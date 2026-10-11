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

### Current task (session 7): source game icons beside the wheel star rating
Goal (user, 2026-10-11): icons showing which game a song comes from (customs
vs native today, other source engines later), everywhere feasible, as true
image icons. User accepts the wheel-skin-injection update-fragility risk.
- Design agreed: `source` field in chart JSON (converter `--source`, default
  `osu`; backfill 30 workspace charts: 29 `osu`, `test_end` `local`);
  loader carries `song.gakuranSource` (SWAP_FIELDS) + `[osu!]`-style text tag
  on wheel-row titles now; true ImageLabels in overlay/Rayfield/submenu text
  where we own the GUI; main-wheel image-beside-badge needs live wheel-skin
  research (fragile, queued as a live step).
- Plan: converter edit → backfill → loader v2.0.22 (readChart default,
  buildGameSong source+tag, SWAP_FIELDS, submenu/overlay/Rayfield tags, icon
  asset map with graceful missing-file fallback) → check.py → candidate →
  live-verify (30/30 load, tags on screen, no Scores.json regrowth) → deploy.
- Star-badge DiffTier-nil probe (session 6) still queued alongside.

### Session 5 (2026-10-11): stage keyboard guard (v2.0.21), chart import answer
- [x] User bug: Space stands you up from the REAL stage keyboard. Cause (live-verified): seated, Space is
      Roblox's jump and a jump stands you up; the engine only sinks Space while a session runs AND the
      game's "lock movement" setting is on (`RhythmEngine:SetMovementLocked`, `RhythmSettingsClient:IsMovementLocked`).
      The game's own leave bind is Backspace/ButtonB (`RhythmStationLeave`, priority 2050, `InstrumentServiceClient`).
- [x] Fix = loader section 6.9 (`HK.sg*`, API `G.stageGuard()`): only while `Humanoid.SeatPart ~= nil or Sit` AND
      character attribute `PlayingInstrument == "Keyboard"`: a CAS bind sinks Space at priority 3100 (below the
      engine's lane keys 3200 and move-lock 3150, above jump 2000 and station-leave 2050) and a PlayerGui button
      "EXIT KEYBOARD" (top right, `GakuranChartStageExit`) runs the Backspace routine (WheelOpenRegistry.CloseOpen,
      then SeatServiceUtils.StandUp, plain `Sit=false` fallback). Torn down in the cleanup, swept on startup.
      Drums stations are NOT covered (change the `== "Keyboard"` test in `HK.sgState` if wanted).
- [x] Verified live (client 14512, fake seat = `hum.Sit = true`, VirtualInputManager Space): baseline Space stands the
      character up; with guard active it stays seated (blocked counter counts the sunk events); during a 7K play
      with Space as lane 4 the lane still registers (`_receptorPressed[4]` true/false) and our sink sees nothing
      (engine 3200 wins); button click via `firesignal(btn.Activated)` stands up; re-exec while active = 1 button,
      1 frame connection; cleanup removes bind and button. NOT verified: a real stage seat (SeatPart, real
      server-side seat, the real wheel open), touch/gamepad (ButtonA jump is not blocked), where the button sits
      relative to the game's HUD.
- [x] Charts: all 9 `.osz` in `FunkyChart_v1.23/` accounted for. 8 hold mania maps and ALL their difficulties are
      in the workspace (Blue Zenith 10, set304864 6, me & u 5, Ievan 4, Dragon Blade, Day by day, Sound Architect,
      d_for the DELTA). `1099026 Laur - Unknown Civilization.osz` is osu!standard (mode 0), skipped by the converter
      unless `--include-nonmania` (approximate conversion): NOT imported, asked the user.
      The osu! Songs library is NOT imported (user: only the FunkyChart folder).
- [x] Cleanup done: `__test_7k.json` deleted, stale `GakuranChart_*_candidate.lua` removed (`deploy.py --clean`).
- [x] FRESH INSTALL of charts done (user: no local scores). `1099026 Laur - Unknown Civilization.osz` (osu!standard,
      user's mistake) deleted from `FunkyChart_v1.23/`. Whole workspace `GakuranCharts` backed up to
      `Referencesandmods\_scratch_convert\workspace_gakurancharts_backup_before_fresh_install` (58 files), then Charts/Audio/
      Assets emptied (kept the hand-made `test_end.json` + `test_end.mp3`), `Scores.json` deleted (Settings.json and Skins
      kept), and the 8 remaining `.osz` re-converted (30 charts, 9 audio, 8 assets: same counts as before). Verified live:
      loader 2.0.21 lists and loads 30/30 (lanes 4x13, 5x4, 6x1, 7x12), 9 wheel songs, no Scores.json, 0 score rows.
- [ ] LATER (user request): find out why some single-difficulty maps do not show their star rating in the wheel
      (v2.0.10/2.0.11 give `song.difficulty = { [mode] = "★x.xx" }` in `injectSingle`; check which rows lack it:
      first suspects are the `chart.mode` key vs the wheel's instrument mode, charts that skip `injectSingle`
      (parents with `not uniform`, non-Keyboard modes), 5K-7K lane charts, and `Kit.tier` word handling).
      Static pass done (session 6, no live client in this env — NOT live-verified):
      mode-key mismatch ruled out (all 30 workspace charts: mode=Keyboard,
      diffKeys=Keyboard); singleton groups (day_by_day, dragon_blade,
      d_for_the_delta, sound_architect) and no-songId test_end all go through
      injectSingle, which always assigns a ★ string (starRating never throws —
      pcall inside, falls back to 0.5). Prime suspect now: HK.makeDiffTier only
      overrides when the game's tier(★) returns a table; if wheelKit.tier has
      its own lookup (does not call our wrapped Difficulty.Key), tier("★x.xx")
      returns nil and the wrapper passes nil through — badge draws nothing.
      Fix sketch (NOT applied): on ★ input with nil/non-table under-result,
      map ★ to its band tier name (same bands as makeDiffKey), call
      under(tierName) for a template, copy it and set word=★. Next: live probe
      (diag hooks DiffKey/DiffTier slot==wrap; call tier("★5.32") + Key("★5.32")
      directly; read which singleton rows lack badges on screen).
### Current task (session 4): import the osu! maps with more than 4 keys as real 4K+ charts
Goal (user, 2026-10-11): the loader plays 5-7 lanes now (v2.0.19/2.0.20), so import the
osu! maps that have more than 4 columns as native 4K+ charts instead of 4-lane folds.
- [x] State checked at session start: tree clean at `e602e8b` plus an UNCOMMITTED converter
      edit by the previous session. **v2.0.20 IS DEPLOYED LIVE** (workspace `GakuranChart.lua`
      == repo, same size and hash `DC279EB17C...`); the "not deployed" lines further down are stale.
- [x] Converter (`tools/osu2gakuran.py`): `MAX_KEYBOARD_LANES = 7`, new `--max-lanes 4-7`
      (default 7). 5K-7K mania maps convert 1:1 and the chart gets `"lanes": N`; 8K+ fold
      to 7; `--max-lanes 4` = the old fold-everything-to-4K behaviour; `--no-fold` still skips.
      Verified offline: `tools/test_fold.py` 10/10 (the 10K end-to-end test was rewritten for the
      new default and a native 5K-7K test added), `tools/check.py` 7/7.
- [x] Source maps: the >4K `.osz` files in `FunkyChart_v1.23/` (Dragon Blade 6K, Blue Zenith 7K x10,
      `304864 daisan -+` 5K x4, Ievan Polkka 7K x2). The previous session re-converted them (11:23) with
      the new default into the workspace `GakuranCharts` (whole-folder backup made first:
      `Referencesandmods\_scratch_convert\workspace_gakurancharts_backup_before_4kplus`). 17 native charts
      (`lanes` 5/6/7, no `fold`). Charts are NOT in git: only the workspace holds them.
- [x] Verified this session: offline check of all 17 (every lane 1..N used, sorted by beat, noteCount
      matches, audio/background files exist) = 0 problems; live loader 2.0.20 `G.load` accepts 17/17
      (`diag`: all getgc targets found); short live play of `ievan_polkka_7k_sv` (7 lanes, SV 107 points):
      `_lanes=7`, view 7 receptors, lane pitch ~134 px, notes live on lanes 2,3,5,7, `svStatus.errors=0`,
      `visStatus` errors 0 (`holdHead`, `pressed`, `tapLanes=2` active, 84 writes), console clean,
      `PlayingInstrument` nil again after `G.stop()`, no session/view left.
- [ ] STILL NOT verified: how it looks on screen, hit judging with physical keys on lanes 5-7 (the
      lane 7 hit-bot result is still open), perspective mode, clicking the Keys (4K+) tab.
- [ ] QUESTION FOR THE USER (unanswered): the osu! Songs folder (`%LOCALAPPDATA%\osu!\Songs`) holds
      251 mania difficulties with more than 4 keys in about 70 sets (mostly 7K, also 5K/6K and 8K-10K).
      NOT imported. Importing all would add ~70 songs and audio files to the wheel, so ask which sets
      (or all) before converting; 8K+ would fold to 7 lanes.
- [ ] Cleanup pending: `__test_7k.json` in the workspace Charts (shows in the wheel) and the
      `GakuranChart_*_candidate.lua` files in the workspace (`python tools/deploy.py --clean`).

### Current task (older, still partly open): deploy v2.0.18 live, then real 4K+ (more than 4 lanes) with a key-binding page
Goal (user, 2026-10-11): make maps with more than 4 keys playable as such instead of
only folded to 4 lanes, with a settings page where the player binds the keys used
for 4K+. Build and test it on the Rayfield UI first; moving it to the game's own
settings page is optional and comes later. Folding (`fold_columns`) stays as the
default/fallback for anything the engine cannot render.

Plan / progress (update after every step):
- [x] Back up the deployed v2.0.16 loader, `python tools/deploy.py --live` (v2.0.18). Done.
- [x] Read-only research in the live client (client 14512): the engine is
      lane-count-generic, so real 4K+ looks feasible. Findings below. NOT tested.
- [x] (DONE 2026-10-11, results in the work log) Probe with a throwaway Luau script (no loader change) whether a >4-lane
      session starts and plays: wrap `RhythmChartUtil.resolvePlayable`, set
      `playable.lanes = 7` + a key map, `StartPlay` a 7K chart, watch for errors.
- [ ] Loader: `lanes` + `keyMapOverride` on our song, a theme for N lanes, hint
      labels, skin lane mapping (design below). Candidate first, then live-test.
      IN PROGRESS (a new session picked this up at b77bd38, 2026-10-11). Sub-steps:
      - [x] read the loader sites, fixed the design (see "Work log": session 2)
      - [x] `ResolvePlayable` hook slot (sets `playable.lanes` for songs we own)
      - [x] N-lane view theme + hint labels + key map: three wrappers on the settings
            module getters (`GetViewTheme`, `GetKeyboardHintLabels`,
            `GetKeyboardKeyMap`), NOT on the `StoredToViewTheme` slot the skin code owns
      - [x] settings (`settings.keys`) + Rayfield "Keys (4K+)" tab - WRITTEN, only the
            tab's construction was exercised live; rebinding / duplicate rejection /
            reset button NOT clicked yet
      - [x] candidate built (`GakuranChart_4k_candidate.lua`), `tools/check.py` ok,
            offline logic test 29/29, live install + 7K play verified (work log)
      - [ ] hit-bot judging check with lanes 5-7 (first run was inconclusive)
      - [ ] look at it on screen (user), SV / skin passes with 7 lanes, then commit
        THE LOADER CHANGE IS NOW COMMITTED (v2.0.19 = `c8aa67f`, v2.0.20 lane-pitch fix = `c9cb719`);
        the patch script `_scratch_convert\patch_4k_loader.py` is already applied, do not re-run.
- [ ] Rayfield "Keys (4K+)" page: per-lane-count key binding (5K, 6K, 7K...), saved
      in Settings.json. Later, optionally, the game's own settings page (see below).
- [ ] Converter: stop folding when the loader supports the lane count (`--no-fold`
      semantics stay; add the real column count to the chart, `sourceKeys` exists).

### Work log (newest last; keep appending)
- 2026-10-11: user approved starting the plan. Step 1 = throwaway probe, scripts live in
  `C:\Users\Administrator\Desktop\Referencesandmods\_scratch_convert\probe4k_*.lua`
  (outside the repo, run with `run_executor_file` or `execute_luau`). The probe only
  touches module tables / a synthetic song guarded in `GakuranChartHookBase.ids`, and
  must restore every wrapper it installs. Results get appended here.

- 2026-10-11 probe RESULT (client 14512, loader 2.0.18, default skin): a synthetic 7K song
  (40 notes, 2 holds, keys A S D Space J K L) played through a real `StartPlay` with ONLY
  two temporary wrappers: `RhythmChartUtil.resolvePlayable` (sets `playable.lanes` from
  `song.gakuranLanes`) and `RhythmThemeSettings.StoredToViewTheme` (for n > 4 it passes a
  copy of the stored theme whose `noteIn4/noteOut4/recBorder4/recPress4` are cycled up to
  n entries). Observed: no error from `StartPlay`, `sess._lanes == 7`, `view._laneCount == 7`,
  `view:GetLaneXAt(1..7)` spans 764..1224 px, notes spawned on lanes 1,2 in order, the
  engine key map is exactly `A=1 S=2 D=3 Space=4 J=5 K=6 L=7` (hint lists also carry the
  controller buttons for lanes 1-4), perspective off, the song ran to its natural end and
  the results screen appeared, no warn/error lines in the console, loader `diag()` still
  "all getgc targets found", `visStatus().errors == 0` (skin was the game default, so the
  skin pass wrote nothing: NOT a test of skins with 7 lanes).
  NOT verified: how it looks on screen (lane width, hold bodies, hint labels, judgement
  line), physical key presses / judging with 5+ lanes (I did not press keys; no hits were
  judged), SV pass and skin pass with 7 lanes, stats/results contents, perspective mode.
  Probe scripts: `_scratch_convert\probe4k_start.lua` (cleaned copy of the inline script;
  the asset-function name inside it is unverified). The probe's wrappers, the guarded
  synthetic song `__probe4k_7k` and the temporary `PlayingInstrument=Keyboard` attribute
  are restored by a watcher inside the client ONLY after the results screen is dismissed
  (restoring earlier would kill it). If this session was cut off, check
  `_G.__probe4k` in the client: `.active == true` means cleanup has NOT run; run
  `for i = #P.restore, 1, -1 do pcall(P.restore[i]) end; P.active = false` once
  `service._session/_view/_resultsScreen` are all nil. A re-exec of the loader does not
  clear it.

- 2026-10-11 (session 2 picked up at b77bd38, tree clean): checked the live client 14512
  (loader 2.0.18, gen 59, bridge had just reconnected). The probe is STILL ACTIVE:
  `__probe4k.active=true watcher=true restoreFns=4`, results screen up, probe song and
  guard id still present, `PlayingInstrument=Keyboard`, and the probe's `resolvePlayable`
  and `StoredToViewTheme` wrappers (executor functions) are still installed. Everything
  restores by itself once the results screen is dismissed. **Do not re-execute the loader
  on that client before then**: `activateSkin` takes `rawget(StoredToViewTheme)` as its
  "original" and would capture the probe's wrapper. Offline loader work is unaffected.
- RISK found while choosing default 4K+ keys: Rayfield's own toggle key defaults to `K`
  (ui/Rayfield.lua config `rayfieldOpen = K`) and GakuranChart.lua passes no
  `ToggleUIKeybind`, so `K` would toggle the UI during play. Default 4K+ binds avoid K
  (5K S D Space J L / 6K S D F J L Semicolon / 7K S D F Space J L Semicolon); the page
  should warn if a lane is bound to the Rayfield toggle key. UNVERIFIED that K really is
  the live toggle key; check before relying on it.

- 2026-10-11 session 2, probe cleanup: the probe restored itself (`restored after surface
  gone at +627s`) once the user dismissed the results screen; verified: no session, probe
  song gone from the registry, `PlayingInstrument=nil`, neither module function executor-wrapped.
- 2026-10-11 session 2, LOADER v2.0.19 CANDIDATE (UNCOMMITTED, working tree):
  * chart JSON may carry `"lanes": 5..7` (Keyboard only); `readChart` normalizes to
    `chart._laneCount` (more than `HK.maxLanes = 7` is refused with a message), `buildGameSong`
    sets `song.gakuranLanes` and REFUSES the chart if `HK.lanesSupported()` is false (hooks
    missing), the picker's `SWAP_FIELDS` carries `gakuranLanes` (a parent's difficulties may
    differ in lane count), the Rayfield info label shows `_laneCount`.
  * 4 new HookBase slots, same discipline (wrapper closes over its record only): `ResolvePlayable`
    (`RhythmChartUtil.resolvePlayable`, sets `playable.lanes`), `ViewTheme`
    (`GetViewTheme`, n>4 -> cycles the 4-lane arrays of a COPY of the stored theme and calls the
    module's current `StoredToViewTheme`, so skins still apply), `HintLabels`
    (`GetKeyboardHintLabels`) and `KeyMap` (`GetKeyboardKeyMap`). The service fills
    `keyMapOverride` from `GetKeyboardKeyMap` only when the song has none, so keys are read from
    `settings.keys` at every play start (a rebind reaches wheel songs too). The live instance puts
    `keyNames`/`hintLabels` on the KeyMap/HintLabels records and cleanup clears them only while
    still its own. `HK.restore` and `diag()` list the new slots.
  * `settings.keys["5".."7"]` = KeyCode names; invalid/duplicate/Escape/wrong length -> defaults
    for that count (5K S D Space J L, 6K S D F J L Semicolon, 7K S D F Space J L Semicolon; no K).
  * Rayfield tab "Keys (4K+)": one keybind per lane (CallOnChange, Ext), duplicate/unusable keys
    rejected and reverted, "Reset 4K+ keys to defaults" button.
  * Verified: `tools/check.py` ok. `_scratch_convert\test_4k_logic.py` = 29/29 offline checks
    (it slices the real code out of the loader and runs it under the luau CLI against stubs).
    Live, client 14512, candidate `GakuranChart_4k_candidate.lua` run as gen 60: `diag()` "all
    getgc targets found", 12 hooks installed, the 4 new slots `slot==wrap`, `under==orig`,
    providers bound, console clean. `G.load` + `G.play` of a throwaway 7K chart (27 notes, 4
    holds): engine `_lanes=7`, view 7 receptors, lane x 764 841 917 994 1071 1147 1224, keyToLane
    `S=1 D=2 F=3 Space=4 J=5 L=6 Semicolon=7` (controller buttons still on lanes 1-4), hint labels
    `S,D,F,Spc,J,L,;`; `G.stop()` restored `PlayingInstrument` to nil in 0.4 s.
  * NOT verified: first hit-bot run (keypress/keyrelease through the executor) pressed 17 of 27
    notes (lane 7: 0) and the song ended before the counters were read, so judging with lanes 5-7
    is still UNPROVEN, and it is unknown whether synthetic keys even register (window focus). Lane
    colours read back as 255,255,255 on all 7 lanes (default theme; not judged). Look/feel on screen,
    SV pass and skin pass with 7 lanes, the Keys tab being clicked, a 4K+ song played from the wheel /
    picker, perspective mode, results/stats contents.
  * Scratch left behind (delete when done): workspace `GakuranCharts\Charts\__test_7k.json`
    (the wheel lists it: "8 custom charts") and `GakuranChart_4k_candidate.lua`.
  * The deployed `GakuranChart.lua` (v2.0.18) was not touched.
- 2026-10-11 session 3 (committed `c8aa67f` = v2.0.19 loader, then `c9cb719` = v2.0.20):
  * Checked first: `tools/check.py` 7/7, `test_4k_logic.py` 29/29, then committed v2.0.19. Live client
    14512: probe inactive, 12 hooks installed; the results screen the user mentioned was ALREADY gone
    (`_resultsScreen._destroyed == true`, Backdrop unparented, no session/view; the service just keeps
    the stale reference), so no input was sent.
  * BUG (user report: "gap lane ... so close, mid-overlapping other lanes"): the view spreads a FIXED
    width (`LanesFrame.X * LANE_SPACING_MULTIPLIER(0.3) * laneSpacing`) over the lane count
    (RhythmView `_refreshColumns`, `v81 = v80 / _laneCount`), but notes keep their size. The earlier 7K
    run had pitch 76.7 px (764..1224) against 108 px notes = neighbours overlapped by ~30 px.
  * FIX v2.0.20: new hook slot `ViewNew` on `RhythmView.new` (found by `GC.viewClass`: `new` +
    `GetLaneXAt` + `SetLaneSpacing`); for lanes > 4 it multiplies the `laneSpacing` argument (6th arg)
    by lanes/4 so the pitch equals 4K's, capped at 3.0 (never reduces a user value already above it).
    Cosmetic only: a missing view class warns and plays still work. Listed in `HK.restore` and `diag()`.
    Offline test now 41/41 (12 new `view:` checks). Run live as candidate `GakuranChart_4k20_candidate.lua`
    (gen 61): 13 hooks all installed, no stacking, `diag()` clean. 7K throwaway chart: `_laneSpacingScale`
    1.575 (user 0.9 x 7/4), lane x 591 726 860 994 1128 1262 1397 (pitch 134-135 px), receptor 108 px,
    so a 26 px gap instead of a 30 px overlap; `G.stop()` left no session/view/instrument, vis errors 0.
  * STILL NOT verified: how it looks on screen (user to eyeball), perspective mode (the same factor
    scales the board width, untested), hit-bot judging with lanes 5-7, SV/skin passes with 7 lanes.
  * v2.0.20 is NOT deployed to the live `GakuranChart.lua`; only the candidate is running in the client.

### Findings (live decompile, 2026-10-11) - 4K+ is an engine-supported shape
- `RhythmChartUtil.getLaneCount(mode)` is hard-coded (Guitar/RhythmGuitar 2, else 4)
  and its ONLY caller among the 48 `Rhythm*` scripts is `resolvePlayable`
  (RhythmChartUtil L317: `local v28 = t.getLaneCount(arg25)`; module-table
  lookup, so hookable). The playable's `lanes` then drives everything.
- `RhythmEngine` is generic: `_lanes = playable.lanes`, loops `1.._lanes`, rejects
  notes with lane outside `1.._lanes` (L2012/2036), `_laneCursor` sized by `_lanes`.
- `RhythmView.new(lanes, ...)` stores `_laneCount` and loops over it (45 hits), so
  receptors/lanes/notes are built per lane count. NOT yet checked: lane width /
  `GetLaneXAt` for 5-7 lanes, note pool sizing, hold bodies.
- **Input:** `RhythmEngine._buildKeyMap(playable)` returns `playable.keyMapOverride`
  when set, else hard-coded defaults for 2 and 4 lanes, else `{}` (no keys at all).
  `resolvePlayable` copies `keyMapOverride` from the SONG table (L369), so a
  loader-built song can carry its own KeyCode->lane map. `RhythmServiceClient`
  (L934) fills it from `RhythmSettingsClient:GetKeyboardKeyMap(lanes)` only if nil.
  Probed: `GetKeyboardKeyMap(5/6/7)` = empty table, `GetKeyboardHintLabels(5/6/7)` = empty.
- **Theme:** `RhythmSettingsClient:GetViewTheme(5/6/7)` ERRORS
  (`RhythmThemeSettings:109: attempt to index nil with number`; 2 and 4 work), so a
  >4-lane view needs a theme supplied by the loader (the loader already wraps
  `StoredToViewTheme` for skins - extend that, building the N-lane theme from the
  4-lane one). Lane colours come from `GetLaneVizColor(laneCount, lane, ...)`.
- **Game settings page:** `SettingsServiceUI` (5,266 lines) builds exactly two key
  sections, "Two Lanes" (L2593) and "Four Lanes" (L2608) via `_buildKeybindRow`
  (L2321), plus 2/4-lane lane-colour pages. Adding 5-7K there means editing that
  closure-heavy module - same trap as the guitar submenu. **Decision: Rayfield page
  first** (as the user asked); the game page is a later, optional port.
- Controller map `_buildControllerMap(n)` only knows 2 vs 4; 4K+ is keyboard-only
  unless extended.

### Design sketch (not implemented)
1. Chart JSON: loader reads `lanes` (or `sourceKeys`) when > 4 and the song's
   charts are unfolded; folded charts keep working unchanged (4 lanes).
2. A `resolvePlayable` wrapper (new slot in HookBase v2, same discipline as
   `StartPlay`): for songs we own with `song.gakuranLanes`, after the original
   returns set `playable.lanes`, ensure `keyMapOverride`, leave everything else.
3. Key binding: Rayfield page with one keybind row per lane for each of 5K..7K
   (defaults e.g. 5K S D Space K L / 6K S D F J K L / 7K S D F Space J K L),
   stored in `Settings.json`, put on `song.keyMapOverride` when a chart starts.
   Reject duplicate keys inside one lane count; Escape/Unknown are unusable.
4. Theme/labels/skin: supply an N-lane theme and hint labels; the skin visuals pass
   indexes lanes 1..4 - map extra lanes onto the nearest skin lane (untested).
5. Everything stays additive and falls back to the fold if anything is missing.

### Risks / unknowns
- Whether `RhythmView` lays out 5-7 lanes sanely (width, hit zones, perspective
  mode `sess._perspective`, SV pass `svApplyFrameInner`, skin pass).
- Anything else that reads `getLaneCount` or assumes 2/4 outside the `Rhythm*`
  scripts (only those 48 were scanned) - e.g. results screen, stats, record slips.
- Engine judging/stat code with `lanes > 4` is unexercised.
- Never forced live on a real stage play; our songs only.

## State
`GakuranChart.lua` is the single loader, **v2.0.18**. Everything below was
verified live on placeVersion 7646 (Madium 2.0.0) before being committed.
**Deploy state:** v2.0.18 is deployed live (`deploy.py --live`, check.py passed,
workspace `GakuranChart.lua` == repo, hash `5BA4D24B9C68...`). The previous v2.0.16
deployed copy was backed up to
`C:\Users\Administrator\Desktop\Referencesandmods\_scratch_convert\GakuranChart_v2.0.16_deployed_backup.lua`
(hash `A2E227C9D7F6...`). The running client was already on the identical candidate.

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
  wheel submenu, play and stop were not re-run on 2.0.18. (2.0.18 WAS deployed live
  earlier today; the live `GakuranChart.lua` is still 2.0.18, 2.0.19/2.0.20 exist only as
  committed source plus the candidate files in the workspace.)
- Folded >4K charts have not been played in-game; the user should try one (for
  example `set304864_5k_*` from the "-+" maps or `ievan_polkka_7k_*`) and judge
  the feel. If a fold choice feels wrong, the knobs are `FOLD_MIN_GAP_MS` and the
  tie-break in `fold_columns` (`tools/osu2gakuran.py`); `tools/test_fold.py` must
  keep passing.
- Repo hygiene is done (history rewritten, `.git` ~391 KB, `.gitattributes`
  added). `_gk_backup/gakuran-pre-cleanup-*.bundle` still holds the full old
  history; the user deletes it when satisfied.
- **Character can stay stuck in keyboard mode after a play (found + reproduced, NOT fixed).**
  The game never writes `PlayingInstrument` on the client (the server owns it; only the loader
  does), but `restoreAttributes` writes back the value captured at play start. Repro on v2.0.7
  (live client, may differ on 2.0.20 because v2.0.15 changed `restoreAttributes`; re-check first):
  set `PlayingInstrument="Keyboard"` as a stage seat would, `G.load` + `G.play` a chart, clear the
  attribute mid-play (standing up), let the session end: the loader restores `"Keyboard"` over the
  server's nil and nothing ever clears it (character keeps the keyboard animation and controls,
  `Sit=false`). Two more leaks in the same code: a respawn mid-play (old character's values get
  written onto the new one) and a throw between `saveAndSetAttributes` and `StartPlay` in
  `playChart` (no restore scheduled). Intended fix: remember what the loader WROTE and only undo a
  value that still equals it, skip if `player.Character` changed, plus an idle sweeper in the
  watcher for an override with no play behind it (30 s). A draft against 2.0.7 was discarded, so
  redo it against the current code. Quick manual cure for a stuck client:
  `game.Players.LocalPlayer.Character:SetAttribute("PlayingInstrument", nil)`.
