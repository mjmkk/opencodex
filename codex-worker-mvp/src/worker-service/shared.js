/**
 * WorkerService 共享常量与纯工具函数
 */

/** 终态集合：任务已完成，不会再变化 */
export const TERMINAL_STATES = new Set(["DONE", "FAILED", "CANCELLED"]);

/** 活跃状态集合：任务正在进行中 */
export const ACTIVE_STATES = new Set(["QUEUED", "RUNNING", "WAITING_APPROVAL"]);

/** 线程历史分页默认大小 */
export const THREAD_EVENTS_PAGE_LIMIT_DEFAULT = 200;

/** 线程历史分页最大大小 */
export const THREAD_EVENTS_PAGE_LIMIT_MAX = 1000;

/** 支持的 JSON-RPC 通知方法 */
export const SUPPORTED_EVENT_METHODS = new Set([
  "thread/started",
  "turn/started",
  "turn/completed",
  "item/started",
  "item/completed",
  "item/agentMessage/delta",
  "item/commandExecution/outputDelta",
  "item/fileChange/outputDelta",
  "error",
]);

/** JSON-RPC 通知方法到事件类型映射 */
export const RPC_EVENT_TYPE_MAP = Object.freeze({
  "thread/started": "thread.started",
  "item/started": "item.started",
  "item/completed": "item.completed",
  "item/agentMessage/delta": "item.agentMessage.delta",
  "item/commandExecution/outputDelta": "item.commandExecution.outputDelta",
  "item/fileChange/outputDelta": "item.fileChange.outputDelta",
});

/**
 * 获取当前时间的 ISO 8601 格式字符串
 * @returns {string}
 */
export function nowIso() {
  return new Date().toISOString();
}

/**
 * 标准化审批策略值（kebab-case）
 * @param {string} [value]
 * @returns {string|null}
 */
export function normalizeApprovalPolicy(value) {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim();
  if (normalized.length === 0) {
    return null;
  }
  const allowed = new Set(["untrusted", "on-failure", "on-request", "never"]);
  return allowed.has(normalized) ? normalized : null;
}

/**
 * 标准化沙箱模式值（kebab-case）
 * @param {string} [value]
 * @returns {string|null}
 */
export function normalizeSandboxMode(value) {
  if (typeof value !== "string") {
    return null;
  }
  const normalized = value.trim();
  if (normalized.length === 0) {
    return null;
  }
  const allowed = new Set(["read-only", "workspace-write", "danger-full-access"]);
  return allowed.has(normalized) ? normalized : null;
}

/**
 * 将 turn 状态转换为 job 状态
 * @param {string} turnStatus
 * @returns {string}
 */
export function toJobStateFromTurnStatus(turnStatus) {
  switch (turnStatus) {
    case "completed":
      return "DONE";
    case "failed":
      return "FAILED";
    case "interrupted":
      return "CANCELLED";
    case "inProgress":
    default:
      return "RUNNING";
  }
}

/**
 * 是否为非空字符串
 * @param {unknown} value
 * @returns {boolean}
 */
export function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

/**
 * 去除 ANSI 颜色转义序列
 * @param {string} value
 * @returns {string}
 */
export function stripAnsi(value) {
  if (typeof value !== "string" || value.length === 0) {
    return value;
  }
  return value.replace(/\x1b\[[0-9;]*m/g, "");
}
