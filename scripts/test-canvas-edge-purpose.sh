#!/bin/bash
set -euo pipefail

WORK="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---static}"
if [[ "$MODE" != "--static" && "$MODE" != "--run" ]]; then
    printf '%s\n' 'Usage: bash scripts/test-canvas-edge-purpose.sh [--static|--run]' >&2
    exit 2
fi

node - "$WORK" <<'NODE'
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const cp = require("child_process");
const work = process.argv[2];
const read = file => fs.readFileSync(path.join(work, file), "utf8");
const requireFact = (fact, message) => {
    if (!fact) throw new Error(message);
    console.log("STATIC: " + message);
};
const edge = read("Sources/ClipSlotsKit/CanvasEdge.swift");
const models = read("Sources/ClipSlotsKit/CanvasModels.swift");
const store = read("Sources/ClipSlots/CanvasStore.swift");
const inputs = read("Sources/ClipSlotsKit/CanvasEdgeInputs.swift");
const resolver = read("Sources/ClipSlotsKit/CanvasWorkflowSnapshot.swift");
const generation = read("Sources/ClipSlots/CanvasWorkspaceView+Generation.swift");
const workflow = read("Sources/ClipSlotsKit/WorkflowSkill.swift");
const main = read("Tests/ClipSlotsKitSmokeTests/main.swift");
const fixture = read("Tests/ClipSlotsKitSmokeTests/CanvasEdgePurposeTests.swift");
requireFact(edge.includes('case generationInput = "generation-input"') &&
    edge.includes('case draftReference = "draft-reference"'), "both explicit purposes are declared");
requireFact(edge.includes("public enum CanvasEdgeCapability") &&
    edge.includes("capabilities(of: source).contains(.draftReferenceOutput)") &&
    edge.includes("capabilities(of: target).contains(.generationInput)"),
    "typed capabilities participate in actual connection validation");
requireFact(edge.includes("decodeIfPresent(CanvasEdgePurpose.self, forKey: .purpose) ?? .generationInput"),
    "absent legacy purpose defaults to generation input");
requireFact(edge.includes("Set<EdgeKey>()") && edge.includes("let purpose: CanvasEdgePurpose"),
    "normalization uses structured endpoint/purpose identity");
requireFact(edge.includes("for e in edges where e.purpose.isGenerationDependency") &&
    edge.includes("if e.purpose.isGenerationDependency, wouldCreateCycle"),
    "reachability and normalization exclude reference edges from execution cycles");
requireFact(models.includes("case draftVideoID, draftReference") &&
    models.includes("decodeIfPresent(CanvasDraftReference.self") && models.includes("encodeIfPresent(draftReference"),
    "draft params have decode/encode paths");
requireFact(store.includes("CanvasEdgeGraph.connecting(edge, nodes: nodes, edges: edges)") &&
    store.includes("CanvasEdgeGraph.disconnecting(edgeID: edgeId, nodes: nodes, edges: edges)"),
    "store edits call the tested edge/params transaction");
requireFact((store.match(/CanvasEdgeGraph\.reconcilingDraftReferences/g) || []).length >= 3,
    "store deletion, remapping and history restore reconcile references");
requireFact(inputs.includes("let dependencies = generationEdges(edges)") &&
    inputs.includes("guard edge.purpose.isGenerationDependency else { return false }"),
    "ordering and input resolution filter purpose");
requireFact(resolver.includes("$0.purpose.isGenerationDependency &&") &&
    resolver.includes("if node.draftReference?.sourceNodeID != nil"),
    "workflow resolution filters references and blocks unsupported draft submission");
requireFact(generation.includes("CanvasEdgeInputs.generationEdges(canvas.interactionEdges)"),
    "selection success dependencies use generation inputs only");
requireFact(workflow.includes("$0.purpose.isGenerationDependency &&") &&
    workflow.includes("config.draftVideoID = nil; config.draftReference = nil"),
    "generation-only workflow export cannot downgrade draft references");
requireFact((main.match(/runCanvasEdgePurposeTests\(t\)/g) || []).length === 1 &&
    main.includes("--canvas-edge-purpose-only"), "smoke main has one unique fixture call and a dedicated exit");
requireFact(fixture.includes("CanvasStorage(rootOverride: root)") && fixture.includes("CanvasUndoStack()") &&
    fixture.includes("fresh-cache reload") && fixture.includes("corrupt raw execution cycle"),
    "meaningful fixture uses real persistence/history and raw cycle failure");
const guard = JSON.parse(fs.readFileSync("/tmp/clipslots-rea-live-guard.json", "utf8"));
requireFact(guard.work === work, "working root matches the protected task root");
let checked = 0;
for (const [relative, expected] of Object.entries(guard.files)) {
    if (path.isAbsolute(relative) || relative.split(path.sep).includes(".."))
        throw new Error("Unexpected protected path: " + relative);
    // The guard inventories project code/resources, never account credentials.
    if (/(^|\/)(\.env(?:\.|$)|credentials(?:\.|$)|secrets(?:\.|$))/i.test(relative))
        throw new Error("Credential path excluded from this verifier: " + relative);
    const digest = crypto.createHash("sha256").update(fs.readFileSync(path.join(guard.source, relative))).digest("hex");
    if (digest !== expected) throw new Error("Protected SOURCE changed: " + relative);
    checked++;
}
console.log("GUARD: " + checked + " protected SOURCE files match recorded SHA-256");

// Reconstruct the staged Git tree hash without write-tree, index locks or object writes.
const staged = cp.spawnSync("git", ["--no-optional-locks", "-C", guard.source, "ls-files", "--stage", "-z"],
    { encoding: "utf8", env: { ...process.env, GIT_OPTIONAL_LOCKS: "0" } });
if (staged.status !== 0) throw new Error("Cannot read protected index: " + staged.stderr);
const root = { children: new Map() };
for (const record of staged.stdout.split("\0").filter(Boolean)) {
    const match = /^(\d+) ([0-9a-f]{40}) (\d)\t([\s\S]+)$/.exec(record);
    if (!match || match[3] !== "0") throw new Error("Unsupported/conflicted protected index record");
    const parts = match[4].split("/");
    let current = root;
    for (const part of parts.slice(0, -1)) {
        if (!current.children.has(part)) current.children.set(part, { children: new Map() });
        current = current.children.get(part);
    }
    current.children.set(parts[parts.length - 1], { mode: match[1], hash: Buffer.from(match[2], "hex") });
}
function treeHash(tree) {
    const items = [...tree.children.entries()].sort(([a, av], [b, bv]) =>
        Buffer.compare(Buffer.from(a + (av.children ? "/" : "")), Buffer.from(b + (bv.children ? "/" : ""))));
    const body = Buffer.concat(items.map(([name, entry]) => Buffer.concat([
        Buffer.from((entry.children ? "40000" : entry.mode) + " " + name + "\0"),
        entry.children ? treeHash(entry) : entry.hash
    ])));
    return crypto.createHash("sha1").update(Buffer.from("tree " + body.length + "\0")).update(body).digest();
}
requireFact(treeHash(root).toString("hex") === guard.index_tree, "protected SOURCE index tree matches guard");
console.log("Static checks only. No Swift compilation or behavior tests were executed.");
NODE

if [[ "$MODE" == "--static" ]]; then
    exit 0
fi
if [[ "${CLIPSLOTS_REA_MAIN_AGENT_BUILD_APPROVED:-}" != "1" ]]; then
    printf '%s\n' 'Compilation is deferred. The main agent must explicitly set CLIPSLOTS_REA_MAIN_AGENT_BUILD_APPROVED=1.' >&2
    exit 3
fi
SCRATCH="${CLIPSLOTS_REA_BUILD_SCRATCH:-/tmp/clipslots-rea-purpose-build-20261016}"
swift build --package-path "$WORK" --scratch-path "$SCRATCH" --product ClipSlots
swift build --package-path "$WORK" --scratch-path "$SCRATCH" --product ClipSlotsKitSmokeTests
"$SCRATCH/debug/ClipSlotsKitSmokeTests" --canvas-edge-purpose-only
