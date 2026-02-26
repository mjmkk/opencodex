# 聊天文件链接可读与文件系统浏览详细设计（V1）

## English Summary

This document defines V1 design for making chat file references truly actionable on iOS:

1. Convert file references and web links into clickable links in chat messages.
2. Open files with line navigation via a Worker-side file proxy API.
3. Add thread-bound file tree browsing, search, and local cache for weak-network scenarios.
4. Keep the architecture incremental: no full IDE scope in V1, but preserve future extension points (diff/edit/history).

## 0. 结论

本功能可行，建议采用“后端文件代理 + iOS 原生代码阅读器 + 本地缓存”的架构，分三期落地：

1. P0：聊天消息中的文件引用与网页链接都变成蓝链可点击；文件引用可打开并跳转到指定行。
2. P1：补齐文件树浏览、搜索与本地缓存，提升弱网与高延迟场景体验。
3. P2：补齐编辑/保存/差异对比（diff）等增强能力（按需开启）。

该方案兼容当前 `codex-worker-ios` 与 `codex-worker-mvp` 的代码结构，能在不重构主链路的前提下快速上线。

---

## 1. 背景与问题

当前聊天消息会出现如下文件定位文本：

- `codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift:438`

但在 iOS（iPhone Operating System，苹果移动操作系统）前端里，它是纯文本，不可点击、不可读。

现状问题：

1. 无法从聊天直接跳转到代码上下文，反馈链路断裂。
2. 没有完整文件树浏览能力，用户无法在手机端自行定位文件。
3. 纯文本链接无法区分“网页链接”和“文件引用”，交互不一致。

---

## 2. 目标与非目标

### 2.1 目标

1. 聊天内容中的文件引用和网页链接统一蓝链可点击。
2. 文件引用点击后可打开文件并定位到行号（可选列号）。
3. iOS 端提供“文件系统浏览器”：目录树、文件打开、基础搜索。
4. 支持本地缓存，减少重复请求和二次打开延迟。
5. 路径策略放宽：优先保证“有链接就能打开”，不过度限制。

### 2.2 非目标（V1 不做）

1. 不做全量 IDE（Integrated Development Environment，集成开发环境）级编辑能力。
2. 不做 Git（Git，分布式版本控制系统）全功能用户界面（User Interface，用户界面）。
3. 不做二进制文件复杂预览（视频、3D、Office 等）。

---

## 3. 现状基线（基于当前代码）

1. iOS 消息渲染：
- `CodexChatView` 使用 `MarkdownUI` 渲染；当前没有“文件引用点击打开”行为。
- `MessageRenderPipeline` 已包含 `MessageSemanticExtractor`，可提取 `links` 与 `pathHints`，但未绑定跳转行为。

2. 后端能力：
- `codex-worker-mvp` 当前 HTTP（HyperText Transfer Protocol，超文本传输协议）路由没有文件浏览 API（Application Programming Interface，应用程序编程接口）。
- 已有线程/任务/终端接口可复用鉴权、错误模型与日志规范。

3. 本地存储：
- iOS 已使用 `GRDB + SQLite`（SQLite，轻量嵌入式关系型数据库）做线程历史缓存，可在同一数据库扩展文件缓存表。

---

## 4. 总体架构

```text
聊天消息渲染（ExyteChat + MarkdownUI）
        │
        │ 解析文件引用/网页链接
        ▼
链接语义层（LinkSemanticExtractor + LinkNormalizer）
        │
        │ 文件链接 -> codexfs://
        │ 网页链接 -> https://
        ▼
文件查看功能（FileViewerFeature + Runestone）
        │
        │ 请求文件 API
        ▼
Worker 文件服务（codex-worker-mvp /v1/threads/:id/fs/*）
        │
        ▼
macOS 文件系统（宽松访问策略 + 可审计日志）
```

核心原则：

1. 前端不直接访问 macOS 文件系统，只走后端代理。
2. 前端只做展示与缓存；后端负责路径解析、权限策略和文件读取。
3. 链接类型统一抽象为 `LinkTarget`，避免 UI 分支爆炸。

---

## 5. 链接解析与蓝链策略

### 5.1 支持的链接类型

1. 网页链接：`http://`、`https://`。
2. 文件引用：
- 相对路径：`codex-worker-ios/Sources/.../File.swift:438`
- 绝对路径：`/Users/Apple/Dev/OpenCodex/.../File.swift:438`
- 可选列号：`path:line:column`
- 可选 `#L438` 风格（兼容外部文本）

### 5.2 解析顺序

1. 先解析文件引用。
2. 再解析网页链接。
3. 冲突时以“更长匹配、路径存在概率更高”的候选优先。

### 5.3 前端渲染策略

新增 `MessageLinkNormalizer`：

1. 将识别到的文件引用转换为自定义链接：
- `codexfs://open?ref=<urlEncodedRawRef>&threadId=<id>`
2. 将裸网页链接转换为 Markdown 自动链接（蓝链）。
3. 通过 `openURL` 统一分发：
- `codexfs://` -> 打开文件查看器
- `http/https` -> 系统 Web（Web，万维网）视图

### 5.4 误判与降级

1. 若文件解析失败：提示“未找到文件”，可复制原始引用。
2. 若 URL（Uniform Resource Locator，统一资源定位符）非法：保留原文本，不做蓝链。

---

## 6. 后端文件 API 设计（`codex-worker-mvp`）

> 路由风格与现有 `/v1/threads/*` 保持一致。

### 6.1 读取根信息

`GET /v1/threads/{threadId}/fs/roots`

返回当前线程可见根目录列表（宽松模式下通常返回 workspace 根 + 常用根）。

响应示例：

```json
{
  "data": [
    {
      "rootId": "workspace",
      "rootPath": "/Users/Apple/Dev/OpenCodex",
      "displayName": "OpenCodex"
    },
    {
      "rootId": "home",
      "rootPath": "/Users/Apple",
      "displayName": "Home"
    }
  ]
}
```

### 6.2 解析引用

`GET /v1/threads/{threadId}/fs/resolve?ref=<rawRef>`

输入聊天中的原始引用字符串，后端返回标准化定位。

响应示例：

```json
{
  "data": {
    "resolved": true,
    "path": "/Users/Apple/Dev/OpenCodex/codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift",
    "line": 438,
    "column": null,
    "rootId": "workspace"
  }
}
```

### 6.3 列目录

`GET /v1/threads/{threadId}/fs/tree?path=.&cursor=&limit=200`

1. 目录优先、文件其次。
2. 支持分页，避免大目录卡顿。

响应示例：

```json
{
  "data": [
    { "name": "codex-worker-ios", "path": "codex-worker-ios", "kind": "directory" },
    { "name": "README.md", "path": "README.md", "kind": "file", "size": 2710 }
  ],
  "nextCursor": null
}
```

### 6.4 读文件（按行区间）

`GET /v1/threads/{threadId}/fs/file?path=<path>&fromLine=400&toLine=520`

响应示例：

```json
{
  "data": {
    "path": "codex-worker-ios/Sources/CodexWorker/Features/ChatFeature/CodexChatView.swift",
    "language": "swift",
    "etag": "W/\"f-1739970123-8271\"",
    "totalLines": 620,
    "fromLine": 400,
    "toLine": 520,
    "truncated": false,
    "lines": [
      { "line": 400, "text": "..." }
    ]
  }
}
```

### 6.5 查元信息

`GET /v1/threads/{threadId}/fs/stat?path=<path>`

返回大小、修改时间、是否二进制、是否可读。

### 6.6 文本搜索（P1）

`GET /v1/threads/{threadId}/fs/search?q=keyword&path=.&cursor=&limit=50`

返回命中项：`path + line + snippet`。

---

## 7. 路径策略（按你的要求放宽）

### 7.1 默认策略：宽松可用优先

1. 允许解析与读取 `workspace` 根目录下文件。
2. 允许读取 `/Users/Apple` 下路径（便于跨项目跳转）。
3. 只要引用能解析到存在文件，就允许打开。

### 7.2 解析规则

`resolve(ref)` 顺序：

1. 若 `ref` 是绝对路径且文件存在，直接命中。
2. 按 `thread.cwd` 拼接尝试。
3. 按 `workspaceRoot` 拼接尝试。
4. 按已知项目根（`listProjects`）拼接尝试。
5. 最后做“同名文件有限搜索”（限制最大结果数，例如 20）。

### 7.3 审计与兜底

1. 记录 `threadId + ref + resolvedPath + elapsedMs`。
2. 搜索超时直接返回“未解析”，前端可让用户手动复制路径。

---

## 8. iOS 本地缓存设计

### 8.1 目标

1. 首次打开快：先读本地缓存，再后台刷新。
2. 重复打开快：命中缓存后几乎瞬开。
3. 弱网可用：短时离线仍可查看近期文件。

### 8.2 缓存层级

1. L1（Level 1，一层缓存）：内存缓存（最近打开文件片段，极低延迟）。
2. L2（Level 2，二层缓存）：SQLite 持久化缓存（跨启动保留）。

### 8.3 表结构（在现有 `thread-history.sqlite` 上增表）

```sql
CREATE TABLE IF NOT EXISTS fs_dir_cache (
  rootPath TEXT NOT NULL,
  path TEXT NOT NULL,
  etag TEXT,
  payloadJson TEXT NOT NULL,
  fetchedAtMs INTEGER NOT NULL,
  accessedAtMs INTEGER NOT NULL,
  PRIMARY KEY (rootPath, path)
);

CREATE TABLE IF NOT EXISTS fs_file_chunk_cache (
  rootPath TEXT NOT NULL,
  path TEXT NOT NULL,
  etag TEXT NOT NULL,
  fromLine INTEGER NOT NULL,
  toLine INTEGER NOT NULL,
  payloadJson TEXT NOT NULL,
  fetchedAtMs INTEGER NOT NULL,
  accessedAtMs INTEGER NOT NULL,
  PRIMARY KEY (rootPath, path, etag, fromLine, toLine)
);

CREATE INDEX IF NOT EXISTS idx_fs_file_chunk_cache_lru
ON fs_file_chunk_cache(accessedAtMs);
```

### 8.4 缓存策略

1. 读取策略：SWR（Stale-While-Revalidate，先返回旧缓存再后台刷新）。
2. 失效策略：
- ETag（Entity Tag，实体标签）变化则失效。
- 目录缓存默认 30 秒软过期。
- 文件分片缓存默认 5 分钟软过期。
3. 容量策略：
- SQLite 总容量上限 50MB；超出后按 LRU（Least Recently Used，最近最少使用）淘汰。

---

## 9. iOS 前端模块拆分（TCA）

TCA（The Composable Architecture，组合式架构）新增模块建议：

1. `FileExplorerFeature`
- 目录树浏览、搜索入口、最近访问。

2. `FileViewerFeature`
- 文件读取、行号定位、高亮、复制。

3. `FileReferenceParserService`
- 从消息文本提取文件引用、网页链接。

4. `FileCacheStore`
- 对接 GRDB（Swift SQLite 工具库）实现目录/文件分片缓存。

---

## 10. 开源方案选型

### 10.1 推荐主方案

1. Runestone（iOS 原生代码编辑/查看组件）
- 仓库：`https://github.com/simonbs/Runestone`
- 用途：文件查看页（只读）与行号定位。
- 优点：原生性能好、滚动手感好、易融入 SwiftUI（SwiftUI，苹果声明式界面框架）。

2. Exyte Chat（现有聊天组件）
- 仓库：`https://github.com/exyte/Chat`
- 用途：继续承载消息列表，新增链接点击分发。

### 10.2 可选增强方案

1. Monaco Editor（Visual Studio Code 同源网页编辑器）
- 仓库：`https://github.com/microsoft/monaco-editor`
- 特点：功能强，但移动端资源占用高，适合后续编辑场景。

2. CodeMirror 6（轻量网页编辑器）
- 仓库：`https://github.com/codemirror/dev`
- 特点：比 Monaco 轻，适合 WebView（Web View，网页视图容器）方案。

3. iSH（终端应用）
- 仓库：`https://github.com/ish-app/ish`
- 用途：交互细节参考，不作为文件浏览主实现。

---

## 11. 分期与排期

### P0（2-3 天）

1. 后端新增 `resolve / tree / file / stat` 最小接口。
2. 前端支持文件引用与网页链接蓝链。
3. 点击文件引用可打开文件并跳行。

### P1（2-4 天）

1. 文件树浏览与分页。
2. 本地缓存（目录 + 文件分片）。
3. 搜索接口与搜索页。

### P2（按需）

1. 编辑/保存。
2. 与终端联动（在当前文件目录执行命令）。
3. 差异对比与历史版本查看。

---

## 12. 关键风险与应对

1. 风险：文件引用误判（例如普通文本被识别为路径）。
- 应对：解析规则加白名单后缀、存在性校验、失败降级。

2. 风险：大目录/大文件导致卡顿。
- 应对：分页、按行区间读取、缓存、后台预取。

3. 风险：路径策略过宽带来隐私泄露。
- 应对：默认限制在 `/Users/Apple`；写审计日志；后续可在设置中切换“严格/宽松”。

---

## 13. 验收标准（Definition of Done）

1. 聊天中的 `http/https` 链接可点击并打开网页。
2. 聊天中的 `path:line` 可点击并定位到文件对应行。
3. 文件树可浏览并打开任意可见路径文件。
4. 断网后可打开最近浏览的缓存文件片段。
5. 弱网下重复打开同一文件，平均耗时明显下降（目标 >50%）。

---

## 14. 推荐先做的实现顺序（可直接开工）

1. 后端先实现 `resolve + file`，先打通点击到可读。
2. 前端接入 `codexfs://` 路由与 `Runestone` 文件查看页。
3. 再加 `tree` 与缓存表，补齐完整浏览能力。
