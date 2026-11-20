"""Explicit queue requests. A client never starts another native reader."""
import json
import time
import uuid
from datetime import datetime, timezone
from .sources import is_offline_source

REQUEST_KIND='thread_request'
COUNT_TABLES=('raw_facts','messages','message_revisions','thread_items','thread_item_revisions','attachments')

def counts(store, conn, tid):
    return {name:conn.execute(f'SELECT count(*) AS n FROM {name} WHERE account_namespace=%s AND thread_id=%s',(store.ns,tid)).fetchone()['n'] for name in COUNT_TABLES}

def request_sync(store, tid, request_id=None, wait_seconds=0):
    if is_offline_source(store.ns):raise ValueError('offline_source_cannot_sync')
    if not isinstance(tid,str) or not tid or len(tid)>200 or '\x00' in tid:raise ValueError('invalid_thread_id')
    wait_seconds=float(wait_seconds)
    if not 0<=wait_seconds<=3600:raise ValueError('wait_seconds_out_of_range')
    if request_id is None:
        request_id=str(uuid.uuid4())
        with store.connect() as c:
            store.ensure_thread(c,tid)
            c.execute('INSERT INTO queue(account_namespace,thread_id,kind,item_id) VALUES (%s,%s,%s,%s)',(store.ns,tid,REQUEST_KIND,request_id))
    else:
        request_id=str(uuid.UUID(request_id))
    deadline=time.monotonic()+wait_seconds
    while True:
        with store.connect() as c:
            row=c.execute('SELECT state,attempts,started_at,last_error,available_at FROM queue WHERE account_namespace=%s AND thread_id=%s AND kind=%s AND item_id=%s',(store.ns,tid,REQUEST_KIND,request_id)).fetchone()
            records=c.execute("SELECT raw_blob FROM snapshots WHERE account_namespace=%s AND thread_id=%s AND slot LIKE %s ORDER BY slot",(store.ns,tid,'request:'+request_id+':%')).fetchall()
        if row is None:raise ValueError('sync_request_not_found')
        receipts=[r['raw_blob']['receipt'] for r in records]
        if any(r.get('request_id')!=request_id or r.get('namespace')!=store.ns or r.get('thread_id')!=tid for r in receipts):raise ValueError('sync_receipt_identity_mismatch')
        receipt={'request_id':request_id,'attempts':[r['attempt'] for r in receipts]} if receipts else None
        terminal=row['state']=='done' or (row['state']=='error' and row['attempts']>=3)
        result={'request_id':request_id,'namespace':store.ns,'thread_id':tid,'state':row['state'],'terminal':terminal,'attempts':row['attempts'],'started_at':row['started_at'],'available_at':row['available_at'],'receipt':receipt,'last_error':row['last_error'],'receipt_missing':terminal and receipt is None,
                'execution_succeeded':row['state']=='done' and bool(receipt) and receipt['attempts'][-1]['error'] is None,'wait_expired':False}
        if terminal or time.monotonic()>=deadline:
            result['wait_expired']=not terminal
            return result
        time.sleep(min(.25,max(0,deadline-time.monotonic())))

def execute_request(mirror, job, latest_only=False):
    """Existing daemon only; both baseline and final counts are under its target lock."""
    tid=job['thread_id'];store=mirror.store
    with mirror.thread_locks_guard:
        import threading
        lock=mirror.thread_locks.setdefault(tid,threading.RLock())
    with lock:
        with store.connect() as c:before=counts(store,c,tid)
        from .runtime import PROJECTION_LIMIT
        attempt={'known_limits':[PROJECTION_LIMIT],'started_at':datetime.now(timezone.utc).isoformat(),'pages':0,'reader_eof':False,'last_cursor':None,'next_cursor':None,'error':None,'read_scope':'latest_page' if latest_only else 'full_history'}
        failure=None
        try:mirror.sync_thread(tid,receipt=attempt,latest_only=latest_only)
        except Exception as exc:
            from .runtime import error_kind
            failure=exc;attempt['error']={'kind':error_kind(exc),'type':type(exc).__name__,'sqlstate':getattr(exc,'sqlstate',None)}
        with store.connect() as c:
            after=counts(store,c,tid)
            row=c.execute('SELECT last_synced_at,last_checked_at,content_coverage,attachment_coverage,coverage_detail FROM threads WHERE account_namespace=%s AND thread_id=%s',(store.ns,tid)).fetchone()
        attempt.update(finished_at=datetime.now(timezone.utc).isoformat(),added={name:after[name]-before[name] for name in before},thread_state=row)
        receipt={'request_id':job['item_id'],'namespace':store.ns,'thread_id':tid,'attempt':attempt}
        raw=json.dumps(receipt,default=str,ensure_ascii=True).encode('utf-8')
        receipt=json.loads(raw)
        record=mirror.blobs.put(raw)
        record.update(format='thread-sync-receipt-v1',observed_at=attempt['finished_at'],receipt=receipt)
        return record,failure
