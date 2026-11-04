import MorrowindMapCore
import MorrowindMapUI
import SwiftUI
import UniformTypeIdentifiers

@main
struct MorrowindMapApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.onLaunch() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.onForeground() }
                }
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false
    @State private var showGPXPicker = false

    private let ink = Color(red: 0.29, green: 0.22, blue: 0.15)

    var body: some View {
        ZStack(alignment: .bottom) {
            MorrowindMapView(camera: $model.camera, fog: model.fog, tiles: model.tiles, player: model.player)
                .ignoresSafeArea()

            VStack(spacing: 8) {
                if let status = model.status {
                    Text(status)
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                        .onTapGesture { model.status = nil }
                }
                HStack(spacing: 12) {
                    button("location.north.fill") { model.centerOnPlayer() }
                    button(model.isImporting ? "hourglass" : "figure.run") { Task { await model.importWorkouts() } }
                    button("square.and.arrow.down") { showGPXPicker = true }
                    button("gearshape") { showSettings = true }
                }
                Text(MapSources.attribution)
                    .font(.system(size: 8))
                    .foregroundStyle(ink.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSettings) { SettingsView(model: model, fog: model.fog) }
        .fileImporter(isPresented: $showGPXPicker, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importGPX(from: urls) } }
        }
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(ink)
                .frame(width: 48, height: 48)
                .background(Color(red: 0.86, green: 0.79, blue: 0.64), in: Circle())
                .overlay(Circle().stroke(ink, lineWidth: 1.5))
        }
    }
}

struct SettingsView: View {
    let model: AppModel
    @Bindable var fog: FogStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Fog of war") {
                    Picker("Unexplored areas", selection: $fog.style) {
                        Text("Parchment (terrain shows faintly)").tag(FogStyle.hidden)
                        Text("Grayed out").tag(FogStyle.grayed)
                    }
                    VStack(alignment: .leading) {
                        Text("Reveal radius: \(Int(fog.revealRadiusMeters)) m")
                        Slider(value: $fog.revealRadiusMeters, in: 50...1000, step: 50)
                    }
                    Text("Applies to newly imported routes. Use “Re-import all workouts” to apply it to your history.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LabeledContent("Explored cells", value: "\(fog.grid.count)")
                }
                Section {
                    Button("Re-import all workouts") { Task { await model.reimportAll() } }
                    Button("Reset explored map", role: .destructive) { confirmReset = true }
                }
                Section("Map data") {
                    Text(MapSources.attribution).font(.footnote)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Forget everything you have explored?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { fog.reset() }
            }
        }
    }
}
