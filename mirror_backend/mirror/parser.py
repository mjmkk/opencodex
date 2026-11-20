"""Parse visible native responses, retaining unknown items and honest coverage."""
import hashlib
import json

KNOWN_ITEMS = {'commandExecution', 'fileChange', 'mcpToolCall', 'webSearch', 'imageView',
               'reasoning', 'plan', 'approval', 'attachment', 'execution', 'toolCall',
               'toolResult', 'collabAgentToolCall', 'contextCompaction', 'nativeMessageMetadata'}

def canonical(payload):
    return json.dumps(payload, sort_keys=True, ensure_ascii=False, separators=(',', ':'))

def hashed(payload):
    return hashlib.sha256(canonical(payload).encode('utf-8','surrogatepass')).hexdigest()

def unwrap(response):
    result = response.get('result', response)
    if result.get('isError'):
        raise RuntimeError('upstream_tool_error')
    if 'content' in result and isinstance(result['content'], list):
        for content in result['content']:
            if content.get('type') == 'text':
                try:
                    return json.loads(content['text'])
                except (ValueError, KeyError):
                    continue
        raise RuntimeError('unrecognized_tool_response')
    return result

def text_content(item):
    if isinstance(item.get('text'), str):
        return item['text']
    return '\n'.join(c.get('text', '') for c in item.get('content', []) if isinstance(c, dict) and isinstance(c.get('text'), str))

def identity(thread_id, item, position):
    native = item.get('id') or item.get('node_id')
    return str(native) if native else 'fp:' + hashed([thread_id, item.get('type'), item.get('createdAt', position), item])

def attachment_identity(thread_id, attachment, ordinal):
    native=attachment.get('id') or attachment.get('fileId') or attachment.get('file_id')
    if native:
        return str(native)
    # Official projection hides native file IDs and changes materialized paths on every read.
    # Stable visible filename + same-name ordinal is best-effort; preserve this identity limitation.
    return 'fp:' + hashed([thread_id,'attachment',attachment.get('name') or attachment.get('filename'),
                            attachment.get('mimeType'),attachment.get('size'),ordinal])

def parse_pages(thread_id, pages, positions=None):
    positions = positions if positions is not None else {}
    turn_ordinal=0
    facts = []
    attachments = {}
    limitations = []
    metadata = {}
    has_explicit_end = False
    name_counts = {}
    for page_index, payload in enumerate(reversed(pages)):
        metadata.update(payload.get('thread', {}))
        page = payload.get('page', {})
        if page.get('hasMore') is False:
            has_explicit_end = True
        elif 'hasMore' not in page:
            limitations.append('pagination_end_unknown')
        for flag in ('truncated', 'native_messages_truncated'):
            if payload.get(flag):
                limitations.append(flag)
        turns=payload.get('turns', [])
        if page.get('order') == 'newest_first':
            turns=list(reversed(turns))
        for tpos, turn in enumerate(turns):
            turn_ordinal+=1
            for ipos, item in enumerate(turn.get('items') or []):
                if not isinstance(item, dict):
                    limitations.append('upstream_null_or_nonobject_item')
                    item = {'type':'upstreamNull', 'value':item}
                ident = identity(thread_id, item, [turn.get('id', tpos), ipos])
                if item.get('type') in ('userMessage', 'agentMessage'):
                    category = 'message'
                else:
                    category = 'item'
                facts.append((category, ident, item))
                stamp=turn.get('startedAt')
                if isinstance(stamp,(int,float)):
                    positions[ident]=f'{stamp:024.6f}/{ipos:09d}'
                else:
                    limitations.append('native_order_timestamp_unknown')
                    positions[ident]=f'fallback/{turn_ordinal:012d}/{ipos:09d}'
                if any(item.get(key) for key in ('truncated', 'textTruncated', 'outputTruncated', 'contentTruncated')):
                    limitations.append('item_truncated')
                # Only native typed attachment references, never links from ordinary message text.
                embedded=[]
                for content in item.get('content',[]):
                    if isinstance(content,dict) and content.get('type') in ('localImage','image','localAudio','audio'):
                        embedded.append({**content,'name':content.get('name') or str(content.get('path') or content.get('url') or ident).rsplit('/',1)[-1]})
                if item.get('type')=='imageView' and item.get('path'):
                    embedded.append({'name':str(item['path']).rsplit('/',1)[-1],'path':item['path']})
                for attachment in list(item.get('attachments', []))+embedded:
                    if isinstance(attachment, dict):
                        key=attachment.get('name') or attachment.get('filename')
                        ordinal=name_counts.get(key,0);name_counts[key]=ordinal+1
                        attachments[attachment_identity(thread_id, attachment, ordinal)] = attachment
        for item in payload.get('native_messages', []):
            facts.append(('item', 'native-metadata:' + identity(thread_id, item, page_index),
                          {**item, 'type': 'nativeMessageMetadata'}))
        for pos, attachment in enumerate(payload.get('attachments', [])):
            if isinstance(attachment, dict):
                key=attachment.get('name') or attachment.get('filename')
                ordinal=name_counts.get(key,0);name_counts[key]=ordinal+1
                attachments[attachment_identity(thread_id, attachment, ordinal)] = attachment
    if not has_explicit_end:
        limitations.append('pagination_incomplete')
    return metadata, facts, attachments, sorted(set(limitations))

def item_type(item):
    typ = str(item.get('type', 'missing'))
    return typ if typ in KNOWN_ITEMS else 'unknown/' + typ
