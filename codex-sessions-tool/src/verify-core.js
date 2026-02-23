import fs from "node:fs/promises";
import path from "node:path";

import {
  REQUIRED_ITEMS,
  collectPayloadFiles,
  ensureRequiredLayout,
  extractSessionIdFromFilename,
  normalizeStatus,
  parseJsonlFile,
  pathExists,
  readJsonLines,
  resolvePath,
  sha256File,
} from "./utils.js";
import { detectPayloadFiles, readChecksumsFile } from "./package-io.js";

function makeSummary() {
  return {
    warnings: [],
    failures: [],
  };
}

function pushWarning(summary, message, detail = null) {
  summary.warnings.push({ message, detail });
}

function pushFailure(summary, message, detail = null) {
  summary.failures.push({ message, detail });
}

async function collectSessionFilesFromPayload(payloadRoot) {
  const groups = ["sessions", "archived_sessions"];
  const files = [];

  for (const group of groups) {
    const groupPath = path.join(payloadRoot, group);
    if (!(await pathExists(groupPath))) continue;
    const entries = await collectPayloadFiles(groupPath);
    for (const item of entries) {
      if (!item.relativePath.endsWith(".jsonl")) continue;
      files.push({
        absolutePath: item.absolutePath,
        relativePath: path.join(group, item.relativePath),
      });
    }
  }

  files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  return files;
}

function pickFilesByMode(files, mode, sampleSize) {
  if (mode !== "quick") return files;
  if (files.length <= sampleSize) return files;
  return files.slice(0, sampleSize);
}

function collectSessionIdsFromFiles(files) {
  const ids = new Set();
  for (const item of files) {
    const id = extractSessionIdFromFilename(item.absolutePath);
    if (id) ids.add(id.toLowerCase());
  }
  return ids;
}

async function analyzeSessionFiles(files, summary) {
  const stats = {
    checkedFiles: 0,
    totalLines: 0,
    badLines: 0,
    badFiles: [],
    missingSessionMeta: [],
    emptyConversation: [],
    timestampViolations: [],
    sessionIds: new Set(),
  };

  for (const item of files) {
    const parsed = await parseJsonlFile(item.absolutePath);

    stats.checkedFiles += 1;
    stats.totalLines += parsed.lineCount;
    stats.badLines += parsed.badLineCount;

    if (parsed.badLineCount > 0) {
      stats.badFiles.push({
        file: item.relativePath,
        badLineCount: parsed.badLineCount,
      });
      pushFailure(summary, "JSONL 解析失败", {
        file: item.relativePath,
        badLines: parsed.badLines.slice(0, 20),
      });
    }

    const sessionId = parsed.sessionId || extractSessionIdFromFilename(item.absolutePath);
    if (sessionId) stats.sessionIds.add(sessionId.toLowerCase());

    if (!parsed.hasSessionMeta) {
      stats.missingSessionMeta.push(item.relativePath);
      pushFailure(summary, "缺少 session_meta 事件", { file: item.relativePath });
    }

    if (!parsed.hasConversationMessage) {
      stats.emptyConversation.push(item.relativePath);
      pushWarning(summary, "会话文件里没有用户/助手消息", { file: item.relativePath });
    }

    if (!parsed.monotonicTimestamps) {
      stats.timestampViolations.push({
        file: item.relativePath,
        count: parsed.timestampViolations,
      });
      pushWarning(summary, "时间戳存在逆序", {
        file: item.relativePath,
        count: parsed.timestampViolations,
      });
    }
  }

  return stats;
}

async function checkIndexConsistency(indexFile, sessionIds, summary) {
  const report = {
    indexEntries: 0,
    badLines: 0,
    indexIds: [],
    missingSessionFilesForIndex: [],
    missingIndexEntriesForSessions: [],
  };

  if (!(await pathExists(indexFile))) {
    pushFailure(summary, "缺少 session_index.jsonl", { file: indexFile });
    return report;
  }

  const { parsed, bad } = await readJsonLines(indexFile);
  report.badLines = bad.length;
  report.indexEntries = parsed.length;

  if (bad.length > 0) {
    pushFailure(summary, "session_index.jsonl 存在非法 JSON 行", {
      file: indexFile,
      badLines: bad.slice(0, 20),
    });
  }

  const indexSet = new Set();

  for (const row of parsed) {
    if (row && typeof row.id === "string") {
      const id = row.id.toLowerCase();
      indexSet.add(id);
      report.indexIds.push(id);
    }
  }

  for (const id of indexSet) {
    if (!sessionIds.has(id)) {
      report.missingSessionFilesForIndex.push(id);
    }
  }

  for (const id of sessionIds) {
    if (!indexSet.has(id)) {
      report.missingIndexEntriesForSessions.push(id);
    }
  }

  if (report.missingSessionFilesForIndex.length > 0) {
    pushWarning(summary, "索引存在但找不到对应会话文件", {
      count: report.missingSessionFilesForIndex.length,
      sample: report.missingSessionFilesForIndex.slice(0, 20),
    });
  }

  if (report.missingIndexEntriesForSessions.length > 0) {
    pushWarning(summary, "存在会话文件但索引缺失", {
      count: report.missingIndexEntriesForSessions.length,
      sample: report.missingIndexEntriesForSessions.slice(0, 20),
    });
  }

  return report;
}

async function buildSampleReplay(sessionFiles, sampleSize) {
  const sample = sessionFiles.slice(0, sampleSize);
  let success = 0;
  const failedFiles = [];

  for (const item of sample) {
    const parsed = await parseJsonlFile(item.absolutePath);
    const good = parsed.badLineCount === 0 && parsed.hasSessionMeta;
    if (good) {
      success += 1;
    } else {
      failedFiles.push(item.relativePath);
    }
  }

  return {
    requested: sampleSize,
    checked: sample.length,
    success,
    failed: sample.length - success,
    failedFiles,
  };
}

export async function verifyPackageRoot(packageRoot, options = {}) {
  const mode = options.mode === "quick" ? "quick" : "full";
  const sampleSize = Math.max(1, Number(options.sampleSize || 100));
  const failOnWarn = Boolean(options.failOnWarn);
  const summary = makeSummary();

  const payloadRoot = path.join(packageRoot, "payload");
  const manifestPath = path.join(packageRoot, "manifest.json");
  const checksumsPath = path.join(packageRoot, "checksums.sha256");

  const integrity = {
    checksumsFile: checksumsPath,
    filesChecked: 0,
    missingFiles: [],
    mismatches: [],
  };

  let manifest = null;
  try {
    const manifestRaw = await fs.readFile(manifestPath, "utf8");
    manifest = JSON.parse(manifestRaw);
  } catch (error) {
    pushFailure(summary, "manifest.json 读取失败", {
      file: manifestPath,
      error: error instanceof Error ? error.message : String(error),
    });
  }

  try {
    const checksums = await readChecksumsFile(packageRoot);
    for (const entry of checksums) {
      const absolutePath = path.join(packageRoot, entry.relativePath);
      const exists = await pathExists(absolutePath);
      if (!exists) {
        integrity.missingFiles.push(entry.relativePath);
        pushFailure(summary, "校验文件缺失", { file: entry.relativePath });
        continue;
      }

      integrity.filesChecked += 1;
      const digest = await sha256File(absolutePath);
      if (digest !== entry.sha256) {
        integrity.mismatches.push({
          file: entry.relativePath,
          expected: entry.sha256,
          actual: digest,
        });
        pushFailure(summary, "SHA-256 校验不一致", {
          file: entry.relativePath,
        });
      }
    }
  } catch (error) {
    pushFailure(summary, "checksums.sha256 读取失败", {
      file: checksumsPath,
      error: error instanceof Error ? error.message : String(error),
    });
  }

  const payloadFiles = await detectPayloadFiles(packageRoot);
  const jsonlFiles = payloadFiles.filter((item) => item.relativePath.endsWith(".jsonl"));
  const sampledJsonlFiles = pickFilesByMode(jsonlFiles, mode, sampleSize);

  const parseStats = {
    filesChecked: 0,
    totalLines: 0,
    badLines: 0,
    badFiles: [],
  };

  for (const file of sampledJsonlFiles) {
    const parsed = await parseJsonlFile(path.join(payloadRoot, file.relativePath));
    parseStats.filesChecked += 1;
    parseStats.totalLines += parsed.lineCount;
    parseStats.badLines += parsed.badLineCount;
    if (parsed.badLineCount > 0) {
      parseStats.badFiles.push({
        file: file.relativePath,
        badLineCount: parsed.badLineCount,
      });
      pushFailure(summary, "JSONL 文件包含坏行", {
        file: file.relativePath,
      });
    }
  }

  const sessionFilesAll = await collectSessionFilesFromPayload(payloadRoot);
  const sessionFiles = pickFilesByMode(sessionFilesAll, mode, sampleSize);
  const semanticStats = await analyzeSessionFiles(sessionFiles, summary);
  const allSessionIds = collectSessionIdsFromFiles(sessionFilesAll);
  for (const id of semanticStats.sessionIds) {
    allSessionIds.add(id);
  }

  const indexPath = path.join(payloadRoot, "session_index.jsonl");
  const indexConsistency = await checkIndexConsistency(indexPath, allSessionIds, summary);

  const sampleReplay = await buildSampleReplay(sessionFilesAll, sampleSize);

  const status = normalizeStatus({
    hasFailures: summary.failures.length > 0,
    hasWarnings: summary.warnings.length > 0,
    failOnWarn,
  });

  return {
    kind: "package",
    packageRoot,
    mode,
    sampleSize,
    status,
    manifest,
    integrity,
    jsonlParse: parseStats,
    semantic: {
      checkedFiles: semanticStats.checkedFiles,
      missingSessionMeta: semanticStats.missingSessionMeta,
      emptyConversation: semanticStats.emptyConversation,
      timestampViolations: semanticStats.timestampViolations,
    },
    indexConsistency,
    sampleReplay,
    summary,
  };
}

export async function verifyCodexHomeLayout(codexHomeInput, options = {}) {
  const codexHome = resolvePath(codexHomeInput);
  const mode = options.mode === "quick" ? "quick" : "full";
  const sampleSize = Math.max(1, Number(options.sampleSize || 100));
  const failOnWarn = Boolean(options.failOnWarn);
  const summary = makeSummary();

  const layoutIssues = await ensureRequiredLayout(codexHome);
  if (layoutIssues.length > 0) {
    for (const issue of layoutIssues) {
      pushFailure(summary, "目录结构不完整", issue);
    }
  }

  const sessionFiles = [];
  for (const item of REQUIRED_ITEMS) {
    if (item.path === "session_index.jsonl") continue;
    const baseDir = path.join(codexHome, item.path);
    if (!(await pathExists(baseDir))) continue;
    const entries = await collectPayloadFiles(baseDir);
    for (const file of entries) {
      if (!file.relativePath.endsWith(".jsonl")) continue;
      sessionFiles.push({
        absolutePath: file.absolutePath,
        relativePath: path.join(item.path, file.relativePath),
      });
    }
  }

  sessionFiles.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  const selectedSessionFiles = pickFilesByMode(sessionFiles, mode, sampleSize);
  const semanticStats = await analyzeSessionFiles(selectedSessionFiles, summary);
  const allSessionIds = collectSessionIdsFromFiles(sessionFiles);
  for (const id of semanticStats.sessionIds) {
    allSessionIds.add(id);
  }
  const indexPath = path.join(codexHome, "session_index.jsonl");
  const indexConsistency = await checkIndexConsistency(indexPath, allSessionIds, summary);

  const status = normalizeStatus({
    hasFailures: summary.failures.length > 0,
    hasWarnings: summary.warnings.length > 0,
    failOnWarn,
  });

  return {
    kind: "codex_home",
    codexHome,
    mode,
    sampleSize,
    status,
    semantic: {
      checkedFiles: semanticStats.checkedFiles,
      missingSessionMeta: semanticStats.missingSessionMeta,
      emptyConversation: semanticStats.emptyConversation,
      timestampViolations: semanticStats.timestampViolations,
    },
    indexConsistency,
    summary,
  };
}
