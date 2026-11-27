-- Usage: luajit tools/sync_stress.lua <path to Gathercraft folder> [scenario]
--
-- Network simulation for Gathercraft's node sharing: loads the addon once per
-- simulated player (each in its own environment), connects them through a fake
-- chat server and lets them gather, share and query like real players.
-- Scenarios: fuzz, normal, attack, launch, mega, answers, echo, all (default)
local ROOT = arg[1] or "."
local ONLY = arg[2] or "all"
local unpack = unpack or table.unpack

---------------------------------------------------------------------------
-- Shared clock + scheduler (binary heap)
---------------------------------------------------------------------------
local NOW = 1000
local heap, seq = {}, 0
local function hpush(t)
    seq = seq + 1
    t.seq = seq
    heap[#heap + 1] = t
    local i = #heap
    while i > 1 do
        local p = math.floor(i / 2)
        local a, b = heap[p], heap[i]
        if a.at < b.at or (a.at == b.at and a.seq < b.seq) then break end
        heap[p], heap[i] = b, a
        i = p
    end
end
local function hpop()
    local top = heap[1]
    local last = table.remove(heap)
    if #heap > 0 then
        heap[1] = last
        local i, n = 1, #heap
        while true do
            local l, r, s = i * 2, i * 2 + 1, i
            local function less(x, y) return heap[x].at < heap[y].at or (heap[x].at == heap[y].at and heap[x].seq < heap[y].seq) end
            if l <= n and less(l, s) then s = l end
            if r <= n and less(r, s) then s = r end
            if s == i then break end
            heap[i], heap[s] = heap[s], heap[i]
            i = s
        end
    end
    return top
end

---------------------------------------------------------------------------
-- Two streams of random numbers (R1 S-M3; Codex, 13.11.2026)
--   Everything used one stream: the world (who logs in when, who gathers
-- what where) and the protocol (how long a message travels, how long the
-- addon waits before it asks or answers). A change to the addon draws more
-- or fewer numbers - and with the same seed the players then gathered other
-- things at other times: "before" and "after" were not the same evening.
--   Now the world has a stream of its own (wrandom) and the protocol
-- another (prandom; math.random inside the addon is this one). Every
-- harvest and login is noted in a checksum that is printed with each
-- scenario: two runs with the same world print the same line.
--   (Lehmer's generator, 48271 mod 2^31 - 1: exact in Lua's numbers and the
-- same on every machine.)
---------------------------------------------------------------------------
local function NewRandom()
    local state = 1
    local function nextFloat()
        state = (state * 48271) % 2147483647
        return (state - 1) / 2147483646
    end
    local function random(a, b)
        local r = nextFloat()
        if not a then return r end
        if not b then a, b = 1, a end
        return a + math.floor(r * (b - a + 1))
    end
    local function seed(n)
        state = (n * 2654435 + 12345) % 2147483646 + 1
        for _ = 1, 10 do nextFloat() end
    end
    return random, seed
end
local wrandom, wseed = NewRandom()
local prandom, pseed = NewRandom()
local function Seed(n)
    wseed(n)
    pseed(n + 7919)
end
Seed(0)

-- What the world did to the players: harvests and logins, in a checksum
local trace = { harvests = 0, logins = 0, sum = 0 }
local function Trace(kind, ...)
    trace[kind] = trace[kind] + 1
    local sum = (trace.sum * 31 + (kind == "harvests" and 1 or 2)) % 2147483647
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then
            for k = 1, #v do sum = (sum * 31 + v:byte(k)) % 2147483647 end
        else
            sum = (sum * 31 + math.floor(v)) % 2147483647
        end
    end
    trace.sum = sum
end

local errors = {}
local function addError(e)
    if #errors < 50 then errors[#errors + 1] = e end
    errors.total = (errors.total or 0) + 1
end

local function runUntil(target)
    while heap[1] and heap[1].at <= target do
        local t = hpop()
        NOW = t.at
        if not t.cancelled then
            local ok, err = pcall(t.fn)
            if not ok then addError("timer: " .. tostring(err)) end
            if t.every and not t.cancelled then
                t.at = NOW + t.every
                hpush(t)
            end
        end
    end
    NOW = target
end

---------------------------------------------------------------------------
-- Shared data
---------------------------------------------------------------------------
do
    local chunk = assert(loadfile(ROOT .. "/Data/QuestieNodes.lua"))
    chunk()
end
local QUESTIE = GathercraftQuestieData
local ZONE = 1412 -- Mulgore

-- Known spawn points of the zone (everyone has these from the addon data)
local questieSpots = {}
for id, x, y in QUESTIE.zones[ZONE]:gmatch("(%d+),(%d+),(%d+)") do
    local kind = QUESTIE.kinds["o" .. id]
    if kind and kind[1] ~= "c" then
        questieSpots[#questieSpots + 1] = { id = tonumber(id), x = x / 10000, y = y / 10000, type = kind[1] == "h" and "herb" or "ore", name = kind[3], item = kind[2] }
    end
end

---------------------------------------------------------------------------
-- Fake chat server
---------------------------------------------------------------------------
local clients = {}
local net = { channel = 0, guild = 0, bySecond = {}, perSender = {}, bytes = 0 }

-- net.echo: does a player hear his own messages? nil = yes (as the live
-- realms do), "missing" = never, "late" = net.lateBy seconds after everybody
-- else; a function (client) may say it per player. Everybody gets the
-- messages in one order - the order they were sent in when net.latency is a
-- fixed time.
local function EchoMode(c)
    local mode = net.echo
    if type(mode) == "function" then mode = mode(c) end
    return mode
end

local function deliver(from, prefix, msg, dist, onlyOwn)
    for _, c in ipairs(clients) do
        if c.online and (dist == "CHANNEL" or (dist == "GUILD" and c.guild and c.guild == from.guild)) then
            local own = c == from
            if (onlyOwn and own) or (not onlyOwn and not (own and EchoMode(c))) then
                c.fire("CHAT_MSG_ADDON", prefix, msg, dist, from.fullName)
            end
        end
    end
end

local function serverSend(from, prefix, msg, dist)
    if #msg > 255 then addError("message too long (" .. #msg .. ") from " .. from.name) end
    local sec = math.floor(NOW)
    net.bySecond[sec] = (net.bySecond[sec] or 0) + (dist == "CHANNEL" and 1 or 0)
    if dist == "CHANNEL" then net.channel = net.channel + 1 else net.guild = net.guild + 1 end
    net.bytes = net.bytes + #msg
    if dist == "CHANNEL" and msg:sub(1, 2) == "N:" then
        for id in msg:gmatch(";o(%d+),") do
            if QUESTIE.kinds["o" .. id] then net.knownNodes = (net.knownNodes or 0) + 1
            else net.newNodes = (net.newNodes or 0) + 1 end
        end
    elseif dist == "CHANNEL" and msg:sub(1, 2) == "Q:" then
        net.queries = (net.queries or 0) + 1
    end
    if net.log and dist == "CHANNEL" then
        local _, count = msg:gsub(";", ";")
        net.log[#net.log + 1] = { at = NOW, from = from.name, kind = msg:sub(1, 1), nodes = count }
    end
    local ps = net.perSender[from.name] or { times = {} }
    net.perSender[from.name] = ps
    ps.times[#ps.times + 1] = NOW
    local after = net.latency or (0.05 + prandom() * 0.2)
    hpush({ at = NOW + after, fn = function() deliver(from, prefix, msg, dist) end })
    if EchoMode(from) == "late" then
        hpush({ at = NOW + after + (net.lateBy or 5), fn = function() deliver(from, prefix, msg, dist, true) end })
    end
    return 0
end

-- The addon's own dice (its waits before asking and answering): a scenario
-- may fix them, so that every player waits the same time
local addonRandom

---------------------------------------------------------------------------
-- One simulated player = one addon instance in its own environment
---------------------------------------------------------------------------
local sharedData = {} -- Data/*.lua, loaded once for all players (of one folder)
-- The version in a folder's TOC (what the client says it runs)
local tocVersion = {}
local function TocVersion(root)
    if tocVersion[root] == nil then
        local toc = io.open(root .. "/Gathercraft.toc"):read("*a")
        tocVersion[root] = toc:match("## Version: ([%w%.%-]+)") or "0.1.0"
    end
    return tocVersion[root]
end
-- root: the Gathercraft folder this player runs (scenario "mixed": an older
-- version for some of them); ROOT when not given
local function NewClient(name, guild, root)
    root = root or ROOT
    local c = { name = name, fullName = name .. "-Forever", guild = guild, online = false, cpu = 0, recvCalls = 0, out = {}, root = root }
    local E = setmetatable({}, { __index = _G })
    E._G = E
    local player = { map = ZONE, x = 0.5, y = 0.5 }
    c.player = player
    local eventFrames = {}

    E.unpack = unpack
    E.math = setmetatable({ random = function(...)
        if addonRandom then return addonRandom(...) end
        return prandom(...)
    end }, { __index = math })
    E.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    E.tinsert = table.insert
    E.strsplit = function(sep, s)
        local out = {}
        for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%-", "%%-")) do out[#out + 1] = part end
        return unpack(out)
    end
    E.tDeleteItem = function(t, v) for i = #t, 1, -1 do if t[i] == v then table.remove(t, i) end end end
    E.debugprofilestop = function() return os.clock() * 1000 end
    E.GetTime = function() return NOW end
    E.time = function() return 1792400000 + math.floor(NOW) end
    E.print = function(...) c.out[#c.out + 1] = table.concat({ tostring((...)) }, " ") if #c.out > 200 then table.remove(c.out, 1) end end
    E.hooksecurefunc = function(t, n, fn) local o = t[n] t[n] = function(...) local r = { o(...) } fn(...) return unpack(r) end end
    E.GetBuildInfo = function() return "1.60.1", "70450", "Oct", 16001 end
    E.InCombatLockdown = function() return false end
    E.IsShiftKeyDown = function() return false end
    E.GetFramerate = function() return 60 end
    E.FlashClientIcon = function() end
    E.PlaySound = function() end
    E.PlaySoundFile = function() return true end
    E.SOUNDKIT = { RAID_WARNING = 8959 }
    E.GetCVar = function() return "0" end
    E.SetCVar = function() end
    E.GetBindingKey = function() return nil end
    E.SetOverrideBinding = function() end
    E.ClearOverrideBindings = function() end
    E.IsInGuild = function() return guild ~= nil end
    E.Ambiguate = function(n) return (n:gsub("%-Forever$", "")) end
    E.GetNormalizedRealmName = function() return "Forever" end
    E.CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
    E.Enum = {}
    E.UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m = m, x = x, y = y } end }
    E.NUM_CHAT_WINDOWS = 10
    E.GetChatWindowInfo = function() return "General" end
    E.GetChannelName = function() return 5, "GathercraftSync" end
    E.JoinTemporaryChannel = function() end
    E.LeaveChannelByName = function() end
    E.ChatFrame_RemoveChannel = function() end
    E.RaidNotice_AddMessage = function() end
    E.GetAddOnMetadata = function(_, field) if field == "Version" then return TocVersion(root) end return "0.1.0" end
    E.C_AddOns = { GetAddOnMetadata = E.GetAddOnMetadata }
    E.GetPlayerFacing = function() return 0 end
    E.UnitName = function(u) return u == "player" and name or "Mob" end
    E.UnitGUID = function() return "Creature-0-1-1-1-1234-ABCDEF" end
    E.UnitExists = function() return false end
    E.UnitIsDead = function() return false end
    E.UnitIsPlayer = function() return false end
    E.UnitLevel = function() return 12 end
    E.UnitIsTapDenied = function() return false end
    E.UnitClassification = function() return "normal" end
    E.IsPlayerSpell = function() return false end
    E.GetInventoryItemID = function() return nil end
    E.GetWeaponEnchantInfo = function() return false end
    E.GetItemCount = function() return 0 end
    E.GetItemIcon = function() return 134400 end
    E.GetSpellInfo = function(id) return "Spell" .. tostring(id) end
    local PROFS = { { "Herbalism", 52, 75, 182 }, { "Mining", 30, 75, 186 } }
    E.GetProfessions = function() return 1, 2 end
    E.GetProfessionInfo = function(i) local p = PROFS[i] return p[1], 0, p[2], p[3], 0, 0, p[4] end
    E.GetNumSkillLines = function() return 0 end
    E.GetSkillLineInfo = function() end

    -- frames
    local methods = {}
    local FrameMT = { __index = function(t, k)
        if methods[k] then return methods[k] end
        if type(k) == "string" and k:match("^%u") then return function() return nil end end
    end }
    local function newObject(kind, fname, parent)
        local o = setmetatable({ __scripts = {}, __shown = true, __parent = parent }, FrameMT)
        if fname then E[fname] = o end
        return o
    end
    function methods:SetScript(s, fn) self.__scripts[s] = fn end
    function methods:GetScript(s) return self.__scripts[s] end
    function methods:HookScript(s, fn) local o = self.__scripts[s] self.__scripts[s] = function(...) if o then o(...) end fn(...) end end
    function methods:RegisterEvent(e) eventFrames[e] = eventFrames[e] or {} eventFrames[e][self] = true end
    methods.RegisterUnitEvent = methods.RegisterEvent
    function methods:UnregisterEvent(e) if eventFrames[e] then eventFrames[e][self] = nil end end
    function methods:Show() local w = self.__shown self.__shown = true if not w and self.__scripts.OnShow then self.__scripts.OnShow(self) end end
    function methods:Hide() local w = self.__shown self.__shown = false if w and self.__scripts.OnHide then self.__scripts.OnHide(self) end end
    function methods:SetShown(v) if v then self:Show() else self:Hide() end end
    function methods:IsShown() return self.__shown end
    function methods:IsVisible() local f = self while f do if not f.__shown then return false end f = f.__parent end return true end
    function methods:SetParent(p) self.__parent = p end
    function methods:GetParent() return self.__parent end
    function methods:CreateFontString() return newObject("FontString", nil, self) end
    function methods:CreateTexture() return newObject("Texture", nil, self) end
    function methods:SetText(t) self.__text = t end
    function methods:GetText() return self.__text end
    function methods:GetWidth() return 200 end
    function methods:GetHeight() return 100 end
    function methods:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function methods:GetCenter() return 500, 400 end
    function methods:GetEffectiveScale() return 1 end
    function methods:GetChecked() return self.__checked end
    function methods:SetChecked(v) self.__checked = v end
    function methods:GetFrameStrata() return "MEDIUM" end
    function methods:IsEnabled() return true end
    function methods:SetAttribute(k, v) self.__attr = self.__attr or {} self.__attr[k] = v end
    function methods:GetAttribute(k) return self.__attr and self.__attr[k] end
    function methods:GetStringWidth() return 50 end
    function methods:GetMapID() return ZONE end
    function methods:IsMouseOver() return false end
    function methods:GetNumPoints() return 1 end
    E.CreateFrame = function(kind, fname, parent) return newObject(kind, fname, parent) end
    E.UIParent = newObject("Frame", "UIParent")
    E.UIParent.__shown = false -- nothing visible: no OnUpdate work in the simulation
    E.Minimap = newObject("Frame", "Minimap")
    E.WorldMapFrame = newObject("Frame", "WorldMapFrame")
    E.WorldMapFrame.OnMapChanged = function() end
    E.GameTooltip = newObject("GameTooltip", "GameTooltip")
    E.DEFAULT_CHAT_FRAME = newObject("Frame", "DEFAULT_CHAT_FRAME")
    E.DEFAULT_CHAT_FRAME.AddMessage = function(_, m) E.print(m) end
    E.ChatFrame1 = E.DEFAULT_CHAT_FRAME
    E.RaidWarningFrame = newObject("Frame", "RaidWarningFrame")
    E.UISpecialFrames = {}
    E.SlashCmdList = {}

    local function schedule(s, fn, every)
        local t = { at = NOW + s, fn = fn, every = every }
        hpush(t)
        return { Cancel = function() t.cancelled = true end }
    end
    E.C_Timer = {
        After = function(s, fn) schedule(s, fn) end,
        NewTicker = function(s, fn) return schedule(s, fn, s) end,
        NewTimer = function(s, fn) return schedule(s, fn) end,
    }

    E.C_Map = {
        GetBestMapForUnit = function() return player.map end,
        GetPlayerMapPosition = function() return { x = player.x, y = player.y, GetXY = function(s) return s.x, s.y end } end,
        GetMapInfo = function(id)
            if type(id) ~= "number" or id < 1 or id > 3000 then return nil end
            if id == 1414 then return { mapID = 1414, name = "Kalimdor", mapType = 2, parentMapID = 947 } end
            if id == 947 then return { mapID = 947, name = "Azeroth", mapType = 1, parentMapID = 0 } end
            return { mapID = id, name = "Zone" .. id, mapType = 3, parentMapID = 1414 }
        end,
        GetMapWorldSize = function() return 5000, 3333 end,
        CanSetUserWaypointOnMap = function() return true end,
        SetUserWaypoint = function() end,
        ClearUserWaypoint = function() end,
    }
    E.C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
    E.C_Spell = { GetSpellName = function(id)
        local n = { [2366] = "Herbalism", [2575] = "Mining", [3365] = "Opening", [7620] = "Fishing" }
        return n[id] or ("Spell" .. id)
    end }
    E.C_Item = {
        GetItemIconByID = function() return 134400 end,
        GetItemNameByID = function(id) return "Item" .. id end,
        GetItemCount = function() return 0 end,
        GetItemInfoInstant = function(id) return id, nil, nil, nil, nil, 0, 0 end,
    }
    E.C_Container = { GetContainerNumSlots = function() return 0 end, GetContainerItemID = function() end }
    E.C_FriendList = { GetFriendInfo = function() return nil end }
    E.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        SendAddonMessage = function(prefix, msg, dist) return serverSend(c, prefix, msg, dist) end,
    }
    local loot = {}
    c.loot = loot
    E.GetNumLootItems = function() return #loot end
    E.GetLootSourceInfo = function(i) return loot[i] and loot[i].guid end
    E.GetLootSlotLink = function(i) return loot[i] and ("|Hitem:" .. loot[i].item .. "::|h") end

    local libs = {}
    E.LibStub = setmetatable({}, { __call = function(_, n) return libs[n] end })
    libs["HereBeDragons-2.0"] = {
        GetWorldCoordinatesFromZone = function(_, x, y, map) return x * 5000 + (map - 1400) * 6000, y * 3333, 1 end,
        GetPlayerWorldPosition = function() return player.x * 5000 + (player.map - 1400) * 6000, player.y * 3333, 1 end,
        GetWorldVector = function(_, inst, ox, oy, dx, dy) return 1.0, math.sqrt((dx - ox) ^ 2 + (dy - oy) ^ 2) end,
    }
    local noop = function() end
    libs["HereBeDragons-Pins-2.0"] = setmetatable({}, { __index = function() return noop end })
    libs["LibDataBroker-1.1"] = { NewDataObject = function(_, n, o) return o end }
    libs["LibDBIcon-1.0"] = setmetatable({}, { __index = function() return noop end })

    E.GathercraftQuestieData = QUESTIE -- shared, read only

    c.fire = function(event, ...)
        local t0 = os.clock()
        for f in pairs(eventFrames[event] or {}) do
            local fn = f.__scripts.OnEvent
            if fn then
                local ok, err = pcall(fn, f, event, ...)
                if not ok then addError(name .. " " .. event .. ": " .. tostring(err)) end
            end
        end
        if event == "CHAT_MSG_ADDON" then
            c.cpu = c.cpu + (os.clock() - t0)
            c.recvCalls = c.recvCalls + 1
        end
    end

    -- load the addon
    local ns = {}
    c.ns = ns
    c.E = E
    -- (R2-M1) how many packets this player's answer has, as the addon plans
    -- it: its line "answering zone ... with N nodes in M packets" is made
    -- whether debug is on or not, and the contract tells long answers (more
    -- than 2 packets) from short ones. Only read - nothing else changes.
    c.planned = nil
    local function Watch(debug)
        return function(text, ...)
            local m = type(text) == "string" and text:match("answering zone %d+ with %d+ nodes in (%d+) packets")
            if m then c.planned = tonumber(m) end
            return debug(text, ...)
        end
    end
    local toc = io.open(root .. "/Gathercraft.toc"):read("*a")
    for line in toc:gmatch("[^\r\n]+") do
        if line:match("^Data") and line:match("%.lua$") and not line:match("QuestieNodes") then
            -- data files only set read-only globals: load them once and share
            -- them (thousands of players fit into memory)
            local data = sharedData[root .. "|" .. line]
            if not data then
                data = {}
                local chunk = assert(loadfile(root .. "/" .. line:gsub("\\", "/")))
                setfenv(chunk, setmetatable(data, { __index = _G }))
                chunk("Gathercraft", {})
                sharedData[root .. "|" .. line] = data
            end
            for k, v in pairs(data) do E[k] = v end
        elseif not line:match("^#") and line:match("%.lua$") and not line:match("^Libs") and not line:match("QuestieNodes") then
            local chunk = assert(loadfile(root .. "/" .. line:gsub("\\", "/")))
            setfenv(chunk, E)
            local ok, e = pcall(chunk, "Gathercraft", ns)
            if not ok then addError("load " .. line .. ": " .. tostring(e)) end
            if ns.Debug and not c.watched then ns.Debug, c.watched = Watch(ns.Debug), true end
        end
    end
    if not c.watched then addError(name .. ": no ns.Debug to read the size of an answer from") end
    return c
end

local function Login(c)
    c.online = true
    Trace("logins", NOW * 1000, c.name)
    c.fire("ADDON_LOADED", "Gathercraft")
    c.fire("PLAYER_LOGIN")
    c.fire("PLAYER_ENTERING_WORLD")
    c.fire("ZONE_CHANGED_NEW_AREA")
end

---------------------------------------------------------------------------
-- The world: new Forever nodes nobody knows yet + the known spawn points
---------------------------------------------------------------------------
local freshNodes = {}
local function MakeFreshNodes(n)
    freshNodes = {}
    for i = 1, n do
        local herb = i % 2 == 0
        freshNodes[i] = {
            id = 7000000 + (i % 12), x = 0.2 + wrandom() * 0.6, y = 0.2 + wrandom() * 0.6,
            type = herb and "herb" or "ore", name = (herb and "Forever Herb " or "Forever Ore ") .. (i % 12), item = herb and 2447 or 2770,
            gathered = false,
        }
    end
end

local spawnCounter = 0
local function Gather(c, spot)
    local p = c.player
    p.x = spot.x + (wrandom() - 0.5) * 0.0006
    p.y = spot.y + (wrandom() - 0.5) * 0.0006
    spawnCounter = spawnCounter + 1
    Trace("harvests", NOW * 1000, c.name, spot.id, p.x * 1000000, p.y * 1000000)
    local spell = spot.type == "herb" and 2366 or 2575
    local cast = "cast" .. spawnCounter
    c.fire("UNIT_SPELLCAST_SENT", "player", spot.name, cast, spell)
    c.fire("UNIT_SPELLCAST_SUCCEEDED", "player", cast, spell)
    c.loot[1] = { guid = ("GameObject-0-1-1-1-%d-%08X"):format(spot.id, spawnCounter), item = spot.item }
    c.fire("LOOT_READY")
    c.loot[1] = nil
    spot.gathered = true
end

local function Knows(c, spot)
    return c.ns.FindNode(ZONE, "o" .. spot.id, spot.x, spot.y, 15) ~= nil
end

---------------------------------------------------------------------------
-- Report
---------------------------------------------------------------------------
local function SyncStatus(c)
    c.out = {}
    c.ns.SyncCommand("")
    local text = table.concat(c.out, "\n")
    local dropped = tonumber(text:match("Dropped %(budget%): (%d+)")) or 0
    local pending = tonumber(text:match("Waiting for confirmation: (%d+)")) or 0
    local imported = tonumber(text:match("Imported this session: (%d+)")) or 0
    return dropped, pending, imported
end

-- Floors for "known per player, average" (the share of the new nodes every
-- player knows at the end); below them sharing got worse and the run fails.
-- v0.1.13 had 97 / 99 / 96 %; a recorder that dropped your own gathers of
-- nodes that came from sync (0.1.14 before the fix) had 51 / 18 / 35 %.
-- The realm floor is lower: 800 players in 5 min leave the last ones less time.
local KNOWN_FLOOR = { ["Normal evening"] = 90, ["Launch day rush"] = 90, ["Whole realm in one zone"] = 85, ["Mixed versions"] = 90 }

local function Report(title, duration, extra)
    local online = {}
    for _, c in ipairs(clients) do if c.online then online[#online + 1] = c end end
    local peak = 0
    for _, v in pairs(net.bySecond) do peak = math.max(peak, v) end
    local maxBurst, maxRate = 0, 0
    for _, ps in pairs(net.perSender) do
        local t = ps.times
        local j = 1
        for i = 1, #t do
            while t[i] - t[j] > 10 do j = j + 1 end
            maxBurst = math.max(maxBurst, i - j + 1)
        end
        maxRate = math.max(maxRate, #t / duration)
    end
    local cpu, calls, dropped, pending, imported = 0, 0, 0, 0, 0
    local cpuMax = 0
    for _, c in ipairs(online) do
        cpu, calls = cpu + c.cpu, calls + c.recvCalls
        cpuMax = math.max(cpuMax, c.cpu)
        local d, p, i = SyncStatus(c)
        dropped, pending, imported = dropped + d, pending + p, imported + i
    end
    local fresh = 0
    for _, s in ipairs(freshNodes) do if s.gathered then fresh = fresh + 1 end end
    local covSum, covMin = 0, 1
    if fresh > 0 then
        for _, c in ipairs(online) do
            local k = 0
            for _, s in ipairs(freshNodes) do if s.gathered and Knows(c, s) then k = k + 1 end end
            covSum = covSum + k / fresh
            covMin = math.min(covMin, k / fresh)
        end
    end
    local n = #online
    print(("\n=== %s: %d players, %d min ==="):format(title, n, duration / 60))
    print(("  Channel messages: %d total, %.2f/s average, peak %d/s  (guild: %d)"):format(net.channel, net.channel / duration, peak, net.guild))
    print(("  Channel content: %d node reports already in everyone's spawn data, %d new ones, %d zone queries"):format(
        net.knownNodes or 0, net.newNodes or 0, net.queries or 0))
    print(("  Traffic per player received: %.1f KB  (%.0f bytes/s)"):format(net.bytes / 1024, net.bytes / duration))
    print(("  Busiest sender: %.2f msg/s average, %d messages in the worst 10 s"):format(maxRate, maxBurst))
    print(("  CPU per player: %.3f ms per message, %.1f ms total (worst player %.1f ms)"):format(
        calls > 0 and cpu * 1000 / calls or 0, n > 0 and cpu * 1000 / n or 0, cpuMax * 1000))
    print(("  Dropped by the incoming budget: %d (all players)   Waiting for confirmation: %.1f per player"):format(dropped, n > 0 and pending / n or 0))
    if fresh > 0 then
        print(("  New nodes found by someone: %d   known per player: %.0f%% average, %.0f%% worst"):format(fresh, covSum / n * 100, covMin * 100))
        local floor = KNOWN_FLOOR[title]
        if floor and covSum / n * 100 < floor then
            addError(("%s: new nodes known per player %.0f%% on average, the floor is %d%%"):format(title, covSum / n * 100, floor))
        end
    end
    if extra then extra(online) end
end

local function Reset()
    clients = {}
    heap = {}
    net = { channel = 0, guild = 0, bySecond = {}, perSender = {}, bytes = 0 }
    freshNodes = {}
    addonRandom = nil
end

-- Players log in spread over `spread` seconds, then gather every `every` seconds (random +-50%)
-- rootOf(i): the folder player i runs (scenario "mixed"), nil = ROOT
local function Populate(count, spread, every, freshShare, rootOf)
    for i = 1, count do
        local guild = (i % 4 ~= 0) and ("G" .. math.floor(i / 10)) or nil
        local c = NewClient("P" .. i, guild, rootOf and rootOf(i))
        clients[#clients + 1] = c
        hpush({ at = NOW + wrandom() * spread, fn = function()
            Login(c)
            -- GC_ROUTEQ=1: everyone starts a farm run through 3 other zones
            -- right after login (the route asks for those zones too)
            if os.getenv("GC_ROUTEQ") and c.ns.SyncQueryRouteZones then
                local zones = {}
                for _ = 1, 3 do zones[#zones + 1] = 1415 + wrandom(0, 9) end
                hpush({ at = NOW + 5, fn = function() c.ns.SyncQueryRouteZones(zones) end })
            end
            local function nextGather()
                local spot
                if wrandom() < freshShare then
                    spot = freshNodes[wrandom(#freshNodes)]
                else
                    spot = questieSpots[wrandom(#questieSpots)]
                end
                Gather(c, spot)
                hpush({ at = NOW + every * (0.5 + wrandom()), fn = nextGather })
            end
            hpush({ at = NOW + 15 + wrandom() * every, fn = nextGather })
        end })
    end
end

---------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------
local scenarios = {}

scenarios.normal = function()
    Reset()
    Seed(1)
    MakeFreshNodes(60)
    Populate(40, 120, 60, 0.3)
    runUntil(NOW + 25 * 60)
    -- five players log in late and only rely on asking the others
    local late = {}
    for i = 1, 5 do
        local c = NewClient("Late" .. i, nil)
        clients[#clients + 1] = c
        late[i] = c
        Login(c)
    end
    runUntil(NOW + 5 * 60)
    Report("Normal evening", 30 * 60, function()
        local fresh, sum = 0, 0
        for _, s in ipairs(freshNodes) do if s.gathered then fresh = fresh + 1 end end
        for _, c in ipairs(late) do
            local k = 0
            for _, s in ipairs(freshNodes) do if s.gathered and Knows(c, s) then k = k + 1 end end
            sum = sum + k / fresh
        end
        print(("  Late joiners (logged in at minute 25, no guild): know %.0f%% of the new nodes after 5 min"):format(sum / #late * 100))
    end)
end

-- 0.2.2 P1 d1: an evening like "normal", every second player with an older
-- Gathercraft (GC_OLD_ROOT = its folder, e.g. an export of v0.2.1). The new
-- ones say their version ("V:gc<version>") once after joining; the old ones
-- must leave it alone: no error, and sharing works as before for both (the
-- floor of "normal" for each). The new ones hear only new ones' versions.
scenarios.mixed = function()
    local OLD = os.getenv("GC_OLD_ROOT")
    if not OLD or OLD == "" then
        print("\n=== Mixed versions: skipped (GC_OLD_ROOT = the folder of an older Gathercraft) ===")
        return
    end
    Reset()
    Seed(1)
    MakeFreshNodes(60)
    local function RootOf(i) return (i % 2 == 1) and OLD or nil end
    Populate(40, 120, 60, 0.3, RootOf)
    runUntil(NOW + 25 * 60)
    for i = 1, 6 do
        local c = NewClient("Late" .. i, nil, RootOf(i))
        clients[#clients + 1] = c
        Login(c)
    end
    runUntil(NOW + 5 * 60)
    local newVersion, oldVersion = TocVersion(ROOT), TocVersion(OLD)
    Report("Mixed versions", 30 * 60, function(online)
        local groups = { old = {}, new = {} }
        for _, c in ipairs(online) do table.insert(c.root == OLD and groups.old or groups.new, c) end
        local fresh = 0
        for _, s in ipairs(freshNodes) do if s.gathered then fresh = fresh + 1 end end
        for key, list in pairs(groups) do
            local sum = 0
            for _, c in ipairs(list) do
                local k = 0
                for _, s in ipairs(freshNodes) do if s.gathered and Knows(c, s) then k = k + 1 end end
                sum = sum + k / math.max(1, fresh)
            end
            local share = #list > 0 and sum / #list * 100 or 0
            print(("  %s clients (%s): %d online, know %.0f%% of the new nodes on average"):format(key == "old" and "Old" or "New",
                key == "old" and oldVersion or newVersion, #list, share))
            if share < KNOWN_FLOOR["Mixed versions"] then
                addError(("Mixed versions: the %s clients know %.0f%% of the new nodes, the floor is %d%%"):format(key, share, KNOWN_FLOOR["Mixed versions"]))
            end
        end
        -- what the new ones heard: the versions of the players that run - the new one, and (0.2.4 a14) the old one where
        -- the old client says its version itself (0.2.2 d1 on: a "V:gc" message; 0.2.1 says none); never one that no
        -- client sent
        local oldSays = false
        do
            local f = io.open(OLD .. "/Sync.lua", "r")
            if f then
                oldSays = f:read("*a"):find('"V:gc"', 1, true) ~= nil
                f:close()
            end
        end
        local most, oldMost, wrong = 0, 0, 0
        for _, c in ipairs(groups.new) do
            c.out = {}
            c.ns.SyncCommand("")
            local line
            for _, l in ipairs(c.out) do if l:find("Versions of the players seen", 1, true) then line = l end end
            if not line then
                addError("Mixed versions: " .. c.name .. " shows no versions line")
            else
                for v, n in line:gmatch("([%w%.%-]+): (%d+)") do
                    if v == newVersion then
                        most = math.max(most, tonumber(n))
                    elseif v == oldVersion and oldSays and oldVersion ~= newVersion then
                        oldMost = math.max(oldMost, tonumber(n))
                    elseif v ~= "heard" then
                        wrong = wrong + tonumber(n)
                    end
                end
            end
        end
        print(("  Versions heard by the new clients: at most %d of the %d other new players, at most %d of the %d old ones (%s %s), %d of another version"):format(most,
            #groups.new - 1, oldMost, #groups.old, oldVersion, oldSays and "says its version" or "says none", wrong))
        if most < 1 or most > #groups.new - 1 then addError(("Mixed versions: a new client heard %d versions of %d other new players"):format(most, #groups.new - 1)) end
        if oldSays and (oldMost < 1 or oldMost > #groups.old) then
            addError(("Mixed versions: a new client heard %d versions of %d old players that say theirs"):format(oldMost, #groups.old))
        end
        if wrong > 0 then addError(("Mixed versions: %d versions heard that no client sent"):format(wrong)) end
    end)
end

scenarios.launch = function()
    Reset()
    Seed(2)
    MakeFreshNodes(120)
    Populate(250, 60, 25, 0.3)
    runUntil(NOW + 10 * 60)
    Report("Launch day rush", 10 * 60)
end

scenarios.mega = function()
    Reset()
    Seed(5)
    MakeFreshNodes(150)
    Populate(800, 120, 25, 0.3)
    runUntil(NOW + 5 * 60)
    Report("Whole realm in one zone", 5 * 60)
end

-- Forever megaserver: one channel for a whole ruleset (run on its own: slow)
scenarios.mega3k = function()
    Reset()
    Seed(7)
    MakeFreshNodes(200)
    Populate(tonumber(os.getenv("GC_PLAYERS") or "") or 3000, 180, 25, 0.3)
    runUntil(NOW + 5 * 60)
    Report("Megaserver, many players in one zone", 5 * 60)
end

scenarios.attack = function()
    Reset()
    Seed(3)
    MakeFreshNodes(40)
    Populate(30, 30, 60, 0.3)
    runUntil(NOW + 60)
    -- 1) a flooder: one name, 20 messages per second of fake nodes
    -- 2) two colluding names reporting the same 40 fake nodes
    -- 3) twenty throwaway names, each reporting 150 different fake nodes
    local fakeIds = {}
    local flooder = { name = "Flooder", fullName = "Flooder-Forever" }
    local evilA = { name = "EvilA", fullName = "EvilA-Forever" }
    local evilB = { name = "EvilB", fullName = "EvilB-Forever" }
    -- every group of attackers uses its own fake object IDs, so reports of
    -- different attackers never land on the same fake node by accident
    local function fakeMsg(seed, count)
        local parts = {}
        for k = 1, count do
            local id = 8000000 + seed * 10 + k
            fakeIds[id] = true
            parts[k] = ("o%d,h,%d,%d,2447"):format(id, wrandom(1000, 9000), wrandom(1000, 9000))
        end
        return "N:" .. ZONE .. ";" .. table.concat(parts, ";")
    end
    for s = 1, 20 * 120 do
        hpush({ at = NOW + s / 20, fn = function() deliver(flooder, "Gathercraft", fakeMsg(s, 8), "CHANNEL") end })
    end
    for s = 1, 5 do
        local msg = fakeMsg(100000 + s, 8) -- the same message from both names
        hpush({ at = NOW + s * 2, fn = function() deliver(evilA, "Gathercraft", msg, "CHANNEL") end })
        hpush({ at = NOW + s * 2 + 1, fn = function() deliver(evilB, "Gathercraft", msg, "CHANNEL") end })
    end
    for b = 1, 20 do
        local bot = { name = "Bot" .. b, fullName = "Bot" .. b .. "-Forever" }
        for s = 1, 19 do
            local msg = fakeMsg(200000 + b * 100 + s, 8)
            hpush({ at = NOW + 5 + s * 3 + b * 0.1, fn = function() deliver(bot, "Gathercraft", msg, "CHANNEL") end })
        end
    end
    runUntil(NOW + 5 * 60)
    Report("Attack", 6 * 60, function(online)
        local accepted, worst = 0, 0
        for _, c in ipairs(online) do
            local k = 0
            for _, n in ipairs(c.ns.db.nodes[ZONE] or {}) do
                if n.id and fakeIds[tonumber(n.id:match("%d+"))] then k = k + 1 end
            end
            accepted = accepted + k
            worst = math.max(worst, k)
        end
        local pend = 0
        for _, c in ipairs(online) do
            for _, list in pairs(c.ns.db.sync.pending) do pend = pend + #list end
        end
        print(("  Fake nodes accepted: %.1f per player (worst %d)   fake reports stored as pending: %.0f per player"):format(
            accepted / #online, worst, pend / #online))
    end)
end

scenarios.fuzz = function()
    Reset()
    Seed(4)
    Populate(3, 1, 60, 0)
    runUntil(NOW + 20)
    local evil = { name = "Fuzzer", fullName = "Fuzzer-Forever" }
    local samples = {
        "", "N:", "N:;", "Q:", "Q:abc", "Q:1412:", "Q:-5:3", "N:1412", "N:1412;", "N:1412;;;;",
        "N:99999999;o1,h,1,1,1", "N:1412;o1,h,-1,5,0", "N:1412;o1,h,1e999,5,0", "N:1412;o1,h,nan,5,0",
        "N:1412;o1,h,0x10,0x10,0", "N:1412;o1,x,5,5,0", "N:1412;i5,h,5,5,0", "N:1412;o1,h,5", "N:1412;o,h,5,5,5",
        "N:1412;o1,h,5,5,99999999999999999999", "N:1412;" .. ("o1,h,5,5,0;"):rep(200), "N:1412;o1;h;5;5",
        "N:1412.5;o1,h,5,5,0", "N:-1;o1,h,5,5,0", "X:hello", "n:1412;o1,h,5,5,0", ("A"):rep(5000),
        "N:1412;o1,h,5,5,0\0garbage", "N:1412;o1,h, 5 , 5 ,0", "N:1412;o0001,h,5,5,0", "Q:1412:999999999999999",
    }
    for i = 1, 200 do
        local s = {}
        for k = 1, wrandom(1, 80) do s[k] = string.char(wrandom(32, 126)) end
        samples[#samples + 1] = (wrandom() < 0.5 and "N:1412;" or "") .. table.concat(s)
    end
    for i, msg in ipairs(samples) do
        hpush({ at = NOW + i * 0.3, fn = function() deliver(evil, "Gathercraft", msg, "CHANNEL") end })
    end
    runUntil(NOW + #samples * 0.3 + 20)
    Report("Fuzz (" .. #samples .. " broken messages)", 120)
end

-- The answer contract of 0.1.22 (Sven, 14.11.2026, R2-M1: it is written down
-- as it is built, and replaces E1 of 13.11.), checked, not only printed -
-- neither weaker nor stricter:
--   - long answers (more than 2 packets): at most 3 players send more than 2
--     packets. Where the own messages come back in time, at most 3 send more
--     than 1. Where they do not, or late, a player who is not one of the
--     three sends 2 packets at most and stops.
--   - where only some players hear their own messages in time (mixed):
--     at most 6 send more than 2 packets - the first 3 in the channel who
--     hear themselves, and 3 more by name among the others (Sven,
--     14.11.2026); everybody else sends 2 at most.
--   - short answers (1 or 2 packets in all) may come from more than 3
--     players - started together, they are out before they hear each other;
--     nobody sends more than 2 of them;
--   - nobody answers with a single node: every first packet has 2 or more;
--   - when somebody knows enough for an answer, one complete answer at
--     least arrives; when nobody does, nobody answers.
--   players: { name, packets (sent), planned (the answer's packets),
-- first (nodes in the first packet), complete }; echo: "in time" (everybody
-- hears his own messages as the realms do), "not in time" (nobody does, or
-- everybody late) or "mixed"; worth: how many knew enough.
local MAX_LONG = { ["in time"] = 3, ["not in time"] = 3, mixed = 6 }
local function CheckContract(title, players, echo, worth)
    local overTwo, longOverOne, complete = 0, 0, 0
    for _, p in ipairs(players) do
        if p.packets > 2 then overTwo = overTwo + 1 end
        if p.planned and p.planned > 2 and p.packets > 1 then longOverOne = longOverOne + 1 end
        if p.complete then complete = complete + 1 end
        if not p.planned then
            addError(("%s: %s sent %d packet(s) of an answer whose size was never said"):format(title, p.name, p.packets))
        elseif p.packets > p.planned then
            addError(("%s: %s sent %d packets of an answer of %d"):format(title, p.name, p.packets, p.planned))
        end
        if p.first < 2 then addError(("%s: %s answered with a first packet of %d node(s)"):format(title, p.name, p.first)) end
    end
    local most = assert(MAX_LONG[echo], "echo: " .. tostring(echo))
    print(("  Contract (own messages %s): %d knew enough; %d sent more than 2 packets (at most %d), %d went past the first packet of a long answer%s, %d complete answers")
        :format(echo, worth, overTwo, most, longOverOne, echo == "in time" and " (at most 3)" or "", complete))
    if overTwo > most then addError(("%s: %d players sent more than 2 packets, at most %d may"):format(title, overTwo, most)) end
    if echo == "in time" and longOverOne > 3 then
        addError(("%s: own messages back in time, and %d players went past the first packet of a long answer, at most 3 may"):format(title, longOverOne))
    end
    if worth > 0 and complete < 1 then addError(("%s: %d players knew enough, and no complete answer arrived"):format(title, worth)) end
    if worth == 0 and #players > 0 then addError(("%s: nobody knew enough for an answer, and %d answered"):format(title, #players)) end
    return complete
end

-- One question, many who could answer (v0.1.22 S; Sven's debug logs of
-- 11. and 12.11.2026: 6-7 players answered one question, and one sent 150
-- nodes to somebody who knew 151). `knowers` players stand in the zone and
-- know a share of its `world` new nodes; nobody gathers. Then one player
-- who knows `asked` of them logs in and asks. Counted for two minutes: who
-- answers, with how many messages and nodes, and what the asker takes.
--   GC_ANSWERS="knowers,world,share from,share to,asked" changes the case.
local function AnswerCase(title, knowers, world, shareFrom, shareTo, asked, seed)
    Reset()
    Seed(seed)
    MakeFreshNodes(world)
    for i, s in ipairs(freshNodes) do s.id = 7000000 + i end -- (each its own object: none merges with another)
    local function Teach(c, share)
        local list = c.ns.db.nodes[ZONE] or {}
        c.ns.db.nodes[ZONE] = list
        local k = 0
        for _, s in ipairs(freshNodes) do
            if wrandom() < share then
                k = k + 1
                list[#list + 1] = { id = "o" .. s.id, type = s.type, x = s.x, y = s.y, name = s.name, item = s.item, count = wrandom(1, 9) }
            end
        end
        c.ns.NotifyNodesChanged()
        return k
    end
    for i = 1, knowers do
        local c = NewClient("K" .. i, nil)
        clients[#clients + 1] = c
        hpush({ at = NOW + wrandom() * 60, fn = function() Login(c) end })
    end
    -- their own questions at login are over and forgotten
    runUntil(NOW + 20 * 60)
    local knownMin, knownMax, knows = math.huge, 0, {}
    for _, c in ipairs(clients) do
        local k = Teach(c, shareFrom + wrandom() * (shareTo - shareFrom))
        knownMin, knownMax, knows[c.name] = math.min(knownMin, k), math.max(knownMax, k), k
    end
    net = { channel = 0, guild = 0, bySecond = {}, perSender = {}, bytes = 0, log = {} }
    local asker = NewClient("Asker", nil)
    clients[#clients + 1] = asker
    local start = NOW
    for _, c in ipairs(clients) do c.planned = nil end
    Login(asker)
    local before = 0
    if asked > 0 then
        -- the first `asked` nodes of the world: what the others know too
        local list = asker.ns.db.nodes[ZONE] or {}
        asker.ns.db.nodes[ZONE] = list
        for i = 1, math.min(asked, #freshNodes) do
            local s = freshNodes[i]
            list[#list + 1] = { id = "o" .. s.id, type = s.type, x = s.x, y = s.y, name = s.name, item = s.item, count = 1 }
        end
        asker.ns.NotifyNodesChanged()
    end
    for _, s in ipairs(freshNodes) do if Knows(asker, s) then before = before + 1 end end
    runUntil(NOW + 120)
    local senders, messages, nodes, last, queries = {}, 0, 0, 0, 0
    for _, m in ipairs(net.log) do
        if m.kind == "Q" then queries = queries + 1 end
        if m.kind == "N" and m.from ~= "Asker" then
            if not senders[m.from] then senders[m.from] = 0 senders[#senders + 1] = m.from end
            senders[m.from] = senders[m.from] + 1
            messages, nodes, last = messages + 1, nodes + m.nodes, math.max(last, m.at - start)
        end
    end
    local now = 0
    for _, s in ipairs(freshNodes) do if Knows(asker, s) then now = now + 1 end end
    print(("\n=== %s ==="):format(title))
    print(("  %d players know %d-%d of the zone's %d new nodes; the asker knew %d and asked %d time(s)"):format(knowers, knownMin, knownMax, world, before, queries))
    print(("  Answering players: %d   their messages: %d   nodes sent: %d   last message after %.0f s"):format(#senders, messages, nodes, last))
    local each = {}
    for i, name in ipairs(senders) do each[i] = senders[name] end
    table.sort(each, function(x, y) return x > y end)
    print("  Messages of each answering player: " .. (#each > 0 and table.concat(each, " ") or "-"))
    print(("  The asker knows %d now (%d new); %d of the nodes sent were of no use to him"):format(now, now - before, nodes - (now - before)))
    -- the contract (see CheckContract); everybody hears his own messages here, in time
    local sentBy, firstNodes, byName = {}, {}, {}
    for _, c in ipairs(clients) do byName[c.name] = c end
    for _, m in ipairs(net.log) do
        if m.kind == "N" and m.from ~= "Asker" then
            sentBy[m.from] = (sentBy[m.from] or 0) + m.nodes
            firstNodes[m.from] = firstNodes[m.from] or m.nodes
        end
    end
    local players, worth = {}, 0
    for _, name in ipairs(senders) do
        players[#players + 1] = { name = name, packets = senders[name], planned = byName[name].planned, first = firstNodes[name],
            complete = sentBy[name] >= math.min(knows[name] or math.huge, 150) }
    end
    for _, k in pairs(knows) do
        local sent = math.min(k, 150)
        local more = math.max(math.ceil(before * 0.2), math.min(20, before), 2)
        if sent >= 2 and sent >= before + more then worth = worth + 1 end
    end
    CheckContract(title, players, "in time", worth)
    return { answering = #senders, messages = messages, nodes = nodes, gained = now - before }
end

scenarios.answers = function()
    local custom = os.getenv("GC_ANSWERS")
    if custom then
        local k, w, a, b, q = custom:match("^(%d+),(%d+),([%d.]+),([%d.]+),(%d+)$")
        AnswerCase("One question (custom)", tonumber(k), tonumber(w), tonumber(a), tonumber(b), tonumber(q), 11)
        return
    end
    AnswerCase("One question, 40 who know more, the asker knows nothing", 40, 120, 0.5, 1, 0, 11)
    AnswerCase("One question, 40 who know more, the asker knows 151 of 300", 40, 300, 0.5, 1, 151, 12)
    AnswerCase("One question, 40 who know a little more than the asker (100 of 120)", 40, 120, 0.85, 1, 100, 13)
    AnswerCase("One question, 8 who know more, the asker knows nothing", 8, 120, 0.5, 1, 0, 14)
    AnswerCase("One question, 8 who know one node each, the asker knows nothing", 8, 1, 1, 1, 0, 15)
    AnswerCase("One question, 8 who know the same 6 nodes (one packet each), the asker knows nothing", 8, 6, 1, 1, 0, 16)
end

-- Everybody starts at the same moment, and the own packet does not come back
-- (R1 S-M1; Codex, 13.11.2026, "echo-missing-ordered": 8 players who know the
-- same 120 nodes each sent one packet, heard three others before the second
-- and stopped - 8 messages, 9 of 120 nodes learned). `knowers` players log
-- in in the same instant (their send tickers tick together), know the same
-- `world` nodes and wait the same time before they answer; every message
-- reaches everybody 0.1 s after it was sent, in the order it was sent.
--   echo: nil = everybody hears himself, "missing", "late" (5 s after the
-- others), "mixed" (every second player hears himself, the others never),
-- or "first three" (only the first three in the channel hear themselves).
--   reversed: the names go the other way round than the order in the
-- channel (K8 sends first, K1 last) - with "mixed", those who never hear
-- themselves then come first by name.
-- Checked: the contract (see CheckContract); with everybody alike (no mix)
-- the asker has everything afterwards.
local function EchoCase(title, knowers, world, echo, lateBy, reversed)
    Reset()
    Seed(21)
    MakeFreshNodes(world)
    for i, s in ipairs(freshNodes) do s.id = 7000000 + i end
    net.latency, net.lateBy = 0.1, lateBy
    addonRandom = function(a, b) if a then return b and math.floor((a + b) / 2) or a end return 0.5 end
    for i = 1, knowers do
        local c = NewClient("K" .. (reversed and (knowers - i + 1) or i), nil)
        clients[#clients + 1] = c
        Login(c)
    end
    runUntil(NOW + 20 * 60)
    for _, c in ipairs(clients) do
        local list = {}
        c.ns.db.nodes[ZONE] = list
        for _, s in ipairs(freshNodes) do
            list[#list + 1] = { id = "o" .. s.id, type = s.type, x = s.x, y = s.y, name = s.name, item = s.item, count = 1 }
        end
        c.ns.NotifyNodesChanged()
    end
    if echo == "mixed" or echo == "first three" then
        -- mixed: every second one never hears himself; first three: only the first three in the channel hear themselves
        local without = {}
        for i, c in ipairs(clients) do if (echo == "mixed" and i % 2 == 1) or (echo == "first three" and i > 3) then without[c] = true end end
        net.echo = function(c) return without[c] and "missing" or nil end
    else
        net.echo = echo
    end
    net.log = {}
    for _, c in ipairs(clients) do c.planned = nil end
    local asker = NewClient("Asker", nil)
    clients[#clients + 1] = asker
    Login(asker)
    runUntil(NOW + 180)
    local packets, nodes, names, messages, first = {}, {}, {}, 0, {}
    for _, m in ipairs(net.log) do
        if m.kind == "N" and m.from ~= "Asker" then
            if not packets[m.from] then names[#names + 1] = m.from first[m.from] = m.nodes end
            packets[m.from], nodes[m.from] = (packets[m.from] or 0) + 1, (nodes[m.from] or 0) + m.nodes
            messages = messages + 1
        end
    end
    local byName = {}
    for _, c in ipairs(clients) do byName[c.name] = c end
    local each, players = {}, {}
    for i, name in ipairs(names) do
        each[i] = packets[name]
        players[i] = { name = name, packets = packets[name], planned = byName[name].planned, first = first[name], complete = nodes[name] >= world }
    end
    table.sort(each, function(x, y) return x > y end)
    -- who went on past the second packet, by name (with "mixed": those who never hear themselves are marked *)
    local full = {}
    for _, name in ipairs(names) do
        if packets[name] > 2 then full[#full + 1] = name .. ((type(net.echo) == "function" and net.echo(byName[name])) and "*" or "") end
    end
    table.sort(full)
    local learned = 0
    for _, s in ipairs(freshNodes) do
        for _, n in ipairs(asker.ns.db.nodes[ZONE] or {}) do
            if n.id == "o" .. s.id then learned = learned + 1 break end
        end
    end
    print(("\n=== %s ==="):format(title))
    print(("  %d players know the same %d nodes and start together; own messages: %s"):format(knowers, world, echo and (echo .. (echo == "late" and (" by " .. (lateBy or 5) .. " s") or "")) or "heard back"))
    print(("  Answering players: %d   messages: %d   packets of each: %s   (planned: %s)"):format(#names, messages, #each > 0 and table.concat(each, " ") or "-",
        players[1] and tostring(players[1].planned) or "-"))
    print(("  The asker learned %d of %d   more than 2 packets: %s"):format(learned, world, #full > 0 and table.concat(full, " ") or "nobody"))
    local worth = world >= 2 and knowers or 0 -- (the asker knows nothing: everybody who knows 2 or more knows enough)
    local complete = CheckContract(title, players, echo == nil and "in time" or (echo == "mixed" or echo == "first three") and "mixed" or "not in time", worth)
    if echo ~= "mixed" and echo ~= "first three" and learned < world then addError(("%s: the asker learned %d of %d"):format(title, learned, world)) end
    return complete, learned, messages
end

scenarios.echo = function()
    -- Codex's six cases of R2-M1 (14.11.2026), fixed: 8 start together with 120, 6 or 12 nodes.
    -- Codex measured 14 14 14 1 1 1 1 1 / 14 14 14 2 2 2 2 2 (also 5 s and 0.9 s late) /
    -- eight answers of 1 packet (with and without echo) / eight answers of 2 packets.
    EchoCase("Echo: 8 start together, everybody hears himself (R2-M1: 120 nodes, echo in time)", 8, 120, nil)
    EchoCase("Echo: 8 start together, nobody hears himself (Codex's echo-missing-ordered; R2-M1: 120 nodes, no echo)", 8, 120, "missing")
    EchoCase("Echo: 8 start together, the own message comes 5 s late (R2-M1: 120 nodes, late)", 8, 120, "late", 5)
    EchoCase("Echo: 8 start together, the own message comes 0.9 s late, before the second packet (R2-M1: 120 nodes, late)", 8, 120, "late", 0.9)
    EchoCase("Echo: 8 start together with 6 nodes (one packet), everybody hears himself (R2-M1)", 8, 6, nil)
    EchoCase("Echo: 8 start together with 6 nodes (one packet), nobody hears himself (R2-M1)", 8, 6, "missing")
    EchoCase("Echo: 8 start together with 12 nodes (two packets), nobody hears himself (R2-M1)", 8, 12, "missing")
    -- and around them
    EchoCase("Echo: 8 start together with 12 nodes (two packets), everybody hears himself", 8, 12, nil)
    EchoCase("Echo: 8 start together, every second one never hears himself", 8, 120, "mixed")
    EchoCase("Echo: 8 start together, every second one never hears himself, and those come first by name", 8, 120, "mixed", nil, true)
    EchoCase("Echo: 8 start together, only the first three hear themselves, the others come first by name", 8, 120, "first three", nil, true)
    EchoCase("Echo: 40 start together, nobody hears himself", 40, 120, "missing")
    EchoCase("Echo: 3 start together, nobody hears himself", 3, 120, "missing")
end

local order = { "fuzz", "normal", "mixed", "attack", "launch", "mega", "mega3k", "answers", "echo" }
for _, name in ipairs(order) do
    if (ONLY == "all" and name ~= "mega3k") or ONLY == name then
        local t0 = os.clock()
        trace.harvests, trace.logins, trace.sum = 0, 0, 0
        scenarios[name]()
        print(("  World of \"%s\": %d harvests, %d logins, checksum %d"):format(name, trace.harvests, trace.logins, trace.sum))
        print(("  (simulated in %.1f s)"):format(os.clock() - t0))
    end
end

print(("\n--- errors: %d"):format(errors.total or 0))
for _, e in ipairs(errors) do print("  " .. e) end
