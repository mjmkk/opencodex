import { spawn } from 'node:child_process';
import { HttpError } from './errors.js';

export function mobileApprovalBridge(config) {
  if (!config?.command || !Array.isArray(config.args)) return null;
  return (operation, body = {}) => new Promise((resolve, reject) => {
    const child = spawn(config.command, config.args, {stdio:['pipe','pipe','pipe']});
    let output = ''; let settled = false;
    const done = (error, value) => {
      if (settled) return; settled = true; clearTimeout(timer);
      error ? reject(error) : resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill(); done(new HttpError(503,'APPROVAL_OUTCOME_UNKNOWN','Refresh the request before resubmitting; its state may already have changed'));
    }, 20000);
    child.on('error',()=>done(new HttpError(503,'APPROVAL_ADAPTER_UNAVAILABLE','The approval adapter is unavailable')));
    child.stdout.on('data',chunk=>{output+=chunk.toString();if(output.length>2*1024*1024){child.kill();done(new HttpError(502,'APPROVAL_RESPONSE_TOO_LARGE','Approval response exceeds the limit'));}});
    child.stderr.resume(); // Adapter exceptions may contain account details; do not echo them into HTTP.
    child.on('exit',code=>{
      try {
        const value=JSON.parse(output);
        if(value.error) done(new HttpError(409,value.error.code,value.error.message));
        else if(code!==0) done(new HttpError(502,'APPROVAL_ADAPTER_FAILED','Approval validation failed'));
        else done(null,value);
      } catch {done(new HttpError(502,'APPROVAL_ADAPTER_FAILED','Could not verify the approval result'));}
    });
    child.stdin.on('error',()=>{});
    child.stdin.end(JSON.stringify({operation,body}));
  });
}
