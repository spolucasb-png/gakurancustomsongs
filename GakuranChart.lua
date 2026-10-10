--[[
    GakuranChart v1.3
    Custom chart system for the (学乱) Gakuran rhythm minigame.
    Revival/remake of FunkyChart v1.23 (by accountrevived) for a different game.

    How it works:
      - Custom charts are JSON files in  GakuranCharts/Charts  (executor workspace)
      - Audio/images live in            GakuranCharts/Audio / GakuranCharts/Assets
      - osu!mania skin packs live in    GakuranCharts/Skins (tools/osu2skin.py)
        and apply GLOBALLY while the loader runs: our Play button and the
        game's own stage plays all get the skin (restore on loader removal).
      - On Play, the chart is injected into the game's own RhythmSongRegistry
        and the official RhythmServiceClient:StartPlay() runs it through the
        real engine (countdown, highway, judging, results).
      - Everything is client-side. Score submission and jam-sync/amp relay calls
        are neutralized for custom song ids so nothing custom reaches the server.

    Chart format v1 is produced by tools/osu2gakuran.py (osu! .osz/.osu converter).
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local VERSION = "1.4"
local FOLDER = "GakuranCharts"
local CHARTS_DIR = FOLDER .. "/Charts"
local AUDIO_DIR = FOLDER .. "/Audio"
local ASSETS_DIR = FOLDER .. "/Assets"
local SKINS_DIR = FOLDER .. "/Skins"
local SETTINGS_FILE = FOLDER .. "/Settings.json"

----------------------------------------------------------------
-- 0. Executor capability check
----------------------------------------------------------------
local function requireFn(name)
    if type(_G[name]) == "function" then return _G[name] end
    if type(getfenv) then
        local ok, env = pcall(function() return getfenv(0) end)
        if ok and type(env) == "table" and type(env[name]) == "function" then
            return env[name]
        end
    end
    return nil
end

local fn = {}
for _, n in ipairs({ "getgc", "readfile", "writefile", "isfile", "isfolder",
                     "makefolder", "listfiles", "loadstring", "getcustomasset" }) do
    fn[n] = requireFn(n)
end
fn.getsynasset = requireFn("getsynasset")
fn.getlocalasset = fn.getcustomasset or fn.getsynasset

local missing = {}
for _, n in ipairs({ "getgc", "readfile", "writefile", "isfile", "isfolder",
                     "makefolder", "listfiles", "loadstring" }) do
    if not fn[n] then table.insert(missing, n) end
end
if not fn.getlocalasset then table.insert(missing, "getcustomasset/getsynasset") end
if #missing > 0 then
    warn("[GakuranChart] Executor missing functions: " .. table.concat(missing, ", "))
    return
end

----------------------------------------------------------------
-- 0.5. Re-execution cleanup: kill the previous instance's UI/loop
----------------------------------------------------------------
local MYGEN = (_G.GakuranChartGen or 0) + 1
_G.GakuranChartGen = MYGEN

if type(_G.GakuranChartCleanup) == "function" then
    pcall(_G.GakuranChartCleanup)
    _G.GakuranChartCleanup = nil
end

-- Fallback for older versions that didn't register a cleanup fn:
-- destroy any previous Rayfield window (Rayfield itself only renames old
-- ones to "Rayfield-Old" and leaves them behind) and our old underframe.
pcall(function()
    local containers = {}
    if type(gethui) == "function" then
        local okH, h = pcall(gethui)
        if okH and h then table.insert(containers, h) end
    end
    table.insert(containers, CoreGui)
    local rg = CoreGui:FindFirstChild("RobloxGui")
    if rg then table.insert(containers, rg) end
    for _, c in ipairs(containers) do
        for _, g in ipairs(c:GetChildren()) do
            if g.Name == "Rayfield" or g.Name == "Rayfield-Old" then
                g:Destroy()
            end
        end
    end
end)
pcall(function()
    local gui = player:FindFirstChildOfClass("PlayerGui")
    if gui then
        for _, g in ipairs(gui:GetChildren()) do
            if g.Name == "GakuranChartUnderframe" then
                g:Destroy()
            end
        end
    end
end)

----------------------------------------------------------------
-- 1. Locate the game's rhythm service + hook safety nets
----------------------------------------------------------------
local function gcFind(pred)
    for _, v in next, fn.getgc(true) do
        if type(v) == "table" and pred(v) then return v end
    end
    return nil
end

local serviceClass = gcFind(function(t)
    return type(rawget(t, "StartPlay")) == "function" and type(rawget(t, "Get")) == "function"
        and type(rawget(t, "Stop")) == "function"
end)
if not serviceClass then
    warn("[GakuranChart] Could not find RhythmServiceClient - has the rhythm system changed?")
    return
end
local ok, service = pcall(serviceClass.Get, serviceClass)
if not ok or type(service) ~= "table" then
    warn("[GakuranChart] Failed to get RhythmService singleton: " .. tostring(service))
    return
end
pcall(service.Init, service)

-- song ids currently injected by us
local customIds = {}
-- chart JSONs by song id: needed to build SV models for plays the
-- loader didn't start itself (song wheel / stage / relay).
local customCharts = {}

-- Safety net 1: never submit scores for custom songs
local statsMod = gcFind(function(t) return type(rawget(t, "SubmitStats")) == "function" end)
if statsMod then
    local origSubmit = statsMod.SubmitStats
    statsMod.SubmitStats = function(songId, ...)
        if customIds[songId] then return end
        return origSubmit(songId, ...)
    end
end

-- Safety net 2: never query jam sync / fire amp relay for custom songs
local relayMod = gcFind(function(t)
    return type(rawget(t, "QueryJamSync")) == "function" and type(rawget(t, "FireStart")) == "function"
end)
if relayMod then
    local origQuery = relayMod.QueryJamSync
    relayMod.QueryJamSync = function(songId, ...)
        if customIds[songId] then return false, nil end
        return origQuery(songId, ...)
    end
    local origFireStart = relayMod.FireStart
    relayMod.FireStart = function(payload, ...)
        if type(payload) == "table" and customIds[payload.SongId] then return end
        return origFireStart(payload, ...)
    end
end

----------------------------------------------------------------
-- 2. Settings persistence
----------------------------------------------------------------
local settings = {
    offsetMs = 0,
    bgEnabled = false,
    bgColor = { 0, 0, 0 },
    bgTransparency = 0,
    showInWheel = false,
    skin = "",   -- selected osu!mania skin pack name ("" = game default)
}

local function saveSettings()
    pcall(fn.writefile, SETTINGS_FILE, HttpService:JSONEncode(settings))
end

local function loadSettings()
    if pcall(fn.isfile, SETTINGS_FILE) and fn.isfile(SETTINGS_FILE) then
        local ok2, data = pcall(function() return HttpService:JSONDecode(fn.readfile(SETTINGS_FILE)) end)
        if ok2 and type(data) == "table" then
            for k, v in pairs(data) do settings[k] = v end
        end
    end
end

-- ensure folders exist
for _, dir in ipairs({ FOLDER, CHARTS_DIR, AUDIO_DIR, ASSETS_DIR }) do
    if not fn.isfolder(dir) then pcall(fn.makefolder, dir) end
end
loadSettings()

----------------------------------------------------------------
-- 3. Chart loading
----------------------------------------------------------------
local function notify(title, body, isError)
    warn(("[GakuranChart] %s: %s"):format(title, body))
end

local function listChartFiles()
    local out = {}
    local ok2, files = pcall(fn.listfiles, CHARTS_DIR)
    if ok2 and type(files) == "table" then
        for _, f in ipairs(files) do
            if tostring(f):lower():match("%.json$") then
                table.insert(out, f)
            end
        end
    end
    table.sort(out)
    return out
end

local currentChart = nil   -- decoded json
local currentChartPath = nil

local function readChart(path)
    if not fn.isfile(path) then
        return nil, "File not found: " .. tostring(path)
    end
    local ok2, data = pcall(function() return HttpService:JSONDecode(fn.readfile(path)) end)
    if not ok2 then
        return nil, "Invalid JSON: " .. tostring(data)
    end
    if type(data) ~= "table" then
        return nil, "Chart file is not a JSON object"
    end
    if data.formatVersion ~= 1 then
        return nil, "Unsupported chart format version: " .. tostring(data.formatVersion)
    end
    if type(data.id) ~= "string" or data.id == "" then
        return nil, "Chart missing 'id'"
    end
    if type(data.charts) ~= "table" or type(data.mode) ~= "string" then
        return nil, "Chart missing 'charts' or 'mode'"
    end
    if type(data.charts[data.mode]) ~= "table" or #data.charts[data.mode] == 0 then
        return nil, "Chart has no notes for mode " .. tostring(data.mode)
    end
    if type(data.bpm) ~= "number" or data.bpm <= 0 then
        return nil, "Chart missing valid 'bpm'"
    end
    -- lane sanity: Gakuran lanes are 1-based (1..lanes); clamp invalid lanes out
    local lanes = (data.mode == "Guitar") and 2 or 4
    local cleaned, dropped = {}, 0
    for _, n in ipairs(data.charts[data.mode]) do
        if type(n) == "table" and type(n.b) == "number" and type(n.l) == "number"
            and n.b >= 0 and n.l >= 1 and n.l <= lanes then
            table.insert(cleaned, { b = n.b, l = math.floor(n.l), d = math.max(0, tonumber(n.d) or 0) })
        else
            dropped += 1
        end
    end
    if #cleaned == 0 then
        return nil, "All notes were invalid (lanes must be 1.." .. lanes .. ")"
    end
    data.charts[data.mode] = cleaned
    data._droppedNotes = dropped
    return data
end

----------------------------------------------------------------
-- 4. Underframe (background) - client-side ScreenGui behind the highway
----------------------------------------------------------------
local underframeGui = nil

local function destroyUnderframe()
    if underframeGui then
        pcall(function() underframeGui:Destroy() end)
        underframeGui = nil
    end
end

local function createUnderframe(chart)
    destroyUnderframe()
    if not settings.bgEnabled then return end

    local gui = Instance.new("ScreenGui")
    gui.Name = "GakuranChartUnderframe"
    gui.DisplayOrder = -10
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = player:FindFirstChildOfClass("PlayerGui")

    local bg
    if type(chart.backgroundFile) == "string" and fn.isfile(chart.backgroundFile) then
        local okA, asset = pcall(fn.getlocalasset, chart.backgroundFile)
        if okA and asset then
            bg = Instance.new("ImageLabel")
            bg.Image = asset
            bg.ScaleType = Enum.ScaleType.Crop
        end
    end
    if not bg then
        bg = Instance.new("Frame")
        local c = settings.bgColor or { 0, 0, 0 }
        bg.BackgroundColor3 = Color3.fromRGB(c[1] or 0, c[2] or 0, c[3] or 0)
    end
    bg.Name = "Background"
    bg.AnchorPoint = Vector2.new(0.5, 0.5)
    bg.Position = UDim2.fromScale(0.5, 0.5)
    bg.Size = UDim2.fromScale(1, 1)
    bg.BorderSizePixel = 0
    bg.BackgroundTransparency = bg:IsA("Frame") and math.clamp(1 - (settings.bgTransparency or 0), 0, 1) or 1
    if bg:IsA("ImageLabel") then
        bg.BackgroundTransparency = 0
        bg.BackgroundColor3 = Color3.new(0, 0, 0)
    end
    bg.ZIndex = 0
    bg.Parent = gui
    underframeGui = gui
end

----------------------------------------------------------------
-- 5. Play / Stop
----------------------------------------------------------------
local savedAttributes = nil

local function saveAndSetAttributes(mode)
    local char = player.Character
    if not char then return false, "No character" end
    if not savedAttributes then
        savedAttributes = {
            PlayingInstrument = char:GetAttribute("PlayingInstrument"),
            ItemEquipped = char:GetAttribute("ItemEquipped"),
        }
    end
    char:SetAttribute("PlayingInstrument", mode)
    -- Guitar/Bass require ItemEquipped == mode; Keyboard/Drums require nil
    if mode == "Guitar" or mode == "Bass" then
        char:SetAttribute("ItemEquipped", mode)
    else
        char:SetAttribute("ItemEquipped", nil)
    end
    return true
end

local function restoreAttributes()
    if not savedAttributes then return end
    local char = player.Character
    if char then
        pcall(function() char:SetAttribute("PlayingInstrument", savedAttributes.PlayingInstrument) end)
        pcall(function() char:SetAttribute("ItemEquipped", savedAttributes.ItemEquipped) end)
    end
    savedAttributes = nil
end

local function buildGameSong(chart)
    local mode = chart.mode
    local audioAsset
    if type(chart.audioFile) == "string" and fn.isfile(chart.audioFile) then
        local okA, asset = pcall(fn.getlocalasset, chart.audioFile)
        if okA and asset then
            audioAsset = asset
        end
    end
    if not audioAsset then
        return nil, "Audio file missing: " .. tostring(chart.audioFile)
    end

    local song = {
        id = chart.id,
        title = chart.title or chart.id,
        artist = chart.artist or "",
        charter = chart.charter or "",
        bpm = chart.bpm,
        animationbpm = chart.animationbpm or chart.bpm,
        animationBpmChanges = chart.animationBpmChanges,
        startAt = tonumber(chart.startAt) or 0,
        offsetMs = settings.offsetMs or 0,
        approach = tonumber(chart.approach) or 5,
        charts = { [mode] = chart.charts[mode] },
        soundIds = { [mode] = audioAsset },
        difficulty = chart.difficulty or { [mode] = "Custom" },
    }
    if type(chart.backgroundFile) == "string" and fn.isfile(chart.backgroundFile) then
        local okB, asset = pcall(fn.getlocalasset, chart.backgroundFile)
        if okB and asset then
            song.coverId = asset
        end
    end
    return song
end

local function injectSong(song)
    customIds[song.id] = true
    service._registry._byId[song.id] = song
    if settings.showInWheel then
        for _, s in ipairs(service._registry._list) do
            if s.id == song.id then return end
        end
        table.insert(service._registry._list, song)
    end
end

-- The game's song wheel rebuilds its list on every open from
-- registry:List(), filtered to the instrument the character holds
-- (hasPlayableChartForHeld: the song needs a non-empty charts[mode]).
-- Our charts are Keyboard mode, so they show up while a keyboard is
-- equipped. injectSong previously only ran when a chart was PLAYED,
-- so the wheel never listed anything else - inject them all instead.
local function injectAllCharts()
    if not settings.showInWheel then return 0 end
    local count = 0
    for _, path in ipairs(listChartFiles()) do
        local okR, chart = pcall(readChart, path)
        if okR and type(chart) == "table" and type(chart.id) == "string" then
            customCharts[chart.id] = chart
            local okB, song = pcall(buildGameSong, chart)
            if okB and song then
                pcall(injectSong, song)
                count += 1
            end
        end
    end
    return count
end

local function removeFromWheel()
    local list = service._registry and service._registry._list
    if type(list) ~= "table" then return end
    for i = #list, 1, -1 do
        local entry = list[i]
        if type(entry) == "table" and customIds[entry.id] then
            table.remove(list, i)
        end
    end
end

----------------------------------------------------------------
-- 5.5 Audio length cache
-- The engine computes the session duration by probing the sound
-- length SYNCHRONOUSLY (RhythmChartUtil.resolveDurationFromSound):
-- a freshly created Sound is never loaded yet, so for custom audio
-- it always fell back to "chart end + 3s" and the session ended
-- early while the track was still playing. We pre-load the sound
-- here and register its real length via CacheSoundLength so the
-- session lasts exactly as long as the audio.
----------------------------------------------------------------
local chartUtil = gcFind(function(t)
    return type(rawget(t, "CacheSoundLength")) == "function"
        and type(rawget(t, "resolvePlayable")) == "function"
end)

local function cacheAudioLength(assetId)
    if not chartUtil then return nil end
    local SoundService = game:GetService("SoundService")
    local probe = Instance.new("Sound")
    probe.Name = "GakuranChartDurationProbe"
    probe.SoundId = assetId
    probe.Volume = 0
    probe.Looped = false
    probe.Parent = SoundService
    local length = nil
    local deadline = os.clock() + 10
    while os.clock() < deadline do
        if probe.TimeLength > 0.05 then
            length = probe.TimeLength
            break
        end
        task.wait(0.1)
    end
    pcall(function() probe:Destroy() end)
    if length then
        pcall(chartUtil.CacheSoundLength, assetId, length)
        return length
    end
    return nil
end

----------------------------------------------------------------
-- 5.7 osu!mania skin support
-- Skin packs live in GakuranCharts/Skins/<name>/ (tools/osu2skin.py).
-- The highway paints notes/receptors from a VIEW theme built by
-- RhythmThemeSettings.StoredToViewTheme, and hold tails from
-- RhythmNoteSprites.Tails[shapeName] (GetTail falls back to
-- Tails[shapeName] first, so a custom shape gets a custom tail).
-- While one of our sessions runs we:
--   * register Tails/Shapes[shapeKey] with the pack's sprites,
--   * wrap StoredToViewTheme to inject NoteImage/ReceptorImage
--     (ReceptorColor auto-whitens when ReceptorImage is set),
--   * write settings._theme.noteShape = shapeKey DIRECTLY.
-- The public SetNoteShape/SetCustomImage persist through a server
-- remote, so they are deliberately never used - everything here is
-- local-only and undone after the session.
----------------------------------------------------------------
-- { shapeKey, head, headHold, receptor, receptorPressed, tapImgs,
--   hasHoldHead, hasPressed, hasTapVariants, origShapes, wrapped }.
-- headHold/receptorPressed always hold a usable asset (they fall back to
-- head/receptor); hasHoldHead/hasPressed say whether the pack really ships
-- a distinct image. tapImgs maps 1-based lanes to tap art (lanes without
-- their own art fall back to head); hasTapVariants says the map is non-empty.
local skinState = nil
local settingsThemeHosts = {}  -- tables that own a raw _theme with noteShape

do
    local mod = gcFind(function(t)
        return type(rawget(t, "GetNoteShape")) == "function"
            and type(rawget(t, "GetViewTheme")) == "function"
    end)
    if mod then
        if type(rawget(mod, "_theme")) == "table" then
            table.insert(settingsThemeHosts, mod)
        end
        local okG, inst = pcall(mod.Get, mod)
        if okG and type(inst) == "table" and inst ~= mod
            and type(rawget(inst, "_theme")) == "table" then
            table.insert(settingsThemeHosts, inst)
        end
        -- force hydration once (their own normal settings Get) so later
        -- reads of _theme don't trigger a remote mid-play
        pcall(mod.GetNoteShape, mod)
    end
end

local noteSpritesMod = gcFind(function(t)
    return type(rawget(t, "Shapes")) == "table" and type(rawget(t, "Tails")) == "table"
        and type(rawget(t, "GetShape")) == "function" and type(rawget(t, "GetTail")) == "function"
end)

local themeSettingsMod = gcFind(function(t)
    return type(rawget(t, "StoredToViewTheme")) == "function"
        and type(rawget(t, "SanitizeAssetId")) == "function"
end)

----------------------------------------------------------------
-- 5.7b Skin visual pass: dedicated hold-head, pressed-receptor and
-- per-lane tap art
-- The engine paints a note's Head image ONCE when the view is built
-- (RhythmView: Paint(Head, NoteImage)); PrepareNoteVisual never repaints
-- it, and pooled note frames are recycled between notes. Likewise the
-- receptor image is painted once; SetReceptorPressed only tweens colour
-- and size and records view._receptorPressed[lane]. So, per frame and
-- ONLY for a custom-chart session built under the active skin, we:
--   * give every active note with len > 0 the pack's hold-head image and
--     every other note its lane's tap image (manifest.taps, falling back
--     to the base tap; note.inst -> Head, plus the Backing silhouette and
--     its Band, which the engine painted with the same image);
--   * show the pressed image on lanes whose _receptorPressed flag is set
--     and the resting image otherwise (Receptors[lane].ReceptorVisual,
--     plus the ReceptorGlow backing and its Band).
-- Purely cosmetic: no timing/judging state is read or written. Painting
-- goes through the engine's own RhythmNoteSprites.Paint(label, image,
-- rect, pixelated); with rect nil it also resets ImageRectOffset/Size,
-- exactly what the engine does for custom images. A write happens only
-- when the current Image differs. Real stage plays are never touched
-- (customIds gate). A view is only touched while it was built with the
-- active skin's images (view._noteImage == skin.head); if the skin is
-- switched/deactivated mid-session, restoreViewVisuals puts the view's
-- own images back.
----------------------------------------------------------------
local visTouched = setmetatable({}, { __mode = "k" })   -- views we wrote to
local visLane = setmetatable({}, { __mode = "k" })     -- note frame -> 1-based lane (for lane-aware restore)
local visTapImgs = setmetatable({}, { __mode = "k" })  -- view -> tap-art map it was painted with
local visFrameErrors = 0
local visDisabled = false   -- set after 60 frame errors (SV is unaffected)
local visWrites = 0

local function paintImage(label, image)
    local paint = noteSpritesMod and noteSpritesMod.Paint
    if type(paint) == "function" then
        paint(label, image)
    else
        label.Image = image
    end
    visWrites += 1
end

-- Head layers of a pooled note frame: Head, Backing (the outline
-- silhouette, a sibling) and Backing.Band.
local function paintNoteImage(inst, image)
    local head = inst:FindFirstChild("Head")
    if not head or head.Image == image then return end
    paintImage(head, image)
    local backing = inst:FindFirstChild("Backing")
    if backing then
        paintImage(backing, image)
        local band = backing:FindFirstChild("Band")
        if band then paintImage(band, image) end
    end
end

local function paintReceptorImage(view, lane, image)
    local receptors = view.Receptors
    local rec = type(receptors) == "table" and receptors[lane] or nil
    local vis = rec and rec:FindFirstChild("ReceptorVisual")
    if not vis or vis.Image == image then return end
    paintImage(vis, image)
    local glows = view._receptorGlows
    local glow = type(glows) == "table" and glows[lane] or nil
    if glow then
        paintImage(glow, image)
        local band = glow:FindFirstChild("Band")
        if band then paintImage(band, image) end
    end
end

-- Put a view's own tap/resting images back on every pooled note frame and
-- receptor (the images the engine painted when it built the view).
-- Per-lane tap art is restored from the lane tracked while painting plus
-- the tap-art map the view was painted with; frames with no tracked lane
-- (or a view painted without lane variants) get the view's base noteImage.
local function restoreViewVisuals(view)
    visTouched[view] = nil
    local tapImgs = visTapImgs[view]
    visTapImgs[view] = nil
    local noteImage = view._noteImage
    local theme = view._theme
    local recImage = type(theme) == "table" and theme.ReceptorImage or nil
    local pool = view._pool
    local list = type(pool) == "table" and pool._pool or nil
    if noteImage and type(list) == "table" then
        for _, inst in ipairs(list) do
            local lane = visLane[inst]
            visLane[inst] = nil
            local want = noteImage
            if lane and type(tapImgs) == "table" and tapImgs[lane] then
                want = tapImgs[lane]
            end
            paintNoteImage(inst, want)
        end
    end
    if recImage and type(view.Receptors) == "table" then
        for lane = 1, (tonumber(view._laneCount) or #view.Receptors) do
            paintReceptorImage(view, lane, recImage)
        end
    end
end

local function restoreTouchedViews()
    for view in pairs(visTouched) do
        pcall(restoreViewVisuals, view)
    end
end

local function visApplyFrameInner()
    local sess = service._session
    if type(sess) ~= "table" or sess._destroyed then return end
    -- Only OUR charts' sessions (never a real stage play).
    local p = sess._playable
    local id = type(p) == "table" and (p.id or p.songId) or nil
    if not id or not customIds[id] then return end
    local view = sess._view
    if type(view) ~= "table" then return end
    local ss = skinState
    local theme = view._theme
    if not (ss and (ss.hasHoldHead or ss.hasPressed) and type(theme) == "table"
        and view._noteImage == ss.head and theme.ReceptorImage == ss.receptor) then
        -- no skin, a skin without extras, or a view built under a different
        -- skin: leave it alone (and undo anything we painted earlier)
        if visTouched[view] then restoreViewVisuals(view) end
        return
    end
    if ss.hasHoldHead or ss.hasTapVariants then
        local active = sess._active
        if type(active) == "table" then
            local tapImage, holdImage, tapImgs = ss.head, ss.headHold, ss.tapImgs
            for _, note in ipairs(active) do
                local inst = note.inst
                if inst then
                    -- Holds share one head image; taps use their lane's art
                    -- (lanes without their own art fall back to the base tap).
                    local want
                    if (note.len or 0) > 0 then
                        want = holdImage
                    elseif type(tapImgs) == "table" and tapImgs[note.lane] then
                        want = tapImgs[note.lane]
                    else
                        want = tapImage
                    end
                    local head = inst:FindFirstChild("Head")
                    if head and head.Image ~= want then
                        visTouched[view] = true
                        visTapImgs[view] = tapImgs
                        visLane[inst] = note.lane
                        paintNoteImage(inst, want)
                    end
                end
            end
        end
    end
    if ss.hasPressed then
        local pressed = view._receptorPressed
        if type(pressed) == "table" and type(view.Receptors) == "table" then
            local rest, down = ss.receptor, ss.receptorPressed
            if not visTouched[view] then visTouched[view] = true end
            for lane = 1, (tonumber(view._laneCount) or #view.Receptors) do
                paintReceptorImage(view, lane, pressed[lane] and down or rest)
            end
        end
    end
end

local function visApplyFrame()
    if visDisabled then return end
    local ok, err = pcall(visApplyFrameInner)
    if ok then
        visFrameErrors = 0
        return
    end
    visFrameErrors += 1
    if visFrameErrors == 1 then
        warn("[GakuranChart] Skin visual frame error: " .. tostring(err))
    elseif visFrameErrors >= 60 then
        warn("[GakuranChart] Skin visuals disabled after repeated frame errors")
        visDisabled = true
        pcall(restoreTouchedViews)
    end
end

local function listSkinPacks()
    local out, seen = {}, {}
    local function tryAdd(dir)
        if type(dir) ~= "string" or dir == "" or seen[dir] then return end
        seen[dir] = true
        local mf = dir .. "/manifest.json"
        if not (pcall(fn.isfile, mf) and fn.isfile(mf)) then return end
        local okJ, man = pcall(function()
            return HttpService:JSONDecode(fn.readfile(mf))
        end)
        if okJ and type(man) == "table" and type(man.shapeKey) == "string" then
            man._dir = dir
            if type(man.name) ~= "string" or man.name == "" then
                man.name = dir:match("([^/\\]+)$") or man.shapeKey
            end
            table.insert(out, man)
        end
    end
    local okL, entries = pcall(fn.listfiles, SKINS_DIR)
    if okL and type(entries) == "table" then
        for _, e in ipairs(entries) do
            local e2 = tostring(e):gsub("\\", "/")
            if e2:match("manifest%.json$") then
                tryAdd((e2:gsub("/manifest%.json$", "")))
            else
                tryAdd(e2)                          -- entry may BE the skin dir
                local parent = e2:match("^(.+)/[^/]+$")
                if parent then tryAdd(parent) end   -- ...or a file inside it
            end
        end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

local function registerSkin(manifest)
    if not noteSpritesMod then
        return nil, "RhythmNoteSprites module not found"
    end
    local dir = manifest._dir
    local function assetOf(file)
        if type(file) ~= "string" or file == "" then return nil end
        local path = dir .. "/" .. file
        if not (pcall(fn.isfile, path) and fn.isfile(path)) then return nil end
        local okA, a = pcall(fn.getlocalasset, path)
        return (okA and a) or nil
    end
    local headA = assetOf(manifest.head)
    local recA = assetOf(manifest.receptor)
    local tailA = assetOf(manifest.tail)
    if not (headA and recA and tailA) then
        return nil, "skin files missing in " .. tostring(dir)
    end
    -- Optional alternate-state sprites (manifest.headHold / receptorPressed).
    -- Absent field or missing file -> nil -> falls back to the base image.
    local headHoldA = assetOf(manifest.headHold)
    local pressedA = assetOf(manifest.receptorPressed)
    -- Optional per-lane tap art (manifest.taps: 1-based lane -> file).
    -- Lanes without an entry fall back to the base tap image at runtime.
    local tapImgs = {}
    local taps = manifest.taps
    if type(taps) == "table" then
        for lane, file in pairs(taps) do
            local n = tonumber(lane)
            if n and type(file) == "string" then
                local a = assetOf(file)
                if a then tapImgs[n] = a end
            end
        end
    end
    local slice = type(manifest.slice) == "table" and manifest.slice or {}
    local okReg, err = pcall(function()
        noteSpritesMod.Tails[manifest.shapeKey] = {
            Body = tailA,
            Outline = tailA,      -- same sprite; the outline layer just re-draws it
            BodyRect = nil,
            OutlineRect = nil,
            SpriteSize = Vector2.new(tonumber(manifest.tailW) or 64, tonumber(manifest.tailH) or 64),
            SliceCenter = Rect.new(
                tonumber(slice[1]) or 0, tonumber(slice[2]) or 0,
                tonumber(slice[3]) or 0, tonumber(slice[4]) or 0
            ),
            Pixel = false,
        }
        noteSpritesMod.Shapes[manifest.shapeKey] = {
            Body = headA,
            Outline = headA,
            BodyRect = nil,
            OutlineRect = nil,
            SpriteSize = Vector2.new(512, 512),
            Rotation = 0,
            -- Hold-tail width. For plain shapes the view sizes a tail at
            -- NoteSize*0.55, which squeezes osu LN body/cap art to ~half the
            -- note width (osu draws both at the full column width, so the
            -- rounded tip also ends up ~half size). Box + TailFrac is the
            -- engine's own shape-level override: Box (1,1) leaves head and
            -- receptor sizes unchanged, TailFrac is the tail width as a
            -- fraction of the note width (manifest.tailFrac, default 1 =
            -- osu proportions).
            Box = Vector2.new(1, 1),
            TailFrac = tonumber(manifest.tailFrac) or 1,
            Receptor = { Body = recA, Outline = recA, BodyRect = nil, OutlineRect = nil },
        }
    end)
    if not okReg then
        return nil, "register failed: " .. tostring(err)
    end
    return {
        head = headA,
        headHold = headHoldA or headA,
        receptor = recA,
        receptorPressed = pressedA or recA,
        tapImgs = tapImgs,
        hasHoldHead = headHoldA ~= nil and headHoldA ~= headA,
        hasPressed = pressedA ~= nil and pressedA ~= recA,
        hasTapVariants = next(tapImgs) ~= nil,
        shapeKey = manifest.shapeKey,
        name = manifest.name,
    }
end

local function deactivateSkin()
    -- undo any hold-head / pressed-receptor paint in live custom views first
    pcall(restoreTouchedViews)
    if not skinState then return end
    if themeSettingsMod and skinState.wrapped then
        pcall(function()
            themeSettingsMod.StoredToViewTheme = _G.GakuranChartSkinBase or skinState.origStored
        end)
    end
    _G.GakuranChartSkinBase = nil
    for host, shape in pairs(skinState.origShapes) do
        pcall(function()
            local th = rawget(host, "_theme")
            if th then th.noteShape = shape end
        end)
    end
    skinState = nil
end

local function activateSkin(manifest)
    deactivateSkin()
    if not manifest then return false end
    local okReg, packOrErr = pcall(registerSkin, manifest)
    if not okReg or type(packOrErr) ~= "table" then
        warn("[GakuranChart] Skin load failed: " .. tostring(packOrErr))
        return false
    end
    local pack = packOrErr

    -- local-only noteShape write (save baseline for restore)
    local origShapes = {}
    for _, host in ipairs(settingsThemeHosts) do
        local th = rawget(host, "_theme")
        origShapes[host] = th.noteShape
        th.noteShape = pack.shapeKey
    end

    -- wrap StoredToViewTheme: inject our images into the view theme the
    -- highway gets at construction. Reuse a single base function across
    -- re-executions so wraps never stack.
    local wrapped = nil
    local origStored = nil
    if themeSettingsMod then
        origStored = _G.GakuranChartSkinBase or rawget(themeSettingsMod, "StoredToViewTheme")
        _G.GakuranChartSkinBase = origStored
        wrapped = function(stored, lanes)
            local vt = origStored(stored, lanes)
            if type(vt) == "table" and skinState then
                vt.NoteImage = skinState.head
                vt.ReceptorImage = skinState.receptor
                vt.NoteShape = skinState.shapeKey
                -- Original skin look: the highway normally multiplies sprites
                -- with theme tints - hold bodies with LaneColors, outline
                -- layers with NoteBorderColors, plus NoteBodyTransparency on
                -- holds. Neutralize all of them while our skin runs so the
                -- sprites render exactly as the skin drew them. Pressed
                -- receptors keep the game-default light-gray flash (no theme
                -- colors, still visible feedback).
                local n = tonumber(lanes) or 4
                for i = 1, n do
                    if type(vt.LaneColors) == "table" then
                        vt.LaneColors[i] = Color3.new(1, 1, 1)
                    end
                    if type(vt.NoteBorderColors) == "table" then
                        vt.NoteBorderColors[i] = Color3.new(1, 1, 1)
                    end
                    if type(vt.ReceptorPressedColors) == "table" then
                        vt.ReceptorPressedColors[i] = Color3.fromRGB(220, 220, 220)
                    end
                end
                vt.NoteBodyTransparency = 0
            end
            return vt
        end
        pcall(function() themeSettingsMod.StoredToViewTheme = wrapped end)
    end

    skinState = {
        shapeKey = pack.shapeKey,
        name = pack.name,
        head = pack.head,
        headHold = pack.headHold,
        receptor = pack.receptor,
        receptorPressed = pack.receptorPressed,
        tapImgs = pack.tapImgs,
        hasHoldHead = pack.hasHoldHead,
        hasPressed = pack.hasPressed,
        hasTapVariants = pack.hasTapVariants,
        origShapes = origShapes,
        origStored = origStored,
        wrapped = wrapped,
    }
    return true
end

local selectedSkinManifest = nil   -- set by the UI dropdown

local function findSelectedSkin()
    if type(settings.skin) ~= "string" or settings.skin == "" then return nil end
    for _, man in ipairs(listSkinPacks()) do
        if man.name == settings.skin then return man end
    end
    return nil
end

local playStatusCallback = nil   -- set by UI to update a status label

----------------------------------------------------------------
-- 5.8 SV (scroll velocity) support
-- Optional chart field: scrollChanges = { {b = beat, rate = mult}, ... }
-- (osu! inherited green lines via tools/osu2gakuran.py).
-- The engine draws each note at  hitY +/- (t - now) * scrollPxPerSec;
-- with SV the distance must be the integral of the scroll rate:
--   hitY +/- (I(t) - I(now)) * scrollPxPerSec,   I' = rate.
-- Judging stays time-based (we never touch it - SV is cosmetic).
-- We recompute each active note's Y ABSOLUTELY every frame, using the
-- engine's own _now()/HitY()/_scrollPxPerSec.
-- Ordering: our write must be the LAST one each frame. In the tested
-- environment RenderStepped:Connect handlers dispatch NEWEST-FIRST (a
-- controlled connect-A-then-B test fired B,A,B,A,B). The game connects
-- its per-play handlers when StartPlay runs, i.e. AFTER the loader has
-- initialized, so a connection the loader makes ONCE at init is OLDER
-- than every engine play handler and therefore fires after them.
-- attachSvRender() makes that single persistent connection during init
-- (before the UI, whose construction can yield); it is idempotent and is
-- never re-connected per frame or per play - a fresh Connect would be the
-- newest, i.e. first, and the engine would overwrite us again.
-- When nothing of ours is playing, the handler costs a couple of field
-- reads and returns.
-- Charts without scrollChanges build a nil model (no writes); flat
-- rates compute values identical to the engine's math.
----------------------------------------------------------------
local svModel = nil        -- {pts = {t...}, rates = {r...}, prefix = {I...}} | nil
local svModelId = nil      -- song id the current model was built for
local svRenderBound = false
local svFrameErrors = 0
local svDisabled = false   -- set after 60 frame errors (handler then no-ops)
local svRenderConn = nil    -- persistent RenderStepped connection, made ONCE at init (older than the engine's per-play ones => fires after them)
local svLastRun = 0        -- os.clock() of last handler invocation
local svLastWrites = 0     -- note writes performed in that run

local function stopSv()
    -- Drops the current model; the bound frame hook rebuilds lazily for
    -- the next custom session. The binding lives until cleanup.
    svModel = nil
    svModelId = nil
    svFrameErrors = 0
end

-- Piecewise integral of the scroll rate; I(t) = t (implicit rate 1)
-- before the first change. Any constant offset cancels out because only
-- differences I(a) - I(b) are ever used.
local function svIntegral(m, t)
    local pts = m.pts
    local n = #pts
    if t <= pts[1] then
        return t
    end
    if t >= pts[n] then
        return m.prefix[n] + (t - pts[n]) * m.rates[n]
    end
    local lo, hi = 1, n -- largest i with pts[i] <= t
    while lo < hi do
        local mid = (lo + hi + 1) // 2
        if pts[mid] <= t then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return m.prefix[lo] + (t - pts[lo]) * m.rates[lo]
end

local function buildSvModel(chart, song)
    local changes = chart.scrollChanges
    if type(changes) ~= "table" or #changes == 0 then return nil end
    local bpm = tonumber(song.bpm)
    if not bpm or bpm <= 0 then bpm = 120 end
    -- Same beat -> seconds formula the engine uses for notes
    -- (buildSecondsChart: t = startAt + chartDelay + 60/bpm * b), so SV
    -- boundaries land on the identical time axis as the note times.
    -- (song.offsetMs is deliberately NOT part of it - buildSecondsChart
    -- doesn't take it either.)
    local base = (tonumber(song.startAt) or 0) + (tonumber(song.chartDelay) or 0)
    local list = {}
    for _, c in ipairs(changes) do
        local b = tonumber(type(c) == "table" and c.b or nil)
        local r = tonumber(type(c) == "table" and c.rate or nil)
        if b and r and r > 0 then
            list[#list + 1] = { t = base + (60 / bpm) * b, r = math.clamp(r, 0.05, 20) }
        end
    end
    table.sort(list, function(x, y) return x.t < y.t end)
    local pts, rates = {}, {}
    for _, e in ipairs(list) do
        -- drop boundaries where the rate does not actually change
        if #rates == 0 or math.abs(rates[#rates] - e.r) > 1e-6 then
            pts[#pts + 1] = e.t
            rates[#rates + 1] = e.r
        end
    end
    if #pts == 0 then return nil end
    local prefix = { pts[1] }   -- I(pts[1]) = pts[1] under implicit rate 1
    for i = 2, #pts do
        prefix[i] = prefix[i - 1] + (pts[i] - pts[i - 1]) * rates[i - 1]
    end
    return { pts = pts, rates = rates, prefix = prefix }
end

local svPerspectiveWarned = false   -- warn once per loader instance while blocked

local function svApplyFrameInner()
    local sess = service._session
    if type(sess) ~= "table" or sess._destroyed then
        if svModelId ~= nil then stopSv() end   -- idle: sv() reports 0
        return
    end
    -- Only ever touch OUR charts' sessions (never a real stage play).
    local p = sess._playable
    local id = type(p) == "table" and (p.id or p.songId) or nil
    if not id or not customIds[id] then
        if svModelId ~= nil then stopSv() end
        return
    end
    -- Lazily build (or switch) the model for whatever custom song is
    -- playing right now - loader, wheel and stage starts all land here.
    -- svModelId set with svModel nil = "checked, this chart has no SV".
    if svModelId ~= id then
        local chart = customCharts[id]
        local reg = service._registry
        local song = reg and reg._byId and reg._byId[id]
        svModel = (chart and song) and buildSvModel(chart, song) or nil
        svModelId = id
    end
    local m = svModel
    if not m then return end
    -- Perspective mode re-derives lane X + note scale from the vanilla Y
    -- every frame; a Y-only override would fight it. SV + perspective
    -- falls back to engine-default rendering (documented limitation).
    if sess._perspective then
        if not svPerspectiveWarned then
            svPerspectiveWarned = true
            warn("[GakuranChart] SV inactive: perspective mode is on "
                .. "(the engine re-derives note positions itself)")
        end
        return
    end
    local view = sess._view
    if type(view) ~= "table" then return end
    local okN, now = pcall(function() return sess:_now() end)
    if not okN or type(now) ~= "number" then return end
    local S = sess._scrollPxPerSec
    if type(S) ~= "number" or S <= 0 then return end
    local okU, up = pcall(function() return view:IsUpscroll() end)
    local sign = (okU and up == true) and 1 or -1
    local okH, hitY = pcall(function() return view:HitY() end)
    if not okH or type(hitY) ~= "number" then return end
    local iNow = svIntegral(m, now)
    local active = sess._active
    if type(active) ~= "table" then return end
    for _, note in ipairs(active) do
        local inst = note.inst
        if inst then
            local t = note.t
            -- Head: engine pins held notes at the receptor itself, so only
            -- free notes get repositioned. Absolute write mirrors the
            -- engine's formula (_ipx rounding included) with (t - now)
            -- replaced by (I(t) - I(now)) - idempotent even if the
            -- engine's step early-returns this frame.
            if not note.holding then
                local y = math.floor(hitY + sign * (svIntegral(m, t) - iNow) * S + 0.5)
                local pos = inst.Position
                if pos.Y.Offset ~= y then
                    inst.Position = UDim2.new(pos.X.Scale, pos.X.Offset, pos.Y.Scale, y)
                end
            end
            -- Hold body: SV distance over the SAME time range the engine
            -- uses (head->end, or now->end while holding). Engine clamps
            -- to the visible span only as an optimization - the lanes
            -- frame clips descendants, so identical rendering.
            local tail = note.tailInst
            if tail and (note.len or 0) > 0 then
                local a, b2
                if note.holding then
                    a, b2 = now, t + note.len
                else
                    a, b2 = t, t + note.len
                end
                local rawLen = (svIntegral(m, b2) - svIntegral(m, a)) * S
                if rawLen < 0 then rawLen = 0 end
                local h = math.floor((math.floor(rawLen + 0.5) + 0.5) / 2) * 2
                local sz = tail.Size
                if h ~= sz.Y.Offset then
                    tail.Size = UDim2.new(sz.X.Scale, sz.X.Offset, sz.Y.Scale, h)
                end
            end
        end
    end
end

local function svApplyFrame()
    if svDisabled then return end
    local ok, err = pcall(svApplyFrameInner)
    if ok then
        svFrameErrors = 0
        return
    end
    svFrameErrors += 1
    if svFrameErrors == 1 then
        warn("[GakuranChart] SV frame error: " .. tostring(err))
    elseif svFrameErrors >= 60 then
        warn("[GakuranChart] SV disabled after repeated frame errors")
        svDisabled = true
        stopSv()
    end
end

-- ONE callback drives both per-frame passes. Each runs under its own pcall
-- and error counter, so a failure (or the SV early-outs) in one never stops
-- the other; the skin visual pass does not depend on an SV model at all.
local function persistentFrame()
    svApplyFrame()
    visApplyFrame()
end

-- Make the ONE persistent RenderStepped connection for persistentFrame.
-- (It was svApplyFrame alone before the skin visual pass; the ordering
-- argument is unchanged.)
-- Idempotent: a live connection is kept as-is, never replaced, because a
-- newer connection would dispatch BEFORE (and be overwritten by) the
-- engine's per-play handlers (newest-first dispatch, see 5.8 header).
-- Must run during loader init, before any StartPlay; the call sits right
-- below, ahead of the UI section whose construction can yield.
local function attachSvRender()
    local okC, alive = pcall(function()
        return svRenderConn ~= nil and svRenderConn.Connected == true
    end)
    if okC and alive then return end
    local ok, conn = pcall(function()
        return RunService.RenderStepped:Connect(persistentFrame)
    end)
    if ok then
        svRenderConn = conn
        svRenderBound = true
    else
        svRenderBound = false
        warn("[GakuranChart] SV attach failed: " .. tostring(conn))
    end
end
attachSvRender()

-- The connection lives for the loader's lifetime (cleanup disconnects it);
-- playChart only pre-builds the model.
local function unbindSv()
    stopSv()
    if svRenderConn then
        pcall(function() svRenderConn:Disconnect() end)
        svRenderConn = nil
    end
    svRenderBound = false
end

local function playChart()
    if not currentChart then
        notify("No chart", "Select and load a chart first", true)
        return
    end
    stopSv()   -- drop any previous SV model before starting a new session
    local song, err = buildGameSong(currentChart)
    if not song then
        notify("Audio error", err, true)
        return
    end

    local okA, attrErr = saveAndSetAttributes(currentChart.mode)
    if not okA then
        notify("Character error", attrErr, true)
        return
    end

    if type(currentChart.id) == "string" then
        customCharts[currentChart.id] = currentChart
    end
    injectSong(song)
    createUnderframe(currentChart)

    -- Pre-cache the real audio length so the session lasts the full track
    -- (instead of falling back to "chart end + 3s" and ending early).
    local audioAsset = song.soundIds[currentChart.mode]
    local okCache, audioLen = false, nil
    if chartUtil then
        local pre = nil
        pcall(function() pre = chartUtil.GetCachedSoundLength(audioAsset) end)
        if pre then
            okCache, audioLen = true, pre
        else
            okCache, audioLen = pcall(cacheAudioLength, audioAsset)
        end
    end

    -- If a session is already running, stop it synchronously first: Stop()
    -- writes _carryOverStats, so we must stop BEFORE clearing it or the old
    -- session's score would resume on this play.
    -- IMPORTANT: Stop's view teardown (FadeOutThenDestroy) lands a frame or
    -- two LATER. Starting in the same tick would let StartPlay reuse the
    -- still-alive old view, whose pending Destroy then kills the new
    -- session's note pool too -> every acquire hits a destroyed frame
    -- ("Parent property ... is locked") and NO notes render. So grab the
    -- old view and wait for its teardown (Gui set to nil) to finish first.
    local oldView = nil
    pcall(function()
        local s = service._session
        if type(s) == "table" then oldView = s._view end
    end)
    pcall(function()
        if service:IsPlaying() then service:Stop({ fadeOut = false }) end
    end)
    if type(oldView) == "table" then
        for _ = 1, 40 do   -- ~2s cap; typically resolves in 1-3 frames
            local okG, gui = pcall(function() return oldView.Gui end)
            if not okG or gui == nil then break end
            task.wait(0.05)
        end
    end
    -- Start fresh: don't carry stats from a previous play of this song.
    pcall(function() service._carryOverStats = nil end)

    -- The selected skin is applied GLOBALLY at loader start / on dropdown
    -- change: activateSkin wraps StoredToViewTheme, which every highway
    -- construction goes through - our Play button AND real stage plays.
    -- Here we only report the active skin for the "Now playing" toast.
    local skinApplied = skinState ~= nil

    local okP, playErr = pcall(function()
        service:StartPlay(song.id, song.mode or currentChart.mode, { showCountdown = true })
    end)
    if not okP then
        notify("Play failed", tostring(playErr), true)
        restoreAttributes()
        destroyUnderframe()
        return
    end
    -- SV: pre-build the model for this chart (the frame hook was already
    -- connected at loader init; wheel/stage starts build theirs lazily on
    -- the first frame instead).
    stopSv()
    local svCount = 0
    local okSv, svErr = pcall(function()
        local m = buildSvModel(currentChart, song)
        svModel = m
        svModelId = song.id
        if m then svCount = #m.pts end
    end)
    if not okSv then
        stopSv()
        warn("[GakuranChart] SV setup failed: " .. tostring(svErr))
    end
    notify("Now playing", song.title .. " - " .. song.artist
        .. (skinApplied and skinState and (" [" .. tostring(skinState.name) .. "]") or "")
        .. (svCount > 0 and (" [SV " .. svCount .. "]") or ""))
    if playStatusCallback then
        playStatusCallback("Playing: " .. song.title .. (okCache and audioLen and (" (" .. math.floor(audioLen) .. "s audio)") or ""))
    end
end

local stopRequested = false

local function stopChart()
    stopRequested = true
    pcall(function() service:Stop({ fadeOut = true }) end)
    -- Prevent score carry-over into the next play of this song.
    pcall(function() service._carryOverStats = nil end)
    pcall(stopSv)
    -- NOTE: the skin stays active - it is global for the loader's lifetime.
    restoreAttributes()
    destroyUnderframe()
    if playStatusCallback then playStatusCallback("Stopped") end
end

-- Watch for natural song end to clean up local state.
-- IMPORTANT: do NOT restore attributes while the results screen is still
-- shown — restoring PlayingInstrument to nil triggers the service's
-- stopIfInvalidContext listener, which calls Stop() and destroys the
-- results screen. Wait for _hasRhythmSurface() to go false AND the
-- results screen to be dismissed (or a timeout), then clean up.
local function surfaceStillUp()
    local ok, up = pcall(function()
        return (service._session ~= nil) or (service._view ~= nil)
            or (service._resultsScreen ~= nil)
    end)
    return ok and up
end

task.spawn(function()
    local wasPlaying = false
    while task.wait(0.5) do
        if _G.GakuranChartGen ~= MYGEN then return end   -- superseded by a re-execution
        local okI, playing = pcall(function() return service:IsPlaying() end)
        playing = okI and playing or false
        if wasPlaying and not playing then
            -- Song ended (natural or manual). Wait for the service to fully
            -- release its surface + results screen before touching attributes.
            local deadline = os.clock() + 120   -- results screen can stay up a while
            while surfaceStillUp() and os.clock() < deadline and not stopRequested do
                if _G.GakuranChartGen ~= MYGEN then return end
                -- Bail out if a new song started during the wait (e.g. the user
                -- hit Play again, or a real song began): leave attributes alone.
                local okP2, playing2 = pcall(function() return service:IsPlaying() end)
                if okP2 and playing2 then break end
                task.wait(0.5)
            end
            if _G.GakuranChartGen ~= MYGEN then return end
            local okP3, playing3 = pcall(function() return service:IsPlaying() end)
            if not (okP3 and playing3) then
                restoreAttributes()
                destroyUnderframe()
                pcall(stopSv)
                if playStatusCallback and not stopRequested then
                    playStatusCallback("Song finished")
                end
            end
            stopRequested = false
        elseif playing then
            stopRequested = false
        end
        wasPlaying = playing
    end
end)

----------------------------------------------------------------
-- 6. UI (Rayfield)
----------------------------------------------------------------
local Rayfield = loadstring(fn.readfile("ui/Rayfield.lua"))()

local Window = Rayfield:CreateWindow({
    Name = "GakuranChart v" .. VERSION,
    LoadingTitle = "GakuranChart",
    LoadingSubtitle = "custom charts for the rhythm minigame",
    ConfigurationSaving = { Enabled = false },
    Discord = { Enabled = false },
    KeySystem = false,
})

local Tab = Window:CreateTab("Charts", 4483362458)
local TabOpt = Window:CreateTab("Options", 4483362458)

Tab:CreateSection("Chart Library")
local chartNames = {}
local pathByName = {}
local function refreshChartList()
    chartNames = {}
    pathByName = {}
    for _, f in ipairs(listChartFiles()) do
        local name = f:match("([^/\\]+)%.json$") or f
        table.insert(chartNames, name)
        pathByName[name] = f
    end
    if #chartNames == 0 then
        table.insert(chartNames, "(no charts found)")
    end
    return chartNames
end

local infoLabel
local chartDropdown = Tab:CreateDropdown({
    Name = "Charts in GakuranCharts/Charts",
    Options = refreshChartList(),
    CurrentOption = nil,
    MultiSelection = false,
    Callback = function(option)
        local name = type(option) == "table" and option[1] or option
        local path = pathByName[name]
        if not path then return end
        local chart, err = readChart(path)
        if not chart then
            notify("Chart error", err, true)
            currentChart, currentChartPath = nil, nil
            return
        end
        currentChart, currentChartPath = chart, path
        if infoLabel then
            infoLabel:Set(
                ("%s\n%s | %s BPM | %s notes | %s keys%s"):format(
                    chart.title .. " - " .. (chart.artist or ""),
                    chart.mode, tostring(chart.bpm), tostring(#chart.charts[chart.mode]),
                    tostring((chart.mode == "Guitar") and 2 or 4),
                    ((chart._droppedNotes or 0) > 0)
                        and ("  (" .. chart._droppedNotes .. " invalid notes dropped)") or ""
                )
            )
        end
        notify("Chart loaded", chart.title)
    end,
})

Tab:CreateButton({
    Name = "Refresh chart list",
    Callback = function()
        local okR, errR = pcall(function()
            local opts = refreshChartList()
            chartDropdown:Refresh(opts)
            if settings.showInWheel then
                injectAllCharts()  -- pick up newly added chart files
            end
            notify("Refreshed", #opts .. " chart(s) found")
        end)
        if not okR then notify("Refresh error", tostring(errR), true) end
    end,
})

infoLabel = Tab:CreateLabel("No chart loaded")

Tab:CreateSection("Playback")
Tab:CreateButton({
    Name = "Play chart",
    Callback = function()
        local okB, errB = pcall(playChart)
        if not okB then notify("Play error", tostring(errB), true) end
    end,
})
Tab:CreateButton({
    Name = "Stop",
    Callback = function()
        local okB, errB = pcall(stopChart)
        if not okB then notify("Stop error", tostring(errB), true) end
    end,
})

local statusLabel = Tab:CreateLabel("Idle")
playStatusCallback = function(text)
    pcall(function() statusLabel:Set(text) end)
end

TabOpt:CreateSection("Calibration")
TabOpt:CreateSlider({
    Name = "Audio offset (ms, + = audio later)",
    Range = { -500, 500 },
    Increment = 5,
    Suffix = "ms",
    CurrentValue = settings.offsetMs or 0,
    Callback = function(value)
        settings.offsetMs = value
        saveSettings()
    end,
})

TabOpt:CreateSection("Background")
local bgToggle = TabOpt:CreateToggle({
    Name = "Enable background",
    CurrentValue = settings.bgEnabled or false,
    Callback = function(value)
        settings.bgEnabled = value
        saveSettings()
        if not value then destroyUnderframe() end
    end,
})
TabOpt:CreateSlider({
    Name = "Background dim (%)",
    Range = { 0, 100 },
    Increment = 5,
    CurrentValue = math.clamp((settings.bgTransparency or 0) * 100, 0, 100),
    Callback = function(value)
        settings.bgTransparency = value / 100
        saveSettings()
    end,
})
TabOpt:CreateColorPicker({
    Name = "Background color (no image fallback)",
    Color = Color3.fromRGB(settings.bgColor[1] or 0, settings.bgColor[2] or 0, settings.bgColor[3] or 0),
    Callback = function(color)
        settings.bgColor = { math.floor(color.R * 255), math.floor(color.G * 255), math.floor(color.B * 255) }
        saveSettings()
    end,
})

TabOpt:CreateSection("Integration")
TabOpt:CreateToggle({
    Name = "Show custom songs in the song wheel",
    CurrentValue = settings.showInWheel or false,
    Callback = function(value)
        settings.showInWheel = value
        saveSettings()
        local okI, errI = pcall(function()
            if value then
                local n = injectAllCharts()
                notify("Song wheel", n .. " custom chart(s) listed (hold an instrument to see them)")
            else
                removeFromWheel()
                notify("Song wheel", "Custom songs hidden from the wheel")
            end
        end)
        if not okI then notify("Wheel error", tostring(errI), true) end
    end,
})

TabOpt:CreateSection("osu!mania skin")
local skinPacks = listSkinPacks()
local skinNames = { "Game default" }
local skinByName = {}
for _, man in ipairs(skinPacks) do
    table.insert(skinNames, man.name)
    skinByName[man.name] = man
end
local skinDropdown
do
    local initial = "Game default"
    if type(settings.skin) == "string" and skinByName[settings.skin] then
        initial = settings.skin
        selectedSkinManifest = skinByName[settings.skin]
    else
        settings.skin = ""
    end
    skinDropdown = TabOpt:CreateDropdown({
        Name = "Note skin (applies everywhere while loaded)",
        Options = skinNames,
        CurrentOption = initial,
        MultiSelection = false,
        Callback = function(option)
            local name = type(option) == "table" and option[1] or option
            local okA, errA = pcall(function()
                if name == "Game default" then
                    settings.skin = ""
                    selectedSkinManifest = nil
                    deactivateSkin()
                elseif skinByName[name] then
                    settings.skin = name
                    selectedSkinManifest = skinByName[name]
                    activateSkin(skinByName[name])
                end
            end)
            if not okA then notify("Skin error", tostring(errA), true) end
            saveSettings()
        end,
    })
end
-- Apply the selected skin NOW: the StoredToViewTheme wrap injects it into
-- every highway the game builds (our Play button and real stage plays
-- alike) until the loader is removed.
if selectedSkinManifest then
    local okS, errS = pcall(activateSkin, selectedSkinManifest)
    if not okS or not skinState then
        warn("[GakuranChart] Skin '" .. tostring(settings.skin) .. "' failed to activate: " .. tostring(errS))
    end
end
TabOpt:CreateButton({
    Name = "Refresh skin list",
    Callback = function()
        local okR, errR = pcall(function()
            skinPacks = listSkinPacks()
            skinNames = { "Game default" }
            skinByName = {}
            for _, man in ipairs(skinPacks) do
                table.insert(skinNames, man.name)
                skinByName[man.name] = man
            end
            skinDropdown:Refresh(skinNames)
            if settings.skin ~= "" and skinByName[settings.skin] then
                -- re-apply so freshly regenerated packs load without a re-exec
                selectedSkinManifest = skinByName[settings.skin]
                pcall(activateSkin, selectedSkinManifest)
                notify("Skins", #skinPacks .. " pack(s), skin re-applied")
            else
                notify("Skins", #skinPacks .. " pack(s) found in " .. SKINS_DIR)
            end
        end)
        if not okR then notify("Refresh error", tostring(errR), true) end
    end,
})
TabOpt:CreateLabel("Convert osu! skins with tools/osu2skin.py")

TabOpt:CreateSection("Info")
TabOpt:CreateLabel("Workspace folder: " .. FOLDER)
TabOpt:CreateLabel("Drop .json charts in Charts/, audio in Audio/")
TabOpt:CreateLabel("Convert osu! maps with tools/osu2gakuran.py")

----------------------------------------------------------------
-- 7. Re-execution cleanup + programmatic API
----------------------------------------------------------------
local function isOurSessionPlaying()
    local ok, yes = pcall(function()
        local sess = service._session
        if not sess then return false end
        local p = nil
        if type(sess.GetPlayable) == "function" then
            local okG, got = pcall(sess.GetPlayable, sess)
            if okG then p = got end
        end
        if type(p) ~= "table" then p = sess._playable end
        if type(p) ~= "table" then return false end
        local id = p.id or p.songId
        return id ~= nil and customIds[id] == true
    end)
    return ok and yes == true
end

_G.GakuranChartCleanup = function()
    local playing = false
    pcall(function() playing = service:IsPlaying() end)
    if playing and isOurSessionPlaying() then
        pcall(function() service:Stop({ fadeOut = false }) end)
        pcall(function() service._carryOverStats = nil end)
        playing = false
    end
    -- Always restore the skin baseline (even if a play is active): the
    -- wrap + shape write are client-side only and the next loader instance
    -- re-applies its own selection right after this cleanup runs.
    pcall(deactivateSkin)
    pcall(unbindSv)
    if not playing then
        pcall(restoreAttributes)
        pcall(destroyUnderframe)
    end
    pcall(function()
        if Rayfield and type(Rayfield.Destroy) == "function" then Rayfield:Destroy() end
    end)
end

_G.GakuranChart = {
    version = VERSION,
    list = listChartFiles,
    load = function(path)
        local chart, err = readChart(path)
        if chart then
            currentChart, currentChartPath = chart, path
        end
        return chart, err
    end,
    play = playChart,
    stop = stopChart,
    current = function() return currentChartPath end,
    skins = listSkinPacks,
    sv = function()
        if svModel then return #svModel.pts end
        return 0
    end,
    -- Introspection for the console: why is (or isn't) SV active?
    svStatus = function()
        local sess = service._session
        local p = type(sess) == "table" and sess._playable or nil
        local id = type(p) == "table" and (p.id or p.songId) or nil
        return {
            bound = svRenderBound,
            disabled = svDisabled,
            errors = svFrameErrors,
            modelId = svModelId,
            points = svModel and #svModel.pts or 0,
            sessionCustom = id ~= nil and customIds[id] == true or false,
            perspective = type(sess) == "table" and sess._perspective == true or false,
        }
    end,
    -- Introspection for the console: is the skin visual pass alive?
    visStatus = function()
        local touched = 0
        for _ in pairs(visTouched) do touched += 1 end
        local ss = skinState
        local tapLanes = 0
        if ss and type(ss.tapImgs) == "table" then
            for _ in pairs(ss.tapImgs) do tapLanes += 1 end
        end
        return {
            bound = svRenderBound,
            disabled = visDisabled,
            errors = visFrameErrors,
            writes = visWrites,
            touchedViews = touched,
            skin = ss and ss.name or nil,
            holdHead = ss and ss.hasHoldHead or false,
            pressed = ss and ss.hasPressed or false,
            tapLanes = tapLanes,
        }
    end,
    setSkin = function(name)
        if name == nil or name == "" or name == "Game default" then
            settings.skin = ""
            selectedSkinManifest = nil
            deactivateSkin()
        else
            for _, man in ipairs(listSkinPacks()) do
                if man.name == name then
                    settings.skin = name
                    selectedSkinManifest = man
                    pcall(activateSkin, man)
                    saveSettings()
                    return name
                end
            end
            return nil, "no such skin: " .. tostring(name)
        end
        saveSettings()
        return settings.skin
    end,
}

-- List every custom chart in the game's song wheel right away (if enabled);
-- the wheel refreshes from the registry on each open.
if settings.showInWheel then
    local okW, wheelCount = pcall(injectAllCharts)
    if okW and wheelCount > 0 then
        notify("Song wheel", wheelCount .. " custom chart(s) listed (hold an instrument to see them)")
    end
end

notify("GakuranChart loaded", "Welcome " .. (player.DisplayName or player.Name))
