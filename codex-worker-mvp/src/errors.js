/**
 * 自定义错误类
 *
 * 职责：
 * - 提供统一的 HTTP 错误类型
 * - 包含 HTTP 状态码、业务错误码和错误消息
 *
 * @module errors
 * @see mvp-architecture.md 第 5 节 "Worker API 契约"
 */

/**
 * HTTP 错误类
 *
 * 用于表示 HTTP API 返回的错误，包含：
 * - status：HTTP 状态码（如 400、404、500）
 * - code：业务错误码（如 INVALID_INPUT、JOB_NOT_FOUND）
 * - message：人类可读的错误消息
 *
 * @example
 * throw new HttpError(404, 'JOB_NOT_FOUND', '任务不存在');
 * // 响应：{ "error": { "code": "JOB_NOT_FOUND", "message": "任务不存在" } }
 */
export class HttpError extends Error {
  /**
   * 创建 HTTP 错误实例
   *
   * @param {number} status - HTTP 状态码
   *   常用状态码：
   *   - 400 Bad Request：请求参数无效
   *   - 401 Unauthorized：缺少或无效的鉴权
   *   - 404 Not Found：资源不存在
   *   - 409 Conflict：资源冲突（如重复操作）
   *   - 413 Payload Too Large：请求体过大
   *   - 500 Internal Server Error：内部错误
   *   - 502 Bad Gateway：上游服务返回无效响应
   * @param {string} code - 业务错误码（大写下划线格式）
   *   常用错误码：
   *   - INVALID_INPUT：输入参数无效
   *   - INVALID_JSON：JSON 格式错误
   *   - INVALID_CURSOR：游标格式错误
   *   - INVALID_THREAD_ID：线程 ID 无效
   *   - INVALID_APPROVAL_ID：审批 ID 无效
   *   - THREAD_HAS_ACTIVE_JOB：线程已有进行中的任务
   *   - PROJECT_NOT_FOUND：项目不存在
   *   - PROJECT_NOT_ALLOWED：项目不在白名单内
   *   - JOB_NOT_FOUND：任务不存在
   *   - APPROVAL_NOT_FOUND：审批不存在
   *   - CURSOR_EXPIRED：游标已过期
   *   - UNAUTHORIZED：未授权
   *   - NOT_FOUND：接口不存在
   *   - INTERNAL_ERROR：内部错误
   *   - INVALID_THREAD_RESPONSE：线程操作返回无效数据
   * @param {string} message - 错误消息（中文，面向开发者）
   */
  constructor(status, code, message) {
    super(message);
    /** 错误名称 */
    this.name = "HttpError";
    /** HTTP 状态码 */
    this.status = status;
    /** 业务错误码 */
    this.code = code;
  }
}
