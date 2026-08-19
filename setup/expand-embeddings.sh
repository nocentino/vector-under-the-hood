#!/usr/bin/env bash
# setup/expand-embeddings.sh
#
# Grows QuestionEmbeddings from the initial 1,000 rows to 10,000 by embedding
# the next highest-scored StackOverflow questions not yet in the table.
#
# Run from the repo root after the initial stack start:
#
#   bash setup/expand-embeddings.sh
#
# Timing reference (Apple Silicon M-series, Ollama GPU acceleration):
#   ~15 sec per 100 embeddings  →  ~15 minutes for the full 10,000
#
# The script is idempotent — safe to re-run or resume after a failure.
# The NOT EXISTS guard in each INSERT batch skips already-embedded rows.
# Batches that hit the external REST timeout (Msg 31629) are retried
# automatically on the next iteration.
#
# What this script does:
#   1. Drops the DiskANN index (required for bulk INSERT on SQL Server 2025)
#   2. Shell while loop: sends 100-row INSERT batches to SQL Server until
#      dbo.QuestionEmbeddings has 10,000 rows. 100-row batches (~15 s each)
#      stay well within SQL Server's external REST endpoint timeout, unlike
#      1,000-row batches (~90–165 s) which hit Msg 31629 inconsistently.
#   3. Rebuilds the DiskANN index over all 10,000 rows
#   4. Reports elapsed time

set -euo pipefail

SA_PASSWORD='S0methingS@Str0ng!'
CONTAINER='sql1'
TARGET=10000
BATCH=100   # 100-row batches (~15 s each) reliably stay within the external REST timeout.
            # 1,000-row batches (~90–165 s) hit Msg 31629 inconsistently.

# ── Helper: run sqlcmd inside the container ───────────────────────────────────
run_sql() {
    docker exec "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -P "$SA_PASSWORD" -d StackOverflow -C -I "$@"
}

# ── Preflight: confirm the container is running ───────────────────────────────
if ! docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    echo "ERROR: Container '$CONTAINER' is not running. Run ./start.sh first."
    exit 1
fi

echo "Started at: $(date)"
echo ""

# ── Step 1: Drop the vector index (makes the table writable) ──────────────────
echo "[$(date '+%H:%M:%S')]  Dropping vector index (if present)..."
run_sql -Q "
IF EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE  name      = 'vec_idx'
      AND  object_id = OBJECT_ID('dbo.QuestionEmbeddings')
)
BEGIN
    DROP INDEX vec_idx ON dbo.QuestionEmbeddings;
    PRINT 'Vector index dropped.';
END
ELSE
    PRINT 'Vector index was already absent.';
GO
SELECT 'Current rows: ' + CAST(COUNT(*) AS VARCHAR(10)) AS status
FROM dbo.QuestionEmbeddings;
GO"

# ── Step 2: Shell while loop: 100-row batches until TARGET ───────────────────
# Each iteration calls sqlcmd once. If Msg 31629 fires (external REST timeout),
# the INSERT rolls back, the error message is printed, and the loop retries
# the same rows on the next iteration. The NOT EXISTS guard is idempotent.
echo ""
echo "[$(date '+%H:%M:%S')]  Starting embedding loop (target: $TARGET rows, batch: $BATCH)..."
echo ""

embed_start=$(date +%s)
batch_num=0
total=$(run_sql -Q "SET NOCOUNT ON; SELECT CAST(COUNT(*) AS VARCHAR(10)) FROM dbo.QuestionEmbeddings; GO" 2>&1 \
    | grep -E '^\s*[0-9]+\s*$' | tail -1 | tr -d ' ')
total=${total:-0}
echo "[$(date '+%H:%M:%S')]  Starting at $total rows."

while [ "$total" -lt "$TARGET" ]; do
    batch_num=$((batch_num + 1))
    result=$(run_sql -Q "
;WITH nq AS (
    SELECT TOP ($BATCH) p.Id,
        p.Title + N' ' +
            REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'')
            AS chunk
    FROM dbo.Posts p
    WHERE p.PostTypeId = 1
      AND p.Title IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM dbo.QuestionEmbeddings qe WHERE qe.PostId = p.Id
      )
    ORDER BY p.Score DESC
)
INSERT INTO dbo.QuestionEmbeddings (PostId, chunk, embeddings)
SELECT q.Id, q.chunk, AI_GENERATE_EMBEDDINGS(q.chunk USE MODEL ollama) FROM nq q;
GO
SET NOCOUNT ON;
SELECT CAST(COUNT(*) AS VARCHAR(10)) FROM dbo.QuestionEmbeddings;
GO" 2>&1)

    total=$(echo "$result" | grep -E '^\s*[0-9]+\s*$' | tail -1 | tr -d ' ')

    if echo "$result" | grep -q "31629"; then
        echo "[$(date '+%H:%M:%S')] Batch $batch_num: REST timeout — retrying (rows still: ${total:-?})"
    else
        echo "[$(date '+%H:%M:%S')] Batch $batch_num done — rows now: $total"
    fi
done

embed_end=$(date +%s)
echo ""
echo "[$(date '+%H:%M:%S')]  Embedding done in $(( embed_end - embed_start )) seconds. Final: $total rows."

# ── Step 3: Rebuild the DiskANN index ─────────────────────────────────────────
echo ""
echo "[$(date '+%H:%M:%S')]  Rebuilding DiskANN vector index..."
index_start=$(date +%s)

run_sql -Q "
CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings([embeddings])
WITH (metric = 'cosine', type = 'diskann', maxdop = 8);
GO
SELECT 'Vector index built over ' + CAST(COUNT(*) AS VARCHAR(10)) + ' rows.' AS status
FROM dbo.QuestionEmbeddings;
GO"

index_end=$(date +%s)

echo ""
echo "======================================================"
echo "  Embedding       : $(( embed_end  - embed_start )) seconds"
echo "  Index build     : $(( index_end  - index_start )) seconds"
echo "  Total elapsed   : $(( index_end  - embed_start )) seconds"
echo "======================================================"
