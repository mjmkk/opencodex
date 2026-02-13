/**
 * ID 生成模块
 *
 * 职责：
 * - 生成全局唯一的实体 ID
 * - ID 格式：{prefix}_{uuid_16位}
 *
 * @module ids
 */

import { randomUUID } from "node:crypto";

/**
 * 生成带有前缀的唯一 ID
 *
 * ID 格式：`{prefix}_{16位随机字符}`
 *
 * 示例：
 * - job_a1b2c3d4e5f6g7h8
 * - thr_i9j0k1l2m3n4o5p6
 * - appr_q7r8s9t0u1v2w3x4
 *
 * 使用 UUID 的前 16 位（去掉横线）保证：
 * - 全局唯一性（UUID 碰撞概率极低）
 * - 不可预测性（UUID v4 使用加密随机数）
 * - 简洁性（16 字符足够，不需要完整的 32 位）
 *
 * @param {string} prefix - ID 前缀，表示实体类型
 *   常用前缀：
 *   - 'job' - 任务（Job）
 *   - 'thr' - 线程（Thread）
 *   - 'appr' - 审批（Approval）
 *   - 'turn' - 轮次（Turn）
 *   - 'item' - 项目（Item）
 * @returns {string} 带前缀的唯一 ID
 *
 * @example
 * createId('job')   // 'job_a1b2c3d4e5f6g7h8'
 * createId('thr')   // 'thr_i9j0k1l2m3n4o5p6'
 * createId('appr')  // 'appr_q7r8s9t0u1v2w3x4'
 */
export function createId(prefix) {
  // randomUUID() 生成 v4 UUID，如 'a1b2c3d4-e5f6-47h8-i9j0-k1l2m3n4o5p6'
  // 去掉横线后取前 16 位，如 'a1b2c3d4e5f6g7h8'
  return `${prefix}_${randomUUID().replace(/-/g, "").slice(0, 16)}`;
}
