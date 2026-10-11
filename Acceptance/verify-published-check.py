#!/usr/bin/env python3
"""Assert published Paper plugin is a valid JAR and its bytecode allowlist exactly
matches current live launcher manifest. Does not claim deployment to live server.
"""
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

jar_path, manifest_path = map(Path, sys.argv[1:3])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
expected = {r["sha256"].upper() for r in manifest["files"] if r["path"].startswith("mods/")}
assert len(expected) == len([r for r in manifest["files"] if r["path"].startswith("mods/")]), "Duplicate MOD hashes"
with zipfile.ZipFile(jar_path) as jar:
    assert jar.testzip() is None, "Corrupt Check server ZIP"
    names = jar.namelist()
    assert "jp/piricraft/check/PiricraftCheckPlugin.class" in names, "Original Check plugin missing"
    info_name = "plugin.yml" if "plugin.yml" in names else "paper-plugin.yml"
    assert info_name in names, "No Paper plugin metadata"
    info = jar.read(info_name).decode("utf-8")
    print("CHECK_PLUGIN_METADATA", info[:1300])
output = subprocess.run(["javap", "-classpath", str(jar_path), "-c", "-p",
                         "jp.piricraft.check.PiricraftCheckPlugin"],
                        text=True, capture_output=True, check=True).stdout
# Only SHA strings from the static initializer (not other strings in methods).
static_initializer = output.split("static {};", 1)
assert len(static_initializer) == 2, "Missing generated static initializer"
initializer = static_initializer[1].split("\n  }", 1)[0]
actual = re.findall(r"// String ([A-F0-9]{64})", initializer)
assert len(actual) == len(expected), (len(actual), len(expected))
assert set(actual) == expected, (
    "Modified Check allowlist differs from official MODs",
    sorted(expected - set(actual)), sorted(set(actual) - expected))
assert re.search(r"invokestatic\s+#[0-9]+\s+// InterfaceMethod java/util/Set.of",initializer), \
    "Expected immutable Java Set.of() initializer not present"
assert re.search(r"putstatic\s+#[0-9]+\s+// Field ALLOWED_HASHES", initializer), \
    "Generated allowlist not assigned to actual server Check field"
print("CHECK_SERVER_CLASS_INITIALIZER_AND_ALL_OFFICIAL_MOD_HASHES_VERIFIED",len(actual))
