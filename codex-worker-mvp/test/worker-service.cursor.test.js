import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

function makeServiceWithRetention(retention) {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/start", () => ({
    thread: {
      id: "thr_1",
      preview: "",
      cwd: "/repo",
      createdAt: 1,
      updatedAt: 1,
      modelProvider: "openai",
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
  rpc.onRequest("turn/start", () => ({
    turn: {
      id: "turn_1",
      status: "inProgress",
      items: [],
      error: null,
    },
  }));
  rpc.onRequest("thread/list", () => ({ data: [], nextCursor: null }));

  const service = new WorkerService({
    rpc,
    projectPaths: ["/repo"],
    defaultProjectPath: "/repo",
    eventRetention: retention,
    logger: {
      warn: () => {},
      error: () => {},
    },
  });

  return { service, rpc };
}

test("cursor 过期会抛出 409", async () => {
  const { service, rpc } = makeServiceWithRetention(5);
  await service.init();

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, { text: "run" });

  for (let i = 0; i < 10; i += 1) {
    rpc.emit("notification", {
      method: "item/agentMessage/delta",
      params: {
        threadId: thread.threadId,
        turnId: "turn_1",
        itemId: "msg_1",
        delta: `chunk-${i}`,
      },
    });
  }

  assert.throws(
    () => service.listEvents(job.jobId, 0),
    (error) => error.code === "CURSOR_EXPIRED" && error.status === 409
  );

  const latest = service.listEvents(job.jobId, null);
  assert.ok(latest.data.length > 0);
  assert.ok(latest.firstSeq > 0, "事件被裁剪后 firstSeq 应前移");
});
