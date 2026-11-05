import Foundation
@testable import MorrowindMapCore
import XCTest

final class GeoMathTests: XCTestCase {
    let krakow = GeoPoint(latitude: 50.0614, longitude: 19.9366)

    func testBearingCardinals() {
        XCTAssertEqual(GeoMath.bearing(from: krakow, to: GeoPoint(latitude: 50.1, longitude: 19.9366)), 0, accuracy: 0.01)
        XCTAssertEqual(GeoMath.bearing(from: krakow, to: GeoPoint(latitude: 50.0, longitude: 19.9366)), 180, accuracy: 0.01)
        XCTAssertEqual(GeoMath.bearing(from: krakow, to: GeoPoint(latitude: 50.0614, longitude: 20.0)), 90, accuracy: 0.1)
        XCTAssertEqual(GeoMath.bearing(from: krakow, to: GeoPoint(latitude: 50.0614, longitude: 19.8)), 270, accuracy: 0.1)
    }

    func testRelativeTurn() {
        XCTAssertEqual(GeoMath.relative(bearing: 10, heading: 350), 20)
        XCTAssertEqual(GeoMath.relative(bearing: 350, heading: 10), -20)
        XCTAssertEqual(GeoMath.relative(bearing: 180, heading: 0), -180)
        XCTAssertEqual(GeoMath.normalized(-90), 270)
    }

    func testCompassNames() {
        XCTAssertEqual(GeoMath.compassName(0), "N")
        XCTAssertEqual(GeoMath.compassName(359), "N")
        XCTAssertEqual(GeoMath.compassName(44), "NE")
        XCTAssertEqual(GeoMath.compassName(100), "E")
        XCTAssertEqual(GeoMath.compassName(225), "SW")
    }

    func testGuidanceArrival() {
        let near = GeoPoint(latitude: krakow.latitude + 0.0001, longitude: krakow.longitude) // ~11 m north
        let g = TargetGuidance(from: krakow, to: near, heading: 90)
        XCTAssertTrue(g.hasArrived)
        XCTAssertEqual(g.turn ?? 0, -90, accuracy: 0.1)
        XCTAssertNil(TargetGuidance(from: krakow, to: near, heading: nil).turn)
    }

    @MainActor
    func testTargetStoreNewestWins() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = TargetStore(defaults: defaults)
        var pushed = 0
        store.onLocalChange = { _, _ in pushed += 1 }
        store.set(krakow, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(pushed, 1)
        // An older remote clear must not wipe the newer local target.
        XCTAssertFalse(store.applyRemote(nil, updatedAt: Date(timeIntervalSince1970: 50)))
        XCTAssertEqual(store.target?.point, krakow)
        XCTAssertTrue(store.applyRemote(nil, updatedAt: Date(timeIntervalSince1970: 150)))
        XCTAssertNil(store.target)
        XCTAssertEqual(pushed, 1, "remote changes are not pushed back")
        // Persisted.
        store.set(krakow, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(TargetStore(defaults: defaults).target?.point, krakow)
    }
}

final class TrackLoggingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func fix(_ dLat: Double, _ seconds: Double, accuracy: Double = 5) -> LocationFix {
        LocationFix(point: GeoPoint(latitude: 50 + dLat, longitude: 20), horizontalAccuracy: accuracy,
                    timestamp: t0.addingTimeInterval(seconds))
    }

    func testFilter() {
        var f = TrackFilter()
        XCTAssertEqual(f.evaluate(fix(0, 0, accuracy: 80)), .reject, "inaccurate")
        XCTAssertEqual(f.evaluate(fix(0, 0)), .start)
        XCTAssertEqual(f.evaluate(fix(0.00002, 2)), .reject, "~2 m: too close")
        XCTAssertEqual(f.evaluate(fix(0.0002, 10)), .extend(from: GeoPoint(latitude: 50, longitude: 20)))
        XCTAssertEqual(f.evaluate(fix(0.05, 11)), .start, "5 km in 1 s is a GPS jump")
        XCTAssertEqual(f.evaluate(fix(0.0502, 1000)), .start, "long pause")
        f.reset()
        XCTAssertEqual(f.evaluate(fix(0.06, 1001)), .start)
    }

    func testChunkerCarriesLastPoint() {
        var c = TrackChunker(makeID: { "seg" })
        c.maxPoints = 3
        let p = (0..<7).map { GeoPoint(latitude: Double($0), longitude: 0) }
        XCTAssertNil(c.start(p[0], at: t0))
        XCTAssertNil(c.extend(p[1], at: t0))
        let first = c.extend(p[2], at: t0)
        XCTAssertEqual(first, TrackChunk(segmentID: "seg", sequence: 0, points: [p[0], p[1], p[2]]))
        XCTAssertNil(c.extend(p[3], at: t0))
        XCTAssertTrue(c.due(at: t0.addingTimeInterval(61)), "old points are due")
        let second = c.flush()
        XCTAssertEqual(second, TrackChunk(segmentID: "seg", sequence: 1, points: [p[2], p[3]]))
        XCTAssertNil(c.flush(), "nothing new")
    }

    func testChunkUserInfoRoundTrip() {
        let chunk = TrackChunk(segmentID: "abc", sequence: 4,
                               points: [GeoPoint(latitude: 50.1, longitude: 19.9), GeoPoint(latitude: 50.2, longitude: 20)])
        XCTAssertEqual(TrackChunk(userInfo: chunk.userInfo), chunk)
        XCTAssertNil(TrackChunk(userInfo: ["kind": "fog"]))
    }

    func testRecordedLogJoinsChunks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = RecordedTrackLog(directory: dir)
        let p = (0..<4).map { GeoPoint(latitude: Double($0), longitude: 0) }
        log.append(TrackChunk(segmentID: "a", sequence: 1, points: [p[1], p[2], p[3]]))
        log.append(TrackChunk(segmentID: "a", sequence: 0, points: [p[0], p[1]]))
        log.append(TrackChunk(segmentID: "a", sequence: 0, points: [p[0], p[1]])) // duplicate delivery
        log.append(TrackChunk(segmentID: "b", sequence: 0, points: [p[3]]))
        XCTAssertEqual(log.allTracks(), [p, [p[3]]])
    }
}
