#if DEBUG
import AppKit
import SceneKit
import ClipSlotsKit

private final class CloudFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String:String], Data))?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        do {
            guard let handler=Self.handler else { throw CanvasCloudError.remote }
            let (status,headers,data)=try handler(request)
            guard let url=request.url,let response=HTTPURLResponse(url:url,statusCode:status,httpVersion:"HTTP/1.1",headerFields:headers) else { throw CanvasCloudError.remote }
            client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
        } catch {client?.urlProtocol(self,didFailWithError:error)}
    }
    override func stopLoading() {}
}

enum CanvasCloudRegression {
    @MainActor static func session(_ session:CanvasToolSession,fixtures:URL,check:(Bool,String)->Void) async {
        do {
            let before=session.configuration,attachments=session.attachments
            var expected=before,cloud=CanvasCloudConfiguration()
            cloud.provider = .tripo;cloud.mode = .text3D;cloud.prompt="fixture model"
            cloud.task = .init(provider:.tripo,mode:.text3D,id:"fixture-session-task",state:.pending)
            expected.cloudGeneration=cloud
            check(session.save(expected,detail:"fixture task"),"fixture pending task saves through canvas transaction")
            let metadata=CanvasCloudResourceMetadata(provider:.tripo,taskID:"fixture-session-task")
            let data=try Data(contentsOf:fixtures.appendingPathComponent("triangle.glb"))
            let result=CanvasCloudClient.Result(data:data,fileExtension:"glb",metadata:metadata)
            try await session.acceptCloud(result,expected:expected)
            guard let id=session.configuration.resourceAttachmentID else {throw CanvasToolError.invalid("缺少结果资源")}
            check(session.configuration.cloudResources?[id]==metadata
                && session.configuration.cloudGeneration?.task?.state == .complete,"fixture cloud import binds immutable metadata and completed task")
            check(session.attachments.count==attachments.count+1 && session.scene != nil,"fixture cloud result actually decodes and stores attachment")
            _=session.canvas.undo();session.attachments=session.store.canvasSlotAttachments(groupId:session.node!.groupId,slot:session.node!.slot)
            check(session.configuration==expected && session.attachments==attachments,"cloud attachment and task completion undo together")
            _=session.canvas.undo()
            check(session.configuration==before,"cloud pending task undo")
            do {try await session.acceptCloud(result,expected:expected);check(false,"cloud late result rejects changed source")}
            catch {check(session.configuration==before && session.attachments==attachments,"cloud late result rejects changed source")}
            try await session.refreshPreview()
            let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[CloudFixtureProtocol.self]
            let client=CanvasCloudClient(http:.init(configuration:configuration))
            var rig=cloud;rig.task=nil;rig.mode = .rig;rig.sourceTaskID="fixture-source"
            var routes=[String]()
            CloudFixtureProtocol.handler={request in
                let route=request.url?.path ?? "";routes.append(route)
                if route.hasSuffix("rig-check") {
                    return (200,[:],try JSONSerialization.data(withJSONObject:["code":0,"data":["riggable":true,"rig_type":"biped"]]))
                }
                return (200,[:],try JSONSerialization.data(withJSONObject:["code":0,"data":["task_id":"fixture-rig"]]))
            }
            let rigTask=try await client.submit(rig,key:"fixture-key")
            check(rigTask.id=="fixture-rig" && routes==["/v3/animations/rig-check","/v3/animations/rig"],"fixture synchronous rig check before rig")
            routes=[]
            CloudFixtureProtocol.handler={request in
                let route=request.url?.path ?? "";routes.append(route)
                let object:[String:Any]
                if route.hasSuffix("rig-check") {object=["code":0,"data":["task_id":"fixture-check"]]}
                else if route.hasSuffix("fixture-check") {object=["code":0,"data":["task_id":"fixture-check","status":"success","output":["riggable":true,"rig_type":"biped"]]]}
                else {object=["code":0,"data":["task_id":"fixture-rig-async"]]}
                return (200,[:],try JSONSerialization.data(withJSONObject:object))
            }
            let asyncRig=try await client.submit(rig,key:"fixture-key")
            check(asyncRig.id=="fixture-rig-async" && routes.count==3,"fixture asynchronous rig check task before rig")
            CloudFixtureProtocol.handler=nil
        } catch {check(false,"cloud session regression exception: \(error.localizedDescription)")}
    }
    @MainActor static func run(fixtures:URL,directory:URL,check:(Bool,String)->Void) async {
        do {
            func json(_ value:[String:Any]) throws -> Data { try JSONSerialization.data(withJSONObject:value) }
            func body(_ request:URLRequest) -> Data? {
                if let data=request.httpBody {return data}
                guard let stream=request.httpBodyStream else {return nil}
                stream.open();defer {stream.close()}
                var data=Data(),buffer=[UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable {
                    let count=stream.read(&buffer,maxLength:buffer.count)
                    if count<=0 {break};data.append(contentsOf:buffer.prefix(count))
                }
                return data
            }
            let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[CloudFixtureProtocol.self]
            let client=CanvasCloudClient(http:.init(configuration:configuration))
            defer {CloudFixtureProtocol.handler=nil}
            var config=CanvasCloudConfiguration();config.prompt="Piano";config.duration=4
            CloudFixtureProtocol.handler={ request in
                guard request.url?.path=="/v1/music",request.value(forHTTPHeaderField:"xi-api-key")=="fixture-key",
                      let data=body(request),let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      object["music_length_ms"] as? Int==4000,object["force_instrumental"] as? Bool==true else {throw CanvasCloudError.remote}
                return (200,["Content-Type":"audio/mpeg","song-id":"fixture-song"],Data(repeating:42,count:64))
            }
            let music=try await client.audio(config,key:"fixture-key")
            check(music.data.count==64 && music.metadata.taskID=="fixture-song","fixture ElevenLabs official music body and raw response")
            CloudFixtureProtocol.handler={_ in (401,[:],Data())}
            do {_=try await client.audio(config,key:"fixture-key");check(false,"fixture auth failure")}
            catch {check(error is CanvasCloudError,"fixture auth failure")}
            config.provider = .miniMax;config.lyrics="hello";config.instrumental=false
            CloudFixtureProtocol.handler={request in
                guard request.value(forHTTPHeaderField:"Authorization")=="Bearer fixture-key" else {throw CanvasCloudError.remote}
                return (200,[:],try json(["base_resp":["status_code":0],"data":["status":2,"audio":String(repeating:"ab",count:32)]]))
            }
            let minimax=try await client.audio(config,key:"fixture-key")
            check(minimax.data==Data(repeating:0xab,count:32),"fixture MiniMax bounded hex decode")
            config.provider = .tripo;config.mode = .text3D;config.prompt="a chair"
            CloudFixtureProtocol.handler={request in
                guard request.url?.path=="/v3/generation/text-to-model",let data=body(request),
                      let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      object["model"] as? String=="v3.1-20260211",object["pbr"] as? Bool==true else {throw CanvasCloudError.remote}
                return (200,[:],try json(["code":0,"data":["task_id":"fixture-task"]]))
            }
            let task=try await client.submit(config,key:"fixture-key")
            check(task.id=="fixture-task" && task.state == .pending,"fixture Tripo task ID contract")
            config.task=task
            check(try JSONDecoder().decode(CanvasCloudConfiguration.self,from:JSONEncoder().encode(config))==config,"cloud task durable recovery Codable")
            CloudFixtureProtocol.handler={request in
                guard request.url?.path=="/v3/tasks/fixture-task" else {throw CanvasCloudError.remote}
                return (200,[:],try json(["code":0,"data":["task_id":"fixture-task","status":"running"]]))
            }
            check(try await !client.status(task,key:"fixture-key").done,"fixture pending does not resubmit")
            let glb=try Data(contentsOf:fixtures.appendingPathComponent("triangle.glb"))
            CloudFixtureProtocol.handler={request in
                if request.url?.host=="cdn.example.com" {
                    guard request.value(forHTTPHeaderField:"Authorization")==nil,
                          request.value(forHTTPHeaderField:"xi-api-key")==nil,
                          request.value(forHTTPHeaderField:"WLT-Api-Key")==nil else {throw CanvasCloudError.remote}
                    return (200,[:],glb)
                }
                return (200,[:],try json(["code":0,"data":["task_id":"fixture-task","status":"success",
                    "output":["model_url":"https://cdn.example.com/model.glb"]]]))
            }
            let status=try await client.status(task,key:"fixture-key")
            let model=try await client.download(status)
            check(model.data==glb && model.fileExtension=="glb","fixture download exact GLB bytes without auth headers on CDN")
            CloudFixtureProtocol.handler={_ in (200,[:],try json(["code":0,"data":["task_id":"different-task","status":"running"]]))}
            do {_=try await client.status(task,key:"fixture-key");check(false,"fixture mismatched task rejection")}
            catch {check(true,"fixture mismatched task rejection")}
            var worldConfig=CanvasCloudConfiguration();worldConfig.provider = .worldLabs;worldConfig.mode = .world;worldConfig.prompt="garden"
            let spz=try Data(contentsOf:fixtures.appendingPathComponent("gaussians-v3.spz"))
            CloudFixtureProtocol.handler={request in
                if request.url?.path=="/marble/v1/worlds:generate" {
                    guard let data=body(request),let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                          let permission=object["permission"] as? [String:Any],permission["public"] as? Bool==false
                    else {throw CanvasCloudError.remote}
                    return (200,[:],try json(["operation_id":"fixture-operation","done":false]))
                }
                if request.url?.host=="cdn.example.com" {
                    guard request.value(forHTTPHeaderField:"WLT-Api-Key")==nil else {throw CanvasCloudError.remote}
                    return (200,[:],spz)
                }
                guard request.value(forHTTPHeaderField:"WLT-Api-Key")=="fixture-key" else {throw CanvasCloudError.remote}
                return (200,[:],try json(["operation_id":"fixture-operation","done":true,"response":[
                    "assets":["splats":["spz_urls":["100k":"https://cdn.example.com/world.spz"]],
                              "semantics_metadata":["metric_scale_factor":2.0,"ground_plane_offset":0.5]]]]))
            }
            let worldTask=try await client.submit(worldConfig,key:"fixture-key")
            let worldStatus=try await client.status(worldTask,key:"fixture-key")
            let world=try await client.download(worldStatus)
            check(world.data==spz && world.metadata.metricScale==2 && world.metadata.groundOffset==0.5
                && world.metadata.marbleCoordinates,"fixture World Labs private request operation SPZ and metric metadata")
            let raw=try CanvasSPZ.decode(spz),adjusted=CanvasSPZ.transformed(raw,metadata:world.metadata)
            check(abs(adjusted.splats[0].center.x-raw.splats[0].center.x*2)<0.001
                && abs(adjusted.splats[0].center.y-(-raw.splats[0].center.y*2+0.5))<0.001,"World Labs metric ground and coordinate conversion")
            check(!CanvasCloudClient.allowedDownloadURL(URL(string:"https://127.0.0.1/a")!)
                && !CanvasCloudClient.allowedDownloadURL(URL(string:"http://cdn.example.com/a")!)
                && !CanvasCloudClient.allowedDownloadURL(URL(string:"https://name:secret@cdn.example.com/a")!),"cloud download rejects local cleartext and credential URLs")
            var request=URLRequest(url:URL(string:"https://cdn.example.com/bounded")!)
            request.httpMethod="GET";CloudFixtureProtocol.handler={_ in (200,[:],Data(repeating:1,count:500))}
            do {_=try await client.http.send(request,limit:100);check(false,"fixture streamed byte bound")}
            catch {check(true,"fixture streamed byte bound")}
            var old=CanvasToolConfiguration()
            let encoded=try JSONEncoder().encode(old)
            var oldJSON=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
            oldJSON.removeValue(forKey:"cloudGeneration");oldJSON.removeValue(forKey:"cloudResources")
            var oldStage=oldJSON["stage"] as! [String:Any];oldStage.removeValue(forKey:"advanced");oldJSON["stage"]=oldStage
            check(try JSONDecoder().decode(CanvasToolConfiguration.self,from:json(oldJSON))==old,"v85 tool configuration remains decodable")
            old.cloudGeneration=config
            let output=try JSONEncoder().encode(old)
            check(!String(decoding:output,as:UTF8.self).contains("fixture-key"),"cloud configuration stores no credentials")
            let animated=try CanvasGLBScene.load(fixtures.appendingPathComponent("animated-skin-morph.glb"),name:"animated-skin-morph.glb")
            check(CanvasGLBScene.animationCount(animated.rootNode)==1,"GLB animation clip decoded")
            try CanvasGLBScene.sample(node:animated.rootNode,time:0.5)
            let bone=animated.rootNode.childNode(withName:"Bone",recursively:true)
            check(abs((bone?.position.x ?? 0)-0.5)<0.0001,"GLB real bone translation sampled")
            var primitives=[SCNNode]()
            animated.rootNode.enumerateChildNodes {node,_ in if node.skinner != nil {primitives.append(node)}}
            check(primitives.count==1 && primitives[0].skinner?.bones.first === bone,"GLB skinner references original joint")
            check(abs((primitives.first?.morpher?.weights.first?.doubleValue ?? 0)-0.5)<0.0001,"GLB morph weight sampled")
            _=try CanvasGLBScene.load(fixtures.appendingPathComponent("sparse.glb"),name:"sparse.glb")
            check(true,"GLB sparse accessor without dense buffer")
            var stage=CanvasStageConfiguration();stage.width=320;stage.height=180;stage.shots[0].duration=2
            let entity=CanvasStageEntity(name:"actor",shape:.resource,attachmentID:"model")
            stage.entities=[entity]
            stage.recordKeyframe(ownerID:entity.id,property:.position,time:0,value:CanvasVector3())
            stage.recordKeyframe(ownerID:entity.id,property:.position,time:1,value:CanvasVector3(2,0,0))
            let urls=["model":(url:fixtures.appendingPathComponent("animated-skin-morph.glb"),name:"animated-skin-morph.glb")]
            let scene=try CanvasStageRenderer.scene(stage,urls:urls)
            try CanvasStageRenderer.apply(stage,time:0.5,scene:scene)
            check(abs((scene.rootNode.childNode(withName:entity.id,recursively:false)?.position.x ?? 0)-1)<0.001,"stage entity keyframe position sampled")
            var saved=stage;saved.captureSetup(name:"A")
            let id=saved.animation.setups[0].id,revision=saved.animation.revision
            saved.entities[0].position.x=10
            check(!saved.restoreSetup(id:id,expectedRevision:revision-1),"setup rejects stale revision")
            check(saved.restoreSetup(id:id,expectedRevision:revision) && saved.entities[0].position.x==0,"setup restores independent baseline")
            let a=directory.appendingPathComponent("animated-0.png"),b=directory.appendingPathComponent("animated-05.png")
            try CanvasStageRenderer.photograph(stage,urls:urls,time:0,to:a)
            try CanvasStageRenderer.photograph(stage,urls:urls,time:0.5,to:b)
            func pixels(_ url:URL)throws->Data {
                guard let image=NSImage(contentsOf:url),let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),
                      let bytes=bitmap.bitmapData else {throw CanvasToolError.invalid("测试画面读取失败")}
                return Data(bytes:bytes,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
            }
            check(try pixels(a) != pixels(b),"actual GLB skin morph and stage motion rendered pixels change")
            var staticStage=stage;staticStage.advanced=nil
            let c=directory.appendingPathComponent("skin-morph-0.png"),d=directory.appendingPathComponent("skin-morph-05.png")
            try CanvasStageRenderer.photograph(staticStage,urls:urls,time:0,to:c)
            try CanvasStageRenderer.photograph(staticStage,urls:urls,time:0.5,to:d)
            check(try pixels(c) != pixels(d),"actual GLB skin and morph animation pixels without stage motion")
            var worldStage=CanvasStageConfiguration();worldStage.width=320;worldStage.height=180
            worldStage.shots[0].camera=CanvasVector3(0,0,4);worldStage.shots[0].duration=0.2;worldStage.fps=10
            let worldEntity=CanvasStageEntity(name:"world",shape:.resource,attachmentID:"world")
            var box=CanvasStageEntity(name:"occluder",shape:.box);box.position.z=1;box.color="#ff1000";box.scale=CanvasVector3(1.5,1.5,0.2)
            worldStage.entities=[worldEntity,box]
            let worldURLs=["world":(url:fixtures.appendingPathComponent("gaussians-v3.spz"),name:"gaussians-v3.spz")]
            let front=directory.appendingPathComponent("spz-mesh-front.png"),back=directory.appendingPathComponent("spz-mesh-back.png")
            try CanvasStageRenderer.photograph(worldStage,urls:worldURLs,time:0,to:front)
            worldStage.entities[1].position.z = -1
            try CanvasStageRenderer.photograph(worldStage,urls:worldURLs,time:0,to:back)
            func center(_ url:URL)throws->NSColor {
                guard let image=NSImage(contentsOf:url),let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),
                      let color=bitmap.colorAt(x:160,y:90)?.usingColorSpace(.deviceRGB) else {throw CanvasToolError.invalid("测试像素无效")}
                return color
            }
            let frontPixel=try center(front),backPixel=try center(back)
            check(frontPixel.redComponent>frontPixel.blueComponent+0.1
                && backPixel.blueComponent>frontPixel.blueComponent+0.1,"SPZ mesh common camera actual depth occlusion")
            let worldVideo=directory.appendingPathComponent("spz-stage.mp4")
            try await CanvasStageRenderer.exportVideo(worldStage,urls:worldURLs,to:worldVideo)
            let facts=try await CanvasToolMedia.inspect(worldVideo)
            check(facts.video && abs(facts.duration-0.2)<0.01,"SPZ and mesh real MP4 export")
            let environment=directory.appendingPathComponent("environment.png")
            let image=NSImage(size:CGSize(width:64,height:32),flipped:false) {rect in NSColor.white.setFill();rect.fill();return true}
            if let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff) {
                try bitmap.representation(using:.png,properties:[:])?.write(to:environment)
            }
            var envStage=CanvasStageConfiguration();envStage.width=160;envStage.height=90
            envStage.entities=[CanvasStageEntity(name:"sphere",shape:.sphere)]
            let noEnv=directory.appendingPathComponent("environment-none.png"),withEnv=directory.appendingPathComponent("environment-lit.png")
            try CanvasStageRenderer.photograph(envStage,urls:[:],time:0,to:noEnv)
            envStage.animation.environment.attachmentID="env";envStage.animation.environment.intensity=4
            try CanvasStageRenderer.photograph(envStage,urls:["env":(url:environment,name:"environment.png")],time:0,to:withEnv)
            check(try pixels(noEnv) != pixels(withEnv),"environment lighting changes actual rendered pixels")
            var track=CanvasStageTrack(ownerID:entity.id,property:.position)
            track.frames=[.init(time:0,value:CanvasVector3()),.init(time:1,value:CanvasVector3(1,0,0))]
            track.frames[0].interpolation = .smooth
            check(abs((track.sample(at:0.25)?.x ?? 0)-0.15625)<0.0001,"smooth keyframe interpolation")
            track.frames[0].interpolation = .step
            check(track.sample(at:0.75)?.x==0,"step keyframe interpolation")
            track.frames[0].interpolation = .bezier;track.frames[0].outgoing.y=1;track.frames[1].incoming.y=1
            check(abs((track.sample(at:0.5)?.y ?? 0)-0.75)<0.0001,"spatial cubic Bezier bend interpolation")
        } catch {check(false,"cloud advanced regression exception: \(error.localizedDescription)")}
    }
}
#endif
