#if canImport(CoreLocation) && !os(macOS)
import CoreLocation
import Foundation

/// Reads the position the system already has cached. It never calls `startUpdatingLocation` or
/// `requestLocation`, so it doesn't power up the GPS. Fog is revealed only from workout routes.
@MainActor
public final class LastKnownLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    public private(set) var point: GeoPoint?
    public var onChange: ((GeoPoint?) -> Void)?

    public override init() {
        super.init()
        manager.delegate = self
        refresh()
    }

    public func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Re-reads the cached fix (call when the app comes to the foreground).
    public func refresh() {
        guard manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways,
              let loc = manager.location else { return }
        point = GeoPoint(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
        onChange?(point)
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }
}
#endif
