"""Package the local candidate with an executable launcher that always isolates data/config.

No installation, downloads, signing identity changes, or user data copies.
Run after swift build. The output is a local, ad-hoc signed debug candidate.
"""
import hashlib
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess

repo = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--variant", choices=["agent-loop", "batch-visual", "creative-optimized", "creative-active", "creative-refined", "light-agent-halo", "light-agent-color", "canvas-menu", "batch-folders", "text-input", "advanced-text", "agent-groups"], default="agent-loop")
parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
args = parser.parse_args()
variants = {
    "agent-loop": ("agent-loop-candidate", "ClipSlots Agent Loop", "21781104"),
    "batch-visual": ("batch-visual-candidate", "ClipSlots Batch Preview", "21781105"),
    "creative-optimized": ("creative-optimized-candidate", "ClipSlots Creative Preview", "21781106"),
    "creative-active": ("creative-active-candidate", "ClipSlots Creative Preview", "21781107"),
    "creative-refined": ("creative-refined-candidate", "ClipSlots Creative Preview", "21781108"),
    "light-agent-halo": ("light-agent-halo-candidate", "ClipSlots Light Preview", "21781109"),
    "light-agent-color": ("light-agent-color-candidate", "ClipSlots Light Preview", "21781110"),
    "canvas-menu": ("canvas-menu-candidate", "ClipSlots Menu Preview", "21781111"),
    "batch-folders": ("batch-folders-candidate", "ClipSlots Batch Folders Preview", "2171001"),
    "text-input": ("text-input-candidate", "ClipSlots Text Input Preview", "2171004"),
    "advanced-text": ("advanced-text-candidate", "ClipSlots Advanced Text Preview", "2171005"),
    "agent-groups": ("agent-groups-candidate", "ClipSlots Agent Groups Preview", "2171006"),
}
folder, app_name, candidate_build = variants[args.variant]
out = repo / "build" / folder
app = out / (app_name + ".app")
contents = app / "Contents"
macos = contents / "MacOS"
resources = contents / "Resources"
macos.mkdir(parents=True, exist_ok=True)
resources.mkdir(parents=True, exist_ok=True)
shutil.copytree(repo / "skills", resources / "skills", dirs_exist_ok=True)
for source, target in [
    (repo / ".build" / args.configuration / "ClipSlots", macos / "ClipSlots-bin"),
    (repo / ".build" / args.configuration / "ClipSlotsCLI", macos / "clipslots-cli"),
    (repo / "assets/AppIcon.icns", resources / "AppIcon.icns"),
]:
    shutil.copy2(source, target)
info = plistlib.loads((repo / "Info.plist").read_bytes())
baseline_build = info["CFBundleVersion"]
info.update(CFBundleIdentifier="com.clipslots." + folder,
            CFBundleName=app_name,
            CFBundleDisplayName=app_name + " · 候选",
            CFBundleExecutable="ClipSlots", CFBundleVersion=candidate_build,
            ClipSlotsIsolatedCandidate=True)
(contents / "Info.plist").write_bytes(plistlib.dumps(info))
# A native launcher works with Finder/LaunchServices and avoids shell quoting.
# Set the env before exec so every child CLI receives the same isolated roots.
launcher = out / "candidate-launcher.c"
launcher.write_text(r'''
#include <mach-o/dyld.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char executable[PATH_MAX], target[PATH_MAX], data[PATH_MAX], config[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return 1;
    char *folder = dirname(executable);
    snprintf(target, sizeof(target), "%s/ClipSlots-bin", folder);
    snprintf(data, sizeof(data), "%s/../../../CandidateData", folder);
    snprintf(config, sizeof(config), "%s/config.toml", data);
    if (setenv("CLIPSLOTS_DATA_DIR", data, 1) ||
        setenv("CLIPSLOTS_CONFIG_PATH", config, 1)) return 1;
    if (argc == 2 && strcmp(argv[1], "--isolation-info") == 0) {
        printf("data=%s\nconfig=%s\n", data, config);
        return 0;
    }
    argv[0] = target;
    execv(target, argv);
    perror("ClipSlots candidate launch");
    return 1;
}
''')
subprocess.run(["clang", "-Os", str(launcher), "-o", str(macos / "ClipSlots")], check=True)
for name in ["ClipSlots-bin", "clipslots-cli", "ClipSlots"]:
    (macos / name).chmod(0o755)
    subprocess.run(["codesign", "--force", "--sign", "-", str(macos / name)], check=True)
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
subprocess.run(["plutil", "-lint", str(contents / "Info.plist")], check=True)
isolation = subprocess.check_output([str(macos / "ClipSlots"), "--isolation-info"], text=True)
assert str(out) in isolation and "CandidateData" in isolation
manifest = {
    "build": candidate_build, "baseline": baseline_build, "version": info["CFBundleShortVersionString"],
    "kind": f"local {args.configuration} candidate; not production release",
    "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
    "source_has_local_changes": bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=repo, text=True).strip()),
    "bundle_id": info["CFBundleIdentifier"],
    "data": str(out / "CandidateData"), "config": str(out / "CandidateData/config.toml"),
    "source_binary_sha256": hashlib.sha256((repo / ".build" / args.configuration / "ClipSlots").read_bytes()).hexdigest(),
    "binary_sha256": hashlib.sha256((macos / "ClipSlots-bin").read_bytes()).hexdigest(),
    "cli_sha256": hashlib.sha256((macos / "clipslots-cli").read_bytes()).hexdigest(),
    "launcher_isolation": isolation.splitlines(),
    "bundled_skills": [str(p.relative_to(resources)) for p in (resources / "skills").rglob("SKILL.md")],
}
(out / "candidate-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
print(app)
