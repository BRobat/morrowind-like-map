import MorrowindMapCore
import SwiftUI

/// The Morrowind-style map with fog of war and waypoints (towns, villages, points of interest).
/// Works on iOS (drag + pinch) and watchOS (drag + Digital Crown).
public struct MorrowindMapView: View {
    @Binding var camera: MapCamera
    let fog: FogStore
    let tiles: MapTileCache
    /// Places to draw on top of the map; nil for none. Which ones show is `fog.placesVisibility`.
    let waypoints: WaypointCache?
    /// Last known position, if any. Never requested by the map itself.
    let player: GeoPoint?

    @State private var dragStart: MapCamera?
    @State private var pinchStart: MapCamera?
    #if os(watchOS)
    @State private var crownZoom: Double = 12
    #endif

    public init(camera: Binding<MapCamera>, fog: FogStore, tiles: MapTileCache, waypoints: WaypointCache? = nil,
                player: GeoPoint? = nil) {
        self._camera = camera
        self.fog = fog
        self.tiles = tiles
        self.waypoints = waypoints
        self.player = player
    }

    public var body: some View {
        GeometryReader { geo in
            let size = (w: Double(geo.size.width), h: Double(geo.size.height))
            let visible = camera.visibleTiles(viewSize: size)
            // Read here so loading tiles re-renders the view (the Canvas closure runs outside body).
            let _ = tiles.images.count
            let dataTiles = WaypointCache.dataTiles(for: visible.compactMap { $0.tile.normalized })
            let _ = waypoints?.revision
            let placesVisibility = fog.placesVisibility
            ZStack {
                Canvas { ctx, _ in
                    drawTiles(visible, in: &ctx)
                    if placesVisibility != .off { drawWaypoints(dataTiles, visibility: placesVisibility, size: size, in: &ctx) }
                    if let player { drawPlayer(at: camera.screenPoint(for: player, viewSize: size), in: &ctx) }
                }
                vignette
            }
            .background(Color(red: 0.85, green: 0.78, blue: 0.64))
            .contentShape(Rectangle())
            .gesture(dragGesture)
            #if os(iOS)
            .simultaneousGesture(pinchGesture)
            .onTapGesture(count: 2) { location in
                withAnimation(.easeOut(duration: 0.25)) {
                    camera.zoom(to: camera.zoom + 1, anchor: (location.x - size.w / 2, location.y - size.h / 2))
                }
            }
            #endif
            .task(id: RequestKey(tiles: visible.compactMap { $0.tile.normalized }, revision: fog.revision, style: fog.style)) {
                tiles.request(visible.compactMap { $0.tile.normalized }, fog: fog)
            }
            .task(id: placesVisibility == .off ? [] : dataTiles) {
                if placesVisibility != .off { waypoints?.request(dataTiles) }
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

    /// Places inside or just outside the view, filtered by zoom and discovery, then laid out without overlaps.
    private func drawWaypoints(_ dataTiles: [TileID], visibility: WaypointVisibility, size: (w: Double, h: Double),
                               in ctx: inout GraphicsContext) {
        guard let waypoints else { return }
        let zoom = camera.zoom
        // A margin keeps labels from popping in right at the edge while panning.
        let margin = 40.0
        let grid = fog.grid, revision = fog.revision
        var candidates: [WaypointLayout.Candidate] = []
        for w in waypoints.waypoints(in: dataTiles) where w.isVisible(atZoom: zoom) {
            let p = camera.screenPoint(for: w.location, viewSize: size)
            guard p.x > -margin, p.y > -margin, p.x < size.w + margin, p.y < size.h + margin else { continue }
            let discovered = waypoints.isDiscovered(w, fog: grid, revision: revision)
            guard visibility.shows(w, discovered: discovered) else { continue }
            candidates.append(WaypointLayout.Candidate(waypoint: w, x: p.x, y: p.y, discovered: discovered))
        }
        WaypointOverlay.draw(candidates, zoom: zoom, in: &ctx)
    }

    /// A small arrowhead in dark red ink, as used for the player on the in-game map.
    private func drawPlayer(at p: (x: Double, y: Double), in ctx: inout GraphicsContext) {
        var path = Path()
        path.move(to: CGPoint(x: p.x, y: p.y - 8))
        path.addLine(to: CGPoint(x: p.x + 6, y: p.y + 6))
        path.addLine(to: CGPoint(x: p.x, y: p.y + 2))
        path.addLine(to: CGPoint(x: p.x - 6, y: p.y + 6))
        path.closeSubpath()
        ctx.fill(path, with: .color(Color(red: 0.55, green: 0.12, blue: 0.08)))
        ctx.stroke(path, with: .color(Color(red: 0.25, green: 0.18, blue: 0.1)), lineWidth: 1)
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
    #endif
}
