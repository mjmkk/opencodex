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
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.1"),
        // Exyte Chat（聊天 UI 组件）
        .package(url: "https://github.com/exyte/Chat.git", from: "2.7.6"),
        // MarkdownUI（完整 Markdown 渲染，支持 GitHub 风格 Markdown 的表格/任务列表）
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.0.2"),
        // EventSource（SSE，Server-Sent Events 客户端）
        .package(url: "https://github.com/Recouse/EventSource.git", from: "0.1.5"),
        // GRDB（SQLite 封装）
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        // SwiftTerm（终端渲染）
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.6"),
        // Runestone（代码编辑器视图）
        .package(url: "https://github.com/simonbs/Runestone.git", from: "0.5.1"),
        // TreeSitterLanguages（Runestone 语法语言包）
        .package(url: "https://github.com/simonbs/TreeSitterLanguages.git", from: "0.1.10"),
    ],
    targets: [
        .target(
            name: "CodexWorker",
            dependencies: [
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "ExyteChat", package: "Chat"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "EventSource", package: "EventSource"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Runestone", package: "Runestone"),
                .product(name: "TreeSitterSwiftRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterJavaScriptRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterTypeScriptRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterTSXRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterJSONRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterYAMLRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterTOMLRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterMarkdownRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterBashRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterPythonRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterCSSRunestone", package: "TreeSitterLanguages"),
                .product(name: "TreeSitterHTMLRunestone", package: "TreeSitterLanguages"),
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
