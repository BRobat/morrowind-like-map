# Waypoints: towns, villages and points of interest

So the map isn't an empty sheet of parchment, it shows named places in the style of the in-game maps:
settlements always (like the major cities on the *Oblivion* map), and smaller places and landmarks
once you have been near them (like *Oblivion*'s discovered locations). Zooming in reveals more
detail: towns on the overview, villages and peaks further in, and real waypoints such as castles,
huts and caves close up.

Every platform follows this spec. [`tools/preview.py`](../tools/preview.py) `--places-demo` is the
executable reference for the look. The Swift version is `apple/Sources/MorrowindMapCore/Waypoint.swift`
(data, discovery, layout) and `apple/Sources/MorrowindMapUI/WaypointOverlay.swift` (drawing).

## Source

The same OpenFreeMap vector tiles that already provide water (see [data-sources.md](data-sources.md)),
so places cost no extra downloads and work offline wherever the map does. Three OpenMapTiles layers are
read, at data zoom `min(tileZoom, 14)`:

| Layer | Features used |
|---|---|
| `place` | `class` = city, town, village, hamlet, isolated_dwelling |
| `mountain_peak` | `class` = peak, volcano (or no class); `ele` for the height |
| `poi` | mapped by `subclass` first, then `class` (table below) |

- Only point features with a name are used: `name`, then `name:latin`, `name_en`, `name_int`.
- Points outside `0 ≤ x, y < extent` lie in the tile's buffer and belong to a neighbour: skip them.
- A waypoint's ID is `<layer>:<feature id>` (OpenMapTiles feature IDs come from OSM IDs, so they are
  stable across zooms). Without a feature ID, use `<kind>:<name>:<round(lat·100)>:<round(lon·100)>`.
- `rank` (lower = more important) orders places within a kind. `capital = 2` marks a national capital.
- While a tile loads, use the waypoints of a loaded ancestor tile that fall inside it.

## Kinds

| Kind | From | Shown from zoom | Labelled from | Discovered within | Icon (pt) | Label (pt) |
|---|---|---|---|---|---|---|
| city | place `city` | 4 (capital 3; +0.5 per rank above 4, max +2) | 4 | landmark | 16 | 15 bold, CAPS, tracked |
| town | place `town` | 8 (+0.25 per rank above 6, max +1.5) | 8 | landmark | 12 | 13 semibold |
| village | place `village` | 11 | 11 | 500 m | 8 | 11.5 medium |
| hamlet | place `hamlet`, `isolated_dwelling` | 13 | 13 | 300 m | 5 | 10 regular |
| peak | `mountain_peak` | 11 | 12 | 250 m | 9 | 10 italic, "Name 1234 m" |
| castle | subclass castle, fort, fortress, manor, palace, city_gate; class `castle` | 13 | 14 | 150 m | 11 | 10 italic |
| ruins | subclass ruins, archaeological_site, battlefield | 13 | 14 | 150 m | 11 | 10 italic |
| lighthouse | subclass lighthouse | 13 | 14 | 150 m | 11 | 10 italic |
| hut | subclass alpine_hut, wilderness_hut, shelter, basic_hut | 14 | 15 | 150 m | 11 | 10 italic |
| camp | subclass camp_site, caravan_site; class `campsite` | 14 | 15 | 150 m | 11 | 10 italic |
| viewpoint | subclass viewpoint | 14 | 15 | 150 m | 11 | 10 italic |
| cave | subclass cave_entrance | 14 | 15 | 150 m | 11 | 10 italic |
| shrine | subclass chapel, monastery; class `place_of_worship` | 15 | 15 | 150 m | 11 | 10 italic |
| monument | subclass monument, memorial, wayside_cross, wayside_shrine, obelisk; class `monument` | 15 | 15 | 150 m | 11 | 10 italic |
| spring | subclass spring, drinking_water, water_point | 15 | 15 | 150 m | 11 | 10 italic |

Collision priority (lower wins): city 0, town 1, village 2, peak 3, hamlet 4, castle/ruins/lighthouse 5,
hut/camp/viewpoint/cave 6, shrine/monument/spring 7. Ties: capital first, then `rank`, then ID.

## Discovery

A waypoint is **discovered** if any explored fog cell (see [fog-format.md](fog-format.md)) lies within
its discovery radius: check cells at offsets `(dx, dy)` from the waypoint's own cell with
`dx² + dy² ≤ r²`, where `r = radius / cellMeters` and `cellMeters = 40075016.686·cos(lat) / 2^18`.
The waypoint's own cell always counts. Cities and towns are **landmarks**: they are shown whether
discovered or not.

User setting `placesVisibility`:

- `discovered` (default): landmarks plus discovered places.
- `all`: everything; undiscovered non-landmarks are drawn at 45% opacity.
- `off`: no places.

## Layout

Coordinates are screen points. Consider waypoints within 40 pt outside the view too, so labels don't pop
at the edges.

1. Drop waypoints below their kind's "shown from" zoom, or hidden by the visibility setting.
2. Sort by priority.
3. **Icons**: accept each icon (a square of its icon size around the point) unless it overlaps an
   already accepted icon grown by 1 pt. Stop at 200 icons.
4. **Labels**, in the same order, for kinds past their "labelled from" zoom: try right, left, above,
   below the icon (3 pt gap; 1.5 pt above/below), taking the first that, grown by 1 pt, overlaps no
   icon and no placed label. If none fits, a settlement is dropped entirely (its icon frees up);
   other kinds keep the icon alone.

The watch scales icons, fonts and gaps by 0.8.

## Drawing

Ink `#4A3826`, parchment `#E6D6B0`, water ink `#3D5C6E`. Every glyph first gets a parchment halo
(stroke of width `line + 2.5`, where `line = max(1, 0.1·iconSize)`), then its fills and ink strokes.
Shapes are in a unit box (−0.5…0.5, y down) scaled to the icon size:

| Kind | Glyph |
|---|---|
| city | filled keep with three merlons and a parchment arched door (a parchment dot for capitals) |
| town | filled house (pentagon) |
| village | parchment ring with an ink dot |
| hamlet | filled dot |
| peak | filled triangle |
| castle | parchment keep, ink outline and door |
| ruins | parchment broken wall with a jagged top |
| hut | parchment A-frame with an ink door |
| camp | parchment tent with an ink opening |
| lighthouse | filled tapered tower, lamp ring, two light rays |
| viewpoint | parchment eye with an ink pupil |
| cave | filled arch with a parchment opening |
| shrine | filled cross |
| monument | filled obelisk on a base |
| spring | water-ink drop |

Labels are a serif face in ink, with a parchment halo drawn by repeating the text in parchment at the 8
neighbouring offsets of `max(0.8, 0.08·fontSize)` pt. Cities are upper case with `0.08·fontSize`
letter spacing. Draw all icons before all labels.
