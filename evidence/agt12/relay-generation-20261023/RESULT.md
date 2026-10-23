# AGT-12 relay child 生命周期隔离候选

候选已完成，production_apply=false，未修改或部署现网。唯一差异为 DesktopRelayClient 和同名既有测试；其余依赖为原字节冻结。当前正式服务保持先前恢复后的版本，本次没有 HTTP、IPC、owner、模型任务、真实请求、手机或服务重启动作。

## 来源与实现

在 /home/spirit/agt12-mobile/codex-worker-mvp 和已知 /home/spirit/workspaces/agt12-goal-overview-20261012/mobile 读取到相同 4b61fd1ed0dc97e46086fa41b9096766a62d2aa7792ecc99680628f6f13655a2 源码；两个目录均无 Git 仓库。限定路径搜索未发现另一份可验证 Git 原仓。因此明确从现网字节冻结构造，不声称 canonical Git/commit；BASELINE.json 记录精确来源/字节/SHA。未覆盖已有 worktree 或他人未提交修改。

- 保持初始 eager child 及正常 read/respond transport 兼容；只有连接进入 closed 后的独立新 list 能建下一代，closed read/respond 不重连。
- 每代独立 pending/parser/callback；失败清除并拒绝所有该代 pending，respond 报 NATIVE_RESPONSE_OUTCOME_UNKNOWN，不自动重放任何操作。
- 同步创建使并发 list 共用一条新 child；旧 child 的晚到输出/error/close/stdin error 不能污染新代。
- 失败销毁该代三条 streams 并 SIGTERM 该 child。活 PID 未 close 前拒绝新 list，避免无界 follower 累积；若 child 挂死且不退出，仍 503，须后续独立恢复，候选不新增定时器、强杀或重试。
- 显式 close 永久 disposal；timeout 仅拒绝该操作，不把超时判成 child 死亡，不重连或重放。
- JSON body 只作合法性校验，原文逐字节发送；未改 Adapter/Follower 的 typed ID、owner、完整 request、版本、receipt 或 attempted/submitted 写保护。新子进程 Adapter 自有新 generation，旧 receipt 拒绝。

## 已执行验证

精确现网 Node v22.23.2，入口见 VERIFICATION.json；Node fake child 用 process.execPath。13 项最终行为测试全部通过（TEST-AFTER-2.log，2.593240674 秒）；未改动 Python Adapter/Follower 的 9 项既有 guard 测试全部通过（TEST-ADAPTER.log）。未为形式重复最终 PASS。源码及测试 node --check 通过。

覆盖首次 spawn 失败后独立 list 恢复，连接丢失拒绝旧 pending，新 list 不重放，respond 断连/timeout 的 unknown 与单次写，closed read/respond 拒绝，并发 12 个 list 只建一条 child，旧 child 晚事件隔离，活旧 child 阻新 follower，重建后 raw/int64/string ID 保持，显式 close 永久关闭，真实冻结 Adapter 的新 generation 拒绝旧 receipt 与 typed/version 错误。旧代晚事件是明确的 EventEmitter 故障注入，其余主要进程行为使用真实本地 synthetic JSONL child；Adapter fixture 只替换 follower 为内存假来源，不初始化真实 follower。

原有两条测试的断言与语义完整保留。RED-BEFORE.log 保留首批 11 项对旧实现的实际结果 5 PASS/6 FAIL；TEST-AFTER-1.log 保留候选首轮 11 PASS。首批初始启动用例的首个失败发生在 closed 下 malformed-list 的错误码差异，其他恢复用例实际止于新 list 的 NATIVE_OWNER_UNAVAILABLE；不把每项 RED 都泛称同一根因。后来补充两项风险形成最终 13 项。

独立只读审核未发现本轮范围阻断，见 STATIC-REVIEW.md；它不是 Root 集成 L1 或生产验证。

## 未证明与采用边界

本候选只修 Node 已检测到的 child error/close/stdin error、解析失败等导致永久 closed 的生命周期。Follower 内部 IPC reader closed 但 Python child 仍活的情形仍未解决；不是所有 owner/IPC/网络错误的自愈方案。timeout 不判死；原首次 discovery RuntimeError 因缺失原 stderr 的原因仍 unknown。先前 503 与单次服务恢复原件保持原记录，不被候选模拟结果覆盖。

没有真实 pending/read/respond、原 turn 继续或 Human 操作验收；不构成完整 V1、手机 Overview、UI/安装/效果 L2 或 Human 接受。

下一步仅由 Root 对 candidate.patch、源基线及测试作契约/集成 L1；如果决定采用，仍须核对真实集成来源及生产字节/责任边界。当前未授权生产改代码、自动重连 owner/read/respond 或再重启服务。
