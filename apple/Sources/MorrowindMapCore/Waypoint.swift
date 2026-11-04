import Foundation

/// What a waypoint is. Settlements come from the OpenMapTiles `place` layer, peaks from
/// `mountain_peak`, and everything else from `poi`. See shared/waypoints-spec.md.
public enum WaypointKind: String, Codable, CaseIterable, Sendable {
    // Settlements
    case city, town, village, hamlet
    // Landmarks and points of interest
    case peak, castle, ruins, hut, camp, lighthouse, viewpoint, cave, shrine, monument, spring

    /// Lowest camera zoom at which this kind is drawn at all.
    public var minZoom: Double {
        switch self {
        case .city: return 4
        case .town: return 8
        case .village: return 11
        case .hamlet: return 13
        case .peak: return 11
        case .castle, .ruins, .lighthouse: return 13
        case .hut, .camp, .viewpoint, .cave: return 14
        case .shrine, .monument, .spring: return 15
        }
    }

    /// Lowest camera zoom at which the name is written next to the icon.
    public var minLabelZoom: Double {
        switch self {
        case .city, .town, .village, .hamlet: return minZoom
        case .peak: return 12
        case .castle, .ruins, .lighthouse: return 14
        default: return 15
        }
    }

    /// Cities and towns are known without visiting them, like the major cities on the
    /// Oblivion map. Everything else appears only once you have been near it.
    public var isLandmark: Bool { self == .city || self == .town }

    public var isSettlement: Bool {
        switch self {
        case .city, .town, .village, .hamlet: return true
        default: return false
        }
    }

    /// How close an explored cell must be for the waypoint to count as discovered.
    /// Settlement points sit in the village centre, so a run along its edge should still count.
    public var discoveryRadiusMeters: Double {
        switch self {
        case .city, .town: return 1_000
        case .village: return 500
        case .hamlet: return 300
        case .peak: return 250
        default: return 150
        }
    }

    /// Lower wins when labels collide.
    var priority: Int {
        switch self {
        case .city: return 0
        case .town: return 1
        case .village: return 2
        case .peak: return 3
        case .hamlet: return 4
        case .castle, .ruins, .lighthouse: return 5
        case .hut, .camp, .viewpoint, .cave: return 6
        case .shrine, .monument, .spring: return 7
        }
    }

    /// Nominal label size in points (the UI may scale it, e.g. on the watch).
    public var fontSize: Double {
        switch self {
        case .city: return 15
        case .town: return 13
        case .village: return 11.5
        case .hamlet: return 10
        default: return 10
        }
    }

    /// Nominal icon size in points.
    public var iconSize: Double {
        switch self {
        case .city: return 16
        case .town: return 12
        case .village: return 8
        case .hamlet: return 5
        case .peak: return 9
        default: return 11
        }
    }

    /// Maps OpenMapTiles `place` classes.
    public init?(placeClass: String) {
        switch placeClass {
        case "city": self = .city
        case "town": self = .town
        case "village": self = .village
        case "hamlet", "isolated_dwelling": self = .hamlet
        default: return nil
        }
    }

    /// Maps OpenMapTiles `poi` features. The subclass (the raw OSM tag value) is more specific,
    /// so it is checked first.
    public init?(poiClass: String?, subclass: String?) {
        switch subclass {
        case "castle", "fort", "fortress", "manor", "palace", "city_gate": self = .castle; return
        case "ruins", "archaeological_site", "battlefield": self = .ruins; return
        case "alpine_hut", "wilderness_hut", "shelter", "basic_hut": self = .hut; return
        case "camp_site", "caravan_site": self = .camp; return
        case "lighthouse": self = .lighthouse; return
        case "viewpoint": self = .viewpoint; return
        case "cave_entrance": self = .cave; return
        case "spring", "drinking_water", "water_point": self = .spring; return
        case "monument", "memorial", "wayside_cross", "wayside_shrine", "obelisk": self = .monument; return
        case "chapel", "monastery": self = .shrine; return
        default: break
        }
        switch poiClass {
        case "castle": self = .castle
        case "campsite": self = .camp
        case "place_of_worship": self = .shrine
        case "monument": self = .monument
        default: return nil
        }
    }
}

/// A named place on the map: a settlement or a point of interest.
public struct Waypoint: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: WaypointKind
    public var location: GeoPoint
    /// Importance within its kind from OpenMapTiles (lower is more important).
    public var rank: Int
    /// Summit height for peaks, in meters.
    public var elevation: Int?
    public var isCapital: Bool

    public init(id: String, name: String, kind: WaypointKind, location: GeoPoint, rank: Int = 10,
                elevation: Int? = nil, isCapital: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.rank = rank
        self.elevation = elevation
        self.isCapital = isCapital
    }

    /// The text written on the map.
    public var label: String {
        if kind == .peak, let elevation { return "\(name) \(elevation) m" }
        return name
    }

    /// Lower draws first and wins label collisions.
    var sortKey: (Int, Int, Int, String) { (kind.priority, isCapital ? 0 : 1, rank, id) }

    /// Whether the waypoint should be drawn at all, before collisions.
    public func isVisible(atZoom zoom: Double) -> Bool {
        // Big cities show a little earlier, small towns a little later.
        var minZoom = kind.minZoom
        if kind == .city { minZoom += isCapital ? -1 : Double(min(max(rank - 4, 0), 4)) * 0.5 }
        if kind == .town { minZoom += Double(min(max(rank - 6, 0), 6)) * 0.25 }
        return zoom >= minZoom
    }

    public func showsLabel(atZoom zoom: Double) -> Bool { zoom >= kind.minLabelZoom }
}

/// Which waypoints the map shows.
public enum WaypointVisibility: String, Codable, CaseIterable, Sendable {
    /// No places at all: the bare Morrowind-style map.
    case off
    /// Cities and towns always, everything else once discovered.
    case discovered
    /// Everything; undiscovered places are drawn faded.
    case all
}

extension WaypointVisibility {
    /// Whether to draw `waypoint`, given whether it has been discovered.
    public func shows(_ waypoint: Waypoint, discovered: Bool) -> Bool {
        switch self {
        case .off: return false
        case .discovered: return discovered || waypoint.kind.isLandmark
        case .all: return true
        }
    }
}

extension FogGrid {
    /// True if any explored cell lies within `radius` meters of `p` (checked on the cell grid).
    public func isExplored(near p: GeoPoint, radius: Double) -> Bool {
        guard !cells.isEmpty else { return false }
        let n = 1 << Self.cellZoom
        let w = WebMercator.world(p)
        let fx = w.x * Double(n), fy = w.y * Double(n)
        let cellMeters = WebMercator.earthCircumference * cos(p.latitude * .pi / 180) / Double(n)
        let r = radius / cellMeters
        let k = Int(ceil(r))
        let cx = Int(floor(fx)), cy = Int(floor(fy))
        for dy in -k...k {
            let y = cy + dy
            guard y >= 0, y < n else { continue }
            for dx in -k...k {
                let ddx = Double(dx), ddy = Double(dy)
                // The point's own cell always counts; others by centre distance.
                guard (dx == 0 && dy == 0) || ddx * ddx + ddy * ddy <= r * r else { continue }
                if cells.contains(Self.key(x: ((cx + dx) % n + n) % n, y: y)) { return true }
            }
        }
        return false
    }

    public func discovered(_ waypoint: Waypoint) -> Bool {
        isExplored(near: waypoint.location, radius: waypoint.kind.discoveryRadiusMeters)
    }
}

/// Reads waypoints from an OpenMapTiles vector tile.
public enum WaypointExtractor {
    public static func waypoints(in vt: VectorTile, tile: TileID) -> [Waypoint] {
        var out: [Waypoint] = []
        if let layer = vt.layers["place"] {
            for f in layer.features {
                guard let cls = f.properties["class"]?.stringValue, let kind = WaypointKind(placeClass: cls) else { continue }
                if let w = make(f, kind: kind, layer: layer, tile: tile) { out.append(w) }
            }
        }
        if let layer = vt.layers["mountain_peak"] {
            for f in layer.features {
                let cls = f.properties["class"]?.stringValue
                guard cls == nil || cls == "peak" || cls == "volcano" else { continue }
                if var w = make(f, kind: .peak, layer: layer, tile: tile) {
                    w.elevation = f.properties["ele"]?.intValue
                    out.append(w)
                }
            }
        }
        if let layer = vt.layers["poi"] {
            for f in layer.features {
                guard let kind = WaypointKind(poiClass: f.properties["class"]?.stringValue,
                                              subclass: f.properties["subclass"]?.stringValue) else { continue }
                if let w = make(f, kind: kind, layer: layer, tile: tile) { out.append(w) }
            }
        }
        return out
    }

    private static func make(_ f: VectorTile.Feature, kind: WaypointKind, layer: VectorTile.Layer, tile: TileID) -> Waypoint? {
        guard f.type == .point, let p = f.paths.first?.first else { return nil }
        guard let name = displayName(of: f) else { return nil }
        // Points in the tile's buffer belong to a neighbour; skipping them avoids duplicates.
        let ext = Double(layer.extent)
        let px = Double(p.x), py = Double(p.y)
        guard px >= 0, py >= 0, px < ext, py < ext else { return nil }
        let n = Double(1 << tile.z)
        let location = WebMercator.geo(worldX: (Double(tile.x) + px / ext) / n, worldY: (Double(tile.y) + py / ext) / n)
        let id: String
        if let fid = f.id {
            id = "\(layer.name):\(fid)"
        } else {
            id = "\(kind.rawValue):\(name):\(Int((location.latitude * 100).rounded())):\(Int((location.longitude * 100).rounded()))"
        }
        let capital = f.properties["capital"]?.intValue
        return Waypoint(id: id, name: name, kind: kind, location: location,
                        rank: f.properties["rank"]?.intValue ?? 10,
                        isCapital: capital == 2)
    }

    /// Local name, falling back to the Latin transliteration.
    static func displayName(of f: VectorTile.Feature) -> String? {
        for key in ["name", "name:latin", "name_en", "name_int"] {
            if let s = f.properties[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
        }
        return nil
    }
}

extension VectorTile.Value {
    public var intValue: Int? {
        switch self {
        case .int(let v): return Int(truncatingIfNeeded: v)
        case .double(let v): return v.isFinite ? Int(v.rounded()) : nil
        case .string(let s): return Int(s)
        case .bool: return nil
        }
    }
}

/// Greedy, priority-ordered placement of waypoint icons and labels without overlaps.
/// Pure geometry so it is shared by every platform and unit-testable.
public enum WaypointLayout {
    public struct Rect: Equatable, Sendable {
        public var x, y, w, h: Double
        public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }

        func intersects(_ o: Rect) -> Bool {
            w > 0 && h > 0 && o.w > 0 && o.h > 0 && x < o.x + o.w && o.x < x + w && y < o.y + o.h && o.y < y + h
        }
        func expanded(by d: Double) -> Rect { Rect(x: x - d, y: y - d, w: w + 2 * d, h: h + 2 * d) }
    }

    public struct Candidate: Sendable {
        public var waypoint: Waypoint
        public var x: Double
        public var y: Double
        public var discovered: Bool

        public init(waypoint: Waypoint, x: Double, y: Double, discovered: Bool) {
            self.waypoint = waypoint
            self.x = x
            self.y = y
            self.discovered = discovered
        }
    }

    public enum Anchor: Sendable { case right, left, above, below }

    public struct Placed: Sendable {
        public var waypoint: Waypoint
        public var x: Double
        public var y: Double
        public var iconSize: Double
        public var fontSize: Double
        /// Where the label goes, or nil for an icon on its own.
        public var label: Rect?
        public var anchor: Anchor
        public var discovered: Bool
    }

    /// - Parameters:
    ///   - measure: size in points of a waypoint's label at a font size.
    ///   - scale: multiplies icon and font sizes (e.g. smaller on the watch).
    ///   - limit: most icons drawn; the rest would be clutter anyway.
    public static func layout(_ candidates: [Candidate], zoom: Double, scale: Double = 1, limit: Int = 200,
                              measure: (Waypoint, Double) -> (w: Double, h: Double) = WaypointLayout.estimate) -> [Placed] {
        let sorted = candidates.sorted { $0.waypoint.sortKey < $1.waypoint.sortKey }

        // Pass 1: icons, most important first. Icons are the waypoints, so they claim space before any text.
        var accepted: [(c: Candidate, icon: Rect)] = []
        for c in sorted {
            guard accepted.count < limit else { break }
            let w = c.waypoint
            let size = w.kind.iconSize * scale * (w.isCapital ? 1.15 : 1)
            let icon = Rect(x: c.x - size / 2, y: c.y - size / 2, w: size, h: size)
            guard !accepted.contains(where: { $0.icon.intersects(icon.expanded(by: 1)) }) else { continue }
            accepted.append((c, icon))
        }

        // Pass 2: labels around their icon, avoiding every icon and every label placed so far.
        var icons = accepted.map { $0.icon }
        var labels: [Rect] = []
        var out: [Placed] = []
        let gap = 3.0 * scale
        for (index, entry) in accepted.enumerated() {
            let (c, icon) = entry
            let w = c.waypoint
            var fontSize = w.kind.fontSize * scale
            if w.kind == .city, w.isCapital { fontSize *= 1.15 }
            var label: Rect?
            var anchor = Anchor.right
            if w.showsLabel(atZoom: zoom) {
                let size = measure(w, fontSize)
                let half = icon.w / 2
                let options: [(Anchor, Rect)] = [
                    (.right, Rect(x: c.x + half + gap, y: c.y - size.h / 2, w: size.w, h: size.h)),
                    (.left, Rect(x: c.x - half - gap - size.w, y: c.y - size.h / 2, w: size.w, h: size.h)),
                    (.above, Rect(x: c.x - size.w / 2, y: c.y - half - gap / 2 - size.h, w: size.w, h: size.h)),
                    (.below, Rect(x: c.x - size.w / 2, y: c.y + half + gap / 2, w: size.w, h: size.h)),
                ]
                let free = options.first { option in
                    let r = option.1.expanded(by: 1)
                    return !icons.contains(where: { $0.intersects(r) }) && !labels.contains(where: { $0.intersects(r) })
                }
                if let free {
                    anchor = free.0
                    label = free.1
                } else if w.kind.isSettlement {
                    // A settlement icon without its name is just noise; free its space for others.
                    icons[index] = Rect(x: 0, y: 0, w: 0, h: 0)
                    continue
                }
            }
            if let label { labels.append(label) }
            out.append(Placed(waypoint: w, x: c.x, y: c.y, iconSize: icon.w, fontSize: fontSize, label: label,
                              anchor: anchor, discovered: c.discovered))
        }
        return out
    }

    /// Rough serif text metrics, for when the platform can't measure.
    public static func estimate(_ waypoint: Waypoint, _ fontSize: Double) -> (w: Double, h: Double) {
        (Double(waypoint.label.count) * fontSize * 0.56, fontSize * 1.25)
    }
}
