#!/bin/bash
# Thin contract smoke for Rust gateway :1317
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/dottie-gateway"
if [ ! -x "$BIN" ]; then
  BIN="$ROOT/target/release/dottie-gateway"
fi
if [ ! -x "$BIN" ]; then
  (cd "$ROOT" && cargo build --release)
  BIN="$ROOT/target/release/dottie-gateway"
fi

export DOTTIE_GATEWAY_DIR="$ROOT"
export PORT=1317
mkdir -p "$HOME/.dottie"
TOKEN_FILE="$HOME/.dottie/agent_token"
if [ ! -s "$TOKEN_FILE" ]; then
  echo "smoke-token-$(date +%s)" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi
TOKEN="$(tr -d '\n' < "$TOKEN_FILE")"

# Free port
if lsof -ti TCP:1317 -sTCP:LISTEN >/dev/null 2>&1; then
  lsof -ti TCP:1317 -sTCP:LISTEN | xargs kill -TERM 2>/dev/null || true
  sleep 1
fi

"$BIN" >/tmp/dottie-gateway-smoke.log 2>&1 &
PID=$!
trap 'kill -TERM $PID 2>/dev/null || true' EXIT

for i in $(seq 1 50); do
  if curl -sf http://127.0.0.1:1317/health >/dev/null; then
    break
  fi
  sleep 0.1
done

echo "== /health =="
curl -sf http://127.0.0.1:1317/health | head -c 200
echo
echo "== auth reject =="
code=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:1317/system/status || true)
test "$code" = "401"
echo "got $code (expect 401)"
echo "== auth ok =="
curl -sf -H "Authorization: Bearer $TOKEN" http://127.0.0.1:1317/system/status | head -c 300
echo
echo "SMOKE_OK"
