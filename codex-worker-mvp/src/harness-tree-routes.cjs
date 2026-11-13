'use strict';
// AGT-26 S6：手机端首页「以 Goal 为主轴」的数据接口（只读）。
// GET /v1/harness/tree 返回 Registry 里的 Goal → 成员树：每个 Goal 有 Master、思考线程（chatgpt）、Worker，
// 每个成员带 role、kind（codex / claude / chatgpt）、host、标题、原生 id。
// 每个 Node 的 ~/.agt-node/status.json（由钩子 outbox 汇总）会补上 status、model 和子代理。
// 这个接口挂在现有 Bearer 鉴权之后（mobileRoutes 扩展点），自己不再做鉴权；只读 Registry，不调用模型，不写库。
const { execFile } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { projectHarness } = require('./harness-topology.cjs');

const SQL = `select coalesce(json_agg(g order by g->>'updated_at' desc), '[]'::json) from (
  select json_build_object(
    'issue_id', i.issue_id, 'updated_at', i.updated_at, 'registry', i.registry,
    'members', coalesce((select json_agg(json_build_object(
        'role', m.role, 'id', m.thread_id, 'host_id', m.host_id,
        'kind', coalesce(m.metadata->>'kind', case when m.role='chatgpt' then 'chatgpt' else 'codex' end),
        'title', m.metadata->>'title', 'model', m.metadata->>'model')
      order by case m.role when 'chatgpt' then 0 when 'master' then 1 else 2 end, m.thread_id)
      from agt_registry.members m where m.namespace=i.namespace and m.issue_id=i.issue_id), '[]'::json)
  ) g from agt_registry.issues i where i.namespace=%s
) t`;

// 有 Node 的机器。local 表示本机（spirit-master），其他机器通过 ssh 别名访问
const DEFAULT_NODES = { local: null, 'mac-m1pro': 'mac-m1pro', 'agt-ubuntu-worker': 'agt-ubuntu-worker' };

function createHarnessTreeRoutes({ dsn, namespace, python = '/usr/bin/python3', timeoutMs = 8000, nodes = DEFAULT_NODES,
  sendDeps = {} }) {
  // 用 psycopg 读取。DSN 来自受信的服务配置，客户端无法指定
  const script = 'import json,os,sys,psycopg\n' +
    'with psycopg.connect(os.environ["D"]) as c:\n' +
    '  sys.stdout.write(json.dumps(c.execute(os.environ["Q"],(os.environ["N"],)).fetchone()[0]))';
  const read = () => new Promise((resolve, reject) => {
    execFile(python, ['-c', script], { timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024,
      env: { PATH: '/usr/bin:/bin', D: dsn, N: namespace, Q: SQL } },
    (err, stdout) => err ? reject(err) : resolve(JSON.parse(stdout)));
  });

  // 每台 Node 的状态快照缓存 15 秒；读不到的 Node 直接跳过，不影响整页
  let cache = { at: 0, value: {} };
  const one = alias => new Promise(resolve => {
    if (alias === null) {
      try { resolve(JSON.parse(fs.readFileSync(path.join(os.homedir(), '.agt-node/status.json'), 'utf8'))); }
      catch { resolve(null); }
      return;
    }
    execFile('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=4', alias, 'cat ~/.agt-node/status.json'],
      { timeout: 6000, maxBuffer: 4 * 1024 * 1024 },
      (err, out) => { try { resolve(err ? null : JSON.parse(out)); } catch { resolve(null); } });
  });
  const nodeStatus = async () => {
    if (Date.now() - cache.at < 15000) return cache.value;
    const merged = {};
    for (const snap of await Promise.all(Object.values(nodes).map(one)))
      if (snap && snap.threads) Object.assign(merged, snap.threads);
    cache = { at: Date.now(), value: merged };
    return merged;
  };

  // 读取当前 Linear Goal 标签和父链，缓存 10 分钟。失败返回不可用，让手机保留最后成功的树，
  // 不把网络错误解释成无 Master。API key 只在服务端读取，不下发。
  let titles = { at: 0, value: {} };
  let topology = { nodes: {}, observedAt: null, unavailable: true };
  const linearKey = () => {
    try {
      const env = fs.readFileSync('/etc/spirit/spirit-agent/registry.env', 'utf8');
      const file = (env.match(/^AGT_LINEAR_CREDENTIALS=(.*)$/m) || [])[1]?.replace(/^"|"$/g, '');
      return file ? JSON.parse(fs.readFileSync(file, 'utf8')).apiKey : null;
    } catch { return null; }
  };
  const issueTitles = sendDeps.issueTitles || (async ids => {
    if (Date.now() - titles.at < 600000 && ids.every(id => id in titles.value)) return titles.value;
    const key = linearKey();
    if (!key || !ids.length) return titles.value;
    try {
      // 按 team 分组，用 team key + number 过滤：不存在的 Issue 只是查不到，不会让整个请求失败
      const byTeam = {};
      for (const id of ids) {
        const m = /^([A-Z][A-Z0-9]*)-(\d+)$/.exec(id);
        if (m) (byTeam[m[1]] ||= []).push(Number(m[2]));
      }
      const fields = 'id identifier title updatedAt archivedAt labels{nodes{name}} project{id name labels{nodes{name}}} parent{id identifier}';
      const q = `query($t:String!,$n:[Float!]){issues(first:250,filter:{team:{key:{eq:$t}},number:{in:$n}}){nodes{${fields}}}}`;
      const value = { ...titles.value };
      const issueNodes = {};
      const remember = node => {
        value[node.identifier] = node.title;
        issueNodes[node.identifier] = { ...node, uuid: node.id,
          labels: node.labels.nodes.map(l => l.name),
          project: node.project ? { ...node.project, labels: node.project.labels.nodes.map(l => l.name) } : null };
      };
      for (const [t, n] of Object.entries(byTeam)) {
        const r = await fetch('https://api.linear.app/graphql', { method: 'POST',
          headers: { 'content-type': 'application/json', authorization: key },
          body: JSON.stringify({ query: q, variables: { t, n } }), signal: AbortSignal.timeout(8000) });
        const d = await r.json();
        if (!r.ok || d.errors || !d?.data?.issues?.nodes) throw new Error('linear_topology_unavailable');
        for (const node of d.data.issues.nodes) remember(node);
      }
      // 父 Issue 不要求已登记线程；补齐 Registry 之外的父链，仍交由生产 resolver 判定 Goal。
      const attempted = new Set();
      while (true) {
        const missing = Object.values(issueNodes).map(n => n.parent)
          .find(p => p && !issueNodes[p.identifier] && !attempted.has(p.id));
        if (!missing) break;
        if (attempted.size >= 128) throw new Error('topology_too_deep');
        attempted.add(missing.id);
        const r = await fetch('https://api.linear.app/graphql', { method: 'POST',
          headers: { 'content-type': 'application/json', authorization: key },
          body: JSON.stringify({ query: `query($id:String!){issue(id:$id){${fields}}}`, variables: { id: missing.id } }),
          signal: AbortSignal.timeout(8000) });
        const d = await r.json();
        if (!r.ok || d.errors || !d?.data?.issue) throw new Error('parent_topology_unavailable');
        remember(d.data.issue);
      }
      for (const id of ids) if (!(id in value)) value[id] = null;
      titles = { at: Date.now(), value };
      topology = { nodes: issueNodes, observedAt: new Date().toISOString(), unavailable: false };
    } catch { topology.unavailable = true; /* 不把关系读取失败伪装成没有 Master */ }
    return titles.value;
  });

  const nodeBin = '/opt/spirit/chatgpt-desktop/current/resources/cua_node/bin/node';
  const readerCli = path.join(os.homedir(), 'scratch/agt-s6/harness-read-cli.mjs');
  // ---------- POST /v1/harness/send：Human 在手机上回复一条线程 ----------
  // 按 Registry 里这条线程的 kind 和 host 选投递方式，全部复用 AGT Node 已经在用的通道：
  //   codex + spirit-master  → 本机 ~/scratch/agt-s2/enqueue.mjs（原生 queue，O_EXCL 持久化 once）
  //   codex + M1 Mac         → ssh mac-m1pro ~/.agt-node/queue/enqueue.mjs（同一套 once 守卫）
  //   claude + M1 Mac        → ssh mac-m1pro 调 deliver.py 的 deliver_claude（原生 inbox socket，带送达确认）
  // 其他组合（Ubuntu、remote-control 设备）还没有可写通道，明确返回 unsupported，不假装发出去了。
  // client_message_id 由客户端生成，同一个 id 只会投递一次；结果不明时返回 unconfirmed，客户端不要重发。
  const MEMBER_SQL = `select coalesce(metadata->>'kind','codex') as kind, host_id from agt_registry.members
    where namespace=%s and thread_id=%s and role in ('master','worker') limit 1`;
  const memberScript = 'import json,os,sys,psycopg\n' +
    'with psycopg.connect(os.environ["D"]) as c:\n' +
    '  r=c.execute(os.environ["Q"],(os.environ["N"],os.environ["T"])).fetchone()\n' +
    '  sys.stdout.write(json.dumps(r and {"kind":r[0],"host":r[1]}))';
  const lookup = sendDeps.lookup || (id => new Promise((resolve, reject) => {
    execFile(python, ['-c', memberScript], { timeout: timeoutMs,
      env: { PATH: '/usr/bin:/bin', D: dsn, N: namespace, Q: MEMBER_SQL, T: id } },
    (err, stdout) => err ? reject(err) : resolve(JSON.parse(stdout)));
  }));
  const run = sendDeps.run || ((cmd, args, input, env) => new Promise(resolve => {
    const child = execFile(cmd, args, { timeout: 60000, maxBuffer: 1024 * 1024, env: { ...process.env, ...env } },
      (err, out) => resolve({ err, out: String(out || '').trim() }));
    child.stdin.end(input);
  }));
  const lastJson = out => { try { return JSON.parse(out.split('\n').pop()); } catch { return null; } };
  const liveTailScript = sendDeps.liveTailScript || path.join(__dirname, 'live-tail.py');
  const sentRoot = sendDeps.sentRoot || path.join(os.homedir(), 'scratch/agt-s6/sent');
  const ssh = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', 'mac-m1pro'];
  const CLAUDE_RELAY = "import importlib.util,json,sys,os;" +
    "s=importlib.util.spec_from_file_location('d',os.path.expanduser('~/.agt-node/deliver.py'));" +
    "d=importlib.util.module_from_spec(s);s.loader.exec_module(d);" +
    "a=json.load(sys.stdin);print(d.deliver_claude(a['sid'],a['text']))";

  const queueResult = r => {
    if (!r) return { status: 'unconfirmed' };
    if (r.ok) return { status: 'queued' };
    if (r.code === 'duplicate_refused') return { status: 'duplicate' };
    if (r.code === 'duplicate_conflict') return { status: 'conflict' };
    return r.submission === 'submitted' ? { status: 'unconfirmed', code: r.code } : { status: 'failed', code: r.code };
  };

  async function send(id, text, cmid) {
    const m = await lookup(id);
    if (!m) return { status: 'unsupported', code: 'not_in_registry' };
    const payload = JSON.stringify({ threadId: id, clientUserMessageId: 'agt-human-' + cmid, prompt: text,
      invocationId: 'mobile:' + cmid });
    if (m.kind === 'codex' && m.host === 'local') {
      const r = await run(process.execPath, [path.join(os.homedir(), 'scratch/agt-s2/enqueue.mjs')], payload);
      return queueResult(lastJson(r.out));
    }
    if (m.kind === 'codex' && m.host === 'mac-m1pro') {
      // Mac 上的 Codex：走 Mac 本机的原生控制通道（follower adapter 的 start/steer，线程没加载时后台 open -g 拉起），
      // 同一个 client_message_id 在 Mac 上用 O_EXCL 占位，只发一次
      const r = await run('ssh', [...ssh, 'python3 ~/.agt-node/native/send.py'],
        JSON.stringify({ thread_id: id, text, submission_id: 'agt-human-' + cmid }));
      if (r.err && !r.out) return { status: 'failed', code: 'host_unreachable' };
      const o = lastJson(r.out) || {};
      return { status: o.status || 'unconfirmed', ...(o.code ? { code: o.code } : {}) };
    }
    if (m.kind === 'claude' && m.host === 'mac-m1pro') {
      // Claude 的 inbox 本身不去重，这里用 O_EXCL 文件占位：同一个 client_message_id 只投一次
      const dir = path.join(sentRoot, id.replace(/[^A-Za-z0-9_.-]/g, '_'));
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      try { fs.writeFileSync(path.join(dir, cmid + '.json'), JSON.stringify({ at: new Date().toISOString() }), { flag: 'wx' }); }
      catch (e) { if (e.code === 'EEXIST') return { status: 'duplicate' }; throw e; }
      const r = await run('ssh', [...ssh, `python3 -c "${CLAUDE_RELAY}"`], JSON.stringify({ sid: id, text: '[Human 从手机回复]\n' + text }));
      const st = r.out.split('\n').pop();
      if (st === 'received') return { status: 'received' };
      if (st === 'master_offline') return { status: 'offline' };
      if (st === 'written_unconfirmed') return { status: 'unconfirmed' };
      return { status: r.err && !r.out ? 'failed' : 'unconfirmed', code: 'relay' };
    }
    return { status: 'unsupported', code: `${m.kind}@${m.host}` };
  }

  return async function harnessTreeRoutes(req, res) {
    const url = new URL(req.url, 'http://local');
    // POST /v1/harness/rename：给线程或 Goal（通过 Master）改名。
    // body: {thread_id, issue_id, new_name, revision}
    // 改名只更新 Registry 里的 metadata.title，不调用原生接口（从不 read_thread）。
    // 对 Codex 线程还会通过 ssh→Mac 调用 thread/name/set，让 Desktop 侧边栏同步（失败不影响 Registry 写入）。
    if (url.pathname === '/v1/harness/rename') {
      const reply = (code, body) => { res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(body)); };
      if (req.method !== 'POST') { reply(405, { ok: false, error: 'method_not_allowed' }); return true; }
      let raw = '';
      for await (const c of req) { raw += c; if (raw.length > 20000) { reply(413, { ok: false, error: 'too_large' }); return true; } }
      let b; try { b = JSON.parse(raw); } catch { reply(400, { ok: false, error: 'invalid_json' }); return true; }
      const { thread_id: tid, issue_id: iid, new_name: name, revision: rev } = b || {};
      if (typeof name !== 'string' || !name.trim() || name.length > 300
          || typeof rev !== 'number' || !Number.isInteger(rev) || rev < 0
          || (tid == null && iid == null)) {
        reply(400, { ok: false, error: 'invalid_request' }); return true;
      }
      try {
        // 用 psycopg 写 Registry，直接 UPDATE metadata jsonb 字段，绕过 registry_cli 的 native read
        const updateScript = 'import json,os,sys,psycopg\n' +
          'with psycopg.connect(os.environ["D"]) as c:\n' +
          '  tid=os.environ.get("TID")\n' +
          '  iid=os.environ.get("IID")\n' +
          '  rev=int(os.environ["REV"])\n' +
          '  name=os.environ["NAME"]\n' +
          '  if tid:\n' +
          '    r=c.execute("UPDATE agt_registry.members SET metadata=jsonb_set(coalesce(metadata,\'{}\'::jsonb),\'{title}\',to_jsonb(%s::text)) WHERE namespace=%s AND thread_id=%s RETURNING thread_id",\n' +
          '      (name,os.environ["NS"],tid))\n' +
          '    rows=r.fetchall()\n' +
          '  else:\n' +
          '    r=c.execute("UPDATE agt_registry.issues SET updated_at=now() WHERE namespace=%s AND issue_id=%s AND EXISTS(SELECT 1 FROM agt_registry.members WHERE namespace=%s AND issue_id=%s) RETURNING issue_id",\n' +
          '      (os.environ["NS"],iid,os.environ["NS"],iid))\n' +
          '    rows=r.fetchall()\n' +
          '  c.commit()\n' +
          '  sys.stdout.write(json.dumps({"updated":len(rows)}))';
        const env = { PATH: '/usr/bin:/bin', D: dsn, NS: namespace, REV: String(rev), NAME: name.trim() };
        if (tid) env.TID = tid; else env.IID = iid;
        const updated = await new Promise((resolve, reject) =>
          execFile(python, ['-c', updateScript], { timeout: timeoutMs, env }, (err, out) =>
            err ? reject(err) : resolve(JSON.parse(out))));
        if (!updated.updated) { reply(409, { ok: false, error: 'not_found_or_conflict' }); return true; }
        // Best-effort: also rename in Codex Desktop on Mac
        if (tid) {
          run('ssh', [...ssh, `python3 -c "
import json,sys; sys.path.insert(0,'${nodeBin.replace('/bin/node','/../codex')}')
" 2>/dev/null || true; /opt/homebrew/bin/node -e "
const c=require('net').createConnection('$(python3 -c "import os;print(os.path.realpath(os.path.expanduser(\"~/.codex/ipc/ipc.sock\")))")');
const s=(o)=>{const b=Buffer.from(JSON.stringify(o));const h=Buffer.alloc(4);h.writeUInt32LE(b.length);c.write(Buffer.concat([h,b]));};
let buf=Buffer.alloc(0),cid=null;
c.on('connect',()=>s({type:'request',requestId:'r0',sourceClientId:'initializing-client',version:0,method:'initialize',params:{clientType:'desktop'},timeoutMs:5000}));
c.on('data',d=>{buf=Buffer.concat([buf,d]);while(buf.length>=4){const n=buf.readUInt32LE(0);if(buf.length<4+n)break;const m=JSON.parse(buf.subarray(4,4+n));buf=buf.subarray(4+n);
 if(m.type==='client-discovery-request'){s({type:'client-discovery-response',requestId:m.requestId,response:{canHandle:false}});continue;}
 if(m.type!=='response')continue;
 if(m.requestId==='r0'){cid=m.result.clientId;s({type:'request',requestId:'r1',sourceClientId:cid,version:1,method:'thread/name/set',params:{conversationId:'${tid}',name:${JSON.stringify(name.trim())}},timeoutMs:5000});}
 else{process.exit(0);}}});
setTimeout(()=>process.exit(0),8000);" 2>&1 || true`], '');
        }
        reply(200, { ok: true, updated: updated.updated });
      } catch { reply(503, { ok: false, error: 'rename_unavailable' }); }
      return true;
    }

        if (url.pathname === '/v1/harness/send') {
      const reply = (code, body) => { res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(body)); };
      if (req.method !== 'POST') { reply(405, { ok: false, error: 'method_not_allowed' }); return true; }
      let raw = '';
      for await (const c of req) { raw += c; if (raw.length > 120000) { reply(413, { ok: false, error: 'too_large' }); return true; } }
      let b; try { b = JSON.parse(raw); } catch { reply(400, { ok: false, error: 'invalid_json' }); return true; }
      const { id, text, client_message_id: cmid } = b || {};
      if (typeof id !== 'string' || !/^[0-9a-f-]{36}$/.test(id) || typeof text !== 'string' || !text.trim()
          || text.length > 100000 || typeof cmid !== 'string' || !/^[A-Za-z0-9_-]{16,100}$/.test(cmid)) {
        reply(400, { ok: false, error: 'invalid_request' }); return true;
      }
      try {
        const r = await send(id, text, cmid);
        reply(200, { ok: ['queued', 'received', 'duplicate'].includes(r.status), ...r });
      } catch { reply(503, { ok: false, status: 'failed', code: 'send_unavailable' }); }
      return true;
    }
    // GET /v1/harness/live?id=<Codex 线程 id>：直接读这条线程在本机（或 Mac）上的会话文件末尾，
    // 返回最近的用户消息和回复，以及是否还在回复中。不调用 read_thread，不占云端历史读取额度，
    // 所以手机可以每几秒问一次。文件在哪台机器由 Registry 的 host 决定（本机、Mac、Ubuntu Worker），remote-control 设备返回 unsupported。
    if (url.pathname === '/v1/harness/live') {
      const id = url.searchParams.get('id') || '';
      const reply = (code, body) => { res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        res.end(JSON.stringify(body)); };
      if (req.method !== 'GET' || !/^[0-9a-f-]{36}$/.test(id)) { reply(400, { ok: false, error: 'invalid_id' }); return true; }
      try {
        const m = await lookup(id);
        if (!m || m.kind !== 'codex') { reply(404, { ok: false, error: 'not_codex' }); return true; }
        const script = fs.readFileSync(liveTailScript);
        let r;
        if (m.host === 'local') r = await run('/usr/bin/python3', ['-', id], script);
        else if (m.host === 'mac-m1pro') r = await run('ssh', [...ssh, 'python3 - ' + id], script);
        else if (m.host === 'remote-ssh-discovered:agt-ubuntu-worker')
          r = await run('ssh', ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', 'agt-ubuntu-worker', 'python3 - ' + id], script);
        else { reply(200, { ok: false, error: 'unsupported', host: m.host }); return true; }
        const body = lastJson(r.out);
        reply(body ? 200 : 502, body || { ok: false, error: 'reader_failed' });
      } catch { reply(503, { ok: false, error: 'live_unavailable' }); }
      return true;
    }
    // GET /v1/harness/thread?id=<原生 id>：只给 Claude 会话用（Codex 线程继续走现有 Mirror，避免占用原生读取配额）。
    // 返回统一消息模型 {kind, host_id, model, turns:[{items:[{role,text,at}]}], subagents}
    if (url.pathname === '/v1/harness/thread') {
      const id = url.searchParams.get('id') || '';
      if (req.method !== 'GET' || !/^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}(\/[A-Za-z0-9][A-Za-z0-9_.:-]{0,127})?$/.test(id)) {
        res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ ok: false, error: 'invalid_id' })); return true;
      }
      execFile(nodeBin, [readerCli], { timeout: 30000, maxBuffer: 16 * 1024 * 1024 }, (err, out) => {
        let body; try { body = JSON.parse(out); } catch { body = { ok: false, error: 'reader_failed' }; }
        // 不是 Claude 的线程让客户端回到 Mirror
        if (body.ok && body.thread && body.thread.kind !== 'claude') body = { ok: false, error: 'use_mirror' };
        res.writeHead(body.ok ? 200 : (body.error === 'use_mirror' ? 409 : 502),
          { 'content-type': 'application/json', 'cache-control': 'no-store' });
        res.end(JSON.stringify(body));
      }).stdin.end(JSON.stringify({ id }));
      return true;
    }
    if (url.pathname !== '/v1/harness/tree') return false;
    if (req.method !== 'GET' || url.search) {
      res.writeHead(400, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: 'invalid_request' })); return true;
    }
    try {
      const inventory = await read();
      const [status, names] = await Promise.all([nodeStatus(), issueTitles(inventory.map(g => g.issue_id))]);
      if (topology.unavailable) throw new Error('linear_topology_unavailable');
      const goals = await projectHarness({ groups: inventory, issueNodes: topology.nodes,
        topologyObservedAt: topology.observedAt, topologyUnavailable: topology.unavailable });
      for (const g of goals) if (names[g.issue_id]) g.title = names[g.issue_id];
      for (const g of goals) for (const m of g.members) {
        const t = status[m.id];
        if (!t) continue;               // 没有观测到的成员保持 unknown，不编造
        m.status = t.status || null;
        if (!m.model && t.model) m.model = t.model;
        // 只有仍在 needs_you 时才带“在等什么”，Node 那边状态变了就不会再有
        if (t.status === 'needs_you' && t.waiting) m.waiting = t.waiting;
        if (t.subagents && t.subagents.length)
          m.subagents = t.subagents.map(s => ({ id: s.id, kind: m.kind, host_id: m.host_id,
            title: s.type || null, status: s.status }));
      }
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify({ ok: true, schema_version: 2, namespace, observed_at: new Date().toISOString(), goals }));
    } catch {
      res.writeHead(503, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: 'harness_tree_unavailable' }));
    }
    return true;
  };
}
module.exports = { createHarnessTreeRoutes };
