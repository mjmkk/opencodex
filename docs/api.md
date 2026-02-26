# API Reference / API 参考

> Language / 语言：English below first, 中文在文末。

The `codex-worker-mvp` backend exposes three transport layers:
- **REST** — request/response for most operations
- **SSE** (Server-Sent Events) — real-time event streaming for chat
- **WebSocket** — bidirectional terminal I/O

## Authentication

All endpoints require a Bearer token header:

```
Authorization: Bearer <authToken>
```

The token is configured in `worker.config.json` and mirrored in iOS Settings.

---

## Threads

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/threads` | List all threads |
| POST | `/v1/threads` | Create a new thread |
| GET | `/v1/threads/:id` | Get thread details |
| POST | `/v1/threads/:id/archive` | Archive a thread |
| POST | `/v1/threads/:id/unarchive` | Unarchive a thread |

## Chat / Turns

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/threads/:id/turns` | Submit a user message, start a turn |
| GET | `/v1/threads/:id/events` | List events (with cursor pagination) |
| GET | `/v1/threads/:id/stream` | **SSE** — stream real-time events |
| POST | `/v1/threads/:id/approvals/:approvalId` | Approve or reject a tool use |

### SSE Event Types

| `type` | Description |
|--------|-------------|
| `message_start` | Assistant turn begins |
| `content_delta` | Incremental text chunk |
| `message_stop` | Assistant turn complete |
| `tool_use` | Tool invocation requiring approval |
| `tool_result` | Tool execution result |
| `error` | Stream error |
| `ping` | Keep-alive heartbeat |

## Terminal

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/terminals` | Open a terminal session for a thread |
| POST | `/v1/terminals/:id/resize` | Resize terminal (cols/rows) |
| POST | `/v1/terminals/:id/close` | Close terminal session |
| WS | `/v1/terminals/:id/stream` | **WebSocket** — bidirectional I/O |

### WebSocket Message Types (client → server)

| `type` | Payload | Description |
|--------|---------|-------------|
| `ping` | `{ clientTs }` | Heartbeat |
| `input` | `{ data: string }` | Keystroke data |
| `resize` | `{ cols, rows }` | Terminal resize |
| `detach` | — | Graceful disconnect |

### WebSocket Message Types (server → client)

| `type` | Payload | Description |
|--------|---------|-------------|
| `ready` | `{ sessionId, seq, ... }` | Session attached, includes replay |
| `output` | `{ seq, data }` | Terminal output chunk |
| `ping` | `{ serverTs }` | Server heartbeat |
| `pong` | `{ clientTs }` | Heartbeat reply |
| `error` | `{ code, message }` | Error |

## File System

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/fs/roots` | List allowed root directories |
| GET | `/v1/fs/tree` | Directory tree |
| GET | `/v1/fs/file` | Read file contents |
| POST | `/v1/fs/write` | Write file contents |
| GET | `/v1/fs/search` | Search files by name/content |

## Models

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/models` | List available AI models |

## Push Notifications

| Method | Path | Description |
|--------|------|-------------|
| POST | `/v1/push/devices/register` | Register APNs device token |
| DELETE | `/v1/push/devices/:token` | Unregister device |

## Health

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1/health` | Server health check |

---

## 中文速览

`codex-worker-mvp` 提供三类传输层：
- **REST（Representational State Transfer，表述性状态传输）**：普通请求/响应接口
- **SSE（Server-Sent Events，服务器发送事件）**：聊天实时事件流
- **WebSocket（全双工长连接）**：终端双向输入输出

### 认证

所有接口都需要 `Bearer Token`：

```http
Authorization: Bearer <authToken>
```

`authToken` 在 `worker.config.json` 配置，并与 iOS 设置页保持一致。

### 主要接口分组

- 线程：`/v1/threads`（列表、创建、详情、归档、恢复）
- 对话：`/v1/threads/:id/turns`、`/v1/threads/:id/events`、`/v1/threads/:id/stream`
- 审批：`/v1/threads/:id/approvals/:approvalId`
- 终端：`/v1/terminals`、`/v1/terminals/:id/resize`、`/v1/terminals/:id/close`、`/v1/terminals/:id/stream`（WebSocket）
- 文件系统：`/v1/fs/roots`、`/v1/fs/tree`、`/v1/fs/file`、`/v1/fs/write`、`/v1/fs/search`
- 模型：`/v1/models`
- 推送：`/v1/push/devices/register`、`/v1/push/devices/:token`
- 健康检查：`/v1/health`

### SSE 常见事件

- `message_start`：助手回复开始
- `content_delta`：增量文本片段
- `message_stop`：助手回复结束
- `tool_use`：触发工具调用（可能需要审批）
- `tool_result`：工具执行结果
- `error`：流异常
- `ping`：心跳保活
