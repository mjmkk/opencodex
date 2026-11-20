import { HttpError } from './errors.js';
import { NativeControlService } from './native-control-service.js';

// Presentation of existing Mirror records; this adapter never starts an App Server.
export class DesktopMobileService {
  constructor({ mirror, store, native, nativeControlTargets }) {
    this.mirror = mirror;
    this.store = store;
    this.native = native;
    this.nativeControl = (native || nativeControlTargets?.size) && store?.db
      ? new NativeControlService({ native, store, nativeControlTargets }) : null;
    this.syncSubscribers = new Set();
  }

  async listThreads() {
    const result = await this.mirror({ operation: 'index', limit: 1000 });
    if (!result.ok) throw new HttpError(503, 'MIRROR_UNAVAILABLE', 'Saved tasks are temporarily unavailable');
    return { data: result.threads.map(t => ({
      threadId: t.thread_id, title: t.metadata?.title ?? t.metadata?.name ?? null,
      name: t.metadata?.title ?? t.metadata?.name ?? null,
      source: 'local_mirror', kind: t.kind, hostId: t.host_id,
      observedAt: t.last_synced_at ?? t.last_seen_at,
      contentCoverage: t.content_coverage, attachmentCoverage: t.attachment_coverage,
      executionState: 'UNKNOWN', // Cached metadata cannot establish a live execution state.
    })), source: 'local_mirror', possiblyTruncated: result.possibly_truncated };
  }

  registerPushDevice(body = {}) {
    const token = body.deviceToken ?? body.device_token;
    if (typeof token !== 'string' || !/^[0-9a-f]{64,512}$/i.test(token))
      throw new HttpError(400, 'INVALID_DEVICE_TOKEN', 'Invalid push token');
    if (!['sandbox', 'production'].includes(body.environment) || body.platform !== 'ios')
      throw new HttpError(400, 'INVALID_PUSH_DEVICE', 'Invalid push environment');
    if (typeof body.clientScope !== 'string' || !/^[A-Za-z0-9-]{16,80}$/.test(body.clientScope))
      throw new HttpError(400, 'INVALID_CLIENT_SCOPE', 'An installation identity is required');
    const now = new Date().toISOString();
    this.store.upsertPushDevice({ deviceToken: token, platform: 'ios',
      bundleId: body.bundleId ?? null, environment: body.environment,
      deviceName: body.deviceName ?? null, clientScope: body.clientScope,
      createdAt: now, updatedAt: now, lastSeenAt: now });
    return { status: 'registered' };
  }

  unregisterPushDevice(body = {}) {
    const token = body.deviceToken ?? body.device_token;
    if (typeof token !== 'string' || !/^[0-9a-f]{64,512}$/i.test(token))
      throw new HttpError(400, 'INVALID_DEVICE_TOKEN', 'Invalid push token');
    this.store.removePushDevice(token);
    return { status: 'unregistered' };
  }
}

// Unsupported legacy paths must not start a second owner or return invented history.
export function desktopService(options) {
  return new Proxy(new DesktopMobileService(options), {
    get(target, key) {
      if (key in target) return typeof target[key] === 'function' ? target[key].bind(target) : target[key];
      return () => { throw new HttpError(503, 'NATIVE_CAPABILITY_UNAVAILABLE', 'This operation is not connected to its native owner'); };
    },
  });
}
