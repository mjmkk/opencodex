# Contributing to OpenCodex

感谢你愿意参与 OpenCodex。
本文档定义了最小贡献流程，确保 iOS 客户端、Worker 后端与文档在同一质量基线下演进。

## 1. 开始前请先确认

- 你同意本仓库采用 Apache License 2.0（Apache 2.0 开源许可证）。
- 你提交的代码为原创，或你有权以 Apache-2.0 方式提交。
- 不要提交密钥、令牌、私有证书、`worker.config.json` 等本地敏感文件。

## 2. 开发环境

最低要求：

- macOS（构建 iOS 端）
- Xcode 16+
- Node.js >= 22（`codex-worker-mvp`）
- Node.js >= 20（`codex-sessions-tool`）

可选要求：

- `codex` CLI（Command Line Interface，命令行接口）
- 有效的 Codex app-server 访问权限（用于端到端联调）

> 没有 app-server 权限也可以贡献：可先跑单元测试与静态检查，提交与 UI/状态机/文档相关的 PR。

## 3. 分支与提交规范

- 分支命名：`codex/<topic>`
- 提交信息建议使用 Conventional Commits（约定式提交）风格：
  - `feat:` 新功能
  - `fix:` 修复
  - `docs:` 文档
  - `test:` 测试
  - `chore:` 工具或依赖

示例：

```text
feat(ios): add markdown quote block style parity
fix(worker): prevent stale cursor replay on reconnect
```

## 4. 提交前自测（必须）

### 后端

```bash
cd codex-worker-mvp && npm ci && npm test
cd codex-sessions-tool && npm ci && npm test
```

### iOS 构建

```bash
cd CodexWorkerApp/CodexWorkerApp
xcodebuild -project CodexWorkerApp.xcodeproj \
  -scheme CodexWorkerApp \
  -destination 'generic/platform=iOS Simulator' \
  -skipMacroValidation \
  build
```

### 代码风格（建议）

```bash
swiftformat --lint . --config .swiftformat
swiftlint lint --config .swiftlint.yml
```

## 5. Pull Request 要求

请在 PR 描述里至少包含：

- 变更目的与范围
- 风险点与回滚策略（如涉及状态机、同步、缓存）
- 自测结果（命令 + 结果）
- UI 改动请附截图或录屏

## 6. 兼容性策略

- 优先保证现有 API（Application Programming Interface，应用程序编程接口）兼容。
- 如需破坏性变更，请在 PR 标题标注 `BREAKING CHANGE`，并更新 `CHANGELOG.md`。

## 7. 安全问题

安全漏洞请不要公开提 issue，参考 `SECURITY.md`。
