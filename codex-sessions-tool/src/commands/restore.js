import crypto from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";

import { locatePackageRoot } from "../package-io.js";
import {
  defaultCodexHome,
  ensureDir,
  extractSessionIdFromFilename,
  nowIso,
  normalizeStatus,
  parseJsonlFile,
  pathExists,
  pickBoolean,
  readJsonLines,
  resolvePath,
  runTar,
  sha256File,
  timestampForFilename,
  writeJsonFile,
  writeTextFile,
} from "../utils.js";
import { verifyCodexHomeLayout, verifyPackageRoot } from "../verify-core.js";

function buildReportPath(options, timestamp) {
  const reportDir = resolvePath(options.reportDir || "./reports");
  return path.join(reportDir, `restore-report-${timestamp}.json`);
}

function sanitizeRelativePath(relativePath) {
  const normalized = path.normalize(relativePath);
  if (normalized.startsWith("..") || path.isAbsolute(normalized)) {
    throw new Error(`非法路径: ${relativePath}`);
  }
  return normalized;
}

function isSessionJsonlRelative(relativePath) {
  if (!relativePath.endsWith(".jsonl")) return false;
  return relativePath.startsWith("sessions/") || relativePath.startsWith("archived_sessions/");
}

async function findUniqueRenamePath(destination, suffix) {
  let candidate = `${destination}.${suffix}`;
  let counter = 1;
  while (await pathExists(candidate)) {
    candidate = `${destination}.${suffix}.${counter}`;
    counter += 1;
  }
  return candidate;
}

async function findUniqueSessionRenamePath(destination, suffix) {
  const ext = destination.endsWith(".jsonl") ? ".jsonl" : "";
  const base = ext ? destination.slice(0, -ext.length) : destination;
  let candidate = `${base}-${suffix}${ext}`;
  let counter = 1;
  while (await pathExists(candidate)) {
    candidate = `${base}-${suffix}-${counter}${ext}`;
    counter += 1;
  }
  return candidate;
}

async function listPayloadFiles(payloadRoot) {
  const files = [];

  async function walk(current, rel) {
    const entries = await fs.readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === ".DS_Store") continue;
      const abs = path.join(current, entry.name);
      const nextRel = rel ? path.join(rel, entry.name) : entry.name;
      if (entry.isDirectory()) {
        await walk(abs, nextRel);
      } else if (entry.isFile()) {
        files.push({
          absolutePath: abs,
          relativePath: nextRel,
        });
      }
    }
  }

  await walk(payloadRoot, "");
  files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  return files;
}

async function backupExistingTargets(targetCodexHome, backupPath, dryRun) {
  const backupAbsPath = resolvePath(backupPath);
  if (dryRun) {
    return {
      backupPath: backupAbsPath,
      skipped: true,
    };
  }

  await ensureDir(path.dirname(backupAbsPath));

  const existing = [];
  for (const relative of ["sessions", "archived_sessions", "session_index.jsonl", "history.jsonl", ".codex-global-state.json"]) {
    const absolute = path.join(targetCodexHome, relative);
    if (await pathExists(absolute)) {
      existing.push(relative);
    }
  }

  if (existing.length === 0) {
    return {
      backupPath: backupAbsPath,
      skipped: true,
      reason: "target has no exportable files",
    };
  }

  runTar(["-czf", backupAbsPath, ...existing], targetCodexHome);
  return {
    backupPath: backupAbsPath,
    skipped: false,
    files: existing,
  };
}

function collectIdsFromParsedRows(rows) {
  const set = new Set();
  for (const row of rows) {
    if (row && typeof row.id === "string") {
      set.add(row.id.toLowerCase());
    }
  }
  return set;
}

async function collectExistingThreadIds(targetCodexHome) {
  const ids = new Set();

  const indexPath = path.join(targetCodexHome, "session_index.jsonl");
  if (await pathExists(indexPath)) {
    const { parsed } = await readJsonLines(indexPath);
    for (const id of collectIdsFromParsedRows(parsed)) {
      ids.add(id);
    }
  }

  async function walkSessionDir(baseDir) {
    if (!(await pathExists(baseDir))) return;

    async function walk(current) {
      const entries = await fs.readdir(current, { withFileTypes: true });
      for (const entry of entries) {
        const abs = path.join(current, entry.name);
        if (entry.isDirectory()) {
          await walk(abs);
          continue;
        }
        if (!entry.isFile() || !entry.name.endsWith(".jsonl")) {
          continue;
        }
        const id = extractSessionIdFromFilename(abs);
        if (id) ids.add(id.toLowerCase());
      }
    }

    await walk(baseDir);
  }

  await walkSessionDir(path.join(targetCodexHome, "sessions"));
  await walkSessionDir(path.join(targetCodexHome, "archived_sessions"));

  return ids;
}

function createUniqueThreadId(existingIds) {
  while (true) {
    const candidate = crypto.randomUUID().toLowerCase();
    if (!existingIds.has(candidate)) {
      return candidate;
    }
  }
}

function replaceThreadIdInRelativePath(relativePath, sourceId, targetId) {
  const base = path.basename(relativePath);
  const sourceSuffix = `-${sourceId}.jsonl`;
  if (base.endsWith(sourceSuffix)) {
    const renamedBase = `${base.slice(0, -sourceSuffix.length)}-${targetId}.jsonl`;
    return path.join(path.dirname(relativePath), renamedBase);
  }

  if (base.endsWith(".jsonl")) {
    const renamedBase = `${base.slice(0, -".jsonl".length)}-${targetId}.jsonl`;
    return path.join(path.dirname(relativePath), renamedBase);
  }

  return relativePath;
}

function deepReplaceStringValue(value, source, target) {
  if (typeof value === "string") {
    return value === source ? target : value;
  }

  if (Array.isArray(value)) {
    return value.map((item) => deepReplaceStringValue(item, source, target));
  }

  if (value && typeof value === "object") {
    const next = {};
    for (const [key, inner] of Object.entries(value)) {
      next[key] = deepReplaceStringValue(inner, source, target);
    }
    return next;
  }

  return value;
}

async function rewriteSessionJsonlThreadId(sourcePath, sourceId, targetId) {
  const raw = await fs.readFile(sourcePath, "utf8");
  const lines = raw.split(/\r?\n/);
  const output = [];

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (!line) continue;

    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new Error(`重写会话 ID 时 JSON 解析失败: ${sourcePath} line=${index + 1} error=${detail}`);
    }

    const rewritten = deepReplaceStringValue(parsed, sourceId, targetId);
    output.push(JSON.stringify(rewritten));
  }

  return `${output.join("\n")}\n`;
}

async function loadSourceIndexMap(payloadRoot, summary) {
  const sourceIndexPath = path.join(payloadRoot, "session_index.jsonl");
  const map = new Map();

  if (!(await pathExists(sourceIndexPath))) {
    return map;
  }

  const { parsed, bad } = await readJsonLines(sourceIndexPath);
  if (bad.length > 0) {
    summary.warnings.push({
      message: "导出包中的 session_index.jsonl 有坏行，已忽略",
      detail: {
        count: bad.length,
        sample: bad.slice(0, 20),
      },
    });
  }

  for (const row of parsed) {
    if (row && typeof row.id === "string") {
      map.set(row.id.toLowerCase(), row);
    }
  }

  return map;
}

async function appendIndexEntries(targetCodexHome, imports, sourceIndexMap, timestamp, dryRun, summary) {
  const targetIndexPath = path.join(targetCodexHome, "session_index.jsonl");

  let existingRaw = "";
  if (await pathExists(targetIndexPath)) {
    existingRaw = await fs.readFile(targetIndexPath, "utf8");
  }

  const { parsed, bad } = await readJsonLines(targetIndexPath).catch(() => ({ parsed: [], bad: [] }));
  if (bad.length > 0) {
    summary.warnings.push({
      message: "目标 session_index.jsonl 有坏行，导入会追加新行但不会修复旧坏行",
      detail: {
        count: bad.length,
        sample: bad.slice(0, 20),
      },
    });
  }

  const existingIds = collectIdsFromParsedRows(parsed);
  const appended = [];
  const now = nowIso();

  for (const item of imports) {
    if (!item.targetId) continue;
    const targetId = item.targetId.toLowerCase();
    if (existingIds.has(targetId)) {
      continue;
    }

    const sourceId = item.sourceId ? item.sourceId.toLowerCase() : null;
    const sourceEntry = sourceId ? sourceIndexMap.get(sourceId) : null;

    const entry = sourceEntry && typeof sourceEntry === "object" ? { ...sourceEntry } : {};
    entry.id = targetId;

    const sourceName = typeof entry.thread_name === "string" && entry.thread_name.trim().length > 0
      ? entry.thread_name.trim()
      : "imported-thread";

    if (sourceId && sourceId !== targetId) {
      entry.thread_name = `${sourceName} (imported ${timestamp})`;
    } else {
      entry.thread_name = sourceName;
    }

    entry.updated_at = now;
    appended.push(JSON.stringify(entry));
    existingIds.add(targetId);
  }

  if (appended.length === 0) {
    return {
      appendedCount: 0,
      targetIndexPath,
    };
  }

  let finalRaw = existingRaw;
  if (finalRaw.length > 0 && !finalRaw.endsWith("\n")) {
    finalRaw += "\n";
  }
  finalRaw += `${appended.join("\n")}\n`;

  if (!dryRun) {
    await writeTextFile(targetIndexPath, finalRaw);
  }

  return {
    appendedCount: appended.length,
    targetIndexPath,
  };
}

async function copyNonSessionFile({
  source,
  destination,
  conflictPolicy,
  addOnly,
  dryRun,
  timestamp,
  actions,
  summary,
}) {
  const destinationExists = await pathExists(destination);

  if (!destinationExists) {
    if (!dryRun) {
      await ensureDir(path.dirname(destination));
      await fs.copyFile(source, destination);
    }
    actions.copied += 1;
    return;
  }

  const [sourceHash, destinationHash] = await Promise.all([sha256File(source), sha256File(destination)]);
  if (sourceHash === destinationHash) {
    actions.unchanged += 1;
    return;
  }

  if (addOnly || conflictPolicy === "skip") {
    actions.skipped += 1;
    const reason = addOnly ? "add-only 模式跳过了冲突文件（未覆盖）" : "冲突策略 skip：已跳过冲突文件（未覆盖）";
    summary.warnings.push({
      message: reason,
      detail: {
        file: destination,
      },
    });
    return;
  }

  if (conflictPolicy === "overwrite") {
    if (!dryRun) {
      await ensureDir(path.dirname(destination));
      await fs.copyFile(source, destination);
    }
    actions.overwritten += 1;
    return;
  }

  const renamedPath = await findUniqueRenamePath(destination, `imported-${timestamp}`);
  if (!dryRun) {
    await ensureDir(path.dirname(renamedPath));
    await fs.copyFile(source, renamedPath);
  }
  actions.renamed += 1;
}

export async function runRestore(rawOptions = {}) {
  const startedAt = nowIso();
  const timestamp = timestampForFilename(new Date());
  const packageInput = resolvePath(rawOptions.package || rawOptions.input);

  if (!packageInput) {
    throw new Error("restore 缺少 --package 参数");
  }

  const targetCodexHome = resolvePath(rawOptions.targetCodexHome || rawOptions.codexHome || defaultCodexHome());
  const conflictPolicy = rawOptions.conflict || "skip";
  const dryRun = pickBoolean(rawOptions.dryRun, false);
  const postVerify = pickBoolean(rawOptions.postVerify, !dryRun);
  const addOnly = pickBoolean(rawOptions.addOnly, true);
  const reportPath = buildReportPath(rawOptions, timestamp);

  if (!["skip", "overwrite", "rename"].includes(conflictPolicy)) {
    throw new Error(`conflict 参数无效: ${conflictPolicy}`);
  }

  const summary = {
    warnings: [],
    failures: [],
  };

  const packageRef = await locatePackageRoot(packageInput);
  const packageRoot = packageRef.packageRoot;

  try {
    const preVerify = await verifyPackageRoot(packageRoot, {
      mode: "full",
      sampleSize: 100,
      failOnWarn: false,
    });

    if (preVerify.status === "FAIL") {
      summary.failures.push({
        message: "导入前校验失败，已中止",
        detail: preVerify.summary,
      });

      const failReport = {
        tool_version: "0.1.0",
        command: "restore",
        started_at: startedAt,
        finished_at: nowIso(),
        status: "FAIL",
        package_path: packageInput,
        target_codex_home: targetCodexHome,
        conflict_policy: conflictPolicy,
        add_only: addOnly,
        dry_run: dryRun,
        report_path: reportPath,
        pre_verify: preVerify,
        summary,
      };
      await writeJsonFile(reportPath, failReport);
      return failReport;
    }

    let backupInfo = null;
    if (rawOptions.backupExisting) {
      backupInfo = await backupExistingTargets(targetCodexHome, rawOptions.backupExisting, dryRun);
    }

    const payloadRoot = path.join(packageRoot, "payload");
    if (!(await pathExists(payloadRoot))) {
      throw new Error(`导出包缺少 payload 目录: ${payloadRoot}`);
    }

    const payloadFiles = await listPayloadFiles(payloadRoot);
    const sourceIndexMap = await loadSourceIndexMap(payloadRoot, summary);

    const actions = {
      copied: 0,
      overwritten: 0,
      skipped: 0,
      renamed: 0,
      unchanged: 0,
      remapped_threads: 0,
      index_appended: 0,
    };

    const imports = [];

    if (!dryRun) {
      await ensureDir(targetCodexHome);
      await ensureDir(path.join(targetCodexHome, "sessions"));
      await ensureDir(path.join(targetCodexHome, "archived_sessions"));
      const targetIndexPath = path.join(targetCodexHome, "session_index.jsonl");
      if (!(await pathExists(targetIndexPath))) {
        await writeTextFile(targetIndexPath, "");
      }
    }

    const existingThreadIds = await collectExistingThreadIds(targetCodexHome);

    for (const file of payloadFiles) {
      const safeRelative = sanitizeRelativePath(file.relativePath);

      if (safeRelative === "session_index.jsonl") {
        continue;
      }

      if (isSessionJsonlRelative(safeRelative)) {
        const parsedStats = await parseJsonlFile(file.absolutePath);
        const sourceId = (parsedStats.sessionId || extractSessionIdFromFilename(file.absolutePath) || null)?.toLowerCase() ?? null;

        let targetId = sourceId;
        let targetRelative = safeRelative;
        let remapped = false;

        if (sourceId && existingThreadIds.has(sourceId) && (addOnly || conflictPolicy === "rename")) {
          targetId = createUniqueThreadId(existingThreadIds);
          targetRelative = replaceThreadIdInRelativePath(safeRelative, sourceId, targetId);
          remapped = true;
          actions.remapped_threads += 1;
          existingThreadIds.add(targetId.toLowerCase());
        }

        let destination = path.join(targetCodexHome, targetRelative);
        while (await pathExists(destination)) {
          const [sourceHash, destinationHash] = await Promise.all([sha256File(file.absolutePath), sha256File(destination)]);
          if (sourceHash === destinationHash) {
            actions.unchanged += 1;
            destination = null;
            break;
          }

          if (addOnly || conflictPolicy === "skip") {
            actions.skipped += 1;
            const reason = addOnly
              ? "add-only 模式跳过了冲突会话文件（未覆盖）"
              : "冲突策略 skip：已跳过冲突会话文件（未覆盖）";
            summary.warnings.push({
              message: reason,
              detail: {
                file: destination,
              },
            });
            destination = null;
            break;
          }

          if (conflictPolicy === "overwrite") {
            break;
          }

          if (sourceId) {
            targetId = createUniqueThreadId(existingThreadIds);
            targetRelative = replaceThreadIdInRelativePath(safeRelative, sourceId, targetId);
            destination = path.join(targetCodexHome, targetRelative);
            if (!remapped) {
              remapped = true;
              actions.remapped_threads += 1;
            }
            existingThreadIds.add(targetId.toLowerCase());
            continue;
          }

          const renamedPath = await findUniqueSessionRenamePath(destination, `imported-${timestamp}`);
          targetRelative = path.relative(targetCodexHome, renamedPath);
          destination = renamedPath;
          actions.renamed += 1;
          break;
        }

        if (!destination) {
          continue;
        }

        if (!dryRun) {
          await ensureDir(path.dirname(destination));
          if (remapped && sourceId && targetId) {
            const rewritten = await rewriteSessionJsonlThreadId(file.absolutePath, sourceId, targetId);
            await writeTextFile(destination, rewritten);
          } else {
            await fs.copyFile(file.absolutePath, destination);
          }
        }

        actions.copied += 1;

        if (targetId) {
          existingThreadIds.add(targetId.toLowerCase());
        }

        imports.push({
          sourceId,
          targetId,
          sourceRelative: safeRelative,
          targetRelative,
        });

        continue;
      }

      const destination = path.join(targetCodexHome, safeRelative);
      await copyNonSessionFile({
        source: file.absolutePath,
        destination,
        conflictPolicy,
        addOnly,
        dryRun,
        timestamp,
        actions,
        summary,
      });
    }

    const indexResult = await appendIndexEntries(targetCodexHome, imports, sourceIndexMap, timestamp, dryRun, summary);
    actions.index_appended = indexResult.appendedCount;

    let postVerifyResult = null;
    if (postVerify && !dryRun) {
      postVerifyResult = await verifyCodexHomeLayout(targetCodexHome, {
        mode: "quick",
        sampleSize: 100,
        failOnWarn: false,
      });

      if (postVerifyResult.status === "FAIL") {
        summary.failures.push({
          message: "导入后可恢复性校验失败",
          detail: postVerifyResult.summary,
        });
      } else if (postVerifyResult.status === "WARN") {
        summary.warnings.push({
          message: "导入后可恢复性校验有告警",
          detail: postVerifyResult.summary,
        });
      }
    }

    const status = normalizeStatus({
      hasFailures: summary.failures.length > 0,
      hasWarnings: summary.warnings.length > 0,
      failOnWarn: false,
    });

    const report = {
      tool_version: "0.1.0",
      command: "restore",
      started_at: startedAt,
      finished_at: nowIso(),
      status,
      package_path: packageInput,
      package_root: packageRoot,
      target_codex_home: targetCodexHome,
      conflict_policy: conflictPolicy,
      add_only: addOnly,
      dry_run: dryRun,
      report_path: reportPath,
      actions,
      imported_threads: imports,
      pre_verify: preVerify,
      post_verify: postVerifyResult,
      backup_existing: backupInfo,
      summary,
    };

    await writeJsonFile(reportPath, report);
    return report;
  } finally {
    if (packageRef.cleanup) {
      await packageRef.cleanup();
    }
  }
}
