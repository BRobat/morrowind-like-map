import Foundation
@testable import MorrowindMapCore
import XCTest

final class TileMathTests: XCTestCase {
    func testWorldRoundTrip() {
        let p = GeoPoint(latitude: 50.0614, longitude: 19.9366)
        let w = WebMercator.world(p)
        let back = WebMercator.geo(worldX: w.x, worldY: w.y)
        XCTAssertEqual(back.latitude, p.latitude, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, p.longitude, accuracy: 1e-9)
    }

    func testAncestor() {
        let a = TileID(z: 16, x: 36_000 + 3, y: 22_000 + 2).ancestor(atZoom: 14)
        XCTAssertEqual(a.tile, TileID(z: 14, x: 9000, y: 5500))
        XCTAssertEqual(a.scale, 0.25)
        XCTAssertEqual(a.offsetX, 0.75)
        XCTAssertEqual(a.offsetY, 0.5)
    }

    func testNormalizedWrapsX() {
        XCTAssertEqual(TileID(z: 2, x: -1, y: 1).normalized, TileID(z: 2, x: 3, y: 1))
        XCTAssertNil(TileID(z: 2, x: 0, y: 4).normalized)
    }
}

final class ElevationTests: XCTestCase {
    func testTerrariumDecoding() {
        // 1000 m = 33768 = 131 * 256 + 232
        var img = RGBAImage(width: 1, height: 1)
        img[0, 0] = RGB(131, 232, 0)
        XCTAssertEqual(ElevationGrid(terrarium: img).meters[0], 1000)
        img[0, 0] = RGB(128, 0, 0)
        XCTAssertEqual(ElevationGrid(terrarium: img).meters[0], 0)
    }

    func testResampleQuadrant() {
        // Left half 0 m, right half 100 m; the top-right quadrant should be all 100 m.
        let m = (0..<16).map { Float($0 % 4 >= 2 ? 100 : 0) }
        let g = ElevationGrid(width: 4, height: 4, meters: m).resampled(offsetX: 0.5, offsetY: 0, scale: 0.5, size: 4)
        XCTAssertTrue(g.meters.allSatisfy { $0 >= 50 })
    }
}

final class VectorTileTests: XCTestCase {
    /// Hand-encodes a tile with one layer "water" holding one square polygon with class=lake.
    static func squareWaterTile() -> Data {
        func varint(_ v: UInt64) -> [UInt8] {
            var v = v, out: [UInt8] = []
            repeat {
                var b = UInt8(v & 0x7F); v >>= 7
                if v != 0 { b |= 0x80 }
                out.append(b)
            } while v != 0
            return out
        }
        func zz(_ v: Int64) -> UInt64 { UInt64(bitPattern: (v << 1) ^ (v >> 63)) }
        func field(_ n: Int, _ wire: Int) -> [UInt8] { varint(UInt64(n << 3 | wire)) }
        func bytes(_ n: Int, _ b: [UInt8]) -> [UInt8] { field(n, 2) + varint(UInt64(b.count)) + b }
        func packed(_ n: Int, _ vals: [UInt64]) -> [UInt8] { bytes(n, vals.flatMap(varint)) }

        // MoveTo(1024,1024) LineTo(+2048,0)(0,+2048)(-2048,0) ClosePath
        let geom: [UInt64] = [9, zz(1024), zz(1024), 26, zz(2048), 0, 0, zz(2048), zz(-2048), 0, 15]
        let feature = packed(2, [0, 0]) + field(3, 0) + varint(3) + packed(4, geom)
        let value = bytes(1, Array("lake".utf8))
        let layer = field(15, 0) + varint(2) + bytes(1, Array("water".utf8)) + bytes(2, feature)
            + bytes(3, Array("class".utf8)) + bytes(4, value) + field(5, 0) + varint(4096)
        return Data(bytes(3, layer))
    }

    func testDecodeSquare() throws {
        let vt = try VectorTile(data: Self.squareWaterTile())
        let layer = try XCTUnwrap(vt.layers["water"])
        XCTAssertEqual(layer.extent, 4096)
        XCTAssertEqual(layer.features.count, 1)
        let f = layer.features[0]
        XCTAssertEqual(f.type, .polygon)
        XCTAssertEqual(f.properties["class"], .string("lake"))
        XCTAssertEqual(f.paths.count, 1)
        XCTAssertEqual(f.paths[0].map { [$0.x, $0.y] }, [[1024, 1024], [3072, 1024], [3072, 3072], [1024, 3072], [1024, 1024]])
    }

    func testRendererUsesVectorWater() throws {
        let vt = try VectorTile(data: Self.squareWaterTile())
        let renderer = TileRenderer(size: 64)
        // Flat land at 100 m everywhere: only the vector square should be water.
        let dem = ElevationGrid(width: 64, height: 64, meters: .init(repeating: 100, count: 64 * 64))
        let mask = renderer.waterMask(tile: TileID(z: 12, x: 0, y: 0), source: .init(tile: vt))
        XCTAssertTrue(mask[32 * 64 + 32])
        XCTAssertFalse(mask[2 * 64 + 2])
        XCTAssertEqual(mask.filter { $0 }.count, 32 * 32)
        _ = renderer.render(tile: TileID(z: 12, x: 0, y: 0), elevation: dem, water: .init(tile: vt))
    }

    func testEmptyTile() throws {
        XCTAssertTrue(try VectorTile(data: Data()).layers.isEmpty)
    }
}

final class RasterizerTests: XCTestCase {
    func testPolygonWithHole() {
        var m = Mask(width: 10, height: 10)
        let outer = [Mask.P(0, 0), Mask.P(10, 0), Mask.P(10, 10), Mask.P(0, 10)]
        let hole = [Mask.P(3, 3), Mask.P(3, 7), Mask.P(7, 7), Mask.P(7, 3)] // opposite winding
        m.fillPolygon([outer, hole])
        XCTAssertTrue(m[1, 1])
        XCTAssertFalse(m[5, 5])
        XCTAssertEqual(m.bits.filter { $0 }.count, 100 - 16)
    }

    func testStroke() {
        var m = Mask(width: 20, height: 20)
        m.strokePolyline([Mask.P(2, 10), Mask.P(18, 10)], width: 2)
        XCTAssertTrue(m[10, 9])
        XCTAssertTrue(m[10, 10])
        XCTAssertFalse(m[10, 13])
    }
}

final class FogTests: XCTestCase {
    let krakow = GeoPoint(latitude: 50.0614, longitude: 19.9366)

    func testRevealMarksPointAndRadius() {
        var g = FogGrid()
        let added = g.reveal(krakow, radius: 100)
        XCTAssertGreaterThan(added, 1)
        XCTAssertTrue(g.isExplored(krakow))
        XCTAssertTrue(g.isExplored(GeoPoint(latitude: krakow.latitude + 0.0002, longitude: krakow.longitude)))
        XCTAssertFalse(g.isExplored(GeoPoint(latitude: krakow.latitude + 0.01, longitude: krakow.longitude)))
        XCTAssertEqual(g.reveal(krakow, radius: 100), 0, "revealing again adds nothing")
    }

    func testTrackInterpolatesShortGaps() {
        var g = FogGrid()
        let b = GeoPoint(latitude: krakow.latitude + 0.01, longitude: krakow.longitude) // ~1.1 km north
        g.reveal(track: [krakow, b], radius: 50)
        XCTAssertTrue(g.isExplored(GeoPoint(latitude: krakow.latitude + 0.005, longitude: krakow.longitude)))

        var far = FogGrid()
        let c = GeoPoint(latitude: krakow.latitude + 0.1, longitude: krakow.longitude) // ~11 km, not bridged
        far.reveal(track: [krakow, c], radius: 50)
        XCTAssertFalse(far.isExplored(GeoPoint(latitude: krakow.latitude + 0.05, longitude: krakow.longitude)))
    }

    func testSerializationRoundTrip() throws {
        var g = FogGrid()
        g.reveal(krakow)
        let data = g.serialized()
        XCTAssertEqual(Array(data.prefix(4)), Array("MWFG".utf8))
        XCTAssertEqual(data.count, 12 + g.count * 8)
        XCTAssertEqual(try FogGrid(serialized: data), g)
        XCTAssertThrowsError(try FogGrid(serialized: Data("nope".utf8)))
    }

    func testMergeIsUnion() {
        var a = FogGrid(), b = FogGrid()
        a.reveal(krakow)
        b.reveal(GeoPoint(latitude: 52.2297, longitude: 21.0122))
        var ab = a; ab.merge(b)
        var ba = b; ba.merge(a)
        XCTAssertEqual(ab, ba)
        XCTAssertEqual(ab.count, a.count + b.count)
    }

    func testCoverageAtSeveralZooms() {
        var g = FogGrid()
        g.reveal(krakow, radius: 100)
        let w = WebMercator.world(krakow)
        for z in [10, 14, 17, 19] {
            let n = Double(1 << z)
            let tile = TileID(z: z, x: Int(w.x * n), y: Int(w.y * n))
            let cov = g.coverage(for: tile, size: 256, edgeSoftness: 6)
            let px = Int((w.x * n - Double(tile.x)) * 256), py = Int((w.y * n - Double(tile.y)) * 256)
            XCTAssertEqual(cov[py * 256 + px], 1, "explored point should be clear at z\(z)")
            if z <= 14 { XCTAssertTrue(cov.contains(0), "far corners should be fogged at z\(z)") }
        }
    }

    func testCompositorHiddenStyle() {
        let base = RGBAImage(width: 2, height: 1, fill: RGB(10, 20, 30))
        let out = FogCompositor.apply(to: base, coverage: [1, 0], style: .hidden, tile: TileID(z: 1, x: 0, y: 0))
        XCTAssertEqual(out[0, 0], RGB(10, 20, 30))
        XCTAssertNotEqual(out[1, 0], RGB(10, 20, 30))
    }

    func testHiddenFogLetsTerrainShowThrough() {
        // Same fogged pixel over dark and light terrain: with hiddenOpacity < 1 the results differ.
        let tile = TileID(z: 1, x: 0, y: 0)
        let dark = FogCompositor.apply(to: RGBAImage(width: 1, height: 1, fill: RGB(0, 0, 0)), coverage: [0], style: .hidden, tile: tile)
        let light = FogCompositor.apply(to: RGBAImage(width: 1, height: 1, fill: RGB(255, 255, 255)), coverage: [0], style: .hidden, tile: tile)
        XCTAssertLessThan(Palette.standard.fog.hiddenOpacity, 1)
        XCTAssertNotEqual(dark[0, 0], light[0, 0])
    }
}

final class GPXTests: XCTestCase {
    func testParsesSegments() {
        let gpx = """
        <?xml version="1.0"?>
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">
          <trk><trkseg>
            <trkpt lat="50.0" lon="19.9"><ele>210</ele></trkpt>
            <trkpt lat="50.001" lon="19.901"/>
          </trkseg><trkseg>
            <trkpt lat="50.1" lon="19.95"/>
          </trkseg></trk>
        </gpx>
        """
        let tracks = GPXParser.tracks(from: Data(gpx.utf8))
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].count, 2)
        XCTAssertEqual(tracks[1][0], GeoPoint(latitude: 50.1, longitude: 19.95))
    }
}

final class PaletteTests: XCTestCase {
    func testBundledPaletteMatchesShared() throws {
        let shared = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("shared/palette.json")
        let a = try Data(contentsOf: shared)
        let b = try Data(contentsOf: XCTUnwrap(MorrowindMapCoreResources.paletteURL))
        XCTAssertEqual(a, b, "Run tools/sync-palette.sh after editing shared/palette.json")
        XCTAssertEqual(Palette.standard.land.first?.elevation, 0)
    }

    func testSeaLevelFallbackColorsWater() {
        let renderer = TileRenderer(size: 8)
        var m = [Float](repeating: 300, count: 64)
        for i in 0..<32 { m[i] = -50 } // top half below sea level
        let img = renderer.render(tile: TileID(z: 10, x: 0, y: 0), elevation: ElevationGrid(width: 8, height: 8, meters: m), water: nil)
        let water = img[4, 1], land = img[4, 6]
        XCTAssertGreaterThan(Int(water.b), Int(water.r), "water should be blue")
        XCTAssertGreaterThan(Int(land.r), Int(land.b), "land should be brown")
    }
}

final class PerformanceBehaviourTests: XCTestCase {
    /// A 2 km track sampled every 2 m, like a 1 Hz recording at walking pace.
    private func denseTrack() -> [GeoPoint] {
        (0...1000).map { i in GeoPoint(latitude: 50.06 + Double(i) * 0.000018, longitude: 19.94 + Double(i) * 0.0000005) }
    }

    func testThinnedTrackRevealsAlmostTheSameCells() {
        let track = denseTrack()
        // Reference: every point stamped, as before thinning.
        var reference = FogGrid()
        for p in track { reference.reveal(p, radius: 250) }
        var thinned = FogGrid()
        thinned.reveal(track: track, radius: 250)

        let common = thinned.cells.intersection(reference.cells).count
        XCTAssertGreaterThanOrEqual(Double(common) / Double(reference.count), 0.98)
        XCTAssertTrue(thinned.isExplored(track.first!))
        XCTAssertTrue(thinned.isExplored(track.last!))
    }

    func testRevealBoundsCoverEveryNewCell() {
        var grid = FogGrid()
        var bounds: CellRect?
        grid.reveal(track: denseTrack(), radius: 250, bounds: &bounds)
        let b = try! XCTUnwrap(bounds)
        for key in grid.cells {
            let (x, y) = FogGrid.coords(key)
            XCTAssertTrue(x >= b.minX && x <= b.maxX && y >= b.minY && y <= b.maxY)
        }
        XCTAssertEqual(CellRect(covering: grid.cells), b)
    }

    func testCellRectIntersectsTiles() {
        // Tile 10/5/7 covers z18 cells x 1280...1535, y 1792...2047.
        let tile = TileID(z: 10, x: 5, y: 7)
        XCTAssertTrue(CellRect(minX: 1535, minY: 2047, maxX: 1535, maxY: 2047).intersects(tile: tile, marginCells: 0))
        XCTAssertFalse(CellRect(minX: 1536, minY: 1800, maxX: 1540, maxY: 1800).intersects(tile: tile, marginCells: 0))
        XCTAssertTrue(CellRect(minX: 1536, minY: 1800, maxX: 1540, maxY: 1800).intersects(tile: tile, marginCells: 1))
        // Above z18 a tile sits inside one cell.
        let deep = TileID(z: 19, x: 2 * 1300 + 1, y: 2 * 1900)
        XCTAssertTrue(CellRect(minX: 1300, minY: 1900, maxX: 1300, maxY: 1900).intersects(tile: deep, marginCells: 0))
        XCTAssertFalse(CellRect(minX: 1301, minY: 1900, maxX: 1301, maxY: 1900).intersects(tile: deep, marginCells: 0))
    }

    @MainActor
    func testBatchRevealMatchesSequentialAndTracksChanges() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracks = [denseTrack(), [GeoPoint(latitude: 46.0, longitude: 7.75), GeoPoint(latitude: 46.001, longitude: 7.751)]]

        let batched = FogStore(fileURL: dir.appendingPathComponent("a.mwfog"))
        batched.revealRadiusMeters = 250
        let r0 = batched.revision
        let added = await batched.reveal(tracks: tracks)

        var sequential = FogGrid()
        for t in tracks { sequential.reveal(track: t, radius: 250) }
        XCTAssertEqual(batched.grid, sequential)
        XCTAssertEqual(added, sequential.count)
        XCTAssertEqual(batched.revision, r0 + 1, "one commit for the whole batch")

        guard case .rect(let r) = batched.dirty(since: r0) else { return XCTFail("expected a rect") }
        XCTAssertEqual(r, CellRect(covering: sequential.cells))
        XCTAssertEqual(batched.dirty(since: batched.revision), .none)
        batched.reset()
        XCTAssertEqual(batched.dirty(since: r0), .all)
    }

    func testPNGRoundTrip() throws {
        var img = RGBAImage(width: 4, height: 3, fill: RGB(10, 20, 30))
        img[1, 2] = RGB(200, 150, 100)
        img[3, 0] = RGB(255, 0, 7)
        let png = try XCTUnwrap(ImageCodec.png(from: img))
        XCTAssertEqual(ImageCodec.decode(png), img)
    }
}
