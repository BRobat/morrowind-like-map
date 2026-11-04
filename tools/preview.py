#!/usr/bin/env python3
"""Reference renderer for the Morrowind-style map.

Reads shared/palette.json and follows the same steps as the Swift
`TileRenderer` (see shared/render-spec.md), so the palette can be tuned on a
desktop without building the apps. Water here comes only from elevation <= 0,
because inland water needs the OpenFreeMap vector tiles, which this script
doesn't decode.

    python3 tools/preview.py --lat 46.0 --lon 7.75 --zoom 11 --size 3 -o preview.png
    python3 tools/preview.py ... --fog-demo        # adds a synthetic explored route
    python3 tools/preview.py ... --places-demo     # draws waypoints from tools/demo-places.json

Waypoint drawing (icons, labels, collision layout, discovery) follows
shared/waypoints-spec.md and mirrors apple/Sources/MorrowindMapUI/WaypointOverlay.swift.
"""
import argparse
import io
import json
import math
import os
import urllib.request

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TERRARIUM = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
TILE = 256
FOG_ZOOM = 18


def hex_rgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    lat_r = math.radians(lat)
    y = (1.0 - math.asinh(math.tan(lat_r)) / math.pi) / 2.0 * n
    return x, y


def fetch_dem(z, x, y, cache_dir):
    os.makedirs(cache_dir, exist_ok=True)
    path = os.path.join(cache_dir, f"{z}_{x}_{y}.png")
    if not os.path.exists(path):
        with urllib.request.urlopen(TERRARIUM.format(z=z, x=x, y=y)) as r:
            data = r.read()
        with open(path, "wb") as f:
            f.write(data)
    img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    return img[..., 0] * 256 + img[..., 1] + img[..., 2] / 256 - 32768


def render(dem, z, ty, pal):
    """dem: elevation in meters (H, W). ty: tile row of the top edge (for latitude)."""
    h, w = dem.shape
    # Ground size of one pixel at the latitude of the image centre.
    n = 2 ** z
    lat = math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * (ty + h / TILE / 2) / n))))
    px_m = 40075016.686 * math.cos(math.radians(lat)) / (n * TILE)

    land_stops = pal["land"]
    elev_stops = np.array([s["elevation"] for s in land_stops], dtype=np.float64)
    colors = np.array([hex_rgb(s["color"]) for s in land_stops])
    land = np.stack([np.interp(dem, elev_stops, colors[:, c]) for c in range(3)], axis=-1)

    hs = pal["hillshade"]
    ex = hs["exaggeration"] * 2 ** (max(0, hs["lowZoomBoostBelow"] - z) * hs["lowZoomBoostPerLevel"])
    e = np.pad(dem, 1, mode="edge")
    dzdx = (e[1:-1, 2:] - e[1:-1, :-2]) / (2 * px_m) * ex
    dzdy = (e[2:, 1:-1] - e[:-2, 1:-1]) / (2 * px_m) * ex
    az = math.radians(hs["azimuthDegrees"])
    alt = math.radians(hs["altitudeDegrees"])
    lx, ly, lz = math.sin(az) * math.cos(alt), -math.cos(az) * math.cos(alt), math.sin(alt)
    shade = (-dzdx * lx - dzdy * ly + lz) / np.sqrt(dzdx ** 2 + dzdy ** 2 + 1)
    factor = np.clip(1 + hs["strength"] * (np.clip(shade, 0, 1) - lz) / lz, hs["minFactor"], hs["maxFactor"])
    land = land * factor[..., None]

    wp = pal["water"]
    depth_t = np.clip(-dem / wp["deepAtMeters"], 0, 1)[..., None]
    water_col = hex_rgb(wp["shallow"]) * (1 - depth_t) + hex_rgb(wp["deep"]) * depth_t
    is_water = dem <= 0
    out = np.where(is_water[..., None], water_col, land)

    # Shoreline: land pixels touching water.
    wpad = np.pad(is_water, 1, mode="edge")
    near = wpad[:-2, 1:-1] | wpad[2:, 1:-1] | wpad[1:-1, :-2] | wpad[1:-1, 2:]
    shore = near & ~is_water
    out[shore] = hex_rgb(wp["shoreline"])

    # Parchment grain: deterministic hash noise, same formula as Swift.
    yy, xx = np.mgrid[0:h, 0:w].astype(np.uint32)
    noise = hash_noise(xx, yy)
    out = out * (1 + pal["parchment"]["noiseAmplitude"] * (noise - 0.5) * 2)[..., None]
    return np.clip(out, 0, 255)


def hash_noise(x, y):
    with np.errstate(over="ignore"):
        hsh = (x * np.uint32(374761393) + y * np.uint32(668265263)).astype(np.uint32)
        hsh = ((hsh ^ (hsh >> np.uint32(13))) * np.uint32(1274126177)).astype(np.uint32)
        hsh = hsh ^ (hsh >> np.uint32(16))
    return (hsh & np.uint32(0xFFFF)).astype(np.float64) / 65535.0


def fog_mask(cells, z, tx0, ty0, h, w, softness):
    """1 = explored, 0 = fog. cells: set of (x, y) at FOG_ZOOM."""
    mask = np.zeros((h, w))
    scale = 2 ** (z - FOG_ZOOM) * TILE  # pixels per fog cell
    radius = max(scale * 0.75, 1.5)
    yy, xx = np.mgrid[0:h, 0:w]
    for cx, cy in cells:
        px = (cx + 0.5) * scale - tx0 * TILE
        py = (cy + 0.5) * scale - ty0 * TILE
        r = radius + softness
        x0, x1 = int(max(0, px - r)), int(min(w, px + r + 1))
        y0, y1 = int(max(0, py - r)), int(min(h, py + r + 1))
        if x0 >= x1 or y0 >= y1:
            continue
        d = np.hypot(xx[y0:y1, x0:x1] - px, yy[y0:y1, x0:x1] - py)
        a = np.clip((radius + softness - d) / max(softness, 1e-6), 0, 1)
        mask[y0:y1, x0:x1] = np.maximum(mask[y0:y1, x0:x1], a)
    return mask


def demo_cells(lat, lon, radius_m=100):
    """A wobbly loop around the centre, revealed like a real run would be."""
    cells = set()
    for i in range(2000):
        t = i / 2000 * 2 * math.pi
        r = 2500 + 600 * math.sin(5 * t)
        plat = lat + r * math.sin(t) / 111320
        plon = lon + r * math.cos(t) / (111320 * math.cos(math.radians(lat)))
        fx, fy = lonlat_to_tile(plon, plat, FOG_ZOOM)
        cell_m = 40075016.686 * math.cos(math.radians(plat)) / 2 ** FOG_ZOOM
        k = int(math.ceil(radius_m / cell_m))
        for dx in range(-k, k + 1):
            for dy in range(-k, k + 1):
                if (dx * cell_m) ** 2 + (dy * cell_m) ** 2 <= radius_m ** 2:
                    cells.add((int(fx) + dx, int(fy) + dy))
    return cells


# --- Waypoints (shared/waypoints-spec.md) -------------------------------------------------------

# kind: (minZoom, minLabelZoom, landmark, discoveryRadius m, priority, fontSize, iconSize)
KINDS = {
    "city":       (4, 4, True, 1000, 0, 15, 16),
    "town":       (8, 8, True, 1000, 1, 13, 12),
    "village":    (11, 11, False, 500, 2, 11.5, 8),
    "hamlet":     (13, 13, False, 300, 4, 10, 5),
    "peak":       (11, 12, False, 250, 3, 10, 9),
    "castle":     (13, 14, False, 150, 5, 10, 11),
    "ruins":      (13, 14, False, 150, 5, 10, 11),
    "lighthouse": (13, 14, False, 150, 5, 10, 11),
    "hut":        (14, 15, False, 150, 6, 10, 11),
    "camp":       (14, 15, False, 150, 6, 10, 11),
    "viewpoint":  (14, 15, False, 150, 6, 10, 11),
    "cave":       (14, 15, False, 150, 6, 10, 11),
    "shrine":     (15, 15, False, 150, 7, 10, 11),
    "monument":   (15, 15, False, 150, 7, 10, 11),
    "spring":     (15, 15, False, 150, 7, 10, 11),
}
SETTLEMENTS = {"city", "town", "village", "hamlet"}
INK, PAPER, WATER_INK = (74, 56, 38), (230, 214, 176), (61, 92, 110)
FONT_DIR = "/usr/share/fonts/truetype"
FONTS = {  # (regular-ish, bold, italic) candidates; first that exists wins
    "bold": ["dejavu/DejaVuSerif-Bold.ttf", "liberation/LiberationSerif-Bold.ttf"],
    "regular": ["liberation/LiberationSerif-Regular.ttf", "dejavu/DejaVuSerif.ttf"],
    "italic": ["liberation/LiberationSerif-Italic.ttf", "dejavu/DejaVuSerif-Italic.ttf"],
}
MERLONS = [(-0.45, 0.5), (-0.45, -0.5), (-0.27, -0.5), (-0.27, -0.32), (-0.09, -0.32), (-0.09, -0.5),
           (0.09, -0.5), (0.09, -0.32), (0.27, -0.32), (0.27, -0.5), (0.45, -0.5), (0.45, 0.5)]


def arch(cx, base, r, steps=10):
    return [(cx + r * math.cos(math.pi * i / steps), base - r * math.sin(math.pi * i / steps)) for i in range(steps + 1)]


def glyph(kind, capital=False):
    """Parts as (shape, data, fill, stroke): shape is 'poly', 'line', 'circle' (cx, cy, r) or 'rect' (x, y, w, h)."""
    P, L, C, R = "poly", "line", "circle", "rect"
    return {
        "city": [(P, MERLONS, INK, None), (P, arch(0, 0.5, 0.16), PAPER, None)]
                + ([(C, (0, -0.02, 0.09), PAPER, None)] if capital else []),
        "town": [(P, [(-0.42, 0.45), (-0.42, -0.05), (0, -0.45), (0.42, -0.05), (0.42, 0.45)], INK, None)],
        "village": [(C, (0, 0, 0.42), PAPER, INK), (C, (0, 0, 0.16), INK, None)],
        "hamlet": [(C, (0, 0, 0.5), INK, None)],
        "peak": [(P, [(0, -0.5), (0.55, 0.42), (-0.55, 0.42)], INK, None)],
        "castle": [(P, MERLONS, PAPER, INK), (P, arch(0, 0.5, 0.15), INK, None)],
        "ruins": [(P, [(-0.42, 0.5), (-0.42, -0.3), (-0.22, -0.48), (-0.08, -0.12), (0.14, -0.36), (0.42, 0.02), (0.42, 0.5)], PAPER, INK),
                  (L, [(-0.42, 0.18), (0.42, 0.18)], None, INK)],
        "hut": [(P, [(-0.5, 0.45), (0, -0.45), (0.5, 0.45)], PAPER, INK), (R, (-0.12, 0.1, 0.24, 0.35), INK, None)],
        "camp": [(P, [(-0.5, 0.42), (0, -0.45), (0.5, 0.42)], PAPER, INK), (P, [(0, -0.05), (-0.16, 0.42), (0.16, 0.42)], INK, None)],
        "lighthouse": [(P, [(-0.16, -0.22), (0.16, -0.22), (0.26, 0.5), (-0.26, 0.5)], INK, None),
                       (C, (0, -0.38, 0.12), PAPER, INK),
                       (L, [(-0.5, -0.5), (-0.24, -0.42)], None, INK), (L, [(0.5, -0.5), (0.24, -0.42)], None, INK)],
        "viewpoint": [(P, [(-0.5, 0), (-0.25, -0.25), (0, -0.32), (0.25, -0.25), (0.5, 0), (0.25, 0.25), (0, 0.32), (-0.25, 0.25)], PAPER, INK),
                      (C, (0, 0, 0.16), INK, None)],
        "cave": [(P, arch(0, 0.4, 0.5), INK, None), (P, arch(0, 0.4, 0.24), PAPER, None)],
        "shrine": [(R, (-0.09, -0.5, 0.18, 1.0), INK, None), (R, (-0.34, -0.25, 0.68, 0.17), INK, None)],
        "monument": [(P, [(-0.13, 0.32), (-0.08, -0.32), (0, -0.5), (0.08, -0.32), (0.13, 0.32)], INK, None),
                     (R, (-0.3, 0.32, 0.6, 0.16), INK, None)],
        "spring": [(P, [(0.62 * 2 * t * (1 - t) * (1 if i < 9 else -1),
                         -0.5 * (1 - t) ** 2 + 0.4 * t * (1 - t) + 0.45 * t ** 2)
                        for i, t in enumerate([k / 8 for k in range(9)] + [1 - k / 8 for k in range(9)])], WATER_INK, None)],
    }[kind]


def load_font(style, size):
    for rel in FONTS[style]:
        path = os.path.join(FONT_DIR, rel)
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def label_style(kind):
    return {"city": "bold", "town": "bold", "village": "regular", "hamlet": "regular"}.get(kind, "italic")


def label_text(wp):
    text = wp["name"]
    if wp["kind"] == "peak" and wp.get("ele"):
        text += f" {wp['ele']} m"
    return text.upper() if wp["kind"] == "city" else text


def is_visible(wp, zoom):
    min_z = KINDS[wp["kind"]][0]
    rank = wp.get("rank", 10)
    if wp["kind"] == "city":
        min_z += -1 if wp.get("capital") else min(max(rank - 4, 0), 4) * 0.5
    if wp["kind"] == "town":
        min_z += min(max(rank - 6, 0), 6) * 0.25
    return zoom >= min_z


def discovered(wp, cells):
    if not cells:
        return False
    n = 2 ** FOG_ZOOM
    fx, fy = lonlat_to_tile(wp["lon"], wp["lat"], FOG_ZOOM)
    cell_m = 40075016.686 * math.cos(math.radians(wp["lat"])) / n
    r = KINDS[wp["kind"]][3] / cell_m
    k = int(math.ceil(r))
    cx, cy = int(fx), int(fy)
    for dy in range(-k, k + 1):
        for dx in range(-k, k + 1):
            if (dx or dy) and dx * dx + dy * dy > r * r:
                continue
            if ((cx + dx) % n, cy + dy) in cells:
                return True
    return False


def intersects(a, b):
    return a[2] > 0 and b[2] > 0 and a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]


def grow(r, d):
    return (r[0] - d, r[1] - d, r[2] + 2 * d, r[3] + 2 * d)


def layout(cands, zoom, measure, scale=1.0, limit=200):
    """Same two-pass algorithm as WaypointLayout.layout in Swift. cands: (wp, x, y, discovered)."""
    def key(c):
        wp = c[0]
        return (KINDS[wp["kind"]][4], 0 if wp.get("capital") else 1, wp.get("rank", 10), wp["name"])
    accepted = []
    for c in sorted(cands, key=key):
        if len(accepted) >= limit:
            break
        wp, x, y, _ = c
        s = KINDS[wp["kind"]][6] * scale * (1.15 if wp.get("capital") else 1)
        icon = (x - s / 2, y - s / 2, s, s)
        if any(intersects(a[1], grow(icon, 1)) for a in accepted):
            continue
        accepted.append((c, icon))
    icons = [a[1] for a in accepted]
    labels, out = [], []
    gap = 3 * scale
    for i, (c, icon) in enumerate(accepted):
        wp, x, y, disc = c
        fs = KINDS[wp["kind"]][5] * scale * (1.15 if wp["kind"] == "city" and wp.get("capital") else 1)
        label = None
        if zoom >= KINDS[wp["kind"]][1]:
            w, h = measure(wp, fs)
            half = icon[2] / 2
            for r in [(x + half + gap, y - h / 2, w, h), (x - half - gap - w, y - h / 2, w, h),
                      (x - w / 2, y - half - gap / 2 - h, w, h), (x - w / 2, y + half + gap / 2, w, h)]:
                g = grow(r, 1)
                if not any(intersects(o, g) for o in icons) and not any(intersects(o, g) for o in labels):
                    label = r
                    break
            if label is None and wp["kind"] in SETTLEMENTS:
                icons[i] = (0, 0, 0, 0)
                continue
        if label:
            labels.append(label)
        out.append((wp, x, y, icon[2], fs, label, disc))
    return out


def draw_places(img, places, z, tx0, ty0, cells, show_all=False, ss=2):
    """img: float RGB array. cells: explored fog cells, or None to treat everything as discovered.
    Draws at `ss`× supersampling for smooth edges."""
    h, w = img.shape[:2]
    base = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).resize((w * ss, h * ss), Image.LANCZOS)
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    faded = Image.new("RGBA", base.size, (0, 0, 0, 0))
    zoom = z
    cands = []
    for wp in places:
        if not is_visible(wp, zoom):
            continue
        fx, fy = lonlat_to_tile(wp["lon"], wp["lat"], z)
        x, y = (fx - tx0) * TILE, (fy - ty0) * TILE
        if not (-40 < x < w + 40 and -40 < y < h + 40):
            continue
        disc = True if cells is None else discovered(wp, cells)
        landmark = KINDS[wp["kind"]][2]
        if not (disc or landmark or show_all):
            continue
        cands.append((wp, x, y, disc))

    fonts = {}

    def font(wp, fs):
        k = (label_style(wp["kind"]), round(fs * ss))
        if k not in fonts:
            fonts[k] = load_font(k[0], k[1])
        return fonts[k]

    def measure(wp, fs):
        f = font(wp, fs)
        spacing = fs * 0.08 if wp["kind"] == "city" else 0
        text = label_text(wp)
        x0, y0, x1, y1 = f.getbbox(text)
        return (x1 / ss + spacing * len(text), fs * 1.25)

    placed = layout(cands, zoom, measure)
    draws = {True: ImageDraw.Draw(layer), False: ImageDraw.Draw(faded)}
    for wp, x, y, s, fs, label, disc in placed:
        # Discovered places and landmarks at full strength; the rest (only with show_all) faded.
        d = draws[disc or KINDS[wp["kind"]][2]]
        parts = glyph(wp["kind"], wp.get("capital", False))
        line = max(1, s * 0.1) * ss

        def tr(pts):
            return [((x + px * s) * ss, (y + py * s) * ss) for px, py in pts]

        def shape(kind, data, fill, outline, width):
            if kind in ("poly", "line"):
                pts = tr(data)
                if kind == "poly" and fill:
                    d.polygon(pts, fill=fill)
                if outline:
                    d.line(pts + (pts[:1] if kind == "poly" else []), fill=outline, width=int(round(width)), joint="curve")
            elif kind == "circle":
                cx, cy, r = data
                box = [(x + (cx - r) * s) * ss, (y + (cy - r) * s) * ss, (x + (cx + r) * s) * ss, (y + (cy + r) * s) * ss]
                d.ellipse(box, fill=fill, outline=outline, width=int(round(width)) if outline else 0)
            else:
                rx, ry, rw, rh = data
                box = [(x + rx * s) * ss, (y + ry * s) * ss, (x + (rx + rw) * s) * ss, (y + (ry + rh) * s) * ss]
                if fill:
                    d.rectangle(box, fill=fill)
                if outline:
                    d.rectangle(box, outline=outline, width=int(round(width)))

        for p in parts:  # halo
            shape(p[0], p[1], None, PAPER, line + 2.5 * ss)
        for p in parts:
            shape(p[0], p[1], p[2], p[3], line)
        if label:
            f = font(wp, fs)
            text = label_text(wp)
            spacing = fs * 0.08 if wp["kind"] == "city" else 0
            ox, oy = label[0] * ss, (label[1] + (label[3] - fs * 1.05) / 2) * ss
            r = max(0.8, fs * 0.08) * ss
            for pass_color, offsets in ((PAPER, [(-r, 0), (r, 0), (0, -r), (0, r), (-r, -r), (r, r), (-r, r), (r, -r)]),
                                        (INK, [(0, 0)])):
                for dx, dy in offsets:
                    cx = ox + dx
                    for ch in text:
                        d.text((cx, oy + dy), ch, font=f, fill=pass_color)
                        cx += f.getlength(ch) + spacing * ss
    alpha = faded.getchannel("A").point(lambda a: int(a * 0.45))
    faded.putalpha(alpha)
    out = Image.alpha_composite(Image.alpha_composite(base.convert("RGBA"), faded), layer)
    return np.asarray(out.convert("RGB").resize((w, h), Image.LANCZOS), dtype=np.float64)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, default=46.0)
    ap.add_argument("--lon", type=float, default=7.75)
    ap.add_argument("--zoom", type=int, default=11)
    ap.add_argument("--size", type=int, default=3, help="tiles per side")
    ap.add_argument("--fog-demo", action="store_true")
    ap.add_argument("--fog-style", choices=["hidden", "grayed"], default="hidden")
    ap.add_argument("--places-demo", action="store_true", help="draw waypoints from --places")
    ap.add_argument("--places", default=os.path.join(ROOT, "tools", "demo-places.json"))
    ap.add_argument("--all-places", action="store_true", help="also draw undiscovered places, faded")
    ap.add_argument("-o", "--out", default="preview.png")
    args = ap.parse_args()

    with open(os.path.join(ROOT, "shared", "palette.json")) as f:
        pal = json.load(f)
    cache = os.path.join(os.environ.get("TMPDIR", "/tmp"), "mwmap-dem-cache")

    z = args.zoom
    cx, cy = lonlat_to_tile(args.lon, args.lat, min(z, 15))
    tx0 = int(cx) - args.size // 2
    ty0 = int(cy) - args.size // 2
    rows = []
    for ty in range(ty0, ty0 + args.size):
        rows.append(np.hstack([fetch_dem(z, tx, ty, cache) for tx in range(tx0, tx0 + args.size)]))
    dem = np.vstack(rows)
    img = render(dem, z, ty0, pal)

    cells = demo_cells(args.lat, args.lon) if args.fog_demo else set()
    if args.fog_demo:
        fog = pal["fog"]
        mask = fog_mask(cells, z, tx0, ty0, *dem.shape,
                        fog["edgeSoftnessPx"])[..., None]
        if args.fog_style == "hidden":
            hidden = hex_rgb(fog["hiddenColor"]) * (1 + pal["parchment"]["noiseAmplitude"] *
                     (hash_noise(*np.mgrid[0:dem.shape[1], 0:dem.shape[0]][::-1].astype(np.uint32)) - 0.5) * 2)[..., None]
            hidden = img + (hidden - img) * fog["hiddenOpacity"]
        else:
            gray = img.mean(axis=-1, keepdims=True)
            hidden = (img * (1 - fog["grayedDesaturation"]) + gray * fog["grayedDesaturation"]) * (1 - fog["grayedDarken"])
        img = img * mask + hidden * (1 - mask)

    if args.places_demo:
        with open(args.places) as f:
            places = json.load(f)["places"]
        # Without a fog demo everything counts as discovered, so the whole layer is visible.
        img = draw_places(img, places, z, tx0, ty0, cells if args.fog_demo else None, show_all=args.all_places)

    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(args.out)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
