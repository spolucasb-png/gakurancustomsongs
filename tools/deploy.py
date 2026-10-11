#!/usr/bin/env python3
"""Gate-then-copy GakuranChart.lua into the executor workspace.

Always runs tools/check.py first and refuses to copy if anything fails, so a
syntax-broken loader can never reach the workspace. Default target is a
*candidate* filename (per the project rule: keep the known-good deployed copy
until the new one is verified live); pass --live to overwrite GakuranChart.lua.

  python tools/deploy.py                 -> Workspace/GakuranChart_candidate.lua
  python tools/deploy.py --name fixes    -> Workspace/GakuranChart_fixes_candidate.lua
  python tools/deploy.py --live          -> Workspace/GakuranChart.lua
  python tools/deploy.py --clean         -> delete stale *_candidate.lua, then exit
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_WS = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local")) / "Madium/Workspace"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--workspace", type=Path, default=DEFAULT_WS, help="executor workspace")
    ap.add_argument("--name", default=None, help="candidate label (default: plain 'candidate')")
    ap.add_argument("--live", action="store_true", help="deploy as GakuranChart.lua")
    ap.add_argument("--clean", action="store_true", help="remove stale candidate files and exit")
    ap.add_argument("--skip-check", action="store_true", help="escape hatch; not recommended")
    args = ap.parse_args()

    ws = args.workspace
    if not ws.is_dir():
        print(f"workspace not found: {ws}", file=sys.stderr)
        return 2

    if args.clean:
        n = 0
        for f in sorted(ws.glob("GakuranChart*_candidate.lua")) + sorted(ws.glob("GakuranChart_v*.lua")):
            f.unlink()
            print(f"removed {f.name}")
            n += 1
        print(f"{n} stale candidate file(s) removed")
        return 0

    if not args.skip_check:
        rc = subprocess.run([sys.executable, "-I", str(ROOT / "tools/check.py")]).returncode
        if rc != 0:
            print("\ncheck failed - nothing deployed", file=sys.stderr)
            return 1
        print()

    src = ROOT / "GakuranChart.lua"
    if args.live:
        dst = ws / "GakuranChart.lua"
    else:
        label = f"_{args.name}" if args.name else ""
        dst = ws / f"GakuranChart{label}_candidate.lua"
    shutil.copy2(src, dst)
    print(f"deployed -> {dst}")
    print(f"           run_executor_file: {dst.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
