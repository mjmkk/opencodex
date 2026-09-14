import test from 'node:test';
import assert from 'node:assert/strict';
import { WorkerService } from '../src/worker-service.js';
import { SqliteStore } from '../src/sqlite-store.js';
import { FakeRpcClient } from './helpers/fake-rpc.js';

async function setup() {
  const rpc = new FakeRpcClient(); rpc.sharedNative = true; rpc.connectionId = 'connection-1';
  const calls = [];
  const thread = { id:'original', cwd:'/repo', createdAt:1, updatedAt:1, turns:[{ id:'turn-original', status:'inProgress', items:[{ type:'agentMessage', id:'message-1', text:'existing work' }] }] };
  for (const method of ['initialize','thread/read','thread/resume','thread/turns/list']) {
    rpc.onRequest(method, params => {
      calls.push({method,params});
      if (method==='initialize') return {};
      if (method==='thread/turns/list') return { data:thread.turns };
      return { thread };
    });
  }
  const store = new SqliteStore({dbPath:':memory:'}); store.init();
  const service = new WorkerService({rpc,store,observedThreadIds:['original'],projectPaths:['/repo'],logger:{warn(){},error(){}}});
  await service.init();
  return {rpc,store,service,calls,thread};
}
function approval(rpc, id=99) {
  rpc.emit('request',{id,method:'item/commandExecution/requestApproval',params:{threadId:'original',turnId:'turn-original',itemId:'command',command:'echo fixture'}});
}
function current(service) { return [...service.approvals.values()].at(-1); }

test('native observation preserves identity and permissions; durable events precede hints', async t => {
  const {rpc,store,service,calls}=await setup(); t.after(()=>store.close());
  assert.ok(calls.every(c=>['initialize','thread/read','thread/resume'].includes(c.method)));
  assert.deepEqual(calls.find(c=>c.method==='thread/resume').params,{threadId:'original',excludeTurns:true});
  let seen=false;
  service.syncSubscribers.add(hint=>{ assert.equal(service.syncLog.head('original').latestCursor,hint.latestCursor); seen=true; });
  rpc.emit('notification',{method:'item/agentMessage/delta',params:{threadId:'original',turnId:'turn-original',itemId:'message-1',delta:' next'}});
  assert.equal(seen,true);
  const first=await service.listThreadEvents('original',{sync:true,cursor:-1});
  await service.observeThread('original');
  const second=await service.listThreadEvents('original',{sync:true,cursor:first.nextCursor,generation:first.generation});
  assert.equal(second.data.length,0,'the same snapshot does not grow the durable log');
  await assert.rejects(service.listThreadEvents('unregistered',{sync:true}),{code:'THREAD_NOT_REGISTERED'});
  await assert.rejects(service.createThread(),{code:'NATIVE_THREAD_IDENTITY_PRESERVED'});
  await assert.rejects(service.startTurn('original',{text:'hello'}),{code:'THREAD_HAS_ACTIVE_JOB'});
  await assert.rejects(service.startTurn('original',{text:'hello',approvalPolicy:'never'}),{code:'NATIVE_SETTINGS_PRESERVED'});
  assert.equal(rpc.responses.length,0);
});

test('shared requests are never auto answered, expanded, replayed or retargeted', async t => {
  const {rpc,store,service,thread}=await setup(); t.after(()=>store.close());
  rpc.emit('request',{id:1,method:'mcpServer/elicitation/request',params:{threadId:'original'}});
  approval(rpc); const item=current(service);
  assert.equal(rpc.responses.length,0);
  const request={approvalId:item.approvalId,decision:'accept',requestVersion:item.requestVersion};
  await assert.rejects(service.approve(item.jobId,{...request,requestVersion:'old'}),{code:'APPROVAL_VERSION_CHANGED'});
  await assert.rejects(service.approve(item.jobId,{...request,decision:'accept_for_session'}),{code:'APPROVAL_SCOPE_EXCEEDED'});
  const results=await Promise.allSettled([service.approve(item.jobId,request),service.approve(item.jobId,request)]);
  assert.equal(results.filter(x=>x.status==='fulfilled').length,1);
  assert.equal(rpc.responses.length,1);
  assert.equal(results.find(x=>x.status==='fulfilled').value.status,'sent_waiting_confirmation');
  assert.equal(service.getJob(item.jobId).pendingApprovalCount,1);
  assert.equal((await service.approve(item.jobId,request)).status,'sent_waiting_confirmation');
  approval(rpc); assert.equal(rpc.responses.length,1);
  rpc.emit('notification',{method:'serverRequest/resolved',params:{threadId:'original',requestId:99}});
  assert.equal(service.getJob(item.jobId).pendingApprovalCount,0);
  approval(rpc,100); const stale=current(service);
  thread.turns[0].status='completed';
  await assert.rejects(service.approve(stale.jobId,{approvalId:stale.approvalId,decision:'decline',requestVersion:stale.requestVersion}),{code:'APPROVAL_EXPIRED'});
  assert.equal(rpc.responses.length,1);
});

test('an approval invalidated during its status read cannot be submitted',async t=>{
  const {rpc,store,service}=await setup();t.after(()=>store.close());
  approval(rpc);const item=current(service);
  rpc.onRequest('thread/turns/list',()=>{
    rpc.emit('notification',{method:'serverRequest/resolved',params:{threadId:'original',requestId:99}});
    return {data:[{id:'turn-original',status:'inProgress'}]};
  });
  await assert.rejects(service.approve(item.jobId,{approvalId:item.approvalId,requestVersion:item.requestVersion,decision:'accept'}),{code:'APPROVAL_EXPIRED'});
  assert.equal(rpc.responses.length,0);
});

test('new native turn identity cannot be assigned to an earlier active turn',async t=>{
  const {rpc,store,service}=await setup();t.after(()=>store.close());
  rpc.emit('notification',{method:'turn/started',params:{threadId:'original',turn:{id:'turn-next',status:'inProgress'}}});
  const jobs=[...service.jobs.values()];
  assert.equal(jobs.length,2);assert.ok(jobs.some(job=>job.turnId==='turn-original'));assert.ok(jobs.some(job=>job.turnId==='turn-next'));
});

test('current-context guard blocks native answers and disconnect clears stale cards',async t=>{
  const {rpc,store,service}=await setup();t.after(()=>store.close());
  approval(rpc);const item=current(service);
  service.nativeWriteGuard=async()=>{throw new Error('loaded contract differs')};
  await assert.rejects(service.approve(item.jobId,{approvalId:item.approvalId,requestVersion:item.requestVersion,decision:'accept'}),/loaded contract differs/);
  assert.equal(rpc.responses.length,0);
  rpc.emit('exit',{sharedNative:true});
  assert.equal(item.invalidated,true);assert.equal(service.getJob(item.jobId).pendingApprovalCount,0);
  assert.equal(service.syncLog.page('original').data.at(-1).payload.source,'native_connection_closed');
});
