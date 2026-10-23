import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { DesktopRelayClient } from '../src/desktop-relay-client.js';

// Every child below is a local synthetic JSONL fixture, never the Desktop adapter.
function fixture(t, { mode = 'normal', timeoutMs = 2000, missingCommand = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'agt12-relay-test-'));
  const trace = join(dir, 'trace.jsonl');
  const executable = join(dir, 'relay');
  const script = `
    const fs = require('node:fs');
    const rl = require('node:readline');
    const trace = process.argv[2];
    const mode = ${JSON.stringify(mode)};
    const log = event => fs.appendFileSync(trace, JSON.stringify({pid:process.pid,...event})+'\\n');
    log({event:'spawn'});
    if (mode === 'ignore-termination') { process.on('SIGTERM',()=>{}); setInterval(()=>{},1000); }
    rl.createInterface({input:process.stdin}).on('line', line => {
      const msg = JSON.parse(line);
      log({event:'call',operation:msg.operation,id:msg.id,line});
      if (mode === 'silent' || (msg.operation === 'respond' && mode === 'respond-timeout')) return;
      if (msg.operation === 'respond' && mode === 'respond-exit') process.exit(9);
      const reply = () => process.stdout.write(JSON.stringify({id:msg.id,payload_json:JSON.stringify({pid:process.pid,operation:msg.operation})})+'\\n');
      if (mode === 'delayed') setTimeout(reply,200); else reply();
    });`;
  if (!missingCommand) writeFileSync(executable, `#!${process.execPath}\n${script}`, {mode:0o700});
  const client = new DesktopRelayClient({command:executable,args:[trace],timeoutMs});
  t.after(() => { client.close(); rmSync(dir,{recursive:true,force:true}); });
  return {client,trace,executable,script,events:() => {
    try { return readFileSync(trace,'utf8').trim().split('\n').filter(Boolean).map(line=>JSON.parse(line)); }
    catch (error) { if (error.code === 'ENOENT') return []; throw error; }
  }};
}

async function waitFor(check) {
  const deadline = Date.now()+3000;
  while (Date.now()<deadline) { const found=check(); if (found) return found; await delay(5); }
  assert.fail('synthetic child did not reach the expected boundary');
}

async function disconnect(client) {
  const old = client.child;
  const stopped = once(old,'close');
  old.kill();
  await stopped;
  return old;
}

test('transport preserves int64 request IDs without JavaScript reserialization', async () => {
  const script = `process.stdin.setEncoding('utf8');process.stdin.once('data',line=>{
    const envelope=JSON.parse(line);
    process.stdout.write(JSON.stringify({id:envelope.id,payload_json:'{"request_id":9223372036854775807}'})+'\\n');
  });`;
  const client = new DesktopRelayClient({command:process.execPath,args:['-e',script]});
  try { assert.equal(await client.call('read','{"request_id":9223372036854775807}'),'{"request_id":9223372036854775807}'); }
  finally { client.close(); }
});

test('lost response reports unknown and never retries the write', async () => {
  const script = `process.stdin.once('data',()=>process.exit(0));`;
  const client = new DesktopRelayClient({command:process.execPath,args:['-e',script]});
  await assert.rejects(client.call('respond','{"response":{"id":0,"result":{"decision":"accept"}}}'),
    error=>error.code==='NATIVE_RESPONSE_OUTCOME_UNKNOWN');
  await assert.rejects(client.call('read'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  client.close();
});

test('initial spawn failure can recover only on a separate valid list', async t => {
  const f=fixture(t,{missingCommand:true});
  await assert.rejects(f.client.call('list'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  writeFileSync(f.executable,`#!${process.execPath}\n${f.script}`,{mode:0o700});
  await assert.rejects(f.client.call('read'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  await assert.rejects(f.client.call('respond'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  await assert.rejects(f.client.call('list','{'),error=>error.code==='INVALID_JSON');
  assert.equal(f.events().length,0);
  const recovered=JSON.parse(await f.client.call('list'));
  assert.equal(recovered.operation,'list');
  assert.equal(f.events().filter(x=>x.event==='spawn').length,1);
  assert.deepEqual(f.events().filter(x=>x.event==='call').map(x=>x.operation),['list']);
});

test('connection loss rejects every old pending operation; a new list does not replay them', async t => {
  const f=fixture(t,{mode:'silent'});
  const outcomes=['list','read','respond'].map(operation=>assert.rejects(f.client.call(operation),error=>
    error.code===(operation==='respond'?'NATIVE_RESPONSE_OUTCOME_UNKNOWN':'NATIVE_OWNER_UNAVAILABLE')));
  await waitFor(()=>f.events().filter(x=>x.event==='call').length===3);
  await disconnect(f.client);
  await Promise.all(outcomes);
  await assert.rejects(f.client.call('read'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  await assert.rejects(f.client.call('respond'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  assert.equal(f.events().filter(x=>x.event==='spawn').length,1);
  // Change only this test fixture's reply mode; production command/args stay fixed.
  writeFileSync(f.executable,readFileSync(f.executable,'utf8').replace('const mode = "silent"','const mode = "normal"'));
  assert.equal(JSON.parse(await f.client.call('list')).operation,'list');
  const calls=f.events().filter(x=>x.event==='call');
  assert.deepEqual(calls.map(x=>x.operation),['list','read','respond','list']);
  assert.equal(new Set(calls.map(x=>x.id)).size,4);
});

test('lost respond is written once across a later list recovery', async t => {
  const f=fixture(t,{mode:'respond-exit'});
  await f.client.call('list');
  await assert.rejects(f.client.call('respond','{"response":{"id":7,"result":{"answers":{}}}}'),
    error=>error.code==='NATIVE_RESPONSE_OUTCOME_UNKNOWN');
  await assert.rejects(f.client.call('respond'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  await f.client.call('list');
  assert.deepEqual(f.events().filter(x=>x.event==='call').map(x=>x.operation),['list','respond','list']);
});

test('respond timeout remains unknown and is never automatically replayed', async t => {
  const f=fixture(t,{mode:'respond-timeout',timeoutMs:200});
  await f.client.call('list');
  await assert.rejects(f.client.call('respond'),error=>error.code==='NATIVE_RESPONSE_OUTCOME_UNKNOWN');
  await f.client.call('list');
  assert.equal(f.events().filter(x=>x.operation==='respond').length,1);
});

test('concurrent new lists share one replacement child', async t => {
  const f=fixture(t);
  const first=JSON.parse(await f.client.call('list'));
  await disconnect(f.client);
  const replies=await Promise.all(Array.from({length:12},()=>f.client.call('list').then(JSON.parse)));
  assert.equal(new Set(replies.map(x=>x.pid)).size,1);
  assert.notEqual(replies[0].pid,first.pid);
  assert.equal(f.events().filter(x=>x.event==='spawn').length,2);
  assert.equal(f.events().filter(x=>x.event==='call').length,13);
});

test('a failed but still-running child blocks additional followers until it exits', async t => {
  const f=fixture(t,{mode:'ignore-termination'});
  t.after(()=>f.client.child?.kill('SIGKILL')); // Only the intentionally stubborn fake child.
  await f.client.call('list');
  const old=f.client.child;
  old.stdin.destroy(new Error('synthetic stdin loss'));
  await waitFor(()=>f.client.closed);
  assert.equal(old.stdin.destroyed,true);
  assert.equal(old.stdout.destroyed,true);
  assert.equal(old.stderr.destroyed,true);
  for (let i=0;i<3;i++)
    await assert.rejects(f.client.call('list'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  assert.equal(f.events().filter(x=>x.event==='spawn').length,1);
  const stopped=once(old,'close'); old.kill('SIGKILL'); await stopped;
  assert.equal(JSON.parse(await f.client.call('list')).operation,'list');
  assert.equal(f.events().filter(x=>x.event==='spawn').length,2);
});

test('replacement preserves the original raw body and typed numeric/string IDs', async t => {
  const f=fixture(t);
  await f.client.call('list'); await disconnect(f.client); await f.client.call('list');
  const bodies=[
    '{ "request_id":9223372036854775807, "request":{"id":9223372036854775807,"params":{"opaque":"unchanged"}} }',
    '{"request_id":"9223372036854775807","request":{"id":"9223372036854775807","params":{}}}',
  ];
  for (const body of bodies) await f.client.call('read',body);
  const frames=f.events().filter(x=>x.event==='call' && x.operation==='read');
  assert.equal(frames.length,2);
  frames.forEach((frame,i)=>assert.ok(frame.line.endsWith(`"body":${bodies[i]}}`)));
});

test('old child late data/error/close/stdin errors cannot affect the replacement', async t => {
  const f=fixture(t,{mode:'delayed'});
  await f.client.call('list');
  const old=await disconnect(f.client);
  const next=f.client.call('list');
  const frame=await waitFor(()=>f.events().find(x=>x.event==='call' && x.pid!==old.pid));
  // Deterministic transport-event injection after a real old-process disconnect.
  old.stdout.emit('data',JSON.stringify({id:frame.id,payload_json:'{"poison":true}'})+'\n');
  old.stdout.emit('data','invalid json\n');
  old.emit('error',new Error('synthetic late child error'));
  old.stdin.emit('error',new Error('synthetic late stdin error'));
  old.emit('close',9,null);
  const result=JSON.parse(await next);
  assert.equal(result.pid,frame.pid);
  assert.equal(result.poison,undefined);
  assert.equal(JSON.parse(await f.client.call('read')).pid,frame.pid);
  assert.equal(f.events().filter(x=>x.event==='spawn').length,2);
});

test('explicit close is permanent, including when a request is pending', async t => {
  const f=fixture(t,{mode:'silent'});
  const outcome=assert.rejects(f.client.call('respond'),error=>error.code==='NATIVE_RESPONSE_OUTCOME_UNKNOWN');
  await waitFor(()=>f.events().some(x=>x.event==='call'));
  f.client.close();
  await outcome;
  f.client.close();
  for (const operation of ['list','read','respond'])
    await assert.rejects(f.client.call(operation),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  assert.equal(f.events().filter(x=>x.event==='spawn').length,1);
  assert.equal(f.events().filter(x=>x.event==='call').length,1);
});

test('explicit close before child startup never enables recovery', async t => {
  const f=fixture(t,{missingCommand:true});
  f.client.close();
  await delay(20);
  writeFileSync(f.executable,`#!${process.execPath}\n${f.script}`,{mode:0o700});
  await assert.rejects(f.client.call('list'),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  assert.equal(f.events().length,0);
});

test('real frozen Adapter rejects old-generation receipts, typed ID and version mismatches', async t => {
  const nativeDir=fileURLToPath(new URL('../native/',import.meta.url));
  const script=`
import copy,json,sys
sys.path.insert(0,sys.argv[1])
from mobile_adapter import Adapter,canonical
class Fake:
    def __init__(self):
        self.request={'id':7,'method':'item/tool/requestUserInput','params':{'threadId':'fixture-thread','turnId':'fixture-turn','questions':[]}}
    def follow(self,thread,host_id):
        return {'valid':True,'threadId':thread,'hostId':host_id,'ownerClientId':'fixture-owner','requests':[copy.deepcopy(self.request)]}
    def native_observation(self,*a,**kw): return {}
    def respond(self,*a,**kw): raise AssertionError('test must never reach a native response')
adapter=Adapter(Fake(),['fixture-thread'])
for line in sys.stdin:
    print(canonical(adapter.line(json.loads(line))),flush=True)
`;
  const client=new DesktopRelayClient({command:'/usr/bin/python3',args:['-B','-u','-c',script,nativeDir],timeoutMs:2000});
  t.after(()=>client.close());
  const first=JSON.parse(await client.call('list')).data[0];
  const body={receipt_id:first.receipt_id,request_id:first.request_id,request_version:first.request_version};
  assert.equal(JSON.parse(await client.call('read',JSON.stringify(body))).request_id,7);
  await disconnect(client);
  for (const operation of ['read','respond'])
    await assert.rejects(client.call(operation,JSON.stringify(body)),error=>error.code==='NATIVE_OWNER_UNAVAILABLE');
  const current=JSON.parse(await client.call('list')).data[0];
  assert.notEqual(current.receipt_id,first.receipt_id);
  for (const operation of ['read','respond'])
    await assert.rejects(client.call(operation,JSON.stringify(body)),error=>error.code==='NATIVE_REQUEST_UNAVAILABLE');
  const fresh={receipt_id:current.receipt_id,request_id:current.request_id,request_version:current.request_version};
  await assert.rejects(client.call('read',JSON.stringify({...fresh,request_id:'7'})),error=>error.code==='NATIVE_REQUEST_UNAVAILABLE');
  await assert.rejects(client.call('read',JSON.stringify({...fresh,request_version:'stale'})),error=>error.code==='NATIVE_REQUEST_UNAVAILABLE');
  assert.equal(JSON.parse(await client.call('read',JSON.stringify(fresh))).request.method,'item/tool/requestUserInput');
});
