import test from "node:test";
import assert from "node:assert/strict";

import { createHttpServer } from "../src/http-server.js";
import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

async function setup() {
  const rpc = new FakeRpcClient();

  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/start", ({ cwd }) => ({
    thread: {
      id: "thr_http",
      preview: "",
      cwd,
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
  rpc.onRequest("thread/list", () => ({ data: [], nextCursor: null }));
  rpc.onRequest("turn/start", () => ({
    turn: {
      id: "turn_http",
      status: "inProgress",
      items: [],
      error: null,
    },
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

  const server = createHttpServer({
    service,
    authToken: "token123",
    logger: {
      error: () => {},
    },
  });

  const address = await server.listen(0, "127.0.0.1");
  const base = `http://127.0.0.1:${address.port}`;

  return { rpc, service, server, base };
}

test("HTTP 最小流程：创建线程 -> 发起任务 -> 查询事件", async (t) => {
  const { base, server } = await setup();
  t.after(async () => {
    await server.close();
  });

  const headers = {
    Authorization: "Bearer token123",
    "Content-Type": "application/json",
  };

  const threadRes = await fetch(`${base}/v1/threads`, {
    method: "POST",
    headers,
    body: JSON.stringify({ projectPath: "/repo" }),
  });
  assert.equal(threadRes.status, 201);
  const threadPayload = await threadRes.json();
  assert.equal(threadPayload.thread.threadId, "thr_http");

  const turnRes = await fetch(`${base}/v1/threads/thr_http/turns`, {
    method: "POST",
    headers,
    body: JSON.stringify({ text: "hello" }),
  });
  assert.equal(turnRes.status, 202);
  const jobPayload = await turnRes.json();
  assert.ok(jobPayload.jobId);

  const eventsRes = await fetch(`${base}/v1/jobs/${jobPayload.jobId}/events`, {
    headers: {
      Authorization: "Bearer token123",
      Accept: "application/json",
    },
  });
  assert.equal(eventsRes.status, 200);
  const eventsPayload = await eventsRes.json();
  assert.ok(Array.isArray(eventsPayload.data));
  assert.ok(eventsPayload.data.length >= 2);

  const unauthorized = await fetch(`${base}/v1/threads`, {
    headers: {
      Accept: "application/json",
    },
  });
  assert.equal(unauthorized.status, 401);
});
