# Changelog

All notable changes to this project will be documented in this file.
本文件记录项目所有重要变更。

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Open-source readiness: Apache 2.0 license, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`
- GitHub CI workflow: backend tests + SwiftLint/SwiftFormat + iOS build & test
- Issue templates (bug report, feature request) and PR template
- Swift unit tests: 12 test files covering ChatFeature, TerminalFeature, ThreadsFeature, approval parsing, markdown pipeline, and more (1,600+ lines)
- Bilingual README (English / 中文) with architecture overview and screenshots

### Changed
- `swift-composable-architecture` dependency switched from local path to remote versioned reference (`exact: 1.23.1`)
- Markdown preview theme unified between chat view and file viewer
- All network-layer `print()` calls replaced with `OSLog Logger`

### Fixed
- `APIClient`: exponential backoff retry (max 2) for transient errors (timeout, 429, 502–504); `CancellationError` now propagates correctly
- `ChatFeature`: `pendingAssistantDeltas` capped at 5 MB to prevent OOM on long streams
- `TerminalFeature`: `threadBuffers` in-memory cache capped at 10 entries
- `FileBrowserFeature`: `saveTreeCache` effect made cancellable to prevent stale concurrent writes

---

## [0.0.5] - 2026-02-25

### Added
- Terminal feature: WebSocket-based half-screen terminal panel (iOS + Node.js backend)
- Heartbeat timeout, incremental sequence-aware stream replay, SwiftTerm renderer
- Keystroke stream, first-open risk notice banner, safer idle session reclaim
- `pipe` transport fallback when `node-pty` spawn fails

### Fixed
- Terminal bootstrap silence window extended to suppress startup noise
- iOS terminal UX polish (input bar, connection status, error display)

---

## [0.0.4] - 2026-02-24

### Added
- `codex-sessions-tool`: CLI for session backup, restore, verify, and environment health check
- Thread import/export on the worker backend
- Tailscale Serve integration (config-driven, defaults to `svc:opencodex`)
- SSE event batching on iOS: 24 events / 80 ms window to reduce UI redraws

### Fixed
- Removed `projectPath` allowlist block on thread creation
- Approval queue consistency and `cwd`-scoped thread creation

---

## [0.0.3] - 2026-02-19

### Added
- Server-backed model picker in iOS Settings
- Thread archive / unarchive support (iOS + worker)
- Auto-open latest thread on launch; threads grouped and sorted by recency
- Thread history sync/replay performance improvements (iOS + worker)
- iOS push notification flow integration

### Fixed
- Worker `model/list` API updated to new `app-server` schema with fallback
- Thread history `UNIQUE` conflict on duplicate events
- Archived thread list collapsed by default in Settings

---

## [0.0.2] - 2026-02-17

### Added
- Chat markdown bubble layering and visual refinement

### Fixed
- Thread approval recovery consistency
- Chat UX improvements and input bar visibility

---

## [0.0.1] - 2026-02-17

### Added
- Initial iOS client: multi-thread chat, SSE real-time streaming, approval flow
- Worker backend: REST + SSE + WebSocket, SQLite persistence
- Swift package with TCA-based architecture (AppFeature, ChatFeature, ThreadsFeature, ApprovalFeature, SettingsFeature)
- `codex-worker-mvp` Node.js backend with thread, job, event, and approval management

---

## [mvp] - 2026-02-16

Initial working prototype connecting iPhone to a local `codex app-server` instance via a Node.js bridge.
