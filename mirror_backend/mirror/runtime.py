import base64
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import selectors
import subprocess
import threading
import sys
import time
import urllib.error
import urllib.request
import psycopg
import zipfile
from psycopg.types.json import Json as Jsonb
from .blob import BlobStore, BlobError
from .parser import unwrap, parse_pages, hashed
from .store import Store

ROOT = Path(__file__).resolve().parent.parent
NODE = '/home/spirit/chatgpt-desktop/app/resources/cua_node/bin/node'
PROFILE = Path('/home/spirit/codex')
PROJECTION_LIMIT = 'official_read_thread_projects_items_and_caps_text_at_20000_chars'

class NativeHistoryDeferred(RuntimeError):
    """Safe shared-Gate metadata, independent of private upstream error text."""
    def __init__(self, metadata):
        expected={'code','category','retry_after_ms','rpc_attempted'}
        local=metadata.get('category')=='deferred' if type(metadata) is dict else False
        if (type(metadata) is not dict or set(metadata)!=expected
                or metadata['code']!=('native_history_deferred' if local else 'native_history_rate_limited')
                or metadata['category'] not in ('deferred','rate_limited')
                or type(metadata['retry_after_ms']) is not int or not 0<=metadata['retry_after_ms']<=9007199254740991
                or type(metadata['rpc_attempted']) is not bool or metadata['rpc_attempted']==local):
            raise ValueError('invalid_native_history_metadata')
        super().__init__(metadata['code'])
        self.retry_after_ms=metadata['retry_after_ms']
        self.rpc_attempted=metadata['rpc_attempted']

def account_namespace():
    # Read only the account identifier; no auth token enters logs, DB, or subprocess arguments.
    account = json.loads((PROFILE/'auth.json').read_text()).get('tokens',{}).get('account_id')
    if not account:
        raise RuntimeError('account_identity_unavailable')
    return 'openai:' + hashlib.sha256(account.encode()).hexdigest()[:24]

def error_kind(exc):
    if isinstance(exc,NativeHistoryDeferred):
        return 'rate_limited' if exc.rpc_attempted else 'native_history_deferred'
    value = str(exc).lower()
    if isinstance(exc,psycopg.Error):
        return 'database_error'
    if isinstance(exc,(TypeError,KeyError,ValueError)):
        return 'parser_error'
    if value in ('account_identity_changed','account_identity_unavailable','attachment_unavailable_host','attachment_original_unavailable'):
        return value
    if isinstance(exc, OSError) and exc.errno == 28:
        return 'disk_full'
    if isinstance(exc, BlobError):
        return str(exc)
    if '429' in value or 'too many requests' in value or 'pressure' in value:
        return 'rate_limited'
    if isinstance(exc, urllib.error.HTTPError) and exc.code in (404,410):
        return 'upstream_missing'
    if any(w in value for w in ('timeout','unavailable','pipe','transport','connection','exited')):
        return 'unreachable'
    return 'read_error'

def storage_failure_context(exc):
    # Metadata only: no exception text, arguments, locals, SQL, DSN or payloads.
    frames = []
    tb = exc.__traceback__
    visited = 0
    while tb is not None and visited < 64:
        code = tb.tb_frame.f_code
        frames.append({'module': Path(code.co_filename).name,
                       'function': code.co_name, 'line': tb.tb_lineno})
        frames = frames[-8:]
        tb = tb.tb_next
        visited += 1
    sqlstate = getattr(exc, 'sqlstate', None)
    if not (isinstance(sqlstate, str) and len(sqlstate) == 5 and sqlstate.isalnum()):
        sqlstate = None
    return {'exception_type': type(exc).__name__, 'sqlstate': sqlstate,
            'frames': frames, 'trace_truncated': tb is not None}

class Native:
    def __init__(self):
        self.local = threading.local()
        self.children = []
        self.lock = threading.Lock()
    def call_bounded(self, name, arguments, timeout_seconds):
        return self.call(name, arguments, timeout_seconds=timeout_seconds)

    def call(self, name, arguments, timeout_seconds=None):
        deadline = None if timeout_seconds is None else time.monotonic() + timeout_seconds
        process = getattr(self.local, 'process', None)
        if process is None or process.poll() is not None:
            process = subprocess.Popen([NODE, str(ROOT/'native/bridge.mjs')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            self.local.process = process
            with self.lock:
                self.children.append(process)
        request={'name':name,'arguments':arguments}
        if deadline is not None:
            remaining=deadline-time.monotonic()
            if remaining<=0:
                raise RuntimeError('transport_timeout_page_budget')
            request['timeoutMs']=max(1,int(remaining*1000))
        process.stdin.write(json.dumps(request).encode()+b'\n')
        process.stdin.flush()
        # Desktop aggregate discovery can take over three minutes. Only list_threads
        # gets a larger bounded wait; other reads retain their original timeout.
        wait_seconds=255 if name == 'list_threads' else 75
        if deadline is not None:
            wait_seconds=min(wait_seconds,max(0,deadline-time.monotonic()))
        response_deadline=time.monotonic()+wait_seconds
        chunks=[]
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining=response_deadline-time.monotonic()
                if remaining<=0 or not selector.select(remaining):
                    process.kill()
                    raise RuntimeError('transport_timeout')
                chunk=os.read(process.stdout.fileno(),1024*1024)
                if not chunk:
                    raise RuntimeError('transport_exited')
                chunks.append(chunk)
                if b'\n' in chunk:
                    line=b''.join(chunks)
                    if not line.endswith(b'\n') or line.count(b'\n')!=1:
                        process.kill()
                        raise RuntimeError('invalid_transport_frame')
                    break
        response = json.loads(line)
        raw = base64.b64decode(response['raw_base64']) if response.get('raw_base64') else None
        return raw, response
    def close(self):
        for process in self.children:
            try:
                process.stdin.close()
                process.wait(timeout=3)
            except (OSError,subprocess.TimeoutExpired):
                process.kill()

class Mirror:
    def __init__(self, store, blobs, native=None, max_concurrency=4, identity_check=True):
        self.store,self.blobs = store,blobs
        self.native = native or Native()
        self.max_concurrency = max(1,max_concurrency)
        self.concurrency = min(4,self.max_concurrency)
        self.stable = 0
        self.identity_check = identity_check
        self.stop = threading.Event()
        self.fatal_error = None
        self.owner = None
        self.thread_locks = {}
        self.thread_locks_guard = threading.Lock()

    def lock(self):
        self.owner = self.store.connect()
        self.owner.autocommit = True
        acquired = self.owner.execute('SELECT pg_try_advisory_lock(hashtextextended(%s,28)) AS held',(self.store.ns,)).fetchone()['held']
        if not acquired:
            self.owner.close()
            raise RuntimeError('mirror_already_running')
        # Restore the persisted backpressure limit before claiming new work.
        saved = self.owner.execute('SELECT concurrency FROM sync_state WHERE account_namespace=%s', (self.store.ns,)).fetchone()
        value = (saved or {}).get('concurrency')
        if type(value) is int:
            self.concurrency = max(1, min(self.max_concurrency, value))
        self.store.recover_queue()

    def check_identity(self):
        if self.identity_check and account_namespace()!=self.store.ns:
            raise RuntimeError('account_identity_changed')

    def payload(self, response):
        if 'native_history_gate_failure' in response:
            raise RuntimeError('native_history_gate_unavailable')
        if 'native_history_error' in response:
            raise NativeHistoryDeferred(response['native_history_error'])
        if response.get('error'):
            raise RuntimeError('transport_error: '+str(response['error'].get('message','')))
        result = response.get('result',{})
        if result.get('isError'):
            detail = ' '.join(c.get('text','') for c in result.get('content',[]) if c.get('type')=='text')
            raise RuntimeError(detail or 'upstream_tool_error')
        return unwrap(result)

    def request_scan(self):
        with self.store.connect() as conn:
            conn.execute('UPDATE sync_state SET scan_requested=true WHERE account_namespace=%s',(self.store.ns,))

    def start_scan(self):
        # Only connection establishment is recoverable here: no SQL was sent.
        # Do not catch SQL/commit errors or replay an ambiguous scan claim.
        try:
            opened = self.store.connect()
        except psycopg.errors.ConnectionTimeout:
            count = min(65, getattr(self, '_scan_connect_timeouts', 0) + 1)
            self._scan_connect_timeouts = count
            if count in (1, 2, 4, 8, 16, 32, 64):
                record = {'event': 'mirror_scan_connect_timeout', 'count': count,
                          'stage': 'connect', 'sql_started': False}
                try:
                    os.write(2, (json.dumps(record, separators=(',', ':')) + '\n').encode())
                except OSError:
                    pass
            return False
        with opened as conn:
            row=conn.execute('''UPDATE sync_state SET scan_running=true,scan_requested=false
                WHERE account_namespace=%s AND scan_running=false AND scan_requested=true RETURNING *''',(self.store.ns,)).fetchone()
        return bool(row)

    def scan(self):
        scan_id=None
        try:
            self.check_identity()
            raw,response=self.native.call('list_threads',{'limit':50})
            self.check_identity()
            if raw:
                blob=self.blobs.put(raw)
                with self.store.connect() as conn:
                    scan_id=conn.execute('INSERT INTO discovery_scans(account_namespace,raw_blob) VALUES (%s,%s) RETURNING id',(self.store.ns,Jsonb(blob))).fetchone()['id']
            payload=self.payload(response)
            entries={}
            for pinned,group in ((False,payload.get('threads',[])),(True,payload.get('pinnedThreads',[]))):
                for entry in group:
                    entries[entry['id']]={**entry,'pinned':pinned}
            with self.store.connect() as conn:
                for tid,entry in entries.items():
                    self.store.metadata(conn,tid,entry,discovery=True)
                conn.execute("UPDATE discovery_scans SET found_count=%s,status='parsed',detail=%s WHERE id=%s",(len(entries),Jsonb({k:payload.get(k) for k in ('schemaVersion','unavailableHosts','unavailableSources')}),scan_id))
                # Failed discovered work is eligible once per real scan, never hidden full-library reads.
                conn.execute("UPDATE queue SET attempts=0,available_at=now() WHERE account_namespace=%s AND state='error' AND kind NOT IN ('thread_request','thread_refresh')",(self.store.ns,))
            return len(entries)
        except Exception as exc:
            kind=error_kind(exc)
            self.store.error(kind,kind)
            if scan_id:
                with self.store.connect() as conn:
                    conn.execute("UPDATE discovery_scans SET status='error',detail=%s WHERE id=%s",(Jsonb({'error':kind}),scan_id))
            raise
        finally:
            with self.store.connect() as conn:
                conn.execute('UPDATE sync_state SET scan_running=false,last_scan_at=now() WHERE account_namespace=%s',(self.store.ns,))

    def snapshot(self, frames):
        # ZIP_STORED is only a framing container. Every upstream response remains byte-for-byte intact.
        buffer=io.BytesIO()
        manifest=[]
        with zipfile.ZipFile(buffer,'w',compression=zipfile.ZIP_STORED) as archive:
            for index,raw in enumerate(frames):
                name=f'{index:08}.jsonrpc'
                info=zipfile.ZipInfo(name,date_time=(1980,1,1,0,0,0))
                archive.writestr(info,raw)
                manifest.append({'name':name,'sha256':hashlib.sha256(raw).hexdigest(),'byte_length':len(raw)})
            archive.writestr(zipfile.ZipInfo('manifest.json',date_time=(1980,1,1,0,0,0)),json.dumps(manifest,separators=(',',':')))
        record=self.blobs.put(buffer.getvalue())
        record['observed_at']=datetime.now(timezone.utc).isoformat()
        record['format']='exact-jsonrpc-pages-v1'
        record['pages']=manifest
        return record

    def read_snapshot(self, record):
        data=self.blobs.read(record)
        pages=[]
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            for item in json.loads(archive.read('manifest.json')):
                raw=archive.read(item['name'])
                if len(raw)!=item['byte_length'] or hashlib.sha256(raw).hexdigest()!=item['sha256']:
                    raise BlobError('blob_corrupt')
                response=json.loads(raw)
                if not response.get('error') and not response.get('result',{}).get('isError'):
                    pages.append(unwrap(response))
        return pages

    def sync_thread(self, tid, receipt=None, latest_only=False, yield_for_interactive=False, background_job_id=None):
        with self.thread_locks_guard:
            lock=self.thread_locks.setdefault(tid,threading.RLock())
        with lock:
            return self._sync_thread(tid, receipt, latest_only, yield_for_interactive, background_job_id)

    def read_page(self, args, frames, diagnostics):
        """Retry only the exact opaque official RPC failure, at the same cursor.

        Smaller pages preserve the projection parameters. The shared deadline is
        local waiting only: it does not guarantee cancellation in Desktop.
        """
        deadline=time.monotonic()+75
        while True:
            if self.stop.is_set():
                raise RuntimeError('shutdown_interrupted')
            remaining=deadline-time.monotonic()
            if remaining<=0:
                raise RuntimeError('transport_timeout_page_budget')
            self.check_identity()
            bounded=getattr(self.native,'call_bounded',None)
            raw,response=(bounded('read_thread',args,remaining) if bounded else self.native.call('read_thread',args))
            if raw:
                frames.append(raw)
            self.check_identity()
            if time.monotonic()>deadline:
                raise RuntimeError('transport_timeout_page_budget')
            if 'native_history_error' in response or 'native_history_gate_failure' in response:
                return self.payload(response)
            error=response.get('error') or {}
            retryable=(error.get('code') == -32000 and
                       error.get('message') == 'MCP error -32000: Codex app tool request failed') or (
                       error.get('code') == -32000 and error.get('message') == 'Codex app tool request failed')
            if retryable and args['turnLimit']>1:
                old=args['turnLimit'];args['turnLimit']={10:5,5:2,2:1}[old]
                diagnostics.append({'reason':'opaque_app_tool_rpc_error','from':old,'to':args['turnLimit']})
                continue
            return self.payload(response)

    def _sync_thread(self, tid, receipt=None, latest_only=False, yield_for_interactive=False, background_job_id=None):
        receipt = receipt if receipt is not None else {}
        receipt['read_scope']='latest_page' if latest_only else 'full_history'
        yielded=False
        self.check_identity()
        with self.store.connect() as conn:
            row=conn.execute('SELECT * FROM threads WHERE account_namespace=%s AND thread_id=%s',(self.store.ns,tid)).fetchone()
        frames,pages,cursors=[],[],set()
        args={'threadId':tid,'turnLimit':10,'includeOutputs':True,'maxOutputCharsPerItem':20000}
        saved_limit=((row or {}).get('coverage_detail') or {}).get('reader_turn_limit')
        if saved_limit in (1,2,5,10):
            args['turnLimit']=saved_limit
        reductions=[]
        if row and row['host_id']:
            args['hostId']=row['host_id']
        failure=None
        try:
            while True:
                if self.stop.is_set():
                    raise RuntimeError('shutdown_interrupted')
                receipt['last_cursor']=args.get('cursor')
                payload=self.read_page(args,frames,reductions)
                pages.append(payload)
                page=payload.get('page',{})
                receipt.update(pages=len(pages),reader_eof=page.get('hasMore') is False,next_cursor=page.get('nextCursor'),reader_turn_limit=args['turnLimit'],reader_page_reductions=list(reductions))
                if page.get('hasMore') is not True:
                    break
                if latest_only:
                    break
                if yield_for_interactive:
                    with self.store.connect() as conn:
                        demand=self.store.has_eligible_interactive(conn,ignore_running_id=background_job_id)
                    if demand:
                        yielded=True
                        receipt['yielded_for_interactive']=True
                        break
                cursor=page.get('nextCursor')
                if not cursor or cursor in cursors:
                    raise RuntimeError('invalid_pagination_cursor')
                cursors.add(cursor)
                args['cursor']=cursor
        except Exception as exc:
            failure=exc
        if not frames:
            raise failure or RuntimeError('empty_transport_response')
        record=self.snapshot(frames)
        receipt['snapshot']=record
        completed=bool(pages) and pages[-1].get('page',{}).get('hasMore') is False and failure is None
        # Commit raw catalog before parsing so parser/schema failures remain offline-recoverable.
        with self.store.connect() as conn:
            # Keep earlier partial evidence reachable even when the next read fails.
            prior=(row or {}).get('latest_attempt_raw')
            if prior:
                conn.execute('INSERT INTO snapshots(account_namespace,thread_id,slot,raw_blob) VALUES (%s,%s,%s,%s) ON CONFLICT DO NOTHING',(self.store.ns,tid,'attempt-history:'+prior['sha256'],Jsonb(prior)))
            conn.execute('INSERT INTO snapshots(account_namespace,thread_id,slot,raw_blob) VALUES (%s,%s,%s,%s) ON CONFLICT(account_namespace,thread_id,slot) DO UPDATE SET raw_blob=excluded.raw_blob',(self.store.ns,tid,'complete' if completed else 'attempt',Jsonb(record)))
        # Raw snapshot and its catalog are committed; parsing uses decoded pages.
        frames.clear()
        positions={}
        metadata,facts,attachments,limits=parse_pages(tid,pages,positions)
        limits.append(PROJECTION_LIMIT)
        if failure:
            limits.append(error_kind(failure))
        completed=bool(pages) and pages[-1].get('page',{}).get('hasMore') is False and failure is None
        with self.store.connect() as conn:
            self.store.metadata(conn,tid,metadata)
            # Oldest pages first, native positions within a turn are preserved.
            for category,ident,payload in facts:
                self.store.fact(conn,tid,category,ident,payload,position=positions.get(ident))
            for ident,attachment in attachments.items():
                old=conn.execute('SELECT * FROM attachments WHERE account_namespace=%s AND thread_id=%s AND native_id=%s',(self.store.ns,tid,ident)).fetchone()
                self.store.fact(conn,tid,'attachment',ident,attachment)
                conn.execute('UPDATE attachments SET observed_at=now() WHERE account_namespace=%s AND thread_id=%s AND native_id=%s',(self.store.ns,tid,ident))
                if old:old['upstream_metadata']=self.store.attachment_metadata(conn,old)
                if not old or (old['state']!='complete' and not old['refresh_used']) or (old['state']=='complete' and old['upstream_metadata']!=attachment):
                    self.store.enqueue(conn,tid,'attachment',ident)
            detail={'limitations':sorted(set(limits)),'pages':len(pages),'pagination_complete':completed,'attachment_discovery':'upstream_latest_10_and_silent_failures_possible','reader_turn_limit':args['turnLimit'],'reader_page_budget_seconds':75,'reader_page_reductions':reductions}
            detail['read_scope']=receipt['read_scope']
            detail['yielded_for_interactive']=yielded
            from .message_context import project_message_context
            detail['message_context'] = project_message_context(pages)
            detail['message_context_snapshot_sha256'] = record['sha256']
            old_raw=row.get('latest_raw') if row else None
            old_attempt=row.get('latest_attempt_raw') if row else None
            if completed:
                conn.execute('''UPDATE threads SET latest_raw=%s,latest_attempt_raw=NULL,last_checked_at=now(),last_synced_at=now(),
                    content_coverage='partial',attachment_coverage='unknown',coverage_detail=%s,upstream_state=CASE WHEN upstream_state IN ('archived','deleted') THEN upstream_state ELSE 'reachable' END,synced_version=%s
                    WHERE account_namespace=%s AND thread_id=%s''', (Jsonb(record),Jsonb(detail),row.get('observed_version') if row else None,self.store.ns,tid))
            else:
                conn.execute('''UPDATE threads SET latest_attempt_raw=%s,last_checked_at=now(),content_coverage='partial',
                    attachment_coverage='unknown',coverage_detail=%s WHERE account_namespace=%s AND thread_id=%s''',
                    (Jsonb(record),Jsonb(detail),self.store.ns,tid))
            self.store.refresh_attachment_coverage(conn,tid)
            slot='complete' if completed else 'attempt'
            conn.execute('INSERT INTO snapshots(account_namespace,thread_id,slot,raw_blob) VALUES (%s,%s,%s,%s) ON CONFLICT(account_namespace,thread_id,slot) DO UPDATE SET raw_blob=excluded.raw_blob',(self.store.ns,tid,slot,Jsonb(record)))
            if completed:
                conn.execute("DELETE FROM snapshots WHERE account_namespace=%s AND thread_id=%s AND slot='attempt'",(self.store.ns,tid))
            if yielded:
                # Only ordinary background jobs use requested/reset semantics.
                # Publish this page and its requeue request in one transaction.
                self.store.enqueue(conn,tid)
        # Only obsolete whole-thread snapshots are replaced; never collect message/item or attachment history.
        for obsolete in ([old_raw,old_attempt] if completed else [old_attempt]):
            self.replace_obsolete_snapshot(obsolete,record)
        if failure:
            raise failure
        return {'pages':len(pages),'facts':len(facts),'attachments':len(attachments),'content_coverage':'partial'}

    def reparse(self):
        with self.store.connect() as conn:
            snapshots=conn.execute("SELECT * FROM snapshots WHERE account_namespace=%s AND slot IN ('complete','attempt') ORDER BY raw_blob->>'observed_at',thread_id",(self.store.ns,)).fetchall()
        count=0
        for snapshot in snapshots:
            tid=snapshot['thread_id']
            pages=self.read_snapshot(snapshot['raw_blob'])
            positions={}
            metadata,facts,attachments,limits=parse_pages(tid,pages,positions)
            with self.store.connect() as conn:
                self.store.ensure_thread(conn,tid)
                has_metadata=conn.execute("SELECT 1 FROM raw_facts WHERE account_namespace=%s AND thread_id=%s AND category='metadata' LIMIT 1",(self.store.ns,tid)).fetchone()
                if not has_metadata:
                    if isinstance(metadata.get('status'),dict):
                        metadata['status']=metadata['status'].get('type','unknown')
                    self.store.fact(conn,tid,'metadata',tid,metadata,source_observed_at=snapshot['raw_blob'].get('observed_at'))
                for category,ident,payload in facts:
                    exists=conn.execute('SELECT 1 FROM raw_facts WHERE account_namespace=%s AND thread_id=%s AND category=%s AND native_id=%s AND payload_hash=%s LIMIT 1',(self.store.ns,tid,category,ident,hashed(payload))).fetchone()
                    if not exists:
                        self.store.fact(conn,tid,category,ident,payload,position=positions.get(ident),source_observed_at=snapshot['raw_blob'].get('observed_at'))
                    elif category=='message':
                        conn.execute('INSERT INTO message_order VALUES (%s,%s,%s,%s) ON CONFLICT(account_namespace,thread_id,native_id) DO UPDATE SET sort_key=excluded.sort_key',(self.store.ns,tid,ident,positions[ident]))
                for ident,payload in attachments.items():
                    exists=conn.execute("SELECT 1 FROM raw_facts WHERE account_namespace=%s AND thread_id=%s AND category='attachment' AND native_id=%s AND payload_hash=%s LIMIT 1",(self.store.ns,tid,ident,hashed(payload))).fetchone()
                    if not exists:
                        self.store.fact(conn,tid,'attachment',ident,payload,source_observed_at=snapshot['raw_blob'].get('observed_at'))
                column='latest_raw' if snapshot['slot']=='complete' else 'latest_attempt_raw'
                conn.execute(f'UPDATE threads SET {column}=%s,content_coverage=%s,coverage_detail=%s WHERE account_namespace=%s AND thread_id=%s',
                    (Jsonb(snapshot['raw_blob']),'partial',Jsonb({'limitations':sorted(set(limits+[PROJECTION_LIMIT])),'reparsed_offline':True}),self.store.ns,tid))
                self.store.refresh_attachment_coverage(conn,tid)
                for attachment in conn.execute("SELECT native_id FROM attachments WHERE account_namespace=%s AND thread_id=%s AND state='pending'",(self.store.ns,tid)).fetchall():
                    self.store.enqueue(conn,tid,'attachment',attachment['native_id'])
            count+=1
        return {'snapshots':count,'row_facts':self.store.reindex()}

    def replace_obsolete_snapshot(self, old, current):
        if not old or old['sha256']==current['sha256'] or old.get('format_version')==2 or self.blobs.canonical_path(old['sha256']).exists():
            return
        with self.store.connect() as conn:
            held=conn.execute('''SELECT 1 FROM threads WHERE latest_raw->>'sha256'=%s OR latest_attempt_raw->>'sha256'=%s
                UNION ALL SELECT 1 FROM discovery_scans WHERE raw_blob->>'sha256'=%s
                UNION ALL SELECT 1 FROM attachment_blobs WHERE sha256=%s
                UNION ALL SELECT 1 FROM snapshots WHERE raw_blob->>'sha256'=%s LIMIT 1''',(old['sha256'],)*5).fetchone()
            # Local imports can share content-addressed objects with native snapshots.
            # Older installations need not have the optional import catalog yet.
            if not held and conn.execute("SELECT to_regclass('codex_backup_files') AS catalog").fetchone()['catalog']:
                held=conn.execute("SELECT 1 FROM codex_backup_files WHERE blob->>'sha256'=%s LIMIT 1",
                                  (old['sha256'],)).fetchone()
        if not held:
            self.blobs.path(old).unlink(missing_ok=True)

    def sync_attachment(self, tid, ident):
        with self.thread_locks_guard:
            lock=self.thread_locks.setdefault(tid,threading.RLock())
        with lock:
            return self._sync_attachment(tid,ident)

    def _sync_attachment(self, tid, ident):
        with self.store.connect() as conn:
            row=conn.execute('SELECT * FROM attachments WHERE account_namespace=%s AND thread_id=%s AND native_id=%s',(self.store.ns,tid,ident)).fetchone()
        if not row:
            raise RuntimeError('attachment_reference_missing')
        with self.store.connect() as conn:
            reference=self.store.attachment_metadata(conn,row)
        with self.store.connect() as conn:
            host=conn.execute('SELECT host_id FROM threads WHERE account_namespace=%s AND thread_id=%s',(self.store.ns,tid)).fetchone()['host_id']
        try:
            path=reference.get('path')
            url=reference.get('url') or reference.get('downloadUrl')
            if path:
                if host and host!='local':
                    raise RuntimeError('attachment_unavailable_host')
                file=Path(path)
                if not file.is_absolute() or not file.is_file() or file.is_symlink() or any(p.is_symlink() for p in file.parents):
                    raise RuntimeError('attachment_original_unavailable')
                with open(file,'rb') as stream:
                    blob=self.blobs.put_stream(iter(lambda:stream.read(1024*1024),b''))
            elif url and url.startswith('https://'):
                with urllib.request.urlopen(url,timeout=60) as response:
                    blob=self.blobs.put_stream(iter(lambda:response.read(1024*1024),b''))
            else:
                raise RuntimeError('attachment_original_unavailable')
            with self.store.connect() as conn:
                conn.execute('INSERT INTO attachment_blobs(account_namespace,thread_id,native_id,sha256,blob) VALUES (%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING', (self.store.ns,tid,ident,blob['sha256'],Jsonb(blob)))
                conn.execute("UPDATE attachments SET state='complete',blob=%s,last_error=NULL,refresh_used=false WHERE account_namespace=%s AND thread_id=%s AND native_id=%s", (Jsonb(blob),self.store.ns,tid,ident))
                # Discovery completeness is unknowable even if every visible reference was downloaded.
                self.store.refresh_attachment_coverage(conn,tid)
            return blob['sha256']
        except Exception as exc:
            kind=error_kind(exc)
            with self.store.connect() as conn:
                conn.execute("UPDATE attachments SET state=%s,last_error=%s WHERE account_namespace=%s AND thread_id=%s AND native_id=%s",('upstream_missing' if kind=='upstream_missing' else 'error',kind,self.store.ns,tid,ident))
                conn.execute("UPDATE threads SET attachment_coverage='partial' WHERE account_namespace=%s AND thread_id=%s",(self.store.ns,tid))
                # Persist the one-refresh budget BEFORE returning to the caller.
                retryable=(path and kind!='disk_full' and str(exc)!='attachment_unavailable_host') or (isinstance(exc,urllib.error.HTTPError) and exc.code in (401,403,404,410))
                refreshed=conn.execute('UPDATE attachments SET refresh_used=true WHERE account_namespace=%s AND thread_id=%s AND native_id=%s AND refresh_used=false RETURNING native_id',(self.store.ns,tid,ident)).fetchone() if retryable else None
            if refreshed:
                self.sync_thread(tid)
                return self.sync_attachment(tid,ident)
            raise

    def job(self, job):
        if job['kind'] in ('thread_request','thread_refresh'):
            with self.thread_locks_guard:
                lock=self.thread_locks.setdefault(job['thread_id'],threading.RLock())
            # Publish receipt + wire references before another same-target sync
            # can replace current pointers and collect an obsolete snapshot.
            with lock:
                return self._job(job)
        return self._job(job)

    def _job(self, job):
        receipt=None
        try:
            if job['kind'] in ('thread_request','thread_refresh'):
                from .thread_ops import execute_request
                receipt,failure=execute_request(self,job,latest_only=job['kind']=='thread_refresh')
                if failure:raise failure
            else:
                result=self.sync_thread(job['thread_id'],yield_for_interactive=True,background_job_id=job['id']) if job['kind']=='thread' else self.sync_attachment(job['thread_id'],job['item_id'])
            self.store.finish(job,receipt_record=receipt)
            return True,None
        except Exception as exc:
            kind=error_kind(exc)
            if isinstance(exc,NativeHistoryDeferred):
                # Transient history pressure is governed by the shared Gate,
                # not the ordinary job-failure budget. Preserve actual RPC facts.
                if exc.rpc_attempted:
                    self.store.error(kind,kind,job['thread_id'] if job['kind'] in ('thread','thread_request','thread_refresh') else None)
                self.store.finish(job,kind,receipt_record=receipt,retry_after_ms=exc.retry_after_ms,
                                  preserve_retry_budget=True)
                return False,kind
            self.store.error(kind,kind+':'+type(exc).__name__+(':'+exc.sqlstate if getattr(exc,'sqlstate',None) else ''),job['thread_id'] if job['kind'] in ('thread','thread_request','thread_refresh') else None)
            self.store.finish(job,kind,receipt_record=receipt)
            if kind=='disk_full' or (kind=='database_error' and isinstance(exc,psycopg.OperationalError)):
                # One bounded event per process, self-expiring at the diagnostic deadline.
                # Keep the existing fail-closed and queue handling unchanged.
                if time.time() < 1792985400:
                    with self.thread_locks_guard:
                        emit = not getattr(self, '_storage_failure_logged', False)
                        self._storage_failure_logged = True
                    if emit:
                        print(json.dumps({'event': 'mirror_storage_failure_context',
                                          **storage_failure_context(exc)}),
                              file=sys.stderr, flush=True)
                self.fatal_error=kind
                self.stop.set()
            return False,kind

    def adapt(self, success, kind):
        if kind in ('rate_limited','unreachable'):
            self.concurrency=max(1,self.concurrency//2)
            self.stable=0
        elif success:
            self.stable+=1
            if self.stable>=8 and self.concurrency<self.max_concurrency:
                self.concurrency+=1
                self.stable=0
        # The finished job is already committed. A connection timeout here
        # only defers its adaptive concurrency checkpoint to the next completion.
        # Do not replay the job or catch SQL/commit errors after opening.
        try:
            opened = self.store.connect()
        except psycopg.errors.ConnectionTimeout:
            count = min(65, getattr(self, '_adapt_connect_timeouts', 0) + 1)
            self._adapt_connect_timeouts = count
            if count in (1, 2, 4, 8, 16, 32, 64):
                record = {'event': 'mirror_adapt_connect_timeout', 'count': count,
                          'stage': 'connect', 'sql_started': False}
                try:
                    os.write(2, (json.dumps(record, separators=(',', ':')) + '\n').encode())
                except OSError:
                    pass
            return
        with opened as conn:
            conn.execute('UPDATE sync_state SET concurrency=%s,stable_count=%s WHERE account_namespace=%s',(self.concurrency,self.stable,self.store.ns))

    def drain(self):
        futures=set()
        with ThreadPoolExecutor(max_workers=self.max_concurrency) as pool:
            while not self.stop.is_set():
                while len(futures)<self.concurrency:
                    job=self.store.claim()
                    if not job:
                        break
                    futures.add(pool.submit(self.job,job))
                if not futures:
                    break
                done,futures=wait(futures,timeout=1,return_when=FIRST_COMPLETED)
                for future in done:
                    self.adapt(*future.result())

    def run(self, initial_scan=False):
        self.lock()
        if initial_scan:
            self.request_scan()
        # A new process never reconstructs missed hourly triggers.
        next_hour=(int(time.time())//3600+1)*3600
        scan_future=None
        jobs=set()
        with ThreadPoolExecutor(max_workers=1) as scanner, ThreadPoolExecutor(max_workers=self.max_concurrency) as pool:
            while not self.stop.is_set():
                now=time.time()
                if now>=next_hour:
                    if now-next_hour<5:
                        self.request_scan()
                    next_hour=(int(now)//3600+1)*3600
                if scan_future and scan_future.done():
                    try:
                        scan_future.result()
                    except Exception:
                        pass
                    scan_future=None
                if not scan_future and self.start_scan():
                    scan_future=scanner.submit(self.scan)
                completed={future for future in jobs if future.done()}
                for future in completed:
                    self.adapt(*future.result())
                jobs-=completed
                while len(jobs)<self.concurrency:
                    job=self.store.claim()
                    if not job:
                        break
                    jobs.add(pool.submit(self.job,job))
                self.stop.wait(1)
        self.close()
        if self.fatal_error:
            print(json.dumps({'event':'mirror_stopped_storage_error','kind':self.fatal_error}),file=sys.stderr)
            raise SystemExit(78)

    def close(self):
        self.native.close()
        if self.owner:
            self.owner.close()
