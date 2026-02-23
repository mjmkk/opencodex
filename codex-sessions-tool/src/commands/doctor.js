import fs from "node:fs/promises";
import path from "node:path";

import {
  defaultCodexHome,
  ensureRequiredLayout,
  nowIso,
  normalizeStatus,
  parseJsonlFile,
  pathExists,
  pickBoolean,
  resolvePath,
  timestampForFilename,
  writeJsonFile,
} from "../utils.js";

function buildReportPath(options, timestamp) {
  const reportDir = resolvePath(options.reportDir || "./reports");
  return path.join(reportDir, `doctor-report-${timestamp}.json`);
}

async function listJsonlFiles(rootDir) {
  const files = [];

  async function walk(current) {
    const entries = await fs.readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === ".DS_Store") continue;
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) {
        await walk(absolute);
      } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        files.push(absolute);
      }
    }
  }

  if (await pathExists(rootDir)) {
    await walk(rootDir);
  }

  files.sort();
  return files;
}

export async function runDoctor(rawOptions = {}) {
  const startedAt = nowIso();
  const timestamp = timestampForFilename(new Date());
  const codexHome = resolvePath(rawOptions.codexHome || defaultCodexHome());
  const reportPath = buildReportPath(rawOptions, timestamp);

  const checkPermissions = pickBoolean(rawOptions.checkPermissions, true);
  const checkLayout = pickBoolean(rawOptions.checkLayout, true);
  const checkJsonlHealth = pickBoolean(rawOptions.checkJsonlHealth, true);

  const summary = {
    warnings: [],
    failures: [],
  };

  const layout = {
    issues: [],
  };

  if (checkLayout) {
    layout.issues = await ensureRequiredLayout(codexHome);
    if (layout.issues.length > 0) {
      summary.failures.push({
        message: "目录结构不完整",
        detail: layout.issues,
      });
    }
  }

  const permissions = {
    entries: [],
  };

  if (checkPermissions) {
    const targets = [
      path.join(codexHome, "sessions"),
      path.join(codexHome, "archived_sessions"),
      path.join(codexHome, "session_index.jsonl"),
    ];

    for (const target of targets) {
      const row = {
        path: target,
        exists: await pathExists(target),
        readable: false,
        writable: false,
      };

      if (row.exists) {
        try {
          await fs.access(target, fs.constants.R_OK);
          row.readable = true;
        } catch {
          row.readable = false;
        }

        try {
          await fs.access(target, fs.constants.W_OK);
          row.writable = true;
        } catch {
          row.writable = false;
        }

        if (!row.readable) {
          summary.failures.push({
            message: "路径不可读",
            detail: { path: target },
          });
        }

        if (!row.writable) {
          summary.warnings.push({
            message: "路径不可写",
            detail: { path: target },
          });
        }
      }

      permissions.entries.push(row);
    }
  }

  const jsonlHealth = {
    files_checked: 0,
    bad_files: [],
    bad_lines: 0,
  };

  if (checkJsonlHealth) {
    const files = [
      ...(await listJsonlFiles(path.join(codexHome, "sessions"))),
      ...(await listJsonlFiles(path.join(codexHome, "archived_sessions"))),
    ];

    const indexFile = path.join(codexHome, "session_index.jsonl");
    if (await pathExists(indexFile)) files.push(indexFile);

    const sampleFiles = files.slice(0, 200);
    jsonlHealth.files_checked = sampleFiles.length;

    for (const file of sampleFiles) {
      const parsed = await parseJsonlFile(file);
      if (parsed.badLineCount > 0) {
        jsonlHealth.bad_files.push({
          file,
          bad_line_count: parsed.badLineCount,
        });
        jsonlHealth.bad_lines += parsed.badLineCount;
      }
    }

    if (jsonlHealth.bad_files.length > 0) {
      summary.failures.push({
        message: "JSONL 健康检查失败",
        detail: {
          files: jsonlHealth.bad_files.slice(0, 50),
        },
      });
    }
  }

  const riskLevel = summary.failures.length > 0 ? "HIGH" : summary.warnings.length > 0 ? "MEDIUM" : "LOW";

  const recommendedFixes = [];
  if (layout.issues.length > 0) {
    recommendedFixes.push(`mkdir -p "${path.join(codexHome, "sessions")}" "${path.join(codexHome, "archived_sessions")}"`);
  }

  if (permissions.entries.some((entry) => entry.exists && !entry.readable)) {
    recommendedFixes.push(`sudo chown -R "$(whoami)":staff "${codexHome}"`);
  }

  const status = normalizeStatus({
    hasFailures: summary.failures.length > 0,
    hasWarnings: summary.warnings.length > 0,
    failOnWarn: false,
  });

  const report = {
    tool_version: "0.1.0",
    command: "doctor",
    started_at: startedAt,
    finished_at: nowIso(),
    codex_home: codexHome,
    status,
    risk_level: riskLevel,
    report_path: reportPath,
    checks: {
      check_layout: checkLayout,
      check_permissions: checkPermissions,
      check_jsonl_health: checkJsonlHealth,
    },
    layout,
    permissions,
    jsonl_health: jsonlHealth,
    recommended_fixes: recommendedFixes,
    summary,
  };

  await writeJsonFile(reportPath, report);
  return report;
}
