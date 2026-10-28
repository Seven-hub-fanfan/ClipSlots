import Foundation
import ClipSlotsKit

private actor CrateAlignmentInvocations {
    var values: [[String]] = []
    func record(_ args: [String]) { values.append(args) }
}

func runCrateModelAlignmentTests(_ t: TestRunner) {
    let proJSON = """
    [{"id":"seedream5-pro","enabled":true,"generationTypes":["text-2-image","image-2-image"],
    "parameters":[{"name":"prompt"},{"name":"ratio","options":[{"value":"1:1"},{"value":"3:4"},{"value":"16:9"}]},
    {"name":"width"},{"name":"height"},{"name":"output_format","type":"string"}],
    "defaults":{"width":2048,"height":2048,"output_format":"jpeg"},
    "dimensions":{"minimumPixels":921600,"maximumPixels":4624220,"minimumAspectRatio":0.0625,"maximumAspectRatio":16}}]
    """
    do {
        let pro = try CrateModelCatalog.parse(proJSON)[0]
        t.check(CanvasImageConfiguration.supportsSplit(pro), "Crate Pro sizing follows published dimensions")
        let dimensions = CanvasImageConfiguration.dimensions(ratio: "3:4", quality: "2K", model: pro)
        t.check(dimensions?.width == 1536 && dimensions?.height == 2048,
                "Crate Pro 3:4 2K overrides square defaults")
        t.equal(CanvasImageConfiguration.qualities(for: pro), ["2K"], "Crate Pro does not offer over-limit 3K")
        t.expectThrows("Crate Pro rejects oversized explicit dimensions") {
            _ = try CrateModelParameters.image(.init(model: pro.id, prompt: "x", ratio: "3:4",
                                                     width: 1920, height: 2560), model: pro)
        }
        t.equal(pro.manifest["defaults"]?["output_format"], .string("jpeg"), "Crate full defaults preserved")
        t.check(CrateGeneration.modelDescribeArguments(model: pro.id).contains("--refresh"),
                "Crate submission description bypasses local cache")
    } catch { t.check(false, "Crate Pro fixture: \(error)") }

    guard let path = ProcessInfo.processInfo.environment["CLIPSLOTS_CRATE_ALIGNMENT_MANIFEST"] else { return }
    do {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let all = try CrateModelCatalog.parse(raw)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("crate-model-adapter-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("reference.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/a9sAAAAASUVORK5CYII=")!.write(to: file)
        // Even currently disabled contracts must retain numeric types when re-enabled.
        let manifests = all.map { model -> JSONValue in
            var values = model.manifest.objectValue ?? [:]; values["enabled"] = true
            return .object(values)
        }
        let adapterResults: [(Bool, String)] = smokeAwait {
            do {
                let calls = CrateAlignmentInvocations()
                let adapter = try CrateGenerationAdapter(directory: directory, executor: { invocation in
                    if invocation.submitting {
                        await calls.record(invocation.arguments)
                        return .init(status: 0, stdout: #"{"success":true,"taskId":"123456789012345678"}"#, stderr: "")
                    }
                    let args = invocation.arguments
                    let value = args[1] == "list" ? JSONValue.array(manifests) :
                        manifests.first { $0["id"]?.stringValue == args[2] }!
                    return .init(status: 0, stdout: try value.encodedText(), stderr: "")
                })
                let capabilities = try await adapter.discover()
                let fractional = capabilities.first { $0.id == "image_to_video" }!
                let half = try await adapter.prepare(.init(values: ["prompt": "x", "duration": 0.5,
                    "images": [.string(file.path)]]), capability: fractional)
                let pro = capabilities.first { $0.id == "seedream5-pro" }!
                let image = try await adapter.prepare(.init(values: ["prompt": "x", "width": 1536,
                    "height": 2048, "ratio": "3:4", "output_format": "png"]), capability: pro)
                let nano = capabilities.first { $0.id == "nano-banana2" }!
                let sized = try await adapter.prepare(.init(values: ["prompt": "x", "ratio": "3:4",
                    "resolution": "2K"]), capability: nano)
                _ = try await adapter.submit(half)
                _ = try await adapter.submit(image)
                _ = try await adapter.submit(sized)
                let args = await calls.values
                return [
                    (args[0].contains("duration=0.5") && args[0].contains("--image"),
                     "Crate adapter keeps fractional duration and legacy image role"),
                    (args[1].contains("output_format=png"), "Crate adapter forwards published output format"),
                    (args[2].contains("resolution=2K"), "Crate adapter and canvas both forward Nano resolution")]
            } catch { return [(false, "Crate full adapter metadata: \(error)")] }
        }
        for (ok, name) in adapterResults { t.check(ok, name) }
        let generators = all.filter { $0.enabled && ($0.isImageGenerator || $0.isVideoGenerator) }
        var cases: [[String: Any]] = []
        var models: [[String: Any]] = []
        for model in generators {
            let parameters = model.manifest["parameters"]?.arrayValue ?? []
            t.equal(model.parameterNames, Set(parameters.compactMap { $0["name"]?.stringValue }),
                    "\(model.id) reads every published parameter")
            t.equal(model.ratioOptions.map(\.value),
                    parameters.first { $0["name"] == .string("ratio") }?["options"]?.arrayValue?.compactMap { $0["value"]?.stringValue } ?? [],
                    "\(model.id) preserves exact ratio values")
            t.equal(model.resolutionOptions.map(\.value),
                    parameters.first { $0["name"] == .string("resolution") }?["options"]?.arrayValue?.compactMap { $0["value"]?.stringValue } ?? [],
                    "\(model.id) preserves exact resolution case")
            let split = CanvasImageConfiguration.supportsSplit(model)
            let ratios = split ? CanvasImageConfiguration.ratios(for: model) :
                (model.ratioOptions.isEmpty ? [""] : model.ratioOptions.map(\.value))
            let resolutions = split ? CanvasImageConfiguration.qualities(for: model) :
                (model.resolutionOptions.isEmpty ? [""] : model.resolutionOptions.map(\.value))
            var submitted = 0, blocked = 0
            for ratio in ratios {
                for resolution in resolutions {
                    var durations: [Int?] = model.isVideoGenerator
                        ? [nil] + (model.durationSpec?.selectableValues ?? []).map(Optional.some) : [nil]
                    if case .range(_, _, _, let special) = model.durationSpec {
                        durations += special.map(Optional.some)
                    }
                    for duration in durations {
                        var node = CanvasNode(pageId: "p", groupId: "g", slot: 1,
                            kind: model.isVideoGenerator ? .video : .image, x: 0, y: 0, width: 400, height: 300)
                        node.model = model.id; node.ratio = ratio; node.resolution = resolution; node.duration = duration
                        let images = model.requiresImageInput ? ["/private/tmp/crate-alignment-reference.png"] : []
                        let fact = CanvasWorkflowFacts(node: node, title: "", body: "只读参数校验", bodyRevision: "",
                                                       inputImagePaths: images, expectedInputImages: images.count)
                        let plan = CanvasWorkflowResolver.resolve(fact, all: [node.id: fact], edges: [], model: model)
                        if !plan.blockingReasons.isEmpty {
                            blocked += 1
                            t.check(model.isVideoGenerator && model.resolutionDurations[resolution] != nil,
                                    "\(model.id) only dependent resolution/duration combination blocks: \(plan.blockingReasons)")
                            continue
                        }
                        let args: [String]
                        if let image = plan.imageRequest {
                            args = try CrateGeneration.submitArguments(image)
                            if model.supportsResolution, !resolution.isEmpty {
                                t.check(args.contains("resolution=\(resolution)"), "\(model.id) image resolution reaches CLI")
                            }
                            if split {
                                t.check(model.imageDimensionLimits.allows(width: image.width ?? 0, height: image.height ?? 0),
                                        "\(model.id) \(ratio) \(resolution) respects model dimensions")
                                t.check(!args.contains(where: { $0.hasPrefix("resolution=") }),
                                        "\(model.id) sizing label is not sent as unpublished parameter")
                            }
                        } else if let video = plan.videoRequest {
                            args = try CrateGeneration.submitArguments(video)
                            if !model.supportsFirstFrame, model.requiresImageInput {
                                t.check(args.contains("--image") && !args.contains("--first-frame"),
                                        "\(model.id) legacy video uses image input")
                            }
                        } else { t.check(false, "\(model.id) missing request"); continue }
                        cases.append(["model": model.id, "args": args, "ratio": ratio, "resolution": resolution])
                        submitted += 1
                    }
                }
            }
            if model.isVideoGenerator, !model.textOnlyResolutions.isEmpty {
                t.expectThrows("\(model.id) rejects text-only resolution with an input frame") {
                    _ = try CrateModelParameters.video(.init(model: model.id, prompt: "x",
                        resolution: model.textOnlyResolutions[0], firstFramePath: "/private/tmp/input.png"), model: model)
                }
            }
            t.check(submitted > 0, "\(model.id) has validated parameter combinations")
            models.append(["id": model.id, "kind": model.isImageGenerator ? "image" : "video",
                           "valid_cases": submitted, "blocked_cases": blocked,
                           "parameter_count": parameters.count])
        }
        if let output = ProcessInfo.processInfo.environment["CLIPSLOTS_CRATE_ALIGNMENT_OUTPUT"] {
            let result: [String: Any] = ["models": models, "model_count": generators.count,
                                        "cases": cases, "case_count": cases.count]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
        t.check(!generators.isEmpty, "Crate live manifest contains generation models")
    } catch { t.check(false, "Crate live manifest alignment: \(error)") }
}
