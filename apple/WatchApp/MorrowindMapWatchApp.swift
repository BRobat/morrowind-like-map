import MorrowindMapCore
import MorrowindMapUI
import Observation
import SwiftUI
import WatchKit

@main
struct MorrowindMapWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView(model: model)
                .task { await model.onLaunch() }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    model.setVisible(phase == .active)
                }
        }
    }
}

/// The watch is a minimap: a fixed-scale view around you with a compass ring that points to the
/// target. While the app is on screen, or while an exploration runs in the background, it follows
/// live GPS, reveals the fog as you move, and sends the points to the iPhone so the big map
/// unlocks too. Explored cells and workout routes also sync as before.
@MainActor
@Observable
final class WatchModel {
    let fog = FogStore()
    let tiles = MapTileCache()
    let targets = TargetStore()
    /// Camera of the full map used to pick a target.
    var camera: MapCamera
    var player: GeoPoint?
    /// Compass heading, when the watch has a compass.
    var heading: Double?
    /// Direction of travel from GPS, used when there is no compass.
    var course: Double?

    /// Exploration keeps GPS on in the background (screen off, other apps).
    private(set) var isExploring = false
    /// Distance and newly revealed cells of the current exploration.
    private(set) var exploredMeters = 0.0
    private(set) var newCells = 0

    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private let healthKit = HealthKitRouteImporter.isAvailable ? HealthKitRouteImporter() : nil
    @ObservationIgnored private let lastKnown = LastKnownLocation()
    @ObservationIgnored private let live = LiveLocation()
    @ObservationIgnored private var sync: FogSync?
    @ObservationIgnored private var filter = TrackFilter()
    @ObservationIgnored private var chunker = TrackChunker()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// The target we already buzzed for, so arrival plays once per approach.
    @ObservationIgnored private var arrivedAt: Date?

    init() {
        camera = MapCamera(center: GeoPoint(latitude: 50.06, longitude: 19.94), zoom: 13)
        if let start = lastKnown.point ?? fog.grid.anyExploredPoint {
            camera = MapCamera(center: start, zoom: 13)
        }
        player = lastKnown.point
        lastKnown.onChange = { [weak self] p in
            guard let self, !self.live.isRunning, let p else { return }
            self.player = p
        }
        live.onFix = { [weak self] fix in self?.handle(fix) }
        live.onHeading = { [weak self] h in self?.heading = h }
        sync = FogSync(store: fog, target: targets)
        // Registered at launch so a background wake-up for a new workout isn't lost.
        if healthKit?.hasImportedBefore == true { healthKit?.startObserving(reveal) }
    }

    private var reveal: @Sendable ([[GeoPoint]]) async -> Void {
        let fog = self.fog
        return { routes in _ = await fog.reveal(tracks: routes) }
    }

    func onLaunch() async {
        live.requestPermissionIfNeeded()
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

    // MARK: - Tracking

    /// The way the player faces: compass first, otherwise direction of travel.
    var facing: Double? { heading ?? course }

    var guidance: TargetGuidance? {
        guard let player, let target = targets.target else { return nil }
        return TargetGuidance(from: player, to: target.point, heading: facing)
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible { lastKnown.refresh() }
        updateTracking()
    }

    func toggleExploring() {
        isExploring.toggle()
        if isExploring {
            exploredMeters = 0
            newCells = 0
            WKInterfaceDevice.current().play(.start)
        } else {
            WKInterfaceDevice.current().play(.stop)
        }
        updateTracking()
    }

    private func updateTracking() {
        if isVisible || isExploring {
            live.start(background: isExploring)
            live.setHeadingEnabled(isVisible)
            if flushTask == nil { flushTask = Task { [weak self] in await self?.flushLoop() } }
        } else {
            live.stop()
            flushTask?.cancel()
            flushTask = nil
            endSegment()
        }
    }

    /// Sends waiting points about once a minute even when standing still.
    private func flushLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if chunker.due(at: Date()) { send(chunker.flush()) }
        }
    }

    private func handle(_ fix: LocationFix) {
        player = fix.point
        if let c = fix.course, (fix.speed ?? 0) > 0.7 { course = c }
        switch filter.evaluate(fix) {
        case .reject:
            break
        case .start:
            newCells += fog.reveal(track: [fix.point], broadcast: false)
            send(chunker.start(fix.point, at: fix.timestamp))
        case .extend(let from):
            exploredMeters += GeoMath.distance(from, fix.point)
            newCells += fog.reveal(track: [from, fix.point], broadcast: false)
            send(chunker.extend(fix.point, at: fix.timestamp))
        }
        checkArrival()
    }

    /// Sends what is left and makes the next fix start a fresh line.
    private func endSegment() {
        send(chunker.flush())
        filter.reset()
    }

    private func send(_ chunk: TrackChunk?) {
        if let chunk { sync?.send(chunk) }
    }

    private func checkArrival() {
        guard let target = targets.target, let g = guidance else { return }
        if g.hasArrived, arrivedAt != target.setAt {
            arrivedAt = target.setAt
            WKInterfaceDevice.current().play(.success)
        } else if g.distance > TargetGuidance.arrivalRadius * 3, arrivedAt == target.setAt {
            arrivedAt = nil // walked away again: buzz on the next arrival
        }
    }

    func setTarget(_ p: GeoPoint?) {
        targets.set(p)
        arrivedAt = nil
        WKInterfaceDevice.current().play(.click)
    }
}

// MARK: - Views

struct WatchContentView: View {
    @Bindable var model: WatchModel
    @State private var showMap = false
    @AppStorage("minimap.northUp") private var northUp = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Not drawn while the full map is shown: both share one tile cache.
                if let p = model.player, !showMap {
                    MinimapView(fog: model.fog, tiles: model.tiles, position: p, facing: model.facing,
                                northUp: northUp, target: model.targets.target?.point)
                        .onTapGesture { northUp.toggle() }
                } else if model.player == nil {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text("Finding your position…").font(.footnote).multilineTextAlignment(.center)
                    }
                }
                VStack {
                    Spacer()
                    StatusLine(model: model)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showMap = true } label: { Image(systemName: "map") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.toggleExploring() } label: {
                        Image(systemName: model.isExploring ? "stop.fill" : "figure.walk")
                    }
                    .tint(model.isExploring ? Color.red : nil)
                    .accessibilityLabel(model.isExploring ? "Stop exploring" : "Start exploring")
                }
            }
            .navigationDestination(isPresented: $showMap) {
                TargetPickerView(model: model)
            }
        }
    }
}

/// Distance and direction to the target, and the running exploration.
private struct StatusLine: View {
    let model: WatchModel

    var body: some View {
        let g = model.guidance
        if g != nil || model.isExploring {
            HStack(spacing: 6) {
                if model.isExploring {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(format(model.exploredMeters))
                }
                if let g {
                    if g.hasArrived {
                        Text("Arrived")
                    } else {
                        if let turn = g.turn {
                            Image(systemName: "location.north.fill").rotationEffect(.degrees(turn))
                        }
                        Text("\(format(g.distance)) \(GeoMath.compassName(g.bearing))")
                    }
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .serif))
            .foregroundStyle(MapSymbols.ink)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(MapSymbols.parchment, in: Capsule())
            .overlay(Capsule().stroke(MapSymbols.ink, lineWidth: 1))
            .padding(.bottom, 4)
        }
    }

    private func format(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }
}

/// The full map (drag to pan, crown to zoom). Tap a place to make it the target.
struct TargetPickerView: View {
    @Bindable var model: WatchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MorrowindMapView(camera: $model.camera, fog: model.fog, tiles: model.tiles, player: model.player,
                         target: model.targets.target?.point) { p in
            model.setTarget(p)
            dismiss()
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            Text("Tap to set target")
                .font(.system(size: 11, design: .serif))
                .foregroundStyle(MapSymbols.ink)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(MapSymbols.parchment.opacity(0.85), in: Capsule())
                .allowsHitTesting(false)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.targets.target != nil {
                    Button { model.setTarget(nil) } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Clear target")
                }
            }
        }
        .onAppear {
            if let p = model.player { model.camera = MapCamera(center: p, zoom: model.camera.zoom) }
        }
    }
}
