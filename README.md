# SQL Server 2025 Vectors: Under the Hood and Into Production

Conference demo repo for the talk **"SQL Server 2025 Vectors: Under the Hood and Into Production"**.  
Everything runs locally — SQL Server 2025, Ollama embeddings, and a Python RAG app —
with a single command. No cloud services, no API keys.

---

## What you need

| Prerequisite | Notes |
|---|---|
| **Docker Desktop** | 4.x or later, running |
| **Ollama** | [ollama.com/download](https://ollama.com/download) — must be installed |
| **ODBC Driver 18** for SQL Server | Optional: only to run `rag-app.py` on the host. The `rag-app` container includes it |
| **Python 3.9+** | Optional: only to run `rag-app.py` on the host |
| ~4 GB free disk space | SQL Server image (~1.7 GB) + StackOverflow backup (~760 MB) |
| ~2 GB more for `llama3.2` | Used by the RAG app for generation |
| ~670 MB more for `mxbai-embed-large` | Optional: only for the model swap in Demo 03 §4b (`ollama pull mxbai-embed-large`) |

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
batches of 100, then rebuilds the DiskANN index over all 10,000 rows.

**Timing reference** (Apple Silicon M2, SQL Server 2025 CU10, Ollama on the host):

| Phase | Time |
|---|---|
| Per 100 embeddings | ~20 sec |
| Full 10,000-row run (90 additional batches) | ~30 minutes |
| DiskANN index build, 1,000 rows | ~11 seconds |
| DiskANN index build, 10,000 rows | ~23 seconds to ~2 minutes on a running instance; ~340 seconds right after a restart |

The script is resumable — if interrupted, re-run it and it picks up where it
left off (the `NOT EXISTS` guard skips already-embedded rows).

---

## Before you present

Everything runs much slower right after a restart. Warm it up first:

1. Start Docker Desktop, then `./start.sh`, and wait for `sql1` to be healthy.
2. Run one throwaway index build (Demo 02 §1b). The first build after a
   restart took ~340 seconds here; after that, 23 seconds to 2 minutes.
   The demos rebuild the index twice live (Demo 02 §1b, Demo 03 §4a), so
   budget about two minutes for each and talk through a diagram while it runs.
3. Run Demo 02 §2b once so the plans and buffer pool are warm.
4. Ask the app one question so Ollama loads `llama3.2`:
   `docker compose run --rm rag-app python demos/rag-app.py "warm up"`
5. If you'll show Demo 03 §4b, warm `mxbai-embed-large` too. A cold model can
   exceed SQL Server's REST timeout (Msg 31629):
   `curl -s http://localhost:11434/api/embed -d '{"model":"mxbai-embed-large","input":"warm up"}' > /dev/null`
6. Each run of Demo 03 §4a embeds 100 more questions. Use `./stop.sh --wipe`
   for a clean reset (then re-run the expansion).

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
    ├── sql1               SQL Server 2025 :1435→1433 — vectors, DiskANN, RAG procs
    ├── sql-init           one-shot: restore DB, embed 1,000 questions, build index
    │                      (run setup/expand-embeddings.sh to grow to 10,000)
    └── rag-app / rag-app-ui   optional (profile "app"): Python RAG CLI and
                           Streamlit UI :8501, with the ODBC driver built in
```

SQL Server's `EXTERNAL MODEL` requires HTTPS. NGINX terminates TLS and reverse-proxies
to the host's Ollama — that's why the `model-web` service exists.

---

## Demos

Run the three demo files **in order** in SSMS or the MSSQL extension for VS Code,
connected to `localhost,1435` as `sa`.

**Session plan (60 minutes of demos + 15 minutes Q&A):**

| Demo | Time | Abstract objective |
|---|---|---|
| 01 Vector internals | 15 min | 1. Describe storage, indexing, and query execution |
| 02 Index performance | 25 min | 2. Evaluate index performance and limits at scale |
| 03 Application architecture + app | 20 min | 3. Apply architecture patterns to build a working app |

Sections marked **[OPTIONAL]** in the scripts are deep dives for Q&A.

### Demo 01 — Vector Internals ([demos/01-vector-internals.sql](demos/01-vector-internals.sql))

| Section | Topic |
|---|---|
| 1a | `VECTOR` type in `sys.types` and `sys.columns` |
| 1b | `DATALENGTH` — 8-byte header (observed) + 768 × 4 = 3,080 bytes per float32 vector |
| 1c | Client representation — JSON array vs internal binary format |
| 1d | [OPTIONAL] In-row vs row-overflow: allocation units + `DBCC PAGE` |
| 1e | Half-precision `VECTOR(n, float16)` — 2 bytes/element, 3,996-dim ceiling |
| 2 | [OPTIONAL] Filegroups and data files — `EMBEDDINGS` filegroup isolation |
| 3 | `AI_GENERATE_EMBEDDINGS` — timing, the HTTP round-trip |
| 4 | `VECTOR_DISTANCE` metrics — cosine / euclidean / dot; `VECTOR_NORM` |
| 5 | Exact kNN execution plan — rank in the satellite table, then join |

### Demo 02 — Index Performance ([demos/02-index-performance.sql](demos/02-index-performance.sql))

| Section | Topic |
|---|---|
| 1 | DiskANN / Vamana, build time, `build_parameters`, the graph's internal tables |
| 2 | IO comparison (`SET STATISTICS IO`) and a scale measurement, kNN vs ANN |
| 3 | Recall@K — ANN vs exact kNN overlap |
| 4a | Limitation: read-only table (Msg 42231 / 42232) |
| 4b–4e | [OPTIONAL] Filtered search, dimensions, build cost, `Vector Index Seek` plan |
| 4f | Silent zero-results with filters, diagnosis, and the oversampling fix |
| 4g | The other documented limits: INT clustered PK, no temp tables, no partitioning |
| 5 | Latest-version DiskANN on Azure SQL DB / Fabric / MI — version check and migration |

### Demo 03 — Application Architecture ([demos/03-application-architecture.sql](demos/03-application-architecture.sql))

| Section | Topic |
|---|---|
| 1 | Satellite table design; chunking long text with `AI_GENERATE_CHUNKS` |
| 2 | `dbo.find_similar_questions` — ANN with a kNN fallback; `dbo.get_top_answer` |
| 3 | Security — `rag_app` least-privilege login |
| 4a | Drop → embed → rebuild cycle, with the proc switching paths live |
| 4b | [OPTIONAL] Side-by-side model swap with a second Ollama model |
| 5 | The full RAG call sequence, then the Python app |

---

## Python RAG app

The app runs in a container (`dockerfile.app`), so the host doesn't need an ODBC
driver. The image builds the first time you run it.

```bash
# Single question via CLI
docker compose run --rm rag-app python demos/rag-app.py "how do I undo my last git commit?"

# Interactive REPL
docker compose run --rm rag-app python demos/rag-app.py

# Streamlit UI at http://localhost:8501
docker compose --profile app up rag-app-ui
```

To run it on the host instead, install the ODBC driver and `pip install -r requirements.txt`,
then `python demos/rag-app.py`. On macOS, Microsoft's ODBC driver loads OpenSSL 3 from
`/opt/homebrew/opt/openssl`; if that link points at OpenSSL 4, connections fail with
"OpenSSL library could not be loaded". The container avoids this.

The first answer can take a minute or more while Ollama loads `llama3.2`.

The app connects as `rag_app` to `localhost,1435`, calls `dbo.find_similar_questions`
for retrieval (DiskANN via `VECTOR_SEARCH`, or exact kNN while the index is being
rebuilt), then calls Ollama `llama3.2` directly for answer generation. It prints which
search path served each question.

---

## Changing embedding models

1. Pull a different model in Ollama: `ollama pull mxbai-embed-large`
2. Follow Demo 03 Section 4b: register it as a second `EXTERNAL MODEL`, build a
   second embeddings table with the new `VECTOR(n)`, then repoint the proc

---

## Key SQL Server 2025 features used

| Feature | Demo |
|---|---|
| `VECTOR(n)` data type (float32) | 01, 02, 03 |
| `VECTOR(n, float16)` half-precision (preview) | 01 §1e |
| `AI_GENERATE_EMBEDDINGS` | 01 §3, 03 |
| `AI_GENERATE_CHUNKS` | 03 §1c |
| `VECTOR_DISTANCE` / `VECTOR_NORM` | 01 §4 |
| `CREATE VECTOR INDEX` (DiskANN, preview) | 02 §1 |
| `VECTOR_SEARCH` | 02 §2, 03 §2 |
| `SELECT TOP N WITH APPROXIMATE`, `sys.dm_db_vector_indexes` | 02 §5 (Azure only, shown not run) |
| `EXTERNAL MODEL` (Ollama via HTTPS) | 01 §3, 03 |
