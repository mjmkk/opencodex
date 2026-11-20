import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import signal
import sys
import time
from psycopg.types.json import Jsonb
from .runtime import Mirror, account_namespace
from .store import Store
from .blob import BlobStore
from .api import LocalMirror


def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser()
    parser.add_argument('command',choices=['init','run','scan','status','index','metadata','body','enqueue','registry','reindex','reparse','audit','sync-thread','export-thread'])
    parser.add_argument('--thread')
    parser.add_argument('--request-id')
    parser.add_argument('--snapshot')
    parser.add_argument('--wait-seconds',type=float,default=0)
    parser.add_argument('--output')
    parser.add_argument('--no-related',action='store_true')
    parser.add_argument('--reserve-bytes',type=int,default=5*1024**3)
    parser.add_argument('--max-output-bytes',type=int,default=8*1024**3)
    parser.add_argument('--namespace',default=os.environ.get('MIRROR_NAMESPACE'))
    parser.add_argument('--dsn',default=os.environ.get('MIRROR_DSN','host=/home/spirit/.local/state/thread-mirror/pgsocket port=55428 dbname=thread_mirror user=spirit'))
    parser.add_argument('--blobs',default=os.environ.get('MIRROR_BLOBS','/home/spirit/.local/state/thread-mirror/objects'))
    parser.add_argument('--initial-scan',action='store_true')
    parser.add_argument('--offline',action='store_true')
    parser.add_argument('--registry-file')
    parser.add_argument('--registry-stdin',action='store_true')
    parser.add_argument('--max-concurrency',type=int,default=4)
    args=parser.parse_args()
    # Local queries require saved namespace; never read online identity just to query.
    ns=args.namespace
    if not ns:
        parser.error('--namespace / MIRROR_NAMESPACE is required')
    from .thread_export import ReadOnlyBlobs
    store=Store(args.dsn,ns,ReadOnlyBlobs(args.blobs) if args.command=='export-thread' else BlobStore(args.blobs))
    if args.command=='init':
        store.init()
        print('initialized')
        return
    api=LocalMirror(store)
    if args.command in ('sync-thread','export-thread'):
        if not args.thread:parser.error('--thread is required')
        if args.command=='sync-thread':
            result=api.sync_thread(args.thread,args.request_id,args.wait_seconds)
        else:
            if not args.output:parser.error('--output is required')
            result=api.export_thread(args.thread,args.output,include_related=not args.no_related,reserve_bytes=args.reserve_bytes,max_output_bytes=args.max_output_bytes,snapshot=args.snapshot)
        print(json.dumps(result,default=str,ensure_ascii=True))
        return
    if args.command in ('metadata','body','index'):
        result=api.index() if args.command=='index' else api.metadata(args.thread) if args.command=='metadata' else api.body(args.thread,args.offline)
        print(json.dumps(result,default=str,ensure_ascii=False))
        return
    if args.command=='enqueue':
        with store.connect() as conn:
            store.ensure_thread(conn,args.thread)
            store.enqueue(conn,args.thread)
        print('queued')
        return
    if args.command=='registry':
        if args.registry_file or args.registry_stdin:
            document=json.load(sys.stdin) if args.registry_stdin else json.loads(Path(args.registry_file).read_text())
            api.observe_registry(document['issue_id'],document['updated_at'],document['registry'])
            print('registry_observed')
        else:
            print(json.dumps(api.registry(),default=str))
        return
    if args.command=='status':
        with store.connect() as conn:
            status={}
            for table in ('threads','messages','message_revisions','thread_items','thread_item_revisions','raw_facts','discovery_scans','attachments','attachment_blobs','sync_errors'):
                status[table]=conn.execute(f'SELECT count(*) AS count FROM {table} WHERE account_namespace=%s',(ns,)).fetchone()['count']
            status['queue']=conn.execute('SELECT state,count(*) FROM queue WHERE account_namespace=%s GROUP BY state',(ns,)).fetchall()
            status['coverage']=conn.execute('SELECT content_coverage,attachment_coverage,count(*) FROM threads WHERE account_namespace=%s GROUP BY 1,2',(ns,)).fetchall()
            status['sync']=conn.execute('SELECT * FROM sync_state WHERE account_namespace=%s',(ns,)).fetchone()
        print(json.dumps(status,default=str))
        return
    mirror=Mirror(store,BlobStore(args.blobs),max_concurrency=args.max_concurrency)
    if args.command=='run':
        signal.signal(signal.SIGTERM,lambda *a:mirror.stop.set())
        signal.signal(signal.SIGINT,lambda *a:mirror.stop.set())
        mirror.run(args.initial_scan)
        return
    if args.command=='scan':
        # Queue only; persistent daemon performs actual scan and saves raw.
        mirror.request_scan()
        print('scan_requested')
        return
    if args.command in ('reindex','reparse'):
        mirror.lock()
        try:
            print(json.dumps(mirror.reparse() if args.command=='reparse' else {'replayed_row_facts':store.reindex()}))
        finally:
            mirror.close()
        return
    if args.command=='audit':
        with store.connect() as conn:
            rows=conn.execute('''SELECT latest_raw AS blob FROM threads WHERE account_namespace=%s AND latest_raw IS NOT NULL
                UNION ALL SELECT latest_attempt_raw FROM threads WHERE account_namespace=%s AND latest_attempt_raw IS NOT NULL
                UNION ALL SELECT raw_blob FROM discovery_scans WHERE account_namespace=%s
                UNION ALL SELECT blob FROM attachment_blobs WHERE account_namespace=%s
                UNION ALL SELECT raw_blob FROM snapshots WHERE account_namespace=%s''',(ns,)*5).fetchall()
        seen=set(); failures=[]
        for row in rows:
            blob=row['blob']
            if blob['sha256'] in seen:
                continue
            seen.add(blob['sha256'])
            try:
                mirror.blobs.verify(blob)
                if blob.get('format')=='exact-jsonrpc-pages-v1':
                    mirror.read_snapshot(blob)
            except Exception as exc:
                failures.append({'sha256':blob['sha256'],'error':str(exc)})
        print(json.dumps({'checked':len(seen),'failures':failures}))
        if failures:
            raise SystemExit(1)

if __name__=='__main__':
    main()
