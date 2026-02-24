import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { exportThreadToPackage, importThreadFromPackageAsNew } from "../src/thread-transfer.js";

async function createCodexHomeFixture(tempRoot) {
  const codexHome = path.join(tempRoot, "codex-home");
  const threadId = "019c7953-404f-73b2-b291-1d5b834395a1";
  const sessionDir = path.join(codexHome, "sessions", "2026", "02", "20");
  await fs.mkdir(sessionDir, { recursive: true });
  await fs.mkdir(path.join(codexHome, "archived_sessions"), { recursive: true });

  const filePath = path.join(sessionDir, `rollout-2026-02-20T12-33-45-${threadId}.jsonl`);
  const lines = [
    JSON.stringify({
      timestamp: "2026-02-20T04:33:56.938Z",
      type: "session_meta",
      payload: {
        id: threadId,
        cwd: "/Users/Apple/Dev/OpenCodex",
      },
    }),
    JSON.stringify({
      timestamp: "2026-02-20T04:33:58.000Z",
      type: "response_item",
      payload: {
        type: "message",
        role: "user",
        content: [{ type: "input_text", text: "导出线程" }],
      },
    }),
  ];
  await fs.writeFile(filePath, `${lines.join("\n")}\n`, "utf8");
  await fs.writeFile(
    path.join(codexHome, "session_index.jsonl"),
    `${JSON.stringify({ id: threadId, thread_name: "thread-export-test", updated_at: "2026-02-20T04:34:00.000Z" })}\n`,
    "utf8",
  );

  return { codexHome, threadId };
}

test("thread-transfer: 导出指定线程并导入为新线程", async () => {
  const tempRoot = await fs.mkdtemp(path.join(os.tmpdir(), "codex-thread-transfer-"));
  const { codexHome, threadId } = await createCodexHomeFixture(tempRoot);
  const exportDir = path.join(tempRoot, "exports");

  const exported = await exportThreadToPackage({
    codexHome,
    threadId,
    exportDir,
  });

  assert.equal(exported.sourceThreadId, threadId);
  assert.ok(exported.packagePath.endsWith(".json"));

  const imported = await importThreadFromPackageAsNew({
    codexHome,
    packagePath: exported.packagePath,
  });

  assert.notEqual(imported.targetThreadId, threadId);
  assert.ok(imported.targetRelativePath.startsWith("sessions/"));

  const importedFilePath = path.join(codexHome, imported.targetRelativePath);
  const importedRaw = await fs.readFile(importedFilePath, "utf8");
  assert.match(importedRaw, new RegExp(imported.targetThreadId));
  assert.doesNotMatch(importedRaw, new RegExp(threadId));

  const indexRaw = await fs.readFile(path.join(codexHome, "session_index.jsonl"), "utf8");
  assert.match(indexRaw, new RegExp(imported.targetThreadId));
});

