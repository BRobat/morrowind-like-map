import MorrowindMapCore
import SwiftUI

/// A round minimap at a fixed scale, always centred on the player, with a compass ring.
/// The target shows on the ring in its direction (like the quest marker on the in-game compass)
/// and on the map itself once it is close enough. No gestures: it only follows the player.
public struct MinimapView: View {
    /// z15 is about 3 m per point at 50°N, so a watch shows a few hundred meters around you.
    public static let zoom = 15.0

    let fog: FogStore
    let tiles: MapTileCache
    let position: GeoPoint
    /// The way the player faces (compass heading, or direction of travel), degrees from north.
    let facing: Double?
    /// When false and `facing` is known, the map turns so that the facing direction is up.
    let northUp: Bool
    let target: GeoPoint?

    private let ringWidth = 14.0

    public init(fog: FogStore, tiles: MapTileCache, position: GeoPoint, facing: Double?, northUp: Bool, target: GeoPoint?) {
        self.fog = fog
        self.tiles = tiles
        self.position = position
        self.facing = facing
        self.northUp = northUp
        self.target = target
    }

    public var body: some View {
        GeometryReader { geo in
            let side = Double(min(geo.size.width, geo.size.height))
            let size = (w: side, h: side)
            let camera = MapCamera(center: position, zoom: Self.zoom)
            // A circle turned about its centre stays inside the unturned square, so the
            // unrotated tile set covers every rotation.
            let visible = camera.visibleTiles(viewSize: size)
            let ids = visible.compactMap { $0.tile.normalized }
            let _ = tiles.images.count
            Canvas { ctx, _ in
                draw(in: &ctx, side: side, camera: camera, visible: visible)
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: RequestKey(tiles: ids, revision: fog.revision, style: fog.style)) {
                tiles.request(ids, fog: fog)
            }
        }
    }

    private struct RequestKey: Hashable {
        var tiles: [TileID]
        var revision: Int
        var style: FogStyle
    }

    /// Screen rotation of the map, degrees clockwise.
    private var rotation: Double { northUp ? 0 : -(facing ?? 0) }

    private func draw(in ctx: inout GraphicsContext, side: Double, camera: MapCamera,
                      visible: [(tile: TileID, x: Double, y: Double, side: Double)]) {
        let c = CGPoint(x: side / 2, y: side / 2)
        let radius = side / 2 - ringWidth
        let disc = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))

        // Map, turned and clipped to the disc.
        var map = ctx
        map.clip(to: disc)
        map.fill(disc, with: .color(MapSymbols.parchment))
        map.translateBy(x: c.x, y: c.y)
        map.rotate(by: .degrees(rotation))
        map.translateBy(x: -c.x, y: -c.y)
        for v in visible {
            guard let id = v.tile.normalized, let img = tiles.drawableImage(for: id) else { continue }
            let rect = CGRect(x: v.x, y: v.y, width: v.side, height: v.side).insetBy(dx: -0.25, dy: -0.25)
            map.draw(Image(decorative: img, scale: 1), in: rect)
        }
        map.fill(disc, with: .radialGradient(Gradient(colors: [.clear, MapSymbols.ink.opacity(0.35)]),
                                             center: c, startRadius: radius * 0.6, endRadius: radius))

        // Target on the map, when it is inside the disc.
        var targetBearing: Double?
        if let target {
            targetBearing = GeoMath.bearing(from: position, to: target)
            let p = camera.screenPoint(for: target, viewSize: (side, side))
            let turned = rotate((p.x, p.y), around: c, degrees: rotation)
            if hypot(turned.x - Double(c.x), turned.y - Double(c.y)) < radius - 4 {
                MapSymbols.drawTarget(at: turned, in: &ctx)
            }
        }

        // Player at the centre.
        MapSymbols.drawPlayer(at: (Double(c.x), Double(c.y)), degrees: (facing ?? 0) + rotation, in: &ctx)

        drawRing(in: &ctx, center: c, radius: radius, targetBearing: targetBearing)
    }

    private func drawRing(in ctx: inout GraphicsContext, center c: CGPoint, radius: Double, targetBearing: Double?) {
        let mid = radius + ringWidth / 2
        let ring = Path(ellipseIn: CGRect(x: c.x - mid, y: c.y - mid, width: mid * 2, height: mid * 2))
        ctx.stroke(ring, with: .color(MapSymbols.parchmentDark), lineWidth: ringWidth)
        for r in [radius, radius + ringWidth] {
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                       with: .color(MapSymbols.ink), lineWidth: 1)
        }
        // Ticks every 30°, letters on the cardinal points.
        for deg in stride(from: 0.0, to: 360, by: 30) {
            let screen = deg + rotation
            if deg.truncatingRemainder(dividingBy: 90) == 0 {
                let label = ["N", "E", "S", "W"][Int(deg / 90)]
                let text = Text(label)
                    .font(.system(size: 10, weight: .bold, design: .serif))
                    .foregroundColor(label == "N" ? MapSymbols.playerRed : MapSymbols.ink)
                ctx.draw(text, at: MapSymbols.onCircle(c, radius: mid, degrees: screen))
            } else {
                var tick = Path()
                tick.move(to: MapSymbols.onCircle(c, radius: mid - 3, degrees: screen))
                tick.addLine(to: MapSymbols.onCircle(c, radius: mid + 3, degrees: screen))
                ctx.stroke(tick, with: .color(MapSymbols.ink.opacity(0.7)), lineWidth: 1)
            }
        }
        // Target direction on the ring: an arrowhead pointing outwards.
        if let targetBearing {
            let a = targetBearing + rotation
            var arrow = Path()
            arrow.move(to: MapSymbols.onCircle(c, radius: radius + ringWidth + 1, degrees: a))
            arrow.addLine(to: MapSymbols.onCircle(c, radius: radius - 3, degrees: a - 9))
            arrow.addLine(to: MapSymbols.onCircle(c, radius: radius + 2, degrees: a))
            arrow.addLine(to: MapSymbols.onCircle(c, radius: radius - 3, degrees: a + 9))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(MapSymbols.markerGold))
            ctx.stroke(arrow, with: .color(MapSymbols.ink), lineWidth: 1.2)
        }
    }

    private func rotate(_ p: (x: Double, y: Double), around c: CGPoint, degrees: Double) -> (x: Double, y: Double) {
        let a = degrees * .pi / 180
        let cx = Double(c.x), cy = Double(c.y)
        let dx = p.x - cx, dy = p.y - cy
        return (cx + dx * cos(a) - dy * sin(a), cy + dx * sin(a) + dy * cos(a))
    }
}
