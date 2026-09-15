import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SqliteStore } from "../src/sqlite-store.js";
import { ThreadSyncLog } from "../src/thread-sync-log.js";

const event = (seq, text = "progress") => ({ jobId: "original-job", seq,
  type: "item.completed", ts: new Date().toISOString(), payload: { text } });

test("offline events survive restart; duplicate replay cannot advance the cursor", () => {
  const dir = mkdtempSync(join(tmpdir(), "agt-sync-"));
  let store;
  try {
    store = new SqliteStore({ dbPath: join(dir, "worker.db") }); store.init();
    let log = new ThreadSyncLog(store.db);
    log.append("original-thread", [event(0), event(1)], { seeded: true });
    const first = log.page("original-thread", { limit: 1 });
    assert.equal(first.nextCursor, 0); assert.equal(first.hasMore, true);
    store.close();
    store = new SqliteStore({ dbPath: join(dir, "worker.db") }); store.init();
    log = new ThreadSyncLog(store.db);
    log.append("original-thread", [event(1), event(2)]);
    const tail = log.page("original-thread", { cursor: first.nextCursor, generation: first.generation });
    assert.deepEqual(tail.data.map(e => e.seq), [1, 2]);
    assert.equal(tail.latestCursor, 2); assert.equal(tail.hasMore, false);
    assert.throws(() => log.page("original-thread", { cursor: 10 }), /Rebuild/);
    assert.throws(() => log.page("original-thread", { generation: "old-generation" }), /Rebuild/);
  } finally { store?.close(); rmSync(dir, { recursive: true, force: true }); }
});

test("changed content is an ordered revision; an unchanged snapshot is not another event", () => {
  const store = new SqliteStore({ dbPath: ":memory:" }); store.init();
  try {
    const log = new ThreadSyncLog(store.db);
    log.append("thread", [event(0, "first")]);
    log.append("thread", [event(0, "first"), event(0, "complete")]);
    const page = log.page("thread");
    assert.equal(page.data.length, 2);
    assert.deepEqual(page.data.map(e => e.threadCursor), [0, 1]);
  } finally { store.close(); }
});

test('large logs have bounded previews and lossless generation-bound detail pages',()=>{
  const store=new SqliteStore({dbPath:':memory:'});store.init();
  try {
    const log=new ThreadSyncLog(store.db);const original='真实日志🙂\n'.repeat(20000);
    log.append('thread',Array.from({length:30},(_,i)=>event(i,original)));
    const page=log.page('thread');assert.ok(Buffer.byteLength(JSON.stringify(page))<280000);
    assert.ok(page.hasMore);assert.equal(page.data[0].detailCursor,0);
    let text='',offset=0,part;
    do { part=log.detail('thread',0,{generation:page.generation,offset});text+=part.text;offset=part.nextOffset; } while(part.hasMore);
    assert.equal(JSON.parse(text).text,original);
    assert.throws(()=>log.detail('thread',0,{generation:'stale'}),/Reload/);
  } finally {store.close()}
});
