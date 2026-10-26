SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production
  Demo 01: Optional deep dives

  Run after demos/01-vector-internals.sql. These sections expand on storage,
  float16, filegroups, and distance behavior.
=============================================================================
*/

USE [StackOverflow];
GO

/* -----------------------------------------------------------------------------
   APPENDIX A. Page-level storage
   -----------------------------------------------------------------------------
   Moved into the core script: see demos/01-vector-internals.sql, §1b-2.
----------------------------------------------------------------------------- */

/* =============================================================================
   APPENDIX B. HALF-PRECISION VECTORS, VECTOR(n, float16)
   =============================================================================

   SQL Server 2025 adds an optional base type parameter to VECTOR. The
   default is float32 (32-bit IEEE 754 single-precision, 4 bytes per
   element). You can also ask for float16 (16-bit half-precision, 2 bytes
   per element).

   Syntax:
       VECTOR( <dimensions> [, <base_type>] )
       base_type: float32 (default) | float16

   Why it matters
   ──────────────
   float32   768 dims × 4 bytes + 8-byte header = 3,080 bytes per vector
   float16   768 dims × 2 bytes + 8-byte header = 1,544 bytes per vector  ← half the payload

   At one million embeddings:
     float32  ~3 GB of raw vector data
     float16  ~1.5 GB (half the space, faster reads from disk)

   float16 also DOUBLES the dimension ceiling:
     float32  max 1,998 dimensions
     float16  max 3,996 dimensions
   That opens the door to bigger models like text-embedding-3-large (3,072 dims).

   The trade-off is precision. float16's range is ±65,504 (vs. ±3.4×10³⁸ for
   float32). For semantic similarity search that's almost always fine.
   Embeddings are unit-normalized, so every value is in [−1, +1], well
   inside float16's range.

   PLATFORM NOTE: float16 is a PREVIEW feature in SQL Server 2025. You need
   PREVIEW_FEATURES on first (it already is, from the DiskANN setup in init.sql).
----------------------------------------------------------------------------- */

-- B-1. Confirm PREVIEW_FEATURES is already on (required for float16):
SELECT name, value AS is_enabled
FROM sys.database_scoped_configurations
WHERE name = 'PREVIEW_FEATURES';
GO

-- B-2. Storage size comparison: float32 vs float16 at the same dimensions:
-- Note: DATALENGTH includes the 8-byte VECTOR binary header.
-- Payload bytes = DATALENGTH - 8. Use sys.columns.vector_dimensions for dimension count.
SELECT
    'float32 (default)' AS base_type,
    768                 AS dimensions,
    8 + 768 * 4         AS bytes_per_vector_with_header,
    DATALENGTH(CAST('[' + REPLICATE('0.1,', 767) + '0.1]' AS VECTOR(768)))
                        AS actual_bytes
UNION ALL
SELECT
    'float16'           AS base_type,
    768                 AS dimensions,
    8 + 768 * 2         AS bytes_per_vector_with_header,
    DATALENGTH(CAST('[' + REPLICATE('0.1,', 767) + '0.1]' AS VECTOR(768, float16)))
                        AS actual_bytes;
GO
-- float32: 3,080 bytes (8 header + 3,072 payload)   float16: 1,544 bytes (8 header + 1,536 payload)
-- Payload is exactly half; the 8-byte header is the same for both types.

-- B-3. The new sys.columns metadata columns for float16:
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

-- B-4. QuestionEmbeddings uses float32 (the default). Check it:
SELECT
    c.name                  AS column_name,
    c.vector_dimensions     AS dimensions,
    c.vector_base_type_desc AS base_type
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
  AND c.vector_base_type_desc IS NOT NULL;
GO

-- B-5. Arithmetic with float16: distance functions work the same way.
--       Same API. Only the storage format changes.
DECLARE @q32 VECTOR(3)          = '[0.1, 0.2, 0.3]';   -- float32 (default)
DECLARE @q16 VECTOR(3, float16) = '[0.1, 0.2, 0.3]';   -- float16

SELECT
    VECTOR_DISTANCE('cosine',    @q32, @q32) AS f32_cosine_self,     -- 0  (identical)
    VECTOR_DISTANCE('cosine',    @q16, @q16) AS f16_cosine_self,     -- 0  (identical)
    DATALENGTH(@q32)                         AS f32_bytes,           -- 20 (8 header + 3 × 4)
    DATALENGTH(@q16)                         AS f16_bytes;           -- 14 (8 header + 3 × 2)
GO

-- B-6. KEY LIMITATIONS you'll hit:
--
--   NO cross-type arithmetic:
--     VECTOR_DISTANCE(float32_col, float16_col) → Msg 42243 (type mismatch)
--     Both arguments to VECTOR_DISTANCE must use the same base type.
--
--   NO implicit float32 ↔ float16 conversion:
--     CAST(@float32_var AS VECTOR(n, float16)) → Msg 42238
--     You have to re-embed with the new type. You can't cast.
--
--   float16 range is ±65,504:
--     Values outside this range (e.g., 70000.0) raise Msg 42241 at insert time.
--     Unit-normalized embeddings (all values in [−1, +1]) are always safe.
--
--   TDS transport: ODBC 18.7.1+ and JDBC 13.4+ send float16 in binary.
--     Older drivers get varchar(max) JSON, and that costs more on the wire.
--

-- Here's the cross-type error (we catch it and print the message):
BEGIN TRY
    DECLARE @v32 VECTOR(3)          = '[1.0, 0.0, 0.0]';
    DECLARE @v16 VECTOR(3, float16) = '[1.0, 0.0, 0.0]';
    SELECT VECTOR_DISTANCE('cosine', @v32, @v16);
END TRY
BEGIN CATCH
    PRINT 'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
    PRINT '=> You can''t mix base types in VECTOR_DISTANCE.';
END CATCH;
GO

-- And here's the out-of-range error:
BEGIN TRY
    DECLARE @overflow VECTOR(3, float16) = '[1.0, 2.0, 70000.0]';
    SELECT @overflow;
END TRY
BEGIN CATCH
    PRINT 'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
    PRINT '=> float16 tops out at 65,504. Unit-norm embeddings are safe.';
END CATCH;
GO

-- B-7. WHEN TO USE float16 vs float32
--
--   USE float16 WHEN:
--     - You're storing millions of embeddings and storage cost matters
--     - Your embedding model produces unit-normalized values (all values ≤ 1)
--     - You need dimensions > 1,998 (e.g., text-embedding-3-large at 3,072 dims)
--     - Approximate similarity search (RAG retrieval) is the workload
--
--   STAY WITH float32 WHEN:
--     - You need exact numerical fidelity (scientific / financial workloads)
--     - You mix embedding and non-embedding vector workloads on the same column
--     - Your client drivers are older than ODBC 18.7.1 / JDBC 13.4 (no binary float16)

-- Summary comparison:
SELECT col, float32_value, float16_value
FROM (VALUES
    ('Bytes per element',       '4',           '2'),
    ('Bytes per 768-dim vector (DATALENGTH)','3,080',        '1,544'),
    ('Max dimensions',          '1,998',        '3,996'),
    ('Value range',             '±3.4×10³⁸',   '±65,504'),
    ('Unit-norm safe?',         'Yes',          'Yes'),
    ('Cross-type VECTOR_DISTANCE','Supported', 'Not supported (same type required)'),
    ('Binary TDS transport',    'Yes',          'ODBC 18.7.1+ / JDBC 13.4+'),
    ('ARM64 support',           'Yes',          'No'),
    ('Preview feature required','No',           'Yes')
) AS t(col, float32_value, float16_value);
GO

/* =============================================================================
   APPENDIX C. PHYSICAL STORAGE, FILEGROUPS AND DATA FILES
   ============================================================================= */

/* -----------------------------------------------------------------------------
   QuestionEmbeddings lives on its own EMBEDDINGS filegroup, backed by
   StackOverflow_Embeddings.ndf. That's separate from the operational data
   (.mdf) and the log (.ldf).

   Why put the vectors on their own filegroup?

     OPERATIONAL ISOLATION
       Vectors and transactional data have different I/O profiles. Vectors
       are large and read sequentially (index builds, full scans). OLTP data
       is small and read randomly. Put them on the same file and they fight.

     INDEPENDENT MANAGEMENT
       You can back up, restore, or OFFLINE the EMBEDDINGS filegroup on its own.
       Need to rebuild every embedding from scratch? Drop and recreate the
       .ndf without touching the primary filegroup.

     STORAGE TIERING
       Point the EMBEDDINGS filegroup at a high-capacity SSD and PRIMARY at
       NVMe. Size each one independently.
----------------------------------------------------------------------------- */

-- All data files in the StackOverflow database:
SELECT
    fg.name                             AS filegroup_name,
    df.name                             AS logical_file_name,
    df.physical_name,
    df.type_desc                        AS file_type,
    df.size     * 8.0 / 1024            AS current_size_MB,
    df.growth   * 8.0 / 1024            AS autogrowth_MB,
    df.is_percent_growth
FROM sys.filegroups     fg
JOIN sys.database_files df ON fg.data_space_id = df.data_space_id
ORDER BY fg.data_space_id, df.file_id;
GO

-- Confirm QuestionEmbeddings lives on the EMBEDDINGS filegroup:
-- ROW_OVERFLOW_DATA can have a catalog row with zero pages.
SELECT
    t.name              AS table_name,
    fg.name             AS filegroup_name,
    au.type_desc        AS allocation_unit,
    au.total_pages      AS allocated_pages,
    p.rows              AS row_count
FROM sys.tables         t
JOIN sys.indexes        i  ON i.object_id = t.object_id
                           AND i.index_id IN (0, 1)     -- heap or clustered index
JOIN sys.partitions     p  ON p.object_id = i.object_id
                           AND p.index_id = i.index_id
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
JOIN sys.filegroups     fg  ON fg.data_space_id = au.data_space_id
WHERE t.name = 'QuestionEmbeddings';
GO

-- Space consumed by the table (data + index):
EXEC sp_spaceused 'dbo.QuestionEmbeddings';
GO

/* -----------------------------------------------------------------------------
   APPENDIX D. Cosine distance in practice: strong match vs. weak match
   -----------------------------------------------------------------------------
   Real numbers make "distance" easier to reason about. Near 0.1 is a very
   strong match. Near 0.5 is background noise. The thresholds depend on the
   model, but they're consistent within a model.
----------------------------------------------------------------------------- */

DECLARE @question     VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama);

DECLARE @strong_match VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'git revert last commit without losing changes' USE MODEL ollama);

DECLARE @weak_match   VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I center a div in CSS' USE MODEL ollama);

SELECT
    VECTOR_DISTANCE('cosine', @question, @strong_match) AS strong_match_distance,
    VECTOR_DISTANCE('cosine', @question, @weak_match)   AS weak_match_distance;
GO

-- Now look at how real StackOverflow questions cluster around the query.
-- The top results are tight, then there's a natural gap before the noise:
DECLARE @query_vector VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama);

SELECT TOP (500)
    p.Title,
    VECTOR_DISTANCE('cosine', @query_vector, qe.embeddings) AS distance,
    p.Score
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
ORDER BY distance;
GO
-- Notice the drop-off: the top results are in the 0.1–0.3 range.
-- Anything above ~0.4 is usually unrelated to the query.
-- You could use a distance threshold instead of TOP K, but in practice
-- TOP K is simpler and holds up better.
