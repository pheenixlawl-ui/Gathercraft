-- Gathercraft: the search range of Find Herbs / Find Minerals (0.2.3 P4)
--
-- How far the game's tracking shows nodes on the minimap - Sven measured it
-- on 11.11.2026 with the minimap zoomed out fully: Goldthorn at 143 yd,
-- Kingsblood at about 150-160 yd. 150 yd is the default (Options, General:
-- "Search range"); ore is assumed the same, not measured.
--
-- During a farm run: once the known spot the run heads for is within that
-- range, its gold pin gets a light-blue ring and the run window says "In
-- search range - no yellow dot? Press Skip." Only the distance from you to
-- that known pin counts. The game's tracking dots are never read or guessed
-- at, nothing is scanned, and nothing happens by itself: skipping stays a key
-- press. Your position is asked whether it is hidden before it is compared.
-- On request (Options: "Show the search range on the minimap", off by
-- default) a ring of dots around you on the minimap shows the range.
local _, ns = ...
local C_Timer = (C_Timer and ns.PerfTimers) and ns.PerfTimers("SearchRange") or C_Timer -- (/gcr perf on: every timer of this file)

local DEFAULT, MIN, MAX = 150, 60, 250
ns.SEARCH_LIMITS = { MIN, MAX, DEFAULT }
ns.SearchRange = function()
    local v = ns.db and tonumber(ns.db.searchRange) or DEFAULT
    return math.max(MIN, math.min(MAX, v))
end

local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)
local TRACKED = { herb = true, ore = true } -- what Find Herbs / Find Minerals shows (no chests, no fish)

-- where you are, if it can be read (hidden: never compared)
local function Where()
    if not HBD then return end
    local x, y, instance = HBD:GetPlayerWorldPosition()
    if ns.AnySecret("position", x, y, instance) or type(x) ~= "number" or type(y) ~= "number" then return end
    return x, y, instance
end

-- the ring around you
local RING_REF = "GathercraftSearch"
local RING_DOTS = 40
local ringDots, ringAt = {}, nil
local function ClearRing()
    if ringAt and HBDPins then HBDPins:RemoveAllMinimapIcons(RING_REF) end
    for _, d in ipairs(ringDots) do d:Hide() end
    ringAt = nil
end
local function Dot(i)
    local d = ringDots[i]
    if not d then
        d = CreateFrame("Frame", nil, UIParent)
        d:SetSize(4, 4)
        d:EnableMouse(false)
        d.tex = d:CreateTexture(nil, "ARTWORK")
        d.tex:SetAllPoints()
        d.tex:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        d.tex:SetVertexColor(0.35, 0.85, 1, 0.8)
        ringDots[i] = d
    end
    return d
end
local function DrawRing(x, y, instance, range)
    -- (again only when you moved 3 yd or more, or the range changed)
    if ringAt and ringAt.instance == instance and ringAt.range == range and (ringAt.x - x) ^ 2 + (ringAt.y - y) ^ 2 < 9 then return end
    if not HBDPins then return end
    HBDPins:RemoveAllMinimapIcons(RING_REF)
    for i = 1, RING_DOTS do
        local a = 2 * math.pi * i / RING_DOTS
        HBDPins:AddMinimapIconWorld(RING_REF, Dot(i), instance, x + range * math.cos(a), y + range * math.sin(a), false)
    end
    ringAt = { x = x, y = y, instance = instance, range = range }
end
ns.SearchRingDots = function() return ringAt and RING_DOTS or 0, ringAt end -- (the tests)

-- Twice a second: the run's target in range or not; the ring
local function Check()
    local run = ns.run
    if not run then
        if ringAt then ClearRing() end
        if ns.RouteTargetInRange and ns.RouteTargetInRange() then ns.SetRouteTargetInRange(false) end
        return
    end
    local range = ns.SearchRange()
    local x, y, instance = Where()
    local inRange = false
    local tp, node = run.targetPoint, run.target
    if x and tp and node and TRACKED[node.type] and instance == run.instance and type(tp.wx) == "number" and type(tp.wy) == "number" then
        inRange = (x - tp.wx) ^ 2 + (y - tp.wy) ^ 2 <= range * range
    end
    run.inSearchRange = inRange or nil
    -- (against the pin's own state: a new target's pin starts without the mark)
    if ns.RouteTargetInRange and ns.RouteTargetInRange() ~= inRange then ns.SetRouteTargetInRange(inRange) end
    if ns.db.searchRing and x then DrawRing(x, y, instance, range) elseif ringAt then ClearRing() end
end
ns.SearchRangeCheck = Check -- (the tests)
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(0.5, Check) end
