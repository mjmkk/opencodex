# codex-worker-mvp

一个“第一版最简流程”的 Mac Worker：
- 对接官方 `codex app-server`（JSON-RPC 2.0 协议）
- 对外提供 `REST`（Representational State Transfer，资源风格 HTTP 接口）
- 提供 `SSE`（Server-Sent Events，服务端推送事件）
- 支持审批请求回传与 `cursor`（游标）续流

## 1. 运行

```bash
cd /Users/Apple/Dev/OpenCodex/codex-worker-mvp
npm start
```

默认端口：`8787`

## 2. 环境变量

- `PORT`：HTTP 端口，默认 `8787`
- `WORKER_TOKEN`：可选，开启 Bearer 鉴权（下面有解释）
- `WORKER_PROJECT_PATHS`：可选，项目白名单，逗号分隔
- `WORKER_DEFAULT_PROJECT`：可选，默认项目路径
- `CODEX_COMMAND`：可选，Codex 可执行文件，默认 `codex`
- `CODEX_APP_SERVER_ARGS`：可选，app-server 启动参数，逗号分隔；默认 `app-server`
- `WORKER_EVENT_RETENTION`：可选，单任务保留事件条数，默认 `2000`
- `WORKER_DB_PATH`：可选，SQLite 数据库路径；默认 `./data/worker.db`

### WORKER_TOKEN 是什么？

`WORKER_TOKEN` 是 Worker 对外 HTTP API 的 **Bearer Token（请求鉴权令牌）**。

- 作用：防止别人直接访问你的 Worker API（例如同一局域网里）。
- 形式：你自己随便定一个随机字符串，例如 `devtoken123`。
- 使用方式：
  - 启动 Worker 时设置：`WORKER_TOKEN=devtoken123 npm start`
  - 客户端请求时带上 HTTP Header：`Authorization: Bearer devtoken123`
  - Web UI（`/`）右上角的 `Token` 输入框就是填这个。
- 只在本机测试：不要设置 `WORKER_TOKEN`（或设为空），就不需要填。

## 3. 最小 API

- `GET /health`
- `GET /v1/projects`
- `POST /v1/threads`
- `GET /v1/threads`
- `POST /v1/threads/{tid}/activate`
- `POST /v1/threads/{tid}/turns`
- `GET /v1/jobs/{jid}`
- `GET /v1/jobs/{jid}/events?cursor=N`（支持 JSON 与 SSE）
- `POST /v1/jobs/{jid}/approve`
- `POST /v1/jobs/{jid}/cancel`

## 4. 审批决策值

`POST /v1/jobs/{jid}/approve` 请求体：

```json
{
  "approvalId": "appr_xxx",
  "decision": "accept | accept_for_session | accept_with_execpolicy_amendment | decline | cancel",
  "execPolicyAmendment": ["git", "push"]
}
```

说明：
- `accept_with_execpolicy_amendment` 仅用于命令审批。
- 该决策下必须提供非空 `execPolicyAmendment`。

## 5. 自测

```bash
cd /Users/Apple/Dev/OpenCodex/codex-worker-mvp
npm test
```

完整自测（覆盖：单元/集成/系统/场景）：

```bash
cd /Users/Apple/Dev/OpenCodex/codex-worker-mvp
npm run test:all
```
