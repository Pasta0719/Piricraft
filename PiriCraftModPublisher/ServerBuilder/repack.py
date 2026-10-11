#!/usr/bin/env python3
"""Reassemble existing .NET single-file apphost with Cecil-edited PiriCraft.dll."""
import argparse, hashlib, io, struct, sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/"PiriCraftUpdater"))
from patch_launcher import get_bundle, wstr

def repack(exe, dll, old_version, new_version):
    ix,hdr,entries,flags,bid=get_bundle(exe)
    out=io.BytesIO()
    out.write(exe[:entries[0]['off']])
    rewritten=[]
    for ent in entries:
        path=ent['path']
        content=dll if path=='PiriCraft.dll' else exe[ent['off']:ent['off']+(ent['compressed'] or ent['size'])]
        compressed=0 if path=='PiriCraft.dll' else ent['compressed']
        if path=='PiriCraft.deps.json':
            if compressed: raise ValueError("Compressed deps not supported")
            target=("PiriCraft/"+old_version).encode()
            replacement=("PiriCraft/"+new_version).encode()
            if target not in content:raise ValueError("Dependency manifest version mismatch")
            content=content.replace(target,replacement)
        offset=out.tell()
        out.write(content)
        rewritten.append((offset,len(content) if not compressed else ent['size'],compressed,ent['type'],path))
    new_hdr=out.tell()
    new_id=hashlib.sha256(dll).hexdigest()[:20]
    deps=next((x for x in rewritten if x[4]=='PiriCraft.deps.json'),None)
    config=next((x for x in rewritten if x[4]=='PiriCraft.runtimeconfig.json'),None)
    out.write(struct.pack('<III',6,0,len(rewritten)))
    out.write(wstr(new_id))
    out.write(struct.pack('<QQQQQ',deps[0] if deps else 0,deps[1] if deps else 0,config[0] if config else 0,config[1] if config else 0,flags))
    for off,size,compressed,kind,path in rewritten:
        out.write(struct.pack('<QQQB',off,size,compressed,kind))
        out.write(wstr(path))
    result=bytearray(out.getvalue())
    struct.pack_into('<Q',result,ix-8,new_hdr)
    _,_,new_entries,_,_=get_bundle(result)
    assert len(new_entries)==len(entries)
    for a,b in zip(new_entries,entries):
        assert a['path']==b['path']
        if b['path'] not in ('PiriCraft.dll','PiriCraft.deps.json'):
            n=b['compressed'] or b['size']
            assert result[a['off']:a['off']+n]==exe[b['off']:b['off']+n],b['path']
    return result

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--base',required=True)
    parser.add_argument('--dll',required=True)
    parser.add_argument('--out',required=True)
    parser.add_argument('--old',required=True)
    parser.add_argument('--new',required=True)
    args=parser.parse_args()
    target=Path(args.out)
    target.parent.mkdir(parents=True,exist_ok=True)
    result=repack(Path(args.base).read_bytes(),Path(args.dll).read_bytes(),args.old,args.new)
    target.write_bytes(result)
    print('REPACKED_EXE',len(result),hashlib.sha256(result).hexdigest().upper())
