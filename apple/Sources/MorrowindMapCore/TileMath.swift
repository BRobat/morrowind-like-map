import Foundation

/// A WGS84 coordinate. We use our own type so the core stays independent of CoreLocation.
public struct GeoPoint: Hashable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A slippy-map tile address (Web Mercator, XYZ scheme, origin top-left).
public struct TileID: Hashable, Codable, Sendable, CustomStringConvertible {
    public var z: Int
    public var x: Int
    public var y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    public var description: String { "\(z)/\(x)/\(y)" }

    /// The ancestor tile at `zoom` (<= z), plus where this tile sits inside it:
    /// `offset` is in fractions of the ancestor (0..<1) and `scale` is this tile's size in fractions.
    public func ancestor(atZoom zoom: Int) -> (tile: TileID, offsetX: Double, offsetY: Double, scale: Double) {
        precondition(zoom <= z)
        let d = z - zoom
        let n = 1 << d
        let parent = TileID(z: zoom, x: x >> d, y: y >> d)
        let scale = 1.0 / Double(n)
        return (parent, Double(x - parent.x * n) * scale, Double(y - parent.y * n) * scale, scale)
    }

    /// Wraps x around the antimeridian; returns nil if y is outside the world.
    public var normalized: TileID? {
        let n = 1 << z
        guard y >= 0, y < n else { return nil }
        return TileID(z: z, x: ((x % n) + n) % n, y: y)
    }
}

public enum WebMercator {
    public static let tileSize = 256
    public static let maxLatitude = 85.05112878
    public static let earthCircumference = 40_075_016.686

    /// Position in "world units": 0...1 on both axes, origin top-left.
    public static func world(_ p: GeoPoint) -> (x: Double, y: Double) {
        let lat = min(max(p.latitude, -maxLatitude), maxLatitude) * .pi / 180
        let x = (p.longitude + 180) / 360
        let y = (1 - asinh(tan(lat)) / .pi) / 2
        return (x, y)
    }

    public static func geo(worldX x: Double, worldY y: Double) -> GeoPoint {
        let lon = x * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * y))) * 180 / .pi
        return GeoPoint(latitude: lat, longitude: lon)
    }

    /// Ground size of one pixel of a 256 px tile at `zoom` and `latitude`.
    public static func metersPerPixel(zoom: Int, latitude: Double) -> Double {
        earthCircumference * cos(latitude * .pi / 180) / Double((1 << zoom) * tileSize)
    }

    /// Latitude at the vertical centre of a tile.
    public static func centerLatitude(of tile: TileID) -> Double {
        geo(worldX: 0, worldY: (Double(tile.y) + 0.5) / Double(1 << tile.z)).latitude
    }
}
