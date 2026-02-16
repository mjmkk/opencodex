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
    public static func makeRootView() -> some View {
        ContentView(
            store: Store(
                initialState: AppFeature.State(),
                reducer: { AppFeature() }
            )
        )
    }
}
