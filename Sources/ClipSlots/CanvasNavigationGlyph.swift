import SwiftUI

/// Small outlined canvas controls, drawn in points to retain crisp hover states.
struct CanvasNavigationGlyph: View {
    let id: String
    let highlighted: Bool
    var body: some View {
        Canvas { context, size in
            let offset = CGPoint(x: (size.width - 20) / 2, y: (size.height - 20) / 2)
            var path = Path()
            func line(_ points: [CGPoint]) {
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            switch id {
            case "map":
                line([CGPoint(x: 1, y: 4), CGPoint(x: 6, y: 2), CGPoint(x: 13, y: 5),
                      CGPoint(x: 19, y: 3), CGPoint(x: 19, y: 16), CGPoint(x: 13, y: 18),
                      CGPoint(x: 6, y: 15), CGPoint(x: 1, y: 17), CGPoint(x: 1, y: 4)])
                line([CGPoint(x: 6, y: 2), CGPoint(x: 6, y: 15)])
                line([CGPoint(x: 13, y: 5), CGPoint(x: 13, y: 18)])
            case "grid":
                for y in [CGFloat(3), 9, 15] {
                    for x in [CGFloat(3), 9, 15] {
                        path.addRoundedRect(in: CGRect(x: x, y: y, width: 3, height: 3), cornerSize: CGSize(width: 0.5, height: 0.5))
                    }
                }
            case "fit":
                line([CGPoint(x: 7, y: 2), CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 7)])
                line([CGPoint(x: 13, y: 2), CGPoint(x: 18, y: 2), CGPoint(x: 18, y: 7)])
                line([CGPoint(x: 2, y: 13), CGPoint(x: 2, y: 18), CGPoint(x: 7, y: 18)])
                line([CGPoint(x: 13, y: 18), CGPoint(x: 18, y: 18), CGPoint(x: 18, y: 13)])
            default:
                path.addRoundedRect(in: CGRect(x: 1, y: 2, width: 5, height: 5), cornerSize: CGSize(width: 1, height: 1))
                path.addRoundedRect(in: CGRect(x: 14, y: 13, width: 5, height: 5), cornerSize: CGSize(width: 1, height: 1))
                path.move(to: CGPoint(x: 6, y: 4.5))
                path.addCurve(to: CGPoint(x: 14, y: 15.5), control1: CGPoint(x: 15, y: 4.5),
                              control2: CGPoint(x: 5, y: 15.5))
            }
            path = path.offsetBy(dx: offset.x, dy: offset.y)
            context.stroke(path, with: .color(CanvasSkin.ink),
                           style: StrokeStyle(lineWidth: highlighted ? 1.8 : 1.5, lineCap: .round, lineJoin: .round))
        }.frame(width: 22, height: 22).accessibilityHidden(true)
    }
}
