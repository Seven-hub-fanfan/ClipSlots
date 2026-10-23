#if DEBUG
import AppKit

/// A settled, deliberately untimed diagnostic. Never enabled in frame measurements.
@MainActor
enum EditorNativeMountAudit {
    static func run(root: NSView, window: NSWindow, directory: URL) async -> [String: Any] {
        let directory = directory.appendingPathComponent("editor-native-mount-audit")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        func tree(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(tree) }
        let identities = NSMapTable<NSView, NSNumber>(
            keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
        var nextIdentity = 0
        func identity(_ view: NSView) -> Int {
            if let value = identities.object(forKey: view) { return value.intValue }
            nextIdentity += 1
            identities.setObject(NSNumber(value: nextIdentity), forKey: view)
            return nextIdentity
        }
        func rect(_ rect: CGRect) -> [Double] {
            [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
        }
        guard let originalEditor = tree(root).compactMap({ $0 as? AgentDraftEditor.Editor }).first,
              let card = tree(root).first(where: { $0 is WorkspaceCardBackground.Surface }),
              let scroll = tree(root).compactMap({ $0 as? NSScrollView }).first(where: {
                  guard let document = $0.documentView else { return false }
                  return card.isDescendant(of: document)
              }), let document = scroll.documentView else {
            return ["complete": false, "error": "editor grid or native draft editor not mounted"]
        }
        func scrollStates() -> [[String: Any]] {
            tree(root).compactMap { $0 as? NSScrollView }.map { view in
                let draft = view.documentView.map {
                    originalEditor === $0 || originalEditor.isDescendant(of: $0)
                } ?? false
                return [
                    "id": identity(view), "is_grid": view === scroll, "contains_native_draft": draft,
                    "root_frame": rect(view.convert(view.bounds, to: root)),
                    "clip_bounds": rect(view.contentView.bounds),
                    "document_bounds": view.documentView.map { rect($0.bounds) as Any } ?? NSNull(),
                    "document_is_flipped": view.documentView?.isFlipped ?? false,
                    "maximum_clip_origin": Double(max(0,
                        (view.documentView?.bounds.height ?? 0) - view.contentView.bounds.height)),
                ]
            }
        }
        func resetOtherScrollViews() {
            for view in tree(root).compactMap({ $0 as? NSScrollView }) where view !== scroll {
                guard let content = view.documentView,
                      !(originalEditor === content || originalEditor.isDescendant(of: content)) else { continue }
                let top = content.isFlipped ? content.bounds.minY :
                    max(content.bounds.minY, content.bounds.maxY - view.contentView.bounds.height)
                view.contentView.scroll(to: CGPoint(x: content.bounds.minX, y: top))
                view.reflectScrolledClipView(view.contentView)
            }
        }
        let initialScrollStates = scrollStates()
        var warmupStates = [[String: Any]]()
        resetOtherScrollViews()
        // Lay out both ends twice so screenshots do not compare different lazy estimates.
        for cycle in 0..<2 {
            for fraction: CGFloat in [1, 0] {
                for _ in 0..<4 {
                    root.layoutSubtreeIfNeeded()
                    let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                    scroll.contentView.scroll(to: CGPoint(x: 0, y: maximum * fraction))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    resetOtherScrollViews()
                    await pause(0.2)
                }
                warmupStates.append(["cycle": cycle, "fraction": Double(fraction),
                                     "scroll_views": scrollStates()])
            }
        }
        var checkpoints = [[String: Any]]()
        var previous = [Int: [String: Any]]()
        var originalChromeIDs = Set<Int>()
        var originalCardIDs = Set<Int>()
        var editorStable = true
        var offsetsVerified = true
        let fractions: [CGFloat] = [0, 0.25, 0.5, 0.75, 1, 0]
        for (index, fraction) in fractions.enumerated() {
            // Reconcile the lazy document's estimated extent before collecting a checkpoint.
            for _ in 0..<3 {
                let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: maximum * fraction))
                scroll.reflectScrolledClipView(scroll.contentView)
                await pause(0.15)
            }
            let name = index == 5 ? "back-0" : "offset-\(Int(fraction * 100))"
            resetOtherScrollViews()
            await pause(0.2)
            root.layoutSubtreeIfNeeded()
            let beforeCapture = scrollStates()
            var bitmapMetadata: [String: Any] = [:]
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                bitmapMetadata = [
                    "pixels": [bitmap.pixelsWide, bitmap.pixelsHigh],
                    "bits_per_sample": bitmap.bitsPerSample, "samples_per_pixel": bitmap.samplesPerPixel,
                    "color_space_name": bitmap.colorSpace.localizedName ?? "",
                    "color_space_model": String(describing: bitmap.colorSpace.colorSpaceModel),
                    "icc_profile_bytes": bitmap.colorSpace.iccProfileData?.count ?? 0,
                    "window_backing_scale": Double(window.backingScaleFactor),
                    "effective_appearance": root.effectiveAppearance.name.rawValue,
                ]
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(name + ".png"))
            }
            let immediatelyAfterCapture = scrollStates()
            await pause(0.2)
            let settledAfterCapture = scrollStates()
            let nativeViews = tree(root)
            let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: root)
            var current = [Int: [String: Any]]()
            var histogram = [String: Int](), gridHistogram = [String: Int]()
            var gridIDs = Set<Int>(), cardIDs = Set<Int>(), chromeIDs = Set<Int>()
            var controls = 0, hosting = 0, tracks = 0, constraints = 0
            for view in nativeViews {
                let id = identity(view)
                let type = String(reflecting: Swift.type(of: view))
                let grid = view === document || view.isDescendant(of: document)
                let frame = view.convert(view.bounds, to: root)
                histogram[type, default: 0] += 1
                if grid { gridIDs.insert(id); gridHistogram[type, default: 0] += 1 }
                else { chromeIDs.insert(id) }
                if view is WorkspaceCardBackground.Surface { cardIDs.insert(id) }
                if view is NSControl { controls += 1 }
                if type.contains("HostingView") || type.contains("ContentViewHost") { hosting += 1 }
                tracks += view.trackingAreas.count
                constraints += view.constraints.count
                current[id] = [
                    "id": id, "type": type,
                    "parent_id": view.superview.map { identity($0) as Any } ?? NSNull(),
                    "scope": grid ? "grid" : "chrome",
                    "root_frame": rect(frame), "local_frame": rect(view.frame),
                    "document_frame": grid ? rect(view.convert(view.bounds, to: document)) : NSNull(),
                    "intersects_grid_viewport": grid && !frame.intersection(viewport).isEmpty,
                    "hidden": view.isHidden, "tracking_areas": view.trackingAreas.count,
                    "constraints": view.constraints.count, "is_control": view is NSControl,
                    "is_card_surface": view is WorkspaceCardBackground.Surface,
                ]
            }
            let ids = Set(current.keys)
            let previousIDs = Set(previous.keys)
            let added = ids.subtracting(previousIDs), removed = previousIDs.subtracting(ids)
            let common = ids.intersection(previousIDs)
            func changes(_ changed: Set<Int>, in records: [Int: [String: Any]]) -> [[String: Any]] {
                changed.sorted().compactMap { records[$0] }
            }
            if index == 0 { originalChromeIDs = chromeIDs; originalCardIDs = cardIDs }
            let editor = nativeViews.compactMap { $0 as? AgentDraftEditor.Editor }.first
            editorStable = editorStable && editor === originalEditor
            let maximum = max(0, document.bounds.height - scroll.contentView.bounds.height)
            let actual = scroll.contentView.bounds.origin.y
            offsetsVerified = offsetsVerified && abs(actual - maximum * fraction) < 2
            let checkpoint: [String: Any] = [
                "name": name, "fraction": Double(fraction), "clip_origin": Double(actual),
                "maximum_clip_origin": Double(maximum), "viewport": rect(viewport),
                "scroll_views_before_capture": beforeCapture,
                "scroll_views_immediately_after_capture": immediatelyAfterCapture,
                "scroll_views_settled_after_capture": settledAfterCapture,
                "bitmap_metadata": bitmapMetadata,
                "view_count": current.count, "grid_view_count": gridIDs.count,
                "control_count": controls, "hosting_view_count": hosting,
                "tracking_area_count": tracks, "constraint_count": constraints,
                "histogram": histogram, "grid_histogram": gridHistogram,
                "native_editor_id": editor.map { identity($0) as Any } ?? NSNull(),
                "native_editor_identity_preserved": editor === originalEditor,
                "original_chrome_ids_present": originalChromeIDs.intersection(chromeIDs).count,
                "original_card_surface_ids_present": originalCardIDs.intersection(cardIDs).count,
                "card_surface_ids": cardIDs.sorted(),
                "added_views": index == 0 ? [] : changes(added, in: current),
                "removed_views": changes(removed, in: previous),
                "retained_views_with_changed_root_frame": common.filter {
                    (current[$0]?["root_frame"] as? [Double]) != (previous[$0]?["root_frame"] as? [Double])
                }.count,
                "retained_grid_views_with_changed_document_frame": common.intersection(gridIDs).filter {
                    (current[$0]?["document_frame"] as? [Double]) != (previous[$0]?["document_frame"] as? [Double])
                }.count,
                "views": ids.sorted().compactMap { current[$0] },
            ]
            checkpoints.append(checkpoint)
            previous = current
            NSLog("[EditorNativeMountAudit] %@ views=%ld grid=%ld added=%ld removed=%ld cards=%ld",
                  name, current.count, gridIDs.count, index == 0 ? 0 : added.count, removed.count, cardIDs.count)
        }
        let report: [String: Any] = [
            "complete": true, "scope": "settled native hierarchy audit with static captures; no FPS or timing claim",
            "identity_method": "monotonic IDs with weak object-pointer keys; no offscreen views retained",
            "native_editor_identity_preserved": editorStable, "checkpoint_offsets_verified": offsetsVerified,
            "initial_scroll_views": initialScrollStates, "warmup_states": warmupStates,
            "normalization": "grid selected by card ancestry; other scroll views reset to top except native draft",
            "checkpoints": checkpoints,
        ]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("report.json"))
        return ["complete": true, "checkpoint_count": checkpoints.count,
                "native_editor_identity_preserved": editorStable, "checkpoint_offsets_verified": offsetsVerified,
                "scope": "untimed mount audit; detailed report and six checkpoint PNGs in editor-native-mount-audit"]
    }
}
#endif
