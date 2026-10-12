#!/usr/bin/env python3
"""Offline tests for Quaver beat precision in qua2gakuran.py (SV teleport spikes).
Run: python tools/test_qua_precision.py   (exit code 0 = all passed)"""
import bisect
import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qua2gakuran as Q  # noqa: E402

BPM = 195.0
REF_BL_MS = 60000.0 / BPM

QUA = """Mode: Keys4
Title: Spike Test
Artist: A
Creator: C
DifficultyName: D
AudioFile: none.mp3
TimingPoints:
- StartTime: 0
  Bpm: 195
SliderVelocities:
- StartTime: 4864.984375
  Multiplier: 9856
- StartTime: 4865
  Multiplier: -9856
- StartTime: 4865.015625
  Multiplier: 1
- StartTime: 6000
  Multiplier: 0.5
- StartTime: 6000
  Multiplier: 2
HitObjects:
- StartTime: 4865
  Lane: 1
- StartTime: 4865.5
  Lane: 2
  EndTime: 5200.25
- StartTime: 7000
  Lane: 3
"""


def convert(text):
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "m.qua").write_text(text, encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            chart = Q.convert_file(d / "m.qua", d / "c", d / "a", d / "s")
    assert chart is not None
    return chart


def integral(changes, t_s):
    """Loader-style piecewise integral: rate 1 before the first change, t = (60/bpm)*b."""
    pts = [(60.0 / BPM) * c["b"] for c in changes]
    rates = [c["rate"] for c in changes]
    prefix, acc = [], pts[0]
    for i in range(len(pts)):
        if i:
            acc += (pts[i] - pts[i - 1]) * rates[i - 1]
        prefix.append(acc)
    if t_s <= pts[0]:
        return t_s
    i = bisect.bisect_right(pts, t_s) - 1
    return prefix[i] + (t_s - pts[i]) * rates[i]


def test_precision_constant():
    assert Q.BEAT_DECIMALS >= 9, Q.BEAT_DECIMALS


def test_spike_triple_survives():
    chart = convert(QUA)
    sc = chart["scrollChanges"]
    rates = [c["rate"] for c in sc]
    assert rates[:3] == [9856.0, -9856.0, 1.0], rates
    bs = [c["b"] for c in sc[:3]]
    assert bs[0] < bs[1] < bs[2], bs   # three distinct instants, not merged
    # spike widths in ms are preserved to well under a microsecond
    w1 = (bs[1] - bs[0]) * REF_BL_MS
    w2 = (bs[2] - bs[1]) * REF_BL_MS
    assert abs(w1 - 0.015625) < 1e-6 and abs(w2 - 0.015625) < 1e-6, (w1, w2)


RAW_SV = [(4864.984375, 9856.0), (4865.0, -9856.0), (4865.015625, 1.0), (6000.0, 0.5), (6000.0, 2.0)]


def exact_integral(t_s):
    """Quaver semantics straight from the source points: sequential segments, rate 1
    (InitialScrollVelocity) before the first one, last of equal times wins."""
    total, last_t, rate = 0.0, 0.0, 1.0
    for ms, r in RAW_SV:
        t = ms / 1000.0
        if t > t_s:
            break
        total += (t - last_t) * rate
        last_t, rate = t, r
    return total + (t_s - last_t) * rate


def test_integral_matches_source():
    # The converted scrollChanges must integrate to the SAME scroll distance as the raw
    # source points, including inside the spikes (4-decimal beats were off by 0.30
    # scroll-seconds here). 1e-6 scroll-s is ~0.002 px at 1920 px/s.
    sc = convert(QUA)["scrollChanges"]
    for t in (4.86, 4.864984375, 4.8649922, 4.865, 4.8650078, 4.8651, 5.5, 6.0, 6.5, 10.0):
        d = abs(integral(sc, t) - exact_integral(t))
        assert d < 1e-6, (t, d)


def test_same_instant_last_in_file_wins():
    sc = convert(QUA)["scrollChanges"]
    at6 = [c for c in sc if abs(c["b"] * REF_BL_MS - 6000.0) < 1e-6]
    assert len(at6) == 1 and at6[0]["rate"] == 2.0, at6


def test_note_and_hold_times_are_precise():
    chart = convert(QUA)
    notes = chart["charts"]["Keyboard"]
    by_lane = {n["l"]: n for n in notes}
    assert abs(by_lane[1]["b"] * REF_BL_MS - 4865.0) < 1e-6
    assert abs(by_lane[2]["b"] * REF_BL_MS - 4865.5) < 1e-6
    assert abs(by_lane[2]["d"] * REF_BL_MS - (5200.25 - 4865.5)) < 1e-6
    assert by_lane[3]["d"] == 0


def _qua_with_sv(points):
    sv = "".join(f"- StartTime: {t}\n  Multiplier: {m}\n" for t, m in points)
    head, rest = QUA.split("SliderVelocities:\n")
    return head + "SliderVelocities:\n" + sv + "HitObjects:" + rest.split("HitObjects:")[1]


def test_same_instant_winner_equal_to_predecessor_is_collapsed():
    # 2.0 at 1000, then at 2000: 5.0 followed by 2.0 (last in file wins) -> the 2000
    # point equals its predecessor and is redundant (one boundary suffices).
    sc = convert(_qua_with_sv([(1000, 2.0), (2000, 5.0), (2000, 2.0)]))["scrollChanges"]
    assert [c["rate"] for c in sc] == [2.0], sc
    # a THIRD point at the same instant must still win over the popped pair
    sc = convert(_qua_with_sv([(1000, 2.0), (2000, 5.0), (2000, 2.0), (2000, 7.0)]))["scrollChanges"]
    assert [c["rate"] for c in sc] == [2.0, 7.0], sc
    # and the generic invariant: no two consecutive equal rates anywhere
    sc = convert(_qua_with_sv([(1000, 1.5), (1500, 1.5), (2000, 3.0), (2000, 1.5), (2500, 1.5), (3000, 0.0)]))["scrollChanges"]
    assert all(abs(sc[i]["rate"] - sc[i + 1]["rate"]) > 1e-9 for i in range(len(sc) - 1)), sc


def test_json_roundtrip_keeps_precision():
    chart = convert(QUA)
    back = json.loads(json.dumps(chart, separators=(",", ":")))
    assert back["scrollChanges"] == chart["scrollChanges"]


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
