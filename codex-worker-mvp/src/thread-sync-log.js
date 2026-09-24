import { createHash, randomUUID } from "node:crypto";
import { HttpError } from "./errors.js";

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])]));
  return value;
}

function preview(value, budget = { remaining: 6000 }) {
  if (budget.remaining <= 0) return "…（完整内容按需加载）";
  if (typeof value === "string") {
    const result = value.slice(0, budget.remaining);
    budget.remaining -= result.length;
    return result.length < value.length ? result + "…（完整内容按需加载）" : result;
  }
  if (Array.isArray(value)) return value.slice(0, 50).map(item => preview(item, budget));
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).slice(0, 50).map(([key, item]) => [key, preview(item, budget)]));
  return value;
}

// The durable cursor belongs to the Worker, never to a client or a replay array.
// This uses the existing Worker database and does not start/resume model turns.
export class ThreadSyncLog {
  constructor(db) {
    this.db = db;
    db.exec(`
      CREATE TABLE IF NOT EXISTS thread_sync_heads (
        threadId TEXT PRIMARY KEY, generation TEXT NOT NULL,
        latestCursor INTEGER NOT NULL DEFAULT -1, seeded INTEGER NOT NULL DEFAULT 0,
        updatedAt TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS thread_sync_events (
        threadId TEXT NOT NULL, cursor INTEGER NOT NULL, eventKey TEXT NOT NULL,
        envelope TEXT NOT NULL, PRIMARY KEY(threadId, cursor), UNIQUE(threadId, eventKey)
      );
    `);
    this.insert = db.prepare("INSERT OR IGNORE INTO thread_sync_events VALUES (?, ?, ?, ?)");
  }

  head(threadId) {
    this.db.prepare("INSERT OR IGNORE INTO thread_sync_heads(threadId,generation,updatedAt) VALUES(?,?,?)")
      .run(threadId, randomUUID(), new Date().toISOString());
    return this.db.prepare("SELECT * FROM thread_sync_heads WHERE threadId=?").get(threadId);
  }

  append(threadId, events, { seeded = false, replay = false } = {}) {
    return this.db.transaction(() => {
      const head = this.head(threadId);
      let cursor = head.latestCursor;
      let added = 0;
      for (const event of events) {
        // Replay timestamps are generated at read time. Ignore them when deduplicating.
        const identity = JSON.stringify(canonical([replay ? "snapshot" : "live", event.jobId,
          replay ? null : event.seq, event.type, event.payload]));
        const key = createHash("sha256").update(identity).digest("hex");
        // Snapshot array positions are not native SSE sequence numbers.
        const result = this.insert.run(threadId, cursor + 1, key, JSON.stringify(replay ? { ...event, seq: -1 } : event));
        if (result.changes) { cursor += 1; added += 1; }
      }
      this.db.prepare(`UPDATE thread_sync_heads SET latestCursor=?, seeded=MAX(seeded,?),
        updatedAt=CASE WHEN ? > 0 THEN ? ELSE updatedAt END WHERE threadId=?`)
        .run(cursor, seeded ? 1 : 0, added, new Date().toISOString(), threadId);
      return { ...this.head(threadId), added };
    })();
  }

  page(threadId, { cursor = -1, limit = 200, generation = null } = {}) {
    const head = this.head(threadId);
    if (!Number.isSafeInteger(cursor) || cursor < -1 || !Number.isSafeInteger(limit) || limit < 1) {
      throw new HttpError(400, "INVALID_CURSOR", "Invalid sync cursor or limit");
    }
    if ((generation && generation !== head.generation) || cursor > head.latestCursor) {
      throw new HttpError(409, "THREAD_CURSOR_EXPIRED", "Rebuild from cursor -1; retain the visible cache until complete");
    }
    const rows = this.db.prepare("SELECT cursor,envelope FROM thread_sync_events WHERE threadId=? AND cursor>? ORDER BY cursor LIMIT ?")
      .all(threadId, cursor, Math.min(limit, 1000));
    const data = []; let bytes = 0;
    for (const row of rows) {
      const envelope = JSON.parse(row.envelope);
      const size = Buffer.byteLength(row.envelope);
      const item = { ...envelope, threadCursor: row.cursor };
      if (size > 24000) {
        item.payload = preview(envelope.payload);
        item.detailCursor = row.cursor; item.detailGeneration = head.generation; item.detailBytes = size;
      }
      const pageBytes = Buffer.byteLength(JSON.stringify(item));
      if (data.length && bytes + pageBytes > 256000) break;
      data.push(item); bytes += pageBytes;
    }
    const nextCursor = data.at(-1)?.threadCursor ?? cursor;
    return {
      data,
      nextCursor, hasMore: nextCursor < head.latestCursor,
      generation: head.generation, latestCursor: head.latestCursor,
      syncedAt: head.updatedAt, source: "worker_durable_log", seeded: Boolean(head.seeded),
    };
  }

  detail(threadId, cursor, { generation, offset = 0, limit = 16000 } = {}) {
    const head = this.head(threadId);
    if (generation !== head.generation) throw new HttpError(409, "THREAD_CURSOR_EXPIRED", "Reload the current event before opening details");
    if (!Number.isSafeInteger(cursor) || !Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(limit) || limit < 1) throw new HttpError(400, "INVALID_CURSOR", "Invalid detail range");
    const row = this.db.prepare("SELECT envelope FROM thread_sync_events WHERE threadId=? AND cursor=?").get(threadId, cursor);
    if (!row) throw new HttpError(404, "EVENT_NOT_FOUND", "The event is unavailable");
    const content = JSON.stringify(JSON.parse(row.envelope).payload, null, 2);
    const text = content.slice(offset, offset + Math.min(limit, 32000));
    return { text, nextOffset: offset + text.length, hasMore: offset + text.length < content.length, totalCharacters: content.length };
  }
}
