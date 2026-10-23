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

-- Minimap style "subtle": a silver ring around a smaller, see-through icon,
-- so what the game's own herb/mineral tracking shows right now (or addons
-- like Node Sight) stands out against "a node usually spawns here".
-- The next node of a farm run gets a gold ring and is always shown.
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
local RING_SILVER, RING_GOLD = MEDIA .. "RingSilver", MEDIA .. "RingGold"
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SUBTLE_ICON_ALPHA = 0.6
local TARGET_REF = ADDON_NAME .. "Target"

local function WorldPinsShown() return not ns.db.worldPinsHidden end
local function MiniPinsShown() return not ns.db.miniPinsHidden end
-- Subtle is the default; "normal" only when chosen in the options
local function SubtleMini() return ns.db.miniPinStyle ~= "normal" end
ns.SubtleMinimap = SubtleMini
-- World map style "ring": the same silver ring, the icon stays fully visible
local function RingedWorld() return ns.db.worldPinStyle ~= "normal" end
ns.RingedWorldMap = RingedWorld

---------------------------------------------------------------------------
-- Pin frames
---------------------------------------------------------------------------
local freeWorld, freeMini = {}, {}
local pinsByNode = {}    -- node -> { world = pin, mini = pin }
local miniOn = {}        -- minimap pins in use (pin -> true)

local function NodeIcon(n)
    if n.item and n.type ~= "chest" then -- chest loot is random, keep the chest icon
        local icon
        if C_Item and C_Item.GetItemIconByID then
            icon = C_Item.GetItemIconByID(n.item)
        ---@diagnostic disable-next-line: deprecated -- fallback for clients without the C_ version
        elseif GetItemIcon then
            ---@diagnostic disable-next-line: deprecated
            icon = GetItemIcon(n.item)
        end
        if icon then return icon end
    end
    return TYPE_ICONS[n.type] or DEFAULT_ICON
end

-- What we know about a node, into a tooltip (GameTooltip or our own
-- minimap tooltip). under: right below the game's tooltip, which already
-- names it - a short "Gathercraft" heading instead of name and type
local function AddNodeLines(tt, n, pin, under)
    if under then
        tt:AddLine("Gathercraft", 1, 0.82, 0.3)
    else
        tt:AddLine(n.name, 1, 1, 1)
        if n.type then
            tt:AddLine(L[TYPE_LABELS[n.type] or n.type], 0.6, 0.6, 0.6)
        end
    end
    local GameTooltip = tt
    if n.pendingReport then
        GameTooltip:AddLine((L["Reported by %d player(s), not confirmed yet"]):format(n.pendingReport.rc or 1), 0.7, 0.7, 0.7)
        GameTooltip:AddLine(L["Not part of routes until you or other players confirm it."], 0.6, 0.6, 0.6, true)
    elseif (n.count or 1) > 0 then
        GameTooltip:AddLine((L["Seen %d times"]):format(n.count or 1), 0.8, 0.8, 0.8)
    end
    if ns.SkillTooltip then
        ns.SkillTooltip(GameTooltip, n)
    end
    -- (a chest's loot is random: one item's price says nothing)
    if n.item and n.type ~= "chest" and ns.GetPrice then
        local price, source = ns.GetPrice(n.item)
        if price then
            GameTooltip:AddLine((L["Worth: %s each  |cff999999(%s)|r"]):format(ns.Money(price), source), 1, 1, 1)
        end
    end
    if n.seenOnly then
        GameTooltip:AddLine(L["Seen on the minimap: position is a rough guess until you harvest it."], 0.6, 0.9, 0.6, true)
    end
    if n.source == "sync" then
        GameTooltip:AddLine(L["Shared by other players"], 0.4, 0.8, 1)
        if ns.IsParked and ns.IsParked(n) then
            GameTooltip:AddLine(L["Always empty so far: left out of routes until someone new reports it or you harvest it."], 1, 0.5, 0.5, true)
        end
    elseif n.source == "questie" then
        GameTooltip:AddLine(L["Known spawn point (Questie data)"], 0.8, 0.7, 1)
    elseif n.source == "starter" then
        GameTooltip:AddLine(L["From the beta database (not confirmed yet)"], 0.8, 0.7, 1)
    end
    local others = pin and (pin.others or (pin.othersOf and pin.othersOf.others))
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
    if n.unreachUntil and n.unreachUntil > time() then
        GameTooltip:AddLine((L["Hard to reach: left out of farm runs for %d min"]):format(math.ceil((n.unreachUntil - time()) / 60)), 1, 0.6, 0.2)
    end
end

local function ShowTooltip(pin)
    local n = pin.node
    if not n then return end
    if n.pendingReport and ns.SyncDisplayName then
        -- the item name may have loaded since the pin was made
        n.name = ns.SyncDisplayName(n.id, n.pendingReport.item, n.type)
    end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    AddNodeLines(GameTooltip, n, pin)
    GameTooltip:Show()
end

-- Core.lua fills its own minimap tooltip with this
function ns.AddNodeTooltipLines(tt, n, under)
    AddNodeLines(tt, n, pinsByNode[n] and pinsByNode[n].mini, under)
end

-- Pins on the same spot are drawn in a fixed order: your own finds on top,
-- shared and starter nodes below, known spawn points (Questie) at the bottom.
-- (HereBeDragons re-adds world map pins in random order on every redraw.)
local function Layer(n)
    if not n then return 1 end
    if n.pendingReport or n.source == "questie" then return 1 end
    if n.source == "sync" or n.source == "starter" then return 2 end
    return 3
end
local function KeepLayer(pin)
    local parent = pin:GetParent()
    local level = parent and parent.GetFrameLevel and parent:GetFrameLevel()
    if level and not pin.isTarget then pin:SetFrameLevel(level + (pin.layer or 1)) end
end

local function CreatePin()
    local pin = CreateFrame("Frame", nil, UIParent)
    pin:HookScript("OnShow", KeepLayer)
    pin.icon = pin:CreateTexture(nil, "OVERLAY")
    pin.icon:SetAllPoints()
    pin.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- crop the icon border
    pin:EnableMouse(true)
    pin:SetScript("OnEnter", ShowTooltip)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:Hide()
    return pin
end

-- ring = texture of a ring around a round icon, or nil for the plain square
-- icon. Pins are reused, so this always sets every part. Call after SetSize.
local function Decorate(pin, ring)
    if ring then
        if not pin.ring then
            pin.ring = pin:CreateTexture(nil, "OVERLAY", nil, 2)
            pin.ring:SetAllPoints()
        end
        pin.ring:SetTexture(ring)
        pin.ring:Show()
        local inset = math.max(1, math.floor((pin:GetWidth() or 12) * 0.17 + 0.5))
        pin.icon:ClearAllPoints()
        pin.icon:SetPoint("TOPLEFT", inset, -inset)
        pin.icon:SetPoint("BOTTOMRIGHT", -inset, inset)
        -- round icon inside the ring (clients without mask textures keep it square)
        if pin.mask == nil then
            pin.mask = pin.CreateMaskTexture and pin:CreateMaskTexture() or false
            if pin.mask then
                pin.mask:SetTexture(ROUND_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
                pin.mask:SetAllPoints(pin.icon)
            end
        end
        if pin.mask and not pin.masked and pin.icon.AddMaskTexture then
            pin.icon:AddMaskTexture(pin.mask)
            pin.masked = true
        end
    else
        if pin.ring then pin.ring:Hide() end
        pin.icon:ClearAllPoints()
        pin.icon:SetAllPoints()
        if pin.masked then
            pin.icon:RemoveMaskTexture(pin.mask)
            pin.masked = nil
        end
    end
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

-- the next node of a farm run (see below): its normal pins step aside
local target = { world = nil, mini = nil, mapID = nil, node = nil }

local PENDING_ALPHA = 0.5 -- unconfirmed reports from other players
local PARKED_ALPHA = 0.25 -- parked by self-healing (Sync.lua): always empty so far
-- Minimap opacity (Options): all minimap node pins, not the run target
local function Fade(pin, alpha)
    pin:SetAlpha(alpha * (pin.isMini and (ns.db.miniPinAlpha or 1) or 1))
end
local function SetAlpha(pin)
    local n = pin.node
    if not n then return end
    if n == target.node then
        pin:SetAlpha(0) -- the bigger gold-ringed target pin stands here
        return
    end
    if n.pendingReport then
        Fade(pin, PENDING_ALPHA)
        pin.icon:SetAlpha(1)
        return
    end
    if ns.IsParked and ns.IsParked(n) then
        Fade(pin, PARKED_ALPHA)
        pin.icon:SetAlpha(1)
        return
    end
    Fade(pin, ns.IsOnCooldown(n) and DIM_ALPHA or (n.source and KNOWN_ALPHA or 1))
    pin.icon:SetAlpha(pin.subtle and SUBTLE_ICON_ALPHA or 1)
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
    -- the Zones tab picks what Start run farms; the map shows everything,
    -- unless the option says the map follows it too
    if ns.db.mapFollowsZones and not ns.IsNodeEnabled(n, mapID) then return end
    if n.type == "chest" and ns.db.chestsHidden then return end -- Options: chests off
    local showWorld = WorldPinsShown()
    local showMini = MiniPinsShown() and mapID == playerMap
    if not (showWorld or showMini) then return end
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

    local w, m
    if showWorld then
        w = table.remove(freeWorld) or CreatePin()
        w.node, w.mapID, w.isMini, w.layer = n, mapID, nil, Layer(n)
        w:EnableMouse(true)
        w:SetSize(worldSize, worldSize)
        w.icon:SetTexture(icon)
        w.icon:SetDesaturated(n.pendingReport and true or false)
        w.others = nil
        Decorate(w, (RingedWorld() and not n.pendingReport) and RING_SILVER or nil)
        SetAlpha(w)
        HBDPins:AddWorldMapIconMap(REF, w, mapID, n.x, n.y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
    end

    if showMini then
        m = table.remove(freeMini) or CreatePin()
        m.node, m.mapID, m.isMini, m.layer = n, mapID, true, Layer(n)
        m:EnableMouse(false) -- the game's blip below gets the mouse (Core.lua shows our tooltip)
        m:SetSize(miniSize, miniSize)
        m.icon:SetTexture(icon)
        m.icon:SetDesaturated(n.pendingReport and true or false)
        m.others = nil
        -- grey report pins keep their own look, so they never pass for "subtle"
        m.subtle = SubtleMini() and not n.pendingReport
        Decorate(m, m.subtle and RING_SILVER or nil)
        SetAlpha(m)
        HBDPins:AddMinimapIconMap(REF, m, mapID, n.x, n.y, false, false)
        miniOn[m] = true
    end

    -- the world map pin holds the list of kinds sharing the spot; without
    -- world map pins the minimap pin does
    local primary = w or m
    if n.source == "questie" then AddToGrid(mapID, primary) end
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
    local primary = pins.world or pins.mini
    if primary and primary.others and #primary.others > 0 and RequestRebuild and not rebuilding and not quiet then
        RequestRebuild() -- another kind takes over this spot
    end
    if pins.world then HBDPins:RemoveWorldMapIcon(REF, pins.world) end
    if pins.mini then
        HBDPins:RemoveMinimapIcon(REF, pins.mini)
        miniOn[pins.mini] = nil
    end
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

-- Unconfirmed reports in zones without known spawn points (new Forever
-- zones) get grey pins. They are drawn from proxy tables, never saved, never
-- routed. Only zones of the continent you are on: a flood of reports for far
-- away maps draws nothing.
local proxies = {} -- pending report -> its pin node (rebuilt with the pins)

local function PendingEligible(mapID)
    if not (WorldPinsShown() or MiniPinsShown()) then return false end
    if ns.HasKnownSpawns and ns.HasKnownSpawns(mapID) then return false end
    local here = playerMap and ns.GetContinent(playerMap)
    return here ~= nil and ns.GetContinent(mapID) == here
end

local function AddPendingPin(mapID, p)
    if not (p and p.x and p.y and p.type and p.type ~= "chest") then return end
    -- not where we know a node already (you picked it yourself meanwhile)
    if ns.FindNode(mapID, p.id, p.x, p.y, 10) then return end
    local proxy = proxies[p]
    if not proxy then
        proxy = {
            id = p.id, type = p.type, x = p.x, y = p.y, source = "pending",
            item = (p.item or 0) > 0 and p.item or nil, pendingReport = p,
            name = ns.SyncDisplayName and ns.SyncDisplayName(p.id, p.item, p.type) or "?",
        }
        proxies[p] = proxy
    end
    if not pinsByNode[proxy] then AddNodePins(mapID, proxy) end
end

local function RemovePendingPin(p)
    local proxy = p and proxies[p]
    if proxy then
        RemoveNodePins(proxy, true)
        proxies[p] = nil
    end
end

-- A node of ours or from sync appeared: grey pins of the same node there go
local function RemovePendingNear(mapID, node)
    local list = ns.SyncPending and ns.SyncPending(mapID)
    if not list or not node or node.pendingReport then return end
    for _, p in ipairs(list) do
        if proxies[p] and p.id == node.id and ns.Distance(mapID, p.x, p.y, node.x, node.y) <= 10 then
            RemovePendingPin(p)
        end
    end
end

---------------------------------------------------------------------------
-- The next node of a farm run: a bigger pin with a gold ring on the world map
-- and minimap (it sticks to the minimap edge while far away). Shown even when
-- node pins are switched off. Replaces the game's own waypoint marker.
---------------------------------------------------------------------------
local function Raise(pin)
    local parent = pin:GetParent()
    local level = parent and parent.GetFrameLevel and parent:GetFrameLevel()
    if level then pin:SetFrameLevel(level + 10) end
end

local function TargetPin()
    local pin = CreatePin()
    pin.isTarget = true
    Decorate(pin, RING_GOLD)
    -- the world map hands the pin to a new parent each time it opens
    pin:HookScript("OnShow", Raise)
    if pin.ring and pin.ring.CreateAnimationGroup then
        local pulse = pin.ring:CreateAnimationGroup()
        local fade = pulse and pulse:CreateAnimation("Alpha")
        if fade then
            fade:SetFromAlpha(1)
            fade:SetToAlpha(0.45)
            fade:SetDuration(0.8)
            pulse:SetLooping("BOUNCE")
            pin.pulse = pulse
        end
    end
    return pin
end

-- normal pins of a node: alpha again (0 while it is the target)
local function RefreshNodeAlpha(n)
    local pins = n and pinsByNode[n]
    if not pins then return end
    if pins.sharedWith then
        SetAlpha(pins.sharedWith)
        return
    end
    if pins.world then SetAlpha(pins.world) end
    if pins.mini then SetAlpha(pins.mini) end
end

local function RemoveTargetPins()
    HBDPins:RemoveAllWorldMapIcons(TARGET_REF)
    HBDPins:RemoveAllMinimapIcons(TARGET_REF)
    for _, pin in ipairs({ target.world, target.mini }) do
        if pin then
            pin:Hide()
            if pin.pulse then pin.pulse:Stop() end
        end
    end
end

local function PlaceTarget()
    RemoveTargetPins()
    local n, mapID = target.node, target.mapID
    if not (n and mapID and n.x and n.y) then return end
    local worldSize, miniSize = Sizes()
    target.world = target.world or TargetPin()
    target.mini = target.mini or TargetPin()
    for _, pair in ipairs({ { target.world, math.floor(worldSize * 1.7 + 0.5) }, { target.mini, math.max(16, math.floor(miniSize * 1.6 + 0.5)) } }) do
        local pin, size = pair[1], pair[2]
        pin.node, pin.mapID, pin.others = n, mapID, nil
        pin:SetSize(size, size)
        Decorate(pin, RING_GOLD) -- the icon inset follows the size
        pin.icon:SetTexture(NodeIcon(n))
        pin.icon:SetDesaturated(false)
        pin.icon:SetAlpha(1)
        pin:SetAlpha(1)
    end
    target.world:EnableMouse(true)
    target.mini:EnableMouse(false) -- like all minimap pins (see AddNodePins)
    HBDPins:AddWorldMapIconMap(TARGET_REF, target.world, mapID, n.x, n.y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
    HBDPins:AddMinimapIconMap(TARGET_REF, target.mini, mapID, n.x, n.y, false, true)
    for _, pin in ipairs({ target.world, target.mini }) do
        Raise(pin)
        if pin.pulse then pin.pulse:Play() end
    end
end

-- The minimap pin under the cursor (they let the mouse through, so the game
-- doesn't tell us): the run target first, else the one nearest the cursor
function ns.MinimapPinUnderCursor()
    local function over(pin)
        return pin and pin:IsShown() and pin.IsMouseOver and pin:IsMouseOver() and (pin:GetAlpha() or 1) > 0
    end
    if over(target.mini) then return target.mini end
    local cx, cy = GetCursorPosition()
    local best, bestD
    for pin in pairs(miniOn) do
        if over(pin) then
            local px, py = pin:GetCenter()
            local es = pin:GetEffectiveScale() or 1
            local d = (px and cx) and ((cx / es - px) ^ 2 + (cy / es - py) ^ 2) or 0
            if not bestD or d < bestD then best, bestD = pin, d end
        end
    end
    return best
end

local function SetRouteTarget(mapID, node)
    if target.node == node and target.mapID == mapID then return end
    local old = target.node
    target.node, target.mapID = node, mapID
    RefreshNodeAlpha(old)
    RefreshNodeAlpha(node)
    PlaceTarget()
end

local function ClearRouteTarget()
    if not target.node then return end
    local old = target.node
    target.node, target.mapID = nil, nil
    RefreshNodeAlpha(old)
    RemoveTargetPins()
end

local function Rebuild()
    if not ns.db or not HBDPins then return end
    rebuilding = true
    for n in pairs(pinsByNode) do
        RemoveNodePins(n)
    end
    rebuilding = false
    wipe(grid)
    wipe(proxies) -- old reports (imported, expired) are let go here
    if target.node then PlaceTarget() end -- the pin size may have changed
    if not (WorldPinsShown() or MiniPinsShown()) then return end
    for mapID, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            AddNodePins(mapID, n)
        end
    end
    -- grey pins: what another player reported in a new zone (see above)
    local pending = ns.db.sync and ns.db.sync.pending
    for mapID, list in pairs(pending or {}) do
        if PendingEligible(mapID) then
            for _, p in ipairs(list) do AddPendingPin(mapID, p) end
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
        local oldPrimary = old and (old.world or old.mini)
        local others = oldPrimary and oldPrimary.others
        RemoveNodePins(node, true)
        AddNodePins(mapID, node)
        if node == target.node then PlaceTarget() end -- the gold ring moves with it
        local new = pinsByNode[node]
        local newPrimary = new and (new.world or new.mini)
        if others and #others > 0 and newPrimary then
            newPrimary.others = others
            for _, o in ipairs(others) do pinsByNode[o] = { sharedWith = newPrimary } end
        end
        RemovePendingNear(mapID, node)
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

-- Sync: one report arrived ("add") or left ("remove": confirmed, or the
-- oldest dropped). Only that report's pin changes, nothing is rebuilt.
ns.OnPendingChanged = function(mapID, p, what)
    if what == "remove" then
        RemovePendingPin(p)
    elseif what == "add" and PendingEligible(mapID) then
        AddPendingPin(mapID, p)
    end
end

-- /gcr pins: all node pins (world map and minimap) off, or both on again
ns.TogglePins = function()
    local hide = WorldPinsShown() or MiniPinsShown()
    ns.db.worldPinsHidden, ns.db.miniPinsHidden = hide or nil, hide or nil
    ns.Print(L["Map pins "] .. (hide and L["|cffff0000hidden|r"] or L["|cff00ff00shown|r"]))
    Rebuild()
end

-- older versions had one switch for map and minimap
ns.MigratePinSwitches = function()
    if ns.db.pinsHidden ~= nil then
        local hidden = ns.db.pinsHidden and true or nil
        ns.db.worldPinsHidden, ns.db.miniPinsHidden = hidden, hidden
        ns.db.pinsHidden = nil
    end
end

ns.SetRouteTarget = SetRouteTarget
ns.ClearRouteTarget = ClearRouteTarget

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("ZONE_CHANGED_NEW_AREA")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        ns.MigratePinSwitches()
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
    ns.Print(("Pin check for %s (%s), world map pins: %s, minimap pins: %s (%s)"):format(tostring(mapID and ns.GetZoneName(mapID)),
        tostring(mapID), tostring(WorldPinsShown()), tostring(MiniPinsShown()), tostring(SubtleMini() and "subtle" or "normal")))
    local stats = {}
    local sample = {}
    for _, n in ipairs((mapID and ns.db.nodes[mapID]) or {}) do
        local t = n.type or "?"
        local s = stats[t] or { total = 0, enabled = 0, pinned = 0, shared = 0 }
        stats[t] = s
        s.total = s.total + 1
        if ns.IsNodeEnabled(n, mapID) then s.enabled = s.enabled + 1 end
        local p = pinsByNode[n]
        if p and (p.world or p.mini) then s.pinned = s.pinned + 1 end
        if p and p.sharedWith then s.shared = s.shared + 1 end
        if not sample[t] then sample[t] = n end
    end
    for t, s in pairs(stats) do
        print(("  %s: %d nodes, %d enabled, %d with pin, %d shared"):format(t, s.total, s.enabled, s.pinned, s.shared))
        local n = sample[t]
        local p = pinsByNode[n]
        local w = p and (p.world or p.mini or p.sharedWith)
        print(("    e.g. %s id=%s key=%s item=%s icon=%s shown=%s"):format(tostring(n.name), tostring(n.id), tostring(ns.KindKey(n)),
            tostring(n.item), tostring(NodeIcon(n)), tostring(w and w:IsShown())))
    end
    local nKinds, nCont = 0, 0
    for _ in pairs(ns.db.disabledKinds or {}) do nKinds = nKinds + 1 end
    for _ in pairs(ns.db.disabledContinentKinds or {}) do nCont = nCont + 1 end
    print(("  unticked materials: %d in zones, %d on continents"):format(nKinds, nCont))
end
