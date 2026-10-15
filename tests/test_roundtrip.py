"""Run with: python3 -m pytest tests  (uses the sample NEF in the project root if present)."""
import glob
import os

import numpy as np
import pytest

from pixelfixer import core, nef

SAMPLES = glob.glob(os.path.join(os.path.dirname(__file__), "..", "*.NEF"))


@pytest.mark.parametrize("path", SAMPLES)
def test_encoder_reproduces_original_bitstream(path):
    data = open(path, "rb").read()
    info = nef.parse_nef(data)
    raw = core.read_raw(data)
    original = data[info.strip_offset:info.strip_offset + info.strip_bytes]
    assert core.encoder_for(info)(raw) == original


@pytest.mark.parametrize("path", SAMPLES)
def test_fix_changes_only_mapped_pixels(path, tmp_path):
    raw = core.read_raw(open(path, "rb").read())
    hot, dead, _ = core.detect(raw)
    pixels = np.vstack([hot, dead])
    out = tmp_path / "out.NEF"
    core.fix_file(path, str(out), pixels, log=lambda *a: None)
    fixed = core.read_raw(out.read_bytes())
    changed = np.argwhere(fixed != raw)
    assert {tuple(p) for p in changed} <= {tuple(p) for p in pixels}
