//
//  CodexWorkerRoot.swift
//  CodexWorker
//
//  根容器：对外提供可嵌入的根视图
//

import ComposableArchitecture
import SwiftUI

/// 根视图工厂
public enum CodexWorkerRoot {
    /// 创建根视图
    @MainActor
    @ViewBuilder
    public static func makeRootView() -> some View {
#if AGT12_UI_REPLAY
        let environment = ProcessInfo.processInfo.environment
        switch environment["AGT12_UI_REPLAY_PAGE"] ?? "chat" {
        case "tasks":
            if let path = environment["AGT12_TASKS_REPLAY_PATH"] { AGT12HistoricalTasksReplay(path: path) }
            else { missingReplay }
        case "overview":
            if let path = environment["AGT12_OVERVIEW_REPLAY_PATH"] { AGT12HistoricalOverviewReplay(path: path) }
            else { missingReplay }
        case "chat":
            if let path = environment["AGT12_CHAT_REPLAY_PATH"] { AGT12HistoricalChatReplay(path: path) }
            else { missingReplay }
        default:
            missingReplay
        }
#else
        liveRoot
#endif
    }

#if AGT12_UI_REPLAY
    private static var missingReplay: some View {
        CodexEmptyState(title: "未指定历史原件", detail: "工程回放不会进入真实任务入口。")
    }
#endif

    @MainActor
    private static var liveRoot: some View {
        ContentView(
            store: Store(
                initialState: AppFeature.State(),
                reducer: { AppFeature() }
            )
        )
    }
}
