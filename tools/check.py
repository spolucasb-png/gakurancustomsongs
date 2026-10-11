#!/usr/bin/env python3
"""Pre-deploy gate for GakuranChart: syntax-check everything before it reaches
the executor workspace.

Why this exists: GakuranChart.lua is a 3,000+ line single file that is only ever
run by executing it in-game. A syntax error therefore costs a full round trip
(copy -> alt-tab -> execute -> read the error) to discover. This catches it in
about a second, offline.

How the Luau check works: `luau` has no syntax-only mode, so we prepend a
sentinel print to a temp copy and run it. Luau compiles the whole chunk before
executing any of it, so:
  * sentinel printed  -> the file parsed (the runtime error that follows is
                         expected: there is no `game` outside Roblox)
  * sentinel missing  -> the file did not parse; the compiler message is the
                         real syntax error, with its line number
Exit code 0 = everything passed.
"""
import json
import py_compile
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SENTINEL = "__GAKURAN_PARSE_OK__"
LUAU = shutil.which("luau") or str(Path.home() / ".rokit/bin/luau.exe")


def check_luau(path: Path) -> list:
    """Return a list of error strings ([] = parsed cleanly)."""
    if not Path(LUAU).exists():
        return [f"luau not found at {LUAU} (install: rokit add --global luau-lang/luau)"]
    src = path.read_text(encoding="utf-8", errors="replace")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / path.name
        tmp.write_text(f'print("{SENTINEL}")\n' + src, encoding="utf-8")
        proc = subprocess.run([LUAU, str(tmp)], capture_output=True, text=True, timeout=120)
    out = (proc.stdout or "") + (proc.stderr or "")
    if SENTINEL in out:
        return []
    # Strip the temp path and our one-line offset so the numbers match the real file.
    errs = []
    for line in out.splitlines():
        if not line.strip() or line.startswith("stacktrace"):
            continue
        # luau prints the path with forward slashes (and Windows may shorten
        # it to 8.3 form), so match on the basename rather than the full path.
        line = re.sub(r"\S*" + re.escape(tmp.name), path.name, line)
        line = re.sub(rf"{re.escape(path.name)}:(\d+):",
                      lambda m: f"{path.name}:{int(m.group(1)) - 1}:", line)
        errs.append(line)
    return errs or ["did not parse (no compiler output)"]


def check_python(path: Path) -> list:
    try:
        py_compile.compile(str(path), cfile=tempfile.mktemp(), doraise=True)
        return []
    except py_compile.PyCompileError as e:
        return [str(e).strip()]


def check_json(path: Path) -> list:
    try:
        json.loads(path.read_text(encoding="utf-8"))
        return []
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        return [f"{path.name}: {e}"]


def main() -> int:
    targets = []
    for pat in ("GakuranChart.lua",):
        targets += [(p, check_luau) for p in sorted(ROOT.glob(pat))]
    targets += [(p, check_python) for p in sorted((ROOT / "tools").glob("*.py"))]
    charts = ROOT / "GakuranCharts" / "Charts"
    if charts.is_dir():
        targets += [(p, check_json) for p in sorted(charts.glob("*.json"))]
    for p in sorted((ROOT / "GakuranCharts" / "Skins").glob("*/manifest.json")):
        targets.append((p, check_json))

    failed = 0
    for path, fn in targets:
        errs = fn(path)
        rel = path.relative_to(ROOT).as_posix()
        if errs:
            failed += 1
            print(f"FAIL  {rel}")
            for e in errs:
                print(f"      {e}")
        else:
            print(f"ok    {rel}")
    print()
    if failed:
        print(f"{failed} file(s) FAILED - do not deploy")
        return 1
    print(f"all {len(targets)} file(s) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
