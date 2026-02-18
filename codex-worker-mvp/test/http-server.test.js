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
  rpc.onRequest("models/list", () => ({
    models: [
      { id: "gpt-5", name: "GPT-5", provider: "openai" },
      { id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", provider: "anthropic" },
    ],
  }));
  rpc.onRequest("thread/read", ({ threadId }) => ({
    thread: {
      id: threadId,
      preview: "",
      cwd: "/repo",
      createdAt: 1,
      updatedAt: 1,
      modelProvider: "openai",
      turns: [
        {
          id: "turn_history_1",
          status: "completed",
          error: null,
          items: [
            {
              type: "userMessage",
              id: "user_1",
              content: [{ type: "text", text: "历史消息" }],
            },
            {
              type: "agentMessage",
              id: "assistant_1",
              text: "已恢复上下文",
            },
          ],
        },
      ],
    },
  }));
  rpc.onRequest("turn/start", () => ({
    turn: {
      id: "turn_http",
      status: "inProgress",
      items: [],
      error: null,
    },
  }));
  rpc.onRequest("thread/archive", () => ({ ok: true }));

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

  const modelsRes = await fetch(`${base}/v1/models`, {
    headers: {
      Authorization: "Bearer token123",
      Accept: "application/json",
    },
  });
  assert.equal(modelsRes.status, 200);
  const modelsPayload = await modelsRes.json();
  assert.ok(Array.isArray(modelsPayload.data));
  assert.equal(modelsPayload.data.length, 2);

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

  const threadEventsRes = await fetch(`${base}/v1/threads/thr_http/events`, {
    headers: {
      Authorization: "Bearer token123",
      Accept: "application/json",
    },
  });
  assert.equal(threadEventsRes.status, 200);
  const threadEventsPayload = await threadEventsRes.json();
  assert.ok(Array.isArray(threadEventsPayload.data));
  assert.equal(typeof threadEventsPayload.nextCursor, "number");
  assert.equal(typeof threadEventsPayload.hasMore, "boolean");
  assert.ok(
    threadEventsPayload.data.some((event) => event.type === "item.completed"),
    "线程历史应该包含 item.completed 事件"
  );

  const incrementalRes = await fetch(
    `${base}/v1/threads/thr_http/events?cursor=${threadEventsPayload.nextCursor}&limit=10`,
    {
      headers: {
        Authorization: "Bearer token123",
        Accept: "application/json",
      },
    }
  );
  assert.equal(incrementalRes.status, 200);
  const incrementalPayload = await incrementalRes.json();
  assert.ok(Array.isArray(incrementalPayload.data));
  assert.equal(incrementalPayload.data.length, 0);
  assert.equal(incrementalPayload.hasMore, false);

  const unauthorized = await fetch(`${base}/v1/threads`, {
    headers: {
      Accept: "application/json",
    },
  });
  assert.equal(unauthorized.status, 401);

  const pushRegister = await fetch(`${base}/v1/push/devices/register`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      platform: "ios",
      deviceToken: "a".repeat(64),
      bundleId: "li.CodexWorkerApp",
      environment: "sandbox",
    }),
  });
  assert.equal(pushRegister.status, 200);
  const pushRegisterPayload = await pushRegister.json();
  assert.equal(pushRegisterPayload.status, "registered");
  assert.equal(pushRegisterPayload.device.deviceToken, "a".repeat(64));

  const pushUnregister = await fetch(`${base}/v1/push/devices/unregister`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      deviceToken: "a".repeat(64),
    }),
  });
  assert.equal(pushUnregister.status, 200);
  const pushUnregisterPayload = await pushUnregister.json();
  assert.equal(pushUnregisterPayload.status, "unregistered");

  const archiveRes = await fetch(`${base}/v1/threads/thr_http/archive`, {
    method: "POST",
    headers,
  });
  assert.equal(archiveRes.status, 200);
  const archivePayload = await archiveRes.json();
  assert.equal(archivePayload.threadId, "thr_http");
  assert.equal(archivePayload.status, "archived");
});
