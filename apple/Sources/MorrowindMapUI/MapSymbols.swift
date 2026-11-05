import SwiftUI

/// Ink and markers shared by the full map and the minimap.
public enum MapSymbols {
    public static let ink = Color(red: 0.25, green: 0.18, blue: 0.1)
    public static let playerRed = Color(red: 0.55, green: 0.12, blue: 0.08)
    public static let parchment = Color(red: 0.86, green: 0.79, blue: 0.64)
    public static let parchmentDark = Color(red: 0.62, green: 0.51, blue: 0.36)
    public static let markerGold = Color(red: 0.86, green: 0.62, blue: 0.16)

    /// A small arrowhead in dark red ink, as used for the player on the in-game map.
    /// `degrees` turns it clockwise from pointing up.
    public static func drawPlayer(at p: (x: Double, y: Double), degrees: Double = 0, in ctx: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -8))
        path.addLine(to: CGPoint(x: 6, y: 6))
        path.addLine(to: CGPoint(x: 0, y: 2))
        path.addLine(to: CGPoint(x: -6, y: 6))
        path.closeSubpath()
        let placed = path.applying(CGAffineTransform(rotationAngle: degrees * .pi / 180).concatenating(CGAffineTransform(translationX: p.x, y: p.y)))
        ctx.fill(placed, with: .color(playerRed))
        ctx.stroke(placed, with: .color(ink), lineWidth: 1)
    }

    /// The target: a gold marker whose tip sits on the place, like a quest marker.
    public static func drawTarget(at p: (x: Double, y: Double), in ctx: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: p.x, y: p.y))
        path.addLine(to: CGPoint(x: p.x + 6, y: p.y - 9))
        path.addLine(to: CGPoint(x: p.x, y: p.y - 16))
        path.addLine(to: CGPoint(x: p.x - 6, y: p.y - 9))
        path.closeSubpath()
        ctx.fill(path, with: .color(markerGold))
        ctx.stroke(path, with: .color(ink), lineWidth: 1.2)
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(ink))
    }

    /// Point on a circle around `c` at `degrees` clockwise from up.
    static func onCircle(_ c: CGPoint, radius: Double, degrees: Double) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: c.x + radius * sin(a), y: c.y - radius * cos(a))
    }
}
