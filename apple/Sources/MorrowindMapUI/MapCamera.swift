import Foundation
import MorrowindMapCore

/// Where the map is looking. `center` is in world units (0...1, Web Mercator), `zoom` is continuous.
public struct MapCamera: Equatable, Sendable {
    public static let minZoom = 2.0
    public static let maxZoom = 17.0

    public var centerX: Double
    public var centerY: Double
    public var zoom: Double {
        didSet { zoom = min(max(zoom, Self.minZoom), Self.maxZoom) }
    }

    public init(center: GeoPoint, zoom: Double) {
        let w = WebMercator.world(center)
        self.centerX = w.x
        self.centerY = w.y
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    public var center: GeoPoint { WebMercator.geo(worldX: centerX, worldY: centerY) }

    /// Points per world unit.
    public var worldSize: Double { Double(WebMercator.tileSize) * pow(2, zoom) }

    /// Integer zoom of the tiles we draw; tiles are scaled between 1x and 2x of their size
    /// (slightly favouring sharper tiles).
    public var tileZoom: Int { Int(min(max(floor(zoom + 0.25), Self.minZoom), Self.maxZoom)) }

    public mutating func pan(byPoints dx: Double, _ dy: Double) {
        centerX -= dx / worldSize
        centerY = min(max(centerY - dy / worldSize, 0), 1)
        centerX -= floor(centerX) // wrap around the antimeridian
    }

    /// Zooms while keeping the world point under `anchor` (offset from view centre, in points) fixed.
    public mutating func zoom(to newZoom: Double, anchor: (x: Double, y: Double) = (0, 0)) {
        let before = worldSize
        zoom = newZoom
        let after = worldSize
        centerX += anchor.x / before - anchor.x / after
        centerY = min(max(centerY + anchor.y / before - anchor.y / after, 0), 1)
    }

    public func screenPoint(for p: GeoPoint, viewSize: (w: Double, h: Double)) -> (x: Double, y: Double) {
        let w = WebMercator.world(p)
        var dx = w.x - centerX
        if dx > 0.5 { dx -= 1 } else if dx < -0.5 { dx += 1 }
        return (viewSize.w / 2 + dx * worldSize, viewSize.h / 2 + (w.y - centerY) * worldSize)
    }

    /// Tiles covering the view at `tileZoom`, with their top-left corner and side length in points.
    /// X is not wrapped here so tiles line up across the antimeridian; normalise before fetching.
    public func visibleTiles(viewSize: (w: Double, h: Double)) -> [(tile: TileID, x: Double, y: Double, side: Double)] {
        let z = tileZoom
        let n = 1 << z
        let side = worldSize / Double(n)
        let originX = viewSize.w / 2 - centerX * worldSize
        let originY = viewSize.h / 2 - centerY * worldSize
        let x0 = Int(floor(-originX / side)), x1 = Int(floor((viewSize.w - originX) / side))
        let y0 = max(0, Int(floor(-originY / side))), y1 = min(n - 1, Int(floor((viewSize.h - originY) / side)))
        guard x0 <= x1, y0 <= y1 else { return [] }
        var out: [(tile: TileID, x: Double, y: Double, side: Double)] = []
        for ty in y0...y1 {
            for tx in x0...x1 {
                out.append((tile: TileID(z: z, x: tx, y: ty), x: originX + Double(tx) * side, y: originY + Double(ty) * side, side: side))
            }
        }
        // Load from the centre outwards.
        let cx = viewSize.w / 2, cy = viewSize.h / 2
        return out.sorted {
            hypot($0.x + side / 2 - cx, $0.y + side / 2 - cy) < hypot($1.x + side / 2 - cx, $1.y + side / 2 - cy)
        }
    }
}
