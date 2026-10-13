#!/usr/bin/env python3
"""Patch verified official Abyss 0.1.4 without altering bytecode or saved region schema."""
import hashlib, json, sys, zipfile
from pathlib import Path
SOURCE_SHA = "E8776FFBFE54A99DBEEEC142B44F35DCD661217DD76517220376A6D05ADE2B54"
SHADER = "assets/piricraft_abyss/shaders/abyss.fsh"
def replace(source, a, b):
    if source.count(a) != 1:
        raise ValueError("Shader anchor missing/ambiguous: " + a[:70])
    return source.replace(a,b)
def patch(shader):
    shader=replace(shader,
'''bool insideBox(vec3 p, vec3 bmin, vec3 bmax) {
    return all(greaterThanEqual(p, bmin)) && all(lessThanEqual(p, bmax));
}''',
'''bool insideBox(vec3 p, vec3 bmin, vec3 bmax) {
    return all(greaterThanEqual(p, bmin)) && all(lessThanEqual(p, bmax));
}

// Signed distance to the closest face of an AABB: positive inside, negative outside.
// A smooth envelope replaces abrupt endpoint membership tests at layer boundaries.
float layerInterior(vec3 p, vec3 bmin, vec3 bmax) {
    vec3 inside = min(p - bmin, bmax - p);
    float inner = min(inside.x, min(inside.y, inside.z));
    vec3 outside = max(max(bmin - p, p - bmax), vec3(0.0));
    return inner >= 0.0 ? inner : -length(outside);
}

float crossEndpointWeight(vec3 p, vec3 bmin, vec3 bmax, float width) {
    // Avoid hard on/off when eyes/geometry cross a layer face.
    return smoothstep(-width, width, layerInterior(p, bmin, bmax));
}

float staticBoundaryNoise(vec3 worldPos) {
    // Spatially stable, never animated: suppress visible perfectly-flat bands.
    vec3 cell = floor(worldPos * 0.25);
    return fract(sin(dot(cell, vec3(12.9898, 78.233, 37.719))) * 43758.5453);
}''')
    shader=replace(shader,
'''        if (forceTau > 0.0) mediumColor += vec3(0.23, 0.24, 0.25) * forceTau;''',
'''        // Misty near-white force field inspired by luminous Abyss distance haze.
        // A pure color blend: no image-space blur, therefore block edges stay sharp.
        if (forceTau > 0.0) mediumColor += vec3(0.957, 0.965, 0.969) * forceTau;''')
    shader=replace(shader,
'''        if (!insideBox(CameraPosition, CrossFromMin[i], CrossFromMax[i]) || !insideBox(target, CrossToMin[i], CrossToMax[i])) continue;
        vec2 hit = rayBox(CameraPosition, invDir, CrossBoundaryMin[i], CrossBoundaryMax[i], rayLength);
        if (hit.y <= hit.x) continue;
        float blend = CrossTransition[i] <= 0.0001 ? 1.0 : smoothstep(0.0, 1.0, hit.x / CrossTransition[i]);
        float directionScale = direction.y >= 0.0 ? CrossUp[i] : CrossDown[i];
        float tau = (CrossInitialTau[i] + CrossBeyondSigma[i] * max(0.0, rayLength - hit.y)) * blend * directionScale;
        float crossT = exp(-tau);
        scatter += transmission * (1.0 - crossT) * CrossColor[i];
        transmission *= crossT;''',
'''        float width = clamp(CrossTransition[i], 6.0, 12.0);
        float fromWeight = crossEndpointWeight(CameraPosition, CrossFromMin[i], CrossFromMax[i], width);
        float toWeight = crossEndpointWeight(target, CrossToMin[i], CrossToMax[i], width);
        float endpointWeight = fromWeight * toWeight;
        if (endpointWeight < 0.0001) continue;

        // The depth buffer ends exactly at a block face. Give solid surfaces a
        // conservative 5 cm clearance so coplanar boundary/geometry cannot shimmer.
        float stableLimit = max(0.0, rayLength - 0.05);
        vec2 hit = rayBox(CameraPosition, invDir, CrossBoundaryMin[i], CrossBoundaryMax[i], stableLimit);
        if (hit.y <= hit.x) continue;
        float boundarySpan = hit.y - hit.x;
        float stableDepth = smoothstep(0.0, width, boundarySpan);
        float onward = max(0.0, stableLimit - hit.x);
        float fade = smoothstep(0.0, width, onward) * stableDepth;
        // Tiny spatial dither, not temporal noise or a screen-space blur.
        vec3 midpoint = CameraPosition + direction * (hit.x + hit.y) * 0.5;
        float natural = mix(0.98, 1.02, staticBoundaryNoise(midpoint));
        float directionScale = direction.y >= 0.0 ? CrossUp[i] : CrossDown[i];
        float tau = (CrossInitialTau[i] + CrossBeyondSigma[i] * max(0.0, stableLimit - hit.y))
            * fade * endpointWeight * natural * directionScale;
        float crossT = exp(-tau);
        // Render the boundary as soft white air rather than an opaque surface.
        vec3 boundaryColor = mix(CrossColor[i], vec3(1.0), 0.72);
        scatter += transmission * (1.0 - crossT) * boundaryColor;
        transmission *= crossT;''')
    return shader
def main():
    if len(sys.argv)!=3: raise SystemExit("Usage: script BASE_0.1.4.jar OUT_0.1.5.jar")
    base,dest=map(Path,sys.argv[1:])
    assert hashlib.sha256(base.read_bytes()).hexdigest().upper()==SOURCE_SHA,"Unexpected published base JAR"
    with zipfile.ZipFile(base) as src,zipfile.ZipFile(dest,"w") as dst:
        assert src.testzip() is None
        metadata=json.loads(src.read("fabric.mod.json"))
        assert metadata["version"]=="0.1.4"
        metadata["version"]="0.1.5"
        original=src.read(SHADER).decode()
        fixed=patch(original)
        assert "vec3(0.23, 0.24, 0.25)" not in fixed
        assert "crossEndpointWeight" in fixed and "stableLimit" in fixed
        for e in src.infolist():
            data=src.read(e.filename)
            if e.filename==SHADER:data=fixed.encode()
            if e.filename=="fabric.mod.json":data=(json.dumps(metadata,ensure_ascii=False,indent=2)+"\n").encode()
            dst.writestr(e,data)
    with zipfile.ZipFile(base) as src,zipfile.ZipFile(dest) as dst:
        assert dst.testzip() is None and src.namelist()==dst.namelist()
        for name in src.namelist():
            if name not in (SHADER,"fabric.mod.json"):assert src.read(name)==dst.read(name),name
        meta=json.loads(dst.read("fabric.mod.json"))
        assert meta["depends"]["minecraft"]=="1.21" and meta["depends"]["sodium"]=="0.6.13"
        assert b"renderOriginal" in dst.read("jp/piricraft/abyss/fabric/AbyssPostProcessor.class")
    print("PASS: 0.1.5 shader-only white-force and smooth stable cross-layer patch")
    print("SHA256="+hashlib.sha256(dest.read_bytes()).hexdigest().upper())
if __name__=="__main__":main()
