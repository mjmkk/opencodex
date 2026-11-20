import { createHash } from 'node:crypto';
import { HttpError } from './errors.js';
import { remoteControlIdentity, remoteControlObservation } from './native-control-targets.js';

const writeNames = new Set(['start', 'steer', 'interrupt']);
const definitePreflightRejections = new Set([
  'INVALID_NATIVE_CONTROL', 'NATIVE_CONTROL_CHANGED', 'NATIVE_THREAD_NOT_CONFIGURED',
  'NATIVE_OWNER_UNAVAILABLE', 'NATIVE_CONTROL_UNAVAILABLE',
]);
const canonical = value => JSON.stringify(value, Object.keys(value).sort());
const fingerprint = (threadId, kind, body) => createHash('sha256')
  .update(JSON.stringify([threadId, kind, canonical(body)])).digest('hex');

// Uses the existing service database. This is a transport write intent, not a
// job, task, approval, retry queue, or second source of native execution state.
export class NativeControlService {
  constructor({ native, store, nativeControlTargets }) {
    if (!store?.db) throw new Error('Native control requires the existing initialized store');
    this.native = native;
    this.nativeControlTargets = new Map(nativeControlTargets ?? []);
    const db = store.db;
    db.exec(`CREATE TABLE IF NOT EXISTS mobile_native_control_intents (
      submissionId TEXT PRIMARY KEY, requestHash TEXT NOT NULL,
      threadId TEXT NOT NULL, operation TEXT NOT NULL, requestJson TEXT NOT NULL,
      status TEXT NOT NULL, resultJson TEXT, createdAt TEXT NOT NULL, updatedAt TEXT NOT NULL
    )`);
    this.readIntent = db.prepare('SELECT * FROM mobile_native_control_intents WHERE submissionId=?');
    this.insertIntent = db.prepare(`INSERT OR IGNORE INTO mobile_native_control_intents
      (submissionId,requestHash,threadId,operation,requestJson,status,resultJson,createdAt,updatedAt)
      VALUES(@submissionId,@requestHash,@threadId,@operation,@requestJson,'unknown',NULL,@now,@now)`);
    this.finishIntent = db.prepare(`UPDATE mobile_native_control_intents
      SET status=@status,resultJson=@resultJson,updatedAt=@now WHERE submissionId=@submissionId`);
    this.claim = db.transaction(row => {
      const existing = this.readIntent.get(row.submissionId);
      if (existing) return { existing };
      this.insertIntent.run(row);
      return { claimed: true };
    });
  }

  existingResult(row, requestHash) {
    if (row.requestHash !== requestHash)
      throw new HttpError(409, 'NATIVE_SUBMISSION_ID_CONFLICT', 'Submission identity is already bound to another request');
    if (row.resultJson) {
      const { native_result, ...receipt } = JSON.parse(row.resultJson);
      return receipt;
    }
    // Restoring an original unknown intent must not consult today's target map.
    const saved = JSON.parse(row.requestJson)?.observation;
    const binding = saved?.protocol === 'plain-text-ssh-v1' ? {
      protocol: saved.protocol, host_id: saved.host_id, native_host_id: saved.native_host_id,
      source_namespace: saved.source_namespace, execution_machine: saved.execution_machine,
      execution_binding: saved.execution_binding,
      owner_client_id: saved.owner_client_id, control_receipt: saved.control_receipt,
      control_version: saved.control_version,
    } : {};
    return { submission_id: row.submissionId, thread_id: row.threadId, ...binding,
      operation: row.operation, status: 'unknown', code: 'NATIVE_CONTROL_OUTCOME_UNKNOWN' };
  }

  async read(threadId) {
    return (await this.observe(threadId)).observation;
  }

  async observe(threadId, target = this.nativeControlTargets.get(threadId)) {
    const native = target?.native ?? this.native;
    if (typeof native?.call !== 'function')
      throw new HttpError(503, 'NATIVE_CONTROL_UNAVAILABLE', 'Native control forwarding is not connected');
    const raw = await native.call('control-read', JSON.stringify({ thread_id: threadId }));
    const result = JSON.parse(raw);
    if (result?.protocol !== 'plain-text-local-v2' || result.thread_id !== threadId
        || result.host_id !== 'local' || typeof result.owner_client_id !== 'string'
        || typeof result.control_receipt !== 'string' || typeof result.control_version !== 'string'
        || !/^[a-f0-9]{64}$/.test(result.control_receipt ?? '')
        || !/^[a-f0-9]{64}$/.test(result.control_version ?? ''))
      throw new HttpError(502, 'NATIVE_PROTOCOL_MISMATCH', 'Native control observation is incompatible');
    if (target && !result.owner_client_id)
      throw new HttpError(502, 'NATIVE_PROTOCOL_MISMATCH', 'Native target owner is missing');
    return { native, target, raw: result,
      observation: target ? remoteControlObservation(target, result) : result };
  }

  receipt(threadId, submissionId) {
    const row = this.readIntent.get(submissionId);
    if (!row || row.threadId !== threadId)
      throw new HttpError(404, 'NATIVE_SUBMISSION_NOT_FOUND', 'Native submission is not recorded');
    return this.existingResult(row, row.requestHash);
  }

  async submit(threadId, kind, body) {
    const fields = new Set(['submission_id', 'control_receipt', 'control_version',
      ...(kind === 'input' ? ['text'] : ['expected_turn_id'])]);
    if (!body || typeof body !== 'object' || Array.isArray(body)
        || Object.keys(body).some(key => !fields.has(key))
        || typeof body.submission_id !== 'string' || !/^[A-Za-z0-9_-]{16,100}$/.test(body.submission_id)
        || typeof body.control_receipt !== 'string' || typeof body.control_version !== 'string'
        || !/^[a-f0-9]{64}$/.test(body.control_receipt ?? '')
        || !/^[a-f0-9]{64}$/.test(body.control_version ?? '')
        || !['input', 'interrupt'].includes(kind))
      throw new HttpError(400, 'INVALID_NATIVE_CONTROL', 'Native control identity required');
    if (kind === 'input' ? typeof body.text !== 'string' || !body.text.trim() || Buffer.byteLength(body.text) > 100000
        : typeof body.expected_turn_id !== 'string' || !body.expected_turn_id)
      throw new HttpError(400, 'INVALID_NATIVE_CONTROL', 'Native text or exact observed turn required');
    const requestHash = fingerprint(threadId, kind, body);
    const existing = this.readIntent.get(body.submission_id);
    if (existing) return this.existingResult(existing, requestHash); // No read or IPC replay.

    // Capture one immutable configured route. Never dispatch writes using a
    // shared "most recently read" client; the write body has no thread field.
    const target = this.nativeControlTargets.get(threadId);
    if (target && kind === 'interrupt')
      throw new HttpError(409, 'NATIVE_CONTROL_UNAVAILABLE', 'Remote target supports plain-text input only');
    const observed = await this.observe(threadId, target);
    const current = observed.observation;
    if (body.control_receipt !== current.control_receipt || body.control_version !== current.control_version)
      throw new HttpError(409, 'NATIVE_CONTROL_CHANGED', 'Refresh the current native observation before submitting');
    const operation = kind === 'input' ? current.reply_route : 'interrupt';
    if ((target && !['start', 'steer'].includes(operation))
        || !writeNames.has(operation) || (kind === 'input' ? current.input_available !== true
        : current.stop_available !== true || current.active_turn_id !== body.expected_turn_id))
      throw new HttpError(409, 'NATIVE_CONTROL_UNAVAILABLE', 'Native operation is not currently available');
    const now = new Date().toISOString();
    const claimed = this.claim({ submissionId: body.submission_id, requestHash, threadId,
      operation, requestJson: JSON.stringify({ body, observation: current }), now });
    if (claimed.existing) return this.existingResult(claimed.existing, requestHash);
    // Durable unknown intent is committed before any native write. Crashes or
    // disconnects leave it unknown; a repeated ID never resends the operation.
    let definitiveReceipt;
    const binding = target ? { ...remoteControlIdentity(target),
      owner_client_id: current.owner_client_id, control_receipt: current.control_receipt,
      control_version: current.control_version } : {};
    const recordOutcome = ({ error, payload }) => {
      let receipt, nativeResult;
      try {
        if (error) throw error;
        const outcome = JSON.parse(payload);
        if (outcome.submission_id !== body.submission_id || outcome.thread_id !== threadId
            || outcome.owner_client_id !== current.owner_client_id || outcome.operation !== operation)
          throw new Error('unverified-native-control-binding');
        if (operation === 'interrupt') {
          if (!['interrupted', 'not_interrupted'].includes(outcome.status)
              || (outcome.status === 'interrupted' ? outcome.turn_id !== body.expected_turn_id : outcome.turn_id !== null))
            throw new Error('unverified-native-stop-result');
        } else if (outcome.status !== 'accepted' || typeof outcome.turn_id !== 'string' || !outcome.turn_id) {
          throw new Error('unverified-native-input-result');
        }
        nativeResult = outcome.native_result;
        if (target) {
          const nativeTurn = operation === 'start' ? nativeResult?.result?.turn?.id : nativeResult?.result?.turnId;
          if (nativeTurn !== outcome.turn_id) throw new Error('unverified-native-target-turn');
        }
        receipt = { submission_id: body.submission_id, thread_id: threadId, operation, ...binding,
          status: outcome.status, turn_id: outcome.turn_id,
          ...(typeof nativeResult?.goalPauseError === 'string'
            ? { goal_pause_error: nativeResult.goalPauseError } : {}) };
      } catch (failure) {
        receipt = { submission_id: body.submission_id, thread_id: threadId, operation, ...binding,
          status: definitePreflightRejections.has(failure?.code) ? 'rejected' : 'unknown',
          code: definitePreflightRejections.has(failure?.code) ? failure.code : 'NATIVE_CONTROL_OUTCOME_UNKNOWN' };
      }
      this.finishIntent.run({ submissionId: body.submission_id, status: receipt.status,
        resultJson: JSON.stringify({ ...receipt, ...(nativeResult == null ? {} : { native_result: nativeResult }) }),
        now: new Date().toISOString() });
      definitiveReceipt = receipt;
      return receipt;
    };
    try {
      const rawBody = target ? { ...body, control_receipt: observed.raw.control_receipt } : body;
      const payload = await observed.native.call(operation, JSON.stringify(rawBody), { onOutcome: recordOutcome });
      return definitiveReceipt ?? recordOutcome({ payload });
    } catch (error) {
      return definitiveReceipt ?? recordOutcome({ error });
    }
  }
}
