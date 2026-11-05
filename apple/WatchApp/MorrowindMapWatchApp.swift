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
    let tiles = MapTileCache()
    var camera: MapCamera
    var player: GeoPoint?

    @ObservationIgnored private let healthKit = HealthKitRouteImporter.isAvailable ? HealthKitRouteImporter() : nil
    @ObservationIgnored private let location = LastKnownLocation()
    @ObservationIgnored private var sync: FogSync?

    init() {
        camera = MapCamera(center: GeoPoint(latitude: 50.06, longitude: 19.94), zoom: 13)
        if let start = location.point ?? fog.grid.anyExploredPoint {
            camera = MapCamera(center: start, zoom: 14)
        }
        player = location.point
        location.onChange = { [weak self] p in self?.player = p }
        sync = FogSync(store: fog)
        // Registered at launch so a background wake-up for a new workout isn't lost.
        if healthKit?.hasImportedBefore == true { healthKit?.startObserving(reveal) }
    }

    private var reveal: @Sendable ([[GeoPoint]]) async -> Void {
        let fog = self.fog
        return { routes in _ = await fog.reveal(tracks: routes) }
    }

    func onLaunch() async {
        location.requestPermissionIfNeeded()
        guard let healthKit else { return }
        do {
            try await healthKit.requestAuthorization()
            // Import before observing: the observer fires once on start and must see the saved anchor.
            try await healthKit.importNewWorkouts(reveal)
            healthKit.startObserving(reveal)
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
            MorrowindMapView(camera: $model.camera, fog: model.fog, tiles: model.tiles, player: model.player)
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.centerOnPlayer() } label: { Image(systemName: "location.north.fill") }
                    }
                }
        }
    }
}
