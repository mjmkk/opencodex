import fs from "node:fs/promises";
import path from "node:path";

import {
  STATUS,
  collectPayloadFiles,
  copyFileWithParents,
  createTempDir,
  defaultCodexHome,
  ensureDir,
  ensureRequiredLayout,
  extractSessionIdFromFilename,
  normalizeStatus,
  nowIso,
  parseDateFilterValue,
  parseJsonlFile,
  pathExists,
  pickBoolean,
  resolvePath,
  runTar,
  sha256File,
  shouldIncludeByDate,
  timestampForFilename,
  writeJsonFile,
  writeTextFile,
} from "../utils.js";

async function listJsonlFiles(rootDir, relativePrefix) {
  const files = [];

  async function walk(current, rel) {
    const entries = await fs.readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === ".DS_Store") continue;
      const absolute = path.join(current, entry.name);
      const relative = rel ? path.join(rel, entry.name) : entry.name;
      if (entry.isDirectory()) {
        await walk(absolute, relative);
      } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
        files.push({
          absolutePath: absolute,
          relativePath: path.join(relativePrefix, relative),
        });
      }
    }
  }

  if (await pathExists(rootDir)) {
    await walk(rootDir, "");
  }

  files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  return files;
}

async function collectSessionSources(codexHome, options) {
  const mode = options.threads || "all";
  const sinceTs = parseDateFilterValue(options.since, "start");
  const untilTs = parseDateFilterValue(options.until, "end");

  const selected = [];

  if (mode === "all" || mode === "active") {
    const active = await listJsonlFiles(path.join(codexHome, "sessions"), "sessions");
    selected.push(...active);
  }

  if (mode === "all" || mode === "archived") {
    const archived = await listJsonlFiles(path.join(codexHome, "archived_sessions"), "archived_sessions");
    selected.push(...archived);
  }

  return selected.filter((item) => shouldIncludeByDate(item.absolutePath, sinceTs, untilTs));
}

async function buildFilteredIndex(sourceFile, destinationFile, sessionIds, summary) {
  if (!(await pathExists(sourceFile))) {
    throw new Error(`缺少索引文件: ${sourceFile}`);
  }

  const raw = await fs.readFile(sourceFile, "utf8");
  const lines = raw.split(/\r?\n/);
  const outputLines = [];

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (!line) continue;

    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      summary.warnings.push({
        message: "session_index.jsonl 含坏行，已跳过",
        detail: {
          line: index + 1,
          error: error instanceof Error ? error.message : String(error),
        },
      });
      continue;
    }

    if (parsed && typeof parsed.id === "string") {
      const id = parsed.id.toLowerCase();
      if (sessionIds.has(id)) {
        outputLines.push(line);
      }
    }
  }

  await writeTextFile(destinationFile, `${outputLines.join("\n")}\n`);
}

async function writeManifestAndChecksums(packageRoot, payloadRoot, metadata, summary) {
  const payloadFiles = await collectPayloadFiles(payloadRoot);
  const manifestFiles = [];
  const checksums = [];

  for (const file of payloadFiles) {
    const normalizedPayloadRelative = path.posix.normalize(file.relativePath.replace(/\\/g, "/"));
    const relativeInPackage = path.posix.join("payload", normalizedPayloadRelative);
    const stat = await fs.stat(file.absolutePath);
    const digest = await sha256File(file.absolutePath);

    const row = {
      relative_path: relativeInPackage,
      size_bytes: stat.size,
      sha256: digest,
    };

    if (file.relativePath.endsWith(".jsonl")) {
      const jsonlStats = await parseJsonlFile(file.absolutePath);
      row.line_count = jsonlStats.lineCount;
      row.bad_line_count = jsonlStats.badLineCount;
      row.session_id = jsonlStats.sessionId || extractSessionIdFromFilename(file.absolutePath);
      row.first_timestamp = jsonlStats.firstTimestamp;
      row.last_timestamp = jsonlStats.lastTimestamp;
      row.has_session_meta = jsonlStats.hasSessionMeta;
      row.has_conversation_message = jsonlStats.hasConversationMessage;

      if (jsonlStats.badLineCount > 0) {
        summary.failures.push({
          message: "JSONL 文件有坏行，导出终止",
          detail: {
            file: relativeInPackage,
            bad_line_count: jsonlStats.badLineCount,
          },
        });
      }
    }

    manifestFiles.push(row);
    checksums.push(`${digest}  ${relativeInPackage}`);
  }

  const manifest = {
    export_id: metadata.exportId,
    created_at: metadata.createdAt,
    source_codex_home: metadata.codexHome,
    included_paths: metadata.includedPaths,
    excluded_paths: metadata.excludedPaths,
    options: metadata.options,
    file_count: manifestFiles.length,
    total_bytes: manifestFiles.reduce((sum, item) => sum + item.size_bytes, 0),
    files: manifestFiles,
  };

  await writeJsonFile(path.join(packageRoot, "manifest.json"), manifest);
  await writeTextFile(path.join(packageRoot, "checksums.sha256"), `${checksums.join("\n")}\n`);

  return manifest;
}

function resolveOutputPath(options, timestamp) {
  const out = options.out ? resolvePath(options.out) : null;
  if (out) return out;

  if (options.manifestOnly) {
    return resolvePath(`./codex-sessions-export-${timestamp}`);
  }

  if (options.compress === "none") {
    return resolvePath(`./codex-sessions-export-${timestamp}.tar`);
  }

  if (options.compress === "zst") {
    return resolvePath(`./codex-sessions-export-${timestamp}.tar.zst`);
  }

  return resolvePath(`./codex-sessions-export-${timestamp}.tar.gz`);
}

function buildReportPath(options, timestamp) {
  const reportDir = resolvePath(options.reportDir || "./reports");
  return path.join(reportDir, `backup-report-${timestamp}.json`);
}

export async function runBackup(rawOptions = {}) {
  const startedAt = nowIso();
  const timestamp = timestampForFilename(new Date());
  const codexHome = resolvePath(rawOptions.codexHome || defaultCodexHome());

  const options = {
    codexHome,
    out: rawOptions.out,
    reportDir: rawOptions.reportDir,
    includeHistory: pickBoolean(rawOptions.includeHistory, false),
    includeGlobalState: pickBoolean(rawOptions.includeGlobalState, false),
    manifestOnly: pickBoolean(rawOptions.manifestOnly, false),
    dryRun: pickBoolean(rawOptions.dryRun, false),
    threads: rawOptions.threads || "all",
    since: rawOptions.since || null,
    until: rawOptions.until || null,
    compress: rawOptions.compress || "gz",
  };

  const summary = {
    warnings: [],
    failures: [],
  };

  const outputPath = resolveOutputPath(options, timestamp);
  const reportPath = buildReportPath(options, timestamp);
  const layoutIssues = await ensureRequiredLayout(codexHome);

  if (layoutIssues.length > 0) {
    summary.failures.push({
      message: "Codex 目录结构不完整",
      detail: layoutIssues,
    });
  }

  if (!["all", "active", "archived"].includes(options.threads)) {
    summary.failures.push({
      message: `threads 参数无效: ${options.threads}`,
    });
  }

  if (!["gz", "none", "zst"].includes(options.compress)) {
    summary.failures.push({
      message: `compress 参数无效: ${options.compress}`,
    });
  }

  let manifest = null;
  let packageRoot = null;

  if (summary.failures.length === 0) {
    const tempDir = await createTempDir("codex-sessions-backup-");
    packageRoot = path.join(tempDir, `codex-sessions-export-${timestamp}`);
    const payloadRoot = path.join(packageRoot, "payload");

    try {
      await ensureDir(payloadRoot);

      const sessionFiles = await collectSessionSources(codexHome, options);
      const sessionIds = new Set();

      for (const file of sessionFiles) {
        const target = path.join(payloadRoot, file.relativePath);
        await copyFileWithParents(file.absolutePath, target);
        let sessionId = extractSessionIdFromFilename(file.absolutePath);
        if (!sessionId) {
          const parsed = await parseJsonlFile(file.absolutePath);
          sessionId = parsed.sessionId;
        }
        if (sessionId) sessionIds.add(sessionId.toLowerCase());
      }

      const indexSource = path.join(codexHome, "session_index.jsonl");
      const indexTarget = path.join(payloadRoot, "session_index.jsonl");
      await buildFilteredIndex(indexSource, indexTarget, sessionIds, summary);

      if (options.includeHistory) {
        const historySource = path.join(codexHome, "history.jsonl");
        if (await pathExists(historySource)) {
          await copyFileWithParents(historySource, path.join(payloadRoot, "history.jsonl"));
        } else {
          summary.warnings.push({
            message: "请求导出 history.jsonl，但文件不存在",
            detail: { path: historySource },
          });
        }
      }

      if (options.includeGlobalState) {
        const globalStateSource = path.join(codexHome, ".codex-global-state.json");
        if (await pathExists(globalStateSource)) {
          await copyFileWithParents(globalStateSource, path.join(payloadRoot, ".codex-global-state.json"));
        } else {
          summary.warnings.push({
            message: "请求导出 .codex-global-state.json，但文件不存在",
            detail: { path: globalStateSource },
          });
        }
      }

      manifest = await writeManifestAndChecksums(
        packageRoot,
        payloadRoot,
        {
          exportId: `codex-sessions-${timestamp}`,
          createdAt: startedAt,
          codexHome,
          includedPaths: ["sessions", "archived_sessions", "session_index.jsonl"],
          excludedPaths: ["auth.json", "models_cache.json", "log/*"],
          options,
        },
        summary,
      );

      if (summary.failures.length === 0 && !options.dryRun) {
        if (options.manifestOnly) {
          if (await pathExists(outputPath)) {
            throw new Error(`输出目录已存在: ${outputPath}`);
          }
          await fs.cp(packageRoot, outputPath, { recursive: true });
        } else {
          await ensureDir(path.dirname(outputPath));
          const packageName = path.basename(packageRoot);
          if (options.compress === "gz") {
            runTar(["-czf", outputPath, packageName], path.dirname(packageRoot));
          } else if (options.compress === "none") {
            runTar(["-cf", outputPath, packageName], path.dirname(packageRoot));
          } else {
            runTar(["--zstd", "-cf", outputPath, packageName], path.dirname(packageRoot));
          }
        }
      }
    } finally {
      await fs.rm(tempDir, { recursive: true, force: true });
    }
  }

  const status = normalizeStatus({
    hasFailures: summary.failures.length > 0,
    hasWarnings: summary.warnings.length > 0,
    failOnWarn: false,
  });

  const report = {
    tool_version: "0.1.0",
    command: "backup",
    started_at: startedAt,
    finished_at: nowIso(),
    status,
    codex_home: codexHome,
    dry_run: options.dryRun,
    output_path: outputPath,
    report_path: reportPath,
    manifest_file_count: manifest?.file_count || 0,
    manifest_total_bytes: manifest?.total_bytes || 0,
    summary,
  };

  await writeJsonFile(reportPath, report);

  return {
    ...report,
    manifest,
  };
}
