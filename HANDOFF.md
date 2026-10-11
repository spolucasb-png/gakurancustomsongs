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

### Current task: v2.0.18 reload hardening (notification errors + wheel-controller scan)
Goal: stop the console errors after back-to-back reloads and make the wheel
controller discovery reliable. Found by reproducing on the live client (PID
14512) with both v2.0.16 and v2.0.17 (identical behaviour):
- **Rayfield notification errors.** A reload destroys the previous Rayfield GUI
  while its `Rayfield:Notify` threads (own `task.spawn`, ~5.3 s life) are still
  sleeping; when they wake, `newNotification.Title` (L1387) / `.Icon` (L1411) are
  gone -> `X is not a valid member of Frame "Song wheel"`. Count = reloads - 1;
  reloads >= 8 s apart are clean. Harmless to the new instance (1 GUI, 7 children).
- **`Wheel controller not found - difficulty picker falls back to overlay`.**
  `findWheelController` scans `getgc(true)` once at init and the scan is flaky:
  5 identical scans returned 4,4,0,4,4 matches with nothing changed; seen in
  ~2 of 10 reloads on v2.0.17 and 2 of 3 on v2.0.16. `armWheelMenu` retries on
  first use, so the usual result is only the warning, but a miss there too means
  the overlay instead of the wheel submenu.

Plan (all in `GakuranChart.lua`, candidate first, nothing deployed live):
1. Load Rayfield through `loadRayfield()`: patch the source IN MEMORY (file on
   disk untouched) so every `task.wait(...)` statement inside
   `RayfieldLibrary:Notify` is followed by `if not newNotification.Parent then
   return end`. Fall back to the unpatched source if the anchors are missing, the
   patch count is 0 or the patched chunk does not compile.
2. Init-time wheel scan: up to 3 forced retries 0.25 s apart, aborting if the
   generation changed (a newer reload took over).
3. Version 2.0.17 -> 2.0.18 (`VERSION` + header comment).

Progress (update after every step):
- [x] Reproduced, root-caused, plan agreed with the user.
- [ ] Patch written and applied (scratch script: `C:\Users\Administrator\_gk_patch\v2_0_18.py`, outside the repo; loader is CRLF).
- [ ] `python tools/check.py` passes.
- [ ] Candidate deployed (`python tools/deploy.py --name notifyguard`); tested:
      back-to-back reloads (expect 0 Icon/Title errors), 8 s-spaced reloads,
      guard count 6, wheel warning rate over ~10 reloads, `diag()`, 1 GUI left.
- [ ] Committed; this section moved to "Recent work"; ROADMAP entry added.
- NOT done on purpose: no `deploy.py --live`; the workspace `GakuranChart.lua`
  is still v2.0.16 and the live client was running the v2.0.17 candidate.

Noticed, not part of this task: the A4 notes below say tier colours are
"untouched", but the loader already has `DiffKey`/`DiffTier` hook slots
(`HK.ensure` calls near L457/L481) - one of the docs is stale; unverified.

## State
`GakuranChart.lua` is the single loader, **v2.0.17**. Everything below was
verified live on placeVersion 7646 (Madium 2.0.0) before being committed.

Recent work, newest first:
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
- Tier colours (A4) are untouched.
- Folded >4K charts have not been played in-game; the user should try one (for
  example `set304864_5k_*` from the "-+" maps or `ievan_polkka_7k_*`) and judge
  the feel. If a fold choice feels wrong, the knobs are `FOLD_MIN_GAP_MS` and the
  tie-break in `fold_columns` (`tools/osu2gakuran.py`); `tools/test_fold.py` must
  keep passing.
- Repo hygiene is done (history rewritten, `.git` ~391 KB, `.gitattributes`
  added). `_gk_backup/gakuran-pre-cleanup-*.bundle` still holds the full old
  history; the user deletes it when satisfied.
