# PixelFixer for Mac

Removes hot and dead pixels from Nikon NEF raw files. Like the Windows
[Pixel Fixer](https://pixelfixer.org/), it edits the raw sensor data itself, so
the output is still a normal NEF. Lightroom, Capture One, NX Studio and Apple
Photos all open it as usual, and the metadata and embedded previews are unchanged.

## Acknowledgements

This project was inspired by [Pixel Fixer](https://pixelfixer.org/), Thomas
Comerford's freeware hot-pixel remover for Windows. PixelFixer for Mac is a
complete, independent rewrite. **No code from Pixel Fixer has been copied or
used**: the original was only the inspiration for the idea of repairing hot
pixels directly in the raw file. This project isn't affiliated with or endorsed
by Pixel Fixer or its author.

## How it works

1. **Map.** A dark frame (lens cap on, long exposure, high ISO) is analysed. Any
   pixel that stands out from its same-colour Bayer neighbours by more than N×
   the noise level is recorded in a JSON map.
2. **Fix.** For each mapped pixel, the raw value is replaced with the median of
   its nearest good same-colour neighbours. Then the image is re-compressed with
   Nikon's own lossless Huffman scheme and written back into the NEF. Only the
   raw data and its byte-count tag change.

### Safety checks (every file)
- Before changing anything, the original raw data is re-encoded. The result must
  match the camera's bitstream **byte for byte**. If it doesn't, the file is
  skipped.
- After repair, the new file is decoded again and checked against the intended
  pixel values.
- Output is written atomically to a separate folder by default. The original is
  only overwritten if you use `--in-place`, which also keeps a `.orig` backup
  unless you add `--no-backup`.

## Spots the map misses

Hot pixels depend on exposure length, temperature and ISO. A 30s ISO 3200 dark
frame doesn't catch every pixel that lights up in an 88s ISO 100 exposure. So
PixelFixer can also look for spots in each photo, with two detectors.

**Single hot pixels.** A pixel is removed if:
- it is brighter than all 8 of its same-colour neighbours by at least the
  threshold × local noise;
- it is at least twice as bright (above black) as the brightest of those
  neighbours;
- the pixels directly above and below it aren't lit.

Hot pixels on this sensor often bleed into their **left/right** neighbours,
which shows up as a white dash. Those neighbours and any others within 2px are
removed with the hot pixel. Lamps, light trails and other real detail fail the
tests above.

**Small clusters** (on by default; `--no-clusters` or the app's *Clusters*
switch turns them off). This catches tight groups of up to 6 bright pixels, such
as plus shapes and pairs, on an otherwise flat surround. Turn it off for star
photos, because small stars look similar.

The threshold is in multiples of local noise. 20–30 is the useful range: on
DSC_5136 that removes 120–280 spots. Below about 15 it starts removing thousands
of plain noise speckles. The app's slider goes down to 10, which matches the
lowest score the Preview analyses.

## Mac app

`app/build/PixelFixer.app` is a drag-and-drop front end for the same engine.

- **Left panel:** drop a dark frame to create a named hot-pixel map. Maps are
  stored in `~/Library/Application Support/PixelFixer/maps`. The Z 6 map from
  `maps/` is installed automatically.
- **Right panel:** drop NEF files or folders to fix them using the selected map.
- You can also drop files on the Dock icon, or use **Open With → PixelFixer**.
- **Remove spots** plus the **Threshold** slider and the **Clusters** switch:
  finds hot pixels in each photo that the map missed (see below). Lower
  values remove fainter spots. **Preview…** opens a window where you drop a
  photo and see before/after zooms of every spot at the current threshold,
  weakest first, with the ones just below the line shown as kept.
- **Save to:** either a `Fixed` folder next to the originals (the default), or
  overwrite the originals, with an optional `.orig` backup.
- **Help:** **Help → PixelFixer Help** (⌘?) or the **?** buttons open a
  built-in guide covering dark frames, fixing, spot removal, the preview, file
  safety and troubleshooting.

## Building from source (macOS 14 or later)

You need:
- **Xcode command-line tools.** Full Xcode isn't required. Install with
  `xcode-select --install`.
- **Python 3 from Homebrew** (<https://brew.sh>): `brew install python`. The app
  runs the engine with Homebrew's `python3`, from `/opt/homebrew/bin` on Apple
  silicon or `/usr/local/bin` on Intel.

```sh
git clone <repo-url> PixelFixer
cd PixelFixer

# Install the engine and its dependencies (numpy, scipy, rawpy, pillow) into
# Homebrew's Python. This also gives you the `pixelfixer` command.
python3 -m pip install --break-system-packages -e .

# Build the app for this Mac's architecture -> app/build/PixelFixer.app
app/build.sh

# Optional: install it
cp -R app/build/PixelFixer.app /Applications/
```

Notes:
- `--break-system-packages` is required because Homebrew's Python refuses
  plain `pip install` (PEP 668). The packages go into Homebrew's Python only,
  not macOS's own Python.
- The build copies the `pixelfixer/` package into the app, so rebuild after
  changing any Python code. The app still needs the Python dependencies
  installed as above.
- Any maps in `maps/` are bundled into the app and installed on first launch.
  Maps are specific to one camera body, so make your own from a dark frame.
- The app is ad-hoc signed for the Mac it was built on. If you copy it to
  another Mac, macOS Gatekeeper will block it; right-click it and choose
  **Open** the first time.
- Tests: put a lossless-compressed NEF in the project root, then run
  `python3 -m pip install --break-system-packages pytest && python3 -m pytest tests`.
  Raw files are git-ignored.

## Command line

```sh
pip install -e .            # already done on this Mac; gives the `pixelfixer` command

# 1. Build a map from one or more dark frames (the maps are combined)
pixelfixer map DSC_5141.NEF -o maps/nikon_z6.json

# 2. Fix photos (repaired copies go to ./fixed/)
pixelfixer fix ~/Pictures/Shoot/*.NEF -m maps/nikon_z6.json

#    ...or write somewhere else / overwrite the originals
pixelfixer fix *.NEF -m maps/nikon_z6.json -o ~/Pictures/Fixed
pixelfixer fix *.NEF -m maps/nikon_z6.json --in-place
```

Options:
- `map -s 8`: lower threshold, finds more (weaker) hot pixels. The default is 10σ.
- `map --no-dead`: map only hot pixels.
- `fix --spots 25`: also removes isolated spots found in each photo, with that
  threshold. Use the app's Preview, or `pixelfixer analyze`, to check the setting
  on astro shots.

Tips: hot pixels get worse with heat, exposure length and ISO. Take your dark
frame at settings like your worst-case shots (for example 30s at ISO 3200). Turn
long-exposure NR off. Re-map every few months, because sensors develop new hot
pixels over time.

## Supported files
- Nikon NEF, **lossless compressed** 12/14-bit (tested on the Z 6)
- Uncompressed NEF (the round-trip check will refuse a file if the layout isn't as expected)
- Not supported: lossy compressed and High Efficiency (HE/HE*) NEFs. The tool
  refuses these with an error and does not modify them.

## Tests
```sh
python3 -m pytest tests     # uses any *.NEF in the project root
```
