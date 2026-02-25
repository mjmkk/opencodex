# codex-worker-mvp

一个“第一版最简流程”的 Mac Worker：
- 对接官方 `codex app-server`（JSON-RPC 2.0 协议）
- 对外提供 `REST`（Representational State Transfer，资源风格 HTTP 接口）
- 提供 `SSE`（Server-Sent Events，服务端推送事件）
- 支持审批请求回传与 `cursor`（游标）续流

## 0. 依赖边界（重要）

- 本目录代码（`codex-worker-mvp`）完整开源，负责协议转换、状态编排与本地缓存。
- `codex app-server` 为外部运行时依赖，不在本仓库内分发。
- 启动本 Worker 前必须保证本机可执行 `codex app-server`。
- 若暂时没有 app-server 权限，仍可运行本仓库的单元测试（含 fake-rpc 覆盖），并参与非运行时改动贡献。

## 1. 快速开始（无门槛）

下面按「第一次在新机器启动」来写，只需 3 步。

### 第 1 步：进入项目

```bash
cd /Users/chenken/Documents/opencodex/codex-worker-mvp
```

### 第 2 步：准备配置文件

```bash
cp worker.config.example.json worker.config.json
```

`worker.config.json` 至少确认这几个字段：

- `port`：Worker 监听端口，默认 `8787`
- `rpc.command`：通常是 `codex`
- `rpc.args`：通常是 `["app-server"]`
- `rpc.cwd`：Codex 工作目录（建议填你的 OpenCodex 根目录）

最小可用示例：

```json
{
  "port": 8787,
  "rpc": {
    "command": "codex",
    "args": ["app-server"],
    "cwd": "/Users/chenken/Documents/opencodex"
  },
  "tailscaleServe": {
    "enabled": true,
    "service": "svc:opencodex",
    "path": "/"
  }
}
```

### 第 3 步：启动 Worker

```bash
npm start -- --config ./worker.config.json
```

也支持环境变量方式：

```bash
WORKER_CONFIG=./worker.config.json npm start
```

默认健康检查：

```bash
curl http://127.0.0.1:8787/health
```

## 1.1 Tailscale HTTPS 访问（iOS 常用）

如果 iOS 端要访问 `https://<device>.tail3c834b.ts.net`，需要在该 Mac 上启用 Tailscale Serve，把 443 映射到本地 Worker（默认 `127.0.0.1:8787`）。

本项目已支持在启动时按配置自动收敛 Serve（幂等）：

```json
{
  "tailscaleServe": {
    "enabled": true,
    "service": "svc:opencodex",
    "path": "/"
  }
}
```

字段说明：

- `enabled`：`true` 时启动 Worker 会自动对齐 Serve 配置
- `service`：默认 `svc:opencodex`；填 `svc:xxx` 表示只改该 service；显式填 `null` 表示节点级 Serve
- `path`：挂载路径，`/` 表示根路径，也可用 `/codex` 等子路径

常见编排示例：

- 默认 service 根路径：`service = "svc:opencodex"`、`path = "/"` -> 只改 `svc:opencodex` 的根路径
- 默认 service 子路径：`service = "svc:opencodex"`、`path = "/codex"` -> 只改 `svc:opencodex` 的 `/codex`
- 节点级挂载：`service = null`、`path = "/"` -> `https://<device>.ts.net/` 到 Worker

查看当前 Serve 状态：

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status
```

期望看到类似：

```text
https://mac-mini.tail3c834b.ts.net (tailnet only)
|-- / proxy http://127.0.0.1:8787
```

### 关闭映射（手动）

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --https=443 off
```

### 持久化与幂等

- Serve 的真实状态保存在 Tailscale 自身，不在仓库文件里。
- 本项目只负责“把目标状态声明在 `worker.config.json`，并在启动时反复收敛到该状态”。
- 同样配置重复启动不会产生重复规则。
- 改了 `service/path/port` 后，下次启动会更新到新目标。

## 代码结构（可扩展）

- `src/index.js`：进程启动与依赖装配（配置、RPC、存储、HTTP）。
- `src/http-server.js`：纯 API 网关层（REST + SSE），不承载业务状态机。
- `src/worker-service.js`：核心编排层（线程/任务/审批状态机）。
- `src/worker-service/shared.js`：跨领域常量与基础纯函数（状态枚举、标准化、时间与字符串处理）。
- `src/worker-service/approval.js`：审批决策映射（API 入参 -> app-server RPC 格式）。
- `src/worker-service/thread-events.js`：线程历史分页与回放事件构建。
- `src/sqlite-store.js`：SQLite 持久化适配层（缓存与断线恢复）。

## 2. 配置（推荐）

后端配置优先级（高 -> 低）：

1. 启动参数：`--config` / `-c`
2. 环境变量
3. 配置文件（JSON）
4. 内置默认值

配置文件示例：`worker.config.example.json`

可用字段（JSON）：

- `port`：HTTP 端口（默认 `8787`）
- `authToken`：可选，Bearer 鉴权令牌
- `projectPaths`：可选，项目候选目录数组（用于 `/v1/projects` 展示）
- `defaultProjectPath`：可选，默认项目路径
- `eventRetention`：可选，单任务事件保留条数（最小 `100`）
- `dbPath`：可选，SQLite 路径
- `codexHome`：可选，Codex 数据目录（线程导入导出使用，默认 `~/.codex`）
- `threadExportDir`：可选，线程导出包目录（默认系统临时目录）
- `terminal.enabled`：可选，是否启用远端终端能力（默认 `false`）
- `terminal.shell`：可选，终端 Shell 路径（默认 `/bin/zsh`）
- `terminal.idleTtlMs`：可选，终端空闲回收毫秒；仅在“无客户端 + 无前台命令 + 无后台任务”时回收
- `terminal.maxSessions`：可选，终端会话上限（默认 `64`）
- `terminal.maxInputBytes`：可选，单次输入最大字节（默认 `32768`）
- `terminal.maxScrollbackBytes`：可选，终端输出缓存上限字节（默认 `2097152`）
- `terminal.heartbeatMs`：可选，终端心跳/巡检间隔毫秒（默认 `15000`）
- `tailscaleServe.enabled`：可选，是否启用 Tailscale Serve 自动收敛（默认 `false`）
- `tailscaleServe.service`：可选，Serve service 名称（默认 `svc:opencodex`；显式 `null` 表示节点级 Serve）
- `tailscaleServe.path`：可选，挂载路径（默认 `/`）
- `rpc.command`：可选，Codex 可执行文件（默认 `codex`）
- `rpc.args`：可选，app-server 参数数组（默认 `["app-server"]`）
- `rpc.cwd`：可选，Codex 子进程工作目录
- `apns.*`：可选，APNs 推送配置

说明：配置文件中的相对路径会按“配置文件所在目录”解析。

## 3. 环境变量

- `PORT`：HTTP 端口，默认 `8787`
- `WORKER_CONFIG`：可选，JSON 配置文件路径（也可用 `--config`）
- `WORKER_TOKEN`：可选，开启 Bearer 鉴权（下面有解释）
- `WORKER_PROJECT_PATHS`：可选，项目候选目录，逗号分隔（用于 `/v1/projects` 展示）
- `WORKER_DEFAULT_PROJECT`：可选，默认项目路径
- `CODEX_COMMAND`：可选，Codex 可执行文件，默认 `codex`
- `CODEX_APP_SERVER_ARGS`：可选，app-server 启动参数，逗号分隔；默认 `app-server`
- `WORKER_EVENT_RETENTION`：可选，单任务保留事件条数，默认 `2000`
- `WORKER_DB_PATH`：可选，SQLite 数据库路径；默认 `./data/worker.db`
- `WORKER_CODEX_HOME`：可选，Codex 数据目录；默认 `~/.codex`
- `WORKER_THREAD_EXPORT_DIR`：可选，线程导出包目录；默认系统临时目录
- `WORKER_TERMINAL_ENABLED`：可选，是否启用终端能力（`true/false`）
- `WORKER_TERMINAL_SHELL`：可选，终端 Shell 路径；默认 `/bin/zsh`
- `WORKER_TERMINAL_IDLE_TTL_MS`：可选，终端空闲回收毫秒；默认 `1200000`
- `WORKER_TERMINAL_MAX_SESSIONS`：可选，终端会话上限；默认 `64`
- `WORKER_TERMINAL_MAX_INPUT_BYTES`：可选，单次输入最大字节；默认 `32768`
- `WORKER_TERMINAL_MAX_SCROLLBACK_BYTES`：可选，终端输出缓存上限；默认 `2097152`
- `WORKER_TERMINAL_HEARTBEAT_MS`：可选，终端心跳/巡检间隔毫秒；默认 `15000`
- `APNS_ENABLED`：可选，是否启用 APNs 推送（`true/false`）
- `APNS_TEAM_ID`：可选，Apple Team ID（启用 APNs 时必填）
- `APNS_KEY_ID`：可选，APNs Key ID（启用 APNs 时必填）
- `APNS_BUNDLE_ID`：可选，App Bundle ID（启用 APNs 时必填）
- `APNS_KEY_PATH`：可选，`.p8` 私钥文件路径（与 `APNS_PRIVATE_KEY` 二选一）
- `APNS_PRIVATE_KEY`：可选，`.p8` 私钥内容（支持 `\n`，与 `APNS_KEY_PATH` 二选一）
- `APNS_DEFAULT_ENV`：可选，默认推送环境（`sandbox`/`production`，默认 `sandbox`）

### WORKER_TOKEN 是什么？

`WORKER_TOKEN` 是 Worker 对外 HTTP API 的 **Bearer Token（请求鉴权令牌）**。

- 作用：防止别人直接访问你的 Worker API（例如同一局域网里）。
- 形式：你自己随便定一个随机字符串，例如 `devtoken123`。
- 使用方式：
  - 启动 Worker 时设置：`WORKER_TOKEN=devtoken123 npm start`
  - 客户端请求时带上 HTTP Header：`Authorization: Bearer devtoken123`
- 只在本机测试：不要设置 `WORKER_TOKEN`（或设为空），就不需要填。

## 4. 最小 API

- `GET /health`
- `GET /v1/projects`
- `GET /v1/models`
- `POST /v1/threads`
- `GET /v1/threads`
- `POST /v1/threads/{tid}/activate`
- `POST /v1/threads/{tid}/archive`
- `POST /v1/threads/{tid}/export`
- `POST /v1/threads/import`
- `GET /v1/threads/{tid}/terminal`
- `POST /v1/threads/{tid}/terminal/open`
- `POST /v1/terminals/{sid}/resize`
- `POST /v1/terminals/{sid}/close`
- `WS /v1/terminals/{sid}/stream?fromSeq=N`
- `POST /v1/threads/{tid}/turns`
- `GET /v1/jobs/{jid}`
- `GET /v1/jobs/{jid}/events?cursor=N`（支持 JSON 与 SSE）
- `POST /v1/jobs/{jid}/approve`
- `POST /v1/jobs/{jid}/cancel`
- `POST /v1/push/devices/register`
- `POST /v1/push/devices/unregister`

## 5. 审批决策值

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

## 6. 线程导入导出

`POST /v1/threads/{tid}/export` 请求体（可选）：

```json
{
  "exportDir": "/tmp/codex-thread-exports"
}
```

返回示例：

```json
{
  "export": {
    "exportId": "texp_20260223-120000_abcd1234",
    "packagePath": "/tmp/codex-thread-exports/texp_20260223-120000_abcd1234.json",
    "sourceThreadId": "019c....",
    "sourceRelativePath": "sessions/2026/02/20/rollout-....jsonl",
    "sizeBytes": 3920843
  }
}
```

`POST /v1/threads/import` 请求体：

```json
{
  "packagePath": "/tmp/codex-thread-exports/texp_20260223-120000_abcd1234.json"
}
```

说明：
- 导入总是创建新线程 ID（不会覆盖原线程）。
- 导入成功后会写入 `session_index.jsonl`，并尝试激活线程。

## 7. 测试

```bash
cd /Users/chenken/Documents/opencodex/codex-worker-mvp
npm test
```

完整测试（当前等同于 `npm test`）：

```bash
cd /Users/chenken/Documents/opencodex/codex-worker-mvp
npm run test:all
```
