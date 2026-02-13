import net from "node:net";
import { spawn } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function pickPort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      server.close(() => resolve(port));
    });
  });
}

async function fetchJson(url, init) {
  const res = await fetch(url, init);
  const text = await res.text();
  let json;
  try {
    json = text.length ? JSON.parse(text) : null;
  } catch {
    throw new Error(`HTTP ${res.status} invalid JSON: ${text.slice(0, 500)}`);
  }
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} ${url}: ${JSON.stringify(json)}`);
  }
  return json;
}

async function waitHealth(baseUrl, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${baseUrl}/health`);
      if (res.ok) return;
    } catch {
      // ignore
    }
    await sleep(200);
  }
  throw new Error("worker health check timeout");
}

function parseSseEventsFromBuffer(buffer) {
  const events = [];
  const parts = buffer.split("\n\n");
  const rest = parts.pop() ?? "";

  for (const raw of parts) {
    const lines = raw.split("\n");
    const dataLines = [];
    for (const line of lines) {
      if (line.startsWith("data:")) {
        dataLines.push(line.slice("data:".length).trim());
      }
    }
    if (dataLines.length === 0) continue;
    const jsonText = dataLines.join("\n");
    try {
      events.push(JSON.parse(jsonText));
    } catch {
      // ignore malformed frames
    }
  }
  return { events, rest };
}

async function readEventsOnce(baseUrl, jobId, cursor) {
  const res = await fetch(`${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}/events?cursor=${cursor}`, {
    headers: { accept: "text/event-stream" },
  });
  if (!res.ok || !res.body) {
    throw new Error(`events failed: HTTP ${res.status}`);
  }

  const reader = res.body.getReader();
  let buf = "";
  const stopAt = Date.now() + 3000;
  let nextCursor = cursor;
  const out = [];

  while (Date.now() < stopAt) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += new TextDecoder().decode(value);
    const parsed = parseSseEventsFromBuffer(buf);
    buf = parsed.rest;
    for (const ev of parsed.events) {
      out.push(ev);
      if (typeof ev.seq === "number") nextCursor = Math.max(nextCursor, ev.seq);
    }
    if (out.length > 0) break;
  }

  await reader.cancel().catch(() => {});
  return { events: out, nextCursor };
}

function spawnWorker({ port, dbPath }) {
  const child = spawn("node", ["src/index.js"], {
    cwd: "/Users/Apple/Dev/OpenCodex/codex-worker-mvp",
    env: {
      ...process.env,
      PORT: String(port),
      WORKER_DB_PATH: dbPath,
      WORKER_PROJECT_PATHS: "/Users/Apple/Dev/OpenCodex",
      WORKER_DEFAULT_PROJECT: "/Users/Apple/Dev/OpenCodex",
      // 场景测试默认不启用鉴权（避免把 token 交互掺进结果里）
      WORKER_TOKEN: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  // Drain stdout to avoid blocking.
  child.stdout.on("data", () => {});
  let stderr = "";
  child.stderr.on("data", (d) => {
    stderr += d.toString("utf8");
  });

  return {
    child,
    baseUrl: `http://127.0.0.1:${port}`,
    stop() {
      child.kill("SIGTERM");
    },
    getStderr() {
      return stderr;
    },
  };
}

async function withWorker({ dbPath }, fn) {
  const port = await pickPort();
  const worker = spawnWorker({ port, dbPath });
  try {
    await waitHealth(worker.baseUrl, 15000);
    return await fn(worker.baseUrl);
  } finally {
    worker.stop();
    await sleep(600);
  }
}

async function runJobToCompletion({
  scenario,
  baseUrl,
  projectPath,
  approvalPolicy,
  sandbox,
  text,
  timeoutMs = 120000,
}) {
  const threadRes = await fetchJson(`${baseUrl}/v1/threads`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      projectPath,
      approvalPolicy,
      sandbox,
      threadName: `scenario:${scenario}`,
    }),
  });
  const threadId = threadRes.thread.threadId;

  await fetchJson(`${baseUrl}/v1/threads/${encodeURIComponent(threadId)}/activate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });

  const turnRes = await fetchJson(`${baseUrl}/v1/threads/${encodeURIComponent(threadId)}/turns`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      approvalPolicy,
      text,
    }),
  });
  const jobId = turnRes.jobId;

  let cursor = -1;
  const approved = new Set();
  const stopAtOverall = Date.now() + timeoutMs;
  let finishedState = null;
  let sawApprovalRequired = false;
  let sawCommandOutputDelta = false;

  while (!finishedState) {
    if (Date.now() > stopAtOverall) {
      // Try to cancel so we don't leave runaway turns behind.
      await fetchJson(`${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}/cancel`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({}),
      }).catch(() => {});
      throw new Error(`job timeout (scenario=${scenario} jobId=${jobId} cursor=${cursor})`);
    }

    const res = await fetch(`${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}/events?cursor=${cursor}`, {
      headers: { accept: "text/event-stream" },
    });
    if (!res.ok || !res.body) {
      throw new Error(`events failed (scenario=${scenario}) HTTP ${res.status}`);
    }

    const reader = res.body.getReader();
    let buf = "";
    const stopAt = Date.now() + 15000;

    while (Date.now() < stopAt) {
      const { value, done } = await reader.read();
      if (done) break;

      buf += new TextDecoder().decode(value);
      const parsed = parseSseEventsFromBuffer(buf);
      buf = parsed.rest;

      for (const ev of parsed.events) {
        cursor = Math.max(cursor, ev.seq ?? cursor);

        if (ev.type === "approval.required") {
          sawApprovalRequired = true;
          const approvalId = ev.payload?.approvalId ?? null;
          if (approvalId && !approved.has(approvalId)) {
            approved.add(approvalId);
            await fetchJson(`${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}/approve`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({
                approvalId,
                decision: "accept",
              }),
            });
          }
        }

        if (ev.type === "item.commandExecution.outputDelta") {
          sawCommandOutputDelta = true;
        }

        if (ev.type === "job.finished") {
          finishedState = ev.payload?.state ?? null;
          break;
        }
      }

      if (finishedState) break;
    }

    await reader.cancel().catch(() => {});
    await sleep(200);
  }

  const finalJob = await fetchJson(`${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}`, {
    headers: { accept: "application/json" },
  });

  return {
    threadId,
    jobId,
    finishedState,
    finalJob,
    lastCursor: cursor,
    sawApprovalRequired,
    sawCommandOutputDelta,
    approvalsCount: approved.size,
  };
}

async function runScenario(name, fn) {
  try {
    const extra = await fn();
    return { name, ok: true, ...extra };
  } catch (err) {
    return {
      name,
      ok: false,
      reason: err instanceof Error ? err.message : String(err),
    };
  }
}

async function main() {
  const tmp = await mkdtemp(join(tmpdir(), "codex-worker-mvp-scenarios-"));
  const dbPath = join(tmp, "worker.db");

  const results = [];
  const ctx = {
    approvalJobId: null,
    approvalJobCursor: null,
  };

  // 使用一个干净的 worker 进程跑“基础对话 + 审批命令”，减少状态污染与波动。
  await withWorker({ dbPath }, async (baseUrl) => {
    results.push(
      await runScenario("scenario_basic_chat", async () => {
        const r = await runJobToCompletion({
          scenario: "basic_chat",
          baseUrl,
          projectPath: "/Users/Apple/Dev/OpenCodex",
          approvalPolicy: "on-request",
          sandbox: "workspace-write",
          text: '只回复一个单词：OK。不要解释，不要做任何额外操作。',
          timeoutMs: 90000,
        });
        return { jobId: r.jobId, ok: r.finalJob.state === "DONE" };
      })
    );

    results.push(
      await runScenario("scenario_approval_command", async () => {
        const r = await runJobToCompletion({
          scenario: "approval_command",
          baseUrl,
          projectPath: "/Users/Apple/Dev/OpenCodex",
          approvalPolicy: "untrusted",
          sandbox: "read-only",
          text:
            "只做两步：1) 在项目内创建文件 codex-worker-mvp/selftest/_scenario_approval.txt，写入一行：SCENARIO_OK。" +
            "2) 运行命令 `git status` 并返回输出。" +
            "不要做任何额外操作；不要使用需要交互输入的命令（例如 vim/nano/`cat > file`）。",
          timeoutMs: 180000,
        });

        ctx.approvalJobId = r.jobId;
        ctx.approvalJobCursor = r.lastCursor;

        // 这条场景要求真实出现审批（闭环核心能力）。
        const ok = r.finalJob.state === "DONE" && r.sawApprovalRequired;
        return {
          ok,
          jobId: r.jobId,
          approvalsCount: r.approvalsCount,
          sawApprovalRequired: r.sawApprovalRequired,
          sawCommandOutputDelta: r.sawCommandOutputDelta,
        };
      })
    );

    results.push(
      await runScenario("scenario_cursor_reconnect", async () => {
        if (!ctx.approvalJobId) {
          return { ok: false, reason: "missing approvalJobId" };
        }
        const first = await readEventsOnce(baseUrl, ctx.approvalJobId, -1);
        const second = await readEventsOnce(baseUrl, ctx.approvalJobId, first.nextCursor);
        const seqs2 = second.events.map((e) => e.seq).filter((n) => typeof n === "number");
        const ok = seqs2.every((s) => typeof s === "number" && s > (first.nextCursor ?? -1));
        return {
          ok,
          jobId: ctx.approvalJobId,
          cursor1: first.nextCursor,
          events1: first.events.length,
          events2: second.events.length,
        };
      })
    );
  });

  // 重启 worker 后验证 SQLite 回放：job snapshot 与事件列表都可读取。
  results.push(
    await runScenario("scenario_persist_replay_after_restart", async () => {
      if (!ctx.approvalJobId) {
        return { ok: false, reason: "missing approvalJobId" };
      }

      return await withWorker({ dbPath }, async (baseUrl2) => {
        const snapshot = await fetchJson(
          `${baseUrl2}/v1/jobs/${encodeURIComponent(ctx.approvalJobId)}`,
          { headers: { accept: "application/json" } }
        );
        if (!snapshot || snapshot.jobId !== ctx.approvalJobId) {
          return { ok: false, reason: "job snapshot missing after restart" };
        }

        const replay = await fetchJson(
          `${baseUrl2}/v1/jobs/${encodeURIComponent(ctx.approvalJobId)}/events?cursor=-1`,
          { headers: { accept: "application/json" } }
        );
        const ok = Array.isArray(replay?.data) && replay.data.length > 0;
        return { ok, events: Array.isArray(replay?.data) ? replay.data.length : 0 };
      });
    })
  );

  const pass = results.filter((r) => r.ok).length;
  const fail = results.length - pass;

  process.stdout.write(
    JSON.stringify(
      {
        ok: fail === 0,
        results,
        summary: { total: results.length, pass, fail },
        dbPath,
      },
      null,
      2
    ) + "\n"
  );

  process.exit(fail === 0 ? 0 : 1);
}

main().catch((err) => {
  process.stderr.write(`SCENARIO_FAIL: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
