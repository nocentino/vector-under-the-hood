SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  Demo 2 of 3 — VECTOR INDEX PERFORMANCE AND LIMITATIONS
  DiskANN internals  ·  ANN vs. kNN recall  ·  IO comparison  ·  Real limits
  Latest-version improvements (Azure SQL DB / Fabric)
=============================================================================

  Learning objective:
    Evaluate vector index performance and limitations at scale.

  Prerequisites:
    Demo 1 complete. StackOverflow is restored and QuestionEmbeddings is
    populated. The vec_idx DiskANN index was created at startup by sql-init.

  OPTIONAL — expand to 10,000 rows for a more striking IO contrast:
    The startup script embeds 1,000 questions. For the full 10,000-row corpus
    (recommended for §2 IO comparison and §3 recall at scale), run:

        bash setup/expand-embeddings.sh

    (~25 min on Apple Silicon with Ollama GPU — see script for batch progress).

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run sections top-to-bottom. Every section is idempotent.

=============================================================================
*/

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 1 — THE DiskANN INDEX: WHAT IT IS AND HOW TO BUILD IT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   1a. What DiskANN is (conceptually)
   -----------------------------------------------------------------------------
   DiskANN is a graph-based Approximate Nearest Neighbor (ANN) system from
   Microsoft Research (Subramanya et al., NeurIPS 2019). 
   https://suhasjs.github.io/files/diskann_neurips19.pdf It's designed to
   index and search a billion-point dataset on a single node with just 64 GB
   RAM and an SSD. In-memory indexes like HNSW require the entire index to fit
   in RAM, DiskANN doesn't.

   The internal graph algorithm is called Vamana. DiskANN is the full system
   (Vamana graph + SSD-based search + quantization pipeline). SQL Server 2025
   implements the Vamana graph index and calls it DiskANN.

   Here's how the graph is structured:

     - Every vector in the table is a NODE
     - Each node has directed out-edges to its approximate nearest neighbors
     - Vamana builds graphs with smaller diameter than HNSW and NSG —
       fewer hops means fewer disk reads at query time (§1.1)

   Graph structure (simplified): shows the medoid as the fixed entry point, 
   local neighborhood edges, and the long-range edge (the key thing Vamana 
   adds that HNSW and NSG don't):

      s (medoid) ──────────────────────────────────────── (far)  ← long-range edge
           │  \
           ▼   ▼
          (A)  (B) ──► (E)
           │
           ▼
          (C) ──► (D) ──► (F)
           │
           ▼
          (G)

   At query time, the engine runs GreedySearch (Algorithm 1 in the paper):
     1. Start at the graph's medoid s — the fixed entry node for all queries
     2. Pick p* = the unvisited candidate in L closest to the query vector
     3. Add p*'s out-neighbors to L; mark p* as visited
     4. If |L| exceeds the search list size, prune to the closest L points
     5. Repeat until every candidate in L is visited; return the top k

   GreedySearch toward query q (k=2, simplified — lower dist = closer match):

   GreedySearch traversal — shows the candidate list L evolving hop by hop, 
   converging on G and D as the two nearest neighbors to query q after visiting 
   just 4 nodes out of N total. The node names are consistent across both 
   diagrams so you can trace the path s → A → C → G through the graph structure 
   above.

      start   L = { s(0.82) }
      hop 1   p* = s  →  L = { A(0.61),  B(0.74),  far(0.95) }
      hop 2   p* = A  →  L = { C(0.44),  D(0.58),  B(0.74),  far(0.95) }
      hop 3   p* = C  →  L = { G(0.31),  D(0.58),  B(0.74),  far(0.95) }
      hop 4   p* = G  →  no closer unvisited  →  done

      return top 2: G(0.31), D(0.58)  — 4 nodes visited, rest skipped

   The paper proves (§2.2) that with α > 1, GreedySearch converges in
   logarithmically many steps. In practice, Vamana makes 2–3× fewer hops
   than HNSW and NSG (§4.2). On 1 billion SIFT vectors, DiskANN hits
   >5,000 QPS at <3ms latency with 95%+ recall. That's the speed win
   versus O(n) for a full table scan.

   The trade-off: it's approximate. It may miss some true nearest neighbors.
   Section 3 shows how often that happens (spoiler: rarely).

   SQL Server 2025 ships DiskANN as a PREVIEW feature. You opt in at the
   database level before creating the index.
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
   1b. Building the DiskANN index — and watching the clock
   -----------------------------------------------------------------------------
   The build phase:
     1. Reads every vector in the table
     2. Computes approximate pairwise distances to construct the graph
     3. Persists the graph to the EMBEDDINGS filegroup

   Build complexity is roughly O(n log n) — meaningfully faster than O(n²)
   exhaustive indexing. MAXDOP controls the degree of build parallelism.

   We drop and rebuild here so you can see the actual timing. On the default
   1,000-row dataset the build is fast (~7 seconds). On the full 10,000-row
   corpus it takes ~25 seconds (~24,500 ms measured on Apple Silicon M-series).
   See Section 4d for resource monitoring during the build.

   NOTE: SQL Server 2025 (earlier-version DiskANN) makes the table READ-ONLY
   while the vector index exists. Section 4a covers this limitation in detail.
----------------------------------------------------------------------------- */

-- Remove the existing index so we can time a fresh build:
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  name      = 'vec_idx'
      AND  object_id = OBJECT_ID('dbo.QuestionEmbeddings')
)
    DROP INDEX vec_idx ON dbo.QuestionEmbeddings;
GO

-- Time the build:
DECLARE @build_start DATETIME2 = SYSDATETIME();

CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (
    metric  = 'cosine',    -- cosine | euclidean | dot  (must match VECTOR_DISTANCE calls)
    type    = 'diskann',   -- only DiskANN is supported in SQL Server 2025
    maxdop  = 8            -- parallelism for the graph construction phase
);

SELECT
    DATEDIFF(MILLISECOND, @build_start, SYSDATETIME()) AS build_time_ms,
    (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)      AS rows_indexed;
GO


/* -----------------------------------------------------------------------------
   1c. Inspecting the index in the catalog
   -----------------------------------------------------------------------------
   After the build, the vector index appears in sys.indexes alongside the
   clustered index on the same table. type_desc identifies it.
----------------------------------------------------------------------------- */

-- All indexes on QuestionEmbeddings:
SELECT
    i.name              AS index_name,
    i.type_desc         AS index_type,
    i.is_unique,
    c.name              AS indexed_column
FROM sys.indexes      i
JOIN sys.index_columns ic ON ic.object_id = i.object_id
                          AND ic.index_id  = i.index_id
JOIN sys.columns      c  ON c.object_id   = ic.object_id
                          AND c.column_id  = ic.column_id
WHERE i.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
ORDER BY i.index_id;
GO

-- sys.vector_indexes is a catalog view available on SQL Server 2025 on-prem.
-- It shows the DiskANN index type, distance metric, and build parameters.
-- build_parameters.Version tells you whether this is the earlier-version (no
-- Version key, or Version < 3) or the latest-version (Version = 3) index.
-- Earlier-version (SQL Server 2025 on-prem): no Version key in JSON.
-- Latest-version (Azure SQL DB / Fabric after March 2026): Version = 3.
SELECT
    i.name                                          AS index_name,
    v.vector_index_type,                            -- 'DiskANN'
    v.distance_metric,                              -- 'COSINE' | 'DOT' | 'EUCLIDEAN'
    JSON_VALUE(v.build_parameters, '$.Version')     AS index_version,    -- NULL = earlier-version
    v.build_parameters
FROM sys.vector_indexes v
JOIN sys.indexes        i  ON i.object_id = v.object_id
                           AND i.index_id  = v.index_id
WHERE v.object_id = OBJECT_ID('dbo.QuestionEmbeddings');
GO
-- NOTE: sys.dm_db_vector_indexes (DMV with staleness metrics) is Azure SQL DB /
-- Fabric only. sys.vector_indexes (catalog view) is available everywhere.

-- Physical size of the DiskANN graph structure on disk:
-- Note: sys.dm_db_index_physical_stats does not expose VECTOR index internals —
-- it returns rows but page_count is 0 for the VECTOR index type.
-- Use sys.dm_db_index_operational_stats or simply observe the data file growth
-- after CREATE VECTOR INDEX as the practical size indicator.
SELECT
    i.name                              AS index_name,
    i.type_desc                         AS index_type,
    ips.page_count,
    ips.page_count * 8                  AS size_KB,
    ips.avg_fragmentation_in_percent
FROM sys.dm_db_index_physical_stats(
         DB_ID(), OBJECT_ID('dbo.QuestionEmbeddings'), NULL, NULL, 'LIMITED'
     ) ips
JOIN sys.indexes i ON i.object_id = ips.object_id
                   AND i.index_id  = ips.index_id
WHERE i.type_desc = 'VECTOR';
GO
-- page_count = 0 for VECTOR indexes in this DMV — this is expected.
-- The DiskANN graph data is stored in a dedicated internal structure.
-- Compare the EMBEDDINGS filegroup .ndf file size before/after index creation
-- for a real disk-space measurement (typically 1–3× the raw vector payload).


/* =============================================================================
   SECTION 2 — PERFORMANCE: ANN vs. kNN SIDE-BY-SIDE IO COMPARISON
   ============================================================================= */

/* -----------------------------------------------------------------------------
   The same semantic question, answered two ways — exact kNN (table scan) and
   approximate ANN (DiskANN graph walk). SET STATISTICS IO / TIME shows the
   exact cost of each path in logical reads and elapsed milliseconds.

   Watch the Messages tab while each query runs. The numbers tell the story
   more clearly than any benchmark chart.
----------------------------------------------------------------------------- */

-- ── Exact kNN ─────────────────────────────────────────────────────────────────
PRINT '--- EXACT kNN (full table scan) ---';
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'my git history is a mess — how do I clean it up before code review?';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

SELECT TOP (10)
    p.Id,
    p.Title,
    p.Score,
    VECTOR_DISTANCE('cosine', @search_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
ORDER BY distance;
GO
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- ── ANN (DiskANN index) ────────────────────────────────────────────────────────
PRINT '--- ANN (DiskANN graph walk) ---';
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @search_text   NVARCHAR(MAX) = N'my git history is a mess — how do I clean it up before code review?';
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

-- WHAT TO LOOK FOR:
--   kNN  logical reads: high (full scan of the embeddings data file)
--   ANN  logical reads: much lower (graph traversal touches a small subset)
--   kNN  elapsed time:  proportional to row count
--   ANN  elapsed time:  roughly constant, bounded by graph traversal depth
--
-- At 10,000 rows: kNN reads 7,043 pages from QuestionEmbeddings (full scan of
-- every row); ANN reads 52 graph edge pages — ~15× faster elapsed time.
-- At 1,000,000 rows the kNN path would take seconds to minutes; the ANN path
-- stays in milliseconds.


/* =============================================================================
   SECTION 3 — RECALL: MEASURING ANN ACCURACY AGAINST EXACT kNN
   ============================================================================= */

/* -----------------------------------------------------------------------------
   Recall@K = |ANN top-K ∩ kNN top-K| / K

   A recall of 1.0 means ANN returned exactly the same K results as the
   exhaustive search. DiskANN typically achieves recall > 0.95 in practice
   at the default parameters.

   This matters for RAG: if ANN misses the single best-matching chunk,
   your LLM gets worse context. A high-recall ANN index means you get
   near-exact quality with a fraction of the cost.

   We run the measurement for a single test query here. In production you'd
   average over hundreds of representative queries to get a stable recall
   estimate for your dataset and model.
----------------------------------------------------------------------------- */

-- All of the following runs in one batch (no GO) so variables are in scope
-- for both the kNN and ANN queries.

SET NOCOUNT ON;

DECLARE @test_prompt  NVARCHAR(MAX) = N'how do I undo my last git commit?';
DECLARE @test_vector  VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@test_prompt USE MODEL ollama);
DECLARE @k            INT           = 10;

-- Step 1: Exact kNN top-K (ground truth):
SELECT TOP (@k)
    qe.PostId,
    VECTOR_DISTANCE('cosine', @test_vector, qe.embeddings) AS exact_distance
INTO #knn_results
FROM dbo.QuestionEmbeddings qe
ORDER BY exact_distance;

-- Step 2: ANN top-K:
SELECT
    t.PostId,
    s.distance AS ann_distance
INTO #ann_results
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @test_vector,
    METRIC     = 'cosine',
    TOP_N      = @k
) AS s;

-- Step 3: Compute recall@K:
SELECT
    @k                                      AS k,
    COUNT(ann.PostId)                       AS matched_in_both,
    CAST(COUNT(ann.PostId) AS FLOAT) / @k   AS recall_at_k
FROM #ann_results ann
JOIN #knn_results knn ON ann.PostId = knn.PostId;

-- Step 4: Show which results differ (if any):
SELECT
    'in kNN only (missed by ANN)' AS source,
    knn.PostId,
    p.Title,
    knn.exact_distance
FROM #knn_results knn
LEFT JOIN #ann_results ann ON ann.PostId = knn.PostId
JOIN dbo.Posts p ON knn.PostId = p.Id
WHERE ann.PostId IS NULL

UNION ALL

SELECT
    'in ANN only (false positive)' AS source,
    ann.PostId,
    p.Title,
    ann.ann_distance
FROM #ann_results ann
LEFT JOIN #knn_results knn ON knn.PostId = ann.PostId
JOIN dbo.Posts p ON ann.PostId = p.Id
WHERE knn.PostId IS NULL;

DROP TABLE IF EXISTS #knn_results;
DROP TABLE IF EXISTS #ann_results;
GO

-- WHAT THE RECALL NUMBER TELLS YOU:
--   recall_at_k = 1.0  → ANN returned identical results to exhaustive search.
--   recall_at_k = 0.9  → 9 of 10 results match; 1 true neighbor was missed.
--   For a RAG workload the missed neighbor would need to be the #1 most relevant
--   chunk AND the other 9 would need to be irrelevant — a pathological scenario.
--   In practice, high recall (> 0.95) means your retrieval quality is intact.


/* =============================================================================
   SECTION 4 — LIMITATIONS: WHERE VECTOR INDEXES HELP AND WHERE THEY DON'T
   ============================================================================= */

/* -----------------------------------------------------------------------------
   4a. LIMITATION: Read-only table after CREATE VECTOR INDEX (SQL Server 2025)
   -----------------------------------------------------------------------------
   STATUS: This limitation exists in SQL Server 2025 on-premises (the
   "earlier-version" DiskANN index). It's RESOLVED in the latest-version
   DiskANN index available on Azure SQL Database and SQL database in Fabric
   (announced March 2026 — see Section 5 for the full story).

   In SQL Server 2025 (the "earlier-version" DiskANN index), creating a vector
   index makes the underlying table READ-ONLY. INSERT, UPDATE, DELETE, and
   MERGE all fail with an error.

   This is a significant operational constraint for workloads that need to
   continuously add new embeddings as new content arrives.

     WORKAROUND — Drop-insert-rebuild cycle: offline maintenance window
                    (the only option on SQL Server 2025 on-prem today).

   On Azure SQL DB / Fabric (latest-version): no workaround needed. Tables
   are fully writable. The index maintains itself asynchronously in the
   background. See Section 5b for the live demo.
----------------------------------------------------------------------------- */

-- Confirm the index exists:
SELECT name, type_desc FROM sys.indexes
WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings');
GO

-- Try to INSERT with the vector index in place:
-- Msg 42231 is not catchable with TRY/CATCH — it surfaces as a hard error.
-- Run this and watch the error message appear directly.
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
   4b. LIMITATION: Filtered search — no predicate pushdown into the graph
   -----------------------------------------------------------------------------
   STATUS: This limitation exists in SQL Server 2025 on-premises (earlier-
   version DiskANN). It's RESOLVED by iterative filtering in the latest-
   version DiskANN on Azure SQL Database / Fabric. See Section 5c.

   VECTOR_SEARCH returns the TOP_N approximate nearest neighbors from the
   ENTIRE graph, and THEN the outer query's WHERE clause filters that candidate
   set. The filter is NOT pushed into the graph traversal.

   Risk: if your filter is very selective, all TOP_N ANN candidates may fail
   the filter — returning zero rows, even though an exact kNN search would have
   found matches.

   Mitigation (SQL Server 2025 on-prem): increase TOP_N to produce a larger
   candidate pool, giving the post-filter more material to work with.
   This is sometimes called "oversampling."
----------------------------------------------------------------------------- */

-- Shared query text for all three variants below:
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div vertically and horizontally';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

-- Version 1: tight TOP_N (5) + selective filter — may return fewer than 5 rows:
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

-- Version 2: oversampled TOP_N (50) + same filter — post-filter has more material:
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

-- Version 3: exact kNN with same filter — the "correct" answer for comparison:
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
WHERE p.Score > 500    -- filter runs over the full scan — always correct
ORDER BY distance;
GO

-- TAKEAWAY: for ANN + filter workloads, oversample TOP_N by the inverse of
-- your filter selectivity. If roughly 1 in 10 rows passes the filter, use
-- TOP_N = 10 × your desired K to maintain result quality.


/* -----------------------------------------------------------------------------
   4c. LIMITATION: Dimensionality constraints
   -----------------------------------------------------------------------------
   The VECTOR type in SQL Server 2025 supports 1 to 1,998 dimensions (float32)
   or 1 to 3,996 dimensions (float16 — see Demo 01 Section 1e).
   This covers all common embedding models:

     nomic-embed-text             768 dimensions   (this demo)
     mxbai-embed-large           1024 dimensions
     text-embedding-3-small      1536 dimensions
     text-embedding-ada-002      1536 dimensions
     text-embedding-3-large (ADA) 3072 dimensions  → needs float16!

   float16 exactly doubles the ceiling:
     VECTOR(3072)            → error on float32 (exceeds 1,998)
     VECTOR(3072, float16)   → works (≤ 3,996), uses 6,144 bytes

   A vector index can only be built on a VECTOR(n) column with a fixed,
   known n. You can't index a column that stores vectors of varying dimensions.

   Changing models (e.g., upgrading from 768-dim to 1536-dim) requires:
     - A new or altered VECTOR column with the new dimension count
     - Re-embedding ALL rows (existing vectors are from a different model's
       coordinate space and aren't comparable to new-model vectors)
     - Dropping and rebuilding the vector index on the new column
----------------------------------------------------------------------------- */

-- Show the current column definition using the new sys.columns metadata:
-- (vector_dimensions is preferred over max_length/4 — see Demo 01 Section 1e)
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

-- Attempt to exceed the float32 maximum — shows the enforced limit:
BEGIN TRY
    CREATE TABLE #dim_test ( v VECTOR(1999) );
    PRINT 'VECTOR(1999) created — current limit is above 1998.';
    DROP TABLE IF EXISTS #dim_test;
END TRY
BEGIN CATCH
    PRINT 'Error: ' + ERROR_MESSAGE();
    PRINT '=> VECTOR(1999) exceeds the float32 maximum (1,998 dims).';
    PRINT '   Use VECTOR(1999, float16) to go beyond 1,998 dimensions.';
END CATCH;
GO

-- float16 allows up to 3,996 dims — can hold text-embedding-3-large (3072):
BEGIN TRY
    CREATE TABLE #dim_float16 ( v VECTOR(3072, float16) );
    PRINT 'VECTOR(3072, float16) created — float16 ceiling is 3,996 dims.';
    DROP TABLE IF EXISTS #dim_float16;
END TRY
BEGIN CATCH
    PRINT 'Error: ' + ERROR_MESSAGE();
END CATCH;
GO

-- The confirmed float32 maximum (1998):
BEGIN TRY
    CREATE TABLE #dim_max ( v VECTOR(1998) );
    PRINT 'VECTOR(1998) created — max float32 dimensions in SQL Server 2025.';
    DROP TABLE IF EXISTS #dim_max;
END TRY
BEGIN CATCH
    PRINT 'Error: ' + ERROR_MESSAGE();
END CATCH;
GO


/* -----------------------------------------------------------------------------
   4d. LIMITATION: Index build resource cost at scale
   -----------------------------------------------------------------------------
   DiskANN graph construction is CPU-intensive and I/O-intensive. For large
   embedding tables:

     - CPU: MAXDOP controls parallelism. Set to the number of available cores
       for a background maintenance window; reduce for production OLTP coexistence.
     - Memory: The build holds graph state in the buffer pool. Monitor total
       server memory pressure during the build.
     - I/O: The resulting graph is written to the EMBEDDINGS filegroup. Size it
       at 1–3× the raw vector data size.

   Monitor an in-progress build with sys.dm_exec_requests.
   Run the query below in a SECOND connection window while CREATE VECTOR INDEX
   executes in the first window.
----------------------------------------------------------------------------- */

-- Remove the existing index so we can time a fresh build:
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  name      = 'vec_idx'
      AND  object_id = OBJECT_ID('dbo.QuestionEmbeddings')
)
    DROP INDEX vec_idx ON dbo.QuestionEmbeddings;
GO

CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (
    metric  = 'cosine',    -- cosine | euclidean | dot  (must match VECTOR_DISTANCE calls)
    type    = 'diskann',   -- only DiskANN is supported in SQL Server 2025
    maxdop  = 8            -- parallelism for the graph construction phase
);

-- Run this in a second connection while CREATE VECTOR INDEX runs in another:
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
WHERE r.command LIKE '%CREATE VECTOR INDEX%'
   AND t.text    LIKE '%CREATE VECTOR INDEX%';
GO 

-- Post-build: compare raw vector data size vs. DiskANN graph structure size:
-- TODO: THIS RETURNS NO ROWS
SELECT
    SUM(CASE WHEN i.index_id IN (0, 1) THEN au.data_pages * 8.0 / 1024
             ELSE 0 END)  AS table_data_MB,
    SUM(CASE WHEN i.type_desc = 'VECTOR' THEN au.data_pages * 8.0 / 1024
             ELSE 0 END)  AS diskann_index_MB
FROM sys.indexes          i
JOIN sys.partitions       p  ON p.object_id  = i.object_id
                             AND p.index_id   = i.index_id
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
WHERE i.object_id = OBJECT_ID('dbo.QuestionEmbeddings');
GO
-- The ratio (index_MB / table_data_MB) is the storage overhead of ANN capability.
-- Typical range: 1×–3×. A higher ratio means more edges in the graph,
-- which gives better recall but costs more storage and build time.

/* -----------------------------------------------------------------------------
   4e. EXECUTION PLAN ANATOMY — the Vector Index Seek operator
   -----------------------------------------------------------------------------
   Unlike a Clustered Index Scan (full table read) or a B-tree Index Seek
   (point/range lookup), VECTOR_SEARCH introduces a purpose-built plan operator:

       Vector Index Seek

   Read the plan in SSMS (Ctrl+M) or query sys.dm_exec_cached_plans directly.
   The ANN plan shape is:

       Top
        └─ Nested Loops (Inner Join)
            ├─ Vector Index Seek     ← DiskANN graph walk, returns TOP_N node IDs
            └─ Clustered Index Seek  ← PK lookup per result to fetch row data

   Contrast with the exact kNN plan from Section 5 (no vector index):

       Top (TopN Sort)
        └─ Clustered Index Scan      ← full heap/CI scan over all 10,000 rows
            └─ Compute Scalar        ← VECTOR_DISTANCE computed for every row

   The key difference: Vector Index Seek visits ~52 graph edge pages vs.
   7,043 data pages for the full scan (see Section 2 IO comparison).
----------------------------------------------------------------------------- */
--TODO: This thows this error when i try to view the plan There is an error in XML document (1, 6188). ---> Instance validation error: 'Vector Index Seek' is not a valid value for PhysicalOpType.
-- Run this, then open the actual execution plan in SSMS (Ctrl+M before running):

DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama
);
SELECT TOP(5)
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

-- WHAT TO LOOK FOR in the graphical plan:
--   Node 0  Top              — enforces the 5-row limit
--   Node 1  Nested Loops     — for each ANN result, fetch the row
--   Node 2  Vector Index Seek — graph traversal: shows estimated/actual rows,
--                               index name 'vec_idx', and cost ~0.13 total
--   Node 3  Clustered Index Seek — PK lookup on QuestionEmbeddings.PostId

-- Query the plan cache directly to see the operator tree without SSMS:
SET QUOTED_IDENTIFIER ON;
GO
SELECT
    r.value('@NodeId',                    'INT')           AS node_id,
    r.value('@PhysicalOp',                'NVARCHAR(100)') AS physical_op,
    ROUND(r.value('@EstimateRows',        'FLOAT'), 1)     AS est_rows,
    ROUND(r.value('@EstimatedTotalSubtreeCost', 'FLOAT'), 4) AS subtree_cost
FROM sys.dm_exec_cached_plans cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) qp
CROSS APPLY qp.query_plan.nodes(
    'declare namespace x="http://schemas.microsoft.com/sqlserver/2004/07/showplan";
     //x:RelOp') AS n(r)
WHERE qp.query_plan IS NOT NULL
  AND CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE '%Vector Index Seek%'
  AND CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE '%undo%'
ORDER BY r.value('@EstimatedTotalSubtreeCost', 'FLOAT') DESC;
GO

-- EXPECTED OUTPUT:
--   node_id  physical_op           est_rows  subtree_cost
--   -------  --------------------  --------  ------------
--         0  Top                        1.0        0.1355
--         1  Nested Loops               1.0        0.1355
--         2  Nested Loops               1.0        0.1322
--         3  Vector Index Seek          1.0        0.1289   ← DiskANN
--        36  Clustered Index Seek       1.0        0.0033   ← PK lookup


/* -----------------------------------------------------------------------------
   4f. STRESS TEST: the silent zero-results failure
   -----------------------------------------------------------------------------
   This is the most dangerous production pitfall with earlier-version DiskANN.
   It produces no error — just silently returns zero rows.

   SETUP: find questions with Score > 5,000 that are semantically related to
   CSS centering. There are 21 such questions in the 10,000-row embedded set
   (0.21% selectivity). But if TOP_N is too small, none of the ANN candidates
   pass the filter.

   STEP 1: ANN with tight TOP_N=5 and a selective Score filter.
   Expected: 0 rows — all 5 ANN candidates have Score < 5,000.
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

-- STEP 2: Diagnose — what DID the ANN retrieve before the filter?
-- Remove the WHERE clause to see the raw ANN candidates and their scores.
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div in CSS';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- Step 2: Diagnose — ANN TOP_N=5 WITHOUT filter (raw candidates) ---';
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
-- All 5 scores are < 5,000: 596, 86, 728, 842, 428.
-- The filter is correct — there just aren't any high-score results in this batch.
GO

-- STEP 3: Confirm the data DOES exist — exact kNN finds it.
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div in CSS';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- Step 3: Exact kNN, Score > 5000 (ground truth — proves data exists) ---';
SELECT TOP(5) qe.PostId, p.Score,
    VECTOR_DISTANCE('cosine', @search_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
WHERE p.Score > 5000
ORDER BY distance;
-- Returns 5 rows — highest scored questions nearest to "center a div in CSS".
-- PostIds: 503093 (Score 7740), 477816 (Score 9081), 1642028 (Score 7623),
--          927358 (Score 17388), 178325 (Score 6591).
-- distance ~0.43–0.48 — further away than the TOP_N=5 candidates (0.17–0.21)
-- which is WHY the ANN didn't include them: closer-but-lower-scored rows
-- dominate the graph neighbourhood.
GO

-- STEP 4: Fix — oversample TOP_N to cover the filter's selectivity.
-- 21 of 10,000 embedded questions have Score > 5000 → ~0.21% selectivity.
-- 1,566 rows are closer to the query than the furthest qualifying result.
-- TOP_N=500 returns only 1 of 5 correct results; TOP_N=2500 returns all 5.
-- Rule of thumb: TOP_N ≥ K / selectivity = 5 / 0.0021 ≈ 2381. Use 2500.
DECLARE @search_text   NVARCHAR(MAX) = N'how do I center a div in CSS';
DECLARE @search_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@search_text USE MODEL ollama);

PRINT '--- Step 4: ANN TOP_N=2500, Score > 5000 (oversampled — correct) ---';
SELECT TOP(5) t.PostId, p.Score, s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 2500       -- covers ~25% of the corpus; filter has material to work with
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
--   eliminates this problem entirely — the engine searches until it finds K
--   qualifying rows, regardless of filter selectivity.
GO


/* =============================================================================
   SECTION 5 — LATEST-VERSION DiskANN: WHAT'S NEW (Azure SQL DB / Fabric)
   =============================================================================

   In March 2026, Microsoft shipped a major upgrade to DiskANN on Azure SQL
   Database and SQL database in Microsoft Fabric. This section demonstrates
   all four improvements. The SQL Server 2025 on-premises container in this
   repo runs the EARLIER-VERSION index, so Sections 5b–5d show code you would
   run against Azure SQL DB — but the patterns and catalog observations apply
   to what is coming to the on-prem product.

   Summary of changes
   ───────────────────
   Earlier-version (SQL Server 2025 on-prem)    Latest-version (Azure SQL DB / Fabric)
   ────────────────────────────────────────     ──────────────────────────────────────
   Table READ-ONLY after CREATE VECTOR INDEX    Full DML: INSERT / UPDATE / DELETE / MERGE
   Filters applied AFTER graph walk             Iterative filtering: filters IN the walk
   Manual TOP_N oversampling needed             SELECT TOP (N) WITH APPROXIMATE
   No staleness DMV                             sys.dm_db_vector_indexes
   ALLOW_STALE_VECTOR_INDEX workaround          No workaround needed
   ============================================================================= */


/* -----------------------------------------------------------------------------
   5a. Check which DiskANN version you are running
   -----------------------------------------------------------------------------
   The new DMV sys.dm_db_vector_indexes is only present in the latest-version
   deployment. Use it as a version probe: NULL means earlier-version (SQL
   Server 2025 on-prem or a region that hasn't received the upgrade yet).

   From the blog (March 2026):
       -- Check if the new DMV exists
       SELECT OBJECT_ID('sys.dm_db_vector_indexes') AS new_dmv_available;
       -- NULL  → earlier-version
       -- non-NULL → latest-version, full DML + iterative filtering available
----------------------------------------------------------------------------- */

SELECT
    OBJECT_ID('sys.dm_db_vector_indexes') AS new_dmv_present,
    CASE
        WHEN OBJECT_ID('sys.dm_db_vector_indexes') IS NULL
        THEN 'Earlier-version DiskANN (SQL Server 2025 on-prem / unupgraded Azure region)'
        ELSE 'Latest-version DiskANN (full DML + iterative filtering available)'
    END AS diskann_version;
GO

-- On this demo container the result will be NULL (earlier-version).
-- On Azure SQL Database (after March 2026 rollout) it returns a non-NULL object_id.


/* -----------------------------------------------------------------------------
   5b. Latest-version: new query syntax — SELECT TOP (N) WITH APPROXIMATE
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

   WITH APPROXIMATE signals to the optimizer that approximate results are
   acceptable. The optimizer then decides whether to use the DiskANN index
   or fall back to exact kNN based on data size, predicates, and cost.

   MIGRATION WARNING: if you create a latest-version index and keep the
   old TOP_N syntax, the query fails with Msg 42274. Update the query
   BEFORE migrating the index.
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

-- Latest-version syntax (for Azure SQL DB after March 2026 rollout):
-- Run this against Azure SQL DB once your region has received the upgrade.
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
   5c. Latest-version: iterative filtering
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

-- Show the current on-prem oversampling workaround in action (Section 4b
-- above). This is the code you would SIMPLIFY when moving to Azure SQL DB.
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
-- SELECT TOP (5) WITH APPROXIMATE — the filter runs inside the walk.


/* -----------------------------------------------------------------------------
   5d. Latest-version: sys.dm_db_vector_indexes — staleness monitoring
   -----------------------------------------------------------------------------
   In the latest-version, DML is applied asynchronously: your INSERT/UPDATE/
   DELETE commits immediately, and the background maintenance queue integrates
   the change into the DiskANN graph. The DMV exposes this process.

   Key columns:
     approximate_staleness_percent
         Proportion of recent DML changes not yet integrated into the graph.
         Fluctuates during active write workloads; approaches 0 between bursts.
         Non-zero staleness does NOT mean rows are invisible — recently changed
         rows ARE returned by searches; recall may be slightly lower until the
         background task catches up.

     last_background_task_succeeded
         True when the last maintenance cycle completed without errors.
         Monitor this in production. A sustained False indicates a problem.

   On the earlier-version (this SQL Server 2025 container), the DMV does not
   exist. The query below checks first and explains which version you're on.
----------------------------------------------------------------------------- */

IF OBJECT_ID('sys.dm_db_vector_indexes') IS NOT NULL
BEGIN
    PRINT 'Latest-version DMV available — querying staleness...';
    SELECT
        OBJECT_NAME(object_id)          AS table_name,
        index_id,
        approximate_staleness_percent,
        last_background_task_succeeded
    FROM sys.dm_db_vector_indexes
    WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings');
END
ELSE
BEGIN
    PRINT 'sys.dm_db_vector_indexes does not exist on this instance.';
    PRINT 'This is the earlier-version DiskANN index (SQL Server 2025 on-prem).';
    PRINT 'Use sys.dm_db_index_physical_stats to inspect the index size instead.';
    SELECT
        i.name                              AS index_name,
        i.type_desc,
        ips.page_count,
        ips.page_count * 8                  AS size_KB
    FROM sys.dm_db_index_physical_stats(
             DB_ID(), OBJECT_ID('dbo.QuestionEmbeddings'), NULL, NULL, 'LIMITED'
         ) ips
    JOIN sys.indexes i ON i.object_id = ips.object_id
                       AND i.index_id  = ips.index_id
    WHERE i.type_desc = 'VECTOR';
END
GO


/* -----------------------------------------------------------------------------
   5e. Migration path: earlier-version → latest-version on Azure SQL DB
   -----------------------------------------------------------------------------
   If you created a DiskANN index during the November 2025 preview on Azure
   SQL DB, it uses the older data structure. To get full DML + iterative
   filtering + the new syntax:

     STEP 1 — Update your application queries FIRST.
              Change all VECTOR_SEARCH calls from TOP_N parameter to
              SELECT TOP (N) WITH APPROXIMATE syntax (Section 5b).
              If you migrate the index without updating queries, searches
              fail with Msg 42274.

     STEP 2 — Drop and recreate the index. The CREATE syntax is UNCHANGED.

              DROP INDEX vec_idx ON dbo.QuestionEmbeddings;

              CREATE VECTOR INDEX vec_idx
              ON dbo.QuestionEmbeddings([embeddings])
              WITH (METRIC = 'cosine', TYPE = 'diskann');
              -- That's it. The new index is automatically latest-version.

     STEP 3 — Verify with the DMV.

              SELECT OBJECT_ID('sys.dm_db_vector_indexes');   -- non-NULL = good

   On SQL Server 2025 on-prem: no migration to perform yet. The on-premises
   product ships the earlier-version index today. When Microsoft ships the
   latest-version to on-prem, the migration steps above will apply.
   Until then, the DROP-INSERT-REBUILD cycle in Demo 03 Section 4b is the
   correct on-prem maintenance pattern.
----------------------------------------------------------------------------- */

-- Summary: where each feature lives today (July 2026):
SELECT
    feature,
    sql_server_2025_onprem,
    azure_sql_db_fabric
FROM (VALUES
    ('Full DML (no read-only restriction)',    'Workaround required',    'GA'),
    ('Iterative filtering (predicate in walk)','Manual oversampling',    'GA'),
    ('SELECT TOP (N) WITH APPROXIMATE syntax', 'Not supported (use TOP_N)','GA'),
    ('sys.dm_db_vector_indexes DMV',           'Not available',          'GA'),
    ('Async background index maintenance',     'Not available',          'GA'),
    ('Improved quantization / faster builds',  'Not available',          'GA')
) AS t(feature, sql_server_2025_onprem, azure_sql_db_fabric);
