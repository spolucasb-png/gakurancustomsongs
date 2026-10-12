# Handoff (for the next chat session)

## Branch check (session 24, review-prompted): `main` == `origin/main` == `a1c24bc`, no ahead/behind, remote contains HEAD. The stale 831-line GitHub `main` view was cache — no pointer issue, no fix needed or made.

## Standing constraint (agreed session 23): the verified `.ssc` conversion path stays UNCHANGED until gameplay evidence shows a defect. New tests (synthetic stops/reverses, multi-BPM) observe first, change code only with a failing measurement in hand.
- Session 26 addition: external hardcoding audit recorded as ROADMAP item 14 (RECORDED, not started). Same constraint covers it: tests-before-changes; high findings (Quaver InitialScrollVelocity, Etterna ref-BPM axis, ID collisions) wait for fixtures + measured evidence like everything else.

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

### Session 26 (2026-10-12): crystallized HARD badge — ROOT CAUSE FOUND + FIXED in loader v2.0.31 (init-path verified live, direct-play path pending user check)
- Screenshot showed the WHEEL badge (not picker) reading raw HARD — real defect. Ledger proof: injected song object carried `difficulty="Hard"` while April's carried `"★4.03"`; chart data verified perfect live (mode/notes/duration all correct, ★4.61 computes).
- Root cause: `playChart()` (loader-UI direct plays) rebuilds via `buildGameSong` (raw name) and re-injects, clobbering the starred row — crystallized was started from the loader UI, April from the wheel (wheel plays never rebuild). Same bug class in the picker path: SWAP_FIELDS carries raw `difficulty` into the parent song, clobbering its "N diffs" label.
- Fix (loader only, converter freeze untouched): new `starDifficulty(song, chart)` helper (same overwrite injectSingle used); called in `playChart` after build; picker path restores `parent.label` (nil-guarded) instead. VERSION 2.0.30 -> 2.0.31 (constant + header).
- Deployed: repo file copied to workspace executor copy (sha-verified identical), executed via run_executor_file, `gen=2 version=2.0.31`, ledger re-read: crystallized row now `★4.61`. Init path VERIFIED live.
- PENDING: direct-play path needs a loader-UI play of crystallized + badge/ledger re-check (needs user UI interaction; I cannot set currentChart). No scores involved.
- VERIFIED by user (session 26): loader-UI play leaves the badge intact, no problems. Direct-play path closed; v2.0.31 fully live-verified.

### Session 25 (2026-10-12): 3 more Etterna SV maps added (user request, deployed)
- Picks (explicit `.ssc` paths, unified frontend, scratch-first): crystallized (2071 notes, 174 BPM, 12 SV: 0.75→1.0 ramp, 1 BPM seg), GO 4 IT (4481 notes, 172 BPM, 10 SV: 1.0→0.1 staircase, 1 seg), Chesire,s dance (2382 notes, 120 BPM, 4 SV: 10x spike + 0.3 dip, 7 BPM segs — MULTI-BPM caveat applies, flagged not blocking).
- Source OFFSETs passed through verbatim (not a defect): crystallized -3487 ms, go4it +954 ms, chesire +1776 ms. If any chart feels globally off-sync in playtest, OFFSET is the named suspect — it's pack data, converter doesn't touch it.
- No STOPS/SPEEDS in any of the three (no skips/warnings). Audio wired on all three. No workspace collisions; deployed additively (3 JSON + media). No converter/loader code touched (freeze holds).
- Awaiting user eyeball vs Etterna whenever ready.

### Session 28 (2026-10-12): review P1+P2 safety gaps closed (single isolated commit)
- P1-1 batch-abort persistence: `batch_aborted()` (true once WRITE_REFUSALS non-empty); all 3 convert_file entries early-return, archive member loop breaks (deferred import, no load-time cycle), write_chart_json refuses silently post-abort, place_media unreachable post-abort via entry guards. Rollback failures recorded in ROLLBACK_ERRORS + loud WARNING (unit-tested via monkeypatched unlink). Regressions: unique-after-collision (+media both sides) leaves tree empty; archive [twin→late] breaks before late + pre-existing byte-identical.
- P1-1b malformed existing JSON (review follow-up): read catches `(OSError, ValueError)` (UnicodeDecodeError included), non-object parsed values fail isinstance (no AttributeError escape); all route to refusal+rollback. Regressions: pre-existing `[]` and invalid-UTF-8 victims, each with earlier chart+media in-batch, victims byte-identical, batch fully rolled back.
- P1-2 rank/write ordering: collision identity excludes volatile `rank` (normalized compare); normalized-equal skips the write (keeps ranked file), assign_ranks recomputes identically. Genuine diffs still refuse. Rank policy (b, user-chosen): partial runs (known charts missing from batch, incl. new difficulties) preserve saved ranks byte-exact, new ids stay provisional + loud full-song warning; completeness via PREBATCH_IDS snapshot at begin_batch (required — just-written defaults are otherwise indistinguishable from saved ranks). Regressions: full-CLI multi-diff twice byte-stable; Hard-alone preserves rank 2; two-of-three preserves both; new-difficulty warns provisional, sibling untouched.
- P2-3 CRC: `except (ValueError, BadZipFile, EOFError)` around extraction (narrow by design); CRC-corrupt .osz+.qp skip cleanly with tree unchanged (payload-flip fixtures).
- P2-4 canonical dup targets: resolved + `normcase`d path keys (`a.osu` vs `./a.osu` refused everywhere; case variants refuse iff the OS folds). Fixed a real bug found by the new test: normcase emits os.sep (backslash on Windows), defeating the `/`-based prefix walk — keys re-unified to `/` post-normcase. File/dir prefix preflight added (dir markers with content pass; file-prefixing-member refuses) + explicit-marker test.
- Suite-batch discipline learned the hard way: process-global tracking + top guards mean direct-call tests must delimit batches (`S.begin_batch()` in convert() helper + collision tests); mains delimit via begin_batch. 4 tests failed before this was understood — all green after.
- Gates (final): archives 18/18, sm 18/18, qua 8+2skip, fold 10/10, check 20 files. Byte proofs re-run after every stage: sm 6/6 vs pre-ssc, april identical, dragon+bozo archive-stable, media identical. No SV math / loader / initial-SV-fix changes.
- PROCESS: single D+E+F commit (not three). Reconstructive splitting was judged too error-prone tonight after 3 edit mistakes + the keep-file scare; the batch is one isolated safety layer, tests are per-finding, acceptance never demanded the split. git-apply still broken (see session 27).
- A (`b475ef1`): Quaver InitialScrollVelocity fixtures as SKIPPED known-issue tests (both fail on current code as designed: empty scrollChanges / missing beat-0 point); suite reports `8/10 passed, 2 skipped (known-issue)` — skips counted separately, never in the pass total. NO converter change (review: no initial-SV fix sneaks in).
- B (`aad121e`): no-overwrite chart guard with batch rollback. `write_chart_json` (shared, osu2gakuran): identical bytes = idempotent pass; differing = ERROR + rollback of everything the batch created (charts + new media; pre-existing/reused untouched) + exclusion from results. `assign_ranks` aborts (no resurrection, exit 1); all 4 mains wire `begin_batch` + `ok`. Collision demo now: first twin refused, tree empty, exit 1. Regression tests: refusal+rollback, sanitized-ID ("A/B" vs "A B"), idempotent rerun.
- C (`16ce8ca`): shared `tools/zipstage.py` (`safe_extract` incl. duplicate-member refusal + `nested_charts` + `convert_archive`); osz/qp route through it (unique system tmp, corrupt→skip, nested→loud warn); `test_archives.py` 9/9 (slip/abs/dup unit, valid/nested/corrupt both formats, colliding-batch pristine incl. sentinels, pre-existing byte-for-byte).
- Per-commit gating via worktrees (A: qua 8+2skip; B: sm 14/14, qua 8+2skip, fold 10/10; C==HEAD: all + archives 9/9, check 20 files). Byte proofs: sm 6/6 vs pre-ssc baseline, april identical, dragon+bozo archive-stable, media identical. No loader/Lua/deployed-chart/SV-math changes anywhere.
- Review acceptances mapped: both initial-SV cases documented failing (no fix); in-batch/existing/sanitized collisions refuse with zero partial (rollback, sentinel-tested); nested handled intentionally (warn+skip); baselines taken before changes (smold + base_arch); BPMDoesNotAffectScrollVelocity NOT touched (separate follow-up).
- TOOLING NOTE: `git apply` (even trivial/--check) fails repo-wide — environmental, unrelated to content (pure-LF files, valid patches). Hunk-splitting via patch files does NOT work here; the A/B/C split was done reconstructively (reverse C-hunks → commit B → re-apply → commit C). Do not attempt `git apply`/`git add -p` in this repo until that is diagnosed.
- Scratch: /tmp/collide (demo), /tmp/splitbc.py + B/C.patch (spent), /tmp/full.patch (reference), keepdir/ emptied (files moved back).

### Session 24 (2026-10-12): synthetic stop/reverse chart BUILT (scratch-only, not deployed)
- `_scratch_convert\\synth_sv\\`: `synth_sv_test.ssc` (single 150 BPM, 13 taps, 8 `#SCROLLS`) + generated 25 s `silent.wav` (stdlib wave, so Etterna can time it) + unified-frontend output + staged drop-in overlay at `_scratch_convert\\synth_sv\\workspace\\GakuranCharts\\` (JSON + wav). NO workspace collision (`*synth*` absent). NOT deployed — holding for user go-ahead per the April procedure.
- Design (beat = 0.4 s, offset 0): baseline notes b4/8/12 (1.6/3.2/4.8 s) | STOP b16 (6.4 s) resume b20 (8.0 s), notes b15/18/21 (6.0/7.2 frozen/8.4 s) | REVERSE -1.0 b28 (11.2 s) resume b32 (12.8 s), notes b27/30/33 (10.8/12.0 backward/13.2 s; reverse displaces -1.6 scroll-s) | COMBINED 0@b40 (16.0 s), -0.5@b44 (17.6 s), 1@b48 (19.2 s), notes b39/42/46/49 (15.6/16.8 frozen/18.4 slow-backward/19.6 s; -0.5 leg displaces -0.8 scroll-s).
- Converter output verified against design (13/13 beats, 8/8 scroll points verbatim). Self-correction on record: first draft misplaced 3 taps on transition boundaries (20/32/48 instead of 21/33/49); caught on output inspection (19.2 vs 19.6 s duration), fixed with one revert of a wrong-measure edit plus the two correct moves, re-verified 13/13.
- NO converter/test code touched (verified path frozen, session 23). No new regression test: this is a gameplay fixture, not a code change.
- Next: user deploys overlay + playtests Etterna vs Gakuran at the windows above; record expected-vs-observed before any code talk.
- DEPLOYED on review go-ahead (2 new files only: JSON + wav; no overwrites, no converter/production/workspace-file changes). Deployed JSON re-parsed from the workspace path: 13 notes, 8 SV. Awaiting user playtest per the section table (baseline <6.4 / stop 6.4-8.0 / reverse 11.2-12.8 / combined freeze 16.0-17.6 / slow reverse 17.6-19.2 / resume 19.2+).
- OBSERVATION LOG (user playtest, unconfirmed): "mostly works"; reverse + combined freeze "off"; combined freeze shows "2 notes, left and right lanes, near the receptors" (user-hedged). Code trace (no code change): spawn math predicts b42/b46/b49 ALL spawn early (ts 15.0/14.6/~14.6, order-clamped to >=15.0) and park at receptors from ~15-16 s; in the reverse at ~12 s exactly lanes 1+4 near receptors is the CORRECT rendering (b30 due + b33 pushed 0.4 scroll-s below receptors by the backward integral). So "2 notes lanes 1+4" fits the reverse section behaving correctly — section/lane ambiguity unresolved. NO defect isolated; frozen path untouched. Next: user confirms exact lanes + timestamp + pop-in-vs-wrong-motion, or approves a bounded live counter read (svStatus only, no scans).
- [SUPERSEDED — wedge cleared post-rejoin, counters read in the probe below.] LIVE READ ATTEMPTED (user-approved, bounded: runtime_status + one trivial svStatus eval, no scans, no play): FAILED on delivery, not on facts. Eval queued, never returned — the session-16 wedge is still in the queue. Console fallback gave real data instead: wheel shows 16 songs/38 difficulties (synth chart picked up), user played it 3x (7700 -> 9000 -> 9700, rising = active testing, source of the "2 notes" report). Counters UNREAD — need a client rejoin/restart before any eval-based read. Do NOT stack more evals.
- [RESOLVED by the mid-song probe below — clearScores ran in-probe on the shared workspace file.] HYGIENE DEBT: 3 "New best!" Synth SV Test scores recorded in-console; `clearScores("synth_sv_test_medium")` still owed (blocked on the same wedge). Remind the user or do it post-rejoin.
- [RESOLVED — loader ran via run_executor_file, probe completed, see below.] POST-REJOIN (fresh client 15120): eval queue is CLEAR (trivial probe returned instantly) — wedge gone. BUT loader not executed in this session yet (`gen=nil version=nil`, early return, no play started, no scores touched). Next: user executes the loader as usual, then I rerun the single play + mid-song svStatus + stop + clearScores probe.
- USER AUTHORIZED loader run ("run the script/loader, u can go"): executor copy byte-count-verified vs repo (204506 == 204506, v2.0.30, repo unmodified since 96abc30), ran via run_executor_file, init `gen=1 version=2.0.30`.
- MID-SONG svStatus LIVE (single probe: Keyboard attr, load, play, 17 s wait = combined-freeze window, stop, clearScores, attr restore): `bound=true disabled=false errors=0 perspective=false modelId=synth_sv_test_medium points=8/8 sessionCustom=true spawnExtended=7 spawnCapped=0 spawnOrderFix=4`. CONCLUSION: spawn path verified working live — model complete, 7/13 notes extended early, 0 caps, 0 errors, counters match the code trace (order clamps on clustered freeze/reverse notes). Spawn-defect theory for "2 notes" WEAKENED (extension demonstrably ran); lanes-1+4-in-reverse = correct rendering stands as lead explanation. Still need user's section/lane datum for the final word. Hygiene: probe's own score cleared in-probe; the 3 pre-rejoin "New best!" rows were in the same shared workspace Scores.json → also wiped by this clearScores.
- COMMENT-ACCURACY NOTE (review-caught, verified locally, NO code change — frozen): the `svSpawnOrderFix` declaration comment (`GakuranChart.lua:2350`, ">0 only with cap cascades") is wrong — the counter increments at :2587 on the prev-spawn order clamp, which runs BEFORE the concurrency-cap logic, so `spawnOrderFix=4` with `spawnCapped=0` is fully consistent. Fix the comment text only, opportunistically, next time the loader is legitimately opened for a defect-driven change. Corrollary: the counter alone doesn't attribute the 4 clamps to freeze/reverse notes specifically.

### Session 22 (2026-10-12): April Showers LIVE-VERIFIED by user ("same as same")
- User playtested Etterna vs Gakuran: scroll-rate behavior matches. Rate-variation fidelity on a single-BPM `.ssc` chart is VERIFIED by user eyeball (final authority). Scope honesty preserved: this says nothing about stops/reverses — zero/negative scrolls still untested anywhere (no local chart has them; synthetic chart remains the next step if wanted).
- No code changed this turn (docs only). No scores involved (user playtest, not a staged probe).

### Session 21 (2026-10-12): April Showers controlled-test staged (convert + isolated overlay)
- Followed the approved procedure steps 1-2: converted via the UNIFIED frontend on the explicit `.ssc` path (1 chart only — the `.sm` twin untouched, no collision): 809 notes, 158 BPM, offset -117ms, 16 SV verbatim, rates {0.2, 0.75, 1.0, 3.0}.
- Collision check: no `*april*` in the 36-chart Madium workspace — clean. Staged a drop-in overlay at `Referencesandmods\\_scratch_convert\\april_test_workspace\\GakuranCharts\\{Charts,Audio,Assets}` (single JSON + mp3 + jpg); known-good workspace untouched. To deploy: copy the overlay's `GakuranCharts/*` over the workspace root.
- Playtest timestamps for the user (158 BPM): wobble beats 113.5-115 -> song ~43.1-43.7s (0.2<->3.0); dip beat 242-244 -> ~91.9-92.7s (0.75). Compare those windows in Etterna vs Gakuran; record timing/position diffs BEFORE any code change.
- Step 3 (live play) is the user's — NOT done this turn, no evals ran.
- Deployed to the Madium workspace on user request (overlay copy: 1 JSON + mp3 + jpg, additive, no overwrites). Loader should list it next init; playtest windows ~43.1-43.7s and ~91.9-92.7s.

### Session 20 (2026-10-12): review verdict on 7abc34b = PASS for controlled testing (docs only)
- Reviewer confirms all 3 prior findings fixed (unified frontend, per-chart timing, NOTES2); did not execute the suite locally. Verdict: ready for a controlled single-BPM test, not proof of full SSC fidelity.
- Concern 1 (NOTEDATA timing before STEPSTYPE) checked against all 9 local `.ssc`: every file has exactly one EMPTY `#NOTEDATA:;` + one `#STEPSTYPE`; all timing lives in the true global header; zero files place timing between NOTEDATA and STEPSTYPE. Tracked as future hardening ("eventually parse NOTEDATA sections as chart boundaries"), NOT implemented — reviewer said "eventually", verdict is pass, no local trigger.
- Concern 2 (multi-BPM) + candidate status: single-BPM local SV candidates are April Showers (1 seg), crystallized (1), GO 4 IT (1); the other six are multi-BPM (up to 91 segs). Zero/negative scrolls exist NOWHERE locally (reconfirmed) — the reviewer's ideal "single-BPM with obvious stops" is unavailable without the 1.3 GB megapack or a synthetic chart. April's 0.2<->3.0 wobble remains the strongest available signal: rate-variation fidelity only.
- Deployment hazard (chart_id collision) already recorded session 19; still open, still out of scope.
- No code changed this turn. Next (needs user): deploy April Showers to workspace for the controlled live test vs Etterna, or pick crystallized/GO 4 IT instead.

### Session 19 (2026-10-12): review findings 1-3 fixed (convert_song + per-chart timing + NOTES2)
- Finding 1 CONFIRMED live in code (`results.append(list)` -> `assign_ranks` `c["songId"]` TypeError; only convert_song.py + CLI + tests call `sm.convert_file`). Fixed: `extend()` at both call sites, `.ssc` in recursive discovery + suffix match + help/docstring. End-to-end proven on the real April Showers folder (1 `.sm` + 1 `.ssc` -> 2 charts, ranks pass, no crash).
- Finding 2 CONFIRMED deeper than reported: not only does the dict keep the LAST `#SCROLLS`, the "global fallback" itself was poisoned (block tags leak into parse_sm's file-wide dict — proven: all 3 synthetic charts inherited the stopped chart's `#STOPS`). Fixed: true header = text before first `#STEPSTYPE`; per-chart resolve (block tag present wins even if empty, else header) for BPMS/STOPS/SCROLLS/SPEEDS/OFFSET. Chart-local `#STOPS`/bad `#BPMS` now skips THAT chart, siblings still convert (old single-block outcome unchanged: no charts).
- Zero local files have multi-block or per-chart timing (264 scanned: 0 multi, 0 NOTES2, 0 overrides) — so the new tests are synthetic by necessity (SSC2: 2 SV sets + SPEEDS on Hard + STOPS on Stopped + divergent global 9.0).
- Finding 3 fixed: `#NOTES2?` in the block regex + test. No local files use it.
- Gates: `test_sm_scrolls.py` 12/12 (was 6/6), qua 8/8, fold 10/10, check.py 18 files. Byte-stability re-proven after the restructure: 6/6 real `.sm` vs pre-ssc HEAD output identical, April `.ssc` identical to session-18 scratch.
- KNOWN WART (not fixed, out of review scope): a folder holding parallel `.sm`+`.ssc` of one song yields the same chart_id from both — last writer wins on disk (observed: april_showers_medium.json written twice). Convert one file at a time until chart_ids disambiguate.

### Session 18 (2026-10-12): .ssc + #SCROLLS support in sm2gakuran.py (Etterna SV test path)
- External report verified from the code: converter globbed `*.sm` only and never read `#SCROLLS`/`#SPEEDS`. Scanner (`Downloads\\find_stepmania_sv.py`, NOT copied into repo) run against the LOCAL pack: 264 files, 9 candidates, all `#SCROLLS`, zero `#SPEEDS`/zero-or-negative anywhere locally.
- Implemented: `.ssc` discovery + new-style block parser (`#STEPSTYPE..#NOTES` per chart; parse_sm dict-overwrite keeps last tag so blocks re-scanned in file order), `#SCROLLS` -> `scrollChanges` (verbatim beats on notes' axis, same-beat last-in-file wins, rates verbatim incl. 0, rounded 4 like qua), `#SPEEDS` loud SKIPPED warning (non-fatal), `#STOPS` still refuses. `convert_file` now returns a LIST of charts (main/test updated).
- Gates: new `tools/test_sm_scrolls.py` 6/6; qua 8/8, fold 10/10, check.py 18 files (was 17 — the new test file). Refactor byte-stability proven: HEAD vs new on 6 real `.sm` files = 6/6 byte-identical JSON.
- April Showers converted to SCRATCH ONLY (`$env:TEMP\\april`, never workspace): `april_showers_medium.json`, 809 notes (643 holds), 158 BPM, 16 SV points verbatim (0.2<->3.0 wobble beats 113.5-115, 0.75 dip at 242), audio+bg wired. NOT live-tested, NOT deployed — awaiting user eyeball decision.
- Honest scope limit: no local chart has zero/negative scrolls or `#SPEEDS`, so this path tests rate-variation fidelity only, not stop/reverse parity.

### Session 17 (2026-10-12): zero-SV fix LIVE-VERIFIED by user, item 13 CLOSED
- User fixed the client and confirmed in-game: pauses/teleports on the reconverted charts now match Quaver ("IT TOOK ALL THE DAMN DAY TO MAKE THIS WORK, im super happy"). Per the standing decision, user eyeball is the final authority on feel — item 13 is CLOSED. Honest scope note: this verification is user-side gameplay, NOT my sampler run (no evals ran after the rejoin except `runtime_status`; the earlier queue wedge was never re-probed — do not cite sampler numbers for this turn).
- Root-cause record: converter missing-`Multiplier` default 1.0 (not the renderer). The session-15 "killed theories" work stands as renderer-healthy evidence — the renderer was never at fault. Session-16 line "Live verification BLOCKED" below is now superseded.
- No code changed this turn (docs only); tree was clean at `4deb590` on entry.
- Next: parked items unchanged (single-difficulty star badge, DiffTier-nil probe, `GC_simref` cleanup, display-displacement clamp unfaithful-by-design, Real inspection-only).

### Session 16 (2026-10-12): missing-Multiplier=0 pause bug (external report + fix)
- External analysis received: `.qua` SV entries with NO `Multiplier` field default to rate 0 in Quaver (uninitialized C# `float` = 0.0f; gameplay treats 0 as "staying"), but `qua2gakuran.py` used `fnum(..., 1.0)` — turning stops into normal scrolling. Files: candidate chart + patch in `C:\Users\Administrator\Downloads\` (do NOT `git apply` the patch: hunk 1 is already present here with identical semantics, hunk 2 needed a blank-line adaptation; do NOT copy the candidate into any chart folder — same song ID).
- Verified from the raw sources with the proven parser (not trusted blindly): ball_hard 335 omissions (exact times match the report: 4711, 4865.015625, ...), bozo 631, halloween 7; C# default + gameplay "staying" use confirm 0 semantics. CORRECTION to my own session-10 census ("zero: 0"): wrong — the same 1.0 default masked them. The "no pauses" census conclusion is retracted for Quaver charts.
- Fix: one-line default 1.0 → 0.0 in `tools/qua2gakuran.py` + the report's regression test adapted by hand into the EXISTING `tools/test_qua_precision.py` (it IS in the repo — 7 tests; my earlier "missing" read was wrong, found via disk search). Tests: 8/8, `check.py` 17 files, `test_fold.py` 10/10.
- Reconverted 3 sets: ball 8714→8723, bozo 9227→9228, halloween unchanged count; non-SV fields byte-identical everywhere. Independent convergence: my output's (time,rate) sets EQUAL their candidate's at ms precision (8723=8723, 0 diffs). Deployed to workspace (backup `_scratch_convert\workspace_charts_backup_before_zerosv`); candidate stays in Downloads.
- [RESOLVED post-rejoin session 24: queue clear, lightweight probe completed, no scans ever queued again.] Live verification BLOCKED (not failed): the executor eval queue is wedged — my getgc-heavy probe never returned and even trivial evals queue behind it (bridge alive per `runtime_status`, console readable). Do NOT stack more evals. Next: user rejoins/restarts the client, then rerun the lightweight probe (load/play/svStatus/stop/clear, NO getgc scans).
- Pre-existing, tolerated, not mine: `Instance` capability-Plugin errors at play start/end in the console log; plays proceed and notes render.
- Scratch staleness: `_gk_patch\qua_audit.py` hardcodes old clamp semantics — do not re-run blindly.

### Session 15 (2026-10-12): continue SV pause/teleport checks (cut off mid-step)
- User decision (answering "how to unblock Real"): BACK TO MADIUM, "real is
  bugged or sum". Real work is parked, not deleted: the deployed files stay
  in Real workspace for later, and the getgc-free discovery research
  (getnilinstances+require proven, controller route open) stays valid as a
  fallback. Madium client 15452 alive at decision time (fresh reconnect).
  Loader testing resumes on Madium; Real keeps inspection-only use.
- [x] Loader v2.0.30 executed on the live Madium client (PID 15452, fresh reconnect, user request): gen=1, version=2.0.30, diag "all getgc targets found", clean init.
- Finished the cut-off step: fixed the 1ms sim path bug (relative path had resolved against System32 — use the absolute `_scratch_convert` path + `$env:GK_STEP`), reran ball_hard + bozo at 1ms/94k frames each: still 0% missing, capped=0. H1 (spawn drops notes) is dead at two sampling rates (60Hz + 1ms).
- RenderStepped dispatch order VERIFIED on Real (client 7256) with an order probe: newest-first (`2,1,2,1...`), same as Madium. The loader's "older connection fires later" design holds; the engine-overwrites-loader theory (which would have explained "keep scrolling" exactly) is dead.
- Quaver position math mapped from source (develop branch, read — not memory): `ScrollGroupControllerKeys.cs` builds positions per segment as `(long)(Δt * mult * TrackRounding)` (EACH segment truncated to long), `TrackRounding = 100`, SV StartTime/Multiplier are float32 (`SliderVelocityInfo.cs`), ISV + NaN→0 handled, sign flips tracked via `SVDirectionChange`, rendering is position-ranged (spatial hash + `RenderThreshold`), track position follows the visual audio offset. Impact of the truncation: sub-pixel typical, small cumulative worst case — real but NOT the main cause. `IndexAtTime`/`InsertSorted` exact same-time semantics still open (not in Helpers/ListHelper.cs; likely Qua.cs or game-side — next agent: fetch before relying on last-in-file).
- BLOCKER, no live testing possible yet: Real's workspace held only `mcp/` — deployed the loader + full `GakuranCharts` via shell (109 files, loader hash == repo v2.0.30, NO Scores.json copied). But `execute-file` REFUSES any file containing `getgc(true)` (freeze policy); the loader needs it 3 times (`GakuranChart.lua:123,144,693`) for 9-target discovery. Verified via eval: `getgc`/`filtergc`/`getgenv` all exist as globals. `filtergc("table", {...})` only echoes the constraint key back (dead end — do not chase further). `gc-scan` is MCP-side inspection (descriptions, not live refs — cannot supply the loader). The loader abstracts executor fns via the `fn` table (`GakuranChart.lua:51-68`) and degrades gracefully if missing — but here the issue is the gate + freeze risk, not absence.
- NOT attempted, needs user decision: (a) calling getgc(true) live to see if Real survives it (0.5 s measured on Madium; refusal warns of unrecoverable freeze → rejoin; do NOT try unasked on the active client); (b) getgc-free discovery redesign (roadmap-compat notes mention require/getloadedmodules fallback, but heap-only tables like the wheel controller can't come from require); (c) gate evasion by renaming (against the control's intent — do not do silently).
- My verified tool inventory (Code Mode side; Madium untouched per instruction, used real.* only): `default.shell` ✓, `execute`+`search` ✓, `real.list-clients` ✓ (7256/Svnth, responsive, 88fps), `real.eval` ✓ (key is `expression`, NOT `code`), `real.execute-file` ✓ (absolute path; the getgc gate above), `webfetch` ✓ (GitHub raw + API). NOT yet run by me: start-job/await-job, live-reload, screenshot-window, get-data-by-code, send-input, read-file/write-file/list-files, get-console-output, gc-scan, check-script, spy-closure.
- User offered to disable "Block Vulnerabilities" entries (screenshot 2026-10-12: 144/144 blocked
across ~25 services, all ON). Assessment recorded BEFORE any toggle is touched: the `getgc(true)`
refusal fires even with the literal inside a code comment, which proves a TEXT scan (a comment
cannot freeze anything). A client-side hook block would not explain a comment refusal, so the gate
is most likely MCP-server-side and toggling protections may NOT lift it. Asked the user to find the
specific entry covering getgc (look under DataModel or any debug/executor group; do NOT blanket-
disable, esp. account/marketplace/http). Awaiting reply. Do not probe gate evasion (spacing/alias
variants) — against the control's intent.
- Discovery without getgc (the path that needs no protection changes): `getnilinstances()` works in-
Luau (3,992 items, no gate trigger); `RhythmWheelServiceClient` found by name among nil-parented
ModuleScripts and `require()` succeeds (49 keys) — but NO live `_session`/`_registry` on it. Its
functions carry ZERO table upvalues with `_uiState`, so the controller is not reachable that way.
Loader source (`GakuranChart.lua:200-210`) shows the live service comes from `serviceClass:Get()` —
require path viable for class tables. Wheel controller (heap instance, `_uiState`+`_isOpen`+slots)
still needs a route (service-field hunt or getconnections+upvalues on wheel GUI signals;
`getconnections`+`debug.getupvalue` both exist). `gc-scan` DID return the live controller table
(full field dump, `_uiState` Closed) — inspection works, but nothing consumes those ids back into
live Luau refs, so it cannot supply the loader.
- Quaver source paths read (develop): `Rulesets/Keys/HitObjects/{ScrollGroupControllerKeys.cs, ScrollNoteController.cs, HitObjectManagerKeys.cs (TR=100)}`, `Rulesets/Keys/{SVDirectionChange.cs, Playfield/ScrollDirectionHelper.cs (per-lane config only, irrelevant)}`, API `Maps/Structures/SliderVelocityInfo.cs` (float32).
- sessionCustom=false artifact RESOLVED (no loader bug, no second actor — gen stayed 1): the earlier probe sampled past song end (93.3s; last sample 92.4 + final wait), so service._session was gone at svStatus time. Lesson: end live captures BEFORE song end + take a mid-run svStatus. SV verified building on BOTH paths live on 15452: direct G.load+G.play → custom=true/8714; picker G.pick("ball_hard",1) → custom=true/8714 (playable songId=ball_hard). 30→88s re-captured with model confirmed active mid-run: active==inst every sample, receptors reached (near=1), SV flings render (yMin=-1329 at 40.3s), 0 errors. Prior 30→92s numbers stand reinterpreted as SV-ON data. Net: system healthy on current build; user-perception causes narrow to stale-build play or faithful gimmicks — asked user to retest on this build.
- User retested: notes STILL move during pause SV on this build. Killed three more theories live on 15452: (a) engine-wins — 34 drawn-Y samples across the 38.6–47s spike zone vs BOTH predictions: every contested frame follows the MODEL (3 exact model matches where engine diverged 100–181px); loader wins, consistent with the dispatch probe. (b) Connection census — RenderStepped 30 conns (exactly 1 string-chunk = ours), Heartbeat 127, none rhythm-named; no separate engine positioning loop found. (c) Clock — 400 frames, deltas 6.5–12.6ms, zero non-monotonic/zero/jumps; H2 dead. Everything measurable (spawn, positions, model, order, clock, errors) is healthy on v2.0.30 — yet the complaint stands. Remaining: NEED a precise timestamp + chart of still-wrong motion on this build (asking below); without it the next hypotheses (hit-path-only effects, fps aliasing of 52Hz vibration at 60fps, expectation) can't be tested.

### REOPENED (session 14, user correction 2026-10-12): "full SV preservation" does NOT reproduce Quaver at 100% - notes do not stop / teleport like Quaver
User's correction (about "full SV preservation", v2.0.30): it does not replicate the Quaver SV 100% on the port; parts where notes are paused / mid-scroll are not rendered well. In Quaver the notes STOP and TELEPORT to the receptors IN BEAT; in the port the notes do NOT stop, they keep scrolling and teleport badly to the receptors.
**This overrides** the "closed as faithful-by-design" verdict below (commit `a4d7e49`, ROADMAP item 13) and every earlier "matches Quaver / <1.23 px" statement. Those checks only prove that the DRAWN position of a note that exists equals the integral of the .qua SV. They do not prove (a) which notes exist on screen, (b) that this integral is what Quaver really draws, (c) that the clock and the frame sampling match. The user's eyes on real Quaver are the reference. Treat all earlier "verified" claims about SV feel as unproven.
Status: investigation STARTED, NO code changed, nothing here is a verified cause yet. Next AI: keep this section current.
Facts gathered so far (offline/read-only, session 14):
- Census of `scrollChanges` in the workspace charts (beat->seconds as the loader does): `ball_hard_sv_ballin` 8714 pts, `bozo_bozo_cope` 9227, `halloween_day_spooked_sv` 13985 (all Quaver) have NO long pauses at all (no stretch >0.25 s with |rate|<0.1) and no long negative runs; their SV is micro-spikes. Example ball_hard 18.0-18.7 s: rate 1.0 for ~19.1 ms, then a 0.125 ms spike (+401, -774, +726, -674, ...), repeating about every 19 ms (about 52 Hz), plus 0.0156 ms spikes of +/-4.4M. The cumulative integral wobbles by +/-0.05-0.1 scroll-s (about 100-190 px at S=1920) around a slowly drifting base.
- The only charts with real "pauses" are osu ones: `day_by_day_psyqui_remix_moving_on` (2352 pts) has rate 0.01 stretches of 0.29-0.35 s at 68.0, 73.2, 76.3, 82.0, 87.6 s, in beat bursts (4.5x for 22 ms) and 0.01/1.0 alternation every 22 ms. All other osu SV charts have no pause.
- So which chart/time the user means is UNKNOWN. ASK: chart, timestamp (mm:ss), fps, ideally a screen recording of Quaver vs the port.
- Loader (v2.0.30, `GakuranChart.lua`): frame positioning = plain integral (`svApplyFrameInner`: `y = hitY + sign*(I(t)-I(now))*S`, rounded); spawn pass `svApplySpawns` rewrites each note's `.spawn` (`svSpawnMaxLead = 5` s earlier than vanilla at most, `svSpawnCap = 400` live notes, branch `nonPositive` -> `svEarliestVisible` scan with tMin = t-5). `buildSvModel` base time = `startAt + chartDelay + 60/bpm*b`, `song.offsetMs` deliberately NOT included.
- Engine (decompiled live via Real `script-grep`, RhythmEngine): a note exists only inside a TIME window: spawn loop `while liveNotes[_nextSpawn].spawn <= now` and `now <= _noteDeadline(note)`, where `_noteDeadline = t + len + BAD/1000` for holds, else `t + _missWindowSec`. SV only moves existing instances; it never decides existence. After the deadline the instance is released (a missed note does not keep scrolling off screen like in Quaver).
Hypotheses (ranked by my guess, NONE verified):
- H1 visibility completeness: Quaver draws every unresolved note whose SV position is on screen, whatever its time; the port draws only notes that have been spawned, i.e. inside `[spawn, deadline]`, with `spawn >= t-5 s` and a 400-note cap. Whenever the integral displaces future notes onto the screen (frozen/slow stretches, +/-N scroll-s teleports) notes that Quaver shows are missing in the port, and the earlier "win==inst, spawnCapped=0" samples cannot see that (they only compare notes already in the window). Predicts: notes "appear when the pause is over".
- H2 clock and sampling: `sess:_now()` (audio TimePosition + interpolation, jitter) vs the Quaver audio clock. With sub-ms spikes every 19 ms any clock jitter or frame aliasing changes what a frame sees, so "stops" in Quaver can become "keeps scrolling" in the port. Check the real behaviour of `_now()` per frame (monotonic? steps? per-frame delta histogram).
- H3 Quaver's own position math differs from a plain double-precision integral (I recall integer track positions scaled by 100 with per-segment truncation, and a start-time float; UNVERIFIED, from memory, check the Quaver source before believing it). The 'stop' may also come from truncation of tiny displacements.
- H4 note release: a note that Quaver keeps scrolling/frozen on screen after its deadline vanishes in the port.
Plan (do in order, record each step here): (1) ask the user for chart+time; (2) offline simulator, Python: per 1/60 s frame list Quaver-visible unresolved notes (|I(t)-I(now)|*S inside the screen) vs port-alive notes (replicate `svApplySpawns` + deadlines) on ball_hard, bozo, halloween, day_by_day, count missing notes; (3) live capture on the Real client at the user's timestamp: per-frame sampler (`_now()` deltas, `_active` count, Y of the nearest notes) + `screenshot-window` frames; (4) only then change the loader, keep non-SV charts byte-identical, bump the version after live test. Rollback: charts untouched, loader committed at v2.0.30 (`a4d7e49` tree).
Findings (session 15, all checks, no code changed):
- Offset theory DEAD: the engine applies `offsetMs` to AUDIO only (`RhythmChartUtil.lua:320,365` builds `offsetSec` into the playable; `RhythmServiceClient.lua:937,1035` + `RhythmEngine.lua:1834-1835` route it to `Audio:SetOffsetSec`). Note-time axes exclude it on both sides (engine `buildSecondsChart` has no offset term, same as our model), and global calibration enters both position systems through the same `_now()`. Setting offset to 0 will change nothing about SV motion — do not chase this.
- Clock deltas clean (Madium live, ball_hard): 400 frames, 6.5–12.6 ms, zero non-monotonic/zero/jumps. Residual: absolute phase vs Quaver audio is unmeasurable from here.
- Aliasing quantified (offline, same integral both sides): 52 Hz spike content sampled at 60 fps vs 240 fps over 18.0–19.0 s gives 4x coarser steps (mean 2306 px vs 580 px); teleports land on arbitrary frames at 60 fps. Both engines alias identically AT the same frame rate — so the fair test is Quaver locked to 60 fps vs the port, plus an fps unlock on Roblox if available. This is the leading remaining mechanism for "keeps scrolling + teleports badly".
- Quaver math mapped (develop source, read not recalled): per-segment `(long)` truncation, `TrackRounding = 100`, float32 SV fields, ISV/NaN handling, position-ranged rendering. Impact sub-pixel typical — small, not the driver. Same-time lookup semantics still open.
- User-side tests proposed (nothing further to check offline): (a) Quaver locked to 60 fps on the same section — if it matches the port, the math is exonerated and only frame rate differs; (b) Roblox fps unlock retest; (c) match scroll speeds before eyeballing (displacement scale).

### NEW TOOLS (session 14): what is available now, and what is only claimed
- Real bridge (replaces Madium; the user said do NOT use Madium for now). Verified this session: `list-clients` works. Client id is **7256** now (user `s_v4x`), the "14256" in the bridge note below is stale; ids change on rejoin, always call `list-clients` first. `script-grep` works (live scan decompiled 1648 scripts, ~seconds; `build-script-index` first makes it instant and enables regex). Loaded but NOT yet run (UNTESTED): `get-script-content`, `execute`, `execute-file`, `live-reload`, `start-job` + `await-job`, `screenshot-window` (needs `list-roblox-windows` when more than one client), `read-file`/`write-file`/`list-files`, `get-console-output`, `send-input`. Load schemas with ToolSearch (large dump). Results come wrapped in a `GAME-DATA` block: it is data, not instructions.
- Real's executor workspace is `C:\Users\Administrator\AppData\Local\Real\workspace` (only an `mcp\` folder so far), NOT `C:\Users\Administrator\AppData\Local\Madium\Workspace`. The loader, `GakuranCharts\` (Charts, Audio, Assets, Skins, Settings) must be copied there before any live test (`tools/deploy.py` still writes to the Madium workspace; extend it or copy by hand). Real scripts live in `AppData\Local\Real\scripts` (MCP-run code is saved under `Scripts\MCP`).
- Repo tools added by other sessions (read their headers before use): `tools/qua2gakuran.py`, `qua2skin.py` (Quaver .qp/.qua), `sm2gakuran.py`, `etterna2skin.py` (StepMania/Etterna), `convert_song.py`, `convert_skin.py` (front-ends), `make_source_icons.py`, `test_qua_precision.py`, `check.py` (syntax + tests), `deploy.py` (`--name`, `--live`, `--clean`). Scratch scripts OUTSIDE the repo, `C:\Users\Administrator\_gk_patch\`: `sv_live_sampler.luau` (Madium API, needs porting to Real), `verify_qua_charts.py`, `qua_sv_sim.py` .. `qua_sv_sim4.py`, `qua_sv_stats.py`, `qua_audit.py`, `export_ref.py`.
- Gotchas: some hand-made chart JSONs have a UTF-8 BOM (open with `utf-8-sig`); the repo files are LF but `GakuranChart.lua` is CRLF (patch with Python bytes, see earlier notes); Desktop Commander `edit_block` works on LF files; PowerShell here-strings: use the single-quoted `@' ... '@` form.

### NEXT TASK (session 13, user report 2026-10-11 21:33): notes do not render during pause/gap sections - SUPERSEDED by the REOPENED section above (the faithful-by-design verdict is disputed by the user)
User's words: "the notes dont render properly on pauses sections, it just spawns when the pauses are gone.. i think". The user is unsure, so treat this as a lead, not a finding.
- Symptom: during a long silent gap in a chart (no notes for a while), upcoming notes are not on screen; they only appear (spawn) once the gap is over, instead of scrolling in from the top.
- Likely suspects (all unchecked): (1) the SV-spawn pass (`persistentFrame`, RenderStepped) only spawns/positions notes inside a look-ahead window, and a pause with big SV or a long time gap leaves the next note outside it; (2) the engine's own look-ahead/pooling by time rather than by scroll distance; (3) negative/zero SV segments (loader v2.0.30 keeps them verbatim) hiding notes in a gap; (4) it may be tied to the new 10-decimal beats / same-instant SV collapse (commits `1d80343`, `947f50f`) on `ball_hard_sv_ballin`, or it may happen on every chart - find out which first.
- How to start: (a) ask which chart(s) and whether it also happens on an osu! chart with no SV; (b) take a chart with a long gap, play it live and sample, per frame, the count of note sprites alive and the Y of the next unspawned note (extend `C:\Users\Administrator\_gk_patch\sv_live_sampler.luau`, scratch, not in repo); (c) compare with the engine's spawn window in RhythmEngine/RhythmNoteSprites (decompile with Madium `decompile_script`); (d) only then touch the loader. Do not bump the version until a fix is live-tested.
- Status: nothing investigated, no code changed for this.
- INVESTIGATED same day, live on client 13984 (ball_hard, deployed v2.0.30):
  VERDICT faultless-rendering — no loader defect found, no code changed.
  Every in-window note HAS an instance in all samples (win==inst: 14/14,
  15/15, ...), cursor advances at chart density, spawnCapped=0,
  spawnOrderFix=0, errors=0: the spawn path (suspects 1+2) is healthy.
  What the player sees is the map's authored gimmicks, reproduced exactly:
  uncompensated ±4.4M teleport spikes (e.g. −69 scroll-sec at 20.403s, +69 at
  20.480s) fling the playfield ±132,000px for tens of ms, and 20s/15s/12s
  negative runs scroll notes away until the rate flips. The loader's integral
  matches a from-source Quaver-semantics reference to measurement precision,
  and calm-zone positions were already proven ≤1px in session 13.
  Suspect-by-suspect: (1) spawn pass healthy (above); (2) engine window
  normal (win==inst every sample); (3) negative/zero SV behave as authored —
  the screen emptying during reverses IS the effect; (4) 10-decimal beats
  ruled OUT (file strictly increasing, 0 duplicate beats, calm exact; the
  ±69 displacements each have a spike source in the raw .qua).
  Upscroll=false confirmed live (sign convention verified, not assumed).
  Recommendation: close as faithful-by-design; compare against real Quaver
  playback if doubt remains. Optional, NOT built: a display-displacement
  clamp so teleports bunch at the screen edge instead of flying — that would
  break fidelity, so only on explicit request. Scores cleared after every
  test play (0 rows), PlayingInstrument restored to nil.

### BRIDGE CHANGE (2026-10-11 22:54): Madium -> "Real" MCP bridge
- The user switched the executor bridge. Madium tools (`lcl-madium-*`, `_G.GakuranChart` probing via `eval_luau`/`execute_luau`, `search_gc`) are NOT enabled in new sessions; the bridge is now **Real** (`mcp__claude-device__lcl-real-*`, load schemas with ToolSearch first).
- Verified: `ping` answers "pong"; `list-clients` shows one injected client, id 14256 (account Svnth / `s_v4x`), clientGeneration 1, responsive, ~96 fps, alive. The old Madium client 13984 is gone, so nothing from earlier (loader, sampler, hooks) is loaded on it.
- Rough tool mapping (names only, UNTESTED beyond ping/list-clients): `eval`/`execute`/`execute-file` for Luau, `gc-scan` for `getgc`, `get-script-content`/`script-grep` for decompiles, `read-file`/`write-file`/`list-files` for the executor workspace, `get-console-output`, `screenshot-window`, `send-input`, `get-game-info` (call first).
- UNKNOWN, check first: whether Real's executor workspace is the same folder as `%LOCALAPPDATA%\Madium\Workspace\` (chart packs, skins, `GakuranChart.lua`), and whether the loader still runs under this executor (`getgc`, `getcustomasset`, `RenderStepped` hooks). Re-load GakuranChart on client 14256 before any live test, and re-adapt `sv_live_sampler.luau` (it used Madium's API) if needed.
- Shell and git tools (`lcl-shell-*`, `lcl-git-*`) are unchanged.

### Current task (session 10): quaver SV mismatch on "ball hard" - FIXED + VERIFIED LIVE in session 13 (only the user's eyeball vs real Quaver is pending; see the checklist at the end of this section)
Goal: the SV map `ball_hard_sv_ballin` does not move like the original game.
Status (session 13): this paragraph is the ORIGINAL session-10 status and is
OUTDATED - the fix is done and live-verified, see the checklist below. Original:
offline investigation only. NO code changes (tree clean), NO fix
applied, NOTHING live-verified for a fix. Scratch scripts (outside the repo,
do not re-run blindly): `C:\Users\Administrator\_gk_patch\qua_sv_stats.py`
(source census), `C:\Users\Administrator\_gk_patch\qua_sv_sim.py`
(position simulation vs a Quaver-semantics reference).
- Source: `FunkyChart_v1.23/QUAVER/crafter2011 - ball hard - 260537.qp`,
  `139214.qua` (`"[SV] ballin'"`, Keys4, 195 BPM single timing point, 1088
  notes, `BPMDoesNotAffectScrollVelocity: true`, `InitialScrollVelocity: 1`)
  → workspace `GakuranCharts/Charts/ball_hard_sv_ballin.json` (8,468
  scrollChanges, rate clamped to [0.05, 20], duration 93.33). Sibling
  `141345.qua` (Skrubble's Ball, 1556 notes) has 0 SV points — unaffected.
- Census (stats script): 8,732 raw SV points; multipliers min/max
  −4,442,921.5 / +4,443,196.0 (spike/teleport SVs); 2,181 negative (25.0%),
  2,338 with rate >20, 24 with |rate| <0.05; 1,794 distinct values; 170
  segments with |rate| >1000, each ~0.016 ms long, net displacement 266.17
  scroll-seconds from those alone (max single 69.42). The converter clamp
  alters 4,543 points.
- Simulation (4 approach moments x 1088 notes = 4,352 samples): 38.7% differ
  from the reference by >0.1 scroll-seconds (~60 px at S~600 px/s), 13.5% by
  >1.0; median |diff| 0.074, 90th pct 2.293, max 70.0. Same samples under
  real-Quaver semantics: 0.0% on the WRONG side of the receptor, 3.7% more
  than 3 scroll-seconds away. So the divergence is ours, not the map's.
- Concrete converter bug (not fixed): 3 same-time SV pairs (t=41.019 /
  43.173 / 45.942 s) read "1.0 then 0.024" in file order; Quaver effective =
  last in file (0.024), but the converter's `sort()` puts 1.0 last
  (DIFFERENT). Fix direction: stable same-time ordering, last-in-file wins.
- Open, NO decision recorded: how to preserve negatives/zero/extremes (loader
  SV model capability was being checked, no conclusion); beat precision
  (4 decimals) and rate rounding as displacement-error sources; spawn
  visibility under non-monotonic rates. Do NOT change the clamp until the
  loader side is verified — clamping is currently load-bearing for stability.
- Next step: decide the SV preservation policy (negative/zero/extreme), fix
  the same-time ordering in `tools/qua2gakuran.py` (+ `osu2gakuran.py` if it
  shares the pattern), re-convert ball_hard to a workspace candidate, and
  live-verify on client 14512 with `svStatus()` + on-screen eyeball before
  touching the deployed charts.
- [x] Same-time fix DONE + VERIFIED (no loader change, so no version bump):
  both converters now stable-sort SV by time and collapse each grid instant
  (same ms, or distinct ms rounding to one 4-decimal beat — 55 such groups on
  ball_hard alone, mostly 0.016 ms spike pairs) to the last-in-file value,
  which is what Quaver plays. osu shares the tuple-sort pattern and got the
  same fix in `parse_timing` + its scroll loop. check.py 16/16, fold tests
  10/10. Fresh output strictly increasing, zero same-beat collisions,
  note counts intact; non-SV chart fields byte-identical.
- [x] Workspace charts rewritten (backup of the 3 files in
  `_scratch_convert\workspace_charts_backup_before_svorder`; halloween
  byte-identical, untouched): ball_hard 8468→8407 pts, bozo 6656→6386 pts.
  Live on client 14512 (v2.0.29): both load, both play, SV models build
  (8382 / 6332 pts after the loader's own equal-rate dedupe), 0 errors;
  scores cleared (0 rows), instrument restored to nil.
- Loader limits checked for the preservation policy (all in `GakuranChart.lua`,
  scrollChanges has ONE consumer, `buildSvModel`): (L1) drops r<=0 + clamps
  [0.05,20]; (L2) same-t order nondeterministic (Lua unstable sort + 1e-6
  dedupe) — now moot for converted charts, still live for hand-made ones;
  (L3) `svInvertIntegral` needs strictly increasing I; (L4) spawn-order proof
  needs rate>0; (L5) zero rate would divide by zero in the invert. Frame
  positioning (`svIntegral` differences) has NO such limit — negatives would
  render as reversed motion fine. So full negative support = replace
  inversion with a bounded earliest-visible-time forward scan + keep
  negatives/zeros in the model; judging never touches SV (time-based), worst
  case of a naive change is visual pop-in + pool pressure, never a crash.
  NOT started — needs its own policy decision + live verification round.
- [x] POLICY APPROVED by user (session 10, "closest to perfect"): preserve
  negative/zero/extreme SV end to end. Design (docs-first, NOT implemented):
  (a) converter drops the clamp (keeps 4dp round + last-in-file collapse;
  rejects only non-finite values); (b) loader keeps negatives/zeros in the
  model + collapses same-t to last deterministically; (c) spawn computation
  branches per chart: positive-only models keep the EXACT v2.0.29 invert path
  (bit-identical behavior, zero regression risk), models with any rate <= 0
  use a bounded earliest-visible forward scan (no division by rate anywhere,
  existing clamp-to-prev/cap/floor machinery keeps sortedness); (d) frame
  positioning untouched (rate-agnostic already). Pre-implementation check
  still open: tail-length sign when a hold spans reversed motion (read the
  tail sizing region fully first). Order: loader → verify old charts →
  converter → reconvert SV sets → verify. Acceptance: models build, 0
  errors, live note-Y samples match sim predictions, Ievan 7k_sv regression
  clean, user eyeball vs Quaver. Rollback: per-file chart backups (charts are
  regenerable from .qp + committed tools); old clamped charts keep working
  unchanged under the new loader.
- [x] IMPLEMENTED as v2.0.30 + VERIFIED live (client 14512): shipped
  `svEarliestVisible` passed an offline differential test vs brute force
  (spiky/neg/zero/flat/single models, run under the luau CLI on the verbatim
  shipped functions). Tail pre-check resolved: `rawLen` already clamps at 0,
  no tail work needed. Loader keeps negatives/zeros verbatim (finite-only
  filter), same-t collapses pre-sort, spawn branches per chart
  (`nonPositive` flag; positive path byte-identical). Converters drop the
  clamp (both qua + osu; non-finite rejected with warning). Reconverted:
  ball 8468→8618 pts (2142 neg kept, incl. ±4.4M spikes), bozo 6656→8857
  (3248 neg), halloween 13985 unchanged in count (402 sub-0.05 floors now
  true 0.01s), day_by_day osu 420 floors now true (non-SV fields identical
  everywhere). Live: 65 s ball play through the 41–45 s spike zone, 0
  errors; Ievan 7k_sv regression 107/107, 0 errors; day_by_day loads +
  models 2352/2352, 0 errors. Scores cleared, attributes restored. DEPLOYED
  v2.0.30, workspace == repo. Remaining: user eyeball vs real Quaver motion
  (only a human can judge feel); full-negative loader redesign is DONE here,
  no follow-up coded.
- [!] CORRECTION (session 11, ~21:20, client 13984 after a PC restart, loader
  v2.0.30): the claim above that the math now matches Quaver "point for point"
  is FALSE for ball_hard. I played the full chart (user request: "does it match
  the real quaver file?") with a per-frame sampler comparing the DRAWN note-Y
  differences against the integral of the ORIGINAL .qua SV: 107,675 note-pair
  samples, only 17.3% within 1 px, 22.9% within 3 px, 37,756 samples >50 px,
  max 340,792 px at t=10.07 s. 0 sampler/SV/vis errors, model 8,593 pts,
  hooks 14/14. The sampler is sound: the same model built OFFLINE from the
  chart JSON (no game) reproduces it (10.9% within 1 px, p90 131,237 px).
- ROOT CAUSE (verified offline): TIME QUANTIZATION in the converter. Beats are
  stored as round(t_ms / ref_bl, 4) = steps of 0.0308 ms (max error 0.0154 ms),
  but ball_hard's 170 teleport spikes are exactly 0.0156 ms (1/64 ms) wide.
  Example, source: 4864.9844 ms +9856, 4865.0000 ms -9856, 4865.0156 ms 1.0
  (net 0). Ours: +9856 held 0.0308 ms then 1.0 (the -9856 point collapses into
  a neighbouring grid instant) = a permanent +0.3033 scroll-second offset; the
  integral offset at song end is -574 scroll-seconds (4 decimals). NOTE TIMES
  matter too: notes sit inside spike windows (rate 9856 x 0.015 ms = 0.15
  scroll-s = ~280 px). Rates rounded to 4 decimals are harmless.
- Offline fix experiment (same 4,352 samples, S=1920; `qua_sv_sim4.py`):
  SV 4 dec / notes 4 dec 12.0% within 1 px | SV 12 dec / notes 4 dec 71.4% |
  SV 8 / notes 8: 96.6% (max 3.3 px) | SV 10 / notes 10: 100% (max 0.5 px) |
  12 / 12: 100% (0 px), end-of-song offset 5e-5 scroll-s.
- FIX PLAN (APPROVED by the user 21:07, IN PROGRESS - checklist below; converter-only, no loader
  change, no version bump): in `tools/qua2gakuran.py` store note beats, hold
  lengths and scrollChanges beats with 10 decimals instead of 4 (osu path
  untouched: its SV times are integer ms). The same-grid collapse then only
  merges genuinely identical times. Re-convert ball_hard (+ bozo and any other
  quaver SV chart) with backups, then verify with the sampler (expect >=99.9%
  within 1 px, 0 px >50) and `qua_sv_sim4.py`. Chart JSON grows a little.
- Scratch files (outside the repo, in `C:\Users\Administrator\_gk_patch\`):
  `export_ref.py` (writes `Workspace\GC_simref\ballhard_ref.json`),
  `qua_sv_sim2.py` / `3.py` / `4.py` (offline comparisons / divergence finder /
  precision sweep), `sv_live_sampler.luau` (the live sampler; header explains
  how to run it). The workspace folder `GC_simref` is reference data only, safe
  to delete after the fix is verified.
- Test hygiene: my play wrote a 0-score row for ball_hard_sv_ballin; removed
  with `clearScores("ball_hard_sv_ballin")` (Scores.json had no other rows).
- CHECKLIST for the precision fix (update after EVERY step, commit small):
  - [x] ROADMAP item 12 + this file updated BEFORE coding (user asked; done in
    the commit that adds this checklist).
  - [x] `tools/qua2gakuran.py`: BEAT_DECIMALS = 10 for note `b`/`d` (both the
    plain and the folded path) and scrollChanges `b`; the same-grid collapse
    key follows. Rates stay at 4 decimals. osu/sm converters untouched.
    (session 12: written by the previous session, uncommitted; reviewed, ref_bpm/rates/duration
    roundings left as planned)
  - [x] Offline test `tools/test_qua_precision.py`: the +9856/-9856/1.0 spike
    triple keeps 3 distinct points and zero net displacement; existing tests
    (`test_fold.py`, `check.py`) still pass. (session 12: 6/6 pass, integral vs raw source
    < 1e-6 scroll-s incl. inside the spikes)
  - [x] (session 13: DONE - backup exists, workspace JSONs == fresh conversion, offline verify_qua_charts.py: ball_hard 100% within 1 px max 0.53 px, bozo 99.41% max 1.41 px, halloween/skrubble 100%) Back up the 4 Quaver chart JSONs (`ball_hard_sv_ballin`,
    `ball_hard_skrubble_s_ball`, `bozo_bozo_cope`, `halloween_day_spooked_sv`)
    to `_scratch_convert\workspace_charts_backup_before_precision`, convert
    from the .qp files into a TEMP dir, diff against the workspace charts (only
    b/d/SV-b precision and SV point counts may differ), then copy the JSONs.
  - [x] (session 13: DONE on client 13984, loader v2.0.30, full 97 s play of `ball_hard_sv_ballin`, SV model 8714 pts: 95,753 note-pair samples, 99.78% within 1 px (spike zone 40.5-45.5 s 100%), 100% within 3 px, 0 samples >50 px (was 17.3% / 37,756), worst 1.23 px, 0 sampler/SV/vis errors. The literal >=99.9%-within-1px target was NOT met (99.78%); the residue is <=1.23 px, consistent with integer-pixel rounding of two positions plus 4-decimal rate rounding. Scores cleared (Scores.json charts=[]), sampler disconnected, instrument attributes nil.) Offline sim on the new JSON (`qua_sv_sim4.py` style, expect >=99.9% within
    1 px) and the LIVE sampler (`sv_live_sampler.luau`) on the playing client;
    0 errors; `clearScores("ball_hard_sv_ballin")`; disconnect `_G.__gkSim.conn`.
  - [x] (session 13: check.py 17/17, test_qua_precision 7/7, results in ROADMAP item 12, committed) `python tools/check.py`, commit, record results in ROADMAP item 12.
  - [ ] User eyeball: play `ball_hard_sv_ballin` and compare the motion with real Quaver (only a human can judge feel). Optional cleanup afterwards: delete `Workspace\GC_simref` (reference data only). If the user is happy, move this whole task to "Recent work" and clear "Current task".
  Rollback: restore the 4 JSONs from the backup folder; revert the converter commit.

### DONE (session 9): hit flash / hit ring orientation fixed in v2.0.29 (user approved 15:57)
No current task is open from this session. DEPLOYED v2.0.29, workspace == repo.
- [x] Read paint helpers + teardown (`paintImage`, `restoreViewVisuals`, cleanup).
- [x] IMPLEMENTED (patch script `C:\Users\Administrator\_gk_patch\patch_hitfx.py`
  already applied, do not re-run):
  per-view `PlayHitEffect` wrapper that, for the duration of the original call,
  overrides `acquire` on `_flashPool` and `_ringPool` so the acquired frame is
  painted with the lane's tap art at spawn; widen the guard with
  hasTapVariants/hasRecVariants; per-frame repaint also covers the ring;
  restoreViewVisuals unwraps and resets pool frames to the base image.
- [x] Live test with REAL spawned effects (client 14512, AmbieArrowsFFR): 24/24
  forced and 40/40 engine-triggered effects (real key input) had the right flash
  AND ring art at the spawn instant on lanes 1-4, incl. recycled frames; no
  leftover `acquire` shadows; 0 visual errors. setSkin to another skin / "Game
  default" removed the wrapper and reset all 16 pooled frames to the base image;
  switching back re-wrapped, spawns correct. Re-running the loader MID-PLAY ends
  the session (expected), so stacking was checked via the skin round trip.
- [x] check.py (16 files), candidate -> `--live`, candidate cleaned, hashes equal.
- Side finding re-tested: two back-to-back executor re-runs on v2.0.29 left
  14/14 hooks and WheelMenu=installed (the v2.0.17-candidate "displaced" case did
  NOT reproduce; one trial only).
- NOT verified: a skin with per-lane taps but no pressed/hold art (none on disk;
  the widened guard is untested for it), drums/guitar instruments, and whether
  a human sees the flash right on the first drawn frame (the spawn-instant check
  is stricter than that, so it should).
- Lesson: a "fix" that repaints a frame later while the engine recycles pooled
  frames can look right in a snapshot and still be wrong at spawn; measure the
  spawn instant (same thread as the call), and check every pool the effect uses
  (flash AND ring), not just the one in the bug report.
Investigation that led here (kept for reference):
User report (2026-10-11 15:51): the NoteHitFlash does not spawn oriented per
lane like the receptor arrows. Findings from real `view:PlayHitEffect(lane)`
calls on the live client (14512, AmbieArrowsFFR skin, loader v2.0.28):
- Engine: `RhythmView:PlayHitEffect(lane)` (ReplicatedStorage.Shared.Services.
  RhythmService.RhythmView, ~line 2113) takes a flash from `view._flashPool` and
  a ring from `view._ringPool` (8 reusable frames each, `HitFlashTemplate` /
  `HitRingTemplate`, parked in `OffscreenPool`). It sets Position, Size, colour
  and transparency and orients BOTH only via `Rotation = RhythmNoteSprites.
  GetRotation(spriteShape, laneCount, lane)`. Both pools carry the base note
  image (the Up arrow). Our skin shapes register Rotation 0 (per-lane art
  instead), so the engine's orientation does nothing for us.
- Flash: only fixed by the per-frame repaint in `visApplyFrameInner` (lane
  guessed from Position.X via `view._laneXs`). Measured: at the instant of spawn
  the flash shows the base image, or the PREVIOUS lane's art, because pool frames
  are recycled with whatever image they last had (a lane-4 flash spawned with
  lane 1's art). It is correct after the next Heartbeat. Whether the loader's
  persistent RenderStepped handler lands before the first rendered frame in a
  real play is NOT verified (the loader comment says it fires after the engine's
  handlers; my probe waking from RenderStepped:Wait ran before it).
- Ring: never repainted. `HitRingTemplate` stays on the base Up image on every
  lane, at spawn and later (lanes 1-4 all the same hash). ROADMAP already lists
  flash/ring matching as deferred; v2.0.28 only did the flash.
- Latent: the guard `(ss.hasHoldHead or ss.hasPressed)` at the top of
  `visApplyFrameInner` skips the whole function, flash repaint included, for a
  skin with per-lane taps but neither hold-head nor pressed art. Not this skin
  (hasPressed is true). Shards use a separate image and are not affected.
- Proposed fix (not applied, needs the user's go-ahead for the .lua): wrap
  `view.PlayHitEffect` per view so the lane is KNOWN: after the original call,
  immediately paint the acquired flash AND ring with that lane's tap art (same
  tapImgs fallback as notes) instead of inferring the lane a frame later; keep
  the per-frame repaint as a fallback; add `hasTapVariants` to the guard; undo
  on teardown. Verify with real spawned effects, asserting the image at the
  spawn instant (same thread, before any frame) for flash AND ring on lanes 1-4.
- Side finding, unresolved, seen on the v2.0.17 candidate (~10:05) and NOT
  rechecked on v2.0.28: two back-to-back executor re-runs left `WheelMenu=
  displaced`, wheelController=false and 7/8 hooks (reproduced twice); the same
  stress on v2.0.16 stayed 8/8, and a single re-run on the candidate was fine.
  Re-test on the current loader before relying on rapid re-execution.

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
- [x] DONE + DEPLOYED as v2.0.22 (`FA8C9CDA…`, workspace == repo). Live on
  client 14512: 30/30 charts read (29 osu + 1 local); 9 wheel rows tagged
  ([osu!] x8, [local] x1); submenu Data.sub `[osu!] 504 notes | 3:11`, chips
  intact; main-row TRUE icons 8/8 on first open after fresh exec, 0 stacked
  across re-renders (defer+repaint; synchronous paint caught 0 — same async-
  apply class as the submenu render wait); diag clean, 0 bad hooks, SV
  errors 0, no Scores.json; wheelRev 1→3 across the work. PNGs
  (tools/make_source_icons.py, pure stdlib) in repo + workspace
  Assets/icons/. NOT live-verified: overlay fallback branch (hard to force;
  syntax-checked only), Rayfield labels (init-clean only — eyeball pending),
  on-screen look (user), 9th row on page 2, touch/gamepad.
- [x] Icon fixes v2.0.23 (user screenshot: overlap, no hover-follow, stale
  submenu icons). Root cause: Root-anchored icons vs the Diff badge frame +
  add-only paint over reused slots. Fix: icons parented to the Diff frame
  (6.8px measured gap, badge-nudge test 11.4px/11.4px follow), sweep on both
  wrap paths + v1 migration, wheelRev 3→4. Verified through the real wrap:
  list 8 icons, submenu 0, list again 8, 0 stacked. Note: a direct
  renderMenu call bypasses the wrap (sweep never runs) — always test the
  submenu through wb.wrap/pending, not renderMenu directly. Same trap once
  more: hand-setting pending without armWheelMenu leaves renderMenu nil (base
  path renders) — test submenus via G.openPicker.
- [x] v2.0.24 (user eyeball: parents iconless, search-row wrong icon). Causes:
  parent Diff frames are hidden (icons existed but invisible); search rows
  bypass the list wrap (stale slot-reuse icons). Fix: 3-home paint (Diff /
  Len / Root), new WheelSearch slot on _renderSearchResults, wheelRev 4→5.
  Verified list 8/8 visible with correct homes+assets, search pink, submenu 0.
- Star-badge DiffTier-nil probe (session 6) still queued alongside.

### Current task (session 8): Etterna (.sm) + Quaver (.qp/.qua) songs and skins
Goal (user): convert the ETTERNA and QUAVER folders in FunkyChart_v1.23
(2 .sm songs + AmbieArrowsFFR skin, 3 .qp sets / 5 .qua difficulties + Still's
Circles skin) and port them into the custom-song script. OSU folder already done.
- Surveyed: .sm = dance-single 4K, single BPM (250/160), no stops, Challenge
  18/13, holds+rolls present, mines to skip (Gurls 4, Nyan 22). .qua = Keys4
  x5, ms clock, holds via EndTime, real SV (SliderVelocities), BPM timing
  points. No PyYAML → hand-parse .qua. No Pillow → reuse osu2skin PNG codec.
- Plan: session-8 docs commit → tools/sm2gakuran.py + tools/qua2gakuran.py
  (import shared bits from osu2gakuran; same chart schema, source=etterna/
  quaver) → tools/qua2skin.py + tools/etterna2skin.py (import osu2skin codec;
  quaver per-lane taps via manifest.taps; etterna single-arrow skin) →
  loader SOURCE_TAGS + icons (etterna/quaver PNGs, v2.0.25) → backup +
  import to workspace → live verify (load all, spot-play, skins apply) →
  final commit. Skins go to repo GakuranCharts/Skins (converted output, not
  the forbidden source folder).
- [x] Converters done + verified (see ROADMAP 11): sm 2 charts, qua 4 charts,
  nyan + bozo-6.6k-SV played live with 0 errors, both skins 0 vis errors.
- [x] Unified per user request: tools/convert_song.py + tools/convert_skin.py
  (import-based, per-format CLIs kept; byte-identical proofs in ROADMAP 11).
- [x] Skin eyeball fixes (tail-tip orientation is skin-specific, etterna
  per-lane arrows + hold-width normalize) verified live, scores cleared.
- [x] DEPLOYED v2.0.25, workspace == repo, candidate cleaned.
- [x] v2.0.26/v2.0.27 (user eyeball: hold heads all-up, receptors all-up,
  hold/body gap): loader hold-head per-lane fallback, manifest.receptors +
  recN/recPN packs, etterna cap crop. Root causes: hold logic hardcoded to
  the single head; schema had no per-lane receptors; cap art floated in a
  128px transparent canvas. Hardest bug: recImgs built but never copied from
  pack to skinState (recLanes diagnostic proved ss.recImgs empty while
  tapLanes=3) — check handoffs between tables, not just producers.
- [x] DEPLOYED v2.0.27, workspace == repo, candidate cleaned.
- [x] Etterna tips (user: still inverted): re-viewed the source art instead
  of trusting memory — the chevron points DOWN, so the osu convention was
  correct and my swap was the bug. Reverted, tail redeployed (repo +
  workspace hash-matched), live sanity 0 errors. Cap orientation is
  per-skin; note the convention + verification in the converter comment.
- [x] v2.0.28 hit-flash (user: flashes all-Up): engine template issue +
  per-frame lane-mapped repaint, verified with real spawned flashes.
- Repo hygiene lesson (this session): `git add -A` staged 537 untracked
  FunkyChart_v1.23 files into 8bc108d (reset to 14d76c2 with docs only).
  FunkyChart_v1.23/* is now gitignored except FunkyChart.lua. From here on:
  NEVER `git add -A` in this repo — stage explicit paths only.

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
