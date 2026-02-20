import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

function setupService() {
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
  rpc.onRequest("turn/interrupt", () => ({}));
  rpc.onRequest("thread/list", () => ({ data: [], nextCursor: null }));

  const service = new WorkerService({
    rpc,
    projectPaths: ["/repo"],
    defaultProjectPath: "/repo",
    eventRetention: 200,
    logger: {
      warn: () => {},
      error: () => {},
    },
  });

  return { service, rpc };
}

test("审批请求可被回传并保持幂等", async () => {
  const { service, rpc } = setupService();
  await service.init();

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, {
    text: "请执行测试",
  });

  rpc.emit("request", {
    id: 99,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: thread.threadId,
      turnId: "turn_1",
      itemId: "item_cmd_1",
      command: "npm test",
      cwd: "/repo",
      commandActions: [],
    },
  });

  const snapshotBeforeApproval = service.getJob(job.jobId);
  assert.equal(snapshotBeforeApproval.state, "WAITING_APPROVAL");
  assert.equal(snapshotBeforeApproval.pendingApprovalCount, 1);

  const approvalEvent = service
    .listEvents(job.jobId, null)
    .data.find((event) => event.type === "approval.required");
  assert.ok(approvalEvent, "应该产生 approval.required 事件");

  const first = await service.approve(job.jobId, {
    approvalId: approvalEvent.payload.approvalId,
    decision: "accept",
  });

  assert.equal(first.status, "submitted");
  assert.equal(rpc.responses.length, 1);
  assert.deepEqual(rpc.responses[0], {
    id: 99,
    result: {
      decision: "accept",
    },
  });

  const second = await service.approve(job.jobId, {
    approvalId: approvalEvent.payload.approvalId,
    decision: "accept",
  });

  assert.equal(second.status, "already_submitted");
  assert.equal(rpc.responses.length, 1, "重复提交不应再次写回 RPC");
});

test("审批接口兼容 snake_case 请求体字段", async () => {
  const { service, rpc } = setupService();
  await service.init();

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, {
    text: "请执行测试",
  });

  rpc.emit("request", {
    id: 109,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: thread.threadId,
      turnId: "turn_1",
      itemId: "item_cmd_2",
      command: "npm test",
      cwd: "/repo",
      commandActions: [],
    },
  });

  const approvalEvent = service
    .listEvents(job.jobId, null)
    .data.find((event) => event.type === "approval.required");
  assert.ok(approvalEvent, "应该产生 approval.required 事件");

  const result = await service.approve(job.jobId, {
    approval_id: approvalEvent.payload.approvalId,
    decision: "accept",
    exec_policy_amendment: ["echo", "safe-run"],
  });

  assert.equal(result.status, "submitted");
  assert.equal(rpc.responses.length, 1);
  assert.deepEqual(rpc.responses[0], {
    id: 109,
    result: {
      decision: "accept",
    },
  });
});

test("turn/completed 事件会收敛成 DONE", async () => {
  const { service, rpc } = setupService();
  await service.init();

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, {
    text: "hello",
  });

  rpc.emit("notification", {
    method: "turn/completed",
    params: {
      threadId: thread.threadId,
      turn: {
        id: "turn_1",
        status: "completed",
        items: [],
        error: null,
      },
    },
  });

  const snapshot = service.getJob(job.jobId);
  assert.equal(snapshot.state, "DONE");

  const finishedEvent = service
    .listEvents(job.jobId, null)
    .data.find((event) => event.type === "job.finished");
  assert.ok(finishedEvent, "终态后应有 job.finished 事件");
  assert.equal(finishedEvent.payload.state, "DONE");
});

test("拒绝审批时可携带拒绝理由并写入事件", async () => {
  const { service, rpc } = setupService();
  await service.init();

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, {
    text: "请执行测试",
  });

  rpc.emit("request", {
    id: 209,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: thread.threadId,
      turnId: "turn_1",
      itemId: "item_cmd_3",
      command: "npm test",
      cwd: "/repo",
      commandActions: [],
    },
  });

  const approvalEvent = service
    .listEvents(job.jobId, null)
    .data.find((event) => event.type === "approval.required");
  assert.ok(approvalEvent, "应该产生 approval.required 事件");

  const result = await service.approve(job.jobId, {
    approval_id: approvalEvent.payload.approvalId,
    decision: "decline",
    decline_reason: "当前分支未完成代码审查，禁止执行",
  });

  assert.equal(result.status, "submitted");
  assert.equal(rpc.responses.length, 1);
  assert.deepEqual(rpc.responses[0], {
    id: 209,
    result: {
      decision: "decline",
    },
  });

  const resolvedEvent = service
    .listEvents(job.jobId, null)
    .data.filter((event) => event.type === "approval.resolved")
    .at(-1);
  assert.ok(resolvedEvent, "应该产生 approval.resolved 事件");
  assert.equal(resolvedEvent.payload.decision, "decline");
  assert.equal(resolvedEvent.payload.declineReason, "当前分支未完成代码审查，禁止执行");
});

test("重复审批请求会去重，并且审批结果写回最新 requestId", async () => {
  const { service, rpc } = setupService();
  await service.init();

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, {
    text: "请执行测试",
  });

  const payload = {
    threadId: thread.threadId,
    turnId: "turn_1",
    itemId: "item_cmd_dup",
    command: "npm test",
    cwd: "/repo",
    commandActions: [],
  };

  rpc.emit("request", {
    id: 601,
    method: "item/commandExecution/requestApproval",
    params: payload,
  });
  rpc.emit("request", {
    id: 602,
    method: "item/commandExecution/requestApproval",
    params: payload,
  });

  const requiredEvents = service
    .listEvents(job.jobId, null)
    .data.filter((event) => event.type === "approval.required");
  assert.equal(requiredEvents.length, 1, "重复请求不应生成新的 approval.required");

  const approvalId = requiredEvents[0]?.payload?.approvalId;
  assert.ok(approvalId, "应包含 approvalId");

  const submitted = await service.approve(job.jobId, {
    approvalId,
    decision: "accept",
  });
  assert.equal(submitted.status, "submitted");
  assert.equal(rpc.responses.length, 1);
  assert.equal(rpc.responses[0].id, 602, "应写回最新 requestId");

  rpc.emit("request", {
    id: 603,
    method: "item/commandExecution/requestApproval",
    params: payload,
  });
  assert.equal(rpc.responses.length, 2);
  assert.deepEqual(rpc.responses[1], {
    id: 603,
    result: {
      decision: "accept",
    },
  });
});

test("审批请求缺少 turnId/itemId 时不做指纹去重，避免误合并不同审批", async () => {
  const { service, rpc } = setupService();
  rpc.onRequest("thread/list", () => ({
    data: [
      {
        id: "thr_1",
        preview: "",
        cwd: "/repo",
        createdAt: 1,
        updatedAt: 1,
        modelProvider: "openai",
      },
    ],
    nextCursor: null,
  }));
  rpc.onRequest("thread/create", () => ({
    thread_id: "thr_1",
    created_at: "2026-01-01T00:00:00.000Z",
  }));
  rpc.onRequest("turn/create", () => ({
    turn_id: "turn_1",
    thread_id: "thr_1",
    job_id: "job_1",
  }));

  await service.init();

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, {
    text: "请执行测试",
  });

  rpc.emit("request", {
    id: 701,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: thread.threadId,
      command: "npm test",
      cwd: "/repo",
      commandActions: [],
    },
  });
  rpc.emit("request", {
    id: 702,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: thread.threadId,
      command: "npm test --watch",
      cwd: "/repo",
      commandActions: [],
    },
  });

  const requiredEvents = service
    .listEvents(job.jobId, null)
    .data.filter((event) => event.type === "approval.required");
  assert.equal(requiredEvents.length, 2, "缺少关键标识时不应按指纹去重");
});

test("线程列表返回 pendingApprovalCount，便于前端显示审批标记", async () => {
  const { service, rpc } = setupService();
  rpc.onRequest("thread/list", () => ({
    data: [
      {
        id: "thr_1",
        preview: "",
        cwd: "/repo",
        createdAt: 1,
        updatedAt: 1,
        modelProvider: "openai",
      },
    ],
    nextCursor: null,
  }));

  await service.init();

  const thread = await service.createThread({ projectPath: "/repo" });
  const job = await service.startTurn(thread.threadId, {
    text: "请执行测试",
  });

  rpc.emit("request", {
    id: 309,
    method: "item/commandExecution/requestApproval",
    params: {
      threadId: thread.threadId,
      turnId: "turn_1",
      itemId: "item_cmd_4",
      command: "npm test",
      cwd: "/repo",
      commandActions: [],
    },
  });

  const snapshot = service.getJob(job.jobId);
  assert.equal(snapshot.pendingApprovalCount, 1);

  const threads = await service.listThreads();
  const target = threads.data.find((item) => item.threadId === thread.threadId);
  assert.ok(target, "线程列表应该包含当前线程");
  assert.equal(target.pendingApprovalCount, 1);
});
