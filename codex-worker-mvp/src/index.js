/**
 * codex-worker-mvp 入口文件
 *
 * 职责：
 * - 加载配置并初始化各个模块
 * - 管理 Worker 生命周期（启动、关闭）
 * - 处理进程信号（SIGINT、SIGTERM）
 *
 * @module index
 * @see mvp-architecture.md 第 4 节 "总览架构"
 */

import { loadConfig } from "./config.js";
import { createHttpServer } from "./http-server.js";
import { JsonRpcClient } from "./json-rpc-client.js";
import { SqliteStore } from "./sqlite-store.js";
import { WorkerService } from "./worker-service.js";
import { mobileApprovalBridge } from "./mobile-approval-bridge.js";
import { ApnsNotifier } from "./apns-notifier.js";
import { startApprovalNotifications } from "./mobile-notifications.js";
import { LiveActivities } from "./live-activities.js";
import { ensureTailscaleServe } from "./tailscale-serve.js";

/**
 * 结构化日志输出
 *
 * 输出 JSON 格式日志，便于日志聚合和检索。
 * 格式：{ level, ts, message, extra? }
 *
 * @param {string} level - 日志级别：info、warn、error
 * @param {string} message - 日志消息
 * @param {Object} [extra] - 额外的上下文信息
 */
function log(level, message, extra = undefined) {
  const payload = {
    level,
    ts: new Date().toISOString(),
    message,
    ...(extra ? { extra } : {}),
  };
  // eslint-disable-next-line no-console
  console.log(JSON.stringify(payload));
}

/**
 * 主函数：初始化并启动 Worker
 *
 * 启动顺序：
 * 1. 加载配置（启动参数 / 环境变量 / 配置文件）
 * 2. 创建 JSON-RPC 客户端（与 codex app-server 通信）
 * 3. 初始化 SQLite 存储（持久化）
 * 4. 创建 Worker 服务（核心业务逻辑）
 * 5. 启动 HTTP 服务器（对外 API）
 *
 * 依赖注入模式：所有组件通过构造函数注入，便于测试和解耦。
 */
async function main() {
  // 1. 加载配置
  const config = loadConfig();

  // 2. 创建 JSON-RPC 客户端
  // 负责：启动 codex app-server 子进程，通过 stdio 通信
  const rpc = new JsonRpcClient({
    command: config.rpc.command,
    args: config.rpc.args,
    cwd: config.rpc.cwd,
    transport: config.rpc.transport,
    socketPath: config.rpc.socketPath,
  });
  if (rpc.sharedNative && !config.authToken) throw new Error("Shared native access requires a Worker authentication token");

  // 3. 初始化 SQLite 本地缓存
  // 负责：线程、任务、事件、审批的缓存与降级回放（非真相源）
  const store = new SqliteStore({
    dbPath: config.dbPath,
    logger: {
      warn: (msg) => log("warn", msg),
      error: (msg, extra) => log("error", msg, extra),
    },
    eventPageLimit: config.eventRetention,
  });
  store.init();

  let apnsNotifier = null;
  if (config.apns?.enabled) {
    apnsNotifier = new ApnsNotifier({
      db: store.db,
      teamId: config.apns.teamId,
      keyId: config.apns.keyId,
      bundleId: config.apns.bundleId,
      keyPath: config.apns.keyPath,
      privateKey: config.apns.privateKey,
      defaultEnvironment: config.apns.defaultEnvironment,
      logger: {
        warn: (msg) => log("warn", msg),
      },
    });
  }

  let terminalManager = null;
  if (config.terminal?.enabled) {
    const { createTerminalManager } = await import("./terminal-manager.js");
    terminalManager = createTerminalManager({
      shell: config.terminal.shell,
      idleTtlMs: config.terminal.idleTtlMs,
      maxSessions: config.terminal.maxSessions,
      maxInputBytes: config.terminal.maxInputBytes,
      maxScrollbackBytes: config.terminal.maxScrollbackBytes,
      sweepIntervalMs: config.terminal.sweepIntervalMs,
      logger: {
        warn: (msg) => log("warn", msg),
      },
    });
  }

  // 4. 创建 Worker 服务
  const approvals = mobileApprovalBridge(config.mobileApprovals);
  // 负责：线程管理、任务执行、审批处理、事件分发
  const service = new WorkerService({
    rpc,
    observedThreadIds: config.rpc.observedThreadIds,
    nativeWriteGuard: approvals ? threadId => approvals("validate_thread", { threadId }) : null,
    store,
    projectPaths: config.projectPaths,
    defaultProjectPath: config.defaultProjectPath,
    eventRetention: config.eventRetention,
    codexHome: config.codexHome,
    threadExportDir: config.threadExportDir,
    terminal: config.terminal,
    terminalManager,
    pushNotifier: apnsNotifier,
    logger: {
      warn: (msg) => log("warn", msg),
      error: (msg, extra) => log("error", msg, extra),
    },
  });

  // 初始化服务：启动子进程、握手 JSON-RPC
  await service.init();
  const liveActivities = apnsNotifier ? new LiveActivities({db:store.db,notifier:apnsNotifier,service}) : null;

  // 5. 创建 HTTP 服务器
  // 提供 REST API 和 SSE 事件流
  const server = createHttpServer({
    service,
    mobileApprovals: approvals,
    mobileMetricsDb: store.db,
    liveActivities,
    authToken: config.authToken,
    terminalHeartbeatMs: config.terminal?.heartbeatMs,
    logger: {
      error: (msg, extra) => log("error", msg, extra),
    },
  });

  // 启动监听
  await server.listen(config.port, config.host ?? (rpc.sharedNative ? "127.0.0.1" : "0.0.0.0"));
  const stopApprovalNotifications = startApprovalNotifications({ bridge: approvals, notifier: apnsNotifier, store,
    logger: { warn: msg => log("warn", msg) } });
  const stopLiveActivities = liveActivities?.start({warn:msg=>log('warn',msg)});

  if (config.tailscaleServe?.enabled) {
    const routeResult = await ensureTailscaleServe({
      service: config.tailscaleServe.service,
      path: config.tailscaleServe.path,
      port: config.port,
    });

    if (!routeResult.applied) {
      log("warn", "tailscale serve apply failed", {
        service: routeResult.service,
        path: routeResult.path,
        target: routeResult.target,
        cli: routeResult.cli,
        error: routeResult.error,
      });
    } else {
      log("info", "tailscale serve applied", {
        service: routeResult.service,
        path: routeResult.path,
        target: routeResult.target,
      });
    }
  }

  log("info", "codex-worker-mvp started", {
    port: config.port,
    authEnabled: Boolean(config.authToken),
    defaultProjectPath: config.defaultProjectPath,
    configFilePath: config.configFilePath,
  });

  /**
   * 优雅关闭函数
   *
   * 关闭顺序：
   * 1. 关闭 HTTP 服务器（停止接受新请求）
   * 2. 关闭 Worker 服务（停止子进程）
   * 3. 关闭数据库连接
   *
   * @param {string} signal - 触发关闭的信号：SIGINT 或 SIGTERM
   */
  let stopping = false;
  const shutdown = async (signal, exitCode = 0) => {
    if (stopping) return;
    stopping = true;
    stopApprovalNotifications();
    stopLiveActivities?.();
    const deadline = setTimeout(() => process.exit(exitCode), 3000);
    deadline.unref();
    log("info", "shutdown requested", { signal });
    try {
      await server.close();
      await service.shutdown();
      apnsNotifier?.close?.();
      store.close();
      process.exit(exitCode);
    } catch (error) {
      log("error", "shutdown failed", {
        error: error instanceof Error ? error.message : String(error),
      });
      process.exit(1);
    }
  };

  // 注册信号处理：Ctrl+C 或 kill 命令
  process.on("SIGINT", () => {
    shutdown("SIGINT");
  });
  process.on("SIGTERM", () => {
    shutdown("SIGTERM");
  });
  if (rpc.sharedNative) rpc.on("exit", () => shutdown("native_connection_closed", 1));
}

// 启动入口，捕获顶层异常
main().catch((error) => {
  log("error", "worker bootstrap failed", {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exit(1);
});
