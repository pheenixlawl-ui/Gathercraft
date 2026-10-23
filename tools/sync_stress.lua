-- Usage: luajit tools/sync_stress.lua <path to Gathercraft folder> [scenario]
--
-- Network simulation for Gathercraft's node sharing: loads the addon once per
-- simulated player (each in its own environment), connects them through a fake
-- chat server and lets them gather, share and query like real players.
-- Scenarios: fuzz, normal, attack, launch, mega, all (default)
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

local function deliver(from, prefix, msg, dist)
    for _, c in ipairs(clients) do
        if c.online and (dist == "CHANNEL" or (dist == "GUILD" and c.guild and c.guild == from.guild)) then
            c.fire("CHAT_MSG_ADDON", prefix, msg, dist, from.fullName)
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
    local ps = net.perSender[from.name] or { times = {} }
    net.perSender[from.name] = ps
    ps.times[#ps.times + 1] = NOW
    hpush({ at = NOW + 0.05 + math.random() * 0.2, fn = function() deliver(from, prefix, msg, dist) end })
    return 0
end

---------------------------------------------------------------------------
-- One simulated player = one addon instance in its own environment
---------------------------------------------------------------------------
local sharedData = {} -- Data/*.lua, loaded once for all players
local function NewClient(name, guild)
    local c = { name = name, fullName = name .. "-Forever", guild = guild, online = false, cpu = 0, recvCalls = 0, out = {} }
    local E = setmetatable({}, { __index = _G })
    E._G = E
    local player = { map = ZONE, x = 0.5, y = 0.5 }
    c.player = player
    local eventFrames = {}

    E.unpack = unpack
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
    E.GetAddOnMetadata = function() return "0.1.0" end
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
    local toc = io.open(ROOT .. "/Gathercraft.toc"):read("*a")
    for line in toc:gmatch("[^\r\n]+") do
        if line:match("^Data") and line:match("%.lua$") and not line:match("QuestieNodes") then
            -- data files only set read-only globals: load them once and share
            -- them (thousands of players fit into memory)
            local data = sharedData[line]
            if not data then
                data = {}
                local chunk = assert(loadfile(ROOT .. "/" .. line:gsub("\\", "/")))
                setfenv(chunk, setmetatable(data, { __index = _G }))
                chunk("Gathercraft", {})
                sharedData[line] = data
            end
            for k, v in pairs(data) do E[k] = v end
        elseif not line:match("^#") and line:match("%.lua$") and not line:match("^Libs") and not line:match("QuestieNodes") then
            local chunk = assert(loadfile(ROOT .. "/" .. line:gsub("\\", "/")))
            setfenv(chunk, E)
            local ok, e = pcall(chunk, "Gathercraft", ns)
            if not ok then addError("load " .. line .. ": " .. tostring(e)) end
        end
    end
    return c
end

local function Login(c)
    c.online = true
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
            id = 7000000 + (i % 12), x = 0.2 + math.random() * 0.6, y = 0.2 + math.random() * 0.6,
            type = herb and "herb" or "ore", name = (herb and "Forever Herb " or "Forever Ore ") .. (i % 12), item = herb and 2447 or 2770,
            gathered = false,
        }
    end
end

local spawnCounter = 0
local function Gather(c, spot)
    local p = c.player
    p.x = spot.x + (math.random() - 0.5) * 0.0006
    p.y = spot.y + (math.random() - 0.5) * 0.0006
    spawnCounter = spawnCounter + 1
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
    end
    if extra then extra(online) end
end

local function Reset()
    clients = {}
    heap = {}
    net = { channel = 0, guild = 0, bySecond = {}, perSender = {}, bytes = 0 }
    freshNodes = {}
end

-- Players log in spread over `spread` seconds, then gather every `every` seconds (random +-50%)
local function Populate(count, spread, every, freshShare)
    for i = 1, count do
        local guild = (i % 4 ~= 0) and ("G" .. math.floor(i / 10)) or nil
        local c = NewClient("P" .. i, guild)
        clients[#clients + 1] = c
        hpush({ at = NOW + math.random() * spread, fn = function()
            Login(c)
            -- GC_ROUTEQ=1: everyone starts a farm run through 3 other zones
            -- right after login (the route asks for those zones too)
            if os.getenv("GC_ROUTEQ") and c.ns.SyncQueryRouteZones then
                local zones = {}
                for _ = 1, 3 do zones[#zones + 1] = 1415 + math.random(0, 9) end
                hpush({ at = NOW + 5, fn = function() c.ns.SyncQueryRouteZones(zones) end })
            end
            local function nextGather()
                local spot
                if math.random() < freshShare then
                    spot = freshNodes[math.random(#freshNodes)]
                else
                    spot = questieSpots[math.random(#questieSpots)]
                end
                Gather(c, spot)
                hpush({ at = NOW + every * (0.5 + math.random()), fn = nextGather })
            end
            hpush({ at = NOW + 15 + math.random() * every, fn = nextGather })
        end })
    end
end

---------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------
local scenarios = {}

scenarios.normal = function()
    Reset()
    math.randomseed(1)
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

scenarios.launch = function()
    Reset()
    math.randomseed(2)
    MakeFreshNodes(120)
    Populate(250, 60, 25, 0.3)
    runUntil(NOW + 10 * 60)
    Report("Launch day rush", 10 * 60)
end

scenarios.mega = function()
    Reset()
    math.randomseed(5)
    MakeFreshNodes(150)
    Populate(800, 120, 25, 0.3)
    runUntil(NOW + 5 * 60)
    Report("Whole realm in one zone", 5 * 60)
end

-- Forever megaserver: one channel for a whole ruleset (run on its own: slow)
scenarios.mega3k = function()
    Reset()
    math.randomseed(7)
    MakeFreshNodes(200)
    Populate(tonumber(os.getenv("GC_PLAYERS") or "") or 3000, 180, 25, 0.3)
    runUntil(NOW + 5 * 60)
    Report("Megaserver, many players in one zone", 5 * 60)
end

scenarios.attack = function()
    Reset()
    math.randomseed(3)
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
            parts[k] = ("o%d,h,%d,%d,2447"):format(id, math.random(1000, 9000), math.random(1000, 9000))
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
    math.randomseed(4)
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
        for k = 1, math.random(1, 80) do s[k] = string.char(math.random(32, 126)) end
        samples[#samples + 1] = (math.random() < 0.5 and "N:1412;" or "") .. table.concat(s)
    end
    for i, msg in ipairs(samples) do
        hpush({ at = NOW + i * 0.3, fn = function() deliver(evil, "Gathercraft", msg, "CHANNEL") end })
    end
    runUntil(NOW + #samples * 0.3 + 20)
    Report("Fuzz (" .. #samples .. " broken messages)", 120)
end

local order = { "fuzz", "normal", "attack", "launch", "mega", "mega3k" }
for _, name in ipairs(order) do
    if (ONLY == "all" and name ~= "mega3k") or ONLY == name then
        local t0 = os.clock()
        scenarios[name]()
        print(("  (simulated in %.1f s)"):format(os.clock() - t0))
    end
end

print(("\n--- errors: %d"):format(errors.total or 0))
for _, e in ipairs(errors) do print("  " .. e) end
