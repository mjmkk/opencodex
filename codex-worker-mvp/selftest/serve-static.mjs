import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDir = fileURLToPath(new URL('.', import.meta.url));

function contentType(path) {
  const ext = extname(path);
  switch (ext) {
    case '.html':
      return 'text/html; charset=utf-8';
    case '.js':
      return 'text/javascript; charset=utf-8';
    case '.mjs':
      return 'text/javascript; charset=utf-8';
    case '.css':
      return 'text/css; charset=utf-8';
    case '.json':
      return 'application/json; charset=utf-8';
    case '.png':
      return 'image/png';
    default:
      return 'application/octet-stream';
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    let pathname = decodeURIComponent(url.pathname);
    if (pathname === '/') {
      pathname = '/browser-click-selftest.html';
    }

    // Prevent path traversal.
    if (pathname.includes('..')) {
      res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Bad Request');
      return;
    }

    // `path.join(root, '/abs')` 会忽略 root；这里强制使用相对路径。
    const relativePath = pathname.startsWith('/') ? pathname.slice(1) : pathname;
    const filePath = join(rootDir, relativePath);
    const data = await readFile(filePath);

    res.writeHead(200, {
      'Content-Type': contentType(filePath),
      'Cache-Control': 'no-store',
    });
    res.end(data);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('Not Found');
  }
});

server.listen(0, '127.0.0.1', () => {
  const addr = server.address();
  const port = typeof addr === 'object' && addr ? addr.port : 0;
  // Print a trailing newline so shell scripts can `read` the value reliably.
  process.stdout.write(`${String(port)}\n`);
});
