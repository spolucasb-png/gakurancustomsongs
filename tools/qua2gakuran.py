#!/usr/bin/env python3
"""Quaver .qp/.qua (Keys) -> GakuranCharts JSON converter.

Same chart schema as tools/osu2gakuran.py (formatVersion 1, beats-based
notes, scrollChanges/animationBpmChanges, songId/tier/rank grouping) and the
same shared helpers (imported from osu2gakuran, not copied). No PyYAML
dependency: .qua files are parsed with a small targeted reader for exactly
the fields a conversion needs.

Mapping notes:
  * .qua clock is milliseconds; beats use the FIRST timing point as reference
    (same simplification as the osu! converter, so SV/BPM math stays consistent)
  * HitObjects: StartTime/Lane taps, EndTime holds; KeySounds ignored
  * SliderVelocities (StartTime ms + Multiplier) -> scrollChanges, consecutive
    equal rates collapsed; rates kept verbatim (negatives, zero, extremes) and
    beats stored with BEAT_DECIMALS so sub-0.03 ms spike pairs survive
  * TimingPoints[1:] -> animationBpmChanges
  * Keys4 needs no fold; 5K-7K convert 1:1 with a "lanes" field (loader 2.0.19+),
    8K+ fold to --max-lanes, mirroring the osu! converter's policy

Usage:
    python tools/qua2gakuran.py song.qp --charts-dir C --audio-dir A --assets-dir S
    python tools/qua2gakuran.py map.qua --charts-dir C ...   (single difficulty)
    python tools/qua2gakuran.py qua_dir/ --charts-dir C ...  (every .qua inside)
"""
import argparse
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osu2gakuran import (FORMAT_VERSION, LANES, MAX_KEYBOARD_LANES, assign_ranks,
                         begin_batch, fold_columns, place_media, sanitize_id, tier_for,
                         write_chart_json)

LIST_SECTIONS = ("TimingPoints", "SliderVelocities", "HitObjects")

# Decimals kept for beat positions (note b/d and SV b). 4 decimals is a 0.0308 ms
# step at 195 BPM, which is WIDER than the 0.0156 ms (1/64 ms) teleport spikes some
# Quaver SV maps use (e.g. +9856 / -9856 / 1.0 within 0.03 ms): rounding merged the
# cancelling point away and left permanent scroll offsets. 10 decimals is ~3e-8 ms.
BEAT_DECIMALS = 10


def parse_qua(text: str):
    """Return (scalars, lists) for the fields a conversion needs."""
    scalars, lists = {}, {k: [] for k in LIST_SECTIONS}
    cur, item = None, None
    for raw in text.splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent == 0 and ":" in s and not s.startswith("-"):
            k, v = s.split(":", 1)
            k, v = k.strip(), v.strip()
            if k in lists:
                cur = k if v == "" else None
                item = None
                continue
            cur, item = None, None
            scalars[k] = v
        elif cur and s.startswith("- "):
            item = {}
            lists[cur].append(item)
            rest = s[2:].strip()
            if ":" in rest:
                k, v = rest.split(":", 1)
                item[k.strip()] = v.strip()
        elif cur and item is not None and ":" in s and not s.startswith("-"):
            k, v = s.split(":", 1)
            item[k.strip()] = v.strip()
    return scalars, lists


def fnum(v, default=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def convert_file(qua_path: Path, out_dir: Path, audio_dir: Path, asset_dir: Path,
                 max_lanes=MAX_KEYBOARD_LANES, no_fold=False, source="quaver"):
    scalars, lists = parse_qua(qua_path.read_text(encoding="utf-8", errors="replace"))

    m = re.match(r"Keys(\d+)$", scalars.get("Mode", ""))
    if not m:
        print(f"  - skipped '{qua_path.name}': Mode {scalars.get('Mode', '?')} is not Keys",
              file=sys.stderr)
        return None
    keys = max(1, min(18, int(m.group(1))))
    lane_cap = LANES.get("Keyboard", 4)
    if keys > lane_cap and max_lanes > lane_cap:
        lane_cap = min(keys, min(max_lanes, MAX_KEYBOARD_LANES))
    fold = keys > lane_cap and not no_fold
    if keys > lane_cap and not fold:
        print(f"  - skipped '{qua_path.name}': {keys}K exceeds {lane_cap} lanes "
              f"(drop --no-fold to fold it)", file=sys.stderr)
        return None

    tps = [(fnum(i.get("StartTime")), fnum(i.get("Bpm"))) for i in lists["TimingPoints"]]
    tps = [(t, b) for t, b in tps if b > 0]
    tps.sort()
    if not tps:
        print(f"  ! ERROR: no timing points in '{qua_path.name}'", file=sys.stderr)
        return None
    ref_bl = 60000.0 / tps[0][1]
    ref_bpm = round(tps[0][1], 4)

    raw, notes, warnings = [], [], []
    for h in lists["HitObjects"]:
        t = fnum(h.get("StartTime"))
        col = int(fnum(h.get("Lane"), 1))
        col = max(1, min(keys, col))
        end = fnum(h["EndTime"]) if "EndTime" in h else None
        if end is not None and end <= t:
            end = None  # degenerate hold: keep the tap
        if fold:
            raw.append((t, end, col))
        else:
            notes.append({"b": round(t / ref_bl, BEAT_DECIMALS), "l": col,
                          "d": round((end - t) / ref_bl, BEAT_DECIMALS) if end else 0})
    fold_note = ""
    if fold:
        placed, stats = fold_columns(raw, keys, lane_cap)
        for t, end, lane in placed:
            notes.append({"b": round(t / ref_bl, BEAT_DECIMALS), "l": lane,
                          "d": round((end - t) / ref_bl, BEAT_DECIMALS) if end is not None else 0})
        fold_note = f", folded {keys}K->{lane_cap} lanes"
        warnings.append(f"folded {keys}K -> {lane_cap} lanes: {stats['source']} objects, "
                        f"{stats['kept']} kept, {stats['rerouted']} rerouted, "
                        f"{stats['dropped']} dropped")
    notes.sort(key=lambda n: (n["b"], n["l"]))
    if not notes:
        print(f"  ! ERROR: no convertible hit objects in '{qua_path.name}'", file=sys.stderr)
        return None

    title = scalars.get("Title", "Unknown").strip() or "Unknown"
    artist = scalars.get("Artist", "Unknown").strip() or "Unknown"
    creator = scalars.get("Creator", "Unknown").strip() or "Unknown"
    diffname = scalars.get("DifficultyName", "Normal").strip() or "Normal"
    id_stem = title
    if not re.search(r"[a-zA-Z0-9]", title):
        set_id = scalars.get("MapSetId", "").strip()
        id_stem = f"quaverset{set_id}" if set_id not in ("", "-1", "0") else qua_path.stem
    song_id = sanitize_id(id_stem)
    chart_id = sanitize_id(f"{id_stem}_{diffname}")

    anim_changes = [
        {"t": round(t / 1000.0, 3), "bpm": round(b, 2)} for t, b in tps[1:]
    ]
    scroll_changes = []
    # A MISSING Multiplier means rate 0 (Quaver's SliderVelocityInfo.Multiplier
    # is an uninitialized C# float = 0.0f, and gameplay treats 0 as "staying
    # in the same spot"). The old default of 1.0 turned 335 stops on ball_hard
    # (631 on bozo, 7 on halloween) into normal scrolling - the pause bug.
    svs = sorted(((fnum(i.get("StartTime")), fnum(i.get("Multiplier"), 0.0))
                  for i in lists["SliderVelocities"]), key=lambda p: p[0])
    for t_ms, mult in svs:
        # Rates kept VERBATIM (negatives, zero, extremes): the loader model
        # handles them (spawn branches on non-positive presence); only
        # non-finite values are rejected. Rounding + last-in-file collapse stay.
        if mult != mult or abs(mult) == float("inf"):
            warnings.append(f"non-finite SV {mult} at {t_ms}ms skipped")
            continue
        r = round(mult, 4)
        b = round(t_ms / ref_bl, BEAT_DECIMALS)
        if scroll_changes and scroll_changes[-1]["b"] == b:
            # Same instant on our axis: identical ms in the file (or values closer
            # than ~1e-7 ms). Quaver plays the LAST one in file order, so it wins.
            scroll_changes[-1] = {"b": b, "rate": r}
            # The winner may now equal the point before it (e.g. 1.0, [spike, 1.0]
            # at one instant): the boundary is redundant, one is enough.
            if len(scroll_changes) > 1 and abs(scroll_changes[-2]["rate"] - r) < 1e-9:
                scroll_changes.pop()
        elif scroll_changes and abs(scroll_changes[-1]["rate"] - r) < 1e-9:
            continue  # consecutive equal rates: one boundary suffices
        else:
            scroll_changes.append({"b": b, "rate": r})

    duration = max(n["b"] + n["d"] for n in notes) * 60.0 / ref_bpm
    mode = scalars.get("Mode", "Keys4")
    chart = {
        "formatVersion": FORMAT_VERSION,
        "id": chart_id,
        "title": title,
        "artist": artist,
        "charter": f"{creator} (Quaver {mode} {diffname}, converted{fold_note})",
        "bpm": ref_bpm,
        "animationbpm": ref_bpm,
        "startAt": 0,
        "offsetMs": 0,
        "approach": 5,
        "mode": "Keyboard",
        "difficulty": {"Keyboard": diffname},
        "charts": {"Keyboard": notes},
        "noteCount": len(notes),
        "duration": round(duration, 2),
        "songId": song_id,
        "tier": tier_for(len(notes) / max(duration, 1.0)),
        "rank": 1,
        "sourceMode": mode,
        "sourceKeys": keys,
        "source": source or "quaver",
    }
    if lane_cap > 4:
        chart["lanes"] = lane_cap
    if anim_changes:
        chart["animationBpmChanges"] = anim_changes
    if scroll_changes:
        chart["scrollChanges"] = scroll_changes

    audio_name = scalars.get("AudioFile", "").strip()
    src_audio = qua_path.parent / audio_name if audio_name else None
    if src_audio and src_audio.exists():
        dst = place_media(src_audio, audio_dir, song_id)
        chart["audioFile"] = f"GakuranCharts/Audio/{dst.name}"
    else:
        warnings.append("audio file not found next to .qua; chart has no audioFile")
    bg_name = scalars.get("BackgroundFile", "").strip()
    if bg_name and (qua_path.parent / bg_name).exists():
        dst = place_media(qua_path.parent / bg_name, asset_dir, song_id)
        chart["backgroundFile"] = f"GakuranCharts/Assets/{dst.name}"

    out_dir.mkdir(parents=True, exist_ok=True)
    if not write_chart_json(out_dir, chart_id, chart):
        print(f"  ! ERROR: refusing to overwrite '{chart_id}.json': exists with different "
              f"content (same chart id from another file/format?) — delete it explicitly "
              f"or rename the source", file=sys.stderr)
        return None
    print(f"  -> {chart_id}.json: {len(notes)} notes, {ref_bpm} BPM (ref), "
          f"{len(anim_changes)} BPM changes, {duration:.1f}s"
          + (f", {len(scroll_changes)} SV points" if scroll_changes else ""))
    for w in warnings:
        print(f"  ! {w}", file=sys.stderr)
    return chart


def convert_qp(qp_path: Path, charts_dir: Path, audio_dir: Path, asset_dir: Path,
               **kw):
    """Convert every .qua inside a .qp package; return the chart dicts."""
    results = []
    with zipfile.ZipFile(qp_path) as zf:
        with tempfile.TemporaryDirectory(prefix="qua_") as tmp:
            tmp = Path(tmp)
            zf.extractall(tmp)
            for qua in sorted(tmp.glob("*.qua")):
                c = convert_file(qua, charts_dir, audio_dir, asset_dir, **kw)
                if c:
                    results.append(c)
    return results


def main():
    ap = argparse.ArgumentParser(description="Convert Quaver .qp/.qua maps to GakuranCharts JSON")
    ap.add_argument("input", type=Path, help=".qp or .qua file (or directory of .qua)")
    ap.add_argument("--charts-dir", type=Path, required=True)
    ap.add_argument("--audio-dir", type=Path, required=True)
    ap.add_argument("--assets-dir", type=Path, required=True)
    ap.add_argument("--no-fold", action="store_true",
                    help="do not fold maps with more keys than lanes; skip them instead")
    ap.add_argument("--max-lanes", type=int, default=MAX_KEYBOARD_LANES,
                    choices=range(4, MAX_KEYBOARD_LANES + 1),
                    help="lanes a Keyboard chart may use (default %d)" % MAX_KEYBOARD_LANES)
    ap.add_argument("--source", default="quaver",
                    help="origin engine tag written into each chart (default quaver)")
    args = ap.parse_args()
    kw = dict(max_lanes=args.max_lanes, no_fold=args.no_fold,
              source=args.source or "quaver")
    inp = args.input
    begin_batch()
    results = []
    if inp.suffix.lower() == ".qp":
        results = convert_qp(inp, args.charts_dir, args.audio_dir, args.assets_dir, **kw)
    else:
        quas = sorted(inp.glob("*.qua")) if inp.is_dir() else [inp]
        for qua in quas:
            c = convert_file(qua, args.charts_dir, args.audio_dir, args.assets_dir, **kw)
            if c:
                results.append(c)
    ok = assign_ranks(args.charts_dir, results)
    if not ok:
        return 1
    print(f"Done: {len(results)} chart(s) converted")
    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
