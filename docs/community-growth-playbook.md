# OpenCodex 社区增长作战手册 / Community Growth Playbook

## 中文

### 目标
- 14 天内将仓库 `Watch` 从当前基线提升到 `20+`。
- 不追求泛流量，优先吸引“会长期使用并关注版本更新”的开发者。

### 指标定义
- `Watch`：核心目标，反映对版本更新的订阅意愿。
- `Star`：次级目标，反映首次兴趣。
- `Conversion`（转化率）：`Watch / Unique Visitors`。

### 节奏（14 天）
1. D1-D2：完善仓库首屏转化
- README 首屏直接给出 Watch/Star/Discussions 三个入口。
- 提供 30 秒演示图（聊天 + 终端 + 文件浏览）。
- Release/Issue 模板统一中英双语，降低参与门槛。

2. D3-D7：定向分发（每天至少 1 个渠道）
- 海外：X、Reddit（r/iOSProgramming、r/swift）、Hacker News。
- 中文：V2EX、掘金、少数派。
- 每条发布都必须给出：
  - 解决的问题（对谁有价值）
  - 30 秒可见结果（GIF/截图）
  - 明确 `Watch` 行动号召（Call To Action）

3. D8-D14：复投与迭代
- 按渠道回看互动，复写高反馈内容。
- 每 3 天发一个小版本（Release Notes 保持短小、可读、可执行）。
- 每周发布一次“真实使用案例（Showcase）”汇总。

### 内容模板（单条）
- 开头：一句话价值主张
- 中段：3 个可验证能力点（实时对话 / 终端 / 文件）
- 结尾：
  - `Watch this repo for release updates`
  - 仓库链接

### 账号动作（维护者）
- 24 小时内响应 Issue / Discussion。
- 给新贡献者首个 PR 快速合入，形成正反馈。
- 每周手动整理一次 FAQ，减少重复答疑成本。

### 追踪方式
- 每天记录：Visitors、Clones、Stars、Watchers。
- 使用 `make growth-report` 拉取最新统计。

### 完成标准
- `Watch >= 20`。
- 连续 2 周每周新增 `Watch >= 5`（避免一次性峰值后归零）。

---

## English

### Goal
- Reach `20+ Watchers` in 14 days.
- Prioritize long-term users who subscribe to releases, not vanity traffic.

### Metrics
- `Watch`: primary metric (release subscription intent).
- `Star`: secondary metric (first-level interest).
- `Conversion`: `Watch / Unique Visitors`.

### 14-Day Execution
1. D1-D2: Improve repository conversion surfaces
- Put Watch/Star/Discussions links above the fold in README.
- Provide a 30-second product preview (chat + terminal + file browsing).
- Keep Release/Issue templates bilingual to reduce contribution friction.

2. D3-D7: Targeted distribution (at least one channel/day)
- Global: X, Reddit (r/iOSProgramming, r/swift), Hacker News.
- Chinese: V2EX, Juejin, SSPAI.
- Every post must include:
  - Who this helps
  - 30-second proof (GIF/screenshot)
  - Clear Watch call-to-action

3. D8-D14: Iterate and compound
- Repost/refine high-performing messages.
- Ship a small release every 3 days with concise release notes.
- Publish one weekly showcase recap.

### Single-Post Structure
- Opening: one-sentence value proposition.
- Body: 3 verifiable capabilities.
- Closing:
  - `Watch this repo for release updates`
  - repository link.

### Maintainer Habits
- Respond to issues/discussions within 24 hours.
- Merge first-time contributor PRs quickly where quality permits.
- Publish weekly FAQ to reduce repeated support overhead.

### Tracking
- Record daily: visitors, clones, stars, watchers.
- Use `make growth-report` for a quick snapshot.

### Exit Criteria
- `Watch >= 20`.
- Keep `>= 5` new watchers per week for two consecutive weeks.
