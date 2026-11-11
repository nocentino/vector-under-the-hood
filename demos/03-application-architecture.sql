SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  Demo 3 of 3: APPLICATION ARCHITECTURE PATTERNS
=============================================================================

  Learning objective:
    Build a working app on SQL Server 2025 vector search.

  Building: a RAG assistant over StackOverflow; rag-app.py calls these procs.

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run top to bottom; all idempotent except 4b (rewrites one post title;
  REHEARSAL RESET restores it). Deep dives: demos/03-application-architecture-optional.sql.
=============================================================================
*/

USE [StackOverflow];
GO

-- Preflight: restore the index if an interrupted 4a dropped it \
-- CREATE PROCEDURE fails, Msg 42227).
IF NOT EXISTS (SELECT 1 FROM sys.vector_indexes WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings'))
    CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
    WITH (metric = 'cosine', type = 'diskann', MAXDOP = 8);
GO


/* =============================================================================
   SECTION 1: SCHEMA DESIGN: WHY A SEPARATE EMBEDDINGS TABLE
   ============================================================================= */

/* -----------------------------------------------------------------------------
   1a. The separation pattern
   -----------------------------------------------------------------------------
   QuestionEmbeddings is a satellite of Posts (join on PostId), own filegroup.
   Why not a column on Posts?
     - A background pipeline writes it; loads and rebuilds stay off Posts.
     - A model change rebuilds this table, not Posts.
     - The vector index needs a single INT clustered key, designed here.
     - A missing row means "not embedded yet."
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


/* =============================================================================
   SECTION 2: THE RAG STORED PROCEDURES
   ============================================================================= */


/* -----------------------------------------------------------------------------
   2a. find_similar_questions: the primary retrieval procedure
   -----------------------------------------------------------------------------
   VECTOR_SEARCH with no index fails (Msg 42227), and the rebuild cycle (4a) has
   none, so the proc checks sys.vector_indexes: ANN if present, else exact kNN.
   @search_mode forces a path.

   Gotchas: CREATE needs the index present (Msg 42227); callers need VIEW
   DEFINITION on the table to see it (optional Appendix C).
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

    -- Oversample, keep the closest @top. At 1,000,000 rows TOP_N = 10 found
    -- 0.84 to 0.89 of the true top 10; 5x, 0.96 to 0.98, for ~20 ms more
    -- (Demo 02 optional Appendix M).
    DECLARE @top_n INT = @top * @oversample;

    -- SQL Server embeds; the app sends text.
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

-- AUTO uses ANN:
EXEC dbo.find_similar_questions
    @prompt = N'I keep getting merge conflicts, what is the right workflow?',
    @top    = 5;
GO

-- Exact, to compare:
EXEC dbo.find_similar_questions
    @prompt = N'I keep getting merge conflicts, what is the right workflow?',
    @top    = 5,
    @search_mode = 'KNN';
GO


/* =============================================================================
   SECTION 3: SECURITY MODEL: LEAST-PRIVILEGE APPLICATION ACCESS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   The app logs in as rag_app: EXECUTE on two procs and the model, metadata on
   the index, no SELECT/DML/DDL. The database enforces it, not the app or prompt.
----------------------------------------------------------------------------- */

USE [master];
GO

-- CHECK_POLICY OFF and a scripted password are demo-only. Production: Entra ID,
-- or a policy-checked password in a secret store.
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

GRANT EXECUTE ON dbo.find_similar_questions TO rag_app;
GRANT EXECUTE ON dbo.get_top_answer         TO rag_app;
GRANT EXECUTE ON EXTERNAL MODEL::ollama     TO rag_app;  -- docs: required to use the model
GRANT VIEW DEFINITION ON dbo.QuestionEmbeddings TO rag_app;  -- metadata only; without it the proc can't see vec_idx
GO


/* =============================================================================
   SECTION 4: PRODUCTION PIPELINE PATTERNS
   ============================================================================= */


/* -----------------------------------------------------------------------------
   4a. Monitoring, and what happens when a chunk changes
   -----------------------------------------------------------------------------
   Vector pipelines fail quietly; schedule checks like these (setup/init.sql
   creates a read-only dba_monitor login). CU10 has no sys.dm_db_vector_indexes,
   so use catalog views and your own checks.

   Staleness matters most: after a source change, search answers from the old
   meaning. Change Tracking on Posts flags rows changed since the last sync;
   re-embed only those.
----------------------------------------------------------------------------- */

-- 1. Is the index there? No rows means the app is on exact kNN.
SELECT
    OBJECT_NAME(v.object_id)  AS table_name,
    v.name                    AS index_name,
    v.vector_index_type,
    v.distance_metric
FROM sys.vector_indexes v;
GO

-- 2. Stale embeddings (1b), as a schedulable view.
CREATE OR ALTER VIEW dbo.stale_embeddings
AS
SELECT
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

SELECT TOP (20) * FROM dbo.stale_embeddings;    -- none yet
GO

-- 3. Enable Change Tracking on Posts; the sync log holds the last version.
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
    ALTER DATABASE [StackOverflow] SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);
GO
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.Posts'))
    ALTER TABLE dbo.Posts ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);
GO
IF OBJECT_ID('dbo.ChunkSyncLog') IS NULL
    CREATE TABLE dbo.ChunkSyncLog (SyncVersion BIGINT NOT NULL PRIMARY KEY, SyncTime DATETIME2 NOT NULL);
IF NOT EXISTS (SELECT 1 FROM dbo.ChunkSyncLog)
    INSERT dbo.ChunkSyncLog VALUES (CHANGE_TRACKING_CURRENT_VERSION(), SYSDATETIME());
GO

-- 4. An editor rewrites a title (Posts has no vector index). A JSON
--    content-type row becomes a git question.
SELECT PostId, chunk FROM dbo.QuestionEmbeddings WHERE PostId = 477816;

UPDATE dbo.Posts
SET Title = N'How do I undo my first git commit and keep my changes?'
WHERE Id = 477816;
GO

-- 5. The monitor sees it; the vector still describes the old title:
SELECT * FROM dbo.stale_embeddings;
GO

-- 6. Refresh proc: rebuild and re-embed the chunk for rows Change Tracking
--    flags; skip unchanged chunks.
CREATE OR ALTER PROCEDURE dbo.refresh_changed_chunks
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @last BIGINT = (SELECT MAX(SyncVersion) FROM dbo.ChunkSyncLog);
    DECLARE @now  BIGINT = CHANGE_TRACKING_CURRENT_VERSION();

    UPDATE qe
    SET chunk      = n.new_chunk,
        embeddings = AI_GENERATE_EMBEDDINGS(n.new_chunk USE MODEL ollama)
    FROM dbo.QuestionEmbeddings qe
    JOIN CHANGETABLE(CHANGES dbo.Posts, @last) ct ON ct.Id = qe.PostId
    JOIN dbo.Posts p                               ON p.Id  = qe.PostId
    CROSS APPLY (SELECT p.Title + N' ' +
        REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'') AS new_chunk) n
    WHERE ct.SYS_CHANGE_OPERATION = 'U'
      AND qe.chunk <> n.new_chunk;

    SELECT @@ROWCOUNT AS chunks_refreshed;

    INSERT dbo.ChunkSyncLog VALUES (@now, SYSDATETIME());
END;
GO

-- 7. Maintenance window: read-only while the index exists (Msg 42231), so
--    same 4a drop, load, rebuild cycle.
DROP INDEX IF EXISTS vec_idx ON dbo.QuestionEmbeddings;
GO
EXEC dbo.refresh_changed_chunks;
GO
CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (metric = 'cosine', type = 'diskann', MAXDOP = 8);
GO

-- 8. Fresh: nothing stale, vector matches its text, search finds the
--    row by its new meaning.
SELECT COUNT(*) AS stale_rows FROM dbo.stale_embeddings;

DECLARE @text NVARCHAR(MAX) = (SELECT chunk FROM dbo.QuestionEmbeddings WHERE PostId = 477816);
DECLARE @v    VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@text USE MODEL ollama);
SELECT PostId,
       VECTOR_DISTANCE('cosine', embeddings, @v) AS distance_to_its_current_text
FROM dbo.QuestionEmbeddings
WHERE PostId = 477816;
GO

EXEC dbo.find_similar_questions @prompt = N'how do I undo my last git commit?', @top = 5;
GO

-- 9. Log the app's search_path; alert on 'kNN' outside a maintenance window.
--    More checks: optional Appendix F.


/* =============================================================================
   SECTION 5: THE FULL RAG ARCHITECTURE: WHAT HAPPENS WHEN THE APP RUNS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   THE FINALE: run the app
   -----------------------------------------------------------------------------
       docker compose --profile app up rag-app-ui      → http://localhost:8501

   Ask one question (about 10 seconds on my M2); the answer shows search path and
   retrieval time. The app connects as rag_app, makes two calls, sees no vector:

       EXEC dbo.find_similar_questions @prompt = ?, @top = ?
       EXEC dbo.get_top_answer @question_post_id = ?

   Browser fails:
       docker compose run --rm rag-app python demos/rag-app.py "how do I undo my last git commit?"
----------------------------------------------------------------------------- */


/* =============================================================================
   REHEARSAL RESET: run after the demo to put the data back
   =============================================================================
   Restores the title 4b rewrote, re-embeds it in a maintenance window, turns
   Change Tracking off.
   ============================================================================= */

USE [StackOverflow];
GO
UPDATE dbo.Posts SET Title = N'What is the correct JSON content type?' WHERE Id = 477816;
GO
DROP INDEX IF EXISTS vec_idx ON dbo.QuestionEmbeddings;
GO
EXEC dbo.refresh_changed_chunks;
GO
CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (metric = 'cosine', type = 'diskann', MAXDOP = 8);
GO
IF EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.Posts'))
    ALTER TABLE dbo.Posts DISABLE CHANGE_TRACKING;
GO
IF EXISTS (SELECT 1 FROM sys.change_tracking_databases WHERE database_id = DB_ID())
    ALTER DATABASE [StackOverflow] SET CHANGE_TRACKING = OFF;
GO
DROP TABLE IF EXISTS dbo.ChunkSyncLog;
GO
SELECT COUNT(*) AS stale_rows FROM dbo.stale_embeddings;
GO
