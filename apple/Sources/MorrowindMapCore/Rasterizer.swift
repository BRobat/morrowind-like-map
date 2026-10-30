import Foundation

/// A binary coverage mask with simple scanline rasterization, used for water areas.
public struct Mask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var bits: [Bool]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bits = [Bool](repeating: false, count: width * height)
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> Bool {
        get { bits[y * width + x] }
        set { bits[y * width + x] = newValue }
    }

    public struct P: Sendable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// Fills the union of `rings` using the nonzero winding rule, sampling at pixel centres.
    /// Rings may be open; they are closed implicitly.
    public mutating func fillPolygon(_ rings: [[P]]) {
        var minY = Double.infinity, maxY = -Double.infinity
        for ring in rings { for p in ring { minY = min(minY, p.y); maxY = max(maxY, p.y) } }
        guard minY.isFinite else { return }
        let y0 = max(0, Int(floor(minY))), y1 = min(height - 1, Int(ceil(maxY)))
        guard y0 <= y1 else { return }

        var crossings: [(x: Double, dir: Int)] = []
        for py in y0...y1 {
            let sy = Double(py) + 0.5
            crossings.removeAll(keepingCapacity: true)
            for ring in rings where ring.count >= 2 {
                var a = ring[ring.count - 1]
                for b in ring {
                    if (a.y <= sy && b.y > sy) || (b.y <= sy && a.y > sy) {
                        let t = (sy - a.y) / (b.y - a.y)
                        crossings.append((a.x + t * (b.x - a.x), b.y > a.y ? 1 : -1))
                    }
                    a = b
                }
            }
            guard crossings.count >= 2 else { continue }
            crossings.sort { $0.x < $1.x }
            var winding = 0
            for i in 0..<crossings.count - 1 {
                winding += crossings[i].dir
                guard winding != 0 else { continue }
                // Pixels whose centre lies in [x_i, x_{i+1}).
                let xs = max(0, Int(ceil(crossings[i].x - 0.5)))
                let xe = min(width - 1, Int(ceil(crossings[i + 1].x - 0.5)) - 1)
                if xs <= xe { for px in xs...xe { bits[py * width + px] = true } }
            }
        }
    }

    /// Strokes a polyline of the given width (in pixels) with round joins.
    public mutating func strokePolyline(_ points: [P], width w: Double) {
        let r = max(w / 2, 0.5)
        for i in 0..<points.count {
            stampDisc(points[i], radius: r)
            guard i + 1 < points.count else { break }
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 0 else { continue }
            let nx = -dy / len * r, ny = dx / len * r
            fillPolygon([[P(a.x + nx, a.y + ny), P(b.x + nx, b.y + ny), P(b.x - nx, b.y - ny), P(a.x - nx, a.y - ny)]])
        }
    }

    public mutating func stampDisc(_ c: P, radius r: Double) {
        let x0 = max(0, Int(floor(c.x - r))), x1 = min(width - 1, Int(ceil(c.x + r)))
        let y0 = max(0, Int(floor(c.y - r))), y1 = min(height - 1, Int(ceil(c.y + r)))
        guard x0 <= x1, y0 <= y1 else { return }
        let r2 = r * r
        for y in y0...y1 {
            let dy = Double(y) + 0.5 - c.y
            for x in x0...x1 {
                let dx = Double(x) + 0.5 - c.x
                if dx * dx + dy * dy <= r2 { bits[y * width + x] = true }
            }
        }
    }
}
