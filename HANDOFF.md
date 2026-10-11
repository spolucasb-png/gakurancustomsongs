# Handoff (for the next chat session)

## State
`GakuranChart.lua` is the single loader again (v2.0.11). The temporary copies
`GakuranChart_v2.0.9.lua` / `GakuranChart_v2.0.10.lua` were folded into it and
removed (they stay in git history). The earlier file lock on `GakuranChart.lua`
is gone.

Recent loader changes (see `git log` for the live-test notes of each):
- v2.0.9: wheel submenu slot title star-first (superseded by 2.0.11).
- v2.0.10: single-difficulty custom songs get a star label ("★5.32") as their
  wheel difficulty. Two HookBase wrappers: `DiffKey` (RhythmDifficulty.Key maps a
  star label to its tier colour) and `DiffTier` (RhythmWheelKit.tier returns the
  label itself as the chip word; the skins draw tier(diff).word, not the raw
  text). User confirmed the badges look right in the wheel list.
- v2.0.11: multi-difficulty submenu slots use the same chip (`art.diff` = star
  label); the title is just the difficulty name. Verified by rendering the real
  submenu page through the live skin (chip text and colours correct); NOT yet
  eyeballed by the user in the open wheel.

## Workflow
- Loader runs from the executor workspace
  `C:\Users\Administrator\AppData\Local\Madium\Workspace` (copy the repo file
  there, then `run_executor_file`). `_G.GakuranChart` holds the API
  (`openPicker`, `pickerStatus`, `svStatus`, `visStatus`, `list`, `setSkin`...).
- The wheel only renders while an instrument is held. To test a submenu page
  without it, call `_G.GakuranChartHookBase.WheelMenu.renderMenu(controller, "me_u")`
  with the controller found via getgc (table with `_slots` and `_menuPage`) and read
  `controller._slots[i].Data / .V.DiffText.Text`.

## Still open / not verified
- Submenu chip not yet seen on screen; pill width with long names unchecked.
- Select-flash colour, physical wheel click, full pick->play->stop cycle on the
  current build, overlay/submenu exclusion with a real overlay.
- Character can stay stuck in keyboard mode after a stage or forced chart play.
- Real stage play with the SV-spawn / skin-visual passes (never forced live).
- Skin visuals (hold head, pressed receptor, per-lane taps) and SV-aware spawn are
  done (`3b4358f`, `d35b546`, `578c2d8`).
- Leftover test junk in the executor workspace: `GakuranCharts/Skins/zz_vis_*` (if
  present) and the many `GakuranChart_*_candidate.lua` files (safe to delete).