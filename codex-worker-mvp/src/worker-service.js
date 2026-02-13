import { HttpError } from "./errors.js";
import { createId } from "./ids.js";

const TERMINAL_STATES = new Set(["DONE", "FAILED", "CANCELLED"]);
const ACTIVE_STATES = new Set(["QUEUED", "RUNNING", "WAITING_APPROVAL"]);
const SUPPORTED_EVENT_METHODS = new Set([
  "thread/started",
  "turn/started",
  "turn/completed",
  "item/started",
  "item/completed",
  "item/agentMessage/delta",
  "item/commandExecution/outputDelta",
  "item/fileChange/outputDelta",
  "error",
]);

function nowIso() {
  return new Date().toISOString();
}

function normalizeApprovalPolicy(value) {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim();
  if (normalized.length === 0) {
    return null;
  }
  // Keep in sync with codex app-server AskForApproval (kebab-case / explicit rename).
  const allowed = new Set(["untrusted", "on-failure", "on-request", "never"]);
  return allowed.has(normalized) ? normalized : null;
}

function normalizeSandboxMode(value) {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim();
  if (normalized.length === 0) {
    return null;
  }
  // Keep in sync with codex app-server SandboxMode (kebab-case).
  const allowed = new Set(["read-only", "workspace-write", "danger-full-access"]);
  return allowed.has(normalized) ? normalized : null;
}

function toJobStateFromTurnStatus(turnStatus) {
  switch (turnStatus) {
    case "completed":
      return "DONE";
    case "failed":
      return "FAILED";
    case "interrupted":
      return "CANCELLED";
    case "inProgress":
    default:
      return "RUNNING";
  }
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

export class WorkerService {
  constructor(options) {
    this.rpc = options.rpc;
    this.store = options.store ?? null;
    this.logger = options.logger ?? console;
    this.eventRetention = options.eventRetention ?? 2000;

    const providedProjects = Array.isArray(options.projectPaths)
      ? options.projectPaths.filter(isNonEmptyString)
      : [];

    const uniqueProjects = [...new Set(providedProjects.map((path) => path.trim()))];
    this.projectPaths = uniqueProjects.length > 0 ? uniqueProjects : [process.cwd()];
    this.defaultProjectPath = options.defaultProjectPath ?? this.projectPaths[0];

    this.threads = new Map();
    this.jobs = new Map();
    this.loadedThreads = new Set();
    this.turnToJob = new Map();
    this.pendingJobByThread = new Map();
    this.approvals = new Map();

    this.initialized = false;
    this.rpcEventsBound = false;
  }

  async init() {
    if (this.initialized) {
      return;
    }

    this.#bindRpcEvents();

    if (typeof this.rpc.start === "function") {
      await this.rpc.start();
    }

    await this.rpc.request("initialize", {
      clientInfo: {
        name: "openclaw_worker_mvp",
        title: "OpenClaw Worker MVP",
        version: "0.1.0",
      },
      capabilities: null,
    });

    this.rpc.notify("initialized");
    this.initialized = true;
  }

  async shutdown() {
    if (typeof this.rpc.stop === "function") {
      await this.rpc.stop();
    }
    this.initialized = false;
  }

  listProjects() {
    return this.projectPaths.map((projectPath, index) => ({
      projectId: `proj_${index + 1}`,
      projectPath,
      displayName: projectPath.split("/").filter(Boolean).pop() ?? projectPath,
    }));
  }

  async createThread(payload = {}) {
    const cwd = this.#resolveProjectPath(payload);
    const approvalPolicy = normalizeApprovalPolicy(payload.approvalPolicy) ?? "on-request";
    const sandbox = normalizeSandboxMode(payload.sandbox) ?? "workspace-write";

    const result = await this.rpc.request("thread/start", {
      cwd,
      approvalPolicy,
      sandbox,
      experimentalRawEvents: false,
    });

    const thread = result.thread;
    if (!thread || !isNonEmptyString(thread.id)) {
      throw new HttpError(502, "INVALID_THREAD_RESPONSE", "thread/start 返回了无效数据");
    }

    if (isNonEmptyString(payload.threadName)) {
      await this.rpc.request("thread/name/set", {
        threadId: thread.id,
        name: payload.threadName,
      });
    }

    this.#upsertThread(thread);
    this.loadedThreads.add(thread.id);

    const dto = this.#toThreadDto(thread);
    this.store?.upsertThread?.(dto);
    return dto;
  }

  async listThreads() {
    const result = await this.rpc.request("thread/list", {
      cursor: null,
      limit: 100,
      sortKey: "updated_at",
      archived: false,
    });

    const threads = Array.isArray(result.data) ? result.data : [];
    for (const thread of threads) {
      this.#upsertThread(thread);
      this.store?.upsertThread?.(this.#toThreadDto(thread));
    }

    return {
      data: threads.map((thread) => this.#toThreadDto(thread)),
      nextCursor: result.nextCursor ?? null,
    };
  }

  async activateThread(threadId) {
    this.#validateThreadId(threadId);

    // If the thread is already loaded in this worker process (e.g. immediately
    // after `thread/start`), "activate" is effectively a no-op. Calling
    // `thread/resume` here can fail because resume is primarily for loading a
    // thread from persisted rollout state.
    if (this.loadedThreads.has(threadId)) {
      const existing = this.threads.get(threadId);
      if (existing) {
        return this.#toThreadDto(existing);
      }
      // Defensive: if the loaded marker is present but cache is missing, fall
      // through and attempt a resume.
    }

    const result = await this.rpc.request("thread/resume", {
      threadId,
      approvalPolicy: "on-request",
      // Keep in sync with codex app-server sandbox enum variants.
      sandbox: "workspace-write",
    });

    const thread = result.thread;
    if (!thread || !isNonEmptyString(thread.id)) {
      throw new HttpError(502, "INVALID_THREAD_RESPONSE", "thread/resume 返回了无效数据");
    }

    this.#upsertThread(thread);
    this.loadedThreads.add(threadId);

    const dto = this.#toThreadDto(thread);
    this.store?.upsertThread?.(dto);
    return dto;
  }

  async startTurn(threadId, payload = {}) {
    this.#validateThreadId(threadId);
    const input = this.#normalizeTurnInput(payload);
    const approvalPolicy = normalizeApprovalPolicy(payload.approvalPolicy);

    const activeJob = this.#findActiveJobByThread(threadId);
    if (activeJob) {
      throw new HttpError(
        409,
        "THREAD_HAS_ACTIVE_JOB",
        `线程 ${threadId} 已有进行中的任务 ${activeJob.jobId}`
      );
    }

    await this.#ensureThreadLoaded(threadId);

    const job = this.#createJob(threadId);
    this.pendingJobByThread.set(threadId, job.jobId);

    this.#appendEvent(job, "job.created", {
      threadId,
    });
    this.#appendEvent(job, "job.state", {
      state: "QUEUED",
    });

    try {
      const response = await this.rpc.request("turn/start", {
        threadId,
        input,
        ...(approvalPolicy ? { approvalPolicy } : {}),
      });

      const turnId = response?.turn?.id;
      if (isNonEmptyString(turnId)) {
        job.turnId = turnId;
        this.turnToJob.set(this.#turnKey(threadId, turnId), job.jobId);
      }

      this.#setJobState(job, "RUNNING");
      return this.#toJobSnapshot(job);
    } catch (error) {
      job.errorMessage = error.message;
      this.#appendEvent(job, "error", {
        message: error.message,
      });
      this.#setJobState(job, "FAILED");
      throw error;
    } finally {
      const pendingJobId = this.pendingJobByThread.get(threadId);
      if (pendingJobId === job.jobId) {
        this.pendingJobByThread.delete(threadId);
      }
    }
  }

  getJob(jobId) {
    const job = this.jobs.get(jobId);
    if (job) {
      return this.#toJobSnapshot(job);
    }

    const persisted = this.store?.getJob?.(jobId) ?? null;
    if (!persisted) {
      throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
    }
    return persisted;
  }

  listEvents(jobId, cursor = null) {
    // 启用 SQLite 后，优先回放落盘事件，支持 Worker 重启后的追溯。
    if (this.store?.listEvents) {
      const snapshot = this.getJob(jobId);
      const persisted = this.store.listEvents(jobId, cursor);
      return {
        ...persisted,
        firstSeq: 0,
        job: snapshot,
      };
    }

    const job = this.jobs.get(jobId);
    if (!job) {
      throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
    }

    let normalizedCursor = cursor;
    if (normalizedCursor === null || normalizedCursor === undefined) {
      normalizedCursor = job.firstSeq - 1;
    } else if (!Number.isInteger(normalizedCursor)) {
      throw new HttpError(400, "INVALID_CURSOR", "cursor 必须是整数");
    }

    if (normalizedCursor < job.firstSeq - 1) {
      throw new HttpError(409, "CURSOR_EXPIRED", "cursor 已过期，请先拉取任务快照再重连");
    }

    const data = job.events.filter((event) => event.seq > normalizedCursor);
    const nextCursor = data.length > 0 ? data[data.length - 1].seq : normalizedCursor;

    return {
      data,
      nextCursor,
      firstSeq: job.firstSeq,
    };
  }

  subscribe(jobId, listener) {
    const job = this.jobs.get(jobId);
    if (!job) {
      throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
    }

    job.subscribers.add(listener);
    return () => {
      job.subscribers.delete(listener);
    };
  }

  async approve(jobId, payload = {}) {
    const job = this.jobs.get(jobId);
    if (!job) {
      throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
    }

    const approvalId = payload.approvalId;
    if (!isNonEmptyString(approvalId)) {
      throw new HttpError(400, "INVALID_APPROVAL_ID", "approvalId 不能为空");
    }

    const approval = this.approvals.get(approvalId);
    if (!approval || approval.jobId !== jobId) {
      throw new HttpError(404, "APPROVAL_NOT_FOUND", `审批 ${approvalId} 不存在或不属于任务 ${jobId}`);
    }

    if (approval.decisionResult) {
      return {
        approvalId,
        status: "already_submitted",
        decision: approval.decisionText,
      };
    }

    const decisionText = payload.decision;
    const decisionResult = this.#mapDecisionToRpc(
      approval.kind,
      decisionText,
      payload.execPolicyAmendment
    );

    this.rpc.respond(approval.requestId, {
      decision: decisionResult,
    });

    approval.decisionResult = decisionResult;
    approval.decisionText = decisionText;
    approval.decidedAt = nowIso();

    this.#appendEvent(job, "approval.resolved", {
      approvalId,
      decision: decisionText,
      decidedAt: approval.decidedAt,
    });

    this.store?.insertDecision?.({
      approvalId,
      decision: decisionText,
      decidedAt: approval.decidedAt,
      actor: "api",
      extra: payload.execPolicyAmendment ? { execPolicyAmendment: payload.execPolicyAmendment } : null,
    });

    job.pendingApprovalIds.delete(approvalId);
    if (job.pendingApprovalIds.size === 0 && !TERMINAL_STATES.has(job.state)) {
      this.#setJobState(job, "RUNNING");
    }

    return {
      approvalId,
      status: "submitted",
      decision: decisionText,
    };
  }

  async cancel(jobId) {
    const job = this.jobs.get(jobId);
    if (!job) {
      throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
    }

    if (TERMINAL_STATES.has(job.state)) {
      return this.#toJobSnapshot(job);
    }

    if (!isNonEmptyString(job.turnId)) {
      this.#setJobState(job, "CANCELLED");
      return this.#toJobSnapshot(job);
    }

    await this.rpc.request("turn/interrupt", {
      threadId: job.threadId,
      turnId: job.turnId,
    });

    return this.#toJobSnapshot(job);
  }

  #bindRpcEvents() {
    if (this.rpcEventsBound) {
      return;
    }

    this.rpc.on("notification", (message) => {
      this.#handleRpcNotification(message);
    });

    this.rpc.on("request", (message) => {
      this.#handleRpcRequest(message);
    });

    this.rpc.on("stderr", (line) => {
      this.logger.warn(`[app-server] ${line}`);
    });

    this.rpc.on("protocolError", (event) => {
      this.logger.error("收到无效协议消息", event);
    });

    this.rpc.on("exit", (event) => {
      this.logger.error("app-server 进程退出", event);
    });

    this.rpcEventsBound = true;
  }

  #handleRpcNotification(message) {
    const { method, params } = message;
    if (!SUPPORTED_EVENT_METHODS.has(method)) {
      return;
    }

    const threadId = params?.threadId;
    const turnId = params?.turnId ?? params?.turn?.id;
    const job = this.#locateJob(threadId, turnId);
    if (!job) {
      return;
    }

    if (method === "turn/started") {
      const notifiedTurnId = params?.turn?.id;
      if (isNonEmptyString(notifiedTurnId)) {
        job.turnId = notifiedTurnId;
        this.turnToJob.set(this.#turnKey(job.threadId, notifiedTurnId), job.jobId);
      }
      this.#setJobState(job, "RUNNING");
      this.#appendEvent(job, "turn.started", params);
      return;
    }

    if (method === "turn/completed") {
      this.#appendEvent(job, "turn.completed", params);

      const finalState = toJobStateFromTurnStatus(params?.turn?.status);
      if (finalState === "FAILED" && isNonEmptyString(params?.turn?.error?.message)) {
        job.errorMessage = params.turn.error.message;
      }
      this.#setJobState(job, finalState);
      return;
    }

    if (method === "error") {
      if (isNonEmptyString(params?.error?.message)) {
        job.errorMessage = params.error.message;
      }
      this.#appendEvent(job, "error", params);
      return;
    }

    const eventTypeMap = {
      "thread/started": "thread.started",
      "item/started": "item.started",
      "item/completed": "item.completed",
      "item/agentMessage/delta": "item.agentMessage.delta",
      "item/commandExecution/outputDelta": "item.commandExecution.outputDelta",
      "item/fileChange/outputDelta": "item.fileChange.outputDelta",
    };

    const mappedType = eventTypeMap[method];
    if (mappedType) {
      this.#appendEvent(job, mappedType, params);
    }
  }

  #handleRpcRequest(message) {
    const { id: requestId, method, params } = message;

    if (
      method !== "item/commandExecution/requestApproval" &&
      method !== "item/fileChange/requestApproval"
    ) {
      this.rpc.respondError(requestId, -32601, `Unsupported server request: ${method}`);
      return;
    }

    const kind =
      method === "item/commandExecution/requestApproval"
        ? "command_execution"
        : "file_change";

    const threadId = params?.threadId;
    const turnId = params?.turnId;

    const job = this.#locateJob(threadId, turnId);
    if (!job) {
      this.rpc.respondError(requestId, -32000, "No active job matches this approval request");
      return;
    }

    const approvalId = createId("appr");
    const approval = {
      approvalId,
      requestId,
      requestMethod: method,
      jobId: job.jobId,
      threadId,
      turnId,
      itemId: params?.itemId ?? null,
      kind,
      createdAt: nowIso(),
      payload: params,
      decisionText: null,
      decisionResult: null,
      decidedAt: null,
    };

    this.approvals.set(approvalId, approval);
    job.pendingApprovalIds.add(approvalId);

    this.#setJobState(job, "WAITING_APPROVAL");

    this.store?.insertApproval?.(approval);

    this.#appendEvent(job, "approval.required", {
      approvalId,
      jobId: job.jobId,
      threadId,
      turnId,
      itemId: approval.itemId,
      kind,
      requestMethod: method,
      createdAt: approval.createdAt,
      reason: params?.reason ?? null,
      command: params?.command ?? null,
      cwd: params?.cwd ?? null,
      commandActions: params?.commandActions ?? [],
      grantRoot: params?.grantRoot ?? null,
      proposedExecpolicyAmendment: params?.proposedExecpolicyAmendment ?? null,
    });
  }

  #resolveProjectPath(payload) {
    const hasProjectId = isNonEmptyString(payload.projectId);
    const hasProjectPath = isNonEmptyString(payload.projectPath);

    if (hasProjectId && hasProjectPath) {
      throw new HttpError(400, "INVALID_PROJECT_SELECTOR", "projectId 和 projectPath 只能二选一");
    }

    if (hasProjectId) {
      const project = this.listProjects().find((item) => item.projectId === payload.projectId);
      if (!project) {
        throw new HttpError(400, "PROJECT_NOT_FOUND", `未找到 projectId=${payload.projectId}`);
      }
      return project.projectPath;
    }

    if (hasProjectPath) {
      if (!this.projectPaths.includes(payload.projectPath)) {
        throw new HttpError(400, "PROJECT_NOT_ALLOWED", "projectPath 不在白名单内");
      }
      return payload.projectPath;
    }

    return this.defaultProjectPath;
  }

  #normalizeTurnInput(payload) {
    if (Array.isArray(payload.input) && payload.input.length > 0) {
      return payload.input;
    }

    if (isNonEmptyString(payload.text)) {
      return [
        {
          type: "text",
          text: payload.text,
        },
      ];
    }

    throw new HttpError(400, "INVALID_INPUT", "turn 输入不能为空，请提供 input 数组或 text");
  }

  async #ensureThreadLoaded(threadId) {
    if (this.loadedThreads.has(threadId)) {
      return;
    }

    await this.activateThread(threadId);
  }

  #createJob(threadId) {
    const createdAtMs = Date.now();
    const timestamp = nowIso();
    const job = {
      jobId: createId("job"),
      threadId,
      turnId: null,
      state: "QUEUED",
      errorMessage: null,
      createdAtMs,
      createdAt: timestamp,
      updatedAt: timestamp,
      terminalAt: null,
      nextSeq: 0,
      firstSeq: 0,
      events: [],
      subscribers: new Set(),
      pendingApprovalIds: new Set(),
      finishedEmitted: false,
    };

    this.jobs.set(job.jobId, job);
    this.store?.insertJob?.(this.#toJobSnapshot(job));
    return job;
  }

  #setJobState(job, state) {
    if (job.state === state) {
      return;
    }

    job.state = state;
    job.updatedAt = nowIso();

    if (TERMINAL_STATES.has(state)) {
      job.terminalAt = job.updatedAt;
    }

    this.#appendEvent(job, "job.state", {
      state,
      errorMessage: job.errorMessage,
    });

    if (TERMINAL_STATES.has(state) && !job.finishedEmitted) {
      this.#appendEvent(job, "job.finished", {
        state,
        errorMessage: job.errorMessage,
      });
      job.finishedEmitted = true;
    }

    this.store?.updateJob?.(this.#toJobSnapshot(job));
  }

  #appendEvent(job, type, payload) {
    const envelope = {
      type,
      ts: nowIso(),
      jobId: job.jobId,
      seq: job.nextSeq,
      payload,
    };

    job.nextSeq += 1;
    job.events.push(envelope);

    if (job.events.length > this.eventRetention) {
      while (job.events.length > this.eventRetention) {
        job.events.shift();
      }
      job.firstSeq = job.events[0]?.seq ?? envelope.seq;
    }

    for (const listener of job.subscribers) {
      listener(envelope);
    }

    this.store?.appendEvent?.(envelope);
  }

  #locateJob(threadId, turnId) {
    if (!isNonEmptyString(threadId)) {
      return null;
    }

    if (isNonEmptyString(turnId)) {
      const byTurn = this.turnToJob.get(this.#turnKey(threadId, turnId));
      if (byTurn) {
        return this.jobs.get(byTurn) ?? null;
      }
    }

    const pendingJobId = this.pendingJobByThread.get(threadId);
    if (pendingJobId) {
      const pendingJob = this.jobs.get(pendingJobId);
      if (pendingJob) {
        if (isNonEmptyString(turnId) && !isNonEmptyString(pendingJob.turnId)) {
          pendingJob.turnId = turnId;
          this.turnToJob.set(this.#turnKey(threadId, turnId), pendingJob.jobId);
        }
        return pendingJob;
      }
    }

    return this.#findActiveJobByThread(threadId) ?? null;
  }

  #findActiveJobByThread(threadId) {
    let found = null;
    for (const job of this.jobs.values()) {
      if (job.threadId !== threadId) {
        continue;
      }
      if (!ACTIVE_STATES.has(job.state)) {
        continue;
      }
      if (!found || job.createdAtMs > found.createdAtMs) {
        found = job;
      }
    }
    return found;
  }

  #mapDecisionToRpc(kind, decision, execPolicyAmendment) {
    if (!isNonEmptyString(decision)) {
      throw new HttpError(400, "INVALID_DECISION", "decision 不能为空");
    }

    switch (decision) {
      case "accept":
        return "accept";
      case "accept_for_session":
        return "acceptForSession";
      case "decline":
        return "decline";
      case "cancel":
        return "cancel";
      case "accept_with_execpolicy_amendment": {
        if (kind !== "command_execution") {
          throw new HttpError(
            400,
            "INVALID_DECISION_FOR_KIND",
            "accept_with_execpolicy_amendment 仅支持命令审批"
          );
        }

        if (!Array.isArray(execPolicyAmendment) || execPolicyAmendment.length === 0) {
          throw new HttpError(
            400,
            "INVALID_EXEC_POLICY_AMENDMENT",
            "decision=accept_with_execpolicy_amendment 时必须提供非空 execPolicyAmendment 数组"
          );
        }

        const sanitized = execPolicyAmendment.map((token) => {
          if (!isNonEmptyString(token)) {
            throw new HttpError(
              400,
              "INVALID_EXEC_POLICY_AMENDMENT",
              "execPolicyAmendment 只能包含非空字符串"
            );
          }
          return token;
        });

        return {
          acceptWithExecpolicyAmendment: {
            execpolicy_amendment: sanitized,
          },
        };
      }
      default:
        throw new HttpError(
          400,
          "INVALID_DECISION",
          "decision 必须是 accept/accept_for_session/accept_with_execpolicy_amendment/decline/cancel"
        );
    }
  }

  #toThreadDto(thread) {
    return {
      threadId: thread.id,
      preview: thread.preview,
      cwd: thread.cwd,
      createdAt: thread.createdAt,
      updatedAt: thread.updatedAt,
      modelProvider: thread.modelProvider,
    };
  }

  #toJobSnapshot(job) {
    return {
      jobId: job.jobId,
      threadId: job.threadId,
      turnId: job.turnId,
      state: job.state,
      pendingApprovalCount: job.pendingApprovalIds.size,
      createdAt: job.createdAt,
      updatedAt: job.updatedAt,
      terminalAt: job.terminalAt,
      errorMessage: job.errorMessage,
    };
  }

  #upsertThread(thread) {
    if (!thread || !isNonEmptyString(thread.id)) {
      return;
    }
    this.threads.set(thread.id, thread);
  }

  #validateThreadId(threadId) {
    if (!isNonEmptyString(threadId)) {
      throw new HttpError(400, "INVALID_THREAD_ID", "threadId 不能为空");
    }
  }

  #turnKey(threadId, turnId) {
    return `${threadId}::${turnId}`;
  }
}
