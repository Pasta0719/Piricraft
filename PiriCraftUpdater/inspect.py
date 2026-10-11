"""Diagnostic: inspect the existing published EXE without modifying it."""
from pathlib import Path
import hashlib
import struct
import zipfile

p=Path("PiriCraft.exe")
b=p.read_bytes()
print("EXE_SIZE",len(b))
print("EXE_SHA256",hashlib.sha256(b).hexdigest().upper())
a={
"OLD_SHA":b"322DC5AFD40A8E007D19CDD21779AA758464E6F8C31AF2EFEABD243F237008C8",
"FILE_NAME":b"piri-juggler-fabric-1.0.0.jar",
"EMBEDDED_RESOURCE":b"PiriCraft.Mods.pirijuggler.jar",
"MANIFEST_RESOURCE":b"PiriCraft.ModsManifest.json",
"BASELINE_VERSION":b"1.1.21",
"ZIP_LOCAL":b"PK\x03\x04",
"BUNDLE_SIGNATURE":bytes.fromhex("8b1202b96fb64bcb8e698fc51dfd446c05d72f9eb5a6185e0217618a66cfca9d"),
}
for n,v in a.items():
 at=b.find(v)
 print("SIGNATURE",n,"count",b.count(v),"first",at)
 if n=="BUNDLE_SIGNATURE" and at>=8:
  x=struct.unpack_from("<Q",b,at-8)[0]
  print("BUNDLE_HEADER_CANDIDATE",x,"valid",0<x<len(b),"near",b[x:x+40].hex() if 0<x<len(b) else "")
print("MAGIC",b[:64].hex())

# Examine PE headers and the embedded MOD resource boundary (no modification).
lfanew=struct.unpack_from("<I",b,0x3c)[0]
machine,sections=struct.unpack_from("<HH",b,lfanew+4)
optional_size=struct.unpack_from("<H",b,lfanew+20)[0]
opt=lfanew+24
magic=struct.unpack_from("<H",b,opt)[0]
dir_off=opt+(112 if magic==0x20B else 96)
com_rva,com_size=struct.unpack_from("<II",b,dir_off+14*8)
print("PE_DETAILS",{"offset":lfanew,"machine":hex(machine),"sections":sections,"pe_magic":hex(magic),"com_descriptor_rva":hex(com_rva),"com_size":com_size})
for idx in range(sections):
 off=opt+optional_size+idx*40
 name=b[off:off+8].rstrip(b"\\0").decode("ascii","replace")
 vsize,rva,rawsize,rawptr=struct.unpack_from("<IIII",b,off+8)
 print("PE_SECTION",idx,name,hex(rva),hex(rawptr),rawsize,"end",rawptr+rawsize)
raw_hash=b.find(a["OLD_SHA"])
print("OLD_HASH_NEAR_HEX",b[raw_hash-64:raw_hash+100].hex())
pos=b.find(a["ZIP_LOCAL"])
print("FIRST_ZIP_NEAR_HEX",b[pos-120:pos+70].hex())
print("TAIL_128",b[-128:].hex())
