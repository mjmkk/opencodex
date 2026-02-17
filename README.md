# OpenCodex Workspace

本仓库是一个 iOS 客户端 + 本地 Worker 后端的研发工作区，用于在手机端使用 Codex 对话、线程和审批能力。

## 1. 目录结构

- `CodexWorkerApp/`  
  Xcode App 工程（iOS 壳工程），负责 App 入口与运行配置。

- `codex-worker-ios/`  
  Swift Package（Swift 包），承载主要业务逻辑和 UI Feature（功能模块）。

- `codex-worker-mvp/`  
  Node.js Worker 后端（本地服务），对接 `codex app-server`，向 iOS 提供 REST + SSE 接口。

- `docs/`  
  设计与架构文档（如前端设计、MVP 架构、调研报告）。

## 2. 环境要求

- macOS（建议与当前 Xcode 版本匹配）
- Xcode（用于运行 iOS App）
- Node.js `>= 22`（用于 `codex-worker-mvp`）
- `npm`
- `codex` 命令行工具（后端会调用 `codex app-server`）

## 3. 快速启动

### Step 1: 启动本地 Worker 后端

```bash
cd /Users/Apple/Dev/OpenCodex/codex-worker-mvp
npm install
npm start
```

默认端口是 `8787`。启动成功后可验证：

```bash
curl http://127.0.0.1:8787/health
```

### Step 2: 运行 iOS App

1. 打开工程：  
   `/Users/Apple/Dev/OpenCodex/CodexWorkerApp/CodexWorkerApp/CodexWorkerApp.xcodeproj`
2. 选择 Scheme（构建方案）：`CodexWorkerApp`
3. 选择模拟器或真机后运行
4. 在 App 的设置页确认：
   - `Base URL` 指向你的 Worker（例如 `http://127.0.0.1:8787` 或 Mac 局域网 IP）
   - 如果后端启用了 `WORKER_TOKEN`，在 `Token` 填相同值

## 4. 常用自测命令

### 4.1 后端测试（Node.js）

```bash
cd /Users/Apple/Dev/OpenCodex/codex-worker-mvp
npm test
```

### 4.2 iOS 业务包测试（Swift Package）

```bash
cd /Users/Apple/Dev/OpenCodex/codex-worker-ios
xcodebuild -scheme CodexWorker -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

### 4.3 iOS App 构建校验

```bash
cd /Users/Apple/Dev/OpenCodex/CodexWorkerApp/CodexWorkerApp
xcodebuild -project CodexWorkerApp.xcodeproj -scheme CodexWorkerApp -configuration Debug -destination 'generic/platform=iOS Simulator' build
```

## 5. 配置与数据

- iOS 端连接配置由 App 设置页维护（本地持久化到 `UserDefaults`）
- Worker 默认 SQLite 路径：  
  `codex-worker-mvp/data/worker.db`
- 后端可通过环境变量改端口、Token、项目路径白名单等，详见：  
  `/Users/Apple/Dev/OpenCodex/codex-worker-mvp/README.md`

## 6. 开发约定

- 本仓库已忽略 Xcode 用户态文件与本地实验目录，避免 Git 混乱：
  - `**/xcuserdata/`
  - `**/*.xcuserstate`
  - `archive/`
- 提交前建议至少执行：
  1. 后端 `npm test`
  2. iOS 包 `xcodebuild ... test`
  3. iOS App `xcodebuild ... build`

