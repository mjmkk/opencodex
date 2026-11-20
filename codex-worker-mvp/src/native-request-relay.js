import { spawn } from 'node:child_process';
import { HttpError } from './errors.js';

// Raw JSON deliberately survives Node unchanged, including 64-bit numeric RPC IDs.
export function nativeRequestRelay(config) {
  if (!config?.command || !Array.isArray(config.args)) return null;
  return (operation, body = '{}') => new Promise((resolve, reject) => {
    const child = spawn(config.command, config.args, { stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '', settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      error ? reject(error) : resolve(value);
    };
    const timer = setTimeout(() => {
      child.kill();
      finish(new HttpError(503, 'NATIVE_RESPONSE_OUTCOME_UNKNOWN', 'Read the original request; do not resubmit an uncertain response'));
    }, 15000);
    child.on('error', () => finish(new HttpError(503, 'NATIVE_REQUEST_UNAVAILABLE', 'Original owner relay unavailable')));
    child.stderr.resume();
    child.stdout.setEncoding('utf8'); // Preserve Unicode across chunk boundaries.
    child.stdout.on('data', chunk => {
      output += chunk.toString();
      if (Buffer.byteLength(output) > 2 * 1024 * 1024) {
        child.kill(); finish(new HttpError(502, 'NATIVE_RESPONSE_TOO_LARGE', 'Native request exceeds transport limit'));
      }
    });
    child.on('close', code => {
      try {
        const envelope = JSON.parse(output); // Inspect errors only; never re-serialize the payload.
        if (envelope.error) finish(new HttpError(409, envelope.error.code, envelope.error.message));
        else if (code !== 0) finish(new Error('Original owner relay failed'));
        else finish(null, output);
      } catch { finish(new HttpError(502, 'NATIVE_RESPONSE_OUTCOME_UNKNOWN', 'Original owner outcome unavailable; read before any further action')); }
    });
    child.stdin.on('error', () => {});
    child.stdin.end(`{"operation":${JSON.stringify(operation)},"body":${body}}`);
  });
}

export async function nativeRequestRoute(req, res, pathname, relay) {
  if (!pathname.startsWith('/v1/native-requests')) return false;
  if (!relay) throw new HttpError(503, 'NATIVE_REQUEST_UNAVAILABLE', 'Original owner relay is not configured');
  let operation;
  if (req.method === 'GET' && pathname === '/v1/native-requests') operation = 'list';
  if (req.method === 'POST' && pathname === '/v1/native-requests/read') operation = 'read';
  if (req.method === 'POST' && pathname === '/v1/native-requests/respond') operation = 'respond';
  if (!operation) throw new HttpError(404, 'NOT_FOUND', 'Unknown native request endpoint');
  const chunks = []; let bytes = 0;
  for await (const chunk of req) {
    bytes += chunk.length;
    if (bytes > 250000) throw new HttpError(413, 'PAYLOAD_TOO_LARGE', 'Native response too large');
    chunks.push(chunk);
  }
  const body = Buffer.concat(chunks).toString('utf8') || '{}';
  try { JSON.parse(body); } catch { throw new HttpError(400, 'INVALID_JSON', 'Invalid native JSON response'); }
  const raw = await relay(operation, body);
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(raw) });
  res.end(raw);
  return true;
}
