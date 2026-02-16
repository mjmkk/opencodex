// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CodexWorker",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "CodexWorker",
            targets: ["CodexWorker"]
        ),
        // 注意：iOS 不支持 .executable，需要在 Xcode App 项目中使用此库
        // 如需创建 iOS App，请参考项目根目录的 README 或创建新的 Xcode App 项目
    ],
    dependencies: [
        // TCA（The Composable Architecture，组合式架构库）
        .package(path: "../swift-composable-architecture"),
        // Exyte Chat（聊天 UI 组件）
        .package(url: "https://github.com/exyte/Chat.git", from: "2.7.6"),
        // EventSource（SSE，Server-Sent Events 客户端）
        .package(url: "https://github.com/Recouse/EventSource.git", from: "0.1.5"),
    ],
    targets: [
        .target(
            name: "CodexWorker",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "ExyteChat", package: "Chat"),
                .product(name: "EventSource", package: "EventSource"),
            ],
            path: "Sources/CodexWorker",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        // 保留 CodexWorkerApp 源代码供 Xcode App 项目使用
        // 注意：这是一个普通 target，不是 executable
        .target(
            name: "CodexWorkerApp",
            dependencies: ["CodexWorker"],
            path: "Sources/CodexWorkerApp"
        ),
        .testTarget(
            name: "CodexWorkerTests",
            dependencies: ["CodexWorker"],
            path: "Tests"
        ),
    ]
)
