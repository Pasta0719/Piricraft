#!/usr/bin/env python3
"""Apply the audited 0.1.3 visual/GL fix to the published 0.1.2 Fabric JAR.

Minecraft 1.21, Sodium 0.6.13, all classes other than AbyssPostProcessor,
and all non-abyss JAR contents are intentionally unchanged.
"""
import hashlib, json, sys, zipfile
from pathlib import Path

BASE_SHA = "30C4FEA3B9D05EE5910053DF23248D5A08FFD6EBB238C14920656ACD3B1FC5F3"
SHADER = "assets/piricraft_abyss/shaders/abyss.fsh"
RENDERER = "jp/piricraft/abyss/fabric/AbyssPostProcessor.class"

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError("Expected exactly one GLSL match for: " + old[:65])
    return text.replace(old, new)

def main():
    if len(sys.argv) != 4:
        raise SystemExit("Usage: patch_abyss_force_and_hand.py BASE_JAR PATCHED_CLASS OUTPUT_JAR")
    base, patched, target = (Path(v) for v in sys.argv[1:])
    assert sha(base) == BASE_SHA, "Unexpected source JAR or version"
    with zipfile.ZipFile(base) as archive:
        assert archive.testzip() is None
        shader = archive.read(SHADER).decode("utf-8")
        meta = json.loads(archive.read("fabric.mod.json"))
        assert meta["version"] == "0.1.2"
        assert meta["depends"]["minecraft"] == "1.21"
        assert meta["depends"]["sodium"] == "0.6.13"
        assert b"renderOriginal" in patched.read_bytes()
        shader = replace_once(shader,
            "    if (rayLength < 0.001) { fragColor = source; return; }",
            "    // Never alter immediate near-plane geometry, including potential first-person overlays.\n"
            "    if (rayLength < 1.5) { fragColor = source; return; }")
        shader = replace_once(shader,
            "        float forceSigma = force < 0 ? 0.0 : MediaSigma[force];",
            "        // Basic force limits distant visibility, not the clarity of nearby air.\n"
            "        float forceSigma = force < 0 ? 0.0 : MediaSigma[force];")
        shader = replace_once(shader,
            """        float sigma = forceSigma + fogSigma;
        if (sigma <= 0.0) continue;
        vec3 mediumColor = vec3(0.0);
        if (forceSigma > 0.0) mediumColor += MediaColor[force] * forceSigma;
        if (fogSigma > 0.0) mediumColor += MediaColor[fog] * fogSigma;
        mediumColor /= sigma;
        float segmentT = exp(-sigma * (finish - start));""",
            """        // Basic force: preserve the first 24 blocks without haze or a color tint.
        // Environmental FOG and CLEAR retain their independent behavior.
        float forceLength = force < 0 ? 0.0 : max(0.0, finish - max(start, 24.0));
        float fogLength = finish - start;
        float forceTau = forceSigma * forceLength;
        float fogTau = fogSigma * fogLength;
        float opticalDepth = forceTau + fogTau;
        if (opticalDepth <= 0.0) continue;
        vec3 mediumColor = vec3(0.0);
        if (forceTau > 0.0) mediumColor += vec3(0.23, 0.24, 0.25) * forceTau;
        if (fogTau > 0.0) mediumColor += MediaColor[fog] * fogTau;
        mediumColor /= opticalDepth;
        float segmentT = exp(-opticalDepth);""")
        meta["version"] = "0.1.3"
        changed = {SHADER, RENDERER, "fabric.mod.json"}
        target.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(target, "w") as output:
            for item in archive.infolist():
                payload = archive.read(item.filename)
                if item.filename == SHADER: payload = shader.encode("utf-8")
                if item.filename == RENDERER: payload = patched.read_bytes()
                if item.filename == "fabric.mod.json":
                    payload = (json.dumps(meta, ensure_ascii=False, indent=2) + "\n").encode()
                output.writestr(item, payload)
    with zipfile.ZipFile(base) as original, zipfile.ZipFile(target) as output:
        assert output.testzip() is None
        assert original.namelist() == output.namelist()
        for name in original.namelist():
            if name not in changed:
                assert original.read(name) == output.read(name), "Unexpected change to " + name
        actual = json.loads(output.read("fabric.mod.json"))
        assert actual["version"] == "0.1.3"
        assert actual["depends"] == json.loads(original.read("fabric.mod.json"))["depends"]
        assert b"glGetIntegerv" in output.read(RENDERER)
    print("PASS: 0.1.3 near-clear force, distinct fog, GL state restoration")
    print("SHA256=" + sha(target))

if __name__ == "__main__":
    main()
