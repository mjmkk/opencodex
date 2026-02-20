import test from "node:test";
import assert from "node:assert/strict";

import { buildServeArgs, ensureTailscaleServe, normalizeServePath } from "../src/tailscale-serve.js";

test("normalizeServePath 会补全前导斜杠并去除尾斜杠", () => {
  assert.equal(normalizeServePath(""), "/");
  assert.equal(normalizeServePath("/"), "/");
  assert.equal(normalizeServePath("codex"), "/codex");
  assert.equal(normalizeServePath("/codex/"), "/codex");
});

test("buildServeArgs 根路径不携带 --set-path", () => {
  const args = buildServeArgs({
    service: "svc:opencodex",
    path: "/",
    target: "http://127.0.0.1:8787",
  });

  assert.deepEqual(args, ["serve", "--bg", "--service", "svc:opencodex", "http://127.0.0.1:8787"]);
});

test("buildServeArgs 子路径会带 --set-path", () => {
  const args = buildServeArgs({
    service: "svc:opencodex",
    path: "/codex",
    target: "http://127.0.0.1:8787",
  });

  assert.deepEqual(args, [
    "serve",
    "--bg",
    "--service",
    "svc:opencodex",
    "--set-path",
    "/codex",
    "http://127.0.0.1:8787",
  ]);
});

test("buildServeArgs 未配置 service 时走节点级路由", () => {
  const args = buildServeArgs({
    service: null,
    path: "/",
    target: "http://127.0.0.1:8787",
  });
  assert.deepEqual(args, ["serve", "--bg", "http://127.0.0.1:8787"]);
});

test("ensureTailscaleServe 会在首个 CLI 不存在时回退到下一个候选", async () => {
  const calls = [];
  const exec = async (cli, args) => {
    calls.push({ cli, args });
    if (cli === "/missing/tailscale") {
      const error = new Error("not found");
      error.code = "ENOENT";
      throw error;
    }
  };

  const result = await ensureTailscaleServe({
    service: "svc:opencodex",
    path: "/",
    port: 8787,
    exec,
    cliCandidates: ["/missing/tailscale", "tailscale"],
  });

  assert.equal(result.applied, true);
  assert.equal(result.cli, "tailscale");
  assert.equal(calls.length, 2);
  assert.equal(calls[0].cli, "/missing/tailscale");
  assert.equal(calls[1].cli, "tailscale");
});

test("ensureTailscaleServe 失败时返回错误信息（不抛异常）", async () => {
  const exec = async () => {
    const error = new Error("command failed");
    error.stderr = "permission denied";
    throw error;
  };

  const result = await ensureTailscaleServe({
    service: "svc:opencodex",
    path: "/codex",
    port: 8787,
    exec,
    cliCandidates: ["tailscale"],
  });

  assert.equal(result.applied, false);
  assert.match(result.error, /command failed/);
  assert.match(result.error, /permission denied/);
  assert.equal(result.path, "/codex");
});
