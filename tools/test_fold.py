#!/usr/bin/env python3
"""Offline tests for the >N-key fold in osu2gakuran.py. No game needed.
Run: python tools/test_fold.py   (exit code 0 = all passed)"""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import osu2gakuran as C  # noqa: E402

GAP = C.FOLD_MIN_GAP_MS


def test_column_lanes_known_shapes():
    nat = lambda k, n=4: [C.column_lanes(c, k, n)[0] for c in range(1, k + 1)]
    assert nat(5) == [(1,), (2,), (2, 3), (3,), (4,)], nat(5)
    assert nat(8) == [(1,), (1,), (2,), (2,), (3,), (3,), (4,), (4,)], nat(8)
    assert nat(6) == [(1,), (1, 2), (2,), (3,), (3, 4), (4,)], nat(6)
    assert nat(3, 2) == [(1,), (1, 2), (2,)], nat(3, 2)


def test_column_lanes_symmetry_and_cover():
    for lanes in (2, 4):
        for k in range(lanes + 1, 19):
            seen = set()
            for c in range(1, k + 1):
                nat, order = C.column_lanes(c, k, lanes)
                mirror, _ = C.column_lanes(k + 1 - c, k, lanes)
                assert tuple(sorted(lanes + 1 - L for L in nat)) == tuple(sorted(mirror)), (k, c)
                assert sorted(order) == list(range(1, lanes + 1))
                assert 1 <= len(nat) <= 2
                seen.update(nat)
            assert seen == set(range(1, lanes + 1)), (k, seen)


def random_map(k, n, seed):
    rnd = random.Random(seed)
    objs = []
    for _ in range(n):
        t = rnd.randrange(0, 60000)
        hold = rnd.random() < 0.3
        objs.append((float(t), float(t + rnd.randrange(80, 900)) if hold else None, rnd.randrange(1, k + 1)))
    return objs


def check_invariants(objs, k, lanes):
    placed, st = C.fold_columns(objs, k, lanes)
    per = {}
    for s, e, L in placed:
        assert 1 <= L <= lanes
        per.setdefault(L, []).append((s, e))
    for L, lst in per.items():
        lst.sort()
        for (s1, e1), (s2, _e2) in zip(lst, lst[1:]):
            assert (e1 if e1 is not None else s1) + GAP <= s2, (L, s1, e1, s2)
    # every kept hold keeps its exact length; counts add up
    src = {}
    for s, e, c in objs:
        if (s, c) not in src:
            src[(s, c)] = e
        elif e is not None and (src[(s, c)] is None or e > src[(s, c)]):
            src[(s, c)] = e
    assert st["source"] == len(src) and st["duplicates"] == len(objs) - len(src)
    assert st["kept"] + st["dropped"] == st["source"] and st["kept"] == len(placed)
    ends = sorted((s, e) for (s, c), e in src.items() if e)
    kept_holds = sorted((s, e) for s, e, _ in placed if e is not None)
    assert all(h in ends for h in kept_holds)
    assert st["dropped"] >= st["droppedHolds"]
    return placed, st


def test_invariants_random():
    for lanes in (4, 2):
        for k in range(lanes + 1, 11):
            for seed in range(5):
                objs = random_map(k, 500, seed * 31 + k)
                placed, st = check_invariants(objs, k, lanes)
                again, st2 = C.fold_columns(list(reversed(objs)), k, lanes)
                assert placed == again and st == st2, "not deterministic"


def test_hold_blocks_lane_and_reroutes():
    # 8K: cols 1 and 2 both naturally map to lane 1. Hold in col 1, tap in col 2 during it.
    placed, st = C.fold_columns([(0.0, 1000.0, 1), (500.0, None, 2)], 8, 4)
    lanes = {s: L for s, e, L in placed}
    assert lanes[0.0] == 1 and lanes[500.0] == 2 and st["rerouted"] == 1 and st["dropped"] == 0, (placed, st)


def test_drop_only_when_all_lanes_busy():
    holds = [(0.0, 2000.0, c) for c in (1, 3, 5, 7)] + [(100.0, None, 2)]
    placed, st = C.fold_columns(holds, 8, 4)
    assert st["dropped"] == 1 and st["kept"] == 4, st
    # the holds win over the tap, and all four lanes are used
    assert sorted(L for _, e, L in placed if e is not None) == [1, 2, 3, 4]


def test_duplicates_merge():
    placed, st = C.fold_columns([(0.0, None, 3), (0.0, None, 3), (0.0, 500.0, 3)], 5, 4)
    assert st["duplicates"] == 2 and st["source"] == 1 and placed[0][1] == 500.0, (placed, st)


def osu_text(keys, objects):
    """Minimal osu!mania map text. objects = [(column_1based, time, end_or_None)]."""
    lines = ["osu file format v14", "", "[General]", "Mode: 3", "",
             "[Metadata]", "Title:T", "Artist:A", "Creator:C", "Version:V", "",
             "[Difficulty]", f"CircleSize:{keys}", "", "[TimingPoints]", "0,500,4,1,0,100,1,0", "",
             "[HitObjects]"]
    for col, t, end in objects:
        x = int((col - 0.5) * 512 / keys)
        lines.append(f"{x},192,{t},128,0,{end}:0:0:0:0:" if end else f"{x},192,{t},1,0,0:0:0:0:")
    return "\n".join(lines) + "\n"


def test_small_maps_untouched():
    # <= 4 columns must not go through the fold: lanes == columns, same dicts as before
    sections = C.parse_osu(osu_text(4, [(1, 0, None), (2, 500, 900), (4, 1000, None)]))
    reds, svs = C.parse_timing(sections)
    info = {}
    notes, warns = C.convert_hitobjects(sections, reds, svs, 4, 3, lanes=4, fold_info=info)
    assert info == {} and not warns
    assert notes == [{"b": 0.0, "l": 1, "d": 0}, {"b": 1.0, "l": 2, "d": 0.8},
                     {"b": 2.0, "l": 4, "d": 0}], notes


def test_seven_key_integration():
    objs = [(c, 1000 * c, None) for c in range(1, 8)] + [(7, 9000, 9800), (6, 9400, None)]
    sections = C.parse_osu(osu_text(7, objs))
    reds, svs = C.parse_timing(sections)
    info = {}
    notes, warns = C.convert_hitobjects(sections, reds, svs, 7, 3, lanes=4, fold_info=info)
    assert all(1 <= n["l"] <= 4 for n in notes)
    assert info["from"] == 7 and info["to"] == 4 and info["source"] == 9, info
    assert info["kept"] + info["dropped"] == 9 and len(notes) == info["kept"]
    assert warns and "folded 7K -> 4 lanes" in warns[0], warns
    # column order is preserved for the plain taps: lane never decreases with the column
    taps = [n["l"] for n in notes if n["b"] < 8.0]
    assert taps == sorted(taps), taps


def test_convert_file_10k_end_to_end():
    # Regression for the old min(7, keys) clamp: a 10K map must be read as 10K.
    import contextlib
    import io
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        objs = [(1, 0, None), (5, 1000, None), (6, 2000, None), (10, 3000, None), (8, 4000, 4600)]
        (d / "m.osu").write_text(osu_text(10, objs), encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            chart = C.convert_file(d / "m.osu", d / "c", d / "a", d / "s", copy_audio=False)
        assert chart is not None and chart["sourceKeys"] == 10, chart and chart.get("sourceKeys")
        assert chart["fold"]["from"] == 10 and chart["fold"]["to"] == 4 and chart["fold"]["dropped"] == 0
        by_t = {round(n["b"] * 500): n["l"] for n in chart["charts"]["Keyboard"]}
        assert by_t[0] == 1 and by_t[1000] == 2 and by_t[2000] == 3 and by_t[3000] == 4, by_t
        assert "folded 10K->4 lanes" in chart["charter"], chart["charter"]
        assert (d / "c" / f"{chart['id']}.json").exists()
        # --no-fold behaviour: skipped, exactly like before
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            assert C.convert_file(d / "m.osu", d / "c2", d / "a", d / "s", copy_audio=False, fold_keys=False) is None


def main():
    tests = [(k, v) for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print(f"ok    {name}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL  {name}: {type(exc).__name__}: {exc}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
