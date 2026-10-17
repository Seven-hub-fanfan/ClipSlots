#!/usr/bin/env python3
"""One signing entry for release bundles; ad-hoc signing requires an explicit flag.

SIGN_IDENTITY selects an existing certificate (local or Developer ID).
SIGN_CERT_SHA256 pins its leaf certificate. No certificates or trust are created.
SIGN_MODE=developer-id enables hardened runtime and timestamping.
ALLOW_ADHOC=1 is reserved for explicitly local builds and isolated probes.
"""
import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("app", type=Path)
options = parser.parse_args()
app = options.app.resolve()
identity = os.environ.get("SIGN_IDENTITY", "")
pin = os.environ.get("SIGN_CERT_SHA256", "").lower().replace(":", "")
mode = os.environ.get("SIGN_MODE", "local")
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
if not identity:
    if os.environ.get("ALLOW_ADHOC") != "1":
        raise SystemExit("Missing stable SIGN_IDENTITY. For an explicit local build set ALLOW_ADHOC=1.")
    signing = ["--timestamp=none", "--sign", "-"]
else:
    if len(pin) != 64 or any(c not in "0123456789abcdef" for c in pin):
        raise SystemExit("SIGN_CERT_SHA256 must pin the existing signing certificate.")
    if mode not in ("local", "developer-id"):
        raise SystemExit("SIGN_MODE must be local or developer-id.")
    signing = (["--timestamp", "--options", "runtime"] if mode == "developer-id"
               else ["--timestamp=none"]) + ["--sign", identity]

for binary in sorted((app / "Contents/MacOS").iterdir()):
    if binary.is_file() and os.access(binary, os.X_OK) and binary.name != info["CFBundleExecutable"]:
        subprocess.run(["/usr/bin/codesign", "--force"] + signing + [str(binary)], check=True)
subprocess.run(["/usr/bin/codesign", "--force"] + signing + [str(app)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
if identity:
    with tempfile.TemporaryDirectory(prefix="clipslots-signer-") as directory:
        prefix = str(Path(directory) / "cert")
        subprocess.run(["/usr/bin/codesign", "-d", "--extract-certificates", prefix, str(app)], check=True)
        actual = hashlib.sha256(Path(prefix + "0").read_bytes()).hexdigest()
        if actual != pin:
            raise SystemExit("Signed certificate differs from SIGN_CERT_SHA256; bundle rejected.")
print("Signing verified:", info["CFBundleIdentifier"], "certificate" if identity else "explicit local ad-hoc")
