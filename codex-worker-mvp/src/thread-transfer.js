import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { HttpError } from "./errors.js";

const THREAD_ID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EXPORT_FORMAT = "codex.thread-export.v1";

function nowIso() {
  return new Date().toISOString();
}

function timestampForName(date = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getUTCFullYear()}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}-${pad(
    date.getUTCHours(),
  )}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}`;
}

function isThreadId(value) {
  return typeof value === "string" && THREAD_ID_PATTERN.test(value.trim());
}

function normalizeThreadId(value) {
  return typeof value === "string" ? value.trim().toLowerCase() : "";
}

function sanitizeRelativePath(relativePath) {
  const normalized = path.normalize(relativePath);
  if (path.isAbsolute(normalized) || normalized.startsWith("..")) {
    throw new HttpError(400, "INVALID_PACKAGE_CONTENT", "导出包中的路径非法");
  }
  return normalized;
}

function extractThreadIdFromFilename(filePath) {
  const base = path.basename(filePath);
  const match = base.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i);
  return match ? match[1].toLowerCase() : null;
}

async function pathExists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function ensureDir(dirPath) {
  await fs.mkdir(dirPath, { recursive: true });
}

function deepReplaceExactString(value, source, target) {
  if (typeof value === "string") {
    return value === source ? target : value;
  }
  if (Array.isArray(value)) {
    return value.map((item) => deepReplaceExactString(item, source, target));
  }
  if (value && typeof value === "object") {
    const next = {};
    for (const [key, inner] of Object.entries(value)) {
      next[key] = deepReplaceExactString(inner, source, target);
    }
    return next;
  }
  return value;
}

function rewriteSessionJsonlThreadId(raw, sourceId, targetId) {
  const lines = raw.split(/\r?\n/);
  const output = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (!line) continue;
    let parsed = null;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      throw new HttpError(
        400,
        "INVALID_PACKAGE_CONTENT",
        `导入包内 JSONL 行无效：line=${index + 1}, error=${detail}`,
      );
    }
    output.push(JSON.stringify(deepReplaceExactString(parsed, sourceId, targetId)));
  }
  return `${output.join("\n")}\n`;
}

async function readJsonLines(filePath) {
  if (!(await pathExists(filePath))) {
    return [];
  }
  const raw = await fs.readFile(filePath, "utf8");
  const lines = raw.split(/\r?\n/);
  const rows = [];
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      rows.push(JSON.parse(trimmed));
    } catch {
      continue;
    }
  }
  return rows;
}

async function collectExistingThreadIds(codexHome) {
  const ids = new Set();
  const indexRows = await readJsonLines(path.join(codexHome, "session_index.jsonl"));
  for (const row of indexRows) {
    if (row && typeof row.id === "string" && isThreadId(row.id)) {
      ids.add(normalizeThreadId(row.id));
    }
  }

  async function walk(baseDir) {
    if (!(await pathExists(baseDir))) {
      return;
    }
    const entries = await fs.readdir(baseDir, { withFileTypes: true });
    for (const entry of entries) {
      const absolute = path.join(baseDir, entry.name);
      if (entry.isDirectory()) {
        await walk(absolute);
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) {
        continue;
      }
      const id = extractThreadIdFromFilename(entry.name);
      if (id) {
        ids.add(id);
      }
    }
  }

  await walk(path.join(codexHome, "sessions"));
  await walk(path.join(codexHome, "archived_sessions"));
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

async function findThreadFile(codexHome, threadId) {
  const candidates = [];

  async function walk(baseDir, relativePrefix) {
    if (!(await pathExists(baseDir))) {
      return;
    }
    const entries = await fs.readdir(baseDir, { withFileTypes: true });
    for (const entry of entries) {
      const absolute = path.join(baseDir, entry.name);
      const relative = path.join(relativePrefix, entry.name);
      if (entry.isDirectory()) {
        await walk(absolute, relative);
        continue;
      }
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) {
        continue;
      }
      const id = extractThreadIdFromFilename(entry.name);
      if (id === threadId) {
        const stat = await fs.stat(absolute);
        candidates.push({
          absolutePath: absolute,
          relativePath: relative,
          updatedAtMs: stat.mtimeMs,
        });
      }
    }
  }

  await walk(path.join(codexHome, "sessions"), "sessions");
  await walk(path.join(codexHome, "archived_sessions"), "archived_sessions");

  if (candidates.length === 0) {
    return null;
  }
  if (candidates.length === 1) {
    return candidates[0];
  }

  candidates.sort((a, b) => b.updatedAtMs - a.updatedAtMs);
  return candidates[0];
}

async function readIndexEntry(codexHome, threadId) {
  const rows = await readJsonLines(path.join(codexHome, "session_index.jsonl"));
  for (const row of rows) {
    if (row && typeof row.id === "string" && normalizeThreadId(row.id) === threadId) {
      return row;
    }
  }
  return null;
}

function buildDefaultRelativePath(targetId, now = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  const y = now.getUTCFullYear();
  const m = pad(now.getUTCMonth() + 1);
  const d = pad(now.getUTCDate());
  const ts = `${y}-${m}-${d}T${pad(now.getUTCHours())}-${pad(now.getUTCMinutes())}-${pad(now.getUTCSeconds())}`;
  return path.join("sessions", String(y), m, d, `imported-${ts}-${targetId}.jsonl`);
}

function buildActiveRelativePath(sourceRelativePath, sourceId, targetId) {
  const safe = sanitizeRelativePath(sourceRelativePath);
  const sourceSuffix = `-${sourceId}.jsonl`;
  const sourceBase = path.basename(safe);
  const sourceDir = path.dirname(safe);
  let nextDir = sourceDir;
  if (nextDir === ".") {
    nextDir = "sessions";
  } else if (nextDir.startsWith("archived_sessions/")) {
    nextDir = path.join("sessions", nextDir.slice("archived_sessions/".length));
  } else if (nextDir === "archived_sessions") {
    nextDir = "sessions";
  } else if (!nextDir.startsWith("sessions/") && nextDir !== "sessions") {
    nextDir = "sessions";
  }

  if (sourceBase.endsWith(sourceSuffix)) {
    const baseWithoutSuffix = sourceBase.slice(0, -sourceSuffix.length);
    return path.join(nextDir, `${baseWithoutSuffix}-${targetId}.jsonl`);
  }

  if (sourceBase.endsWith(".jsonl")) {
    const baseWithoutExt = sourceBase.slice(0, -".jsonl".length);
    return path.join(nextDir, `${baseWithoutExt}-${targetId}.jsonl`);
  }

  return buildDefaultRelativePath(targetId);
}

async function appendIndexEntry(codexHome, entry) {
  const indexPath = path.join(codexHome, "session_index.jsonl");
  let raw = "";
  if (await pathExists(indexPath)) {
    raw = await fs.readFile(indexPath, "utf8");
  }
  if (raw.length > 0 && !raw.endsWith("\n")) {
    raw += "\n";
  }
  raw += `${JSON.stringify(entry)}\n`;
  await fs.writeFile(indexPath, raw, "utf8");
}

function createExportId() {
  return `texp_${timestampForName()}_${crypto.randomBytes(4).toString("hex")}`;
}

export function defaultCodexHome() {
  return path.join(os.homedir(), ".codex");
}

export function defaultThreadExportDir() {
  return path.join(os.tmpdir(), "codex-thread-exports");
}

export async function exportThreadToPackage(options) {
  const codexHome = options.codexHome || defaultCodexHome();
  const threadId = normalizeThreadId(options.threadId);
  const exportDir = options.exportDir || defaultThreadExportDir();

  if (!isThreadId(threadId)) {
    throw new HttpError(400, "INVALID_THREAD_ID", "threadId 格式无效");
  }

  const threadFile = await findThreadFile(codexHome, threadId);
  if (!threadFile) {
    throw new HttpError(404, "THREAD_NOT_FOUND", `未找到线程 ${threadId} 对应的会话文件`);
  }

  const sessionJsonl = await fs.readFile(threadFile.absolutePath, "utf8");
  const sourceIndexEntry = await readIndexEntry(codexHome, threadId);
  const exportId = createExportId();

  await ensureDir(exportDir);
  const packagePath = path.join(exportDir, `${exportId}.json`);
  const payload = {
    format: EXPORT_FORMAT,
    exportedAt: nowIso(),
    source: {
      threadId,
      relativePath: threadFile.relativePath,
      archived: threadFile.relativePath.startsWith("archived_sessions/"),
    },
    sourceIndexEntry,
    sessionJsonl,
  };
  await fs.writeFile(packagePath, `${JSON.stringify(payload, null, 2)}\n`, "utf8");

  return {
    exportId,
    packagePath,
    format: EXPORT_FORMAT,
    sourceThreadId: threadId,
    sourceRelativePath: threadFile.relativePath,
    sizeBytes: Buffer.byteLength(sessionJsonl),
    exportedAt: payload.exportedAt,
  };
}

export async function importThreadFromPackageAsNew(options) {
  const codexHome = options.codexHome || defaultCodexHome();
  const packagePath = typeof options.packagePath === "string" ? options.packagePath.trim() : "";
  if (!packagePath) {
    throw new HttpError(400, "INVALID_PACKAGE_PATH", "packagePath 不能为空");
  }
  if (!(await pathExists(packagePath))) {
    throw new HttpError(404, "PACKAGE_NOT_FOUND", `导入包不存在: ${packagePath}`);
  }

  let payload = null;
  try {
    const raw = await fs.readFile(packagePath, "utf8");
    payload = JSON.parse(raw);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new HttpError(400, "INVALID_PACKAGE_CONTENT", `导入包读取失败: ${detail}`);
  }

  if (!payload || payload.format !== EXPORT_FORMAT) {
    throw new HttpError(400, "INVALID_PACKAGE_CONTENT", "导入包格式不受支持");
  }

  const sourceThreadId = normalizeThreadId(payload?.source?.threadId);
  if (!isThreadId(sourceThreadId)) {
    throw new HttpError(400, "INVALID_PACKAGE_CONTENT", "导入包缺少合法 source.threadId");
  }
  if (typeof payload.sessionJsonl !== "string" || payload.sessionJsonl.trim().length === 0) {
    throw new HttpError(400, "INVALID_PACKAGE_CONTENT", "导入包缺少会话内容");
  }

  await ensureDir(codexHome);
  await ensureDir(path.join(codexHome, "sessions"));
  await ensureDir(path.join(codexHome, "archived_sessions"));

  const existingIds = await collectExistingThreadIds(codexHome);
  const targetThreadId = createUniqueThreadId(existingIds);
  existingIds.add(targetThreadId);

  const sourceRelativePath =
    typeof payload?.source?.relativePath === "string" ? payload.source.relativePath : buildDefaultRelativePath(sourceThreadId);

  let targetRelativePath = buildActiveRelativePath(sourceRelativePath, sourceThreadId, targetThreadId);
  let destination = path.join(codexHome, targetRelativePath);

  while (await pathExists(destination)) {
    const another = createUniqueThreadId(existingIds);
    existingIds.add(another);
    targetRelativePath = buildActiveRelativePath(sourceRelativePath, sourceThreadId, another);
    destination = path.join(codexHome, targetRelativePath);
  }

  const finalThreadId = extractThreadIdFromFilename(destination) || targetThreadId;
  const rewrittenJsonl = rewriteSessionJsonlThreadId(payload.sessionJsonl, sourceThreadId, finalThreadId);
  await ensureDir(path.dirname(destination));
  await fs.writeFile(destination, rewrittenJsonl, "utf8");

  const sourceIndexEntry =
    payload.sourceIndexEntry && typeof payload.sourceIndexEntry === "object" && !Array.isArray(payload.sourceIndexEntry)
      ? payload.sourceIndexEntry
      : {};
  const sourceName =
    typeof sourceIndexEntry.thread_name === "string" && sourceIndexEntry.thread_name.trim().length > 0
      ? sourceIndexEntry.thread_name.trim()
      : "imported-thread";
  const indexEntry = {
    ...sourceIndexEntry,
    id: finalThreadId,
    thread_name: `${sourceName} (imported ${timestampForName()})`,
    updated_at: nowIso(),
  };
  await appendIndexEntry(codexHome, indexEntry);

  return {
    sourceThreadId,
    targetThreadId: finalThreadId,
    targetRelativePath,
    packagePath,
  };
}
