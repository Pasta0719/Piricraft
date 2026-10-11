"""PiriCraft standalone publisher gateway.

The Windows client carries no GitHub credential. The server accepts an explicitly
limited publisher capability, stages one validated Fabric JAR and dispatches the
existing fail-closed GitHub Actions publishing pipeline.
"""
from __future__ import annotations

import base64
from collections import deque
from datetime import datetime, timezone
import hashlib
import hmac
import io
import jwt
import json
import logging
import os
import re
import secrets
import threading
import time
from urllib.parse import urlsplit
import zipfile

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse

REPO = "Pasta0719/Piricraft"
MAX_JAR_BYTES = 64 * 1024 * 1024
MAX_ZIP_UNCOMPRESSED = 256 * 1024 * 1024
MAX_ZIP_ENTRIES = 5000
STAGE_PATTERN = re.compile(r"^publisher-input-[a-f0-9]{24}$")
PATH_PATTERN = re.compile(r"^mods/[^/]+[.]jar$", flags=re.I)
FILENAME_PATTERN = re.compile(r"^[^/]+[.]jar$", flags=re.I)
logging.basicConfig(level=logging.INFO)
log = logging.getLogger("piricraft.publisher.gateway")
app = FastAPI(title="PiriCraft Publisher Gateway", docs_url=None, redoc_url=None)
_upload_lock = threading.Lock()
_recent_uploads: deque[float] = deque()

class GitHubError(Exception):
    pass

def require_capability(authorization: str | None):
    expected = os.environ.get("PIRICRAFT_GATEWAY_CAPABILITY", "")
    if len(expected) < 32:
        raise HTTPException(503, "Publisher gateway has not been activated")
    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(401, "Publisher capability required")
    supplied = authorization[7:]
    if not hmac.compare_digest(supplied.encode("utf-8"), expected.encode("utf-8")):
        raise HTTPException(403, "Publisher capability rejected")

def check_upload_rate():
    now = time.monotonic()
    with _upload_lock:
        while _recent_uploads and now - _recent_uploads[0] > 3600:
            _recent_uploads.popleft()
        if len(_recent_uploads) >= 24:
            raise HTTPException(429, "Upload hourly limit reached")
        _recent_uploads.append(now)

def verify_jar(data: bytes, filename: str):
    if not FILENAME_PATTERN.fullmatch(filename) or chr(92) in filename or filename.startswith(".") or len(filename) > 160:
        raise HTTPException(400, "Invalid JAR filename")
    try:
        with zipfile.ZipFile(io.BytesIO(data), "r") as jar:
            entries = jar.infolist()
            if len(entries) > MAX_ZIP_ENTRIES:
                raise HTTPException(400, "Too many ZIP entries")
            if sum(entry.file_size for entry in entries) > MAX_ZIP_UNCOMPRESSED:
                raise HTTPException(400, "Excessive ZIP expansion")
            for entry in entries:
                entry_name = entry.filename.replace(chr(92), "/")
                if entry_name.startswith("/") or any(part == ".." for part in entry_name.split("/")):
                    raise HTTPException(400, "Unsafe ZIP path")
            if jar.testzip() is not None:
                raise HTTPException(400, "Invalid ZIP checksums")
            if "fabric.mod.json" not in jar.namelist():
                raise HTTPException(400, "Not a Fabric MOD JAR (fabric.mod.json missing)")
            meta = json.loads(jar.read("fabric.mod.json"))
            if not isinstance(meta, dict) or not isinstance(meta.get("id"), str):
                raise HTTPException(400, "Invalid fabric.mod.json")
            if len(meta["id"]) > 64 or not re.fullmatch(r"[a-z][a-z0-9_-]{1,63}", meta["id"]):
                raise HTTPException(400, "Invalid Fabric MOD identifier")
    except zipfile.BadZipFile:
        raise HTTPException(400, "Invalid JAR/ZIP file")
    except (ValueError, json.JSONDecodeError, UnicodeDecodeError):
        raise HTTPException(400, "Invalid fabric.mod.json")

def get_secret(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise HTTPException(503, "Publisher gateway has not been configured")
    return value

class GitHub:
    def __init__(self):
        self.token = get_secret("PIRICRAFT_GITHUB_TOKEN")
        self.client = httpx.AsyncClient(timeout=httpx.Timeout(30.0, connect=10.0), follow_redirects=False)

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        await self.client.aclose()

    async def call(self, method: str, endpoint: str, *, json_data=None, content=None, extra_headers=None):
        url = endpoint if endpoint.startswith("https://") else "https://api.github.com" + endpoint
        headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + self.token,
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "PiriCraft-Publisher-Gateway",
        }
        if extra_headers:
            headers.update(extra_headers)
        try:
            response = await self.client.request(method, url, headers=headers, json=json_data, content=content)
        except httpx.RequestError as exc:
            raise GitHubError("GitHub connection failed") from exc
        if response.status_code not in (200, 201, 202, 204):
            log.warning("GitHub call %s %s failed HTTP %s", method, urlsplit(url).path, response.status_code)
            raise GitHubError("GitHub returned HTTP " + str(response.status_code))
        if response.status_code == 204:
            return None
        return response.json()

    async def official_manifest(self):
        doc = await self.call("GET", f"/repos/{REPO}/contents/update-manifest.json")
        raw = base64.b64decode(doc["content"]).decode("utf-8")
        return json.loads(raw)

    async def new_release(self, tag: str):
        return await self.call("POST", f"/repos/{REPO}/releases", json_data={
            "tag_name": tag,
            "target_commitish": "main",
            "name": "Publisher staged upload",
            "body": "Temporary publisher input, not a public release",
            "draft": True,
            "prerelease": True,
        })

    async def upload_asset(self, release: dict, filename: str, content: bytes):
        # Filename is validated to a plain basename; use the QueryParams serializer.
        upload_url = release["upload_url"].split("{", 1)[0] + "?" + str(httpx.QueryParams({"name": filename}))
        return await self.call("POST", upload_url, content=content, extra_headers={
            "Content-Type": "application/java-archive",
            "Accept": "application/vnd.github+json",
        })

    async def dispatch(self, mode: str, target: str, tag: str, filename: str, sha: str):
        return await self.call("POST", f"/repos/{REPO}/actions/workflows/publish-mod-from-app.yml/dispatches",
            json_data={"ref": "main", "inputs": {
                "mode": mode, "target": target, "stage_tag": tag,
                "filename": filename, "sha256": sha,
                "dry_run": ("true" if os.environ.get("GITHUB_ACTIONS") == "true"
                            and os.environ.get("PIRICRAFT_TEST_DRY_RUN") == "true" else "false"),
            }})

    async def jobs(self):
        return await self.call("GET", f"/repos/{REPO}/actions/workflows/publish-mod-from-app.yml/runs?event=workflow_dispatch&per_page=100")

    async def delete_staging(self, release_id: int, tag: str):
        await self.call("DELETE", f"/repos/{REPO}/releases/{release_id}")
        # Draft releases do not necessarily create their Git tag until published.
        try:
            await self.call("DELETE", f"/repos/{REPO}/git/refs/tags/{tag}")
        except GitHubError:
            log.info("Staging release deleted; its draft tag may not exist: %s", tag)

    async def find_staging(self, tag: str):
        # GitHub's /releases/tags/{tag} can return 404 for DRAFT releases.
        listing = await self.call("GET", f"/repos/{REPO}/releases?per_page=100")
        return next((r for r in listing if r.get("tag_name") == tag and r.get("draft")), None)

@app.exception_handler(GitHubError)
async def github_error_handler(_request: Request, exc: GitHubError):
    return JSONResponse(status_code=502, content={"detail": str(exc)})

@app.get("/healthz")
async def health():
    return {"status": "healthy", "active": len(os.environ.get("PIRICRAFT_GATEWAY_CAPABILITY", "")) >= 32 and bool(os.environ.get("PIRICRAFT_GITHUB_TOKEN"))}

@app.get("/api/v1/mods")
async def mods(authorization: str | None = Header(None)):
    require_capability(authorization)
    async with GitHub() as gh:
        manifest = await gh.official_manifest()
    return {
        "launcher": manifest["launcher"]["version"],
        "mods": [{"path": f["path"], "sha256": f["sha256"]} for f in manifest["files"]
                 if PATH_PATTERN.fullmatch(f["path"])],
    }

@app.post("/api/v1/publish", status_code=202)
async def publish(request: Request,
                  authorization: str | None = Header(None),
                  x_mod_mode: str = Header(""),
                  x_mod_target: str = Header(""),
                  x_mod_filename: str = Header(""),
                  x_mod_sha256: str = Header("")):
    require_capability(authorization)
    if x_mod_mode not in {"add", "update"}:
        raise HTTPException(400, "Unknown MOD publish mode")
    if x_mod_mode == "update" and (not PATH_PATTERN.fullmatch(x_mod_target) or chr(92) in x_mod_target):
        raise HTTPException(400, "Invalid original MOD selection")
    if not FILENAME_PATTERN.fullmatch(x_mod_filename) or chr(92) in x_mod_filename:
        raise HTTPException(400, "Invalid filename")
    if not re.fullmatch("[A-Fa-f0-9]{64}", x_mod_sha256):
        raise HTTPException(400, "Invalid expected checksum")

    data = bytearray()
    async for chunk in request.stream():
        if len(data) + len(chunk) > MAX_JAR_BYTES:
            raise HTTPException(413, "MOD JAR is too large")
        data.extend(chunk)
    digest = hashlib.sha256(data).hexdigest().upper()
    if not hmac.compare_digest(digest, x_mod_sha256.upper()):
        raise HTTPException(400, "SHA-256 checksum mismatch")
    verify_jar(bytes(data), x_mod_filename)
    check_upload_rate()

    async with GitHub() as gh:
        manifest = await gh.official_manifest()
        valid_paths = {f["path"] for f in manifest["files"] if PATH_PATTERN.fullmatch(f["path"])}
        if x_mod_mode == "update" and x_mod_target not in valid_paths:
            raise HTTPException(409, "Original MOD has changed or disappeared")
        new_path = "mods/" + x_mod_filename
        if new_path in valid_paths and (x_mod_mode == "add" or x_mod_target != new_path):
            raise HTTPException(409, "A MOD already uses this filename")
        stage = "publisher-input-" + secrets.token_hex(12)
        release = await gh.new_release(stage)
        dispatched = False
        try:
            await gh.upload_asset(release, x_mod_filename, bytes(data))
            await gh.dispatch(x_mod_mode, x_mod_target if x_mod_mode == "update" else "",
                              stage, x_mod_filename, digest)
            dispatched = True
        finally:
            if not dispatched:
                try:
                    await gh.delete_staging(release["id"], stage)
                except Exception:
                    log.exception("Cleanup failed for rejected staged upload")
    log.info("Queued authorized JAR upload %s SHA256 %s", stage, digest[:16])
    return {"ticket": stage, "status": "queued", "sha256": digest}

@app.get("/api/v1/status/{ticket}")
async def status(ticket: str, authorization: str | None = Header(None)):
    require_capability(authorization)
    if not STAGE_PATTERN.fullmatch(ticket):
        raise HTTPException(400, "Invalid ticket")
    async with GitHub() as gh:
        runs = await gh.jobs()
    for run in runs.get("workflow_runs", []):
        if ticket in run.get("name", "") or ticket in run.get("display_title", ""):
            result = {"ticket": ticket, "status": run["status"], "conclusion": run.get("conclusion"),
                      "workflow_url": run.get("html_url")}
            return result
    return {"ticket": ticket, "status": "queued", "conclusion": None, "workflow_url": None}


@app.post("/api/v1/ci-client-config")
async def ci_client_config(authorization: str | None = Header(None)):
    """Issue a short-lived response only to the intended GitHub Actions workflow.

    The credential is injected into the private EXE at build time. Nothing secret
    is committed to GitHub or stored in an Actions artifact.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "GitHub Actions OIDC bearer token required")
    jwt_text = authorization[7:]
    try:
        signing_key = jwt.PyJWKClient(
            "https://token.actions.githubusercontent.com/.well-known/jwks", cache_jwk_set=True
        ).get_signing_key_from_jwt(jwt_text)
        claims = jwt.decode(jwt_text, signing_key.key,
                            algorithms=["RS256"],
                            issuer="https://token.actions.githubusercontent.com",
                            audience="piricraft-publisher-client-build",
                            options={"require": ["iss", "aud", "exp", "sub", "iat"]})
    except (jwt.InvalidTokenError, jwt.PyJWKClientError, ValueError):
        raise HTTPException(403, "Invalid GitHub Actions OIDC identity")
    if (
        claims.get("repository") != REPO
        or claims.get("ref") != "refs/heads/main"
        or claims.get("event_name") != "workflow_dispatch"
        or claims.get("workflow_ref") != (
            "Pasta0719/Piricraft/.github/workflows/build-secure-publisher.yml@refs/heads/main"
        )
    ):
        raise HTTPException(403, "Not an authorized publishing workflow")
    public_url = get_secret("PIRICRAFT_PUBLIC_URL")
    if not public_url.startswith("https://"):
        raise HTTPException(503, "Gateway public URL is not configured")
    return {"gatewayBaseUrl": public_url.rstrip("/"),
            "publisherCapability": get_secret("PIRICRAFT_GATEWAY_CAPABILITY")}
