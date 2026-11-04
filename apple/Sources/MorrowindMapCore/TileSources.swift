import Foundation

/// Free, key-less map data sources. See shared/data-sources.md for licences and attribution.
public enum MapSources {
    /// AWS Terrain Tiles (Mapzen Terrarium encoding), open data on the AWS Registry of Open Data.
    public static let terrainURLTemplate = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
    public static let terrainMaxZoom = 15

    /// OpenFreeMap planet vector tiles (OpenMapTiles schema, data © OpenStreetMap contributors).
    /// The TileJSON names the current versioned tile URL, so we resolve it at runtime.
    public static let waterTileJSON = URL(string: "https://tiles.openfreemap.org/planet")!
    /// Max zoom of the vector tiles. The same tiles hold water, places and POIs.
    public static let vectorMaxZoom = 14

    public static let attribution = "Elevation: AWS Terrain Tiles (Mapzen, SRTM, GMTED, ETOPO1 and others) · Water & places: © OpenStreetMap contributors, OpenMapTiles, OpenFreeMap"

    public static func url(template: String, tile: TileID) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: String(tile.z))
            .replacingOccurrences(of: "{x}", with: String(tile.x))
            .replacingOccurrences(of: "{y}", with: String(tile.y)))
    }
}

/// The parts of a TileJSON document we need.
struct TileJSON: Decodable {
    var tiles: [String]
    var maxzoom: Int?
}
