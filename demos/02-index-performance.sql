SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  Demo 2 of 3: VECTOR INDEX PERFORMANCE AND LIMITATIONS
=============================================================================

  Learning objective:
    Evaluate vector index performance and limitations at scale.

  Prerequisites: Demo 1 done, QuestionEmbeddings at 10,000 rows
    (setup/expand-embeddings.sh). 2b needs StackOverflowScale
    (bash setup/build-scale-db.sh, or --restore).

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo)

  Run top to bottom; all idempotent.
  Deep dives: demos/02-index-performance-optional.sql.
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
   PREVIEW in SQL Server 2025; opt in per database.
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
   Graph goes to internal tables (1c). ~8 s, ~10,000 rows, MAXDOP 8.
   MAXDOP honored on CU10 (share the box on rebuild). Build: reads work,
   writes fail (Msg 42231), VECTOR_SEARCH fails (Msg 42227).
   Appendix A: numbers. Ignore "join order has been enforced".
----------------------------------------------------------------------------- */

DROP INDEX IF EXISTS vec_idx ON dbo.QuestionEmbeddings;
GO

DECLARE @build_start DATETIME2 = SYSDATETIME();

CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (
    metric  = 'cosine',    -- cosine | euclidean | dot (match VECTOR_DISTANCE)
    type    = 'diskann',   -- only option
    MAXDOP  = 8
);

SELECT
    DATEDIFF(MILLISECOND, @build_start, SYSDATETIME()) AS build_time_ms,
    (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)      AS rows_indexed;
GO


/* -----------------------------------------------------------------------------
   1c. Inspecting the index in the catalog
   -----------------------------------------------------------------------------
   build_parameters ("internal usage only"):
     StartId  entry node: real PostId near the vectors' center
     R        max edges per node (48)
     L        build candidate list size (48)
   No "Version" key = earlier-version index (2025).
----------------------------------------------------------------------------- */

SELECT
    i.name                                          AS index_name,
    v.vector_index_type,                            -- 'DiskANN'
    v.distance_metric,                              -- 'COSINE' | 'DOT' | 'EUCLIDEAN'
    JSON_VALUE(v.build_parameters, '$.StartId')     AS start_node,
    JSON_VALUE(v.build_parameters, '$.R')           AS max_degree_R,
    JSON_VALUE(v.build_parameters, '$.L')           AS build_list_L,
    JSON_VALUE(v.build_parameters, '$.Version')     AS index_version,    -- NULL = earlier
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

-- Graph tables. Quantization: 0 pages (full vectors walked).
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
   Actual plan (Ctrl+M). Vector Index Seek replaces Demo 1 - 4b's scan and
   Compute Scalar; no Sort. Serial. Estimated rows 1 everywhere (no vector
   costing). (Two-plans slide.)
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
   10,000 is under Microsoft's ~50,000-vector exact-search line.
   StackOverflowScale: 1,000,000 real posts, own index.
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
-- LOOK FOR (CU10, my laptop):
--                       exact kNN            ANN
--   logical reads       535,731              5,564
--   elapsed             175 to 265 ms        8 to 15 ms
--   CPU                 ~2 seconds           8 to 15 ms
-- Same 10 results, ~96x fewer reads.

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 3. LIMITATIONS: WHERE VECTOR INDEXES HELP AND WHERE THEY DON'T
   ============================================================================= */

/* -----------------------------------------------------------------------------
   3a. LIMITATION: Read-only table after CREATE VECTOR INDEX (SQL Server 2025)
   -----------------------------------------------------------------------------
   INSERT, UPDATE, DELETE, MERGE fail: Msg 42231 (TRUNCATE: 42232).
   No ALLOW_STALE_VECTOR_INDEX on 2025. Fix: drop, insert, rebuild
   (Demo 3 - 4a). Azure SQL latest-version index: writable.
----------------------------------------------------------------------------- */

-- Compile-time Msg 42231: TRY/CATCH can't catch it.
INSERT INTO dbo.QuestionEmbeddings (PostId, chunk, embeddings)
VALUES (
    999999,
    'test row',
    AI_GENERATE_EMBEDDINGS(N'test insertion with vector index present' USE MODEL ollama)
);
GO


/* -----------------------------------------------------------------------------
   3b. STRESS TEST: the silent zero-results failure
   -----------------------------------------------------------------------------
   Filters run AFTER the walk. Only 21 of 10,000 questions have Score > 5,000
   (0.21%), so small TOP_N returns zero rows, no error. Exact kNN: 5.
   Appendix C: candidates, truth.
----------------------------------------------------------------------------- */

-- STEP 1: TOP_N = 5 plus Score filter. Expected: 0 rows.
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

-- STEP 2: Oversample: TOP_N ≥ K / selectivity = 5 / 0.0021 ≈ 2,381.
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
-- Now 5 rows, as exact kNN. Azure SQL latest-version filters during the
-- walk: no issue.
GO

/* 
   Azure SQL latest version (not for SQL Server 2025): no TOP_N, no oversampling.
   Iterative filtering keeps walking the graph until 5 rows pass the filter.

DECLARE @search_vector VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'how do I center a div in CSS' USE MODEL ollama);

SELECT TOP (5) WITH APPROXIMATE t.PostId, p.Score, s.distance
FROM VECTOR_SEARCH(
    TABLE      = dbo.QuestionEmbeddings AS t,
    COLUMN     = [embeddings],
    SIMILAR_TO = @search_vector,
    METRIC     = 'cosine'
) AS s
JOIN dbo.Posts p ON t.PostId = p.Id
WHERE p.Score > 5000
ORDER BY s.distance;
*/
GO
