# GakuranChart Roadmap

Written 2026-10-10 from a static read of `GakuranChart.lua` (HEAD `578c2d8`).
**Status:** items 2 and 3 are done and verified live in `bdd1402`; version synced to 2.0 in `dd0191f`. Next up is the "Current focus" section (multi-difficulty, then above-4K). Everything else below is still unverified and untouched.
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

## Current focus (confirmed vision): multi-difficulty parent rows, then above-4K

**Vision (confirmed 2026-10-10; overrides the earlier "separate rows + Rayfield picker" proposal):** the wheel shows **one row per song**. Clicking it opens a **difficulty submenu**; picking a difficulty starts that chart. Not separate rows per difficulty, not a Rayfield picker.

Research is read-only: decompiles of the live game (`RhythmDifficulty`, `RhythmChartUtil`, `RhythmWheelServiceClient`, `RhythmServiceClient`, `RhythmSongRegistry`), the local `re/` copies, and `tools/osu2gakuran.py`. Nothing below has been built or tested in-game yet.

### Findings
- **The guitar submenu is not reusable.** `_applyGuitarVariantSubmenu` builds slots with fixed "Lead"/"Rhythm" labels and fixed `Guitar`/`RhythmGuitar` play paths; the page router only knows list-page vs guitar-page. Reuse for keyboard would mean editing a ~3,550-line wheel module with closure-local functions. Do not attempt.
- **`StartPlay` is a single choke point.** The only callers anywhere are 4 wheel sites (main rows L2707, search rows via `_selectSong` L1294, plus 2 guitar-only at L2498/L2522); the only definition is `RhythmServiceClient.StartPlay`. Keyboard clicks play immediately (no confirm step, no submenu hook point), then the wheel calls `Close()` (L1296).
- **No retry path found.** No `Retry`/`Restart`/`Replay` in `RhythmServiceClient`, `RhythmResultsScreen` or `RhythmResultsShared`, so the "results-screen retry" worry looks moot (re-check when testing).
- **Registry sorts `_list` by title**, so one parent row per song sorts naturally; no ordering work.
- **`songHasBothGuitarCharts` only reads `Guitar`/`RhythmGuitar`**, so Keyboard-only parents can never trip the guitar path.
- **Labels and colours.** The wheel shows `string.upper(song.difficulty[mode])` (free text). `RhythmDifficulty.Resolve` -> `Key()` colours only easy (e), medium (normal/med/m/moderate), hard (h/expert/difficult), extreme (ext/ex+/explus), insane (ins); anything else is grey "Unrated". RGB: easy 64,214,112; medium 246,176,56; hard 240,78,62; extreme 178,82,240; insane 255,48,138; unrated 84,92,120. `Resolve` calls `t.Key` through the module table each call, so a `Key` hook colours custom names.
- **Duration labels** come from the wheel's own cache/estimator; nothing for us to maintain on a difficulty swap.
- **Converter duplicates media per difficulty** (verified in source): `Audio/<chart_id>.ext` and `Assets/<chart_id>.ext` for every `.osu`. Per-difficulty data (reference BPM, `scrollChanges`, `animationBpmChanges`) also differs, so only the media can be shared, and dedupe must key on file content, not assume identical files.
- **Lane counts are fixed by mode** (`getLaneCount`: Guitar/RhythmGuitar 2, everything else 4); above-4K must be folded to 4 at convert time.

### Design (no wheel edits, no native reuse)
1. **One parent row per song** (new `songId`, e.g. `day_by_day_psyqui_remix`). Difficulties live inside the parent object, never as registry rows. Chart files stay one JSON per difficulty (additive fields); the loader groups them by `songId` at load time. Charts without `songId` are legacy singles and behave exactly as today.
2. **`StartPlay` wrapper (4th hook, same stability discipline).** If the id is a parent with difficulties and no bypass flag is set, swallow the call and open our difficulty overlay; legacy singles pass straight through; the loader's own plays set the bypass flag. Covers main rows, search rows and any future wheel path. Add it as a **new slot in the existing HookBase v2 table** rather than bumping the base version: on a version mismatch the loader builds a fresh base, which would orphan live v2 wrappers.
3. **Pick = synchronous swap, then the real `StartPlay`.** Set `charts[mode]`, `difficulty[mode]`, timing/`scrollChanges`/BPM data, and the `customCharts[parent]` SV facade from the pick, then call through. Single-threaded, so no races and nothing to restore; SV/judging code runs unmodified.
4. **Overlay:** custom panel with wheel-style buttons in tier colours: header, one button per difficulty (name, notes, duration), Back. Tradeoff: the row handler closes the wheel right after `StartPlay` returns, so the overlay stands alone instead of being a wheel page; Back just closes it.
5. **Converter (additive):** emit `songId`/`tier`/`rank` per difficulty; dedupe audio + background per song; flag/skip non-mania maps; auto-rank by density; osu Version strings stay as the displayed names.
6. **Tier colours** for custom names via a `Key` hook: later, separate commit.

### Plan
Order: A1.5, then A1, A2, A3. A1 is Python-only and cannot regress the loader, so doing it second costs nothing; A1.5 first de-risks the additive-slot pattern that A3 depends on.
- [ ] **A1.5. "Customs only" wheel filter (do first; dry run for the additive HookBase slot):** Rayfield toggle persisted in `Settings.json`; one new slot in the existing HookBase v2 table wrapping `ListPlayableSongInfosForHeld` (module table method, same restore-only-if-ours discipline). ON: return a **new** array holding only entries whose registry song is ledger-owned (`owned[_byId[id]]`, never an id pattern); OFF: return the game's array untouched. Requires the existing "show custom songs in the wheel" option (force it on or grey the toggle out). If the filtered result is empty, fire a one-time notice from the hook. Takes effect on the next wheel open (`_refreshSongs` is called only from `Open`, L3157; rows and search both read `_songEntries`). Forward-compatible with parent rows. Callers verified: wheel `_refreshSongs` (L716) and `RhythmWheelPreview` (L98, hard-coded "Keyboard", first 8 sorted). `ListSongIds`/`ListSongInfos` have no client callers (1,324 scripts scanned). **Live test:** toggle on -> open wheel -> customs only; preview shows customs or an empty list without error; toggle off -> everything back; re-exec zero growth; hook restored on cleanup and on UI-failure rollback; search works inside the filtered list.
- [ ] **A1. Converter + format (Python, additive):** `songId`, `tier`, `rank`; per-song media dedupe (by content); non-mania flagging; old charts and old converter output keep working.
- [ ] **A2. Loader grouping:** build one parent song per `songId` (difficulties inside); registered through the existing ledger so cleanup/restore stays identity-based.
- [ ] **A3. `StartPlay` wrapper + overlay:** new HookBase slot, bypass flag, overlay, synchronous swap. Full live test before commit: re-exec zero growth, ledger, hook restore, play/stop, click from main and search rows, results screen.
- [ ] **A4. (Optional, separate commit) Tier colours:** hook `RhythmDifficulty.Key`.
- [ ] **B. Above-4K (step 4 below):** fold 5K/7K to 4 lanes in the converter (or warn); the fold rule is per map, so it yields a different chart per difficulty. Right after A1, since both change the converter.

### Still to probe at implementation (all quick)
- What the wheel does when `StartPlay` is swallowed (it still calls `Close()`); confirm it assumes no session/state.
- Search-row path (`_selectSong`) behaves the same as main rows.
- Which difficulty the parent row's label and duration reflect.
- Hook slot: no stacking across re-execs, restore only while ours is installed.

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

### 4. Converter vs loader key-count mismatch (scheduled right after multi-difficulty A1)
- Engine fact: `getLaneCount` is fixed per mode (Guitar/RhythmGuitar 2, all others 4), so lanes can't be added; fold or warn.
- `osu2gakuran.py` clamps keys to 1-7; the loader drops lanes above 4 (above 2 for Guitar), so 5K/7K maps silently lose notes.
- [ ] Check how the converter handles >4 keys (Python only, no game needed).
- [ ] Either fold/merge columns to 4 or warn at convert time.

### 5. Small fixes (one commit)
- [ ] Sort notes by `b` in `readChart` (hand-made charts may be out of order).
- [ ] Fix `if type(getfenv) then` (L41) to `== "function"`.
- [ ] Create `SKINS_DIR` in the folder loop (L195).
- [ ] Use `Rayfield:Notify` for errors instead of `warn` only.
- [x] Sync version: code, header comment and README now all say 2.0 (done in the version-bump commit).
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

### Multi-difficulty support (requested) -> moved to "Current focus" above
The plan is now the parent-row + wheel difficulty submenu design in "Current focus" (one JSON per difficulty, grouped by `songId` at load). Only still "later":
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
