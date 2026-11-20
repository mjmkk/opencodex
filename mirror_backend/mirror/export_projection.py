"""Restore accepted offline export current state without rewriting permanent facts."""
from psycopg.types.json import Json

PROJECTION_ID = 'export-projection'

def apply_projection(store, conn, tid, projection):
    if not store.ns.startswith('chatgpt-export:'):
        raise ValueError('export namespace required')
    selected = projection['messages']
    ids = [entry['native_id'] for entry in selected]
    if len(ids) != len(set(ids)):
        raise ValueError('duplicate projected message')
    facts = []
    for category, entries in [('message', selected), ('item', projection.get('items', [])),
                              ('attachment', projection.get('attachments', []))]:
        for entry in entries:
            fact = store.read_fact(conn,entry['fact_seq'])
            if not fact or (fact['account_namespace'],fact['thread_id'],fact['category'],fact['native_id'])!=(store.ns,tid,category,entry['native_id']):
                raise ValueError('projection fact missing or wrong identity')
            facts.append((entry, fact))
    for table in ('messages', 'message_order', 'attachments'):
        conn.execute(f'DELETE FROM {table} WHERE account_namespace=%s AND thread_id=%s', (store.ns, tid))
    # Preserve observation/association/projection controls, but rebuild all source nodes.
    conn.execute('''DELETE FROM thread_items WHERE account_namespace=%s AND thread_id=%s
        AND native_id<>%s AND native_id NOT LIKE 'export-observation:%%'
        AND native_id NOT LIKE 'export-association:%%' ''', (store.ns, tid, PROJECTION_ID))
    for entry, fact in facts:
        store.fact(conn, tid, fact['category'], entry['native_id'], fact['raw_payload'], replay=fact,
                   position=entry.get('sort_key') if fact['category']=='message' else None)
        if fact['category']=='attachment':
            conn.execute('''UPDATE attachments SET state=%s,blob=%s,last_error=%s
                WHERE account_namespace=%s AND thread_id=%s AND native_id=%s''',
                (entry['state'],Json(entry['blob']) if entry.get('blob') else None,
                 entry.get('last_error'),store.ns,tid,entry['native_id']))
    metadata = projection['metadata']
    attachment_states = [r['state'] for r in projection.get('attachments', [])]
    coverage = 'none' if not attachment_states else 'complete' if all(s=='complete' for s in attachment_states) else 'partial'
    conn.execute('''UPDATE threads SET metadata=%s,kind=%s,upstream_state=%s,
        content_coverage='partial',attachment_coverage=%s,coverage_detail=%s
        WHERE account_namespace=%s AND thread_id=%s''',
        (Json(metadata),metadata.get('kind','chatgpt'),'archived' if metadata.get('archived') else 'reachable',
         coverage,Json(projection.get('coverage_detail', {})),store.ns,tid))

def reindex_projections(store, conn):
    rows = conn.execute('''SELECT r.seq,r.thread_id FROM thread_items i JOIN raw_facts r ON r.seq=i.fact_seq
        WHERE i.account_namespace=%s AND i.native_id=%s''', (store.ns, PROJECTION_ID)).fetchall()
    for row in rows:
        apply_projection(store, conn, row['thread_id'], store.read_fact(conn,row['seq'])['raw_payload'])
