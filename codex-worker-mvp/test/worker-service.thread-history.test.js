import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

function createService({ threadReadHandler, store } = {}) {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/list", () => ({ data: [], nextCursor: null }));
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
  rpc.onRequest("thread/read", threadReadHandler ?? (() => ({ thread: { id: "thr_1", turns: [] } })));

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

  return { rpc, service };
}

test("listThreadEvents 优先使用 thread/read turns 构建回放事件", async () => {
  let fallbackCalled = 0;
  const fallbackStore = {
    upsertThread: () => {},
    listEventsByThread: () => {
      fallbackCalled += 1;
      return [
        {
          type: "error",
          ts: "2026-01-01T00:00:00.000Z",
          jobId: "from-sqlite",
          seq: 0,
          payload: { message: "should not happen" },
        },
      ];
    },
  };

  const { service } = createService({
    store: fallbackStore,
    threadReadHandler: () => ({
      thread: {
        id: "thr_1",
        turns: [
          {
            id: "turn_a",
            status: "completed",
            error: null,
            items: [
              {
                type: "userMessage",
                id: "user_a",
                content: [{ type: "text", text: "你好" }],
              },
              {
                type: "agentMessage",
                id: "assistant_a",
                text: "你好，我在。",
              },
            ],
          },
          {
            id: "turn_b",
            status: "inProgress",
            error: null,
            items: [],
          },
        ],
      },
    }),
  });

  await service.init();
  const page = await service.listThreadEvents("thr_1", { cursor: null, limit: 200 });
  const events = page.data;

  assert.ok(events.length > 0);
  assert.equal(typeof page.nextCursor, "number");
  assert.equal(typeof page.hasMore, "boolean");
  assert.equal(fallbackCalled, 0, "thread/read 成功时不应回退 SQLite");

  const userCompleted = events.find((event) => event.type === "item.completed" && event.payload?.item?.id === "user_a");
  const assistantCompleted = events.find(
    (event) => event.type === "item.completed" && event.payload?.item?.id === "assistant_a"
  );
  assert.ok(userCompleted, "应包含用户消息 completed 事件");
  assert.ok(assistantCompleted, "应包含助手消息 completed 事件");

  const doneEvent = events.find(
    (event) => event.type === "job.finished" && event.payload?.state === "DONE" && event.jobId.endsWith("_turn_a")
  );
  assert.ok(doneEvent, "completed turn 应映射为 DONE + job.finished");

  const runningState = events.find((event) => event.type === "job.state" && event.payload?.state === "RUNNING");
  assert.equal(runningState, undefined, "未知真实 jobId 的 inProgress turn 不应产生 RUNNING 状态");
});

test("listThreadEvents 在 thread/read 失败时回退 SQLite 缓存", async () => {
  let fallbackCalled = 0;
  const fallbackEvents = [
    {
      type: "item.completed",
      ts: "2026-01-01T00:00:00.000Z",
      jobId: "job_from_cache",
      seq: 0,
      payload: {
        item: {
          type: "agentMessage",
          id: "assistant_cache",
          text: "来自缓存",
        },
      },
    },
  ];
  const fallbackStore = {
    upsertThread: () => {},
    listEventsByThread: () => {
      fallbackCalled += 1;
      return fallbackEvents;
    },
  };

  const { service } = createService({
    store: fallbackStore,
    threadReadHandler: () => {
      throw new Error("thread/read down");
    },
  });

  await service.init();
  const page = await service.listThreadEvents("thr_1", { cursor: null, limit: 200 });
  const events = page.data;

  assert.equal(fallbackCalled, 1, "thread/read 失败时应回退 SQLite");
  assert.deepEqual(events, fallbackEvents);
});

test("listThreadEvents 支持 cursor 增量分页", async () => {
  let threadReadCallCount = 0;
  const { service } = createService({
    threadReadHandler: () => {
      threadReadCallCount += 1;
      return {
        thread: {
          id: "thr_1",
          turns: [
            {
              id: "turn_a",
              status: "completed",
              error: null,
              items: [
                { type: "userMessage", id: "u1", content: [{ type: "text", text: "A" }] },
                { type: "agentMessage", id: "a1", text: "B" },
              ],
            },
          ],
        },
      };
    },
  });
  await service.init();

  const firstPage = await service.listThreadEvents("thr_1", { cursor: -1, limit: 1 });
  assert.equal(firstPage.data.length, 1);
  assert.equal(firstPage.nextCursor, 0);
  assert.equal(firstPage.hasMore, true);

  const secondPage = await service.listThreadEvents("thr_1", {
    cursor: firstPage.nextCursor,
    limit: 10,
  });
  assert.ok(secondPage.data.length >= 1);
  assert.equal(secondPage.hasMore, false);
  assert.ok(secondPage.nextCursor >= firstPage.nextCursor);
  assert.equal(threadReadCallCount, 1, "同一线程连续分页应复用快照，避免重复 thread/read");
});
