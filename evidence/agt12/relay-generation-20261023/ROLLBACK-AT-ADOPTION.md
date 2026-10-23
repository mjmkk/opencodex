# 本轮单文件回退边界

旧源精确字节保存为 desktop-relay-client.before.js；原 mode/uid/gid 保存于 result.private.json 的 source_original_metadata。备份文件保留原 mode，外层目录为0700。源基线 SHA256 为 4b61fd1ed0dc97e46086fa41b9096766a62d2aa7792ecc99680628f6f13655a2；采用目标为 db34a0c8e65f57e7e88ed498e0a62f524305ee995956c9d33f6fe1dff7249783。没有已验证 Git 来源。

adopt.py 仅在本轮已替换后的实际失败时，最多执行一次原字节/原权限的同目录原子恢复，并一次重启 opencodex-mobile.service。先前失败与回退返回均保存，不循环、不再 GET。rollback_attempts=1 时不得以本授权重复回退。

本轮成功后若将来需要回退，由 Root 按当时源 SHA、进程身份与业务状态重新核定具体操作；此说明不自行触发回退。只恢复这一个 JS 并重启同 mobile 单元，绝不恢复旧 DB、journal、状态、receipt、配置或单元，不重启 Desktop/PostgreSQL/Tailscale/主机，也不重发响应。

Root 在本次执行已开始后补充的未来回退保护：恢复前必须核当前源仍为本轮 NEW 或已是 OLD；任何第三种 SHA 必须停止并报告未知写入，不覆盖。该约束到达时本次脚本已运行，Root明确要求保持本次完整返回；本次成功且 rollback_attempts=0，未触发回退分支。冻结 adopt.py 保留实际执行字节，不事后改写。将来如需回退必须按本段及当时 Root 核定方案执行，不直接重跑本轮历史脚本。
