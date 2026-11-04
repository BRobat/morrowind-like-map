import MorrowindMapCore
import SwiftUI

/// Draws waypoints the way a hand-inked fantasy map would: small dark-ink glyphs with a parchment
/// halo, and serif names. Cities get a keep, towns a house, villages a ring; points of interest get
/// their own small icons once you zoom in. See shared/waypoints-spec.md.
enum WaypointOverlay {
    static let ink = Color(red: 0.29, green: 0.22, blue: 0.15)
    static let paper = Color(red: 0.90, green: 0.84, blue: 0.69)
    static let waterInk = Color(red: 0.24, green: 0.36, blue: 0.43)
    /// Undiscovered places (only drawn with the "all places" setting) are faded.
    static let undiscoveredOpacity = 0.45

    #if os(watchOS)
    static let scale = 0.8
    #else
    static let scale = 1.0
    #endif

    // MARK: - Labels

    static func font(for w: Waypoint, size: Double) -> Font {
        switch w.kind {
        case .city: return .system(size: size, weight: .bold, design: .serif)
        case .town: return .system(size: size, weight: .semibold, design: .serif)
        case .village: return .system(size: size, weight: .medium, design: .serif)
        case .hamlet: return .system(size: size, weight: .regular, design: .serif)
        default: return .system(size: size, weight: .regular, design: .serif).italic()
        }
    }

    static func text(for w: Waypoint, size: Double, color: Color) -> Text {
        let s = w.kind == .city ? w.label.uppercased() : w.label
        var t = Text(s).font(font(for: w, size: size)).foregroundStyle(color)
        if w.kind == .city { t = t.tracking(size * 0.08) }
        return t
    }

    struct LabelTexts {
        var ink: GraphicsContext.ResolvedText
        var halo: GraphicsContext.ResolvedText
    }

    /// Lays out and draws `candidates`. Text is measured with the real fonts.
    static func draw(_ candidates: [WaypointLayout.Candidate], zoom: Double, in ctx: inout GraphicsContext) {
        guard !candidates.isEmpty else { return }
        var labels: [String: LabelTexts] = [:]
        let context = ctx
        let placed = WaypointLayout.layout(candidates, zoom: zoom, scale: scale) { w, size in
            let label = LabelTexts(ink: context.resolve(text(for: w, size: size, color: ink)),
                              halo: context.resolve(text(for: w, size: size, color: paper)))
            labels[w.id] = label
            let m = label.ink.measure(in: CGSize(width: 1_000, height: 200))
            return (Double(m.width), Double(m.height))
        }
        // Icons below labels, so a long name never hides a neighbour's icon outline.
        for p in placed {
            var c = ctx
            if !p.discovered { c.opacity = undiscoveredOpacity }
            drawGlyph(p, in: &c)
        }
        for p in placed {
            guard let rect = p.label, let label = labels[p.waypoint.id] else { continue }
            var c = ctx
            if !p.discovered { c.opacity = undiscoveredOpacity }
            let origin = CGPoint(x: rect.x, y: rect.y)
            let r = max(0.8, p.fontSize * 0.08)
            for (dx, dy) in [(-r, 0.0), (r, 0.0), (0.0, -r), (0.0, r), (-r, -r), (r, r), (-r, r), (r, -r)] {
                c.draw(label.halo, at: CGPoint(x: origin.x + dx, y: origin.y + dy), anchor: .topLeading)
            }
            c.draw(label.ink, at: origin, anchor: .topLeading)
        }
    }

    // MARK: - Glyphs

    private enum Paint { case ink, paper, water }

    private struct Part {
        var path: Path
        var fill: Paint?
        var stroke: Paint?
    }

    private static func color(_ p: Paint) -> Color {
        switch p {
        case .ink: return ink
        case .paper: return paper
        case .water: return waterInk
        }
    }

    static func drawGlyph(_ placed: WaypointLayout.Placed, in ctx: inout GraphicsContext) {
        let s = placed.iconSize
        let parts = glyph(placed.waypoint.kind, center: CGPoint(x: placed.x, y: placed.y), size: s,
                          capital: placed.waypoint.isCapital)
        let line = max(1, s * 0.1)
        // Parchment halo keeps icons readable on dark mountains.
        for part in parts { ctx.stroke(part.path, with: .color(paper), style: StrokeStyle(lineWidth: line + 2.5, lineJoin: .round)) }
        for part in parts {
            if let f = part.fill { ctx.fill(part.path, with: .color(color(f))) }
            if let st = part.stroke { ctx.stroke(part.path, with: .color(color(st)), style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round)) }
        }
    }

    /// Glyph shapes in a unit box (−0.5…0.5, y down) scaled to `size` around `center`.
    private static func glyph(_ kind: WaypointKind, center c: CGPoint, size s: Double, capital: Bool) -> [Part] {
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
        func poly(_ pts: [(Double, Double)], closed: Bool = true) -> Path {
            var p = Path()
            p.addLines(pts.map { pt($0.0, $0.1) })
            if closed { p.closeSubpath() }
            return p
        }
        func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: c.x + (x - r) * s, y: c.y + (y - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Path {
            Path(CGRect(x: c.x + x * s, y: c.y + y * s, width: w * s, height: h * s))
        }
        /// Upper half of a circle, as a closed arch shape.
        func arch(_ cx: Double, _ baseY: Double, _ r: Double) -> Path {
            let steps = 10
            var pts: [(Double, Double)] = []
            for i in 0...steps {
                let a = Double.pi * Double(i) / Double(steps) // 0 = right, pi = left
                pts.append((cx + r * cos(a), baseY - r * sin(a)))
            }
            return poly(pts)
        }
        let merlons: [(Double, Double)] = [
            (-0.45, 0.5), (-0.45, -0.5), (-0.27, -0.5), (-0.27, -0.32), (-0.09, -0.32), (-0.09, -0.5),
            (0.09, -0.5), (0.09, -0.32), (0.27, -0.32), (0.27, -0.5), (0.45, -0.5), (0.45, 0.5),
        ]

        switch kind {
        case .city:
            var parts = [Part(path: poly(merlons), fill: .ink), Part(path: arch(0, 0.5, 0.16), fill: .paper)]
            if capital { parts.append(Part(path: circle(0, -0.02, 0.09), fill: .paper)) }
            return parts
        case .town:
            return [Part(path: poly([(-0.42, 0.45), (-0.42, -0.05), (0, -0.45), (0.42, -0.05), (0.42, 0.45)]), fill: .ink)]
        case .village:
            return [Part(path: circle(0, 0, 0.42), fill: .paper, stroke: .ink), Part(path: circle(0, 0, 0.16), fill: .ink)]
        case .hamlet:
            return [Part(path: circle(0, 0, 0.5), fill: .ink)]
        case .peak:
            return [Part(path: poly([(0, -0.5), (0.55, 0.42), (-0.55, 0.42)]), fill: .ink)]
        case .castle:
            return [Part(path: poly(merlons), fill: .paper, stroke: .ink), Part(path: arch(0, 0.5, 0.15), fill: .ink)]
        case .ruins:
            return [Part(path: poly([(-0.42, 0.5), (-0.42, -0.3), (-0.22, -0.48), (-0.08, -0.12), (0.14, -0.36), (0.42, 0.02), (0.42, 0.5)]),
                         fill: .paper, stroke: .ink),
                    Part(path: poly([(-0.42, 0.18), (0.42, 0.18)], closed: false), stroke: .ink)]
        case .hut:
            return [Part(path: poly([(-0.5, 0.45), (0, -0.45), (0.5, 0.45)]), fill: .paper, stroke: .ink),
                    Part(path: rect(-0.12, 0.1, 0.24, 0.35), fill: .ink)]
        case .camp:
            return [Part(path: poly([(-0.5, 0.42), (0, -0.45), (0.5, 0.42)]), fill: .paper, stroke: .ink),
                    Part(path: poly([(0, -0.05), (-0.16, 0.42), (0.16, 0.42)]), fill: .ink)]
        case .lighthouse:
            return [Part(path: poly([(-0.16, -0.22), (0.16, -0.22), (0.26, 0.5), (-0.26, 0.5)]), fill: .ink),
                    Part(path: circle(0, -0.38, 0.12), fill: .paper, stroke: .ink),
                    Part(path: poly([(-0.5, -0.5), (-0.24, -0.42)], closed: false), stroke: .ink),
                    Part(path: poly([(0.5, -0.5), (0.24, -0.42)], closed: false), stroke: .ink)]
        case .viewpoint:
            return [Part(path: poly([(-0.5, 0), (-0.25, -0.25), (0, -0.32), (0.25, -0.25), (0.5, 0), (0.25, 0.25), (0, 0.32), (-0.25, 0.25)]),
                         fill: .paper, stroke: .ink),
                    Part(path: circle(0, 0, 0.16), fill: .ink)]
        case .cave:
            return [Part(path: arch(0, 0.4, 0.5), fill: .ink), Part(path: arch(0, 0.4, 0.24), fill: .paper)]
        case .shrine:
            return [Part(path: rect(-0.09, -0.5, 0.18, 1.0), fill: .ink), Part(path: rect(-0.34, -0.25, 0.68, 0.17), fill: .ink)]
        case .monument:
            return [Part(path: poly([(-0.13, 0.32), (-0.08, -0.32), (0, -0.5), (0.08, -0.32), (0.13, 0.32)]), fill: .ink),
                    Part(path: rect(-0.3, 0.32, 0.6, 0.16), fill: .ink)]
        case .spring:
            var drop = Path()
            drop.move(to: pt(0, -0.5))
            drop.addQuadCurve(to: pt(0, 0.45), control: pt(0.62, 0.2))
            drop.addQuadCurve(to: pt(0, -0.5), control: pt(-0.62, 0.2))
            drop.closeSubpath()
            return [Part(path: drop, fill: .water)]
        }
    }
}
