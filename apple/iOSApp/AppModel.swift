import Foundation
import MorrowindMapCore
import MorrowindMapUI
import Observation

@MainActor
@Observable
final class AppModel {
    let fog = FogStore()
    let tiles = MapTileCache()
    var camera: MapCamera
    var player: GeoPoint?
    var status: String?
    var isImporting = false

    @ObservationIgnored private let healthKit = HealthKitRouteImporter.isAvailable ? HealthKitRouteImporter() : nil
    @ObservationIgnored private let location = LastKnownLocation()
    @ObservationIgnored private var sync: FogSync?

    init() {
        camera = MapCamera(center: GeoPoint(latitude: 50.06, longitude: 19.94), zoom: 12)
        if let start = location.point ?? fog.grid.anyExploredPoint {
            camera = MapCamera(center: start, zoom: 13)
        }
        player = location.point
        location.onChange = { [weak self] p in self?.player = p }
        sync = FogSync(store: fog)
        // The model is created at process launch, also when HealthKit wakes the app in the
        // background, where no view appears. Register the observer here so that wake-up isn't lost.
        if healthKit?.hasImportedBefore == true { startObserving() }
    }

    func onLaunch() async {
        location.requestPermissionIfNeeded()
        guard let healthKit else { return }
        do {
            try await healthKit.requestAuthorization()
            // Import first: the observer fires once on start, and must see the saved anchor
            // or it would re-import the whole history in parallel.
            await importWorkouts()
            startObserving()
        } catch {
            status = "Health access failed: \(error.localizedDescription)"
        }
    }

    private func startObserving() {
        let fog = self.fog
        healthKit?.startObserving { routes in
            _ = await fog.reveal(tracks: routes)
        }
    }

    func onForeground() {
        location.refresh()
    }

    func importWorkouts() async {
        guard let healthKit, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let fog = self.fog
        do {
            let before = fog.grid.count
            let n = try await healthKit.importNewWorkouts { routes in
                _ = await fog.reveal(tracks: routes)
            }
            status = n == 0 ? "No new workouts" : "Imported \(n) routes, \(fog.grid.count - before) new cells explored"
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Re-reads every workout (e.g. after changing the reveal radius).
    func reimportAll() async {
        healthKit?.resetAnchor()
        fog.reset()
        await importWorkouts()
    }

    func importGPX(from urls: [URL]) async {
        var tracks: [[GeoPoint]] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            tracks += GPXParser.tracks(from: data)
        }
        let added = await fog.reveal(tracks: tracks)
        status = "Imported \(tracks.count) GPX tracks, \(added) new cells explored"
    }

    func centerOnPlayer() {
        location.refresh()
        guard let p = player else { return }
        camera = MapCamera(center: p, zoom: max(camera.zoom, 13))
    }
}
