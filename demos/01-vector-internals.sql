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
    query execution.

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
    (DATALENGTH(qe.embeddings) - 8) / 4              AS dimension_count,    -- 768
    DATALENGTH(CAST(qe.embeddings AS NVARCHAR(MAX))) AS json_text_bytes     -- much larger
FROM dbo.QuestionEmbeddings qe;
GO

-- Quick sanity check: are all the stored vectors the same dimension?
-- If they're not, you've got a pipeline bug or a model swap mid-flight.
SELECT
    (DATALENGTH(embeddings) - 8) / 4  AS dimension_count,
    COUNT(*)                          AS row_count
FROM dbo.QuestionEmbeddings
GROUP BY DATALENGTH(embeddings);
GO


/* -----------------------------------------------------------------------------
   1b-2. Page-level storage: where does the vector actually live?
   -----------------------------------------------------------------------------
   A VECTOR(768) is 3,080 bytes. A data page holds about 8,060 bytes of row
   data. So does the vector stay in the row, or get pushed to another page?

   The documented rule (Pages and Extents Architecture Guide): when a row
   exceeds 8,060 bytes, the engine moves variable-length columns to
   ROW_OVERFLOW_DATA pages, starting with the widest column.
     https://learn.microsoft.com/en-us/sql/relational-databases/pages-and-extents-architecture-guide

   The VECTOR docs say nothing about row overflow, so let's measure it. Our
   rows are PostId (4) + vector (3,080) + chunk (a title and tags, a few
   hundred bytes). That's well under 8,060, so the vector stays IN_ROW. Two
   rows could fit on a page. You'll see closer to 1.5 rows per page because
   we inserted in Score order, not PostId order, and page splits left pages
   partly empty. A vector would only overflow if chunk grew past ~4,900 bytes.

   Why care? Every exact kNN scan reads every page. At ~1.5 rows per page, a
   full scan of 10,000 rows reads ~6,700 pages. That's the number you'll see
   in STATISTICS IO in §4 and in Demo 02.
----------------------------------------------------------------------------- */

-- Which allocation units hold the table's data? ROW_OVERFLOW_DATA stays absent.
SELECT
    au.type_desc            AS allocation_unit,
    au.total_pages,
    au.data_pages,
    p.rows,
    CAST(p.rows * 1.0 / NULLIF(au.data_pages, 0) AS DECIMAL(5,2)) AS rows_per_page
FROM sys.partitions       p
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
WHERE p.object_id = OBJECT_ID('dbo.QuestionEmbeddings')
  AND p.index_id  = 1;
GO

-- DBCC PAGE is undocumented. Use it to look, never in production code.
-- fn_PhysLocCracker gives the file, page, and slot for a row.
DECLARE @file INT, @page INT, @sql NVARCHAR(200);
SELECT TOP (1) @file = plc.file_id, @page = plc.page_id
FROM dbo.QuestionEmbeddings qe
CROSS APPLY sys.fn_PhysLocCracker(%%physloc%%) AS plc;

SET @sql = CONCAT(N'DBCC PAGE(''StackOverflow'', ', @file, N', ', @page, N', 3);');
DBCC TRACEON(3604);   -- send DBCC output to the Messages tab
EXEC (@sql);
DBCC TRACEOFF(3604);
GO
-- In the Messages tab, look for m_slotCnt in the page header (1 or 2) and the
-- slots, each carrying a ~3 KB vector inline.


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

-- 10 rows batched. Compare the elapsed time to the single call above:
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
   SECTION 3: DISTANCE METRICS, COSINE, EUCLIDEAN, DOT PRODUCT
   ============================================================================= */

/* -----------------------------------------------------------------------------
   VECTOR_DISTANCE(metric, v1, v2) returns a scalar distance. Lower = closer.
   SQL Server 2025 supports three metrics:

     'cosine'    1 - (v1 · v2) / (|v1| × |v2|)   angle-based, ignores magnitude
     'euclidean' √ Σ(v1ᵢ - v2ᵢ)²                 straight-line distance in n-space
     'dot'       -(v1 · v2)                      inner product, negated

   For text embeddings:
     - Cosine is the standard choice. A short and a long passage on the same
       topic come out equally close, because magnitude doesn't matter.
     - Euclidean cares about vector length. Skip it for text unless you
       normalize the vectors first.
     - Dot product matches cosine when vectors are unit-normalized (most
       embedding models produce those). It's a bit cheaper to compute.

   On real text embeddings, cosine distance runs roughly 0.1 (very similar)
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
--   'norm1'   : L1 norm: sum of absolute values          e.g. |3|+|4|+|0| = 7.0
--   'norm2'   : L2 Euclidean norm: √(Σ xᵢ²)              e.g. √(9+16+0)   = 5.0
--   'norminf' : Infinity norm: max of absolute values    e.g. max(3,4,0)  = 4.0
-- For unit-normalized embeddings, norm2 should come out very close to 1.0.
DECLARE @v VECTOR(3) = '[3.0, 4.0, 0.0]';
SELECT
    VECTOR_NORM(@v, 'norm1')   AS l1_norm,    -- 7.0
    VECTOR_NORM(@v, 'norm2')   AS l2_norm,    -- 5.0
    VECTOR_NORM(@v, 'norminf') AS inf_norm;   -- 4.0
GO

-- Are our stored embeddings unit-normalized? They should be.
-- Most embedding models, nomic-embed-text included, produce unit vectors.
SELECT
    MIN(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS min_norm,
    MAX(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS max_norm,
    AVG(CAST(VECTOR_NORM(embeddings, 'norm2') AS FLOAT))  AS avg_norm
FROM dbo.QuestionEmbeddings;
GO


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
   row to Posts before the sort. On 10,100 rows that cost 41,099 reads on
   Posts, against 40 for rank-then-join. The CTE below keeps the join to
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


/* -----------------------------------------------------------------------------
   4b. The execution plan for exact kNN
   -----------------------------------------------------------------------------
   Turn on INCLUDE ACTUAL EXECUTION PLAN in SSMS (Ctrl+M) and re-run the
   query above. You'll see this operator chain:

     [Clustered Index Scan]  →  [Compute Scalar]  →  [Top N Sort]
        →  [Nested Loops to Posts, 10 rows]  →  [SELECT]

   On a multi-core box you may also see Parallelism operators around the
   scan.

   Let's walk through it operator by operator:

     Clustered Index Scan
       Reads every row from QuestionEmbeddings. No predicate can filter rows
       before the distance is computed. You have to read the vector to know
       the distance. That's the fundamental cost of exact kNN.

     Compute Scalar
       Calls VECTOR_DISTANCE(cosine, @query_vector, qe.embeddings) for each row.
       That's float arithmetic over 768 values per row.

     Top N Sort
       Keeps only the K closest candidates seen so far. It holds K rows in
       memory, but it has to read ALL n rows before it knows it has the
       right K.

     Nested Loops + Clustered Index Seek on Posts
       Fetches titles for the 10 winners.

   The DiskANN index (Demo 2) replaces the Scan + Compute Scalar with a
   graph walk. Demo 2 measures when that pays off and when it doesn't.
----------------------------------------------------------------------------- */

-- Capture the plan as XML so you can dig into it later:
SET STATISTICS XML ON;
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
SELECT p.Id, p.Title, n.distance
FROM nearest n
JOIN dbo.Posts p ON p.Id = n.PostId
ORDER BY n.distance;
GO
SET STATISTICS XML OFF;
GO
