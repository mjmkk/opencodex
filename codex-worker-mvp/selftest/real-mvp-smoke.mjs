import net from 'node:net';
import { spawn } from 'node:child_process';

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function deadlineMs(fromNowMs) {
  return Date.now() + fromNowMs;
}

async function pickPort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const addr = server.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
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
      if (res.ok) {
        return;
      }
    } catch {
      // ignore
    }
    await sleep(200);
  }
  throw new Error('worker health check timeout');
}

function parseSseEventsFromBuffer(buffer) {
  // SSE event framing: events are separated by a blank line.
  // Each event may have multiple "data:" lines; join them with "\n".
  const events = [];
  const parts = buffer.split('\n\n');
  const rest = parts.pop() ?? '';

  for (const raw of parts) {
    const lines = raw.split('\n');
    const dataLines = [];
    for (const line of lines) {
      if (line.startsWith('data:')) {
        dataLines.push(line.slice('data:'.length).trim());
      }
    }
    if (dataLines.length === 0) {
      continue;
    }
    const jsonText = dataLines.join('\n');
    try {
      events.push(JSON.parse(jsonText));
    } catch {
      // Ignore malformed frames; continue consuming stream.
    }
  }

  return { events, rest };
}

async function run() {
  const port = await pickPort();
  const baseUrl = `http://127.0.0.1:${port}`;

  const child = spawn('node', ['src/index.js'], {
    cwd: '/Users/Apple/Dev/OpenCodex/codex-worker-mvp',
    env: {
      ...process.env,
      PORT: String(port),
      // 允许本仓库作为 project 白名单
      WORKER_PROJECT_PATHS: '/Users/Apple/Dev/OpenCodex',
      WORKER_DEFAULT_PROJECT: '/Users/Apple/Dev/OpenCodex',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  // Drain stdout to avoid blocking the child if its pipe buffer fills.
  child.stdout.on('data', () => {});

  let stderr = '';
  child.stderr.on('data', (d) => {
    stderr += d.toString('utf8');
  });

  try {
    await waitHealth(baseUrl, 15000);

    const threadRes = await fetchJson(`${baseUrl}/v1/threads`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        projectPath: '/Users/Apple/Dev/OpenCodex',
        // 尽量强制触发审批
        approvalPolicy: 'unlessTrusted',
        sandbox: 'readOnly',
        threadName: 'mvp-smoke',
      }),
    });

    const threadId = threadRes.thread.threadId;

    await fetchJson(`${baseUrl}/v1/threads/${encodeURIComponent(threadId)}/activate`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({}),
    });

    const turnRes = await fetchJson(`${baseUrl}/v1/threads/${encodeURIComponent(threadId)}/turns`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        approvalPolicy: 'unlessTrusted',
        text:
          '请在项目内创建文件 codex-worker-mvp/selftest/_smoke_approval.txt，并写入一行：SMOKE_APPROVAL_OK。' +
          '然后运行命令：git status，并返回输出。',
      }),
    });

    const jobId = turnRes.jobId;

    let cursor = -1;
    let approvalId = null;
    const approved = new Set();
    let finishedState = null;
    const overallStopAt = deadlineMs(120000);

    while (!finishedState) {
      if (Date.now() > overallStopAt) {
        throw new Error(`smoke timeout (approvalId=${approvalId ?? 'null'} cursor=${cursor})`);
      }
      const res = await fetch(`${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}/events?cursor=${cursor}`, {
        headers: { accept: 'text/event-stream' },
      });

      if (!res.ok || !res.body) {
        throw new Error(`events failed: HTTP ${res.status}`);
      }

      const reader = res.body.getReader();
      let buf = '';
      const stopAt = Date.now() + 15000;

      while (Date.now() < stopAt) {
        const { value, done } = await reader.read();
        if (done) {
          break;
        }

        buf += new TextDecoder().decode(value);
        const parsed = parseSseEventsFromBuffer(buf);
        buf = parsed.rest;

        for (const ev of parsed.events) {
          cursor = Math.max(cursor, ev.seq ?? cursor);

          if (ev.type === 'approval.required') {
            const nextApprovalId = ev.payload?.approvalId ?? null;
            if (nextApprovalId && !approved.has(nextApprovalId)) {
              approvalId = nextApprovalId;
              approved.add(nextApprovalId);
              await fetchJson(`${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}/approve`, {
                method: 'POST',
                headers: { 'content-type': 'application/json' },
                body: JSON.stringify({
                  approvalId: nextApprovalId,
                  decision: 'accept',
                }),
              });
            }
          }

          if (ev.type === 'job.finished') {
            finishedState = ev.payload.state;
            break;
          }
        }

        if (finishedState) {
          break;
        }
      }

      await reader.cancel().catch(() => {});
      await sleep(200);
    }

    const finalJob = await fetchJson(`${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}`, {
      headers: { accept: 'application/json' },
    });

    process.stdout.write(
      JSON.stringify(
        {
          ok: true,
          baseUrl,
          threadId,
          jobId,
          approvalId,
          finishedState,
          finalState: finalJob.state,
        },
        null,
        2
      ) +
        '\n'
    );

    if (finalJob.state !== 'DONE' && finalJob.state !== 'FAILED' && finalJob.state !== 'CANCELLED') {
      throw new Error(`unexpected final state: ${finalJob.state}`);
    }
  } finally {
    child.kill('SIGTERM');
  }
}

run().catch((err) => {
  process.stderr.write(`SMOKE_FAIL: ${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
