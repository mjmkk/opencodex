/**
 * Worker 核心服务
 *
 * 职责：
 * - 管理线程（Thread）和任务（Job）的生命周期
 * - 处理与 codex app-server 的 JSON-RPC 通信
 * - 实现任务状态机（QUEUED → RUNNING → DONE/FAILED/CANCELLED）
 * - 处理审批请求的接收和响应
 * - 管理事件流和订阅者
 *
 * 核心概念：
 * - Thread（线程）：一个会话上下文，绑定工作目录（cwd）
 * - Job（任务）：一次 turn 执行，从发消息到完成
 * - Turn（轮次）：与 AI 的一次对话交互
 * - Approval（审批）：执行命令或修改文件前的确认
 *
 * @module WorkerService
 * @see mvp-architecture.md 第 7 节 "Job 状态机"
 * @see mvp-architecture.md 第 8 节 "Worker 实现细节"
 */

import { HttpError } from "./errors.js";
import { createId } from "./ids.js";
import { mapDecisionToRpc } from "./worker-service/approval.js";
import {
  ACTIVE_STATES,
  RPC_EVENT_TYPE_MAP,
  SUPPORTED_EVENT_METHODS,
  TERMINAL_STATES,
  isNonEmptyString,
  normalizeApprovalPolicy,
  normalizeSandboxMode,
  nowIso,
  stripAnsi,
  toJobStateFromTurnStatus,
} from "./worker-service/shared.js";
import {
  buildThreadReplayEvents,
  normalizeThreadCursor,
  normalizeThreadEventsLimit,
  sliceThreadEventsByCursor,
} from "./worker-service/thread-events.js";

const PUSH_RELEVANT_EVENT_TYPES = new Set([
  "approval.required",
  "approval.resolved",
  "job.finished",
]);
const THREAD_EVENTS_CACHE_TTL_MS_DEFAULT = 5000;

// ==================== WorkerService 类 ====================

/**
 * Worker 核心服务类
 *
 * 管理整个 Worker 的业务逻辑，包括：
 * - 线程的创建、列表、激活
 * - 任务的启动、取消、查询
 * - 审批的接收、处理、响应
 * - 事件的存储、分发、订阅
 *
 * @example
 * const service = new WorkerService({ rpc, store, projectPaths });
 * await service.init();
 *
 * // 创建线程
 * const thread = await service.createThread({ projectPath: '/project' });
 *
 * // 发送消息
 * const job = await service.startTurn(thread.threadId, { text: 'hello' });
 *
 * // 订阅事件
 * service.subscribe(job.jobId, (event) => console.log(event));
 */
export class WorkerService {
  /**
   * 创建 Worker 服务实例
   *
   * @param {Object} options - 配置选项
   * @param {JsonRpcClient} options.rpc - JSON-RPC 客户端
   * @param {SqliteStore} [options.store] - 本地缓存存储（可选，不作为真相源）
   * @param {string[]} [options.projectPaths] - 项目路径白名单
   * @param {string} [options.defaultProjectPath] - 默认项目路径
   * @param {number} [options.eventRetention=2000] - 单任务保留事件数
   * @param {number} [options.threadEventsCacheTtlMs=5000] - 线程历史快照缓存 TTL（毫秒）
   * @param {Object} [options.pushNotifier] - 推送通知器（可选）
   * @param {Object} [options.logger] - 日志器
   */
  constructor(options) {
    // 外部依赖
    this.rpc = options.rpc;
    this.store = options.store ?? null;
    this.logger = options.logger ?? console;
    this.eventRetention = options.eventRetention ?? 2000;
    this.pushNotifier = options.pushNotifier ?? null;
    this.threadEventsCacheTtlMs = Number.isFinite(options.threadEventsCacheTtlMs)
      ? Math.max(0, Number(options.threadEventsCacheTtlMs))
      : THREAD_EVENTS_CACHE_TTL_MS_DEFAULT;

    // 处理项目路径配置
    const providedProjects = Array.isArray(options.projectPaths)
      ? options.projectPaths.filter(isNonEmptyString)
      : [];
    const uniqueProjects = [...new Set(providedProjects.map((path) => path.trim()))];
    // 如果没有配置项目路径，使用当前目录
    this.projectPaths = uniqueProjects.length > 0 ? uniqueProjects : [process.cwd()];
    this.defaultProjectPath = options.defaultProjectPath ?? this.projectPaths[0];

    // 运行时状态（内存缓存）
    this.threads = new Map();           // threadId -> thread 对象
    this.jobs = new Map();              // jobId -> job 对象
    this.loadedThreads = new Set();     // 已加载到 app-server 的线程 ID
    this.turnToJob = new Map();         // "threadId::turnId" -> jobId
    this.pendingJobByThread = new Map(); // threadId -> jobId（刚创建还没 turnId 的 job）
    this.approvals = new Map();         // approvalId -> approval 对象
    this.pushDevices = new Map();       // deviceToken -> push device
    this.threadEventsCache = new Map(); // threadId -> { events, builtAtMs }
    this.threadProjectionCache = new Map(); // threadId -> projection refresh timestamp(ms)

    // 初始化状态
    this.initialized = false;
    this.rpcEventsBound = false;
  }

  // ==================== 生命周期管理 ====================

  /**
   * 初始化服务
   *
   * 初始化流程：
   * 1. 绑定 RPC 事件处理器
   * 2. 启动子进程
   * 3. 发送 initialize 请求握手
   * 4. 发送 initialized 通知
   *
   * @returns {Promise<void>}
   */
  async init() {
    if (this.initialized) {
      return;
    }

    // 绑定事件处理器
    this.#bindRpcEvents();

    // 启动子进程
    if (typeof this.rpc.start === "function") {
      await this.rpc.start();
    }

    // JSON-RPC 握手：initialize -> initialized
    await this.rpc.request("initialize", {
      clientInfo: {
        name: "openclaw_worker_mvp",
        title: "OpenClaw Worker MVP",
        version: "0.1.0",
      },
      capabilities: null,
    });

    this.rpc.notify("initialized");

    if (this.store?.listPushDevices) {
      const cachedDevices = this.store.listPushDevices();
      for (const device of cachedDevices) {
        if (isNonEmptyString(device?.deviceToken)) {
          this.pushDevices.set(device.deviceToken, device);
        }
      }
    }

    this.initialized = true;
  }

  /**
   * 关闭服务
   *
   * @returns {Promise<void>}
   */
  async shutdown() {
    if (typeof this.rpc.stop === "function") {
      await this.rpc.stop();
    }
    this.initialized = false;
  }

  // ==================== 项目管理 ====================

  /**
   * 列出可用项目
   *
   * 返回 Worker 配置的项目路径白名单。
   * 每个项目包含：projectId、projectPath、displayName。
   *
   * @returns {Object[]} 项目列表
   *
   * @example
   * service.listProjects();
   * // [{ projectId: 'proj_1', projectPath: '/Users/me/project', displayName: 'project' }]
   */
  listProjects() {
    return this.projectPaths.map((projectPath, index) => ({
      projectId: `proj_${index + 1}`,
      projectPath,
      displayName: projectPath.split("/").filter(Boolean).pop() ?? projectPath,
    }));
  }

  // ==================== 线程管理 ====================

  /**
   * 创建新线程
   *
   * 调用 codex app-server 的 thread/start 方法创建线程。
   * 创建后线程自动加载到当前 app-server 进程。
   *
   * @param {Object} [payload={}] - 创建参数
   * @param {string} [payload.projectId] - 项目 ID（与 projectPath 二选一）
   * @param {string} [payload.projectPath] - 项目路径（与 projectId 二选一）
   * @param {string} [payload.threadName] - 线程名称（可选）
   * @param {string} [payload.approvalPolicy] - 审批策略（默认 on-request）
   * @param {string} [payload.sandbox] - 沙箱模式（默认 workspace-write）
   * @returns {Promise<Object>} 线程 DTO
   * @throws {HttpError} 如果参数无效或创建失败
   *
   * @example
   * const thread = await service.createThread({
   *   projectPath: '/Users/me/project',
   *   threadName: '我的线程',
   * });
   */
  async createThread(payload = {}) {
    // 解析项目路径
    const cwd = this.#resolveProjectPath(payload);
    const approvalPolicy = normalizeApprovalPolicy(payload.approvalPolicy) ?? "on-request";
    const sandbox = normalizeSandboxMode(payload.sandbox) ?? "workspace-write";

    // 调用 app-server 创建线程
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

    // 设置线程名称（如果提供）
    if (isNonEmptyString(payload.threadName)) {
      await this.rpc.request("thread/name/set", {
        threadId: thread.id,
        name: payload.threadName,
      });
    }

    // 更新内存缓存
    this.#upsertThread(thread);
    this.loadedThreads.add(thread.id);
    this.#invalidateThreadEventsCache(thread.id);

    // 持久化
    const dto = this.#toThreadDto(thread);
    this.store?.upsertThread?.(dto);
    return dto;
  }

  /**
   * 列出所有线程
   *
   * 调用 app-server 的 thread/list 方法获取线程列表。
   * 同时更新本地缓存。
   *
   * @returns {Promise<Object>} { data: ThreadDTO[], nextCursor: string|null }
   */
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

  /**
   * 激活（恢复）线程
   *
   * 将历史线程加载到当前 app-server 进程。
   * 这是对应 thread/resume 的包装。
   *
   * 注意：刚创建的线程已经在内存中，调用 resume 可能失败，
   * 所以需要先检查 loadedThreads。
   *
   * @param {string} threadId - 线程 ID
   * @returns {Promise<Object>} 线程 DTO
   * @throws {HttpError} 如果线程不存在或恢复失败
   */
  async activateThread(threadId) {
    this.#validateThreadId(threadId);

    // 如果线程已经加载，直接返回缓存
    // 调用 thread/resume 对已加载的线程可能失败
    if (this.loadedThreads.has(threadId)) {
      const existing = this.threads.get(threadId);
      if (existing) {
        return this.#toThreadDto(existing);
      }
      // 防御性：如果标记存在但缓存丢失，继续尝试 resume
    }

    // 调用 app-server 恢复线程
    const result = await this.rpc.request("thread/resume", {
      threadId,
      approvalPolicy: "on-request",
      sandbox: "workspace-write",
    });

    const thread = result.thread;
    if (!thread || !isNonEmptyString(thread.id)) {
      throw new HttpError(502, "INVALID_THREAD_RESPONSE", "thread/resume 返回了无效数据");
    }

    // 更新状态
    this.#upsertThread(thread);
    this.loadedThreads.add(threadId);
    this.#invalidateThreadEventsCache(threadId);

    const dto = this.#toThreadDto(thread);
    this.store?.upsertThread?.(dto);
    return dto;
  }

  // ==================== 任务管理 ====================

  /**
   * 启动新的对话轮次（创建 Job）
   *
   * 这是最核心的方法，流程：
   * 1. 检查线程是否有活跃任务（防止并发）
   * 2. 确保线程已加载
   * 3. 创建 Job 对象
   * 4. 调用 turn/start
   * 5. 更新 Job 状态
   *
   * @param {string} threadId - 线程 ID
   * @param {Object} [payload={}] - 请求参数
   * @param {string} [payload.text] - 文本消息
   * @param {Array} [payload.input] - 结构化输入（与 text 二选一）
   * @param {string} [payload.approvalPolicy] - 覆盖审批策略
   * @param {string} [payload.sandbox] - 覆盖沙箱模式
   * @returns {Promise<Object>} Job 快照
   * @throws {HttpError} 409 如果线程已有活跃任务
   */
  async startTurn(threadId, payload = {}) {
    this.#validateThreadId(threadId);
    const input = this.#normalizeTurnInput(payload);
    const approvalPolicy = normalizeApprovalPolicy(payload.approvalPolicy);
    const sandbox = normalizeSandboxMode(payload.sandbox);

    // 检查是否有活跃任务（防止同一线程并发执行）
    const activeJob = this.#findActiveJobByThread(threadId);
    if (activeJob) {
      throw new HttpError(
        409,
        "THREAD_HAS_ACTIVE_JOB",
        `线程 ${threadId} 已有进行中的任务 ${activeJob.jobId}`
      );
    }

    // 确保线程已加载（懒加载）
    await this.#ensureThreadLoaded(threadId);

    // 创建 Job 对象
    const job = this.#createJob(threadId);
    this.pendingJobByThread.set(threadId, job.jobId);

    // 记录事件
    this.#appendEvent(job, "job.created", { threadId });
    this.#appendEvent(job, "job.state", { state: "QUEUED" });

    try {
      // 调用 app-server 开始 turn
      const response = await this.rpc.request("turn/start", {
        threadId,
        input,
        ...(approvalPolicy ? { approvalPolicy } : {}),
        ...(sandbox ? { sandbox } : {}),
      });

      // 记录 turnId
      const turnId = response?.turn?.id;
      if (isNonEmptyString(turnId)) {
        job.turnId = turnId;
        this.turnToJob.set(this.#turnKey(threadId, turnId), job.jobId);
      }

      // 更新状态为运行中
      this.#setJobState(job, "RUNNING");
      return this.#toJobSnapshot(job);
    } catch (error) {
      // 失败处理
      job.errorMessage = error.message;
      this.#appendEvent(job, "error", { message: error.message });
      this.#setJobState(job, "FAILED");
      throw error;
    } finally {
      // 清理 pending 标记
      const pendingJobId = this.pendingJobByThread.get(threadId);
      if (pendingJobId === job.jobId) {
        this.pendingJobByThread.delete(threadId);
      }
    }
  }

  /**
   * 获取任务快照
   *
   * 仅从内存读取任务状态。
   * 真相源为 app-server；SQLite 仅用于缓存，不参与此接口读路径。
   *
   * @param {string} jobId - 任务 ID
   * @returns {Object} Job 快照
   * @throws {HttpError} 404 如果任务不存在
   */
  getJob(jobId) {
    const job = this.jobs.get(jobId);
    if (job) {
      return this.#toJobSnapshot(job);
    }
    throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
  }

  /**
   * 获取任务事件列表
   *
   * 支持游标（cursor）分页，用于 SSE 断线续流。
   * 该接口仅读取当前 Worker 进程内任务事件，不从 SQLite 回放旧数据。
   * SQLite 仅作为线程历史的降级缓存（见 listThreadEvents）。
   *
   * @param {string} jobId - 任务 ID
   * @param {number|null} [cursor=null] - 游标，返回 seq > cursor 的事件
   * @returns {Object} { data: Event[], nextCursor: number, firstSeq: number, job?: JobSnapshot }
   * @throws {HttpError} 404 如果任务不存在
   * @throws {HttpError} 409 如果游标已过期
   */
  listEvents(jobId, cursor = null) {
    // 内存读路径（权威）
    const job = this.jobs.get(jobId);
    if (!job) {
      throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
    }

    // 标准化游标
    let normalizedCursor = cursor;
    if (normalizedCursor === null || normalizedCursor === undefined) {
      normalizedCursor = job.firstSeq - 1;
    } else if (!Number.isInteger(normalizedCursor)) {
      throw new HttpError(400, "INVALID_CURSOR", "cursor 必须是整数");
    }

    // 检查游标是否过期
    if (normalizedCursor < job.firstSeq - 1) {
      throw new HttpError(409, "CURSOR_EXPIRED", "cursor 已过期，请先拉取任务快照再重连");
    }

    // 过滤事件
    const data = job.events.filter((event) => event.seq > normalizedCursor);
    const nextCursor = data.length > 0 ? data[data.length - 1].seq : normalizedCursor;

    return {
      data,
      nextCursor,
      firstSeq: job.firstSeq,
    };
  }

  /**
   * 订阅任务事件
   *
   * 返回一个取消订阅函数。
   *
   * @param {string} jobId - 任务 ID
   * @param {Function} listener - 事件监听器，接收 envelope 参数
   * @returns {Function} 取消订阅函数
   * @throws {HttpError} 404 如果任务不存在
   *
   * @example
   * const unsubscribe = service.subscribe(jobId, (event) => {
   *   console.log('收到事件:', event.type);
   * });
   * // 取消订阅
   * unsubscribe();
   */
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

  /**
   * 获取线程的历史事件
   *
   * 用于在切换线程时回放历史消息。
   *
   * @param {string} threadId - 线程 ID
   * @param {Object} [options={}] - 分页参数
   * @param {number|null} [options.cursor=null] - 线程级游标，返回游标之后的事件
   * @param {number} [options.limit=200] - 分页大小，最大 1000
   * @returns {Promise<Object>} { data: Event[], nextCursor: number, hasMore: boolean }
   *
   * 性能策略：
   * - P1 读模型：同一线程先刷新 SQLite 线程事件投影，再走 O(pageSize) 分页查询。
   * - 同一线程短时间分页请求复用投影刷新结果，避免每页重复 thread/read。
   * - 线程有新事件写入时立即失效缓存，保证活跃会话实时性。
   */
  async listThreadEvents(threadId, options = {}) {
    this.#validateThreadId(threadId);
    const normalizedCursor = normalizeThreadCursor(options.cursor);
    const limit = normalizeThreadEventsLimit(options.limit);
    const canUseProjection = this.#supportsThreadEventsProjectionStore();

    if (canUseProjection) {
      const projectionReady = await this.#refreshThreadEventsProjection(threadId);
      let page = this.store.listThreadEventsProjectionPage(threadId, normalizedCursor, limit);
      if (this.#shouldRetryProjectionRead(page, normalizedCursor)) {
        await this.#refreshThreadEventsProjection(threadId, { forceRefresh: true });
        page = this.store.listThreadEventsProjectionPage(threadId, normalizedCursor, limit);
      }
      if (page && Number.isInteger(page.total)) {
        if (!(!projectionReady && page.total === 0)) {
          if (page.total > 0 && normalizedCursor >= page.total) {
            throw new HttpError(
              409,
              "THREAD_CURSOR_EXPIRED",
              `cursor=${normalizedCursor} 超出当前线程历史范围（total=${page.total}）`
            );
          }
          return {
            data: page.data,
            nextCursor: page.nextCursor,
            hasMore: page.hasMore,
          };
        }
      }

      // 读模型路径异常时，回退旧路径（不影响可用性）。
      if (projectionReady && typeof this.logger?.warn === "function") {
        this.logger.warn(`[thread-events] projection page unavailable, fallback snapshot: threadId=${threadId}`);
      }
    }

    let events = await this.#getThreadEventsSnapshot(threadId);

    // 缓存快照可能在极端场景下过旧，游标看起来“越界”时强制刷新一次再判定是否过期。
    if (normalizedCursor >= events.length) {
      events = await this.#getThreadEventsSnapshot(threadId, { forceRefresh: true });
    }

    return sliceThreadEventsByCursor(events, normalizedCursor, limit);
  }

  // ==================== 审批管理 ====================

  /**
   * 提交审批决策
   *
   * 这是审批流程的核心方法，处理用户对审批的响应。
   *
   * 支持的决策：
   * - accept：接受本次
   * - accept_for_session：会话内全部接受
   * - accept_with_execpolicy_amendment：接受并修改命令（仅命令审批）
   * - decline：拒绝
   * - cancel：取消任务
   *
   * 幂等性：重复提交返回首次结果，不会重复执行。
   *
   * @param {string} jobId - 任务 ID
   * @param {Object} payload - 请求体
   * @param {string} payload.approvalId - 审批 ID
   * @param {string} payload.decision - 决策值
   * @param {string[]} [payload.execPolicyAmendment] - 修改后的命令（仅用于 accept_with_execpolicy_amendment）
   * @param {string} [payload.declineReason] - 拒绝原因（可选，兼容 decline_reason）
   * @returns {Promise<Object>} { approvalId, status, decision }
   * @throws {HttpError} 404 如果审批不存在或不属于该任务
   */
  async approve(jobId, payload = {}) {
    const job = this.jobs.get(jobId);
    if (!job) {
      throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
    }

    // 兼容不同客户端字段风格（camelCase / snake_case）。
    const approvalId = payload.approvalId ?? payload.approval_id;
    if (!isNonEmptyString(approvalId)) {
      throw new HttpError(400, "INVALID_APPROVAL_ID", "approvalId 不能为空");
    }

    const approval = this.approvals.get(approvalId);
    if (!approval || approval.jobId !== jobId) {
      throw new HttpError(404, "APPROVAL_NOT_FOUND", `审批 ${approvalId} 不存在或不属于任务 ${jobId}`);
    }

    // 幂等性检查：已决策的审批直接返回
    if (approval.decisionResult) {
      return {
        approvalId,
        status: "already_submitted",
        decision: approval.decisionText,
      };
    }

    // 转换决策格式
    const decisionText = payload.decision;
    const execPolicyAmendment =
      payload.execPolicyAmendment ?? payload.exec_policy_amendment;
    const declineReasonRaw = payload.declineReason ?? payload.decline_reason;
    const declineReason = isNonEmptyString(declineReasonRaw)
      ? declineReasonRaw.trim()
      : null;
    const decisionResult = mapDecisionToRpc(
      approval.kind,
      decisionText,
      execPolicyAmendment
    );

    // 响应服务端请求
    this.rpc.respond(approval.requestId, {
      decision: decisionResult,
    });

    // 更新审批状态
    approval.decisionResult = decisionResult;
    approval.decisionText = decisionText;
    approval.decidedAt = nowIso();

    // 记录事件
    this.#appendEvent(job, "approval.resolved", {
      approvalId,
      decision: decisionText,
      decidedAt: approval.decidedAt,
      ...(declineReason ? { declineReason } : {}),
    });

    // 持久化决策
    const extraPayload = {};
    if (execPolicyAmendment) {
      extraPayload.execPolicyAmendment = execPolicyAmendment;
    }
    if (declineReason) {
      extraPayload.declineReason = declineReason;
    }
    this.store?.insertDecision?.({
      approvalId,
      decision: decisionText,
      decidedAt: approval.decidedAt,
      actor: "api",
      extra: Object.keys(extraPayload).length > 0 ? extraPayload : null,
    });

    // 更新 Job 状态
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

  /**
   * 取消任务
   *
   * 发送 turn/interrupt 请求中断正在执行的任务。
   * 幂等性：终态任务直接返回当前快照。
   *
   * @param {string} jobId - 任务 ID
   * @returns {Promise<Object>} Job 快照
   */
  async cancel(jobId) {
    const job = this.jobs.get(jobId);
    if (!job) {
      throw new HttpError(404, "JOB_NOT_FOUND", `任务 ${jobId} 不存在`);
    }

    // 终态任务无需取消
    if (TERMINAL_STATES.has(job.state)) {
      return this.#toJobSnapshot(job);
    }

    // 没有 turnId 的任务直接标记取消
    if (!isNonEmptyString(job.turnId)) {
      this.#setJobState(job, "CANCELLED");
      return this.#toJobSnapshot(job);
    }

    // 发送中断请求
    await this.rpc.request("turn/interrupt", {
      threadId: job.threadId,
      turnId: job.turnId,
    });

    return this.#toJobSnapshot(job);
  }

  // ==================== 推送设备管理 ====================

  /**
   * 注册（或刷新）推送设备
   *
   * @param {Object} payload
   * @returns {Object}
   */
  registerPushDevice(payload = {}) {
    const deviceToken = this.#normalizeDeviceToken(payload.deviceToken ?? payload.device_token);
    if (!deviceToken) {
      throw new HttpError(400, "INVALID_DEVICE_TOKEN", "deviceToken 无效");
    }

    const platform = this.#normalizePushPlatform(payload.platform);
    const environment = this.#normalizePushEnvironment(payload.environment);
    const bundleId = isNonEmptyString(payload.bundleId ?? payload.bundle_id)
      ? (payload.bundleId ?? payload.bundle_id).trim()
      : null;
    const deviceName = isNonEmptyString(payload.deviceName ?? payload.device_name)
      ? (payload.deviceName ?? payload.device_name).trim()
      : null;

    const now = nowIso();
    const existing = this.pushDevices.get(deviceToken);
    const device = {
      deviceToken,
      platform,
      bundleId,
      environment,
      deviceName,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
      lastSeenAt: now,
    };

    this.pushDevices.set(deviceToken, device);
    this.store?.upsertPushDevice?.(device);

    return {
      status: "registered",
      device,
    };
  }

  /**
   * 注销推送设备
   *
   * @param {Object} payload
   * @returns {Object}
   */
  unregisterPushDevice(payload = {}) {
    const deviceToken = this.#normalizeDeviceToken(payload.deviceToken ?? payload.device_token);
    if (!deviceToken) {
      throw new HttpError(400, "INVALID_DEVICE_TOKEN", "deviceToken 无效");
    }
    const existed = this.pushDevices.delete(deviceToken);
    this.store?.removePushDevice?.(deviceToken);

    return {
      status: existed ? "unregistered" : "not_found",
      deviceToken,
    };
  }

  // ==================== RPC 事件处理 ====================

  /**
   * 绑定 RPC 事件处理器
   * @private
   */
  #bindRpcEvents() {
    if (this.rpcEventsBound) {
      return;
    }

    // 处理通知（turn/started, turn/completed, item/delta 等）
    this.rpc.on("notification", (message) => {
      this.#handleRpcNotification(message);
    });

    // 处理服务端请求（审批请求）
    this.rpc.on("request", (message) => {
      this.#handleRpcRequest(message);
    });

    // 处理 stderr 输出
    this.rpc.on("stderr", (line) => {
      const cleaned = stripAnsi(line);
      // 默认过滤 codex app-server 的 rollout 噪音（不影响核心 MVP 闭环）
      // 如需排查，可设置 WORKER_SHOW_APP_SERVER_ROLLOUT_WARNINGS=1
      const showRolloutWarnings = process.env.WORKER_SHOW_APP_SERVER_ROLLOUT_WARNINGS === "1";
      if (
        !showRolloutWarnings &&
        (cleaned.includes("Falling back on rollout system") ||
          cleaned.includes("state db missing rollout path for thread"))
      ) {
        return;
      }
      this.logger.warn(`[app-server] ${cleaned}`);
    });

    // 协议错误
    this.rpc.on("protocolError", (event) => {
      this.logger.error("收到无效协议消息", event);
    });

    // 子进程退出
    this.rpc.on("exit", (event) => {
      this.logger.error("app-server 进程退出", event);
    });

    this.rpcEventsBound = true;
  }

  /**
   * 处理 JSON-RPC 通知
   *
   * 处理 app-server 推送的事件通知，包括：
   * - turn/started: 轮次开始
   * - turn/completed: 轮次完成（终态）
   * - item/*: 项目事件（消息、命令输出等）
   * - error: 错误
   *
   * @private
   * @param {Object} message - JSON-RPC 通知消息
   */
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

    // turn/started: 记录 turnId，更新状态
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

    // turn/completed: 终态，更新 Job 状态
    if (method === "turn/completed") {
      this.#appendEvent(job, "turn.completed", params);

      const finalState = toJobStateFromTurnStatus(params?.turn?.status);
      if (finalState === "FAILED" && isNonEmptyString(params?.turn?.error?.message)) {
        job.errorMessage = params.turn.error.message;
      }
      this.#setJobState(job, finalState);
      return;
    }

    // error: 记录错误消息
    if (method === "error") {
      if (isNonEmptyString(params?.error?.message)) {
        job.errorMessage = params.error.message;
      }
      this.#appendEvent(job, "error", params);
      return;
    }

    const mappedType = RPC_EVENT_TYPE_MAP[method];
    if (mappedType) {
      this.#appendEvent(job, mappedType, params);
    }
  }

  /**
   * 处理 JSON-RPC 服务端请求
   *
   * 主要是审批请求：
   * - item/commandExecution/requestApproval: 命令执行审批
   * - item/fileChange/requestApproval: 文件变更审批
   *
   * @private
   * @param {Object} message - JSON-RPC 请求消息
   */
  #handleRpcRequest(message) {
    const { id: requestId, method, params } = message;

    // 只处理审批请求
    if (
      method !== "item/commandExecution/requestApproval" &&
      method !== "item/fileChange/requestApproval"
    ) {
      this.rpc.respondError(requestId, -32601, `Unsupported server request: ${method}`);
      return;
    }

    // 判断审批类型
    const kind =
      method === "item/commandExecution/requestApproval"
        ? "command_execution"
        : "file_change";

    const threadId = params?.threadId;
    const turnId = params?.turnId;

    // 定位对应的 Job
    const job = this.#locateJob(threadId, turnId);
    if (!job) {
      this.rpc.respondError(requestId, -32000, "No active job matches this approval request");
      return;
    }

    // 创建审批记录
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

    // 更新状态
    this.approvals.set(approvalId, approval);
    job.pendingApprovalIds.add(approvalId);

    // 更新 Job 状态为等待审批
    this.#setJobState(job, "WAITING_APPROVAL");

    // 持久化审批
    this.store?.insertApproval?.(approval);

    // 发送审批事件给客户端
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

  // ==================== 私有辅助方法 ====================

  #supportsThreadEventsProjectionStore() {
    return Boolean(
      this.store?.replaceThreadEventsProjection &&
      this.store?.listThreadEventsProjectionPage
    );
  }

  async #refreshThreadEventsProjection(threadId, options = {}) {
    if (!this.#supportsThreadEventsProjectionStore()) {
      return false;
    }
    const forceRefresh = options.forceRefresh === true;
    if (!forceRefresh && this.#isThreadProjectionFresh(threadId)) {
      return true;
    }
    try {
      const events = await this.#loadThreadEventsFromSourceOfTruth(threadId);
      this.store.replaceThreadEventsProjection(threadId, events);
      this.#markThreadProjectionFresh(threadId);
      this.#writeThreadEventsCache(threadId, events);
      return true;
    } catch (error) {
      if (typeof this.logger?.warn === "function") {
        const message = error instanceof Error ? error.message : String(error);
        this.logger.warn(`[thread-events] projection refresh failed: threadId=${threadId}, error=${message}`);
      }
      return false;
    }
  }

  #shouldRetryProjectionRead(page, cursor) {
    if (!page || !Number.isInteger(page.total)) {
      return true;
    }
    return page.total > 0 && cursor >= page.total;
  }

  async #loadThreadEventsFromSourceOfTruth(threadId) {
    await this.#ensureThreadLoaded(threadId);
    const result = await this.rpc.request("thread/read", {
      threadId,
      includeTurns: true,
    });
    const turns = Array.isArray(result?.thread?.turns) ? result.thread.turns : [];
    const replayEvents = buildThreadReplayEvents({
      threadId,
      turns,
      turnToJob: this.turnToJob,
      turnKey: (currentThreadId, turnId) => this.#turnKey(currentThreadId, turnId),
    });
    const activeJob = this.#findActiveJobByThread(threadId);
    return this.#sanitizeThreadEvents(
      this.#mergeThreadReplayWithActiveJobEvents(replayEvents, activeJob?.events ?? [])
    );
  }

  async #getThreadEventsSnapshot(threadId, options = {}) {
    const forceRefresh = options.forceRefresh === true;
    if (!forceRefresh) {
      const cachedEvents = this.#readThreadEventsCache(threadId);
      if (cachedEvents) {
        return cachedEvents;
      }
    }

    let events = [];
    try {
      events = await this.#loadThreadEventsFromSourceOfTruth(threadId);
    } catch (error) {
      if (typeof this.logger?.warn === "function") {
        const message = error instanceof Error ? error.message : String(error);
        this.logger.warn(`[thread-events] thread/read 失败，回退 SQLite 缓存: threadId=${threadId}, error=${message}`);
      }
      if (this.store?.listEventsByThread) {
        const fallbackEvents = this.store.listEventsByThread(threadId);
        if (Array.isArray(fallbackEvents)) {
          events = this.#sanitizeThreadEvents(fallbackEvents);
        }
      }
    }
    this.#writeThreadEventsCache(threadId, events);
    return events;
  }

  #sanitizeThreadEvents(events) {
    if (!Array.isArray(events)) {
      return [];
    }
    return events.filter((event) => (
      event &&
      isNonEmptyString(event.type) &&
      isNonEmptyString(event.jobId) &&
      Number.isInteger(event.seq)
    ));
  }

  #isThreadProjectionFresh(threadId) {
    const builtAtMs = this.threadProjectionCache.get(threadId);
    if (!Number.isFinite(builtAtMs)) {
      return false;
    }
    if (this.threadEventsCacheTtlMs <= 0) {
      this.threadProjectionCache.delete(threadId);
      return false;
    }
    if (Date.now() - builtAtMs > this.threadEventsCacheTtlMs) {
      this.threadProjectionCache.delete(threadId);
      return false;
    }
    return true;
  }

  #markThreadProjectionFresh(threadId) {
    if (this.threadEventsCacheTtlMs <= 0) {
      return;
    }
    this.threadProjectionCache.set(threadId, Date.now());
  }

  #mergeThreadReplayWithActiveJobEvents(replayEvents, activeJobEvents) {
    const merged = [...(Array.isArray(replayEvents) ? replayEvents : [])];
    if (Array.isArray(activeJobEvents) && activeJobEvents.length > 0) {
      merged.push(...activeJobEvents);
    }

    const deduped = [];
    const seen = new Set();
    for (const event of merged) {
      if (!event || !isNonEmptyString(event.type) || !isNonEmptyString(event.jobId)) {
        continue;
      }
      const seq = Number.isInteger(event.seq) ? event.seq : -1;
      const key = `${event.jobId}:${seq}:${event.type}`;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      deduped.push(event);
    }
    return deduped;
  }

  #readThreadEventsCache(threadId) {
    const entry = this.threadEventsCache.get(threadId);
    if (!entry) {
      return null;
    }
    if (this.threadEventsCacheTtlMs <= 0) {
      this.threadEventsCache.delete(threadId);
      return null;
    }
    if (Date.now() - entry.builtAtMs > this.threadEventsCacheTtlMs) {
      this.threadEventsCache.delete(threadId);
      return null;
    }
    return entry.events;
  }

  #writeThreadEventsCache(threadId, events) {
    if (this.threadEventsCacheTtlMs <= 0) {
      return;
    }
    this.threadEventsCache.set(threadId, {
      events,
      builtAtMs: Date.now(),
    });
  }

  #invalidateThreadEventsCache(threadId = null) {
    if (isNonEmptyString(threadId)) {
      this.threadEventsCache.delete(threadId);
      this.threadProjectionCache.delete(threadId);
      return;
    }
    this.threadEventsCache.clear();
    this.threadProjectionCache.clear();
  }

  #normalizeDeviceToken(rawDeviceToken) {
    if (!isNonEmptyString(rawDeviceToken)) {
      return null;
    }
    const normalized = rawDeviceToken.trim().toLowerCase();
    if (!/^[0-9a-f]{64,512}$/.test(normalized)) {
      return null;
    }
    return normalized;
  }

  #normalizePushPlatform(rawPlatform) {
    if (!isNonEmptyString(rawPlatform)) {
      return "ios";
    }
    const platform = rawPlatform.trim().toLowerCase();
    if (platform !== "ios") {
      throw new HttpError(400, "INVALID_PUSH_PLATFORM", "platform 仅支持 ios");
    }
    return "ios";
  }

  #normalizePushEnvironment(rawEnvironment) {
    if (!isNonEmptyString(rawEnvironment)) {
      return "sandbox";
    }
    const normalized = rawEnvironment.trim().toLowerCase();
    if (normalized === "sandbox" || normalized === "development" || normalized === "dev") {
      return "sandbox";
    }
    if (normalized === "production" || normalized === "prod") {
      return "production";
    }
    throw new HttpError(400, "INVALID_PUSH_ENVIRONMENT", "environment 仅支持 sandbox/production");
  }

  #dispatchPushNotification(job, envelope) {
    if (!this.pushNotifier) {
      return;
    }
    if (!PUSH_RELEVANT_EVENT_TYPES.has(envelope.type)) {
      return;
    }
    if (this.pushDevices.size === 0) {
      return;
    }

    const devices = [...this.pushDevices.values()].filter((device) => device.platform === "ios");
    if (devices.length === 0) {
      return;
    }

    const thread = this.threads.get(job.threadId) ?? null;
    Promise.resolve(
      this.pushNotifier.notify({
        envelope,
        job: this.#toJobSnapshot(job),
        thread,
        devices,
      })
    )
      .then((result) => {
        const invalidDeviceTokens = Array.isArray(result?.invalidDeviceTokens)
          ? result.invalidDeviceTokens
          : [];
        for (const deviceToken of invalidDeviceTokens) {
          this.pushDevices.delete(deviceToken);
          this.store?.removePushDevice?.(deviceToken);
        }
      })
      .catch((error) => {
        const message = error instanceof Error ? error.message : String(error);
        this.logger.warn?.(`[push] 推送失败: ${message}`);
      });
  }

  /**
   * 解析项目路径
   *
   * 支持 projectId 或 projectPath，二选一。
   * 都不传时使用默认项目路径。
   *
   * @private
   * @param {Object} payload - 请求参数
   * @returns {string} 项目路径
   * @throws {HttpError} 如果参数无效或项目不在白名单
   */
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

  /**
   * 标准化 turn 输入
   *
   * 支持两种格式：
   * - text: 简单文本消息
   * - input: 结构化输入数组
   *
   * @private
   * @param {Object} payload - 请求参数
   * @returns {Array} 标准化后的输入数组
   * @throws {HttpError} 如果输入为空
   */
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

  /**
   * 确保线程已加载
   *
   * 如果线程未加载，自动调用 activateThread。
   *
   * @private
   * @param {string} threadId - 线程 ID
   */
  async #ensureThreadLoaded(threadId) {
    if (this.loadedThreads.has(threadId)) {
      return;
    }
    await this.activateThread(threadId);
  }

  /**
   * 创建 Job 对象
   *
   * @private
   * @param {string} threadId - 线程 ID
   * @returns {Object} Job 对象
   */
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

  /**
   * 设置 Job 状态
   *
   * 状态变化时：
   * 1. 更新 updatedAt
   * 2. 如果是终态，设置 terminalAt
   * 3. 记录 job.state 事件
   * 4. 如果是终态，记录 job.finished 事件
   * 5. 持久化
   *
   * @private
   * @param {Object} job - Job 对象
   * @param {string} state - 新状态
   */
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

    // 终态时发送 job.finished 事件
    if (TERMINAL_STATES.has(state) && !job.finishedEmitted) {
      this.#appendEvent(job, "job.finished", {
        state,
        errorMessage: job.errorMessage,
      });
      job.finishedEmitted = true;
    }

    this.store?.updateJob?.(this.#toJobSnapshot(job));
  }

  /**
   * 追加事件
   *
   * 事件格式：
   * {
   *   type: string,      // 事件类型
   *   ts: string,        // ISO 时间戳
   *   jobId: string,     // 任务 ID
   *   seq: number,       // 序列号（严格递增）
   *   payload: any       // 事件负载
   * }
   *
   * @private
   * @param {Object} job - Job 对象
   * @param {string} type - 事件类型
   * @param {Object} payload - 事件负载
   */
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
    this.#invalidateThreadEventsCache(job.threadId);

    // 事件保留策略：超过限制时删除旧事件
    if (job.events.length > this.eventRetention) {
      while (job.events.length > this.eventRetention) {
        job.events.shift();
      }
      job.firstSeq = job.events[0]?.seq ?? envelope.seq;
    }

    // 通知所有订阅者
    for (const listener of job.subscribers) {
      listener(envelope);
    }

    // 持久化
    this.store?.appendEvent?.(envelope);

    // 触发远程推送（异步，不阻塞主流程）
    this.#dispatchPushNotification(job, envelope);
  }

  /**
   * 定位 Job
   *
   * 查找策略（按优先级）：
   * 1. 通过 turnId 查找（最精确）
   * 2. 通过 pendingJobByThread 查找（刚创建还没 turnId）
   * 3. 查找线程的活跃 Job（兜底）
   *
   * @private
   * @param {string} threadId - 线程 ID
   * @param {string} [turnId] - 轮次 ID
   * @returns {Object|null} Job 对象或 null
   */
  #locateJob(threadId, turnId) {
    if (!isNonEmptyString(threadId)) {
      return null;
    }

    // 策略 1：通过 turnId 查找
    if (isNonEmptyString(turnId)) {
      const byTurn = this.turnToJob.get(this.#turnKey(threadId, turnId));
      if (byTurn) {
        return this.jobs.get(byTurn) ?? null;
      }
    }

    // 策略 2：通过 pending 标记查找
    const pendingJobId = this.pendingJobByThread.get(threadId);
    if (pendingJobId) {
      const pendingJob = this.jobs.get(pendingJobId);
      if (pendingJob) {
        // 如果有 turnId 但 job 还没有，补上
        if (isNonEmptyString(turnId) && !isNonEmptyString(pendingJob.turnId)) {
          pendingJob.turnId = turnId;
          this.turnToJob.set(this.#turnKey(threadId, turnId), pendingJob.jobId);
        }
        return pendingJob;
      }
    }

    // 策略 3：查找线程的活跃 Job
    return this.#findActiveJobByThread(threadId) ?? null;
  }

  /**
   * 查找线程的活跃 Job
   *
   * 遍历所有 job，找到属于该线程且状态为活跃的 job。
   * 如果有多个，返回最新创建的。
   *
   * @private
   * @param {string} threadId - 线程 ID
   * @returns {Object|null} Job 对象或 null
   */
  #findActiveJobByThread(threadId) {
    let found = null;
    for (const job of this.jobs.values()) {
      if (job.threadId !== threadId) {
        continue;
      }
      if (!ACTIVE_STATES.has(job.state)) {
        continue;
      }
      // 返回最新的
      if (!found || job.createdAtMs > found.createdAtMs) {
        found = job;
      }
    }
    return found;
  }

  /**
   * 将 thread 对象转换为 DTO
   *
   * @private
   * @param {Object} thread - 原始 thread 对象
   * @returns {Object} Thread DTO
   */
  #toThreadDto(thread) {
    const activeJob = this.#findActiveJobByThread(thread.id);
    const pendingApprovalCount = activeJob?.pendingApprovalIds?.size ?? 0;
    return {
      threadId: thread.id,
      preview: thread.preview,
      cwd: thread.cwd,
      createdAt: thread.createdAt,
      updatedAt: thread.updatedAt,
      modelProvider: thread.modelProvider,
      pendingApprovalCount,
    };
  }

  /**
   * 将 job 对象转换为快照
   *
   * @private
   * @param {Object} job - Job 对象
   * @returns {Object} Job 快照
   */
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

  /**
   * 更新或插入线程到缓存
   *
   * @private
   * @param {Object} thread - 线程对象
   */
  #upsertThread(thread) {
    if (!thread || !isNonEmptyString(thread.id)) {
      return;
    }
    this.threads.set(thread.id, thread);
  }

  /**
   * 验证线程 ID
   *
   * @private
   * @param {string} threadId - 线程 ID
   * @throws {HttpError} 如果线程 ID 为空
   */
  #validateThreadId(threadId) {
    if (!isNonEmptyString(threadId)) {
      throw new HttpError(400, "INVALID_THREAD_ID", "threadId 不能为空");
    }
  }

  /**
   * 生成 turn 键
   *
   * @private
   * @param {string} threadId - 线程 ID
   * @param {string} turnId - 轮次 ID
   * @returns {string} "threadId::turnId"
   */
  #turnKey(threadId, turnId) {
    return `${threadId}::${turnId}`;
  }
}
