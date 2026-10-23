import SwiftUI
import WebKit
import ClipSlotsKit

/// The retained CSS uses fixed dots and SVG feTurbulence masks. Rendering those
/// filters in WebKit preserves their seeds and gradient semantics without
/// approximating them with native random particles. Only visible busy nodes own
/// a view; every renderer shares one nonpersistent process pool.
struct CanvasGenerationMotion: NSViewRepresentable {
    let worldSize: CGSize
    let renderScale: CGFloat
    let hasMedia: Bool
    let reducedMotion: Bool
    private static let pool = WKProcessPool()
    private static let css = CanvasGenerationAssets.loadingCSS

    final class MotionView: WKWebView {
        var key = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
    }

    func makeNSView(context: Context) -> MotionView {
        let configuration = WKWebViewConfiguration()
        configuration.processPool = Self.pool
        configuration.websiteDataStore = .nonPersistent()
        let view = MotionView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        if #available(macOS 13.3, *) { view.isInspectable = false }
        view.navigationDelegate = context.coordinator
        return view
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme
            decisionHandler(scheme == "about" ? .allow : .cancel)
        }
    }

    func updateNSView(_ view: MotionView, context: Context) {
        let width = max(1, worldSize.width), height = max(1, worldSize.height)
        let key = "\(width)|\(height)|\(renderScale)|\(hasMedia)|\(reducedMotion)"
        guard view.key != key else { return }
        view.key = key
        let reduced = reducedMotion ? """
        .node-loading-motion-enter{animation:node-loading-backdrop-enter 200ms cubic-bezier(.16,1,.3,1) forwards}
        .node-loading-grid-stars{mask-image:none!important;-webkit-mask-image:none!important;animation:none;opacity:.35}
        .node-loading-grid-sweep,.node-loading-sweep-glow,.node-loading-burst{display:none}
        """ : ""
        let shade = hasMedia ? "node-loading-shadow-layer" : "node-loading-shadow-layer-empty"
        let background = hasMedia ? "transparent" : "#070708"
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; script-src 'none'">
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
        *{box-sizing:border-box;pointer-events:none!important}
        \(Self.css)
        .root{position:absolute;left:0;top:0;width:\(width)px;height:\(height)px;
          transform:scale(\(renderScale));transform-origin:top left;border-radius:16px;
          clip-path:inset(0 round 16px);overflow:hidden;isolation:isolate;background:\(background)}
        .absolute{position:absolute}.shade{z-index:20}.motion{position:absolute;inset:0;z-index:30;overflow:hidden;border-radius:16px}
        \(reduced)
        </style></head><body><div class="root">
          <div class="absolute shade \(shade)"></div>
          <div class="motion node-loading-motion-enter">
            <div class="absolute node-loading-grid-stars"></div>
            <div class="absolute node-loading-grid-sweep"></div>
            <div class="absolute node-loading-sweep-glow"></div>
            <div class="absolute node-loading-burst"></div>
            <div class="absolute node-loading-dither"></div>
          </div>
        </div></body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ view: MotionView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
    }
}

struct CanvasTextGenerationSkeleton: View {
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @State private var pulse = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * scale) {
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 8 * scale) {
                    ForEach([CGFloat(1), 2/3, 1/3], id: \.self) { fraction in
                        RoundedRectangle(cornerRadius: 2 * scale)
                            .fill(Color(red: 229/255, green: 231/255, blue: 235/255))
                            .frame(width: proxy.size.width * fraction, height: 8 * scale)
                    }
                }
            }
        }
        .padding(8 * scale)
        .opacity(pulse && !reducedMotion ? 0.5 : 1)
        .onAppear {
            guard !reducedMotion else { return }
            withAnimation(.timingCurve(0.4, 0, 0.6, 1, duration: 1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .allowsHitTesting(false)
    }
}
