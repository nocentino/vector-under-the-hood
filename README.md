# Vector: Under the Hood and Into Production

Conference demo repo for the talk **"Vector: Under the Hood and Into Production"**.  
Everything runs locally — SQL Server 2025, Ollama embeddings, and a Python RAG app —
with a single command.

---

## What you need

| Prerequisite | Notes |
|---|---|
| **Docker Desktop** | 4.x or later, running |
| **Ollama** | [ollama.com/download](https://ollama.com/download) — must be installed |
| **ODBC Driver 18** for SQL Server | [Microsoft docs](https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server) — needed only for `rag-app.py` |
| **Python 3.9+** | Only for `rag-app.py` |
| ~4 GB free disk space | SQL Server image (~1.7 GB) + StackOverflow backup (~760 MB) |
| ~2 GB more for `llama3.2` | Used by the RAG app for generation |

> **Apple Silicon (M1/M2/M3/M4):** SQL Server 2025 runs as `linux/amd64` under Rosetta.  
> Docker Desktop's Rosetta emulation must be enabled (Settings → General → Use Rosetta).

---

## Quick start

```bash
# 1. Clone / download this repo and cd into it
cd vector-under-the-hood

# 2. Pull the models and spin up the full stack
./start.sh
```

`start.sh` will:
1. Start Ollama (if not already running) and pull `nomic-embed-text` + `llama3.2`
2. Download the StackOverflow Mini backup (~760 MB, one-time)
3. `docker compose up --detach` — builds the TLS proxy, starts SQL Server, restores  
   the database, generates 1,000 embeddings, and builds the DiskANN vector index

The `sql-init` container runs the full setup and exits with code 0 when everything  
is ready. Watch progress with:

```bash
docker logs -f sql-init
```

First run takes **10–20 minutes** (image pulls + embedding 1,000 questions).

---

## Expanding the corpus to 10,000 embeddings (recommended)

The startup script embeds the **top 1,000** questions by community score. For a
more striking ANN vs. kNN IO contrast (Demo 02 §2) and a larger recall sample
(Demo 02 §3), expand to **10,000 rows** before running the demos:

```bash
bash setup/expand-embeddings.sh
```

The script drops the vector index, embeds the next highest-scored questions in
batches of 1,000, then rebuilds the DiskANN index over all 10,000 rows.

**Timing reference** (Apple Silicon M-series with Ollama GPU acceleration):

| Phase | Time |
|---|---|
| Per 1,000 embeddings | ~2 min 45 sec |
| Full 10,000-row run (9 additional batches) | ~25 minutes |
| DiskANN index rebuild | ~7–15 seconds |

The script is resumable — if interrupted, re-run it and it picks up where it
left off (the `NOT EXISTS` guard skips already-embedded rows).

---

## Stopping / cleaning up

```bash
./stop.sh           # stop containers, keep data volume
./stop.sh --wipe    # stop containers AND delete the sql-data volume (full reset)
```

---

## Connection details

| Setting | Value |
|---|---|
| Host | `localhost,1435` |
| SA password | `S0methingS@Str0ng!` |
| Database | `StackOverflow` |
| RAG app login | `rag_app` / `RagP@ss2025!` |
| Monitor login | `dba_monitor` / `MonitorP@ss123!` |

> Port **1435** is used (not 1433) to avoid conflicts with other local SQL Server instances.

---

## Stack architecture

```
Host (macOS)
├── Ollama :11434          ← GPU-accelerated embedding + generation
│
└── Docker Compose
    ├── config             one-shot: generates self-signed TLS cert
    ├── model-web          NGINX :443 → Ollama (TLS required by SQL Server)
    ├── sql1               SQL Server 2025 :1434 — vectors, DiskANN, RAG procs
    └── sql-init           one-shot: restore DB, embed 1,000 questions, build index
                           (run setup/expand-embeddings.sh to grow to 10,000)
```

SQL Server's `EXTERNAL MODEL` requires HTTPS. NGINX terminates TLS and reverse-proxies
to the host's Ollama — that's why the `model-web` service exists.

---

## Demos

Run the three demo files **in order** in SSMS or Azure Data Studio, connected to
`localhost,1435` as `sa`.

### Demo 01 — Vector Internals ([demos/01-vector-internals.sql](demos/01-vector-internals.sql))

| Section | Topic |
|---|---|
| 1a | `VECTOR` type in `sys.types` and `sys.columns` |
| 1b | `DATALENGTH` — 8-byte header + 768 × 4 = 3,080 bytes per float32 vector |
| 1c | Client representation — `NVARCHAR` JSON array vs internal binary format |
| 1d | `sys.fn_PhysLocFormatter` + `DBCC PAGE` stub |
| **1e** | **Half-precision `VECTOR(n, float16)` — 2 bytes/element, 3,996-dim ceiling** |
| 2 | Filegroups and data files — `EMBEDDINGS` filegroup isolation |
| 3 | `AI_GENERATE_EMBEDDINGS` — timing, the HTTP round-trip |
| 4 | `VECTOR_DISTANCE` metrics — cosine / euclidean / dot; `VECTOR_NORM` |
| 5 | Exact kNN execution plan — Scan → Compute Scalar → Top Sort |

### Demo 02 — Index Performance ([demos/02-index-performance.sql](demos/02-index-performance.sql))

| Section | Topic |
|---|---|
| 1 | `CREATE VECTOR INDEX` — DiskANN graph, build time, catalog |
| 2 | IO comparison — `SET STATISTICS IO ON`, kNN scan vs ANN graph walk |
| 3 | Recall@K measurement — ANN vs exact kNN overlap |
| 4a | Limitation: read-only table (on-prem) — `ALLOW_STALE_VECTOR_INDEX` is Azure SQL DB only |
| 4b | Limitation: filtered search + oversampling (`TOP_N`) workaround |
| 4c | Limitation: dimension constraints — 1,998 (float32) / 3,996 (float16) |
| 4d | Limitation: index build resource monitoring |
| **4e** | **Execution plan anatomy — `Vector Index Seek` operator, plan cache query** |
| **4f** | **Stress test: silent zero-results failure + step-by-step diagnosis + fix** |
| **5** | **Latest-version DiskANN (Azure SQL DB / Fabric)** — `SELECT TOP N WITH APPROXIMATE`, iterative filtering, `sys.dm_db_vector_indexes` DMV |

### Demo 03 — Application Architecture ([demos/03-application-architecture.sql](demos/03-application-architecture.sql))

| Section | Topic |
|---|---|
| 1 | Schema design — satellite table pattern |
| 2 | `dbo.find_similar_questions` — RAG retrieval stored procedure |
| 3 | `dbo.get_top_answer` — accepted-answer fetch |
| 4 | Security — `rag_app` least-privilege login |
| 5 | Pipeline patterns — incremental embedding, model swap |

---

## Python RAG app

```bash
cd demos
pip install -r ../requirements.txt

# Interactive REPL
python rag-app.py

# Single question via CLI
python rag-app.py "how do I undo my last git commit?"
```

The app connects as `rag_app` to `localhost,1435`, calls `dbo.find_similar_questions`
for retrieval, then calls Ollama `llama3.2` directly for answer generation.

---

## Changing embedding models

1. Pull a different model in Ollama: `ollama pull mxbai-embed-large`
2. Update `setup/init.sql` — change the `EXTERNAL MODEL` definition and the  
   `VECTOR(768)` column dimension to match the new model's output size
3. Run `./stop.sh --wipe` then `./start.sh` to rebuild from scratch

---

## Key SQL Server 2025 features used

| Feature | Demo |
|---|---|
| `VECTOR(n)` data type (float32) | 01, 02, 03 |
| `VECTOR(n, float16)` half-precision | 01 §1e |
| `AI_GENERATE_EMBEDDINGS` | 01 §3, 03 |
| `VECTOR_DISTANCE` / `VECTOR_NORM` | 01 §4 |
| `CREATE VECTOR INDEX` (DiskANN) | 02 §1 |
| `VECTOR_SEARCH` / `SELECT TOP N WITH APPROXIMATE` | 02 §2, §5 |
| `sys.dm_db_vector_indexes` DMV | 02 §5 |
| `EXTERNAL MODEL` (Ollama via HTTPS) | 01 §3, 03 |
