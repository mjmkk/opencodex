# API Reference

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
