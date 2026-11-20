"""Optional message parent context projected from the same saved native pages.

This is a disposable projection. It does not alter upstream items or raw facts.
Absent or conflicting source identity stays unknown.
"""
import re
from .parser import hashed


def project_message_context(pages):
    contexts = {}
    suppressed = set()
    for page in pages:
        for turn in page.get('turns') or []:
            if not isinstance(turn, dict):
                continue
            turn_id = turn.get('id')
            for item in turn.get('items') or []:
                if not isinstance(item, dict) or item.get('type') not in ('userMessage', 'agentMessage'):
                    continue
                native_id = item.get('id') or item.get('node_id')
                if not native_id:
                    continue
                native_id = str(native_id)
                if native_id in suppressed:
                    continue
                if not isinstance(turn_id, str) or not turn_id:
                    contexts.pop(native_id, None)
                    suppressed.add(native_id)
                    continue
                context = {
                    'payload_hash': hashed(item),
                    'turn_id': turn_id,
                    'phase': item.get('phase') if isinstance(item.get('phase'), str) else None,
                    'turn_status': turn.get('status') if isinstance(turn.get('status'), str) else None,
                }
                if native_id in contexts and contexts[native_id] != context:
                    contexts.pop(native_id)
                    suppressed.add(native_id)
                else:
                    contexts[native_id] = context
    return contexts


def attach_message_context(messages, coverage_detail):
    """Publish context only for the exact current native item payload hash."""
    detail = coverage_detail if isinstance(coverage_detail, dict) else {}
    contexts = detail.get('message_context')
    contexts = contexts if isinstance(contexts, dict) else {}
    snapshot = detail.get('message_context_snapshot_sha256')
    valid_snapshot = isinstance(snapshot, str) and re.fullmatch('[0-9a-f]{64}', snapshot) is not None
    for message in messages:
        for key in ('turn_id', 'phase', 'turn_status', 'context_snapshot_sha256'):
            message[key] = None
        context = contexts.get(message.get('native_id'))
        if not valid_snapshot or not isinstance(context, dict):
            continue
        turn_id = context.get('turn_id')
        if (not isinstance(turn_id, str) or not turn_id
                or not isinstance(message.get('payload_hash'), str)
                or context.get('payload_hash') != message['payload_hash']):
            continue
        message['turn_id'] = turn_id
        message['phase'] = context.get('phase') if isinstance(context.get('phase'), str) else None
        message['turn_status'] = context.get('turn_status') if isinstance(context.get('turn_status'), str) else None
        message['context_snapshot_sha256'] = snapshot
