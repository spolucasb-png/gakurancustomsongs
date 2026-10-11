--[[
    GakuranChart v2.0.28
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
local VERSION = "2.0.28"
local FOLDER = "GakuranCharts"
local CHARTS_DIR = FOLDER .. "/Charts"
local AUDIO_DIR = FOLDER .. "/Audio"
local ASSETS_DIR = FOLDER .. "/Assets"
local SKINS_DIR = FOLDER .. "/Skins"
local SETTINGS_FILE = FOLDER .. "/Settings.json"
local SCORES_FILE = FOLDER .. "/Scores.json"

----------------------------------------------------------------
-- 0. Executor capability check
----------------------------------------------------------------
local function requireFn(name)
    if type(_G[name]) == "function" then return _G[name] end
    if type(getfenv) == "function" then
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

-- HK holds the hook-ownership and UI-rollback helpers (one local instead of
-- a dozen; see section 1 for the hook side).
local HK = { cleaned = false, safetyDone = false }

-- Destroy Rayfield windows. Rayfield itself only renames old ones to
-- "Rayfield-Old" and leaves them behind.
function HK.sweepRayfield()
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
end

-- Fallback for older versions that didn't register a cleanup fn:
-- destroy any previous Rayfield window and our old underframe.
pcall(HK.sweepRayfield)
pcall(function()
    local gui = player:FindFirstChildOfClass("PlayerGui")
    if gui then
        for _, g in ipairs(gui:GetChildren()) do
            if g.Name == "GakuranChartUnderframe" or g.Name == "GakuranChartDifficulty" or g.Name == "GakuranChartStageExit" then
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

-- Resolve many targets in ONE pass. getgc(true) walks the whole Luau heap, and
-- the loader used to call gcFind nine times at startup - nine full heap sweeps
-- for nine tables. Each predicate drops out of the running set the moment it
-- matches, so a value is only tested against targets still missing, and the
-- scan returns early once everything is found.
--
-- Match semantics are identical to nine separate gcFind calls: iteration order
-- over getgc(true) is the same, so each target still binds to the first table
-- that satisfies its predicate. No pcall here, deliberately: the predicates
-- only ever type()/rawget() a table, which cannot error, and a pcall per
-- predicate per heap value would cost more than the passes this saves.
local function gcScan(specs)
    local out, pending = {}, 0
    for _ in pairs(specs) do pending += 1 end
    if pending == 0 then return out end
    for _, v in next, fn.getgc(true) do
        if type(v) == "table" then
            for name, pred in pairs(specs) do
                if out[name] == nil and pred(v) then
                    out[name] = v
                    pending -= 1
                    if pending == 0 then return out end
                end
            end
        end
    end
    return out
end

-- Every table the loader looks up on the heap, found in a single sweep.
-- Sections 1, 5.5 and 5.7 read their target out of GC instead of scanning
-- again; gcFind stays available for anything that has to look later.
local GC = gcScan({
    service = function(t)
        return type(rawget(t, "StartPlay")) == "function" and type(rawget(t, "Get")) == "function"
            and type(rawget(t, "Stop")) == "function"
    end,
    stats = function(t) return type(rawget(t, "SubmitStats")) == "function" end,
    relay = function(t)
        return type(rawget(t, "QueryJamSync")) == "function" and type(rawget(t, "FireStart")) == "function"
    end,
    difficulty = function(t)
        return type(rawget(t, "Key")) == "function" and type(rawget(t, "Resolve")) == "function"
            and type(rawget(t, "Tiers")) == "table"
    end,
    wheelKit = function(t)
        return type(rawget(t, "tier")) == "function" and type(rawget(t, "textW")) == "function"
            and type(rawget(t, "ink")) == "function"
    end,
    chartUtil = function(t)
        return type(rawget(t, "CacheSoundLength")) == "function"
            and type(rawget(t, "resolvePlayable")) == "function"
    end,
    noteSprites = function(t)
        return type(rawget(t, "Shapes")) == "table" and type(rawget(t, "Tails")) == "table"
            and type(rawget(t, "GetShape")) == "function" and type(rawget(t, "GetTail")) == "function"
    end,
    themeSettings = function(t)
        return type(rawget(t, "StoredToViewTheme")) == "function"
            and type(rawget(t, "SanitizeAssetId")) == "function"
    end,
    noteShapeHost = function(t)
        return type(rawget(t, "GetNoteShape")) == "function"
            and type(rawget(t, "GetViewTheme")) == "function"
    end,
    viewClass = function(t)
        return type(rawget(t, "new")) == "function" and type(rawget(t, "GetLaneXAt")) == "function"
            and type(rawget(t, "SetLaneSpacing")) == "function"
    end,
})

local serviceClass = GC.service
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
-- Multi-difficulty parents: songId -> { id, song, mode, label, diffs = { {chart, density}, ... } }.
-- One registry/wheel row per song; the difficulty picker (StartPlay hook) opens
-- on click. Rebuilt by injectAllCharts; instance-local, never shared via _G.
local parents = {}

-- Hook ownership. The three safety nets wrap game functions and the loader can
-- be executed many times in one client, so the wrappers are owned by a shared
-- base in _G that survives re-execution:
--   * ONE stable wrapper per hook, created once and never wrapped again, so a
--     new execution cannot stack on a previous GakuranChart wrapper.
--   * A wrapper holds only the shared guard set and its own base record, never
--     a loader instance's tables, so nothing from a dead instance is retained.
--   * The genuine original is recovered by peeling stale GakuranChart wrappers
--     (left by loader versions that predate this base) off the slot.
--   * Cleanup restores a slot only while OUR wrapper is what is installed.
local HOOK_BASE_VERSION = 2
local hookBase = _G.GakuranChartHookBase
if type(hookBase) ~= "table" or hookBase.version ~= HOOK_BASE_VERSION then
    -- Older layout: its saved "originals" may themselves be stale wrappers.
    hookBase = { version = HOOK_BASE_VERSION }
    _G.GakuranChartHookBase = hookBase
end
if type(hookBase.ids) ~= "table" then hookBase.ids = {} end
local guardIds = hookBase.ids   -- song ids that must never reach the originals

function HK.upvals(f)
    local ok, u = pcall(function() return (getupvalues or (debug :: any).getupvalues)(f) end)
    if ok and type(u) == "table" then return u end
    return nil
end

function HK.source(f)
    local ok, s = pcall(function() return (debug :: any).info(f, "s") end)
    return ok and tostring(s) or ""
end

-- Executor-compiled code (as opposed to a game ModuleScript function)? Game
-- functions run in an environment whose `script` is their ModuleScript;
-- executor chunks have none. The "[string" chunk name is a second signal.
function HK.isExecutorChunk(f)
    if HK.source(f):find("^%[string") then return true end
    local okE, env = pcall(getfenv, f)
    if okE and type(env) == "table" then
        local okS, sc = pcall(function() return env.script end)
        return okS and typeof(sc) ~= "Instance"
    end
    return false
end

-- Is f a wrapper left in a slot by an older GakuranChart execution? Those are
-- executor-compiled chunks with exactly two upvalues: a pure {string = true}
-- guard set and the function they wrap. Returns the wrapped function, or nil.
-- Our own stable wrappers never match (their second upvalue is a table), and
-- foreign wrappers do not have this shape, so they are never peeled.
function HK.legacyInner(f)
    if type(f) ~= "function" then return nil end
    if not HK.isExecutorChunk(f) then return nil end
    local u = HK.upvals(f)
    if not u then return nil end
    local guardTbl, inner, n = nil, nil, 0
    for _, v in pairs(u) do
        n += 1
        if type(v) == "table" then
            guardTbl = v
        elseif type(v) == "function" then
            inner = v
        end
    end
    if n ~= 2 or guardTbl == nil or inner == nil then return nil end
    for k, v in pairs(guardTbl) do
        if type(k) ~= "string" or v ~= true then return nil end
    end
    return inner
end

function HK.unwrapLegacy(f)
    for _ = 1, 32 do
        local inner = HK.legacyInner(f)
        if not inner then break end
        f = inner
    end
    return f
end

-- Is `target` reachable from `top` through function upvalues (i.e. does top
-- wrap target)? Bounded: depth 6, 200 visited functions.
function HK.chainContains(top, target, depth, seen)
    depth = depth or 0
    seen = seen or { n = 0 }
    if type(top) ~= "function" or seen[top] or depth > 6 or seen.n > 200 then return false end
    if top == target then return true end
    seen[top] = true
    seen.n += 1
    local u = HK.upvals(top)
    if not u then return false end
    for _, v in pairs(u) do
        if type(v) == "function" and HK.chainContains(v, target, depth + 1, seen) then
            return true
        end
    end
    return false
end

-- Install (or re-use) our stable wrapper for mod[key]. `rev` (optional) is
-- the wrapper-BODY revision. The execution that first creates a record owns
-- its wrapper body for the life of the client, so an edited body would never
-- go live on re-execution. When the stored rev differs, the body is rebuilt in
-- place, and only while our own wrapper is what the slot holds: still ONE
-- wrapper (never stacked), same b.under, every record field kept. Beneath a
-- foreign wrapper it is left alone - that chain is not ours to rewrite.
function HK.ensure(name, mod, key, makeWrap, rev)
    local b = hookBase[name]
    if type(b) ~= "table" or b.mod ~= mod or b.key ~= key
        or type(b.orig) ~= "function" or type(b.wrap) ~= "function" then
        local orig = HK.unwrapLegacy(mod[key])
        b = { mod = mod, key = key, orig = orig, under = orig, rev = rev }
        b.wrap = makeWrap(b)
        hookBase[name] = b
    elseif rev ~= nil and b.rev ~= rev then
        local slot = mod[key]
        if slot == b.wrap then
            b.wrap = makeWrap(b)
            mod[key] = b.wrap
            b.rev = rev
        elseif not HK.chainContains(slot, b.wrap) then
            b.wrap = makeWrap(b)   -- slot no longer holds us; reinstalled below
            b.rev = rev
        else
            warn("[GakuranChart] " .. tostring(name) .. " wrapper is beneath a foreign wrapper; keeping its existing body (rev " .. tostring(b.rev) .. ")")
        end
    end
    local cur = mod[key]
    if cur == b.wrap or HK.chainContains(cur, b.wrap) then
        return b   -- already installed, directly or beneath another component's wrapper
    end
    b.under = HK.unwrapLegacy(cur)
    mod[key] = b.wrap
    return b
end

-- Custom songs are never submitted, but the stats the engine hands over are
-- real, so the live instance records them locally instead of dropping them
-- (section 5.97). The handler lives on the base RECORD, exactly like
-- b.handler on StartPlay: the wrapper closes over its record only, so a
-- retired instance is never called, and a wrapper left behind by a deferred
-- restore degrades to a pure guard. submitRev exists because a wrapper body is
-- created once per client - without it, a client already holding a v2 base
-- from an earlier loader version would keep the old body and silently record
-- nothing.
HK.submitRev = 1
function HK.makeSubmit(b)
    return function(songId, ...)
        if guardIds[songId] then
            local h = b.scoreHandler
            if h then pcall(h, songId, ...) end
            return
        end
        return b.under(songId, ...)
    end
end

function HK.makeQuery(b)
    return function(songId, ...)
        if guardIds[songId] then return false, nil end
        return b.under(songId, ...)
    end
end

function HK.makeFire(b)
    return function(payload, ...)
        if type(payload) == "table" and guardIds[payload.SongId] then return end
        return b.under(payload, ...)
    end
end

-- Safety net 1: never submit scores for custom songs
local statsMod = GC.stats
if statsMod then
    HK.ensure("SubmitStats", statsMod, "SubmitStats", HK.makeSubmit, HK.submitRev)
end

-- Safety net 2: never query jam sync / fire amp relay for custom songs
local relayMod = GC.relay
if relayMod then
    HK.ensure("QueryJamSync", relayMod, "QueryJamSync", HK.makeQuery)
    HK.ensure("FireStart", relayMod, "FireStart", HK.makeFire)
end

-- Optional "customs only" song-wheel filter. Same ownership discipline, but
-- this one reads instead of blocking: when the flag is on it returns a NEW
-- array holding only ledger-owned songs, otherwise the game's array passes
-- through untouched. The wrapper closes over its base record only (plus _G
-- at call time) - never chunk-local settings or the ledger local - so it
-- stays correct across re-executions. Toggle state lives on the record
-- (b.customsOnly), synced from settings at startup and by the UI toggle.
function HK.makeSongFilter(b)
    return function(self, mode, ...)
        local list = b.under(self, mode, ...)
        if type(list) ~= "table" then return list end
        if not b.customsOnly then return list end
        -- Fail open: if the registry or ledger can't be read, show
        -- everything rather than an empty wheel.
        local okR, reg = pcall(function() return b.mod._registry end)
        local byId = (okR and type(reg) == "table") and reg._byId or nil
        local lg = _G.GakuranChartLedger
        local owned = (type(lg) == "table" and lg.owned) or nil
        if type(byId) ~= "table" or type(owned) ~= "table" then return list end
        local out = {}
        for _, info in ipairs(list) do
            local song = (type(info) == "table" and byId[info.id]) or nil
            if type(song) == "table" and owned[song] then out[#out + 1] = info end
        end
        if #out == 0 and not b.emptyNoticed then
            b.emptyNoticed = true
            -- notify() is declared further down; warn directly so this
            -- wrapper never depends on a not-yet-declared local.
            pcall(warn, "[GakuranChart] Song wheel: customs-only filter is on, but no custom songs are listed for this instrument")
        end
        return out
    end
end
HK.ensure("ListPlayableSongInfosForHeld", service, "ListPlayableSongInfosForHeld", HK.makeSongFilter)

-- Star badges ("★5.32") on single-difficulty custom songs. The wheel colours a
-- row's difficulty badge through RhythmDifficulty.Key(text) -> tier, which is
-- grey (Unrated) for anything it does not know. This wrapper maps a star
-- label to the tier of the same density band as starRating (easy<2, medium<3,
-- hard<4, extreme<5, insane above) and passes every other input straight
-- through, so the game's own songs are untouched. Closes over its record
-- only, like the other wrappers.
function HK.makeDiffKey(b)
    return function(s, ...)
        if type(s) == "string" then
            local n = tonumber(s:match("^★(%d+%.?%d*)$"))
            if n then
                return n < 2 and "easy" or n < 3 and "medium" or n < 4 and "hard"
                    or n < 5 and "extreme" or "insane"
            end
        end
        return b.under(s, ...)
    end
end
local diffMod = GC.difficulty
if diffMod then
    HK.ensure("DiffKey", diffMod, "Key", HK.makeDiffKey)
else
    warn("[GakuranChart] RhythmDifficulty not found - star badges will be grey")
end

-- The wheel skins do not print the raw difficulty text: they call
-- RhythmWheelKit.tier(text) and draw its .word, which is the tier WORD
-- ("EXTREME") looked up from the Key above. For a star label we keep the tier
-- colour / rank / ink and show the label itself ("★5.32") as the word. Every
-- other input (all of the game's own songs) goes straight to the original.
function HK.makeDiffTier(b)
    return function(s, ...)
        local r = b.under(s, ...)
        if type(s) == "string" and type(r) == "table" and s:match("^★%d+%.?%d*$") then
            local c = {}
            for k, v in pairs(r) do c[k] = v end
            c.word = s
            return c
        end
        return r
    end
end
local kitMod = GC.wheelKit
if kitMod then
    HK.ensure("DiffTier", kitMod, "tier", HK.makeDiffTier)
else
    warn("[GakuranChart] RhythmWheelKit not found - star badges will read as tier words")
end

-- Difficulty-picker hook on service.StartPlay (every wheel row, search row and
-- stage start goes through it). For one of OUR multi-difficulty parent songs the
-- call is swallowed and the loader's picker opens instead; everything else - all
-- real game songs, legacy single charts, the picker's own start (b.bypass) -
-- reaches the original with the exact original arguments. The wrapper closes
-- over its base record only; the live loader instance registers its handler on
-- the record (b.handler) and clears it in cleanup, so a retired instance is
-- never called and a wrapper left behind (deferred restore) is a pure
-- pass-through.
function HK.makeStartPlay(b)
    return function(self, songId, ...)
        local h = b.handler
        if h and not b.bypass then
            local okH, swallow = pcall(h, songId, ...)
            if okH and swallow == true then return end
        end
        return b.under(self, songId, ...)
    end
end
HK.ensure("StartPlay", service, "StartPlay", HK.makeStartPlay)

-- 4K+ (more than 4 lanes). The engine itself is lane-count generic; what is
-- hard-coded to 2/4 is the lane count (RhythmChartUtil.resolvePlayable), the
-- key map, the hint labels and the view theme, and all four are looked up
-- through module tables, so four stable wrappers cover it (same discipline as
-- above: each closes over its own record only). Only OUR songs can ask for
-- more than 4 lanes (song.gakuranLanes, set by buildGameSong); every other
-- input - all of the game's own songs - reaches the original untouched. The
-- live loader instance puts the player's keys on the records (b.keyNames /
-- b.hintLabels) and clears them in cleanup, so a retired instance is never
-- called. Verified by hand in a probe before this was written: a 7-lane song
-- starts and runs with exactly a lanes override and an extended theme.
HK.maxLanes = 7

function HK.makeResolve(b)
    return function(song, mode, ...)
        local p = b.under(song, mode, ...)
        if type(song) == "table" and type(p) == "table" then
            local n = song.gakuranLanes
            if type(n) == "number" and n > 4 then p.lanes = n end
        end
        return p
    end
end

-- Stock GetViewTheme(n > 4) errors (the stored theme only has 2- and 4-lane
-- colour arrays). For n > 4 build the view theme from a copy of the stored
-- theme whose 4-lane arrays are cycled up to n, through the module's CURRENT
-- StoredToViewTheme (so an active skin still applies).
function HK.makeViewTheme(b)
    return function(self, n, ...)
        local tm = b.themeMod
        if type(n) == "number" and n > 4 and type(tm) == "table" and type(self) == "table" then
            if not self._hydrated then pcall(self.HydrateFromServer, self) end
            local stored = self._theme
            if type(stored) == "table" then
                local s2 = {}
                for k, v in pairs(stored) do s2[k] = v end
                for _, key in ipairs({ "noteIn4", "noteOut4", "recBorder4", "recPress4" }) do
                    local src = stored[key]
                    if type(src) == "table" then
                        local ext = {}
                        for i = 1, n do ext[i] = src[((i - 1) % 4) + 1] end
                        s2[key] = ext
                    end
                end
                return tm.StoredToViewTheme(s2, n)
            end
        end
        return b.under(self, n, ...)
    end
end

function HK.makeHintLabels(b)
    return function(self, n, ...)
        local f = b.hintLabels
        if type(n) == "number" and n > 4 and type(f) == "function" then
            local ok, labels = pcall(f, n)
            if ok and type(labels) == "table" and #labels == n then return labels end
        end
        return b.under(self, n, ...)
    end
end

-- The service fills a song's keyMapOverride from this getter only when the
-- song has none, so answering for n > 4 here covers every start (Rayfield Play,
-- wheel, picker) and reads the player's CURRENT keys each time.
function HK.makeKeyMap(b)
    return function(self, n, ...)
        local f = b.keyNames
        if type(n) == "number" and n > 4 and type(f) == "function" then
            local ok, names = pcall(f, n)
            if ok and type(names) == "table" and #names == n then
                local map, good = {}, true
                for lane = 1, n do
                    local okC, code = pcall(function() return Enum.KeyCode[names[lane]] end)
                    if okC and code then map[code] = lane else good = false end
                end
                if good then return map end
            end
        end
        return b.under(self, n, ...)
    end
end

do
    local cu, sm = GC.chartUtil, GC.noteShapeHost
    if cu and type(rawget(cu, "resolvePlayable")) == "function" then
        HK.ensure("ResolvePlayable", cu, "resolvePlayable", HK.makeResolve)
    else
        warn("[GakuranChart] RhythmChartUtil not found - charts with more than 4 lanes will be refused")
    end
    if sm and type(rawget(sm, "GetViewTheme")) == "function" then
        HK.ensure("ViewTheme", sm, "GetViewTheme", HK.makeViewTheme)
        local vb = hookBase["ViewTheme"]
        if type(vb) == "table" then vb.themeMod = GC.themeSettings end
        if type(rawget(sm, "GetKeyboardHintLabels")) == "function" then
            HK.ensure("HintLabels", sm, "GetKeyboardHintLabels", HK.makeHintLabels)
        end
        if type(rawget(sm, "GetKeyboardKeyMap")) == "function" then
            HK.ensure("KeyMap", sm, "GetKeyboardKeyMap", HK.makeKeyMap)
        end
    else
        warn("[GakuranChart] RhythmSettingsClient not found - charts with more than 4 lanes will be refused")
    end
end

-- Lane pitch for n > 4. The view spreads a FIXED total width (screen width *
-- LANE_SPACING_MULTIPLIER * laneSpacing) over the lane count, so 7 lanes get
-- ~57% of the 4-lane pitch while notes keep their size (80 px) and neighbours
-- overlap. RhythmView.new(lanes, duration, testTools, theme, hints, laneSpacing,
-- ...): for n > 4 scale laneSpacing by n/4 (same pitch as 4K), capped so the
-- track never exceeds 3.0 (0.9 of the screen). Purely cosmetic: if the view
-- class is not found, plays still work.
function HK.makeViewNew(b)
    return function(lanes, ...)
        local a = table.pack(...)
        local sp = a[5]
        if type(lanes) == "number" and lanes > 4 and type(sp) == "number" and sp > 0 then
            a[5] = math.min(sp * lanes / 4, math.max(sp, 3.0))
        end
        return b.under(lanes, table.unpack(a, 1, a.n))
    end
end
do
    local vc = GC.viewClass
    if vc and type(rawget(vc, "new")) == "function" then
        HK.ensure("ViewNew", vc, "new", HK.makeViewNew)
    else
        warn("[GakuranChart] RhythmView not found - charts with more than 4 lanes will use the stock lane pitch")
    end
end

-- True once every piece a >4-lane play needs is wired.
function HK.lanesSupported()
    local r, v, k = hookBase["ResolvePlayable"], hookBase["ViewTheme"], hookBase["KeyMap"]
    return type(r) == "table" and type(v) == "table" and type(v.themeMod) == "table"
        and type(k) == "table" and type(k.keyNames) == "function"
end

----------------------------------------------------------------
-- Wheel-native difficulty submenu (multi-difficulty parent rows).
-- The guitar submenu's CONTENT is hard-coded and unusable, but the wheel's
-- PAGE SYSTEM is generic: _applySongMenu renders the guitar page when
-- _guitarVariantSongId is set, else the song list. We add a third page the
-- same way - our own pending flag checked first by a wrapper on
-- _applySongMenu - so difficulty selection lives inside the wheel (Back
-- returns to the list, picks get the native flash + select sound). The
-- standalone overlay stays as the fallback when the wheel controller can't
-- be driven. The controller is the t_8 singleton (one per client); it is
-- found by a structural getgc scan and revalidated on every use. Only one
-- wheel method is wrapped, under the same ownership discipline; Close is
-- deliberately NOT wrapped (nothing wheel-side needs clearing - the pending
-- flag lives on our base record with a timestamp, so Toggle-close can never
-- stick it).
----------------------------------------------------------------
local wheelCtl = nil   -- cached wheel controller, revalidated per use
local wheelLastScan = -1e18
-- force=true bypasses the rescan gate (user-triggered paths where a few
-- seconds are acceptable); init and diagnostics use the gated call
local function findWheelController(force)
    local function usable(c)
        -- regular indexing: the singleton instance inherits these methods
        -- from its class through a metatable (rawget would miss them)
        if type(c) ~= "table" then return false end
        local okM, m = pcall(function() return c._applySongMenu end)
        local okS, s = pcall(function() return c._setSlot end)
        local okO, o = pcall(function() return c.Open end)
        local okT, t = pcall(function() return c._transitionPage end)
        local okC, cl = pcall(function() return c.Close end)
        local okL, li = pcall(function() return c._applySongListMenu end)
        return okM and type(m) == "function" and okS and type(s) == "function"
            and okO and type(o) == "function" and okT and type(t) == "function"
            and okC and type(cl) == "function" and okL and type(li) == "function"
    end
    if usable(wheelCtl) then return wheelCtl end
    wheelCtl = nil
    -- getgc enumeration misses under load; a scan that just ran and missed is
    -- not worth repeating immediately (callers retry on later clicks anyway)
    if os.time() - wheelLastScan < 20 and not force then return nil end
    wheelLastScan = os.time()
    -- The class table carries the same method names as own fields but no
    -- instance state; the singleton instance has both. Match the instance.
    for _, v in ipairs(getgc(true)) do
        if type(v) == "table" then
            local okU, st = pcall(rawget, v, "_uiState")
            local okO, op = pcall(rawget, v, "_isOpen")
            if okU and type(st) == "string" and okO and type(op) == "boolean" and usable(v) then
                wheelCtl = v
                break
            end
        end
    end
    return wheelCtl
end

-- Forward declaration: the list-page wrapper below calls it, but the body
-- lives further down (it needs sourceIconAsset). Assigned before any render
-- can run; the wheelRev bump rebuilds live records onto the new body anyway.
local paintWheelSourceIcons

-- List-page wrapper: pending valid + per-run renderer present -> our submenu
-- page; otherwise clear any stale flag and run the game's list renderer. (An
-- earlier revision wrapped the whole router and skipped its prologue and
-- epilogue; wrapping the list page keeps _ensureGui, the search refresh, the
-- header deco and _notifyFocus native.) Closes over the base record only, so
-- it stays correct across re-executions. A render stores the wheel's
-- transition token; any close/reopen bumps it, so a stale pending can never
-- stick the menu even if an explicit clear is missed. The 30 s wall-clock
-- expiry is the backstop.
function HK.makeWheelListMenu(b)
    return function(self, ...)
        local pend = b.pendingSongId
        local render = b.renderMenu
        local okT, tok = pcall(function() return self._transitionToken end)
        local tokMatch = okT and b.pendingToken ~= nil and tok == b.pendingToken
        local fresh = (os.time() - (b.pendingAt or 0)) < 30
        if type(pend) == "string" and type(render) == "function"
            and (tokMatch or (b.pendingToken == nil and fresh)) then
            local okR, did = pcall(render, self, pend)
            if okR and did == true then
                if okT then b.pendingToken = tok end
                b.renderCount = (b.renderCount or 0) + 1
                -- submenu slots reuse the list page's frames: sweep any icons
                -- the base page left behind (synchronous: render set slots now)
                paintWheelSourceIcons(self, false)
                return
            end
        end
        b.pendingSongId = nil
        local res = table.pack(b.under(self, ...))
        -- base list just rendered: paint our rows' source icons on a defer.
        -- the first Open proved the apply finishes during the transition
        -- tween (slots/V may not exist yet when under returns: 0 icons on a
        -- synchronous paint, 8/8 one open later), so paint after the call
        -- returns and once more shortly after. pcall-guarded no-op on
        -- unfamiliar skins; never touches the return values.
        task.defer(function()
            paintWheelSourceIcons(self, true)
            task.wait(0.5)
            paintWheelSourceIcons(self, true)
        end)
        return table.unpack(res, 1, res.n)
    end
end
-- Search-results renderer wrapper: search rows reuse the same slot frames
-- (a stale list-page icon would otherwise stand beside the wrong song), so
-- the same sweep-and-paint runs here. Same discipline: record-only upvalues,
-- deferred (results may settle after the call returns), returns untouched.
function HK.makeWheelSearchRender(b)
    return function(self, ...)
        local res = table.pack(b.under(self, ...))
        task.defer(function()
            paintWheelSourceIcons(self, true)
            task.wait(0.5)
            paintWheelSourceIcons(self, true)
        end)
        return table.unpack(res, 1, res.n)
    end
end
HK.searchRev = 1
-- Wrapper-body revision for the WheelMenu hook: bump whenever
-- HK.makeWheelListMenu changes, or a client that already holds a record keeps
-- running the OLD body (rev 1 = first body that counts renders).
HK.wheelRev = 5
do
    local c = findWheelController()
    -- getgc(true) enumeration is non-deterministic: five identical scans in a
    -- row returned 4, 4, 0, 4, 4 hits with nothing changed, so a single miss at
    -- init is common (~2 in 10 reloads). Retry a few times, forced past the
    -- rescan gate, before falling back to the overlay. Stop early if a newer
    -- re-execution has taken over (generation bumped).
    local tries = 0
    while not c and tries < 3 and _G.GakuranChartGen == MYGEN do
        tries = tries + 1
        task.wait(0.25)
        c = findWheelController(true)
    end
    if c then
        HK.ensure("WheelMenu", c, "_applySongListMenu", HK.makeWheelListMenu, HK.wheelRev)
        HK.ensure("WheelSearch", c, "_renderSearchResults", HK.makeWheelSearchRender, HK.searchRev)
    elseif _G.GakuranChartGen == MYGEN then
        warn("[GakuranChart] Wheel controller not found - difficulty picker falls back to overlay")
    end
    local wb = hookBase["WheelMenu"]
    if type(wb) == "table" then wb.pendingSongId = nil; wb.pendingToken = nil end
end

-- Discover + wrap on demand (init-time discovery can miss under load; the
-- trigger path completes the wiring on first use). HK.ensure is idempotent:
-- same controller reuses the record, a changed one rebuilds it.
local function armWheelMenu()
    findWheelController(true)
    if wheelCtl then
        HK.ensure("WheelMenu", wheelCtl, "_applySongListMenu", HK.makeWheelListMenu, HK.wheelRev)
        HK.ensure("WheelSearch", wheelCtl, "_renderSearchResults", HK.makeWheelSearchRender, HK.searchRev)
    end
    local wb = hookBase["WheelMenu"]
    if type(wb) == "table" then
        if HK.renderWheelSubmenu then
            wb.renderMenu = HK.renderWheelSubmenu
        end
        return wb
    end
    return nil
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
    customsOnly = false,   -- song wheel shows only custom songs (needs showInWheel)
    skin = "",   -- selected osu!mania skin pack name ("" = game default)
    keys = {},   -- 4K+ key names per lane count: keys["5"] = { "S", "D", ... }
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
for _, dir in ipairs({ FOLDER, CHARTS_DIR, AUDIO_DIR, ASSETS_DIR, SKINS_DIR }) do
    if not fn.isfolder(dir) then pcall(fn.makefolder, dir) end
end
loadSettings()

-- "Customs only" needs customs listed: force showInWheel on (the toggles
-- below keep the two consistent at runtime the same way). The filter flag
-- on the shared hook record follows settings, not the other way round.
if settings.customsOnly and not settings.showInWheel then
    settings.showInWheel = true
    saveSettings()
end
do
    local b = hookBase["ListPlayableSongInfosForHeld"]
    if type(b) == "table" then b.customsOnly = settings.customsOnly == true end
end

-- 4K+ key bindings. settings.keys["5".."7"] = array of KeyCode names, one per
-- lane. A missing, unknown, duplicated or unusable list falls back to the
-- defaults for that lane count as a whole. The defaults avoid K: Rayfield's own
-- default toggle key is K (read from ui/Rayfield.lua, not yet seen live).
HK.defaultKeys = {
    [5] = { "S", "D", "Space", "J", "L" },
    [6] = { "S", "D", "F", "J", "L", "Semicolon" },
    [7] = { "S", "D", "F", "Space", "J", "L", "Semicolon" },
}
HK.shortKey = {
    Semicolon = ";", Comma = ",", Period = ".", Slash = "/", Space = "Spc",
    Return = "Ent", LeftShift = "LS", RightShift = "RS", Tab = "Tab",
}

function HK.usableKey(name)
    if type(name) ~= "string" or name == "" or name == "Unknown" or name == "Escape" then
        return false
    end
    local ok, code = pcall(function() return Enum.KeyCode[name] end)
    return ok and code ~= nil and code ~= Enum.KeyCode.Unknown
end

function HK.cleanKeys(n, list)
    if type(list) == "table" and #list == n then
        local seen, good = {}, true
        for i = 1, n do
            local k = list[i]
            if not HK.usableKey(k) or seen[k] then good = false break end
            seen[k] = true
        end
        if good then
            local out = {}
            for i = 1, n do out[i] = list[i] end
            return out
        end
    end
    local d, out = HK.defaultKeys[n] or {}, {}
    for i = 1, n do out[i] = d[i] or "Unknown" end
    return out
end

-- Called by the hook wrappers at the start of a play (n = lane count).
function HK.keyNamesFor(n)
    local stored = type(settings.keys) == "table" and settings.keys[tostring(n)] or nil
    return HK.cleanKeys(n, stored)
end

function HK.hintLabelsFor(n)
    local names, out = HK.keyNamesFor(n), {}
    for i = 1, n do out[i] = HK.shortKey[names[i]] or names[i] end
    return out
end

-- Hand the live instance's providers to the shared records (cleanup clears
-- them again, but only while they are still ours).
for _, nm in ipairs({ "KeyMap", "HintLabels" }) do
    local r = hookBase[nm]
    if type(r) == "table" then
        r.keyNames = HK.keyNamesFor
        r.hintLabels = HK.hintLabelsFor
    end
end

----------------------------------------------------------------
-- 3. Chart loading
----------------------------------------------------------------
-- Assigned by buildUI() once Rayfield exists (and cleared by cleanup).
-- Until then - and if the UI build fails - notifications stay warn-only.
local uiNotify = nil

local function notify(title, body, isError)
    warn(("[GakuranChart] %s: %s"):format(title, body))
    -- pcall: a Rayfield API change must never turn a message into an error.
    if uiNotify then pcall(uiNotify, title, body, isError) end
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

-- Source game tags (session 7): which engine a chart comes from (osu, local,
-- future converters). The game wheel has no icon slot, so the origin travels
-- as a short title prefix on wheel rows; our own UI adds true ImageLabels
-- where it owns the GUI (overlay) and text tags elsewhere. Placed here (ahead
-- of readChart/buildGameSong) so both can close over these locals.
local SOURCE_TAGS = { osu = "[osu!]", ["local"] = "[local]", etterna = "[etterna]", quaver = "[quaver]" }
local function chartSource(chart)
    local s = type(chart) == "table" and type(chart.source) == "string" and chart.source or ""
    s = s:lower():gsub("[^%w]", "")
    return s ~= "" and s or "unknown"
end
local function sourceTag(chart)
    return SOURCE_TAGS[chartSource(chart)] or "[custom]"
end
-- Icon asset for a source id, or nil when the PNG is not installed yet.
-- Graceful by design: callers fall back to the text tag, so missing files
-- never break a row. Expected path: GakuranCharts/Assets/icons/<source>.png
local function sourceIconAsset(src)
    local ok, asset = pcall(function()
        local path = FOLDER .. "/Assets/icons/" .. src .. ".png"
        if fn.isfile(path) then return fn.getlocalasset(path) end
        return nil
    end)
    if ok then return asset end
    return nil
end

-- Wheel-row source icons (session 7): after a game renderer builds rows,
-- tag OUR rows (title prefix) with a small icon beside the right cluster.
-- Home depends on the row shape, all runtime-derived and pcall-guarded:
-- a visible real badge -> child of the Diff frame (rides hover tweens, fixed
-- gap left of the frame, verified 6.8px / 11.4px-follow live); badgeless rows
-- (parents: Diff frame exists but hidden, 15px) -> child of Len (which always
-- shows the duration); missing Len -> Root at the badge zone. An unfamiliar
-- skin simply gets no icon. Sweep covers all three homes every pass, so a
-- slot reused by another page (submenu, search) never keeps a stale icon.
paintWheelSourceIcons = function(self, doAdd)
    local okS, slots = pcall(function() return self._slots end)
    if not (okS and type(slots) == "table") then return end
    for _, s in ipairs(slots) do
        pcall(function()
            if type(s) ~= "table" then return end
            local lab = tostring(s.Label or "")
            local src = lab:match("^%[osu!%]") and "osu"
                or lab:match("^%[local%]") and "local"
                or lab:match("^%[etterna%]") and "etterna"
                or lab:match("^%[quaver%]") and "quaver"
                or lab:match("^%[custom%]") and "unknown" or nil
            local V = s.V
            local root = type(V) == "table" and V.Root or nil
            local diff = type(V) == "table" and V.Diff or nil
            local len = type(V) == "table" and V.Len or nil
            local function killAll()
                if typeof(root) == "Instance" then
                    local o = root:FindFirstChild("GakuranSrcIcon")
                    if o then o:Destroy() end
                end
                if typeof(diff) == "Instance" then
                    local o = diff:FindFirstChild("GakuranSrcIcon")
                    if o then o:Destroy() end
                end
                if typeof(len) == "Instance" then
                    local o = len:FindFirstChild("GakuranSrcIcon")
                    if o then o:Destroy() end
                end
            end
            if not src or not doAdd then killAll() return end
            local home, pos = nil, nil
            if typeof(diff) == "Instance" and diff.Visible == true
                and diff.AbsoluteSize.X >= 30
                and diff.Position.X.Scale == 1 then
                home, pos = diff, UDim2.new(0, -6, 0.5, 0)
            elseif typeof(len) == "Instance" and len.Visible == true then
                home, pos = len, UDim2.new(0, -6, 0.5, 0)
            elseif typeof(root) == "Instance" then
                home, pos = root, UDim2.new(1, -20, 0.5, 0)
            else
                killAll() return
            end
            killAll()
            local img = Instance.new("ImageLabel")
            img.Name = "GakuranSrcIcon"
            img.AnchorPoint = Vector2.new(1, 0.5)
            img.Position = pos
            img.Size = UDim2.fromOffset(16, 16)
            img.BackgroundTransparency = 1
            img.BorderSizePixel = 0
            local iconAsset = sourceIconAsset(src)
            if type(iconAsset) == "string" then img.Image = iconAsset end
            img.Parent = home
        end)
    end
end

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
    -- A Keyboard chart may declare more than 4 lanes ("lanes": 5..7, written by
    -- the converter when it does not fold); the 4K+ hooks make those playable.
    local lanes = (data.mode == "Guitar") and 2 or 4
    local declared = math.floor(tonumber(data.lanes) or 0)
    if declared > 4 and data.mode == "Keyboard" then
        if declared > HK.maxLanes then
            return nil, ("Chart needs %d lanes; this loader supports up to %d"):format(declared, HK.maxLanes)
        end
        lanes = declared
    end
    data._laneCount = lanes
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
    -- The converter emits sorted notes, but hand-made/hand-edited charts may
    -- not be. Strict weak ordering (beat, then lane) keeps table.sort valid
    -- even when two notes share both.
    table.sort(cleaned, function(x, y)
        if x.b ~= y.b then return x.b < y.b end
        return x.l < y.l
    end)
    data.charts[data.mode] = cleaned
    data._droppedNotes = dropped
    -- origin engine tag (additive; the converter writes it, hand-made charts
    -- may lack it). Normalised once here so every consumer sees one shape.
    if type(data.source) ~= "string" or data.source == "" then
        data.source = "unknown"
    end
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
    -- "Background dim (%)" only ever moved BackgroundTransparency, which an
    -- ImageLabel's pixels ignore - the slider did nothing for maps that ship a
    -- background image. Dim those with a black sheet over the image instead
    -- (same 0 = untouched .. 1 = fully dark scale as the solid-colour path).
    if bg:IsA("ImageLabel") then
        local dim = Instance.new("Frame")
        dim.Name = "Dim"
        dim.BackgroundColor3 = Color3.new(0, 0, 0)
        dim.BackgroundTransparency = math.clamp(1 - (settings.bgTransparency or 0), 0, 1)
        dim.BorderSizePixel = 0
        dim.Size = UDim2.fromScale(1, 1)
        dim.ZIndex = 1
        dim.Parent = bg
    end
    underframeGui = gui
end

----------------------------------------------------------------
-- 5. Play / Stop
----------------------------------------------------------------
-- Instrument-mode override on the character (client-side only; the game
-- itself never writes PlayingInstrument, the server owns it). Tracks what we
-- captured and what we WROTE so the undo can be exact:
--   { char, saved = {PlayingInstrument, ItemEquipped},
--     wrote = {PlayingInstrument, ItemEquipped}, at = os.clock() }
local savedAttributes = nil

local function saveAndSetAttributes(mode)
    local char = player.Character
    if not char then return false, "No character" end
    -- Keep the ORIGINAL values across back-to-back plays on one character; a
    -- respawn starts a fresh capture (never carry values between characters).
    if not savedAttributes or savedAttributes.char ~= char then
        savedAttributes = {
            char = char,
            saved = {
                PlayingInstrument = char:GetAttribute("PlayingInstrument"),
                ItemEquipped = char:GetAttribute("ItemEquipped"),
            },
        }
    end
    -- Guitar/Bass require ItemEquipped == mode; Keyboard/Drums require nil
    local wrote = {
        PlayingInstrument = mode,
        ItemEquipped = (mode == "Guitar" or mode == "Bass") and mode or nil,
    }
    savedAttributes.wrote = wrote
    savedAttributes.at = os.clock()
    char:SetAttribute("PlayingInstrument", wrote.PlayingInstrument)
    char:SetAttribute("ItemEquipped", wrote.ItemEquipped)
    return true
end

-- Undo ONLY what is still our override. The server owns these attributes: if
-- it changed one since we wrote it (the player stood up from a station
-- mid-play and the server cleared PlayingInstrument), writing our captured
-- value back would resurrect a stale "Keyboard" that nothing ever clears
-- again (the character then stays in keyboard animation/controls off-chart).
-- Clearing PlayingInstrument is what actually takes the instrument out of the
-- player's hands: KeyboardClient.evaluateLocal (and the Drums/Piano
-- equivalents) listen on that attribute. But the SAME attribute change also
-- drives three teardown listeners - RhythmServiceClient.stopIfInvalidContext,
-- RhythmWheelServiceClient.recheck and InstrumentServiceClient.sync - and
-- stopIfInvalidContext calls Stop(), which destroys a results screen that is
-- still on display. That coupling is why the loader used to wait for the
-- results screen to go away before restoring, leaving the character holding
-- the keyboard for as long as the end screen was up.
--
-- So suppress just those three for the duration of the write and let every
-- other listener (the ones that do the unequip) see it. Verified in-game: the
-- character unequips immediately on song end AND the results screen survives.
-- Suppressing only stopIfInvalidContext is NOT enough - the screen still died,
-- which is how the other two were found.
--
-- The window is a single frame on our own restore path, and the listeners are
-- re-enabled unconditionally, including when the write throws. Each is matched
-- by the name of the function its Profiled decorator wraps, never by index.
-- Without getconnections the suppression is skipped and the old
-- wait-for-the-results-screen behaviour applies.
local CONTEXT_TEARDOWN = {
    stopIfInvalidContext = true,   -- RhythmServiceClient -> Stop()
    recheck = true,                -- RhythmWheelServiceClient
    sync = true,                   -- InstrumentServiceClient
}

-- The listeners are Profiled(fn) closures, so debug.info on the connection
-- reports the decorator; the real target is the function it captured.
local function wrappedFnName(f)
    if type(f) ~= "function" then return nil end
    local u = HK.upvals(f)
    if not u then return nil end
    local found
    for _, v in pairs(u) do
        if type(v) == "function" then
            local okN, nm = pcall(function() return (debug :: any).info(v, "n") end)
            if okN and type(nm) == "string" and nm ~= "" and nm ~= "Profiled"
                and nm ~= "profilebegin" then
                found = nm
            end
        end
    end
    return found
end

-- Run writeFn with the teardown listeners off. Returns how many were
-- suppressed (0 = none found / unavailable, so callers can still decide to
-- wait for the results screen the old way).
local function withContextTeardownSuppressed(char, writeFn)
    local getconns = requireFn("getconnections")
    if type(getconns) ~= "function" then
        writeFn()
        return 0
    end
    local picked = {}
    for _, attr in ipairs({ "PlayingInstrument", "ItemEquipped" }) do
        local okC, conns = pcall(function()
            return getconns(char:GetAttributeChangedSignal(attr))
        end)
        if okC and type(conns) == "table" then
            for _, c in ipairs(conns) do
                local nm = wrappedFnName(c.Function)
                if nm and CONTEXT_TEARDOWN[nm] then table.insert(picked, c) end
            end
        end
    end
    for _, c in ipairs(picked) do pcall(function() c:Disable() end) end
    local okW, errW = pcall(writeFn)
    for _, c in ipairs(picked) do pcall(function() c:Enable() end) end
    if not okW then
        warn("[GakuranChart] attribute restore errored: " .. tostring(errW))
    end
    return #picked
end

-- A respawned character carries none of our writes, so it is left alone.
local function restoreAttributes()
    local st = savedAttributes
    if not st then return end
    savedAttributes = nil
    local char = player.Character
    if not char or char ~= st.char then return end
    withContextTeardownSuppressed(char, function()
        for _, k in ipairs({ "PlayingInstrument", "ItemEquipped" }) do
            pcall(function()
                if char:GetAttribute(k) == st.wrote[k] then
                    char:SetAttribute(k, st.saved[k])
                end
            end)
        end
    end)
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
        -- source tag travels in the title: the game wheel renders rows itself
        -- and offers no icon slot, so a prefix is the only lever on its rows.
        -- Rayfield/submenu read the chart tables directly and tag at their own
        -- display sites, so they are unaffected by this prefix.
        title = sourceTag(chart) .. " " .. (chart.title or chart.id),
        artist = chart.artist or "",
        charter = chart.charter or "",
        gakuranSource = chartSource(chart),
        bpm = chart.bpm,
        animationbpm = chart.animationbpm or chart.bpm,
        animationBpmChanges = chart.animationBpmChanges,
        startAt = tonumber(chart.startAt) or 0,
        -- Global calibration (Options slider) plus the chart's own correction.
        -- chart.offsetMs is written by the converter and documented in the
        -- README, but used to be dropped on the floor here.
        offsetMs = (settings.offsetMs or 0) + (tonumber(chart.offsetMs) or 0),
        approach = tonumber(chart.approach) or 5,
        charts = { [mode] = chart.charts[mode] },
        soundIds = { [mode] = audioAsset },
        difficulty = chart.difficulty or { [mode] = "Custom" },
    }
    local laneCount = tonumber(chart._laneCount) or 4
    if laneCount > 4 then
        if not HK.lanesSupported() then
            return nil, ("Chart needs %d lanes but the 4K+ hooks are not installed"):format(laneCount)
        end
        song.gakuranLanes = laneCount
    end
    if type(chart.backgroundFile) == "string" and fn.isfile(chart.backgroundFile) then
        local okB, asset = pcall(fn.getlocalasset, chart.backgroundFile)
        if okB and asset then
            song.coverId = asset
        end
    end
    return song
end

-- Registry ownership ledger. injectSong used to overwrite _byId[id] blindly
-- and cleanup could not tell our entries from the game's. Every song we put
-- in the registry is now recorded (shared through _G, so a later loader
-- execution can still undo what an earlier one did) together with the real
-- game entry it shadowed, if any. Ownership is by object identity.
local LG = {}
LG.ledger = _G.GakuranChartLedger
if type(LG.ledger) ~= "table" or LG.ledger.version ~= 1 then
    LG.ledger = { version = 1, recs = {}, owned = setmetatable({}, { __mode = "k" }) }
    _G.GakuranChartLedger = LG.ledger
end

-- _byId / _list of the live registry (nil if unavailable). Records describing
-- a different registry object are dropped.
function LG.tables()
    local reg = service._registry
    if type(reg) ~= "table" or type(reg._byId) ~= "table" or type(reg._list) ~= "table" then
        return nil
    end
    local L = LG.ledger
    if L.reg ~= reg then
        L.reg = reg
        L.recs = {}
        L.owned = setmetatable({}, { __mode = "k" })
    end
    return reg._byId, reg._list
end

-- Is this registry entry ours? Normally by identity (the ledger). The second
-- branch only recognises leftovers of loader runs that predate the ledger: it
-- applies only to ids we manage and only when EVERY sound is a local executor
-- asset (rbxasset://...). Shipped game songs use rbxassetid://, so a real
-- game entry is never claimed here. Having soundIds / a charter / a long
-- snake_case id proves nothing and is not used.
function LG.isOurs(s)
    if type(s) ~= "table" then return false end
    if LG.ledger.owned[s] then return true end
    if not customIds[s.id] or type(s.soundIds) ~= "table" then return false end
    local any = false
    for _, v in pairs(s.soundIds) do
        if type(v) ~= "string" or not v:find("^rbxasset://") then return false end
        any = true
    end
    return any
end

local function injectSong(song, noList)
    local byId, list = LG.tables()
    if not byId then error("song registry unavailable") end
    local L = LG.ledger
    local id = song.id
    customIds[id] = true
    guardIds[id] = true   -- guard first, then publish the song

    -- What real game entry (if any) are we shadowing? Never one of ours.
    local rec = L.recs[id]
    local displaced, displacedIdx
    if rec then displaced, displacedIdx = rec.displaced, rec.displacedIdx end
    if displaced == nil then
        local cur = byId[id]
        if cur ~= nil and cur ~= song and not LG.isOurs(cur) then displaced = cur end
        for i, s in ipairs(list) do
            if type(s) == "table" and s.id == id and s ~= song and not LG.isOurs(s) then
                if displaced == nil then displaced = s end
                if s == displaced then displacedIdx = i end
                break
            end
        end
    end

    byId[id] = song
    local listed = false
    if settings.showInWheel and not noList then
        local genuine = false
        for _, s in ipairs(list) do
            if type(s) == "table" and s.id == id and s ~= song and not LG.isOurs(s) then
                genuine = true
                break
            end
        end
        -- Replace our own earlier/stale entry in place; never duplicate an id
        -- and never touch a real game entry (it stays in the wheel).
        for i = #list, 1, -1 do
            local s = list[i]
            if type(s) == "table" and s.id == id and (s == song or LG.isOurs(s)) then
                if genuine or listed then
                    table.remove(list, i)
                else
                    list[i] = song
                    listed = true
                end
            end
        end
        if not listed and not genuine then
            table.insert(list, song)
            listed = true
        end
    end

    if rec and rec.song ~= song then L.owned[rec.song] = nil end
    L.owned[song] = true
    L.recs[id] = { song = song, displaced = displaced, displacedIdx = displacedIdx, listed = listed }
end

-- The game's song wheel rebuilds its list on every open from
-- registry:List(), filtered to the instrument the character holds
-- (hasPlayableChartForHeld: the song needs a non-empty charts[mode]).
-- Our charts are Keyboard mode, so they show up while a keyboard is
-- equipped. injectSong previously only ran when a chart was PLAYED,
-- so the wheel never listed anything else - inject them all instead.
-- Charts that share a songId (written by tools/osu2gakuran.py) become ONE
-- wheel row: the parent song, with the difficulties inside it (a Rayfield
-- play still registers the picked difficulty by id for the session, but it
-- never gets its own wheel row). Clicking the row opens the difficulty
-- picker (StartPlay hook, section 5.95). Charts without a songId, and songs
-- with a single chart, stay plain rows exactly as before.
local function chartDensity(c)
    local dur = tonumber(c.duration)
    if not dur or dur <= 0 then dur = 1 end
    return #c.charts[c.mode] / dur
end

-- Easiest -> hardest. `rank` is only a hint (the converter ranks per run, so a
-- later-added difficulty can duplicate one), so it is used only when every
-- member has a distinct rank; otherwise note density decides.
local function sortDiffs(diffs)
    local ranked, seen = true, {}
    for _, d in ipairs(diffs) do
        local r = d.chart.rank
        if type(r) ~= "number" or seen[r] then ranked = false break end
        seen[r] = true
    end
    table.sort(diffs, function(a, b)
        if ranked then return a.chart.rank < b.chart.rank end
        if a.density ~= b.density then return a.density < b.density end
        return a.chart.id < b.chart.id
    end)
end

-- Chart length in seconds: the converter's `duration` when present, else
-- estimated from the last note end (older hand-made charts have no duration;
-- without a fallback they would divide by 1 and read as 9.99 stars).
local function chartSeconds(chart)
    local dur = tonumber(chart.duration)
    if dur and dur > 0 then return dur end
    local notes = type(chart.charts) == "table" and chart.charts[chart.mode] or nil
    local bpm = tonumber(chart.bpm)
    if type(notes) == "table" and bpm and bpm > 0 then
        local last = 0
        for _, n in ipairs(notes) do
            local e = (tonumber(n.b) or 0) + (tonumber(n.d) or 0)
            if e > last then last = e end
        end
        if last > 0 then return last * 60 / bpm end
    end
    return 1
end

-- Decimal star estimate from note density, anchored so whole numbers match
-- the tier-colour bands (easy<2, medium<4, hard<6.5, extreme<9 notes/s).
-- Our own heuristic, shown beside difficulty names - NOT osu! star rating
-- (which is computed by the osu! client and never stored in .osu files).
local function starRating(chart)
    local d = 0
    pcall(function()
        d = #chart.charts[chart.mode] / chartSeconds(chart)
    end)
    local s
    if d < 2 then s = 0.5 + d * 0.75
    elseif d < 4 then s = 2 + (d - 2) * 0.5
    elseif d < 6.5 then s = 3 + (d - 4) * 0.4
    elseif d < 9 then s = 4 + (d - 6.5) * 0.4
    else s = 5 + (d - 9) * 0.3 end
    if s > 9.99 then s = 9.99 end
    return s
end

local function diffName(chart)
    local d = type(chart.difficulty) == "table" and chart.difficulty[chart.mode] or nil
    return type(d) == "string" and d ~= "" and d or "Custom"
end

local function injectAllCharts()
    if not settings.showInWheel then return 0 end
    local count = 0
    table.clear(parents)
    local groups, order = {}, {}
    local function injectSingle(chart)
        local okB, song = pcall(buildGameSong, chart)
        if okB and song then
            -- A single-difficulty custom song gets a star badge ("★5.32")
            -- in the wheel row, like the game's own songs get their tier
            -- badge; HK.makeDiffKey gives it the matching tier colour.
            pcall(function()
                song.difficulty = { [chart.mode] = ("★%.2f"):format(starRating(chart)) }
            end)
            pcall(injectSong, song)
            count += 1
        end
    end
    for _, path in ipairs(listChartFiles()) do
        local okR, chart = pcall(readChart, path)
        if okR and type(chart) == "table" and type(chart.id) == "string" then
            customCharts[chart.id] = chart
            local sid = chart.songId
            if type(sid) == "string" and sid ~= "" then
                if not groups[sid] then
                    groups[sid] = {}
                    order[#order + 1] = sid
                end
                table.insert(groups[sid], { chart = chart, density = chartDensity(chart) })
            else
                injectSingle(chart)
            end
        end
    end
    for _, sid in ipairs(order) do
        local group = groups[sid]
        -- a parent's difficulties must share one instrument mode
        local mode = group[1].chart.mode
        local uniform = true
        for _, d in ipairs(group) do
            if d.chart.mode ~= mode then uniform = false end
        end
        if #group == 1 or not uniform then
            for _, d in ipairs(group) do injectSingle(d.chart) end
        else
            sortDiffs(group)
            local first = group[1].chart
            local okB, song = pcall(buildGameSong, first)
            if okB and song then
                song.id = sid   -- the parent row owns the songId
                local label = { [mode] = ("%d diffs"):format(#group) }
                song.difficulty = label
                customCharts[sid] = first   -- SV facade; re-pointed at pick time
                parents[sid] = { id = sid, song = song, mode = mode, label = label, diffs = group }
                pcall(injectSong, song)
                count += 1
            end
        end
    end
    return count
end

-- Take OUR songs out of the wheel: exact objects we own (plus pre-ledger
-- leftovers, see LG.isOurs). A game entry that merely shares an id stays.
local function removeFromWheel()
    local _, list = LG.tables()
    if type(list) ~= "table" then return end
    for i = #list, 1, -1 do
        if LG.isOurs(list[i]) then
            table.remove(list, i)
        end
    end
    for _, rec in pairs(LG.ledger.recs) do rec.listed = false end
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
local chartUtil = GC.chartUtil

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
-- { shapeKey, head, headHold, receptor, receptorPressed, tapImgs, recImgs,
--   recPressedImgs, hasHoldHead, hasPressed, hasTapVariants, hasRecVariants,
--   origShapes, wrapped }.
-- headHold/receptorPressed always hold a usable asset (they fall back to
-- head/receptor); hasHoldHead/hasPressed say whether the pack really ships
-- a distinct image. tapImgs maps 1-based lanes to tap art (lanes without
-- their own art fall back to head); hasTapVariants says the map is non-empty.
-- recImgs/recPressedImgs do the same for receptors (manifest.receptors).
local skinState = nil
local settingsThemeHosts = {}  -- tables that own a raw _theme with noteShape

do
    local mod = GC.noteShapeHost
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

local noteSpritesMod = GC.noteSprites

local themeSettingsMod = GC.themeSettings

----------------------------------------------------------------
-- 5.7b Skin visual pass: dedicated hold-head, pressed-receptor and
-- per-lane tap art
-- The engine paints a note's Head image ONCE when the view is built
-- (RhythmView: Paint(Head, NoteImage)); PrepareNoteVisual never repaints
-- it, and pooled note frames are recycled between notes. Likewise the
-- receptor image is painted once; SetReceptorPressed only tweens colour
-- and size and records view._receptorPressed[lane]. So, per frame and
-- ONLY for a custom-chart session built under the active skin, we:
--   * give every active hold the pack's dedicated hold-head image, or the
--     lane's tap image when the pack ships no distinct hold head (etterna);
--     every other note gets its lane's tap image (manifest.taps, falling
--     back to the base tap; note.inst -> Head, plus the Backing silhouette
--     and its Band, which the engine painted with the same image);
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
local visRecImgs = setmetatable({}, { __mode = "k" })  -- view -> receptor-art map it was painted with
local visRecPressedImgs = setmetatable({}, { __mode = "k" })  -- view -> pressed-receptor map
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
    local recImgs = visRecImgs[view]
    visRecImgs[view] = nil
    visRecPressedImgs[view] = nil
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
            local want = recImage
            if type(recImgs) == "table" and recImgs[lane] then want = recImgs[lane] end
            paintReceptorImage(view, lane, want)
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
                    -- Holds use the dedicated head when the pack ships one;
                    -- otherwise the lane's tap art (so hold arrows point
                    -- per-lane too); taps use their lane's art, falling back
                    -- to the base tap.
                    local want
                    if (note.len or 0) > 0 then
                        if ss.hasHoldHead then
                            want = holdImage
                        elseif type(tapImgs) == "table" and tapImgs[note.lane] then
                            want = tapImgs[note.lane]
                        else
                            want = holdImage
                        end
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
    if ss.hasPressed or ss.hasRecVariants then
        local pressed = view._receptorPressed
        if type(pressed) == "table" and type(view.Receptors) == "table" then
            local rest, down = ss.receptor, ss.receptorPressed
            local recImgs, recPImgs = ss.recImgs, ss.recPressedImgs
            if not visTouched[view] then visTouched[view] = true end
            visRecImgs[view], visRecPressedImgs[view] = recImgs, recPImgs
            for lane = 1, (tonumber(view._laneCount) or #view.Receptors) do
                local r = (type(recImgs) == "table" and recImgs[lane]) or rest
                local d = (type(recPImgs) == "table" and recPImgs[lane]) or down
                paintReceptorImage(view, lane, pressed[lane] and d or r)
            end
        end
    end
    -- Hit-flash pool clones share the template's base note image (painted once
    -- at view build, always the Up orientation for directional skins), so the
    -- flash on lanes 1/2/4 shows the wrong arrow. Clones keep the template
    -- name; their lane comes from Position.X via view._laneXs. Repaint with
    -- the lane's tap art (same fallback as notes). Our shape registers
    -- Rotation 0, so the engine's per-lane flash rotation is a no-op for us.
    if ss.hasTapVariants then
        local laneXs = view._laneXs
        local root = view._contentRoot
        if type(laneXs) == "table" and typeof(root) == "Instance" then
            local tapImgsF, headF = ss.tapImgs, ss.head
            local kids = nil
            pcall(function() kids = root:GetChildren() end)
            if type(kids) == "table" then
                for _, inst in ipairs(kids) do
                    if inst.Name == "HitFlashTemplate" and inst:IsA("ImageLabel") then
                        local x = inst.Position.X.Offset
                        local best, bestD = 1, nil
                        for i, lx in ipairs(laneXs) do
                            if type(lx) == "number" then
                                local d = math.abs(x - lx)
                                if bestD == nil or d < bestD then best, bestD = i, d end
                            end
                        end
                        local want = (type(tapImgsF) == "table" and tapImgsF[best]) or headF
                        if inst.Image ~= want then
                            paintImage(inst, want)
                            if not visTouched[view] then visTouched[view] = true end
                        end
                    end
                end
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
    -- Optional per-lane receptor art (manifest.receptors / receptorsPressed).
    -- Same fallback rule; lanes without entries use the base images.
    local recImgs, recPressedImgs = {}, {}
    if type(manifest.receptors) == "table" then
        for lane, file in pairs(manifest.receptors) do
            local n = tonumber(lane)
            if n and type(file) == "string" then
                local a = assetOf(file)
                if a then recImgs[n] = a end
            end
        end
    end
    if type(manifest.receptorsPressed) == "table" then
        for lane, file in pairs(manifest.receptorsPressed) do
            local n = tonumber(lane)
            if n and type(file) == "string" then
                local a = assetOf(file)
                if a then recPressedImgs[n] = a end
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
        recImgs = recImgs,
        recPressedImgs = recPressedImgs,
        hasHoldHead = headHoldA ~= nil and headHoldA ~= headA,
        hasPressed = pressedA ~= nil and pressedA ~= recA,
        hasTapVariants = next(tapImgs) ~= nil,
        hasRecVariants = next(recImgs) ~= nil,
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
        recImgs = pack.recImgs,
        recPressedImgs = pack.recPressedImgs,
        hasHoldHead = pack.hasHoldHead,
        hasPressed = pack.hasPressed,
        hasTapVariants = pack.hasTapVariants,
        hasRecVariants = pack.hasRecVariants,
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

-- SV-aware spawn extension (pop-in fix). The engine spawns notes on TIME
-- (spawn = t - lead) but SV repositions them by integral distance, so at
-- rate r a note appears r * (edge distance) from the receptors - for
-- r < ~0.78 it pops in mid-playfield instead of sliding in. We rewrite
-- each note's .spawn to the earlier time when its SV distance equals the
-- visible distance; fast-SV regions keep vanilla spawns via min().
local svSpawnMaxLead = 5    -- max seconds a spawn may move earlier than vanilla
local svSpawnMargin = 0.1    -- extra SV-seconds of distance beyond the screen edge
local svSpawnCap = 400       -- max simultaneously live notes (note pool max is 512)
local svSpawnId = nil        -- song id spawns were computed for
local svSpawnLead = nil      -- sess._spawnLead at compute time
local svSpawnNotes = nil     -- sess._liveNotes table identity at compute time
local svSpawnExt = 0         -- notes spawned earlier than vanilla (diagnostic)
local svSpawnCapped = 0      -- notes clamped by the concurrency cap (diagnostic)
local svSpawnOrderFix = 0    -- order-guard repairs (diagnostic; >0 only with cap cascades)

local function stopSv()
    -- Drops the current model; the bound frame hook rebuilds lazily for
    -- the next custom session. The binding lives until cleanup.
    svModel = nil
    svModelId = nil
    svFrameErrors = 0
    svSpawnId = nil
    svSpawnLead = nil
    svSpawnNotes = nil
    svSpawnExt = 0
    svSpawnCapped = 0
    svSpawnOrderFix = 0
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

-- Invert the piecewise-linear integral: largest ts with I(ts) <= V.
-- Rates are clamped to [0.05, 20], so I is strictly increasing and the
-- inverse is unique. Mirrors svIntegral's implicit rate-1 region before
-- the first change point.
local function svInvertIntegral(m, V)
    local pts = m.pts
    local n = #pts
    if V <= pts[1] then
        return V
    end
    local lo, hi = 1, n -- largest i with prefix[i] <= V
    while lo < hi do
        local mid = (lo + hi + 1) // 2
        if m.prefix[mid] <= V then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return pts[lo] + (V - m.prefix[lo]) / m.rates[lo]
end

-- Rewrite per-note .spawn times so slow-SV notes exist before they become
-- visible. Target: the time ts with I(ts) = I(t) - D/S, where D is the
-- visible SV-distance derived from the engine's own lead
-- (lead = min(approach, (distToEdge + noteSize)/S + 0.15), so
-- (lead - 0.15)*S is the exact edge distance whenever lead < approach).
--   spawn = max(t - maxLead, min(t - lead, ts))
-- min() keeps fast-SV regions (and flat-rate charts) exactly vanilla.
-- Ordering: t - maxLead, t - lead and ts(t) are all non-decreasing in t
-- (dts/dt = rate(t)/rate(ts) > 0), and the engine keeps _liveNotes in t
-- order, so the rewritten list stays sorted - required by the spawn
-- loop's break-on-first-not-due and by lowerBoundSpawn. We never re-sort:
-- _nextSpawn is an index into this array. The concurrency pass below only
-- ever pushes spawns later and each note is also clamped to the previous
-- note's final spawn, so sortedness holds by construction; violations are
-- counted, not tolerated.
-- Runs from the persistent frame (after the engine's step each frame):
-- once per session, and again whenever the engine overwrites .spawn,
-- detected via _spawnLead value or _liveNotes identity (_refreshSpawnLead
-- runs every step but early-outs without writing when the lead is
-- unchanged; _rebuildLiveNotes replaces the table). Only for sessions
-- with an SV model; charts without scrollChanges return before any write.
local function svApplySpawns(sess, m, S)
    local live = sess._liveNotes
    if type(live) ~= "table" then return end
    local id = svModelId
    local lead = sess._spawnLead
    if type(lead) ~= "number" or lead <= 0 then return end
    if svSpawnId == id and svSpawnLead == lead and svSpawnNotes == live then
        return -- clean: engine did not rewrite spawns this frame
    end
    local n = #live
    svSpawnId, svSpawnLead, svSpawnNotes = id, lead, live
    svSpawnExt, svSpawnCapped, svSpawnOrderFix = 0, 0, 0
    if n == 0 then return end
    local D = S * (lead - 0.15) + S * svSpawnMargin
    if D <= 0 then D = S * 0.05 end
    -- ends[]: release times of the placed window, ascending (head pointer
    -- instead of table.remove churn). A placed note counts as live until
    -- t + len + 0.2s (holds stay live to their end; +0.2 covers the hit
    -- window so the cap estimate never undercounts pool use).
    local ends = {}
    local head = 1
    local prev = -1e18
    for i = 1, n do
        local note = live[i]
        local t = note.t
        if type(t) ~= "number" then
            -- Malformed entry (engine notes always carry t): leave its spawn
            -- alone but track it for ordering. Never throw here.
            local kept = note.spawn
            if type(kept) == "number" and kept > prev then prev = kept end
        else
            local vanilla = t - lead
            local ts = svInvertIntegral(m, svIntegral(m, t) - D / S)
            local s = vanilla
            if ts < s then s = ts end
            local floor = t - svSpawnMaxLead
            if s < floor then s = floor end
            if s < vanilla - 1e-9 then svSpawnExt += 1 end
            if s < prev - 1e-9 then
                s = prev
                svSpawnOrderFix += 1
            elseif s < prev then
                s = prev -- float dust; don't count it
            end
            while head <= #ends and ends[head] <= s do
                head += 1
            end
            local pushed = false
            while (#ends - head + 1) >= svSpawnCap do
                s = ends[head]
                pushed = true
                head += 1
                while head <= #ends and ends[head] <= s do
                    head += 1
                end
            end
            if pushed then svSpawnCapped += 1 end
            if s < prev then s = prev end -- cap pushes only move later; keep sorted
            local len = note.len
            local rel = t + (if type(len) == "number" then len else 0) + 0.2
            local j = #ends
            while j >= head and ends[j] > rel do
                ends[j + 1] = ends[j]
                j -= 1
            end
            ends[j + 1] = rel
            note.spawn = s
            prev = s
        end
    end
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
    -- SV-aware spawn extension (pop-in fix): same frame pass, after the
    -- engine's step, so engine overwrites of .spawn are re-applied the
    -- same frame. No-op for flat-rate charts (min() keeps vanilla) and
    -- never runs without a model (early return above), so non-SV charts
    -- keep byte-identical spawn behavior.
    local Sp = sess._scrollPxPerSec
    if type(Sp) == "number" and Sp > 0 then
        svApplySpawns(sess, m, Sp)
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

----------------------------------------------------------------
-- 5.9 Re-execution cleanup.
-- Registered HERE, before the UI is built (the persistent RenderStepped
-- connection above is already live), so a UI failure can never leave a
-- running loader that the next execution cannot clean up.
----------------------------------------------------------------
local Rayfield = nil   -- assigned by buildUI() in section 6

-- Difficulty picker overlay (built in section 5.95). Declared here so cleanup,
-- which is registered earlier than the code that builds the overlay, can drop it.
local pickerGui = nil
local function destroyPicker()
    if pickerGui then
        pcall(function() pickerGui:Destroy() end)
        pickerGui = nil
    end
    -- sweep by name: catches overlays left by older runs (different upvalue)
    pcall(function()
        local pg = player:FindFirstChildOfClass("PlayerGui")
        local ov = pg and pg:FindFirstChild("GakuranChartDifficulty")
        if ov then ov:Destroy() end
    end)
end

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

-- Undo what injectSong did, by ownership:
--   * our songs leave the wheel (exact objects only);
--   * where _byId still holds OUR song, the real game entry we shadowed is put
--     back (or the key is removed when there was none); a slot someone else
--     has since taken over is left alone;
--   * a real entry that was in the wheel and is now missing is re-inserted
--     once (never creating a duplicate id);
--   * stale custom entries from older loader runs under ids we manage are
--     dropped, and replaced by the genuine entry from _list when one exists.
-- customIds is deliberately NOT cleared (the guard set in hookBase.ids is what
-- keeps blocking while a wrapper is installed; it is cleared by HK.restore).
local function removeInjectedSongs()
    local byId, list = LG.tables()
    if not byId then return end
    local L = LG.ledger
    pcall(removeFromWheel)
    for id, rec in pairs(L.recs) do
        if byId[id] == rec.song then
            byId[id] = rec.displaced
        end
        local d = rec.displaced
        if d ~= nil and rec.displacedIdx ~= nil then
            local present, dup = false, false
            for _, s in ipairs(list) do
                if s == d then
                    present = true
                elseif type(s) == "table" and s.id == id then
                    dup = true
                end
            end
            if not present and not dup then
                table.insert(list, math.min(rec.displacedIdx, #list + 1), d)
            end
        end
        L.owned[rec.song] = nil
        L.recs[id] = nil
    end
    for id in pairs(customIds) do
        local cur = byId[id]
        if cur ~= nil and LG.isOurs(cur) then
            local genuine = nil
            for _, s in ipairs(list) do
                if type(s) == "table" and s.id == id and not LG.isOurs(s) then
                    genuine = s
                    break
                end
            end
            byId[id] = genuine
        end
    end
end

-- Put the game's originals back, but only where our wrapper is still the
-- installed function (never clobber a wrapper someone else put on top of
-- ours). Covers SubmitStats / QueryJamSync / FireStart and the song-wheel
-- filter (restoring that one just un-filters the wheel). If another
-- component wraps ours, we stay in its chain and the guard set is kept.
-- Returns true once no wrapper of ours remains installed (then the guard
-- set is cleared, so nothing stale lingers).
function HK.restore()
    local base = _G.GakuranChartHookBase
    if type(base) ~= "table" or base.version ~= HOOK_BASE_VERSION then return true end
    local allGone = true
    for _, name in ipairs({ "SubmitStats", "QueryJamSync", "FireStart", "ListPlayableSongInfosForHeld", "StartPlay", "WheelMenu", "WheelSearch", "DiffKey", "DiffTier",
                          "ResolvePlayable", "ViewTheme", "HintLabels", "KeyMap", "ViewNew" }) do
        local b = base[name]
        if type(b) == "table" and type(b.mod) == "table" and type(b.wrap) == "function" then
            local cur = b.mod[b.key]
            if cur == b.wrap then
                if not pcall(function() b.mod[b.key] = b.under end) then allGone = false end
            elseif HK.chainContains(cur, b.wrap) then
                allGone = false
            end
        end
    end
    if allGone and type(base.ids) == "table" then
        for k in pairs(base.ids) do base.ids[k] = nil end
    end
    return allGone
end

-- Registry + hook rollback, only while no custom session of ours is live.
-- Stop() tears down a frame later, so right after our own Stop this can still
-- be true; then the songs and the wrappers simply stay (guards intact) and a
-- later call, or the next loader execution, finishes the job. Restoring the
-- originals is only safe once our songs are out of the registry/wheel,
-- otherwise a leftover custom song could submit a score with the guard gone.
-- Returns true when done.
function HK.finish()
    if HK.safetyDone then return true end
    if isOurSessionPlaying() then return false end
    pcall(removeInjectedSongs)
    pcall(HK.restore)
    HK.safetyDone = true
    return true
end

-- Idempotent: the first call does the teardown, later calls only retry the
-- safety nets if they were deferred.
_G.GakuranChartCleanup = function()
    if not HK.cleaned then
        HK.cleaned = true
        -- Picker first: stop swallowing StartPlay (the wrapper turns into a pure
        -- pass-through) and drop the overlay before anything else is torn down.
        pcall(function()
            local b = _G.GakuranChartHookBase and _G.GakuranChartHookBase["StartPlay"]
            if type(b) == "table" and b.handler == HK.pickerHandler then
                b.handler = nil
                b.bypass = false
            end
        end)
        pcall(function()
            local wb = _G.GakuranChartHookBase and _G.GakuranChartHookBase["WheelMenu"]
            if type(wb) == "table" and wb.renderMenu == HK.renderWheelSubmenu then
                wb.renderMenu = nil
            end
        end)
        pcall(function()
            local sb = _G.GakuranChartHookBase and _G.GakuranChartHookBase["SubmitStats"]
            if type(sb) == "table" and sb.scoreHandler == HK.scoreHandler then
                sb.scoreHandler = nil   -- a retired instance must not record
            end
        end)
        pcall(function()
            for _, nm in ipairs({ "KeyMap", "HintLabels" }) do
                local kb = _G.GakuranChartHookBase and _G.GakuranChartHookBase[nm]
                if type(kb) == "table" and kb.keyNames == HK.keyNamesFor then
                    kb.keyNames = nil
                    kb.hintLabels = nil
                end
            end
        end)
        pcall(destroyPicker)
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
        pcall(unbindSv)   -- also disconnects the persistent RenderStepped connection
        pcall(HK.sgStop)  -- stage keyboard guard: Space bind, button, watchers
        if not playing then
            pcall(restoreAttributes)
            pcall(destroyUnderframe)
        end
        uiNotify = nil   -- stop notifying through a window we are destroying
        pcall(function()
            if Rayfield and type(Rayfield.Destroy) == "function" then Rayfield:Destroy() end
        end)
    end
    HK.finish()
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
    -- A difficulty of a multi-difficulty parent is registered (so it can play)
    -- but never gets its own wheel row: the parent row already covers it.
    injectSong(song, type(currentChart.songId) == "string" and parents[currentChart.songId] ~= nil)
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

----------------------------------------------------------------
-- 5.95 Difficulty picker (multi-difficulty parent rows)
-- The wheel starts a row with  RhythmServiceClient:Get():StartPlay(id, mode)
-- and closes itself right after the call returns. For one of our parent rows
-- the StartPlay hook swallows that call and runs onStartPlay, which opens this
-- overlay (the wheel is already closing, so the overlay stands alone). Picking
-- a difficulty swaps that chart's data INTO the parent's song object - the
-- same table the registry and the wheel hold, so nothing is re-registered -
-- re-points the SV chart facade, then makes the real StartPlay with the
-- bypass flag set. All of it is synchronous on one thread: no race, nothing
-- to undo (the row label is put back when the session has ended).
----------------------------------------------------------------
local TIER_COLORS = {
    easy = Color3.fromRGB(64, 214, 112),
    medium = Color3.fromRGB(246, 176, 56),
    hard = Color3.fromRGB(240, 78, 62),
    extreme = Color3.fromRGB(178, 82, 240),
    insane = Color3.fromRGB(255, 48, 138),
}
local TIER_UNRATED = Color3.fromRGB(84, 92, 120)

local function tierColor(chart)
    local t = type(chart.tier) == "string" and chart.tier:lower() or ""
    return TIER_COLORS[t] or TIER_UNRATED
end

local function fmtDuration(sec)
    sec = math.max(0, math.floor((tonumber(sec) or 0) + 0.5))
    return ("%d:%02d"):format(sec // 60, sec % 60)
end

-- (starRating / chartSeconds live above diffName, next to injectAllCharts,
-- because single-difficulty wheel rows need them at injection time.)

-- Fields of the parent song object that describe ONE chart.
local SWAP_FIELDS = {
    "title", "artist", "charter", "bpm", "animationbpm", "animationBpmChanges",
    "startAt", "offsetMs", "approach", "charts", "soundIds", "difficulty", "coverId",
    "gakuranLanes", "gakuranSource",
}

local function pickDifficultyInner(parent, d, state)
    state = state or {}
    local chart = d.chart
    local okI, busy = pcall(function() return service:IsPlaying() end)
    if okI and busy then
        notify("Difficulty", "Stop the current song first", true)
        return false
    end
    -- Wheel clicks carry no attribute setup (playChart does this for Rayfield
    -- plays); without PlayingInstrument the engine's StartPlay returns silently.
    local okA, attrErr = saveAndSetAttributes(chart.mode)
    if not okA then
        notify("Character error", attrErr, true)
        return false
    end
    state.attrsSet = true   -- wrapper restores on a throw before StartPlay succeeds
    local fresh, err = buildGameSong(chart)
    if not fresh then
        restoreAttributes()
        notify("Audio error", tostring(err), true)
        return false
    end
    local song = parent.song
    for _, k in ipairs(SWAP_FIELDS) do song[k] = fresh[k] end
    customCharts[parent.id] = chart   -- the SV model is built from this
    stopSv()
    pcall(function() service._carryOverStats = nil end)   -- no score carry-over

    -- Pre-cache the real audio length so the session lasts the full track
    -- (same as playChart; a wheel start would otherwise end at chart end + 3 s).
    local audioAsset = fresh.soundIds[chart.mode]
    if chartUtil and audioAsset then
        local okC, pre = pcall(chartUtil.GetCachedSoundLength, audioAsset)
        if not (okC and pre) then pcall(cacheAudioLength, audioAsset) end
    end

    local b = hookBase["StartPlay"]
    if type(b) == "table" then b.bypass = true end
    local okP, errP = pcall(function()
        service:StartPlay(parent.id, parent.mode, { showCountdown = true })
    end)
    if type(b) == "table" then b.bypass = false end
    if not okP then
        restoreAttributes()
        notify("Play failed", tostring(errP), true)
        return false
    end
    state.started = true   -- from here the play owns the attributes (restored at stop)
    -- Success: drop the submenu state and close the wheel (mirrors the
    -- guitar slots, which StartPlay then Close). No-ops when the wheel is
    -- already closed (overlay/API starts) or unreachable.
    local wb = hookBase["WheelMenu"]
    if type(wb) == "table" then wb.pendingSongId = nil; wb.pendingToken = nil end
    local ctl = findWheelController()
    if ctl then pcall(function() ctl:Close() end) end
    stopSv()
    local okSv, svErr = pcall(function()
        svModel = buildSvModel(chart, song)
        svModelId = song.id
    end)
    if not okSv then
        stopSv()
        warn("[GakuranChart] SV setup failed: " .. tostring(svErr))
    end
    notify("Now playing", ("%s - %s [%s]"):format(song.title, song.artist, diffName(chart)))
    return true
end

-- Re-entrancy guard: the slot handler runs pickDifficulty synchronously, so a
-- second click while the first is still yielding (audio pre-cache on an
-- uncached song) would otherwise swap state twice and start two plays. The
-- busy flag turns the second click into a clean refusal (red flash); the
-- IsPlaying guard still covers plays already running. Reset on every exit,
-- including throws, so the flag can never stick.
local picking = false
local function pickDifficulty(parent, d)
    if picking then return false end
    picking = true
    local state = { attrsSet = false, started = false }
    local ok, res = pcall(pickDifficultyInner, parent, d, state)
    picking = false
    if not ok then
        -- A throw before StartPlay succeeded would leave PlayingInstrument /
        -- ItemEquipped overridden with no play to restore them. After a
        -- successful start the play owns them, so leave them alone.
        if state.attrsSet and not state.started then restoreAttributes() end
        error(res, 0)
    end
    return res
end

local function openPicker(parent)
    destroyPicker()
    local pg = player:FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    local gui = Instance.new("ScreenGui")
    gui.Name = "GakuranChartDifficulty"
    gui.DisplayOrder = 100
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.Parent = pg
    pickerGui = gui

    local function round(inst, px)
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, px)
        c.Parent = inst
    end
    local function text(parentInst, str, size, font, color, pos, sz, align)
        local l = Instance.new("TextLabel")
        l.BackgroundTransparency = 1
        l.Text = str
        l.TextSize = size
        l.Font = font
        l.TextColor3 = color
        l.TextXAlignment = align or Enum.TextXAlignment.Left
        l.TextTruncate = Enum.TextTruncate.AtEnd
        l.Position = pos
        l.Size = sz
        l.Parent = parentInst
        return l
    end

    local shade = Instance.new("TextButton")   -- click outside = close
    shade.Name = "Shade"
    shade.Size = UDim2.fromScale(1, 1)
    shade.BackgroundColor3 = Color3.new(0, 0, 0)
    shade.BackgroundTransparency = 0.45
    shade.BorderSizePixel = 0
    shade.AutoButtonColor = false
    shade.Text = ""
    shade.Parent = gui
    shade.Activated:Connect(destroyPicker)

    local n = #parent.diffs
    local rowH, gap = 54, 8
    local visible = math.min(n, 6)
    local listH = visible * rowH + (visible - 1) * gap
    local panelW = 440
    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.Active = true   -- sink clicks so they don't reach the shade
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.Size = UDim2.fromOffset(panelW, 70 + listH + 12 + 40 + 16)
    panel.BackgroundColor3 = Color3.fromRGB(22, 24, 34)
    panel.BorderSizePixel = 0
    panel.Parent = gui
    round(panel, 10)

    local head = parent.diffs[1].chart
    text(panel, tostring(head.title or parent.id), 22, Enum.Font.GothamBold, Color3.new(1, 1, 1),
        UDim2.fromOffset(16, 10), UDim2.fromOffset(panelW - 32, 28))
    text(panel, tostring(head.artist or ""), 14, Enum.Font.Gotham, Color3.fromRGB(160, 166, 190),
        UDim2.fromOffset(16, 38), UDim2.fromOffset(panelW - 32, 18))

    local list = Instance.new("ScrollingFrame")
    list.Name = "List"
    list.Position = UDim2.fromOffset(16, 70)
    list.Size = UDim2.fromOffset(panelW - 32, listH)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.ScrollBarThickness = n > visible and 4 or 0
    list.CanvasSize = UDim2.fromOffset(0, n * rowH + (n - 1) * gap)
    list.Parent = panel
    local rowW = panelW - 32 - (n > visible and 8 or 0)

    for i, d in ipairs(parent.diffs) do
        local chart = d.chart
        local btn = Instance.new("TextButton")
        btn.Name = "Diff" .. i
        btn.Position = UDim2.fromOffset(0, (i - 1) * (rowH + gap))
        btn.Size = UDim2.fromOffset(rowW, rowH)
        btn.BackgroundColor3 = Color3.fromRGB(34, 37, 52)
        btn.BorderSizePixel = 0
        btn.AutoButtonColor = true
        btn.Text = ""
        btn.Parent = list
        round(btn, 8)
        local bar = Instance.new("Frame")
        bar.Size = UDim2.fromOffset(6, rowH)
        bar.BackgroundColor3 = tierColor(chart)
        bar.BorderSizePixel = 0
        bar.Parent = btn
        round(bar, 3)
        text(btn, string.upper(diffName(chart)), 18, Enum.Font.GothamBold, Color3.new(1, 1, 1),
            UDim2.fromOffset(18, 6), UDim2.fromOffset(rowW - 80, 24))
        -- true source icon when its PNG is installed, else the text tag keeps
        -- the row labelled; either way the row never renders unidentified
        local srcIcon = sourceIconAsset(chartSource(chart))
        if type(srcIcon) == "string" then
            local img = Instance.new("ImageLabel")
            img.Name = "SrcIcon"
            img.Size = UDim2.fromOffset(18, 18)
            img.Position = UDim2.fromOffset(rowW - 26, 6)
            img.BackgroundTransparency = 1
            img.BorderSizePixel = 0
            img.Image = srcIcon
            img.Parent = btn
        else
            text(btn, sourceTag(chart), 13, Enum.Font.GothamBold, Color3.fromRGB(140, 180, 255),
                UDim2.fromOffset(rowW - 70, 6), UDim2.fromOffset(62, 18))
        end
        text(btn, ("%d notes  |  %s  |  %.1f notes/s"):format(
                #chart.charts[chart.mode], fmtDuration(chart.duration), d.density),
            13, Enum.Font.Gotham, Color3.fromRGB(160, 166, 190),
            UDim2.fromOffset(18, 31), UDim2.fromOffset(rowW - 28, 18))
        btn.Activated:Connect(function()
            destroyPicker()
            -- own thread: the audio-length pre-cache can yield
            task.spawn(function()
                local okB, errB = pcall(pickDifficulty, parent, d)
                if not okB then notify("Difficulty error", tostring(errB), true) end
            end)
        end)
    end

    local back = Instance.new("TextButton")
    back.Name = "Back"
    back.Position = UDim2.fromOffset(16, 70 + listH + 12)
    back.Size = UDim2.fromOffset(panelW - 32, 40)
    back.BackgroundColor3 = Color3.fromRGB(46, 50, 70)
    back.BorderSizePixel = 0
    back.AutoButtonColor = true
    back.Text = "BACK"
    back.TextSize = 16
    back.Font = Enum.Font.GothamBold
    back.TextColor3 = Color3.fromRGB(200, 205, 225)
    back.Parent = panel
    round(back, 8)
    back.Activated:Connect(destroyPicker)
end

-- Called from the StartPlay wrapper with the original arguments. Returns true
-- to swallow the call (a parent row was clicked). Anything else - real songs,
-- legacy single charts - returns false and reaches the game untouched.
local function onStartPlay(songId)
    if _G.GakuranChartGen ~= MYGEN then return false end
    local parent = type(songId) == "string" and parents[songId] or nil
    if not parent then return false end
    -- the wheel calls Close() right after StartPlay returns, so a native
    -- submenu can only open afterwards: schedule it, with the standalone
    -- overlay as the fallback when the wheel controller can't be driven
    task.defer(function()
        if _G.GakuranChartGen ~= MYGEN then return end
        local shown = false
        if HK.openWheelSubmenu then
            local okW, res = pcall(HK.openWheelSubmenu, parent)
            shown = okW and res == true
        end
        if not shown then
            -- mutual exclusion: an open wheel goes back to its list page
            -- first, so the overlay never stands beside our submenu
            local wb = hookBase["WheelMenu"]
            if type(wb) == "table" then wb.pendingSongId = nil; wb.pendingToken = nil end
            local fc = findWheelController()
            if fc then
                local okFS, fst = pcall(function() return fc._uiState end)
                local okFO, fop = pcall(function() return fc._isOpen end)
                if okFS and fst == "Open" and okFO and fop == true then
                    pcall(function() fc:_transitionPage(function() end) end)
                end
            end
            local okO, errO = pcall(openPicker, parent)
            if not okO then notify("Picker error", tostring(errO), true) end
        end
    end)
    return true
end
----------------------------------------------------------------
-- 5.96 Native wheel submenu page (multi-difficulty parent rows).
-- Renders inside the game's own wheel through its slot primitives, the way
-- _applyGuitarVariantSubmenu does: Back nav slot, one button per difficulty
-- (tier-coloured strip, star-rating chip on the right), remaining
-- slots cleared. Picks run pickDifficulty, then close the wheel and return
-- "play" (native flash + select sound). Registered per run on the shared
-- WheelMenu record (like b.handler); the stable router wrapper only reads
-- the record, so it stays correct across re-executions.
----------------------------------------------------------------
function HK.renderWheelSubmenu(controller, pid)
    local parent = parents[pid]
    if not parent then return false end
    local diffs = parent.diffs
    if type(diffs) ~= "table" or #diffs == 0 then return false end
    controller._menuPage, controller._menuPages, controller._menuResults = 1, 1, nil
    controller:_setNavSlot(1, "\227\130\130\227\129\169\227\130\139", function()
        local wb = hookBase["WheelMenu"]
        if type(wb) == "table" then wb.pendingSongId = nil; wb.pendingToken = nil end
        controller:_transitionPage(function() end)
    end, true, "BACK", "back")
    local shown = math.min(#diffs, 9)
    if #diffs > 9 then warn("[GakuranChart] Difficulty submenu shows 9 of " .. #diffs .. " difficulties") end
    for i = 1, shown do
        local dd = diffs[i]
        local chart = dd.chart
        local name = string.upper(diffName(chart))
        -- The rating is the slot's difficulty CHIP: the wheel skins draw
        -- RhythmWheelKit.tier(meta.diff), and HK.makeDiffTier turns a star
        -- label into a tier-coloured "★5.32" chip, the same badge the
        -- single-difficulty rows get. The title is just the difficulty name
        -- (the native slot label end-truncates, so only the name can clip).
        local stars = ("★%.2f"):format(starRating(chart))
        local title = name
        local sub = ("%s  %d notes  |  %s"):format(sourceTag(chart),
            #chart.charts[chart.mode], fmtDuration(chart.duration))
        local song = parent.song
        local art = { artist = song.artist, coverId = song.coverId, diff = stars,
            length = fmtDuration(chart.duration), playMode = parent.mode,
            source = chartSource(chart) }
        controller:_setSlot(1 + i, title, function()
            local okB, resB = pcall(pickDifficulty, parent, dd)
            if not okB then
                notify("Difficulty error", tostring(resB), true)
                return false
            end
            if resB == true then return "play" end
            return false
        end, false, nil, sub, tierColor(chart), false, nil, art)
    end
    for j = 2 + shown, 10 do controller:_setSlot(j, "", nil) end
    return true
end

-- Drive the native submenu for a parent: flag the router record, then open
-- (lands straight on our page) or transition (wheel already open). Returns
-- true only on the paths that show the submenu; callers fall back to the
-- overlay otherwise.
function HK.openWheelSubmenu(parent)
    local wb = armWheelMenu()
    if type(wb) ~= "table" then return false end
    local c = findWheelController()
    if not c then return false end
    wb.pendingSongId = parent.id
    wb.pendingAt = os.time()
    wb.pendingToken = nil
    local before = wb.renderCount or 0
    local function rendered()
        return (wb.renderCount or 0) > before
    end
    local function fail()
        wb.pendingSongId = nil
        wb.pendingToken = nil
        return false
    end
    for _ = 1, 30 do
        local okS, st = pcall(function() return c._uiState end)
        if okS and st == "Open" then
            local okT = pcall(function() c:_transitionPage(function() end) end)
            if not okT then
                return fail()
            end
            -- the apply runs after the transition tween: wait for our render,
            -- not just a clean call. falls through to overlay on timeout
            for _ = 1, 30 do
                if rendered() then pcall(destroyPicker) return true end
                task.wait(0.05)
            end
            return fail()
        end
        if okS and st == "Closed" then break end
        task.wait(0.05)
    end
    -- the wait loop above only breaks early on Open; anything else here means
    -- it timed out in a transitional state, where Open() would silently no-op
    local okS2, st2 = pcall(function() return c._uiState end)
    if not (okS2 and st2 == "Closed") then
        return fail()
    end
    if pcall(function() c:Open() end) then
        local okI, isOpen = pcall(function() return c._isOpen end)
        -- Open() renders synchronously, so a render must already be counted;
        -- _isOpen alone can lie (split-brain after programmatic opens).
        -- A stale overlay would otherwise stand beside the submenu.
        if okI and isOpen == true and rendered() then pcall(destroyPicker) return true end
    end
    return fail()
end

HK.pickerHandler = onStartPlay
do
    local b = hookBase["StartPlay"]
    if type(b) == "table" then
        b.handler = onStartPlay
        b.bypass = false
    end
    local wb = hookBase["WheelMenu"]
    if type(wb) == "table" then
        wb.renderMenu = HK.renderWheelSubmenu
    end
end

-- Watch for natural song end to clean up local state.
-- Restoring PlayingInstrument used to be unsafe while the results screen was
-- up (stopIfInvalidContext -> Stop() -> the screen is destroyed mid-fade), so
-- this waited for the results screen to be dismissed as well - which is what
-- left the instrument in the character's hands for the whole end screen.
-- restoreAttributes now writes with those teardown listeners suppressed (see
-- withContextTeardownSuppressed), so only a LIVE session or view has to be
-- waited out. _resultsScreen is reported separately for the leak sweeper and
-- diag, but no longer gates the restore.
local function surfaceStillUp()
    local ok, up = pcall(function()
        return (service._session ~= nil) or (service._view ~= nil)
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
                -- parent rows show "N diffs" again (a pick had swapped in the
                -- played difficulty's name for the results screen)
                for _, p in pairs(parents) do
                    pcall(function() p.song.difficulty = p.label end)
                end
                if playStatusCallback and not stopRequested then
                    playStatusCallback("Song finished")
                end
            end
            stopRequested = false
        elseif playing then
            stopRequested = false
        elseif savedAttributes and not surfaceStillUp()
            and os.clock() - (savedAttributes.at or 0) > 30 then
            -- Leak sweeper: an override with no play, results screen or
            -- pending start behind it (a throw between saveAndSetAttributes
            -- and StartPlay, a missed play->stop transition) would leave the
            -- character in instrument mode. 30 s outlasts any legitimate
            -- start (old-view teardown wait + audio-length pre-cache), and
            -- restoreAttributes only undoes what is still ours.
            restoreAttributes()
        end
        wasPlaying = playing
    end
end)

----------------------------------------------------------------
-- 5.97 Local scores (GakuranCharts/Scores.json)
--
-- Custom plays are never submitted, so the engine's leaderboard never sees
-- them and a custom chart had nothing to beat. The guard wrapper already
-- receives the genuine stats on their way to being dropped, so they are
-- recorded here instead. Nothing is ever sent anywhere - this file is local.
--
-- The payload was captured live rather than guessed (Madium, placeVersion
-- 7646). RhythmStatsClient.SubmitStats takes five arguments:
--   1 songId (string), 2 mode (string), 3 number and 4 nil - both still
--   unidentified, being 0/nil on a capture run that took no input - and
--   5 the stats table { Clutch, Hits, Judged, MaxCombo, Score }.
-- The raw table is stored verbatim beside the derived figures so nothing is
-- lost if "Hits" turns out to mean one judgement rather than every non-miss.
-- a3/a4 are kept on the last play for the same reason: a real played run will
-- show what they are without another capture session.
--
-- Rows are keyed by CHART id, not by the submitted song id. A multi-difficulty
-- parent submits the PARENT id, so keying on that would collapse every
-- difficulty of a song into one row. customCharts[songId] is re-pointed at
-- pick time (and set for singles and for Rayfield plays), so it names the
-- difficulty actually played.
----------------------------------------------------------------
local SCORES_VERSION = 1
local scores = { formatVersion = SCORES_VERSION, charts = {} }

local function loadScores()
    local okF, isf = pcall(fn.isfile, SCORES_FILE)
    if not (okF and isf) then return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(fn.readfile(SCORES_FILE)) end)
    if ok2 and type(data) == "table" and type(data.charts) == "table" then
        scores = data
        scores.formatVersion = SCORES_VERSION
    end
end

local function saveScores()
    pcall(fn.writefile, SCORES_FILE, HttpService:JSONEncode(scores))
end

loadScores()

local function num(v) return (type(v) == "number" and v == v) and v or 0 end

-- Fold one finished play into its chart row. Returns the row and whether this
-- run was a new best, so the caller can say which.
local function recordScore(songId, mode, a3, a4, stats)
    if type(stats) ~= "table" then return nil, false end
    local chart = customCharts[songId]
    local key = (type(chart) == "table" and type(chart.id) == "string" and chart.id) or songId
    if type(key) ~= "string" or key == "" then return nil, false end

    local judged, hits = num(stats.Judged), num(stats.Hits)
    local run = {
        score = num(stats.Score),
        maxCombo = num(stats.MaxCombo),
        hits = hits,
        judged = judged,
        misses = math.max(0, judged - hits),
        clutch = num(stats.Clutch),
        -- Hits/Judged. Called hitRate, not accuracy, because the exact meaning
        -- of Hits is not confirmed yet (see the section comment).
        hitRate = (judged > 0) and (hits / judged) or 0,
        at = os.time(),
        raw = stats,
        a3 = a3,
        a4 = a4,
    }

    local row = scores.charts[key]
    if type(row) ~= "table" then
        row = { plays = 0 }
        scores.charts[key] = row
    end
    row.plays = num(row.plays) + 1
    row.lastPlayed = run.at
    row.mode = mode or row.mode
    row.songId = songId
    if type(chart) == "table" then
        row.title = chart.title or row.title
        row.artist = chart.artist or row.artist
        row.difficulty = diffName(chart)
    end
    row.last = run

    local isBest = (type(row.best) ~= "table") or (run.score > num(row.best.score))
    if isBest then row.best = run end

    saveScores()
    return row, isBest
end

-- Announce a finished custom run. Kept separate from recordScore so that a
-- notify error can never cost us the file write.
local function onCustomStatsSubmitted(songId, mode, a3, a4, stats)
    local row, isBest = recordScore(songId, mode, a3, a4, stats)
    if not row then return end
    local r = row.last
    notify(isBest and "New best!" or "Score saved",
        ("%s - %d  (%.2f%%, combo %d)%s"):format(
            row.title or songId, r.score, r.hitRate * 100, r.maxCombo,
            isBest and "" or ("  |  best " .. tostring(num(row.best and row.best.score)))))
end

do
    local b = hookBase["SubmitStats"]
    if type(b) == "table" then b.scoreHandler = onCustomStatsSubmitted end
end
HK.scoreHandler = onCustomStatsSubmitted

-- One-line best for a chart, for the UI and the console.
local function scoreLine(chart)
    if type(chart) ~= "table" then return "No chart loaded" end
    local row = scores.charts[chart.id]
    if type(row) ~= "table" or type(row.best) ~= "table" then
        return "No local score yet"
    end
    local b = row.best
    return ("Best %d  |  %.2f%%  |  combo %d  |  %d/%d hit  |  %d play(s)"):format(
        num(b.score), num(b.hitRate) * 100, num(b.maxCombo),
        num(b.hits), num(b.judged), num(row.plays))
end

----------------------------------------------------------------
-- 6. UI (Rayfield)
----------------------------------------------------------------
-- The whole UI is built inside buildUI() and run under pcall (see the end of
-- this section): a Rayfield load/build error must not abort the loader and
-- leave it half-initialised. The body below is intentionally NOT re-indented
-- so the diff against the previous version stays reviewable.
-- Rayfield:Notify runs every notification in its own task.spawn thread that
-- sleeps through the whole animation (~5 s). A re-execution destroys the
-- previous Rayfield GUI (cleanup + sweepRayfield) while those threads are still
-- asleep; when one wakes, the notification's children are gone and it throws
-- "Title/Icon is not a valid member of Frame ..." (one pair per notification
-- still on screen, so N back-to-back reloads print N-1 pairs). Harmless to the
-- new instance, but noisy. Fix: patch the Rayfield source IN MEMORY (the file
-- on disk stays as downloaded) so the thread returns as soon as its frame is
-- no longer parented. A destroyed GUI can only be noticed after a yield, so one
-- check after every `task.wait(...)` statement inside Notify covers every line
-- that could throw. Returns the source and the number of guards inserted.
HK.rayfieldGuardCount = 0
function HK.guardRayfieldNotify(src)
    local s = src:find("function RayfieldLibrary:Notify(data)", 1, true)
    if not s then return src, 0 end
    -- the function ends at the first column-0 "end" (inner blocks are indented)
    local e = src:find("\nend", s, true)
    if not e then return src, 0 end
    local body, n = src:sub(s, e):gsub("(\n[ \t]*task%.wait%b())",
        "%1 if not newNotification.Parent then return end")
    if n == 0 then return src, 0 end
    return src:sub(1, s - 1) .. body .. src:sub(e + 1), n
end

-- Loads ui/Rayfield.lua with the guard applied. Any problem (anchors missing
-- after a Rayfield update, patched chunk fails to compile) falls back to the
-- untouched source: the guard is cosmetic and must never block the UI.
function HK.loadRayfield()
    local src = fn.readfile("ui/Rayfield.lua")
    local okP, patched, n = pcall(HK.guardRayfieldNotify, src)
    if okP and n > 0 then
        local chunk = loadstring(patched)
        if chunk then
            HK.rayfieldGuardCount = n
            return chunk()
        end
    end
    HK.rayfieldGuardCount = 0
    warn("[GakuranChart] Rayfield notification guard not applied (unexpected Rayfield source); reload errors may appear")
    return loadstring(src)()
end

local function buildUI()
Rayfield = HK.loadRayfield()

-- Route notify() through Rayfield now that it exists. Errors linger longer.
uiNotify = function(title, body, isError)
    Rayfield:Notify({ Title = title, Content = body, Duration = isError and 9 or 4 })
end

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

-- The list shows one row per SONG, not one per chart file: a song with several
-- difficulties is a single row, and picking it reveals the difficulty selector
-- below (the same shape as the in-game wheel's parent rows and submenu).
--
-- Grouping is done here from the chart files rather than reusing `parents`,
-- because injectAllCharts only fills `parents` when the "show custom songs in
-- the wheel" option is on, and this list has to work either way. Ordering of
-- difficulties reuses sortDiffs/chartDensity, so the UI and the wheel agree.
local songEntries = {}     -- { { label, diffs = { { name, label, path, chart, density } } } }
local songByLabel = {}

local function buildSongList()
    songEntries, songByLabel = {}, {}
    local groups, order, skipped = {}, {}, 0
    for _, path in ipairs(listChartFiles()) do
        local chart = readChart(path)   -- unreadable charts cannot be played, so skip
        if chart then
            -- "\0" prefixes the singles so a chart id can never collide with a songId
            local key = (type(chart.songId) == "string" and chart.songId ~= "")
                and chart.songId or ("\0" .. tostring(chart.id))
            if not groups[key] then
                groups[key] = {}
                table.insert(order, key)
            end
            table.insert(groups[key], {
                name = diffName(chart), path = path,
                chart = chart, density = chartDensity(chart),
            })
        else
            skipped += 1
        end
    end

    for _, key in ipairs(order) do
        local diffs = groups[key]
        sortDiffs(diffs)                     -- easiest first, same rule as the wheel
        for _, d in ipairs(diffs) do
            d.label = ("%s  %s  (%s%.2f)"):format(sourceTag(d.chart), d.name, utf8.char(0x2605), starRating(d.chart))
        end
        local first = diffs[1].chart
        local label = sourceTag(first) .. " " .. (first.title or tostring(first.id))
        if type(first.artist) == "string" and first.artist ~= "" then
            label = label .. " - " .. first.artist
        end
        if #diffs > 1 then
            label = ("%s  [%d diffs]"):format(label, #diffs)
        end
        -- Two different songs can share title and artist; keep rows selectable.
        local base, dup = label, 2
        while songByLabel[label] do
            label = ("%s (%d)"):format(base, dup)
            dup += 1
        end
        local entry = { label = label, diffs = diffs }
        table.insert(songEntries, entry)
        songByLabel[label] = entry
    end
    table.sort(songEntries, function(a, b) return a.label:lower() < b.label:lower() end)

    local names = {}
    for i, e in ipairs(songEntries) do names[i] = e.label end
    if #names == 0 then names = { "(no charts found)" } end
    return names, skipped
end

local infoLabel
local scoreLabel
local diffDropdown
local diffFrame            -- the difficulty dropdown's own Frame, for show/hide
local selectedSong

-- Rayfield's dropdown object exposes only :Set and :Refresh, but the element's
-- Frame is named after the dropdown, so it can be found and toggled. A
-- notification can share that name, so candidates are filtered by having the
-- "Selected" child that only a dropdown has.
local function findDropdownFrame(name)
    local gui
    if type(gethui) == "function" then
        local okH, h = pcall(gethui)
        if okH and h then gui = h:FindFirstChild("Rayfield") end
    end
    gui = gui or CoreGui:FindFirstChild("Rayfield")
    if not gui then return nil end
    for _, d in ipairs(gui:GetDescendants()) do
        if d.Name == name and d:IsA("GuiObject") and d:FindFirstChild("Selected") then
            return d
        end
    end
    return nil
end

-- Hidden rather than emptied, so a single-difficulty song shows no selector at
-- all. UIListLayout skips invisible children, so the row collapses cleanly. If
-- Rayfield's internals ever change, the frame simply is not found and the
-- selector stays visible - usable, just always on screen.
local function setDiffSelectorVisible(show)
    if not diffFrame then diffFrame = findDropdownFrame("Difficulty") end
    if diffFrame then pcall(function() diffFrame.Visible = show and true or false end) end
end

local function selectDiff(d)
    if type(d) ~= "table" or type(d.chart) ~= "table" then return end
    local chart = d.chart
    currentChart, currentChartPath = chart, d.path
    if infoLabel then
        pcall(function()
            infoLabel:Set(
                ("%s\n%s | %s | %s BPM | %s notes | %s keys%s"):format(
                    chart.title .. " - " .. (chart.artist or ""),
                    d.name, chart.mode, tostring(chart.bpm),
                    tostring(#chart.charts[chart.mode]),
                    tostring(chart._laneCount or ((chart.mode == "Guitar") and 2 or 4)),
                    ((chart._droppedNotes or 0) > 0)
                        and ("  (" .. chart._droppedNotes .. " invalid notes dropped)") or ""
                )
            )
        end)
    end
    if scoreLabel then pcall(function() scoreLabel:Set(scoreLine(chart)) end) end
end

local songDropdown = Tab:CreateDropdown({
    Name = "Songs in GakuranCharts/Charts",
    Options = (buildSongList()),
    CurrentOption = nil,
    MultiSelection = false,
    Callback = function(option)
        local label = type(option) == "table" and option[1] or option
        local entry = songByLabel[label]
        if not entry then return end   -- the "(no charts found)" placeholder
        selectedSong = entry
        if #entry.diffs > 1 then
            local labels = {}
            for i, d in ipairs(entry.diffs) do labels[i] = d.label end
            setDiffSelectorVisible(true)
            if diffDropdown then
                -- :Set fires the dropdown's own Callback, which loads the chart,
                -- so the easiest difficulty is selected for you.
                pcall(function() diffDropdown:Refresh(labels) end)
                pcall(function() diffDropdown:Set(labels[1]) end)
            else
                selectDiff(entry.diffs[1])
            end
        else
            setDiffSelectorVisible(false)
            selectDiff(entry.diffs[1])
            notify("Chart loaded", entry.diffs[1].chart.title)
        end
    end,
})

diffDropdown = Tab:CreateDropdown({
    Name = "Difficulty",
    Options = { "-" },
    CurrentOption = nil,
    MultiSelection = false,
    Callback = function(option)
        local label = type(option) == "table" and option[1] or option
        if not selectedSong then return end
        for _, d in ipairs(selectedSong.diffs) do
            if d.label == label then
                selectDiff(d)
                notify("Chart loaded", ("%s [%s]"):format(d.chart.title, d.name))
                return
            end
        end
    end,
})

local function refreshSongUI()
    local opts, skipped = buildSongList()
    pcall(function() songDropdown:Refresh(opts) end)
    selectedSong = nil
    setDiffSelectorVisible(false)
    return opts, skipped
end

Tab:CreateButton({
    Name = "Refresh chart list",
    Callback = function()
        local okR, errR = pcall(function()
            local opts, skipped = refreshSongUI()
            if settings.showInWheel then
                injectAllCharts()  -- pick up newly added chart files
            end
            local diffCount = 0
            for _, e in ipairs(songEntries) do diffCount += #e.diffs end
            notify("Refreshed", ("%d song(s), %d difficult%s%s"):format(
                #songEntries, diffCount, diffCount == 1 and "y" or "ies",
                skipped > 0 and ("  (" .. skipped .. " unreadable, skipped)") or ""))
        end)
        if not okR then notify("Refresh error", tostring(errR), true) end
    end,
})

infoLabel = Tab:CreateLabel("No chart loaded")
-- Local best for the loaded chart. Custom plays are never submitted, so this
-- is the only scoreboard they have.
scoreLabel = Tab:CreateLabel(scoreLine(currentChart))

-- Nothing is selected at build time, so the selector starts hidden. Deferred
-- because the element Frames do not exist until Rayfield finishes laying the
-- tab out.
task.defer(function() pcall(setDiffSelectorVisible, false) end)

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

-- 4K+ key bindings (5-7 lanes). One keybind per lane, stored in Settings.json
-- and read at the START of every play, so a rebind applies to the next play
-- (wheel songs included). A duplicate or unusable key is rejected and the box
-- goes back to the previous key.
do
    local TabKeys = Window:CreateTab("Keys (4K+)", 4483362458)
    TabKeys:CreateLabel("Keys for charts with 5-7 lanes (4-lane charts use the game's own keys)")
    TabKeys:CreateLabel("Avoid K: it is Rayfield's default toggle key. Applies from the next play.")
    local elems, resetting = {}, false
    for n = 5, HK.maxLanes do
        TabKeys:CreateSection(("%d lanes"):format(n))
        local names = HK.keyNamesFor(n)
        elems[n] = {}
        for lane = 1, n do
            elems[n][lane] = TabKeys:CreateKeybind({
                Name = ("%dK  lane %d"):format(n, lane),
                CurrentKeybind = names[lane],
                HoldToInteract = false,
                CallOnChange = true,
                Ext = true,
                Callback = function(key)
                    if resetting then return end
                    local cur = HK.keyNamesFor(n)
                    if not HK.usableKey(key) then
                        notify("Keys", tostring(key) .. " cannot be used", true)
                        pcall(function() elems[n][lane]:Set(cur[lane]) end)
                        return
                    end
                    for other = 1, n do
                        if other ~= lane and cur[other] == key then
                            notify("Keys", ("%s is already lane %d of %dK"):format(key, other, n), true)
                            pcall(function() elems[n][lane]:Set(cur[lane]) end)
                            return
                        end
                    end
                    cur[lane] = key
                    if type(settings.keys) ~= "table" then settings.keys = {} end
                    settings.keys[tostring(n)] = cur
                    saveSettings()
                end,
            })
        end
    end
    TabKeys:CreateButton({
        Name = "Reset 4K+ keys to defaults",
        Callback = function()
            resetting = true
            settings.keys = {}
            saveSettings()
            for n = 5, HK.maxLanes do
                local d = HK.keyNamesFor(n)
                for lane = 1, n do
                    pcall(function() elems[n][lane]:Set(d[lane]) end)
                end
            end
            resetting = false
            notify("Keys", "4K+ keys reset to defaults")
        end,
    })
end

TabOpt:CreateSection("Integration")
-- Forward-declared so the two wheel toggles can sync each other: enabling
-- "customs only" forces listing on, and turning listing off also turns the
-- filter off (without listed customs it would only ever show an empty wheel).
-- ToggleSettings:Set() updates the visual AND runs the callback, so syncing
-- through Set never duplicates logic and can never recurse (neither callback
-- re-triggers the other in the same direction).
local showWheelToggle, customsOnlyToggle = nil, nil
showWheelToggle = TabOpt:CreateToggle({
    Name = "Show custom songs in the song wheel",
    CurrentValue = settings.showInWheel or false,
    Callback = function(value)
        settings.showInWheel = value
        saveSettings()
        if not value and settings.customsOnly then
            settings.customsOnly = false
            saveSettings()
            local b = hookBase["ListPlayableSongInfosForHeld"]
            if type(b) == "table" then b.customsOnly = false end
            if customsOnlyToggle then pcall(function() customsOnlyToggle:Set(false) end) end
            notify("Song wheel", "Customs-only filter turned off (no customs listed)")
        end
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
customsOnlyToggle = TabOpt:CreateToggle({
    Name = "Song wheel: show only custom songs",
    CurrentValue = settings.customsOnly or false,
    Callback = function(value)
        settings.customsOnly = value
        saveSettings()
        local b = hookBase["ListPlayableSongInfosForHeld"]
        if type(b) == "table" then
            b.customsOnly = value
            if value then b.emptyNoticed = false end
        end
        if value and not settings.showInWheel then
            if showWheelToggle then pcall(function() showWheelToggle:Set(true) end) end
        end
        notify("Song wheel", value and "Showing only custom songs (reopen the wheel to apply)"
            or "Showing all songs (reopen the wheel to apply)")
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
end -- buildUI

local uiOk, uiErr = xpcall(buildUI, function(e)
    return tostring(e) .. "\n" .. debug.traceback()
end)
if not uiOk then
    warn("[GakuranChart] UI initialization failed - rolling the loader back:\n" .. tostring(uiErr))
    -- Retire this instance (its background loops watch _G.GakuranChartGen),
    -- then undo everything with the cleanup registered before the UI.
    if _G.GakuranChartGen == MYGEN then _G.GakuranChartGen = MYGEN + 1 end
    local retireGen = _G.GakuranChartGen
    pcall(_G.GakuranChartCleanup)
    pcall(HK.sweepRayfield)   -- a half-built window may exist
    if not HK.safetyDone then
        -- A custom session was still tearing down: keep the guards until it
        -- is gone, then finish. Stops as soon as a newer execution takes over
        -- (it owns the shared state from then on).
        task.spawn(function()
            for _ = 1, 80 do
                task.wait(0.25)
                if _G.GakuranChartGen ~= retireGen then return end
                if HK.finish() then return end
            end
        end)
    end
    return
end

----------------------------------------------------------------
-- 6.9 Stage keyboard guard. Seated at a REAL stage keyboard (Humanoid.SeatPart
-- set and the character attribute PlayingInstrument == "Keyboard"), Space is
-- Roblox's jump and a jump stands you up, which ends the play. While that holds:
--   * a ContextActionService bind sinks Space. Priority 3100 is deliberately
--     BELOW the engine's lane keys (RhythmLanes, 3200) and its movement lock
--     (3150), so a session that uses Space as a lane key (5K/7K defaults) still
--     receives it, and ABOVE the default jump (2000) and the game's own
--     station-leave bind (RhythmStationLeave, 2050: Backspace / ButtonB keep
--     working);
--   * an on-screen EXIT KEYBOARD button runs the same leave routine as the
--     Backspace bind (close an open wheel, then SeatServiceUtils.StandUp).
-- Nothing exists while you are not seated at the keyboard (our own forced
-- plays are not seated, so they are untouched). Torn down by the cleanup.
----------------------------------------------------------------
HK.sg = { conns = {}, charConns = {}, bound = false, gui = nil, blocked = 0, exits = 0,
          action = "GakuranChartStageSpaceGuard", guiName = "GakuranChartStageExit" }

function HK.sgState()
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return false, nil end
    local seated = hum.SeatPart ~= nil or hum.Sit
    return (seated and char:GetAttribute("PlayingInstrument") == "Keyboard") or false, hum
end

-- Same routine as the game's Backspace bind (InstrumentServiceClient
-- onStationLeave), except that a click always leaves: an open wheel is closed
-- AND the character stands up.
function HK.sgLeave()
    HK.sg.exits += 1
    local okC, reg = pcall(function() return require(RS.Shared.Services.WheelOpenRegistry) end)
    if okC and type(reg) == "table" and type(reg.CloseOpen) == "function" then
        pcall(reg.CloseOpen)
    end
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return false end
    local okS, seatUtils = pcall(function()
        return require(RS.Shared.Services.SeatService.SeatServiceUtils)
    end)
    if okS and type(seatUtils) == "table" and type(seatUtils.StandUp) == "function"
        and pcall(seatUtils.StandUp, hum) then
        return true
    end
    -- fallback if the game's helper moved: plain Roblox stand-up
    pcall(function() hum.Sit = false end)
    pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    return true
end

function HK.sgBind()
    local sg = HK.sg
    if sg.bound then return end
    local okB = pcall(function()
        game:GetService("ContextActionService"):BindActionAtPriority(sg.action, function()
            sg.blocked += 1
            return Enum.ContextActionResult.Sink
        end, false, 3100, Enum.KeyCode.Space)
    end)
    sg.bound = okB
end

function HK.sgUnbind()
    local sg = HK.sg
    pcall(function() game:GetService("ContextActionService"):UnbindAction(sg.action) end)
    sg.bound = false
end

function HK.sgShow()
    local sg = HK.sg
    if sg.gui and sg.gui.Parent then return end
    local pgui = player:FindFirstChildOfClass("PlayerGui")
    if not pgui then return end
    local gui = Instance.new("ScreenGui")
    gui.Name = sg.guiName
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 40
    gui.IgnoreGuiInset = false
    local btn = Instance.new("TextButton")
    btn.Name = "Exit"
    btn.AnchorPoint = Vector2.new(1, 0)
    btn.Position = UDim2.new(1, -16, 0, 12)
    btn.Size = UDim2.new(0, 176, 0, 42)
    btn.BackgroundColor3 = Color3.fromRGB(34, 28, 78)
    btn.BackgroundTransparency = 0.08
    btn.AutoButtonColor = true
    btn.BorderSizePixel = 0
    btn.Font = Enum.Font.GothamBlack
    btn.Text = "EXIT KEYBOARD"
    btn.TextSize = 16
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Parent = gui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = btn
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(255, 48, 138)
    stroke.Thickness = 2
    stroke.Parent = btn
    btn.Activated:Connect(function()
        if _G.GakuranChartGen ~= MYGEN then return end
        pcall(HK.sgLeave)
    end)
    gui.Parent = pgui
    sg.gui = gui
end

function HK.sgHide()
    local sg = HK.sg
    if sg.gui then
        pcall(function() sg.gui:Destroy() end)
        sg.gui = nil
    end
end

function HK.sgUpdate()
    if _G.GakuranChartGen ~= MYGEN or HK.cleaned then
        HK.sgStop()
        return
    end
    if (HK.sgState()) then
        HK.sgBind()
        HK.sgShow()
    else
        HK.sgUnbind()
        HK.sgHide()
    end
end

function HK.sgWatch(char)
    local sg = HK.sg
    for _, c in ipairs(sg.charConns) do pcall(function() c:Disconnect() end) end
    sg.charConns = {}
    if char then
        table.insert(sg.charConns, char:GetAttributeChangedSignal("PlayingInstrument"):Connect(HK.sgUpdate))
        local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
        if hum then
            table.insert(sg.charConns, hum:GetPropertyChangedSignal("SeatPart"):Connect(HK.sgUpdate))
            table.insert(sg.charConns, hum:GetPropertyChangedSignal("Sit"):Connect(HK.sgUpdate))
        end
    end
    HK.sgUpdate()
end

function HK.sgStart()
    local sg = HK.sg
    table.insert(sg.conns, player.CharacterAdded:Connect(function(c) task.spawn(HK.sgWatch, c) end))
    task.spawn(HK.sgWatch, player.Character)
end

function HK.sgStop()
    local sg = HK.sg
    for _, c in ipairs(sg.conns) do pcall(function() c:Disconnect() end) end
    for _, c in ipairs(sg.charConns) do pcall(function() c:Disconnect() end) end
    sg.conns, sg.charConns = {}, {}
    HK.sgUnbind()
    HK.sgHide()
end

function HK.sgStatus()
    local sg = HK.sg
    local active = HK.sgState()
    return { active = active, bound = sg.bound, button = sg.gui ~= nil and sg.gui.Parent ~= nil,
             blocked = sg.blocked, exits = sg.exits, watching = #sg.conns > 0 }
end

if _G.GakuranChartGen == MYGEN then HK.sgStart() end
----------------------------------------------------------------
-- 7. Programmatic API
-- (the re-execution cleanup now lives in 5.9, registered before the UI)
----------------------------------------------------------------
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
    -- Stage keyboard guard status (Space block + EXIT KEYBOARD button), see 6.9.
    stageGuard = function() return HK.sgStatus() end,
    current = function() return currentChartPath end,
    skins = listSkinPacks,
    -- Local scores. Never sent anywhere; GakuranCharts/Scores.json.
    -- scores()      -> the whole table
    -- scores(id)    -> one chart's row (chart id, not song id)
    scores = function(chartId)
        if chartId == nil then return scores end
        return scores.charts[chartId]
    end,
    scoreLine = function(chart) return scoreLine(chart or currentChart) end,
    clearScores = function(chartId)
        if chartId == nil then
            scores = { formatVersion = SCORES_VERSION, charts = {} }
        else
            scores.charts[chartId] = nil
        end
        saveScores()
        return true
    end,
    -- Startup self-test. The loader reads private fields of a game it does not
    -- control, so when an update breaks something this says WHICH piece moved
    -- instead of just failing. Pure read, JSON-encodable, no side effects.
    diag = function()
        local function n(t) local c = 0 for _ in pairs(t or {}) do c += 1 end return c end
        -- Private state: rawget, because identity on the instance is the point.
        local function fields(t, keys)
            local out = {}
            for _, k in ipairs(keys) do
                out[k] = (type(t) == "table") and (rawget(t, k) ~= nil) or false
            end
            return out
        end
        -- Methods: plain index, because they live on the class and arrive
        -- through __index. rawget would report every one of them missing.
        local function methods(t, keys)
            local out = {}
            for _, k in ipairs(keys) do
                local ok, v = pcall(function() return t[k] end)
                out[k] = ok and type(v) == "function"
            end
            return out
        end

        -- getgc targets, in the order section 1/5.5/5.7 look for them.
        local mods = {
            RhythmServiceClient   = serviceClass ~= nil,
            RhythmService         = type(service) == "table",
            StatsModule           = statsMod ~= nil,
            JamRelayModule        = relayMod ~= nil,
            RhythmDifficulty      = diffMod ~= nil,
            RhythmWheelKit        = kitMod ~= nil,
            RhythmChartUtil       = chartUtil ~= nil,
            RhythmNoteSprites     = noteSpritesMod ~= nil,
            RhythmThemeSettings   = themeSettingsMod ~= nil,
            SettingsThemeHosts    = #settingsThemeHosts,
        }
        local missing = {}
        for k, v in pairs(mods) do
            if v == false then table.insert(missing, k) end
        end
        table.sort(missing)

        -- Hook slots: is the slot ours, and is ours what the game will call?
        local hooks = {}
        for _, name in ipairs({ "SubmitStats", "QueryJamSync", "FireStart",
                                "ListPlayableSongInfosForHeld", "DiffKey",
                                "DiffTier", "StartPlay", "WheelMenu", "WheelSearch",
                                "ResolvePlayable", "ViewTheme", "HintLabels", "KeyMap", "ViewNew" }) do
            local b = hookBase[name]
            if type(b) ~= "table" then
                hooks[name] = "absent"
            else
                local cur = nil
                pcall(function() cur = b.mod[b.key] end)
                if cur == b.wrap then hooks[name] = "installed"
                elseif cur ~= nil and HK.chainContains(cur, b.wrap) then hooks[name] = "beneath-foreign"
                else hooks[name] = "displaced" end
            end
        end

        local reg = type(service) == "table" and rawget(service, "_registry") or nil
        return {
            version = VERSION,
            gen = _G.GakuranChartGen,
            summary = (#missing == 0)
                and "all getgc targets found"
                or (#missing .. " target(s) MISSING: " .. table.concat(missing, ", ")),
            modules = mods,
            -- Private service state the loader reads. _session/_view/
            -- _resultsScreen/_carryOverStats are nil while idle, so false is
            -- normal there; _registry false is a real break.
            state = fields(service, { "_session", "_view", "_resultsScreen",
                                      "_registry", "_active", "_carryOverStats" }),
            -- These must all be true. Any false means the engine moved.
            methods = methods(service, { "StartPlay", "Stop", "Get", "Init",
                                         "IsPlaying", "ListPlayableSongInfosForHeld" }),
            registry = fields(reg, { "_byId", "_list" }),
            hooks = hooks,
            counts = {
                charts = #listChartFiles(),
                parents = n(parents),
                customIds = n(customIds),
                customCharts = n(customCharts),
                skinPacks = #listSkinPacks(),
                guardIds = n(guardIds),
                ledgerRecs = n(LG.ledger and LG.ledger.recs),
                registryById = n(reg and rawget(reg, "_byId")),
                wheelController = findWheelController() ~= nil,
                rayfieldGuard = HK.rayfieldGuardCount or 0,
            },
            settings = {
                skin = settings.skin,
                showInWheel = settings.showInWheel == true,
                customsOnly = settings.customsOnly == true,
                offsetMs = settings.offsetMs or 0,
                bgEnabled = settings.bgEnabled == true,
                bgTransparency = settings.bgTransparency or 0,
            },
        }
    end,
    -- Multi-difficulty parents: { songId = { difficulty names, easiest first } }
    parents = function()
        local out = {}
        for id, p in pairs(parents) do
            local names = {}
            for i, d in ipairs(p.diffs) do names[i] = diffName(d.chart) end
            out[id] = names
        end
        return out
    end,
    -- Console equivalents of clicking a parent row / a difficulty button.
    openPicker = function(songId)
        local p = parents[songId]
        if not p then return false end
        -- native wheel page first (falls back to the overlay when the wheel
        -- controller can't be driven)
        if HK.openWheelSubmenu then
            local okW, res = pcall(HK.openWheelSubmenu, p)
            if okW and res == true then return true end
        end
        -- same mutual exclusion as the trigger path above
        local wb = hookBase["WheelMenu"]
        if type(wb) == "table" then wb.pendingSongId = nil; wb.pendingToken = nil end
        local fc = findWheelController()
        if fc then
            local okFS, fst = pcall(function() return fc._uiState end)
            local okFO, fop = pcall(function() return fc._isOpen end)
            if okFS and fst == "Open" and okFO and fop == true then
                pcall(function() fc:_transitionPage(function() end) end)
            end
        end
        openPicker(p)
        return true
    end,
    pick = function(songId, index)
        local p = parents[songId]
        local d = p and p.diffs[index]
        if not d then return false end
        task.spawn(pickDifficulty, p, d)   -- may yield (audio pre-cache)
        return true
    end,
    closePicker = function()
        local wb = hookBase["WheelMenu"]
        if type(wb) == "table" then wb.pendingSongId = nil; wb.pendingToken = nil end
        local c = findWheelController()
        if c then
            local okS, st = pcall(function() return c._uiState end)
            if okS and st == "Open" then
                -- back to the song list with the native transition
                pcall(function() c:_transitionPage(function() end) end)
            end
        end
        destroyPicker()
    end,
    pickerStatus = function()
        local b = hookBase["StartPlay"]
        local wb = hookBase["WheelMenu"]
        local n = 0
        for _ in pairs(parents) do n += 1 end
        local pendingValid = false
        if type(wb) == "table" and type(wb.pendingSongId) == "string" then
            pendingValid = (os.time() - (wb.pendingAt or 0)) < 30
        end
        return {
            parents = n,
            open = pickerGui ~= nil,
            hooked = type(b) == "table" and b.mod.StartPlay == b.wrap,
            handlerSet = type(b) == "table" and b.handler == HK.pickerHandler,
            bypass = type(b) == "table" and b.bypass == true,
            wheel = findWheelController() ~= nil,
            submenuPending = pendingValid,
        }
    end,
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
            spawnExtended = svSpawnExt,
            spawnCapped = svSpawnCapped,
            spawnOrderFix = svSpawnOrderFix,
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
        local recLanes = 0
        if ss and type(ss.recImgs) == "table" then
            for _ in pairs(ss.recImgs) do recLanes += 1 end
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
            recLanes = recLanes,
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
