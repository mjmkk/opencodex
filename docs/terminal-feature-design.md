# iOS 半屏远端终端功能详细设计（TermAway 思路 + codex-worker-mvp 风格）

## English Summary

This document describes the half-screen remote terminal feature for iOS:

1. iOS connects to Worker via WebSocket for low-latency bidirectional stream.
2. Worker hosts a PTY-backed `/bin/zsh -i` shell on Mac and relays terminal I/O.
3. Terminal sessions are isolated by `threadId` and default to each thread's `cwd`.
4. Chat pipeline and terminal pipeline are intentionally decoupled for reliability and maintainability.

## 0. 结论

本功能采用“**Mac 侧终端网关 + iOS 侧终端面板**”方案：

1. iOS 通过 `WebSocket（全双工网络通信协议）` 与 Worker 建立终端流连接。
2. Worker 使用 `PTY（Pseudo Terminal，伪终端）` 在 Mac 上启动 `/bin/zsh -i`，并将输入输出实时透传。
3. 终端会话按 `threadId` 隔离，默认绑定该线程的 `cwd（Current Working Directory，当前工作目录）`。
4. 聊天与终端解耦：终端不经过 Codex 审批链路，属于“直接远端 Shell 通道”。

该方案参考了 `TermAway` 的核心思路（`node-pty + WebSocket + scrollback + 心跳 + 多端附着`），并适配现有 `codex-worker-mvp` 的 REST 风格与错误模型。

---

## 1. 背景与目标

### 1.1 业务目标

1. 在 iOS 前端增加“终端开关”按钮。
2. 打开后显示半屏终端（默认占可用高度 50%）。
3. 终端操作的是 Mac 上的 `zsh`，与 iOS 本地系统无关。
4. 每个线程有自己的终端上下文，默认工作目录是该线程 `cwd`。

### 1.2 非目标（本期不做）

1. 不做 SSH 跳板和多主机路由。
2. 不做终端命令级审批（终端本身即高权限通道）。
3. 不做 tmux 深度集成。

---

## 2. 设计原则

1. **线程上下文一致性优先**：终端会话与 `threadId` 绑定，避免跨线程污染。
2. **低延迟优先**：输入输出走 WebSocket，不复用 `SSE（Server-Sent Events，服务器发送事件）`。
3. **可恢复优先**：支持断线重连与输出续传（基于 `seq`）。
4. **最小侵入**：尽量不改现有聊天/审批主链路。
5. **生产可控**：默认关闭开关，显式启用；有超时回收、限流、日志与错误码。

---

## 3. 总体架构

```mermaid
flowchart LR
  subgraph iOS[iOS App]
    Chat[聊天区]
    TerminalPanel[半屏终端面板]
    TFeature[TerminalFeature(TCA)]
  end

  subgraph Worker[codex-worker-mvp]
    HTTP[REST API]
    WS[WebSocket Stream]
    TSvc[TerminalService]
    TMgr[TerminalManager]
    PTY[Mac PTY /bin/zsh -i]
  end

  Chat -->|切线程| TFeature
  TerminalPanel -->|open/close/resize| HTTP
  TerminalPanel <-->|input/output| WS

  HTTP --> TSvc --> TMgr --> PTY
  WS --> TMgr
```

说明：

1. `TerminalService` 负责会话生命周期与权限校验。
2. `TerminalManager` 负责 `PTY`、缓冲、广播、心跳、回收。
3. iOS 只持有“UI 状态 + 会话句柄 + 输出缓冲”，不持久化终端历史为权威数据。

---

## 4. 后端详细设计（codex-worker-mvp）

### 4.1 新增模块

1. `src/terminal-manager.js`
2. `src/terminal-service.js`
3. `src/terminal-types.js`（可选，放常量与错误码）

并在以下文件接入：

1. `src/worker-service.js`：挂载终端相关能力。
2. `src/http-server.js`：新增终端 REST + WS 路由。
3. `src/index.js`：注入终端配置。
4. `src/config.js`：新增配置项。

### 4.2 配置项

新增 `worker.config.json` 字段：

```json
{
  "terminal": {
    "enabled": true,
    "shell": "/bin/zsh",
    "idleTtlMs": 1200000,
    "maxSessions": 64,
    "maxInputBytes": 32768,
    "maxScrollbackBytes": 2097152,
    "heartbeatMs": 15000
  }
}
```

环境变量覆盖：

1. `WORKER_TERMINAL_ENABLED`
2. `WORKER_TERMINAL_SHELL`
3. `WORKER_TERMINAL_IDLE_TTL_MS`
4. `WORKER_TERMINAL_MAX_SESSIONS`
5. `WORKER_TERMINAL_MAX_INPUT_BYTES`
6. `WORKER_TERMINAL_MAX_SCROLLBACK_BYTES`
7. `WORKER_TERMINAL_HEARTBEAT_MS`

### 4.3 会话模型

```ts
TerminalSession {
  sessionId: string;
  threadId: string;
  cwd: string;
  shell: string; // /bin/zsh
  pid: number;
  cols: number;
  rows: number;
  status: "running" | "exited" | "closing";
  createdAt: string;
  lastActiveAt: string;
  exitCode: number | null;
  signal: string | null;
  nextSeq: number; // output seq
}
```

内存结构：

1. `threadId -> sessionId`（每线程最多一个活动会话）
2. `sessionId -> session`（主会话索引）
3. `sessionId -> ringBuffer[{seq, data}]`（用于重连补发）
4. `sessionId -> Set<WebSocketClient>`（多端附着）

### 4.4 线程与 cwd 绑定规则

1. `open` 请求不允许客户端传 `cwd`。
2. 服务端从线程信息读取 `cwd`：
   - 优先 `WorkerService.threads` 缓存。
   - 缓存缺失时执行 `thread/list` 补齐。
3. 若线程不存在：返回 `404 THREAD_NOT_FOUND`。
4. 若线程已归档：返回 `409 THREAD_ARCHIVED`。
5. 兜底目录：线程缺失 `cwd` 时用 `defaultProjectPath`。

### 4.5 REST API 设计

### 4.5.1 打开终端

`POST /v1/threads/{threadId}/terminal/open`

请求体：

```json
{
  "cols": 100,
  "rows": 28
}
```

响应体：

```json
{
  "session": {
    "sessionId": "term_01J...",
    "threadId": "019c...",
    "cwd": "/Users/Apple/Dev/OpenCodex",
    "shell": "/bin/zsh",
    "pid": 12345,
    "status": "running",
    "createdAt": "2026-02-24T13:00:00.000Z",
    "lastActiveAt": "2026-02-24T13:00:00.000Z",
    "cols": 100,
    "rows": 28,
    "nextSeq": 0
  },
  "reused": false,
  "wsPath": "/v1/terminals/term_01J.../stream"
}
```

语义：

1. 若该线程已有活动会话，返回 `reused=true`。
2. 若没有则创建新会话并启动 `zsh`。

### 4.5.2 查询终端状态

`GET /v1/threads/{threadId}/terminal`

响应体：

```json
{
  "session": null
}
```

或：

```json
{
  "session": {
    "sessionId": "term_01J...",
    "status": "running",
    "cwd": "/Users/Apple/Dev/OpenCodex",
    "nextSeq": 392
  }
}
```

### 4.5.3 调整窗口大小

`POST /v1/terminals/{sessionId}/resize`

```json
{
  "cols": 120,
  "rows": 36
}
```

说明：

1. 该接口仅调整 **PTY 逻辑窗口**，用于控制远端 Shell 的换行与全屏程序布局。
2. 不调整也不依赖 Mac 上 `Terminal.app/iTerm` 的图形窗口大小（两者不是同一终端实例）。

### 4.5.4 关闭会话

`POST /v1/terminals/{sessionId}/close`

```json
{
  "reason": "user_closed"
}
```

### 4.6 WebSocket 协议

连接地址：

`GET /v1/terminals/{sessionId}/stream?fromSeq=120`

鉴权：

1. 复用现有 Bearer Token（`Authorization` 头）。
2. 与 REST 保持一致的鉴权失败语义。

客户端 -> 服务端：

```json
{ "type": "input", "data": "ls -la\n" }
{ "type": "resize", "cols": 120, "rows": 36 }
{ "type": "ping", "clientTs": "2026-02-24T13:00:02.000Z" }
{ "type": "detach" }
```

服务端 -> 客户端：

```json
{ "type": "ready", "sessionId": "term_01J...", "threadId": "019c...", "cwd": "/Users/...", "seq": 120 }
{ "type": "output", "seq": 121, "data": "total 88\r\n..." }
{ "type": "pong", "clientTs": "2026-02-24T13:00:02.000Z" }
{ "type": "exit", "seq": 205, "exitCode": 0, "signal": null }
{ "type": "error", "code": "SESSION_NOT_FOUND", "message": "..." }
```

续传规则：

1. `fromSeq` 缺失：从最新位置开始，仅收后续增量。
2. `fromSeq >= 0`：先回放 `seq > fromSeq` 的缓冲输出，再进入实时流。
3. 缓冲窗口外：返回 `409 CURSOR_EXPIRED`，客户端应重新 `open` 或从当前点重连。

### 4.7 错误码

新增错误码（保持 `HttpError` 风格）：

1. `TERMINAL_DISABLED` (403)
2. `TERMINAL_LIMIT_REACHED` (429)
3. `TERMINAL_OPEN_FAILED` (502)
4. `TERMINAL_SESSION_NOT_FOUND` (404)
5. `TERMINAL_SESSION_EXITED` (409)
6. `TERMINAL_CURSOR_EXPIRED` (409)
7. `TERMINAL_INVALID_INPUT` (400)

### 4.8 安全与资源控制

1. 输入大小限制：单帧 `<= maxInputBytes`。
2. 输出缓冲限制：`ringBuffer` 总字节 `<= maxScrollbackBytes`。
3. 会话上限：`maxSessions`。
4. 心跳：`ping/pong`，超时断连。
5. 空闲回收采用“安全回收条件”：
   - `noClientAttached=true`（无客户端附着）
   - `foregroundBusy=false`（当前无前台命令执行）
   - `backgroundJobs=0`（当前无后台任务）
   - 同时满足且持续超过 `idleTtlMs` 才允许 kill `PTY`。
6. `foregroundBusy/backgroundJobs` 建议通过 Shell hook 维护（如 `preexec/precmd/jobs -p`），避免“后台仍在跑任务却被误回收”。
7. 任何 `input/output/attach/resize` 都刷新 `lastActiveAt` 并取消待回收计时。
8. 日志审计：记录 open/close/exit/resize，不默认全量落命令文本。

---

## 5. iOS 前端详细设计（codex-worker-ios）

### 5.1 新增依赖

1. `SwiftTerm`（终端渲染，替代纯文本模拟）

### 5.2 新增模块

1. `Features/TerminalFeature/TerminalFeature.swift`
2. `Features/TerminalFeature/TerminalView.swift`
3. `Dependencies/TerminalClient.swift`
4. `Services/Terminal/TerminalWebSocketClient.swift`

### 5.3 状态与动作（TCA）

`TCA（The Composable Architecture，可组合架构）` 状态建议：

```swift
State {
  isPresented: Bool
  heightRatio: CGFloat // default 0.5
  threadId: String?
  sessionId: String?
  cwd: String?
  connection: ConnectionState // idle/connecting/connected/failed
  output: AttributedString // 或分片缓存
  isOpening: Bool
  isClosing: Bool
  errorMessage: String?
}
```

关键动作：

1. `togglePresented(Bool)`
2. `threadChanged(Thread?)`
3. `openSessionResponse(...)`
4. `websocketConnected`
5. `receivedOutput(seq, data)`
6. `sendInput(String)`
7. `resize(cols, rows)`
8. `closeSession`

### 5.4 UI 交互

1. 聊天头部增加终端开关按钮（`terminal` 图标）。
2. 打开时布局变为上下分栏：
   - 上：聊天区
   - 下：终端区（默认 50%，可拖动 35%~70%）
3. 收起时仅隐藏终端面板，不默认关闭远端会话。
4. 面板头显示：`cwd`、连接状态、关闭按钮。

### 5.5 线程切换行为

1. 当前线程 A 打开终端后切到线程 B：
   - 断开 A 的 WS（不一定 kill A）。
   - 尝试复用 B 的 session；无则创建 B 会话。
2. 返回线程 A 时：
   - 复连 A 会话并按 `fromSeq` 补历史。

### 5.6 输入法与性能

1. 输入采用“按键流”或“行提交”模式；默认按键流。
2. 输出采用分片追加，避免全量字符串复制导致卡顿。
3. 主线程仅做 UI 渲染；WebSocket 数据处理在后台队列。

---

## 6. 与现有功能关系

1. 与聊天任务流解耦：终端不会改变 `job` 状态机。
2. 与审批解耦：终端命令不触发 `approval.required`。
3. 与线程模型耦合：唯一耦合点是 `threadId -> cwd` 映射。

产品提示建议：

1. 在终端首次打开时提示“该终端直接执行 Mac 命令，不经过审批”。

---

## 7. 实施计划

### Phase 1（后端可用）

1. 引入 `node-pty` 与 `ws`。
2. 打通 open/status/resize/close + WebSocket input/output。
3. 完成 `threadId -> cwd` 绑定。
4. 增加后端单测与 HTTP 集成测试。

### Phase 2（iOS 可用）

1. 接入 `SwiftTerm`。
2. 完成半屏终端 UI 与开关。
3. 完成线程切换联动。
4. 处理断线重连与基础错误提示。

### Phase 3（生产强化）

1. 续传稳定性（`fromSeq` 与 cursor 过期处理）。
2. 空闲会话回收、资源上限策略。
3. 观测指标与日志细化。

---

## 8. 测试计划

### 8.1 后端测试

1. `terminal-service.test.js`：
   - 同线程 open 幂等复用
   - thread-cwd 绑定正确
   - session close 行为
2. `terminal-ws.test.js`：
   - input/output 双向流
   - resize 生效
   - heartbeat 断线
   - fromSeq 续传
3. `http-server.test.js`：
   - 鉴权
   - 错误码
   - 参数校验

### 8.2 iOS 测试

1. `TerminalFeatureTests`：
   - toggle 与 session 生命周期
   - thread 切换时 session 复用/切换
   - 断线重连状态迁移
2. 手工回归：
   - 打开/收起半屏
   - 连续切线程
   - 大量输出（`ls -R`, `tail -f`）
   - 后台切前台恢复

---

## 9. 验收标准

1. iOS 点击按钮可打开半屏终端，默认 50% 高度。
2. 终端默认在对应线程 `cwd` 下执行 Mac `zsh`。
3. 切换线程时终端上下文随线程切换，不串目录。
4. 断线重连后终端可继续交互，且输出不明显丢失。
5. 不影响现有聊天、审批、线程列表主流程。

---

## 10. 参考实现映射（TermAway）

参考仓库：

1. <https://github.com/alexkerber/termaway>
2. `server/sessionManager.js`：`PTY + scrollback + multi-client + resize`。
3. `server/index.js`：`WebSocket 消息分发 + 心跳 + 鉴权`。

本方案复用其思想，但做了以下本地化约束：

1. 会话命名从“自定义 session name”改为“threadId 绑定”。
2. 鉴权统一复用 `codex-worker-mvp` 的 Bearer token。
3. 协议风格统一到 `/v1/...` + `HttpError`。

---

## 11. 风险与对策

1. 风险：终端高权限绕过审批。
   对策：默认关闭终端能力 + 首次风险提示 + 服务端审计日志。
2. 风险：长输出导致 iOS 卡顿。
   对策：分片渲染 + 缓冲上限 + 背景队列处理。
3. 风险：会话泄漏占用资源。
   对策：空闲超时回收 + 连接心跳 + 会话上限。
