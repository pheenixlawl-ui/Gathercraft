-- Usage: luajit tools/smoke_test.lua <path to Gathercraft folder>
-- Mini WoW environment to smoke-test Gathercraft outside the game.
local ROOT = arg[1]
local errors, log = {}, {}
local savedShipped
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
UnitFactionGroup = function() return "Horde", "Horde" end
CreateColor = function(r, g, b, a) return { r = r, g = g, b = b, a = a } end
Enum = {}
UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { m = m, x = x, y = y } end }
NUM_CHAT_WINDOWS = 10
-- chat windows: CHAT_WIN[i] = { name, shown, docked }; closed tabs keep their name
CHAT_WIN = { { "General", true, true }, { "Combat Log", true, true } }
GetChatWindowInfo = function(i)
    local w = CHAT_WIN[i]
    if not w then return "" end
    return w[1], 14, 1, 1, 1, 1, w[2], false, w[3]
end
FCF_OPENED = 0
FCF_OpenNewWindow = function(name)
    for i = 3, NUM_CHAT_WINDOWS do
        local w = CHAT_WIN[i]
        if not w or (not w[2] and not w[3]) then
            CHAT_WIN[i] = { name, true, true }
            FCF_OPENED = FCF_OPENED + 1
            _G["ChatFrame" .. i]:Show()
            return _G["ChatFrame" .. i]
        end
    end
end
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

-- professions: herbalism 52/75, mining 30/75, fishing 1/75; [5] = bonus from gear/buffs
local PROFS = { { "Herbalism", 52, 75, 182, 0 }, { "Mining", 30, 75, 186, 0 }, nil, { "Fishing", 1, 75, 356, 0 }, nil, nil }
GetProfessions = function() return 1, 2, nil, 4, nil, nil end
GetProfessionInfo = function(i)
    local p = PROFS[i]
    return p[1], 0, p[2], p[3], 0, 0, p[4], p[5]
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
function methods:GetFrameLevel() return self.__level or 1 end
function methods:SetFrameLevel(l) self.__level = l end
function methods:CreateMaskTexture() return newObject("MaskTexture", nil, self) end
function methods:AddMaskTexture(m) self.__masks = (self.__masks or 0) + 1 end
function methods:RemoveMaskTexture(m) self.__masks = (self.__masks or 0) - 1 end
function methods:CreateAnimationGroup() return newObject("AnimationGroup", nil, self) end
function methods:CreateAnimation() return newObject("Animation", nil, self) end
function methods:SetTexture(t) self.__tex = t end
function methods:SetAlpha(a) self.__alpha = a end
function methods:GetAlpha() return self.__alpha or 1 end
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
GameTooltip.AddDoubleLine = function(self, a, b) note("TT2", a, "=", b) end
DEFAULT_CHAT_FRAME = newObject("Frame", "DEFAULT_CHAT_FRAME")
DEFAULT_CHAT_FRAME.AddMessage = function(_, m) note("CHAT", m) end
_G.ChatFrame1 = DEFAULT_CHAT_FRAME
for i = 2, NUM_CHAT_WINDOWS do
    local f = newObject("Frame", "ChatFrame" .. i)
    f.AddMessage = function(self, m) self.__lines = (self.__lines or 0) + 1 note("CHAT" .. i, m) end
end
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
    SetUserWaypoint = function(p) USER_WP = p WP_SETS = (WP_SETS or 0) + 1 end,
    ClearUserWaypoint = function() USER_WP = nil WP_CLEARS = (WP_CLEARS or 0) + 1 end,
    GetUserWaypoint = function()
        return USER_WP and { uiMapID = USER_WP.m, position = { x = USER_WP.x, y = USER_WP.y } }
    end,
}
C_SuperTrack = { SetSuperTrackedUserWaypoint = function() end }
-- GC_LOCALE=deDE runs everything as a German client
local LOCALE = os.getenv("GC_LOCALE") or "enUS"
local GERMAN = LOCALE == "deDE"
GetLocale = function() return LOCALE end
local SPELL_NAMES = { [2366] = "Herbalism", [2575] = "Mining", [3365] = "Opening", [7620] = "Fishing" }
if GERMAN then
    SPELL_NAMES = {
        [2366] = "Kräutersammeln", [2575] = "Bergbau", [3365] = "Öffnen", [7620] = "Angeln",
        [2259] = "Alchimie", [2018] = "Schmiedekunst", [7411] = "Verzauberkunst", [4036] = "Ingenieurskunst",
        [2108] = "Lederverarbeitung", [3908] = "Schneiderei", [2550] = "Kochkunst", [3273] = "Erste Hilfe",
        [2656] = "Verhüttung", [7420] = "Brust - Schwache Ausdauer", [3840] = "Schwere Leinenhandschuhe",
    }
    ITEM_MIN_SKILL = "Benötigt %s (%d)"
    SPELL_REAGENTS = "Reagenzien: %s"
    ITEM_SPELL_TRIGGER_ONUSE = "Benutzen:"
end
C_Spell = { GetSpellName = function(id)
    return SPELL_NAMES[id] or ("Spell" .. id)
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
    GetZoneCoordinatesFromWorld = function(_, wx, wy, map) return (wx - (map - 1400) * 6000) / 5000, wy / 3333 end,
    GetZoneDistance = function(_, m1, x1, y1, m2, x2, y2)
        local ax, ay = x1 * 5000 + (m1 - 1400) * 6000, y1 * 3333
        local bx, by = x2 * 5000 + (m2 - 1400) * 6000, y2 * 3333
        return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
    end,
}
local pinCount = 0
HBD_ADDS, HBD_FLOAT, MINI_ICONS, LINE_PTS = {}, {}, {}, {}
libs["HereBeDragons-Pins-2.0"] = {
    AddWorldMapIconMap = function(_, ref) pinCount = pinCount + 1 PIN_ADDS = (PIN_ADDS or 0) + 1
        HBD_ADDS[ref] = HBD_ADDS[ref] or { world = 0, mini = 0 } HBD_ADDS[ref].world = HBD_ADDS[ref].world + 1 end,
    AddMinimapIconMap = function(_, ref, icon, map, x, y, parent, float) pinCount = pinCount + 1
        HBD_ADDS[ref] = HBD_ADDS[ref] or { world = 0, mini = 0 } HBD_ADDS[ref].mini = HBD_ADDS[ref].mini + 1
        HBD_FLOAT[ref] = float if ref == "Gathercraft" then MINI_ICONS[#MINI_ICONS + 1] = icon end end,
    AddWorldMapIconWorld = function(_, ref, icon, inst, x, y) LINE_DOTS = (LINE_DOTS or 0) + 1 LINE_PTS[#LINE_PTS + 1] = { x, y } end, AddMinimapIconWorld = function() end,
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

-- tools/route_sim.lua uses this file only for the mini WoW: hand it the pieces
if HARNESS_ONLY then
    return {
        ns = ns, fire = fire, advance = advance, player = player, errors = errors, note = note, log = log, allFrames = allFrames,
        now = function() return NOW end, setLoot = function(l) loot = l end, profs = PROFS,
        slash = function(cmd) SlashCmdList.GATHERCRAFT(cmd) end,
    }
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
step("Tauren Cultivation: the copy on top is not a new node", function()
    local function CountNear(x, y)
        local c = 0
        for _, n in ipairs(ns.db.nodes[1412]) do
            if n.name == "Earthroot" and math.abs(n.x - x) < 0.002 and math.abs(n.y - y) < 0.002 then c = c + 1 end
        end
        return c
    end
    local ox, oy = player.x, player.y
    local oldRace = UnitRace
    UnitRace = function() return "Tauren", "Tauren" end
    player.x, player.y = 0.3333, 0.4444
    fire("UNIT_SPELLCAST_SENT", "player", "Earthroot", "cult1", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cult1", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1619-CULT01", item = 2449, qty = 2 } }
    fire("LOOT_READY") advance(3)
    assert(CountNear(0.3333, 0.4444) == 1, "first pick not recorded")
    advance(20) -- cast Cultivation, then pick the copy (another spawn, same spot)
    fire("UNIT_SPELLCAST_SENT", "player", "Earthroot", "cult2", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cult2", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1619-CULT02", item = 2449, qty = 2 } }
    fire("LOOT_READY") advance(3)
    assert(CountNear(0.3333, 0.4444) == 1, "cultivated copy became a node of its own")
    -- not a Tauren: two real Earthroots side by side stay two nodes
    UnitRace = function() return "Human", "Human" end
    player.x, player.y = 0.6111, 0.2222
    fire("UNIT_SPELLCAST_SENT", "player", "Earthroot", "cult3", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cult3", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1619-CULT03", item = 2449, qty = 2 } }
    fire("LOOT_READY") advance(3)
    player.x = 0.6113 -- about a yard away
    fire("UNIT_SPELLCAST_SENT", "player", "Earthroot", "cult4", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cult4", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1619-CULT04", item = 2449, qty = 2 } }
    fire("LOOT_READY") advance(3)
    assert(CountNear(0.6112, 0.2222) == 2, "two real herbs merged for a non-Tauren: " .. CountNear(0.6112, 0.2222))
    UnitRace = oldRace
    player.x, player.y = ox, oy
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
step("Farm run: only nodes you can gather, route goals", function()
    -- every herb spawn point of Barrens and Mulgore in the database
    ns.ImportQuestieZone(1413, true)
    PROFS[1][2] = 40 -- Herbalism 40: no Briarthorn (70) or Bruiseweed (100)
    player.map, player.x, player.y = 1413, 0.5, 0.5
    slash("run herb") advance(2)
    assert(ns.run and ns.run.path and #ns.run.path > 0, "no route")
    local tooHigh, kinds = 0, {}
    for _, p in ipairs(ns.run.path) do
        local req = ns.RequiredSkill(p.node.id, p.node.name)
        if req > 40 then tooHigh = tooHigh + 1 end
        kinds[p.node.name] = true
    end
    assert(tooHigh == 0, tooHigh .. " nodes on the route need more skill")
    local goal = ns.run.goal
    for _, g in ipairs({ "gold", "nodes", "skill", "auto", "bogus" }) do
        ns.db.routeGoal = g
        ns.RouteGoalChanged()
        assert(ns.run and #ns.run.path > 0, "no route for goal " .. g)
    end
    ns.db.routeGoal = nil
    -- every route line color and style, dots stay within the limit
    for _, c in ipairs(ns.ROUTE_LINE_COLORS) do
        ns.db.routeLineColor = c.code
        ns.RedrawRouteLine()
    end
    for _, st in ipairs(ns.ROUTE_LINE_STYLES) do
        ns.db.routeLineStyle = st.code
        LINE_DOTS = 0
        ns.RedrawRouteLine() advance(1)
        assert(LINE_DOTS > 0 and LINE_DOTS <= 620, "route dots for " .. st.code .. ": " .. LINE_DOTS)
        note("route line", st.code, "dots", LINE_DOTS, "path yd", math.floor(ns.run.length))
    end
    ns.db.routeLineColor, ns.db.routeLineStyle = nil, nil
    slash("stop")
    PROFS[1][2] = 1 -- nothing in a Briarthorn-only selection is gatherable
    slash("run briarthorn") advance(1)
    assert(not ns.run, "run started with nothing gatherable")
    PROFS[1][2] = 52
    player.map, player.x, player.y = 1412, 0.45, 0.7
    local n = 0 for _ in pairs(kinds) do n = n + 1 end
    note("route goal", goal, "kinds", n, "chance", ns.NodeChance(ns.db.nodes[1413][1]))
end)
step("Route: maxed skill goes for gold, a vein mined 3x is one hit", function()
    local Z = 1460
    ns.db.nodes[Z] = {}
    for i = 1, 6 do
        table.insert(ns.db.nodes[Z], { id = "o176584", name = "Dreamfoil", type = "herb", x = 0.4 + i * 0.02, y = 0.5, count = 1, last = 1 })
        table.insert(ns.db.nodes[Z], { id = "o1618", name = "Peacebloom", type = "herb", x = 0.4 + i * 0.02, y = 0.6, count = 1, last = 1 })
    end
    local oldRank, oldMax = PROFS[1][2], PROFS[1][3]
    player.map, player.x, player.y = Z, 0.5, 0.5
    PROFS[1][2], PROFS[1][3] = 300, 300
    ns.StartRun("herb", Z) advance(1)
    assert(ns.run and ns.run.goal == "gold", "maxed skill: goal " .. tostring(ns.run and ns.run.goal))
    ns.StopRun()
    PROFS[1][2], PROFS[1][3] = 280, 300
    ns.StartRun("herb", Z) advance(1)
    assert(ns.run and ns.run.goal == "skill", "skill 280: goal " .. tostring(ns.run and ns.run.goal))
    ns.StopRun()
    ns.db.nodes[Z] = nil
    PROFS[1][2], PROFS[1][3] = oldRank, oldMax
    -- one copper vein, mined three times (same spawn)
    player.map, player.x, player.y = 1412, 0.6, 0.3
    for i = 1, 3 do
        fire("UNIT_SPELLCAST_SENT", "player", "Copper Vein", "m" .. i, 2575)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "m" .. i, 2575)
        loot = { { guid = "GameObject-0-1-1-1-1731-BBBB77", item = 2770, qty = 1 } }
        fire("LOOT_READY") advance(3)
    end
    local vein = ns.FindNode(1412, "o1731", 0.6, 0.3, 10)
    assert(vein and vein.hits == 1, "vein hits " .. tostring(vein and vein.hits))
    player.map, player.x, player.y = 1412, 0.45, 0.7
end)
step("Skill bonus (gloves, tea) counts for gathering", function()
    ns.ImportQuestieZone(1413, true)
    player.map, player.x, player.y = 1413, 0.5, 0.5
    -- by requirement, node names differ per client language
    local function onRoute(name)
        local req = ns.RequiredSkill(nil, name)
        for _, p in ipairs(ns.run.path) do if ns.RequiredSkill(p.node.id, p.node.name) == req then return true end end
    end
    local function highest()
        local h = 0
        for _, p in ipairs(ns.run.path) do h = math.max(h, ns.RequiredSkill(p.node.id, p.node.name)) end
        return h
    end
    PROFS[1][2], PROFS[1][5] = 40, 0 -- Herbalism 40: Mageroyal (50) out of reach
    ns.StartRun("herb", 1413) advance(2)
    assert(ns.run and not onRoute("Mageroyal"), "Mageroyal on the route without a bonus")
    -- Goldthorn Tea +15 during the run: noticed within a few seconds
    PROFS[1][5] = 15
    advance(6)
    assert(ns.run and onRoute("Mageroyal"), "bonus not noticed during the run")
    assert(highest() <= 55, "node above 40+15 on the route: " .. highest())
    local rank, maxRank, eff = ns.GetSkill("herb")
    assert(rank == 40 and maxRank == 75 and eff == 55, ("GetSkill %s %s %s"):format(tostring(rank), tostring(maxRank), tostring(eff)))
    local order, text = ns.SkillVerdict("herb", "Mageroyal")
    assert(order == 0, "verdict for Mageroyal with bonus: " .. tostring(text))
    order = ns.SkillVerdict("herb", "Briarthorn")
    assert(order == 4, "Briarthorn (70) should need more skill")
    ns.StopRun()
    -- old skill list API (no GetProfessions): bonus = 6th value
    local gp, gn, gi = GetProfessions, GetNumSkillLines, GetSkillLineInfo
    GetProfessions = nil
    GetNumSkillLines = function() return 2 end
    GetSkillLineInfo = function(i)
        if i == 1 then return "Professions", true end
        return "Herbalism", false, false, 40, 0, 5, 75
    end
    rank, maxRank, eff = ns.GetSkill("herb")
    GetProfessions, GetNumSkillLines, GetSkillLineInfo = gp, gn, gi
    assert(rank == 40 and maxRank == 75 and eff == 45, ("skill line API %s %s %s"):format(tostring(rank), tostring(maxRank), tostring(eff)))
    -- a new kind gathered with a bonus: "gathered from" is what you could reach
    PROFS[1][2], PROFS[1][5] = 40, 15
    player.map, player.x, player.y = 1412, 0.3, 0.3
    fire("UNIT_SPELLCAST_SENT", "player", "Testbloom", "bonus1", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "bonus1", 2366)
    loot = { { guid = "GameObject-0-1-1-1-999001-CCCC01", item = 2447, qty = 1 } }
    fire("LOOT_READY") fire("LOOT_OPENED")
    advance(3)
    local seen
    for _, st in pairs(ns.KindStats()) do
        if st.name == "Testbloom" then seen = st end
    end
    assert(seen and seen.minSkill == 55, "minSkill with bonus: " .. tostring(seen and seen.minSkill))
    -- Overview bar shows the bonus
    PROFS[1][5] = 15
    slash("") advance(1) slash("")
    PROFS[1][2], PROFS[1][5] = 52, 0
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Pins: map and minimap apart, subtle style", function()
    local REF = "Gathercraft"
    player.map, player.x, player.y = 1412, 0.45, 0.72
    local function rebuild()
        HBD_ADDS[REF] = { world = 0, mini = 0 }
        MINI_ICONS = {}
        ns.NotifyNodesChanged() advance(1)
        return HBD_ADDS[REF]
    end
    local all = rebuild()
    assert(all.world > 0 and all.mini > 0, ("both on: %d world, %d mini"):format(all.world, all.mini))
    ns.db.worldPinsHidden = true
    local a = rebuild()
    assert(a.world == 0 and a.mini == all.mini, ("world off: %d world, %d mini (was %d)"):format(a.world, a.mini, all.mini))
    ns.db.worldPinsHidden, ns.db.miniPinsHidden = nil, true
    a = rebuild()
    assert(a.world == all.world and a.mini == 0, ("mini off: %d world, %d mini"):format(a.world, a.mini))
    ns.db.worldPinsHidden = true
    a = rebuild()
    assert(a.world == 0 and a.mini == 0, "both off still adds pins")
    slash("pins") -- one command turns both on again
    assert(not ns.db.worldPinsHidden and not ns.db.miniPinsHidden, "/gcr pins did not show both")
    slash("pins")
    assert(ns.db.worldPinsHidden and ns.db.miniPinsHidden, "/gcr pins did not hide both")
    ns.db.worldPinsHidden, ns.db.miniPinsHidden = nil, nil
    -- old single switch is taken over
    ns.db.pinsHidden = true
    ns.MigratePinSwitches()
    assert(ns.db.worldPinsHidden and ns.db.miniPinsHidden and ns.db.pinsHidden == nil, "old switch not migrated")
    ns.db.pinsHidden = false
    ns.MigratePinSwitches()
    assert(not ns.db.worldPinsHidden and not ns.db.miniPinsHidden, "old 'shown' not migrated")
    -- subtle: silver ring, round see-through icon; world map pins stay plain
    ns.db.miniPinStyle = nil -- the default is subtle
    rebuild()
    assert(ns.SubtleMinimap(), "subtle is not the default")
    -- own finds are drawn above known spawn points (fixed order, also after a redraw)
    local ownSeen, questieSeen = false, false
    for _, pin in ipairs(MINI_ICONS) do
        local n = pin.node
        if n and not n.pendingReport then
            local want = (n.source == "questie") and 1 or (n.source == nil and 3 or 2)
            assert(pin.layer == want, ("pin layer %s for %s"):format(tostring(pin.layer), tostring(n.source)))
            pin:Show() pin.__scripts.OnShow(pin)
            assert(pin:GetFrameLevel() == Minimap:GetFrameLevel() + want, "frame level does not follow the layer")
            if n.source == nil then ownSeen = true elseif n.source == "questie" then questieSeen = true end
        end
    end
    assert(ownSeen and questieSeen, "test needs own and Questie pins")
    local subtle, plainPending = 0, 0
    for _, pin in ipairs(MINI_ICONS) do
        if pin.subtle then
            subtle = subtle + 1
            assert(pin.ring and pin.ring:IsShown() and tostring(pin.ring.__tex):find("RingSilver"), "no silver ring")
            assert((pin.icon.__masks or 0) == 1, "icon not round")
            assert(pin.icon.__alpha and pin.icon.__alpha < 1, "icon not see-through")
        end
    end
    assert(subtle > 0, "no subtle minimap pins")
    ns.db.miniPinStyle = "normal"
    rebuild()
    for _, pin in ipairs(MINI_ICONS) do
        assert(not pin.subtle and not (pin.ring and pin.ring:IsShown()), "normal style still has a ring")
        assert((pin.icon.__masks or 0) == 0, "normal style icon still round")
        assert(pin.icon.__alpha == 1, "normal style icon still see-through")
    end
    -- and back: reused pins get their ring again
    ns.db.miniPinStyle = "subtle"
    rebuild()
    for _, pin in ipairs(MINI_ICONS) do
        if pin.subtle then
            assert(pin.ring:IsShown() and (pin.icon.__masks or 0) == 1, "reused pin without ring")
        end
    end
    ns.db.miniPinStyle = nil
    rebuild()
    -- minimap opacity: minimap pins only, world map pins unchanged
    local function alphas()
        local mini, world = nil, nil
        for _, pin in ipairs(MINI_ICONS) do if pin.node and not pin.node.pendingReport then mini = pin.__alpha break end end
        for _, f in ipairs(allFrames) do
            if f.node and not f.isMini and f.__alpha and f.__alpha > 0 and not f.node.pendingReport and f.node.source == "questie" then world = f.__alpha break end
        end
        return mini, world
    end
    local mini1, world1 = alphas()
    ns.db.miniPinAlpha = 0.5
    rebuild()
    local mini2, world2 = alphas()
    assert(mini1 and mini2 and math.abs(mini2 - mini1 * 0.5) < 1e-6, ("minimap opacity not applied: %s -> %s"):format(tostring(mini1), tostring(mini2)))
    assert(world1 and world2 == world1, "world map pins changed with minimap opacity")
    ns.db.miniPinAlpha = nil
    rebuild()
    -- options: both switches, the style selector and its tooltip
    slash("options") advance(1)
    for _, f in ipairs(allFrames) do
        if f.__kind == "CheckButton" and f.get then f:SetChecked(not f.get()) f.__scripts.OnClick(f) f:SetChecked(not f.get()) f.__scripts.OnClick(f) end
    end
    local before = ns.db.miniPinStyle
    for _, f in ipairs(allFrames) do
        if f.__kind == "Button" and f.__text == ">" and f.__scripts.OnEnter then
            local ok, err = pcall(f.__scripts.OnEnter, f)
            assert(ok, "tooltip: " .. tostring(err))
        end
    end
    -- opacity: - / + in steps of 10%, never below 20%, 100% is the default
    local down, up
    for _, f in ipairs(allFrames) do
        if f.__kind == "Button" and f.__scripts.OnEnter and f.__text == "-" then down = f end
        if f.__kind == "Button" and f.__scripts.OnEnter and f.__text == "+" then up = f end
    end
    assert(down and up, "no opacity buttons")
    assert(pcall(down.__scripts.OnEnter, down), "opacity tooltip")
    down.__scripts.OnClick(down)
    assert(math.abs((ns.db.miniPinAlpha or 1) - 0.9) < 1e-6, "minus did not lower opacity")
    for i = 1, 12 do down.__scripts.OnClick(down) end
    assert(math.abs(ns.db.miniPinAlpha - 0.2) < 1e-6, "opacity below 20%")
    for i = 1, 12 do up.__scripts.OnClick(up) end
    assert(ns.db.miniPinAlpha == nil, "100% not back to default")
    -- sections: the chosen one is remembered, the first one is the default
    ns.ShowOptionsSection("sync")
    assert(ns.db.optionsSection == "sync", "section not remembered")
    ns.ShowOptionsSection("nope")
    assert(ns.db.optionsSection == nil, "unknown section not back to the first")
    slash("options")
    assert(ns.db.miniPinStyle == before, "tooltips changed the style")
    assert(not ns.db.worldPinsHidden and not ns.db.miniPinsHidden, "switches not back on")
end)
step("Farm run target: own marker, game waypoint only without arrow", function()
    local T = "GathercraftTarget"
    player.map, player.x, player.y = 1412, 0.45, 0.72
    USER_WP, WP_SETS, WP_CLEARS = nil, 0, 0
    HBD_ADDS[T] = { world = 0, mini = 0 }
    ns.db.arrowHidden = nil
    slash("run herb") advance(2)
    assert(ns.run and ns.run.target, "no target")
    assert(HBD_ADDS[T].world >= 1 and HBD_ADDS[T].mini >= 1, "no target marker")
    assert(HBD_FLOAT[T] == true, "target marker does not stick to the minimap edge")
    assert(WP_SETS == 0, "game waypoint set although our arrow is on")
    -- the marker stays when node pins are off
    ns.db.worldPinsHidden, ns.db.miniPinsHidden = true, true
    HBD_ADDS[T] = { world = 0, mini = 0 }
    ns.NotifyNodesChanged() advance(1)
    assert(HBD_ADDS[T].world >= 1 and HBD_ADDS[T].mini >= 1, "target marker gone with the pins")
    ns.db.worldPinsHidden, ns.db.miniPinsHidden = nil, nil
    -- arrow off: the game's waypoint stands in, and goes at the end
    ns.db.arrowHidden = true
    ns.RouteArrowChanged()
    assert(WP_SETS == 1 and USER_WP, "no game waypoint with the arrow off")
    slash("skip") advance(2)
    assert(WP_SETS == 2, "waypoint did not follow the next target")
    slash("stop") advance(1)
    assert(USER_WP == nil and WP_CLEARS == 1, "our waypoint stayed after the run")
    -- your own waypoint survives a run with the arrow on
    ns.db.arrowHidden = nil
    USER_WP, WP_SETS, WP_CLEARS = { m = 1412, x = 0.9, y = 0.9 }, 0, 0
    slash("run herb") advance(2)
    slash("skip") advance(2)
    slash("stop") advance(1)
    assert(USER_WP and USER_WP.x == 0.9 and WP_CLEARS == 0, "own waypoint touched")
    -- ... and one you set during a run with the arrow off, also at the next target
    ns.db.arrowHidden = true
    slash("run herb") advance(2)
    USER_WP = { m = 1412, x = 0.1, y = 0.1 }
    slash("skip") advance(2)
    assert(USER_WP and USER_WP.x == 0.1, "own waypoint replaced at the next target")
    slash("stop") advance(1)
    assert(USER_WP and USER_WP.x == 0.1, "waypoint set during the run was cleared")
    -- the target's normal pins step aside for the gold one, and come back
    ns.db.arrowHidden = nil
    slash("run herb") advance(2)
    local t = ns.run.target
    MINI_ICONS = {}
    ns.NotifyNodesChanged() advance(1)
    local hidden = 0
    for _, pin in ipairs(MINI_ICONS) do
        if pin.node == t then
            hidden = hidden + 1
            assert(pin.__alpha == 0, "normal pin of the target still visible")
        end
    end
    slash("stop") advance(1)
    for _, pin in ipairs(MINI_ICONS) do
        if pin.node == t then assert(pin.__alpha > 0, "pin of the old target stays hidden") end
    end
    assert(hidden > 0, "target node has no minimap pin to hide")
    ns.db.arrowHidden = nil
    USER_WP = nil
end)
step("Route line: dense all around you, also where the route bends back", function()
    local Z = 1461
    ns.db.nodes[Z] = {}
    -- out 900 yd east, then back west past you, then far away: zone is 5000 x 3333 yd
    local xs = { 0.56, 0.62, 0.68, 0.62, 0.53, 0.47, 0.41, 0.35, 0.25, 0.15 }
    for i, x in ipairs(xs) do
        table.insert(ns.db.nodes[Z], { id = "o1618", name = "Peacebloom", type = "herb", x = x, y = 0.5 + (i % 2) * 0.01, count = 1, last = 1 })
    end
    player.map, player.x, player.y = Z, 0.5, 0.5
    ns.db.routeLineStyle = "line"
    ns.StartRun("herb", Z) advance(1)
    assert(ns.run and ns.run.path and #ns.run.path >= 8, "no route")
    LINE_PTS, LINE_DOTS = {}, 0
    ns.RedrawRouteLine()
    local pxw, pyw = player.x * 5000 + (Z - 1400) * 6000, player.y * 3333
    local near, worst = 0, 0
    for i, a in ipairs(LINE_PTS) do
        if math.sqrt((a[1] - pxw) ^ 2 + (a[2] - pyw) ^ 2) < 450 then
            near = near + 1
            local best = math.huge
            for j, b in ipairs(LINE_PTS) do
                if i ~= j then best = math.min(best, math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)) end
            end
            worst = math.max(worst, best)
        end
    end
    note("route line near dots", near, "worst gap", worst, "all", LINE_DOTS)
    assert(near > 50 and worst <= 8, ("line not dense around you: %d dots, gap %.1f yd"):format(near, worst))
    assert(LINE_DOTS <= 620, "too many dots: " .. LINE_DOTS)
    ns.StopRun()
    ns.db.routeLineStyle = nil
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Debug: chat tab opens, also a closed one of an old client", function()
    local was = ns.db.debug
    -- closed tab named Gathercraft (e.g. chat settings from the beta)
    CHAT_WIN[3] = { "Gathercraft", false, false }
    _G.ChatFrame3:Hide()
    _G.ChatFrame3.__lines = 0
    FCF_OPENED = 0
    ns.db.debug = false
    slash("debug") -- on
    assert(ns.db.debug, "debug not on")
    assert(FCF_OPENED == 1 and CHAT_WIN[3][2], "closed Gathercraft tab not opened again")
    assert(_G.ChatFrame3.__lines >= 1, "no line in the Gathercraft tab")
    -- now it is open: no new window for later lines
    ns.Debug("second line")
    assert(FCF_OPENED == 1 and _G.ChatFrame3.__lines >= 2, "second line went elsewhere")
    -- no tab at all: one is made
    CHAT_WIN[3] = nil
    _G.ChatFrame3:Hide()
    ns.db.debug = false
    slash("debug")
    assert(FCF_OPENED == 2 and CHAT_WIN[3] and CHAT_WIN[3][1] == "Gathercraft", "no new tab made")
    ns.db.debug = was
    CHAT_WIN[3] = nil
end)
step("Farm run: waiting counts down, gives up after 10 minutes", function()
    local Z = 1462
    ns.db.nodes[Z] = { { id = "o1731", name = "Copper Vein", type = "ore", x = 0.52, y = 0.5, count = 1, last = 1 } }
    player.map, player.x, player.y = Z, 0.5, 0.5
    local vein = ns.db.nodes[Z][1]
    vein.emptyUntil = time() + 150 -- just mined
    ns.StartRun("ore", Z) advance(1)
    assert(ns.run and not ns.run.target and ns.run.waiting, "run should wait")
    assert(ns.run.nextRespawn == vein.emptyUntil, "no respawn time: " .. tostring(ns.run.nextRespawn))
    advance(1)
    local panelText
    for _, f in ipairs(allFrames) do
        if f.__kind == "FontString" and type(f.__text) == "string" and f.__text:find("2:%d%d") and f.__text:find("|cffaaaaaa") then panelText = f.__text end
    end
    assert(panelText, "farm panel shows no countdown")
    -- respawned: the run goes on by itself
    advance(160)
    assert(ns.run and ns.run.target == vein, "run did not pick the vein up again")
    assert(ns.run.waitingSince == nil, "waiting time not reset")
    -- mined again, and nothing comes back for a long time: stops after 10 minutes
    vein.emptyUntil = time() + 3600
    ns.run.target = nil
    ns.RouteGoalChanged() advance(1)
    assert(ns.run and ns.run.waiting, "not waiting again")
    advance(590)
    assert(ns.run, "stopped too early")
    advance(20)
    assert(not ns.run, "run still waiting after 10 minutes")
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Sync self-healing: parked only after many empty visits over a long time", function()
    local Z = 1463
    local function sync(x, extra)
        local n = { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = 0.5, count = 3, last = 1,
            source = "sync", heard = 3, heardBy = { ["Alt One"] = true, ["Alt Two"] = true, ["Alt Three"] = true } }
        for k, v in pairs(extra or {}) do n[k] = v end
        return n
    end
    ns.db.nodes[Z] = {
        sync(0.55),                    -- fake: three alts, never there
        sync(0.45, { hits = 1 }),      -- harvested once: real
        sync(0.40, { heard = 5 }),     -- more players than the first three know it
        sync(0.35, { seenAt = 1 }),    -- seen with your own eyes
        { id = "o1731", name = "Copper Vein", type = "ore", x = 0.50, y = 0.55, count = 3, last = 1 }, -- own
    }
    local list = ns.db.nodes[Z]
    -- the clock jumps (no timers run in between: hours would take minutes)
    local function jump(sec)
        NOW = NOW + sec
        for _, t in ipairs(timers) do t.at = t.at + sec end -- running timers move along
    end
    local fake, safe = list[1], { list[2], list[3], list[4], list[5] }
    -- visits only 5 minutes apart: one counts per 10 minutes
    for i = 1, 6 do ns.SyncSelfHeal(fake) jump(300) end
    assert(fake.healMisses == 3, "spacing: " .. tostring(fake.healMisses))
    -- many counted visits within a few hours: real spawn points are often empty
    for i = 1, 8 do jump(620) ns.SyncSelfHeal(fake) end
    assert(fake.healMisses >= 5 and not ns.IsParked(fake), "parked within a few hours")
    -- still never there half a day later: parked, not deleted
    jump(12 * 3600)
    assert(ns.SyncSelfHeal(fake) and ns.IsParked(fake), "fake not parked")
    assert(ns.FindNode(Z, "o1731", 0.55, 0.5, 5) == fake, "parked node was deleted")
    for _, n in ipairs(safe) do
        for i = 1, 30 do ns.SyncSelfHeal(n) jump(1800) end
        assert(not ns.IsParked(n), "a safe node got parked: x=" .. n.x)
    end
    -- parked: not in routes
    player.map, player.x, player.y = Z, 0.56, 0.5
    for _, n in ipairs(list) do n.emptyUntil = nil end
    ns.StartRun("ore", Z) advance(1)
    assert(ns.run and ns.run.path, "no run")
    for _, p in ipairs(ns.run.path) do assert(p.node ~= fake, "parked node in the route") end
    ns.StopRun()
    -- the alts again: still parked; someone new: back
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:" .. Z .. ";o1731,o,5500,5000,2770", "CHANNEL", "Alt Two", nil, nil, nil, "GathercraftSync")
    advance(1)
    assert(ns.IsParked(fake), "an old reporter brought it back")
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:" .. Z .. ";o1731,o,5500,5000,2770", "CHANNEL", "Someone New", nil, nil, nil, "GathercraftSync")
    advance(1)
    assert(not ns.IsParked(fake) and not fake.healMisses, "a new reporter did not bring it back")
    local heard = fake.heard
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:" .. Z .. ";o1731,o,5500,5000,2770", "CHANNEL", "Someone New", nil, nil, nil, "GathercraftSync")
    advance(1)
    assert(fake.heard == heard, "the same player counted twice")
    -- harvesting a parked node: yours now, not parked
    fake.parked, fake.heard = time(), 3
    assert(ns.IsParked(fake), "test setup")
    fake.hits = 1
    assert(not ns.IsParked(fake), "harvested node still parked")
    -- an imported node remembers who reported it
    for _, who in ipairs({ "Rep One", "Rep Two", "Rep Three" }) do
        fire("CHAT_MSG_ADDON", "Gathercraft", "N:" .. Z .. ";o1732,h,3000,3000,2447", "CHANNEL", who, nil, nil, nil, "GathercraftSync")
    end
    advance(1)
    local imp = ns.FindNode(Z, "o1732", 0.3, 0.3, 5)
    assert(imp and imp.heardBy and imp.heardBy["Rep One"] and imp.heardBy["Rep Three"] and imp.heard == 3, "reporters not kept on import")
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Farm run: only the target counts as empty, not passing by or fighting", function()
    local Z = 1464
    local function own(x, y) return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = y, count = 3, last = 1 } end
    ns.db.nodes[Z] = { own(0.50, 0.50), own(0.53, 0.50), own(0.60, 0.50), own(0.50, 0.60) }
    local A, P, C, D = unpack(ns.db.nodes[Z])
    local heals = 0
    local realHeal = ns.SyncSelfHeal
    ns.SyncSelfHeal = function(n) heals = heals + 1 return realHeal(n) end
    local function aim(node)
        for _, p in ipairs(ns.run.path) do
            if p.node == node then ns.run.target, ns.run.targetPoint, ns.run.targetBest = node, p, nil return end
        end
        error("node not in the path")
    end
    player.map, player.x, player.y = Z, 0.51, 0.505
    ns.StartRun("ore", Z) advance(1)
    -- the target, found empty: learns (and could count for self-healing)
    aim(A)
    player.x, player.y = 0.50, 0.50
    advance(30)
    assert((A.misses or 0) == 1 and heals == 1, "empty target not counted")
    -- passing a node on the way to another one: short rest only
    aim(C)
    player.x, player.y = 0.53, 0.50
    advance(30)
    assert(not P.misses and P.emptyUntil and heals == 1, "passing by counted as empty")
    -- the target, but you were fighting: short rest only
    aim(D)
    UnitAffectingCombat = function() return true end
    player.x, player.y = 0.50, 0.60
    advance(30)
    UnitAffectingCombat = nil
    assert(not D.misses and D.emptyUntil and heals == 1, "empty while fighting counted")
    -- skipped: learns, no self-healing
    aim(C)
    slash("skip") advance(1)
    assert((C.misses or 0) == 1 and heals == 1, "skip counted for self-healing")
    ns.StopRun()
    ns.SyncSelfHeal = realHeal
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Farm run: walking away from the target picks a new one", function()
    local Z = 1465
    local function own(x) return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = 0.50, count = 3, last = 1 } end
    -- the old target stays the nearest node after you walked off: without the
    -- detour rule the arrow would point straight back at it
    ns.db.nodes[Z] = { own(0.40), own(0.70), own(0.72) }
    player.map, player.x, player.y = Z, 0.47, 0.50
    ns.StartRun("ore", Z) advance(1)
    local old = ns.run and ns.run.target
    assert(old, "no target")
    -- a few steps away: the target stays (no jumping arrow)
    local dir = old.x < 0.47 and 1 or -1
    player.x = 0.47 + dir * 0.01 advance(11)
    assert(ns.run.target == old, "target changed after a few steps")
    -- far away from it (a quest): a new target, the old one comes later
    player.x = 0.47 + dir * 0.05 advance(1)
    assert(ns.run.target and ns.run.target ~= old, "still pointing back at the old target")
    local later = false
    for i, p in ipairs(ns.run.path) do if p.node == old and i > 1 then later = true end end
    assert(later, "old target dropped from the path")
    ns.StopRun()
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Farm run: a node you can't get to is left out for a while", function()
    local Z = 1468
    local function own(x, y) return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = y, count = 3, last = 1 } end
    ns.db.nodes[Z] = { own(0.50, 0.30), own(0.80, 0.80) }
    local cliff, other = ns.db.nodes[Z][1], ns.db.nodes[Z][2]
    player.map, player.x, player.y = Z, 0.50, 0.50
    ns.StartRun("ore", Z) advance(1)
    assert(ns.run.target == cliff, "test setup: nearest node first")
    -- walking back and forth below the cliff for half a minute, never getting closer
    local walk = C_Timer.NewTicker(1, function() player.x = (player.x < 0.5) and 0.502 or 0.498 end)
    advance(10)
    assert(ns.run.target == cliff, "gave up too early")
    advance(25)
    walk:Cancel()
    assert(ns.run.target == other, "still sent up the cliff")
    assert(cliff.unreachUntil and cliff.unreachUntil > time() + 600, "node not left out")
    advance(70) -- also after the "not first again" minute: out of the route altogether
    for _, p in ipairs(ns.run.path or {}) do assert(p.node ~= cliff, "unreachable node still in the route") end
    -- standing still or fighting is no reason to give up
    ns.StopRun()
    cliff.unreachUntil, cliff.reachMiss = nil, nil
    player.x, player.y = 0.50, 0.50
    ns.StartRun("ore", Z) advance(1)
    assert(ns.run.target == cliff, "test setup again")
    advance(40)
    assert(ns.run.target == cliff and not cliff.unreachUntil, "standing still counted as stuck")
    UnitAffectingCombat = function() return true end
    walk = C_Timer.NewTicker(1, function() player.x = (player.x < 0.5) and 0.502 or 0.498 end)
    advance(40)
    walk:Cancel()
    UnitAffectingCombat = nil
    assert(ns.run.target == cliff and not cliff.unreachUntil, "fighting counted as stuck")
    -- by hand, then harvested after all: back to normal
    slash("unreachable") advance(1)
    assert(cliff.unreachUntil and ns.run.target ~= cliff, "/gcr unreachable did nothing")
    ns.OnHarvested(cliff, "S1")
    assert(not cliff.unreachUntil and not cliff.reachMiss, "harvest did not clear it")
    ns.StopRun()
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Minimap tooltip: pointing at a tracked node learns it", function()
    local Z = 1466
    local names = GathercraftNodeNames and GathercraftNodeNames[GetLocale()]
    local veinName = names and names[1731] or "Copper Vein"
    local herbName = names and names[1618] or "Peacebloom"
    -- the minimap: 140 px wide, centre at 500/400, zoom 0 outdoors (radius 233 yd)
    local owner, lines, over, cursor = Minimap, {}, true, { 535, 400 }
    local savedCursor, savedCVar = GetCursorPosition, GetCVar
    Minimap.IsMouseOver = function() return over end
    Minimap.GetCenter = function() return 500, 400 end
    Minimap.GetWidth = function() return 140 end
    Minimap.GetHeight = function() return 140 end
    Minimap.GetZoom = function() return 0 end
    Minimap.GetEffectiveScale = function() return 1 end
    GameTooltip.IsShown = function() return #lines > 0 end
    GameTooltip.GetOwner = function() return owner end
    GameTooltip.NumLines = function() return #lines end
    for i = 1, 3 do
        local fs = _G["GameTooltipTextLeft" .. i] or newObject("FontString", "GameTooltipTextLeft" .. i)
        _G["GameTooltipTextLeft" .. i] = fs
        fs.GetText = function() return lines[i] end
    end
    GetCursorPosition = function() return cursor[1], cursor[2] end
    local rotate = "0"
    GetCVar = function(k) if k == "rotateMinimap" then return rotate end return "0" end
    player.map, player.x, player.y = Z, 0.5, 0.5
    -- 35 px right of the centre = half the radius = 116.7 yd (the mock world runs the other way round)
    local ex, ey = 0.5 - (35 / 70 * (466 + 2 / 3) / 2) / 5000, 0.5
    local mapID, cx, cy = ns.CursorOnMap()
    assert(mapID == Z and math.abs(cx - ex) < 1e-6 and math.abs(cy - ey) < 1e-6, ("cursor position %s %s"):format(tostring(cx), tostring(cy)))
    -- rotating minimap, facing west (90°): the same pixel is somewhere else
    rotate = "1"
    local realFacing = GetPlayerFacing
    GetPlayerFacing = function() return math.pi / 2 end
    local _, rx, ry = ns.CursorOnMap()
    assert(math.abs(rx - 0.5) < 1e-6 and math.abs(ry - (0.5 + 116.6667 / 3333)) < 1e-4, ("rotated %s %s"):format(tostring(rx), tostring(ry)))
    rotate, GetPlayerFacing = "0", realFacing
    -- a known spawn point next to it: that one is up now
    ns.db.nodes[Z] = { { id = "o1731", name = veinName, type = "ore", x = ex + 0.001, y = ey, count = 1, last = 1, source = "questie", emptyUntil = time() + 600 } }
    local vein = ns.db.nodes[Z][1]
    lines = { "|cffffffff" .. veinName .. "|r" }
    advance(1)
    assert(vein.seenAt and vein.upAt and not vein.emptyUntil, "known vein not marked as up")
    assert(ns.NodeChance(vein) == 1, "a node seen up is not certain for the route")
    assert(#ns.db.nodes[Z] == 1, "a known node was added again")
    -- a herb nobody knew: learned at the cursor, rough position
    lines = { herbName }
    cursor = { 500, 435 } -- above the centre
    advance(1)
    local herb
    for _, n in ipairs(ns.db.nodes[Z]) do if n.id == "o1618" then herb = n end end
    assert(herb and herb.seenOnly and herb.type == "herb" and herb.item == 2447, "new herb not learned")
    -- zoom 0: 233 yd over 70 px = 3.3 yd per pixel, a look can be ~10 px off: ~33 yd
    assert(herb.seenErr and math.abs(herb.seenErr - 10 * (466 + 2 / 3) / 2 / 70) < 0.5, "look error not from the zoom: " .. tostring(herb.seenErr))
    local count = #ns.db.nodes[Z]
    local wasDebug = ns.db.debug
    ns.db.debug = true
    local function seenLines()
        local c = 0
        for _, l in ipairs(log) do if l:find("SEEN", 1, true) then c = c + 1 end end
        return c
    end
    local before = seenLines()
    advance(3) -- still pointing at it: not every look counts again
    assert(seenLines() == before, "the same node counted again while pointing at it")
    advance(3) -- a while later it may count again, but never as a second node
    assert(#ns.db.nodes[Z] == count, "pointing longer made a duplicate")
    -- pointing again a bit to the side: the guess moves towards the average
    local oldY = herb.y
    cursor = { 500, 438 } -- 10 yd further
    local _, _, newY = ns.CursorOnMap()
    advance(6)
    assert(#ns.db.nodes[Z] == count and (herb.seenLooks or 1) >= 2, "second look not used")
    assert(herb.y > math.min(oldY, newY) + 1e-9 and herb.y < math.max(oldY, newY) - 1e-9,
        ("position not averaged: %.5f between %.5f and %.5f?"):format(herb.y, oldY, newY))
    cursor = { 500, 435 }
    ns.db.debug = wasDebug
    -- not shared while its position is a guess
    local sent = #sentMessages
    ns.SyncShare(Z, herb) advance(3)
    assert(#sentMessages == sent, "a node only seen on the minimap was shared")
    -- another addon's pin tooltip, our own pins, or the option off: nothing
    lines = { herbName }
    cursor = { 500, 365 }
    owner = newObject("Frame", "SomeAddonPin")
    advance(1)
    assert(#ns.db.nodes[Z] == count, "learned from someone else's tooltip")
    owner = setmetatable({ node = herb }, { __index = owner }) -- one of our own pins
    advance(1)
    assert(#ns.db.nodes[Z] == count, "learned from our own pin's tooltip")
    -- WoW Forever: the tooltip belongs to UIParent, the minimap is under the mouse
    owner = UIParent
    GetMouseFoci = function() return { Minimap } end
    cursor = { 465, 400 }
    advance(1)
    assert(#ns.db.nodes[Z] == count + 1, "tooltip owned by UIParent over the minimap not read")
    table.remove(ns.db.nodes[Z]) -- (keeps one herb for the harvest check below)
    ns.NotifyNodesChanged()
    -- the same owner, but a pin is under the mouse (another addon's): not ours to read
    GetMouseFoci = function() return { newObject("Button", "OtherAddonPin") } end
    cursor = { 500, 470 }
    advance(6)
    assert(#ns.db.nodes[Z] == count, "read a tooltip while a pin was under the mouse")
    GetMouseFoci = nil
    owner, ns.db.minimapLearnOff = Minimap, true
    advance(1)
    assert(#ns.db.nodes[Z] == count, "learned with the option off")
    ns.db.minimapLearnOff = nil
    lines = {}
    advance(1)
    -- harvested 20 yd from the guess: the same node, real position now
    player.x, player.y = herb.x + 20 / 5000, herb.y
    fire("UNIT_SPELLCAST_SENT", "player", herbName, "seen1", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "seen1", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1618-SEEN01", item = 2447, qty = 2 } }
    fire("LOOT_READY") fire("LOOT_OPENED")
    advance(3)
    local herbs = 0
    for _, n in ipairs(ns.db.nodes[Z]) do if n.id == "o1618" then herbs = herbs + 1 end end
    assert(herbs == 1, "harvest next to the guess made a second node: " .. herbs)
    assert(not herb.seenOnly and math.abs(herb.x - player.x) < 1e-6, "position not taken from the harvest")
    -- one hover across a blip: the positions are averaged (middle of the blip)
    owner = UIParent
    GetMouseFoci = function() return { Minimap } end
    lines = {}
    advance(1)
    local left, right = { 420, 340 }, { 432, 340 }
    cursor = left
    local _, lx = ns.CursorOnMap()
    cursor = right
    local _, rx = ns.CursorOnMap()
    local flip = C_Timer.NewTicker(0.05, function() cursor = (cursor == left) and right or left end)
    lines = { herbName }
    advance(0.5)
    flip:Cancel()
    lines = {}
    advance(1)
    local hovered
    for _, n in ipairs(ns.db.nodes[Z]) do
        if n.seenOnly and n.x > math.min(lx, rx) - 0.002 and n.x < math.max(lx, rx) + 0.002 and math.abs(n.y - ns.db.nodes[Z][1].y) < 1 then hovered = n end
    end
    assert(hovered, "hover not learned")
    local mid = (lx + rx) / 2
    assert(math.abs(hovered.x - mid) < math.abs(rx - lx) * 0.3, ("hover not averaged: %.5f, edges %.5f / %.5f"):format(hovered.x, lx, rx))
    GetMouseFoci = nil
    owner = Minimap
    -- the diagnosis command runs through without errors
    lines = { herbName }
    slash("mmtest") advance(21)
    lines = {}
    advance(1)
    -- back to the plain mocks (instance fields hide the shared methods)
    for _, k in ipairs({ "IsMouseOver", "GetCenter", "GetWidth", "GetHeight", "GetZoom", "GetEffectiveScale" }) do Minimap[k] = nil end
    for _, k in ipairs({ "IsShown", "GetOwner", "NumLines" }) do GameTooltip[k] = nil end
    GetCursorPosition, GetCVar = savedCursor, savedCVar
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Minimap tooltip: rough guesses (zoomed out) still find their node", function()
    local Z = 1467
    local names = GathercraftNodeNames and GathercraftNodeNames[GetLocale()]
    local herbName = names and names[1618] or "Peacebloom"
    player.map, player.x, player.y = Z, 0.5, 0.5
    -- guessed with the minimap zoomed out (~20 yd error): a harvest 45 yd away is that node
    local rough = { id = "o1618", name = herbName, type = "herb", x = 0.5, y = 0.5, count = 1, last = 1,
        seenOnly = true, seenErr = 12, seenW = 1 / 144, lookErr = 24 } -- averaged, but each look ~24 yd off
    -- guessed zoomed in (~5 yd): a harvest 45 yd away is another node
    local fine = { id = "o1618", name = herbName, type = "herb", x = 0.5, y = 0.6, count = 1, last = 1,
        seenOnly = true, seenErr = 5, seenW = 1 / 25, lookErr = 5 }
    ns.db.nodes[Z] = { rough, fine }
    local function harvest(x, y, tag)
        player.x, player.y = x, y
        fire("UNIT_SPELLCAST_SENT", "player", herbName, tag, 2366)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", tag, 2366)
        loot = { { guid = "GameObject-0-1-1-1-1618-" .. tag, item = 2447, qty = 1 } }
        fire("LOOT_READY") fire("LOOT_OPENED")
        advance(3)
    end
    harvest(0.5 + 45 / 5000, 0.5, "RGH001")
    assert(#ns.db.nodes[Z] == 2 and not rough.seenOnly, "rough guess 45 yd away did not merge")
    harvest(0.5 + 45 / 5000, 0.6, "FIN001")
    assert(#ns.db.nodes[Z] == 3 and fine.seenOnly, "exact guess merged with a node 45 yd away")
    -- a look zoomed in counts much more than the rough guess it improves
    local guess = { id = "o1618", name = herbName, type = "herb", x = 0.3, y = 0.3, count = 1, last = 1,
        seenOnly = true, seenErr = 20, seenW = 1 / 400 }
    table.insert(ns.db.nodes[Z], guess)
    ns.SeenOnMinimap(Z, 0.3 + 10 / 5000, 0.3, herbName, 5)
    local moved = (guess.x - 0.3) * 5000
    assert(moved > 8 and moved < 10, ("zoomed-in look moved the guess %.1f of 10 yd"):format(moved))
    assert(guess.seenErr < 6, "error did not shrink: " .. tostring(guess.seenErr))
    -- a zoomed-out look finds a rough guess of ours up to 2 x its error away
    local count = #ns.db.nodes[Z]
    ns.SeenOnMinimap(Z, 0.7, 0.7, herbName, 20)
    local far = ns.db.nodes[Z][#ns.db.nodes[Z]]
    advance(6)
    ns.SeenOnMinimap(Z, 0.7 + 35 / 5000, 0.7, herbName, 20)
    assert(#ns.db.nodes[Z] == count + 1 and far.seenLooks == 2, "zoomed-out looks 35 yd apart made two nodes")
    -- many looks made a guess exact (~8 yd), the next rough look is 40 yd off: still that node
    local avg = { id = "o1618", name = herbName, type = "herb", x = 0.6, y = 0.2, count = 1, last = 1,
        seenOnly = true, seenErr = 8, seenW = 1 / 64, lookErr = 24, seenLooks = 9 }
    table.insert(ns.db.nodes[Z], avg)
    count = #ns.db.nodes[Z]
    advance(6)
    ns.SeenOnMinimap(Z, 0.6 + 40 / 5000, 0.2, herbName, 24)
    assert(#ns.db.nodes[Z] == count and avg.seenLooks == 10, "an exact guess turned away a rough look 40 yd off")
    -- a zoomed-in look 40 yd off that guess (its looks were rough): it improves it, no second node
    advance(6)
    local before = avg.x
    ns.SeenOnMinimap(Z, 0.6 + 45 / 5000, 0.2, herbName, 6)
    assert(#ns.db.nodes[Z] == count and avg.seenLooks == 11 and avg.x > before, "zoomed-in look made a second node next to a rough guess")
    -- a known spawn point 35 yd from a zoomed-out look is the one we see (zoomed in: not)
    local spawn = { id = "o1618", name = herbName, type = "herb", x = 0.2, y = 0.8, count = 1, last = 1, source = "questie" }
    table.insert(ns.db.nodes[Z], spawn)
    count = #ns.db.nodes[Z]
    advance(6)
    ns.SeenOnMinimap(Z, 0.2 + 35 / 5000, 0.8, herbName, 20)
    assert(#ns.db.nodes[Z] == count and spawn.upAt, "zoomed-out look did not find the spawn point 35 yd away")
    advance(6)
    ns.SeenOnMinimap(Z, 0.2 - 35 / 5000, 0.8, herbName, 5)
    assert(#ns.db.nodes[Z] == count + 1, "zoomed-in look took a spawn point 35 yd away")
    -- old duplicates (four guesses of one herb, up to 40 yd apart) become one; a real
    -- second herb 120 yd away and exact nodes stay
    local function seen(dx, dy) return { id = "o1618", name = herbName, type = "herb", x = 0.4 + dx / 5000, y = 0.4 + dy / 3333,
        count = 1, last = 1, seenOnly = true } end
    ns.db.nodes[Z] = { seen(0, 0), seen(30, 0), seen(0, 30), seen(25, 25), seen(120, 0),
        { id = "o1618", name = herbName, type = "herb", x = 0.4 + 10 / 5000, y = 0.4, count = 2, last = 1 } }
    local merged = ns.ConsolidateSeen(Z)
    assert(merged == 3 and #ns.db.nodes[Z] == 3, ("duplicates: %d merged, %d left"):format(merged, #ns.db.nodes[Z]))
    local one = ns.db.nodes[Z][1]
    assert(one.seenLooks == 4 and math.abs((one.x - 0.4) * 5000 - 13.75) < 0.5, "merged guess not the average")
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Sync: own messages with a two-part name are ours", function()
    local realName = UnitName
    UnitName = function(u) if u == "player" then return "Gather" end return realName(u) end
    local wasDebug = ns.db.debug
    ns.db.debug = true
    local node = { id = "o1619", name = "Silverleaf", type = "herb", x = 0.31, y = 0.62, count = 1, last = time() }
    table.insert(ns.db.nodes[1412], node)
    local n0 = #sentMessages
    ns.SyncShare(1412, node) advance(3)
    assert(#sentMessages > n0, "nothing sent")
    local text = sentMessages[#sentMessages]
    local function recvLines(who)
        local c = 0
        for _, l in ipairs(log) do if l:find("recv %[CHANNEL%] " .. who, 1) then c = c + 1 end end
        return c
    end
    -- our own message comes back under the full name: learned, not processed
    fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", "Gather Craft-Realm", nil, nil, nil, "GathercraftSync")
    -- later messages from that name are ours too
    fire("CHAT_MSG_ADDON", "Gathercraft", "Q:1412:7", "CHANNEL", "Gather Craft-Realm", nil, nil, nil, "GathercraftSync")
    assert(recvLines("Gather Craft") == 0, "own message processed")
    -- someone else is still heard
    fire("CHAT_MSG_ADDON", "Gathercraft", "Q:1412:7", "CHANNEL", "Other Person-Realm", nil, nil, nil, "GathercraftSync")
    assert(recvLines("Other Person") == 1, "other player not heard")
    -- the same text right away from someone with another first name is not us
    fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", "Gatherer Two-Realm", nil, nil, nil, "GathercraftSync")
    assert(recvLines("Gatherer Two") == 1, "stranger taken for us")
    for i, n in ipairs(ns.db.nodes[1412]) do if n == node then table.remove(ns.db.nodes[1412], i) break end end
    UnitName = realName
    ns.db.debug = wasDebug
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
step("Sync: single reports in a new zone show as grey pins", function()
    local function GreyPins()
        local c, seen = 0, {}
        for _, f in ipairs(allFrames) do
            if f.node and f.node.pendingReport and not seen[f.node] then
                seen[f.node] = true
                c = c + 1
            end
        end
        return c
    end
    assert(not ns.HasKnownSpawns(2521) and ns.HasKnownSpawns(1412), "known spawn zones")
    local om, ox, oy = player.map, player.x, player.y
    player.map, player.x, player.y = 2521, 0.5, 0.5 -- you are on that continent
    fire("ZONE_CHANGED_NEW_AREA") advance(2)
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:2521;o990001,h,5000,5000,2447;o990002,o,5100,5100,2770", "CHANNEL", "Stranger One", nil, nil, nil, "GathercraftSync")
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:1412;o1617,h,1234,1234,765", "CHANNEL", "Stranger One", nil, nil, nil, "GathercraftSync")
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:2521;o990003,h,nan,nan,0;o990004,h,1e3,200,0", "CHANNEL", "Stranger One", nil, nil, nil, "GathercraftSync")
    advance(1)
    local pend = ns.SyncPending(2521)
    assert(pend and #pend == 2, "reports in the new zone: " .. tostring(pend and #pend))
    local grey = GreyPins()
    assert(grey == 2, "grey pins " .. grey)
    -- a guild member confirms one: it becomes a node, its grey pin goes
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:2521;o990001,h,5000,5000,2447", "GUILD", "Guildie Two")
    advance(1)
    assert(#ns.SyncPending(2521) == 1, "confirmed report still pending")
    assert(GreyPins() == 1, "grey pin of the confirmed node still there: " .. GreyPins())
    player.map, player.x, player.y = om, ox, oy
    fire("ZONE_CHANGED_NEW_AREA") advance(2)
    for _, f in ipairs(allFrames) do
        if f.node and f.node.pendingReport and f.__scripts.OnEnter then f.__scripts.OnEnter(f) f.__scripts.OnLeave(f) break end
    end
    -- never routed: unconfirmed reports are not in the node database
    for _, n in ipairs(ns.db.nodes[2521] or {}) do assert(n.id ~= "o990002", "report became a node") end
    note("grey pins", grey)
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
    ns.db.advisorSort = "zone"
    ns.ToggleMain("overview") ns.ToggleMain("farm") advance(1)
    ns.HideMain()
    slash("run both")  -- placeholder run to make sure zone runs still work
    slash("stop")
    ns.StartRun("herb", 1413) advance(2)
    assert(ns.run and ns.run.zone == 1413 and ns.run.target, "zone run")
    advance(30)
    slash("stop")
end)
step("Crafting: shipped recipe data (all professions)", function()
    local shipped = GathercraftRecipeData and GathercraftRecipeData.professions
    assert(shipped and shipped.Enchanting and shipped.Tailoring, "RecipeData.lua not loaded")
    local n = 0
    for _, list in pairs(shipped) do for _ in pairs(list) do n = n + 1 end end
    note("shipped recipes:", n)
    assert(n > 2000, "too few shipped recipes")
    local rows = ns.CraftAdvice("Enchanting")
    note("enchanting rows:", #rows)
    ns.db.craftTab = "Enchanting" ns.ToggleMain("craft") advance(1) ns.HideMain()
    -- the rest of the crafting tests work on their own data
    savedShipped = GathercraftRecipeData
    GathercraftRecipeData = { version = "test", professions = {} }
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
    slash("pintest")
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
            or i == 4 and { "Enchanting: Enchant Chest - Inferior Stamina", "", "Tools: Runed Copper Rod", "Reagents: |nStrange Dust" }
            or { "Journeyman Tailoring", "Allows you to learn more." }
        local lines = {}
        for _, x in ipairs(t) do lines[#lines + 1] = { leftText = x } end
        return { lines = lines }
    end }
    fire("TRAINER_SHOW") advance(1)
    ns.TrainerTest()
    slash("pintest")
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
    ns.db.recipePending = { Enchanting = { ["Enchant Bracer - Minor Health"] = "1|\nStrange Dust:1;|nSimple Wood:1" } }
    ns.ResolvePending()
    assert(ns.db.recipeDB.Enchanting["Enchant Bracer - Minor Health"] == "0:1:1:1|10940:1,4470:1", "shipped names " .. tostring(ns.db.recipeDB.Enchanting["Enchant Bracer - Minor Health"]))
end)
step("Crafting: shipped data back", function()
    GathercraftRecipeData = savedShipped
    assert(#ns.CraftAdvice("Tailoring") > 50, "tailoring rows")
end)
if GERMAN then
step("German: gathering spell under an unknown ID, confirmed by the object", function()
    player.x, player.y = 0.5, 0.5
    fire("UNIT_SPELLCAST_SENT", "player", "Friedensblume", "castDE", 999001)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "castDE", 999001)
    loot = { { guid = "GameObject-0-1-1-1-1618-DDDD11", item = 2447, qty = 2 } }
    fire("LOOT_READY") advance(3)
    assert(ns.db.gatherSpells and ns.db.gatherSpells[999001] == "herb", "unknown gather spell not learned")
    -- a mob kill with a name must not become a node
    fire("UNIT_SPELLCAST_SENT", "player", "Eber", "castDE2", 999002)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "castDE2", 999002)
    loot = { { guid = "Creature-0-1-1-1-3099-EEEE", item = 769, qty = 1 } }
    fire("LOOT_READY") advance(3)
    assert(not ns.db.gatherSpells[999002], "mob spell learned as gathering")
end)
step("German: profession window, trainer and recipe names", function()
    -- German profession window: Schneiderei, recipe in German, product 4307
    local oldLine, oldNum, oldInfo, oldLink, oldNR, oldRI, oldRL, oldMade = GetTradeSkillLine, GetNumTradeSkills,
        GetTradeSkillInfo, GetTradeSkillItemLink, GetTradeSkillNumReagents, GetTradeSkillReagentInfo, GetTradeSkillReagentItemLink, GetTradeSkillNumMade
    GetTradeSkillLine = function() return "Schneiderei", 50, 75 end
    GetNumTradeSkills = function() return 1 end
    GetTradeSkillInfo = function() return "Schwere Leinenhandschuhe", "easy" end
    GetTradeSkillItemLink = function() return "|Hitem:4307::|h" end
    GetTradeSkillNumReagents = function() return 1 end
    GetTradeSkillReagentInfo = function() return "Leinenstoffballen", nil, 2 end
    GetTradeSkillReagentItemLink = function() return "|Hitem:2996::|h" end
    GetTradeSkillNumMade = function() return 1, 1 end
    fire("TRADE_SKILL_SHOW") advance(2)
    local mine = ns.db.recipes[next(ns.db.recipes)]
    local keys = {} for k, v in pairs(mine) do local ns_ = {} for n in pairs(v.list or {}) do ns_[#ns_ + 1] = n end keys[#keys + 1] = k .. "=" .. table.concat(ns_, "/") end
    assert(mine.Tailoring and mine.Tailoring.list["Heavy Linen Gloves"], "German window not stored under English names: " .. table.concat(keys, "; "))
    assert(not mine.Schneiderei, "German profession key left behind")
    local rows = ns.CraftAdvice("Tailoring")
    local found
    for _, r in ipairs(rows) do if r.key == "Heavy Linen Gloves" then found = r end end
    assert(found and found.learned and found.name == "Schwere Leinenhandschuhe", "learned row: " .. tostring(found and found.name))
    -- German trainer: enchant with tooltip reagents
    GetNumTrainerServices = function() return 1 end
    GetTrainerServiceInfo = function() return "Brust - Schwache Ausdauer", nil, "available" end
    GetTrainerServiceItemLink = function() return nil end
    GetTrainerServiceSkillReq = function() return "Verzauberkunst", 15, true end
    GetTrainerServiceNumReagents = nil
    C_TooltipInfo = { GetTrainerService = function()
        local lines = {}
        for _, x in ipairs({ "Verzauberkunst: Brust - Schwache Ausdauer", "", "Reagenzien: |nSeltsamer Staub" }) do lines[#lines + 1] = { leftText = x } end
        return { lines = lines }
    end }
    ns.NoteItemName("Seltsamer Staub", 10940)
    fire("TRAINER_SHOW") advance(1)
    local e = ns.db.recipeDB.Enchanting and ns.db.recipeDB.Enchanting["Enchant Chest - Inferior Stamina"]
    assert(e and e:find("^0:1:1:15|10940:1"), "German trainer: " .. tostring(e))
    assert(not ns.db.recipeDB.Verzauberkunst, "German profession key in recipe book")
    C_TooltipInfo = nil
    GetTradeSkillLine, GetNumTradeSkills, GetTradeSkillInfo, GetTradeSkillItemLink, GetTradeSkillNumReagents,
        GetTradeSkillReagentInfo, GetTradeSkillReagentItemLink, GetTradeSkillNumMade = oldLine, oldNum, oldInfo, oldLink, oldNR, oldRI, oldRL, oldMade
    ns.db.craftTab = "Enchanting" ns.ToggleMain("craft") advance(1) ns.HideMain()
end)
end
step("Crafting: where to learn a recipe (tooltip)", function()
    local src = GathercraftRecipeSources
    assert(src and src.trainer and src.scroll and src.items and src.npcs, "recipe sources not loaded")
    ns.ToggleMain("craft") advance(1)
    GameTooltip.AddDoubleLine = function(_, l, r) note("TT2", l, "=", r) end
    local before = #log
    local tried = 0
    for _, f in ipairs(allFrames) do
        local r = f.data
        if r and r.prof and r.key and not r.learned and f.__scripts and f.__scripts.OnEnter and tried < 40 then
            f.__scripts.OnEnter(f)
            if f.__scripts.OnLeave then f.__scripts.OnLeave(f) end
            tried = tried + 1
        end
    end
    local learnAt, item = 0, 0
    for i = before + 1, #log do
        if log[i]:find(ns.L["Learn at"], 1, true) then learnAt = learnAt + 1 end
        if log[i]:find(ns.L["Recipe item"], 1, true) then item = item + 1 end
    end
    note("recipe sources: rows", tried, "trainer lines", learnAt, "recipe item lines", item)
    assert(tried > 0 and learnAt + item > 0, "no recipe source lines in " .. tried .. " tooltips")
    ns.HideMain()
end)
step("Language: switch to German and back", function()
    ns.db.language = "deDE" ns.ApplyLanguage()
    local de
    for _, n in ipairs(ns.db.nodes[1412]) do if n.id == "o1618" then de = n.name end end
    assert(de == "Friedensblume", "node name in German: " .. tostring(de))
    assert(ns.L["Overview"] == "Overview" and ns.L["Show route line"] == "Routenlinie zeigen", "German not active")
    ns.ToggleMain("options") advance(1) ns.ToggleMain("craft") advance(1) ns.HideMain()
    slash("stats")
    ns.db.language = "auto" ns.ApplyLanguage()
    local loc = ({ esMX = "esES", enGB = "enUS" })[LOCALE] or LOCALE
    assert(ns.L["Show route line"] == ((ns.Locales[loc] or {})["Show route line"] or "Show route line"), "auto language")
end)
step("Language: every language, every page", function()
    for _, lang in ipairs(ns.LANGUAGES) do
        ns.db.language = lang.code ns.ApplyLanguage()
        for _, tab in ipairs({ "overview", "farm", "craft", "zones", "skills", "options" }) do ns.ToggleMain(tab) advance(1) end
        ns.HideMain()
        slash("stats") slash("list") slash("sync") slash("skills")
        if ns.Money then ns.Money(123456) ns.Money(-77) end
    end
    ns.db.language = "auto" ns.ApplyLanguage()
end)
step("Merchant with the newer API only (C_MerchantFrame)", function()
    local old = GetMerchantItemInfo
    GetMerchantItemInfo = nil
    C_MerchantFrame = { GetItemInfo = function(i)
        return { name = "Coarse Thread", price = 10, stackCount = 1, numAvailable = -1, hasExtendedCost = false }
    end }
    GetMerchantNumItems = function() return 1 end
    GetMerchantItemLink = function() return "|Hitem:2320::|h" end
    ns.db.vendorPrices[2320] = nil
    fire("MERCHANT_SHOW") advance(2)
    assert(ns.db.vendorPrices[2320] == 10, "vendor price via C_MerchantFrame: " .. tostring(ns.db.vendorPrices[2320]))
    GetMerchantItemInfo, C_MerchantFrame = old, nil
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
    -- and one with learned hits and misses (spawn point learning)
    local learned
    for _, n in ipairs(ns.db.nodes[1413] or {}) do
        if n.source == "questie" and n ~= resting then learned = n break end
    end
    learned.hits, learned.misses, learned.emptyAt = 3, 5, time() - 60
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
    local again, found, learnedBack = 0, false, false
    for _, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            if n.source == "questie" then
                again = again + 1
                if n.sk == resting.sk and n.emptyStreak == 2 and n.emptyUntil then found = true end
                if n.sk == learned.sk then
                    assert(n.hits == 3 and n.misses == 5 and n.emptyAt, "learned spawn point lost")
                    learnedBack = true
                end
            end
        end
    end
    note("slim: spawn points after login", again, "resting state back", found)
    assert(again > 1000 and found and learnedBack, "spawn points or resting state not restored")
end)
step("Zones in two columns, Farm Spots continent tabs", function()
    local zscroll = _G.GathercraftZonesScroll
    assert(zscroll, "zones scroll frame not global")
    zscroll:SetWidth(700) -- the size it has in the main window
    ns.ImportQuestieZone(1421, true) -- a second continent (Silverpine Forest)
    ns.ToggleMain("zones") advance(1)
    ns.ToggleMain("farm") advance(1)
    for _, mode in ipairs({ "herb", "ore", "both" }) do
        ns.db.advisorMode = mode
        ns.ToggleMain("overview") ns.ToggleMain("farm") advance(1)
    end
    ns.HideMain()
    zscroll:SetWidth(300) -- narrow: one column
    ns.ToggleMain("zones") advance(1)
    ns.HideMain()
end)
step("Delete + wipe zone", function() slash("del") slash("wipe zone") advance(1) end)
step("Long run (10 min) for leaks", function() slash("run herb") advance(600) slash("stop") end)

io.write("\n--- errors: " .. #errors .. "\n")
for _, e in ipairs(errors) do io.write("  " .. e .. "\n") end
io.write("\n--- notable log lines:\n")
for _, l in ipairs(log) do
    if l:find("questie nodes") or l:find("grey pins") or l:find("recipe sources") or l:find("route line") or l:find("route goal") or l:find("fish next") or l:find("SOUNDFILE") or l:find("RAIDWARN") or l:find("sync sent") or l:find("empty test") or l:find("prices ok") or l:find("scan price") or l:find("TTPRICE") or l:find("advisor") or l:find("target changes") or l:find("JUMP") or l:find("harvest cost") or l:find("slim:") or l:find("learned prices") or l:find("fishing session") or l:find("recipe item") or l:find("craft ") or l:find("recipes") or l:find("profit") or l:find("Price alert") or l:find("scanned") or l:find("Own scan") or l:find("15 minutes") or l:find("shared spawn") or l:find("Shared spawn") or l:find("Loaded") or l:find("took over") or l:find("RECORD") or l:find("No ") or l:find("rror") then
        io.write("  " .. l:sub(1, 160) .. "\n")
    end
end
