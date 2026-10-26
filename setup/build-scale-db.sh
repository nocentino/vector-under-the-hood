#!/usr/bin/env bash
# setup/build-scale-db.sh
#
# Builds StackOverflowScale, a second database with 1,000,000 vectors for the
# "at scale" half of Demo 02. It's separate from StackOverflow so Demo 03's
# drop-insert-rebuild cycle never touches it, and so the slow index build
# happens once, ahead of time.
#
# Run it from the repo root, after ./start.sh and expand-embeddings.sh:
#
#   bash setup/build-scale-db.sh             # build it (about an hour or more)
#   bash setup/build-scale-db.sh --restore   # restore from backups/StackOverflowScale.bak
#
# How the data is made:
#   The first 10,000 real embeddings from StackOverflow are the "centers".
#   Each center gets 100 noisy copies (random noise added to every element), so
#   the table has 1,000,000 rows that keep real topic structure. Neighbors
#   cluster the way real text does, which makes recall at this size meaningful.
#   The vectors are SYNTHETIC. They aren't real questions, so don't read the
#   titles. Use it for timing and recall, not for search quality.
#
# It's resumable. If you stop it, run it again and it continues from the last
# complete copy. When the data and index are done it writes a compressed backup
# to backups/ (not in git) so you can restore in minutes instead of rebuilding.
#
# Tunables (environment variables):
#   DB       database name           (default StackOverflowScale)
#   CENTERS  real vectors to start from (default 10000)
#   COPIES   noisy copies per center     (default 100)
#   NOISE    half-width of the uniform noise added to each element (default 0.05)
#            Elements of a unit-length 768-d vector are about 0.036 in size.

set -euo pipefail

SA_PASSWORD='S0methingS@Str0ng!'
CONTAINER='sql1'
DB="${DB:-StackOverflowScale}"
CENTERS="${CENTERS:-10000}"
COPIES="${COPIES:-100}"
NOISE="${NOISE:-0.05}"
BAK="/var/opt/mssql/backups/${DB}.bak"

run_sql() {
    docker exec "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -P "$SA_PASSWORD" -C -I -t 0 "$@"
}

if ! docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
    echo "ERROR: Container '$CONTAINER' is not running. Run ./start.sh first."
    exit 1
fi

# ── Restore path ──────────────────────────────────────────────────────────────
if [ "${1:-}" = "--restore" ]; then
    echo "[$(date '+%H:%M:%S')]  Restoring $DB from $BAK ..."
    run_sql -Q "
IF DB_ID(N'$DB') IS NOT NULL
BEGIN
    ALTER DATABASE [$DB] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DB];
END
RESTORE DATABASE [$DB] FROM DISK = N'$BAK' WITH REPLACE, STATS = 10;"
    echo "[$(date '+%H:%M:%S')]  Restored."
    exit 0
fi

echo "Started at: $(date)"
echo "Database: $DB   centers: $CENTERS   copies: $COPIES   rows: $((CENTERS * COPIES))   noise: $NOISE"
echo ""

# ── Step 1: Create the database and the tables ────────────────────────────────
# PREVIEW_FEATURES is a database scoped setting, so it has to be turned on here.
# Compatibility level 170 matches StackOverflow. SIMPLE recovery keeps the log
# small during the load. The data file is pre-sized so the load isn't
# interrupted by autogrow.
run_sql -Q "
IF DB_ID(N'$DB') IS NULL
BEGIN
    CREATE DATABASE [$DB]
    ON PRIMARY (NAME = N'${DB}', FILENAME = N'/var/opt/mssql/data/${DB}.mdf',
                SIZE = 8GB, FILEGROWTH = 512MB)
    LOG ON     (NAME = N'${DB}_log', FILENAME = N'/var/opt/mssql/data/${DB}_log.ldf',
                SIZE = 1GB, FILEGROWTH = 512MB);
    PRINT 'Database created.';
END
ALTER DATABASE [$DB] SET COMPATIBILITY_LEVEL = 170;
ALTER DATABASE [$DB] SET RECOVERY SIMPLE;
GO
USE [$DB];
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO
IF OBJECT_ID('dbo.Centers') IS NULL
BEGIN
    -- PostId records which real question each center came from. The recall
    -- test uses real questions that are NOT centers as its queries.
    CREATE TABLE dbo.Centers (Id INT NOT NULL PRIMARY KEY CLUSTERED, PostId INT NOT NULL, js NVARCHAR(MAX) NOT NULL);
    INSERT INTO dbo.Centers (Id, PostId, js)
    SELECT TOP ($CENTERS) ROW_NUMBER() OVER (ORDER BY PostId), PostId, CAST(embeddings AS NVARCHAR(MAX))
    FROM StackOverflow.dbo.QuestionEmbeddings
    ORDER BY PostId;
END
IF OBJECT_ID('dbo.ScaleVectors') IS NULL
    CREATE TABLE dbo.ScaleVectors
    (
        Id       INT         NOT NULL,   -- (copy - 1) * centers + center
        CenterId INT         NOT NULL,
        v        VECTOR(768) NOT NULL,
        CONSTRAINT PK_ScaleVectors PRIMARY KEY CLUSTERED (Id)
    );
GO"

# ── Step 2: Generate the copies, one pass over all centers per call ───────────
# The table is read-only once the vector index exists, so a rerun after the
# index is built does nothing here (the row count is already at the target).
rows=$(run_sql -d "$DB" -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.ScaleVectors;" | grep -E '^[0-9]+$' | tail -1)
rows=${rows:-0}
copy=$(( rows / CENTERS ))
target=$(( CENTERS * COPIES ))
echo "[$(date '+%H:%M:%S')]  Starting at $rows rows (target $target)."

gen_start=$(date +%s)
while [ "$copy" -lt "$COPIES" ]; do
    copy=$((copy + 1))
    t0=$(date +%s)
    run_sql -d "$DB" -b -Q "
SET NOCOUNT ON;
INSERT INTO dbo.ScaleVectors (Id, CenterId, v)
SELECT ($copy - 1) * $CENTERS + c.Id, c.Id, CAST(CONCAT('[', x.js, ']') AS VECTOR(768))
FROM dbo.Centers c
CROSS APPLY (
    -- Each element: the center's value plus uniform noise. NEWID() is
    -- non-deterministic, so it's evaluated for every element of every row.
    -- CAST to VARCHAR(MAX): STRING_AGG stops at 8,000 bytes otherwise.
    SELECT STRING_AGG(
               CAST(CAST(CAST(j.[value] AS FLOAT)
                         + (ABS(CHECKSUM(NEWID())) % 2000001 - 1000000) / 1000000.0 * $NOISE
                    AS VARCHAR(24)) AS VARCHAR(MAX)), ',')
           WITHIN GROUP (ORDER BY CAST(j.[key] AS INT)) AS js
    FROM OPENJSON(c.js) AS j
) AS x;
GO" > /dev/null
    echo "[$(date '+%H:%M:%S')]  Copy $copy of $COPIES done in $(( $(date +%s) - t0 )) s  ($((copy * CENTERS)) rows)"
done
echo "[$(date '+%H:%M:%S')]  Generation done in $(( $(date +%s) - gen_start )) seconds."

# ── Step 3: Build the vector index ────────────────────────────────────────────
echo ""
echo "[$(date '+%H:%M:%S')]  Building the DiskANN index. This is the slow part."
idx_start=$(date +%s)
run_sql -d "$DB" -Q "
IF NOT EXISTS (SELECT 1 FROM sys.vector_indexes WHERE object_id = OBJECT_ID('dbo.ScaleVectors'))
    CREATE VECTOR INDEX vec_idx_scale ON dbo.ScaleVectors(v)
    WITH (metric = 'cosine', type = 'diskann');
GO"
echo "[$(date '+%H:%M:%S')]  Index built in $(( $(date +%s) - idx_start )) seconds."

# ── Step 4: Back it up so you can restore instead of rebuilding ───────────────
echo ""
echo "[$(date '+%H:%M:%S')]  Writing the backup to backups/${DB}.bak ..."
run_sql -Q "BACKUP DATABASE [$DB] TO DISK = N'$BAK' WITH COMPRESSION, INIT, STATS = 10;"

echo ""
echo "======================================================"
echo "  $DB is ready: $target rows, indexed, backed up."
echo "  Restore later with: bash setup/build-scale-db.sh --restore"
echo "======================================================"
