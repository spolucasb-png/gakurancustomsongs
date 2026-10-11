# Handoff (for the next chat session)

## READ FIRST: work-in-progress log + save protocol
**Instruction to every AI session working in this repo: keep this section
current as you go, not at the end.** Sessions can be cut off at any moment
(usage limits, API budget errors), and whatever is not written here or
committed is lost. So:
1. Before starting a task, add it below under "Current task" with its goal and plan.
2. After every meaningful step (a function written, a decision made, a test run),
   update the "Progress" checklist and "Decisions / findings" here, then
   **commit** (small commits, WIP is fine: `git commit -am "WIP: ..."`).
3. Record exact next step and anything half-done, including files or scratch
   scripts left outside the repo (e.g. `C:\Users\Administrator\_gk_patch\`).
4. When the task is finished, move it to the "Recent work" list below and clear
   "Current task". Tell the next AI to keep doing the same.
5. Never claim something works unless it was run; mark untested items as untested.

### Current task: deploy v2.0.18 live, then real 4K+ (more than 4 lanes) with a key-binding page
Goal (user, 2026-10-11): make maps with more than 4 keys playable as such instead of
only folded to 4 lanes, with a settings page where the player binds the keys used
for 4K+. Build and test it on the Rayfield UI first; moving it to the game's own
settings page is optional and comes later. Folding (`fold_columns`) stays as the
default/fallback for anything the engine cannot render.

Plan / progress (update after every step):
- [ ] Back up the deployed v2.0.16 loader (outside the workspace), then
      `python tools/deploy.py --live` (runs check.py) so the workspace has v2.0.18.
- [ ] Read-only research in the live client: is lane count really fixed per
      mode (`RhythmChartUtil.getLaneCount`)? who consumes it (note pool, receptors,
      highway layout, input, judging)? where are the key->lane bindings and the
      game's own keybind settings page? Record findings here BEFORE designing.
- [ ] Decide: extra lanes in the engine vs. loader-side rendering/judging; if the
      engine cannot do it, say so here and fall back to a better fold, not a hack.
- [ ] Only then design the Rayfield binding page + loader changes (candidate first).

Decisions / findings: (none yet - the first two items are being done now)

## State
`GakuranChart.lua` is the single loader, **v2.0.18**. Everything below was
verified live on placeVersion 7646 (Madium 2.0.0) before being committed.
**Deploy state:** nothing has been deployed with `deploy.py --live` since
v2.0.16 - the workspace `GakuranChart.lua` is still v2.0.16. The repo file
(v2.0.18, hash `5BA4D24B9C68...`) exists in the workspace as
`GakuranChart_notifyguard_candidate.lua`; the live client was last running it.

Recent work, newest first:
- **v2.0.18 - reload hardening (ROADMAP 9c).** (1) `HK.loadRayfield` patches
  the Rayfield source IN MEMORY so `RayfieldLibrary:Notify` threads return when
  their frame is unparented (a check after each of its 6 `task.wait` statements);
  this removes the `Title/Icon is not a valid member of Frame ...` errors printed
  by back-to-back reloads (N reloads used to print N-1 pairs; reloads >= 8 s apart
  were always clean). Falls back to the untouched source with a warn if the
  anchors are missing or the patched chunk does not compile. (2) The init-time
  `findWheelController` scan (`getgc(true)`, flaky: 4,4,0,4,4 hits in five identical
  scans) now retries up to 3x, 0.25 s apart, and stops if a newer reload took over.
  `diag().counts.rayfieldGuard` = guards applied (6 on the current Rayfield).
  Verified live on client 14512: 10 reloads (4 back-to-back, 3 at 4 s, 3 at 8 s)
  = 0 error lines and 0 wheel warnings; v2.0.17 printed 5 error pairs on the same
  patterns. `tools/check.py` passes and the guard patches exactly 6 sites under the
  luau CLI. New helpers live on `HK` (the main chunk is near Luau's 200-local limit).
- **Above-4K converter fold (ROADMAP 4 / B), `tools/osu2gakuran.py` only, loader
  untouched.** 5K-18K mania maps are folded to 4 lanes (`fold_columns`, exact
  overlap rule, busy-lane rerouting, drops only when all lanes are busy; adds
  `fold` + keeps `sourceKeys` in the chart JSON). Default on; `--no-fold` skips
  such maps; also fixes the old min(7, keys) clamp (now 18). `python
  tools/test_fold.py` = 9 offline tests. Real maps (5K x4, 7K x2) convert with
  0-3 dropped objects each and load in the live loader. NOT played in-game yet,
  and 6K / 8K+ are synthetic-tested only.
- **v2.0.17 — Rayfield chart list is one row per song.** A "Difficulty" dropdown
  appears only for multi-difficulty songs (ROADMAP 8c).
- **v2.0.16 — local scores** in `GakuranCharts/Scores.json` (ROADMAP 8).
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
- **Line endings differ per file** (all files are `-text`, bytes are stored as
  is): `GakuranChart.lua`, `README.md`, `ROADMAP.md` are CRLF in git; `HANDOFF.md`
  and `tools/*.py` are LF. Check `git ls-files --eol <file>` before writing a
  patch script and write the same EOL, or git shows the whole file as changed.
  `git diff --stat` after an edit should show only the lines you meant to touch.
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
- Tier colours (A4): this file used to say "untouched", but the loader has
  `DiffKey`/`DiffTier` hook slots (`HK.ensure` near L457/L481) and ROADMAP A4 is
  still unticked. Nobody has checked which is right: read that code and `diag()`'s
  hook list before building anything, then fix whichever doc is stale.
- v2.0.18: the wheel-scan retry is not proven to fire (0 warnings in 10 reloads vs
  roughly 20-67% before is consistent with it, but nothing was instrumented). The
  wheel submenu, play and stop were not re-run on 2.0.18, and it is not deployed live.
- Folded >4K charts have not been played in-game; the user should try one (for
  example `set304864_5k_*` from the "-+" maps or `ievan_polkka_7k_*`) and judge
  the feel. If a fold choice feels wrong, the knobs are `FOLD_MIN_GAP_MS` and the
  tie-break in `fold_columns` (`tools/osu2gakuran.py`); `tools/test_fold.py` must
  keep passing.
- Repo hygiene is done (history rewritten, `.git` ~391 KB, `.gitattributes`
  added). `_gk_backup/gakuran-pre-cleanup-*.bundle` still holds the full old
  history; the user deletes it when satisfied.
