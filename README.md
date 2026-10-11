# GakuranChart

Custom chart system for the rhythm minigame in **(学乱) Gakuran** — a revival of
[FunkyChart v1.23](https://github.com/accountrevuilt/funkychart) (made for Funky Friday),
rebuilt against Gakuran's own engine.

Personal-use, client-side only. Custom charts are injected into the game's
`RhythmSongRegistry` and played through the official `RhythmServiceClient:StartPlay()`,
so countdown, note highway, judging, and results all use the real game code.
Score submission and jam-sync/amp-relay calls are neutralized for custom song ids
so nothing custom is ever sent to the server.

## Requirements

- A Roblox executor with: `getgc`, `getcustomasset`/`getsynasset`, file I/O
  (`readfile`, `writefile`, `isfile`, `isfolder`, `makefolder`, `listfiles`), `loadstring`
- Tested with Madium 2.0.0

## Usage

1. Put `GakuranChart.lua`, `ui/Rayfield.lua`, and the `GakuranCharts/` folder
   into the executor workspace (Madium: `AppData/Local/Madium/Workspace`).
2. Execute `GakuranChart.lua` in-game.
3. In the Rayfield window: pick a chart → **Play chart**. Keybind default: Rayfield's toggle key.
4. Stop restores your character attributes and removes the highway.

**Re-executing is safe**: running `GakuranChart.lua` again destroys the previous
Rayfield window, underframe, and watcher loop before building a new one
(generation counter + name-based cleanup of `Rayfield`/`Rayfield-Old` GUIs),
so you never end up with duplicate windows or competing watcher loops.

The character must exist. The script sets `PlayingInstrument`/`ItemEquipped`
attributes locally (client-only, restored on stop) to pass the game's
"are you holding the instrument" check.

## Converting osu! maps

.osz (osu! beatmap archive) and .osu files convert with the bundled Python tool:

```
python tools/osu2gakuran.py "map.osz" ^
  --charts-dir <workspace>/GakuranCharts/Charts ^
  --audio-dir  <workspace>/GakuranCharts/Audio ^
  --assets-dir <workspace>/GakuranCharts/Assets
```

- osu!mania (Mode 3) maps convert exactly (columns → lanes).
- osu!standard sliders become approximate holds; spinners are skipped.
- Audio and background image are copied automatically.

## Chart format (v1)

JSON, one file per chart in `GakuranCharts/Charts/`:

```json
{
  "formatVersion": 1,
  "id": "unique_id",
  "title": "Song", "artist": "Artist", "charter": "Charter",
  "bpm": 165,
  "animationbpm": 165,
  "animationBpmChanges": [{ "t": 24.9, "bpm": 169.4 }],
  "startAt": 0, "offsetMs": 0, "approach": 5,
  "mode": "Keyboard",
  "difficulty": { "Keyboard": "Hard" },
  "charts": { "Keyboard": [ { "b": 8.29, "l": 1, "d": 0 } ] },
  "audioFile": "GakuranCharts/Audio/song.mp3",
  "backgroundFile": "GakuranCharts/Assets/bg.jpg"
}
```

- `b` = note beat, `l` = lane (1-based; Keyboard/Bass/Drums 1–4, Guitar 1–2),
  `d` = hold length in beats (0 for taps).
- Note seconds are computed by the game as `t = 60/bpm × b` — so `bpm` is a
  **fixed reference BPM**. The converter picks the map's first BPM and stores beats
  pre-converted, making timing exact even through mid-song BPM changes (which go in
  `animationBpmChanges` for character animation).
- `mode`: `Keyboard` (4 lanes), `Guitar` (2 lanes), `Bass`/`Drums` (4 lanes).

## Options (persisted to GakuranCharts/Settings.json)

- Audio offset (±500 ms)
- Background/dim (uses the map's background image if present, else a solid color)
- Show custom songs in the in-game song wheel (off by default). All charts in
  `GakuranCharts/Charts` are listed at loader start, when toggled on, and on
  "Refresh chart list". The game's wheel filters by the instrument your
  character holds — custom mania charts are Keyboard mode, so they appear
  while holding a keyboard.

## Console API

`_G.GakuranChart` (after executing the loader):

```lua
_G.GakuranChart.load("GakuranCharts/Charts/song.json")  -- parse/validate a chart
_G.GakuranChart.play()                                   -- play the loaded chart
_G.GakuranChart.stop()                                   -- stop + full cleanup
_G.GakuranChart.list()                                   -- list available chart files
_G.GakuranChart.current()                                -- currently loaded chart info
_G.GakuranChart.skins()                                  -- list installed skin packs
_G.GakuranChart.setSkin("My Skin")                       -- select a skin ("" = default)
```

## osu!mania skins (v1.3)

Convert any osu! skin into a Gakuran skin pack and select it in the Options tab.
The skin applies **globally while the loader runs** — our Play button *and* the
game's own stage plays (walk up to a real keyboard) — and is restored when the
loader is removed or the skin is set back to "Game default":

```
python tools/osu2skin.py "C:/Users/<you>/AppData/Local/osu!/Skins/MySkin" ^
  --out <workspace>/GakuranCharts/Skins ^
  [--keys 4] [--lane 2] [--name "My Skin"]
```

- Reads the skin.ini `[Mania]` Keys:N section (`NoteImage*`/`KeyImage*`, with
  stable-name fallbacks); `--lane` picks which column's art to use when a skin
  has per-lane notes.
- Produces `head.png` / `receptor.png` / `tail.png` (hold body + end cap
  composited into one slice-stretched sprite) + `manifest.json`.
- The loader registers the pack into the game's `RhythmNoteSprites` tables and
  wraps `StoredToViewTheme` to inject note/receptor images while one of our
  sessions runs. The game's own `SetNoteShape`/`SetCustomImage` are never used
  (they persist via a server remote).
- Limitation: one note image for all 4 lanes (the engine has no per-lane
  textures); judgement popups and hit sounds stay game-default.

## v1.1 fixes (verified in-game)

- **Full-length playback**: the real audio duration is pre-cached via
  `RhythmChartUtil.CacheSoundLength` before `StartPlay`, so the session ends with
  the *audio* instead of the old `chartEnd + 3s` fallback (previously cut songs
  ~20 s early).
- **Results/end screen appears**: the watcher no longer restores character
  attributes while the results surface is up — restoring mid-fade triggered the
  engine's `stopIfInvalidContext → Stop()`, which destroyed the results screen
  during its 0.4 s fade-in. Attributes are now restored only after the results
  screen is dismissed (verified stable 25 s+).
- **No score carry-over**: `service._carryOverStats` is cleared before and after
  every custom session, so replays always start at score 0.
- **Dropdown crash fixed**: missing `%s` format-arg bug in the chart list
  dropdown, plus all UI callbacks and status updates are `pcall`-wrapped so a Rayfield
  error can no longer take down the window.
- **Converter hold fix**: osu!mania hold end times (field merged with hitSample,
  e.g. `3560:2:0:1:60:`) are parsed correctly — 865 holds restored in SOUND
  ARCHITECT.

## Stability (v2.0)

Re-executing the loader or a failed UI build no longer leaves anything behind.
All three mechanisms below were verified live (hook/registry state identical
across repeated executions).

- **Hook ownership.** The safety-net hooks on `SubmitStats`, `QueryJamSync` and
  `FireStart` use one versioned shared base (`_G.GakuranChartHookBase`, v2) with a
  single stable wrapper per hook, so re-executing never wraps the wrappers.
  Genuine originals are recovered by peeling wrappers left by older loader
  versions. Cleanup restores a slot only while our wrapper is still installed,
  and stays out of the chain if another script wrapped it afterwards.
- **Registry ledger.** `_G.GakuranChartLedger` (v1) records the song objects we
  inject and any genuine entries they displaced. Cleanup removes only what the
  ledger says we own and puts displaced genuine entries back by identity, never
  by id match. Leftovers from pre-ledger versions are claimed only for managed ids
  whose sounds are all `rbxasset://`. The song wheel is de-duplicated without
  touching genuine entries.
- **UI-failure rollback.** The Rayfield build runs inside `buildUI()` + `xpcall`.
  If it errors, the loader logs `UI initialization failed - rolling the loader
  back`, retires that instance, runs the cleanup that was registered before the
  UI was built, sweeps any Rayfield windows, and defers guard/registry teardown
  while a custom session is still shutting down. There is no headless fallback;
  fix the error and execute again.

Custom song ids are still neutralized locally with early returns, so nothing
custom is sent to the server.

## Files

| Path | Purpose |
| --- | --- |
| `GakuranChart.lua` | The in-game loader (execute this) |
| `tools/osu2gakuran.py` | osu! → GakuranCharts JSON converter |
| `tools/osu2skin.py` | osu! skin → GakuranCharts/Skins pack converter |
| `GakuranCharts/Skins/` | Converted skin packs (manifest + sprites) |
| `GakuranCharts/Charts/test_end.json` | 30 s smoke-test chart (end/duration/holds) |
| `FunkyChart_v1.23/` | Original FunkyFriday reference (loader stub + converter exe) |

Credit: FunkyChart concept and original by accountrevived. GakuranChart remake for
the Gakuran rhythm engine.
