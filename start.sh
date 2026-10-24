#!/usr/bin/env bash
# Start the "SQL Server 2025 Vectors: Under the Hood and Into Production" stack.
set -euo pipefail

cd "$(dirname "$0")"

EMBED_MODEL="nomic-embed-text"
LLM_MODEL="llama3.2"

# ── Host Ollama ───────────────────────────────────────────────────────────────
# Ollama runs on the HOST (GPU-accelerated). NGINX in the stack reverse-proxies
# to it at host.docker.internal:11434 and adds the TLS that SQL Server 2025's
# EXTERNAL MODEL needs.
if command -v ollama >/dev/null 2>&1; then
    # Start the server if it's not already answering.
    if ! ollama list >/dev/null 2>&1; then
        echo "Ollama is installed but the server is not running. Starting it..."
        # OLLAMA_NUM_GPU=999  → use all available GPU layers (Metal on Apple Silicon,
        #                        CUDA on NVIDIA). macOS already defaults to GPU, but
        #                        being explicit means no CPU-only fallback.
        OLLAMA_NUM_GPU=999 OLLAMA_HOST=0.0.0.0 ollama serve >/tmp/ollama-serve.log 2>&1 &
        # Give the server up to 10s to respond.
        for i in $(seq 1 10); do
            sleep 1
            ollama list >/dev/null 2>&1 && break
            [[ $i -eq 10 ]] && echo "WARNING: ollama serve did not respond after 10s. Check /tmp/ollama-serve.log"
        done
    fi

    # Show which hardware Ollama is using for loaded models:
    echo "Ollama GPU status:"
    ollama ps 2>/dev/null || true

    if ! ollama list 2>/dev/null | grep -q "$EMBED_MODEL"; then
        echo "Pulling $EMBED_MODEL on the host (one time)..."
        ollama pull "$EMBED_MODEL"
    fi
    echo "Host Ollama ready ($EMBED_MODEL present)."

    # Pull the generation model for rag-app.py if you don't have it yet.
    if ! ollama list 2>/dev/null | grep -q "$LLM_MODEL"; then
        echo "Pulling $LLM_MODEL for rag-app.py (one time)..."
        ollama pull "$LLM_MODEL"
    fi
    echo "Host Ollama ready ($LLM_MODEL present)."
else
    echo "WARNING: 'ollama' not found on the host. Install it from https://ollama.com, then:"
    echo "    ollama pull $EMBED_MODEL   # embedding model (required)"
    echo "    ollama pull $LLM_MODEL     # generation model for rag-app.py"
fi

# If your containers can't reach host Ollama (non-Docker Desktop runtimes like
# OrbStack or plain Linux), make Ollama listen on all interfaces:
#     launchctl setenv OLLAMA_HOST "0.0.0.0"   # then restart Ollama
# Docker Desktop already reaches the host's localhost via host.docker.internal.

# ── StackOverflow sample database ────────────────────────────────────────────
# ~759 MB, too big to commit to git. It's downloaded once to backups/ and reused.
# The download runs on the HOST so corporate TLS inspection (Zscaler etc.) doesn't get in the way.
BAK="backups/StackOverflowMini.bak"
BAK_URL="https://github.com/BrentOzarULTD/Stack-Overflow-Database/releases/download/20230114/StackOverflowMini.bak"
if [ ! -f "$BAK" ]; then
    echo "Downloading the StackOverflow sample database (~759 MB, one time)..."
    mkdir -p backups
    curl -L --fail -o "$BAK" "$BAK_URL"
fi
echo "StackOverflow backup present ($(du -h "$BAK" 2>/dev/null | cut -f1))."

# ── Start the stack ───────────────────────────────────────────────────────────
echo "Starting the stack (SQL Server 2025 + NGINX)..."
docker compose up --detach

cat <<'EOF'

Containers are starting.
The first run takes a few minutes: it pulls images, restores the StackOverflow
database, and embeds a curated set of questions via host Ollama.

Watch the one-time setup finish:
    docker compose logs -f sql-init      # exits 0 when the database is ready
    docker compose ps                    # sql1 should be healthy

Connect your SQL client:
    Server:   localhost,1435
    Login:    sa / S0methingS@Str0ng!

Then open the demos in order:
    demos/01-vector-internals.sql        # storage layout, catalog, query execution
    demos/02-index-performance.sql       # DiskANN, IO stats, recall, limitations
    demos/03-application-architecture.sql# schema design, RAG procs, security

Run the Python RAG app:
    docker compose run --rm rag-app python demos/rag-app.py "how do I undo my last git commit?"
    docker compose --profile app up rag-app-ui      # http://localhost:8501
EOF
