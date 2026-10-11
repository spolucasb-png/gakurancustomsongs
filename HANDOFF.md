# Handoff (for the next chat session)

State at commit time: `main` was at `109064e` (v2.0.8) before this commit.

## Why there are two loader files
`GakuranChart.lua` could not be overwritten (Windows EPERM on rename; something
had the file locked). The fix was made in a copy instead:

- `GakuranChart_v2.0.9.lua` = `GakuranChart.lua` (v2.0.8) + the changes below.
- Next step: confirm `GakuranChart_v2.0.9.lua` works, then replace
  `GakuranChart.lua` with it (`Copy-Item -Force`) and delete the copy. If the
  lock is still there, find what holds the file (editor, other session, AV).

## Changes in v2.0.9 (only these)
1. `HK.renderWheelSubmenu` (~line 2518): difficulty slot title is now
   `★5.32  NAME` instead of `NAME  ★5.32`. The engine's slot label end-truncates
   with "...", so a long difficulty name used to hide the star. With the star
   first only the name can be clipped.
2. VERSION / header comment bumped to 2.0.9.

## NOT verified
- The change has not been seen on screen. The wheel only renders while an
  instrument is held; `G.openPicker("me_u")` reported open but no label existed.
  To test: hold a keyboard, open the wheel, open `me_u` (has the long
  "UNPREDICTABLE'S ADVANCED"), check the star is visible.
- Name-first with a scrolling marquee, or a name shortened to a measured width,
  was the user's other idea (e.g. `i love u ★5.32`). It needs the engine slot
  label measured live with the wheel open (TextService:GetTextSize vs
  AbsoluteSize). Do it if star-first is not liked.
- Still open from v2.0.7: no select-flash colour seen by the user; physical
  wheel click, full pick->play->stop cycle, and overlay/submenu exclusion with a
  real overlay were never verified. User said "keep it 2-4k for now" and that
  the submenu styling is fine, so do not restyle.
- Known: the character can stay stuck in keyboard mode after a stage or forced
  chart play (separate fix pending).

## Workflow notes
- Loader runs from the executor workspace: `loadstring(readfile("GakuranChart.lua"))`
  (copy the repo file there first; `_G.GakuranChart` holds the API, e.g.
  `openPicker`, `pickerStatus`, `svStatus`, `visStatus`).
- Check `git log` for history; commit messages list what was verified live.
- Leftover test junk in the executor workspace: skin packs
  `GakuranCharts/Skins/zz_vis_*` and `GakuranChart_skinvisual_candidate.lua`
  (safe to delete; they show up in the skin dropdown).
- Skin visuals (hold head, pressed receptor, per-lane taps) are already done
  (`3b4358f`, `d35b546`).
