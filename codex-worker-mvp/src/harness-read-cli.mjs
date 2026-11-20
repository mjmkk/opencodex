// AGT-26 S6：手机端读线程的单次入口。从 stdin 读 {id}，往 stdout 写一行 JSON（统一消息模型）。
// 直接复用线上 spirit-agent 的 read_thread（Codex / ChatGPT 走官方原生读取，Claude 走 Registry 定位后 ssh 读 transcript）。
// 只读，不写任何东西。由 opencodex-mobile 的 /v1/harness/thread 调用。
import {readFileSync} from 'node:fs';
import {homedir} from 'node:os';
import {join} from 'node:path';

const R = '/opt/spirit/spirit-agent/current/runtime';
const {registryEnv} = await import(`${R}/registry_cli.mjs`);
const {registryDBFromEnv} = await import(`${R}/registry_db.mjs`);
const {createClaudeThreadReader} = await import(`${R}/claude_thread.mjs`);
const {createThreadReader, readNativeThread} = await import(`${R}/read_thread.mjs`);
const {nativeTools} = await import(`${R}/native_tools.mjs`);

let raw = '';
for await (const c of process.stdin) raw += c;
const {id} = JSON.parse(raw);
try {
  const env = await registryEnv({...process.env, AGT_REGISTRY_ENV: '/etc/spirit/spirit-agent/registry.env'});
  const registry = registryDBFromEnv(env);
  const config = JSON.parse(readFileSync(join(homedir(), '.config/spirit-agent/claude-mcp.json'), 'utf8'));
  const read = createThreadReader({
    registry,
    claudeRead: createClaudeThreadReader({hosts: config.hosts}),
    nativeRead: async args => {
      const native = await nativeTools({node: process.execPath, server: env.AGT_NATIVE_SERVER,
        profile: env.AGT_CODEX_PROFILE, contextThreadId: env.AGT_NATIVE_CONTEXT, diagnostics: false});
      try { return await readNativeThread(native.readThread, args); } finally { await native.close(); }
    },
  });
  process.stdout.write(JSON.stringify({ok: true, thread: await read({id})}));
} catch (e) {
  process.stdout.write(JSON.stringify({ok: false, error: e.code || 'read_failed'}));
}
