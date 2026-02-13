/**
 * JSON-RPC 2.0 客户端
 *
 * 职责：
 * - 管理 codex app-server 子进程的生命周期
 * - 发送 JSON-RPC 请求并等待响应（client request）
 * - 接收服务端推送的通知（notification）和请求（server request）
 * - 处理审批请求的响应回传
 *
 * JSON-RPC 消息类型：
 * - 请求（request）：有 id 有 method，需要响应
 * - 响应（response）：有 id 无 method，包含 result 或 error
 * - 通知（notification）：无 id 有 method，不需要响应
 *
 * @module JsonRpcClient
 * @see mvp-architecture.md 第 8.1 节 "JSON-RPC Bridge"
 * @see https://www.jsonrpc.org/specification JSON-RPC 2.0 规范
 */

import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { createInterface } from "node:readline";

/** 默认请求超时时间（毫秒）：2 分钟 */
const DEFAULT_REQUEST_TIMEOUT_MS = 120000;

/**
 * JSON-RPC 2.0 客户端
 *
 * 通过 stdio 与 codex app-server 子进程通信。
 * 继承 EventEmitter，支持以下事件：
 *
 * @fires notification - 收到服务端通知（如 turn/started、item/delta）
 * @fires request - 收到服务端请求（如审批请求）
 * @fires stderr - 子进程 stderr 有输出
 * @fires error - 子进程发生错误
 * @fires exit - 子进程退出
 * @fires protocolError - 收到无效的协议消息
 *
 * @example
 * const rpc = new JsonRpcClient({ command: 'codex', args: ['app-server'] });
 * await rpc.start();
 *
 * // 发送请求
 * const result = await rpc.request('thread/start', { cwd: '/project' });
 *
 * // 监听审批请求
 * rpc.on('request', (message) => {
 *   if (message.method === 'item/commandExecution/requestApproval') {
 *     // 处理审批...
 *     rpc.respond(message.id, { decision: 'accept' });
 *   }
 * });
 *
 * // 监听事件通知
 * rpc.on('notification', (message) => {
 *   console.log('收到事件:', message.method);
 * });
 */
export class JsonRpcClient extends EventEmitter {
  /**
   * 创建 JSON-RPC 客户端实例
   *
   * @param {Object} options - 配置选项
   * @param {string} [options.command='codex'] - codex 可执行文件路径或命令名
   * @param {string[]} [options.args=['app-server']] - 启动参数，默认启动 app-server 模式
   * @param {string} [options.cwd=process.cwd()] - 子进程工作目录
   * @param {Object} [options.env=process.env] - 子进程环境变量
   * @param {number} [options.requestTimeoutMs=120000] - 请求超时时间（毫秒）
   */
  constructor(options = {}) {
    super();
    // 子进程配置
    this.command = options.command ?? "codex";
    this.args = options.args ?? ["app-server"];
    this.cwd = options.cwd ?? process.cwd();
    this.env = options.env ?? process.env;
    this.requestTimeoutMs = options.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;

    // 运行时状态
    this.child = null;           // 子进程引用
    this.started = false;        // 是否已启动
    this.nextId = 1;             // 下一个请求 ID（JSON-RPC 要求唯一）
    this.pending = new Map();    // 等待响应的请求：id -> { resolve, reject, timeout, method }
  }

  /**
   * 启动子进程并建立通信
   *
   * 启动流程：
   * 1. spawn 子进程，使用 pipe 模式的 stdio
   * 2. 监听 stderr 输出（日志/警告）
   * 3. 监听子进程错误和退出事件
   * 4. 逐行读取 stdout 并解析 JSON-RPC 消息
   *
   * @returns {Promise<void>}
   * @throws {Error} 如果子进程启动失败
   *
   * @example
   * await rpc.start();
   */
  async start() {
    // 防止重复启动
    if (this.started) {
      return;
    }

    // 启动子进程
    // stdio: [stdin, stdout, stderr] 都使用 pipe
    this.child = spawn(this.command, this.args, {
      cwd: this.cwd,
      env: this.env,
      stdio: ["pipe", "pipe", "pipe"],
    });

    // 监听 stderr：app-server 的日志输出
    this.child.stderr.on("data", (chunk) => {
      const message = chunk.toString("utf8").trim();
      if (message.length > 0) {
        this.emit("stderr", message);
      }
    });

    // 监听子进程错误：如命令不存在、权限不足等
    this.child.on("error", (error) => {
      this.#failAllPending(error);
      this.emit("error", error);
    });

    // 监听子进程退出：可能是正常退出或崩溃
    this.child.on("exit", (code, signal) => {
      const reason = new Error(`app-server exited (code=${code ?? "null"}, signal=${signal ?? "null"})`);
      this.#failAllPending(reason);
      this.started = false;
      this.emit("exit", { code, signal });
    });

    // 逐行读取 stdout，解析 JSON-RPC 消息
    const rl = createInterface({ input: this.child.stdout });
    rl.on("line", (line) => {
      this.#handleLine(line);
    });

    this.started = true;
  }

  /**
   * 停止子进程
   *
   * 当前实现直接 kill 子进程。
   *
   * TODO: 实现优雅关闭
   * - 先发送 SIGTERM，给子进程清理时间
   * - 超时后（如 3 秒）发送 SIGKILL 强制终止
   *
   * @returns {Promise<void>}
   */
  async stop() {
    if (!this.child) {
      return;
    }
    this.child.kill();
    this.child = null;
    this.started = false;
  }

  /**
   * 发送 JSON-RPC 请求并等待响应
   *
   * 请求流程：
   * 1. 分配唯一 ID
   * 2. 设置超时定时器
   * 3. 写入 stdin
   * 4. 等待响应或超时
   *
   * @param {string} method - 方法名
   *   常用方法：
   *   - 'initialize' - 初始化握手
   *   - 'thread/start' - 创建线程
   *   - 'thread/list' - 列出线程
   *   - 'thread/resume' - 恢复线程
   *   - 'turn/start' - 开始对话轮次
   *   - 'turn/interrupt' - 中断对话轮次
   * @param {Object} params - 请求参数
   * @returns {Promise<any>} 响应结果
   * @throws {Error} 请求超时或服务端返回错误
   *
   * @example
   * const result = await rpc.request('thread/list', { limit: 100 });
   * console.log(result.data); // 线程列表
   */
  request(method, params) {
    // 分配请求 ID
    const id = this.nextId;
    this.nextId += 1;

    return new Promise((resolve, reject) => {
      // 设置超时：防止请求永久挂起
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`JSON-RPC request timeout: ${method}`));
      }, this.requestTimeoutMs);

      // 记录等待中的请求
      this.pending.set(id, {
        resolve,
        reject,
        timeout,
        method,  // 记录方法名用于错误消息
      });

      // 发送请求
      this.#send({ id, method, params });
    });
  }

  /**
   * 发送 JSON-RPC 通知（无需响应）
   *
   * 通知是单向的，服务端不会回复。
   *
   * @param {string} method - 方法名
   *   常用通知：
   *   - 'initialized' - 握手完成通知
   * @param {Object} params - 通知参数
   *
   * @example
   * rpc.notify('initialized');
   */
  notify(method, params) {
    this.#send({ method, params });
  }

  /**
   * 响应服务端请求
   *
   * 用于回复服务端发起的请求，主要是审批请求。
   *
   * @param {number} id - 服务端请求的 ID
   * @param {Object} result - 响应结果
   *
   * @example
   * // 响应审批请求
   * rpc.respond(requestId, { decision: 'accept' });
   */
  respond(id, result) {
    this.#send({ id, result });
  }

  /**
   * 响应服务端错误
   *
   * 当服务端请求无法处理时，返回错误响应。
   *
   * @param {number} id - 服务端请求的 ID
   * @param {number} code - 错误码
   *   JSON-RPC 预定义错误码：
   *   - -32700: Parse error（解析错误）
   *   - -32600: Invalid Request（无效请求）
   *   - -32601: Method not found（方法不存在）
   *   - -32602: Invalid params（无效参数）
   *   - -32603: Internal error（内部错误）
   *   - -32000 to -32099: Server error（服务端错误）
   * @param {string} message - 错误消息
   * @param {*} [data] - 额外错误数据
   *
   * @example
   * rpc.respondError(requestId, -32601, `Unsupported method: ${method}`);
   */
  respondError(id, code, message, data = undefined) {
    const error = data === undefined ? { code, message } : { code, message, data };
    this.#send({ id, error });
  }

  // ==================== 私有方法 ====================

  /**
   * 发送 JSON 消息到子进程 stdin
   *
   * @private
   * @param {Object} message - JSON-RPC 消息对象
   * @throws {Error} 如果 stdin 不可写
   */
  #send(message) {
    if (!this.child || !this.child.stdin.writable) {
      throw new Error("app-server stdin is not writable");
    }
    // JSON-RPC 要求每条消息一行
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  /**
   * 处理子进程 stdout 的单行输出
   *
   * 消息类型判断逻辑（JSON-RPC 2.0 规范）：
   * - hasId && !hasMethod → 响应（response）
   * - hasId && hasMethod → 服务端请求（server request）
   * - !hasId && hasMethod → 通知（notification）
   * - 其他 → 协议错误
   *
   * @private
   * @param {string} line - 单行 JSON 字符串
   */
  #handleLine(line) {
    // 跳过空行
    const trimmed = line.trim();
    if (trimmed.length === 0) {
      return;
    }

    // 解析 JSON
    let message;
    try {
      message = JSON.parse(trimmed);
    } catch (error) {
      // JSON 解析失败，发出协议错误事件
      this.emit("protocolError", {
        kind: "invalid_json",
        line: trimmed,
        error,
      });
      return;
    }

    // 判断消息类型
    const hasId = Object.prototype.hasOwnProperty.call(message, "id");
    const hasMethod = typeof message.method === "string";

    // 情况 1：响应（有 id，无 method）
    if (hasId && !hasMethod) {
      const pending = this.pending.get(message.id);
      if (!pending) {
        // 收到未知 ID 的响应，可能是重复响应或超时后的延迟响应
        this.emit("protocolError", {
          kind: "unknown_response_id",
          message,
        });
        return;
      }

      // 清除超时定时器，从等待列表移除
      clearTimeout(pending.timeout);
      this.pending.delete(message.id);

      // 根据响应类型 resolve 或 reject
      if (Object.prototype.hasOwnProperty.call(message, "error")) {
        pending.reject(new Error(`RPC ${pending.method} failed: ${JSON.stringify(message.error)}`));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    // 情况 2：服务端请求（有 id，有 method）
    // 用于审批：item/commandExecution/requestApproval、item/fileChange/requestApproval
    if (hasId && hasMethod) {
      this.emit("request", message);
      return;
    }

    // 情况 3：通知（无 id，有 method）
    // 用于事件：turn/started、item/delta、turn/completed 等
    if (!hasId && hasMethod) {
      this.emit("notification", message);
      return;
    }

    // 情况 4：无法识别的消息格式
    this.emit("protocolError", {
      kind: "unexpected_message_shape",
      message,
    });
  }

  /**
   * 拒绝所有等待中的请求
   *
   * 在子进程异常退出或发生错误时调用，
   * 确保所有 pending 的 Promise 都能得到响应（即使是错误）。
   *
   * @private
   * @param {Error} error - 拒绝原因
   */
  #failAllPending(error) {
    for (const [id, pending] of this.pending.entries()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
      this.pending.delete(id);
    }
  }
}
