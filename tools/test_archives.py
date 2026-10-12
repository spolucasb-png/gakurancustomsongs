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


def test_safe_extract_refuses_aliased_and_case_duplicates():
    # "./a.osu" resolves onto "a.osu": same staged target, must refuse on
    # every OS. Case variants refuse exactly where the OS folds them.
    import os as _os
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        dest = d / "stage"
        dest.mkdir()
        zp = d / "alias.zip"
        with zipfile.ZipFile(zp, "w") as zf:
            zf.writestr("a.osu", OSU_MIN)
            zf.writestr("./a.osu", OSU_MIN)
        with zipfile.ZipFile(zp) as zf:
            try:
                safe_extract(zf, dest)
            except ValueError as e:
                assert "duplicate" in str(e), e
            else:
                raise AssertionError("aliased duplicate accepted")
        zp2 = d / "case.zip"
        with zipfile.ZipFile(zp2, "w") as zf:
            zf.writestr("A.osu", OSU_MIN)
            zf.writestr("a.osu", OSU_MIN)
        with zipfile.ZipFile(zp2) as zf:
            if _os.path.normcase("A.osu") == _os.path.normcase("a.osu"):
                try:
                    safe_extract(zf, dest)
                except ValueError as e:
                    assert "duplicate" in str(e), e
                else:
                    raise AssertionError("case duplicate accepted on folding OS")
            else:
                assert safe_extract(zf, dest) == 2


def corrupt_payload(data: bytes, needle: bytes) -> bytes:
    # Flip one stored payload byte without touching headers: the central
    # directory stays readable, the member CRC breaks on read.
    i = data.find(needle)
    assert i >= 0, needle
    return data[:i] + bytes([data[i] ^ 0x01]) + data[i + 1:]


def test_file_directory_conflicts_refused_both_formats():
    # A file member prefixing another member's directory ("a" + "a/x.osu")
    # must skip cleanly, not crash in mkdir/open; staging temp cleans itself.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        with zipfile.ZipFile(d / "conf.osz", "w") as zf:
            zf.writestr("a", b"plain file, not a chart")
            zf.writestr("a/song.osu", OSU_MIN)
        with zipfile.ZipFile(d / "conf.qp", "w") as zf:
            zf.writestr("q", b"plain file, not a chart")
            zf.writestr("q/m.qua", QUA)
        before = snapshot(d)
        for arch in ("conf.osz", "conf.qp"):
            rc, _, err = run_frontend(d / arch, d)
            assert rc == 1, (arch, rc)
            assert "conflicting archive members" in err, (arch, err)
        assert snapshot(d) == before, "conflict run left output behind"


def test_explicit_dir_markers_with_content_pass():
    # A directory marker ("sub/") with content under it is normal archival
    # practice, not a conflict: extraction succeeds.
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        zp = d / "dirs.zip"
        with zipfile.ZipFile(zp, "w") as zf:
            zf.writestr("sub/", "")
            zf.writestr("sub/x.osu", OSU_MIN)
        dest = d / "stage"
        dest.mkdir()
        with zipfile.ZipFile(zp) as zf:
            assert safe_extract(zf, dest) == 1
        assert (dest / "sub" / "x.osu").exists()


def test_crc_corrupt_archives_skip_cleanly_both_formats():
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        raw = d / "raw.zip"
        with zipfile.ZipFile(raw, "w") as zf:
            zf.writestr("song.osu", OSU_MIN)
        bad = corrupt_payload(raw.read_bytes(), b"Mode: 3")
        (d / "bad.osz").write_bytes(bad)
        rawq = d / "rawq.zip"
        with zipfile.ZipFile(rawq, "w") as zf:
            zf.writestr("m.qua", QUA)
        badq = corrupt_payload(rawq.read_bytes(), b"Keys4")
        (d / "bad.qp").write_bytes(badq)
        before = snapshot(d)
        for arch, needle in (("bad.osz", "Bad CRC"), ("bad.qp", "Bad CRC")):
            rc, _, err = run_frontend(d / arch, d)
            assert rc == 1, (arch, rc)
            assert needle in err, (arch, err)
        assert snapshot(d) == before, "corrupt archive left output behind"


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


def test_abort_stops_later_writes_including_media():
    # Unique charts BEFORE and AFTER the collision (plus media on both sides)
    # must not persist: refusal aborts the batch, rollback removes everything.
    sm_good = (SM_A.replace("#TITLE:Same Song;", "#TITLE:Good Song;")
                     .replace("#OFFSET:0;", "#OFFSET:0;\n#MUSIC:m.mp3;"))
    sm_late = (SM_A.replace("#TITLE:Same Song;", "#TITLE:Late Song;")
                     .replace("#OFFSET:0;", "#OFFSET:0;\n#MUSIC:late.mp3;"))
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        src = d / "src"
        src.mkdir()
        (src / "m.mp3").write_bytes(b"fake-audio-good")
        (src / "late.mp3").write_bytes(b"fake-audio-late")
        (src / "a.sm").write_text(sm_good, encoding="utf-8")
        (src / "b1.sm").write_text(SM_A, encoding="utf-8")
        (src / "b2.sm").write_text(SM_B, encoding="utf-8")
        (src / "c.sm").write_text(sm_late, encoding="utf-8")
        rc, _, err = run_frontend(src, d)
        assert rc == 1, rc
        assert "batch aborted" in err, err
        leftovers = (list((d / "c").glob("*")) if (d / "c").is_dir() else [])
        leftovers += (list((d / "a").glob("*")) if (d / "a").is_dir() else [])
        leftovers += (list((d / "s").glob("*")) if (d / "s").is_dir() else [])
        assert leftovers == [], [p.name for p in leftovers]


def test_abort_inside_archive_stops_members_and_preserves_existing():
    # Archive members [a_twin (collides with pre-existing), z_late (unique)]:
    # the twin refuses, the loop breaks before z_late, the pre-existing file
    # survives byte-for-byte, nothing is added.
    twin = OSU_MIN.replace("Title:T", "Title:Same Song")
    late = OSU_MIN.replace("Title:T", "Title:Late Song")
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "seed.sm").write_text(SM_A, encoding="utf-8")
        rc, _, _ = run_frontend(d / "seed.sm", d)
        assert rc == 0, rc
        victim = d / "c" / "same_song_hard.json"
        original = victim.read_bytes()
        (d / "seed.sm").unlink()
        with zipfile.ZipFile(d / "box.osz", "w") as zf:
            zf.writestr("a_twin.osu", twin)
            zf.writestr("z_late.osu", late)
        before = snapshot(d)
        rc, _, err = run_frontend(d / "box.osz", d)
        assert rc == 1, rc
        assert "batch aborted" in err, err
        assert victim.read_bytes() == original, "pre-existing file damaged"
        assert snapshot(d) == before, "partial output survived the abort"


def test_rollback_failures_are_reported():
    # A deletion that fails must be recorded + warned, not silently swallowed.
    import osu2gakuran as O
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        target = d / "stuck.json"
        target.write_text("x")
        O.WRITTEN_CHARTS.append(target)
        real_unlink = Path.unlink
        Path.unlink = lambda self, *a, **k: (_ for _ in ()).throw(OSError("locked"))
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                O.rollback_batch()
        finally:
            Path.unlink = real_unlink
            O.WRITTEN_CHARTS.clear()
            O.ROLLBACK_ERRORS.clear()
    assert "could not delete" in err.getvalue(), err.getvalue()


def test_malformed_existing_json_refuses_and_rolls_back():
    # AUDIT P1 (follow-up): a pre-existing destination holding `[]` is valid
    # JSON but not an object — .items() would raise AttributeError past the
    # old ValueError-only handler. It must refuse + roll back instead.
    _malformed_victim_case(b"[]")


def test_invalid_utf8_existing_json_refuses_and_rolls_back():
    # Same path via undecodable bytes (UnicodeDecodeError is a ValueError,
    # not an OSError, so the old read handler missed it too).
    _malformed_victim_case(b"\xff\xfe{\x00bad")


def _malformed_victim_case(victim_bytes):
    sm_good = (SM_A.replace("#TITLE:Same Song;", "#TITLE:Good Song;")
                     .replace("#OFFSET:0;", "#OFFSET:0;\n#MUSIC:g.mp3;"))
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        src = d / "src"
        src.mkdir()
        (src / "g.mp3").write_bytes(b"fake-audio-good")
        (src / "a_good.sm").write_text(sm_good, encoding="utf-8")
        (src / "b_twin.sm").write_text(SM_B, encoding="utf-8")
        (d / "c").mkdir(parents=True, exist_ok=True)
        victim = d / "c" / "same_song_hard.json"
        victim.write_bytes(victim_bytes)
        rc, _, err = run_frontend(src, d)
        assert rc == 1, rc
        assert "refusing to overwrite" in err and "batch aborted" in err, err
        assert victim.read_bytes() == victim_bytes, "victim damaged"
        assert sorted(p.name for p in (d / "c").glob("*")) == ["same_song_hard.json"]
        aud = list((d / "a").glob("*")) if (d / "a").is_dir() else []
        assert aud == [], [p.name for p in aud]


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
