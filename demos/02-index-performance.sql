SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  Demo 2 of 3: VECTOR INDEX PERFORMANCE AND LIMITATIONS
  Build a DiskANN index  ·  kNN vs ANN  ·  1,000,000 rows  ·  Recall  ·  Limits
=============================================================================

  Learning objective:
    Evaluate vector index performance and limitations at scale.

  Time budget (about 15 minutes):
    Section 1  build and inspect the index          3 min
    Section 2  kNN vs ANN, the plan, 1M rows        5 min
    Section 3  recall: what approximate costs       3 min
    Section 4  the limits                           4 min

  Prerequisites:
    Demo 1 complete. QuestionEmbeddings has 10,000 rows (run
    setup/expand-embeddings.sh, about 4 minutes) and the vec_idx index exists.
    Section 2c and 3b need the StackOverflowScale database (1,000,000 rows).
    Build it ahead of time with: bash setup/build-scale-db.sh
    (or restore it: bash setup/build-scale-db.sh --restore)

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run the sections top to bottom. Every one is idempotent.

  Want the full measurements behind the numbers in this file (the timing
  curves, recall averaged over 50 to 100 questions, the cost of oversampling)?
  They're in demos/02-index-performance-optional.sql, Appendix F.
=============================================================================
*/

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 1. THE DiskANN INDEX: WHAT IT IS AND HOW TO BUILD IT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   1a. What DiskANN is
   -----------------------------------------------------------------------------
   A vector index in SQL Server 2025 is a DiskANN index, a graph index from
   Microsoft Research:
     https://suhasjs.github.io/files/diskann_neurips19.pdf

   The idea in three lines:
     - Every vector is a node. Each node links to a few of its nearest
       neighbors, plus some long-range links.
     - A search starts at a fixed entry node and keeps hopping to whichever
       neighbor is closest to the query, until nothing closer is left.
     - It visits a tiny fraction of the table, so it's fast. It can also miss
       a true nearest neighbor, so it's approximate. Section 3 measures that.

   SQL Server 2025 ships the vector index as a PREVIEW feature. You opt in at
   the database level before you create one.
----------------------------------------------------------------------------- */

-- Enable preview features for this database:
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

-- Confirm preview features are on:
SELECT
    name,
    [value]
FROM sys.database_scoped_configurations
WHERE name = 'PREVIEW_FEATURES';
GO


/* -----------------------------------------------------------------------------
   1b. Building the DiskANN index (and watching the clock)
   -----------------------------------------------------------------------------
   Here's what the build does:
     1. Reads every vector in the table
     2. Runs the Vamana build: a GreedySearch from the medoid for every point,
        then prunes each node's edges down to the degree bound R
     3. Persists the graph to internal tables (Section 1c shows them)

   MAXDOP: the CREATE VECTOR INDEX syntax accepts it, but SQL Server 2025
   ignores it, for the build and for VECTOR_SEARCH. That's a documented known
   issue, so I leave it off. The docs' workaround is the server-level max
   degree of parallelism or a database scoped MAXDOP.

   You'll also see "Warning: The join order has been enforced because a local
   join hint is used." That's on the same known-issues list, and the docs say
   it's safe to ignore.
     https://learn.microsoft.com/en-us/sql/sql-server/sql-server-2025-known-issues

   Let's drop and rebuild so you can see the real timing. Here's what I
   measured on this stack (SQL Server 2025 CU10, Apple Silicon M2):
     1,000 rows    ~11 seconds
     10,000 rows   10 to 12 seconds on a running instance (an earlier run
                   saw ~340 seconds right after a restart)
   Build time swings a lot with what's cached and what else the box is
   doing. Measure it on your hardware before you size a maintenance window.

   The build takes about ten seconds here. If you'd rather not wait, skip
   the DROP/CREATE and just run 1c against the existing index.

   NOTE: SQL Server 2025 (earlier-version DiskANN) makes the table READ-ONLY
   while the vector index exists. Section 4a digs into it.
----------------------------------------------------------------------------- */

-- Remove the existing index so we can time a fresh build:
DROP INDEX IF EXISTS vec_idx ON dbo.QuestionEmbeddings;
GO

-- Time the build:
DECLARE @build_start DATETIME2 = SYSDATETIME();

CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (
    metric  = 'cosine',    -- cosine | euclidean | dot  (must match VECTOR_DISTANCE calls)
    type    = 'diskann'    -- only DiskANN is supported
);

SELECT
    DATEDIFF(MILLISECOND, @build_start, SYSDATETIME()) AS build_time_ms,
    (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)      AS rows_indexed;
GO


/* -----------------------------------------------------------------------------
   1c. Inspecting the index in the catalog
   -----------------------------------------------------------------------------
   After the build, the vector index shows up in sys.indexes next to the
   table's clustered index. Notice the type_desc column.
----------------------------------------------------------------------------- */

-- All indexes on QuestionEmbeddings:
SELECT
    i.name              AS index_name,
    i.type_desc         AS index_type,
    i.is_unique,
    c.name              AS indexed_column
FROM sys.indexes      i
JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id  = i.index_id
JOIN sys.columns       c  ON c.object_id   = ic.object_id AND c.column_id  = ic.column_id
WHERE i.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
ORDER BY i.index_id;
GO

-- sys.vector_indexes shows the index type, metric, and build parameters.
-- The docs call build_parameters "internal usage only", but look at the keys:
--   StartId  the entry node, and it's a real PostId. The paper starts at the
--            medoid; the docs don't say how SQL Server picks it.
--   R        the degree bound: max out-edges per node
--   L        the search list size used during the build
--   M        not documented
-- A latest-version index (Azure SQL DB, Fabric, MI Always-up-to-date) adds
-- "Version": 3. No Version key means the earlier-version index.
SELECT
    i.name                                          AS index_name,
    v.vector_index_type,                            -- 'DiskANN'
    v.distance_metric,                              -- 'COSINE' | 'DOT' | 'EUCLIDEAN'
    JSON_VALUE(v.build_parameters, '$.StartId')     AS start_node,
    JSON_VALUE(v.build_parameters, '$.R')           AS max_degree_R,
    JSON_VALUE(v.build_parameters, '$.L')           AS build_list_L,
    JSON_VALUE(v.build_parameters, '$.Version')     AS index_version,    -- NULL = earlier-version
    v.build_parameters
FROM sys.vector_indexes v
JOIN sys.indexes        i  ON i.object_id = v.object_id
                           AND i.index_id  = v.index_id
WHERE v.object_id = OBJECT_ID('dbo.QuestionEmbeddings');
GO

-- The start node is a real row. Here's the question the graph walk starts from:
SELECT p.Id, p.Title
FROM sys.vector_indexes v
JOIN dbo.Posts p ON p.Id = CAST(JSON_VALUE(v.build_parameters, '$.StartId') AS INT)
WHERE v.object_id = OBJECT_ID('dbo.QuestionEmbeddings');
GO

-- Where does the graph live? Not in the VECTOR index's own allocation units.
-- It's stored in internal tables owned by the base table: one for the graph
-- edges and one for quantized vectors. Look at the quantization table's size:
-- it's 0 pages, here and at 1,000,000 rows. This earlier-version index doesn't
-- store quantized vectors. The docs list "advanced quantization" as a
-- latest-version feature, so expect that table to fill on Azure SQL.
SELECT
    it.name                     AS internal_table,
    it.internal_type_desc,
    SUM(au.total_pages)         AS total_pages,
    SUM(au.total_pages) * 8     AS size_KB
FROM sys.internal_tables  it
JOIN sys.partitions       p  ON p.object_id = it.object_id
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
WHERE it.parent_object_id = OBJECT_ID('dbo.QuestionEmbeddings')
GROUP BY it.name, it.internal_type_desc;
GO
-- Compare to the base table: the graph is a small fraction of the vector data.
EXEC sp_spaceused 'dbo.QuestionEmbeddings';
GO


/* -----------------------------------------------------------------------------
   1d. Which DiskANN version is this? The syntax in this demo is the old one
   -----------------------------------------------------------------------------
   Everything in these demos uses the EARLIER-VERSION index, because that's
   what SQL Server 2025 on-premises builds. The docs are explicit about where
   that's headed:

     - Earlier-version indexes are supported today but "will be retired in a
       future version." You can't upgrade one in place. You drop and recreate.
     - The TOP_N parameter of VECTOR_SEARCH is deprecated and kept only for
       earlier-version indexes.
     - The latest version (GA on Azure SQL Database, SQL database in Fabric,
       and Managed Instance with the Always-up-to-date policy) adds full DML,
       iterative filtering, and an optimizer that picks ANN or kNN for you.

   If you copy the queries from this repo to Azure SQL, they fail:

       Msg 42274: Vector search with version 3 index does not support
                  explicit TOP_N parameter.

   Here's the same search in both syntaxes. Only the first one runs on this
   server:

       -- Earlier version (this server):
       SELECT t.PostId, s.distance
       FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                          SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s
       ORDER BY s.distance;

       -- Latest version (Azure SQL DB, Fabric, MI Always-up-to-date):
       SELECT TOP (10) WITH APPROXIMATE t.PostId, s.distance
       FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                          SIMILAR_TO = @qv, METRIC = 'cosine') AS s
       ORDER BY s.distance;

   Docs:
     https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql
     https://learn.microsoft.com/en-us/sql/t-sql/functions/vector-search-transact-sql
----------------------------------------------------------------------------- */

-- Check your index version. No Version key (NULL) means earlier-version.
-- Version = 3 means latest.
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
   SECTION 2. PERFORMANCE: ANN vs. kNN SIDE-BY-SIDE IO COMPARISON
   ============================================================================= */

/* -----------------------------------------------------------------------------
   2a. kNN vs ANN at 10,000 rows
   -----------------------------------------------------------------------------
   Let's answer the same question two ways: exact kNN (table scan) and
   approximate ANN (DiskANN graph walk). SET STATISTICS IO / TIME shows what
   each path costs in logical reads and elapsed milliseconds.

   Watch the Messages tab while each query runs. The numbers tell the story
   better than any benchmark chart.
----------------------------------------------------------------------------- */

-- ── Exact kNN ─────────────────────────────────────────────────────────────────
PRINT '--- EXACT kNN (full table scan) ---';
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'my git history is a mess - how do I clean it up before code review?';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

-- Rank in the satellite table, then join the 10 winners (Demo 01 Section 4a).
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

-- ── ANN (DiskANN index) ────────────────────────────────────────────────────────
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
-- So ANN wins, but not by the 100× the graph reads alone (50) might suggest.
-- The graph itself is cheap (50 reads). Most of the ANN cost is reads on
-- QuestionEmbeddings. The IO suggests the walk fetches the stored
-- vector for the candidates it scores, much like the paper's full-precision
-- re-ranking (§3.5). The docs don't describe this, so treat it as observed.
--
-- And at 1,000 rows ANN LOSES: about 1,555 total reads vs 502 for the scan.
-- Small tables don't need a vector index.
--
-- Microsoft's own guidance agrees. The vectors overview recommends exact
-- search when you have fewer than about 50,000 vectors to compare, and says
-- a table can hold many more as long as your predicates cut the candidates to
-- 50,000 or fewer. Our 10,000 rows are under that line. So the lesson isn't
-- "the index is always faster." It's "know where the line is for your data,"
-- and §2c measures past it.
--   https://learn.microsoft.com/en-us/sql/sql-server/ai/vectors


/* -----------------------------------------------------------------------------
   2b. The plan: Vector Index Seek
   -----------------------------------------------------------------------------
   Turn on the actual plan (Ctrl+M in SSMS) and run the query below. You'll
   see a new operator, Vector Index Seek. It replaces the Clustered Index Scan
   and the per-row Compute Scalar from the exact plan in Demo 1 §4b:

       Exact kNN:  Clustered Index Scan → Compute Scalar → Top N Sort
       ANN:        Vector Index Seek → Clustered Index Seek → Nested Loops → Top

   One thing to notice: the estimated rows on Vector Index Seek say 1, even
   though it returns 5. The optimizer doesn't estimate vector search well yet.

   If SSMS says "'Vector Index Seek' is not a valid value for PhysicalOpType",
   update SSMS. (No graphical plan at all? Optional Appendix F reads the plan
   from the plan cache.)
----------------------------------------------------------------------------- */

DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama
);
SELECT TOP (5)
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


/* -----------------------------------------------------------------------------
   2c. Past the line: 1,000,000 vectors
   -----------------------------------------------------------------------------
   10,000 rows is under Microsoft's ~50,000-vector guidance for exact search.
   So let's switch to StackOverflowScale, a second database with 1,000,000
   vectors and its own index, and run the same comparison.

   What the data is: the 10,000 real embeddings, each with 100 noisy copies.
   It keeps real topic structure, but it's synthetic. Use it for reads, time,
   and recall, not for search quality.

   The query is a real StackOverflow question that is NOT in the table, the
   way a user's question would be.
----------------------------------------------------------------------------- */

USE [StackOverflowScale];
GO

-- What we're working with:
SELECT COUNT(*) AS rows_in_table FROM dbo.ScaleVectors;
EXEC sp_spaceused 'dbo.ScaleVectors';
GO

-- The same question, both ways. Watch the Messages tab.
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @qv VECTOR(768) = (
    SELECT embeddings FROM StackOverflow.dbo.QuestionEmbeddings
    WHERE PostId = 219716);   -- "What are the uses for Cross Join?"

PRINT '--- EXACT kNN over 1,000,000 rows ---';
SELECT TOP (10) s.Id, VECTOR_DISTANCE('cosine', @qv, s.v) AS distance
FROM dbo.ScaleVectors s
ORDER BY distance;

PRINT '--- ANN over 1,000,000 rows ---';
SELECT t.Id, s.distance
FROM VECTOR_SEARCH(TABLE = dbo.ScaleVectors AS t, COLUMN = [v],
                   SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s
ORDER BY s.distance;
GO
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
-- WHAT TO LOOK FOR (CU10 on my laptop, this question):
--                       exact kNN          ANN
--   logical reads       511,159            7,324 (6,236 + 971 worktable + 117 graph)
--   elapsed             160 to 340 ms      about 15 ms
--   CPU                 1.7 to 2.5 seconds about 15 ms
--
-- About 70 times fewer reads. That's the reason the index exists. At 10,000
-- rows the gap was about 2x; at 1,000,000 it's about 70x. Exact search grows
-- with every row; the graph walk barely notices. (Appendix F has the full curve
-- from 10,000 to 1,000,000 rows.)

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 3. RECALL: WHAT APPROXIMATE COSTS YOU
   ============================================================================= */

/* -----------------------------------------------------------------------------
   Recall@K = how many of the true top K the index found, divided by K.
   1.0 means the index returned exactly what an exact search would.

   This matters for RAG: if the index misses the best match, the LLM gets
   worse context. We'll check one question at 10,000 rows, then one at
   1,000,000.
----------------------------------------------------------------------------- */

/* -----------------------------------------------------------------------------
   3a. One question at 10,000 rows
   -----------------------------------------------------------------------------
   Run the exact search and the index search for the same question and count
   how many of the top 10 they share.
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
-- At 10,000 rows the index finds all, or nearly all, of the true top 10.
-- Averaged over 100 questions it's about 0.96 (Appendix F).


/* -----------------------------------------------------------------------------
   3b. One question at 1,000,000 rows, and the fix
   -----------------------------------------------------------------------------
   Same check on the big table, with the Cross Join question from §2c. Then the
   fix: ask the index for more candidates than you need (TOP_N = 50) and keep
   the closest 10. That's called oversampling.
----------------------------------------------------------------------------- */

USE [StackOverflowScale];
GO

DECLARE @qv VECTOR(768) = (
    SELECT embeddings FROM StackOverflow.dbo.QuestionEmbeddings
    WHERE PostId = 219716);   -- "What are the uses for Cross Join?"

WITH exact_top10 AS (
    SELECT TOP (10) s.Id
    FROM dbo.ScaleVectors s
    ORDER BY VECTOR_DISTANCE('cosine', @qv, s.v)
),
ann_top_n_10 AS (
    SELECT t.Id
    FROM VECTOR_SEARCH(TABLE = dbo.ScaleVectors AS t, COLUMN = [v],
                       SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s
),
ann_top_n_50 AS (
    SELECT TOP (10) t.Id
    FROM VECTOR_SEARCH(TABLE = dbo.ScaleVectors AS t, COLUMN = [v],
                       SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 50) AS s
    ORDER BY s.distance
)
SELECT
    (SELECT COUNT(*) FROM ann_top_n_10 a JOIN exact_top10 e ON e.Id = a.Id) AS found_with_top_n_10,
    (SELECT COUNT(*) FROM ann_top_n_50 a JOIN exact_top10 e ON e.Id = a.Id) AS found_with_top_n_50;
GO
-- On my run: 4 of 10 with TOP_N = 10, all 10 with TOP_N = 50.
--
-- That's one question. Averaged over 50 questions at 1,000,000 rows (Appendix F),
-- the range across nine runs on my laptop:
--   TOP_N = 10    recall 0.64 to 0.86    about 7 to 24 ms
--   TOP_N = 50    recall 0.94 to 0.99    about 19 to 43 ms
--   exact kNN     recall 1.0             about 160 to 340 ms
-- The times are relative: compare them to each other, not to your servers.
-- Recall falls as the table grows. Oversampling buys it back for a few more
-- milliseconds, and it's still far cheaper than the exact scan. The demo app's
-- search proc oversamples 5x (Demo 3).

USE [StackOverflow];
GO


/* -----------------------------------------------------------------------------
   3c. What we measured, and what we didn't
   -----------------------------------------------------------------------------
   Measured: 10,000 real rows and 1,000,000 synthetic ones, one session on one
   laptop. Not measured: a corpus of 1,000,000 distinct documents, concurrent
   load, or anything bigger. Treat these numbers as a guide. Load a realistic
   copy of your data, embed it with your model, and run these same queries.
----------------------------------------------------------------------------- */


/* =============================================================================
   SECTION 4. LIMITATIONS: WHERE VECTOR INDEXES HELP AND WHERE THEY DON'T
   ============================================================================= */

/* -----------------------------------------------------------------------------
   4a. LIMITATION: Read-only table after CREATE VECTOR INDEX (SQL Server 2025)
   -----------------------------------------------------------------------------
   STATUS: This limitation exists in SQL Server 2025 on-premises (the
   "earlier-version" DiskANN index). It's RESOLVED in the latest-version
   DiskANN index on Azure SQL Database, SQL database in Fabric, and Azure
   SQL Managed Instance with the Always-up-to-date update policy (see demos/02-index-performance-optional.sql).

   In SQL Server 2025 (the "earlier-version" DiskANN index), creating a vector
   index makes the underlying table READ-ONLY. INSERT, UPDATE, DELETE, and
   MERGE fail with Msg 42231. TRUNCATE TABLE fails with Msg 42232. The docs
   list the read-only rule but not the error numbers. These are what this
   build returns.

   ALLOW_STALE_VECTOR_INDEX isn't an option here. The CREATE VECTOR INDEX page
   suggests it for earlier-version indexes, but the ALTER DATABASE SCOPED
   CONFIGURATION page says it "isn't currently available in SQL Server 2025"
   (it's Azure SQL Database and Fabric only), and on CU10 it fails with Msg 102.

   That's a big operational problem if your workload keeps adding new
   embeddings as new content arrives.

     WORKAROUND: Drop-insert-rebuild cycle in an offline maintenance
                 window (the only option on SQL Server 2025 on-prem today).
                 Demo 03 Section 4a runs it live.

   On the latest-version index: no workaround needed. Tables are fully
   writable and the index maintains itself in the background.
----------------------------------------------------------------------------- */

-- Confirm the index exists:
SELECT name, type_desc FROM sys.indexes
WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings');
GO

-- Try to INSERT with the vector index in place:
-- Msg 42231 isn't catchable with TRY/CATCH. It surfaces as a hard error,
-- so run this and watch the message come back directly.
INSERT INTO dbo.QuestionEmbeddings (PostId, chunk, embeddings)
VALUES (
    999999,
    'test row',
    AI_GENERATE_EMBEDDINGS(N'test insertion with vector index present' USE MODEL ollama)
);
-- Expected: Msg 42231 "Data modification statement failed because table
--           'QuestionEmbeddings' has a vector index on it."
GO


/* -----------------------------------------------------------------------------
   4b. STRESS TEST: the silent zero-results failure
   -----------------------------------------------------------------------------
   This is the most dangerous production pitfall with earlier-version DiskANN.
   It produces no error. It just silently returns zero rows.

   SETUP: find questions about CSS centering with Score > 5,000. Only 21
   questions in the 10,000-row embedded set have Score > 5,000 at all
   (0.21% selectivity). If TOP_N is too small, none of the ANN candidates
   pass the filter.

   STEP 1: ANN with tight TOP_N=5 and a selective Score filter.
   Expected: 0 rows, because all 5 ANN candidates have Score < 5,000.
----------------------------------------------------------------------------- */
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div in CSS';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- Step 1: ANN TOP_N=5, Score > 5000 ---';
SELECT t.PostId, p.Score, s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 5           -- only 5 ANN candidates; none have Score > 5000
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 5000
ORDER BY s.distance;
-- Returns 0 rows. No error. Silent data loss.
GO

-- STEP 2: Diagnose. What DID the ANN retrieve before the filter?
-- Let's drop the WHERE clause and look at the raw ANN candidates and scores.
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div in CSS';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- Step 2: Diagnose: ANN TOP_N=5 WITHOUT filter (raw candidates) ---';
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
-- All 5 scores are < 5,000 (this run: 596, 842, 3549, 428, 728).
-- The filter's fine. There just aren't any high-score results in this batch.
GO

-- STEP 3: Confirm the data DOES exist. Exact kNN finds it.
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div in CSS';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- Step 3: Exact kNN, Score > 5000 (ground truth: proves data exists) ---';
SELECT TOP(5) qe.PostId, p.Score,
    VECTOR_DISTANCE('cosine', @search_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
WHERE p.Score > 5000
ORDER BY distance;
-- Returns 5 rows: the highest-scored questions nearest to "center a div in CSS".
-- This run: 503093, 178325, 348170, 927358, 477816 (Scores 6,591 to 17,388).
-- Notice distance is ~0.49–0.57, much further away than the TOP_N=5
-- candidates (0.11–0.15). That's WHY the ANN didn't include them: closer,
-- lower-scored rows fill the top of the list.
GO

-- STEP 4: Fix it. Oversample TOP_N to cover the filter's selectivity.
-- 21 of 10,000 embedded questions have Score > 5000 → ~0.21% selectivity.
-- About 1,700 rows are closer to the query than the furthest qualifying
-- result (1,764 at 10,300 rows), so TOP_N has to reach past all of them.
-- TOP_N=2500 returns all 5.
-- Rule of thumb: TOP_N ≥ K / selectivity = 5 / 0.0021 ≈ 2381. Use 2500.
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div in CSS';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- Step 4: ANN TOP_N=2500, Score > 5000 (oversampled, correct) ---';
SELECT TOP(5) t.PostId, p.Score, s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 2500       -- covers ~25% of the corpus, so the filter has material to work with
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 5000
ORDER BY s.distance;
-- Now returns the same 5 rows as exact kNN.

-- TAKEAWAY:
--   Filter selectivity × TOP_N must exceed desired K.
--   Rule of thumb: TOP_N ≥ K / estimated_filter_pass_rate
--   For 0.21% selectivity wanting 5 results: TOP_N ≥ 2381 (use 2500).
--   On Azure SQL DB / Fabric (latest-version DiskANN), iterative filtering
--   eliminates this problem entirely. The engine searches until it finds K
--   qualifying rows, regardless of filter selectivity.
GO


/* -----------------------------------------------------------------------------
   4c. The rest of the documented limits
   -----------------------------------------------------------------------------
   These come from the CREATE VECTOR INDEX docs. Each one shapes your schema,
   so you want to know them before you design the table.
     https://learn.microsoft.com/en-us/sql/t-sql/statements/create-vector-index-transact-sql

     - The table needs a clustered primary key on a single INT column
       (Msg 42217). No BIGINT, no GUID, no composite key.
     - No vector indexes on temp tables or views (Msg 42220 for temp tables).
     - You can't partition a vector index.
     - TRUNCATE TABLE fails while the index exists (Msg 42232).
     - Vector indexes aren't replicated to subscribers.
     - The docs list a minimum of 100 rows with non-NULL vectors (Msg 42266),
       and their examples tie it to the latest-version index. The
       earlier-version index on this build doesn't enforce it: it builds on
       50 rows, and even on an empty table. Expect the error on Azure SQL.
     - VECTOR_SEARCH can't be used in the body of a view.
     - DacPac can't deploy a vector index. BACPAC can, with DacFx 170.5.96 or
       later, and the table needs 100 rows loaded first. Check
       sys.vector_indexes after any deployment.
     - A VECTOR column can't be a key, can't carry DEFAULT or CHECK
       constraints, and isn't supported in memory-optimized tables or with
       Always Encrypted.
     - VECTOR_SEARCH with no index on the column fails with Msg 42227 on
       this build. Demo 03 shows how the app's proc handles that.

   Let's see the first two fail, then the 100-row rule:
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

-- And the 100-row minimum. The docs' examples tie it to the latest-version index.
-- Here, on the earlier-version index, 50 rows builds with no error. On Azure SQL
-- (latest version) the same statement fails with Msg 42266:
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
