import Foundation

/// Mirrors `shared/palette.json`. The bundled copy in Resources/ must stay identical
/// to the shared one (a unit test checks this).
public struct Palette: Codable, Sendable {
    public struct LandStop: Codable, Sendable {
        public var elevation: Double
        public var color: String
    }

    public struct Water: Codable, Sendable {
        public var shallow: String
        public var deep: String
        public var deepAtMeters: Double
        public var shoreline: String
        public var shorelineWidthPx: Int
    }

    public struct Hillshade: Codable, Sendable {
        public var azimuthDegrees: Double
        public var altitudeDegrees: Double
        public var exaggeration: Double
        public var strength: Double
        public var minFactor: Double
        public var maxFactor: Double
        public var lowZoomBoostBelow: Int
        public var lowZoomBoostPerLevel: Double
    }

    public struct Parchment: Codable, Sendable {
        public var noiseAmplitude: Double
    }

    /// Roads are an ink layer that only shows in explored areas (see render-spec.md, step 7).
    public struct Roads: Codable, Sendable {
        public var color: String
        /// Multiplies every road class's own opacity.
        public var opacity: Double
    }

    public struct Fog: Codable, Sendable {
        public var hiddenColor: String
        /// How much of the terrain the `hidden` fog covers: 1 = solid parchment, lower lets the map show through.
        public var hiddenOpacity: Double
        public var grayedDesaturation: Double
        public var grayedDarken: Double
        public var edgeSoftnessPx: Double
    }

    public var version: Int
    public var land: [LandStop]
    public var water: Water
    public var hillshade: Hillshade
    public var parchment: Parchment
    public var roads: Roads
    public var fog: Fog

    public static let standard: Palette = {
        guard let url = MorrowindMapCoreResources.paletteURL,
              let data = try? Data(contentsOf: url),
              let palette = try? JSONDecoder().decode(Palette.self, from: data)
        else { fatalError("palette.json missing or invalid in MorrowindMapCore resources") }
        return palette
    }()
}

public enum MorrowindMapCoreResources {
    public static var paletteURL: URL? { Bundle.module.url(forResource: "palette", withExtension: "json") }
}

/// Palette with colors parsed once, for the hot rendering loops.
struct ResolvedPalette {
    let landElevations: [Double]
    let landColors: [RGB]
    let waterShallow: RGB
    let waterDeep: RGB
    let deepAtMeters: Double
    let shoreline: RGB
    let shorelineWidth: Int
    let hillshade: Palette.Hillshade
    let noiseAmplitude: Double
    let fogHidden: RGB
    let roadColor: RGB
    let roadOpacity: Double
    let fog: Palette.Fog

    init(_ p: Palette) {
        landElevations = p.land.map(\.elevation)
        landColors = p.land.map { RGB(hex: $0.color) ?? RGB(200, 180, 140) }
        waterShallow = RGB(hex: p.water.shallow) ?? RGB(110, 140, 150)
        waterDeep = RGB(hex: p.water.deep) ?? RGB(77, 107, 120)
        deepAtMeters = p.water.deepAtMeters
        shoreline = RGB(hex: p.water.shoreline) ?? RGB(75, 58, 40)
        shorelineWidth = p.water.shorelineWidthPx
        hillshade = p.hillshade
        noiseAmplitude = p.parchment.noiseAmplitude
        fogHidden = RGB(hex: p.fog.hiddenColor) ?? RGB(216, 200, 162)
        roadColor = RGB(hex: p.roads.color) ?? RGB(92, 68, 48)
        roadOpacity = p.roads.opacity
        fog = p.fog
    }

    func landColor(elevation e: Double) -> RGB {
        if e <= landElevations[0] { return landColors[0] }
        for i in 1..<landElevations.count where e < landElevations[i] {
            let t = (e - landElevations[i - 1]) / (landElevations[i] - landElevations[i - 1])
            return RGB.lerp(landColors[i - 1], landColors[i], t)
        }
        return landColors[landColors.count - 1]
    }

    func waterColor(depth: Double) -> RGB {
        RGB.lerp(waterShallow, waterDeep, min(max(depth / deepAtMeters, 0), 1))
    }
}

/// Deterministic per-pixel grain so tiles line up seamlessly. Same formula as tools/preview.py.
@inline(__always)
func hashNoise(_ x: UInt32, _ y: UInt32) -> Double {
    var h = x &* 374_761_393 &+ y &* 668_265_263
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h = h ^ (h >> 16)
    return Double(h & 0xFFFF) / 65535.0
}
