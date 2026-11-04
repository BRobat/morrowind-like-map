import Foundation
import MorrowindMapCore
import Observation

/// Towns, villages and points of interest for the map view, read from the same OpenMapTiles
/// vector tiles that provide water (so they cost no extra downloads).
@MainActor
@Observable
public final class WaypointCache {
    /// Bumped whenever new waypoints arrive, so the map redraws.
    public private(set) var revision = 0

    @ObservationIgnored private let provider: TileProvider
    @ObservationIgnored private var byTile: [TileID: [Waypoint]] = [:]
    @ObservationIgnored private var order: [TileID] = []
    @ObservationIgnored private var pending: Set<TileID> = []
    @ObservationIgnored private var failed: [TileID: Date] = [:]
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private var discovery: [String: Bool] = [:]
    @ObservationIgnored private var discoveryRevision = -1

    /// - Parameter provider: pass `MapTileCache.provider` so decoded tiles are shared.
    public init(provider: TileProvider, memoryLimit: Int? = nil) {
        self.provider = provider
        #if os(watchOS)
        self.limit = memoryLimit ?? 64
        #else
        self.limit = memoryLimit ?? 256
        #endif
    }

    /// Vector tiles to read waypoints from for the given (normalised) map tiles: the same tiles,
    /// or their ancestors at the vector source's max zoom when overzooming.
    public static func dataTiles(for visible: [TileID]) -> [TileID] {
        var seen = Set<TileID>()
        var out: [TileID] = []
        for t in visible {
            let a = t.ancestor(atZoom: min(t.z, MapSources.vectorMaxZoom)).tile
            if seen.insert(a).inserted { out.append(a) }
        }
        return out
    }

    /// Makes sure `tiles` (from `dataTiles(for:)`) are loaded or loading.
    public func request(_ tiles: [TileID]) {
        for tile in tiles where byTile[tile] == nil && !pending.contains(tile) {
            if let at = failed[tile], Date().timeIntervalSince(at) < 30 { continue }
            pending.insert(tile)
            let provider = self.provider
            Task.detached(priority: .utility) {
                let vt = await provider.vectorTile(tile)
                let found = vt.map { WaypointExtractor.waypoints(in: $0, tile: tile) }
                await self.finish(tile, found)
            }
        }
    }

    /// Waypoints inside `tiles`, without duplicates. While a tile is still loading, the waypoints of
    /// a loaded ancestor that fall inside it are used instead, so places don't blink out on zoom.
    public func waypoints(in tiles: [TileID]) -> [Waypoint] {
        var seen = Set<String>()
        var out: [Waypoint] = []
        for tile in tiles {
            let list: [Waypoint]
            if let own = byTile[tile] {
                list = own
            } else if let ancestor = loadedAncestor(of: tile), let theirs = byTile[ancestor] {
                list = theirs.filter { Self.tile(tile, contains: $0.location) }
            } else {
                continue
            }
            for w in list where seen.insert(w.id).inserted { out.append(w) }
        }
        return out
    }

    /// Whether the player has been near `waypoint`, memoised until the fog changes.
    public func isDiscovered(_ waypoint: Waypoint, fog: FogGrid, revision: Int) -> Bool {
        if revision != discoveryRevision {
            discovery.removeAll(keepingCapacity: true)
            discoveryRevision = revision
        }
        if let known = discovery[waypoint.id] { return known }
        let d = fog.discovered(waypoint)
        discovery[waypoint.id] = d
        return d
    }

    private func loadedAncestor(of tile: TileID) -> TileID? {
        var t = tile
        for _ in 0..<6 {
            guard t.z > 0 else { return nil }
            t = TileID(z: t.z - 1, x: t.x >> 1, y: t.y >> 1)
            if byTile[t] != nil { return t }
        }
        return nil
    }

    private static func tile(_ tile: TileID, contains p: GeoPoint) -> Bool {
        let w = WebMercator.world(p)
        let n = Double(1 << tile.z)
        return Int(floor(w.x * n)) == tile.x && Int(floor(w.y * n)) == tile.y
    }

    private func finish(_ tile: TileID, _ found: [Waypoint]?) {
        pending.remove(tile)
        guard let found else {
            failed[tile] = Date()
            return
        }
        failed[tile] = nil
        if byTile[tile] == nil { order.append(tile) }
        byTile[tile] = found
        while order.count > limit {
            byTile[order.removeFirst()] = nil
        }
        revision += 1
    }
}
