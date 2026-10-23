"""Inactive JSONL candidate. One existing follower, configured local threads only."""
import argparse
import copy
import hashlib
import json
import sys
import uuid
from follower import Follower


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def version(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def same_id(a, b):
    return type(a) in (int, str) and type(a) is type(b) and a == b


class AdapterError(Exception):
    def __init__(self, code='NATIVE_REQUEST_UNAVAILABLE', message='Refresh the original request before acting'):
        self.code, self.message = code, message


class Adapter:
    def __init__(self, follower, threads, generation=None):
        self.follower = follower
        self.threads = tuple(dict.fromkeys(threads))
        self.generation = generation or str(uuid.uuid4())
        self.receipts = {}
        self.attempted = set()
        self.submitted = set()

    def fresh(self, thread):
        try:
            view = self.follower.follow(thread, host_id='local')
        except Exception:
            raise AdapterError('NATIVE_OWNER_UNAVAILABLE', 'Current native owner snapshot unavailable') from None
        if not view.get('valid') or view.get('hostId') != 'local' or view.get('threadId') != thread or not view.get('ownerClientId') or not isinstance(view.get('requests'), list):
            raise AdapterError()
        return view

    def bind(self, view, request):
        rid = request.get('id')
        if type(rid) not in (int, str) or not isinstance(request.get('method'), str) or not isinstance(request.get('params'), dict):
            raise AdapterError('NATIVE_PROTOCOL_MISMATCH', 'Invalid native request schema')
        digest = version(request)
        binding = [self.generation, view['ownerClientId'], view['hostId'], view['threadId'], type(rid).__name__, rid, digest]
        receipt = version(binding)
        self.receipts[receipt] = {'owner': view['ownerClientId'], 'host': view['hostId'], 'thread': view['threadId'], 'rid': rid, 'version': digest, 'request': copy.deepcopy(request)}
        return receipt

    def observed(self, receipt, request):
        b = self.receipts[receipt]
        key = (b['owner'], b['host'], b['thread'], type(b['rid']).__name__, b['rid'])
        writable = (request['method'] == 'item/tool/requestUserInput'
                    and set(request) == {'id', 'method', 'params'}
                    and request['params'].get('threadId') == b['thread']
                    and isinstance(request['params'].get('turnId'), str) and bool(request['params']['turnId'])
                    and key not in self.attempted
                    and (type(b['rid']) is str or abs(b['rid']) <= 9007199254740991))
        return dict(receipt_id=receipt, request_id=b['rid'], thread_id=b['thread'],
                    request_version=b['version'], request=copy.deepcopy(request),
                    turn_id=request['params'].get('turnId'), response_available=writable,
                    response_submitted=key in self.submitted)

    def handle(self, operation, body):
        if not isinstance(body, dict):
            raise AdapterError('INVALID_NATIVE_REQUEST', 'JSON object required')
        if operation == 'list':
            if body:
                raise AdapterError('INVALID_NATIVE_REQUEST', 'List accepts no client scope')
            data = []
            for thread in self.threads:
                view = self.fresh(thread)
                for request in view['requests']:
                    receipt = self.bind(view, request)
                    native = self.follower.native_observation(thread, request, view['ownerClientId'], host_id='local')
                    observed = {**self.observed(receipt, request), **native}
                    if native: observed['response_available'] = False
                    data.append(observed)
            return {'data': data}
        if operation not in ('read', 'respond') or set(body) - {'receipt_id', 'request_id', 'request_version', 'response'}:
            raise AdapterError('INVALID_NATIVE_REQUEST', 'Unsupported operation or fields')
        receipt = body.get('receipt_id')
        b = self.receipts.get(receipt) if isinstance(receipt, str) else None
        if b is None or not same_id(body.get('request_id'), b['rid']):
            raise AdapterError()
        if body.get('request_version', b['version']) != b['version']:
            raise AdapterError()
        view = self.fresh(b['thread'])
        if view['ownerClientId'] != b['owner'] or view['hostId'] != b['host']:
            raise AdapterError('NATIVE_OWNER_CHANGED', 'Original native owner changed')
        request = next((r for r in view['requests'] if same_id(r.get('id'), b['rid'])), None)
        native = self.follower.native_observation(b['thread'], b['request'], b['owner'], host_id=b['host'])
        if request is None:
            # Disappearance is not serverRequest/resolved evidence.
            if operation == 'read' and native:
                return {**self.observed(receipt, b['request']), **native, 'response_available': False}
            raise AdapterError('NATIVE_REQUEST_NOT_PENDING', 'Request absent from current snapshot; resolution unverified')
        if version(request) != b['version']:
            raise AdapterError('NATIVE_REQUEST_CHANGED', 'Native request changed; refresh required')
        observed = {**self.observed(receipt, request), **native}
        if native: observed['response_available'] = False
        if operation == 'read':
            return observed
        response = body.get('response')
        if (not isinstance(response, dict) or not same_id(response.get('id'), b['rid'])
                or set(response) - {'jsonrpc', 'id', 'result'} or 'result' not in response
                or response.get('jsonrpc', '2.0') != '2.0'):
            raise AdapterError('INVALID_NATIVE_RESPONSE', 'Original typed id and native result required; error responses unsupported')
        if body.get('request_version') != b['version'] or not observed['response_available']:
            raise AdapterError()
        result = response['result']
        key = (b['owner'], b['host'], b['thread'], type(b['rid']).__name__, b['rid'])
        self.attempted.add(key)
        try:
            self.follower.respond(b['thread'], b['rid'], result, b['owner'], host_id=b['host'], expected_request=request, expected_turn_id=request['params']['turnId'])
        except Exception:
            raise AdapterError('NATIVE_RESPONSE_OUTCOME_UNKNOWN', 'Read original request; do not resubmit automatically') from None
        self.submitted.add(key)
        return {**observed, 'response_available': False, 'response_submitted': True}

    def line(self, command):
        ident = command.get('id') if isinstance(command, dict) else None
        try:
            if not isinstance(command, dict) or set(command) - {'id', 'operation', 'body'}:
                raise AdapterError('INVALID_NATIVE_REQUEST', 'Invalid JSONL envelope')
            payload = self.handle(command.get('operation'), command.get('body', {}))
            return {'id': ident, 'payload_json': canonical(payload)}
        except AdapterError as error:
            return {'id': ident, 'error': {'code': error.code, 'message': error.message}}
        except Exception:
            return {'id': ident, 'error': {'code': 'NATIVE_REQUEST_UNAVAILABLE', 'message': 'Native request unavailable'}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--thread', action='append', required=True, type=lambda x: str(uuid.UUID(x)))
    args = parser.parse_args()
    follower = Follower()
    adapter = Adapter(follower, args.thread)
    try:
        for line in sys.stdin:
            try:
                command = json.loads(line, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
                reply = adapter.line(command)
            except (ValueError, TypeError):
                reply = {'id': None, 'error': {'code': 'INVALID_JSON', 'message': 'Invalid JSONL input'}}
            print(canonical(reply), flush=True)
    finally:
        follower.close()


if __name__ == '__main__':
    main()
