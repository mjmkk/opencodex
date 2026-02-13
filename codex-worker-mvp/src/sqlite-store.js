/**
 * SQLite 持久化存储模块
 *
 * 职责：
 * - 持久化线程、任务、事件、审批数据
 * - 支持事件回放（断线重连、Worker 重启后追溯）
 * - 提供审计日志基础
 *
 * 设计原则：
 * - append-only 事件日志：事件只追加，不修改
 * - 幂等操作：重复插入不报错
 * - 外键约束：保证数据完整性
 *
 * @module SqliteStore
 * @see mvp-architecture.md 第 8.3 节 "持久化最小结构"
 */

import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

/**
 * SQLite 持久化存储类
 *
 * 使用 better-sqlite3 库，提供同步的 SQLite API。
 * 采用 WAL（Write-Ahead Logging）模式提高并发性能。
 *
 * @example
 * const store = new SqliteStore({ dbPath: './data/worker.db' });
 * store.init();
 *
 * // 插入数据
 * store.insertJob({ jobId: 'job_123', ... });
 * store.appendEvent({ jobId: 'job_123', seq: 0, type: 'job.created', ... });
 *
 * // 查询数据
 * const job = store.getJob('job_123');
 * const events = store.listEvents('job_123', 0);
 *
 * // 关闭连接
 * store.close();
 */
export class SqliteStore {
  /**
   * 创建存储实例
   *
   * @param {Object} options - 配置选项
   * @param {string} options.dbPath - 数据库文件路径
   *   - 文件路径：如 './data/worker.db'
   *   - 内存模式：':memory:'（仅用于测试）
   * @param {Object} [options.logger] - 日志器
   * @param {number} [options.eventPageLimit=2000] - 单次查询事件数限制
   */
  constructor(options) {
    this.dbPath = options.dbPath;
    this.logger = options.logger ?? console;
    this.eventPageLimit = options.eventPageLimit ?? 2000;

    /** @type {Database|null} 数据库实例 */
    this.db = null;
    /** @type {Object|null} 预编译语句集合 */
    this.stmt = null;
  }

  /**
   * 初始化数据库
   *
   * 流程：
   * 1. 创建数据库目录（如果不存在）
   * 2. 打开数据库连接
   * 3. 设置 WAL 模式和外键约束
   * 4. 创建表结构（如果不存在）
   * 5. 准备预编译语句
   *
   * @throws {Error} 如果 dbPath 无效
   */
  init() {
    if (this.db) {
      return;
    }

    // 验证 dbPath
    if (!this.dbPath || typeof this.dbPath !== "string") {
      throw new Error("SqliteStore requires dbPath");
    }

    // 创建目录（非内存模式）
    if (this.dbPath !== ":memory:") {
      mkdirSync(dirname(this.dbPath), { recursive: true });
    }

    // 打开数据库
    const db = new Database(this.dbPath);

    // 设置 PRAGMA
    db.pragma("journal_mode = WAL");      // WAL 模式：提高并发性能
    db.pragma("foreign_keys = ON");       // 启用外键约束

    // 创建表结构
    db.exec(`
      -- 线程表
      CREATE TABLE IF NOT EXISTS threads (
        threadId TEXT PRIMARY KEY,
        cwd TEXT,
        preview TEXT,
        createdAt INTEGER,
        updatedAt INTEGER,
        modelProvider TEXT
      );

      -- 任务表
      CREATE TABLE IF NOT EXISTS jobs (
        jobId TEXT PRIMARY KEY,
        threadId TEXT NOT NULL,
        turnId TEXT,
        state TEXT NOT NULL,
        pendingApprovalCount INTEGER NOT NULL DEFAULT 0,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        terminalAt TEXT,
        errorMessage TEXT
      );

      -- 任务事件表（append-only）
      CREATE TABLE IF NOT EXISTS job_events (
        jobId TEXT NOT NULL,
        seq INTEGER NOT NULL,
        type TEXT NOT NULL,
        ts TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        PRIMARY KEY(jobId, seq),
        FOREIGN KEY(jobId) REFERENCES jobs(jobId) ON DELETE CASCADE
      );

      -- 审批表
      CREATE TABLE IF NOT EXISTS approvals (
        approvalId TEXT PRIMARY KEY,
        jobId TEXT NOT NULL,
        threadId TEXT NOT NULL,
        turnId TEXT,
        itemId TEXT,
        kind TEXT NOT NULL,
        request_method TEXT NOT NULL,
        request_id INTEGER NOT NULL,
        createdAt TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        FOREIGN KEY(jobId) REFERENCES jobs(jobId) ON DELETE CASCADE
      );

      -- 审批决策表（幂等闸门）
      CREATE TABLE IF NOT EXISTS approval_decisions (
        approvalId TEXT PRIMARY KEY,
        decision TEXT NOT NULL,
        decidedAt TEXT NOT NULL,
        actor TEXT NOT NULL,
        extra_json TEXT
      );
    `);

    // 准备预编译语句（提高性能，防止 SQL 注入）
    this.stmt = {
      // 线程操作
      upsertThread: db.prepare(`
        INSERT INTO threads(threadId, cwd, preview, createdAt, updatedAt, modelProvider)
        VALUES(@threadId, @cwd, @preview, @createdAt, @updatedAt, @modelProvider)
        ON CONFLICT(threadId) DO UPDATE SET
          cwd=excluded.cwd,
          preview=excluded.preview,
          updatedAt=excluded.updatedAt,
          modelProvider=excluded.modelProvider
      `),

      // 任务操作
      insertJob: db.prepare(`
        INSERT INTO jobs(jobId, threadId, turnId, state, pendingApprovalCount, createdAt, updatedAt, terminalAt, errorMessage)
        VALUES(@jobId, @threadId, @turnId, @state, @pendingApprovalCount, @createdAt, @updatedAt, @terminalAt, @errorMessage)
        ON CONFLICT(jobId) DO NOTHING
      `),

      updateJob: db.prepare(`
        UPDATE jobs SET
          turnId=@turnId,
          state=@state,
          pendingApprovalCount=@pendingApprovalCount,
          updatedAt=@updatedAt,
          terminalAt=@terminalAt,
          errorMessage=@errorMessage
        WHERE jobId=@jobId
      `),

      // 事件操作
      insertEvent: db.prepare(`
        INSERT INTO job_events(jobId, seq, type, ts, payload_json)
        VALUES(@jobId, @seq, @type, @ts, @payload_json)
        ON CONFLICT(jobId, seq) DO NOTHING
      `),

      // 审批操作
      insertApproval: db.prepare(`
        INSERT INTO approvals(approvalId, jobId, threadId, turnId, itemId, kind, request_method, request_id, createdAt, payload_json)
        VALUES(@approvalId, @jobId, @threadId, @turnId, @itemId, @kind, @request_method, @request_id, @createdAt, @payload_json)
        ON CONFLICT(approvalId) DO NOTHING
      `),

      insertDecision: db.prepare(`
        INSERT INTO approval_decisions(approvalId, decision, decidedAt, actor, extra_json)
        VALUES(@approvalId, @decision, @decidedAt, @actor, @extra_json)
        ON CONFLICT(approvalId) DO NOTHING
      `),

      // 查询操作
      getJob: db.prepare(`SELECT * FROM jobs WHERE jobId = ?`),
      listEvents: db.prepare(`
        SELECT jobId, seq, type, ts, payload_json
        FROM job_events
        WHERE jobId = ? AND seq > ?
        ORDER BY seq ASC
        LIMIT ?
      `),
      lastSeq: db.prepare(`
        SELECT seq FROM job_events WHERE jobId = ? ORDER BY seq DESC LIMIT 1
      `),
    };

    this.db = db;
  }

  /**
   * 关闭数据库连接
   */
  close() {
    if (this.db) {
      this.db.close();
      this.db = null;
      this.stmt = null;
    }
  }

  // ==================== 线程操作 ====================

  /**
   * 更新或插入线程
   *
   * @param {Object} threadDto - 线程 DTO
   * @param {string} threadDto.threadId - 线程 ID
   * @param {string} [threadDto.cwd] - 工作目录
   * @param {string} [threadDto.preview] - 预览文本
   * @param {string} [threadDto.createdAt] - 创建时间
   * @param {string} [threadDto.updatedAt] - 更新时间
   * @param {string} [threadDto.modelProvider] - 模型提供者
   */
  upsertThread(threadDto) {
    if (!this.db) this.init();
    this.stmt.upsertThread.run({
      threadId: threadDto.threadId,
      cwd: threadDto.cwd ?? null,
      preview: threadDto.preview ?? "",
      createdAt: threadDto.createdAt ?? null,
      updatedAt: threadDto.updatedAt ?? null,
      modelProvider: threadDto.modelProvider ?? null,
    });
  }

  // ==================== 任务操作 ====================

  /**
   * 插入任务
   *
   * 使用 ON CONFLICT DO NOTHING 实现幂等。
   *
   * @param {Object} snapshot - 任务快照
   */
  insertJob(snapshot) {
    if (!this.db) this.init();
    this.stmt.insertJob.run({
      jobId: snapshot.jobId,
      threadId: snapshot.threadId,
      turnId: snapshot.turnId ?? null,
      state: snapshot.state,
      pendingApprovalCount: snapshot.pendingApprovalCount ?? 0,
      createdAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt,
      terminalAt: snapshot.terminalAt ?? null,
      errorMessage: snapshot.errorMessage ?? null,
    });
  }

  /**
   * 更新任务
   *
   * @param {Object} snapshot - 任务快照
   */
  updateJob(snapshot) {
    if (!this.db) this.init();
    this.stmt.updateJob.run({
      jobId: snapshot.jobId,
      turnId: snapshot.turnId ?? null,
      state: snapshot.state,
      pendingApprovalCount: snapshot.pendingApprovalCount ?? 0,
      createdAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt,
      terminalAt: snapshot.terminalAt ?? null,
      errorMessage: snapshot.errorMessage ?? null,
    });
  }

  // ==================== 事件操作 ====================

  /**
   * 追加事件
   *
   * 事件采用 append-only 模式，只追加不修改。
   * 使用 ON CONFLICT DO NOTHING 实现幂等。
   *
   * @param {Object} envelope - 事件信封
   * @param {string} envelope.jobId - 任务 ID
   * @param {number} envelope.seq - 序列号
   * @param {string} envelope.type - 事件类型
   * @param {string} envelope.ts - 时间戳
   * @param {Object} envelope.payload - 事件负载
   */
  appendEvent(envelope) {
    if (!this.db) this.init();
    this.stmt.insertEvent.run({
      jobId: envelope.jobId,
      seq: envelope.seq,
      type: envelope.type,
      ts: envelope.ts,
      payload_json: JSON.stringify(envelope.payload ?? null),
    });
  }

  // ==================== 审批操作 ====================

  /**
   * 插入审批记录
   *
   * @param {Object} approval - 审批对象
   * @param {string} approval.approvalId - 审批 ID
   * @param {string} approval.jobId - 任务 ID
   * @param {string} approval.threadId - 线程 ID
   * @param {string} [approval.turnId] - 轮次 ID
   * @param {string} [approval.itemId] - 项目 ID
   * @param {string} approval.kind - 审批类型
   * @param {string} approval.requestMethod - 请求方法
   * @param {number} approval.requestId - 请求 ID
   * @param {string} approval.createdAt - 创建时间
   * @param {Object} approval.payload - 完整的请求参数
   */
  insertApproval(approval) {
    if (!this.db) this.init();
    this.stmt.insertApproval.run({
      approvalId: approval.approvalId,
      jobId: approval.jobId,
      threadId: approval.threadId,
      turnId: approval.turnId ?? null,
      itemId: approval.itemId ?? null,
      kind: approval.kind,
      request_method: approval.requestMethod,
      request_id: approval.requestId,
      createdAt: approval.createdAt,
      payload_json: JSON.stringify(approval.payload ?? null),
    });
  }

  /**
   * 插入审批决策
   *
   * 使用 approvalId 作为主键，实现幂等闸门：
   * 同一审批重复插入会被忽略。
   *
   * @param {Object} params - 参数
   * @param {string} params.approvalId - 审批 ID
   * @param {string} params.decision - 决策值
   * @param {string} params.decidedAt - 决策时间
   * @param {string} params.actor - 决策者（如 'api'）
   * @param {Object} [params.extra] - 额外信息
   */
  insertDecision({ approvalId, decision, decidedAt, actor, extra }) {
    if (!this.db) this.init();
    this.stmt.insertDecision.run({
      approvalId,
      decision,
      decidedAt,
      actor,
      extra_json: extra ? JSON.stringify(extra) : null,
    });
  }

  // ==================== 查询操作 ====================

  /**
   * 获取任务快照
   *
   * @param {string} jobId - 任务 ID
   * @returns {Object|null} 任务快照，不存在返回 null
   */
  getJob(jobId) {
    if (!this.db) this.init();
    const row = this.stmt.getJob.get(jobId);
    if (!row) return null;
    return {
      jobId: row.jobId,
      threadId: row.threadId,
      turnId: row.turnId,
      state: row.state,
      pendingApprovalCount: row.pendingApprovalCount ?? 0,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      terminalAt: row.terminalAt,
      errorMessage: row.errorMessage,
    };
  }

  /**
   * 列出任务事件
   *
   * 支持游标分页，返回 seq > cursor 的事件。
   *
   * @param {string} jobId - 任务 ID
   * @param {number|null} cursor - 游标，null 表示从头开始
   * @returns {Object} { data: Event[], nextCursor: number }
   */
  listEvents(jobId, cursor) {
    if (!this.db) this.init();

    // 标准化游标
    const normalizedCursor = Number.isInteger(cursor) ? cursor : -1;

    // 查询事件
    const rows = this.stmt.listEvents.all(jobId, normalizedCursor, this.eventPageLimit);

    // 解析 JSON 负载
    const data = rows.map((r) => {
      let payload = null;
      try {
        payload = JSON.parse(r.payload_json);
      } catch {
        // JSON 解析失败，保留 null
        payload = null;
      }
      return {
        type: r.type,
        ts: r.ts,
        jobId: r.jobId,
        seq: r.seq,
        payload,
      };
    });

    // 计算下一个游标
    const nextCursor = data.length > 0 ? data[data.length - 1].seq : normalizedCursor;

    return { data, nextCursor };
  }
}
