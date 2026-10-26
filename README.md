# SQL Server 2025 Vectors: Under the Hood and Into Production

This repo has every demo from my session **SQL Server 2025 Vectors: Under the Hood and
Into Production**. Everything runs on your laptop: SQL Server 2025 in Docker, Ollama for
embeddings and answers, and a small Python RAG app on top. No cloud services, no API keys.

Clone it, run one script, and you can work through the same demos I show on stage. Let's go.

> I built and tested this on SQL Server 2025 CU10 (17.0.5035.5) in Docker on an Apple M2
> with 24 GB of RAM, with Ollama running on the host. Every number in the demo scripts
> came from that setup. Your mileage will certainly vary.

---

## About the Session

SQL Server 2025's vector data type puts semantic search and retrieval-augmented
generation directly into a data estate you already operate and trust. That's a big
deal, and there's real engineering depth that is worth understanding before you ship
anything to production.

This session goes inside the vector data type: storage layout, index structures, and
what actually happens at query execution time when you ask SQL Server to perform a
similarity search. We'll be direct about where vector indexes help and where they don't.

Then we'll zoom out and build a working example application that puts all of it
together. If you're an architect, DBA, or developer building the next generation of
SQL Server applications, this one's for you. Let's go.

**You'll leave able to:**

1. Describe vector data type internals: storage, indexing, and query execution
2. Evaluate vector index performance and limitations at scale
3. Apply application architecture patterns to build a working application using
   SQL Server 2025's vector search capabilities

---

## What You'll Need

| Prerequisite | Notes |
|---|---|
| **Docker Desktop** | 4.x or later, running |
| **Ollama** | Installed from [ollama.com/download](https://ollama.com/download). `start.sh` pulls the models for you |
| **Disk space** | About 4 GB for the SQL Server image and the StackOverflow backup, plus 2 GB for `llama3.2` |
| **Disk for the scale test** | Optional. About 12 GB for the 1,000,000-row `StackOverflowScale` database (8 GB data file, plus a 3 GB backup in `backups/`) |
| **`mxbai-embed-large`** | Optional. Only for the model swap in Demo 03 §4b (`ollama pull mxbai-embed-large`, about 670 MB) |

You don't need Python or an ODBC driver on your machine. The RAG app runs in its own container.

> **Apple Silicon:** SQL Server 2025 runs as `linux/amd64` under Rosetta, so turn on
> Rosetta emulation in Docker Desktop (Settings → General → Use Rosetta).

---

## Getting Started

### Step 1: Start the stack

Clone the repo and run the start script:

```bash
git clone https://github.com/nocentino/vector-under-the-hood.git
cd vector-under-the-hood
./start.sh
```

Here's what `start.sh` does for you:

1. Starts Ollama if it isn't running, and pulls `nomic-embed-text` and `llama3.2`
2. Downloads the StackOverflow Mini backup (about 760 MB, one time)
3. Runs `docker compose up`, which starts SQL Server, restores the database, embeds the
   top 1,000 questions, and builds the DiskANN vector index

The first run takes 10 to 20 minutes. The `sql-init` container does the setup and exits
when it's done. You can watch it work:

```bash
docker logs -f sql-init
docker compose ps -a sql-init      # "Exited (0)" means you're ready
```

If it exits with anything other than 0, the log tells you which step failed. Running
`./start.sh` again is safe. It won't redo work that's already finished.

### Step 2: Grow the data to 10,000 rows

The stack starts with 1,000 embedded questions. That's not enough to see what a vector
index is good for. At 1,000 rows the index actually loses to a plain table scan, and
the numbers in Demo 02 assume 10,000 rows. So grow the data:

```bash
bash setup/expand-embeddings.sh
```

The script drops the vector index, embeds the next 9,000 highest-scored questions in
batches of 100, then rebuilds the index. If you stop it partway, run it again and it
picks up where it left off. If three batches in a row fail, it stops and shows you the
error. That's usually Ollama not running.

Here's how long things took on my M2 (CU10, Ollama on the host, October 2026):

| Step | Time |
|---|:---:|
| Embedding 100 questions | ~2 to 3 seconds |
| Growing to 10,000 rows | ~4 minutes |
| Building the vector index, 1,000 rows | ~11 seconds |
| Building the vector index, 10,000 rows | 10 to 12 seconds |
| First index build after a restart | up to ~6 minutes (an earlier, slower run; I didn't see it again) |

### Step 3: Build the scale database (optional, for Demo 02 §2b)

Demo 02 §2b measures exact search and the index at 1,000,000 rows. That lives in its
own database, `StackOverflowScale`, so Demo 03's drop-and-rebuild never touches it:

```bash
bash setup/build-scale-db.sh             # build it
bash setup/build-scale-db.sh --restore   # or restore the backup it wrote
```

Building takes about 80 minutes on my M2 (50 minutes to generate the rows and 27 minutes
for the index), and it's safe to stop and rerun. It writes a 3 GB backup to `backups/`,
so you only pay that once. The rows are synthetic: the 10,000 real embeddings from
StackOverflow, each with 100 noisy copies. Use it for timing, reads, and recall, not for
search quality.

### Step 4: Run the demos

Open the three demo scripts in SSMS or the MSSQL extension for VS Code, connect to
`localhost,1435` as `sa`, and run them in order. Each script explains what you're
looking at as you go. Run it a section at a time and read the comments.

### Step 5: Try the RAG app

Start the web UI, then open [http://localhost:8501](http://localhost:8501) and ask it a
programming question:

```bash
docker compose --profile app up rag-app-ui
```

Press `Ctrl+C` to stop it. [The RAG App](#the-rag-app) section below has the command-line
version and more detail.

---

## The Demos

Each demo lines up with one of the session's learning objectives. Start with the core
scripts. Optional deep dives live in separate files, so you can keep going when you want
more detail.

### Demo 01: Vector Internals ([demos/01-vector-internals.sql](demos/01-vector-internals.sql))

How a vector is stored and how SQL Server runs an exact similarity search.

| Section | What you'll see |
|---|---|
| 1a | The `VECTOR` type in `sys.types` and `sys.columns` |
| 1b | `DATALENGTH`: an 8-byte header plus 768 × 4 bytes, so 3,080 bytes per vector |
| 1b-2 | Page-level storage: the vector stays in the row, about 1.5 rows per page, and `DBCC PAGE` |
| 1c | What your client sees (a JSON array) versus what SQL Server stores (binary) |
| 2 | `AI_GENERATE_EMBEDDINGS` and the HTTPS round trip to Ollama |
| 3 | `VECTOR_DISTANCE` with cosine, euclidean, and dot; `VECTOR_NORM` |
| 4 | Exact kNN: the table scan and execution plan |

For the optional float16, filegroup, and distance deep dives, run
[demos/01-vector-internals-optional.sql](demos/01-vector-internals-optional.sql).

### Demo 02: Index Performance ([demos/02-index-performance.sql](demos/02-index-performance.sql))

What the DiskANN index is, what it costs, and where it helps and where it doesn't.

| Section | What you'll see |
|---|---|
| 1 | How DiskANN and its Vamana graph work, the build, and where the graph is stored |
| 1d | Which DiskANN version you're on, and why the `TOP_N` syntax here is the deprecated one |
| 2 | Reads and CPU for an exact scan versus the index, and how each one grows with row count |
| 2-plan | The execution plan: Vector Index Seek versus Clustered Index Scan |
| 2a | Scale: how exact kNN and ANN change as the row count grows |
| 2b | Scale past the corpus: 1,000,000 rows in `StackOverflowScale`, reads and timing against Microsoft's ~50,000-vector guidance, and recall with and without oversampling |
| 3 | Recall: averaged over 100 queries at K = 10 and K = 100, and what "at scale" means |
| 4a | The table goes read-only while the index exists (Msg 42231 and 42232) |
| 4b | A filter that silently returns zero rows, how to spot it, and how to fix it |
| 4c | The documented limits: INT clustered key, the latest-version 100-row minimum, no temp tables, no partitioning |

For filtered-search details, dimension limits, build diagnostics, and
the latest Azure DiskANN version, see
[demos/02-index-performance-optional.sql](demos/02-index-performance-optional.sql).

### Demo 03: Application Architecture ([demos/03-application-architecture.sql](demos/03-application-architecture.sql))

The patterns behind a working RAG app, then the app itself.

| Section | What you'll see |
|---|---|
| 1 | A separate embeddings table, and chunking long text with `AI_GENERATE_CHUNKS` |
| 2 | A search proc that uses the index and falls back to an exact search when it's gone |
| 3 | A least-privilege login for the app, and a live demo of it being denied |
| 4a | Loading new data: drop the index, embed, rebuild, with the app working the whole time |
| 4b | [OPTIONAL] Moving to a different embedding model side by side |
| 4c | Monitoring and staleness checks, run as `dba_monitor`, and what to add next |
| 5 | The full request flow, then the app answering questions |

---

## The RAG App

The app takes your question, asks SQL Server for the most similar StackOverflow
questions and their best answers, and hands that context to `llama3.2` to write an
answer. SQL Server does the embedding and the search. The app never touches a vector.
The procedure defaults to `AUTO`: it uses ANN when the index exists and exact kNN
when it doesn't. You can pass `@search_mode = 'ANN'` or `'KNN'` to force a path for
comparison; `ANN` returns Msg 50002 if the index is missing.

It runs in a container, so you don't need Python or an ODBC driver on your machine.
The image builds the first time you run it.

### The web UI

Start the web UI, then open [http://localhost:8501](http://localhost:8501) in your browser:

```bash
docker compose --profile app up rag-app-ui
```

Press `Ctrl+C` to stop it. Add `-d` to run it in the background, and stop it later with
`docker compose --profile app stop rag-app-ui`.

### The command line

```bash
# Ask one question
docker compose run --rm rag-app python demos/rag-app.py "how do I undo my last git commit?"

# Ask as many as you like
docker compose run --rm rag-app python demos/rag-app.py
```

The first answer can take a minute while Ollama loads `llama3.2`. After that it's faster.
The app also tells you whether SQL Server answered from the vector index (`ANN`) or
with an exact search (`kNN`).

> Want to run it straight on your Mac instead? Install the ODBC driver and
> `pip install -r requirements.txt`. On macOS, Microsoft's ODBC driver needs OpenSSL 3
> at `/opt/homebrew/opt/openssl`, and if that points at OpenSSL 4 you'll get "OpenSSL
> library could not be loaded". The container sidesteps all of that.

---

## Trying a Different Embedding Model

The stack uses `nomic-embed-text`, which produces 768-dimension vectors. Demo 03 §4b
walks you through moving to `mxbai-embed-large` (1,024 dimensions) side by side,
without taking the app down:

1. Pull the model: `ollama pull mxbai-embed-large`
2. Register it as a second `EXTERNAL MODEL`
3. Build a second embeddings table with `VECTOR(1024)` and its own index
4. Point the search proc at the new table

---

## Connection Details

| Setting | Value |
|---|---|
| Server | `localhost,1435` |
| SA password | `S0methingS@Str0ng!` |
| Database | `StackOverflow` (and `StackOverflowScale` if you built it) |
| App login | `rag_app` / `RagP@ss2025!` |
| Monitoring login | `dba_monitor` / `MonitorP@ss123!` (read-only, used in Demo 03 §4c) |

The stack uses port 1435 so it won't collide with a SQL Server you already have on 1433.
These passwords are for a local demo only. Don't reuse them anywhere real.

The app login can't read any table directly. It can run the two search procs and use
the embedding model, and it has `VIEW DEFINITION` on the embeddings table. That last
one is metadata only, and the search proc needs it to see the vector index. Demo 03
shows why.

---

## How It Fits Together

```
Your Mac
├── Ollama :11434          embeddings and answers, on your GPU
│
└── Docker Compose
    ├── config             one time: creates a self-signed TLS certificate
    ├── model-web          NGINX :443, forwards to Ollama over HTTPS
    ├── sql1               SQL Server 2025 on :1435, with the data, index, and procs
    ├── sql-init           one time: restores the database and sets everything up
    └── rag-app / rag-app-ui   optional: the RAG app and its web UI on :8501
```

SQL Server only calls embedding endpoints over HTTPS. Ollama speaks plain HTTP, so
NGINX sits in between and adds the TLS. That's the only reason `model-web` exists.

---

## SQL Server 2025 Features in These Demos

| Feature | Where |
|---|---|
| `VECTOR(n)` data type | All three demos |
| `VECTOR(n, float16)` half precision (preview) | Demo 01 optional Appendix B |
| `AI_GENERATE_EMBEDDINGS` | Demo 01 §2, Demo 03 |
| `AI_GENERATE_CHUNKS` | Demo 03 §1c |
| `VECTOR_DISTANCE` and `VECTOR_NORM` | Demo 01 §3 |
| `CREATE VECTOR INDEX` (DiskANN, preview) | Demo 02 §1 |
| `VECTOR_SEARCH` | Demo 02 §2, Demo 03 §2 |
| `CREATE EXTERNAL MODEL` with Ollama | Demo 01 §2, Demo 03 |
| `SELECT TOP (N) WITH APPROXIMATE`, `sys.dm_db_vector_indexes` | Demo 02 optional Appendix E, Azure only |

---

## Troubleshooting

Here are the problems I hit while building this, and what fixes them.

| What you see | What's going on |
|---|---|
| **Msg 31629**, "external rest endpoint execution exceeded the timeout" | Ollama isn't running, or the model is still loading. Warm it up with `curl -s http://localhost:11434/api/embed -d '{"model":"nomic-embed-text","input":"hi"}'` and try again. |
| **Msg 42231 or 42232** on INSERT, UPDATE, DELETE, or TRUNCATE | That's expected. On SQL Server 2025 a table is read-only while it has a vector index. Drop the index, load your data, rebuild it. Demo 03 §4a shows how. |
| **Msg 42266** on `CREATE VECTOR INDEX` | Latest-version indexes (Azure SQL) need at least 100 rows with non-NULL vectors. The earlier-version index on SQL Server 2025 doesn't enforce it. |
| **Msg 42274** on `VECTOR_SEARCH` | You're on a latest-version index (Azure SQL) and used `TOP_N`. Use `SELECT TOP (N) WITH APPROXIMATE` instead. See Demo 02 §1d. |
| **Msg 42227**, "Cannot find a vector index" | `VECTOR_SEARCH` needs a vector index on SQL Server 2025. Rebuild the index. |
| The app always says `kNN` | The vector index is missing, or the app login lost `VIEW DEFINITION` on `dbo.QuestionEmbeddings`. |
| `sql-init` exited with a non-zero code | Check `docker logs sql-init`. It's usually Ollama not being reachable from Docker. |
| SSMS says "'Vector Index Seek' is not a valid value for PhysicalOpType" | Your SSMS is older than the operator. Update it, or use the plan cache query in Demo 02 §2-plan. |
| Everything is slow right after Docker restarts | Nothing is cached yet. The first index build after a restart took me up to 6 minutes. Run it once and it settles down. |

---

## Stopping and Cleaning Up

```bash
./stop.sh           # stop the containers, keep the data
./stop.sh --wipe    # stop the containers and delete the data volume
```

Demo 03 §4a embeds 100 more questions every time you run it. If you want to start
fresh, run `./stop.sh --wipe`, then `./start.sh` and `bash setup/expand-embeddings.sh`.

---

## What's in the Repo

```
demos/        the three demo scripts, rag-app.py (CLI), and rag-app-ui.py (web UI)
setup/        init.sql (run by sql-init), expand-embeddings.sh, and build-scale-db.sh
config/       nginx.conf for the TLS proxy
certs/        generate_ssl.sh; the certificate is created on first start
backups/      StackOverflowMini.bak (downloaded by start.sh) and StackOverflowScale.bak
              (written by build-scale-db.sh), neither in git
docker-compose.yml, dockerfile.ssl, dockerfile.app, start.sh, stop.sh
```

---

## Wrapping Up

Everything in this repo runs on SQL Server 2025 and a laptop. Clone it, work through
the demos, change the queries, and try it with your own data. Let me know how it works
in your environment.
