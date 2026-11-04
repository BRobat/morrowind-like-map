# Apple: iOS + watchOS

```
apple/
├── Package.swift                 Swift package with the shared code
├── Sources/MorrowindMapCore/     platform-independent logic (also testable with `swift test` on macOS)
│   ├── TileMath.swift            Web Mercator, tile IDs, overzoom ancestors
│   ├── ElevationGrid.swift       Terrarium decoding + bilinear resampling
│   ├── VectorTile.swift          minimal MVT/protobuf decoder (water, waterway, transportation, place, poi)
│   ├── Rasterizer.swift          scanline polygon fill + line stroking
│   ├── TileRenderer.swift        Morrowind look: palette, hillshade, water, shoreline, grain
│   ├── Roads.swift               road classes/widths, antialiased road layer, BaseTile
│   ├── FogOfWar.swift            FogGrid (explored z18 cells), coverage masks, compositing, file format
│   ├── Waypoint.swift            towns / villages / POIs: kinds, extraction, discovery, label layout
│   ├── FogStore.swift            persisted, observable fog + settings (radius, style, places)
│   ├── TileProvider.swift        downloads with a permanent disk cache, renders tiles
│   ├── HealthKitRouteImporter.swift  reads routes from recorded workouts (no GPS use)
│   ├── GPXParser.swift           GPX import (Garmin Connect / Strava exports)
│   ├── FogSync.swift             iPhone <-> Watch sync over WatchConnectivity
│   └── LastKnownLocation.swift   cached position only, never starts GPS
├── Sources/MorrowindMapUI/       SwiftUI map view shared by both apps
│   ├── WaypointCache.swift       loads waypoints per vector tile, memoises discovery
│   └── WaypointOverlay.swift     ink icons + haloed serif labels
├── Tests/MorrowindMapCoreTests/
├── iOSApp/                       iPhone app
├── WatchApp/                     Apple Watch app (standalone-capable, companion of the iOS app)
└── project.yml                   XcodeGen spec for the Xcode project
```

## Build

Requirements: macOS with Xcode 15 or newer, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

Run the core unit tests:

```bash
cd apple && swift test
```

Generate the Xcode project:

```bash
cd apple && xcodegen
```

Open it:

```bash
open apple/MorrowindMap.xcodeproj
```

Before running on devices:

1. In `project.yml`, set `DEVELOPMENT_TEAM` and replace `com.example.morrowindmap` with your own bundle
   ID prefix, then re-run `xcodegen`.
2. HealthKit works only on a real device. In the Simulator, use the GPX import button to reveal areas.

## How revealing works

The app never starts GPS. Fog is lifted only by:

- **HealthKit workout routes** that something already recorded (Apple Watch Workout app, Strava,
  Nike Run Club, ...). The first launch imports your whole history. Later, an `HKObserverQuery` with
  background delivery wakes the app after each new workout. Both apps import, and the results merge.
- **GPX files** imported on the iPhone.
- **Sync**: whenever either device reveals new cells it sends its grid file to the other over
  WatchConnectivity, and the receiver merges it.

The player marker uses `CLLocationManager.location`, the position the system already has cached.

## Known gaps / next steps

- Hillshade is computed per tile with clamped edges, which can leave faint seams on steep terrain.
  Fix: sample one pixel from neighbouring tiles.
- "Reset explored map" clears only the current device. The paired device will sync its cells back.
  Needs a reset tombstone in the sync protocol.
- A large first import (years of workouts) runs in the foreground with no progress UI.
- No map rotation, compass or scale bar yet.
- Waypoints can't be tapped yet (no callout with the place's name/type), and there are no
  user-placed markers.
- Place names are the local `name`; a language preference (`name_en`, ...) would be easy to add.
