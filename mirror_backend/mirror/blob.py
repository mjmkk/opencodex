"""Durable CAS objects, legacy readers and explicit v2 representation records."""
import gzip
import hashlib
import json
import os
import shutil
import struct
import tempfile
from pathlib import Path
from .codec import CodecError, factor, rebuild, zstd_stream

class BlobError(Exception):
    pass

def fsync_dir(directory):
    fd=os.open(directory,os.O_RDONLY|os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)

def file_chunks(path, compressed=False):
    with (gzip.open(path,'rb') if compressed else open(path,'rb')) as source:
        while chunk:=source.read(1024*1024):yield chunk

def lines(chunks):
    # Retain one original line without repeatedly copying a growing buffer.
    parts=[]
    for chunk in chunks:
        start=0
        while True:
            at=chunk.find(b'\n',start)
            if at<0:break
            parts.append(chunk[start:at+1]);yield b''.join(parts);parts=[];start=at+1
        if start<len(chunk):parts.append(chunk[start:])
    if parts:yield b''.join(parts)

def decode_frames(chunks, media_reader):
    rest=bytearray();want=None
    for chunk in chunks:
        rest.extend(chunk)
        while True:
            if want is None:
                if len(rest)<8:break
                want=struct.unpack('>Q',rest[:8])[0];del rest[:8]
            if len(rest)<want:break
            yield rebuild(bytes(rest[:want]),media_reader);del rest[:want];want=None
    if rest or want is not None:raise BlobError('truncated_object_frame')

class BlobStore:
    def __init__(self, root):
        self.root=Path(root).resolve();self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
        os.chmod(self.root,0o700);self._media_saved={}

    def canonical_path(self, sha):
        if len(sha)!=64 or any(c not in '0123456789abcdef' for c in sha):raise BlobError('invalid_sha')
        return self.root/sha[:2]/(sha+'.v2.json')

    def canonical(self, sha):
        p=self.canonical_path(sha)
        if p.exists():
            value=json.loads(p.read_text())
            if value.get('sha256')!=sha or value.get('format_version')!=2:raise BlobError('invalid_canonical_record')
            return value
        for ext,codec in [('bin','none'),('gz','gzip')]:
            p=self.root/sha[:2]/(sha+'.'+ext)
            if p.is_file():
                record=dict(sha256=sha,path=str(p.relative_to(self.root)),compression=codec)
                n=0;digest=hashlib.sha256()
                for chunk in self.chunks(record):n+=len(chunk);digest.update(chunk)
                if digest.hexdigest()!=sha:raise BlobError('existing_media_corrupt')
                record['byte_length']=n;return record
        raise BlobError('blob_missing')

    def put_media(self, sha, data):
        if hashlib.sha256(data).hexdigest()!=sha:raise BlobError('media_sha_mismatch')
        if sha in self._media_saved:return self._media_saved[sha]
        try:
            record=self.canonical(sha)
            self.verify(record)
            if record['byte_length']!=len(data):raise BlobError('media_length_mismatch')
        except BlobError as e:
            if str(e)!='blob_missing':raise
            record=self.put_stream([data],compress=True,externalize=False)
        if not self.canonical_path(sha).exists():
            alias=dict(record,format_version=2,representation=record.get('representation','raw'))
            dest=self.canonical_path(sha);dest.parent.mkdir(mode=0o700,exist_ok=True)
            fd,temp=tempfile.mkstemp(dir=dest.parent,prefix='.record-')
            try:
                with os.fdopen(fd,'w') as out:
                    json.dump(alias,out,sort_keys=True);out.flush();os.fsync(out.fileno())
                os.replace(temp,dest);fsync_dir(dest.parent);fsync_dir(self.root)
            finally:Path(temp).unlink(missing_ok=True)
            record=alias
        if len(self._media_saved)>=4096:self._media_saved.clear()
        self._media_saved[sha]=record;return record

    def read_media(self, sha):return self.read(self.canonical(sha))

    def put(self, raw, compress=True):
        externalize=False
        if raw.lstrip().startswith((b'{',b'[')):
            try:json.loads(raw);externalize=True
            except (ValueError,UnicodeDecodeError):pass
        return self.put_stream([raw],compress,externalize=externalize)

    def put_stream(self, chunks, compress=False, externalize=False, force_recode=False):
        # Compressed staging bounds disk consumption even for large original files.
        # After a codec failure the complete spool can be replayed as v2/none.
        digest=hashlib.sha256();size=0
        fd,spool=tempfile.mkstemp(dir=self.root,prefix='.incoming-')
        candidate=None
        try:
            with os.fdopen(fd,'wb') as file:
                with gzip.GzipFile(fileobj=file,mode='wb',mtime=0,filename='',compresslevel=1) as out:
                    for chunk in chunks:
                        digest.update(chunk);size+=len(chunk);out.write(chunk)
                file.flush();os.fsync(file.fileno())
            sha=digest.hexdigest()
            if not force_recode and self.canonical_path(sha).exists():
                existing=self.canonical(sha)
                if existing['byte_length']!=size:raise BlobError('canonical_length_mismatch')
                self.verify(existing);return existing
            def encoded_chunks():
                original=file_chunks(spool,True)
                if not externalize:yield from original;return
                for line in lines(original):
                    frame=factor(line,self.put_media)
                    yield struct.pack('>Q',len(frame));yield frame
            codec='zstd' if compress and os.environ.get('MIRROR_CODEC','zstd')!='none' else 'none'
            for attempt in range(2):
                fd,candidate=tempfile.mkstemp(dir=self.root,prefix='.incoming-')
                try:
                    with os.fdopen(fd,'wb') as out:
                        data=encoded_chunks()
                        if codec=='zstd':data=zstd_stream(data,encode=True)
                        for chunk in data:out.write(chunk)
                        out.flush();os.fsync(out.fileno())
                    if codec=='zstd' and not externalize and Path(candidate).stat().st_size>=size:
                        codec='none';Path(candidate).unlink();candidate=None;continue
                    break
                except (CodecError,OSError) as exc:
                    # Only loading/encoding zstd failures are fallback. Disk I/O
                    # and media publication errors must fail the original write.
                    Path(candidate).unlink(missing_ok=True);candidate=None
                    if isinstance(exc,CodecError) and codec=='zstd':codec='none';continue
                    raise
            relative=f'{sha[:2]}/{sha}.v2.{"media" if externalize else "raw"}.{"zst" if codec=="zstd" else "bin"}'
            path=self.root/relative;path.parent.mkdir(mode=0o700,exist_ok=True)
            record=dict(sha256=sha,byte_length=size,path=relative,compression=codec,
                        format_version=2,representation='media-lines-v2' if externalize else 'raw',
                        encoded_bytes=Path(candidate).stat().st_size)
            if path.exists():self.verify(record)
            else:
                try:os.link(candidate,path)
                except FileExistsError:self.verify(record)
                fsync_dir(path.parent);fsync_dir(self.root)
            record['encoded_bytes']=path.stat().st_size
            self.verify(record)
            # Atomic alias is durable before any fact may commit a reference.
            fd,meta=tempfile.mkstemp(dir=path.parent,prefix='.record-')
            try:
                with os.fdopen(fd,'w') as out:
                    json.dump(record,out,sort_keys=True);out.flush();os.fsync(out.fileno())
                os.replace(meta,self.canonical_path(sha));fsync_dir(path.parent)
            finally:Path(meta).unlink(missing_ok=True)
            return record
        finally:
            Path(spool).unlink(missing_ok=True)
            if candidate:Path(candidate).unlink(missing_ok=True)

    def path(self, record):
        path=(self.root/record['path']).resolve()
        if not path.is_relative_to(self.root):raise BlobError('invalid_blob_path')
        return path

    def chunks(self, record):
        original=record
        try:
            path=self.path(record)
            try:opened=open(path,'rb')
            except FileNotFoundError:
                replacement=self.canonical(record['sha256'])
                if self.path(replacement)==path:raise BlobError('blob_missing')
                if replacement['byte_length']!=record.get('byte_length',replacement['byte_length']):raise BlobError('alias_length_mismatch')
                record=replacement;path=self.path(record);opened=open(path,'rb')
            # Pin bytes before concurrent recoding unlinks a legacy pathname.
            with opened:
                codec=record.get('compression')
                if record.get('format_version',1) not in (1,2):raise BlobError('unknown_blob_version')
                if codec not in ('gzip','none','zstd'):raise BlobError('unknown_blob_codec')
                source=gzip.GzipFile(fileobj=opened,mode='rb') if codec=='gzip' else opened
                try:
                    data=iter(lambda:source.read(1024*1024),b'')
                    if codec=='zstd':data=zstd_stream(data)
                    representation=record.get('representation','raw')
                    if representation=='media-lines-v2':data=decode_frames(data,self.read_media)
                    elif representation!='raw':raise BlobError('unknown_blob_representation')
                    digest=hashlib.sha256();total=0
                    for chunk in data:
                        digest.update(chunk);total+=len(chunk);yield chunk
                    if digest.hexdigest()!=original['sha256'] or ('byte_length' in original and total!=original['byte_length']):raise BlobError('blob_corrupt')
                finally:
                    if source is not opened:source.close()
        except FileNotFoundError as exc:raise BlobError('blob_missing') from exc
        except (gzip.BadGzipFile,EOFError,CodecError) as exc:raise BlobError('blob_corrupt') from exc

    def verify(self, record):
        digest=hashlib.sha256();size=0
        for chunk in self.chunks(record):digest.update(chunk);size+=len(chunk)
        if digest.hexdigest()!=record['sha256'] or size!=record['byte_length']:raise BlobError('blob_corrupt')
        return True

    def read(self, record):
        self.verify(record);return b''.join(self.chunks(record))
