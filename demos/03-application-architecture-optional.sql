SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
=============================================================================
  SQL Server 2025 Vectors: Under the Hood and Into Production
  Demo 03: Optional deep dives

  Run after demos/03-application-architecture.sql. The appendices follow the
  core script's order:
    A. Chunking long text with AI_GENERATE_CHUNKS   (after §1b)
    B. get_top_answer                               (after §2a)
    C. rag_app's permissions, and two more checks   (with Section 3)
    D. Model swap: a new embedding model            (after §4a; needs
                                                     mxbai-embed-large)
    E. The full call sequence                       (behind Section 5)
    F. More pipeline checks                         (with §4b)
=============================================================================
*/

USE [StackOverflow];
GO


/* =============================================================================
   APPENDIX A. CHUNKING LONG TEXT WITH AI_GENERATE_CHUNKS
   ============================================================================= */

/* -----------------------------------------------------------------------------
   A. Chunking long text with AI_GENERATE_CHUNKS
   -----------------------------------------------------------------------------
   Chunk the accepted answers to a few top questions into 500-character
   pieces with 10% overlap (so a sentence on a boundary lands in both), then
   embed each piece.

     - ChunkId is a surrogate INT key: (AnswerId, chunk_order) is the natural
       key, but a vector index needs a single INT clustered primary key.
     - AI_GENERATE_CHUNKS needs compatibility level 170 (init.sql sets it).

   Docs: https://learn.microsoft.com/en-us/sql/t-sql/functions/ai-generate-chunks-transact-sql
----------------------------------------------------------------------------- */

DROP TABLE IF EXISTS dbo.AnswerChunks;
CREATE TABLE dbo.AnswerChunks
(
    ChunkId     INT IDENTITY(1,1) NOT NULL,
    AnswerId    INT               NOT NULL,
    chunk_order BIGINT            NOT NULL,
    chunk       NVARCHAR(MAX)     NOT NULL,
    embeddings  VECTOR(768)       NOT NULL,
    CONSTRAINT PK_AnswerChunks PRIMARY KEY CLUSTERED (ChunkId)
) ON [EMBEDDINGS];
GO

-- Here's what the chunker produces for one answer:
SELECT TOP (1) a.Id AS answer_id, c.chunk_order, c.chunk_offset, c.chunk_length, c.chunk
FROM dbo.Posts q
JOIN dbo.Posts a ON a.Id = q.AcceptedAnswerId
CROSS APPLY AI_GENERATE_CHUNKS(SOURCE = a.Body, CHUNK_TYPE = FIXED,
                               CHUNK_SIZE = 500, OVERLAP = 10) AS c
WHERE q.Id = (SELECT TOP (1) PostId FROM dbo.QuestionEmbeddings ORDER BY PostId)
ORDER BY c.chunk_order;
GO

-- Chunk and embed the accepted answers for 5 top questions in one statement:
INSERT INTO dbo.AnswerChunks (AnswerId, chunk_order, chunk, embeddings)
SELECT a.Id, c.chunk_order, c.chunk,
       AI_GENERATE_EMBEDDINGS(c.chunk USE MODEL ollama)
FROM (SELECT TOP (5) q.AcceptedAnswerId
      FROM dbo.Posts q
      JOIN dbo.QuestionEmbeddings qe ON qe.PostId = q.Id
      WHERE q.AcceptedAnswerId IS NOT NULL
      ORDER BY q.Score DESC) AS top_q
JOIN dbo.Posts a ON a.Id = top_q.AcceptedAnswerId
CROSS APPLY AI_GENERATE_CHUNKS(SOURCE = a.Body, CHUNK_TYPE = FIXED,
                               CHUNK_SIZE = 500, OVERLAP = 10) AS c;
GO

SELECT AnswerId, COUNT(*) AS chunks, SUM(LEN(chunk)) AS total_chars
FROM dbo.AnswerChunks
GROUP BY AnswerId;
GO

SELECT
    AnswerId,
    chunk_order,
    chunk
FROM dbo.AnswerChunks
ORDER BY AnswerId, chunk_order;
GO
-- In production, strip the HTML before chunking. The model embeds the tags too.

-- Search the passages, not the questions. A few dozen chunks means exact
-- search is the right tool (no index needed).
DECLARE @qv VECTOR(768) = AI_GENERATE_EMBEDDINGS(
    N'how do I undo a commit but keep my changes?' USE MODEL ollama);

SELECT TOP (3)
    c.AnswerId,
    c.chunk_order,
    VECTOR_DISTANCE('cosine', @qv, c.embeddings) AS distance,
    LEFT(c.chunk, 200)                           AS passage
FROM dbo.AnswerChunks c
ORDER BY distance;
GO
-- The winner is a passage from the git answer, not the whole answer: the LLM
-- gets the paragraph that answers the question, not 3,000 characters around
-- it. The repo's app still sends titles plus a trimmed answer; searching
-- chunks is the next step up.


/* =============================================================================
   APPENDIX B. get_top_answer: FETCH THE BEST ANSWER FOR A GIVEN QUESTION
   ============================================================================= */

/* -----------------------------------------------------------------------------
   B. get_top_answer: fetch the best answer for a given question
   -----------------------------------------------------------------------------
   After find_similar_questions, the app calls this once per result for
   answer text to use as context: the accepted answer if there is one,
   otherwise the highest-scored.
----------------------------------------------------------------------------- */

CREATE OR ALTER PROCEDURE dbo.get_top_answer
    @question_post_id INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1)
        a.Id            AS answer_id,
        a.Body          AS answer_body,     -- HTML; Python app strips tags
        a.Score         AS answer_score,
        a.CreationDate  AS answer_date
    FROM dbo.Posts a
    WHERE a.PostTypeId = 2                              -- answers only
      AND a.ParentId   = @question_post_id              -- for this question
    ORDER BY
        -- Accepted answer first (AcceptedAnswerId is on the parent question):
        CASE WHEN a.Id = (
            SELECT AcceptedAnswerId FROM dbo.Posts WHERE Id = @question_post_id
        ) THEN 0 ELSE 1 END,
        a.Score DESC;   -- then highest voted
END;
GO

-- The best answer for the top-scored embedded question (the app does this in
-- a loop over the search results):
DECLARE @q_id INT = (
    SELECT TOP (1) p.Id
    FROM dbo.Posts p
    JOIN dbo.QuestionEmbeddings qe ON qe.PostId = p.Id
    ORDER BY p.Score DESC
);
SELECT Id, Title, Score FROM dbo.Posts WHERE Id = @q_id;
EXEC dbo.get_top_answer @question_post_id = @q_id;
GO


/* =============================================================================
   APPENDIX C. rag_app'S PERMISSIONS, AND TWO MORE CHECKS
   ============================================================================= */

-- Run Demo 3 Section 3 first, so rag_app exists with its grants.

-- The complete permission set for rag_app: EXECUTE on two procs and the model,
-- VIEW DEFINITION on one table, and no SELECT anywhere.
SELECT
    dp.class_desc                           AS object_class,
    COALESCE(
        OBJECT_NAME(dp.major_id),
        em.name,
        CAST(dp.major_id AS NVARCHAR(20))
    )                                       AS object_name,
    dp.permission_name,
    dp.state_desc                           AS grant_state
FROM sys.database_permissions   dp
JOIN sys.database_principals     u  ON u.principal_id = dp.grantee_principal_id
LEFT JOIN sys.external_models    em ON em.external_model_id = dp.major_id
WHERE u.name = N'rag_app'
ORDER BY dp.class_desc, object_name;
GO

-- EXECUTE on the model makes its sys.external_models row visible to rag_app,
-- endpoint URL included. Keep secrets in a database scoped credential, never
-- in LOCATION.

-- C-1. The vector column is off limits too:
EXECUTE AS USER = 'rag_app';
BEGIN TRY
    SELECT TOP (1) embeddings FROM dbo.QuestionEmbeddings;
END TRY
BEGIN CATCH
    PRINT CONCAT('Msg ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;
REVERT;
GO


-- C-2. The proc source is hidden from the app:
EXECUTE AS USER = 'rag_app';
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.find_similar_questions')) AS proc_source;   -- NULL
REVERT;
GO


/* =============================================================================
   APPENDIX D. MODEL SWAP: A NEW EMBEDDING MODEL, SIDE BY SIDE
   ============================================================================= */

/* -----------------------------------------------------------------------------
   D. Model swap: a new embedding model, side by side
   -----------------------------------------------------------------------------
   Queries name the model, not the endpoint. But changing models is more than
   a rename: vectors from two models aren't comparable, and the dimension
   count usually changes (mxbai-embed-large is 1,024; our column is 768).

   The pattern that keeps the app online:

     1. Register the new model next to the old one
     2. Build a second satellite table with the new VECTOR(n)
     3. Backfill it and build its vector index
     4. CREATE OR ALTER the proc to point at the new table and model
     5. Drop the old table and model

   The app never changes; step 4 is a one-statement cutover.

   Build the index AFTER the backfill. The docs warn that after a near-
   complete replacement of the vectors, an old index still returns valid
   rows but recall can quietly degrade. Recreate it, then re-measure recall
   (Demo 02 §3).

   Prerequisite (run on the host, ~670 MB):
       ollama pull mxbai-embed-large

   Warm it up first; a cold model can exceed the REST timeout (Msg 31629):
       curl -s http://localhost:11434/api/embed \
            -d '{"model":"mxbai-embed-large","input":"warm up"}' > /dev/null

   The 1,000-row backfill below takes about two minutes on an M2.
----------------------------------------------------------------------------- */

-- The current model registration:
SELECT
    name,
    location,
    model,
    model_type_desc,
    api_format
FROM sys.external_models;
GO

/*
-- Step 1: register the second model on the same Ollama endpoint.
CREATE EXTERNAL MODEL ollama_mxbai
WITH (
    LOCATION   = 'https://model-web:443/api/embed',
    API_FORMAT = 'Ollama',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'mxbai-embed-large'
);
GO

-- The dimension count is a property of the model. Check it before you
-- design the column:
DECLARE @v NVARCHAR(MAX) =
    CAST(AI_GENERATE_EMBEDDINGS(N'dimension check' USE MODEL ollama_mxbai) AS NVARCHAR(MAX));
SELECT COUNT(*) AS dimensions FROM OPENJSON(@v);   -- 1024
GO

-- Steps 2-3: second satellite table, backfill, index.
CREATE TABLE dbo.QuestionEmbeddings_mxbai
(
    PostId     INT            NOT NULL,
    embeddings VECTOR(1024)   NOT NULL,
    chunk      NVARCHAR(4000) NOT NULL,
    CONSTRAINT PK_QuestionEmbeddings_mxbai PRIMARY KEY CLUSTERED (PostId)
) ON [EMBEDDINGS];
GO

INSERT INTO dbo.QuestionEmbeddings_mxbai (PostId, chunk, embeddings)
SELECT TOP (1000) qe.PostId, qe.chunk, AI_GENERATE_EMBEDDINGS(qe.chunk USE MODEL ollama_mxbai)
FROM dbo.QuestionEmbeddings qe
JOIN dbo.Posts p ON p.Id = qe.PostId
ORDER BY p.Score DESC;   -- the same top questions the 768-dim table started with
GO

CREATE VECTOR INDEX vec_idx_mxbai ON dbo.QuestionEmbeddings_mxbai([embeddings])
WITH (metric = 'cosine', type = 'diskann');
GO

-- Same question, both models. Distances aren't comparable across models;
-- compare which questions come back.
DECLARE @q768  VECTOR(768)  = AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit?' USE MODEL ollama);
DECLARE @q1024 VECTOR(1024) = AI_GENERATE_EMBEDDINGS(N'how do I undo my last git commit?' USE MODEL ollama_mxbai);

SELECT 'nomic 768' AS model, p.Title, s.distance
FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings AS t, COLUMN = [embeddings],
                   SIMILAR_TO = @q768, METRIC = 'cosine', TOP_N = 3) AS s
JOIN dbo.Posts p ON p.Id = t.PostId
UNION ALL
SELECT 'mxbai 1024', p.Title, s.distance
FROM VECTOR_SEARCH(TABLE = dbo.QuestionEmbeddings_mxbai AS t, COLUMN = [embeddings],
                   SIMILAR_TO = @q1024, METRIC = 'cosine', TOP_N = 3) AS s
JOIN dbo.Posts p ON p.Id = t.PostId;
GO

-- Step 4: CREATE OR ALTER dbo.find_similar_questions with VECTOR(1024),
-- USE MODEL ollama_mxbai, and TABLE = dbo.QuestionEmbeddings_mxbai.
-- GRANT EXECUTE ON EXTERNAL MODEL::ollama_mxbai TO rag_app; first, and
-- GRANT VIEW DEFINITION on the new table (see the core script, §2a).

-- Cleanup, so the demo can be re-run:
DROP TABLE IF EXISTS dbo.QuestionEmbeddings_mxbai;
DROP EXTERNAL MODEL ollama_mxbai;
GO
*/


/* =============================================================================
   APPENDIX E. THE FULL CALL SEQUENCE, AND WHAT THE APP GETS BACK
   ============================================================================= */

/* -----------------------------------------------------------------------------
   What happens when rag-app.py gets a question:

     APP                     SQL SERVER                        OLLAMA
      │                           │                               │
      │  EXEC find_similar_       │                               │
      │  questions @prompt=...    │                               │
      │ ────────────────────────► │                               │
      │                           │  AI_GENERATE_EMBEDDINGS(...)  │
      │                           │ ────────────────────────────► │
      │                           │ ◄──────── VECTOR(768) ─────── │
      │                           │                               │
      │                           │  VECTOR_SEARCH (DiskANN walk) │
      │                           │  or VECTOR_DISTANCE (kNN)     │
      │                           │  → top-K rows                 │
      │ ◄────── result set ────── │                               │
      │                           │                               │
      │  (for each result)        │                               │
      │  EXEC get_top_answer      │                               │
      │ ────────────────────────► │                               │
      │ ◄────── answer text ───── │                               │
      │                           │                               │
      │  Build RAG prompt         │                               │
      │  (question + context)     │                               │
      │                           │                               │
      │  POST /api/generate       │                               │
      │ ────────────────────────────────────────────────────────► │
      │ ◄──────────── LLM response ────────────────────────────── │
      │                           │                               │
      │  Display grounded answer  │                               │

   SQL Server embeds and retrieves; the app builds the prompt and calls the
   LLM.

   That's 1 + N round trips per question (6 for K = 5): a few ms locally.
   Over a WAN or under load, fold the answer lookup into the search proc
   (OUTER APPLY to the top answer) and make it one call.
----------------------------------------------------------------------------- */

-- What the app gets back for a few typical questions:
EXEC dbo.find_similar_questions
    @prompt = N'what is the difference between a list and a tuple in Python?',
    @top    = 3;
GO

EXEC dbo.find_similar_questions
    @prompt = N'how do I handle errors in async JavaScript?',
    @top    = 3;
GO

EXEC dbo.find_similar_questions
    @prompt = N'SQL query is running slow, how do I find out why?',
    @top    = 3;
GO


/* =============================================================================
   APPENDIX F. MORE PIPELINE CHECKS
   ============================================================================= */

-- The server-level switch that allows outbound REST calls (needed for
-- AI_GENERATE_EMBEDDINGS):
EXEC sp_configure 'external rest endpoint enabled';
GO

-- Coverage: embedded questions versus the backlog still to embed.
SELECT
    (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)                                AS embedded,
    (SELECT COUNT(*) FROM dbo.Posts WHERE PostTypeId = 1 AND Title IS NOT NULL)  AS embeddable,
    (SELECT COUNT(*) FROM dbo.Posts WHERE PostTypeId = 1 AND Title IS NOT NULL)
      - (SELECT COUNT(*) FROM dbo.QuestionEmbeddings)                            AS backlog;
GO

-- The coverage gap: top questions not embedded yet.
SELECT TOP (10)
    p.Id,
    p.Title,
    p.Score,
    CASE WHEN qe.PostId IS NOT NULL THEN 'embedded' ELSE 'pending' END AS status
FROM dbo.Posts p
LEFT JOIN dbo.QuestionEmbeddings qe ON qe.PostId = p.Id
WHERE p.PostTypeId = 1
ORDER BY p.Score DESC;
GO

/*
   WHAT I'D ADD NEXT, NOT BUILT HERE
     - Hybrid search: merge vector search with full-text results (reciprocal
       rank fusion). Vectors are great at meaning, weak at exact tokens like
       error codes and names.
     - A hard filter pushed into the search (tenant, date, permissions). On
       this build filters run after the graph walk (Demo 02 §4b).
     - Alerts on the checks in the core script's §4b and this appendix.
*/
