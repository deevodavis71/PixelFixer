"""Hot/dead pixel detection and repair on Bayer raw data."""
import io
import json
import os
import tempfile
from datetime import datetime, timezone

import numpy as np
import rawpy
from scipy.ndimage import median_filter

from . import nikon_codec
from .nef import parse_nef, replace_strip

MAP_VERSION = 1


def read_raw(data: bytes) -> np.ndarray:
    with rawpy.imread(io.BytesIO(data)) as r:
        return r.raw_image.copy()


def neighbour_residual(raw: np.ndarray) -> np.ndarray:
    """Pixel value minus the median of its 3x3 same-colour neighbourhood."""
    a = raw.astype(np.int32)
    res = np.empty_like(a)
    for dy in (0, 1):
        for dx in (0, 1):
            plane = a[dy::2, dx::2]
            res[dy::2, dx::2] = plane - median_filter(plane, size=3, mode="mirror")
    return res


def detect(raw: np.ndarray, sigma_k: float = 10.0, min_adu: int = 0, dead: bool = True):
    """Find pixels that stand out from same-colour neighbours.

    Returns (hot, dead, sigma) where hot/dead are (N, 2) arrays of (row, col).
    """
    res = neighbour_residual(raw)
    sigma = 1.4826 * float(np.median(np.abs(res)))  # robust noise estimate
    thresh = max(sigma_k * sigma, min_adu)
    hot = np.argwhere(res > thresh)
    cold = np.argwhere(res < -thresh) if dead else np.empty((0, 2), int)
    return hot, cold, sigma


def repair(raw: np.ndarray, pixels: np.ndarray) -> np.ndarray:
    """Replace each listed pixel with the median of its nearest good same-colour neighbours."""
    out = raw.copy()
    h, w = raw.shape
    bad = np.zeros(raw.shape, bool)
    bad[pixels[:, 0], pixels[:, 1]] = True
    for y, x in pixels:
        for radius in (2, 4, 6):  # widen the search if a cluster hides all neighbours
            vals = [raw[yy, xx]
                    for yy in range(y - radius, y + radius + 1, 2)
                    for xx in range(x - radius, x + radius + 1, 2)
                    if (yy, xx) != (y, x) and 0 <= yy < h and 0 <= xx < w and not bad[yy, xx]]
            if len(vals) >= 3:
                out[y, x] = int(np.median(vals))
                break
    return out


def encoder_for(info):
    """Return a function raw->strip bytes for this file's raw encoding, or raise."""
    if info.compression == 34713:
        if not info.nef_meta or info.nef_meta[0] != 0x46:
            raise ValueError("Only lossless-compressed and uncompressed NEFs are supported "
                             "(this file uses lossy or high-efficiency compression)")
        return lambda raw: nikon_codec.encode(raw, info.vpred, info.bps)
    if info.compression == 1 and info.bps in (12, 14, 16):
        bo = info.meta_byte_order
        return lambda raw: raw.astype(bo + "u2").tobytes()
    raise ValueError(f"Unsupported raw compression {info.compression}")


# --- pixel maps ----------------------------------------------------------------

def save_map(path, model, shape, hot, dead, sources, sigma_k):
    pix = sorted({(int(y), int(x)) for y, x in np.vstack([hot, dead])})
    doc = {
        "version": MAP_VERSION,
        "camera": model,
        "width": int(shape[1]),
        "height": int(shape[0]),
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "sources": sources,
        "threshold_sigma": sigma_k,
        "hot_count": int(len(hot)),
        "dead_count": int(len(dead)),
        "pixels": pix,
    }
    with open(path, "w") as f:
        json.dump(doc, f, indent=1)
    return doc


def load_maps(paths):
    pixels, cams, dims = set(), set(), set()
    for p in paths:
        with open(p) as f:
            doc = json.load(f)
        pixels.update(map(tuple, doc["pixels"]))
        cams.add(doc["camera"])
        dims.add((doc["height"], doc["width"]))
    return np.array(sorted(pixels), int).reshape(-1, 2), cams, dims


# --- file processing -----------------------------------------------------------

def fix_file(src, dst, map_pixels=None, spot_threshold=None, clusters=True, verify=True, cameras=None, log=print):
    """Repair a NEF and write it to dst. Returns number of pixels changed."""
    with open(src, "rb") as f:
        data = f.read()
    info = parse_nef(data)
    encode = encoder_for(info)
    if cameras and info.model not in cameras:
        log(f"  warning: map is for {', '.join(sorted(cameras))} but this file is from {info.model}")
    raw = read_raw(data)
    if raw.shape != (info.height, info.width):
        raise ValueError(f"Decoded size {raw.shape} doesn't match header {info.height}x{info.width}")

    # Safety check: our encoder must reproduce the camera's original bitstream exactly,
    # otherwise we can't be sure the rewritten file is lossless.
    original = data[info.strip_offset:info.strip_offset + info.strip_bytes]
    if encode(raw) != original:
        raise ValueError("Re-encoding the original raw data didn't reproduce the file exactly; "
                         "refusing to modify it")

    fixed = raw
    if map_pixels is not None and len(map_pixels):
        inside = (map_pixels[:, 0] < raw.shape[0]) & (map_pixels[:, 1] < raw.shape[1])
        fixed = repair(fixed, map_pixels[inside])
    n_map = int((fixed != raw).sum())
    if spot_threshold:
        from .spots import black_level, find_spots
        fixed, n_spots = find_spots(fixed, black_level(data), spot_threshold, clusters)
    changed = int((fixed != raw).sum())
    if not changed:
        log("  nothing to fix")
        return 0
    if spot_threshold:
        log(f"  {n_map} pixels from map, {n_spots} spots found in photo")
    out = replace_strip(data, info, encode(fixed))

    if verify and read_raw(out).tobytes() != fixed.tobytes():
        raise ValueError("Verification failed: rewritten file doesn't decode to the repaired data")

    # Atomic write so a crash never leaves a half-written raw file.
    d = os.path.dirname(os.path.abspath(dst))
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    with os.fdopen(fd, "wb") as f:
        f.write(out)
    st = os.stat(src)
    os.utime(tmp, (st.st_atime, st.st_mtime))
    os.replace(tmp, dst)
    return changed
