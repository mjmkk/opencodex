// AGT-26 S2：把完成通知投递到 Codex Master 的原生 queue。
// 复用正式 release 的 native_master_queue.mjs，本脚本是它的薄封装。
// stdin 传入 JSON：{threadId, clientUserMessageId, prompt, invocationId}，stdout 输出一行 JSON 结果。
//
// 持久化 once（2026-11-09 增加）：原生 queue 不会按 clientUserMessageId 去重，
// 同一 id 再 add 一次，Master 就会被唤醒第二次（S2 试点实测）。这里在第一次写 socket 之前
// 用 O_EXCL 原子占用 sent/<threadId>/<clientUserMessageId>.json，占用失败就拒绝，不再连接 IPC。
// 占用文件里保存 payload hash、调用 id，事后补写 ACK。同一个键但正文不同时报冲突。
import {configuredNativeMasterQueue} from '/opt/spirit/spirit-agent/current/runtime/native_master_queue.mjs';
import {mkdirSync, openSync, writeSync, closeSync, readFileSync, writeFileSync, appendFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {homedir} from 'node:os';
import {join} from 'node:path';

const ROOT = join(homedir(), 'scratch/agt-s2');
const log = (o) => appendFileSync(join(ROOT, 'enqueue.log'), JSON.stringify({at: new Date().toISOString(), pid: process.pid, ...o}) + '\n');
let raw = '';
for await (const c of process.stdin) raw += c;
const {threadId, clientUserMessageId, prompt, invocationId = null} = JSON.parse(raw);
const hash = createHash('sha256').update(prompt).digest('hex');
const dir = join(ROOT, 'sent', threadId);
mkdirSync(dir, {recursive: true, mode: 0o700});
const claim = join(dir, `${clientUserMessageId}.json`);
let fd;
try {
  fd = openSync(claim, 'wx', 0o600);
} catch (e) {
  if (e.code !== 'EEXIST') throw e;
  const prev = JSON.parse(readFileSync(claim, 'utf8') || '{}');
  const r = {ok: false, code: prev.payloadHash === hash ? 'duplicate_refused' : 'duplicate_conflict',
             submission: 'not_submitted', previous: prev};
  log({event: 'refused', threadId, clientUserMessageId, invocationId, code: r.code});
  console.log(JSON.stringify(r));
  process.exit(0);
}
const rec = {threadId, clientUserMessageId, payloadHash: hash, invocationId, claimedAt: new Date().toISOString()};
writeSync(fd, JSON.stringify(rec)); closeSync(fd);
log({event: 'claimed', threadId, clientUserMessageId, invocationId});

const q = configuredNativeMasterQueue({env: {AGT_NATIVE_QUEUE_SOCKET: '/var/lib/spirit/codex/ipc/ipc.sock'}});
let r;
// Master 被 Desktop 卸载后，queue 会返回 owner_unverified，此时 add 还没有写出去。
// 这种情况下改用官方 send_message_to_thread 把这条通知直接发给 Master：它会被重新加载，
// 而这次发送本身就算一次投递，不会再另外 add，所以 once 不受影响。
async function wakeAndSend() {
  const fs = await import('node:fs');
  const env = Object.fromEntries(fs.readFileSync('/etc/spirit/spirit-agent/registry.env', 'utf8').split('\n')
    .filter(l => /^AGT_[A-Z_]+=/.test(l))
    .map(l => { const i = l.indexOf('='); return [l.slice(0, i), l.slice(i + 1).replace(/^"|"$/g, '')]; }));
  const {nativeTools} = await import('/opt/spirit/spirit-agent/current/runtime/native_tools.mjs');
  const n = await nativeTools({node: process.execPath, server: env.AGT_NATIVE_SERVER, profile: env.AGT_CODEX_PROFILE,
    contextThreadId: env.AGT_NATIVE_CONTEXT, diagnostics: false});
  try {
    await n.sendMessage({threadId, hostId: 'local', prompt});
    return {ok: true, via: 'send_message_to_thread', native_ack_only: true};
  } finally { await n.close(); }
}
try {
  r = {ok: true, ...(await q.enqueue({threadId, hostId: 'local', prompt, clientUserMessageId}))};
} catch (e) {
  if (e.code === 'native_queue_owner_unverified' && e.submission === 'not_submitted' && process.env.AGT_WAKE !== '0') {
    try { r = await wakeAndSend(); }
    catch (w) { r = {ok: false, code: 'wake_failed:' + (w.code || 'error'), submission: 'unknown'}; }
    writeFileSync(claim, JSON.stringify({...rec, result: r, finishedAt: new Date().toISOString()}), {mode: 0o600});
    log({event: 'finished', threadId, clientUserMessageId, invocationId, ok: r.ok, code: r.code ?? null, via: r.via ?? null});
    console.log(JSON.stringify(r));
    process.exit(0);
  }
  // submission=submitted 表示请求可能已经写出：占用文件保留，绝不重发。
  // 只有确定没写出（not_submitted）时才释放占用，允许调用方重试
  r = {ok: false, code: e.code, submission: e.submission ?? 'unknown'};
}
writeFileSync(claim, JSON.stringify({...rec, result: r, finishedAt: new Date().toISOString()}), {mode: 0o600});
if (!r.ok && r.submission === 'not_submitted') {
  const {unlinkSync} = await import('node:fs'); unlinkSync(claim);
}
log({event: 'finished', threadId, clientUserMessageId, invocationId, ok: r.ok, code: r.code ?? null, queued: r.queued_submission_id ?? null});
console.log(JSON.stringify(r));
