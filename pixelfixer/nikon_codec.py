"""Nikon NEF lossless-compressed raw encoder (inverse of dcraw/LibRaw nikon_load_raw)."""
import numpy as np

# Huffman tables from dcraw: 16 code-length counts followed by symbols.
NIKON_TREES = {
    "12-bit lossless": ([0, 1, 4, 2, 3, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0],
                        [5, 4, 6, 3, 7, 2, 8, 1, 9, 0, 10, 11, 12]),
    "14-bit lossless": ([0, 1, 4, 2, 2, 3, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0],
                        [7, 6, 8, 5, 9, 4, 10, 3, 11, 12, 2, 0, 1, 13, 14]),
}


def canonical_codes(counts, symbols):
    """Return {symbol: (code, length)} for a canonical (JPEG-style) Huffman table."""
    table, code, k = {}, 0, 0
    for length in range(1, 17):
        for _ in range(counts[length - 1]):
            table[symbols[k]] = (code, length)
            code += 1
            k += 1
        code <<= 1
    return table


def encode(raw, vpred_init, bps):
    """Encode a (rows, cols) uint16 Bayer array into a Nikon lossless bitstream."""
    tree = NIKON_TREES["14-bit lossless" if bps == 14 else "12-bit lossless"]
    table = canonical_codes(*tree)
    code_lut = np.zeros(16, np.uint32)
    len_lut = np.zeros(16, np.uint8)
    for sym, (c, l) in table.items():
        code_lut[sym], len_lut[sym] = c, l

    v = raw.astype(np.int32)
    diff = np.empty_like(v)
    diff[:, 2:] = v[:, 2:] - v[:, :-2]
    # First two columns predict from two rows up (same CFA colour); rows 0/1 from vpred.
    diff[2:, :2] = v[2:, :2] - v[:-2, :2]
    diff[:2, :2] = v[:2, :2] - np.asarray(vpred_init, np.int32).reshape(2, 2)
    diff = diff.ravel()

    mag = np.abs(diff)
    nbits = np.zeros(mag.shape, np.uint8)
    nz = mag > 0
    nbits[nz] = np.floor(np.log2(mag[nz])).astype(np.uint8) + 1
    extra = np.where(diff >= 0, diff, diff + (1 << nbits.astype(np.int64)) - 1).astype(np.uint64)

    hlen = len_lut[nbits].astype(np.uint64)
    total_len = hlen + nbits
    word = (code_lut[nbits].astype(np.uint64) << nbits.astype(np.uint64)) | extra

    ends = np.cumsum(total_len, dtype=np.uint64)
    starts = ends - total_len
    total_bits = int(ends[-1])
    bits = np.zeros(((total_bits + 7) // 8) * 8, np.uint8)
    maxlen = int(total_len.max())
    tl = total_len.astype(np.int64)
    for k in range(maxlen):  # bit k counted from the MSB of each word
        sel = tl > k
        shift = (tl[sel] - 1 - k).astype(np.uint64)
        bits[(starts[sel] + np.uint64(k)).astype(np.int64)] = ((word[sel] >> shift) & np.uint64(1)).astype(np.uint8)
    pad = len(bits) - total_bits
    if pad:
        bits[total_bits:] = 1  # Nikon pads the final byte with 1-bits
    return np.packbits(bits).tobytes()
