import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

async function setupService({ terminalEnabled = true, terminalManager, threadListHandler }) {
  const rpc = new FakeRpcClient();
  rpc.onRequest("initialize", () => ({}));
  rpc.onRequest("thread/list", threadListHandler);

  const service = new WorkerService({
    rpc,
    projectPaths: ["/repo-default"],
    defaultProjectPath: "/repo-default",
    terminal: { enabled: terminalEnabled },
    terminalManager,
    logger: {
      warn: () => {},
      error: () => {},
    },
  });
  await service.init();
  return service;
}

test("openThreadTerminal 使用线程 cwd 打开终端", async () => {
  const calls = [];
  const service = await setupService({
    terminalManager: {
      openSession: (params) => {
        calls.push(params);
        return {
          reused: false,
          session: {
            sessionId: "term_1",
            threadId: params.threadId,
            cwd: params.cwd,
            status: "running",
            nextSeq: 0,
          },
        };
      },
      shutdown: () => {},
    },
    threadListHandler: ({ archived }) => ({
      data: archived
        ? []
        : [
            {
              id: "thr_terminal",
              cwd: "/repo-terminal",
              preview: "",
              createdAt: 1,
              updatedAt: 1,
            },
          ],
      nextCursor: null,
    }),
  });

  const result = await service.openThreadTerminal("thr_terminal", { cols: 120, rows: 40 });
  assert.equal(result.reused, false);
  assert.equal(result.session.sessionId, "term_1");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].cwd, "/repo-terminal");
  assert.equal(calls[0].cols, 120);
  assert.equal(calls[0].rows, 40);
});

test("openThreadTerminal 在线程归档时返回 409", async () => {
  const service = await setupService({
    terminalManager: {
      openSession: () => {
        throw new Error("should not be called");
      },
      shutdown: () => {},
    },
    threadListHandler: ({ archived }) => ({
      data: archived
        ? [
            {
              id: "thr_archived",
              cwd: "/repo-archived",
              preview: "",
              createdAt: 1,
              updatedAt: 1,
            },
          ]
        : [],
      nextCursor: null,
    }),
  });

  await assert.rejects(
    () => service.openThreadTerminal("thr_archived", {}),
    (error) => error.code === "THREAD_ARCHIVED" && error.status === 409
  );
});

test("terminal disabled 时拒绝终端操作", async () => {
  const service = await setupService({
    terminalEnabled: false,
    terminalManager: null,
    threadListHandler: () => ({ data: [], nextCursor: null }),
  });

  assert.throws(
    () => service.getThreadTerminal("thr_1"),
    (error) => error.code === "TERMINAL_DISABLED" && error.status === 403
  );
});

