import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

test("listModels 返回规范化后的模型列表", async () => {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("models/list", () => ({
    models: [
      { id: "gpt-5", name: "GPT-5", provider: "openai" },
      { model: "claude-sonnet-4-5", provider: "anthropic" },
      { id: "   " },
    ],
  }));

  const service = new WorkerService({
    rpc,
    projectPaths: ["/repo"],
    defaultProjectPath: "/repo",
    logger: {
      warn: () => {},
      error: () => {},
    },
  });

  await service.init();
  const models = await service.listModels();
  assert.ok(Array.isArray(models.data));
  assert.equal(models.data.length, 2);
  assert.equal(models.data[0].displayName, "openai/gpt-5");
  assert.equal(models.data[1].displayName, "anthropic/claude-sonnet-4-5");
});

test("archiveThread 成功后会清理本地缓存并允许重新 resume", async () => {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));

  rpc.onRequest("thread/start", ({ cwd }) => ({
    thread: {
      id: "thr_archive",
      preview: "",
      cwd,
      createdAt: 1,
      updatedAt: 1,
      modelProvider: "openai",
    },
  }));

  let resumeCount = 0;
  rpc.onRequest("thread/resume", ({ threadId }) => {
    resumeCount += 1;
    return {
      thread: {
        id: threadId,
        preview: "",
        cwd: "/repo",
        createdAt: 1,
        updatedAt: 2,
        modelProvider: "openai",
      },
    };
  });

  rpc.onRequest("thread/update", ({ archived }) => ({
    ok: archived === true,
  }));

  rpc.onRequest("turn/start", () => ({
    turn: {
      id: "turn_archive",
      status: "inProgress",
      items: [],
      error: null,
    },
  }));

  let deletedThreadId = null;
  const store = {
    deleteThread: (threadId) => {
      deletedThreadId = threadId;
    },
    replaceThreadEventsProjection: () => {},
    upsertThread: () => {},
    insertJob: () => {},
    updateJob: () => {},
    appendEvent: () => {},
  };

  const service = new WorkerService({
    rpc,
    store,
    projectPaths: ["/repo"],
    defaultProjectPath: "/repo",
    logger: {
      warn: () => {},
      error: () => {},
    },
  });

  await service.init();
  const thread = await service.createThread({ projectPath: "/repo" });
  const archive = await service.archiveThread(thread.threadId);

  assert.equal(archive.threadId, "thr_archive");
  assert.equal(archive.status, "archived");
  assert.equal(deletedThreadId, "thr_archive");

  await service.startTurn(thread.threadId, { text: "after archive" });
  assert.equal(resumeCount, 1);
});

test("listThreads 在 archived=true 时不写入活跃线程缓存", async () => {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/list", ({ archived }) => ({
    data: archived
      ? [
          {
            id: "thr_archived",
            preview: "archived",
            cwd: "/repo",
            createdAt: 1,
            updatedAt: 1,
            modelProvider: "openai",
          },
        ]
      : [],
    nextCursor: null,
  }));

  let upsertCount = 0;
  const store = {
    upsertThread: () => {
      upsertCount += 1;
    },
  };

  const service = new WorkerService({
    rpc,
    store,
    projectPaths: ["/repo"],
    defaultProjectPath: "/repo",
    logger: {
      warn: () => {},
      error: () => {},
    },
  });

  await service.init();
  const archived = await service.listThreads({ archived: true });

  assert.equal(archived.data.length, 1);
  assert.equal(archived.data[0].threadId, "thr_archived");
  assert.equal(upsertCount, 0);
});

test("unarchiveThread 支持回退到 thread/update", async () => {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/unarchive", () => {
    throw new Error("method not found");
  });

  let updateCallCount = 0;
  rpc.onRequest("thread/update", ({ archived }) => {
    updateCallCount += 1;
    return { ok: archived === false };
  });

  const service = new WorkerService({
    rpc,
    projectPaths: ["/repo"],
    defaultProjectPath: "/repo",
    logger: {
      warn: () => {},
      error: () => {},
    },
  });

  await service.init();
  const result = await service.unarchiveThread("thr_unarchive");

  assert.equal(result.threadId, "thr_unarchive");
  assert.equal(result.status, "active");
  assert.equal(updateCallCount, 1);
});
