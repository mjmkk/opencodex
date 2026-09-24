// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexActivityModels",
    platforms: [.iOS(.v17)],
    products: [.library(name: "CodexActivityModels", targets: ["CodexActivityModels"])],
    targets: [.target(name: "CodexActivityModels")]
)
