#if canImport(CoreLocation) && !os(macOS)
import CoreLocation
import Foundation

/// Live GPS and compass, used only by the watch's minimap while it is open or while an
/// exploration is running. Unlike `LastKnownLocation`, this does turn the GPS on.
@MainActor
public final class LiveLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    public private(set) var isRunning = false

    public var onFix: ((LocationFix) -> Void)?
    /// Device heading in degrees from true north (magnetic when true north is unavailable).
    public var onHeading: ((Double) -> Void)?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .fitness
        manager.distanceFilter = 5
        manager.headingFilter = 2
    }

    public static var headingAvailable: Bool { CLLocationManager.headingAvailable() }

    public func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Starts updates. With `background`, they continue when the screen turns off or another app
    /// is shown (needs the `location` background mode); the system shows the location indicator.
    public func start(background: Bool) {
        requestPermissionIfNeeded()
        manager.allowsBackgroundLocationUpdates = background
        guard !isRunning else { return }
        isRunning = true
        manager.startUpdatingLocation()
        if Self.headingAvailable { manager.startUpdatingHeading() }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        manager.allowsBackgroundLocationUpdates = false
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    /// Heading only matters while the screen is visible.
    public func setHeadingEnabled(_ enabled: Bool) {
        guard Self.headingAvailable, isRunning else { return }
        if enabled { manager.startUpdatingHeading() } else { manager.stopUpdatingHeading() }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map { loc in
            LocationFix(point: GeoPoint(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude),
                        horizontalAccuracy: loc.horizontalAccuracy,
                        course: loc.course >= 0 ? loc.course : nil,
                        speed: loc.speed >= 0 ? loc.speed : nil,
                        timestamp: loc.timestamp)
        }
        Task { @MainActor in fixes.forEach { self.onFix?($0) } }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.onHeading?(heading) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient (e.g. kCLErrorLocationUnknown); CoreLocation keeps trying.
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {}
}
#endif
