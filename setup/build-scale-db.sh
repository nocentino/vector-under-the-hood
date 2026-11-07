#!/usr/bin/env bash
# setup/build-scale-db.sh
#
# Builds StackOverflowScale, a second database with 1,000,000 real posts
# embedded, for the "at scale" half of Demo 02. It's separate from
# StackOverflow so Demo 03's drop-insert-rebuild cycle never touches it, and so
# the slow index build happens once, ahead of time.
#
# Run it from the repo root, after ./start.sh:
#
#   bash setup/ollama-lb.sh start            # extra Ollama instances for the load balancer
#   bash setup/build-scale-db.sh             # build it (about 2 hours on my M2)
#   bash setup/build-scale-db.sh --restore   # or restore from backups/StackOverflowScale.bak
#
# What's in it:
#   A fresh restore of StackOverflowMini, with the same schema as StackOverflow:
#   the EMBEDDINGS filegroup and dbo.QuestionEmbeddings (PostId, embeddings,
#   chunk). The same queries run in both databases. It holds 1,000,000 posts:
#     - all 402,278 questions, chunk = title + tags (same as StackOverflow)
#     - the top 597,722 answers by score, chunk = the first 500 characters of
#       the answer text with the HTML stripped
#   The table name says Question, but at this scale it holds answers too.
#
# How it goes fast:
#   The embeddings go through model-web:444, which load-balances across four
#   Ollama instances (setup/ollama-lb.sh). SESSIONS sqlcmd sessions run at once,
#   each embedding its own slice. One session through :443 is about 17 ms a row;
#   16 sessions through :444 are about 6 ms a row. More sessions than that
#   didn't help on my laptop: the GPU is the limit.
#
# It's resumable. If you stop it, run it again and it skips rows that are
# already embedded. When the data and index are done it writes a ZSTD-compressed
# backup to backups/ (not in git) so you can restore in minutes instead.
#
# Tunables (environment variables):
#   DB        database name                     (default StackOverflowScale)
#   SESSIONS  parallel embedding sessions       (default 16)
#   ROWS      posts to embed                    (default 1000000)

set -euo pipefail

SA_PASSWORD='S0methingS@Str0ng!'
CONTAINER='sql1'
DB="${DB:-StackOverflowScale}"
SESSIONS="${SESSIONS:-16}"
ROWS="${ROWS:-1000000}"
BAK="/var/opt/mssql/backups/${DB}.bak"
SRC="/var/opt/mssql/backups/StackOverflowMini.bak"

run_sql() {
    docker exec -e SQLCMDPASSWORD="$SA_PASSWORD" "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd \
        -S localhost -U sa -C -I -t 0 "$@"
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
echo "Database: $DB   rows: $ROWS   sessions: $SESSIONS"
echo ""

# ── Step 1: Restore StackOverflowMini as $DB, with StackOverflow's schema ─────
# PREVIEW_FEATURES is a database scoped setting, so it has to be turned on here.
# SIMPLE recovery keeps the log small during the load. Two models: ollama is
# the demo endpoint (:443), ollama_lb is the load-balanced one (:444).
run_sql -b -Q "
IF DB_ID(N'$DB') IS NULL
    RESTORE DATABASE [$DB] FROM DISK = N'$SRC'
    WITH MOVE 'StackOverflowMini'     TO '/var/opt/mssql/data/${DB}.mdf',
         MOVE 'StackOverflowMini_log' TO '/var/opt/mssql/data/${DB}_log.ldf',
         STATS = 25;
GO
ALTER DATABASE [$DB] SET COMPATIBILITY_LEVEL = 170;
ALTER DATABASE [$DB] SET RECOVERY SIMPLE;
GO
USE [$DB];
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;
GO
IF NOT EXISTS (SELECT 1 FROM sys.filegroups WHERE name = N'EMBEDDINGS')
    ALTER DATABASE [$DB] ADD FILEGROUP [EMBEDDINGS];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_files WHERE name = N'${DB}_Embeddings')
    ALTER DATABASE [$DB] ADD FILE
    (NAME = '${DB}_Embeddings', FILENAME = '/var/opt/mssql/data/${DB}_Embeddings.ndf',
     SIZE = 6GB, FILEGROWTH = 512MB) TO FILEGROUP [EMBEDDINGS];
GO
IF OBJECT_ID('dbo.QuestionEmbeddings', 'U') IS NULL
    CREATE TABLE dbo.QuestionEmbeddings
    (
        PostId     INT           NOT NULL,
        embeddings VECTOR(768)   NOT NULL,
        chunk      NVARCHAR(4000) NOT NULL,
        CONSTRAINT PK_QuestionEmbeddings PRIMARY KEY (PostId)
    ) ON [EMBEDDINGS];
GO
IF NOT EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'ollama')
    CREATE EXTERNAL MODEL ollama
    WITH (LOCATION = 'https://model-web:443/api/embed', API_FORMAT = 'Ollama',
          MODEL_TYPE = EMBEDDINGS, MODEL = 'nomic-embed-text');
IF NOT EXISTS (SELECT 1 FROM sys.external_models WHERE name = N'ollama_lb')
    CREATE EXTERNAL MODEL ollama_lb
    WITH (LOCATION = 'https://model-web:444/api/embed', API_FORMAT = 'Ollama',
          MODEL_TYPE = EMBEDDINGS, MODEL = 'nomic-embed-text');
GO"

# ── Step 2: Queue the posts to embed ──────────────────────────────────────────
# Answers have no title or tags, so an answer's chunk is its own text: the
# first 500 characters of the body with the HTML tags stripped, entities
# decoded, and whitespace collapsed. rn is in PostId order, so each session
# appends to its own range of the clustered key.
echo "[$(date '+%H:%M:%S')]  Queueing $ROWS posts ..."
run_sql -d "$DB" -b -Q "
SET NOCOUNT ON;
IF OBJECT_ID('dbo.EmbedQueue') IS NULL
BEGIN
    CREATE TABLE dbo.EmbedQueue (rn INT NOT NULL PRIMARY KEY, PostId INT NOT NULL, chunk NVARCHAR(4000) NOT NULL);

    SELECT a.Id, a.Score, t.txt
    INTO #answers
    FROM (SELECT TOP ($ROWS) Id, Score, LEFT(Body, 3000) AS b
          FROM dbo.Posts WHERE PostTypeId = 2 ORDER BY Score DESC, Id) a
    CROSS APPLY (
        SELECT LTRIM(RTRIM(
                 REPLACE(REPLACE(REPLACE(
                 REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                     (SELECT STRING_AGG(CAST(CASE WHEN CHARINDEX(N'>', s.value) > 0
                                                  THEN SUBSTRING(s.value, CHARINDEX(N'>', s.value) + 1, 4000)
                                                  ELSE s.value END AS NVARCHAR(MAX)), N' ')
                                        WITHIN GROUP (ORDER BY s.ordinal)
                      FROM STRING_SPLIT(a.b, N'<', 1) s),
                 N'&lt;', N'<'), N'&gt;', N'>'), N'&quot;', N'\"'), N'&#39;', N''''), N'&amp;', N'&'),
                 CHAR(13), N' '), CHAR(10), N' '),
                 N'    ', N' '), N'  ', N' '), N'  ', N' '))) AS txt
    ) t;

    WITH q AS (
        SELECT p.Id AS PostId,
               p.Title + N' ' + REPLACE(REPLACE(REPLACE(ISNULL(p.Tags, N''), N'><', N' '), N'<', N''), N'>', N'') AS chunk
        FROM dbo.Posts p
        WHERE p.PostTypeId = 1 AND p.Title IS NOT NULL
    ), a AS (
        SELECT TOP ($ROWS - (SELECT COUNT(*) FROM q)) Id AS PostId, LEFT(txt, 500) AS chunk
        FROM #answers WHERE LEN(txt) >= 20
        ORDER BY Score DESC, Id
    )
    INSERT INTO dbo.EmbedQueue (rn, PostId, chunk)
    SELECT ROW_NUMBER() OVER (ORDER BY PostId), PostId, chunk
    FROM (SELECT PostId, chunk FROM q UNION ALL SELECT PostId, chunk FROM a) x;
END
SELECT COUNT(*) AS queued FROM dbo.EmbedQueue;"

# ── Step 2b: Held-out queries for the recall tests ────────────────────────────
# Every question is in the table, so recall needs query vectors that aren't:
# 100 answers that didn't make the cut, at least 200 characters of text,
# picked by a hash of the Id so the set is the same on every build.
run_sql -d "$DB" -b -Q "
SET NOCOUNT ON;
IF OBJECT_ID('dbo.HoldoutQueries') IS NULL
BEGIN
    CREATE TABLE dbo.HoldoutQueries (qid INT NOT NULL PRIMARY KEY, PostId INT NOT NULL,
                                     chunk NVARCHAR(4000) NOT NULL, embeddings VECTOR(768) NULL);
    WITH cand AS (
        SELECT TOP (5000) p.Id, LEFT(p.Body, 3000) AS b
        FROM dbo.Posts p
        WHERE p.PostTypeId = 2
          AND NOT EXISTS (SELECT 1 FROM dbo.EmbedQueue q WHERE q.PostId = p.Id)
        ORDER BY HASHBYTES('MD5', CAST(p.Id AS VARCHAR(12)))
    ), clean AS (
        SELECT cand.Id, LEFT(t.txt, 500) AS chunk, LEN(t.txt) AS len
        FROM cand
        CROSS APPLY (
            SELECT LTRIM(RTRIM(
                     REPLACE(REPLACE(REPLACE(
                     REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
                         (SELECT STRING_AGG(CAST(CASE WHEN CHARINDEX(N'>', s.value) > 0
                                                      THEN SUBSTRING(s.value, CHARINDEX(N'>', s.value) + 1, 4000)
                                                      ELSE s.value END AS NVARCHAR(MAX)), N' ')
                                            WITHIN GROUP (ORDER BY s.ordinal)
                          FROM STRING_SPLIT(cand.b, N'<', 1) s),
                     N'&lt;', N'<'), N'&gt;', N'>'), N'&quot;', N'\"'), N'&#39;', N''''), N'&amp;', N'&'),
                     CHAR(13), N' '), CHAR(10), N' '),
                     N'    ', N' '), N'  ', N' '), N'  ', N' '))) AS txt
        ) t
    )
    INSERT INTO dbo.HoldoutQueries (qid, PostId, chunk)
    SELECT TOP (100) ROW_NUMBER() OVER (ORDER BY HASHBYTES('MD5', CAST(Id AS VARCHAR(12)))), Id, chunk
    FROM clean WHERE len >= 200
    ORDER BY HASHBYTES('MD5', CAST(Id AS VARCHAR(12)));

    UPDATE dbo.HoldoutQueries SET embeddings = AI_GENERATE_EMBEDDINGS(chunk USE MODEL ollama);
END
SELECT COUNT(*) AS holdout_queries FROM dbo.HoldoutQueries;"

# ── Step 3: Embed, SESSIONS slices at once through the load balancer ──────────
# Each session works through its slice 1,000 rows per INSERT, skipping rows
# that are already there, and retries a failed batch. The REST call itself
# retries too (retry_count). A parallel plan hint didn't help here: the calls
# still went one at a time, so the concurrency comes from separate sessions.
WORKER=$(mktemp)
cat > "$WORKER" <<'SQL'
SET NOCOUNT ON;
DECLARE @lo INT = $(lo), @hi INT = $(hi), @batch INT = 1000;
DECLARE @params JSON = N'{"sql_rest_options":{"retry_count":3}}';
DECLARE @b INT = @lo, @e INT, @tries INT, @err INT;
WHILE @b <= @hi
BEGIN
    SET @e = CASE WHEN @b + @batch - 1 > @hi THEN @hi ELSE @b + @batch - 1 END;
    SET @tries = 0;
    WHILE 1 = 1
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.QuestionEmbeddings (PostId, embeddings, chunk)
            SELECT q.PostId, AI_GENERATE_EMBEDDINGS(q.chunk USE MODEL ollama_lb PARAMETERS @params), q.chunk
            FROM dbo.EmbedQueue q
            WHERE q.rn BETWEEN @b AND @e
              AND NOT EXISTS (SELECT 1 FROM dbo.QuestionEmbeddings qe WHERE qe.PostId = q.PostId)
            OPTION (MAXDOP 1);
            BREAK;
        END TRY
        BEGIN CATCH
            SELECT @tries += 1, @err = ERROR_NUMBER();
            RAISERROR('slice %d-%d batch %d: Msg %d, try %d', 0, 1, @lo, @hi, @b, @err, @tries) WITH NOWAIT;
            IF @tries >= 5 THROW;
            WAITFOR DELAY '00:00:05';
        END CATCH
    END
    SET @b = @e + 1;
END
SQL
docker cp "$WORKER" "$CONTAINER:/tmp/embed_worker.sql" > /dev/null
rm -f "$WORKER"

if run_sql -d "$DB" -h -1 -W -Q "SET NOCOUNT ON; SELECT 1 FROM sys.vector_indexes WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings');" | grep -q 1; then
    echo "[$(date '+%H:%M:%S')]  Vector index exists, so the table is read-only. Skipping embedding."
else
    echo "[$(date '+%H:%M:%S')]  Embedding with $SESSIONS sessions through model-web:444 ..."
    emb_start=$(date +%s)
    per=$(( (ROWS + SESSIONS - 1) / SESSIONS ))
    for i in $(seq 0 $((SESSIONS - 1))); do
        lo=$(( i * per + 1 )); hi=$(( lo + per - 1 )); [ "$hi" -gt "$ROWS" ] && hi=$ROWS
        run_sql -d "$DB" -v lo="$lo" hi="$hi" -i /tmp/embed_worker.sql &
    done
    wait
    echo "[$(date '+%H:%M:%S')]  Embedding done in $(( $(date +%s) - emb_start )) seconds."
fi
run_sql -d "$DB" -Q "SET NOCOUNT ON; SELECT COUNT(*) AS embedded FROM dbo.QuestionEmbeddings;"

# ── Step 4: Build the vector index ────────────────────────────────────────────
echo ""
echo "[$(date '+%H:%M:%S')]  Building the DiskANN index. This is the slow part."
idx_start=$(date +%s)
run_sql -d "$DB" -b -Q "
IF NOT EXISTS (SELECT 1 FROM sys.vector_indexes WHERE object_id = OBJECT_ID('dbo.QuestionEmbeddings'))
    CREATE VECTOR INDEX vec_idx ON dbo.QuestionEmbeddings(embeddings)
    WITH (metric = 'cosine', type = 'diskann', MAXDOP = 4);
GO"
echo "[$(date '+%H:%M:%S')]  Index built in $(( $(date +%s) - idx_start )) seconds."

# ── Step 5: Back it up so you can restore instead of rebuilding ───────────────
# The queue isn't needed once everything is embedded.
run_sql -d "$DB" -Q "DROP TABLE IF EXISTS dbo.EmbedQueue;"
echo ""
echo "[$(date '+%H:%M:%S')]  Writing the backup to backups/${DB}.bak ..."
run_sql -Q "BACKUP DATABASE [$DB] TO DISK = N'$BAK' WITH FORMAT, INIT, COMPRESSION (ALGORITHM = ZSTD), CHECKSUM, STATS = 10;"

echo ""
echo "======================================================"
echo "  $DB is ready: $ROWS posts, indexed, backed up."
echo "  Restore later with: bash setup/build-scale-db.sh --restore"
echo "======================================================"
