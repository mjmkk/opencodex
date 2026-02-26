# Changelog

All notable changes to this project will be documented in this file.  
本文件用于记录项目的所有重要变更。

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
格式遵循 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，版本遵循 [Semantic Versioning](https://semver.org/spec/v2.0.0.html)。

## [Unreleased]

### Added

- Apache License 2.0 project licensing baseline (`LICENSE`, `NOTICE`, package license fields).
- Open source governance docs (`CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`).
- GitHub issue / pull request templates.
- CI workflow for backend tests and iOS build checks.

### 新增（中文）

- 建立 Apache License 2.0（Apache 2.0 开源许可证）合规基础（`LICENSE`、`NOTICE`、依赖许可证声明）。
- 新增开源治理文档（`CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`、`SECURITY.md`）。
- 新增 GitHub Issue / Pull Request 模板。
- 新增后端测试与 iOS 构建检查的 CI 工作流。

### Changed

- Switched `swift-composable-architecture` dependency from local path to remote versioned source.
- README clarified Codex app-server dependency boundary and contribution paths without full runtime access.

### 变更（中文）

- `swift-composable-architecture` 依赖由本地路径切换为远端版本化引用。
- README 补充 Codex app-server 运行时依赖边界，并说明无完整运行权限时可参与的贡献路径。

## [0.1.0] - 2026-02-25

### Added

- iOS chat threads, streaming messages, approval flow.
- Split terminal panel with reconnect and sequence-aware stream replay.
- File browser with code highlighting, markdown preview, file deep-links.
- Worker backend with REST + SSE + WebSocket and SQLite cache.
