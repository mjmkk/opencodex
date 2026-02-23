import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { runBackup } from "../src/commands/backup.js";
import { runRestore } from "../src/commands/restore.js";
import { runVerify } from "../src/commands/verify.js";

async function createFixtureCodexHome(baseDir) {
  const codexHome = path.join(baseDir, "codex-home");
  await fs.mkdir(path.join(codexHome, "sessions", "2026", "02", "20"), { recursive: true });
  await fs.mkdir(path.join(codexHome, "archived_sessions", "2026", "02", "19"), { recursive: true });

  const activeId = "019c7953-404f-73b2-b291-1d5b834395a1";
  const archivedId = "019c6585-0662-7751-ad58-27e2b0f94794";

  const activeFile = path.join(
    codexHome,
    "sessions",
    "2026",
    "02",
    "20",
    `rollout-2026-02-20T12-33-45-${activeId}.jsonl`,
  );

  const archivedFile = path.join(
    codexHome,
    "archived_sessions",
    "2026",
    "02",
    "19",
    `rollout-2026-02-19T08-11-22-${archivedId}.jsonl`,
  );

  const activeLines = [
    JSON.stringify({
      timestamp: "2026-02-20T04:33:56.938Z",
      type: "session_meta",
      payload: {
        id: activeId,
        timestamp: "2026-02-20T04:33:45.039Z",
        cwd: "/Users/Apple/Dev/OpenCodex",
      },
    }),
    JSON.stringify({
      timestamp: "2026-02-20T04:33:56.939Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "导出会话" }],
      },
    }),
    JSON.stringify({
      timestamp: "2026-02-20T04:34:22.494Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "好的" }],
      },
    }),
  ];

  const archivedLines = [
    JSON.stringify({
      timestamp: "2026-02-19T00:00:01.000Z",
      type: "session_meta",
      payload: {
        id: archivedId,
        timestamp: "2026-02-19T00:00:00.000Z",
      },
    }),
    JSON.stringify({
      timestamp: "2026-02-19T00:00:02.000Z",
      payload: {
        type: "user_message",
        message: "历史会话",
      },
    }),
    JSON.stringify({
      timestamp: "2026-02-19T00:00:03.000Z",
      payload: {
        type: "agent_message",
        message: "收到",
      },
    }),
  ];

  await fs.writeFile(activeFile, `${activeLines.join("\n")}\n`, "utf8");
  await fs.writeFile(archivedFile, `${archivedLines.join("\n")}\n`, "utf8");

  const indexLines = [
    JSON.stringify({ id: activeId, thread_name: "active" }),
    JSON.stringify({ id: archivedId, thread_name: "archived" }),
  ];

  await fs.writeFile(path.join(codexHome, "session_index.jsonl"), `${indexLines.join("\n")}\n`, "utf8");
  await fs.writeFile(path.join(codexHome, "history.jsonl"), `${JSON.stringify({ session_id: activeId, text: "导出" })}\n`, "utf8");
  await fs.writeFile(path.join(codexHome, ".codex-global-state.json"), JSON.stringify({ ui: { last: activeId } }), "utf8");

  return {
    codexHome,
    activeId,
    archivedId,
    activeFile,
  };
}

async function sha256File(filePath) {
  const content = await fs.readFile(filePath);
  return crypto.createHash("sha256").update(content).digest("hex");
}

async function readChecksums(packageRoot) {
  const checksumsPath = path.join(packageRoot, "checksums.sha256");
  const lines = (await fs.readFile(checksumsPath, "utf8")).split(/\r?\n/).filter(Boolean);
  return lines.map((line) => {
    const match = line.match(/^([a-f0-9]{64})\s{2}(.+)$/i);
    if (!match) {
      throw new Error(`checksums 格式错误: ${line}`);
    }
    return {
      sha256: match[1].toLowerCase(),
      relativePath: match[2],
    };
  });
}

async function writeChecksums(packageRoot, entries) {
  const checksumsPath = path.join(packageRoot, "checksums.sha256");
  const rows = entries.map((item) => `${item.sha256}  ${item.relativePath}`);
  await fs.writeFile(checksumsPath, `${rows.join("\n")}\n`, "utf8");
}

async function replaceChecksumRelativePath(packageRoot, fromRelativePath, toRelativePath) {
  const entries = await readChecksums(packageRoot);
  let found = false;
  for (const entry of entries) {
    if (entry.relativePath === fromRelativePath) {
      entry.relativePath = toRelativePath;
      found = true;
      break;
    }
  }
  assert.equal(found, true, `未找到 checksums 条目: ${fromRelativePath}`);
  await writeChecksums(packageRoot, entries);
}

async function refreshChecksumForPath(packageRoot, relativePath) {
  const entries = await readChecksums(packageRoot);
  let found = false;
  const absolutePath = path.join(packageRoot, ...relativePath.split("/"));
  const digest = await sha256File(absolutePath);
  for (const entry of entries) {
    if (entry.relativePath === relativePath) {
      entry.sha256 = digest;
      found = true;
      break;
    }
  }
  assert.equal(found, true, `未找到 checksums 条目: ${relativePath}`);
  await writeChecksums(packageRoot, entries);
}

test("backup -> verify -> restore should pass", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);

  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    manifestOnly: true,
    includeHistory: true,
    includeGlobalState: true,
    out: exportDir,
    reportDir: reportsDir,
  });

  assert.equal(backup.status, "PASS");
  assert.ok(await fs.stat(exportDir));

  const verifyExport = await runVerify({
    input: exportDir,
    mode: "full",
    reportDir: reportsDir,
  });

  assert.equal(verifyExport.status, "PASS");

  const targetHome = path.join(tempRoot, "restored-home");
  const restore = await runRestore({
    package: exportDir,
    targetCodexHome: targetHome,
    conflict: "skip",
    postVerify: true,
    reportDir: reportsDir,
  });

  assert.equal(restore.status, "PASS");
  const restoredSession = path.join(
    targetHome,
    "sessions",
    "2026",
    "02",
    "20",
    `rollout-2026-02-20T12-33-45-${fixture.activeId}.jsonl`,
  );
  const restoredContent = await fs.readFile(restoredSession, "utf8");
  assert.match(restoredContent, /session_meta/);
});

test("verify should fail if payload is tampered", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);

  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    manifestOnly: true,
    out: exportDir,
    reportDir: reportsDir,
  });

  assert.equal(backup.status, "PASS");

  const tamperedFile = path.join(
    exportDir,
    "payload",
    "sessions",
    "2026",
    "02",
    "20",
    `rollout-2026-02-20T12-33-45-${fixture.activeId}.jsonl`,
  );

  await fs.appendFile(tamperedFile, "{\"tampered\":true}\n", "utf8");

  const verifyResult = await runVerify({
    input: exportDir,
    mode: "full",
    reportDir: reportsDir,
  });

  assert.equal(verifyResult.status, "FAIL");
  assert.ok(verifyResult.result.summary.failures.length > 0);
});

test("verify should fail if payload contains undeclared file", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);
  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    manifestOnly: true,
    out: exportDir,
    reportDir: reportsDir,
  });
  assert.equal(backup.status, "PASS");

  const injectedId = "c77a2d34-7838-41aa-af8a-f36ddf950111";
  const injectedPath = path.join(
    exportDir,
    "payload",
    "sessions",
    "2026",
    "02",
    "20",
    `rollout-2026-02-20T12-59-59-${injectedId}.jsonl`,
  );
  const injectedLines = [
    JSON.stringify({
      timestamp: "2026-02-20T04:59:59.000Z",
      type: "session_meta",
      payload: { id: injectedId, cwd: "/tmp/injected" },
    }),
    JSON.stringify({
      timestamp: "2026-02-20T05:00:00.000Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "injected file" }],
      },
    }),
  ];
  await fs.mkdir(path.dirname(injectedPath), { recursive: true });
  await fs.writeFile(injectedPath, `${injectedLines.join("\n")}\n`, "utf8");

  const verifyResult = await runVerify({
    input: exportDir,
    mode: "full",
    reportDir: reportsDir,
  });

  assert.equal(verifyResult.status, "FAIL");
  assert.ok(
    verifyResult.result.summary.failures.some((item) =>
      item?.message === "payload 存在未在 checksums 声明的文件"),
  );
});

test("restore add-only on same codex home should create new thread ids without overwrite", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);

  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    manifestOnly: true,
    out: exportDir,
    reportDir: reportsDir,
  });

  assert.equal(backup.status, "PASS");

  const beforeFiles = await fs.readdir(path.join(fixture.codexHome, "sessions", "2026", "02", "20"));
  assert.equal(beforeFiles.length, 1);

  const restore = await runRestore({
    package: exportDir,
    targetCodexHome: fixture.codexHome,
    conflict: "skip",
    addOnly: true,
    postVerify: true,
    reportDir: reportsDir,
  });

  assert.equal(restore.status, "PASS");
  assert.ok(restore.actions.remapped_threads >= 1);
  assert.ok(restore.actions.index_appended >= 1);

  const afterFiles = await fs.readdir(path.join(fixture.codexHome, "sessions", "2026", "02", "20"));
  assert.ok(afterFiles.length >= 2);

  const originalName = `rollout-2026-02-20T12-33-45-${fixture.activeId}.jsonl`;
  assert.ok(afterFiles.includes(originalName));

  const importedName = afterFiles.find(
    (name) => name.endsWith(".jsonl") && name !== originalName,
  );
  assert.ok(importedName);

  const importedId = importedName.match(/([0-9a-f-]{36})\.jsonl$/i)?.[1]?.toLowerCase();
  assert.ok(importedId);
  assert.notEqual(importedId, fixture.activeId);

  const indexRaw = await fs.readFile(path.join(fixture.codexHome, "session_index.jsonl"), "utf8");
  assert.match(indexRaw, new RegExp(importedId));
});

test("restore conflict=rename should keep session file importable and append index", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);

  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    threads: "active",
    manifestOnly: true,
    out: exportDir,
    reportDir: reportsDir,
  });
  assert.equal(backup.status, "PASS");

  await fs.appendFile(
    fixture.activeFile,
    `${JSON.stringify({
      timestamp: "2026-02-20T04:35:00.000Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "assistant",
        content: [{ type: "output_text", text: "conflict-rename-test" }],
      },
    })}\n`,
    "utf8",
  );

  const restore = await runRestore({
    package: exportDir,
    targetCodexHome: fixture.codexHome,
    addOnly: false,
    conflict: "rename",
    postVerify: false,
    reportDir: reportsDir,
  });

  assert.equal(restore.status, "PASS");
  assert.ok(restore.actions.remapped_threads >= 1);
  assert.ok(restore.actions.index_appended >= 1);

  const sessionDir = path.join(fixture.codexHome, "sessions", "2026", "02", "20");
  const names = await fs.readdir(sessionDir);
  assert.equal(names.some((name) => name.includes(".jsonl.imported")), false);

  const importedName = names.find(
    (name) => name.endsWith(".jsonl") && name !== `rollout-2026-02-20T12-33-45-${fixture.activeId}.jsonl`,
  );
  assert.ok(importedName);
  const importedId = importedName.match(/([0-9a-f-]{36})\.jsonl$/i)?.[1]?.toLowerCase();
  assert.ok(importedId);
  assert.notEqual(importedId, fixture.activeId);

  const indexRaw = await fs.readFile(path.join(fixture.codexHome, "session_index.jsonl"), "utf8");
  assert.match(indexRaw, new RegExp(importedId));
});

test("restore dry-run should not fail on fresh target home", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);

  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");
  const targetHome = path.join(tempRoot, "dryrun-target");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    manifestOnly: true,
    out: exportDir,
    reportDir: reportsDir,
  });
  assert.equal(backup.status, "PASS");

  const restore = await runRestore({
    package: exportDir,
    targetCodexHome: targetHome,
    dryRun: true,
    postVerify: true,
    reportDir: reportsDir,
  });

  assert.equal(restore.status, "PASS");
  assert.equal(await fs.stat(targetHome).then(() => true).catch(() => false), false);
});

test("backup should parse string booleans correctly", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);

  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    out: exportDir,
    reportDir: reportsDir,
    manifestOnly: true,
    includeHistory: "false",
    includeGlobalState: "false",
  });
  assert.equal(backup.status, "PASS");

  const historyExists = await fs
    .access(path.join(exportDir, "payload", "history.jsonl"))
    .then(() => true)
    .catch(() => false);
  const globalStateExists = await fs
    .access(path.join(exportDir, "payload", ".codex-global-state.json"))
    .then(() => true)
    .catch(() => false);

  assert.equal(historyExists, false);
  assert.equal(globalStateExists, false);
});

test("backup default output suffix should match compress type", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);
  const reportsDir = path.join(tempRoot, "reports");

  const noneResult = await runBackup({
    codexHome: fixture.codexHome,
    dryRun: true,
    compress: "none",
    reportDir: reportsDir,
  });
  const zstResult = await runBackup({
    codexHome: fixture.codexHome,
    dryRun: true,
    compress: "zst",
    reportDir: reportsDir,
  });
  const gzResult = await runBackup({
    codexHome: fixture.codexHome,
    dryRun: true,
    compress: "gz",
    reportDir: reportsDir,
  });

  assert.equal(noneResult.status, "PASS");
  assert.equal(zstResult.status, "PASS");
  assert.equal(gzResult.status, "PASS");
  assert.match(noneResult.output_path, /\.tar$/);
  assert.match(zstResult.output_path, /\.tar\.zst$/);
  assert.match(gzResult.output_path, /\.tar\.gz$/);
});

test("verify should accept checksums paths with windows separators", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);
  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    manifestOnly: true,
    out: exportDir,
    reportDir: reportsDir,
  });
  assert.equal(backup.status, "PASS");

  const entries = await readChecksums(exportDir);
  const windowsStyleEntries = entries.map((item) => ({
    ...item,
    relativePath: item.relativePath.replaceAll("/", "\\"),
  }));
  await writeChecksums(exportDir, windowsStyleEntries);

  const verifyResult = await runVerify({
    input: exportDir,
    mode: "full",
    reportDir: reportsDir,
  });
  assert.equal(verifyResult.status, "PASS");
});

test("restore should remap and append index when package metadata uses backslash session path", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);
  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    threads: "active",
    manifestOnly: true,
    out: exportDir,
    reportDir: reportsDir,
  });
  assert.equal(backup.status, "PASS");

  const fileName = `rollout-2026-02-20T12-33-45-${fixture.activeId}.jsonl`;
  const oldPayloadRelative = `payload/sessions/2026/02/20/${fileName}`;
  const newPayloadRelative = `payload\\sessions\\2026\\02\\20\\${fileName}`;

  const manifestPath = path.join(exportDir, "manifest.json");
  const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
  let replaced = false;
  for (const item of manifest.files) {
    if (item.relative_path === oldPayloadRelative) {
      item.relative_path = newPayloadRelative;
      replaced = true;
    }
  }
  assert.equal(replaced, true);
  await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
  await replaceChecksumRelativePath(exportDir, oldPayloadRelative, newPayloadRelative);

  const restore = await runRestore({
    package: exportDir,
    targetCodexHome: fixture.codexHome,
    conflict: "skip",
    addOnly: true,
    postVerify: false,
    reportDir: reportsDir,
  });

  assert.equal(restore.status, "PASS");
  assert.ok(restore.actions.remapped_threads >= 1);
  assert.ok(restore.actions.index_appended >= 1);
});

test("restore should rewrite mixed-case session id in jsonl body", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);
  const exportDir = path.join(tempRoot, "exported");
  const reportsDir = path.join(tempRoot, "reports");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    threads: "active",
    manifestOnly: true,
    out: exportDir,
    reportDir: reportsDir,
  });
  assert.equal(backup.status, "PASS");

  const fileName = `rollout-2026-02-20T12-33-45-${fixture.activeId}.jsonl`;
  const sessionRelative = `payload/sessions/2026/02/20/${fileName}`;
  const sessionPath = path.join(exportDir, "payload", "sessions", "2026", "02", "20", fileName);
  const sourceUpper = fixture.activeId.toUpperCase();
  const raw = await fs.readFile(sessionPath, "utf8");
  await fs.writeFile(sessionPath, raw.replaceAll(fixture.activeId, sourceUpper), "utf8");
  await refreshChecksumForPath(exportDir, sessionRelative);

  const restore = await runRestore({
    package: exportDir,
    targetCodexHome: fixture.codexHome,
    conflict: "skip",
    addOnly: true,
    postVerify: false,
    reportDir: reportsDir,
  });

  assert.equal(restore.status, "PASS");
  assert.ok(restore.actions.remapped_threads >= 1);
  const imported = restore.imported_threads.find((item) => item.sourceId === fixture.activeId);
  assert.ok(imported?.targetRelative);
  assert.ok(imported?.targetId);
  const importedPath = path.join(fixture.codexHome, ...imported.targetRelative.split("/"));
  const importedRaw = await fs.readFile(importedPath, "utf8");
  assert.match(importedRaw, new RegExp(imported.targetId, "i"));
  assert.doesNotMatch(importedRaw, new RegExp(sourceUpper));
});

test("zst backup package should be verifiable when tar supports zstd", async (t) => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-sessions-test-"));
  const fixture = await createFixtureCodexHome(tempRoot);
  const reportsDir = path.join(tempRoot, "reports");
  const outPath = path.join(tempRoot, "archive.tar.zst");

  const backup = await runBackup({
    codexHome: fixture.codexHome,
    manifestOnly: false,
    compress: "zst",
    out: outPath,
    reportDir: reportsDir,
  });

  if (backup.status !== "PASS") {
    t.skip("当前环境 tar 不支持 zstd，跳过该用例");
    return;
  }

  const verify = await runVerify({
    input: outPath,
    mode: "full",
    reportDir: reportsDir,
  });

  assert.equal(verify.status, "PASS");
});
