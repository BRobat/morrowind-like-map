import CoreGraphics
import Foundation
import MorrowindMapCore
import Observation

/// In-memory cache of rendered tiles for the map view.
/// Base tiles (expensive: network + terrain render) survive fog changes; only the cheap fog
/// composite is redone, and only for tiles the change actually touches.
@MainActor
@Observable
public final class MapTileCache {
    /// Tiles ready to draw for the current fog state, keyed by normalised tile ID.
    public private(set) var images: [TileID: CGImage] = [:]
    /// Images from the previous fog state, drawn until their replacement is ready (avoids flashing).
    @ObservationIgnored private var staleImages: [TileID: CGImage] = [:]
    /// Cropped ancestor images for overzoomed tiles, with the source they were cut from.
    @ObservationIgnored private var crops: [TileID: (source: CGImage, image: CGImage)] = [:]

    /// Shared with `WaypointCache`, so both read the same downloaded vector tiles.
    @ObservationIgnored public let provider: TileProvider
    @ObservationIgnored private var bases: [TileID: RGBAImage] = [:]
    /// Least recently requested first.
    @ObservationIgnored private var lru: [TileID] = []
    /// Tiles the view currently shows, centre first. Only these get rendered.
    @ObservationIgnored private var wanted: [TileID] = []
    @ObservationIgnored private var pending: Set<TileID> = []
    @ObservationIgnored private var failed: [TileID: Date] = [:]
    @ObservationIgnored private weak var fog: FogStore?
    @ObservationIgnored private var revision: Int?
    @ObservationIgnored private var style: FogStyle?
    @ObservationIgnored private let baseLimit: Int
    @ObservationIgnored private let maxConcurrent: Int

    public init(provider: TileProvider = TileProvider(), memoryLimit: Int? = nil) {
        self.provider = provider
        #if os(watchOS)
        self.baseLimit = memoryLimit ?? 40
        self.maxConcurrent = 2
        #else
        self.baseLimit = memoryLimit ?? 160
        self.maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount)
        #endif
    }

    /// Makes sure `tiles` (normalised IDs, centre first) are loaded or loading, composited with the current fog.
    /// Tiles from earlier calls that are no longer listed are not started.
    public func request(_ tiles: [TileID], fog: FogStore) {
        self.fog = fog
        if style != fog.style {
            invalidate(.all)
            style = fog.style
        } else if let old = revision, old != fog.revision {
            invalidate(fog.dirty(since: old))
        }
        revision = fog.revision
        touch(tiles)
        wanted = tiles
        pump()
    }

    /// Best available image for a tile: the tile itself, or a loaded ancestor with the sub-rect to draw.
    public func image(for tile: TileID) -> (image: CGImage, crop: CGRect)? {
        var t = tile
        for _ in 0...5 {
            if let img = images[t] ?? (t == tile ? staleImages[t] : nil) {
                let a = tile.ancestor(atZoom: t.z)
                let w = Double(img.width)
                return (img, CGRect(x: a.offsetX * w, y: a.offsetY * w, width: a.scale * w, height: a.scale * w))
            }
            guard t.z > 0 else { break }
            t = TileID(z: t.z - 1, x: t.x >> 1, y: t.y >> 1)
        }
        return nil
    }

    /// The image to draw for `tile`, already cropped when it comes from an ancestor.
    /// Crops are cached so panning an overzoomed map doesn't cut new images every frame.
    public func drawableImage(for tile: TileID) -> CGImage? {
        guard let found = image(for: tile) else { return nil }
        guard found.crop.width < Double(found.image.width) else { return found.image }
        if let cached = crops[tile], cached.source === found.image { return cached.image }
        guard let cropped = found.image.cropping(to: found.crop) else { return found.image }
        if crops.count > baseLimit * 2 { crops.removeAll(keepingCapacity: true) }
        crops[tile] = (found.image, cropped)
        return cropped
    }

    private func marginCells(_ tile: TileID) -> Int {
        FogGrid.marginCells(zoom: tile.z, size: provider.renderer.size, edgeSoftness: provider.renderer.palette.fog.edgeSoftnessPx)
    }

    private func invalidate(_ dirty: FogDirty) {
        let ids: [TileID]
        switch dirty {
        case .none: return
        case .all: ids = Array(images.keys)
        case .rect: ids = images.keys.filter { dirty.affects($0, marginCells: marginCells($0)) }
        }
        for id in ids {
            staleImages[id] = images.removeValue(forKey: id)
        }
    }

    private func touch(_ tiles: [TileID]) {
        for t in tiles where bases[t] != nil {
            if let i = lru.firstIndex(of: t) { lru.remove(at: i) }
            lru.append(t)
        }
    }

    /// Starts renders for wanted tiles, centre first, up to `maxConcurrent` at a time.
    private func pump() {
        guard let fog else { return }
        for tile in wanted where pending.count < maxConcurrent {
            guard images[tile] == nil, !pending.contains(tile) else { continue }
            if let at = failed[tile], Date().timeIntervalSince(at) < 30 { continue }
            start(tile, fog: fog)
        }
    }

    private func start(_ tile: TileID, fog: FogStore) {
        pending.insert(tile)
        let base = bases[tile]
        let provider = self.provider
        let palette = provider.renderer.palette
        let grid = fog.grid, style = fog.style, revision = fog.revision
        Task.detached(priority: .userInitiated) {
            do {
                let b: RGBAImage
                if let base { b = base } else { b = try await provider.baseTile(tile) }
                let composed = TileProvider.applyFog(b, tile: tile, fog: grid, style: style, palette: palette)
                let cg = ImageCodec.cgImage(from: composed)
                await self.finish(tile, base: b, image: cg, revision: revision, style: style)
            } catch {
                await self.fail(tile)
            }
        }
    }

    private func finish(_ tile: TileID, base: RGBAImage, image: CGImage?, revision: Int, style: FogStyle) {
        pending.remove(tile)
        failed[tile] = image == nil ? Date() : nil
        if bases[tile] == nil {
            bases[tile] = base
            lru.append(tile)
            while lru.count > baseLimit {
                let old = lru.removeFirst()
                bases[old] = nil
                images[old] = nil
                staleImages[old] = nil
                crops[old] = nil
            }
        }
        // An image composed against an older fog state is still right if no change since touched the tile.
        // Otherwise it's dropped and `pump` redoes the (cheap) composite from the cached base.
        if let fog, let image, style == fog.style,
           revision == fog.revision || !fog.dirty(since: revision).affects(tile, marginCells: marginCells(tile)) {
            images[tile] = image
            staleImages[tile] = nil
        }
        pump()
    }

    private func fail(_ tile: TileID) {
        pending.remove(tile)
        failed[tile] = Date()
        pump()
    }
}
