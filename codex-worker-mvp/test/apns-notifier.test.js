import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import Database from 'better-sqlite3';
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
