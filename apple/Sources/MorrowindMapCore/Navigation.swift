import Foundation
#if canImport(Observation)
import Observation
#endif

/// Direction and distance math for the compass (the "quest marker").
public enum GeoMath {
    /// Great-circle distance in meters.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        FogGrid.distance(a, b)
    }

    /// Initial great-circle bearing from `a` to `b`, in degrees clockwise from true north (0..<360).
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalized(atan2(y, x) * 180 / .pi)
    }

    /// Wraps an angle into 0..<360.
    public static func normalized(_ degrees: Double) -> Double {
        let d = degrees.truncatingRemainder(dividingBy: 360)
        return d < 0 ? d + 360 : d
    }

    /// How far to turn from `heading` to face `bearing`: -180..<180, negative = turn left.
    public static func relative(bearing: Double, heading: Double) -> Double {
        let d = normalized(bearing - heading)
        return d >= 180 ? d - 360 : d
    }

    /// Eight-wind compass name ("N", "NE", ...).
    public static func compassName(_ bearing: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((normalized(bearing) + 22.5) / 45) % 8]
    }
}

/// The point the compass guides you to. Set on either device and synced to the other.
public struct NavigationTarget: Codable, Equatable, Sendable {
    public var point: GeoPoint
    public var setAt: Date

    public init(point: GeoPoint, setAt: Date = Date()) {
        self.point = point
        self.setAt = setAt
    }
}

/// Where the user is heading towards the target, ready to show.
public struct TargetGuidance: Equatable, Sendable {
    /// Meters to the target.
    public var distance: Double
    /// Bearing to the target, degrees from true north.
    public var bearing: Double
    /// Turn needed from the current heading (-180..<180), or nil without a heading.
    public var turn: Double?

    public init(from position: GeoPoint, to target: GeoPoint, heading: Double?) {
        distance = GeoMath.distance(position, target)
        bearing = GeoMath.bearing(from: position, to: target)
        turn = heading.map { GeoMath.relative(bearing: bearing, heading: $0) }
    }

    /// Close enough to count as arrived.
    public static let arrivalRadius = 25.0
    public var hasArrived: Bool { distance <= Self.arrivalRadius }
}

#if canImport(Observation)
/// The current navigation target, persisted, with change notification for sync.
/// Newest change wins: each change carries a timestamp, and remote changes older than the
/// local one are ignored (also for clearing, so a stale "cleared" can't wipe a newer target).
@MainActor
@Observable
public final class TargetStore {
    public private(set) var target: NavigationTarget?
    @ObservationIgnored public private(set) var updatedAt: Date

    /// Called after a local change (used to push it to the paired device).
    @ObservationIgnored public var onLocalChange: ((NavigationTarget?, Date) -> Void)?

    private let defaults: UserDefaults
    private enum Keys {
        static let target = "nav.target"
        static let updatedAt = "nav.updatedAt"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        target = defaults.data(forKey: Keys.target).flatMap { try? JSONDecoder().decode(NavigationTarget.self, from: $0) }
        updatedAt = Date(timeIntervalSince1970: defaults.double(forKey: Keys.updatedAt))
    }

    /// Sets (or with nil, clears) the target on this device.
    public func set(_ point: GeoPoint?, now: Date = Date()) {
        target = point.map { NavigationTarget(point: $0, setAt: now) }
        updatedAt = now
        save()
        onLocalChange?(target, now)
    }

    /// Applies a change from the paired device if it is newer than ours. Returns true if applied.
    @discardableResult
    public func applyRemote(_ remote: NavigationTarget?, updatedAt remoteAt: Date) -> Bool {
        guard remoteAt > updatedAt else { return false }
        target = remote
        updatedAt = remoteAt
        save()
        return true
    }

    private func save() {
        if let target, let data = try? JSONEncoder().encode(target) {
            defaults.set(data, forKey: Keys.target)
        } else {
            defaults.removeObject(forKey: Keys.target)
        }
        defaults.set(updatedAt.timeIntervalSince1970, forKey: Keys.updatedAt)
    }
}
#endif
