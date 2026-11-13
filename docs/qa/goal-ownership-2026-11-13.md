# 手机工作树归属走查 · 2026-11-13

范围：AGT-12 / AGT-26 S6；基线 `20d64b15`。Human 报告截图中的 Worker 看起来没有 Master，要求走查产品。

## 结论与原始事实

原接口只按同一个 Registry Issue 分组，没有解析 Work 的当前 owning Goal。因此 50 个分组中 40 个看起来没有 Master；其中 37 个实际能沿当前 Linear 父链找到已登记的 Goal Master。

使用生产 `runtime/owning_goal.mjs` 的 `resolveOwningGoal`，对实际 Registry 和 Linear 快照重放，结果为：

- 12 个展示分组：9 个已验证 Master 的 Goal、1 个未登记 Master 的 Goal、2 个未关联 Goal 的 Work。
- 223 个原生身份全部保留；同一 Goal 内合并重复身份，保留全部工作票绑定。同一线程跨 Goal 登记仍可出现于不同 Goal。
- Registry 成员、Linear 父链和历史 CALL 均未改写；历史 RETURN 目标不用于推断当前 Master。

| 截图里的工作 | 当前归属 | 依据 |
|---|---|---|
| BOX-166、BOX-167、BOX-169、BOX-173、BOX-62、BOX-45、BOX-28 | BOX-159 | 当前 Linear 父链；Goal 正式 Registry Master |
| BOX-133 | BOX-159 | BOX-133 → BOX-62 → BOX-159 |
| BOX-123 | BOX-163 | 当前 Linear 父链 |
| BOX-139 | BOX-161 | 当前 Linear 父链 |
| AGT-27、AGT-37 | AGT-26 | 当前 Linear 父链 |

真实数据例外：AGT-6、AGT-39 的当前父链没有 Goal；AGT-24 是 Goal，但没有正式登记的 Master。不依据标题、Related 或历史 CALL 臆造关系。

## 修复

- `/v1/harness/tree` v2：批量读取当前 Linear 标签和父链，补齐 Registry 以外的父节点，复用生产 resolver 后按 Goal 聚合；只有 Goal Registry 的 Master 显示为 Goal Master。
- Work 自己登记的 Master 保留原绑定角色，在父 Goal 内显示为“工作负责人”。迁移线程 `01a19f43-ec2e-7de0-958a-8ec68009f315` 在 BOX-159 下只显示一次，保留 BOX-167、BOX-169 两个入口。
- 首页显示 Goal Master、工作数、执行线程数、工作票和归属核对时间；未关联 Goal 的 Work 单独分区；AGT-24 显示“未登记 Master”。Linear 元数据缓存 10 分钟，显示实际核对时间。
- 思考线程原来同时进入普通成员列表和专用列表，造成重复且折叠无效。现在 Master → 最多 3 个思考线程 → Worker；思考线程可展开/收起，子代理继续挂在主线程下面。
- ChatGPT 思考线程改为打开原 ChatGPT URL，不再把 conversation ID 送往 Codex Mirror 或发送接口；深链落入该 ID 时呈现 ChatGPT 入口。
- 首页缓存只接收 v2，并按地址和凭证 scope 隔离；切换连接后清除当前旧树，旧请求不得覆盖新连接。Claude 正文缓存也改为按 scope 隔离，旧响应在连接改变后不写入新 scope。
- 首页失败提供可点“重试”；工作票同时保留在列表长按菜单和聊天菜单，补全无障碍说明。
- 真实走查再次复现“服务端已回，页面不更新”：旧代码把补历史、读取审批和最新回复轮询串行执行。拆为独立生命周期任务，最新消息不再等待 Mirror 或审批读取；切到后台/其他线程会取消，回前台重新启动。

## 真实系统验证

- 对 50 组实际只读快照重放，12 组/223 个唯一身份/9 个正式 Master；校验所有原生身份和迁移线程两张工作票未丢失。
- 临时 HTTP 服务调用真实数据库、Linear、Node SSH 状态读取，鉴权 200，schema 2，12 组/9 个正式 Master。
- 正式服务发布后回读：2026-11-13T03:04:53.754Z，鉴权 200，schema 2，12 组及上述 3 个数据例外。
- 23 项 XCTest + 11 项 Swift Testing，0 失败；App 模拟器构建通过。新增两项用真实投影快照验证成员去重、唯一 Master、Work 负责人、工作票保留和思考线程折叠。
- Simulator 实际点击：BOX-159 下打开 BOX-166，仍显示原 Ubuntu 身份和真实 CTest 对话；返回列表，迁移线程长按菜单同时包含 BOX-159、BOX-167、BOX-169；底部两条“归属待确认”及 AGT-24 的缺 Master 标注正确。
- Simulator 实际展开/收起 AGT-26 Master 的 16 个子代理；默认思考线程 3 条，没有原来的重复渲染。列表通过 AX 的 Scroll Down/Up 实际到达其他成员和底部例外，不能据此扩展为真机手指滚动验收。
- 修复前 `QA_GOAL_OWNER_1113` 于 03:16:15.510Z 成为真实用户记录，03:16:19.128Z 已有 OWNER_OK，页面仍停留在旧内容。拆分任务后自动显示这条回复；再从 UI 发送 `QA_GOAL_POLL_FIXED reply POLL_OK only`，下一轮界面观察自动出现 POLL_OK，无手动刷新。两条验证消息在服务端各只有一条用户记录，原始消息回执保留在 `docs/qa/evidence/goal-ownership-chat-2026-11-13.json`。
- 聊天菜单实际显示 AGT-26 Goal 与 AGT-47 工作票；真实 ChatGPT conversation 深链显示原对话标题和“在 ChatGPT 打开”入口，没有 Codex 发送框。

## 发布与证据

服务：`opencodex-mobile`，仅重启手机服务。

- 发布：`/opt/spirit/opencodex-mobile/releases/20261113-agt12-goal-topology-v2`
- 上一版本：`/opt/spirit/opencodex-mobile/releases/20261113-agt12-goal-topology`；修复前基线 `20261112-agt26-s6-live` 也保留。
- 回滚记录：spirit-master `~/scratch/agt-s6/rollback-20261113-goal-topology-v2.txt`
- 线上 routes SHA256：`5cc8a3510aae473f80a1b50dc47725f3c986ce55df3d3a27f4947bb5f478dfb6`
- 线上 topology SHA256：`effeaa574658f541cbc4e05d6ba6b7bd17f4218bd57aeb73a79d1daff87b2e18`

上述两份线上源码与提交源码哈希一致。原来未跟踪的线上 routes、live-tail 源码本次纳入仓库，避免发布物与仓库脱节。

真实数据投影保留于 `codex-worker-ios/Tests/CodexWorkerTests/Fixtures/harness-goals-2026-11-13.json`。原始 Registry/Linear/合同快照留在 spirit-master `~/scratch/agt-s6/product-*.json`，未将合同全文或凭据写入仓库。

重放命令（在有生产 resolver 的 spirit-master）：

```sh
node codex-worker-mvp/scripts/harness-product-replay.cjs product-tree-before.json product-linear.json product-tree-after.json
```

原始响应 SHA256 `a4cd06000046bd10410d690f44a37e919a1cfd971b0111e56242e9392c75371d`；Linear 快照 `48ff1a76d5d8ff1ab4c261f8e30ad58aa95446fe17e672552e7f92064585bb7b`；投影快照 `540ccbfd657eadf28d4a6c997508178b145034a8caf9d3187f1c6c7cca36dd3b`。

## 判断与边界

L1：归属修复采用生产 resolver 和实际数据，未改变业务真值；已完成的源码、API、模拟器检查支持该修复。AGT-12 长期 Goal 继续 In Progress，不宣称完整 V1 验收。

- 真 iPhone、锁屏通知、自然 Approval、steer/Stop 不在本次验收内。
- ChatGPT URL 路由已用真实 conversation ID 校验；未把浏览器登录或对话访问授权计作已验收。
- `harness/send` 备用路径仍只覆盖 spirit-master Codex、M1 Codex/Claude；remote-control 和 Ubuntu 的真实写入不在本轮验证内，不能因为关系显示正确就宣称各机器都能收发。
- M2 按既定分工仅同步源代码，保留已有 Package.resolved 修改；不操作签名、钥匙串或真机安装。
