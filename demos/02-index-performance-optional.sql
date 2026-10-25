SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production
  Demo 02 optional deep dives

    Run after demos/02-index-performance.sql. These are optional deep dives.
  These sections cover filtered search, build diagnostics, plan details, and
  latest-version DiskANN on Azure SQL Database, Fabric, and Managed Instance.
=============================================================================
*/

USE [StackOverflow];
GO

/* -----------------------------------------------------------------------------
    APPENDIX A. Filtered search (no predicate pushdown into the graph)
   -----------------------------------------------------------------------------
   STATUS: This limitation exists in SQL Server 2025 on-premises (earlier-
   version DiskANN). It's RESOLVED by iterative filtering in the latest-
    version DiskANN on Azure SQL Database / Fabric. See Appendix E.3.

   VECTOR_SEARCH returns the TOP_N approximate nearest neighbors from the
   ENTIRE graph, and THEN the outer query's WHERE clause filters that candidate
   set. The filter is NOT pushed into the graph traversal.

   Risk: if your filter is very selective, every TOP_N ANN candidate can fail
   it. You get zero rows back, even though an exact kNN search would have
   found matches.

   Mitigation (SQL Server 2025 on-prem): raise TOP_N so the post-filter has
   a bigger candidate pool to work with. That's often called "oversampling."
----------------------------------------------------------------------------- */

-- Shared query text for all three variants below:
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div vertically and horizontally';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

-- Version 1: tight TOP_N (5) + selective filter. It may return fewer than 5 rows:
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
    TOP_N      = 5     -- ANN retrieves 5 candidates, THEN the WHERE clause runs
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 500    -- post-filter: may eliminate all 5 ANN candidates
ORDER BY s.distance;
GO

-- Version 2: oversampled TOP_N (50) + same filter, so the post-filter has more to work with:
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
    TOP_N      = 50    -- retrieve 50 ANN candidates, filter, return best 5
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 500
ORDER BY s.distance;
GO

-- Version 3: exact kNN with the same filter. That's the "correct" answer to compare against:
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
WHERE p.Score > 500    -- filter runs over the full scan, so it's always correct
ORDER BY distance;
GO

-- TAKEAWAY: for ANN + filter workloads, oversample TOP_N by the inverse of
-- your filter selectivity. If roughly 1 in 10 rows passes the filter, use
-- TOP_N = 10 × your desired K to keep result quality up.


/* -----------------------------------------------------------------------------
    APPENDIX B. Dimensionality constraints
   -----------------------------------------------------------------------------
   The VECTOR type in SQL Server 2025 supports 1 to 1,998 dimensions (float32)
    or 1 to 3,996 dimensions (float16, see Demo 01 optional Appendix B).
   That covers all the common embedding models:

     nomic-embed-text             768 dimensions   (this demo)
     mxbai-embed-large           1024 dimensions
     text-embedding-3-small      1536 dimensions
     text-embedding-ada-002      1536 dimensions
     text-embedding-3-large      3072 dimensions  → needs float16!

   float16 exactly doubles the ceiling:
     VECTOR(3072)            → error on float32 (exceeds 1,998)
     VECTOR(3072, float16)   → works (≤ 3,996), uses 6,144 bytes

   A vector index can only be built on a VECTOR(n) column with a fixed,
   known n. You can't index a column that stores vectors of varying dimensions.

   Changing models (say, from 768-dim to 1536-dim) means:
     - A new or altered VECTOR column with the new dimension count
     - Re-embedding ALL rows (existing vectors are from a different model's
       coordinate space and aren't comparable to new-model vectors)
     - Dropping and rebuilding the vector index on the new column
----------------------------------------------------------------------------- */

-- Show the current column definition using the new sys.columns metadata:
-- (vector_dimensions is preferred over max_length/4; see Demo 01 optional Appendix B)
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

-- Let's try to go past the float32 maximum and see the enforced limit:
-- Msg 2717 is a compile error, so it has to run in its own scope to be caught.
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

-- The confirmed float32 maximum (1998):
BEGIN TRY
    CREATE TABLE #dim_max ( v VECTOR(1998) );
    PRINT 'VECTOR(1998) created: max float32 dimensions in SQL Server 2025.';
    DROP TABLE IF EXISTS #dim_max;
END TRY
BEGIN CATCH
    PRINT 'Error: ' + ERROR_MESSAGE();
END CATCH;
GO


/* -----------------------------------------------------------------------------
    APPENDIX C. Index build resource cost at scale
   -----------------------------------------------------------------------------
   Building the DiskANN graph is CPU-heavy. For large embedding tables:

     - CPU: you can't throttle it with MAXDOP on SQL Server 2025 (the option
       is ignored, a documented known issue). Use Resource Governor or a
       maintenance window instead.
     - Memory: the build holds graph state in memory. Watch memory grants
       and buffer pool pressure while it runs.
     - Storage: the graph lands in internal tables (Section 1c). Measure it
       after the build instead of guessing.

   You can watch an in-progress build with sys.dm_exec_requests. Run the
   query below in a SECOND connection window while CREATE VECTOR INDEX
   runs in the first.
----------------------------------------------------------------------------- */

-- Window 1 (uncomment to run):
/*
DROP INDEX IF EXISTS vec_idx ON dbo.QuestionEmbeddings;
CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (metric = 'cosine', type = 'diskann');
*/

-- Window 2, while the build runs:
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

-- Post-build: base table size vs. the graph's internal tables.
-- The VECTOR index's own allocation units are empty; the graph is in
-- internal tables (see Section 1c).
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

/* -----------------------------------------------------------------------------
    APPENDIX D. EXECUTION PLAN ANATOMY: the Vector Index Seek operator
   -----------------------------------------------------------------------------
   VECTOR_SEARCH brings its own plan operator. It isn't a Clustered Index
   Scan (full table read) or a B-tree Index Seek (point/range lookup). It's:

       Vector Index Seek

   Read the plan in SSMS (Ctrl+M) or query sys.dm_exec_cached_plans directly.
   Here's the ANN plan shape:

       Top
        └─ Nested Loops
            ├─ Nested Loops
            │   ├─ Vector Index Seek     ← DiskANN graph walk, returns TOP_N keys
            │   └─ Clustered Index Seek  ← QuestionEmbeddings row lookup
            └─ Clustered Index Seek      ← Posts row lookup

    Compare that to the exact kNN plan from Demo 01 Section 4 (no vector index):

       Top N Sort
        └─ Compute Scalar            ← VECTOR_DISTANCE computed for every row
            └─ Clustered Index Scan  ← full CI scan over every row

   Section 2 has the measured page counts for both paths.

   If SSMS says "'Vector Index Seek' is not a valid value for PhysicalOpType",
   your client's showplan schema predates the operator. Update SSMS, or use
   the plan cache query below, which reads the XML on the server.
----------------------------------------------------------------------------- */
-- Run this, then open the actual execution plan in SSMS (Ctrl+M before running):

DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama
);
SELECT TOP(5) /* demo-4e */
    t.PostId,
    p.Title,
    s.distance,
    p.Score
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

-- WHAT TO LOOK FOR in the graphical plan (node numbers match the query below):
--   Node 0   Top                    enforces the 5-row limit
--   Node 1-2 Nested Loops           for each ANN result, fetch the rows
--   Node 3   Vector Index Seek      the graph walk on 'vec_idx', cost ~0.13
--   Node 36  Clustered Index Seek   QuestionEmbeddings lookup
--   Node 37  Clustered Index Seek   Posts lookup

-- Query the plan cache directly to see the operator tree without SSMS:
SET QUOTED_IDENTIFIER ON;
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
WHERE st.text LIKE N'%demo-4e%'                       -- the marker in the query above
  AND st.text NOT LIKE N'%dm_exec_cached_plans%'      -- not this query
ORDER BY node_id;
GO

-- EXPECTED OUTPUT:
--   node_id  physical_op           est_rows  subtree_cost
--   -------  --------------------  --------  ------------
--         0  Top                        1.0        0.1355
--         1  Nested Loops               1.0        0.1355
--         2  Nested Loops               1.0        0.1322
--         3  Vector Index Seek          1.0        0.1289   ← DiskANN
--        36  Clustered Index Seek       1.0        0.0033   ← QuestionEmbeddings lookup
--        37  Clustered Index Seek       1.0        0.0033   ← Posts lookup
--
-- Notice est_rows = 1.0 on the Vector Index Seek even though it returns 5.
-- The optimizer doesn't estimate vector search cardinality well yet.

/* =============================================================================
    APPENDIX E. LATEST-VERSION DiskANN: WHAT'S NEW (Azure SQL DB / Fabric)
   =============================================================================

   The latest-version DiskANN index is GA on Azure SQL Database, SQL database
   in Microsoft Fabric, and Azure SQL Managed Instance with the
   Always-up-to-date update policy. SQL Server 2025 on-premises runs the
   EARLIER-VERSION index (preview), and the docs don't say when or whether
   that changes. So Sections 5b–5d show code you'd run on those Azure
   platforms.
     https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql

   Summary of changes
   ───────────────────
   Earlier-version (SQL Server 2025 on-prem)    Latest-version (Azure SQL DB / Fabric)
   ────────────────────────────────────────     ──────────────────────────────────────
   Table READ-ONLY after CREATE VECTOR INDEX    Full DML: INSERT / UPDATE / DELETE / MERGE
   Filters applied AFTER graph walk             Iterative filtering: filters IN the walk
   Manual TOP_N oversampling needed             SELECT TOP (N) WITH APPROXIMATE
   No staleness DMV                             sys.dm_db_vector_indexes
   Drop-insert-rebuild cycle                    No workaround needed
   ============================================================================= */


/* -----------------------------------------------------------------------------
    E.1 Check which DiskANN version you're running
   -----------------------------------------------------------------------------
   The reliable check is the Version key in sys.vector_indexes.build_parameters.
   The docs' own migration guidance uses it: Version = 3 is the latest
   version, no Version key is the earlier version.

   Don't use the existence of sys.dm_db_vector_indexes as the test. The docs
   list that DMV for SQL Server 2025 too, even though this CU10 build doesn't
   have it yet.
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

-- On this demo container: no Version key, earlier-version.


/* -----------------------------------------------------------------------------
    E.2 Latest-version query syntax: SELECT TOP (N) WITH APPROXIMATE
   -----------------------------------------------------------------------------
   The earlier-version syntax used TOP_N as a VECTOR_SEARCH parameter:

       FROM VECTOR_SEARCH(
           TABLE = ..., COLUMN = ..., SIMILAR_TO = ...,
           METRIC = 'cosine',
           TOP_N  = 10                       -- earlier-version only
       ) AS s

   The latest-version replaces TOP_N with SELECT TOP (N) WITH APPROXIMATE:

       SELECT TOP (10) WITH APPROXIMATE ...  -- latest-version syntax
       FROM VECTOR_SEARCH(
           TABLE = ..., COLUMN = ..., SIMILAR_TO = ...,
           METRIC = 'cosine'
           -- no TOP_N parameter
       ) AS s

   WITH APPROXIMATE tells the optimizer approximate results are OK. It then
   decides whether to use the DiskANN index or fall back to exact kNN based
   on data size, predicates, and cost.

   MIGRATION WARNING: if you create a latest-version index and keep the
   old TOP_N syntax, the query fails with Msg 42274. Update the query
   BEFORE migrating the index. On this SQL Server 2025 build, WITH
   APPROXIMATE fails with Msg 102 (syntax error).
----------------------------------------------------------------------------- */

-- Earlier-version syntax (works on this SQL Server 2025 container):
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
    TOP_N      = 5     -- earlier-version parameter
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
ORDER BY s.distance;
GO

-- Latest-version syntax (Azure SQL DB, Fabric, MI Always-up-to-date only).
-- Swap <your_external_model> for a model registered on that server.
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
   Earlier-version: filter is a post-process on the ANN candidate set.
     Selective filters can eliminate ALL candidates → zero results.
     Workaround: oversample (increase TOP_N).

   Latest-version: the optimizer pushes predicates INTO the graph walk.
     The walk only considers nodes that satisfy the filter.
     You get exactly the K results you asked for, even with tight filters.
     No oversampling needed. No TOP_N hint needed.

   Syntax comparison:

   -- EARLIER-VERSION (SQL Server 2025 on-prem): oversample to compensate
   SELECT TOP (5)
       ...
   FROM VECTOR_SEARCH(
       ..., METRIC = 'cosine', TOP_N = 50   -- over-fetch 50, filter to 5
   ) AS s
   JOIN dbo.Posts p ON t.PostId = p.Id
   WHERE p.Score > 500
   ORDER BY s.distance;

   -- LATEST-VERSION (Azure SQL DB): iterative filtering, no oversampling
   SELECT TOP (5) WITH APPROXIMATE
       ...
   FROM VECTOR_SEARCH(
       ..., METRIC = 'cosine'               -- no TOP_N
   ) AS s
   JOIN dbo.Posts p ON t.PostId = p.Id
   WHERE p.Score > 500                      -- filter runs INSIDE the graph walk
   ORDER BY s.distance;

   The query is simpler AND more correct: you always get 5 results when
   5 matching rows exist, regardless of filter selectivity.
----------------------------------------------------------------------------- */

-- Here's the on-prem oversampling workaround from Appendix A in action.
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
    TOP_N      = 50    -- workaround: over-fetch to survive the post-filter
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 500
ORDER BY s.distance;
GO
-- On Azure SQL DB (latest-version): drop TOP_N = 50, change to
-- SELECT TOP (5) WITH APPROXIMATE, and the filter runs inside the walk.


/* -----------------------------------------------------------------------------
    E.4 sys.dm_db_vector_indexes: background maintenance monitoring
   -----------------------------------------------------------------------------
   In the latest-version, DML is applied asynchronously: your INSERT/UPDATE/
   DELETE commits immediately, and a background task folds the change into
   the DiskANN graph. The DMV exposes that process.
     https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-vector-indexes-transact-sql

   Key columns:
     graph_catchup_pending_percent
         How much recent DML hasn't been folded into the graph yet.
         It rises during write bursts and drains back toward 0.

     quantized_keys_used_percent
         How much of the index is using quantized keys.

     last_background_task_succeeded
         1 when the last maintenance run finished without errors. If it
         stays 0, read last_background_task_error_message.

   This CU10 build doesn't have the DMV yet, so the query checks first.
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
   If you created a DiskANN index on Azure SQL DB before the latest version
   arrived, it uses the older structure. To get full DML + iterative
   filtering + the new syntax:

     STEP 1:  Update your application queries FIRST.
              Change all VECTOR_SEARCH calls from TOP_N parameter to
              SELECT TOP (N) WITH APPROXIMATE syntax (Appendix E.2).
              If you migrate the index without updating queries, searches
              fail with Msg 42274.

     STEP 2:  Drop and recreate the index. The CREATE syntax is UNCHANGED.

              DROP INDEX vec_idx ON dbo.QuestionEmbeddings;

              CREATE VECTOR INDEX vec_idx
              ON dbo.QuestionEmbeddings([embeddings])
              WITH (METRIC = 'cosine', TYPE = 'diskann');
              -- That's it. The new index is automatically latest-version.

    STEP 3:  Verify the version (Appendix E.1).

              SELECT JSON_VALUE(build_parameters, '$.Version')
              FROM sys.vector_indexes;                        -- 3 = latest

   On SQL Server 2025 on-prem: no migration to perform. The on-premises
   product ships the earlier-version index, and the docs don't announce a
   date for the latest version. Until then, the drop-insert-rebuild cycle
   in Demo 03 Section 4a is the on-prem maintenance pattern.
----------------------------------------------------------------------------- */

-- Summary: where each feature lives (per the docs as of this build):
SELECT
    feature,
    sql_server_2025_onprem,
    azure_latest_version
FROM (VALUES
    ('Full DML (no read-only restriction)',    'Drop-insert-rebuild',      'GA'),
    ('Iterative filtering (predicate in walk)','Manual oversampling',      'GA'),
    ('SELECT TOP (N) WITH APPROXIMATE syntax', 'Not supported (use TOP_N)','GA'),
    ('sys.dm_db_vector_indexes DMV',           'Not on CU10',              'GA'),
    ('Async background index maintenance',     'Not available',            'GA'),
    ('Vector index overall',                   'Preview',                  'GA')
) AS t(feature, sql_server_2025_onprem, azure_latest_version);
-- azure_latest_version = Azure SQL DB, SQL database in Fabric, and Azure SQL
-- Managed Instance with the Always-up-to-date update policy.
