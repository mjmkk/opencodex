# 隔离候选最小契约

来源为现网冻结字节，无已验证 Git 来源。唯一修改面为 DesktopRelayClient 和同名既有测试。生产、服务、owner、ASAR、手机、配置与真实请求均不操作。

- 保留初始 eager child；连接失败拒绝该代全部 pending，respond 保持 OUTCOME_UNKNOWN。
- 只有独立的新 list 可新建 child；closed read/respond 拒绝，显式 close 永久拒绝；无操作重放、定时重试或后台重连。
- 新 list 共享一次同步 child 创建；每个 child 自己的 parser/pending/callback。旧 data/error/close/stdin error/timer 不得作用新代。
- 失败代销毁本代 streams 并 SIGTERM 本代 child；收到 close 前不创建下一条 follower，若尚未退出则该次新 list 仍 503。无清理定时器或强杀；挂死且不退出的 relay 仍 fail-closed，不能累积子进程。
- timeout 本身不判定连接死亡，不触发重建或写重放。
- 原 JSON body 字节、typed ID、完整 request/owner/version/receipt 校验由原未修改 adapter/follower 保留。新 child 的 Adapter 自有新 generation，旧 receipt 不可复用。

验证：原 int64/raw 与 lost-respond 测试保留；fake JSONL 实际子进程覆盖初次启动失败、全部 pending 失败、新 list 恢复、并发 list、unknown respond 单次写、timeout、explicit close；确定性注入旧代迟到事件；未修改真实 Adapter 的 fake-follower 子进程覆盖代际 receipt、typed ID 和版本验证，既有 Python 单元测试覆盖完整 request/owner guard。
