import MorrowindMapCore
import SwiftUI

/// The Morrowind-style map with fog of war. Works on iOS (drag + pinch) and watchOS (drag + Digital Crown).
public struct MorrowindMapView: View {
    @Binding var camera: MapCamera
    let fog: FogStore
    let tiles: MapTileCache
    /// Last known position, if any. Never requested by the map itself.
    let player: GeoPoint?

    @State private var dragStart: MapCamera?
    @State private var pinchStart: MapCamera?
    #if os(watchOS)
    @State private var crownZoom: Double = 12
    #endif

    public init(camera: Binding<MapCamera>, fog: FogStore, tiles: MapTileCache, player: GeoPoint? = nil) {
        self._camera = camera
        self.fog = fog
        self.tiles = tiles
        self.player = player
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
                tiles.request(visible.compactMap { $0.tile.normalized }, fog: fog.grid, revision: fog.revision, style: fog.style)
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
            guard let id = v.tile.normalized, let found = tiles.image(for: id) else { continue }
            let img = found.crop.width < Double(found.image.width) ? found.image.cropping(to: found.crop) ?? found.image : found.image
            // Slight overlap hides hairline seams between scaled tiles.
            let rect = CGRect(x: v.x, y: v.y, width: v.side, height: v.side).insetBy(dx: -0.25, dy: -0.25)
            ctx.draw(Image(decorative: img, scale: 1), in: rect)
        }
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
