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
    ],
    dependencies: [
        // TCA - Composable Architecture（本地路径）
        .package(path: "../swift-composable-architecture"),
        // exyte/Chat - 聊天 UI 组件（本地路径）
        .package(path: "../Chat"),
        // EventSource - SSE 客户端（本地路径）
        .package(path: "../EventSource"),
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
        .testTarget(
            name: "CodexWorkerTests",
            dependencies: ["CodexWorker"],
            path: "Tests"
        ),
    ]
)
