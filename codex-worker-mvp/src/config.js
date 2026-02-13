/**
 * 配置加载模块
 *
 * 职责：
 * - 从环境变量加载 Worker 配置
 * - 提供默认值和配置验证
 *
 * @module config
 * @see README.md 第 2 节 "环境变量"
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
 * 加载并验证配置
 *
 * 从环境变量读取配置，提供合理的默认值。
 *
 * 环境变量说明：
 *
 * | 变量名 | 说明 | 默认值 |
 * |--------|------|--------|
 * | PORT | HTTP 服务端口 | 8787 |
 * | WORKER_TOKEN | Bearer 鉴权令牌（可选） | 无 |
 * | WORKER_PROJECT_PATHS | 项目路径白名单（逗号分隔） | 当前目录 |
 * | WORKER_DEFAULT_PROJECT | 默认项目路径 | 白名单第一个 |
 * | CODEX_COMMAND | codex 可执行文件 | codex |
 * | CODEX_APP_SERVER_ARGS | app-server 启动参数 | app-server |
 * | WORKER_EVENT_RETENTION | 单任务保留事件数 | 2000 |
 * | WORKER_DB_PATH | SQLite 数据库路径 | ./data/worker.db |
 * | WORKER_CWD | 子进程工作目录 | 当前目录 |
 *
 * @param {Object} [env=process.env] - 环境变量对象（便于测试）
 * @returns {Object} 配置对象
 * @returns {number} returns.port - HTTP 端口
 * @returns {string|null} returns.authToken - 鉴权令牌
 * @returns {string[]} returns.projectPaths - 项目路径白名单
 * @returns {string} returns.defaultProjectPath - 默认项目路径
 * @returns {number} returns.eventRetention - 事件保留条数
 * @returns {string} returns.dbPath - 数据库路径
 * @returns {Object} returns.rpc - JSON-RPC 配置
 * @throws {Error} 如果配置无效（如端口不是正整数）
 *
 * @example
 * const config = loadConfig();
 * console.log(config.port); // 8787
 */
export function loadConfig(env = process.env) {
  // 解析项目路径白名单
  const projectPaths = parseCsv(env.WORKER_PROJECT_PATHS);
  const defaultProjectPath = env.WORKER_DEFAULT_PROJECT?.trim() || projectPaths[0] || process.cwd();

  // JSON-RPC 子进程配置
  const command = env.CODEX_COMMAND?.trim() || "codex";
  const rawArgs = parseCsv(env.CODEX_APP_SERVER_ARGS);
  const args = rawArgs.length > 0 ? rawArgs : ["app-server"];

  // 解析端口
  const portRaw = env.PORT ?? "8787";
  const port = Number.parseInt(portRaw, 10);
  if (!Number.isInteger(port) || port <= 0) {
    throw new Error(`invalid PORT: ${portRaw}`);
  }

  // 解析事件保留数量
  const eventRetentionRaw = env.WORKER_EVENT_RETENTION ?? "2000";
  const eventRetention = Number.parseInt(eventRetentionRaw, 10);
  if (!Number.isInteger(eventRetention) || eventRetention < 100) {
    throw new Error(`invalid WORKER_EVENT_RETENTION: ${eventRetentionRaw}`);
  }

  // 数据库路径
  const dbPath =
    env.WORKER_DB_PATH?.trim() ||
    // 默认落盘到仓库内，方便单机 MVP 使用与排查
    `${process.cwd()}/data/worker.db`;

  return {
    port,
    authToken: env.WORKER_TOKEN?.trim() || null,
    projectPaths,
    defaultProjectPath,
    eventRetention,
    dbPath,
    rpc: {
      command,
      args,
      cwd: env.WORKER_CWD?.trim() || process.cwd(),
    },
  };
}
