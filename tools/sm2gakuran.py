#!/usr/bin/env python3
"""StepMania .sm (dance-single) -> GakuranCharts JSON converter.

Same chart schema as tools/osu2gakuran.py (formatVersion 1, beats-based
notes, scrollChanges/animationBpmChanges, songId/tier/rank grouping) and the
same shared helpers (imported from osu2gakuran, not copied).

Mapping notes:
  * measures -> beats: beat = (measure_index + row / rows_in_measure) * 4
  * `1` tap, `2`+`3` hold, `4` roll head (treated as a hold; the engine has
    no rolls), `M` mine and `F` fake/L-lift skipped with a warning (no engine
    equivalent)
  * #BPMS beat=bpm segments (these files have one); #OFFSET seconds -> offsetMs
  * a non-empty #STOPS refuses the chart: the engine cannot freeze time and a
    silent desync is worse than a skip
  * dance-single is 4 columns, so no fold path (other stepstypes are skipped)

Usage:
    python tools/sm2gakuran.py song.sm --charts-dir C --audio-dir A --assets-dir S
    python tools/sm2gakuran.py etterna_folder/ --charts-dir C ...   (every .sm inside)
"""
import argparse
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osu2gakuran import (FORMAT_VERSION, assign_ranks, place_media, sanitize_id,
                         tier_for)


def parse_sm(text: str):
    """Return {TAG: value}. Values may span lines (NOTES blocks)."""
    tags = {}
    for m in re.finditer(r"#([A-Z0-9]+):(.*?);", text, re.DOTALL):
        tags[m.group(1)] = m.group(2).strip()
    return tags


def parse_bpms(raw: str):
    segs = []
    for part in raw.split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        b, v = part.split("=", 1)
        try:
            segs.append((float(b), float(v)))
        except ValueError:
            continue
    segs.sort()
    return [(b, v) for b, v in segs if v > 0]


def beat_to_ms(beat: float, segs) -> float:
    ms = 0.0
    for i, (sb, bpm) in enumerate(segs):
        eb = segs[i + 1][0] if i + 1 < len(segs) else None
        if beat < sb:
            break
        bl = 60000.0 / bpm
        ms += (min(beat, eb) - sb) * bl if eb else (beat - sb) * bl
    return ms


def convert_file(sm_path: Path, out_dir: Path, audio_dir: Path, asset_dir: Path,
                 source="etterna"):
    tags = parse_sm(sm_path.read_text(encoding="utf-8", errors="replace"))
    title = tags.get("TITLE", "Unknown").strip() or "Unknown"
    artist = tags.get("ARTIST", "Unknown").strip() or "Unknown"

    segs = parse_bpms(tags.get("BPMS", ""))
    if not segs:
        print(f"  - skipped '{sm_path.name}': no valid #BPMS", file=sys.stderr)
        return None
    if tags.get("STOPS", "").strip():
        print(f"  - skipped '{sm_path.name}': #STOPS need a time freeze the engine "
              f"cannot do (would desync)", file=sys.stderr)
        return None
    ref_bpm = round(segs[0][1], 4)
    ref_bl = 60000.0 / segs[0][1]

    notes_blob = tags.get("NOTES")
    if not notes_blob:
        print(f"  - skipped '{sm_path.name}': no #NOTES block", file=sys.stderr)
        return None
    fields = [f.strip() for f in notes_blob.split(":", 5)]
    while len(fields) < 6:
        fields.append("")
    stepstype, author, difficulty, meter = fields[0], fields[1], fields[2], fields[3]
    if stepstype != "dance-single":
        print(f"  - skipped '{difficulty}': stepstype {stepstype} is not dance-single",
              file=sys.stderr)
        return None
    author = author or "Unknown"
    difficulty = difficulty or "Normal"

    notes, warnings = [], []
    mines = fakes = 0
    open_hold = {}
    measures = [m for m in fields[5].split(",")]
    for mi, meas in enumerate(measures):
        rows = [ln.strip() for ln in meas.splitlines()
                if ln.strip() and not ln.strip().startswith("//")]
        if not rows:
            continue
        width = max(len(r) for r in rows)
        if width != 4:
            print(f"  ! ERROR: measure {mi + 1} is {width} columns, not 4", file=sys.stderr)
            return None
        for ri, row in enumerate(rows):
            beat = round((mi + ri / len(rows)) * 4.0, 4)
            for ci, ch in enumerate(row[:4]):
                lane = ci + 1
                if ch == "1":
                    notes.append({"b": beat, "l": lane, "d": 0})
                elif ch in "24":
                    if lane in open_hold:
                        warnings.append(f"lane {lane}: hold head over an open hold at beat {beat} "
                                        f"(kept the earlier one)")
                    else:
                        open_hold[lane] = beat
                elif ch == "3":
                    if lane in open_hold:
                        start = open_hold.pop(lane)
                        if beat > start:
                            notes.append({"b": start, "l": lane,
                                          "d": round(beat - start, 4)})
                    else:
                        warnings.append(f"lane {lane}: lone hold tail at beat {beat} (skipped)")
                elif ch == "M":
                    mines += 1
                elif ch in "FL":
                    fakes += 1
    if open_hold:
        warnings.append(f"{len(open_hold)} unclosed hold head(s) dropped")
    if mines:
        warnings.append(f"{mines} mine(s) skipped (no engine equivalent)")
    if fakes:
        warnings.append(f"{fakes} fake/lift(s) skipped (no engine equivalent)")
    notes.sort(key=lambda n: (n["b"], n["l"]))
    if not notes:
        print(f"  ! ERROR: no convertible notes in '{difficulty}'", file=sys.stderr)
        return None

    id_stem = title
    if not re.search(r"[a-zA-Z0-9]", title):
        id_stem = sm_path.parent.name
    song_id = sanitize_id(id_stem)
    chart_id = sanitize_id(f"{id_stem}_{difficulty}")
    try:
        offset_ms = round(float(tags.get("OFFSET", "0") or 0) * 1000)
    except ValueError:
        offset_ms = 0

    anim_changes = [
        {"t": round(beat_to_ms(b, segs) / 1000.0, 3), "bpm": round(bpm, 2)}
        for b, bpm in segs[1:]
    ]
    duration = max(n["b"] + n["d"] for n in notes) * 60.0 / ref_bpm
    chart = {
        "formatVersion": FORMAT_VERSION,
        "id": chart_id,
        "title": title,
        "artist": artist,
        "charter": f"{author} (StepMania dance-single {difficulty} {meter}, converted)",
        "bpm": ref_bpm,
        "animationbpm": ref_bpm,
        "startAt": 0,
        "offsetMs": offset_ms,
        "approach": 5,
        "mode": "Keyboard",
        "difficulty": {"Keyboard": difficulty},
        "charts": {"Keyboard": notes},
        "noteCount": len(notes),
        "duration": round(duration, 2),
        "songId": song_id,
        "tier": tier_for(len(notes) / max(duration, 1.0)),
        "rank": 1,
        "sourceMode": "dance-single",
        "sourceKeys": 4,
        "source": source or "etterna",
    }
    if anim_changes:
        chart["animationBpmChanges"] = anim_changes

    music = tags.get("MUSIC", "").strip()
    src_audio = sm_path.parent / music if music else None
    if src_audio and src_audio.exists():
        dst = place_media(src_audio, audio_dir, song_id)
        chart["audioFile"] = f"GakuranCharts/Audio/{dst.name}"
    else:
        warnings.append("audio file not found next to .sm; chart has no audioFile")
    bg = tags.get("BACKGROUND", "").strip()
    if bg and (sm_path.parent / bg).exists():
        dst = place_media(sm_path.parent / bg, asset_dir, song_id)
        chart["backgroundFile"] = f"GakuranCharts/Assets/{dst.name}"

    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / f"{chart_id}.json").write_text(
        json.dumps(chart, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"  -> {chart_id}.json: {len(notes)} notes, {ref_bpm} BPM, {duration:.1f}s")
    for w in warnings:
        print(f"  ! {w}", file=sys.stderr)
    return chart


def main():
    ap = argparse.ArgumentParser(description="Convert StepMania .sm maps to GakuranCharts JSON")
    ap.add_argument("input", type=Path, help=".sm file or directory of them")
    ap.add_argument("--charts-dir", type=Path, required=True)
    ap.add_argument("--audio-dir", type=Path, required=True)
    ap.add_argument("--assets-dir", type=Path, required=True)
    ap.add_argument("--source", default="etterna",
                    help="origin engine tag written into each chart (default etterna)")
    args = ap.parse_args()
    sm_files = sorted(args.input.rglob("*.sm")) if args.input.is_dir() else [args.input]
    results = []
    for sm in sm_files:
        c = convert_file(sm, args.charts_dir, args.audio_dir, args.assets_dir,
                         source=args.source or "etterna")
        if c:
            results.append(c)
    assign_ranks(args.charts_dir, results)
    print(f"Done: {len(results)} chart(s) converted")
    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
