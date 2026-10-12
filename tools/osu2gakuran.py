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

  Maps with more columns than the instrument has lanes (e.g. 5K-10K osu!mania
  for the 4-lane Keyboard) are folded down to the lane count. Such a chart
  carries "sourceKeys" (original column count) and "fold": {from, to, source,
  kept, rerouted, dropped, droppedHolds, duplicates}. See fold_columns().
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
# The loader (HK.maxLanes) plays Keyboard charts with up to this many lanes
# ("lanes": 5..7 in the chart). A mania map with 5-7 columns is converted 1:1;
# 8K+ is folded to this many lanes (use --max-lanes 4 for the old 4-lane fold).
MAX_KEYBOARD_LANES = 7

# --- folding maps with more columns than lanes -----------------------------
# The engine fixes the lane count per instrument (LANES) and the loader only
# reads lanes 1..N, so an osu!mania map with more columns than lanes is folded
# down here, at convert time. The game's system is untouched: the output is an
# ordinary N-lane chart.
FOLD_MIN_GAP_MS = 25.0   # a lane is unusable this long after a note / hold release


def column_lanes(col: int, keys: int, lanes: int):
    """Where 1-based column `col` of a `keys`-column map goes when folded to
    `lanes` lanes. Returns (natural, order).

    Exact integer rule: in units of 1/keys the column spans [(col-1)*lanes,
    col*lanes) and lane j spans [j*keys, (j+1)*keys). The natural lane is the
    one the column overlaps most; an exact tie (the centre column of 5K/7K/9K,
    columns 2 and 5 of 6K, ...) yields two natural lanes and the caller picks
    between them. `order` lists every lane nearest-first, for rerouting."""
    lo, hi = (col - 1) * lanes, col * lanes
    overlap = [max(0, min(hi, (j + 1) * keys) - max(lo, j * keys)) for j in range(lanes)]
    best = max(overlap)
    natural = tuple(j + 1 for j, o in enumerate(overlap) if o == best)
    centre2 = lo + hi
    order = sorted(range(1, lanes + 1), key=lambda L: (abs(centre2 - (2 * L - 1) * keys), L))
    return natural, order


def fold_columns(objs, keys: int, lanes: int, min_gap_ms: float = FOLD_MIN_GAP_MS):
    """Fold hit objects onto `lanes` lanes.

    objs: [(start_ms, end_ms or None, col)], col 1-based; end_ms is None for a tap.
    Returns (placed, stats): placed = [(start_ms, end_ms or None, lane)].

    Deterministic, chronological. A lane is busy until a hold's end (or a tap's
    start) plus min_gap_ms, so no two notes ever share a lane at once. Per
    start time, every object first takes its natural lane if free (ties go to
    the least recently used free lane), then leftovers are rerouted to the
    nearest free lane (holds before taps); an object is dropped only when all
    lanes are busy."""
    best = {}
    duplicates = 0
    for start, end, col in objs:
        key = (start, col)
        if key in best:
            duplicates += 1
            old = best[key]
            if end is not None and (old is None or end > old):
                best[key] = end
        else:
            best[key] = end
    items = sorted(((k[0], v, k[1]) for k, v in best.items()), key=lambda o: (o[0], o[2]))

    free_at = [float("-inf")] * lanes
    last_use = [float("-inf")] * lanes
    placed = []
    rerouted = dropped = dropped_holds = 0

    def place(lane, start, end):
        free_at[lane - 1] = (end if end is not None else start) + min_gap_ms
        last_use[lane - 1] = start
        placed.append((start, end, lane))

    i = 0
    while i < len(items):
        j = i
        while j < len(items) and items[j][0] == items[i][0]:
            j += 1
        group = items[i:j]
        i = j
        start = group[0][0]
        pending = []
        for o in group:
            natural, order = column_lanes(o[2], keys, lanes)
            free = [L for L in natural if free_at[L - 1] <= start]
            if free:
                place(min(free, key=lambda L: (last_use[L - 1], L)), start, o[1])
            else:
                pending.append((o, order))
        pending.sort(key=lambda p: (p[0][1] is None, p[0][2]))
        for o, order in pending:
            free = [L for L in order if free_at[L - 1] <= start]
            if free:
                place(free[0], start, o[1])
                rerouted += 1
            else:
                dropped += 1
                if o[1] is not None:
                    dropped_holds += 1
    stats = {"from": keys, "to": lanes, "source": len(items), "kept": len(placed),
             "rerouted": rerouted, "dropped": dropped, "droppedHolds": dropped_holds,
             "duplicates": duplicates}
    return placed, stats


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
    # Time sort must be STABLE (file order kept for ties): a later same-time
    # point overrides an earlier one, in osu! as in Quaver. A plain tuple
    # sort would order ties by multiplier value and the wrong rate would win.
    svs.sort(key=lambda p: p[0])
    deduped = []
    for t, m in svs:
        if deduped and deduped[-1][0] == t:
            deduped[-1] = (t, m)  # last in file wins
        else:
            deduped.append((t, m))
    return reds, deduped


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


def convert_hitobjects(sections: dict, reds, svs, keys: int, mode: int,
                       lanes=None, fold_info=None):
    """Return (notes, warnings). notes = [{b, l, d}] sorted by beat.

    With lanes set and keys > lanes (osu!mania only) the objects are folded onto
    `lanes` lanes by fold_columns(); fold_info, if given, receives its stats."""
    notes = []
    warnings = []
    raw = [] if (mode == 3 and lanes and keys > lanes) else None
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
            if raw is not None:
                raw.append((t, end, col))
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
            if raw is not None:
                raw.append((t, None, col))
            else:
                notes.append({"b": round(t / reds[0][1], 4), "l": col, "d": 0})
        elif htype & 128:  # mania hold w/o parsable end
            skipped_other += 1
        else:  # spinner etc.
            skipped_other += 1

    if raw is not None:
        placed, stats = fold_columns(raw, keys, lanes)
        for t, end, lane in placed:
            notes.append({
                "b": round(t / reds[0][1], 4),
                "l": lane,
                "d": round((end - t) / reds[0][1], 4) if end is not None else 0,
            })
        if fold_info is not None:
            fold_info.update(stats)
        lost = stats["dropped"]
        warnings.append(
            f"folded {keys}K -> {lanes} lanes: {stats['source']} objects, "
            f"{stats['kept']} kept, {stats['rerouted']} moved to a neighbouring lane, "
            f"{lost} dropped" + (f" ({stats['droppedHolds']} holds)" if stats["droppedHolds"] else "")
            + (f", {stats['duplicates']} duplicate(s) merged" if stats["duplicates"] else ""))
    notes.sort(key=lambda n: (n["b"], n["l"]))
    if sliders:
        warnings.append(f"{sliders} slider(s) converted to holds (approximate, standard-mode maps)")
    if skipped_other:
        warnings.append(f"{skipped_other} spinner/break object(s) skipped")
    return notes, warnings


ID_LIMIT = 64


def sanitize_id(s: str, limit: int = ID_LIMIT) -> str:
    """Filesystem-safe lowercase id, at most `limit` characters.

    Names that already fit are returned unchanged, so every chart converted by
    an earlier version keeps its id. Longer names end in a short digest of the
    FULL name instead of being cut: plain truncation made two difficulties of a
    long-titled song collapse onto the same id (`..._artist_e` for both "Easy"
    and "Expert"), and the second .json written then silently overwrote the
    first - losing a difficulty off the song's wheel row.
    """
    s = re.sub(r"[^a-zA-Z0-9]+", "_", s).strip("_").lower()
    if not s:
        return "chart"
    if len(s) <= limit:
        return s
    digest = hashlib.sha1(s.encode("utf-8")).hexdigest()[:8]
    return s[: limit - 9].rstrip("_") + "_" + digest


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
            CREATED_MEDIA.append(dst)
            return dst
        if _sha1(dst) == digest:
            return dst
    raise RuntimeError(f"too many media variants for {base}{ext}")


def write_chart_json(out_dir: Path, chart_id: str, chart: dict) -> bool:
    """Write one chart JSON unless the target exists with DIFFERENT content.

    Returns True when the file was written (or already byte-identical, so
    re-converting is idempotent). Returns False on refusal: an existing file
    with different bytes (same chart id from another file/format — e.g.
    parallel .sm/.ssc twins) is NEVER overwritten, and the refusal rolls back
    everything this batch created (zero partial output). Unlike media, charts
    are not auto-suffixed: a second identity for one id would silently fork
    the wheel row. Callers skip the chart with an ERROR and keep going; the
    batch epilogue (assign_ranks) turns any refusal into a failed run.
    """
    text = json.dumps(chart, ensure_ascii=False, separators=(",", ":"))
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / f"{chart_id}.json"
    if dest.exists():
        try:
            same = dest.read_text(encoding="utf-8") == text
        except OSError:
            same = False
        if not same:
            WRITE_REFUSALS.append((chart_id, str(dest)))
            rollback_batch()
        return same
    dest.write_text(text, encoding="utf-8")
    WRITTEN_CHARTS.append(dest)
    return True


# Batch-output tracking for the no-overwrite guarantee (audit item 14 HIGH 03).
# Single-batch assumption: converter CLIs and convert_song.py run one batch
# per process; tests use isolated temp dirs. Lists below accumulate across
# direct convert_file calls in one process, which is harmless there because a
# rollback only deletes paths it recorded (missing files are skipped) and
# tests never share output dirs.
WRITTEN_CHARTS = []   # chart JSONs this process created (never pre-existing)
CREATED_MEDIA = []    # media files this process created (reused ones unlisted)
WRITE_REFUSALS = []   # (chart_id, dest-string) pairs refused for differing bytes


def begin_batch():
    """Reset batch-output tracking at the start of a converter run.

    Every CLI main and convert_song.main calls this first: one process runs
    one batch, so leftovers from direct convert_file calls (tests) must not
    leak into the run's abort decision.
    """
    WRITTEN_CHARTS.clear()
    CREATED_MEDIA.clear()
    WRITE_REFUSALS.clear()


def rollback_batch():
    """Delete everything this batch created; pre-existing files are untouched.

    Only paths recorded as created-above are removed (missing-ok), so files
    that predated the batch — including the refused collision target — survive
    byte-for-byte. Called automatically on the first refusal of a batch.
    """
    for paths in (WRITTEN_CHARTS, CREATED_MEDIA):
        for p in paths:
            try:
                Path(p).unlink()
            except OSError:
                pass
        paths.clear()


def convert_file(osu_path: Path, out_dir: Path, audio_dir: Path, asset_dir: Path,
                 copy_audio=True, mode_override=None,
                 include_nonmania=False, allow_lossy_keys=False, fold_keys=True,
                 max_lanes=MAX_KEYBOARD_LANES, source="osu"):
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
    # osu!mania goes to 18 columns. (This used to clamp to 7, which mis-placed the
    # columns of 8K+ maps because x is encoded for the real column count.)
    keys = max(1, min(18, keys))
    lane_cap = LANES.get(gakuran_mode, 4)
    # Keyboard maps may use more than 4 lanes natively (loader 2.0.19+): a 5K-7K
    # mania map keeps all its columns, 8K+ folds to max_lanes. Other instruments
    # (and max_lanes <= 4) keep the engine's fixed lane count.
    if mode == 3 and gakuran_mode == "Keyboard" and keys > lane_cap and max_lanes > lane_cap:
        lane_cap = min(keys, min(max_lanes, MAX_KEYBOARD_LANES))
    # More columns than lanes: fold down to the lane count (default). The old
    # lossy path (extra lanes dropped by the loader) is only used when asked for.
    fold = mode == 3 and keys > lane_cap and fold_keys and not allow_lossy_keys
    if mode == 3 and keys > lane_cap and not fold and not allow_lossy_keys:
        # The engine has a fixed lane count per instrument and the loader drops
        # lanes above it, so without folding a >4K map would silently lose notes.
        print(f"  - skipped '{version}': {keys}K exceeds the {lane_cap} lanes of {gakuran_mode} "
              f"(folding is off; drop --no-fold to fold it, or pass --allow-lossy-keys "
              f"to convert anyway and lose notes)", file=sys.stderr)
        return None

    reds, svs = parse_timing(sections)
    if not reds:
        print("  ! ERROR: no uninherited timing points; cannot convert", file=sys.stderr)
        return None

    ref_bl = reds[0][1]
    ref_bpm = round(60000.0 / ref_bl, 4)

    fold_info = {}
    notes, warnings = convert_hitobjects(sections, reds, svs, keys, mode,
                                         lanes=lane_cap if fold else None,
                                         fold_info=fold_info)
    fold_note = f", folded {keys}K->{lane_cap} lanes" if fold_info else ""
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
    # Same grid instant twice (same ms, or distinct ms rounding to one beat):
    # last in file wins, like the game. Consecutive equal rates collapse.
    scroll_changes = []
    for t_ms, mult in svs:
        # Rates kept VERBATIM (see qua2gakuran): the loader model handles
        # negatives/zero/extremes; only non-finite values are rejected.
        if mult != mult or abs(mult) == float("inf"):
            warnings.append(f"non-finite SV {mult} at {t_ms}ms skipped")
            continue
        r = round(mult, 4)
        b = round(t_ms / ref_bl, 4)
        if scroll_changes and scroll_changes[-1]["b"] == b:
            scroll_changes[-1] = {"b": b, "rate": r}
        elif scroll_changes and abs(scroll_changes[-1]["rate"] - r) < 1e-9:
            continue
        else:
            scroll_changes.append({"b": b, "rate": r})

    duration = max(n["b"] + n["d"] for n in notes) * 60.0 / ref_bpm

    chart = {
        "formatVersion": FORMAT_VERSION,
        "id": chart_id,
        "title": title,
        "artist": artist,
        "charter": f"{creator} (osu! {MODE_NAMES.get(mode, mode)} {version}, converted{fold_note})",
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
        # origin engine of the chart (additive; the loader shows a game tag /
        # icon from it and falls back to "unknown" when absent)
        "source": source or "osu",
    }
    if mode != 3:
        chart["approximate"] = True
    if chart["sourceKeys"] is None:
        del chart["sourceKeys"]
    if fold_info:
        chart["fold"] = dict(fold_info)
    if mode == 3 and gakuran_mode == "Keyboard" and lane_cap > 4:
        # more-than-4-lane chart: the loader plays it with this many lanes
        # (it refuses it with a message if its 4K+ hooks are missing)
        chart["lanes"] = lane_cap
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
    if not write_chart_json(out_dir, chart_id, chart):
        print(f"  ! ERROR: refusing to overwrite '{out_path.name}': exists with different "
              f"content (same chart id from another file/format?) — delete it explicitly "
              f"or rename the source", file=sys.stderr)
        return None
    print(f"  -> {out_path.name}: {len(notes)} notes, {ref_bpm} BPM (ref), "
          f"{len(anim_changes)} BPM changes, {duration:.1f}s"
          + (f", {len(scroll_changes)} SV points" if scroll_changes else ""))
    for w in warnings:
        print(f"  ! {w}", file=sys.stderr)
    return chart


def assign_ranks(charts_dir: Path, charts: list):
    """Rank each song's converted difficulties by note density (1 = easiest)
    and rewrite their JSON. Only covers the charts of this run; the loader
    treats rank as a hint and falls back to density when ranks disagree.

    Returns False (writing nothing) when the batch hit a chart-id refusal:
    the outputs were already rolled back, so resurrecting rank-only files
    here would undo the zero-partial-output guarantee. Callers exit nonzero.
    """
    if WRITE_REFUSALS:
        print(f"  ! ERROR: batch aborted: {len(WRITE_REFUSALS)} chart-id collision(s), "
              f"output tree restored (refused: "
              + ", ".join(f"'{c}'" for c, _ in WRITE_REFUSALS) + ")", file=sys.stderr)
        return False
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
    return True


def main():
    begin_batch()  # one process runs one batch; reset tracking before converting
    ap = argparse.ArgumentParser(description="Convert osu! maps to GakuranCharts JSON")
    ap.add_argument("input", type=Path, help=".osz or .osu file (or directory of .osu)")
    ap.add_argument("--charts-dir", type=Path, required=True, help="output charts dir")
    ap.add_argument("--audio-dir", type=Path, required=True, help="output audio dir")
    ap.add_argument("--assets-dir", type=Path, required=True, help="output assets dir")
    ap.add_argument("--mode", choices=list(LANES), help="force Gakuran instrument mode")
    ap.add_argument("--include-nonmania", action="store_true",
                    help="also convert osu!standard/taiko/catch maps (approximate)")
    ap.add_argument("--allow-lossy-keys", action="store_true",
                    help="legacy: convert maps with more keys than lanes WITHOUT folding "
                         "(the loader drops the extra lanes, so notes are lost)")
    ap.add_argument("--no-fold", action="store_true",
                    help="do not fold maps with more keys than lanes; skip them instead "
                         "(default: fold them down to the lane count)")
    ap.add_argument("--max-lanes", type=int, default=MAX_KEYBOARD_LANES, choices=range(4, MAX_KEYBOARD_LANES + 1),
                    metavar="4-%d" % MAX_KEYBOARD_LANES,
                    help="lanes a Keyboard chart may use (default %d: 5K-7K maps convert 1:1, "
                         "8K+ fold to this many lanes; 4 = the old fold-everything-to-4K behaviour)"
                         % MAX_KEYBOARD_LANES)
    ap.add_argument("--source", default="osu",
                    help="origin engine tag written into each chart (default osu)")
    args = ap.parse_args()

    kw = dict(mode_override=args.mode, include_nonmania=args.include_nonmania,
              allow_lossy_keys=args.allow_lossy_keys, fold_keys=not args.no_fold,
              max_lanes=args.max_lanes, source=args.source or "osu")
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
    ok = assign_ranks(args.charts_dir, results)
    if not ok:
        return 1
    print(f"Done: {len(results)} chart(s) converted")
    return 0 if results else 1


if __name__ == "__main__":
    sys.exit(main())
