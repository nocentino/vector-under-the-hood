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

  Prerequisites:
    Demo 1 complete, QuestionEmbeddings at 10,000 rows
    (setup/expand-embeddings.sh). §2b and §3a need StackOverflowScale
    (bash setup/build-scale-db.sh, or --restore).

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run the sections top to bottom. Every one is idempotent.
  Deep dives and the measurements behind these numbers:
  demos/02-index-performance-optional.sql.
=============================================================================
*/

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 1. THE DiskANN INDEX: WHAT IT IS AND HOW TO BUILD IT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   1a. Turn on preview features
   -----------------------------------------------------------------------------
   The vector index is a PREVIEW feature in SQL Server 2025. Opt in per database.
----------------------------------------------------------------------------- */

ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO

SELECT
    name,
    [value]
FROM sys.database_scoped_configurations
WHERE name = 'PREVIEW_FEATURES';
GO


/* -----------------------------------------------------------------------------
   1b. Building the DiskANN index (and watching the clock)
   -----------------------------------------------------------------------------
   The build reads every vector, builds the graph, and stores it in internal
   tables (§1c). About 17 to 18 seconds for 10,800 rows at MAXDOP 4 here.

   MAXDOP on the build is honored on CU10 and is how you share the box during
   a rebuild. While it builds, reads work, writes fail (Msg 42231), and
   VECTOR_SEARCH fails (Msg 42227). Numbers: optional Appendix A.

   The "join order has been enforced" warning is a known issue; ignore it.
----------------------------------------------------------------------------- */

DROP INDEX IF EXISTS vec_idx ON dbo.QuestionEmbeddings;
GO

DECLARE @build_start DATETIME2 = SYSDATETIME();

CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (
    metric  = 'cosine',    -- cosine | euclidean | dot  (must match VECTOR_DISTANCE calls)
    type    = 'diskann',   -- only DiskANN is supported
    MAXDOP  = 4
);

SELECT
    DATEDIFF(MILLISECOND, @build_start, SYSDATETIME()) AS build_time_ms,
    (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)      AS rows_indexed;
GO


/* -----------------------------------------------------------------------------
   1c. Inspecting the index in the catalog
   -----------------------------------------------------------------------------
   build_parameters is "internal usage only", but readable:
     StartId  the entry node: a real PostId near the center of all the vectors
     R        max edges per node (48)
     L        candidate list size during the build (48)
   No "Version" key means the earlier-version index (SQL Server 2025).
----------------------------------------------------------------------------- */

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

-- The question every graph walk starts from:
SELECT p.Id, p.Title
FROM sys.vector_indexes v
JOIN dbo.Posts p ON p.Id = CAST(JSON_VALUE(v.build_parameters, '$.StartId') AS INT)
WHERE v.object_id = OBJECT_ID('dbo.QuestionEmbeddings');
GO

-- The graph lives in internal tables owned by the base table. The quantization
-- table stays at 0 pages: this earlier-version index walks the full vectors.
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


/* =============================================================================
   SECTION 2. PERFORMANCE: ANN vs. kNN SIDE-BY-SIDE IO COMPARISON
   ============================================================================= */

/* -----------------------------------------------------------------------------
   2a. The plan: Vector Index Seek
   -----------------------------------------------------------------------------
   Turn on the actual plan (Ctrl+M). Vector Index Seek replaces the scan and
   the per-row Compute Scalar from Demo 1 §4b. Estimated rows say 1; the
   optimizer doesn't estimate vector search well yet.
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
   2b. Past the line: 1,000,000 vectors
   -----------------------------------------------------------------------------
   10,000 rows is under Microsoft's ~50,000-vector guidance for exact search.
   StackOverflowScale has 1,000,000 real posts and its own index. The query is
   typed text; it isn't in the table.
----------------------------------------------------------------------------- */

USE [StackOverflowScale];
GO

DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'what are the uses for a cross join?' USE MODEL ollama);

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

PRINT '--- EXACT kNN over 1,000,000 rows ---';
SELECT TOP (10) qe.PostId, VECTOR_DISTANCE('cosine', @qv, qe.embeddings) AS distance,
       LEFT(qe.chunk, 80) AS chunk
FROM dbo.QuestionEmbeddings qe
ORDER BY distance;

PRINT '--- ANN over 1,000,000 rows ---';
SELECT t.PostId, s.distance, LEFT(t.chunk, 80) AS chunk
FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                   SIMILAR_TO = @qv, METRIC = 'cosine', TOP_N = 10) AS s
ORDER BY s.distance;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO
-- WHAT TO LOOK FOR (CU10, my laptop):
--                       exact kNN            ANN
--   logical reads       535,731              5,564
--   elapsed             about 165 to 215 ms  6 to 15 ms
--   CPU                 1.2 to 1.6 seconds   6 to 15 ms
-- Same 10 results, about 96 times fewer reads.

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 3. RECALL: WHAT APPROXIMATE COSTS YOU
   ============================================================================= */

/* -----------------------------------------------------------------------------
   3a. One question at 1,000,000 rows, and the fix
   -----------------------------------------------------------------------------
   Recall@10 = how many of the true top 10 the index found. The fix for a
   miss: ask for more candidates (TOP_N = 50) and keep the closest 10. That's
   oversampling.
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
--   TOP_N = 10    recall 0.84 to 0.89    about 8 to 10 ms
--   TOP_N = 50    recall 0.96 to 0.98    about 24 to 28 ms
--   exact kNN     recall 1.0             about 175 to 235 ms

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 4. LIMITATIONS: WHERE VECTOR INDEXES HELP AND WHERE THEY DON'T
   ============================================================================= */

/* -----------------------------------------------------------------------------
   4a. LIMITATION: Read-only table after CREATE VECTOR INDEX (SQL Server 2025)
   -----------------------------------------------------------------------------
   With a vector index, INSERT, UPDATE, DELETE, and MERGE fail with Msg 42231
   (TRUNCATE: 42232). ALLOW_STALE_VECTOR_INDEX isn't available on SQL Server
   2025. Workaround: drop, insert, rebuild (Demo 3 §4a). The latest-version
   index on Azure SQL is fully writable.
----------------------------------------------------------------------------- */

-- Msg 42231 is a compile-time error, so TRY/CATCH can't catch it here.
INSERT INTO dbo.QuestionEmbeddings (PostId, chunk, embeddings)
VALUES (
    999999,
    'test row',
    AI_GENERATE_EMBEDDINGS(N'test insertion with vector index present' USE MODEL ollama)
);
GO


/* -----------------------------------------------------------------------------
   4b. STRESS TEST: the silent zero-results failure
   -----------------------------------------------------------------------------
   Filters run AFTER the graph walk. Only 21 of 10,000 questions have
   Score > 5,000 (0.21%), so a small TOP_N can return nothing: no error, just
   zero rows. Exact kNN finds 5 matches for this query. Optional Appendix C
   shows the raw candidates and that ground truth.
----------------------------------------------------------------------------- */

-- STEP 1: TOP_N = 5 plus the Score filter. Expected: 0 rows.
DECLARE @search_vector VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'how do I center a div in CSS' USE MODEL ollama);

SELECT t.PostId, p.Score, s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 5
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 5000
ORDER BY s.distance;
GO

-- STEP 2: Fix it. Oversample: TOP_N ≥ K / selectivity = 5 / 0.0021 ≈ 2,381.
DECLARE @search_vector VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'how do I center a div in CSS' USE MODEL ollama);

SELECT TOP(5) t.PostId, p.Score, s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine',
    TOP_N      = 2500
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 5000
ORDER BY s.distance;
-- Now 5 rows, the same ones exact kNN finds. The latest-version index on
-- Azure SQL filters during the walk, so this goes away there.
GO
