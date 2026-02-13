#!/usr/bin/env bash
set -euo pipefail

# 浏览器自测（核心 MVP）：启动 worker 并打开内置 UI，
# UI 支持 “自测模式：自动接受审批”，用于验证 Thread/Job/SSE/Approval 闭环。

ROOT="/Users/Apple/Dev/OpenCodex/codex-worker-mvp"

pick_port() {
  node -e 'const net=require("net");const s=net.createServer();s.listen(0,"127.0.0.1",()=>{const p=s.address().port;console.log(p);s.close();});'
}

PORT="$(pick_port | tr -d '\r\n')"
URL="http://127.0.0.1:${PORT}/"

cleanup() {
  if [[ -n "${WORKER_PID:-}" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
    kill "$WORKER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

cd "$ROOT"

export PORT
export WORKER_PROJECT_PATHS="/Users/Apple/Dev/OpenCodex"
export WORKER_DEFAULT_PROJECT="/Users/Apple/Dev/OpenCodex"
unset WORKER_TOKEN

node src/index.js &
WORKER_PID="$!"

echo "打开核心 MVP 自测台: $URL"
if open -a "Microsoft Edge" "$URL" 2>/dev/null; then
  :
else
  open "$URL"
fi

echo "worker PID=$WORKER_PID (Ctrl+C 退出并关闭 worker)"
wait "$WORKER_PID"

