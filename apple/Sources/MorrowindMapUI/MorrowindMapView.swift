import MorrowindMapCore
import SwiftUI

/// The Morrowind-style map with fog of war. Works on iOS (drag + pinch) and watchOS (drag + Digital Crown).
/// With `onSelect`, a long press (iOS) or a tap (watchOS) picks a place, e.g. a navigation target.
public struct MorrowindMapView: View {
    @Binding var camera: MapCamera
    let fog: FogStore
    let tiles: MapTileCache
    /// Last known position, if any. Never requested by the map itself.
    let player: GeoPoint?
    let target: GeoPoint?
    let onSelect: ((GeoPoint) -> Void)?

    @State private var dragStart: MapCamera?
    @State private var pinchStart: MapCamera?
    #if os(watchOS)
    @State private var crownZoom: Double = 12
    #endif

    public init(camera: Binding<MapCamera>, fog: FogStore, tiles: MapTileCache, player: GeoPoint? = nil,
                target: GeoPoint? = nil, onSelect: ((GeoPoint) -> Void)? = nil) {
        self._camera = camera
        self.fog = fog
        self.tiles = tiles
        self.player = player
        self.target = target
        self.onSelect = onSelect
    }

    public var body: some View {
        GeometryReader { geo in
            let size = (w: Double(geo.size.width), h: Double(geo.size.height))
            let visible = camera.visibleTiles(viewSize: size)
            // Read here so loading tiles re-renders the view (the Canvas closure runs outside body).
            let _ = tiles.images.count
            ZStack {
                Canvas { ctx, _ in
                    drawTiles(visible, in: &ctx)
                    if let target { MapSymbols.drawTarget(at: camera.screenPoint(for: target, viewSize: size), in: &ctx) }
                    if let player { MapSymbols.drawPlayer(at: camera.screenPoint(for: player, viewSize: size), in: &ctx) }
                }
                vignette
            }
            .background(Color(red: 0.85, green: 0.78, blue: 0.64))
            .contentShape(Rectangle())
            .gesture(dragGesture)
            #if os(iOS)
            .simultaneousGesture(pinchGesture)
            .simultaneousGesture(selectGesture(size))
            .onTapGesture(count: 2) { location in
                withAnimation(.easeOut(duration: 0.25)) {
                    camera.zoom(to: camera.zoom + 1, anchor: (location.x - size.w / 2, location.y - size.h / 2))
                }
            }
            #else
            .onTapGesture(coordinateSpace: .local) { location in
                onSelect?(camera.geoPoint(atScreen: location.x, location.y, viewSize: size))
            }
            #endif
            .task(id: RequestKey(tiles: visible.compactMap { $0.tile.normalized }, revision: fog.revision, style: fog.style)) {
                tiles.request(visible.compactMap { $0.tile.normalized }, fog: fog)
            }
        }
        #if os(watchOS)
        .focusable()
        .digitalCrownRotation($crownZoom, from: MapCamera.minZoom, through: MapCamera.maxZoom, by: 0.05,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
        .onAppear { crownZoom = camera.zoom }
        .onChange(of: crownZoom) { _, z in camera.zoom = z }
        #endif
    }

    private struct RequestKey: Hashable {
        var tiles: [TileID]
        var revision: Int
        var style: FogStyle
    }

    private func drawTiles(_ visible: [(tile: TileID, x: Double, y: Double, side: Double)], in ctx: inout GraphicsContext) {
        for v in visible {
            guard let id = v.tile.normalized, let img = tiles.drawableImage(for: id) else { continue }
            // Slight overlap hides hairline seams between scaled tiles.
            let rect = CGRect(x: v.x, y: v.y, width: v.side, height: v.side).insetBy(dx: -0.25, dy: -0.25)
            ctx.draw(Image(decorative: img, scale: 1), in: rect)
        }
    }

    /// Darkened parchment edges.
    private var vignette: some View {
        RadialGradient(colors: [.clear, Color(red: 0.3, green: 0.2, blue: 0.1).opacity(0.35)],
                       center: .center, startRadius: 80, endRadius: 420)
            .allowsHitTesting(false)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? camera
                if dragStart == nil { dragStart = start }
                var c = camera
                c.centerX = start.centerX
                c.centerY = start.centerY
                c.pan(byPoints: value.translation.width, value.translation.height)
                camera = c
            }
            .onEnded { _ in dragStart = nil }
    }

    #if os(iOS)
    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? camera
                if pinchStart == nil { pinchStart = start }
                var c = camera
                c.zoom = start.zoom + log2(value.magnification)
                camera = c
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Long press, then lift: selects the place under the finger.
    private func selectGesture(_ size: (w: Double, h: Double)) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onEnded { value in
                guard let onSelect, case .second(true, let drag?) = value else { return }
                onSelect(camera.geoPoint(atScreen: drag.location.x, drag.location.y, viewSize: size))
            }
    }
    #endif
}
