SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  setup/init.sql — one-shot idempotent database initialization
=============================================================================

  Run automatically by the sql-init container on first stack start.
  Safe to re-run: every block is guarded by an existence check.

  What this script does:
    0. Enable outbound HTTPS (external REST endpoint)
    1. Restore the StackOverflowMini database
    2. Register the Ollama embedding model as an EXTERNAL MODEL
    3. Create the EMBEDDINGS filegroup + data file
    4. Create the QuestionEmbeddings satellite table on that filegroup
    5. Generate embeddings for the top 1,000 questions (incremental)
    6. Build the DiskANN CREATE VECTOR INDEX
    7. Create the application views and stored procedures
    8. Create least-privilege logins for the demo SQL client + rag-app.py

  The demo SQL files (01/02/03) walk through this state live.
  DO NOT alter the objects created here during a live demo — the demo files
  assume this baseline exists. Use ./stop.sh --wipe to reset completely.
=============================================================================
*/


/* =============================================================================
   STEP 0 — Enable outbound HTTPS
   ============================================================================= */

-- SQL Server 2025 can make outbound REST calls to external AI endpoints.
-- This server-level switch must be ON before CREATE EXTERNAL MODEL works.
EXEC sp_configure 'external rest endpoint enabled', 1;
GO
RECONFIGURE WITH OVERRIDE;
GO


/* =============================================================================
   STEP 1 — Restore the StackOverflow database
   ============================================================================= */

USE [master];
GO

-- Skip the restore if the database already exists (idempotent on re-run).
IF DB_ID('StackOverflow') IS NULL
BEGIN
    PRINT 'Restoring StackOverflowMini database...';
    RESTORE DATABASE [StackOverflow]
    FROM DISK = '/var/opt/mssql/backups/StackOverflowMini.bak'
    WITH
        MOVE 'StackOverflowMini'     TO '/var/opt/mssql/data/StackOverflow.mdf',
        MOVE 'StackOverflowMini_log' TO '/var/opt/mssql/data/StackOverflow_log.ldf',
        REPLACE,
        NOUNLOAD,
        STATS = 25;
    PRINT 'Restore complete.';
END
ELSE
    PRINT 'StackOverflow database already exists — skipping restore.';
GO

-- The backup restores at an older compatibility level. AI_GENERATE_CHUNKS
-- (Demo 03) needs 170 or higher.
ALTER DATABASE [StackOverflow] SET COMPATIBILITY_LEVEL = 170;
GO


/* =============================================================================
   STEP 2 — Register the Ollama embedding model
   ============================================================================= */

USE [StackOverflow];
GO

-- CREATE EXTERNAL MODEL is a named pointer to the embedding endpoint.
-- LOCATION is the NGINX TLS reverse proxy (model-web:443) that sits in
-- front of host Ollama. SQL Server 2025 requires HTTPS for external calls.
-- Point this object at a different Ollama model to change models without
-- touching any query in the demo files (see Demo 03 Section 4c).
IF NOT EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'ollama')
BEGIN
    PRINT 'Creating EXTERNAL MODEL ollama...';
    CREATE EXTERNAL MODEL ollama
    WITH (
        LOCATION   = 'https://model-web:443/api/embed',
        API_FORMAT = 'Ollama',
        MODEL_TYPE = EMBEDDINGS,
        MODEL      = 'nomic-embed-text'   -- 768-dimension vectors
    );
    PRINT 'EXTERNAL MODEL created.';
END
ELSE
    PRINT 'EXTERNAL MODEL ollama already exists — skipping.';
GO

-- Quick connectivity check: if this SELECT errors, NGINX or Ollama is not
-- reachable. The sql-init container logs the error and exits non-zero.
PRINT 'Testing embedding endpoint connectivity...';
SELECT AI_GENERATE_EMBEDDINGS(N'connectivity test' USE MODEL ollama) AS test_vector;
PRINT 'Embedding endpoint reachable.';
GO


/* =============================================================================
   STEP 3 — EMBEDDINGS filegroup and data file
   ============================================================================= */

-- The QuestionEmbeddings table lives on its own filegroup backed by a
-- dedicated .ndf file. This separates vector I/O (large, sequential during
-- index build and graph traversal) from operational OLTP I/O on PRIMARY.
IF NOT EXISTS (SELECT 1 FROM sys.filegroups WHERE name = N'EMBEDDINGS')
BEGIN
    PRINT 'Adding EMBEDDINGS filegroup...';
    ALTER DATABASE [StackOverflow] ADD FILEGROUP [EMBEDDINGS];
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_files WHERE name = N'StackOverflow_Embeddings')
BEGIN
    PRINT 'Adding StackOverflow_Embeddings.ndf data file...';
    ALTER DATABASE [StackOverflow] ADD FILE
    (
        NAME       = 'StackOverflow_Embeddings',
        FILENAME   = '/var/opt/mssql/data/StackOverflow_Embeddings.ndf',
        SIZE       = 1GB,
        FILEGROWTH = 64MB
    ) TO FILEGROUP [EMBEDDINGS];
END
GO


/* =============================================================================
   STEP 4 — QuestionEmbeddings satellite table
   ============================================================================= */

-- VECTOR(768) is a first-class column type — not a string, not JSON.
-- chunk stores the exact text that was embedded so we can return it as
-- RAG context without re-joining to Posts at retrieval time.
-- The table is stored on the EMBEDDINGS filegroup (separate from Posts).
IF OBJECT_ID('dbo.QuestionEmbeddings', 'U') IS NULL
BEGIN
    PRINT 'Creating dbo.QuestionEmbeddings table...';
    CREATE TABLE dbo.QuestionEmbeddings
    (
        PostId     INT           NOT NULL,
        embeddings VECTOR(768)   NOT NULL,
        chunk      NVARCHAR(4000) NOT NULL,
        CONSTRAINT PK_QuestionEmbeddings PRIMARY KEY (PostId)
    ) ON [EMBEDDINGS];
END
GO


/* =============================================================================
   STEP 5 — Generate embeddings (incremental — skips already-embedded rows)
   ============================================================================= */

-- Enable preview features so the CREATE VECTOR INDEX in Step 6 succeeds.
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

-- Embed the top 1,000 questions by community score. Each row's chunk is
-- the question title concatenated with its cleaned tag string — the text
-- that the embedding model turns into a 768-dimensional vector.
--
-- The NOT EXISTS guard makes this resumable: safe to kill and restart,
-- and a no-op once all 1,000 rows are present.
--
-- NOTE on SQL Server 2025 earlier-version DiskANN: the table is READ-ONLY
-- while a vector index exists. The index is created in Step 6 AFTER this
-- bulk INSERT, so Step 5 always runs against an unindexed table.
PRINT 'Generating embeddings for top 1,000 questions (incremental)...';
GO

;WITH top_questions AS (
    SELECT TOP (1000)
        p.Id,
        p.Title + N' ' +
            REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'')
            AS chunk
    FROM dbo.Posts p
    WHERE p.PostTypeId = 1
      AND p.Title      IS NOT NULL
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
FROM top_questions q;
GO

DECLARE @embedded INT = (SELECT COUNT(*) FROM dbo.QuestionEmbeddings);
PRINT 'Embeddings complete. Rows in QuestionEmbeddings: ' + CAST(@embedded AS NVARCHAR(10));
GO


/* =============================================================================
   STEP 6 — Build the DiskANN vector index
   ============================================================================= */

-- The index enables Approximate Nearest Neighbor (ANN) search via
-- VECTOR_SEARCH. Demo 02 compares ANN vs. exact kNN IO stats and recall.
-- MAXDOP is left off: SQL Server 2025 ignores it for vector index builds
-- (documented known issue).
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  name      = 'vec_idx'
      AND  object_id = OBJECT_ID('dbo.QuestionEmbeddings')
)
BEGIN
    PRINT 'Building DiskANN vector index (vec_idx)...';
    CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
    WITH (metric = 'cosine', type = 'diskann');
    PRINT 'Vector index built.';
END
ELSE
    PRINT 'Vector index vec_idx already exists — skipping.';
GO


/* =============================================================================
   STEP 7a — Application views
   ============================================================================= */

-- A tidy, agent-friendly view over Questions. Only useful columns;
-- tags are cleaned from <tag1><tag2> XML form to "tag1, tag2" text.
CREATE OR ALTER VIEW dbo.vQuestions AS
SELECT
    p.Id,
    p.Title,
    REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), '><', ', '), '<', ''), '>', '') AS Tags,
    p.Score,
    p.ViewCount,
    p.AnswerCount,
    p.CreationDate,
    p.OwnerUserId
FROM dbo.Posts p
WHERE p.PostTypeId = 1;
GO


/* =============================================================================
   STEP 7b — Semantic search stored procedure
   ============================================================================= */

-- Primary retrieval procedure used by rag-app.py and Demo 03.
-- Accepts plain text; SQL Server handles embedding via AI_GENERATE_EMBEDDINGS.
-- Returns only scalar columns (no VECTOR type) — clean for application use.
-- Uses the DiskANN index when it exists and falls back to exact kNN while the
-- index is dropped for maintenance. Must be created while vec_idx exists:
-- CREATE PROCEDURE fails with Msg 42227 if VECTOR_SEARCH has no index.
CREATE OR ALTER PROCEDURE dbo.find_similar_questions
    @prompt NVARCHAR(MAX),
    @top    INT = 5
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @query_vector VECTOR(768) =
        AI_GENERATE_EMBEDDINGS(@prompt USE MODEL ollama);

    IF EXISTS (SELECT 1 FROM sys.vector_indexes
               WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings'))
        SELECT
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
            TOP_N      = @top
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


/* =============================================================================
   STEP 7c — Top-answer retrieval stored procedure
   ============================================================================= */

-- Returns the accepted answer (preferred) or highest-scored answer for a
-- given question. Called by rag-app.py after find_similar_questions to
-- populate the RAG context with actual answer text.
CREATE OR ALTER PROCEDURE dbo.get_top_answer
    @question_post_id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1)
        a.Id            AS answer_id,
        a.Body          AS answer_body,
        a.Score         AS answer_score,
        a.CreationDate  AS answer_date
    FROM dbo.Posts a
    WHERE a.PostTypeId = 2
      AND a.ParentId   = @question_post_id
    ORDER BY
        CASE WHEN a.Id = (
            SELECT AcceptedAnswerId FROM dbo.Posts WHERE Id = @question_post_id
        ) THEN 0 ELSE 1 END,
        a.Score DESC;
END;
GO


/* =============================================================================
   STEP 8 — Least-privilege logins
   ============================================================================= */

USE [master];
GO

-- ── rag_app: the Python RAG application login ─────────────────────────────
-- Used by rag-app.py. Can only EXECUTE the two search procedures and the
-- external model (needed for AI_GENERATE_EMBEDDINGS inside the procs).
-- Cannot SELECT any table directly, cannot INSERT/UPDATE/DELETE anything.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'rag_app')
    CREATE LOGIN rag_app
    WITH PASSWORD        = 'RagP@ss2025!',
         CHECK_EXPIRATION = OFF,
         CHECK_POLICY     = OFF;
GO

USE [StackOverflow];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'rag_app')
    CREATE USER rag_app FOR LOGIN rag_app;
GO
GRANT EXECUTE ON dbo.find_similar_questions TO rag_app;
GRANT EXECUTE ON dbo.get_top_answer         TO rag_app;
GRANT EXECUTE ON EXTERNAL MODEL::ollama     TO rag_app;
GRANT VIEW DEFINITION ON dbo.QuestionEmbeddings TO rag_app;  -- lets the proc see vec_idx in sys.vector_indexes
GO

USE [master];
GO

-- ── dba_monitor: read-only monitoring login ───────────────────────────────
-- Matches the faststart repo — grants VIEW SERVER STATE for DMV queries.
-- Included so Demo 02's index build monitoring queries run under this login.
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'dba_monitor')
    CREATE LOGIN dba_monitor
    WITH PASSWORD        = 'MonitorP@ss123!',
         CHECK_EXPIRATION = OFF,
         CHECK_POLICY     = OFF;
GO
GRANT VIEW SERVER STATE   TO dba_monitor;
GRANT VIEW ANY DATABASE   TO dba_monitor;
GRANT VIEW ANY DEFINITION TO dba_monitor;
GO

USE [StackOverflow];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'dba_monitor')
    CREATE USER dba_monitor FOR LOGIN dba_monitor;
GO
GRANT VIEW DATABASE STATE TO dba_monitor;
GRANT VIEW DEFINITION     TO dba_monitor;
GO

PRINT '=======================================================================';
PRINT 'Setup complete.';
PRINT '  StackOverflow is restored, vectorized, and indexed.';
PRINT '  Stored procedures: dbo.find_similar_questions, dbo.get_top_answer';
PRINT '  Logins: rag_app, dba_monitor';
PRINT '  Open the demo files in your SQL client and follow along.';
PRINT '=======================================================================';
GO
