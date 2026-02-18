/**
 * APNs 推送通知器
 *
 * 通过 Apple Push Notification service（APNs）向 iOS 设备发送远程通知。
 */

import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";
import { connect as connectHttp2 } from "node:http2";

const APNS_HOSTS = {
  sandbox: "api.sandbox.push.apple.com",
  production: "api.push.apple.com",
};

const INVALID_DEVICE_REASONS = new Set([
  "BadDeviceToken",
  "DeviceTokenNotForTopic",
  "Unregistered",
]);

function base64url(input) {
  const buffer = Buffer.isBuffer(input) ? input : Buffer.from(String(input), "utf8");
  return buffer
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function normalizeEnvironment(value, fallback = "sandbox") {
  if (!isNonEmptyString(value)) {
    return fallback;
  }
  const normalized = value.trim().toLowerCase();
  if (normalized === "production" || normalized === "prod") {
    return "production";
  }
  return "sandbox";
}

function truncate(text, maxLength = 88) {
  const normalized = isNonEmptyString(text) ? text.trim() : "";
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return `${normalized.slice(0, maxLength)}...`;
}

export class ApnsNotifier {
  constructor(options) {
    this.logger = options.logger ?? console;
    this.teamId = options.teamId;
    this.keyId = options.keyId;
    this.bundleId = options.bundleId;
    this.defaultEnvironment = normalizeEnvironment(options.defaultEnvironment, "sandbox");

    if (isNonEmptyString(options.privateKey)) {
      this.privateKey = options.privateKey;
    } else if (isNonEmptyString(options.keyPath)) {
      this.privateKey = readFileSync(options.keyPath, "utf8");
    } else {
      throw new Error("ApnsNotifier requires privateKey or keyPath");
    }

    this.cachedJwt = null;
    this.cachedJwtExpirySec = 0;
    this.clients = new Map();
  }

  close() {
    for (const client of this.clients.values()) {
      try {
        client.close();
      } catch {
        // ignore close error
      }
      try {
        client.destroy();
      } catch {
        // ignore destroy error
      }
    }
    this.clients.clear();
  }

  async notify({ envelope, job, thread, devices }) {
    const eventType = envelope?.type;
    const payload = envelope?.payload ?? {};
    const message = this.#buildMessage(eventType, payload, job, thread);
    if (!message) {
      return { delivered: 0, failed: 0, invalidDeviceTokens: [] };
    }

    const targets = Array.isArray(devices)
      ? devices.filter(
          (device) =>
            device &&
            device.platform === "ios" &&
            isNonEmptyString(device.deviceToken)
        )
      : [];

    if (targets.length === 0) {
      return { delivered: 0, failed: 0, invalidDeviceTokens: [] };
    }

    const results = await Promise.all(targets.map((device) => this.#sendToDevice(device, message)));
    const delivered = results.filter((item) => item.ok).length;
    const failed = results.length - delivered;
    const invalidDeviceTokens = results
      .filter((item) => !item.ok && INVALID_DEVICE_REASONS.has(item.reason))
      .map((item) => item.deviceToken);

    return { delivered, failed, invalidDeviceTokens };
  }

  #buildMessage(eventType, payload, job, thread) {
    const threadId = job?.threadId ?? payload?.threadId ?? null;
    const jobId = job?.jobId ?? payload?.jobId ?? null;
    const threadName =
      truncate(
        (isNonEmptyString(thread?.preview) && thread.preview)
          || (isNonEmptyString(thread?.cwd) && thread.cwd.split("/").filter(Boolean).at(-1))
          || threadId
          || "当前线程",
        48
      ) || "当前线程";

    if (eventType === "approval.required") {
      const commandSnippet = truncate(payload?.command, 96);
      return {
        title: "Codex 需要审批",
        body: commandSnippet
          ? `命令审批：${commandSnippet}`
          : `线程「${threadName}」有新的审批请求`,
        threadId,
        jobId,
        approvalId: payload?.approvalId ?? payload?.approval_id ?? null,
        eventType,
      };
    }

    if (eventType === "approval.resolved") {
      const decisionRaw = String(payload?.decision ?? "").trim().toLowerCase();
      const denied = decisionRaw.includes("decline") || decisionRaw.includes("reject");
      return {
        title: denied ? "Codex 审批已拒绝" : "Codex 审批已完成",
        body: `线程「${threadName}」审批已处理`,
        threadId,
        jobId,
        approvalId: payload?.approvalId ?? payload?.approval_id ?? null,
        eventType,
      };
    }

    if (eventType === "job.finished") {
      const state = String(payload?.state ?? "DONE").toUpperCase();
      let title = "Codex 任务已结束";
      if (state === "DONE") {
        title = "Codex 任务已完成";
      } else if (state === "FAILED") {
        title = "Codex 任务失败";
      } else if (state === "CANCELLED") {
        title = "Codex 任务已取消";
      }
      return {
        title,
        body: `线程「${threadName}」状态：${state}`,
        threadId,
        jobId,
        approvalId: null,
        eventType,
      };
    }

    return null;
  }

  #getJwt() {
    const nowSec = Math.floor(Date.now() / 1000);
    if (this.cachedJwt && nowSec < this.cachedJwtExpirySec) {
      return this.cachedJwt;
    }

    const header = base64url(JSON.stringify({ alg: "ES256", kid: this.keyId }));
    const payload = base64url(JSON.stringify({ iss: this.teamId, iat: nowSec }));
    const unsignedToken = `${header}.${payload}`;
    const signer = createSign("sha256");
    signer.update(unsignedToken);
    signer.end();
    const signature = signer.sign(this.privateKey);
    const token = `${unsignedToken}.${base64url(signature)}`;

    // APNs 要求 token 在 1 小时内有效，缓存 50 分钟
    this.cachedJwt = token;
    this.cachedJwtExpirySec = nowSec + 50 * 60;
    return token;
  }

  #getClient(host) {
    const existing = this.clients.get(host);
    if (existing && !existing.closed && !existing.destroyed) {
      return existing;
    }

    const client = connectHttp2(`https://${host}`);
    client.on("error", (error) => {
      this.logger.warn?.(`[apns] session error host=${host} error=${error.message}`);
    });
    client.on("close", () => {
      if (this.clients.get(host) === client) {
        this.clients.delete(host);
      }
    });
    this.clients.set(host, client);
    return client;
  }

  async #sendToDevice(device, message) {
    const environment = normalizeEnvironment(device.environment, this.defaultEnvironment);
    const host = APNS_HOSTS[environment] ?? APNS_HOSTS.sandbox;
    const topic = isNonEmptyString(device.bundleId) ? device.bundleId.trim() : this.bundleId;
    const requestPath = `/3/device/${encodeURIComponent(device.deviceToken)}`;
    const authorization = `bearer ${this.#getJwt()}`;

    const payload = {
      aps: {
        alert: {
          title: message.title,
          body: message.body,
        },
        sound: "default",
        ...(isNonEmptyString(message.threadId) ? { "thread-id": message.threadId } : {}),
      },
      eventType: message.eventType,
      ...(isNonEmptyString(message.threadId) ? { threadId: message.threadId } : {}),
      ...(isNonEmptyString(message.jobId) ? { jobId: message.jobId } : {}),
      ...(isNonEmptyString(message.approvalId) ? { approvalId: message.approvalId } : {}),
    };

    const response = await this.#postJson(host, requestPath, {
      authorization,
      "apns-topic": topic,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    }, payload);

    if (response.ok) {
      return {
        ok: true,
        statusCode: response.statusCode,
        reason: null,
        deviceToken: device.deviceToken,
      };
    }

    this.logger.warn?.(
      `[apns] delivery failed status=${response.statusCode} reason=${response.reason ?? "unknown"}`
    );
    return {
      ok: false,
      statusCode: response.statusCode,
      reason: response.reason ?? "Unknown",
      deviceToken: device.deviceToken,
    };
  }

  #postJson(host, path, headers, payload) {
    return new Promise((resolve) => {
      const client = this.#getClient(host);
      const req = client.request({
        ":method": "POST",
        ":path": path,
        ...headers,
      });

      let settled = false;
      let statusCode = 0;
      let responseBody = "";

      const done = (result) => {
        if (settled) {
          return;
        }
        settled = true;
        resolve(result);
      };

      req.setEncoding("utf8");
      req.on("response", (responseHeaders) => {
        statusCode = Number(responseHeaders[":status"] ?? 0);
      });
      req.on("data", (chunk) => {
        responseBody += chunk;
      });
      req.on("error", (error) => {
        done({
          ok: false,
          statusCode,
          reason: `transport:${error.message}`,
        });
      });
      req.on("end", () => {
        let reason = null;
        if (isNonEmptyString(responseBody)) {
          try {
            reason = JSON.parse(responseBody).reason ?? null;
          } catch {
            reason = responseBody;
          }
        }
        done({
          ok: statusCode >= 200 && statusCode < 300,
          statusCode,
          reason,
        });
      });

      req.end(JSON.stringify(payload));
    });
  }
}
