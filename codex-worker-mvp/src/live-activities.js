import { HttpError } from './errors.js';

const terminal = new Set(['DONE', 'FAILED', 'CANCELLED']);

export function activityPayload(state, timestamp, ending = false) {
  const summary = ending ? '任务已结束' : state === 'WAITING_APPROVAL' ? '等待你确认' :
    state === 'IDLE' ? '等待下一步' : '任务进行中';
  return { aps: { timestamp, event: ending ? 'end' : 'update',
    // Swift's default Codable Date representation is seconds since 2001.
    'content-state': { summary, updatedAt: timestamp - 978307200 },
    'stale-date': timestamp + 1200, ...(ending ? { 'dismissal-date': timestamp + 60 } : {}) } };
}

/** Stores only tokens for activities already created by an explicit client Pin.
 * There is no remote-start API and no request to an inference endpoint. */
export class LiveActivities {
  constructor({ db, notifier, service, now = Date.now }) {
    this.db = db; this.notifier = notifier; this.service = service; this.now = now;
    db.exec(`CREATE TABLE IF NOT EXISTS mobile_live_activities (
      id TEXT NOT NULL, clientScope TEXT NOT NULL, threadId TEXT, token TEXT,
      environment TEXT, state TEXT NOT NULL, expiresAt INTEGER NOT NULL,
      lastAttempt INTEGER NOT NULL DEFAULT 0, timestamp INTEGER NOT NULL DEFAULT 0,
      lastStatus TEXT, PRIMARY KEY(id,clientScope));`);
  }

  identity(body) {
    if (![body.id, body.clientScope].every(v => typeof v === 'string' && /^[A-Za-z0-9-]{8,100}$/.test(v)))
      throw new HttpError(400,'INVALID_ACTIVITY','Invalid activity identity');
  }

  async register(body) {
    this.identity(body);
    if (body.pinned !== true || !/^[0-9a-f]{64,512}$/.test(body.token ?? '') ||
        !['sandbox','production'].includes(body.environment))
      throw new HttpError(400,'INVALID_ACTIVITY','An explicit Pin and valid activity token are required');
    const old = this.db.prepare('SELECT * FROM mobile_live_activities WHERE id=? AND clientScope=?').get(body.id,body.clientScope);
    if (old && old.state !== 'active') throw new HttpError(409,'ACTIVITY_ENDED','Pin again to create a new activity');
    if (old && old.threadId !== body.threadId) throw new HttpError(409,'ACTIVITY_CHANGED','An activity cannot change its original thread');
    const catalog = await this.service.listThreads();
    if (!catalog.data.some(thread => thread.threadId === body.threadId) || catalog.observationErrors?.[body.threadId])
      throw new HttpError(409,'THREAD_UNAVAILABLE','The original thread cannot be verified');
    // Unpin may arrive while the read-only catalog request is in flight.
    const save = this.db.transaction(() => {
      const current = this.db.prepare('SELECT state,threadId FROM mobile_live_activities WHERE id=? AND clientScope=?').get(body.id,body.clientScope);
      if (current && current.state !== 'active') throw new HttpError(409,'ACTIVITY_ENDED','The activity was unpinned');
      if (current && current.threadId !== body.threadId) throw new HttpError(409,'ACTIVITY_CHANGED','The activity is already bound to another thread');
      this.db.prepare(`INSERT INTO mobile_live_activities(id,clientScope,threadId,token,environment,state,expiresAt)
        VALUES(@id,@clientScope,@threadId,@token,@environment,'active',@expiresAt)
        ON CONFLICT(id,clientScope) DO UPDATE SET
          lastAttempt=CASE WHEN token=excluded.token THEN lastAttempt ELSE 0 END,
          token=excluded.token,environment=excluded.environment`).run({...body,expiresAt:this.now()+8*3600000});
    });
    save();
    return { registered:true, remoteStart:false };
  }

  unregister(body) {
    this.identity(body);
    // Keep a tombstone so an in-flight token upload cannot undo Unpin.
    this.db.prepare(`INSERT INTO mobile_live_activities(id,clientScope,state,expiresAt)
      VALUES(?,?,'closed',?) ON CONFLICT(id,clientScope) DO UPDATE SET state='closed',token=NULL`)
      .run(body.id,body.clientScope,this.now()+8*3600000);
    return { unregistered:true };
  }

  async poll() {
    if (this.running) return;
    this.running = true;
    try {
      const now = this.now();
      this.db.prepare('DELETE FROM mobile_live_activities WHERE expiresAt<?').run(now);
      const rows = this.db.prepare("SELECT * FROM mobile_live_activities WHERE state='active'").all();
      if (!rows.length) return;
      const catalog = await this.service.listThreads();
      for (const row of rows) {
        const thread = catalog.data.find(item => item.threadId === row.threadId);
        if (!thread || catalog.observationErrors?.[row.threadId]) continue;
        const state = thread.executionState;
        if (!['IDLE','RUNNING','QUEUED','WAITING_APPROVAL',...terminal].includes(state)) continue;
        const ending = terminal.has(state);
        const interval = row.lastStatus === state ? 10*60000 : 60000;
        if (!ending && row.lastAttempt && now-row.lastAttempt < interval) continue;
        const current = this.db.prepare('SELECT * FROM mobile_live_activities WHERE id=? AND clientScope=?').get(row.id,row.clientScope);
        if (!current || current.state !== 'active' || current.token !== row.token) continue;
        const timestamp = Math.max(Math.floor(now/1000),row.timestamp+1);
        this.db.prepare('UPDATE mobile_live_activities SET lastAttempt=?,timestamp=? WHERE id=? AND clientScope=?')
          .run(now,timestamp,row.id,row.clientScope);
        const result = await this.notifier.sendActivity(row, activityPayload(state,timestamp,ending));
        if (result.ok) {
          this.db.prepare("UPDATE mobile_live_activities SET lastStatus=?,state=CASE WHEN state='closed' THEN state ELSE ? END WHERE id=? AND clientScope=?")
            .run(state,ending?'closed':'active',row.id,row.clientScope);
          if (ending) this.db.prepare('UPDATE mobile_live_activities SET token=NULL WHERE id=? AND clientScope=?').run(row.id,row.clientScope);
        } else if (['BadDeviceToken','DeviceTokenNotForTopic','Unregistered'].includes(result.reason)) this.unregister(row);
      }
    } finally { this.running = false; }
  }

  start(logger = console) {
    const timer = setInterval(() => { void this.poll().catch(() => logger.warn?.('Live Activity refresh unavailable')); },30000);
    timer.unref();
    return () => clearInterval(timer);
  }
}
