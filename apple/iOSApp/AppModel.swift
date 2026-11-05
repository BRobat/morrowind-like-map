import Foundation
import MorrowindMapCore
import MorrowindMapUI
import Observation

@MainActor
@Observable
final class AppModel {
    let fog = FogStore()
    let tiles = MapTileCache()
    /// Navigation target, shared with the watch's compass.
    let targets = TargetStore()
    var camera: MapCamera
    var player: GeoPoint?
    var status: String?
    var isImporting = false

    @ObservationIgnored private let healthKit = HealthKitRouteImporter.isAvailable ? HealthKitRouteImporter() : nil
    @ObservationIgnored private let location = LastKnownLocation()
    @ObservationIgnored private var sync: FogSync?
    /// Tracks the watch logged live while exploring, kept so a full re-import can reveal them again.
    @ObservationIgnored private let watchTracks = RecordedTrackLog()

    init() {
        camera = MapCamera(center: GeoPoint(latitude: 50.06, longitude: 19.94), zoom: 12)
        if let start = location.point ?? fog.grid.anyExploredPoint {
            camera = MapCamera(center: start, zoom: 13)
        }
        player = location.point
        location.onChange = { [weak self] p in self?.player = p }
        sync = FogSync(store: fog, target: targets)
        sync?.onTrackChunk = { [weak self] chunk in self?.receiveWatchTrack(chunk) }
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

    /// Points the watch logged while exploring. Saved first, then revealed. Not pushed back to
    /// the watch: it has already revealed the same points itself.
    private func receiveWatchTrack(_ chunk: TrackChunk) {
        watchTracks.append(chunk)
        let fog = self.fog
        Task {
            let added = await fog.reveal(tracks: [chunk.points], broadcast: false)
            if added > 0 { self.status = "Watch explored \(added) new cells" }
        }
    }

    func setTarget(_ p: GeoPoint?) {
        targets.set(p)
        status = p == nil ? "Target cleared" : "Target set. Your watch's compass points to it."
    }

    var guidance: TargetGuidance? {
        guard let player, let target = targets.target else { return nil }
        return TargetGuidance(from: player, to: target.point, heading: nil)
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

    /// Re-reads every workout and every track logged on the watch (e.g. after changing the reveal radius).
    func reimportAll() async {
        healthKit?.resetAnchor()
        fog.reset()
        await importWorkouts()
        let tracks = watchTracks.allTracks()
        if !tracks.isEmpty { await fog.reveal(tracks: tracks) }
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
