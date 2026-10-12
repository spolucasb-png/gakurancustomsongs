#!/usr/bin/env python3
"""Offline tests for archive staging + batch preservation (audit item 14).
Run: python tools/test_archives.py   (exit code 0 = all passed)

Covers: zip-slip/absolute/duplicate members refused on .osz and .qp,
top-level-only chart discovery (nested warns), corrupt archives skipped,
sentinel + pre-existing files byte-identical after an aborted batch.
"""
import contextlib
import io
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import convert_song as C  # noqa: E402
from test_qua_precision import QUA  # noqa: E402
from zipstage import nested_charts, safe_extract  # noqa: E402

OSU_MIN = """osu file format v14
[General]
AudioFilename: x.mp3
Mode: 3
[Metadata]
Title:T
Artist:A
Version:Hard
[Difficulty]
HPDrainRate:5
[TimingPoints]
0,315,-4,2,0,50,1,0
[HitObjects]
64,192,1000,1,0
320,192,2000,1,0
"""

SM_A = ("#TITLE:Same Song;\n#ARTIST:A;\n#OFFSET:0;\n#BPMS:0.000=120.000;\n"
        "#NOTES:dance-single:X:Hard:5::0001\n0000;\n")
SM_B = ("#TITLE:Same Song;\n#ARTIST:B;\n#OFFSET:0;\n#BPMS:0.000=140.000;\n"
        "#NOTES:dance-single:Y:Hard:9::1000\n0000;\n")


def make_zip(path, members):
    with zipfile.ZipFile(path, "w") as zf:
        for name, data in members.items():
            zf.writestr(name, data)


def run_frontend(inp, d):
    argv = ["convert_song.py", str(inp), "--charts-dir", str(d / "c"),
            "--audio-dir", str(d / "a"), "--assets-dir", str(d / "s")]
    old = sys.argv
    sys.argv = argv
    out, err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = C.main()
    finally:
        sys.argv = old
    return rc, out.getvalue(), err.getvalue()


def snapshot(d):
    snap = {}
    for sub in ("c", "a", "s"):
        root = d / sub
        if root.is_dir():
            for p in sorted(root.rglob("*")):
                if p.is_file():
                    snap[str(p.relative_to(d))] = p.read_bytes()
    return snap


def test_safe_extract_refuses_traversal():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        zp = d / "evil.zip"
        make_zip(zp, {"../evil.osu": OSU_MIN, "ok.osu": OSU_MIN})
        dest = d / "stage"
        dest.mkdir()
        try:
            with zipfile.ZipFile(zp) as zf:
                safe_extract(zf, dest)
        except ValueError as e:
            assert "escapes destination" in str(e), e
        else:
            raise AssertionError("traversal member accepted")
        assert not (d.parent / "evil.osu").exists()
        assert not list(dest.rglob("evil.osu"))


def test_safe_extract_refuses_absolute_and_duplicate():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        dest = d / "stage"
        dest.mkdir()
        zp = d / "abs.zip"
        make_zip(zp, {"/abs.osu": OSU_MIN})
        with zipfile.ZipFile(zp) as zf:
            try:
                safe_extract(zf, dest)
            except ValueError as e:
                assert "escapes destination" in str(e), e
            else:
                raise AssertionError("absolute member accepted")
        zp2 = d / "dup.zip"
        with zipfile.ZipFile(zp2, "w") as zf:
            zf.writestr("a.osu", OSU_MIN)
            zf.writestr("a.osu", OSU_MIN)
        with zipfile.ZipFile(zp2) as zf:
            try:
                safe_extract(zf, dest)
            except ValueError as e:
                assert "duplicate" in str(e), e
            else:
                raise AssertionError("duplicate member accepted")


def test_nested_charts_listed():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "top.osu").write_text("x")
        (d / "sub").mkdir()
        (d / "sub" / "deep.osu").write_text("x")
        found = nested_charts(d, ".osu")
        assert len(found) == 1 and found[0].name == "deep.osu", found


def test_osz_valid_converts_without_tree_litter():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        make_zip(d / "song.osz", {"song.osu": OSU_MIN})
        rc, out, _ = run_frontend(d, d)
        assert rc == 0, (rc, out)
        assert (d / "c" / "t_hard.json").exists()
        assert not (d / "c" / "_osz_tmp").exists(), "legacy staging dir leaked"


def test_osz_nested_warns_and_root_converts():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        make_zip(d / "song.osz", {"song.osu": OSU_MIN, "sub/deep.osu": OSU_MIN})
        rc, _, err = run_frontend(d, d)
        assert rc == 0, rc
        assert (d / "c" / "t_hard.json").exists()
        assert "NOT converted" in err and "deep.osu" in err, err


def test_osz_slip_and_corrupt_leave_tree_untouched():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        make_zip(d / "evil.osz", {"../evil.osu": OSU_MIN, "ok.osu": OSU_MIN})
        before = snapshot(d)
        rc, _, err = run_frontend(d / "evil.osz", d)
        assert rc == 1, rc
        assert "escapes destination" in err, err
        assert snapshot(d) == before
        (d / "bad.osz").write_bytes(b"not a zip at all")
        rc, _, err = run_frontend(d / "bad.osz", d)
        assert rc == 1, rc
        assert "not a valid .osz archive" in err, err
        assert snapshot(d) == before


def test_qp_valid_converts_nested_warns_slip_refused():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        make_zip(d / "good.qp", {"m.qua": QUA})
        rc, _, _ = run_frontend(d / "good.qp", d)
        assert rc == 0, rc
        assert list((d / "c").glob("*.json"))
        make_zip(d / "mix.qp", {"m2.qua": QUA, "sub/n.qua": QUA})
        rc, _, err = run_frontend(d / "mix.qp", d)
        assert rc == 0, rc
        assert "NOT converted" in err and "n.qua" in err, err
        before = snapshot(d)
        make_zip(d / "evil.qp", {"../evil.qua": QUA})
        rc, _, err = run_frontend(d / "evil.qp", d)
        assert rc == 1, rc
        assert "escapes destination" in err, err
        assert snapshot(d) == before


def test_colliding_batch_aborts_tree_pristine():
    # In-batch collision: both twins rolled back, sentinels intact, rc nonzero.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        src = d / "src"
        src.mkdir()
        (src / "a.sm").write_text(SM_A, encoding="utf-8")
        (src / "b.sm").write_text(SM_B, encoding="utf-8")
        for sub, name in (("c", "keep.json"), ("a", "keep.mp3"), ("s", "keep.jpg")):
            (d / sub).mkdir(parents=True, exist_ok=True)
            (d / sub / name).write_bytes(b"sentinel-" + name.encode())
        before = snapshot(d)
        rc, _, err = run_frontend(src, d)
        assert rc == 1, rc
        assert "batch aborted" in err and "collision" in err, err
        assert snapshot(d) == before, "partial output survived the abort"


def test_existing_file_collision_preserved_byte_for_byte():
    # An input colliding with a PRE-EXISTING destination JSON is refused and
    # the existing file survives byte-for-byte.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "a.sm").write_text(SM_A, encoding="utf-8")
        rc, _, _ = run_frontend(d / "a.sm", d)
        assert rc == 0, rc
        victim = d / "c" / "same_song_hard.json"
        original = victim.read_bytes()
        (d / "b.sm").write_text(SM_B, encoding="utf-8")
        rc, _, err = run_frontend(d / "b.sm", d)
        assert rc == 1, rc
        assert "refusing to overwrite" in err, err
        assert victim.read_bytes() == original


def main():
    tests = [(k, v) for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
        except AssertionError as e:
            failed += 1
            print(f"FAIL {name}: {e}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"ERROR {name}: {type(exc).__name__}: {exc}")
        else:
            print(f"ok    {name}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
