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

### Current task: above-4K converter fold (ROADMAP item 4 / B)
Goal: let osu!mania maps with 5-10 keys be converted to playable 4-lane Gakuran
charts without changing the game's system (lane count is fixed per instrument:
Keyboard/Bass/Drums 4, Guitar 2). Today `tools/osu2gakuran.py` skips >4K maps
(`--allow-lossy-keys` converts them but the loader drops lanes above 4).
Python-only; do not touch `GakuranChart.lua` for this.

Progress:
- [x] Found that the converter already skips >4K with a warning (not silent loss).
- [x] Studied `convert_hitobjects` / `convert_file` (only caller of the former is `convert_file`).
- [x] Implemented `column_lanes()` / `fold_columns()` in `tools/osu2gakuran.py` + hook into `convert_hitobjects` (patch script: `C:\Users\Administrator\_gk_patch\patch_fold.py`, already applied, do NOT re-run).
- [x] `tools/test_fold.py`: 8/8 pass (`python tools/test_fold.py`).
- [x] CLI: fold is the default for keys > lanes; `--no-fold` restores the old skip; `--allow-lossy-keys` stays legacy.
- [x] Chart JSON: additive `fold` object (from/to/source/kept/rerouted/dropped/droppedHolds/duplicates); `sourceKeys` stays the original count; `charter` gets ", folded 7K->4 lanes".
- [ ] Run on real maps (list below), eyeball stats, `python tools/check.py`.
- [ ] Commit; update ROADMAP (item 4 / B) and this file. Loader is NOT changed.

Decisions / findings:
- Existing bug: `keys = max(1, min(7, keys))` mis-computes columns for 8K-10K
  (x is encoded for the real key count). Clamp becomes 1..18; <=7K unchanged.
- Fold rule (one exact rule, integer math): column c of k spans [(c-1)N, cN) in
  units of 1/k, lane j spans [jk, (j+1)k). Natural lane = largest overlap; an
  exact tie (e.g. 5K centre, 7K centre, 6K cols 2/5) means two candidate lanes,
  resolved dynamically toward the least recently used free lane.
- Conflicts: chronological pass; a lane is busy until a hold's end (or a tap's
  time) plus FOLD_MIN_GAP_MS. Per same-time group: natural lanes first, then
  reroute leftovers to the nearest free lane (holds before taps), and drop only
  if all lanes are busy. Counts are reported and stored in the chart.
- Output stays mode "Keyboard" with lanes 1..4, so the loader/engine are untouched.
- Test maps on disk (all osu!mania): `..\_scratch_convert\extract\304864\` (5K
  maps of "-+"), `..\_scratch_convert\extract\993703\` (Ievan Polkka 7K NSV/SV),
  `..\madium\Workspace\afn_charts\2FAR_Hard_ALT_057_233.osu` (6K).
  Convert into a TEMP dir, never into the real GakuranCharts folder.
- Line endings: `tools/*.py` and `*.md` are LF in git, but the working copies
  were CRLF; `GakuranChart.lua` is CRLF in the index. A patch script that
  preserves CRLF on a LF blob makes git show the whole file as changed - write
  the same EOL as the committed blob (`git ls-files --eol <file>`).

## State
`GakuranChart.lua` is the single loader, **v2.0.17**. Everything below was
verified live on placeVersion 7646 (Madium 2.0.0) before being committed.

Recent work, newest first:
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
- Tier colours (A4) are untouched. The `>4K` fold (ROADMAP B) is in progress,
  see "Current task" at the top.
- Repo hygiene is done (history rewritten, `.git` ~391 KB, `.gitattributes`
  added). `_gk_backup/gakuran-pre-cleanup-*.bundle` still holds the full old
  history; the user deletes it when satisfied.
