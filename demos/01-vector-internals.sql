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
    Describe vector internals: storage, indexing, and query execution. This
    demo covers storage and exact search. Indexing is Demo 2.

  Prerequisites:
    The stack is up (./start.sh). setup/init.sql embedded 1,000 rows at
    startup; run setup/expand-embeddings.sh to grow it to 10,000
    (recommended; Demo 02's numbers assume 10,000).

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
   QuestionEmbeddings lives on its own EMBEDDINGS filegroup
   (StackOverflow_Embeddings.ndf), apart from the operational data (.mdf) and
   the log (.ldf). Vectors are big and read in bulk (scans, builds) or at
   random (graph walks), so on their own filegroup you can size, back up, and
   place them on different storage.

   Loading embeddings is heavily logged: about 3,600 bytes of log per row, so
   a 1,000,000-row load writes ~3.6 GB. Size the log for loads and rebuilds.
----------------------------------------------------------------------------- */

-- Every data and log file. Log files have no filegroup, so it's NULL.
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
   1a. Storage size in practice: DATALENGTH
   -----------------------------------------------------------------------------
   For a VECTOR(768):

       8-byte header + 768 dimensions × 4 bytes = 3,080 bytes

   To get the dimension count from the bytes, subtract the header:
       (DATALENGTH(col) - 8) / 4  → 768

   The JSON text you see on SELECT writes each float in scientific notation
   (4.3272693e-002), about 12,000 characters, or ~24,000 bytes as NVARCHAR:
   nearly 8× the binary size, with no type enforcement.

   sys.columns.vector_dimensions (optional Appendix C) is cleaner than the
   DATALENGTH math, and correct for float32 and float16.
----------------------------------------------------------------------------- */

SELECT TOP (1)
    qe.PostId,
    DATALENGTH(qe.embeddings)                        AS vector_bytes,       -- 3080 (8-byte header + 768×4)
   (DATALENGTH(qe.embeddings) - 8) / 4               AS dimension_count,    -- 768
    DATALENGTH(CAST(qe.embeddings AS NVARCHAR(MAX))) AS json_text_bytes     -- much larger
FROM dbo.QuestionEmbeddings qe;
GO



/* -----------------------------------------------------------------------------
   1a-2. Down to the page: where does the vector actually live?
   -----------------------------------------------------------------------------
   A 3,080-byte vector fits in a page's ~8,060 bytes of row data, so it stays
   IN_ROW. A row over 8,060 bytes would push its widest variable-length column
   to ROW_OVERFLOW_DATA; ours would need ~4,900 bytes of chunk text first.
     https://learn.microsoft.com/en-us/sql/relational-databases/pages-and-extents-architecture-guide

   About 1.5 rows fit per page, and exact kNN reads every page. That's the
   number in STATISTICS IO in §4.
----------------------------------------------------------------------------- */

-- Filegroup, allocation units, pages, and rows per page.
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
   DBCC PAGE (undocumented: look, never use in production code) shows a row's
   bytes as they sit on disk. Decode them by hand and compare to SELECT.

     17 bytes   record overhead: status, fixed-length size, PostId (4 bytes),
                column count, null bitmap, variable-column count, and the
                end offset of each variable-length column
      8 bytes   the VECTOR header
   3072 bytes   768 floats, 4 bytes each (the rest of the row is the chunk text)

   Each float is IEEE 754, little-endian: 1 sign, 8 exponent, 23 mantissa bits.
     value = (-1)^sign × (1 + mantissa / 2^23) × 2^(exponent - 127)
----------------------------------------------------------------------------- */
-- Print the page holding the first row to the Messages tab.
DECLARE @file INT, @page INT;
SELECT TOP (1) @file = plc.file_id, @page = plc.page_id
FROM dbo.QuestionEmbeddings qe
CROSS APPLY sys.fn_PhysLocCracker(%%physloc%%) AS plc
ORDER BY qe.PostId;

DBCC TRACEON(3604);                 -- send DBCC output to this session's Messages tab
DBCC PAGE('StackOverflow', @file, @page, 3);
DBCC TRACEOFF(3604);
GO

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
-- The vector is 768 raw float32s in the row; SQL Server turns them into the
-- JSON you see on SELECT. For the full hex dump (~1,400 lines), run
-- DBCC TRACEON(3604), then DBCC PAGE('StackOverflow', <file>, <page>, 3).


/* -----------------------------------------------------------------------------
   1b. Binary storage: client representation vs internal format
   -----------------------------------------------------------------------------
   VECTOR is stored as compact binary (header + payload), but CAST won't give
   you those bytes:

       CAST(col AS VARBINARY(MAX))  →  Msg 529, conversion not allowed.

   Clients see a JSON array ([1.0, -0.5, 0.123, ...]) as NVARCHAR/VARCHAR or
   JSON. SQL Server converts on the way in and out, and the round trip
   NVARCHAR → VECTOR → NVARCHAR is lossless.
----------------------------------------------------------------------------- */

-- Raw vector as stored internally (compact binary, 8-byte header + payload)
SELECT TOP (1)
    qe.embeddings as raw_vector
FROM dbo.QuestionEmbeddings qe;
GO

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
   1c. Half precision: VECTOR(n, float16)
   -----------------------------------------------------------------------------
       VECTOR( <dimensions> [, <base_type>] )     base_type: float32 | float16

   float16 stores 2 bytes per element instead of 4:
     - Half the payload: 768 dims is 1,544 bytes against 3,080, so ~1.5 GB per
       million embeddings instead of ~3 GB.
     - Double the ceiling: 3,996 dimensions instead of 1,998, so 3,072-dim
       models like text-embedding-3-large fit.
     - Less precision: ±65,504 range, about three significant digits.
       Unit-length embeddings sit in [-1, +1], and real distances move by
       ~0.00001 (optional Appendix A measures it).

   float16 is PREVIEW, so it needs PREVIEW_FEATURES (init.sql turned it on).
   The docs say it isn't supported on Arm64; it works here because the
   container runs linux/amd64 under Rosetta.
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

-- The limit that bites first: you can't mix base types. Caught so you can
-- read the message.
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
   2a. What AI_GENERATE_EMBEDDINGS does at execution time
   -----------------------------------------------------------------------------
   Each call serializes the text as JSON, POSTs it over HTTPS to the EXTERNAL
   MODEL's LOCATION, pulls the float array out of the response, and returns a
   VECTOR. Most of the latency is the model host (Ollama), not SQL Server.
----------------------------------------------------------------------------- */

-- Single embedding latency:
SET STATISTICS TIME ON;
GO
SELECT AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit' USE MODEL ollama)
    AS embedding;
GO
SET STATISTICS TIME OFF;
GO

-- About 15 ms per row here, one call per row, no batching: a 1,000,000-row
-- load takes about 4 hours. Plan it like any bulk load.


/* =============================================================================
   SECTION 3: DISTANCE METRICS, COSINE, EUCLIDEAN, DOT PRODUCT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   VECTOR_DISTANCE(metric, v1, v2) returns a distance; lower is closer.
   Metrics: 'cosine', 'euclidean', 'dot'.

     - Cosine compares direction, so short and long passages on the same topic
       come out equally close. Use it for text unless you have a reason not to.
     - Euclidean cares about length. Skip it for text unless you normalize.
     - Dot matches cosine on unit-length vectors (most models produce them)
       and is a bit cheaper.

   On real text, cosine runs from ~0.1 (very similar) to ~0.7 (unrelated);
   below ~0.3 is usually a strong match.

   The formulas and VECTOR_NORM are in demos/01-vector-internals-optional.sql,
   Appendix B.
----------------------------------------------------------------------------- */

/* -----------------------------------------------------------------------------
   3a. The same function on real text
   -----------------------------------------------------------------------------
   768 numbers per vector, picked by the model so that similar meanings point
   the same way. One question against two sentences:

     - the question:    how do I undo my last git commit?
     - a strong match:  git revert last commit without losing changes
     - a weak match:    what type of cheeses should I use on a quattro formaggi pizza

   Near 0.1 is a strong match; past 0.5 is noise. Thresholds vary by model
   but are consistent within one.
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
--   1. The strong match is near 0.1 and the weak match is past 0.5: the same
--      0 to 1 scale as the 3-D example on the slide.
--   2. dot_distance is cosine_distance minus 1. The vectors are unit-length,
--      so the dot product IS the cosine similarity. The math, and a check
--      that every stored vector is unit-length, are in optional Appendix B.


/* =============================================================================
   SECTION 4: QUERY EXECUTION, EXACT kNN (THE TABLE SCAN PATH)
   ============================================================================= */

/* -----------------------------------------------------------------------------
   4a. The exact kNN query, and what SQL Server does to answer it
   -----------------------------------------------------------------------------
   Without a vector index, finding the K nearest neighbors means:

     1. Embed the query text                     (one HTTP call to Ollama)
     2. Scan EVERY row in QuestionEmbeddings     (O(n) reads)
     3. Compute VECTOR_DISTANCE for every row    (O(n) float arithmetic)
     4. Keep the K smallest distances            (Top N Sort, O(n log K))

   Exact results, perfect recall. Fine for tens of thousands of rows, not for
   millions.

   Rank inside the satellite table first, then join the 10 winners to Posts.
   Join first and the optimizer can join every row before the sort: about
   41,500 reads on Posts at ~10,000 rows, against 40 for rank-then-join.

   Check the logical reads in the Messages tab: that's a full scan of the
   embeddings table.
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
--   "elapsed time" grows linearly with row count. Demo 02 §2b and optional
--   Appendix F measure it.

-- On a cold cache the same scan reads ~7,000 pages from disk and runs 3 to 10
-- times slower, so the EMBEDDINGS filegroup's storage matters.


/* -----------------------------------------------------------------------------
   4b. The execution plan for exact kNN
   -----------------------------------------------------------------------------
   Turn on the actual plan (Ctrl+M in SSMS) and re-run 4a. On this box:

     [Clustered Index Scan]  →  [Compute Scalar]  →  [Sort (Top N)]
        →  [Gather Streams]  →  [Top]  →  [Nested Loops to Posts]  →  [SELECT]

   Read it right to left:

     Clustered Index Scan
       Every row (10,300 here), no predicate: you have to read the vector to
       know the distance. That's the cost of exact kNN.

     Compute Scalar
       Defined Values shows vector_distance(N'cosine', @query_vector,
       embeddings), once per row: 768 multiplications each.

     Sort (Top N), then Gather Streams, then Top
       Parallel (DOP 12 here). Each thread keeps its own 10, so the Sort emits
       120 rows; Gather Streams merges them and Top picks 10. The memory grant
       is tiny (~3 MB) because it holds 10 rows per thread.

     Nested Loops + Clustered Index Seek on Posts
       10 seeks for the 10 winners (estimated 1 per seek, actual 10 total).

   Estimates are right (10,300 estimated and actual), so the cost is the scan
   and the math, not a bad plan. Parallelism flatters elapsed time; CPU time
   keeps growing with every row (Demo 2 §2b).

   The DiskANN index (Demo 2) replaces the Scan + Compute Scalar with a graph
   walk, and Demo 2 measures when that pays off.
----------------------------------------------------------------------------- */
