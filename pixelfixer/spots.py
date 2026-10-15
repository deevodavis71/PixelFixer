"""Per-photo detection of isolated bright spots (hot pixels missed by the dark-frame map).

A pixel is flagged when it:
  * is brighter than all 8 of its same-colour Bayer neighbours by `threshold` x local noise,
  * is at least twice as bright (above black) as the brightest of those neighbours, and
  * the pixels directly above and below it aren't lit up with it.
Real detail such as lamps, light trails and stars spreads across several pixels and fails
at least one of these tests; a hot pixel passes all three. Hot pixels often bleed into
their left/right neighbours (charge spreads along the sensor's readout rows), so only the
vertical neighbours are checked; the horizontal ones are removed as partners.

Optionally, small *clusters* are also removed: a tight group of at most 6 pixels standing
`threshold` x noise above an otherwise flat 11x11 surround. This catches multi-pixel
defects (plus shapes, pairs, dashes) but would also remove small stars, so it can be
turned off for astrophotography.
"""
import io
import json
import os

import numpy as np
import rawpy
from scipy.ndimage import maximum_filter, median_filter, uniform_filter

from .core import neighbour_residual, repair

RING = np.ones((3, 3), bool)
RING[1, 1] = False


def black_level(data: bytes) -> float:
    with rawpy.imread(io.BytesIO(data)) as r:
        return float(np.mean(r.black_level_per_channel))


def spot_scores(raw: np.ndarray, black: float):
    """Return (per-pixel spot strength in noise sigmas, 0 where not a spot; local noise)."""
    a = raw.astype(np.float32)
    med = np.empty_like(a)
    mx = np.empty_like(a)
    for dy in (0, 1):
        for dx in (0, 1):
            plane = a[dy::2, dx::2]
            med[dy::2, dx::2] = median_filter(plane, footprint=RING, mode="mirror")
            mx[dy::2, dx::2] = maximum_filter(plane, footprint=RING, mode="mirror")
    res = a - med

    noise = local_noise(res)

    lit_neighbour = np.maximum(np.roll(res, 1, 0), np.roll(res, -1, 0))

    isolated = lit_neighbour < 0.33 * res
    stands_out = (a - black) > 2.0 * np.maximum(mx - black, noise)
    return np.where(isolated & stands_out, (a - mx) / noise, 0).astype(np.float32), noise


def local_noise(res):
    """Robust noise estimate from residuals over ~64x64 pixel windows."""
    coarse = 1.4826 * median_filter(np.abs(res)[::8, ::8], size=8, mode="mirror")
    noise = np.kron(coarse, np.ones((8, 8), np.float32))[:res.shape[0], :res.shape[1]]
    return np.maximum(noise, 2.0)


def count_in(mask, size):
    return uniform_filter(mask.astype(np.float32), size=size, mode="constant") * size * size


def cluster_spots(raw, min_score, member_sigma=5.0, max_size=6):
    """Find compact groups of bright pixels on a flat surround.

    Returns a list of (y, x, score, members) like single_spots.
    """
    a = raw.astype(np.float32)
    bg = np.empty_like(a)
    for dy in (0, 1):
        for dx in (0, 1):
            bg[dy::2, dx::2] = median_filter(a[dy::2, dx::2], size=5, mode="mirror")  # 9x9 px
    excess = a - bg
    z = excess / local_noise(excess)

    peak = (z >= min_score) & (excess == maximum_filter(excess, size=5))
    lit = z > member_sigma
    core = count_in(lit, 5)
    busy = np.abs(z) > 4
    surround_busy = count_in(busy, 11) - count_in(busy, 5)
    seeds = np.argwhere(peak & (core <= max_size) & (surround_busy <= 3))

    h, w = raw.shape
    out = []
    for y, x in seeds:
        members = [(yy, xx)
                   for yy in range(max(0, y - 2), min(h, y + 3))
                   for xx in range(max(0, x - 2), min(w, x + 3))
                   if (yy, xx) != (y, x) and lit[yy, xx]]
        out.append((int(y), int(x), float(z[y, x]), members))
    return out


def detect_spots(raw, black, min_score, clusters=True):
    """Find spots scoring >= min_score: isolated pixels, plus small clusters if enabled.

    Returns a list of (y, x, score, partners); partners are other pixels repaired with it.
    """
    spots = single_spots(raw, black, min_score)
    if clusters:
        pix = spot_pixels(spots)
        rest = repair(raw, pix) if len(pix) else raw
        taken = {tuple(p) for p in pix}
        for y, x, score, members in cluster_spots(rest, min_score):
            members = [m for m in members if m not in taken]
            if (y, x) not in taken:
                spots.append((y, x, score, members))
                taken.update([(y, x), *members])
    return spots


def single_spots(raw, black, min_score, partner_sigma=6.0):
    """Find isolated hot pixels scoring >= min_score.

    Returns a list of (y, x, score, partners), where partners are pixels within 2px that the
    spot bleeds into (they only stand out once the spot itself has been repaired).
    """
    scores, noise = spot_scores(raw, black)
    cand = np.argwhere(scores >= min_score)
    if not len(cand):
        return []
    excess = neighbour_residual(repair(raw, cand)) / noise
    h, w = raw.shape
    taken = {tuple(p) for p in cand}
    spots = []
    for y, x in cand:
        partners = []
        for yy in range(max(0, y - 2), min(h, y + 3)):
            for xx in range(max(0, x - 2), min(w, x + 3)):
                if (yy, xx) not in taken and excess[yy, xx] > partner_sigma:
                    partners.append((yy, xx))
                    taken.add((yy, xx))
        spots.append((int(y), int(x), float(scores[y, x]), partners))
    return spots


def spot_pixels(spots, threshold=0.0):
    pix = [(y, x) for y, x, s, partners in spots if s >= threshold for (y, x) in [(y, x), *partners]]
    return np.array(pix, int).reshape(-1, 2)


PREVIEW_MIN_SCORE = 10.0


def find_spots(raw, black, threshold, clusters=True):
    """Detect and repair spots. Returns (repaired raw, number of spots).

    Detection runs at the same floor as the app's preview and is then filtered, so the
    fix removes exactly the spots the preview shows for this threshold.
    """
    spots = detect_spots(raw, black, min(threshold, PREVIEW_MIN_SCORE), clusters)
    pix = spot_pixels(spots, threshold)
    return (repair(raw, pix) if len(pix) else raw), sum(s[2] >= threshold for s in spots)


def analyze(path, out_dir, map_pixels=None, min_score=PREVIEW_MIN_SCORE, clusters=True, max_tiles=5000, tile=24, cols=40):
    """Score every candidate spot in a photo and write before/after zoom crops for the app.

    Writes analysis.json, before.png and after.png (sprite sheets of `tile`-px crops) to out_dir.
    """
    from PIL import Image

    with open(path, "rb") as f:
        data = f.read()
    black = black_level(data)

    with rawpy.imread(io.BytesIO(data)) as r:
        raw = r.raw_image.copy()
        pattern = r.raw_pattern.copy()
        margins = (r.sizes.top_margin, r.sizes.left_margin)

    base = raw
    n_map = 0
    if map_pixels is not None and len(map_pixels):
        inside = (map_pixels[:, 0] < raw.shape[0]) & (map_pixels[:, 1] < raw.shape[1])
        base = repair(raw, map_pixels[inside])
        n_map = int((base != raw).sum())

    spots = sorted(detect_spots(base, black, min_score, clusters), key=lambda s: -s[2])
    # Every spot is counted, but only the strongest max_tiles get zoom crops.
    cand = np.array([(y, x) for y, x, _, _ in spots[:max_tiles]], int).reshape(-1, 2)

    # "After": map pixels and every candidate (with its partners) repaired.
    pix = spot_pixels(spots)
    after_raw = repair(base, pix) if len(pix) else base

    def render(bayer):
        with rawpy.imread(io.BytesIO(data)) as r:
            r.raw_image[:] = bayer
            return r.postprocess(use_camera_wb=True, output_bps=8, bright=1.5,
                                 user_flip=0, fbdd_noise_reduction=rawpy.FBDDNoiseReductionMode.Off)

    os.makedirs(out_dir, exist_ok=True)
    rows = max(1, (len(cand) + cols - 1) // cols)
    for name, bayer in (("before", raw), ("after", after_raw)):
        rgb = render(bayer)
        h, w = rgb.shape[:2]
        sheet = np.zeros((rows * tile, cols * tile, 3), np.uint8)
        for i, (y, x) in enumerate(cand):
            # raw coords -> rendered image coords (LibRaw crops the margins)
            cy, cx = y - margins[0], x - margins[1]
            y0 = int(np.clip(cy - tile // 2, 0, h - tile))
            x0 = int(np.clip(cx - tile // 2, 0, w - tile))
            r_, c_ = divmod(i, cols)
            sheet[r_ * tile:(r_ + 1) * tile, c_ * tile:(c_ + 1) * tile] = rgb[y0:y0 + tile, x0:x0 + tile]
        Image.fromarray(sheet).save(os.path.join(out_dir, f"{name}.png"))

    doc = {
        "file": os.path.basename(path),
        "map_pixels_fixed": n_map,
        "tile": tile,
        "cols": cols,
        "min_score": min_score,
        "spots": [{"y": y, "x": x, "score": round(s, 1), "partners": len(p),
                   "tile": i if i < len(cand) else -1}
                  for i, (y, x, s, p) in enumerate(spots)],
    }
    with open(os.path.join(out_dir, "analysis.json"), "w") as f:
        json.dump(doc, f)
    return doc
