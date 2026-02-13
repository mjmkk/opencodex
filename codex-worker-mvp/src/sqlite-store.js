import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";

// SQLite 持久化：用于“审计落盘 + 事件回放”，避免 Worker 重启后丢失 job/events。
export class SqliteStore {
  constructor(options) {
    this.dbPath = options.dbPath;
    this.logger = options.logger ?? console;
    this.eventPageLimit = options.eventPageLimit ?? 2000;

    this.db = null;
    this.stmt = null;
  }

  init() {
    if (this.db) {
      return;
    }

    if (!this.dbPath || typeof this.dbPath !== "string") {
      throw new Error("SqliteStore requires dbPath");
    }

    if (this.dbPath !== ":memory:") {
      mkdirSync(dirname(this.dbPath), { recursive: true });
    }

    const db = new Database(this.dbPath);
    db.pragma("journal_mode = WAL");
    db.pragma("foreign_keys = ON");

    db.exec(`
      CREATE TABLE IF NOT EXISTS threads (
        threadId TEXT PRIMARY KEY,
        cwd TEXT,
        preview TEXT,
        createdAt INTEGER,
        updatedAt INTEGER,
        modelProvider TEXT
      );

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

      CREATE TABLE IF NOT EXISTS job_events (
        jobId TEXT NOT NULL,
        seq INTEGER NOT NULL,
        type TEXT NOT NULL,
        ts TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        PRIMARY KEY(jobId, seq),
        FOREIGN KEY(jobId) REFERENCES jobs(jobId) ON DELETE CASCADE
      );

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

      CREATE TABLE IF NOT EXISTS approval_decisions (
        approvalId TEXT PRIMARY KEY,
        decision TEXT NOT NULL,
        decidedAt TEXT NOT NULL,
        actor TEXT NOT NULL,
        extra_json TEXT
      );
    `);

    this.stmt = {
      upsertThread: db.prepare(`
        INSERT INTO threads(threadId, cwd, preview, createdAt, updatedAt, modelProvider)
        VALUES(@threadId, @cwd, @preview, @createdAt, @updatedAt, @modelProvider)
        ON CONFLICT(threadId) DO UPDATE SET
          cwd=excluded.cwd,
          preview=excluded.preview,
          updatedAt=excluded.updatedAt,
          modelProvider=excluded.modelProvider
      `),

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

      insertEvent: db.prepare(`
        INSERT INTO job_events(jobId, seq, type, ts, payload_json)
        VALUES(@jobId, @seq, @type, @ts, @payload_json)
        ON CONFLICT(jobId, seq) DO NOTHING
      `),

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

  close() {
    if (this.db) {
      this.db.close();
      this.db = null;
      this.stmt = null;
    }
  }

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

  listEvents(jobId, cursor) {
    if (!this.db) this.init();
    const normalizedCursor = Number.isInteger(cursor) ? cursor : -1;
    const rows = this.stmt.listEvents.all(jobId, normalizedCursor, this.eventPageLimit);
    const data = rows.map((r) => {
      let payload = null;
      try {
        payload = JSON.parse(r.payload_json);
      } catch {
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
    const nextCursor = data.length > 0 ? data[data.length - 1].seq : normalizedCursor;
    return { data, nextCursor };
  }
}

