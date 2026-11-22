local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- /gcr perf on (0.2.3; Sven's performance diagnosis, 22.11.2026: a friend
-- reports strong lags): one minute of what each part of the addon takes.
--   The parts' own handlers - their timers, OnUpdate and event scripts,
--   hooks and listeners - are wrapped once at load (ns.PerfWrap). Off, a
--   wrapper only passes the call on: nothing is measured, no clock is read.
--   On, each call's time is booked to its part, without the time of other
--   wrapped calls inside it (those book their own). What no wrapper covers
--   (the core's events, the windows, crafting, fishing, questing) is not in
--   the numbers.
--   At the start and at the end: the addon's memory (the game adds it up for
--   all addons, so only then), the Lua memory of all addons (rough: the game
--   collects garbage meanwhile) and how many world map pins HereBeDragons has
--   in use. Once a second the largest of those. No game setting is changed;
--   nothing is saved - after /reload it is off.
--   The result is one line in chat and in a box to copy (Ctrl+C): chat
--   lines cannot be copied in the game.
---------------------------------------------------------------------------
local MODULES = { "Route", "Pins", "Minimap", "Sync", "Tooltip", "Prices", "Rares", "SearchRange", "RunHistory", "VisitLog",
    "UI", "Paths", "Questie" }
local SECONDS = 60

local on = false
local books = {}
local depth, stackMod, stackT, stackSelf = 0, {}, {}, {}
local run -- the measurement going on: start, memory, pins, its ticker

local function Book(mod, ms)
    local b = books[mod]
    if not b then
        b = { n = 0, ms = 0, max = 0 }
        books[mod] = b
    end
    b.n = b.n + 1
    b.ms = b.ms + ms
    if ms > b.max then b.max = ms end
end

-- fn wrapped for its part: called as it is while nothing is measured
function ns.PerfWrap(mod, fn)
    return function(...)
        if not on then return fn(...) end
        local now = debugprofilestop()
        if depth > 0 then stackSelf[depth] = stackSelf[depth] + (now - stackT[depth]) end
        depth = depth + 1
        stackMod[depth], stackT[depth], stackSelf[depth] = mod, now, 0
        local a, b, c, d, e = fn(...)
        if depth > 0 then
            now = debugprofilestop()
            Book(stackMod[depth], stackSelf[depth] + (now - stackT[depth]))
            depth = depth - 1
            if depth > 0 then stackT[depth] = now end
        end
        return a, b, c, d, e
    end
end

-- C_Timer for one file of a part: every callback it is given is wrapped
-- (the game's C_Timer is looked up at each call - the file keeps none of its own)
function ns.PerfTimers(mod)
    return {
        After = function(seconds, fn) return C_Timer.After(seconds, ns.PerfWrap(mod, fn)) end,
        NewTicker = function(seconds, fn, n) return C_Timer.NewTicker(seconds, ns.PerfWrap(mod, fn), n) end,
        NewTimer = function(seconds, fn) return C_Timer.NewTimer(seconds, ns.PerfWrap(mod, fn)) end,
    }
end

-- the addon's memory in KB, where the client tells it
local function AddonKB()
    if type(UpdateAddOnMemoryUsage) ~= "function" or type(GetAddOnMemoryUsage) ~= "function" then return end
    local ok, kb = pcall(function()
        UpdateAddOnMemoryUsage()
        return GetAddOnMemoryUsage(ADDON_NAME)
    end)
    if ok and type(kb) == "number" and not (ns.AnySecret and ns.AnySecret("perf", kb)) then return kb end
end
local function LuaKB()
    local ok, kb = pcall(collectgarbage, "count")
    if ok and type(kb) == "number" then return kb end
end
-- world map pins HereBeDragons has in use now (its pool), or nil
local function WorldPinsInUse()
    local lib = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
    local pool = lib and lib.worldmapPinsPool
    if not (pool and pool.GetNumActive) then return end
    local ok, n = pcall(pool.GetNumActive, pool)
    if ok and type(n) == "number" then return n end
end

local function MB(kb) return kb and ("%.1f"):format(kb / 1024) or "?" end

local function Version()
    return (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version")) or "?"
end

local function Result(seconds, kb1, lua1, pins1)
    local parts = {}
    for _, mod in ipairs(MODULES) do
        local b = books[mod] or { n = 0, ms = 0, max = 0 }
        parts[#parts + 1] = ("%s %.1f ms (%.2f ms/s, longest %.1f ms, %d calls)"):format(mod, b.ms, b.ms / seconds, b.max, b.n)
    end
    local mem
    if run.kb0 and kb1 then
        mem = ("memory: addon %s -> %s MB (%+.1f KB/s)"):format(MB(run.kb0), MB(kb1), (kb1 - run.kb0) / seconds)
    else
        mem = "memory: addon not readable in this client"
    end
    local lua = ("Lua of all addons %s -> %s MB (rough: the game collects garbage meanwhile)"):format(MB(run.lua0), MB(lua1))
    local ours = ns.WorldPinCount and ns.WorldPinCount() or 0
    local pins
    if pins1 then
        pins = ("world map pins in HereBeDragons: %d now, at most %d (ours %d)"):format(pins1, math.max(run.peak or pins1, pins1), ours)
    else
        pins = ("world map pins in HereBeDragons: not readable (ours %d)"):format(ours)
    end
    local near, inZone = 0, 0
    if ns.MiniPinCounts then near, inZone = ns.MiniPinCounts() end
    return ("Gathercraft %s perf, %d s: %s | not measured: the rest of the addon; %s; %s; %s; minimap pins %d near / %d in zone"):format(
        Version(), seconds, table.concat(parts, " | "), mem, lua, pins, near, inZone)
end

local function ShowCopy(line)
    if not (StaticPopupDialogs and StaticPopup_Show) then return end
    StaticPopupDialogs.GATHERCRAFT_PERF = StaticPopupDialogs.GATHERCRAFT_PERF or {
        text = "",
        button1 = OKAY or "OK",
        hasEditBox = true,
        editBoxWidth = 350,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
        OnShow = function(self)
            local eb = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
            if eb then
                -- (the line is longer than an edit box takes by default)
                if eb.SetMaxLetters then eb:SetMaxLetters(0) end
                if eb.SetMaxBytes then eb:SetMaxBytes(0) end
                eb:SetText(StaticPopupDialogs.GATHERCRAFT_PERF.line or "")
                eb:SetFocus()
                eb:HighlightText()
            end
        end,
        EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    }
    StaticPopupDialogs.GATHERCRAFT_PERF.text = L["Press Ctrl+C to copy the perf result:"]
    StaticPopupDialogs.GATHERCRAFT_PERF.line = line
    StaticPopup_Show("GATHERCRAFT_PERF")
end

local function Finish()
    if not run then return end
    on = false
    depth = 0
    if run.ticker then run.ticker:Cancel() end
    local seconds = math.max(1, math.floor(GetTime() - run.start + 0.5))
    local line = Result(seconds, AddonKB(), LuaKB(), WorldPinsInUse())
    run = nil
    if ns.Print then ns.Print(line) end
    ShowCopy(line)
end

-- once a second: the most pins in use; a wrapper left by an error is let go
-- (the ticker itself runs outside every wrapper)
local function Sample()
    if not run then return end
    depth = 0
    local n = WorldPinsInUse()
    if n and (not run.peak or n > run.peak) then run.peak = n end
    if GetTime() - run.start >= SECONDS - 0.01 then Finish() end
end

local function Start()
    wipe(books)
    depth = 0
    run = { start = GetTime(), kb0 = AddonKB(), lua0 = LuaKB() }
    run.peak = WorldPinsInUse()
    on = true
    run.ticker = C_Timer.NewTicker(1, Sample)
    if ns.Print then ns.Print(L["Gathercraft perf: measuring for one minute. /gcr perf off stops it early."]) end
end

-- /gcr perf on | off
function ns.PerfCommand(what)
    if what == "on" then
        if run then
            local left = math.max(1, math.ceil(SECONDS - (GetTime() - run.start) - 0.01))
            if ns.Print then ns.Print((L["Gathercraft perf: already measuring, %d s to go."]):format(left)) end
            return
        end
        Start()
    elseif run then
        Finish()
    elseif ns.Print then
        ns.Print(L["Gathercraft perf: not measuring. /gcr perf on starts a minute."])
    end
end
ns.PerfMeasuring = function() return on end
