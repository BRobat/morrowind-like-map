import Foundation

/// The set of explored places, stored as Web Mercator cells at a fixed zoom.
/// Format and semantics are specified in shared/fog-format.md so every platform can share files.
public struct FogGrid: Sendable, Equatable {
    /// Cell zoom. z18 cells are ~153 m at the equator, ~98 m at 50°N.
    public static let cellZoom = 18
    public static let defaultRevealRadiusMeters = 250.0
    /// Gaps longer than this between consecutive track points are not filled in (GPS dropouts, flights).
    public static let maxInterpolationGapMeters = 2_000.0

    public private(set) var cells: Set<UInt64>

    public init(cells: Set<UInt64> = []) {
        self.cells = cells
    }

    @inline(__always)
    public static func key(x: Int, y: Int) -> UInt64 { UInt64(UInt32(x)) << 32 | UInt64(UInt32(y)) }

    @inline(__always)
    public static func coords(_ key: UInt64) -> (x: Int, y: Int) { (Int(key >> 32), Int(key & 0xFFFF_FFFF)) }

    public var isEmpty: Bool { cells.isEmpty }
    public var count: Int { cells.count }

    public func isExplored(_ p: GeoPoint) -> Bool {
        let n = Double(1 << Self.cellZoom)
        let w = WebMercator.world(p)
        return cells.contains(Self.key(x: Int(w.x * n), y: Int(w.y * n)))
    }

    /// Marks every cell whose centre is within `radius` meters of `p`. Returns how many cells were new.
    @discardableResult
    public mutating func reveal(_ p: GeoPoint, radius: Double = defaultRevealRadiusMeters) -> Int {
        var bounds: CellRect?
        return reveal(p, radius: radius, bounds: &bounds)
    }

    /// Same as `reveal(_:radius:)`, also growing `bounds` to cover every newly explored cell.
    @discardableResult
    public mutating func reveal(_ p: GeoPoint, radius: Double = defaultRevealRadiusMeters, bounds: inout CellRect?) -> Int {
        let n = 1 << Self.cellZoom
        let w = WebMercator.world(p)
        let fx = w.x * Double(n), fy = w.y * Double(n)
        let cellMeters = WebMercator.earthCircumference * cos(p.latitude * .pi / 180) / Double(n)
        let rCells = radius / cellMeters
        let k = Int(ceil(rCells))
        var added = 0
        for dy in -k...k {
            for dx in -k...k {
                let cx = Int(floor(fx)) + dx, cy = Int(floor(fy)) + dy
                guard cy >= 0, cy < n else { continue }
                let ddx = Double(cx) + 0.5 - fx, ddy = Double(cy) + 0.5 - fy
                // Always include the cell the point is in, even for tiny radii.
                guard (dx == 0 && dy == 0) || ddx * ddx + ddy * ddy <= rCells * rCells else { continue }
                let x = ((cx % n) + n) % n
                if cells.insert(Self.key(x: x, y: cy)).inserted {
                    added += 1
                    bounds.include(x: x, y: cy)
                }
            }
        }
        return added
    }

    /// Reveals along a recorded track, filling short gaps between points so sparse
    /// recordings (e.g. 1 point / 10 s) still leave a continuous trail.
    @discardableResult
    public mutating func reveal(track: [GeoPoint], radius: Double = defaultRevealRadiusMeters) -> Int {
        var bounds: CellRect?
        return reveal(track: track, radius: radius, bounds: &bounds)
    }

    /// Same as `reveal(track:radius:)`, also growing `bounds` to cover every newly explored cell.
    /// Points closer than a quarter of the radius to the last revealed point are skipped: dense
    /// recordings (1 point/s) would otherwise stamp nearly the same disc over and over.
    @discardableResult
    public mutating func reveal(track: [GeoPoint], radius: Double = defaultRevealRadiusMeters, bounds: inout CellRect?) -> Int {
        var added = 0
        var previous: GeoPoint?
        let step = max(radius * 0.5, 10)
        let minSpacing = max(radius * 0.25, 5)
        for (i, p) in track.enumerated() {
            if let a = previous {
                let d = Self.distance(a, p)
                if d < minSpacing && i < track.count - 1 { continue }
                if d > step, d <= Self.maxInterpolationGapMeters {
                    let steps = Int(d / step)
                    for s in 1..<max(steps, 1) {
                        let t = Double(s) / Double(steps)
                        added += reveal(GeoPoint(latitude: a.latitude + (p.latitude - a.latitude) * t,
                                                 longitude: a.longitude + (p.longitude - a.longitude) * t),
                                        radius: radius, bounds: &bounds)
                    }
                }
            }
            added += reveal(p, radius: radius, bounds: &bounds)
            previous = p
        }
        return added
    }

    /// Some explored place (centre of an arbitrary cell), e.g. to centre the map on first launch.
    public var anyExploredPoint: GeoPoint? {
        guard let key = cells.first else { return nil }
        let (x, y) = Self.coords(key)
        let n = Double(1 << Self.cellZoom)
        return WebMercator.geo(worldX: (Double(x) + 0.5) / n, worldY: (Double(y) + 0.5) / n)
    }

    public mutating func merge(_ other: FogGrid) {
        cells.formUnion(other.cells)
    }

    /// Haversine distance in meters.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    // MARK: - Mask for rendering

    /// Pixel size of a cell and its stamped disc (radius + soft edge) on a tile at `zoom`.
    static func stampGeometry(zoom: Int, size: Int, edgeSoftness: Double) -> (cellPx: Double, radius: Double, soft: Double) {
        let cellPx = Double(size) * pow(2.0, Double(zoom - Self.cellZoom))
        return (cellPx, max(cellPx * 0.75, 1.0), min(edgeSoftness, max(1.5, cellPx * 1.5)))
    }

    /// How many cells beyond a tile's edge can still change its pixels.
    public static func marginCells(zoom: Int, size: Int, edgeSoftness: Double) -> Int {
        let g = stampGeometry(zoom: zoom, size: size, edgeSoftness: edgeSoftness)
        return Int(ceil((g.radius + g.soft) / g.cellPx)) + 1
    }

    /// Coverage for one tile: 1 = explored, 0 = fog, soft in between. `size`×`size`, row-major.
    public func coverage(for tile: TileID, size: Int = WebMercator.tileSize, edgeSoftness: Double) -> [Float] {
        var mask = [Float](repeating: 0, count: size * size)
        guard !cells.isEmpty else { return mask }

        let (cellPx, radius, soft) = Self.stampGeometry(zoom: tile.z, size: size, edgeSoftness: edgeSoftness)
        let reach = radius + soft

        // Cell index range that can touch this tile.
        let zoomDiff = tile.z - Self.cellZoom
        let tileX0 = Double(tile.x) * Double(size), tileY0 = Double(tile.y) * Double(size)
        let marginCells = Self.marginCells(zoom: tile.z, size: size, edgeSoftness: edgeSoftness)
        let cx0 = Int(floor(tileX0 / cellPx)) - marginCells
        let cy0 = Int(floor(tileY0 / cellPx)) - marginCells
        let span = (zoomDiff >= 0 ? 1 : 1 << -zoomDiff) + 2 * marginCells

        func stamp(_ cx: Int, _ cy: Int) {
            let px = (Double(cx) + 0.5) * cellPx - tileX0
            let py = (Double(cy) + 0.5) * cellPx - tileY0
            let x0 = max(0, Int(floor(px - reach))), x1 = min(size - 1, Int(ceil(px + reach)))
            let y0 = max(0, Int(floor(py - reach))), y1 = min(size - 1, Int(ceil(py + reach)))
            guard x0 <= x1, y0 <= y1 else { return }
            for y in y0...y1 {
                let dy = Double(y) + 0.5 - py
                for x in x0...x1 {
                    let dx = Double(x) + 0.5 - px
                    let a = Float(min(max((reach - (dx * dx + dy * dy).squareRoot()) / soft, 0), 1))
                    if a > mask[y * size + x] { mask[y * size + x] = a }
                }
            }
        }

        if span * span < cells.count {
            for cy in cy0..<(cy0 + span) {
                for cx in cx0..<(cx0 + span) where cells.contains(Self.key(x: cx, y: cy)) {
                    stamp(cx, cy)
                }
            }
        } else {
            for key in cells {
                let (cx, cy) = Self.coords(key)
                if cx >= cx0, cx < cx0 + span, cy >= cy0, cy < cy0 + span { stamp(cx, cy) }
            }
        }
        return mask
    }

    // MARK: - Serialization (shared/fog-format.md)

    static let magic: [UInt8] = Array("MWFG".utf8)
    static let formatVersion: UInt16 = 1

    public enum FormatError: Error { case badMagic, unsupportedVersion(UInt16), unsupportedZoom(UInt8), truncated }

    public func serialized() -> Data {
        var out = Data(capacity: 12 + cells.count * 8)
        out.append(contentsOf: Self.magic)
        appendLE(&out, Self.formatVersion)
        out.append(UInt8(Self.cellZoom))
        out.append(0)
        appendLE(&out, UInt32(cells.count))
        for key in cells.sorted() {
            let (x, y) = Self.coords(key)
            appendLE(&out, UInt32(x))
            appendLE(&out, UInt32(y))
        }
        return out
    }

    public init(serialized data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 12 else { throw FormatError.truncated }
        guard Array(b[0..<4]) == Self.magic else { throw FormatError.badMagic }
        let version = UInt16(b[4]) | UInt16(b[5]) << 8
        guard version == Self.formatVersion else { throw FormatError.unsupportedVersion(version) }
        guard Int(b[6]) == Self.cellZoom else { throw FormatError.unsupportedZoom(b[6]) }
        let count = Int(readLE32(b, 8))
        guard b.count >= 12 + count * 8 else { throw FormatError.truncated }
        var cells = Set<UInt64>(minimumCapacity: count)
        for i in 0..<count {
            let o = 12 + i * 8
            cells.insert(Self.key(x: Int(readLE32(b, o)), y: Int(readLE32(b, o + 4))))
        }
        self.init(cells: cells)
    }
}

private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ v: T) {
    withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) }
}

private func readLE32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

/// Inclusive bounding box of z18 fog cells, used to find the tiles a change touches.
public struct CellRect: Sendable, Equatable {
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int

    public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// Bounds of the given cell keys, or nil if there are none.
    public init?(covering keys: some Sequence<UInt64>) {
        var r: CellRect?
        for key in keys {
            let (x, y) = FogGrid.coords(key)
            r.include(x: x, y: y)
        }
        guard let r else { return nil }
        self = r
    }

    public func union(_ o: CellRect) -> CellRect {
        CellRect(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    /// Whether cells in this rect can change pixels of `tile`, given how far fog edges reach (`marginCells`).
    public func intersects(tile: TileID, marginCells: Int) -> Bool {
        let d = FogGrid.cellZoom - tile.z
        let tx0, ty0, tx1, ty1: Int
        if d >= 0 {
            tx0 = tile.x << d; ty0 = tile.y << d
            tx1 = ((tile.x + 1) << d) - 1; ty1 = ((tile.y + 1) << d) - 1
        } else {
            tx0 = tile.x >> -d; ty0 = tile.y >> -d
            tx1 = tx0; ty1 = ty0
        }
        return minX <= tx1 + marginCells && maxX >= tx0 - marginCells
            && minY <= ty1 + marginCells && maxY >= ty0 - marginCells
    }
}

extension Optional where Wrapped == CellRect {
    mutating func include(x: Int, y: Int) {
        let cell = CellRect(minX: x, minY: y, maxX: x, maxY: y)
        self = self?.union(cell) ?? cell
    }
}

/// How unexplored areas are drawn.
public enum FogStyle: String, Codable, CaseIterable, Sendable {
    /// Parchment over the map, like an uncharted region on the Morrowind map
    /// (`fog.hiddenOpacity` sets how much terrain shows through).
    case hidden
    /// The map is still visible but grayed out and darkened.
    case grayed
}

public enum FogCompositor {
    /// - Parameters:
    ///   - roads: road ink coverage (0…255) per pixel. By default roads are drawn only where the map is
    ///     explored and fade out with the fog edge; the fog is computed from the terrain without roads,
    ///     so they never show through `hidden` or `grayed` fog.
    ///   - roadsEverywhere: draw roads under the fog too (the fog then tints them like the terrain).
    public static func apply(to base: RGBAImage, coverage: [Float], style: FogStyle, palette: Palette = .standard,
                             tile: TileID, roads: [UInt8]? = nil, roadsEverywhere: Bool = false) -> RGBAImage {
        let p = ResolvedPalette(palette)
        var out = base
        let size = base.width
        let originX = UInt32(truncatingIfNeeded: tile.x &* size)
        let originY = UInt32(truncatingIfNeeded: tile.y &* size)
        for y in 0..<base.height {
            for x in 0..<base.width {
                let i = y * size + x
                let a = Double(coverage[i])
                // Fully explored and no road here: the base pixel is already right.
                if a >= 1, (roads?[i] ?? 0) == 0 { continue }
                var c = base[x, y]
                var explored = c
                if let roads, a > 0 || roadsEverywhere, roads[i] > 0 {
                    explored = RGB.lerp(c, p.roadColor, Double(roads[i]) / 255)
                    if roadsEverywhere { c = explored }
                }
                if a >= 1 {
                    out[x, y] = explored
                    continue
                }
                let fog: RGB
                switch style {
                case .hidden:
                    let n = hashNoise(originX &+ UInt32(x), originY &+ UInt32(y))
                    let parchment = p.fogHidden.scaled(1 + p.noiseAmplitude * (n - 0.5) * 2)
                    fog = RGB.lerp(c, parchment, p.fog.hiddenOpacity)
                case .grayed:
                    let (r, g, b) = c.components
                    let gray = (r + g + b) / 3
                    let d = p.fog.grayedDesaturation, k = 1 - p.fog.grayedDarken
                    fog = RGB(r: (r * (1 - d) + gray * d) * k, g: (g * (1 - d) + gray * d) * k, b: (b * (1 - d) + gray * d) * k)
                }
                out[x, y] = RGB.lerp(fog, explored, a)
            }
        }
        return out
    }
}
