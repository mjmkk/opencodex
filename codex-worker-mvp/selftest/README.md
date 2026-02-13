# Browser Click Selftest

这里提供两种自测方式：

1. Node 自测（已在当前环境执行）
- 验证状态机逻辑是否正确。
- 命令：
  ```bash
  cd /Users/Apple/Dev/OpenCodex/codex-worker-mvp
  npm test
  ```

2. 浏览器自动点击自测（依赖 Playwright 运行时）
- 命令：
  ```bash
  cd /Users/Apple/Dev/OpenCodex/codex-worker-mvp
  ./selftest/run-browser-click-playwright.sh
  ```
- 说明：
  - 返回 `PASS`：浏览器自动点击通过。
  - 返回 `SKIP`（退出码 2）：本机缺少离线可用的 `playwright-cli` 或浏览器运行时。

页面文件：
- `/Users/Apple/Dev/OpenCodex/codex-worker-mvp/selftest/browser-click-selftest.html`
