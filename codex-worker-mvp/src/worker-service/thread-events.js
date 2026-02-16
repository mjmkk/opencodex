import { HttpError } from "../errors.js";
import {
  THREAD_EVENTS_PAGE_LIMIT_DEFAULT,
  THREAD_EVENTS_PAGE_LIMIT_MAX,
  TERMINAL_STATES,
  toJobStateFromTurnStatus,
  isNonEmptyString,
  nowIso,
} from "./shared.js";

/**
 * 标准化线程历史游标
 * @param {number|null|undefined} cursor
 * @returns {number}
 */
export function normalizeThreadCursor(cursor) {
  if (cursor === null || cursor === undefined) {
    return -1;
  }
  if (!Number.isInteger(cursor) || cursor < -1) {
    throw new HttpError(400, "INVALID_CURSOR", "cursor 必须是大于等于 -1 的整数");
  }
  return cursor;
}

/**
 * 标准化线程历史分页大小
 * @param {number|undefined|null} limit
 * @returns {number}
 */
export function normalizeThreadEventsLimit(limit) {
  if (limit === undefined || limit === null) {
    return THREAD_EVENTS_PAGE_LIMIT_DEFAULT;
  }
  if (!Number.isInteger(limit) || limit <= 0) {
    throw new HttpError(400, "INVALID_LIMIT", "limit 必须是正整数");
  }
  return Math.min(limit, THREAD_EVENTS_PAGE_LIMIT_MAX);
}

/**
 * 根据线程游标切片事件分页
 * @param {Array<object>} events
 * @param {number} cursor
 * @param {number} limit
 * @returns {{data: Array<object>, nextCursor: number, hasMore: boolean}}
 */
export function sliceThreadEventsByCursor(events, cursor, limit) {
  const total = Array.isArray(events) ? events.length : 0;

  if (total === 0) {
    return {
      data: [],
      nextCursor: -1,
      hasMore: false,
    };
  }

  if (cursor >= total) {
    throw new HttpError(
      409,
      "THREAD_CURSOR_EXPIRED",
      `cursor=${cursor} 超出当前线程历史范围（total=${total}）`
    );
  }

  const start = cursor + 1;
  if (start >= total) {
    return {
      data: [],
      nextCursor: cursor,
      hasMore: false,
    };
  }

  const endExclusive = Math.min(start + limit, total);
  const data = events.slice(start, endExclusive);
  const nextCursor = endExclusive - 1;
  return {
    data,
    nextCursor,
    hasMore: endExclusive < total,
  };
}

/**
 * 生成历史回放使用的虚拟 jobId
 * @param {string} threadId
 * @param {string} turnId
 * @returns {string}
 */
export function buildHistoryJobId(threadId, turnId) {
  return `hist_${threadId}_${turnId}`;
}

/**
 * 仅保留聊天回放必需的 item 字段
 * @param {object} rawItem
 * @param {string} itemId
 * @returns {object | null}
 */
export function toReplayChatItem(rawItem, itemId) {
  if (!isNonEmptyString(rawItem?.type)) {
    return null;
  }

  if (rawItem.type === "userMessage") {
    return {
      type: "userMessage",
      id: itemId,
      content: Array.isArray(rawItem.content) ? rawItem.content : [],
    };
  }

  if (rawItem.type === "agentMessage") {
    return {
      type: "agentMessage",
      id: itemId,
      text: isNonEmptyString(rawItem.text) ? rawItem.text : "",
    };
  }

  return null;
}

/**
 * 将 thread/read 返回的 turns/items 转换为前端可回放的事件流
 *
 * @param {object} options
 * @param {string} options.threadId
 * @param {Array<object>} options.turns
 * @param {Map<string, string>} options.turnToJob
 * @param {(threadId: string, turnId: string) => string} options.turnKey
 * @returns {Array<object>}
 */
export function buildThreadReplayEvents({ threadId, turns, turnToJob, turnKey }) {
  if (!Array.isArray(turns) || turns.length === 0) {
    return [];
  }

  const events = [];

  for (const turn of turns) {
    if (!turn || !isNonEmptyString(turn.id)) {
      continue;
    }

    const turnId = turn.id;
    const existingJobId = turnToJob.get(turnKey(threadId, turnId)) ?? null;
    const jobId = existingJobId ?? buildHistoryJobId(threadId, turnId);
    let seq = 0;

    const append = (type, payload) => {
      events.push({
        type,
        ts: nowIso(),
        jobId,
        seq,
        payload,
      });
      seq += 1;
    };

    const turnStatus = isNonEmptyString(turn.status) ? turn.status : "completed";
    const turnErrorMessage = turn?.error?.message;

    const items = Array.isArray(turn.items) ? turn.items : [];
    let itemIndex = 0;
    for (const rawItem of items) {
      if (!rawItem || typeof rawItem !== "object") {
        continue;
      }

      const fallbackItemId = `item_${itemIndex}`;
      const itemId = isNonEmptyString(rawItem.id) ? rawItem.id : fallbackItemId;
      const item = toReplayChatItem(rawItem, itemId);
      if (!item) {
        itemIndex += 1;
        continue;
      }

      append("item.completed", {
        threadId,
        turnId,
        itemId,
        item,
      });
      itemIndex += 1;
    }

    const mappedState = toJobStateFromTurnStatus(turnStatus);
    const canEmitState = mappedState !== "RUNNING" || isNonEmptyString(existingJobId);
    if (canEmitState) {
      append("job.state", {
        state: mappedState,
        errorMessage: isNonEmptyString(turnErrorMessage) ? turnErrorMessage : null,
      });

      if (TERMINAL_STATES.has(mappedState)) {
        append("job.finished", {
          state: mappedState,
          errorMessage: isNonEmptyString(turnErrorMessage) ? turnErrorMessage : null,
        });
      }
    }

    if (turnStatus === "failed" && isNonEmptyString(turnErrorMessage)) {
      append("error", {
        message: turnErrorMessage,
        threadId,
        turnId,
      });
    }
  }

  return events;
}
