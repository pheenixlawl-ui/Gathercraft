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
function methods:EnableMouse(on) self.__mouse = on and true or false end
function methods:IsMouseEnabled() return self.__mouse ~= false end
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
function methods:SetPoint(p, ...) if p then self.__pts = self.__pts or {} self.__pts[p] = { ... } end end -- last anchor per point
function methods:GetStringHeight() return self.__strH end
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
function methods:SetVertexColor(r, g, b) self.__color = { r, g, b } end
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
HBD_ADDS, HBD_FLOAT, MINI_ICONS, LINE_PTS, MINI_PTS = {}, {}, {}, {}, {}
libs["HereBeDragons-Pins-2.0"] = {
    AddWorldMapIconMap = function(_, ref) pinCount = pinCount + 1 PIN_ADDS = (PIN_ADDS or 0) + 1
        HBD_ADDS[ref] = HBD_ADDS[ref] or { world = 0, mini = 0 } HBD_ADDS[ref].world = HBD_ADDS[ref].world + 1 end,
    AddMinimapIconMap = function(_, ref, icon, map, x, y, parent, float) pinCount = pinCount + 1
        HBD_ADDS[ref] = HBD_ADDS[ref] or { world = 0, mini = 0 } HBD_ADDS[ref].mini = HBD_ADDS[ref].mini + 1
        HBD_FLOAT[ref] = float if ref == "Gathercraft" then MINI_ICONS[#MINI_ICONS + 1] = icon end end,
    AddWorldMapIconWorld = function(_, ref, icon, inst, x, y) LINE_DOTS = (LINE_DOTS or 0) + 1 LINE_PTS[#LINE_PTS + 1] = { x, y } end,
    AddMinimapIconWorld = function(_, ref, icon, inst, x, y) HBD_ADDS[ref] = HBD_ADDS[ref] or { world = 0, mini = 0 } HBD_ADDS[ref].mini = HBD_ADDS[ref].mini + 1
        if x then MINI_PTS[#MINI_PTS + 1] = { x, y } end end,
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
            -- by object: the name follows the chosen language
            if n.id == "o1619" and math.abs(n.x - x) < 0.002 and math.abs(n.y - y) < 0.002 then c = c + 1 end
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
    local target, mark = ns.run.target, #log
    slash("skip") advance(2)
    -- skip learns nothing: it says "left out", not "marked empty"
    local want = (ns.L["%s left out for %d min."]):format(target.name, 5)
    if LOCALE == "enUS" then assert(want == target.name .. " left out for 5 min.", "English skip text: " .. want) end
    if LOCALE == "deDE" then assert(want == target.name .. " für 5 Min. ausgelassen.", "German skip text: " .. want) end
    local said
    for i = mark + 1, #log do
        if log[i]:find(want, 1, true) then said = true end
        assert(not log[i]:find("marked empty", 1, true), "the old skip text: " .. log[i])
    end
    assert(said, "skip did not say: " .. want)
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
        assert(LINE_DOTS > 0 and LINE_DOTS <= 1220, "route dots for " .. st.code .. ": " .. LINE_DOTS)
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
            -- silver, or white in the trainer colour (Leveling)
            assert(pin.ring and pin.ring:IsShown() and (tostring(pin.ring.__tex):find("RingSilver")
                or (pin.level and tostring(pin.ring.__tex):find("RingWhite"))), "no silver ring")
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
step("Route line: dense around you on the minimap, even all along on the map", function()
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
    LINE_PTS, MINI_PTS, LINE_DOTS = {}, {}, 0
    ns.RedrawRouteLine()
    local pxw, pyw = player.x * 5000 + (Z - 1400) * 6000, player.y * 3333
    local function Gaps(pts, within)
        local count, worst = 0, 0
        for i, a in ipairs(pts) do
            if not within or math.sqrt((a[1] - pxw) ^ 2 + (a[2] - pyw) ^ 2) < within then
                count = count + 1
                local best = math.huge
                for j, b in ipairs(pts) do
                    if i ~= j then best = math.min(best, math.sqrt((a[1] - b[1]) ^ 2 + (a[2] - b[2]) ^ 2)) end
                end
                worst = math.max(worst, best)
            end
        end
        return count, worst
    end
    -- minimap: dense around you
    local near, worstNear = Gaps(MINI_PTS, 450)
    note("route line minimap dots near you", near, "worst gap", worstNear)
    assert(near > 50 and worstNear <= 8, ("minimap line not dense around you: %d dots, gap %.1f yd"):format(near, worstNear))
    for _, a in ipairs(MINI_PTS) do
        assert(math.sqrt((a[1] - pxw) ^ 2 + (a[2] - pyw) ^ 2) <= 601, "minimap dot far away from you")
    end
    -- world map: the same spacing all the way, also at the far end
    local all, worst = Gaps(LINE_PTS)
    note("route line world dots", all, "worst gap", worst)
    assert(worst <= 13, ("world map line falls apart: gap %.1f yd"):format(worst))
    assert(LINE_DOTS <= 1220, "too many dots: " .. LINE_DOTS)
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
    -- skipped (a cliff, a mob in the way): out of the run for a while, but
    -- nothing learned and no self-healing
    aim(C)
    local restBefore = C.emptyUntil
    C.emptyUntil = nil
    local chance = ns.NodeChance(C)
    C.emptyUntil = restBefore
    slash("skip") advance(1)
    assert(not C.misses and not C.emptyStreak and not C.emptyAt, "skip learned 'empty'")
    assert(heals == 1, "skip counted for self-healing")
    assert(ns.run.visited[C] and C.emptyUntil and C.emptyUntil >= time() + 299 - 1, "skipped node not out of the run for 5 min")
    assert(ns.run.target ~= C, "still pointing at the skipped node")
    -- once its time out is over, its chance is what it was
    local wasUntil = C.emptyUntil
    C.emptyUntil = nil
    assert(math.abs(ns.NodeChance(C) - chance) < 1e-9, "skip changed the node's chance")
    C.emptyUntil = wasUntil
    ns.StopRun()
    ns.SyncSelfHeal = realHeal
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Farm run: the line to the next node follows you", function()
    local Z = 1469
    local function own(x, y) return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = y, count = 3, last = 1 } end
    ns.db.nodes[Z] = { own(0.30, 0.50), own(0.40, 0.55), own(0.50, 0.45), own(0.60, 0.55) }
    player.map, player.x, player.y = Z, 0.25, 0.50
    ns.StartRun("ore", Z) advance(1)
    assert(ns.run and ns.run.path, "no run")
    -- the part from you to the next node is drawn again as you move, often
    local ref = "GathercraftRouteHead"
    HBD_ADDS[ref] = { world = 0, mini = 0 }
    for i = 1, 10 do player.x = player.x + 0.001 advance(0.2) end
    assert(HBD_ADDS[ref].mini >= 10, "line to the next node not kept up: " .. HBD_ADDS[ref].mini)
    -- standing still: not drawn again
    local before = HBD_ADDS[ref].mini
    advance(2)
    assert(HBD_ADDS[ref].mini == before, "line redrawn while standing still")
    ns.StopRun()
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Farm run: Loop rides a fixed round, new spots go in on the way", function()
    local Z = 1467
    -- 8 veins on a circle: the round must go round the circle
    local nodes = {}
    for i = 1, 8 do
        local a = (i - 1) * math.pi / 4
        nodes[i] = { id = "o1731", name = "Copper Vein", type = "ore", x = 0.5 + 0.2 * math.cos(a),
            y = 0.5 + 0.2 * math.sin(a), count = 3, last = 1 }
    end
    ns.db.nodes[Z] = { unpack(nodes) }
    local circle = {}
    for i, n in ipairs(nodes) do circle[n] = i end
    ns.db.routeMode = "loop"
    player.map, player.x, player.y = Z, 0.72, 0.52
    ns.StartRun("ore", Z) advance(1)
    local run = ns.run
    assert(run and run.loopMode and run.loop and #run.loop == 8, "no loop")
    for i, node in ipairs(run.loop) do
        local d = (circle[run.loop[i % 8 + 1]] - circle[node]) % 8
        assert(d == 1 or d == 7, "the round cuts across the circle")
    end
    assert(#run.path == 8, "the line does not show the whole round")
    -- ride it: always the next one in the same direction, a full round = round 2
    local seen, dir = {}, nil
    for k = 1, 8 do
        local t = run.target
        assert(t, "no target on the round")
        seen[#seen + 1] = circle[t]
        player.x, player.y = t.x, t.y
        advance(1)
        ns.OnHarvested(t, "LOOP" .. k)
        advance(1)
    end
    for k = 2, #seen do
        local d = (seen[k] - seen[k - 1]) % 8
        dir = dir or d
        assert(d == dir and (d == 1 or d == 7), "the round changed direction or skipped: " .. table.concat(seen, ","))
    end
    assert(run.round == 2, "a full round did not start round 2: " .. run.round)
    -- a new spot between two neighbours goes in right there
    local a, b = run.loop[3], run.loop[4]
    local new = { id = "o1731", name = "Copper Vein", type = "ore", x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, count = 1, last = 1 }
    table.insert(ns.db.nodes[Z], new)
    for _, f in ipairs(ns.nodeListeners) do f("add", Z, new) end
    advance(1)
    assert(#run.loop == 9, "new spot not in the round")
    assert(run.loopIndex[new] == run.loopIndex[a] + 1 and run.loopIndex[b] == run.loopIndex[new] + 1,
        "new spot not put in on the way")
    -- a spot far off the round stays out (it would stretch the round across the map)
    local far = { id = "o1731", name = "Copper Vein", type = "ore", x = 0.97, y = 0.03, count = 1, last = 1 }
    table.insert(ns.db.nodes[Z], far)
    for _, f in ipairs(ns.nodeListeners) do f("add", Z, far) end
    advance(1)
    assert(#run.loop == 9 and not run.loopIndex[far], "a far spot was pulled into the round")
    -- after a detour (a quest far away) the round goes on, not back
    advance(30) -- the veins just reached are checked by now
    for _, f in ipairs(ns.nodeListeners) do f("update", Z) end
    advance(1)
    local pos = run.loopPos
    -- off to a quest right next to the spot before the last one: that one is
    -- the nearest, but it was passed already
    local behind = run.loop[(pos - 2) % #run.loop + 1]
    player.x, player.y = 0.5 + (behind.x - 0.5) * 1.15, 0.5 + (behind.y - 0.5) * 1.15
    advance(2)
    assert(run.target, "no target after the detour")
    assert((run.loopIndex[run.target] - pos) % #run.loop <= 3, "after the detour the round went back")
    -- back to Smart during the run
    ns.db.routeMode = nil
    ns.RouteModeChanged() advance(1)
    assert(ns.run and not ns.run.loopMode and ns.run.path, "switching to Smart broke the run")
    ns.StopRun()
    -- the preview shows the closed round
    ns.db.routeMode = "loop"
    player.x, player.y = 0.72, 0.52
    ns.PreviewRoute("ore") advance(1)
    ns.PreviewRoute("") advance(1)
    ns.db.routeMode = nil
    ns.db.nodes[Z] = nil
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Farm run: Loop gets shorter where spots come back fast, longer where not (v0.1.13)", function()
    local Z = 1467
    local keep = ns.db.nodes[Z]
    local function vein(x, y) return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = y, count = 3, last = 1 } end
    ns.db.nodes[Z] = {}
    -- a dense patch of 24 veins, 12 lonely ones on a wide circle around it
    for i = 0, 23 do table.insert(ns.db.nodes[Z], vein(0.42 + (i % 6) * 0.03, 0.42 + math.floor(i / 6) * 0.03)) end
    for i = 1, 12 do
        local a = i * math.pi / 6
        table.insert(ns.db.nodes[Z], vein(0.5 + 0.4 * math.cos(a), 0.5 + 0.4 * math.sin(a)))
    end
    ns.db.loopShort = nil
    ns.db.routeMode = "loop"
    player.map, player.x, player.y = Z, 0.45, 0.45
    ns.StartRun("ore", Z) advance(1)
    local run = ns.run
    assert(run and run.loopN0 == 36 and run.loopSize == 36, "loop not built with all 36 points")
    -- many players: a pass finds a node one time in five, after 3 minutes as after 30
    local rev = {}
    for i = 1, 60 do rev[i] = { t = (i % 2 == 0) and 180 or 1800, hit = i % 5 == 0 } end
    run.loopStats.rev = rev
    run.adaptAt = 0
    for i in ipairs(log) do log[i] = "" end
    advance(1)
    assert(run.loopSize < 36, "the round did not get shorter: " .. run.loopSize)
    for _, node in ipairs(run.loop) do
        assert(math.abs(node.x - 0.5) < 0.2 and math.abs(node.y - 0.5) < 0.2, "a lonely point stayed in the shorter round")
    end
    local said = false
    local want = (ns.L["Loop: spots come back fast here (many players?) - shorter round through the dense part: %d of %d spawn points."]):format(run.loopSize, 36)
    for _, l in ipairs(log) do if l:find(want, 1, true) then said = true end end
    assert(said, "no word about the shorter round")
    assert(ns.db.loopShort and ns.db.loopShort[Z .. ":ore"], "shorter round not remembered for the zone")
    assert(run.target and run.loopIndex[run.target], "the target is not on the new round")
    -- farming alone: right after a pass nothing, long after it often
    rev = {}
    for i = 1, 60 do
        local long = i % 2 == 0
        rev[i] = { t = long and 3600 or 180, hit = long and i % 4 == 0 }
    end
    run.loopStats.rev = rev
    run.adaptAt = 0
    advance(1)
    assert(run.loopSize == 36, "the round did not grow back: " .. run.loopSize)
    assert(not ns.db.loopShort[Z .. ":ore"], "the full round should forget the shorter one")
    ns.StopRun(true)
    -- a busy zone a short while ago: the next run starts shorter
    ns.db.loopShort[Z .. ":ore"] = { share = 0.5, at = time() }
    ns.db.loopShort[Z .. ":herb"] = { share = 0.4, at = time() - 4 * 3600 } -- too old, and herbs
    ns.StartRun("ore", Z) advance(1)
    assert(ns.run and ns.run.loopSize == 18, "remembered round size not used: " .. tostring(ns.run and ns.run.loopSize))
    -- the shorter round all harvested a moment ago: the whole round meanwhile
    local short = {}
    for _, node in ipairs(ns.run.loop) do
        node.emptyUntil = time() + 600
        short[node] = true
    end
    ns.run.target = nil
    advance(6)
    assert(ns.run.target and not short[ns.run.target] and ns.run.loopSize == 18,
        "nothing to ride to while the shorter round respawns, or the round changed")
    for node in pairs(short) do node.emptyUntil = nil end
    ns.StopRun(true)
    ns.db.loopShort, ns.db.routeMode = nil, nil
    ns.db.nodes[Z] = keep
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
step("Farm run: questing or a stop is not 'hard to reach' (v0.1.12)", function()
    local keep1412 = ns.db.nodes[1412]
    local function silver() return { id = "o1617", name = "Silverleaf", type = "herb", x = 0.56, y = 0.50, count = 3, last = 1 } end
    -- walking crosswise with the run on (a quest): never 'hard to reach'
    ns.db.nodes[1412] = { silver() }
    local node = ns.db.nodes[1412][1]
    ns.NotifyNodesChanged()
    player.map, player.x, player.y = 1412, 0.50, 0.50
    advance(1) slash("run herb") advance(1)
    assert(ns.run and ns.run.target == node, "test setup: target")
    for i = 1, 60 do player.y = player.y - 3.5 / 3333 advance(0.5) end
    assert(not node.unreachUntil, "walking crosswise marked the node unreachable")
    ns.StopRun()
    -- riding towards it, a long stop (mailbox), then around a building
    ns.db.nodes[1412] = { silver() }
    node = ns.db.nodes[1412][1]
    ns.NotifyNodesChanged()
    player.x, player.y = 0.50, 0.50
    slash("run herb") advance(1)
    for i = 1, 20 do player.x = player.x + 5 / 5000 advance(0.5) end
    advance(30)
    for i = 1, 12 do player.y = player.y - 3.75 / 3333 advance(0.5) end
    assert(not node.unreachUntil, "standing still counted towards 'hard to reach'")
    ns.StopRun()
    -- the count starts over after a long time reachable
    node.reachMiss, node.unreachUntil = 3, time() - 2 * 24 * 3600
    ns.MarkUnreachable(node)
    assert(node.reachMiss == 1, "old 'hard to reach' count kept")
    ns.db.nodes[1412] = keep1412
    ns.NotifyNodesChanged()
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Minimap guesses: object IDs, neighbours on cooldown, parked nodes (v0.1.12)", function()
    local keep1412 = ns.db.nodes[1412]
    -- a guess gets one of Peacebloom's object IDs; the harvest is another one
    ns.db.nodes[1450] = {}
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    player.map, player.x, player.y = 1450, 0.50, 0.50
    ns.SeenOnMinimap(1450, 0.50 + 12 / 5000, 0.50, "Peacebloom", 20)
    local seen = ns.db.nodes[1450][1]
    assert(seen and seen.seenOnly, "test setup: no guess")
    seen.id = "o3724"
    fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "c1", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c1", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1618-BBBB22", item = 2447, qty = 2 } }
    fire("LOOT_READY") fire("LOOT_OPENED") advance(3)
    loot = {}
    assert(#ns.db.nodes[1450] == 1, "guess and harvest with another object ID stayed two nodes")
    assert(ns.db.nodes[1450][1].id == "o1618" and not ns.db.nodes[1450][1].seenOnly, "harvest did not take over the guess")
    -- two herbs 20 yd apart, one harvested a moment ago: a look between them is the other one
    local A = { id = "o1617", name = "Silverleaf", type = "herb", x = 0.40, y = 0.50, count = 3, last = 1 }
    local B = { id = "o1617", name = "Silverleaf", type = "herb", x = 0.40 + 20 / 5000, y = 0.50, count = 3, last = 1 }
    ns.db.nodes[1412] = { A, B }
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    A.emptyUntil = time() + 290
    ns.SeenOnMinimap(1412, B.x - 12 / 5000, 0.50, "Silverleaf", 33)
    assert(B.upAt and not A.upAt, "the look went to the node harvested a moment ago")
    -- a parked shared node you see on the minimap is real: back in the routes
    local P = { id = "o1617", name = "Silverleaf", type = "herb", x = 0.70, y = 0.50, count = 0, last = 1,
        source = "sync", parked = time(), healMisses = 5 }
    ns.db.nodes[1412] = { P }
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    assert(ns.IsParked(P), "test setup: parked")
    ns.SeenOnMinimap(1412, 0.70, 0.50, "Silverleaf", 20)
    assert(not ns.IsParked(P) and P.upAt, "seen on the minimap but still parked")
    ns.db.nodes[1412], ns.db.nodes[1450] = keep1412, nil
    ns.NotifyNodesChanged()
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
    -- what we know shows in a tooltip of our own, below the game's (v0.1.12)
    local tip = GathercraftMinimapTooltip
    assert(tip and tip:IsShown() and tip.node == vein and tip.anchor == GameTooltip, "no tooltip of ours below the game's")
    -- our minimap pins let the mouse through; where the game shows nothing,
    -- the pin under the cursor shows our tooltip
    fire("ZONE_CHANGED_NEW_AREA") advance(1) -- minimap pins for this zone
    local vpin
    for _, f in ipairs(allFrames) do if f.node == vein and f.isMini and not f.isTarget then vpin = f end end
    assert(vpin, "no minimap pin for the vein")
    assert(vpin.__mouse == false, "minimap pin still catches the mouse")
    lines = {}
    vpin:Show() -- HereBeDragons shows minimap pins in range (not the mock)
    vpin.IsMouseOver = function() return true end
    advance(0.5)
    assert(tip:IsShown() and tip.node == vein and tip.anchor == vpin, "no tooltip of our own where the game shows none")
    -- the game shows a quest area's tooltip there: ours goes below it
    -- (the quest tooltip comes first, then the cursor reaches the pin: ours
    -- right away, not only after the game's tooltip was measured)
    vpin.IsMouseOver = function() return false end
    lines = { "Restocking the Larders", "- 1/3 Small Egg" }
    advance(0.15)
    vpin.IsMouseOver = function() return true end
    advance(0.2)
    assert(tip:IsShown() and tip.node == vein and tip.anchor == GameTooltip, "nothing of ours below the game's quest tooltip")
    -- several blips in one line ("|n"): each name counts
    lines = { "Restocking the Larders|n" .. veinName }
    vpin.IsMouseOver = function() return false end
    advance(0.5)
    assert(tip:IsShown() and tip.node == vein, "a name after |n not found")
    lines = {}
    advance(0.5)
    assert(not tip:IsShown(), "our tooltip stays after leaving the pin")
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
    for i = sent + 1, #sentMessages do -- a zone query on the way is fine, a shared node is not
        assert(sentMessages[i]:sub(1, 2) == "Q:", "a node only seen on the minimap was shared")
    end
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
step("Sync: a run through another zone asks for that zone too (v0.1.13)", function()
    slash("sync on")
    local Z = 1469
    ns.db.nodes[Z] = { { id = "o1731", name = "Copper Vein", type = "ore", x = 0.4, y = 0.5, count = 3, last = 1 } }
    player.map, player.x, player.y = 1412, 0.45, 0.72
    local function asked()
        local n = 0
        for _, m in ipairs(sentMessages) do if m:find("^Q:" .. Z .. ":") then n = n + 1 end end
        return n
    end
    local before = asked()
    ns.StartRun("ore", Z) advance(1)
    assert(asked() == before, "asked right away (should wait a moment)")
    advance(40)
    ns.StopRun(true)
    assert(asked() > before, "the route's zone was not asked for")
    -- the same run again a minute later: not asked again
    local once = asked()
    ns.StartRun("ore", Z) advance(45)
    ns.StopRun(true)
    assert(asked() == once, "asked for the zone again right away")
    ns.db.nodes[Z] = nil
end)
step("Sync: floods are cut off (v0.1.12)", function()
    slash("sync on")
    local function msg(text, who) fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", who, nil, nil, nil, "GathercraftSync") end
    -- one player asking for the same zone again and again: answered once, and briefly
    local list = {}
    for i = 1, 400 do list[i] = { id = "o99" .. (1000 + i), name = "X", type = "herb", x = (i % 20) / 20 + 0.01, y = math.floor(i / 20) / 21 + 0.01, count = 1, last = 1, item = 2447 } end
    ns.db.nodes[1450] = list
    local before = #sentMessages
    for i = 1, 20 do msg("Q:1450:0", "Spammer-Realm") advance(9) end
    advance(120)
    local answers = 0
    for i = before + 1, #sentMessages do if sentMessages[i]:find("^N:1450;") then answers = answers + 1 end end
    note("answers to 20 queries", answers)
    assert(answers > 0, "no answer at all")
    assert(answers <= 20, "20 queries caused " .. answers .. " messages")
    ns.db.nodes[1450] = nil
    -- broken numbers are ignored
    local pending = ns.db.sync.pending
    msg("N:2521.5;o990101,h,5000,5000,2447", "Stranger Two")
    msg("N:2521;o990102,h,5000,5000,99999999999999999999", "Stranger Two")
    for _, p in ipairs(pending[2521] or {}) do
        assert(p.id ~= "o990101" and p.id ~= "o990102", "broken report kept: " .. p.id)
    end
    -- one stranger can't fill the reports of all zones
    local saved = ns.db.sync.pending
    ns.db.sync.pending = {}
    for i = 1, 100 do
        ns.db.sync.pending[3000 + i] = { { id = "o9" .. i, type = "herb", x = 0.5, y = 0.5, item = 0,
            reporters = { ["Flooder-Realm"] = true }, rc = 1, first = time(), by = "Flooder-Realm" } }
    end
    msg("N:2522;o990777,h,4000,4000,2447", "Flooder-Realm")
    assert(not ns.db.sync.pending[2522] or #ns.db.sync.pending[2522] == 0, "flooder got past the limit")
    msg("N:2522;o990778,h,4100,4100,2447", "Honest Player")
    assert(ns.db.sync.pending[2522] and #ns.db.sync.pending[2522] == 1, "an honest report was refused")
    ns.db.sync.pending = saved
    -- self-healing: a first empty visit long ago doesn't count any more
    local n = { id = "o1731", name = "Copper Vein", type = "ore", x = 0.3, y = 0.3, count = 1, last = 1, source = "sync", heard = 1,
        healFirst = time() - 7 * 24 * 3600, healAt = time() - 4 * 24 * 3600, healMisses = 4 }
    ns.SyncSelfHeal(n)
    assert(n.healMisses == 1 and not ns.IsParked(n), "old empty visits still counted")
    advance(5)
end)
step("Leveling: pin rings in the trainer colour for your skill (v0.1.14)", function()
    local Z = 1449
    local keep = ns.db.nodes[Z]
    local herb, ore, herbMax = PROFS[1][2], PROFS[2][2], PROFS[1][3]
    PROFS[1][3] = 300 -- skills up to 150 below: trained far enough (the rank cap is tested further down)
    local function N(id, name, x, kind, src)
        return { id = id, name = name, type = kind or "herb", x = x, y = 0.5, count = 1, last = 1, source = src }
    end
    local peace, earth, mage, briar, bruise, odd =
        N("o1618", "Peacebloom", 0.1), N("o1619", "Earthroot", 0.2), N("o1620", "Mageroyal", 0.3),
        N("o1621", "Briarthorn", 0.4), N("o1622", "Bruiseweed", 0.5), N("o999999", "Mystery Bloom", 0.6)
    -- a known spot where Copper or Tin can be
    local copper, tin = N("o1731", "Copper Vein", 0.7, "ore", "questie"), N("o1732", "Tin Vein", 0.7, "ore", "questie")
    ns.db.nodes[Z] = { peace, earth, mage, briar, bruise, odd, copper, tin }
    local pins = LibStub("HereBeDragons-Pins-2.0")
    local add = pins.AddWorldMapIconMap
    local pinOf = {}
    pins.AddWorldMapIconMap = function(self, ref, frame, mapID, ...)
        if ref == "Gathercraft" and mapID == Z and frame.node then pinOf[frame.node] = frame end
        return add(self, ref, frame, mapID, ...)
    end
    local function Ring(n)
        local pin = pinOf[n]
        assert(pin and pin.node == n, "no pin for " .. n.name)
        local c = pin.ring.__color or { 1, 1, 1 }
        if pin.ring.__tex:find("RingSilver", 1, true) then return "silver" end
        assert(pin.ring.__tex:find("RingWhite", 1, true), "ring texture " .. tostring(pin.ring.__tex))
        for name, t in pairs({ orange = { 1, 0.55, 0.2 }, yellow = { 1, 0.95, 0.2 }, green = { 0.3, 0.95, 0.3 },
            grey = { 0.6, 0.6, 0.6 }, red = { 1, 0.2, 0.2 } }) do
            if math.abs(c[1] - t[1]) + math.abs(c[2] - t[2]) + math.abs(c[3] - t[3]) < 0.01 then return name end
        end
        return "?"
    end
    local function Expect(list)
        for n, want in pairs(list) do
            local got = Ring(n)
            assert(got == want, ("%s: ring %s, expected %s"):format(n.name, got, want))
        end
    end
    -- Herbalism 60, Mining 70
    PROFS[1][2], PROFS[2][2] = 60, 70
    ns.NotifyNodesChanged() advance(2)
    Expect({ [peace] = "green", [earth] = "yellow", [mage] = "orange", [briar] = "red", [bruise] = "red",
        [odd] = "silver", [copper] = "orange" }) -- Copper green, but Tin (orange) can be there too
    -- Tin turns out to be somewhere else: the spot is Copper only, green
    tin.x = 0.9
    for _, f in ipairs(ns.nodeListeners) do f("update", Z, tin) end
    advance(1)
    Expect({ [copper] = "green", [tin] = "orange" })
    -- skill goes up while you gather: the colours follow (same pins, no rebuild)
    local peacePin, before = pinOf[peace], pinOf[peace]:GetAlpha()
    PROFS[1][2] = 130
    advance(4)
    assert(pinOf[peace] == peacePin, "pins were rebuilt for a colour change")
    Expect({ [peace] = "grey", [earth] = "grey", [mage] = "green", [briar] = "green", [bruise] = "yellow" })
    assert(peacePin:GetAlpha() < before, "grey nodes do not step back")
    -- hide grey ones
    ns.db.hideGreyNodes = true
    pinOf = {}
    ns.NotifyNodesChanged() advance(2)
    assert(not pinOf[peace] and not pinOf[earth], "grey nodes still on the map")
    assert(pinOf[mage] and pinOf[bruise] and pinOf[odd], "too many nodes hidden")
    -- a skill-up that makes a node grey: hidden a moment later (not while you loot)
    PROFS[1][2] = 150 -- Mageroyal (50) turns grey
    advance(4)
    pinOf = {}
    advance(6)
    assert(not pinOf[mage] and pinOf[bruise], "Mageroyal not hidden after it turned grey")
    -- at 300 nothing levels you any more: silver rings, nothing hidden
    PROFS[1][2] = 300
    pinOf = {}
    ns.NotifyNodesChanged() advance(2)
    assert(pinOf[peace], "at 300 grey nodes must not be hidden")
    Expect({ [peace] = "silver", [bruise] = "silver" })
    -- colours off
    PROFS[1][2] = 60
    ns.db.hideGreyNodes, ns.db.skillColorsOff = nil, true
    pinOf = {}
    ns.NotifyNodesChanged() advance(2)
    Expect({ [mage] = "silver", [briar] = "silver" })
    ns.db.skillColorsOff = nil
    -- the tooltip says the same as the ring
    assert(select(2, ns.SkillVerdict("herb", "Mageroyal", "o1620")) == ns.L["|cffff8040Skill-up guaranteed|r"], "tooltip verdict changed")
    local function Verdict(n) return select(2, ns.SkillVerdict("herb", n.name, n.id)) end
    -- end of a rank (75/75): nothing gives a point until you train, silver rings
    PROFS[1][2], PROFS[1][3] = 75, 75
    advance(4)
    Expect({ [briar] = "silver", [peace] = "silver", [mage] = "silver" })
    assert(Verdict(briar) == ns.L["|cffffd060No skill-ups until you train the next rank|r"], "75/75 tooltip: " .. Verdict(briar))
    assert(Verdict(bruise) == (ns.L["|cffff5555Needs skill %d|r"]):format(100), "75/75: too high stays red in the tooltip")
    -- trained to 75/150: the colours are back on the same pins
    PROFS[1][3] = 150
    advance(4)
    Expect({ [briar] = "orange", [peace] = "green", [mage] = "yellow" })
    assert(Verdict(briar) == ns.L["|cffff8040Skill-up guaranteed|r"], "75/150 tooltip: " .. Verdict(briar))
    -- hide grey + 150/150: the cap hides nothing extra, Peacebloom (grey by skill) shows silver
    ns.db.hideGreyNodes = true
    PROFS[1][2], PROFS[1][3] = 150, 150
    pinOf = {}
    ns.NotifyNodesChanged() advance(2)
    assert(pinOf[peace] and pinOf[mage], "the rank cap hid nodes")
    Expect({ [peace] = "silver", [briar] = "silver" })
    -- trained to 150/225: grey again, hidden after the delayed rebuild
    PROFS[1][3] = 225
    advance(4)
    pinOf = {}
    advance(6)
    assert(not pinOf[peace] and not pinOf[mage] and pinOf[briar], "grey not hidden again after training")
    Expect({ [briar] = "green" })
    -- Herbalism unlearned (GetProfessions no longer lists it): silver, hidden grey nodes come back
    local gp, gn, gi = GetProfessions, GetNumSkillLines, GetSkillLineInfo
    GetProfessions = function() return nil, 2, nil, 4, nil, nil end
    advance(4)
    pinOf = {}
    advance(6)
    assert(pinOf[peace] and pinOf[mage], "unlearned: grey nodes still hidden")
    Expect({ [peace] = "silver", [briar] = "silver" })
    assert(Verdict(briar) == ns.L["|cffff5555Profession not learned|r"], "unlearned tooltip")
    GetProfessions = gp
    PROFS[1][2], PROFS[1][3] = 130, 150
    advance(10) -- incl. the delayed rebuild (Peacebloom grey again)
    Expect({ [mage] = "green", [briar] = "green" })
    -- old skill list API: a collapsed header keeps the last skill, a real loss does not
    local lines
    GetProfessions = nil
    GetNumSkillLines = function() return #lines end
    GetSkillLineInfo = function(i) return unpack(lines[i]) end
    lines = { { "Professions", true, true }, { "Herbalism", false, nil, 130, 0, 0, 150 } }
    ns.db.hideGreyNodes = nil
    pinOf = {}
    ns.NotifyNodesChanged() advance(2)
    Expect({ [mage] = "green", [briar] = "green" })
    local magePin = pinOf[mage]
    lines = { { "Professions", true, false } } -- header collapsed: Herbalism not listed
    advance(4)
    assert(pinOf[mage] == magePin, "collapsed header rebuilt the pins")
    Expect({ [mage] = "green", [briar] = "green" })
    lines = { { "Professions", true, true } } -- expanded, no Herbalism: unlearned
    advance(4)
    Expect({ [mage] = "silver", [briar] = "silver" })
    GetProfessions, GetNumSkillLines, GetSkillLineInfo = gp, gn, gi
    PROFS[1][3] = herbMax
    pins.AddWorldMapIconMap = add
    PROFS[1][2], PROFS[2][2] = herb, ore
    ns.db.nodes[Z] = keep
    ns.NotifyNodesChanged() advance(2)
end)
step("Options: the Leveling page flows again after a language or width change (v0.1.14)", function()
    -- mock text layout: 5 px per character, wrapped at the page width (no real font metrics)
    local opts = _G.GathercraftOptions
    local function Find(key) -- in the language of this run
        local found
        for _, f in ipairs(allFrames) do
            if f.__kind == "FontString" and f.__text == ns.L[key] then found = f end
        end
        return found
    end
    local colour, remind = Find("Color pins by skill-up chance"),
        Find("Remind me to visit the trainer (5 points before the end of a rank)")
    local hint = Find("Handy while you level - turn it off when you farm for gold.")
    local hide = Find("Hide nodes that give no more skill-ups")
    assert(colour and remind and hint and hide, "Leveling labels not found")
    local page = colour.__parent
    assert(colour.__pts.RIGHT and colour.__pts.RIGHT[1] == page, "checkbox label not limited to the page width")
    local box = colour.__pts.TOPLEFT[1]
    assert(box and box.__kind == "CheckButton", "checkbox label not anchored to its box")
    local remindBox = remind.__pts.TOPLEFT[1]
    local old = methods.GetStringHeight
    local keepLang = ns.db.language
    methods.GetStringHeight = function(self)
        if self.__strH then return self.__strH end
        local w = (self.__parent and self.__parent:GetWidth() or 200) - 30
        local len = #((self.__text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
        return 12 * math.max(1, math.ceil(len * 5 / w))
    end
    local function Y(f) return f.__pts.TOPLEFT[2] end
    page.__w = 470
    opts:Refresh()
    local y1 = Y(remindBox)
    assert(Y(box) == -62, "first row moved")
    -- another language whose texts wrap differently: the rows below move
    local y2
    for _, other in ipairs({ "frFR", "enUS", "esES", "deDE", "itIT", "ptBR" }) do
        ns.db.language = other ns.ApplyLanguage() opts:Refresh()
        y2 = Y(remindBox)
        if y2 ~= y1 then break end
    end
    assert(y2 ~= y1, ("no language moved the trainer row (%s / %s)"):format(y1, y2))
    -- narrower (another window): more lines, the size change alone lays it out again
    page.__w = 300
    page.__scripts.OnSizeChanged(page, 300, 400)
    local y3 = Y(remindBox)
    assert(y3 < y2, ("narrower: trainer row did not move down (%s / %s)"):format(y2, y3))
    -- a checkbox label that wraps to 3 lines pushes the next row down by its height
    hide.__strH = 36
    opts:Refresh()
    local gap = Y(hint) - Y(hide.__pts.TOPLEFT[1])
    assert(gap == -(36 + 12) + 2, "hint under a wrapped label: gap " .. gap)
    hide.__strH = nil
    ns.db.language = keepLang ns.ApplyLanguage()
    methods.GetStringHeight = old
    page.__w = nil
    opts:Refresh()
end)
-- Mock text layout for the layout tests: the real (translated) text, wrapped
-- at the string's width; 6 px per Latin letter, 11 px per CJK sign, 12 px a
-- line. No real font metrics: it shows whether the code makes room, not
-- how the game draws it.
local function TextHeight(self)
    if self.__strH then return self.__strH end
    local t = (self.__text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local w, lines = self:GetWidth(), 0
    for para in (t .. "\n"):gmatch("([^\n]*)\n") do
        local px = 0
        for ch in para:gmatch("[%z\1-\127\194-\244][\128-\191]*") do px = px + (#ch >= 3 and 11 or 6) end
        lines = lines + math.max(1, math.ceil(px / w))
    end
    return 12 * lines
end
-- rows (frames with TOPLEFT y and a height) must not overlap
local function NoOverlap(rows, what)
    table.sort(rows, function(a, b) return a.__pts.TOPLEFT[2] > b.__pts.TOPLEFT[2] end)
    for i = 2, #rows do
        local above, row = rows[i - 1], rows[i]
        assert(row.__pts.TOPLEFT[2] <= above.__pts.TOPLEFT[2] - above.__h,
            ("%s: row %d overlaps the one above (y %s, above y %s h %s)"):format(what, i,
                row.__pts.TOPLEFT[2], above.__pts.TOPLEFT[2], above.__h))
    end
end
step("Overview: rows as high as their texts, in a scroll area (v0.1.14)", function()
    local old, herb = methods.GetStringHeight, { PROFS[1][2], PROFS[1][3] }
    methods.GetStringHeight = TextHeight
    PROFS[1][2], PROFS[1][3] = 75, 75 -- end of a rank: the long trainer verdict
    ns.ToggleMain("overview") advance(3)
    local scroll = _G.GathercraftHereScroll
    assert(scroll, "no scroll area for the zone's nodes")
    local function Rows()
        local rows = {}
        for _, f in ipairs(allFrames) do
            if f.__kind == "Frame" and f.__parent and f.__parent.__parent == scroll and f.__shown and f.__pts then rows[#rows + 1] = f end
        end
        return rows
    end
    local cap = ns.L["|cffffd060No skill-ups until you train the next rank|r"]
    local function Check(what)
        local rows, capped = Rows(), 0
        assert(#rows > 0, what .. ": no rows")
        for _, row in ipairs(rows) do
            local name, info
            for _, f in ipairs(allFrames) do
                if f.__parent == row and f.__kind == "FontString" then
                    if f.__pts.TOPLEFT[1] == row.icon then name = f else info = f end
                end
            end
            assert(name.__w and info.__w and name.__w + 28 <= row.__w, what .. ": texts wider than the row")
            assert(row.__h >= name:GetStringHeight() + info:GetStringHeight(), ("%s: row %s px for %s + %s px of text"):format(
                what, row.__h, name:GetStringHeight(), info:GetStringHeight()))
            if info.__text:find(cap, 1, true) then capped = capped + 1 end
        end
        assert(capped > 0, what .. ": no row with the trainer verdict")
        NoOverlap(rows, what)
        return rows
    end
    Check("overview")
    -- the list ends above the run buttons (they sit 10 px up, 22 px high)
    local br = scroll.__pts.BOTTOMRIGHT
    assert(br and br[4] >= 34, "the list runs into the buttons below")
    -- narrower: more lines, laid out again by the size change alone
    local rowsBefore = Rows()
    local hBefore = 0 for _, r in ipairs(rowsBefore) do hBefore = hBefore + r.__h end
    scroll.__scripts.OnSizeChanged(scroll, 180, 300)
    local hAfter = 0 for _, r in ipairs(Check("narrow")) do hAfter = hAfter + r.__h end
    assert(hAfter > hBefore, "rows did not grow when the area got narrower")
    scroll.__scripts.OnSizeChanged(scroll, 414, 300)
    ns.HideMain()
    methods.GetStringHeight = old
    PROFS[1][2], PROFS[1][3] = herb[1], herb[2]
end)
step("Skills: long names and verdicts stay in their columns (v0.1.14)", function()
    local old, herb = methods.GetStringHeight, { PROFS[1][2], PROFS[1][3] }
    methods.GetStringHeight = TextHeight
    PROFS[1][2], PROFS[1][3] = 75, 75
    local stats = ns.KindStats()
    local added = {
        ["herb:briarthorn"] = { name = "Briarthorn", type = "herb", n = 3, ups = 2, minSkill = 70, maxUp = 74 },
        ["ore:ooze covered rich thorium vein"] = { name = "Ooze Covered Rich Thorium Vein", type = "ore", n = 1, ups = 0, minSkill = 275 },
    }
    for k, s in pairs(added) do stats[k] = s end
    ns.ToggleMain("skills") advance(1)
    local scroll = _G.GathercraftSkillsScroll
    local function Check(what)
        local rows = {}
        for _, f in ipairs(allFrames) do
            if f.__kind == "Frame" and f.__parent and f.__parent.__parent == scroll and f.__shown and f.__pts then rows[#rows + 1] = f end
        end
        assert(#rows >= 2, what .. ": rows missing")
        for _, row in ipairs(rows) do
            local name, verdict, info
            for _, f in ipairs(allFrames) do
                if f.__parent == row and f.__kind == "FontString" then
                    local a = f.__pts.TOPLEFT
                    if a[1] == row.icon then name = f elseif a[1] == row then info = f else verdict = f end
                end
            end
            assert(name and verdict and info, what .. ": texts not found")
            assert(name.__w and verdict.__w and 32 + name.__w + 12 + verdict.__w <= row.__w,
                what .. ": name + verdict wider than the row")
            local top = math.max(name:GetStringHeight(), verdict:GetStringHeight())
            assert(-info.__pts.TOPLEFT[4] >= top, what .. ": numbers overlap name or verdict")
            assert(row.__h >= top + info:GetStringHeight(), what .. ": row lower than its texts")
        end
        NoOverlap(rows, what)
    end
    Check("skills")
    local cap = ns.L["|cffffd060No skill-ups until you train the next rank|r"]
    local found
    for _, f in ipairs(allFrames) do if f.__text == cap then found = true end end
    assert(found, "Briarthorn at 75/75 does not show the trainer verdict")
    scroll.__scripts.OnSizeChanged(scroll, 420, 300) -- narrower: laid out again
    Check("narrow")
    scroll.__scripts.OnSizeChanged(scroll, 698, 300)
    ns.HideMain()
    for k in pairs(added) do stats[k] = nil end
    methods.GetStringHeight = old
    PROFS[1][2], PROFS[1][3] = herb[1], herb[2]
end)
step("Language change without reload: no English left, craft hint too (v0.1.14)", function()
    local keep = ns.db.language
    local target = ns.Language() == "deDE" and "frFR" or "deDE"
    -- like the language buttons in Options: apply, then the options refresh
    ns.db.language = target ns.ApplyLanguage() _G.GathercraftOptions:Refresh()
    local L, dict = ns.L, ns.Locales[target]
    local craft = L["Colored names: recipes you know (color = skill-up chance). Grey: not learned yet, with the skill it needs. "] ..
        L["Hover a line for the reagents. \"Can make\" counts bags and bank. Visit trainers to add their recipes."]
    local farm = L["~ = estimate from known spawn points, your skill and prices. After 10 minutes of farm runs "] ..
        L["in a zone your real numbers are shown instead (green). Click a column title to sort."]
    local gotCraft, gotFarm
    for _, f in ipairs(allFrames) do
        if f.__text == craft then gotCraft = true end
        if f.__text == farm then gotFarm = true end
    end
    assert(gotCraft, "craft page hint not in " .. target .. " after the switch")
    assert(gotFarm, "farm spots hint not in " .. target .. " after the switch")
    -- every page as you see it: no label keeps an English text that has a
    -- translation. The game runs OnShow of a shown frame's children too
    -- (the mock only for the frame itself), so that is done here
    local keys = {}
    for k, v in pairs(dict) do if v ~= k and #k >= 3 then keys[#keys + 1] = k end end
    local main, left, seen = _G.GathercraftMain, {}, {}
    local function InMain(f)
        while f do if f == main then return true end f = f.__parent end
    end
    for _, tab in ipairs({ "overview", "farm", "craft", "zones", "skills", "options" }) do
        ns.ToggleMain(tab) advance(3)
        for _, f in ipairs(allFrames) do
            if f ~= main and f.__scripts.OnShow and InMain(f) and f:IsVisible() then f.__scripts.OnShow(f) end
        end
        for _, f in ipairs(allFrames) do
            local t = f.__kind == "FontString" and type(f.__text) == "string" and f.__text
            if t and not seen[t] and f:IsVisible() and InMain(f) then
                for _, k in ipairs(keys) do
                    if (#k >= 8 and t:find(k, 1, true)) or t == k then seen[t] = true left[#left + 1] = tab .. ": " .. t:sub(1, 60) break end
                end
            end
        end
    end
    ns.HideMain()
    ns.db.language = keep ns.ApplyLanguage()
    assert(#left == 0, ("%d English texts after switching to %s: %s"):format(#left, target, table.concat(left, " | ")))
end)
step("Pins: a zone change on the same continent moves only the minimap pins (v0.1.14)", function()
    -- Mulgore <-> The Barrens (both Kalimdor in the mock, like Thunder Bluff <-> Mulgore)
    local pins = LibStub("HereBeDragons-Pins-2.0")
    local keep = { pins.AddWorldMapIconMap, pins.RemoveWorldMapIcon, pins.AddMinimapIconMap, pins.RemoveMinimapIcon }
    local world, mini, active = { add = 0, rem = 0 }, { add = 0, rem = 0 }, {}
    pins.AddWorldMapIconMap = function(self, ref, icon, ...) if ref == "Gathercraft" then world.add = world.add + 1 end return keep[1](self, ref, icon, ...) end
    pins.RemoveWorldMapIcon = function(self, ref, icon, ...) if ref == "Gathercraft" then world.rem = world.rem + 1 end return keep[2](self, ref, icon, ...) end
    pins.AddMinimapIconMap = function(self, ref, icon, ...)
        if ref == "Gathercraft" then mini.add = mini.add + 1 active[icon] = icon.node end
        return keep[3](self, ref, icon, ...)
    end
    pins.RemoveMinimapIcon = function(self, ref, icon, ...)
        if ref == "Gathercraft" then mini.rem = mini.rem + 1 active[icon] = nil end
        return keep[4](self, ref, icon, ...)
    end
    local map = player.map
    local function Go(mapID)
        world.add, world.rem, mini.add, mini.rem = 0, 0, 0, 0
        player.map = mapID
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
    end
    local function MiniNodes()
        local set, n = {}, 0
        for _, node in pairs(active) do set[node] = true n = n + 1 end
        return set, n
    end
    ns.ImportQuestieZone(1412, true) ns.ImportQuestieZone(1413, true) advance(1)
    -- Mining 110/150 and a known spot where Copper or Tin can be: Copper alone
    -- is grey there, the spot shows Tin's yellow
    local ore = { PROFS[2][2], PROFS[2][3] }
    PROFS[2][2], PROFS[2][3] = 110, 150
    local copper = { id = "o1731", name = "Copper Vein", type = "ore", x = 0.1234, y = 0.4567, count = 0, last = 0, source = "questie" }
    local tin = { id = "o1732", name = "Tin Vein", type = "ore", x = 0.1234, y = 0.4567, count = 0, last = 0, source = "questie" }
    table.insert(ns.db.nodes[1413], copper) table.insert(ns.db.nodes[1413], tin)
    ns.TogglePins() ns.TogglePins() advance(4)
    Go(1412) Go(1413)
    assert(world.add == 0 and world.rem == 0, ("Mulgore -> Barrens: %d world map pins off, %d on"):format(world.rem, world.add))
    assert(mini.add > 0 and mini.rem > 0, "minimap pins did not move")
    local moved, count = MiniNodes()
    local inBarrens = {}
    for _, node in ipairs(ns.db.nodes[1413]) do inBarrens[node] = true end
    for node in pairs(moved) do assert(node.pendingReport or inBarrens[node], "minimap pin of another zone: " .. tostring(node.name)) end
    -- the same pins as a full rebuild: which nodes, the kinds sharing a spot,
    -- ring texture and colour, alpha
    local function Look()
        local out = {}
        for icon, node in pairs(active) do
            local ring, c = icon.ring, icon.ring and icon.ring.__color
            out[node] = ("%s|%s|%s|%.2f|%s"):format(tostring(ring and ring.__tex),
                c and ("%.2f,%.2f,%.2f"):format(c[1], c[2], c[3]) or "-", tostring(icon.level), icon:GetAlpha(),
                icon.othersOf and tostring(#(icon.othersOf.others or {})) or "no link")
        end
        return out
    end
    local afterMove = Look()
    local spot = afterMove[copper] or afterMove[tin]
    assert(spot and spot:find("|yellow|", 1, true), "Copper/Tin spot after the move: " .. tostring(spot))
    ns.TogglePins() ns.TogglePins() advance(1)
    local rebuilt, count2 = MiniNodes()
    assert(count == count2, ("minimap pins after the move %d, after a rebuild %d"):format(count, count2))
    for node in pairs(rebuilt) do assert(moved[node], "a node has a minimap pin only after the rebuild: " .. tostring(node.name)) end
    for node, look in pairs(Look()) do
        assert(afterMove[node] == look, ("%s: after the move %s, after a rebuild %s"):format(tostring(node.name), tostring(afterMove[node]), look))
    end
    for i = #ns.db.nodes[1413], 1, -1 do
        if ns.db.nodes[1413][i] == copper or ns.db.nodes[1413][i] == tin then table.remove(ns.db.nodes[1413], i) end
    end
    PROFS[2][2], PROFS[2][3] = ore[1], ore[2]
    -- another continent: rebuilt as before (grey report pins depend on it)
    Go(1429)
    assert(world.add > 0, "continent change: no rebuild")
    Go(map)
    pins.AddWorldMapIconMap, pins.RemoveWorldMapIcon, pins.AddMinimapIconMap, pins.RemoveMinimapIcon = keep[1], keep[2], keep[3], keep[4]
    advance(1)
end)
step("Run: the empty check after arriving (20 yd) - gathers, other kinds, late records (v0.1.14)", function()
    -- Mulgore in the mock: 1 yd = 0.0002 map x. A far Peacebloom keeps a next target.
    local keepNodes, keepArrive, keepMap, keepX, keepY = ns.db.nodes[1412], ns.db.arriveDist, player.map, player.x, player.y
    local OBJ = { Earthroot = { 1619, 2449, "herb" }, Peacebloom = { 1618, 2447, "herb" }, ["Copper Vein"] = { 1731, 2770, "ore" } }
    local seq = 0
    local function Node(name, xYd, extra)
        local o = OBJ[name]
        local n = { id = "o" .. o[1], name = name, type = o[3], item = o[2], x = 0.5 + xYd / 5000, y = 0.5, count = 1, last = 1 }
        for k, v in pairs(extra or {}) do n[k] = v end
        return n
    end
    local function At(xYd) player.map, player.x, player.y = 1412, 0.5 + xYd / 5000, 0.5 end
    local function Wait(s) for _ = 1, s * 2 do advance(0.5) end end
    local function Cast(name)
        seq = seq + 1
        local id = "emptycheck" .. seq
        fire("UNIT_SPELLCAST_SENT", "player", name, id, OBJ[name][3] == "ore" and 2575 or 2366)
        return id
    end
    local function Done(name, id, withLoot)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", id, OBJ[name][3] == "ore" and 2575 or 2366)
        if withLoot ~= false then
            loot = { { guid = ("GameObject-0-1-1-1-%d-EC%06d"):format(OBJ[name][1], seq), item = OBJ[name][2], qty = 2 } }
            fire("LOOT_READY") fire("LOOT_OPENED")
            loot = {}
        end
    end
    local function Run(nodes, filter)
        ns.db.nodes[1412] = nodes
        table.insert(nodes, Node("Peacebloom", 2500))
        ns.NotifyNodesChanged() advance(1)
        At(-200)
        ns.StartRun(filter, 1412) Wait(1)
        At(-19) Wait(1) -- the first point is reached (19 yd)
    end
    ns.db.arriveDist = 20
    -- a gather still running when the 25 s are over: its result decides
    local A = Node("Earthroot", 0)
    Run({ A }, "herb")
    At(-2) Wait(20)
    local id = Cast("Earthroot") Wait(5) Done("Earthroot", id)
    Wait(30)
    assert(not A.misses and A.hits == 1, ("gather running at the check: misses %s"):format(tostring(A.misses)))
    ns.StopRun(true)
    -- a second try only after the 25 s: the miss is taken back when it works
    A = Node("Earthroot", 0)
    Run({ A }, "herb")
    At(-2) Wait(10)
    id = Cast("Earthroot") Wait(2) fire("UNIT_SPELLCAST_INTERRUPTED", "player", id, 2366)
    Wait(14)
    id = Cast("Earthroot") Wait(3) Done("Earthroot", id)
    Wait(30)
    assert((A.misses or 0) == 0 and A.hits == 1, ("late second try: misses %s"):format(tostring(A.misses)))
    ns.StopRun(true)
    -- another kind gathered 20 yd away says nothing: the empty Earthroot spot is learned
    for _, other in ipairs({ { "Peacebloom", "herb" }, { "Copper Vein", nil } }) do
        A = Node("Earthroot", 0)
        local B = Node(other[1], 22)
        Run({ A, B }, other[2])
        At(20) Wait(2)
        id = Cast(other[1]) Wait(3) Done(other[1], id)
        At(80) Wait(30)
        assert(A.emptyStreak == 1 and A.misses == 1, other[1] .. " next to it counted as an Earthroot harvest")
        ns.StopRun(true)
    end
    -- the herb grows 12 yd from the known point; no loot event at all: since v0.1.14
    -- (round 10) nothing is booked, and the gather without loot keeps the known
    -- point from being called empty (it is not judged)
    A = Node("Earthroot", 0, { source = "questie" })
    Run({ A }, "herb")
    At(12) Wait(2)
    id = Cast("Earthroot") Wait(3) Done("Earthroot", id, false)
    At(55) Wait(32)
    assert(not A.misses, "a late record far away made the known point empty")
    ns.StopRun(true)
    -- unchanged: really empty target = learned; passed by in combat = short rest only
    A = Node("Earthroot", 0)
    Run({ A }, "herb")
    At(-2) Wait(30)
    assert(A.emptyStreak == 1 and A.misses == 1, "empty target not learned")
    ns.StopRun(true)
    A = Node("Earthroot", 0)
    Run({ A }, "herb")
    UnitAffectingCombat = function() return true end
    Wait(15)
    UnitAffectingCombat = nil
    At(-2) Wait(15)
    assert(not A.misses and ns.IsOnCooldown(A), "combat: should be a short rest only")
    ns.StopRun(true)
    ns.db.nodes[1412], ns.db.arriveDist = keepNodes, keepArrive
    player.map, player.x, player.y = keepMap, keepX, keepY
    ns.NotifyNodesChanged() advance(2)
end)
-- shared by the two steps below: a clean Mulgore with chosen nodes
local function IdentityWorld()
    local W = { keepNodes = ns.db.nodes[1412], keepArrive = ns.db.arriveDist, map = player.map, x = player.x, y = player.y, seq = 0 }
    function W.P(xYd) return 0.5 + xYd / 5000, 0.5 end
    function W.At(xYd) player.map = 1412 player.x, player.y = W.P(xYd) end
    function W.Wait(s) for _ = 1, math.floor(s / 0.5 + 0.5) do advance(0.5) end end
    function W.Node(id, name, xYd, extra)
        local x, y = W.P(xYd)
        local n = { id = id, name = name, type = "herb", x = x, y = y, count = 1, last = 1 }
        for k, v in pairs(extra or {}) do n[k] = v end
        return n
    end
    function W.Set(list)
        table.insert(list, W.Node("o1618", "Peacebloom", 2500, { item = 2447 })) -- a far next target
        ns.db.nodes[1412] = list
        ns.NotifyNodesChanged() advance(1)
    end
    function W.Loot(objectID, item, tag, event)
        loot = objectID and { { guid = ("GameObject-0-1-1-1-%d-%s"):format(objectID, tag or "ID0001"), item = item, qty = 2 } } or {}
        fire(event or "LOOT_READY")
        loot = {}
    end
    function W.Cast(target, spell)
        W.seq = W.seq + 1
        local id = "ident" .. W.seq
        fire("UNIT_SPELLCAST_SENT", "player", target, id, spell or 2366)
        return id
    end
    function W.Done(id, spell) fire("UNIT_SPELLCAST_SUCCEEDED", "player", id, spell or 2366) end
    function W.Count(name)
        local c = 0
        for _, n in ipairs(ns.db.nodes[1412]) do if n.name == name then c = c + 1 end end
        return c
    end
    function W.Restore()
        if ns.run then ns.StopRun(true) end
        ns.db.nodes[1412], ns.db.arriveDist = W.keepNodes, W.keepArrive
        player.map, player.x, player.y = W.map, W.x, W.y
        loot = {}
        ns.NotifyNodesChanged() advance(2)
    end
    return W
end
step("Recorder: a gather keeps its identity - late, empty, repeated or crossed loot (v0.1.14)", function()
    local W = IdentityWorld()
    local unknown = ns.L["Unknown Herb"]
    local function Fresh()
        local s = W.Node("o1617", "Silverleaf", 0, { item = 765 })
        W.Set({ s })
        W.At(0)
        return s
    end
    -- control: no target name, loot in time: it is the Silverleaf
    local s = Fresh()
    local id = W.Cast("") W.Wait(2) W.Done(id) advance(0.2) W.Loot(1617, 765, "C0001") W.Wait(3)
    assert(s.count == 2 and W.Count(unknown) == 0, "control: no-name gather with loot not on the Silverleaf")
    -- loot only 2.0 s after the cast (the recorder used to stop at 1.5 s): no Unknown Herb
    s = Fresh()
    id = W.Cast("") W.Wait(2) W.Done(id) advance(2.0) W.Loot(1617, 765, "C0002") W.Wait(3)
    assert(W.Count(unknown) == 0, "late loot: an Unknown Herb was stored")
    assert(s.count == 2 and (s.hits or 0) == 1, "late loot: the Silverleaf did not get its harvest")
    -- R3, a SIMULATED special case (not seen in the real client): an empty loot event first
    s = Fresh()
    id = W.Cast("") W.Wait(2) W.Done(id) advance(0.1) W.Loot(nil) advance(0.2) W.Loot(1617, 765, "C0003", "LOOT_OPENED") W.Wait(3)
    assert(W.Count(unknown) == 0 and s.count == 2, "empty first loot event: the identity got lost")
    -- the same loot twice (LOOT_READY + LOOT_OPENED): one record
    s = Fresh()
    id = W.Cast("Silverleaf") W.Wait(2) W.Done(id) W.Loot(1617, 765, "C0004") W.Loot(1617, 765, "C0004", "LOOT_OPENED") W.Wait(3)
    assert(s.count == 2 and (s.hits or 0) == 1, ("repeated loot event: count %d, hits %s"):format(s.count, tostring(s.hits)))
    -- the other Silverleaf object (o3725) fits a Silverleaf gather: same kind, other ID
    s = Fresh()
    id = W.Cast("Silverleaf") W.Wait(2) W.Done(id) W.Loot(3725, 765, "C0005") W.Wait(3)
    assert(W.Count("Silverleaf") >= 1 and W.Count(unknown) == 0, "second object of the same kind rejected")
    local fitted = false
    for _, n in ipairs(ns.db.nodes[1412]) do if n.id == "o3725" or (n == s and n.count == 2) then fitted = true end end
    assert(fitted, "Silverleaf o3725 loot was not used")
    -- no name and no loot at all: nothing recorded (after the 10 s upper bound)
    s = Fresh()
    local before = #ns.db.nodes[1412]
    id = W.Cast("") W.Wait(2) W.Done(id) W.Wait(12)
    assert(#ns.db.nodes[1412] == before and s.count == 1, "a gather without identity was stored")
    -- interrupted: nothing
    s = Fresh()
    id = W.Cast("") W.Wait(1) fire("UNIT_SPELLCAST_INTERRUPTED", "player", id, 2366) W.Wait(12)
    assert(#ns.db.nodes[1412] == before and s.count == 1, "an interrupted gather was stored")
    -- crossed: the next gather (Peacebloom, 8 yd) starts before the Silverleaf loot came
    s = Fresh()
    local p = W.Node("o1618", "Peacebloom", 8, { item = 2447 })
    table.insert(ns.db.nodes[1412], p) ns.NotifyNodesChanged() advance(1)
    local sx = s.x
    id = W.Cast("Silverleaf") W.Wait(2) W.Done(id)
    W.At(8)
    local id2 = W.Cast("Peacebloom")
    W.Loot(1617, 765, "C0006") -- the Silverleaf loot arrives now
    W.Wait(2) W.Done(id2) W.Loot(1618, 2447, "C0007") W.Wait(3)
    assert(s.count == 2 and math.abs(s.x - sx) < 1e-9, "crossed: the Silverleaf was not booked at its own spot")
    assert(p.count == 2, ("crossed: the Peacebloom was not booked (count %d)"):format(p.count))
    -- crossed without a name: the loot fits both (the first could be any herb):
    -- nobody can tell whose, so neither is booked
    s = Fresh()
    before = #ns.db.nodes[1412]
    id = W.Cast("") W.Wait(2) W.Done(id)
    id2 = W.Cast("Silverleaf") W.Wait(2) W.Done(id2) W.Loot(1617, 765, "C0008") W.Wait(12)
    assert(#ns.db.nodes[1412] == before and s.count == 1, "crossed without a name: a gather of uncertain loot was booked")
    -- only loot of another kind (a wrong name or someone else's loot): nothing rather than a wrong kind
    s = Fresh()
    before = #ns.db.nodes[1412]
    id = W.Cast("Silverleaf") W.Wait(2) W.Done(id) W.Loot(1618, 2447, "C0009") W.Wait(12)
    assert(#ns.db.nodes[1412] == before and s.count == 1, "loot of another kind: something was booked")
    -- Wilted Peacebloom (o656160) is its own Forever herb, even though its loot
    -- holds the Peacebloom item 2447 (the beta starter data says so)
    local function WiltedWorld(wiltedYd)
        local list = { W.Node("o1618", "Peacebloom", 5, { item = 2447 }) }
        if wiltedYd then table.insert(list, W.Node("o656160", "Wilted Peacebloom", wiltedYd, { item = 2447, source = "starter" })) end
        W.Set(list)
        W.At(0)
        return list[1], list[2]
    end
    local function Stats(key) local st = ns.KindStats()[key] return st and st.n or 0 end
    -- (a) named: booked on the Wilted record, never on the Peacebloom 5 yd away
    local pb, wp = WiltedWorld(3)
    local pbStats, wpStats = Stats("herb:peacebloom"), Stats("herb:wilted peacebloom")
    id = W.Cast("Wilted Peacebloom") W.Wait(2) W.Done(id) W.Loot(656160, 2447, "WP0001") W.Wait(3)
    assert(wp.count == 2 and pb.count == 1, ("Wilted gather booked on: wilted %d, peacebloom %d"):format(wp.count, pb.count))
    assert(Stats("herb:wilted peacebloom") == wpStats + 1 and Stats("herb:peacebloom") == pbStats, "Wilted skill stats mixed with Peacebloom")
    -- (b) no name: the name our records give the object, not the item's
    pb, wp = WiltedWorld(60)
    before = #ns.db.nodes[1412]
    id = W.Cast("") W.Wait(2) W.Done(id) W.Loot(656160, 2447, "WP0002") W.Wait(3)
    local new = ns.db.nodes[1412][#ns.db.nodes[1412]]
    assert(#ns.db.nodes[1412] == before + 1 and new.name == "Wilted Peacebloom" and new.id == "o656160" and pb.count == 1,
        ("no-name Wilted gather: %s [%s], peacebloom count %d"):format(tostring(new.name), tostring(new.id), pb.count))
    -- (c) no name, no record of the object in the zone: still not a Peacebloom
    pb = WiltedWorld(nil)
    id = W.Cast("") W.Wait(2) W.Done(id) W.Loot(656160, 2447, "WP0003") W.Wait(3)
    new = ns.db.nodes[1412][#ns.db.nodes[1412]]
    assert(pb.count == 1 and new.id == "o656160" and new.name ~= "Peacebloom", "unnamed Wilted gather became a Peacebloom")
    -- (d) crossed: late Wilted loot does not fit a Peacebloom gather
    pb, wp = WiltedWorld(3)
    id = W.Cast("Wilted Peacebloom") W.Wait(2) W.Done(id)
    W.At(5)
    id2 = W.Cast("Peacebloom")
    W.Loot(656160, 2447, "WP0004")
    W.Wait(2) W.Done(id2) W.Loot(1618, 2447, "PB0004") W.Wait(3)
    -- the Wilted loot fits only the Wilted gather still waiting: it is its own, booked there
    assert(pb.count == 2 and pb.lastSpawn == "PB0004" and wp.count == 2 and wp.lastSpawn == "WP0004",
        "crossed Wilted/Peacebloom: loot of the one booked on the other")
    -- (e) a Peacebloom gather that only gets Wilted loot (no earlier gather waiting):
    -- the kind check alone must reject it - nothing booked, no Peacebloom with o656160
    pb, wp = WiltedWorld(3)
    before = #ns.db.nodes[1412]
    id = W.Cast("Peacebloom") W.Wait(2) W.Done(id) W.Loot(656160, 2447, "WP0005") W.Wait(12)
    assert(#ns.db.nodes[1412] == before and pb.count == 1 and wp.count == 1 and pb.id == "o1618",
        "a Peacebloom gather took Wilted Peacebloom loot")
    -- crossed, same kind: Silverleaf A, then Silverleaf B 8 yd on before A's loot came.
    -- Same kind is not enough to know whose loot it is: neither is booked (no
    -- count, no spawn, no skill stat) rather than a guess
    local a = W.Node("o1617", "Silverleaf", 0, { item = 765 })
    local b = W.Node("o1617", "Silverleaf", 8, { item = 765 })
    W.Set({ a, b })
    local ax, bx = a.x, b.x
    local slStats = Stats("herb:silverleaf")
    W.At(0)
    id = W.Cast("Silverleaf") W.Wait(2) W.Done(id)
    W.At(8)
    id2 = W.Cast("Silverleaf") W.Wait(2) W.Done(id2)
    W.Loot(1617, 765, "SLA001") W.Loot(1617, 765, "SLA001", "LOOT_OPENED") -- A's loot, late, twice
    W.Loot(1617, 765, "SLB001") W.Loot(1617, 765, "SLB001", "LOOT_OPENED") -- B's own, twice
    W.Wait(12)
    assert(a.count == 1 and b.count == 1 and Stats("herb:silverleaf") == slStats,
        ("same kind crossed: A %d, B %d, stats +%d"):format(a.count, b.count, Stats("herb:silverleaf") - slStats))
    assert(math.abs(a.x - ax) < 1e-9 and math.abs(b.x - bx) < 1e-9, "same kind crossed: a spot moved")
    assert(not a.lastSpawn and not b.lastSpawn, "same kind crossed: a spawn of uncertain owner was booked")
    -- three Silverleafs, each cast before the loot of the one before, every loot
    -- twice: no count, hit or skill stat grows more than once per gather (here: none)
    local three = { W.Node("o1617", "Silverleaf", 0, { item = 765 }), W.Node("o1617", "Silverleaf", 8, { item = 765 }),
        W.Node("o1617", "Silverleaf", 16, { item = 765 }) }
    W.Set({ three[1], three[2], three[3] })
    slStats = Stats("herb:silverleaf")
    for i = 1, 3 do
        W.At((i - 1) * 8)
        local c = W.Cast("Silverleaf") W.Wait(2) W.Done(c)
        if i > 1 then W.Loot(1617, 765, "TRI" .. (i - 1)) W.Loot(1617, 765, "TRI" .. (i - 1), "LOOT_OPENED") end
    end
    W.Loot(1617, 765, "TRI3") W.Loot(1617, 765, "TRI3", "LOOT_OPENED")
    W.Wait(13)
    local grew = 0
    for _, n in ipairs(three) do
        assert(n.count <= 2 and (n.hits or 0) <= 1, "three crossed: a node grew more than once")
        grew = grew + n.count - 1
    end
    assert(grew == Stats("herb:silverleaf") - slStats and grew <= 3, ("three crossed: counts +%d, stats +%d"):format(
        grew, Stats("herb:silverleaf") - slStats))
    -- one copper vein mined three times (one spawn), every loot twice: counted once
    -- when the loot comes in time, at most once (here: dropped) when it comes late
    for _, late in ipairs({ false, true }) do
        local v = W.Node("o1731", "Copper Vein", 0, { type = "ore", item = 2770 })
        W.Set({ v })
        W.At(0)
        local st = Stats("ore:copper vein")
        for i = 1, 3 do
            local c = W.Cast("Copper Vein", 2575) W.Wait(2) W.Done(c, 2575)
            if not late then
                W.Loot(1731, 2770, "VEIN01") W.Loot(1731, 2770, "VEIN01", "LOOT_OPENED") W.Wait(1)
            elseif i > 1 then
                W.Loot(1731, 2770, "VEIN01") W.Loot(1731, 2770, "VEIN01", "LOOT_OPENED")
            end
        end
        if late then W.Loot(1731, 2770, "VEIN01") W.Loot(1731, 2770, "VEIN01", "LOOT_OPENED") end
        W.Wait(13)
        local grown = Stats("ore:copper vein") - st
        assert(v.count - 1 <= 1 and (v.hits or 0) <= 1 and grown <= 1,
            ("vein mined 3x (loot %s): count +%d, hits %s, stats +%d"):format(late and "late" or "in time", v.count - 1, tostring(v.hits), grown))
        if not late then assert(v.count == 2 and grown == 1, "vein mined 3x, loot in time: not counted once") end
    end
    -- one rule: booked only with its own loot. The same vein mined three times
    -- without any loot event: nothing booked, no count, hit or skill stat
    do
        local v = W.Node("o1731", "Copper Vein", 0, { type = "ore", item = 2770 })
        W.Set({ v })
        W.At(0)
        local st = Stats("ore:copper vein")
        for _ = 1, 3 do
            local c = W.Cast("Copper Vein", 2575) W.Wait(2) W.Done(c, 2575) W.Wait(4)
        end
        W.Wait(12)
        assert(v.count == 1 and not v.hits and Stats("ore:copper vein") == st and #ns.db.nodes[1412] == 2,
            ("vein mined 3x without loot: count +%d, hits %s, stats +%d"):format(v.count - 1, tostring(v.hits), Stats("ore:copper vein") - st))
    end
    -- a single herb, its own loot late (5 s) but clear: booked once, with its spawn
    do
        local sl = W.Node("o1617", "Silverleaf", 0, { item = 765 })
        W.Set({ sl })
        W.At(0)
        local st = Stats("herb:silverleaf")
        local c = W.Cast("Silverleaf") W.Wait(2) W.Done(c) W.Wait(5)
        W.Loot(1617, 765, "LATE01") W.Loot(1617, 765, "LATE01", "LOOT_OPENED") W.Wait(12)
        assert(sl.count == 2 and sl.hits == 1 and sl.lastSpawn == "LATE01" and Stats("herb:silverleaf") == st + 1,
            ("single herb, late loot: count +%d, hits %s, spawn %s, stats +%d"):format(sl.count - 1, tostring(sl.hits),
                tostring(sl.lastSpawn), Stats("herb:silverleaf") - st))
    end
    -- unchanged: loot in time is booked at once (no 10 s wait), every loot event twice counts once
    do
        local sl = W.Node("o1617", "Silverleaf", 0, { item = 765 })
        W.Set({ sl })
        W.At(0)
        local st = Stats("herb:silverleaf")
        local c = W.Cast("Silverleaf") W.Wait(2) W.Done(c)
        W.Loot(1617, 765, "NOW001") W.Loot(1617, 765, "NOW001", "LOOT_OPENED")
        assert(sl.count == 2 and sl.lastSpawn == "NOW001", "loot in time: not booked at once")
        W.Wait(12)
        assert(sl.count == 2 and sl.hits == 1 and Stats("herb:silverleaf") == st + 1, "loot in time, twice: counted more than once")
    end
    -- the object name lookup uses the zone index: a new record's name is found
    -- at once, and a renamed record too (index kept up to date)
    local o = W.Node("o987654", "Shimmer Moss", 30, { item = 2447 })
    W.Set({ o })
    assert(ns.ObjectName(987654, 1412) == "Shimmer Moss", "object name not found")
    local o2 = W.Node("o987655", "Glow Cap", 40, { item = 2447 })
    table.insert(ns.db.nodes[1412], o2) ns.NotifyNodesChanged("add", 1412, o2)
    assert(ns.ObjectName(987655, 1412) == "Glow Cap", "object name of a new record not found")
    W.Restore()
end)
step("Run: points without identity learn nothing; known kinds stay apart (v0.1.14)", function()
    local W = IdentityWorld()
    ns.db.arriveDist = 20
    local function Run(list)
        W.Set(list)
        W.At(-200) ns.StartRun("herb", 1412) W.Wait(1)
        W.At(-15) W.Wait(1)
    end
    local function Harvest(objectID, item, name)
        local id = W.Cast(name) W.Wait(2) W.Done(id) W.Loot(objectID, item, "R" .. W.seq) W.Wait(1)
    end
    -- the log case: Silverleaf gathered, an old Unknown Herb [nil] 8 yd away
    local s = W.Node("o1617", "Silverleaf", 0, { item = 765, source = "questie", count = 0 })
    local u = W.Node(nil, "Unknown Herb", 6)
    Run({ s, u })
    W.At(-1) W.Wait(10)
    Harvest(1617, 765, "Silverleaf")
    W.Wait(30)
    assert(not u.misses and not u.emptyStreak and not u.hits, "unknown point next to a harvest learned something")
    ns.StopRun(true)
    -- nothing harvested: an unknown point only rests, it learns nothing
    u = W.Node(nil, "Unknown Herb", 0)
    Run({ u })
    W.At(-1) W.Wait(30)
    assert(not u.misses and not u.emptyStreak and ns.IsOnCooldown(u), "unknown point without harvest: should only rest")
    ns.StopRun(true)
    -- known kinds stay apart: an empty Peacebloom 8 yd from a harvested Silverleaf is empty
    s = W.Node("o1617", "Silverleaf", 0, { item = 765 })
    local pb = W.Node("o1618", "Peacebloom", 8, { item = 2447 })
    Run({ s, pb })
    W.At(-1) W.Wait(2)
    Harvest(1617, 765, "Silverleaf")
    W.At(60) W.Wait(30)
    assert(pb.misses == 1, "an empty known Peacebloom next to a Silverleaf harvest was not learned")
    ns.StopRun(true)
    -- Wilted Peacebloom is another herb: its harvest does not cover an empty Peacebloom point
    local wp = W.Node("o656160", "Wilted Peacebloom", 0, { item = 2447 })
    pb = W.Node("o1618", "Peacebloom", 8, { item = 2447 })
    Run({ wp, pb })
    W.At(-1) W.Wait(2)
    Harvest(656160, 2447, "Wilted Peacebloom")
    W.At(60) W.Wait(30)
    assert(pb.misses == 1 and not wp.misses, "a Wilted Peacebloom harvest counted for the Peacebloom point")
    ns.StopRun(true)
    -- an ore harvest does not cover an unknown herb point
    u = W.Node(nil, "Unknown Herb", 0)
    local v = W.Node("o1731", "Copper Vein", 8, { type = "ore", item = 2770 })
    W.Set({ u, v })
    W.At(-200) ns.StartRun(nil, 1412) W.Wait(1) W.At(-15) W.Wait(1)
    W.At(8) W.Wait(2)
    local id = W.Cast("Copper Vein", 2575) W.Wait(2) W.Done(id, 2575) W.Loot(1731, 2770, "R0") W.Wait(1)
    W.At(60) W.Wait(30)
    assert(not u.misses and ns.IsOnCooldown(u), "unknown herb: an ore harvest should not count, a rest only")
    W.Restore()
end)
step("Sync: parking or unparking one node changes only its pins and the route list (v0.1.14)", function()
    local Z = 1412
    local pins = LibStub("HereBeDragons-Pins-2.0")
    local keep = { pins.AddWorldMapIconMap, pins.RemoveWorldMapIcon, pins.AddMinimapIconMap, pins.RemoveMinimapIcon }
    local adds, active = 0, {}
    pins.AddWorldMapIconMap = function(self, ref, icon, ...)
        if ref == "Gathercraft" then adds = adds + 1 active[icon] = "world" end
        return keep[1](self, ref, icon, ...)
    end
    pins.RemoveWorldMapIcon = function(self, ref, icon, ...) if ref == "Gathercraft" then active[icon] = nil end return keep[2](self, ref, icon, ...) end
    pins.AddMinimapIconMap = function(self, ref, icon, ...)
        if ref == "Gathercraft" then adds = adds + 1 active[icon] = "mini" end
        return keep[3](self, ref, icon, ...)
    end
    pins.RemoveMinimapIcon = function(self, ref, icon, ...) if ref == "Gathercraft" then active[icon] = nil end return keep[4](self, ref, icon, ...) end
    local notified = {}
    local Notify = ns.NotifyNodesChanged
    ns.NotifyNodesChanged = function(kind, ...) notified[#notified + 1] = tostring(kind) return Notify(kind, ...) end
    local function Count() adds = 0 wipe(notified) end
    -- what the map shows: per node and pin kind ring, colour, level, alpha, kinds sharing the spot
    local function Look()
        local out = {}
        for icon, where in pairs(active) do
            local ring, c = icon.ring, icon.ring and icon.ring.__color
            local key = tostring(icon.node and icon.node.name) .. "@" .. tostring(icon.node) .. ":" .. where
            out[key] = ("%s|%s|%s|%.2f|%d"):format(tostring(ring and ring.__tex), c and ("%.2f,%.2f,%.2f"):format(c[1], c[2], c[3]) or "-",
                tostring(icon.level), icon:GetAlpha(), #(icon.others or (icon.othersOf and icon.othersOf.others) or {}))
        end
        return out
    end
    local function RouteLook()
        local set = {}
        for _, p in ipairs(ns.run and ns.run.points or {}) do set[p.node] = true end
        return set, ns.run and ns.run.target
    end
    -- the targeted update against a full rebuild of pins and route list
    local function SameAsRebuild(what)
        local look, route, tgt = Look(), RouteLook()
        ns.TogglePins() ns.TogglePins()
        if ns.run then ns.run.pointsDirty = true ns.RouteGoalChanged() end
        advance(1)
        local look2, route2, tgt2 = Look(), RouteLook()
        for k, v in pairs(look) do assert(look2[k] == v, ("%s: %s is %s, after a rebuild %s"):format(what, k, v, tostring(look2[k]))) end
        for k, v in pairs(look2) do assert(look[k] == v, ("%s: %s only after a rebuild (%s)"):format(what, k, v)) end
        for n in pairs(route) do assert(route2[n], what .. ": in the route list only before the rebuild: " .. tostring(n.name)) end
        for n in pairs(route2) do assert(route[n], what .. ": in the route list only after the rebuild: " .. tostring(n.name)) end
        assert(tgt == tgt2, what .. ": another target after the rebuild")
    end
    local function AllUpdates(what)
        for _, k in ipairs(notified) do assert(k == "update", what .. ": told everyone '" .. k .. "' (all pins are rebuilt)") end
    end

    local keepNodes = ns.db.nodes[Z]
    ns.db.nodes[Z] = {}
    ns.ImportQuestieZone(Z, true)
    -- a node only other players reported, empty four times over 13 hours
    local S = { id = "o1618", name = "Peacebloom", type = "herb", x = 0.3012, y = 0.2987, count = 1, last = time() - 50000,
        item = 2447, source = "sync", heard = 1, heardBy = { Alice = true } }
    local function Unlucky() S.healMisses, S.healFirst, S.healAt = 4, time() - 13 * 3600, time() - 700 end
    Unlucky()
    table.insert(ns.db.nodes[Z], S)
    -- one of our own further on: the run keeps a target after S (the empty
    -- check after arriving only runs while there is one)
    table.insert(ns.db.nodes[Z], { id = "o1618", name = "Peacebloom", type = "herb", x = S.x + 300 / 5000, y = S.y, count = 2, last = 1, item = 2447 })
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    player.map, player.x, player.y = Z, S.x + 30 / 5000, S.y
    ns.StartRun("herb", Z) advance(1)
    assert(ns.run and ns.run.target == S, "test setup: the shared node is the target")

    -- (1) parked by SelfHeal: arrived, nothing there for 25 s
    Count()
    player.x = S.x advance(27)
    assert(S.parked, "not parked after the fifth empty visit")
    AllUpdates("parked")
    assert(adds <= 2, ("parking one node registered %d pins"):format(adds))
    local route = RouteLook()
    assert(not route[S] and ns.run.target ~= S, "the parked node is still in the route list or the target")
    local look = Look()
    local w = look["Peacebloom@" .. tostring(S) .. ":world"]
    assert(w and w:find("|0.25|", 1, true), "parked node not faded on the world map: " .. tostring(w))
    SameAsRebuild("parked")
    -- the same again: nothing changes
    Count()
    assert(not ns.SyncSelfHeal(S), "parked twice")
    advance(1)
    assert(adds == 0 and #notified == 0, "parking again changed something")

    -- (2) back through sync: someone new reports it
    local text = ("N:%d;o1618,h,%d,%d,2447"):format(Z, math.floor(S.x * 10000 + 0.5), math.floor(S.y * 10000 + 0.5))
    Count()
    fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", "Newcomer-Realm") advance(1)
    assert(not S.parked, "not back after a new player reported it")
    AllUpdates("back by sync")
    assert(adds <= 2, ("unparking one node registered %d pins"):format(adds))
    assert(RouteLook()[S], "the node is back but not in the route list")
    SameAsRebuild("back by sync")
    -- the same message again, and one more player: nothing to change
    Count()
    fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", "Newcomer-Realm") advance(2)
    fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", "Another-Realm") advance(1)
    assert(adds == 0 and #notified == 0, "a report of a node that is back changed something")

    -- (3) parked again, back by a look on the minimap
    Unlucky()
    Count()
    assert(ns.SyncSelfHeal(S) and S.parked, "test setup: parked again")
    advance(1)
    AllUpdates("parked again")
    assert(adds <= 2 and not RouteLook()[S], "parked again: pins or route list")
    advance(6)
    Count()
    ns.SeenOnMinimap(Z, S.x, S.y, S.name, 10) advance(1)
    assert(not S.parked, "not back after a look on the minimap")
    AllUpdates("back by a look")
    assert(adds <= 4, ("unparking by a look registered %d pins"):format(adds))
    assert(RouteLook()[S], "back by a look but not in the route list")
    SameAsRebuild("back by a look")
    -- seen with your own eyes: never parked again
    Unlucky()
    Count()
    assert(not ns.SyncSelfHeal(S) and not S.parked, "a node seen on the minimap was parked")
    advance(1)
    assert(adds == 0 and #notified == 0, "a refused park changed something")

    -- (4) the map follows the Zones tab and the zone is off: no pins, before and after
    ns.StopRun() advance(1)
    S.seenAt, S.upAt = nil, nil
    ns.db.mapFollowsZones, ns.db.disabledZones[Z] = true, true
    ns.TogglePins() ns.TogglePins() advance(1)
    Unlucky()
    Count()
    assert(ns.SyncSelfHeal(S) and S.parked, "test setup: parked in a zone that is off")
    advance(1)
    assert(adds == 0, "a node of a zone that is off got pins")
    SameAsRebuild("zone off")
    ns.db.mapFollowsZones, ns.db.disabledZones[Z] = nil, nil

    ns.NotifyNodesChanged = Notify
    pins.AddWorldMapIconMap, pins.RemoveWorldMapIcon, pins.AddMinimapIconMap, pins.RemoveMinimapIcon = keep[1], keep[2], keep[3], keep[4]
    ns.db.nodes[Z] = keepNodes
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    advance(1)
end)
step("Run: checks after arriving come due also while the run has no target (v0.1.14)", function()
    local Z = 1471
    local saved = { debug = ns.db.debug, arrive = ns.db.arriveDist }
    ns.db.debug, ns.db.arriveDist = true, 20
    local seq = 0
    -- one route point only: once it is reached, the run has no target
    local function Setup()
        ns.StopRun() advance(1)
        local S = { id = "o1618", name = "Peacebloom", type = "herb", x = 0.50, y = 0.50, count = 3, last = 1, item = 2447 }
        ns.db.nodes[Z] = { S }
        ns.NotifyNodesChanged() ns.ForgetSeenKinds()
        player.map, player.x, player.y = Z, 0.50 + 60 / 5000, 0.50
        ns.StartRun("herb", Z) advance(1)
        assert(ns.run and ns.run.target == S, "test setup: target")
        player.x = 0.50 advance(1)
        assert(not ns.run.target and #ns.run.checking == 1, "test setup: reached, no target, one check open")
        return S, #log
    end
    local function Cast()
        seq = seq + 1
        fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "nt" .. seq, 2366)
        return "nt" .. seq
    end
    local function Loot(id)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", id, 2366)
        loot = { { guid = ("GameObject-0-1-1-1-1618-NT%04d"):format(seq), item = 2447, qty = 2 } }
        fire("LOOT_READY") loot = {}
    end
    local function Said(text, from)
        for i = from, #log do if log[i]:find(text, 1, true) then return true end end
    end

    -- (a) really empty: counted as empty, and the run goes on (it used to wait
    -- for the open check until it gave up after 10 minutes)
    local S, mark = Setup()
    advance(30)
    assert(S.misses == 1 and ns.IsOnCooldown(S), "an empty point was not counted as empty while the run had no target")
    assert(Said("since arriving 25 s ago (target, no combat)", mark), "no check line for the empty point")
    assert(#ns.run.checking == 0, "the check is still open")
    advance(600)
    assert(ns.run, "the run gave up although its point came back")

    -- (b) harvested: the check closes as harvested, nothing counted as empty
    S, mark = Setup()
    local id = Cast() advance(2) Loot(id)
    advance(30)
    assert(S.hits == 1 and not S.misses and Said("harvested (this node", mark), "harvest without a target: not checked as harvested")
    assert(#ns.run.checking == 0, "harvested: the check is still open")

    -- (c) a gather still running when the check comes due: waited for, then harvested
    S, mark = Setup()
    advance(21)
    id = Cast() advance(5)
    assert(Said("still gathering", mark) and not S.misses, "a running gather was not waited for")
    Loot(id) advance(5)
    assert(S.hits == 1 and not S.misses and Said("harvested (this node", mark), "harvested after waiting: not checked as harvested")

    -- (d) a gather that succeeded without loot of its own: not judged, nothing learned
    S, mark = Setup()
    id = Cast() advance(2) fire("UNIT_SPELLCAST_SUCCEEDED", "player", id, 2366)
    advance(30)
    assert(Said("not judged, nothing learned", mark) and not S.misses and not S.hits, "an uncertain gather was judged")

    -- (e) stopped before the check came due: nothing is judged afterwards
    S, mark = Setup()
    advance(5)
    ns.StopRun() advance(40)
    assert(not S.misses and not ns.IsOnCooldown(S) and not Said("check Peacebloom", mark), "a check was judged after the run stopped")

    ns.db.debug, ns.db.arriveDist = saved.debug, saved.arrive
    ns.db.nodes[Z] = nil
    ns.NotifyNodesChanged()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    advance(1)
end)
step("Run: spots from other players are taken in together, ones the run can't use not at all (v0.1.14)", function()
    local keep = { [1412] = ns.db.nodes[1412], [1413] = ns.db.nodes[1413], [1429] = ns.db.nodes[1429] }
    local saved = { skill = PROFS[1][2], max = PROFS[1][3], disabled = ns.db.disabledZones[1413] }
    ns.db.nodes[1412], ns.db.nodes[1413], ns.db.nodes[1429] = {}, {}, {}
    -- a few of our own, so the run has something to do
    for i = 1, 6 do
        table.insert(ns.db.nodes[1412], { id = "o1618", name = "Peacebloom", type = "herb", x = 0.30 + i * 0.02, y = 0.30, count = 2, last = 1, item = 2447 })
    end
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    local briar
    for id, k in pairs(GathercraftQuestieData.kinds) do if k[3] == "Briarthorn" then briar = id end end
    -- the node list of the run: how often it was collected again
    local collects, lastPoints = 0, nil
    local watch = C_Timer.NewTicker(0.05, function()
        local r = ns.run
        if r and r.points ~= lastPoints then
            if lastPoints then collects = collects + 1 end
            lastPoints = r.points
        end
    end)
    local function InRun(n)
        for _, p in ipairs(ns.run and ns.run.points or {}) do if p.node == n then return true end end
    end
    local senders = 0
    local function Import(mapID, entries)
        senders = senders + 1 -- one guild member per message: the rate limit stays out of it
        local parts = {}
        for i, e in ipairs(entries) do
            parts[i] = ("%s,%s,%d,%d,%d"):format(e[1], e[2], math.floor(e[3] * 10000 + 0.5), math.floor(e[4] * 10000 + 0.5), e[5] or 0)
        end
        fire("CHAT_MSG_ADDON", "Gathercraft", "N:" .. mapID .. ";" .. table.concat(parts, ";"), "GUILD", "Guild" .. senders .. "-Realm")
    end
    local function Find(mapID, id, x, y) return ns.FindNode(mapID, id, x, y, 5) end
    local function Start(filter, zone)
        ns.StopRun() advance(1)
        player.map, player.x, player.y = 1412, 0.30, 0.32
        ns.StartRun(filter, zone) advance(2)
        assert(ns.run and ns.run.points, "test setup: no run")
        lastPoints, collects = ns.run.points, 0
    end

    -- (1) spots this run can't use: stored and on the map, the run's list stays as it is
    Start("herb", 1412)
    PIN_ADDS = 0
    Import(1412, { { "o1731", "o", 0.40, 0.40, 2770 } }) advance(1.2)  -- ore: another type
    Import(1413, { { "o1618", "h", 0.40, 0.40, 2447 } }) advance(1.2)  -- herb, but another zone
    Import(1429, { { "o1618", "h", 0.40, 0.40, 2447 } }) advance(1.2)  -- herb, another continent
    advance(15)
    assert(Find(1412, "o1731", 0.40, 0.40) and Find(1413, "o1618", 0.40, 0.40) and Find(1429, "o1618", 0.40, 0.40), "an import was not stored")
    assert(PIN_ADDS >= 3, "an import was not shown on the map")
    assert(collects == 0, ("spots the run can't use collected its list again %d times"):format(collects))
    -- a run over all zones: another continent is another world (the mini WoW
    -- has one world for all maps, so Elwynn Forest gets instance 0 here)
    local HBD = LibStub("HereBeDragons-2.0")
    local Coords = HBD.GetWorldCoordinatesFromZone
    HBD.GetWorldCoordinatesFromZone = function(self, x, y, map)
        local wx, wy, inst = Coords(self, x, y, map)
        return wx, wy, map == 1429 and 0 or inst
    end
    Start("herb")
    Import(1429, { { "o1618", "h", 0.45, 0.45, 2447 } }) advance(12)
    HBD.GetWorldCoordinatesFromZone = Coords
    assert(Find(1429, "o1618", 0.45, 0.45) and collects == 0, "a spot on another continent collected the list of a run over all zones")

    -- (2) a stream of usable ones (30 s): taken in together, each at the latest 10 s after it came
    local arrived, n = {}, 0
    local late = 0
    local check = C_Timer.NewTicker(0.5, function()
        for node, t in pairs(arrived) do
            if not InRun(node) and GetTime() - t > 10.5 then late = late + 1 arrived[node] = nil end
            if InRun(node) then arrived[node] = nil end
        end
    end)
    for k = 1, 25 do
        local entries = {}
        for j = 1, 6 do
            n = n + 1
            entries[j] = { "o1618", "h", 0.10 + (n % 30) * 0.02, 0.50 + math.floor(n / 30) * 0.02, 2447 }
        end
        Import(1412, entries)
        for _, e in ipairs(entries) do
            local node = Find(1412, e[1], e[3], e[4])
            assert(node, "test setup: import not stored")
            arrived[node] = GetTime()
        end
        advance(1.2)
    end
    advance(12)
    check:Cancel()
    assert(late == 0, late .. " imported spots were not in the run 10 s after they came")
    assert(next(arrived) == nil, "imported spots never reached the run")
    assert(collects >= 3 and collects <= 4, ("25 messages in 30 s: the list was collected %d times (expected 3-4)"):format(collects))

    -- (3) spots that did not fit count once the run fits them: filter, zone, skill
    Start("ore", 1412)
    assert(InRun(Find(1412, "o1731", 0.40, 0.40)), "after a filter change: the ore vein that came during a herb run is missing")
    Start("herb", 1413)
    assert(InRun(Find(1413, "o1618", 0.40, 0.40)), "a run in the other zone: its imported herb is missing")
    ns.db.disabledZones[1413] = true
    Start("herb")
    Import(1413, { { "o1618", "h", 0.60, 0.60, 2447 } }) advance(12)
    assert(collects == 0, "a spot in a zone switched off collected the list again")
    ns.db.disabledZones[1413] = nil
    ns.NotifyNodesChanged() advance(1) -- the Zones tab: zone back on
    assert(InRun(Find(1413, "o1618", 0.60, 0.60)), "zone switched on again: its imported herb is missing")
    PROFS[1][2] = 40 -- Herbalism 40: Briarthorn (70) can't be gathered yet
    Start("herb", 1412)
    Import(1412, { { briar, "h", 0.70, 0.70, 2450 } }) advance(11)
    local b = Find(1412, briar, 0.70, 0.70)
    assert(InRun(b), "a Briarthorn import is not in the run's list")
    local bp
    for _, p in ipairs(ns.run.points) do if p.node == b then bp = p end end
    assert((ns.run.weights[bp.kind] or 0) == 0, "test setup: Briarthorn at skill 40 is not left out")
    -- the weights are worked out again with the next plan after 30 s (riding on)
    PROFS[1][2], PROFS[1][3] = 100, 300 advance(31)
    player.x = player.x + 60 / 5000 advance(1)
    assert((ns.run.weights[bp.kind] or 0) > 0, "after the skill went up: the imported Briarthorn is still left out")

    -- (4) our own harvest of a new spot: in the run at once, as before
    Start("herb", 1412)
    player.x, player.y = 0.90, 0.90
    fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "imp1", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "imp1", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1618-IMP001", item = 2447, qty = 2 } }
    fire("LOOT_READY") loot = {} advance(1)
    local own = Find(1412, "o1618", 0.90, 0.90)
    assert(own and not own.source and InRun(own), "our own new spot is not in the run a second later")

    watch:Cancel()
    ns.StopRun()
    for m, list in pairs(keep) do ns.db.nodes[m] = list end
    ns.db.disabledZones[1413] = saved.disabled
    PROFS[1][2], PROFS[1][3] = saved.skill, saved.max
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    advance(1)
end)
step("Self-healing: one empty visit per stay at a spot, not one per check (v0.1.14)", function()
    local Z = 1471
    local saved = { arrive = ns.db.arriveDist }
    ns.db.arriveDist = 25 -- gone from the spot = more than 2 x max(25, 30) = 60 yd
    local S
    local function Setup()
        ns.StopRun() advance(1)
        S = { id = "o1618", name = "Peacebloom", type = "herb", x = 0.50, y = 0.50, count = 1, last = 1, item = 2447,
            source = "sync", heard = 1, heardBy = { Alice = true } }
        ns.db.nodes[Z] = { S }
        ns.NotifyNodesChanged() ns.ForgetSeenKinds()
        player.map, player.x, player.y = Z, 0.50, 0.50
        ns.StartRun("herb", Z) advance(30)
        assert(S.healMisses == 1 and S.healStay, "test setup: the first empty visit did not count")
    end
    local function At(yards) player.x = 0.50 + yards / 5000 end

    -- (1) standing there for two hours: the checks go on (each one gives the
    -- point its rest), the point learns "empty" once (experiment O1), and
    -- self-healing counts the stay once
    local dbg = ns.db.debug
    ns.db.debug = true
    Setup()
    local mark = #log
    advance(7200)
    ns.db.debug = dbg
    local again = 0
    for i = mark, #log do if log[i]:find("the same stay, rest only", 1, true) then again = again + 1 end end
    assert(ns.run and again >= 10, "the checks stopped while standing there: " .. again .. " checks")
    assert(S.misses == 1, "two hours at one spot: the point learned 'empty' " .. tostring(S.misses) .. " times")
    assert(S.healMisses == 1 and not S.parked, ("two hours at one spot counted %d empty visits"):format(S.healMisses))

    -- (2) moving about at the spot, also past the arrival radius (25 yd) and
    -- the empty check radius (30 yd), but never 60 yd away: the same stay
    Setup()
    for _ = 1, 20 do
        At(45) advance(150) At(55) advance(150) At(10) advance(150)
    end
    assert(S.healMisses == 1, ("small moves at the spot counted %d empty visits"):format(S.healMisses))

    -- (3) gone and back: a new visit, under the old time limits
    Setup()
    At(100) advance(2) -- 100 yd away: gone
    assert(not S.healStay, "100 yd away is not gone from the spot")
    At(0) advance(30) -- back within 10 minutes of the counted visit: too soon
    assert(S.healMisses == 1, "back after a minute counted a new empty visit (10 minutes apart at least)")
    At(100) advance(700) -- away for longer than 10 minutes
    At(0) advance(30)
    assert(S.healMisses == 2, ("gone for 12 minutes and back: %s empty visits counted (expected 2)"):format(tostring(S.healMisses)))
    advance(1800) -- and again a long stay: still 2
    assert(S.healMisses == 2, "the second stay counted more than once")

    -- (4) a stop and a new run at the same spot are still the same stay
    Setup()
    ns.StopRun() advance(700)
    ns.StartRun("herb", Z) advance(60)
    assert(S.healStay and S.healMisses == 1, "a new run at the same spot counted a new empty visit")
    -- ... also without a run while you wait: only being seen away counts
    ns.StopRun() At(200) advance(5) At(0) advance(700)
    ns.StartRun("herb", Z) advance(60)
    assert(S.healMisses == 1, "away and back without a run in between counted a new empty visit")
    At(100) advance(2) At(0) advance(180) -- back; the point's 2 minute rest runs out, then it is checked
    assert(S.healMisses == 2, "gone during a run and back: not counted")

    ns.StopRun()
    ns.db.arriveDist = saved.arrive
    ns.db.nodes[Z] = nil
    ns.NotifyNodesChanged()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    advance(1)
end)
step("Experiment O1: a point learns 'empty' once per stay, the checks and rests go on", function()
    local Z = 1471
    local saved = { arrive = ns.db.arriveDist, debug = ns.db.debug }
    ns.db.arriveDist, ns.db.debug = 25, true -- gone from the spot = more than 60 yd
    local S, seq = nil, 0
    local function At(yards) player.x = 0.50 + yards / 5000 end
    -- one point of our own: once it is reached, the run has no target
    local function Setup()
        ns.StopRun() advance(1)
        S = { id = "o1618", name = "Peacebloom", type = "herb", x = 0.50, y = 0.50, count = 3, last = 1, item = 2447 }
        ns.db.nodes[Z] = { S }
        ns.NotifyNodesChanged() ns.ForgetSeenKinds()
        player.map, player.y = Z, 0.50 At(60)
        ns.StartRun("herb", Z) advance(1)
        At(0) advance(30)
        assert(S.misses == 1 and S.learnStay, "test setup: the first empty visit was not learned")
    end
    local function Harvest()
        seq = seq + 1
        local id = "o1x" .. seq
        fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", id, 2366) advance(2)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", id, 2366)
        loot = { { guid = ("GameObject-0-1-1-1-1618-O1%04d"):format(seq), item = 2447, qty = 2 } }
        fire("LOOT_READY") loot = {}
    end

    -- (1) an hour standing there: checked again and again (each one gives the
    -- point its rest), learned once; its chance only comes back, never drops again
    Setup()
    local c1 = ns.NodeChance(S)
    local mark = #log
    advance(3600)
    local again = 0
    for i = mark, #log do if log[i]:find("the same stay, rest only", 1, true) then again = again + 1 end end
    assert(again >= 10, "standing there: only " .. again .. " checks")
    assert(S.misses == 1 and (S.emptyStreak or 0) == 1, "an hour at one spot learned 'empty' " .. tostring(S.misses) .. " times")
    assert(ns.NodeChance(S) >= c1, "standing there lowered the chance again")
    assert(ns.IsOnCooldown(S) or S.emptyUntil, "no rest any more while standing there")

    -- (2) small moves at the spot (never 60 yd away): still the same stay
    Setup()
    for _ = 1, 8 do At(45) advance(150) At(55) advance(150) At(10) advance(150) end
    assert(S.misses == 1, "small moves at the spot learned 'empty' " .. tostring(S.misses) .. " times")

    -- (3) gone (100 yd) and back: a new visit, learned again
    Setup()
    At(100) advance(2)
    assert(not S.learnStay, "100 yd away is not gone from the spot")
    At(0) advance(180)
    assert(S.misses == 2, "gone and back: " .. tostring(S.misses) .. " learned (expected 2)")

    -- (4) a stop and a new run at the same spot: the same stay
    Setup()
    ns.StopRun() advance(300)
    ns.StartRun("herb", Z) advance(200)
    assert(S.misses == 1 and S.learnStay, "a new run at the same spot learned 'empty' again")

    -- (5) a real find later: counted, and a check of the same stay that
    -- learned nothing is not "taken back" (the miss of the first visit stays)
    Setup()
    advance(150) -- the next check of this stay: rest only
    assert(S.misses == 1, "test setup: the second check learned")
    Harvest() advance(5)
    assert(S.hits == 1 and S.misses == 1, ("found after a check that learned nothing: hits %s, misses %s (expected 1, 1)"):format(tostring(S.hits), tostring(S.misses)))
    assert(not S.learnStay, "a find did not end the empty stay")

    -- (6) a gather without loot of its own (uncertain): not judged, nothing learned
    Setup()
    At(100) advance(2) At(0) advance(150) -- a new visit: the check comes in 25 s
    local before = S.misses
    seq = seq + 1
    fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "o1u" .. seq, 2366) advance(2)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "o1u" .. seq, 2366)
    advance(40)
    assert(S.misses == before, "an uncertain gather was learned as empty")

    ns.StopRun()
    ns.db.arriveDist, ns.db.debug = saved.arrive, saved.debug
    ns.db.nodes[Z] = nil
    ns.NotifyNodesChanged()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    advance(1)
end)
step("Skill plan: unknown prices, fees, training, what you can make yourself (v0.1.14)", function()
    local d = ns.CraftData
    local saved = { known = d.Known, have = d.Have, rank = ns.ProfessionRank, price = ns.GetPrice, vendor = ns.db.vendorPrices }
    local recipes = GathercraftRecipeData.professions
    local knownBy = {} -- profession -> { recipe name -> packed }
    d.Known = function(p) return knownBy[p] or {} end
    d.Have = function() return 0 end
    local ranks = {} -- profession -> { rank, maxRank }
    ns.ProfessionRank = function(p) local r = ranks[p] if r then return r[1], r[2] end end
    ns.db.vendorPrices = {}
    local function Texts()
        local list = {}
        for _, o in ipairs(allFrames) do
            local t = o.GetText and o:GetText()
            if type(t) == "string" and o.IsShown and o:IsShown() then list[#list + 1] = t end
        end
        return list
    end
    local function Shows(text)
        for _, t in ipairs(Texts()) do if t:find(text, 1, true) then return t end end
    end
    local function Mat(mats, id) for _, m in ipairs(mats) do if m.id == id then return m end end end

    -- (1) no prices at all: the missing materials count as unknown, never as 0
    ns.GetPrice = function() end
    local steps, mats, total, _, unknown, info = ns.SkillPlan("Blacksmithing", 1, 75)
    local noPrice = 0
    for _, m in ipairs(mats) do if m.missing > 0 and not m.cost then noPrice = noPrice + 1 end end
    assert(#steps > 0 and noPrice > 0 and unknown, "test setup: a plan without prices")
    assert(info.matsUnknown == noPrice and total == 0, ("%d missing materials without a price counted as %d"):format(noPrice, info.matsUnknown))
    ranks.Blacksmithing = { 1, 75 }
    ns.ShowSkillPlan("Blacksmithing") advance(1)
    assert(Shows((ns.L["Missing materials cost: unknown (%d without a price)"]):format(noPrice)), "the total shows a price where none is known")
    assert(Shows(ns.L["~ = planned with an estimated price."]), "estimated prices are not explained")

    -- (2) every price known: the total is the sum by hand
    ns.GetPrice = function() return 100, "AH scan" end
    steps, mats, total, _, _, info = ns.SkillPlan("Blacksmithing", 1, 75)
    local sum = 0
    for _, m in ipairs(mats) do if not m.madeFrom then sum = sum + m.missing * 100 end end
    assert(info.matsUnknown == 0 and total == sum and sum > 0, ("total %d, by hand %d"):format(total, sum))

    -- (3) trainer fees of the recipes you don't know yet, once each; a known one costs nothing
    local fees, seen, firstTrainer = 0, {}, nil
    for _, s in ipairs(steps) do
        local r = s.recipe
        if r.how == "trainer" and not seen[r] then seen[r] = true fees = fees + r.fee firstTrainer = firstTrainer or r end
    end
    assert(firstTrainer and info.fees == fees and info.feesUnknown == 0, ("fees %d, by hand %d"):format(info.fees, fees))
    knownBy.Blacksmithing = { [firstTrainer.key] = recipes.Blacksmithing[firstTrainer.key] }
    local steps2, _, _, _, _, info2 = ns.SkillPlan("Blacksmithing", 1, 75)
    assert(info2.fees == fees - firstTrainer.fee, "a recipe you know still costs its trainer fee")
    for i, s in ipairs(steps2) do -- knowing it changes how you learn it, not the choice
        assert(s.recipe.key == steps[i].recipe.key and s.crafts == steps[i].crafts, "knowing a recipe changed the plan")
    end
    knownBy.Blacksmithing = nil
    -- recipe items from vendors: counted, with a price only where a vendor showed one
    local csteps, _, _, _, _, cinfo = ns.SkillPlan("Cooking", 1, 75)
    local items, oneItem = 0, nil
    seen = {}
    for _, s in ipairs(csteps) do
        local r = s.recipe
        if r.how == "vendor" and not seen[r] then seen[r] = true items = items + 1 oneItem = oneItem or r.recipeItem end
    end
    assert(items > 0 and cinfo.items == items and cinfo.itemsUnknown == items and cinfo.itemCost == 0, "recipe items to buy")
    ns.db.vendorPrices[oneItem] = 500
    _, _, _, _, _, cinfo = ns.SkillPlan("Cooking", 1, 75)
    assert(cinfo.itemCost == 500 and cinfo.itemsUnknown == items - 1, "a recipe item price a vendor showed")
    ns.db.vendorPrices[oneItem] = nil

    -- (4) training: your own maximum, else the usual caps (assumed)
    ranks.Blacksmithing = { 75, 75 }
    ns.ShowSkillPlan("Blacksmithing") advance(1)
    assert(Shows((ns.L["Train the next rank at your trainer (needed at %d)."]):format(75)), "no training step at your maximum")
    assert(Shows((ns.L["Your skill: %d / %d"]):format(75, 75)), "your maximum is not shown")
    ranks.Blacksmithing = { 75 } -- the maximum is unknown
    ns.ShowSkillPlan("Blacksmithing") advance(1)
    assert(Shows((ns.L["Train the next rank at your trainer (at ~%d, cap assumed)."]):format(75)) and Shows("~150"), "assumed caps are not marked")

    -- (5) what you can make yourself: profession, known recipe and its skill
    -- (smelting for a blacksmith)
    local cheap = { [2842] = 1, [3470] = 1, [2840] = 1, [2841] = 1, [2775] = 1, [2770] = 1, [2771] = 1 }
    ns.GetPrice = function(id) return cheap[id] or 1000, "AH scan" end
    local function Bars(from, to)
        local _, m = ns.SkillPlan("Blacksmithing", from, to)
        return Mat(m, 2840), Mat(m, 2841), Mat(m, 3470), m
    end
    local copper, bronze, _, m = Bars(75, 150)
    assert(bronze and not bronze.madeFrom and bronze.missing > 0, "no Mining: bronze bars are not bought")
    assert(not copper and not Mat(m, 2770) and not Mat(m, 2771), "no Mining: bars broken down into ore anyway")
    knownBy.Mining = recipes.Mining
    ranks.Mining = { 30, 75 } -- Smelt Bronze needs 65
    copper, bronze = Bars(75, 150)
    assert(bronze and not bronze.madeFrom, "Mining 30: bronze bars (65) are made")
    ranks.Mining = { 150, 150 }
    copper, bronze = Bars(75, 150)
    assert(bronze and bronze.madeFrom and bronze.madeFrom.prof == "Mining", "Mining 150: bronze bars are not made")
    assert(copper and copper.madeFrom, "Mining 150: the copper bars inside the bronze are not made")
    ranks.Mining = nil -- learned recipes, but the profession is gone
    _, bronze = Bars(75, 150)
    assert(bronze and not bronze.madeFrom, "without the profession: bars are made")
    knownBy.Mining = nil
    -- the same profession: Rough Grinding Stone (25) for Silver Skeleton Keys
    local _, _, stone = Bars(75, 90)
    assert(stone and not stone.madeFrom and stone.missing > 0, "an unknown recipe of your own profession is made")
    knownBy.Blacksmithing = { ["Rough Grinding Stone"] = recipes.Blacksmithing["Rough Grinding Stone"] }
    _, _, stone = Bars(75, 90)
    assert(stone and stone.madeFrom and stone.madeFrom.prof == "Blacksmithing", "a known recipe of your profession is not made")
    _, _, stone = Bars(20, 90)
    assert(stone and not stone.madeFrom, "made below its required skill (25)")
    knownBy.Blacksmithing = nil

    -- (6) a recipe you learned from a quest stays usable; not learned, it is left
    -- out. Kaldorei Spider Kabob (quest reward, needs 10): its one ingredient is
    -- cheap, everything else expensive
    cheap = { [5465] = 1 }
    local function Uses(name)
        for _, s in ipairs(ns.SkillPlan("Cooking", 15, 40)) do if s.recipe.key == name then return s.recipe.how end end
    end
    assert(not Uses("Kaldorei Spider Kabob"), "a quest recipe you don't have is planned")
    knownBy.Cooking = { ["Kaldorei Spider Kabob"] = recipes.Cooking["Kaldorei Spider Kabob"] }
    assert(Uses("Kaldorei Spider Kabob") == "known", "a quest recipe you learned is not used")
    knownBy.Cooking = nil

    d.Known, d.Have, ns.ProfessionRank, ns.GetPrice, ns.db.vendorPrices = saved.known, saved.have, saved.rank, saved.price, saved.vendor
    if _G.GathercraftSkillPlan then _G.GathercraftSkillPlan:Hide() end
end)
step("Skill plan: hints, fees and totals fit, also long translations and big amounts (v0.1.14)", function()
    -- no real font metrics: the estimate of TextHeight (6 px a letter, 11 px
    -- a CJK sign) shows whether the window makes room, not how the game draws it
    local function Px(t)
        t = (t or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        local px = 0
        for ch in t:gmatch("[%z\1-\127\194-\244][\128-\191]*") do px = px + (#ch >= 3 and 11 or 6) end
        return px
    end
    local d = ns.CraftData
    local saved = { known = d.Known, have = d.Have, rank = ns.ProfessionRank, price = ns.GetPrice, vendor = ns.db.vendorPrices,
        height = methods.GetStringHeight }
    methods.GetStringHeight = TextHeight
    d.Known = function() return {} end
    d.Have = function() return 0 end
    ns.GetPrice = function() end -- no prices: estimated steps, unknown totals
    ns.db.vendorPrices = {}
    local rank = {}
    ns.ProfessionRank = function(p) if p == rank.prof then return rank[1], rank[2] end end
    local scroll = _G.GathercraftSkillPlanScroll
    local function Check(what)
        local win = _G.GathercraftSkillPlan
        local content
        for _, o in ipairs(allFrames) do if o.__parent == scroll and o.__kind == "Frame" then content = o end end
        assert(content, "test setup: the list of the planner")
        local rows = {}
        for _, o in ipairs(allFrames) do
            if o.__parent == content and o.left and o:IsShown() and o.__pts and o.__pts.TOPLEFT then rows[#rows + 1] = o end
        end
        table.sort(rows, function(a, b) return a.__pts.TOPLEFT[2] > b.__pts.TOPLEFT[2] end)
        local hints = 0
        for i, row in ipairs(rows) do
            local text, y, h = row.left:GetText() or "", -row.__pts.TOPLEFT[2], row.__h or 18
            if (row.right:GetText() or "") == "" then
                -- a hint: the whole width, and as high as its wrapped text
                hints = hints + 1
                assert(row.left.__w >= 480, ("%s: a hint in a narrow column (%d px): %s"):format(what, row.left.__w or 0, text))
                assert(h >= TextHeight(row.left), ("%s: %d px row for %d px of text: %s"):format(what, h, TextHeight(row.left), text))
            end
            local nextRow = rows[i + 1]
            if nextRow then
                assert(y + h <= -nextRow.__pts.TOPLEFT[2], ("%s: rows overlap at %q"):format(what, text))
            end
        end
        assert(hints > 0, what .. ": test setup: no hints")
        -- the note and the total at the bottom of the card (by their place, any language)
        local note, total
        for _, o in ipairs(allFrames) do
            local at = o.__parent == win and o.__kind == "FontString" and o.__pts and o.__pts.BOTTOMLEFT
            if at and at[2] == 24 then note = o elseif at and at[2] == 42 then total = o end
        end
        assert(note and total, what .. ": test setup: note and total")
        local nt, tt = note:GetText() or "", total:GetText() or ""
        assert(Px(nt) <= 500, ("%s: the note at the bottom needs %d px of 500: %s"):format(what, Px(nt), nt))
        assert(tt ~= "" and total.__w and Px(tt) <= total.__w, ("%s: the total needs %d px of %s: %s"):format(what, Px(tt), tostring(total.__w), tt))
    end
    -- training at your maximum, fees, estimated prices, unknown total
    rank.prof, rank[1], rank[2] = "Blacksmithing", 75, 75
    ns.ShowSkillPlan("Blacksmithing") advance(1)
    Check("Blacksmithing 75/75")
    -- caps assumed (no maximum)
    rank[2] = nil
    ns.ShowSkillPlan("Blacksmithing") advance(1)
    Check("Blacksmithing, cap assumed")
    -- recipe items with a big price and without one
    rank.prof, rank[1], rank[2] = "Cooking", 1, 75
    local _, _, _, _, _, info = ns.SkillPlan("Cooking", 1, 75)
    for _, s in ipairs((ns.SkillPlan("Cooking", 1, 75))) do
        if s.recipe.how == "vendor" then ns.db.vendorPrices[s.recipe.recipeItem] = 12345678 break end
    end
    assert(info.items > 1, "test setup: recipe items")
    ns.ShowSkillPlan("Cooking") advance(1)
    Check("Cooking, recipe items 1234g")

    d.Known, d.Have, ns.ProfessionRank, ns.GetPrice, ns.db.vendorPrices = saved.known, saved.have, saved.rank, saved.price, saved.vendor
    methods.GetStringHeight = saved.height
    _G.GathercraftSkillPlan:Hide()
end)
step("Farm Spots: the Go buttons of reused rows follow a language change (v0.1.14)", function()
    -- rows are made once and reused: their buttons must keep the English key, so
    -- a switch without reload relabels them (both ways: de -> en and en -> de)
    local keep = ns.db.language
    local scroll = _G.GathercraftFarmScroll
    local function GoButtons()
        local list = {}
        for _, f in ipairs(allFrames) do
            local row = f.__kind == "Button" and f.__parent
            if row and row.go == f and row.__parent and row.__parent.__parent == scroll then list[#list + 1] = f end
        end
        return list
    end
    local function Switch(lang)
        ns.db.language = lang ns.ApplyLanguage() _G.GathercraftOptions:Refresh()
        ns.ToggleMain("overview") advance(1) ns.ToggleMain("farm") advance(1)
        local list = GoButtons()
        assert(#list > 0, "no zone rows on Farm Spots")
        for _, b in ipairs(list) do
            assert(b.__text == ns.L["Go"], ("%s: Go button shows %q, expected %q"):format(lang, tostring(b.__text), ns.L["Go"]))
        end
    end
    -- like a German player at login: new rows are made while German is on
    -- ("Los"). 40 more Kalimdor zones (mock) need more rows; you stand in
    -- Mulgore, so Kalimdor is the continent shown
    local start, map = ns.Language(), player.map
    player.map = 1412
    local info = C_Map.GetMapInfo
    C_Map.GetMapInfo = function(id)
        if id >= 1460 and id <= 1499 then return { mapID = id, name = "Extra" .. id, mapType = 3, parentMapID = 1414 } end
        return info(id)
    end
    -- the rows of the zones known so far (past the 60 s list cache), then German,
    -- then the new zones: their rows are made in German
    ns.ToggleMain("overview") advance(61) ns.ToggleMain("farm") advance(1)
    local before = #GoButtons()
    ns.db.language = "deDE" ns.ApplyLanguage() _G.GathercraftOptions:Refresh()
    for id = 1460, 1499 do
        local list = {}
        for k = 1, 8 do list[k] = { id = "o1618", name = "Peacebloom", type = "herb", x = 0.1 * k, y = 0.5, count = 3, last = 1 } end
        ns.db.nodes[id] = list
    end
    ns.ToggleMain("overview") advance(61) ns.ToggleMain("farm") advance(1)
    assert(#GoButtons() > before, "no new rows made while German was on")
    -- then every language this client offers, de -> en and en -> de included,
    -- and back to the start
    local order = { start:sub(1, 2) == "en" and "deDE" or "enUS", start:sub(1, 2) == "en" and "enUS" or "deDE" }
    for _, lang in ipairs(ns.UsableLanguages()) do
        if lang.code ~= "auto" and lang.code ~= order[1] and lang.code ~= order[2] then order[#order + 1] = lang.code end
    end
    order[#order + 1] = "deDE"
    order[#order + 1] = start
    for _, lang in ipairs(order) do Switch(lang) end
    ns.HideMain()
    for id = 1460, 1499 do ns.db.nodes[id] = nil end
    C_Map.GetMapInfo = info
    player.map = map
    ns.db.language = keep ns.ApplyLanguage()
    ns.NotifyNodesChanged() advance(2)
end)
step("Sharing shows what it does; chests can be hidden", function()
    slash("sync on")
    local function said(text)
        for _, l in ipairs(log) do if l:find(text, 1, true) then return true end end
    end
    -- a friend's (guild) spot arrives: one line in chat a little later
    for i, l in ipairs(log) do if l:find(ns.GetZoneName(1412), 1, true) then log[i] = "" end end
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:1412;o1620,h,6111,2222,785", "GUILD", "Guildie Three")
    advance(200) -- at most one note every 3 minutes (an earlier step may just have had one)
    assert(said(ns.GetZoneName(1412)), "no note about spots from other players")
    local peers, received = ns.SyncSummary()
    assert(received >= 1, "summary without the received spot")
    -- the note can be turned off
    ns.db.sync.announceOff = true
    for i, l in ipairs(log) do if l:find(ns.GetZoneName(1412), 1, true) then log[i] = "" end end
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:1412;o1619,h,3555,4666,2449", "GUILD", "Guildie Three")
    advance(240)
    assert(not said(ns.GetZoneName(1412)), "note shown although turned off")
    ns.db.sync.announceOff = nil
    -- chests: off in the options = no pins
    ns.db.nodes[1450] = { { id = "o2843", name = "Battered Chest", type = "chest", x = 0.5, y = 0.5, count = 1, last = 1 } }
    HBD_ADDS["Gathercraft"] = { world = 0, mini = 0 }
    ns.db.chestsHidden = true
    ns.NotifyNodesChanged() advance(2)
    local hidden = HBD_ADDS["Gathercraft"].world
    ns.db.chestsHidden = nil
    HBD_ADDS["Gathercraft"] = { world = 0, mini = 0 }
    ns.NotifyNodesChanged() advance(2)
    assert(HBD_ADDS["Gathercraft"].world > hidden, "chests not back on the map")
    -- the Zones tab is for "Start run": an unticked zone stays on the map,
    -- unless the option says the map follows it (v0.1.13)
    local chest = ns.db.nodes[1450][1]
    local pins = LibStub("HereBeDragons-Pins-2.0")
    local add = pins.AddWorldMapIconMap
    local chestPinned
    pins.AddWorldMapIconMap = function(self, ref, frame, mapID, x, y, ...)
        if mapID == 1450 and x == chest.x and y == chest.y then chestPinned = true end
        return add(self, ref, frame, mapID, x, y, ...)
    end
    ns.db.disabledZones[1450] = true
    chestPinned = false
    ns.NotifyNodesChanged() advance(2)
    assert(chestPinned, "an unticked zone hides its pins")
    ns.db.mapFollowsZones = true
    chestPinned = false
    ns.NotifyNodesChanged() advance(2)
    assert(not chestPinned, "the option does not hide the unticked zone")
    pins.AddWorldMapIconMap = add
    ns.db.mapFollowsZones, ns.db.disabledZones[1450] = nil, nil
    ns.db.nodes[1450] = nil
    ns.NotifyNodesChanged() advance(1)
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
step("Crafting: costs without a price show ? or ~, never 0c (v0.1.14)", function()
    -- found in testing: Smelting showed "Costs 0c" for every recipe whose ores had no price yet
    local T, Q = ns.CraftCostText, ns.L["|cff777777?|r"]
    local function R(cost, unknown, n, guessed)
        local rs = {}
        for i = 1, n do rs[i] = {} end
        return { cost = cost, costUnknown = unknown, reagents = rs, guessed = guessed }
    end
    assert(T(R(0, 2, 2)) == Q, "no reagent has a price: " .. T(R(0, 2, 2)))
    local part = T(R(40, 1, 3))
    assert(part:sub(1, 1) == "~" and part:find(ns.Money(40), 1, true), "some reagents have a price: " .. part)
    assert(T(R(40, 0, 3)) == ns.Money(40), "all reagents have a price: " .. T(R(40, 0, 3)))
    assert(T(R(0, 0, 2)) == ns.Money(0), "materials that really cost nothing: " .. T(R(0, 0, 2)))
    assert(T(R(40, 0, 3, true)):sub(1, 1) == "~", "an estimated vendor price lost its ~")
    -- Peacebloom has no price for a moment: Minor Healing Potion has one
    -- reagent without a price
    local oldPrice, oldVendor = ns.GetPrice, ns.db.vendorPrices and ns.db.vendorPrices[2447]
    ns.GetPrice = function(id, ...) if id == 2447 then return nil end return oldPrice(id, ...) end
    if ns.db.vendorPrices then ns.db.vendorPrices[2447] = nil end
    -- the rows: the count fits their reagents; nothing with an unknown price
    -- ranks among the known ones, and those are in name order
    local rows = ns.CraftAdvice()
    local seenMissing, lastName, partial
    for _, r in ipairs(rows) do
        local u = 0
        for _, p in ipairs(r.reagents) do if not p.cost then u = u + 1 end end
        assert(r.costUnknown == u, ("%s: %d reagents without a price counted, %d really"):format(r.name, r.costUnknown, u))
        if r.missing then
            assert(not seenMissing or not lastName or r.enchant or lastName <= r.name, "unknown prices not in name order: " .. r.name)
            seenMissing, lastName = true, r.name
        else
            assert(not seenMissing, "a recipe with a known profit after one with an unknown price: " .. r.name)
        end
        if r.costUnknown > 0 and r.costUnknown < #r.reagents and not r.enchant and r.learned then partial = partial or r end
    end
    assert(partial, "test setup: no learned recipe with some reagents without a price")
    assert(T(partial):sub(1, 1) == "~", partial.name .. ": costs with a reagent without a price: " .. T(partial))
    -- its tooltip: materials not as a plain sum, the count without a price, profit ?
    local oldTab = ns.db.craftTab
    ns.ToggleMain("craft") advance(1)
    for _, f in ipairs(allFrames) do -- the "Mine" tab: the recipes you know
        if f.full == "Mine" and f.__scripts and f.__scripts.OnClick then f.__scripts.OnClick(f) end
    end
    local row
    for _, f in ipairs(allFrames) do
        if f.data == partial or (f.data and f.data.key == partial.key and f:IsShown()) then
            if f.__scripts and f.__scripts.OnEnter then row = f end
        end
    end
    assert(row, "test setup: no row for " .. partial.name)
    local shown = row.cost and row.cost:GetText() or ""
    assert(shown:sub(1, 1) == "~", "Costs column with a reagent without a price: " .. shown)
    local oldDouble, mats, profit = GameTooltip.AddDoubleLine, nil, nil
    GameTooltip.AddDoubleLine = function(_, l, r)
        if l == ns.L["Materials"] then mats = r end
        if l == ns.L["Profit per craft"] then profit = r end
    end
    row.__scripts.OnEnter(row)
    GameTooltip.AddDoubleLine = oldDouble
    local without = (ns.L["(+%d without a price)"]):format(partial.costUnknown)
    assert(mats and mats:find(without, 1, true) and (mats:find(Q, 1, true) or mats:find("~", 1, true)), "materials line: " .. tostring(mats))
    assert(profit and profit:find(Q, 1, true), "profit with an unknown price: " .. tostring(profit))
    if row.__scripts.OnLeave then row.__scripts.OnLeave(row) end
    ns.GetPrice = oldPrice
    if ns.db.vendorPrices then ns.db.vendorPrices[2447] = oldVendor end
    ns.db.craftTab = oldTab
    ns.HideMain()
end)
step("V: a product without a price sells for ?, never 0c (v0.1.14)", function()
    -- found in testing: Crafting > Leather showed "Sells for 0c" in every row
    -- while no price source knew the products yet
    local V, Q = ns.CraftValueText, ns.L["|cff777777?|r"]
    assert(V({ value = 0 }) == Q, "no price source: " .. V({ value = 0 }))
    assert(V({ value = 0, valueSource = "vendor" }) == ns.Money(0), "a vendor price of 0 is a known value: " .. V({ value = 0, valueSource = "vendor" }))
    assert(V({ value = 1234, valueSource = "AH scan" }, true) == ns.Money(1234, true), "a known price: " .. V({ value = 1234, valueSource = "AH scan" }, true))
    -- a learned recipe whose product has no price for a moment
    local pick
    for _, r in ipairs(ns.CraftAdvice()) do
        if r.learned and not r.enchant and r.product and r.valueSource then pick = r break end
    end
    assert(pick, "test setup: no learned recipe with a priced product")
    local oldPrice = ns.GetPrice
    ns.GetPrice = function(id, ...) if id == pick.product then return nil end return oldPrice(id, ...) end
    local again
    for _, r in ipairs(ns.CraftAdvice()) do if r.key == pick.key and r.prof == pick.prof then again = r end end
    assert(again and again.missing and not again.valueSource, pick.name .. ": a product without a price still has a value source")
    assert(V(again, true) == Q, pick.name .. ": sells for " .. V(again, true))
    -- its row says ?, its tooltip "no price"
    local oldTab = ns.db.craftTab
    local function Row()
        ns.ToggleMain("craft") advance(1)
        for _, f in ipairs(allFrames) do -- the "Mine" tab: the recipes you know
            if f.full == "Mine" and f.__scripts and f.__scripts.OnClick then f.__scripts.OnClick(f) end
        end
        for _, f in ipairs(allFrames) do
            if f.data and f.data.key == pick.key and f.data.prof == pick.prof and f:IsShown() and f.__scripts and f.__scripts.OnEnter then return f end
        end
    end
    local row = Row()
    assert(row, "test setup: no row for " .. pick.name)
    local shown = row.value and row.value:GetText() or ""
    assert(shown == Q, "Sells for column without a price: " .. shown)
    local oldDouble, sells = GameTooltip.AddDoubleLine, nil
    GameTooltip.AddDoubleLine = function(_, l, r) if l == ns.L["Sells for"] then sells = r end end
    row.__scripts.OnEnter(row)
    GameTooltip.AddDoubleLine = oldDouble
    assert(sells == ns.L["|cffff7070no price|r"], "Sells for in the tooltip without a price: " .. tostring(sells))
    if row.__scripts.OnLeave then row.__scripts.OnLeave(row) end
    -- the price is known again: the real value is back
    ns.GetPrice = oldPrice
    ns.HideMain()
    row = Row()
    assert(row, "test setup: no row for " .. pick.name .. " with its price back")
    shown = row.value and row.value:GetText() or ""
    assert(shown == ns.Money(pick.value, true), "Sells for with the price back: " .. shown)
    ns.db.craftTab = oldTab
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
    local function Peacebloom()
        for _, n in ipairs(ns.db.nodes[1412]) do if n.id == "o1618" then return n.name end end
    end
    local before = Peacebloom()
    ns.db.language = "deDE" ns.ApplyLanguage()
    -- node names follow the game's language (what you read in the world), not the
    -- addon's: the switch leaves them; shipped name where the game's language has one
    -- (Data/NodeNames.lua has none for itIT: the name stays as it was)
    local de = Peacebloom()
    local shipped = (GathercraftNodeNames[LOCALE] or {})[1618]
    local want = LOCALE:sub(1, 2) == "en" and "Peacebloom" or shipped or before
    assert(de == want and de == before, ("node name in the game's language: %s (before %s), expected %s"):format(
        tostring(de), tostring(before), tostring(want)))
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
step("World map pins in a ring (default), normal by option", function()
    ns.db.worldPinStyle = nil
    ns.NotifyNodesChanged() advance(2)
    local ringed, plain = 0, 0
    for _, f in ipairs(allFrames) do
        if f.node and f.isMini == nil and not f.isTarget and f.icon then
            if f.ring and f.ring:IsShown() then ringed = ringed + 1 else plain = plain + 1 end
        end
    end
    assert(ringed > 0, "no world map pin in a ring")
    ns.db.worldPinStyle = "normal"
    ns.NotifyNodesChanged() advance(2)
    local ringedAfter = 0
    for _, f in ipairs(allFrames) do
        if f.node and f.isMini == nil and not f.isTarget and f.icon and f.ring and f.ring:IsShown() then ringedAfter = ringedAfter + 1 end
    end
    assert(ringedAfter == 0, "world map pins still in rings with the normal style")
    ns.db.worldPinStyle = nil
    ns.NotifyNodesChanged() advance(2)
end)
step("Herbs / minerals switch button", function()
    local btn = GathercraftTrackButton
    assert(btn, "no switch button")
    -- only one of the two known: no button
    ns.UpdateTrackButton()
    assert(not btn:IsShown(), "button shown without both tracking spells")
    local realKnown = IsPlayerSpell
    IsPlayerSpell = function(id) return id == 2383 or id == 2580 or realKnown(id) end
    ns.UpdateTrackButton()
    assert(btn:IsShown(), "button not shown with both tracking spells")
    -- every click switches to the other one
    local first = btn:GetAttribute("spell")
    assert(btn:GetAttribute("type") == "spell" and first, "no spell on the button")
    btn.__scripts.PreClick(btn) btn.__scripts.PostClick(btn) advance(1)
    local second = btn:GetAttribute("spell")
    assert(second and second ~= first, "click did not switch: " .. tostring(first) .. " / " .. tostring(second))
    btn.__scripts.PreClick(btn) btn.__scripts.PostClick(btn) advance(1)
    assert(btn:GetAttribute("spell") == first, "second click did not switch back")
    assert(pcall(btn.__scripts.OnEnter, btn), "tooltip")
    -- shift-drag moves it along the minimap's edge
    local realShift, realCursor = IsShiftKeyDown, GetCursorPosition
    IsShiftKeyDown = function() return true end
    GetCursorPosition = function() return 400, 300 end
    btn.__scripts.OnDragStart(btn)
    assert(btn.__scripts.OnUpdate, "dragging does not follow the cursor")
    assert(pcall(btn.__scripts.OnUpdate, btn, 0.1), "drag update")
    btn.__scripts.OnDragStop(btn)
    assert(not btn.__scripts.OnUpdate and ns.db.trackButtonAngle, "drag did not end or save the angle")
    IsShiftKeyDown, GetCursorPosition = realShift, realCursor
    ns.db.trackButtonAngle = nil
    -- option off: hidden
    ns.db.trackButtonHidden = true
    ns.UpdateTrackButton()
    assert(not btn:IsShown(), "option off, button still shown")
    ns.db.trackButtonHidden = nil
    -- the macro for the action bar: made once, then reused, on the cursor
    local macros, picked = {}, nil
    GetMacroIndexByName = function(n) for i, m in ipairs(macros) do if m.name == n then return i end end return 0 end
    GetNumMacros = function() return #macros, 0 end
    CreateMacro = function(n, icon, body) macros[#macros + 1] = { name = n, body = body } return #macros end
    EditMacro = function(i, n, icon, body) macros[i].body = body return i end
    PickupMacro = function(i) picked = i end
    ns.TrackMacro()
    assert(#macros == 1 and macros[1].body == "/click GathercraftTrackButton" and picked == 1, "macro not made")
    ns.TrackMacro()
    assert(#macros == 1, "macro made twice")
    InCombatLockdown = function() return true end
    picked = nil
    ns.TrackMacro()
    assert(picked == nil, "macro touched in combat")
    InCombatLockdown = function() return false end
    GetMacroIndexByName, GetNumMacros, CreateMacro, EditMacro, PickupMacro = nil, nil, nil, nil, nil
    IsPlayerSpell = realKnown
    ns.UpdateTrackButton()
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
step("Fishing: a catch counts once (loot events twice, late, autoloot on and off)", function()
    -- seen on the live server (05.11.): one fish, the panel went from 12 to 14
    local prices = ns.db.prices[next(ns.db.prices)]
    prices.items[6303], prices.items[6291] = 500, 300
    prices.seen[6303], prices.seen[6291] = time(), time()
    local worth = ns.LootValue({ { id = 6303, qty = 2 } })
    local other = ns.LootValue({ { id = 6291, qty = 2 } })
    assert(worth > 0 and other > 0 and worth ~= other, "test setup: no prices for the fish")
    local wasDebug, mark = ns.db.debug, #log
    ns.db.debug = true
    IsFishingLoot = function() return true end
    local function Fish(item)
        return { { guid = "GameObject-0-1-1-1-35591-FFFF01", item = item or 6303, qty = 2 } }
    end
    local function Cast()
        fire("UNIT_SPELLCAST_CHANNEL_START", "player", "c9", 7620)
        fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "c9", 7620)
    end
    local session0
    local function Fresh()
        advance(3)
        ns.StopFishing()
        session0 = ns.SessionValue()
        Cast()
    end
    local function Expect(what, catches, value)
        local f = ns.FishingSession()
        assert(f, what .. ": no fishing session")
        assert(f.catches == catches, ("%s: %d catches, expected %d"):format(what, f.catches, catches))
        assert(f.items == catches * 2, ("%s: %d items, expected %d"):format(what, f.items, catches * 2))
        assert(f.value == value, ("%s: value %s, expected %s"):format(what, tostring(f.value), tostring(value)))
        local booked = ns.SessionValue() - session0
        assert(booked == value, ("%s: session value %s, expected %s"):format(what, tostring(booked), tostring(value)))
    end
    -- what the window does when it opens by hand: the event twice, then closed
    local function Window(item)
        loot = Fish(item)
        fire("LOOT_READY", false) fire("LOOT_READY", false) fire("LOOT_OPENED", false)
        loot = {}
        fire("LOOT_CLOSED")
    end

    -- autoloot off: LOOT_READY twice, then LOOT_CLOSED
    Fresh() Window()
    Expect("event twice", 1, worth)
    -- LOOT_OPENED is only for the debug line: alone it counts nothing
    Fresh()
    loot = Fish() fire("LOOT_OPENED", false)
    loot = {} fire("LOOT_CLOSED")
    Expect("LOOT_OPENED alone", 0, 0)
    -- ... and it doesn't open the way for a repeat between two LOOT_READY
    Fresh()
    loot = Fish() fire("LOOT_READY", false) fire("LOOT_OPENED", false) advance(3) fire("LOOT_READY", false)
    loot = {} fire("LOOT_CLOSED")
    Expect("LOOT_OPENED between two events", 1, worth)
    -- a late LOOT_READY after LOOT_CLOSED, the same loot
    Fresh()
    loot = Fish() fire("LOOT_READY", false) fire("LOOT_CLOSED")
    advance(1) fire("LOOT_READY", false)
    loot = {} fire("LOOT_CLOSED")
    Expect("late event, same loot", 1, worth)
    -- the window stays open longer than the time limit, the event comes again
    Fresh()
    loot = Fish() fire("LOOT_READY", false)
    advance(3) fire("LOOT_READY", false)
    loot = {} fire("LOOT_CLOSED")
    Expect("window left open", 1, worth)
    -- two catches, the same fish
    Fresh() Window()
    advance(20) Cast() Window()
    Expect("two catches", 2, worth * 2)
    -- the same fish again, just past the time limit
    Fresh() Window()
    advance(1.6) Cast() Window()
    Expect("two catches, the same fish, 1.6 s apart", 2, worth * 2)
    -- two catches shortly after each other, different fish
    Fresh() Window()
    advance(0.5) Cast() Window(6291)
    Expect("two quick catches", 2, worth + other)
    -- LOOT_CLOSED never comes: the next cast opens the way for the next catch
    Fresh()
    loot = Fish() fire("LOOT_READY", false) fire("LOOT_READY", false)
    advance(2) Cast() fire("LOOT_READY", false)
    loot = {} fire("LOOT_CLOSED")
    Expect("no LOOT_CLOSED", 2, worth * 2)
    -- autoloot on: the loot is gone when the second event comes
    Fresh()
    loot = Fish() fire("LOOT_READY", true)
    loot = {} fire("LOOT_CLOSED") fire("LOOT_READY", true)
    Expect("autoloot, second event empty", 1, worth)
    -- autoloot on: both events before the window closes
    Fresh()
    loot = Fish() fire("LOOT_READY", true) fire("LOOT_READY", true)
    loot = {} fire("LOOT_CLOSED")
    Expect("autoloot, event twice", 1, worth)
    -- autoloot on: closed at once, cast again, then the late event
    Fresh()
    loot = Fish() fire("LOOT_READY", true) fire("LOOT_CLOSED")
    Cast()
    advance(1) fire("LOOT_READY", true)
    loot = {} fire("LOOT_CLOSED")
    Expect("autoloot, late event after the next cast", 1, worth)
    -- autoloot on: two catches
    Fresh()
    loot = Fish() fire("LOOT_READY", true) fire("LOOT_READY", true) loot = {} fire("LOOT_CLOSED")
    advance(20) Cast()
    loot = Fish() fire("LOOT_READY", true) fire("LOOT_READY", true) loot = {} fire("LOOT_CLOSED")
    Expect("autoloot, two catches", 2, worth * 2)
    -- the game doesn't call it fishing loot, an empty event comes first: the
    -- reeled-in line still counts the loot that follows, once
    IsFishingLoot = nil
    Fresh()
    loot = {} fire("LOOT_READY", false)
    Window()
    Expect("empty first event after the reel", 1, worth)
    -- other loot long after the reel is no catch
    advance(5) Window()
    Expect("other loot", 1, worth)

    -- /gcr debug shows every event in order, and what was left out
    local function Said(text)
        for i = mark + 1, #log do if log[i]:find(text, 1, true) then return true end end
        error("debug line missing: " .. text)
    end
    Said("FISH loot event LOOT_READY at ")
    Said("FISH loot event LOOT_OPENED at ")
    Said("FISH loot event LOOT_CLOSED at ")
    Said(": 1 slot(s)")
    Said("FISH repeat of the catch left out (loot window already counted)")
    Said("FISH repeat of the catch left out (same loot")
    ns.db.debug = wasDebug
end)
step("Gathering: repeated loot events book the value once (herb and ore)", function()
    -- the counter-check to the fishing fix: gathers go through the recorder
    local W = IdentityWorld()
    local prices = ns.db.prices[next(ns.db.prices)]
    prices.items[2770], prices.items[765] = 100, 200
    prices.seen[2770], prices.seen[765] = time(), time()
    W.Set({
        W.Node("o1731", "Copper Vein", 0, { type = "ore", item = 2770 }),
        W.Node("o1731", "Copper Vein", 300, { type = "ore", item = 2770 }),
        W.Node("o1617", "Silverleaf", 600, { item = 765 }),
        W.Node("o1617", "Silverleaf", 900, { item = 765 }),
    })
    local function Gather(at, name, spell, object, item, tag, repeats)
        W.At(at)
        local before = ns.SessionValue()
        local c = W.Cast(name, spell) W.Wait(2) W.Done(c, spell)
        local items = { { guid = ("GameObject-0-1-1-1-%d-%s"):format(object, tag), item = item, qty = 2 } }
        loot = items
        for _ = 1, repeats do fire("LOOT_READY", false) end
        fire("LOOT_OPENED", false)
        loot = {}
        fire("LOOT_CLOSED")
        W.Wait(3)
        return ns.SessionValue() - before
    end
    for _, g in ipairs({ { 0, "Copper Vein", 2575, 1731, 2770 }, { 600, "Silverleaf", 2366, 1617, 765 } }) do
        local once = Gather(g[1], g[2], g[3], g[4], g[5], "ONCE" .. g[4], 1)
        assert(once > 0, g[2] .. ": test setup: the gather has no value")
        local twice = Gather(g[1] + 300, g[2], g[3], g[4], g[5], "TWICE" .. g[4], 2)
        assert(twice == once, ("%s: value %s with LOOT_READY twice, %s with it once"):format(g[2], tostring(twice), tostring(once)))
    end
    W.Restore()
end)
step("Fishing: your interact settings come back (end, abort, /reload, login, own change, second cast, failed restore)", function()
    local saved = { get = GetCVar, set = SetCVar }
    local store
    local function Reset() store = { SoftTargetInteract = "1", SoftTargetInteractRange = "10", SoftTargetInteractArc = "0" } end
    GetCVar = function(k) if store[k] ~= nil then return store[k] end return saved.get(k) end
    SetCVar = function(k, v) store[k] = tostring(v) return true end
    local function Is(i, r, a, what)
        assert(store.SoftTargetInteract == i and store.SoftTargetInteractRange == r and store.SoftTargetInteractArc == a,
            ("%s: SoftTargetInteract=%s Range=%s Arc=%s, expected %s/%s/%s"):format(what, store.SoftTargetInteract,
                store.SoftTargetInteractRange, store.SoftTargetInteractArc, i, r, a))
    end
    local function Cast() fire("UNIT_SPELLCAST_CHANNEL_START", "player", "fc", 7620) end
    local function Stop() fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "fc", 7620) advance(1) end
    ns.db.fishingCVars = nil

    -- (1) a normal cast and catch
    Reset() Cast()
    Is("3", "30", "2", "line out")
    assert(ns.db.fishingCVars and ns.db.fishingCVars.SoftTargetInteractRange.orig == "10", "not kept in the saved variables")
    Stop()
    Is("1", "10", "0", "after the catch")
    assert(ns.db.fishingCVars == nil, "the saved entry is left after the catch")

    -- (2) aborted (moved, interrupted): the same stop
    Reset() Cast() advance(2) fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "fc", 7620)
    Is("1", "10", "0", "after an abort")

    -- (3) settings you already have wider stay untouched and are not recorded
    store = { SoftTargetInteract = "3", SoftTargetInteractRange = "40", SoftTargetInteractArc = "2" }
    Cast()
    assert(ns.db.fishingCVars == nil, "unchanged settings were recorded")
    Stop()
    Is("3", "40", "2", "your own wide settings")

    -- (4) you change one while the line is out: it stays as you set it
    Reset() Cast()
    store.SoftTargetInteractRange = "25"
    Stop()
    Is("1", "25", "0", "changed by you during the cast")

    -- (5) /reload with the line out: the old code is gone before the stop;
    -- the reloaded addon puts the values back at login
    Reset() Cast()
    -- the frames of the first load: from the fishing button on, as many as a
    -- load makes (a /reload drops all of them)
    local first
    for i, f in ipairs(allFrames) do if f == _G.GathercraftFishButton then first = i break end end
    local old = next(eventFrames["UNIT_SPELLCAST_CHANNEL_STOP"])
    assert(first and old, "test setup: fishing frames not found")
    local before = #allFrames
    local chunk = assert(loadfile(ROOT .. "/Fishing.lua"))
    chunk("Gathercraft", ns) -- the reloaded addon (saved variables kept: ns.db)
    local made = #allFrames - before
    for i = first, first + made - 1 do
        local f = allFrames[i]
        for _, list in pairs(eventFrames) do list[f] = nil end
        f.__scripts = {}
    end
    assert(eventFrames["UNIT_SPELLCAST_CHANNEL_STOP"][old] == nil, "test setup: the old fishing frame is still there")
    local new = next(eventFrames["UNIT_SPELLCAST_CHANNEL_STOP"])
    assert(new and new ~= old, "test setup: reloaded fishing frame missing")
    Is("3", "30", "2", "right after the reload")
    new.__scripts.OnEvent(new, "PLAYER_LOGIN")
    Is("1", "10", "0", "after login following a /reload with the line out")
    assert(ns.db.fishingCVars == nil, "the saved entry is left after login")
    Stop() -- the stop of that old cast reaches the new code: nothing more happens
    Is("1", "10", "0", "the old cast's stop after the reload")

    -- (6) login with an open entry, you changed one meanwhile
    ns.db.fishingCVars = { SoftTargetInteract = { orig = "1", ours = "3" }, SoftTargetInteractRange = { orig = "10", ours = "30" } }
    store = { SoftTargetInteract = "2", SoftTargetInteractRange = "30.000000", SoftTargetInteractArc = "0" }
    new.__scripts.OnEvent(new, "PLAYER_LOGIN")
    Is("2", "10", "0", "login with an open entry")
    assert(ns.db.fishingCVars == nil, "the open entry is left after login")

    -- (7) login without an entry: nothing is touched
    store = { SoftTargetInteract = "3", SoftTargetInteractRange = "30", SoftTargetInteractArc = "2" }
    new.__scripts.OnEvent(new, "PLAYER_LOGIN")
    Is("3", "30", "2", "login without an entry")

    -- the debug lines of cases 8-10 say what was found and done (/gcr debug)
    local wasDebug, mark = ns.db.debug, #log
    ns.db.debug = true
    local function Said(text)
        for i = mark + 1, #log do if log[i]:find(text, 1, true) then return true end end
        error("debug line missing: " .. text)
    end
    local START, STOP = "(UNIT_SPELLCAST_CHANNEL_START): SoftTargetInteractRange", "(UNIT_SPELLCAST_CHANNEL_STOP): SoftTargetInteractRange"

    -- (8) cast again before the line came in, you changed one in between:
    -- your value is what comes back, not the one from before
    Reset() Cast()
    Said("FISH start (UNIT_SPELLCAST_CHANNEL_START): no entry of an earlier cast")
    store.SoftTargetInteractRange = "25"
    mark = #log
    Cast()
    Said("FISH start " .. START .. " orig 10, ours 30, now 25 -> changed by you, yours from now on")
    Is("3", "30", "2", "second cast after your change")
    mark = #log
    Stop()
    Said("FISH restore " .. STOP .. " orig 25, ours 30, now 30 -> put back")
    Is("1", "25", "0", "second cast after your change, then the catch")
    assert(ns.db.fishingCVars == nil, "the saved entry is left after a second cast")

    -- (9) cast twice without a change: your original values come back
    Reset() Cast()
    mark = #log
    Cast()
    Said("FISH start " .. START .. " orig 10, ours 30, now 30 -> still ours, kept")
    mark = #log
    Stop()
    Said("FISH restore " .. STOP .. " orig 10, ours 30, now 30 -> put back")
    Is("1", "10", "0", "two casts, no change")

    -- (10) putting one back fails: its entry stays, the next login puts it back
    Reset() Cast()
    SetCVar = function(k, v) if k == "SoftTargetInteractRange" then error("blocked") end store[k] = tostring(v) return true end
    mark = #log
    Stop()
    Said("FISH restore " .. STOP .. " orig 10, ours 30, now 30 -> could not be put back, tried again at the next login")
    Is("1", "30", "0", "a value that could not be put back")
    assert(ns.db.fishingCVars and ns.db.fishingCVars.SoftTargetInteractRange and not ns.db.fishingCVars.SoftTargetInteract,
        "a failed restore: its entry is gone, or the others stayed")
    SetCVar = function(k, v) store[k] = tostring(v) return true end
    mark = #log
    new.__scripts.OnEvent(new, "PLAYER_LOGIN")
    Said("FISH restore (PLAYER_LOGIN): SoftTargetInteractRange orig 10, ours 30, now 30 -> put back")
    Is("1", "10", "0", "the next login after a failed restore")
    assert(ns.db.fishingCVars == nil, "the entry is left after the login put it back")
    ns.db.debug = wasDebug

    GetCVar, SetCVar = saved.get, saved.set
    ns.db.fishingCVars = nil
end)
step("Pin tooltip", function()
    for _, f in ipairs(allFrames) do
        if f.node and f.__scripts.OnEnter then f.__scripts.OnEnter(f) f.__scripts.OnLeave(f) break end
    end
end)
step("N: a node seen once says 'Seen 1 time', twice 'Seen 2 times' (pin and skill lines)", function()
    local lines
    local tt = { AddLine = function(_, t) lines[#lines + 1] = tostring(t) end, AddDoubleLine = function() end }
    local function Lines(n)
        lines = {}
        ns.AddNodeTooltipLines(tt, n)
        return table.concat(lines, "\n")
    end
    local function Has(text, what) return text:find(what, 1, true) ~= nil end
    local node = { id = "o1731", name = "Copper Vein", type = "ore", x = 0.5, y = 0.5, count = 1, last = time(), item = 2770 }
    local stats, key = ns.KindStats(), ns.KindKey(node)
    local saved = stats[key]
    stats[key] = { type = "ore", name = "Copper Vein", n = 1, ups = 1, minSkill = 1, maxUp = 1 }
    local one = Lines(node)
    assert(Has(one, ns.L["Seen 1 time"]), "count 1: " .. one)
    assert(Has(one, (ns.L["Gathered from skill %d (1 node)"]):format(1)), "skill line with 1 node: " .. one)
    if LOCALE == "enUS" then
        assert(Has(one, "Seen 1 time") and not Has(one, "1 times") and Has(one, "(1 node)") and not Has(one, "1 nodes"),
            "English singular: " .. one)
    end
    node.count, stats[key].n = 2, 2
    local two = Lines(node)
    assert(Has(two, (ns.L["Seen %d times"]):format(2)), "count 2: " .. two)
    assert(Has(two, (ns.L["Gathered from skill %d (%d nodes)"]):format(1, 2)), "skill line with 2 nodes: " .. two)
    if LOCALE == "enUS" then assert(Has(two, "Seen 2 times") and Has(two, "(2 nodes)"), "English plural: " .. two) end
    stats[key] = saved
end)
step("L: long header texts stay inside their page (zones hints wrap, list below them)", function()
    -- found in testing (deDE): the first zone hint ran over the right edge
    local hint, routeHint
    for _, f in ipairs(allFrames) do
        if f.__kind == "FontString" then
            if f.__text == ns.L["Ticked zones and materials are what Start run farms. The map still shows everything. Click + to pick single materials."] then hint = f end
            if f.__text == ns.L["Farm runs from the overview or the minimap button stay in your zone. For a route over several zones: tick them here and press Start run."] then routeHint = f end
        end
    end
    assert(hint and routeHint, "test setup: the zone hints were not found")
    assert(type(hint.__w) == "number" and hint.__w > 0, "the first zone hint has no width: it runs over the edge")
    assert(hint.__w == routeHint.__w, ("the zone hints differ in width: %s / %s"):format(tostring(hint.__w), tostring(routeHint.__w)))
    local scroll = _G.GathercraftZonesScroll
    local top = scroll and scroll.__pts and scroll.__pts.TOPLEFT
    assert(top and top[1] == routeHint, "the zone list is not anchored below the route hint")
    -- Crafting: the price line ends before the "Only recipes I know" box
    -- (page 728 wide, the box 22 wide at TOPRIGHT -268: its left edge is at 438)
    local prefix, sub, label = (ns.L["Profit after the 5%% auction cut  ·  %s"]):format(""), nil, nil
    for _, f in ipairs(allFrames) do
        if f.__kind == "FontString" then
            if type(f.__text) == "string" and f.__text:find(prefix, 1, true) == 1 then sub = f end
            if f.__text == ns.L["Only recipes I know"] then label = f end
        end
    end
    assert(sub and label, "test setup: the crafting price line or the checkbox label was not found")
    local box = label.__pts and label.__pts.LEFT and label.__pts.LEFT[1]
    local boxRight = box and box.__pts and box.__pts.TOPRIGHT
    assert(boxRight and boxRight[1] == -268 and box.__w == 22, "the crafting checkbox moved: check the price line's width with it")
    local subLeft = sub.__pts and sub.__pts.TOPLEFT and sub.__pts.TOPLEFT[1] or 0
    assert(type(sub.__w) == "number" and subLeft + sub.__w <= 728 - 268 - 22 - 8,
        ("the crafting price line reaches the checkbox: %d + %s"):format(subLeft, tostring(sub.__w)))
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
step("Welcome, what's new and the run summary (v0.1.13)", function()
    local function said(text)
        for _, l in ipairs(log) do if l:find(text, 1, true) then return true end end
    end
    -- this test started with old WoWFFarm data: an update, no welcome
    assert(not (_G.GathercraftWelcome and _G.GathercraftWelcome:IsShown()), "welcome for a player who already had data")
    assert(ns.db.welcomeSeen and ns.db.lastVersion, "version not remembered")
    -- same version again: quiet; a new player: the welcome
    for i, l in ipairs(log) do log[i] = "" end
    ns.WelcomeOnLogin()
    assert(not said("0.1."), "what's new again without an update")
    local fresh = ns.freshInstall
    ns.freshInstall, ns.db.welcomeSeen = true, nil
    ns.WelcomeOnLogin()
    assert(_G.GathercraftWelcome and _G.GathercraftWelcome:IsShown(), "no welcome on a fresh install")
    _G.GathercraftWelcome:Hide()
    ns.freshInstall = fresh
    assert(ns.db.welcomeSeen, "closing the welcome is not remembered")
    slash("welcome")
    assert(_G.GathercraftWelcome:IsShown(), "/gcr welcome does not show it again")
    _G.GathercraftWelcome:Hide()
    slash("whatsnew")
    assert(said("0.1.13") or said("CurseForge"), "/gcr whatsnew says nothing")
    -- a run that brought something: the summary shows when you stop it
    local sent = {}
    SendChatMessage = function(msg, chatType) sent[#sent + 1] = { msg = msg, type = chatType } end
    player.map, player.x, player.y = 1412, 0.45, 0.72
    ns.StartRun("herb") advance(1)
    for _ = 1, 3 do
        for _, f in ipairs(ns.gatherListeners) do f({ type = "herb", name = "Peacebloom" }, { value = 1234 }) end
    end
    advance(150)
    ns.StopRun()
    local card = _G.GathercraftRunSummary
    assert(card and card:IsShown(), "no summary after a run")
    ns.ShareRunSummary("GUILD")
    assert(#sent == 1 and sent[1].type == "GUILD", "share did not post in guild chat")
    assert(sent[1].msg:find("3", 1, true) and not sent[1].msg:find("|", 1, true), "bad share line: " .. sent[1].msg)
    assert(not card:IsShown(), "summary stays open after sharing")
    -- a new run replacing the old one, or a very short one: no summary
    ns.StartRun("herb") advance(1)
    for _, f in ipairs(ns.gatherListeners) do f({ type = "herb", name = "Peacebloom" }, { value = 1234 }) end
    advance(150)
    ns.StartRun("ore") advance(1)
    assert(not card:IsShown(), "summary when a new run replaced the old one")
    advance(30)
    ns.StopRun()
    assert(not card:IsShown(), "summary after a 30 second run")
    -- turned off in the options
    ns.db.summaryOff = true
    ns.StartRun("herb") advance(1)
    for _, f in ipairs(ns.gatherListeners) do f({ type = "herb", name = "Peacebloom" }, { value = 1234 }) end
    advance(150)
    ns.StopRun()
    assert(not card:IsShown(), "summary although it is turned off")
    ns.db.summaryOff = nil
    SendChatMessage = nil
end)
step("Crafting: waypoint to a recipe vendor (v0.1.13)", function()
    slash("") ns.ToggleMain("crafting") advance(1)
    assert(ns.RecipeVendorWaypoint, "crafting page not built")
    local src, spells = GathercraftRecipeSources, GathercraftRecipeData.spells
    local found, wp
    for prof, list in pairs(spells) do
        for key, spell in pairs(list) do
            local item = src.scroll[spell]
            local packed = item and src.items[item]
            if packed and packed:find("V:", 1, true) then
                wp = ns.RecipeVendorWaypoint({ prof = prof, key = key })
                if wp then found = true break end
            end
        end
        if found then break end
    end
    assert(wp, "no recipe vendor with a position found")
    assert(type(wp.mapID) == "number" and wp.x > 0 and wp.x < 1 and wp.y > 0 and wp.y < 1 and wp.name ~= "", "bad vendor position")
    ns.ToggleMain("crafting")
end)
step("Skill plan: steps and material list (v0.1.13)", function()
    slash("plan tailoring") advance(1)
    local win = _G.GathercraftSkillPlan
    assert(win and win:IsShown(), "/gcr plan does not open the planner")
    for _, prof in ipairs({ "Tailoring", "Blacksmithing", "Alchemy", "Leatherworking", "Engineering", "Enchanting", "Cooking", "First Aid" }) do
        local steps, mats, total, stuck = ns.SkillPlan(prof, 1, 300)
        assert(not stuck and #steps > 0 and #mats > 0, prof .. ": no plan to 300")
        local at = 1
        for _, s in ipairs(steps) do
            assert(s.from == at and s.to > s.from and s.crafts >= 1, prof .. ": steps don't follow each other")
            assert(s.recipe.how ~= nil, prof .. ": a recipe nobody can learn")
            at = s.to
        end
        assert(at == 300, prof .. ": plan ends at " .. at)
    end
    -- a blacksmith who smelts (Mining 150, the smelting recipes known): bars
    -- you don't have are broken down into ore, and ore gets a farm run
    -- (without Mining they are bought: see the step for v0.1.14)
    local Known, Rank = ns.CraftData.Known, ns.ProfessionRank
    local smelts = GathercraftRecipeData.professions.Mining
    ns.CraftData.Known = function(p) if p == "Mining" then return smelts end return Known(p) end
    ns.ProfessionRank = function(p) if p == "Mining" then return 150, 150 end return Rank(p) end
    local _, mats = ns.SkillPlan("Blacksmithing", 1, 150)
    local ore
    for _, m in ipairs(mats) do if m.id == 2770 then ore = m end end
    assert(ore and ore.node and ore.node:find("Copper"), "copper ore (from bars) not in the list or without a node")
    -- every copper bar - also the ones inside bronze bars - comes from one copper ore
    local bars, ore2 = 0, 0
    local steps150, mats150 = ns.SkillPlan("Blacksmithing", 1, 150)
    local recipes = GathercraftRecipeData.professions
    local function uses(id, s)
        local _, reagents = recipes.Blacksmithing[s.recipe.key]:match("^([^|]+)|(.*)$")
        return tonumber((reagents or ""):match(id .. ":(%d+)")) or 0
    end
    local bronze = 0
    for _, s in ipairs(steps150) do
        bars = bars + uses(2840, s) * s.crafts
        bronze = bronze + uses(2841, s) * s.crafts
    end
    bars = bars + math.ceil(bronze / 2) -- one smelt: 1 copper + 1 tin bar -> 2 bronze bars
    for _, m in ipairs(mats150) do if m.id == 2770 then ore2 = m.need end end
    assert(ore2 >= bars, ("copper ore %d for at least %d copper bars"):format(ore2, bars))
    ns.CraftData.Known, ns.ProfessionRank = Known, Rank
    -- a recipe read from a profession window has no required skill: the shipped one counts
    ns.db.recipeDB = ns.db.recipeDB or {}
    ns.db.recipeDB.Tailoring = ns.db.recipeDB.Tailoring or {}
    local shippedShirt = recipes.Tailoring["Orange Mageweave Shirt"]
    ns.db.recipeDB.Tailoring["Orange Mageweave Shirt"] = shippedShirt:gsub("^(%d+:%d+:%d+:)%d+", "%10")
    for _, s in ipairs(ns.SkillPlan("Tailoring", 100, 170)) do
        assert(s.recipe.key ~= "Orange Mageweave Shirt", "a recipe planned below its required skill")
    end
    ns.db.recipeDB.Tailoring["Orange Mageweave Shirt"] = nil
    -- a farm run for an item: every node that gives it, whatever its name
    player.map, player.x, player.y = 1412, 0.45, 0.72
    ns.StartRun("item:2770") advance(1)
    assert(ns.run and ns.run.path and #ns.run.path > 0, "no route for copper ore")
    for _, p in ipairs(ns.run.path) do
        assert(p.node.type == "ore" and p.node.name:find("Copper") or p.node.name:find("Kupfer") or p.node.name ~= "", "a node that gives no copper ore")
    end
    ns.StopRun(true)
    -- smelting: Mining rises with it up to where the shipped smelts end
    local msteps, _, _, mstuck = ns.SkillPlan("Mining", 1, 300)
    assert(#msteps > 0 and msteps[1].from == 1 and mstuck, "smelting plan: " .. tostring(msteps[1] and msteps[1].recipe.key) .. " " .. tostring(mstuck))
    ns.ShowSkillPlan("Mining") advance(1)
    -- herbs gathered while the switch showed its tooltip get a real name at login
    ns.db.nodes[1412] = ns.db.nodes[1412] or {}
    local odd = { name = "Find Herbs / Find Minerals", type = "herb", x = 0.31, y = 0.31, count = 1, last = 1, item = 2447 }
    table.insert(ns.db.nodes[1412], odd)
    fire("PLAYER_LOGIN") advance(10)
    assert(odd.name == "Peacebloom" or odd.name:find("Peacebloom") or odd.name ~= "Find Herbs / Find Minerals", "node still named after the switch: " .. odd.name)
    -- the switch's own tooltip is no node name when gathering
    GameTooltip:SetOwner(_G.GathercraftTrackButton, "ANCHOR_LEFT")
    GameTooltip:AddLine("Find Herbs / Find Minerals")
    GameTooltip:Show()
    -- you already know a bit: the plan starts at your skill
    local steps = ns.SkillPlan("Tailoring", 120, 150)
    assert(steps[1].from == 120 and steps[#steps].to == 150, "plan does not start at the given skill")
    win:Hide()
end)
step("Trainer reminder 5 points before the end of a rank (v0.1.13)", function()
    local function count(text)
        local n = 0
        for _, l in ipairs(log) do if l:find(text, 1, true) then n = n + 1 end end
        return n
    end
    local oldRank, oldMax = PROFS[1][2], PROFS[1][3]
    for i, l in ipairs(log) do log[i] = "" end
    PROFS[1][2], PROFS[1][3] = 69, 75
    ns.CheckTrainer()
    assert(count("69/75") == 0, "reminded 6 points before the end")
    PROFS[1][2] = 70
    ns.CheckTrainer() ns.CheckTrainer()
    assert(count("70/75") == 1, "no reminder (or twice) at 70/75")
    PROFS[1][2] = 75
    ns.CheckTrainer()
    assert(count("75/75") == 1, "no reminder at the cap")
    -- the bar goes to 300 and shows what is unlocked
    ns.ToggleMain("overview") advance(3)
    ns.ToggleMain("overview")
    -- turned off: quiet
    ns.db.trainerRemindOff = true
    PROFS[2][2], PROFS[2][3] = 148, 150
    ns.CheckTrainer()
    assert(count("148/150") == 0, "reminder although it is turned off")
    ns.db.trainerRemindOff = nil
    PROFS[1][2], PROFS[1][3] = oldRank, oldMax
    PROFS[2][2], PROFS[2][3] = 30, 75
end)
step("Forever bonus loot (seeds, lichen) is not what the herb is (v0.1.13)", function()
    player.map, player.x, player.y = 1412, 0.66, 0.66
    -- the switch's tooltip is still up while gathering: not the node's name
    GameTooltip:SetOwner(_G.GathercraftTrackButton, "ANCHOR_LEFT")
    GameTooltip:AddLine("Find Herbs / Find Minerals")
    GameTooltip:Show()
    fire("UNIT_SPELLCAST_SENT", "player", "", "castB", 2366)
    fire("UNIT_SPELLCAST_SUCCEEDED", "player", "castB", 2366)
    loot = { { guid = "GameObject-0-1-1-1-1617-BONUS1", item = 999001, qty = 1 },
        { guid = "GameObject-0-1-1-1-1617-BONUS1", item = 765, qty = 2 } }
    fire("LOOT_READY") fire("LOOT_OPENED")
    advance(3)
    loot = {}
    GameTooltip:Hide()
    local found
    for _, n in ipairs(ns.db.nodes[1412]) do
        if math.abs(n.x - 0.66) < 0.01 and math.abs(n.y - 0.66) < 0.01 and n.type == "herb" then found = n end
    end
    assert(found, "the gather was not recorded")
    assert(found.item == 765, "node item is the bonus drop: " .. tostring(found.item))
    assert(not found.name:find("Find Herbs", 1, true), "node named after the switch tooltip")
end)
step("A run from the overview stays in your zone (v0.1.13)", function()
    -- nodes in two zones next to each other: the overview run stays where you are
    local function vein(x, y) return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = y, count = 3, last = 1 } end
    local keepA, keepB = ns.db.nodes[1461], ns.db.nodes[1460]
    ns.db.nodes[1461], ns.db.nodes[1460] = {}, {}
    for i = 1, 10 do table.insert(ns.db.nodes[1461], vein(0.1 + i * 0.07, 0.5)) end
    for i = 1, 10 do table.insert(ns.db.nodes[1460], vein(0.1 + i * 0.07, 0.4)) end
    player.map, player.x, player.y = 1461, 0.5, 0.5
    ns.StartHereRun("ore") advance(1)
    assert(ns.run and ns.run.zone == 1461, "the run left your zone")
    for _, p in ipairs(ns.run.path) do assert(p.mapID == 1461, "a node of another zone in the route") end
    ns.StopRun(true)
    -- a city or a zone with too few nodes for a round: the nearest zone that has them
    ns.db.nodes[1461] = { vein(0.5, 0.5) }
    ns.StartHereRun("ore") advance(1)
    assert(ns.run and ns.run.zone == 1460, "not the nearest zone with nodes: " .. tostring(ns.run and ns.run.zone))
    for _, p in ipairs(ns.run.path) do assert(p.mapID == 1460, "a node of another zone in the route") end
    ns.StopRun(true)
    -- in a capital: the zone around it (Thunder Bluff -> Mulgore)
    local keepM = ns.db.nodes[1412]
    ns.db.nodes[1412] = {}
    for i = 1, 10 do table.insert(ns.db.nodes[1412], vein(0.1 + i * 0.07, 0.6)) end
    player.map, player.x, player.y = 1456, 0.5, 0.5
    ns.StartHereRun("ore") advance(1)
    assert(ns.run and ns.run.zone == 1412, "Thunder Bluff run not in Mulgore: " .. tostring(ns.run and ns.run.zone))
    ns.StopRun(true)
    ns.db.nodes[1412] = keepM
    player.map, player.x, player.y = 1461, 0.5, 0.5
    -- the Zones tab selection doesn't count for a quick run
    ns.db.nodes[1461] = {}
    for i = 1, 10 do table.insert(ns.db.nodes[1461], vein(0.1 + i * 0.07, 0.5)) end
    ns.db.disabledZones[1461] = true
    ns.StartHereRun("ore") advance(1)
    assert(ns.run and ns.run.zone == 1461 and #ns.run.path > 0, "an unticked zone blocks the quick run")
    ns.StopRun(true)
    ns.db.disabledZones[1461] = nil
    -- right-click: what you can gather (only Mining here: ore)
    local GetSkill = ns.GetSkill
    ns.GetSkill = function(t) if t == "ore" then return 50, 75, 50 end end
    ns.StartHereRun() advance(1)
    assert(ns.run and ns.run.filter == "ore", "right-click run not for your profession: " .. tostring(ns.run and ns.run.filter))
    ns.StopRun(true)
    ns.GetSkill = GetSkill
    ns.db.nodes[1461], ns.db.nodes[1460] = keepA, keepB
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Zones tab run over picked zones far apart: the group near you (v0.1.13)", function()
    local function vein(x, y) return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = y, count = 3, last = 1 } end
    local keep = {}
    for _, z in ipairs({ 1412, 1413, 1443, 1460, 1461 }) do keep[z] = ns.db.nodes[z] end
    local function fill(z, y)
        ns.db.nodes[z] = {}
        for i = 1, 6 do table.insert(ns.db.nodes[z], vein(0.1 + i * 0.12, y)) end
    end
    -- Mulgore + Barrens (neighbours) and Desolace (far away), nothing else picked
    for _, z in ipairs({ 1412, 1413, 1443 }) do fill(z, 0.5) end
    ns.db.nodes[1460], ns.db.nodes[1461] = nil, nil
    local disabled = ns.db.disabledZones
    ns.db.disabledZones = {}
    for z in pairs(ns.db.nodes) do
        if z ~= 1412 and z ~= 1413 and z ~= 1443 then ns.db.disabledZones[z] = true end
    end
    for i, l in ipairs(log) do log[i] = "" end
    player.map, player.x, player.y = 1412, 0.5, 0.5
    ns.StartRun("ore") advance(1)
    assert(ns.run and ns.run.path, "no run")
    local zones = {}
    for _, p in ipairs(ns.run.points) do zones[p.mapID] = true end
    assert(zones[1412] and zones[1413], "Mulgore and the Barrens are neighbours: both belong in the route")
    assert(not zones[1443], "Desolace is far away: not in this route")
    local told = false
    for _, l in ipairs(log) do if l:find(ns.GetZoneName(1443), 1, true) then told = true end end
    assert(told, "no word about the far zone")
    -- a flight to Desolace: the run moves there
    player.map, player.x, player.y = 1443, 0.5, 0.5
    ns.run.pointsDirty = true
    advance(15)
    local there = {}
    for _, p in ipairs(ns.run.points) do there[p.mapID] = true end
    assert(there[1443] and not there[1412], "after a flight the run stays in the old zones")
    ns.StopRun(true)
    ns.db.disabledZones = disabled
    for z, v in pairs(keep) do ns.db.nodes[z] = v end
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Skill statistics: gathers at the end of a rank are not counted, 300 is", function()
    local Z = 1471
    local was = { rank = PROFS[1][2], max = PROFS[1][3], debug = ns.db.debug }
    ns.db.debug = true
    player.map, player.x, player.y = Z, 0.50, 0.50
    local seq = 0
    local function Gather(rank, max, after)
        PROFS[1][2], PROFS[1][3] = rank, max
        seq = seq + 1
        local id = "cap" .. seq
        fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", id, 2366) advance(1)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", id, 2366)
        if after then PROFS[1][2] = after end
        loot = { { guid = ("GameObject-0-1-1-1-1618-CAP%03d"):format(seq), item = 2447, qty = 1 } }
        fire("LOOT_READY") loot = {}
        advance(3) -- the skill is read 1.5 s after the gather
    end
    local key = "herb:peacebloom"
    local function S() local s = ns.KindStats()[key] or {} return s.n or 0, s.ups or 0, s.minNoUp end
    local n0, up0 = S()
    -- 75/75: no point possible until you train: not counted
    local mark = #log
    Gather(75, 75)
    local n, up = S()
    assert(n == n0 and up == up0, ("75/75 counted: n %d -> %d"):format(n0, n))
    local said = false
    for i = mark + 1, #log do if log[i]:find("at the end of your rank (75/75), not counted", 1, true) then said = true end end
    assert(said, "no debug line for the gather at the end of the rank")
    Gather(150, 150)
    n, up = S()
    assert(n == n0 and up == up0, "150/150 counted")
    -- 74/75 with a point: counted
    Gather(74, 75, 75)
    n, up = S()
    assert(n == n0 + 1 and up == up0 + 1, ("74/75 with a skill-up not counted: n %d, ups %d"):format(n - n0, up - up0))
    -- 300/300: as before (counted, no point)
    Gather(300, 300)
    local n3, up3, noUp = S()
    assert(n3 == n0 + 2 and up3 == up0 + 1 and noUp and noUp <= 300, "300/300 not counted as before")

    PROFS[1][2], PROFS[1][3] = was.rank, was.max
    ns.db.debug = was.debug
    ns.db.nodes[Z] = nil
    ns.NotifyNodesChanged()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    advance(1)
end)
step("Starter data: the new Forever kinds are pins with names, and are never shared", function()
    -- the beta data loaded at login: Poor Copper, Wilted Peacebloom, Stunted Silverleaf
    local data = GathercraftStarterData
    assert(data and data.version == "beta-2026-10-23", "starter data version " .. tostring(data and data.version))
    local want = { o562111 = "Poor Copper Vein", o656160 = "Wilted Peacebloom", o656161 = "Stunted Silverleaf" }
    local shipped = {}
    for _, list in pairs(data.nodes) do
        for _, e in ipairs(list) do if want[e[1]] then shipped[e[1]] = (shipped[e[1]] or 0) + 1 end end
    end
    for oid, name in pairs(want) do assert((shipped[oid] or 0) > 0, name .. " missing in the starter data") end
    -- in a fresh profile they all come in as starter nodes of their own kind
    local saved = { nodes = ns.db.nodes, version = ns.db.starterVersion }
    ns.db.nodes, ns.db.starterVersion = {}, nil
    ns.ForgetSeenKinds()
    local mark = #log
    local loader
    for f in pairs(eventFrames["PLAYER_LOGOUT"] or {}) do
        if eventFrames["PLAYER_LOGIN"][f] then loader = f end
    end
    assert(loader, "test setup: starter loader not found")
    loader.__scripts.OnEvent(loader, "PLAYER_LOGIN")
    local got, named = {}, {}
    for mapID, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            if want[n.id] then
                assert(n.source == "starter", n.name .. " not marked as starter data")
                got[n.id] = (got[n.id] or 0) + 1
                if n.name and n.name ~= "" and n.name ~= n.id then named[n.id] = (named[n.id] or 0) + 1 end
            end
        end
    end
    for oid, name in pairs(want) do
        assert(got[oid] == shipped[oid], ("%s: %s of %d imported"):format(name, tostring(got[oid]), shipped[oid]))
        assert(named[oid] == got[oid], name .. " without a name")
    end
    -- and they get pins (Mulgore, where we stand)
    player.map, player.x, player.y = 1412, 0.45, 0.72
    ns.NotifyNodesChanged() advance(2)
    local pinned = {}
    for _, f in ipairs(allFrames) do
        if f.node and want[f.node.id] and f.node.source == "starter" then pinned[f.node.id] = true end
    end
    for oid, name in pairs(want) do
        local inMulgore = false
        for _, e in ipairs(data.nodes[1412] or {}) do if e[1] == oid then inMulgore = true end end
        assert(not inMulgore or pinned[oid], name .. " has no pin")
    end
    -- never shared as if we had found them: no push, no answer to a query
    ns.db.sync = ns.db.sync or {}
    local sent = #sentMessages
    for _, n in ipairs(ns.db.nodes[1412] or {}) do
        if want[n.id] then ns.SyncShare(1412, n) end
    end
    advance(3)
    -- someone asks for Mulgore: we hold only starter nodes there, so nothing to answer with
    fire("CHAT_MSG_ADDON", "Gathercraft", "Q:1412:0", "CHANNEL", "Curious Player", nil, nil, nil, "GathercraftSync")
    advance(12)
    for i = sent + 1, #sentMessages do
        assert(sentMessages[i]:sub(1, 2) == "Q:", "a starter node was shared: " .. sentMessages[i])
    end
    ns.db.nodes, ns.db.starterVersion = saved.nodes, saved.version
    ns.ForgetSeenKinds() ns.NotifyNodesChanged() advance(1)
end)
step("Sync: your own gather of a node that came from sync is booked and shared", function()
    -- a new Forever object (no spawn data kind) from a guild member: sync
    -- sends no object names, so it is named after its item
    local W = IdentityWorld()
    W.Set({})
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:1412;o7123456,h,5000,5000,2447", "GUILD", "Guildie Sync-Realm") advance(1)
    local got
    for _, n in ipairs(ns.db.nodes[1412]) do if n.id == "o7123456" then got = n end end
    assert(got and got.source == "sync" and got.itemName, "the node from sync was not imported with its item name")
    assert(ns.ObjectName(7123456, 1412) == nil, "the item name of a node from sync is used as the object name")
    local function Shared(tag)
        for i = tag + 1, #sentMessages do
            if sentMessages[i]:find("o7123456", 1, true) then return true end
        end
    end
    -- you gather it yourself: the cast names the object, the loot fits
    W.At(0)
    local sent = #sentMessages
    local c = W.Cast("Wilted Peacebloom") W.Wait(2) W.Done(c) W.Loot(7123456, 2447, "SYNC01") W.Wait(12)
    assert(got.lastSpawn == "SYNC01" and got.count == 2 and not got.source,
        ("own gather of the node from sync not booked: spawn %s, count %d, source %s"):format(tostring(got.lastSpawn), got.count, tostring(got.source)))
    assert(Shared(sent), "own gather of the node from sync not shared")
    -- now your own node, but still named after its item: the next one of the
    -- same object somewhere else is booked too (a new node), also once the
    -- name lookup was built again (any bigger change, a relog)
    ns.NotifyNodesChanged() advance(1)
    W.At(80)
    sent = #sentMessages
    c = W.Cast("Wilted Peacebloom") W.Wait(2) W.Done(c) W.Loot(7123456, 2447, "SYNC02") W.Wait(12)
    local second
    for _, n in ipairs(ns.db.nodes[1412]) do if n.id == "o7123456" and n.lastSpawn == "SYNC02" then second = n end end
    assert(second and second ~= got and second.name == "Wilted Peacebloom", "second gather of the object not booked as its own node")
    assert(Shared(sent), "second gather of the object not shared")
    assert(ns.ObjectName(7123456, 1412) == "Wilted Peacebloom", "the gathered name is not the object's name now")
    -- unchanged (round 10): loot of another kind still drops the gather
    W.At(160)
    local before = 0
    for _, n in ipairs(ns.db.nodes[1412]) do if n.id == "o7123456" then before = before + 1 end end
    c = W.Cast("Glow Cap") W.Wait(2) W.Done(c) W.Loot(7123456, 2447, "SYNC03") W.Wait(12)
    local after = 0
    for _, n in ipairs(ns.db.nodes[1412]) do if n.id == "o7123456" then after = after + 1 end end
    assert(after == before and W.Count("Glow Cap") == 0, "loot of another kind was booked")
    W.Restore()
end)
step("Run counter: the same spawn opened again counts once, its value too", function()
    -- found in testing: a vein whose loot window was closed with loot left
    -- in it and mined again - the node and skill stats said "not counted",
    -- the run's gathered, per hour and gold went up every time
    local W = IdentityWorld()
    local v = W.Node("o1731", "Copper Vein", 0, { type = "ore", item = 2770 })
    W.Set({ v })
    W.At(-200) ns.StartRun("ore", 1412) W.Wait(1)
    W.At(0)
    local function KindValue()
        local n = 0
        for _, kv in pairs(ns.db.kindValue or {}) do n = n + kv.n end
        return n
    end
    local function Mine(tag)
        local c = W.Cast("Copper Vein", 2575) W.Wait(2) W.Done(c, 2575) W.Loot(1731, 2770, tag) W.Wait(3)
    end
    local s0, sv0, k0 = ns.RunSnapshot(), ns.SessionValue(), KindValue()
    assert(s0, "test setup: no run")
    Mine("SAME01")
    local s1, sv1 = ns.RunSnapshot(), ns.SessionValue()
    local one = s1.value - s0.value
    assert(s1.nodes == s0.nodes + 1 and one > 0 and sv1 - sv0 == one, "test setup: the first gather was not counted with its value")
    -- the same spawn twice more, its loot never emptied
    Mine("SAME01") Mine("SAME01")
    local s2, sv2 = ns.RunSnapshot(), ns.SessionValue()
    assert(s2.nodes == s0.nodes + 1, ("the same spawn counted %d times in the run"):format(s2.nodes - s0.nodes))
    assert(s2.value == s1.value and sv2 == sv1, "the value of the same spawn was booked again")
    assert(KindValue() == k0 + 1, "the same spawn counted again in the value per kind")
    -- another spawn: counts
    Mine("OTHER1")
    local s3 = ns.RunSnapshot()
    assert(s3.nodes == s0.nodes + 2 and s3.value > s2.value, "another spawn of the vein was not counted")
    -- a gather that failed or was interrupted: nothing
    local c = W.Cast("Copper Vein", 2575) W.Wait(1)
    fire("UNIT_SPELLCAST_INTERRUPTED", "player", c, 2575) W.Wait(12)
    local s4 = ns.RunSnapshot()
    assert(s4.nodes == s3.nodes and s4.value == s3.value, "an interrupted gather was counted")
    -- the summary when the run ends and the line shared from it: the same 2
    local sent = {}
    local oldSend = SendChatMessage
    SendChatMessage = function(msg, chatType) sent[#sent + 1] = msg end
    W.Wait(130)
    ns.StopRun()
    local card = _G.GathercraftRunSummary
    assert(card and card:IsShown(), "no summary after the run")
    ns.ShareRunSummary("GUILD")
    local fmt = ns.L["[Gathercraft] Farm run: %d nodes in %s (%d per hour, %s per hour, +%d skill)"]
    local head = fmt:match("^(.-)%%d")
    local msg = sent[1] or ""
    assert(msg:sub(1, #head) == head and msg:sub(#head + 1):match("^2%D"), "shared line: " .. msg .. ", expected 2 nodes")
    SendChatMessage = oldSend
    W.Restore()
end)
step("Recorder: a placeholder name never blocks a later gather with the real name", function()
    local W = IdentityWorld()
    W.Set({})
    local function Gather(target, id, tag, xYd)
        W.At(xYd)
        local c = W.Cast(target) W.Wait(2) W.Done(c) W.Loot(id, 2447, tag) W.Wait(12)
    end
    local function Booked(id, tag)
        for _, n in ipairs(ns.db.nodes[1412]) do if n.id == "o" .. id and n.lastSpawn == tag then return n end end
    end
    -- (a) a new object gathered without any name (no target, no tooltip),
    -- then the same object with its name at another spawn: both are booked
    Gather("", 7999998, "PH0001", 0)
    local first = Booked(7999998, "PH0001")
    assert(first and first.name == ns.L["Unknown Herb"], "test setup: the gather without a name was not stored as Unknown Herb")
    Gather("New Forever Herb", 7999998, "PH0002", 100)
    assert(Booked(7999998, "PH0002"), "a placeholder blocked the gather with the real name")
    -- (b) a placeholder already saved: the name lookup is built from it
    W.Set({ W.Node("o7999996", ns.L["Unknown Herb"], 0, { item = 2447, lastSpawn = "OLD001" }) })
    Gather("New Forever Herb", 7999996, "PH0003", 100)
    assert(Booked(7999996, "PH0003"), "a saved placeholder blocked the gather with the real name")
    -- (c) a placeholder saved under another language
    local other = LOCALE == "deDE" and "Unknown Herb" or ns.Locales.deDE["Unknown Herb"]
    W.Set({ W.Node("o7999994", other, 0, { item = 2447, lastSpawn = "OLD002" }) })
    Gather("New Forever Herb", 7999994, "PH0004", 100)
    assert(Booked(7999994, "PH0004"), "a placeholder of another language (" .. other .. ") blocked the gather with the real name")
    W.Restore()
end)
step("Sync: your own gather of a node from sync keeps what you saw, not what the report said", function()
    local W = IdentityWorld()
    W.Set({})
    local function Get(id)
        for _, n in ipairs(ns.db.nodes[1412]) do if n.id == id then return n end end
    end
    -- a report that calls the spot ore with Copper Ore; you gather a herb there
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:1412;o7999997,o,5000,5000,2770", "GUILD", "Guildie Wrong-Realm") advance(1)
    local n = Get("o7999997")
    assert(n and n.type == "ore" and n.item == 2770 and n.source == "sync", "test setup: the report was not imported as ore")
    W.At(0)
    local c = W.Cast("New Real Herb") W.Wait(2) W.Done(c) W.Loot(7999997, 2447, "OWNREAL") W.Wait(12)
    assert(n.lastSpawn == "OWNREAL" and not n.source, "test setup: your own gather was not booked on the node")
    assert(n.type == "herb" and n.item == 2447, ("your own gather did not win: type %s, item %s"):format(tostring(n.type), tostring(n.item)))
    -- a report that fits: nothing changes
    fire("CHAT_MSG_ADDON", "Gathercraft", "N:1412;o7999995,h,5300,5000,2447", "GUILD", "Guildie Right-Realm") advance(1)
    local m = Get("o7999995")
    assert(m and m.type == "herb" and m.item == 2447, "test setup: the fitting report was not imported")
    W.At(150)
    c = W.Cast("Other Real Herb") W.Wait(2) W.Done(c) W.Loot(7999995, 2447, "OWNOK1") W.Wait(12)
    assert(m.lastSpawn == "OWNOK1" and m.type == "herb" and m.item == 2447 and not m.source, "a fitting report changed with your own gather")
    W.Restore()
end)
step("Welcome: the herb and ore count is covered by the shipped data (v0.1.14)", function()
    -- the welcome's text, wherever it says how many herb and ore spots there are
    local f = assert(io.open(ROOT .. "/Welcome.lua"))
    local src = f:read("*a") f:close()
    local key = src:match('text = "(%d[^"]-herb and ore spots[^"]*)"')
    assert(key, "test setup: no herb and ore count in Welcome.lua")
    local t = ns.L[key]
    -- herb and ore positions in Data/QuestieNodes.lua (a place counts once,
    -- chests do not count): the number said may not be more
    local data = GathercraftQuestieData
    local seen, n = {}, 0
    for map, packed in pairs(data.zones) do
        for id, x, y in packed:gmatch("(%d+),(%d+),(%d+)") do
            local kind = data.kinds["o" .. id]
            if kind and (kind[1] == "h" or kind[1] == "o") and not seen[map .. ":" .. x .. ":" .. y] then
                seen[map .. ":" .. x .. ":" .. y] = true
                n = n + 1
            end
        end
    end
    local digits = (t:match("%d[%d%.,%s]*%d") or ""):gsub("%D", "")
    local said = tonumber(digits)
    assert(said and said <= n, ("the welcome says %s herb and ore spots, the data has %d: %s"):format(tostring(said), n, t))
    assert(said >= 1000 and n - said < 1000, ("the welcome's %s is far below the %d herb and ore spots"):format(tostring(said), n))
    if LOCALE == "enUS" then assert(t == key, "English welcome text: " .. t) end
    if LOCALE == "deDE" then assert(t:find("Über 15.000 Kräuter- und Erzfundorte", 1, true), "German welcome text: " .. t) end
    if LOCALE ~= "enUS" then assert(t ~= key, "welcome text not translated: " .. t) end
end)
step("Run counter: a cultivated copy counts once, the first one still counts (v0.1.14)", function()
    -- found in review: the same copy gathered again counted again
    local W = IdentityWorld()
    local e = W.Node("o1619", "Earthroot", 0, { item = 2449 })
    W.Set({ e })
    local oldRace = UnitRace
    UnitRace = function() return "Tauren", "Tauren" end
    W.At(-200) ns.StartRun("herb", 1412) W.Wait(1)
    W.At(0)
    local function Pick(tag)
        local c = W.Cast("Earthroot") W.Wait(2) W.Done(c) W.Loot(1619, 2449, tag) W.Wait(3)
    end
    local s0 = ns.RunSnapshot()
    Pick("BASE01")
    local one = ns.RunSnapshot().value - s0.value
    assert(one > 0, "test setup: the first pick has no value")
    Pick("COPY01")
    local s1 = ns.RunSnapshot()
    assert(s1.nodes == s0.nodes + 2 and s1.value == s0.value + 2 * one, "the first cultivated copy did not count")
    Pick("COPY01")
    local s2 = ns.RunSnapshot()
    assert(s2.nodes == s0.nodes + 2 and s2.value == s0.value + 2 * one,
        ("the same copy counted again: %d gathered, value %d (want 2, %d)"):format(s2.nodes - s0.nodes, s2.value - s0.value, 2 * one))
    local n = 0
    for _, x in ipairs(ns.db.nodes[1412]) do if x.id == "o1619" then n = n + 1 end end
    assert(n == 1, "the copy became a node of its own")
    UnitRace = oldRace
    W.Restore()
end)
-- A1: spawn IDs on Forever hold for one session only. A node from the saved
-- data (a plain table, as an older save has it, with no session mark) still
-- resting from a gather in an earlier session
local function SpawnWorld()
    local W = IdentityWorld()
    function W.Saved(xYd, spawn, rest, extra)
        local v = W.Node("o1731", "Copper Vein", xYd, { type = "ore", item = 2770, lastSpawn = spawn,
            emptyUntil = rest and time() + rest or nil })
        for k, val in pairs(extra or {}) do v[k] = val end
        return v
    end
    function W.Mine(tag, xYd)
        W.At(xYd or 0)
        local c = W.Cast("Copper Vein", 2575) W.Wait(2) W.Done(c, 2575) W.Loot(1731, 2770, tag) W.Wait(3)
    end
    function W.Veins()
        local n = 0
        for _, x in ipairs(ns.db.nodes[1412]) do if x.id == "o1731" then n = n + 1 end end
        return n
    end
    function W.Hits()
        local h = 0
        for _, x in ipairs(ns.db.nodes[1412]) do if x.id == "o1731" then h = h + (x.hits or 0) end end
        return h
    end
    function W.Run(list)
        W.Set(list)
        W.At(-200) ns.StartRun("ore", 1412) W.Wait(1)
        local s = ns.RunSnapshot()
        assert(s, "test setup: no run")
        return s
    end
    return W
end
step("A1: a spawn ID from an earlier session is no new spot (Codex' three cases)", function()
    local W = SpawnWorld()
    -- (1) the old ID again, still resting: one node, not counted
    local v = W.Saved(0, "OLDID1", 200)
    local s0 = W.Run({ v })
    W.Mine("OLDID1")
    assert(W.Veins() == 1 and v.count == 1 and ns.RunSnapshot().nodes == s0.nodes,
        ("old ID again: %d nodes, count %d"):format(W.Veins(), v.count))
    W.Restore()
    -- (2) a new ID, still resting, same spot and object: the same node, not counted
    W = SpawnWorld()
    v = W.Saved(0, "OLDID1", 200)
    s0 = W.Run({ v })
    W.Mine("NEWID1")
    assert(W.Veins() == 1, ("new ID while resting: %d nodes at the same spot (want 1)"):format(W.Veins()))
    assert(v.count == 1 and v.lastSpawn == "NEWID1", ("new ID while resting: count %d, spawn %s"):format(v.count, tostring(v.lastSpawn)))
    assert(ns.RunSnapshot().nodes == s0.nodes, "new ID while resting: counted in the run again")
    -- the new ID holds from now on in this session: once more, still nothing
    W.Mine("NEWID1")
    assert(W.Veins() == 1 and v.count == 1 and ns.RunSnapshot().nodes == s0.nodes, "the new ID again: counted")
    W.Restore()
    -- (3) a new ID, the rest is over: the same node, counted (as before)
    W = SpawnWorld()
    v = W.Saved(0, "OLDID1", -10)
    s0 = W.Run({ v })
    W.Mine("NEWID2")
    assert(W.Veins() == 1 and v.count == 2 and ns.RunSnapshot().nodes == s0.nodes + 1,
        ("new ID after the rest: %d nodes, count %d"):format(W.Veins(), v.count))
    W.Restore()
end)
step("A1: earlier session, a few yards off or a real neighbour; this session as before", function()
    -- (2) new session, new ID, you stand 4 yards from where you mined before: one node
    local W = SpawnWorld()
    local v = W.Saved(0, "OLDID1", 200)
    W.Run({ v })
    W.Mine("NEWID3", 4)
    assert(W.Veins() == 1 and v.lastSpawn == "NEWID3", ("4 yd off, new session: %d nodes (want 1)"):format(W.Veins()))
    W.Restore()
    -- (3) this session: a vein mined, a neighbour 8 yards away with its own ID: two spots (as before)
    W = SpawnWorld()
    local s0 = W.Run({ W.Saved(1000) }) -- a vein far away: the run has a target
    W.Mine("SESS01", 0)
    W.Mine("SESS02", 8)
    assert(W.Veins() == 3 and ns.RunSnapshot().nodes == s0.nodes + 2, -- with the far one
        ("this session, neighbour at 8 yd: %d new nodes, %d counted (want 2, 2)"):format(W.Veins() - 1, ns.RunSnapshot().nodes - s0.nodes))
    W.Restore()
    -- (4) new session, a real neighbour at a usual spawn distance (15 yd; for about
    -- half of the spawn data entries the next one of the same object is 43-45 yd
    -- or more away, an approximation): two spots
    W = SpawnWorld()
    v = W.Saved(0, "OLDID1", 200)
    s0 = W.Run({ v })
    W.Mine("NEWID4", 15)
    assert(W.Veins() == 2 and v.count == 1 and ns.RunSnapshot().nodes == s0.nodes + 1,
        ("new session, neighbour at 15 yd: %d nodes (want 2)"):format(W.Veins()))
    W.Restore()
    -- (4b) known limit A1-N, accepted on 31.10.2026: new session, a real neighbour
    -- 8 yd away while the first one rests. It can't be told from the resting
    -- spot under a new ID: one node, not counted. A change here must be on purpose
    W = SpawnWorld()
    v = W.Saved(0, "OLDID1", 200)
    s0 = W.Run({ v })
    W.Mine("NEWID5", 8)
    assert(W.Veins() == 1 and v.count == 1 and v.lastSpawn == "NEWID5" and ns.RunSnapshot().nodes == s0.nodes,
        ("known limit A1-N changed: new session, neighbour at 8 yd while resting: %d nodes, %d counted (accepted: 1, 0)")
            :format(W.Veins(), ns.RunSnapshot().nodes - s0.nodes))
    W.Restore()
    -- (5) this session, the same ID three times: one node, counted once
    W = SpawnWorld()
    s0 = W.Run({ W.Saved(1000) })
    W.Mine("SESS03") W.Mine("SESS03") W.Mine("SESS03")
    assert(W.Veins() == 2 and ns.RunSnapshot().nodes == s0.nodes + 1, -- with the far one
        ("this session, same ID 3x: %d new nodes, %d counted"):format(W.Veins() - 1, ns.RunSnapshot().nodes - s0.nodes))
    W.Restore()
    -- (6) saved nodes with only part of it (old saves): no Lua error
    W = SpawnWorld()
    local before = #errors
    W.Run({ W.Saved(0, "OLDID1", nil), W.Saved(30, nil, 200), W.Saved(60, "OLDID2", 200, { count = 0 }) })
    W.Mine("NEWID5", 0) W.Mine("NEWID6", 30) W.Mine("NEWID7", 60)
    assert(#errors == before and W.Veins() == 3, ("partial saves: %d errors, %d nodes (want 0, 3)"):format(#errors - before, W.Veins()))
    W.Restore()
end)
step("A1: route hits after a new session (lastHitSpawn)", function()
    -- (7) the hit a resting spot got in an earlier session is not taken again
    -- under its new ID; after the rest a new ID is a new hit
    local W = SpawnWorld()
    local v = W.Saved(0, "OLDID1", 200, { hits = 1, lastHitSpawn = "OLDID1" })
    W.Run({ v })
    W.Mine("NEWID8")
    assert(W.Hits() == 1, ("new ID while resting: %d hits (want 1)"):format(W.Hits()))
    v.emptyUntil = time() - 1
    W.Mine("NEWID9")
    assert(v.hits == 2 and v.lastHitSpawn == "NEWID9", ("new ID after the rest: %d hits (want 2)"):format(v.hits or 0))
    W.Mine("NEWID9")
    assert(v.hits == 2, "the same ID again in this session: another hit")
    W.Restore()
end)
step("Sync: a refused or failing send is dropped, the queue goes on", function()
    slash("sync on")
    local real = C_ChatInfo.SendAddonMessage
    local wasDebug = ns.db.debug
    local tries = {}
    local function Share(x)
        local node = { id = "o1619", name = "Earthroot", type = "herb", x = x, y = 0.62, count = 1, last = time(), item = 2449 }
        table.insert(ns.db.nodes[1412], node)
        ns.SyncShare(1412, node) advance(3)
        return node
    end
    -- (a) refused, (b) the call throws, (c) throws with /gcr debug on
    local ok, err = pcall(function()
    for _, mode in ipairs({ "false", "throw", "debug" }) do
        tries = {}
        C_ChatInfo.SendAddonMessage = function(prefix, msg, chan)
            local key = msg .. "|" .. tostring(chan)
            tries[key] = (tries[key] or 0) + 1
            if mode ~= "false" then error("addon messages are not allowed") end
            return false
        end
        ns.db.debug = mode == "debug"
        local before, mark = #errors, #log
        local a = Share(0.211)
        local b = Share(0.233)
        advance(10)
        assert(#errors == before, mode .. ": an error came out of the send")
        local texts, total = 0, 0
        for _, n in pairs(tries) do texts = texts + 1 total = total + n end
        assert(texts >= 2, ("%s: the queue stopped after a failed send (%d messages tried)"):format(mode, texts))
        assert(total == texts, ("%s: a failed message was sent again (%d tries for %d messages)"):format(mode, total, texts))
        local lines = 0
        for i = mark + 1, #log do
            if log[i]:find("not allowed", 1, true) or log[i]:find("sent [", 1, true) then lines = lines + 1 end
        end
        if mode == "debug" then
            assert(lines <= total, ("debug: %d lines for %d failed sends (want one each at most)"):format(lines, total))
        else
            assert(lines == 0, mode .. ": a chat line without /gcr debug")
        end
        for _, n in ipairs({ a, b }) do
            for i, x in ipairs(ns.db.nodes[1412]) do if x == n then table.remove(ns.db.nodes[1412], i) break end end
        end
    end
    end)
    C_ChatInfo.SendAddonMessage = real
    ns.db.debug = wasDebug
    assert(ok, err)
end)
step("Crafting: /gcr crafttest marks unknown costs like the list (v0.1.14)", function()
    -- every reagent without a price for a moment: the diagnosis says ?, not 0c
    local oldPrice, oldVendor = ns.GetPrice, ns.db.vendorPrices
    ns.GetPrice = function() return nil end
    ns.db.vendorPrices = {}
    local mark = #log
    slash("crafttest")
    ns.GetPrice, ns.db.vendorPrices = oldPrice, oldVendor
    local lines = 0
    for i = mark + 1, #log do
        local costs = log[i]:match("costs (.-)%)$")
        if costs and log[i]:find("profit", 1, true) then
            lines = lines + 1
            assert(costs:find("?", 1, true), "crafttest shows a known cost without any price: " .. log[i])
            local sells = log[i]:match("sells (.-), costs")
            assert(sells and sells:find("?", 1, true), "crafttest shows a sale value without any price: " .. log[i])
        end
    end
    assert(lines > 0, "test setup: crafttest listed no recipe")
end)
step("SoftTarget is not in the release: no event, /gcr softtest only shows the help", function()
    assert(ns.SoftTargetTest == nil and ns.SoftTargetState == nil, "SoftTarget code is still loaded")
    assert(not next(eventFrames["PLAYER_SOFT_INTERACT_CHANGED"] or {}), "something still listens to PLAYER_SOFT_INTERACT_CHANGED")
    local before, mark = #errors, #log
    slash("softtest")
    assert(#errors == before, "/gcr softtest raised an error")
    local help = false
    for i = mark + 1, #log do if log[i]:find("/gcr test         - API check", 1, true) then help = true end end
    assert(help, "/gcr softtest did not show the help")
end)
step("Long run (10 min) for leaks", function() slash("run herb") advance(600) slash("stop") end)

io.write("\n--- errors: " .. #errors .. "\n")
for _, e in ipairs(errors) do io.write("  " .. e .. "\n") end
io.write("\n--- notable log lines:\n")
for _, l in ipairs(log) do
    if l:find("questie nodes") or l:find("grey pins") or l:find("recipe sources") or l:find("route line") or l:find("route goal") or l:find("fish next") or l:find("SOUNDFILE") or l:find("RAIDWARN") or l:find("sync sent") or l:find("empty test") or l:find("prices ok") or l:find("scan price") or l:find("TTPRICE") or l:find("advisor") or l:find("target changes") or l:find("JUMP") or l:find("harvest cost") or l:find("slim:") or l:find("learned prices") or l:find("fishing session") or l:find("recipe item") or l:find("craft ") or l:find("recipes") or l:find("profit") or l:find("Price alert") or l:find("scanned") or l:find("Own scan") or l:find("15 minutes") or l:find("shared spawn") or l:find("Shared spawn") or l:find("Loaded") or l:find("took over") or l:find("RECORD") or l:find("No ") or l:find("rror") then
        io.write("  " .. l:sub(1, 160) .. "\n")
    end
end
