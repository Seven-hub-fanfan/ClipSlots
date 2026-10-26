import Foundation

public struct CanvasStageEnvironment: Codable, Equatable {
    public var attachmentID: String?
    public var rotation: Double = 0
    public var intensity: Double = 1
    public var exposure: Double = 0
    public init() {}
}

public struct CanvasStageKeyframe: Codable, Equatable, Identifiable {
    public enum Interpolation: String, Codable, CaseIterable { case linear, smooth, step, bezier }
    public var id = UUID().uuidString
    public var time: Double
    public var value: CanvasVector3
    public var interpolation: Interpolation = .linear
    public var incoming = CanvasVector3()
    public var outgoing = CanvasVector3()
    public init(time: Double, value: CanvasVector3) { self.time=time;self.value=value }
}
public struct CanvasStageTrack: Codable, Equatable, Identifiable {
    public enum Property: String, Codable, CaseIterable { case position, rotation, scale, camera, target, focalLength }
    public var id = UUID().uuidString
    public var ownerID: String
    public var property: Property
    public var frames: [CanvasStageKeyframe] = []
    public init(ownerID: String, property: Property) { self.ownerID=ownerID;self.property=property }
    public func sample(at time: Double) -> CanvasVector3? {
        guard time.isFinite,!frames.isEmpty else { return nil }
        let ordered=frames.sorted { $0.time<$1.time }
        guard let first=ordered.first,let last=ordered.last else { return nil }
        if time<=first.time { return first.value }; if time>=last.time { return last.value }
        guard let index=ordered.indices.dropLast().first(where:{ time<ordered[$0+1].time }) else { return last.value }
        let a=ordered[index],b=ordered[index+1]
        var t=(time-a.time)/(b.time-a.time)
        if a.interpolation == .step { return a.value }
        if a.interpolation == .smooth { t=t*t*(3-2*t) }
        func axis(_ av:Double,_ bv:Double,_ out:Double,_ into:Double) -> Double {
            if a.interpolation == .bezier {
                let s=1-t
                return s*s*s*av+3*s*s*t*(av+out)+3*s*t*t*(bv+into)+t*t*t*bv
            }
            return av+(bv-av)*t
        }
        return CanvasVector3(axis(a.value.x,b.value.x,a.outgoing.x,b.incoming.x),
                             axis(a.value.y,b.value.y,a.outgoing.y,b.incoming.y),
                             axis(a.value.z,b.value.z,a.outgoing.z,b.incoming.z))
    }
}
public struct CanvasStageRole: Codable, Equatable, Identifiable {
    public var id = UUID().uuidString
    public var name: String
    public var entityID: String
    public var animationIndex: Int = 0
    public var animationSpeed: Double = 1
    public var animationOffset: Double = 0
    public init(name:String,entityID:String) { self.name=name;self.entityID=entityID }
}
public struct CanvasStageSnapshot: Codable, Equatable, Identifiable {
    public var id = UUID().uuidString
    public var name: String
    public var entities: [CanvasStageEntity]
    public var shots: [CanvasStageShot]
    public var background: String
    public var environment: CanvasStageEnvironment
    public var tracks: [CanvasStageTrack]
    public var roles: [CanvasStageRole]
    public init(name:String,config:CanvasStageConfiguration) {
        self.name=name;entities=config.entities;shots=config.shots;background=config.background
        environment=config.animation.environment;tracks=config.animation.tracks;roles=config.animation.roles
    }
}
public struct CanvasStageAdvancedConfiguration: Codable, Equatable {
    public var environment = CanvasStageEnvironment()
    public var tracks: [CanvasStageTrack] = []
    public var roles: [CanvasStageRole] = []
    public var setups: [CanvasStageSnapshot] = []
    public var revision: Int = 0
    public var cutShots = false
    public init() {}
}
extension CanvasStageConfiguration {
    public var animation: CanvasStageAdvancedConfiguration {
        get { advanced ?? .init() }
        set { advanced=newValue }
    }
    public mutating func captureSetup(name: String) {
        var next=animation
        guard next.setups.count<20 else { return }
        next.setups.append(.init(name:name,config:self));next.revision+=1;animation=next
    }
    public mutating func restoreSetup(id:String,expectedRevision:Int) -> Bool {
        guard animation.revision==expectedRevision,let setup=animation.setups.first(where:{$0.id==id}) else { return false }
        entities=setup.entities;shots=setup.shots;background=setup.background
        var next=animation;next.environment=setup.environment;next.tracks=setup.tracks;next.roles=setup.roles
        next.revision+=1;animation=next;return true
    }
    public mutating func recordKeyframe(ownerID:String,property:CanvasStageTrack.Property,time:Double,value:CanvasVector3) {
        var next=animation
        let index: Int
        if let found=next.tracks.firstIndex(where:{$0.ownerID==ownerID && $0.property==property}) { index=found }
        else { next.tracks.append(.init(ownerID:ownerID,property:property));index=next.tracks.count-1 }
        let frame=CanvasStageKeyframe(time:time,value:value)
        if let old=next.tracks[index].frames.firstIndex(where:{abs($0.time-time)<0.0001}) { next.tracks[index].frames[old]=frame }
        else { next.tracks[index].frames.append(frame) }
        next.revision+=1;animation=next
    }
    public var advancedValidationError: String? {
        let value=animation,env=value.environment
        guard env.rotation.isFinite,env.intensity.isFinite,env.exposure.isFinite,
              abs(env.rotation)<=36000,(0...10).contains(env.intensity),(-10...10).contains(env.exposure),
              value.tracks.count<=1200,value.roles.count<=200,value.setups.count<=20,value.revision>=0,
              Set(value.tracks.map(\.id)).count==value.tracks.count,Set(value.roles.map(\.id)).count==value.roles.count,
              Set(value.setups.map(\.id)).count==value.setups.count else { return "环境光、角色或关键帧配置无效" }
        let entityIDs=Set(entities.map(\.id)),shotIDs=Set(shots.map(\.id))
        for track in value.tracks {
            let camera=[CanvasStageTrack.Property.camera,.target,.focalLength].contains(track.property)
            guard (camera ? shotIDs : entityIDs).contains(track.ownerID),track.frames.count<=1000,
                  Set(track.frames.map(\.time)).count==track.frames.count else { return "关键帧引用无效或时间重复" }
            for frame in track.frames {
                guard frame.time.isFinite,(0...600).contains(frame.time),frame.value.isFinite,frame.incoming.isFinite,frame.outgoing.isFinite,
                      [frame.value,frame.incoming,frame.outgoing].allSatisfy({[$0.x,$0.y,$0.z].allSatisfy({abs($0)<=100000})})
                else { return "关键帧数值无效" }
                if track.property == .scale && [frame.value.x,frame.value.y,frame.value.z].contains(where:{abs($0)<0.00001}) { return "缩放关键帧不能为零" }
                if track.property == .focalLength && !(8...300).contains(frame.value.x) { return "焦距关键帧需为 8–300 mm" }
            }
        }
        guard Set(value.roles.map(\.entityID)).count==value.roles.count,value.roles.allSatisfy({
            entityIDs.contains($0.entityID) && $0.animationIndex>=0 && $0.animationIndex<100
                && $0.animationSpeed.isFinite && (0...10).contains($0.animationSpeed)
                && $0.animationOffset.isFinite && abs($0.animationOffset)<=600
        }) else { return "角色绑定或动画速度无效" }
        for setup in value.setups {
            var config=CanvasToolConfiguration()
            config.stage.entities=setup.entities;config.stage.shots=setup.shots;config.stage.background=setup.background
            config.stage.animation.environment=setup.environment;config.stage.animation.tracks=setup.tracks;config.stage.animation.roles=setup.roles
            if config.validationError(for:.stage) != nil { return "保存的布景配置无效" }
        }
        return nil
    }
}
