#!/usr/bin/env python3
"""StepMania .sm/.ssc (dance-single) -> GakuranCharts JSON converter.

Same chart schema as tools/osu2gakuran.py (formatVersion 1, beats-based
notes, scrollChanges/animationBpmChanges, songId/tier/rank grouping) and the
same shared helpers (imported from osu2gakuran, not copied).

Mapping notes:
  * measures -> beats: beat = (measure_index + row / rows_in_measure) * 4
  * `1` tap, `2`+`3` hold, `4` roll head (treated as a hold; the engine has
    no rolls), `M` mine and `F` fake/L-lift skipped with a warning (no engine
    equivalent)
  * #BPMS beat=bpm segments (these files have one); #OFFSET seconds -> offsetMs
  * #SCROLLS beat=ratio -> scrollChanges (verbatim beats on the notes' axis,
    same-beat collapses to last-in-file, rates verbatim incl. zero/negative)
  * a non-empty #SPEEDS warns LOUDLY and converts WITHOUT it (the engine
    cannot do speed ramps); a non-empty #STOPS refuses the chart: the engine
    cannot freeze time and a silent desync is worse than a skip
  * .ssc files use one #STEPSTYPE..#NOTES (or #NOTES2, keysounds) block per
    chart (each becomes its own JSON); a chart block may override
    BPMS/STOPS/SCROLLS/SPEEDS/OFFSET for itself, else the global header
    applies; old-style .sm files keep the single colon-joined #NOTES block
  * dance-single is 4 columns, so no fold path (other stepstypes are skipped)

Usage:
    python tools/sm2gakuran.py song.sm --charts-dir C --audio-dir A --assets-dir S
    python tools/sm2gakuran.py song.ssc --charts-dir C --audio-dir A --assets-dir S
    python tools/sm2gakuran.py etterna_folder/ --charts-dir C ...   (every .sm/.ssc inside)
"""
import argparse
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from osu2gakuran import (FORMAT_VERSION, assign_ranks, begin_batch, place_media,
                         sanitize_id, tier_for, write_chart_json)


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


def parse_scrolls(raw: str):
    """#SCROLLS beat=ratio pairs -> [(beat, rate)] in file order.

    Malformed entries are skipped (caller sees none of them; an empty tag
    yields no points, same as a missing tag).
    """
    pts = []
    for part in (raw or "").split(","):
        part = part.strip()
        if not part or "=" not in part:
            continue
        b, v = part.split("=", 1)
        try:
            pts.append((float(b), float(v)))
        except ValueError:
            continue
    return pts


def parse_chart_blocks(text: str, tags: dict):
    """Return [(stepstype, author, difficulty, meter, measures_text)] in file order.

    New-style .ssc carries one #STEPSTYPE..#NOTES block per chart (separate
    #STEPSTYPE/#DESCRIPTION/#DIFFICULTY/#METER/#NOTES tags); old-style .sm
    has a single colon-joined #NOTES block. parse_sm's dict keeps only the
    LAST repeated tag, so new-style blocks are re-scanned here in file order.
    """
    blocks = []
    for m in re.finditer(r"#STEPSTYPE:(.*?);(.*?)#NOTES2?:(.*?);", text, re.DOTALL):
        stepstype = m.group(1).strip()
        middle, notes_text = m.group(2), m.group(3)

        def one(tag):
            mm = re.search(r"#" + tag + r":(.*?);", middle, re.DOTALL)
            return mm.group(1).strip() if mm else ""

        timing = {}
        for tm in re.finditer(r"#(BPMS|STOPS|SCROLLS|SPEEDS|OFFSET):(.*?);",
                              middle, re.DOTALL):
            timing[tm.group(1)] = tm.group(2).strip()
        blocks.append({"stepstype": stepstype,
                       "author": one("DESCRIPTION") or "Unknown",
                       "difficulty": one("DIFFICULTY") or "Normal",
                       "meter": one("METER"),
                       "measures": notes_text,
                       "timing": timing})
    if blocks:
        return blocks
    if tags.get("NOTES"):
        fields = [f.strip() for f in tags["NOTES"].split(":", 5)]
        while len(fields) < 6:
            fields.append("")
        return [{"stepstype": fields[0], "author": fields[1] or "Unknown",
                 "difficulty": fields[2] or "Normal", "meter": fields[3],
                 "measures": fields[5], "timing": {}}]
    return []


def resolve_timing(block: dict, tags: dict, name: str) -> str:
    """Chart-block timing value when the tag is PRESENT in the block (even
    empty, which explicitly clears the global); otherwise the global header
    value. StepMania .ssc lets charts override BPMS/STOPS/SCROLLS/SPEEDS/
    OFFSET per difficulty.
    """
    if name in block["timing"]:
        return block["timing"][name]
    return tags.get(name, "")


def build_scroll_changes(raw: str, warnings: list):
    """#SCROLLS beat=ratio text -> scrollChanges list.

    Beats are the file's musical beats (same axis as the notes); same beat
    twice collapses to the LAST file entry (Quaver semantics); rates go in
    VERBATIM (the loader integral handles zero/negatives, session 16).
    """
    won = {}
    for b, r in parse_scrolls(raw):
        if r != r or abs(r) == float("inf"):
            warnings.append(f"non-finite #SCROLLS rate {r} at beat {b} (dropped)")
            continue
        won[b] = round(r, 4)
    return [{"b": b, "rate": won[b]} for b in sorted(won)]


def parse_measures(measures_text: str):
    """Comma-separated measure rows -> (notes, warnings, fatal).

    fatal is None on success, else an error string the caller prints (and
    aborts the file over), matching the old inline behavior exactly.
    """
    notes, warnings = [], []
    mines = fakes = 0
    open_hold = {}
    measures = [m for m in measures_text.split(",")]
    for mi, meas in enumerate(measures):
        rows = [ln.strip() for ln in meas.splitlines()
                if ln.strip() and not ln.strip().startswith("//")]
        if not rows:
            continue
        width = max(len(r) for r in rows)
        if width != 4:
            return None, [], f"measure {mi + 1} is {width} columns, not 4"
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
    return notes, warnings, None


def convert_file(sm_path: Path, out_dir: Path, audio_dir: Path, asset_dir: Path,
                 source="etterna"):
    """Convert one .sm/.ssc file -> list of charts (one per dance-single block).

    Timing (BPMS/STOPS/SCROLLS/SPEEDS/OFFSET) resolves per chart: a tag
    present inside the chart's block wins, else the global header (StepMania
    .ssc override semantics). Files without overrides behave exactly as before.
    """
    text = sm_path.read_text(encoding="utf-8", errors="replace")
    tags = parse_sm(text)
    title = tags.get("TITLE", "Unknown").strip() or "Unknown"
    artist = tags.get("ARTIST", "Unknown").strip() or "Unknown"

    # The TRUE global header is the text BEFORE the first chart block:
    # parse_sm's dict keeps the LAST repeated tag file-wide, so a per-chart
    # #SCROLLS/#STOPS later in the file would otherwise poison the fallback
    # every chart without its own override inherits.
    first_block = re.search(r"#STEPSTYPE:", text)
    header_tags = parse_sm(text[:first_block.start()] if first_block else text)

    warnings = []

    blocks = parse_chart_blocks(text, header_tags)
    if not blocks:
        print(f"  - skipped '{sm_path.name}': no #NOTES block", file=sys.stderr)
        return []

    id_stem = title
    if not re.search(r"[a-zA-Z0-9]", title):
        id_stem = sm_path.parent.name
    song_id = sanitize_id(id_stem)

    # Validate every dance-single block BEFORE writing anything (one bad block
    # aborts the file, as before). A chart carrying its own #STOPS (or no
    # valid #BPMS) is SKIPPED, not fatal: sibling charts still convert.
    validated = []
    for block in blocks:
        stepstype, difficulty = block["stepstype"], block["difficulty"]
        if stepstype != "dance-single":
            print(f"  - skipped '{difficulty}': stepstype {stepstype} is not dance-single",
                  file=sys.stderr)
            continue
        segs = parse_bpms(resolve_timing(block, header_tags, "BPMS"))
        if not segs:
            print(f"  - skipped '{difficulty}' in '{sm_path.name}': no valid #BPMS",
                  file=sys.stderr)
            continue
        if resolve_timing(block, header_tags, "STOPS").strip():
            print(f"  - skipped '{difficulty}' in '{sm_path.name}': #STOPS need a time freeze "
                  f"the engine cannot do (would desync)", file=sys.stderr)
            continue
        notes, nwarnings, fatal = parse_measures(block["measures"])
        if fatal is not None:
            print(f"  ! ERROR: {fatal}", file=sys.stderr)
            return []
        if not notes:
            print(f"  ! ERROR: no convertible notes in '{difficulty}'", file=sys.stderr)
            return []
        validated.append((block, segs, notes, nwarnings))
    if not validated:
        return []

    music = tags.get("MUSIC", "").strip()
    src_audio = sm_path.parent / music if music else None
    audio_name = None
    if src_audio and src_audio.exists():
        audio_name = f"GakuranCharts/Audio/{place_media(src_audio, audio_dir, song_id).name}"
    else:
        warnings.append(f"audio file not found next to {sm_path.suffix}; chart has no audioFile")
    bg = tags.get("BACKGROUND", "").strip()
    bg_name = None
    if bg and (sm_path.parent / bg).exists():
        bg_name = f"GakuranCharts/Assets/{place_media(sm_path.parent / bg, asset_dir, song_id).name}"

    out_dir.mkdir(parents=True, exist_ok=True)
    charts = []
    used_ids = set()
    for block, segs, notes, nwarnings in validated:
        difficulty, author, meter = block["difficulty"], block["author"], block["meter"]
        ref_bpm = round(segs[0][1], 4)
        try:
            offset_ms = round(float(resolve_timing(block, header_tags, "OFFSET") or 0) * 1000)
        except ValueError:
            offset_ms = 0
        speeds_raw = resolve_timing(block, header_tags, "SPEEDS").strip()
        if speeds_raw:
            n_speeds = len([p for p in speeds_raw.split(",") if p.strip()])
            warnings.append(f"[{difficulty}] #SPEEDS has {n_speeds} entrie(s): SKIPPED - the engine "
                            f"cannot do speed ramps, so this chart converts WITHOUT "
                            f"them (sections under #SPEEDS scroll at the #SCROLLS rate "
                            f"and may look wrong)")
        scroll_changes = build_scroll_changes(resolve_timing(block, header_tags, "SCROLLS"),
                                              warnings)
        anim_changes = [
            {"t": round(beat_to_ms(b, segs) / 1000.0, 3), "bpm": round(bpm, 2)}
            for b, bpm in segs[1:]
        ]
        chart_id = sanitize_id(f"{id_stem}_{difficulty}")
        if chart_id in used_ids:
            i = 2
            while f"{chart_id}_{i}" in used_ids:
                i += 1
            chart_id = f"{chart_id}_{i}"
        used_ids.add(chart_id)
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
        if scroll_changes:
            chart["scrollChanges"] = scroll_changes
        if audio_name:
            chart["audioFile"] = audio_name
        if bg_name:
            chart["backgroundFile"] = bg_name

        if not write_chart_json(out_dir, chart_id, chart):
            print(f"  ! ERROR: refusing to overwrite '{chart_id}.json': exists with different "
                  f"content (same chart id from another file/format?) — delete it explicitly "
                  f"or rename the source", file=sys.stderr)
            return []
        print(f"  -> {chart_id}.json: {len(notes)} notes, {ref_bpm} BPM, {duration:.1f}s"
              + (f", {len(scroll_changes)} SV points" if scroll_changes else ""))
        for w in nwarnings:
            print(f"  ! {w}", file=sys.stderr)
        charts.append(chart)
    for w in warnings:
        print(f"  ! {w}", file=sys.stderr)
    return charts


def main():
    ap = argparse.ArgumentParser(description="Convert StepMania .sm/.ssc maps to GakuranCharts JSON")
    ap.add_argument("input", type=Path, help=".sm/.ssc file or directory of them")
    ap.add_argument("--charts-dir", type=Path, required=True)
    ap.add_argument("--audio-dir", type=Path, required=True)
    ap.add_argument("--assets-dir", type=Path, required=True)
    ap.add_argument("--source", default="etterna",
                    help="origin engine tag written into each chart (default etterna)")
    args = ap.parse_args()
    sm_files = (sorted(p for p in args.input.rglob("*") if p.is_file()
                      and p.suffix.lower() in {".sm", ".ssc"})
                if args.input.is_dir() else [args.input])
    begin_batch()
    results = []
    for sm in sm_files:
        results.extend(convert_file(sm, args.charts_dir, args.audio_dir,
                                    args.assets_dir,
                                    source=args.source or "etterna"))
    ok = assign_ranks(args.charts_dir, results)
    if not ok:
        return 1
    print(f"Done: {len(results)} chart(s) converted")
    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
