#!/usr/bin/env python3
"""Actual loopback template transfers, including legacy fallback and security boundaries."""
import argparse
import hashlib
import http.server
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", type=Path, required=True)
parser.add_argument("--source-proxy", type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-page-resource-", dir="/private/tmp"))
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
names = ["redirect", "auth", "missing", "invalid-utf8", "oversize", "stream-oversize", "slow"]
release_id = "r-0123456789abcdef"
channel = {"schema_version": "mcp_app_channel.v1", "release_id": release_id}
release = {"schema_version": "mcp_app_release.v1", "release_id": release_id, "widgets": {
    "previs@v3": {"hash": "0123abcd", "csp": {"img_domains": ["https://files.tapnow.art", "https://forbidden.example"]},
                  "presentation": {"allow_expanded": True, "max_inline_height": 520}},
    **{name + "@v1": {"hash": "0123abcd"} for name in names}}}
manifest = {"widgets": {"previs@v3": "0123abcd", "animatic@v1": "fedcba98", "malformed@v1": "../attack"}}
body = "<!doctype html><title>页面🙂</title><p id='remote'>已发布模板</p>".encode()
requests = []
lock = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        with lock:
            requests.append({"path": self.path, "method": self.command,
                "cookiePresent": bool(self.headers.get("Cookie")), "authorizationPresent": bool(self.headers.get("Authorization")),
                "proxyAuthorizationPresent": bool(self.headers.get("Proxy-Authorization")), "accept": self.headers.get("Accept")})
        status = 200
        payload = body
        if self.path == "/mcp-apps/channels/current.json":
            payload = json.dumps(channel).encode()
        elif self.path == "/mcp-apps/releases/" + release_id + ".json":
            payload = json.dumps(release).encode()
        elif self.path.endswith("/manifest.json"):
            payload = json.dumps(manifest).encode()
        elif self.path == "/apps/redirect@v1.0123abcd.html":
            status = 302
        elif self.path == "/apps/auth@v1.0123abcd.html":
            status = 401
        elif self.path == "/apps/missing@v1.0123abcd.html":
            status = 404
        elif self.path == "/apps/invalid-utf8@v1.0123abcd.html":
            payload = b"\xff\xfe"
        elif "oversize@v1" in self.path:
            payload = b"x" * 1024
        elif self.path == "/apps/slow@v1.0123abcd.html":
            time.sleep(0.2)
        elif self.path not in ["/apps/previs@v3.0123abcd.html", "/apps/animatic@v1.fedcba98.html",
                              "/usercontent-proxy/apps/previs@v3.0123abcd.html"]:
            status = 404
        self.send_response(status)
        self.send_header("Set-Cookie", "sentinel=private; Path=/")
        if status == 302:
            self.send_header("Location", "/redirect-target")
        if status == 401:
            self.send_header("WWW-Authenticate", 'Basic realm="fixture"')
        if "stream-oversize" not in self.path:
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    result = subprocess.run([str(args.binary.resolve(strict=True)), f"http://127.0.0.1:{server.server_port}"],
                            capture_output=True, text=True, timeout=30)
finally:
    server.shutdown()
    server.server_close()
report = json.loads(result.stdout.splitlines()[-1])
(root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
(root / "requests.json").write_text(json.dumps(requests, indent=2) + "\n")
(root / "stderr.txt").write_text(result.stderr)
shutil.copy2(args.source_proxy, root / "source-proxy.html")
(root / "source-oracle.cjs").write_text(r"""
const fs=require('node:fs'),vm=require('node:vm');
const html=fs.readFileSync(__dirname+'/source-proxy.html','utf8');
let script=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const marker='      // 内联脚本先挂监听再通知';
if(script.split(marker).length!==2)throw Error('source oracle marker changed');
script=script.replace(marker,'window.__oracle={resolveAppsBase,buildCspPolicy};\n'+marker);
const out=[];
for(const url of ['https://usercontent.tapnow.art/82b3c69f76/mcp-app-proxy.html',
                  'http://127.0.0.1:123/usercontent-proxy/mcp-app-proxy.html']){
  const location=new URL(url),inner={setAttribute(){},contentWindow:{}};
  const window={parent:{postMessage(){}},addEventListener(){}};
  const context={window,location,URL,document:{createElement(){return inner},body:{appendChild(){}}},
    setInterval(){return 1},clearInterval(){},fetch(){throw Error('oracle must not fetch')}};
  vm.runInNewContext(script,context,{timeout:1000});
  const oracle=window.__oracle;
  out.push({url,templatePath:new URL(oracle.resolveAppsBase()+'previs@v3.0123abcd.html',url).pathname,
    csp:oracle.buildCspPolicy({imgDomains:['https://files.tapnow.art',"https://x'; connect-src *"],
                              mediaDomains:['https://files.tapnow.media']})});
}
fs.writeFileSync(__dirname+'/source-oracle.json',JSON.stringify(out));
""")
subprocess.run(["node", str(root / "source-oracle.cjs")], check=True, capture_output=True, timeout=10)
oracle = json.loads((root / "source-oracle.json").read_text())
assert [r["templatePath"] for r in oracle] == ["/apps/previs@v3.0123abcd.html",
                                                   "/usercontent-proxy/apps/previs@v3.0123abcd.html"]
assert all(r["csp"] == report["CSP"] for r in oracle)
subject = {"binarySHA256": sha(args.binary), "sources": sources, "productionProtected": protected,
           "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
           "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
           "sourceProxySHA256": sha(args.source_proxy), "sourceOracleCases": len(oracle),
           "sourceOptionsBoundary": "Proxy template fetch uses browser defaults; native transport omits credentials, rejects redirects and adds bounds.",
           "remoteProviderRequests": 0, "remotePageRendered": False, "M06Accepted": False}
(root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
print(json.dumps({"root": str(root), "passed": report["passed"], "requests": len(requests),
                  "sourceOracleCases": len(oracle), "failures": report["failures"]}), flush=True)
assert result.returncode == 0 and not report["failures"]
assert all(not r["cookiePresent"] and not r["authorizationPresent"] and not r["proxyAuthorizationPresent"]
           and r["method"] == "GET" for r in requests)
paths = [r["path"] for r in requests]
assert "/redirect-target" not in paths
assert paths.count("/apps/auth@v1.0123abcd.html") == 1
assert paths.count("/apps/manifest.json") == 2
assert paths[:3] == ["/mcp-apps/channels/current.json", "/mcp-apps/releases/" + release_id + ".json",
                     "/apps/previs@v3.0123abcd.html"]
assert paths.count("/apps/previs@v3.0123abcd.html") == 1
assert all(r["accept"] == ("text/html" if r["path"].endswith(".html") else "application/json") for r in requests)
assert subject["sourceUnchanged"] and subject["productionUnchanged"]
