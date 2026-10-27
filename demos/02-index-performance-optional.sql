SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production
  Demo 02 optional deep dives

  Run after demos/02-index-performance.sql. The appendices follow the core
  script's order:
    A. Index build resource cost         (extends §1 and §2b)
    B. Duplicate embeddings              (data quality before you build)
    C. Filtered search                   (behind §4b)
    D. Dimensionality constraints        (behind §4c)
    E. Latest-version DiskANN            (Azure SQL DB, Fabric, and Managed
                                          Instance: where this is heading)
    F. Measurement harnesses             (the averages Demo 2 quotes)
=============================================================================
*/

USE [StackOverflow];
GO

/* -----------------------------------------------------------------------------
    APPENDIX A. Index build resource cost at scale
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

/* =============================================================================
   APPENDIX B. DUPLICATE EMBEDDINGS
   =============================================================================

   The CREATE VECTOR INDEX docs say not to index datasets with a high share
   of duplicate vectors. Duplicates crowd real neighbors out of the results,
   waste build time, and add maintenance cost for no benefit. Deduplicate
   before you build.

   You can't GROUP BY a VECTOR column, so use the text that was embedded as
   the proxy. Identical chunks give identical vectors from the same model.
   ============================================================================= */

SELECT
    COUNT(*)                                         AS total_rows,
    COUNT(DISTINCT qe.chunk)                         AS distinct_chunks,
    COUNT(*) - COUNT(DISTINCT qe.chunk)              AS duplicate_rows
FROM dbo.QuestionEmbeddings qe;
GO

-- The worst offenders:
SELECT TOP (10) qe.chunk, COUNT(*) AS copies
FROM dbo.QuestionEmbeddings qe
GROUP BY qe.chunk
HAVING COUNT(*) > 1
ORDER BY copies DESC;
GO

/* -----------------------------------------------------------------------------
    APPENDIX C. Filtered search (no predicate pushdown into the graph)
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
    APPENDIX D. Dimensionality constraints
   -----------------------------------------------------------------------------
   The VECTOR type in SQL Server 2025 supports 1 to 1,998 dimensions (float32)
    or 1 to 3,996 dimensions (float16, see Demo 01 optional Appendix A).
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
-- (vector_dimensions is preferred over max_length/4; see Demo 01 optional Appendix A)
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

/* =============================================================================
    APPENDIX E. LATEST-VERSION DiskANN: WHAT'S NEW (Azure SQL DB / Fabric)
   =============================================================================

   The latest-version DiskANN index is GA on Azure SQL Database, SQL database
   in Microsoft Fabric, and Azure SQL Managed Instance with the
   Always-up-to-date update policy. SQL Server 2025 on-premises runs the
   EARLIER-VERSION index (preview), and the docs don't say when or whether
   that changes. So sections E.2 to E.5 show code you'd run on those Azure
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

-- Here's the on-prem oversampling workaround from Appendix C in action.
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
    ('sys.dm_db_vector_indexes DMV',           'Not on this build (CU5, CU10)',              'GA'),
    ('Async background index maintenance',     'Not available',            'GA'),
    ('Vector index overall',                   'Preview',                  'GA')
) AS t(feature, sql_server_2025_onprem, azure_latest_version);
-- azure_latest_version = Azure SQL DB, SQL database in Fabric, and Azure SQL
-- Managed Instance with the Always-up-to-date update policy.


/* =============================================================================
   APPENDIX F. MEASUREMENT HARNESSES (the numbers behind Demo 2)
   =============================================================================

   The core demo shows one query at a time. These are the loops that produced
   the averages it quotes: the timing curve from 10,000 to 1,000,000 rows,
   recall averaged over many questions, and what oversampling costs. They use
   timing loops and DMV deltas, so they're more involved than the core demo.

   F.1  Read the ANN plan from the plan cache (no graphical plan needed)
   F.2  Timing curve at 1,000 to 10,000 rows (StackOverflow)
   F.3  Recall averaged over 100 questions at 10,000 rows
   F.4  Timing curve to 1,000,000 rows, and recall and cost of oversampling
        (StackOverflowScale)
   ============================================================================= */

/* -----------------------------------------------------------------------------
   F.1 The ANN plan from the plan cache
   -----------------------------------------------------------------------------
   Run this right after the Demo 2 §2b query, which carries no marker, so here
   is a marked copy to find in the cache.
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

-- Read the operator tree from the plan cache:
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
WHERE st.text LIKE N'%demo-ann-plan%'                 -- the marker in the query above
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
-- Notice est_rows = 1.0 on the Vector Index Seek even though it returns 5.
-- The optimizer doesn't estimate vector search cardinality well yet, so don't
-- trust row estimates downstream of it.



/* -----------------------------------------------------------------------------
   F.2 Scale: how each path grows with row count
   -----------------------------------------------------------------------------
   One IO comparison at one size doesn't tell you how it scales. Let's
   measure it. This batch embeds the query once, then times exact kNN over
   the first 1,000, 2,500, 5,000, and 10,000 rows (a clustered key range, so
   each run reads only its slice) and ANN over the whole table. Each size
   runs 10 times and we keep the average.

   No Ollama call inside the loop, so you're timing SQL Server, not HTTP.
----------------------------------------------------------------------------- */

SET NOCOUNT ON;
DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'my git history is a mess - how do I clean it up before code review?' USE MODEL ollama);
DECLARE @results TABLE (search_path VARCHAR(4), rows_searched INT, avg_elapsed_ms DECIMAL(9,1), avg_cpu_ms DECIMAL(9,1));
DECLARE @n INT, @cutoff INT, @i INT, @t DATETIME2, @us BIGINT, @cpu0 INT, @sink INT;
DECLARE @runs INT = 10;

-- CPU used so far by this request; the difference is the work done in a loop.
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
-- Here's what to say out loud:
--   - kNN CPU grows linearly with rows. Parallelism can hide that in elapsed
--     time on an idle box, but under concurrent load you pay the CPU.
--   - ANN at 10,000 rows costs about what kNN costs at 1,000.
--   - Below a few thousand rows, a vector index isn't worth it (see the
--     1,000-row note at the end of the IO comparison above).



/* -----------------------------------------------------------------------------
   F.3 Recall averaged over 100 queries, at two values of K
   -----------------------------------------------------------------------------
   The queries are 100 real StackOverflow questions that are NOT in
   QuestionEmbeddings, embedded the same way the corpus was (title + tags).
   That's what a user's question looks like to the index: something it has
   never seen. It's also the same method §2b uses at 1,000,000 rows, so the
   two recall numbers are a fair comparison.

   (Querying with vectors that are already in the table is a common shortcut,
   and it flatters the index. It gave 0.99 here, against 0.95 to 0.97 this
   way.)

   Embedding 100 questions costs about 1.5 seconds of Ollama calls, once. After
   that every search is pure SQL Server.

   Compare K = 10 against K = 100. Watch the worst-query column: the average
   hides the queries that did worse. The number you get here is for THIS
   data, THIS model, and THIS index build. Rerun it on yours.
----------------------------------------------------------------------------- */

SET NOCOUNT ON;

DROP TABLE IF EXISTS #queries;
DROP TABLE IF EXISTS #recall;
CREATE TABLE #queries (qid INT IDENTITY PRIMARY KEY, qv VECTOR(768) NOT NULL);
CREATE TABLE #recall  (k INT, qid INT, matched INT);

-- The next 100 top-scored questions that aren't embedded yet:
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
--   worst_query_recall the tail. Averages hide the queries that got worse
--                      context. Always look at the worst case too.
--   What recall is good enough depends on your workload. Test answer quality
--   with your own questions, not just the recall number.
--   Recall is a property of your data and the index build, not a constant.
--   Measure it after every model change and every index rebuild. Two runs of
--   the same queries can differ slightly, so quote a range.



/* -----------------------------------------------------------------------------
   F.4 Timing curve to 1,000,000 rows, recall, and the cost of oversampling
   -----------------------------------------------------------------------------
   Needs StackOverflowScale (bash setup/build-scale-db.sh). The query vectors
   are real questions that are NOT in the table.
----------------------------------------------------------------------------- */

USE [StackOverflowScale];
GO

-- The same harness as §2a: exact kNN over slices of the table, ANN over all of it.
SET NOCOUNT ON;
DECLARE @qv VECTOR(768) = (
    SELECT TOP (1) qe.embeddings
    FROM StackOverflow.dbo.QuestionEmbeddings qe
    WHERE NOT EXISTS (SELECT 1 FROM dbo.Centers c WHERE c.PostId = qe.PostId)
    ORDER BY qe.PostId);
DECLARE @results TABLE (search_path VARCHAR(4), rows_searched INT, avg_elapsed_ms DECIMAL(9,1), avg_cpu_ms DECIMAL(9,1));
DECLARE @n INT, @i INT, @t DATETIME2, @us BIGINT, @cpu0 INT, @cpu_now INT, @sink INT;
DECLARE @runs INT = 5;

DECLARE @sizes TABLE (n INT PRIMARY KEY);
INSERT INTO @sizes VALUES (10000), (50000), (100000), (250000), (500000), (1000000);

SELECT @n = MIN(n) FROM @sizes;
WHILE @n IS NOT NULL
BEGIN
    SELECT @i = 0, @us = 0;
    SELECT @cpu0 = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
    WHILE @i < @runs
    BEGIN
        SET @t = SYSDATETIME();
        SELECT TOP (10) @sink = s.Id
        FROM dbo.ScaleVectors s
        WHERE s.Id <= @n
        ORDER BY VECTOR_DISTANCE('cosine', @qv, s.v)
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
    SELECT @sink = t.Id
    FROM VECTOR_SEARCH(TABLE = dbo.ScaleVectors AS t, COLUMN = [v],
                       SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s;
    SET @us += DATEDIFF(MICROSECOND, @t, SYSDATETIME());
    SET @i += 1;
END;
SELECT @cpu_now = cpu_time FROM sys.dm_exec_requests WHERE session_id = @@SPID;
INSERT INTO @results
SELECT 'ANN', COUNT(*), @us / 1000.0 / @runs, (@cpu_now - @cpu0) * 1.0 / @runs
FROM dbo.ScaleVectors;

SELECT search_path, rows_searched, avg_elapsed_ms, avg_cpu_ms
FROM @results
ORDER BY search_path DESC, rows_searched;
GO

/* -----------------------------------------------------------------------------
   Recall at 1,000,000 rows, and what oversampling costs
   -----------------------------------------------------------------------------
   The queries are real StackOverflow questions that are NOT among the 10,000
   centers, so none of them has a noisy copy in the table. Their true nearest
   neighbors are spread across many clusters, which is a much harder test than
   querying with a vector that's already in the table. (My first version used
   stored vectors as queries. Every neighbor was a copy from the same cluster,
   and recall came out at a perfect 1.0. That proved nothing.)

   We ask for the true top 10 and compare three ways to get it from the index:
     TOP_N = 10    ask the graph for exactly 10
     TOP_N = 50    ask for 50, keep the 10 closest
     TOP_N = 200   ask for 200, keep the 10 closest
   Asking for more candidates and trimming is the same oversampling trick as
   §4b, now used to buy back recall instead of to beat a filter. It isn't free,
   so the table shows what each setting costs.

   Columns:
     avg_recall_at_10   how many of the exact top 10 the index found
     zero_queries       queries where the index found NONE of them
     avg_best_gap       how much farther the index's best hit is than the true
                        best hit. A small gap means the misses were near-misses.
     avg_ann_ms         time for the ANN call alone
     avg_logical_reads  logical reads for the ANN call alone

   Exact kNN over a million rows costs real time. This takes a few minutes.
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
SELECT TOP (50) qe.embeddings
FROM StackOverflow.dbo.QuestionEmbeddings qe
WHERE NOT EXISTS (SELECT 1 FROM dbo.Centers c WHERE c.PostId = qe.PostId)
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
    SELECT TOP (@k) s.Id, VECTOR_DISTANCE('cosine', @qv, s.v)
    FROM dbo.ScaleVectors AS s
    ORDER BY VECTOR_DISTANCE('cosine', @qv, s.v);

    SET @n = (SELECT MIN(n) FROM @tn);
    WHILE @n IS NOT NULL
    BEGIN
        TRUNCATE TABLE #ann;
        SELECT @r0 = logical_reads FROM sys.dm_exec_requests WHERE session_id = @@SPID;
        SET @t = SYSDATETIME();

        INSERT INTO #ann (Id, d)
        SELECT TOP (@k) Id, d
        FROM (
            SELECT t.Id, s.distance AS d
            FROM VECTOR_SEARCH(TABLE = dbo.ScaleVectors AS t, COLUMN = [v],
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
-- 1,000,000 synthetic rows, earlier-version DiskANN, R = 48, L = 48).
-- The query is a real question that is NOT in the table:
--
--   build:      generate 3,024 s (50 min) + index 1,591 s (26.5 min), backup 3.1 GB
--   one query:  exact kNN 511,159 reads, 1.8 s CPU, 240 ms elapsed
--               ANN         4,819 reads (4,044 + 697 worktable + 78 graph), 10 ms
--   path  rows        elapsed ms   CPU ms
--   kNN      100,000     32         107
--   kNN      250,000     76         254
--   kNN      500,000    144         488
--   kNN    1,000,000    337       1,040
--   ANN    1,000,000      5.2        4.6
--   Times are relative to this laptop and move from run to run: later re-runs
--   put the 1,000,000-row kNN point at 520 to 570 ms with ANN at 5 to 7 ms,
--   and over a second when the box was busy. Logical reads never moved.
--
--   Recall and cost, 50 random real questions not in the table. The recall
--   column swings from run to run, so run it a few times and quote a range.
--   These are the full ranges across nine runs:
--   TOP_N   recall@10     ANN ms     ANN reads    exact kNN, for scale
--      10   0.64 to 0.86    7 to 24      5,800      511,159 reads, 160 to 340 ms
--      50   0.94 to 0.99   19 to 43     13,900
--     200   0.986 to 1.0   54 to 126    45,300
--   Oversampling buys recall back at the cost of reads and latency, and even
--   TOP_N = 200 reads about 11 times fewer pages than the exact scan. Measured
--   the same way at 10,000 real rows, recall at TOP_N = 10 was 0.95 to 0.97
--   (§3a), so recall FELL as the table grew with the same index parameters. The misses were near-misses (best hit 0.003 to
--   0.014 farther than the true best). This data is synthetic and clustered,
--   so don't promise your own number. Measure it.
--
-- WHAT TO SAY:
--   Say what you measured and what you didn't. This is one session on an idle
--   box. It isn't concurrent load, it isn't a corpus of distinct documents, and
--   the index build time and memory are in the build log, not on stage.

USE [StackOverflow];
GO
