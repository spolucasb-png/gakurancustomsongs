#!/usr/bin/env python3
"""Offline tests for .ssc + #SCROLLS support in sm2gakuran.py.
Run: python tools/test_sm_scrolls.py   (exit code 0 = all passed)"""
import contextlib
import io
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm2gakuran as S  # noqa: E402

SSC = """#VERSION:0.83;
#TITLE:Scroll Test;
#ARTIST:A;
#MUSIC:test.mp3;
#OFFSET:0.0;
#BPMS:0.000=150.000;
#STOPS:;
#SCROLLS:0.000=1.000,
8.000=0.500,
16.000=0.000,
20.000=2.000,
20.000=1.000;
#STEPSTYPE:dance-single;
#DESCRIPTION:Charter;
#DIFFICULTY:Medium;
#METER:5;
#NOTES:
0000
0001
1000
0100,
0000
0000
0000
0000;
"""

SM = """#TITLE:Old Style;
#ARTIST:A;
#OFFSET:0.0;
#BPMS:0.000=150.000;
#STOPS:;
#NOTES:dance-single:Auth:Hard:7::0000
0001
1000
0100;
"""


def convert(text, suffix=".ssc"):
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / ("m" + suffix)).write_text(text, encoding="utf-8")
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            charts = S.convert_file(d / ("m" + suffix), d / "c", d / "a", d / "s")
    return charts, err.getvalue()


def test_scrolls_become_scroll_changes():
    charts, _ = convert(SSC)
    assert len(charts) == 1
    sc = charts[0]["scrollChanges"]
    # verbatim beats, verbatim rates incl. zero; same beat -> last in file wins
    assert [(c["b"], c["rate"]) for c in sc] == [
        (0.0, 1.0), (8.0, 0.5), (16.0, 0.0), (20.0, 1.0)], sc


def test_new_style_block_parsing():
    charts, _ = convert(SSC)
    c = charts[0]
    assert c["difficulty"] == {"Keyboard": "Medium"}, c["difficulty"]
    assert "Charter" in c["charter"], c["charter"]
    assert [(n["b"], n["l"], n["d"]) for n in c["charts"]["Keyboard"]] == [
        (1.0, 4, 0), (2.0, 1, 0), (3.0, 2, 0)], c["charts"]["Keyboard"]
    assert c["bpm"] == 150.0 and c["offsetMs"] == 0


def test_speeds_warns_loudly_but_still_converts():
    text = SSC.replace("#STOPS:;", "#STOPS:;\n#SPEEDS:0.000=1.000,0.000,0,8.000=2.000,4.000,0;")
    charts, err = convert(text)
    assert len(charts) == 1, charts
    assert "SKIPPED" in err and "#SPEEDS" in err, err
    # SCROLLS data is unaffected by the skipped SPEEDS
    assert [c["rate"] for c in charts[0]["scrollChanges"]] == [1.0, 0.5, 0.0, 1.0]


def test_old_sm_without_scrolls_unchanged():
    charts, _ = convert(SM, ".sm")
    assert len(charts) == 1
    c = charts[0]
    assert "scrollChanges" not in c, c.get("scrollChanges")
    assert [(n["b"], n["l"]) for n in c["charts"]["Keyboard"]] == [
        (1.0, 4), (2.0, 1), (3.0, 2)], c["charts"]["Keyboard"]
    assert c["id"] == "old_style_hard", c["id"]


def test_non_dance_block_skipped():
    text = SSC.replace("#STEPSTYPE:dance-single;", "#STEPSTYPE:pump-single;")
    charts, err = convert(text)
    assert charts == [], charts
    assert "not dance-single" in err, err


def test_stops_still_refuses():
    charts, err = convert(SSC.replace("#STOPS:;", "#STOPS:16.000=0.500;"))
    assert charts == [], charts
    assert "#STOPS" in err, err


def main():
    tests = [(k, v) for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except AssertionError as e:
            failed += 1
            print(f"FAIL {name}: {e}")
        else:
            print(f"ok    {name}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
