# 大 Goal 的成员收纳 · 2026-11-13

基线 `3412f2b8`，AGT-12。Human 反馈 BOX-159 关联修正后，展开的线程数量过多。

## 事实与改动

真实 `/v1/harness/tree` 于 2026-11-13T03:52:25.269Z 返回 BOX-159：84 个成员，包括 1 个 Master、23 个 Worker、60 个 ChatGPT 思考对话。23 个 Worker 中 22 个无状态观测，1 个 idle，不能据此把它们认定为已完成或删除。

- 大 Goal 首页只显示 Master、当前工作线程、全部需要 Human 处理的 Worker，以及最多 3 个 running Worker；其余工作进入独立目录。
- BOX-159 展开后提供“工作线程 23”和“思考对话 60”两个入口。子代理仍在各自线程下折叠；Worker 不超过 3 个的小 Goal 保持直接可点。
- 完整目录支持名称、原生 ID、工作票编号/标题、harness、机器和模型搜索。多个关键词同时匹配，不改变原生身份或正式绑定。
- 同一个线程绑定 BOX-167、BOX-169 时，搜任一编号都返回同一个成员，两张票同时保留。
- 从目录打开线程后，回到目录保留搜索位置；返回首页时，当前工作线程直接露出。
- 思考对话仍打开原 ChatGPT 对话；目录只改变收纳，不改变历史或投递路径。

本次只改 iOS，无 Registry、Linear 父链、归属 resolver 或服务端发布变更。

## 验证

- 真实 84 成员 fixture 回归：Master + 两个完整目录覆盖全部成员且目录内无重复；BOX-159 默认不铺开其他 Worker，当前线程和所有 needs_you Worker 保留；小 Goal 保持直达。
- 搜索回归：BOX-167/169、中文“迁移”、BOX-133 + Ubuntu、空白和无结果；ChatGPT 的 BOX-133 工作票绑定也可检索。
- 全量 25 项 XCTest + 11 项 Swift Testing 通过，最终目录专项 11 项通过；模拟器 App 构建通过。
- Simulator 使用真实后端，实际观察 BOX-159 Master 下只出现两个目录入口，后续 Goal 同屏可见。
- 实际搜索 BOX-167、BOX-169 均得到 1/23 同一个迁移成员；BOX-133 Ubuntu 得到唯一对应 Worker；思考目录搜 BOX-133 得到 6/60。
- 实际搜索 BOX-166 并点入，仍显示原 Ubuntu 线程和 CTest 对话；返回保留 BOX-166 搜索，再返回首页时该当前线程在 Master 下直接显示。

原始成员 fixture 延用 `codex-worker-ios/Tests/CodexWorkerTests/Fixtures/harness-goals-2026-11-13.json`，没有替身 API 或虚构 AI 回复。本次没有向业务线程发送新消息。

L1：按以上代码、真实快照和模拟器行为检查，本轮收纳改动通过。真 iPhone 安装效果仍需与模拟器验收区分；M2 仅同步源码，保留 Package.resolved 的既有修改。
