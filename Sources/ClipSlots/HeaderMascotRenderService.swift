import AppKit
import ClipSlotsKit

@MainActor
protocol HeaderMascotRenderOwner: AnyObject {
    func receiveMascotFrame(_ request:MascotFrameRequest,_ frame:MascotRenderedFrame)
}

/// Weak window keys and a weak presenter prevent model/NSView retention. The
/// scheduler survives titlebar remounts, including a still-running GPU request.
@MainActor
final class HeaderMascotRenderService {
    private static let windows=NSMapTable<NSWindow,HeaderMascotRenderService>(
        keyOptions:.weakMemory,valueOptions:.strongMemory)
    static func forWindow(_ window:NSWindow) -> HeaderMascotRenderService {
        if let service=windows.object(forKey:window) { return service }
        let service=HeaderMascotRenderService()
        windows.setObject(service,forKey:window)
        service.closeObserver=NotificationCenter.default.addObserver(
            forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak window,weak service] _ in
                MainActor.assumeIsolated {
                    guard let service else { return }
                    service.owner=nil;service.frames.invalidate();service.idleExpired=true
                    service.releaseIfIdle()
                    if let window { windows.removeObject(forKey:window) }
                }
            }
        return service
    }
    private weak var owner:(any HeaderMascotRenderOwner)?
    private var idleRelease:Timer?
    private var idleExpired=false
    private var storage:HeaderMascotRenderer?
    private var closeObserver:NSObjectProtocol?
    private var pressureObserver:UUID?
    var renderer:HeaderMascotRenderer {
        if let storage { return storage }
        let value=HeaderMascotRenderer();storage=value;return value
    }
    lazy var frames=MascotFrameScheduler(render: { [weak self] request,completion in
        guard let self else { return }
        self.renderer.render(request,completion:completion)
    },present: { [weak self] request,frame in
        self?.owner?.receiveMascotFrame(request,frame)
    })
    init() {
        frames.onIdle={ [weak self] in self?.releaseIfIdle() }
        pressureObserver=ResourceBudget.shared.observe { [weak self] in
            Task { @MainActor in
                guard let self,self.owner==nil,
                      ResourceBudget.shared.schedulingSnapshot.pressure == .critical else { return }
                self.idleExpired=true;self.releaseIfIdle()
            }
        }
    }
    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        if let pressureObserver { ResourceBudget.shared.removeObserver(pressureObserver) }
        idleRelease?.invalidate()
    }
    func attach(_ view:any HeaderMascotRenderOwner) {
        if owner === view { return }
        idleRelease?.invalidate();idleRelease=nil;idleExpired=false
        frames.invalidate();owner=view
    }
    func detach(_ view:any HeaderMascotRenderOwner) {
        guard owner === view else { return }
        owner=nil;frames.invalidate()
        idleRelease?.invalidate()
        let timer=Timer(timeInterval:10,repeats:false) { [weak self] _ in
            Task { @MainActor in
                self?.idleExpired=true;self?.releaseIfIdle()
            }
        }
        idleRelease=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func releaseIfIdle() {
        guard idleExpired,owner == nil,!frames.inFlight else { return }
        storage=nil;idleRelease?.invalidate();idleRelease=nil
    }
}
