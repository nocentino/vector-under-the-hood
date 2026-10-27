SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production

  Demo 1 of 3: VECTOR DATA TYPE INTERNALS
  Storage layout  ·  Catalog views  ·  Query execution
=============================================================================

  Learning objective:
    You'll be able to describe vector internals: storage, indexing, and
    query execution. This demo covers storage and exact-search execution.
    Indexing is Demo 2.

  Time budget (about 15 minutes):
    Section 0  files, filegroup, log          1 min
    Section 1  type, bytes, pages, float16    4 min
    Section 2  embedding call, cost per row   2 min
    Section 3  distance, toy then real        3 min
    Section 4  exact kNN, cold cache, plan,
               why a B-tree can't help        5 min

  Prerequisites:
    The stack is up (./start.sh) and StackOverflow is restored and embedded.
    The sql-init container ran setup/init.sql at startup, which embeds
    1,000 rows. Run setup/expand-embeddings.sh to grow it to 10,000 rows
    (recommended; Demo 02's scale numbers assume 10,000).

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run the sections top to bottom. Every one is idempotent.

  Optional deep dives live in demos/01-vector-internals-optional.sql.
=============================================================================
*/

USE [StackOverflow];
GO


/* =============================================================================
   SECTION 0: WHERE DOES IT LIVE? DATA AND LOG FILES
   ============================================================================= */

/* -----------------------------------------------------------------------------
   0a. The files behind the database
   -----------------------------------------------------------------------------
   Before we look inside a vector, let's see where it sits on disk.
   QuestionEmbeddings lives on its own EMBEDDINGS filegroup, backed by
   StackOverflow_Embeddings.ndf. That's separate from the operational data
   (.mdf) and the transaction log (.ldf).

   Why? Vectors are big and read in bulk (scans, index builds) or at random
   (graph walks). OLTP data is small. On their own filegroup you can size,
   back up, and place the vectors on different storage than the operational data.

   Don't forget the log. Loading embeddings is heavily logged: I measured about
   3,600 bytes of log per inserted row, so a 1,000,000-row load writes roughly
   3.6 GB. Size the log for your embedding loads and your index rebuilds.
----------------------------------------------------------------------------- */

-- Every file in the database, data and log. Log files don't belong to a
-- filegroup, so their filegroup_name is NULL.
SELECT
    fg.name                             AS filegroup_name,
    df.name                             AS logical_file_name,
    df.physical_name,
    df.type_desc                        AS file_type,       -- ROWS or LOG
    df.size * 8.0 / 1024                AS current_size_MB
FROM sys.database_files df
LEFT JOIN sys.filegroups fg ON fg.data_space_id = df.data_space_id
ORDER BY df.type, fg.data_space_id, df.file_id;
GO


/* =============================================================================
   SECTION 1: THE VECTOR DATA TYPE, WHAT IT IS AT THE BINARY LEVEL
   ============================================================================= */

/* -----------------------------------------------------------------------------
   1a. VECTOR in the type catalog
   -----------------------------------------------------------------------------
   VECTOR is a first-class type in SQL Server 2025. It shows up in sys.types
   just like INT, NVARCHAR, or DATETIME2. There are two max_length values you
   need to know:

   sys.types:    max_length = 8000  (type-level maximum for any VECTOR column)
   sys.columns:  max_length = 8 + dimensions × element_bytes
                 e.g. VECTOR(768) float32:  8 + 768 × 4 = 3,080
                      VECTOR(768) float16:  8 + 768 × 2 = 1,544

   MAXIMUM DIMENSIONS
   ──────────────────
   The 8000-byte type ceiling (sys.types.max_length) translates to:
     float32:  (8000 - 8) / 4 = 1,998 dimensions max
     float16:  (8000 - 8) / 2 = 3,996 dimensions max

   We're using 768 because that's what our embedding model outputs:
   nomic-embed-text (https://ollama.com/library/nomic-embed-text). You don't
   pick the dimension count. The model does. Every model produces a
   fixed-width vector, and your VECTOR column has to match it exactly.
   Common sizes: 384 (MiniLM), 768 (nomic-embed-text, BGE), 1,536 (OpenAI
   text-embedding-ada-002), 3,072 (text-embedding-3-large).

   That 8-byte prefix is a binary metadata header SQL Server puts in front of
   every stored VECTOR value. DATALENGTH() and sys.columns.max_length both
   include it. For the real dimension count, use sys.columns.vector_dimensions.

   Here's what's documented versus what I observed. The docs say each element
   is a 4-byte float and give the 1,998 / 3,996 limits. The 8-byte header
   isn't documented. You can see it here with DATALENGTH and sys.columns, so
   treat it as an implementation detail that could change.
     https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type

   Everything else in this demo builds on this. The type isn't text, isn't
   JSON, and isn't a blob you manage yourself. It's a native numeric array
   with a known, fixed stride.
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
    c.name                       AS column_name,
    t.name                       AS type_name,
    c.max_length                 AS max_length_bytes,     -- 3080 (8-byte header + 768×4 = 3,072)
    c.vector_dimensions          AS vector_dimensions,    -- SQL Server 2025: authoritative count
    c.vector_base_type_desc      AS base_type             -- 'float32' | 'float16'
FROM sys.columns c
JOIN sys.types   t ON t.user_type_id = c.user_type_id    -- user_type_id avoids duplicates (VECTOR shares system_type_id=165 with varbinary)
WHERE c.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
ORDER BY c.column_id;
GO


/* -----------------------------------------------------------------------------
   1b. Storage size in practice: DATALENGTH
   -----------------------------------------------------------------------------
   DATALENGTH() returns the actual bytes stored for a value. For a VECTOR(768):

       8-byte header + 768 dimensions × 4 bytes = 3,080 bytes

   The 8-byte header sits in front of the element payload, so DATALENGTH
   returns 3,080, not 3,072. To get the dimension count back from raw bytes,
   subtract the header first:
       (DATALENGTH(col) - 8) / 4  → 768

   Now compare that to the JSON text you see when you SELECT the column.
   SQL Server writes each float in scientific notation, like 4.3272693e-002,
   so 768 of them come to about 12,000 characters. As NVARCHAR that's
   ~24,000 bytes. Nearly 8× the binary size, with no type enforcement.

   I'd use sys.columns.vector_dimensions (see §1a) over the DATALENGTH math.
   It's cleaner, and it's correct for both float32 and float16 columns.
----------------------------------------------------------------------------- */

SELECT TOP (1)
    qe.PostId,
    DATALENGTH(qe.embeddings)                        AS vector_bytes,       -- 3080 (8-byte header + 768×4)
   (DATALENGTH(qe.embeddings) - 8) / 4               AS dimension_count,    -- 768
    DATALENGTH(CAST(qe.embeddings AS NVARCHAR(MAX))) AS json_text_bytes     -- much larger
FROM dbo.QuestionEmbeddings qe;
GO



/* -----------------------------------------------------------------------------
   1b-2. Down to the page: where does the vector actually live?
   -----------------------------------------------------------------------------
   A VECTOR(768) is 3,080 bytes and a data page holds about 8,060 bytes of
   row data, so the vector stays IN_ROW. The docs say a row that exceeds 8,060
   bytes pushes its widest variable-length column to ROW_OVERFLOW_DATA pages,
   but ours never gets close. A vector would only overflow if the chunk text
   grew past ~4,900 bytes.
     https://learn.microsoft.com/en-us/sql/relational-databases/pages-and-extents-architecture-guide

   Roughly 1.5 rows fit on each page, so an exact kNN scan has to read every
   one of those pages. That's the number you'll see in STATISTICS IO in §4.
----------------------------------------------------------------------------- */

-- Which filegroup, which allocation units, how many pages and rows per page.
-- ROW_OVERFLOW_DATA has a catalog row but zero pages.
SELECT
    fg.name                 AS filegroup_name,
    au.type_desc            AS allocation_unit,
    au.data_pages,
    p.rows,
    CAST(p.rows * 1.0 / NULLIF(au.data_pages, 0) AS DECIMAL(5,2)) AS rows_per_page
FROM sys.partitions       p
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
JOIN sys.filegroups       fg ON fg.data_space_id = au.data_space_id
WHERE p.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
  AND p.index_id  = 1;
GO

/* -----------------------------------------------------------------------------
   See it for real: read the vector straight off the page
   -----------------------------------------------------------------------------
   DBCC PAGE shows the bytes of a row exactly as they sit on disk. It's
   undocumented, so look but never use it in production code. We'll pull the
   first row's bytes, decode them by hand, and compare them to what SELECT
   prints. If the bytes on the page ARE the vector, they have to match.

   A row on this page is laid out like this:

     17 bytes   record overhead: status, fixed-length size, PostId (4 bytes),
                column count, null bitmap, variable-column count, and the
                end offset of each variable-length column
      8 bytes   the VECTOR header (the 8 bytes from §1a)
   3072 bytes   768 floats, 4 bytes each (the rest of the row is the chunk text)

   Each 4-byte float is IEEE 754, stored little-endian: 1 sign bit, 8 exponent
   bits, 23 mantissa bits.
     value = (-1)^sign × (1 + mantissa / 2^23) × 2^(exponent - 127)
----------------------------------------------------------------------------- */

DECLARE @pid INT, @file INT, @page INT, @slot INT;
SELECT TOP (1) @pid = qe.PostId, @file = plc.file_id, @page = plc.page_id, @slot = plc.slot_id
FROM dbo.QuestionEmbeddings qe
CROSS APPLY sys.fn_PhysLocCracker(%%physloc%%) AS plc
ORDER BY qe.PostId;

-- Ask DBCC PAGE for the page as rows, then stitch the row's hex dump back into bytes.
CREATE TABLE #pg (ParentObject VARCHAR(255), Object VARCHAR(255), Field VARCHAR(255), VALUE VARCHAR(MAX));
DECLARE @sql NVARCHAR(200) = CONCAT(N'DBCC PAGE(''', DB_NAME(), N''', ', @file, N', ', @page, N', 3) WITH TABLERESULTS;');
INSERT #pg EXEC (@sql);

DECLARE @hex VARCHAR(MAX) = (
    SELECT STRING_AGG(h.hexpart, '')
           WITHIN GROUP (ORDER BY CONVERT(BIGINT, CONVERT(BINARY(8), '0x' + LEFT(p.VALUE, 16), 1)))
    FROM #pg p
    CROSS APPLY (SELECT LTRIM(SUBSTRING(p.VALUE, 18, 8000)) AS rest) r
    CROSS APPLY (SELECT REPLACE(LEFT(r.rest, CHARINDEX('  ', r.rest + '  ') - 1), ' ', '') AS hexpart) h
    WHERE p.Object LIKE 'Memory Dump%' AND p.ParentObject LIKE CONCAT('Slot ', @slot, ' Offset%'));
DECLARE @rec  VARBINARY(MAX) = CONVERT(VARBINARY(MAX), '0x' + @hex, 1);
DECLARE @json NVARCHAR(MAX)  = (SELECT CAST(embeddings AS NVARCHAR(MAX))
                                FROM dbo.QuestionEmbeddings WHERE PostId = @pid);

SELECT
    @pid                       AS post_id,
    DATALENGTH(@rec)           AS row_bytes_on_page,
    SUBSTRING(@rec, 1, 17)     AS record_overhead,
    SUBSTRING(@rec, 18, 8)     AS vector_header;

-- Decode every float: reverse the 4 bytes (little-endian), split the bits, apply the formula.
SELECT g.value                                       AS element,
       y.b                                           AS bytes_on_page,
       d.decoded                                     AS decoded_from_bytes,
       JSON_VALUE(@json, CONCAT('$[', g.value, ']')) AS select_shows
INTO #floats
FROM GENERATE_SERIES(0, 767) AS g
CROSS APPLY (SELECT SUBSTRING(@rec, 26 + 4 * g.value, 4) AS b) y
CROSS APPLY (SELECT CAST(0x00 + SUBSTRING(y.b,4,1) + SUBSTRING(y.b,3,1)
                              + SUBSTRING(y.b,2,1) + SUBSTRING(y.b,1,1) AS BIGINT) AS u) bits
CROSS APPLY (SELECT bits.u / CAST(2147483648 AS BIGINT) AS sign_bit,
                    (bits.u / 8388608) % 256            AS exponent,
                    bits.u % 8388608                    AS mantissa) f
CROSS APPLY (SELECT (1 - 2 * f.sign_bit)
                  * (1 + f.mantissa / CAST(8388608 AS FLOAT))
                  * POWER(CAST(2 AS FLOAT), f.exponent - 127) AS decoded) d;

-- The first five. The bytes on the left are the numbers on the right:
SELECT TOP (5) * FROM #floats ORDER BY element;

-- All 768. SELECT prints 8 digits, so "match" means to those 8 digits.
SELECT COUNT(*) AS floats_on_page,
       SUM(CASE WHEN ABS(decoded_from_bytes - CAST(select_shows AS FLOAT)) < 1E-7 THEN 1 ELSE 0 END)
                AS match_what_select_prints
FROM #floats;

DROP TABLE #floats;
DROP TABLE #pg;
GO
-- That's the whole trick: the vector is 768 raw float32s in the row, and SQL
-- Server turns them into the JSON you see when you SELECT. To see the full hex
-- dump instead (about 1,400 lines), run DBCC TRACEON(3604) and then
-- DBCC PAGE('StackOverflow', <file>, <page>, 3) without WITH TABLERESULTS.


/* -----------------------------------------------------------------------------
   1c. Binary storage: client representation vs internal format
   -----------------------------------------------------------------------------
   Internally, SQL Server stores VECTOR as compact binary (8-byte header +
   element payload). But you can't get at that raw binary with CAST:

       CAST(col AS VARBINARY(MAX))  →  Msg 529, conversion not allowed.

   Here's what clients can actually work with:
     • NVARCHAR / VARCHAR : a JSON array, like [1.0, -0.5, 0.123, ...]
     • JSON               : same JSON array via JSON_VALUE / FOR JSON

   SQL Server converts to and from JSON on the way in and out. The compact
   binary is an internal implementation detail.

   Let's roundtrip it: NVARCHAR → VECTOR → NVARCHAR gives back the same
   values. JSON is the interchange format, and it's lossless.
----------------------------------------------------------------------------- */

-- What the client sees: the first 80 characters of the JSON array:
SELECT TOP (1)
    LEFT(CAST(qe.embeddings AS NVARCHAR(MAX)), 80) + N'...' AS json_preview
FROM dbo.QuestionEmbeddings qe;
GO

-- Roundtrip: text → VECTOR → text. JSON is just the interchange format.
SELECT TOP (1)
    LEFT(CAST(
        CAST(CAST(qe.embeddings AS NVARCHAR(MAX)) AS VECTOR(768))
    AS NVARCHAR(MAX)), 80) + N'...' AS roundtripped_json
FROM dbo.QuestionEmbeddings qe;
GO


/* -----------------------------------------------------------------------------
   1d. Half precision: VECTOR(n, float16)
   -----------------------------------------------------------------------------
   SQL Server 2025 adds an optional base type to VECTOR. The default is
   float32 (4 bytes per element). float16 is half precision, 2 bytes per
   element:

       VECTOR( <dimensions> [, <base_type>] )     base_type: float32 | float16

   What you get:
     - Half the payload. 768 dims: 8-byte header + 1,536 = 1,544 bytes, against
       3,080 for float32. At a million embeddings that's ~1.5 GB instead of ~3 GB.
     - A higher dimension ceiling: 3,996 instead of 1,998. That's what makes
       models like text-embedding-3-large (3,072 dims) fit.

   What it costs:
     - Precision. float16 covers ±65,504 and keeps about three significant
       digits per element. Embeddings are unit-length, so every value is in
       [-1, +1], well inside the range. On real distances the change is
       around 0.00001, and the optional Appendix A measures it.

   PLATFORM NOTE: float16 is a PREVIEW feature in SQL Server 2025, so it needs
   PREVIEW_FEATURES on (already on, from the DiskANN setup in init.sql). The
   docs also say float16 isn't supported on Arm64. It works on this Apple
   Silicon laptop because the container runs as linux/amd64 under Rosetta.
     https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type-half-precision-float
----------------------------------------------------------------------------- */

-- Same 768 values, two storage types. The header is the same size in both:
SELECT
    'float32 (default)' AS base_type,
    768                 AS dimensions,
    8 + 768 * 4         AS expected_bytes,
    DATALENGTH(CAST('[' + REPLICATE('0.1,', 767) + '0.1]' AS VECTOR(768)))
                        AS actual_bytes
UNION ALL
SELECT
    'float16',
    768,
    8 + 768 * 2,
    DATALENGTH(CAST('[' + REPLICATE('0.1,', 767) + '0.1]' AS VECTOR(768, float16)));
GO

-- The one limit that bites first: you can't mix base types. Caught here so you
-- can read the message.
BEGIN TRY
    DECLARE @v32 VECTOR(3)          = '[1.0, 0.0, 0.0]';
    DECLARE @v16 VECTOR(3, float16) = '[1.0, 0.0, 0.0]';
    SELECT VECTOR_DISTANCE('cosine', @v32, @v16);
END TRY
BEGIN CATCH
    PRINT 'Error ' + CAST(ERROR_NUMBER() AS NVARCHAR(10)) + ': ' + ERROR_MESSAGE();
    PRINT '=> Pick one base type per column. A direct CAST between them fails too,';
    PRINT '   so changing your mind means converting through JSON text or re-embedding.';
END CATCH;
GO

-- WHEN TO USE IT
--   float16: millions of embeddings where storage matters, unit-length model
--            output, or a model with more than 1,998 dimensions.
--   float32: exact numeric fidelity, or client drivers older than ODBC 18.7.1
--            and JDBC 13.4 (they can't send float16 in binary).
-- The precision measurement on real text, the out-of-range error, and the
-- catalog metadata are in demos/01-vector-internals-optional.sql, Appendix A.


/* =============================================================================
   SECTION 2: AI_GENERATE_EMBEDDINGS, WHAT HAPPENS AT EXECUTION TIME
   ============================================================================= */

/* -----------------------------------------------------------------------------
   2a. The EXTERNAL MODEL catalog
   -----------------------------------------------------------------------------
   CREATE EXTERNAL MODEL registers a named pointer to an embedding endpoint.
   Your queries use the name, so you can swap the model without touching
   them. sys.external_models shows you the registration metadata.

   Notice the LOCATION is HTTPS. SQL Server 2025 requires TLS for external
   calls, so in this stack NGINX terminates TLS in front of Ollama on the host.
----------------------------------------------------------------------------- */

SELECT
    em.name,
    em.location,
    em.model_type_desc, -- 'EMBEDDINGS'
    em.api_format       -- 'Ollama', 'AzureOpenAI', 'OpenAI', etc.
FROM sys.external_models em;
GO

-- The server-level switch that allows outbound REST calls:
EXEC sp_configure 'external rest endpoint enabled';
GO


/* -----------------------------------------------------------------------------
   2b. What AI_GENERATE_EMBEDDINGS does at execution time
   -----------------------------------------------------------------------------
   Here's what each call to AI_GENERATE_EMBEDDINGS does:

     1. Serializes the input text as a JSON payload
     2. Makes an HTTPS POST to the EXTERNAL MODEL's LOCATION endpoint
     3. Reads the response, extracts the float array from the JSON
     4. Returns a native VECTOR value

   Most of the latency is the embedding service (Ollama on the host), not
   SQL compute. Let's measure it:
----------------------------------------------------------------------------- */

-- Single embedding latency:
SET STATISTICS TIME ON;
GO
SELECT AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit' USE MODEL ollama)
    AS embedding;
GO
SET STATISTICS TIME OFF;
GO

-- 10, 50, and 100 rows. Each one is timed on its own. The text comes from the
-- small QuestionEmbeddings table so we time the embedding calls and not a sort
-- of 400,000 posts. Watch how the time scales with the row count:
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
-- It's linear: about 15 ms per row on my M2 (10 rows ~140 ms, 100 rows ~1.5 s).
-- Each row is its own call to Ollama. There's no batching. That's about 65
-- embeddings a second here, so a 1,000,000-row load takes about 4 hours.
-- Plan the embedding pipeline like any other bulk load, and size your model
-- host for the throughput you need.
--
-- One more thing: keep AI_GENERATE_EMBEDDINGS at the top level of the query,
-- next to the TOP. In one test I wrapped it in a derived table under an
-- aggregate and the query was still running after five minutes, so I killed it.
-- Use the plan to see how many times the function runs.


/* =============================================================================
   SECTION 3: DISTANCE METRICS, COSINE, EUCLIDEAN, DOT PRODUCT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   VECTOR_DISTANCE(metric, v1, v2) returns a scalar distance. Lower = closer.
   SQL Server 2025 supports three metrics: 'cosine', 'euclidean', and 'dot'.

   For text embeddings:
     - Cosine is the standard choice. It compares direction, so a short and a
       long passage on the same topic come out equally close.
     - Euclidean cares about vector length. Skip it for text unless you
       normalize the vectors first.
     - Dot product matches cosine when vectors are unit-length (most
       embedding models produce those). It's a bit cheaper to compute.

   On real text embeddings, cosine distance runs roughly 0.1 (very similar)
   to 0.7 (unrelated). Below ~0.3 is usually a strong semantic match.

   The formulas and VECTOR_NORM are in demos/01-vector-internals-optional.sql,
   Appendix B.
----------------------------------------------------------------------------- */

-- The three metrics on a simple 3-D pair of vectors, so you can see the scale.
-- v1 and v2 are 30 degrees apart. v1 and v3 are at right angles (nothing in
-- common). Cosine distance is 0 for the same direction and 1 at right angles
-- (opposite directions would be 2, but text embeddings rarely get there):
DECLARE @v1 VECTOR(3) = '[1.0, 0.0, 0.0]';
DECLARE @v2 VECTOR(3) = '[0.866, 0.5, 0.0]';   -- ~30 degrees away from v1
DECLARE @v3 VECTOR(3) = '[0.0, 1.0, 0.0]';     -- 90 degrees away from v1

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


/* -----------------------------------------------------------------------------
   3b. The same function on real text
   -----------------------------------------------------------------------------
   Nothing changes except the size. Three numbers become 768, and the model
   picks them so that sentences with similar meaning point the same way.
   Let's embed three sentences and measure them against one question:

     - the question:    how do I undo my last git commit?
     - a strong match:  git revert last commit without losing changes
     - a weak match:    what type of cheeses should I use on a quattro formaggi pizza

   Real distances make "distance" easier to reason about. Near 0.1 is a very
   strong match. Past 0.5 is background noise. The thresholds depend on the
   model, but they're consistent within a model.
----------------------------------------------------------------------------- */

DECLARE @question     VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama);

DECLARE @strong_match VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'git revert last commit without losing changes' USE MODEL ollama);

DECLARE @weak_match   VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'what type of cheeses should I use on a quattro formaggi pizza' USE MODEL ollama);

SELECT
    pair,
    VECTOR_DISTANCE('cosine',    a, b) AS cosine_distance,
    VECTOR_DISTANCE('euclidean', a, b) AS euclidean_distance,
    VECTOR_DISTANCE('dot',       a, b) AS dot_distance
FROM (VALUES
    ('question vs strong match', @question, @strong_match),
    ('question vs weak match',   @question, @weak_match)
) AS t(pair, a, b);
GO
-- Two things to notice:
--   1. The strong match is near 0.1 and the weak match is past 0.5. That's
--      the same 0 to 1 scale as the 3-D example, just with real text.
--   2. dot_distance is cosine_distance minus 1. These vectors are
--      unit-length, so the dot product IS the cosine similarity. That's why
--      dot is a cheaper stand-in for cosine here. The math, and a check that
--      every stored vector is unit-length, are in the optional Appendix B.


/* -----------------------------------------------------------------------------
   3c. What a whole corpus looks like around one question
   -----------------------------------------------------------------------------
   Now measure the question against every embedded StackOverflow question and
   look at how the distances fall off. The top results are tight, then there's
   a natural gap before the noise.
----------------------------------------------------------------------------- */

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
-- Notice the drop-off: the top results are in the 0.1 to 0.3 range.
-- Anything above ~0.4 is usually unrelated to the query.
-- You could use a distance threshold instead of TOP K, but in practice
-- TOP K is simpler and holds up better.


/* =============================================================================
   SECTION 4: QUERY EXECUTION, EXACT kNN (THE TABLE SCAN PATH)
   ============================================================================= */

/* -----------------------------------------------------------------------------
   4a. The exact kNN query, and what SQL Server does to answer it
   -----------------------------------------------------------------------------
   Without a vector index, here's what it takes to find the K nearest neighbors:

     1. Embed the query text                     (one HTTP call to Ollama)
     2. Scan EVERY row in QuestionEmbeddings     (O(n) reads)
     3. Compute VECTOR_DISTANCE for every row    (O(n) float arithmetic)
     4. Keep the K smallest distances            (Top N Sort, O(n log K))

   That's an exhaustive, or brute-force, kNN search. The results are exact
   (perfect recall). It's fine for tens of thousands of rows. It doesn't
   scale to millions.

   One query-shape tip: rank inside the satellite table first, then join to
   Posts for the 10 winners. If you join first, the optimizer can join every
   row to Posts before the sort. On ~10,000 rows that cost about 41,500 reads
   on Posts, against 40 for rank-then-join. The CTE below keeps the join to
   10 rows.

   SET STATISTICS IO and TIME show you exactly what it cost. After you run
   it, check the logical reads in the Messages tab. That number is the cost
   of a full scan of the embeddings table.
----------------------------------------------------------------------------- */

SET STATISTICS IO ON;
SET STATISTICS TIME ON;
GO
DECLARE @query_text   NVARCHAR(MAX) = N'how do I undo my last git commit?';
DECLARE @query_vector VECTOR(768)   = AI_GENERATE_EMBEDDINGS(@query_text USE MODEL ollama);

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

-- The key numbers:
--   "logical reads" on QuestionEmbeddings = every data page of the table.
--   Posts reads stay tiny: 10 key lookups.
--   "elapsed time" grows linearly with row count. Demo 02 Section 2a measures it.

-- Now the same query on a COLD cache, so the pages have to come from disk.
-- DEV BOXES ONLY: DROPCLEANBUFFERS empties the buffer pool for the whole instance.
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
-- Look at "read-ahead reads" on QuestionEmbeddings. On my box it was about
-- 7,000 pages, and the query ran 3 to 10 times slower than warm (40 to 210 ms
-- against 8 to 25 ms). The scan is sequential, so the engine reads ahead in
-- big chunks. That's the I/O profile from Section 0, and it's why the
-- EMBEDDINGS filegroup's storage matters for exact search and for index builds.


/* -----------------------------------------------------------------------------
   4b. The execution plan for exact kNN
   -----------------------------------------------------------------------------
   Turn on INCLUDE ACTUAL EXECUTION PLAN (Ctrl+M in SSMS) and re-run the
   query in 4a. Here's the plan I got on this box, and what to look at in it:

     [Clustered Index Scan]  →  [Compute Scalar]  →  [Sort (Top N)]
        →  [Gather Streams]  →  [Top]  →  [Nested Loops to Posts]  →  [SELECT]

   Read it bottom-up, right to left:

     Clustered Index Scan
       Actual rows = every row in the table (10,300 here). There's no
       predicate, because you have to read the vector to know the distance.
       That's the fundamental cost of exact kNN.

     Compute Scalar
       Click it and open Defined Values. You'll find
       vector_distance(N'cosine', @query_vector, embeddings), calculated once
       per row. That's 768 multiplications per row.

     Sort (Top N), then Gather Streams, then Top
       This plan is parallel (DOP 12 on my box). Each thread keeps its own
       10 best rows, so the Sort emits 120 actual rows. Gather Streams merges
       them, and Top picks the final 10. The sort memory grant is tiny
       (about 3 MB) because it only ever holds 10 rows per thread.

     Nested Loops + Clustered Index Seek on Posts
       10 seeks for the 10 winners. Estimated rows show 1 per seek, actual
       rows total 10.

   Two things that matter later:
     - Estimates are fine here (10,300 estimated, 10,300 actual), so don't
       blame the optimizer. The cost is in the scan and the math, not a bad plan.
     - Parallelism makes elapsed time look better than the work really is.
       Compare CPU time, which keeps growing with every row (Demo 2 §2c).

   The DiskANN index (Demo 2) replaces the Scan + Compute Scalar with a
   graph walk. Demo 2 measures when that pays off and when it doesn't.
----------------------------------------------------------------------------- */



/* -----------------------------------------------------------------------------
   4c. Why a B-tree can't help
   -----------------------------------------------------------------------------
   Every index you already know is a B-tree, and a B-tree needs a key it can
   compare and sort. A vector has neither. The docs say it plainly: no B-tree
   or columnstore index on a vector column, and no comparison operators.
     https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type#limitations

   Three tries, three errors. These are expected.
----------------------------------------------------------------------------- */

-- 1. A vector can't be an index key (Msg 1978):
CREATE INDEX ix_vec_key ON dbo.QuestionEmbeddings(embeddings);
GO

-- 2. Or compared with = (Msg 8117):
DECLARE @qv VECTOR(768) = (SELECT embeddings FROM dbo.QuestionEmbeddings WHERE PostId = 219716);
SELECT COUNT(*) FROM dbo.QuestionEmbeddings WHERE embeddings = @qv;
GO

-- 3. Or sorted (Msg 42213):
SELECT TOP (1) PostId FROM dbo.QuestionEmbeddings ORDER BY embeddings;
GO

-- You CAN carry a vector as an INCLUDE column on a normal index, but that
-- only copies it. It doesn't help find neighbors.
--
-- "Close to" isn't something a sort order can answer. That's why exact kNN
-- reads every row, and why the vector index in Demo 2 is a graph, not a tree.
