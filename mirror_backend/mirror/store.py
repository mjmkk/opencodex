import json
import os
import uuid
from .blob import BlobStore
from .codec import PayloadCodec, payload_columns, decoded_dict_row
from pathlib import Path
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Json as Jsonb
from .parser import hashed, item_type, text_content

class Store:
    def __init__(self, dsn, namespace, blobs=None):
        if not namespace or len(namespace) > 200:
            raise ValueError('Explicit stable account namespace required')
        self.dsn, self.ns = dsn, namespace
        self.blobs = blobs or BlobStore(os.environ.get("MIRROR_BLOBS", "/home/spirit/.local/state/thread-mirror/objects"))
        self.codec = PayloadCodec(self.blobs)

    def connect(self):
        conn=psycopg.connect(self.dsn, row_factory=decoded_dict_row)
        conn._mirror_codec=self.codec
        return conn

    def init(self):
        with self.connect() as conn:
            conn.execute(Path(__file__).with_name('schema.sql').read_text())
            conn.execute('INSERT INTO sync_state(account_namespace) VALUES (%s) ON CONFLICT DO NOTHING', (self.ns,))

    def ensure_thread(self, conn, tid):
        conn.execute('INSERT INTO threads(account_namespace,thread_id) VALUES (%s,%s) ON CONFLICT DO NOTHING', (self.ns, tid))

    def enqueue(self, conn, tid, kind='thread', item_id=''):
        conn.execute('''INSERT INTO queue(account_namespace,thread_id,kind,item_id) VALUES (%s,%s,%s,%s)
            ON CONFLICT(account_namespace,thread_id,kind,item_id) DO UPDATE SET
            state=CASE WHEN queue.state='running' THEN 'running' ELSE 'pending' END,
            requested=CASE WHEN queue.state='running' THEN true ELSE false END,
            attempts=CASE WHEN queue.state='running' THEN queue.attempts ELSE 0 END,
            available_at=now()''', (self.ns, tid, kind, item_id))

    def enqueue_thread_request(self, conn, tid):
        """Coalesce a body refresh without rearming an immutable request UUID."""
        self.ensure_thread(conn, tid)
        # Serialize consumer requests for this exact namespace/target. A running
        # request keeps its receipt slots; at most one runnable successor is
        # added by this path, including while that request is still running.
        conn.execute('''SELECT thread_id FROM threads
            WHERE account_namespace=%s AND thread_id=%s FOR UPDATE''', (self.ns, tid))
        queued = conn.execute('''SELECT item_id FROM queue
            WHERE account_namespace=%s AND thread_id=%s AND kind='thread_refresh'
              AND state IN ('pending','error') AND attempts<3
            ORDER BY available_at,id FOR UPDATE LIMIT 1''', (self.ns, tid)).fetchone()
        if queued:
            # A future available_at is an existing retry backoff, not permission
            # for a poll to reset attempts or bring the request forward.
            return queued['item_id']
        request_id = str(uuid.uuid4())
        conn.execute('''INSERT INTO queue(account_namespace,thread_id,kind,item_id)
            VALUES (%s,%s,'thread_refresh',%s)''', (self.ns, tid, request_id))
        return request_id

    def has_eligible_interactive(self, conn, ignore_running_id=None):
        # A normal job checks this only between pages. Ignore exactly that job,
        # so its own same-target running row cannot hide the queued demand.
        return conn.execute('''SELECT 1 FROM queue q WHERE q.account_namespace=%s
            AND q.kind IN ('thread_refresh','thread_request')
            AND q.state IN ('pending','error') AND q.available_at<=now() AND q.attempts<3
            AND NOT EXISTS (SELECT 1 FROM queue running
                WHERE running.account_namespace=q.account_namespace
                  AND running.thread_id=q.thread_id AND running.state='running'
                  AND running.id IS DISTINCT FROM %s::bigint)
            AND NOT EXISTS (SELECT 1 FROM queue cooling
                WHERE cooling.account_namespace=q.account_namespace
                  AND cooling.thread_id=q.thread_id
                  AND cooling.kind IN ('thread','thread_request','thread_refresh')
                  AND cooling.state IN ('pending','error')
                  AND cooling.last_error IS NOT NULL AND cooling.available_at>now())
            LIMIT 1''', (self.ns, ignore_running_id)).fetchone() is not None

    def metadata(self, conn, tid, metadata, discovery=False):
        self.ensure_thread(conn, tid)
        old = conn.execute('SELECT * FROM threads WHERE account_namespace=%s AND thread_id=%s FOR UPDATE', (self.ns,tid)).fetchone()
        metadata=dict(metadata)
        if isinstance(metadata.get('status'),dict):
            metadata['status']=metadata['status'].get('type','unknown')
        merged = {**old['metadata'], **metadata}
        version = hashed({k:metadata.get(k) for k in ('updatedAt','status','pinned','pinnedIndex','archived') if k in metadata})
        # read_thread and list_threads use different status shapes; only discovery drives version comparison.
        self.fact(conn, tid, 'metadata', tid, merged)
        state = 'deleted' if merged.get('deleted') is True else 'archived' if merged.get('archived') is True else old['upstream_state']
        if (metadata.get('deleted') is False and state=='deleted') or (metadata.get('archived') is False and state=='archived'):
            state='reachable'
        conn.execute('''UPDATE threads SET metadata=%s,kind=COALESCE(%s,kind),host_id=COALESCE(%s,host_id),
            last_seen_at=now(),upstream_state=%s WHERE account_namespace=%s AND thread_id=%s''',
            (Jsonb(merged), merged.get('kind'),merged.get('hostId'),state,self.ns,tid))
        if discovery:
            conn.execute('UPDATE threads SET observed_version=%s WHERE account_namespace=%s AND thread_id=%s', (version,self.ns,tid))
            if old['observed_version'] != version or old['last_synced_at'] is None or old['synced_version'] != version:
                self.enqueue(conn,tid)
        return merged

    def fact(self, conn, tid, category, ident, payload, replay=None, position=None, source_observed_at=None):
        digest = hashed(payload)
        if replay is None:
            old = conn.execute('''SELECT seq,payload_hash,observed_at FROM raw_facts WHERE account_namespace=%s AND thread_id=%s
                AND category=%s AND native_id=%s ORDER BY observed_at DESC,seq DESC LIMIT 1''', (self.ns,tid,category,ident)).fetchone()
            if old and old['payload_hash'] == digest:
                fact = old
            else:
                raw=json.dumps(payload).encode('utf-8')
                encoded=self.codec.encode(raw)
                fact=conn.execute("""INSERT INTO raw_facts(account_namespace,thread_id,category,native_id,payload_hash,observed_at,
                    format_version,payload_codec,original_length,original_bytes_sha256,encoded_length,encoded_payload)
                    VALUES (%s,%s,%s,%s,%s,COALESCE(%s::timestamptz,now()),%s,%s,%s,%s,%s,%s) RETURNING *""",
                    (self.ns,tid,category,ident,digest,source_observed_at,*encoded.values())).fetchone()
        else:
            fact = replay
        base = (fact['seq'], self.ns,tid)
        def write_derived(table, columns, values, conflict):
            # Connections are short-lived; schema migration runs with the daemon stopped.
            legacy = getattr(conn, '_mirror_legacy_raw_tables', None)
            if legacy is None:
                names = ('messages', 'message_revisions', 'thread_items',
                         'thread_item_revisions', 'thread_metadata_revisions')
                legacy = {r['name'] for r in conn.execute(
                    "SELECT name FROM unnest(%s::text[]) AS t(name) WHERE EXISTS "
                    "(SELECT 1 FROM pg_attribute a WHERE a.attrelid=to_regclass(name) "
                    "AND a.attname='raw_payload' AND a.attnum>0 AND NOT a.attisdropped)",
                    (list(names),)).fetchall()}
                conn._mirror_legacy_raw_tables = legacy
            if table in legacy:
                columns += ('raw_payload',)
                values += (Jsonb(payload),)
                if 'DO UPDATE SET' in conflict:
                    conflict += ',raw_payload=excluded.raw_payload'
            placeholders = ','.join(['%s'] * len(columns))
            conn.execute(f"INSERT INTO {table} ({','.join(columns)}) VALUES ({placeholders}) {conflict}", values)

        if category == 'metadata':
            write_derived('thread_metadata_revisions',
                ('fact_seq','account_namespace','thread_id','payload_hash','observed_at'),
                (*base,digest,fact['observed_at']), 'ON CONFLICT DO NOTHING')
        elif category == 'message':
            if position is not None:
                conn.execute('INSERT INTO message_order VALUES (%s,%s,%s,%s) ON CONFLICT(account_namespace,thread_id,native_id) DO UPDATE SET sort_key=excluded.sort_key',(self.ns,tid,ident,position))
            role = 'user' if payload.get('type') == 'userMessage' else 'assistant'
            body = text_content(payload)
            write_derived('message_revisions',
                ('fact_seq','account_namespace','thread_id','native_id','role','text_content','payload_hash','observed_at'),
                (*base,ident,role,Jsonb(body),digest,fact['observed_at']), 'ON CONFLICT DO NOTHING')
            write_derived('messages',
                ('account_namespace','thread_id','native_id','role','text_content','payload_hash','fact_seq','first_fact_seq'),
                (self.ns,tid,ident,role,Jsonb(body),digest,fact['seq'],fact['seq']),
                'ON CONFLICT(account_namespace,thread_id,native_id) DO UPDATE SET '
                'role=excluded.role,text_content=excluded.text_content,payload_hash=excluded.payload_hash,'
                'fact_seq=excluded.fact_seq,last_seen_at=now()')
        elif category == 'item':
            typ = item_type(payload)
            write_derived('thread_item_revisions',
                ('fact_seq','account_namespace','thread_id','native_id','type','payload_hash','observed_at'),
                (*base,ident,typ,digest,fact['observed_at']), 'ON CONFLICT DO NOTHING')
            write_derived('thread_items',
                ('account_namespace','thread_id','native_id','type','payload_hash','fact_seq'),
                (self.ns,tid,ident,typ,digest,fact['seq']),
                'ON CONFLICT(account_namespace,thread_id,native_id) DO UPDATE SET '
                'type=excluded.type,payload_hash=excluded.payload_hash,'
                'fact_seq=excluded.fact_seq,last_seen_at=now()')
        elif category == 'attachment':
            blob_row=conn.execute('SELECT blob FROM attachment_blobs WHERE account_namespace=%s AND thread_id=%s AND native_id=%s ORDER BY observed_at DESC LIMIT 1',(self.ns,tid,ident)).fetchone()
            conn.execute('''INSERT INTO attachments(account_namespace,thread_id,native_id,filename,mime,metadata_fact_seq,state,blob)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(account_namespace,thread_id,native_id) DO UPDATE SET
                filename=excluded.filename,mime=excluded.mime,upstream_metadata=NULL,metadata_fact_seq=excluded.metadata_fact_seq''',
                (self.ns,tid,ident,payload.get('name') or payload.get('filename'),payload.get('mimeType') or payload.get('mime'),
                 fact['seq'],'complete' if blob_row else 'pending',Jsonb(blob_row['blob']) if blob_row else None))
        return fact

    def read_fact(self, conn, seq):
        row=conn.execute('SELECT *,raw_payload::text AS raw_text FROM raw_facts WHERE seq=%s',(seq,)).fetchone()
        if row:row['raw_payload']=self.codec.payload(row)
        return row

    def attachment_metadata(self, conn, row):
        if row['upstream_metadata'] is not None:return row['upstream_metadata']
        if row['metadata_fact_seq'] is None:raise ValueError('attachment_metadata_missing')
        fact=self.read_fact(conn,row['metadata_fact_seq'])
        if not fact or (fact['account_namespace'],fact['thread_id'],fact['native_id'],fact['category'])!=(row['account_namespace'],row['thread_id'],row['native_id'],'attachment'):
            raise ValueError('attachment_fact_identity_mismatch')
        return fact['raw_payload']

    def error(self, kind, detail, tid=None):
        with self.connect() as conn:
            conn.execute('INSERT INTO sync_errors(account_namespace,thread_id,kind,detail) VALUES (%s,%s,%s,%s)', (self.ns,tid,kind,detail))
            if tid:
                conn.execute("UPDATE threads SET upstream_state=CASE WHEN upstream_state IN ('deleted','archived') THEN upstream_state ELSE %s END,last_checked_at=now() WHERE account_namespace=%s AND thread_id=%s", (kind,self.ns,tid))

    def get_thread(self, tid, body=False):
        with self.connect() as conn:
            row = conn.execute('''SELECT account_namespace,thread_id,kind,host_id,metadata,last_seen_at,last_checked_at,
                last_synced_at,content_coverage,attachment_coverage,coverage_detail,upstream_state
                FROM threads WHERE account_namespace=%s AND thread_id=%s''', (self.ns,tid)).fetchone()
            if row and body:
                row['messages'] = conn.execute('''SELECT m.native_id,m.role,m.text_content,m.last_seen_at,m.payload_hash FROM messages m LEFT JOIN message_order o
                    ON (m.account_namespace,m.thread_id,m.native_id)=(o.account_namespace,o.thread_id,o.native_id)
                    WHERE m.account_namespace=%s AND m.thread_id=%s ORDER BY o.sort_key NULLS LAST,m.first_fact_seq''', (self.ns,tid)).fetchall()
                from .message_context import attach_message_context
                attach_message_context(row['messages'], row.get('coverage_detail'))
                row['items'] = conn.execute('''SELECT native_id,type,last_seen_at FROM thread_items
                    WHERE account_namespace=%s AND thread_id=%s ORDER BY fact_seq''', (self.ns,tid)).fetchall()
                row['attachments'] = conn.execute('''SELECT native_id,filename,mime,state,blob,last_error FROM attachments
                    WHERE account_namespace=%s AND thread_id=%s''', (self.ns,tid)).fetchall()
            return row

    def reindex(self):
        # Raw facts are append-only, not disposable indexes. Preserve raw and all other accounts.
        with self.connect() as conn:
            for table in ('messages','message_revisions','thread_items','thread_item_revisions','thread_metadata_revisions'):
                conn.execute(f'DELETE FROM {table} WHERE account_namespace=%s', (self.ns,))
            with conn.cursor(name='mirror_reindex_facts') as facts:
                facts.execute('SELECT *,raw_payload::text AS raw_text FROM raw_facts WHERE account_namespace=%s ORDER BY observed_at,seq', (self.ns,))
                count = 0
                for fact in facts:
                    count += 1
                    fact['raw_payload']=self.codec.payload(fact)
                    self.ensure_thread(conn,fact['thread_id'])
                    self.fact(conn,fact['thread_id'],fact['category'],fact['native_id'],fact['raw_payload'],replay=fact)
                    if fact['category'] == 'metadata':
                        conn.execute('UPDATE threads SET metadata=%s,kind=%s,host_id=%s WHERE account_namespace=%s AND thread_id=%s',
                                     (Jsonb(fact['raw_payload']),fact['raw_payload'].get('kind'),fact['raw_payload'].get('hostId'),self.ns,fact['thread_id']))
            if self.ns.startswith('chatgpt-export:'):
                from .export_projection import reindex_projections
                reindex_projections(self, conn)
        return count

    def recover_queue(self):
        # Caller holds account advisory lock for its process lifetime.
        with self.connect() as conn:
            conn.execute("UPDATE queue SET state='pending',available_at=now(),requested=false,attempts=GREATEST(0,attempts-1) WHERE account_namespace=%s AND state='running'", (self.ns,))
            conn.execute('UPDATE sync_state SET scan_running=false,scan_requested=false WHERE account_namespace=%s', (self.ns,))

    def claim(self):
        with self.connect() as conn:
            # Interactive reads precede the background backlog, but never bypass
            # retry eligibility or preempt a running job. This running check
            # avoids known same-target waits; concurrent claims still rely on
            # the existing daemon target mutex for source-read serialization.
            # A fresh UUID must not bypass an existing source failure's backoff,
            # including an exhausted request. Attachment errors do not gate it.
            row = conn.execute('''SELECT q.* FROM queue q WHERE q.account_namespace=%s
                AND q.state IN ('pending','error') AND q.available_at<=now() AND q.attempts<3
                AND NOT EXISTS (SELECT 1 FROM queue running
                    WHERE running.account_namespace=q.account_namespace
                      AND running.thread_id=q.thread_id AND running.state='running')
                AND (q.kind NOT IN ('thread_request','thread_refresh') OR NOT EXISTS (
                    SELECT 1 FROM queue cooling
                    WHERE cooling.account_namespace=q.account_namespace
                      AND cooling.thread_id=q.thread_id
                      AND cooling.kind IN ('thread','thread_request','thread_refresh')
                      AND cooling.state IN ('pending','error')
                      AND cooling.last_error IS NOT NULL AND cooling.available_at>now()))
                ORDER BY CASE q.kind WHEN 'thread_refresh' THEN 0 WHEN 'thread_request' THEN 1 ELSE 2 END,q.available_at,q.id
                FOR UPDATE OF q SKIP LOCKED LIMIT 1''', (self.ns,)).fetchone()
            if row:
                conn.execute("UPDATE queue SET state='running',attempts=attempts+1,started_at=now() WHERE id=%s", (row['id'],))
            return row

    def finish(self, job, error=None, receipt_record=None, retry_after_ms=None, preserve_retry_budget=False):
        if (retry_after_ms is not None and (type(retry_after_ms) is not int or not 0<=retry_after_ms<=9007199254740991)
                or type(preserve_retry_budget) is not bool or preserve_retry_budget and retry_after_ms is None):
            raise ValueError('invalid_native_history_backoff')
        with self.connect() as conn:
            if receipt_record is not None:
                # Refunded history waits may reuse the same attempt number. Their
                # distinct immutable receipts must not collide or replace history.
                suffix=str(int(job['attempts'])+1)
                if preserve_retry_budget:
                    # Place a refunded wait before the next real attempt, so
                    # the existing ordered receipt reader ends on final success.
                    suffix=str(int(job['attempts']))+':deferred:'+receipt_record['observed_at']+':'+receipt_record['sha256']
                wire=receipt_record['receipt']['attempt'].get('snapshot')
                if wire is not None:
                    conn.execute('INSERT INTO snapshots(account_namespace,thread_id,slot,raw_blob) VALUES (%s,%s,%s,%s)',(self.ns,job['thread_id'],'request-wire:'+job['item_id']+':'+suffix,Jsonb(wire)))
                conn.execute('INSERT INTO snapshots(account_namespace,thread_id,slot,raw_blob) VALUES (%s,%s,%s,%s)',(self.ns,job['thread_id'],'request:'+job['item_id']+':'+suffix,Jsonb(receipt_record)))
            if retry_after_ms is not None:
                conn.execute('''UPDATE queue SET state=%s,
                    attempts=GREATEST(0,attempts-%s),requested=false,last_error=%s,
                    available_at=GREATEST(available_at,now()+make_interval(secs=>%s::double precision/1000))
                    WHERE id=%s AND account_namespace=%s''',
                    ('pending' if preserve_retry_budget else 'error',1 if preserve_retry_budget else 0,error,
                     retry_after_ms,job['id'],self.ns))
                return
            conn.execute('''UPDATE queue SET state=CASE WHEN requested THEN 'pending' WHEN %s::text IS NULL THEN 'done' ELSE 'error' END,
                attempts=CASE WHEN requested THEN 0 ELSE attempts END,requested=false,last_error=%s,
                available_at=now()+interval '30 seconds' WHERE id=%s AND account_namespace=%s''', (error,error,job['id'],self.ns))

    def refresh_attachment_coverage(self, conn, tid):
        rows = conn.execute('SELECT state FROM attachments WHERE account_namespace=%s AND thread_id=%s', (self.ns,tid)).fetchall()
        coverage = 'partial' if any(r['state'] in ('error','upstream_missing') for r in rows) else 'unknown'
        conn.execute('UPDATE threads SET attachment_coverage=%s WHERE account_namespace=%s AND thread_id=%s', (coverage,self.ns,tid))
