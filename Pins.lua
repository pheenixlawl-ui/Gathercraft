local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Node pins on the world map and minimap (HereBeDragons)
--   Single new/changed nodes only add or move their own pins.
--   Bigger changes (selection, pin size, deletes) rebuild everything,
--   at most once per short moment.
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)

local WORLD_SIZE = 14
local DIM_ALPHA = 0.35   -- nodes on cooldown (just harvested)
local REF = ADDON_NAME   -- owner key for HereBeDragons
local REBUILD_DELAY = 0.3

local TYPE_ICONS = {
    herb = "Interface\\Icons\\INV_Misc_Flower_02",
    ore = "Interface\\Icons\\INV_Ore_Copper_01",
    chest = "Interface\\Icons\\INV_Box_02",
}
local TYPE_LABELS = { herb = "Herb", ore = "Ore", chest = "Chest" }
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

---------------------------------------------------------------------------
-- Pin frames
---------------------------------------------------------------------------
local freeWorld, freeMini = {}, {}
local pinsByNode = {}    -- node -> { world = pin, mini = pin }

local function NodeIcon(n)
    if n.item and n.type ~= "chest" then -- chest loot is random, keep the chest icon
        local icon
        if C_Item and C_Item.GetItemIconByID then
            icon = C_Item.GetItemIconByID(n.item)
        elseif GetItemIcon then
            icon = GetItemIcon(n.item)
        end
        if icon then return icon end
    end
    return TYPE_ICONS[n.type] or DEFAULT_ICON
end

local function ShowTooltip(pin)
    local n = pin.node
    if not n then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:AddLine(n.name, 1, 1, 1)
    if n.type then
        GameTooltip:AddLine(L[TYPE_LABELS[n.type] or n.type], 0.6, 0.6, 0.6)
    end
    if (n.count or 1) > 0 then
        GameTooltip:AddLine((L["Seen %d times"]):format(n.count or 1), 0.8, 0.8, 0.8)
    end
    if ns.SkillTooltip then
        ns.SkillTooltip(GameTooltip, n)
    end
    if n.item and ns.GetPrice then
        local price, source = ns.GetPrice(n.item)
        if price then
            GameTooltip:AddLine((L["Worth: %s each  |cff999999(%s)|r"]):format(ns.Money(price), source), 1, 1, 1)
        end
    end
    if n.source == "sync" then
        GameTooltip:AddLine(L["Shared by other players"], 0.4, 0.8, 1)
    elseif n.source == "questie" then
        GameTooltip:AddLine(L["Known spawn point (Questie data)"], 0.8, 0.7, 1)
    elseif n.source == "starter" then
        GameTooltip:AddLine(L["From the beta database (not confirmed yet)"], 0.8, 0.7, 1)
    end
    local others = pin.others or (pin.othersOf and pin.othersOf.others)
    if others and #others > 0 then
        local names, seen = {}, { [n.name] = true }
        for _, o in ipairs(others) do
            if not seen[o.name] then
                seen[o.name] = true
                names[#names + 1] = o.name
            end
        end
        if #names > 0 then
            GameTooltip:AddLine(L["Shared spawn point, can also be: "] .. table.concat(names, ", "), 1, 0.82, 0.3, true)
        end
    end
    if ns.IsOnCooldown(n) then
        GameTooltip:AddLine((L["Harvested, respawn in ~%ds"]):format(n.emptyUntil - time()), 1, 0.5, 0.5)
    end
    GameTooltip:Show()
end

local function CreatePin()
    local pin = CreateFrame("Frame", nil, UIParent)
    pin.icon = pin:CreateTexture(nil, "OVERLAY")
    pin.icon:SetAllPoints()
    pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- crop the icon border
    pin:EnableMouse(true)
    pin:SetScript("OnEnter", ShowTooltip)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:Hide()
    return pin
end

-- Known spawn points (Questie / beta data) are drawn smaller and a bit
-- transparent, so your own nodes stand out and the map stays readable
local KNOWN_SCALE, KNOWN_ALPHA = 0.7, 0.75

local function Sizes(n)
    local world = ns.db.pinSize or WORLD_SIZE
    local mini = math.max(8, world - 2)
    if n and n.source then
        return math.max(7, math.floor(world * KNOWN_SCALE + 0.5)), math.max(7, math.floor(mini * 0.85 + 0.5))
    end
    return world, mini
end

local function SetAlpha(pin)
    local n = pin.node
    pin:SetAlpha(ns.IsOnCooldown(n) and DIM_ALPHA or (n.source and KNOWN_ALPHA or 1))
end

-- Adds the two pins (world map + minimap) of one node
-- Minimap pins only for the zone the player is in: with known spawn data a
-- continent can hold thousands of nodes, and every minimap pin costs time
-- while moving. The world map still shows every zone.
local playerMap

-- Known spawn points that share a spot (e.g. Copper OR Tin Vein can spawn
-- there) get one pin instead of icons stacked on top of each other.
-- Grid of known-spawn pins per zone: mapID -> "cx:cy" -> { pins }
local SHARED_YARDS = 10
local grid = {}
local function Cell(x, y) return math.floor(x * 200), math.floor(y * 200) end

local function FindSharedPin(mapID, n)
    local g = grid[mapID]
    if not g then return end
    local cx, cy = Cell(n.x, n.y)
    for dx = -1, 1 do
        for dy = -1, 1 do
            for _, pin in ipairs(g[(cx + dx) .. ":" .. (cy + dy)] or {}) do
                local p = pin.node
                if p and p.type == n.type and p.name ~= n.name
                    and ns.Distance(mapID, n.x, n.y, p.x, p.y) <= SHARED_YARDS then
                    return pin
                end
            end
        end
    end
end

local function AddToGrid(mapID, pin)
    local cx, cy = Cell(pin.node.x, pin.node.y)
    grid[mapID] = grid[mapID] or {}
    local key = cx .. ":" .. cy
    grid[mapID][key] = grid[mapID][key] or {}
    table.insert(grid[mapID][key], pin)
end

local function AddNodePins(mapID, n)
    if ns.db.pinsHidden or not ns.IsNodeEnabled(n, mapID) then return end
    if n.source == "questie" then
        local shared = FindSharedPin(mapID, n)
        if shared then
            shared.others = shared.others or {}
            table.insert(shared.others, n)
            pinsByNode[n] = { sharedWith = shared }
            return
        end
    end
    local icon = NodeIcon(n)
    local worldSize, miniSize = Sizes(n)

    local w = table.remove(freeWorld) or CreatePin()
    w.node, w.mapID = n, mapID
    w:SetSize(worldSize, worldSize)
    w.icon:SetTexture(icon)
    SetAlpha(w)
    w.others = nil
    HBDPins:AddWorldMapIconMap(REF, w, mapID, n.x, n.y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
    if n.source == "questie" then AddToGrid(mapID, w) end

    local m
    if mapID == playerMap then
        m = table.remove(freeMini) or CreatePin()
        m.node, m.mapID = n, mapID
        m:SetSize(miniSize, miniSize)
        m.icon:SetTexture(icon)
        m.others = nil
        SetAlpha(m)
        HBDPins:AddMinimapIconMap(REF, m, mapID, n.x, n.y, false, false)
    end

    pinsByNode[n] = { world = w, mini = m }
    if m then m.othersOf = w end
end

-- Removes the pins of one node
local RequestRebuild -- forward declaration
local rebuilding = false

local function RemoveNodePins(n, quiet)
    local pins = pinsByNode[n]
    if not pins then return end
    if pins.sharedWith then
        local others = pins.sharedWith.others or {}
        for i = #others, 1, -1 do
            if others[i] == n then table.remove(others, i) end
        end
        pinsByNode[n] = nil
        return
    end
    if pins.world.others and #pins.world.others > 0 and RequestRebuild and not rebuilding and not quiet then
        RequestRebuild() -- another kind takes over this spot
    end
    HBDPins:RemoveWorldMapIcon(REF, pins.world)
    if pins.mini then HBDPins:RemoveMinimapIcon(REF, pins.mini) end
    for key, pin in pairs(pins) do
        pin:Hide()
        pin.node = nil
        table.insert(key == "world" and freeWorld or freeMini, pin)
    end
    pinsByNode[n] = nil
end

---------------------------------------------------------------------------
-- Build / update
---------------------------------------------------------------------------
local function UpdateAlpha()
    for _, pins in pairs(pinsByNode) do
        if pins.world then SetAlpha(pins.world) end
        if pins.mini then SetAlpha(pins.mini) end
    end
end

local function Rebuild()
    if not ns.db or not HBDPins then return end
    rebuilding = true
    for n in pairs(pinsByNode) do
        RemoveNodePins(n)
    end
    rebuilding = false
    wipe(grid)
    if ns.db.pinsHidden then return end
    for mapID, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            AddNodePins(mapID, n)
        end
    end
end

local rebuildPending = false
RequestRebuild = function()
    if rebuildPending then return end
    rebuildPending = true
    C_Timer.After(REBUILD_DELAY, function()
        rebuildPending = false
        Rebuild()
    end)
end

-- Database changed (see NotifyNodesChanged in Core.lua)
local function OnNodesChanged(kind, mapID, node)
    if not ns.db then return end
    if (kind == "add" or kind == "update") and mapID and node then
        -- "update": the position may have moved a bit. Only this node's pins
        -- are redrawn (never all of them: that would stutter while looting);
        -- other kinds sharing its spot stay attached to the new pin.
        local old = pinsByNode[node]
        local others = old and old.world and old.world.others
        RemoveNodePins(node, true)
        AddNodePins(mapID, node)
        local new = pinsByNode[node]
        if others and #others > 0 and new and new.world then
            new.world.others = others
            for _, o in ipairs(others) do pinsByNode[o] = { sharedWith = new.world } end
        end
    else
        RequestRebuild()
    end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
if not (HBD and HBDPins) then
    -- Library missing: tell the user once at login and do nothing else
    local warn = CreateFrame("Frame")
    warn:RegisterEvent("PLAYER_LOGIN")
    warn:SetScript("OnEvent", function()
        ns.Print(L["|cffff5555HereBeDragons not found, map pins are disabled.|r"])
    end)
    return
end

table.insert(ns.nodeListeners, OnNodesChanged)

ns.TogglePins = function()
    ns.db.pinsHidden = not ns.db.pinsHidden
    ns.Print(L["Map pins "] .. (ns.db.pinsHidden and L["|cffff0000hidden|r"] or L["|cff00ff00shown|r"]))
    Rebuild()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("ZONE_CHANGED_NEW_AREA")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        playerMap = ns.GetPlayerPos()
        C_Timer.After(1, Rebuild)
        C_Timer.NewTicker(3, UpdateAlpha) -- cooldowns run out
        return
    end
    -- New zone: move the minimap pins over
    C_Timer.After(0.5, function()
        local mapID = ns.GetPlayerPos()
        if mapID and mapID ~= playerMap then
            playerMap = mapID
            RequestRebuild()
        end
    end)
end)

-- /gcr pintest : why nodes of this zone have (no) pins
ns.PinTest = function()
    local mapID = ns.GetPlayerPos and ns.GetPlayerPos()
    ns.Print(("Pin check for %s (%s), pins hidden: %s"):format(tostring(mapID and ns.GetZoneName(mapID)), tostring(mapID),
        tostring(ns.db.pinsHidden)))
    local stats = {}
    local sample = {}
    for _, n in ipairs((mapID and ns.db.nodes[mapID]) or {}) do
        local t = n.type or "?"
        local s = stats[t] or { total = 0, enabled = 0, pinned = 0, shared = 0 }
        stats[t] = s
        s.total = s.total + 1
        if ns.IsNodeEnabled(n, mapID) then s.enabled = s.enabled + 1 end
        local p = pinsByNode[n]
        if p and p.world then s.pinned = s.pinned + 1 end
        if p and p.sharedWith then s.shared = s.shared + 1 end
        if not sample[t] then sample[t] = n end
    end
    for t, s in pairs(stats) do
        print(("  %s: %d nodes, %d enabled, %d with pin, %d shared"):format(t, s.total, s.enabled, s.pinned, s.shared))
        local n = sample[t]
        local p = pinsByNode[n]
        local w = p and (p.world or (p.sharedWith))
        print(("    e.g. %s id=%s key=%s item=%s icon=%s shown=%s"):format(tostring(n.name), tostring(n.id), tostring(ns.KindKey(n)),
            tostring(n.item), tostring(NodeIcon(n)), tostring(w and w:IsShown())))
    end
    local nKinds, nCont = 0, 0
    for _ in pairs(ns.db.disabledKinds or {}) do nKinds = nKinds + 1 end
    for _ in pairs(ns.db.disabledContinentKinds or {}) do nCont = nCont + 1 end
    print(("  unticked materials: %d in zones, %d on continents"):format(nKinds, nCont))
end
