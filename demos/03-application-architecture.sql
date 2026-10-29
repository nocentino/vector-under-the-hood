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
    A RAG assistant over StackOverflow. The Python app (rag-app.py) calls the
    stored procedures in this script.

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run the sections top to bottom. Every one is idempotent.
  Deep dives: demos/03-application-architecture-optional.sql.
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
   QuestionEmbeddings is a satellite table to Posts, joined on PostId, on its
   own filegroup. Why not a column on Posts?
     - A background pipeline writes it, not users, so keep the logging apart.
     - Change models and you rebuild this table without touching Posts.
     - The vector index needs a single INT clustered key; you design it here.
     - Not every post needs a vector. A missing row means "not embedded yet."
----------------------------------------------------------------------------- */

SELECT
    total.total_questions,
    embedded.embedded_questions,
    CAST(embedded.embedded_questions AS FLOAT) / total.total_questions * 100
        AS pct_embedded
FROM (SELECT COUNT(*) AS total_questions     FROM dbo.Posts              WHERE PostTypeId = 1) total
CROSS JOIN
     (SELECT COUNT(*) AS embedded_questions  FROM dbo.QuestionEmbeddings)                     embedded;
GO


/* -----------------------------------------------------------------------------
   1b. The chunk column: why it matters
   -----------------------------------------------------------------------------
   chunk stores the exact text that was embedded. If Posts changes and no
   longer matches it, the vector is stale (§4b checks this). The app can also
   hand chunk text to the LLM without a join. Long documents get split with
   AI_GENERATE_CHUNKS (optional Appendix A).
----------------------------------------------------------------------------- */

SELECT TOP (5)
    qe.PostId,
    qe.chunk,
    DATALENGTH(qe.chunk)    AS chunk_bytes,
    qe.embeddings           AS embedding_preview
FROM dbo.QuestionEmbeddings qe;
GO


/* =============================================================================
   SECTION 2: THE RAG STORED PROCEDURES
   ============================================================================= */

/* -----------------------------------------------------------------------------
   The app never writes VECTOR_DISTANCE or VECTOR_SEARCH. It calls a proc,
   which owns the model name, the index-or-scan choice, and the oversampling,
   and returns only scalar columns.

   The model it calls is registered with CREATE EXTERNAL MODEL. LOCATION is
   HTTPS because SQL Server 2025 requires TLS for external calls.
----------------------------------------------------------------------------- */

SELECT
    em.name,
    em.location,
    em.model_type_desc, -- 'EMBEDDINGS'
    em.api_format       -- 'Ollama', 'AzureOpenAI', 'OpenAI', etc.
FROM sys.external_models em;
GO


/* -----------------------------------------------------------------------------
   2a. find_similar_questions: the primary retrieval procedure
   -----------------------------------------------------------------------------
   VECTOR_SEARCH with no index fails with Msg 42227, and during the rebuild
   cycle (§4a) there's no index. So the proc checks sys.vector_indexes: ANN
   when the index exists, exact kNN when it doesn't. @search_mode forces
   either path.

   The ANN path oversamples 5x: at 1,000,000 rows that lifts recall from
   ~0.85 to ~0.97 for ~20 ms more (Demo 2 §3a).

   Gotchas: CREATE fails with Msg 42227 if the index is missing at create time,
   and the caller needs VIEW DEFINITION on the table to see the index (§3a).
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
    -- @top. At 1,000,000 rows, TOP_N = 10 found 0.84 to 0.89 of the true top 10;
    -- 5x oversampling brought it to 0.96 to 0.98 (Demo 02 §3a).
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

-- AUTO picks ANN when vec_idx exists:
EXEC dbo.find_similar_questions
    @prompt = N'I keep getting merge conflicts, what is the right workflow?',
    @top    = 5;
GO

-- Force the exact path to compare:
EXEC dbo.find_similar_questions
    @prompt = N'I keep getting merge conflicts, what is the right workflow?',
    @top    = 5,
    @search_mode = 'KNN';
GO


/* =============================================================================
   SECTION 3: SECURITY MODEL: LEAST-PRIVILEGE APPLICATION ACCESS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   The app logs in as rag_app, which can EXECUTE two procs and the model, and
   see the index's metadata. No SELECT on any table, no DML, no DDL. The
   database enforces that, not the app or the prompt.
----------------------------------------------------------------------------- */

USE [master];
GO

-- CHECK_POLICY OFF and a password in a script are demo shortcuts. In production
-- use Microsoft Entra ID or a policy-checked password kept in a secret store.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'rag_app')
    CREATE LOGIN rag_app
    WITH PASSWORD         = 'RagP@ss2025!',
         DEFAULT_DATABASE = [StackOverflow],
         CHECK_EXPIRATION = OFF,
         CHECK_POLICY     = OFF;
GO
ALTER LOGIN rag_app WITH DEFAULT_DATABASE = [StackOverflow];
GO

USE [StackOverflow];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'rag_app')
    CREATE USER rag_app FOR LOGIN rag_app;
GO

-- Grant exactly what the app needs. Nothing more.
GRANT EXECUTE ON dbo.find_similar_questions TO rag_app;
GRANT EXECUTE ON dbo.get_top_answer         TO rag_app;
GRANT EXECUTE ON EXTERNAL MODEL::ollama     TO rag_app;  -- docs: required to use the model
GRANT VIEW DEFINITION ON dbo.QuestionEmbeddings TO rag_app;  -- metadata only; without it the proc can't see vec_idx
GO


/* -----------------------------------------------------------------------------
   3a. Prove it: act as rag_app
   -----------------------------------------------------------------------------
   EXECUTE AS USER runs with only rag_app's grants; REVERT puts you back.
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

-- 2. But the proc works: ownership chaining reads the tables for it.
EXECUTE AS USER = 'rag_app';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
REVERT;
GO

-- 3. The VIEW DEFINITION gotcha. Revoke it and the same proc quietly takes the
--    slow path: no error, just search_path = 'kNN'.
REVOKE VIEW DEFINITION ON dbo.QuestionEmbeddings FROM rag_app;
GO
EXECUTE AS USER = 'rag_app';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
REVERT;
GO

-- Put it back:
GRANT VIEW DEFINITION ON dbo.QuestionEmbeddings TO rag_app;
GO

USE [master];
GO


/* =============================================================================
   SECTION 4: PRODUCTION PIPELINE PATTERNS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   4a. The maintenance cycle: drop, embed, rebuild (SQL Server 2025)
   -----------------------------------------------------------------------------
   The table is read-only while the index exists, so new content loads in a
   cycle: drop the index, insert, rebuild. The proc switches to exact kNN
   during the window and back after. No error, no app change.

   At 10,000 rows the fallback is nearly free. At 1,000,000 it's ~200 ms and
   1 to 2 CPU-seconds per query, and the rebuild took 35 minutes, so plan the
   window. Azure SQL's latest-version index doesn't need any of this.
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

-- NOT EXISTS makes this resumable: kill it, rerun it, it picks up where it left off.
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
WITH (metric = 'cosine', type = 'diskann', MAXDOP = 4);

SELECT
    DATEDIFF(MILLISECOND, @rebuild_start, SYSDATETIME()) AS build_time_ms,
    (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)        AS rows_in_index;
GO

PRINT 'After: back on the index.';
EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 3;
GO


/* -----------------------------------------------------------------------------
   4b. Monitoring and staleness
   -----------------------------------------------------------------------------
   A vector pipeline fails quietly. Schedule checks like these (setup/init.sql
   creates a read-only dba_monitor login for them). CU10 has no
   sys.dm_db_vector_indexes, so use catalog views and your own comparisons.
----------------------------------------------------------------------------- */

-- 1. Is the index there? No rows means the app is on exact kNN.
SELECT
    OBJECT_NAME(v.object_id)  AS table_name,
    v.name                    AS index_name,
    v.vector_index_type,
    v.distance_metric
FROM sys.vector_indexes v;
GO

-- 2. Stale embeddings: the chunk no longer matches the source (§1b).
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

-- 3. Log the search_path the app reports, and alert on 'kNN' outside a
--    maintenance window. More checks: optional Appendix F.


/* =============================================================================
   SECTION 5: THE FULL RAG ARCHITECTURE: WHAT HAPPENS WHEN THE APP RUNS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   THE FINALE: run the app
   -----------------------------------------------------------------------------
       docker compose --profile app up rag-app-ui      → http://localhost:8501

   Ask one question (about 10 seconds end to end on my M2). The answer shows
   its search path and retrieval time. The app connects as
   rag_app and its database work is two calls; it never sees a vector:

       EXEC dbo.find_similar_questions @prompt = ?, @top = ?
       EXEC dbo.get_top_answer @question_post_id = ?

   If the browser misbehaves:
       docker compose run --rm rag-app python demos/rag-app.py "how do I undo my last git commit?"
----------------------------------------------------------------------------- */
