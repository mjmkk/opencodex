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
        .package(path: "../codex-activity-models"),
        // MarkdownUI（完整 Markdown 渲染，支持 GitHub 风格 Markdown 的表格/任务列表）
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.0.2"),
        // GRDB（SQLite 封装）
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .target(
            name: "CodexWorker",
            dependencies: [
                .product(name: "CodexActivityModels", package: "codex-activity-models"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/CodexWorker",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "CodexWorkerTests",
            dependencies: ["CodexWorker"],
            path: "Tests",
            resources: [.copy("CodexWorkerTests/Fixtures")]
        ),
    ]
)
