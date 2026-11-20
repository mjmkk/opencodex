import { createHash } from 'node:crypto';
import path from 'node:path';
import { DesktopRelayClient } from './desktop-relay-client.js';

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const hex = /^[a-f0-9]{64}$/;
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value)
  && [Object.prototype, null].includes(Object.getPrototypeOf(value));
const text = value => typeof value === 'string' && value.length > 0 && value === value.trim();
const keys = (value, allowed) => record(value) && Object.keys(value).every(key => allowed.includes(key));
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');

// Only trusted startup configuration calls this factory. HTTP cannot supply a
// host, command, namespace, socket or source binding. Validate all entries before
// constructing any SSH client, so invalid config cannot partly open targets.
export function createNativeControlTargets(config, createClient = options => new DesktopRelayClient(options)) {
  if (config === undefined) return new Map();
  if (!record(config)) throw new Error('nativeControlTargets must be a trusted thread map');
  const entries = Object.entries(config).map(([threadId, value]) => {
    if (!uuid.test(threadId) || !keys(value, ['hostId', 'sourceNamespace', 'executionMachine', 'transport', 'binding'])
        || !text(value.hostId) || value.hostId === 'local' || !text(value.sourceNamespace)
        || !text(value.executionMachine)
        || !keys(value.transport, ['command', 'args', 'timeoutMs'])
        || !text(value.transport.command) || path.basename(value.transport.command) !== 'ssh'
        || !Array.isArray(value.transport.args) || value.transport.args.length === 0
        || value.transport.args.some(arg => typeof arg !== 'string' || arg.includes('\0'))
        || !keys(value.binding, ['sshFingerprint', 'nativeSocket', 'adapterSourceSha256'])
        || !/^SHA256:[A-Za-z0-9+/]{43}=?$/.test(value.binding.sshFingerprint ?? '')
        || !text(value.binding.nativeSocket) || !path.isAbsolute(value.binding.nativeSocket)
        || !hex.test(value.binding.adapterSourceSha256 ?? ''))
      throw new Error('Invalid trusted native control target');
    const timeoutMs = value.transport.timeoutMs ?? 15000;
    if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 15000 || timeoutMs > 2147483647)
      throw new Error('Native control target cannot shorten the existing transport timeout');
    const transport = Object.freeze({ command: value.transport.command,
      args: Object.freeze(value.transport.args.slice()), timeoutMs });
    const binding = Object.freeze({ ...value.binding });
    // Fixed tuple covers every accepted config field, including ordered SSH args.
    // Do not use the flat-body JSON replacer used by legacy request fingerprints.
    const executionBinding = hash(['plain-text-ssh-v1', threadId, value.hostId,
      value.sourceNamespace, value.executionMachine, binding.sshFingerprint,
      binding.nativeSocket, binding.adapterSourceSha256,
      transport.command, transport.args, transport.timeoutMs]);
    return { threadId, hostId: value.hostId, sourceNamespace: value.sourceNamespace,
      executionMachine: value.executionMachine, executionBinding, binding, transport };
  });
  const targets = new Map();
  try {
    for (const entry of entries) {
      const native = createClient({ ...entry.transport, args: entry.transport.args.slice() });
      if (typeof native?.call !== 'function') throw new Error('Native target requires a relay client');
      targets.set(entry.threadId, Object.freeze({ ...entry, native }));
    }
    return targets;
  } catch (error) {
    closeNativeControlTargets(targets);
    throw error;
  }
}

export function closeNativeControlTargets(targets) {
  for (const target of targets?.values() ?? []) target.native.close?.();
}

export function remoteControlIdentity(target) {
  return { protocol: 'plain-text-ssh-v1', host_id: target.hostId, native_host_id: 'local',
    source_namespace: target.sourceNamespace, execution_machine: target.executionMachine,
    execution_binding: target.executionBinding };
}

export function remoteControlObservation(target, raw) {
  return { ...raw, ...remoteControlIdentity(target), stop_available: false,
    input_available: raw.input_available === true && ['start', 'steer'].includes(raw.reply_route),
    control_receipt: hash(['plain-text-ssh-v1', target.executionBinding, raw.control_receipt]) };
}
