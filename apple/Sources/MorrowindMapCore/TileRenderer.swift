import Foundation

/// Renders one Morrowind-style base tile (no fog) into an RGBA buffer.
/// The algorithm is described in shared/render-spec.md and mirrored by tools/preview.py.
public struct TileRenderer: Sendable {
    /// Bump when the rendering code changes, so tiles cached on disk are rendered again.
    public static let version = 1

    public let palette: Palette
    private let resolved: ResolvedPalette
    public let size: Int

    public init(palette: Palette = .standard, size: Int = WebMercator.tileSize) {
        self.palette = palette
        self.resolved = ResolvedPalette(palette)
        self.size = size
    }

    /// Vector water data for a tile, possibly from an ancestor tile when overzooming.
    public struct WaterSource: Sendable {
        public var tile: VectorTile
        public var offsetX: Double
        public var offsetY: Double
        public var scale: Double

        public init(tile: VectorTile, offsetX: Double = 0, offsetY: Double = 0, scale: Double = 1) {
            self.tile = tile
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.scale = scale
        }
    }

    /// - Parameters:
    ///   - elevation: elevation for exactly this tile, `size`×`size`.
    ///   - water: OpenMapTiles water data. When nil (offline / not yet loaded), anything at or
    ///     below sea level in the elevation data is treated as water.
    /// Identifies what a rendered tile looks like: renderer version, size and palette.
    /// Used as the folder name for the rendered-tile disk cache.
    public var cacheKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = (try? encoder.encode(palette)) ?? Data()
        // FNV-1a: stable across launches, unlike Swift's Hasher.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            hash ^= UInt64(b)
            hash &*= 0x0000_0100_0000_01b3
        }
        return "v\(Self.version)-\(size)-\(String(hash, radix: 16))"
    }

    public func render(tile: TileID, elevation: ElevationGrid, water: WaterSource?) -> RGBAImage {
        precondition(elevation.width == size && elevation.height == size)
        let isWater = water.map { waterMask(tile: tile, source: $0) } ?? seaLevelMask(elevation)
        let shore = shorelineMask(isWater)

        let hs = resolved.hillshade
        let boost = pow(2.0, Double(max(0, hs.lowZoomBoostBelow - tile.z)) * hs.lowZoomBoostPerLevel)
        // Tiles are rendered at `size` px but cover a 256 px slot's worth of ground.
        let pxMeters = WebMercator.metersPerPixel(zoom: tile.z, latitude: WebMercator.centerLatitude(of: tile))
            * Double(WebMercator.tileSize) / Double(size)
        let k = hs.exaggeration * boost / (2 * pxMeters)
        let az = hs.azimuthDegrees * .pi / 180, alt = hs.altitudeDegrees * .pi / 180
        let lx = sin(az) * cos(alt), ly = -cos(az) * cos(alt), lz = sin(alt)
        let noiseAmp = resolved.noiseAmplitude
        // Grain is anchored to world pixels so neighbouring tiles match.
        let originX = UInt32(truncatingIfNeeded: tile.x &* size)
        let originY = UInt32(truncatingIfNeeded: tile.y &* size)

        var out = RGBAImage(width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                let i = y * size + x
                let e = Double(elevation.meters[i])
                var color: RGB
                if shore[i] {
                    color = resolved.shoreline
                } else if isWater[i] {
                    color = resolved.waterColor(depth: -e)
                } else {
                    let dzdx = Double(elevation.at(x + 1, y) - elevation.at(x - 1, y)) * k
                    let dzdy = Double(elevation.at(x, y + 1) - elevation.at(x, y - 1)) * k
                    let shade = (-dzdx * lx - dzdy * ly + lz) / (dzdx * dzdx + dzdy * dzdy + 1).squareRoot()
                    let factor = min(max(1 + hs.strength * (max(0, min(1, shade)) - lz) / lz, hs.minFactor), hs.maxFactor)
                    color = resolved.landColor(elevation: e).scaled(factor)
                }
                let n = hashNoise(originX &+ UInt32(x), originY &+ UInt32(y))
                out[x, y] = color.scaled(1 + noiseAmp * (n - 0.5) * 2)
            }
        }
        return out
    }

    func seaLevelMask(_ elevation: ElevationGrid) -> [Bool] {
        elevation.meters.map { $0 <= 0 }
    }

    func waterMask(tile: TileID, source: WaterSource) -> [Bool] {
        var mask = Mask(width: size, height: size)
        let s = Double(size)

        if let layer = source.tile.layers["water"] {
            let ext = Double(layer.extent)
            for f in layer.features where f.type == .polygon {
                if f.properties["class"]?.stringValue == "swimming_pool" { continue }
                if f.properties["brunnel"]?.stringValue == "tunnel" { continue }
                let rings = f.paths.map { path in
                    path.map { Mask.P((Double($0.x) / ext - source.offsetX) / source.scale * s,
                                      (Double($0.y) / ext - source.offsetY) / source.scale * s) }
                }
                mask.fillPolygon(rings)
            }
        }

        if let layer = source.tile.layers["waterway"] {
            let ext = Double(layer.extent)
            for f in layer.features where f.type == .lineString {
                guard let width = Self.waterwayWidth(class: f.properties["class"]?.stringValue, zoom: tile.z),
                      f.properties["brunnel"]?.stringValue != "tunnel" else { continue }
                let scaledWidth = width * s / Double(WebMercator.tileSize)
                for path in f.paths {
                    let pts = path.map { Mask.P((Double($0.x) / ext - source.offsetX) / source.scale * s,
                                                (Double($0.y) / ext - source.offsetY) / source.scale * s) }
                    mask.strokePolyline(pts, width: scaledWidth)
                }
            }
        }
        return mask.bits
    }

    /// Stroke width in 256-px-tile pixels, or nil to skip the waterway at this zoom.
    static func waterwayWidth(class cls: String?, zoom: Int) -> Double? {
        switch cls {
        case "river": return zoom < 9 ? nil : min(1 + Double(zoom - 9) * 0.6, 6)
        case "canal": return zoom < 12 ? nil : min(1 + Double(zoom - 12) * 0.5, 4)
        case "stream": return zoom < 13 ? nil : min(0.8 + Double(zoom - 13) * 0.4, 2.5)
        default: return nil
        }
    }

    /// Land pixels within `shorelineWidthPx` of water get the dark ink outline.
    func shorelineMask(_ water: [Bool]) -> [Bool] {
        let w = resolved.shorelineWidth
        guard w > 0 else { return [Bool](repeating: false, count: water.count) }
        var shore = [Bool](repeating: false, count: water.count)
        for y in 0..<size {
            for x in 0..<size where !water[y * size + x] {
                search: for dy in -w...w {
                    for dx in -w...w where abs(dx) + abs(dy) <= w && (dx != 0 || dy != 0) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < size, ny < size else { continue }
                        if water[ny * size + nx] { shore[y * size + x] = true; break search }
                    }
                }
            }
        }
        return shore
    }
}
