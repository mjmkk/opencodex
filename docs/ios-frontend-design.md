# iOS 前端详细设计文档

> 基于 TCA + exyte/Chat + EventSource 的 Codex Worker iOS 客户端设计

## English Summary

This document is the detailed iOS frontend design for OpenCodex.

1. Defines goals, architecture, and module boundaries for the iOS app.
2. Uses TCA (The Composable Architecture，组合式架构), Exyte Chat, and SSE streaming.
3. Specifies runtime flows for thread switching, incremental rendering, approval handling, and reconnect behavior.
4. Provides implementation constraints and acceptance criteria for production-ready delivery.

## 1. 项目概述

### 1.1 目标

开发一个 iOS 应用，作为 Codex Worker 的移动端前端，支持：
- 线程列表与切换
- 实时对话消息流（增量渲染）
- 审批弹窗与决策回传
- SSE 断线重连与游标恢复

### 1.2 技术栈

| 组件 | 技术选型 | 说明 |
|------|----------|------|
| 状态管理 | TCA (swift-composable-architecture) | 单向数据流，可测试性强 |
| 聊天 UI | exyte/Chat | 成熟的聊天组件库 |
| SSE 客户端 | Recouse/EventSource | 支持 Async/Await 的 SSE 库 |
| 网络层 | URLSession + Async/Await | 原生方案，无第三方依赖 |
| 最低版本 | iOS 16.0 | 支持 SwiftUI 4.0+ |

### 1.3 与后端 API 对接

后端 Worker 运行在 Mac 上，通过 HTTP + SSE 对外提供服务。iOS 作为客户端通过局域网或隧道连接。

## 2. 项目结构

### 2.1 工程形态说明（必须明确）

最终交付目标是 **可运行的 iOS App 工程**，而不是仅有 Swift Package。

- `CodexWorkerKit`（Swift Package）：承载业务模块（TCA Feature、API/SSE、模型、通用组件），可复用、可测试。
- `CodexWorkerApp`（Xcode iOS App Target）：承载 `@main` 入口、签名配置、运行 Scheme、Info.plist、资产与启动流程。
- 关系：`CodexWorkerApp` 依赖 `CodexWorkerKit`；调试与发版均以 `CodexWorkerApp` 为入口。
- 验收标准：必须能在模拟器/真机通过 `Run` 启动，并完成“线程切换 -> 聊天 -> 审批”闭环。

> 说明：开发早期可以先用 Swift Package 快速搭业务层，但在 MVP 阶段必须补齐 App 容器工程，否则无法完成真实运行与交互验收。

```
CodexWorker/
├── App/
│   ├── CodexWorkerApp.swift          // App 入口
│   └── ContentView.swift              // 根视图
├── Dependencies/                       // 依赖层（TCA Dependency）
│   ├── APIClient.swift                // REST API 客户端
│   ├── SSEClient.swift                // SSE 客户端封装
│   └── Configuration.swift            // 配置（Worker 地址、Token）
├── Models/                            // 数据模型
│   ├── Thread.swift                   // 线程模型
│   ├── Job.swift                      // 任务模型
│   ├── Event.swift                    // SSE 事件模型
│   ├── Approval.swift                 // 审批模型
│   ├── ChatMessage.swift              // 聊天消息（适配 exyte/Chat）
│   └── User.swift                     // 用户模型
├── Features/                          // TCA Feature 层
│   ├── AppFeature.swift               // 应用级 Feature
│   ├── ThreadsFeature/                // 线程列表
│   │   ├── ThreadsFeature.swift
│   │   └── ThreadsView.swift
│   ├── ChatFeature/                   // 聊天界面
│   │   ├── ChatFeature.swift
│   │   ├── ChatView.swift
│   │   └── MessageBuilder.swift
│   ├── ApprovalFeature/               // 审批处理
│   │   ├── ApprovalFeature.swift
│   │   └── ApprovalSheet.swift
│   └── SettingsFeature/               // 设置
│       ├── SettingsFeature.swift
│       └── SettingsView.swift
├── Services/                          // 服务层
│   ├── EventProcessor.swift           // 事件处理器
│   ├── MessageAggregator.swift        // 消息聚合器（delta 合并）
│   └── ConnectionState.swift          // 连接状态机
└── UI/                                // 通用 UI 组件
    ├── StatusBanner.swift             // 状态横幅
    ├── SidebarView.swift              // 侧边栏
    └── Components/
```

## 3. 数据模型设计

### 3.1 线程模型（Thread）

```swift
// Models/Thread.swift

/// 线程状态
enum ThreadState: String, Codable {
    case idle           // 空闲，无活跃任务
    case active         // 有活跃任务
    case archived       // 已归档
}

/// 线程 DTO（与后端 API 对齐）
struct Thread: Identifiable, Codable, Equatable {
    let threadId: String
    var preview: String?
    var cwd: String?
    var createdAt: String?
    var updatedAt: String?
    var modelProvider: String?
    
    // 本地计算属性
    var id: String { threadId }
    var displayName: String {
        // 从 cwd 提取最后一段作为显示名
        cwd?.split(separator: "/").last.map(String.init) ?? "Untitled"
    }
    var lastActiveAt: Date? {
        updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}
```

### 3.2 任务模型（Job）

```swift
// Models/Job.swift

/// 任务状态（与后端状态机对齐）
enum JobState: String, Codable, Equatable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case waitingApproval = "WAITING_APPROVAL"
    case done = "DONE"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
    
    /// 是否为终态
    var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }
    
    /// 是否为活跃状态
    var isActive: Bool {
        switch self {
        case .queued, .running, .waitingApproval: return true
        default: return false
        }
    }
}

/// 任务快照
struct Job: Identifiable, Codable, Equatable {
    let jobId: String
    let threadId: String
    var turnId: String?
    var state: JobState
    var pendingApprovalCount: Int
    var createdAt: String
    var updatedAt: String
    var terminalAt: String?
    var errorMessage: String?
    
    var id: String { jobId }
}
```

### 3.3 SSE 事件模型

```swift
// Models/Event.swift

/// SSE 事件信封（与后端对齐）
struct EventEnvelope: Codable, Equatable {
    let type: String
    let ts: String
    let jobId: String
    let seq: Int
    let payload: [String: JSONValue]?
}

/// 事件类型枚举
enum EventType: String, CaseIterable {
    // 生命周期事件
    case jobCreated = "job.created"
    case jobState = "job.state"
    case jobFinished = "job.finished"
    case turnStarted = "turn.started"
    case turnCompleted = "turn.completed"
    
    // 消息事件
    case itemStarted = "item.started"
    case itemCompleted = "item.completed"
    case itemAgentMessageDelta = "item.agentMessage.delta"
    case itemCommandExecutionOutputDelta = "item.commandExecution.outputDelta"
    case itemFileChangeOutputDelta = "item.fileChange.outputDelta"
    
    // 审批事件
    case approvalRequired = "approval.required"
    case approvalResolved = "approval.resolved"
    
    // 错误事件
    case error = "error"
    
    // 线程事件
    case threadStarted = "thread.started"
}

/// JSON 值类型（用于解析动态 payload）
enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null
    
    // Codable 实现...
}
```

### 3.4 审批模型

```swift
// Models/Approval.swift

/// 审批类型
enum ApprovalKind: String, Codable {
    case commandExecution = "command_execution"
    case fileChange = "file_change"
}

/// 审批决策
enum ApprovalDecision: String, Codable {
    case accept
    case acceptForSession = "accept_for_session"
    case acceptWithExecpolicyAmendment = "accept_with_execpolicy_amendment"
    case decline
    case cancel
}

/// 审批请求（从 approval.required 事件解析）
struct Approval: Identifiable, Codable, Equatable {
    let approvalId: String
    let jobId: String
    let threadId: String
    let turnId: String?
    let itemId: String?
    let kind: ApprovalKind
    let requestMethod: String
    let createdAt: String
    
    // 命令审批字段
    var command: String?
    var cwd: String?
    var commandActions: [String]?
    var reason: String?
    var grantRoot: Bool?
    var proposedExecpolicyAmendment: [String]?
    
    // 文件变更审批字段（待扩展）
    
    var id: String { approvalId }
    
    /// 风险等级（本地计算）
    var riskLevel: RiskLevel {
        // 基于命令/文件路径判断风险
        if let cmd = command {
            if cmd.contains("rm ") || cmd.contains("sudo ") { return .high }
            if cmd.contains("git push") || cmd.contains("npm publish") { return .medium }
        }
        return .low
    }
}

enum RiskLevel {
    case low, medium, high
    
    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
    
    var label: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "中风险"
        case .high: return "高风险"
        }
    }
}
```

### 3.5 聊天消息模型（适配 exyte/Chat）

```swift
// Models/ChatMessage.swift

import ExyteChat

/// 消息发送者
enum MessageSender: Equatable {
    case user      // 当前用户
    case assistant // AI 助手
    case system    // 系统消息
}

/// 将 Codex 消息适配到 exyte/Chat 的 Message
struct ChatMessageAdapter {
    /// 当前用户（iPhone 用户）
    static let currentUser = User(
        id: "user",
        name: "You",
        avatarURL: nil,
        isCurrentUser: true
    )
    
    /// AI 助手
    static let assistantUser = User(
        id: "assistant",
        name: "Codex",
        avatarURL: nil,
        isCurrentUser: false
    )
    
    /// 系统用户
    static let systemUser = User(
        id: "system",
        name: "System",
        avatarURL: nil,
        isCurrentUser: false
    )
    
    /// 从事件数据构建消息
    static func fromEvent(
        itemId: String,
        sender: MessageSender,
        text: String,
        createdAt: Date = Date()
    ) -> Message {
        let user: User
        switch sender {
        case .user: user = currentUser
        case .assistant: user = assistantUser
        case .system: user = systemUser
        }
        
        return Message(
            id: itemId,
            user: user,
            status: .sent,
            createdAt: createdAt,
            text: text,
            attachments: [],
            reactions: []
        )
    }
}

/// 消息增量状态（用于 delta 合并）
struct MessageDelta {
    let itemId: String
    var text: String
    var isComplete: Bool
    var sender: MessageSender
    var createdAt: Date
    
    /// 合并 delta
    mutating func append(_ delta: String) {
        text += delta
    }
    
    /// 转换为最终消息
    func toMessage() -> Message {
        ChatMessageAdapter.fromEvent(
            itemId: itemId,
            sender: sender,
            text: text,
            createdAt: createdAt
        )
    }
}
```

## 4. TCA Feature 设计

### 4.1 Feature 层级结构

```
AppFeature
├── connectionState: ConnectionState     // 连接状态
├── settings: SettingsFeature             // 设置
├── threads: ThreadsFeature               // 线程列表
├── chat: ChatFeature                     // 当前聊天
├── approval: ApprovalFeature             // 审批处理
└── destination: Destination              // 导航目标
```

### 4.2 AppFeature（根 Feature）

```swift
// Features/AppFeature.swift

import ComposableArchitecture

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        // 连接状态
        var connectionState: ConnectionState = .disconnected
        var isConfigured: Bool = false
        
        // 子 Feature
        var settings: SettingsFeature.State = .init()
        var threads: ThreadsFeature.State = .init()
        var chat: ChatFeature.State?
        var approval: ApprovalFeature.State?
        
        // 导航
        var path = StackState<Path.State>()
        
        // 侧边栏
        var isSidebarPresented = false
    }
    
    enum Action: BindableAction {
        case binding(BindingAction<State>)
        
        // 生命周期
        case onAppear
        case onBackground
        case onForeground
        
        // 连接管理
        case connect
        case disconnect
        case connectionStateChanged(ConnectionState)
        
        // 子 Feature
        case settings(SettingsFeature.Action)
        case threads(ThreadsFeature.Action)
        case chat(ChatFeature.Action)
        case approval(ApprovalFeature.Action)
        case path(StackAction<Path.State, Path.Action>)
        
        // 导航
        case toggleSidebar
        case selectThread(Thread)
        case dismissChat
    }
    
    @Reducer
    enum Path {
        case chat(ChatFeature)
        case settings(SettingsFeature)
    }
    
    @Dependency(\.apiClient) var apiClient
    @Dependency(\.continuousClock) var clock
    
    var body: some ReducerOf<Self> {
        BindingReducer()
        
        Scope(state: \.settings, action: \.settings) {
            SettingsFeature()
        }
        
        Scope(state: \.threads, action: \.threads) {
            ThreadsFeature()
        }
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // 初始化时检查配置并连接
                return .run { send in
                    // 加载配置
                    // 如果已配置，尝试连接
                    await send(.connect)
                }
                
            case .connect:
                return .run { send in
                    // 尝试连接 Worker
                    // 更新连接状态
                    await send(.connectionStateChanged(.connecting))
                    // ... 连接逻辑
                }
                
            case let .connectionStateChanged(newState):
                state.connectionState = newState
                return .none
                
            case .toggleSidebar:
                state.isSidebarPresented.toggle()
                return .none
                
            case let .selectThread(thread):
                // 激活线程并打开聊天
                state.isSidebarPresented = false
                return .run { send in
                    // 激活线程
                    try await apiClient.activateThread(thread.threadId)
                    // 推入聊天界面
                    await send(.path(.push(id: .init(), state: .chat(.init(thread: thread)))))
                } catch: { error, send in
                    // 错误处理
                }
                
            default:
                return .none
            }
        }
        .forEach(\.path, action: \.path)
        .ifLet(\.approval, action: \.approval) {
            ApprovalFeature()
        }
    }
}
```

### 4.3 ThreadsFeature（线程列表）

```swift
// Features/ThreadsFeature/ThreadsFeature.swift

@Reducer
struct ThreadsFeature {
    @ObservableState
    struct State: Equatable {
        var threads: IdentifiedArrayOf<Thread> = []
        var isLoading = false
        var error: String?
        
        // 按 cwd 分组
        var groupedThreads: [String: [Thread]] {
            Dictionary(grouping: threads) { $0.cwd ?? "Unknown" }
        }
    }
    
    enum Action {
        case onAppear
        case refresh
        case loadThreads
        case threadsLoaded(Result<[Thread], Error>)
        case selectThread(Thread)
        case createThread(projectPath: String, name: String?)
        case threadCreated(Result<Thread, Error>)
    }
    
    @Dependency(\.apiClient) var apiClient
    
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear, .refresh:
                state.isLoading = true
                return .send(.loadThreads)
                
            case .loadThreads:
                return .run { send in
                    await send(.threadsLoaded(Result {
                        try await apiClient.listThreads()
                    }))
                }
                
            case let .threadsLoaded(.success(threads)):
                state.isLoading = false
                state.threads = IdentifiedArrayOf(uniqueElements: threads)
                state.error = nil
                return .none
                
            case let .threadsLoaded(.failure(error)):
                state.isLoading = false
                state.error = error.localizedDescription
                return .none
                
            case let .createThread(projectPath, name):
                state.isLoading = true
                return .run { send in
                    await send(.threadCreated(Result {
                        try await apiClient.createThread(
                            projectPath: projectPath,
                            threadName: name
                        )
                    }))
                }
                
            case let .threadCreated(.success(thread)):
                state.isLoading = false
                state.threads.append(thread)
                return .send(.selectThread(thread))
                
            case let .threadCreated(.failure(error)):
                state.isLoading = false
                state.error = error.localizedDescription
                return .none
                
            case .selectThread:
                // 由父 Feature 处理
                return .none
            }
        }
    }
}
```

### 4.4 ChatFeature（聊天界面）

```swift
// Features/ChatFeature/ChatFeature.swift

@Reducer
struct ChatFeature {
    @ObservableState
    struct State: Equatable {
        // 线程信息
        let thread: Thread
        var job: Job?
        
        // 消息状态
        var messages: IdentifiedArrayOf<Message> = []
        var pendingDeltas: [String: MessageDelta] = [:]  // itemId -> delta
        
        // 输入状态
        var inputText = ""
        var isInputEnabled = true
        var isSending = false
        
        // SSE 连接
        var cursor: Int = -1
        var isStreaming = false
        var connectionError: String?
        
        // 审批
        var pendingApproval: Approval?
        
        // 滚动
        var shouldScrollToBottom = false
    }
    
    enum Action: BindableAction {
        case binding(BindingAction<State>)
        
        // 生命周期
        case onAppear
        case onDisappear
        
        // 消息
        case sendMessage(String)
        case messageSent(Result<Job, Error>)
        
        // SSE 事件
        case startStreaming
        case stopStreaming
        case eventReceived(EventEnvelope)
        case connectionStateChanged(Bool)
        
        // 事件处理
        case handleJobState(JobState, String?)
        case handleItemStarted([String: JSONValue]?)
        case handleItemDelta(String, String)  // itemId, delta
        case handleItemCompleted([String: JSONValue]?)
        case handleApprovalRequired(Approval)
        case handleApprovalResolved(String, String)  // approvalId, decision
        case handleError(String)
        
        // UI
        case setInputEnabled(Bool)
        case scrollToBottom
    }
    
    @Dependency(\.apiClient) var apiClient
    @Dependency(\.sseClient) var sseClient
    @Dependency(\.continuousClock) var clock
    
    var body: some ReducerOf<Self> {
        BindingReducer()
        
        Reduce { state, action in
            switch action {
            case .onAppear:
                // 加载历史事件
                return .run { [threadId = state.thread.threadId] send in
                    // 获取历史事件
                    if let events = try? await apiClient.listThreadEvents(threadId) {
                        for event in events {
                            await send(.eventReceived(event))
                        }
                    }
                    // 启动 SSE
                    await send(.startStreaming)
                }
                
            case .onDisappear:
                return .send(.stopStreaming)
                
            case let .sendMessage(text):
                guard !text.isEmpty, state.isInputEnabled else { return .none }
                state.isSending = true
                state.inputText = ""
                
                // 添加用户消息
                let userMessage = ChatMessageAdapter.fromEvent(
                    itemId: UUID().uuidString,
                    sender: .user,
                    text: text
                )
                state.messages.append(userMessage)
                
                return .run { [threadId = state.thread.threadId] send in
                    await send(.messageSent(Result {
                        try await apiClient.startTurn(threadId, text: text)
                    }))
                }
                
            case let .messageSent(.success(job)):
                state.job = job
                state.isSending = false
                state.cursor = -1  // 重置游标
                return .send(.startStreaming)
                
            case let .messageSent(.failure(error)):
                state.isSending = false
                state.connectionError = error.localizedDescription
                return .none
                
            case .startStreaming:
                guard let jobId = state.job?.jobId, !state.isStreaming else { return .none }
                state.isStreaming = true
                state.connectionError = nil
                
                return .run { [jobId, cursor = state.cursor] send in
                    // 订阅 SSE
                    for try await event in try await sseClient.subscribe(jobId: jobId, cursor: cursor) {
                        await send(.eventReceived(event))
                        
                        // 检查是否终态
                        if event.type == "job.finished" {
                            await send(.stopStreaming)
                        }
                    }
                } catch: { error, send in
                    await send(.connectionStateChanged(false))
                    await send(.handleError(error.localizedDescription))
                }
                
            case .stopStreaming:
                state.isStreaming = false
                return .none
                
            case let .eventReceived(envelope):
                state.cursor = envelope.seq
                
                guard let eventType = EventType(rawValue: envelope.type) else { return .none }
                
                switch eventType {
                case .jobState:
                    let payload = envelope.payload
                    let stateValue = payload?["state"]?.stringValue
                    let errorMsg = payload?["errorMessage"]?.stringValue
                    if let jobState = stateValue.flatMap(JobState.init(rawValue:)) {
                        return .send(.handleJobState(jobState, errorMsg))
                    }
                    return .none
                    
                case .itemAgentMessageDelta:
                    let itemId = envelope.payload?["itemId"]?.stringValue ?? ""
                    let delta = envelope.payload?["delta"]?.stringValue ?? ""
                    return .send(.handleItemDelta(itemId, delta))
                    
                case .approvalRequired:
                    if let approval = try? JSONDecoder().decode(
                        Approval.self,
                        from: JSONSerialization.data(withJSONObject: envelope.payload ?? [:])
                    ) {
                        return .send(.handleApprovalRequired(approval))
                    }
                    return .none
                    
                case .approvalResolved:
                    let approvalId = envelope.payload?["approvalId"]?.stringValue ?? ""
                    let decision = envelope.payload?["decision"]?.stringValue ?? ""
                    return .send(.handleApprovalResolved(approvalId, decision))
                    
                default:
                    return .none
                }
                
            case let .handleJobState(jobState, errorMsg):
                state.job?.state = jobState
                if let errorMsg = errorMsg {
                    state.connectionError = errorMsg
                }
                
                // 终态时停止流
                if jobState.isTerminal {
                    state.isStreaming = false
                    state.isInputEnabled = true
                }
                
                return .none
                
            case let .handleItemDelta(itemId, delta):
                if var existing = state.pendingDeltas[itemId] {
                    existing.append(delta)
                    state.pendingDeltas[itemId] = existing
                    
                    // 更新消息
                    if let idx = state.messages.index(id: itemId) {
                        state.messages[idx] = existing.toMessage()
                    }
                } else {
                    // 新消息
                    let newDelta = MessageDelta(
                        itemId: itemId,
                        text: delta,
                        isComplete: false,
                        sender: .assistant,
                        createdAt: Date()
                    )
                    state.pendingDeltas[itemId] = newDelta
                    state.messages.append(newDelta.toMessage())
                }
                return .send(.scrollToBottom)
                
            case let .handleApprovalRequired(approval):
                state.pendingApproval = approval
                state.isInputEnabled = false  // 审批期间禁用输入
                return .none
                
            case let .handleApprovalResolved(approvalId, decision):
                // 关闭审批弹窗
                if state.pendingApproval?.approvalId == approvalId {
                    state.pendingApproval = nil
                    state.isInputEnabled = true
                }
                return .none
                
            case .scrollToBottom:
                state.shouldScrollToBottom = true
                return .none
                
            default:
                return .none
            }
        }
    }
}
```

### 4.5 ApprovalFeature（审批处理）

```swift
// Features/ApprovalFeature/ApprovalFeature.swift

@Reducer
struct ApprovalFeature {
    @ObservableState
    struct State: Equatable {
        var approval: Approval?
        var isSubmitting = false
        var error: String?
        var isPresented = false
    }
    
    enum Action {
        case present(Approval)
        case dismiss
        case submit(ApprovalDecision, [String]?)
        case submitted(Result<String, Error>)
    }
    
    @Dependency(\.apiClient) var apiClient
    
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .present(approval):
                state.approval = approval
                state.isPresented = true
                state.error = nil
                return .none
                
            case .dismiss:
                state.isPresented = false
                state.approval = nil
                state.error = nil
                return .none
                
            case let .submit(decision, execPolicyAmendment):
                guard let approval = state.approval else { return .none }
                state.isSubmitting = true
                
                return .run { send in
                    await send(.submitted(Result {
                        try await apiClient.approve(
                            jobId: approval.jobId,
                            approvalId: approval.approvalId,
                            decision: decision,
                            execPolicyAmendment: execPolicyAmendment
                        )
                    }))
                }
                
            case let .submitted(.success(decision)):
                state.isSubmitting = false
                // 等待 approval.resolved 事件再关闭
                return .none
                
            case let .submitted(.failure(error)):
                state.isSubmitting = false
                state.error = error.localizedDescription
                return .none
            }
        }
    }
}
```

## 5. 网络层设计

### 5.1 API 客户端协议

```swift
// Dependencies/APIClient.swift

import ComposableArchitecture
import Foundation

/// API 客户端协议（支持依赖注入）
struct APIClient: DependencyKey {
    var listProjects: @Sendable () async throws -> [Project]
    var createThread: @Sendable (_ projectPath: String?, _ threadName: String?) async throws -> Thread
    var listThreads: @Sendable () async throws -> [Thread]
    var activateThread: @Sendable (_ threadId: String) async throws -> Thread
    var listThreadEvents: @Sendable (_ threadId: String) async throws -> [EventEnvelope]
    var startTurn: @Sendable (_ threadId: String, _ text: String) async throws -> Job
    var getJob: @Sendable (_ jobId: String) async throws -> Job
    var approve: @Sendable (_ jobId: String, _ approvalId: String, _ decision: ApprovalDecision, _ execPolicyAmendment: [String]?) async throws -> String
    var cancel: @Sendable (_ jobId: String) async throws -> Job
    
    static let liveValue = APIClient(
        listProjects: { try await LiveAPIClient().listProjects() },
        createThread: { try await LiveAPIClient().createThread(projectPath: $0, threadName: $1) },
        // ... 其他方法
    )
    
    static let testValue = APIClient(/* mock */)
}

extension DependencyValues {
    var apiClient: APIClient {
        get { self[APIClient.self] }
        set { self[APIClient.self] = newValue }
    }
}
```

### 5.2 SSE 客户端封装

```swift
// Dependencies/SSEClient.swift

import ComposableArchitecture
import EventSource
import Foundation

/// SSE 客户端协议
struct SSEClient: DependencyKey {
    var subscribe: @Sendable (_ jobId: String, _ cursor: Int) async throws -> AsyncStream<EventEnvelope>
    
    static let liveValue: SSEClient = .init(
        subscribe: { jobId, cursor in
            AsyncStream { continuation in
                Task {
                    let config = try Configuration.load()
                    let url = URL(string: "\(config.workerURL)/v1/jobs/\(jobId)/events?cursor=\(cursor)")!
                    
                    var request = URLRequest(url: url)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
                    
                    let eventSource = EventSource()
                    let task = eventSource.dataTask(for: request)
                    
                    for await event in task.events() {
                        switch event {
                        case let .event(serverEvent):
                            if let envelope = try? JSONDecoder().decode(
                                EventEnvelope.self,
                                from: serverEvent.data ?? Data()
                            ) {
                                continuation.yield(envelope)
                            }
                            
                        case let .error(error):
                            // 重连逻辑
                            print("SSE error: \(error)")
                            
                        case .open:
                            print("SSE connected")
                            
                        case .closed:
                            continuation.finish()
                        }
                    }
                }
            }
        }
    )
    
    static let testValue = SSEClient(/* mock */)
}

extension DependencyValues {
    var sseClient: SSEClient {
        get { self[SSEClient.self] }
        set { self[SSEClient.self] = newValue }
    }
}
```

### 5.3 连接状态管理

```swift
// Services/ConnectionState.swift

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(Error)
    
    var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中..."
        case .connected: return "已连接"
        case let .reconnecting(attempt): return "重连中(\(attempt))..."
        case let .failed(error): return "连接失败: \(error.localizedDescription)"
        }
    }
    
    var color: Color {
        switch self {
        case .disconnected: return .gray
        case .connecting, .reconnecting: return .orange
        case .connected: return .green
        case .failed: return .red
        }
    }
}

/// 重连策略
struct ReconnectStrategy {
    var maxAttempts: Int = 10
    var baseDelay: TimeInterval = 1.0
    var maxDelay: TimeInterval = 30.0
    
    func delay(for attempt: Int) -> TimeInterval {
        min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
    }
}
```

## 6. UI 设计

### 6.1 主界面布局

```swift
// ContentView.swift

struct ContentView: View {
    @Bindable var store: StoreOf<AppFeature>
    
    var body: some View {
        ZStack {
            // 主内容
            NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
                // 线程列表（默认视图）
                ThreadsView(store: store.scope(state: \.threads, action: \.threads))
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                store.send(.toggleSidebar)
                            } label: {
                                Image(systemName: "sidebar.left")
                            }
                        }
                    }
            } destination: { store in
                switch store.case {
                case let .chat(store):
                    ChatView(store: store)
                case let .settings(store):
                    SettingsView(store: store)
                }
            }
            
            // 侧边栏（覆盖层）
            if store.isSidebarPresented {
                sidebarOverlay
            }
            
            // 审批弹窗（底部）
            if let approvalStore = store.scope(state: \.approval, action: \.approval) {
                ApprovalSheet(store: approvalStore)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            
            // 状态横幅（顶部）
            if store.connectionState != .connected {
                StatusBanner(state: store.connectionState)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut, value: store.isSidebarPresented)
        .animation(.easeInOut, value: store.connectionState)
    }
    
    @ViewBuilder
    private var sidebarOverlay: some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture {
                store.send(.toggleSidebar)
            }
        
        SidebarView(
            threadsStore: store.scope(state: \.threads, action: \.threads),
            settingsAction: { /* 导航到设置 */ },
            onSelectThread: { thread in
                store.send(.selectThread(thread))
            }
        )
        .frame(maxWidth: 300)
        .transition(.move(edge: .leading))
    }
}
```

### 6.2 聊天界面（集成 exyte/Chat）

```swift
// Features/ChatFeature/ChatView.swift

import SwiftUI
import ExyteChat

struct ChatView: View {
    @Bindable var store: StoreOf<ChatFeature>
    
    var body: some View {
        VStack(spacing: 0) {
            // 状态条
            if let job = store.job {
                JobStatusBar(state: job.state)
            }
            
            // 聊天内容
            ChatContentView(
                messages: store.messages,
                inputText: $store.inputText,
                isInputEnabled: store.isInputEnabled,
                isSending: store.isSending,
                onSend: { text in
                    store.send(.sendMessage(text))
                }
            )
            
            // 审批弹窗占位（由父视图处理）
        }
        .navigationTitle(store.thread.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store.send(.onAppear)
        }
        .onDisappear {
            store.send(.onDisappear)
        }
    }
}

/// 任务状态条
struct JobStatusBar: View {
    let state: JobState
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.color)
                .frame(width: 8, height: 8)
            
            Text(state.label)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            if state.isActive {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color(.systemGray6))
    }
}

extension JobState {
    var color: Color {
        switch self {
        case .queued: return .gray
        case .running: return .blue
        case .waitingApproval: return .orange
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
    
    var label: String {
        switch self {
        case .queued: return "排队中"
        case .running: return "执行中"
        case .waitingApproval: return "等待审批"
        case .done: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}
```

### 6.3 审批弹窗

```swift
// Features/ApprovalFeature/ApprovalSheet.swift

import SwiftUI

struct ApprovalSheet: View {
    @Bindable var store: StoreOf<ApprovalFeature>
    
    var body: some View {
        if let approval = store.approval {
            VStack(spacing: 16) {
                // 标题
                HStack {
                    Image(systemName: approval.kind.icon)
                        .foregroundColor(approval.riskLevel.color)
                    Text(approval.kind.title)
                        .font(.headline)
                    Spacer()
                    Text(approval.riskLevel.label)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(approval.riskLevel.color.opacity(0.2))
                        .cornerRadius(4)
                }
                
                // 内容
                VStack(alignment: .leading, spacing: 8) {
                    switch approval.kind {
                    case .commandExecution:
                        CommandApprovalView(approval: approval)
                    case .fileChange:
                        FileChangeApprovalView(approval: approval)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
                
                // 错误提示
                if let error = store.error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                // 操作按钮
                HStack(spacing: 12) {
                    Button("取消任务") {
                        store.send(.submit(.cancel, nil))
                    }
                    .buttonStyle(.bordered)
                    
                    Button("拒绝") {
                        store.send(.submit(.decline, nil))
                    }
                    .buttonStyle(.bordered)
                    
                    Button("接受") {
                        store.send(.submit(.accept, nil))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .disabled(store.isSubmitting)
            }
            .padding()
            .background(.regularMaterial)
            .cornerRadius(16)
            .shadow(radius: 10)
            .padding()
        }
    }
}

/// 命令审批视图
struct CommandApprovalView: View {
    let approval: Approval
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("命令:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(approval.command ?? "")
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(.systemBackground))
                .cornerRadius(4)
            
            if let cwd = approval.cwd {
                Text("工作目录: \(cwd)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if let reason = approval.reason {
                Text("原因: \(reason)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 文件变更审批视图
struct FileChangeApprovalView: View {
    let approval: Approval
    
    var body: some View {
        // 文件变更展示
        Text("文件变更审批")
    }
}

extension ApprovalKind {
    var icon: String {
        switch self {
        case .commandExecution: return "terminal"
        case .fileChange: return "doc.text"
        }
    }
    
    var title: String {
        switch self {
        case .commandExecution: return "命令执行审批"
        case .fileChange: return "文件变更审批"
        }
    }
}
```

## 7. 状态机设计

### 7.1 输入状态机

```
┌─────────────────┐
│  INPUT_ENABLED  │ ◄─────────────────────┐
└────────┬────────┘                        │
         │ approval.required               │
         ▼                                 │
┌─────────────────┐                        │
│ INPUT_DISABLED  │                        │
│  (审批中)        │                        │
└────────┬────────┘                        │
         │ approval.resolved               │
         │ 或审批提交成功                   │
         └─────────────────────────────────┘
```

### 7.2 连接状态机

```
┌──────────────┐     connect      ┌─────────────┐
│ DISCONNECTED │ ───────────────► │ CONNECTING  │
└──────────────┘                  └──────┬──────┘
       ▲                                 │
       │ disconnect                      │
       │                          ┌──────┴──────┐
       │                          │             │
       │                     success         failure
       │                          │             │
       │                          ▼             ▼
       │                    ┌───────────┐ ┌────────────┐
       │                    │ CONNECTED │ │ RECONNECT  │
       └────────────────────┴───────────┴────────────┘
```

## 8. 错误处理

### 8.1 错误类型

```swift
// Models/Error.swift

enum CodexError: Error, Equatable {
    // 网络错误
    case connectionFailed(String)
    case timeout
    case unauthorized
    
    // API 错误
    case apiError(code: String, message: String)
    case jobNotFound(String)
    case threadNotFound(String)
    case approvalNotFound(String)
    
    // 业务错误
    case threadHasActiveJob(String)
    case cursorExpired
    case invalidState
    
    // 本地错误
    case notConfigured
    case decodingError
    
    var localizedDescription: String {
        switch self {
        case let .connectionFailed(msg): return "连接失败: \(msg)"
        case .timeout: return "请求超时"
        case .unauthorized: return "未授权，请检查 Token"
        case let .apiError(code, msg): return "[\(code)] \(msg)"
        case let .jobNotFound(id): return "任务不存在: \(id)"
        case let .threadNotFound(id): return "线程不存在: \(id)"
        case let .approvalNotFound(id): return "审批不存在: \(id)"
        case let .threadHasActiveJob(id): return "线程已有活跃任务: \(id)"
        case .cursorExpired: return "游标已过期，正在恢复..."
        case .invalidState: return "状态无效"
        case .notConfigured: return "请先配置 Worker 连接"
        case .decodingError: return "数据解析失败"
        }
    }
}
```

### 8.2 错误恢复策略

| 错误类型 | 恢复策略 |
|---------|---------|
| 连接失败 | 指数退避重连（1s, 2s, 4s...最多 30s） |
| 游标过期 | 先拉取快照再重连 SSE |
| Token 失效 | 提示用户重新配置 |
| 任务不存在 | 返回线程列表 |
| 审批不存在 | 忽略（可能已被处理） |

## 9. 测试策略

### 9.1 单元测试

- Model 解析测试（Event、Approval 等）
- MessageAggregator delta 合并测试
- ConnectionState 状态机测试
- RiskLevel 计算测试

### 9.2 Feature 测试

使用 TCA 的 TestStore：

```swift
@MainActor
func testSendMessage() async {
    let store = TestStore(initialState: ChatFeature.State(thread: mockThread)) {
        ChatFeature()
    } withDependencies: {
        $0.apiClient.startTurn = { _, _ in mockJob }
    }
    
    await store.send(.sendMessage("Hello")) {
        $0.inputText = ""
        $0.isSending = true
        $0.messages.append(/* 用户消息 */)
    }
    
    await store.receive(.messageSent(.success(mockJob))) {
        $0.job = mockJob
        $0.isSending = false
    }
}
```

### 9.3 集成测试

- SSE 连接 → 接收事件 → UI 更新全流程
- 审批流程：接收 → 展示 → 提交 → 关闭

## 10. 开发里程碑

### Phase 1: 基础架构（1 天）
- [ ] 项目搭建（业务模块 Swift Package）
- [ ] App 容器搭建（Xcode iOS App Target + 可运行 Scheme）
- [ ] 依赖集成（TCA、exyte/Chat、EventSource）
- [ ] 数据模型定义
- [ ] API 客户端协议

### Phase 2: 线程管理（1 天）
- [ ] ThreadsFeature 实现
- [ ] 线程列表 UI
- [ ] 线程切换逻辑

### Phase 3: 聊天功能（1 天）
- [ ] ChatFeature 实现
- [ ] SSE 订阅与事件处理
- [ ] 消息增量渲染
- [ ] exyte/Chat 集成

### Phase 4: 审批功能（1 天）
- [ ] ApprovalFeature 实现
- [ ] 审批弹窗 UI
- [ ] 决策提交与状态更新

### Phase 5: 完善与测试（3 天）
- [ ] 错误处理与恢复
- [ ] 断线重连
- [ ] 单元测试
- [ ] UI 测试

## 11. 附录

### 11.1 后端 API 端点汇总

| 方法 | 端点 | 说明 |
|-----|------|------|
| GET | `/v1/projects` | 列出项目 |
| POST | `/v1/threads` | 创建线程 |
| GET | `/v1/threads` | 列出线程 |
| POST | `/v1/threads/{id}/activate` | 激活线程 |
| GET | `/v1/threads/{id}/events` | 线程历史事件 |
| POST | `/v1/threads/{id}/turns` | 发送消息 |
| GET | `/v1/jobs/{id}` | 任务快照 |
| GET | `/v1/jobs/{id}/events` | SSE 事件流 |
| POST | `/v1/jobs/{id}/approve` | 提交审批 |
| POST | `/v1/jobs/{id}/cancel` | 取消任务 |
| GET | `/health` | 健康检查 |

### 11.2 SSE 事件类型

| 事件类型 | 说明 |
|---------|------|
| `job.created` | 任务创建 |
| `job.state` | 任务状态变更 |
| `job.finished` | 任务完成（终态） |
| `turn.started` | 轮次开始 |
| `turn.completed` | 轮次完成 |
| `item.started` | 项目开始 |
| `item.completed` | 项目完成 |
| `item.agentMessage.delta` | AI 消息增量 |
| `approval.required` | 审批请求 |
| `approval.resolved` | 审批已处理 |
| `error` | 错误 |

### 11.3 审批决策值

| 决策 | 说明 | 适用类型 |
|-----|------|---------|
| `accept` | 接受本次 | 全部 |
| `accept_for_session` | 会话内接受 | 全部 |
| `accept_with_execpolicy_amendment` | 接受并修改命令 | 命令 |
| `decline` | 拒绝 | 全部 |
| `cancel` | 取消任务 | 全部 |
