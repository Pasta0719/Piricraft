"""Real GitHub staging/upload/dispatch acceptance test, always DRY_RUN.

Run ONLY from GitHub Actions with a short-lived GITHUB_TOKEN.
Does not activate a new launcher or alter update-manifest.json.
"""
import asyncio
import hashlib
import io
import json
import os
import time
import zipfile

import httpx
from app import app, GitHub


async def main():
    assert os.environ["GITHUB_ACTIONS"] == "true"
    assert os.environ["PIRICRAFT_TEST_DRY_RUN"] == "true"
    assert os.environ["PIRICRAFT_GITHUB_TOKEN"]
    capability = os.environ["PIRICRAFT_GATEWAY_CAPABILITY"]
    headers={"Authorization":"Bearer "+capability}

    name="publisher-gateway-ci-"+os.environ["GITHUB_RUN_ID"]+".jar"
    buf=io.BytesIO()
    with zipfile.ZipFile(buf,"w") as jar:
        jar.writestr("fabric.mod.json",json.dumps({
            "schemaVersion":1, "id":"publishergatewayci", "version":"1.0.0",
            "name":"Gateway CI acceptance", "environment":"client"
        }))
    payload=buf.getvalue()
    digest=hashlib.sha256(payload).hexdigest()
    async with GitHub() as github:
        before=await github.official_manifest()
    ticket=None
    try:
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url="http://gateway-in-process",timeout=90) as client:
            resp=await client.post("/api/v1/publish",headers={
                **headers,"x-mod-mode":"add","x-mod-filename":name,
                "x-mod-sha256":digest
            },content=payload)
            if resp.status_code!=202:
                raise RuntimeError("Gateway rejected real GH staging: "+str(resp.status_code)+" "+resp.text)
            ticket=resp.json()["ticket"]
            print("REAL_GATEWAY_UPLOAD_DISPATCHED",ticket,flush=True)
            for i in range(90):
                await asyncio.sleep(5)
                progress=await client.get("/api/v1/status/"+ticket,headers=headers)
                if progress.status_code!=200:
                    raise RuntimeError("Gateway status query error: "+str(progress.status_code)+" "+progress.text)
                job=progress.json()
                if job["status"]!="completed":
                    if i % 6 == 0: print("CI_BACKGROUND_BUILD",job["status"],flush=True)
                    continue
                if job["conclusion"]!="success":
                    raise RuntimeError("Gateway remote build failed "+str(job))
                print("REAL_GATEWAY_TO_GITHUB_WINDOWS_BUILD_PASSED",job["workflow_url"],flush=True)
                break
            else:
                raise TimeoutError("Gateway publishing pipeline did not complete")
        async with GitHub() as github:
            after=await github.official_manifest()
        if after!=before:raise RuntimeError("Dry run modified live automatic update manifest")
        print("LIVE_MANIFEST_UNCHANGED",flush=True)
    finally:
        if ticket:
            async with GitHub() as gh:
                try:
                    release=await gh.find_staging(ticket)
                    if release is None: raise RuntimeError("Draft staging release not found by listing")
                    await gh.delete_staging(release["id"],ticket)
                    print("STAGING_RELEASE_CLEANED",flush=True)
                except Exception as exc:
                    # Preserve cleanup failure as an explicit CI failure instead of a silent orphan.
                    raise RuntimeError("Could not clean staging release "+ticket) from exc

if __name__=="__main__":
    asyncio.run(main())
