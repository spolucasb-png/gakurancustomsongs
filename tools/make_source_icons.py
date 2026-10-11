#!/usr/bin/env python3
"""One-off: paint 32x32 source-icon discs (pure stdlib, no PIL).

Usage: python tools/make_source_icons.py <outdir>
Writes osu.png (pink), local.png (blue), unknown.png (grey): a filled disc
on a transparent background. The loader maps chart `source` -> these files
(GakuranCharts/Assets/icons/<source>.png) and falls back to text tags when
a file is missing, so adding a new source later is just a new PNG.
"""
import struct
import sys
import zlib
from pathlib import Path

COLORS = {
    "osu": (237, 127, 168),
    "local": (138, 180, 255),
    "unknown": (138, 140, 160),
    "etterna": (60, 110, 200),
    "quaver": (255, 170, 40),
}

SIZE = 32


def disc_png(rgb):
    r = SIZE / 2 - 1
    raw = bytearray()
    for y in range(SIZE):
        raw.append(0)  # filter: none
        for x in range(SIZE):
            dx, dy = x - SIZE / 2 + 0.5, y - SIZE / 2 + 0.5
            if dx * dx + dy * dy <= r * r:
                raw.extend((*rgb, 255))
            else:
                raw.extend((0, 0, 0, 0))
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xFFFFFFFF)
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def main():
    outdir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("GakuranCharts/Assets/icons")
    outdir.mkdir(parents=True, exist_ok=True)
    for name, rgb in COLORS.items():
        (outdir / f"{name}.png").write_bytes(disc_png(rgb))
        print(f"wrote {outdir / (name + '.png')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
