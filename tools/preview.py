#!/usr/bin/env python3
"""Reference renderer for the Morrowind-style map.

Reads shared/palette.json and follows the same steps as the Swift
`TileRenderer` (see shared/render-spec.md), so the palette can be tuned on a
desktop without building the apps. Water here comes only from elevation <= 0,
because inland water needs the OpenFreeMap vector tiles, which this script
doesn't decode.

    python3 tools/preview.py --lat 46.0 --lon 7.75 --zoom 11 --size 3 -o preview.png
    python3 tools/preview.py ... --fog-demo        # adds a synthetic explored route
"""
import argparse
import io
import json
import math
import os
import urllib.request

import numpy as np
from PIL import Image

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lat", type=float, default=46.0)
    ap.add_argument("--lon", type=float, default=7.75)
    ap.add_argument("--zoom", type=int, default=11)
    ap.add_argument("--size", type=int, default=3, help="tiles per side")
    ap.add_argument("--fog-demo", action="store_true")
    ap.add_argument("--fog-style", choices=["hidden", "grayed"], default="hidden")
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

    if args.fog_demo:
        fog = pal["fog"]
        mask = fog_mask(demo_cells(args.lat, args.lon), z, tx0, ty0, *dem.shape,
                        fog["edgeSoftnessPx"])[..., None]
        if args.fog_style == "hidden":
            hidden = hex_rgb(fog["hiddenColor"]) * (1 + pal["parchment"]["noiseAmplitude"] *
                     (hash_noise(*np.mgrid[0:dem.shape[1], 0:dem.shape[0]][::-1].astype(np.uint32)) - 0.5) * 2)[..., None]
            hidden = img + (hidden - img) * fog["hiddenOpacity"]
        else:
            gray = img.mean(axis=-1, keepdims=True)
            hidden = (img * (1 - fog["grayedDesaturation"]) + gray * fog["grayedDesaturation"]) * (1 - fog["grayedDarken"])
        img = img * mask + hidden * (1 - mask)

    Image.fromarray(img.astype(np.uint8)).save(args.out)
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
