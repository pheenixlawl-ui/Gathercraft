local ADDON_NAME, ns = ...

local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)

local WORLD_SIZE = 14
local MINI_SIZE = 12
local DIM_ALPHA = 0.35   -- nodes on cooldown or unchecked in /fg zones
local REF = ADDON_NAME   -- owner key for HereBeDragons

local TYPE_ICONS = {
    herb = "Interface\\Icons\\INV_Misc_Flower_02",
    ore = "Interface\\Icons\\INV_Ore_Copper_01",
}
local DEFAULT_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

---------------------------------------------------------------------------
-- Pin frames
---------------------------------------------------------------------------
local freeWorld, usedWorld = {}, {}
local freeMini, usedMini = {}, {}

local function NodeIcon(n)
    if n.item then
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
        GameTooltip:AddLine(n.type == "herb" and "Herb" or "Ore", 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(("Seen %d times"):format(n.count or 1), 0.8, 0.8, 0.8)
    if ns.IsOnCooldown(n) then
        GameTooltip:AddLine(("Harvested, respawn in ~%ds"):format(n.emptyUntil - time()), 1, 0.5, 0.5)
    end
    if not ns.IsNodeEnabled(n, pin.mapID) then
        GameTooltip:AddLine("Unchecked in /fg zones", 0.6, 0.6, 0.6)
    end
    GameTooltip:Show()
end

local function CreatePin(size)
    local pin = CreateFrame("Frame", nil, UIParent)
    pin:SetSize(size, size)
    pin.icon = pin:CreateTexture(nil, "OVERLAY")
    pin.icon:SetAllPoints()
    pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- crop the icon border
    pin:EnableMouse(true)
    pin:SetScript("OnEnter", ShowTooltip)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:Hide()
    return pin
end

local function Acquire(free, used, size)
    local pin = table.remove(free) or CreatePin(size)
    table.insert(used, pin)
    return pin
end

local function Release(free, used)
    for _, pin in ipairs(used) do
        pin:Hide()
        pin.node = nil
        table.insert(free, pin)
    end
    wipe(used)
end

---------------------------------------------------------------------------
-- Build / update
---------------------------------------------------------------------------
local function UpdateAlpha()
    for _, used in ipairs({ usedWorld, usedMini }) do
        for _, pin in ipairs(used) do
            local n = pin.node
            if n then
                local dim = ns.IsOnCooldown(n) or not ns.IsNodeEnabled(n, pin.mapID)
                pin:SetAlpha(dim and DIM_ALPHA or 1)
            end
        end
    end
end

local function Rebuild()
    if not ns.db or not HBDPins then return end
    HBDPins:RemoveAllWorldMapIcons(REF)
    HBDPins:RemoveAllMinimapIcons(REF)
    Release(freeWorld, usedWorld)
    Release(freeMini, usedMini)

    if ns.db.pinsHidden then return end

    local showFlag = HBD_PINS_WORLDMAP_SHOW_PARENT or 1
    for mapID, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            local icon = NodeIcon(n)

            local w = Acquire(freeWorld, usedWorld, WORLD_SIZE)
            w.node, w.mapID = n, mapID
            w.icon:SetTexture(icon)
            HBDPins:AddWorldMapIconMap(REF, w, mapID, n.x, n.y, showFlag)

            local m = Acquire(freeMini, usedMini, MINI_SIZE)
            m.node, m.mapID = n, mapID
            m.icon:SetTexture(icon)
            HBDPins:AddMinimapIconMap(REF, m, mapID, n.x, n.y, false, false)
        end
    end
    UpdateAlpha()
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

table.insert(ns.nodeListeners, Rebuild)

ns.TogglePins = function()
    ns.db.pinsHidden = not ns.db.pinsHidden
    ns.Print("Map pins " .. (ns.db.pinsHidden and "|cffff0000hidden|r" or "|cff00ff00shown|r"))
    Rebuild()
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    C_Timer.After(1, Rebuild)
    C_Timer.NewTicker(3, UpdateAlpha) -- cooldowns run out, zone selection changes
end)