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
-- "Ring only" on the minimap: the run target is a broader gold ring without
-- an icon, so the yellow dot of the game's tracking shows in its middle too
local RING_GOLD_BOLD = MEDIA .. "RingGoldBold"
local ROUND_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local SUBTLE_ICON_ALPHA = 0.6
local TARGET_REF = ADDON_NAME .. "Target"

-- Leveling (Options → Leveling): the ring of a pin in the trainer's colour
-- for your skill, so you see at a glance what still levels you. Only while
-- the profession can still go up; nodes without a known requirement (new
-- Forever kinds) keep the silver ring. A white ring, tinted.
local RING_WHITE = MEDIA .. "RingWhite"
local SKILL_TINT = {
    orange = { 1, 0.55, 0.2 }, yellow = { 1, 0.95, 0.2 }, green = { 0.3, 0.95, 0.3 },
    grey = { 0.6, 0.6, 0.6 }, red = { 1, 0.2, 0.2 },
}
local SKILL_ORDER = { orange = 1, yellow = 2, green = 3, red = 4, grey = 5 } -- a shared spot: its best kind
local GREY_ALPHA = 0.6   -- grey nodes (no more skill-ups) step back
local MAX_SKILL = 300

local function SkillColorsOn() return not ns.db.skillColorsOff end
local function HideGrey() return ns.db.hideGreyNodes end

local function WorldPinsShown() return not ns.db.worldPinsHidden end
local function MiniPinsShown() return not ns.db.miniPinsHidden end
-- Minimap style: "ring" (only a ring, no icon: the game's yellow tracking
-- dot shows in the middle) is the default since 0.1.17; "subtle" and
-- "normal" when chosen in the options. Up to 0.1.16 subtle was the default
-- and was saved as nothing, so a saved "nothing" now means ring.
local MINI_STYLES = { normal = true, subtle = true, ring = true }
local function MiniStyle()
    local s = ns.db.miniPinStyle
    return MINI_STYLES[s] and s or "ring"
end
ns.MiniPinStyle = MiniStyle
local function SubtleMini() return MiniStyle() == "subtle" end
ns.SubtleMinimap = SubtleMini
-- "ring": without a skill colour the ring tells the kind apart
local KIND_TINT = { herb = { 0.45, 0.95, 0.75 }, ore = { 0.95, 0.75, 0.45 }, chest = { 1, 0.9, 0.5 } }
-- World map style "ring": the same silver ring, the icon stays fully visible
local function RingedWorld() return ns.db.worldPinStyle ~= "normal" end
ns.RingedWorldMap = RingedWorld

---------------------------------------------------------------------------
-- Pin frames
---------------------------------------------------------------------------
local freeWorld, freeMini = {}, {}
local pinsByNode = {}    -- node -> { world = pin, mini = pin }
local miniOn = {}        -- minimap pins in use (pin -> true)

-- Your skill, read once per check (not once per pin: a continent has
-- thousands), and each kind's colour for it
local skillNow = {}      -- "herb"/"ore" -> { rank, with bonus, max rank } or false
local levelCache = {}    -- kind key -> colour, or false for none
local levelArgs = {}     -- kind key -> { type, name, id } (to work it out again)
local skillSig

local function LevelKey(n) return n.type .. ":" .. tostring(n.id or n.name) end

local function ComputeLevel(nodeType, name, id)
    local skill = skillNow[nodeType]
    if not (skill and skill[1] < MAX_SKILL and ns.SkillLevel) then return false end
    -- at the end of a rank (75/75...): no skill-ups until you train, silver
    if skill[3] and skill[3] > 0 and skill[1] >= skill[3] then return false end
    return ns.SkillLevel(name, id, skill[1], skill[2]) or false
end

-- The trainer colour of one node, or nil
local function NodeLevel(n)
    if not (n and n.type) or n.type == "chest" or n.pendingReport then return nil end
    local key = LevelKey(n)
    local c = levelCache[key]
    if c == nil then
        c = ComputeLevel(n.type, n.name, n.id)
        levelCache[key], levelArgs[key] = c, { n.type, n.name, n.id }
    end
    return c or nil
end

-- Reads your skill. Returns whether a colour changed, and whether a node
-- became grey or stopped being grey (then hidden nodes have to change)
local function CheckSkills()
    local sig = ""
    for _, t in ipairs({ "herb", "ore" }) do
        local rank, maxRank, eff
        if ns.GetSkill then rank, maxRank, eff = ns.GetSkill(t) end
        if rank then
            skillNow[t] = { rank, eff or rank, maxRank }
        elseif not (ns.SkillListIncomplete and ns.SkillListIncomplete()) then
            skillNow[t] = false -- not learned (or unlearned)
        end
        -- else nothing read (a collapsed header in the skill window): keep what we knew
        local s = skillNow[t] or false
        skillNow[t] = s
        sig = sig .. t .. (s and (s[1] .. "/" .. s[2] .. "/" .. tostring(s[3])) or "-") .. ";"
    end
    if sig == skillSig then return false, false end
    skillSig = sig
    local changed, greyChanged = false, false
    for key, args in pairs(levelArgs) do
        local c = ComputeLevel(args[1], args[2], args[3])
        local old = levelCache[key]
        if c ~= old then
            changed = true
            if (c == "grey") ~= (old == "grey") then greyChanged = true end
            levelCache[key] = c
        end
    end
    return changed, greyChanged
end

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
        local count = n.count or 1
        GameTooltip:AddLine(count == 1 and L["Seen 1 time"] or (L["Seen %d times"]):format(count), 0.8, 0.8, 0.8)
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
        GameTooltip:AddLine(L["Gathercraft starter data (not harvested by you yet)"], 0.8, 0.7, 1)
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
-- Minimap pins sit one level higher: the route line lies right above the
-- minimap and below every pin (Route.lua)
local function KeepLayer(pin)
    local parent = pin:GetParent()
    local level = parent and parent.GetFrameLevel and parent:GetFrameLevel()
    if level and not pin.isTarget then pin:SetFrameLevel(level + (pin.layer or 1) + (pin.isMini and 1 or 0)) end
end

-- World map pins: their tooltip always (the default, as before), or only
-- with Shift (0.2.2 P1; a CurseForge comment, 21.11.2026: our pins lay on
-- quest symbols and took the mouse from them). "shift": without Shift a
-- world map pin takes no mouse - what lies below it gets it -, with Shift
-- held as before. The shown world map pins are kept in a set (OnShow and
-- OnHide of our own pins); a Shift press goes over that set only, from the
-- game's MODIFIER_STATE_CHANGED - no OnUpdate, and the event is registered
-- only while the choice is "shift". EnableMouse on our own frames (no
-- secure template, nothing protected hangs on them) is allowed in combat.
local worldShown = {} -- shown world map pins (pin -> true)
local function WorldTipShift() return ns.db ~= nil and ns.db.worldPinTip == "shift" end
local function WorldMouse()
    if not WorldTipShift() then return true end
    return IsShiftKeyDown and IsShiftKeyDown() and true or false
end
-- (0.2.2 P2e) the pass every 3 s (UpdateAlpha) looks at the shown world map
-- pins only: one that comes into sight gets its colour and alpha now
local RefreshPin -- (below, once Tint and SetAlpha are there)
local function WorldPinShown(pin)
    if not pin.isWorld then return end
    worldShown[pin] = true
    pin:EnableMouse(WorldMouse())
    if RefreshPin and pin.node and not pin.isTarget then RefreshPin(pin) end
end
local function WorldPinHidden(pin) worldShown[pin] = nil end

local function CreatePin()
    local pin = CreateFrame("Frame", nil, UIParent)
    pin:HookScript("OnShow", KeepLayer)
    pin:HookScript("OnShow", WorldPinShown)
    pin:HookScript("OnHide", WorldPinHidden)
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

-- The colour of a pin: its node's, or for a spot several kinds share the
-- best of them (Copper or Tin can be there: Tin levels you, so it counts)
local function PinLevel(pin)
    if not SkillColorsOn() then return nil end
    local best = NodeLevel(pin.node)
    local unknown = best == nil
    local others = pin.others or (pin.othersOf and pin.othersOf.others)
    for _, o in ipairs(others or {}) do
        local c = NodeLevel(o)
        if not c then
            unknown = true
        elseif not best or SKILL_ORDER[c] < SKILL_ORDER[best] then
            best = c
        end
    end
    -- grey, but an unknown kind can be there too: no verdict
    if best == "grey" and unknown then return nil end
    return best
end

-- A plan run ("Farm for plan", PlanFarm.lua) lights the nodes of its
-- materials and dims the rest - as a factor worked out HERE, every time a
-- pin gets its alpha or its ring colour, from the run as it is now. Nothing
-- of it is kept at the pin: pins are taken from a pool and used again, and
-- minimap pins come and go. No plan run: no factor, nothing changes.
--   1: a node of a material the plan still needs (any kind at a shared spot)
--   2: a kind your own gathers found such a material at ("seen"): weaker
--   0: everything else, dimmed
local PLAN_DIM_ALPHA, PLAN_SEEN_ALPHA = 0.35, 0.65
local PLAN_GOLD = { 1, 0.82, 0.1 }
local function PlanGlow(pin)
    local glowFor = ns.PlanGlowFor
    if not glowFor then return nil end
    local glow = glowFor(pin.node)
    if glow == nil or glow == 1 then return glow end
    local others = pin.others or (pin.othersOf and pin.othersOf.others)
    for _, o in ipairs(others or {}) do
        local g = glowFor(o)
        if g == 1 then return 1 end
        if g == 2 then glow = 2 end
    end
    if pin.othersOf and pin.othersOf.node then
        local g = glowFor(pin.othersOf.node)
        if g == 1 then return 1 end
        if g == 2 then glow = 2 end
    end
    return glow
end

-- The ring in the trainer colour (pins with a ring only). Call after Decorate.
local function Tint(pin)
    if not pin or pin.isTarget then return end
    pin.level = nil
    if not (pin.ring and pin.ring:IsShown()) then return end
    local level = PinLevel(pin)
    pin.level = level
    if PlanGlow(pin) == 1 then
        -- a node of the plan: a gold ring (the level stays what it is)
        pin.ring:SetTexture(RING_WHITE)
        pin.ring:SetVertexColor(PLAN_GOLD[1], PLAN_GOLD[2], PLAN_GOLD[3])
        return
    end
    local kind = not level and pin.ringOnly and KIND_TINT[pin.node and pin.node.type]
    if level or kind then
        local c = level and SKILL_TINT[level] or kind
        pin.ring:SetTexture(RING_WHITE)
        pin.ring:SetVertexColor(c[1], c[2], c[3])
    else
        pin.ring:SetTexture(RING_SILVER)
        pin.ring:SetVertexColor(1, 1, 1)
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
-- questing mode (Quest.lua): node -> its gold ring on the minimap
local questLit = {}

local PENDING_ALPHA = 0.5 -- unconfirmed reports from other players
local PARKED_ALPHA = 0.25 -- parked by self-healing (Sync.lua): always empty so far
-- Minimap opacity (Options): all minimap node pins, not the run target
local function Fade(pin, alpha)
    -- (the plan run's factor only ever multiplies: a hidden pin stays hidden)
    local glow = PlanGlow(pin)
    if glow == 0 then alpha = alpha * PLAN_DIM_ALPHA elseif glow == 2 then alpha = alpha * PLAN_SEEN_ALPHA end
    pin:SetAlpha(alpha * (pin.isMini and (ns.db.miniPinAlpha or 1) or 1))
end
local function SetAlpha(pin)
    local n = pin.node
    if not n then return end
    if n == target.node or (pin.isMini and questLit[n]) then
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
    local alpha = ns.IsOnCooldown(n) and DIM_ALPHA or (n.source and KNOWN_ALPHA or 1)
    if pin.level == "grey" then alpha = alpha * GREY_ALPHA end
    Fade(pin, alpha)
    pin.icon:SetAlpha(pin.subtle and SUBTLE_ICON_ALPHA or 1)
end
RefreshPin = function(pin)
    Tint(pin)
    SetAlpha(pin)
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

---------------------------------------------------------------------------
-- Minimap pins only near you (v0.1.23 P1)
--   Sven, 13.11.2026, Stranglethorn, walking: Gathercraft up to 20 % of the
--   addon time, 5 % with the minimap pins off. HereBeDragons works through
--   every registered minimap pin on each frame you move - also the ones half
--   a zone away. So every node of your zone still has its pin frame, with
--   its look and the kinds sharing its spot, but only the ones near you are
--   registered with HereBeDragons (and only those are on the screen).
--     MINI_IN / MINI_OUT: registered from 400 yd, taken off beyond 450 yd.
--       The minimap shows 233 yd at its widest zoom outdoors, a square one
--       about 330 yd into its corners; 400 leaves 70 yd for what you ride
--       until the next look. 50 yd between on and off: no flicker at the edge.
--     MINI_MOVE / MINI_EVERY: looked at again once you are 50 yd from the
--       last look, and after 2 s when you moved at all. Not while you stand.
--     MINI_CELL: the zone in squares of 150 yd, so a look goes through the
--       squares in reach and not through the zone.
---------------------------------------------------------------------------
local MINI_IN, MINI_OUT = 400, 450
local MINI_MOVE, MINI_EVERY, MINI_TICK = 50, 2, 0.5
local MINI_CELL = 150
local miniAll = {}       -- every minimap pin of your zone, near or not (pin -> true)
local miniCells = {}     -- square -> { pin, ... }
local miniCount = { near = 0, zone = 0 }
local here = {}          -- where the last look was: map, x, y, t; w, h = the zone in yards

local function ZoneYards(mapID)
    local w, h
    if C_Map.GetMapWorldSize then w, h = C_Map.GetMapWorldSize(mapID) end
    if not w or w == 0 then w, h = 1000, 1000 end -- as ns.Distance does
    return w, h
end

local function MiniCell(x, y)
    return math.floor(x * here.w / MINI_CELL) * 4096 + math.floor(y * here.h / MINI_CELL)
end

-- yards from the last look to a node, or nil when we do not know where you are
local function MiniDist(n)
    if not (here.x and n and n.x and n.y) then return nil end
    local dx, dy = (n.x - here.x) * here.w, (n.y - here.y) * here.h
    return math.sqrt(dx * dx + dy * dy)
end

-- Where you are, for the pins of mapID. False: not known, or not in that zone
local function MiniHere(mapID)
    local map, x, y = ns.GetPlayerPos()
    if here.map ~= mapID then
        here.map = mapID
        here.w, here.h = ZoneYards(mapID or 0)
        here.x, here.y = nil, nil
    end
    if not (map and x and y and map == mapID) then return false end
    here.x, here.y, here.t = x, y, GetTime()
    return true
end

local function MiniOn(m)
    if miniOn[m] then return end
    local n = m.node
    HBDPins:AddMinimapIconMap(REF, m, m.mapID, n.x, n.y, false, false)
    miniOn[m] = true
    miniCount.near = miniCount.near + 1
end

local function MiniOff(m)
    if not miniOn[m] then return end
    HBDPins:RemoveMinimapIcon(REF, m)
    miniOn[m] = nil
    miniCount.near = miniCount.near - 1
end

-- a pin frame leaves the zone's books (its node went, or the zone did)
local function MiniForget(m, bulk)
    MiniOff(m)
    if not miniAll[m] then return end
    miniAll[m] = nil
    miniCount.zone = miniCount.zone - 1
    local cell = not bulk and m.cell and miniCells[m.cell]
    if cell then
        for i = #cell, 1, -1 do
            if cell[i] == m then table.remove(cell, i) break end
        end
        if #cell == 0 then miniCells[m.cell] = nil end
    end
    m.cell = nil
end

-- Which pins are near now: off what is beyond MINI_OUT, on what is within
-- MINI_IN. Goes through the registered pins and the squares in reach.
local function MiniLook()
    for m in pairs(miniOn) do
        local d = MiniDist(m.node)
        if not d or d > MINI_OUT then MiniOff(m) end
    end
    if not here.x then return end
    local cx0, cx1 = math.floor((here.x * here.w - MINI_IN) / MINI_CELL), math.floor((here.x * here.w + MINI_IN) / MINI_CELL)
    local cy0, cy1 = math.floor((here.y * here.h - MINI_IN) / MINI_CELL), math.floor((here.y * here.h + MINI_IN) / MINI_CELL)
    for cx = cx0, cx1 do
        for cy = cy0, cy1 do
            local cell = miniCells[cx * 4096 + cy]
            if cell then
                for i = 1, #cell do
                    local m = cell[i]
                    if not miniOn[m] and (MiniDist(m.node) or MINI_OUT) <= MINI_IN then MiniOn(m) end
                end
            end
        end
    end
end

-- /gcr perf: how many minimap pins are registered, and how many the zone has
ns.MiniPinCounts = function() return miniCount.near, miniCount.zone end
-- one look now, whatever the clock says (the tests measure it with this)
ns.MiniPinLook = function()
    if here.map and MiniHere(here.map) then MiniLook() end
end

-- The minimap pin of a node (only nodes of the zone you are in have one, and
-- only the ones near you are registered: see above).
-- world: the node's world map pin, which holds the kinds sharing its spot;
-- linked before the colour is worked out (the spot shows its best kind)
local function AddMiniPin(mapID, n, world)
    local _, miniSize = Sizes(n)
    local m = table.remove(freeMini) or CreatePin()
    m.node, m.mapID, m.isMini, m.layer = n, mapID, true, Layer(n)
    m.othersOf = world
    m:EnableMouse(false) -- the game's blip below gets the mouse (Core.lua shows our tooltip)
    m:SetSize(miniSize, miniSize)
    m.icon:SetTexture(NodeIcon(n))
    m.icon:SetDesaturated(n.pendingReport and true or false)
    m.others = nil
    -- grey report pins keep their own look, so they never pass for "subtle"
    local style = MiniStyle()
    m.subtle = style == "subtle" and not n.pendingReport
    m.ringOnly = style == "ring" and not n.pendingReport
    Decorate(m, (m.subtle or m.ringOnly) and RING_SILVER or nil)
    m.icon:SetShown(not m.ringOnly)
    Tint(m)
    SetAlpha(m)
    if here.map ~= mapID then MiniHere(mapID) end
    miniAll[m] = true
    miniCount.zone = miniCount.zone + 1
    if n.x and n.y then -- (a node without a place is in no square: it is never near)
        m.cell = MiniCell(n.x, n.y)
        local cell = miniCells[m.cell]
        if not cell then
            cell = {}
            miniCells[m.cell] = cell
        end
        cell[#cell + 1] = m
    end
    local d = MiniDist(n)
    if d and d <= MINI_IN then MiniOn(m) end
    return m
end

local function RemoveMiniPin(pins)
    local m = pins.mini
    if not m then return end
    MiniForget(m)
    m:Hide()
    m.node, m.othersOf = nil, nil
    table.insert(freeMini, m)
    pins.mini = nil
end

local function AddNodePins(mapID, n)
    -- the Zones tab picks what Start run farms; the map shows everything,
    -- unless the option says the map follows it too
    if ns.db.mapFollowsZones and not ns.IsNodeEnabled(n, mapID) then return end
    if ns.HiddenByProfession(n) then return end -- Options: only what you can gather
    if n.type == "chest" and ns.db.chestsHidden then return end -- Options: chests off
    if HideGrey() and NodeLevel(n) == "grey" then return end -- Options → Leveling
    local showWorld = WorldPinsShown()
    local showMini = MiniPinsShown() and mapID == playerMap
    if not (showWorld or showMini) then return end
    if n.source == "questie" then
        local shared = FindSharedPin(mapID, n)
        if shared then
            shared.others = shared.others or {}
            table.insert(shared.others, n)
            pinsByNode[n] = { sharedWith = shared }
            -- the spot's colour may change with the new kind
            local spot = pinsByNode[shared.node]
            if spot and spot.world then Tint(spot.world) SetAlpha(spot.world) end
            if spot and spot.mini then Tint(spot.mini) SetAlpha(spot.mini) end
            return
        end
    end
    local icon = NodeIcon(n)
    local worldSize = Sizes(n)

    local w, m
    if showWorld then
        w = table.remove(freeWorld) or CreatePin()
        w.node, w.mapID, w.isMini, w.layer, w.isWorld = n, mapID, nil, Layer(n), true
        w:EnableMouse(WorldMouse()) -- (see WorldMouse: always, or with Shift)
        w:SetSize(worldSize, worldSize)
        w.icon:SetTexture(icon)
        w.icon:SetDesaturated(n.pendingReport and true or false)
        w.others = nil
        Decorate(w, (RingedWorld() and not n.pendingReport) and RING_SILVER or nil)
        Tint(w)
        SetAlpha(w)
        HBDPins:AddWorldMapIconMap(REF, w, mapID, n.x, n.y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
    end

    if showMini then m = AddMiniPin(mapID, n, w) end

    -- the world map pin holds the list of kinds sharing the spot; without
    -- world map pins the minimap pin does
    local primary = w or m
    if n.source == "questie" then AddToGrid(mapID, primary) end
    pinsByNode[n] = { world = w, mini = m } -- m.othersOf = w (set in AddMiniPin)
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
        -- the spot's colour may have come from this kind
        local spot = pins.sharedWith.node and pinsByNode[pins.sharedWith.node]
        if spot and spot.world then Tint(spot.world) SetAlpha(spot.world) end
        if spot and spot.mini then Tint(spot.mini) SetAlpha(spot.mini) end
        return
    end
    local primary = pins.world or pins.mini
    if primary and primary.others and #primary.others > 0 and RequestRebuild and not rebuilding and not quiet then
        RequestRebuild() -- another kind takes over this spot
    end
    if pins.world then HBDPins:RemoveWorldMapIcon(REF, pins.world) end
    if pins.mini then MiniForget(pins.mini, rebuilding) end
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
-- Every few seconds: cooldowns run out, and your skill may have gone up.
-- (0.2.2 P2e; P2d's count with Sven's saved data: 19,472 world map pins in
-- 45 zones, every one of them looked at every 3 s, the map open or not.)
-- Only the pins that can be seen now: the world map pins shown (none while
-- the map is closed) and the minimap pins of your zone. A world map pin that
-- comes into sight gets its colour and alpha then (WorldPinShown).
-- Only when your skill changed a colour (rare: a skill-up, training, a
-- profession dropped) do all world map pins, shown or not, take it at once,
-- as before.
local greyRebuild = false
local function UpdateAlpha()
    local changed, greyChanged = CheckSkills()
    -- hidden grey nodes: the pins themselves change, a moment later (not
    -- right while you loot the node that gave the point)
    if greyChanged and HideGrey() and not greyRebuild then
        greyRebuild = true
        C_Timer.After(5, function()
            greyRebuild = false
            RequestRebuild()
        end)
    end
    if changed then
        for _, pins in pairs(pinsByNode) do
            if pins.world then
                Tint(pins.world)
                SetAlpha(pins.world)
            end
        end
    else
        for pin in pairs(worldShown) do
            -- (the run target's pin keeps its own look: SetAlpha would hide it)
            if pin.node and not pin.isTarget then SetAlpha(pin) end
        end
    end
    for m in pairs(miniAll) do
        if changed then Tint(m) end
        SetAlpha(m)
    end
end
ns.PinsUpdateAlpha = UpdateAlpha -- (the tests)

-- The plan run began, ended or needs other materials: every pin gets its
-- ring and its alpha anew, now (not with the next round a few seconds on)
ns.PlanPinsChanged = function()
    for _, pins in pairs(pinsByNode) do
        if pins.world then
            Tint(pins.world)
            SetAlpha(pins.world)
        end
        if pins.mini then
            Tint(pins.mini)
            SetAlpha(pins.mini)
        end
    end
end
-- a grey node the option "Hide grey nodes" keeps off the map (for the plan
-- run's line "N plan nodes hidden": the plan switches nothing on)
ns.PinHiddenGrey = function(n)
    return (HideGrey() and NodeLevel(n) == "grey") and true or false
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

-- The size of a gold ring on the minimap and whether it is bare (ring only:
-- no icon, the game's yellow tracking dot shows in its middle)
local function MiniTargetLook()
    local _, miniSize = Sizes()
    local ringOnly = MiniStyle() == "ring"
    return ringOnly and math.max(22, math.floor(miniSize * 2.2 + 0.5)) or math.max(16, math.floor(miniSize * 1.6 + 0.5)), ringOnly
end

local function PlaceTarget()
    RemoveTargetPins()
    local n, mapID = target.node, target.mapID
    if not (n and mapID and n.x and n.y) then return end
    local worldSize = Sizes()
    target.world = target.world or TargetPin()
    target.world.isWorld = true -- (the tooltip choice holds for it too)
    target.mini = target.mini or TargetPin()
    local miniTarget, ringOnly = MiniTargetLook()
    for _, pair in ipairs({ { target.world, math.floor(worldSize * 1.7 + 0.5), false }, { target.mini, miniTarget, ringOnly } }) do
        local pin, size, bare = pair[1], pair[2], pair[3]
        pin.node, pin.mapID, pin.others = n, mapID, nil
        pin:SetSize(size, size)
        Decorate(pin, bare and RING_GOLD_BOLD or RING_GOLD) -- the icon inset follows the size
        pin.icon:SetTexture(NodeIcon(n))
        pin.icon:SetDesaturated(false)
        pin.icon:SetAlpha(1)
        pin.icon:SetShown(not bare)
        pin:SetAlpha(1)
    end
    target.world:EnableMouse(WorldMouse())
    target.mini:EnableMouse(false) -- like all minimap pins (see AddNodePins)
    HBDPins:AddWorldMapIconMap(TARGET_REF, target.world, mapID, n.x, n.y, HBD_PINS_WORLDMAP_SHOW_PARENT or 1)
    HBDPins:AddMinimapIconMap(TARGET_REF, target.mini, mapID, n.x, n.y, false, true)
    for _, pin in ipairs({ target.world, target.mini }) do
        Raise(pin)
        if pin.pulse then pin.pulse:Play() end
    end
end

---------------------------------------------------------------------------
-- Questing mode (Quest.lua): the nodes near you that you can gather get a
-- gold ring as big as the run target's, on the minimap only. Quest.lua
-- picks them; here they are drawn. No pulse: several rings may be lit at
-- once. Always the thin gold ring (v0.1.21 T6; Sven, 10.11.2026: "der ist
-- mords dick"): in "Ring only" the run target alone has the broad one, and
-- the middle of a questing ring - the game's yellow dot - is wider.
---------------------------------------------------------------------------
local QUEST_REF = ADDON_NAME .. "Quest"
local questFree = {}
local questMap

local function QuestPin()
    local pin = table.remove(questFree)
    if pin then return pin end
    pin = CreatePin()
    pin.isTarget, pin.isQuest = true, true
    pin:HookScript("OnShow", Raise)
    return pin
end

local function LookQuest(pin, n)
    local size, bare = MiniTargetLook()
    pin.node, pin.mapID, pin.others = n, questMap, nil
    pin:SetSize(size, size)
    Decorate(pin, RING_GOLD)
    pin.icon:SetTexture(NodeIcon(n))
    pin.icon:SetDesaturated(false)
    pin.icon:SetAlpha(1)
    pin.icon:SetShown(not bare)
    pin:SetAlpha(1)
    pin:EnableMouse(false) -- like all minimap pins
end

local function DropQuest(n)
    local pin = questLit[n]
    if not pin then return end
    HBDPins:RemoveMinimapIcon(QUEST_REF, pin)
    pin:Hide()
    pin.node = nil
    questFree[#questFree + 1] = pin
    questLit[n] = nil
    RefreshNodeAlpha(n)
end

-- mapID and the set of nodes to light (node -> true); nil, nil: none
local function SetQuestRings(mapID, want)
    want = want or {}
    if mapID ~= questMap then
        for n in pairs(questLit) do DropQuest(n) end
        questMap = mapID
    end
    for n in pairs(questLit) do
        if not want[n] then DropQuest(n) end
    end
    if not (HBDPins and mapID) then return end
    for n in pairs(want) do
        if not questLit[n] and n.x and n.y then
            local pin = QuestPin()
            questLit[n] = pin
            LookQuest(pin, n)
            HBDPins:AddMinimapIconMap(QUEST_REF, pin, mapID, n.x, n.y, false, false)
            Raise(pin)
            RefreshNodeAlpha(n)
        end
    end
end
ns.SetQuestRings = SetQuestRings
ns.QuestRings = function() return questLit end

-- the style or pin size changed: every lit ring takes the new look
local function RestyleQuest()
    for n, pin in pairs(questLit) do
        HBDPins:RemoveMinimapIcon(QUEST_REF, pin)
        LookQuest(pin, n)
        HBDPins:AddMinimapIconMap(QUEST_REF, pin, questMap, n.x, n.y, false, false)
        Raise(pin)
    end
end

-- The minimap pin under the cursor (they let the mouse through, so the game
-- doesn't tell us): the run target first, else the one nearest the cursor
function ns.MinimapPinUnderCursor()
    local function over(pin)
        return pin and pin:IsShown() and pin.IsMouseOver and pin:IsMouseOver() and (pin:GetAlpha() or 1) > 0
    end
    if over(target.mini) then return target.mini end
    for _, pin in pairs(questLit) do -- its normal pin is hidden below it
        if over(pin) then return pin end
    end
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
    wipe(miniCells) -- (the pins left the books above; the lists are dropped here in one go)
    MiniHere(playerMap)
    wipe(grid)
    wipe(proxies) -- old reports (imported, expired) are let go here
    if target.node then PlaceTarget() end -- the pin size may have changed
    RestyleQuest()
    if not (WorldPinsShown() or MiniPinsShown()) then return end
    CheckSkills()
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
            if new.world then Tint(new.world) SetAlpha(new.world) end
            if new.mini then Tint(new.mini) SetAlpha(new.mini) end
        elseif others and #others > 0 then
            -- the node got no pin now (hidden: grey, chests off, ...): the
            -- other kinds of its spot need one of their own
            RequestRebuild()
        end
        RemovePendingNear(mapID, node)
    else
        RequestRebuild()
    end
end

-- Into another zone of the same continent (Thunder Bluff <-> Mulgore): only
-- the minimap pins move over, the world map pins stay as they are. A full
-- rebuild would take all world map pins of every loaded zone off and on
-- again for nothing. Another continent (grey report pins depend on it) or
-- no world map pins (then the minimap pin holds a spot's kinds): rebuild.
local function MovePlayerMap(old, new)
    if not (old and WorldPinsShown()) or ns.GetContinent(old) ~= ns.GetContinent(new) then
        RequestRebuild()
        return
    end
    if not MiniPinsShown() then return end
    MiniHere(new)
    local moved = { off = 0, on = 0 }
    local function Each(mapID, fn)
        for _, n in ipairs(ns.db.nodes[mapID] or {}) do fn(n) end
        local pending = ns.db.sync and ns.db.sync.pending and ns.db.sync.pending[mapID]
        for _, p in ipairs(pending or {}) do
            if proxies[p] then fn(proxies[p]) end
        end
    end
    Each(old, function(n)
        local pins = pinsByNode[n]
        if pins and pins.mini then
            RemoveMiniPin(pins)
            moved.off = moved.off + 1
        end
    end)
    Each(new, function(n)
        local pins = pinsByNode[n]
        if pins and pins.world and not pins.mini then
            pins.mini = AddMiniPin(new, n, pins.world)
            moved.on = moved.on + 1
        end
    end)
    ns.Debug(("minimap pins: zone %s -> %s, %d off, %d on (world map pins kept)"):format(
        tostring(old), tostring(new), moved.off, moved.on))
end

-- Minimap pins near you (see MiniLook): every half second, did you move far
-- enough, or long enough ago?
local function MiniTick()
    if not (ns.db and playerMap) or miniCount.zone == 0 then return end
    local map, x, y = ns.GetPlayerPos()
    if not (map and x and y and map == playerMap and here.map == map) then return end
    if here.x then
        local dx, dy = (x - here.x) * here.w, (y - here.y) * here.h
        local moved = math.sqrt(dx * dx + dy * dy)
        if moved < MINI_MOVE and (moved == 0 or GetTime() - (here.t or 0) < MINI_EVERY) then return end
    end
    here.x, here.y, here.t = x, y, GetTime()
    MiniLook()
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
ns.RouteTargetPins = function() return target.world, target.mini end

-- The world map tooltip choice (see WorldMouse): Shift pressed or let go
-- while it is "shift" - the shown world map pins take the mouse or let it
-- through; the tooltip of a pin that let it go goes too
local modWatch = CreateFrame("Frame")
modWatch:SetScript("OnEvent", function(_, _, key)
    if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
    local on = WorldMouse()
    for pin in pairs(worldShown) do pin:EnableMouse(on) end
    local owner = not on and GameTooltip:GetOwner()
    if owner and worldShown[owner] then GameTooltip:Hide() end
end)
-- the choice changed (Options) or the saved data is there (login): every
-- world map pin as the choice says; the event only while it is "shift"
local function ApplyWorldTip()
    if WorldTipShift() then
        modWatch:RegisterEvent("MODIFIER_STATE_CHANGED")
    else
        modWatch:UnregisterEvent("MODIFIER_STATE_CHANGED")
    end
    local on = WorldMouse()
    for _, pins in pairs(pinsByNode) do
        if pins.world then pins.world:EnableMouse(on) end
    end
    if target.world then target.world:EnableMouse(on) end
end
ns.WorldPinTipChanged = ApplyWorldTip

-- Where the minimap pins are (world yards) and how big (pixels): the route
-- line leaves a little gap around each one (Route.lua)
ns.MinimapPinSpots = function()
    local spots = {}
    if not (HBD and HBD.GetWorldCoordinatesFromZone) then return spots end
    local function Add(pin, mapID, x, y)
        local wx, wy = HBD:GetWorldCoordinatesFromZone(x, y, mapID)
        if wx then spots[#spots + 1] = { wx = wx, wy = wy, px = pin:GetWidth() or 12 } end
    end
    for pin in pairs(miniOn) do
        local n = pin.node
        if n and pin.mapID then Add(pin, pin.mapID, n.x, n.y) end
    end
    if target.mini and target.node and target.mapID then Add(target.mini, target.mapID, target.node.x, target.node.y) end
    return spots
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:RegisterEvent("ZONE_CHANGED_NEW_AREA")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
loader:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        ns.MigratePinSwitches()
        if ns.MigrateLineSwitch then ns.MigrateLineSwitch() end
        playerMap = ns.GetPlayerPos()
        ApplyWorldTip() -- (the tooltip choice: the Shift event only when chosen)
        C_Timer.After(1, Rebuild)
        C_Timer.NewTicker(3, UpdateAlpha) -- cooldowns run out
        C_Timer.NewTicker(MINI_TICK, MiniTick) -- minimap pins: only the ones near you
        return
    end
    -- New zone: move the minimap pins over
    C_Timer.After(0.5, function()
        local mapID = ns.GetPlayerPos()
        if mapID and mapID ~= playerMap then
            local old = playerMap
            playerMap = mapID
            MovePlayerMap(old, mapID)
        end
    end)
end)

-- /gcr pintest : why nodes of this zone have (no) pins
ns.PinTest = function()
    local mapID = ns.GetPlayerPos and ns.GetPlayerPos()
    ns.Print(("Pin check for %s (%s), world map pins: %s, minimap pins: %s (%s)"):format(tostring(mapID and ns.GetZoneName(mapID)),
        tostring(mapID), tostring(WorldPinsShown()), tostring(MiniPinsShown()), tostring(MiniStyle())))
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
