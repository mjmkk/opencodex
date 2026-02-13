function $(id) {
  const el = document.getElementById(id);
  if (!el) {
    throw new Error(`missing element: #${id}`);
  }
  return el;
}

const els = {
  baseUrl: $("baseUrl"),
  token: $("token"),
  refresh: $("refresh"),
  loadThreads: $("loadThreads"),
  threads: $("threads"),
  projectPath: $("projectPath"),
  threadName: $("threadName"),
  threadApprovalPolicy: $("threadApprovalPolicy"),
  sandbox: $("sandbox"),
  createThread: $("createThread"),
  activeThread: $("activeThread"),
  activeJob: $("activeJob"),
  activeState: $("activeState"),
  turnApprovalPolicy: $("turnApprovalPolicy"),
  input: $("input"),
  autoApprove: $("autoApprove"),
  send: $("send"),
  cancel: $("cancel"),
  runSelftest: $("runSelftest"),
  clearLog: $("clearLog"),
  cursorHint: $("cursorHint"),
  log: $("log"),
  approvalModal: $("approvalModal"),
  apprKind: $("apprKind"),
  apprCmd: $("apprCmd"),
  apprCwd: $("apprCwd"),
  apprReason: $("apprReason"),
  apprAccept: $("apprAccept"),
  apprAcceptSession: $("apprAcceptSession"),
  apprDecline: $("apprDecline"),
  apprCancel: $("apprCancel"),
};

const storage = {
  get(key, fallback = "") {
    try {
      const v = localStorage.getItem(key);
      return v === null ? fallback : v;
    } catch {
      return fallback;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch {
      // ignore
    }
  },
  getBool(key, fallback = false) {
    return storage.get(key, fallback ? "1" : "0") === "1";
  },
  setBool(key, value) {
    storage.set(key, value ? "1" : "0");
  },
};

function normalizeBaseUrl(value) {
  const v = String(value || "").trim();
  if (!v) return "";
  return v.endsWith("/") ? v.slice(0, -1) : v;
}

function nowTs() {
  return new Date().toISOString();
}

function appendLog(line) {
  els.log.textContent += `${line}\n`;
  els.log.scrollTop = els.log.scrollHeight;
}

function setBadge(text, kind = "neutral") {
  els.activeState.textContent = text;
  const base = "badge";
  if (kind === "ok") {
    els.activeState.className = `${base}`;
    els.activeState.style.borderColor = "rgba(46, 204, 113, 0.55)";
    els.activeState.style.background = "rgba(46, 204, 113, 0.12)";
    return;
  }
  if (kind === "warn") {
    els.activeState.className = `${base}`;
    els.activeState.style.borderColor = "rgba(255, 77, 79, 0.55)";
    els.activeState.style.background = "rgba(255, 77, 79, 0.10)";
    return;
  }
  els.activeState.className = `${base}`;
  els.activeState.style.borderColor = "";
  els.activeState.style.background = "";
}

function authHeaders() {
  const token = String(els.token.value || "").trim();
  const headers = {};
  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }
  return headers;
}

async function apiFetch(path, init = {}) {
  const baseUrl = normalizeBaseUrl(els.baseUrl.value);
  if (!baseUrl) {
    throw new Error("请先填写 Worker 地址");
  }

  const url = `${baseUrl}${path}`;
  const headers = {
    ...authHeaders(),
    ...(init.headers || {}),
  };

  const res = await fetch(url, {
    ...init,
    headers,
  });

  const text = await res.text();
  let json = null;
  if (text.trim()) {
    try {
      json = JSON.parse(text);
    } catch {
      throw new Error(`HTTP ${res.status} 返回非 JSON：${text.slice(0, 200)}`);
    }
  }
  if (!res.ok) {
    const msg = json?.error?.message || JSON.stringify(json) || text || "unknown error";
    throw new Error(`HTTP ${res.status} ${path}: ${msg}`);
  }
  return json;
}

async function refreshHealth() {
  const baseUrl = normalizeBaseUrl(els.baseUrl.value);
  if (!baseUrl) {
    return;
  }
  try {
    const res = await fetch(`${baseUrl}/health`);
    const json = await res.json().catch(() => null);
    const authEnabled = Boolean(json?.authEnabled);
    if (authEnabled && !String(els.token.value || "").trim()) {
      appendLog(
        `[${nowTs()}] 提示：当前 Worker 开启了鉴权（WORKER_TOKEN）。请在右上角 Token 输入框填写同一个值，否则 API 会 401。`
      );
    }
  } catch {
    // ignore
  }
}

let activeThreadId = null;
let activeJobId = null;
let cursor = -1;
let sseAbort = null;
let activeApproval = null; // { approvalId, kind }

async function activateThread(threadId) {
  await apiFetch(`/v1/threads/${encodeURIComponent(threadId)}/activate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  setActiveThread(threadId);
  resetJobUi();
  closeApproval();
  appendLog(`[${nowTs()}] thread.activate ${threadId}`);
  await refreshThreads();
}

function resetJobUi() {
  activeJobId = null;
  cursor = -1;
  els.activeJob.textContent = "无";
  els.cancel.disabled = true;
  setBadge("-", "neutral");
  els.cursorHint.textContent = `cursor=${cursor}`;
}

function setActiveThread(threadId) {
  activeThreadId = threadId;
  els.activeThread.textContent = threadId ? threadId : "未选择";
  // 防止“没选线程直接发消息”，按钮态更直观。
  els.send.disabled = !threadId;
}

function setActiveJob(jobId) {
  activeJobId = jobId;
  els.activeJob.textContent = jobId ? jobId : "无";
  els.cancel.disabled = !jobId;
}

function closeApproval() {
  activeApproval = null;
  els.approvalModal.classList.add("hidden");
}

function openApproval(payload) {
  activeApproval = {
    approvalId: payload.approvalId,
    kind: payload.kind,
  };
  els.apprKind.textContent = payload.kind || "-";
  els.apprCmd.textContent = payload.command || "-";
  els.apprCwd.textContent = payload.cwd || "-";
  els.apprReason.textContent = payload.reason || "-";
  els.approvalModal.classList.remove("hidden");
}

async function approve(decision) {
  if (!activeJobId || !activeApproval?.approvalId) {
    throw new Error("当前没有可审批的请求");
  }
  const body = {
    approvalId: activeApproval.approvalId,
    decision,
  };
  const result = await apiFetch(`/v1/jobs/${encodeURIComponent(activeJobId)}/approve`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  appendLog(`[${nowTs()}] approval.submit ${decision} -> ${JSON.stringify(result)}`);
  closeApproval();
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

async function startSseLoop(jobId) {
  // Abort previous loop.
  if (sseAbort) {
    sseAbort.abort();
  }
  sseAbort = new AbortController();
  const signal = sseAbort.signal;

  appendLog(`[${nowTs()}] sse.start jobId=${jobId}`);
  while (!signal.aborted) {
    try {
      const baseUrl = normalizeBaseUrl(els.baseUrl.value);
      const url = `${baseUrl}/v1/jobs/${encodeURIComponent(jobId)}/events?cursor=${cursor}`;
      const headers = {
        ...authHeaders(),
        Accept: "text/event-stream",
      };

      const res = await fetch(url, { headers, signal });
      if (!res.ok || !res.body) {
        throw new Error(`events HTTP ${res.status}`);
      }

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buf = "";

      // Read until the server closes or we time out and reconnect.
      const stopAt = Date.now() + 15000;
      while (Date.now() < stopAt && !signal.aborted) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += decoder.decode(value);

        const parsed = parseSseEventsFromBuffer(buf);
        buf = parsed.rest;

        for (const ev of parsed.events) {
          if (typeof ev.seq === "number") {
            cursor = Math.max(cursor, ev.seq);
            els.cursorHint.textContent = `cursor=${cursor}`;
          }
          appendLog(`[${nowTs()}] ${ev.type} ${JSON.stringify(ev.payload ?? {})}`);

          if (ev.type === "job.state") {
            const st = ev.payload?.state || "-";
            if (st === "WAITING_APPROVAL") setBadge(st, "warn");
            else if (st === "DONE") setBadge(st, "ok");
            else if (st === "FAILED" || st === "CANCELLED") setBadge(st, "warn");
            else setBadge(st, "neutral");
          }

          if (ev.type === "approval.required") {
            openApproval(ev.payload || {});
            if (els.autoApprove.checked) {
              // Auto-approve for selftest mode.
              await approve("accept");
            }
          }

          if (ev.type === "job.finished") {
            const st = ev.payload?.state || "-";
            if (st === "DONE") setBadge(st, "ok");
            else setBadge(st, "warn");
            appendLog(`[${nowTs()}] sse.done state=${st}`);
            return st;
          }
        }
      }

      try {
        await reader.cancel();
      } catch {
        // ignore
      }
    } catch (e) {
      if (signal.aborted) return;
      appendLog(`[${nowTs()}] sse.error ${(e && e.message) || String(e)}`);
      await new Promise((r) => setTimeout(r, 400));
    }
  }
}

function renderThreads(threads) {
  els.threads.textContent = "";
  if (!Array.isArray(threads) || threads.length === 0) {
    const empty = document.createElement("div");
    empty.className = "hint";
    empty.textContent = "没有可选线程。你可以先在下面创建一个新线程。";
    els.threads.appendChild(empty);
    return;
  }

  for (const t of threads) {
    const wrap = document.createElement("button");
    wrap.type = "button";
    wrap.className = `thread thread-btn${t.threadId === activeThreadId ? " active" : ""}`;
    wrap.addEventListener("click", async () => {
      try {
        await activateThread(t.threadId);
      } catch (e) {
        appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
      }
    });

    const meta = document.createElement("div");
    meta.className = "meta";

    const title = document.createElement("div");
    title.className = "title";
    title.textContent = t.threadId;

    const sub = document.createElement("div");
    sub.className = "sub";
    sub.textContent = `${t.cwd || ""}${t.preview ? " | " + t.preview : ""}`;

    meta.appendChild(title);
    meta.appendChild(sub);

    const actions = document.createElement("div");
    actions.className = "thread-action";
    actions.textContent = t.threadId === activeThreadId ? "已选择" : "点击选择";
    wrap.appendChild(meta);
    wrap.appendChild(actions);
    els.threads.appendChild(wrap);
  }
}

async function refreshProjects() {
  const data = await apiFetch("/v1/projects", { headers: { Accept: "application/json" } });
  const projects = Array.isArray(data?.data) ? data.data : [];
  els.projectPath.textContent = "";
  for (const p of projects) {
    const opt = document.createElement("option");
    opt.value = p.projectPath;
    opt.textContent = p.projectPath;
    els.projectPath.appendChild(opt);
  }
  if (projects.length === 0) {
    const opt = document.createElement("option");
    opt.value = "";
    opt.textContent = "（未配置项目白名单）";
    els.projectPath.appendChild(opt);
  }
}

async function refreshThreads() {
  const data = await apiFetch("/v1/threads", { headers: { Accept: "application/json" } });
  const threads = Array.isArray(data?.data) ? data.data : [];
  if (!activeThreadId && threads.length > 0) {
    setActiveThread(threads[0].threadId);
    appendLog(`[${nowTs()}] thread.auto_select ${threads[0].threadId}`);
  }
  renderThreads(threads);
}

function bootstrapDefaults() {
  // When UI is served by the worker, this is the right base URL.
  els.baseUrl.value = storage.get("baseUrl", normalizeBaseUrl(location.origin));
  els.token.value = storage.get("token", "");
  els.autoApprove.checked = storage.getBool("autoApprove", true);
  els.input.value = storage.get(
    "inputText",
    "自测闭环：请在项目内创建文件 codex-worker-mvp/selftest/_ui_selftest.txt 并写入 UI_SELFTEST。然后运行 git status 并返回输出。"
  );
}

function wireEvents() {
  els.refresh.addEventListener("click", async () => {
    try {
      storage.set("baseUrl", normalizeBaseUrl(els.baseUrl.value));
      storage.set("token", String(els.token.value || ""));
      await refreshHealth();
      await refreshProjects();
      await refreshThreads();
      appendLog(`[${nowTs()}] refreshed`);
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });

  els.loadThreads.addEventListener("click", async () => {
    try {
      await refreshThreads();
      appendLog(`[${nowTs()}] thread.list`);
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });

  els.createThread.addEventListener("click", async () => {
    try {
      const payload = {
        projectPath: String(els.projectPath.value || "").trim() || undefined,
        threadName: String(els.threadName.value || "").trim() || undefined,
        approvalPolicy: String(els.threadApprovalPolicy.value || "").trim() || undefined,
        sandbox: String(els.sandbox.value || "").trim() || undefined,
      };
      const created = await apiFetch("/v1/threads", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });
      const tid = created?.thread?.threadId;
      if (tid) {
        appendLog(`[${nowTs()}] thread.create ${tid}`);
        await activateThread(tid);
      }
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });

  els.send.addEventListener("click", async () => {
    try {
      if (!activeThreadId) {
        throw new Error("请先选择或创建线程");
      }
      const text = String(els.input.value || "").trim();
      if (!text) {
        throw new Error("输入不能为空");
      }
      storage.set("inputText", text);
      storage.setBool("autoApprove", els.autoApprove.checked);

      const payload = { text };
      const ap = String(els.turnApprovalPolicy.value || "").trim();
      if (ap) payload.approvalPolicy = ap;

      const job = await apiFetch(`/v1/threads/${encodeURIComponent(activeThreadId)}/turns`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });

      const jid = job?.jobId;
      if (!jid) {
        throw new Error("turns 未返回 jobId");
      }

      setActiveJob(jid);
      cursor = -1;
      els.cursorHint.textContent = `cursor=${cursor}`;
      setBadge("RUNNING", "neutral");
      closeApproval();
      appendLog(`[${nowTs()}] turn.start jobId=${jid}`);
      startSseLoop(jid);
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });

  els.runSelftest.addEventListener("click", async () => {
    try {
      appendLog(`[${nowTs()}] selftest.start`);

      if (!normalizeBaseUrl(els.baseUrl.value)) {
        els.baseUrl.value = normalizeBaseUrl(location.origin);
        storage.set("baseUrl", els.baseUrl.value);
      }

      // 自测：默认自动接受审批，避免用户参与测试。
      els.autoApprove.checked = true;
      storage.setBool("autoApprove", true);

      await refreshProjects();

      const projectPath = String(els.projectPath.value || "").trim();
      if (!projectPath) {
        throw new Error("未找到可用项目目录（/v1/projects 为空或未配置白名单）");
      }

      const created = await apiFetch("/v1/threads", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          projectPath,
          threadName: "ui-selftest",
          approvalPolicy: "untrusted",
          sandbox: "read-only",
        }),
      });
      const tid = created?.thread?.threadId;
      if (!tid) throw new Error("创建线程失败：未返回 threadId");

      await apiFetch(`/v1/threads/${encodeURIComponent(tid)}/activate`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({}),
      });
      setActiveThread(tid);
      resetJobUi();
      closeApproval();
      appendLog(`[${nowTs()}] selftest.thread ${tid}`);

      const payload = {
        approvalPolicy: "untrusted",
        text:
          "自测闭环：请在项目内创建文件 codex-worker-mvp/selftest/_ui_selftest.txt 并写入 UI_SELFTEST。然后运行 git status 并返回输出。",
      };
      const job = await apiFetch(`/v1/threads/${encodeURIComponent(tid)}/turns`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      });
      const jid = job?.jobId;
      if (!jid) throw new Error("发起任务失败：未返回 jobId");

      setActiveJob(jid);
      cursor = -1;
      els.cursorHint.textContent = `cursor=${cursor}`;
      setBadge("RUNNING", "neutral");
      appendLog(`[${nowTs()}] selftest.job ${jid}`);

      const finalState = await startSseLoop(jid);
      appendLog(`[${nowTs()}] selftest.PASS finalState=${finalState}`);
    } catch (e) {
      appendLog(`[${nowTs()}] selftest.FAIL ${(e && e.message) || String(e)}`);
    }
  });

  els.cancel.addEventListener("click", async () => {
    try {
      if (!activeJobId) return;
      const r = await apiFetch(`/v1/jobs/${encodeURIComponent(activeJobId)}/cancel`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({}),
      });
      appendLog(`[${nowTs()}] job.cancel ${JSON.stringify(r)}`);
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });

  els.clearLog.addEventListener("click", () => {
    els.log.textContent = "";
  });

  els.apprAccept.addEventListener("click", async () => {
    try {
      await approve("accept");
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });
  els.apprAcceptSession.addEventListener("click", async () => {
    try {
      await approve("accept_for_session");
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });
  els.apprDecline.addEventListener("click", async () => {
    try {
      await approve("decline");
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });
  els.apprCancel.addEventListener("click", async () => {
    try {
      await approve("cancel");
    } catch (e) {
      appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
    }
  });

  // Clicking the backdrop closes the modal (non-destructive).
  els.approvalModal.addEventListener("click", (ev) => {
    if (ev.target === els.approvalModal) {
      closeApproval();
    }
  });
}

async function main() {
  bootstrapDefaults();
  wireEvents();
  resetJobUi();
  setActiveThread(null);

  try {
    await refreshHealth();
    await refreshProjects();
    await refreshThreads();
    appendLog(`[${nowTs()}] ready`);
  } catch (e) {
    appendLog(`[${nowTs()}] ERROR ${(e && e.message) || String(e)}`);
  }
}

main().catch((e) => {
  appendLog(`[${nowTs()}] FATAL ${(e && e.message) || String(e)}`);
});
