#!/usr/bin/env bash
# Stops the stack.
# Pass --wipe to delete the SQL data volume too (you'll get a fresh restore +
# re-embedding on the next start). Host Ollama and the downloaded .bak stay put.
set -euo pipefail

if [[ "${1:-}" == "--wipe" ]]; then
    echo "Stopping and deleting the SQL data volume (fresh restore + re-embed next start)..."
    docker compose down --volumes --remove-orphans
else
    echo "Stopping containers (data is kept). Use './stop.sh --wipe' for a clean reset."
    docker compose down
fi
