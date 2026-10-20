local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Live routing and farm runs
--   The route is always planned from the player's current position through
--   all remaining nodes of this round (checked zones/kinds in /gcr zones, on
--   the current continent). It is re-planned whenever something changes:
--   arriving at a node, harvesting, skipping, new nodes. Marker and route
--   line always come from the same plan.
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)

local ARRIVE_DEFAULT = 25    -- yards: close enough to see whether the node is there
local ARRIVE_MIN, ARRIVE_MAX = 10, 40
local SKIP_TIME = 300        -- seconds a skipped (empty) node stays out of runs
local EMPTY_GRACE = 25       -- seconds after arriving: no harvest by then = the node wasn't there
local EMPTY_NEAR = 30        -- yards: a harvest this close counts for the node we arrived at
local WAIT_RETRY = 5         -- seconds between retries while all nodes are on cooldown
local TICK = 0.5             -- seconds between arrival checks
local MAX_ROUTE_NODES = 800  -- more nodes: only the nearest ones are planned
local OPT_BUDGET_MS = 150    -- max time spent improving a plan
local QUICK_BUDGET_MS = 10   -- same for automatic re-plans while moving (keeps the game smooth)
local REPLAN_MOVE = 50       -- yards moved since the last plan before re-planning
local QUICK_MAX_NODES = 100  -- automatic re-plans only look at the nearest nodes
local REPLAN_INTERVAL = 10   -- seconds between automatic re-plans while moving
local MAX_DOTS = 600          -- per map; long routes get wider spacing
local NEAR_YARDS = 500       -- the first part of the line (around you) can be drawn denser
local LINE_REF = ADDON_NAME .. "Route"

-- Route line look (Options): colors and styles
local LINE_COLORS = {
    { code = "gold", name = "Golden", rgb = { 1, 0.82, 0.2 } },
    { code = "white", name = "White", rgb = { 1, 1, 1 } },
    { code = "green", name = "Green", rgb = { 0.35, 1, 0.35 } },
    { code = "cyan", name = "Cyan", rgb = { 0.25, 0.9, 1 } },
    { code = "purple", name = "Purple", rgb = { 0.8, 0.45, 1 } },
    { code = "red", name = "Red", rgb = { 1, 0.3, 0.3 } },
    { code = "orange", name = "Orange", rgb = { 1, 0.55, 0.1 } },
}
-- map/minimap dot size in pixels, yards between dots (near you / further away)
local LINE_STYLES = {
    { code = "dots", name = "Dots", map = 5, mini = 4, near = 25, far = 25 },
    { code = "fine", name = "Fine dots", map = 3, mini = 3, near = 10, far = 15 },
    { code = "line", name = "Line", map = 4, mini = 3, near = 4, far = 12 },
    { code = "big", name = "Big dots", map = 8, mini = 6, near = 40, far = 40 },
}
local function Pick(list, code)
    for _, e in ipairs(list) do
        if e.code == code then return e end
    end
    return list[1]
end
local function LineColor() return Pick(LINE_COLORS, ns.db.routeLineColor) end
local function LineStyle() return Pick(LINE_STYLES, ns.db.routeLineStyle) end
ns.ROUTE_LINE_COLORS, ns.ROUTE_LINE_STYLES = LINE_COLORS, LINE_STYLES
ns.RouteLineColor, ns.RouteLineStyle = LineColor, LineStyle

-- Spawn point learning: every spawn point gets a chance of having a node.
--   * learned per point: how often it had something when you came by
--     (hits / misses, starts at about 1 in 3)
--   * a point found empty a moment ago has almost no chance; it comes back
--     slowly (nodes respawn somewhere of their kind, maybe here)
-- The route leaves out points whose chance is too small for the detour.
local TUNE = {
    emptyRest = 120,   -- seconds an empty point stays out for sure (no ping-pong)
    refill = 600,      -- seconds: time scale for an empty point's chance to come back
    priorHits = 1,     -- a new point counts as 1 hit in 3 visits
    priorVisits = 3,
    minChance = 0.08,  -- points below this chance are left out
    prune = 1.6,       -- leave out a point when its detour per expected node is this many times the route's
    learn = true,
    freeAfterDetour = true,
}
ns.RouteTune = TUNE

local ticker
local preview -- plan shown with /gcr route (no run)
local Plan    -- forward declaration
local MarkEmpty

---------------------------------------------------------------------------
-- World coordinates (yards, work across zone borders)
---------------------------------------------------------------------------
local function PlayerWorld()
    return HBD:GetPlayerWorldPosition()
end

local function WDist(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return math.sqrt(dx * dx + dy * dy)
end

local function PDist(a, b)
    return WDist(a.wx, a.wy, b.wx, b.wy)
end

---------------------------------------------------------------------------
-- Planning
---------------------------------------------------------------------------
local TYPE_FILTERS = { herb = true, ore = true }
local function MatchesFilter(n, filter)
    -- chests are map icons only, never part of a route
    if n.type == "chest" then return false end
    if not filter then return true end
    if filter == "both" then return n.type == "herb" or n.type == "ore" end
    if TYPE_FILTERS[filter] then return n.type == filter end -- no string work per node
    return n.type == filter or n.name:lower():find(filter, 1, true)
end

-- World coordinates per node, cached (weak keys: deleted nodes drop out)
local worldCache = setmetatable({}, { __mode = "k" })
local function WorldPos(n, mapID)
    local c = worldCache[n]
    if c and c.x == n.x and c.y == n.y and c.mapID == mapID then
        return c.wx, c.wy, c.inst
    end
    local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(n.x, n.y, mapID)
    worldCache[n] = { x = n.x, y = n.y, mapID = mapID, wx = wx, wy = wy, inst = inst }
    return wx, wy, inst
end

-- All checked nodes on the given continent (or in one zone only)
local function CollectPoints(filter, instance, zone)
    local points = {}
    for mapID, nodes in pairs(ns.db.nodes) do
        if (not zone or mapID == zone) and (zone or not ns.db.disabledZones[mapID]) then
            for _, n in ipairs(nodes) do
                if MatchesFilter(n, filter) and ns.IsNodeEnabled(n, mapID) then
                    local wx, wy, inst = WorldPos(n, mapID)
                    if wx and inst == instance then
                        points[#points + 1] = { node = n, mapID = mapID, wx = wx, wy = wy }
                    end
                end
            end
        end
    end
    return points
end

local function NearestNeighbor(points, sx, sy)
    local remaining = {}
    for i, p in ipairs(points) do remaining[i] = p end
    local path = {}
    local cx, cy = sx, sy
    while #remaining > 0 do
        local bestI, bestD = 1, math.huge
        for i, p in ipairs(remaining) do
            local d = WDist(cx, cy, p.wx, p.wy)
            if d < bestD then bestI, bestD = i, d end
        end
        local p = remaining[bestI]
        remaining[bestI] = remaining[#remaining]
        remaining[#remaining] = nil
        path[#path + 1] = p
        cx, cy = p.wx, p.wy
    end
    return path
end

-- 2-opt for an open path whose first point (the player) stays fixed
local function TwoOptOpen(t, budget)
    local n = #t
    if n < 4 then return end
    local startTime = debugprofilestop()
    local improved = true
    while improved do
        improved = false
        for i = 1, n - 2 do
            local a, b = t[i], t[i + 1]
            for j = i + 2, n do
                local c, e = t[j], t[j + 1]
                local delta = PDist(a, c) - PDist(a, b)
                if e then
                    delta = delta + PDist(b, e) - PDist(c, e)
                end
                if delta < -0.01 then
                    local l, r = i + 1, j
                    while l < r do
                        t[l], t[r] = t[r], t[l]
                        l, r = l + 1, r - 1
                    end
                    b = t[i + 1]
                    improved = true
                end
            end
            if debugprofilestop() - startTime > (budget or OPT_BUDGET_MS) then return end
        end
    end
end

---------------------------------------------------------------------------
-- What a node is worth to this run (route goal, Options)
--   skill : nodes that still give skill-ups (orange > yellow > green > grey)
--   gold  : what the material sells for (own scan, else Auctionator/TSM)
--   nodes : every node the same
--   auto  : skill-ups while any node here still levels you, then gold
-- Nodes you can't gather yet (skill too low, profession not learned) are
-- never part of a route.
---------------------------------------------------------------------------
local GOALS = { auto = true, skill = true, gold = true, nodes = true }
local GOAL_NAMES = { skill = "Skill-ups", gold = "Gold", nodes = "Nodes" }

local function Goal()
    local g = ns.db.routeGoal
    return GOALS[g] and g or "auto"
end

local function SkillChance(mine, req)
    if not req then return 0.5 end
    local d = mine - req
    if d < 0 then return nil end -- can't gather
    if d < 25 then return 1 end
    if d < 50 then return 0.75 end
    if d < 100 then return 0.25 end
    return 0
end

-- Weights per kind for the given points: weights[kindKey] = 0 (skip) or > 0
local function KindWeights(points)
    local skills, maxed = {}, {}
    for _, t in ipairs({ "herb", "ore" }) do
        local rank, maxRank
        if ns.GetSkill then rank, maxRank = ns.GetSkill(t) end
        skills[t] = rank
        -- at the cap (until you train): nodes still pay, but give no skill-ups
        maxed[t] = rank and maxRank and maxRank > 0 and rank >= maxRank
    end
    -- no profession found at all: the client hides it, don't filter
    local filterProfs = skills.herb or skills.ore
    local kinds, list = {}, {}
    for _, p in ipairs(points) do
        local n = p.node
        local key = n.id or n.name
        p.kind = key
        if not kinds[key] then
            local k = { node = n }
            local mine = skills[n.type]
            if not mine then
                k.skill = not filterProfs and 0.5 or nil
            else
                -- 0 = requirement unknown (new Forever nodes): don't treat them as grey
                local req = ns.RequiredSkill and ns.RequiredSkill(n.id, n.name)
                if req == 0 then req = nil end
                k.skill = SkillChance(mine, req)
                if k.skill and maxed[n.type] then k.skill = 0 end
            end
            if k.skill and n.item and ns.GetPrice then k.price = ns.GetPrice(n.item) end
            kinds[key] = k
            list[#list + 1] = k
        end
    end
    local goal = Goal()
    if goal == "auto" then
        goal = "gold"
        for _, k in ipairs(list) do
            if k.skill and k.skill >= 0.25 then goal = "skill" break end
        end
    end
    local prices = {}
    for _, k in ipairs(list) do
        if k.skill and k.price and k.price > 0 then prices[#prices + 1] = k.price end
    end
    table.sort(prices)
    local median = prices[math.ceil(#prices / 2)]
    local weights = {}
    for key, k in pairs(kinds) do
        local w
        if not k.skill then
            w = 0
        elseif goal == "skill" then
            w = math.max(k.skill, 0.1) -- grey: only when it is right on the way
        elseif goal == "gold" then
            w = (k.price and median) and math.max(0.2, math.min(5, k.price / median)) or 1
        else
            w = 1
        end
        weights[key] = w
    end
    return weights, goal
end

-- Chance (0..1) that a spawn point has a node right now
local LEARN_WINDOW = 20 -- only the latest ~20 visits count: spawn points can change
local function Chance(n, now)
    local hits, misses = n.hits or 0, n.misses or 0
    if not TUNE.learn then hits, misses = 0, 0 end
    if hits + misses > LEARN_WINDOW then
        local f = LEARN_WINDOW / (hits + misses)
        hits, misses = hits * f, misses * f
    end
    local c = (hits + TUNE.priorHits) / (hits + misses + TUNE.priorVisits)
    if n.emptyAt then
        c = c * (1 - math.exp(-math.max(0, now - n.emptyAt) / TUNE.refill))
    end
    return c
end
ns.NodeChance = function(n) return Chance(n, time()) end

-- Can the route go there now? (minChance false: also unlikely points)
local function Available(p, run, now, minChance)
    if ns.IsOnCooldown(p.node) or run.visited[p.node] or run.checkingSet[p.node] then return false end
    local w = run.weights and run.weights[p.kind] or 1
    if w <= 0 then return false end
    local c = Chance(p.node, now)
    p.chance = c * w -- expected value of going there
    return not minChance or c >= TUNE.minChance
end

-- Leave out points that cost more riding per expected node than the route
-- as a whole. A pass removes at most a quarter of the points, so one bad
-- estimate never empties the route.
local function Prune(path, sx, sy)
    if TUNE.prune <= 0 or #path < 4 then return path end
    for _ = 1, 3 do
        local length, expected, cx, cy = 0, 0, sx, sy
        for _, p in ipairs(path) do
            length = length + WDist(cx, cy, p.wx, p.wy)
            expected = expected + (p.chance or 1)
            cx, cy = p.wx, p.wy
        end
        if expected <= 0 then return path end
        local limit = TUNE.prune * length / expected
        local keep, removed, maxRemove = {}, 0, math.floor(#path / 4)
        local px, py = sx, sy
        for i, p in ipairs(path) do
            local nx = path[i + 1]
            local detour = WDist(px, py, p.wx, p.wy)
            if nx then detour = detour + PDist(p, nx) - WDist(px, py, nx.wx, nx.wy) end
            if removed < maxRemove and i > 1 and detour / math.max(p.chance or 1, 0.01) > limit then
                removed = removed + 1 -- skip it: the next point is reached from px, py
            else
                keep[#keep + 1] = p
                px, py = p.wx, p.wy
            end
        end
        if removed == 0 then return keep end
        path = keep
    end
    return path
end

-- Plans the best path from (px, py) through the given points
local function PlanPath(points, px, py, budget, maxNodes)
    maxNodes = maxNodes or MAX_ROUTE_NODES
    if #points > maxNodes then
        -- Too many nodes: only plan through the nearest ones. Grow a circle
        -- until it holds enough of them, so we never sort thousands of nodes.
        for _, p in ipairs(points) do
            p.d = WDist(px, py, p.wx, p.wy)
        end
        local radius, near = 400, nil
        repeat
            near = {}
            for _, p in ipairs(points) do
                if p.d <= radius then near[#near + 1] = p end
            end
            radius = radius * 2
        until #near >= maxNodes or radius > 100000
        if #near == 0 then
            -- everything is very far away (another zone of a huge continent): take them all
            for _, p in ipairs(points) do near[#near + 1] = p end
        end
        table.sort(near, function(a, b) return a.d < b.d end)
        for i = #near, maxNodes + 1, -1 do
            near[i] = nil
        end
        points = near
    end
    local path = NearestNeighbor(points, px, py)
    table.insert(path, 1, { wx = px, wy = py }) -- fixed start: the player
    TwoOptOpen(path, budget)
    table.remove(path, 1)
    path = Prune(path, px, py)

    local length, cx, cy = 0, px, py
    for _, p in ipairs(path) do
        length = length + WDist(cx, cy, p.wx, p.wy)
        cx, cy = p.wx, p.wy
    end
    return path, length
end

local function CountZones(points)
    local zones, count = {}, 0
    for _, p in ipairs(points) do
        if not zones[p.mapID] then
            zones[p.mapID] = true
            count = count + 1
        end
    end
    return count
end

---------------------------------------------------------------------------
-- Route line (dots on world map and minimap)
---------------------------------------------------------------------------
local freeDots, usedDots = {}, {}

local function GetDot(size, rgb)
    local dot = table.remove(freeDots)
    if not dot then
        dot = CreateFrame("Frame", nil, UIParent)
        dot:EnableMouse(false)
        dot.tex = dot:CreateTexture(nil, "ARTWORK")
        dot.tex:SetAllPoints()
        dot.tex:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    end
    dot.tex:SetVertexColor(rgb[1], rgb[2], rgb[3], 0.9)
    dot:SetSize(size, size)
    usedDots[#usedDots + 1] = dot
    return dot
end

local function ClearLine()
    if not HBDPins then return end
    HBDPins:RemoveAllWorldMapIcons(LINE_REF)
    HBDPins:RemoveAllMinimapIcons(LINE_REF)
    for _, dot in ipairs(usedDots) do
        dot:Hide()
        freeDots[#freeDots + 1] = dot
    end
    wipe(usedDots)
end

-- Draws the path: player position -> first node -> ... -> last node
local function DrawLine(path, length, instance, px, py)
    ClearLine()
    if not path or #path == 0 or ns.db.routeLineHidden then return end
    local style, rgb = LineStyle(), LineColor().rgb
    -- dense around you, wider further away; never more than MAX_DOTS
    local nearLen = math.min(length or 0, NEAR_YARDS)
    local nearDots = math.min(nearLen / style.near, MAX_DOTS / 2)
    local nearSpacing = nearLen > 0 and nearLen / math.max(nearDots, 1) or style.near
    local farSpacing = math.max(style.far, ((length or 0) - nearLen) / math.max(MAX_DOTS - nearDots, 1))
    local showFlag = HBD_PINS_WORLDMAP_SHOW_PARENT or 1
    local cx, cy, along, nextAt = px, py, 0, nearSpacing
    for _, p in ipairs(path) do
        local seg = WDist(cx, cy, p.wx, p.wy)
        -- dots at fixed distances along the whole path (not per segment)
        while nextAt < along + seg do
            local d = nextAt - along
            -- keep the node pins themselves clear
            if d > 6 and seg - d > 6 then
                local t = d / seg
                local x = cx + (p.wx - cx) * t
                local y = cy + (p.wy - cy) * t
                HBDPins:AddWorldMapIconWorld(LINE_REF, GetDot(style.map, rgb), instance, x, y, showFlag)
                HBDPins:AddMinimapIconWorld(LINE_REF, GetDot(style.mini, rgb), instance, x, y, false)
            end
            nextAt = nextAt + (nextAt < nearLen and nearSpacing or farSpacing)
        end
        along = along + seg
        cx, cy = p.wx, p.wy
    end
end

---------------------------------------------------------------------------
-- Farm run
---------------------------------------------------------------------------
local function StopRun(silent)
    ns.db.activeRun = nil
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    ClearLine()
    preview = nil
    if ns.run then
        ns.run = nil
        C_Map.ClearUserWaypoint()
        if not silent then
            ns.Print(L["Run stopped."])
        end
    end
end

-- (Re-)plans the run from the player's current position
Plan = function(quick)
    local run = ns.run
    if not run then return end
    run.lastTry = time()
    run.planPending = nil

    local px, py, instance = PlayerWorld()
    if not px then return end -- no position right now, retry later

    -- The node list only changes when the database changes: reuse it
    -- (rebuilding thousands of entries on every plan makes the game hitch)
    if not run.points or run.pointsDirty or run.pointsInstance ~= instance then
        run.points = CollectPoints(run.filter, instance, run.zone)
        run.pointsDirty, run.pointsInstance = false, instance
        run.pointsChanged = true
    end
    local points = run.points
    run.total = #points
    if #points == 0 then
        ns.Print(run.zone and (L["No matching nodes in "] .. ns.GetZoneName(run.zone) .. ".")
            or L["No matching nodes on this continent (check /gcr zones)."])
        StopRun()
        return
    end
    -- weights change with your skill and prices: refresh now and then
    if not run.weights or run.pointsChanged or time() - (run.weightsAt or 0) > 30 then
        run.weights, run.goal = KindWeights(points)
        run.weightsAt, run.pointsChanged = time(), nil
        local any = false
        for _, w in pairs(run.weights) do
            if w > 0 then any = true break end
        end
        if not any then
            ns.Print(L["You can't gather any of these nodes yet (skill too low or profession not learned)."])
            StopRun()
            return
        end
    end

    -- nodes reached a moment ago are still being checked: not open, not new
    run.checkingSet = run.checkingSet or {}
    wipe(run.checkingSet)
    for _, c in ipairs(run.checking) do run.checkingSet[c.node] = true end

    local open, now = {}, time()
    for _, p in ipairs(points) do
        if Available(p, run, now, true) then open[#open + 1] = p end
    end
    -- only unlikely points left: better those than standing still
    if #open == 0 then
        for _, p in ipairs(points) do
            if Available(p, run, now, false) then open[#open + 1] = p end
        end
    end

    -- Round finished: start a new one, if a node can follow after it
    if #open == 0 and next(run.visited) then
        for _, p in ipairs(points) do
            if not ns.IsOnCooldown(p.node) and not run.checkingSet[p.node] and (run.weights[p.kind] or 1) > 0 then
                wipe(run.visited)
                local msg = (L["Round %d complete, starting round %d."]):format(run.round, run.round + 1)
                -- tiny runs (one zone, one herb) finish rounds quickly: say it only now and then
                if time() - (run.roundSaidAt or 0) >= 120 then
                    ns.Print(msg)
                    run.roundSaidAt = time()
                else
                    ns.Debug(msg)
                end
                run.round = run.round + 1
                return Plan(quick)
            end
        end
    end

    -- Everything on cooldown: wait (CheckArrival retries)
    if #open == 0 then
        run.target, run.targetPoint, run.path = nil, nil, nil
        ClearLine()
        if not run.waiting then
            ns.Print(L["All nodes on the route are on cooldown. Waiting for respawns..."])
            C_Map.ClearUserWaypoint()
        end
        run.waiting = true
        return
    end
    run.waiting = nil

    -- Keep the node we are heading to: re-plans only reorder what comes after
    -- it. Otherwise a slightly shorter total route can make the arrow jump to
    -- a node behind you while you walk. A new target is picked only when you
    -- reach, harvest or skip the current one.
    local keep
    if run.target then
        for i, p in ipairs(open) do
            if p.node == run.target then
                keep = table.remove(open, i)
                break
            end
        end
    end
    local sx, sy = px, py
    if keep then sx, sy = keep.wx, keep.wy end
    local path, length
    if #open == 0 then
        path, length = {}, 0
    elseif quick then
        path, length = PlanPath(open, sx, sy, QUICK_BUDGET_MS, QUICK_MAX_NODES)
    else
        path, length = PlanPath(open, sx, sy)
    end
    if keep then
        table.insert(path, 1, keep)
        length = length + WDist(px, py, keep.wx, keep.wy)
    elseif #path > 1 then
        -- New target: never send you far away while a node is much closer
        local nearest, nd = nil, math.huge
        for _, p in ipairs(path) do
            local d = WDist(px, py, p.wx, p.wy)
            if d < nd then nearest, nd = p, d end
        end
        local fd = WDist(px, py, path[1].wx, path[1].wy)
        if nearest ~= path[1] and fd > nd * 2.5 and fd - nd > 150 then
            for i, p in ipairs(open) do
                if p == nearest then table.remove(open, i) break end
            end
            path, length = PlanPath(open, nearest.wx, nearest.wy, quick and QUICK_BUDGET_MS or nil, quick and QUICK_MAX_NODES or nil)
            table.insert(path, 1, nearest)
            length = length + nd
        end
    end
    if #path == 0 then
        -- nothing to ride to right now: wait (CheckArrival retries)
        run.target, run.targetPoint, run.path = nil, nil, nil
        ClearLine()
        return
    end
    run.path, run.length, run.instance = path, length, instance
    run.planX, run.planY = px, py
    run.zones = CountZones(path)

    local first = path[1]
    if run.target ~= first.node then
        run.target, run.targetPoint = first.node, first
        ns.SetWaypoint(first.mapID, first.node.x, first.node.y)
    else
        run.targetPoint = first
    end
    run.mapID = first.mapID
    DrawLine(path, length, instance, px, py)
end

-- Re-plan a moment later (several changes in a row only cause one plan)
local function RequestPlan(kind)
    local run = ns.run
    -- the node list changes when nodes are added or removed, not when one is
    -- harvested or nudged a little ("update", "harvest")
    if run and kind ~= "update" and kind ~= "harvest" then run.pointsDirty = true end
    if run and not run.planPending then
        run.planPending = true
        C_Timer.After(0.3, function() Plan(true) end) -- quick: no hitch while you loot
    end
end

-- Found empty: out for a short while, then its chance comes back slowly.
-- The point also learns that it was empty (see Chance).
MarkEmpty = function(n, why)
    if ns.IsOnCooldown(n) then return end
    n.emptyStreak = (n.emptyStreak or 0) + 1
    n.misses = (n.misses or 0) + 1
    if (n.hits or 0) + n.misses > LEARN_WINDOW then
        n.hits, n.misses = (n.hits or 0) * 0.9, n.misses * 0.9
    end
    n.emptyAt = time()
    n.emptyUntil = time() + TUNE.emptyRest
    ns.Debug(("%s was empty (%s, %dx in a row, chance in 10 min %d%%)"):format(n.name, why, n.emptyStreak,
        Chance(n, time() + 600) * 100))
end

local function CheckArrival()
    local run = ns.run
    if not run then return end

    if not run.target then
        if time() - (run.lastTry or 0) >= WAIT_RETRY then
            Plan(true)
        end
        return
    end

    -- Time spent farming per zone (for "Best place to farm")
    if ns.CountFarmTime then
        ns.CountFarmTime(ns.GetPlayerPos(), run.filter, TICK)
    end

    local px, py, instance = PlayerWorld()
    if not px or instance ~= run.instance or not run.path then return end

    -- Nodes we reached a moment ago: no harvest close by = nothing was there.
    -- Mark them empty so later rounds don't send you back right away.
    for i = #run.checking, 1, -1 do
        local c = run.checking[i]
        if time() - c.at >= EMPTY_GRACE then
            table.remove(run.checking, i)
            local found = false
            for _, h in ipairs(run.harvests) do
                if h.t >= c.at - 2 and WDist(h.wx, h.wy, c.wx, c.wy) <= EMPTY_NEAR then
                    found = true
                    break
                end
            end
            if not found then MarkEmpty(c.node, L["nothing harvested"]) end
        end
    end

    -- Every node of the plan you get close to counts as checked, not only the
    -- target. "Close" = where you can see whether it is there (Options).
    local arrive = ns.ArriveDistance()
    local reached = false
    for _, p in ipairs(run.path) do
        if not run.visited[p.node] and WDist(px, py, p.wx, p.wy) <= arrive then
            run.visited[p.node] = true
            run.done = run.done + 1
            run.checking[#run.checking + 1] = { node = p.node, wx = p.wx, wy = p.wy, at = time() }
            reached = true
        end
    end
    if reached then
        if SOUNDKIT and SOUNDKIT.MAP_PING then
            PlaySound(SOUNDKIT.MAP_PING)
        end
        Plan(true)
        return
    end

    -- Walked away from where the last plan started: plan again from here
    if run.planX and time() - (run.lastTry or 0) >= REPLAN_INTERVAL
        and WDist(px, py, run.planX, run.planY) > REPLAN_MOVE then
        Plan(true)
    end
end

local function StartRun(filter, zone)
    if not HBD then
        ns.Print(L["HereBeDragons missing, routes are not available."])
        return
    end
    StopRun(true)
    filter = (filter and filter ~= "") and filter:lower() or nil

    ns.run = {
        filter = filter,
        zone = zone,       -- only this zone (from "Best place to farm")
        visited = {},
        checking = {}, -- nodes reached, waiting to see if they get harvested
        harvests = {}, -- where we harvested during this run (recent ones)
        round = 1,
        done = 0,
    }
    ns.db.activeRun = { filter = filter, zone = zone }
    Plan()
    local run = ns.run
    if not run then return end -- nothing to farm
    if run.path then
        ns.Print((L["Run started: %d nodes in %d zone(s), path %d yd."]):format(
            #run.path, run.zones, run.length) .. " " .. (L["Route goal: %s."]):format(L[GOAL_NAMES[run.goal] or "Nodes"]))
    end
    ticker = C_Timer.NewTicker(TICK, CheckArrival)
end

local function SkipNode()
    local run = ns.run
    if not run or not run.target then
        ns.Print(L["No run target right now. Start one with /gcr run."])
        return
    end
    local node = run.target
    MarkEmpty(node, "skipped")
    node.emptyUntil = math.max(node.emptyUntil or 0, time() + SKIP_TIME)
    run.visited[node] = true
    ns.Print((L["%s marked empty for %d min."]):format(node.name, SKIP_TIME / 60))
    Plan(true)
end

-- Called by the recorder after a node was harvested (it is on cooldown now)
local function OnHarvested(node, spawn)
    node.emptyStreak, node.emptyAt = nil, nil -- it had something: back to normal
    -- the same vein mined two or three times counts once
    if not spawn or node.lastHitSpawn ~= spawn then
        node.lastHitSpawn = spawn
        node.hits = (node.hits or 0) + 1
        if node.hits + (node.misses or 0) > LEARN_WINDOW then
            node.hits, node.misses = node.hits * 0.9, (node.misses or 0) * 0.9
        end
    end
    local run = ns.run
    if run then
        run.visited[node] = true
        local px, py = PlayerWorld()
        if px then
            table.insert(run.harvests, { wx = px, wy = py, t = time() })
            if #run.harvests > 20 then table.remove(run.harvests, 1) end
        end
        -- harvested something off the route (you saw it and rode there): the
        -- old target may be behind you now, so pick the next one fresh
        local tp = run.targetPoint
        if TUNE.freeAfterDetour and tp and node ~= run.target and px and run.planX
            and WDist(px, py, tp.wx, tp.wy) > WDist(run.planX, run.planY, tp.wx, tp.wy) then
            run.target = nil
        end
        RequestPlan("harvest")
    end
end

---------------------------------------------------------------------------
-- Preview and line toggle
---------------------------------------------------------------------------
local function PreviewRoute(filter)
    if not HBD then
        ns.Print(L["HereBeDragons missing, routes are not available."])
        return
    end
    if ns.run then
        if ns.run.path then
            ns.Print((L["Current run: %d nodes left, path %d yd."]):format(#ns.run.path, ns.run.length))
        end
        return
    end
    if preview and (filter == nil or filter == "") then
        preview = nil
        ClearLine()
        ns.Print(L["Route preview hidden."])
        return
    end

    filter = (filter and filter ~= "") and filter:lower() or nil
    local px, py, instance = PlayerWorld()
    if not px then
        ns.Print(L["No position available here."])
        return
    end
    local open = {}
    -- same choice as a run: only nodes you can gather
    local all = CollectPoints(filter, instance)
    local weights = KindWeights(all)
    for _, p in ipairs(all) do
        if not ns.IsOnCooldown(p.node) and (weights[p.kind] or 1) > 0 then open[#open + 1] = p end
    end
    if #open == 0 then
        ns.Print(L["No available nodes on this continent (check /gcr zones)."])
        return
    end
    local path, length = PlanPath(open, px, py)
    preview = { path = path, length = length, instance = instance, px = px, py = py }
    DrawLine(path, length, instance, px, py)
    ns.Print((L["Route preview: %d nodes in %d zone(s), path %d yd. /gcr route again to hide."]):format(
        #path, CountZones(path), length))
end

-- Options: line color or style changed, draw it again
local function RedrawLine()
    local run = ns.run
    if run then
        local px, py = PlayerWorld()
        if run.path and px then DrawLine(run.path, run.length, run.instance, px, py) end
    elseif preview then
        DrawLine(preview.path, preview.length, preview.instance, preview.px, preview.py)
    end
end
ns.RedrawRouteLine = RedrawLine

local function ToggleRouteLine()
    ns.db.routeLineHidden = not ns.db.routeLineHidden
    ns.Print(L["Route line "] .. (ns.db.routeLineHidden and L["|cffff0000hidden|r"] or L["|cff00ff00shown|r"]))
    if ns.run then
        Plan()
    elseif preview then
        DrawLine(preview.path, preview.length, preview.instance, preview.px, preview.py)
    else
        ClearLine()
    end
end

-- Distance from the player to the current target (for the panel)
local function DistanceToTarget()
    local run = ns.run
    if not run or not run.targetPoint then return end
    local px, py, instance = PlayerWorld()
    if not px or instance ~= run.instance then return end
    return WDist(px, py, run.targetPoint.wx, run.targetPoint.wy)
end

---------------------------------------------------------------------------
-- Shared
---------------------------------------------------------------------------
-- Distance at which a node counts as reached and the arrow moves on
-- Options: the route goal changed, plan again with the new weights
ns.RouteGoalChanged = function()
    if ns.run then
        ns.run.weights = nil
        Plan(true)
    end
end

ns.ArriveDistance = function()
    local d = ns.db and ns.db.arriveDist or ARRIVE_DEFAULT
    return math.max(ARRIVE_MIN, math.min(ARRIVE_MAX, d))
end
ns.ARRIVE_LIMITS = { ARRIVE_MIN, ARRIVE_MAX, ARRIVE_DEFAULT }

ns.StartRun = StartRun
ns.StopRun = StopRun
ns.SkipNode = SkipNode
ns.PreviewRoute = PreviewRoute
ns.ToggleRouteLine = ToggleRouteLine
ns.OnHarvested = OnHarvested
ns.DistanceToTarget = DistanceToTarget
table.insert(ns.nodeListeners, RequestPlan)
