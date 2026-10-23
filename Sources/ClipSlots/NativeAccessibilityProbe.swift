#if DEBUG
import AppKit

/// An in-process fixture can request its own virtual accessibility children.
/// This does not grant another process Accessibility permission.
@MainActor
enum NativeAccessibilityProbe {
    static func enable() {
        NSApp.accessibilitySetValue(true,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    static func elements(_ root: AnyObject) -> [AnyObject] {
        var visited = Set<ObjectIdentifier>()
        func visit(_ node: AnyObject, depth: Int) -> [AnyObject] {
            guard depth < 40, visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children = node.accessibilityChildren?() ?? []
            let native = (node as? NSView)?.subviews ?? []
            return [node] + (children + native).flatMap { visit($0 as AnyObject, depth: depth + 1) }
        }
        return visit(root, depth: 0)
    }
}
#endif
