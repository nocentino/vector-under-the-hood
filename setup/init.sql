SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  setup/init.sql: one-shot, idempotent database setup
=============================================================================

  The sql-init container runs this for you on the first stack start.
  It's safe to re-run. Every block checks whether its object already exists.

  Here's what it does:
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
  DON'T alter these objects during a live demo. The demo files assume this
  baseline exists. Use ./stop.sh --wipe if you want a full reset.
=============================================================================
*/


/* =============================================================================
   STEP 0: Enable outbound HTTPS
   ============================================================================= */

-- SQL Server 2025 can make outbound REST calls to external AI endpoints.
-- You have to turn this server-level switch ON before CREATE EXTERNAL MODEL works.
EXEC sp_configure 'external rest endpoint enabled', 1;
GO
RECONFIGURE WITH OVERRIDE;
GO


/* =============================================================================
   STEP 1: Restore the StackOverflow database
   ============================================================================= */

USE [master];
GO

-- If the database is already there, skip the restore (idempotent on re-run).
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
    PRINT 'StackOverflow database already exists, skipping restore.';
GO

-- The backup comes back at an older compatibility level, and AI_GENERATE_CHUNKS
-- (Demo 03) needs 170 or higher.
ALTER DATABASE [StackOverflow] SET COMPATIBILITY_LEVEL = 170;
GO


/* =============================================================================
   STEP 2: Register the Ollama embedding model
   ============================================================================= */

USE [StackOverflow];
GO

-- CREATE EXTERNAL MODEL is a named pointer to the embedding endpoint.
-- LOCATION is the NGINX TLS reverse proxy (model-web:443) in front of host
-- Ollama, because SQL Server 2025 requires HTTPS for external calls.
-- Point this object at a different Ollama model and you've changed models
-- without touching a single query in the demo files (see Demo 03 Section 4b).
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
    PRINT 'EXTERNAL MODEL ollama already exists, skipping.';
GO

-- Quick connectivity check. If this SELECT errors, NGINX or Ollama isn't
-- reachable, and the sql-init container logs the error and exits non-zero.
PRINT 'Testing embedding endpoint connectivity...';
SELECT AI_GENERATE_EMBEDDINGS(N'connectivity test' USE MODEL ollama) AS test_vector;
PRINT 'Embedding endpoint reachable.';
GO


/* =============================================================================
   STEP 3: EMBEDDINGS filegroup and data file
   ============================================================================= */

-- QuestionEmbeddings gets its own filegroup and its own .ndf file. That keeps
-- vector I/O (large, sequential during index build and graph traversal) apart
-- from the OLTP I/O on PRIMARY.
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
   STEP 4: QuestionEmbeddings satellite table
   ============================================================================= */

-- VECTOR(768) is a real column type. It's not a string and it's not JSON.
-- chunk holds the exact text we embedded, so you can return it as RAG
-- context without joining back to Posts at retrieval time.
-- The table lives on the EMBEDDINGS filegroup, apart from Posts.
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
   STEP 5: Generate embeddings (incremental, skips rows already embedded)
   ============================================================================= */

-- Turn on preview features so the CREATE VECTOR INDEX in Step 6 works.
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

-- Embed the top 1,000 questions by community score. Each chunk is the
-- question title plus its cleaned tag string. That's the text the embedding
-- model turns into a 768-dimensional vector.
--
-- Every ./start.sh reruns this script, so this step only tops the table up
-- to 1,000 rows, and only when there's no vector index (the table is
-- READ-ONLY while one exists). After expand-embeddings.sh it does nothing.
-- The INSERT is dynamic SQL because Msg 42231 fires at compile time, even
-- inside an IF branch that never runs.
PRINT 'Generating embeddings for top 1,000 questions (if needed)...';
GO

DECLARE @need INT = 1000 - (SELECT COUNT(*) FROM dbo.QuestionEmbeddings);

IF @need > 0
   AND NOT EXISTS (SELECT 1 FROM sys.vector_indexes
                   WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings'))
    EXEC sp_executesql N'
    INSERT INTO dbo.QuestionEmbeddings (PostId, chunk, embeddings)
    SELECT
        q.Id,
        q.chunk,
        AI_GENERATE_EMBEDDINGS(q.chunk USE MODEL ollama) AS embeddings
    FROM (
        SELECT TOP (@need)
            p.Id,
            p.Title + N'' '' +
                REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''''), N''><'', N'' ''), N''<'', N''''), N''>'', N'''')
                AS chunk
        FROM dbo.Posts p
        WHERE p.PostTypeId = 1
          AND p.Title      IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM dbo.QuestionEmbeddings qe WHERE qe.PostId = p.Id
          )
        ORDER BY p.Score DESC
    ) AS q;', N'@need INT', @need = @need;
GO

DECLARE @embedded INT = (SELECT COUNT(*) FROM dbo.QuestionEmbeddings);
PRINT 'Embeddings complete. Rows in QuestionEmbeddings: ' + CAST(@embedded AS NVARCHAR(10));
GO


/* =============================================================================
   STEP 6: Build the DiskANN vector index
   ============================================================================= */

-- This index is what gives you Approximate Nearest Neighbor (ANN) search via
-- VECTOR_SEARCH. Demo 02 compares ANN vs. exact kNN IO stats and recall.
-- There's no MAXDOP here: SQL Server 2025 ignores it for vector index builds
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
    PRINT 'Vector index vec_idx already exists, skipping.';
GO


/* =============================================================================
   STEP 7a: Semantic search stored procedure
   ============================================================================= */

-- The main retrieval procedure for rag-app.py and Demo 03.
-- You pass in plain text and SQL Server embeds it via AI_GENERATE_EMBEDDINGS.
-- It returns only scalar columns (no VECTOR type), so the app gets clean rows.
-- It uses the DiskANN index when it exists and falls back to exact kNN while
-- the index is dropped for maintenance. @search_mode defaults to AUTO; ANN
-- requires an index, and KNN forces the exact scan. Create it while vec_idx
-- exists, since CREATE PROCEDURE fails with Msg 42227 without the index.
CREATE OR ALTER PROCEDURE dbo.find_similar_questions
    @prompt NVARCHAR(MAX),
    @top    INT = 5,
    @search_mode VARCHAR(10) = 'AUTO'
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

    DECLARE @query_vector VECTOR(768) =
        AI_GENERATE_EMBEDDINGS(@prompt USE MODEL ollama);

    IF @mode = 'ANN' OR (@mode = 'AUTO' AND @has_index = 1)
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
   STEP 7b: Top-answer retrieval stored procedure
   ============================================================================= */

-- Returns the accepted answer (if there is one) or the highest-scored answer
-- for a question. rag-app.py calls it after find_similar_questions so the RAG
-- context has real answer text in it.
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
   STEP 8: Least-privilege logins
   ============================================================================= */

USE [master];
GO

-- ── rag_app: the Python RAG application login ─────────────────────────────
-- rag-app.py connects as this login. It can only EXECUTE the two search
-- procedures and the external model (AI_GENERATE_EMBEDDINGS inside the procs
-- needs that). It can't SELECT any table directly or INSERT/UPDATE/DELETE anything.
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
-- Gets VIEW SERVER STATE for DMV queries.
-- It's here so you can run Demo 02's index build monitoring queries as this login.
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
