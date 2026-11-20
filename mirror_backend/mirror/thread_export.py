"""Read-only, mechanical, self-contained thread export (no source publication)."""
import base64
import contextlib
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import uuid
import zipfile
from psycopg import sql
from psycopg.rows import dict_row
from .blob import BlobStore, BlobError, fsync_dir
from .codec import PayloadCodec
from .sources import is_offline_source

VERSION='thread-export-v1'

class ReadOnlyBlobs(BlobStore):
    def __init__(self,root):
        self.root=Path(root).resolve(strict=True)
        if not self.root.is_dir():raise ValueError('object_root_not_directory')
    def put(self,*a,**k):raise RuntimeError('read_only_objects')
    put_stream=put
    put_media=put
    def _safe(self,p):
        relative=p.relative_to(self.root)
        current=self.root
        for piece in relative.parts:
            current=current/piece
            if current.is_symlink():raise BlobError('symlink_object_path')
        return p
    def canonical_path(self,sha):return self._safe(super().canonical_path(sha))
    def path(self,record):
        sha=record['sha256'];self.canonical_path(sha)
        allowed={f'{sha[:2]}/{sha}{suffix}' for suffix in ('.gz','.bin','.v2.raw.zst','.v2.raw.bin','.v2.media.zst','.v2.media.bin')}
        if record['path'] not in allowed:raise BlobError('invalid_blob_path')
        return self._safe(self.root/record['path'])

def encode(value):
    def default(x):
        if isinstance(x,(bytes,bytearray,memoryview)):return {'$bytes_base64':base64.b64encode(x).decode('ascii')}
        if hasattr(x,'isoformat'):return x.isoformat()
        raise TypeError(type(x).__name__)
    return json.dumps(value,ensure_ascii=True,separators=(',',':'),default=default).encode('utf-8')

def refs(value):
    if isinstance(value,dict):
        if {'sha256','path','byte_length'}<=value.keys():yield value
        for child in value.values():yield from refs(child)
    elif isinstance(value,list):
        for child in value:yield from refs(child)

def atomic_publish(source,target):
    # Linux renameat2 excludes the check/replace race even for existing empty dirs.
    libc=ctypes.CDLL(None,use_errno=True)
    fn=libc.renameat2;fn.argtypes=[ctypes.c_int,ctypes.c_char_p,ctypes.c_int,ctypes.c_char_p,ctypes.c_uint]
    if fn(-100,os.fsencode(source),-100,os.fsencode(target),1):
        raise OSError(ctypes.get_errno(),'export_output_publish_failed')
    fsync_dir(target.parent)

class Bundle:
    def __init__(self,path,reserve,max_bytes):
        self.path=path;self.reserve=reserve;self.max_bytes=max_bytes;self.files={}
        self.archive=zipfile.ZipFile(path/'archive.zip','w',compression=zipfile.ZIP_DEFLATED,compresslevel=1)
    def check(self):
        if shutil.disk_usage(self.path).free<self.reserve:raise OSError('export_space_reserve')
        if sum(p.stat().st_size for p in self.path.iterdir() if p.is_file())>self.max_bytes:raise OSError('export_output_budget')
    @contextlib.contextmanager
    def member(self,name):
        if name in self.files or name.startswith('/') or '..' in Path(name).parts:raise ValueError('invalid_archive_member')
        digest=hashlib.sha256();length=0
        with self.archive.open(name,'w',force_zip64=True) as target:
            def write(data):
                nonlocal length
                for at in range(0,len(data),1024*1024):
                    self.check();piece=data[at:at+1024*1024];target.write(piece);digest.update(piece);length+=len(piece)
            yield write
        self.files[name]={'sha256':digest.hexdigest(),'byte_length':length}
    def add(self,name,chunks):
        with self.member(name) as write:
            for chunk in chunks:write(chunk)
        return self.files[name]

def related(c,store,tid,codec):
    if is_offline_source(store.ns):return []
    rows=c.execute("""SELECT r.*,r.raw_payload::text AS raw_text FROM thread_items i JOIN raw_facts r
      ON r.seq=i.fact_seq AND r.account_namespace=i.account_namespace AND r.thread_id=i.thread_id
      AND r.native_id=i.native_id AND r.payload_hash=i.payload_hash AND r.category='item'
      WHERE i.account_namespace LIKE 'chatgpt-export:%%' AND i.thread_id=%s AND i.native_id=%s
      AND i.type='unknown/chatgptExportAssociation' ORDER BY i.account_namespace""",(tid,'export-association:'+store.ns)).fetchall()
    result=[]
    for row in rows:
        p=json.loads(codec.decode(row))
        if (p.get('type')=='chatgptExportAssociation' and p.get('active') is True and p.get('online_namespace')==store.ns
            and p.get('online_thread_id')==tid and isinstance(p.get('evidence'),dict) and p['evidence']):
            result.append({'namespace':row['account_namespace'],'thread_id':row['thread_id'],'association_evidence':p['evidence']})
    return result

def export_thread(store,tid,output,include_related=True,reserve_bytes=5*1024**3,max_output_bytes=8*1024**3,snapshot=None):
    if reserve_bytes<0 or max_output_bytes<=0:raise ValueError('invalid_export_budget')
    output=Path(output).absolute()
    if output.exists() or output.is_symlink():raise FileExistsError('export_output_exists')
    parent=output.parent.resolve(strict=True)
    if output.parent!=parent:raise ValueError('symlink_output_parent')
    objects=ReadOnlyBlobs(store.blobs.root);codec=PayloadCodec(objects)
    if output==objects.root or objects.root in output.parents:raise ValueError('output_inside_object_store')
    work=Path(tempfile.mkdtemp(prefix='.thread-export-',dir=parent));os.chmod(work,0o700)
    bundle=None
    manifest={'schema':VERSION,'artifact_complete':False,'read_only':True,'staging_reads':0,'sources':[],'files':{},'objects':{},'gaps':[],
      'rules':['Sources are separate: no semantic or cross-source deduplication.','Conversation includes every stored user/assistant revision; missing current revision is included explicitly.',
               'Chronology: stored sort_key, then first_fact_seq/native identity, then revision observed_at/fact_seq. Unknown chronology is labeled.',
               'Archive facts contain decoded original JSON bytes; v2 media bytes are reconstructed inside those originals. No external codec/CAS dependencies are required.',
               'Shared import members are provenance references only; unrelated conversations are never copied into this archive.',
               'No cross-Mirror re-import or full schema restore is asserted. SQL NULL versus JSON null in nonraw JSON columns is tagged separately.']}
    try:
        bundle=Bundle(work,reserve_bytes,max_output_bytes);bundle.check()
        with store.connect() as c:
            c.row_factory=dict_row
            c.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
            if snapshot is not None:c.execute(sql.SQL('SET TRANSACTION SNAPSHOT {}').format(sql.Literal(snapshot)))
            c.execute("SET LOCAL TIME ZONE 'UTC'")
            manifest['transaction_snapshot']=c.execute('SELECT pg_current_snapshot()::text AS snapshot').fetchone()['snapshot']
            manifest['imported_snapshot']=snapshot
            manifest['snapshot_at']=c.execute('SELECT transaction_timestamp() AS at').fetchone()['at'].isoformat()
            sources=[{'namespace':store.ns,'thread_id':tid}]+(related(c,store,tid,codec) if include_related else [])
            names=[r['tablename'] for r in c.execute('SELECT tablename FROM pg_tables WHERE schemaname=current_schema() ORDER BY tablename')]
            schemas={}
            for name in names:
                cols=c.execute('SELECT a.attname,format_type(a.atttypid,a.atttypmod) AS type FROM pg_attribute a WHERE a.attrelid=to_regclass(%s) AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum',(name,)).fetchall()
                schemas[name]=cols
            manifest['table_columns']=schemas
            objects_to_copy={};run_refs=set()
            def remember(row,origin):
                for record in refs(row):
                    sha=record['sha256']
                    if sha in objects_to_copy and objects_to_copy[sha]['record']['byte_length']!=record['byte_length']:raise BlobError('reference_length_conflict')
                    entry=objects_to_copy.setdefault(sha,{'record':record,'references':[]});entry['references'].append(origin)
            def rows_for(name,where,params):
                cols=schemas[name]
                # Preserve the distinction JSON null/SQL NULL, absent in Python None.
                markers=[sql.SQL('{} IS NULL AS {}').format(sql.Identifier(x['attname']),sql.Identifier('__sql_null_'+x['attname'])) for x in cols if x['type'] in ('json','jsonb')]
                extra=sql.SQL(',')+sql.SQL(',').join(markers) if markers else sql.SQL('')
                query=sql.SQL('SELECT *{} FROM {} WHERE {} ORDER BY ctid').format(extra,sql.Identifier(name),where)
                with c.cursor(name='export_'+uuid.uuid4().hex,row_factory=dict_row) as cur:
                    cur.itersize=8;cur.execute(query,params)
                    for row in cur:yield row
            with (work/'conversation.jsonl').open('wb') as jsonl,(work/'conversation.md').open('wb') as readable:
                readable.write(b'# Mechanical conversation export\n\nAll stored revisions, grouped by source. No summary or semantic deduplication.\n')
                for source_index,source in enumerate(sources):
                    ns=source['namespace'];sid=source['thread_id'];prefix=f'sources/{source_index:04d}';params=(ns,sid)
                    thread=c.execute('SELECT * FROM threads WHERE account_namespace=%s AND thread_id=%s',params).fetchone()
                    if thread is None:raise ValueError('thread_not_found')
                    detail={**source,'metadata':thread,'tables':{},'conversation_revisions':0};manifest['sources'].append(detail)
                    readable.write(b'\n## Source metadata\n\n'+encode({**source,'last_synced_at':thread['last_synced_at'],'coverage':thread['coverage_detail'],'content_coverage':thread['content_coverage'],'attachment_coverage':thread['attachment_coverage']})+b'\n')
                    member_refs=set()
                    for name,cols in schemas.items():
                        if not {'account_namespace','thread_id'}<={x['attname'] for x in cols}:continue
                        if name=='raw_facts':continue
                        count=0
                        with bundle.member(prefix+'/tables/'+name+'.jsonl') as write:
                            for row in rows_for(name,sql.SQL('account_namespace=%s AND thread_id=%s'),params):
                                remember(row,{'source':source_index,'table':name});write(encode(row)+b'\n');count+=1
                                if name=='codex_backup_threads':run_refs.add((row['run_id'],ns,sid))
                                if name=='attachments' and row['blob'] is None:
                                    if row['state']=='complete':raise BlobError('complete_attachment_without_blob')
                                    manifest['gaps'].append({'source':source_index,'kind':'attachment_not_captured','native_id':row['native_id'],'state':row['state'],'recorded_reason':row['last_error']})
                        detail['tables'][name]=count
                    count=0
                    raw_index=work/'.raw-index.jsonl'
                    with raw_index.open('wb') as index_file:
                        write=index_file.write
                        with c.cursor(name='facts_'+uuid.uuid4().hex,row_factory=dict_row) as cur:
                            cur.itersize=1;cur.execute('SELECT *,raw_payload::text AS raw_text FROM raw_facts WHERE account_namespace=%s AND thread_id=%s ORDER BY seq',params)
                            for row in cur:
                                raw=codec.decode(row);member=prefix+'/raw/'+str(row['seq'])+'.json'
                                bundle.add(member,[raw]);payload=json.loads(raw)
                                if isinstance(payload,dict) and payload.get('type')=='chatgptExportObservation' and payload.get('member'):
                                    member_refs.add((payload.get('snapshot_id'),payload['member']))
                                record={k:v for k,v in row.items() if k not in ('raw_payload','raw_text','encoded_payload')};record['archive_raw']=member
                                record['archive_raw_sha256']=hashlib.sha256(raw).hexdigest();record['archive_raw_length']=len(raw)
                                write(encode(record)+b'\n');count+=1
                    with raw_index.open('rb') as index_file:bundle.add(prefix+'/tables/raw_facts.jsonl',iter(lambda:index_file.read(1024*1024),b''))
                    raw_index.unlink()
                    detail['tables']['raw_facts']=count
                    query='''WITH versions AS (
                       SELECT native_id,role,text_content,payload_hash,fact_seq,observed_at FROM message_revisions WHERE account_namespace=%s AND thread_id=%s
                       UNION ALL SELECT m.native_id,m.role,m.text_content,m.payload_hash,m.fact_seq,r.observed_at FROM messages m JOIN raw_facts r ON r.seq=m.fact_seq
                       WHERE m.account_namespace=%s AND m.thread_id=%s AND NOT EXISTS(SELECT 1 FROM message_revisions v WHERE v.fact_seq=m.fact_seq))
                       SELECT v.*,o.sort_key,m.first_fact_seq FROM versions v LEFT JOIN message_order o ON o.account_namespace=%s AND o.thread_id=%s AND o.native_id=v.native_id
                       LEFT JOIN messages m ON m.account_namespace=%s AND m.thread_id=%s AND m.native_id=v.native_id
                       WHERE v.role IN ('user','assistant') ORDER BY o.sort_key NULLS LAST,COALESCE(m.first_fact_seq,v.fact_seq),v.native_id,v.observed_at,v.fact_seq'''
                    with c.cursor(name='conversation_'+uuid.uuid4().hex,row_factory=dict_row) as cur:
                        cur.itersize=8;cur.execute(query,params*4)
                        for row in cur:
                            record={**source,**row,'chronology_known':row['sort_key'] is not None};jsonl.write(encode(record)+b'\n')
                            body=row['text_content'];meta={k:v for k,v in record.items() if k!='text_content'}
                            readable.write(b'\n### '+row['role'].encode()+b'\n\n'+encode(meta)+b'\n\n')
                            readable.write((body if isinstance(body,str) else json.dumps(body,ensure_ascii=True)).encode('utf-8','backslashreplace')+b'\n')
                            detail['conversation_revisions']+=1;bundle.check()
                    # Only evidence-addressed shared members, not every file in an import.
                    source['import_members']=detail['import_members']=[{'run_id':run,'source_path':path} for run,path in sorted(member_refs)]
            if 'codex_backup_files' in schemas:
                selected={}
                for run,ns,sid in sorted(run_refs):
                    source_name=ns[len('codex-backup:'):] if ns.startswith('codex-backup:') else ns
                    for row in rows_for('codex_backup_files',sql.SQL('run_id=%s AND source=%s AND thread_id=%s'),(run,source_name,sid)):
                        selected[(row['run_id'],row['source'],row['source_path'])]=row
                for source in sources:
                    for member in source.get('import_members',[]):
                        for row in rows_for('codex_backup_files',sql.SQL('run_id=%s AND source=%s AND source_path=%s'),(member['run_id'],source['namespace'],member['source_path'])):
                            selected[(row['run_id'],row['source'],row['source_path'])]=row
                with bundle.member('catalog/files.jsonl') as write:
                    for key,row in sorted(selected.items()):
                        if row.get('thread_id')==tid:
                            remember(row,{'catalog':list(key)})
                            row['archive_inclusion']='original_included'
                        else:
                            row['archive_inclusion']='reference_only'
                            row['archive_omission_reason']='shared_source_not_included'
                            manifest['gaps'].append({'kind':'shared_source_not_included','catalog':list(key),'sha256':row['blob']['sha256'],'byte_length':row['blob']['byte_length']})
                        write(encode(row)+b'\n')
                runs=sorted({x[0] for x in run_refs}|{x[0] for x in selected})
                with bundle.member('catalog/imports.jsonl') as write:
                    for run in runs:
                        for row in rows_for('codex_backup_imports',sql.SQL('run_id=%s'),(run,)):write(encode(row)+b'\n')
            for sha,entry in sorted(objects_to_copy.items()):
                member='objects/'+sha
                # Decode v2 framing/media into exact original bytes; missing/corrupt claimed
                # objects fail the owned export, unlike recorded upstream absence above.
                check=bundle.add(member,objects.chunks(entry['record']))
                if check['sha256']!=sha or check['byte_length']!=entry['record']['byte_length']:raise BlobError('export_object_mismatch')
                manifest['objects'][sha]={**check,'member':member,'source_record':entry['record'],'references':entry['references']}
            (work/'verify.py').write_bytes(Path(__file__).with_name('export_verify.py').read_bytes())
            for name in ('conversation.jsonl','conversation.md','verify.py'):
                with (work/name).open('rb') as f:bundle.add(name,iter(lambda:f.read(1024*1024),b''))
            manifest['artifact_complete']=True;manifest['object_status']='all_in_scope_captured_objects_verified; shared originals explicitly reference_only';manifest['files']=dict(bundle.files)
            bundle.add('manifest.json',[encode(manifest)+b'\n'])
        bundle.archive.close();bundle.check()
        # Outer manifest authenticates the final ZIP, without recursive hashes.
        digest=hashlib.sha256()
        with (work/'archive.zip').open('rb') as f:
            for chunk in iter(lambda:f.read(1024*1024),b''):digest.update(chunk)
        manifest['archive']={'file':'archive.zip','byte_length':(work/'archive.zip').stat().st_size,'sha256':digest.hexdigest()}
        (work/'manifest.json').write_bytes(encode(manifest)+b'\n')
        bundle.check()
        for p in work.iterdir():
            os.chmod(p,0o600)
            with p.open('rb') as f:os.fsync(f.fileno())
        fsync_dir(work);atomic_publish(work,output)
        return {'output':str(output),'schema':VERSION,'artifact_complete':True,'sources':len(sources),'conversation_revisions':sum(s['conversation_revisions'] for s in manifest['sources']),'gaps':len(manifest['gaps']),'archive':manifest['archive']}
    finally:
        if bundle:bundle.archive.close()
        if work.exists():shutil.rmtree(work)
