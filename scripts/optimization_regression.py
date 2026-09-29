"""Compile isolated probes against production sources; never use user storage or paid services."""
from pathlib import Path
import json
import os
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
work = Path(tempfile.mkdtemp(prefix="clipslots-optimization-repairs-"))
app = repo / "Sources/ClipSlots"
imports = "import AppKit\nimport AVFoundation\nimport ImageIO\nimport UniformTypeIdentifiers\nimport ClipSlotsKit\n"
extracts = [
    ("AttachmentManagerPopover.swift", "enum AttachmentThumbnailProvider {", "// MARK: - Hover Preview Content", "AttachmentThumbnailProvider.swift"),
    ("SlotContent+Thumbnail.swift", "enum ClipSlotsImageIO {", "extension SlotContent {", "ClipSlotsImageIO.swift"),
]
for source, begin, end, target in extracts:
    text = (app / source).read_text()
    (work / target).write_text(imports + text[text.index(begin):text.index(end)])
sources = [
    repo / "build/validation/optimization-repairs-probe.swift",
    work / "AttachmentThumbnailProvider.swift", work / "ClipSlotsImageIO.swift",
] + [app / name for name in [
    "CanvasNodeAttachments.swift", "CanvasMediaProbe.swift", "CanvasVideoAsset.swift",
    "VideoThumbnailProvider.swift", "AgentChatModel.swift", "AppVersion.swift", "CanvasStore.swift",
]]
command = ["swiftc", "-parse-as-library", "-I", str(repo / ".build/debug/Modules")]
command += [str(p) for p in sources]
command += [str(p) for p in (repo / ".build/debug/ClipSlotsKit.build").glob("*.o")]
command += ["-o", str(work / "probe")]
with (work / "compile.log").open("w") as log:
    compiled = subprocess.run(command, cwd=repo, stdout=log, stderr=log)
print(json.dumps({"work": str(work), "compiled": compiled.returncode == 0}))
if compiled.returncode:
    print((work / "compile.log").read_text())
    raise SystemExit(compiled.returncode)
env = dict(os.environ, CLIPSLOTS_DATA_DIR=str(work / "isolated-data"))
videos = list(Path("/tmp").glob("clipslots-v2174-*/fixtures/fixture.mp4"))
video = max(videos, key=lambda path: path.stat().st_mtime) if videos else None
result = subprocess.run([str(work / "probe"), str(work)] + ([str(video)] if video else []), cwd=repo, env=env)
if (work / "report.json").exists():
    (repo / "build/validation/optimization-repairs.json").write_bytes((work / "report.json").read_bytes())
raise SystemExit(result.returncode)
