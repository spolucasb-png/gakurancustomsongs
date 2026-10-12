#!/usr/bin/env python3
"""Shared archive staging for the song converters (.osz/.qp are ZIPs).

safe_extract() replaces bare extractall(): unique staging directories come
from tempfile.TemporaryDirectory at the call sites (never inside the output
tree), members are validated before any byte is written, and cleanup rides
the context manager even when conversion raises.
"""
import os
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


def safe_extract(zf: zipfile.ZipFile, dest: Path) -> int:
    """Extract ZIP members into dest, refusing hostile archives.

    Absolute paths, drive letters, '..' escapes and duplicate member paths
    raise ValueError before anything outside dest is touched (fail loudly; a
    hostile archive must not partially convert). Returns the file count.
    """
    dest = dest.resolve()
    seen = set()
    # File/directory structural conflicts (a file "a" alongside "a/x.osu")
    # are refused up front: extraction order would otherwise decide between
    # a mkdir/open crash. Comparison is normcase'd so case-only variants
    # collide on case-insensitive filesystems too. Directory markers ("a/")
    # with content under them are normal and pass; only a FILE member
    # prefixing another member fails.
    flat = [(info.filename.replace("\\", "/")) for info in zf.infolist()]

    def _key(n):
        # normcase folds case on case-insensitive filesystems; the separator
        # is re-unified to "/" afterwards because normcase emits os.sep
        # (backslash on Windows), which would defeat the prefix walk below.
        return os.path.normcase(n).replace(os.sep, "/")

    files = {_key(n.rstrip("/")) for n in flat if n and not n.endswith("/")}
    for n in sorted(files):
        parent, sep, _ = n.rpartition("/")
        while sep:
            if parent in files:
                raise ValueError(
                    f"conflicting archive members (file/directory): {parent!r} vs {n!r}")
            parent, sep, _ = parent.rpartition("/")
    count = 0
    for info in zf.infolist():
        name = info.filename.replace("\\", "/")
        if not name or name.endswith("/"):
            continue
        target = (dest / name).resolve()
        # Duplicates are detected on the canonical staged target (resolved +
        # OS-normalized), not the raw member name: "a.osu" vs "./a.osu" (and
        # case variants on Windows) would otherwise overwrite each other.
        key = os.path.normcase(str(target))
        if key in seen:
            raise ValueError(f"duplicate archive member for staged path: {info.filename!r}")
        seen.add(key)
        try:
            target.relative_to(dest)
        except ValueError:
            raise ValueError(f"archive member escapes destination: {info.filename!r}")
        target.parent.mkdir(parents=True, exist_ok=True)
        with zf.open(info) as src, open(target, "wb") as out:
            shutil.copyfileobj(src, out)
        count += 1
    return count


def nested_charts(root: Path, suffix: str) -> list:
    """Chart files below the extraction root (converters read top-level only).

    Returned so callers can warn loudly instead of silently ignoring them.
    """
    top = {p for p in root.glob(f"*{suffix}")}
    return sorted(set(root.rglob(f"*{suffix}")) - top)


def convert_archive(arch_path: Path, kind: str, suffix: str, convert_fn,
                    charts_dir: Path, audio_dir: Path, assets_dir: Path, kw: dict):
    """Stage a .osz/.qp-style archive and convert its top-level charts.

    kind ("osz"/"qp") labels messages; convert_fn(chart_path, charts_dir,
    audio_dir, assets_dir, **kw) returns one chart, a list, or a falsy skip.
    Staging is a unique TemporaryDirectory outside the output tree (never the
    legacy charts/_osz_tmp); members are validated before extraction; nested
    charts warn loudly instead of being silently ignored; corrupt/hostile
    archives skip with a message and convert nothing. Returns chart list.
    """
    out = []
    try:
        zf = zipfile.ZipFile(arch_path)
    except zipfile.BadZipFile:
        print(f"  - skipped '{arch_path.name}': not a valid .{kind} archive",
              file=sys.stderr)
        return out
    with zf:
        with tempfile.TemporaryDirectory(prefix=f"{kind}_") as tmp:
            tmp = Path(tmp)
            try:
                safe_extract(zf, tmp)
            except (ValueError, zipfile.BadZipFile, EOFError) as e:
                # ValueError: hostile/duplicate members; BadZipFile: CRC or
                # structural corruption found while reading a member; EOFError:
                # truncated member data. Deliberately narrow: anything else is
                # a programming error and must surface, not skip silently.
                print(f"  - skipped '{arch_path.name}': {e}", file=sys.stderr)
                return out
            for member in sorted(tmp.glob(f"*{suffix}")):
                from osu2gakuran import WRITE_REFUSALS  # deferred: no load-time cycle
                if WRITE_REFUSALS:
                    break  # batch refused: stop before further members write
                c = convert_fn(member, charts_dir, audio_dir, assets_dir, **kw)
                if isinstance(c, list):
                    out.extend(c)
                elif c:
                    out.append(c)
            for n in nested_charts(tmp, suffix):
                print(f"  ! '{n}' nested inside '{arch_path.name}': NOT converted "
                      f"(top-level charts only)", file=sys.stderr)
    return out
