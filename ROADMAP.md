# GakuranChart Roadmap

Written 2026-10-10 from a static read of `GakuranChart.lua` (HEAD `578c2d8`).
**Status:** items 2 and 3 are done and verified live in `bdd1402`; everything else below is still unverified and untouched.
**Every bug below is "likely, please verify"**. Nothing here has been confirmed in-game yet.
Items are ordered: safety first, then cheap wins, then features.

## Working rules (from SESSION_NOTES.md)

- Don't touch `.lua` without explicit go-ahead.
- Test candidate files from the workspace first; keep the known-good deployed copy until verified.
- Commit only after live verification. Never claim success before a live test.
- Real stage plays are never modified or forced live.
- Nothing custom may ever reach the server.
- Report untested items honestly.
- Never commit `tools/- !       NC Skin ~[Svnth's Edit!]~/` (skin source).

## Do in order

### 1. Baseline (read-only)
- [ ] Diff the deployed workspace `GakuranChart.lua` against HEAD `578c2d8` to confirm what "known good" is.
- [ ] Decide whether to commit `SESSION_NOTES.md` (currently untracked).
- [ ] Verify each claimed bug in the code, starting with #2 and #3 below.
- [ ] Leave the SV spawn-extension block (~L1092-1220) alone. It was verified live and the review only skimmed it.

### 2. Stability: UI failure leaves a half-initialised loader (L1517, L1780) — DONE (`bdd1402`)
- [x] Register `_G.GakuranChartCleanup` **before** the UI is built.
- [x] Wrap the Rayfield load/build in a protected call (`buildUI()` + `xpcall`).
- [x] ~~Fall back to headless mode~~ Changed approach: on failure the loader **rolls back fully** instead (retire instance via generation bump, run pre-registered cleanup, `sweepRayfield`, deferred `HK.finish()` while a custom session tears down). Headless fallback was dropped.
- Verified live (Test B, forced UI error in a temp copy): hook slots back to original, 0 guard ids, 0 persistentFrame conns, 0 windows, ledger 0; a normal re-exec afterwards recovered everything.
- Why: if the UI errors, the `RenderStepped` connection, skin wrap and hooks stay live and the next run can't clean them up.

### 3. Stability: safety-net hooks stack across re-executions (L143-167) — DONE (`bdd1402`)
- [x] Keep the genuine `SubmitStats`, `QueryJamSync`, `FireStart` and restore them in cleanup. Implemented as a versioned shared base (`_G.GakuranChartHookBase` v2): one stable wrapper per hook, genuine originals recovered by peeling legacy-shaped wrappers, restore only while our wrapper is installed.
- [x] Cleanup removes injected songs from the registry and wheel via an identity-based ledger (`_G.GakuranChartLedger` v1) that also restores displaced genuine entries.
- Verified live: Test A (3 re-execs, zero growth), Test C (custom ids guarded, no network calls), Test D (play/stop/teardown, double cleanup clean).
- Caveat: `SubmitStats`/`QueryJamSync` bogus-id probes matched the guards' return values but were not independently decisive; their wrappers share the verified structure.
- Live test had to cover: several re-executions, Stop, hooks not stacking, and custom ids still neutralized after a restore.

### 4. Converter vs loader key-count mismatch
- `osu2gakuran.py` clamps keys to 1-7; the loader drops lanes above 4 (above 2 for Guitar), so 5K/7K maps silently lose notes.
- [ ] Check how the converter handles >4 keys (Python only, no game needed).
- [ ] Either fold/merge columns to 4 or warn at convert time.

### 5. Small fixes (one commit)
- [ ] Sort notes by `b` in `readChart` (hand-made charts may be out of order).
- [ ] Fix `if type(getfenv) then` (L41) to `== "function"`.
- [ ] Create `SKINS_DIR` in the folder loop (L195).
- [ ] Use `Rayfield:Notify` for errors instead of `warn` only.
- [ ] Sync version: code says 1.4 (L28), header says v1.3, README stops at v1.3.
- [ ] Fix README: it says "one note image for all 4 lanes" but per-lane taps, hold heads and pressed receptors now exist.
- [ ] Background dim does nothing for images (L311-315): add a black overlay frame tied to the slider. *(needs a quick in-game look)*
- [ ] Honor per-chart `chart.offsetMs` in `buildGameSong` (L377). *(needs a quick in-game look)*
- [ ] Clearer "N notes dropped" message when validating charts.

### 6. Startup self-test and `_G.GakuranChart.diag()`
- [ ] Report which hooks and fields were found at startup (`_session`, `_view`, `_registry._byId`, `_active`, `_carryOverStats`, ...).
- Why: when a game update breaks something, we see which piece changed. Do this before riskier work.

### 7. Single-pass `getgc` scan
- [ ] `gcFind` runs ~8 full scans at startup. Collect every target (service, stats, relay, chartUtil, noteSprites, themeSettings, settings host) in one pass.
- [ ] Use the diag output from step 6 to confirm the same targets are found.

### 8. Local scores (`Scores.json`)
- [ ] First capture what `SubmitStats` actually receives for a custom song (via Madium). Don't guess the payload shape.
- [ ] Save best score, accuracy and combo per chart locally. Never sent anywhere.

### 9. Quality-of-life
- [ ] Retry hotkey and Stop keybind.
- [ ] Remember per-chart offset automatically; optional tap-to-calibrate.

## Later / future add-ons

### Multi-difficulty support (requested)
Switch difficulty when an osu! map (or a chart from another game) has more than one.
- [ ] Converter: convert every `.osu` in an `.osz` (or let the user pick) instead of one map at a time. *(Check how `osu2gakuran.py` handles multi-difficulty `.osz` today. Not read yet.)*
- [ ] Share audio and background across difficulties (store once, don't copy each time).
- [ ] Handle `.osz` files that mix osu!mania with other modes: only mania converts exactly, so flag or skip the rest.
- [ ] UI: a difficulty dropdown that appears when a song has more than one.
- **Cheap version (start here):** one JSON per difficulty, shared `songId` and audio path; UI groups by song and shows a difficulty picker. No format change.
- **Cleaner version:** one JSON per song holding several difficulty charts (format v2). Touches loader and converter together; only if the cheap version feels limiting.
- Keep it game-agnostic: Clone Hero (Easy-Expert) and StepMania work the same way.

### Medium effort
- [ ] Chart browser: search, sort by difficulty/BPM, cover, artist, note count, favourites. (Natural home for the difficulty switcher.)
- [ ] Song preview: play the osu `PreviewTime` clip on selection.
- [ ] Multi-mode charts: the format already stores `charts[mode]`, but only `chart.mode` is used. Add a mode picker.
- [ ] Hit sounds: client-side sound on judgement (`soft-hitnormal.wav` is already in `osz_extract`).
- [ ] Playlist / queue / shuffle.
- [ ] Practice mode: start from a timestamp, loop a section, no-fail. Speed rate depends on how the engine reads the audio clock, so check that first.

### Bigger projects
- [ ] More converters: Clone Hero `.chart`/`.mid`, StepMania `.sm`/`.ssc`, Quaver `.qua`.
- [ ] Watch-folder importer: a Python script that auto-converts new `.osz` files (keep unzipping outside the executor).
- [ ] Engine adapter layer: put every game-specific hook behind one table so game updates are a small patch.

### Compatibility (skipped for now, since only Madium 2.0.0 is used)
- Weak or partial `getgc` on other executors fails silently ("Could not find RhythmServiceClient").
- `require` / `getloadedmodules` fallback if the game's ModuleScripts are reachable (paths not inspected).
- Executor API differences: `getcustomasset` path format, `listfiles` returning `\` or `/`, missing `gethui`.
- Separate core from UI so Rayfield becomes optional.
- Check Rayfield window and toggle key with touch (mobile has no keyboard).
- Game updates are the biggest long-term risk: the loader depends on private fields. Step 6 is the insurance.

## Known limits (from SESSION_NOTES.md)
- Custom stage lighting isn't implementable: the engine has no lighting slots, only flash/ring pools.
- Flash/ring matching is possible but marginal (deferred).
- The day_by_day audio file was overwritten once; the overwriter was never identified.
