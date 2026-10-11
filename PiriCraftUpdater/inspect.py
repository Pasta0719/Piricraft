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
