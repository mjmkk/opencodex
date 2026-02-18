/**
 * HTTP 服务器模块
 *
 * 职责：
 * - 提供 REST API 端点
 * - 提供 SSE（Server-Sent Events）事件流
 * - 处理鉴权（Bearer Token）
 *
 * @module http-server
 * @see mvp-architecture.md 第 5 节 "Worker API 契约"
 */

import { createServer } from "node:http";
import { HttpError } from "./errors.js";

// ==================== 常量定义 ====================

/** JSON 请求体最大限制（字节）：1MB */
const JSON_BODY_LIMIT_BYTES = 1024 * 1024;

// ==================== 响应辅助函数 ====================

/**
 * 发送 JSON 响应
 *
 * @param {http.ServerResponse} res - HTTP 响应对象
 * @param {number} status - HTTP 状态码
 * @param {Object} payload - 响应体（会被 JSON 序列化）
 */
function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

// ==================== 错误处理 ====================

/**
 * 发送错误响应
 *
 * 将错误转换为标准 JSON 格式：
 * { error: { code: string, message: string } }
 *
 * @param {http.ServerResponse} res - HTTP 响应对象
 * @param {Error} error - 错误对象
 */
function sendError(res, error) {
  if (error instanceof HttpError) {
    // 业务错误：使用定义的状态码和错误码
    sendJson(res, error.status, {
      error: {
        code: error.code,
        message: error.message,
      },
    });
    return;
  }

  // 未知错误：500 Internal Server Error
  sendJson(res, 500, {
    error: {
      code: "INTERNAL_ERROR",
      message: error instanceof Error ? error.message : "unknown error",
    },
  });
}

// ==================== 请求处理辅助函数 ====================

/**
 * 读取并解析 JSON 请求体
 *
 * 特性：
 * - 流式读取，支持大请求体
 * - 大小限制（1MB）
 * - 空请求体返回空对象
 *
 * @param {http.IncomingMessage} req - HTTP 请求对象
 * @returns {Promise<Object>} 解析后的 JSON 对象
 * @throws {HttpError} 413 如果请求体过大
 * @throws {HttpError} 400 如果 JSON 格式错误
 */
async function readJsonBody(req) {
  const chunks = [];
  let total = 0;

  for await (const chunk of req) {
    total += chunk.length;
    // 检查大小限制
    if (total > JSON_BODY_LIMIT_BYTES) {
      throw new HttpError(413, "PAYLOAD_TOO_LARGE", "请求体过大");
    }
    chunks.push(chunk);
  }

  // 空请求体
  if (chunks.length === 0) {
    return {};
  }

  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (raw.length === 0) {
    return {};
  }

  // 解析 JSON
  try {
    return JSON.parse(raw);
  } catch {
    throw new HttpError(400, "INVALID_JSON", "请求体 JSON 格式错误");
  }
}

/**
 * 检查鉴权
 *
 * 如果配置了 authToken，要求请求携带正确的 Bearer Token。
 *
 * @param {http.IncomingMessage} req - HTTP 请求对象
 * @param {string|null} authToken - 配置的鉴权令牌
 * @throws {HttpError} 401 如果令牌缺失或无效
 */
function requireAuth(req, authToken) {
  // 未配置鉴权，跳过
  if (!authToken) {
    return;
  }

  const header = req.headers.authorization;
  if (header !== `Bearer ${authToken}`) {
    throw new HttpError(401, "UNAUTHORIZED", "缺少或无效的 Bearer Token");
  }
}

/**
 * 解析游标参数
 *
 * 从查询字符串中解析 cursor 参数。
 *
 * @param {URLSearchParams} searchParams - URL 查询参数
 * @returns {number|null} 游标值，或 null（表示从头开始）
 * @throws {HttpError} 400 如果游标不是整数
 */
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

/**
 * 解析 limit 参数
 *
 * @param {URLSearchParams} searchParams - URL 查询参数
 * @returns {number|undefined} 分页大小，未传返回 undefined
 * @throws {HttpError} 400 如果 limit 不是正整数
 */
function parseLimit(searchParams) {
  const limitRaw = searchParams.get("limit");
  if (limitRaw === null) {
    return undefined;
  }

  const limit = Number.parseInt(limitRaw, 10);
  if (!Number.isInteger(limit) || limit <= 0) {
    throw new HttpError(400, "INVALID_LIMIT", "limit 必须是正整数");
  }
  return limit;
}

// ==================== SSE 辅助函数 ====================

/**
 * 写入 SSE 事件
 *
 * SSE 格式：
 * ```
 * id: <seq>
 * event: <type>
 * data: <json>
 *
 * ```
 *
 * @param {http.ServerResponse} res - HTTP 响应对象
 * @param {Object} envelope - 事件信封
 * @param {number} envelope.seq - 序列号
 * @param {string} envelope.type - 事件类型
 * @param {Object} envelope - 事件数据
 */
function writeSseEvent(res, envelope) {
  res.write(`id: ${envelope.seq}\n`);
  res.write(`event: ${envelope.type}\n`);
  res.write(`data: ${JSON.stringify(envelope)}\n\n`);
}

// ==================== 路由匹配 ====================

/**
 * URL 路径匹配
 *
 * @param {string} pathname - URL 路径
 * @param {RegExp} pattern - 正则模式
 * @returns {string[]|null} 捕获组数组，或 null（不匹配）
 */
function match(pathname, pattern) {
  const result = pathname.match(pattern);
  return result ? result.slice(1) : null;
}

// ==================== HTTP 服务器 ====================

/**
 * 创建 HTTP 服务器
 *
 * @param {Object} options - 配置选项
 * @param {WorkerService} options.service - Worker 服务实例
 * @param {string|null} [options.authToken] - 鉴权令牌
 * @param {Object} [options.logger] - 日志器
 * @returns {Object} 服务器对象，包含 listen 和 close 方法
 *
 * API 端点：
 *
 * | 方法 | 路径 | 说明 | 鉴权 |
 * |------|------|------|------|
 * | GET | /health | 健康检查 | 否 |
 * | GET | /v1/projects | 列出项目 | 是 |
 * | GET | /v1/models | 列出模型 | 是 |
 * | POST | /v1/threads | 创建线程 | 是 |
 * | GET | /v1/threads | 列出线程 | 是 |
 * | POST | /v1/threads/{id}/activate | 激活线程 | 是 |
 * | POST | /v1/threads/{id}/archive | 归档线程 | 是 |
 * | GET | /v1/threads/{id}/events | 获取线程历史事件 | 是 |
 * | POST | /v1/threads/{id}/turns | 发送消息 | 是 |
 * | GET | /v1/jobs/{id} | 获取任务 | 是 |
 * | GET | /v1/jobs/{id}/events | 获取事件（支持 SSE） | 是 |
 * | POST | /v1/jobs/{id}/approve | 提交审批 | 是 |
 * | POST | /v1/jobs/{id}/cancel | 取消任务 | 是 |
 * | POST | /v1/push/devices/register | 注册 APNs 设备 token | 是 |
 * | POST | /v1/push/devices/unregister | 注销 APNs 设备 token | 是 |
 *
 * @example
 * const server = createHttpServer({ service, authToken: 'secret' });
 * await server.listen(8787);
 * // 服务器运行在 http://localhost:8787
 */
export function createHttpServer(options) {
  const service = options.service;
  const logger = options.logger ?? console;
  const authToken = options.authToken ?? null;

  const server = createServer(async (req, res) => {
    const method = req.method ?? "GET";
    const requestUrl = new URL(req.url ?? "/", `http://${req.headers.host ?? "127.0.0.1"}`);
    const pathname = requestUrl.pathname;

    try {
      // 跳过 favicon（减少日志噪音）
      if (method === "GET" && pathname === "/favicon.ico") {
        res.writeHead(204);
        res.end();
        return;
      }

      // 检查鉴权（health 端点除外）
      if (pathname !== "/health") {
        requireAuth(req, authToken);
      }

      // ==================== API 路由 ====================

      // GET /health - 健康检查
      if (method === "GET" && pathname === "/health") {
        sendJson(res, 200, {
          status: "ok",
          authEnabled: Boolean(authToken),
        });
        return;
      }

      // GET /v1/projects - 列出项目
      if (method === "GET" && pathname === "/v1/projects") {
        sendJson(res, 200, {
          data: service.listProjects(),
        });
        return;
      }

      // GET /v1/models - 列出模型
      if (method === "GET" && pathname === "/v1/models") {
        const result = await service.listModels();
        sendJson(res, 200, result);
        return;
      }

      // POST /v1/threads - 创建线程
      if (method === "POST" && pathname === "/v1/threads") {
        const body = await readJsonBody(req);
        const thread = await service.createThread(body);
        sendJson(res, 201, { thread });
        return;
      }

      // GET /v1/threads - 列出线程
      if (method === "GET" && pathname === "/v1/threads") {
        const result = await service.listThreads();
        sendJson(res, 200, result);
        return;
      }

      // POST /v1/threads/{threadId}/activate - 激活线程
      const activateMatch = match(pathname, /^\/v1\/threads\/([^/]+)\/activate$/);
      if (method === "POST" && activateMatch) {
        const threadId = decodeURIComponent(activateMatch[0]);
        const thread = await service.activateThread(threadId);
        sendJson(res, 200, { thread });
        return;
      }

      // POST /v1/threads/{threadId}/archive - 归档线程
      const archiveMatch = match(pathname, /^\/v1\/threads\/([^/]+)\/archive$/);
      if (method === "POST" && archiveMatch) {
        const threadId = decodeURIComponent(archiveMatch[0]);
        const result = await service.archiveThread(threadId);
        sendJson(res, 200, result);
        return;
      }

      // GET /v1/threads/{threadId}/events - 获取线程历史事件
      const threadEventsMatch = match(pathname, /^\/v1\/threads\/([^/]+)\/events$/);
      if (method === "GET" && threadEventsMatch) {
        const threadId = decodeURIComponent(threadEventsMatch[0]);
        const cursor = parseCursor(requestUrl.searchParams);
        const limit = parseLimit(requestUrl.searchParams);
        const page = await service.listThreadEvents(threadId, { cursor, limit });
        sendJson(res, 200, page);
        return;
      }

      // POST /v1/threads/{threadId}/turns - 发送消息
      const turnsMatch = match(pathname, /^\/v1\/threads\/([^/]+)\/turns$/);
      if (method === "POST" && turnsMatch) {
        const threadId = decodeURIComponent(turnsMatch[0]);
        const body = await readJsonBody(req);
        const job = await service.startTurn(threadId, body);
        sendJson(res, 202, job);  // 202 Accepted
        return;
      }

      // GET /v1/jobs/{jobId} - 获取任务
      const jobMatch = match(pathname, /^\/v1\/jobs\/([^/]+)$/);
      if (method === "GET" && jobMatch) {
        const jobId = decodeURIComponent(jobMatch[0]);
        const job = service.getJob(jobId);
        sendJson(res, 200, job);
        return;
      }

      // GET /v1/jobs/{jobId}/events - 获取事件（支持 SSE）
      const eventsMatch = match(pathname, /^\/v1\/jobs\/([^/]+)\/events$/);
      if (method === "GET" && eventsMatch) {
        const jobId = decodeURIComponent(eventsMatch[0]);
        const cursor = parseCursor(requestUrl.searchParams);

        // 检查是否请求 SSE
        const acceptsSse = (req.headers.accept ?? "").includes("text/event-stream");
        const events = service.listEvents(jobId, cursor);
        const jobSnapshot = events.job ?? null;

        // 非 SSE 请求：返回 JSON
        if (!acceptsSse) {
          sendJson(res, 200, events);
          return;
        }

        // SSE 请求：建立长连接
        res.writeHead(200, {
          "Content-Type": "text/event-stream",
          "Cache-Control": "no-cache, no-transform",
          "Connection": "keep-alive",
          "X-Accel-Buffering": "no",  // 禁用 nginx 缓冲
        });

        // 发送初始连接确认
        res.write(": connected\n\n");

        // 发送历史事件
        for (const envelope of events.data) {
          writeSseEvent(res, envelope);
        }

        // 如果任务已终态，直接关闭连接（只需回放历史）
        if (jobSnapshot && ["DONE", "FAILED", "CANCELLED"].includes(jobSnapshot.state)) {
          res.write(": eof\n\n");
          res.end();
          return;
        }

        // 订阅实时事件
        let unsubscribe = null;
        try {
          unsubscribe = service.subscribe(jobId, (envelope) => {
            writeSseEvent(res, envelope);
          });
        } catch {
          // 任务不在内存中，仅回放历史
          res.write(": eof\n\n");
          res.end();
          return;
        }

        // 心跳：每 15 秒发送 ping，保持连接
        const heartbeat = setInterval(() => {
          res.write(": ping\n\n");
        }, 15000);

        // 客户端断开时清理
        req.on("close", () => {
          clearInterval(heartbeat);
          if (unsubscribe) {
            unsubscribe();
          }
        });

        return;
      }

      // POST /v1/jobs/{jobId}/approve - 提交审批
      const approveMatch = match(pathname, /^\/v1\/jobs\/([^/]+)\/approve$/);
      if (method === "POST" && approveMatch) {
        const jobId = decodeURIComponent(approveMatch[0]);
        const body = await readJsonBody(req);
        const result = await service.approve(jobId, body);
        sendJson(res, 200, result);
        return;
      }

      // POST /v1/jobs/{jobId}/cancel - 取消任务
      const cancelMatch = match(pathname, /^\/v1\/jobs\/([^/]+)\/cancel$/);
      if (method === "POST" && cancelMatch) {
        const jobId = decodeURIComponent(cancelMatch[0]);
        const result = await service.cancel(jobId);
        sendJson(res, 200, result);
        return;
      }

      // POST /v1/push/devices/register - 注册推送设备
      if (method === "POST" && pathname === "/v1/push/devices/register") {
        const body = await readJsonBody(req);
        const result = service.registerPushDevice(body);
        sendJson(res, 200, result);
        return;
      }

      // POST /v1/push/devices/unregister - 注销推送设备
      if (method === "POST" && pathname === "/v1/push/devices/unregister") {
        const body = await readJsonBody(req);
        const result = service.unregisterPushDevice(body);
        sendJson(res, 200, result);
        return;
      }

      // 404 - 接口不存在
      throw new HttpError(404, "NOT_FOUND", "接口不存在");

    } catch (error) {
      // 记录错误日志
      logger.error("request failed", {
        method,
        pathname,
        error: error instanceof Error ? error.message : String(error),
      });
      sendError(res, error);
    }
  });

  // 返回服务器控制接口
  return {
    /**
     * 启动服务器监听
     *
     * @param {number} port - 端口号
     * @param {string} [host='0.0.0.0'] - 监听地址
     * @returns {Promise<Object>} 服务器地址信息
     */
    listen(port, host = "0.0.0.0") {
      return new Promise((resolve) => {
        server.listen(port, host, () => {
          resolve(server.address());
        });
      });
    },

    /**
     * 关闭服务器
     *
     * @returns {Promise<void>}
     */
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
