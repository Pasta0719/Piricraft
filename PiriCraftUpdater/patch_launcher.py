#!/usr/bin/env python3
"""Update PiriCraft's existing .NET 10 single-file EXE without changing launcher code.

- Keeps the original native apphost, compiled WPF code and update logic
- Replaces the embedded Fabric JAR with an exact uploaded file
- Updates its embedded ModsManifest.json SHA-256
- Rewrites the .NET single-file bundle metadata and the PE managed resource pointer

Raises on any unexpected baseline/version/metadata layout; never patches a guessed location.
"""
import argparse, hashlib, io, re, struct
from pathlib import Path

BUNDLE_SIG = bytes.fromhex('8b1202b96a612038727b930214d7a03213f5b9e6efae3318ee3b2dce24b36aae')
OLD = '322DC5AFD40A8E007D19CDD21779AA758464E6F8C31AF2EFEABD243F237008C8'
NEW = '0FA5B2C12E4E8D59D728F5485ECFC6A002CA6B04750D2E8BC775B3F0DFA2B083'
ORIGINAL_EXE_SHA = '7457D259481445171ADBC945A163564AADA4DC2303DA8B2504EB15A09EE7CE69'


def hash_(b): return hashlib.sha256(b).hexdigest().upper()
def align(n,a): return (n+a-1)//a*a
def read7(b,p):
    val=0;shift=0
    while True:
        x=b[p];p+=1;val|=(x&127)<<shift
        if x<128: return val,p
        shift+=7
        if shift>35: raise ValueError('invalid bundle length')
def rstr(b,p):
    n,p=read7(b,p);return b[p:p+n].decode('utf-8'),p+n
def wstr(v):
    s=v.encode();n=len(s);arr=bytearray()
    while n>=128:arr.append((n&127)|128);n>>=7
    arr.append(n)
    return bytes(arr)+s


def get_bundle(exe):
    ix=exe.find(BUNDLE_SIG)
    assert ix>8 and exe.count(BUNDLE_SIG)==1, 'Unsupported .NET bundle format'
    hdr=struct.unpack_from('<Q',exe,ix-8)[0]
    ver,minor,n=struct.unpack_from('<III',exe,hdr)
    assert (ver,minor)==(6,0) and 5<n<1000, 'Unexpected bundle version'
    p=hdr+12;bid,p=rstr(exe,p)
    deps_off,deps_sz,config_off,config_sz,flags=struct.unpack_from('<QQQQQ',exe,p);p+=40
    entries=[]
    for _ in range(n):
        off,size,compressed=struct.unpack_from('<QQQ',exe,p);p+=24
        ty=exe[p];p+=1;path,p=rstr(exe,p)
        entries.append({'off':off,'size':size,'compressed':compressed,'type':ty,'path':path})
    assert p==len(exe),'Unexpected bytes trailing .NET manifest'
    assert entries[0]['path']=='PiriCraft.dll' and entries[0]['compressed']==0
    return ix,hdr,entries,flags,bid


def patch_managed_dll(dll_bytes,newjar):
    dll=bytearray(dll_bytes)
    oldsha=OLD.encode();newsha=NEW.encode()
    assert dll.count(oldsha)==1,'Old SHA-256 constant missing/duplicated'
    dll=dll.replace(oldsha,newsha)
    # Keep the launcher updater's AssemblyVersion and InformationalVersion coherent:
    # 1.1.22 is the new release. These two fixed-width metadata strings are
    # located inside the original managed executable and can be changed safely.
    oldver=b'1.1.21';newver=b'1.1.22'
    assert dll.count(oldver)==2,'Unexpected AssemblyInformationalVersion strings'
    dll=dll.replace(oldver,newver)
    assemblyver=bytes.fromhex('0100010015000000')
    assert dll[:134888].count(assemblyver)==1,'Ambiguous compiled assembly version'
    dll=dll.replace(assemblyver,bytes.fromhex('0100010016000000'),1)
    peoff=struct.unpack_from('<I',dll,0x3c)[0]
    assert dll[peoff:peoff+4]==b'PE\0\0'
    nsec=struct.unpack_from('<H',dll,peoff+6)[0]
    opt=peoff+24
    magic=struct.unpack_from('<H',dll,opt)[0]
    assert magic==0x20b,'Only x64 PE32+ supported'
    optsz=struct.unpack_from('<H',dll,peoff+20)[0]
    sectab=opt+optsz
    fileal,sectal=struct.unpack_from('<II',dll,opt+36)[0],struct.unpack_from('<II',dll,opt+32)[0]
    headsz=struct.unpack_from('<I',dll,opt+60)[0]
    assert sectab+(nsec+1)*40<=headsz,'No free section header; refuse unsafe patch'
    dir_offset=opt+112+14*8
    comrva,comsz=struct.unpack_from('<II',dll,dir_offset)
    assert comsz==72 and comrva>0
    sections=[]
    for i in range(nsec):
        p=sectab+i*40
        vsize,rva,rawsize,raw=struct.unpack_from('<IIII',dll,p+8)
        sections.append((p,vsize,rva,rawsize,raw))
    def offset(rva):
        for _,_,sva,sz,raw in sections:
            if sva<=rva<sva+sz:return raw+(rva-sva)
        raise ValueError(f'RVA not present in a PE section: {rva}')
    cli=offset(comrva)
    metarva,metasz=struct.unpack_from('<II',dll,cli+8)
    resrva,ressize=struct.unpack_from('<II',dll,cli+24)
    resraw=offset(resrva)
    assert ressize>4_000_000 and resraw+ressize<=len(dll)
    # Locate the EXACT old client JAR using the 4-byte CLI embedded resource prefix
    # and the old 64-character checksum (not filename heuristics).
    oldjar_candidates=[];cursor=resraw
    while True:
        pk=dll.find(b'PK\x03\x04',cursor,resraw+ressize)
        if pk<0:break
        cursor=pk+4
        if pk<resraw+4:continue
        size=struct.unpack_from('<I',dll,pk-4)[0]
        if size<1_000_000 or pk+size>resraw+ressize:continue
        resource_rel=(pk-4)-resraw
        if dll[offset(metarva):offset(metarva)+metasz].count(struct.pack('<I',resource_rel))==0:continue
        if hash_(dll[pk:pk+size])==OLD:oldjar_candidates.append((pk,size,resource_rel))
    assert len(oldjar_candidates)==1,f'Expected exactly one embedded old MOD: {oldjar_candidates}'
    pk,size,oldresrel=oldjar_candidates[0]
    # The ManifestResource.Offset field is a DWORD pointing into the CLR resource section.
    metadata=offset(metarva);metadata_end=metadata+metasz
    oldoffset=struct.pack('<I',oldresrel)
    locations=[];cursor=metadata
    while True:
        i=dll.find(oldoffset,cursor,metadata_end)
        if i<0:break
        locations.append(i);cursor=i+1
    assert len(locations)==1,f'Expected unique ManifestResource.Offset, found {locations}'
    # CLR ManifestResource.Offset is relative to the resource directory RVA.
    # Every CLI resource MUST live in one contiguous PE section; the previous
    # v1.1.22 binary violated this and crashed with BadImageFormatException.
    # Copy the full unchanged original resource directory, then append the
    # new user JAR and relocate the CLI Resources RVA to a new PE section.
    old_resources=bytes(dll[resraw:resraw+ressize])
    last=max(sections,key=lambda x:x[2])
    new_rva=align(last[2]+max(last[1],last[3]),sectal)
    new_raw=align(len(dll),fileal)
    new_rel=len(old_resources)
    payload=old_resources+struct.pack('<I',len(newjar))+newjar
    rawsz=align(len(payload),fileal)
    vsize=len(payload)
    assert new_rel+len(newjar)+4<2**32
    struct.pack_into('<I',dll,locations[0],new_rel)
    struct.pack_into('<II',dll,cli+24,new_rva,vsize)
    new_section=sectab+nsec*40
    struct.pack_into('<8sIIIIIIHHI',dll,new_section,b'.pirijar',vsize,new_rva,rawsz,new_raw,0,0,0,0,0x40000040)
    struct.pack_into('<H',dll,peoff+6,nsec+1)
    struct.pack_into('<I',dll,opt+56,align(new_rva+vsize,sectal))
    struct.pack_into('<I',dll,opt+8,struct.unpack_from('<I',dll,opt+8)[0]+rawsz)
    struct.pack_into('<I',dll,opt+64,0)
    dll.extend(b'\x00'*(new_raw-len(dll)))
    dll.extend(payload)
    dll.extend(b'\x00'*(rawsz-len(payload)))
    assert dll[new_raw+new_rel:new_raw+new_rel+4]==struct.pack('<I',len(newjar))
    assert hash_(dll[new_raw+new_rel+4:new_raw+new_rel+4+len(newjar)])==NEW
    return bytes(dll)


def patch_exe(exe,newjar):
    ix,hdr,entries,flags,bundleid=get_bundle(exe)
    first=entries[0]['off']
    end=first+entries[0]['size']
    olddll=exe[first:end]
    dll=patch_managed_dll(olddll,newjar)
    host=bytearray(exe[:first]);manifest_entries=[]
    out=io.BytesIO()
    out.write(host)
    for item in entries:
        payload=dll if item['path']=='PiriCraft.dll' else exe[item['off']:item['off']+(item['compressed'] or item['size'])]
        if item['path']=='PiriCraft.deps.json':
            assert item['compressed']==0
            assert payload.count(b'PiriCraft/1.1.21')==2
            payload=payload.replace(b'PiriCraft/1.1.21',b'PiriCraft/1.1.22')
        offset=out.tell()
        out.write(payload)
        manifest_entries.append((offset,len(payload) if item['path']=='PiriCraft.dll' else item['size'],item['compressed'],item['type'],item['path']))
    newhdr=out.tell()
    # New bundle ID forces .NET's extraction cache to be versioned for this build.
    newid=hashlib.sha256(dll).hexdigest()[:12]
    deps=next((x for x in manifest_entries if x[4]=='PiriCraft.deps.json'),None)
    config=next((x for x in manifest_entries if x[4]=='PiriCraft.runtimeconfig.json'),None)
    out.write(struct.pack('<III',6,0,len(entries)))
    out.write(wstr(newid))
    out.write(struct.pack('<QQQQQ',deps[0] if deps else 0,deps[1] if deps else 0,config[0] if config else 0,config[1] if config else 0,flags))
    for off,size,compressed,ty,path in manifest_entries:
        out.write(struct.pack('<QQQB',off,size,compressed,ty))
        out.write(wstr(path))
    answer=bytearray(out.getvalue())
    struct.pack_into('<Q',answer,ix-8,newhdr)
    # Confirm complete bundle can be reparsed and every untouched embedded payload matches.
    _,_,check_entries,_,_=get_bundle(answer)
    assert check_entries[0]['size']==len(dll)
    for a,b in zip(check_entries,entries):
        assert a['path']==b['path'] and a['type']==b['type']
        if b['path'] not in ('PiriCraft.dll','PiriCraft.deps.json'):
            n=b['compressed'] or b['size']
            assert answer[a['off']:a['off']+n]==exe[b['off']:b['off']+n],b['path']
    return bytes(answer)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--input',type=Path,required=True)
    ap.add_argument('--client-mod',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True)
    args=ap.parse_args()
    exe=args.input.read_bytes();newjar=args.client_mod.read_bytes()
    assert hash_(exe)==ORIGINAL_EXE_SHA,f'Wrong EXE: expected official v1.1.21, got {hash_(exe)}'
    assert hash_(newjar)==NEW,'JAR checksum mismatch: wrong MOD file'
    result=patch_exe(exe,newjar)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes(result)
    print('EXE:',args.output,'SIZE',len(result),'SHA256',hash_(result))
    print('Fabric JAR SHA-256:',hash_(newjar))

if __name__=='__main__':main()