//
//  CodexWorkerRoot.swift
//  CodexWorker
//
//  根容器：对外提供可嵌入的根视图
//

import SwiftUI

/// 根视图工厂。AGT-26 S6 原地重写后，根就是 RootView（Goal 树 + 线程页）
public enum CodexWorkerRoot {
    @MainActor
    public static func makeRootView() -> some View {
        RootView()
    }
}
