#!/usr/bin/env python3
"""One song converter for every supported game (osu!, Etterna, Quaver).

Auto-detects the input by extension and calls the tested per-format
converters (osu2gakuran / sm2gakuran / qua2gakuran live on as importable
building blocks and standalone CLIs); shared output dirs, one rank pass.

Inputs: .osz / .osu (osu!), .sm / .ssc (StepMania/Etterna dance-single),
        .qp / .qua (Quaver Keys), or a directory (every supported file inside,
        .sm/.ssc/.qua searched recursively, .osz/.osu top-level like before).

Usage:
    python tools/convert_song.py <file-or-dir> --charts-dir C --audio-dir A --assets-dir S
    python tools/convert_song.py FunkyChart_v1.23/OSU FunkyChart_v1.23/ETTERNA --charts-dir C ...
"""
import argparse
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import osu2gakuran as osu
import qua2gakuran as qua
import sm2gakuran as sm
from osu2gakuran import MAX_KEYBOARD_LANES, assign_ranks
from zipstage import convert_archive

SONG_DEFAULT_SOURCE = {"osu": "osu", "sm": "etterna", "qua": "quaver"}


def convert_osu_path(osu_path, charts, audio, assets, args):
    kw = dict(mode_override=args.mode, include_nonmania=args.include_nonmania,
              allow_lossy_keys=args.allow_lossy_keys, fold_keys=not args.no_fold,
              max_lanes=args.max_lanes,
              source=args.source or SONG_DEFAULT_SOURCE["osu"])
    if osu_path.suffix.lower() == ".osz":
        return convert_archive(osu_path, "osz", ".osu", osu.convert_file,
                               charts, audio, assets, kw)
    c = osu.convert_file(osu_path, charts, audio, assets, **kw)
    return [c] if c else []


def main():
    ap = argparse.ArgumentParser(description="Convert rhythm-game maps (osu!/sm/qua) to GakuranCharts JSON")
    ap.add_argument("input", type=Path, nargs="+", help=".osz/.osu/.sm/.ssc/.qp/.qua files or directories")
    ap.add_argument("--charts-dir", type=Path, required=True)
    ap.add_argument("--audio-dir", type=Path, required=True)
    ap.add_argument("--assets-dir", type=Path, required=True)
    ap.add_argument("--source", default=None,
                    help="override the origin tag (default: osu/etterna/quaver per input)")
    ap.add_argument("--mode", choices=list(osu.LANES), help="force Gakuran instrument mode (osu! only)")
    ap.add_argument("--include-nonmania", action="store_true")
    ap.add_argument("--allow-lossy-keys", action="store_true")
    ap.add_argument("--no-fold", action="store_true")
    ap.add_argument("--max-lanes", type=int, default=MAX_KEYBOARD_LANES,
                    choices=range(4, MAX_KEYBOARD_LANES + 1))
    args = ap.parse_args()

    osu.begin_batch()
    results = []
    for inp in args.input:
        if inp.is_dir():
            for o in sorted(inp.glob("*.osz")) + sorted(inp.glob("*.osu")):
                results += convert_osu_path(o, args.charts_dir, args.audio_dir,
                                            args.assets_dir, args)
            for s in sorted(inp.rglob("*.sm")) + sorted(inp.rglob("*.ssc")):
                results.extend(sm.convert_file(s, args.charts_dir, args.audio_dir,
                                               args.assets_dir,
                                               source=args.source or SONG_DEFAULT_SOURCE["sm"]))
            for q in sorted(inp.rglob("*.qp")):
                results += qua.convert_qp(
                    q, args.charts_dir, args.audio_dir, args.assets_dir,
                    max_lanes=args.max_lanes, no_fold=args.no_fold,
                    source=args.source or SONG_DEFAULT_SOURCE["qua"])
            for q in sorted(inp.rglob("*.qua")):
                c = qua.convert_file(q, args.charts_dir, args.audio_dir, args.assets_dir,
                                     max_lanes=args.max_lanes, no_fold=args.no_fold,
                                     source=args.source or SONG_DEFAULT_SOURCE["qua"])
                if c:
                    results.append(c)
            continue
        suf = inp.suffix.lower()
        if suf in (".osz", ".osu"):
            results += convert_osu_path(inp, args.charts_dir, args.audio_dir,
                                        args.assets_dir, args)
        elif suf in (".sm", ".ssc"):
            results.extend(sm.convert_file(inp, args.charts_dir, args.audio_dir,
                                           args.assets_dir,
                                           source=args.source or SONG_DEFAULT_SOURCE["sm"]))
        elif suf == ".qp":
            results += qua.convert_qp(
                inp, args.charts_dir, args.audio_dir, args.assets_dir,
                max_lanes=args.max_lanes, no_fold=args.no_fold,
                source=args.source or SONG_DEFAULT_SOURCE["qua"])
        elif suf == ".qua":
            c = qua.convert_file(inp, args.charts_dir, args.audio_dir, args.assets_dir,
                                 max_lanes=args.max_lanes, no_fold=args.no_fold,
                                 source=args.source or SONG_DEFAULT_SOURCE["qua"])
            if c:
                results.append(c)
        else:
            print(f"  - skipped '{inp}': unknown extension", file=sys.stderr)
    ok = assign_ranks(args.charts_dir, results)
    if not ok:
        return 1
    print(f"Done: {len(results)} chart(s) converted")
    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
