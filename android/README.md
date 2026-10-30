# Android / Wear OS: planned

Not started. Notes for when we do:

- **Language**: Kotlin with Jetpack Compose (phone) and Compose for Wear OS (watch).
- **Fog source without extra GPS use**: read recorded exercise routes from **Health Connect**
  (`ExerciseSessionRecord` with `ExerciseRoute`, permission `READ_EXERCISE_ROUTES`). This mirrors the
  iOS HealthKit importer. GPX import works the same as on iOS.
- **Rendering**: port `apple/Sources/MorrowindMapCore` 1:1. It is plain math on RGBA buffers with no
  platform APIs: Terrarium decoding, a minimal MVT decoder, a scanline rasterizer, hillshade and fog
  compositing. Follow `../shared/render-spec.md` and read `../shared/palette.json`.
- **Fog storage and sync**: `../shared/fog-format.md`. Phone and watch sync with the Wearable Data
  Layer, merging by set union like the iOS/watchOS `FogSync`.
