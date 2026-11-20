'use strict';

const { execFile } = require('node:child_process');
const { isDeepStrictEqual } = require('node:util');
const path = require('node:path');

const IDENTIFIER = /^[A-Z][A-Z0-9]{0,15}-[1-9][0-9]{0,11}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HEALTH = new Set(['On track', 'At risk', 'Blocked']);
const AVAILABILITY = new Set(['current', 'pending', 'last_known', 'partial']);
const DIMENSION_AVAILABILITY = new Set(['current', 'pending', 'last_known', 'not_applicable']);
const ERROR_CODES = new Set(['invalid_issue_id', 'goal_not_found', 'overview_unavailable']);
const REASON_CODE = /^[a-z][a-z0-9_]{0,95}$/;

function object(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function timestamp(value) {
  return typeof value === 'string' && /T.*(?:Z|[+-]\d{2}:\d{2})$/.test(value) && Number.isFinite(Date.parse(value));
}

function inventoryInstant(value) {
  if (typeof value !== 'string') return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|([+-])(\d{2}):(\d{2}))$/.exec(value);
  if (!match) return null;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  const offsetHour = Number(match[10] ?? 0);
  const offsetMinute = Number(match[11] ?? 0);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (year < 1 || month < 1 || month > 12 || day < 1 || day > monthDays[month - 1]
      || hour > 23 || minute > 59 || second > 59 || offsetHour > 23 || offsetMinute > 59) return null;
  // Date.parse normalizes invalid calendar days and drops sub-millisecond
  // precision. Validate the components first and compare the full fraction.
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, 0);
  const offset = (offsetHour * 60 + offsetMinute) * (match[9] === '-' ? -1 : 1);
  return { seconds: date.getTime() / 1000 - offset * 60, fraction: (match[7] ?? '').replace(/0+$/, '') };
}

function compareInventoryInstants(left, right) {
  if (left.seconds !== right.seconds) return left.seconds < right.seconds ? -1 : 1;
  const width = Math.max(left.fraction.length, right.fraction.length);
  const a = left.fraction.padEnd(width, '0');
  const b = right.fraction.padEnd(width, '0');
  return a === b ? 0 : a < b ? -1 : 1;
}

function validMetadata(value) {
  return object(value) && !Object.hasOwn(value, 'value')
    && ['input_version', 'goal_version', 'method_version'].every(key => typeof value[key] === 'string' && value[key].trim())
    && timestamp(value.evaluated_at)
    && (value.input_coverage_at === null || timestamp(value.input_coverage_at))
    && Array.isArray(value.sources) && value.sources.every(object);
}

function validDimensions(goal) {
  const dimensions = goal.dimensions;
  if (!(goal.unavailability_reason === null || typeof goal.unavailability_reason === 'string' && goal.unavailability_reason.trim())) return false;
  if (!object(dimensions) || Object.keys(dimensions).length !== 2
      || !Object.hasOwn(dimensions, 'Progress') || !Object.hasOwn(dimensions, 'Health')) return false;
  for (const name of ['Progress', 'Health']) {
    const dimension = dimensions[name];
    if (!object(dimension) || Object.keys(dimension).length !== 4
        || !['availability', 'value', 'unavailability_reason', 'observation'].every(key => Object.hasOwn(dimension, key))
        || !DIMENSION_AVAILABILITY.has(dimension.availability)
        || dimension.value !== goal[name === 'Progress' ? 'progress' : 'health']
        || !(dimension.unavailability_reason === null || typeof dimension.unavailability_reason === 'string' && dimension.unavailability_reason.trim())) return false;
    if (dimension.availability === 'pending') {
      if (dimension.value !== null || dimension.observation !== null || dimension.unavailability_reason === null) return false;
      continue;
    }
    if (!validMetadata(dimension.observation)) return false;
    const notApplicable = dimension.observation.not_applicable === true;
    if (Object.hasOwn(dimension.observation, 'not_applicable') && !notApplicable) return false;
    if (name === 'Health') {
      if (!HEALTH.has(dimension.value) || dimension.availability === 'not_applicable' || notApplicable) return false;
    } else if (dimension.value === null) {
      if (!notApplicable || dimension.observation.completion_scope !== 'unbounded'
          || !['not_applicable', 'last_known'].includes(dimension.availability)) return false;
    } else if (!Number.isInteger(dimension.value) || dimension.value < 0 || dimension.value > 100 || notApplicable
               || dimension.availability === 'not_applicable') return false;
    if (dimension.availability === 'current' && dimension.unavailability_reason !== null) return false;
    if (dimension.availability === 'not_applicable' && dimension.unavailability_reason !== 'unbounded_goal') return false;
    if (dimension.availability === 'last_known' && dimension.unavailability_reason === null) return false;
  }
  const statuses = Object.values(dimensions).map(value => value.availability);
  const availability = statuses.every(value => value === 'pending') ? 'pending'
    : statuses.every(value => ['current', 'not_applicable'].includes(value)) ? 'current'
      : statuses.every(value => value === 'last_known') ? 'last_known' : 'partial';
  if (goal.availability !== availability || (availability === 'current') !== (goal.unavailability_reason === null)) return false;
  const metadata = Object.values(dimensions).map(value => value.observation === null ? null
    : Object.fromEntries(Object.entries(value.observation).filter(([key]) => key !== 'not_applicable')));
  const common = ['current', 'last_known'].includes(availability) && metadata[0] !== null
    && isDeepStrictEqual(metadata[0], metadata[1]) ? metadata[0] : null;
  return isDeepStrictEqual(goal.observation, common);
}

function validClosureScope(scope, issueUrl) {
  const fields = ['description', 'source_url', 'call_id', 'parent_call_id'];
  if (!object(scope) || Object.keys(scope).length !== fields.length
      || !fields.every(key => Object.hasOwn(scope, key) && typeof scope[key] === 'string' && scope[key].trim())
      || !UUID.test(scope.call_id) || !UUID.test(scope.parent_call_id)
      || scope.call_id.toLowerCase() === scope.parent_call_id.toLowerCase()) return false;
  try {
    const base = new URL(issueUrl);
    const source = new URL(scope.source_url);
    if (base.protocol !== 'https:' || source.protocol !== 'https:' || base.username || base.password
        || source.username || source.password || !/^#comment-[^#/?\s]+$/.test(source.hash)) return false;
    base.hash = ''; source.hash = '';
    // Escape hex case is equivalent; preserve encoded separators and comment identity.
    const canonicalEscapes = href => href.replace(/%[0-9a-f]{2}/gi, escape => escape.toUpperCase());
    return canonicalEscapes(base.href) === canonicalEscapes(source.href);
  } catch { return false; }
}

function validGoal(goal) {
  if (!goal || typeof goal !== 'object' || Array.isArray(goal)) return false;
  if (!IDENTIFIER.test(goal.issue_id) || goal.goal_id !== goal.issue_id) return false;
  if (typeof goal.title !== 'string' || typeof goal.issue_url !== 'string') return false;
  if (Object.hasOwn(goal, 'closure_scope') && !validClosureScope(goal.closure_scope, goal.issue_url)) return false;
  if (!(goal.progress === null || Number.isInteger(goal.progress) && goal.progress >= 0 && goal.progress <= 100)) return false;
  if (!(goal.health === null || HEALTH.has(goal.health)) || !AVAILABILITY.has(goal.availability)) return false;
  if (!(goal.observation === null || typeof goal.observation === 'object' && !Array.isArray(goal.observation))) return false;
  if (!Array.isArray(goal.closure_obligations) || !Array.isArray(goal.workers)) return false;
  // A present malformed dimensions field cannot fall back to the legacy shape.
  if (Object.hasOwn(goal, 'dimensions')) return validDimensions(goal);
  if (goal.availability === 'partial') return false;
  // An unavailable observer must not manufacture a business assessment.
  if (goal.availability === 'pending' && (goal.progress !== null || goal.health !== null || goal.observation !== null)) return false;
  if (goal.availability !== 'pending' && (goal.observation === null || !HEALTH.has(goal.health))) return false;
  // Legacy clients already require these identities and the original scoring
  // time. Apply the same boundary to nonempty closure rows, without requiring
  // the newer dimension-only goal_version field on legacy metadata.
  if (goal.availability !== 'pending' && (!timestamp(goal.observation.evaluated_at)
      || !['input_version', 'method_version'].every(key => typeof goal.observation[key] === 'string' && goal.observation[key].trim()))) return false;
  return true;
}

function validGoalTree(root) {
  const seen = new Set();
  const pending = [root];
  while (pending.length) {
    const goal = pending.pop();
    if (!validGoal(goal) || seen.has(goal.issue_id)) return false;
    seen.add(goal.issue_id);
    // The producer supplies explicit accepted obligations. Validation does
    // not derive them from Related links, native activity or worker identity.
    for (const obligation of goal.closure_obligations) pending.push(obligation);
  }
  return true;
}

function validResult(result, operation, issueId, namespace) {
  if (!result || result.ok !== true || result.schema_version !== 1 || result.source !== 'goal_observer') return false;
  if (result.namespace !== namespace || !Number.isSafeInteger(result.snapshot_revision) || result.snapshot_revision < 1) return false;
  const observed = inventoryInstant(result.inventory_observed_at);
  if (observed === null) return false;
  const keys = ['ok', 'schema_version', 'source', 'namespace', 'snapshot_revision', 'inventory_observed_at',
    operation === 'list' ? 'goals' : 'goal'];
  if (Object.hasOwn(result, 'inventory_validation')) {
    const validation = result.inventory_validation;
    const fields = ['availability', 'verified_at', 'unavailability_reason'];
    if (!object(validation) || Object.keys(validation).length !== fields.length
        || !fields.every(key => Object.hasOwn(validation, key))
        || !(validation.unavailability_reason === null
             || typeof validation.unavailability_reason === 'string' && REASON_CODE.test(validation.unavailability_reason))) return false;
    if (validation.availability === 'current') {
      const verified = inventoryInstant(validation.verified_at);
      if (verified === null || compareInventoryInstants(verified, observed) !== 0
          || validation.unavailability_reason !== null) return false;
    } else if (validation.availability === 'last_known') {
      if (validation.verified_at !== null) {
        const verified = inventoryInstant(validation.verified_at);
        if (verified === null || compareInventoryInstants(verified, observed) > 0) return false;
      }
    } else if (validation.availability === 'unknown') {
      if (validation.verified_at !== null) return false;
    } else return false;
    keys.push('inventory_validation');
  }
  if (Object.keys(result).length !== keys.length || keys.some(key => !Object.hasOwn(result, key))) return false;
  return operation === 'list'
    ? Array.isArray(result.goals) && result.goals.every(validGoalTree)
    : validGoalTree(result.goal) && result.goal.issue_id === issueId;
}

// The caller mounts this handler after its existing Bearer authentication.
// All paths and storage scope come from trusted server configuration.
function createOverviewRoutes({ namespace, dsn, cachePath,
  adapterPath = path.join(__dirname, 'adapter.py'),
  python = '/home/spirit/agt28-mirror/.venv/bin/python',
  invoke, timeoutMs = 5000 } = {}) {
  if (![namespace, dsn, cachePath, adapterPath, python].every(value => typeof value === 'string' && value.trim())) {
    throw new Error('Overview server configuration required');
  }
  if (![cachePath, adapterPath, python].every(path.isAbsolute)) throw new Error('Overview server paths must be absolute');
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 5000) throw new Error('Invalid Overview timeout');
  if (invoke !== undefined && typeof invoke !== 'function') throw new Error('Invalid Overview adapter');
  let latestSnapshotRevision = 0;

  const run = invoke || (input => new Promise((resolve, reject) => {
    const child = execFile(python, [adapterPath], {
      timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024,
      env: { PATH: '/usr/bin:/bin', LANG: 'C.UTF-8',
        OVERVIEW_NAMESPACE: namespace, OVERVIEW_DSN: dsn, OVERVIEW_CACHE_PATH: cachePath },
    }, (error, stdout) => {
      if (error) return reject(error);
      try { resolve(JSON.parse(stdout)); } catch { reject(new Error('invalid_adapter_response')); }
    });
    child.stdin.on('error', reject);
    child.stdin.end(JSON.stringify(input));
  }));

  async function read(input) {
    let timer;
    try {
      return await Promise.race([
        Promise.resolve().then(() => run(input)),
        new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('adapter_timeout')), timeoutMs); }),
      ]);
    } finally { clearTimeout(timer); }
  }

  return async function overviewRoutes(req, res) {
    let url;
    try { url = new URL(req.url, 'http://localhost'); }
    catch { return false; }
    if (!url.pathname.startsWith('/v1/overview/')) return false;
    const send = (status, data, extraHeaders = {}) => {
      res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...extraHeaders });
      res.end(JSON.stringify(data));
      return true;
    };
    const error = (status, code, headers) => send(status, { ok: false, error: { code } }, headers);
    if (req.method !== 'GET') return error(405, 'method_not_allowed', { Allow: 'GET' });
    // GET is a cache read. No client-controlled refresh, scope or file input.
    const contentLength = req.headers?.['content-length'];
    if (url.search || req.headers?.['transfer-encoding'] || contentLength !== undefined && contentLength !== '0') {
      return error(400, 'invalid_request');
    }
    let input;
    if (url.pathname === '/v1/overview/goals') input = { operation: 'list' };
    else {
      const match = url.pathname.match(/^\/v1\/overview\/goals\/([^/]+)$/);
      if (!match) return error(404, 'route_not_found');
      let issueId;
      try { issueId = decodeURIComponent(match[1]); } catch { return error(400, 'invalid_issue_id'); }
      if (!IDENTIFIER.test(issueId)) return error(400, 'invalid_issue_id');
      input = { operation: 'get', issue_id: issueId };
    }
    let result;
    try { result = await read(input); } catch { return error(503, 'overview_unavailable'); }
    if (result?.ok === false) {
      const code = result.error?.code;
      if (result.status === 404 && code === 'goal_not_found') return error(404, code);
      if (result.status === 400 && ERROR_CODES.has(code)) return error(400, code);
      return error(503, 'overview_unavailable');
    }
    if (!validResult(result, input.operation, input.issue_id, namespace) || result.snapshot_revision < latestSnapshotRevision) {
      return error(503, 'overview_unavailable');
    }
    latestSnapshotRevision = result.snapshot_revision;
    return send(200, result);
  };
}

module.exports = { createOverviewRoutes };
