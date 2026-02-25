# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Apache License 2.0 project licensing baseline (`LICENSE`, `NOTICE`, package license fields).
- Open source governance docs (`CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`).
- GitHub issue / pull request templates.
- CI workflow for backend tests and iOS build checks.

### Changed

- Switched `swift-composable-architecture` dependency from local path to remote versioned source.
- README clarified Codex app-server dependency boundary and contribution paths without full runtime access.

## [0.1.0] - 2026-02-25

### Added

- iOS chat threads, streaming messages, approval flow.
- Split terminal panel with reconnect and sequence-aware stream replay.
- File browser with code highlighting, markdown preview, file deep-links.
- Worker backend with REST + SSE + WebSocket and SQLite cache.
