#!/usr/bin/env python3
"""Pinned local CONNECT/TLS fixture, signed isolated App and actual WebKit resource matrix.

The proxy implements responses locally and never opens an outbound connection. Failover is disabled
in the fixture data store. Both denied and allowed endpoints have separate positive controls.
"""
import argparse
import base64
import hashlib
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import socketserver
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import urllib.parse
import wave
import zlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", required=True, type=Path)
parser.add_argument("--html-parser", action="store_true",
                    help="Run the adversarial HTML parser matrix through the same pinned HTTPS fixture")
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
binary = args.binary.resolve(strict=True)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
root = Path(tempfile.mkdtemp(prefix="clipslots-store-regression-", dir="/tmp"))
print(json.dumps({"root": str(root), "stage": "prepare"}), flush=True)
contents = root / "Artifact HTTPS Test.app/Contents"
(contents / "MacOS").mkdir(parents=True)
(contents / "Resources").mkdir()
info = plistlib.loads((repo / "Info.plist").read_bytes())
info.update(CFBundleIdentifier="com.clipslots.app.store-regression",
            CFBundleName="Artifact HTTPS Test", ClipSlotsIsolatedCandidate=True)
# Fixture-only ATS setting permits the delegate's pinned synthetic TLS identity.
# No installed App plist or system trust entry is touched.
info["NSAppTransportSecurity"] = {"NSAllowsArbitraryLoadsInWebContent": True}
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
shutil.copy2(binary, contents / "MacOS/ClipSlots")
shutil.copytree(binary.parent / "ClipSlots_ClipSlotsKit.bundle",
                contents / "Resources/ClipSlots_ClipSlotsKit.bundle")
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(contents.parent)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(contents.parent)], check=True)
protected = {str(Path("/Applications/ClipSlots.app/Contents/MacOS") / n):
             sha(Path("/Applications/ClipSlots.app/Contents/MacOS") / n)
             for n in ["ClipSlots", "clipslots-cli", "clipslots-mcp"]}
hosts = ["files.tapnow.art", "files.tapnow.media", "denied.invalid", "files.tapnow.art.denied.invalid"]
certificate_config = """[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=ClipSlots isolated HTTPS fixture
[ext]
subjectAltName=""" + ",".join("DNS:" + h for h in hosts) + "\nbasicConstraints=critical,CA:FALSE\n"
(root / "fixture-cert.conf").write_text(certificate_config)
with (root / "certificate.log").open("w") as log:
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-keyout", str(root / "fixture-key.pem"), "-out", str(root / "fixture-cert.pem"),
                    "-config", str(root / "fixture-cert.conf")], stdout=log, stderr=log, check=True)
    subprocess.run(["openssl", "x509", "-in", str(root / "fixture-cert.pem"), "-outform", "DER",
                    "-out", str(root / "fixture-cert.der")], stdout=log, stderr=log, check=True)
os.chmod(root / "fixture-key.pem", 0o600)
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 3, 2, 8, 6, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress((b"\0" + b"\xff\x10\x20\xff" * 3) * 2)) + chunk(b"IEND", b"")
wav_bytes = io.BytesIO()
with wave.open(wav_bytes, "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(8000)
    wav.writeframes(b"\0\0" * 4000)
wav_payload = wav_bytes.getvalue()
(root / "image.png").write_bytes(png)
(root / "audio.wav").write_bytes(wav_payload)
with (root / "media-generation.log").open("w") as log:
    subprocess.run(["swift", str(repo / "scripts/generate-artifact-media.swift"), str(root / "video.mp4")],
                   stdout=log, stderr=log, timeout=60, check=True)
mp4 = (root / "video.mp4").read_bytes()
font = Path("/System/Library/Fonts/Supplemental/Arial.ttf").read_bytes()
(root / "fixture-font.ttf").write_bytes(font)
fixture = (repo / "scripts/gateway-fixtures/ArtifactTemplateFixture.html").read_bytes()
matrix = (repo / "scripts/gateway-fixtures/ArtifactResourceMatrix.js").read_bytes()
fixture = fixture.replace(b"</body>", b"<script>" + matrix + b"</script></body>")
(root / "resource-fixture.html").write_bytes(fixture)
parser_cases = []
if args.html_parser:
    module_path = repo / "scripts/gateway-fixtures/ArtifactHTMLParserCases.py"
    spec = importlib.util.spec_from_file_location("artifact_html_parser_cases", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    parser_cases = module.cases()
    for case in parser_cases:
        (root / (case["name"] + ".html")).write_text(case["source"])
    (root / "parser-cases.json").write_text(json.dumps(parser_cases, indent=2) + "\n")
requests, proxy_events = [], []
lock = threading.Lock()
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(root / "fixture-cert.pem", root / "fixture-key.pem")
tls.set_alpn_protocols(["http/1.1"])
def read_headers(stream):
    data = bytearray()
    while not data.endswith(b"\r\n\r\n"):
        byte = stream.recv(1)
        if not byte:
            return None
        data.extend(byte)
        if len(data) > 32768:
            raise ValueError("fixture header limit")
    return data.decode("iso-8859-1")

class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        stream = self.request
        stream.settimeout(10)
        authority = ""
        try:
            head = read_headers(stream)
            if head is None:
                return
            method, target, _ = head.split("\r\n", 1)[0].split(" ", 2)
            with lock:
                proxy_events.append({"method": method, "target": target, "phase": "initial", "timeNS": time.time_ns()})
            if method != "CONNECT":
                stream.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            authority = target
            if authority.rsplit(":", 1)[0] not in hosts:
                stream.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                return
            stream.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            stream = tls.wrap_socket(stream, server_side=True)
            while True:
                head = read_headers(stream)
                if head is None:
                    break
                lines = head.split("\r\n")
                method, path, _ = lines[0].split(" ", 2)
                headers = dict((k.lower(), v.strip()) for k, v in
                               (line.split(":", 1) for line in lines[1:] if ":" in line))
                parsed = urllib.parse.urlsplit(path)
                case = urllib.parse.parse_qs(parsed.query).get("case", [""])[0]
                payload, mime, status, extra = b"", "text/plain", 200, {}
                resources = {"/image.png": (png, "image/png"), "/audio.wav": (wav_payload, "audio/wav"),
                    "/video.mp4": (mp4, "video/mp4"), "/font.ttf": (font, "font/ttf"),
                    "/script.js": (b"window.controlScriptExecuted=true;window.matrixExternalScriptExecuted=true;", "text/javascript"),
                    "/style.css": (b"#control-style{color:rgb(9,8,7)}#matrix-style{color:rgb(9,8,7)}", "text/css"),
                    "/frame.html": (b"<p>reachable nested fixture</p>", "text/html"),
                    "/data.json": (b'{"fixture":true}', "application/json")}
                if method != "GET":
                    status = 405
                elif parsed.path == "/redirect.png":
                    status = 302
                    extra["Location"] = "https://denied.invalid/image.png?case=redirect-denied"
                elif parsed.path in resources:
                    payload, mime = resources[parsed.path]
                else:
                    status = 404
                size = len(payload)
                byte_range = headers.get("range")
                if status == 200 and byte_range and byte_range.startswith("bytes="):
                    start_text, end_text = byte_range[6:].split("-", 1)
                    start = int(start_text or "0")
                    end = min(int(end_text) if end_text else size - 1, size - 1)
                    if start <= end:
                        status = 206
                        payload = payload[start:end + 1]
                        extra["Content-Range"] = f"bytes {start}-{end}/{size}"
                    else:
                        status, payload = 416, b""
                event = {"method": method, "authority": authority, "host": headers.get("host"),
                         "path": path, "case": case, "status": status, "range": byte_range,
                         "responseBytes": len(payload), "payloadSHA256": hashlib.sha256(payload).hexdigest(),
                         "cookiePresent": bool(headers.get("cookie")), "authorizationPresent": bool(headers.get("authorization")),
                         "origin": headers.get("origin"), "timeNS": time.time_ns()}
                with lock:
                    requests.append(event)
                response = f"HTTP/1.1 {status} Fixture\r\nContent-Type: {mime}\r\nContent-Length: {len(payload)}\r\n"
                response += "Access-Control-Allow-Origin: *\r\nAccept-Ranges: bytes\r\nCache-Control: no-store\r\n"
                response += "".join(f"{k}: {v}\r\n" for k, v in extra.items()) + "\r\n"
                stream.sendall(response.encode() + payload)
        except (OSError, ssl.SSLError, ValueError) as error:
            with lock:
                proxy_events.append({"phase": "closed", "authority": authority,
                                     "errorType": type(error).__name__, "error": str(error)})
        finally:
            stream.close()

class ProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

class Metadata(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_GET(self):
        status = 200
        release_id = "r-0123456789abcdef"
        if "/channels/" in self.path:
            payload = json.dumps({"schema_version": "mcp_app_channel.v1", "release_id": release_id}).encode()
        elif "/releases/" in self.path:
            widgets = {case["name"] + "@v3": {"hash": "0123abcd",
                "csp": {"img_domains": ["https://files.tapnow.art"],
                        "media_domains": ["https://files.tapnow.media"]}}
                       for case in parser_cases} if parser_cases else {"matrix@v3": {"hash": "0123abcd",
                "csp": {"img_domains": ["https://files.tapnow.art"], "media_domains": ["https://files.tapnow.media"]},
                "presentation": {"allow_expanded": True}}}
            payload = json.dumps({"schema_version": "mcp_app_release.v1", "release_id": release_id,
                                  "widgets": widgets}).encode()
        elif self.path == "/apps/matrix@v3.0123abcd.html":
            payload = fixture
        elif any(self.path == "/apps/" + case["name"] + "@v3.0123abcd.html" for case in parser_cases):
            payload = next(case["source"].encode() for case in parser_cases
                           if self.path == "/apps/" + case["name"] + "@v3.0123abcd.html")
        else:
            payload, status = b"not found", 404
        with lock:
            requests.append({"method": "GET", "path": self.path, "metadata": True, "status": status,
                "responseBytes": len(payload), "payloadSHA256": hashlib.sha256(payload).hexdigest(),
                "cookiePresent": bool(self.headers.get("Cookie")), "authorizationPresent": bool(self.headers.get("Authorization")),
                "timeNS": time.time_ns()})
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Type", "text/html" if self.path.endswith(".html") else "application/json")
        self.end_headers()
        self.wfile.write(payload)

proxy = ProxyServer(("127.0.0.1", 0), Proxy)
metadata = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Metadata)
for server in [proxy, metadata]:
    threading.Thread(target=server.serve_forever, daemon=True).start()
control = """<!doctype html><p id="control-style">control</p><script>
(async()=>{
 const out={};
 const specs=[
 ['image','img','https://files.tapnow.art/image.png'],
 ['denied-host','img','https://denied.invalid/image.png'],
 ['suffix-host','img','https://files.tapnow.art.denied.invalid/image.png'],
 ['wrong-port','img','https://files.tapnow.art:444/image.png'],
 ['audio','audio','https://files.tapnow.media/audio.wav'],
 ['video','video','https://files.tapnow.media/video.mp4'],
 ['script','script','https://files.tapnow.art/script.js'],
 ['style','link','https://files.tapnow.art/style.css']];
 for(const[name,kind,url]of specs){
  const n=document.createElement(kind);if(kind==='link'){n.rel='stylesheet';n.href=url+'?case=control-'+name;}
  else n.src=url+'?case=control-'+name;
  if(kind==='audio'||kind==='video')n.preload='auto';
  out[name]=await new Promise(resolve=>{
   const timer=setTimeout(()=>resolve({outcome:'timeout'}),2000);
   n.addEventListener(kind==='audio'||kind==='video'?'loadedmetadata':'load',()=>{
    clearTimeout(timer);resolve({outcome:'loaded',width:n.naturalWidth??n.videoWidth??null,
      height:n.naturalHeight??n.videoHeight??null,duration:Number.isFinite(n.duration)?n.duration:null});});
   n.onerror=()=>{clearTimeout(timer);resolve({outcome:'error'});};document.body.appendChild(n);
   if(kind==='audio'||kind==='video')n.load();
  });
 }
 out.script.executed=window.controlScriptExecuted===true;
 out.style.color=getComputedStyle(document.getElementById('control-style')).color;
 window.controlResults=out;
})();
</script>"""
(root / "control.html").write_text(control)
assets = {name: base64.b64encode(data).decode() for name, data in
          [("png", png), ("wav", wav_payload), ("mp4", mp4), ("font", font)]}
(root / "fixture-config.json").write_text(json.dumps({
    "baseURL": f"http://127.0.0.1:{metadata.server_port}",
    "proxyPort": proxy.server_address[1], "hosts": hosts,
    "certificateSHA256": sha(root / "fixture-cert.der"), "assets": assets,
    "parserCases": [{k: v for k, v in case.items() if k != "source"} for case in parser_cases]}) + "\n")
sources = {str(p.relative_to(repo)): sha(p) for folder in ["Sources", "Tests", "scripts", "docs", "gateway", "assets", "skills"]
           for p in (repo / folder).rglob("*") if p.is_file() and not any(
               part in ["__pycache__", "node_modules", ".build", ".DS_Store"] for part in p.parts)}
for name in [".gitignore", "CLAUDE.md", "Info.plist", "Package.swift", "agent.md"]:
    sources[name] = sha(repo / name)
for name in sources:
    target = root / "source-snapshot" / name
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(repo / name, target)
product = {str(p.relative_to(contents.parent)): sha(p) for p in contents.parent.rglob("*") if p.is_file()}
prelaunch = {"timeNS": time.time_ns(), "sourceBinarySHA256": sha(binary), "sources": sources,
             "productMembers": product, "productionProtected": protected,
             "fixtureAssets": {name: sha(root / name) for name in [
                 "resource-fixture.html", "control.html", "image.png", "audio.wav", "video.mp4",
                 "fixture-font.ttf", "fixture-cert.der", "fixture-config.json"]}}
(root / "prelaunch.json").write_text(json.dumps(prelaunch, indent=2) + "\n")
env = {k: v for k, v in os.environ.items() if not k.startswith(("CLIPSLOTS_", "CANVAS_", "GATEWAY_"))}
env.update(CLIPSLOTS_STORE_REGRESSION="1", CLIPSLOTS_ARTIFACT_HTTPS_REGRESSION="1",
           CLIPSLOTS_DATA_DIR=str(root), CLIPSLOTS_CONFIG_PATH=str(root / "config.toml"))
report = None
result = None
try:
    with (root / "app.log").open("w") as log:
        result = subprocess.run([str(contents / "MacOS/ClipSlots")], env=env, stdout=log, stderr=log,
                                timeout=180 if args.html_parser else 90)
    report = json.loads((root / "report.json").read_text())
finally:
    for server in [proxy, metadata]:
        server.shutdown()
        server.server_close()
    (root / "requests.json").write_text(json.dumps(requests, indent=2) + "\n")
    (root / "proxy-events.json").write_text(json.dumps(proxy_events, indent=2) + "\n")
    subject = {"root": str(root), "prelaunch": prelaunch, "report": report,
        "sourceUnchanged": all(sha(repo / p) == h for p, h in sources.items()),
        "productUnchanged": all(sha(contents.parent / p) == h for p, h in product.items()),
        "productionUnchanged": all(sha(Path(p)) == h for p, h in protected.items()),
        "remoteProviderRequests": 0, "proxyOutboundConnections": 0, "systemTrustModified": False,
        "foregroundAccepted": False, "M06Accepted": False, "goalComplete": False}
    (root / "subject.json").write_text(json.dumps(subject, indent=2) + "\n")
    print(json.dumps({"root": str(root), "passed": report and report["passed"],
        "failures": report and report["failures"], "GET": sum(r["method"] == "GET" for r in requests)}), flush=True)
def require(condition, message):
    if not condition:
        raise RuntimeError(message)
require(subject["sourceUnchanged"] and subject["productUnchanged"] and subject["productionUnchanged"],
        "prelaunch source or protected product identity changed")
require(all(r["method"] == "GET" and not r["cookiePresent"] and not r["authorizationPresent"] for r in requests),
        "unexpected request method or credential header")
permitted = {"https-image", "https-audio", "https-video", "redirect-image", "remote-404", "parser-allowed-image"}
require(all(r.get("metadata") or r["case"].startswith("control-") or r["case"] in permitted for r in requests),
        "denied parser/resource endpoint reached the fixture")
require(result is not None and result.returncode == 0 and report is not None and not report["failures"],
        "actual WebKit regression did not pass")
