--[[
    GakuranChart v1.0
    Custom chart system for the (学乱) Gakuran rhythm minigame.
    Revival/remake of FunkyChart v1.23 (by accountrevived) for a different game.

    How it works:
      - Custom charts are JSON files in  GakuranCharts/Charts  (executor workspace)
      - Audio/images live in            GakuranCharts/Audio / GakuranCharts/Assets
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

local player = Players.LocalPlayer
local VERSION = "1.0"
local FOLDER = "GakuranCharts"
local CHARTS_DIR = FOLDER .. "/Charts"
local AUDIO_DIR = FOLDER .. "/Audio"
local ASSETS_DIR = FOLDER .. "/Assets"
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
    savedAttributes = {
        PlayingInstrument = char:GetAttribute("PlayingInstrument"),
        ItemEquipped = char:GetAttribute("ItemEquipped"),
    }
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

local playStatusCallback = nil   -- set by UI to update a status label

local function playChart()
    if not currentChart then
        notify("No chart", "Select and load a chart first", true)
        return
    end
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

    injectSong(song)
    createUnderframe(currentChart)

    local okP, playErr = pcall(function()
        service:StartPlay(song.id, song.mode or currentChart.mode, { showCountdown = true })
    end)
    if not okP then
        notify("Play failed", tostring(playErr), true)
        restoreAttributes()
        destroyUnderframe()
        return
    end
    notify("Now playing", song.title .. " - " .. song.artist)
    if playStatusCallback then
        playStatusCallback("Playing: " .. song.title)
    end
end

local stopRequested = false

local function stopChart()
    stopRequested = true
    pcall(function() service:Stop({ fadeOut = true }) end)
    restoreAttributes()
    destroyUnderframe()
    if playStatusCallback then playStatusCallback("Stopped") end
end

-- watch for natural song end to clean up local state
task.spawn(function()
    local wasPlaying = false
    while task.wait(0.5) do
        local okI, playing = pcall(function() return service:IsPlaying() end)
        playing = okI and playing or false
        if wasPlaying and not playing then
            restoreAttributes()
            destroyUnderframe()
            if playStatusCallback and not stopRequested then
                playStatusCallback("Song finished")
            end
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
        infoLabel:Set(
            ("%s\n%s | %s BPM | %s notes | %s key%s%s"):format(
                chart.title .. " - " .. (chart.artist or ""),
                chart.mode, tostring(chart.bpm), tostring(#chart.charts[chart.mode]),
                (chart.mode == "Guitar") and 2 or 4,
                chart._droppedNotes > 0 and ("  (" .. chart._droppedNotes .. " invalid notes dropped)") or ""
            )
        )
        notify("Chart loaded", chart.title)
    end,
})

Tab:CreateButton({
    Name = "Refresh chart list",
    Callback = function()
        local opts = refreshChartList()
        chartDropdown:Refresh(opts)
        notify("Refreshed", #opts .. " chart(s) found")
    end,
})

infoLabel = Tab:CreateLabel("No chart loaded")

Tab:CreateSection("Playback")
Tab:CreateButton({
    Name = "Play chart",
    Callback = playChart,
})
Tab:CreateButton({
    Name = "Stop",
    Callback = stopChart,
})

local statusLabel = Tab:CreateLabel("Idle")
playStatusCallback = function(text)
    statusLabel:Set(text)
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
    end,
})

TabOpt:CreateSection("Info")
TabOpt:CreateLabel("Workspace folder: " .. FOLDER)
TabOpt:CreateLabel("Drop .json charts in Charts/, audio in Audio/")
TabOpt:CreateLabel("Convert osu! maps with tools/osu2gakuran.py")

notify("GakuranChart loaded", "Welcome " .. (player.DisplayName or player.Name))
