# Security Policy

## Supported Versions

当前处于快速迭代阶段，仅保证 `main` 分支最新提交的安全修复。

## Reporting a Vulnerability

如果你发现了安全漏洞，请不要公开提交 issue。

推荐流程：

1. 使用 GitHub Security Advisory（安全通告）私密上报。
2. 如果暂时无法使用 Security Advisory，请联系仓库维护者并说明：
   - 影响范围
   - 复现步骤
   - 可能的修复建议

## Response SLA

- 24 小时内确认收到
- 72 小时内给出初步分级
- 7 天内给出修复计划或缓解措施

## Scope

重点关注：

- 鉴权与令牌处理（Worker Token、APNs 密钥）
- 远端终端与文件系统访问控制
- 会话与线程数据持久化安全
- 依赖供应链风险
