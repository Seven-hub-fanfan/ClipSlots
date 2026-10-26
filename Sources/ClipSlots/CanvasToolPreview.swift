import SwiftUI
import SceneKit
import MetalKit
import ClipSlotsKit

struct CanvasStageCompositePreview:NSViewRepresentable {
    let composite:CanvasStageComposite
    let time:Double
    var capture:((@escaping () throws -> NSImage)->Void)?
    func makeNSView(context:Context)->MTKView {
        let view=MTKView(frame:.zero,device:composite.device)
        view.colorPixelFormat = .bgra8Unorm;view.depthStencilPixelFormat = .depth32Float
        view.framebufferOnly=false;view.enableSetNeedsDisplay=true;view.isPaused=true
        updateNSView(view,context:context);return view
    }
    func updateNSView(_ view:MTKView,context:Context) {
        view.device=composite.device;view.delegate=composite;composite.time=time
        capture? {[weak view] in try composite.photograph(size:view?.drawableSize ?? CGSize(width:640,height:360))}
        view.draw()
    }
}

struct CanvasScenePreview: NSViewRepresentable {
    let scene: SCNScene
    var time: Double = 0
    var stage: CanvasStageConfiguration?
    var resetToken = 0
    var capture: ((@escaping () throws -> NSImage) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var scene: SCNScene?; var reset = -1 }
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(); view.allowsCameraControl = true; view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X; view.rendersContinuously = false
        view.preferredFramesPerSecond = 60; view.backgroundColor = .clear
        updateNSView(view, context: context); return view
    }
    func updateNSView(_ view: SCNView, context: Context) {
        capture? { [weak view] in
            guard let view else {throw CanvasToolError.invalid("预览已关闭")}
            return view.snapshot()
        }
        if context.coordinator.scene !== scene || context.coordinator.reset != resetToken {
            context.coordinator.scene = scene; context.coordinator.reset = resetToken; view.scene = scene
            if let camera = scene.rootNode.childNode(withName: "clipslots-camera", recursively: false) {
                view.pointOfView = camera; view.allowsCameraControl = stage == nil
            } else {
                let camera = SCNNode(); camera.camera = SCNCamera()
                let bounds = scene.rootNode.boundingBox
                let center = SCNVector3((bounds.min.x + bounds.max.x)/2, (bounds.min.y + bounds.max.y)/2, (bounds.min.z + bounds.max.z)/2)
                let extent = max(0.1, max(bounds.max.x - bounds.min.x, max(bounds.max.y - bounds.min.y, bounds.max.z - bounds.min.z)))
                camera.position = SCNVector3(center.x, center.y + extent * 0.2, center.z + extent * 1.8)
                camera.look(at: center); view.pointOfView = camera
            }
        }
        if let stage { try? CanvasStageRenderer.apply(stage,time:time,scene:scene) }
        else { try? CanvasGLBScene.sample(node:scene.rootNode,time:time) }
        view.sceneTime = time; view.setNeedsDisplay(view.bounds)
    }
}

struct CanvasGaussianPreview: NSViewRepresentable {
    let cloud: CanvasGaussianCloud
    var resetToken = 0
    var capture: ((@escaping () throws -> NSImage) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: CanvasGaussianRenderer?; var reset = -1 }
    func makeNSView(context: Context) -> GaussianView {
        let view = GaussianView()
        do {
            let renderer = try CanvasGaussianRenderer(cloud: cloud); context.coordinator.renderer = renderer
            view.device = renderer.device; view.delegate = renderer; view.renderer = renderer
            view.colorPixelFormat = .bgra8Unorm; view.clearColor = MTLClearColorMake(0.03,0.03,0.03,1)
            view.enableSetNeedsDisplay = true; view.isPaused = true; view.framebufferOnly = false
            view.draw()
        } catch {
            let label = NSTextField(labelWithString: error.localizedDescription)
            label.frame = NSRect(x: 12, y: 12, width: 600, height: 50); view.addSubview(label)
        }
        return view
    }
    func updateNSView(_ view: GaussianView, context: Context) {
        capture? { [weak view] in
            guard let view,let renderer=view.renderer else {throw CanvasToolError.invalid("高斯预览尚未就绪")}
            return try renderer.photograph(size:view.drawableSize)
        }
        if context.coordinator.reset != resetToken {
            context.coordinator.reset = resetToken; view.renderer?.reset(); view.draw()
        }
    }
    final class GaussianView: MTKView {
        weak var renderer: CanvasGaussianRenderer?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
        override func mouseDragged(with event: NSEvent) {
            renderer?.yaw -= Float(event.deltaX) * 0.008
            if let renderer { renderer.pitch = min(1.5, max(-1.5, renderer.pitch + Float(event.deltaY) * 0.008)) }
            draw()
        }
        override func scrollWheel(with event: NSEvent) {
            if let renderer { renderer.distance = max(0.001, min(1_000_000, renderer.distance * exp(Float(event.scrollingDeltaY) * 0.015))) }
            draw()
        }
        override func keyDown(with event: NSEvent) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": renderer?.move(forward: 1, right: 0, up: 0)
            case "s": renderer?.move(forward: -1, right: 0, up: 0)
            case "a": renderer?.move(forward: 0, right: -1, up: 0)
            case "d": renderer?.move(forward: 0, right: 1, up: 0)
            case "q": renderer?.move(forward: 0, right: 0, up: -1)
            case "e": renderer?.move(forward: 0, right: 0, up: 1)
            case "r": renderer?.reset()
            default: super.keyDown(with: event)
            }
            draw()
        }
    }
}

struct CanvasWaveform: View {
    let values: [Float]
    var progress: Double = 0
    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty else { return }
            let width = size.width / CGFloat(values.count)
            for index in values.indices {
                let height = max(2, CGFloat(values[index]) * size.height)
                let rect = CGRect(x: CGFloat(index) * width, y: (size.height - height)/2, width: max(1,width * 0.55), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1),
                    with: .color(Double(index) / Double(values.count) < progress ? CanvasSkin.nodeAccent(.audio) : CanvasSkin.secondaryInk.opacity(0.6)))
            }
        }
    }
}
