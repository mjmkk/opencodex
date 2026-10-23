import test from 'node:test';
import assert from 'node:assert/strict';
import { DesktopRelayClient } from '../src/desktop-relay-client.js';

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
