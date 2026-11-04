import Foundation

/// How a road is drawn. Roads come from the OpenMapTiles `transportation` layer and are kept as a
/// separate ink layer that the fog compositor reveals only in explored areas. See shared/render-spec.md.
public enum RoadGroup: Int, CaseIterable, Sendable {
    case major, medium, minor, track, path

    /// Ink strength of the group, before `palette.roads.opacity`.
    public var opacity: Double {
        switch self {
        case .major: return 0.95
        case .medium: return 0.85
        case .minor: return 0.8
        case .track: return 0.7
        case .path: return 0.65
        }
    }

    /// Group and stroke width (in 256-px-tile pixels) for an OpenMapTiles `transportation` class,
    /// or nil to skip it at this zoom.
    public static func style(class cls: String?, zoom z: Int) -> (group: RoadGroup, width: Double)? {
        let d = Double(z)
        switch cls {
        case "motorway", "trunk": return z < 6 ? nil : (.major, min(0.9 + 0.3 * (d - 6), 4))
        case "primary": return z < 8 ? nil : (.major, min(0.8 + 0.3 * (d - 8), 3.5))
        case "secondary": return z < 9 ? nil : (.medium, min(0.7 + 0.25 * (d - 9), 3))
        case "tertiary": return z < 10 ? nil : (.medium, min(0.6 + 0.25 * (d - 10), 2.5))
        case "minor": return z < 12 ? nil : (.minor, min(0.9 + 0.25 * (d - 12), 2.2))
        case "service": return z < 14 ? nil : (.minor, min(0.7 + 0.2 * (d - 14), 1.6))
        case "track": return z < 12 ? nil : (.track, min(0.8 + 0.15 * (d - 12), 1.5))
        case "path": return z < 13 ? nil : (.path, min(0.8 + 0.15 * (d - 13), 1.5))
        default: return nil
        }
    }
}

/// Where roads are drawn.
public enum RoadVisibility: String, Codable, CaseIterable, Sendable {
    /// Only in explored areas, fading out with the fog edge (default).
    case explored
    /// Everywhere, also under the fog (the fog then tints them like the terrain).
    case everywhere
    case off
}

/// A rendered base tile: the terrain image plus the road layer that sits on top of it once explored.
public struct BaseTile: Sendable, Equatable {
    public var image: RGBAImage
    /// Road ink coverage per pixel (0…255, row-major, same size as `image`), or nil for no roads.
    public var roads: [UInt8]?

    public init(image: RGBAImage, roads: [UInt8]? = nil) {
        self.image = image
        self.roads = roads
    }
}

extension TileRenderer {
    /// Supersampling factor for road strokes, so 1 px roads come out smooth instead of jagged.
    static let roadSupersampling = 2

    /// Road coverage for a tile (0 = no road, 255 = full ink), or nil if the tile has no drawable roads.
    public func roadMask(tile: TileID, source: WaterSource) -> [UInt8]? {
        guard let layer = source.tile.layers["transportation"] else { return nil }
        let ss = Self.roadSupersampling
        let big = size * ss
        let s = Double(big)
        let ext = Double(layer.extent)
        var masks = RoadGroup.allCases.map { _ in Mask(width: big, height: big) }
        var drawn = Set<RoadGroup>()

        for f in layer.features where f.type == .lineString {
            guard f.properties["brunnel"]?.stringValue != "tunnel",
                  let style = RoadGroup.style(class: f.properties["class"]?.stringValue, zoom: tile.z) else { continue }
            let width = style.width * s / Double(WebMercator.tileSize)
            for path in f.paths where path.count >= 2 {
                let pts = path.map { Mask.P((Double($0.x) / ext - source.offsetX) / source.scale * s,
                                            (Double($0.y) / ext - source.offsetY) / source.scale * s) }
                // Skip lines entirely outside the tile (the buffer, or the rest of an overzoomed ancestor).
                let pad = width + 1
                guard Self.crosses(pts, size: s, pad: pad) else { continue }
                masks[style.group.rawValue].strokePolyline(pts, width: width)
                drawn.insert(style.group)
            }
        }
        guard !drawn.isEmpty else { return nil }

        var out = [UInt8](repeating: 0, count: size * size)
        let samples = Double(ss * ss)
        let global = palette.roads.opacity
        for group in RoadGroup.allCases where drawn.contains(group) {
            let m = masks[group.rawValue]
            let k = group.opacity * global * 255 / samples
            for y in 0..<size {
                for x in 0..<size {
                    var n = 0
                    for dy in 0..<ss {
                        let row = (y * ss + dy) * big + x * ss
                        for dx in 0..<ss where m.bits[row + dx] { n += 1 }
                    }
                    guard n > 0 else { continue }
                    let a = UInt8(min(255, (Double(n) * k).rounded()))
                    if a > out[y * size + x] { out[y * size + x] = a }
                }
            }
        }
        return out
    }

    /// True if some segment's bounding box overlaps the tile (a long segment can cross it with both ends outside).
    static func crosses(_ pts: [Mask.P], size s: Double, pad: Double) -> Bool {
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            if max(a.x, b.x) > -pad, min(a.x, b.x) < s + pad, max(a.y, b.y) > -pad, min(a.y, b.y) < s + pad { return true }
        }
        return false
    }
}
