SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  Demo 1 of 3 — VECTOR DATA TYPE INTERNALS
  Storage layout  ·  Catalog views  ·  Query execution
=============================================================================

  Learning objective:
    Describe vector data type internals: storage, indexing, and query execution.

  Prerequisites:
    Stack is up (./start.sh), StackOverflow is restored and embedded.
    The sql-init container ran demos/vector-demos.sql at startup —
    QuestionEmbeddings is populated with ~10,000 rows.

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run sections top-to-bottom. Every section is idempotent.

  LIVE-DEMO TIP: Sections 1-3 are "look, don't touch" catalog queries.
    Sections 4-5 are the ones your audience will want to see run live.
    Budget roughly 15 min on internals (1-3) and 15 min on execution (4-5).
=============================================================================
*/

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 1 — THE VECTOR DATA TYPE: WHAT IT IS AT THE BINARY LEVEL
   ============================================================================= */

/* -----------------------------------------------------------------------------
   1a. VECTOR in the type catalog
   -----------------------------------------------------------------------------
   VECTOR is a first-class type in SQL Server 2025. It appears in sys.types
   just like INT, NVARCHAR, or DATETIME2. Two max_length values to know:

   sys.types:    max_length = 8000  (type-level maximum for any VECTOR column)
   sys.columns:  max_length = 8 + dimensions × element_bytes
                 e.g. VECTOR(768) float32:  8 + 768 × 4 = 3,080
                      VECTOR(768) float16:  8 + 768 × 2 = 1,544

   MAXIMUM DIMENSIONS
   ──────────────────
   The 8000-byte type ceiling (sys.types.max_length) translates to:
     float32:  (8000 - 8) / 4 = 1,998 dimensions max
     float16:  (8000 - 8) / 2 = 3,996 dimensions max

   We use 768 because that is the output dimension of our embedding model:
   nomic-embed-text (https://ollama.com/library/nomic-embed-text). The
   dimension count is a property of the model, not a choice — every model
   produces a fixed-width vector and your VECTOR column must match it exactly.
   Common sizes: 384 (MiniLM), 768 (nomic-embed-text, BGE), 1,536 (OpenAI
   text-embedding-ada-002), 3,072 (text-embedding-3-large).

   The 8-byte prefix is a binary metadata header SQL Server prepends to every
   stored VECTOR value. DATALENGTH() and sys.columns.max_length both include it.
   Use sys.columns.vector_dimensions for the authoritative dimension count.

   This is the foundation of everything that follows: the type is not text,
   not JSON, not a blob you manage yourself. It's a native numeric array with
   a known, fixed stride.
----------------------------------------------------------------------------- */

SELECT
    t.name              AS type_name,
    t.system_type_id,
    t.max_length,       -- meaningful only if you know the dimension count
    t.is_nullable
FROM sys.types t
WHERE t.name = 'vector';
GO

-- Column-level metadata for QuestionEmbeddings:
SELECT
    c.name                  AS column_name,
    t.name                  AS type_name,
    c.max_length                 AS max_length_bytes,     -- 3080 (8-byte header + 768×4 = 3,072)
    (c.max_length - 8) / 4       AS dimension_count,      -- subtract header before dividing
    c.vector_dimensions          AS vector_dimensions,    -- SQL Server 2025: authoritative count
    c.vector_base_type_desc      AS base_type             -- 'float32' | 'float16'
FROM sys.columns c
JOIN sys.types   t ON t.user_type_id = c.user_type_id    -- user_type_id avoids duplicates (VECTOR shares system_type_id=165 with varbinary)
WHERE c.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
ORDER BY c.column_id;
GO


/* -----------------------------------------------------------------------------
   1b. Storage size in practice — DATALENGTH
   -----------------------------------------------------------------------------
   DATALENGTH() returns the actual bytes stored for a value. For a VECTOR(768):

       8-byte header + 768 dimensions × 4 bytes = 3,080 bytes

   The VECTOR binary format includes an 8-byte metadata header before the
   element payload. So DATALENGTH returns 3,080, not 3,072. To recover the
   dimension count from raw bytes, subtract the header first:
       (DATALENGTH(col) - 8) / 4  → 768

   Compare that to the JSON text representation (what you see when you SELECT
   the column). Storing 768 floats as a JSON array like [0.123456, -0.987654, ...]
   takes roughly 10–12 characters per float × 768 = ~8,000–9,000 bytes —
   roughly 3× more space and no type enforcement.

   Prefer sys.columns.vector_dimensions (see §1a) over the DATALENGTH arithmetic
   — it's cleaner and correct for both float32 and float16 columns.
----------------------------------------------------------------------------- */

SELECT TOP (1)
    qe.PostId,
    DATALENGTH(qe.embeddings)               AS vector_bytes,       -- 3080 (8-byte header + 768×4)
    (DATALENGTH(qe.embeddings) - 8) / 4     AS dimension_count,    -- 768
    DATALENGTH(CAST(qe.embeddings AS NVARCHAR(MAX)))
                                            AS json_text_bytes      -- much larger
FROM dbo.QuestionEmbeddings qe;
GO

-- Quick sanity check: are all stored vectors the same dimension?
-- Mismatched dimensions would indicate a pipeline bug or a mid-flight model swap.
SELECT
    (DATALENGTH(embeddings) - 8) / 4  AS dimension_count,
    COUNT(*)                          AS row_count
FROM dbo.QuestionEmbeddings
GROUP BY DATALENGTH(embeddings);
GO


/* -----------------------------------------------------------------------------
   1c. Binary storage — client representation vs internal format
   -----------------------------------------------------------------------------
   SQL Server stores VECTOR internally as a compact binary (8-byte header +
   element payload). However, that raw binary is NOT accessible via CAST:

       CAST(col AS VARBINARY(MAX))  →  Msg 529, conversion not allowed.

   The only supported client-facing representations are:
     • NVARCHAR / VARCHAR  — JSON array format: [1.0, -0.5, 0.123, ...]
     • JSON               — same JSON array via JSON_VALUE / FOR JSON

   SQL Server converts to/from the JSON surface format on the way in and out.
   The compact binary is an internal implementation detail.

   Roundtrip test: NVARCHAR → VECTOR → NVARCHAR produces the same values,
   confirming that JSON is the interchange format and is lossless.
----------------------------------------------------------------------------- */

-- What the client sees: the first 80 characters of the JSON array:
SELECT TOP (1)
    LEFT(CAST(qe.embeddings AS NVARCHAR(MAX)), 80) + N'...' AS json_preview
FROM dbo.QuestionEmbeddings qe;
GO

-- Roundtrip: text → VECTOR → text.  Proves JSON is just an interchange format.
SELECT TOP (1)
    LEFT(CAST(
        CAST(CAST(qe.embeddings AS NVARCHAR(MAX)) AS VECTOR(768))
    AS NVARCHAR(MAX)), 80) + N'...' AS roundtripped_json
FROM dbo.QuestionEmbeddings qe;
GO


/* -----------------------------------------------------------------------------
   1d. Page-level storage — looking at the raw data page  [deep dive / optional]
   -----------------------------------------------------------------------------
   DBCC PAGE reveals the actual on-disk layout of an 8KB data page. For a
   VECTOR(768) row (3,072 bytes) SQL Server stores the row across pages using
   the normal row-overflow / LOB storage mechanism — large rows spill to LOB
   pages when the inline record exceeds the 8060-byte row limit.

   Step 1: find the physical location (file : page : slot) of a row.
   Step 2: use DBCC PAGE to dump the page and inspect the binary content.

   DBCC TRACEON(3604) redirects DBCC output to the client (SSMS Messages tab)
   instead of the SQL Server error log.

   WHERE IS THIS DOCUMENTED?
   ─────────────────────────
   The VECTOR docs state vectors are "stored in an optimized binary format"
   but say nothing about row-overflow:
     https://learn.microsoft.com/en-us/sql/relational-databases/vectors/vectors-sql-server

   The row-overflow mechanism itself is documented in the Pages and Extents
   Architecture Guide — specifically the "Large row support" section:
     https://learn.microsoft.com/en-us/sql/relational-databases/pages-and-extents-architecture-guide

   Key quote: "When the total row size exceeds the 8,060-byte limitation, the
   Database Engine dynamically moves one or more variable length columns to
   pages in a ROW_OVERFLOW_DATA allocation unit, starting with the widest column."

   Here's the connection you have to make yourself: VECTOR shares system_type_id = 165
   with varbinary (see §1a), so it follows the same overflow rules as any other
   large variable-length column. A VECTOR(768) is 3,080 bytes; combined with
   PostId (4) + chunk (up to ~8,000) the row exceeds 8,060 bytes, so the
   embeddings column spills to a ROW_OVERFLOW_DATA allocation unit.

   The DBCC PAGE output is the empirical confirmation — this specific behavior
   for VECTOR columns is not yet explicitly called out in the official docs.

   NOTE: This uses undocumented internals. Use for education only.
----------------------------------------------------------------------------- */

-- Step 1: physical location of one row (fn_PhysLocFormatter is the readable form):
SELECT TOP (1)
    qe.PostId,
    sys.fn_PhysLocFormatter(%%physloc%%) AS physical_location   -- (file:page:slot)
FROM dbo.QuestionEmbeddings qe;
GO

-- Step 2: dump the page.
-- Replace the page number with the value returned above.
-- Output in the Messages tab shows slot data including the raw VECTOR bytes.
/*
DBCC TRACEON(3604);                        -- redirect output to client
GO
DBCC PAGE('StackOverflow', 1, 8096, 3);   -- mode 3 = full row data
GO
DBCC TRACEOFF(3604);
GO
*/


/* =============================================================================
   SECTION 1e — HALF-PRECISION VECTORS: VECTOR(n, float16)
   =============================================================================

   SQL Server 2025 introduces an optional base type parameter for the VECTOR
   type. The default is float32 (32-bit IEEE 754 single-precision, 4 bytes per
   element). You can also specify float16 (16-bit half-precision, 2 bytes per
   element).

   Syntax:
       VECTOR( <dimensions> [, <base_type>] )
       base_type: float32 (default) | float16

   Why it matters
   ──────────────
   float32   768 dims × 4 bytes + 8-byte header = 3,080 bytes per vector
   float16   768 dims × 2 bytes + 8-byte header = 1,544 bytes per vector  ← half the payload

   At one million embeddings:
     float32  ~3 GB of raw vector data
     float16  ~1.5 GB — fits in half the space, reads faster from disk

   float16 also DOUBLES the dimension ceiling:
     float32  max 1,998 dimensions
     float16  max 3,996 dimensions
   This unlocks larger models like text-embedding-large (3,072 dims).

   The trade-off: float16 has reduced numerical precision. The representable
   range is ±65,504 (vs. ±3.4×10³⁸ for float32). For semantic similarity
   search this is almost always acceptable — embeddings are unit-normalized,
   so all values are in [−1, +1], well within float16 range.

   PLATFORM NOTE: float16 is a PREVIEW feature in SQL Server 2025. Enable
   PREVIEW_FEATURES first (already on from the DiskANN setup in init.sql).
----------------------------------------------------------------------------- */

-- 1e-1. Confirm PREVIEW_FEATURES is already on (required for float16):
SELECT name, value AS is_enabled
FROM sys.database_scoped_configurations
WHERE name = 'PREVIEW_FEATURES';
GO

-- 1e-2. Storage size comparison: float32 vs float16 at the same dimensions:
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

-- 1e-3. The new sys.columns metadata columns for float16:
--   vector_dimensions     — dimension count (same as max_length / element_size)
--   vector_base_type      — 0 = float32, 1 = float16
--   vector_base_type_desc — 'float32' or 'float16'
--
-- These columns only exist in SQL Server 2025. Older catalog queries using
-- max_length / 4 to infer dimensions will be incorrect for float16 columns
-- (where the stride is 2, not 4). Use vector_dimensions directly.

-- First create a small demo table with both types side by side:
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
    c.max_length            AS raw_max_length,    -- 3072 for float32, 1536 for float16
    c.vector_dimensions     AS dimensions,         -- new column: always 768
    c.vector_base_type      AS base_type_code,     -- 0 = float32, 1 = float16
    c.vector_base_type_desc AS base_type_name      -- 'float32' | 'float16'
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('tempdb..#vec_type_demo')
ORDER BY c.column_id;
GO

DROP TABLE IF EXISTS #vec_type_demo;
GO

-- 1e-4. QuestionEmbeddings uses float32 (the default). Check it:
SELECT
    c.name                  AS column_name,
    c.vector_dimensions     AS dimensions,
    c.vector_base_type_desc AS base_type
FROM sys.columns c
WHERE c.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
  AND c.vector_base_type_desc IS NOT NULL;
GO

-- 1e-5. Arithmetic with float16 — distance functions work identically.
--       The API is the same; the storage format is the only difference.
DECLARE @q32 VECTOR(3)          = '[0.1, 0.2, 0.3]';   -- float32 (default)
DECLARE @q16 VECTOR(3, float16) = '[0.1, 0.2, 0.3]';   -- float16

SELECT
    VECTOR_DISTANCE('cosine',    @q32, @q32) AS f32_cosine_self,     -- 0  (identical)
    VECTOR_DISTANCE('cosine',    @q16, @q16) AS f16_cosine_self,     -- 0  (identical)
    DATALENGTH(@q32)                         AS f32_bytes,           -- 20 (8 header + 3 × 4)
    DATALENGTH(@q16)                         AS f16_bytes;           -- 14 (8 header + 3 × 2)
GO

-- 1e-6. KEY LIMITATIONS to be aware of:
--
--   NO cross-type arithmetic:
--     VECTOR_DISTANCE(float32_col, float16_col) → Msg 42243 (type mismatch)
--     Both arguments to VECTOR_DISTANCE must use the same base type.
--
--   NO implicit float32 ↔ float16 conversion:
--     CAST(@float32_var AS VECTOR(n, float16)) → Msg 42238
--     You must re-embed with the new type, not cast.
--
--   float16 range is ±65,504:
--     Values outside this range (e.g., 70000.0) raise Msg 42241 at insert time.
--     Unit-normalized embeddings (all values in [−1, +1]) are always safe.
--
--   TDS transport: float16 vectors are currently sent as varchar(max) JSON
--     over the wire to client drivers (ODBC, JDBC, .NET). No binary TDS
--     transport yet — slightly more network overhead than float32.
--

-- Demonstrate the cross-type error (catches the error, prints the message):
BEGIN TRY
    DECLARE @v32 VECTOR(3)          = '[1.0, 0.0, 0.0]';
    DECLARE @v16 VECTOR(3, float16) = '[1.0, 0.0, 0.0]';
    SELECT VECTOR_DISTANCE('cosine', @v32, @v16);
END TRY
BEGIN CATCH
    PRINT 'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
    PRINT '=> Mixed base types in VECTOR_DISTANCE are not supported.';
END CATCH;
GO

-- Demonstrate the out-of-range error:
BEGIN TRY
    DECLARE @overflow VECTOR(3, float16) = '[1.0, 2.0, 70000.0]';
    SELECT @overflow;
END TRY
BEGIN CATCH
    PRINT 'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
    PRINT '=> float16 max representable value is 65,504. Unit-norm embeddings are safe.';
END CATCH;
GO

-- 1e-7. WHEN TO USE float16 vs float32
--
--   USE float16 WHEN:
--     - You need to store millions of embeddings and storage cost matters
--     - Your embedding model produces unit-normalized values (all values ≤ 1)
--     - You need dimensions > 1,998 (e.g., text-embedding-large at 3,072 dims)
--     - Approximate similarity search (RAG retrieval) is the workload
--
--   STAY WITH float32 WHEN:
--     - You need exact numerical fidelity (scientific / financial workloads)
--     - You mix embedding and non-embedding vector workloads on the same column
--     - Your client drivers need binary TDS transport for performance

-- Summary comparison:
SELECT col, float32_value, float16_value
FROM (VALUES
    ('Bytes per element',       '4',           '2'),
    ('Bytes per 768-dim vector (DATALENGTH)','3,080',        '1,544'),
    ('Max dimensions',          '1,998',        '3,996'),
    ('Value range',             '±3.4×10³⁸',   '±65,504'),
    ('Unit-norm safe?',         'Yes',          'Yes'),
    ('Cross-type VECTOR_DISTANCE','Supported', 'Not supported (same type required)'),
    ('Binary TDS transport',    'Yes',          'Not yet (JSON array over wire)'),
    ('ARM64 support',           'Yes',          'No'),
    ('Preview feature required','No',           'Yes')
) AS t(col, float32_value, float16_value);
GO


/* =============================================================================
   SECTION 2 — PHYSICAL STORAGE: FILEGROUPS AND DATA FILES
   ============================================================================= */

/* -----------------------------------------------------------------------------
   The QuestionEmbeddings table lives on a dedicated EMBEDDINGS filegroup backed
   by StackOverflow_Embeddings.ndf — separate from the operational data (.mdf)
   and log (.ldf).

   Why separate the vectors onto their own filegroup?

     OPERATIONAL ISOLATION
       Vector data and transactional data have different I/O profiles. Vectors
       are large, sequential-read (during index build and full scans). OLTP data
       is small, random-read. Mixing them on the same file can cause I/O contention.

     INDEPENDENT MANAGEMENT
       You can back up, restore, or OFFLINE the EMBEDDINGS filegroup independently.
       If you need to rebuild all embeddings from scratch, you drop and recreate
       the .ndf without touching the primary filegroup.

     STORAGE TIERING
       Point the EMBEDDINGS filegroup at a high-capacity SSD and the PRIMARY
       filegroup at NVMe. Right-size each independently.
----------------------------------------------------------------------------- */

-- All data files in the StackOverflow database:
SELECT
    fg.name                             AS filegroup_name,
    df.name                             AS logical_file_name,
    df.physical_name,
    df.type_desc                        AS file_type,
    df.size     * 8.0 / 1024           AS current_size_MB,
    df.growth   * 8.0 / 1024           AS autogrowth_MB,
    df.is_percent_growth
FROM sys.filegroups     fg
JOIN sys.database_files df ON fg.data_space_id = df.data_space_id
ORDER BY fg.data_space_id, df.file_id;
GO

-- Confirm QuestionEmbeddings lives on the EMBEDDINGS filegroup:
SELECT
    t.name              AS table_name,
    fg.name             AS filegroup_name,
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


/* =============================================================================
   SECTION 3 — AI_GENERATE_EMBEDDINGS: WHAT HAPPENS AT EXECUTION TIME
   ============================================================================= */

/* -----------------------------------------------------------------------------
   3a. The EXTERNAL MODEL catalog
   -----------------------------------------------------------------------------
   CREATE EXTERNAL MODEL registers a named pointer to an embedding endpoint.
   It's an implementation detail: swap the model without changing any queries.
   sys.external_models exposes the registration metadata.

   The LOCATION is HTTPS because SQL Server 2025 requires TLS for external
   calls. In this stack, NGINX terminates TLS in front of host Ollama.
----------------------------------------------------------------------------- */

SELECT
    em.name,
    em.location,
    em.model_type_desc, -- 'EMBEDDINGS'
    em.api_format       -- 'Ollama', 'AzureOpenAI', 'OpenAI', etc.
FROM sys.external_models em;
GO

-- The server-level config switch that permits outbound REST calls:
EXEC sp_configure 'external rest endpoint enabled';
GO


/* -----------------------------------------------------------------------------
   3b. What AI_GENERATE_EMBEDDINGS does at execution time
   -----------------------------------------------------------------------------
   Each call to AI_GENERATE_EMBEDDINGS:

     1. Serializes the input text as a JSON payload
     2. Makes an HTTPS POST to the EXTERNAL MODEL's LOCATION endpoint
     3. Reads the response, extracts the float array from the JSON
     4. Returns a native VECTOR value

   The call latency is dominated by the embedding service (Ollama on the host),
   not by SQL compute. Measure it:
----------------------------------------------------------------------------- */

-- Single embedding latency:
SET STATISTICS TIME ON;
GO
SELECT AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit' USE MODEL ollama)
    AS embedding;
GO
SET STATISTICS TIME OFF;
GO

-- 10 rows batched — compare elapsed time to single-call latency above:
SET STATISTICS TIME ON;
GO
SELECT TOP (10)
    p.Id,
    AI_GENERATE_EMBEDDINGS(p.Title USE MODEL ollama) AS embedding
FROM dbo.Posts p
WHERE p.PostTypeId = 1
  AND p.Title IS NOT NULL
ORDER BY p.Score DESC;
GO
SET STATISTICS TIME OFF;
GO


/* =============================================================================
   SECTION 4 — DISTANCE METRICS: COSINE, EUCLIDEAN, DOT PRODUCT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   VECTOR_DISTANCE(metric, v1, v2) returns a scalar distance. Lower = closer.
   SQL Server 2025 supports three metrics:

     'cosine'    1 - (v1 · v2) / (|v1| × |v2|)   angle-based, ignores magnitude
     'euclidean' √ Σ(v1ᵢ - v2ᵢ)²                 straight-line distance in n-space
     'dot'       -(v1 · v2)                      inner product, negated

   For text embeddings:
     - Cosine is the standard choice. It treats a short and a long passage
       about the same topic as equally close (magnitude is irrelevant).
     - Euclidean is sensitive to vector length — avoid for text unless you
       normalize the vectors first.
     - Dot product is equivalent to cosine when vectors are unit-normalized
       (which most embedding models produce). It's slightly cheaper to compute.

   Range for cosine distance on real text embeddings: roughly 0.1 (very similar)
   to 0.6 (unrelated). Below ~0.3 is usually a strong semantic match.
----------------------------------------------------------------------------- */

-- The three metrics on a simple 3-D pair of vectors:
DECLARE @v1 VECTOR(3) = '[1.0, 0.0, 0.0]';
DECLARE @v2 VECTOR(3) = '[0.866, 0.5, 0.0]';   -- ~30 degrees away from v1

SELECT
    VECTOR_DISTANCE('cosine',    @v1, @v2) AS cosine_distance,
    VECTOR_DISTANCE('euclidean', @v1, @v2) AS euclidean_distance,
    VECTOR_DISTANCE('dot',       @v1, @v2) AS dot_distance;
GO

-- VECTOR_NORM computes the magnitude of a vector using the specified norm.
-- Syntax: VECTOR_NORM(vector, norm_type)
-- Supported norm_type values:
--   'norm1'   — L1 norm: sum of absolute values          e.g. |3|+|4|+|0| = 7.0
--   'norm2'   — L2 Euclidean norm: √(Σ xᵢ²)              e.g. √(9+16+0)   = 5.0
--   'norminf' — Infinity norm: max of absolute values    e.g. max(3,4,0)  = 4.0
-- For unit-normalized embeddings, norm2 should be very close to 1.0.
DECLARE @v VECTOR(3) = '[3.0, 4.0, 0.0]';
SELECT
    VECTOR_NORM(@v, 'norm1')   AS l1_norm,    -- 7.0
    VECTOR_NORM(@v, 'norm2')   AS l2_norm,    -- 5.0
    VECTOR_NORM(@v, 'norminf') AS inf_norm;   -- 4.0
GO

-- Are our stored embeddings unit-normalized?
-- Most embedding models (including nomic-embed-text) produce unit vectors.
SELECT
    MIN(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS min_norm,
    MAX(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS max_norm,
    AVG(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS avg_norm
FROM dbo.QuestionEmbeddings;
GO


/* =============================================================================
   SECTION 5 — QUERY EXECUTION: EXACT kNN (THE TABLE SCAN PATH)
   ============================================================================= */

/* -----------------------------------------------------------------------------
   5a. The exact kNN query — and what SQL Server does to answer it
   -----------------------------------------------------------------------------
   Without a vector index, finding the K nearest neighbors requires:

     1. Embed the query text                     (one HTTP call to Ollama)
     2. Scan EVERY row in QuestionEmbeddings     (O(n) reads)
     3. Compute VECTOR_DISTANCE for every row    (O(n) float arithmetic)
     4. Sort all n distances and take the top K  (O(n log n))

   This is called an exhaustive or brute-force kNN search. It guarantees
   exact (perfect-recall) results. It's fine for tens of thousands of rows.
   It doesn't scale to millions.

   SET STATISTICS IO and TIME show exactly what it cost.
   After running this, look at the logical reads in the Messages tab —
   that number is the cost of a full scan of the embeddings table.
----------------------------------------------------------------------------- */

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @query_text   NVARCHAR(MAX) = N'how do I undo my last git commit?';
DECLARE @query_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@query_text USE MODEL ollama);

SELECT TOP (10)
    p.Id,
    p.Title,
    p.Score,
    VECTOR_DISTANCE('cosine', @query_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
ORDER BY distance;    -- ORDER BY distance = full-sort of all n computed values
GO
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

-- The key numbers:
--   "logical reads" on QuestionEmbeddings = every data page in the EMBEDDINGS file.
--   "elapsed time" grows linearly with row count — double the rows, double the time.


/* -----------------------------------------------------------------------------
   5b. The execution plan for exact kNN
   -----------------------------------------------------------------------------
   Enable INCLUDE ACTUAL EXECUTION PLAN in SSMS (Ctrl+M), then re-run the
   query above. You'll see this operator chain:

     [Clustered Index Scan]  →  [Compute Scalar]  →  [Top Sort]  →  [SELECT]

   Operator by operator:

     Clustered Index Scan
       Reads every row from QuestionEmbeddings. No predicate can filter rows
       before the distance is computed — you must read the vector to know the
       distance. This is the fundamental cost of exact kNN.

     Compute Scalar
       Calls VECTOR_DISTANCE(cosine, @query_vector, qe.embeddings) for each row.
       This is float arithmetic over 768 values per row.

     Top Sort
       Maintains a min-heap of the K closest candidates seen so far. It only
       retains K rows in memory at a time, but it must read ALL n rows before
       it can be certain the heap is correct.

     SELECT
       Returns the K rows.

   The DiskANN index (Demo 2) replaces the Scan + Compute Scalar with a
   dedicated graph-walk operator that reads far fewer rows.
----------------------------------------------------------------------------- */

-- Capture plan as XML for offline analysis:
SET STATISTICS XML ON;
GO
DECLARE @query_text   NVARCHAR(MAX) = N'how do I undo my last git commit?';
DECLARE @query_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@query_text USE MODEL ollama);

SELECT TOP (10)
    p.Id,
    p.Title,
    VECTOR_DISTANCE('cosine', @query_vector, qe.embeddings) AS distance
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON qe.PostId = p.Id
ORDER BY distance;
GO
SET STATISTICS XML OFF;
GO


/* -----------------------------------------------------------------------------
   5c. Cosine distance in practice — strong match vs. weak match
   -----------------------------------------------------------------------------
   Concrete numbers help you understand what "distance" means.
   A distance near 0.1 is a very strong match; near 0.5 is background noise.
   These thresholds are model-dependent but consistent within a model.
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

-- See how the real StackOverflow questions cluster around the query —
-- the top results are tight; then there is a natural gap before the noise:
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
-- Notice the score drop-off: top results are in the 0.1–0.3 range.
-- Results above ~0.4 are usually semantically unrelated to the query.
-- Choosing a distance threshold (instead of TOP K) is an alternative strategy —
-- but TOP K is simpler and tends to be more robust in practice.
