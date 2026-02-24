# codex-sessions-tool

`codex-sessions-tool` 是一个面向 Codex 会话目录（默认 `~/.codex`）的命令行工具，提供四类能力：

1. `backup`：导出会话数据包
2. `restore`：导入会话数据包
3. `verify`：做可恢复性校验
4. `doctor`：做环境体检（目录、权限、JSONL）

其中 `JSONL` 是 `JSON Lines`（每行一个 JSON 对象）。

## 适用场景

1. 迁移会话到新机器或新目录
2. 同机“追加导入”历史线程，不覆盖当前线程
3. 导出后做完整性校验（`manifest + checksums`）
4. 定位 `session_index.jsonl` 和会话文件不一致问题

## 安装与运行

```bash
cd codex-sessions-tool
npm test
node ./bin/codex-sessions.js help
```

## 一次完整流程（推荐）

```bash
# 1) 导出为目录（推荐：便于校验和排错）
node ./bin/codex-sessions.js backup \
  --codex-home ~/.codex \
  --manifest-only true \
  --out /tmp/codex-export \
  --threads active \
  --since 2026-02-20 \
  --until 2026-02-23

# 2) 校验导出包
node ./bin/codex-sessions.js verify \
  --input /tmp/codex-export \
  --mode full

# 3) 导入到目标目录（同机导入也用这个命令）
node ./bin/codex-sessions.js restore \
  --package /tmp/codex-export \
  --target-codex-home ~/.codex \
  --add-only true \
  --conflict skip \
  --post-verify true
```

## 命令说明

### 1) backup（导出）

核心参数：

1. `--codex-home <path>`：源目录，默认 `~/.codex`
2. `--out <path>`：输出位置
3. `--manifest-only <true|false>`：输出目录模式（`true`）或压缩包模式（`false`）
4. `--threads <all|active|archived>`：会话范围
5. `--since / --until <YYYY-MM-DD>`：按日期筛选 rollout 文件
6. `--include-history <true|false>`：是否包含 `history.jsonl`
7. `--include-global-state <true|false>`：是否包含 `.codex-global-state.json`
8. `--compress <gz|none|zst>`：压缩格式（仅 `manifest-only=false` 时生效）

注意：

1. 布尔参数支持显式值，`--include-history false` 不会再被当作 true。
2. 未显式传 `--out` 时，默认后缀会跟随压缩格式：
   - `gz` -> `.tar.gz`
   - `none` -> `.tar`
   - `zst` -> `.tar.zst`

### 2) restore（导入）

核心参数：

1. `--package <path>`：导入包路径（必填）
2. `--target-codex-home <path>`：目标目录，默认 `~/.codex`
3. `--add-only <true|false>`：是否“只新增不覆盖”，默认 `true`
4. `--conflict <skip|overwrite|rename>`：冲突策略
5. `--post-verify <true|false>`：导入后校验；`dry-run` 时自动跳过
6. `--backup-existing <path>`：导入前备份目标目录关键文件（可选）

导入策略（重点）：

1. 默认 `--add-only true`，适合“同机追加导入”。
2. 如果目标中已存在同 `thread id`（线程唯一标识），会自动改写成新 ID 并写入新文件。
3. 会同步追加 `session_index.jsonl`，保证线程能出现在正常列表。
4. `--conflict rename` 作用在会话文件时，会保持 `.jsonl` 有效文件名，不会产生不可识别后缀。

### 3) verify（校验）

核心参数：

1. `--input <path>`：可传导出包目录/压缩包/本地 Codex 目录
2. `--mode <quick|full>`：快速或完整校验
3. `--sample-size <N>`：抽样回放数量
4. `--fail-on-warn`：把告警也视为失败

### 4) doctor（体检）

核心参数：

1. `--codex-home <path>`：目标目录
2. `--check-layout <true|false>`：检查目录结构
3. `--check-permissions <true|false>`：检查权限
4. `--check-jsonl-health <true|false>`：检查 JSONL 健康度

## 报告与退出码

工具会输出结构化报告（默认在 `./reports`）：

1. `backup-report-*.json`
2. `restore-report-*.json`
3. `verify-report-*.json`
4. `doctor-report-*.json`

退出码：

1. `0`：PASS（通过）
2. `10`：WARN（有告警）
3. `20`：FAIL（失败）
4. `30`：ERROR（执行异常）

## 常见问题

1. 为什么 `verify` 是 `WARN` 但 `restore` 是 `PASS`？
   典型原因是历史目录本来就存在“索引缺失/文件缺失”问题。只要本次导入动作成功且无硬失败，`restore` 仍可能是 `PASS`。

2. 为什么 `dry-run` 不做导入后校验？
   `dry-run` 不落盘，不具备“导入后目录状态”，因此默认跳过 post-verify，避免演练被误判失败。

3. 同机导入怎么避免覆盖？
   直接使用默认行为：`--add-only true`。它会自动生成新线程 ID 并追加索引。

## 开发自测

```bash
cd codex-sessions-tool
npm test
```
