import Foundation

/// Tool inputs live with the graph, so project copies, undo and archive retain
/// them. Media is referenced by the owning slot's immutable attachment ID.
public struct CanvasToolConfiguration: Codable, Equatable {
    public var audio = CanvasAudioConfiguration()
    public var timeline = CanvasTimelineConfiguration()
    public var stage = CanvasStageConfiguration()
    public var resourceAttachmentID: String?
    public var cloudGeneration: CanvasCloudConfiguration?
    public var cloudResources: [String: CanvasCloudResourceMetadata]?
    public init() {}

    public func validationError(for kind: CanvasNodeKind) -> String? {
        if let resources=cloudResources,!resources.allSatisfy({
            $0.value.metricScale.isFinite && (0.00001...100000).contains($0.value.metricScale)
                && $0.value.groundOffset.isFinite && abs($0.value.groundOffset)<=100000
        }) {return "云端资源的坐标元数据无效"}
        func output(_ width: Int, _ height: Int, _ fps: Int) -> Bool {
            (16...4096).contains(width) && (16...4096).contains(height)
                && width.isMultiple(of: 2) && height.isMultiple(of: 2) && (1...60).contains(fps)
        }
        func color(_ value: String) -> Bool {
            let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
            return hex.count == 6 && UInt32(hex, radix: 16) != nil
        }
        func vector(_ value: CanvasVector3) -> Bool {
            value.isFinite && [value.x,value.y,value.z].allSatisfy { abs($0) <= 100000 }
        }
        switch kind {
        case .audio:
            if !audio.rate.isFinite || !audio.pitch.isFinite || !audio.volume.isFinite
                || !(0.1...0.6).contains(audio.rate) || !(0.5...2).contains(audio.pitch)
                || !(0...1).contains(audio.volume) || audio.text.count > 30000 { return "配音参数无效" }
        case .timeline:
            if !output(timeline.width,timeline.height,timeline.fps)
                || timeline.clips.count > 500 || !timeline.clips.allSatisfy(\.isValid)
                || Set(timeline.clips.map(\.id)).count != timeline.clips.count
                || !timeline.duration.isFinite || timeline.duration > 86400 { return "时间线参数无效，请检查裁剪范围和输出尺寸" }
            var end: Double = 0
            for clip in timeline.clips.filter({ !$0.isAudio }).sorted(by: { $0.timelineStart < $1.timelineStart }) {
                if clip.timelineStart < end { return "视频片段重叠，请调整顺序" }
                end = clip.end
            }
        case .stage:
            if !output(stage.width,stage.height,stage.fps) || stage.entities.count > 200
                || stage.shots.isEmpty || stage.shots.count > 100
                || !stage.duration.isFinite || stage.duration > 600 || !color(stage.background)
                || Set(stage.entities.map(\.id)).count != stage.entities.count
                || Set(stage.shots.map(\.id)).count != stage.shots.count { return "片场参数无效" }
            if !stage.entities.allSatisfy({
                vector($0.position) && vector($0.rotation) && vector($0.scale) && color($0.color)
                    && [$0.scale.x,$0.scale.y,$0.scale.z].allSatisfy { abs($0) > 0.00001 && abs($0) <= 10000 }
            }) { return "对象变换或颜色无效" }
            if !stage.shots.allSatisfy({
                $0.duration.isFinite && (0.1...600).contains($0.duration)
                    && vector($0.camera) && vector($0.target) && $0.camera != $0.target
                    && $0.focalLength.isFinite && (8...300).contains($0.focalLength)
            }) { return "镜头位置、时长或焦距无效" }
            if let error = stage.advancedValidationError { return error }
        default: break
        }
        return nil
    }
}

public struct CanvasAudioConfiguration: Codable, Equatable {
    public enum Scene: String, Codable, CaseIterable {
        case music, sound, speech
        public var title: String {
            switch self { case .music: return "音乐"; case .sound: return "音效"; case .speech: return "文字转语音" }
        }
    }
    public var scene: Scene = .music
    public var text = ""
    public var voiceID = ""
    public var rate: Double = 0.5
    public var pitch: Double = 1
    public var volume: Double = 1
    public var loop = false
    public init() {}
}

public struct CanvasTimelineClip: Codable, Equatable, Identifiable {
    public var id = UUID().uuidString
    public var attachmentID: String
    public var name: String
    public var sourceStart: Double
    public var sourceEnd: Double
    public var timelineStart: Double
    public var isAudio: Bool
    public var volume: Double
    public init(attachmentID: String, name: String, duration: Double, isAudio: Bool = false,
                timelineStart: Double = 0) {
        self.attachmentID = attachmentID; self.name = name
        sourceStart = 0; sourceEnd = duration; self.timelineStart = timelineStart
        self.isAudio = isAudio; volume = 1
    }
    public var duration: Double { max(0, sourceEnd - sourceStart) }
    public var end: Double { timelineStart + duration }
    public var isValid: Bool {
        [sourceStart, sourceEnd, timelineStart, volume].allSatisfy(\.isFinite)
            && sourceStart >= 0 && sourceEnd > sourceStart && timelineStart >= 0
            && (0...2).contains(volume) && sourceEnd <= 86400
    }
}

public struct CanvasTimelineConfiguration: Codable, Equatable {
    public var clips: [CanvasTimelineClip] = []
    public var width = 1920
    public var height = 1080
    public var fps = 30
    public init() {}
    public var duration: Double { clips.map(\.end).max() ?? 0 }
    /// Video order is sequential; audio keeps its explicit placement.
    public mutating func reflowVideo() {
        var cursor: Double = 0
        for index in clips.indices where !clips[index].isAudio {
            clips[index].timelineStart = cursor; cursor += clips[index].duration
        }
    }
    public mutating func split(id: String, at time: Double) -> Bool {
        guard let index = clips.firstIndex(where: { $0.id == id }), clips[index].isValid else { return false }
        let clip = clips[index], offset = time - clip.timelineStart
        guard offset > 0.03, offset < clip.duration - 0.03 else { return false }
        var right = clip; right.id = UUID().uuidString
        right.sourceStart += offset; right.timelineStart = time
        clips[index].sourceEnd = right.sourceStart
        clips.insert(right, at: index + 1); return true
    }
}

public struct CanvasVector3: Codable, Equatable {
    public var x: Double; public var y: Double; public var z: Double
    public init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

public struct CanvasStageEntity: Codable, Equatable, Identifiable {
    public enum Shape: String, Codable, CaseIterable { case resource, box, sphere, plane, light }
    public var id = UUID().uuidString
    public var name: String
    public var shape: Shape
    public var attachmentID: String?
    public var position = CanvasVector3()
    public var rotation = CanvasVector3()
    public var scale = CanvasVector3(1, 1, 1)
    public var color = "#91b4fc"
    public var visible = true
    public init(name: String, shape: Shape, attachmentID: String? = nil) {
        self.name = name; self.shape = shape; self.attachmentID = attachmentID
    }
}

public struct CanvasStageShot: Codable, Equatable, Identifiable {
    public var id = UUID().uuidString
    public var name = "镜头"
    public var duration: Double = 3
    public var camera = CanvasVector3(0, 2, 6)
    public var target = CanvasVector3()
    public var focalLength: Double = 35
    public init() {}
}

public struct CanvasStageConfiguration: Codable, Equatable {
    public var entities: [CanvasStageEntity] = []
    public var shots: [CanvasStageShot] = [CanvasStageShot()]
    public var background = "#17181b"
    public var width = 1920
    public var height = 1080
    public var fps = 30
    public var advanced: CanvasStageAdvancedConfiguration?
    public init() {}
    public var duration: Double { shots.reduce(0) { $0 + max(0, $1.duration) } }
}
