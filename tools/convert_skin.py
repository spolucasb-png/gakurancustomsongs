#!/usr/bin/env python3
"""One skin converter for every supported game (osu!, Quaver, Etterna).

Auto-detects the skin folder and calls the tested per-format converters
(osu2skin / qua2skin / etterna2skin live on as importable building blocks):
  * skin.ini with a [Mania] section -> osu!mania skin
  * skin.ini with a [4K] section (Quaver) -> Quaver skin
  * Noteskin.lua present -> Etterna noteskin

Usage:
    python tools/convert_skin.py "path/to/skin" --out <Skins dir> [--lane N] [--name X]
"""
import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import etterna2skin as etn
import osu2skin as o2s
import qua2skin as qua


def detect(skin_dir: str) -> str:
    """Return 'osu', 'quaver' or 'etterna'; raise FileNotFoundError if unknown."""
    ini = os.path.join(skin_dir, "skin.ini")
    if os.path.isfile(ini):
        try:
            with open(ini, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            text = ""
        low = text.lower()
        if "[mania]" in low or "[mania" in low:
            return "osu"
        if "[4k]" in low:
            return "quaver"
    if os.path.isfile(os.path.join(skin_dir, "Noteskin.lua")):
        return "etterna"
    if os.path.isfile(ini):
        # osu! skins without a [Mania] section still convert via stable
        # filenames; Quaver skins always carry [4K], so plain skin.ini = osu.
        return "osu"
    raise FileNotFoundError(f"unrecognised skin folder: {skin_dir}")


def main():
    ap = argparse.ArgumentParser(description="Convert a rhythm-game skin (osu!/quaver/etterna) to a GakuranChart pack")
    ap.add_argument("skin_dir", help="skin folder (auto-detected)")
    ap.add_argument("--out", required=True, help="output Skins directory")
    ap.add_argument("--format", choices=("auto", "osu", "quaver", "etterna"), default="auto")
    ap.add_argument("--keys", type=int, default=4, help="key count (osu! only)")
    ap.add_argument("--lane", type=int, default=None, help="1-based base lane (default per format)")
    ap.add_argument("--aspect", type=float, default=1.0)
    ap.add_argument("--name", default=None)
    args = ap.parse_args()

    fmt = args.format if args.format != "auto" else detect(args.skin_dir)
    print(f"format: {fmt}")
    if fmt == "osu":
        o2s.convert_osu_skin(args.skin_dir, args.out, keys=args.keys,
                             lane=args.lane, aspect=args.aspect, name=args.name)
    elif fmt == "quaver":
        qua.convert_quaver_skin(args.skin_dir, args.out, lane=args.lane or 2,
                                aspect=args.aspect, name=args.name)
    elif fmt == "etterna":
        etn.convert_etterna_skin(args.skin_dir, args.out,
                                 aspect=args.aspect, name=args.name)
    else:  # pragma: no cover - argparse constrains this
        ap.error(f"unknown format: {fmt}")


if __name__ == "__main__":
    main()
