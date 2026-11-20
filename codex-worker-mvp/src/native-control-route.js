import { HttpError } from './errors.js';

// Native transport forwarding under the existing bearer/TLS boundary. These
// paths do not create a Human-message/approval workflow or a legacy worker job.
export async function nativeControlRoute(req, res, pathname, control) {
  if (!pathname.startsWith('/v1/native-threads/')) return false;
  if (!control || typeof control.read !== 'function' || typeof control.submit !== 'function')
    throw new HttpError(503, 'NATIVE_CONTROL_UNAVAILABLE', 'Native control forwarding is not connected');
  const match = /^\/v1\/native-threads\/([0-9a-f-]{36})\/(control|input|interrupt|submissions\/([A-Za-z0-9_-]{16,100}))$/.exec(pathname);
  if (!match) throw new HttpError(404, 'NOT_FOUND', 'Unknown native control endpoint');
  const [, threadId, action, submissionId] = match;
  let result;
  if (req.method === 'GET' && action === 'control') result = await control.read(threadId);
  else if (req.method === 'GET' && submissionId) result = control.receipt(threadId, submissionId);
  else if (req.method === 'POST' && ['input', 'interrupt'].includes(action)) {
    const chunks = []; let size = 0;
    for await (const chunk of req) {
      size += chunk.length;
      if (size > 250000) throw new HttpError(413, 'PAYLOAD_TOO_LARGE', 'Native input exceeds transport limit');
      chunks.push(chunk);
    }
    let body;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { throw new HttpError(400, 'INVALID_JSON', 'Invalid native control JSON'); }
    result = await control.submit(threadId, action, body);
  } else throw new HttpError(405, 'METHOD_NOT_ALLOWED', 'Native control method not supported');
  const raw = JSON.stringify(result);
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store', 'Content-Length': Buffer.byteLength(raw) });
  res.end(raw);
  return true;
}
