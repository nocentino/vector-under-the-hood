SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production
  Demo 01: Optional deep dives

  Run after demos/01-vector-internals.sql. The appendices follow the core
  script's order:
    A. float16 precision, catalog metadata, side-by-side   (extends §1d)
    B. Distance and norm math                         (behind §3)
=============================================================================
*/

USE [StackOverflow];
GO

/* =============================================================================
   APPENDIX A. FLOAT16 CATALOG METADATA AND A SIDE-BY-SIDE
   =============================================================================

   The core demo (demos/01-vector-internals.sql §1d) covers what float16 is,
   the size comparison, and the mixed-types error. This appendix adds the
   precision measurement on real text, the out-of-range error, how a float16
   column shows up in sys.columns, and a summary table.
   ============================================================================= */

-- A-0. What does half precision do to a real distance? Take the three
-- sentences from Demo 01 §3b, convert each to float16 by round-tripping
-- through JSON text, and measure again:
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
-- The distances agree to about five decimal places (the difference column).
-- That's far below the gap between a strong match (~0.1) and a weak one
-- (~0.7), and the vector is half the size.

-- And the out-of-range error. float16 tops out at 65,504:
BEGIN TRY
    DECLARE @overflow VECTOR(3, float16) = '[1.0, 2.0, 70000.0]';
    SELECT @overflow;
END TRY
BEGIN CATCH
    PRINT 'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
    PRINT '=> float16 tops out at 65,504. Unit-length embeddings are safe.';
END CATCH;
GO

-- A-1. float16 needs PREVIEW_FEATURES (already on, from the DiskANN setup):
SELECT name, value AS is_enabled
FROM sys.database_scoped_configurations
WHERE name = 'PREVIEW_FEATURES';
GO

-- A-2. The sys.columns metadata for float16:
--   vector_dimensions     : dimension count (same as max_length / element_size)
--   vector_base_type      : 0 = float32, 1 = float16
--   vector_base_type_desc : 'float32' or 'float16'
--
-- These columns only exist in SQL Server 2025. If you've got older catalog
-- queries doing max_length / 4 to infer dimensions, they're wrong for
-- float16 columns (the stride is 2, not 4). Use vector_dimensions directly.

-- Let's create a small demo table with both types side by side:
DROP TABLE IF EXISTS #vec_type_demo;
CREATE TABLE #vec_type_demo
(
    id          INT            PRIMARY KEY,
    v_float32   VECTOR(768),              -- default: float32
    v_float16   VECTOR(768, float16)      -- explicit: float16
);
GO

SELECT
    c.name                  AS column_name,
    c.max_length            AS raw_max_length,    -- 3080 for float32, 1544 for float16 (includes the 8-byte header)
    c.vector_dimensions     AS dimensions,         -- new column: always 768
    c.vector_base_type      AS base_type_code,     -- 0 = float32, 1 = float16
    c.vector_base_type_desc AS base_type_name      -- 'float32' | 'float16'
FROM tempdb.sys.columns c
WHERE c.object_id = OBJECT_ID('tempdb..#vec_type_demo')
ORDER BY c.column_id;
GO

DROP TABLE IF EXISTS #vec_type_demo;
GO

-- A-3. QuestionEmbeddings uses float32 (the default). Check it:
SELECT
    c.name                  AS column_name,
    c.vector_dimensions     AS dimensions,
    c.vector_base_type_desc AS base_type
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
  AND c.vector_base_type_desc IS NOT NULL;
GO

-- A-4. Distance functions work the same way. Only the storage format changes.
DECLARE @q32 VECTOR(3)          = '[0.1, 0.2, 0.3]';   -- float32 (default)
DECLARE @q16 VECTOR(3, float16) = '[0.1, 0.2, 0.3]';   -- float16

SELECT
    VECTOR_DISTANCE('cosine',    @q32, @q32) AS f32_cosine_self,     -- 0  (identical)
    VECTOR_DISTANCE('cosine',    @q16, @q16) AS f16_cosine_self,     -- 0  (identical)
    DATALENGTH(@q32)                         AS f32_bytes,           -- 20 (8 header + 3 × 4)
    DATALENGTH(@q16)                         AS f16_bytes;           -- 14 (8 header + 3 × 2)
GO

-- A-5. Summary comparison:
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

   The formulas behind VECTOR_DISTANCE, a hand check against SQL Server's
   answer, and VECTOR_NORM. Demo 01 §3 uses these without the math.

     'cosine'    1 - (v1 · v2) / (|v1| × |v2|)   angle-based, ignores magnitude
     'euclidean' √ Σ(v1ᵢ - v2ᵢ)²                 straight-line distance in n-space
     'dot'       -(v1 · v2)                      inner product, negated

   For unit-length vectors, |v1| = |v2| = 1, so:
     cosine distance = 1 - (v1 · v2)
     dot distance    = -(v1 · v2)
   which means  dot distance = cosine distance - 1.
   ============================================================================= */

-- Check the formulas by hand on the 3-D pair from Demo 01 §3:
--   v1 · v2     = 1.0×0.866 + 0.0×0.5 + 0.0×0.0       = 0.866
--   |v1|, |v2|  = 1.0 and √(0.866² + 0.5²)             = 1.0
--   cosine      = 1 - 0.866                            = 0.134
--   euclidean   = √((1-0.866)² + (0-0.5)² + 0)         = 0.5176
--   dot         = -0.866
DECLARE @v1 VECTOR(3) = '[1.0, 0.0, 0.0]';
DECLARE @v2 VECTOR(3) = '[0.866, 0.5, 0.0]';
SELECT
    VECTOR_DISTANCE('cosine',    @v1, @v2) AS cosine_distance,     -- 0.134
    VECTOR_DISTANCE('euclidean', @v1, @v2) AS euclidean_distance,  -- 0.5176
    VECTOR_DISTANCE('dot',       @v1, @v2) AS dot_distance;        -- -0.866
GO

-- VECTOR_NORM computes the magnitude of a vector using the specified norm.
-- Syntax: VECTOR_NORM(vector, norm_type)
-- Supported norm_type values:
--   'norm1'   : L1 norm: sum of absolute values          e.g. |3|+|4|+|0| = 7.0
--   'norm2'   : L2 Euclidean norm: √(Σ xᵢ²)              e.g. √(9+16+0)   = 5.0
--   'norminf' : Infinity norm: max of absolute values    e.g. max(3,4,0)  = 4.0
DECLARE @v VECTOR(3) = '[3.0, 4.0, 0.0]';
SELECT
    VECTOR_NORM(@v, 'norm1')   AS l1_norm,    -- 7.0
    VECTOR_NORM(@v, 'norm2')   AS l2_norm,    -- 5.0
    VECTOR_NORM(@v, 'norminf') AS inf_norm;   -- 4.0
GO

-- Are our stored embeddings unit-length? The dot and cosine relationship only
-- holds if they are. VECTOR_NORM(v, 'norm2') returns a vector's length, and
-- most embedding models, nomic-embed-text included, produce unit vectors.
SELECT
    MIN(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS min_norm,
    MAX(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS max_norm,
    AVG(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS avg_norm
FROM dbo.QuestionEmbeddings;
GO

-- Prove dot = cosine - 1 on every stored embedding, not just one pair.
-- The biggest gap should be tiny (floating-point noise).
DECLARE @q VECTOR(768) = (SELECT TOP (1) embeddings FROM dbo.QuestionEmbeddings ORDER BY PostId);
SELECT
    COUNT(*) AS vectors_checked,
    MAX(ABS( VECTOR_DISTANCE('dot', @q, embeddings)
           - (VECTOR_DISTANCE('cosine', @q, embeddings) - 1) )) AS max_gap
FROM dbo.QuestionEmbeddings;
GO
