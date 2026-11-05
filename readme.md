# Morrowind-like map

A real-world map drawn like the in-game map from *The Elder Scrolls III: Morrowind*: parchment-brown
relief from a heightmap and muted blue water, with no roads or labels. On top sits a **fog of war**:
the map stays hidden until you have been there. Places are revealed from GPS routes your watch
**already records** during runs, hikes and rides, and from the watch app's **minimap**, which
follows you live and logs where you walk. A compass on the watch points to a target you pick on
the map, like the quest marker in the game.

| Terrain (z11, Alps) | Fog: hidden | Fog: grayed |
|---|---|---|
| ![](docs/images/alps-z11.jpg) | ![](docs/images/bergen-fog-hidden.jpg) | ![](docs/images/bergen-fog-grayed.jpg) |

*(Previews from `tools/preview.py`, with water from elevation only and a synthetic route.)*

## Repository layout

| Folder | What |
|---|---|
| [`apple/`](apple/) | iOS + watchOS apps and the shared Swift package. **First target.** |
| [`garmin/`](garmin/) | Garmin Connect IQ (planned) |
| [`android/`](android/) | Android + Wear OS (planned) |
| [`shared/`](shared/) | Specs every platform follows: [palette](shared/palette.json), [rendering](shared/render-spec.md), [fog format](shared/fog-format.md), [data sources](shared/data-sources.md) |
| [`tools/`](tools/) | `preview.py`, the reference renderer for tuning the look on a desktop; `sync-palette.sh` |

## Map data (free, no API keys)

- **Elevation**: AWS Terrain Tiles (Terrarium PNG, z0–15)
- **Water**: OpenFreeMap vector tiles (OpenStreetMap data, OpenMapTiles schema, z0–14)

Tiles are rendered on the device into the Morrowind style and cached permanently. Details and
attribution are in [shared/data-sources.md](shared/data-sources.md).

## Quick start

- Apple: see [apple/README.md](apple/README.md). Run `cd apple && swift test`, then `xcodegen`, then open in Xcode.
- Tune the look without Xcode:

  ```bash
  pip install numpy pillow
  ```

  ```bash
  python3 tools/preview.py --lat 46.0 --lon 7.75 --zoom 11 --fog-demo -o preview.png
  ```

  After editing `shared/palette.json`, run `tools/sync-palette.sh`.
