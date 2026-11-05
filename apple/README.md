# Apple: iOS + watchOS

```
apple/
├── Package.swift                 Swift package with the shared code
├── Sources/MorrowindMapCore/     platform-independent logic (also testable with `swift test` on macOS)
│   ├── TileMath.swift            Web Mercator, tile IDs, overzoom ancestors
│   ├── ElevationGrid.swift       Terrarium decoding + bilinear resampling
│   ├── VectorTile.swift          minimal MVT/protobuf decoder (water, waterway layers)
│   ├── Rasterizer.swift          scanline polygon fill + line stroking
│   ├── TileRenderer.swift        Morrowind look: palette, hillshade, water, shoreline, grain
│   ├── FogOfWar.swift            FogGrid (explored z18 cells), coverage masks, compositing, file format
│   ├── FogStore.swift            persisted, observable fog + settings (radius, style)
│   ├── TileProvider.swift        downloads with a permanent disk cache, renders tiles
│   ├── HealthKitRouteImporter.swift  reads routes from recorded workouts (no GPS use)
│   ├── GPXParser.swift           GPX import (Garmin Connect / Strava exports)
│   ├── FogSync.swift             iPhone <-> Watch sync: fog grid, live tracks, navigation target
│   ├── LastKnownLocation.swift   cached position only, never starts GPS
│   ├── LiveLocation.swift        live GPS + compass, used only by the watch minimap
│   ├── TrackLogging.swift        live-fix filter, chunking for sync, the iPhone's log of watch tracks
│   └── Navigation.swift          bearing/distance math and the synced navigation target
├── Sources/MorrowindMapUI/       SwiftUI map view shared by both apps, and the watch's minimap
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

## Apple Watch: minimap and compass

The watch app opens on a **minimap**: a round map at a fixed scale (z15, a few hundred meters
across) that stays centred on you. There is no zoom or pan. It turns with the watch's compass
so the way you face is up (or with your direction of travel on watches without a compass). Tap it
to switch to north-up.

- **Target**: tap the map button (top left) to open the full map, pan with your finger and zoom
  with the Digital Crown, then tap a place. You can also long-press the map on the iPhone. The
  target syncs between both devices, and the newest change wins.
- **Compass**: the ring around the minimap shows N/E/S/W, and a gold arrowhead on the ring points
  to the target, like the quest marker on the in-game compass. Once the target is close enough to
  fit on the minimap, a gold marker also shows exactly where it is. The line at the bottom shows
  the distance and direction (for example "1.2 km NE") with an arrow showing which way to turn.
  The watch taps your wrist when you get within 25 m.
- **Exploring**: while the minimap is on screen it uses live GPS and reveals the fog as you walk.
  To keep logging with the screen off, press the walking figure (top right). A red dot and the
  distance show while an exploration runs; press stop to end it.
- **Logging to the iPhone**: logged points are filtered (accuracy 35 m or better, at least 10 m
  apart, with pauses over 5 minutes and GPS jumps starting a new line) and sent to the iPhone in
  chunks about once a minute with `transferUserInfo`. Chunks are queued and delivered even if the
  phone is away or the app isn't running. The iPhone saves every chunk under
  `Documents/watch-tracks/` and reveals it, so "Re-import all workouts and watch tracks" brings
  them back after a reset.

## How revealing works

The iPhone app never starts GPS. The watch uses GPS only while its minimap is on screen or while
an exploration runs (see above). Fog is lifted by:

- **HealthKit workout routes** that something already recorded (Apple Watch Workout app, Strava,
  Nike Run Club, ...). The first launch imports your whole history. Later, an `HKObserverQuery` with
  background delivery wakes the app after each new workout. Both apps import, and the results merge.
- **GPX files** imported on the iPhone.
- **Live tracks** logged on the watch.
- **Sync**: whenever either device reveals new cells it sends its grid file to the other over
  WatchConnectivity, and the receiver merges it.

The player marker uses `CLLocationManager.location`, the position the system already has cached.

## Known gaps / next steps

- Hillshade is computed per tile with clamped edges, which can leave faint seams on steep terrain.
  Fix: sample one pixel from neighbouring tiles.
- "Reset explored map" clears only the current device. The paired device will sync its cells back.
  Needs a reset tombstone in the sync protocol.
- A large first import (years of workouts) runs in the foreground with no progress UI.
- The iPhone map has no rotation, compass or scale bar yet (the watch minimap has a compass).
- An exploration doesn't survive the watch app being terminated. A workout session
  (`HKWorkoutSession`) would make long explorations more robust and also save them to Health.
- The reveal radius is set per device. The watch uses its own setting (default 250 m) for its
  live trail, and the iPhone reveals the received points with its own.
