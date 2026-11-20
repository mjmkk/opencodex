'use strict';
const { execFile } = require('node:child_process');
const path = require('node:path');

// Mount only AFTER the existing server's authentication check.
function createMirrorRoutes({ namespace, dsn, blobRoot, python = '/home/spirit/agt28-mirror/.venv/bin/python' }) {
  if (!namespace || !dsn) throw new Error('Mirror server configuration required');
  function invoke(input) {
    return new Promise(resolve => {
      const child = execFile(python, [path.join(__dirname, 'adapter.py')], {
        timeout: 15000, maxBuffer: 16 * 1024 * 1024,
        env: { PATH: '/usr/bin:/bin', LANG: 'C.UTF-8', MIRROR_NAMESPACE: namespace, MIRROR_DSN: dsn, ...(blobRoot ? {MIRROR_BLOBS: blobRoot} : {}), PYTHONDONTWRITEBYTECODE: '1' },
      }, (error, stdout) => {
        if (error) return resolve({ ok: false, status: 503, error: { code: 'mirror_unavailable' } });
        try { resolve(JSON.parse(stdout)); }
        catch { resolve({ ok: false, status: 503, error: { code: 'mirror_unavailable' } }); }
      });
      child.stdin.on('error', () => {});
      child.stdin.end(JSON.stringify(input));
    });
  }
  return async function mirrorRoutes(req, res) {
    const url = new URL(req.url, 'http://localhost');
    if (!url.pathname.startsWith('/v1/mirror/')) return false;
    const send = (status, data) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(data));
      return true;
    };
    if (req.method !== 'GET') return send(405, { ok: false, error: { code: 'method_not_allowed' } });
    let input;
    if (url.pathname === '/v1/mirror/threads') input = { operation: 'index', limit: url.searchParams.get('limit') };
    else if (url.pathname === '/v1/mirror/registry') input = { operation: 'registry', issue_id: url.searchParams.get('issue_id') };
    else {
      const match = url.pathname.match(/^\/v1\/mirror\/threads\/([^/]+)$/);
      if (!match) return send(404, { ok: false, error: { code: 'route_not_found' } });
      const offline = url.searchParams.get('offline');
      if (offline !== null && offline !== 'true' && offline !== 'false') return send(400, { ok: false, error: { code: 'invalid_offline' } });
      const flag = name => { const v = url.searchParams.get(name); return v === null ? undefined : v === 'true' ? true : v === 'false' ? false : null; };
      const tail = flag('tail'), items = flag('items');
      if (tail === null || items === null) return send(400, { ok: false, error: { code: 'invalid_request' } });
      try {
        input = { operation: 'body', thread_id: decodeURIComponent(match[1]), offline: offline !== 'false',
          offset: url.searchParams.get('offset'), limit: url.searchParams.get('limit'), snapshot: url.searchParams.get('snapshot'),
          ...(tail !== undefined ? { tail } : {}), ...(items !== undefined ? { items } : {}) };
      } catch { return send(400, { ok: false, error: { code: 'invalid_thread_id' } }); }
    }
    // Reject account overrides instead of silently trusting client parameters.
    if (url.searchParams.has('namespace') || url.searchParams.has('dsn')) return send(400, { ok: false, error: { code: 'invalid_request' } });
    const result = await invoke(input);
    return send(result.ok ? 200 : (result.status || 503), result);
  };
}
module.exports = { createMirrorRoutes };
