import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { WebSocketServer } from 'ws';
import { JsonRpcClient } from '../src/json-rpc-client.js';

test('registered Unix WebSocket transport reads the same backend and closes only its client',async t=>{
  const dir=await mkdtemp(join(tmpdir(),'opencodex-rpc-')); const socket=join(dir,'rpc.sock');
  const server=createServer(); const wss=new WebSocketServer({server});
  wss.on('connection',(ws,request)=>{ assert.equal(request.headers['sec-websocket-extensions'],undefined); ws.on('message',raw=>{
    const message=JSON.parse(raw); ws.send(JSON.stringify({id:message.id,result:{thread:{id:message.params.threadId}}}));
  }); });
  await new Promise(resolve=>server.listen(socket,resolve));
  const rpc=new JsonRpcClient({transport:'unix',socketPath:socket,requestTimeoutMs:1000});
  t.after(async()=>{await rpc.stop();wss.clients.forEach(ws=>ws.terminate());wss.close();await new Promise(resolve=>server.close(resolve));await rm(dir,{recursive:true,force:true});});
  await rpc.start(); const connectionId=rpc.connectionId;
  assert.equal((await rpc.request('thread/read',{threadId:'original'})).thread.id,'original');
  await rpc.stop(); assert.equal(server.listening,true);
  await rpc.start(); assert.notEqual(rpc.connectionId,connectionId);
  assert.equal((await rpc.request('thread/read',{threadId:'original'})).thread.id,'original');
});

test('a silent native endpoint fails within the deadline without starting inference',async t=>{
  const {createServer: netServer}=await import('node:net');
  const dir=await mkdtemp(join(tmpdir(),'opencodex-rpc-timeout-')); const socket=join(dir,'rpc.sock');
  const connections=[];const server=netServer(c=>{connections.push(c);c.resume()});
  await new Promise(resolve=>server.listen(socket,resolve));
  const rpc=new JsonRpcClient({transport:'unix',socketPath:socket,requestTimeoutMs:40});
  t.after(async()=>{await rpc.stop();connections.forEach(c=>c.destroy());await new Promise(resolve=>server.close(resolve));await rm(dir,{recursive:true,force:true})});
  await assert.rejects(rpc.start(),/handshake|WebSocket was closed/);
  assert.equal(rpc.started,false);assert.equal(server.listening,true);
});
