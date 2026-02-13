#!/usr/bin/env bash
set -euo pipefail

# Playwright CLI = Playwright 命令行工具（通过 skill 包装脚本调用）
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PWCLI="$CODEX_HOME/skills/playwright/scripts/playwright_cli.sh"

if [[ ! -x "$PWCLI" ]]; then
  echo "ERROR: Playwright skill wrapper 不存在或不可执行: $PWCLI" >&2
  exit 1
fi

# 清理可能残留的 session，避免 socket 冲突影响本次自测。
"$PWCLI" close-all >/dev/null 2>&1 || true

# playwright-cli 默认会阻止 file://，所以我们起一个本地 HTTP 静态服务。
PORT_FILE="$(mktemp)"
cleanup() {
  rm -f "$PORT_FILE" || true
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  "$PWCLI" close-all >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 启动静态服务并拿到端口
node /Users/Apple/Dev/OpenCodex/codex-worker-mvp/selftest/serve-static.mjs >"$PORT_FILE" &
SERVER_PID=$!

# 等端口文件出现内容
for _ in $(seq 1 50); do
  if [[ -s "$PORT_FILE" ]]; then
    break
  fi
  sleep 0.05
done

PORT="$(cat "$PORT_FILE" | tr -d '\n' | tr -d '\r' || true)"
if [[ -z "$PORT" ]]; then
  echo "FAIL: 未能启动本地静态服务" >&2
  exit 1
fi

URL="http://127.0.0.1:${PORT}/browser-click-selftest.html"
SESSION="s$$"

# 先清理旧 session，避免 socket 冲突。
"$PWCLI" --session "$SESSION" close >/dev/null 2>&1 || true

"$PWCLI" --session "$SESSION" open --browser msedge "$URL"
"$PWCLI" --session "$SESSION" run-code 'async (page) => { await page.click("#start-btn"); await page.check("#confirm-check"); await page.click("#finish-btn"); }'
RESULT="$("$PWCLI" --session "$SESSION" eval 'document.querySelector("#result")?.textContent?.trim() || ""')"
STATUS="$("$PWCLI" --session "$SESSION" eval 'document.querySelector("#status-text")?.textContent?.trim() || ""')"
"$PWCLI" --session "$SESSION" close

if [[ "$RESULT" != *"PASS"* || "$STATUS" != *"PASS"* ]]; then
  echo "FAIL: 结果不符合预期，status=$STATUS result=$RESULT" >&2
  exit 1
fi

echo "PASS: 浏览器自动点击自测通过"
