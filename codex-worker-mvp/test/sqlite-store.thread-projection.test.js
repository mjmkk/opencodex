import test from "node:test";
import assert from "node:assert/strict";

import { SqliteStore } from "../src/sqlite-store.js";

function makeStore() {
  const store = new SqliteStore({
    dbPath: ":memory:",
    logger: {
      warn: () => {},
      error: () => {},
    },
    eventPageLimit: 1000,
  });
  store.init();
  return store;
}

test("线程事件投影支持按 cursor 分页查询", () => {
  const store = makeStore();
  const threadId = "thr_projection_page";
  store.replaceThreadEventsProjection(threadId, [
    {
      type: "item.completed",
      ts: "2026-02-18T00:00:00.000Z",
      jobId: "job_1",
      seq: 0,
      payload: { itemId: "item_0" },
    },
    {
      type: "item.completed",
      ts: "2026-02-18T00:00:01.000Z",
      jobId: "job_1",
      seq: 1,
      payload: { itemId: "item_1" },
    },
    {
      type: "job.finished",
      ts: "2026-02-18T00:00:02.000Z",
      jobId: "job_1",
      seq: 2,
      payload: { state: "DONE" },
    },
  ]);

  const first = store.listThreadEventsProjectionPage(threadId, -1, 2);
  assert.equal(first.total, 3);
  assert.equal(first.data.length, 2);
  assert.equal(first.nextCursor, 1);
  assert.equal(first.hasMore, true);

  const second = store.listThreadEventsProjectionPage(threadId, first.nextCursor, 2);
  assert.equal(second.total, 3);
  assert.equal(second.data.length, 1);
  assert.equal(second.nextCursor, 2);
  assert.equal(second.hasMore, false);
  assert.equal(second.data[0].type, "job.finished");

  const tail = store.listThreadEventsProjectionPage(threadId, second.nextCursor, 2);
  assert.equal(tail.total, 3);
  assert.equal(tail.data.length, 0);
  assert.equal(tail.nextCursor, 2);
  assert.equal(tail.hasMore, false);

  store.close();
});

test("线程事件投影 replace 为全量覆盖写入", () => {
  const store = makeStore();
  const threadId = "thr_projection_replace";

  store.replaceThreadEventsProjection(threadId, [
    {
      type: "item.completed",
      ts: "2026-02-18T00:00:00.000Z",
      jobId: "job_old",
      seq: 0,
      payload: { text: "old" },
    },
    {
      type: "job.finished",
      ts: "2026-02-18T00:00:01.000Z",
      jobId: "job_old",
      seq: 1,
      payload: { state: "DONE" },
    },
  ]);

  store.replaceThreadEventsProjection(threadId, [
    {
      type: "item.completed",
      ts: "2026-02-18T01:00:00.000Z",
      jobId: "job_new",
      seq: 0,
      payload: { text: "new" },
    },
  ]);

  const page = store.listThreadEventsProjectionPage(threadId, -1, 10);
  assert.equal(page.total, 1);
  assert.equal(page.data.length, 1);
  assert.equal(page.data[0].jobId, "job_new");
  assert.equal(page.data[0].payload?.text, "new");
  assert.equal(page.hasMore, false);

  store.close();
});
