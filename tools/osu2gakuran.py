#!/usr/bin/env python3
"""
osu! (.osu / .osz) -> GakuranCharts JSON converter for the Gakuran rhythm minigame.

Chart format v1 (GakuranCharts):
  All note beats are stored against a fixed reference BPM so that the game's
  t = 60/bpm * beat conversion yields the exact osu! millisecond timing even
  when the map has BPM changes. Real BPM changes are emitted as
  animationBpmChanges (track seconds -> BPM) so character animation follows.

  {
    "formatVersion": 1,
    "id": "soundarchitect_harmonicbliss",
    "title": "...", "artist": "...", "charter": "...",
    "bpm": <reference BPM, first red line>,
    "animationbpm": <same>,
    "animationBpmChanges": [{"t": sec, "bpm": n}, ...],   # optional
    "startAt": 0, "offsetMs": 0, "approach": 5,
    "mode": "Keyboard",
    "difficulty": {"Keyboard": "Harmonic Bliss"},
    "charts": {"Keyboard": [{"b": beat, "l": lane(1..lanes), "d": holdBeats}]},
    "noteCount": n, "duration": sec,
    "audioFile": "GakuranCharts/Audio/<id>.mp3",
    "backgroundFile": "GakuranCharts/Assets/<id>.jpg",  # optional
    "scrollChanges": [{"b": beat, "rate": mult}, ...]   # optional, SV (green lines)
  }
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
import zipfile
from pathlib import Path

FORMAT_VERSION = 1
MODE_NAMES = {0: "osu!standard", 1: "osu!taiko", 2: "osu!catch", 3: "osu!mania"}
# Gakuran instrument modes and their lane counts (from RhythmChartUtil.getLaneCount)
LANES = {"Keyboard": 4, "Guitar": 2, "Bass": 4, "Drums": 4}


def parse_osu(text: str) -> dict:
    sections: dict = {}
    current = None
    for raw in text.splitlines():
        line = raw.strip().lstrip("\ufeff").rstrip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections[current] = []
        elif current is not None and not line.startswith("//"):
            sections[current].append(line)
    return sections


def meta(sections: dict, key: str, default=None):
    for line in sections.get("Metadata", []):
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip()
    for line in sections.get("General", []):
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip()
    for line in sections.get("Difficulty", []):
        if line.startswith(key + ":"):
            return line.split(":", 1)[1].strip()
    return default


def parse_timing(sections: dict):
    """Return (reds, svs): reds = [(time_ms, beat_len_ms)], svs = [(time_ms, sv_mult)]."""
    reds, svs = [], []
    for line in sections.get("TimingPoints", []):
        parts = line.split(",")
        if len(parts) < 2:
            continue
        try:
            t = float(parts[0])
            bl = float(parts[1])
        except ValueError:
            continue
        uninherited = parts[6].strip() == "1" if len(parts) > 6 else bl > 0
        if uninherited and bl > 0:
            reds.append((t, bl))
        elif bl < 0:
            svs.append((t, -100.0 / bl))
    reds.sort()
    svs.sort()
    return reds, svs


def sv_at(svs, time_ms: float) -> float:
    mult = 1.0
    for t, m in svs:
        if t <= time_ms:
            mult = m
        else:
            break
    return max(0.1, min(10.0, mult))


def red_at(reds, time_ms: float):
    cur = None
    for t, bl in reds:
        if t <= time_ms:
            cur = (t, bl)
        else:
            break
    return cur if cur else (reds[0] if reds else (0.0, 500.0))


def convert_hitobjects(sections: dict, reds, svs, keys: int, mode: int):
    """Return (notes, warnings). notes = [{b, l, d}] sorted by beat."""
    notes = []
    warnings = []
    sliders = 0
    skipped_other = 0
    slider_mult = float(meta(sections, "SliderMultiplier", "1.4") or 1.4)

    for line in sections.get("HitObjects", []):
        parts = line.split(",")
        if len(parts) < 4:
            continue
        try:
            x = float(parts[0])
            t = float(parts[2])
            htype = int(parts[3])
        except ValueError:
            continue

        if mode == 3:  # mania: x encodes the column; Gakuran lanes are 1-based
            col = int(x * keys / 512.0) + 1
            col = max(1, min(keys, col))
        else:  # standard fallback: map x into 4 lanes (1-based)
            col = max(1, min(4, int(x / 128.0) + 1))

        if htype & 128 and len(parts) > 5:  # mania hold: x,y,time,128,hitSound,endTime[,hitSample]
            # exporter may merge endTime with hitSample via ':' (e.g. "3560:2:0:1:60:")
            m_end = re.match(r"[-+]?\d+(?:\.\d+)?", parts[5])
            if not m_end:
                skipped_other += 1
                continue
            end = float(m_end.group())
            if end <= t:
                skipped_other += 1  # osu! spec: degenerate hold
                continue
            notes.append({
                "b": round(t / reds[0][1], 4),
                "l": col,
                "d": round((end - t) / reds[0][1], 4),
            })
        elif htype & 2:  # slider (osu!standard): parts[5]=curve, [6]=slides, [7]=px length
            sliders += 1
            try:
                px_len = float(parts[7])
            except (ValueError, IndexError):
                px_len = 60.0
            rt, rbl = red_at(reds, t)
            dur_ms = px_len / (slider_mult * 100.0) * rbl * sv_at(svs, t)
            notes.append({
                "b": round(t / reds[0][1], 4),
                "l": col,
                "d": round(dur_ms / reds[0][1], 4),
            })
        elif htype & 1:  # circle / mania tap
            notes.append({"b": round(t / reds[0][1], 4), "l": col, "d": 0})
        elif htype & 128:  # mania hold w/o parsable end
            skipped_other += 1
        else:  # spinner etc.
            skipped_other += 1

    notes.sort(key=lambda n: (n["b"], n["l"]))
    if sliders:
        warnings.append(f"{sliders} slider(s) converted to holds (approximate, standard-mode maps)")
    if skipped_other:
        warnings.append(f"{skipped_other} spinner/break object(s) skipped")
    return notes, warnings


def sanitize_id(s: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "_", s).strip("_").lower()
    return s[:64] or "chart"


# Absolute difficulty tiers by note density (notes/second). The names are the
# ones the game's RhythmDifficulty colours (easy/medium/hard/extreme/insane).
TIER_LIMITS = [(2.0, "easy"), (4.0, "medium"), (6.5, "hard"), (9.0, "extreme")]


def tier_for(density: float) -> str:
    for limit, name in TIER_LIMITS:
        if density < limit:
            return name
    return "insane"


def _sha1(path: Path) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def place_media(src: Path, dst_dir: Path, base: str) -> Path:
    """Copy src into dst_dir as <base><ext>, shared across a song's difficulties.

    Dedupe is by content: an existing file with identical bytes is reused; a
    different file already under that name is NEVER overwritten (the copy goes
    to <base>_2, <base>_3, ...). Re-converting a song therefore cannot clobber
    hand-edited/trimmed audio.
    """
    dst_dir.mkdir(parents=True, exist_ok=True)
    ext = src.suffix.lower()
    digest = _sha1(src)
    for i in range(1, 100):
        dst = dst_dir / (f"{base}{ext}" if i == 1 else f"{base}_{i}{ext}")
        if not dst.exists():
            shutil.copy2(src, dst)
            return dst
        if _sha1(dst) == digest:
            return dst
    raise RuntimeError(f"too many media variants for {base}{ext}")


def convert_file(osu_path: Path, out_dir: Path, audio_dir: Path, asset_dir: Path,
                 copy_audio=True, mode_override=None,
                 include_nonmania=False, allow_lossy_keys=False):
    text = osu_path.read_text(encoding="utf-8", errors="replace")
    sections = parse_osu(text)

    mode = int(meta(sections, "Mode", "0") or 0)
    gakuran_mode = mode_override or "Keyboard"
    version = meta(sections, "Version", "Normal")
    if mode != 3 and not include_nonmania:
        # Only osu!mania maps map onto lanes faithfully; standard/taiko/catch
        # become approximations (sliders -> holds, x -> lane). Opt in explicitly.
        print(f"  - skipped '{version}': {MODE_NAMES.get(mode, mode)} is not osu!mania "
              f"(approximate; pass --include-nonmania to convert anyway)", file=sys.stderr)
        return None
    if mode != 3:
        print(f"  ! WARNING: {MODE_NAMES.get(mode, mode)} has no good Gakuran equivalent; "
              f"converting as approximate {gakuran_mode}", file=sys.stderr)
    keys = int(float(meta(sections, "CircleSize", "4") or 4))
    keys = max(1, min(7, keys))
    lane_cap = LANES.get(gakuran_mode, 4)
    if mode == 3 and keys > lane_cap and not allow_lossy_keys:
        # The engine has a fixed lane count per instrument and the loader drops
        # lanes above it, so a >4K map would silently lose notes.
        print(f"  - skipped '{version}': {keys}K exceeds the {lane_cap} lanes of {gakuran_mode} "
              f"(notes would be lost; pass --allow-lossy-keys to convert anyway)", file=sys.stderr)
        return None

    reds, svs = parse_timing(sections)
    if not reds:
        print("  ! ERROR: no uninherited timing points; cannot convert", file=sys.stderr)
        return None

    ref_bl = reds[0][1]
    ref_bpm = round(60000.0 / ref_bl, 4)

    notes, warnings = convert_hitobjects(sections, reds, svs, keys, mode)
    if not notes:
        print("  ! ERROR: no convertible hit objects", file=sys.stderr)
        return None

    title = meta(sections, "Title", "Unknown")
    artist = meta(sections, "Artist", "Unknown")
    creator = meta(sections, "Creator", "Unknown")
    # (version was read above)
    # Ids: chart_id stays sanitize(title + version) so existing charts keep their
    # ids. A title with no alphanumerics (e.g. "-+") used to collapse to just the
    # version ("4k_sc"), which collides across songs; fall back to the beatmap set
    # id or the folder name instead. song_id groups a song's difficulties.
    id_stem = title
    if not re.search(r"[a-zA-Z0-9]", title):
        set_id = (meta(sections, "BeatmapSetID", "") or "").strip()
        id_stem = f"set{set_id}" if set_id not in ("", "-1", "0") else osu_path.parent.name
    song_id = sanitize_id(id_stem)
    chart_id = sanitize_id(f"{id_stem}_{version}")

    anim_changes = [
        {"t": round(t / 1000.0, 3), "bpm": round(60000.0 / bl, 2)}
        for t, bl in reds[1:]
    ]

    # osu! inherited timing points (green lines) -> scroll velocity (SV).
    # rate = -100 / beatLength (osu!mania convention). Stored on the same
    # fixed reference-BPM beat axis as the notes, so the loader's
    # t = startAt + 60/bpm * b lands them on the exact osu! ms axis.
    # Consecutive equal rates collapse into a single boundary.
    scroll_changes = []
    for t_ms, mult in svs:
        r = round(max(0.05, min(20.0, mult)), 4)
        if scroll_changes and abs(scroll_changes[-1]["rate"] - r) < 1e-9:
            continue
        scroll_changes.append({"b": round(t_ms / ref_bl, 4), "rate": r})

    duration = max(n["b"] + n["d"] for n in notes) * 60.0 / ref_bpm

    chart = {
        "formatVersion": FORMAT_VERSION,
        "id": chart_id,
        "title": title,
        "artist": artist,
        "charter": f"{creator} (osu! {MODE_NAMES.get(mode, mode)} {version}, converted)",
        "bpm": ref_bpm,
        "animationbpm": ref_bpm,
        "startAt": 0,
        "offsetMs": 0,
        "approach": 5,
        "mode": gakuran_mode,
        "difficulty": {gakuran_mode: version},
        "charts": {gakuran_mode: notes},
        "noteCount": len(notes),
        "duration": round(duration, 2),
        # multi-difficulty grouping (additive; the loader groups charts that
        # share a songId into one wheel row with a difficulty picker)
        "songId": song_id,
        "tier": tier_for(len(notes) / max(duration, 1.0)),
        "rank": 1,   # 1 = easiest in its song; finalised by assign_ranks()
        "sourceMode": MODE_NAMES.get(mode, str(mode)),
        "sourceKeys": keys if mode == 3 else None,
    }
    if mode != 3:
        chart["approximate"] = True
    if chart["sourceKeys"] is None:
        del chart["sourceKeys"]
    if anim_changes:
        chart["animationBpmChanges"] = anim_changes
    if scroll_changes:
        chart["scrollChanges"] = scroll_changes

    # audio / background
    audio_name = meta(sections, "AudioFilename", "audio.mp3")
    src_audio = osu_path.parent / audio_name
    if copy_audio and src_audio.exists():
        # one copy per SONG (shared by all its difficulties), deduped by content
        dst = place_media(src_audio, audio_dir, song_id)
        chart["audioFile"] = f"GakuranCharts/Audio/{dst.name}"
    else:
        warnings.append("audio file not found next to .osu; chart has no audioFile")

    bg = None
    for line in sections.get("Events", []):
        m = re.match(r'0,0,"([^"]+)"', line.strip())
        if m:
            bg = m.group(1)
            break
    if bg and (osu_path.parent / bg).exists():
        dst = place_media(osu_path.parent / bg, asset_dir, song_id)
        chart["backgroundFile"] = f"GakuranCharts/Assets/{dst.name}"

    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{chart_id}.json"
    out_path.write_text(json.dumps(chart, ensure_ascii=False, separators=(",", ":")),
                        encoding="utf-8")
    print(f"  -> {out_path.name}: {len(notes)} notes, {ref_bpm} BPM (ref), "
          f"{len(anim_changes)} BPM changes, {duration:.1f}s"
          + (f", {len(scroll_changes)} SV points" if scroll_changes else ""))
    for w in warnings:
        print(f"  ! {w}", file=sys.stderr)
    return chart


def assign_ranks(charts_dir: Path, charts: list):
    """Rank each song's converted difficulties by note density (1 = easiest)
    and rewrite their JSON. Only covers the charts of this run; the loader
    treats rank as a hint and falls back to density when ranks disagree."""
    by_song = {}
    for c in charts:
        by_song.setdefault(c["songId"], []).append(c)
    for song_id, group in by_song.items():
        group.sort(key=lambda c: (c["noteCount"] / max(c["duration"], 1.0), c["noteCount"]))
        for i, c in enumerate(group, 1):
            c["rank"] = i
            (charts_dir / f"{c['id']}.json").write_text(
                json.dumps(c, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        if len(group) > 1:
            print(f"  song '{song_id}': " + " < ".join(
                f"{c['difficulty'][c['mode']]} ({c['tier']})" for c in group))


def main():
    ap = argparse.ArgumentParser(description="Convert osu! maps to GakuranCharts JSON")
    ap.add_argument("input", type=Path, help=".osz or .osu file (or directory of .osu)")
    ap.add_argument("--charts-dir", type=Path, required=True, help="output charts dir")
    ap.add_argument("--audio-dir", type=Path, required=True, help="output audio dir")
    ap.add_argument("--assets-dir", type=Path, required=True, help="output assets dir")
    ap.add_argument("--mode", choices=list(LANES), help="force Gakuran instrument mode")
    ap.add_argument("--include-nonmania", action="store_true",
                    help="also convert osu!standard/taiko/catch maps (approximate)")
    ap.add_argument("--allow-lossy-keys", action="store_true",
                    help="also convert maps with more keys than lanes (extra lanes are dropped)")
    args = ap.parse_args()

    kw = dict(mode_override=args.mode, include_nonmania=args.include_nonmania,
              allow_lossy_keys=args.allow_lossy_keys)
    inp = args.input
    results = []
    if inp.suffix.lower() == ".osz":
        with zipfile.ZipFile(inp) as zf:
            tmp = args.charts_dir / "_osz_tmp"
            tmp.mkdir(parents=True, exist_ok=True)
            zf.extractall(tmp)
            for osu in sorted(tmp.glob("*.osu")):
                c = convert_file(osu, args.charts_dir, args.audio_dir, args.assets_dir, **kw)
                if c:
                    results.append(c)
            shutil.rmtree(tmp, ignore_errors=True)
    elif inp.suffix.lower() == ".osu":
        c = convert_file(inp, args.charts_dir, args.audio_dir, args.assets_dir, **kw)
        if c:
            results.append(c)
    elif inp.is_dir():
        for osu in sorted(inp.glob("*.osu")):
            c = convert_file(osu, args.charts_dir, args.audio_dir, args.assets_dir, **kw)
            if c:
                results.append(c)
    else:
        ap.error(f"unsupported input: {inp}")
    assign_ranks(args.charts_dir, results)
    print(f"Done: {len(results)} chart(s) converted")
    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
