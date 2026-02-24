import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

import { loadConfig } from "../src/config.js";

function withTempConfig(config, run) {
  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "codex-worker-config-"));
  const filePath = path.join(tempDir, "worker.config.json");
  fs.writeFileSync(filePath, JSON.stringify(config, null, 2), "utf8");
  try {
    return run({ tempDir, filePath });
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

test("loadConfig 支持通过 --config 加载配置文件，并解析相对路径", () => {
  withTempConfig(
    {
      port: 8899,
      projectPaths: ["./projects/a", "./projects/b"],
      defaultProjectPath: "./projects/a",
      eventRetention: 4321,
      dbPath: "./db/worker.db",
      rpc: {
        command: "codex-custom",
        args: ["app-server", "--stdio"],
        cwd: "./workspace",
      },
      tailscaleServe: {
        enabled: true,
        service: "svc:opencodex",
        path: "codex",
      },
      apns: {
        enabled: false,
        defaultEnvironment: "production",
      },
    },
    ({ tempDir, filePath }) => {
      const config = loadConfig({}, { argv: ["--config", filePath], cwd: "/tmp/ignored" });

      assert.equal(config.configFilePath, filePath);
      assert.equal(config.port, 8899);
      assert.equal(config.eventRetention, 4321);
      assert.deepEqual(config.projectPaths, [
        path.join(tempDir, "projects/a"),
        path.join(tempDir, "projects/b"),
      ]);
      assert.equal(config.defaultProjectPath, path.join(tempDir, "projects/a"));
      assert.equal(config.dbPath, path.join(tempDir, "db/worker.db"));
      assert.equal(config.rpc.command, "codex-custom");
      assert.deepEqual(config.rpc.args, ["app-server", "--stdio"]);
      assert.equal(config.rpc.cwd, path.join(tempDir, "workspace"));
      assert.equal(config.tailscaleServe.enabled, true);
      assert.equal(config.tailscaleServe.service, "svc:opencodex");
      assert.equal(config.tailscaleServe.path, "/codex");
      assert.equal(config.apns.defaultEnvironment, "production");
    }
  );
});

test("环境变量优先级高于配置文件", () => {
  withTempConfig(
    {
      port: 8899,
      dbPath: "./db/worker.db",
      rpc: {
        command: "codex-from-file",
        args: ["app-server"],
      },
    },
    ({ filePath }) => {
      const config = loadConfig(
        {
          WORKER_CONFIG: filePath,
          PORT: "9900",
          WORKER_DB_PATH: "/tmp/worker-from-env.db",
          CODEX_COMMAND: "codex-from-env",
          CODEX_APP_SERVER_ARGS: "app-server,--json",
        },
        { argv: [] }
      );

      assert.equal(config.port, 9900);
      assert.equal(config.dbPath, "/tmp/worker-from-env.db");
      assert.equal(config.rpc.command, "codex-from-env");
      assert.deepEqual(config.rpc.args, ["app-server", "--json"]);
    }
  );
});

test("配置文件不存在时给出明确报错", () => {
  const missingPath = path.join(os.tmpdir(), `worker-config-missing-${Date.now()}.json`);
  assert.throws(
    () => loadConfig({}, { argv: ["--config", missingPath] }),
    /failed to read config file/
  );
});

test("--config 缺少值时报错", () => {
  assert.throws(() => loadConfig({}, { argv: ["--config"] }), /missing value/);
});

test("tailscaleServe 缺省值正确", () => {
  const config = loadConfig({}, { argv: [], cwd: "/tmp/workspace" });
  assert.equal(config.tailscaleServe.enabled, false);
  assert.equal(config.tailscaleServe.service, "svc:opencodex");
  assert.equal(config.tailscaleServe.path, "/");
});

test("tailscaleServe.service 显式为 null 时走节点级路由", () => {
  withTempConfig(
    {
      tailscaleServe: {
        enabled: true,
        service: null,
        path: "/",
      },
    },
    ({ filePath }) => {
      const config = loadConfig({}, { argv: ["--config", filePath] });
      assert.equal(config.tailscaleServe.enabled, true);
      assert.equal(config.tailscaleServe.service, null);
      assert.equal(config.tailscaleServe.path, "/");
    }
  );
});

test("线程导入导出目录支持环境变量覆盖", () => {
  const config = loadConfig(
    {
      WORKER_CODEX_HOME: "/tmp/custom-codex-home",
      WORKER_THREAD_EXPORT_DIR: "/tmp/custom-thread-exports",
    },
    { argv: [], cwd: "/tmp/workspace" },
  );

  assert.equal(config.codexHome, "/tmp/custom-codex-home");
  assert.equal(config.threadExportDir, "/tmp/custom-thread-exports");
});
