import Foundation

/// One GPS fix, independent of CoreLocation so the filtering logic is testable everywhere.
public struct LocationFix: Sendable, Equatable {
    public var point: GeoPoint
    /// Meters; negative means invalid.
    public var horizontalAccuracy: Double
    /// Direction of travel in degrees from true north, nil when unknown.
    public var course: Double?
    /// Meters per second, nil when unknown.
    public var speed: Double?
    public var timestamp: Date

    public init(point: GeoPoint, horizontalAccuracy: Double, course: Double? = nil, speed: Double? = nil, timestamp: Date) {
        self.point = point
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course
        self.speed = speed
        self.timestamp = timestamp
    }
}

/// Decides which live GPS fixes go into the exploration log, and whether a fix continues the
/// current line or starts a new one (after a long pause or an implausible jump).
public struct TrackFilter: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Inaccurate, or too close to the last logged point.
        case reject
        /// First point of a new segment.
        case start
        /// Continues the segment from the given (previous) point.
        case extend(from: GeoPoint)
    }

    /// Fixes less accurate than this are dropped (matches the fog format's 50 m rule, a bit stricter).
    public var maxAccuracy = 35.0
    /// Minimum distance between logged points.
    public var minSpacing = 10.0
    /// A longer pause between logged points starts a new segment.
    public var maxGap: TimeInterval = 300
    /// Faster than this between points is treated as a GPS jump: new segment, no line drawn.
    public var maxSpeed = 70.0

    public private(set) var last: LocationFix?

    public init() {}

    public mutating func reset() { last = nil }

    public mutating func evaluate(_ fix: LocationFix) -> Decision {
        guard fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= maxAccuracy else { return .reject }
        guard let last else {
            self.last = fix
            return .start
        }
        let dt = fix.timestamp.timeIntervalSince(last.timestamp)
        guard dt >= 0 else { return .reject } // out-of-order delivery
        let d = GeoMath.distance(last.point, fix.point)
        if dt > maxGap || (dt > 0 && d / dt > maxSpeed) {
            self.last = fix
            return .start
        }
        guard d >= minSpacing else { return .reject }
        self.last = fix
        return .extend(from: last.point)
    }
}

/// A piece of a live-recorded track, sent from the watch to the iPhone.
/// Chunks of one segment share `segmentID` and are numbered by `sequence`. Each chunk after the
/// first starts with the last point of the previous one, so revealing chunks one by one still
/// leaves an unbroken trail.
public struct TrackChunk: Codable, Equatable, Sendable {
    public var segmentID: String
    public var sequence: Int
    public var points: [GeoPoint]

    public init(segmentID: String, sequence: Int, points: [GeoPoint]) {
        self.segmentID = segmentID
        self.sequence = sequence
        self.points = points
    }

    static let kind = "track"

    /// Property-list form for `WCSession.transferUserInfo`.
    public var userInfo: [String: Any] {
        ["kind": Self.kind, "segment": segmentID, "seq": sequence,
         "coords": points.flatMap { [$0.latitude, $0.longitude] }]
    }

    public init?(userInfo: [String: Any]) {
        guard userInfo["kind"] as? String == Self.kind,
              let segment = userInfo["segment"] as? String,
              let seq = userInfo["seq"] as? Int,
              let coords = userInfo["coords"] as? [Double],
              coords.count % 2 == 0, !coords.isEmpty else { return nil }
        self.segmentID = segment
        self.sequence = seq
        self.points = stride(from: 0, to: coords.count, by: 2).map { GeoPoint(latitude: coords[$0], longitude: coords[$0 + 1]) }
    }
}

/// Groups logged points into chunks: one is emitted every `maxPoints` points or once the oldest
/// unsent point is `maxAge` old, so the iPhone hears about progress about once a minute.
public struct TrackChunker: Sendable {
    public var maxPoints = 30
    public var maxAge: TimeInterval = 60

    private var segmentID: String?
    private var sequence = 0
    private var pending: [GeoPoint] = []
    private var pendingSince: Date?
    /// Last point already sent, repeated at the start of the next chunk.
    private var carry: GeoPoint?
    private let makeID: @Sendable () -> String

    public init(makeID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.makeID = makeID
    }

    /// Starts a new segment with `p`. Returns the finished chunk of the previous segment, if any.
    public mutating func start(_ p: GeoPoint, at date: Date) -> TrackChunk? {
        let finished = flush()
        segmentID = makeID()
        sequence = 0
        carry = nil
        pending = [p]
        pendingSince = date
        return finished
    }

    /// Adds `p` to the current segment (starting one if needed). Returns a chunk when one is due.
    public mutating func extend(_ p: GeoPoint, at date: Date) -> TrackChunk? {
        guard segmentID != nil else { return start(p, at: date) }
        if pending.isEmpty { pendingSince = date }
        pending.append(p)
        return due(at: date) ? flush() : nil
    }

    /// Whether unsent points have waited long enough (call from a timer while standing still).
    public func due(at date: Date) -> Bool {
        guard let since = pendingSince, !pending.isEmpty else { return false }
        return pending.count >= maxPoints || date.timeIntervalSince(since) >= maxAge
    }

    /// Emits the unsent points now, if any.
    public mutating func flush() -> TrackChunk? {
        guard let segmentID, !pending.isEmpty else { return nil }
        let chunk = TrackChunk(segmentID: segmentID, sequence: sequence, points: (carry.map { [$0] } ?? []) + pending)
        sequence += 1
        carry = pending.last
        pending = []
        pendingSince = nil
        return chunk
    }
}

/// The iPhone's permanent record of tracks logged on the watch, so they can be revealed again
/// after "Re-import all workouts" resets the fog. One small JSON file per chunk; duplicates
/// (WatchConnectivity may deliver twice) simply overwrite.
public final class RecordedTrackLog: @unchecked Sendable {
    public let directory: URL
    private let queue = DispatchQueue(label: "RecordedTrackLog")

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("watch-tracks", isDirectory: true)
    }

    private func url(for chunk: TrackChunk) -> URL {
        let safeID = chunk.segmentID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory.appendingPathComponent("\(safeID)-\(chunk.sequence).json")
    }

    public func append(_ chunk: TrackChunk) {
        queue.sync {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(chunk) { try? data.write(to: url(for: chunk), options: .atomic) }
        }
    }

    /// Every logged segment as one track, chunks in order.
    public func allTracks() -> [[GeoPoint]] {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            var segments: [String: [TrackChunk]] = [:]
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let chunk = try? JSONDecoder().decode(TrackChunk.self, from: data) else { continue }
                segments[chunk.segmentID, default: []].append(chunk)
            }
            return segments.keys.sorted().map { id in
                var track: [GeoPoint] = []
                for chunk in segments[id]!.sorted(by: { $0.sequence < $1.sequence }) {
                    // Drop the repeated carry point when it matches the previous chunk's end.
                    let pts = track.last == chunk.points.first ? chunk.points.dropFirst() : chunk.points[...]
                    track += pts
                }
                return track
            }
        }
    }
}
