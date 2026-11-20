"""Authenticated HTTP consumer's local projection; never returns raw storage rows."""
import hashlib
import json
import os
import sys
from datetime import date, datetime


class RequestError(Exception):
    def __init__(self, code, status=400):
        self.code, self.status = code, status


def pick(row, keys):
    return {key: row.get(key) if isinstance(row.get(key), (str, int, float, bool, date, datetime)) else None
            for key in keys.split()}


def thread(row, namespace):
    out = pick(row, 'thread_id kind host_id last_seen_at last_checked_at last_synced_at content_coverage attachment_coverage upstream_state')
    out['namespace'] = namespace
    metadata = row.get('metadata') or {}
    out['metadata'] = pick(metadata, 'title name status archived pinned createdAt updatedAt')
    status = metadata.get('status')
    if isinstance(status, dict) and isinstance(status.get('type'), str):
        out['metadata']['status'] = status['type']
    out['refresh_requested'] = bool(row.get('refresh_requested', False))
    return out


def bounded(value, default, low, high):
    if value is None:
        return default
    if isinstance(value, bool) or not str(value).isdigit():
        raise RequestError('invalid_pagination')
    return max(low, min(int(value), high))


def required_id(req):
    value = req.get('thread_id')
    if not isinstance(value, str) or not value or len(value) > 300:
        raise RequestError('invalid_thread_id')
    return value


def project_registry(row):
    data = row.get('registry') or {}
    def ref(value):
        return pick(value, 'thread_id host_id title role') if isinstance(value, dict) else None
    return {**pick(row, 'issue_id source_updated_at observed_at'), 'registry': {
        'master': ref(data.get('master')),
        'workers': [ref(v) for v in data.get('workers', []) if isinstance(v, dict)],
        'chatgpts': [ref(v) for v in data.get('chatgpts', []) if isinstance(v, dict)]}}


def dispatch(api, namespace, req):
    if not isinstance(req, dict) or 'namespace' in req or 'dsn' in req:
        raise RequestError('invalid_request')
    operation = req.get('operation')
    result = {'ok': True, 'namespace': namespace, 'source': 'local_mirror'}
    if operation == 'index':
        limit = bounded(req.get('limit'), 1000, 1, 1000)
        rows = api.index(limit=limit)
        result.update(threads=[thread(r, namespace) for r in rows], limit=limit,
                      possibly_truncated=len(rows) == limit, refresh_requested=False)
    elif operation in ('metadata', 'body'):
        tid = required_id(req)
        offline = req.get('offline', True)
        if not isinstance(offline, bool):
            raise RequestError('invalid_offline')
        offset = bounded(req.get('offset'), 0, 0, 2147483647)
        limit = bounded(req.get('limit'), 100, 1, 1000)
        # AGT-26 S6: tail=true returns the newest page (the phone opens at the bottom);
        # items=false drops the tool-call list, which is not paginated and can be several MB.
        tail = req.get('tail', False)
        with_items = req.get('items', True)
        if not isinstance(tail, bool) or not isinstance(with_items, bool):
            raise RequestError('invalid_request')
        # Continuation pages read the cache without another enqueue. A supplied
        # snapshot token detects changes below; no old snapshot is frozen here.
        continuation = (offset > 0 and not tail) or req.get('snapshot') is not None
        row = api.metadata(tid) if operation == 'metadata' else api.body(tid, offline=offline or continuation)
        if row is None:
            raise RequestError('thread_not_cached', 404)
        result['thread'] = thread(row, namespace)
        if operation == 'body':
            messages = [pick(m, 'native_id role text_content last_seen_at turn_id phase turn_status context_snapshot_sha256') for m in row.get('messages', [])]
            # Offset is stable within this snapshot; changed data requires a fresh first page.
            snapshot = hashlib.sha256(json.dumps(messages, sort_keys=True, default=serialize).encode()).hexdigest()
            if req.get('snapshot') is not None and req['snapshot'] != snapshot:
                raise RequestError('snapshot_changed', 409)
            if tail:
                offset = max(0, len(messages) - limit)
            result.update(messages=messages[offset:offset+limit],
                          items=[pick(i, 'native_id type last_seen_at') for i in row.get('items', [])] if with_items else [],
                          attachments=[{**pick(a, 'native_id mime state'), 'filename': str(a.get('filename') or '').replace('\\', '/').rsplit('/', 1)[-1]} for a in row.get('attachments', [])],
                          page={'offset': offset, 'limit': limit, 'local_total': len(messages), 'snapshot': snapshot,
                                'next_offset': offset+limit if offset+limit < len(messages) else None,
                                'scope': 'local_only'})
    elif operation == 'registry':
        issue_id = req.get('issue_id')
        if issue_id is not None and (not isinstance(issue_id, str) or len(issue_id) > 300):
            raise RequestError('invalid_issue_id')
        result.update(observations=[project_registry(r) for r in api.registry(issue_id=issue_id)], refresh_requested=False)
    else:
        raise RequestError('invalid_operation')
    return result


def serialize(value):
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    raise TypeError('unsupported_value')


def execute(api, namespace, req):
    try:
        return dispatch(api, namespace, req)
    except RequestError as exc:
        return {'ok': False, 'error': {'code': exc.code}, 'status': exc.status}
    except Exception:
        # DB exceptions may contain connection details and source text.
        return {'ok': False, 'error': {'code': 'mirror_unavailable'}, 'status': 503}


def main():
    try:
        req = json.loads(sys.stdin.read(65537))
        namespace = os.environ['MIRROR_NAMESPACE']
        dsn = os.environ['MIRROR_DSN']
        sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parents[1] / 'mirror_backend'))
        from mirror.api import LocalMirror
        from mirror.store import Store
        result = execute(LocalMirror(Store(dsn, namespace)), namespace, req)
        output = json.dumps(result, ensure_ascii=False, default=serialize)
    except (json.JSONDecodeError, UnicodeError):
        output = json.dumps({'ok': False, 'error': {'code': 'invalid_json'}, 'status': 400})
    except Exception:
        output = json.dumps({'ok': False, 'error': {'code': 'mirror_unavailable'}, 'status': 503})
    print(output)


if __name__ == '__main__':
    main()
