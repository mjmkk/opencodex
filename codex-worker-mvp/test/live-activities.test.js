import test from 'node:test';
import assert from 'node:assert/strict';
import Database from 'better-sqlite3';
import { generateKeyPairSync } from 'node:crypto';
import { LiveActivities, activityPayload } from '../src/live-activities.js';
import { ApnsNotifier } from '../src/apns-notifier.js';
import { createHttpServer } from '../src/http-server.js';

const registration={id:'activity-fixture',clientScope:'installation-fixture',threadId:'original',token:'a'.repeat(64),environment:'sandbox',pinned:true};
function setup() {
  const db=new Database(':memory:');
  let now=1789431000000, state='RUNNING', errors={};
  const calls=[];
  const service={listThreads:async()=>({data:[{threadId:'original',executionState:state}],observationErrors:errors})};
  const activities=new LiveActivities({db,service,now:()=>now,notifier:{sendActivity:async(...args)=>{calls.push(args);return {ok:true};}}});
  return {db,activities,service,calls,tick:delta=>now+=delta,state:value=>state=value,errors:value=>errors=value};
}

test('only explicit Pin registers, Unpin stays ended across late registration',async()=>{
  const t=setup();
  try {
    await t.activities.poll();assert.equal(t.calls.length,0);
    await assert.rejects(t.activities.register({...registration,pinned:false}));
    await assert.rejects(t.activities.register({...registration,threadId:'unregistered'}));
    await t.activities.register(registration);
    t.activities.unregister(registration);
    await assert.rejects(t.activities.register(registration),{code:'ACTIVITY_ENDED'});
    await t.activities.poll();assert.equal(t.calls.length,0);
    assert.equal(t.db.prepare('SELECT token FROM mobile_live_activities').get().token,null);
  } finally {t.db.close();}
});

test('concurrent Unpin wins while registration awaits current native catalog',async()=>{
  const t=setup();
  try {
    let release;
    t.service.listThreads=()=>new Promise(resolve=>{release=resolve;});
    const inFlight=t.activities.register(registration);
    t.activities.unregister(registration);
    release({data:[{threadId:'original'}]});
    await assert.rejects(inFlight,{code:'ACTIVITY_ENDED'});
    assert.equal(t.db.prepare('SELECT state FROM mobile_live_activities').get().state,'closed');
  } finally {t.db.close();}
});

test('concurrent registrations cannot rebind one activity to a different task',async()=>{
  const t=setup();
  try {
    const releases=[];
    t.service.listThreads=()=>new Promise(resolve=>releases.push(resolve));
    const first=t.activities.register(registration);
    const second=t.activities.register({...registration,threadId:'another'});
    const catalog={data:[{threadId:'original'},{threadId:'another'}]};
    releases[0](catalog);await first;
    releases[1](catalog);await assert.rejects(second,{code:'ACTIVITY_CHANGED'});
    assert.equal(t.db.prepare('SELECT threadId FROM mobile_live_activities').get().threadId,'original');
  } finally {t.db.close();}
});

test('updates are bounded, unavailable sources do not advance freshness, terminal ends once',async()=>{
  const t=setup();
  try {
    await t.activities.register(registration);
    await t.activities.poll();assert.equal(t.calls.length,1);
    t.tick(30000);await t.activities.poll();assert.equal(t.calls.length,1);
    t.tick(600000);t.errors({original:'offline'});await t.activities.poll();assert.equal(t.calls.length,1);
    t.errors({});t.state('WAITING_APPROVAL');await t.activities.poll();assert.equal(t.calls.length,2);
    t.state('DONE');await t.activities.poll();assert.equal(t.calls.length,3);
    assert.equal(t.calls[2][1].aps.event,'end');
    assert.equal(t.calls[2][1].aps['dismissal-date'],t.calls[2][1].aps.timestamp+60);
    await t.activities.poll();assert.equal(t.calls.length,3);
    assert.equal(t.db.prepare('SELECT token FROM mobile_live_activities').get().token,null);
  } finally {t.db.close();}
});

test('ActivityKit transport uses its own token, topic, default Codable date and no alert',async()=>{
  const {privateKey}=generateKeyPairSync('ec',{namedCurve:'P-256'});
  const sent=[];
  const notifier=new ApnsNotifier({teamId:'FIXTURE',keyId:'FIXTURE',bundleId:'test.fixture',privateKey:privateKey.export({type:'pkcs8',format:'pem'}),
    postJson:async(...args)=>{sent.push(args);return {ok:true,statusCode:200};}});
  try {
    const payload=activityPayload('RUNNING',1789431000);
    await notifier.sendActivity(registration,payload);
    assert.equal(sent[0][2]['apns-topic'],'test.fixture.push-type.liveactivity');
    assert.equal(sent[0][2]['apns-push-type'],'liveactivity');
    assert.equal(sent[0][2]['apns-priority'],'5');
    assert.equal(sent[0][3].aps.alert,undefined);
    assert.equal(sent[0][3].aps.event,'update');
    assert.equal(sent[0][3].aps['content-state'].updatedAt,811123800);
    assert.equal(notifier.policy.counters.live_activity_accepted,1);
  } finally {notifier.close();}
});

test('HTTP activity registration requires authentication and cannot start an activity remotely',async()=>{
  const t=setup();
  const server=createHttpServer({service:t.service,liveActivities:t.activities,authToken:'fixture-secret',logger:{error(){}}});
  const {port}=await server.listen(0,'127.0.0.1');
  const url=`http://127.0.0.1:${port}/v1/live-activities/`;
  try {
    const denied=await fetch(url+'register',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(registration)});
    assert.equal(denied.status,401);
    assert.equal(t.db.prepare('SELECT count(*) AS n FROM mobile_live_activities').get().n,0);
    const response=await fetch(url+'register',{method:'POST',headers:{authorization:'Bearer fixture-secret','content-type':'application/json'},body:JSON.stringify(registration)});
    assert.equal(response.status,200);assert.equal((await response.json()).remoteStart,false);
    const removed=await fetch(url+'unregister',{method:'POST',headers:{authorization:'Bearer fixture-secret','content-type':'application/json'},body:JSON.stringify(registration)});
    assert.equal(removed.status,200);
    await t.activities.poll();assert.equal(t.calls.length,0);
  } finally {await server.close();t.db.close();}
});
