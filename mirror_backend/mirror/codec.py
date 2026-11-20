"""Storage v2: exact bytes, reversible media references, independent codec policy."""
import base64
import ctypes
import ctypes.util
import hashlib
import json
import os
import struct

class CodecError(ValueError):
    pass

_lib = None

def lib():
    global _lib
    if _lib is None:
        _lib = ctypes.CDLL(os.environ.get('MIRROR_ZSTD_LIBRARY') or ctypes.util.find_library('zstd') or 'libzstd.so.1')
        for name, args, result in (
            ('ZSTD_compressBound',[ctypes.c_size_t],ctypes.c_size_t),
            ('ZSTD_compress',[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t,ctypes.c_int],ctypes.c_size_t),
            ('ZSTD_decompress',[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t],ctypes.c_size_t),
            ('ZSTD_isError',[ctypes.c_size_t],ctypes.c_uint)):
            f=getattr(_lib,name);f.argtypes=args;f.restype=result
    return _lib

def checked(n):
    if lib().ZSTD_isError(n):
        raise CodecError('zstd_error')
    return n

def pack(raw, level=None):
    # Only codec failure falls back. Object, transaction and disk errors propagate.
    level=int(os.environ.get('MIRROR_ZSTD_LEVEL','3')) if level is None else level
    if os.environ.get('MIRROR_CODEC','zstd') == 'none' or len(raw)<128:
        return 'none', raw
    try:
        z=lib();out=ctypes.create_string_buffer(z.ZSTD_compressBound(len(raw)))
        n=checked(z.ZSTD_compress(out,len(out),raw,len(raw),level))
        return ('zstd',out.raw[:n]) if n<len(raw) else ('none',raw)
    except (CodecError,OSError):
        import logging
        logging.getLogger(__name__).warning('zstd_encode_failed_using_v2_none')
        return 'none',raw

def unpack(codec, data, length):
    if codec=='none':
        out=bytes(data)
    elif codec=='zstd':
        buf=ctypes.create_string_buffer(max(1,length))
        n=checked(lib().ZSTD_decompress(buf,len(buf),bytes(data),len(data)))
        out=buf.raw[:n]
    else:
        raise CodecError('unknown_codec')
    if len(out)!=length:raise CodecError('encoded_length_mismatch')
    return out

MAGIC=b'AGTP2\0'
MARKER_SIZE=76

def tokens(raw):
    pos=0
    while True:
        start=raw.find(b'"',pos)
        if start<0:return
        end=start+1
        while True:
            end=raw.find(b'"',end)
            if end<0:return
            p=end-1
            while p>=start and raw[p]==92:p-=1
            if (end-1-p)%2==0:break
            end+=1
        yield start,end+1
        pos=end+1

def factor(raw, save_media):
    changes=[]
    if b';base64,' in raw or b'"file_data"' in raw:
        for start,end in tokens(raw):
            if end-start<1024:continue
            token=raw[start+1:end-1];body_start=None
            if token.startswith(b'data:'):
                sep=token.find(b';base64,',0,512)
                if sep>=0:body_start=start+1+sep+8
            elif b'"file_data"' in raw[max(0,start-64):start]:
                body_start=start+1
            if body_start is None:continue
            body=raw[body_start:end-1]
            try:
                media=base64.b64decode(body,validate=True)
                if base64.b64encode(media)!=body:continue
            except (ValueError,base64.binascii.Error):continue
            sha=hashlib.sha256(media).digest()
            save_media(sha.hex(),media) # persistence errors are never codec fallback
            changes.append((body_start,end-1,sha))
    fragments=[];refs=[];pos=0;offset=0
    for start,end,sha in changes:
        literal=raw[pos:start];marker=b'~agt-media:'+sha.hex().encode()+b'~'
        fragments.extend((literal,marker));offset+=len(literal)
        refs.append((offset,sha));offset+=len(marker);pos=end
    fragments.append(raw[pos:]);recipe=b''.join(fragments)
    return MAGIC+struct.pack('>QI',len(recipe),len(refs))+recipe+b''.join(struct.pack('>Q',off)+sha for off,sha in refs)

def rebuild(frame, read_media):
    if len(frame)<18 or frame[:6]!=MAGIC:raise CodecError('invalid_v2_frame')
    n,count=struct.unpack('>QI',frame[6:18])
    if 18+n+40*count!=len(frame):raise CodecError('invalid_reference_frame_length')
    recipe=frame[18:18+n];out=[];pos=0
    for i in range(count):
        off=18+n+40*i;offset=struct.unpack('>Q',frame[off:off+8])[0];sha=frame[off+8:off+40]
        marker=b'~agt-media:'+sha.hex().encode()+b'~'
        if offset<pos or recipe[offset:offset+76]!=marker:raise CodecError('invalid_media_offset')
        media=read_media(sha.hex())
        if hashlib.sha256(media).digest()!=sha:raise CodecError('media_sha_mismatch')
        out.extend((recipe[pos:offset],base64.b64encode(media)));pos=offset+76
    out.append(recipe[pos:]);return b''.join(out)

class PayloadCodec:
    def __init__(self, blobs):self.blobs=blobs
    def encode(self, raw):
        try:lib()
        except OSError:
            import logging
            logging.getLogger(__name__).warning('zstd_backend_unavailable_using_literal_v2_none')
            frame=MAGIC+struct.pack('>QI',len(raw),0)+raw
            codec,data='none',frame
        else:
            frame=factor(raw,self.blobs.put_media)
            codec,data=pack(frame)
        return dict(format_version=2,payload_codec=codec,original_length=len(raw),
                    original_bytes_sha256=hashlib.sha256(raw).digest(),encoded_length=len(frame),encoded_payload=data)
    def decode(self, row):
        if row['format_version']==1:
            value=row['raw_text']
            if value is None:raise CodecError('missing_v1_payload')
            return value.encode('utf-8')
        if row['format_version']!=2:raise CodecError('unknown_format_version')
        frame=unpack(row['payload_codec'],row['encoded_payload'],row['encoded_length'])
        raw=rebuild(frame,self.blobs.read_media)
        if len(raw)!=row['original_length'] or hashlib.sha256(raw).digest()!=bytes(row['original_bytes_sha256']):
            raise CodecError('original_payload_mismatch')
        return raw
    def payload(self, row):return json.loads(self.decode(row))

FIELDS='format_version,payload_codec,original_length,original_bytes_sha256,encoded_length,encoded_payload'
def payload_columns(alias=''):
    prefix=alias+'.' if alias else ''
    return ','.join(prefix+k for k in FIELDS.split(','))+','+prefix+'raw_payload::text AS raw_text'

class _In(ctypes.Structure):
    _fields_=[('src',ctypes.c_void_p),('size',ctypes.c_size_t),('pos',ctypes.c_size_t)]
class _Out(ctypes.Structure):
    _fields_=[('dst',ctypes.c_void_p),('size',ctypes.c_size_t),('pos',ctypes.c_size_t)]

def zstd_stream(chunks, encode=False, level=None):
    try:z=lib()
    except OSError as exc:raise CodecError('zstd_library_unavailable') from exc
    p=ctypes.c_void_p;s=ctypes.c_size_t
    defs=[('ZSTD_createCStream',[],p),('ZSTD_createDStream',[],p),
          ('ZSTD_initCStream',[p,ctypes.c_int],s),('ZSTD_initDStream',[p],s),
          ('ZSTD_compressStream',[p,ctypes.POINTER(_Out),ctypes.POINTER(_In)],s),
          ('ZSTD_decompressStream',[p,ctypes.POINTER(_Out),ctypes.POINTER(_In)],s),
          ('ZSTD_endStream',[p,ctypes.POINTER(_Out)],s),
          ('ZSTD_freeCStream',[p],s),('ZSTD_freeDStream',[p],s)]
    for name,args,result in defs:
        f=getattr(z,name);f.argtypes=args;f.restype=result
    ctx=z.ZSTD_createCStream() if encode else z.ZSTD_createDStream()
    if not ctx:raise CodecError('zstd_context_failed')
    try:
        if encode:checked(z.ZSTD_initCStream(ctx,int(os.environ.get('MIRROR_ZSTD_LEVEL','3')) if level is None else level))
        else:checked(z.ZSTD_initDStream(ctx))
        buffer=ctypes.create_string_buffer(262144);remaining=1
        for chunk in chunks:
            src=ctypes.create_string_buffer(chunk);inp=_In(ctypes.cast(src,p),len(chunk),0)
            while inp.pos<inp.size:
                out=_Out(ctypes.cast(buffer,p),len(buffer),0)
                remaining=checked((z.ZSTD_compressStream if encode else z.ZSTD_decompressStream)(ctx,ctypes.byref(out),ctypes.byref(inp)))
                if out.pos:yield ctypes.string_at(buffer,out.pos)
        if encode:
            while True:
                out=_Out(ctypes.cast(buffer,p),len(buffer),0)
                remaining=checked(z.ZSTD_endStream(ctx,ctypes.byref(out)))
                if out.pos:yield ctypes.string_at(buffer,out.pos)
                if remaining==0:break
        elif remaining!=0:raise CodecError('truncated_zstd_stream')
    finally:
        (z.ZSTD_freeCStream if encode else z.ZSTD_freeDStream)(ctx)

def decoded_dict_row(cursor):
    """Explicit encoded-field projections hydrate raw for existing Python consumers.

    SQL callers must select the version/codec fields, or use SELECT raw_facts.*.
    SQL raw_payload::text remains the original v1 column, never silently rewritten.
    """
    from psycopg.rows import dict_row
    make=dict_row(cursor)
    def row(values):
        value=make(values)
        if value.get('format_version')==2 and all(k in value for k in FIELDS.split(',')):
            codec=getattr(cursor.connection,'_mirror_codec',None)
            if codec is None:
                from .blob import BlobStore
                codec=PayloadCodec(BlobStore(os.environ.get('MIRROR_BLOBS','/home/spirit/.local/state/thread-mirror/objects')))
                cursor.connection._mirror_codec=codec
            value['raw_payload']=codec.payload(value)
        return value
    return row
