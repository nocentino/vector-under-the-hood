#!/bin/bash
# Start or stop the extra Ollama instances behind the load-balanced endpoint.
#
#   bash setup/ollama-lb.sh start    # instances on 11435-11437 (11434 is your normal Ollama)
#   bash setup/ollama-lb.sh stop
#
# model-web:444 spreads requests across 11434-11437 (config/nginx.conf). Use it
# for bulk loads like setup/build-scale-db.sh. The demos stay on model-web:443,
# which only needs the normal Ollama on 11434. Based on
# https://github.com/nocentino/ollama-lb-sql
#
# The win comes from concurrency: run several SQL sessions at once, each
# embedding its own slice of rows. On my M2, 8 sessions through :444 embedded
# about 4 ms per row against about 17 ms for one session through :443.

set -euo pipefail

PORTS="11435 11436 11437"
MODEL="nomic-embed-text"
LOGDIR="${TMPDIR:-/tmp}"

OLLAMA_BIN="$(command -v ollama || true)"
if [ -z "$OLLAMA_BIN" ] && [ -x /Applications/Ollama.app/Contents/Resources/ollama ]; then
    OLLAMA_BIN=/Applications/Ollama.app/Contents/Resources/ollama
fi
if [ -z "$OLLAMA_BIN" ]; then
    echo "ollama not found. Install it from https://ollama.com/download" >&2
    exit 1
fi

case "${1:-}" in
  start)
    for p in $PORTS; do
        if curl -s -o /dev/null "http://127.0.0.1:$p/api/version"; then
            echo "Ollama already listening on $p"
            continue
        fi
        OLLAMA_HOST="127.0.0.1:$p" nohup "$OLLAMA_BIN" serve > "$LOGDIR/ollama-$p.log" 2>&1 &
        echo "Started Ollama on $p (log: $LOGDIR/ollama-$p.log)"
    done
    sleep 3
    # Load the model on every instance so the first real request isn't slow.
    for p in 11434 $PORTS; do
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$p/api/embed" \
               -d "{\"model\":\"$MODEL\",\"input\":\"warm up\"}" || true)
        echo "  $p: HTTP $code"
    done
    ;;
  stop)
    for p in $PORTS; do
        pid=$(lsof -tiTCP:"$p" -sTCP:LISTEN 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill $pid && echo "Stopped Ollama on $p"
        fi
    done
    ;;
  *)
    echo "usage: bash setup/ollama-lb.sh start|stop" >&2
    exit 1
    ;;
esac
