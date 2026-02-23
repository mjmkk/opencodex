import { runBackup } from "./commands/backup.js";
import { runDoctor } from "./commands/doctor.js";
import { runRestore } from "./commands/restore.js";
import { runVerify } from "./commands/verify.js";
import { statusToExitCode } from "./utils.js";

function toCamelCase(name) {
  return name.replace(/-([a-z])/g, (_, char) => char.toUpperCase());
}

function parseArgs(argv) {
  if (!Array.isArray(argv) || argv.length === 0) {
    return { command: "help", options: {} };
  }

  const [first, ...rest] = argv;
  if (["-h", "--help", "help"].includes(first)) {
    return { command: "help", options: {} };
  }

  const options = {};
  let index = 0;
  while (index < rest.length) {
    const token = rest[index];
    if (!token.startsWith("--")) {
      index += 1;
      continue;
    }

    const raw = token.slice(2);
    const hasInlineValue = raw.includes("=");
    let key;
    let value;

    if (hasInlineValue) {
      const splitIndex = raw.indexOf("=");
      key = raw.slice(0, splitIndex);
      value = raw.slice(splitIndex + 1);
    } else {
      key = raw;
      const maybeValue = rest[index + 1];
      if (!maybeValue || maybeValue.startsWith("--")) {
        value = true;
      } else {
        value = maybeValue;
        index += 1;
      }
    }

    options[toCamelCase(key)] = value;
    index += 1;
  }

  return {
    command: first,
    options,
  };
}

function printHelp() {
  const text = `
codex-sessions - 导出/导入/校验 Codex sessions

用法:
  codex-sessions <command> [options]

命令:
  backup   导出 sessions 包
  restore  导入 sessions 包
  verify   校验导出包或 Codex 数据目录
  doctor   环境体检

常用参数:
  --codex-home <path>          Codex 数据目录（默认 ~/.codex）
  --report-dir <path>          报告输出目录（默认 ./reports）
  --dry-run                    演练模式，不落盘
  --json                       输出完整 JSON

backup 参数:
  --out <path>                 输出 tar.gz 或目录
  --threads <all|active|archived>
  --since <YYYY-MM-DD>
  --until <YYYY-MM-DD>
  --include-history <true|false>
  --include-global-state <true|false>
  --manifest-only <true|false>
  --compress <gz|none|zst>

restore 参数:
  --package <path>             导入包路径（必填）
  --target-codex-home <path>
  --conflict <skip|overwrite|rename>
  --add-only <true|false>      只新增不覆盖（默认 true）
  --backup-existing <path>
  --post-verify <true|false>

verify 参数:
  --input <path>               包路径 / 包目录 / codex home
  --mode <quick|full>
  --sample-size <N>
  --fail-on-warn

doctor 参数:
  --check-layout <true|false>
  --check-permissions <true|false>
  --check-jsonl-health <true|false>
`;

  process.stdout.write(text.trimStart());
}

function printHumanResult(command, result) {
  const base = [`[${result.status}] ${command}`];
  if (result.report_path) base.push(`report: ${result.report_path}`);

  if (command === "backup") {
    base.push(`output: ${result.output_path}`);
    base.push(`files: ${result.manifest_file_count}`);
  }

  if (command === "restore") {
    base.push(`target: ${result.target_codex_home}`);
  }

  if (result.summary) {
    base.push(`warnings: ${result.summary.warnings?.length || 0}`);
    base.push(`failures: ${result.summary.failures?.length || 0}`);
  }

  process.stdout.write(`${base.join(" | ")}\n`);
}

export async function runCli(argv) {
  const { command, options } = parseArgs(argv);

  if (command === "help") {
    printHelp();
    process.exitCode = 0;
    return;
  }

  let result;
  if (command === "backup") {
    result = await runBackup(options);
  } else if (command === "restore") {
    result = await runRestore(options);
  } else if (command === "verify") {
    result = await runVerify(options);
  } else if (command === "doctor") {
    result = await runDoctor(options);
  } else {
    throw new Error(`未知命令: ${command}`);
  }

  if (options.json) {
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
  } else {
    printHumanResult(command, result);
  }

  process.exitCode = statusToExitCode(result.status);
}
