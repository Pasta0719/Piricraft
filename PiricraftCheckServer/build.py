#!/usr/bin/env python3
"""Produce an updated PiriCraftCheck server JAR from the published v1.1.21 JAR.

This patches ONLY the 64-byte allowed SHA-256 constant in its Java class.
Unmodified ZIP entries are copied byte-for-byte after decompression.
No Java source, plugin behavior, event listeners or config values are changed.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import urllib.request
import zipfile

OLD_SHA = "322DC5AFD40A8E007D19CDD21779AA758464E6F8C31AF2EFEABD243F237008C8"
NEW_SHA = "0FA5B2C12E4E8D59D728F5485ECFC6A002CA6B04750D2E8BC775B3F0DFA2B083"
UPSTREAM = (
    "https://github.com/Pasta0719/Piricraft/releases/download/"
    "launcher-v1.1.21/PiricraftCheckServer-1.0.0.jar"
)
FILE_NAME = "PiricraftCheckServer-1.0.0.jar"


def patch(source: Path, target: Path) -> None:
    before, after = OLD_SHA.encode("ascii"), NEW_SHA.encode("ascii")
    if len(before) != 64 or len(after) != 64:
        raise ValueError("SHA-256 must be 64 ASCII hex chars")
    if hashlib.sha256(source.read_bytes()).hexdigest().upper() == NEW_SHA:
        raise ValueError("A client mod JAR was supplied instead of the Check server JAR")
    found = 0
    target.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source, "r") as incoming, zipfile.ZipFile(target, "w") as outgoing:
        for item in incoming.infolist():
            content = incoming.read(item.filename)
            if item.filename.endswith(".class"):
                count = content.count(before)
                found += count
                content = content.replace(before, after)
            outgoing.writestr(item, content)
    if found != 1:
        target.unlink(missing_ok=True)
        raise RuntimeError(f"Expected old allowed SHA in exactly one class constant; found {found}. "
                           "The upstream version may differ. Nothing was published.")
    with zipfile.ZipFile(target) as produced:
        classes = [produced.read(name) for name in produced.namelist() if name.endswith(".class")]
        assert sum(c.count(after) for c in classes) == 1, "New allowed SHA not present"
        assert all(before not in c for c in classes), "Old allowed SHA remains"
        assert produced.testzip() is None, "Corrupted server plugin JAR"
    print(f"CHECK_SERVER_JAR={target.resolve()}")
    print(f"ALLOWED_NEW_MOD_SHA256={NEW_SHA}")
    print(f"CHECK_SERVER_JAR_SHA256={hashlib.sha256(target.read_bytes()).hexdigest().upper()}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", type=Path, help="Existing v1.1.21 PiricraftCheckServer-1.0.0.jar")
    ap.add_argument("--output", type=Path, default=Path(__file__).parent / "dist" / FILE_NAME)
    args = ap.parse_args()
    if args.source:
        source = args.source
    else:
        source = Path(__file__).parent / "dist" / "upstream" / FILE_NAME
        source.parent.mkdir(parents=True, exist_ok=True)
        print("Fetching baseline plugin from official v1.1.21 release")
        urllib.request.urlretrieve(UPSTREAM, source)
    patch(source, args.output)


if __name__ == "__main__":
    main()
