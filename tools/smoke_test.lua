-- Usage: luajit tools/smoke_test.lua <path to Gathercraft folder>
-- Mini WoW environment to smoke-test Gathercraft outside the game.
local ROOT = arg[1]
local errors, log = {}, {}
local function note(...) local t = {} for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end log[#log + 1] = table.concat(t, " ") end

-- ---------------------------------------------------------------- basics
unpack = unpack or table.unpack
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
tinsert = table.insert
strsplit = function(sep, s)
    local out, i = {}, 1
    for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%-", "%%-")) do out[#out + 1] = part end
    return unpack(out)
end
tDeleteItem = function(t, v) for i = #t, 1, -1 do if t[i] == v then table.remove(t, i) end end end
debugprofilestop = function() return os.clock() * 1000 end
local NOW = 1000
GetTime = function() return NOW end
time = function() return 1792400000 + math.floor(NOW) end
print = function(...) note("PRINT", ...) end
hooksecurefunc = function(t, name, fn)
    local orig = t[name]
    t[name] = function(...) local r = { orig(...) } fn(...) return unpack(r) end
end
GetBuildInfo = function() return "1.60.1", "70450", "Oct", 16001 end
InCombatLockdown = function() return false end
IsShiftKeyDown = function() return false end
GetFramerate = function() return 60 end
FlashClientIcon = function() end
PlaySound = function(id) note("SOUND", id) end
PlaySoundFile = function(path) note("SOUNDFILE", path) return true end
SOUNDKIT = { RAID_WARNING = 8959 }
GetCVar = function() return "0" end
SetCVar = function(k, v) note("CVAR", k, v) end
GetBindingKey = function() return "F" end
SetOverrideBinding = function(_, _, key, cmd) note("BIND", key, cmd) end
ClearOverrideBindings = function() end
IsInGuild = function() return true end
Ambiguate = function(n) return n end
GetNormalizedRealmName = function() return "Forever" end
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
Enum = {}
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m = m, x = x, y = y } end }
NUM_CHAT_WINDOWS = 10
GetChatWindowInfo = function(i) return "General" end
FCF_OpenNewWindow = function() return _G.ChatFrame1 end
GetChannelName = function() return 5, "GathercraftSync" end
JoinTemporaryChannel = function() end
LeaveChannelByName = function() end
ChatFrame_RemoveChannel = function() end
RaidNotice_AddMessage = function(_, msg) note("RAIDWARN", msg) end
GetAddOnMetadata = function() return "0.1.0" end
C_AddOns = { GetAddOnMetadata = GetAddOnMetadata }
GetPlayerFacing = function() return 0 end
UnitName = function(u) return u == "player" and "Test Player" or "Old Murk-Eye" end
UnitGUID = function(u) return "Creature-0-1-1-1-1234-ABCDEF" end
UnitExists = function() return true end
UnitIsDead = function() return false end
UnitIsPlayer = function() return false end
UnitLevel = function() return 12 end
UnitIsTapDenied = function() return false end
local classification = "normal"
UnitClassification = function() return classification end
IsPlayerSpell = function(id) return id == 7620 end
GetInventoryItemID = function() return nil end
GetWeaponEnchantInfo = function() return false end
GetItemCount = function() return 0 end
GetItemIcon = function() return 134400 end
GetSpellInfo = function(id) return "Spell" .. tostring(id) end

-- professions: herbalism 52/75, mining 30/75, fishing 1/75
local PROFS = { { "Herbalism", 52, 75, 182 }, { "Mining", 30, 75, 186 }, nil, { "Fishing", 1, 75, 356 }, nil, nil }
GetProfessions = function() return 1, 2, nil, 4, nil, nil end
GetProfessionInfo = function(i)
    local p = PROFS[i]
    return p[1], 0, p[2], p[3], 0, 0, p[4]
end
GetNumSkillLines = function() return 0 end
GetSkillLineInfo = function() end

-- ---------------------------------------------------------------- frames
local allFrames, eventFrames = {}, {}
local FrameMT = {}
local function newObject(kind, name, parent)
    local o = { __kind = kind, __scripts = {}, __shown = (kind ~= "Frame" and kind ~= "Button" and kind ~= "CheckButton" and kind ~= "ScrollFrame" and kind ~= "StatusBar") or true, __parent = parent, __points = 0, __text = nil }
    setmetatable(o, FrameMT)
    if name then _G[name] = o end
    allFrames[#allFrames + 1] = o
    return o
end
local methods = {}
function methods:SetScript(s, fn) self.__scripts[s] = fn end
function methods:GetScript(s) return self.__scripts[s] end
function methods:HookScript(s, fn) local o = self.__scripts[s] self.__scripts[s] = function(...) if o then o(...) end fn(...) end end
function methods:RegisterEvent(e) eventFrames[e] = eventFrames[e] or {} eventFrames[e][self] = true end
methods.RegisterUnitEvent = methods.RegisterEvent
function methods:UnregisterEvent(e) if eventFrames[e] then eventFrames[e][self] = nil end end
function methods:Show() local was = self.__shown self.__shown = true if not was and self.__scripts.OnShow then self.__scripts.OnShow(self) end end
function methods:Hide() local was = self.__shown self.__shown = false if was and self.__scripts.OnHide then self.__scripts.OnHide(self) end end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:IsShown() return self.__shown end
function methods:IsVisible() local f = self while f do if not f.__shown then return false end f = f.__parent end return true end
function methods:SetParent(p) self.__parent = p end
function methods:GetParent() return self.__parent end
function methods:CreateFontString() local o = newObject("FontString", nil, self) return o end
function methods:CreateTexture() local o = newObject("Texture", nil, self) return o end
function methods:SetText(t) self.__text = t end
function methods:GetText() return self.__text end
function methods:SetFormattedText(f, ...) self.__text = f:format(...) end
function methods:GetWidth() return self.__w or 200 end
function methods:GetHeight() return self.__h or 100 end
function methods:SetSize(w, h) self.__w, self.__h = w, h end
function methods:SetWidth(w) self.__w = w end
function methods:SetHeight(h) self.__h = h end
function methods:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function methods:GetCenter() return 500, 400 end
function methods:GetEffectiveScale() return 1 end
function methods:GetChecked() return self.__checked end
function methods:SetChecked(v) self.__checked = v end
function methods:GetFrameStrata() return "MEDIUM" end
function methods:IsEnabled() return self.__enabled ~= false end
function methods:Enable() self.__enabled = true end
function methods:Disable() self.__enabled = false end
function methods:GetName() return nil end
function methods:SetAttribute(k, v) self.__attr = self.__attr or {} self.__attr[k] = v end
function methods:GetAttribute(k) return self.__attr and self.__attr[k] end
function methods:GetStringWidth() return 50 end
function methods:GetMapID() return 1412 end
function methods:SetRotation(r) self.__rot = r end
function methods:IsMouseOver() return false end
function methods:GetNumPoints() return 1 end
FrameMT.__index = function(t, k)
    if methods[k] then return methods[k] end
    if type(k) == "string" and k:match("^%u") then
        return function() return nil end -- any other API method: harmless no-op
    end
    return nil
end
CreateFrame = function(kind, name, parent) return newObject(kind, name, parent) end
UIParent = newObject("Frame", "UIParent")
Minimap = newObject("Frame", "Minimap")
WorldMapFrame = newObject("Frame", "WorldMapFrame")
WorldMapFrame.OnMapChanged = function() end
GameTooltip = newObject("GameTooltip", "GameTooltip")
GameTooltip.AddLine = function(self, t) note("TT", t) end
DEFAULT_CHAT_FRAME = newObject("Frame", "DEFAULT_CHAT_FRAME")
DEFAULT_CHAT_FRAME.AddMessage = function(_, m) note("CHAT", m) end
_G.ChatFrame1 = DEFAULT_CHAT_FRAME
RaidWarningFrame = newObject("Frame", "RaidWarningFrame")
UISpecialFrames = {}
SlashCmdList = {}

local function fire(event, ...)
    for f in pairs(eventFrames[event] or {}) do
        local fn = f.__scripts.OnEvent
        if fn then
            local ok, err = pcall(fn, f, event, ...)
            if not ok then errors[#errors + 1] = event .. ": " .. tostring(err) end
        end
    end
end

-- ---------------------------------------------------------------- timers
local timers = {}
C_Timer = {
    After = function(s, fn) timers[#timers + 1] = { at = NOW + s, fn = fn } end,
    NewTicker = function(s, fn) local t = { at = NOW + s, fn = fn, every = s } timers[#timers + 1] = t return { Cancel = function() t.cancelled = true end } end,
    NewTimer = function(s, fn) local t = { at = NOW + s, fn = fn } timers[#timers + 1] = t return { Cancel = function() t.cancelled = true end } end,
}
local function advance(seconds)
    local target = NOW + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if not t or t.at > target then break end
        table.remove(timers, 1)
        NOW = t.at
        if not t.cancelled then
            local ok, err = pcall(t.fn)
            if not ok then errors[#errors + 1] = "timer: " .. tostring(err) end
            if t.every then t.at = NOW + t.every timers[#timers + 1] = t end
        end
        -- OnUpdate of visible frames
        for _, f in ipairs(allFrames) do
            local fn = f.__scripts.OnUpdate
            if fn and f:IsVisible() then
                local ok, err = pcall(fn, f, 0.25)
                if not ok then errors[#errors + 1] = "OnUpdate: " .. tostring(err) end
            end
        end
    end
    NOW = target
end

-- ---------------------------------------------------------------- map / player
local player = { map = 1412, x = 0.45, y = 0.72 }
C_Map = {
    GetBestMapForUnit = function() return player.map end,
    GetPlayerMapPosition = function() return { x = player.x, y = player.y, GetXY = function(s) return s.x, s.y end } end,
    GetMapInfo = function(id)
        if id == 1414 then return { mapID = 1414, name = "Kalimdor", mapType = 2, parentMapID = 947 } end
        if id == 947 then return { mapID = 947, name = "Azeroth", mapType = 1, parentMapID = 0 } end
        return { mapID = id, name = "Zone" .. id, mapType = 3, parentMapID = (id >= 1411 and id <= 1413 or id >= 1438 and id <= 1452) and 1414 or 1415 }
    end,
    GetMapWorldSize = function() return 5000, 3333 end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function() end,
    ClearUserWaypoint = function() end,
}
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
C_Spell = { GetSpellName = function(id)
    local names = { [2366] = "Herbalism", [2575] = "Mining", [3365] = "Opening", [7620] = "Fishing" }
    return names[id] or ("Spell" .. id)
end }
C_Item = {
    GetItemIconByID = function() return 134400 end,
    GetItemNameByID = function(id) return "Item" .. id end,
    GetItemCount = function(id) return id == 6529 and 2 or 0 end,
    GetItemInfoInstant = function(id)
        if id == 6256 then return id, nil, nil, nil, nil, 2, 20 end
        if ({ [2447] = 1, [765] = 1, [2449] = 1, [785] = 1, [2770] = 1, [2771] = 1 })[id] then return id, nil, nil, nil, nil, 7, 9 end
        return id, nil, nil, nil, nil, 0, 0
    end,
}
local bags = { [0] = { 6256 } }
C_Container = {
    GetContainerNumSlots = function(b) return bags[b] and #bags[b] or 0 end,
    GetContainerItemID = function(b, s) return bags[b] and bags[b][s] end,
}
C_FriendList = { GetFriendInfo = function() return nil end }
local sentMessages = {}
C_ChatInfo = {
    RegisterAddonMessagePrefix = function() return true end,
    SendAddonMessage = function(prefix, msg, chan, target) sentMessages[#sentMessages + 1] = msg return 0 end,
}
local loot = {}
GetNumLootItems = function() return #loot end
GetLootSourceInfo = function(i) return loot[i] and loot[i].guid end
GetLootSlotLink = function(i) return loot[i] and ("|Hitem:" .. loot[i].item .. "::|h") end
GetLootSlotInfo = function(i) return 134400, "Item", loot[i] and (loot[i].qty or 1) or 0 end
GetItemInfo = function(id) return "Item" .. id, nil, 1, 1, 1, "Trade Goods", "Herb", 20, "", 134400, 10 end

-- ---------------------------------------------------------------- libraries (stubs)
local libs = {}
LibStub = setmetatable({}, { __call = function(_, name, silent) return libs[name] end })
libs["HereBeDragons-2.0"] = {
    GetWorldCoordinatesFromZone = function(_, x, y, map) return x * 5000 + (map - 1400) * 6000, y * 3333, 1 end,
    GetPlayerWorldPosition = function() return player.x * 5000 + (player.map - 1400) * 6000, player.y * 3333, 1 end,
    GetWorldVector = function(_, inst, ox, oy, dx, dy) local d = math.sqrt((dx - ox) ^ 2 + (dy - oy) ^ 2) return 1.0, d end,
}
local pinCount = 0
libs["HereBeDragons-Pins-2.0"] = {
    AddWorldMapIconMap = function() pinCount = pinCount + 1 PIN_ADDS = (PIN_ADDS or 0) + 1 end, AddMinimapIconMap = function() pinCount = pinCount + 1 end,
    AddWorldMapIconWorld = function() end, AddMinimapIconWorld = function() end,
    RemoveWorldMapIcon = function() pinCount = pinCount - 1 end, RemoveMinimapIcon = function() pinCount = pinCount - 1 end,
    RemoveAllWorldMapIcons = function() end, RemoveAllMinimapIcons = function() end,
}
local ldbObj
libs["LibDataBroker-1.1"] = { NewDataObject = function(_, name, o) ldbObj = o return o end }
libs["LibDBIcon-1.0"] = { Register = function() end, Show = function() end, Hide = function() end, SetButtonIcon = function() end }

-- ---------------------------------------------------------------- load addon
local ns = {}
local toc = io.open(ROOT .. "/Gathercraft.toc"):read("*a")
for line in toc:gmatch("[^\r\n]+") do
    if not line:match("^#") and line:match("%.lua$") and not line:match("^Libs") then
        local path = ROOT .. "/" .. line:gsub("\\", "/")
        local chunk, err = loadfile(path)
        if not chunk then errors[#errors + 1] = "load " .. line .. ": " .. err
        else
            local ok, e = pcall(chunk, "Gathercraft", ns)
            if not ok then errors[#errors + 1] = "run " .. line .. ": " .. tostring(e) end
        end
    end
end

local function step(name, fn)
    local before = #errors
    local ok, err = pcall(fn)
    if not ok then errors[#errors + 1] = name .. ": " .. tostring(err) end
    io.write(("%-38s %s\n"):format(name, (#errors == before) and "ok" or ("FAIL -> " .. errors[#errors])))
end
local function slash(cmd) SlashCmdList.GATHERCRAFT(cmd) end

-- ---------------------------------------------------------------- scenario
step("ADDON_LOADED (fresh, old WoWFFarm data)", function()
    WoWFFarmDB = { nodes = { [1412] = { { id = "o1617", name = "Silverleaf", type = "herb", x = 0.4458, y = 0.7168, count = 1, last = 1 } } } }
    fire("ADDON_LOADED", "Gathercraft")
    assert(ns.db and ns.db.nodes[1412], "db missing")
end)
step("PLAYER_LOGIN + timers", function() fire("PLAYER_LOGIN") fire("PLAYER_ENTERING_WORLD") advance(5) end)
step("Questie zone import (Mulgore)", function()
    fire("ZONE_CHANGED_NEW_AREA") advance(3)
    local n = 0 for _, x in ipairs(ns.db.nodes[1412]) do if x.source == "questie" then n = n + 1 end end
    assert(n > 200, "only " .. n .. " questie nodes")
    note("questie nodes", n, "pins", pinCount)
end)
step("Gather herb (Herbalism + loot)", function()
    fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "cast1", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast1", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1618-AAAA11", item = 2447, qty = 3 } }
    fire("LOOT_READY") fire("LOOT_OPENED")
    PROFS[1][2] = 53
    advance(3)
end)
step("Gather same node again (merge)", function()
    fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "cast2", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast2", 2366)
    fire("LOOT_READY") advance(3)
end)
step("Open chest", function()
    player.x, player.y = 0.4752, 0.7335
    fire("UNIT_SPELLCAST_SENT", "player", "Battered Chest", "cast3", 3365)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast3", 3365)
    loot = { { guid = "GameObject-0-1-1-1-106318-CCCC22", item = 2835 } }
    fire("LOOT_READY") advance(3)
end)
step("Open door (must be ignored)", function()
    fire("UNIT_SPELLCAST_SENT", "player", "Wooden Door", "cast4", 3365)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast4", 3365) advance(3)
end)
step("Main window: all tabs", function()
    slash("") advance(3)
    for _, t in ipairs({ "zones", "skills", "options", "overview" }) do ns.ToggleMain(t) advance(1) end
    ns.HideMain()
end)
step("Minimap button clicks + tooltip", function()
    ldbObj.OnClick(nil, "LeftButton") ldbObj.OnClick(nil, "LeftButton")
    ldbObj.OnTooltipShow(GameTooltip)
    ldbObj.OnClick(nil, "RightButton") advance(2)
    ldbObj.OnClick(nil, "RightButton")
end)
step("Farm run herbs: plan, move, skip, stop", function()
    slash("run herb") advance(2)
    assert(ns.run and ns.run.target, "no target")
    for i = 1, 6 do player.x = player.x - 0.01 advance(1) end
    slash("skip") advance(2)
    slash("stop") advance(1)
end)
step("Farm run: target stays while walking to it", function()
    math.randomseed(7)
    local changed, trials = 0, 0
    for trial = 1, 15 do
        player.map, player.x, player.y = 1412, 0.25 + math.random() * 0.5, 0.25 + math.random() * 0.5
        slash("run herb") advance(1)
        local t = ns.run and ns.run.target
        if t then
            trials = trials + 1
            -- walk at 7 yd/s straight to the target (map is 5000 x 3333 yd here)
            for step = 1, 400 do
                local dx, dy = (t.x - player.x) * 5000, (t.y - player.y) * 3333
                local d = math.sqrt(dx * dx + dy * dy)
                if d < ns.ArriveDistance() + 4 then break end
                local k = math.min(1, 3.5 / d)
                player.x, player.y = player.x + dx * k / 5000, player.y + dy * k / 3333
                advance(0.5)
                if ns.run.target ~= t then
                    note("JUMP", t.name, "visited", tostring(ns.run.visited[t]), "cd", tostring(ns.IsOnCooldown(t)), "dist", math.floor(d), "new", ns.run.target and ns.run.target.name)
                    changed = changed + 1
                    break
                end
            end
        end
        slash("stop")
    end
    note("target changes while walking", changed, "of", trials)
    assert(changed == 0, "target jumped in " .. changed .. " runs")
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Farm run: empty node gets skipped", function()
    slash("run herb") advance(2)
    local t = ns.run.target
    player.map, player.x, player.y = ns.run.mapID, t.x, t.y   -- arrive, harvest nothing
    advance(1)
    assert(ns.run.target ~= t, "still pointing at the node we reached")
    assert(not t.emptyUntil or t.emptyUntil <= time(), "marked empty too early")
    advance(30)
    assert(t.emptyUntil and t.emptyUntil > time(), "empty node not marked")
    -- arrive at the next one and harvest it: must not be marked empty
    local t2 = ns.run.target
    player.map, player.x, player.y = ns.run.mapID, t2.x, t2.y
    advance(1)
    fire("UNIT_SPELLCAST_SENT", "player", t2.name, "castE", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "castE", 2366)
    loot = { { guid = "GameObject-0-1-1-1-" .. t2.id:sub(2) .. "-EEEE99", item = 2447 } }
    fire("LOOT_READY") advance(30)
    note("empty test", t.name, t.emptyStreak, t2.name, t2.emptyStreak)
    assert(not t2.emptyStreak, "harvested node was marked empty")
    slash("stop")
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Farm run both + ore + by name", function()
    slash("run both") advance(2) slash("stop")
    slash("run ore") advance(2) slash("stop")
    slash("run silverleaf") advance(2) slash("stop")
end)
step("Route preview + line toggle", function() slash("route") advance(1) slash("route") slash("line") slash("line") end)
step("Slash commands", function()
    for _, c in ipairs({ "help", "zones", "zones", "pins", "pins", "list", "next", "stats", "skills", "clear", "sync", "options", "options", "rare", "loadall", "debug", "debug", "test" }) do
        slash(c) advance(0.5)
    end
end)
step("Sync: share + receive", function()
    slash("sync on")
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:1412;o1619,h,4548,7312,2449", "CHANNEL", "Friend Player", nil, nil, nil, "GathercraftSync")
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:1412;o1619,h,4548,7312,2449", "GUILD", "Guildie Two")
    fire("CHAT_MSG_ADDON", "Gathercraft", "Q:1412:3", "CHANNEL", "Asker Three", nil, nil, nil, "GathercraftSync")
    fire("CHAT_MSG_ADDON", "Gathercraft", "garbage;;;", "CHANNEL", "Evil", nil, nil, nil, "GathercraftSync")
    advance(5)
    note("sync sent", #sentMessages)
end)
step("Sync stress test (dry)", function() slash("sync stress 50 2") advance(5) end)
step("Prices: vendor value, Auctionator, ahtest", function()
    local v = ns.SessionValue()
    assert(v >= 30, "session value " .. tostring(v))
    Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(caller, id) return id == 2447 and 1234 or nil end } } }
    local p, src = ns.GetPrice(2447)
    assert(p == 1234 and src == "Auctionator", "auctionator price " .. tostring(p) .. " " .. tostring(src))
    slash("ahtest")
    Auctionator = nil
    note("prices ok", v, ns.Money(123456), ns.Money(1234), ns.Money(5))
end)
step("Own auction house scan", function()
    local auctions = {}
    for i = 1, 5000 do
        local id = ({ 2447, 765, 2449, 2770, 2771 })[i % 5 + 1]
        local count = (i % 20) + 1
        local unit = (id == 2447 and 20 or 100) + (i % 7) * 3
        if i == 7 then unit = 1 end -- one silly cheap auction must not set the price
        auctions[i] = { id = id, count = count, buyout = unit * count }
    end
    C_AuctionHouse = {
        ReplicateItems = function() end,
        GetNumReplicateItems = function() return #auctions end,
        GetReplicateItemInfo = function(i)
            local a = auctions[i + 1]
            if not a then return nil end
            return "Item", 1, a.count, 1, true, 1, 0, 0, 0, a.buyout, 0, false, nil, "Seller", nil, 0, a.id, true
        end,
    }
    AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    -- Prices.lua captured C_AuctionHouse at load time: reload just that file
    local chunk = assert(loadfile(ROOT .. "/Prices.lua"))
    chunk("Gathercraft", ns)
    fire("AUCTION_HOUSE_SHOW")
    slash("scan") advance(1)
    fire("REPLICATE_ITEM_LIST_UPDATE") advance(2)
    local p, src = ns.GetPrice(2447)
    note("scan price peacebloom", p, src, ns.Money(p))
    assert(src == "AH scan" and p >= 20 and p <= 40, "scan price " .. tostring(p) .. " " .. tostring(src))
    GameTooltip.GetItem = function() return "Peacebloom", "|cffffffff|Hitem:2447::::::::12:::::|h[Peacebloom]|h|r" end
    GameTooltip.AddDoubleLine = function(_, l, r) note("TTPRICE", l, r) end
    GameTooltip.__scripts.OnTooltipSetItem(GameTooltip)
    -- learning from searches: a commodity search for Earthroot, a browse list
    C_AuctionHouse.GetNumCommoditySearchResults = function() return 3 end
    C_AuctionHouse.HasFullCommoditySearchResults = function() return true end
    C_AuctionHouse.GetCommoditySearchResultInfo = function(id, i)
        return ({ { unitPrice = 500, quantity = 10 }, { unitPrice = 520, quantity = 30 }, { unitPrice = 900, quantity = 5 } })[i]
    end
    C_AuctionHouse.GetBrowseResults = function()
        return { { itemKey = { itemID = 4306 }, minPrice = 1500, totalQuantity = 40 }, { itemKey = { itemID = 2449 }, minPrice = 1, totalQuantity = 1 } }
    end
    fire("COMMODITY_SEARCH_RESULTS_UPDATED", 2449)
    fire("BROWSE_RESULTS_UPDATED")
    local e = ns.GetPrice(2449)
    local silk = ns.GetPrice(4306)
    note("learned prices earthroot", e, "silk", silk)
    assert(e == 500, "commodity search not learned: " .. tostring(e))
    assert(silk == 1500, "browse not learned")
    -- price alert: Earthroot usually 100c (4 days of history), now 500c
    local day = math.floor(time() / 86400)
    local realm = next(ns.db.prices)
    local p = ns.db.prices[realm]
    p.history[2449] = ("%d:100;%d:110;%d:90;%d:100;%d:500"):format(day - 4, day - 3, day - 2, day - 1, day)
    assert(ns.UsualPrice(2449) == 100, "usual price " .. tostring(ns.UsualPrice(2449)))
    local hot = ns.HotItems()
    assert(#hot >= 1 and hot[1].id == 2449, "hot items")
    advance(3) -- alert fires after a search
    GameTooltip.GetItem = function() return "Earthroot", "|Hitem:2449::|h" end
    GameTooltip.__scripts.OnTooltipSetItem(GameTooltip)
    ns.ToggleMain("farm") advance(1) ns.HideMain()
    slash("scan") -- cooldown message
    slash("ahtest")
    fire("AUCTION_HOUSE_CLOSED")
    assert(#ns.PriceHistory(2447) == 1, "history")
end)
step("Best place to farm", function()
    for _, mode in ipairs({ "herb", "ore", "both" }) do
        local groups = ns.FarmAdvice(mode)
        assert(#groups > 0, "no continents for " .. mode)
        for _, g in ipairs(groups) do
            local best
            for _, r in ipairs(g.rows) do if r.best then best = r end end
            note("advisor", mode, g.name, #g.rows, "best", best and best.mapID, best and math.floor(best.goldPerHour), best and math.floor(best.nodesPerHour))
        end
    end
    ns.ToggleMain("farm") advance(1)
    ns.db.advisorOpen = { [1415] = true } ns.db.advisorSort = "gold"
    ns.ToggleMain("overview") ns.ToggleMain("farm") advance(1)
    ns.HideMain()
    slash("run both")  -- placeholder run to make sure zone runs still work
    slash("stop")
    ns.StartRun("herb", 1413) advance(2)
    assert(ns.run and ns.run.zone == 1413 and ns.run.target, "zone run")
    advance(30)
    slash("stop")
end)
step("Crafting: learn recipes, profit, can make", function()
    -- classic profession window: Alchemy with two potions
    local skills = {
        { "Alchemy", "header" },
        { "Minor Healing Potion", "optimal", 118, { { 2447, 1 }, { 765, 1 }, { 3371, 1 } } },
        { "Elixir of Lion's Strength", "easy", 2454, { { 2449, 1 }, { 765, 1 }, { 3371, 1 } } },
    }
    GetTradeSkillLine = function() return "Alchemy", 60, 150 end
    GetNumTradeSkills = function() return #skills end
    GetTradeSkillInfo = function(i) return skills[i][1], skills[i][2] end
    GetTradeSkillItemLink = function(i) return skills[i][3] and ("|Hitem:" .. skills[i][3] .. "::|h") end
    GetTradeSkillNumMade = function() return 1, 1 end
    GetTradeSkillNumReagents = function(i) return #skills[i][4] end
    GetTradeSkillReagentInfo = function(i, r) return "Reagent", 134400, skills[i][4][r][2], 0 end
    GetTradeSkillReagentItemLink = function(i, r) return "|Hitem:" .. skills[i][4][r][1] .. "::|h" end
    fire("TRADE_SKILL_SHOW") advance(1)
    -- a vendor sells Empty Vials for 4c
    GetMerchantNumItems = function() return 1 end
    GetMerchantItemInfo = function() return "Empty Vial", 134400, 20, 5, -1, true, false, nil end
    GetMerchantItemLink = function() return "|Hitem:3371::|h" end
    fire("MERCHANT_SHOW")
    -- auction prices for the products
    local realm = next(ns.db.prices)
    ns.db.prices[realm].items[118] = 300
    ns.db.prices[realm].items[2454] = 50
    ns.db.prices[realm].seen[118] = time() ns.db.prices[realm].seen[2454] = time()
    -- a Tailoring trainer (we don't have Tailoring): Linen Bag needs skill 45
    GetNumTrainerServices = function() return 2 end
    GetTrainerServiceInfo = function(i) return ({ "Tailoring", "Linen Bag" })[i], nil, i == 1 and "header" or "unavailable" end
    GetTrainerServiceItemLink = function(i) return i == 2 and "|Hitem:4238::|h" or nil end
    GetTrainerServiceSkillReq = function() return "Tailoring", 45, false end
    GetTrainerServiceNumReagents = function() return 2 end
    GetTrainerServiceReagentInfo = function(i, r) return "R", 1, r == 1 and 3 or 1 end
    GetTrainerServiceReagentLink = function(i, r) return "|Hitem:" .. (r == 1 and 2589 or 2320) .. "::|h" end
    GetTrainerServiceTypeFilter = function() return 1 end
    IsTradeskillTrainer = function() return true end
    fire("TRAINER_SHOW") advance(1)
    ns.TrainerTest()
    ns.db.prices[next(ns.db.prices)].items[4238] = 900
    local tailor = ns.CraftAdvice("Tailoring")
    assert(#tailor == 1 and not tailor[1].learned and tailor[1].req == 45, "trainer recipe")
    note("craft trainer", tailor[1].name, "req", tailor[1].req, "profit", math.floor(tailor[1].profit))
    -- a vendor sells "Pattern: Linen Reagent Bag": read it from the tooltip
    local oldName = C_Item.GetItemNameByID
    local names = { [253664] = "Pattern: Linen Reagent Bag", [2996] = "Bolt of Linen Cloth", [2320] = "Coarse Thread", [999001] = "Linen Reagent Bag" }
    C_Item.GetItemNameByID = function(id) return names[id] or oldName(id) end
    C_TooltipInfo = { GetItemByID = function(id)
        if id ~= 253664 then return nil end
        local t = { "Pattern: Linen Reagent Bag", "\nLinen Reagent Bag", "Binds when equipped", "6 Slot Reagent Bag",
            "Use: Teaches you how to craft Linen Reagent Bag.", "Bolt of Linen Cloth (6), Coarse Thread (6)", "Requires Tailoring (5)" }
        local lines = {}
        for _, x in ipairs(t) do lines[#lines + 1] = { leftText = x } end
        return { lines = lines }
    end }
    GetMerchantNumItems = function() return 1 end
    GetMerchantItemInfo = function() return "Pattern: Linen Reagent Bag", 134400, 500, 1, 1, true, false, nil end
    GetMerchantItemLink = function() return "|Hitem:253664::|h" end
    fire("MERCHANT_SHOW") advance(2)
    local pend = ns.db.recipePending and ns.db.recipePending.Tailoring and ns.db.recipePending.Tailoring["Linen Reagent Bag"]
    note("recipe item pending (names unknown yet):", tostring(pend))
    ns.db.prices[next(ns.db.prices)].items[2996] = 80
    ns.db.prices[next(ns.db.prices)].items[999001] = 2500
    fire("MERCHANT_SHOW") advance(2)
    local got = ns.db.recipeDB.Tailoring and ns.db.recipeDB.Tailoring["Linen Reagent Bag"]
    note("recipe item stored:", tostring(got))
    assert(got == "999001:1:1:5|2996:6,2320:6", "recipe item not resolved: " .. tostring(got))
    C_Item.GetItemNameByID = oldName C_TooltipInfo = nil
    local rows = ns.CraftAdvice()
    for _, r in ipairs(rows) do
        note("craft", r.name, "profit", math.floor(r.profit), "value", math.floor(r.value), "cost", math.floor(r.cost), "can", r.canMake, "missing", tostring(r.missing))
    end
    assert(#rows == 2 and rows[1].name == "Minor Healing Potion", "craft ranking")
    ns.ToggleMain("craft") advance(1)
    ns.db.craftTab = "Tailoring" ns.ToggleMain("overview") ns.ToggleMain("craft") advance(1)
    ns.db.craftTab = "mine"
    slash("crafttest")
    ns.HideMain()
end)
step("Crafting: trainer without links (Forever), tooltip reagents", function()
    local oldName = C_Item.GetItemNameByID
    local names = { [2996] = "Bolt of Linen Cloth", [2320] = "Coarse Thread", [4307] = "Heavy Linen Gloves" }
    ns.NoteItemName("Strange Dust", 10940) -- seen in an auction house scan, not loaded now
    ns.db.prices[next(ns.db.prices)].items[10940] = 40
    C_Item.GetItemNameByID = function(id) return names[id] or oldName(id) end
    local realm = next(ns.db.prices)
    ns.db.prices[realm].items[4307] = 700 ns.db.prices[realm].items[2320] = 10 ns.db.prices[realm].items[2996] = 80
    GetNumTrainerServices = function() return 4 end
    GetTrainerServiceInfo = function(i) return ({ "Tailoring", "Heavy Linen Gloves", "Journeyman Tailoring", "Enchant Chest - Inferior Stamina" })[i], nil, i == 1 and "header" or "available" end
    GetTrainerServiceItemLink = function() return nil end
    GetTrainerServiceSkillReq = function() return "Tailoring", 35, true end
    GetTrainerServiceNumReagents = function() return 0 end
    C_TooltipInfo = { GetTrainerService = function(i)
        local t = i == 2 and { "Heavy Linen Gloves", "Requires Tailoring (35)", "Reagents: |cffff2020Bolt of Linen Cloth|r (2), Coarse Thread" }
            or i == 4 and { "Enchanting: Enchant Chest - Inferior Stamina", "", "Tools: Runed Copper Rod", "Reagents: \nStrange Dust" }
            or { "Journeyman Tailoring", "Allows you to learn more." }
        local lines = {}
        for _, x in ipairs(t) do lines[#lines + 1] = { leftText = x } end
        return { lines = lines }
    end }
    fire("TRAINER_SHOW") advance(1)
    ns.TrainerTest()
    local got = ns.db.recipeDB.Tailoring["Heavy Linen Gloves"]
    note("forever trainer stored:", tostring(got))
    note("PENDING", ns.db.recipePending and ns.db.recipePending.Tailoring and ns.db.recipePending.Tailoring["Heavy Linen Gloves"])
    assert(got == "4307:1:1:35|2996:2,2320:1", "forever trainer: " .. tostring(got) .. " pending " .. tostring(ns.db.recipePending and ns.db.recipePending.Tailoring and ns.db.recipePending.Tailoring["Heavy Linen Gloves"]))
    local ench = ns.db.recipeDB.Tailoring["Enchant Chest - Inferior Stamina"]
    assert(ench == "0:1:1:35|10940:1", "enchant: " .. tostring(ench))
    local erows = ns.CraftAdvice("Tailoring")
    local e
    for _, r in ipairs(erows) do if r.enchant then e = r end end
    assert(e and not e.missing and e.cost == 40, "enchant row")
    ns.db.craftTab = "Tailoring" ns.ToggleMain("craft") advance(1) ns.HideMain()
    C_Item.GetItemNameByID = oldName C_TooltipInfo = nil
end)
step("Crafting: item names load later (not cached)", function()
    local oldName, oldReq = C_Item.GetItemNameByID, C_Item.RequestLoadItemDataByID
    local loaded, asked = {}, 0
    C_Item.GetItemNameByID = function(id) return loaded[id] and ("Thing" .. id) or nil end
    C_Item.RequestLoadItemDataByID = function(id) asked = asked + 1 end
    ns.db.itemNames = {}
    local realm = next(ns.db.prices)
    ns.db.prices[realm].items[55501] = 100
    ns.db.recipePending = { Alchemy = { ["Thing55502"] = "1|Thing55501:2" } }
    ns.db.prices[realm].items[55502] = 900
    ns.LearnPriceNames() advance(5)
    assert(asked > 0, "no load requests")
    loaded[55501], loaded[55502] = true, true
    fire("GET_ITEM_INFO_RECEIVED", 55501, true) fire("GET_ITEM_INFO_RECEIVED", 55502, true) advance(5)
    note("names loaded later:", tostring(ns.db.itemNames["thing55501"]), "recipe", tostring(ns.db.recipeDB.Alchemy and ns.db.recipeDB.Alchemy["Thing55502"]))
    assert(ns.db.recipeDB.Alchemy["Thing55502"] == "55502:1:1:1|55501:2", "late names " .. tostring(ns.db.itemNames["thing55501"]) .. " " .. tostring(ns.db.recipePending.Alchemy["Thing55502"]))
    -- an enchanting formula: no item, line 2 is already the "Use:" text
    loaded[10940] = true ns.NoteItemName("Strange Dust", 10940)
    C_TooltipInfo = { GetItemByID = function(id)
        if id ~= 6342 then return nil end
        local lines = {}
        for _, x in ipairs({ "Formula: Enchant Chest - Minor Mana", "Use: Teaches you how to permanently enchant a piece of chest armor to grant +20 mana.",
            "Strange Dust (2)", "Requires Enchanting (20)" }) do lines[#lines + 1] = { leftText = x } end
        return { lines = lines }
    end }
    GetMerchantNumItems = function() return 1 end
    GetMerchantItemInfo = function() return "Formula: Enchant Chest - Minor Mana", 134400, 300, 1, 1, true, false, nil end
    GetMerchantItemLink = function() return "|Hitem:6342::|h" end
    fire("MERCHANT_SHOW") advance(2)
    local f = ns.db.recipeDB.Enchanting and ns.db.recipeDB.Enchanting["Enchant Chest - Minor Mana"]
    assert(f == "0:1:1:20|10940:2", "formula: " .. tostring(f))
    C_TooltipInfo = nil
    C_Item.GetItemNameByID, C_Item.RequestLoadItemDataByID = oldName, oldReq
end)
step("Crafting: names from the shipped item list", function()
    assert(GathercraftItemNames and GathercraftItemNames:find("10940\tStrange Dust"), "ItemNames.lua not loaded")
    ns.db.itemNames = {}
    ns.db.recipePending = { Enchanting = { ["Enchant Bracer - Minor Health"] = "1|Strange Dust:1" } }
    ns.ResolvePending()
    assert(ns.db.recipeDB.Enchanting["Enchant Bracer - Minor Health"] == "0:1:1:1|10940:1", "shipped names")
end)
step("Rare alert (nameplate + test)", function()
    classification = "rare" fire("NAME_PLATE_UNIT_ADDED", "nameplate1") classification = "normal"
    fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
end)
step("Fishing: equip, lure, cast, reel", function()
    local b = _G.GathercraftFishButton
    b.__scripts.PreClick(b) note("fish next", b.next)
    GetInventoryItemID = function() return 6256 end
    b.__scripts.PreClick(b) note("fish next", b.next)
    GetWeaponEnchantInfo = function() return true end
    b.__scripts.PreClick(b) note("fish next", b.next)
    fire("UNIT_SPELLCAST_CHANNEL_START", "player", "c9", 7620)
    fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c9", 7620)
    IsFishingLoot = function() return true end
    loot = { { guid = "GameObject-0-1-1-1-35591-FFFF01", item = 6303, qty = 2 } }
    fire("LOOT_READY") loot = {}
    IsFishingLoot = nil
    advance(1)
    local f = ns.FishingSession()
    assert(f and f.catches == 1 and f.items == 2, "fishing catch not counted")
    note("fishing session catches", f.catches, "value", f.value, "panel", tostring(_G.GathercraftPanel:IsShown()))
    assert(_G.GathercraftPanel:IsShown(), "fishing panel not shown")
    _G.GathercraftPanel.__scripts.OnUpdate = _G.GathercraftPanel.__scripts.OnUpdate
end)
step("Pin tooltip", function()
    for _, f in ipairs(allFrames) do
        if f.node and f.__scripts.OnEnter then f.__scripts.OnEnter(f) f.__scripts.OnLeave(f) break end
    end
end)
step("Zone change to Durotar + world map look", function()
    player.map = 1411 fire("ZONE_CHANGED_NEW_AREA") advance(3)
    WorldMapFrame:OnMapChanged() advance(1)
end)
step("loadall continent", function() slash("loadall") advance(3) note("questie nodes after loadall, pins", pinCount)
    local shared, sample = 0, nil
    for _, f in ipairs(allFrames) do
        if f.others and #f.others > 0 and f.node then shared = shared + 1 sample = sample or f end
    end
    note("shared spawn pins", shared)
    assert(shared > 0, "no shared spawn pins (Copper/Tin in the Barrens)")
    sample.__scripts.OnEnter(sample) sample.__scripts.OnLeave(sample)
    local t0 = os.clock() slash("run herb") advance(2) note("questie nodes: plan time ms", math.floor((os.clock() - t0) * 1000)) slash("stop") end)
step("Harvest cost during a run (after loadall)", function()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    slash("run herb") advance(2)
    -- harvest at shared spawn spots in the Barrens (Copper/Tin), the worst case for pins
    local worst, total = 0, 0
    PIN_ADDS = 0
    for i = 1, 5 do
        local t = ns.run.target
        player.map, player.x, player.y = ns.run.mapID, t.x, t.y
        local t0 = os.clock()
        fire("UNIT_SPELLCAST_SENT", "player", t.name, "lag" .. i, 2366)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "lag" .. i, 2366)
        loot = { { guid = "GameObject-0-1-1-1-" .. t.id:sub(2) .. "-LAG" .. i, item = 2447, qty = 2 } }
        fire("LOOT_READY")
        advance(1) -- planning and pin updates happen right after
        local ms = (os.clock() - t0) * 1000
        worst, total = math.max(worst, ms), total + ms
    end
    note("harvest cost ms: worst", math.floor(worst), "avg", math.floor(total / 5), "pins redrawn", PIN_ADDS)
    slash("stop")
end)
step("Logout keeps SavedVariables slim, login loads spawns again", function()
    -- one known spawn point resting (was empty)
    local resting
    for _, n in ipairs(ns.db.nodes[1413] or {}) do
        if n.source == "questie" then resting = n break end
    end
    resting.emptyUntil, resting.emptyStreak = time() + 600, 2
    local before = 0
    for _, list in pairs(ns.db.nodes) do before = before + #list end
    fire("PLAYER_LOGOUT")
    local after, questie = 0, 0
    for _, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            after = after + 1
            if n.source == "questie" then questie = questie + 1 end
        end
    end
    local stateCount = 0
    for _, zone in pairs(ns.db.spawnState) do for _ in pairs(zone) do stateCount = stateCount + 1 end end
    note("slim: nodes before", before, "saved", after, "questie saved", questie, "resting saved", stateCount)
    assert(questie == 0 and stateCount >= 1, "questie nodes still saved")
    -- "reload": a fresh Starter.lua loads the zones again
    local chunk = assert(loadfile(ROOT .. "/Starter.lua"))
    chunk("Gathercraft", ns)
    fire("PLAYER_LOGIN") advance(5)
    local again, found = 0, false
    for _, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            if n.source == "questie" then
                again = again + 1
                if n.sk == resting.sk and n.emptyStreak == 2 and n.emptyUntil then found = true end
            end
        end
    end
    note("slim: spawn points after login", again, "resting state back", found)
    assert(again > 1000 and found, "spawn points or resting state not restored")
end)
step("Delete + wipe zone", function() slash("del") slash("wipe zone") advance(1) end)
step("Long run (10 min) for leaks", function() slash("run herb") advance(600) slash("stop") end)

io.write("\n--- errors: " .. #errors .. "\n")
for _, e in ipairs(errors) do io.write("  " .. e .. "\n") end
io.write("\n--- notable log lines:\n")
for _, l in ipairs(log) do
    if l:find("questie nodes") or l:find("fish next") or l:find("SOUNDFILE") or l:find("RAIDWARN") or l:find("sync sent") or l:find("empty test") or l:find("prices ok") or l:find("scan price") or l:find("TTPRICE") or l:find("advisor") or l:find("target changes") or l:find("JUMP") or l:find("harvest cost") or l:find("slim:") or l:find("learned prices") or l:find("fishing session") or l:find("recipe item") or l:find("craft ") or l:find("recipes") or l:find("profit") or l:find("Price alert") or l:find("scanned") or l:find("Own scan") or l:find("15 minutes") or l:find("shared spawn") or l:find("Shared spawn") or l:find("Loaded") or l:find("took over") or l:find("RECORD") or l:find("No ") or l:find("rror") then
        io.write("  " .. l:sub(1, 160) .. "\n")
    end
end
