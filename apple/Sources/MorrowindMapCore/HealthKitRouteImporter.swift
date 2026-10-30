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
    private var observer: HKObserverQuery?
    /// Points less accurate than this are dropped (indoor starts, tunnels).
    public var maxHorizontalAccuracy: CLLocationAccuracy = 50

    public init(anchorURL: URL? = nil) {
        self.anchorURL = anchorURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("healthkit-workout-anchor")
    }

    public func requestAuthorization() async throws {
        let types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        try await store.requestAuthorization(toShare: [], read: types)
    }

    /// Imports all workouts added since the last call (the first call imports the whole history).
    /// `handler` is called once per route with its points; return value is the number of routes.
    @discardableResult
    public func importNewWorkouts(_ handler: @escaping @Sendable ([GeoPoint]) async -> Void) async throws -> Int {
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workout()], anchor: loadAnchor())
        let result = try await descriptor.result(for: store)
        var imported = 0
        for workout in result.addedSamples {
            for route in try await routes(of: workout) {
                let points = try await locations(of: route)
                if !points.isEmpty {
                    await handler(points)
                    imported += 1
                }
            }
        }
        saveAnchor(result.newAnchor)
        return imported
    }

    /// Wakes the app when HealthKit gets a new workout (also in the background on iOS),
    /// then imports it. Requires the HealthKit background-delivery entitlement.
    public func startObserving(_ handler: @escaping @Sendable ([GeoPoint]) async -> Void) {
        guard observer == nil else { return }
        let query = HKObserverQuery(sampleType: HKObjectType.workoutType(), predicate: nil) { [weak self] _, completion, error in
            guard let self, error == nil else { completion(); return }
            Task {
                _ = try? await self.importNewWorkouts(handler)
                completion()
            }
        }
        observer = query
        store.execute(query)
        store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate) { _, _ in }
    }

    public func resetAnchor() {
        try? FileManager.default.removeItem(at: anchorURL)
    }

    private func routes(of workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        let d = HKSampleQueryDescriptor(predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))],
                                        sortDescriptors: [])
        return try await d.result(for: store)
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
    }
}
#endif
