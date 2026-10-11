#!/usr/bin/env python3
"""Publish validated launcher v1.1.22 into the EXISTING PiriCraft auto-update feed.
Call only AFTER the GitHub Release contains both EXE and Check server JAR.
"""
import base64
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

NEW_VERSION="1.1.22"
OLD_VERSION="1.1.21"
NEW_MOD_SHA="0FA5B2C12E4E8D59D728F5485ECFC6A002CA6B04750D2E8BC775B3F0DFA2B083"
OLD_MOD_SHA="322DC5AFD40A8E007D19CDD21779AA758464E6F8C31AF2EFEABD243F237008C8"
PATH="mods/piri-juggler-fabric-1.0.0.jar"
EXE=Path(sys.argv[1] if len(sys.argv)>1 else "dist/PiriCraft.exe")
REPO=os.environ.get("GITHUB_REPOSITORY","Pasta0719/Piricraft")
URL=f"https://github.com/{REPO}/releases/download/launcher-v{NEW_VERSION}/PiriCraft.exe"
API=f"repos/{REPO}/contents/update-manifest.json"

def gh(*args):
    p=subprocess.run(["gh",*args],capture_output=True,text=True,check=True)
    return p.stdout

def main():
    binary=EXE.read_bytes()
    digest=hashlib.sha256(binary).hexdigest().upper()
    # The .NET bundle produced by patch_launcher.py carries these fixed fields.
    assert len(binary)>100_000_000, "Unexpectedly small launcher binary"
    # Never publish a broken or unavailable release URL in the auto-update feed.
    data=json.loads(gh("release","view",f"launcher-v{NEW_VERSION}","--repo",REPO,
                       "--json","assets"))
    asset=[a for a in data["assets"] if a["name"]=="PiriCraft.exe"]
    assert len(asset)==1 and int(asset[0]["size"])==len(binary), "EXE release asset missing / size mismatch"
    assert any(a["name"]=="PiricraftCheckServer-1.0.0.jar" for a in data["assets"]), "Check server asset missing"

    current=json.loads(gh("api",API))
    obj=json.loads(base64.b64decode(current["content"]))
    manifest=obj["launcher"]
    assert manifest["version"] in (OLD_VERSION,NEW_VERSION), "Unexpected newer auto-update version"
    assert len([x for x in obj["files"] if x.get("path")==PATH])==1, "Mod entry not unique"
    mod=next(x for x in obj["files"] if x.get("path")==PATH)
    assert mod["sha256"] in (OLD_MOD_SHA,NEW_MOD_SHA), "Conflicting MOD SHA"
    assert mod.get("resource")=="PiriCraft.Mods.pirijuggler.jar", "Embedded MOD resource mapping changed"
    manifest.update(version=NEW_VERSION,url=URL,sha256=digest,size=len(binary))
    mod["sha256"]=NEW_MOD_SHA
    updated=json.dumps(obj,ensure_ascii=False,indent=2)+"\n"
    encoded=base64.b64encode(updated.encode("utf-8")).decode("ascii")
    gh("api",API,"-X","PUT",
       "-f",f"sha={current['sha']}",
       "-f","message=Enable PiriCraft v1.1.22 automatic update and new Fabric MOD SHA-256",
       "-f",f"content={encoded}")
    # Read back what the updater consumes instead of trusting the PUT alone.
    remote=json.loads(gh("api",API))
    confirmed=json.loads(base64.b64decode(remote["content"]))
    assert confirmed["launcher"]==manifest
    assert next(x for x in confirmed["files"] if x.get("path")==PATH)["sha256"]==NEW_MOD_SHA
    print("AUTO_UPDATE_ENABLED",NEW_VERSION,digest,len(binary),URL)

if __name__=="__main__":main()
