import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { HttpError } from './errors.js';

// One child keeps one follower connection. Numeric request IDs remain inside raw JSON strings.
export class DesktopRelayClient {
  constructor({command = '/usr/bin/python3', args, timeoutMs = 15000}) {
    this.timeoutMs = timeoutMs;
    this.pending = new Map();
    this.closed = false;
    this.child = spawn(command,args,{stdio:['pipe','pipe','pipe']});
    let buffer = '';
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', chunk => {
      buffer += chunk;
      if (Buffer.byteLength(buffer) > 32 * 1024 * 1024) { this.fail(); this.child.kill(); return; }
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0,end); buffer = buffer.slice(end+1);
        try {
          const message = JSON.parse(line);
          const call = this.pending.get(message.id);
          if (!call) continue;
          this.pending.delete(message.id); clearTimeout(call.timer);
          if (message.error) call.reject(new HttpError(409, message.error.code ?? 'NATIVE_REQUEST_UNAVAILABLE', message.error.message ?? 'Native owner is unavailable'));
          else if (typeof message.payload_json === 'string') call.resolve(message.payload_json);
          else call.reject(new HttpError(502,'NATIVE_PROTOCOL_MISMATCH','Native relay protocol is incompatible'));
        } catch { this.fail(); this.child.kill(); return; }
      }
    });
    // Never print native payload, commands, or request contents to application logs.
    this.child.stderr.resume();
    this.child.on('error',()=>this.fail());
    this.child.on('close',()=>this.fail());
    this.child.stdin.on('error',()=>this.fail());
  }

  call(operation, rawBody = '{}') {
    if (this.closed) return Promise.reject(new HttpError(503,'NATIVE_OWNER_UNAVAILABLE','The original owner is unavailable'));
    try { JSON.parse(rawBody); } catch { return Promise.reject(new HttpError(400,'INVALID_JSON','Invalid native JSON')); }
    return new Promise((resolve,reject) => {
      const id = randomUUID();
      const timer = setTimeout(()=>{
        this.pending.delete(id);
        reject(new HttpError(503, operation === 'respond' ? 'NATIVE_RESPONSE_OUTCOME_UNKNOWN' : 'NATIVE_OWNER_UNAVAILABLE', 'Read the original request before any further action'));
      },this.timeoutMs);
      this.pending.set(id,{resolve,reject,timer,operation});
      this.child.stdin.write(`{"id":${JSON.stringify(id)},"operation":${JSON.stringify(operation)},"body":${rawBody}}\n`);
    });
  }

  fail() {
    this.closed = true;
    for (const call of this.pending.values()) {
      clearTimeout(call.timer);
      call.reject(new HttpError(503,call.operation === 'respond' ? 'NATIVE_RESPONSE_OUTCOME_UNKNOWN' : 'NATIVE_OWNER_UNAVAILABLE','Original owner connection unavailable'));
    }
    this.pending.clear();
  }

  close() { this.fail(); this.child.kill(); }
}
