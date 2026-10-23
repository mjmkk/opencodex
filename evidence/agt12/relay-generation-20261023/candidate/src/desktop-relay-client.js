import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { HttpError } from './errors.js';

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
          if (message.error) call.reject(new HttpError(409, message.error.code ?? 'NATIVE_REQUEST_UNAVAILABLE', message.error.message ?? 'Native owner is unavailable'));
          else if (typeof message.payload_json === 'string') call.resolve(message.payload_json);
          else call.reject(new HttpError(502,'NATIVE_PROTOCOL_MISMATCH','Native relay protocol is incompatible'));
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

  call(operation, rawBody = '{}') {
    if (this.disposed || (this.closed && operation !== 'list'))
      return Promise.reject(new HttpError(503,'NATIVE_OWNER_UNAVAILABLE','The original owner is unavailable'));
    try { JSON.parse(rawBody); } catch { return Promise.reject(new HttpError(400,'INVALID_JSON','Invalid native JSON')); }
    // Only a separate list may begin a fresh adapter/receipt generation.
    if (this.closed && !this.#connect())
      return Promise.reject(new HttpError(503,'NATIVE_OWNER_UNAVAILABLE','The original owner is unavailable'));
    const generation = this.generation;
    return new Promise((resolve,reject) => {
      const id = randomUUID();
      const timer = setTimeout(()=>{
        if (!generation.pending.delete(id)) return;
        // A timeout alone does not establish connection loss or permit write replay.
        reject(new HttpError(503, operation === 'respond' ? 'NATIVE_RESPONSE_OUTCOME_UNKNOWN' : 'NATIVE_OWNER_UNAVAILABLE', 'Read the original request before any further action'));
      },this.timeoutMs);
      generation.pending.set(id,{resolve,reject,timer,operation});
      try { generation.child.stdin.write(`{"id":${JSON.stringify(id)},"operation":${JSON.stringify(operation)},"body":${rawBody}}\n`); }
      catch { this.fail(generation); }
    });
  }

  fail(generation = this.generation) {
    if (!generation || this.generation !== generation || this.closed) return;
    this.closed = true;
    for (const call of generation.pending.values()) {
      clearTimeout(call.timer);
      call.reject(new HttpError(503,call.operation === 'respond' ? 'NATIVE_RESPONSE_OUTCOME_UNKNOWN' : 'NATIVE_OWNER_UNAVAILABLE','Original owner connection unavailable'));
    }
    generation.pending.clear();
    generation.child.stdin.destroy();
    generation.child.stdout.destroy();
    generation.child.stderr.destroy();
    generation.child.kill();
  }

  close() { this.disposed = true; this.fail(); }
}
