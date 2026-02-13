import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { HttpError } from "./errors.js";

const JSON_BODY_LIMIT_BYTES = 1024 * 1024;
const UI_ROOT = fileURLToPath(new URL("../ui", import.meta.url));

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function contentType(path) {
  const ext = extname(path);
  switch (ext) {
    case ".html":
      return "text/html; charset=utf-8";
    case ".js":
      return "text/javascript; charset=utf-8";
    case ".css":
      return "text/css; charset=utf-8";
    case ".json":
      return "application/json; charset=utf-8";
    case ".png":
      return "image/png";
    case ".svg":
      return "image/svg+xml; charset=utf-8";
    default:
      return "application/octet-stream";
  }
}

async function maybeServeUi(req, res, pathname) {
  const method = req.method ?? "GET";
  if (method !== "GET") {
    return false;
  }

  // UI routes:
  // - `/` -> ui/index.html
  // - `/ui/*` -> static assets
  let relativePath = null;
  if (pathname === "/" || pathname === "") {
    relativePath = "index.html";
  } else if (pathname.startsWith("/ui/")) {
    relativePath = pathname.slice("/ui/".length);
  } else {
    return false;
  }

  // Prevent path traversal.
  if (relativePath.includes("..")) {
    res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Bad Request");
    return true;
  }

  try {
    const filePath = join(UI_ROOT, relativePath);
    const data = await readFile(filePath);
    res.writeHead(200, {
      "Content-Type": contentType(filePath),
      "Cache-Control": "no-store",
    });
    res.end(data);
    return true;
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Not Found");
    return true;
  }
}

function sendError(res, error) {
  if (error instanceof HttpError) {
    sendJson(res, error.status, {
      error: {
        code: error.code,
        message: error.message,
      },
    });
    return;
  }

  sendJson(res, 500, {
    error: {
      code: "INTERNAL_ERROR",
      message: error instanceof Error ? error.message : "unknown error",
    },
  });
}

async function readJsonBody(req) {
  const chunks = [];
  let total = 0;

  for await (const chunk of req) {
    total += chunk.length;
    if (total > JSON_BODY_LIMIT_BYTES) {
      throw new HttpError(413, "PAYLOAD_TOO_LARGE", "请求体过大");
    }
    chunks.push(chunk);
  }

  if (chunks.length === 0) {
    return {};
  }

  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (raw.length === 0) {
    return {};
  }

  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpError(400, "INVALID_JSON", "请求体 JSON 格式错误");
  }
}

function requireAuth(req, authToken) {
  if (!authToken) {
    return;
  }

  const header = req.headers.authorization;
  if (header !== `Bearer ${authToken}`) {
    throw new HttpError(401, "UNAUTHORIZED", "缺少或无效的 Bearer Token");
  }
}

function parseCursor(searchParams) {
  const cursorRaw = searchParams.get("cursor");
  if (cursorRaw === null) {
    return null;
  }

  const cursor = Number.parseInt(cursorRaw, 10);
  if (!Number.isInteger(cursor)) {
    throw new HttpError(400, "INVALID_CURSOR", "cursor 必须是整数");
  }

  return cursor;
}

function writeSseEvent(res, envelope) {
  res.write(`id: ${envelope.seq}\n`);
  res.write(`event: ${envelope.type}\n`);
  res.write(`data: ${JSON.stringify(envelope)}\n\n`);
}

function match(pathname, pattern) {
  const result = pathname.match(pattern);
  return result ? result.slice(1) : null;
}

export function createHttpServer(options) {
  const service = options.service;
  const logger = options.logger ?? console;
  const authToken = options.authToken ?? null;

  const server = createServer(async (req, res) => {
    const method = req.method ?? "GET";
    const requestUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
    const pathname = requestUrl.pathname;

    try {
      // Avoid noisy 404 logs from browsers; we don't need a favicon for MVP.
      if (method === "GET" && pathname === "/favicon.ico") {
        res.writeHead(204);
        res.end();
        return;
      }

      // Serve the minimal web UI without requiring auth so it can load assets.
      // API calls from the UI still follow the normal auth rules below.
      if (await maybeServeUi(req, res, pathname)) {
        return;
      }

      if (pathname !== "/health") {
        requireAuth(req, authToken);
      }

      if (method === "GET" && pathname === "/health") {
        sendJson(res, 200, {
          status: "ok",
          authEnabled: Boolean(authToken),
        });
        return;
      }

      if (method === "GET" && pathname === "/v1/projects") {
        sendJson(res, 200, {
          data: service.listProjects(),
        });
        return;
      }

      if (method === "POST" && pathname === "/v1/threads") {
        const body = await readJsonBody(req);
        const thread = await service.createThread(body);
        sendJson(res, 201, {
          thread,
        });
        return;
      }

      if (method === "GET" && pathname === "/v1/threads") {
        const result = await service.listThreads();
        sendJson(res, 200, result);
        return;
      }

      const activateMatch = match(pathname, /^\/v1\/threads\/([^/]+)\/activate$/);
      if (method === "POST" && activateMatch) {
        const threadId = decodeURIComponent(activateMatch[0]);
        const thread = await service.activateThread(threadId);
        sendJson(res, 200, {
          thread,
        });
        return;
      }

      const turnsMatch = match(pathname, /^\/v1\/threads\/([^/]+)\/turns$/);
      if (method === "POST" && turnsMatch) {
        const threadId = decodeURIComponent(turnsMatch[0]);
        const body = await readJsonBody(req);
        const job = await service.startTurn(threadId, body);
        sendJson(res, 202, job);
        return;
      }

      const jobMatch = match(pathname, /^\/v1\/jobs\/([^/]+)$/);
      if (method === "GET" && jobMatch) {
        const jobId = decodeURIComponent(jobMatch[0]);
        const job = service.getJob(jobId);
        sendJson(res, 200, job);
        return;
      }

      const eventsMatch = match(pathname, /^\/v1\/jobs\/([^/]+)\/events$/);
      if (method === "GET" && eventsMatch) {
        const jobId = decodeURIComponent(eventsMatch[0]);
        const cursor = parseCursor(requestUrl.searchParams);

        const acceptsSse = (req.headers.accept ?? "").includes("text/event-stream");
        const events = service.listEvents(jobId, cursor);
        const jobSnapshot = events.job ?? null;

        if (!acceptsSse) {
          sendJson(res, 200, events);
          return;
        }

        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache, no-transform",
          Connection: "keep-alive",
          "X-Accel-Buffering": "no",
        });

        res.write(": connected\n\n");
        for (const envelope of events.data) {
          writeSseEvent(res, envelope);
        }

        // If the job is already terminal and only replay is needed (common after restart),
        // close the SSE stream after sending the backlog.
        if (jobSnapshot && ["DONE", "FAILED", "CANCELLED"].includes(jobSnapshot.state)) {
          res.write(": eof\n\n");
          res.end();
          return;
        }

        let unsubscribe = null;
        try {
          unsubscribe = service.subscribe(jobId, (envelope) => {
            writeSseEvent(res, envelope);
          });
        } catch (err) {
          // If the job isn't active in memory, fallback to replay-only behavior.
          res.write(": eof\n\n");
          res.end();
          return;
        }

        const heartbeat = setInterval(() => {
          res.write(": ping\n\n");
        }, 15000);

        req.on("close", () => {
          clearInterval(heartbeat);
          if (unsubscribe) {
            unsubscribe();
          }
        });

        return;
      }

      const approveMatch = match(pathname, /^\/v1\/jobs\/([^/]+)\/approve$/);
      if (method === "POST" && approveMatch) {
        const jobId = decodeURIComponent(approveMatch[0]);
        const body = await readJsonBody(req);
        const result = await service.approve(jobId, body);
        sendJson(res, 200, result);
        return;
      }

      const cancelMatch = match(pathname, /^\/v1\/jobs\/([^/]+)\/cancel$/);
      if (method === "POST" && cancelMatch) {
        const jobId = decodeURIComponent(cancelMatch[0]);
        const result = await service.cancel(jobId);
        sendJson(res, 200, result);
        return;
      }

      throw new HttpError(404, "NOT_FOUND", "接口不存在");
    } catch (error) {
      logger.error("request failed", {
        method,
        pathname,
        error: error instanceof Error ? error.message : String(error),
      });
      sendError(res, error);
    }
  });

  return {
    listen(port, host = "0.0.0.0") {
      return new Promise((resolve) => {
        server.listen(port, host, () => {
          resolve(server.address());
        });
      });
    },
    close() {
      return new Promise((resolve, reject) => {
        server.close((error) => {
          if (error) {
            reject(error);
            return;
          }
          resolve();
        });
      });
    },
  };
}
