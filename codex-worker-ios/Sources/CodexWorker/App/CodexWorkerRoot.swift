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
        if let path = ProcessInfo.processInfo.environment["AGT12_CHAT_REPLAY_PATH"] {
            AGT12HistoricalChatReplay(path: path)
        } else {
            liveRoot
        }
#else
        liveRoot
#endif
    }

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
