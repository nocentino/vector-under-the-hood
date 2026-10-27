SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  Demo 3 of 3: APPLICATION ARCHITECTURE PATTERNS
  Schema design  ·  RAG stored procedures  ·  Security  ·  Pipeline patterns
=============================================================================

  Learning objective:
    Use these architecture patterns to build a working application on
    SQL Server 2025 vector search.

  What we're building:
    A Retrieval-Augmented Generation (RAG) assistant over the StackOverflow
    dataset. The companion Python app (rag-app.py) connects to SQL Server and
    calls the stored procedures you'll create in this script.

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run the sections top to bottom. Every one is idempotent.

  Section 4b is [OPTIONAL] and needs a second Ollama model pulled.
=============================================================================
*/

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 1: SCHEMA DESIGN: WHY A SEPARATE EMBEDDINGS TABLE
   ============================================================================= */

/* -----------------------------------------------------------------------------
   1a. The separation pattern
   -----------------------------------------------------------------------------
   QuestionEmbeddings is a SATELLITE TABLE to Posts. It's related by PostId,
   lives on its own filegroup, and holds only what the vector pipeline needs.

   So why not just add an embeddings column to Posts?

     LIFECYCLE MISMATCH
       Users write Posts. A background pipeline writes embeddings. Put them
       in one table and you've mixed two very different write patterns.
       Every embedding update now generates a log record on the operational
       table.

     REBUILD INDEPENDENCE
       When you change models (say, nomic-embed-text 768-dim to
       mxbai-embed-large 1024-dim), you rebuild the embeddings table and
       never touch Posts. PostId keeps them aligned. There's no foreign key
       in this demo; add one in production.

     INDEX REQUIREMENTS
       A vector index needs a clustered primary key on a single INT column
       (Msg 42217 otherwise). Posts happens to fit, but plenty of source tables
       have GUID or composite keys. With a satellite table, you design the key
       for the index.

     PARTIAL COVERAGE
       Not every Post needs an embedding. We embedded the top questions
       by Score. A missing row in the satellite table means "not yet
       embedded," not NULL data.

     STORAGE TIERING
       The EMBEDDINGS filegroup can live on different storage than PRIMARY.
       Vector I/O (large sequential reads during index build, random reads
       during graph traversal) shouldn't fight OLTP I/O for bandwidth.

   Here's what I'd do in your own systems: keep the vector column and its
   index in a satellite table you can fully rebuild without touching the
   transactional source of truth.
----------------------------------------------------------------------------- */

-- Embedding coverage: how much of the dataset is vectorized?
SELECT
    total.total_questions,
    embedded.embedded_questions,
    CAST(embedded.embedded_questions AS FLOAT) / total.total_questions * 100
        AS pct_embedded
FROM (SELECT COUNT(*) AS total_questions     FROM dbo.Posts              WHERE PostTypeId = 1) total
CROSS JOIN
     (SELECT COUNT(*) AS embedded_questions  FROM dbo.QuestionEmbeddings)                     embedded;
GO

-- The coverage gap: top questions NOT yet in QuestionEmbeddings.
SELECT TOP (10)
    p.Id,
    p.Title,
    p.Score,
    CASE WHEN qe.PostId IS NOT NULL THEN 'embedded' ELSE 'pending' END AS status
FROM dbo.Posts p
LEFT JOIN dbo.QuestionEmbeddings qe ON qe.PostId = p.Id
WHERE p.PostTypeId = 1
ORDER BY p.Score DESC;
GO


/* -----------------------------------------------------------------------------
   1b. The chunk column: why it matters
   -----------------------------------------------------------------------------
   QuestionEmbeddings.chunk stores the EXACT text that was embedded. It's a
   small detail that pays off:

     DECOUPLING FROM SOURCE
       The source row (Posts.Title, Posts.Tags) can change. The chunk column
       records what the vector represented when it was generated. If the
       title changes, the chunk tells you the embedding is stale.

     CONTEXT FOR THE APPLICATION
       At retrieval time, the Python app can hand back chunk text as RAG
       context without joining back to Posts. One query, one round trip.

     AUDIT TRAIL
       "This is the exact text the vector represents." That's what you want
       when you're debugging retrieval and the results look wrong.

   Our chunks are short (a title plus tags), so one row is one chunk. Real
   documents are longer than an embedding model wants at once, so you split
   them. SQL Server 2025 does that in T-SQL with AI_GENERATE_CHUNKS.
----------------------------------------------------------------------------- */

SELECT TOP (5)
    qe.PostId,
    qe.chunk,
    DATALENGTH(qe.chunk)    AS chunk_bytes,
    qe.embeddings           AS embedding_preview
FROM dbo.QuestionEmbeddings qe;
GO


/* -----------------------------------------------------------------------------
   1c. Chunking long text with AI_GENERATE_CHUNKS
   -----------------------------------------------------------------------------
   Answers are long HTML bodies. Let's chunk the accepted answers to a few
   top questions into 500-character pieces with 10% overlap, then embed each
   piece. The overlap keeps a sentence that straddles a boundary in both
   chunks.

   Notice two schema points:
     - ChunkId is a surrogate INT key. (AnswerId, chunk_order) is the natural
       key, but a vector index needs a single INT clustered primary key.
     - AI_GENERATE_CHUNKS needs database compatibility level 170
       (setup/init.sql sets it).

   Docs: https://learn.microsoft.com/en-us/sql/t-sql/functions/ai-generate-chunks-transact-sql
----------------------------------------------------------------------------- */

DROP TABLE IF EXISTS dbo.AnswerChunks;
CREATE TABLE dbo.AnswerChunks
(
    ChunkId     INT IDENTITY(1,1) NOT NULL,
    AnswerId    INT               NOT NULL,
    chunk_order BIGINT            NOT NULL,
    chunk       NVARCHAR(MAX)     NOT NULL,
    embeddings  VECTOR(768)       NOT NULL,
    CONSTRAINT PK_AnswerChunks PRIMARY KEY CLUSTERED (ChunkId)
) ON [EMBEDDINGS];
GO

-- Here's what the chunker produces for one answer:
SELECT TOP (1) a.Id AS answer_id, c.chunk_order, c.chunk_offset, c.chunk_length, c.chunk
FROM dbo.Posts q
JOIN dbo.Posts a ON a.Id = q.AcceptedAnswerId
CROSS APPLY AI_GENERATE_CHUNKS(SOURCE = a.Body, CHUNK_TYPE = FIXED,
                               CHUNK_SIZE = 500, OVERLAP = 10) AS c
WHERE q.Id = (SELECT TOP (1) PostId FROM dbo.QuestionEmbeddings ORDER BY PostId)
ORDER BY c.chunk_order;
GO

-- Chunk and embed the accepted answers for 5 top questions in one statement:
INSERT INTO dbo.AnswerChunks (AnswerId, chunk_order, chunk, embeddings)
SELECT a.Id, c.chunk_order, c.chunk,
       AI_GENERATE_EMBEDDINGS(c.chunk USE MODEL ollama)
FROM (SELECT TOP (5) q.AcceptedAnswerId
      FROM dbo.Posts q
      JOIN dbo.QuestionEmbeddings qe ON qe.PostId = q.Id
      WHERE q.AcceptedAnswerId IS NOT NULL
      ORDER BY q.Score DESC) AS top_q
JOIN dbo.Posts a ON a.Id = top_q.AcceptedAnswerId
CROSS APPLY AI_GENERATE_CHUNKS(SOURCE = a.Body, CHUNK_TYPE = FIXED,
                               CHUNK_SIZE = 500, OVERLAP = 10) AS c;
GO

SELECT AnswerId, COUNT(*) AS chunks, SUM(LEN(chunk)) AS total_chars
FROM dbo.AnswerChunks
GROUP BY AnswerId;
GO

SELECT
    AnswerId,
    chunk_order,
    chunk
FROM dbo.AnswerChunks
ORDER BY AnswerId, chunk_order;
GO
-- In production, strip the HTML before chunking. The model embeds the tags too.

-- Now use them. Search the passages, not the questions: which piece of which
-- answer best matches a question? There are only a few dozen chunks, so an
-- exact search is the right tool here (no vector index needed).
DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo a commit but keep my changes?' USE MODEL ollama);

SELECT TOP (3)
    c.AnswerId,
    c.chunk_order,
    VECTOR_DISTANCE('cosine', @qv, c.embeddings) AS distance,
    LEFT(c.chunk, 200)                           AS passage
FROM dbo.AnswerChunks c
ORDER BY distance;
GO
-- The winner is a passage from the git answer, not the whole answer. That's
-- the point of chunking: the context you hand the LLM is the paragraph that
-- answers the question, not 3,000 characters around it. The app in this repo
-- still sends question titles plus a trimmed answer. Searching chunks is the
-- next step up.


/* =============================================================================
   SECTION 2: THE RAG STORED PROCEDURES
   ============================================================================= */

/* -----------------------------------------------------------------------------
   The stored procedure is the stable interface between the application and
   the vector search logic. The application NEVER writes VECTOR_DISTANCE or
   VECTOR_SEARCH itself. It calls a named procedure.

   Here's what that buys you:

     SWAPPABLE INTERNALS
       The proc below uses the DiskANN index when it's there and falls back
       to exact kNN when it isn't. The Python app doesn't know or care which
       path ran. It just sees a search_path column.

     MODEL ABSTRACTION
       The embedding model name ('ollama' here) lives inside the proc. Swap
       the model by updating one object, not every query in the codebase.

     TYPE SAFETY AT THE BOUNDARY
       The proc returns only scalar columns (no VECTOR(768)). The app gets
       text and numbers. It never has to deserialize 768 floats.

     GOVERNANCE
       The app gets EXECUTE on two procs and the model, plus metadata-only
       VIEW DEFINITION on one table. No SELECT anywhere. Section 3 shows it.
----------------------------------------------------------------------------- */

/* -----------------------------------------------------------------------------
   2a. find_similar_questions: the primary retrieval procedure
   -----------------------------------------------------------------------------
   The Python app calls this with the user's natural-language question.
   SQL Server embeds the prompt with AI_GENERATE_EMBEDDINGS (calling Ollama),
   then walks the DiskANN graph with VECTOR_SEARCH.

   Here's the catch on SQL Server 2025: VECTOR_SEARCH with no vector index
   fails with Msg 42227. During the drop-insert-rebuild cycle (Section 4a)
   there's no index. By default, the proc checks sys.vector_indexes and uses
   ANN when the index exists, or exact kNN with VECTOR_DISTANCE when it doesn't.

   You can override that with @search_mode: AUTO (the default), ANN, or KNN.
   ANN raises Msg 50002 if the index is missing. KNN always forces the exact
   scan, which is handy when you're comparing recall or performance.

   The ANN path applies Demo 02's lesson: it asks the graph for
   @top × @oversample candidates (5x by default) and keeps the closest @top.
   At 10,000 rows you won't see a difference. At 1,000,000 rows it's the
   difference between finding about 80% and about 97% of the true top 10, for
   roughly 20 ms more per search (Demo 02 §3b).

   The docs say VECTOR_SEARCH with no matching index raises a warning and
   falls back to kNN. On SQL Server 2025 CU10 it raises Msg 42227 instead, so
   the proc has to make the choice itself.

   One more gotcha: CREATE PROCEDURE itself fails with Msg 42227 if the
   index doesn't exist at create time. After that, dropping the index is
   fine and the IF branch handles it. Run this while vec_idx exists.

   And a security gotcha: catalog views only show metadata the CALLER can
   see. Ownership chaining covers the table, not sys.vector_indexes. Run as
   rag_app, the IF EXISTS check sees nothing and the proc quietly takes the
   slow kNN path. Section 3 fixes that with VIEW DEFINITION on the one
   table. That's metadata only, not data.
----------------------------------------------------------------------------- */

CREATE OR ALTER PROCEDURE dbo.find_similar_questions
    @prompt NVARCHAR(MAX),
    @top    INT = 5,
    @search_mode VARCHAR(10) = 'AUTO',
    @oversample  INT = 5
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @mode VARCHAR(10) = UPPER(LTRIM(RTRIM(@search_mode)));

    IF @mode IS NULL OR @mode NOT IN ('AUTO', 'ANN', 'KNN')
        THROW 50001, 'Invalid @search_mode. Use AUTO, ANN, or KNN.', 1;

    DECLARE @has_index BIT = CASE WHEN EXISTS (
        SELECT 1 FROM sys.vector_indexes
        WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings')
    ) THEN 1 ELSE 0 END;

    IF @mode = 'ANN' AND @has_index = 0
        THROW 50002, 'ANN search requires a vector index on dbo.QuestionEmbeddings.', 1;

    IF @oversample IS NULL OR @oversample < 1
        THROW 50003, '@oversample must be 1 or more.', 1;

    -- Ask the graph for more candidates than we return, then keep the closest
    -- @top. At 1,000,000 rows, TOP_N = 10 found 0.64 to 0.86 of the true top 10;
    -- 5x oversampling brought it to 0.94 to 0.99 (Demo 02 §3b).
    DECLARE @top_n INT = @top * @oversample;

    -- SQL Server makes the embedding call. The app sends plain text.
    DECLARE @query_vector VECTOR(768) =
        AI_GENERATE_EMBEDDINGS(@prompt USE MODEL ollama);

    IF @mode = 'ANN' OR (@mode = 'AUTO' AND @has_index = 1)
        SELECT TOP (@top)
            p.Id                                                        AS post_id,
            p.Title                                                     AS title,
            qe.chunk                                                    AS context_chunk,
            REPLACE(REPLACE(REPLACE(
                ISNULL(p.Tags, N''), '><', ', '), '<', ''), '>', '')    AS tags,
            p.Score                                                     AS community_score,
            p.ViewCount                                                 AS view_count,
            p.AnswerCount                                               AS answer_count,
            s.distance                                                  AS distance,
            'ANN'                                                       AS search_path
        FROM VECTOR_SEARCH(
            TABLE      = dbo.QuestionEmbeddings AS qe,
            COLUMN     = [embeddings],
            SIMILAR_TO = @query_vector,
            METRIC     = 'cosine',
            TOP_N      = @top_n
        ) AS s
        JOIN dbo.Posts p ON p.Id = qe.PostId
        ORDER BY s.distance;
    ELSE
        SELECT
            p.Id                                                        AS post_id,
            p.Title                                                     AS title,
            n.chunk                                                     AS context_chunk,
            REPLACE(REPLACE(REPLACE(
                ISNULL(p.Tags, N''), '><', ', '), '<', ''), '>', '')    AS tags,
            p.Score                                                     AS community_score,
            p.ViewCount                                                 AS view_count,
            p.AnswerCount                                               AS answer_count,
            n.distance                                                  AS distance,
            'kNN'                                                       AS search_path
        FROM (
            SELECT TOP (@top)
                qe.PostId,
                qe.chunk,
                VECTOR_DISTANCE('cosine', @query_vector, qe.embeddings) AS distance
            FROM dbo.QuestionEmbeddings qe
            ORDER BY distance
        ) AS n
        JOIN dbo.Posts p ON p.Id = n.PostId
        ORDER BY n.distance;
END;
GO

-- AUTO picks ANN when vec_idx exists and exact kNN when it doesn't.
EXEC dbo.find_similar_questions
    @prompt = N'my Python script is really slow on large files, how do I speed it up?',
    @top    = 5,
    @search_mode = 'AUTO';
GO

-- Force each path when you're comparing recall or performance.
EXEC dbo.find_similar_questions
    @prompt = N'I keep getting merge conflicts, what is the right workflow?',
    @top    = 5,
    @search_mode = 'ANN';
GO

EXEC dbo.find_similar_questions
    @prompt = N'I keep getting merge conflicts, what is the right workflow?',
    @top    = 5,
    @search_mode = 'KNN';
GO


/* -----------------------------------------------------------------------------
   2b. get_top_answer: fetch the best answer for a given question
   -----------------------------------------------------------------------------
   The Python app calls find_similar_questions to find relevant questions,
   then calls get_top_answer for each result to pull real answer text in
   as extra RAG context.

   Priority order:
     1. The accepted answer (if one exists)
     2. The highest-scored answer (fallback)
----------------------------------------------------------------------------- */

CREATE OR ALTER PROCEDURE dbo.get_top_answer
    @question_post_id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1)
        a.Id            AS answer_id,
        a.Body          AS answer_body,     -- HTML; Python app strips tags
        a.Score         AS answer_score,
        a.CreationDate  AS answer_date
    FROM dbo.Posts a
    WHERE a.PostTypeId = 2                              -- answers only
      AND a.ParentId   = @question_post_id              -- for this question
    ORDER BY
        -- Accepted answer first (AcceptedAnswerId is on the parent question):
        CASE WHEN a.Id = (
            SELECT AcceptedAnswerId FROM dbo.Posts WHERE Id = @question_post_id
        ) THEN 0 ELSE 1 END,
        a.Score DESC;   -- then highest voted
END;
GO

-- Let's grab the accepted (or best) answer for our top-scored embedded question.
-- The Python app does the same thing in a loop over find_similar_questions results.
DECLARE @q_id INT = (
    SELECT TOP (1) p.Id
    FROM dbo.Posts p
    JOIN dbo.QuestionEmbeddings qe ON qe.PostId = p.Id
    ORDER BY p.Score DESC
);
SELECT Id, Title, Score FROM dbo.Posts WHERE Id = @q_id;
EXEC dbo.get_top_answer @question_post_id = @q_id;
GO


/* =============================================================================
   SECTION 3: SECURITY MODEL: LEAST-PRIVILEGE APPLICATION ACCESS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   The Python RAG app connects as a dedicated login that can call two stored
   procedures. That's it.

   The database enforces the access contract. Not the application code.
   Not the prompt. Not the AI model. The database.

   What rag_app CAN do:
     - EXECUTE dbo.find_similar_questions    (semantic search)
     - EXECUTE dbo.get_top_answer            (answer retrieval)
     - EXECUTE EXTERNAL MODEL::ollama        (needed for AI_GENERATE_EMBEDDINGS)
     - VIEW DEFINITION on QuestionEmbeddings (so the proc can see the vector
                                              index in sys.vector_indexes)

   What rag_app CANNOT do:
     - Read the VECTOR(768) column directly
     - Read any table it is not explicitly granted on
     - INSERT, UPDATE, or DELETE anything
     - DROP or ALTER any object
     - Read the proc source (OBJECT_DEFINITION returns NULL)
     - Do anything in another database. It has no user in any other
       database. Like every login it can still connect to master, tempdb,
       and msdb as guest, so its default database is set to StackOverflow.

   One thing it CAN see: EXECUTE on the external model makes its row in
   sys.external_models visible, endpoint URL included. Keep secrets in a
   database scoped credential, never in the LOCATION.
----------------------------------------------------------------------------- */

USE [master];
GO

-- Create the application login (idempotent).
-- CHECK_POLICY OFF and a password in a script are demo shortcuts. In production
-- use Microsoft Entra ID or a policy-checked password kept in a secret store.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'rag_app')
    CREATE LOGIN rag_app
    WITH PASSWORD         = 'RagP@ss2025!',
         DEFAULT_DATABASE = [StackOverflow],
         CHECK_EXPIRATION = OFF,
         CHECK_POLICY     = OFF;
GO
-- For a login created before this setting existed:
ALTER LOGIN rag_app WITH DEFAULT_DATABASE = [StackOverflow];
GO

USE [StackOverflow];
GO

-- Map the login to a database user.
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'rag_app')
    CREATE USER rag_app FOR LOGIN rag_app;
GO

-- Grant exactly what the app needs. Nothing more.
GRANT EXECUTE ON dbo.find_similar_questions TO rag_app;
GRANT EXECUTE ON dbo.get_top_answer         TO rag_app;
GRANT EXECUTE ON EXTERNAL MODEL::ollama     TO rag_app;  -- docs: required to use the model
GRANT VIEW DEFINITION ON dbo.QuestionEmbeddings TO rag_app;  -- metadata only; without it the proc can't see vec_idx
GO

-- Let's verify the complete permission set for rag_app:
SELECT
    dp.class_desc                           AS object_class,
    COALESCE(
        OBJECT_NAME(dp.major_id),
        em.name,
        CAST(dp.major_id AS NVARCHAR(20))
    )                                       AS object_name,
    dp.permission_name,
    dp.state_desc                           AS grant_state
FROM sys.database_permissions   dp
JOIN sys.database_principals     u  ON u.principal_id = dp.grantee_principal_id
LEFT JOIN sys.external_models    em ON em.external_model_id = dp.major_id
WHERE u.name = N'rag_app'
ORDER BY dp.class_desc, object_name;
GO

-- WHAT TO HIGHLIGHT:
--   The app has EXECUTE on two procs and the external model.
--   It has no SELECT on any table. It can't read Posts, QuestionEmbeddings,
--   Users, or anything else. All data access goes through the procs.
--   That's the SQL Server security model doing its job.


/* -----------------------------------------------------------------------------
   3b. Prove it: act as rag_app
   -----------------------------------------------------------------------------
   EXECUTE AS USER switches your session to rag_app, so every statement below
   runs with only the grants above. REVERT puts you back as sa. If a batch
   stops early, run REVERT by hand before you continue.
----------------------------------------------------------------------------- */

-- 1. Direct table access is denied (Msg 229):
EXECUTE AS USER = 'rag_app';
BEGIN TRY
    SELECT TOP (1) * FROM dbo.Posts;
END TRY
BEGIN CATCH
    PRINT CONCAT('Msg ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;
REVERT;
GO

-- 2. The vector column is off limits too:
EXECUTE AS USER = 'rag_app';
BEGIN TRY
    SELECT TOP (1) embeddings FROM dbo.QuestionEmbeddings;
END TRY
BEGIN CATCH
    PRINT CONCAT('Msg ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;
REVERT;
GO

-- 3. But the proc works. Ownership chaining lets it read the tables on the
--    app's behalf. The path is ANN because the index is visible to rag_app:
EXECUTE AS USER = 'rag_app';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
REVERT;
GO

-- 4. The proc source is hidden from the app:
EXECUTE AS USER = 'rag_app';
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.find_similar_questions')) AS proc_source;   -- NULL
REVERT;
GO

-- 5. The VIEW DEFINITION gotcha, live. Take the grant away and the same proc
--    quietly takes the slow path. No error, just search_path = 'kNN':
REVOKE VIEW DEFINITION ON dbo.QuestionEmbeddings FROM rag_app;
GO
EXECUTE AS USER = 'rag_app';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
REVERT;
GO

-- Put it back:
GRANT VIEW DEFINITION ON dbo.QuestionEmbeddings TO rag_app;
GO
EXECUTE AS USER = 'rag_app';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
REVERT;
GO

USE [master];
GO


/* =============================================================================
   SECTION 4: PRODUCTION PIPELINE PATTERNS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   4a. The maintenance cycle: drop, embed, rebuild (SQL Server 2025)
   -----------------------------------------------------------------------------
   On SQL Server 2025 a table with a vector index is read-only. INSERT,
   UPDATE, DELETE, and MERGE fail with Msg 42231, and TRUNCATE TABLE fails
   with Msg 42232. ALLOW_STALE_VECTOR_INDEX doesn't help here: the ALTER
   DATABASE SCOPED CONFIGURATION docs say it isn't available in SQL Server 2025
   (it's Azure SQL Database and Fabric), and CU10 rejects it with Msg 102.

   So you load new content with a cycle:

     1. DROP the vector index    → table becomes writable
     2. INSERT new embeddings    → only the rows that aren't embedded yet
     3. CREATE the vector index  → rebuild the graph over every row

   Let's watch the app's proc switch paths while it happens. It answers from
   the index before step 1, from exact kNN during the window, and from the
   index again after step 3. No error, no app change.

   That fallback is nearly free on 10,000 rows (tens of milliseconds). It is
   NOT free at scale. From Demo 2 §2c, an exact search over 1,000,000 rows
   takes 160 to 340 ms and 1.7 to 2.5 CPU-seconds per query on my laptop,
   against about 15 ms for the index. The rebuild at that size took 26.5 minutes. So at scale the
   rebuild window needs spare CPU, a throttle or queue on search, or a
   maintenance mode. "The app keeps working" is true. "At the same speed" isn't.

   The NOT EXISTS guard in step 2 makes the load resumable and idempotent.
   Kill it, rerun it, and it picks up where it left off.

   Schedule this in a low-traffic window. Azure SQL Database, Fabric, and
   Managed Instance (Always-up-to-date) don't need it: their latest-version
   index supports DML and maintains itself in the background.

   Heads up: step 3 rebuilds the index over ~10,000 rows, which takes
   about ten seconds on my M2.
----------------------------------------------------------------------------- */

USE [StackOverflow];
GO

PRINT 'Before: the proc uses the index.';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
GO

PRINT 'Step 1: drop the vector index. The table is now writable.';
DROP INDEX IF EXISTS vec_idx ON dbo.QuestionEmbeddings;
GO

PRINT 'During the window: same proc, exact kNN path.';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
GO

PRINT 'Step 2: embed the next 100 questions that aren''t embedded yet.';
;WITH new_questions AS (
    SELECT TOP (100)
        p.Id,
        p.Title + N' ' +
            REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'')
            AS chunk
    FROM dbo.Posts p
    WHERE p.PostTypeId = 1
      AND p.Title IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM dbo.QuestionEmbeddings qe WHERE qe.PostId = p.Id
      )
    ORDER BY p.Score DESC
)
INSERT INTO dbo.QuestionEmbeddings (PostId, chunk, embeddings)
SELECT
    q.Id,
    q.chunk,
    AI_GENERATE_EMBEDDINGS(q.chunk USE MODEL ollama) AS embeddings
FROM new_questions q;
GO

PRINT 'Step 3: rebuild the DiskANN index.';
DECLARE @rebuild_start DATETIME2 = SYSDATETIME();

CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (metric = 'cosine', type = 'diskann');

SELECT
    DATEDIFF(MILLISECOND, @rebuild_start, SYSDATETIME()) AS build_time_ms,
    (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)        AS rows_in_index;
GO

PRINT 'After: back on the index.';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
GO


/* -----------------------------------------------------------------------------
   4b. [OPTIONAL] Model swap: a new embedding model, side by side
   -----------------------------------------------------------------------------
   The EXTERNAL MODEL is the only place the model endpoint is named. Every
   query refers to the model by name.

   Changing models is bigger than changing a name, though. Vectors from two
   models live in different coordinate spaces, so you can't compare them.
   And a new model usually has a new dimension count. mxbai-embed-large
   produces 1,024 dimensions, and our column is VECTOR(768).

   Here's the pattern that keeps the app online:

     1. Register the new model next to the old one
     2. Build a second satellite table with the new VECTOR(n)
     3. Backfill it and build its vector index
     4. CREATE OR ALTER the proc to point at the new table and model
     5. Drop the old table and model

   The app never changes. Step 4 is the cutover, and it's one statement.

   Build the new index AFTER the backfill, not before. The docs say the same
   about any near-complete replacement of your embeddings: the index was
   built for a different distribution, searches still return valid rows, but
   recall and ranking can quietly degrade. Drop and recreate the index after
   the new vectors are loaded, then re-measure recall (Demo 02 §3).

   Prerequisite (run on the host, ~670 MB):
       ollama pull mxbai-embed-large

   Warm it up before the demo. The first call to a cold Ollama model can take
   longer than SQL Server's REST timeout and fail with Msg 31629:
       curl -s http://localhost:11434/api/embed \
            -d '{"model":"mxbai-embed-large","input":"warm up"}' > /dev/null

   The 1,000-row backfill below takes about two minutes on an M2.
----------------------------------------------------------------------------- */

-- Here's the current model registration:
SELECT
    name,
    location,
    model,
    model_type_desc,
    api_format
FROM sys.external_models;
GO

/*
-- Step 1: register the second model on the same Ollama endpoint.
CREATE EXTERNAL MODEL ollama_mxbai
WITH (
    LOCATION   = 'https://model-web:443/api/embed',
    API_FORMAT = 'Ollama',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'mxbai-embed-large'
);
GO

-- The dimension count is a property of the model. Check it before you
-- design the column:
DECLARE @v NVARCHAR(MAX) =
    CAST(AI_GENERATE_EMBEDDINGS(N'dimension check' USE MODEL ollama_mxbai) AS NVARCHAR(MAX));
SELECT COUNT(*) AS dimensions FROM OPENJSON(@v);   -- 1024
GO

-- Steps 2-3: second satellite table, backfill, index.
CREATE TABLE dbo.QuestionEmbeddings_mxbai
(
    PostId     INT            NOT NULL,
    embeddings VECTOR(1024)   NOT NULL,
    chunk      NVARCHAR(4000) NOT NULL,
    CONSTRAINT PK_QuestionEmbeddings_mxbai PRIMARY KEY CLUSTERED (PostId)
) ON [EMBEDDINGS];
GO

INSERT INTO dbo.QuestionEmbeddings_mxbai (PostId, chunk, embeddings)
SELECT TOP (1000) qe.PostId, qe.chunk, AI_GENERATE_EMBEDDINGS(qe.chunk USE MODEL ollama_mxbai)
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON p.Id = qe.PostId
ORDER BY p.Score DESC;   -- the same top questions the 768-dim table started with
GO

CREATE VECTOR INDEX vec_idx_mxbai ON dbo.QuestionEmbeddings_mxbai([embeddings])
WITH (metric = 'cosine', type = 'diskann');
GO

-- Same question, both models. Distances aren't comparable across models;
-- compare which questions come back.
DECLARE @q768  VECTOR(768)  = AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit?' USE MODEL ollama);
DECLARE @q1024 VECTOR(1024) = AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit?' USE MODEL ollama_mxbai);

SELECT 'nomic 768' AS model, p.Title, s.distance
FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                   SIMILAR_TO = @q768, METRIC = 'cosine', TOP_N = 3) AS s
JOIN dbo.Posts p ON p.Id = t.PostId
UNION ALL
SELECT 'mxbai 1024', p.Title, s.distance
FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings_mxbai AS t, COLUMN = [embeddings],
                   SIMILAR_TO = @q1024, METRIC = 'cosine', TOP_N = 3) AS s
JOIN dbo.Posts p ON p.Id = t.PostId;
GO

-- Step 4: CREATE OR ALTER dbo.find_similar_questions with VECTOR(1024),
-- USE MODEL ollama_mxbai, and TABLE = dbo.QuestionEmbeddings_mxbai.
-- GRANT EXECUTE ON EXTERNAL MODEL::ollama_mxbai TO rag_app; first, and
-- GRANT VIEW DEFINITION on the new table (see Section 2a).

-- Cleanup, so the demo can be re-run:
DROP TABLE IF EXISTS dbo.QuestionEmbeddings_mxbai;
DROP EXTERNAL MODEL ollama_mxbai;
GO
*/


/* -----------------------------------------------------------------------------
   4c. Monitoring and staleness
   -----------------------------------------------------------------------------
   A vector pipeline fails quietly. Nothing errors when an embedding goes
   stale, or when the index is missing and the proc falls back to a scan. So
   you check for it. These are the queries I'd schedule. setup/init.sql
   creates a dba_monitor login (VIEW SERVER STATE and VIEW DATABASE STATE) so
   you can run them without sa:
       sqlcmd -S localhost,1435 -U dba_monitor -P 'MonitorP@ss123!' -d StackOverflow

   SQL Server 2025 CU10 doesn't have sys.dm_db_vector_indexes, the DMV that
   reports index staleness on Azure SQL. So here the signals are catalog
   views and your own comparisons.
----------------------------------------------------------------------------- */

-- 1. Is the index there? If this returns no rows, the app is on exact kNN.
SELECT
    OBJECT_NAME(v.object_id)  AS table_name,
    v.name                    AS index_name,
    v.vector_index_type,
    v.distance_metric
FROM sys.vector_indexes v;
GO

-- 2. Stale embeddings: the chunk we embedded no longer matches the source.
--    This is the job the chunk column does (see §1b). Same expression that
--    built the chunk, so any difference means the title or tags changed.
SELECT TOP (20)
    qe.PostId,
    qe.chunk                                          AS embedded_text,
    p.Title + N' ' +
        REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'')
                                                      AS current_text
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON p.Id = qe.PostId
WHERE qe.chunk <> p.Title + N' ' +
        REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'');
GO

-- 3. Coverage: embedded questions versus the backlog still to embed.
SELECT
    (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)                                AS embedded,
    (SELECT COUNT(*) FROM dbo.Posts WHERE PostTypeId = 1 AND Title IS NOT NULL)  AS embeddable,
    (SELECT COUNT(*) FROM dbo.Posts WHERE PostTypeId = 1 AND Title IS NOT NULL)
      - (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)                            AS backlog;
GO

-- 4. Is search going through the index? The app reports search_path on every
--    call. Log it, and alert when 'kNN' shows up outside a maintenance window.

/*
   WHAT I'D ADD NEXT, NOT BUILT HERE
     - Hybrid search: combine this vector search with full-text search and
       merge the two ranked lists (reciprocal rank fusion). Vector search is
       great at meaning and weak at exact tokens like error codes and names.
     - A hard filter pushed into the search (tenant, date, permissions). On
       this build the filter runs after the graph walk. Demo 02 §4b is why
       you oversample TOP_N.
     - Alerts on the four checks above.
*/


/* =============================================================================
   SECTION 5: THE FULL RAG ARCHITECTURE: WHAT HAPPENS WHEN THE APP RUNS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   Here's the complete call sequence when the Python app (rag-app.py) gets a
   user question:

     APP                     SQL SERVER                        OLLAMA
      │                           │                               │
      │  EXEC find_similar_       │                               │
      │  questions @prompt=...    │                               │
      │ ────────────────────────► │                               │
      │                           │  AI_GENERATE_EMBEDDINGS(...)  │
      │                           │ ────────────────────────────► │
      │                           │ ◄──────── VECTOR(768) ─────── │
      │                           │                               │
      │                           │  VECTOR_SEARCH (DiskANN walk) │
      │                           │  or VECTOR_DISTANCE (kNN)     │
      │                           │  → top-K rows                 │
      │ ◄────── result set ────── │                               │
      │                           │                               │
      │  (for each result)        │                               │
      │  EXEC get_top_answer      │                               │
      │ ────────────────────────► │                               │
      │ ◄────── answer text ───── │                               │
      │                           │                               │
      │  Build RAG prompt         │                               │
      │  (question + context)     │                               │
      │                           │                               │
      │  POST /api/generate       │                               │
      │ ────────────────────────────────────────────────────────► │
      │ ◄──────────── LLM response ────────────────────────────── │
      │                           │                               │
      │  Display grounded answer  │                               │

   SQL Server does the embedding and retrieval.
   The Python app assembles the final prompt and makes the LLM call.
   The user gets a grounded answer backed by StackOverflow content.

   One design note an architect will spot: that's 1 + N round trips per
   question (one search, then one get_top_answer per result, so 6 for K = 5).
   On a local box it's a few milliseconds. Over a WAN, or under load, fold the
   answer lookup into the search proc (an OUTER APPLY to the top answer) and
   make it one call.
----------------------------------------------------------------------------- */

-- Let's run a few representative questions to preview what the app gets back:
EXEC dbo.find_similar_questions
    @prompt = N'what is the difference between a list and a tuple in Python?',
    @top    = 3;
GO

EXEC dbo.find_similar_questions
    @prompt = N'how do I handle errors in async JavaScript?',
    @top    = 3;
GO

EXEC dbo.find_similar_questions
    @prompt = N'SQL query is running slow, how do I find out why?',
    @top    = 3;
GO

/* -----------------------------------------------------------------------------
   THE FINALE: run the app
   -----------------------------------------------------------------------------
   Start the web UI from a terminal and open http://localhost:8501:

       docker compose --profile app up rag-app-ui

   Ask it a few questions. Each answer shows which search path served it (ANN
   or kNN) and how long retrieval took. Then show the code. This is all the
   database work in demos/rag-app.py. The app never sees a vector:

       def find_similar_questions(conn, prompt, top=TOP_K):
           cursor = conn.cursor()
           cursor.execute(
               "EXEC dbo.find_similar_questions @prompt = ?, @top = ?",
               prompt, top)
           columns = [col[0] for col in cursor.description]
           return [dict(zip(columns, row)) for row in cursor.fetchall()]

       def get_top_answer(conn, question_post_id):
           cursor = conn.cursor()
           cursor.execute(
               "EXEC dbo.get_top_answer @question_post_id = ?",
               question_post_id)
           ...

   It connects as rag_app, sends plain text, and gets rows back. Everything
   from this session (the type, the index, the fallback, the oversampling, the
   permissions) sits behind those two EXEC calls.

   The command-line version, if the browser misbehaves:
       docker compose run --rm rag-app python demos/rag-app.py "how do I undo my last git commit?"
----------------------------------------------------------------------------- */
