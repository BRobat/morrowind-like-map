import MorrowindMapCore
import MorrowindMapUI
import Observation
import SwiftUI

@main
struct MorrowindMapWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView(model: model)
                .task { await model.onLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.onForeground() }
                }
        }
    }
}

/// The watch shows the same map. Explored cells arrive from the iPhone via WatchConnectivity,
/// and the watch also imports the routes it recorded itself, so a run shows up right after it ends.
@MainActor
@Observable
final class WatchModel {
    let fog = FogStore()
    let tiles: MapTileCache
    let waypoints: WaypointCache
    var camera: MapCamera
    var player: GeoPoint?

    @ObservationIgnored private let healthKit = HealthKitRouteImporter.isAvailable ? HealthKitRouteImporter() : nil
    @ObservationIgnored private let location = LastKnownLocation()
    @ObservationIgnored private var sync: FogSync?

    init() {
        let tiles = MapTileCache()
        self.tiles = tiles
        waypoints = WaypointCache(provider: tiles.provider)
        camera = MapCamera(center: GeoPoint(latitude: 50.06, longitude: 19.94), zoom: 13)
        if let start = location.point ?? fog.grid.anyExploredPoint {
            camera = MapCamera(center: start, zoom: 14)
        }
        player = location.point
        location.onChange = { [weak self] p in self?.player = p }
        sync = FogSync(store: fog)
    }

    func onLaunch() async {
        location.requestPermissionIfNeeded()
        guard let healthKit else { return }
        let fog = self.fog
        let reveal: @Sendable ([GeoPoint]) async -> Void = { points in
            await MainActor.run { _ = fog.reveal(track: points) }
        }
        do {
            try await healthKit.requestAuthorization()
            healthKit.startObserving(reveal)
            try await healthKit.importNewWorkouts(reveal)
        } catch {
            // Without Health access the watch still shows what the phone syncs.
        }
    }

    func onForeground() {
        location.refresh()
    }

    func centerOnPlayer() {
        location.refresh()
        guard let p = player else { return }
        camera = MapCamera(center: p, zoom: camera.zoom)
    }
}

struct WatchContentView: View {
    @Bindable var model: WatchModel

    var body: some View {
        NavigationStack {
            MorrowindMapView(camera: $model.camera, fog: model.fog, tiles: model.tiles,
                             waypoints: model.waypoints, player: model.player)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.centerOnPlayer() } label: { Image(systemName: "location.north.fill") }
                    }
                }
        }
    }
}
