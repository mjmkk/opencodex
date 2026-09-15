import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import Database from 'better-sqlite3';
import { SqliteStore } from '../src/sqlite-store.js';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ApnsNotifier, NotificationPolicy, notificationMessage } from '../src/apns-notifier.js';

const job={threadId:'original',jobId:'job'};
const event=(type,seq,payload={})=>({type,seq,jobId:'job',payload});
test('progress is bounded per device, independent approvals remain distinct, and policy survives reopening',()=>{
  const db=new Database(':memory:');
  const policy=new NotificationPolicy(db);
  let attempts=0;
  for(let seq=0;seq<1000;seq++) if(policy.reserve('fixture',notificationMessage(event('item.completed',seq),job),1000+seq)) attempts++;
  assert.equal(attempts,1);
  const reopened=new NotificationPolicy(db);
  assert.equal(reopened.reserve('fixture',notificationMessage(event('item.completed',1001),job),2001),false);
  for(const id of ['a','b']) assert.equal(policy.reserve('fixture',notificationMessage(event('approval.required',1,{approvalId:id}),job),3000),true);
  assert.equal(policy.reserve('fixture',notificationMessage(event('approval.required',1,{approvalId:'a'}),job),4000),false);
  assert.equal(policy.reserve('fixture',notificationMessage(event('item.completed',2000),job),1201001),true);
  db.close();
});
test('APNs uses a correct ES256 JWT and minimal category-specific payloads without logs',async()=>{
  const {privateKey,publicKey}=generateKeyPairSync('ec',{namedCurve:'P-256'});
  const sent=[];
  const notifier=new ApnsNotifier({teamId:'FIXTURE',keyId:'FIXTURE',bundleId:'test.fixture',privateKey:privateKey.export({type:'pkcs8',format:'pem'}),
    postJson:async(...args)=>{sent.push(args);return {ok:true,statusCode:200};}});
  const devices=[{platform:'ios',deviceToken:'a'.repeat(64),environment:'sandbox'}];
  await notifier.notify({envelope:event('item.completed',0,{command:'secret fixture command'}),job,devices,syncHead:{latestCursor:42}});
  const headers=sent[0][2], payload=sent[0][3];
  const jwt=headers.authorization.slice(7).split('.'); const signature=Buffer.from(jwt[2],'base64url');
  assert.equal(signature.length,64);
  assert.equal(verify('sha256',Buffer.from(jwt.slice(0,2).join('.')),{key:publicKey,dsaEncoding:'ieee-p1363'},signature),true);
  assert.equal(headers['apns-push-type'],'background'); assert.equal(headers['apns-priority'],'5');
  assert.deepEqual(payload.aps,{'content-available':1}); assert.equal(payload.latest_cursor,42);
  assert.equal(JSON.stringify(payload).includes('secret fixture'),false);
  const result=await notifier.notify({envelope:event('approval.required',1,{approvalId:'one',requestVersion:'v1',command:'another secret'}),job,devices});
  assert.equal(sent[1][3].aps.category,'AGT_APPROVAL');
  assert.equal(sent[1][3].aps['interruption-level'],'active');
  assert.equal(sent[1][3].aps.sound,undefined);
  assert.equal(result.accepted,1); assert.equal(result.delivered,null); assert.equal(result.seen,null);
  notifier.close();
});

test('quick buttons require a structured complete summary and current installation binding',async()=>{
  const {privateKey}=generateKeyPairSync('ec',{namedCurve:'P-256'});
  const sent=[];
  const notifier=new ApnsNotifier({teamId:'FIXTURE',keyId:'FIXTURE',bundleId:'test.fixture',privateKey:privateKey.export({type:'pkcs8',format:'pem'}),
    postJson:async(...args)=>{sent.push(args);return {ok:true,statusCode:200};}});
  const quickResponse={kind:'approve_reject',body:'Record fixture?\nScope: fixture only\nConsequence: append one value'};
  const payload={approvalId:'simple',requestVersion:'v1',source:'structured_approval',quickResponse};
  const device={platform:'ios',deviceToken:'a'.repeat(64),environment:'sandbox',clientScope:'installation-fixture'};
  await notifier.notify({envelope:event('approval.required',0,payload),job,devices:[device]});
  assert.equal(sent[0][3].aps.category,'AGT_APPROVAL_SIMPLE');
  assert.equal(sent[0][3].aps.alert.body,quickResponse.body);
  assert.equal(sent[0][3].clientScope,device.clientScope);
  await notifier.notify({envelope:event('approval.required',0,payload),job,devices:[{...device,deviceToken:'b'.repeat(64),clientScope:null}]});
  assert.equal(sent[1][3].aps.category,'AGT_APPROVAL');
  assert.equal(notificationMessage(event('approval.required',0,{...payload,source:'native'}),job).quickResponse,false);
  assert.equal(notificationMessage(event('approval.required',0,{...payload,quickResponse:{...quickResponse,body:'x'.repeat(1201)}}),job).quickResponse,false);
  notifier.close();
});

test('existing push registrations migrate without losing records and keep account bindings after reopening',()=>{
  const dir=mkdtempSync(join(tmpdir(),'mobile-push-'));
  const path=join(dir,'worker.sqlite');
  let store;
  try {
    const old=new Database(path);
    old.exec(`CREATE TABLE push_devices (deviceToken TEXT PRIMARY KEY, platform TEXT NOT NULL, bundleId TEXT,
      environment TEXT NOT NULL, deviceName TEXT, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL, lastSeenAt TEXT NOT NULL);
      INSERT INTO push_devices VALUES ('fixture-token','ios','test.fixture','sandbox',NULL,'t','t','t');`);
    old.close();
    store=new SqliteStore({dbPath:path});store.init();
    assert.equal(store.listPushDevices().length,1);
    assert.equal(store.listPushDevices()[0].clientScope,null);
    store.upsertPushDevice({...store.listPushDevices()[0],clientScope:'new-installation'});
    store.close();store=new SqliteStore({dbPath:path});store.init();
    assert.equal(store.listPushDevices()[0].clientScope,'new-installation');
  } finally {store?.close();rmSync(dir,{recursive:true,force:true});}
});
