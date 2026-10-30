# Fog-of-war data format (v1)

Every platform (Apple, Garmin, Android) stores explored areas the same way, so files can be
moved between devices and merged.

## Model

- The world is divided into **Web Mercator cells at zoom 18**: the same grid as XYZ map tiles at
  z18. Cell `(x, y)` covers tile `18/x/y`. A cell is about 153 m wide at the equator, 98 m at 50°N
  and 76 m at 60°N.
- A cell is either **explored** or not. Explored data is a *set* of cells, so merging two devices'
  data is a set union. Union is commutative, associative and idempotent, so sync needs no conflict
  resolution.
- **Revealing a point** marks every cell whose centre is within `R` meters of the point (default
  `R = 100 m`, user-configurable), always including the cell that holds the point.
- **Revealing a track** reveals each point. Where two consecutive points are more than `max(R/2, 10 m)`
  apart but no more than **2 km** apart, intermediate points are interpolated linearly every
  `max(R/2, 10 m)`. Longer gaps (GPS dropouts, ferries, flights) are left unrevealed.
- GPS points with a horizontal accuracy worse than 50 m are discarded when the accuracy is known.

## Binary file (`*.mwfog`)

All integers are little-endian.

| Offset | Size | Field                                   |
|-------:|-----:|-----------------------------------------|
| 0      | 4    | Magic `"MWFG"` (ASCII)                  |
| 4      | 2    | Format version, `1`                     |
| 6      | 1    | Cell zoom, `18`                         |
| 7      | 1    | Reserved, `0`                           |
| 8      | 4    | `count`, number of cells                |
| 12     | 8×count | `count` × (`uint32 x`, `uint32 y`)   |

Writers should sort cells by `(x << 32) | y` ascending. Readers must not rely on the order.
A reader that sees an unknown version or zoom must refuse the file rather than misread it.

Size: 8 bytes per cell. One 10 km run with R = 100 m explores about 200 cells (1.6 KB), so years of
activity stay in the low megabytes.

## Rendering the fog

For a tile at zoom `z`, rendered at `S` px per side:

- `cellPx = S · 2^(z − 18)`
- Each explored cell stamps a disc centred on the cell centre with radius
  `r = max(0.75 · cellPx, 1 px)`, plus a linear falloff of
  `soft = min(edgeSoftnessPx, max(1.5, 1.5 · cellPx))` px. Inside the disc coverage is 1; it drops to 0 at `r + soft`.
- Coverage is the maximum over all discs.
- The final pixel is `lerp(fogColor, base, coverage)`, where `fogColor` depends on the style:
  - `hidden`: `fog.hiddenColor` with the same parchment grain as the map,
  - `grayed`: the base pixel desaturated by `fog.grayedDesaturation` and darkened by `fog.grayedDarken`.

All parameters are in `palette.json`.
