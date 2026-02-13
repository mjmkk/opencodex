import net from "node:net";
import { spawn } from "node:child_process";

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

async function mustOk(res, label) {
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`${label} HTTP ${res.status}: ${text.slice(0, 200)}`);
  }
  return res;
}

async function run() {
  const port = await pickPort();
  const baseUrl = `http://127.0.0.1:${port}`;

  const child = spawn("node", ["src/index.js"], {
    cwd: "/Users/Apple/Dev/OpenCodex/codex-worker-mvp",
    env: {
      ...process.env,
      PORT: String(port),
      WORKER_PROJECT_PATHS: "/Users/Apple/Dev/OpenCodex",
      WORKER_DEFAULT_PROJECT: "/Users/Apple/Dev/OpenCodex",
      // UI 自测不启用 token
      WORKER_TOKEN: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  child.stdout.on("data", () => {});
  let stderr = "";
  child.stderr.on("data", (d) => {
    stderr += d.toString("utf8");
  });

  try {
    await waitHealth(baseUrl, 15000);

    await mustOk(await fetch(`${baseUrl}/`), "GET /");
    await mustOk(await fetch(`${baseUrl}/ui/app.js`), "GET /ui/app.js");
    await mustOk(await fetch(`${baseUrl}/ui/style.css`), "GET /ui/style.css");
    await mustOk(await fetch(`${baseUrl}/v1/projects`), "GET /v1/projects");

    process.stdout.write(JSON.stringify({ ok: true, baseUrl }, null, 2) + "\n");
  } finally {
    child.kill("SIGTERM");
  }
}

run().catch((err) => {
  process.stderr.write(`UI_SMOKE_FAIL: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});

