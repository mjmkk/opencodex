"""Version-pinned, same-user Desktop follower. Never creates an IPC router/owner."""
import argparse
import copy
import json
import queue
import socket
import struct
import sys
import threading
import time
import uuid

DEFAULT_SOCKET = '/home/spirit/codex/ipc/ipc.sock'
METHODS = {
    'item/commandExecution/requestApproval': ('thread-follower-command-approval-decision', 'decision'),
    'item/fileChange/requestApproval': ('thread-follower-file-approval-decision', 'decision'),
    'item/permissions/requestApproval': ('thread-follower-permissions-request-approval-response', 'response'),
    'item/tool/requestUserInput': ('thread-follower-submit-user-input', 'response'),
    'mcpServer/elicitation/request': ('thread-follower-submit-mcp-server-elicitation-response', 'response'),
}

def patch_state(state, patches):
    result = copy.deepcopy(state)
    for patch in patches:
        path = patch['path']
        if not isinstance(path, list) or patch['op'] not in ('add', 'remove', 'replace'):
            raise ValueError('unsupported-native-patch')
        if not path:
            if patch['op'] == 'remove': raise ValueError('removed-root')
            result = copy.deepcopy(patch['value']); continue
        parent = result
        for key in path[:-1]: parent = parent[key]
        key = path[-1]
        if patch['op'] == 'remove': del parent[key]
        elif isinstance(parent, list) and patch['op'] == 'add': parent.insert(key, copy.deepcopy(patch['value']))
        else: parent[key] = copy.deepcopy(patch['value'])
    return result

class Follower:
    def __init__(self, path=DEFAULT_SOCKET):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(path)
        self.lock = threading.RLock()
        self.write_lock = threading.Lock()
        self.pending = {}
        self.views = {}
        self.attempted = set()
        self.observations = {}
        self.invalid_owners = set()
        self.client = 'initializing-client'
        self.closed = False
        threading.Thread(target=self._reader, daemon=True).start()
        self.client = self.rpc('initialize', {'clientType': 'opencodex-mobile-follower'}, version=0)['result']['clientId']

    def send(self, message):
        data = json.dumps(message, separators=(',', ':')).encode()
        with self.write_lock: self.sock.sendall(struct.pack('<I', len(data)) + data)

    def rpc(self, method, params, owner=None, host=None, version=1, timeout=12):
        ident = str(uuid.uuid4()); inbox = queue.Queue()
        with self.lock: self.pending[ident] = inbox
        message = dict(type='request', requestId=ident, sourceClientId=self.client,
                       version=version + (1 if host and host != 'local' else 0), method=method,
                       params=params, timeoutMs=int(timeout * 1000))
        if owner: message['targetClientId'] = owner
        if host and host != 'local': message['hostId'] = host
        try:
            self.send(message)
            response = inbox.get(timeout=timeout)
            if response.get('resultType') != 'success': raise RuntimeError(response.get('error', 'native-error'))
            if response.get('method') != method: raise RuntimeError('native-method-mismatch')
            if owner and response.get('handledByClientId') != owner: raise RuntimeError('owner-mismatch')
            return response
        finally:
            with self.lock: self.pending.pop(ident, None)

    def _read_exact(self, length):
        data = bytearray()
        while len(data) < length:
            block = self.sock.recv(length - len(data))
            if not block: raise EOFError()
            data.extend(block)
        return data

    def _reader(self):
        try:
            while True:
                length = struct.unpack('<I', self._read_exact(4))[0]
                if not 0 < length <= 268435456: raise ValueError('invalid-frame')
                message = json.loads(self._read_exact(length))
                if message['type'] == 'client-discovery-request':
                    self.send(dict(type='client-discovery-response', requestId=message['requestId'], response={'canHandle': False}))
                elif message['type'] == 'response':
                    with self.lock:
                        inbox = self.pending.get(message['requestId'])
                        if inbox: inbox.put(message)
                elif message['type'] == 'broadcast': self.observe(message)
        except Exception:
            with self.lock:
                self.closed = True
                for view in self.views.values(): view['valid'] = False
                for inbox in self.pending.values(): inbox.put({'error': 'connection-closed'})

    def observe(self, message):
        with self.lock:
            if message.get('targetClientIds') is not None and self.client not in message['targetClientIds']: return
            params = message.get('params', {})
            if message['method'] == 'client-status-changed' and params.get('status') == 'disconnected':
                self.invalid_owners.add(params.get('clientId'))
                for view in self.views.values():
                    if view['ownerClientId'] == params.get('clientId'): view['valid'] = False
            if message['method'] == 'mobile-native-request-observation':
                self.observe_native(message)
                return
            if message['method'] != 'thread-stream-state-changed': return
            view = self.views.get((params.get('hostId'), params.get('conversationId')))
            if not view or message.get('sourceClientId') != view['ownerClientId']: return
            if view['ownerClientId'] in self.invalid_owners: return
            if message.get('version') != 11: view['valid'] = False; return
            change = params['change']
            try:
                if change['type'] == 'snapshot':
                    view.update(state=copy.deepcopy(change['conversationState']), revision=change['revision'], valid=True)
                elif change['type'] == 'patches' and view['valid'] and change['baseRevision'] == view['revision']:
                    view.update(state=patch_state(view['state'], change['patches']), revision=change['revision'])
                else: view['valid'] = False
                if view['valid']: self.bind_observations(view)
            except (KeyError, IndexError, TypeError, ValueError): view['valid'] = False

    def bind_observations(self, view):
        for request in (view.get('state') or {}).get('requests', []):
            rid = request.get('id')
            params = request.get('params') or {}
            if type(rid) not in (int, str) or params.get('threadId') != view['threadId'] or not isinstance(params.get('turnId'), str): continue
            key = (view['ownerClientId'], view['hostId'], view['threadId'], type(rid).__name__, rid)
            old = self.observations.get(key)
            serialized = json.dumps(request, sort_keys=True, separators=(',', ':'), allow_nan=False)
            if old is None or old['request_json'] != serialized:
                self.observations[key] = {'request_json': serialized, 'turn_id': params['turnId']}

    def observe_native(self, message):
        envelope = message.get('params') or {}
        owner = message.get('sourceClientId')
        if message.get('version') != 0 or envelope.get('hostId') != 'local' or owner in self.invalid_owners: return
        method, params = envelope.get('method'), envelope.get('params')
        if not isinstance(params, dict): return
        if method == 'connection/state':
            if params.get('state') != 'connected' and any(v['ownerClientId'] == owner for v in self.views.values()):
                self.invalid_owners.add(owner)
                for view in self.views.values():
                    if view['ownerClientId'] == owner: view['valid'] = False
            return
        if method not in ('serverRequest/resolved', 'turn/completed'): return
        tid = params.get('threadId')
        view = self.views.get(('local', tid))
        if not view or view['ownerClientId'] != owner: return
        for key, record in self.observations.items():
            if key[:3] != (owner, 'local', tid): continue
            if method == 'serverRequest/resolved':
                rid = params.get('requestId')
                if type(rid).__name__ != key[3] or rid != key[4]: continue
                if params.get('turnId', record['turn_id']) != record['turn_id']: continue
                record['native_resolution'] = copy.deepcopy({'method': method, 'params': params})
            else:
                turn = params.get('turn')
                if not isinstance(turn, dict) or turn.get('id') != record['turn_id']: continue
                record['native_terminal'] = copy.deepcopy(turn)

    def native_observation(self, thread_id, request, owner_client_id, host_id='local'):
        with self.lock:
            if self.closed or owner_client_id in self.invalid_owners: raise ValueError('connection-observation-invalid')
            view = self.views.get((host_id, thread_id))
            if not view or not view['valid'] or view['ownerClientId'] != owner_client_id: raise ValueError('stale-owner-or-view')
            rid = request['id']
            key = (owner_client_id, host_id, thread_id, type(rid).__name__, rid)
            record = self.observations.get(key)
            if not record or record['request_json'] != json.dumps(request, sort_keys=True, separators=(',', ':'), allow_nan=False): return {}
            return copy.deepcopy({k: record[k] for k in ('native_resolution', 'native_terminal') if k in record})

    def follow(self, thread_id, host_id='local', timeout=12):
        owner = self.rpc('thread-owner-discovery', {'hostId': host_id, 'conversationId': thread_id})['handledByClientId']
        if owner in self.invalid_owners or self.closed: raise ValueError('connection-observation-invalid')
        key = (host_id, thread_id)
        with self.lock: self.views[key] = dict(ownerClientId=owner, hostId=host_id, threadId=thread_id, valid=False, revision=None, state=None)
        self.send(dict(type='broadcast', method='thread-stream-following-changed', version=1,
                       sourceClientId=self.client, targetClientIds=[owner],
                       params=dict(hostId=host_id, conversationId=thread_id, following=True)))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.lock:
                if self.views[key]['valid']: return self.read(thread_id, host_id)
                if self.closed: raise RuntimeError('connection-closed')
            time.sleep(.05)
        raise TimeoutError('native-snapshot-timeout')

    def read(self, thread_id, host_id='local'):
        with self.lock:
            view = self.views[(host_id, thread_id)]
            return copy.deepcopy({k: v for k, v in view.items() if k != 'state'} | {'requests': (view['state'] or {}).get('requests', [])})

    def respond(self, thread_id, request_id, response, owner_client_id, host_id='local', expected_request=None, expected_turn_id=None):
        with self.lock:
            view = self.views[(host_id, thread_id)]
            if self.closed or not view['valid'] or owner_client_id != view['ownerClientId']: raise ValueError('stale-owner-or-view')
            requests = view['state'].get('requests', [])
            request = next((r for r in requests if type(r['id']) is type(request_id) and r['id'] == request_id), None)
            if request is None: raise ValueError('request-not-pending')
            if expected_request is not None and json.dumps(request, sort_keys=True, separators=(',', ':'), allow_nan=False) != json.dumps(expected_request, sort_keys=True, separators=(',', ':'), allow_nan=False):
                raise ValueError('request-version-changed')
            if type(request_id) not in (int, str) or (type(request_id) is int and abs(request_id) > 9007199254740991):
                raise ValueError('request-id-not-lossless-over-native-js-ipc')
            if request['method'] not in METHODS: raise ValueError('unsupported-native-method')
            method, field = METHODS[request['method']]
            key = (owner_client_id, host_id, thread_id, type(request_id).__name__, str(request_id))
            if key in self.attempted: raise ValueError('response-already-attempted')
            if field == 'decision':
                if not isinstance(response, dict) or set(response) != {'decision'}: raise ValueError('native-decision-result-required')
                value = response['decision']
                available = request.get('params', {}).get('availableDecisions')
                if available is not None and value not in available: raise ValueError('decision-not-available')
            else: value = response
            self.attempted.add(key)
        # ACK and later disappearance are not serverRequest/resolved evidence.
        params = dict(conversationId=thread_id, requestId=request_id, **{field: value})
        if expected_request is not None:
            params.update(mobileExpectedRequest=expected_request, mobileExpectedTurnId=expected_turn_id)
        return self.rpc(method, params, owner=owner_client_id, host=host_id)

    def close(self):
        self.sock.close()

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--socket', default=DEFAULT_SOCKET); parser.add_argument('--probe')
    args = parser.parse_args(); follower = Follower(args.socket)
    try:
        if args.probe:
            result = follower.follow(args.probe)
            result['requests'] = [{'id': r['id'], 'method': r['method']} for r in result['requests']]
            print(json.dumps(result)); return
        for line in sys.stdin:
            command = json.loads(line)
            try:
                operation = command['op']; params = command.get('params', {})
                if operation not in ('follow', 'read', 'respond'): raise ValueError('unsupported-operation')
                result = getattr(follower, operation)(**params)
                print(json.dumps({'id': command.get('id'), 'result': result}), flush=True)
            except Exception as error:
                print(json.dumps({'id': command.get('id'), 'error': str(error)}), flush=True)
    finally: follower.close()

if __name__ == '__main__': main()
