#!/usr/bin/env python3
"""Offline tests for .ssc + #SCROLLS support in sm2gakuran.py.
Run: python tools/test_sm_scrolls.py   (exit code 0 = all passed)"""
import contextlib
import io
import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sm2gakuran as S  # noqa: E402
import convert_song as C  # noqa: E402

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
    S.begin_batch()  # each direct call is its own batch: no refusal may leak
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


SSC2 = """#TITLE:Two Diff;
#ARTIST:A;
#OFFSET:0.0;
#BPMS:0.000=100.000;
#SCROLLS:0.000=9.000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Easy;
#METER:3;
#SCROLLS:0.000=0.500,4.000=1.000;
#NOTES:
0001
0000,
0000
0000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Hard;
#METER:8;
#SCROLLS:0.000=2.000;
#SPEEDS:0.000=1.000,0.000,0;
#NOTES:
1000
0000,
0000
0000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Stopped;
#METER:5;
#STOPS:4.000=0.500;
#NOTES:
0100
0000;
"""


def by_diff(charts):
    return {c["difficulty"]["Keyboard"]: c for c in charts}


def test_per_chart_scrolls_isolated():
    # Each difficulty keeps its OWN scrolls; the global 9.0 must not leak in,
    # and the stopped chart's absence must not disturb the others.
    charts, _ = convert(SSC2)
    assert len(charts) == 2, [c["id"] for c in charts]
    d = by_diff(charts)
    assert [(c["b"], c["rate"]) for c in d["Easy"]["scrollChanges"]] == [
        (0.0, 0.5), (4.0, 1.0)], d["Easy"]["scrollChanges"]
    assert [(c["b"], c["rate"]) for c in d["Hard"]["scrollChanges"]] == [
        (0.0, 2.0)], d["Hard"]["scrollChanges"]
    assert "Stopped" not in d


def test_per_chart_stops_skips_only_that_chart():
    charts, err = convert(SSC2)
    ids = [c["id"] for c in charts]
    assert "two_diff_stopped" not in ids, ids
    assert "two_diff_easy" in ids and "two_diff_hard" in ids, ids
    assert "Stopped" in err and "#STOPS" in err, err


def test_per_chart_speeds_names_the_chart():
    charts, err = convert(SSC2)
    assert len(charts) == 2
    assert "[Hard]" in err and "SKIPPED" in err, err
    # the warning is chart-scoped: no SPEEDS warning is attributed to Easy
    assert "[Easy]" not in err, err


def test_global_scrolls_fallback():
    # A chart block with NO timing tags of its own inherits the global ones.
    text = SSC2.split("#STEPSTYPE:")[1]
    text = "#TITLE:F;\n#ARTIST:A;\n#OFFSET:0;\n#BPMS:0.000=100.000;\n#SCROLLS:0.000=0.250;\n#STEPSTYPE:" + text
    charts, _ = convert(text)
    assert len(charts) == 1
    assert [(c["b"], c["rate"]) for c in charts[0]["scrollChanges"]] == [
        (0.0, 0.5), (4.0, 1.0)], charts[0]["scrollChanges"]


def test_notes2_block_parses():
    text = """#TITLE:N2;
#ARTIST:A;
#OFFSET:0;
#BPMS:0.000=120.000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Edit;
#METER:6;
#NOTES2:
0001
0000;
"""
    charts, _ = convert(text)
    assert len(charts) == 1, charts
    assert charts[0]["id"] == "n2_edit", charts[0]["id"]
    assert [(n["b"], n["l"]) for n in charts[0]["charts"]["Keyboard"]] == [(0.0, 4)]


def test_chart_id_collision_refused_not_overwritten():
    # AUDIT item 14 HIGH 03: same chart id from a different file must never
    # silently overwrite — and the batch aborts with ZERO partial output
    # (the first chart's files are rolled back too, not left behind).
    other = SM.replace("#ARTIST:A;", "#ARTIST:B;").replace("150.000", "140.000")
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        S.begin_batch()  # delimit: direct calls share process batch state
        (d / "a.sm").write_text(SM, encoding="utf-8")
        (d / "b.sm").write_text(other, encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            first = S.convert_file(d / "a.sm", d / "c", d / "a", d / "s")
        assert len(first) == 1
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            second = S.convert_file(d / "b.sm", d / "c", d / "a", d / "s")
        assert second == [], second
        assert "refusing to overwrite" in err.getvalue(), err.getvalue()
        leftovers = list((d / "c").glob("*.json")) + list((d / "a").glob("*"))
        assert leftovers == [], [p.name for p in leftovers]
        # identical re-convert stays idempotent (no refusal)
        (d / "b.sm").write_text(SM, encoding="utf-8")
        S.begin_batch()  # new batch: the refusal above must not leak into it
        err2 = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err2):
            third = S.convert_file(d / "b.sm", d / "c", d / "a", d / "s")
        assert len(third) == 1, third
        assert "refusing to overwrite" not in err2.getvalue(), err2.getvalue()


def test_sanitized_id_collision_detected():
    # "A/B" and "A B" normalize to the same chart id: the collision is about
    # the ID contract, not the raw titles.
    var = SM.replace("#TITLE:Old Style;", "#TITLE:Old/Style;").replace("150.000", "140.000")
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        S.begin_batch()  # delimit: direct calls share process batch state
        (d / "a.sm").write_text(SM, encoding="utf-8")
        (d / "b.sm").write_text(var, encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            first = S.convert_file(d / "a.sm", d / "c", d / "a", d / "s")
        assert len(first) == 1
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            second = S.convert_file(d / "b.sm", d / "c", d / "a", d / "s")
        assert second == [], second
        assert "refusing to overwrite" in err.getvalue(), err.getvalue()
        assert list((d / "c").glob("*.json")) == [], "rolled back"


SSC3A = """#TITLE:Three Diff;
#ARTIST:A;
#OFFSET:0;
#BPMS:0.000=120.000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Easy;
#METER:2;
#NOTES:
0001
0000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Medium;
#METER:4;
#NOTES:
0001
0010;
"""

SSC3B = """#TITLE:Three Diff;
#ARTIST:A;
#OFFSET:0;
#BPMS:0.000=120.000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Hard;
#METER:7;
#NOTES:
1000
0100
0010;
"""

SSC_HARD_ONLY = """#TITLE:Two Diff;
#ARTIST:A;
#OFFSET:0.0;
#BPMS:0.000=100.000;
#SCROLLS:0.000=9.000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Hard;
#METER:8;
#SCROLLS:0.000=2.000;
#SPEEDS:0.000=1.000,0.000,0;
#NOTES:
1000
0000,
0000
0000;
"""

GROW1 = """#TITLE:Growing;
#ARTIST:A;
#OFFSET:0;
#BPMS:0.000=120.000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Easy;
#METER:2;
#NOTES:
0001
0000;
"""

GROW2 = """#TITLE:Growing;
#ARTIST:A;
#OFFSET:0;
#BPMS:0.000=120.000;
#STEPSTYPE:dance-single;
#DIFFICULTY:Medium;
#METER:4;
#NOTES:
0001
0010;
"""


def run_sm(inp, d):
    argv = ["sm2gakuran.py", str(inp), "--charts-dir", str(d / "c"),
            "--audio-dir", str(d / "a"), "--assets-dir", str(d / "s")]
    old = sys.argv
    sys.argv = argv
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = S.main()
    finally:
        sys.argv = old
    return rc, out.getvalue(), err.getvalue()


def snap_jsons(d):
    return {p.name: p.read_bytes() for p in sorted((d / "c").glob("*.json"))}


def test_partial_rerun_preserves_saved_rank():
    # Policy (b): rerunning Hard alone must not rewrite its saved rank 2.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "full.ssc").write_text(SSC2, encoding="utf-8")
        assert run_sm(d / "full.ssc", d)[0] == 0
        before = snap_jsons(d)
        assert json.loads(before["two_diff_hard.json"].decode("utf-8"))["rank"] == 2
        (d / "hard.ssc").write_text(SSC_HARD_ONLY, encoding="utf-8")
        (d / "full.ssc").unlink()
        rc, _, err = run_sm(d / "hard.ssc", d)
        assert rc == 0, err
        assert "batch aborted" not in err, err
        assert snap_jsons(d) == before, "partial rerun rewrote ranked files"


def test_two_of_three_counts_partial():
    # Two files, one song: full batch ranks 1-2-3; the two-diff file alone
    # is partial and must leave both saved files byte-identical.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "em.ssc").write_text(SSC3A, encoding="utf-8")
        (d / "h.ssc").write_text(SSC3B, encoding="utf-8")
        assert run_sm(d, d)[0] == 0
        before = snap_jsons(d)
        assert len(before) == 3, sorted(before)
        (d / "h.ssc").unlink()
        rc, _, err = run_sm(d / "em.ssc", d)
        assert rc == 0, err
        assert snap_jsons(d) == before, "partial rerun rewrote ranked files"


def test_new_difficulty_partial_warns_provisional():
    # A new difficulty in a partial run keeps its provisional rank-1 file and
    # warns loudly; the existing sibling is untouched.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "e.ssc").write_text(GROW1, encoding="utf-8")
        assert run_sm(d / "e.ssc", d)[0] == 0
        easy_before = (d / "c" / "growing_easy.json").read_bytes()
        (d / "e.ssc").unlink()
        (d / "m.ssc").write_text(GROW2, encoding="utf-8")
        rc, _, err = run_sm(d / "m.ssc", d)
        assert rc == 0, err
        assert "provisional" in err and "full-song" in err, err
        assert (d / "c" / "growing_easy.json").read_bytes() == easy_before
        med = json.loads((d / "c" / "growing_medium.json").read_bytes().decode("utf-8"))
        assert med["rank"] == 1, med["rank"]


def test_full_cli_rerun_multi_difficulty_idempotent():
    # AUDIT P1-2: rank is assigned AFTER writing (assign_ranks rewrites the
    # files), so a rerun constructs rank=1 where the saved files carry final
    # ranks. Rank is excluded from collision identity: the second full run
    # must exit 0 with zero byte changes.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "m.ssc").write_text(SSC2, encoding="utf-8")

        def run():
            argv = ["sm2gakuran.py", str(d / "m.ssc"), "--charts-dir", str(d / "c"),
                    "--audio-dir", str(d / "a"), "--assets-dir", str(d / "s")]
            old = sys.argv
            sys.argv = argv
            try:
                with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    return S.main()
            finally:
                sys.argv = old

        def snap():
            return {p.name: p.read_bytes() for p in sorted((d / "c").glob("*.json"))}

        assert run() == 0
        first = snap()
        assert len(first) == 2, sorted(first)
        # the trap is set: saved ranks are final (Hard carries rank 2), while
        # a fresh conversion constructs rank 1 for every chart
        assert json.loads(first["two_diff_hard.json"].decode("utf-8"))["rank"] == 2
        assert run() == 0
        assert snap() == first, "rerun changed bytes"


def test_unified_frontend_handles_sm_and_ssc():
    # convert_song.py must accept the list return (dict access in assign_ranks
    # raised TypeError on bare lists) and discover .ssc next to .sm.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "a.sm").write_text(SM, encoding="utf-8")
        (d / "b.ssc").write_text(SSC, encoding="utf-8")
        argv = ["convert_song.py", str(d), "--charts-dir", str(d / "c"),
                "--audio-dir", str(d / "a"), "--assets-dir", str(d / "s")]
        old = sys.argv
        sys.argv = argv
        try:
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                rc = C.main()
        finally:
            sys.argv = old
        assert rc == 0, rc
        outs = sorted((d / "c").glob("*.json"))
        assert len(outs) == 2, [p.name for p in outs]


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
