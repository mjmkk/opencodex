import fs from "node:fs/promises";
import path from "node:path";

import {
  createTempDir,
  ensureDir,
  pathExists,
  removeDirSafe,
  runTar,
  resolvePath,
} from "./utils.js";

function packageLooksValid(root) {
  return Promise.all([
    pathExists(path.join(root, "manifest.json")),
    pathExists(path.join(root, "checksums.sha256")),
    pathExists(path.join(root, "payload")),
  ]).then(([hasManifest, hasChecksums, hasPayload]) => hasManifest && hasChecksums && hasPayload);
}

export async function locatePackageRoot(inputPath) {
  const resolved = resolvePath(inputPath);
  if (!resolved) {
    throw new Error("缺少输入路径");
  }

  const stat = await fs.stat(resolved).catch(() => null);
  if (!stat) {
    throw new Error(`路径不存在: ${resolved}`);
  }

  let cleanup = null;
  let rootCandidate = resolved;

  if (stat.isFile()) {
    const tempDir = await createTempDir("codex-sessions-load-");
    cleanup = async () => removeDirSafe(tempDir);

    await ensureDir(tempDir);
    const extension = path.extname(resolved).toLowerCase();
    const isGzip = resolved.endsWith(".tar.gz") || resolved.endsWith(".tgz") || extension === ".gz";

    const tarArgs = isGzip ? ["-xzf", resolved, "-C", tempDir] : ["-xf", resolved, "-C", tempDir];
    runTar(tarArgs);

    rootCandidate = tempDir;
  }

  if (await packageLooksValid(rootCandidate)) {
    return { packageRoot: rootCandidate, cleanup };
  }

  const firstLevel = await fs.readdir(rootCandidate, { withFileTypes: true });
  for (const entry of firstLevel) {
    if (!entry.isDirectory()) continue;
    const subRoot = path.join(rootCandidate, entry.name);
    if (await packageLooksValid(subRoot)) {
      return { packageRoot: subRoot, cleanup };
    }
  }

  if (cleanup) {
    await cleanup();
  }

  throw new Error(`未找到合法导出包结构: ${resolved}`);
}

export async function readChecksumsFile(packageRoot) {
  const checksumsPath = path.join(packageRoot, "checksums.sha256");
  const content = await fs.readFile(checksumsPath, "utf8");
  const lines = content.split(/\r?\n/);
  const entries = [];

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const match = trimmed.match(/^([a-f0-9]{64})\s{2}(.+)$/i);
    if (!match) {
      throw new Error(`checksums 格式错误: ${trimmed}`);
    }

    entries.push({
      sha256: match[1].toLowerCase(),
      relativePath: match[2],
    });
  }

  return entries;
}

export async function detectPayloadFiles(packageRoot) {
  const payloadRoot = path.join(packageRoot, "payload");
  const files = [];

  async function walk(current) {
    const entries = await fs.readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === ".DS_Store") continue;
      const abs = path.join(current, entry.name);
      if (entry.isDirectory()) {
        await walk(abs);
      } else if (entry.isFile()) {
        files.push({
          absolutePath: abs,
          relativePath: path.relative(payloadRoot, abs),
        });
      }
    }
  }

  if (await pathExists(payloadRoot)) {
    await walk(payloadRoot);
  }

  files.sort((a, b) => a.relativePath.localeCompare(b.relativePath));
  return files;
}
