"""pixelfixer — remove hot/dead pixels from Nikon NEF raw files on macOS."""
import argparse
import os
import shutil
import sys

import numpy as np

from . import core
from .nef import parse_nef


def cmd_map(args):
    hot_all, dead_all, model, shape = [], [], None, None
    for path in args.darkframes:
        with open(path, "rb") as f:
            data = f.read()
        info = parse_nef(data)
        raw = core.read_raw(data)
        if shape and raw.shape != shape:
            sys.exit(f"{path}: size {raw.shape} differs from previous frames {shape}")
        model, shape = info.model, raw.shape
        hot, dead, sigma = core.detect(raw, args.sigma, args.min_adu, dead=not args.no_dead)
        print(f"{os.path.basename(path)}: {info.model}, noise σ≈{sigma:.1f} ADU, "
              f"{len(hot)} hot, {len(dead)} dead (threshold {args.sigma}σ)")
        hot_all.append(hot)
        dead_all.append(dead)
    hot = np.unique(np.vstack(hot_all), axis=0)
    dead = np.unique(np.vstack(dead_all), axis=0)
    doc = core.save_map(args.output, model, shape, hot, dead,
                        [os.path.basename(p) for p in args.darkframes], args.sigma)
    print(f"Wrote {args.output}: {len(doc['pixels'])} pixels")


def cmd_fix(args):
    pixels = None
    if args.map:
        pixels, cams, dims = core.load_maps(args.map)
        print(f"Loaded {len(pixels)} pixels from {len(args.map)} map(s) [{', '.join(sorted(cams))}]")
    elif not args.spots:
        sys.exit("Give a pixel map (--map) and/or --spots STRENGTH")

    if not args.in_place:
        os.makedirs(args.output_dir, exist_ok=True)

    failures = 0
    for src in args.files:
        name = os.path.basename(src)
        try:
            if args.in_place:
                if args.backup:
                    shutil.copy2(src, src + ".orig")
                dst = src
            else:
                dst = os.path.join(args.output_dir, name)
                if os.path.abspath(dst) == os.path.abspath(src):
                    raise ValueError("output would overwrite the original; use --in-place")
            n = core.fix_file(src, dst, pixels, args.spots, not args.no_clusters,
                              verify=not args.no_verify,
                              cameras=cams if pixels is not None else None, log=print)
            print(f"{name}: fixed {n} pixels -> {dst}")
        except Exception as e:  # keep going with the rest of the batch
            failures += 1
            print(f"{name}: ERROR {e}", file=sys.stderr)
    sys.exit(1 if failures else 0)


def cmd_analyze(args):
    from .spots import analyze
    pixels = core.load_maps(args.map)[0] if args.map else None
    doc = analyze(args.file, args.out_dir, pixels, min_score=args.min_score,
                  clusters=not args.no_clusters)
    print(f"{doc['file']}: {doc['map_pixels_fixed']} map pixels, {len(doc['spots'])} candidate spots")


def main(argv=None):
    p = argparse.ArgumentParser(prog="pixelfixer", description=__doc__)
    sub = p.add_subparsers(required=True)

    m = sub.add_parser("map", help="build a hot-pixel map from dark frame(s) (lens cap on, long exposure)")
    m.add_argument("darkframes", nargs="+")
    m.add_argument("-o", "--output", default="hotpixels.json")
    m.add_argument("-s", "--sigma", type=float, default=10.0,
                   help="detection threshold in noise standard deviations (default 10; lower finds more)")
    m.add_argument("--min-adu", type=int, default=0, help="also require at least this many ADU above neighbours")
    m.add_argument("--no-dead", action="store_true", help="don't include dead (dark) pixels")
    m.set_defaults(func=cmd_map)

    f = sub.add_parser("fix", help="repair raw files using a pixel map")
    f.add_argument("files", nargs="+")
    f.add_argument("-m", "--map", action="append", help="pixel map JSON (repeatable)")
    f.add_argument("-o", "--output-dir", default="fixed", help="where to write repaired files (default ./fixed)")
    f.add_argument("--no-clusters", action="store_true",
                   help="with --spots, only remove single-pixel spots, not small clusters "
                        "(use for star photos)")
    f.add_argument("--in-place", action="store_true", help="overwrite the originals")
    f.add_argument("--no-backup", dest="backup", action="store_false",
                   help="with --in-place, don't keep a .orig copy")
    f.add_argument("-s", "--spots", type=float, metavar="STRENGTH",
                   help="also remove isolated bright spots found in each photo that stand out by at "
                        "least STRENGTH x noise (try 20-30; lower removes fainter spots)")
    f.add_argument("--no-verify", action="store_true", help=argparse.SUPPRESS)
    f.set_defaults(func=cmd_fix)

    a = sub.add_parser("analyze", help="score candidate spots in a photo and render before/after crops")
    a.add_argument("file")
    a.add_argument("-m", "--map", action="append")
    a.add_argument("-o", "--out-dir", required=True)
    a.add_argument("--min-score", type=float, default=10.0)
    a.add_argument("--no-clusters", action="store_true")
    a.set_defaults(func=cmd_analyze)

    args = p.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
