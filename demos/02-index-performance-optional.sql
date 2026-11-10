SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production
  Demo 02 optional deep dives

  Run after demos/02-index-performance.sql. Appendices follow its order:
    A. Index build resource cost         (extends 1 and 2a)
    B. Duplicate embeddings              (data quality first)
    C. Filtered search                   (behind 3b)
    D. Dimensionality constraints        (behind Appendix L)
    E. Latest-version DiskANN            (Azure)
    F. Measurement harnesses             (Demo 2's numbers)
    G. Walk the graph by hand            (extends 1c; needs the DAC)
    H. What DiskANN is                   (behind 1)
    I. Which DiskANN version is this?    (after 1c)
    J. kNN vs ANN at 10,000 rows         (before 2b)
    K. Recall at 10,000 rows             (before Appendix M)
    L. The rest of the documented limits (after 3b)
    M. Recall on one question at 1M rows (was Demo 2 - 3a)
=============================================================================
*/

USE [StackOverflow];
GO

/* -----------------------------------------------------------------------------
    APPENDIX A. Index build resource cost at scale
   -----------------------------------------------------------------------------
   Measured on 100,000 vectors, 12 cores, CU10:

     - CPU: every core by default. Known-issues page says MAXDOP is ignored;
       the index option works, the scoped setting doesn't:
         default                       135 to 140 s, DOP 12
         WITH (..., MAXDOP = 4)        237 s, DOP 4
         WITH (..., MAXDOP = 1)        908 s, DOP 1
         database scoped MAXDOP = 1    135 s, DOP 12 (ignored)
     - Memory: grant scales with DOP (31 MB at 1, 63 MB at 4, 121 MB at 12);
       the build used ~25 MB at every DOP.
     - tempdb: a few MB at most.
     - Concurrency: readers work (shared table lock); INSERT and UPDATE fail
       with Msg 42231 from the start; VECTOR_SEARCH fails with Msg 42227 until
       it finishes. A 40 ms exact query ran 700 to 900 ms at the default DOP,
       ~250 ms at MAXDOP 4.
     - Storage: graph tables (1c) grow linearly: 26 MB at 100,000 vectors, 261 MB at 1,000,000.

   Watch a build from a SECOND window (query below).
----------------------------------------------------------------------------- */

-- Window 1 (uncomment to run):
/*
DROP INDEX IF EXISTS vec_idx ON dbo.QuestionEmbeddings;
CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (metric = 'cosine', type = 'diskann', MAXDOP = 4);
*/

SELECT
    r.session_id,
    r.command,
    r.status,
    r.percent_complete,
    r.cpu_time,
    r.total_elapsed_time    AS elapsed_ms,
    r.reads,
    r.writes,
    SUBSTRING(t.text, 1, 120) AS query_snippet
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE t.text LIKE '%CREATE VECTOR INDEX%'
  AND r.session_id <> @@SPID;
GO

-- Post-build: table vs. graph (1c).
SELECT
    (SELECT SUM(au.total_pages) * 8 / 1024.0
     FROM sys.partitions p
     JOIN sys.allocation_units au ON au.container_id = p.hobt_id
     WHERE p.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
       AND p.index_id = 1)                                AS table_MB,
    (SELECT SUM(au.total_pages) * 8 / 1024.0
     FROM sys.internal_tables it
     JOIN sys.partitions p        ON p.object_id = it.object_id
     JOIN sys.allocation_units au ON au.container_id = p.hobt_id
     WHERE it.parent_object_id = OBJECT_ID('dbo.QuestionEmbeddings')) AS graph_MB;
GO

/* =============================================================================
   APPENDIX B. DUPLICATE EMBEDDINGS
   =============================================================================

   Docs: don't index many duplicate vectors; they crowd real neighbors out
   and waste build time. Deduplicate first. VECTOR can't be grouped, so group
   by the embedded text (same chunk, same model, same vector).
   ============================================================================= */

SELECT
    COUNT(*)                                         AS total_rows,
    COUNT(DISTINCT qe.chunk)                         AS distinct_chunks,
    COUNT(*) - COUNT(DISTINCT qe.chunk)              AS duplicate_rows
FROM dbo.QuestionEmbeddings qe;
GO

SELECT TOP (10) qe.chunk, COUNT(*) AS copies
FROM dbo.QuestionEmbeddings qe
GROUP BY qe.chunk
HAVING COUNT(*) > 1
ORDER BY copies DESC;
GO

/* -----------------------------------------------------------------------------
    APPENDIX C. Filtered search (no predicate pushdown into the graph)
   -----------------------------------------------------------------------------
   VECTOR_SEARCH returns TOP_N candidates from the whole graph and THEN
   WHERE filters them, so a selective filter can reject every candidate:
   zero rows though exact kNN finds matches. On-prem fix: oversample (bigger
   TOP_N). The latest-version index filters during the walk (Appendix E.3).
----------------------------------------------------------------------------- */

DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div vertically and horizontally';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

-- Version 1: TOP_N = 5 plus a selective filter. May return fewer than 5 rows:
PRINT '--- ANN: TOP_N = 5, Score > 500 (tight filter) ---';
SELECT
    t.PostId,
    p.Title,
    s.distance,
    p.Score
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 5     -- 5 candidates, THEN WHERE runs
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 500    -- post-filter: may kill all 5
ORDER BY s.distance;
GO

-- Version 2: TOP_N = 50, same filter:
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div vertically and horizontally';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- ANN: TOP_N = 50, Score > 500 (oversampled) ---';
SELECT TOP (5)
    t.PostId,
    p.Title,
    s.distance,
    p.Score
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 50    -- 50 candidates, filter, best 5
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 500
ORDER BY s.distance;
GO

-- Version 3: exact kNN, same filter. The ground truth:
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div vertically and horizontally';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- Exact kNN: Score > 500 (ground truth) ---';
SELECT TOP (5)
    p.Id,
    p.Title,
    p.Score,
    VECTOR_DISTANCE('cosine', @search_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
WHERE p.Score > 500    -- full scan, so always correct
ORDER BY distance;
GO

-- TAKEAWAY: oversample TOP_N by the inverse of the pass rate (1 in 10 rows
-- passes: TOP_N = 10 × K).

-- Demo 2 - 3b taken apart. Score > 5,000 matches 21 of 10,000 questions.
-- Without WHERE, the raw TOP_N = 5 candidates:
DECLARE @search_vector VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'how do I center a div in CSS' USE MODEL ollama);

PRINT '--- ANN TOP_N = 5, no filter: the raw candidates ---';
SELECT t.PostId, p.Score, s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 5
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
ORDER BY s.distance;
-- All 5 score under 5,000 (one run: 596, 842, 3549, 428, 728): the filter
-- works, no high-score row made the list.
GO

-- Ground truth: the rows exist.
DECLARE @search_vector VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'how do I center a div in CSS' USE MODEL ollama);

PRINT '--- Exact kNN, Score > 5000 ---';
SELECT TOP(5) qe.PostId, p.Score,
    VECTOR_DISTANCE('cosine', @search_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
WHERE p.Score > 5000
ORDER BY distance;
-- 5 rows (Scores 6,591 to 17,388) at distance ~0.49 to 0.57, far past the
-- TOP_N = 5 candidates (0.11 to 0.15). About 1,700 rows are closer than the
-- furthest match, so reaching it takes TOP_N = 2,500.
GO


/* -----------------------------------------------------------------------------
    APPENDIX D. Dimensionality constraints
   -----------------------------------------------------------------------------
   VECTOR supports 1 to 1,998 dimensions as float32 and 1 to 3,996 as
   float16 (Demo 01 optional Appendix A):

     nomic-embed-text             768 dimensions   (this demo)
     mxbai-embed-large           1024 dimensions
     text-embedding-3-small      1536 dimensions
     text-embedding-ada-002      1536 dimensions
     text-embedding-3-large      3072 dimensions  → needs float16!

   float16 doubles the ceiling:
     VECTOR(3072)            → error on float32 (exceeds 1,998)
     VECTOR(3072, float16)   → works (≤ 3,996), uses 6,144 bytes

   An index needs a fixed VECTOR(n). Changing models (768 to 1,536) means a
   new column, re-embedding EVERY row (different models aren't comparable),
   and a rebuild.
----------------------------------------------------------------------------- */

-- The current column (sys.columns metadata):
SELECT
    c.name,
    t.name                  AS type_name,
    c.vector_dimensions     AS dimensions,        -- new in SQL Server 2025
    c.vector_base_type_desc AS base_type          -- float32 | float16
FROM sys.columns c
JOIN sys.types   t ON t.user_type_id = c.user_type_id    -- use user_type_id to avoid duplicates for VECTOR columns
WHERE c.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
  AND t.name      = 'vector';
GO

-- One past the float32 max. Msg 2717 is a compile error, so it runs in its
-- own scope to be caught.
BEGIN TRY
    EXEC (N'CREATE TABLE #dim_test ( v VECTOR(1999) );');
    PRINT 'VECTOR(1999) created: current limit is above 1998.';
END TRY
BEGIN CATCH
    PRINT 'Error: ' + ERROR_MESSAGE();
    PRINT '=> VECTOR(1999) exceeds the float32 maximum (1,998 dims).';
    PRINT '   Use VECTOR(1999, float16) to go beyond 1,998 dimensions.';
END CATCH;
GO

-- float16 allows up to 3,996 dims, enough for text-embedding-3-large (3072):
BEGIN TRY
    CREATE TABLE #dim_float16 ( v VECTOR(3072, float16) );
    PRINT 'VECTOR(3072, float16) created: float16 ceiling is 3,996 dims.';
    DROP TABLE IF EXISTS #dim_float16;
END TRY
BEGIN CATCH
    PRINT 'Error: ' + ERROR_MESSAGE();
END CATCH;
GO

-- The float32 maximum (1998):
BEGIN TRY
    CREATE TABLE #dim_max ( v VECTOR(1998) );
    PRINT 'VECTOR(1998) created: max float32 dimensions in SQL Server 2025.';
    DROP TABLE IF EXISTS #dim_max;
END TRY
BEGIN CATCH
    PRINT 'Error: ' + ERROR_MESSAGE();
END CATCH;
GO

/* =============================================================================
    APPENDIX E. LATEST-VERSION DiskANN: WHAT'S NEW (Azure SQL DB / Fabric)
   =============================================================================

   The latest-version index is GA on Azure SQL Database, SQL database in
   Fabric, and Managed Instance (Always-up-to-date). SQL Server 2025 runs the
   EARLIER-VERSION index (preview); no date given for a change.
     https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql

   Earlier-version vs. latest-version summary: table at the end of E.5.
   ============================================================================= */


/* -----------------------------------------------------------------------------
    E.1 Check which DiskANN version you're running
   -----------------------------------------------------------------------------
   Check the Version key in build_parameters: 3 is latest, no key is earlier. Don't test for sys.dm_db_vector_indexes:
   docs list it for SQL Server 2025, but CU10 lacks it.
----------------------------------------------------------------------------- */

SELECT
    OBJECT_NAME(v.object_id)                        AS table_name,
    v.name                                          AS index_name,
    JSON_VALUE(v.build_parameters, '$.Version')     AS index_version,
    CASE
        WHEN JSON_VALUE(v.build_parameters, '$.Version') = '3'
        THEN 'Latest-version DiskANN (full DML + iterative filtering)'
        ELSE 'Earlier-version DiskANN (read-only table, post-filtering)'
    END                                             AS diskann_version
FROM sys.vector_indexes v;
GO

-- This container: no Version key, earlier-version.


/* -----------------------------------------------------------------------------
    E.2 Latest-version query syntax: SELECT TOP (N) WITH APPROXIMATE
   -----------------------------------------------------------------------------
   Earlier-version: TOP_N = 10 inside VECTOR_SEARCH. Latest-version: SELECT
   TOP (10) WITH APPROXIMATE ..., no TOP_N parameter (examples below).

   WITH APPROXIMATE lets the optimizer pick index or exact kNN by cost;
   without it, TOP (N) ... ORDER BY distance runs as exact kNN.

   The docs' rules:
     - It needs VECTOR_SEARCH in the query and an ORDER BY (Msg 42248).
     - ORDER BY must be the distance column only, ascending (Msg 42271).
       Sort by anything else in an outer query.
     - FORCE_ANN_ONLY (table hint on VECTOR_SEARCH) forces the index.

   MIGRATION WARNING: TOP_N against a latest-version index fails with Msg
   42274, so update queries BEFORE migrating. On CU10, WITH APPROXIMATE fails
   with Msg 102.
----------------------------------------------------------------------------- */

-- Earlier-version (works here):
DECLARE @sv1 VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama);

PRINT '--- Earlier-version syntax (TOP_N) ---';
SELECT
    t.PostId,
    p.Title,
    s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @sv1,
    METRIC     = 'cosine',
    TOP_N      = 5
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
ORDER BY s.distance;
GO

-- Latest-version syntax (Azure SQL DB, Fabric, MI Always-up-to-date only);
-- swap <your_external_model> for a model registered there.
/*
DECLARE @sv2 VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL <your_external_model>);

PRINT '--- Latest-version syntax (SELECT TOP N WITH APPROXIMATE) ---';
SELECT TOP (5) WITH APPROXIMATE
    t.PostId,
    p.Title,
    s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @sv2,
    METRIC     = 'cosine'
    -- no TOP_N
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
ORDER BY s.distance;
*/


/* -----------------------------------------------------------------------------
    E.3 Latest-version: iterative filtering
   -----------------------------------------------------------------------------
   Latest-version: predicates apply DURING the walk; the engine searches
   until it has K qualifying rows or runs out of graph. No oversampling.

   Latest-version (Azure SQL DB): the E.2 query plus WHERE p.Score > 500. The
   filter runs INSIDE the graph walk: no TOP_N, no oversampling.

   Simpler and more correct: if 5 matching rows exist, you get 5.
----------------------------------------------------------------------------- */

-- The on-prem workaround from Appendix C:
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div vertically and horizontally';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- On-prem: oversample TOP_N = 50 to survive Score > 500 filter ---';
SELECT TOP (5)
    t.PostId,
    p.Title,
    s.distance,
    p.Score
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 50    -- over-fetch to survive the post-filter
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 500
ORDER BY s.distance;
GO
-- Azure SQL DB: drop TOP_N, use SELECT TOP (5) WITH APPROXIMATE.


/* -----------------------------------------------------------------------------
    E.4 sys.dm_db_vector_indexes: background maintenance monitoring
   -----------------------------------------------------------------------------
   Latest version: DML commits immediately; a background task folds it into
   the graph (this DMV).
     https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-vector-indexes-transact-sql

   Key columns:
     graph_catchup_pending_percent
         Recent DML not yet folded into the graph; rises in write bursts,
         drains toward 0.
     quantized_keys_used_percent
         Percent of the quantized key space used.
     last_background_task_succeeded
         1 = last run clean. If it stays 0, read
         last_background_task_error_message.

   Needs VIEW DATABASE STATE. Don't rebuild for a brief catch-up above zero;
   rebuild when recall or latency degrades, or after replacing most of the
   embeddings.
----------------------------------------------------------------------------- */

IF OBJECT_ID('sys.dm_db_vector_indexes') IS NOT NULL
    EXEC (N'
    SELECT
        OBJECT_NAME(object_id)              AS table_name,
        index_id,
        graph_catchup_pending_percent,
        quantized_keys_used_percent,
        last_background_task_succeeded,
        last_background_task_error_message
    FROM sys.dm_db_vector_indexes
    WHERE object_id = OBJECT_ID(''dbo.QuestionEmbeddings'');');
ELSE
    PRINT 'sys.dm_db_vector_indexes does not exist on this build.';
GO


/* -----------------------------------------------------------------------------
    E.5 Migration path: earlier-version → latest-version on Azure
   -----------------------------------------------------------------------------
   Azure SQL DB indexes created before the latest version keep the old
   structure. To migrate:

     STEP 1:  Update queries FIRST (E.2).

     STEP 2:  Drop and recreate the index. The CREATE syntax is UNCHANGED.

              DROP INDEX vec_idx ON dbo.QuestionEmbeddings;

              CREATE VECTOR INDEX vec_idx
              ON dbo.QuestionEmbeddings([embeddings])
              WITH (METRIC = 'cosine', TYPE = 'diskann');
              -- That's it: the new index is latest-version.

    STEP 3:  Verify the version (Appendix E.1): 3 = latest.

   Nothing to migrate on SQL Server 2025; until the latest version
   ships on-prem, drop-insert-rebuild (Demo 03 - 4a) is the maintenance
   pattern.
----------------------------------------------------------------------------- */

-- Where each feature lives (docs, as of this build):
SELECT
    feature,
    sql_server_2025_onprem,
    azure_latest_version
FROM (VALUES
    ('Full DML (no read-only restriction)',    'Drop-insert-rebuild',      'GA'),
    ('Iterative filtering (predicate in walk)','Manual oversampling',      'GA'),
    ('SELECT TOP (N) WITH APPROXIMATE syntax', 'Not supported (use TOP_N)','GA'),
    ('sys.dm_db_vector_indexes DMV',           'Not on this build (CU5, CU10)',              'GA'),
    ('Async background index maintenance',     'Not available',            'GA'),
    ('Vector index overall',                   'Preview',                  'GA')
) AS t(feature, sql_server_2025_onprem, azure_latest_version);
-- azure_latest_version: Azure SQL DB, Fabric, MI (Always-up-to-date).


/* =============================================================================
   APPENDIX F. MEASUREMENT HARNESSES (the numbers behind Demo 2)
   =============================================================================

   ============================================================================= */

/* -----------------------------------------------------------------------------
   F.1 The ANN plan from the plan cache
   -----------------------------------------------------------------------------
   The Demo 2 - 2a query again, with a marker to find it in the cache.
----------------------------------------------------------------------------- */

DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama
);
SELECT TOP(5) /* demo-ann-plan */
    t.PostId,
    p.Title,
    s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @qv,
    METRIC     = 'cosine',
    TOP_N      = 5
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
ORDER BY s.distance;
GO

SELECT
    r.value('@NodeId',                    'INT')           AS node_id,
    r.value('@PhysicalOp',                'NVARCHAR(100)') AS physical_op,
    ROUND(r.value('@EstimateRows',        'FLOAT'), 1)     AS est_rows,
    ROUND(r.value('@EstimatedTotalSubtreeCost', 'FLOAT'), 4) AS subtree_cost
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) st
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp
CROSS APPLY qp.query_plan.nodes(
    'declare namespace x="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
     //x:RelOp') AS n(r)
WHERE st.text LIKE N'%demo-ann-plan%'                 -- the marker
  AND st.text NOT LIKE N'%dm_exec_cached_plans%'      -- not this query
ORDER BY node_id;
GO
-- EXPECTED OUTPUT (node ids can differ on your build):
--   physical_op           est_rows  subtree_cost
--   Top                        1.0        0.1355
--   Nested Loops               1.0        0.1355
--   Nested Loops               1.0        0.1322
--   Vector Index Seek          1.0        0.1289   ← DiskANN
--   Clustered Index Seek       1.0        0.0033   ← QuestionEmbeddings lookup
--   Clustered Index Seek       1.0        0.0033   ← Posts lookup
--
-- est_rows = 1.0 on the Vector Index Seek though it returns 5: don't trust
-- estimates downstream.



/* -----------------------------------------------------------------------------
   F.2 Scale: how each path grows with row count
   -----------------------------------------------------------------------------
   Embed once, then time exact kNN over the first 1,000, 2,500, 5,000, and
   10,000 rows (clustered key range, so each run reads only its slice) and
   ANN over the whole table, 10 runs each. No Ollama call in the loop, so
   it times SQL Server, not HTTP.
----------------------------------------------------------------------------- */

SET NOCOUNT ON;
DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'my git history is a mess - how do I clean it up before code review?' USE MODEL ollama);
DECLARE @results TABLE (search_path VARCHAR(4), rows_searched INT, avg_elapsed_ms DECIMAL(9,1), avg_cpu_ms DECIMAL(9,1));
DECLARE @n INT, @cutoff INT, @i INT, @t DATETIME2, @us BIGINT, @cpu0 INT, @sink INT;
DECLARE @runs INT = 10;

DECLARE @cpu_now INT;

DECLARE @sizes TABLE (n INT PRIMARY KEY);
INSERT INTO @sizes VALUES (1000), (2500), (5000), (10000);

SELECT @n = MIN(n) FROM @sizes;
WHILE @n IS NOT NULL
BEGIN
    SELECT @cutoff = MAX(PostId)
    FROM (SELECT TOP (@n) PostId FROM dbo.QuestionEmbeddings ORDER BY PostId) AS s;

    SELECT @i = 0, @us = 0;
    SELECT @cpu0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    WHILE @i < @runs
    BEGIN
        SET @t = SYSDATETIME();
        SELECT TOP (10) @sink = qe.PostId
        FROM dbo.QuestionEmbeddings qe
        WHERE qe.PostId <= @cutoff
        ORDER BY VECTOR_DISTANCE('cosine', @qv, qe.embeddings)
        OPTION (RECOMPILE);   -- a fresh plan for each slice size
        SET @us += DATEDIFF(MICROSECOND, @t, SYSDATETIME());
        SET @i += 1;
    END;
    SELECT @cpu_now = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT INTO @results VALUES ('kNN', @n, @us / 1000.0 / @runs, (@cpu_now - @cpu0) * 1.0 / @runs);

    SELECT @n = MIN(n) FROM @sizes WHERE n > @n;
END;

SELECT @i = 0, @us = 0;
SELECT @cpu0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
WHILE @i < @runs
BEGIN
    SET @t = SYSDATETIME();
    SELECT @sink = t.PostId
    FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                       SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s;
    SET @us += DATEDIFF(MICROSECOND, @t, SYSDATETIME());
    SET @i += 1;
END;
SELECT @cpu_now = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
INSERT INTO @results
SELECT 'ANN', COUNT(*), @us / 1000.0 / @runs, (@cpu_now - @cpu0) * 1.0 / @runs
FROM dbo.QuestionEmbeddings;

SELECT search_path, rows_searched, avg_elapsed_ms, avg_cpu_ms
FROM @results
ORDER BY search_path DESC, rows_searched;
GO
-- MEASURED (two runs, M2, CU10):
--   path  rows    elapsed ms   CPU ms
--   kNN    1,000     5-7         5-8
--   kNN    2,500     9-13        9-13
--   kNN    5,000    16-18       16-18
--   kNN   10,000    15          38-41   ← parallel plan: elapsed drops, CPU doesn't
--   ANN   10,000     5-6         5-6
--
--   - kNN CPU grows linearly; parallelism hides it in elapsed time on an
--     idle box, under load you pay the CPU.
--   - ANN at 10,000 rows costs about what kNN costs at 1,000.
--   - Below a few thousand rows the index isn't worth it (Appendix J).



/* -----------------------------------------------------------------------------
   F.3 Recall averaged over 100 queries, at two values of K
   -----------------------------------------------------------------------------
   100 real questions NOT in QuestionEmbeddings, embedded the same way
   (title + tags), so they look like a user's question. Appendix M uses the
   same method at 1,000,000 rows, so numbers compare. (Vectors already in
   the table flatter the index: 0.99, against 0.95 to 0.97 this way.)

   Embedding the 100 takes ~1.5 s once; searches after that are pure SQL
   Server. Compare K = 10 with K = 100, watch the worst-query column. Holds
   for THIS data, model, and build.
----------------------------------------------------------------------------- */

SET NOCOUNT ON;

DROP TABLE IF EXISTS #queries;
DROP TABLE IF EXISTS #recall;
CREATE TABLE #queries (qid INT IDENTITY PRIMARY KEY, qv VECTOR(768) NOT NULL);
CREATE TABLE #recall  (k INT, qid INT, matched INT);

-- The next 100 top-scored unembedded questions:
INSERT INTO #queries (qv)
SELECT TOP (100)
    AI_GENERATE_EMBEDDINGS(
        p.Title + N' ' +
        REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'')
        USE MODEL ollama)
FROM dbo.Posts p
WHERE p.PostTypeId = 1
  AND p.Title IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.QuestionEmbeddings qe WHERE qe.PostId = p.Id)
ORDER BY p.Score DESC;

DECLARE @ks TABLE (k INT PRIMARY KEY);
INSERT INTO @ks VALUES (10), (100);

DECLARE @k INT = (SELECT MIN(k) FROM @ks);
WHILE @k IS NOT NULL
BEGIN
    DECLARE @qid INT = 1, @maxq INT = (SELECT MAX(qid) FROM #queries);
    WHILE @qid <= @maxq
    BEGIN
        DECLARE @qv VECTOR(768) = (SELECT qv FROM #queries WHERE qid = @qid);

        WITH knn AS (
            SELECT TOP (@k) qe.PostId
            FROM dbo.QuestionEmbeddings qe
            ORDER BY VECTOR_DISTANCE('cosine', @qv, qe.embeddings)
        ),
        ann AS (
            SELECT t.PostId
            FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                               SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = @k) AS s
        )
        INSERT INTO #recall (k, qid, matched)
        SELECT @k, @qid, COUNT(*) FROM ann JOIN knn ON knn.PostId = ann.PostId;

        SET @qid += 1;
    END;
    SET @k = (SELECT MIN(k) FROM @ks WHERE k > @k);
END;

SELECT
    k,
    COUNT(*)                                          AS queries,
    CAST(AVG(matched * 1.0 / k) AS DECIMAL(5,4))      AS avg_recall_at_k,
    CAST(MIN(matched * 1.0 / k) AS DECIMAL(5,4))      AS worst_query_recall
FROM #recall
GROUP BY k
ORDER BY k;

DROP TABLE #queries;
DROP TABLE #recall;
GO

-- HOW TO READ IT:
--   avg_recall_at_k    the headline number.
--   worst_query_recall the tail the average hides. Always look at it.
--   Recall depends on your data and build: measure after every model change
--   and rebuild, test answer quality with your own questions, quote a range
--   (runs differ slightly).



/* -----------------------------------------------------------------------------
   F.4 Timing curve to 1,000,000 rows, recall, and the cost of oversampling
   -----------------------------------------------------------------------------
   Needs StackOverflowScale (bash setup/build-scale-db.sh). Queries come
   from dbo.HoldoutQueries: 100 real answers not in the table.
----------------------------------------------------------------------------- */

USE [StackOverflowScale];
GO

-- Same harness as F.2.
SET NOCOUNT ON;
DECLARE @qv VECTOR(768) = (SELECT embeddings FROM dbo.HoldoutQueries WHERE qid = 1);
DECLARE @results TABLE (search_path VARCHAR(4), rows_searched INT, avg_elapsed_ms DECIMAL(9,1), avg_cpu_ms DECIMAL(9,1));
DECLARE @n INT, @i INT, @t DATETIME2, @us BIGINT, @cpu0 INT, @cpu_now INT, @sink INT;
DECLARE @runs INT = 5;

-- PostId has gaps, so each slice ends at the PostId of its nth row.
DECLARE @sizes TABLE (n INT PRIMARY KEY, last_id INT);
INSERT INTO @sizes (n, last_id)
SELECT rn, PostId
FROM (SELECT PostId, ROW_NUMBER() OVER (ORDER BY PostId) AS rn FROM dbo.QuestionEmbeddings) x
WHERE rn IN (10000, 50000, 100000, 250000, 500000, 1000000);
DECLARE @last_id INT;

SELECT @n = MIN(n) FROM @sizes;
WHILE @n IS NOT NULL
BEGIN
    SELECT @i = 0, @us = 0, @last_id = (SELECT last_id FROM @sizes WHERE n = @n);
    SELECT @cpu0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    WHILE @i < @runs
    BEGIN
        SET @t = SYSDATETIME();
        SELECT TOP (10) @sink = s.PostId
        FROM dbo.QuestionEmbeddings s
        WHERE s.PostId <= @last_id
        ORDER BY VECTOR_DISTANCE('cosine', @qv, s.embeddings)
        OPTION (RECOMPILE);
        SET @us += DATEDIFF(MICROSECOND, @t, SYSDATETIME());
        SET @i += 1;
    END;
    SELECT @cpu_now = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    INSERT INTO @results VALUES ('kNN', @n, @us / 1000.0 / @runs, (@cpu_now - @cpu0) * 1.0 / @runs);
    SELECT @n = MIN(n) FROM @sizes WHERE n > @n;
END;

SELECT @i = 0, @us = 0;
SELECT @cpu0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
WHILE @i < @runs
BEGIN
    SET @t = SYSDATETIME();
    SELECT @sink = t.PostId
    FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                       SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s;
    SET @us += DATEDIFF(MICROSECOND, @t, SYSDATETIME());
    SET @i += 1;
END;
SELECT @cpu_now = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
INSERT INTO @results
SELECT 'ANN', COUNT(*), @us / 1000.0 / @runs, (@cpu_now - @cpu0) * 1.0 / @runs
FROM dbo.QuestionEmbeddings;

SELECT search_path, rows_searched, avg_elapsed_ms, avg_cpu_ms
FROM @results
ORDER BY search_path DESC, rows_searched;
GO

/* -----------------------------------------------------------------------------
   Recall at 1,000,000 rows, and what oversampling costs
   -----------------------------------------------------------------------------
   Queries are real answers NOT in the table (dbo.HoldoutQueries), like a
   new question.

   Three ways to get the true top 10 from the index: TOP_N = 10, 50, or 200
   (ask the graph for that many, keep the 10 closest).
   Same oversampling as Demo 2 - 3b, buying back recall, not beating a filter.

   Columns:
     avg_recall_at_10   how many of the exact top 10 the index found
     zero_queries       queries where the index found NONE of them
     avg_best_gap       how much farther the index's best hit is than the true
                        best (small = near-misses)
     avg_ann_ms         time for the ANN call alone
     avg_logical_reads  same, logical reads

   Exact kNN over a million rows is slow: this takes a few minutes.
----------------------------------------------------------------------------- */

SET NOCOUNT ON;
DROP TABLE IF EXISTS #sq;
DROP TABLE IF EXISTS #knn;
DROP TABLE IF EXISTS #ann;
DROP TABLE IF EXISTS #srecall;
CREATE TABLE #sq      (qid INT IDENTITY PRIMARY KEY, qv VECTOR(768) NOT NULL);
CREATE TABLE #knn     (Id INT NOT NULL, d FLOAT NOT NULL);
CREATE TABLE #ann     (Id INT NOT NULL, d FLOAT NOT NULL);
CREATE TABLE #srecall (top_n INT, qid INT, matched INT, exact_best FLOAT, ann_best FLOAT,
                       ann_us BIGINT, ann_reads BIGINT);

INSERT INTO #sq (qv)
SELECT TOP (50) h.embeddings
FROM dbo.HoldoutQueries h
ORDER BY NEWID();

DECLARE @k INT = 10;
DECLARE @tn TABLE (n INT PRIMARY KEY);
INSERT INTO @tn VALUES (10), (50), (200);

DECLARE @qid INT = 1, @maxq INT = (SELECT MAX(qid) FROM #sq);
DECLARE @n INT, @t DATETIME2, @r0 BIGINT, @us BIGINT, @reads BIGINT;
WHILE @qid <= @maxq
BEGIN
    DECLARE @qv VECTOR(768) = (SELECT qv FROM #sq WHERE qid = @qid);

    -- The truth, once per query: the exact top 10.
    TRUNCATE TABLE #knn;
    INSERT INTO #knn (Id, d)
    SELECT TOP (@k) s.PostId, VECTOR_DISTANCE('cosine', @qv, s.embeddings)
    FROM dbo.QuestionEmbeddings AS s
    ORDER BY VECTOR_DISTANCE('cosine', @qv, s.embeddings);

    SET @n = (SELECT MIN(n) FROM @tn);
    WHILE @n IS NOT NULL
    BEGIN
        TRUNCATE TABLE #ann;
        SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        SET @t = SYSDATETIME();

        INSERT INTO #ann (Id, d)
        SELECT TOP (@k) Id, d
        FROM (
            SELECT t.PostId AS Id, s.distance AS d
            FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                               SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = @n) AS s
        ) AS x
        ORDER BY d;

        SET @us = DATEDIFF(MICROSECOND, @t, SYSDATETIME());
        SELECT @reads = logical_reads - @r0 FROM sys.dm_exec_requests WHERE session_id = @@SPID;

        INSERT INTO #srecall (top_n, qid, matched, exact_best, ann_best, ann_us, ann_reads)
        SELECT @n, @qid,
               (SELECT COUNT(*) FROM #ann a JOIN #knn k ON k.Id = a.Id),
               (SELECT MIN(d) FROM #knn),
               (SELECT MIN(d) FROM #ann),
               @us, @reads;

        SET @n = (SELECT MIN(n) FROM @tn WHERE n > @n);
    END;
    SET @qid += 1;
END;

SELECT
    top_n,
    COUNT(*)                                          AS queries,
    CAST(AVG(matched * 1.0 / @k) AS DECIMAL(5,3))     AS avg_recall_at_10,
    SUM(CASE WHEN matched = 0 THEN 1 ELSE 0 END)      AS zero_queries,
    CAST(AVG(ann_best - exact_best) AS DECIMAL(6,4))  AS avg_best_gap,
    CAST(AVG(ann_us) / 1000.0 AS DECIMAL(8,2))        AS avg_ann_ms,
    AVG(ann_reads)                                    AS avg_logical_reads
FROM #srecall
GROUP BY top_n
ORDER BY top_n;

DROP TABLE #sq;
DROP TABLE #knn;
DROP TABLE #ann;
DROP TABLE #srecall;
GO

-- MEASURED (SQL Server 2025 CU10 17.0.5035.5, Docker on Apple Silicon,
-- 1,000,000 real posts, earlier-version DiskANN, R = 48, L = 48).
-- Held-out answers not in the table. Three runs:
--
--   build:      embed 1,000,000 posts ~1 h 55 min (16 sessions through the
--               load balancer) + index 2,100 s (35 min), backup 4.4 GB (ZSTD)
--   one query:  exact kNN 535,731 reads, 1.2 to 2 s CPU, 165 to 235 ms elapsed
--               ANN         ~6,400 reads, about 8 ms
--   rerun (Nov 7, Demo 2 - 2b's question, warm): exact kNN 207 to 265 ms elapsed,
--               1.8 to 2.3 s CPU; ANN 5,564 reads (4,680 vectors + 791
--               worktable + 93 graph edges), 11 to 14 ms. The deck quotes
--               the envelope: exact 175 to 265 ms, ~2 s CPU; ANN 8 to 15 ms.
--   path  rows        elapsed ms   CPU ms
--   kNN       10,000    21 to 26      22 to 26
--   kNN       50,000    26 to 30      84 to 156
--   kNN      100,000    42 to 66     151 to 334
--   kNN      250,000    87 to 101    305 to 462
--   kNN      500,000   179 to 270    653 to 1,421
--   kNN    1,000,000   175 to 234  1,758 to 1,954
--   ANN    1,000,000     about 8       about 8
--
--   Recall and cost, 50 held-out answers per run:
--   TOP_N   recall@10     ANN ms     ANN reads    exact kNN, for scale
--      10   0.84 to 0.89    8 to 10      6,400      535,731 reads, 175 to 235 ms
--      50   0.96 to 0.98   24 to 28     20,800
--     200   0.98 to 0.99   83 to 93     72,000
--   One query per run found none of its true top 10 at TOP_N = 10; at 50,
--   none came back empty. Even TOP_N = 200 reads ~7 times fewer pages than
--   the exact scan. At 10,000 rows, TOP_N = 10 recall was 0.95 to 0.97
--   (Appendix K): recall FELL as the table grew, same index settings.
--   Elapsed is noisy (500K beat 1M in one run); CPU and reads are steadier.
--

USE [StackOverflow];
GO


/* =============================================================================
   APPENDIX G. WALK THE GRAPH BY HAND (extends 1c)
   =============================================================================
   Walk the graph edge table from Demo 2 - 1c by hand, as a greedy search
   (Appendix H).

   The edge table (my reading, not documented):
     src_id           the node, a PostId from the clustered key
     pruned_dest_ids  its neighbors, packed as 4-byte little-endian ints.
                      The start node holds 192 bytes: 48 neighbors, which is R.

   DEV BOXES ONLY. Internal tables are readable only over the DAC:
   ADMIN:<server> in SSMS, -S admin:<server> in sqlcmd (else "Invalid object
   name"). Layout undocumented, can change in any CU. Like DBCC PAGE in
   Demo 01: look, never production code.
----------------------------------------------------------------------------- */

-- Where does the walk start? Docs don't say how StartId is picked; the paper
-- uses the medoid, the data's center. Average each of the 768 positions
-- across all rows, rank real rows by distance to that average. Normal
-- connection; ~8 million values at 10,600 rows (a few seconds). Don't run
-- on StackOverflowScale.
USE [StackOverflow];
GO
DROP TABLE IF EXISTS #centroid;
SELECT CAST(j.[key] AS INT) AS dim, AVG(CAST(j.value AS FLOAT)) AS v
INTO #centroid
FROM dbo.QuestionEmbeddings qe
CROSS APPLY OPENJSON(CAST(qe.embeddings AS NVARCHAR(MAX))) j
GROUP BY CAST(j.[key] AS INT);

DECLARE @centroid VECTOR(768) = (
    SELECT '[' + STRING_AGG(CONVERT(VARCHAR(MAX), CONVERT(VARCHAR(40), v, 3)), ',')
                 WITHIN GROUP (ORDER BY dim) + ']'
    FROM #centroid);
DECLARE @start INT = (SELECT CAST(JSON_VALUE(build_parameters, '$.StartId') AS INT)
                      FROM sys.vector_indexes
                      WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings'));

SELECT TOP (3)
    RANK() OVER (ORDER BY VECTOR_DISTANCE('euclidean', @centroid, qe.embeddings)) AS rank_to_center,
    qe.PostId,
    p.Title,
    CASE WHEN qe.PostId = @start THEN 'StartId' ELSE '' END AS is_start_node
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON p.Id = qe.PostId
ORDER BY VECTOR_DISTANCE('euclidean', @centroid, qe.embeddings);
DROP TABLE #centroid;
GO
-- On my box the StartId (518000, "Is JavaScript a pass-by-reference or
-- pass-by-value language?") ranks 1 of 10,600 by Euclidean and cosine.
-- Strictly, the medoid minimizes total distance to all others; "nearest the
-- center" is the stand-in. Observed, not documented.

-- RUN OVER THE DAC: everything below needs ADMIN:<server>.
USE [StackOverflow];
GO

-- The start node's neighbor list, decoded:
DECLARE @edges SYSNAME = (SELECT it.name FROM sys.internal_tables it
                          WHERE it.parent_object_id = OBJECT_ID('dbo.QuestionEmbeddings')
                            AND it.internal_type_desc = 'VECTOR_INDEX_GRAPH_EDGE_TABLE');
DECLARE @start INT = (SELECT CAST(JSON_VALUE(build_parameters, '$.StartId') AS INT)
                      FROM sys.vector_indexes
                      WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings'));
DECLARE @sql NVARCHAR(MAX) = N'
    SELECT nb.neighbor_id, p.Title
    FROM sys.' + QUOTENAME(@edges) + N' e
    CROSS APPLY GENERATE_SERIES(0, DATALENGTH(e.pruned_dest_ids) / 4 - 1) g
    CROSS APPLY (SELECT CAST(CAST(REVERSE(SUBSTRING(e.pruned_dest_ids, g.value * 4 + 1, 4))
                                  AS BINARY(4)) AS INT) AS neighbor_id) nb
    JOIN dbo.Posts p ON p.Id = nb.neighbor_id
    WHERE e.src_id = @start;';
EXEC sp_executesql @sql, N'@start INT', @start;
GO

-- The walk, one hop at a time:
DECLARE @edges SYSNAME = (SELECT it.name FROM sys.internal_tables it
                          WHERE it.parent_object_id = OBJECT_ID('dbo.QuestionEmbeddings')
                            AND it.internal_type_desc = 'VECTOR_INDEX_GRAPH_EDGE_TABLE');
DECLARE @cur INT = (SELECT CAST(JSON_VALUE(build_parameters, '$.StartId') AS INT)
                    FROM sys.vector_indexes
                    WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings'));
DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit?' USE MODEL ollama);

DECLARE @walk TABLE (hop INT, PostId INT, distance FLOAT, neighbors_checked INT);
DECLARE @nbrs TABLE (PostId INT);
DECLARE @hop INT = 0, @next INT, @cur_d FLOAT, @next_d FLOAT, @n INT;
DECLARE @sql NVARCHAR(MAX) = N'
    SELECT CAST(CAST(REVERSE(SUBSTRING(e.pruned_dest_ids, g.value * 4 + 1, 4)) AS BINARY(4)) AS INT)
    FROM sys.' + QUOTENAME(@edges) + N' e
    CROSS APPLY GENERATE_SERIES(0, DATALENGTH(e.pruned_dest_ids) / 4 - 1) g
    WHERE e.src_id = @cur;';

SELECT @cur_d = VECTOR_DISTANCE('cosine', @qv, embeddings)
FROM dbo.QuestionEmbeddings WHERE PostId = @cur;
INSERT INTO @walk VALUES (0, @cur, @cur_d, NULL);

WHILE @hop < 10
BEGIN
    DELETE @nbrs;
    INSERT INTO @nbrs EXEC sp_executesql @sql, N'@cur INT', @cur;
    SET @n = @@ROWCOUNT;

    SELECT TOP (1) @next = qe.PostId, @next_d = VECTOR_DISTANCE('cosine', @qv, qe.embeddings)
    FROM @nbrs nb
    JOIN dbo.QuestionEmbeddings qe ON qe.PostId = nb.PostId
    ORDER BY VECTOR_DISTANCE('cosine', @qv, qe.embeddings);

    IF @next_d >= @cur_d BREAK;   -- no neighbor is closer, so stop
    SET @hop += 1;
    INSERT INTO @walk VALUES (@hop, @next, @next_d, @n);
    SELECT @cur = @next, @cur_d = @next_d;
END;

SELECT w.hop, w.PostId, p.Title, CAST(w.distance AS DECIMAL(5,3)) AS distance_to_query, w.neighbors_checked
FROM @walk w
JOIN dbo.Posts p ON p.Id = w.PostId
ORDER BY w.hop;

-- The true answer:
SELECT TOP (3) qe.PostId, p.Title,
       CAST(VECTOR_DISTANCE('cosine', @qv, qe.embeddings) AS DECIMAL(5,3)) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON p.Id = qe.PostId
ORDER BY VECTOR_DISTANCE('cosine', @qv, qe.embeddings);
GO

-- WHAT TO LOOK FOR (10,600 rows on my box):
--   hop  question                                                       distance
--     0  Is JavaScript a pass-by-reference or pass-by-value language?     0.581
--     1  How do I correctly clone a JavaScript object?                    0.512
--     2  How to clone a single branch in git?                             0.365
--     3  Making git auto-commit                                           0.255
--     4  How to undo 'git add' before commit?                             0.152
--
-- Four hops, 137 neighbors checked instead of 10,600 rows, drifting from
-- JavaScript to git to undo. The true nearest is "How to undo the most
-- recent commits in Git?" at 0.092: following ONE path, hop 4 is a dead end.
--
-- The real search keeps the best candidates seen (L = 48 here) and explores
-- from several, getting past dead ends. Recall depends on how hard it looks;
-- oversampling TOP_N helps (Appendix M).


/* =============================================================================
   APPENDIX H. WHAT DiskANN IS
   ============================================================================= */

/*
   SQL Server 2025's vector index is DiskANN, a Microsoft Research graph
   index:
     https://suhasjs.github.io/files/diskann_neurips19.pdf

     - Every vector is a node, linked to a few near neighbors plus some
       long-range links.
     - A search starts at a fixed entry node and hops to the neighbor closest
       to the query until nothing closer is left.
     - It visits a tiny fraction of the table, so it's fast, but can miss a
       true neighbor, so it's approximate (Appendix M measures that).
*/


/* =============================================================================
   APPENDIX I. WHICH DiskANN VERSION IS THIS? THE SYNTAX IN THIS DEMO IS THE OLD ONE
   ============================================================================= */

USE [StackOverflow];
GO

/* -----------------------------------------------------------------------------
   I. Which DiskANN version is this? The syntax in this demo is the old one
   -----------------------------------------------------------------------------
   These demos use the EARLIER-VERSION index (what SQL Server 2025 builds).
   Docs:

     - Earlier-version indexes "will be retired in a future version." There's
       no in-place upgrade: drop and recreate.
     - VECTOR_SEARCH's TOP_N is deprecated, kept only for earlier-version
       indexes.
     - The latest version (GA on Azure SQL Database, Fabric, and MI
       Always-up-to-date) is Appendix E.

   This repo's queries fail on Azure SQL:

       Msg 42274: Vector search with version 3 index does not support
                  explicit TOP_N parameter.

   Both versions of the search are in E.2 (only the earlier one runs here).

   Docs:
     https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql
     https://learn.microsoft.com/en-us/sql/t-sql/functions/vector-search-transact-sql
----------------------------------------------------------------------------- */

-- NULL = earlier-version; 3 = latest.
SELECT
    i.name                                          AS index_name,
    JSON_VALUE(v.build_parameters, '$.Version')     AS index_version,
    CASE
        WHEN JSON_VALUE(v.build_parameters, '$.Version') >= '3'
        THEN 'Latest version: no migration needed'
        ELSE 'Earlier version: drop and recreate to migrate, and expect it to be retired'
    END                                             AS migration_status
FROM sys.vector_indexes v
JOIN sys.indexes        i ON i.object_id = v.object_id AND i.index_id = v.index_id;
GO


/* =============================================================================
   APPENDIX J. kNN vs ANN AT 10,000 ROWS
   ============================================================================= */

USE [StackOverflow];
GO

/* -----------------------------------------------------------------------------
   J. kNN vs ANN at 10,000 rows
   -----------------------------------------------------------------------------
   One question, exact kNN (scan) vs. ANN (graph walk). Watch logical reads
   and time in the Messages tab.
----------------------------------------------------------------------------- */

-- ── Exact kNN ──
PRINT '--- EXACT kNN (full table scan) ---';
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'my git history is a mess - how do I clean it up before code review?';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

-- Rank in the satellite table, join the 10 winners (Demo 01 Section 4a).
WITH nearest AS (
    SELECT TOP (10)
        qe.PostId,
        VECTOR_DISTANCE('cosine', @search_vector, qe.embeddings) AS distance
    FROM dbo.QuestionEmbeddings qe
    ORDER BY distance
)
SELECT p.Id, p.Title, p.Score, n.distance
FROM nearest n
JOIN dbo.Posts p ON p.Id = n.PostId
ORDER BY n.distance;
GO
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- ── ANN (DiskANN index) ──
PRINT '--- ANN (DiskANN graph walk) ---';
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'my git history is a mess - how do I clean it up before code review?';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

SELECT
    t.PostId,
    p.Title,
    s.distance,
    p.Score
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 10     -- SQL Server 2025 earlier-version DiskANN syntax
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
ORDER BY s.distance;
GO
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- WHAT TO LOOK FOR (measured on this stack, 10,000 rows, warm cache):
--
--                      kNN (scan)      ANN (graph walk)
--   QuestionEmbeddings  7,055 reads     2,301 reads
--   Worktable               0             671 reads
--   Graph edge table        -              50 reads
--   Total reads         7,055           3,022
--   CPU time            37-63 ms        8-11 ms
--   Elapsed time        13-28 ms        7-10 ms
--
-- ANN wins, but not by the 100× the graph reads (50) suggest: most cost is
-- reads on QuestionEmbeddings. The walk seems to fetch each scored
-- candidate's stored vector, like the paper's full-precision re-ranking
-- (section 3.5). Observed, not documented.
--
-- At 1,000 rows ANN LOSES: ~1,555 total reads vs 502 for the scan.
--
-- Microsoft's vectors overview recommends exact search under ~50,000
-- vectors (after predicates). 10,000 rows is under; know your line.
-- Demo 2 - 2b measures past it.
--   https://learn.microsoft.com/en-us/sql/sql-server/ai/vectors


/* =============================================================================
   APPENDIX K. RECALL AT 10,000 ROWS, AND WHAT WE DIDN'T MEASURE
   ============================================================================= */

USE [StackOverflow];
GO

/* -----------------------------------------------------------------------------
   K-1. One question at 10,000 rows
   -----------------------------------------------------------------------------
----------------------------------------------------------------------------- */

DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama);

WITH exact_top10 AS (
    SELECT TOP (10) qe.PostId
    FROM dbo.QuestionEmbeddings qe
    ORDER BY VECTOR_DISTANCE('cosine', @qv, qe.embeddings)
),
ann_top10 AS (
    SELECT t.PostId
    FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                       SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s
)
SELECT COUNT(*)        AS found_by_both,
       COUNT(*) / 10.0 AS recall_at_10
FROM ann_top10 a
JOIN exact_top10 e ON e.PostId = a.PostId;
GO
-- All or nearly all of the true top 10; about 0.96 over 100 questions (Appendix F).


/* -----------------------------------------------------------------------------
   K-2. What we measured, and what we didn't
   -----------------------------------------------------------------------------
   Measured: 10,000 real questions and 1,000,000 real posts, one session on
   an idle laptop. Not measured: concurrent load, longer documents, anything bigger.
   Load a realistic copy of your data, embed it with your model, rerun.
----------------------------------------------------------------------------- */


/* =============================================================================
   APPENDIX L. THE REST OF THE DOCUMENTED LIMITS
   ============================================================================= */

USE [StackOverflow];
GO

/* -----------------------------------------------------------------------------
   L. The rest of the documented limits
   -----------------------------------------------------------------------------
   From the CREATE VECTOR INDEX docs; know them before designing the table.
     https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql

     - The table needs a clustered primary key on a single INT column
       (Msg 42217). No BIGINT, no GUID, no composite key.
     - No vector indexes on temp tables or views (Msg 42220 for temp tables).
     - You can't partition a vector index.
     - TRUNCATE TABLE fails while the index exists (Msg 42232).
     - Vector indexes aren't replicated to subscribers.
     - Minimum 100 rows with non-NULL vectors (Msg 42266); the docs tie it to
       the latest version. CU10 builds on 50 rows, even on an empty table;
       expect the error on Azure SQL.
     - VECTOR_SEARCH can't be used in the body of a view.
     - DacPac can't deploy a vector index. BACPAC can (DacFx 170.5.96+, with
       100 rows loaded first). Check sys.vector_indexes after any deployment.
     - A VECTOR column can't be a key, can't carry DEFAULT or CHECK
       constraints, and isn't supported in memory-optimized tables or with
       Always Encrypted.
     - VECTOR_SEARCH with no index fails with Msg 42227 on CU10 (Demo 03's
       proc handles it).

   The first two fail, then the 100-row rule:
----------------------------------------------------------------------------- */

DROP TABLE IF EXISTS dbo.vt_guid_key;
CREATE TABLE dbo.vt_guid_key
(
    id UNIQUEIDENTIFIER NOT NULL DEFAULT NEWID() PRIMARY KEY CLUSTERED,
    v  VECTOR(768)      NOT NULL
);
INSERT INTO dbo.vt_guid_key (v)
SELECT TOP (200) embeddings FROM dbo.QuestionEmbeddings;

BEGIN TRY
    CREATE VECTOR INDEX vi ON dbo.vt_guid_key(v) WITH (METRIC = 'cosine', TYPE = 'diskann');
END TRY
BEGIN CATCH
    PRINT CONCAT('Msg ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;
DROP TABLE dbo.vt_guid_key;
GO

CREATE TABLE #vt_temp (id INT NOT NULL PRIMARY KEY CLUSTERED, v VECTOR(768) NOT NULL);
INSERT INTO #vt_temp SELECT TOP (200) PostId, embeddings FROM dbo.QuestionEmbeddings;

BEGIN TRY
    CREATE VECTOR INDEX vi ON #vt_temp(v) WITH (METRIC = 'cosine', TYPE = 'diskann');
END TRY
BEGIN CATCH
    PRINT CONCAT('Msg ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;
DROP TABLE #vt_temp;
GO

-- 50 rows build fine here; Azure SQL fails with Msg 42266:
CREATE TABLE dbo.vt_small (id INT NOT NULL PRIMARY KEY CLUSTERED, v VECTOR(768) NOT NULL);
INSERT INTO dbo.vt_small SELECT TOP (50) PostId, embeddings FROM dbo.QuestionEmbeddings;

BEGIN TRY
    CREATE VECTOR INDEX vi ON dbo.vt_small(v) WITH (METRIC = 'cosine', TYPE = 'diskann');
    PRINT 'Built on 50 rows: no Msg 42266 on the earlier-version index.';
END TRY
BEGIN CATCH
    PRINT CONCAT('Msg ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;
DROP TABLE dbo.vt_small;
GO


/* =============================================================================
   APPENDIX M. RECALL ON ONE QUESTION AT 1,000,000 ROWS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   M. One question at 1,000,000 rows, and the fix
   -----------------------------------------------------------------------------
   Recall@10 = share of the true top 10 the index found. Fix for a miss:
   oversample (TOP_N = 50, keep the closest 10).
----------------------------------------------------------------------------- */

USE [StackOverflowScale];
GO

DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I make an HTTP request in javascript' USE MODEL ollama);

WITH exact_top10 AS (
    SELECT TOP (10) qe.PostId
    FROM dbo.QuestionEmbeddings qe
    ORDER BY VECTOR_DISTANCE('cosine', @qv, qe.embeddings)
),
ann_top_n_10 AS (
    SELECT t.PostId
    FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                       SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s
),
ann_top_n_50 AS (
    SELECT TOP (10) t.PostId
    FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                       SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 50) AS s
    ORDER BY s.distance
)
SELECT
    (SELECT COUNT(*) FROM ann_top_n_10 a JOIN exact_top10 e ON e.PostId = a.PostId) AS found_with_top_n_10,
    (SELECT COUNT(*) FROM ann_top_n_50 a JOIN exact_top10 e ON e.PostId = a.PostId) AS found_with_top_n_50;
GO
-- On my run: 9 of 10 with TOP_N = 10, all 10 with TOP_N = 50.
-- Averaged over 50 questions (Appendix F):
--   TOP_N = 10    recall 0.84 to 0.89    about 8 to 15 ms
--   TOP_N = 50    recall 0.96 to 0.98    about 24 to 28 ms
--   exact kNN     recall 1.0             about 175 to 265 ms

USE [StackOverflow];
GO
