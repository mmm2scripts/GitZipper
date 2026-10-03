#!/usr/bin/env python3
"""GitZipper upload API - Python 3.8+ standard library only. No root, no pip.
POST /upload?repo=owner/name&branch=main&path=sub/dir   (body = raw .zip)
Headers: X-GitHub-Token (required), X-Api-Key (required if API_KEY env is set)
Env: PORT (8787) HOST (0.0.0.0) API_KEY MAX_MB (300) WORKERS (6)"""
import base64, io, json, os, posixpath, urllib.request, urllib.error, zipfile
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

API_KEY = os.environ.get("API_KEY", "")
MAX = int(os.environ.get("MAX_MB", "300")) * 1024 * 1024
WORKERS = int(os.environ.get("WORKERS", "6"))

class Err(Exception):
    def __init__(s, code, msg): super().__init__(msg); s.code, s.msg = code, msg

def gh(token, path, method="GET", body=None):
    req = urllib.request.Request("https://api.github.com" + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "gitzipper-api",
                 "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r: return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: m = json.loads(e.read()).get("message", "")
        except Exception: m = ""
        raise Err(e.code, f"GitHub {e.code}: {m}")

def head(token, repo, branch):
    try:
        sha = gh(token, f"/repos/{repo}/git/ref/heads/{branch}")["object"]["sha"]
        return sha, gh(token, f"/repos/{repo}/git/commits/{sha}")["tree"]["sha"]
    except Err as e:
        if e.code in (404, 409): gh(token, f"/repos/{repo}"); return None
        raise

def clean_zip(data, prefix):
    z = zipfile.ZipFile(io.BytesIO(data))
    items = []
    for i in z.infolist():
        n = i.filename.replace("\\", "/")
        if i.is_dir() or n.startswith("__MACOSX/") or n.endswith(".DS_Store"): continue
        n = posixpath.normpath(n)
        if n.startswith(("/", "..")) or "/../" in n: continue   # zip-slip guard
        items.append((n, i))
    if not items: raise Err(400, "The zip contains no files")
    roots = {n.split("/")[0] for n, _ in items}
    if len(roots) == 1 and all("/" in n for n, _ in items):
        items = [(n.split("/", 1)[1], i) for n, i in items]
    return [((prefix + "/" if prefix else "") + n, z.read(i)) for n, i in items]

def upload(token, repo, branch, prefix, data):
    files = clean_zip(data, prefix)
    h = head(token, repo, branch)
    if h is None:
        gh(token, f"/repos/{repo}/contents/README.md", "PUT", {"message": "Initialize repository",
           "content": base64.b64encode(f"# {repo}\n".encode()).decode(), "branch": branch})
        h = head(token, repo, branch)
    def blob(f):
        b = gh(token, f"/repos/{repo}/git/blobs", "POST", {"content": base64.b64encode(f[1]).decode(), "encoding": "base64"})
        return {"path": f[0], "mode": "100644", "type": "blob", "sha": b["sha"]}
    with ThreadPoolExecutor(WORKERS) as ex: entries = list(ex.map(blob, files))
    t = gh(token, f"/repos/{repo}/git/trees", "POST", {"base_tree": h[1], "tree": entries})
    c = gh(token, f"/repos/{repo}/git/commits", "POST",
           {"message": f"Upload {len(files)} file(s) via GitZipper", "tree": t["sha"], "parents": [h[0]]})
    gh(token, f"/repos/{repo}/git/refs/heads/{branch}", "PATCH", {"sha": c["sha"]})
    return len(files), c["sha"]

class H(BaseHTTPRequestHandler):
    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        self.send(200, {"ok": True}) if urlparse(self.path).path == "/health" else self.send(404, {"error": "not found"})
    def do_POST(self):
        try:
            u = urlparse(self.path)
            if u.path != "/upload": raise Err(404, "not found")
            if API_KEY and self.headers.get("X-Api-Key") != API_KEY: raise Err(401, "bad API key")
            token = self.headers.get("X-GitHub-Token", "")
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            if not token or "/" not in q.get("repo", ""): raise Err(400, "missing token or repo")
            n = int(self.headers.get("Content-Length", 0))
            if n <= 0 or n > MAX: raise Err(413, f"zip must be 1 byte - {MAX // 1048576} MB")
            try: count, sha = upload(token, q["repo"], q.get("branch", "main"), q.get("path", "").strip("/"), self.rfile.read(n))
            except zipfile.BadZipFile: raise Err(400, "Not a valid zip archive")
            self.send(200, {"ok": True, "files": count, "commit": sha})
        except Err as e: self.send(e.code, {"error": e.msg})
        except Exception as e: self.send(500, {"error": str(e)})
    def log_message(self, *a): pass

if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8787"))
    print(f"GitZipper API on :{port}")
    ThreadingHTTPServer((os.environ.get("HOST", "0.0.0.0"), port), H).serve_forever()
