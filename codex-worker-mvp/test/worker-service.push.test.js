import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

function setupService(pushNotifier) {
  const rpc = new FakeRpcClient();

  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/start", () => ({
    thread: {
      id: "thr_push",
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
      id: "turn_push_1",
      status: "inProgress",
      items: [],
      error: null,
    },
  }));
  rpc.onRequest("thread/list", () => ({ data: [], nextCursor: null }));
  rpc.onRequest("turn/interrupt", () => ({}));

  const service = new WorkerService({
    rpc,
    projectPaths: ["/repo"],
    defaultProjectPath: "/repo",
    eventRetention: 200,
    pushNotifier,
    logger: {
      warn: () => {},
      error: () => {},
    },
  });

  return { service, rpc };
}

test("审批与任务完成事件会触发推送通知", async () => {
  const calls = [];
  const pushNotifier = {
    async notify(input) {
      calls.push(input);
      return { invalidDeviceTokens: [] };
    },
  };
  const { service, rpc } = setupService(pushNotifier);
  await service.init();

  service.registerPushDevice({
    platform: "ios",
    deviceToken: "b".repeat(64),
    bundleId: "li.CodexWorkerApp",
    environment: "sandbox",
  });

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, { text: "hello push" });

  rpc.emit("request", {
    id: 501,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: thread.threadId,
      turnId: "turn_push_1",
      command: "npm test",
      cwd: "/repo",
      commandActions: [],
    },
  });

  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].envelope.type, "approval.required");
  assert.equal(calls[0].devices.length, 1);

  const approvalEvent = service
    .listEvents(job.jobId, null)
    .data.find((event) => event.type === "approval.required");
  assert.ok(approvalEvent);

  await service.approve(job.jobId, {
    approvalId: approvalEvent.payload.approvalId,
    decision: "accept",
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(calls.length, 2);
  assert.equal(calls[1].envelope.type, "approval.resolved");

  rpc.emit("notification", {
    method: "turn/completed",
    params: {
      threadId: thread.threadId,
      turn: {
        id: "turn_push_1",
        status: "completed",
        items: [],
        error: null,
      },
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(calls.length, 3);
  assert.equal(calls[2].envelope.type, "job.finished");
});

test("推送返回无效 token 时会自动移除，避免重复失败", async () => {
  const calls = [];
  const badToken = "c".repeat(64);
  const pushNotifier = {
    async notify(input) {
      calls.push(input);
      return { invalidDeviceTokens: [badToken] };
    },
  };
  const { service, rpc } = setupService(pushNotifier);
  await service.init();

  service.registerPushDevice({
    platform: "ios",
    deviceToken: badToken,
    bundleId: "li.CodexWorkerApp",
    environment: "sandbox",
  });

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, { text: "token cleanup" });

  rpc.emit("request", {
    id: 601,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: thread.threadId,
      turnId: "turn_push_1",
      command: "npm test",
      cwd: "/repo",
      commandActions: [],
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(calls.length, 1);

  const approvalEvent = service
    .listEvents(job.jobId, null)
    .data.find((event) => event.type === "approval.required");
  assert.ok(approvalEvent);

  await service.approve(job.jobId, {
    approvalId: approvalEvent.payload.approvalId,
    decision: "accept",
  });
  await new Promise((resolve) => setTimeout(resolve, 0));

  // 第二次事件（approval.resolved）不会再通知，因为 bad token 已被移除
  assert.equal(calls.length, 1);
});
