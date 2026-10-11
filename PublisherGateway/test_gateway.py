import base64
import hashlib
import io
import json
import os
import zipfile

import httpx
import pytest

import app as gateway


@pytest.fixture(autouse=True)
def prepared(monkeypatch):
    monkeypatch.setenv("PIRICRAFT_GATEWAY_CAPABILITY", "testing-authorization-only-not-real-" + "x"*32)
    monkeypatch.setenv("PIRICRAFT_GITHUB_TOKEN", "dummy-test-github-token")
    gateway._recent_uploads.clear()


@pytest.fixture
def client():
    return httpx.AsyncClient(transport=httpx.ASGITransport(app=gateway.app),
                             base_url="http://localhost")


def make_jar(mod_id="test_mod"):
    content = io.BytesIO()
    with zipfile.ZipFile(content, "w") as jar:
        jar.writestr("fabric.mod.json", json.dumps({"schemaVersion":1, "id":mod_id, "version":"1.0"}))
    return content.getvalue()


def auth():
    return {"Authorization": "Bearer testing-authorization-only-not-real-" + "x"*32}


@pytest.mark.asyncio
async def test_auth_required(client):
    async with client as c:
        assert (await c.get("/api/v1/mods")).status_code == 401
        assert (await c.get("/api/v1/mods",headers={"Authorization":"Bearer bad"})).status_code == 403
        assert (await c.get("/healthz")).json()["active"] is True


@pytest.mark.asyncio
async def test_source_list(client, monkeypatch):
    async def manifest(_gh):
        return {"launcher": {"version": "1.1.22"}, "files": [
            {"path":"mods/valid.jar","sha256":"0"*64},
            {"path":"other/file.txt","sha256":"f"*64}
        ]}
    monkeypatch.setattr(gateway.GitHub, "official_manifest", manifest)
    async with client as c:
        data=(await c.get("/api/v1/mods",headers=auth())).json()
    assert data["launcher"] == "1.1.22"
    assert data["mods"] == [{"path":"mods/valid.jar","sha256":"0"*64}]


@pytest.mark.asyncio
async def test_invalid_jar_never_published(client):
    async with client as c:
        result=await c.post("/api/v1/publish",
            headers={**auth(),"x-mod-mode":"add","x-mod-filename":"bad.jar","x-mod-sha256":hashlib.sha256(b"not a jar").hexdigest()},
            content=b"not a jar")
    assert result.status_code == 400


@pytest.mark.asyncio
async def test_forged_hash_rejected(client):
    async with client as c:
        result=await c.post("/api/v1/publish",
            headers={**auth(),"x-mod-mode":"add","x-mod-filename":"good.jar","x-mod-sha256":"f"*64},
            content=make_jar())
    assert result.status_code == 400


@pytest.mark.asyncio
async def test_unauthorized_before_payload(client):
    async with client as c:
        result=await c.post("/api/v1/publish",
            headers={"x-mod-mode":"add","x-mod-filename":"good.jar","x-mod-sha256":"f"*64},
            content=b"")
    assert result.status_code == 401


@pytest.mark.asyncio
async def test_real_staging_and_dispatch(client, monkeypatch):
    fake = {"calls":[]}
    async def manifest(_gh):
        return {"launcher":{"version":"1.1.22"}, "files":[{"path":"mods/old.jar","sha256":"a"*64}]}
    async def create(_gh, tag):
        fake["calls"].append(("new",tag))
        return {"id": 123, "upload_url": "https://uploads.github.com/repos/Pasta0719/Piricraft/releases/123/assets{?name,label}"}
    async def upload(_gh, release, filename, payload):
        fake["calls"].append(("upload",filename,hashlib.sha256(payload).hexdigest()))
    async def dispatch(_gh, mode, target, tag, filename, checksum):
        fake["calls"].append(("dispatch",mode,target,tag,filename,checksum))
    async def jobs(_gh):
        tag=fake["calls"][0][1]
        return {"workflow_runs":[{"name":"MOD upload / "+tag,
            "status":"completed","conclusion":"success","html_url":"https://github.com/Pasta0719/Piricraft/actions/runs/123"}]}
    for k,v in {"official_manifest":manifest,"new_release":create,"upload_asset":upload,
                "dispatch":dispatch,"jobs":jobs}.items():
        monkeypatch.setattr(gateway.GitHub,k,v)
    payload=make_jar()
    sha=hashlib.sha256(payload).hexdigest()
    async with client as c:
        created=await c.post("/api/v1/publish",headers={**auth(),"x-mod-mode":"update",
            "x-mod-target":"mods/old.jar","x-mod-filename":"new.jar","x-mod-sha256":sha},content=payload)
        assert created.status_code == 202, created.text
        ticket=created.json()["ticket"]
        assert gateway.STAGE_PATTERN.fullmatch(ticket)
        result=await c.get(f"/api/v1/status/{ticket}",headers=auth())
    assert fake["calls"][0][0]=="new"
    assert fake["calls"][1][0]=="upload"
    assert fake["calls"][2]==("dispatch","update","mods/old.jar",ticket,"new.jar",sha.upper())
    assert result.status_code==200
    assert result.json()["conclusion"]=="success"


@pytest.mark.asyncio
async def test_reject_nonofficial_replacement(client, monkeypatch):
    async def manifest(_gh):
        return {"launcher":{"version":"1.1.22"},"files":[]}
    monkeypatch.setattr(gateway.GitHub,"official_manifest",manifest)
    content=make_jar()
    async with client as c:
        result=await c.post("/api/v1/publish",headers={**auth(),"x-mod-mode":"update",
            "x-mod-target":"mods/doesnotexist.jar","x-mod-filename":"new.jar",
            "x-mod-sha256":hashlib.sha256(content).hexdigest()},content=content)
    assert result.status_code==409


@pytest.mark.asyncio
async def test_reject_dangerous_zip_path(client):
    payload=io.BytesIO()
    with zipfile.ZipFile(payload,"w") as jar:
        jar.writestr("fabric.mod.json",'{"id":"validid","version":"1"}')
        jar.writestr("../escape.bin",b"bad")
    raw=payload.getvalue()
    async with client as c:
        result=await c.post("/api/v1/publish",headers={**auth(),"x-mod-mode":"add",
            "x-mod-filename":"dangerous.jar","x-mod-sha256":hashlib.sha256(raw).hexdigest()},content=raw)
    assert result.status_code==400


@pytest.mark.asyncio
async def test_no_server_secret_refuses_use(client, monkeypatch):
    monkeypatch.delenv("PIRICRAFT_GATEWAY_CAPABILITY")
    async with client as c:
        assert (await c.get("/api/v1/mods",headers=auth())).status_code==503


@pytest.mark.asyncio
async def test_ci_config_requires_github_oidc(client):
    async with client as c:
        response=await c.post("/api/v1/ci-client-config")
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_ci_config_rejects_random_token(client, monkeypatch):
    class FakeJwks:
        def __init__(self, *args, **kwargs):
            pass
        def get_signing_key_from_jwt(self, token):
            raise gateway.jwt.PyJWKClientError("No matching signing key")
    monkeypatch.setattr(gateway.jwt,"PyJWKClient",FakeJwks)
    async with client as c:
        response=await c.post("/api/v1/ci-client-config",
            headers={"Authorization": "Bearer definitely-not-github-oidc"})
    assert response.status_code == 403
