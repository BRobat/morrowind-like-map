import CoreGraphics
import Foundation
import MorrowindMapCore
import Observation

/// In-memory cache of rendered tiles for the map view.
/// Base tiles (expensive: network + terrain render) survive fog changes; only the cheap fog
/// composite is redone when the explored area or the fog style changes.
@MainActor
@Observable
public final class MapTileCache {
    /// Tiles ready to draw for the current fog state, keyed by normalised tile ID.
    public private(set) var images: [TileID: CGImage] = [:]
    /// Images from the previous fog state, drawn until their replacement is ready (avoids flashing).
    @ObservationIgnored private var staleImages: [TileID: CGImage] = [:]

    @ObservationIgnored private let provider: TileProvider
    @ObservationIgnored private var bases: [TileID: RGBAImage] = [:]
    @ObservationIgnored private var baseOrder: [TileID] = []
    @ObservationIgnored private var pending: Set<TileID> = []
    @ObservationIgnored private var failed: [TileID: Date] = [:]
    @ObservationIgnored private var fogKey: FogKey?
    @ObservationIgnored private var currentFog = FogGrid()
    @ObservationIgnored private let baseLimit: Int

    private struct FogKey: Equatable {
        var revision: Int
        var style: FogStyle
    }

    public init(provider: TileProvider = TileProvider(), memoryLimit: Int? = nil) {
        self.provider = provider
        #if os(watchOS)
        self.baseLimit = memoryLimit ?? 40
        #else
        self.baseLimit = memoryLimit ?? 160
        #endif
    }

    /// Makes sure `tiles` (normalised IDs) are loaded or loading, composited with the given fog.
    public func request(_ tiles: [TileID], fog: FogGrid, revision: Int, style: FogStyle) {
        let key = FogKey(revision: revision, style: style)
        currentFog = fog
        if key != fogKey {
            fogKey = key
            staleImages.merge(images) { new, _ in new }
            images.removeAll(keepingCapacity: true)
        }
        for tile in tiles where images[tile] == nil && !pending.contains(tile) {
            if let at = failed[tile], Date().timeIntervalSince(at) < 30 { continue }
            pending.insert(tile)
            let base = bases[tile]
            let provider = self.provider
            let palette = provider.renderer.palette
            Task.detached(priority: .userInitiated) {
                do {
                    let b: RGBAImage
                    if let base { b = base } else { b = try await provider.baseTile(tile) }
                    let composed = TileProvider.applyFog(b, tile: tile, fog: fog, style: style, palette: palette)
                    let cg = ImageCodec.cgImage(from: composed)
                    await self.finish(tile, base: b, image: cg, key: key)
                } catch {
                    await self.fail(tile)
                }
            }
        }
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

    private func finish(_ tile: TileID, base: RGBAImage, image: CGImage?, key: FogKey) {
        pending.remove(tile)
        failed[tile] = nil
        if bases[tile] == nil {
            bases[tile] = base
            baseOrder.append(tile)
            while baseOrder.count > baseLimit {
                let old = baseOrder.removeFirst()
                bases[old] = nil
                images[old] = nil
                staleImages[old] = nil
            }
        }
        guard let current = fogKey else { return }
        if key == current {
            if let image {
                images[tile] = image
                staleImages[tile] = nil
            }
        } else {
            // Composed against an outdated fog state: redo the (cheap) composite from the cached base.
            request([tile], fog: currentFog, revision: current.revision, style: current.style)
        }
    }

    private func fail(_ tile: TileID) {
        pending.remove(tile)
        failed[tile] = Date()
    }
}
