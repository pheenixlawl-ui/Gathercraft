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
function methods:GetFrameStrata() return self.__strata or "MEDIUM" end
function methods:SetFrameStrata(s) self.__strata = s end
function methods:IsEnabled() return self.__enabled ~= false end
function methods:Enable() self.__enabled = true end
function methods:Disable() self.__enabled = false end
function methods:GetName() return nil end
function methods:SetAttribute(k, v) self.__attr = self.__attr or {} self.__attr[k] = v end
function methods:GetAttribute(k) return self.__attr and self.__attr[k] end
function methods:GetStringWidth() return 50 end
function methods:SetPoint(p, ...) if p then self.__pts = self.__pts or {} self.__pts[p] = { ... } end end -- last anchor per point
function methods:ClearAllPoints() self.__pts = nil end
function methods:SetWordWrap(on) self.__wrap = on end
function methods:SetJustifyH(j) self.__justify = j end
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

-- the auction house API is there from the start, as in the game: Prices.lua
-- keeps this table from its load on, the tests fill in its functions
C_AuctionHouse = {}

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
    ns.db.miniPinStyle = "subtle" -- the default up to 0.1.16 (v0.1.17: ring only, own step)
    rebuild()
    assert(ns.SubtleMinimap(), "subtle when chosen")
    -- own finds are drawn above known spawn points (fixed order, also after a redraw)
    local ownSeen, questieSeen = false, false
    for _, pin in ipairs(MINI_ICONS) do
        local n = pin.node
        if n and not n.pendingReport then
            local want = (n.source == "questie") and 1 or (n.source == nil and 3 or 2)
            assert(pin.layer == want, ("pin layer %s for %s"):format(tostring(pin.layer), tostring(n.source)))
            pin:Show() pin.__scripts.OnShow(pin)
            -- one level up since 0.1.17: the route line lies between the minimap and the pins
            assert(pin:GetFrameLevel() == Minimap:GetFrameLevel() + want + 1, "frame level does not follow the layer")
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
step("Smart route: after a detour the old target is put where it fits, not at the end (v0.1.17)", function()
    -- in yards around the spot you end up at: the old target 400 north, two
    -- nodes 1200 west and 1240 east. Before 0.1.17 the old target went to the
    -- end: west, all the way east, back to the middle (1240 yd more).
    local Z = 1470
    local function at(dx, dy) return 0.5 + dx / 5000, 0.5 + dy / 3333 end
    local function own(dx, dy)
        local x, y = at(dx, dy)
        return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = y, count = 3, last = 1 }
    end
    ns.db.nodes[Z] = { own(0, 400), own(-1200, 600), own(1240, 600) }
    local old, west, east = ns.db.nodes[Z][1], ns.db.nodes[Z][2], ns.db.nodes[Z][3]
    player.map = Z
    player.x, player.y = at(0, 240)
    ns.StartRun("ore", Z) advance(1)
    assert(ns.run and ns.run.target == old, "test setup: the nearest node first")
    -- walk off 240 yd (a quest): a new target, the old one later
    player.x, player.y = at(0, 0) advance(1)
    local path = ns.run.path or {}
    assert(ns.run.target == west and #path == 3, "test setup: west is the new target")
    local order = {}
    for i, p in ipairs(path) do order[i] = p.node == old and "old" or p.node == west and "west" or p.node == east and "east" or "?" end
    assert(path[2].node == old and path[3].node == east, "the route goes " .. table.concat(order, ", "))
    -- the length is the one of the line you see
    local HBD = LibStub("HereBeDragons-2.0")
    local cx, cy = HBD:GetWorldCoordinatesFromZone(player.x, player.y, Z)
    local sum = 0
    for _, p in ipairs(path) do sum = sum + math.sqrt((p.wx - cx) ^ 2 + (p.wy - cy) ^ 2) cx, cy = p.wx, p.wy end
    assert(math.abs(sum - ns.run.length) < 1, ("length %d, the line is %d"):format(ns.run.length, sum))
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
step("Skill plan: what the plan makes itself is counted once, every profession (v0.1.18 S1-S4)", function()
    -- One shared stock per item for the whole plan: what you have plus what
    -- the plan's own steps make. Extra crafts of an intermediate only for the
    -- need that is still not covered after that.
    -- The steps are fixed by the test: each recipe gets a required skill and
    -- colours (yellow = grey = "upto") so it gives one point per craft from
    -- its required skill up to "upto" and nothing after it. Reagent amounts
    -- come from Data/RecipeData.lua; the test checks them first.
    local d = ns.CraftData
    local data = GathercraftRecipeData
    local saved = { known = d.Known, have = d.Have, rank = ns.ProfessionRank, price = ns.GetPrice,
        vendor = ns.db.vendorPrices, all = d.AllRecipes, spells = data.spells, colors = data.colors }
    local recipes = data.professions
    -- the stand-ins go back also when an assert fails (later steps use them)
    local ok, err = pcall(function()
    local function Uses(prof, key, id)
        local _, reagents = recipes[prof][key]:match("^([^|]+)|(.*)$")
        return tonumber((reagents or ""):match("%f[%d]" .. id .. ":(%d+)")) or 0
    end
    local function Makes(prof, key)
        local product, lo, hi = recipes[prof][key]:match("^(%d+):(%d+):(%d+):")
        return tonumber(product), (tonumber(lo) + tonumber(hi)) / 2
    end
    local stock, ranks, known = {}, {}, {}
    d.Have = function(id) return stock[id] or 0 end
    ns.ProfessionRank = function(p) local r = ranks[p] if r then return r, r end end
    d.Known = function(p) return known[p] or {} end
    -- prices: everything 10c at the auction house; vendor items cost what a vendor showed
    ns.GetPrice = function() return 10, "AH scan" end
    ns.db.vendorPrices = {}
    -- plan(prof, from, to, { { key, req, upto[, start] }, ... }): only these recipes, all known
    local function Plan(prof, from, to, list)
        local all, spells, colors = {}, {}, {}
        known[prof] = {}
        for i, r in ipairs(list) do
            local packed = recipes[prof][r[1]]:gsub("^(%d+:%d+:%d+:)%d+", "%1" .. r[2])
            all[r[1]], known[prof][r[1]] = packed, packed
            spells[r[1]] = 900000 + i
            colors[900000 + i] = r[3] .. ":" .. r[3]
        end
        d.AllRecipes = function(p) return p == prof and all or {} end
        data.spells, data.colors = { [prof] = spells }, colors
        local steps, mats, total, stuck = ns.SkillPlan(prof, from, to)
        data.spells, data.colors = saved.spells, saved.colors
        assert(not stuck, prof .. ": test setup: the plan got stuck at " .. tostring(stuck))
        for i, r in ipairs(list) do
            local s = steps[i]
            -- r[4]: where the step starts when that is not its required skill
            assert(s and s.recipe.key == r[1] and s.crafts == r[3] - (r[4] or math.max(r[2], from)),
                ("%s: test setup: step %d is %s x%s"):format(prof, i, s and s.recipe.key or "-", s and s.crafts or "-"))
        end
        local byId = {}
        for _, m in ipairs(mats) do
            assert(not byId[m.id], prof .. ": item " .. m.id .. " listed twice")
            byId[m.id] = m
        end
        return byId, total
    end
    local function Is(prof, m, id, need, missing, made)
        local row = m[id]
        assert(row, ("%s: item %d not in the list"):format(prof, id))
        assert(row.need == need and row.missing == missing,
            ("%s: item %d need %d missing %d, want %d / %d"):format(prof, id, row.need, row.missing, need, missing))
        assert((row.madeFrom ~= nil) == (made == true), ("%s: item %d %s"):format(prof, id, made and "is not made" or "is made"))
        if made then assert(row.cost == 0, prof .. ": an item you make has a cost") end
    end

    -- Leatherworking, Sven's plan: 1-25 Light Leather x24, 25-74 Light Armor Kit
    -- x49, 74-97 Embossed Leather Gloves x23
    assert(Uses("Leatherworking", "Light Leather", 2934) == 3 and Uses("Leatherworking", "Light Armor Kit", 2318) == 1
        and Uses("Leatherworking", "Embossed Leather Gloves", 2318) == 3 and Uses("Leatherworking", "Embossed Leather Gloves", 2320) == 2,
        "test setup: leather amounts changed in RecipeData")
    local LW = { { "Light Leather", 1, 25 }, { "Light Armor Kit", 25, 74 }, { "Embossed Leather Gloves", 74, 97 } }
    -- Light Leather: need 49 x 1 + 23 x 3 = 118; you have 35, the steps make 24
    -- -> 118 - 35 - 24 = 59 more; made in all 24 + 59 = 83 -> scraps 83 x 3 = 249
    -- Coarse Thread 23 x 2 = 46 (vendor 10c, at the AH 50c: the vendor counts)
    ns.GetPrice = function(id) return id == 2320 and 50 or 10, "AH scan" end
    ns.db.vendorPrices[2320] = 10
    stock = { [2318] = 35 }
    local m, total = Plan("Leatherworking", 1, 97, LW)
    Is("Leatherworking", m, 2318, 118, 0, true)
    Is("Leatherworking", m, 2934, 249, 249)
    Is("Leatherworking", m, 2320, 46, 46)
    -- what is missing, nothing else: 249 x 10c + 46 x 10c (vendor)
    assert(total == 249 * 10 + 46 * 10, ("Leatherworking: total %d, want %d"):format(total, 249 * 10 + 46 * 10))
    -- 34 in your bags: 60 more -> 84 crafts -> 252 scraps (S1 apart from S2)
    stock = { [2318] = 34 }
    m = Plan("Leatherworking", 1, 97, LW)
    Is("Leatherworking", m, 2934, 252, 252)
    -- enough leather already: no extra crafts, only the 24 of the steps (72 scraps)
    stock = { [2318] = 200, [2934] = 10 }
    m = Plan("Leatherworking", 1, 97, LW)
    Is("Leatherworking", m, 2934, 72, 62)
    ns.GetPrice = function() return 10, "AH scan" end

    -- Tailoring: 1-11 Bolt of Linen Cloth x10, 11-31 Brown Linen Robe x20
    assert(Uses("Tailoring", "Bolt of Linen Cloth", 2589) == 2 and Uses("Tailoring", "Brown Linen Robe", 2996) == 3
        and Uses("Tailoring", "Brown Linen Robe", 2320) == 1, "test setup: tailoring amounts changed")
    -- bolts: need 20 x 3 = 60; you have 5, the steps make 10 -> 45 more;
    -- linen (10 + 45) x 2 = 110; thread 20
    stock = { [2996] = 5 }
    m = Plan("Tailoring", 1, 31, { { "Bolt of Linen Cloth", 1, 11 }, { "Brown Linen Robe", 11, 31 } })
    Is("Tailoring", m, 2996, 60, 0, true)
    Is("Tailoring", m, 2589, 110, 110)
    Is("Tailoring", m, 2320, 20, 20)

    -- Blacksmithing with smelting (Mining 150, Smelt Copper known):
    -- 1-11 Rough Sharpening Stone x10, 11-21 Rough Grinding Stone x10,
    -- 21-41 Runed Copper Gauntlets x20
    assert(Uses("Blacksmithing", "Rough Sharpening Stone", 2835) == 1 and Uses("Blacksmithing", "Rough Grinding Stone", 2835) == 2
        and Uses("Blacksmithing", "Runed Copper Gauntlets", 2840) == 8 and Uses("Blacksmithing", "Runed Copper Gauntlets", 3470) == 2
        and Uses("Mining", "Smelt Copper", 2770) == 1, "test setup: blacksmithing amounts changed")
    ranks.Mining = 150
    known.Mining = { ["Smelt Copper"] = recipes.Mining["Smelt Copper"] }
    -- grinding stones: need 20 x 2 = 40, the steps make 10 -> 30 more (Rough
    -- Grinding Stone from skill 1 here, so you can make it at the start);
    -- rough stone 10 + (10 + 30) x 2 = 90; copper bars 20 x 8 = 160, you have
    -- 30 -> 130 smelted -> copper ore 130
    stock = { [2840] = 30 }
    m = Plan("Blacksmithing", 1, 41, { { "Rough Sharpening Stone", 1, 11 }, { "Rough Grinding Stone", 1, 21, 11 }, { "Runed Copper Gauntlets", 21, 41 } })
    Is("Blacksmithing", m, 3470, 40, 0, true)
    Is("Blacksmithing", m, 2835, 90, 90)
    Is("Blacksmithing", m, 2840, 160, 0, true)
    Is("Blacksmithing", m, 2770, 130, 130)

    -- Engineering: 1-11 Rough Blasting Powder x10, 11-31 Handful of Copper
    -- Bolts x20, 31-51 Rough Copper Bomb x20 (two bombs a craft)
    assert(Uses("Engineering", "Rough Blasting Powder", 2835) == 1 and Uses("Engineering", "Handful of Copper Bolts", 2840) == 1
        and Uses("Engineering", "Rough Copper Bomb", 4357) == 2 and Uses("Engineering", "Rough Copper Bomb", 4359) == 1
        and Uses("Engineering", "Rough Copper Bomb", 2840) == 1 and Uses("Engineering", "Rough Copper Bomb", 2589) == 1,
        "test setup: engineering amounts changed")
    -- powder: need 20 x 2 = 40, the steps make 10 -> 30 more -> rough stone 40;
    -- bolts: need 20, the steps make 20 -> none more; copper bars 20 (bolts)
    -- + 20 (bombs) = 40, you have 5 -> 35 smelted -> copper ore 35; linen 20
    ns.GetPrice = function(id) return id == 2840 and 50 or 10, "AH scan" end -- bars dear: powder first
    stock = { [2840] = 5 }
    m = Plan("Engineering", 1, 51, { { "Rough Blasting Powder", 1, 11 }, { "Handful of Copper Bolts", 11, 31 }, { "Rough Copper Bomb", 31, 51 } })
    Is("Engineering", m, 4357, 40, 0, true)
    Is("Engineering", m, 2835, 40, 40)
    Is("Engineering", m, 4359, 20, 0)
    Is("Engineering", m, 2840, 40, 0, true)
    Is("Engineering", m, 2770, 35, 35)
    Is("Engineering", m, 2589, 20, 20)
    ns.GetPrice = function() return 10, "AH scan" end
    ranks.Mining, known.Mining = nil, nil

    -- Enchanting: 1-2 Runed Copper Rod x1, 2-22 Enchant Bracer - Minor Stamina
    -- x20. The rod is a tool: no enchanting recipe lists it as a reagent, so
    -- it is made once and never counted again. The Copper Rod comes from a
    -- vendor (an enchanter can't make it): 1 x its vendor price.
    assert(Uses("Enchanting", "Runed Copper Rod", 6217) == 1 and Uses("Enchanting", "Enchant Bracer - Minor Stamina", 10940) == 2,
        "test setup: enchanting amounts changed")
    for key in pairs(recipes.Enchanting) do
        assert(Uses("Enchanting", key, 6218) == 0, "test setup: " .. key .. " uses up a Runed Copper Rod")
    end
    ns.db.vendorPrices[6217] = 124
    ns.GetPrice = function(id) if id ~= 6217 then return 10, "AH scan" end end -- the rod: vendor only
    stock = {}
    m, total = Plan("Enchanting", 1, 22, { { "Runed Copper Rod", 1, 2 }, { "Enchant Bracer - Minor Stamina", 2, 22 } })
    Is("Enchanting", m, 6217, 1, 1)
    assert(not m[6218], "Enchanting: the Runed Copper Rod is listed as a material")
    Is("Enchanting", m, 10940, 40, 40)
    local other = Uses("Enchanting", "Runed Copper Rod", 247786)
    Is("Enchanting", m, 247786, other, other)
    assert(total == 124 + 40 * 10 + other * 10, ("Enchanting: total %d"):format(total))
    ns.GetPrice = function() return 10, "AH scan" end

    -- Mining: 1-66 Smelt Copper x65, 66-76 Smelt Bronze x10 (1 copper + 1 tin
    -- -> 2 bronze). Copper bars: need 10, the steps make 65 -> none more ->
    -- copper ore 65 (not 75); tin bars 10, you have 10
    assert(Uses("Mining", "Smelt Bronze", 2840) == 1 and Uses("Mining", "Smelt Bronze", 3576) == 1, "test setup: smelting amounts changed")
    stock = { [3576] = 10 }
    m = Plan("Mining", 1, 76, { { "Smelt Copper", 1, 66 }, { "Smelt Bronze", 66, 76 } })
    Is("Mining", m, 2770, 65, 65)
    Is("Mining", m, 2840, 10, 0) -- the steps make them all: nothing extra to smelt
    Is("Mining", m, 3576, 10, 0)

    -- Alchemy: 1-21 Blackmouth Oil x20, 21-46 Swim Speed Potion x25
    assert(Uses("Alchemy", "Blackmouth Oil", 6358) == 2 and Uses("Alchemy", "Blackmouth Oil", 3371) == 1
        and Uses("Alchemy", "Swim Speed Potion", 6370) == 1 and Uses("Alchemy", "Swim Speed Potion", 3371) == 1
        and Uses("Alchemy", "Swim Speed Potion", 2452) == 1, "test setup: alchemy amounts changed")
    -- oil: need 25, you have 2, the steps make 20 -> 3 more; oily blackmouth
    -- (20 + 3) x 2 = 46; vials 20 + 3 (oil) + 25 (potions) = 48 at the vendor (4c)
    ns.db.vendorPrices[3371] = 4
    stock = { [6370] = 2 }
    m, total = Plan("Alchemy", 1, 46, { { "Blackmouth Oil", 1, 21 }, { "Swim Speed Potion", 21, 46 } })
    Is("Alchemy", m, 6370, 25, 0, true)
    Is("Alchemy", m, 6358, 46, 46)
    Is("Alchemy", m, 3371, 48, 48)
    Is("Alchemy", m, 2452, 25, 25)
    assert(total == 46 * 10 + 48 * 4 + 25 * 10, ("Alchemy: total %d"):format(total))

    -- Cooking and First Aid: the same calculation, no list of exceptions.
    -- 1-11 Charred Wolf Meat x10, 11-31 Spiced Wolf Meat x20: meat 30, spices
    -- 20 at the vendor (10c) -> 30 x 10c + 20 x 10c
    assert(Uses("Cooking", "Charred Wolf Meat", 2672) == 1 and Uses("Cooking", "Spiced Wolf Meat", 2678) == 1, "test setup: cooking amounts changed")
    ns.GetPrice = function(id) return id == 2678 and 99 or 10, "AH scan" end
    ns.db.vendorPrices[2678] = 10
    stock = {}
    m, total = Plan("Cooking", 1, 31, { { "Charred Wolf Meat", 1, 11 }, { "Spiced Wolf Meat", 11, 31 } })
    Is("Cooking", m, 2672, 30, 30)
    Is("Cooking", m, 2678, 20, 20)
    assert(total == 30 * 10 + 20 * 10, ("Cooking: total %d"):format(total))
    ns.GetPrice = function() return 10, "AH scan" end
    -- 1-41 Linen Bandage x40, 41-61 Heavy Linen Bandage x20: linen 40 + 40 = 80,
    -- you have 15 -> 65 missing
    assert(Uses("First Aid", "Linen Bandage", 2589) == 1 and Uses("First Aid", "Heavy Linen Bandage", 2589) == 2, "test setup: first aid amounts changed")
    stock = { [2589] = 15 }
    m, total = Plan("First Aid", 1, 61, { { "Linen Bandage", 1, 41 }, { "Heavy Linen Bandage", 41, 61 } })
    Is("First Aid", m, 2589, 80, 65)
    assert(total == 65 * 10, ("First Aid: total %d"):format(total))

    end)
    d.Known, d.Have, ns.ProfessionRank, ns.GetPrice, ns.db.vendorPrices = saved.known, saved.have, saved.rank, saved.price, saved.vendor
    d.AllRecipes, data.spells, data.colors = saved.all, saved.spells, saved.colors
    if not ok then error(err, 0) end
end)
step("Skill plan: counts again when the bags change (v0.1.18 S2)", function()
    -- Sven had 35 Light Leather, the plan said 34: the plan counted once when
    -- it opened, and loot, crafting or the bank after that never reached it
    local d = ns.CraftData
    local saved = { have = d.Have, rank = ns.ProfessionRank }
    local stock = { [2318] = 34 }
    d.Have = function(id) return stock[id] or 0 end
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return 30, 75 end end
    ns.ShowSkillPlan("Leatherworking") advance(1)
    local win = _G.GathercraftSkillPlan
    local name = ns.ItemName and ns.ItemName(2318) or "2318"
    local function Row()
        for _, o in ipairs(allFrames) do
            local t = o.GetText and o:IsShown() and o:GetText()
            if type(t) == "string" and t:find(name .. "  ", 1, true) == 1 and t:find(" / ", 1, true) then return t end
        end
    end
    local before = Row()
    assert(before and before:find("/ 34|r", 1, true), "test setup: Light Leather is not in the plan: " .. tostring(before))
    for _, e in ipairs({ "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_OPENED" }) do
        stock[2318] = (stock[2318] or 0) + 1
        fire(e) fire(e) fire(e) advance(1)
        local want = "/ " .. stock[2318] .. "|r"
        assert((Row() or ""):find(want, 1, true), ("after %s: %s, want %s"):format(e, tostring(Row()), want))
    end
    -- closed: nothing is counted
    win:Hide()
    local calls = 0
    d.Have = function(id) calls = calls + 1 return stock[id] or 0 end
    fire("BAG_UPDATE_DELAYED") advance(1)
    assert(calls == 0, "the closed plan counted again")
    d.Have, ns.ProfessionRank = saved.have, saved.rank
end)
step("Skill plan: the reagent bag counts, /gcr debug shows the parts (v0.1.18 S2)", function()
    -- C_Item.GetItemCount(item, includeBank, includeUses, includeReagentBank, ...):
    -- the reagent BANK is not the reagent BAG, so no parameter is guessed.
    -- The bag slots are counted too: holding more than the client's count
    -- without the bank, the client left the reagent bag out
    local saved = { count = C_Item.GetItemCount, info = C_Container.GetContainerItemInfo, slots = C_Container.GetContainerNumSlots,
        enum = Enum.BagIndex, debug = ns.db.debug }
    local slots = { [0] = { { itemID = 2318, stackCount = 20 }, { itemID = 2318, stackCount = 14 } }, [5] = { { itemID = 2318, stackCount = 1 } } }
    Enum.BagIndex = { ReagentBag = 5 }
    C_Container.GetContainerNumSlots = function(b) return slots[b] and #slots[b] or 0 end
    C_Container.GetContainerItemInfo = function(b, s) return slots[b] and slots[b][s] end
    local d = ns.CraftData
    local function Parts(what, total, bags, reagent, bank)
        fire("BAG_UPDATE_DELAYED")
        assert(d.Have(2318) == total, ("%s: you have %d, want %d"):format(what, d.Have(2318), total))
        local t, b, r, k = d.HaveParts(2318)
        assert(t == total and b == bags and r == reagent and k == bank,
            ("%s: total %s, bags %s, reagent bag %s, bank %s"):format(what, tostring(t), tostring(b), tostring(r), tostring(k)))
    end
    -- a client that leaves the reagent bag out: 34 in the bags, 3 in the bank
    C_Item.GetItemCount = function(id, bank) if id ~= 2318 then return 0 end return bank and 37 or 34 end
    Parts("reagent bag left out", 38, 34, 1, 3)
    -- a client that counts it: nothing is added twice
    C_Item.GetItemCount = function(id, bank) if id ~= 2318 then return 0 end return bank and 38 or 35 end
    Parts("reagent bag counted", 38, 34, 1, 3)
    -- the bags changed: counted again after the update
    slots[5][1].stackCount = 4
    Parts("after a bag update", 41, 34, 4, 3)
    -- no slot functions: the client's count alone
    C_Container.GetContainerItemInfo = nil
    fire("BAG_UPDATE_DELAYED")
    assert(d.Have(2318) == 38 and select(2, d.HaveParts(2318)) == nil, "without slot functions")
    C_Container.GetContainerItemInfo = function(b, s) return slots[b] and slots[b][s] end
    -- /gcr debug: one line per material, again only when its count changes
    ns.db.debug = true
    local saveRank = ns.ProfessionRank
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return 30, 75 end end
    C_Item.GetItemCount = function(id, bank) if id ~= 2318 then return 0 end return bank and 37 or 34 end
    fire("BAG_UPDATE_DELAYED")
    local name = ns.ItemName and ns.ItemName(2318) or "2318"
    local line = ("PLAN have %s: bags 34, reagent bag 4, bank 3, total 41"):format(name)
    local function Said(from)
        local n = 0
        for i = from + 1, #log do if log[i]:find(line, 1, true) then n = n + 1 end end
        return n
    end
    local mark = #log
    ns.ShowSkillPlan("Leatherworking") advance(1)
    ns.ShowSkillPlan("Leatherworking") advance(1)
    assert(Said(mark) == 1, ("the debug line came %d times: %s"):format(Said(mark), line))
    ns.db.debug = false
    mark = #log
    slots[0][1].stackCount = 21
    fire("BAG_UPDATE_DELAYED")
    ns.ShowSkillPlan("Leatherworking") advance(1)
    for i = mark + 1, #log do assert(not log[i]:find("PLAN have", 1, true), "a debug line without /gcr debug") end
    _G.GathercraftSkillPlan:Hide()
    ns.ProfessionRank = saveRank
    C_Item.GetItemCount, C_Container.GetContainerItemInfo, C_Container.GetContainerNumSlots = saved.count, saved.info, saved.slots
    Enum.BagIndex, ns.db.debug = saved.enum, saved.debug
    fire("BAG_UPDATE_DELAYED")
end)
step("Recipe import: a hotfix only changes the source values it was written for (v0.1.18, Codex N3)", function()
    -- tools/import_skillup.lua on a small SkillUp source of one recipe,
    -- Tanning Rack (hotfix 06.11.2026: skill 140 -> 125, thresholds 15
    -- lower), written to a temp folder
    local windows = package.config:sub(1, 1) == "\\"
    local dir = os.tmpname()
    os.remove(dir)
    os.execute(windows and ('mkdir "' .. dir .. '\\Data"') or ("mkdir -p '" .. dir .. "/Data'"))
    local function Write(file, body)
        local f = assert(io.open(dir .. "/Data/" .. file, "w"))
        f:write("local _, ns = ...\n" .. body .. "\n")
        f:close()
    end
    local function Import(required, t)
        Write("Recipes.lua", "ns.RecipeData = { [1263031] = { skillLine = 165, output = { itemID = 1263032, quantity = 1 }, "
            .. "reagents = { { itemID = 2318, quantity = 4 } } } }\nns.RecipeNames = { [165] = { [\"Tanning Rack\"] = 1263031 } }")
        Write("Thresholds.lua", ("ns.Thresholds = { [1263031] = { %d, %d, %d, %d } }"):format(t[1], t[2], t[3], t[4]))
        Write("Trainer.lua", ("ns.TrainerFees = { [1263031] = { 500, %d } }"):format(required))
        local out, warn = {}, {}
        local keep = { print = print, arg = arg, stderr = io.stderr }
        print = function(s) out[#out + 1] = tostring(s) end
        arg = { dir }
        io.stderr = { write = function(_, s) warn[#warn + 1] = s end }
        local ok, err = pcall(assert(loadfile(ROOT .. "/tools/import_skillup.lua")))
        print, arg, io.stderr = keep.print, keep.arg, keep.stderr
        assert(ok, "import: " .. tostring(err))
        local text = table.concat(out, "\n")
        local req = tonumber(text:match('%["Tanning Rack"%] = "%d+:%d+:%d+:(%d+)|'))
        local colors = text:match('%[1263031%]="(%d+:%d+)"')
        local hotfixWarn
        for _, w in ipairs(warn) do if w:find("hotfix Tanning Rack", 1, true) then hotfixWarn = w end end
        return req, colors, hotfixWarn
    end
    local ok, err = pcall(function()
        -- the old source: the hotfix applies
        local req, colors, warn = Import(140, { 140, 140, 142, 145 })
        assert(req == 125 and colors == "125:130" and not warn, ("old source: %s %s %s"):format(tostring(req), tostring(colors), tostring(warn)))
        -- a source that has the hotfix already: not lowered a second time (was 110:115)
        req, colors, warn = Import(125, { 125, 125, 127, 130 })
        assert(req == 125 and colors == "125:130", ("updated source: %s %s"):format(tostring(req), tostring(colors)))
        assert(warn and warn:find("already", 1, true), "updated source: no note")
        -- other values: left as they are, with a warning
        req, colors, warn = Import(150, { 150, 150, 152, 155 })
        assert(req == 150 and colors == "150:155" and warn, ("other source: %s %s %s"):format(tostring(req), tostring(colors), tostring(warn)))
    end)
    os.execute(windows and ('rmdir /s /q "' .. dir .. '"') or ("rm -rf '" .. dir .. "'"))
    if not ok then error(err, 0) end
end)
step("Minimap guesses nobody confirmed go after 30 days (v0.1.18 S6)", function()
    local DAY = 24 * 3600
    local now = time()
    local keep = ns.db.nodes[1450]
    local function Guess(id, age, extra)
        local n = { id = id, name = "Peacebloom", type = "herb", x = 0.1 + #ns.db.nodes[1450] * 0.05, y = 0.3, count = 1, last = 1,
            seenOnly = true, seenAt = age and (now - age) or nil, upAt = 1, seenErr = 20 }
        for k, v in pairs(extra or {}) do n[k] = v end
        table.insert(ns.db.nodes[1450], n)
        return n
    end
    ns.db.nodes[1450] = {}
    local d29 = Guess("o2001", 29 * DAY)
    local d30 = Guess("o2002", 30 * DAY)
    local d31 = Guess("o2003", 31 * DAY)
    local again = Guess("o2004", 40 * DAY)
    local undated = Guess("o2005", nil)
    local questie = Guess("o2006", 90 * DAY, { source = "questie" })
    local starter = Guess("o2007", 90 * DAY, { source = "starter" })
    local synced = Guess("o2008", 90 * DAY, { source = "sync", heard = 1 })
    local confirmed = Guess("o2009", 90 * DAY, { heard = 1, heardBy = { Someone = true } })
    -- harvested: a normal node (no longer a guess), however old
    local harvested = { id = "o2010", name = "Peacebloom", type = "herb", x = 0.9, y = 0.9, count = 3, hits = 3, last = now - 90 * DAY }
    table.insert(ns.db.nodes[1450], harvested)
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    -- seen again on the minimap just now: its 40 days start over
    player.map, player.x, player.y = 1450, again.x, again.y
    advance(10)
    ns.SeenOnMinimap(1450, again.x, again.y, "Peacebloom", 20)
    assert(again.seenAt == time(), "test setup: the new look didn't reach the old guess")
    -- the ages exactly at the login below: 29, 30 and 31 days
    d29.seenAt, d30.seenAt, d31.seenAt = time() - 29 * DAY, time() - 30 * DAY, time() - 31 * DAY
    -- the login clears up (all zones in one go, one debug line)
    local wasDebug = ns.db.debug
    ns.db.debug = true
    local mark = #log
    for f in pairs(eventFrames.PLAYER_LOGIN) do
        if eventFrames.ADDON_LOADED and eventFrames.ADDON_LOADED[f] then f.__scripts.OnEvent(f, "PLAYER_LOGIN") end
    end
    ns.db.debug = wasDebug
    local left = {}
    for _, n in ipairs(ns.db.nodes[1450] or {}) do left[n] = true end
    assert(left[d29], "29 days: gone")
    assert(not left[d30] and not left[d31], "30 / 31 days: still there")
    assert(left[again], "seen again: gone")
    assert(left[undated] and undated.seenAt and undated.seenAt >= now, "without a date: gone or no date set")
    assert(left[questie] and left[starter] and left[synced], "a Questie, starter or shared node went")
    assert(left[confirmed], "a guess another player confirmed went")
    assert(left[harvested], "a harvested node went")
    local said = 0
    for i = mark + 1, #log do
        if log[i]:find("2 rough minimap guesses gone", 1, true) then said = said + 1 end
    end
    assert(said == 1, "the login said it " .. said .. " times")
    ns.db.nodes[1450] = keep
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Minimap guesses: merging at login keeps what protects them from the 30 days (v0.1.18 F1)", function()
    -- Codex H1 (08.11.): ConsolidateSeen runs right before ExpireGuesses. Two
    -- undated guesses got the date 0 (gone at once), and a confirmation on
    -- the second guess of a pair was lost (gone, or not, by list order).
    local DAY = 24 * 3600
    local Z = 1450
    local keep = ns.db.nodes[Z]
    ns.db.nodes[Z] = {}
    local spot = 0
    -- a pair of guesses of one kind about 5 yd apart, each pair far from the others
    local function Pair(id, a, b)
        spot = spot + 1
        local x = 0.05 + spot * 0.07
        local out = {}
        for i, extra in ipairs({ a, b }) do
            local n = { id = id, name = "Peacebloom", type = "herb", x = x + (i - 1) * 0.001, y = 0.4, count = 1, last = 1,
                seenOnly = true, seenErr = 20, upAt = 1 }
            for k, v in pairs(extra) do n[k] = v end
            table.insert(ns.db.nodes[Z], n)
            out[i] = n
        end
        return out[1], out[2], x
    end
    local now = time()
    local function Ago(days) return now - days * DAY end
    -- A: both without a date
    local A1, A2, ax = Pair("o2101", {}, {})
    -- B: 40 days old, the confirmed one second, then first
    local B1, B2, bx = Pair("o2102", { seenAt = Ago(40) }, { seenAt = Ago(40), heard = 1, heardBy = { Reporter = true } })
    local C1, C2, cx = Pair("o2103", { seenAt = Ago(40), heard = 1, heardBy = { Reporter = true } }, { seenAt = Ago(40) })
    -- shared spots: the source of the second one counts too
    local S1, S2, sx = Pair("o2104", { seenAt = Ago(90) }, { seenAt = Ago(90), source = "sync" })
    -- the youngest known date counts; an unknown one is no date
    local D29a, D29b, d29x = Pair("o2105", { seenAt = Ago(35) }, { seenAt = Ago(29) })
    local D30a, D30b, d30x = Pair("o2106", { seenAt = Ago(40) }, { seenAt = Ago(30) })
    local D31a, D31b, d31x = Pair("o2107", { seenAt = Ago(45) }, { seenAt = Ago(31) })
    local U1, U2, ux = Pair("o2108", {}, { seenAt = Ago(29) })
    -- confirmations by the same and by another player: each player once
    local H1, H2, hx = Pair("o2109", { seenAt = Ago(60), heard = 1, heardBy = { Ann = true } },
        { seenAt = Ago(60), heard = 2, heardBy = { Ann = true, Bob = true } })
    -- close to a harvested node: the guesses merge and go, the node stays
    local G1, G2, gx = Pair("o2110", { seenAt = Ago(40) }, { seenAt = Ago(40) })
    local harvested = { id = "o2110", name = "Peacebloom", type = "herb", x = gx + 0.0005, y = 0.4, count = 3, hits = 3, last = Ago(90) }
    table.insert(ns.db.nodes[Z], harvested)
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
    -- the login: merge, then the 30 days (the whole chain)
    for f in pairs(eventFrames.PLAYER_LOGIN) do
        if eventFrames.ADDON_LOADED and eventFrames.ADDON_LOADED[f] then f.__scripts.OnEvent(f, "PLAYER_LOGIN") end
    end
    local at = {}
    for _, n in ipairs(ns.db.nodes[Z] or {}) do
        local key = math.floor((n.x - 0.05) / 0.07 + 0.5)
        at[key] = at[key] or {}
        table.insert(at[key], n)
    end
    local function Left(x, what)
        local list = at[math.floor((x - 0.05) / 0.07 + 0.5)] or {}
        local guesses = {}
        for _, n in ipairs(list) do if n.seenOnly then guesses[#guesses + 1] = n end end
        assert(#guesses <= 1, ("%s: %d guesses left, not merged into one"):format(what, #guesses))
        return guesses[1], list
    end
    local a = Left(ax, "A")
    assert(a, "A: two close undated guesses went at the login")
    assert(a.seenAt and a.seenAt >= now, "A: no date of today after the merge: " .. tostring(a.seenAt))
    local b = Left(bx, "B")
    assert(b and (b.heard or 0) >= 1 and b.heardBy and b.heardBy.Reporter, "B: the confirmation of the second guess was lost")
    local c = Left(cx, "B reversed")
    assert(c and (c.heard or 0) >= 1 and c.heardBy and c.heardBy.Reporter, "B reversed: the confirmed guess went")
    local s = Left(sx, "shared")
    assert(s and s.source == "sync", "a shared spot merged into an own guess went: " .. tostring(s and s.source))
    local d29 = Left(d29x, "29 days")
    assert(d29 and d29.seenAt == Ago(29), "29 days after the merge: gone, or not the youngest date")
    assert(not Left(d30x, "30 days") and not Left(d31x, "31 days"), "30 / 31 days after the merge: still there")
    local u = Left(ux, "one date unknown")
    assert(u and u.seenAt == Ago(29), "an unknown date took the place of the known one: " .. tostring(u and u.seenAt))
    local h = Left(hx, "confirmations")
    assert(h and h.heardBy and h.heardBy.Ann and h.heardBy.Bob, "confirmations: not every player kept")
    local names = 0
    for _ in pairs(h.heardBy) do names = names + 1 end
    assert(names == 2 and h.heard == 2, ("confirmations: %d players, heard %s (each player once)"):format(names, tostring(h.heard)))
    local g, glist = Left(gx, "harvested")
    assert(not g, "next to a harvested node: 40 days old guesses stayed")
    assert(#glist == 1 and glist[1] == harvested, "next to a harvested node: the harvested node went or changed")
    ns.db.nodes[Z] = keep
    ns.NotifyNodesChanged() ns.ForgetSeenKinds()
end)
step("Craft log: one entry per finished craft, failures and odd cases marked apart (v0.1.18 S5)", function()
    local data = GathercraftRecipeData
    local spell = data.spells.Leatherworking["Light Leather"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], log = ns.db.craftLog,
        off = ns.db.craftLogOff, secret = issecretvalue }
    local rank, maxRank, bag = 10, 75, 0
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, maxRank end end
    ns.CraftData.Have = function(id) return id == 2318 and bag or 0 end
    data.colors[spell] = "20:40" -- orange below 20, yellow below 30, green below 40, grey from 40
    ns.db.craftLog, ns.db.craftLogOff = {}, nil
    local keepMulti = ns.db.craftMulti ns.db.craftMulti = nil -- (F2: the note of a multi-point craft)
    local n = 0
    local function Craft(gain, events, made)
        n = n + 1
        local guid = "Cast-3-1-1-1-" .. spell .. "-" .. n
        for _, e in ipairs(events or { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED" }) do
            if e == "UNIT_SPELLCAST_SUCCEEDED" then
                if gain and gain ~= 0 then rank = rank + gain end
                bag = bag + (made or 1)
            end
            fire(e, "player", guid, spell)
        end
        advance(2)
        return guid
    end
    local function Last() return ns.db.craftLog[#ns.db.craftLog] end
    local ok, err = pcall(function()
        -- a skill-up: everything that is known about it
        Craft(1)
        local e = Last()
        assert(#ns.db.craftLog == 1 and e.result == "ok", "no entry for a finished craft")
        assert(e.prof == "Leatherworking" and e.recipe == "Light Leather" and e.spell == spell, "profession or recipe")
        assert(e.before == 10 and e.after == 11 and e.gain == 1 and e.max == 75, ("skill %s -> %s"):format(tostring(e.before), tostring(e.after)))
        assert(e.colour == "orange" and e.yellow == 20 and e.grey == 40, "colour " .. tostring(e.colour))
        assert(e.made == 1 and e.build == 70450 and e.t, ("made %s, build %s"):format(tostring(e.made), tostring(e.build)))
        assert(not e.multi and not e.atCap and not e.secret, "marked although nothing odd")
        -- no skill-up (yellow at 25)
        rank = 25
        Craft(0)
        assert(Last().gain == 0 and Last().colour == "yellow", "a craft without a skill-up")
        -- failed: FAILED and INTERRUPTED of one cast are one entry
        Craft(0, { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED" })
        assert(#ns.db.craftLog == 3 and Last().result == "failed", "a failed cast")
        Craft(0, { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_INTERRUPTED" })
        assert(#ns.db.craftLog == 4 and Last().result == "interrupted", "an interrupted cast")
        -- more than one point
        rank = 35
        Craft(2)
        assert(Last().multi and Last().gain == 2 and Last().colour == "yellow", "a gain of two points (35 of 20:40 is yellow since K3, no green threshold)")
        -- at the rank's maximum
        rank, maxRank = 75, 75
        Craft(0)
        assert(Last().atCap, "a craft at the maximum")
        rank, maxRank = 45, 75
        -- the same cast twice, and a late failure of it: one craft
        local count = #ns.db.craftLog
        local guid = Craft(1)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", guid, spell)
        fire("UNIT_SPELLCAST_FAILED", "player", guid, spell)
        advance(2)
        assert(#ns.db.craftLog == count + 1 and Last().colour == "grey", ("one cast: %d entries"):format(#ns.db.craftLog - count))
        -- a value the client hides: marked, nothing made up
        local SECRET = newproxy(true)
        issecretvalue = function(v) return rawequal(v, SECRET) end
        rank = SECRET
        Craft(0)
        assert(Last().secret and Last().before == nil and Last().gain == nil, "a hidden skill")
        rank = 45
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, spell) advance(2)
        -- since F2 (Codex M2): only a recipe spell counts, and it says which
        assert(Last().secret and Last().recipe == "Light Leather" and Last().gain == nil, "a hidden cast")
        issecretvalue = saved.secret
        -- not a recipe (a gathering spell): nothing
        count = #ns.db.craftLog
        fire("UNIT_SPELLCAST_START", "player", "Cast-x", 2366) fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-x", 2366) advance(2)
        assert(#ns.db.craftLog == count, "a gathering spell in the craft log")
        -- /gcr craftlog: per colour and per distance to grey; the odd ones apart
        local mark = #log
        slash("craftlog")
        local text = table.concat(log, "\n", mark + 1)
        -- (7 since 0.1.21, T7: the two failed or interrupted casts are no crafts)
        assert(text:find((ns.L["Craft log: %d crafts (kept on this computer, never shared)."]):format(7), 1, true), "no count in /gcr craftlog: " .. text)
        assert(text:find((ns.L["  %s: %d crafts, %d skill-ups (%d%%)"]):format("|cffff8040" .. ns.L["orange"] .. "|r", 1, 1, 100), 1, true), "orange line: " .. text)
        assert(text:find((ns.L["  %s points below grey: %d crafts, %d skill-ups (%d%%)"]):format("5-9", 1, 1, 100), 1, true), "distance line: " .. text)
        assert(text:find((ns.L["  Not counted: %d failed or interrupted, %d unreadable, %d overlapping, %d at the rank's maximum; %d gave more than one point."]):format(2, 2, 0, 1, 1), 1, true), "not counted: " .. text)
        -- turned off: nothing is recorded
        ns.db.craftLogOff = true
        count = #ns.db.craftLog
        Craft(1)
        assert(#ns.db.craftLog == count, "recorded although turned off")
        ns.db.craftLogOff = nil
        -- the newest 5000 are kept
        local full = {}
        for i = 1, 5000 do full[i] = { t = i, result = "ok", colour = "unknown" } end
        ns.db.craftLog = full
        Craft(1)
        assert(#ns.db.craftLog == 5000 and ns.db.craftLog[1].t == 2 and Last().recipe == "Light Leather", "the list is not kept at 5000")
        slash("craftlog clear")
        assert(#ns.db.craftLog == 0, "/gcr craftlog clear")
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell] = saved.rank, saved.have, saved.colors
    ns.db.craftLog, ns.db.craftLogOff, issecretvalue = saved.log, saved.off, saved.secret
    ns.db.craftMulti = keepMulti
    if not ok then error(err, 0) end
end)
step("Craft log: only clear observations count; no other spells, hidden amounts, clear (v0.1.18 F2)", function()
    -- Codex M1, M2, V1, N2 (08.11.)
    local data = GathercraftRecipeData
    local spell = data.spells.Leatherworking["Light Leather"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], log = ns.db.craftLog,
        off = ns.db.craftLogOff, secret = issecretvalue }
    local SECRET = newproxy(true)
    local rank, maxRank, bag = 10, 75, 0
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, maxRank end end
    ns.CraftData.Have = function(id) if id == 2318 then return bag end return 0 end
    data.colors[spell] = "20:40"
    ns.db.craftLog, ns.db.craftLogOff = {}, nil
    local keepMulti = ns.db.craftMulti ns.db.craftMulti = nil -- (F2: the note of a multi-point craft)
    local n = 0
    local function Guid() n = n + 1 return "Cast-3-1-1-1-" .. spell .. "-f2-" .. n end
    local function Line()
        local mark = #log
        slash("craftlog")
        return table.concat(log, "\n", mark + 1)
    end
    local ok, err = pcall(function()
        -- M1: two crafts, the second ends before the first is read again.
        -- Really: one skill-up, two items. Neither may count as a clear 1/1.
        -- Since K2 (0.1.20) the two are one block: 2 tries, 1 skill-up.
        local g1, g2 = Guid(), Guid()
        fire("UNIT_SPELLCAST_START", "player", g1, spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g1, spell)
        bag = bag + 1
        advance(0.5)
        fire("UNIT_SPELLCAST_START", "player", g2, spell)
        rank = rank + 1
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g2, spell)
        bag = bag + 1
        advance(2)
        assert(#ns.db.craftLog == 3, "two chained crafts: " .. #ns.db.craftLog .. " entries (want 2 and their block)")
        for i = 1, 2 do assert(ns.db.craftLog[i].overlap and ns.db.craftLog[i].inSeries, "a chained craft not marked") end
        local block = ns.db.craftLog[3]
        assert(block.kind == "series" and block.n == 2 and block.before == 10 and block.after == 11 and block.gain == 1, "the block of the two")
        local byColour, _, other = ns.CraftLogSummary()
        assert(byColour.orange and byColour.orange.tries == 2 and byColour.orange.ups == 1, ("the block in the rate: %s/%s"):format(
            tostring(byColour.orange and byColour.orange.ups), tostring(byColour.orange and byColour.orange.tries)))
        assert(other.overlap == 0 and other.series == 1, "counted as overlapping although a clear block: " .. tostring(other.overlap))
        local text = Line()
        assert(text:find((ns.L["  Not counted: %d failed or interrupted, %d unreadable, %d overlapping, %d at the rank's maximum; %d gave more than one point."]):format(0, 0, 0, 0, 0), 1, true),
            "/gcr craftlog: the block's crafts named as overlapping: " .. text)
        -- started while the one before was still being read: overlapping too
        local g3, g4 = Guid(), Guid()
        fire("UNIT_SPELLCAST_START", "player", g3, spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g3, spell)
        advance(0.5)
        fire("UNIT_SPELLCAST_START", "player", g4, spell)
        advance(1.5)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g4, spell)
        advance(2)
        assert(ns.db.craftLog[4].overlap and ns.db.craftLog[5].overlap, "a craft started inside the last one's reading: not marked")
        assert(ns.db.craftLog[6] and ns.db.craftLog[6].kind == "series" and ns.db.craftLog[6].n == 2 and ns.db.craftLog[6].gain == 0, "a chained pair without a skill-up: no block of 2 tries, 0 ups")
        -- single crafts with time between them: as before
        ns.db.craftLog = {}
        rank = 10
        local g5 = Guid()
        fire("UNIT_SPELLCAST_START", "player", g5, spell)
        rank = rank + 1 bag = bag + 1
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g5, spell)
        advance(2)
        local g6 = Guid()
        fire("UNIT_SPELLCAST_START", "player", g6, spell)
        bag = bag + 1
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g6, spell)
        advance(2)
        byColour = ns.CraftLogSummary()
        assert(byColour.orange and byColour.orange.tries == 2 and byColour.orange.ups == 1, "single crafts no longer counted")
        assert(not ns.db.craftLog[1].overlap and not ns.db.craftLog[2].overlap and ns.db.craftLog[1].made == 1, "single crafts marked")
        -- M2: a hidden cast ID, but a spell that is no recipe (Herbalism): nothing
        issecretvalue = function(v) return rawequal(v, SECRET) end
        local count = #ns.db.craftLog
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, 2366)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, 2366)
        advance(2)
        assert(#ns.db.craftLog == count, "a gathering spell with a hidden cast ID in the craft log: " .. (#ns.db.craftLog - count))
        -- spell hidden too: not a craft
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, SECRET) advance(2)
        assert(#ns.db.craftLog == count, "a cast with nothing readable stored as a craft")
        -- a real craft with a hidden cast ID, its event twice: one entry
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, spell)
        advance(2)
        assert(#ns.db.craftLog == count + 1, "a hidden-ID craft twice: " .. (#ns.db.craftLog - count) .. " entries")
        local e = ns.db.craftLog[#ns.db.craftLog]
        assert(e.secret and e.recipe == "Light Leather" and e.gain == nil, "a hidden-ID craft: what it is or that it is unreadable")
        -- V1: the amount in the bags is hidden: unreadable, no error
        local g7 = Guid()
        bag = SECRET
        fire("UNIT_SPELLCAST_START", "player", g7, spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g7, spell)
        advance(2)
        e = ns.db.craftLog[#ns.db.craftLog]
        assert(e.recipe == "Light Leather" and e.secret and e.made == nil, "a hidden amount: not marked unreadable")
        bag = 5
        local g8 = Guid()
        fire("UNIT_SPELLCAST_START", "player", g8, spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g8, spell)
        bag = SECRET
        advance(2)
        e = ns.db.craftLog[#ns.db.craftLog]
        assert(e.secret and e.made == nil, "a hidden amount after the craft: not marked unreadable")
        bag = 5
        issecretvalue = saved.secret
        -- N2: clear while a craft is still being read: it stays empty
        local g9 = Guid()
        fire("UNIT_SPELLCAST_START", "player", g9, spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g9, spell)
        advance(0.5)
        slash("craftlog clear")
        advance(2)
        assert(#ns.db.craftLog == 0, "/gcr craftlog clear: a craft read afterwards came back")
        -- after the clear the log works again
        local g10 = Guid()
        fire("UNIT_SPELLCAST_START", "player", g10, spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g10, spell)
        advance(2)
        assert(#ns.db.craftLog == 1 and not ns.db.craftLog[1].overlap, "after the clear: no new entry, or marked overlapping")
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell] = saved.rank, saved.have, saved.colors
    ns.db.craftLog, ns.db.craftLogOff, issecretvalue = saved.log, saved.off, saved.secret
    ns.db.craftMulti = keepMulti
    if not ok then error(err, 0) end
end)
step("Craft log: a craft with a hidden cast ID marks the one still being read as overlapping (v0.1.18 B1)", function()
    -- Codex round 2 (08.11.): A readable, no skill-up; 0.5 s later B, same
    -- recipe, hidden cast ID, one skill-up. A must not count as 1/1.
    local data = GathercraftRecipeData
    local spell = data.spells.Leatherworking["Light Leather"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], log = ns.db.craftLog,
        off = ns.db.craftLogOff, secret = issecretvalue }
    local SECRET = newproxy(true)
    local rank, bag = 10, 0
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, 75 end end
    ns.CraftData.Have = function(id) if id == 2318 then return bag end return 0 end
    data.colors[spell] = "20:40"
    ns.db.craftLog, ns.db.craftLogOff = {}, nil
    local keepMulti = ns.db.craftMulti ns.db.craftMulti = nil -- (F2: the note of a multi-point craft)
    local ok, err = pcall(function()
        issecretvalue = function(v) return rawequal(v, SECRET) end
        fire("UNIT_SPELLCAST_START", "player", "Cast-b1-A", spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-b1-A", spell)
        bag = bag + 1
        advance(0.5)
        rank, bag = rank + 1, bag + 1
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, spell)
        advance(2)
        assert(#ns.db.craftLog == 2, "entries: " .. #ns.db.craftLog)
        local a = ns.db.craftLog[1].recipe and not ns.db.craftLog[1].secret and ns.db.craftLog[1] or ns.db.craftLog[2]
        assert(a.overlap, ("A was read alone: gain %s, made %s"):format(tostring(a.gain), tostring(a.made)))
        local byColour, _, other = ns.CraftLogSummary()
        assert(not byColour.orange, ("A in the rate: %s/%s"):format(tostring(byColour.orange and byColour.orange.ups),
            tostring(byColour.orange and byColour.orange.tries)))
        assert(other.overlap >= 1, "not counted as overlapping")
        -- the other way round: B hidden first, A readable while nothing is read: A alone counts
        ns.db.craftLog = {}
        advance(3)
        fire("UNIT_SPELLCAST_START", "player", "Cast-b1-C", spell)
        rank, bag = rank + 1, bag + 1
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-b1-C", spell)
        advance(2)
        assert(not ns.db.craftLog[1].overlap and ns.db.craftLog[1].gain == 1, "a single readable craft is marked")
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell] = saved.rank, saved.have, saved.colors
    ns.db.craftLog, ns.db.craftLogOff, issecretvalue = saved.log, saved.off, saved.secret
    ns.db.craftMulti = keepMulti
    if not ok then error(err, 0) end
end)
step("Craft log: clear while a craft is still being cast drops it too (v0.1.18 B2)", function()
    -- Codex round 2 (08.11.): START, /gcr craftlog clear, SUCCEEDED - the
    -- success made a new entry in the log just emptied
    local data = GathercraftRecipeData
    local spell = data.spells.Leatherworking["Light Leather"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, log = ns.db.craftLog, off = ns.db.craftLogOff }
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return 10, 75 end end
    ns.CraftData.Have = function() return 0 end
    ns.db.craftLog, ns.db.craftLogOff = {}, nil
    local keepMulti = ns.db.craftMulti ns.db.craftMulti = nil -- (F2: the note of a multi-point craft)
    local ok, err = pcall(function()
        advance(3)
        fire("UNIT_SPELLCAST_START", "player", "Cast-b2-A", spell)
        slash("craftlog clear")
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-b2-A", spell)
        advance(2)
        assert(#ns.db.craftLog == 0, "a craft cast through the clear came back: " .. #ns.db.craftLog)
        -- a failure of it after the clear: nothing either
        fire("UNIT_SPELLCAST_START", "player", "Cast-b2-B", spell)
        slash("craftlog clear")
        fire("UNIT_SPELLCAST_FAILED", "player", "Cast-b2-B", spell)
        advance(2)
        assert(#ns.db.craftLog == 0, "a failed cast through the clear came back")
        -- a craft started after the clear is logged as usual
        fire("UNIT_SPELLCAST_START", "player", "Cast-b2-C", spell)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-b2-C", spell)
        advance(2)
        assert(#ns.db.craftLog == 1 and ns.db.craftLog[1].recipe == "Light Leather", "a craft after the clear is not logged")
    end)
    ns.ProfessionRank, ns.CraftData.Have = saved.rank, saved.have
    ns.db.craftLog, ns.db.craftLogOff = saved.log, saved.off
    ns.db.craftMulti = keepMulti
    if not ok then error(err, 0) end
end)
step("Craft log: a Create All series counts as one block, only when it is clear (v0.1.20 K2)", function()
    -- Sven (09.11.): 10 cooks, 3 alone (orange, 3/3), 7 by Create All -
    -- every one gave a point, all 7 landed under "overlapping"
    local data = GathercraftRecipeData
    local spell, other = data.spells.Leatherworking["Light Leather"], data.spells.Leatherworking["Light Armor Kit"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], colors2 = data.colors[other],
        log = ns.db.craftLog, off = ns.db.craftLogOff, secret = issecretvalue }
    local SECRET = newproxy(true)
    local rank, maxRank = 10, 75
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, maxRank end end
    ns.CraftData.Have = function() return 0 end
    data.colors[spell], data.colors[other] = "25:45", "25:45" -- orange below 25, yellow below 45, grey from 45
    ns.db.craftLog, ns.db.craftLogOff = {}, nil
    local keepMulti = ns.db.craftMulti ns.db.craftMulti = nil -- (F2: the note of a multi-point craft)
    local n = 0
    local function Guid() n = n + 1 return "Cast-k2-" .. n end
    -- one craft: START, the cast time, SUCCEEDED (or what `events` says); the skill rises by `gain`
    local function Cast(gain, castTime, events, sp)
        sp = sp or spell
        local guid = Guid()
        events = events or { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED" }
        for i, e in ipairs(events) do
            if i > 1 and castTime and castTime > 0 then advance(castTime) end
            if e == "UNIT_SPELLCAST_SUCCEEDED" and gain and gain ~= 0 then rank = rank + gain end
            fire(e, "player", guid, sp)
        end
        return guid
    end
    -- a Create All series: the next cast starts right after the last success
    local function Series(gains, castTime, sp)
        for _, g in ipairs(gains) do Cast(g, castTime, nil, sp) advance(0.3) end
        advance(2)
    end
    local function Blocks()
        local list = {}
        for _, e in ipairs(ns.db.craftLog) do if e.kind == "series" then list[#list + 1] = e end end
        return list
    end
    local function Reset(skill) ns.db.craftLog = {} rank = skill advance(3) end
    local function Text()
        local mark = #log
        slash("craftlog")
        return table.concat(log, "\n", mark + 1)
    end
    local ok, err = pcall(function()
        -- (1) Sven's case: 3 alone, then 7 by Create All, every one a point (13 -> 20, all orange)
        advance(3)
        for _ = 1, 3 do Cast(1) advance(2) end
        Series({ 1, 1, 1, 1, 1, 1, 1 })
        local blocks = Blocks()
        assert(#blocks == 1, "blocks: " .. #blocks)
        local b = blocks[1]
        assert(b.n == 7 and b.before == 13 and b.after == 20 and b.gain == 7 and b.colour == "orange" and b.recipe == "Light Leather" and b.prof == "Leatherworking", ("the block: n %s, %s -> %s, gain %s, %s"):format(tostring(b.n), tostring(b.before), tostring(b.after), tostring(b.gain), tostring(b.colour)))
        assert(b.yellow == 25 and b.grey == 45 and b.max == 75 and b.t and b.build == 70450 and b.result == "ok", "the block's thresholds, max, time or build")
        assert(#ns.db.craftLog == 3 + 7 + 1, "entries: " .. #ns.db.craftLog)
        local inSeries = 0
        for _, e in ipairs(ns.db.craftLog) do if e.inSeries then assert(e.overlap, "a series craft not marked overlapping") inSeries = inSeries + 1 end end
        assert(inSeries == 7, "crafts counted by the block: " .. inSeries)
        local byColour, byGap, others = ns.CraftLogSummary()
        assert(byColour.orange and byColour.orange.tries == 10 and byColour.orange.ups == 10, ("orange %s/%s, want 10/10"):format(tostring(byColour.orange and byColour.orange.ups), tostring(byColour.orange and byColour.orange.tries)))
        assert(others.overlap == 0 and others.series == 1 and others.seriesTries == 7 and others.seriesUps == 7, "the series counts")
        local text = Text()
        assert(text:find((ns.L["  %s: %d crafts, %d skill-ups (%d%%)"]):format("|cffff8040" .. ns.L["orange"] .. "|r", 10, 10, 100), 1, true), "orange line: " .. text)
        assert(text:find((ns.L["  from series (Create All): %d series, %d crafts, %d skill-ups - counted above"]):format(1, 7, 7), 1, true), "no series line: " .. text)
        assert(text:find((ns.L["  Not counted: %d failed or interrupted, %d unreadable, %d overlapping, %d at the rank's maximum; %d gave more than one point."]):format(0, 0, 0, 0, 0), 1, true), "not counted: " .. text)
        -- (2) realistic cast times (3 s): the series is one block too
        Reset(10)
        Series({ 1, 0, 1 }, 3)
        blocks = Blocks()
        assert(#blocks == 1 and blocks[1].n == 3 and blocks[1].gain == 2, "a series with 3 s casts: no block")
        -- a single craft after a pause counts alone
        Cast(1) advance(2)
        byColour = ns.CraftLogSummary()
        assert(byColour.orange.tries == 4 and byColour.orange.ups == 3, "the single after the series")
        -- (3) over a colour change (23 -> 27, yellow from 25): stays overlapping
        Reset(23)
        Series({ 1, 1, 1, 1 })
        assert(#Blocks() == 0, "a block over a colour change")
        byColour, byGap, others = ns.CraftLogSummary()
        assert(not byColour.orange and not byColour.yellow and others.overlap == 4, "a series over a colour change counted")
        assert(#ns.db.craftLog == 4, "entries: " .. #ns.db.craftLog)
        -- (4) over a distance group (33 -> 37: 12 and 8 below grey): stays overlapping
        Reset(33)
        Series({ 1, 1, 1, 1 })
        assert(#Blocks() == 0 and select(3, ns.CraftLogSummary()).overlap == 4, "a block over a distance group")
        -- yellow and the same group throughout (31 -> 33: 14 to 12 below grey): a block, in the 10-14 group
        Reset(31)
        Series({ 1, 0, 1 })
        assert(#Blocks() == 1 and Blocks()[1].colour == "yellow", "a yellow series in one group: no block")
        byColour, byGap = ns.CraftLogSummary()
        assert(byColour.yellow.tries == 3 and byColour.yellow.ups == 2 and byGap[2] and byGap[2].tries == 3 and byGap[2].ups == 2, "the yellow block in colour and distance")
        -- (5) a failed cast inside: no block, the rest overlapping
        Reset(10)
        Cast(1) advance(0.3)
        Cast(0, nil, { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_FAILED" }) advance(0.3)
        Cast(1) advance(2)
        assert(#Blocks() == 0, "a block with a failure inside")
        byColour, byGap, others = ns.CraftLogSummary()
        assert(others.failed == 1 and others.overlap == 2 and not byColour.orange, "a series with a failure counted")
        -- a failure as the last cast, nothing left to read: the first is marked all the same
        Reset(10)
        Cast(1) advance(1.6)
        assert(not ns.db.craftLog[1].overlap, "test setup: the first alone")
        -- (the first's reading is over; a cast started inside it fails now)
        Reset(10)
        Cast(1) advance(0.3)
        Cast(0, 2, { "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_FAILED" }) advance(2)
        assert(#Blocks() == 0 and ns.db.craftLog[1].overlap and select(3, ns.CraftLogSummary()).overlap == 1, "a failure after the reading left the first as a clear craft")
        -- (6) a hidden cast ID inside: no block
        Reset(10)
        issecretvalue = function(v) return rawequal(v, SECRET) end
        Cast(1) advance(0.3)
        rank = rank + 1
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, spell) advance(0.3)
        Cast(1) advance(2)
        issecretvalue = saved.secret
        assert(#Blocks() == 0 and not ns.CraftLogSummary().orange, "a block around a hidden cast ID")
        -- a hidden skill inside: no block
        Reset(10)
        Cast(1) advance(0.3)
        issecretvalue = function(v) return rawequal(v, SECRET) end
        local keep = rank
        rank = SECRET
        Cast(0) advance(0.3)
        rank = keep + 1
        issecretvalue = saved.secret
        Cast(1) advance(2)
        assert(#Blocks() == 0, "a block with a hidden skill inside")
        -- (7) at the rank's maximum (73 -> 75 of 75): no block
        Reset(73)
        Series({ 1, 1, 0 })
        assert(#Blocks() == 0 and select(3, ns.CraftLogSummary()).overlap == 3, "a block at the maximum")
        -- (8) more points than casts (k > n): no block
        Reset(10)
        Series({ 2, 2 })
        assert(#Blocks() == 0, "a block with more points than casts")
        -- (9) mixed recipes: no block, all overlapping
        Reset(10)
        Cast(1) advance(0.3)
        Cast(1, nil, nil, other) advance(0.3)
        Cast(1) advance(2)
        assert(#Blocks() == 0 and select(3, ns.CraftLogSummary()).overlap == 3, "a block of mixed recipes")
        -- two chained, then another recipe inside the last reading: the series is broken, no block of the two
        Reset(10)
        Cast(1) advance(0.3) Cast(1) advance(0.3)
        Cast(1, nil, nil, other) advance(2)
        assert(#Blocks() == 0 and select(3, ns.CraftLogSummary()).overlap == 3, "a block of two with another recipe chained after them")
        -- two chained, then a hidden cast ID inside the last reading (no point
        -- from it, so only the shared reading tells): the same
        Reset(10)
        Cast(1) advance(0.3) Cast(1) advance(0.3)
        issecretvalue = function(v) return rawequal(v, SECRET) end
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, spell) advance(2)
        issecretvalue = saved.secret
        assert(#Blocks() == 0 and not ns.CraftLogSummary().orange, "a block of two with a hidden cast ID after them")
        -- (10) clear in the middle of a series: no block; what comes after counts anew
        Reset(10)
        Cast(1) advance(0.3)
        Cast(1) advance(0.3)
        slash("craftlog clear")
        advance(2) -- (since 0.1.21, T8: the cleared crafts' points may still be on the way)
        Cast(1) advance(2)
        assert(#ns.db.craftLog == 1 and not ns.db.craftLog[1].kind and not ns.db.craftLog[1].overlap and ns.db.craftLog[1].gain == 1, "after a clear in a series: " .. #ns.db.craftLog .. " entries")
        Cast(1) advance(0.3) Cast(1) advance(2)
        assert(#Blocks() == 1 and Blocks()[1].n == 2, "a series after the clear: no block")
        -- (11) recording off: no block either; turned off in the middle of a series: no block
        Reset(10)
        ns.db.craftLogOff = true
        Series({ 1, 1 })
        assert(#ns.db.craftLog == 0, "recorded although turned off")
        ns.db.craftLogOff = nil
        Cast(1) advance(0.3) Cast(1) advance(0.3)
        ns.db.craftLogOff = true
        advance(2)
        assert(#Blocks() == 0, "a block written although recording was turned off during the series")
        ns.db.craftLogOff = nil
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell], data.colors[other] = saved.rank, saved.have, saved.colors, saved.colors2
    ns.db.craftLog, ns.db.craftLogOff, issecretvalue = saved.log, saved.off, saved.secret
    ns.db.craftMulti = keepMulti
    advance(3)
    if not ok then error(err, 0) end
end)
step("Craft log: switching the recording off or on is a hard break (v0.1.20 F1)", function()
    -- Codex 09.11., B1: a cast left open over the switch held the series
    -- for ever (later crafts each read the same end skill: orange 4/4), and
    -- another recipe's craft while off was counted into the first one's series
    local data = GathercraftRecipeData
    local spell, other = data.spells.Leatherworking["Light Leather"], data.spells.Leatherworking["Light Armor Kit"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], colors2 = data.colors[other],
        log = ns.db.craftLog, off = ns.db.craftLogOff, multi = ns.db.craftMulti }
    local rank = 10
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, 75 end end
    ns.CraftData.Have = function() return 0 end
    data.colors[spell], data.colors[other] = "25:45", "25:45"
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = {}, nil, nil
    local n = 0
    local function Guid() n = n + 1 return "Cast-f1-" .. n end
    local function Start(sp) local g = Guid() fire("UNIT_SPELLCAST_START", "player", g, sp or spell) return g end
    local function Done(g, gain, sp) rank = rank + (gain or 0) fire("UNIT_SPELLCAST_SUCCEEDED", "player", g, sp or spell) end
    local function Blocks()
        local list = {}
        for _, e in ipairs(ns.db.craftLog) do if e.kind == "series" then list[#list + 1] = e end end
        return list
    end
    local ok, err = pcall(function()
        advance(3)
        -- Probe A: A +1; 0.3 s later B starts (the series is open); A is read;
        -- recording off; B succeeds (ignored); on again; three quick crafts 0, 0, +1
        Done(Start(), 1) advance(0.3)
        local b = Start()
        advance(2)
        ns.db.craftLogOff = true
        Done(b, 0)
        ns.db.craftLogOff = nil
        -- (2 s: since 0.1.21 a craft that starts right after one the log did
        -- not read - B - has no reliable "before": its own step, T8)
        advance(2)
        for _, gain in ipairs({ 0, 0, 1 }) do Done(Start(), gain) advance(0.3) end
        advance(2)
        local byColour, _, others = ns.CraftLogSummary()
        local o = byColour.orange
        assert(not (o and o.tries == 4 and o.ups == 4), "Probe A: orange 4/4 - the three crafts after the switch each counted the one point")
        local blocks = Blocks()
        assert(#blocks == 1 and blocks[1].n == 3 and blocks[1].gain == 1, ("Probe A: the three crafts after the switch are not one block of 3 tries, 1 point (%d blocks)"):format(#blocks))
        assert(o and o.tries == 3 and o.ups == 1, ("Probe A: orange %s/%s, want 1/3"):format(tostring(o and o.ups), tostring(o and o.tries)))
        assert(ns.db.craftLog[1].overlap and not ns.db.craftLog[1].inSeries and others.overlap == 1, "Probe A: A, whose series the switch broke, is not left as overlapping")
        -- B (cast through the switch) is in no entry: 1 (A) + 3 + their block
        assert(#ns.db.craftLog == 5, "Probe A: entries " .. #ns.db.craftLog)
        -- Probe B: two quick crafts without a point; while they are read: off,
        -- another recipe +1, on again before the last reading
        ns.db.craftLog = {}
        advance(3)
        Done(Start(), 0) advance(0.3)
        Done(Start(), 0) advance(0.3)
        ns.db.craftLogOff = true
        Done(Start(other), 1, other)
        ns.db.craftLogOff = nil
        advance(3)
        assert(#Blocks() == 0, "Probe B: a series for the first recipe (n " .. tostring(Blocks()[1] and Blocks()[1].n) .. ", gain " .. tostring(Blocks()[1] and Blocks()[1].gain) .. ")")
        byColour = ns.CraftLogSummary()
        assert(not byColour.orange, "Probe B: the first recipe's crafts counted with the other one's point")
        for _, e in ipairs(ns.db.craftLog) do assert(e.spell ~= other, "Probe B: the craft made while off is in the log") end
        -- a cast started while off and finished after switching on: no craft
        ns.db.craftLog = {}
        advance(3)
        ns.db.craftLogOff = true
        local c = Start()
        ns.db.craftLogOff = nil
        Done(c, 1) advance(2)
        assert(#ns.db.craftLog == 0, "a cast started while off was logged after switching on")
        -- the option's switch itself, no event between off and on: the open cast and reading are gone
        local box
        for _, f in ipairs(allFrames) do
            if f.__kind == "FontString" and f:GetText() == ns.L["Record crafting skill-ups (helps improve the skill plan)"] and f.__pts and f.__pts.LEFT then
                box = f.__pts.LEFT[1]
            end
        end
        assert(box and box.get and box.__scripts.OnClick, "test setup: the option's switch")
        Done(Start(), 1) advance(0.3)
        local d = Start()
        box:SetChecked(false) box.__scripts.OnClick(box)
        assert(ns.db.craftLogOff, "test setup: the switch did not turn it off")
        box:SetChecked(true) box.__scripts.OnClick(box)
        assert(not ns.db.craftLogOff, "test setup: the switch did not turn it on")
        Done(d, 1) advance(3)
        assert(#ns.db.craftLog == 0, "off and on by the option: " .. #ns.db.craftLog .. " entries of crafts open over the switch")
        -- after all that a single craft counts as ever
        Done(Start(), 1) advance(2)
        assert(#ns.db.craftLog == 1 and not ns.db.craftLog[1].overlap and ns.db.craftLog[1].gain == 1, "a single craft after the switches")
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell], data.colors[other] = saved.rank, saved.have, saved.colors, saved.colors2
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = saved.log, saved.off, saved.multi
    advance(3)
    if not ok then error(err, 0) end
end)
step("Craft log: a series' points are its successes only while no craft ever gave more than one (v0.1.20 F2)", function()
    -- Codex 09.11., B2: +2 and +0 counted as a series 2/2, alone 1/2. Sven:
    -- in WoW: Forever a craft gives at most one point - so k points are k
    -- successes, as long as that is never seen to be wrong.
    local data = GathercraftRecipeData
    local spell = data.spells.Leatherworking["Light Leather"]
    local cookKey, cook = next(data.spells.Cooking)
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], colors2 = data.colors[cook],
        log = ns.db.craftLog, off = ns.db.craftLogOff, multi = ns.db.craftMulti }
    local rank, cooking = 10, 10
    ns.ProfessionRank = function(p)
        if p == "Leatherworking" then return rank, 75 end
        if p == "Cooking" then return cooking, 75 end
    end
    ns.CraftData.Have = function() return 0 end
    data.colors[spell], data.colors[cook] = "25:45", "25:45"
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = {}, nil, nil
    local n = 0
    local function Cast(gain, castTime, sp)
        n = n + 1
        local guid = "Cast-f2k-" .. n
        fire("UNIT_SPELLCAST_START", "player", guid, sp or spell)
        if castTime then advance(castTime) end
        if sp == cook then cooking = cooking + gain else rank = rank + gain end
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", guid, sp or spell)
    end
    local function Series(gains, castTime, sp)
        for _, g in ipairs(gains) do Cast(g, castTime, sp) advance(0.3) end
        advance(2)
    end
    local function Blocks()
        local list = {}
        for _, e in ipairs(ns.db.craftLog) do if e.kind == "series" then list[#list + 1] = e end end
        return list
    end
    local function Fresh(skill) ns.db.craftLog = {} rank = skill or 10 advance(3) end
    local function Text()
        local mark = #log
        slash("craftlog")
        return table.concat(log, "\n", mark + 1)
    end
    local HINT = (ns.L["  Series of %s are not counted: a craft there gave more than one point."]):format(ns.L["Leatherworking"])
    local ok, err = pcall(function()
        assert(cook and cookKey, "test setup: no Cooking recipe")
        advance(3)
        -- +1 / +1: 2 of 2 (the first one's reading holds both points - no proof of a double)
        Series({ 1, 1 })
        local byColour = ns.CraftLogSummary()
        assert(#Blocks() == 1 and byColour.orange and byColour.orange.tries == 2 and byColour.orange.ups == 2, "+1/+1 is not 2/2")
        assert(not ns.db.craftMulti, "+1/+1 read together was taken for a multi-point craft")
        -- +1 / +0 / +1, never a multi-point craft seen: 2 of 3
        Fresh()
        Series({ 1, 0, 1 }, 3)
        byColour = ns.CraftLogSummary()
        assert(#Blocks() == 1 and Blocks()[1].n == 3 and Blocks()[1].gain == 2, "+1/+0/+1: no block of 3 tries, 2 points")
        assert(byColour.orange.tries == 3 and byColour.orange.ups == 2, ("+1/+0/+1: orange %d/%d, want 2/3"):format(byColour.orange.ups, byColour.orange.tries))
        assert(not Text():find(HINT, 1, true), "the hint without a multi-point craft")
        -- Codex' probe: +2 then +0; the second starts inside the first one's
        -- reading and takes 3 s, so the first is read alone: its +2 is its own
        Fresh()
        Cast(2) advance(0.3)
        Cast(0, 3) advance(2)
        assert(#Blocks() == 0, "+2/+0 counted as a series " .. tostring(Blocks()[1] and Blocks()[1].gain) .. "/" .. tostring(Blocks()[1] and Blocks()[1].n))
        local _, _, others
        byColour, _, others = ns.CraftLogSummary()
        assert(not byColour.orange and others.overlap == 2, "+2/+0: not left as overlapping")
        assert(ns.db.craftMulti and ns.db.craftMulti.Leatherworking, "the multi-point craft is not noted for the profession")
        assert(Text():find(HINT, 1, true), "/gcr craftlog does not say that series are no longer counted")
        -- from then on: series of the profession stay overlapping
        Fresh()
        Series({ 1, 1 })
        byColour, _, others = ns.CraftLogSummary()
        assert(#Blocks() == 0 and not byColour.orange and others.overlap == 2, "a series after the multi-point craft was counted")
        -- another profession is not touched by it
        Series({ 1, 1 }, nil, cook)
        local blocks = Blocks()
        assert(#blocks == 1 and blocks[1].prof == "Cooking" and blocks[1].gain == 2, "a Cooking series stopped by Leatherworking's note")
        -- clear forgets the note with everything else
        slash("craftlog clear")
        assert(ns.db.craftMulti == nil, "clear kept the note")
        advance(3)
        Series({ 1, 1 })
        assert(#Blocks() == 1, "after the clear a clean series is not counted")
        -- a single multi-point craft: later blocks overlapping
        Fresh()
        Cast(2) advance(2)
        assert(ns.db.craftLog[1].multi and ns.db.craftMulti and ns.db.craftMulti.Leatherworking, "a single +2 is not noted")
        Series({ 1, 0, 1 })
        byColour, _, others = ns.CraftLogSummary()
        assert(#Blocks() == 0 and others.overlap == 3, "a block after a single multi-point craft")
        assert(byColour.orange and byColour.orange.tries == 1 and byColour.orange.ups == 1 and others.multi == 1, "the single +2 itself: one try, one success, named apart")
        -- a log of 0.1.18 / 0.1.19 with such a craft, no note yet: found in the log
        Fresh()
        ns.db.craftMulti = nil
        ns.db.craftLog = { { t = 1, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 5, after = 7, gain = 2, multi = true, yellow = 25, grey = 45, max = 75 } }
        Series({ 1, 1 })
        assert(#Blocks() == 0 and ns.db.craftMulti and ns.db.craftMulti.Leatherworking, "an old multi-point entry in the log does not stop the series")
        -- an overlapping old entry with two points proves nothing
        Fresh()
        ns.db.craftMulti = nil
        ns.db.craftLog = { { t = 1, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 5, after = 7, gain = 2, multi = true, overlap = true, yellow = 25, grey = 45, max = 75 } }
        Series({ 1, 1 })
        assert(#Blocks() == 1 and not ns.db.craftMulti, "an overlapping two-point reading was taken for proof")
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell], data.colors[cook] = saved.rank, saved.have, saved.colors, saved.colors2
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = saved.log, saved.off, saved.multi
    advance(3)
    if not ok then error(err, 0) end
end)
step("Craft log: the header counts crafts, a block and its casts once (v0.1.20 F3)", function()
    -- Codex 09.11., B3: 3 single crafts and 7 by Create All said "11 crafts"
    local data = GathercraftRecipeData
    local spell = data.spells.Leatherworking["Light Leather"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], log = ns.db.craftLog, off = ns.db.craftLogOff, multi = ns.db.craftMulti }
    local rank = 10
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, 75 end end
    ns.CraftData.Have = function() return 0 end
    data.colors[spell] = "25:45"
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = {}, nil, nil
    local n = 0
    local function Cast(gain)
        n = n + 1
        fire("UNIT_SPELLCAST_START", "player", "Cast-f3-" .. n, spell)
        rank = rank + gain
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-f3-" .. n, spell)
    end
    local function Header()
        local mark = #log
        slash("craftlog")
        return table.concat(log, "\n", mark + 1)
    end
    local function Says(count) return (ns.L["Craft log: %d crafts (kept on this computer, never shared)."]):format(count) end
    local ok, err = pcall(function()
        advance(3)
        for _ = 1, 3 do Cast(1) advance(2) end
        for _ = 1, 7 do Cast(1) advance(0.3) end
        advance(2)
        assert(#ns.db.craftLog == 11, "test setup: 3 singles, 7 series casts and their block: " .. #ns.db.craftLog)
        local text = Header()
        assert(text:find(Says(10), 1, true), "the header does not say 10 crafts: " .. text:sub(1, 120))
        assert(not text:find(Says(11), 1, true), "the header counts the block as a craft")
        -- a failed cast is no craft (since 0.1.21, T7: finished crafts only)
        fire("UNIT_SPELLCAST_START", "player", "Cast-f3-x", spell)
        fire("UNIT_SPELLCAST_FAILED", "player", "Cast-f3-x", spell)
        assert(Header():find(Says(10), 1, true), "a failed cast is counted as a craft")
        -- a full log that has lost the oldest casts of a block: the block still stands for all of them
        ns.db.craftLog = {
            { t = 3, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 12, after = 13, gain = 1, overlap = true, inSeries = true },
            { kind = "series", t = 1, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", n = 7, before = 6, after = 13, gain = 7, yellow = 25, grey = 45, max = 75 },
            { t = 9, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 13, after = 14, gain = 1, yellow = 25, grey = 45, max = 75 },
        }
        assert(Header():find(Says(8), 1, true), "a block whose oldest casts left the log: not 7 + 1 crafts")
        local byColour = ns.CraftLogSummary()
        assert(byColour.orange.tries == 8, "header and colour line disagree")
        -- an empty log says 0
        ns.db.craftLog = {}
        assert(Header():find(Says(0), 1, true), "an empty log")
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell] = saved.rank, saved.have, saved.colors
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = saved.log, saved.off, saved.multi
    advance(3)
    if not ok then error(err, 0) end
end)
step("Craft log: an orange block needs no distance group and never goes into a distance line (v0.1.20 F4)", function()
    -- Codex 09.11., B4: thresholds 55:60, skill 50 -> 53: orange throughout,
    -- 10 to 7 below grey (two groups). Accepted on purpose - orange always
    -- gives its point and is not in the distance statistic.
    local data = GathercraftRecipeData
    local spell = data.spells.Leatherworking["Light Leather"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], log = ns.db.craftLog, off = ns.db.craftLogOff, multi = ns.db.craftMulti }
    local rank = 50
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, 75 end end
    ns.CraftData.Have = function() return 0 end
    data.colors[spell] = "55:60"
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = {}, nil, nil
    local n = 0
    local function Series(gains)
        for _, gain in ipairs(gains) do
            n = n + 1
            fire("UNIT_SPELLCAST_START", "player", "Cast-f4-" .. n, spell)
            rank = rank + gain
            fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-f4-" .. n, spell)
            advance(0.3)
        end
        advance(2)
    end
    local ok, err = pcall(function()
        advance(3)
        Series({ 1, 1, 1 })
        local byColour, byGap, others = ns.CraftLogSummary()
        assert(others.series == 1 and byColour.orange and byColour.orange.tries == 3 and byColour.orange.ups == 3, "the orange block over two distance groups is not counted")
        assert(next(byGap) == nil, "an orange block went into a distance line")
        local mark = #log
        slash("craftlog")
        local text = table.concat(log, "\n", mark + 1)
        for _, group in ipairs({ "0-4", "5-9", "10-14", "15-19", "20+" }) do
            assert(not text:find((ns.L["  %s points below grey: %d crafts, %d skill-ups (%d%%)"]):format(group, 3, 3, 100), 1, true), "a distance line from the orange block: " .. group)
        end
        -- yellow/green keeps the rule: 55 -> 57 is 5 to 3 below grey, two groups: no block
        ns.db.craftLog = {}
        rank = 55
        advance(3)
        Series({ 1, 1 })
        byColour, byGap, others = ns.CraftLogSummary()
        assert(others.series == 0 and others.overlap == 2 and next(byGap) == nil, "a yellow block over two distance groups")
        -- and inside one group (56 -> 57: 4 and 3 below grey) it counts, in its line
        ns.db.craftLog = {}
        rank = 56
        advance(3)
        Series({ 1, 0 })
        byColour, byGap, others = ns.CraftLogSummary()
        assert(others.series == 1 and byGap[0] and byGap[0].tries == 2 and byGap[0].ups == 1, "a yellow block inside one distance group")
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell] = saved.rank, saved.have, saved.colors
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = saved.log, saved.off, saved.multi
    advance(3)
    if not ok then error(err, 0) end
end)
step("Craft log: no green threshold is made up; yellow/green is one honest line (v0.1.20 K3)", function()
    -- skill plan 2.0 concept 4.1: the shipped colours are yellow and grey
    -- only. The distance to grey stays the real statistic.
    local data = GathercraftRecipeData
    local spell = data.spells.Leatherworking["Light Leather"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], log = ns.db.craftLog, off = ns.db.craftLogOff }
    local rank = 35
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, 75 end end
    ns.CraftData.Have = function() return 0 end
    data.colors[spell] = "20:40"
    ns.db.craftLog, ns.db.craftLogOff = {}, nil
    local keepMulti = ns.db.craftMulti ns.db.craftMulti = nil -- (F2: the note of a multi-point craft)
    local ok, err = pcall(function()
        advance(3)
        -- 35 of 20:40 was "green" before: now yellow, the thresholds kept as they are
        fire("UNIT_SPELLCAST_START", "player", "Cast-k3-A", spell)
        rank = 36
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-k3-A", spell)
        advance(2)
        local e = ns.db.craftLog[1]
        assert(e and e.colour == "yellow" and e.yellow == 20 and e.grey == 40 and e.before == 35, ("colour %s, %s:%s"):format(tostring(e and e.colour), tostring(e and e.yellow), tostring(e and e.grey)))
        -- 20 (the threshold itself) is yellow, 39 is yellow, 40 is grey
        rank = 20
        fire("UNIT_SPELLCAST_START", "player", "Cast-k3-B", spell) fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-k3-B", spell) advance(2)
        rank = 39
        fire("UNIT_SPELLCAST_START", "player", "Cast-k3-C", spell) fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-k3-C", spell) advance(2)
        rank = 40
        fire("UNIT_SPELLCAST_START", "player", "Cast-k3-D", spell) fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-k3-D", spell) advance(2)
        assert(ns.db.craftLog[2].colour == "yellow" and ns.db.craftLog[3].colour == "yellow" and ns.db.craftLog[4].colour == "grey", "the thresholds")
        -- an entry of 0.1.18 still saying "green": counted with yellow, never on a line of its own
        table.insert(ns.db.craftLog, { t = 1, result = "ok", colour = "green", before = 34, after = 35, gain = 1, yellow = 20, grey = 40, max = 75 })
        local byColour = ns.CraftLogSummary()
        assert(byColour.yellow and byColour.yellow.tries == 4 and byColour.yellow.ups == 2, ("yellow: %s/%s"):format(tostring(byColour.yellow and byColour.yellow.ups), tostring(byColour.yellow and byColour.yellow.tries)))
        assert(not byColour.green, "a green line of its own")
        local mark = #log
        slash("craftlog")
        local text = table.concat(log, "\n", mark + 1)
        assert(text:find((ns.L["  %s: %d crafts, %d skill-ups (%d%%)"]):format("|cffffff00" .. ns.L["yellow/green"] .. "|r", 4, 2, 50), 1, true), "no yellow/green line: " .. text)
        assert(not text:find("|cff40c040", 1, true), "a green line in /gcr craftlog: " .. text)
        -- the distance to grey is still counted (5 below grey: 35 and 34 -> 5-9; 39 -> 0-4)
        assert(text:find((ns.L["  %s points below grey: %d crafts, %d skill-ups (%d%%)"]):format("5-9", 2, 2, 100), 1, true), "distance line: " .. text)
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell] = saved.rank, saved.have, saved.colors
    ns.db.craftLog, ns.db.craftLogOff = saved.log, saved.off
    ns.db.craftMulti = keepMulti
    if not ok then error(err, 0) end
end)
step("Sharing counts what other players sent, over all sessions (v0.1.18 S7)", function()
    local db = ns.db.sync
    local saved = { counts = db.counts, enabled = db.enabled, public = db.public, friend = C_FriendList.GetFriendInfo }
    db.enabled, db.public, db.counts = true, true, nil
    local Z = 1463
    ns.db.nodes[Z] = {}
    local function Send(id, x, who, where)
        local text = ("N:%d;%s,h,%d,5000,2447"):format(Z, id, x)
        if where == "GUILD" then
            fire("CHAT_MSG_ADDON", "Gathercraft", text, "GUILD", who)
        else
            fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", who, nil, nil, nil, "GathercraftSync")
        end
        advance(1)
    end
    local function Counts(what, received, new, confirmed, trusted, public)
        local r, n, c, t, p = ns.SyncCounts()
        assert(r == received and n == new and c == confirmed and t == trusted and p == public,
            ("%s: received %d, new %d, confirmed %d, guild/friends %d, public %d"):format(what, r, n, c, t, p))
    end
    local ok, err = pcall(function()
        -- a guild member: a new spot at once
        Send("o3001", 1000, "Guild Mate", "GUILD")
        Counts("guild", 1, 1, 0, 1, 0)
        -- the same message again: nothing more
        Send("o3001", 1000, "Guild Mate", "GUILD")
        Counts("the same message twice", 1, 1, 0, 1, 0)
        -- public: one report, two reports, waiting; the third takes it
        Send("o3002", 3000, "Stranger One")
        Counts("public, 1 report", 1, 1, 0, 1, 0)
        Send("o3002", 3000, "Stranger One") -- one player twice is still one report
        Send("o3002", 3000, "Stranger Two")
        Counts("public, 2 reports", 1, 1, 0, 1, 0)
        Send("o3002", 3000, "Stranger Three")
        Counts("public, 3 reports", 2, 2, 0, 1, 1)
        -- someone new reports a spot you know: a confirmation, once per player
        Send("o3001", 1000, "Stranger Four")
        Counts("a known spot", 3, 2, 1, 1, 1)
        Send("o3001", 1000, "Stranger Four")
        Send("o3002", 3000, "Stranger Two") -- already one of its reporters
        Counts("the same players again", 3, 2, 1, 1, 1)
        -- a friend in the public channel counts like the guild
        C_FriendList.GetFriendInfo = function(name) if name == "Good Friend" then return { name = name } end end
        Send("o3003", 5000, "Good Friend")
        Counts("a friend", 4, 3, 1, 2, 1)
        C_FriendList.GetFriendInfo = saved.friend
        -- one report waiting: shown as waiting, not counted
        Send("o3004", 7000, "Stranger Five")
        Counts("waiting", 4, 3, 1, 2, 1)
        -- kept over sessions: in the saved variables
        assert(ns.db.sync.counts and ns.db.sync.counts.received == 4, "not in the saved variables")
        -- /gcr sync and Options > Sharing
        local mark = #log
        slash("sync")
        local said
        local want = (ns.L["  Received from other players (all sessions): %d spots, %d new (%d guild/friends, %d public, confirmed), %d confirm spots you know"]):format(4, 3, 2, 1, 1)
        for i = mark + 1, #log do if log[i]:find(want, 1, true) then said = true end end
        assert(said, "/gcr sync: " .. want)
        -- the Sharing section, also when an earlier step left the options open elsewhere
        local win = _G.GathercraftOptions
        local wasOpen, wasSection = win:IsShown(), ns.db.optionsSection
        if not wasOpen then ns.ToggleOptions() end
        ns.ShowOptionsSection("sync")
        win:Refresh()
        advance(1)
        local line = (ns.L["Received from other players: %d spots (%d new)"]):format(4, 3)
        local shown
        for _, o in ipairs(allFrames) do
            local t = o.GetText and o:GetText()
            if type(t) == "string" and t:find(line, 1, true) and o:IsShown() then shown = true end
        end
        assert(shown, "Options > Sharing: " .. line)
        -- no names in the options
        for _, o in ipairs(allFrames) do
            local t = o.GetText and o:IsShown() and o:GetText()
            if type(t) == "string" and t:find(line, 1, true) then assert(not t:find("Stranger", 1, true), "a name in the options") end
        end
        ns.ShowOptionsSection(wasSection or "map")
        if not wasOpen then ns.ToggleOptions() end
    end)
    C_FriendList.GetFriendInfo = saved.friend
    db.counts, db.enabled, db.public = saved.counts, saved.enabled, saved.public
    ns.db.nodes[Z] = nil
    if db.pending then db.pending[Z] = nil end
    ns.NotifyNodesChanged()
    if not ok then error(err, 0) end
end)
step("README says what the addon does, no more (v0.1.18 S8)", function()
    local f = assert(io.open(ROOT .. "/README.md"))
    local text = f:read("*a") f:close()
    -- the plan follows your prices: never "the cheapest"
    assert(not text:lower():find("cheapest", 1, true), "README calls the plan the cheapest")
    -- prices: your own scan first, the others only when fresher (Prices.lua, v0.1.16)
    assert(not text:find("only used if you have no scan yet", 1, true) and not text:find("are used until your first own scan", 1, true),
        "README: Auctionator or TSM only until the first scan")
    -- the price order: its own step since F3 (Codex M3)
    assert(text:find("An optional louder splash helps in busy spots.", 1, true), "README: the louder splash")
    local nextUp = text:match("Next up.-\n\n(.-)\n\n")
    assert(nextUp and nextUp:find("Skill plan rebuilt", 1, true) and nextUp:find("Smoother Loop routes", 1, true)
        and nextUp:find("Disenchant values", 1, true) and nextUp:find("new Forever zones", 1, true), "README: Next up")
end)
step("README: the price text says what Prices.lua does (v0.1.18 F3)", function()
    -- Codex M3 (08.11.): "Auctionator or TSM only fill in when they have a
    -- fresher price" - TSM never wins on freshness. The rule, from the code:
    local f = assert(io.open(ROOT .. "/Prices.lua"))
    local code = f:read("*a") f:close()
    local fresh = tonumber(code:match("local FRESH_PRICE = (%d+) %* 3600"))
    local maxAge = tonumber(code:match("local MAX_PRICE_AGE = (%d+) %* 86400"))
    assert(fresh and maxAge, "test setup: the price ages in Prices.lua")
    -- only Auctionator is compared by age; TSM is a fallback only
    assert(code:find('local other = age >= FRESH_PRICE and AuctionatorPrice(itemID)', 1, true), "test setup: the Auctionator age check")
    f = assert(io.open(ROOT .. "/README.md"))
    local text = f:read("*a") f:close()
    local first, fallback = 0, 0
    -- every sentence about the price sources
    for sentence in (text:gsub("\n", " ")):gmatch("[^%.%?!]+") do
        local s = sentence:lower()
        if s:find("tsm", 1, true) then
            assert(not s:find("fresh", 1, true) and not s:find("newer", 1, true) and not s:find("recent", 1, true),
                "README: TSM described as fresher: " .. sentence)
            if s:find(("%d days"):format(maxAge), 1, true) then fallback = fallback + 1 end
        end
        if s:find("scan comes first", 1, true) then
            first = first + 1
            assert(s:find(("%d hours"):format(fresh), 1, true) and s:find("fresher auctionator", 1, true),
                ("README: not that a fresher Auctionator price may take over after %d hours: %s"):format(fresh, sentence))
        end
    end
    -- in both places (features and FAQ)
    assert(first == 2, "README: your own scan first, then a fresher Auctionator: " .. first .. " times")
    assert(fallback == 2, ("README: Auctionator or TSM fill in without an own scan of the last %d days: %d times"):format(maxAge, fallback))
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
step("Sharing status: waiting spots need the number of players the code asks for (v0.1.18 F4)", function()
    -- Sven's find (08.11.): "Waiting for a second player" - a public spot
    -- needs CONFIRMATIONS (3) different players; guild and friends count at once
    local f = assert(io.open(ROOT .. "/Sync.lua"))
    local code = f:read("*a") f:close()
    local need = tonumber(code:match("local CONFIRMATIONS = (%d+)"))
    assert(need and need >= 2, "test setup: CONFIRMATIONS in Sync.lua")
    local db = ns.db.sync
    local was = { enabled = db.enabled, public = db.public }
    db.enabled, db.public = true, true
    local win = _G.GathercraftOptions
    local wasOpen = win:IsShown()
    local ok, err = pcall(function()
        if not wasOpen then ns.ToggleOptions() end
        ns.ShowOptionsSection("sync")
        win:Refresh()
        advance(3)
        local waiting = select(3, ns.SyncSummary())
        local want = (ns.L["Waiting for confirmation by %d different players: %d"]):format(need, waiting)
        assert(want ~= ("Waiting for confirmation by %d different players: %d"):format(need, waiting) or LOCALE == "enUS" or LOCALE == "enGB",
            "no translation of the waiting line in " .. LOCALE)
        local status
        for _, o in ipairs(allFrames) do
            local t = o.GetText and o:IsShown() and o:GetText()
            if type(t) == "string" and t:find(want, 1, true) then status = t end
        end
        assert(status, "Options > Sharing: " .. want)
        assert(not status:lower():find("second", 1, true), "still a second player: " .. status)
        -- one line in the status area (6 px a letter, 11 px a CJK sign; about 500 px wide)
        local px = 0
        for ch in want:gmatch("[%z\1-\127\194-\244][\128-\191]*") do px = px + (#ch >= 3 and 11 or 6) end
        assert(px <= 480, ("the waiting line needs %d px: %s"):format(px, want))
    end)
    db.enabled, db.public = was.enabled, was.public
    if not wasOpen then ns.ToggleOptions() end
    if not ok then error(err, 0) end
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
    -- the table Prices.lua has kept since its load (loaded once, Codex N4)
    C_AuctionHouse.ReplicateItems = function() end
    C_AuctionHouse.GetNumReplicateItems = function() return #auctions end
    C_AuctionHouse.GetReplicateItemInfo = function(i)
        local a = auctions[i + 1]
        if not a then return nil end
        return "Item", 1, a.count, 1, true, 1, 0, 0, 0, a.buyout, 0, false, nil, "Seller", nil, 0, a.id, true
    end
    AuctionHouseFrame = CreateFrame("Frame", "AuctionHouseFrame", UIParent)
    -- one copy of the price module, as in the game: one frame for the scan
    -- event, one price line in the tooltip
    local copies = 0
    for _ in pairs(eventFrames["REPLICATE_ITEM_LIST_UPDATE"] or {}) do copies = copies + 1 end
    assert(copies == 1, copies .. " frames of the price module wait for the scan")
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
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
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
step("Auction house: a search replaces an old price, a failed scan changes nothing (v0.1.16)", function()
    local p = ns.db.prices[next(ns.db.prices)]
    local AHX = C_AuctionHouse
    local keepTime, keepDebug = time, ns.db.debug
    local keepNum, keepInfo, keepBrowse = AHX.GetNumReplicateItems, AHX.GetReplicateItemInfo, AHX.GetBrowseResults
    local clock = keepTime()
    time = function() return clock end
    local TIN = 2771
    ns.db.debug = true
    local function Told(text)
        for _, l in ipairs(log) do if l:find(text, 1, true) then return true end end
    end
    local function Old(price, qty, hours)
        p.items[TIN], p.qty[TIN], p.seen[TIN] = price, qty, clock - hours * 3600
    end
    local function Browse(min, qty)
        AHX.GetBrowseResults = function() return { { itemKey = { itemID = TIN }, minPrice = min, totalQuantity = qty } } end
    end
    local function Reopen()
        fire("AUCTION_HOUSE_CLOSED")
        fire("AUCTION_HOUSE_SHOW") advance(1)
        p.lastScanStart = nil
    end

    -- Befund 2: a browse search takes over a price of 21 hours ago
    Old(295, 1143, 21)
    Browse(187, 1707)
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    assert(p.items[TIN] == 187 and p.qty[TIN] == 1707, "browse left the old price: " .. tostring(p.items[TIN]))
    assert(p.seen[TIN] == clock, "browse: not fresh")
    -- the second event of a list, and a fresh price stays
    Old(295, 1143, 21)
    fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    assert(p.items[TIN] == 187, "browse, added: " .. tostring(p.items[TIN]))
    Old(300, 10, 0.5)
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    assert(p.items[TIN] == 300, "browse beat a fresh search price")
    assert(Told("1 results, 0 stored, 1 left out"), "debug: left out")
    -- a list that stores nothing is no search learned, gear counts with its lowest price
    AHX.GetBrowseResults = function()
        return { { itemKey = { itemID = 9001 }, minPrice = 900, totalQuantity = 1 }, { itemKey = { itemID = 9001 }, minPrice = 300, totalQuantity = 2 },
            { itemKey = { itemID = 9001 }, minPrice = 500, totalQuantity = 1 } }
    end
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    assert(p.items[9001] == 300 and p.qty[9001] == 4, "gear: " .. tostring(p.items[9001]))
    p.items[9001], p.qty[9001], p.seen[9001] = nil, nil, nil
    local function Searches()
        slash("prices")
        for i = #log, 1, -1 do
            local n = log[i]:match("(%d+) searches learned")
            if n then return tonumber(n) end
        end
    end
    local searches = Searches()
    Old(300, 10, 0.5)
    Browse(187, 1707)
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    assert(Searches() == searches, "nothing stored, yet a search learned")
    fire("AUCTION_HOUSE_BROWSE_FAILURE")
    assert(Told("AUCTION_HOUSE_BROWSE_FAILURE"), "debug: browse failure")

    -- a search while a scan runs still counts: the scan may fail
    Reopen()
    Old(295, 1143, 21)
    local before = p.scanned
    slash("scan") advance(1)
    Browse(187, 1707)
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    assert(p.items[TIN] == 187, "search during a scan was dropped")

    -- no answer: nothing stored, the lock stays, the search works again
    Old(295, 1143, 21)
    local items = p.items
    advance(91)
    assert(p.items == items and p.scanned == before and p.items[TIN] == 295, "timeout: prices changed")
    assert(Told("SCAN timeout"), "debug: timeout")
    assert(p.lastScanStart, "timeout: no lock")
    local left = (ns.L["Your prices stay as they are. Next scan in %d:%02d."]):sub(1, 8)
    assert(Told(left), "timeout: no word about the prices")
    -- the answer comes late: it is read after all
    fire("REPLICATE_ITEM_LIST_UPDATE") advance(2)
    assert(p.scanned ~= before and p.items ~= items, "late answer left out")
    assert(Told("after the timeout"), "debug: late answer")
    -- without a scan of ours the list is left alone
    items, before = p.items, p.scanned
    fire("REPLICATE_ITEM_LIST_UPDATE") advance(2)
    assert(p.items == items and p.scanned == before, "somebody else's list was read")
    assert(Told("no scan of ours"), "debug: not ours")

    -- closed while waiting, and the answer after that: nothing
    Reopen()
    slash("scan") advance(1)
    fire("AUCTION_HOUSE_CLOSED")
    fire("REPLICATE_ITEM_LIST_UPDATE") advance(2)
    assert(p.items == items and p.scanned == before, "closed: scan went on")
    assert(Told("cancelled, auction house closed (waiting)"), "debug: closed")
    -- closed in the middle of reading: the part read is not the auction house
    fire("AUCTION_HOUSE_SHOW") advance(1)
    p.lastScanStart = nil
    AHX.GetNumReplicateItems = function() return 4000 end
    slash("scan") advance(1)
    fire("REPLICATE_ITEM_LIST_UPDATE")
    fire("AUCTION_HOUSE_CLOSED")
    advance(5)
    assert(p.items == items and p.scanned == before, "closed while reading: partial scan stored")
    assert(Told("cancelled, auction house closed (reading)"), "debug: closed while reading")

    -- 0 auctions, or nothing usable in them: nothing stored
    AHX.GetNumReplicateItems = function() return 0 end
    Reopen()
    slash("scan") advance(1)
    fire("REPLICATE_ITEM_LIST_UPDATE") advance(2)
    assert(p.items == items and p.scanned == before, "0 auctions: prices changed")
    AHX.GetNumReplicateItems = function() return 3 end
    AHX.GetReplicateItemInfo = function(i)
        if i == 0 then return "Item", 1, 1, 1, true, 1, 0, 0, 0, 0, 0, false, nil, "Seller", nil, 0, TIN, true end
        if i == 1 then return "Item", 1, 0, 1, true, 1, 0, 0, 0, 500, 0, false, nil, "Seller", nil, 0, TIN, true end
        return "Item", 1, 2, 1, true, 1, 0, 0, 0, 500, 0, false, nil, "Seller", nil, 0, nil, true
    end
    Reopen()
    slash("scan") advance(1)
    fire("REPLICATE_ITEM_LIST_UPDATE") advance(2)
    assert(p.items == items and p.scanned == before, "nothing usable: prices wiped")
    assert(Told("skipped 1 without itemID, 1 with count 0, 1 with buyout 0"), "debug: skipped")

    slash("prices")
    assert(Told("doesn't know: none"), "prices: events")
    fire("AUCTION_HOUSE_CLOSED")
    AHX.GetNumReplicateItems, AHX.GetReplicateItemInfo, AHX.GetBrowseResults = keepNum, keepInfo, keepBrowse
    time, ns.db.debug = keepTime, keepDebug
end)
step("Auction house: a scan with unreadable auctions keeps the old prices (R4-B2)", function()
    local p = ns.db.prices[next(ns.db.prices)]
    local keep = { items = p.items, qty = p.qty, seen = p.seen, scanned = p.scanned }
    local AHX = C_AuctionHouse
    local keepNum, keepInfo, keepReplicate = AHX.GetNumReplicateItems, AHX.GetReplicateItemInfo, AHX.ReplicateItems
    local TIN, PEACE = 2771, 2447
    local function Prices() p.items, p.qty, p.seen, p.scanned = { [TIN] = 295 }, { [TIN] = 10 }, { [TIN] = time() - 3600 }, time() - 7200 end
    local function Scan(info, n)
        AHX.GetNumReplicateItems = function() return n end
        AHX.GetReplicateItemInfo = info
        fire("AUCTION_HOUSE_CLOSED")
        fire("AUCTION_HOUSE_SHOW") advance(1)
        ns.db.prices[next(ns.db.prices)].lastScanStart = nil
        slash("scan") advance(1)
        fire("REPLICATE_ITEM_LIST_UPDATE") advance(3)
        fire("AUCTION_HOUSE_CLOSED") advance(1)
    end
    local function Good() return "Peacebloom", 1, 1, 1, true, 1, 0, 0, 0, 20, 0, false, nil, "Seller", nil, 0, PEACE, true end
    -- Codex's probe: Tin 295c known; one good Peacebloom auction, one that throws
    Prices()
    local scanned = p.scanned
    local mark = #log
    Scan(function(i) if i == 0 then return Good() end error("read failed") end, 2)
    p = ns.db.prices[next(ns.db.prices)]
    assert(p.items[TIN] == 295, "Tin lost: " .. tostring(p.items[TIN]))
    assert(p.items[PEACE] == 20, "Peacebloom not updated: " .. tostring(p.items[PEACE]))
    assert(p.scanned == scanned, "an incomplete scan counts as a full one")
    local told
    for i = mark + 1, #log do if log[i]:find("incomplete", 1, true) or log[i]:find(ns.L["Scan incomplete: %d auctions could not be read, old prices kept (%d updated)."]:sub(1, 12), 1, true) then told = true end end
    assert(told, "no word that the scan was incomplete")
    -- an auction that gives back nothing at all counts the same
    Prices()
    Scan(function(i) if i == 0 then return Good() end end, 2)
    p = ns.db.prices[next(ns.db.prices)]
    assert(p.items[TIN] == 295 and p.items[PEACE] == 20, "no answer for one auction: Tin " .. tostring(p.items[TIN]))
    -- a full scan without errors still replaces everything
    Prices()
    Scan(function() return Good() end, 2)
    p = ns.db.prices[next(ns.db.prices)]
    assert(p.items[TIN] == nil and p.items[PEACE] == 20 and p.scanned > scanned, "a complete scan did not replace the prices")
    AHX.GetNumReplicateItems, AHX.GetReplicateItemInfo, AHX.ReplicateItems = keepNum, keepInfo, keepReplicate
    p.items, p.qty, p.seen, p.scanned = keep.items, keep.qty, keep.seen, keep.scanned
    p.lastScanStart = nil
end)
step("Auction house: \"left out\" once per scan, the rest as one count (v0.1.17)", function()
    local p = ns.db.prices[next(ns.db.prices)]
    local keep = { items = p.items, qty = p.qty, seen = p.seen, scanned = p.scanned }
    local AHX = C_AuctionHouse
    local keepNum, keepInfo = AHX.GetNumReplicateItems, AHX.GetReplicateItemInfo
    local wasDebug = ns.db.debug
    ns.db.debug = true
    local function Count(text, from)
        local n = 0
        for i = from + 1, #log do if log[i]:find(text, 1, true) then n = n + 1 end end
        return n
    end
    local LEFT = "REPLICATE_ITEM_LIST_UPDATE left out"
    -- Prices.lua is loaded once (Codex N4): one line each
    local copies = 1
    -- another addon's scan: 120 updates, none of them ours
    fire("AUCTION_HOUSE_CLOSED")
    fire("AUCTION_HOUSE_SHOW") advance(1)
    local mark = #log
    for _ = 1, 120 do fire("REPLICATE_ITEM_LIST_UPDATE") end
    advance(1)
    assert(Count(LEFT, mark) == copies, ("%d left-out lines, want %d"):format(Count(LEFT, mark), copies))
    fire("AUCTION_HOUSE_CLOSED")
    assert(Count("119 further updates ignored (no scan of ours", mark) == copies, "no count of the other 119")
    -- our scan, and 50 more updates while it reads
    AHX.GetNumReplicateItems = function() return 4000 end
    AHX.GetReplicateItemInfo = function() return "Peacebloom", 1, 1, 1, true, 1, 0, 0, 0, 20, 0, false, nil, "Seller", nil, 0, 2447, true end
    fire("AUCTION_HOUSE_SHOW") advance(1)
    p.lastScanStart = nil
    mark = #log
    slash("scan") advance(1)
    fire("REPLICATE_ITEM_LIST_UPDATE")
    for _ = 1, 50 do fire("REPLICATE_ITEM_LIST_UPDATE") end
    advance(30)
    fire("AUCTION_HOUSE_CLOSED") advance(1)
    assert(Count("left out: already reading", mark) == 1, Count("left out: already reading", mark) .. " already-reading lines, want 1")
    assert(Count("49 further updates ignored (already reading)", mark) == 1, "no count of the other 49")
    AHX.GetNumReplicateItems, AHX.GetReplicateItemInfo = keepNum, keepInfo
    p = ns.db.prices[next(ns.db.prices)]
    p.items, p.qty, p.seen, p.scanned = keep.items, keep.qty, keep.seen, keep.scanned
    p.lastScanStart = nil
    ns.db.debug = wasDebug
end)
step("Market price: the cheapest offer with stock behind it (v0.1.16)", function()
    local p = ns.db.prices[next(ns.db.prices)]
    local AHX = C_AuctionHouse
    local keepNum, keepInfo = AHX.GetNumReplicateItems, AHX.GetReplicateItemInfo
    local keepCount, keepRow, keepFull = AHX.GetNumCommoditySearchResults, AHX.GetCommoditySearchResultInfo, AHX.HasFullCommoditySearchResults
    local keepPrices = { p.items, p.qty, p.seen, p.scanned }
    local ID = 12345
    local CASES = {
        -- what, { unit price, quantity, ... }, price
        { "Blood Shard", { 13, 400, 25, 2800 }, 13 },
        { "all at the minimum", { 13, 3222 }, 13 },
        { "one bait item", { 1, 1, 100, 1000 }, 100 },
        { "four bait items", { 1, 4, 100, 1000 }, 100 },
        { "bait, under 2% of much stock", { 1, 19, 100, 981 }, 100 },
        { "real stock at 2%", { 1, 20, 100, 980 }, 1 },
        { "five are enough", { 10, 5, 50, 95 }, 10 },
        { "three plus two", { 10, 3, 12, 2, 50, 95 }, 12 },
        { "little stock", { 10, 1, 20, 2 }, 20 },
        { "one item", { 77, 1 }, 77 },
    }
    local fails = {}
    fire("AUCTION_HOUSE_SHOW") advance(1)
    for _, case in ipairs(CASES) do
        local what, list, want = case[1], case[2], case[3]
        -- commodity search
        AHX.GetNumCommoditySearchResults = function() return #list / 2 end
        AHX.HasFullCommoditySearchResults = function() return true end
        AHX.GetCommoditySearchResultInfo = function(_, i) return { unitPrice = list[i * 2 - 1], quantity = list[i * 2] } end
        fire("COMMODITY_SEARCH_RESULTS_UPDATED", ID)
        if p.items[ID] ~= want then fails[#fails + 1] = what .. ", commodity: " .. tostring(p.items[ID]) end
        -- item search: a buyout for the whole stack
        AHX.GetNumItemSearchResults = function() return #list / 2 end
        AHX.GetItemSearchResultInfo = function(_, i) return { buyoutAmount = list[i * 2 - 1] * list[i * 2], quantity = list[i * 2] } end
        p.items[ID] = nil
        fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = ID })
        if p.items[ID] ~= want then fails[#fails + 1] = what .. ", item: " .. tostring(p.items[ID]) end
        -- full scan
        AHX.GetNumReplicateItems = function() return #list / 2 end
        AHX.GetReplicateItemInfo = function(i)
            local unit, qty = list[i * 2 + 1], list[i * 2 + 2]
            if not unit then return nil end
            return "Item", 1, qty, 1, true, 1, 0, 0, 0, unit * qty, 0, false, nil, "Seller", nil, 0, ID, true
        end
        p.lastScanStart = nil
        slash("scan") advance(1)
        fire("REPLICATE_ITEM_LIST_UPDATE") advance(2)
        if p.items[ID] ~= want then fails[#fails + 1] = what .. ", scan: " .. tostring(p.items[ID]) end
    end
    -- the browse list only knows the lowest price: it stays that
    p.seen[ID] = time() - 7200
    local keepBrowse = AHX.GetBrowseResults
    AHX.GetBrowseResults = function() return { { itemKey = { itemID = ID }, minPrice = 3, totalQuantity = 1 } } end
    fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    if p.items[ID] ~= 3 then fails[#fails + 1] = "browse: " .. tostring(p.items[ID]) end
    fire("AUCTION_HOUSE_CLOSED")
    AHX.GetBrowseResults = keepBrowse
    AHX.GetNumReplicateItems, AHX.GetReplicateItemInfo = keepNum, keepInfo
    AHX.GetNumCommoditySearchResults, AHX.GetCommoditySearchResultInfo, AHX.HasFullCommoditySearchResults = keepCount, keepRow, keepFull
    AHX.GetNumItemSearchResults, AHX.GetItemSearchResultInfo = nil, nil
    -- each scan here replaced all prices: the steps after this one need the old ones
    p.items, p.qty, p.seen, p.scanned = keepPrices[1], keepPrices[2], keepPrices[3], keepPrices[4]
    p.items[ID], p.qty[ID], p.seen[ID], p.history[ID] = nil, nil, nil, nil
    assert(#fails == 0, #fails .. " wrong: " .. table.concat(fails, " | "))
end)
step("Prices: fresh before own, and the label says which (v0.1.16)", function()
    local p = ns.db.prices[next(ns.db.prices)]
    local keepTime, keepAddLine, keepItem = time, GameTooltip.AddDoubleLine, GameTooltip.GetItem
    local clock = keepTime()
    time = function() return clock end
    local ID, OTHER = 2771, 2772
    local keepSeen, keepScanned = p.seen, p.scanned
    local fails = {}
    local function Check(ok, text) if not ok then fails[#fails + 1] = text end end
    local function Own(hours, id)
        p.items[id or ID], p.qty[id or ID], p.seen[id or ID] = 295, 1143, clock - hours * 3600
    end
    local function Atr(price, hasAge, days)
        local api = { GetAuctionPriceByItemID = function(_, id) return id == ID and price or nil end }
        if hasAge then api.GetAuctionAgeByItemID = function() return days end end
        Auctionator = { API = { v1 = api } }
    end
    local function Want(what, price, source)
        local got, from = ns.GetPrice(ID)
        Check(got == price and from == source, ("%s: %s %s"):format(what, tostring(got), tostring(from)))
    end
    -- without an age from Auctionator
    Atr(187)
    Own(5.9) Want("own 5.9 h", 295, "AH scan")
    Own(6) Want("own 6 h", 187, "Auctionator")
    Own(21) Want("own 21 h", 187, "Auctionator")
    Own(24 * 8) Want("own 8 days", 187, "Auctionator")
    -- Auctionator without a price for it
    Atr(nil)
    Own(21) Want("no Auctionator price, 21 h", 295, "AH scan")
    Own(24 * 6.9) Want("no Auctionator price, 6.9 days", 295, "AH scan")
    -- Auctionator with an age: only if it is fresher
    Atr(187, true, 0)
    Own(5) Want("seen today, own 5 h", 295, "AH scan")
    Own(21) Want("seen today, own 21 h", 187, "Auctionator")
    Atr(187, true, 3)
    Own(24) Want("3 days, own 1 day", 295, "AH scan")
    Own(24 * 4) Want("3 days, own 4 days", 187, "Auctionator")
    Atr(187, true, nil)
    Own(24) Want("older than 21 days, own 1 day", 295, "AH scan")
    Own(24 * 6.9) Want("older than 21 days, own 6.9 days", 295, "AH scan")
    Own(24 * 8) Want("older than 21 days, own 8 days", 187, "Auctionator")
    Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function() return 187 end, GetAuctionAgeByItemID = function() error("broken") end } } }
    Own(21) Want("age call breaks", 187, "Auctionator")
    -- no Auctionator at all
    Auctionator = nil
    Own(24 * 6.9) Want("alone, 6.9 days", 295, "AH scan")
    Own(24 * 8)
    Check(select(2, ns.GetPrice(ID)) ~= "AH scan", "alone, 8 days: still our own")

    -- tooltip: old is marked, what is used instead is named
    local lines
    GameTooltip.AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. " = " .. r end
    GameTooltip.GetItem = function() return "Tin Ore", "|Hitem:" .. ID .. "::|h" end
    local function Tooltip()
        lines = {}
        GameTooltip.__scripts.OnTooltipSetItem(GameTooltip)
        return table.concat(lines, " / ")
    end
    local used = ns.L["    used instead"]
    Atr(187)
    Own(5)
    local text = Tooltip()
    Check(text:find("|cff999999(", 1, true) and not text:find("|cffff8040", 1, true), "tooltip, fresh: marked old")
    Check(not text:find(used, 1, true), "tooltip, fresh: used instead")
    Own(21)
    text = Tooltip()
    Check(text:find("|cffff8040(", 1, true), "tooltip, 21 h: not marked old")
    Check(text:find(used, 1, true) and text:find("(Auctionator)", 1, true) and text:find(ns.Money(187), 1, true), "tooltip, 21 h: Auctionator not named")
    Atr(nil)
    text = Tooltip()
    Check(text:find("|cffff8040(", 1, true) and not text:find(used, 1, true), "tooltip, old and alone")
    Auctionator = nil

    -- the labels: "prices: ..." and the source of a mix
    p.seen, p.scanned = { [ID] = clock - 7 * 3600 }, clock - 7 * 3600
    -- R4-H1: the label names the sources in their order, never one for all
    local atr = ns.L["prices: Auctionator (scan at the auction house for our own)"]
    local own = ns.L["prices: own scan (newest %s ago), vendor"]:format("7 h")
    local mix = ns.L["prices: own scan (newest %s ago), fresher Auctionator, vendor"]
    Check(ns.PriceSourceText() == own, "label, 7 h, alone: " .. ns.PriceSourceText())
    Atr(187)
    Check(ns.PriceSourceText() == mix:format("7 h"), "label, 7 h, Auctionator: " .. ns.PriceSourceText())
    -- Codex's probe: own Tin 21 h old, Auctionator 3 days: the own price is used, the label says own scan first
    p.seen[ID], p.scanned = clock - 21 * 3600, clock - 21 * 3600
    Check(ns.PriceSourceText() == mix:format("21 h"), "label, 21 h: " .. ns.PriceSourceText())
    p.seen[ID] = clock - 3600
    Check(ns.PriceSourceText() == mix:format("60" .. ns.L[" min"]) or ns.PriceSourceText() == mix:format("1 h"), "label, 1 h: " .. ns.PriceSourceText())
    p.seen[ID] = clock - 86400 * 8
    p.scanned = clock - 86400 * 8
    Check(ns.PriceSourceText() == atr, "label, 8 days")
    p.seen = keepSeen
    Own(1, OTHER)
    Own(21)
    Check(select(2, ns.LootValue({ { id = ID, qty = 1 }, { id = OTHER, qty = 1 } })) == "AH scan", "mix: Auctionator, then own")
    Check(ns.BetterPriceSource("vendor", "Auctionator") == "Auctionator" and ns.BetterPriceSource("AH scan", "vendor") == "AH scan", "mix: vendor named")
    Check(ns.BetterPriceSource("vendor", nil) == "vendor" and ns.BetterPriceSource(nil, "vendor") == "vendor" and ns.BetterPriceSource(nil, nil) == nil, "mix: alone")
    Auctionator = nil
    p.items[OTHER], p.qty[OTHER], p.seen[OTHER] = nil, nil, nil
    p.scanned = keepScanned
    GameTooltip.AddDoubleLine, GameTooltip.GetItem, time = keepAddLine, keepItem, keepTime
    assert(#fails == 0, #fails .. " wrong: " .. table.concat(fails, " | "))
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
step("Questing mode: on and off by command, Ctrl + right-click, key and option; a run or fishing ends it (v0.1.19 Q1)", function()
    local L = ns.L
    local keepCtrl = IsControlKeyDown
    local calls = {}
    local function Listen(on) calls[#calls + 1] = on end
    local ok, err = pcall(function()
        assert(ns.QuestModeOn and ns.SetQuestMode and ns.questModeListeners, "no questing mode")
        table.insert(ns.questModeListeners, Listen)
        ns.SetQuestMode(false)
        local function Said(text, mark)
            for i = mark + 1, #log do if log[i]:find(text, 1, true) then return true end end
        end
        -- /gcr quest
        local mark = #log
        slash("quest")
        assert(ns.QuestModeOn() and ns.db.questMode, "/gcr quest did not turn it on")
        assert(Said(L["Questing mode on – nearby nodes get a gold ring"], mark), "no chat line when turned on")
        mark = #log
        slash("quest")
        assert(not ns.QuestModeOn() and ns.db.questMode == nil, "/gcr quest did not turn it off")
        assert(Said(L["Questing mode off"], mark), "no chat line when turned off")
        assert(#calls == 2 and calls[1] == true and calls[2] == false, "the rings are not told: " .. #calls)
        -- Ctrl + right-click on the minimap button: no farm run
        IsControlKeyDown = function() return true end
        ldbObj.OnClick(nil, "RightButton")
        assert(ns.QuestModeOn() and not ns.run, "Ctrl + right-click: not on, or a run started")
        -- the tooltip says it, with the state
        local lines = {}
        local tt = { AddLine = function(_, t) lines[#lines + 1] = t end }
        ldbObj.OnTooltipShow(tt)
        local onLine = L["Ctrl + right-click: questing mode"] .. " |cff00ff00" .. L["on"] .. "|r"
        local found = false
        for _, l in ipairs(lines) do if l == onLine then found = true end end
        assert(found, "tooltip: " .. onLine .. " | " .. table.concat(lines, " | "))
        ldbObj.OnClick(nil, "RightButton")
        assert(not ns.QuestModeOn() and not ns.run, "Ctrl + right-click again: not off")
        lines = {}
        ldbObj.OnTooltipShow(tt)
        local offLine = L["Ctrl + right-click: questing mode"] .. " |cff999999" .. L["off"] .. "|r"
        found = false
        for _, l in ipairs(lines) do if l == offLine then found = true end end
        assert(found, "tooltip: " .. offLine)
        IsControlKeyDown = keepCtrl
        -- a plain right-click still starts the run
        ldbObj.OnClick(nil, "RightButton") advance(1)
        assert(ns.run, "right-click no longer starts a run")
        ns.StopRun()
        -- key binding
        local f = assert(io.open(ROOT .. "/Bindings.xml"))
        local xml = f:read("*a") f:close()
        assert(xml:find('<Binding name="GATHERCRAFT_QUEST" category="ADDONS">Gathercraft_QuestMode()</Binding>', 1, true), "no key binding")
        assert(BINDING_NAME_GATHERCRAFT_QUEST == L["Questing mode on / off"], "binding name: " .. tostring(BINDING_NAME_GATHERCRAFT_QUEST))
        Gathercraft_QuestMode()
        assert(ns.QuestModeOn(), "the key did not turn it on")
        Gathercraft_QuestMode()
        assert(not ns.QuestModeOn(), "the key did not turn it off")
        -- Options > Map & minimap
        local box
        for _, o in ipairs(allFrames) do
            if o.__kind == "FontString" and o:GetText() == L["Questing mode"] and o.__pts and o.__pts.LEFT then
                local cb = o.__pts.LEFT[1]
                if cb and cb.__kind == "CheckButton" and cb.get then box = cb end
                local p = o.__parent
                while p and not p.key do p = p.__parent end
                assert(p and p.key == "map", "the switch is not under Map & minimap")
            end
        end
        assert(box, "no switch in the options")
        assert(box.get() == false, "the switch shows on while off")
        box:SetChecked(true) box.__scripts.OnClick(box)
        assert(ns.QuestModeOn() and box.get() == true, "the switch did not turn it on")
        -- kept over /reload and login (saved variables); the rings are told again
        local before = #calls
        local watch = _G.GathercraftQuestWatch
        assert(watch and eventFrames.PLAYER_LOGIN[watch], "test setup: the questing mode's login frame")
        watch.__scripts.OnEvent(watch, "PLAYER_LOGIN")
        assert(ns.db.questMode and ns.QuestModeOn(), "not kept over the login")
        assert(#calls > before and calls[#calls] == true, "after the login the rings are not told")
        -- a farm run turns it off, with a word; after the run it stays off
        mark = #log
        slash("run herb") advance(2)
        assert(ns.run, "test setup: no run")
        assert(not ns.QuestModeOn(), "still on during a farm run")
        assert(Said(L["Questing mode off: a farm run started."], mark), "no word why it went off (run)")
        slash("stop") advance(1)
        assert(not ns.QuestModeOn(), "back on after the run")
        -- fishing too
        ns.SetQuestMode(true)
        mark = #log
        fire("UNIT_SPELLCAST_CHANNEL_START", "player", "q1fish", 7620) advance(1)
        assert(not ns.QuestModeOn(), "still on while fishing")
        assert(Said(L["Questing mode off: you started fishing."], mark), "no word why it went off (fishing)")
        fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "q1fish", 7620) advance(1)
        assert(not ns.QuestModeOn(), "back on after fishing")
        -- the second cast of the same fishing session turns it off too, and
        -- the session goes on (Codex 09.11., B1)
        local session = ns.FishingSession()
        assert(session and session.start, "test setup: no fishing session after the first cast")
        local started = session.start
        advance(30)
        ns.SetQuestMode(true)
        mark = #log
        fire("UNIT_SPELLCAST_CHANNEL_START", "player", "q1fish2", 7620) advance(1)
        assert(not ns.QuestModeOn(), "still on at the second cast of the session")
        assert(Said(L["Questing mode off: you started fishing."], mark), "no word why it went off (second cast)")
        assert(ns.FishingSession() and ns.FishingSession().start == started, "the second cast started the fishing session anew")
        fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "q1fish2", 7620) advance(1)
        ns.StopFishing()
        assert(not ns.QuestModeOn(), "back on after fishing")
    end)
    IsControlKeyDown = keepCtrl
    for i = #ns.questModeListeners, 1, -1 do if ns.questModeListeners[i] == Listen then table.remove(ns.questModeListeners, i) end end
    if ns.StopRun then ns.StopRun() end
    if ns.SetQuestMode then ns.SetQuestMode(false) end
    if not ok then error(err, 0) end
end)
step("Questing mode: gold rings on nearby nodes you can gather, minimap only (v0.1.19 Q2)", function()
    -- map 5000 x 3333 yd in the mock: 0.001 in x is 5 yd
    local Z, Z2 = 1460, 1461
    local keep = { nodes = ns.db.nodes[Z], nodes2 = ns.db.nodes[Z2], style = ns.db.miniPinStyle, chests = ns.db.chestsHidden, grey = ns.db.hideGreyNodes,
        gp = ns.GatherProfessions, skill = ns.GetSkill, pos = ns.GetPlayerPos, secret = issecretvalue,
        map = player.map, x = player.x, y = player.y }
    local px, py = 0.5, 0.5
    local function At(yd, name, kind, extra)
        local n = { id = "o9" .. math.random(100000, 999999), name = name, type = kind, x = px + yd / 5000, y = py, count = 1, last = 1, hits = 1 }
        for k, v in pairs(extra or {}) do n[k] = v end
        table.insert(ns.db.nodes[Z], n)
        return n
    end
    local ok, err = pcall(function()
        ns.SetQuestMode(false)
        ns.db.nodes[Z] = {}
        local near = At(20, "Peacebloom", "herb")
        local edge = At(75, "Mageroyal", "herb")          -- skill 50, yours 52
        local out = At(76, "Peacebloom", "herb")
        local ore = At(40, "Copper Vein", "ore")
        -- (other herbs stand more than 10 yd from `near`: since 0.1.21 herbs
        -- that close are one place with one ring - its own step, T1)
        local herbHigh = At(-40, "Briarthorn", "herb")   -- needs 70
        local oreHigh = At(12, "Tin Vein", "ore")        -- needs 65, yours 30
        local chest = At(30, "Battered Chest", "chest")
        local resting = At(-15, "Silverleaf", "herb", { emptyUntil = time() + 300 }) -- just harvested / found empty
        ns.db.nodes[Z2] = {}
        local other = { id = "o1617", name = "Silverleaf", type = "herb", x = px + 0.001, y = py, count = 1, last = 1, hits = 1 }
        table.insert(ns.db.nodes[Z2], other)
        player.map, player.x, player.y = Z, px, py
        fire("ZONE_CHANGED_NEW_AREA") advance(1) -- the minimap pins move to this zone
        ns.db.miniPinStyle, ns.db.chestsHidden = nil, nil -- ring only, chests shown
        ns.NotifyNodesChanged() advance(1)
        -- off: nothing lit
        assert(not next(ns.QuestRings()), "rings while the mode is off")
        local REF = "GathercraftQuest"
        HBD_ADDS[REF] = { world = 0, mini = 0 }
        ns.SetQuestMode(true) advance(1)
        local lit = ns.QuestRings()
        local function Lit(n) return lit[n] ~= nil end
        assert(Lit(near) and Lit(edge) and Lit(ore) and Lit(chest), ("a node you can gather in reach is not lit: near %s edge %s ore %s chest %s"):format(tostring(Lit(near)), tostring(Lit(edge)), tostring(Lit(ore)), tostring(Lit(chest))))
        assert(not Lit(out), "lit outside the radius (76 yd)")
        assert(not Lit(herbHigh) and not Lit(oreHigh), "lit although your skill is too low")
        assert(not Lit(resting), "lit although just harvested or found empty")
        assert(not Lit(other), "a node of another zone lit")
        -- the minimap only
        assert(HBD_ADDS[REF].mini >= 4 and HBD_ADDS[REF].world == 0, ("rings: %d minimap, %d world map"):format(HBD_ADDS[REF].mini, HBD_ADDS[REF].world))
        -- the look of the run target (ring only: its size, no icon - and since
        -- 0.1.21 the thin gold ring where the target has the broad one: T6)
        local function Tex(pin) return tostring(pin.ring and pin.ring.__tex or "") end
        local function TargetLook(style)
            ns.db.miniPinStyle = style
            ns.SetRouteTarget(Z, near)
            local _, mini = ns.RouteTargetPins()
            local w, shown, tex = mini.__w, mini.icon.__shown ~= false, Tex(mini)
            ns.ClearRouteTarget()
            return w, shown, tex
        end
        for _, style in ipairs({ "ring", "subtle", "normal" }) do
            local tw, tshown, ttex = TargetLook(style ~= "ring" and style or nil)
            ns.NotifyNodesChanged() advance(1) -- the options rebuild the pins
            local pin = ns.QuestRings()[near]
            assert(pin, style .. ": the ring went with the rebuild")
            local want = style == "ring" and ttex:gsub("RingGoldBold$", "RingGold") or ttex
            assert(Tex(pin) == want and pin.__w == tw and (pin.icon.__shown ~= false) == tshown,
                ("%s: ring %s %spx icon %s, the run target %s %spx icon %s"):format(style, Tex(pin), tostring(pin.__w),
                    tostring(pin.icon.__shown ~= false), ttex, tostring(tw), tostring(tshown)))
            if style == "ring" then assert(ttex:find("RingGoldBold$") and not tshown, "test setup: ring only target") end
        end
        ns.db.miniPinStyle = nil
        ns.NotifyNodesChanged() advance(1)
        -- the node's own minimap pin steps aside under its ring, comes back after
        local mine
        for _, pin in ipairs(MINI_ICONS) do if pin.node == near and pin.isMini and not pin.isQuest then mine = pin end end
        assert(mine and mine.__alpha == 0, "the normal minimap pin still shows under the ring")
        -- chests only while shown
        ns.db.chestsHidden = true
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(not ns.QuestRings()[chest] and ns.QuestRings()[near], "a chest lit while chests are hidden")
        ns.db.chestsHidden = nil
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(ns.QuestRings()[chest], "the chest not lit again")
        -- a profession you don't have: none of its nodes
        ns.GatherProfessions = function() return false, true, true end
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(not ns.QuestRings()[near] and not ns.QuestRings()[edge] and ns.QuestRings()[ore], "herbs lit without Herbalism")
        ns.GatherProfessions = keep.gp
        ns.GetSkill = function(t) if t == "herb" then return keep.skill(t) end end -- Mining not learned
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(ns.QuestRings()[near] and not ns.QuestRings()[ore], "ore lit without Mining")
        -- "Hide grey nodes" (Options > Leveling): a node that gives no more
        -- skill-ups gets no ring while the option is on (Sven, 09.11.)
        ns.GetSkill = function(t) if t == "herb" then return 160, 225, 160 end return keep.skill(t) end -- Peacebloom (1) is grey from 100
        ns.db.hideGreyNodes = true
        ns.NotifyNodesChanged() advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(not ns.QuestRings()[near] and ns.QuestRings()[ore], "a grey herb lit although grey nodes are hidden")
        ns.db.hideGreyNodes = nil
        ns.NotifyNodesChanged() advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(ns.QuestRings()[near], "a grey herb not lit although grey nodes are shown")
        ns.GetSkill = keep.skill
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        -- a hidden skill: nothing of it, no error
        local SECRET = newproxy(true)
        issecretvalue = function(v) return rawequal(v, SECRET) end
        ns.GetSkill = function(t) if t == "herb" then return SECRET, 75, SECRET end return keep.skill(t) end
        ns.GetSkill("ore") -- (only the questing mode reads it now: no other timer meets the stand-in)
        ns.UpdateQuestRings()
        assert(not ns.QuestRings()[near] and ns.QuestRings()[ore], "a hidden Herbalism skill: herbs lit")
        ns.GetSkill, issecretvalue = keep.skill, keep.secret
        -- the position can't be read (hidden): no rings, no error
        ns.GetPlayerPos = function() end
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(not next(ns.QuestRings()), "rings without a position")
        ns.GetPlayerPos = keep.pos
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(ns.QuestRings()[near], "the rings did not come back")
        -- another zone: its nodes, not the old ones
        player.map, player.x, player.y = Z2, px, py
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
        assert(ns.QuestRings()[other] and not ns.QuestRings()[near], "after a zone change: the old zone's rings")
        player.map = Z
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
        -- walking away: the rings go
        player.x = px + 0.05
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        assert(not next(ns.QuestRings()), "rings 250 yd away")
        player.x = px
        advance(3) -- the questing mode looks again at least every 2 s (Q4)
        -- off: all rings go, the normal pin is back
        ns.SetQuestMode(false) advance(1)
        assert(not next(ns.QuestRings()), "rings after turning it off")
        assert(mine.__alpha and mine.__alpha > 0, "the normal minimap pin did not come back")
    end)
    ns.SetQuestMode(false)
    ns.GatherProfessions, ns.GetSkill, ns.GetPlayerPos, issecretvalue = keep.gp, keep.skill, keep.pos, keep.secret
    ns.db.nodes[Z], ns.db.nodes[Z2], ns.db.miniPinStyle, ns.db.chestsHidden, ns.db.hideGreyNodes = keep.nodes, keep.nodes2, keep.style, keep.chests, keep.grey
    player.map, player.x, player.y = keep.map, keep.x, keep.y
    fire("ZONE_CHANGED_NEW_AREA") advance(1)
    ns.NotifyNodesChanged() advance(1)
    if not ok then error(err, 0) end
end)
step("Questing mode: radius 50 / 75 / 100 yd and the arrow to the nearest ring (v0.1.19 Q3)", function()
    local L = ns.L
    local Z = 1460
    local keep = { nodes = ns.db.nodes[Z], radius = ns.db.questRadius, arrow = ns.db.questArrow,
        map = player.map, x = player.x, y = player.y }
    local win = _G.GathercraftOptions
    local wasOpen, wasSection = win:IsShown(), ns.db.optionsSection
    local px, py = 0.5, 0.5
    -- dir: east, west or north of you (the map is 5000 x 3333 yd)
    -- (kind: the three nodes at a limit are a herb, a vein and a chest - one
    -- yard apart, three of one kind would be one place with one ring: T1)
    local KINDS = { herb = { "o1618", "Peacebloom" }, ore = { "o1731", "Copper Vein" }, chest = { "o2843", "Battered Chest" } }
    local function Node(yd, dir, kind)
        local x, y = px, py
        if dir == "east" then x = px + yd / 5000 elseif dir == "west" then x = px - yd / 5000 else y = py - yd / 3333 end
        local n = { id = KINDS[kind][1], name = KINDS[kind][2], type = kind, x = x, y = y, count = 1, last = 1, hits = 1 }
        table.insert(ns.db.nodes[Z], n)
        return n
    end
    local function PageOf(o)
        local p = o.__parent
        while p and not p.key do p = p.__parent end
        return p and p.key
    end
    local ok, err = pcall(function()
        assert(ns.QUEST_RADII and #ns.QUEST_RADII == 3 and ns.QUEST_RADII[1] == 50 and ns.QUEST_RADII[2] == 75 and ns.QUEST_RADII[3] == 100, "not 50 / 75 / 100")
        ns.db.questRadius, ns.db.questArrow = nil, nil
        assert(ns.QuestRadius() == 75, "the default is not 75: " .. tostring(ns.QuestRadius()))
        ns.db.nodes[Z] = {}
        player.map, player.x, player.y = Z, px, py
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
        -- three nodes at each limit, each radius in its own direction
        local rows = {}
        for r, dir in pairs({ [50] = "east", [75] = "west", [100] = "north" }) do
            rows[r] = { Node(r - 1, dir, "herb"), Node(r, dir, "ore"), Node(r + 1, dir, "chest") }
        end
        ns.NotifyNodesChanged() advance(1)
        ns.SetQuestMode(true) advance(1)
        local function Check(r)
            local lit = ns.QuestRings()
            for limit, row in pairs(rows) do
                for k, n in ipairs(row) do
                    local d = limit - 2 + k -- limit-1, limit, limit+1
                    local want = d <= r
                    assert((lit[n] ~= nil) == want, ("radius %d: a node at %d yd %s"):format(r, d, want and "not lit" or "lit"))
                end
            end
        end
        Check(75)
        -- the < > control in Options > Map & minimap (open, so it shows its value)
        if not win:IsShown() then ns.ToggleOptions() end
        ns.ShowOptionsSection("map")
        win:Refresh()
        local valueText, plus, minus
        for _, o in ipairs(allFrames) do
            if o.__kind == "FontString" and o:GetText() == (L["%d yd"]):format(75) and PageOf(o) == "map" and o.__pts and o.__pts.LEFT then
                minus = o.__pts.LEFT[1]
                valueText = o
            end
        end
        assert(valueText and minus and minus.__kind == "Button", "no radius control under Map & minimap")
        for _, o in ipairs(allFrames) do
            if o.__kind == "Button" and o.__pts and o.__pts.LEFT and o.__pts.LEFT[1] == valueText then plus = o end
        end
        assert(plus, "test setup: the > button")
        plus.__scripts.OnClick(plus) advance(1)
        assert(ns.QuestRadius() == 100 and ns.db.questRadius == 100 and valueText:GetText() == (L["%d yd"]):format(100), "> did not go to 100 yd")
        Check(100)
        plus.__scripts.OnClick(plus) advance(1)
        assert(ns.QuestRadius() == 100, "> went past 100 yd")
        minus.__scripts.OnClick(minus) minus.__scripts.OnClick(minus) advance(1)
        assert(ns.QuestRadius() == 50 and ns.db.questRadius == 50, "< did not go to 50 yd")
        Check(50)
        minus.__scripts.OnClick(minus) advance(1)
        assert(ns.QuestRadius() == 50, "< went below 50 yd")
        plus.__scripts.OnClick(plus) advance(1)
        assert(ns.QuestRadius() == 75 and ns.db.questRadius == nil, "back at 75: not saved as the default")
        -- an odd saved value: the default
        ns.db.questRadius = 60
        assert(ns.QuestRadius() == 75, "a saved 60 yd is used")
        ns.db.questRadius = nil
        -- the arrow: off by default
        advance(1)
        local arrow = _G.GathercraftArrow
        assert(arrow and not arrow:IsShown() and not ns.QuestArrowNode(), "the arrow shows although it is off")
        local box
        for _, o in ipairs(allFrames) do
            if o.__kind == "FontString" and o:GetText() == L["Arrow to the nearest gold ring"] and o.__pts and o.__pts.LEFT then
                box = o.__pts.LEFT[1]
                assert(PageOf(o) == "map", "the arrow switch is not under Map & minimap")
            end
        end
        assert(box and box.get and box.get() ~= true, "no arrow switch, or it is on")
        box:SetChecked(true) box.__scripts.OnClick(box) advance(1)
        assert(ns.db.questArrow, "the switch did not turn the arrow on")
        local n = ns.QuestArrowNode()
        assert(n == rows[50][1], "the arrow does not point at the nearest ring: " .. tostring(n and n.x))
        assert(arrow:IsShown(), ("the arrow does not show: run %s, shown %s, hidden %s"):format(tostring(ns.run), tostring(arrow.__shown), tostring(ns.db.arrowHidden)))
        -- only which way and how far: no route, no line
        assert(not ns.run, "a run started")
        -- walking: it follows the nearest one
        player.x = px - 75 / 5000 -- 75 yd west: right at the middle node of that row
        advance(1)
        assert(ns.QuestArrowNode() == rows[75][2], "the arrow did not move on to the nearest ring")
        player.x = px
        advance(1)
        -- off again: gone
        box:SetChecked(false) box.__scripts.OnClick(box) advance(1)
        assert(not ns.QuestArrowNode() and not arrow:IsShown(), "the arrow stays when switched off")
        -- with the mode off: no arrow either
        ns.db.questArrow = true
        ns.SetQuestMode(false) advance(1)
        assert(not ns.QuestArrowNode() and not arrow:IsShown(), "the arrow stays with the questing mode off")
    end)
    ns.SetQuestMode(false)
    ns.db.nodes[Z], ns.db.questRadius, ns.db.questArrow = keep.nodes, keep.radius, keep.arrow
    player.map, player.x, player.y = keep.map, keep.x, keep.y
    ns.ShowOptionsSection(wasSection or "map")
    if win:IsShown() ~= wasOpen then ns.ToggleOptions() end
    fire("ZONE_CHANGED_NEW_AREA") advance(1)
    ns.NotifyNodesChanged() advance(1)
    if not ok then error(err, 0) end
end)
step("Questing mode: looks again only after 5 yd, a change or 2 s; nothing while off; Hillsbrad (v0.1.19 Q4)", function()
    local Z = 1424 -- Hillsbrad Foothills: every herb and ore spawn point of the Questie data
    local keep = { nodes = ns.db.nodes[Z], map = player.map, x = player.x, y = player.y }
    local ok, err = pcall(function()
        ns.SetQuestMode(false)
        ns.ImportQuestieZone(Z, true)
        local questie = #(ns.db.nodes[Z] or {})
        assert(questie >= 600, "test setup: Hillsbrad has " .. questie .. " Questie nodes")
        -- plus own finds up to 700 (Sven's zone had 680+)
        for i = questie + 1, 700 do
            table.insert(ns.db.nodes[Z], { id = "o1617", name = "Silverleaf", type = "herb", x = (i % 40) / 40, y = math.floor(i / 40) / 20, count = 1, last = 1, hits = 1 })
        end
        local count = #ns.db.nodes[Z]
        ns.NotifyNodesChanged() advance(1)
        note("Hillsbrad nodes", questie, "from Questie,", count, "in all")
        player.map, player.x, player.y = Z, 0.5, 0.5
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
        -- off: nothing is gone through, however long
        local p0 = ns.QuestPicks()
        advance(10)
        assert(ns.QuestPicks() == p0, "the nodes were gone through while the mode is off")
        -- on: once at once
        ns.SetQuestMode(true)
        local p1 = ns.QuestPicks()
        assert(p1 == p0 + 1, "not looked at once when turned on")
        -- standing still for 10 s (20 ticks): only the 2 s refresh
        advance(10)
        local still = ns.QuestPicks() - p1
        assert(still >= 3 and still <= 6, "standing still 10 s: gone through " .. still .. " times (want every 2 s, not every tick)")
        -- 4 yd walked: nothing new; 6 yd: at once
        advance(2.1)
        local p2 = ns.QuestPicks()
        player.x = player.x + 4 / 5000
        advance(0.6)
        assert(ns.QuestPicks() == p2, "4 yd walked: gone through again")
        player.x = player.x + 2 / 5000
        advance(0.6)
        assert(ns.QuestPicks() == p2 + 1, "6 yd walked: not gone through again")
        -- a node changed (harvested, options): at the next tick
        local p3 = ns.QuestPicks()
        ns.NotifyNodesChanged()
        advance(0.6)
        assert(ns.QuestPicks() > p3, "a node change: not looked again")
        -- one look at 680+ nodes is quick (the mock's clock: a rough bound only)
        local t0 = os.clock()
        for _ = 1, 20 do ns.UpdateQuestRings() end
        local ms = (os.clock() - t0) * 1000 / 20
        note("questing mode, one look at Hillsbrad", ("%.2f ms"):format(ms), "rings", (function() local c = 0 for _ in pairs(ns.QuestRings()) do c = c + 1 end return c end)())
        assert(ms < 25, ("one look at %d nodes takes %.1f ms"):format(count, ms))
        -- only this zone: a node of another zone is never looked at
        local seen = {}
        local realDistance = ns.Distance
        ns.Distance = function(mapID, ...) seen[mapID] = true return realDistance(mapID, ...) end
        ns.UpdateQuestRings()
        ns.Distance = realDistance
        for m in pairs(seen) do assert(m == Z, "a node of another zone was measured: " .. tostring(m)) end
        -- off: the ticker stops (no more looks)
        ns.SetQuestMode(false)
        local p4 = ns.QuestPicks()
        player.x = player.x + 0.01
        advance(5)
        assert(ns.QuestPicks() == p4, "still looking after turning it off")
    end)
    ns.SetQuestMode(false)
    ns.db.nodes[Z] = keep.nodes
    player.map, player.x, player.y = keep.map, keep.x, keep.y
    fire("ZONE_CHANGED_NEW_AREA") advance(1)
    ns.NotifyNodesChanged() advance(1)
    if not ok then error(err, 0) end
end)
-- Every herb and ore spawn point of a zone as the shipped Questie data has
-- it, as fresh node tables (the starter import itself runs once per session
-- and merges what lies close together: the 0.1.21 steps want the raw points)
local function QuestieZoneNodes(mapID)
    local data = GathercraftQuestieData
    local kindOf = { h = "herb", o = "ore" }
    local list = {}
    for id, xs, ys in (data.zones[mapID] or ""):gmatch("(%d+),(%d+),(%d+)") do
        local kind = data.kinds["o" .. id]
        if kind and kindOf[kind[1]] then
            list[#list + 1] = { id = "o" .. id, type = kindOf[kind[1]], name = kind[3], x = tonumber(xs) / 10000, y = tonumber(ys) / 10000,
                count = 0, last = 0, hits = 1, source = "questie" }
        end
    end
    return list
end
step("Questing mode: a look reads your skill once and asks only the nodes near you; the same rings (v0.1.21 T3)", function()
    -- Sven, 10.11.2026, Hillsbrad: a short hitch every few yards while the
    -- questing mode is on. A look went through every node of the zone and
    -- read the skill for each one (the whole skill list of the game, node by
    -- node), also for the nodes far away. Now the skill is read once per
    -- look, and only the nodes within the radius are asked the rest. Which
    -- nodes get a ring - and which one the arrow points at - is what it was:
    -- compared here with a copy of the old way, on a full zone with every
    -- kind of state mixed in.
    local Z = 1424 -- Hillsbrad Foothills
    local keep = { nodes = ns.db.nodes[Z], map = player.map, x = player.x, y = player.y, gp = ns.GatherProfessions, skill = ns.GetSkill, cool = ns.IsOnCooldown,
        secret = issecretvalue, chests = ns.db.chestsHidden, grey = ns.db.hideGreyNodes, radius = ns.db.questRadius, arrow = ns.db.questArrow,
        debug = ns.db.debug, say = ns.Debug }
    local ok, err = pcall(function()
        ns.SetQuestMode(false)
        -- one entry per place and kind (what several entries at one place do
        -- is another step): an entry closer than 15 yd to an earlier one of
        -- its kind is left out
        local all, list = QuestieZoneNodes(Z), {}
        assert(#all >= 600, "test setup: Hillsbrad has " .. #all .. " spawn points")
        for _, n in ipairs(all) do
            local alone = true
            for _, m in ipairs(list) do
                if m.type == n.type and ns.Distance(Z, m.x, m.y, n.x, n.y) < 15 then alone = false break end
            end
            if alone then list[#list + 1] = n end
        end
        assert(#list >= 300, "test setup: Hillsbrad has " .. #list .. " places")
        -- every kind of state, spread over the zone
        local now = time()
        for i, n in ipairs(list) do
            n.emptyUntil, n.parked, n.source, n.hits, n.pendingReport = nil, nil, nil, 1, nil
            if i % 7 == 0 then n.emptyUntil = now + 600 end                        -- just harvested / found empty
            if i % 11 == 0 then n.emptyUntil = now - 5 end                         -- rested long ago
            if i % 13 == 0 then n.parked, n.source, n.hits = true, "sync", 0 end   -- parked as always empty
            if i % 17 == 0 then n.pendingReport = {} end                           -- a report nobody confirmed
        end
        for i = 1, 40 do
            local at = list[i * 7]
            list[#list + 1] = { id = "o9" .. (800000 + i), name = "Battered Chest", type = "chest", x = at.x + 0.004, y = at.y + 0.003, count = 1, last = 1, hits = 1 }
            list[#list + 1] = { id = "o9" .. (810000 + i), name = "School of Fish", type = "fish", x = at.x - 0.004, y = at.y + 0.003, count = 1, last = 1, hits = 1 }
        end
        list[#list + 1] = { id = "o9820000", name = "Peacebloom", type = "herb", count = 1, last = 1, hits = 1 } -- no place
        ns.db.nodes[Z] = list
        ns.NotifyNodesChanged() advance(1)

        -- ---- the old way (0.1.20), word for word
        local function OldCanGather(n)
            if not (n and n.x and n.y) or n.pendingReport then return false end
            if ns.IsOnCooldown and ns.IsOnCooldown(n) then return false end
            if ns.IsParked and ns.IsParked(n) then return false end
            if n.type == "chest" then return not ns.db.chestsHidden end
            if n.type ~= "herb" and n.type ~= "ore" then return false end
            if ns.GatherProfessions then
                local herb, ore, known = ns.GatherProfessions()
                if known and not ((n.type == "herb" and herb) or (n.type == "ore" and ore)) then return false end
            end
            local rank, _, effective
            if ns.GetSkill then rank, _, effective = ns.GetSkill(n.type) end
            if not rank or ns.AnySecret("questing mode", rank, effective) then return false end
            local level = ns.SkillLevel(n.name, n.id, rank, effective)
            if level == "red" then return false end
            if level == "grey" and ns.db.hideGreyNodes then return false end
            return true
        end
        -- (since T1, the next step, rings go by places: the slow way does too.
        -- Every distance asked from ns.Distance, node by node; a place is the
        -- entries of one kind within 10 yd of its first entry, in the zone's
        -- order; it has a ring on its first entry OldCanGather says yes to,
        -- and none while an entry of it rests.)
        local function OldPick()
            local mapID, px, py = ns.GetPlayerPos()
            if not (mapID and px and py) then return end
            local want, r = {}, ns.QuestRadius()
            local places = {}
            for _, n in ipairs(ns.db.nodes[mapID] or {}) do
                local lit = n.x and n.y and not n.pendingReport
                    and (n.type == "herb" or n.type == "ore" or (n.type == "chest" and not ns.db.chestsHidden))
                if lit then
                    local d = math.floor(ns.Distance(mapID, px, py, n.x, n.y) + 0.5)
                    if d <= r then
                        local place
                        for _, s in ipairs(places) do
                            if not place and s.kind == n.type and ns.Distance(mapID, s[1].n.x, s[1].n.y, n.x, n.y) <= 10 then place = s end
                        end
                        if not place then
                            place = { kind = n.type }
                            places[#places + 1] = place
                        end
                        place[#place + 1] = { n = n, d = d }
                    end
                end
            end
            local nearest, nearestD
            for _, s in ipairs(places) do
                local resting, first
                for _, e in ipairs(s) do
                    if (ns.IsOnCooldown and ns.IsOnCooldown(e.n)) or (ns.IsParked and ns.IsParked(e.n)) then resting = true end
                    if not first and OldCanGather(e.n) then first = e end
                end
                if first and not resting then
                    want[first.n] = true
                    if not nearestD or first.d < nearestD then nearest, nearestD = first.n, first.d end
                end
            end
            return mapID, want, nearest
        end

        -- ---- the same rings and the same arrow, state by state
        local SECRET = newproxy(true)
        local herbSkill, oreSkill = { 100, 150, 105 }, { 70, 75, 70 }
        ns.GetSkill = function(kind)
            local s = kind == "herb" and herbSkill or kind == "ore" and oreSkill or nil
            if s then return s[1], s[2], s[3] end
        end
        ns.GatherProfessions = function() return true, true, true end
        ns.db.questArrow = true
        player.map = Z
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
        ns.SetQuestMode(true)
        local compared, lit, arrows = 0, 0, 0
        -- places to stand: next to nodes spread over the zone, and one in the open
        local stands = { { 0.05, 0.95 } }
        for _, i in ipairs({ 15, 70, 130, 190, 250 }) do stands[#stands + 1] = { list[i].x + 0.002, list[i].y + 0.001 } end
        local function Same(what)
            for _, pos in ipairs(stands) do
                player.x, player.y = pos[1], pos[2]
                for _, radius in ipairs({ 50, 75, 100 }) do
                    ns.db.questRadius = radius
                    local _, want, nearest = OldPick()
                    ns.UpdateQuestRings()
                    local rings = ns.QuestRings()
                    for n in pairs(want) do
                        assert(rings[n], ("%s, at %.2f / %.2f, %d yd: %s has no ring any more"):format(what, pos[1], pos[2], radius, tostring(n.name)))
                        lit = lit + 1
                    end
                    for n in pairs(rings) do
                        assert(want[n], ("%s, at %.2f / %.2f, %d yd: %s has a ring it did not have"):format(what, pos[1], pos[2], radius, tostring(n.name)))
                    end
                    assert(ns.QuestArrowNode() == nearest, ("%s, at %.2f / %.2f, %d yd: the arrow points at another node"):format(what, pos[1], pos[2], radius))
                    if nearest then arrows = arrows + 1 end
                    compared = compared + 1
                end
            end
        end
        Same("every profession")
        ns.db.hideGreyNodes = true
        Same("grey nodes hidden")
        ns.db.hideGreyNodes = nil
        ns.db.chestsHidden = true
        Same("chests hidden")
        ns.db.chestsHidden = nil
        ns.GatherProfessions = function() return false, true, true end
        Same("no Herbalism")
        ns.GatherProfessions = function() return true, false, false end -- (not known for sure: the skill decides)
        Same("professions not known for sure")
        ns.GatherProfessions = function() return true, true, true end
        oreSkill = nil
        Same("Mining not learned")
        oreSkill = { 300, 300, 300 }
        herbSkill = { 1, 75, 1 }
        Same("Herbalism at 1, Mining at 300")
        issecretvalue = function(v) return rawequal(v, SECRET) end
        herbSkill = { SECRET, 150, SECRET }
        Same("a hidden Herbalism skill")
        issecretvalue = keep.secret
        herbSkill, oreSkill = { 100, 150, 105 }, { 70, 75, 70 }
        ns.GatherProfessions = nil
        Same("no profession watch")
        ns.GatherProfessions = function() return true, true, true end
        assert(compared == 9 * 18 and lit > 150 and arrows > 60, ("test setup: %d looks compared, %d rings, %d arrows"):format(compared, lit, arrows))
        -- asking about one node (the way other parts ask) gives the old answer too
        for _, n in ipairs(list) do
            assert(ns.QuestCanGather(n) == OldCanGather(n), "asked alone, " .. tostring(n.name) .. " gets another answer")
        end

        -- ---- what a look costs: the skill once per kind, the rest only near you
        -- (where it asks the most nodes for their skill colour: there the
        -- skill would be read the most often)
        ns.db.questRadius = 100
        local realLevel = ns.SkillLevel
        local asks, best = 0, nil
        for i = 5, #list, 5 do
            local at = list[i]
            if at.x then
                player.x, player.y = at.x + 0.001, at.y
                ns.UpdateQuestRings()
                local levels = 0
                ns.SkillLevel = function(...) levels = levels + 1 return realLevel(...) end
                ns.UpdateQuestRings()
                ns.SkillLevel = realLevel
                if levels > asks then asks, best = levels, at end
            end
        end
        assert(best and asks >= 4, "test setup: no place where a look asks 4 nodes or more for their colour (" .. asks .. ")")
        player.x, player.y = best.x + 0.001, best.y
        local within = 0
        for _, n in ipairs(list) do
            if n.x and math.floor(ns.Distance(Z, player.x, player.y, n.x, n.y) + 0.5) <= 100 then within = within + 1 end
        end
        assert(within > 0 and within < 80, "test setup: " .. within .. " nodes within 100 yd")
        ns.UpdateQuestRings() -- (the rings of this place are lit: the pins have asked what they ask)
        local skillReads, restAsked = 0, 0
        local realSkill, realCool = ns.GetSkill, ns.IsOnCooldown
        ns.GetSkill = function(kind) skillReads = skillReads + 1 return realSkill(kind) end
        ns.IsOnCooldown = function(n) restAsked = restAsked + 1 return realCool(n) end
        ns.UpdateQuestRings()
        ns.GetSkill, ns.IsOnCooldown = realSkill, realCool
        local ringCount = 0
        for _ in pairs(ns.QuestRings()) do ringCount = ringCount + 1 end
        assert(ringCount > 0, "test setup: no ring at this place")
        assert(skillReads >= 1 and skillReads <= 2, ("one look read your skill %d times (%d nodes in the zone, %d asked for their colour)"):format(skillReads, #list, asks))
        assert(restAsked <= within, ("one look asked %d nodes whether they rest, %d are within the radius"):format(restAsked, within))
        local info = ns.QuestLook()
        assert(info.nodes == #list and info.near > 0 and info.near <= within and info.rings == ringCount,
            ("what the look says about itself: %d nodes, %d near, %d rings"):format(info.nodes, info.near, info.rings))

        -- ---- /gcr debug: how long a look took, a line now and then
        local lines = {}
        ns.Debug = function(text) if tostring(text):find("^QUEST ") then lines[#lines + 1] = text end end
        ns.db.debug = false
        advance(6)
        assert(#lines == 0, "a line about the look without /gcr debug")
        ns.db.debug = true
        for _ = 1, 8 do ns.UpdateQuestRings() end
        assert(#lines == 1, ("8 looks in a row wrote %d lines, want one"):format(#lines))
        local ms, nodes, near, rings = lines[1]:match("^QUEST look ([%d%.]+) ms: (%d+) nodes in the zone, (%d+) near, (%d+) rings$")
        assert(ms and tonumber(nodes) == #list and tonumber(near) == info.near and tonumber(rings) == info.rings, "the line about the look: " .. tostring(lines[1]))
        advance(21) -- (about ten looks: one every 2 s)
        assert(#lines >= 3 and #lines <= 6, ("21 s wrote %d lines, want one about every 5 s"):format(#lines))
    end)
    ns.SetQuestMode(false)
    ns.GatherProfessions, ns.GetSkill, ns.IsOnCooldown, issecretvalue, ns.Debug = keep.gp, keep.skill, keep.cool, keep.secret, keep.say
    ns.db.chestsHidden, ns.db.hideGreyNodes, ns.db.questRadius, ns.db.questArrow, ns.db.debug = keep.chests, keep.grey, keep.radius, keep.arrow, keep.debug
    ns.db.nodes[Z] = keep.nodes
    player.map, player.x, player.y = keep.map, keep.x, keep.y
    fire("ZONE_CHANGED_NEW_AREA") advance(1)
    ns.NotifyNodesChanged() advance(1)
    if not ok then error(err, 0) end
end)
step("Questing mode: one ring per place, and none while something of its kind rests there (v0.1.21 T1)", function()
    -- Sven, 10.11.2026, Hillsbrad 57.0 / 8.5: Copper, Tin and Silver Vein are
    -- three entries at the very same spot (the starter data has one per sort
    -- a spawn point can hold). The tin was mined: only the tin entry rested,
    -- copper and silver there still counted - the gold ring stayed on a vein
    -- that was gone. For the rings, entries of one kind at one place are ONE
    -- place now. Nothing is written to the nodes for it.
    -- map 5000 x 3333 yd in the mock: 0.001 in x is 5 yd
    local Z, H = 1460, 1424
    local keep = { nodes = ns.db.nodes[Z], hills = ns.db.nodes[H], chests = ns.db.chestsHidden, grey = ns.db.hideGreyNodes, radius = ns.db.questRadius,
        arrow = ns.db.questArrow, gp = ns.GatherProfessions, skill = ns.GetSkill, map = player.map, x = player.x, y = player.y }
    local px, py = 0.5, 0.5
    local function At(yd, name, kind, extra)
        local n = { id = "o9" .. math.random(100000, 999999), name = name, type = kind, x = px + yd / 5000, y = py, count = 1, last = 1, hits = 1 }
        for k, v in pairs(extra or {}) do n[k] = v end
        table.insert(ns.db.nodes[Z], n)
        return n
    end
    local function Rings(among)
        ns.UpdateQuestRings()
        local lit, count = ns.QuestRings(), 0
        for _, n in ipairs(among) do if lit[n] then count = count + 1 end end
        return count
    end
    local ok, err = pcall(function()
        ns.SetQuestMode(false)
        ns.db.nodes[Z] = {}
        ns.db.chestsHidden, ns.db.hideGreyNodes, ns.db.questRadius, ns.db.questArrow = nil, nil, 75, true
        ns.GatherProfessions = function() return true, true, true end
        ns.GetSkill = function(kind) if kind == "ore" then return 70, 75, 70 elseif kind == "herb" then return 60, 75, 60 end end
        -- three sorts at one place, 20 yd away: copper (1) and tin (65) you
        -- can mine at 70, silver (75) not
        local copper = At(20, "Copper Vein", "ore")
        local tin = At(20, "Tin Vein", "ore")
        local silver = At(20, "Silver Vein", "ore")
        local vein = { copper, tin, silver }
        -- further out, another place of its own
        local far = At(60, "Copper Vein", "ore")
        player.map, player.x, player.y = Z, px, py
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
        ns.NotifyNodesChanged() advance(1)
        ns.SetQuestMode(true) advance(1)
        local lit = ns.QuestRings()
        -- nothing mined: one ring for the place, on a sort you can mine
        assert(Rings(vein) == 1, ("three sorts at one place: %d rings, want one"):format(Rings(vein)))
        assert(lit[copper] and not lit[silver], "the ring of the place is not on a sort you can mine")
        assert(lit[far], "test setup: the other place")
        assert(ns.QuestArrowNode() == copper, "the arrow does not point at the place 20 yd away")
        -- the tin is mined (the recorder puts THAT entry to rest): the whole
        -- place has no ring, and the arrow goes on to the next one
        local before = {}
        for _, n in ipairs(vein) do before[n] = { n.emptyUntil, n.parked, n.source, n.hits, n.x, n.y, n.count, n.last } end
        tin.emptyUntil = time() + 600
        before[tin][1] = tin.emptyUntil
        assert(Rings(vein) == 0, ("the tin is mined: the place still has %d ring(s)"):format(Rings(vein)))
        assert(lit[far] and ns.QuestArrowNode() == far, "the arrow still points at a place where the vein is gone")
        -- ... and nothing was written to its neighbours for that
        for _, n in ipairs(vein) do
            local b = before[n]
            assert(n.emptyUntil == b[1] and n.parked == b[2] and n.source == b[3] and n.hits == b[4] and n.x == b[5] and n.y == b[6] and n.count == b[7] and n.last == b[8],
                "the questing mode wrote to a node: " .. n.name)
        end
        assert(ns.IsOnCooldown(tin) and not ns.IsOnCooldown(copper) and not ns.IsOnCooldown(silver), "a rest time was put on a neighbour")
        -- the rest is over: the ring is back
        tin.emptyUntil = time() - 1
        assert(Rings(vein) == 1 and ns.QuestArrowNode() == copper, "the ring does not come back when the rest is over")
        -- the sort you cannot mine rests: still the whole place
        silver.emptyUntil = time() + 600
        assert(Rings(vein) == 0, "the silver rests (a sort you cannot mine): the place keeps its ring")
        silver.emptyUntil = nil
        -- a parked entry at the place: no ring either
        tin.parked, tin.source, tin.hits = true, "sync", 0
        assert(ns.IsParked(tin) and Rings(vein) == 0, "a parked entry at the place: the place keeps its ring")
        tin.parked, tin.source, tin.hits = nil, nil, 1
        assert(Rings(vein) == 1, "test setup: the place again")
        -- only sorts you cannot mine at a place: no ring
        local onlyHigh = { At(-30, "Silver Vein", "ore"), At(-30, "Gold Vein", "ore") }
        assert(Rings(onlyHigh) == 0, "a place with only sorts you cannot mine has a ring")
        -- the first sort you cannot, the second you can: the ring is on the second
        local mixed = { At(-45, "Silver Vein", "ore"), At(-45, "Tin Vein", "ore") }
        assert(Rings(mixed) == 1 and lit[mixed[2]], "a place whose first entry you cannot mine gets no ring from the second")
        -- other kinds at the same spot are places of their own: a herb next
        -- to the vein keeps its ring while the vein rests, and the other way
        local herb = At(20, "Mageroyal", "herb")
        tin.emptyUntil = time() + 600
        assert(Rings(vein) == 0 and Rings({ herb }) == 1, "a resting vein takes the ring of a herb at the same spot")
        tin.emptyUntil = nil
        herb.emptyUntil = time() + 600
        assert(Rings(vein) == 1 and Rings({ herb }) == 0, "a resting herb takes the ring of a vein at the same spot")
        herb.emptyUntil = nil
        -- chests: two entries at one spot are one place too
        local chests = { At(35, "Battered Chest", "chest"), At(35, "Solid Chest", "chest") }
        assert(Rings(chests) == 1, ("two chests at one spot: %d rings"):format(Rings(chests)))
        chests[2].emptyUntil = time() + 600
        assert(Rings(chests) == 0, "one chest of the spot was opened: the spot keeps its ring")
        chests[2].emptyUntil = nil
        -- how close is one place: 8 yd apart is one (the recorder's own rule
        -- for "the same node"), 12 and 20 yd apart are two
        local eight = { At(-60, "Copper Vein", "ore"), At(-52, "Tin Vein", "ore") }
        local twelve = { At(-10, "Copper Vein", "ore"), At(2, "Tin Vein", "ore") }
        local twenty = { At(40, "Copper Vein", "ore"), At(40, "Tin Vein", "ore", { y = py + 20 / 3333 }) }
        assert(Rings(eight) == 1, ("8 yd apart: %d rings, want one"):format(Rings(eight)))
        assert(Rings(twelve) == 2, ("12 yd apart: %d rings, want two"):format(Rings(twelve)))
        assert(Rings(twenty) == 2, ("20 yd apart: %d rings, want two"):format(Rings(twenty)))
        twelve[1].emptyUntil = time() + 600
        assert(Rings(twelve) == 1 and lit[twelve[2]], "a resting vein 12 yd away takes the ring of the next place")
        twelve[1].emptyUntil = nil

        -- ---- Sven's place: the shipped spawn points of Hillsbrad
        local hills = QuestieZoneNodes(H)
        local spot = {}
        for _, n in ipairs(hills) do
            if math.abs(n.x - 0.57) < 0.0006 and math.abs(n.y - 0.085) < 0.0006 and n.type == "ore" then spot[#spot + 1] = n end
        end
        local names = {}
        for _, n in ipairs(spot) do names[#names + 1] = n.name end
        table.sort(names)
        assert(table.concat(names, ", ") == "Copper Vein, Silver Vein, Tin Vein", "test setup: at 57.0 / 8.5 the data has " .. table.concat(names, ", "))
        ns.db.nodes[H] = hills
        player.map, player.x, player.y = H, 0.5702, 0.0852
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
        ns.NotifyNodesChanged() advance(1)
        assert(Rings(spot) == 1, ("Hillsbrad 57.0 / 8.5, nothing mined: %d rings"):format(Rings(spot)))
        for _, n in ipairs(spot) do if n.name == "Tin Vein" then n.emptyUntil = time() + 600 end end
        assert(Rings(spot) == 0, ("Hillsbrad 57.0 / 8.5, the tin mined: %d ring(s) stay"):format(Rings(spot)))
        -- the whole zone: no place has two rings
        ns.db.questRadius = 100
        for _, pos in ipairs({ { 0.5702, 0.0852 }, { 0.3, 0.4 }, { 0.62, 0.2 }, { 0.45, 0.72 } }) do
            player.x, player.y = pos[1], pos[2]
            ns.UpdateQuestRings()
            local carriers = {}
            for n in pairs(ns.QuestRings()) do carriers[#carriers + 1] = n end
            for i = 1, #carriers do
                for j = i + 1, #carriers do
                    local a, b = carriers[i], carriers[j]
                    assert(a.type ~= b.type or ns.Distance(H, a.x, a.y, b.x, b.y) > 10, ("two rings at one place: %s and %s"):format(a.name, b.name))
                end
            end
        end
        -- a look at the full zone stays quick (the mock's clock: a rough bound only)
        local t0 = os.clock()
        for _ = 1, 20 do ns.UpdateQuestRings() end
        local ms = (os.clock() - t0) * 1000 / 20
        assert(ms < 25, ("one look at %d nodes takes %.1f ms"):format(#hills, ms))
    end)
    ns.SetQuestMode(false)
    ns.GatherProfessions, ns.GetSkill = keep.gp, keep.skill
    ns.db.chestsHidden, ns.db.hideGreyNodes, ns.db.questRadius, ns.db.questArrow = keep.chests, keep.grey, keep.radius, keep.arrow
    ns.db.nodes[Z], ns.db.nodes[H] = keep.nodes, keep.hills
    player.map, player.x, player.y = keep.map, keep.x, keep.y
    fire("ZONE_CHANGED_NEW_AREA") advance(1)
    ns.NotifyNodesChanged() advance(1)
    if not ok then error(err, 0) end
end)
step("Minimap tooltip: a frame that covers the whole minimap counts as the minimap, a pin does not (v0.1.21 T2)", function()
    -- Sven, 10.11.2026, with Ellesmere UI: the game's tooltip showed "Tin
    -- Vein", Gathercraft said "minimap tooltip [UIParent, ignored]". Under the
    -- mouse was not the minimap but a nameless frame, a child of it, 255 x 256
    -- - like the minimap itself. Such a frame counts as the minimap now, for
    -- the tooltip of ours below the game's AND for learning by pointing (one
    -- check for both). A pin on the minimap does not, as before.
    local Z = 1466
    local names = GathercraftNodeNames and GathercraftNodeNames[GetLocale()]
    local herbName = names and names[1618] or "Peacebloom"
    local keep = { nodes = ns.db.nodes[Z], map = player.map, x = player.x, y = player.y, foci = GetMouseFoci, focus = GetMouseFocus, cursor = GetCursorPosition,
        cvar = GetCVar, secret = issecretvalue, learnOff = ns.db.minimapLearnOff }
    local mm, gt = {}, {}
    for _, k in ipairs({ "IsMouseOver", "GetCenter", "GetWidth", "GetHeight", "GetZoom", "GetEffectiveScale" }) do mm[k] = rawget(Minimap, k) end
    for _, k in ipairs({ "IsShown", "GetOwner", "NumLines" }) do gt[k] = rawget(GameTooltip, k) end
    local texts = {}
    local ok, err = pcall(function()
        -- the minimap as Ellesmere shows it: 255 x 256, centre at 500 / 400
        local lines, owner = {}, UIParent
        Minimap.IsMouseOver = function() return true end
        Minimap.GetCenter = function() return 500, 400 end
        Minimap.GetWidth = function() return 255 end
        Minimap.GetHeight = function() return 256 end
        Minimap.GetZoom = function() return 0 end
        Minimap.GetEffectiveScale = function() return 1 end
        GameTooltip.IsShown = function() return #lines > 0 end
        GameTooltip.GetOwner = function() return owner end
        GameTooltip.NumLines = function() return #lines end
        for i = 1, 3 do
            local fs = _G["GameTooltipTextLeft" .. i] or newObject("FontString", "GameTooltipTextLeft" .. i)
            _G["GameTooltipTextLeft" .. i] = fs
            texts[i] = rawget(fs, "GetText")
            fs.GetText = function() return lines[i] end
        end
        GetCursorPosition = function() return 540, 400 end
        GetCVar = function() return "0" end
        ns.db.minimapLearnOff = nil
        player.map, player.x, player.y = Z, 0.5, 0.5
        local mapID, cx, cy = ns.CursorOnMap()
        assert(mapID == Z and cx and cy, "test setup: the cursor on the map")
        -- a herb we know, right under the cursor, resting: pointing at it
        -- marks it as up (learning) and shows our tooltip below the game's
        local herb = { id = "o1618", name = herbName, type = "herb", x = cx, y = cy, count = 1, last = 1, source = "questie" }
        ns.db.nodes[Z] = { herb }
        ns.NotifyNodesChanged() advance(1)
        local tip
        -- what is under the mouse -> learned, our tooltip shown
        local function Point(focus)
            lines = {}
            advance(6) -- (the same name at the same place counts again after 5 s)
            herb.seenAt, herb.upAt, herb.emptyUntil = nil, nil, time() + 600
            if focus == "none" then
                GetMouseFoci, GetMouseFocus = nil, nil
            else
                GetMouseFoci = function() return { focus } end
            end
            lines = { herbName }
            local fine, problem = pcall(advance, 2)
            assert(fine, "pointing at the minimap raises an error: " .. tostring(problem))
            tip = tip or _G.GathercraftMinimapTooltip
            local learned = herb.seenAt ~= nil and not herb.emptyUntil
            local shown = (tip and tip:IsShown() and tip.node == herb) and true or false
            if ns.MouseOnMinimapItself then assert(ns.MouseOnMinimapItself() == learned, "the check for the mouse and the learning disagree") end
            return learned, shown
        end
        local function Child(w, h, x, y, parent)
            local f = newObject("Frame", nil, parent or Minimap)
            f:SetSize(w, h)
            f.GetCenter = function() return x or 500, y or 400 end
            return f
        end
        local learned, shown
        -- the minimap itself, as before
        learned, shown = Point(Minimap)
        assert(learned and shown, "the minimap under the mouse: not read any more")
        -- Sven's case: a nameless child of the minimap, as big as the minimap
        local cover = Child(255, 256)
        assert(cover:GetParent() == Minimap and cover:GetName() == nil, "test setup: the frame over the minimap")
        learned, shown = Point(cover)
        assert(learned, "a frame over the whole minimap: the tooltip is ignored (nothing learned)")
        assert(shown, "a frame over the whole minimap: our tooltip does not show below the game's")
        -- a few pixels off is still "the whole minimap", also at another scale
        learned, shown = Point(Child(253, 258, 502, 399))
        assert(learned and shown, "a frame 2 px off the minimap's size and place is not taken as the minimap")
        local scaled = Child(510, 512, 1000, 800)
        scaled.GetEffectiveScale = function() return 0.5 end
        learned, shown = Point(scaled)
        assert(learned and shown, "a frame over the whole minimap at half the scale is not taken as the minimap")
        -- a pin of another addon: a small child of the minimap
        learned, shown = Point(Child(16, 16, 540, 400))
        assert(not learned and not shown, "another addon's pin under the mouse: its tooltip was read")
        -- one of our own pins - whatever its size
        local ours = Child(255, 256)
        ours.node = herb
        learned, shown = Point(ours)
        assert(not learned and not shown, "one of our own pins is taken for the minimap")
        local target = Child(255, 256)
        target.isTarget = true
        learned = Point(target)
        assert(not learned, "the run target's pin is taken for the minimap")
        -- another size, another place, another parent: not the minimap
        learned = Point(Child(200, 256))
        assert(not learned, "a child 55 px narrower than the minimap is taken for it")
        learned = Point(Child(255, 200))
        assert(not learned, "a child 56 px lower than the minimap is taken for it")
        learned = Point(Child(255, 256, 540, 400))
        assert(not learned, "a child 40 px beside the minimap's place is taken for it")
        learned = Point(Child(255, 256, 500, 400, UIParent))
        assert(not learned, "a frame as big as the minimap that is no child of it is taken for it")
        local grand = Child(255, 256, 500, 400, Child(255, 256))
        learned = Point(grand)
        assert(not learned, "a grandchild of the minimap is taken for it")
        -- things that cannot be read: not the minimap, and no error
        learned = Point({})
        assert(not learned, "a thing without a size is taken for the minimap")
        local broken = Child(255, 256)
        broken.GetWidth = function() error("no width") end
        learned = Point(broken)
        assert(not learned, "a frame whose size cannot be read is taken for the minimap")
        local SECRET = newproxy(true)
        issecretvalue = function(v) return rawequal(v, SECRET) end
        local hidden = Child(255, 256)
        hidden.GetHeight = function() return SECRET end
        learned = Point(hidden)
        assert(not learned, "a frame with a hidden size is taken for the minimap")
        issecretvalue = keep.secret
        local odd = Child(255, 256)
        odd.GetCenter = function() return nil end
        learned = Point(odd)
        assert(not learned, "a frame without a place is taken for the minimap")
        -- the client tells nothing about the mouse (neither function): as before
        learned, shown = Point("none")
        assert(learned and shown, "without GetMouseFoci / GetMouseFocus the minimap tooltip is not read any more")
        -- only the old function, with the cover under the mouse
        GetMouseFoci, GetMouseFocus = nil, function() return cover end
        lines = {}
        advance(6)
        herb.seenAt, herb.upAt, herb.emptyUntil = nil, nil, time() + 600
        lines = { herbName }
        advance(2)
        assert(herb.seenAt and not herb.emptyUntil, "the cover under the mouse, told by the old function: not read")
        -- nothing was changed on the frames we looked at
        assert(cover:GetParent() == Minimap and cover.__w == 255 and cover.__h == 256 and cover.__shown ~= false, "a frame of another addon was changed")
        lines = {}
        advance(2)
    end)
    GetMouseFoci, GetMouseFocus, GetCursorPosition, GetCVar, issecretvalue = keep.foci, keep.focus, keep.cursor, keep.cvar, keep.secret
    for _, k in ipairs({ "IsMouseOver", "GetCenter", "GetWidth", "GetHeight", "GetZoom", "GetEffectiveScale" }) do Minimap[k] = mm[k] end
    for _, k in ipairs({ "IsShown", "GetOwner", "NumLines" }) do GameTooltip[k] = gt[k] end
    for i = 1, 3 do if _G["GameTooltipTextLeft" .. i] then _G["GameTooltipTextLeft" .. i].GetText = texts[i] end end
    ns.db.nodes[Z], ns.db.minimapLearnOff = keep.nodes, keep.learnOff
    player.map, player.x, player.y = keep.map, keep.x, keep.y
    ns.NotifyNodesChanged() advance(2)
    if not ok then error(err, 0) end
end)
step("Herbs / minerals switch button: on the screen, not on the minimap; follows it; the shape can be chosen (v0.1.21 T5)", function()
    -- Sven, 10.11.2026, Ellesmere UI, square minimap: the button was shown but
    -- had an effective alpha of 0 - something that goes through the minimap's
    -- children had faded it - and with no GetMinimapShape it sat on a circle.
    -- The button is a child of the screen now, only anchored to the minimap,
    -- and the shape can be chosen in the options.
    local btn = GathercraftTrackButton
    assert(btn, "no switch button")
    local saved = { shape = _G.GetMinimapShape, w = rawget(Minimap, "GetWidth"), h = rawget(Minimap, "GetHeight"), es = rawget(Minimap, "GetEffectiveScale"),
        ues = rawget(UIParent, "GetEffectiveScale"), angle = ns.db.trackButtonAngle, combat = InCombatLockdown, known = IsPlayerSpell,
        choice = ns.db.minimapShape, hidden = ns.db.trackButtonHidden, mparent = Minimap.__parent, mshown = Minimap.__shown,
        setAlpha = rawget(btn, "SetAlpha"), setScale = rawget(btn, "SetScale") }
    local function Pos()
        local p = btn.__pts and btn.__pts.CENTER
        assert(p and p[1] == Minimap and p[2] == "CENTER", "the button is not anchored to the minimap's centre")
        return p[3], p[4]
    end
    local function Near(a, b) return math.abs(a - b) < 0.5 end
    local function Radius() local x, y = Pos() return math.sqrt(x * x + y * y) end
    local ok, err = pcall(function()
        -- not a child of the minimap, nowhere up the line
        assert(btn:GetParent() ~= Minimap, "the button is a child of the minimap")
        assert(btn:GetParent() == UIParent, "the button is not a child of the screen (UIParent)")
        for _, o in ipairs(allFrames) do
            if o.__parent == Minimap then
                assert(o ~= btn and (not o.GetName or o:GetName() ~= "GathercraftTrackButton"), "the minimap has the switch button as a child")
            end
        end
        local alphas, scale = 0, nil
        btn.SetAlpha = function() alphas = alphas + 1 end
        btn.SetScale = function(_, s) scale = s end
        Minimap.GetWidth = function() return 140 end
        Minimap.GetHeight = function() return 140 end
        _G.GetMinimapShape = nil
        ns.db.minimapShape, ns.db.trackButtonAngle, ns.db.trackButtonHidden = nil, 250, nil
        IsPlayerSpell = function(id) return id == 2383 or id == 2580 or saved.known(id) end
        Minimap.__shown = true
        ns.UpdateTrackButton()
        assert(btn:IsShown(), "test setup: the button shows with both tracking spells")
        -- place, strata and level as before: on the minimap's edge, above it
        assert(Near(Radius(), 75), ("round: %.1f from the centre, want 75"):format(Radius()))
        assert(btn:GetFrameStrata() == "MEDIUM" and btn:GetFrameLevel() == Minimap:GetFrameLevel() + 8, "strata or level changed")
        -- as big as a child of the minimap would be: the minimap's scale
        assert(scale == 1, "the button's scale with minimap and screen at the same scale: " .. tostring(scale))
        Minimap.GetEffectiveScale = function() return 0.6 end
        UIParent.GetEffectiveScale = function() return 0.75 end
        ns.PlaceTrackButton()
        assert(scale and Near(scale * 100, 80), "a minimap at 0.6 on a screen at 0.75: the button's scale is " .. tostring(scale) .. ", want 0.8")
        Minimap.GetEffectiveScale = function() return nil end
        assert(pcall(ns.PlaceTrackButton) and scale == 1, "a scale that cannot be read: an error, or not 1")
        Minimap.GetEffectiveScale = function() error("no scale") end
        assert(pcall(ns.PlaceTrackButton) and scale == 1, "a scale that raises an error: an error, or not 1")
        Minimap.GetEffectiveScale, UIParent.GetEffectiveScale = saved.es, saved.ues

        -- the minimap hidden: the button goes; shown again: back
        Minimap:Hide()
        assert(not btn:IsShown(), "the minimap is hidden, the button still shows")
        Minimap:Show()
        assert(btn:IsShown(), "the minimap is back, the button is not")
        -- hidden through what the minimap sits in (its cluster)
        local cluster = newObject("Frame", nil, UIParent)
        Minimap.__parent = cluster
        cluster:Hide()
        ns.UpdateTrackButton()
        assert(not btn:IsShown(), "the minimap's parent is hidden, the button still shows")
        cluster:Show()
        ns.UpdateTrackButton()
        assert(btn:IsShown(), "the minimap's parent is back, the button is not")
        Minimap.__parent = saved.mparent
        -- in a fight nothing changes (a protected frame); the fight's end catches up
        InCombatLockdown = function() return true end
        Minimap:Hide()
        assert(btn:IsShown(), "the button was hidden in combat")
        InCombatLockdown = saved.combat
        fire("PLAYER_REGEN_ENABLED")
        assert(not btn:IsShown(), "after the fight the button still shows, the minimap is hidden")
        InCombatLockdown = function() return true end
        Minimap:Show()
        assert(not btn:IsShown(), "the button was shown in combat")
        InCombatLockdown = saved.combat
        fire("PLAYER_REGEN_ENABLED")
        assert(btn:IsShown(), "after the fight the button is not back")
        -- the option off: hidden, whatever the minimap does
        ns.db.trackButtonHidden = true
        ns.UpdateTrackButton()
        Minimap:Hide() Minimap:Show()
        assert(not btn:IsShown(), "the option is off, the button shows when the minimap comes back")
        ns.db.trackButtonHidden = nil
        ns.UpdateTrackButton()
        assert(btn:IsShown(), "the option is on again, no button")
        -- only one of the two spells known: no button when the minimap comes back
        IsPlayerSpell = saved.known
        Minimap:Hide() Minimap:Show()
        assert(not btn:IsShown(), "the button shows without both tracking spells when the minimap comes back")
        IsPlayerSpell = function(id) return id == 2383 or id == 2580 or saved.known(id) end
        ns.UpdateTrackButton()
        -- no fight against another addon: the alpha is never set
        assert(alphas == 0, "the button's alpha was set " .. alphas .. " times")

        -- the shape: Auto as before (what a UI addon tells, else round)
        local x, y
        _G.GetMinimapShape = function() return "SQUARE" end
        ns.PlaceTrackButton()
        x, y = Pos()
        assert(Near(y, -75) and math.abs(x) < 75, "Auto with a UI addon saying SQUARE: not on the rectangle's edge")
        _G.GetMinimapShape = nil
        ns.PlaceTrackButton()
        assert(Near(Radius(), 75), "Auto without a shape function: not round")
        -- Square chosen, no shape function (Sven's case): the rectangle's edge
        ns.db.minimapShape = "square"
        ns.PlaceTrackButton()
        x, y = Pos()
        assert(Near(y, -75), ("Square chosen, at 250 degrees: y %.1f, want -75 (the bottom edge)"):format(y))
        assert(Near(x / y, math.cos(math.rad(250)) / math.sin(math.rad(250))), "Square chosen: not in the direction of the angle")
        Minimap.GetWidth = function() return 255 end
        Minimap.GetHeight = function() return 256 end
        ns.db.trackButtonAngle = 180
        ns.PlaceTrackButton()
        x, y = Pos()
        assert(Near(x, -132.5) and Near(y, 0), ("Square chosen, a minimap of 255 x 256 at 180 degrees: %.1f, %.1f"):format(x, y))
        ns.db.trackButtonAngle = 45
        ns.PlaceTrackButton()
        x, y = Pos()
        assert(Near(x, 132.5) and Near(y, 132.5), ("Square chosen, 255 x 256 at 45 degrees: %.1f, %.1f"):format(x, y))
        Minimap.GetWidth = function() return 140 end
        Minimap.GetHeight = function() return 140 end
        -- Round chosen wins over a UI addon that says SQUARE
        ns.db.minimapShape = "round"
        _G.GetMinimapShape = function() return "SQUARE" end
        ns.PlaceTrackButton()
        assert(Near(Radius(), 75), "Round chosen: not on the circle")
        -- an odd saved value: Auto
        ns.db.minimapShape = "hexagon"
        ns.PlaceTrackButton()
        x, y = Pos()
        assert(Near(x, 75) and Near(y, 75), "an unknown saved shape is not taken as Auto")
        _G.GetMinimapShape = nil
        ns.db.minimapShape = nil

        -- the option: under General, next to the button's other things
        local label, less, more, value
        for _, o in ipairs(allFrames) do
            if o.GetText and o:GetText() == ns.L["Minimap shape"] then label = o end
            if o.gcShapeStep == -1 then less = o elseif o.gcShapeStep == 1 then more = o end
            if o.gcShapeValue then value = o end
        end
        assert(label and less and more and value, "no choice \"Minimap shape\" in the options")
        local p = label.__parent
        while p and not p.key do p = p.__parent end
        assert(p and p.key == "general", "the choice of the shape is not under General")
        assert(less.__parent == p and more.__parent == p, "the buttons of the choice are on another page")
        ns.db.trackButtonAngle = 45
        GathercraftOptions:Refresh() -- (as opening the options does)
        local function Shown() return value:GetText() end
        assert(Shown() == ns.L["Auto"], "the choice does not start at Auto: " .. tostring(Shown()))
        more.__scripts.OnClick(more)
        assert(ns.db.minimapShape == "round" and Shown() == ns.L["Round"], "> after Auto is not Round")
        assert(Near(Radius(), 75), "Round picked: the button did not move at once")
        more.__scripts.OnClick(more)
        assert(ns.db.minimapShape == "square" and Shown() == ns.L["Square"], "> after Round is not Square")
        x, y = Pos()
        assert(Near(x, 75) and Near(y, 75), "Square picked: the button did not move to the corner at once")
        more.__scripts.OnClick(more)
        assert(ns.db.minimapShape == nil and Shown() == ns.L["Auto"], "> after Square is not Auto (nothing saved)")
        less.__scripts.OnClick(less)
        assert(ns.db.minimapShape == "square", "< before Auto is not Square")
        less.__scripts.OnClick(less)
        less.__scripts.OnClick(less)
        assert(ns.db.minimapShape == nil, "< twice more is not Auto")
        -- in a fight the choice is saved, the button moves after it
        InCombatLockdown = function() return true end
        more.__scripts.OnClick(more) more.__scripts.OnClick(more)
        assert(ns.db.minimapShape == "square" and Near(Radius(), 75), "picked in combat: not saved, or the button moved")
        InCombatLockdown = saved.combat
        fire("PLAYER_REGEN_ENABLED")
        x, y = Pos()
        assert(Near(x, 75) and Near(y, 75), "picked in combat: not placed after the fight")
        assert(pcall(more.__scripts.OnEnter, more), "the tooltip of the choice")
        -- the page still fits
        local used = ns.OptionsUsedHeight()
        assert(used.general <= 640 - 112 - 18 - 4 - 66, "Options, General: " .. tostring(used.general) .. " px, too long")
        -- shift-drag still saves the angle
        local realShift, realCursor = IsShiftKeyDown, GetCursorPosition
        IsShiftKeyDown = function() return true end
        GetCursorPosition = function() return 400, 300 end
        ns.db.trackButtonAngle = nil
        btn.__scripts.OnDragStart(btn)
        assert(btn.__scripts.OnUpdate and pcall(btn.__scripts.OnUpdate, btn, 0.1), "dragging does not follow the cursor")
        btn.__scripts.OnDragStop(btn)
        IsShiftKeyDown, GetCursorPosition = realShift, realCursor
        assert(ns.db.trackButtonAngle, "dragging did not save the angle")
        assert(alphas == 0, "the button's alpha was set")
    end)
    _G.GetMinimapShape, InCombatLockdown, IsPlayerSpell = saved.shape, saved.combat, saved.known
    Minimap.GetWidth, Minimap.GetHeight, Minimap.GetEffectiveScale, UIParent.GetEffectiveScale = saved.w, saved.h, saved.es, saved.ues
    Minimap.__parent, Minimap.__shown = saved.mparent, saved.mshown
    btn.SetAlpha, btn.SetScale = saved.setAlpha, saved.setScale
    ns.db.trackButtonAngle, ns.db.minimapShape, ns.db.trackButtonHidden = saved.angle, saved.choice, saved.hidden
    ns.UpdateTrackButton()
    GathercraftOptions:Refresh()
    if not ok then error(err, 0) end
end)
step("Questing mode: in \"Ring only\" the rings are the thin gold ring, the run target stays broad (v0.1.21 T6)", function()
    -- Sven, 10.11.2026 23:11, about the questing mode's ring: "der ist mords
    -- dick". In the minimap style "Ring only" its rings took the run target's
    -- broad ring (RingGoldBold: the wall is 22 % of the texture). They take
    -- the thin one now (RingGold: 14 %), at the same size - the middle, where
    -- the game's yellow dot shows, gets wider. The run target is as it was.
    -- map 5000 x 3333 yd in the mock: 0.001 in x is 5 yd
    local Z = 1460
    local keep = { nodes = ns.db.nodes[Z], style = ns.db.miniPinStyle, size = ns.db.pinSize, chests = ns.db.chestsHidden,
        gp = ns.GatherProfessions, map = player.map, x = player.x, y = player.y }
    local px, py = 0.5, 0.5
    local function At(yd, name, kind)
        local n = { id = "o9" .. math.random(100000, 999999), name = name, type = kind, x = px + yd / 5000, y = py, count = 1, last = 1, hits = 1 }
        table.insert(ns.db.nodes[Z], n)
        return n
    end
    local function Tex(pin) return tostring(pin.ring and pin.ring.__tex or "") end
    local ok, err = pcall(function()
        ns.SetQuestMode(false)
        ns.db.nodes[Z] = {}
        local herb, ore, chest = At(20, "Peacebloom", "herb"), At(40, "Copper Vein", "ore"), At(-30, "Battered Chest", "chest")
        local far = At(60, "Silverleaf", "herb")
        player.map, player.x, player.y = Z, px, py
        fire("ZONE_CHANGED_NEW_AREA") advance(1)
        ns.db.miniPinStyle, ns.db.chestsHidden, ns.db.pinSize = nil, nil, nil -- ring only, chests shown
        ns.GatherProfessions = function() return true, true, true end
        ns.NotifyNodesChanged() advance(1)
        ns.SetQuestMode(true) advance(1)
        local function Rings()
            local list = {}
            for _, n in ipairs({ herb, ore, chest, far }) do
                local pin = ns.QuestRings()[n]
                assert(pin, "test setup: " .. n.name .. " has no ring")
                list[#list + 1] = pin
            end
            return list
        end
        -- the run target in a style: size, icon shown, texture
        local function TargetLook()
            ns.SetRouteTarget(Z, herb)
            local _, mini = ns.RouteTargetPins()
            local w, shown, tex = mini.__w, mini.icon.__shown ~= false, Tex(mini)
            ns.ClearRouteTarget()
            return w, shown, tex
        end
        -- ring only: every ring thin, no icon, as big as the run target
        local tw, tshown, ttex = TargetLook()
        assert(ttex:find("RingGoldBold$") and not tshown, "ring only: the run target is no longer the broad gold ring without an icon (" .. ttex .. ")")
        for _, pin in ipairs(Rings()) do
            assert(Tex(pin):find("RingGold$"), "ring only: the ring of " .. pin.node.name .. " is not the thin gold ring (" .. Tex(pin) .. ")")
            assert(pin.icon.__shown == false, "ring only: the ring of " .. pin.node.name .. " shows an icon")
            assert(pin.ring:IsShown(), "ring only: no ring texture shown")
            assert(pin.__w == tw and pin.__h == tw, ("ring only: the ring is %s px, the run target %s px"):format(tostring(pin.__w), tostring(tw)))
        end
        -- the style changes while the mode is on: every ring takes the new look
        for _, style in ipairs({ "subtle", "normal" }) do
            ns.db.miniPinStyle = style
            ns.NotifyNodesChanged() advance(1)
            tw, tshown, ttex = TargetLook()
            ns.NotifyNodesChanged() advance(1)
            assert(ttex:find("RingGold$") and tshown, style .. ": test setup, the run target is the icon in a thin gold ring")
            for _, pin in ipairs(Rings()) do
                assert(Tex(pin) == ttex and pin.__w == tw and pin.icon.__shown ~= false,
                    ("%s: the ring of %s is %s, %s px, icon %s - not the run target's look"):format(style, pin.node.name, Tex(pin), tostring(pin.__w), tostring(pin.icon.__shown ~= false)))
            end
        end
        -- and back to ring only: thin again, the icons gone again (pins are reused)
        ns.db.miniPinStyle = nil
        ns.NotifyNodesChanged() advance(1)
        tw = TargetLook()
        ns.NotifyNodesChanged() advance(1)
        for _, pin in ipairs(Rings()) do
            assert(Tex(pin):find("RingGold$") and pin.icon.__shown == false and pin.__w == tw, "back to ring only: the ring of " .. pin.node.name .. " kept the other style's look")
        end
        -- another pin size: the rings follow, still thin
        ns.db.pinSize = 20
        ns.NotifyNodesChanged() advance(1)
        local big = TargetLook()
        ns.NotifyNodesChanged() advance(1)
        assert(big > tw, "test setup: a bigger pin size gives a bigger target")
        for _, pin in ipairs(Rings()) do
            assert(Tex(pin):find("RingGold$") and pin.__w == big, "pin size 20: the ring of " .. pin.node.name .. " did not follow")
        end
        ns.db.pinSize = nil
        ns.NotifyNodesChanged() advance(1)
        -- a ring lit later (walking up to it) is thin too; one that went and came back as well
        ns.SetQuestMode(false) advance(1)
        ns.SetQuestMode(true) advance(1)
        for _, pin in ipairs(Rings()) do
            assert(Tex(pin):find("RingGold$") and pin.icon.__shown == false, "lit anew: the ring of " .. pin.node.name .. " is not thin")
        end
        -- the run target next to the rings: still the broad one
        ns.SetRouteTarget(Z, herb)
        local _, mini = ns.RouteTargetPins()
        assert(Tex(mini):find("RingGoldBold$") and mini.icon.__shown == false, "the run target lost its broad ring")
        ns.ClearRouteTarget()
    end)
    ns.SetQuestMode(false)
    ns.GatherProfessions = keep.gp
    ns.db.nodes[Z], ns.db.miniPinStyle, ns.db.pinSize, ns.db.chestsHidden = keep.nodes, keep.style, keep.size, keep.chests
    player.map, player.x, player.y = keep.map, keep.x, keep.y
    fire("ZONE_CHANGED_NEW_AREA") advance(1)
    ns.NotifyNodesChanged() advance(1)
    if not ok then error(err, 0) end
end)
step("Craft log: Create All ended by an aborted cast keeps its block; the header counts finished crafts (v0.1.21 T7)", function()
    -- Sven, 11.11.2026 19:05, 0.1.20: 3 crafts alone (quickly: a series, 3/3),
    -- then Create All, ended by moving after 5 successes - the usual way to
    -- end it. The log said "1 series, 3 crafts", "1 failed or interrupted",
    -- 5 overlapping, and the header counted the aborted cast as a craft.
    local data = GathercraftRecipeData
    local spell, other = data.spells.Leatherworking["Light Leather"], data.spells.Leatherworking["Light Armor Kit"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], colors2 = data.colors[other],
        log = ns.db.craftLog, off = ns.db.craftLogOff, multi = ns.db.craftMulti, secret = issecretvalue }
    local SECRET = newproxy(true)
    local rank, maxRank = 10, 75
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, maxRank end end
    ns.CraftData.Have = function() return 0 end
    data.colors[spell], data.colors[other] = "25:45", "25:45" -- orange below 25, yellow below 45, grey from 45
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = {}, nil, nil
    local n = 0
    local function Guid() n = n + 1 return "Cast-t7-" .. n end
    local function Start(sp) local g = Guid() fire("UNIT_SPELLCAST_START", "player", g, sp or spell) return g end
    local function Ok(g, gain, sp) rank = rank + (gain or 0) fire("UNIT_SPELLCAST_SUCCEEDED", "player", g, sp or spell) end
    local function Abort(g, how, sp) fire(how or "UNIT_SPELLCAST_INTERRUPTED", "player", g, sp or spell) end
    -- Create All: every cast takes castTime, the next starts the moment the
    -- last succeeded; returns the cast that is running at the end
    local function CreateAll(gains, castTime)
        local g = Start()
        for _, gain in ipairs(gains) do
            advance(castTime or 3)
            Ok(g, gain)
            g = Start()
        end
        return g
    end
    local function Blocks()
        local list = {}
        for _, e in ipairs(ns.db.craftLog) do if e.kind == "series" then list[#list + 1] = e end end
        return list
    end
    local function Reset(skill) advance(3) ns.db.craftLog, ns.db.craftMulti = {}, nil rank = skill advance(3) end
    local function Text()
        local mark = #log
        slash("craftlog")
        return table.concat(log, "\n", mark + 1)
    end
    local function Says(count) return (ns.L["Craft log: %d crafts (kept on this computer, never shared)."]):format(count) end
    local function NotCounted(failed, unreadable, overlap, cap, multi)
        return (ns.L["  Not counted: %d failed or interrupted, %d unreadable, %d overlapping, %d at the rank's maximum; %d gave more than one point."]):format(failed, unreadable, overlap, cap, multi)
    end
    local ok, err = pcall(function()
        advance(3)
        -- (1) Sven's case: 3 quickly one after the other, then Create All:
        -- 5 successes, the sixth cast ended by moving
        for _ = 1, 3 do Ok(Start(), 1) advance(0.3) end
        advance(3)
        local g = CreateAll({ 1, 1, 1, 1, 1 })
        advance(1)
        Abort(g)
        advance(3)
        local blocks = Blocks()
        assert(#blocks == 2, "Sven's case: " .. #blocks .. " blocks, want the 3 and the 5")
        local b = blocks[2]
        assert(b.n == 5 and b.before == 13 and b.after == 18 and b.gain == 5 and b.colour == "orange",
            ("the block of Create All: n %s, %s -> %s, gain %s, %s"):format(tostring(b.n), tostring(b.before), tostring(b.after), tostring(b.gain), tostring(b.colour)))
        local byColour, _, others = ns.CraftLogSummary()
        assert(others.series == 2 and others.seriesTries == 8 and others.seriesUps == 8, "the series line: " .. others.series .. " series, " .. others.seriesTries .. " crafts")
        assert(others.failed == 1 and others.overlap == 0, ("%d failed, %d overlapping - want 1 and 0"):format(others.failed, others.overlap))
        assert(byColour.orange.tries == 8 and byColour.orange.ups == 8, "orange: " .. byColour.orange.ups .. "/" .. byColour.orange.tries)
        local text = Text()
        assert(text:find(Says(8), 1, true), "the header does not say 8 crafts (the aborted cast is none): " .. text:sub(1, 90))
        assert(text:find(NotCounted(1, 0, 0, 0, 0), 1, true), "not counted: " .. text)
        -- the aborted cast is in the log, as it was: outside the block
        local aborted
        for _, e in ipairs(ns.db.craftLog) do if e.result == "interrupted" then aborted = e end end
        assert(aborted and not aborted.inSeries and not aborted.kind, "the aborted cast is not in the log as interrupted")

        -- (2) the abort comes while the last success is still being read
        -- (within 1.5 s), and the client tells it twice (interrupted, failed)
        Reset(31) -- (31 -> 34: 14 to 11 below grey, one distance group)
        g = CreateAll({ 1, 0, 1, 1, 0 })
        advance(0.4)
        Abort(g) Abort(g, "UNIT_SPELLCAST_FAILED")
        advance(3)
        blocks = Blocks()
        assert(#blocks == 1 and blocks[1].n == 5 and blocks[1].gain == 3 and blocks[1].before == 31 and blocks[1].after == 34 and blocks[1].colour == "yellow",
            "an abort 0.4 s after the last success: no block of 5 with 3 points")
        byColour, _, others = ns.CraftLogSummary()
        assert(others.failed == 1 and others.overlap == 0 and byColour.yellow.tries == 5 and byColour.yellow.ups == 3, "yellow 3/5 and one failed")
        assert(Text():find(Says(5), 1, true), "the header after 5 crafts and an abort")

        -- (3) a cast that fails (not interrupted) at the end: the same
        Reset(10)
        g = CreateAll({ 1, 1 })
        advance(2)
        Abort(g, "UNIT_SPELLCAST_FAILED")
        advance(3)
        assert(#Blocks() == 1 and Blocks()[1].n == 2 and select(3, ns.CraftLogSummary()).failed == 1, "a failed cast at the end: no block of 2")

        -- (4) a failure that never started (no START of its own), at the end
        Reset(10)
        Ok(Start(), 1) advance(0.3)
        Ok(Start(), 1) advance(0.3)
        Ok(Start(), 1) advance(0.3)
        Abort(Guid(), "UNIT_SPELLCAST_FAILED")
        advance(3)
        assert(#Blocks() == 1 and Blocks()[1].n == 3 and Blocks()[1].gain == 3, "a failure without a start at the end: no block of 3")
        assert(select(3, ns.CraftLogSummary()).failed == 1, "the failure without a start is not in the log")

        -- (5) two aborted attempts after the last success: still the block
        Reset(10)
        g = CreateAll({ 1, 1, 1 }, 0.3)
        Abort(g)
        advance(0.2)
        g = Start()
        advance(0.2)
        Abort(g)
        advance(3)
        assert(#Blocks() == 1 and Blocks()[1].n == 3, "two aborted casts at the end: no block of 3")
        assert(select(3, ns.CraftLogSummary()).failed == 2, "two aborted casts: not 2 failed")

        -- (6) an abort in the middle - a success of the same series after it:
        -- everything stays overlapping, as before
        Reset(10)
        Ok(Start(), 1) advance(0.3)
        Ok(Start(), 1) advance(0.3)
        g = Start() advance(0.2) Abort(g) advance(0.2)
        Ok(Start(), 1) advance(0.3)
        Ok(Start(), 1) advance(3)
        byColour, _, others = ns.CraftLogSummary()
        assert(#Blocks() == 0 and others.overlap == 4 and others.failed == 1 and not byColour.orange,
            ("an abort in the middle: %d blocks, %d overlapping, %d failed"):format(#Blocks(), others.overlap, others.failed))
        assert(Text():find(Says(4), 1, true), "the header: 4 overlapping crafts are crafts, the aborted cast is none")
        -- a failure without a start in the middle: the same
        Reset(10)
        Ok(Start(), 1) advance(0.3)
        Ok(Start(), 1) advance(0.3)
        Abort(Guid(), "UNIT_SPELLCAST_FAILED") advance(0.2)
        Ok(Start(), 1) advance(3)
        byColour, _, others = ns.CraftLogSummary()
        assert(#Blocks() == 0 and others.overlap == 3 and others.failed == 1 and not byColour.orange, "a failure without a start in the middle: counted")

        -- (7) an abort as the only cast: only "failed", no craft
        Reset(10)
        g = Start() advance(1) Abort(g) advance(3)
        byColour, _, others = ns.CraftLogSummary()
        assert(#ns.db.craftLog == 1 and others.failed == 1 and others.overlap == 0 and not next(byColour), "an abort alone")
        assert(Text():find(Says(0), 1, true), "an abort alone: the header does not say 0 crafts")
        -- one success and the abort of the next cast: no block of one (a
        -- block needs two); the craft stays overlapping, as before
        Reset(10)
        g = CreateAll({ 1 })
        advance(1) Abort(g) advance(3)
        byColour, _, others = ns.CraftLogSummary()
        assert(#Blocks() == 0 and others.overlap == 1 and others.failed == 1, "one success and an abort")
        assert(Text():find(Says(1), 1, true), "one success and an abort: the header does not say 1 craft")

        -- (8) the other conditions of a block stay: a colour change (23 -> 27)
        Reset(23)
        g = CreateAll({ 1, 1, 1, 1 })
        advance(1) Abort(g) advance(3)
        assert(#Blocks() == 0 and select(3, ns.CraftLogSummary()).overlap == 4, "aborted at the end, over a colour change: a block")
        -- at the rank's maximum
        Reset(73)
        g = CreateAll({ 1, 1, 0 })
        advance(1) Abort(g) advance(3)
        assert(#Blocks() == 0, "aborted at the end, at the maximum: a block")
        -- more points than crafts
        Reset(10)
        g = CreateAll({ 2, 2 })
        advance(2) Abort(g) advance(3)
        assert(#Blocks() == 0, "aborted at the end, more points than crafts: a block")
        -- a hidden skill inside
        Reset(10)
        g = Start() advance(3) Ok(g, 1)
        issecretvalue = function(v) return rawequal(v, SECRET) end
        local keepRank = rank
        rank = SECRET
        g = Start()
        rank = keepRank
        issecretvalue = saved.secret
        advance(3) Ok(g, 1)
        g = Start() advance(1) Abort(g) advance(3)
        assert(#Blocks() == 0, "aborted at the end, a hidden skill inside: a block")
        -- the note that a craft of this profession gave more than one point
        Reset(10)
        ns.db.craftMulti = { Leatherworking = true }
        g = CreateAll({ 1, 1, 1 })
        advance(1) Abort(g) advance(3)
        assert(#Blocks() == 0 and select(3, ns.CraftLogSummary()).overlap == 3, "aborted at the end, with the note of a multi-point craft: a block")
        -- another recipe started while the last success is being read
        Reset(10)
        g = CreateAll({ 1, 1 }, 0.3)
        Abort(g)
        Ok(Start(other), 1, other) advance(3)
        assert(#Blocks() == 0, "aborted, then another recipe inside the last reading: a block")

        -- (9) the switch (a hard break) is as it was: off while the series runs - no block
        Reset(10)
        g = CreateAll({ 1, 1, 1 })
        advance(0.4)
        ns.db.craftLogOff = true
        ns.CraftLogBreak()
        Abort(g)
        ns.db.craftLogOff = nil
        ns.CraftLogBreak()
        advance(3)
        assert(#Blocks() == 0, "switched off before the abort: a block")
        -- cleared between the last success and the abort: nothing of it comes back
        Reset(10)
        g = CreateAll({ 1, 1, 1 })
        advance(0.4)
        slash("craftlog clear")
        Abort(g)
        advance(3)
        assert(#ns.db.craftLog == 0, "cleared before the abort: " .. #ns.db.craftLog .. " entries came back")

        -- (10) after the abort, once everything is read, the next Create All
        -- is a series of its own
        Reset(10)
        g = CreateAll({ 1, 1, 1 })
        advance(2) Abort(g)
        g = CreateAll({ 1, 1 })
        advance(1) Abort(g) advance(3)
        blocks = Blocks()
        assert(#blocks == 2 and blocks[1].n == 3 and blocks[1].before == 10 and blocks[1].after == 13 and blocks[2].n == 2 and blocks[2].before == 13 and blocks[2].after == 15,
            "two Create All, each ended by an abort: not a block of 3 and one of 2")
        assert(Text():find(Says(5), 1, true), "two aborted Create All: the header does not say 5 crafts")

        -- (11) the header: a failed cast is no craft, a block stands for its
        -- crafts, old entries count as before
        ns.db.craftLog = {
            { t = 1, result = "failed", prof = "Leatherworking", spell = spell, colour = "orange", before = 5 },
            { t = 2, result = "interrupted", prof = "Leatherworking", spell = spell, colour = "orange", before = 5 },
            { t = 3, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 12, after = 13, gain = 1, overlap = true, inSeries = true },
            { kind = "series", t = 1, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", n = 7, before = 6, after = 13, gain = 7, yellow = 25, grey = 45, max = 75 },
            { t = 9, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 13, after = 14, gain = 1, yellow = 25, grey = 45, max = 75 },
            { t = 10, result = "ok", prof = "Leatherworking", spell = spell, colour = "unknown", secret = true },
            { t = 11, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 14, after = 15, gain = 1, overlap = true },
        }
        assert(ns.CraftLogCrafts() == 10, "the header's count: " .. tostring(ns.CraftLogCrafts()) .. ", want 7 + 1 + 1 + 1")
        text = Text()
        assert(text:find(Says(10), 1, true) and text:find(NotCounted(2, 1, 1, 0, 0), 1, true), "the header and the line of what is not counted: " .. text)
    end)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell], data.colors[other] = saved.rank, saved.have, saved.colors, saved.colors2
    ns.db.craftLogOff, issecretvalue = saved.off, saved.secret
    advance(3)
    ns.db.craftLog, ns.db.craftMulti = saved.log, saved.multi
    advance(3)
    if not ok then error(err, 0) end
end)
step("Craft log: a craft without a reliable \"before\" is no proof of a multi-point craft and in no rate (v0.1.21 T8)", function()
    -- Sven, 11.11.2026 19:10, 0.1.20: during Create All (Cooking) recording
    -- switched off and on again for a craft or two. After that: "Series of
    -- Cooking are not counted: a craft there gave more than one point." The
    -- chat showed exactly +1 after every "You create".
    local data = GathercraftRecipeData
    local spell, other = data.spells.Leatherworking["Light Leather"], data.spells.Leatherworking["Light Armor Kit"]
    local saved = { rank = ns.ProfessionRank, have = ns.CraftData.Have, colors = data.colors[spell], colors2 = data.colors[other],
        log = ns.db.craftLog, off = ns.db.craftLogOff, multi = ns.db.craftMulti, secret = issecretvalue }
    local SECRET = newproxy(true)
    local rank, maxRank = 10, 75
    ns.ProfessionRank = function(p) if p == "Leatherworking" then return rank, maxRank end end
    ns.CraftData.Have = function() return 0 end
    data.colors[spell], data.colors[other] = "25:45", "25:45" -- orange below 25
    ns.db.craftLog, ns.db.craftLogOff, ns.db.craftMulti = {}, nil, nil
    local n = 0
    local function Guid() n = n + 1 return "Cast-t8-" .. n end
    local function Start(sp) local g = Guid() fire("UNIT_SPELLCAST_START", "player", g, sp or spell) return g end
    -- the point of a craft arrives LAG seconds after its success (as in the
    -- game: later than the event)
    local LAG = 0.5
    local function Ok(g, gain, sp)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", g, sp or spell)
        if gain and gain ~= 0 then C_Timer.After(LAG, function() rank = rank + gain end) end
    end
    -- the option's switch, as Options.lua does it
    local function Switch(on)
        ns.db.craftLogOff = not on or nil
        ns.CraftLogBreak()
    end
    local function Blocks()
        local list = {}
        for _, e in ipairs(ns.db.craftLog) do if e.kind == "series" then list[#list + 1] = e end end
        return list
    end
    local function Reset(skill) advance(3) ns.db.craftLog, ns.db.craftMulti = {}, nil rank = skill advance(3) end
    local function NoteLine()
        local mark = #log
        slash("craftlog")
        local text = table.concat(log, "\n", mark + 1)
        return text:find((ns.L["  Series of %s are not counted: a craft there gave more than one point."]):format(ns.L["Leatherworking"]), 1, true) ~= nil, text
    end
    -- nothing in the log says more points than crafts
    local function Honest(what)
        local byColour, byGap, others = ns.CraftLogSummary()
        for colour, c in pairs(byColour) do assert(c.ups <= c.tries, what .. ": " .. colour .. " " .. c.ups .. "/" .. c.tries) end
        for _, g in pairs(byGap) do assert(g.ups <= g.tries, what .. ": a distance line with more points than crafts") end
        assert(others.multi == 0, what .. ": " .. others.multi .. " \"gave more than one point\"")
        for _, e in ipairs(ns.db.craftLog) do
            assert(not (e.multi and not e.overlap), what .. ": a craft with " .. tostring(e.gain) .. " points counts alone")
        end
        return byColour, others
    end
    local ok, err = pcall(function()
        advance(3)
        -- (1) Sven's test 6: Create All with 3 s casts, every craft +1. Off
        -- during the second cast, on again during the third.
        local g = Start()                    -- A
        advance(3) Ok(g, 1) g = Start()      -- B runs
        advance(1) Switch(false)
        advance(2) Ok(g, 1) g = Start()      -- B succeeds (off), C runs
        advance(1) Switch(true)
        advance(2) Ok(g, 1) g = Start()      -- C succeeds: over for the log. D starts - C's point is not there yet
        advance(3) Ok(g, 1) g = Start()      -- D succeeds, E runs
        advance(2)                           -- D is read: 2 more than at its start
        assert(not (ns.db.craftMulti and ns.db.craftMulti.Leatherworking), "switched off and on during Create All: the note \"a craft gave more than one point\" is set")
        advance(1) Ok(g, 1) g = Start()      -- E succeeds, F runs
        advance(3) Ok(g, 1) g = Start()      -- F succeeds, a last cast runs
        advance(1) fire("UNIT_SPELLCAST_INTERRUPTED", "player", g, spell) -- ended by moving
        advance(3)
        assert(rank == 16, "test setup: six crafts, six points (" .. rank .. ")")
        local noted, text = NoteLine()
        assert(not noted and not ns.db.craftMulti, "the line \"Series of ... are not counted\" shows: " .. text)
        local byColour, others = Honest("after the switch")
        assert(not byColour.orange or byColour.orange.tries <= 1, "crafts after the switch are in the rates: orange " .. tostring(byColour.orange and byColour.orange.ups) .. "/" .. tostring(byColour.orange and byColour.orange.tries))
        assert(#Blocks() == 0, "a block out of the crafts after the switch")
        -- D is in the log, marked: it started while C's point was on its way
        local blind = 0
        for _, e in ipairs(ns.db.craftLog) do
            if e.blind then
                blind = blind + 1
                assert(e.blind == "settle" and e.overlap and e.result == "ok", "the craft after the switch: blind " .. tostring(e.blind))
            end
        end
        assert(blind == 1, blind .. " crafts marked as started while another's point was on its way, want 1 (D)")
        -- the next Create All, after a pause, counts as ever: a block of 3
        advance(3)
        g = Start()
        for _ = 1, 3 do advance(3) Ok(g, 1) g = Start() end
        advance(1) fire("UNIT_SPELLCAST_INTERRUPTED", "player", g, spell)
        advance(3)
        assert(#Blocks() == 1 and Blocks()[1].n == 3 and Blocks()[1].gain == 3 and Blocks()[1].before == 16 and Blocks()[1].after == 19,
            "the next Create All after the switch is not a block of 3 (" .. #Blocks() .. " blocks)")

        -- (2) the same with single crafts: one made while off, the next
        -- started at once after switching on
        Reset(10)
        Switch(false)
        g = Start() advance(3) Ok(g, 1)
        Switch(true)
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(not ns.db.craftMulti, "a craft started right after one made while off: taken as proof of a multi-point craft")
        assert(#ns.db.craftLog == 1 and ns.db.craftLog[1].blind == "settle" and ns.db.craftLog[1].overlap, "that craft is not marked overlapping")
        Honest("a craft right after one made while off")
        -- one second after it: still inside the 1.5 s
        Reset(10)
        Switch(false)
        g = Start() advance(3) Ok(g, 1)
        Switch(true)
        advance(1)
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(#ns.db.craftLog == 1 and ns.db.craftLog[1].blind == "settle" and ns.db.craftLog[1].overlap, "a craft 1 s after one made while off counts")
        -- 1.5 s after the craft made while off, a craft counts as ever
        Reset(10)
        Switch(false)
        g = Start() advance(3) Ok(g, 1)
        Switch(true)
        advance(1.6)
        g = Start() advance(3) Ok(g, 1) advance(3)
        byColour = ns.CraftLogSummary()
        assert(#ns.db.craftLog == 1 and not ns.db.craftLog[1].overlap and not ns.db.craftLog[1].blind and ns.db.craftLog[1].gain == 1 and byColour.orange.tries == 1 and byColour.orange.ups == 1,
            "a craft 1.6 s after one made while off does not count")

        -- (3) a success whose start was never seen (after a reload in the
        -- middle of a cast, say): no "before" at all
        Reset(10)
        Ok(Guid(), 1) -- no START
        g = Start()   -- Create All goes on
        advance(3) Ok(g, 1) g = Start()
        advance(3) Ok(g, 1)
        advance(3)
        assert(not ns.db.craftMulti, "a success without a start: taken as proof of a multi-point craft")
        local first = ns.db.craftLog[1]
        assert(first and first.blind == "start" and first.before == nil and first.overlap and first.result == "ok" and first.gain == nil,
            "a success without a start: blind " .. tostring(first and first.blind) .. ", before " .. tostring(first and first.before))
        byColour, others = Honest("a success without a start")
        assert(not next(byColour) and #Blocks() == 0 and others.overlap == 3, "a success without a start, then two more of Create All: " .. others.overlap .. " overlapping, want all 3")
        -- with a late point that makes two at once: still no note
        Reset(10)
        g = Start() advance(3) Ok(g, 1)        -- a normal craft, its point 0.5 s later
        advance(0.2)
        Ok(Guid(), 1)                          -- a success without a start, inside the reading
        advance(3)
        assert(not ns.db.craftMulti, "a success without a start inside a reading: the note is set")
        Honest("a success without a start inside a reading")
        assert(select(3, ns.CraftLogSummary()).overlap == 2, "both are not overlapping")

        -- (4) login, reload, a loading screen: what succeeded just before was not seen
        Reset(10)
        fire("PLAYER_ENTERING_WORLD", false, true)
        C_Timer.After(LAG, function() rank = rank + 1 end) -- the point of a craft made just before
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(not ns.db.craftMulti and ns.db.craftLog[1].blind == "settle" and ns.db.craftLog[1].overlap, "a craft started right after a reload: counted alone, +" .. tostring(ns.db.craftLog[1].gain))
        Honest("right after a reload")
        Reset(10)
        fire("PLAYER_ENTERING_WORLD", false, true)
        advance(1.6)
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(not ns.db.craftLog[1].blind and not ns.db.craftLog[1].overlap, "a craft 1.6 s after a reload does not count")

        -- (5) cleared while a craft is still being read, the next starts at once
        Reset(10)
        g = Start() advance(3) Ok(g, 1)
        advance(0.2)
        slash("craftlog clear")
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(not ns.db.craftMulti, "a craft started right after a clear: taken as proof of a multi-point craft")
        assert(#ns.db.craftLog == 1 and ns.db.craftLog[1].blind == "settle" and ns.db.craftLog[1].overlap, "a craft started right after a clear inside a reading is not overlapping")
        -- cleared with nothing being read: the next craft counts
        Reset(10)
        slash("craftlog clear")
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(#ns.db.craftLog == 1 and not ns.db.craftLog[1].overlap and ns.db.craftLog[1].gain == 1, "a craft after a clear with nothing open does not count")

        -- (6) a craft with a hidden cast ID, the next starts at once
        Reset(10)
        issecretvalue = function(v) return rawequal(v, SECRET) end
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, spell)
        C_Timer.After(LAG, function() rank = rank + 1 end)
        issecretvalue = saved.secret
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(not ns.db.craftMulti, "a craft started right after one with a hidden cast ID: taken as proof of a multi-point craft")
        Honest("right after a hidden cast ID")

        -- (7) a cast open at a switch that succeeds later, the next at once
        Reset(10)
        g = Start()
        advance(1) Switch(false) Switch(true)
        advance(2) Ok(g, 1)
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(not ns.db.craftMulti and #ns.db.craftLog == 1 and ns.db.craftLog[1].overlap, "a craft started right after a cast that was open at a switch")
        Honest("right after a cast open at a switch")

        -- (8) what must stay: a repeated event of a logged cast is nothing
        -- new - Create All stays a block
        Reset(10)
        g = Start()
        for _ = 1, 4 do
            advance(3)
            Ok(g, 1)
            fire("UNIT_SPELLCAST_SUCCEEDED", "player", g, spell) -- told twice
            g = Start()
        end
        advance(1) fire("UNIT_SPELLCAST_INTERRUPTED", "player", g, spell)
        advance(3)
        assert(#Blocks() == 1 and Blocks()[1].n == 4 and Blocks()[1].gain == 4, "successes told twice: no block of 4")
        -- a spell that is no recipe, cast while off or ignored, makes nothing blind
        Reset(10)
        Switch(false)
        fire("UNIT_SPELLCAST_START", "player", "Cast-t8-hearth", 8690)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-t8-hearth", 8690)
        Switch(true)
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(#ns.db.craftLog == 1 and not ns.db.craftLog[1].blind and not ns.db.craftLog[1].overlap, "a spell that is no recipe made the next craft blind")
        -- a cast begun while off that is aborted after switching on made
        -- nothing: the next craft counts
        Reset(10)
        Switch(false)
        g = Start()
        advance(1)
        Switch(true)
        fire("UNIT_SPELLCAST_INTERRUPTED", "player", g, spell)
        g = Start() advance(3) Ok(g, 1) advance(3)
        assert(#ns.db.craftLog == 1 and not ns.db.craftLog[1].blind and not ns.db.craftLog[1].overlap and ns.db.craftLog[1].gain == 1,
            "an aborted cast that was begun while off made the next craft blind")
        -- a blind cast breaks a series that is still open (its last cast
        -- never ended for the log - a loading screen, say): no block
        Reset(10)
        g = Start() advance(3) Ok(g, 0)   -- A, no point
        local b = Start()                   -- B, in A's reading: a series
        advance(2)
        fire("PLAYER_ENTERING_WORLD", false, false)
        local c = Start()                   -- C: blind
        advance(1) Ok(c, 1)
        advance(0.2) Ok(b, 1)               -- B's success after all
        advance(3)
        assert(#Blocks() == 0, "a blind cast while a series was open: a block of 2 with 2 points (A gave none)")
        Honest("a blind cast while a series was open")
        -- a failure never makes the next craft blind
        Reset(10)
        fire("UNIT_SPELLCAST_FAILED", "player", Guid(), spell)
        g = Start() advance(3) Ok(g, 1) advance(3)
        local counted = 0
        for _, e in ipairs(ns.db.craftLog) do if e.result == "ok" and not e.overlap and e.gain == 1 then counted = counted + 1 end end
        assert(counted == 1, "a craft after a failure without a start does not count")

        -- (9) a real single craft with two points, its start seen, nothing
        -- unsettled: the note is set as before
        Reset(10)
        g = Start() advance(3) Ok(g, 2) advance(3)
        assert(ns.db.craftMulti and ns.db.craftMulti.Leatherworking, "a clear single craft with two points: no note")
        assert(NoteLine(), "the line of the note does not show")
        -- and an old log (0.1.20) with such an entry still gives the note
        ns.db.craftMulti = nil
        ns.db.craftLog = {
            { t = 1, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 10, after = 12, gain = 2, multi = true },
        }
        g = Start() advance(0.3) Ok(g, 1) g = Start() advance(0.3) Ok(g, 1) advance(3)
        assert(ns.db.craftMulti and ns.db.craftMulti.Leatherworking and #Blocks() == 0, "an old entry with two points: the note is not found again")
        -- an entry marked blind never gives it
        ns.db.craftMulti = nil
        ns.db.craftLog = {
            { t = 1, result = "ok", prof = "Leatherworking", spell = spell, colour = "orange", before = 10, after = 12, gain = 2, multi = true, blind = "settle" },
        }
        rank = 12
        advance(3)
        g = Start() advance(0.3) Ok(g, 1) g = Start() advance(0.3) Ok(g, 1) advance(3)
        assert(not ns.db.craftMulti and #Blocks() == 1, "an entry marked blind is taken as proof of a multi-point craft")
    end)
    advance(3)
    ns.ProfessionRank, ns.CraftData.Have, data.colors[spell], data.colors[other] = saved.rank, saved.have, saved.colors, saved.colors2
    ns.db.craftLogOff, issecretvalue = saved.off, saved.secret
    if ns.CraftLogBreak then ns.CraftLogBreak() end
    advance(3)
    ns.db.craftLog, ns.db.craftMulti = saved.log, saved.multi
    if not ok then error(err, 0) end
end)
-- (end of the v0.1.21 steps)
step("Gathering help: mark the node you walk towards, put back like fishing (v0.1.19 Q6 A)", function()
    local saved = { get = GetCVar, set = SetCVar, mark = ns.db.gatherMark, bobber = ns.db.fishMarkBobber, loud = ns.db.fishLoudSplash,
        cvars = ns.db.fishingCVars, map = player.map, x = player.x, y = player.y }
    local store
    local ORIG = { SoftTargetInteract = "1", SoftTargetInteractRange = "10", SoftTargetInteractArc = "0", SoftTargetIconGameObject = "0",
        Sound_SFXVolume = "0.5", Sound_MusicVolume = "0.8", Sound_AmbienceVolume = "0.8" }
    local function Reset()
        store = {}
        for k, v in pairs(ORIG) do store[k] = v end
    end
    local function Is(want, what)
        for k, v in pairs(want) do
            assert(store[k] == v, ("%s: %s = %s, want %s"):format(what, k, tostring(store[k]), v))
        end
    end
    local MARKED = { SoftTargetInteract = "3", SoftTargetInteractRange = "30", SoftTargetInteractArc = "2", SoftTargetIconGameObject = "1" }
    local function Untouched(what)
        Is(ORIG, what)
        assert(ns.db.fishingCVars == nil, what .. ": an entry is left in the saved list")
    end
    local fishFrame = next(eventFrames["UNIT_SPELLCAST_CHANNEL_STOP"])
    local function Cast() fire("UNIT_SPELLCAST_CHANNEL_START", "player", "q6fish", 7620) end
    local function Reel() fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "q6fish", 7620) advance(1) end
    local ok, err = pcall(function()
        GetCVar = function(k) if store[k] ~= nil then return store[k] end return saved.get(k) end
        SetCVar = function(k, v) store[k] = tostring(v) return true end
        ns.db.fishingCVars, ns.db.fishMarkBobber, ns.db.fishLoudSplash = nil, false, true
        player.map, player.x, player.y = 1412, 0.45, 0.72
        ns.SetQuestMode(false)
        if ns.run then ns.StopRun(true) end
        -- (1) off (the default): runs and the questing mode change nothing
        ns.db.gatherMark = nil
        Reset()
        slash("run herb") advance(2)
        assert(ns.run, "test setup: no run")
        Untouched("option off, during a run")
        ns.StopRun(true) advance(1)
        ns.SetQuestMode(true) advance(1)
        Untouched("option off, questing mode")
        ns.SetQuestMode(false) advance(1)
        Untouched("option off, after")
        -- (2) on: during the questing mode the four settings, after it yours again
        ns.db.gatherMark = true
        Reset()
        ns.UpdateGatherHelp("test")
        Untouched("option on, nothing going on")
        ns.SetQuestMode(true) advance(1)
        Is(MARKED, "questing mode")
        assert(ns.db.fishingCVars and ns.db.fishingCVars.SoftTargetInteractRange.orig == "10", "not in the saved list")
        ns.SetQuestMode(false) advance(1)
        Untouched("questing mode off")
        -- (3) a farm run the same
        slash("run herb") advance(2)
        Is(MARKED, "farm run")
        slash("stop") advance(1)
        Untouched("run stopped")
        -- (4) you change one during the run: it stays as you set it
        slash("run herb") advance(2)
        store.SoftTargetInteractRange = "50"
        slash("stop") advance(1)
        Is({ SoftTargetInteract = "1", SoftTargetInteractRange = "50", SoftTargetInteractArc = "0", SoftTargetIconGameObject = "0" }, "changed by you during the run")
        assert(ns.db.fishingCVars == nil, "changed by you: an entry is left")
        -- (5) fishing during a run: fishing takes over, the run keeps its mark
        Reset()
        slash("run herb") advance(2)
        Cast()
        Is(MARKED, "line out during a run")
        Is({ Sound_SFXVolume = "1", Sound_MusicVolume = "0.1" }, "line out: the splash settings")
        Reel()
        Is(MARKED, "line in, the run goes on")
        Is({ Sound_SFXVolume = "0.5", Sound_MusicVolume = "0.8", Sound_AmbienceVolume = "0.8" }, "line in: the splash settings came back")
        slash("stop") advance(1)
        Untouched("run stopped after fishing")
        -- the other way round: a run starts while the line is out
        Reset()
        Cast()
        slash("run herb") advance(2)
        Reel()
        Is(MARKED, "run started with the line out, line in")
        slash("stop") advance(1)
        Untouched("run stopped, the line came in first")
        Reset()
        Cast()
        slash("run herb") advance(2)
        slash("stop") advance(1)
        Is({ SoftTargetInteractRange = "30", Sound_SFXVolume = "1" }, "run stopped, the line still out: fishing keeps its settings")
        Reel()
        Untouched("line in after the run")
        -- (6) the option switched off and on during a run
        slash("run herb") advance(2)
        Is(MARKED, "run")
        ns.db.gatherMark = nil
        ns.UpdateGatherHelp("option")
        Untouched("option switched off during the run")
        ns.db.gatherMark = true
        ns.UpdateGatherHelp("option")
        Is(MARKED, "option switched on again during the run")
        -- (7) /reload or logout during the run: back before the game saves
        fishFrame.__scripts.OnEvent(fishFrame, "PLAYER_LOGOUT")
        Untouched("logout during a run")
        -- the reloaded addon, the run going on: marked again after login
        fishFrame.__scripts.OnEvent(fishFrame, "PLAYER_LOGIN")
        advance(2)
        Is(MARKED, "login, the run going on")
        -- (8) the run ended without its stop (a crash, a disconnect), but the
        -- list was saved before it (a /reload or logout during the run): the
        -- settings are still ours, the next login (no run going on now) puts
        -- them back from the saved list
        assert(ns.db.fishingCVars and ns.db.fishingCVars.SoftTargetInteractRange, "test setup: the list during the run")
        local crashed = ns.run
        ns.run = nil -- gone with the crash, without its stop
        fishFrame.__scripts.OnEvent(fishFrame, "PLAYER_LOGIN")
        advance(2)
        Untouched("login after a crash, the list saved before it")
        ns.run = crashed
        ns.StopRun(true)
        Untouched("the old run's stop after the crash login")
        -- the limit (Codex 09.11., B4): a crash before the game ever saved
        -- the list - the settings are still ours, nothing says what they
        -- were. The login leaves them as they are: nothing is guessed, no
        -- default is forced, no list is invented
        for k, v in pairs(MARKED) do store[k] = v end
        ns.db.fishingCVars = nil
        fishFrame.__scripts.OnEvent(fishFrame, "PLAYER_LOGIN")
        advance(2)
        Is(MARKED, "login after a crash without a saved list: a value was guessed")
        assert(ns.db.fishingCVars == nil, "login after a crash without a saved list: a list was invented")
        Reset()
        -- (9) the option text says honestly what it does
        local found
        for _, o in ipairs(allFrames) do
            if o.__kind == "FontString" and o:GetText() == ns.L["Mark the node you walk towards (one at a time)"] then found = o end
        end
        assert(found, "no option \"Mark the node you walk towards (one at a time)\"")
    end)
    GetCVar, SetCVar = saved.get, saved.set
    if ns.run then ns.StopRun(true) end
    ns.SetQuestMode(false)
    ns.db.gatherMark, ns.db.fishMarkBobber, ns.db.fishLoudSplash, ns.db.fishingCVars = saved.mark, saved.bobber, saved.loud, saved.cvars
    if ns.StopFishing then ns.StopFishing() end
    player.map, player.x, player.y = saved.map, saved.x, saved.y
    if not ok then error(err, 0) end
end)
step("Gathering help: the Fish key gathers during a run or the questing mode, never in combat (v0.1.19 Q6 B)", function()
    local saved = { get = GetCVar, set = SetCVar, set2 = SetOverrideBinding, clear = ClearOverrideBindings, combat = InCombatLockdown,
        bind = GetBindingKey, mark = ns.db.gatherMark, key = ns.db.gatherKey, cvars = ns.db.fishingCVars, bobber = ns.db.fishMarkBobber,
        map = player.map, x = player.x, y = player.y }
    local store = {}
    local binds = {} -- owner -> key -> command
    local fighting = false
    local bound = "F" -- the key bound to Fish (nil: none)
    local function Gathers()
        for _, keys in pairs(binds) do if keys.F == "INTERACTTARGET" then return true end end
        return false
    end
    local function Owners()
        local n = 0
        for _, keys in pairs(binds) do if next(keys) then n = n + 1 end end
        return n
    end
    local function Cast() fire("UNIT_SPELLCAST_CHANNEL_START", "player", "q6b", 7620) end
    local function Reel() fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "q6b", 7620) advance(1) end
    local L = ns.L
    local ok, err = pcall(function()
        GetCVar = function(k) return store[k] or "0" end
        SetCVar = function(k, v) store[k] = tostring(v) return true end
        SetOverrideBinding = function(owner, _, key, cmd) binds[owner] = binds[owner] or {} binds[owner][key] = cmd end
        ClearOverrideBindings = function(owner) binds[owner] = nil end
        InCombatLockdown = function() return fighting end
        GetBindingKey = function(cmd) if cmd == ns.FishBinding then return bound end return saved.bind(cmd) end
        ns.db.fishingCVars, ns.db.fishMarkBobber = nil, false
        player.map, player.x, player.y = 1412, 0.45, 0.72
        ns.SetQuestMode(false)
        if ns.run then ns.StopRun(true) end
        -- (1) off: the Fish key stays the Fish key
        ns.db.gatherMark, ns.db.gatherKey = nil, nil
        slash("run herb") advance(2)
        assert(ns.run and not Gathers(), "option off: the Fish key gathers during a run")
        slash("stop") advance(1)
        -- (2) the switch turns the mark on too; the mark off turns it off
        local keyBox, markBox
        for _, o in ipairs(allFrames) do
            if o.__kind == "FontString" and o.__pts and o.__pts.LEFT then
                if o:GetText() == L["Fish key gathers the marked node"] then keyBox = o.__pts.LEFT[1] end
                if o:GetText() == L["Mark the node you walk towards (one at a time)"] then markBox = o.__pts.LEFT[1] end
            end
        end
        assert(keyBox and markBox and keyBox.get and markBox.get, "no switches under Farm runs")
        keyBox:SetChecked(true) keyBox.__scripts.OnClick(keyBox)
        assert(ns.db.gatherKey and ns.db.gatherMark and markBox.get(), "the key switch did not turn the mark on")
        markBox:SetChecked(false) markBox.__scripts.OnClick(markBox)
        assert(not ns.db.gatherKey and not ns.db.gatherMark, "the mark off left the key on")
        keyBox:SetChecked(true) keyBox.__scripts.OnClick(keyBox)
        assert(not Gathers(), "the key gathers with nothing going on")
        -- (3) a run: the Fish key gathers, and the node is marked; after the run: fishing again
        slash("run herb") advance(2)
        assert(Gathers() and store.SoftTargetInteract == "3", "during the run: the key does not gather, or nothing marked")
        slash("stop") advance(1)
        assert(not Gathers() and Owners() == 0, "after the run the key still gathers")
        assert(ns.db.fishingCVars == nil, "after the run settings are left")
        -- (4) the questing mode the same
        ns.SetQuestMode(true) advance(1)
        assert(Gathers(), "questing mode: the key does not gather")
        ns.SetQuestMode(false) advance(1)
        assert(not Gathers(), "questing mode off: the key still gathers")
        -- (5) combat: nothing is changed in the fight, it follows at its end
        fighting = true
        slash("run herb") advance(2)
        assert(ns.run and not Gathers(), "a key changed in combat (run start)")
        fighting = false
        fire("PLAYER_REGEN_ENABLED") advance(1)
        assert(Gathers(), "after the fight the key does not gather")
        fighting = true
        slash("stop") advance(1)
        assert(Gathers(), "a key changed in combat (run stop)")
        fighting = false
        fire("PLAYER_REGEN_ENABLED") advance(1)
        assert(not Gathers() and Owners() == 0, "after the fight the key still gathers")
        -- (6) fishing during a run: reeling in ends the line, not the gathering key
        slash("run herb") advance(2)
        Cast()
        assert(Gathers(), "line out during a run")
        Reel()
        assert(Gathers(), "line in: the run's gathering key went")
        slash("stop") advance(1)
        assert(not Gathers() and Owners() == 0, "after the run and fishing a key is left")
        -- (7) the option off during the run
        slash("run herb") advance(2)
        keyBox:SetChecked(false) keyBox.__scripts.OnClick(keyBox)
        assert(not Gathers(), "the switch off: the key still gathers")
        slash("stop") advance(1)
        -- (8) the key saved on, the mark saved off (settings of another
        -- version): the key still brings the mark with it
        ns.db.gatherKey, ns.db.gatherMark = true, nil
        slash("run herb") advance(2)
        assert(Gathers() and store.SoftTargetInteract == "3", "the key without a saved mark: nothing marked")
        slash("stop") advance(1)
        assert(not Gathers() and ns.db.fishingCVars == nil, "the key without a saved mark: left after the run")
        ns.db.gatherKey = nil
        -- (9) you rebind the Fish key while it gathers (Codex 09.11., B2): the
        -- old key is yours again, the new one gathers; none bound, none
        -- overridden; in combat it waits for the end of the fight
        local function KeyGathers(key)
            for _, keys in pairs(binds) do if keys[key] == "INTERACTTARGET" then return true end end
            return false
        end
        ns.db.gatherKey, ns.db.gatherMark = true, true
        slash("run herb") advance(2)
        assert(KeyGathers("F"), "test setup: F does not gather")
        bound = "G"
        fire("UPDATE_BINDINGS")
        assert(not KeyGathers("F"), "F rebound to another action: still overridden")
        assert(KeyGathers("G"), "the new Fish key G does not gather")
        bound = nil
        fire("UPDATE_BINDINGS")
        assert(not KeyGathers("F") and not KeyGathers("G") and Owners() == 0, "no Fish key bound: an override is left")
        bound = "F"
        fighting = true
        fire("UPDATE_BINDINGS")
        assert(Owners() == 0, "a key changed in combat (rebind)")
        fighting = false
        fire("PLAYER_REGEN_ENABLED") advance(1)
        assert(KeyGathers("F"), "after the fight the rebound key does not gather")
        fighting = true
        bound = "G"
        fire("UPDATE_BINDINGS")
        assert(KeyGathers("F") and not KeyGathers("G"), "a key changed in combat (F to G)")
        fighting = false
        fire("PLAYER_REGEN_ENABLED") advance(1)
        assert(KeyGathers("G") and not KeyGathers("F"), "after the fight: G should gather, F be free")
        slash("stop") advance(1)
        assert(Owners() == 0, "after the run an override of a rebound key is left")
        bound = "F"
    end)
    GetBindingKey = saved.bind
    GetCVar, SetCVar, SetOverrideBinding, ClearOverrideBindings, InCombatLockdown = saved.get, saved.set, saved.set2, saved.clear, saved.combat
    if ns.run then ns.StopRun(true) end
    ns.SetQuestMode(false)
    ns.db.gatherMark, ns.db.gatherKey, ns.db.fishingCVars, ns.db.fishMarkBobber = saved.mark, saved.key, saved.cvars, saved.bobber
    if ns.UpdateGatherHelp then ns.UpdateGatherHelp("test end") end
    if ns.StopFishing then ns.StopFishing() end
    player.map, player.x, player.y = saved.map, saved.x, saved.y
    if not ok then error(err, 0) end
end)
step("Skinning log: one entry per skinned beast, needed skill from the client's message, local only (v0.1.19 Q7)", function()
    local L = ns.L
    local saved = { guid = UnitGUID, name = UnitName, isPlayer = UnitIsPlayer, skill = ns.GetSkill, secret = issecretvalue,
        log = ns.db.skinLog, needs = ns.db.skinNeeds, off = ns.db.skinLogOff, err = _G.ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI,
        unclear = ns.db.skinUnclear, map = player.map, x = player.x, y = player.y }
    local units = {}
    local SECRET = newproxy(true)
    local CORPSE = "Creature-0-1-1-1-3035-0000AA0001"
    -- opts.target == false: no target and nothing under the mouse at the cast
    local function Skin(guid, items, opts)
        opts = opts or {}
        units.target = opts.target ~= false and guid or nil
        if not opts.noCast then fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-skin-" .. tostring(guid), opts.spell or 8613) end
        if opts.wait then advance(opts.wait) end
        loot = {}
        for _, it in ipairs(items) do loot[#loot + 1] = { guid = opts.source or guid, item = it[1], qty = it[2] } end
        for _, e in ipairs(opts.events or { "LOOT_READY", "LOOT_OPENED", "LOOT_READY", "LOOT_CLOSED", "LOOT_CLOSED" }) do fire(e) end
        loot = {}
        advance(1)
    end
    local ok, err = pcall(function()
        UnitGUID = function(u) return units[u] end
        UnitName = function(u) if u == "player" then return "Test Player" end return units[u] and "Plainstrider" or nil end
        UnitIsPlayer = function() return false end
        ns.GetSkill = function(t) if t == "skin" then return 50, 75, 50 end return saved.skill(t) end
        ns.db.skinLog, ns.db.skinNeeds, ns.db.skinLogOff, ns.db.skinUnclear = {}, {}, nil, nil
        player.map, player.x, player.y = 1412, 0.4567, 0.7123
        local nodesBefore = #(ns.db.nodes[1412] or {})
        -- a normal skinning; the loot window seen twice is one entry
        Skin(CORPSE, { { 2318, 2 }, { 2934, 1 } })
        assert(#ns.db.skinLog == 1, "entries after one skinning: " .. #ns.db.skinLog)
        local e = ns.db.skinLog[1]
        assert(e.npc == 3035 and e.name == "Plainstrider" and e.map == 1412, ("npc %s, name %s, map %s"):format(tostring(e.npc), tostring(e.name), tostring(e.map)))
        assert(e.x == 0.46 and e.y == 0.71, ("a rough position, not the exact one: %s %s"):format(tostring(e.x), tostring(e.y)))
        assert(e.skill == 50 and e.build == 70450 and e.t, "skill, build or time")
        assert(e.items[2318] == 2 and e.items[2934] == 1, "the items and amounts")
        assert(#(ns.db.nodes[1412] or {}) == nodesBefore, "the herb and ore recorder took the skinning as a node")
        -- the same corpse again (a late loot event): nothing more
        Skin(CORPSE, { { 2318, 2 } }, { noCast = true })
        assert(#ns.db.skinLog == 1, "the same corpse counted twice")
        -- looting a corpse without skinning it: nothing
        Skin("Creature-0-1-1-1-3035-0000AA0002", { { 4865, 1 } }, { noCast = true })
        assert(#ns.db.skinLog == 1, "a normal corpse loot counted as skinning")
        -- a cast that was broken off (no success), then the normal loot: nothing
        units.target = "Creature-0-1-1-1-3035-0000AA0003"
        fire("UNIT_SPELLCAST_START", "player", "Cast-abort", 8613)
        fire("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-abort", 8613)
        Skin("Creature-0-1-1-1-3035-0000AA0003", { { 4865, 1 } }, { noCast = true })
        assert(#ns.db.skinLog == 1, "an interrupted skinning counted")
        -- another spell (Herbalism) before a loot: nothing
        Skin("Creature-0-1-1-1-3035-0000AA0004", { { 2318, 1 } }, { spell = 2366 })
        assert(#ns.db.skinLog == 1, "a herb spell made a skinning")
        -- the loot of a chest or a herb right after a skinning cast: nothing
        Skin("Creature-0-1-1-1-3035-0000AA0005", { { 2447, 1 } }, { source = "GameObject-0-1-1-1-1617-0000BB0001" })
        Skin("Creature-0-1-1-1-3035-0000AA0006", { { 858, 1 } }, { source = "GameObject-0-1-1-1-106318-0000BB0002" })
        assert(#ns.db.skinLog == 1, "a chest or herb loot counted as skinning")
        -- Codex' probe (09.11., B3): no target and nothing under the mouse at
        -- the cast, then the loot of another beast within 5 s: no find for
        -- it; kept apart as unclear, not dropped in silence
        local OTHER = "Creature-0-1-1-1-9999-0000DD0001"
        Skin(OTHER, { { 4865, 1 } }, { target = false })
        assert(#ns.db.skinLog == 1, "a beast's loot without a beast at the cast counted as a find")
        assert(ns.db.skinUnclear and #ns.db.skinUnclear == 1, "the unclear loot was dropped in silence")
        assert(ns.db.skinUnclear[1].npc == 9999 and ns.db.skinUnclear[1].items[4865] == 1 and ns.db.skinUnclear[1].name == nil, "the unclear entry")
        -- the same corpse again: still one unclear
        Skin(OTHER, { { 4865, 1 } }, { target = false, noCast = true })
        assert(#ns.db.skinUnclear == 1, "the same unclear corpse kept twice")
        -- Codex' control: your own corpse is clear, another beast's loot comes
        -- first - it is not the skinning (no find, not unclear), your leather
        -- after it is one entry
        local MINE = "Creature-0-1-1-1-3035-0000AA0020"
        Skin(MINE, { { 4865, 1 } }, { source = "Creature-0-1-1-1-9999-0000DD0002" })
        assert(#ns.db.skinLog == 1 and #ns.db.skinUnclear == 1, "another beast's loot with your own corpse clear")
        Skin(MINE, { { 2318, 1 } }, { noCast = true })
        Skin(MINE, { { 2318, 1 } }, { noCast = true })
        assert(#ns.db.skinLog == 2 and ns.db.skinLog[2].npc == 3035 and ns.db.skinLog[2].items[2318] == 1, "your own leather after another beast's loot")
        table.remove(ns.db.skinLog, 2)
        -- a loot long after the cast: nothing
        Skin("Creature-0-1-1-1-3035-0000AA0007", { { 2318, 1 } }, { wait = 6 })
        assert(#ns.db.skinLog == 1, "a loot 6 s after the cast counted")
        -- a second skinning cast on the corpse already skinned, its loot again: still one
        Skin(CORPSE, { { 2318, 2 } })
        assert(#ns.db.skinLog == 1, "the same corpse counted again after a second cast")
        -- no beast to tell (no target, no mouseover): a chest after a skinning cast is still no entry
        units.target, units.mouseover = nil, nil
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-nt", 8613)
        loot = { { guid = "GameObject-0-1-1-1-106318-0000BB0003", item = 858, qty = 1 } }
        fire("LOOT_READY") loot = {} advance(1)
        assert(#ns.db.skinLog == 1, "a chest counted as skinning when no beast was targeted")
        -- hidden values: nothing compared or kept
        issecretvalue = function(v) return rawequal(v, SECRET) end
        Skin("Creature-0-1-1-1-3035-0000AA0008", { { 2318, 1 } }, { source = SECRET })
        assert(#ns.db.skinLog == 1, "a hidden loot source counted")
        loot = {}
        units.target = "Creature-0-1-1-1-3035-0000AA0009"
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-s9", 8613)
        loot = { { guid = "Creature-0-1-1-1-3035-0000AA0009", item = 2318, qty = SECRET } }
        fire("LOOT_READY") loot = {} advance(1)
        assert(#ns.db.skinLog == 1, "a hidden amount counted")
        ns.GetSkill = function(t) if t == "skin" then return SECRET end return saved.skill(t) end
        Skin("Creature-0-1-1-1-3035-0000AA0010", { { 2318, 1 } })
        assert(#ns.db.skinLog == 2 and ns.db.skinLog[2].skill == nil, "a hidden skill: kept, or the entry missing")
        ns.GetSkill = function(t) if t == "skin" then return 50, 75, 50 end return saved.skill(t) end
        issecretvalue = saved.secret
        -- "Requires Skinning N": the client's own text, the client's name of Skinning
        local skin = C_Spell.GetSpellName(8613)
        _G.ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI = "Requires %s %d"
        units.target, units.mouseover = "Creature-0-1-1-1-2956-0000CC0001", nil
        fire("UI_ERROR_MESSAGE", 51, "Requires " .. skin .. " 100")
        assert(ns.db.skinNeeds[2956] == 100, "the needed skill is not kept: " .. tostring(ns.db.skinNeeds[2956]))
        -- the older form (message only)
        units.target = "Creature-0-1-1-1-2957-0000CC0002"
        fire("UI_ERROR_MESSAGE", "Requires " .. skin .. " 85")
        assert(ns.db.skinNeeds[2957] == 85, "the older message form")
        -- a client whose text puts the number first (numbered places)
        _G.ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI = "%2$d %1$s benötigt"
        units.target = "Creature-0-1-1-1-2958-0000CC0003"
        fire("UI_ERROR_MESSAGE", 51, "120 " .. skin .. " benötigt")
        assert(ns.db.skinNeeds[2958] == 120, "a text with the number first")
        _G.ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI = "Requires %s %d"
        -- another skill (Lockpicking), or two beasts at once: nothing
        units.target = "Creature-0-1-1-1-2959-0000CC0004"
        fire("UI_ERROR_MESSAGE", 51, "Requires Lockpicking 100")
        units.target, units.mouseover = "Creature-0-1-1-1-2960-0000CC0005", "Creature-0-1-1-1-2961-0000CC0006"
        fire("UI_ERROR_MESSAGE", 51, "Requires " .. skin .. " 100")
        assert(not ns.db.skinNeeds[2959] and not ns.db.skinNeeds[2960] and not ns.db.skinNeeds[2961], "kept although not clear")
        units.mouseover = nil
        -- no text in the client: nothing is guessed
        _G.ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI = nil
        units.target = "Creature-0-1-1-1-2962-0000CC0007"
        fire("UI_ERROR_MESSAGE", 51, "Requires " .. skin .. " 100")
        assert(not ns.db.skinNeeds[2962], "a needed skill without the client's text")
        _G.ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI = saved.err
        -- /gcr skinlog
        local mark = #log
        slash("skinlog")
        local text = table.concat(log, "\n", mark + 1)
        assert(text:find((L["Skinning log: %d skinned, %d kinds of beasts (kept on this computer, never shared)."]):format(2, 1), 1, true), "/gcr skinlog: " .. text)
        assert(text:find("Plainstrider", 1, true) and text:find((L["  Your skill while skinning: %d-%d"]):format(50, 50), 1, true), "/gcr skinlog: beasts or skill")
        assert(text:find((L["  %d unclear: no beast could be told at the cast (not counted)"]):format(1), 1, true), "/gcr skinlog: the unclear count")
        assert(not text:find("9999", 1, true), "/gcr skinlog: the unclear beast listed as a find")
        -- off: nothing
        ns.db.skinLogOff = true
        Skin("Creature-0-1-1-1-3035-0000AA0011", { { 2318, 1 } })
        assert(#ns.db.skinLog == 2, "recorded although turned off")
        ns.db.skinLogOff = nil
        -- the newest 5000
        local full = {}
        for i = 1, 5000 do full[i] = { t = i, npc = 1, items = {} } end
        ns.db.skinLog = full
        Skin("Creature-0-1-1-1-3035-0000AA0012", { { 2318, 1 } })
        assert(#ns.db.skinLog == 5000 and ns.db.skinLog[1].t == 2 and ns.db.skinLog[5000].npc == 3035, "not kept at 5000")
        -- clear
        slash("skinlog clear")
        assert(#ns.db.skinLog == 0 and not next(ns.db.skinNeeds) and #ns.db.skinUnclear == 0, "/gcr skinlog clear")
        -- never in what is shared: no sync message carries it
        for _, m in ipairs(sentMessages) do assert(not m:find("3035", 1, true) or m:find("^N:"), "a skinning in a sync message: " .. m) end
        for _, m in ipairs(sentMessages) do assert(not m:find("9999", 1, true) or m:find("^N:"), "an unclear skinning in a sync message: " .. m) end
        -- the option under General
        local found
        for _, o in ipairs(allFrames) do
            if o.__kind == "FontString" and o:GetText() == L["Record skinning (helps build skinning areas)"] then
                local p = o.__parent
                while p and not p.key do p = p.__parent end
                found = p and p.key
            end
        end
        assert(found == "general", "the option is not under General: " .. tostring(found))
    end)
    UnitGUID, UnitName, UnitIsPlayer, ns.GetSkill, issecretvalue = saved.guid, saved.name, saved.isPlayer, saved.skill, saved.secret
    ns.db.skinLog, ns.db.skinNeeds, ns.db.skinLogOff, _G.ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI = saved.log, saved.needs, saved.off, saved.err
    ns.db.skinUnclear = saved.unclear
    player.map, player.x, player.y = saved.map, saved.x, saved.y
    loot = {}
    if not ok then error(err, 0) end
end)
step("Options: the herbs/minerals switch is under General, every page fits (v0.1.19)", function()
    -- Sven (08.11.): Map & minimap makes room for the questing mode
    local function PageOf(text)
        for _, o in ipairs(allFrames) do
            if o.GetText and o:GetText() == text then
                local p = o.__parent
                while p and not p.key do p = p.__parent end
                if p then return p.key end
            end
        end
    end
    assert(PageOf(ns.L["Herbs / minerals switch button"]) == "general", "the switch is not under General: " .. tostring(PageOf(ns.L["Herbs / minerals switch button"])))
    assert(PageOf(ns.L["Put it on an action bar"]) == "general", "its macro button is not under General")
    assert(PageOf(ns.L["Next to the minimap, when you know both: one click switches your tracking."]) == "general", "its hint is not under General")
    -- every page that does not flow ends above the footer, also inside the
    -- main window (its options page is 6 px lower than the standalone window)
    local used = ns.OptionsUsedHeight and ns.OptionsUsedHeight()
    assert(used and used.map and used.general, "test setup: how far the pages go")
    local ROOM = 640 - 112 - 18 - 4 - 66 -- main window body, minus the options' top and footer
    for key, h in pairs(used) do
        if key ~= "level" then -- Leveling flows (own step)
            assert(h <= ROOM, ("Options %s: %d px of %d"):format(key, h, ROOM))
        end
    end
end)
step("Herbs / minerals switch button: on the edge of a round and a square minimap, above its frame (v0.1.20 K1)", function()
    -- Sven (09.11.): with a square minimap (Ellesmere UI) the button was
    -- never seen. It sat on a circle around the centre, whatever the shape.
    local btn = GathercraftTrackButton
    assert(btn, "no switch button")
    local saved = { shape = _G.GetMinimapShape, w = Minimap.GetWidth, h = Minimap.GetHeight, angle = ns.db.trackButtonAngle, combat = InCombatLockdown }
    -- places the button (older code: only its login event does)
    local function Place()
        if ns.PlaceTrackButton then ns.PlaceTrackButton() return end
        local f = next(eventFrames["MINIMAP_UPDATE_TRACKING"])
        f.__scripts.OnEvent(f, "PLAYER_LOGIN")
    end
    local function Pos()
        local p = btn.__pts and btn.__pts.CENTER
        assert(p and p[1] == Minimap and p[2] == "CENTER", "the button is not anchored to the minimap's centre")
        return p[3], p[4]
    end
    local function Near(a, b) return math.abs(a - b) < 0.5 end
    local ok, err = pcall(function()
        Minimap.GetWidth = function() return 140 end
        Minimap.GetHeight = function() return 140 end
        -- round (no shape function, as the game's own minimap): a circle of 75
        _G.GetMinimapShape = nil
        ns.db.trackButtonAngle = 250
        Place()
        local x, y = Pos()
        assert(Near(math.sqrt(x * x + y * y), 75), ("round: %.1f from the centre, want 75"):format(math.sqrt(x * x + y * y)))
        assert(Near(x, math.cos(math.rad(250)) * 75) and Near(y, math.sin(math.rad(250)) * 75), "round: not at the saved angle")
        -- a UI addon says ROUND: the same
        _G.GetMinimapShape = function() return "ROUND" end
        Place()
        local x2, y2 = Pos()
        assert(Near(x, x2) and Near(y, y2), "ROUND from the shape function placed differently")
        -- SQUARE: on the rectangle's edge, 5 px outside, in the same direction
        _G.GetMinimapShape = function() return "SQUARE" end
        Place()
        x, y = Pos()
        assert(Near(y, -75), ("square at 250 degrees: y %.1f, want -75 (the bottom edge)"):format(y))
        assert(Near(x / y, math.cos(math.rad(250)) / math.sin(math.rad(250))), "square: not in the direction of the angle")
        assert(math.abs(x) < 75, "square: outside the rectangle's width")
        -- at 0 degrees: the right edge
        ns.db.trackButtonAngle = 0
        Place()
        x, y = Pos()
        assert(Near(x, 75) and Near(y, 0), ("square at 0 degrees: %.1f, %.1f"):format(x, y))
        -- at 45 degrees on a square: the corner
        ns.db.trackButtonAngle = 45
        Place()
        x, y = Pos()
        assert(Near(x, 75) and Near(y, 75), ("square at 45 degrees: %.1f, %.1f"):format(x, y))
        -- a wider than tall minimap: the edge is the rectangle's, not a circle's
        Minimap.GetWidth = function() return 200 end
        ns.db.trackButtonAngle = 90
        Place()
        x, y = Pos()
        assert(Near(x, 0) and Near(y, 75), ("wide minimap at 90 degrees: %.1f, %.1f"):format(x, y))
        Minimap.GetWidth = function() return 140 end
        -- a corner shape or an odd value: not round, so the rectangle; an
        -- erroring or non-string answer: round
        _G.GetMinimapShape = function() return "CORNER-TOPLEFT" end
        ns.db.trackButtonAngle = 0
        Place()
        assert(Near((Pos()), 75), "a corner shape: not on the rectangle's edge")
        _G.GetMinimapShape = function() error("no") end
        ns.db.trackButtonAngle = 45
        Place()
        x, y = Pos()
        assert(Near(math.sqrt(x * x + y * y), 75), "an erroring shape function: not round")
        _G.GetMinimapShape = function() return 42 end
        Place()
        x, y = Pos()
        assert(Near(math.sqrt(x * x + y * y), 75), "a non-string shape: not round")
        -- above the minimap: strata MEDIUM, level above the minimap's
        assert(btn:GetFrameStrata() == "MEDIUM", "strata: " .. tostring(btn:GetFrameStrata()))
        assert(btn:GetFrameLevel() == Minimap:GetFrameLevel() + 8, "frame level")
        -- in combat nothing moves (a protected frame): the old place stays
        _G.GetMinimapShape = function() return "SQUARE" end
        InCombatLockdown = function() return true end
        Place()
        x, y = Pos()
        assert(Near(math.sqrt(x * x + y * y), 75), "moved in combat")
        InCombatLockdown = saved.combat
        -- after the fight the update places it again
        ns.UpdateTrackButton()
        x, y = Pos()
        assert(Near(x, 75) and Near(y, 75), "not placed after the fight")
    end)
    _G.GetMinimapShape, Minimap.GetWidth, Minimap.GetHeight, ns.db.trackButtonAngle, InCombatLockdown = saved.shape, saved.w, saved.h, saved.angle, saved.combat
    Place()
    if not ok then error(err, 0) end
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
    ns.db.fishMarkBobber = false -- the bobber mark has its own step (v0.1.17)

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
    ns.db.fishMarkBobber = nil
end)
step("Fishing: mark my bobber, and your setting comes back (v0.1.17)", function()
    local saved = { get = GetCVar, set = SetCVar }
    local store
    GetCVar = function(k) return store[k] end
    SetCVar = function(k, v) if store[k] == nil then error("unknown CVar " .. k) end store[k] = tostring(v) return true end
    local function Reset(icon)
        store = { SoftTargetInteract = "3", SoftTargetInteractRange = "30", SoftTargetInteractArc = "2",
            SoftTargetIconGameObject = icon, SoftTargetIconInteract = "1" }
    end
    local function Cast() fire("UNIT_SPELLCAST_CHANNEL_START", "player", "fc", 7620) end
    local function Stop() fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "fc", 7620) advance(1) end
    local fishFrame
    for f in pairs(eventFrames["PLAYER_LOGOUT"] or {}) do
        if eventFrames["UNIT_SPELLCAST_CHANNEL_STOP"] and eventFrames["UNIT_SPELLCAST_CHANNEL_STOP"][f] then fishFrame = f end
    end
    assert(fishFrame, "the fishing code does not listen to PLAYER_LOGOUT")
    ns.db.fishingCVars, ns.db.fishMarkBobber = nil, nil
    -- Sven's values (06.11.): icon over game objects 0, over interact targets 1
    Reset("0") Cast()
    assert(store.SoftTargetIconGameObject == "1", "line out: no mark over the bobber")
    assert(store.SoftTargetIconInteract == "1", "the other icon setting was touched")
    Stop()
    assert(store.SoftTargetIconGameObject == "0", "after the catch: " .. store.SoftTargetIconGameObject)
    assert(ns.db.fishingCVars == nil, "saved entry left after the catch")
    -- logout with the line out: put back right away
    Reset("0") Cast()
    fishFrame.__scripts.OnEvent(fishFrame, "PLAYER_LOGOUT")
    assert(store.SoftTargetIconGameObject == "0" and store.SoftTargetInteractRange == "30", "logout: not put back")
    assert(ns.db.fishingCVars == nil, "saved entry left after logout")
    Stop()
    -- you set it yourself while the line is out: yours stays
    Reset("0") Cast()
    store.SoftTargetIconGameObject = "2"
    Stop()
    assert(store.SoftTargetIconGameObject == "2", "your own change was undone")
    -- already on: nothing to do
    Reset("1") Cast()
    assert(ns.db.fishingCVars == nil, "an icon already on was recorded")
    Stop()
    -- option off: not touched
    ns.db.fishMarkBobber = false
    Reset("0") Cast()
    assert(store.SoftTargetIconGameObject == "0" and ns.db.fishingCVars == nil, "option off, yet the icon was set")
    Stop()
    ns.db.fishMarkBobber = nil
    -- a client without the setting: no error, nothing recorded
    Reset(nil) Cast()
    assert(ns.db.fishingCVars == nil, "a missing setting was recorded")
    Stop()
    GetCVar, SetCVar = saved.get, saved.set
    ns.db.fishingCVars = nil
end)
step("Fishing: Stop shows a summary like a farm run, and its line can be shared (v0.1.17)", function()
    local sent = {}
    SendChatMessage = function(msg, chatType) sent[#sent + 1] = { msg = msg, type = chatType } end
    local card = _G.GathercraftRunSummary
    if card then card:Hide() end
    ns.StopFishing()
    local function Catch()
        fire("UNIT_SPELLCAST_CHANNEL_START", "player", "fs", 7620)
        fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "fs", 7620)
        IsFishingLoot = function() return true end
        loot = { { guid = "GameObject-0-1-1-1-35591-FFFF0" .. math.random(1, 9), item = 6303, qty = 1 } }
        fire("LOOT_READY") loot = {} fire("LOOT_CLOSED")
        IsFishingLoot = nil
        advance(40)
    end
    for _ = 1, 4 do Catch() end
    local f = ns.FishingSession()
    assert(f and f.catches == 4, "test setup: " .. tostring(f and f.catches) .. " catches")
    local panel = _G.GathercraftPanel
    advance(1)
    assert(panel:IsShown() and panel.fishing, "test setup: no fishing panel")
    -- Stop on the panel
    local stop
    for _, b in ipairs(allFrames) do
        if b.__parent == panel and b.__kind == "Button" and b.__text == ns.L["Stop"] then stop = b end
    end
    assert(stop, "no Stop button on the panel")
    stop.__scripts.OnClick(stop)
    card = _G.GathercraftRunSummary
    assert(card and card:IsShown(), "no summary after fishing")
    assert(card.title.__text == ns.L["Fishing done"], "title: " .. tostring(card.title.__text))
    local caught
    for _, fs in ipairs(allFrames) do if fs.__parent == card and fs.__text == ns.L["caught"] then caught = true end end
    assert(caught, "the first number is not called caught")
    assert(ns.FishingSession() == nil, "the session goes on after Stop")
    ns.ShareRunSummary("GUILD")
    assert(#sent == 1 and sent[1].msg:find("^%[Gathercraft%]") and sent[1].msg:find("4", 1, true), "share line: " .. tostring(sent[1] and sent[1].msg))
    assert(GetLocale() ~= "enUS" or sent[1].msg:find("Fishing: 4 catches", 1, true), "not the fishing line: " .. sent[1].msg)
    -- a farm run afterwards gets its own title back
    ns.StartRun("herb") advance(1)
    for _, l in ipairs(ns.gatherListeners) do l({ type = "herb", name = "Peacebloom" }, { value = 1234 }) end
    advance(150)
    ns.StopRun()
    assert(card:IsShown() and card.title.__text == ns.L["Farm run done"], "farm run summary after fishing: " .. tostring(card.title.__text))
    card:Hide()
    -- short or empty sessions: no summary; /gcr stop ends fishing too
    Catch() advance(10)
    slash("stop")
    assert(not card:IsShown(), "summary after a short session")
    assert(ns.FishingSession() == nil, "/gcr stop did not end fishing")
    SendChatMessage = nil
end)
step("Fishing: louder splash while the line is out, your volumes come back exactly (v0.1.17)", function()
    local saved = { get = GetCVar, set = SetCVar }
    local store
    GetCVar = function(k) return store[k] end
    SetCVar = function(k, v) if store[k] == nil then error("unknown CVar " .. k) end store[k] = tostring(v) return true end
    local function Reset()
        store = { SoftTargetInteract = "3", SoftTargetInteractRange = "30", SoftTargetInteractArc = "2", SoftTargetIconGameObject = "1",
            Sound_SFXVolume = "0.4", Sound_MusicVolume = "0.35", Sound_AmbienceVolume = "0.6", Sound_MasterVolume = "0.8" }
    end
    local function Cast() fire("UNIT_SPELLCAST_CHANNEL_START", "player", "fc", 7620) end
    local function Stop() fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "fc", 7620) advance(1) end
    ns.db.fishingCVars = nil
    -- off by default: nothing changes
    Reset() Cast()
    assert(store.Sound_SFXVolume == "0.4" and ns.db.fishingCVars == nil, "off by default, yet a volume changed")
    Stop()
    ns.db.fishLoudSplash = true
    Reset() Cast()
    assert(store.Sound_SFXVolume == "1", "effects not at full volume: " .. store.Sound_SFXVolume)
    assert(tonumber(store.Sound_MusicVolume) == 0.1 and tonumber(store.Sound_AmbienceVolume) == 0.1, "music/ambience not quieter")
    assert(store.Sound_MasterVolume == "0.8", "the master volume was touched")
    Stop()
    assert(store.Sound_SFXVolume == "0.4" and store.Sound_MusicVolume == "0.35" and store.Sound_AmbienceVolume == "0.6",
        ("not put back exactly: %s %s %s"):format(store.Sound_SFXVolume, store.Sound_MusicVolume, store.Sound_AmbienceVolume))
    assert(ns.db.fishingCVars == nil, "saved entry left after the catch")
    -- music already quiet: left alone; you turn music up while fishing: yours stays
    Reset() store.Sound_MusicVolume = "0.05" Cast()
    assert(store.Sound_MusicVolume == "0.05", "quiet music was changed")
    store.Sound_AmbienceVolume = "0.9"
    Stop()
    assert(store.Sound_AmbienceVolume == "0.9" and store.Sound_SFXVolume == "0.4", "your own change was undone, or effects not back")
    ns.db.fishLoudSplash = nil
    GetCVar, SetCVar = saved.get, saved.set
    ns.db.fishingCVars = nil
end)
step("Run window: one slim line or hidden, fishing too, Stop still works (v0.1.17)", function()
    local panel = _G.GathercraftPanel
    local b = panel.compactButton
    assert(b and b.__scripts.OnClick, "no -/+ button on the run window")
    player.map, player.x, player.y = 1412, 0.45, 0.72
    ns.db.panelCompact, ns.db.runPanelHidden, ns.db.fishPanelHidden = nil, nil, nil
    ns.StartRun("herb") advance(2)
    assert(panel:IsShown(), "test setup: no run window")
    b.__scripts.OnClick(b)
    assert(ns.db.panelCompact, "the slim line is not remembered")
    assert(panel.__h <= 40, "not one slim line: height " .. tostring(panel.__h))
    -- title, time, next node: the four numbers and their labels are gone
    local texts = 0
    for _, f in ipairs(allFrames) do
        if f.__parent == panel and f.__kind == "FontString" and f.__shown then texts = texts + 1 end
    end
    assert(texts == 3, texts .. " texts in the slim line, want title, time and next node")
    local stop, skip
    for _, f in ipairs(allFrames) do
        if f.__parent == panel and f.__kind == "Button" then
            if f.__text == ns.L["Stop"] then stop = f elseif f.__text == ns.L["Skip"] then skip = f end
        end
    end
    assert(stop and stop.__shown and skip and skip.__shown, "Stop or Skip missing in the slim line")
    -- texts fit: title and next node cut, not over the buttons
    assert((panel.__w or 0) >= 6 + 20 + 4 + 100 + 6 + 130 + 6 + 52 + 4 + 52 + 4 + 20 + 6, "slim line too narrow for its parts")
    -- remembered after a reload: the layout comes from the saved choice
    ns.PanelLayout()
    assert(panel.__h <= 40, "the slim line is gone after the layout ran again")
    b.__scripts.OnClick(b)
    assert(not ns.db.panelCompact and panel.__h == 120, "+ does not bring the whole panel back")
    -- hidden: the run goes on, the minimap button stops it
    ns.db.runPanelHidden = true
    advance(1)
    assert(not panel:IsShown(), "the run window is shown although it is hidden")
    assert(ns.run, "hiding the window stopped the run")
    ldbObj.OnClick(nil, "RightButton")
    assert(not ns.run, "right-click on the minimap button does not stop the hidden run")
    ns.db.runPanelHidden = nil
    -- fishing window hidden: the session counts on, right-click ends it
    ns.db.fishPanelHidden = true
    fire("UNIT_SPELLCAST_CHANNEL_START", "player", "fh", 7620)
    fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "fh", 7620)
    advance(1)
    assert(ns.FishingSession(), "test setup: no fishing session")
    assert(not panel:IsShown(), "the fishing window is shown although it is hidden")
    ldbObj.OnClick(nil, "RightButton")
    assert(not ns.FishingSession() and not ns.run, "right-click did not end the hidden fishing session (or started a run)")
    ns.db.fishPanelHidden = nil
end)
step("Run window: a long title is cut before the time, the time before the button (v0.1.17)", function()
    -- Sven's find (08.11.): "Farm run  Herbs + Ores · Hillsbrad Foothills" ran
    -- into "0:09" and "-". Here the left and right edges are worked out from
    -- the anchors; a text is as wide as 9 px a letter, 16 px a CJK sign.
    local panel = _G.GathercraftPanel
    local title, clock, b = panel.title, panel.clock, panel.compactButton
    assert(title and clock and panel.nextText, "the run window does not name its title, time and next-node text")
    local function TextWidth(s)
        s = tostring(s or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        local w = 0
        for i = 1, #s do
            local c = s:byte(i)
            if c < 128 or (c >= 192 and c < 224) then w = w + 9 elseif c >= 224 then w = w + 16 end
        end
        return w
    end
    local function Side(p)
        if p:find("LEFT") then return "L" elseif p:find("RIGHT") then return "R" end
        return "C"
    end
    local Edges
    local function At(o, p, a)
        local rel, relPoint, x = a[1], a[2], a[3]
        if type(rel) == "number" or rel == nil then rel, relPoint, x = o.__parent, p, rel end
        if type(rel) == "string" then rel = _G[rel] end
        local l, r = Edges(rel)
        local s = Side(relPoint or p)
        return (s == "L" and l or s == "R" and r or (l + r) / 2) + (x or 0)
    end
    function Edges(o)
        if o == panel then return 0, panel.__w end
        local pts = o.__pts or {}
        local left, right, center
        for p, a in pairs(pts) do
            local s = Side(p)
            if s == "L" then left = At(o, p, a) elseif s == "R" then right = At(o, p, a) else center = At(o, p, a) end
        end
        local w = (o.__w and o.__w > 0) and o.__w or (o.__kind == "FontString" and TextWidth(o.__text)) or 0
        if left and right then return left, right end
        if left then return left, left + w end
        if right then return right - w, right end
        return (center or 0) - w / 2, (center or 0) + w / 2
    end
    local function Button(text)
        for _, f in ipairs(allFrames) do
            if f.__parent == panel and f.__kind == "Button" and f.__text == text and f.__shown then return f end
        end
    end
    local ZONES = { "Hillsbrad Foothills", "Stranglethorn Vale", "Western Plaguelands", "Eastern Plaguelands", "Swamp of Sorrows" }
    local keepZone, keepMode = ns.GetZoneName, ns.db.routeMode
    local fails = {}
    local function Check(what)
        clock:SetText("1:23:45")
        local tl, tr = Edges(title)
        local cl, cr = Edges(clock)
        local nl, nr = Edges(panel.nextText)
        if TextWidth(clock.__text) > cr - cl then fails[#fails + 1] = what .. ": the time is cut" end
        if title.__wrap ~= false then fails[#fails + 1] = what .. ": the title can wrap" end
        if ns.db.panelCompact then
            local right = Button(ns.L["Skip"]) or Button(ns.L["Stop"])
            local bl = Edges(right)
            if not (tr <= nl and nr < cl and cr < bl) then
                fails[#fails + 1] = ("%s: title %d-%d, next %d-%d, time %d-%d, button at %d"):format(what, tl, tr, nl, nr, cl, cr, bl)
            end
        else
            local bl = Edges(b)
            if not (tr < cl and cr < bl) then
                fails[#fails + 1] = ("%s: title ends at %d, time %d-%d, button at %d"):format(what, tr, cl, cr, bl)
            end
        end
    end
    player.map, player.x, player.y = 1412, 0.45, 0.72
    for _, compact in ipairs({ false, true }) do
        ns.db.panelCompact = compact or nil
        ns.PanelLayout()
        for _, mode in ipairs({ "smart", "loop" }) do
            ns.db.routeMode = mode
            for _, filter in ipairs({ "herb", "ore", "both" }) do
                for _, zone in ipairs(ZONES) do
                    ns.GetZoneName = function() return zone end
                    ns.StartRun(filter, 1412) advance(1)
                    if ns.run then ns.run.zone = 1412 end
                    advance(1)
                    if not ns.run then fails[#fails + 1] = ("no run: %s %s"):format(mode, filter) end
                    Check(("%s, %s, %s, %s"):format(compact and "slim" or "full", mode, filter, zone))
                    ns.StopRun(true)
                end
            end
        end
    end
    ns.GetZoneName, ns.db.routeMode = keepZone, keepMode
    -- fishing: the same window, without Skip
    for _, compact in ipairs({ false, true }) do
        ns.db.panelCompact = compact or nil
        ns.PanelLayout()
        fire("UNIT_SPELLCAST_CHANNEL_START", "player", "ft", 7620)
        fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "ft", 7620)
        advance(1)
        Check((compact and "slim" or "full") .. ", fishing")
        ns.StopFishing()
    end
    ns.db.panelCompact = nil
    ns.PanelLayout()
    assert(#fails == 0, #fails .. " wrong: " .. table.concat(fails, " | ", 1, math.min(#fails, 4)))
    -- the whole title as a tooltip when it is cut
    local hit = panel.titleHit
    assert(hit, "no tooltip for a cut title")
    title:SetText("Farm run  Herbs + Ores · Hillsbrad Foothills")
    title.IsTruncated = function() return true end
    local mark = #log
    hit.__scripts.OnEnter(hit)
    local shown
    for i = mark + 1, #log do if log[i]:find("Hillsbrad Foothills", 1, true) then shown = true end end
    title.IsTruncated = nil
    assert(shown, "a cut title has no tooltip with the whole text")
    assert(hit.__scripts.OnDragStart, "the window can't be dragged by its title any more")
end)
step("Run window hidden from the start: the numbers still count from the start (v0.1.17, Codex M1)", function()
    -- Codex's probe: hidden before the run, first gather after 60 s, then
    -- shown and stopped; everything as with the window shown all along
    local panel = _G.GathercraftPanel
    local function Gather() for _, f in ipairs(ns.gatherListeners) do f({ type = "herb", name = "Peacebloom" }, { value = 1234 }) end end
    local function Run(hidden)
        player.map, player.x, player.y = 1412, 0.45, 0.72
        ns.db.runPanelHidden = hidden or nil
        ns.StartRun("herb") advance(60)
        local before = ns.RunSnapshot()
        Gather()
        local after = ns.RunSnapshot()
        ns.db.runPanelHidden = nil
        advance(1)
        local shown = ns.RunSnapshot()
        assert(panel:IsShown(), "test setup: the window did not come back")
        advance(70)
        local card = _G.GathercraftRunSummary
        if card then card:Hide() end
        ns.StopRun()
        return before, after, shown, card and card:IsShown()
    end
    local vb, va, vs, vcard = Run(false)
    local hb, ha, hs, hcard = Run(true)
    assert(vb and va and vs, "test setup: the shown run has no numbers")
    assert(hb, "hidden from the start: no numbers before the first gather")
    assert(ha and math.abs(ha.elapsed - va.elapsed) < 1.5, ("after the first gather: %s s hidden, %s s shown"):format(tostring(ha and ha.elapsed), tostring(va.elapsed)))
    assert(ha.nodes == va.nodes and ha.value == va.value and ha.skill == va.skill, "hidden: other numbers than shown")
    assert(math.abs(hs.elapsed - vs.elapsed) < 1.5, ("shown again: %s s, want %s s"):format(tostring(hs.elapsed), tostring(vs.elapsed)))
    assert(vcard and hcard, ("summary after the run: shown %s, hidden %s"):format(tostring(vcard), tostring(hcard)))
end)
step("Minimap style ring only: the run target is a broad gold ring without an icon (v0.1.17)", function()
    -- Sven's find (08.11.): the target kept its icon and hid the yellow dot
    local list = ns.db.nodes[1412]
    local n = list and list[1]
    assert(n, "test setup: no node on map 1412")
    local keepStyle = ns.db.miniPinStyle
    local function Place(style)
        ns.db.miniPinStyle = style
        ns.ClearRouteTarget()
        ns.SetRouteTarget(1412, n)
        local world, mini = ns.RouteTargetPins()
        return world, mini
    end
    local function Tex(pin) return tostring(pin.ring and pin.ring.__tex or "") end
    local world, mini = Place("subtle")
    assert(mini and mini.icon.__shown ~= false and Tex(mini):find("RingGold$"), "subtle: the target is no longer the icon in a gold ring")
    local subtleSize = mini.__w
    world, mini = Place("normal")
    assert(mini.icon.__shown ~= false and Tex(mini):find("RingGold$"), "normal: the target is no longer the icon in a gold ring")
    world, mini = Place(nil) -- ring only, the default
    assert(mini.icon.__shown == false, "ring only: the target still shows its icon over the tracking dot")
    assert(Tex(mini):find("RingGoldBold$"), "ring only: not the broad gold ring: " .. Tex(mini))
    assert((mini.__w or 0) > (subtleSize or 0), ("ring only: target ring %s px, not bigger than %s"):format(tostring(mini.__w), tostring(subtleSize)))
    assert(world.icon.__shown ~= false and Tex(world):find("RingGold$"), "the world map target changed")
    -- switched in the options while a target is set: it follows
    ns.db.miniPinStyle = "subtle"
    ns.NotifyNodesChanged() advance(1)
    assert(mini.icon.__shown ~= false, "back to subtle: the target icon did not come back")
    ns.db.miniPinStyle = nil
    ns.NotifyNodesChanged() advance(1)
    assert(mini.icon.__shown == false, "to ring only: the target icon stayed")
    ns.ClearRouteTarget()
    ns.db.miniPinStyle = keepStyle
    ns.NotifyNodesChanged() advance(1)
end)
step("Minimap style: ring only is the default, a choice stays (v0.1.17)", function()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    local function rebuild() MINI_ICONS = {} ns.NotifyNodesChanged() advance(1) end
    -- never changed (or subtle, saved as nothing up to 0.1.16): ring only
    ns.db.miniPinStyle = nil
    rebuild()
    assert(ns.MiniPinStyle() == "ring", "ring only is not the default: " .. tostring(ns.MiniPinStyle()))
    local rings, kinds = 0, 0
    for _, pin in ipairs(MINI_ICONS) do
        local n = pin.node
        if n and not n.pendingReport then
            rings = rings + 1
            assert(pin.ringOnly and pin.ring and pin.ring:IsShown(), "a ring-only pin without its ring")
            assert(not pin.icon:IsShown(), "a ring-only pin still shows its icon")
            if not pin.level and pin.ring.__color then kinds = kinds + 1 end
        elseif n and n.pendingReport then
            assert(pin.icon:IsShown() and not pin.ringOnly, "a grey report pin lost its look")
        end
    end
    assert(rings > 0, "test setup: no minimap pins")
    -- world map pins are not touched (the run target has its own step)
    for _, f in ipairs(allFrames) do
        if f.node and not f.isMini and not f.isTarget and f.icon then assert(not f.ringOnly and f.icon:IsShown(), "a world map pin went ring-only") end
    end
    -- your choice stays: normal and subtle, saved by name, with the icon back
    for _, style in ipairs({ "normal", "subtle" }) do
        ns.db.miniPinStyle = style
        rebuild()
        assert(ns.MiniPinStyle() == style, style .. " not kept")
        for _, pin in ipairs(MINI_ICONS) do
            if pin.node then assert(not pin.ringOnly and pin.icon:IsShown(), style .. ": a pin without its icon") end
        end
    end
    -- the options cycle through all three and save the name
    ns.db.miniPinStyle = nil
    local tip = ns.L["Ring only: just a coloured ring, no icon. The yellow dot of the game's herb and mineral tracking shows in the middle."]
    local plus
    for _, f in ipairs(allFrames) do
        if f.__kind == "Button" and f.__text == ">" and f.__scripts.OnEnter then
            local mark = #log
            f.__scripts.OnEnter(f)
            for i = mark + 1, #log do if log[i]:find(tip, 1, true) then plus = f end end
        end
    end
    assert(plus, "options: no > for the minimap style, or its tooltip does not explain ring only")
    plus.__scripts.OnClick(plus)
    assert(ns.db.miniPinStyle == "subtle", "> after ring only: " .. tostring(ns.db.miniPinStyle))
    plus.__scripts.OnClick(plus)
    assert(ns.db.miniPinStyle == "normal", "> after subtle: " .. tostring(ns.db.miniPinStyle))
    plus.__scripts.OnClick(plus)
    assert(ns.db.miniPinStyle == "ring", "> after normal: " .. tostring(ns.db.miniPinStyle))
    ns.db.miniPinStyle = nil
    rebuild()
end)
step("Route line on the minimap: below the pins, a gap at each pin, its own switch (v0.1.17)", function()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    ns.db.routeLineHidden, ns.db.routeLineMiniHidden = nil, nil
    -- a minimap 140 px wide at zoom 0 (466 yd across): 3.33 yd per pixel
    Minimap.GetZoom, Minimap.GetWidth = function() return 0 end, function() return 140 end
    ns.StartRun("herb") advance(2)
    local spots = ns.MinimapPinSpots()
    assert(#spots > 0, "test setup: no minimap pins")
    local ypp = ns.MinimapYardsPerPixel()
    assert(ypp and ypp > 3 and ypp < 3.5, "yards per pixel at zoom 0: " .. tostring(ypp))
    MINI_PTS = {}
    ns.RedrawRouteLine() advance(1)
    assert(#MINI_PTS > 0, "no minimap line")
    -- no dot of the line on or right next to a pin
    local close = 0
    for _, p in ipairs(MINI_PTS) do
        for _, s in ipairs(spots) do
            local dx, dy = p[1] - s.wx, p[2] - s.wy
            if math.sqrt(dx * dx + dy * dy) < (s.px / 2 + 2) * ypp then close = close + 1 end
        end
    end
    assert(close == 0, close .. " minimap line dots on a pin")
    -- the dots lie below the pins
    local dotLevel, pinLevel
    for _, f in ipairs(allFrames) do
        if f.mini == true and f.tex then
            f.__parent = Minimap f.__scripts.OnShow(f) dotLevel = f:GetFrameLevel() break
        end
    end
    for _, pin in ipairs(MINI_ICONS) do
        if pin.node then pin.__parent = Minimap pin.__scripts.OnShow(pin) pinLevel = math.min(pinLevel or 99, pin:GetFrameLevel()) end
    end
    assert(dotLevel and pinLevel and dotLevel < pinLevel, ("line level %s, lowest pin %s"):format(tostring(dotLevel), tostring(pinLevel)))
    -- its own switch: minimap off, world map still drawn; and the other way round
    ns.ToggleRouteLine("mini")
    MINI_PTS, LINE_PTS = {}, {}
    ns.RedrawRouteLine() advance(1)
    assert(#MINI_PTS == 0 and #LINE_PTS > 0, ("minimap off: %d mini, %d world dots"):format(#MINI_PTS, #LINE_PTS))
    ns.ToggleRouteLine("mini") ns.ToggleRouteLine("world")
    MINI_PTS, LINE_PTS = {}, {}
    ns.RedrawRouteLine() advance(1)
    assert(#MINI_PTS > 0 and #LINE_PTS == 0, ("world map off: %d mini, %d world dots"):format(#MINI_PTS, #LINE_PTS))
    ns.ToggleRouteLine("world")
    -- /gcr line: both off, then both on, and it says where the look is set
    local mark = #log
    slash("line")
    assert(ns.db.routeLineHidden and ns.db.routeLineMiniHidden, "/gcr line did not hide both")
    local told
    for i = mark + 1, #log do if log[i]:find(ns.L["Colour and style: Options > Farm runs > Route line."], 1, true) then told = true end end
    assert(told, "/gcr line does not say where colour and style are")
    slash("line")
    assert(not ns.db.routeLineHidden and not ns.db.routeLineMiniHidden, "/gcr line did not show both")
    -- an old "line off" (one switch up to 0.1.16) keeps both off
    ns.db.routeLineHidden, ns.db.routeLineMiniHidden, ns.db.routeLineSplit = true, nil, nil
    ns.MigrateLineSwitch()
    assert(ns.db.routeLineMiniHidden, "old switch off: the minimap line came back")
    ns.db.routeLineMiniHidden = nil
    ns.MigrateLineSwitch()
    assert(not ns.db.routeLineMiniHidden, "migrated twice")
    ns.db.routeLineHidden, ns.db.routeLineMiniHidden = nil, nil
    ns.StopRun(true)
    Minimap.GetZoom, Minimap.GetWidth = nil, nil
end)
step("Minimap looks from a city go to the zone around it; old ones move once (v0.1.17)", function()
    -- a look from Thunder Bluff (1456): the mesa stands in Mulgore (1412);
    -- in this test world the city map is a small part of Mulgore's
    local HBD = LibStub("HereBeDragons-2.0")
    local W, Z, P = HBD.GetWorldCoordinatesFromZone, HBD.GetZoneCoordinatesFromWorld, HBD.GetPlayerWorldPosition
    HBD.GetWorldCoordinatesFromZone = function(s, x, y, map)
        if map == 1456 then return W(s, 0.4 + 0.2 * x, 0.3 + 0.2 * y, 1412) end
        return W(s, x, y, map)
    end
    HBD.GetZoneCoordinatesFromWorld = function(s, wx, wy, map)
        if map == 1456 then local x, y = Z(s, wx, wy, 1412) return (x - 0.4) / 0.2, (y - 0.3) / 0.2 end
        return Z(s, wx, wy, map)
    end
    HBD.GetPlayerWorldPosition = function(s) return HBD.GetWorldCoordinatesFromZone(s, player.x, player.y, player.map) end
    player.map, player.x, player.y = 1456, 0.5, 0.5
    Minimap.GetZoom, Minimap.GetWidth, Minimap.GetHeight = function() return 0 end, function() return 140 end, function() return 140 end
    Minimap.GetCenter, Minimap.GetEffectiveScale = function() return 500, 500 end, function() return 1 end
    local cursor = GetCursorPosition
    GetCursorPosition = function() return 535, 500 end
    local mapID = ns.CursorOnMap()
    GetCursorPosition = cursor
    Minimap.GetZoom, Minimap.GetWidth, Minimap.GetHeight, Minimap.GetCenter, Minimap.GetEffectiveScale = nil, nil, nil, nil, nil
    assert(mapID == 1412, "a look from Thunder Bluff landed on map " .. tostring(mapID))
    -- guesses already on the city map: moved to Mulgore, same spot of the world; harvested ones stay
    ns.db.cityGuessesMoved = nil
    ns.db.nodes[1456] = {
        { id = "o1617", name = "Silverleaf", type = "herb", x = 0.3, y = 0.4, count = 1, seenOnly = true },
        { id = "o1618", name = "Peacebloom", type = "herb", x = 0.6, y = 0.2, count = 3 },
    }
    local before = #(ns.db.nodes[1412] or {})
    local wx, wy = HBD:GetWorldCoordinatesFromZone(0.3, 0.4, 1456)
    local moved = ns.MoveCityGuesses()
    assert(moved == 1, moved .. " moved, want the one guess")
    assert(#ns.db.nodes[1456] == 1 and ns.db.nodes[1456][1].name == "Peacebloom", "the harvested node left the city map")
    local m = ns.db.nodes[1412][#ns.db.nodes[1412]]
    assert(#ns.db.nodes[1412] == before + 1 and m.name == "Silverleaf" and m.movedFrom == 1456, "the guess is not in Mulgore")
    local mx, my = HBD:GetWorldCoordinatesFromZone(m.x, m.y, 1412)
    assert(math.abs(mx - wx) < 0.01 and math.abs(my - wy) < 0.01, "the guess moved in the world")
    assert(ns.MoveCityGuesses() == 0, "moved twice")
    table.remove(ns.db.nodes[1412])
    ns.db.nodes[1456] = nil
    ns.NotifyNodesChanged()
    HBD.GetWorldCoordinatesFromZone, HBD.GetZoneCoordinatesFromWorld, HBD.GetPlayerWorldPosition = W, Z, P
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Nodes on a continent map go to their zone; a gather there too (v0.1.17)", function()
    -- in this test world the continent map 1414 is the same as Barrens (1413) at 0.5..1
    local HBD = LibStub("HereBeDragons-2.0")
    local W, Z = HBD.GetWorldCoordinatesFromZone, HBD.GetZoneCoordinatesFromWorld
    HBD.GetWorldCoordinatesFromZone = function(s, x, y, map)
        if map == 1414 then return W(s, (x - 0.5) * 2, (y - 0.5) * 2, 1413) end
        return W(s, x, y, map)
    end
    HBD.GetZoneCoordinatesFromWorld = function(s, wx, wy, map)
        if map == 1414 then local x, y = Z(s, wx, wy, 1413) return 0.5 + x / 2, 0.5 + y / 2 end
        return Z(s, wx, wy, map)
    end
    local atPos = C_Map.GetMapInfoAtPosition
    C_Map.GetMapInfoAtPosition = function(map, x, y)
        if map == 1414 and x >= 0.5 and y >= 0.5 then return { mapID = 1413, mapType = 3, name = "Zone1413" } end
        if map == 1414 then return { mapID = 1414, mapType = 2 } end -- no zone known there
    end
    ns.db.nodes[1414] = {
        { id = "o2041", name = "Bruiseweed", type = "herb", x = 0.52, y = 0.55, count = 2 },
        { id = "o2042", name = "Kingsblood", type = "herb", x = 0.30, y = 0.20, count = 1 },
    }
    local before = #(ns.db.nodes[1413] or {})
    local wx, wy = HBD:GetWorldCoordinatesFromZone(0.52, 0.55, 1414)
    local moved = ns.MoveContinentNodes()
    assert(moved == 1, moved .. " moved, want the one with a zone")
    assert(#ns.db.nodes[1414] == 1 and ns.db.nodes[1414][1].name == "Kingsblood", "the node without a zone left the continent")
    local m = ns.db.nodes[1413][#ns.db.nodes[1413]]
    assert(#ns.db.nodes[1413] == before + 1 and m.name == "Bruiseweed" and m.movedFrom == 1414, "the node is not in its zone")
    local mx, my = HBD:GetWorldCoordinatesFromZone(m.x, m.y, 1413)
    assert(math.abs(mx - wx) < 0.01 and math.abs(my - wy) < 0.01, "the node moved in the world")
    table.remove(ns.db.nodes[1413])
    ns.db.nodes[1414] = nil
    -- standing there: the game says Kalimdor, the position goes to the zone
    local pos = C_Map.GetPlayerMapPosition
    C_Map.GetPlayerMapPosition = function(map)
        if map == 1413 then return { x = 0.04, y = 0.1, GetXY = function(s) return s.x, s.y end } end
        return pos(map)
    end
    player.map, player.x, player.y = 1414, 0.52, 0.55
    local mapID, x, y = ns.GetPlayerPos()
    assert(mapID == 1413 and x == 0.04 and y == 0.1, ("on the continent: %s %s %s"):format(tostring(mapID), tostring(x), tostring(y)))
    -- no zone there: the continent, as before
    player.x, player.y = 0.3, 0.2
    assert(ns.GetPlayerPos() == 1414, "without a zone the continent position was lost")
    C_Map.GetPlayerMapPosition, C_Map.GetMapInfoAtPosition = pos, atPos
    HBD.GetWorldCoordinatesFromZone, HBD.GetZoneCoordinatesFromWorld = W, Z
    ns.NotifyNodesChanged()
    player.map, player.x, player.y = 1412, 0.45, 0.72
end)
step("Route line length: next 10 points for Smart, the whole round for Loop, or off (v0.1.17)", function()
    player.map, player.x, player.y = 1412, 0.45, 0.72
    ns.db.routeLineHidden, ns.db.routeLineMiniHidden, ns.db.routeLineLength, ns.db.routeMode = nil, nil, nil, nil
    ns.StartRun("herb") advance(2)
    local run = ns.run
    assert(run and run.path and #run.path > 12, "test setup: path of " .. tostring(run and run.path and #run.path))
    local function Dots()
        LINE_PTS = {}
        ns.RedrawRouteLine() advance(1)
        return #LINE_PTS
    end
    -- the line ends near the 10th point: no dot further along than that part
    local function Reach()
        local far = 0
        local p10 = run.path[10]
        for _, p in ipairs(LINE_PTS) do
            local best = math.huge
            for i = 1, 10 do
                local q = run.path[i]
                best = math.min(best, math.sqrt((p[1] - q.wx) ^ 2 + (p[2] - q.wy) ^ 2))
            end
            far = math.max(far, best)
        end
        return far, p10
    end
    assert(ns.RouteLineLength() == "next10", "Smart default: " .. tostring(ns.RouteLineLength()))
    local next10 = Dots()
    local legs = 0
    local px, py = LibStub("HereBeDragons-2.0"):GetPlayerWorldPosition()
    local cx, cy = px, py
    for i = 1, 10 do
        local q = run.path[i]
        legs = math.max(legs, math.sqrt((q.wx - cx) ^ 2 + (q.wy - cy) ^ 2))
        cx, cy = q.wx, q.wy
    end
    assert(next10 > 0 and Reach() <= legs, ("next 10: %d dots, one %.0f yd from the first 10 points"):format(next10, Reach()))
    ns.db.routeLineLength = "all"
    local all = Dots()
    assert(all > next10, ("whole route %d dots, next 10 %d"):format(all, next10))
    ns.db.routeLineLength = "off"
    MINI_PTS = {}
    assert(Dots() == 0 and #MINI_PTS == 0, "off: still a line")
    -- loop: the whole round by default
    ns.db.routeLineLength = nil
    ns.db.routeMode = "loop"
    assert(ns.RouteLineLength() == "all", "Loop default: " .. tostring(ns.RouteLineLength()))
    ns.db.routeMode = nil
    ns.StopRun(true)
end)
step("Crafting: events the client doesn't know are named, not swallowed (R4-H2)", function()
    local mark = #log
    slash("crafttest")
    local said
    for i = mark + 1, #log do if log[i]:find("Crafting events the client doesn't know: none", 1, true) then said = true end end
    assert(said, "/gcr crafttest does not name the events the client doesn't know")
end)
-- Crafting.lua loaded again with this RegisterEvent and these globals,
-- into its own namespace (reads fall back to the real one); returns that
-- namespace and its event frame. The frames of the load are dropped again.
local function ReloadCrafting(register, globals)
    local keep, before = {}, #allFrames
    for k, v in pairs(globals or {}) do keep[k] = _G[k] _G[k] = v end
    local reg = methods.RegisterEvent
    methods.RegisterEvent = function(self, e)
        if not register(e) then error("Attempt to register unknown event \"" .. e .. "\"") end
        return reg(self, e)
    end
    local ns2 = setmetatable({}, { __index = ns })
    local chunk = assert(loadfile(ROOT .. "/Crafting.lua"))
    local ok, err = pcall(chunk, "Gathercraft", ns2)
    methods.RegisterEvent = reg
    for k in pairs(globals or {}) do _G[k] = keep[k] end
    local frame
    for i = before + 1, #allFrames do
        local f = allFrames[i]
        if eventFrames.PLAYER_LOGIN and eventFrames.PLAYER_LOGIN[f] then frame = f end
    end
    local registered = {}
    for e, list in pairs(eventFrames) do
        if frame and list[frame] then registered[e] = true end
        for i = before + 1, #allFrames do list[allFrames[i]] = nil end
    end
    assert(ok, "reload of Crafting.lua: " .. tostring(err))
    assert(frame, "test setup: the event frame of the reload")
    return ns2, frame, registered
end
local function CraftTestLine(ns2)
    local mark = #log
    ns2.CraftTest()
    for i = mark + 1, #log do
        local list = log[i]:match("Crafting events the client doesn't know: (.*)$")
        if list then return list end
    end
end
step("Crafting: an event the client refuses is named by /gcr crafttest and at login (v0.1.18 H2)", function()
    -- the client refuses TRAINER_UPDATE: /gcr crafttest names it, and so does
    -- the debug line at login; everything else is still asked for
    local ns2, frame, registered = ReloadCrafting(function(e) return e ~= "TRAINER_UPDATE" end)
    local list = CraftTestLine(ns2)
    assert(list and list:find("TRAINER_UPDATE", 1, true), "/gcr crafttest: " .. tostring(list))
    assert(not registered.TRAINER_UPDATE and registered.TRAINER_SHOW and registered.MERCHANT_SHOW, "test setup: registrations")
    local wasDebug = ns.db.debug
    ns.db.debug = true
    local mark = #log
    frame.__scripts.OnEvent(frame, "PLAYER_LOGIN")
    ns.db.debug = wasDebug
    local said
    for i = mark + 1, #log do
        if log[i]:find("CRAFT events the client doesn't know: ", 1, true) and log[i]:find("TRAINER_UPDATE", 1, true) then said = true end
    end
    assert(said, "no debug line at login names TRAINER_UPDATE")
    -- a client that takes every event: "none"
    ns2 = ReloadCrafting(function() return true end)
    assert(CraftTestLine(ns2) == "none", "every event taken: " .. tostring(CraftTestLine(ns2)))
end)
step("Crafting: Classic-only events only with the Classic API (v0.1.18)", function()
    -- WoW: Forever has only the modern profession window: no GetNumTradeSkills,
    -- no GetNumCrafts, and the client refuses TRADE_SKILL_UPDATE, CRAFT_SHOW
    -- and CRAFT_UPDATE. They are not asked for there, so the list says "none"
    local classic = { TRADE_SKILL_UPDATE = true, CRAFT_SHOW = true, CRAFT_UPDATE = true }
    local ns2, _, registered = ReloadCrafting(function(e) return not classic[e] end, { GetNumTradeSkills = false, GetNumCrafts = false })
    assert(CraftTestLine(ns2) == "none", "Forever: " .. tostring(CraftTestLine(ns2)))
    assert(registered.TRADE_SKILL_SHOW and registered.TRADE_SKILL_LIST_UPDATE, "the modern events are not asked for")
    -- a Classic client: asked for, and each with its own API
    _, _, registered = ReloadCrafting(function() return true end, { GetNumTradeSkills = function() return 0 end, GetNumCrafts = false })
    assert(registered.TRADE_SKILL_UPDATE and not registered.CRAFT_SHOW and not registered.CRAFT_UPDATE, "trade skills without crafts")
    _, _, registered = ReloadCrafting(function() return true end, { GetNumTradeSkills = false, GetNumCrafts = function() return 0 end })
    assert(registered.CRAFT_SHOW and registered.CRAFT_UPDATE and not registered.TRADE_SKILL_UPDATE, "crafts without trade skills")
    -- the Classic API there, the event refused anyway: still named
    ns2 = ReloadCrafting(function(e) return e ~= "CRAFT_UPDATE" end, { GetNumTradeSkills = false, GetNumCrafts = function() return 0 end })
    assert(CraftTestLine(ns2) == "CRAFT_UPDATE", "a refused Classic event: " .. tostring(CraftTestLine(ns2)))
end)
step("Fishing: Stop with the line still out gives the settings back at once (v0.1.17, Codex M2)", function()
    local saved = { get = GetCVar, set = SetCVar }
    local store
    GetCVar = function(k) return store[k] end
    SetCVar = function(k, v) if store[k] == nil then error("unknown CVar " .. k) end store[k] = tostring(v) return true end
    local function Reset()
        store = { SoftTargetInteract = "3", SoftTargetInteractRange = "30", SoftTargetInteractArc = "2",
            SoftTargetIconGameObject = "0", SoftTargetIconInteract = "1",
            Sound_SFXVolume = "0.4", Sound_MusicVolume = "0.35", Sound_AmbienceVolume = "0.6", Sound_MasterVolume = "0.8" }
    end
    local function Cast() fire("UNIT_SPELLCAST_CHANNEL_START", "player", "fs", 7620) end
    local function LineIn() fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "fs", 7620) advance(1) end
    ns.db.fishingCVars, ns.db.fishMarkBobber, ns.db.fishLoudSplash = nil, nil, true
    -- Codex's probe: mark 0, effects 0.4; cast, then Stop with the line out
    Reset() Cast()
    assert(store.SoftTargetIconGameObject == "1" and store.Sound_SFXVolume == "1", "test setup: nothing set for the cast")
    ns.StopFishing(true)
    assert(store.SoftTargetIconGameObject == "0" and store.Sound_SFXVolume == "0.4" and store.Sound_MusicVolume == "0.35"
        and store.Sound_AmbienceVolume == "0.6", ("Stop with the line out: mark %s, effects %s, music %s"):format(
        store.SoftTargetIconGameObject, store.Sound_SFXVolume, store.Sound_MusicVolume))
    assert(ns.db.fishingCVars == nil, "Stop left saved values behind")
    assert(not ns.FishingSession(), "Stop did not end the session")
    -- the end of the cast afterwards: nothing set again, nothing put back twice
    store.Sound_SFXVolume = "0.5" -- you turn it up after Stop
    LineIn()
    assert(store.SoftTargetIconGameObject == "0" and store.Sound_SFXVolume == "0.5", "the end of the cast changed values after Stop")
    -- you change one while the line is out: yours stays, the others come back
    Reset() Cast()
    store.Sound_SFXVolume = "0.7"
    ns.StopFishing(true)
    assert(store.Sound_SFXVolume == "0.7", "your own change was undone by Stop")
    assert(store.SoftTargetIconGameObject == "0" and store.Sound_MusicVolume == "0.35", "the other values did not come back")
    LineIn()
    assert(store.Sound_SFXVolume == "0.7" and ns.db.fishingCVars == nil, "the end of the cast undid your change")
    GetCVar, SetCVar = saved.get, saved.set
    ns.db.fishingCVars, ns.db.fishLoudSplash = nil, nil
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
    -- since 0.1.19 a window (Q5); a version without an entry: the chat line
    local newsWin = _G.GathercraftWhatsNew
    assert((newsWin and newsWin:IsShown()) or said("CurseForge"), "/gcr whatsnew says nothing")
    if newsWin then newsWin:Hide() end
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
step("What's new: 0.1.20 after an update, in this language and all translations", function()
    local version = toc:match("## Version: ([%d%.]+)")
    assert(version == "0.1.20", "TOC version: " .. tostring(version))
    assert(toc:match("## Interface: (%d+)") == "16001", "TOC interface changed")
    local f = assert(io.open(ROOT .. "/Welcome.lua"))
    local src = f:read("*a") f:close()
    local key = src:match('%["0%.1%.20"%] = "([^"]+)"')
    assert(key and key:find("square minimap", 1, true) and key:find("Create All", 1, true) and key:find("green threshold", 1, true),
        "no entry for 0.1.20 in Welcome.lua")
    -- the 0.1.19 entry stays for players who skip a version
    assert(src:match('%["0%.1%.19"%] = "([^"]+)"'), "the 0.1.19 entry is gone")
    -- README and CHANGELOG say it
    local rf = assert(io.open(ROOT .. "/README.md"))
    local readme = rf:read("*a") rf:close()
    assert(readme:find("Questing mode – gather along the way", 1, true) and readme:find("`/gcr quest`", 1, true), "README: no questing mode")
    local cf = assert(io.open(ROOT .. "/CHANGELOG.md"))
    local changelog = cf:read("*a") cf:close()
    assert(changelog:find("^## v0%.1%.20") and not changelog:find("v0.1.19", 1, true), "CHANGELOG: not 0.1.20 only")
    assert(changelog:find("square minimap", 1, true) and changelog:find("Create All", 1, true) and changelog:find("yellow/green", 1, true), "CHANGELOG: K1-K3 missing")
    -- every translation is there, whatever language this run is in
    for _, code in ipairs({ "deDE", "esES", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
        local t = ns.Locales[code] and ns.Locales[code][key]
        assert(type(t) == "string" and t ~= "" and t ~= key, "no translation in " .. code)
    end
    local function said(text)
        for _, l in ipairs(log) do if l:find(text, 1, true) then return l end end
    end
    local function clear() for i in ipairs(log) do log[i] = "" end end
    local keepMeta, keepVersion, keepFresh = C_AddOns.GetAddOnMetadata, ns.db.lastVersion, ns.freshInstall
    local ok, err = pcall(function()
        C_AddOns.GetAddOnMetadata = function() return version end
        ns.freshInstall = false
        local text = ns.L[key]
        assert(LOCALE == "enUS" or text ~= key, "English text in " .. LOCALE)
        -- the login after the update shows it once, in this language
        -- (since 0.1.19 in its own window, Q5)
        local win = _G.GathercraftWhatsNew
        if win then win:Hide() end
        ns.db.lastVersion = "0.1.19"
        ns.WelcomeOnLogin()
        win = _G.GathercraftWhatsNew
        assert(win and win:IsShown() and win.body:GetText() == text and win.title:GetText():find(version, 1, true),
            "no what's new at the login after the update")
        assert(ns.db.lastVersion == version, "the new version is not remembered")
        note("what's new", win.body:GetText())
        win:Hide()
        ns.WelcomeOnLogin()
        assert(not win:IsShown(), "what's new again on the next login")
        slash("whatsnew")
        assert(win:IsShown() and win.body:GetText() == text, "/gcr whatsnew does not show it")
        win:Hide()
    end)
    C_AddOns.GetAddOnMetadata, ns.db.lastVersion, ns.freshInstall = keepMeta, keepVersion, keepFresh
    if not ok then error(err, 0) end
end)

step("What's new: a window with a box \"Coming next\", once per update, /gcr news (v0.1.19 Q5)", function()
    local L = ns.L
    local keep = { meta = C_AddOns.GetAddOnMetadata, last = ns.db.lastVersion, fresh = ns.freshInstall, height = methods.GetStringHeight }
    local version = toc:match("## Version: ([%d%.]+)")
    local ok, err = pcall(function()
        C_AddOns.GetAddOnMetadata = function() return version end
        ns.freshInstall = false
        -- the texts are their own keys, translated
        local f = assert(io.open(ROOT .. "/Welcome.lua"))
        local src = f:read("*a") f:close()
        local coming = src:match('local COMING_NEXT = "([^"]+)"')
        local feedback = src:match('local FEEDBACK = "([^"]+)"')
        assert(coming and feedback, "no COMING_NEXT / FEEDBACK key in Welcome.lua")
        assert(coming:find("Skill plan 2.0", 1, true) and not coming:find("%d%d%d%d") and not coming:lower():find("soon", 1, true), "Coming next: " .. coming)
        for _, key in ipairs({ coming, feedback, "Coming next", "What's new in %s" }) do
            for _, code in ipairs({ "deDE", "esES", "frFR", "itIT", "koKR", "ptBR", "ruRU", "zhCN", "zhTW" }) do
                local tr = ns.Locales[code] and ns.Locales[code][key]
                assert(type(tr) == "string" and tr ~= "" and tr ~= key, ("no %s translation of %q"):format(code, key))
            end
        end
        -- the login after an update: the window, once
        local win = _G.GathercraftWhatsNew
        if win then win:Hide() end
        methods.GetStringHeight = TextHeight -- room for the text, as the game would wrap it (estimate)
        ns.db.lastVersion = "0.0.1"
        ns.WelcomeOnLogin()
        win = _G.GathercraftWhatsNew
        assert(win and win:IsShown(), "no window after the update")
        local box = win.box
        assert(box and box:IsShown() ~= false, "no box Coming next")
        assert(box.head:GetText() == L["Coming next"] and box.line:GetText() == L[coming] and box.feedback:GetText() == L[feedback],
            "the box does not say what comes next: " .. tostring(box.line:GetText()))
        -- set apart below the text, everything inside the window, nothing on top of another
        local bodyBottom = 70 + TextHeight(win.body)
        local boxTop = -box.__pts.TOPLEFT[4]
        assert(boxTop >= bodyBottom + 8, ("the box (from %d px) runs into the text (down to %d px)"):format(boxTop, bodyBottom))
        local inBox = 10 + 16 + 5 + TextHeight(box.line) + 8 + TextHeight(box.feedback)
        assert(box.__h >= inBox + 8, ("the box is %d px for %d px of text"):format(box.__h, inBox))
        local buttonTop = win.__h - 20 - 24
        assert(boxTop + box.__h + 8 <= buttonTop, ("the box (to %d px) runs into the button (from %d px)"):format(boxTop + box.__h, buttonTop))
        assert(win.__h <= 560, "the window is too high: " .. win.__h)
        note("what's new window", LOCALE, win.__h .. " px high")
        win:Hide()
        -- not again on the next login
        ns.WelcomeOnLogin()
        assert(not win:IsShown(), "the window again without an update")
        -- /gcr news and /gcr whatsnew bring it back
        slash("news")
        assert(win:IsShown(), "/gcr news does not show it")
        win:Hide()
        slash("whatsnew")
        assert(win:IsShown(), "/gcr whatsnew does not show it")
        -- Got it closes it
        win.ok.__scripts.OnClick(win.ok)
        assert(not win:IsShown(), "Got it does not close it")
        -- the help names /gcr news
        local mark = #log
        slash("help")
        local said = false
        for i = mark + 1, #log do if log[i]:find("/gcr news", 1, true) then said = true end end
        assert(said, "/gcr help does not name /gcr news")
    end)
    C_AddOns.GetAddOnMetadata, ns.db.lastVersion, ns.freshInstall, methods.GetStringHeight = keep.meta, keep.last, keep.fresh, keep.height
    if _G.GathercraftWhatsNew then _G.GathercraftWhatsNew:Hide() end
    if not ok then error(err, 0) end
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
        -- the fishing code listens to both too (v0.1.17): not that one
        if eventFrames["PLAYER_LOGIN"][f] and not (eventFrames["UNIT_SPELLCAST_CHANNEL_STOP"] or {})[f] then loader = f end
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
step("Recorder: a spell cast on a target before a gather leaves the gather alone", function()
    -- seen on the live server (05.11.): Mark of the Wild on yourself, then a
    -- Silverleaf: "fits 2 gathers, all dropped", no pin, no count
    local W = IdentityWorld()
    local BUFF, MAUL, HERB, ORE = 5232, 6807, 2366, 2575
    local wasDebug, mark = ns.db.debug, #log
    ns.db.debug = true
    ns.db.gatherSpells = ns.db.gatherSpells or {}
    W.Set({})
    W.At(-200) ns.StartRun("both", 1412) W.Wait(1)
    assert(ns.RunSnapshot(), "test setup: no run")
    local fails = {}
    local function Check(ok, text) if not ok then fails[#fails + 1] = text end end
    local function Booked(tag)
        for _, n in ipairs(ns.db.nodes[1412]) do if n.lastSpawn == tag then return n end end
    end
    local function Said(text)
        for i = mark + 1, #log do if log[i]:find(text, 1, true) then return true end end
    end
    local function Spell(target, spell) local c = W.Cast(target, spell) W.Done(c, spell) end
    local function MobLoot(source)
        loot = { { guid = source or "Creature-0-1-1-1-3099-EEEE", item = 769, qty = 1 } }
        fire("LOOT_READY") fire("LOOT_OPENED")
        loot = {}
        fire("LOOT_CLOSED")
    end
    local function Pick(name, spell, object, item, tag)
        local c = W.Cast(name, spell) W.Wait(2) W.Done(c, spell)
        W.Loot(object, item, tag) W.Loot(object, item, tag, "LOOT_OPENED")
    end
    local at = 0
    -- one case on its own spot; what is left of it has run out afterwards
    local function Case(what, tag, expected, fn)
        at = at + 300
        W.At(at)
        mark = #log
        local s0, v0 = ns.RunSnapshot(), ns.SessionValue()
        fn()
        W.Wait(12)
        local s1, v1 = ns.RunSnapshot(), ns.SessionValue()
        local booked = tag and Booked(tag) ~= nil
        if expected then
            Check(booked, what .. ": no RECORD, no pin")
            Check(s1.nodes == s0.nodes + 1, ("%s: run counter +%d"):format(what, s1.nodes - s0.nodes))
            Check(s1.value > s0.value and v1 > v0, what .. ": no value booked")
            Check(not Said("can't tell whose"), what .. ": called ambiguous")
            Check(not Said("DROPPED gather"), what .. ": dropped")
        else
            Check(not booked, what .. ": booked")
            Check(s1.nodes == s0.nodes and s1.value == s0.value and v1 == v0, what .. ": counted")
        end
        Check(not ns.db.gatherSpells[BUFF] and not ns.db.gatherSpells[MAUL], what .. ": a combat spell was learned")
    end

    Case("buff, then herb", "VB0001", true, function()
        Spell("Druid Lawl", BUFF) Pick("Silverleaf", HERB, 1617, 765, "VB0001")
    end)
    Case("buff, then the other Silverleaf object", "VB0002", true, function()
        Spell("Druid Lawl", BUFF) Pick("Silverleaf", HERB, 3725, 765, "VB0002")
    end)
    Case("buff, then ore", "VB0003", true, function()
        Spell("Druid Lawl", BUFF) Pick("Copper Vein", ORE, 1731, 2770, "VB0003")
    end)
    Case("buff between the herb and its loot", "VB0004", true, function()
        local c = W.Cast("Silverleaf", HERB) W.Wait(2) W.Done(c, HERB)
        Spell("Druid Lawl", BUFF)
        W.Loot(1617, 765, "VB0004") W.Loot(1617, 765, "VB0004", "LOOT_OPENED")
    end)
    Case("three attacks, mob loot, then herb", "VB0005", true, function()
        for _ = 1, 3 do Spell("Sunscale Screecher", MAUL) W.Wait(1) end
        MobLoot()
        Pick("Silverleaf", HERB, 1617, 765, "VB0005")
    end)
    -- no gather at all: the mob's loot, an item's loot, a window without an object
    Case("attack, mob loot alone", nil, false, function()
        Spell("Sunscale Screecher", MAUL) W.Wait(1) MobLoot()
    end)
    Check(not Said("can't tell whose") and not Said("does not fit"), "mob loot alone: named as a gather's loot")
    Case("attacks, mob loot alone", nil, false, function()
        for _ = 1, 3 do Spell("Sunscale Screecher", MAUL) W.Wait(1) end
        MobLoot()
    end)
    Check(not Said("can't tell whose"), "mob loot after three attacks: called ambiguous")
    Case("buff, item loot", nil, false, function()
        Spell("Druid Lawl", BUFF) MobLoot("Item-0-1-1-1-AAAA")
    end)
    Case("buff, loot of an object nobody knows", nil, false, function()
        Spell("Druid Lawl", BUFF) W.Loot(7999999, 769, "VB0006")
    end)
    Check(not Booked("VB0006"), "a guess took the loot of an unknown object")

    -- still as before: an unknown spell alone on a known object is learned
    Case("unknown spell alone", "VB0007", true, function()
        Pick("Silverleaf", 999003, 1617, 765, "VB0007")
    end)
    Check(ns.db.gatherSpells[999003] == "herb", "unknown gather spell not learned")
    ns.db.gatherSpells[999003] = nil
    -- still as before: a real gather needs no guess out of the way when two
    -- real ones can't be told apart: both dropped, with or without a guess
    Case("two herb casts before the loot", "VB0008", false, function()
        local a = W.Cast("Silverleaf", HERB) W.Wait(2) W.Done(a, HERB)
        local b = W.Cast("Silverleaf", HERB) W.Wait(2) W.Done(b, HERB)
        W.Loot(1617, 765, "VB0008")
    end)
    Check(Said("can't tell whose"), "two herb casts: not called ambiguous")
    Case("two herb casts and a buff before the loot", "VB0009", false, function()
        local a = W.Cast("Silverleaf", HERB) W.Wait(2) W.Done(a, HERB)
        local b = W.Cast("Silverleaf", HERB) W.Wait(2) W.Done(b, HERB)
        Spell("Druid Lawl", BUFF)
        W.Loot(1617, 765, "VB0009")
    end)
    -- two guesses on a known object: nobody learned, and they don't block the next gather
    Case("two guesses, then herb", "VB0011", true, function()
        Spell("Druid Lawl", BUFF) Spell("Druid Lawl", MAUL)
        W.Loot(1617, 765, "VB0010") mark = #log
        Pick("Silverleaf", HERB, 1617, 765, "VB0011")
    end)

    ns.db.debug = wasDebug
    W.Restore()
    assert(#fails == 0, table.concat(fails, " | "))
end)
step("Recorder: a spell is learned only when its own target named the object (v0.1.16)", function()
    -- Codex B1: a buff or attack must never become a gathering spell. The
    -- loot of a known object alone is no proof: the cast's target has to name it
    local W = IdentityWorld()
    local BUFF, HERB = 5232, 2366
    local wasDebug, mark = ns.db.debug, #log
    local keepSpells = ns.db.gatherSpells
    ns.db.debug, ns.db.gatherSpells = true, {}
    W.Set({})
    local fails = {}
    local function Check(ok, text) if not ok then fails[#fails + 1] = text end end
    local function Said(text)
        for i = mark + 1, #log do if log[i]:find(text, 1, true) then return true end end
    end
    local function Booked(tag)
        for _, n in ipairs(ns.db.nodes[1412]) do if n.lastSpawn == tag then return n end end
    end
    local function Spell(target, spell) local c = W.Cast(target, spell) W.Done(c, spell) end
    local function Pick(name, spell, object, item, tag)
        local c = W.Cast(name, spell) W.Wait(2) W.Done(c, spell)
        W.Loot(object, item, tag) W.Loot(object, item, tag, "LOOT_OPENED")
    end
    local at = 0
    local function Case(fn)
        at = at + 300
        W.At(at)
        mark = #log
        fn()
        W.Wait(12)
    end

    -- probe A: the object's loot opens once more after the buff
    Case(function()
        Pick("Silverleaf", HERB, 1617, 765, "LB0001") W.Wait(12)
        Spell("Druid Lawl", BUFF)
        W.Loot(1617, 765, "LB0001", "LOOT_OPENED")
    end)
    Check(not ns.db.gatherSpells[BUFF], "probe A: the buff was learned")
    Check(Said("GUESS not learned: spell 5232 target=Druid Lawl object=1617"), "probe A: no debug line")
    -- probe B: the herb cast names Silverleaf, the loot is a Peacebloom
    Case(function()
        Spell("Druid Lawl", BUFF)
        local c = W.Cast("Silverleaf", HERB) W.Wait(2) W.Done(c, HERB)
        W.Loot(1618, 2447, "LB0002")
    end)
    Check(not ns.db.gatherSpells[BUFF], "probe B: the buff was learned")
    Check(Said("GUESS not learned: spell 5232 target=Druid Lawl object=1618"), "probe B: no debug line")
    -- probe C: mob loot first, then known loot with no gather spell seen
    Case(function()
        Spell("Druid Lawl", BUFF)
        loot = { { guid = "Creature-0-1-1-1-3099-EEEE", item = 769, qty = 1 } }
        fire("LOOT_READY") loot = {}
        W.Wait(1)
        W.Loot(1617, 765, "LB0003")
    end)
    Check(not ns.db.gatherSpells[BUFF], "probe C: the buff was learned")
    Check(Said("GUESS not learned: spell 5232 target=Druid Lawl object=1617"), "probe C: no debug line")
    -- the target names another herb than the loot's
    Case(function() Pick("Peacebloom", 999004, 1617, 765, "LB0004") end)
    Check(not ns.db.gatherSpells[999004], "another herb's name: learned")
    Check(Booked("LB0004"), "another herb's name: the gather itself is gone")
    -- only a tooltip named it: the mouse can rest on a herb during any cast
    local keepShown, keepOwner, keepLine = GameTooltip.IsShown, GameTooltip.GetOwner, _G.GameTooltipTextLeft1
    GameTooltip.IsShown = function() return true end
    GameTooltip.GetOwner = function() return nil end
    _G.GameTooltipTextLeft1 = { GetText = function() return "Silverleaf" end }
    Case(function() Pick("", 999005, 1617, 765, "LB0005") end)
    GameTooltip.IsShown, GameTooltip.GetOwner, _G.GameTooltipTextLeft1 = keepShown, keepOwner, keepLine
    Check(not ns.db.gatherSpells[999005], "tooltip only: learned")
    Check(Booked("LB0005"), "tooltip only: the gather itself is gone")
    -- still learned: the target names the object, in English or the client's language
    Case(function() Pick("Silverleaf", 999006, 1617, 765, "LB0006") end)
    Check(ns.db.gatherSpells[999006] == "herb", "a real unknown herb spell: not learned")
    Check(Booked("LB0006"), "a real unknown herb spell: not booked")
    Case(function() Pick("Copper Vein", 999007, 1731, 2770, "LB0007") end)
    Check(ns.db.gatherSpells[999007] == "ore", "a real unknown ore spell: not learned")
    Case(function() Pick(ns.KindNameFor(3725), 999008, 3725, 765, "LB0008") end)
    Check(ns.db.gatherSpells[999008] == "herb", "the object's name in the client's language: not learned")
    -- chests as before: booked, never learned
    Case(function() Pick("Battered Chest", 999009, 2843, 769, "LB0009") end)
    Check(not ns.db.gatherSpells[999009], "a chest spell was learned")
    Check(Booked("LB0009"), "the chest was not booked")

    ns.db.debug, ns.db.gatherSpells = wasDebug, keepSpells
    W.Restore()
    assert(#fails == 0, table.concat(fails, " | "))
end)
step("Recorder: spells learned by older versions are dropped once (v0.1.16)", function()
    local keepSpells, keepVersion, keepFresh = ns.db.gatherSpells, ns.db.gatherSpellsVersion, ns.freshInstall
    ns.db.gatherSpells, ns.db.gatherSpellsVersion = { [5232] = "herb", [6807] = "ore" }, nil
    fire("ADDON_LOADED", "Gathercraft")
    assert(not (ns.db.gatherSpells and next(ns.db.gatherSpells)), "old learned spells kept")
    assert(ns.db.gatherSpellsVersion == 2, "no version mark set")
    -- only once: what the new rule learns stays
    ns.db.gatherSpells = { [999010] = "herb" }
    fire("ADDON_LOADED", "Gathercraft")
    assert(ns.db.gatherSpells[999010] == "herb", "a spell learned under the new rule was dropped")
    ns.db.gatherSpells, ns.db.gatherSpellsVersion, ns.freshInstall = keepSpells, 2, keepFresh
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
-- The character's professions for a test: fn as GetProfessions, then the game says so
local function ProfessionTest()
    local T = { keep = { GetProfessions, GetNumSkillLines, GetSkillLineInfo }, nodes = ns.db.nodes[player.map], map = player.map }
    function T.Both() return 1, 2, nil, 4, nil, nil end
    function T.Herb() return 1, nil, nil, 4, nil, nil end
    function T.Ore() return nil, 2, nil, 4, nil, nil end
    function T.None() return nil, nil, nil, 4, nil, nil end
    function T.Set(fn) GetProfessions = fn fire("SKILL_LINES_CHANGED") advance(2) end
    function T.Login(fn) GetProfessions = fn ns.WatchGatherProfessions() advance(2) end
    function T.Settle() advance(6) end
    function T.Restore()
        if ns.run then ns.StopRun(true) end
        GetProfessions, GetNumSkillLines, GetSkillLineInfo = T.keep[1], T.keep[2], T.keep[3]
        ns.WatchGatherProfessions() advance(7)
        ns.db.nodes[T.map] = T.nodes
        ns.db.noProfessionHint = nil
        ns.NotifyNodesChanged() advance(2)
    end
    return T
end
step("Pins: only what your professions can gather (v0.1.16)", function()
    local T = ProfessionTest()
    local M = player.map
    local HINT = "No gathering profession: herb and ore pins are hidden. To show them, untick \"Only show nodes my professions can gather\" in Options, Map & minimap."
    for lang, d in pairs(ns.Locales) do
        for _, key in ipairs({ "Only show nodes my professions can gather", HINT }) do
            assert(d[key] and d[key] ~= key, lang .. ": not translated: " .. key)
        end
    end
    local herb = { id = "o1617", name = "Silverleaf", type = "herb", x = 0.41, y = 0.5, count = 1, last = 1, item = 765 }
    local ore = { id = "o1731", name = "Copper Vein", type = "ore", x = 0.43, y = 0.5, count = 1, last = 1, item = 2770 }
    local chest = { id = "o2843", name = "Battered Chest", type = "chest", x = 0.45, y = 0.5, count = 1, last = 1 }
    ns.db.nodes[M] = { herb, ore, chest }
    ns.db.noProfessionHint = nil
    local pins = LibStub("HereBeDragons-Pins-2.0")
    local addWorld, addMini = pins.AddWorldMapIconMap, pins.AddMinimapIconMap
    local world, mini = {}, {}
    pins.AddWorldMapIconMap = function(self, ref, frame, mapID, x, y, ...)
        if mapID == M then world[x] = true end
        return addWorld(self, ref, frame, mapID, x, y, ...)
    end
    pins.AddMinimapIconMap = function(self, ref, icon, mapID, x, y, ...)
        if mapID == M then mini[x] = true end
        return addMini(self, ref, icon, mapID, x, y, ...)
    end
    local function Clear() world, mini = {}, {} end
    local function Redraw() Clear() ns.NotifyNodesChanged() advance(2) end
    local fails = {}
    local function Check(ok, text) if not ok then fails[#fails + 1] = text end end
    local function Shows(what, h, o)
        for name, seen in pairs({ map = world, minimap = mini }) do
            Check((seen[herb.x] or false) == h, ("%s: %s herb %s"):format(what, name, tostring(seen[herb.x])))
            Check((seen[ore.x] or false) == o, ("%s: %s ore %s"):format(what, name, tostring(seen[ore.x])))
            Check(seen[chest.x] == true, ("%s: %s chest gone"):format(what, name))
        end
    end
    local mark = #log
    local function Hints()
        local c = 0
        for i = mark + 1, #log do if log[i]:find(ns.L[HINT], 1, true) then c = c + 1 end end
        return c
    end

    local ok, err = pcall(function()
    -- learned or unlearned: the pins follow on their own, no /reload
    T.Login(T.Both) T.Settle() Redraw() Shows("both", true, true)
    Clear() T.Set(T.Herb) Shows("Herbalism only", true, false)
    Clear() T.Set(T.Ore) Shows("Mining only", false, true)
    Clear() T.Set(T.Both) Shows("Mining and Herbalism again", true, true)
    Check(Hints() == 0, "a hint with professions")
    -- none: no pins, one line, once
    Clear() T.Set(T.None) Shows("no profession", false, false)
    Check(Hints() == 1, ("no profession: %d hints"):format(Hints()))
    T.Set(T.Herb) T.Set(T.None)
    T.Login(T.None) T.Settle()
    Check(Hints() == 1, ("no profession again: %d hints"):format(Hints()))
    -- the option off: all of them, and no hint
    ns.db.allGatherPins = true
    Redraw() Shows("option off", true, true)
    ns.db.noProfessionHint = nil
    T.Login(T.None) T.Settle()
    Check(Hints() == 1, "option off: a hint")
    ns.db.allGatherPins = nil
    -- both filters: the Zones tab hides what you could gather, professions hide what it leaves
    T.Set(T.Ore)
    ns.db.mapFollowsZones = true
    Redraw() Shows("Mining, Zones filter on, zone ticked", false, true)
    ns.db.disabledZones[M] = true
    Clear() ns.NotifyNodesChanged() advance(2)
    Check(not world[ore.x] and not mini[ore.x], "Mining, its zone unticked: ore still shown")
    ns.db.disabledZones[M] = nil
    ns.db.mapFollowsZones = nil
    -- not known yet after login: everything as before
    ns.db.noProfessionHint = nil
    mark = #log
    T.Login(function() end)
    Redraw() Shows("just logged in", true, true)
    Check(select(3, ns.GatherProfessions()) == false, "known right after login")
    Check(Hints() == 0, "a hint right after login")
    -- still nothing from either source after the wait: not known, as in 0.1.15
    Clear() T.Settle()
    Check(select(3, ns.GatherProfessions()) == false, "nothing read, yet known after the wait")
    Redraw() Shows("nothing read after the wait", true, true)
    Check(Hints() == 0, "a hint with nothing read")
    -- a character without any profession: the full skill list shows it
    local full = { { "Class Skills", true, true }, { "Defense", false, nil, 5, nil, 0, 5 } }
    GetNumSkillLines = function() return #full end
    GetSkillLineInfo = function(i) return unpack(full[i]) end
    Clear() T.Set(function() end)
    Check(select(3, ns.GatherProfessions()) == true, "the full skill list not believed")
    Shows("settled, no profession", false, false)
    -- the old skill list: empty = not sent yet, a collapsed header may hide them
    GetNumSkillLines = function() return 0 end
    T.Login(nil) T.Settle()
    Check(select(3, ns.GatherProfessions()) == false, "an empty skill list counts as known")
    local lines = { { "Professions", true, false } }
    GetNumSkillLines = function() return #lines end
    GetSkillLineInfo = function(i) return unpack(lines[i]) end
    T.Login(nil) T.Settle()
    Check(select(3, ns.GatherProfessions()) == false, "a collapsed header counts as known")
    lines = { { "Professions", true, true }, { "Herbalism", false, nil, 50, nil, 0, 75 } }
    T.Set(nil)
    local h, o, known = ns.GatherProfessions()
    Check(known and h and not o, "the old skill list: Herbalism not read")
    -- collapsing the header later changes nothing
    lines = { { "Professions", true, false } }
    T.Set(nil)
    h, o, known = ns.GatherProfessions()
    Check(known and h and not o, "a header collapsed later: forgotten")
    end)
    pins.AddWorldMapIconMap, pins.AddMinimapIconMap = addWorld, addMini
    ns.db.mapFollowsZones, ns.db.allGatherPins, ns.db.disabledZones[M] = nil, nil, nil
    T.Restore()
    assert(ok, err)
    assert(#fails == 0, table.concat(fails, " | "))
end)
step("Right-click: no farm run without a gathering profession (v0.1.16)", function()
    local T = ProfessionTest()
    local TEXT = "Learn Herbalism or Mining from a trainer to start a farm run."
    for lang, d in pairs(ns.Locales) do
        assert(d[TEXT] and d[TEXT] ~= TEXT, lang .. ": not translated")
    end
    local list = {}
    for i = 1, 10 do
        list[i] = { id = "o1617", name = "Silverleaf", type = "herb", x = 0.4 + i / 100, y = 0.5, count = 1, last = 1, item = 765 }
    end
    ns.db.nodes[player.map] = list
    ns.db.noProfessionHint = true
    ns.NotifyNodesChanged() advance(2)
    local mark = #log
    local function Said()
        for i = mark + 1, #log do if log[i]:find(ns.L[TEXT], 1, true) then return true end end
    end
    local ok, err = pcall(function()
        -- known, none there: no run, one friendly line
        T.Login(T.None) T.Settle()
        ns.StartHereRun() advance(1)
        assert(not ns.run, "a run without a profession")
        assert(Said(), "no line about the trainer")
        -- the Overview buttons name what they farm: as before
        mark = #log
        ns.StartHereRun("herb") advance(1)
        assert(ns.run and not Said(), "the Herbs button stopped working")
        ns.StopRun(true)
        -- right after login, not known yet: as before
        T.Login(function() end)
        ns.StartHereRun() advance(1)
        assert(ns.run and not Said(), "no run while the professions are unknown")
        ns.StopRun(true)
        -- with a profession: as before
        T.Login(T.Herb) T.Settle()
        ns.StartHereRun() advance(1)
        assert(ns.run and not Said(), "no run with Herbalism")
    end)
    T.Restore()
    assert(ok, err)
end)
step("Professions: \"none\" only from a sure read (v0.1.16)", function()
    local T = ProfessionTest()
    local keepLocale, keepInfo, keepDebug = GetLocale, GetProfessionInfo, ns.Debug
    local HINT = "No gathering profession: herb and ore pins are hidden. To show them, untick \"Only show nodes my professions can gather\" in Options, Map & minimap."
    local TRAINER = "Learn Herbalism or Mining from a trainer to start a farm run."
    local herb, ore = { type = "herb" }, { type = "ore" }
    local list = {}
    for i = 1, 10 do
        list[i] = { id = "o1617", name = "Silverleaf", type = "herb", x = 0.4 + i / 100, y = 0.5, count = 1, last = 1, item = 765 }
    end
    ns.db.nodes[player.map] = list
    ns.db.noProfessionHint = nil
    ns.NotifyNodesChanged() advance(2)
    local lines = {}
    GetNumSkillLines = function() return #lines end
    GetSkillLineInfo = function(i) return unpack(lines[i]) end
    local function Lines(...)
        local t = { { "Header", true, true } }
        for i = 1, select("#", ...) do t[#t + 1] = { (select(i, ...)), false, nil, 50, nil, 0, 75 } end
        return t
    end
    -- a fresh login on this client, read after the wait
    local function Read(locale, modern, skillLines)
        GetLocale = function() return locale end
        lines = skillLines or {}
        T.Login(modern) T.Settle()
    end
    local function Starts()
        ns.StartHereRun() advance(1)
        local started = ns.run and true or false
        if started then ns.StopRun(true) end
        return started
    end
    local fails = {}
    local function Check(ok, text) if not ok then fails[#fails + 1] = text end end
    local function Is(what, wantHerb, wantOre, wantKnown)
        local h, o, known = ns.GatherProfessions()
        Check(known == wantKnown and (not wantKnown or (h == wantHerb and o == wantOre)),
            ("%s: herb %s ore %s known %s"):format(what, tostring(h), tostring(o), tostring(known)))
    end
    local function Pins(what, wantHerb, wantOre)
        Check(ns.HiddenByProfession(herb) == not wantHerb, what .. ": herb pins wrong")
        Check(ns.HiddenByProfession(ore) == not wantOre, what .. ": ore pins wrong")
    end
    local nothing = function() end
    local mark = #log
    local function Said(text)
        for i = mark + 1, #log do if log[i]:find(ns.L[text], 1, true) then return true end end
    end

    local ok, err = pcall(function()
    -- the review's table: the old list, both learned, in the client's own spelling
    local names = {
        enUS = { "Herbalism", "Mining" }, ruRU = { "Травничество", "Горное дело" }, koKR = { "약초채집", "채광" },
        zhCN = { "草药学", "采矿" }, zhTW = { "草藥學", "採礦" },
    }
    for lang, d in pairs(ns.Locales) do names[lang] = names[lang] or { d["Herbalism"], d["Mining"] } end
    names.esMX = names.esMX or names.esES
    for lang, n in pairs(names) do
        for what, modern in pairs({ ["no GetProfessions"] = false, ["GetProfessions empty"] = nothing }) do
            local case = lang .. ", " .. what
            Read(lang, modern or nil, Lines("Defense", n[1], n[2]))
            Is(case, true, true, true)
            Pins(case, true, true)
            Check(Starts(), case .. ": no run")
            -- only one learned, the language is covered: the other is really missing
            Read(lang, modern or nil, Lines(n[1]))
            Is(case .. ", herb only", true, false, true)
            Pins(case .. ", herb only", true, false)
            Read(lang, modern or nil, Lines("Defense"))
            Is(case .. ", none", false, false, true)
            Pins(case .. ", none", false, false)
            Check(not Starts(), case .. ", none: a run")
        end
    end
    -- a language we have no names for: nothing can be said, all as in 0.1.15
    ns.db.noProfessionHint = nil
    mark = #log
    Read("xxXX", nil, Lines("Defense", "Bylinovedenie", "Gornoe"))
    Is("unknown language", nil, nil, false)
    Pins("unknown language", true, true)
    Check(Starts(), "unknown language: no run")
    Check(not Said(TRAINER), "unknown language: sent to the trainer")
    Check(not Said(HINT), "unknown language: the hint")
    Read("xxXX", nothing, Lines("Defense"))
    Is("unknown language, GetProfessions empty", nil, nil, false)
    -- one name found there says nothing about the other; both found leave no doubt
    Read("xxXX", nil, Lines("Herbalism"))
    Is("unknown language, one found", nil, nil, false)
    Pins("unknown language, one found", true, true)
    Read("xxXX", nil, Lines("Herbalism", "Mining"))
    Is("unknown language, both found", true, true, true)
    -- the list can't tell: empty, or a collapsed header hides the other one
    Read("enUS", nil, {})
    Is("empty list", nil, nil, false)
    Check(Starts(), "empty list: no run")
    Read("enUS", nothing, {})
    Is("empty list, GetProfessions empty", nil, nil, false)
    Pins("empty list, GetProfessions empty", true, true)
    local collapsed = Lines("Herbalism")
    collapsed[#collapsed + 1] = { "Other", true, false }
    Read("enUS", nil, collapsed)
    Is("collapsed header, one found", nil, nil, false)
    Pins("collapsed header, one found", true, true)
    -- IDs: any language, and the list doesn't matter
    ns.db.noProfessionHint = nil
    mark = #log
    Read("xxXX", T.None, {})
    Is("IDs, none", false, false, true)
    Pins("IDs, none", false, false)
    Check(Said(HINT), "IDs, none: no hint")
    Check(not Starts(), "IDs, none: a run")
    Check(Said(TRAINER), "IDs, none: no line about the trainer")
    Read("xxXX", T.Herb, {})
    Is("IDs, Herbalism", true, false, true)
    Pins("IDs, Herbalism", true, false)
    Check(Starts(), "IDs, Herbalism: no run")
    local hidden = Lines("Defense")
    hidden[#hidden + 1] = { "Other", true, false }
    Read("koKR", T.Ore, hidden)
    Is("IDs, Mining", false, true, true)
    Pins("IDs, Mining", false, true)
    -- professions listed without their skill line: the IDs prove nothing
    GetProfessionInfo = function() return "?", 0, 1, 75 end
    Read("enUS", T.None, {})
    Is("no skill line", nil, nil, false)
    Pins("no skill line", true, true)
    GetProfessionInfo = function() return "?", 0, 1, 75, 0, 0, 0 end
    Read("enUS", T.None, {})
    Is("skill line 0", nil, nil, false)
    Read("ruRU", T.None, Lines("Травничество"))
    Is("no skill line, old list", true, false, true)
    GetProfessionInfo = keepInfo
    -- /gcr debug: which source, and whether it counts as sure
    local seen = {}
    ns.Debug = function(text) seen[#seen + 1] = text end
    local function Debugged(...)
        for _, text in ipairs(seen) do
            local all = true
            for i = 1, select("#", ...) do all = all and text:find((select(i, ...)), 1, true) ~= nil end
            if all then return true end
        end
    end
    Read("enUS", T.Herb, {})
    Check(Debugged("IDs", "sure") and not Debugged("not sure"), "debug: IDs, sure")
    seen = {}
    Read("enUS", nil, Lines("Herbalism"))
    Check(Debugged("skill lines", "sure"), "debug: skill lines, sure")
    seen = {}
    Read("xxXX", nil, Lines("Defense"))
    Check(Debugged("skill lines", "not sure"), "debug: skill lines, not sure")
    -- switching debug on tells it again, without a new login
    seen = {}
    local keepFlag = ns.db.debug
    ns.db.debug = nil
    slash("debug")
    Check(Debugged("skill lines", "not sure"), "debug: nothing when switched on")
    ns.db.debug = keepFlag
    end)
    GetLocale, GetProfessionInfo, ns.Debug = keepLocale, keepInfo, keepDebug
    T.Restore()
    assert(ok, err)
    assert(#fails == 0, #fails .. " wrong: " .. table.concat(fails, " | "):sub(1, 900))
end)
step("Professions: a find beats an old \"none\", without a new login (v0.1.16)", function()
    local T = ProfessionTest()
    local keepLocale, keepDebug = GetLocale, ns.Debug
    local M = player.map
    local kinds, list = {}, {}
    for i = 1, 10 do
        local hx, ox = 0.3 + i / 100, 0.5 + i / 100
        kinds[hx], kinds[ox] = "herb", "ore"
        list[#list + 1] = { id = "o1617", name = "Silverleaf", type = "herb", x = hx, y = 0.5, count = 1, last = 1, item = 765 }
        list[#list + 1] = { id = "o1731", name = "Copper Vein", type = "ore", x = ox, y = 0.5, count = 1, last = 1, item = 2770 }
    end
    ns.db.nodes[M] = list
    ns.db.noProfessionHint = nil
    local pins = LibStub("HereBeDragons-Pins-2.0")
    local addWorld, addMini = pins.AddWorldMapIconMap, pins.AddMinimapIconMap
    local world, mini = {}, {}
    pins.AddWorldMapIconMap = function(self, ref, frame, mapID, x, y, ...)
        if mapID == M then world[x] = true end
        return addWorld(self, ref, frame, mapID, x, y, ...)
    end
    pins.AddMinimapIconMap = function(self, ref, icon, mapID, x, y, ...)
        if mapID == M then mini[x] = true end
        return addMini(self, ref, icon, mapID, x, y, ...)
    end
    local function Clear() world, mini = {}, {} end
    local function Redraw() Clear() ns.NotifyNodesChanged() advance(2) end
    local fails = {}
    local function Check(ok, text) if not ok then fails[#fails + 1] = text end end
    local function Count(seen, kind)
        local c = 0
        for x in pairs(seen) do if kinds[x] == kind then c = c + 1 end end
        return c
    end
    local function Shows(what, h, o)
        for name, seen in pairs({ map = world, minimap = mini }) do
            Check(Count(seen, "herb") == (h and 10 or 0), ("%s: %s herb %d"):format(what, name, Count(seen, "herb")))
            Check(Count(seen, "ore") == (o and 10 or 0), ("%s: %s ore %d"):format(what, name, Count(seen, "ore")))
        end
    end
    local function Is(what, wantHerb, wantOre, wantKnown)
        local h, o, known = ns.GatherProfessions()
        Check(known == wantKnown and (not wantKnown or (h == wantHerb and o == wantOre)),
            ("%s: herb %s ore %s known %s"):format(what, tostring(h), tostring(o), tostring(known)))
    end
    local function Starts()
        ns.StartHereRun() advance(1)
        local started = ns.run and true or false
        if started then ns.StopRun(true) end
        return started
    end
    -- the old skill list: the names under an open header, maybe another one collapsed
    local lines = {}
    GetNumSkillLines = function() return #lines end
    GetSkillLineInfo = function(i) return unpack(lines[i]) end
    local function Lines(collapsed, ...)
        local t = { { "Professions", true, true }, { "Defense", false, nil, 5, nil, 0, 5 } }
        for i = 1, select("#", ...) do t[#t + 1] = { (select(i, ...)), false, nil, 50, nil, 0, 75 } end
        if collapsed then t[#t + 1] = { "Weapon Skills", true, false } end
        return t
    end
    -- what the skill list shows now, told by the game: no login, the cache stays
    local function Now(skillLines)
        lines = skillLines
        T.Set(nil)
    end
    local function None()
        lines = Lines(false)
        T.Login(nil) T.Settle()
    end

    local ok, err = pcall(function()
    GetLocale = function() return "enUS" end
    for _, case in ipairs({ { "Herbalism", true, false }, { "Mining", false, true } }) do
        local name, h, o = case[1], case[2], case[3]
        None()
        Is(name .. ", before", false, false, true)
        Redraw() Shows(name .. ", before", false, false)
        Check(not Starts(), name .. ", before: a run")
        -- learned, another category collapsed: the event alone brings the pins back
        Clear() Now(Lines(true, name))
        Is(name .. " learned", h, o, true)
        Shows(name .. " learned", h, o)
        Check(Starts(), name .. " learned: no run")
        -- and it stays, whatever comes after
        for _ = 1, 5 do T.Set(nil) end
        advance(60)
        Is(name .. ", later", h, o, true)
        Redraw() Shows(name .. ", later", h, o)
        Check(Starts(), name .. ", later: no run")
        -- unlearned: a sure read takes it away again
        Now(Lines(false))
        Is(name .. " unlearned", false, false, true)
        Redraw() Shows(name .. " unlearned", false, false)
        Check(not Starts(), name .. " unlearned: a run")
    end

    -- per profession: finding one takes nothing from the other
    None()
    Now(Lines(true, "Herbalism"))
    Now(Lines(true, "Mining"))
    Is("one after the other", true, true, true)
    Redraw() Shows("one after the other", true, true)
    -- a sure read can take one of them
    Now(Lines(false, "Mining"))
    Is("Herbalism unlearned", false, true, true)
    Redraw() Shows("Herbalism unlearned", false, true)
    Check(Starts(), "Herbalism unlearned: no run")

    -- a read that isn't sure and finds nothing changes nothing, says nothing
    None()
    ns.db.noProfessionHint = nil
    for what, skillLines in pairs({ collapsed = Lines(true), empty = {} }) do
        Now(skillLines)
        Is("none, then " .. what, false, false, true)
        Redraw() Shows("none, then " .. what, false, false)
        Check(not Starts(), "none, then " .. what .. ": a run")
    end
    Check(not ns.db.noProfessionHint, "not sure, nothing found: the hint")
    Now(Lines(false, "Herbalism"))
    for what, skillLines in pairs({ collapsed = Lines(true), empty = {} }) do
        Now(skillLines)
        Is("Herbalism, then " .. what, true, false, true)
        Redraw() Shows("Herbalism, then " .. what, true, false)
        Check(Starts(), "Herbalism, then " .. what .. ": no run")
    end

    -- nothing sure yet: a find doesn't make it known, the other stays open
    lines = Lines(true, "Herbalism")
    T.Login(nil) T.Settle()
    T.Set(nil)
    Is("nothing sure yet", nil, nil, false)
    Redraw() Shows("nothing sure yet", true, true)

    -- the IDs as before: learned and unlearned follow without a login
    lines = {}
    T.Login(T.None) T.Settle()
    Is("IDs, none", false, false, true)
    Clear() T.Set(T.Herb)
    Is("IDs, learned", true, false, true)
    Shows("IDs, learned", true, false)
    T.Set(T.None)
    Is("IDs, unlearned", false, false, true)
    Redraw() Shows("IDs, unlearned", false, false)

    -- /gcr debug: one line per change, nothing while the state stays
    local seen = {}
    ns.Debug = function(text) if text:find("PROFESSIONS", 1, true) then seen[#seen + 1] = text end end
    None()
    seen = {}
    for _ = 1, 10 do T.Set(nil) end
    Check(#seen == 0, ("debug, no change: %d lines"):format(#seen))
    Now(Lines(true, "Herbalism"))
    Check(#seen == 1, ("debug, a change: %d lines"):format(#seen))
    for _ = 1, 10 do T.Set(nil) end
    advance(60)
    Check(#seen == 1, ("debug, no change after it: %d lines"):format(#seen))
    end)
    pins.AddWorldMapIconMap, pins.AddMinimapIconMap = addWorld, addMini
    GetLocale, ns.Debug = keepLocale, keepDebug
    T.Restore()
    assert(ok, err)
    assert(#fails == 0, #fails .. " wrong: " .. table.concat(fails, " | "):sub(1, 900))
end)
step("Secret values: nothing breaks, nothing is learned (v0.1.16)", function()
    -- what the client hands out in dungeons and combat: everything but passing
    -- it on is an error. Lua 5.1 can't catch == and ~= against a string here:
    -- that shows as a secret that gets further than it should.
    local SECRET = newproxy(true)
    local meta = getmetatable(SECRET)
    for _, k in ipairs({ "__index", "__newindex", "__concat", "__lt", "__le", "__eq", "__add", "__sub", "__mul",
        "__div", "__mod", "__unm", "__len", "__call", "__tostring" }) do
        meta[k] = function() error("attempt to use a secret value", 2) end
    end
    local function Secret() return SECRET end
    local names = { "issecretvalue", "UnitGUID", "UnitName", "UnitClassification", "UnitExists", "UnitIsDead",
        "UnitIsPlayer", "UnitLevel", "UnitIsTapDenied", "GetLootSourceInfo", "GetLootSlotLink", "GetLootSlotInfo",
        "GetNumLootItems", "IsFishingLoot", "GetProfessions", "GetProfessionInfo", "GetNumSkillLines",
        "GetSkillLineInfo", "GetCursorPosition", "GetCVar", "GetPlayerFacing" }
    local keep = {}
    for _, k in ipairs(names) do keep[k] = _G[k] end
    local keepMap, keepPos = C_Map.GetBestMapForUnit, C_Map.GetPlayerMapPosition
    local keepItem, keepDebug, keepLoot = GameTooltip.GetItem, ns.db.debug, loot
    local keepPlayer = { player.map, player.x, player.y }
    local fails = {}
    local function Check(ok, text) if not ok then fails[#fails + 1] = text end end
    local base = #errors
    -- errors of the handlers (fire collects them) go in the list of this step
    local function Clean(what)
        local n = #errors - base
        if n > 0 then fails[#fails + 1] = ("%s: %d errors, first %s"):format(what, n, errors[base + 1]:sub(1, 120)) end
        for i = #errors, base + 1, -1 do errors[i] = nil end
    end
    local function Try(what, fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok then fails[#fails + 1] = what .. ": " .. tostring(err):sub(1, 120) end
    end
    -- one global secret at a time, the others as they were
    local function With(key, fn)
        local old = _G[key]
        _G[key] = Secret
        fn()
        _G[key] = old
    end

    local round = 0
    local function Casts()
        ns.pending = nil
        for i = 1, 500 do
            fire("UNIT_SPELLCAST_SENT", "player", SECRET, "Cast-" .. i, 780)
            fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-" .. i, 780)
        end
        Clean("500 casts")
        Check(ns.pending == nil, "500 casts: something pending")
        -- a gathering spell without a readable name books nothing either
        for _, spell in ipairs({ 2366, 2575, 3365 }) do
            fire("UNIT_SPELLCAST_SENT", "player", SECRET, "s" .. spell, spell)
            Check(ns.pending == nil, spell .. ": something pending")
        end
        fire("UNIT_SPELLCAST_SENT", SECRET, "Peacebloom", "s1", 2366)
        Check(ns.pending == nil, "secret unit: something pending")
        fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", SECRET, 2366)
        Check(ns.pending == nil, "secret cast: something pending")
        fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", "s2", SECRET)
        Check(ns.pending == nil, "secret spell: something pending")
        Clean("secret arguments")
        -- after the fight: a gather works, the secrets next to it don't touch it
        local id = "after" .. round
        local got
        local function Listen(node) got = node end
        table.insert(ns.gatherListeners, Listen)
        fire("UNIT_SPELLCAST_SENT", "player", "Peacebloom", id, 2366)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", SECRET, 2366)
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", id, SECRET)
        fire("UNIT_SPELLCAST_FAILED", "player", SECRET)
        fire("UNIT_SPELLCAST_INTERRUPTED", "player", SECRET)
        Clean("a gather and secrets")
        Check(ns.pending and ns.pending.castGUID == id and not ns.pending.succeeded, "a gather and secrets: changed")
        fire("UNIT_SPELLCAST_SUCCEEDED", "player", id, 2366)
        loot = { { guid = "GameObject-0-1-1-1-1618-AFTER" .. round, item = 2447, qty = 1 } }
        fire("LOOT_READY") fire("LOOT_OPENED") advance(3)
        fire("LOOT_CLOSED")
        table.remove(ns.gatherListeners)
        loot = keepLoot
        Clean("gather after the fight")
        Check(got ~= nil, "gather after the fight: nothing booked")
    end

    local function Loot()
        loot = { { guid = "GameObject-0-1-1-1-1618-LOOT", item = 2447, qty = 2 } }
        for _, key in ipairs({ "GetLootSourceInfo", "GetLootSlotLink", "GetLootSlotInfo", "GetNumLootItems", "IsFishingLoot" }) do
            With(key, function()
                fire("LOOT_READY") fire("LOOT_OPENED") fire("LOOT_CLOSED")
                Clean(key)
            end)
        end
        -- a catch: the same reads again, now the fishing side gets that far
        IsFishingLoot = function() return true end
        for _, key in ipairs({ "GetLootSlotLink", "GetLootSlotInfo", "GetNumLootItems" }) do
            With(key, function()
                fire("LOOT_READY") fire("LOOT_CLOSED")
                Clean("fishing, " .. key)
            end)
        end
        IsFishingLoot = keep.IsFishingLoot
        loot = keepLoot
    end

    local function Tooltips()
        local Z = 1467
        local known = GathercraftNodeNames and GathercraftNodeNames[GetLocale()]
        local herbName = known and known[1618] or "Peacebloom"
        local owner, lines = UIParent, {}
        Minimap.IsMouseOver = function() return true end
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
        GetCursorPosition = function() return 535, 400 end
        GetCVar = function() return "0" end
        player.map, player.x, player.y = Z, 0.5, 0.5
        ns.db.nodes[Z] = nil
        -- no target, the name would come from the tooltip: a secret one books nothing
        ns.pending = nil
        lines = { SECRET }
        fire("UNIT_SPELLCAST_SENT", "player", "", "t1", 2366)
        Check(ns.pending == nil, "secret tooltip title, herb: something pending")
        fire("UNIT_SPELLCAST_SENT", "player", "", "t2", 780)
        Check(ns.pending == nil, "secret tooltip title, a guess: something pending")
        Clean("secret tooltip title")
        lines = { herbName }
        fire("UNIT_SPELLCAST_SENT", "player", "", "t3", 2366)
        Check(ns.pending and ns.pending.name == herbName, "readable tooltip title: not read")
        fire("UNIT_SPELLCAST_FAILED", "player", "t3")
        -- the minimap: a tooltip with a secret line teaches nothing, not even its readable lines
        local function Hover(l)
            owner, lines = Minimap, l
            advance(3)
            lines = {}
            advance(3)
        end
        Hover({ SECRET })
        Hover({ herbName, SECRET })
        With("GetCursorPosition", function() Hover({ herbName }) end)
        Clean("secret minimap tooltip")
        Check(#(ns.db.nodes[Z] or {}) == 0, "secret minimap tooltip: learned something")
        Hover({ herbName })
        Clean("readable minimap tooltip")
        Check(#(ns.db.nodes[Z] or {}) > 0, "readable minimap tooltip: learned nothing")
        ns.db.nodes[Z] = nil
        for _, k in ipairs({ "IsMouseOver", "GetCenter", "GetWidth", "GetHeight", "GetZoom", "GetEffectiveScale" }) do Minimap[k] = nil end
        for _, k in ipairs({ "IsShown", "GetOwner", "NumLines" }) do GameTooltip[k] = nil end
        GetCursorPosition, GetCVar = keep.GetCursorPosition, keep.GetCVar
        player.map, player.x, player.y = keepPlayer[1], keepPlayer[2], keepPlayer[3]
        -- an item tooltip in a dungeon
        GameTooltip.GetItem = function() return "Peacebloom", SECRET end
        Try("secret item link", GameTooltip.__scripts.OnTooltipSetItem, GameTooltip)
        GameTooltip.GetItem = keepItem
    end

    local function Rares()
        local function Fire(unit)
            fire("NAME_PLATE_UNIT_ADDED", unit or "nameplate1")
            fire("PLAYER_TARGET_CHANGED")
            fire("UPDATE_MOUSEOVER_UNIT")
        end
        local rare = UnitClassification
        UnitClassification = function() return "rare" end
        local guid = UnitGUID
        for _, key in ipairs({ "UnitGUID", "UnitName", "UnitClassification", "UnitExists", "UnitIsDead", "UnitIsPlayer",
            "UnitLevel", "UnitIsTapDenied" }) do
            -- a rare not seen yet, or the alert ends before it reads the rest
            UnitGUID = function() return ("Creature-0-1-1-1-1234-%s%d"):format(key, round) end
            With(key, function() Fire() end)
            Clean(key)
        end
        UnitClassification, UnitGUID = rare, guid
        Fire(SECRET)
        Clean("secret unit")
    end

    local function Sync()
        local text = "N:1412;o1619,h,4548,7312,2449"
        fire("CHAT_MSG_ADDON", SECRET, text, "CHANNEL", "Someone-Realm")
        fire("CHAT_MSG_ADDON", "Gathercraft", SECRET, "CHANNEL", "Someone-Realm")
        fire("CHAT_MSG_ADDON", "Gathercraft", text, SECRET, "Someone-Realm")
        fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", SECRET)
        With("UnitName", function() fire("CHAT_MSG_ADDON", "Gathercraft", text, "CHANNEL", "Someone-Realm") end)
        Clean("addon message")
    end

    local function Skills()
        local herb, ore, known = ns.GatherProfessions()
        local function Read(what)
            fire("SKILL_LINES_CHANGED") advance(2)
            Try(what, ns.GetSkill, "herb")
            Try(what, ns.SkillListIncomplete)
            Clean(what)
            local h, o, k = ns.GatherProfessions()
            Check(h == herb and o == ore and k == known, what .. ": what was known changed")
        end
        With("GetProfessions", function() Read("secret profession") end)
        With("GetProfessionInfo", function() Read("secret profession info") end)
        local info = GetProfessionInfo
        GetProfessionInfo = function() return "x", 0, 50, 75, 0, 0, SECRET end
        Read("secret skill line")
        GetProfessionInfo = info
        local gp, gn = GetProfessions, GetNumSkillLines
        GetProfessions = nil
        GetNumSkillLines = function() return 2 end
        GetSkillLineInfo = function(i) if i == 1 then return "Herbs", true, true end return SECRET, false, nil, 50, nil, 0, 75 end
        Read("secret skill name")
        GetSkillLineInfo = function() return SECRET, SECRET, SECRET, SECRET, nil, SECRET, SECRET end
        Read("secret skill line values")
        GetNumSkillLines = Secret
        Read("secret skill count")
        GetProfessions, GetNumSkillLines, GetSkillLineInfo = gp, gn, keep.GetSkillLineInfo
        fire("SKILL_LINES_CHANGED") advance(2)
    end

    local function Rest()
        fire("UNIT_SPELLCAST_CHANNEL_START", "player", "x", SECRET)
        fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", "x", SECRET)
        Clean("secret channel")
        C_Map.GetBestMapForUnit = Secret
        Check(ns.GetPlayerPos() == nil, "secret map: a position")
        C_Map.GetBestMapForUnit = keepMap
        C_Map.GetPlayerMapPosition = function() return { GetXY = function() return SECRET, SECRET end } end
        Check(ns.GetPlayerPos() == nil, "secret position: a position")
        C_Map.GetPlayerMapPosition = keepPos
        Clean("secret position")
    end

    -- nothing secret kept: not in the saved data, not in the gather
    local function Stored(t, seen, path)
        if type(t) ~= "table" or seen[t] then return end
        seen[t] = true
        for k, v in pairs(t) do
            if rawequal(k, SECRET) or rawequal(v, SECRET) then fails[#fails + 1] = path .. " holds a secret" end
            Stored(k, seen, path)
            Stored(v, seen, path)
        end
    end

    local seen
    local function Told()
        local count = 0
        seen = {}
        for _, line in ipairs(log) do
            local where = line:match("secret value skipped in (.+)")
            if where then
                count = count + 1
                Check(not seen[where], "debug: more than once: " .. where)
                seen[where] = true
            end
        end
        return count
    end

    local ok, err = pcall(function()
    local function All()
        round = round + 1
        Casts() Loot() Tooltips() Rares() Sync() Skills() Rest()
        Stored(ns.db, {}, "ns.db")
        Stored(ns.pending, {}, "ns.pending")
        ns.pending = nil
    end
    local function IsSecret(v) return rawequal(v, SECRET) end
    -- debug off: not a word; on: once per place; the client without issecretvalue the same
    issecretvalue = IsSecret
    ns.db.debug = nil
    local before = Told()
    All()
    Check(Told() == before, "debug off: a line")
    ns.db.debug = true
    All()
    local told = Told()
    Check(told > before, "debug on: no line")
    -- every guard says so: a compare can't throw in Lua 5.1, this line shows it was reached
    for _, where in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED", "the tooltip",
        "loot", "fishing", "position", "item link", "rare alert", "skills", "CHAT_MSG_ADDON", "sync" }) do
        Check(seen[where], "debug: no line for " .. where)
    end
    All()
    Check(Told() == told, "debug on, again: a new line")
    issecretvalue = nil
    All()
    Check(Told() == told, "without issecretvalue: a new line")
    -- what is readable stays as it is
    issecretvalue = IsSecret
    for _, v in ipairs({ "text", "", 0, 12 }) do
        Check(ns.Readable(v) == v, "readable: " .. tostring(v))
    end
    Check(ns.Readable(false) == false and ns.Readable(nil) == nil and ns.Readable(SECRET) == nil, "Readable, issecretvalue")
    issecretvalue = nil
    for _, v in ipairs({ "text", "", 0, 12 }) do
        Check(ns.Readable(v) == v, "readable, without issecretvalue: " .. tostring(v))
    end
    Check(ns.Readable(false) == false and ns.Readable(nil) == nil and ns.Readable(SECRET) == nil, "Readable, without issecretvalue")
    end)
    for _, k in ipairs(names) do _G[k] = keep[k] end
    C_Map.GetBestMapForUnit, C_Map.GetPlayerMapPosition = keepMap, keepPos
    GameTooltip.GetItem, ns.db.debug, loot = keepItem, keepDebug, keepLoot
    player.map, player.x, player.y = keepPlayer[1], keepPlayer[2], keepPlayer[3]
    ns.pending = nil
    Clean("the rest")
    if not ok then fails[#fails + 1] = tostring(err) end
    assert(#fails == 0, #fails .. " wrong: " .. table.concat(fails, " | "):sub(1, 1500))
end)
step("Professions: a hidden number is no proof the profession is gone (R4-B1)", function()
    local T = ProfessionTest()
    local SECRET = newproxy(true)
    local meta = getmetatable(SECRET)
    for _, k in ipairs({ "__index", "__concat", "__lt", "__le", "__eq", "__add", "__sub", "__mul", "__div", "__unm", "__len", "__call", "__tostring" }) do
        meta[k] = function() error("attempt to use a secret value", 2) end
    end
    local keepSecret, keepInfo = issecretvalue, GetProfessionInfo
    issecretvalue = function(v) return rawequal(v, SECRET) end
    local fails = {}
    local function Check(ok, text) if not ok then fails[#fails + 1] = text end end
    local herbNode = { type = "herb" }
    local function Sure(what, wantHerb)
        local herb, ore, known = ns.GatherProfessions()
        Check(known and herb == wantHerb and ore, ("%s: herb %s ore %s known %s"):format(what, tostring(herb), tostring(ore), tostring(known)))
        Check(ns.HiddenByProfession(herbNode) == not wantHerb, what .. ": herb pins " .. (wantHerb and "hidden" or "shown"))
    end
    -- the ID way: Herbalism 52/75 read once, then one number hidden at a time
    GetProfessionInfo = keepInfo
    T.Login(T.Both) T.Settle()
    Sure("readable", true)
    ns.db.noProfessionHint = nil
    for slot, what in pairs({ [3] = "rank", [4] = "max rank", [8] = "modifier" }) do
        GetProfessionInfo = function(i)
            local v = { keepInfo(i) }
            if i == 1 then v[slot] = SECRET end
            return unpack(v, 1, 8)
        end
        T.Set(T.Both)
        Sure("IDs, hidden " .. what, true)
        local rank = ns.GetSkill("herb")
        Check(rank == 52, ("IDs, hidden %s: rank %s, want the last read 52"):format(what, tostring(rank)))
    end
    -- the skill line ID itself hidden: can't tell, what was known stays
    GetProfessionInfo = function(i)
        local v = { keepInfo(i) }
        if i == 1 then v[7] = SECRET end
        return unpack(v, 1, 8)
    end
    T.Set(T.Both)
    Sure("IDs, hidden skill line", true)
    Check(not ns.db.noProfessionHint, "the 'no gathering profession' hint came")
    -- the old skill list (no GetProfessions): name readable, numbers hidden
    GetProfessionInfo = keepInfo
    GetProfessions = nil
    for slot, what in pairs({ [4] = "rank", [6] = "modifier", [7] = "max rank" }) do
        local lines = { { "Professions", true, true }, { "Herbalism", false, false, 52, 0, 0, 75 }, { "Mining", false, false, 30, 0, 0, 75 } }
        lines[2][slot] = SECRET
        GetNumSkillLines = function() return #lines end
        GetSkillLineInfo = function(i) return unpack(lines[i], 1, 7) end
        fire("SKILL_LINES_CHANGED") advance(2)
        Sure("skill list, hidden " .. what, true)
    end
    -- really unlearned, all readable: still noticed
    GetProfessions = T.Ore
    GetNumSkillLines = function() return 0 end
    T.Set(T.Ore)
    Sure("Herbalism unlearned (readable)", false)
    Check(#errors == 0 or not errors[#errors]:find("secret", 1, true), "a secret value was used")
    issecretvalue, GetProfessionInfo = keepSecret, keepInfo
    T.Restore()
    assert(#fails == 0, #fails .. " wrong: " .. table.concat(fails, " | "))
end)
step("Sync: unconfirmed reports wait 7 days, in new zones 14 (v0.1.16)", function()
    local s = ns.db.sync
    local keepPending, keepKnown = s.pending, ns.HasKnownSpawns
    local DAY = 24 * 3600
    local function Report(days) return { first = time() - days * DAY } end
    ns.HasKnownSpawns = function(mapID) return mapID ~= 9001 end
    s.pending = {
        [1412] = { Report(2), Report(5), Report(6.9), Report(7.1), Report(8) },
        [1437] = { Report(8) },
        [9001] = { Report(8), Report(13), Report(15) },
    }
    ns.DropOldPending()
    local pending = s.pending
    local known, new = pending[1412], pending[9001]
    ns.HasKnownSpawns, s.pending = keepKnown, keepPending
    assert(known and #known == 3, ("known spawns: %d reports left, want the three up to 7 days"):format(known and #known or 0))
    for _, r in ipairs(known) do assert(time() - r.first < 7 * DAY, "a report older than 7 days stayed") end
    assert(pending[1437] == nil, "a report of 8 days stayed, or its empty zone")
    assert(new and #new == 2, ("new zone: %d reports left, want 2"):format(new and #new or 0))
end)
step("Recipe data: Blizzard hotfix for the Tanning Rack (v0.1.17)", function()
    local rack = GathercraftRecipeData.professions.Leatherworking["Tanning Rack"]
    assert(rack and rack:match("^%d+:%d+:%d+:(%d+)|") == "125", "Tanning Rack: required skill " .. tostring(rack))
    local spell = GathercraftRecipeData.spells.Leatherworking["Tanning Rack"]
    assert(GathercraftRecipeData.colors[spell] == "125:130", "Tanning Rack: colours " .. tostring(GathercraftRecipeData.colors[spell]))
    assert(not (GathercraftRecipeData.guessed.Leatherworking or {})["Tanning Rack"], "Tanning Rack: marked as a guess")
end)
step("Crafting: sort by a column, both ways, remembered (v0.1.17)", function()
    local function R(name, req, profit, value, cost, can, extra)
        local r = { name = name, prof = "Tailoring", req = req, profit = profit, value = value, valueSource = "AH scan",
            cost = cost, costUnknown = 0, reagents = { {} }, canMake = can, missing = false, enchant = false }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    local function Rows()
        return { R("Bolt", 50, 100, 300, 200, 3), R("Shirt", 10, 500, 900, 400, 0), R("Gloves", 75, -50, 100, 150, 9),
            R("Cloak", nil, 20, 120, 100, 1), R("Robe", 30, 0, 0, 0, 2, { missing = true, valueSource = nil, costUnknown = 1 }) }
    end
    local function Order(key, desc)
        local names = {}
        for _, r in ipairs(ns.CraftSortRows(Rows(), key, desc)) do names[#names + 1] = r.name end
        return table.concat(names, " ")
    end
    local want = {
        { "skill", false, "Shirt Robe Bolt Gloves Cloak" }, { "skill", true, "Gloves Bolt Robe Shirt Cloak" },
        { "profit", true, "Shirt Bolt Cloak Gloves Robe" }, { "profit", false, "Gloves Cloak Bolt Shirt Robe" },
        { "value", true, "Shirt Bolt Cloak Gloves Robe" }, { "cost", false, "Cloak Gloves Bolt Shirt Robe" },
        { "can", true, "Gloves Bolt Robe Cloak Shirt" }, { "name", false, "Bolt Cloak Gloves Robe Shirt" },
        { "name", true, "Shirt Robe Gloves Cloak Bolt" },
    }
    local bad = {}
    for _, w in ipairs(want) do
        local got = Order(w[1], w[2])
        if got ~= w[3] then bad[#bad + 1] = ("%s %s: %s"):format(w[1], tostring(w[2]), got) end
    end
    assert(#bad == 0, #bad .. " wrong: " .. table.concat(bad, " | "))

    -- the page: skill, low first, by default; a click sorts, a second click turns it round
    ns.db.craftSort, ns.db.craftSortDesc = nil, nil
    ns.ToggleMain("craft") advance(1)
    local titles = {}
    for _, f in ipairs(allFrames) do
        if f.__kind == "Button" and f.label and f.text and f.__scripts.OnClick then titles[f.label] = f end
    end
    for _, label in ipairs({ "Item", "Skill", "Profit", "Sells for", "Costs", "Can make" }) do
        assert(titles[label], "no clickable column title " .. label)
    end
    assert(titles.Skill.text.__text:find("Arrow-Up", 1, true), "skill is not the default sort: " .. tostring(titles.Skill.text.__text))
    titles.Profit.__scripts.OnClick(titles.Profit)
    assert(ns.db.craftSort == "profit" and ns.db.craftSortDesc == true, "profit click: " .. tostring(ns.db.craftSort))
    assert(titles.Profit.text.__text:find("Arrow-Down", 1, true), "profit: no arrow")
    assert(not titles.Skill.text.__text:find("Arrow", 1, true), "skill still marked")
    titles.Profit.__scripts.OnClick(titles.Profit)
    assert(ns.db.craftSort == "profit" and ns.db.craftSortDesc == false, "second click did not turn it round")
    ns.HideMain()
    ns.db.craftSort, ns.db.craftSortDesc = nil, nil
end)
step("Crafting: the skill in its own column, never 0, unknown ones last (v0.1.17)", function()
    -- Sven's find (08.11.): learned cooking recipes had no number and stood
    -- first when sorted by skill, the number sat in brackets after the name
    local keepDB = ns.db.recipeDB
    ns.db.recipeDB = { Cooking = {
        -- read from the profession window: no skill there (0)
        ["Brilliant Smallfish"] = "6290:1:1:0|6291:1",
        ["Smoked Desert Dumplings"] = "20452:1:1:0|3713:1,20424:1",
        -- seen at a trainer
        ["Herb Baked Egg"] = "6888:1:1:40|2678:1,6889:1",
    } }
    local shipped = GathercraftRecipeData.professions.Cooking
    assert(shipped["Brilliant Smallfish"]:match("^%d+:%d+:%d+:(%d+)") == "1", "test setup: shipped Brilliant Smallfish")
    local rows = ns.CraftAdvice("Cooking")
    local byName, zero = {}, 0
    for _, r in ipairs(rows) do
        byName[r.key] = r
        if r.req == 0 then zero = zero + 1 end
    end
    assert(zero == 0, zero .. " recipes with skill 0")
    assert(byName["Brilliant Smallfish"] and byName["Brilliant Smallfish"].req == 1, "own 0 hid the shipped skill: " .. tostring(byName["Brilliant Smallfish"] and byName["Brilliant Smallfish"].req))
    assert(byName["Herb Baked Egg"] and byName["Herb Baked Egg"].req == 40, "the skill seen at a trainer was not used")
    assert(byName["Smoked Desert Dumplings"] and byName["Smoked Desert Dumplings"].req == nil, "an unknown skill is not unknown")
    -- low first: the ones without a skill come last
    local sorted = ns.CraftSortRows(rows, "skill", false)
    local seenUnknown, bad = false, nil
    for i, r in ipairs(sorted) do
        if r.req == nil then seenUnknown = true elseif seenUnknown then bad = r.key end
        if i > 1 and r.req and sorted[i - 1].req and r.req < sorted[i - 1].req then bad = r.key end
    end
    assert(not bad, "skill low first is out of order at " .. tostring(bad))
    assert(sorted[#sorted].req == nil and sorted[1].req, "unknown skills are not last")
    -- Codex N1: costs a fraction of a copper apart still have one order
    local function C(name, cost) return { name = name, prof = "Cooking", cost = cost, costUnknown = 0, reagents = { {} } } end
    for _, desc in ipairs({ false, true }) do
        local list = ns.CraftSortRows({ C("A", 100.8), C("B", 100.4), C("C", 100.0) }, "cost", desc)
        local got = list[1].name .. list[2].name .. list[3].name
        assert(got == (desc and "ABC" or "CBA"), ("costs 100.8/100.4/100.0, %s: %s"):format(desc and "high first" or "low first", got))
    end
    -- the page: a skill column, names cut before it, no number in brackets
    ns.db.craftSort, ns.db.craftSortDesc = nil, nil
    ns.ToggleMain("craft") advance(1)
    local shown = 0
    for _, f in ipairs(allFrames) do
        if f.name and f.profit and f.icon and f.__shown and type(f.data) == "table" and f.data.reagents then
            shown = shown + 1
            assert(f.skill, "no skill column in the recipe rows")
            local nx, sx = f.name.__pts.LEFT[1], f.skill.__pts.LEFT[1]
            assert(nx + f.name.__w < sx, ("the name (%d + %d) runs into the skill column at %d"):format(nx, f.name.__w, sx))
            assert(f.name.__wrap == false, "a long name can wrap")
            assert(not tostring(f.name.__text):find("%(~?%d+%)"), "the skill still sits in brackets after the name: " .. tostring(f.name.__text))
            local want = f.data.req and tostring(f.data.req) or "?"
            assert(tostring(f.skill.__text):find(want, 1, true), ("skill column says %s, want %s"):format(tostring(f.skill.__text), want))
        end
    end
    assert(shown > 0, "test setup: no recipe rows on the page")
    ns.HideMain()
    ns.db.recipeDB = keepDB
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
