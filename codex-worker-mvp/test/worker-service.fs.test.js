import test from "node:test";
import assert from "node:assert/strict";
import os from "node:os";
import path from "node:path";
import { promises as fs } from "node:fs";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

async function createFsService(workspacePath) {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/list", ({ archived }) => ({
    data: archived
      ? []
      : [
          {
            id: "thr_fs",
            preview: "",
            cwd: workspacePath,
            createdAt: 1,
            updatedAt: 1,
            modelProvider: "openai",
          },
        ],
    nextCursor: null,
  }));

  const service = new WorkerService({
    rpc,
    projectPaths: [workspacePath],
    defaultProjectPath: workspacePath,
    logger: {
      warn: () => {},
      error: () => {},
    },
  });

  await service.init();
  return service;
}

test("文件系统：roots/resolve/tree/file/search/write 全链路可用", async () => {
  const workspacePath = await fs.mkdtemp(path.join(os.tmpdir(), "cw-fs-"));
  const nestedDir = path.join(workspacePath, "src");
  const nestedFile = path.join(nestedDir, "demo.swift");
  const readmeFile = path.join(workspacePath, "README.md");

  await fs.mkdir(nestedDir, { recursive: true });
  await fs.writeFile(
    nestedFile,
    [
      "import Foundation",
      "",
      "struct Demo {",
      "    let value: String",
      "}",
    ].join("\n"),
    "utf8"
  );
  await fs.writeFile(readmeFile, "Codex worker mvp\nsearch text", "utf8");

  const service = await createFsService(workspacePath);

  const roots = await service.listThreadFsRoots("thr_fs");
  assert.ok(Array.isArray(roots.data));
  assert.ok(roots.data.length >= 1);

  const resolved = await service.resolveThreadFsReference("thr_fs", {
    ref: "src/demo.swift:4",
  });
  assert.equal(resolved.data.resolved, true);
  assert.equal(resolved.data.path, nestedFile);
  assert.equal(resolved.data.line, 4);

  const tree = await service.listThreadFsTree("thr_fs", {
    path: ".",
    cursor: 0,
    limit: 20,
  });
  assert.ok(Array.isArray(tree.data));
  assert.ok(tree.data.some((entry) => entry.name === "src"));
  assert.ok(tree.data.some((entry) => entry.name === "README.md"));

  const fileWindow = await service.getThreadFsFile("thr_fs", {
    path: "src/demo.swift",
    fromLine: 3,
    toLine: 4,
  });
  assert.equal(fileWindow.data.path, nestedFile);
  assert.equal(fileWindow.data.fromLine, 3);
  assert.equal(fileWindow.data.toLine, 4);
  assert.equal(fileWindow.data.lines.length, 2);
  assert.equal(fileWindow.data.lines[0].text, "struct Demo {");

  const stat = await service.getThreadFsStat("thr_fs", {
    path: "src/demo.swift",
  });
  assert.equal(stat.data.path, nestedFile);
  assert.equal(stat.data.isFile, true);
  assert.equal(typeof stat.data.etag, "string");

  const search = await service.searchThreadFs("thr_fs", {
    q: "search text",
    path: ".",
    cursor: 0,
    limit: 20,
  });
  assert.ok(Array.isArray(search.data));
  assert.ok(
    search.data.some((entry) => entry.path.endsWith("/README.md") && entry.snippet.includes("search text"))
  );

  const write = await service.writeThreadFsFile("thr_fs", {
    path: "src/demo.swift",
    content: "updated content\n",
    expectedEtag: stat.data.etag,
  });
  assert.equal(write.data.path, nestedFile);

  const changed = await fs.readFile(nestedFile, "utf8");
  assert.equal(changed, "updated content\n");
});

test("文件系统：写入不在允许根目录内的路径会被拒绝", async () => {
  const workspacePath = await fs.mkdtemp(path.join(os.tmpdir(), "cw-fs-"));
  const service = await createFsService(workspacePath);

  await assert.rejects(
    () => service.writeThreadFsFile("thr_fs", {
      path: "/etc/passwd",
      content: "nope",
    }),
    (error) => error?.code === "FS_PATH_FORBIDDEN"
  );
});
