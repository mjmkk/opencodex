import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/**
 * 配置加载模块
 *
 * 职责：
 * - 从配置文件、环境变量加载 Worker 配置
 * - 提供默认值和配置验证
 *
 * 优先级（高 -> 低）：
 * - 启动参数（仅 `--config`）
 * - 环境变量
 * - 配置文件
 * - 默认值
 *
 * @module config
 * @see README.md 第 2 节 "配置"
 */

/**
 * 解析逗号分隔的字符串
 *
 * 将 "a, b, c" 这样的字符串解析为 ['a', 'b', 'c'] 数组。
 * 自动处理空白字符和空值。
 *
 * @param {string} [value] - 逗号分隔的字符串
 * @returns {string[]} 解析后的字符串数组
 *
 * @example
 * parseCsv('a, b, c')  // ['a', 'b', 'c']
 * parseCsv('')         // []
 * parseCsv(null)       // []
 */
function parseCsv(value) {
  if (!value) {
    return [];
  }
  return value
    .split(",")
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
}

/**
 * 解析字符串数组（支持数组或 CSV 字符串）
 *
 * @param {unknown} value
 * @returns {string[]}
 */
function parseStringList(value) {
  if (Array.isArray(value)) {
    return value
      .map((item) => (typeof item === "string" ? item : String(item)))
      .map((item) => item.trim())
      .filter((item) => item.length > 0);
  }
  if (typeof value === "string") {
    return parseCsv(value);
  }
  return [];
}

/**
 * 解析布尔值
 *
 * 支持：true/1/yes/on 与 false/0/no/off（大小写不敏感）
 *
 * @param {unknown} value
 * @returns {boolean|undefined}
 */
function parseBoolean(value) {
  if (typeof value === "boolean") {
    return value;
  }
  if (typeof value !== "string") {
    return undefined;
  }
  const normalized = value.trim().toLowerCase();
  if (["true", "1", "yes", "on"].includes(normalized)) {
    return true;
  }
  if (["false", "0", "no", "off"].includes(normalized)) {
    return false;
  }
  return undefined;
}

/**
 * 安全提取非空字符串
 *
 * @param {unknown} value
 * @returns {string|undefined}
 */
function asNonEmptyString(value) {
  if (typeof value !== "string") {
    return undefined;
  }
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : undefined;
}

/**
 * 判断是否为普通对象
 *
 * @param {unknown} value
 * @returns {Record<string, unknown>}
 */
function asPlainObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return /** @type {Record<string, unknown>} */ (value);
}

/**
 * 解析正整数配置项
 *
 * @param {string} name
 * @param {unknown} value
 * @param {number} min
 * @returns {number|undefined}
 */
function parseInteger(name, value, min) {
  if (value === undefined || value === null || value === "") {
    return undefined;
  }
  const parsed =
    typeof value === "number" && Number.isFinite(value)
      ? Math.trunc(value)
      : Number.parseInt(String(value), 10);
  if (!Number.isInteger(parsed) || parsed < min) {
    throw new Error(`invalid ${name}: ${value}`);
  }
  return parsed;
}

/**
 * 从 argv 解析配置文件路径
 *
 * 支持：
 * - --config ./worker.config.json
 * - --config=./worker.config.json
 * - -c ./worker.config.json
 * - -c=./worker.config.json
 *
 * @param {string[]} argv
 * @returns {string|undefined}
 */
function parseConfigPathFromArgv(argv) {
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (token === "--config" || token === "-c") {
      const next = argv[index + 1];
      if (!next || next.startsWith("-")) {
        throw new Error(`${token} missing value`);
      }
      return next;
    }
    if (token.startsWith("--config=")) {
      const value = token.slice("--config=".length).trim();
      if (!value) {
        throw new Error("--config missing value");
      }
      return value;
    }
    if (token.startsWith("-c=")) {
      const value = token.slice("-c=".length).trim();
      if (!value) {
        throw new Error("-c missing value");
      }
      return value;
    }
  }
  return undefined;
}

/**
 * 解析文件配置中的路径值
 *
 * 规则：
 * - 绝对路径直接返回
 * - 相对路径相对于配置文件目录
 *
 * @param {unknown} value
 * @param {string|null} baseDir
 * @returns {string|undefined}
 */
function resolvePathFromFile(value, baseDir) {
  const normalized = asNonEmptyString(value);
  if (!normalized) {
    return undefined;
  }
  if (!baseDir || path.isAbsolute(normalized)) {
    return normalized;
  }
  return path.resolve(baseDir, normalized);
}

/**
 * 读取 JSON 配置文件
 *
 * @param {string} configPath
 * @param {string} cwd
 * @returns {{ path: string; baseDir: string; data: Record<string, unknown> }}
 */
function loadJsonConfigFile(configPath, cwd) {
  const absolutePath = path.isAbsolute(configPath) ? configPath : path.resolve(cwd, configPath);
  let raw = "";
  try {
    raw = fs.readFileSync(absolutePath, "utf8");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`failed to read config file "${absolutePath}": ${message}`);
  }

  let parsed = null;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(`failed to parse config file "${absolutePath}" as JSON: ${message}`);
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`invalid config file "${absolutePath}": root must be an object`);
  }

  return {
    path: absolutePath,
    baseDir: path.dirname(absolutePath),
    data: /** @type {Record<string, unknown>} */ (parsed),
  };
}

/**
 * 加载并验证配置
 *
 * 来源：
 * - 启动参数：`--config` / `-c`
 * - 环境变量：`WORKER_*`、`CODEX_*`、`APNS_*`
 * - JSON 配置文件
 *
 * 配置项说明：
 *
 * | 变量名 | 说明 | 默认值 |
 * |--------|------|--------|
 * | PORT | HTTP 服务端口 | 8787 |
 * | WORKER_CONFIG | JSON 配置文件路径 | 无 |
 * | WORKER_TOKEN | Bearer 鉴权令牌（可选） | 无 |
 * | WORKER_PROJECT_PATHS | 项目路径候选列表（逗号分隔） | 当前目录 |
 * | WORKER_DEFAULT_PROJECT | 默认项目路径 | 候选列表第一个 |
 * | CODEX_COMMAND | codex 可执行文件 | codex |
 * | CODEX_APP_SERVER_ARGS | app-server 启动参数 | app-server |
 * | WORKER_EVENT_RETENTION | 单任务保留事件数 | 2000 |
 * | WORKER_DB_PATH | SQLite 数据库路径 | ./data/worker.db |
 * | WORKER_CODEX_HOME | Codex 数据目录（线程导入导出） | ~/.codex |
 * | WORKER_THREAD_EXPORT_DIR | 线程导出包目录 | 系统临时目录 |
 * | WORKER_TERMINAL_ENABLED | 是否启用终端功能 | false |
 * | WORKER_TERMINAL_SHELL | 终端 Shell 路径 | /bin/zsh |
 * | WORKER_TERMINAL_IDLE_TTL_MS | 终端空闲回收毫秒 | 1200000 |
 * | WORKER_TERMINAL_MAX_SESSIONS | 终端会话上限 | 64 |
 * | WORKER_TERMINAL_MAX_INPUT_BYTES | 单次输入最大字节 | 32768 |
 * | WORKER_TERMINAL_MAX_SCROLLBACK_BYTES | 输出缓存上限字节 | 2097152 |
 * | WORKER_TERMINAL_HEARTBEAT_MS | 终端心跳间隔毫秒 | 15000 |
 * | WORKER_TERMINAL_SWEEP_INTERVAL_MS | 终端空闲扫描间隔毫秒 | 10000 |
 * | WORKER_CWD | 子进程工作目录 | 当前目录 |
 *
 * @param {Object} [env=process.env] - 环境变量对象（便于测试）
 * @param {Object} [options]
 * @param {string[]} [options.argv=process.argv.slice(2)] - 启动参数（便于测试）
 * @param {string} [options.cwd=process.cwd()] - 工作目录（便于测试）
 * @returns {Object} 配置对象
 * @returns {number} returns.port - HTTP 端口
 * @returns {string|null} returns.authToken - 鉴权令牌
 * @returns {string[]} returns.projectPaths - 项目路径候选列表
 * @returns {string} returns.defaultProjectPath - 默认项目路径
 * @returns {number} returns.eventRetention - 事件保留条数
 * @returns {string} returns.dbPath - 数据库路径
 * @returns {string} returns.codexHome - Codex 数据目录
 * @returns {string} returns.threadExportDir - 线程导出目录
 * @returns {Object} returns.terminal - 终端配置
 * @returns {Object} returns.rpc - JSON-RPC 配置
 * @returns {string|null} returns.configFilePath - 实际生效的配置文件路径
 * @throws {Error} 如果配置无效（如端口不是正整数）
 *
 * @example
 * const config = loadConfig();
 * console.log(config.port); // 8787
 */
export function loadConfig(env = process.env, options = {}) {
  const argv = Array.isArray(options.argv) ? options.argv : process.argv.slice(2);
  const cwd = asNonEmptyString(options.cwd) || process.cwd();

  const cliConfigPath = parseConfigPathFromArgv(argv);
  const envConfigPath = asNonEmptyString(env.WORKER_CONFIG);
  const configPathRaw = cliConfigPath || envConfigPath;

  let configFilePath = null;
  let configFileBaseDir = null;
  let fileConfig = {};
  if (configPathRaw) {
    const loaded = loadJsonConfigFile(configPathRaw, cwd);
    configFilePath = loaded.path;
    configFileBaseDir = loaded.baseDir;
    fileConfig = loaded.data;
  }

  const fileRpc = asPlainObject(fileConfig.rpc);
  const fileApns = asPlainObject(fileConfig.apns);
  const fileTailscaleServe = asPlainObject(fileConfig.tailscaleServe);
  const fileTerminal = asPlainObject(fileConfig.terminal);

  // 解析项目路径候选列表
  const projectPaths =
    asNonEmptyString(env.WORKER_PROJECT_PATHS) !== undefined
      ? parseCsv(env.WORKER_PROJECT_PATHS)
      : parseStringList(fileConfig.projectPaths).map((value) =>
          resolvePathFromFile(value, configFileBaseDir)
        );

  const defaultProjectPath =
    asNonEmptyString(env.WORKER_DEFAULT_PROJECT) ||
    resolvePathFromFile(fileConfig.defaultProjectPath, configFileBaseDir) ||
    projectPaths[0] ||
    cwd;

  // JSON-RPC 子进程配置
  const command = asNonEmptyString(env.CODEX_COMMAND) || asNonEmptyString(fileRpc.command) || "codex";
  const rawArgs =
    asNonEmptyString(env.CODEX_APP_SERVER_ARGS) !== undefined
      ? parseCsv(env.CODEX_APP_SERVER_ARGS)
      : parseStringList(fileRpc.args);
  const args = rawArgs.length > 0 ? rawArgs : ["app-server"];

  // 解析端口
  const port = parseInteger("PORT", env.PORT ?? fileConfig.port ?? "8787", 1);

  // 解析事件保留数量
  const eventRetention = parseInteger(
    "WORKER_EVENT_RETENTION",
    env.WORKER_EVENT_RETENTION ?? fileConfig.eventRetention ?? "2000",
    100
  );

  // 数据库路径
  const dbPathFromFile = resolvePathFromFile(fileConfig.dbPath, configFileBaseDir);
  const dbPath =
    asNonEmptyString(env.WORKER_DB_PATH) ||
    dbPathFromFile ||
    // 默认落盘到仓库内，方便单机 MVP 使用与排查
    `${cwd}/data/worker.db`;

  const codexHomeFromFile = resolvePathFromFile(fileConfig.codexHome, configFileBaseDir);
  const threadExportDirFromFile = resolvePathFromFile(fileConfig.threadExportDir, configFileBaseDir);
  const codexHome = asNonEmptyString(env.WORKER_CODEX_HOME) || codexHomeFromFile || path.join(os.homedir(), ".codex");
  const threadExportDir =
    asNonEmptyString(env.WORKER_THREAD_EXPORT_DIR) ||
    threadExportDirFromFile ||
    path.join(os.tmpdir(), "codex-thread-exports");

  const terminalEnabled =
    parseBoolean(env.WORKER_TERMINAL_ENABLED) ??
    parseBoolean(fileTerminal.enabled) ??
    false;
  const terminalShell =
    asNonEmptyString(env.WORKER_TERMINAL_SHELL) ||
    asNonEmptyString(fileTerminal.shell) ||
    "/bin/zsh";
  const terminalIdleTtlMs = parseInteger(
    "WORKER_TERMINAL_IDLE_TTL_MS",
    env.WORKER_TERMINAL_IDLE_TTL_MS ?? fileTerminal.idleTtlMs ?? "1200000",
    0
  );
  const terminalMaxSessions = parseInteger(
    "WORKER_TERMINAL_MAX_SESSIONS",
    env.WORKER_TERMINAL_MAX_SESSIONS ?? fileTerminal.maxSessions ?? "64",
    1
  );
  const terminalMaxInputBytes = parseInteger(
    "WORKER_TERMINAL_MAX_INPUT_BYTES",
    env.WORKER_TERMINAL_MAX_INPUT_BYTES ?? fileTerminal.maxInputBytes ?? "32768",
    1
  );
  const terminalMaxScrollbackBytes = parseInteger(
    "WORKER_TERMINAL_MAX_SCROLLBACK_BYTES",
    env.WORKER_TERMINAL_MAX_SCROLLBACK_BYTES ?? fileTerminal.maxScrollbackBytes ?? "2097152",
    1024
  );
  const terminalHeartbeatMs = parseInteger(
    "WORKER_TERMINAL_HEARTBEAT_MS",
    env.WORKER_TERMINAL_HEARTBEAT_MS ?? fileTerminal.heartbeatMs ?? "15000",
    1000
  );
  const terminalSweepIntervalMs = parseInteger(
    "WORKER_TERMINAL_SWEEP_INTERVAL_MS",
    env.WORKER_TERMINAL_SWEEP_INTERVAL_MS ?? fileTerminal.sweepIntervalMs ?? "10000",
    1000
  );

  // APNs（Apple Push Notification service）配置
  const apnsTeamId = asNonEmptyString(env.APNS_TEAM_ID) || asNonEmptyString(fileApns.teamId) || null;
  const apnsKeyId = asNonEmptyString(env.APNS_KEY_ID) || asNonEmptyString(fileApns.keyId) || null;
  const apnsBundleId =
    asNonEmptyString(env.APNS_BUNDLE_ID) || asNonEmptyString(fileApns.bundleId) || null;
  const apnsKeyPath =
    asNonEmptyString(env.APNS_KEY_PATH) ||
    resolvePathFromFile(fileApns.keyPath, configFileBaseDir) ||
    null;
  const apnsPrivateKeyRaw =
    asNonEmptyString(env.APNS_PRIVATE_KEY) || asNonEmptyString(fileApns.privateKey) || null;
  const apnsPrivateKey = apnsPrivateKeyRaw ? apnsPrivateKeyRaw.replace(/\\n/g, "\n") : null;
  const apnsEnabledFlag = parseBoolean(env.APNS_ENABLED) ?? parseBoolean(fileApns.enabled);
  const apnsDefaultEnvironmentRaw =
    (asNonEmptyString(env.APNS_DEFAULT_ENV) || asNonEmptyString(fileApns.defaultEnvironment) || "sandbox")
      .trim()
      .toLowerCase();
  const apnsDefaultEnvironment =
    apnsDefaultEnvironmentRaw === "production" || apnsDefaultEnvironmentRaw === "prod"
      ? "production"
      : "sandbox";

  const apnsHasCredentials =
    Boolean(apnsTeamId) &&
    Boolean(apnsKeyId) &&
    Boolean(apnsBundleId) &&
    (Boolean(apnsKeyPath) || Boolean(apnsPrivateKey));
  const apnsEnabled = apnsEnabledFlag ?? apnsHasCredentials;

  if (apnsEnabled && !apnsHasCredentials) {
    throw new Error(
      "APNS_ENABLED=true 但缺少 APNS_TEAM_ID/APNS_KEY_ID/APNS_BUNDLE_ID/APNS_KEY_PATH(APNS_PRIVATE_KEY)"
    );
  }

  const tailscaleServeEnabled = parseBoolean(fileTailscaleServe.enabled) ?? false;
  const fileTailscaleServeService = fileTailscaleServe.service;
  const tailscaleServeServiceRaw =
    fileTailscaleServeService === null
      ? null
      : asNonEmptyString(fileTailscaleServeService) || "svc:opencodex";
  const tailscaleServePathRaw = asNonEmptyString(fileTailscaleServe.path) || "/";
  const tailscaleServePathWithSlash =
    tailscaleServePathRaw.startsWith("/") ? tailscaleServePathRaw : `/${tailscaleServePathRaw}`;
  const tailscaleServePath =
    tailscaleServePathWithSlash === "/"
      ? "/"
      : tailscaleServePathWithSlash.replace(/\/+$/, "");

  return {
    port: /** @type {number} */ (port),
    authToken: asNonEmptyString(env.WORKER_TOKEN) || asNonEmptyString(fileConfig.authToken) || null,
    configFilePath,
    projectPaths,
    defaultProjectPath,
    eventRetention: /** @type {number} */ (eventRetention),
    dbPath,
    codexHome,
    threadExportDir,
    terminal: {
      enabled: terminalEnabled,
      shell: terminalShell,
      idleTtlMs: /** @type {number} */ (terminalIdleTtlMs),
      maxSessions: /** @type {number} */ (terminalMaxSessions),
      maxInputBytes: /** @type {number} */ (terminalMaxInputBytes),
      maxScrollbackBytes: /** @type {number} */ (terminalMaxScrollbackBytes),
      heartbeatMs: /** @type {number} */ (terminalHeartbeatMs),
      sweepIntervalMs: /** @type {number} */ (terminalSweepIntervalMs),
    },
    rpc: {
      command,
      args,
      cwd: asNonEmptyString(env.WORKER_CWD) || resolvePathFromFile(fileRpc.cwd, configFileBaseDir) || cwd,
    },
    tailscaleServe: {
      enabled: tailscaleServeEnabled,
      service: tailscaleServeServiceRaw,
      path: tailscaleServePath,
    },
    apns: {
      enabled: apnsEnabled,
      teamId: apnsTeamId,
      keyId: apnsKeyId,
      bundleId: apnsBundleId,
      keyPath: apnsKeyPath,
      privateKey: apnsPrivateKey,
      defaultEnvironment: apnsDefaultEnvironment,
    },
  };
}
