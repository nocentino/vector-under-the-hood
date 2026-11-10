SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production
  Demo 01: Optional deep dives

  Run after demos/01-vector-internals.sql. Appendices follow its order:
    A. float16 precision, catalog metadata, side-by-side   (extends 1c)
    B. Distance and norm math                         (behind 3)
    C. VECTOR in the type catalog                     (behind 1a)
    D. The three metrics on a 3-D example             (behind 3)
    E. What a whole corpus looks like around a query  (after 3a)
    F. Embedding throughput: 10, 50, and 100 rows     (after 2a)
    G. Exact kNN on a cold cache                      (after 4a)
    H. Why a B-tree can't help                        (after 4b)
=============================================================================
*/

USE [StackOverflow];
GO

/* =============================================================================
   APPENDIX A. FLOAT16 CATALOG METADATA AND A SIDE-BY-SIDE
   =============================================================================

   1c covers basics, sizes, mixed types. This adds real-text precision, the
   out-of-range error, sys.columns metadata, and a summary.
   ============================================================================= */

-- A-0. Half precision on real distances (Demo 01 - 3a's sentences, via JSON):
DECLARE @q   VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit?' USE MODEL ollama);
DECLARE @s   VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'git revert last commit without losing changes' USE MODEL ollama);
DECLARE @w   VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'what type of cheeses should I use on a quattro formaggi pizza' USE MODEL ollama);

DECLARE @q16 VECTOR(768, float16) = CAST(CAST(@q AS NVARCHAR(MAX)) AS VECTOR(768, float16));
DECLARE @s16 VECTOR(768, float16) = CAST(CAST(@s AS NVARCHAR(MAX)) AS VECTOR(768, float16));
DECLARE @w16 VECTOR(768, float16) = CAST(CAST(@w AS NVARCHAR(MAX)) AS VECTOR(768, float16));

SELECT
    pair,
    VECTOR_DISTANCE('cosine', a32, b32)                              AS float32_distance,
    VECTOR_DISTANCE('cosine', a16, b16)                              AS float16_distance,
    ABS(VECTOR_DISTANCE('cosine', a32, b32) - VECTOR_DISTANCE('cosine', a16, b16)) AS difference,
    DATALENGTH(a32)                                                  AS float32_bytes,
    DATALENGTH(a16)                                                  AS float16_bytes
FROM (VALUES
    ('question vs strong match', @q, @s, @q16, @s16),
    ('question vs weak match',   @q, @w, @q16, @w16)
) AS t(pair, a32, b32, a16, b16);
GO
-- Agree to ~5 decimal places, far below the ~0.1 vs ~0.7 strong/weak gap.

-- Out of range:
BEGIN TRY
    DECLARE @overflow VECTOR(3, float16) = '[1.0, 2.0, 70000.0]';
    SELECT @overflow;
END TRY
BEGIN CATCH
    PRINT 'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
    PRINT '=> float16 tops out at 65,504. Unit-length embeddings are safe.';
END CATCH;
GO

-- A-1. float16 needs PREVIEW_FEATURES (on from DiskANN setup):
SELECT name, value AS is_enabled
FROM sys.database_scoped_configurations
WHERE name = 'PREVIEW_FEATURES';
GO

-- A-2. sys.columns metadata (new in SQL Server 2025): vector_dimensions,
-- vector_base_type (0 = float32, 1 = float16), vector_base_type_desc.
-- max_length / 4 is wrong for float16 (stride 2); use vector_dimensions.
DROP TABLE IF EXISTS #vec_type_demo;
CREATE TABLE #vec_type_demo
(
    id          INT            PRIMARY KEY,
    v_float32   VECTOR(768),              -- default float32
    v_float16   VECTOR(768, float16)
);
GO

SELECT
    c.name                  AS column_name,
    c.max_length            AS raw_max_length,    -- 3080 float32, 1544 float16 (with 8-byte header)
    c.vector_dimensions     AS dimensions,         -- 768
    c.vector_base_type      AS base_type_code,
    c.vector_base_type_desc AS base_type_name
FROM tempdb.sys.columns c
WHERE c.object_id = OBJECT_ID('tempdb..#vec_type_demo')
ORDER BY c.column_id;
GO

DROP TABLE IF EXISTS #vec_type_demo;
GO

-- A-3. QuestionEmbeddings is float32:
SELECT
    c.name                  AS column_name,
    c.vector_dimensions     AS dimensions,
    c.vector_base_type_desc AS base_type
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
  AND c.vector_base_type_desc IS NOT NULL;
GO

-- A-4. Distances are unchanged.
DECLARE @q32 VECTOR(3)          = '[0.1, 0.2, 0.3]';
DECLARE @q16 VECTOR(3, float16) = '[0.1, 0.2, 0.3]';

SELECT
    VECTOR_DISTANCE('cosine',    @q32, @q32) AS f32_cosine_self,     -- 0
    VECTOR_DISTANCE('cosine',    @q16, @q16) AS f16_cosine_self,     -- 0
    DATALENGTH(@q32)                         AS f32_bytes,           -- 20
    DATALENGTH(@q16)                         AS f16_bytes;           -- 14
GO

-- A-5. Summary:
SELECT col, float32_value, float16_value
FROM (VALUES
    ('Bytes per element',       '4',           '2'),
    ('Bytes per 768-dim vector (DATALENGTH)','3,080',        '1,544'),
    ('Max dimensions',          '1,998',        '3,996'),
    ('Value range',             '±3.4×10³⁸',   '±65,504'),
    ('Unit-norm safe?',         'Yes',          'Yes'),
    ('Cross-type VECTOR_DISTANCE','Supported', 'Not supported (same type required)'),
    ('Direct CAST between types','Not allowed (Msg 42238)', 'Not allowed (Msg 42238)'),
    ('Binary TDS transport',    'Yes',          'ODBC 18.7.1+ / JDBC 13.4+'),
    ('Preview feature required','No',           'Yes')
) AS t(col, float32_value, float16_value);
GO

/* =============================================================================
   APPENDIX B. DISTANCE AND NORM MATH
   =============================================================================

   VECTOR_DISTANCE by hand, plus VECTOR_NORM.

     'cosine'    1 - (v1 · v2) / (|v1| × |v2|)   angle-based, ignores magnitude
     'euclidean' √ Σ(v1ᵢ - v2ᵢ)²                 straight-line distance
     'dot'       -(v1 · v2)                      inner product, negated

   Unit-length (|v1| = |v2| = 1): cosine = 1 - (v1 · v2), dot = -(v1 · v2),
   so dot distance = cosine distance - 1.
   ============================================================================= */

-- By hand, Appendix D's pair:
--   v1 · v2     = 1.0×0.866 + 0.0×0.5 + 0.0×0.0   = 0.866
--   |v1|, |v2|  = 1.0 and √(0.866² + 0.5²)         = 1.0
--   cosine      = 1 - 0.866                        = 0.134
--   euclidean   = √((1-0.866)² + (0-0.5)² + 0)     = 0.5176
--   dot         = -0.866
DECLARE @v1 VECTOR(3) = '[1.0, 0.0, 0.0]';
DECLARE @v2 VECTOR(3) = '[0.866, 0.5, 0.0]';
SELECT
    VECTOR_DISTANCE('cosine',    @v1, @v2) AS cosine_distance,
    VECTOR_DISTANCE('euclidean', @v1, @v2) AS euclidean_distance,
    VECTOR_DISTANCE('dot',       @v1, @v2) AS dot_distance;
GO

-- VECTOR_NORM(vector, norm_type):
--   'norm1'   : L1, sum of absolute values       e.g. |3|+|4|+|0| = 7.0
--   'norm2'   : L2 Euclidean, √(Σ xᵢ²)           e.g. √(9+16+0)   = 5.0
--   'norminf' : max of absolute values           e.g. max(3,4,0)  = 4.0
DECLARE @v VECTOR(3) = '[3.0, 4.0, 0.0]';
SELECT
    VECTOR_NORM(@v, 'norm1')   AS l1_norm,
    VECTOR_NORM(@v, 'norm2')   AS l2_norm,
    VECTOR_NORM(@v, 'norminf') AS inf_norm;
GO

-- dot = cosine - 1 needs unit length; nomic-embed-text, like most models,
-- produces it.
SELECT
    MIN(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS min_norm,
    MAX(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS max_norm,
    AVG(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS avg_norm
FROM dbo.QuestionEmbeddings;
GO

-- dot = cosine - 1 on every stored embedding; the biggest gap is float noise.
DECLARE @q VECTOR(768) = (SELECT TOP (1) embeddings FROM dbo.QuestionEmbeddings ORDER BY PostId);
SELECT
    COUNT(*) AS vectors_checked,
    MAX(ABS( VECTOR_DISTANCE('dot', @q, embeddings)
           - (VECTOR_DISTANCE('cosine', @q, embeddings) - 1) )) AS max_gap
FROM dbo.QuestionEmbeddings;
GO


/* =============================================================================
   APPENDIX C. VECTOR IN THE TYPE CATALOG
   ============================================================================= */

/* -----------------------------------------------------------------------------
   C. VECTOR in the type catalog
   -----------------------------------------------------------------------------
   VECTOR is a first-class type in sys.types; two max_length values matter:

   sys.types:    max_length = 8000  (type-level maximum)
   sys.columns:  max_length = 8 + dimensions × element_bytes
                 e.g. VECTOR(768) float32:  8 + 768 × 4 = 3,080
                      VECTOR(768) float16:  8 + 768 × 2 = 1,544

   The 8,000-byte ceiling sets the limits:
     float32:  (8000 - 8) / 4 = 1,998 dimensions max
     float16:  (8000 - 8) / 2 = 3,996 dimensions max

   The model picks the dimensions; the column must match.
   nomic-embed-text (https://ollama.com/library/nomic-embed-text): 768.
   Common: 384 (MiniLM), 768 (nomic-embed-text, BGE), 1,536 (OpenAI
   text-embedding-ada-002), 3,072 (text-embedding-3-large).

   Docs give the 4-byte elements and the 1,998 / 3,996 limits, not the 8-byte
   header, which DATALENGTH and sys.columns.max_length include: an
   implementation detail that could change. Use sys.columns.vector_dimensions.
     https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type
----------------------------------------------------------------------------- */

SELECT
    t.name              AS type_name,
    t.system_type_id,
    t.max_length,       -- needs the dimension count
    t.is_nullable
FROM sys.types t
WHERE t.name = 'vector';
GO

SELECT
    c.name                       AS column_name,
    t.name                       AS type_name,
    c.max_length                 AS max_length_bytes,     -- 3080 (8 + 768×4)
    c.vector_dimensions          AS vector_dimensions,    -- authoritative count
    c.vector_base_type_desc      AS base_type
FROM sys.columns c
JOIN sys.types   t ON t.user_type_id = c.user_type_id    -- user_type_id avoids dupes (VECTOR shares system_type_id 165 with varbinary)
WHERE c.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
ORDER BY c.column_id;
GO


/* =============================================================================
   APPENDIX D. THE THREE METRICS ON A 3-D EXAMPLE
   ============================================================================= */

-- The deck draws this ("Cosine, Euclidean, or dot?"): v1 and v2 30 degrees
-- apart, v1 and v3 at right angles. Cosine: 0 same direction, 1 right angles,
-- 2 opposite (rare for text):
DECLARE @v1 VECTOR(3) = '[1.0, 0.0, 0.0]';
DECLARE @v2 VECTOR(3) = '[0.866, 0.5, 0.0]';   -- ~30 degrees from v1
DECLARE @v3 VECTOR(3) = '[0.0, 1.0, 0.0]';     -- 90 degrees from v1

SELECT
    pair,
    VECTOR_DISTANCE('cosine',    a, b) AS cosine_distance,
    VECTOR_DISTANCE('euclidean', a, b) AS euclidean_distance,
    VECTOR_DISTANCE('dot',       a, b) AS dot_distance
FROM (VALUES
    ('v1 vs v1 (same)',        @v1, @v1),
    ('v1 vs v2 (30 degrees)',  @v1, @v2),
    ('v1 vs v3 (90 degrees)',  @v1, @v3)
) AS t(pair, a, b);
GO


/* =============================================================================
   APPENDIX E. WHAT A WHOLE CORPUS LOOKS LIKE AROUND ONE QUESTION
   ============================================================================= */

/* -----------------------------------------------------------------------------
   E. What a whole corpus looks like around one question
   -----------------------------------------------------------------------------
   One question vs every embedded question: tight top, a gap, noise.
----------------------------------------------------------------------------- */

DECLARE @query_vector VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama);

SELECT TOP (500)
    p.Title,
    VECTOR_DISTANCE('cosine', @query_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
ORDER BY distance;
GO
-- Top results sit at 0.1 to 0.3; above ~0.4 is usually unrelated. A threshold
-- works; TOP K is simpler, sturdier.


/* =============================================================================
   APPENDIX F. EMBEDDING THROUGHPUT: 10, 50, AND 100 ROWS
   ============================================================================= */

-- Text from the small QuestionEmbeddings table: we time the calls, not a
-- sort of 400,000 posts.
DECLARE @t DATETIME2 = SYSDATETIME();
SELECT TOP (10) qe.PostId, AI_GENERATE_EMBEDDINGS(qe.chunk USE MODEL ollama) AS embedding
INTO #e FROM dbo.QuestionEmbeddings qe ORDER BY qe.PostId;
PRINT CONCAT('10 rows:  ', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), ' ms');
DROP TABLE #e;
GO
DECLARE @t DATETIME2 = SYSDATETIME();
SELECT TOP (50) qe.PostId, AI_GENERATE_EMBEDDINGS(qe.chunk USE MODEL ollama) AS embedding
INTO #e FROM dbo.QuestionEmbeddings qe ORDER BY qe.PostId;
PRINT CONCAT('50 rows:  ', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), ' ms');
DROP TABLE #e;
GO
DECLARE @t DATETIME2 = SYSDATETIME();
SELECT TOP (100) qe.PostId, AI_GENERATE_EMBEDDINGS(qe.chunk USE MODEL ollama) AS embedding
INTO #e FROM dbo.QuestionEmbeddings qe ORDER BY qe.PostId;
PRINT CONCAT('100 rows: ', DATEDIFF(MILLISECOND, @t, SYSDATETIME()), ' ms');
DROP TABLE #e;
GO
-- Linear: ~15 ms/row on my M2 (10 rows ~140 ms, 100 rows ~1.5 s). One
-- call per row, no batching: ~65 a second, 1,000,000 rows ~4 hours. Size
-- the model host.
--
-- Keep AI_GENERATE_EMBEDDINGS at the top level, next to the TOP. In a derived
-- table under an aggregate, one test ran past five minutes before I killed
-- it. The plan shows the call count.


/* =============================================================================
   APPENDIX G. EXACT kNN ON A COLD CACHE
   ============================================================================= */

-- Run 4a warm first (STATISTICS IO and TIME on), then cold.
-- DEV BOXES ONLY: DROPCLEANBUFFERS empties the whole instance's buffer pool.
CHECKPOINT;
DBCC DROPCLEANBUFFERS;
GO
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @query_vector VECTOR(768) = AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit?' USE MODEL ollama);

WITH nearest AS (
    SELECT TOP (10)
        qe.PostId,
        VECTOR_DISTANCE('cosine', @query_vector, qe.embeddings) AS distance
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
-- "read-ahead reads" on QuestionEmbeddings: ~7,000 pages on my box, 3 to 10
-- times slower than warm (40 to 210 ms against 8 to 25 ms). Sequential scan,
-- so big read-aheads. Storage matters for exact search and builds.


/* =============================================================================
   APPENDIX H. WHY A B-TREE CAN'T HELP
   ============================================================================= */

/* -----------------------------------------------------------------------------
   H. Why a B-tree can't help
   -----------------------------------------------------------------------------
   A B-tree needs a key to compare and sort. A vector has neither: no
   B-tree or columnstore index, no comparison operators.
     https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type#limitations

   Three expected errors.
----------------------------------------------------------------------------- */

-- 1. Not an index key (Msg 1978):
CREATE INDEX ix_vec_key ON dbo.QuestionEmbeddings(embeddings);
GO

-- 2. Not comparable with = (Msg 8117):
DECLARE @qv VECTOR(768) = (SELECT embeddings FROM dbo.QuestionEmbeddings WHERE PostId = 219716);
SELECT COUNT(*) FROM dbo.QuestionEmbeddings WHERE embeddings = @qv;
GO

-- 3. Not sortable (Msg 42213):
SELECT TOP (1) PostId FROM dbo.QuestionEmbeddings ORDER BY embeddings;
GO

-- A vector can be an INCLUDE column, but that only copies it. Sort order
-- can't answer "close to": exact kNN reads every row; the Demo 2 index is a
-- graph, not a tree.
