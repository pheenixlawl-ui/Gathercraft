local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Live routing and farm runs
--   The route is always planned from the player's current position through
--   all remaining nodes of this round (checked zones/kinds in /fg zones, on
--   the current continent). It is re-planned whenever something changes:
--   arriving at a node, harvesting, skipping, new nodes. Marker and route
--   line always come from the same plan.
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local HBDPins = LibStub and LibStub("HereBeDragons-Pins-2.0", true)

local ARRIVE_DIST = 10       -- yards: counts as "arrived"
local SKIP_TIME = 300        -- seconds a skipped (empty) node stays out of runs
local WAIT_RETRY = 5         -- seconds between retries while all nodes are on cooldown
local TICK = 0.5             -- seconds between arrival checks
local MAX_ROUTE_NODES = 800  -- more nodes: only the nearest ones are planned
local OPT_BUDGET_MS = 150    -- max time spent improving a plan
local QUICK_BUDGET_MS = 40   -- same for automatic re-plans while moving
local REPLAN_MOVE = 50       -- yards moved since the last plan before re-planning
local QUICK_MAX_NODES = 150  -- automatic re-plans only look at the nearest nodes
local REPLAN_INTERVAL = 4    -- seconds between automatic re-plans while moving
local DOT_SPACING = 25       -- yards between route line dots
local MAX_DOTS = 500
local LINE_REF = ADDON_NAME .. "Route"
local LINE_COLOR = { 1, 0.82, 0.2, 0.9 }

local ticker
local preview -- plan shown with /fg route (no run)
local Plan    -- forward declaration

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
local function MatchesFilter(n, filter)
    return not filter or n.type == filter or n.name:lower():find(filter, 1, true)
end

-- All checked nodes on the given continent
local function CollectPoints(filter, instance)
    local points = {}
    for mapID, nodes in pairs(ns.db.nodes) do
        if not ns.db.disabledZones[mapID] then
            for _, n in ipairs(nodes) do
                if ns.IsNodeEnabled(n, mapID) and MatchesFilter(n, filter) then
                    local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(n.x, n.y, mapID)
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

-- Plans the best path from (px, py) through the given points
local function PlanPath(points, px, py, budget, maxNodes)
    maxNodes = maxNodes or MAX_ROUTE_NODES
    if #points > maxNodes then
        -- Too many nodes: only plan through the nearest ones
        for _, p in ipairs(points) do
            p.d = WDist(px, py, p.wx, p.wy)
        end
        table.sort(points, function(a, b) return a.d < b.d end)
        for i = #points, maxNodes + 1, -1 do
            points[i] = nil
        end
    end
    local path = NearestNeighbor(points, px, py)
    table.insert(path, 1, { wx = px, wy = py }) -- fixed start: the player
    TwoOptOpen(path, budget)
    table.remove(path, 1)

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

local function GetDot(size)
    local dot = table.remove(freeDots)
    if not dot then
        dot = CreateFrame("Frame", nil, UIParent)
        dot:EnableMouse(false)
        dot.tex = dot:CreateTexture(nil, "ARTWORK")
        dot.tex:SetAllPoints()
        dot.tex:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        dot.tex:SetVertexColor(unpack(LINE_COLOR))
    end
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
    local spacing = math.max(DOT_SPACING, (length or 0) / MAX_DOTS)
    local showFlag = HBD_PINS_WORLDMAP_SHOW_PARENT or 1
    local cx, cy = px, py
    for _, p in ipairs(path) do
        local steps = math.floor(WDist(cx, cy, p.wx, p.wy) / spacing)
        for s = 1, steps do
            local t = s / (steps + 1)
            local x = cx + (p.wx - cx) * t
            local y = cy + (p.wy - cy) * t
            HBDPins:AddWorldMapIconWorld(LINE_REF, GetDot(5), instance, x, y, showFlag)
            HBDPins:AddMinimapIconWorld(LINE_REF, GetDot(4), instance, x, y, false)
        end
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
            ns.Print("Run stopped.")
        end
    end
end

local function Available(p, run)
    return not ns.IsOnCooldown(p.node) and not run.visited[p.node]
end

-- (Re-)plans the run from the player's current position
Plan = function(quick)
    local run = ns.run
    if not run then return end
    run.lastTry = time()
    run.planPending = nil

    local px, py, instance = PlayerWorld()
    if not px then return end -- no position right now, retry later

    local points = CollectPoints(run.filter, instance)
    run.total = #points
    if #points == 0 then
        ns.Print("No matching nodes on this continent (check /fg zones).")
        StopRun()
        return
    end

    local open = {}
    for _, p in ipairs(points) do
        if Available(p, run) then open[#open + 1] = p end
    end

    -- Round finished: start a new one with every node that is not on cooldown
    if #open == 0 and next(run.visited) then
        for _, p in ipairs(points) do
            if not ns.IsOnCooldown(p.node) then
                wipe(run.visited)
                ns.Print(("Round %d complete, starting round %d."):format(run.round, run.round + 1))
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
            ns.Print("All nodes on the route are on cooldown. Waiting for respawns...")
            C_Map.ClearUserWaypoint()
        end
        run.waiting = true
        return
    end
    run.waiting = nil

    local path, length
    if quick then
        path, length = PlanPath(open, px, py, QUICK_BUDGET_MS, QUICK_MAX_NODES)
    else
        path, length = PlanPath(open, px, py)
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
local function RequestPlan()
    local run = ns.run
    if run and not run.planPending then
        run.planPending = true
        C_Timer.After(0.3, Plan)
    end
end

local function CheckArrival()
    local run = ns.run
    if not run then return end

    if not run.target then
        if time() - (run.lastTry or 0) >= WAIT_RETRY then
            Plan()
        end
        return
    end

    local px, py, instance = PlayerWorld()
    if not px or instance ~= run.instance or not run.path then return end

    -- Every node of the plan you walk past counts as visited, not only the target
    local reached = false
    for _, p in ipairs(run.path) do
        if not run.visited[p.node] and WDist(px, py, p.wx, p.wy) <= ARRIVE_DIST then
            run.visited[p.node] = true
            run.done = run.done + 1
            reached = true
        end
    end
    if reached then
        if SOUNDKIT and SOUNDKIT.MAP_PING then
            PlaySound(SOUNDKIT.MAP_PING)
        end
        Plan()
        return
    end

    -- Walked away from where the last plan started: plan again from here
    if run.planX and time() - (run.lastTry or 0) >= REPLAN_INTERVAL
        and WDist(px, py, run.planX, run.planY) > REPLAN_MOVE then
        Plan(true)
    end
end

local function StartRun(filter)
    if not HBD then
        ns.Print("HereBeDragons missing, routes are not available.")
        return
    end
    StopRun(true)
    filter = (filter and filter ~= "") and filter:lower() or nil

    ns.run = {
        filter = filter,
        visited = {},
        round = 1,
        done = 0,
    }
    ns.db.activeRun = { filter = filter }
    Plan()
    local run = ns.run
    if not run then return end -- nothing to farm
    if run.path then
        ns.Print(("Run started: %d nodes in %d zone(s), path %d yd."):format(
            #run.path, run.zones, run.length))
    end
    ticker = C_Timer.NewTicker(TICK, CheckArrival)
end

local function SkipNode()
    local run = ns.run
    if not run or not run.target then
        ns.Print("No run target right now. Start one with /fg run.")
        return
    end
    local node = run.target
    node.emptyUntil = time() + SKIP_TIME
    run.visited[node] = true
    ns.Print(("%s marked empty for %d min."):format(node.name, SKIP_TIME / 60))
    Plan()
end

-- Called by the recorder after a node was harvested (it is on cooldown now)
local function OnHarvested(node)
    local run = ns.run
    if run then
        run.visited[node] = true
        RequestPlan()
    end
end

---------------------------------------------------------------------------
-- Preview and line toggle
---------------------------------------------------------------------------
local function PreviewRoute(filter)
    if not HBD then
        ns.Print("HereBeDragons missing, routes are not available.")
        return
    end
    if ns.run then
        if ns.run.path then
            ns.Print(("Current run: %d nodes left, path %d yd."):format(#ns.run.path, ns.run.length))
        end
        return
    end
    if preview and (filter == nil or filter == "") then
        preview = nil
        ClearLine()
        ns.Print("Route preview hidden.")
        return
    end

    filter = (filter and filter ~= "") and filter:lower() or nil
    local px, py, instance = PlayerWorld()
    if not px then
        ns.Print("No position available here.")
        return
    end
    local open = {}
    for _, p in ipairs(CollectPoints(filter, instance)) do
        if not ns.IsOnCooldown(p.node) then open[#open + 1] = p end
    end
    if #open == 0 then
        ns.Print("No available nodes on this continent (check /fg zones).")
        return
    end
    local path, length = PlanPath(open, px, py)
    preview = { path = path, length = length, instance = instance, px = px, py = py }
    DrawLine(path, length, instance, px, py)
    ns.Print(("Route preview: %d nodes in %d zone(s), path %d yd. /fg route again to hide."):format(
        #path, CountZones(path), length))
end

local function ToggleRouteLine()
    ns.db.routeLineHidden = not ns.db.routeLineHidden
    ns.Print("Route line " .. (ns.db.routeLineHidden and "|cffff0000hidden|r" or "|cff00ff00shown|r"))
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
ns.StartRun = StartRun
ns.StopRun = StopRun
ns.SkipNode = SkipNode
ns.PreviewRoute = PreviewRoute
ns.ToggleRouteLine = ToggleRouteLine
ns.OnHarvested = OnHarvested
ns.DistanceToTarget = DistanceToTarget
table.insert(ns.nodeListeners, RequestPlan)
