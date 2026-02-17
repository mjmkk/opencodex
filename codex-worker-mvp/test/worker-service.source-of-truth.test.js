import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

function makeService(store) {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/start", () => ({
    thread: {
      id: "thr_truth",
      preview: "",
      cwd: "/repo",
      createdAt: 1,
      updatedAt: 1,
      modelProvider: "openai",
    },
  }));
  rpc.onRequest("turn/start", () => ({
    turn: {
      id: "turn_truth",
      status: "inProgress",
      items: [],
      error: null,
    },
  }));
  rpc.onRequest("thread/resume", ({ threadId }) => ({
    thread: {
      id: threadId,
      preview: "",
      cwd: "/repo",
      createdAt: 1,
      updatedAt: 1,
      modelProvider: "openai",
    },
  }));

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

  return { service };
}

test("getJob/listEvents 不读取 SQLite 缓存作为权威数据", async () => {
  let cachedReadCount = 0;
  const store = {
    getJob: () => {
      cachedReadCount += 1;
      return {
        jobId: "job_from_cache",
        threadId: "thr_truth",
        state: "DONE",
      };
    },
    listEvents: () => {
      cachedReadCount += 1;
      return {
        data: [{ type: "job.finished", seq: 999 }],
        nextCursor: 999,
      };
    },
    insertJob: () => {},
    updateJob: () => {},
    appendEvent: () => {},
    upsertThread: () => {},
  };

  const { service } = makeService(store);
  await service.init();
  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, { text: "hello" });

  const snapshot = service.getJob(job.jobId);
  assert.equal(snapshot.jobId, job.jobId);

  const events = service.listEvents(job.jobId, null);
  assert.ok(Array.isArray(events.data));
  assert.equal(cachedReadCount, 0, "运行时读路径不应访问 SQLite 缓存");
});

test("缓存中存在任务也不能替代内存权威状态", async () => {
  const store = {
    getJob: () => ({
      jobId: "job_cached_only",
      threadId: "thr_cached_only",
      state: "DONE",
    }),
    listEvents: () => ({
      data: [{ type: "job.finished", seq: 1 }],
      nextCursor: 1,
    }),
  };

  const { service } = makeService(store);
  await service.init();

  assert.throws(
    () => service.getJob("job_cached_only"),
    (error) => error.code === "JOB_NOT_FOUND" && error.status === 404
  );
  assert.throws(
    () => service.listEvents("job_cached_only", null),
    (error) => error.code === "JOB_NOT_FOUND" && error.status === 404
  );
});
