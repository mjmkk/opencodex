import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

export const EXIT_CODE = Object.freeze({
  PASS: 0,
  WARN: 10,
  FAIL: 20,
  ERROR: 30,
});

export const STATUS = Object.freeze({
  PASS: "PASS",
  WARN: "WARN",
  FAIL: "FAIL",
  ERROR: "ERROR",
});

export const REQUIRED_ITEMS = Object.freeze([
  { path: "sessions", type: "dir" },
  { path: "archived_sessions", type: "dir" },
  { path: "session_index.jsonl", type: "file" },
]);

export function defaultCodexHome() {
  return path.join(os.homedir(), ".codex");
}

export function timestampForFilename(date = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getUTCFullYear()}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}-${pad(
    date.getUTCHours(),
  )}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}`;
}

export function expandHome(input) {
  if (!input) return input;
  if (input === "~") return os.homedir();
  if (input.startsWith("~/")) return path.join(os.homedir(), input.slice(2));
  return input;
}

export function resolvePath(input, cwd = process.cwd()) {
  if (!input) return input;
  return path.resolve(cwd, expandHome(input));
}

export async function pathExists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

export async function ensureDir(dirPath) {
  await fs.mkdir(dirPath, { recursive: true });
}

export async function listFilesRecursively(rootDir) {
  const result = [];

  async function walk(current) {
    const entries = await fs.readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === ".DS_Store") continue;
      const absolute = path.join(current, entry.name);
      if (entry.isDirectory()) {
        await walk(absolute);
      } else if (entry.isFile()) {
        result.push(absolute);
      }
    }
  }

  await walk(rootDir);
  result.sort();
  return result;
}

export async function sha256File(filePath) {
  const hash = crypto.createHash("sha256");
  const handle = await fs.open(filePath, "r");

  try {
    const buffer = Buffer.allocUnsafe(1024 * 1024);
    while (true) {
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
      if (bytesRead <= 0) break;
      hash.update(buffer.subarray(0, bytesRead));
    }
  } finally {
    await handle.close();
  }

  return hash.digest("hex");
}

export async function parseJsonlFile(filePath) {
  const content = await fs.readFile(filePath, "utf8");
  const lines = content.split(/\r?\n/);

  const stats = {
    lineCount: 0,
    badLineCount: 0,
    badLines: [],
    typeCounts: {},
    hasSessionMeta: false,
    hasConversationMessage: false,
    firstTimestamp: null,
    lastTimestamp: null,
    monotonicTimestamps: true,
    timestampViolations: 0,
    sessionId: null,
  };

  let previousTimestampMs = null;

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line) continue;

    stats.lineCount += 1;

    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch (error) {
      stats.badLineCount += 1;
      stats.badLines.push({
        line: i + 1,
        error: error instanceof Error ? error.message : String(error),
      });
      continue;
    }

    const itemType = typeof parsed.type === "string" ? parsed.type : "unknown";
    stats.typeCounts[itemType] = (stats.typeCounts[itemType] || 0) + 1;

    if (parsed.type === "session_meta" && parsed.payload && typeof parsed.payload === "object") {
      stats.hasSessionMeta = true;
      if (typeof parsed.payload.id === "string") {
        stats.sessionId = parsed.payload.id;
      }
    }

    if (
      parsed.type === "response_item" &&
      parsed.payload &&
      parsed.payload.type === "message" &&
      (parsed.payload.role === "user" || parsed.payload.role === "assistant")
    ) {
      stats.hasConversationMessage = true;
    }

    if (parsed.payload && (parsed.payload.type === "user_message" || parsed.payload.type === "agent_message")) {
      stats.hasConversationMessage = true;
    }

    if (typeof parsed.timestamp === "string") {
      const timestampMs = Date.parse(parsed.timestamp);
      if (!Number.isNaN(timestampMs)) {
        if (!stats.firstTimestamp) stats.firstTimestamp = parsed.timestamp;
        stats.lastTimestamp = parsed.timestamp;

        if (previousTimestampMs !== null && timestampMs < previousTimestampMs) {
          stats.monotonicTimestamps = false;
          stats.timestampViolations += 1;
        }

        previousTimestampMs = timestampMs;
      }
    }
  }

  return stats;
}

export function extractSessionIdFromFilename(filePath) {
  const base = path.basename(filePath);
  const match = base.match(/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$/i);
  return match ? match[1].toLowerCase() : null;
}

export function parseDateFilterValue(value, boundary) {
  if (!value) return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new Error(`日期参数格式错误: ${value}，应为 YYYY-MM-DD`);
  }

  const suffix = boundary === "end" ? "T23:59:59.999Z" : "T00:00:00.000Z";
  const timestamp = Date.parse(`${value}${suffix}`);
  if (Number.isNaN(timestamp)) {
    throw new Error(`无法解析日期: ${value}`);
  }

  return timestamp;
}

export function extractDateFromRolloutFilename(filePath) {
  const base = path.basename(filePath);
  const match = base.match(/^rollout-(\d{4}-\d{2}-\d{2})T/);
  if (!match) return null;
  return Date.parse(`${match[1]}T00:00:00.000Z`);
}

export function shouldIncludeByDate(filePath, sinceTs, untilTs) {
  if (!sinceTs && !untilTs) return true;
  const dateTs = extractDateFromRolloutFilename(filePath);
  if (!dateTs) return true;
  if (sinceTs && dateTs < sinceTs) return false;
  if (untilTs && dateTs > untilTs) return false;
  return true;
}

export function runTar(args, cwd) {
  const result = spawnSync("tar", args, {
    cwd,
    encoding: "utf8",
  });

  if (result.status !== 0) {
    const stderr = result.stderr?.trim();
    throw new Error(`tar 执行失败: ${stderr || "未知错误"}`);
  }
}

export async function removeDirSafe(targetPath) {
  if (!targetPath) return;
  if (!(await pathExists(targetPath))) return;
  await fs.rm(targetPath, { recursive: true, force: true });
}

export async function writeJsonFile(targetPath, data) {
  const payload = `${JSON.stringify(data, null, 2)}\n`;
  await ensureDir(path.dirname(targetPath));
  await fs.writeFile(targetPath, payload, "utf8");
}

export async function writeTextFile(targetPath, text) {
  await ensureDir(path.dirname(targetPath));
  await fs.writeFile(targetPath, text, "utf8");
}

export async function readJsonLines(filePath) {
  const content = await fs.readFile(filePath, "utf8");
  const lines = content.split(/\r?\n/);
  const parsed = [];
  const bad = [];

  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line) continue;
    try {
      parsed.push(JSON.parse(line));
    } catch (error) {
      bad.push({ line: i + 1, text: line, error: error instanceof Error ? error.message : String(error) });
    }
  }

  return { parsed, bad };
}

export function normalizeStatus({ hasFailures, hasWarnings, failOnWarn }) {
  if (hasFailures) return STATUS.FAIL;
  if (hasWarnings && failOnWarn) return STATUS.FAIL;
  if (hasWarnings) return STATUS.WARN;
  return STATUS.PASS;
}

export function statusToExitCode(status) {
  switch (status) {
    case STATUS.PASS:
      return EXIT_CODE.PASS;
    case STATUS.WARN:
      return EXIT_CODE.WARN;
    case STATUS.FAIL:
      return EXIT_CODE.FAIL;
    default:
      return EXIT_CODE.ERROR;
  }
}

export async function ensureRequiredLayout(codexHome) {
  const issues = [];

  for (const item of REQUIRED_ITEMS) {
    const absolute = path.join(codexHome, item.path);
    const exists = await pathExists(absolute);
    if (!exists) {
      issues.push({
        path: absolute,
        type: "missing",
        expected: item.type,
      });
      continue;
    }

    const stat = await fs.stat(absolute);
    const ok = item.type === "dir" ? stat.isDirectory() : stat.isFile();
    if (!ok) {
      issues.push({
        path: absolute,
        type: "mismatch",
        expected: item.type,
      });
    }
  }

  return issues;
}

export function pickBoolean(value, fallback = false) {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["1", "true", "yes", "on"].includes(normalized)) return true;
    if (["0", "false", "no", "off"].includes(normalized)) return false;
  }
  return fallback;
}

export function parseNumber(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback;
  const number = Number(value);
  if (Number.isNaN(number)) return fallback;
  return number;
}

export async function copyFileWithParents(source, destination) {
  await ensureDir(path.dirname(destination));
  await fs.copyFile(source, destination);
}

export async function collectPayloadFiles(payloadRoot) {
  if (!(await pathExists(payloadRoot))) return [];
  const files = await listFilesRecursively(payloadRoot);
  return files.map((absolutePath) => ({
    absolutePath,
    relativePath: path.relative(payloadRoot, absolutePath),
  }));
}

export async function createTempDir(prefix) {
  return fs.mkdtemp(path.join(os.tmpdir(), prefix));
}

export function nowIso() {
  return new Date().toISOString();
}
