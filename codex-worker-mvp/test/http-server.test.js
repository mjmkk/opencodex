import test from "node:test";
import assert from "node:assert/strict";
import { WebSocket } from "ws";

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
  rpc.onRequest("thread/list", ({ archived }) => ({
    data: archived
      ? [
          {
            id: "thr_archived",
            preview: "已归档会话",
            cwd: "/repo-archived",
            createdAt: 1,
            updatedAt: 2,
            modelProvider: "openai",
          },
        ]
      : [
          {
            id: "thr_http",
            preview: "活跃会话",
            cwd: "/repo",
            createdAt: 1,
            updatedAt: 2,
            modelProvider: "openai",
          },
        ],
    nextCursor: null,
  }));
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
  rpc.onRequest("thread/unarchive", () => ({ ok: true }));

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

  const archivedThreadsRes = await fetch(`${base}/v1/threads?archived=true`, {
    headers: {
      Authorization: "Bearer token123",
      Accept: "application/json",
    },
  });
  assert.equal(archivedThreadsRes.status, 200);
  const archivedThreadsPayload = await archivedThreadsRes.json();
  assert.ok(Array.isArray(archivedThreadsPayload.data));
  assert.equal(archivedThreadsPayload.data.length, 1);
  assert.equal(archivedThreadsPayload.data[0].threadId, "thr_archived");

  const unarchiveRes = await fetch(`${base}/v1/threads/thr_archived/unarchive`, {
    method: "POST",
    headers,
  });
  assert.equal(unarchiveRes.status, 200);
  const unarchivePayload = await unarchiveRes.json();
  assert.equal(unarchivePayload.threadId, "thr_archived");
  assert.equal(unarchivePayload.status, "active");
});

test("HTTP 线程导出/导入接口", async (t) => {
  const calls = {
    export: null,
    import: null,
  };

  const service = {
    exportThread: async (threadId, payload) => {
      calls.export = { threadId, payload };
      return {
        exportId: "texp_123",
        packagePath: "/tmp/codex-thread-exports/texp_123.json",
      };
    },
    importThreadAsNew: async (payload) => {
      calls.import = payload;
      return {
        sourceThreadId: "thr_source",
        targetThreadId: "thr_target",
        packagePath: payload.packagePath,
        thread: {
          threadId: "thr_target",
          preview: "导入线程",
          cwd: "/repo",
          createdAt: 1,
          updatedAt: 2,
          modelProvider: "openai",
          pendingApprovalCount: 0,
        },
      };
    },
  };

  const server = createHttpServer({
    service,
    authToken: "token123",
    logger: {
      error: () => {},
    },
  });

  const address = await server.listen(0, "127.0.0.1");
  const base = `http://127.0.0.1:${address.port}`;

  t.after(async () => {
    await server.close();
  });

  const headers = {
    Authorization: "Bearer token123",
    "Content-Type": "application/json",
  };

  const exportRes = await fetch(`${base}/v1/threads/thr_source/export`, {
    method: "POST",
    headers,
    body: JSON.stringify({ exportDir: "/tmp/codex-thread-exports" }),
  });
  assert.equal(exportRes.status, 200);
  const exportPayload = await exportRes.json();
  assert.equal(exportPayload.export.exportId, "texp_123");
  assert.equal(calls.export.threadId, "thr_source");
  assert.equal(calls.export.payload.exportDir, "/tmp/codex-thread-exports");

  const importRes = await fetch(`${base}/v1/threads/import`, {
    method: "POST",
    headers,
    body: JSON.stringify({ packagePath: "/tmp/codex-thread-exports/texp_123.json" }),
  });
  assert.equal(importRes.status, 201);
  const importPayload = await importRes.json();
  assert.equal(importPayload.import.targetThreadId, "thr_target");
  assert.equal(importPayload.thread.threadId, "thr_target");
  assert.equal(calls.import.packagePath, "/tmp/codex-thread-exports/texp_123.json");
});

test("HTTP 终端接口", async (t) => {
  const calls = {
    getThreadTerminal: null,
    openThreadTerminal: null,
    resizeTerminal: null,
    closeTerminal: null,
  };

  const service = {
    getThreadTerminal: (threadId) => {
      calls.getThreadTerminal = threadId;
      return {
        session: null,
      };
    },
    openThreadTerminal: async (threadId, payload) => {
      calls.openThreadTerminal = { threadId, payload };
      return {
        reused: false,
        session: {
          sessionId: "term_123",
          threadId,
          cwd: "/repo",
          status: "running",
          nextSeq: 0,
        },
      };
    },
    resizeTerminal: (sessionId, payload) => {
      calls.resizeTerminal = { sessionId, payload };
      return {
        session: {
          sessionId,
          cols: payload.cols,
          rows: payload.rows,
        },
      };
    },
    closeTerminal: (sessionId, payload) => {
      calls.closeTerminal = { sessionId, payload };
      return {
        session: {
          sessionId,
          status: "exited",
        },
      };
    },
  };

  const server = createHttpServer({
    service,
    authToken: "token123",
    logger: {
      error: () => {},
    },
  });

  const address = await server.listen(0, "127.0.0.1");
  const base = `http://127.0.0.1:${address.port}`;
  t.after(async () => {
    await server.close();
  });

  const headers = {
    Authorization: "Bearer token123",
    "Content-Type": "application/json",
  };

  const statusRes = await fetch(`${base}/v1/threads/thr_terminal/terminal`, {
    headers,
  });
  assert.equal(statusRes.status, 200);
  const statusPayload = await statusRes.json();
  assert.equal(statusPayload.session, null);
  assert.equal(calls.getThreadTerminal, "thr_terminal");

  const openRes = await fetch(`${base}/v1/threads/thr_terminal/terminal/open`, {
    method: "POST",
    headers,
    body: JSON.stringify({ cols: 120, rows: 40 }),
  });
  assert.equal(openRes.status, 200);
  const openPayload = await openRes.json();
  assert.equal(openPayload.session.sessionId, "term_123");
  assert.equal(openPayload.wsPath, "/v1/terminals/term_123/stream");
  assert.equal(calls.openThreadTerminal.threadId, "thr_terminal");
  assert.equal(calls.openThreadTerminal.payload.cols, 120);

  const resizeRes = await fetch(`${base}/v1/terminals/term_123/resize`, {
    method: "POST",
    headers,
    body: JSON.stringify({ cols: 80, rows: 24 }),
  });
  assert.equal(resizeRes.status, 200);
  const resizePayload = await resizeRes.json();
  assert.equal(resizePayload.session.cols, 80);
  assert.equal(calls.resizeTerminal.sessionId, "term_123");

  const closeRes = await fetch(`${base}/v1/terminals/term_123/close`, {
    method: "POST",
    headers,
    body: JSON.stringify({ reason: "manual_close" }),
  });
  assert.equal(closeRes.status, 200);
  const closePayload = await closeRes.json();
  assert.equal(closePayload.session.status, "exited");
  assert.equal(calls.closeTerminal.sessionId, "term_123");
});

test("WebSocket 终端流：ready/ping/input/resize/detach", async (t) => {
  const calls = {
    attach: null,
    input: [],
    resize: [],
    detach: [],
  };
  let pushEvent = null;

  const service = {
    attachTerminalClient: (sessionId, clientId, params) => {
      calls.attach = { sessionId, clientId, fromSeq: params.fromSeq };
      pushEvent = params.onEvent;
      return {
        session: {
          sessionId,
          threadId: "thr_ws",
          cwd: "/repo",
          nextSeq: 3,
        },
        replay: [{ type: "output", seq: 2, data: "history\n" }],
      };
    },
    writeTerminalInput: (sessionId, data) => {
      calls.input.push({ sessionId, data });
    },
    resizeTerminal: (sessionId, payload) => {
      calls.resize.push({ sessionId, payload });
      return {
        session: {
          sessionId,
          cols: payload.cols,
          rows: payload.rows,
        },
      };
    },
    detachTerminalClient: (sessionId, clientId) => {
      calls.detach.push({ sessionId, clientId });
    },
  };

  const server = createHttpServer({
    service,
    authToken: "token123",
    logger: {
      error: () => {},
    },
  });
  const address = await server.listen(0, "127.0.0.1");
  const wsUrl = `ws://127.0.0.1:${address.port}/v1/terminals/term_ws/stream?fromSeq=1`;

  t.after(async () => {
    await server.close();
  });

  const messages = [];
  const ws = new WebSocket(wsUrl, {
    headers: {
      Authorization: "Bearer token123",
    },
  });
  t.after(() => {
    ws.terminate();
  });

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("websocket test timeout")), 2000);
    ws.on("message", (raw) => {
      const message = JSON.parse(raw.toString("utf8"));
      messages.push(message);

      if (message.type === "ready") {
        ws.send(JSON.stringify({ type: "ping", clientTs: "ts_1" }));
        ws.send(JSON.stringify({ type: "input", data: "echo hi\n" }));
        ws.send(JSON.stringify({ type: "resize", cols: 120, rows: 40 }));
        pushEvent?.({ type: "output", seq: 3, data: "live\n" });
        ws.send(JSON.stringify({ type: "detach" }));
      }
      if (message.type === "pong") {
        // no-op
      }
      if (message.type === "output" && message.seq === 3) {
        // live event already received, wait for close
      }
    });
    ws.on("close", () => {
      clearTimeout(timer);
      resolve();
    });
    ws.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });

  assert.equal(calls.attach.sessionId, "term_ws");
  assert.equal(calls.attach.fromSeq, 1);
  assert.equal(calls.input.length, 1);
  assert.equal(calls.input[0].data, "echo hi\n");
  assert.equal(calls.resize.length, 1);
  assert.equal(calls.resize[0].payload.cols, 120);
  assert.equal(calls.detach.length >= 1, true);

  assert.ok(messages.some((message) => message.type === "ready"));
  assert.ok(messages.some((message) => message.type === "output" && message.seq === 2));
  assert.ok(messages.some((message) => message.type === "output" && message.seq === 3));
  assert.ok(messages.some((message) => message.type === "pong" && message.clientTs === "ts_1"));
});
