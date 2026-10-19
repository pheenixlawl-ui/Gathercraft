local ADDON_NAME, ns = ...

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
        GameTooltip:AddLine(TYPE_LABELS[n.type] or n.type, 0.6, 0.6, 0.6)
    end
    if (n.count or 1) > 0 then
        GameTooltip:AddLine(("Seen %d times"):format(n.count or 1), 0.8, 0.8, 0.8)
    end
    if ns.SkillTooltip then
        ns.SkillTooltip(GameTooltip, n)
    end
    if n.source == "sync" then
        GameTooltip:AddLine("Shared by other players", 0.4, 0.8, 1)
    elseif n.source == "questie" then
        GameTooltip:AddLine("Known spawn point (Questie data)", 0.8, 0.7, 1)
    elseif n.source == "starter" then
        GameTooltip:AddLine("From the beta database (not confirmed yet)", 0.8, 0.7, 1)
    end
    if ns.IsOnCooldown(n) then
        GameTooltip:AddLine(("Harvested, respawn in ~%ds"):format(n.emptyUntil - time()), 1, 0.5, 0.5)
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

local function Sizes()
    local world = ns.db.pinSize or WORLD_SIZE
    return world, math.max(8, world - 2)
end

local function SetAlpha(pin)
    pin:SetAlpha(ns.IsOnCooldown(pin.node) and DIM_ALPHA or 1)
end

-- Adds the two pins (world map + minimap) of one node
-- Minimap pins only for the zone the player is in: with known spawn data a
-- continent can hold thousands of nodes, and every minimap pin costs time
-- while moving. The world map still shows every zone.
local playerMap

local function AddNodePins(mapID, n)
    if ns.db.pinsHidden or not ns.IsNodeEnabled(n, mapID) then return end
    local icon = NodeIcon(n)
    local worldSize, miniSize = Sizes()

    local w = table.remove(freeWorld) or CreatePin()
    w.node, w.mapID = n, mapID
    w:SetSize(worldSize, worldSize)
    w.icon:SetTexture(icon)
    SetAlpha(w)
    HBDPins:AddWorldMapIconMap(REF, w, mapID, n.x, n.y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)

    local m
    if mapID == playerMap then
        m = table.remove(freeMini) or CreatePin()
        m.node, m.mapID = n, mapID
        m:SetSize(miniSize, miniSize)
        m.icon:SetTexture(icon)
        SetAlpha(m)
        HBDPins:AddMinimapIconMap(REF, m, mapID, n.x, n.y, false, false)
    end

    pinsByNode[n] = { world = w, mini = m }
end

-- Removes the pins of one node
local function RemoveNodePins(n)
    local pins = pinsByNode[n]
    if not pins then return end
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
        SetAlpha(pins.world)
        if pins.mini then SetAlpha(pins.mini) end
    end
end

local function Rebuild()
    if not ns.db or not HBDPins then return end
    for n in pairs(pinsByNode) do
        RemoveNodePins(n)
    end
    if ns.db.pinsHidden then return end
    for mapID, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            AddNodePins(mapID, n)
        end
    end
end

local rebuildPending = false
local function RequestRebuild()
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
        RemoveNodePins(node)       -- "update": the position may have moved a bit
        AddNodePins(mapID, node)
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
        ns.Print("|cffff5555HereBeDragons not found, map pins are disabled.|r")
    end)
    return
end

table.insert(ns.nodeListeners, OnNodesChanged)

ns.TogglePins = function()
    ns.db.pinsHidden = not ns.db.pinsHidden
    ns.Print("Map pins " .. (ns.db.pinsHidden and "|cffff0000hidden|r" or "|cff00ff00shown|r"))
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
