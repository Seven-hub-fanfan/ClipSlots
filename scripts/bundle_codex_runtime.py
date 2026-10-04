#!/usr/bin/env python3
"""Bundle the pinned official Codex runtime; preserve its upstream signatures."""
import argparse
import base64
import hashlib
import io
import pathlib
import platform
import shutil
import tarfile
import urllib.request

VERSION = "0.160.0"
TARGETS = {
    "arm64": ("aarch64-apple-darwin", "aefV6cqZA2REZgR//4McyXlp7zLcTti4CI2v3j9IVgNndPBv2kCeNEcz07qeelXcwOdSFPUKb6roA48vZmDgrQ=="),
    "x64": ("x86_64-apple-darwin", "ir7cdsPrb9VkqNqpTECoTiomv04xws/FQ968mHQzuL+2J5Da0Dkh2Qlxp7sguDDZJab4YpYmNjQvBVMXbTeQaQ=="),
}
parser = argparse.ArgumentParser()
parser.add_argument("--bundle", type=pathlib.Path, required=True)
parser.add_argument("--archive", type=pathlib.Path, help="Use an already downloaded npm archive")
parser.add_argument("--arch", choices=TARGETS, default="arm64" if platform.machine() == "arm64" else "x64")
args = parser.parse_args()
target, digest = TARGETS[args.arch]
url = f"https://registry.npmjs.org/@openai/codex/-/codex-{VERSION}-darwin-{args.arch}.tgz"
data = args.archive.read_bytes() if args.archive else urllib.request.urlopen(url, timeout=60).read()
if base64.b64encode(hashlib.sha512(data).digest()).decode() != digest:
    raise SystemExit("Codex archive checksum mismatch; bundle not modified.")
destination = args.bundle / "Contents/Resources/codex-runtime"
if destination.exists():
    raise SystemExit("Runtime already exists; remove it from the staging bundle before replacing.")
destination.mkdir(parents=True)
prefix = f"package/vendor/{target}/"
with tarfile.open(fileobj=io.BytesIO(data)) as archive:
    for member in archive.getmembers():
        if not member.name.startswith(prefix):
            continue
        relative = pathlib.PurePosixPath(member.name[len(prefix):])
        if relative.is_absolute() or ".." in relative.parts or member.issym() or member.islnk():
            raise SystemExit("Unsafe archive member.")
        if member.isfile():
            output = destination.joinpath(*relative.parts)
            output.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, output.open("wb") as stream:
                shutil.copyfileobj(source, stream)
            output.chmod(member.mode)
license_path = pathlib.Path(__file__).resolve().parent.parent / "licenses/Codex-LICENSE"
shutil.copy2(license_path, destination / "LICENSE")
shutil.copy2(license_path.with_name("Codex-NOTICE"), destination / "NOTICE")
print(f"Bundled official Codex {VERSION} ({args.arch}); SHA-512 verified.")
