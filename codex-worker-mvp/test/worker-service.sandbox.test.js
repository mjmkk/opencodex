import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

test("createThread 会把 sandbox/approvalPolicy 标准化为 kebab-case", async () => {
  const rpc = new FakeRpcClient();

  rpc.onRequest("initialize", () => ({}));

  let captured = null;
  rpc.onRequest("thread/start", (params) => {
    captured = params;
    return {
      thread: {
        id: "thr_sandbox",
        preview: "",
        cwd: params.cwd,
        createdAt: 1,
        updatedAt: 1,
        modelProvider: "openai",
      },
    };
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

  // camelCase 是历史兼容格式，当前应回退到默认值
  await service.createThread({
    projectPath: "/repo",
    sandbox: "readOnly",
    approvalPolicy: "unlessTrusted",
    model: "openai/gpt-5",
  });

  assert.ok(captured);
  assert.equal(captured.sandbox, "workspace-write");
  assert.equal(captured.approvalPolicy, "on-request");
  assert.equal(captured.model, "openai/gpt-5");

  // Test kebab-case input (legacy format, should be converted)
  captured = null;
  await service.createThread({
    projectPath: "/repo",
    sandbox: "read-only",
    approvalPolicy: "untrusted",
  });

  assert.ok(captured);
  assert.equal(captured.sandbox, "read-only");
  assert.equal(captured.approvalPolicy, "untrusted");

  // invalid sandbox should fall back to default.
  captured = null;
  await service.createThread({
    projectPath: "/repo",
    sandbox: "not-a-real-sandbox",
  });
  assert.ok(captured);
  assert.equal(captured.sandbox, "workspace-write");

  // 非候选目录也允许创建（不做 projectPath 白名单拦截）。
  captured = null;
  await service.createThread({
    projectPath: "/Users/Apple",
  });
  assert.ok(captured);
  assert.equal(captured.cwd, "/Users/Apple");
});

test("startTurn 支持覆盖 approvalPolicy/sandbox，并标准化输入", async () => {
  const rpc = new FakeRpcClient();

  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/start", (params) => ({
    thread: {
      id: "thr_turn_sandbox",
      preview: "",
      cwd: params.cwd,
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

  let capturedTurnStart = null;
  rpc.onRequest("turn/start", (params) => {
    capturedTurnStart = params;
    return {
      turn: {
        id: "turn_turn_sandbox",
        status: "inProgress",
        items: [],
        error: null,
      },
    };
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
  const thread = await service.createThread({ projectPath: "/repo" });

  await service.startTurn(thread.threadId, {
    text: "hello",
    approvalPolicy: "never",
    sandbox: "danger-full-access",
    model: "openai/gpt-5",
  });

  assert.ok(capturedTurnStart);
  assert.equal(capturedTurnStart.approvalPolicy, "never");
  assert.equal(capturedTurnStart.sandbox, "danger-full-access");
  assert.equal(capturedTurnStart.model, "openai/gpt-5");

  // 将第一次 turn 收敛为终态，避免并发保护拦截第二次 startTurn。
  rpc.emit("notification", {
    method: "turn/completed",
    params: {
      threadId: thread.threadId,
      turn: {
        id: "turn_turn_sandbox",
        status: "completed",
        items: [],
        error: null,
      },
    },
  });

  capturedTurnStart = null;
  await service.startTurn(thread.threadId, {
    text: "hello again",
    approvalPolicy: "bad-policy",
    sandbox: "bad-sandbox",
  });

  assert.ok(capturedTurnStart);
  assert.equal(capturedTurnStart.approvalPolicy, undefined);
  assert.equal(capturedTurnStart.sandbox, undefined);
});
