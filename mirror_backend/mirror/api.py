"""Local consumer API. All network work is explicit and runs in the daemon queue."""
from psycopg.types.json import Jsonb
from datetime import datetime
from mirror.sources import is_offline_source, source_format
from mirror.store import Store

class LocalMirror:
    def __init__(self,store):
        self.store=store
    def sync_thread(self,thread_id,request_id=None,wait_seconds=0):
        from .thread_ops import request_sync
        return request_sync(self.store,thread_id,request_id,wait_seconds)

    def export_thread(self,thread_id,output,**options):
        from .thread_export import export_thread
        return export_thread(self.store,thread_id,output,**options)

    def metadata(self,thread_id):
        return self.store.get_thread(thread_id)
    def index(self,limit=50):
        with self.store.connect() as conn:
            return conn.execute('''SELECT thread_id,kind,host_id,metadata,last_seen_at,last_synced_at,
                content_coverage,attachment_coverage,upstream_state FROM threads WHERE account_namespace=%s
                ORDER BY last_seen_at DESC NULLS LAST LIMIT %s''',(self.store.ns,max(1,min(int(limit),1000)))).fetchall()
    def registry(self,issue_id=None):
        with self.store.connect() as conn:
            return conn.execute('SELECT issue_id,source_updated_at,registry,observed_at FROM registry_observations WHERE account_namespace=%s AND (%s::text IS NULL OR issue_id=%s)',(self.store.ns,issue_id,issue_id)).fetchall()
    def body(self,thread_id,offline=False):
        row=self.store.get_thread(thread_id,body=True)
        if is_offline_source(self.store.ns):
            # Local backup provenance is not a verified upstream account identity.
            # Never enqueue a remote read under this offline-only namespace.
            if row is not None:
                row['refresh_available']=False
                row['refresh_unavailable_reason']='offline_backup_source'
            return row
        if not offline:
            with self.store.connect() as conn:
                # Body refreshes use one latest page; explicit CLI sync retains
                # its separate immutable full-history request semantics.
                self.store.enqueue_thread_request(conn,thread_id)
            row=row or {'thread_id':thread_id,'content_coverage':'unknown','attachment_coverage':'unknown'}
            row['refresh_requested']=True
        return row
    def backup_sources(self, source_format=None):
        """Discover offline imports without asserting online account identity."""
        if source_format not in (None, 'codex_backup', 'chatgpt_export'):
            raise ValueError('unknown_source_format')
        with self.store.connect() as conn:
            rows=conn.execute("""SELECT account_namespace,host_id,count(*) AS threads
                FROM threads WHERE account_namespace LIKE 'codex-backup:%%'
                   OR account_namespace LIKE 'chatgpt-export:%%'
                GROUP BY account_namespace,host_id ORDER BY account_namespace""").fetchall()
        from mirror.sources import source_format as classify
        return [dict(row,source_format=classify(row['account_namespace'])) for row in rows
                if classify(row['account_namespace']) is not None
                and (source_format is None or classify(row['account_namespace'])==source_format)]

    def item_detail(self, thread_id, native_id):
        """Explicit internal/audit access; not ordinary visible body content."""
        with self.store.connect() as conn:
            row=conn.execute("""SELECT i.native_id,i.type,i.payload_hash,i.fact_seq
                FROM thread_items i JOIN raw_facts r ON r.seq=i.fact_seq
                 AND r.account_namespace=i.account_namespace AND r.thread_id=i.thread_id
                 AND r.native_id=i.native_id AND r.payload_hash=i.payload_hash AND r.category='item'
                WHERE i.account_namespace=%s AND i.thread_id=%s AND i.native_id=%s""",
                (self.store.ns,thread_id,native_id)).fetchone()
        if row:
            with self.store.connect() as conn:row['raw_payload']=self.store.read_fact(conn,row['fact_seq'])['raw_payload']
        return dict(row,visibility='internal_explicit_read') if row else None

    def related_sources(self, thread_id):
        """Only current evidence-bearing associations, stored on the export side."""
        if is_offline_source(self.store.ns):
            return []
        with self.store.connect() as conn:
            rows=conn.execute("""SELECT i.account_namespace,i.thread_id,r.seq
                FROM thread_items i JOIN raw_facts r ON r.seq=i.fact_seq
                 AND r.account_namespace=i.account_namespace AND r.thread_id=i.thread_id
                 AND r.native_id=i.native_id AND r.payload_hash=i.payload_hash AND r.category='item'
                WHERE i.account_namespace LIKE 'chatgpt-export:%%'
                  AND i.thread_id=%s AND i.native_id=%s
                  AND i.type='unknown/chatgptExportAssociation'""",
                (thread_id,'export-association:'+self.store.ns)).fetchall()
        related=[]
        for row in rows:
            with self.store.connect() as conn:payload=self.store.read_fact(conn,row['seq'])['raw_payload']
            if (isinstance(payload,dict) and payload.get('type')=='chatgptExportAssociation'
                and payload.get('active') is True
                and payload.get('online_namespace')==self.store.ns
                and payload.get('online_thread_id')==thread_id
                and isinstance(payload.get('evidence'),dict) and payload['evidence']
                and source_format(row['account_namespace'])=='chatgpt_export'):
                related.append({'account_namespace':row['account_namespace'],
                                'thread_id':row['thread_id'],'source_format':'chatgpt_export',
                                'association_evidence':payload['evidence']})
        return sorted(related,key=lambda row:row['account_namespace'])

    def export_snapshot(self, thread_id, export_namespace):
        """Read a linked historical snapshot; never merge into Online body."""
        if source_format(export_namespace)!='chatgpt_export':
            raise ValueError('export_namespace_required')
        if not any(row['account_namespace']==export_namespace for row in self.related_sources(thread_id)):
            raise ValueError('verified_active_association_required')
        return LocalMirror(Store(self.store.dsn,export_namespace)).body(thread_id,offline=True)

    def observe_registry(self,issue_id,updated_at,registry):
        """Call on an authenticated Registry hit/addition, NOT on a local index read."""
        stamp=datetime.fromisoformat(updated_at.replace('Z','+00:00'))
        if stamp.tzinfo is None:
            raise ValueError('registry_source_timezone_required')
        if set(registry)!={'master','workers','chatgpts'}:
            raise ValueError('invalid_registry_shape')
        with self.store.connect() as conn:
            observed=conn.execute('''INSERT INTO registry_observations(account_namespace,issue_id,source_updated_at,registry)
                VALUES (%s,%s,%s,%s) ON CONFLICT(account_namespace,issue_id) DO UPDATE SET
                source_updated_at=excluded.source_updated_at,registry=excluded.registry,observed_at=now()
                WHERE excluded.source_updated_at::timestamptz>=registry_observations.source_updated_at::timestamptz
                RETURNING issue_id''',
                (self.store.ns,issue_id,updated_at,Jsonb(registry))).fetchone()
            if not observed:
                return False
            for ref in [registry.get('master')]+registry['workers']+registry['chatgpts']:
                if not ref:
                    continue
                tid=ref['thread_id']
                self.store.ensure_thread(conn,tid)
                if ref.get('host_id'):
                    conn.execute('UPDATE threads SET host_id=%s WHERE account_namespace=%s AND thread_id=%s',(ref['host_id'],self.store.ns,tid))
                row=conn.execute('SELECT content_coverage FROM threads WHERE account_namespace=%s AND thread_id=%s',(self.store.ns,tid)).fetchone()
                if row['content_coverage']!='complete':
                    self.store.enqueue(conn,tid)
