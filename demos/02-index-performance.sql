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

  RECOMMENDED — expand to 10,000 rows. The numbers in this file assume it:
    The startup script embeds 1,000 questions. For the full 10,000-row corpus
    (needed for §2 IO comparison, §2b scale, and §4f), run:

        bash setup/expand-embeddings.sh

    (~30 min on an M2 with Ollama on the host — see script for batch progress).

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run sections top-to-bottom. Every section is idempotent.

  TIME BUDGET: 25 of the 60 demo minutes (75-minute slot, 15 for Q&A).
    1a     how DiskANN works          5 min
    1b-1c  build + where it lives     4 min
    2      IO and scale               6 min
    3      recall                     3 min
    4a,4f  read-only + zero results   4 min
    4g     the rest of the limits     1 min
    5a,5e  what's next on Azure       2 min
    [OPTIONAL] 4b-4e and 5b-5d are deep dives for Q&A.

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

   Graph structure (simplified). s is the medoid, the fixed entry point. Most
   edges are local. Vamana's pruning with α > 1 also keeps long-range edges.
   HNSW and NSG effectively use α = 1, which is why Vamana gets a smaller
   diameter at the same degree (§2.4):

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

   GreedySearch toward query q (k=2, simplified, lower dist = closer match).
   Follow the path s → A → C → G through the graph above:

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
     2. Runs the Vamana build: a GreedySearch from the medoid for every point,
        then prunes each node's edges down to the degree bound R
     3. Persists the graph to internal tables (Section 1c shows them)

   MAXDOP: the CREATE VECTOR INDEX syntax accepts it, but SQL Server 2025
   ignores it. That's a documented known issue, so we leave it off.
     https://learn.microsoft.com/en-us/sql/sql-server/sql-server-2025-known-issues

   We drop and rebuild here so you can see the actual timing. Measured on
   this stack (SQL Server 2025 CU10, Apple Silicon M2):
     1,000 rows    ~11 seconds
     10,000 rows   anywhere from ~23 seconds to ~2 minutes on a running
                   instance, and ~340 seconds right after a restart
   Build time swings a lot with what's cached and what else the box is
   doing. Measure it on your hardware before you size a maintenance window.

   LIVE-DEMO TIP: budget two minutes. Start the build, then walk back
   through the GreedySearch diagram in 1a while it runs. If you're short
   on time, skip the DROP/CREATE and just run 1c against the existing index.

   NOTE: SQL Server 2025 (earlier-version DiskANN) makes the table READ-ONLY
   while the vector index exists. Section 4a covers this limitation in detail.
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
-- edges and one for quantized vectors.
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

-- Rank in the satellite table, then join the 10 winners (Demo 01 Section 5a).
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

-- WHAT TO LOOK FOR (measured on this stack, 10,000 rows, warm cache):
--
--                      kNN (scan)      ANN (graph walk)
--   QuestionEmbeddings  7,057 reads     2,265 reads
--   Worktable               0             671 reads
--   Graph edge table        —              50 reads
--   Total reads         7,057           2,986
--   CPU time            37-63 ms        8-11 ms
--   Elapsed time        13-28 ms        7-10 ms
--
-- So ANN wins, but not by the 100× the graph reads alone (50) might suggest.
-- The graph itself is cheap (50 reads). Most of the ANN cost is reads on
-- QuestionEmbeddings itself. The IO suggests the walk fetches the stored
-- vector for the candidates it scores, much like the paper's full-precision
-- re-ranking (§3.5). The docs don't describe this, so treat it as observed.
--
-- And at 1,000 rows ANN LOSES: about 1,555 total reads vs 502 for the scan.
-- Small tables don't need a vector index. Section 2b shows the crossover.


/* -----------------------------------------------------------------------------
   2b. Scale: how each path grows with row count
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


/* =============================================================================
   SECTION 3 — RECALL: MEASURING ANN ACCURACY AGAINST EXACT kNN
   ============================================================================= */

/* -----------------------------------------------------------------------------
   Recall@K = |ANN top-K ∩ kNN top-K| / K

   A recall of 1.0 means ANN returned exactly the same K results as the
   exhaustive search. The DiskANN paper reports 95%+ 1-recall@1 on a billion
   SIFT vectors. That's their data and their parameters, not yours. The only
   recall number that matters is the one you measure on your data.

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
   DiskANN index on Azure SQL Database, SQL database in Fabric, and Azure
   SQL Managed Instance with the Always-up-to-date update policy (Section 5).

   In SQL Server 2025 (the "earlier-version" DiskANN index), creating a vector
   index makes the underlying table READ-ONLY. INSERT, UPDATE, DELETE, and
   MERGE fail with Msg 42231. TRUNCATE TABLE fails with Msg 42232. The docs
   list the read-only rule but not the error numbers; these are what this
   build returns.

   ALLOW_STALE_VECTOR_INDEX isn't an option here. The docs say it "isn't
   currently available in SQL Server 2025", and it fails with Msg 102.

   This is a significant operational constraint for workloads that need to
   continuously add new embeddings as new content arrives.

     WORKAROUND — Drop-insert-rebuild cycle: offline maintenance window
                    (the only option on SQL Server 2025 on-prem today).
                    Demo 03 Section 4a runs it live.

   On the latest-version index: no workaround needed. Tables are fully
   writable and the index maintains itself in the background.
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
   4b. [OPTIONAL] LIMITATION: Filtered search — no predicate pushdown into the graph
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
   4c. [OPTIONAL] LIMITATION: Dimensionality constraints
   -----------------------------------------------------------------------------
   The VECTOR type in SQL Server 2025 supports 1 to 1,998 dimensions (float32)
   or 1 to 3,996 dimensions (float16 — see Demo 01 Section 1e).
   This covers all common embedding models:

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
-- Msg 2717 is a compile error, so it has to run in its own scope to be caught.
BEGIN TRY
    EXEC (N'CREATE TABLE #dim_test ( v VECTOR(1999) );');
    PRINT 'VECTOR(1999) created — current limit is above 1998.';
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
   4d. [OPTIONAL] Index build resource cost at scale
   -----------------------------------------------------------------------------
   DiskANN graph construction is CPU-intensive. For large embedding tables:

     - CPU: you can't throttle it with MAXDOP on SQL Server 2025 (the option
       is ignored, a documented known issue). Use Resource Governor or a
       maintenance window instead.
     - Memory: the build holds graph state in memory. Watch memory grants
       and buffer pool pressure while it runs.
     - Storage: the graph lands in internal tables (Section 1c). Measure it
       after the build instead of guessing.

   Monitor an in-progress build with sys.dm_exec_requests.
   Run the query below in a SECOND connection window while CREATE VECTOR INDEX
   executes in the first window.
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
   4e. [OPTIONAL] EXECUTION PLAN ANATOMY — the Vector Index Seek operator
   -----------------------------------------------------------------------------
   Unlike a Clustered Index Scan (full table read) or a B-tree Index Seek
   (point/range lookup), VECTOR_SEARCH introduces a purpose-built plan operator:

       Vector Index Seek

   Read the plan in SSMS (Ctrl+M) or query sys.dm_exec_cached_plans directly.
   The ANN plan shape is:

       Top
        └─ Nested Loops
            ├─ Nested Loops
            │   ├─ Vector Index Seek     ← DiskANN graph walk, returns TOP_N keys
            │   └─ Clustered Index Seek  ← QuestionEmbeddings row lookup
            └─ Clustered Index Seek      ← Posts row lookup

   Contrast with the exact kNN plan from Demo 01 Section 5 (no vector index):

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
--   Node 0   Top                  — enforces the 5-row limit
--   Node 1-2 Nested Loops         — for each ANN result, fetch the rows
--   Node 3   Vector Index Seek    — the graph walk on 'vec_idx', cost ~0.13
--   Node 36  Clustered Index Seek — QuestionEmbeddings lookup
--   Node 37  Clustered Index Seek — Posts lookup

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


/* -----------------------------------------------------------------------------
   4f. STRESS TEST: the silent zero-results failure
   -----------------------------------------------------------------------------
   This is the most dangerous production pitfall with earlier-version DiskANN.
   It produces no error — just silently returns zero rows.

   SETUP: find questions about CSS centering with Score > 5,000. Only 21
   questions in the 10,000-row embedded set have Score > 5,000 at all
   (0.21% selectivity). If TOP_N is too small, none of the ANN candidates
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
-- All 5 scores are < 5,000 (this run: 596, 842, 3549, 428, 728).
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
-- This run: 503093, 178325, 348170, 927358, 477816 (Scores 6,591 to 17,388).
-- distance ~0.49–0.57 — much further away than the TOP_N=5 candidates
-- (0.11–0.15). That's WHY the ANN didn't include them: closer but
-- lower-scored rows fill the top of the list.
GO

-- STEP 4: Fix — oversample TOP_N to cover the filter's selectivity.
-- 21 of 10,000 embedded questions have Score > 5000 → ~0.21% selectivity.
-- 1,713 rows are closer to the query than the furthest qualifying result,
-- so TOP_N has to reach past all of them. TOP_N=2500 returns all 5.
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


/* -----------------------------------------------------------------------------
   4g. The rest of the documented limits, in one minute
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
     - VECTOR_SEARCH with no index on the column fails with Msg 42227 on
       this build. Demo 03 shows how the app's proc handles that.

   Let's see the first two fail:
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


/* =============================================================================
   SECTION 5 — LATEST-VERSION DiskANN: WHAT'S NEW (Azure SQL DB / Fabric)
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
   5a. Check which DiskANN version you are running
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
   5b. [OPTIONAL] Latest-version: new query syntax — SELECT TOP (N) WITH APPROXIMATE
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
   5c. [OPTIONAL] Latest-version: iterative filtering
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
   5d. [OPTIONAL] sys.dm_db_vector_indexes — background maintenance monitoring
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
   5e. Migration path: earlier-version → latest-version on Azure
   -----------------------------------------------------------------------------
   If you created a DiskANN index on Azure SQL DB before the latest version
   arrived, it uses the older structure. To get full DML + iterative
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

     STEP 3 — Verify the version (Section 5a).

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
