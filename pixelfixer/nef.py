"""Minimal TIFF/NEF structure reader and in-place raw strip rewriter."""
import struct
from dataclasses import dataclass

TYPE_SIZES = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4}


@dataclass
class Entry:
    tag: int
    type: int
    count: int
    value_pos: int  # file offset of the value (inline or pointed-to)


class Tiff:
    def __init__(self, data: bytes):
        self.data = data
        self.bo = {b"II": "<", b"MM": ">"}[data[:2]]
        self.ifd0 = self.u32(4)

    def u16(self, pos, base_bo=None):
        return struct.unpack_from((base_bo or self.bo) + "H", self.data, pos)[0]

    def u32(self, pos, base_bo=None):
        return struct.unpack_from((base_bo or self.bo) + "I", self.data, pos)[0]

    def read_ifd(self, pos, base=0, bo=None):
        bo = bo or self.bo
        n = self.u16(pos, bo)
        entries = {}
        for i in range(n):
            e = pos + 2 + 12 * i
            tag, typ, count = struct.unpack_from(bo + "HHI", self.data, e)
            size = TYPE_SIZES.get(typ, 1) * count
            vpos = e + 8 if size <= 4 else base + self.u32(e + 8, bo)
            entries[tag] = Entry(tag, typ, count, vpos)
        return entries

    def values(self, entry, bo=None):
        bo = bo or self.bo
        if entry.type == 3:
            return list(struct.unpack_from(bo + f"{entry.count}H", self.data, entry.value_pos))
        if entry.type in (4, 13):
            return list(struct.unpack_from(bo + f"{entry.count}I", self.data, entry.value_pos))
        return self.data[entry.value_pos:entry.value_pos + entry.count]


@dataclass
class RawInfo:
    width: int
    height: int
    bps: int
    compression: int
    strip_offset: int
    strip_bytes: int
    bytecount_entry: Entry
    offset_entry: Entry
    model: str
    nef_meta: bytes  # NEFLinearizationTable (makernote 0x0096)
    meta_byte_order: str

    @property
    def vpred(self):
        """Initial vertical predictors for the compressed bitstream."""
        return list(struct.unpack_from(self.meta_byte_order + "4H", self.nef_meta, 2))


def parse_nef(data: bytes) -> RawInfo:
    t = Tiff(data)
    ifd0 = t.read_ifd(t.ifd0)
    model = t.values(ifd0[0x0110]).rstrip(b"\0").decode(errors="replace") if 0x0110 in ifd0 else "?"

    raw = None
    for sub in t.values(ifd0.get(0x014A)) if 0x014A in ifd0 else []:
        ifd = t.read_ifd(sub)
        if 0x00FE in ifd and t.values(ifd[0x00FE])[0] == 0 and 0x0111 in ifd:
            raw = ifd
    if raw is None:
        raise ValueError("No full-resolution raw image found (not a NEF?)")
    for tag in (0x0111, 0x0117):
        if raw[tag].count != 1:
            raise ValueError("Multi-strip raw data is not supported")

    # Nikon makernote -> tag 0x0096 holds compression version + predictor seeds.
    exif = t.read_ifd(t.values(ifd0[0x8769])[0])
    mn = exif[0x927C].value_pos
    if data[mn:mn + 6] != b"Nikon\0":
        raise ValueError("Unrecognised Nikon makernote")
    base = mn + 10
    mbo = {b"II": "<", b"MM": ">"}[data[base:base + 2]]
    mifd = t.read_ifd(base + t.u32(base + 4, mbo), base=base, bo=mbo)
    meta = t.values(mifd[0x0096], mbo) if 0x0096 in mifd else b""

    return RawInfo(
        width=t.values(raw[0x0100])[0], height=t.values(raw[0x0101])[0],
        bps=t.values(raw[0x0102])[0], compression=t.values(raw[0x0103])[0],
        strip_offset=t.values(raw[0x0111])[0], strip_bytes=t.values(raw[0x0117])[0],
        bytecount_entry=raw[0x0117], offset_entry=raw[0x0111], model=model, nef_meta=meta, meta_byte_order=mbo,
    )


def replace_strip(data: bytes, info: RawInfo, new_strip: bytes) -> bytes:
    """Return a copy of the file with the raw strip replaced, fixing offset/bytecount tags."""
    buf = bytearray(data)
    bo = {b"II": "<", b"MM": ">"}[data[:2]]
    end = info.strip_offset + info.strip_bytes
    if end == len(data) or len(new_strip) <= info.strip_bytes:
        # Raw data is last in the file (the usual case), or the new strip fits in place.
        offset = info.strip_offset
        tail = b"" if end == len(data) else bytes(info.strip_bytes - len(new_strip)) + data[end:]
        buf[offset:] = new_strip + tail
    else:  # append at end of file, word aligned; the old strip becomes unused
        buf += bytes(-len(buf) % 4)
        offset = len(buf)
        buf += new_strip
    _put(buf, info.offset_entry, offset, bo)
    _put(buf, info.bytecount_entry, len(new_strip), bo)
    return bytes(buf)


def _put(buf, entry, value, bo):
    if entry.type == 3:
        if value > 0xFFFF:
            raise ValueError("Value too large for SHORT tag")
        struct.pack_into(bo + "H", buf, entry.value_pos, value)
    else:
        struct.pack_into(bo + "I", buf, entry.value_pos, value)
