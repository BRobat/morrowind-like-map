# Map data sources

Both sources are free and need no API key or account. Tiles are cached permanently on the device, so
each area is downloaded once and then works offline.

## Elevation: AWS Terrain Tiles (Terrarium)

- URL: `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png`
- Zoom 0–15, 256 px PNG, Terrarium encoding (`R·256 + G + B/256 − 32768` meters). Ocean bathymetry is included.
- Hosted on the [AWS Registry of Open Data](https://registry.opendata.aws/terrain-tiles/).
- Attribution: *Mapzen Terrain Tiles; data from SRTM, GMTED2010, ETOPO1, NED, and other sources*
  (full list: https://github.com/tilezen/joerd/blob/master/docs/attribution.md).

## Water: OpenFreeMap vector tiles

- TileJSON: `https://tiles.openfreemap.org/planet`. Read `tiles[0]` for the current versioned URL
  template (`…/planet/<version>/{z}/{x}/{y}.pbf`).
- Zoom 0–14, Mapbox Vector Tile (MVT) format, [OpenMapTiles schema](https://openmaptiles.org/schema/).
  We use only the `water` (polygons) and `waterway` (lines) layers.
- No usage limits or registration ([openfreemap.org](https://openfreemap.org)). Send a descriptive
  `User-Agent`.
- Attribution: *© OpenStreetMap contributors, OpenMapTiles, OpenFreeMap*.

## Required on-screen attribution

> Elevation: AWS Terrain Tiles (Mapzen, SRTM, GMTED, ETOPO1 and others) · Water: © OpenStreetMap
> contributors, OpenMapTiles, OpenFreeMap

## Alternatives if a source goes away

- Elevation: self-host Terrarium tiles generated from Copernicus GLO-30.
- Water: self-host an OpenMapTiles/Planetiler `.pmtiles` extract, or use the OSM water polygons from
  osmdata.openstreetmap.de, pre-tiled.
