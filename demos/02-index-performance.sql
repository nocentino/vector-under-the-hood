SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  Demo 2 of 3: VECTOR INDEX PERFORMANCE AND LIMITATIONS
  DiskANN internals  ·  ANN vs. kNN recall  ·  IO comparison  ·  Real limits
  Latest-version improvements (Azure SQL DB / Fabric)
=============================================================================

  Learning objective:
    Evaluate vector index performance and limitations at scale.

  Prerequisites:
    Demo 1 complete. StackOverflow is restored and QuestionEmbeddings is
    populated. The vec_idx DiskANN index was created at startup by sql-init.

  RECOMMENDED: expand to 10,000 rows. The numbers in this file assume it.
    The startup script embeds 1,000 questions. You'll need the full 10,000-row
    corpus for the §2 IO comparison, §2a scale, and §4b, so run:

        bash setup/expand-embeddings.sh

    (~30 min on my M2 with Ollama on the host. The script shows batch progress.)

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run the sections top to bottom. Every one is idempotent.

  Optional deep dives live in demos/02-index-performance-optional.sql.

=============================================================================
*/

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 1. THE DiskANN INDEX: WHAT IT IS AND HOW TO BUILD IT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   1a. What DiskANN is (conceptually)
   -----------------------------------------------------------------------------
   DiskANN is a graph-based Approximate Nearest Neighbor (ANN) system from
   Microsoft Research (Subramanya et al., NeurIPS 2019):
     https://suhasjs.github.io/files/diskann_neurips19.pdf
   It's built to index and search a billion-point dataset on a single node
   with just 64 GB of RAM and an SSD. In-memory indexes like HNSW need the
   whole index to fit in RAM. DiskANN doesn't.

   The graph algorithm inside is called Vamana. DiskANN is the full system
   (Vamana graph + SSD-based search + quantization pipeline). SQL Server 2025
   implements the Vamana graph index and calls it DiskANN.

   Here's how the graph is structured:

     - Every vector in the table is a NODE
     - Each node has directed out-edges to its approximate nearest neighbors
     - Vamana builds graphs with smaller diameter than HNSW and NSG.
       Fewer hops means fewer disk reads at query time (§1.1)

   Here's a simplified picture. s is the medoid, the fixed entry point. Most
   edges are local, but Vamana's pruning with α > 1 also keeps long-range
   edges. HNSW and NSG effectively use α = 1, which is why Vamana gets a smaller
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
     1. Start at the graph's medoid s, the fixed entry node for all queries
     2. Pick p* = the unvisited candidate in L closest to the query vector
     3. Add p*'s out-neighbors to L; mark p* as visited
     4. If |L| exceeds the search list size, prune to the closest L points
     5. Repeat until every candidate in L is visited; return the top k

   Let's walk GreedySearch toward query q (k=2, simplified, lower dist =
   closer match). Follow the path s → A → C → G through the graph above:

      start   L = { s(0.82) }
      hop 1   p* = s  →  L = { A(0.61),  B(0.74),  far(0.95) }
      hop 2   p* = A  →  L = { C(0.44),  D(0.58),  B(0.74),  far(0.95) }
      hop 3   p* = C  →  L = { G(0.31),  D(0.58),  B(0.74),  far(0.95) }
      hop 4   p* = G  →  no closer unvisited  →  done

      return top 2: G(0.31), D(0.58)  (4 nodes visited, rest skipped)

   The paper proves (§2.2) that with α > 1, GreedySearch converges in
   logarithmically many steps. In practice, Vamana makes 2–3× fewer hops
   than HNSW and NSG (§4.2). On 1 billion SIFT vectors, DiskANN hits
   >5,000 QPS at <3ms latency with 95%+ recall. That's the speed win
   versus O(n) for a full table scan.

   The trade-off: it's approximate, so it can miss some true nearest
   neighbors. Section 3 shows how often that happens (spoiler: rarely).

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
   1b. Building the DiskANN index (and watching the clock)
   -----------------------------------------------------------------------------
   Here's what the build does:
     1. Reads every vector in the table
     2. Runs the Vamana build: a GreedySearch from the medoid for every point,
        then prunes each node's edges down to the degree bound R
     3. Persists the graph to internal tables (Section 1c shows them)

   MAXDOP: the CREATE VECTOR INDEX syntax accepts it, but SQL Server 2025
   ignores it. That's a documented known issue, so I leave it off.
     https://learn.microsoft.com/en-us/sql/sql-server/sql-server-2025-known-issues

   Let's drop and rebuild so you can see the real timing. Here's what I
   measured on this stack (SQL Server 2025 CU10, Apple Silicon M2):
     1,000 rows    ~11 seconds
     10,000 rows   anywhere from ~23 seconds to ~2 minutes on a running
                   instance, and ~340 seconds right after a restart
   Build time swings a lot with what's cached and what else the box is
   doing. Measure it on your hardware before you size a maintenance window.

   The build can take a couple of minutes. If you'd rather not wait, skip
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
   SECTION 2. PERFORMANCE: ANN vs. kNN SIDE-BY-SIDE IO COMPARISON
   ============================================================================= */

/* -----------------------------------------------------------------------------
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
--   QuestionEmbeddings  7,057 reads     2,265 reads
--   Worktable               0             671 reads
--   Graph edge table        -              50 reads
--   Total reads         7,057           2,986
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
-- Small tables don't need a vector index. Section 2a shows the crossover.


/* -----------------------------------------------------------------------------
   2a. Scale: how each path grows with row count
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
   SECTION 3. RECALL: MEASURING ANN ACCURACY AGAINST EXACT kNN
   ============================================================================= */

/* -----------------------------------------------------------------------------
   Recall@K = |ANN top-K ∩ kNN top-K| / K

   A recall of 1.0 means ANN returned exactly the same K results as the
   exhaustive search. The DiskANN paper reports 95%+ 1-recall@1 on a billion
   SIFT vectors. That's their data and their parameters, not yours. The only
   recall number that matters is the one you measure on your data.

   This matters for RAG: if ANN misses the single best-matching chunk,
   your LLM gets worse context. A high-recall ANN index gets you
   near-exact quality at a fraction of the cost.

   Here we measure a single test query. In production you'd
   average over hundreds of representative queries to get a stable recall
   estimate for your dataset and model.
----------------------------------------------------------------------------- */

-- Everything below runs in one batch (no GO), so the variables stay in
-- scope for both the kNN and ANN queries.

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
--   For a RAG workload to suffer, the missed neighbor would have to be the #1
--   most relevant chunk AND the other 9 would have to be irrelevant. That's a
--   pathological case.
--   In practice, high recall (> 0.95) means your retrieval quality is intact.


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

   ALLOW_STALE_VECTOR_INDEX isn't an option here. The docs say it "isn't
   currently available in SQL Server 2025", and it fails with Msg 102.

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
-- 1,713 rows are closer to the query than the furthest qualifying result,
-- so TOP_N has to reach past all of them. TOP_N=2500 returns all 5.
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
