import test from "node:test";
import assert from "node:assert/strict";

import { WorkerService } from "../src/worker-service.js";
import { FakeRpcClient } from "./helpers/fake-rpc.js";

test("createThread 会把 sandbox 透传到 thread/start（并校验枚举）", async () => {
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

  // Test camelCase input (official format)
  await service.createThread({
    projectPath: "/repo",
    sandbox: "readOnly",
    approvalPolicy: "unlessTrusted",
  });

  assert.ok(captured);
  assert.equal(captured.sandbox, "readOnly");
  assert.equal(captured.approvalPolicy, "unlessTrusted");

  // Test kebab-case input (legacy format, should be converted)
  captured = null;
  await service.createThread({
    projectPath: "/repo",
    sandbox: "read-only",
    approvalPolicy: "untrusted",
  });

  assert.ok(captured);
  assert.equal(captured.sandbox, "readOnly");
  assert.equal(captured.approvalPolicy, "unlessTrusted");

  // invalid sandbox should fall back to default.
  captured = null;
  await service.createThread({
    projectPath: "/repo",
    sandbox: "not-a-real-sandbox",
  });
  assert.ok(captured);
  assert.equal(captured.sandbox, "workspaceWrite");
});

