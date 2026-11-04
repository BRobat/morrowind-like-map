# Morrowind-style tile rendering

The look is a hand-drawn parchment map. Land is shades of brown that get darker with elevation and is
lit by hillshade. Water is a muted blue with a dark ink shoreline. There are no roads or buildings;
named places are an ink overlay on top (step 8). Every platform renders tiles on the device from raw data, following the steps below with the
values in [`palette.json`](palette.json). [`tools/preview.py`](../tools/preview.py) is the executable
reference.

Tiles are 256 px Web Mercator XYZ tiles.

## Inputs

1. **Elevation**: a Terrarium PNG for the tile, where `meters = R·256 + G + B/256 − 32768`. Above the
   source's max zoom (15), take the z15 ancestor and resample its sub-square bilinearly.
2. **Water**: an OpenMapTiles vector tile (layers `water` and `waterway`). Above z14, use the z14
   ancestor and scale its geometry. If the vector tile can't be loaded (offline, never cached), treat
   pixels with `elevation ≤ 0` as water. A vector tile that returns 404 means "no water here".

## Steps

1. **Water mask**:
   - Fill `water` polygons with the nonzero rule, skipping `class=swimming_pool` and `brunnel=tunnel`.
   - Stroke `waterway` lines with round joins. Widths are in 256-px pixels:
     - `river`: from z9, width `min(1 + 0.6·(z−9), 6)`
     - `canal`: from z12, width `min(1 + 0.5·(z−12), 4)`
     - `stream`: from z13, width `min(0.8 + 0.4·(z−13), 2.5)`
   - Tunnels are skipped.
2. **Shoreline**: land pixels within `water.shorelineWidthPx` (Manhattan distance) of a water pixel take
   the colour `water.shoreline`.
3. **Water colour**: `lerp(shallow, deep, clamp(−elevation / deepAtMeters, 0, 1))`, using the
   bathymetry that Terrarium includes for oceans.
4. **Land colour**: interpolate linearly between the `land` stops by elevation.
5. **Hillshade** (land only), with pixel ground size `p = 40075016.686·cos(lat) / (2^z · 256)` and
   the tile's centre latitude:
   - `boost = 2^(max(0, lowZoomBoostBelow − z) · lowZoomBoostPerLevel)`
   - `dzdx = (e[x+1] − e[x−1]) / (2p) · exaggeration · boost`, and `dzdy` the same way (y points south). Edges are clamped.
   - Light vector `L = (sin az·cos alt, −cos az·cos alt, sin alt)`.
   - `shade = (−dzdx·Lx − dzdy·Ly + Lz) / sqrt(dzdx² + dzdy² + 1)`
   - `factor = clamp(1 + strength·(clamp(shade,0,1) − Lz)/Lz, minFactor, maxFactor)`
   - `colour *= factor`
6. **Parchment grain**: `colour *= 1 + noiseAmplitude·(n − 0.5)·2`, where `n` is a hash of the *world*
   pixel coordinate (so tiles join seamlessly):
   ```
   h = x·374761393 + y·668265263          (uint32, wrapping)
   h = (h ^ (h >> 13)) · 1274126177
   h = h ^ (h >> 16)
   n = (h & 0xFFFF) / 65535
   ```
7. **Fog of war** is composited on top. See [`fog-format.md`](fog-format.md).
8. **Waypoints** (towns, villages, POIs) are drawn as a vector overlay above the tiles, not baked into
   them, so labels stay sharp and can cross tile edges. See [`waypoints-spec.md`](waypoints-spec.md).

Cache the base tile (steps 1–6) separately from the fog composite. The base never changes; the fog
changes after every run.
