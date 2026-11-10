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
    Describe vector internals: storage, indexing, query execution. This demo
    is storage and exact search; indexing is Demo 2.

  Prerequisites:
    Stack up (./start.sh). setup/init.sql embedded 1,000 rows; run
    setup/expand-embeddings.sh to reach 10,000 (Demo 02's numbers assume it).

  Connect:
    Server:   localhost,1435
    Login:    sa
    Password: S0methingS@Str0ng!   (demo only)

  Run top to bottom; all idempotent.
  Deep dives: demos/01-vector-internals-optional.sql.
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
   (StackOverflow_Embeddings.ndf), apart from data (.mdf) and log (.ldf).
   Vectors are big, read in bulk (scans, builds) or at random (graph walks):
   size, back up, and place them separately.

   Loads are heavily logged: ~3,600 bytes per row, ~3.6 GB per 1,000,000
   rows. Size the log for loads and rebuilds.
----------------------------------------------------------------------------- */

-- Log files: NULL filegroup.
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
   VECTOR(768): 8-byte header + 768 dimensions × 4 bytes = 3,080 bytes

   Dimensions: (DATALENGTH(col) - 8) / 4  → 768

   SELECT shows JSON text, floats in scientific notation (4.3272693e-002):
   ~12,000 characters, ~24,000 bytes as NVARCHAR, ~8× binary, untyped.

   sys.columns.vector_dimensions (optional Appendix C) beats DATALENGTH math
   and is right for float32 and float16.
----------------------------------------------------------------------------- */

SELECT TOP (1)
    qe.PostId,
    DATALENGTH(qe.embeddings)                        AS vector_bytes,       -- 3080
   (DATALENGTH(qe.embeddings) - 8) / 4               AS dimension_count,    -- 768
    DATALENGTH(CAST(qe.embeddings AS NVARCHAR(MAX))) AS json_text_bytes
FROM dbo.QuestionEmbeddings qe;
GO



/* -----------------------------------------------------------------------------
   1a-2. Down to the page: where does the vector actually live?
   -----------------------------------------------------------------------------
   3,080 bytes fits in a page's ~8,060 bytes of row data: IN_ROW. A row over
   8,060 pushes its widest variable-length column to ROW_OVERFLOW_DATA (ours
   needs ~4,900 bytes of chunk text first).
     https://learn.microsoft.com/en-us/sql/relational-databases/pages-and-extents-architecture-guide

   ~1.5 rows per page; exact kNN reads every page (STATISTICS IO, Section 4).
----------------------------------------------------------------------------- */

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
   DBCC PAGE (undocumented: never in production code) shows a row's on-disk
   bytes. Decode, compare to SELECT.

     17 bytes   record overhead: status, fixed-length size, PostId (4 bytes),
                column count, null bitmap, variable-column count, end offset
                of each variable-length column
      8 bytes   the VECTOR header
   3072 bytes   768 floats, 4 bytes each (rest of the row is chunk text)

   Floats are IEEE 754 little-endian: 1 sign, 8 exponent, 23 mantissa bits.
     value = (-1)^sign × (1 + mantissa / 2^23) × 2^(exponent - 127)
----------------------------------------------------------------------------- */
DECLARE @file INT, @page INT;
SELECT TOP (1) @file = plc.file_id, @page = plc.page_id
FROM dbo.QuestionEmbeddings qe
CROSS APPLY sys.fn_PhysLocCracker(%%physloc%%) AS plc
ORDER BY qe.PostId;

DBCC TRACEON(3604);                 -- DBCC output to Messages tab
DBCC PAGE('StackOverflow', @file, @page, 3);
DBCC TRACEOFF(3604);
GO

DECLARE @pid INT, @file INT, @page INT, @slot INT;
SELECT TOP (1) @pid = qe.PostId, @file = plc.file_id, @page = plc.page_id, @slot = plc.slot_id
FROM dbo.QuestionEmbeddings qe
CROSS APPLY sys.fn_PhysLocCracker(%%physloc%%) AS plc
ORDER BY qe.PostId;

-- Page as rows, hex dump stitched into bytes.
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

-- Reverse the 4 bytes, split the bits, apply the formula.
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

-- All 768 elements, bytes on the left, numbers on the right:
SELECT * FROM #floats ORDER BY element;

-- "Match" means to the 8 digits SELECT prints.
SELECT COUNT(*) AS floats_on_page,
       SUM(CASE WHEN ABS(decoded_from_bytes - CAST(select_shows AS FLOAT)) < 1E-7 THEN 1 ELSE 0 END)
                AS match_what_select_prints
FROM #floats;

DROP TABLE #floats;
DROP TABLE #pg;
GO
-- The row holds 768 raw float32s; SQL Server turns them into the JSON SELECT
-- shows. Full dump (~1,400 lines): DBCC TRACEON(3604), then DBCC PAGE(
-- 'StackOverflow', <file>, <page>, 3).


/* -----------------------------------------------------------------------------
   1b. Binary storage: client representation vs internal format
   -----------------------------------------------------------------------------
   VECTOR is stored as compact binary (header + payload), but
   CAST(col AS VARBINARY(MAX)) gives Msg 529, conversion not allowed.
   Clients see a JSON array ([1.0, -0.5, 0.123, ...]) as NVARCHAR/VARCHAR or
   JSON.
----------------------------------------------------------------------------- */

-- Raw vector
SELECT TOP (1)
    qe.embeddings as raw_vector
FROM dbo.QuestionEmbeddings qe;
GO


/* -----------------------------------------------------------------------------
   1c. Half precision: VECTOR(n, float16)
   -----------------------------------------------------------------------------
       VECTOR( <dimensions> [, <base_type>] )     base_type: float32 | float16

   float16 is 2 bytes per element, not 4:
     - Half the payload: 768 dims is 1,544 bytes against 3,080 (~1.5 GB per
       million embeddings, not ~3 GB).
     - Double the ceiling: 3,996 dimensions, not 1,998, so 3,072-dim models
       like text-embedding-3-large fit.
     - Less precision: ±65,504 range, ~3 significant digits. Unit-length
       embeddings sit in [-1, +1]; real distances move ~0.00001 (optional
       Appendix A).

   float16 is PREVIEW; needs PREVIEW_FEATURES (init.sql set it). Docs say
   Arm64 isn't supported; works here (container is linux/amd64 under Rosetta).
     https://learn.microsoft.com/en-us/sql/t-sql/data-types/vector-data-type-half-precision-float
----------------------------------------------------------------------------- */

-- Same 768 values, two types, same header:
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

-- No mixing base types:
DECLARE @v32 VECTOR(3)          = '[1.0, 0.0, 0.0]';
DECLARE @v16 VECTOR(3, float16) = '[1.0, 0.0, 0.0]';
SELECT VECTOR_DISTANCE('cosine', @v32, @v16);


-- WHEN TO USE IT
--   float16: millions of embeddings where storage matters, unit-length
--            output, or more than 1,998 dimensions.
--   float32: exact fidelity, or drivers older than ODBC 18.7.1 / JDBC 13.4
--            (can't send float16 in binary).
-- Precision on real text, the out-of-range error, and catalog metadata:
-- demos/01-vector-internals-optional.sql, Appendix A.


/* =============================================================================
   SECTION 2: AI_GENERATE_EMBEDDINGS, WHAT HAPPENS AT EXECUTION TIME
   ============================================================================= */

/* -----------------------------------------------------------------------------
   2a. What AI_GENERATE_EMBEDDINGS does at execution time
   -----------------------------------------------------------------------------
   Each call POSTs the text as JSON over HTTPS to the EXTERNAL MODEL's
   LOCATION, returning the float array as a VECTOR. Most latency is the
   model host (Ollama).
----------------------------------------------------------------------------- */

SET STATISTICS TIME ON;
GO
SELECT AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit' USE MODEL ollama)
    AS embedding;
GO
SET STATISTICS TIME OFF;
GO

-- ~15 ms per row, one call each, no batching: 1,000,000 rows take ~4 hours.
-- Plan it like a bulk load.


/* =============================================================================
   SECTION 3: DISTANCE METRICS, COSINE, EUCLIDEAN, DOT PRODUCT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   VECTOR_DISTANCE(metric, v1, v2): lower is closer.
   Metrics: 'cosine', 'euclidean', 'dot'.

     - Cosine compares direction, so short and long passages on one topic
       are equally close. Default for text.
     - Euclidean cares about length; skip for text unless normalized.
     - Dot matches cosine on unit-length vectors (most models), a bit cheaper.

   Real text: cosine ~0.1 (very similar) to ~0.7 (unrelated); below ~0.3 is
   usually a strong match.

   Formulas and VECTOR_NORM: demos/01-vector-internals-optional.sql, Appendix B.
----------------------------------------------------------------------------- */

/* -----------------------------------------------------------------------------
   3a. The same function on real text
   -----------------------------------------------------------------------------
   One question, two sentences:

     - the question:    how do I undo my last git commit?
     - a strong match:  git revert last commit without losing changes
     - a weak match:    what type of cheeses should I use on a quattro formaggi pizza

   Near 0.1 strong; past 0.5 noise. Thresholds vary by model, stable within one.
----------------------------------------------------------------------------- */

DECLARE @question     VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo my last git commit?' USE MODEL ollama);

DECLARE @strong_match VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'git revert last commit without losing changes' USE MODEL ollama);

DECLARE @weak_match   VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'what type of cheeses should I use on a quattro formaggi pizza' USE MODEL ollama);

SELECT
    pair,
    VECTOR_DISTANCE('cosine',    a, b) AS cosine_distance
FROM (VALUES
    ('question vs strong match', @question, @strong_match),
    ('question vs weak match',   @question, @weak_match)
) AS t(pair, a, b);
GO
-- Same 0 to 1 scale as the slide's 3-D example. Euclidean, dot, math, and a
-- unit-length check: optional Appendix B.


/* =============================================================================
   SECTION 4: QUERY EXECUTION, EXACT kNN (THE TABLE SCAN PATH)
   ============================================================================= */

/* -----------------------------------------------------------------------------
   4a. The exact kNN query, and what SQL Server does to answer it
   -----------------------------------------------------------------------------
   Without a vector index:

     1. Embed the query text                     (one HTTP call to Ollama)
     2. Scan EVERY row                           (O(n) reads)
     3. VECTOR_DISTANCE for every row            (O(n) float arithmetic)
     4. Keep the K smallest                      (Top N Sort, O(n log K))

   Exact, perfect recall; fine for tens of thousands of rows, not millions.

   Rank in the satellite table, then join the 10 winners to Posts. Join first
   and the optimizer can join every row before the sort: ~41,500 Posts reads
   at ~10,000 rows, against 40.
----------------------------------------------------------------------------- */

SELECT TOP (10) * FROM dbo.QuestionEmbeddings qe;


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

-- "logical reads" on QuestionEmbeddings = every data page; Posts is tiny
-- (10 key lookups). "elapsed time" grows linearly (Demo 02 - 2b, optional
-- Appendix F).

-- Cold cache: ~7,000 pages from disk, 3 to 10 times slower.


/* -----------------------------------------------------------------------------
   4b. The execution plan for exact kNN
   -----------------------------------------------------------------------------
   Actual plan on (Ctrl+M in SSMS), re-run 4a:

     [Clustered Index Scan]  →  [Compute Scalar]  →  [Sort (Top N)]
        →  [Gather Streams]  →  [Top]  →  [Nested Loops to Posts]  →  [SELECT]

   Right to left:
     Clustered Index Scan
       Every row (~10,000), no predicate: each vector must be read. That's
       exact kNN's cost.

     Compute Scalar
       Defined Values: vector_distance(N'cosine', @query_vector, embeddings)
       per row, 768 multiplications.

     Sort (Top N), Gather Streams, Top
       Parallel (DOP 12). Each thread keeps 10: Sort emits 120 rows, Gather
       Streams merges, Top picks 10. Memory grant ~3 MB.

     Nested Loops + Clustered Index Seek on Posts
       10 seeks for the 10 winners (estimated 1 per seek, actual 10 total).

   Estimates are right: the cost is scan and math, not the plan. Parallelism
   flatters elapsed time; CPU grows per row (Demo 2 - 2b).

   DiskANN (Demo 2) replaces Scan + Compute Scalar with a graph walk; Demo 2
   measures the payoff.
----------------------------------------------------------------------------- */
