/**
 * APNs 推送通知器
 *
 * 通过 Apple Push Notification service（APNs）向 iOS 设备发送远程通知。
 */

import { createHash, createSign } from "node:crypto";
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
    this.policy = new NotificationPolicy(options.db);
    this.postJson = options.postJson ?? ((...args) => this.#postJson(...args));
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

  async notify({ envelope, job, devices, syncHead }) {
    const message = notificationMessage(envelope, job, syncHead);
    const results = [];
    for (const device of devices ?? []) {
      if (device.platform !== "ios" || !isNonEmptyString(device.deviceToken)) continue;
      if (!this.policy.reserve(device.deviceToken, message, Date.now())) continue;
      const result = await this.#sendToDevice(device, message);
      this.policy.record(result.ok ? "apns_accepted" : "apns_failed");
      results.push(result);
    }
    const accepted = results.filter(item => item.ok).length;
    return { accepted, delivered: null, seen: null, failed: results.length - accepted,
      invalidDeviceTokens: results.filter(item => INVALID_DEVICE_REASONS.has(item.reason)).map(item => item.deviceToken) };
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
    const signature = signer.sign({ key: this.privateKey, dsaEncoding: "ieee-p1363" });
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
      aps: message.silent ? { "content-available": 1 } : {
        alert: { title: message.title, body: message.body },
        "thread-id": message.threadId,
        category: message.approvalId ? "AGT_APPROVAL" : "AGT_THREAD",
        "mutable-content": 1,
        "interruption-level": "active",
      },
      eventType: message.eventType,
      threadId: message.threadId,
      jobId: message.jobId,
      latest_cursor: message.latestCursor,
      requestVersion: message.requestVersion,
      approvalId: message.approvalId,
      source: message.source,
      deepLink: message.source === "structured_approval" ? "opencodex://approvals" : `opencodex://thread/${encodeURIComponent(message.threadId)}`,
    };
    const response = await this.postJson(host, requestPath, {
      authorization,
      "apns-topic": topic,
      "apns-push-type": message.silent ? "background" : "alert",
      "apns-priority": message.silent ? "5" : "10",
      "apns-collapse-id": createHash("sha256").update(message.collapseKey).digest("hex"),
      "apns-expiration": String(Math.floor(Date.now() / 1000) + (message.silent ? 1200 : 3600)),
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

      req.setTimeout(15000, () => { done({ ok: false, statusCode: 0, reason: "transport:timeout" }); req.close(); });
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


export function notificationMessage(envelope, job, head = {}) {
  const eventType = envelope.type;
  const approvalId = eventType === "approval.required" ? envelope.payload?.approvalId : null;
  const completion = eventType === "job.finished";
  const threadId = job.threadId;
  return {
    eventType, threadId, jobId: job.jobId, approvalId,
    source: envelope.payload?.source ?? "native",
    requestVersion: envelope.payload?.requestVersion ?? null,
    latestCursor: head?.latestCursor ?? null,
    silent: !approvalId && !completion,
    title: approvalId ? "Codex 需要你确认" : "Codex 任务有结果",
    // Commands, full logs and arbitrary model text never enter lock-screen payloads.
    body: approvalId ? "打开查看当前请求的范围与上下文。" : "打开查看原任务的最新结果。",
    collapseKey: approvalId ? `approval:${approvalId}` : `${completion ? "completion" : "progress"}:${threadId}`,
    dedupKey: approvalId ? `approval:${approvalId}:${envelope.payload?.requestVersion ?? ""}` : `${job.jobId}:${envelope.seq}:${eventType}`,
  };
}

export class NotificationPolicy {
  constructor(db = null) {
    this.db = db; this.entries = new Map(); this.counters = {};
    db?.exec(`CREATE TABLE IF NOT EXISTS mobile_push_policy (key TEXT PRIMARY KEY, at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS mobile_metrics (name TEXT PRIMARY KEY, value INTEGER NOT NULL);`);
  }
  record(name) {
    if (this.db) this.db.prepare("INSERT INTO mobile_metrics VALUES(?,1) ON CONFLICT(name) DO UPDATE SET value=value+1").run(name);
    else this.counters[name] = (this.counters[name] ?? 0) + 1;
  }
  reserve(token, message, now) {
    const device = createHash("sha256").update(token).digest("hex");
    const key = `${device}:${message.dedupKey}`;
    const rateKey = `${device}:${message.silent ? "background" : message.collapseKey}`;
    const get = key => this.db ? this.db.prepare("SELECT at FROM mobile_push_policy WHERE key=?").get(key)?.at : this.entries.get(key);
    const put = (key, at) => this.db ? this.db.prepare("INSERT INTO mobile_push_policy VALUES(?,?) ON CONFLICT(key) DO UPDATE SET at=excluded.at").run(key,at) : this.entries.set(key,at);
    const reserve = () => {
      if (get(key) !== undefined) { this.record("push_duplicate_suppressed"); return false; }
      const previous = get(rateKey);
      // At most three silent hints per hour per device. Durable pull recovers every thread.
      const interval = message.silent ? 20 * 60 * 1000 : (message.approvalId ? 0 : 30 * 1000);
      if (previous !== undefined && now - previous < interval) { this.record("push_coalesced"); return false; }
      put(key, now); put(rateKey, now); this.record(message.silent ? "silent_attempted" : "visible_attempted");
      if (this.db) this.db.prepare("DELETE FROM mobile_push_policy WHERE at<?").run(now - 86400000);
      else for (const [entry, at] of this.entries) if (at < now - 86400000) this.entries.delete(entry);
      return true;
    };
    return this.db ? this.db.transaction(reserve)() : reserve();
  }
}
