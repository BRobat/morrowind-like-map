#if canImport(HealthKit) && !os(macOS)
import CoreLocation
import Foundation
import HealthKit

/// Reads GPS routes that workouts have already recorded (Apple Watch Workout app, Strava,
/// Nike Run Club, ... anything writing HKWorkoutRoute). The app never starts GPS itself,
/// so revealing the map costs no extra battery.
public final class HealthKitRouteImporter: @unchecked Sendable {
    public static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private let store = HKHealthStore()
    private let anchorURL: URL
    private let legacyAnchorURL: URL
    private var observers: [HKObserverQuery] = []
    private let gate = ImportGate()
    /// Points less accurate than this are dropped (indoor starts, tunnels).
    public var maxHorizontalAccuracy: CLLocationAccuracy = 50

    public init(anchorURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // The anchor tracks route samples, not workouts (see `importNewWorkouts`). Versions that anchored on
        // workouts used another file; starting a fresh anchor re-reads the history once and picks up the
        // routes that were skipped then.
        self.anchorURL = anchorURL ?? support.appendingPathComponent("healthkit-route-anchor")
        self.legacyAnchorURL = support.appendingPathComponent("healthkit-workout-anchor")
    }

    public func requestAuthorization() async throws {
        let types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        try await store.requestAuthorization(toShare: [], read: types)
    }

    /// Routes handed to the handler at once: few enough that a long first import still shows
    /// progress, many enough that saving and syncing the fog doesn't happen per route.
    public var batchSize = 50

    /// Imports every workout route added since the last call (the first call imports the whole history),
    /// whatever the activity: runs, walks, hikes, rides, ...
    /// `handler` is called with batches of routes (each a list of points); return value is the number of routes.
    ///
    /// The anchor is on route samples rather than workouts on purpose: a route is saved as its own sample,
    /// often after its workout (always for workouts synced from the Watch, and later still for long hikes
    /// and walks). Anchoring on workouts skipped those for good, because the workout was already past the
    /// anchor by the time its route arrived.
    @discardableResult
    public func importNewWorkouts(_ handler: @escaping @Sendable ([[GeoPoint]]) async -> Void) async throws -> Int {
        // Observer wake-ups and manual imports can overlap; run them one after another so the anchor stays consistent.
        try await gate.run { try await self.importNewRoutes(handler) }
    }

    private func importNewRoutes(_ handler: @escaping @Sendable ([[GeoPoint]]) async -> Void) async throws -> Int {
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workoutRoute()], anchor: loadAnchor())
        let result = try await descriptor.result(for: store)
        var imported = 0
        var batch: [[GeoPoint]] = []
        for route in result.addedSamples {
            let points = try await locations(of: route)
            guard !points.isEmpty else { continue }
            batch.append(points)
            imported += 1
            if batch.count >= batchSize {
                await handler(batch)
                batch.removeAll()
            }
        }
        if !batch.isEmpty { await handler(batch) }
        saveAnchor(result.newAnchor)
        return imported
    }

    /// Wakes the app when HealthKit gets a new workout (also in the background on iOS),
    /// then imports it. Requires the HealthKit background-delivery entitlement.
    /// Watches both workouts and routes: the route of a workout can arrive after the workout itself.
    public func startObserving(_ handler: @escaping @Sendable ([[GeoPoint]]) async -> Void) {
        guard observers.isEmpty else { return }
        let types: [HKSampleType] = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
                guard let self, error == nil else { completion(); return }
                Task {
                    _ = try? await self.importNewWorkouts(handler)
                    completion()
                }
            }
            observers.append(query)
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    /// True once a full import has finished, which also means Health access was requested before.
    public var hasImportedBefore: Bool {
        FileManager.default.fileExists(atPath: anchorURL.path)
    }

    public func resetAnchor() {
        try? FileManager.default.removeItem(at: anchorURL)
        try? FileManager.default.removeItem(at: legacyAnchorURL)
    }

    private func locations(of route: HKWorkoutRoute) async throws -> [GeoPoint] {
        var points: [GeoPoint] = []
        for try await loc in HKWorkoutRouteQueryDescriptor(route).results(for: store)
        where loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= maxHorizontalAccuracy {
            points.append(GeoPoint(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude))
        }
        return points
    }

    private func loadAnchor() -> HKQueryAnchor? {
        guard let data = try? Data(contentsOf: anchorURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        try? FileManager.default.createDirectory(at: anchorURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: anchorURL, options: .atomic)
        // The workout-based anchor of older versions is no longer used.
        try? FileManager.default.removeItem(at: legacyAnchorURL)
    }
}

/// Runs async operations strictly one after another.
private actor ImportGate {
    private var last: Task<Int, Error>?

    func run(_ operation: @escaping @Sendable () async throws -> Int) async throws -> Int {
        let previous = last
        let task = Task<Int, Error> {
            _ = try? await previous?.value
            return try await operation()
        }
        last = task
        return try await task.value
    }
}
#endif
