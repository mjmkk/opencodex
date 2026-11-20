"""Standalone stdlib verifier. Usage: python verify.py /path/to/export-directory."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile


def digest(stream):
    h=hashlib.sha256();n=0
    for block in iter(lambda:stream.read(1024*1024),b''):h.update(block);n+=len(block)
    return h.hexdigest(),n


def verify(directory):
    root=Path(directory);outer=json.loads((root/'manifest.json').read_bytes())
    with (root/'archive.zip').open('rb') as f:sha,length=digest(f)
    if (sha,length)!=(outer['archive']['sha256'],outer['archive']['byte_length']):raise ValueError('archive_integrity')
    with zipfile.ZipFile(root/'archive.zip') as z:
        manifest=json.loads(z.read('manifest.json'));names=z.namelist()
        if manifest!={k:v for k,v in outer.items() if k!='archive'}:raise ValueError('manifest_disagreement')
        if len(names)!=len(set(names)) or set(names)!=set(manifest['files'])|{'manifest.json'}:raise ValueError('archive_member_set')
        if not manifest['artifact_complete']:raise ValueError('artifact_incomplete')
        for name,info in manifest['files'].items():
            if name.startswith('/') or '..' in Path(name).parts:raise ValueError('unsafe_member')
            with z.open(name) as f:sha,length=digest(f)
            if (sha,length)!=(info['sha256'],info['byte_length']):raise ValueError('member_integrity')
        for name in ('conversation.md','conversation.jsonl'):
            with (root/name).open('rb') as f:sha,length=digest(f)
            if (sha,length)!=(manifest['files'][name]['sha256'],manifest['files'][name]['byte_length']):raise ValueError('loose_conversation_integrity')
        raw_count=0
        for source_index,source in enumerate(manifest['sources']):
            member=f'sources/{source_index:04d}/tables/raw_facts.jsonl';count=0
            with z.open(member) as lines:
                for line in lines:
                    row=json.loads(line);raw=z.read(row['archive_raw']);count+=1
                    if (hashlib.sha256(raw).hexdigest(),len(raw))!=(row['archive_raw_sha256'],row['archive_raw_length']):raise ValueError('raw_bytes_integrity')
                    payload=json.loads(raw)
                    canonical=json.dumps(payload,sort_keys=True,ensure_ascii=False,separators=(',',':')).encode('utf-8','surrogatepass')
                    if hashlib.sha256(canonical).hexdigest()!=row['payload_hash']:raise ValueError('raw_semantic_hash')
            if count!=source['tables']['raw_facts']:raise ValueError('raw_row_count')
            raw_count+=count
        return {'verified':True,'schema':manifest['schema'],'sources':len(manifest['sources']),'members':len(names),'raw_facts':raw_count,'gaps':len(manifest['gaps']),'coverage':'See each source metadata; artifact integrity is not upstream completeness.'}

if __name__=='__main__':
    try:print(json.dumps(verify(sys.argv[1])))
    except Exception as exc:print(json.dumps({'verified':False,'error_type':type(exc).__name__}));raise SystemExit(1)
