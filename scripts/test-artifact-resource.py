#!/usr/bin/env python3
"""Local HTTP transport and differential oracle from the frozen, complete source host."""
import argparse
import copy
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--source-host", required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-resource-", dir="/tmp"))
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
sources = {str(p.relative_to(repo)): sha(p) for p in (repo / "Sources").rglob("*.swift")}
channel = {"schema_version": "mcp_app_channel.v1", "release_id": "r-0123456789abcdef"}
release = {"schema_version": "mcp_app_release.v1", "release_id": channel["release_id"], "widgets": {
    "previs@v3": {"hash": "0123abcd", "csp": {
        "img_domains": ["https://files.tapnow.art", "https://bad.example", "https://files.tapnow.art",
                        "https://files.tapnow.art/", "https://u:p@files.tapnow.art"],
        "media_domains": ["https://files.tapnow.media"], "connect_domains": ["https://bad.example"]},
        "presentation": {"allow_expanded": True, "auto_expand_on_ready": True, "max_inline_height": 520}}}}
cases = [{"uri": "ui://tapnow/previs@v3", "channel": channel, "release": release}]
for field, value in [("schema_version", "bad"), ("release_id", "r-UPPERCASE0000000")]:
    case = copy.deepcopy(cases[0]); case["channel"][field] = value; cases.append(case)
for field, value in [("schema_version", "bad"), ("release_id", "r-ffffffffffffffff"), ("widgets", None)]:
    case = copy.deepcopy(cases[0]); case["release"][field] = value; cases.append(case)
for hash_value in ["UPPER123", "short", "0123abcd9"]:
    case = copy.deepcopy(cases[0]); case["release"]["widgets"]["previs@v3"]["hash"] = hash_value; cases.append(case)
case = copy.deepcopy(cases[0]); case["uri"] = "ui://tapnow/missing@v1"; cases.append(case)
case = copy.deepcopy(cases[0]); case["release"]["widgets"]["previs@v3"]["presentation"] = {
    "allow_expanded": "true", "auto_expand_on_ready": False, "max_inline_height": 99}
cases.append(case)
(root / "oracle-cases.json").write_text(json.dumps(cases))
shutil.copy2(args.source_host, root / "source-host.mjs")
(root / "source-oracle.mjs").write_text("""
import fs from 'node:fs';
import {c as makeResolver} from './source-host.mjs';
const cases=JSON.parse(fs.readFileSync(new URL('./oracle-cases.json',import.meta.url)));
const out=[];
for(const item of cases){
  const requests=[];
  const resolver=makeResolver({getChannelUrl:()=> 'http://127.0.0.1:123/mcp-apps/channels/current.json',
    fetchImpl:async(url,options)=>{
      requests.push({url,credentials:options.credentials,redirect:options.redirect,signal:!!options.signal});
      return {ok:true,json:async()=> url.includes('/channels/')?item.channel:item.release};
    }});
  const match=/^ui:\\/\\/tapnow\\/([a-z0-9-]+)@(v\\d+)$/.exec(item.uri);
  out.push({value:match?await resolver({name:match[1],version:match[2]}):null,requests});
}
fs.writeFileSync(new URL('./source-oracle.json',import.meta.url),JSON.stringify(out));
""")
subprocess.run(["node", str(root / "source-oracle.mjs")], check=True, capture_output=True, text=True, timeout=30)
requests = []
lock = threading.Lock()

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def do_GET(self):
        with lock:
            requests.append({"path": self.path, "method": self.command,
                             "cookiePresent": bool(self.headers.get("Cookie")),
                             "authorizationPresent": bool(self.headers.get("Authorization")),
                             "proxyAuthorizationPresent": bool(self.headers.get("Proxy-Authorization"))})
        if self.path == "/mcp-apps/channels/ok.json":
            self.send_response(200); self.send_header("Set-Cookie", "fixture=sentinel; Path=/")
            body = json.dumps(channel).encode()
        elif self.path == "/mcp-apps/releases/" + channel["release_id"] + ".json":
            self.send_response(200); body = json.dumps(release).encode()
        elif self.path == "/redirect":
            self.send_response(302); self.send_header("Location", "/redirect-target"); body = b"{}"
        elif self.path == "/auth":
            self.send_response(401); self.send_header("WWW-Authenticate", 'Basic realm="fixture"'); body = b"{}"
        elif self.path in ["/oversize", "/stream-oversize"]:
            self.send_response(200); body = b"x" * 1024
        elif self.path == "/slow":
            time.sleep(0.2); self.send_response(200); body = b"{}"
        else:
            self.send_response(404); body = b"{}"
        if self.path != "/stream-oversize":
            self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/json"); self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_", "GATEWAY_"))}
try:
    result = subprocess.run([str(args.binary.resolve(strict=True)), "--url", f"http://127.0.0.1:{server.server_port}/",
                             "--oracle", str(root / "oracle-cases.json")],
                            capture_output=True, text=True, env=env, timeout=30)
finally:
    server.shutdown(); server.server_close(); thread.join(timeout=2)
(root / "native.stdout").write_text(result.stdout)
(root / "native.stderr").write_text(result.stderr)
report = json.loads(result.stdout)
oracle = json.loads((root / "source-oracle.json").read_text())
oracle_matches = len(oracle) == len(report["oracleResults"]) and all(
    item["value"] == actual for item, actual in zip(oracle, report["oracleResults"]))
source_options_match = all(r["credentials"] == "omit" and r["redirect"] == "error" and r["signal"]
                           for item in oracle for r in item["requests"])
(root / "http-requests.json").write_text(json.dumps(requests, indent=2))
transport_matches = len(requests) == 7 and all(
    r["method"] == "GET" and not r["cookiePresent"] and not r["authorizationPresent"]
    and not r["proxyAuthorizationPresent"] and r["path"] != "/redirect-target" for r in requests)
subject = {"root": str(root), "binarySHA256": sha(args.binary), "sourceHostSHA256": sha(args.source_host),
           "sources": sources, "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
           "productionProtected": protected, "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
           "report": report, "oracleCases": len(cases), "oracleMatches": oracle_matches,
           "sourceOptionsMatch": source_options_match, "transportRequests": len(requests),
           "transportMatches": transport_matches, "remoteProviderRequests": 0, "M06Accepted": False}
(root / "subject.json").write_text(json.dumps(subject, indent=2))
print(json.dumps({"root": str(root), "passed": report["passed"], "failures": report["failures"],
                  "oracleCases": len(cases), "oracleMatches": oracle_matches, "transportMatches": transport_matches}))
assert result.returncode == 0 and not report["failures"]
assert oracle_matches and source_options_match and transport_matches
assert subject["sourceUnchanged"] and subject["productionUnchanged"]
