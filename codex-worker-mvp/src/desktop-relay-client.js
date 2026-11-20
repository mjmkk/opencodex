import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { HttpError } from './errors.js';

// All native mutations can be delivered before a relay timeout/disconnection.
// These names are candidate-only; no new operation is exposed by this file.
const nativeWriteOperations = new Set(['respond', 'start', 'steer', 'interrupt']);
const freshReadOperations = new Set(['list', 'control-read']);
const unknownCode = operation => operation === 'respond'
  ? 'NATIVE_RESPONSE_OUTCOME_UNKNOWN' : 'NATIVE_CONTROL_OUTCOME_UNKNOWN';

// One child keeps one follower connection. Numeric request IDs remain inside raw JSON strings.
export class DesktopRelayClient {
  constructor({command = '/usr/bin/python3', args, timeoutMs = 15000}) {
    this.command = command;
    this.args = args?.slice();
    this.timeoutMs = timeoutMs;
    this.pending = new Map();
    this.closed = true;
    this.disposed = false;
    this.generation = null;
    this.#connect();
  }

  #connect() {
    // A failed child must exit before another follower can be created. No retry loop.
    if (this.disposed || (this.generation?.child.pid && !this.generation.ended)) return false;
    let child;
    try { child = spawn(this.command,this.args,{stdio:['pipe','pipe','pipe']}); }
    catch { return false; }
    const generation = {child, pending:new Map(), ended:false};
    this.generation = generation;
    this.child = child;
    this.pending = generation.pending;
    this.closed = false;
    const active = () => this.generation === generation && !this.closed;
    let buffer = '';
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      if (!active()) return;
      buffer += chunk;
      if (Buffer.byteLength(buffer) > 32 * 1024 * 1024) { this.fail(generation); return; }
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0,end); buffer = buffer.slice(end+1);
        try {
          const message = JSON.parse(line);
          const call = generation.pending.get(message.id);
          if (!call) continue;
          generation.pending.delete(message.id); clearTimeout(call.timer);
          const outcome = message.error
            ? { error: new HttpError(409, message.error.code ?? 'NATIVE_REQUEST_UNAVAILABLE', message.error.message ?? 'Native owner is unavailable') }
            : typeof message.payload_json === 'string' ? { payload: message.payload_json }
              : { error: new HttpError(502,'NATIVE_PROTOCOL_MISMATCH','Native relay protocol is incompatible') };
          // A late result still belongs to the original durable submission.
          // Never replay the write or apply it to a newly selected mobile task.
          try { call.onOutcome?.(outcome); } catch { /* durable unknown remains */ }
          if (outcome.error) call.reject(outcome.error);
          else call.resolve(outcome.payload);
        } catch { this.fail(generation); return; }
      }
    });
    // Never print native payload, commands, or request contents to application logs.
    child.stderr.resume();
    child.on('error',()=>this.fail(generation));
    child.on('close',()=>{ generation.ended = true; this.fail(generation); });
    child.stdin.on('error',()=>this.fail(generation));
    return true;
  }

  call(operation, rawBody = '{}', { onOutcome } = {}) {
    if (this.disposed || (this.closed && !freshReadOperations.has(operation)))
      return Promise.reject(new HttpError(503,'NATIVE_OWNER_UNAVAILABLE','The original owner is unavailable'));
    try { JSON.parse(rawBody); } catch { return Promise.reject(new HttpError(400,'INVALID_JSON','Invalid native JSON')); }
    // Only a separate explicit read may begin a fresh adapter/receipt generation.
    if (this.closed && !this.#connect())
      return Promise.reject(new HttpError(503,'NATIVE_OWNER_UNAVAILABLE','The original owner is unavailable'));
    const generation = this.generation;
    return new Promise((resolve,reject) => {
      const id = randomUUID();
      const timer = setTimeout(()=>{
        const call = generation.pending.get(id);
        if (!call) return;
        // Keep only subscribed native mutations until their one original IPC
        // finishes, so later acceptance can reconcile the same intent.
        if (!nativeWriteOperations.has(operation) || typeof onOutcome !== 'function')
          generation.pending.delete(id);
        // A timeout alone does not establish connection loss or permit write replay.
        reject(new HttpError(503, nativeWriteOperations.has(operation) ? unknownCode(operation) : 'NATIVE_OWNER_UNAVAILABLE', 'Read the original request before any further action'));
      },this.timeoutMs);
      generation.pending.set(id,{resolve,reject,timer,operation,onOutcome});
      try { generation.child.stdin.write(`{"id":${JSON.stringify(id)},"operation":${JSON.stringify(operation)},"body":${rawBody}}\n`); }
      catch { this.fail(generation); }
    });
  }

  fail(generation = this.generation) {
    if (!generation || this.generation !== generation || this.closed) return;
    this.closed = true;
    for (const call of generation.pending.values()) {
      clearTimeout(call.timer);
      const error = new HttpError(503,nativeWriteOperations.has(call.operation) ? unknownCode(call.operation) : 'NATIVE_OWNER_UNAVAILABLE','Original owner connection unavailable');
      try { call.onOutcome?.({ error }); } catch { /* durable unknown remains */ }
      call.reject(error);
    }
    generation.pending.clear();
    generation.child.stdin.destroy();
    generation.child.stdout.destroy();
    generation.child.stderr.destroy();
    generation.child.kill();
  }

  close() { this.disposed = true; this.fail(); }
}
