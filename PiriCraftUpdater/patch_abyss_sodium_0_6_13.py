#!/usr/bin/env python3
"""Port the already-published Minecraft-1.21 Abyss 0.1.1 build to Sodium 0.6.13.

This changes only the Fabric dependency metadata and the matching runtime
Sodium guard. It does not retarget Minecraft, touch other mods or strip classes.
"""
import hashlib
import json
import sys
from pathlib import Path
from zipfile import ZipFile

OLD_SHA = "A28FE463E38C917C7EB3EA71758CF6E2361DF2F3B01703191F0A5E9530F76B57"
NEW_SHA = "30C4FEA3B9D05EE5910053DF23248D5A08FFD6EBB238C14920656ACD3B1FC5F3"
GUARD = "jp/piricraft/abyss/fabric/PiriCraftAbyssClient.class"

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()

def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: patch_abyss_sodium_0_6_13.py OLD_JAR NEW_JAR")
    original, target = map(Path, sys.argv[1:])
    assert digest(original) == OLD_SHA, "Input JAR is not the audited 0.1.1 release"
    with ZipFile(original) as before:
        assert before.testzip() is None
        meta = json.loads(before.read("fabric.mod.json"))
        assert meta["id"] == "piricraft_abyss"
        assert meta["version"] == "0.1.1"
        assert meta["depends"]["minecraft"] == "1.21"
        assert meta["depends"]["sodium"] == "0.5.11"
        assert before.read(GUARD).count(b"0.5.11") == 1
        meta["version"] = "0.1.2"
        meta["depends"]["sodium"] = "0.6.13"
        target.parent.mkdir(parents=True, exist_ok=True)
        with ZipFile(target, "w") as after:
            for item in before.infolist():
                content = before.read(item.filename)
                if item.filename == "fabric.mod.json":
                    content = (json.dumps(meta, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
                elif item.filename == GUARD:
                    content = content.replace(b"0.5.11", b"0.6.13")
                after.writestr(item, content)
    assert digest(target) == NEW_SHA, "Unexpected binary differences"
    with ZipFile(original) as before, ZipFile(target) as after:
        assert after.testzip() is None
        assert before.namelist() == after.namelist()
        for name in before.namelist():
            if name not in ("fabric.mod.json", GUARD):
                assert before.read(name) == after.read(name), f"Unexpected mutation: {name}"
        new_meta = json.loads(after.read("fabric.mod.json"))
        assert new_meta["depends"]["minecraft"] == "1.21"
        assert new_meta["depends"]["sodium"] == "0.6.13"
        assert after.read(GUARD).count(b"0.6.13") == 1
    print("PASS: Minecraft 1.21, Sodium 0.6.13, Abyss 0.1.2, only two entries changed")
    print("SHA256", digest(target))

if __name__ == "__main__":
    main()
