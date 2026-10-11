# Handoff (for the next chat session)

## State
`GakuranChart.lua` is the single loader, **v2.0.15**. Everything below was
verified live on placeVersion 7646 (Madium 2.0.0) before being committed.

Recent work, newest first:
- **v2.0.15 — instrument no longer stays equipped through the end screen.**
  Reported from play. `restoreAttributes` now writes with three engine teardown
  listeners suppressed (`stopIfInvalidContext`, `recheck@RhythmWheelServiceClient`,
  `sync@InstrumentServiceClient`), so the unequip goes through while the results
  screen survives; `surfaceStillUp` no longer waits on `_resultsScreen`. See
  ROADMAP 9b for the four experiments that pinned it down.
- **v2.0.14 — single-pass `getgc`.** One heap sweep instead of nine.
  1.695 s -> 0.566 s on a ~2M-object heap. Validated by `diag()` output being
  identical to the v2.0.13 baseline.
- **v2.0.13 — `diag()`.** Startup self-test: getgc targets, service state and
  methods, per-hook-slot status, counts, settings, summary line.
- **v2.0.12 — ROADMAP section 5 small fixes** (note sort, `notify` reaching
  Rayfield, image background dim, per-chart `offsetMs`, the `getfenv` guard,
  `SKINS_DIR`) plus the converter's chart-id collision fix.

## Workflow
- **Always `python tools/check.py` (or `tools/deploy.py`, which runs it) before
  deploying.** It parse-checks the loader offline with the `luau` CLI, compiles
  the Python tools and validates chart/skin JSON. `rokit add --global
  luau-lang/luau` if `luau` is missing.
- `python tools/deploy.py --name <label>` copies the loader to the workspace as
  `GakuranChart_<label>_candidate.lua` (keeps the known-good copy); `--live`
  overwrites `GakuranChart.lua`; `--clean` deletes stale candidates.
- Workspace is `C:\Users\Administrator\AppData\Local\Madium\Workspace`; run a
  candidate with `run_executor_file`.
- `_G.GakuranChart` holds the API (`diag`, `openPicker`, `pickerStatus`,
  `svStatus`, `visStatus`, `list`, `setSkin`, ...). **`diag()` first** when
  something looks wrong - it names the piece that moved.
- The wheel only renders while an instrument is held. To test a submenu page
  without one, call
  `_G.GakuranChartHookBase.WheelMenu.renderMenu(controller, "me_u")` with the
  controller found via getgc (table with `_slots` and `_menuPage`) and read
  `controller._slots[i].Data / .V.DiffText.Text`.
- `GakuranCharts/Charts/test_end.json` is a 28 s chart - the right thing to
  play when a test needs a full song-end, results screen and stats call.

## Still open / not verified
- Submenu chip still not eyeballed on screen by the user; pill width with long
  names unchecked.
- Select-flash colour, physical wheel click, full pick->play->stop cycle,
  overlay/submenu exclusion with a real overlay.
- Real stage play with the SV-spawn / skin-visual passes (never forced live).
- `SubmitStats` args 3 and 4 are still unidentified - they were 0/nil on a
  capture run that took no input. Identify them from a played run before local
  scores relies on them (ROADMAP 8 has the full captured shape).
- Local scores (ROADMAP 8) is designed but not built: record via a
  `b.scoreHandler` on the base record plus a `HK.submitRev`.
- The `>4K` fold (ROADMAP B) and tier colours (A4) are untouched.
- Repo hygiene: `.git` is ~52 MB because beatmap archives, a 9 MB mp3 and a
  10 MB converter .exe are tracked, and `GakuranChart - Copy just in case.lua`
  is a v1.0 file superseded by 27+ commits of history. No remote yet, so this
  is the cheap moment to fix it. There is also no `.gitattributes`, so line
  endings churn (CRLF warnings on commit).
