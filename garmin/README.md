# Garmin (Connect IQ): planned

Not started. Notes for when we do:

- **Language/SDK**: Monkey C, Connect IQ SDK. Probably a widget/glance plus a full-screen app.
- **Fog source without extra GPS use**: Connect IQ apps can't read the history of other activities on
  the device. Options:
  1. Build a Connect IQ **data field** that runs inside the user's normal Run/Hike activity and records
     the activity's own `Activity.Info.currentLocation`. This reuses the GPS the activity already has
     on, so it costs nothing extra. It stores revealed z18 cells (see `../shared/fog-format.md`).
  2. Fetch past activities from **Garmin Connect** (Health/Activity API, partner access required), or
     have users export GPX/FIT files and import them on the phone. The iOS app already imports GPX.
- **Map rendering**: watches have little memory and CPU. Pre-render Morrowind-style tiles on the
  phone or a server following `../shared/render-spec.md`, ship small palettised bitmaps to the
  watch, and composite fog there.
- **Shared assets**: `../shared/palette.json` (colours), `../shared/fog-format.md` (explored cells and
  the binary file format).
