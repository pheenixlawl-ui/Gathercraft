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
    GetItemInfoInstant = function(id) if id == 6256 then return id, nil, nil, nil, nil, 2, 20 end return id, nil, nil, nil, nil, 0, 0 end,
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
    AddWorldMapIconMap = function() pinCount = pinCount + 1 end, AddMinimapIconMap = function() pinCount = pinCount + 1 end,
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
    slash("scan") -- cooldown message
    slash("ahtest")
    fire("AUCTION_HOUSE_CLOSED")
    assert(#ns.PriceHistory(2447) == 1, "history")
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
    fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c9", 7620) advance(1)
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
step("Delete + wipe zone", function() slash("del") slash("wipe zone") advance(1) end)
step("Long run (10 min) for leaks", function() slash("run herb") advance(600) slash("stop") end)

io.write("\n--- errors: " .. #errors .. "\n")
for _, e in ipairs(errors) do io.write("  " .. e .. "\n") end
io.write("\n--- notable log lines:\n")
for _, l in ipairs(log) do
    if l:find("questie nodes") or l:find("fish next") or l:find("SOUNDFILE") or l:find("RAIDWARN") or l:find("sync sent") or l:find("empty test") or l:find("prices ok") or l:find("scan price") or l:find("TTPRICE") or l:find("scanned") or l:find("Own scan") or l:find("15 minutes") or l:find("shared spawn") or l:find("Shared spawn") or l:find("Loaded") or l:find("took over") or l:find("RECORD") or l:find("No ") or l:find("rror") then
        io.write("  " .. l:sub(1, 160) .. "\n")
    end
end
