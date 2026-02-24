import fs from "node:fs/promises";
import path from "node:path";

import { locatePackageRoot } from "../package-io.js";
import {
  STATUS,
  defaultCodexHome,
  ensureRequiredLayout,
  nowIso,
  normalizeStatus,
  parseNumber,
  pickBoolean,
  resolvePath,
  timestampForFilename,
  writeJsonFile,
} from "../utils.js";
import { verifyCodexHomeLayout, verifyPackageRoot } from "../verify-core.js";

function buildReportPath(options, timestamp) {
  const reportDir = resolvePath(options.reportDir || "./reports");
  return path.join(reportDir, `verify-report-${timestamp}.json`);
}

async function looksLikePackageDirectory(inputPath) {
  const needed = ["manifest.json", "checksums.sha256", "payload"];
  const checks = await Promise.all(
    needed.map(async (name) => {
      const target = path.join(inputPath, name);
      try {
        await fs.access(target);
        return true;
      } catch {
        return false;
      }
    }),
  );
  return checks.every(Boolean);
}

export async function runVerify(rawOptions = {}) {
  const startedAt = nowIso();
  const timestamp = timestampForFilename(new Date());
  const input = resolvePath(rawOptions.input || rawOptions.path || rawOptions.package || defaultCodexHome());
  const mode = rawOptions.mode === "quick" ? "quick" : "full";
  const sampleSize = parseNumber(rawOptions.sampleSize, 100);
  const failOnWarn = pickBoolean(rawOptions.failOnWarn, false);
  const reportPath = buildReportPath(rawOptions, timestamp);

  let result;
  let cleanup = null;

  try {
    const stat = await fs.stat(input).catch(() => null);
    if (!stat) {
      throw new Error(`路径不存在: ${input}`);
    }

    if (stat.isFile()) {
      const packageRef = await locatePackageRoot(input);
      cleanup = packageRef.cleanup;
      result = await verifyPackageRoot(packageRef.packageRoot, {
        mode,
        sampleSize,
        failOnWarn,
      });
    } else {
      const packageDir = await looksLikePackageDirectory(input);
      if (packageDir) {
        result = await verifyPackageRoot(input, {
          mode,
          sampleSize,
          failOnWarn,
        });
      } else {
        const issues = await ensureRequiredLayout(input);
        if (issues.length > 0) {
          result = {
            kind: "unknown",
            status: STATUS.FAIL,
            summary: {
              failures: [
                {
                  message: "输入目录既不是导出包也不是 Codex 数据目录",
                  detail: issues,
                },
              ],
              warnings: [],
            },
          };
        } else {
          result = await verifyCodexHomeLayout(input, {
            mode,
            sampleSize,
            failOnWarn,
          });
        }
      }
    }
  } finally {
    if (cleanup) {
      await cleanup();
    }
  }

  const status = normalizeStatus({
    hasFailures: result.summary.failures.length > 0,
    hasWarnings: result.summary.warnings.length > 0,
    failOnWarn,
  });

  const report = {
    tool_version: "0.1.0",
    command: "verify",
    started_at: startedAt,
    finished_at: nowIso(),
    input_path: input,
    mode,
    sample_size: sampleSize,
    fail_on_warn: failOnWarn,
    status,
    report_path: reportPath,
    result,
  };

  await writeJsonFile(reportPath, report);
  return report;
}
