#if canImport(ImageIO)
import Foundation

/// Downloads raw tile bytes with a permanent on-disk cache and request de-duplication.
/// Every tile is fetched once per device; afterwards the map works offline for that area.
public actor TileFetcher {
    private let session: URLSession
    private let cacheDirectory: URL
    private var inFlight: [URL: Task<Data, Error>] = [:]

    public enum FetchError: Error { case http(Int), notFound }

    public init(cacheDirectory: URL? = nil) {
        let base = cacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("tiles")
        self.cacheDirectory = base
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["User-Agent": "MorrowindLikeMap/0.1 (+https://github.com/BRobat/morrowind-like-map)"]
        config.httpMaximumConnectionsPerHost = 6
        config.urlCache = nil // we keep our own permanent cache
        self.session = URLSession(configuration: config)
    }

    /// - Parameter cacheKey: stable relative path, e.g. "terrain/12/2200/1343.png".
    public func data(from url: URL, cacheKey: String) async throws -> Data {
        let file = cacheDirectory.appendingPathComponent(cacheKey)
        if let cached = try? Data(contentsOf: file) { return cached }
        if let task = inFlight[url] { return try await task.value }

        let session = self.session
        let task = Task<Data, Error> {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw http.statusCode == 404 || http.statusCode == 204 ? FetchError.notFound : FetchError.http(http.statusCode)
            }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        return try await task.value
    }

    /// Fetches without caching to disk (for TileJSON, which changes when OpenFreeMap publishes new data).
    public func uncachedData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw FetchError.http(http.statusCode) }
        return data
    }
}

/// Turns tile addresses into rendered Morrowind-style images (with fog applied on request).
public final class TileProvider: @unchecked Sendable {
    public let renderer: TileRenderer
    private let fetcher: TileFetcher
    private let decoded = DecodedCache()
    private let waterTemplate = WaterTemplate()
    /// Rendered base tiles as PNGs, so relaunches don't decode and render terrain again.
    private let renderedDirectory: URL

    /// - Parameter renderedCacheDirectory: where rendered base tiles are kept; defaults to
    ///   `Caches/tiles/rendered/<renderer.cacheKey>` (the system may purge it, which only costs a re-render).
    public init(renderer: TileRenderer = TileRenderer(), fetcher: TileFetcher = TileFetcher(), renderedCacheDirectory: URL? = nil) {
        self.renderer = renderer
        self.fetcher = fetcher
        self.renderedDirectory = renderedCacheDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("tiles/rendered/\(renderer.cacheKey)")
    }

    /// The base map for a tile without fog, plus its road layer.
    public func baseTile(_ tile: TileID) async throws -> BaseTile {
        let dir = renderedDirectory.appendingPathComponent("\(tile.z)/\(tile.x)")
        let file = dir.appendingPathComponent("\(tile.y).png")
        let roadsFile = dir.appendingPathComponent("\(tile.y).roads.png")
        let size = renderer.size
        if let data = try? Data(contentsOf: file), let img = ImageCodec.decode(data),
           img.width == size, img.height == size {
            // The road file is written before the tile, so a tile without one has no roads.
            let roads = (try? Data(contentsOf: roadsFile)).flatMap(ImageCodec.decode)
                .flatMap { $0.width == size && $0.height == size ? Self.roadCoverage(fromGray: $0) : nil }
            return BaseTile(image: img, roads: roads)
        }
        async let demTask = elevation(for: tile)
        async let waterTask = water(for: tile)
        let (dem, w) = try await (demTask, waterTask)
        let img = renderer.render(tile: tile, elevation: dem, water: w)
        let roads = w.flatMap { renderer.roadMask(tile: tile, source: $0) }
        // Without vectors (offline) the renderer guesses water from elevation and has no roads; don't keep that.
        if w != nil {
            Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let roads, let png = ImageCodec.png(from: TileProvider.grayImage(fromRoadCoverage: roads, size: size)) {
                    try? png.write(to: roadsFile, options: .atomic)
                } else {
                    try? FileManager.default.removeItem(at: roadsFile)
                }
                guard let png = ImageCodec.png(from: img) else { return }
                try? png.write(to: file, options: .atomic)
            }
        }
        return BaseTile(image: img, roads: roads)
    }

    /// Road coverage is stored as a grayscale PNG (it compresses to almost nothing where there are no roads).
    static func grayImage(fromRoadCoverage roads: [UInt8], size: Int) -> RGBAImage {
        var px = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<roads.count {
            px[i * 4] = roads[i]
            px[i * 4 + 1] = roads[i]
            px[i * 4 + 2] = roads[i]
        }
        return RGBAImage(width: size, height: size, pixels: px)
    }

    static func roadCoverage(fromGray img: RGBAImage) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: img.width * img.height)
        var any = false
        for i in 0..<out.count {
            out[i] = img.pixels[i * 4]
            if out[i] != 0 { any = true }
        }
        return any ? out : nil
    }

    /// The base map with fog of war composited on top (roads only where explored).
    public func tile(_ tile: TileID, fog: FogGrid, style: FogStyle) async throws -> RGBAImage {
        let base = try await baseTile(tile)
        return Self.applyFog(base, tile: tile, fog: fog, style: style, palette: renderer.palette)
    }

    public static func applyFog(_ base: BaseTile, tile: TileID, fog: FogGrid, style: FogStyle, palette: Palette,
                                roads: RoadVisibility = .explored) -> RGBAImage {
        let coverage = fog.coverage(for: tile, size: base.image.width, edgeSoftness: palette.fog.edgeSoftnessPx)
        return FogCompositor.apply(to: base.image, coverage: coverage, style: style, palette: palette, tile: tile,
                                   roads: roads == .off ? nil : base.roads, roadsEverywhere: roads == .everywhere)
    }

    // MARK: - Inputs

    private func elevation(for tile: TileID) async throws -> ElevationGrid {
        let a = tile.ancestor(atZoom: min(tile.z, MapSources.terrainMaxZoom))
        let source: ElevationGrid
        if let cached = await decoded.elevation(a.tile) {
            source = cached
        } else {
            guard let url = MapSources.url(template: MapSources.terrainURLTemplate, tile: a.tile) else { throw TileFetcher.FetchError.notFound }
            let data = try await fetcher.data(from: url, cacheKey: "terrain/\(a.tile.z)/\(a.tile.x)/\(a.tile.y).png")
            guard let img = ImageCodec.decode(data) else { throw TileFetcher.FetchError.notFound }
            source = ElevationGrid(terrarium: img)
            await decoded.store(elevation: source, for: a.tile)
        }
        return source.resampled(offsetX: a.offsetX, offsetY: a.offsetY, scale: a.scale, size: renderer.size)
    }

    /// Water vectors, or nil if they can't be loaded (then the renderer falls back to sea level).
    private func water(for tile: TileID) async -> TileRenderer.WaterSource? {
        let a = tile.ancestor(atZoom: min(tile.z, MapSources.vectorMaxZoom))
        guard let vt = await vectorTile(a.tile) else { return nil }
        return .init(tile: vt, offsetX: a.offsetX, offsetY: a.offsetY, scale: a.scale)
    }

    /// The OpenMapTiles vector tile (water, places, POIs, ...) for `tile`, which must be at or below
    /// `MapSources.vectorMaxZoom`. Returns nil if it can't be loaded right now (offline and not cached).
    /// The same downloaded file serves both the water mask and the waypoints.
    public func vectorTile(_ tile: TileID) async -> VectorTile? {
        if let cached = await decoded.vector(tile) { return cached }
        do {
            let template = try await waterTemplate.resolve(using: fetcher)
            guard let url = MapSources.url(template: template, tile: tile) else { return nil }
            let data = try await fetcher.data(from: url, cacheKey: "water/\(tile.z)/\(tile.x)/\(tile.y).pbf")
            let vt = try VectorTile(data: data)
            await decoded.store(vector: vt, for: tile)
            return vt
        } catch TileFetcher.FetchError.notFound {
            // No tile means no features (open land), which is not the same as "unknown".
            let empty = VectorTile.empty
            await decoded.store(vector: empty, for: tile)
            return empty
        } catch {
            return nil
        }
    }
}

extension VectorTile {
    static let empty: VectorTile = try! VectorTile(data: Data())
}

/// Resolves OpenFreeMap's versioned tile URL from its TileJSON, remembering it between launches.
private actor WaterTemplate {
    private static let defaultsKey = "openfreemap.planet.template"
    private var template: String? = UserDefaults.standard.string(forKey: WaterTemplate.defaultsKey)
    private var refreshed = false

    func resolve(using fetcher: TileFetcher) async throws -> String {
        if let template, refreshed { return template }
        do {
            let data = try await fetcher.uncachedData(from: MapSources.waterTileJSON)
            let json = try JSONDecoder().decode(TileJSON.self, from: data)
            guard let t = json.tiles.first else { throw TileFetcher.FetchError.notFound }
            template = t
            refreshed = true
            UserDefaults.standard.set(t, forKey: Self.defaultsKey)
            return t
        } catch {
            // Offline: a previously resolved template still works for cached tiles.
            if let template { return template }
            throw error
        }
    }
}

/// Small LRU caches of decoded source tiles; overzoomed children reuse their parent's decode.
private actor DecodedCache {
    private var elevations: [TileID: ElevationGrid] = [:]
    private var vectors: [TileID: VectorTile] = [:]
    private var order: [TileID] = []
    private let limit = 48

    func elevation(_ t: TileID) -> ElevationGrid? { elevations[t] }
    func vector(_ t: TileID) -> VectorTile? { vectors[t] }

    func store(elevation: ElevationGrid, for t: TileID) {
        elevations[t] = elevation
        touch(t)
    }

    func store(vector: VectorTile, for t: TileID) {
        vectors[t] = vector
        touch(t)
    }

    private func touch(_ t: TileID) {
        order.removeAll { $0 == t }
        order.append(t)
        while order.count > limit {
            let old = order.removeFirst()
            elevations[old] = nil
            vectors[old] = nil
        }
    }
}
#endif
