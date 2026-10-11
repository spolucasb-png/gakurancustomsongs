# GakuranChart Roadmap

Written 2026-10-10 from a static read of `GakuranChart.lua` (HEAD `fdeab9d`).
**Status:** items 2 and 3 are done and verified live in `c23dba8`; version synced to 2.0 in `353a2e9`. Next up is the "Current focus" section (multi-difficulty, then above-4K). Everything else below is still unverified and untouched.
**Every bug below is "likely, please verify"**. Nothing here has been confirmed in-game yet.
Items are ordered: safety first, then cheap wins, then features.

## Working rules
<!-- SESSION_NOTES.md is not in the repo; these rules are the canonical copy. -->

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
- [x] **A1.5. "Customs only" wheel filter (do first; dry run for the additive HookBase slot):** Rayfield toggle persisted in `Settings.json`; one new slot in the existing HookBase v2 table wrapping `ListPlayableSongInfosForHeld` (module table method, same restore-only-if-ours discipline). ON: return a **new** array holding only entries whose registry song is ledger-owned (`owned[_byId[id]]`, never an id pattern); OFF: return the game's array untouched. Requires the existing "show custom songs in the wheel" option (force it on or grey the toggle out). If the filtered result is empty, fire a one-time notice from the hook. Takes effect on the next wheel open (`_refreshSongs` is called only from `Open`, L3157; rows and search both read `_songEntries`). Forward-compatible with parent rows. Callers verified: wheel `_refreshSongs` (L716) and `RhythmWheelPreview` (L98, hard-coded "Keyboard", first 8 sorted). `ListSongIds`/`ListSongInfos` have no client callers (1,324 scripts scanned). **Live test:** toggle on -> open wheel -> customs only; preview shows customs or an empty list without error; toggle off -> everything back; re-exec zero growth; hook restored on cleanup and on UI-failure rollback; search works inside the filtered list. — DONE: verified live (38→4→38, all-owned, new-array, Guitar empty+notice, real-toggle dependency matrix, cleanup restore, re-exec recovery, SV/skin clean).
- [x] **A1. Converter + format (Python, additive):** `songId`, `tier`, `rank`; per-song media dedupe (by content); non-mania flagging; old charts and old converter output keep working.
- [x] **A2. Loader grouping:** build one parent song per `songId` (difficulties inside); registered through the existing ledger so cleanup/restore stays identity-based.
- [x] **A3. `StartPlay` wrapper + overlay:** new HookBase slot, bypass flag, overlay, synchronous swap. Full live test before commit: re-exec zero growth, ledger, hook restore, play/stop, click from main and search rows, results screen.
- [ ] **A4. (Optional, separate commit) Tier colours:** hook `RhythmDifficulty.Key`.
- [x] **B. Above-4K (step 4 below):** DONE (`a47ae1d`), see item 4. 5K-18K maps are folded to 4 lanes in the converter; the fold is per map, so each difficulty gets its own chart.

### Still to probe at implementation (all quick)
- What the wheel does when `StartPlay` is swallowed (it still calls `Close()`); confirm it assumes no session/state.
- Search-row path (`_selectSong`) behaves the same as main rows.
- Which difficulty the parent row's label and duration reflect.
- Hook slot: no stacking across re-execs, restore only while ours is installed.

## Do in order

### 1. Baseline (read-only)
- [x] Diffed the deployed workspace copy against the repo: byte-identical to HEAD
  at `ad0f3c4` (v2.0.11) before the v2.0.12 batch, so "known good" was unambiguous.
- [x] `SESSION_NOTES.md` is absent from this working tree; its working rules were
  folded into the "Working rules" section above, which is now canonical.
- [ ] Verify each claimed bug in the code, starting with #2 and #3 below.
- [ ] Leave the SV spawn-extension block (~L1092-1220) alone. It was verified live and the review only skimmed it.

### 2. Stability: UI failure leaves a half-initialised loader (L1517, L1780) — DONE (`c23dba8`)
- [x] Register `_G.GakuranChartCleanup` **before** the UI is built.
- [x] Wrap the Rayfield load/build in a protected call (`buildUI()` + `xpcall`).
- [x] ~~Fall back to headless mode~~ Changed approach: on failure the loader **rolls back fully** instead (retire instance via generation bump, run pre-registered cleanup, `sweepRayfield`, deferred `HK.finish()` while a custom session tears down). Headless fallback was dropped.
- Verified live (Test B, forced UI error in a temp copy): hook slots back to original, 0 guard ids, 0 persistentFrame conns, 0 windows, ledger 0; a normal re-exec afterwards recovered everything.
- Why: if the UI errors, the `RenderStepped` connection, skin wrap and hooks stay live and the next run can't clean them up.

### 3. Stability: safety-net hooks stack across re-executions (L143-167) — DONE (`c23dba8`)
- [x] Keep the genuine `SubmitStats`, `QueryJamSync`, `FireStart` and restore them in cleanup. Implemented as a versioned shared base (`_G.GakuranChartHookBase` v2): one stable wrapper per hook, genuine originals recovered by peeling legacy-shaped wrappers, restore only while our wrapper is installed.
- [x] Cleanup removes injected songs from the registry and wheel via an identity-based ledger (`_G.GakuranChartLedger` v1) that also restores displaced genuine entries.
- Verified live: Test A (3 re-execs, zero growth), Test C (custom ids guarded, no network calls), Test D (play/stop/teardown, double cleanup clean).
- Caveat: `SubmitStats`/`QueryJamSync` bogus-id probes matched the guards' return values but were not independently decisive; their wrappers share the verified structure.
- Live test had to cover: several re-executions, Stop, hooks not stacking, and custom ids still neutralized after a restore.

### 4. Converter vs loader key-count mismatch — DONE (fold, `a47ae1d`)
- Engine fact: `getLaneCount` is fixed per mode (Guitar/RhythmGuitar 2, all others 4), so lanes can't be added; fold or warn.
- `osu2gakuran.py` clamps keys to 1-7; the loader drops lanes above 4 (above 2 for Guitar), so 5K/7K maps silently lose notes.
- [x] Checked how the converter handled >4 keys: by then it already skipped them
  with a warning (`--allow-lossy-keys` was the only way through, and then the
  loader dropped lanes 5+). It also clamped keys to 7, which mis-placed the
  columns of 8K+ maps (x is encoded for the real column count). Clamp is now 18.
- [x] **Fold, not warn.** `fold_columns()` in `tools/osu2gakuran.py` folds 5K-18K
  mania maps to the instrument's lane count (4 for Keyboard), so they play in
  the game's normal system with no loader change. One exact integer rule: each
  column goes to the lane it overlaps most; an exact tie (centre column of
  5K/7K/9K, columns 2 and 5 of 6K) is resolved to the least recently used free
  lane. A lane is busy until a hold's end or a note plus 25 ms; leftovers on a
  busy lane are rerouted to the nearest free lane (holds before taps) and an
  object is dropped only when all lanes are busy. Duplicate (time, column)
  objects are merged. Default for keys > lanes; `--no-fold` restores the old
  skip, `--allow-lossy-keys` stays the legacy lossy path. Charts get an
  additive `fold` object (from/to/source/kept/rerouted/dropped/droppedHolds/
  duplicates), `sourceKeys` keeps the original count and `charter` notes the fold.
- Verified: `python tools/test_fold.py` (9 offline tests: exact shapes and
  mirror symmetry for 3-18 keys, no lane overlap on random maps, hold lengths
  kept, deterministic, <=4K path untouched, 10K end to end). On real maps
  (5K "-+" x4, 7K Ievan Polkka x2): 0-3 objects dropped per map out of
  350-1,140 (1 of 985 on 7K), no overlaps, lanes balanced, and the live loader's
  `load()` accepted them (348/348 and 984/984 notes, lanes 1-4, nothing
  dropped by validation). Charts of <=4K are byte-identical to the previous
  converter except `rank`, which is relative to the other charts in the run.
- Not verified: no folded chart has been played in-game yet (feel is the user's
  call), and 6K and 8K+ are covered by synthetic tests only (the one 6K file on
  disk is an empty stub).

### 5. Small fixes — DONE (v2.0.12, all six verified live)
- [x] Sort notes by `b` in `readChart`. Strict weak ordering (beat, then lane) so
  `table.sort` stays valid on duplicates. Verified: input `9/2 1/4 5/1 3/3 1/1 7/2`
  loaded back as `1/1 1/4 3/3 5/1 7/2 9/2`.
- [x] Fix `if type(getfenv) then` (L41) to `== "function"`. Verified the bug class
  live: the old form returns `true` for a *missing* function. No behaviour change
  on Madium (which has `getfenv`); this only matters on executors without it.
- [x] Create `SKINS_DIR` in the folder loop. Loop pattern verified on a throwaway
  path (`GC_ztest/Skins` absent -> created); the real Skins dir was not deleted to
  test, so this one is "mechanism verified", not a true negative test.
- [x] Use `Rayfield:Notify` for errors instead of `warn` only. `notify()` took an
  `isError` argument and discarded it, so nothing ever reached the screen. Now
  routed through a late-bound `uiNotify` set by `buildUI` (nil if the UI build
  fails, cleared by cleanup, `pcall`-guarded). Verified: a real notification
  rendered at `Container.Rayfield.Notifications.No chart`.
- [x] Sync version: code, header comment and README now all say 2.0 (done in the version-bump commit).
- [x] Fix README: the "one note image for all 4 lanes" claim is gone, along with
  the references to files the repo does not ship.
- [x] Background dim does nothing for images: a black `Dim` overlay frame now sits
  over the ImageLabel. Verified live at 60% dim -> `Dim.BackgroundTransparency` 0.4.
- [x] Honor per-chart `chart.offsetMs` in `buildGameSong`. Now `settings.offsetMs +
  chart.offsetMs`. Verified live: global 50 + chart 123 -> injected `offsetMs=173`.
- [ ] Clearer "N notes dropped" message when validating charts.

### 6. Startup self-test and `_G.GakuranChart.diag()` — DONE (v2.0.13)
- [x] `diag()` reports, as one JSON-encodable table: every getgc target, the
  private service state (`_session`, `_view`, `_resultsScreen`, `_registry`,
  `_active`, `_carryOverStats`), the service methods, each hook slot's status
  (`installed` / `beneath-foreign` / `displaced` / `absent`), counts (charts,
  parents, customIds, guard ids, ledger recs, registry size, skin packs, wheel
  controller) and the live settings. Plus a `summary` line.
- State and methods are checked differently on purpose: private state via
  `rawget` (identity on the instance is the point), methods via plain index
  (they live on the class and arrive through `__index`). The first cut used
  `rawget` for both and reported `Stop`/`Get`/`Init`/`IsPlaying` as missing —
  a false alarm in a diagnostic is worse than no diagnostic.
- Baseline on placeVersion 7646: all 9 targets found, 8/8 hooks installed,
  6/6 methods present, `_registry` true with the rest nil while idle.

### 7. Single-pass `getgc` scan — DONE (v2.0.14)
- [x] It was **9** scans, not 8 (the ninth is the note-shape settings host, in a
  top-level `do` block). New `gcScan(specs)` resolves all nine in one sweep:
  each predicate retires the moment it matches, and the sweep returns early
  once nothing is pending. Predicates were moved verbatim. No `pcall` per
  predicate - they only `type()`/`rawget()` a table, which cannot error, and a
  pcall per predicate per heap value would cost more than the passes it saves.
- [x] Confirmed via step 6: `diag()` output is identical to the v2.0.13
  baseline (same 9 modules, 8 hooks, 6 methods, and identical counts -
  `registryById=106`, `ledgerRecs=7`, `customCharts=16`, `parents=3`).
- Measured in-game on a 1,981,736-object heap: 9 sweeps 1.695 s -> 1 sweep
  0.566 s. **1.13 s saved per execution, 3.0x faster** (not 9x: both the old
  and new paths stop early once a target is found).
- `gcFind` is kept for any lookup that has to happen later, but nothing calls
  it now.

### 8. Local scores (`Scores.json`)
- [x] **Payload captured live** (2026-10-11, placeVersion 7646) by recording at
  the guard wrapper during a real `test_end` play, delegating so the guard still
  swallowed it. `RhythmStatsClient.SubmitStats` takes 5 args:

  | # | type | value seen | meaning |
  | --- | --- | --- | --- |
  | 1 | string | `"test_end"` | song id |
  | 2 | string | `"Keyboard"` | mode / instrument |
  | 3 | number | `0` | unidentified (0 on a no-input run) |
  | 4 | nil | `nil` | unidentified (absent on this run) |
  | 5 | table | `{Clutch=0, Hits=0, Judged=27, MaxCombo=0, Score=0}` | the stats |

  Args 1, 2 and 5 are unambiguous and are all the feature needs (accuracy =
  `Hits/Judged`, misses = `Judged - Hits`). Args 3 and 4 stayed 0/nil because
  the capture run took no input; identify them from a played run before relying
  on them. `QueryJamSync` was also seen firing twice with the custom id and
  being correctly swallowed.
- [x] **DONE (v2.0.16).** `GakuranCharts/Scores.json`, one row per chart with
  `plays`, `lastPlayed`, `best` and `last`; each run holds score, maxCombo,
  hits, judged, misses, clutch, `hitRate` and the engine's `raw` table
  verbatim. Recorded at the guard wrapper via `b.scoreHandler` on the base
  record (same discipline as `b.handler`), with `HK.submitRev = 1` so a client
  already holding a v2 base gets the new wrapper body instead of silently
  recording nothing. Cleanup clears the handler so a retired instance never
  records. API: `scores()`, `scores(id)`, `scoreLine()`, `clearScores([id])`;
  the Charts tab shows the loaded chart's best and a finished run notifies
  "New best!" / "Score saved".
- Keyed by **chart** id, not the submitted song id: a multi-difficulty parent
  submits the PARENT id, so keying on that would collapse a song's difficulties
  into one row. `customCharts[songId]` is re-pointed at pick time, so it names
  the difficulty actually played.
- Live verification: a real 28 s play recorded 0.0 s after the song ended
  (`judged=27 hits=0`, correct for a run that took no input); `rev=1` confirmed
  the wrapper body was rebuilt; the guard still passes a genuine id through and
  still swallows a custom one; best-vs-last kept 500000 over a later 1000;
  derived figures correct (25/27 -> 92.59%, 2 misses); scores survived a
  re-execution (reloaded from disk) with 8/8 hook slots still ours.
- Still open: `SubmitStats` args 3 and 4 remain unidentified (0/nil on every
  no-input run so far). They are stored on each run as `a3`/`a4`, so the first
  genuinely *played* run will reveal them with no extra work.

### 8b. Safety net: call conventions now verified (was an open caveat)
The note under item 3 said the `SubmitStats`/`QueryJamSync` bogus-id probes
"were not independently decisive". They are now:
- `stats.Init` takes **0** params, so the stats module is static
  (`function M.Init()`, not `M:Init()`) - therefore the genuine
  `SubmitStats(songId, ...)` really does take the song id first and the
  loader's `function(songId, ...)` wrapper is correctly shaped.
- `relay.QueryJamSync` and `relay.FireStart` are 1-param plain calls, matching
  their wrappers; `service.StartPlay` is 4-param method-style, matching
  `makeStartPlay`'s leading `self`.
- Demonstrated live that an engine-shaped call (plain, custom id) does **not**
  reach the genuine original, with a recorder standing in for it. A synthetic
  method-style call *does* slip past the guard, but the engine never makes one -
  `Init`'s arity rules it out. Worth re-checking if the module ever becomes
  method-style.

### 8c. Rayfield chart list: one row per song — DONE (v2.0.17, `79ddd94`)
The Charts tab listed every chart file as its own row (13 rows for 7 songs).
It now lists songs; a second "Difficulty" dropdown appears only for songs with
several difficulties. This is the Rayfield list only - the wheel keeps its own
parent rows and submenu (A2/A3) and is untouched.
- [x] Multi-difficulty songs are marked (`me & u - succducc  [5 diffs]`).
  Picking one shows the selector, fills it with that song's difficulties
  (with star ratings) and loads the easiest; a single-difficulty song hides
  the selector and loads directly.
- [x] Ordering reuses `sortDiffs`/`chartDensity`, so the list and the wheel
  agree on which difficulty comes first.
- [x] Grouped from the chart files, not from `parents`: `injectAllCharts` only
  fills `parents` when "show custom songs in the wheel" is on, and this list
  has to work either way.
- [x] Rayfield's dropdown object only has `:Set`/`:Refresh`, so the selector is
  shown/hidden through its own Frame (found by name, filtered on the
  `Selected` child only dropdowns have). If Rayfield's internals change the
  frame is not found and the selector just stays visible - usable, never
  broken. Confirmed live: `:Set` fires the Callback, `:Refresh` keeps
  `CurrentOption`.
- Live verification: 7 song rows, selector starts hidden; `me & u` shows 5
  difficulties by star rating and loads `aries' beginner`; switching to
  `hyper` loads it; a single-difficulty song (Endtest) hides the selector; a
  2-difficulty song (Ievan Polkka) brings it back with the easiest selected;
  no console errors; `tools/check.py` passes.

### 9. Quality-of-life
- [ ] Retry hotkey and Stop keybind.
- [ ] Remember per-chart offset automatically; optional tap-to-calibrate.

### 10. Source game icons (customs vs native now, other engines later) — IN PROGRESS (session 7)
- Chart JSON gains additive `"source"` (converter `--source`, default `"osu"`;
  backfilled: 29 workspace charts `osu`, `test_end` `local`). `formatVersion`
  stays 1; `check.py` needs no change (syntax-only).
- Loader v2.0.22: `readChart` defaults missing/invalid source to `"unknown"`;
  `buildGameSong` sets `song.gakuranSource` (added to `SWAP_FIELDS`) and
  prefixes wheel-row titles (`[osu!]`, `[local]`, `[custom]` fallback) — title
  prefix touches game wheel/search rows only (Rayfield uses `chart.title`,
  submenu uses difficulty names). `★x.xx` difficulty strings untouched so the
  `DiffKey`/`DiffTier` hooks keep matching.
- True `ImageLabel` icons where we own the GUI (overlay rows, Rayfield);
  native submenu slots get a source tag in title/sub (their `art` table goes
  to the game's `_setSlot`). Icon asset map (`Assets/icons/<source>.png`)
  with graceful fallback while PNGs don't exist yet.
- Main-wheel image-beside-badge needs live wheel-skin research (user accepted
  the update-fragility risk): find the row frame beside `DiffText`, add an
  `ImageLabel`, guard everything with pcall. Queued as a live step.
- Live gate before deploy: 30/30 load, tags visible on screen, hooks still
  ours, no `Scores.json` regrowth, re-exec zero growth.
- [x] DONE + DEPLOYED v2.0.22 (live-verified on client 14512, see HANDOFF
  session 7; wheelRev 3). Not yet eyeballed on screen by the user; overlay
  branch + Rayfield labels still only init-clean.
- [x] Icon placement fixes v2.0.23 (wheelRev 4): icons are Diff-frame children
  (6px left of the badge — overlap gone, hover-follow structural), sweep on
  both wrap paths (submenu shows 0 stale icons, list restores 8/8, 0 stacked).
  Live-verified on client 14512; user eyeball still pending.
- [x] v2.0.24 (wheelRev 5 + new WheelSearch slot, rev 1): parent rows use the
  Len frame (their Diff badge is hidden 15px — icons are instances but
  invisible there), search rows painted via _renderSearchResults wrap (killed
  the blue-on-SOUND-ARCHITECT stale). Verified: list 8/8 visible (singles
  @Diff, parents @Len, correct pink/blue assets), search pink, real-path
  submenu 0, diag clean. Probe lesson: driving wb.wrap with hand-set pending
  skips armWheelMenu (renderMenu nil → base path) — test submenus via
  G.openPicker, not raw wrap calls.

### 11. Multi-format charts + skins (Etterna, Quaver) — DONE (session 8)
- Converters: `tools/sm2gakuran.py` (.sm dance-single → chart JSON, beats =
  (measure + row/rows)*4, holds `2→3`, rolls `4→3` as holds, mines skipped
  with warning, `#OFFSET` s → offsetMs) and `tools/qua2gakuran.py` (.qp zip
  → .qua set → chart JSON each, ms clock → beats via first BPM exactly like
  the osu converter, EndTime holds, SliderVelocities → scrollChanges,
  TimingPoints[1:] → animationBpmChanges). Shared code imported from
  osu2gakuran (sanitize_id, tier_for, place_media, assign_ranks); same schema,
  `source` = etterna/quaver; Keys4 needs no fold (5K+ folds like osu).
- Skins: `tools/qua2skin.py` (4k/HitObjects per-lane taps via manifest.taps,
  receptor-up/down, holdbody+holdend composite tail) and
  `tools/etterna2skin.py` (single-arrow Noteskin: _Up tap/go/press + hold
  body, no caps) importing the osu2skin PNG codec. Output to repo
  GakuranCharts/Skins (converted packs, committable).
- Loader v2.0.25: SOURCE_TAGS + `Assets/icons/{etterna,quaver}.png`
  (make_source_icons COLORS). Live gate: all new charts load, spot-play one
  .sm + one .qua (SV), both skins apply without vis errors.
- [x] Unified front-ends (user request): `tools/convert_song.py` (.osz/.osu/
  .sm/.qp/.qua + dirs, one rank pass) and `tools/convert_skin.py`
  (auto-detect osu/quaver/etterna) import the tested per-format modules —
  deliberate import-over-merge so the proven osu path is byte-untouched.
  Per-format CLIs stay as entry points. Proven: unified song run ==
  per-format runs byte-identical (6 charts); unified skins == per-format
  17/17 files; osu2skin refactor regenerates the production nc_skin PNGs
  7/7 identical.
- [x] Skin eyeball fixes: quaver tail tips pointed inward (flip convention is
  skin-specific — qua/etterna use as-is-top/flipped-bottom, opposite of osu);
  etterna showed one Up arrow everywhere (now real Left/Down/Right per-lane
  taps) and fat holds (128px doubleres body normalized to the ~58px head).
  Receptors stay single-arrow (schema has no per-lane receptors).
- [x] DEPLOYED v2.0.25: 36/36 load (29 osu + 1 local + 2 etterna + 4 quaver),
  nyan + bozo (6611 SV pts, 0 err) played, both fixed skins 0 vis errors,
  scores cleared after test plays, workspace == repo.
- [x] v2.0.26/v2.0.27 skin-correctness round (user eyeball): per-lane hold
  heads (loader prefers tapImgs[lane] when the pack has no headHold),
  per-lane receptors (new manifest.receptors/receptorsPressed + recN/recPN
  packs + ss.recImgs plumbing), etterna cap crop (128px dead canvas rendered
  as hold/body gap). Real bug found by the new recLanes diagnostic:
  registerSkin built recImgs but activateSkin never copied them into
  skinState — always check the handoff between tables. Verified live:
  rec1/2/4 = Left/Down/Right hashes, lane 3 = base Up, hold heads per-lane,
  0 errors. DEPLOYED v2.0.27, workspace == repo.
- [x] Etterna tip correction: the bottomcap art is a point-DOWN chevron
  (misread as point-up from a thumbnail — re-viewed the source to confirm),
  so the osu convention (flipped on top, as-is at bottom) was right all
  along; the "swap" was reverted. Lesson: cap orientation is per-skin
  (quaver end-bulbs want as-is-top, etterna chevrons want flipped-top) —
  verify against the source art, not memory. Tail redeployed, live sanity
  clean (0 errors, taps=3, recs=3).
- [x] v2.0.28 hit-flash orientation (user: hit effects all-Up): the engine's
  PlayHitEffect clones a template painted ONCE with the base note image, so
  flashes ignored per-lane art. Fix: per-frame repaint of live
  HitFlashTemplate clones with lane-mapped tap art (lane from Position.X via
  view._laneXs; our shape registers Rotation 0 so the engine's flash rotation
  is a no-op). Verified by spawning REAL flashes through PlayHitEffect:
  lane 1 = tap1 hash, lane 4 = tap4 hash, 0 errors. DEPLOYED v2.0.28.
- [x] v2.0.29 hit flash AND ring oriented at spawn (user: the flash still does
  not spawn oriented like the receptor arrows). Measured with real
  `PlayHitEffect` calls: the engine orients flash/ring only through
  `GetRotation(shape, lane)` (0 for our shapes) and both pools share the base Up
  image and recycle frames with the previous lane's art, so v2.0.28 only fixed
  the flash a frame late (a lane-4 flash spawned with lane 1's art) and the ring
  was never repainted (Up on every lane). Fix (`wrapHitEffect`): a per-view
  `PlayHitEffect` wrapper that, for one call, shadows `acquire` on `_flashPool`
  and `_ringPool`, so the frame is painted with that lane's tap art the moment it
  is handed out. Removed right after the call (also on error); `unwrapHitEffect`
  (from `restoreViewVisuals`) removes the wrapper and resets all pooled frames to
  the base image. The per-frame repaint stays as a fallback and now covers the
  ring; the guard also accepts skins with only per-lane tap/receptor art.
  Verified live (client 14512, AmbieArrowsFFR): 24/24 forced effects and 40/40
  ENGINE-triggered effects (real key input judged by the engine) had the right
  flash AND ring art at the spawn instant on lanes 1-4, incl. recycled frames; no
  `acquire` shadows left; 0 visual errors; switching to another skin or "Game
  default" removed the wrapper and reset all 16 pooled frames, switching back
  re-wrapped with spawns correct again; two back-to-back loader re-runs left
  14/14 hooks installed. DEPLOYED v2.0.29, workspace == repo. NOT verified: a
  skin with per-lane taps but no pressed/hold art (none on disk), drums/guitar
  instruments, and the receptor-glow/shard art (shards use a separate sprite).

## Later / future add-ons

### Multi-difficulty support (requested) -> moved to "Current focus" above
The plan is now the parent-row + wheel difficulty submenu design in "Current focus" (one JSON per difficulty, grouped by `songId` at load). Only still "later":
- **Cleaner version:** one JSON per song holding several difficulty charts (format v2). Touches loader and converter together; only if the cheap version feels limiting.
- Keep it game-agnostic: Clone Hero (Easy-Expert) and StepMania work the same way.

### Medium effort
- [ ] Chart browser: search, sort by difficulty/BPM, cover, artist, note count, favourites. (The difficulty switcher now exists as the Rayfield selector, item 8c; this would build on it.)
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

### 9b. Instrument stayed equipped through the end screen — DONE (v2.0.15)
Reported from play: the keyboard did not leave the character's hands when a
song finished. Root cause, found live: clearing `PlayingInstrument` is what
unequips (`KeyboardClient.evaluateLocal` listens on it), but the same attribute
change also drives `RhythmServiceClient.stopIfInvalidContext`, which calls
`Stop()` and destroys a results screen that is still displayed. The v1.1 fix
avoided that by waiting for the results screen to be dismissed first - so the
instrument stayed in hand for the whole end screen.

What the live experiments established, in order:
1. Clearing the attribute with `_session`/`_view` already nil **still** destroys
   the results screen, so narrowing the wait to session+view does not work.
   `stopIfInvalidContext` acts on the attribute alone.
2. Suppressing only `stopIfInvalidContext` was **not** enough - the screen still
   died. `Disable()` was confirmed effective (`Enabled` true -> false -> true),
   so another listener was responsible.
3. Unmasking the `Profiled` decorator (the connection reports the decorator's
   source, not its target) named the other two: `recheck@RhythmWheelServiceClient`
   and `sync@InstrumentServiceClient`.
4. Suppressing those three - and letting every other listener, including
   `KeyboardClient.evaluateLocal`, see the change - unequips the character AND
   leaves the results screen standing.

Implemented as `withContextTeardownSuppressed`, which `restoreAttributes` wraps
its writes in; `surfaceStillUp` no longer counts `_resultsScreen`. Matching is
by the wrapped function's name, never by connection index, the window is one
frame on our own restore path, and the listeners are re-enabled unconditionally
including when the write throws. No `getconnections` -> suppression is skipped
and the old behaviour applies.

Verified live through the loader's own watcher: song ended t+33.1s, results
screen up t+33.1s, `PlayingInstrument` cleared t+33.6s, results screen still
up afterwards, 7/7 suppressed listeners re-enabled.

## Known limits
- Custom stage lighting isn't implementable: the engine has no lighting slots, only flash/ring pools.
- Flash/ring matching: done in v2.0.29 (see the hit-flash entries above).
- The day_by_day audio file was overwritten once; the overwriter was never identified.

### 9c. Reload noise: Rayfield notification errors + flaky wheel scan - DONE (v2.0.18, `8da328b`)
Reproduced on the live client with v2.0.16 and v2.0.17 (same behaviour).
- [x] **Rayfield notification errors.** `Title/Icon is not a valid member of Frame "Song wheel"` (Rayfield L1387/L1411). A reload destroys the previous Rayfield GUI while `RayfieldLibrary:Notify`'s own `task.spawn` threads (~5.3 s life) are still asleep; when they wake the frame has no children. N back-to-back reloads printed N-1 pairs; reloads >= 8 s apart were clean; the new instance was never affected. Fix: `HK.loadRayfield` patches the Rayfield source in memory (file on disk untouched) with a "frame still parented" check after each of the 6 `task.wait` statements in `Notify`; falls back to the untouched source if anchors are missing or the patched chunk does not compile.
- [x] **Wheel controller discovery.** `findWheelController` scans `getgc(true)`, which is non-deterministic (five identical scans: 4, 4, 0, 4, 4 hits), so `Wheel controller not found - difficulty picker falls back to overlay` appeared in roughly 2 of 10 reloads. Init now retries up to 3 times (forced, 0.25 s apart) and stops if a newer reload took over.
- Verified: 10 reloads (4 back-to-back, 3 at 4 s, 3 at 8 s) = 0 error lines, 0 wheel warnings; `diag().counts.rayfieldGuard` = 6; 1 Rayfield GUI left; `tools/check.py` passes.
- Not verified: whether the retry ever fired (not instrumented), and the wheel submenu / play / stop on 2.0.18.
- Open follow-ups: deploy with `python tools/deploy.py --live`; the guard depends on `RayfieldLibrary:Notify` keeping its shape (it warns and falls back if not).
