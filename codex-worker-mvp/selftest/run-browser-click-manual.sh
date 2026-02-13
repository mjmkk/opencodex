#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/Apple/Dev/OpenCodex/codex-worker-mvp"
PORT_FILE="$(mktemp -t codex-worker-mvp-port.XXXXXX)"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$PORT_FILE" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$ROOT"

# Start local static server and capture the chosen port.
node selftest/serve-static.mjs >"$PORT_FILE" &
SERVER_PID="$!"

deadline=$((SECONDS + 5))
port=""
while [[ -z "$port" && $SECONDS -lt $deadline ]]; do
  if [[ -s "$PORT_FILE" ]]; then
    port="$(tr -d '\r\n' <"$PORT_FILE" | head -c 16)"
  fi
  sleep 0.05
done

if [[ -z "$port" ]]; then
  echo "ERROR: 未能获取静态服务端口" >&2
  exit 1
fi

url="http://127.0.0.1:${port}/"
echo "打开自测页: $url"

# Prefer Edge if installed; otherwise fall back to default browser.
if open -a "Microsoft Edge" "$url" 2>/dev/null; then
  :
else
  open "$url"
fi

echo "静态服务 PID=$SERVER_PID (Ctrl+C 退出并关闭服务)"
wait "$SERVER_PID"

