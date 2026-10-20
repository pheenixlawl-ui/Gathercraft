local ADDON_NAME, ns = ...

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

local ARRIVE_DIST = 10       -- yards: counts as "arrived"
local SKIP_TIME = 300        -- seconds a skipped (empty) node stays out of runs
local EMPTY_GRACE = 25       -- seconds after arriving: no harvest by then = the node wasn't there
local EMPTY_NEAR = 30        -- yards: a harvest this close counts for the node we arrived at
local EMPTY_MAX = 1800       -- seconds: longest rest for a spawn point that is empty again and again
local LOOK_DIST = 22         -- yards: close enough to see whether the node is there
local LOOK_TIME = 1.5        -- seconds in sight without the node = it's not there
-- While a run is on, interact targeting reaches nodes from further away. That
-- tells us early whether a node is there (and lets your interact key gather it).
-- Your own settings come back when the run stops.
local RUN_CVARS = { SoftTargetInteract = "3", SoftTargetInteractRange = "25", SoftTargetInteractArc = "2" }
local WAIT_RETRY = 5         -- seconds between retries while all nodes are on cooldown
local TICK = 0.5             -- seconds between arrival checks
local MAX_ROUTE_NODES = 800  -- more nodes: only the nearest ones are planned
local OPT_BUDGET_MS = 150    -- max time spent improving a plan
local QUICK_BUDGET_MS = 10   -- same for automatic re-plans while moving (keeps the game smooth)
local REPLAN_MOVE = 50       -- yards moved since the last plan before re-planning
local QUICK_MAX_NODES = 100  -- automatic re-plans only look at the nearest nodes
local REPLAN_INTERVAL = 10   -- seconds between automatic re-plans while moving
local DOT_SPACING = 25       -- yards between route line dots
local MAX_DOTS = 500
local LINE_REF = ADDON_NAME .. "Route"
local LINE_COLOR = { 1, 0.82, 0.2, 0.9 }

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
local TYPE_FILTERS = { herb = true, ore = true, chest = true }
local function MatchesFilter(n, filter)
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
---------------------------------------------------------------------------
-- Seeing nodes before we arrive (interact targeting)
---------------------------------------------------------------------------
local savedCVars

local function LookAhead()
    return ns.db.lookAhead ~= false and GetCVar and SetCVar
end

local function WidenLook()
    if savedCVars or not LookAhead() then return end
    savedCVars = {}
    for name, value in pairs(RUN_CVARS) do
        local current = GetCVar(name)
        if current and current ~= value and not (tonumber(current) and tonumber(current) > tonumber(value)) then
            savedCVars[name] = current
            pcall(SetCVar, name, value)
        end
    end
end

local function RestoreLook()
    if not savedCVars then return end
    for name, value in pairs(savedCVars) do pcall(SetCVar, name, value) end
    savedCVars = nil
end

-- Gathering object the game currently offers to interact with: id, type
local function SoftTargetNode()
    local guid = UnitGUID and UnitGUID("softinteract")
    if not guid then return end
    local unitType, _, _, _, _, id = strsplit("-", guid)
    if unitType ~= "GameObject" then return end
    local data = GathercraftQuestieData
    local kind = data and data.kinds["o" .. id]
    local types = { h = "herb", o = "ore", c = "chest" }
    return "o" .. id, kind and types[kind[1]]
end

local logoutWatch = CreateFrame("Frame")
logoutWatch:RegisterEvent("PLAYER_LOGOUT")
logoutWatch:SetScript("OnEvent", RestoreLook)

local function StopRun(silent)
    ns.db.activeRun = nil
    RestoreLook()
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

    -- The node list only changes when the database changes: reuse it
    -- (rebuilding thousands of entries on every plan makes the game hitch)
    if not run.points or run.pointsDirty or run.pointsInstance ~= instance then
        run.points = CollectPoints(run.filter, instance, run.zone)
        run.pointsDirty, run.pointsInstance = false, instance
    end
    local points = run.points
    run.total = #points
    if #points == 0 then
        ns.Print(run.zone and ("No matching nodes in " .. ns.GetZoneName(run.zone) .. ".")
            or "No matching nodes on this continent (check /gcr zones).")
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

-- Empty again and again: rest it longer (5, 10, 20, 30 min), so the
-- route keeps to the spawn points that actually have something
MarkEmpty = function(n, why)
    if ns.IsOnCooldown(n) then return end
    n.emptyStreak = (n.emptyStreak or 0) + 1
    local rest = math.min(SKIP_TIME * 2 ^ (n.emptyStreak - 1), EMPTY_MAX)
    n.emptyUntil = time() + rest
    ns.Debug(("%s was empty (%s, %dx in a row), rested for %d min"):format(n.name, why, n.emptyStreak, rest / 60))
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

    -- Look ahead: once we are close and facing the node, interact targeting
    -- shows whether it is there. Nothing there for a moment = skip it now
    -- instead of walking all the way. Only used after we saw it work once.
    local t = run.targetPoint
    if t and LookAhead() then
        local id, kind = SoftTargetNode()
        if id then
            run.lookWorks = true
        end
        local d = WDist(px, py, t.wx, t.wy)
        if id and d <= LOOK_DIST + 8 and (id == t.node.id or kind == t.node.type) then
            run.lookSeen = t.node
        end
        if run.lookWorks and d <= LOOK_DIST and d > ARRIVE_DIST and run.lookSeen ~= t.node then
            run.lookSince = run.lookSince or GetTime()
            if GetTime() - run.lookSince >= LOOK_TIME then
                run.lookSince = nil
                run.visited[t.node] = true
                run.done = run.done + 1
                MarkEmpty(t.node, "seen from afar")
                Plan(true)
                return
            end
        else
            run.lookSince = nil
        end
    end

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
            if not found then MarkEmpty(c.node, "nothing harvested") end
        end
    end

    -- Every node of the plan you walk past counts as visited, not only the target
    local reached = false
    for _, p in ipairs(run.path) do
        if not run.visited[p.node] and WDist(px, py, p.wx, p.wy) <= ARRIVE_DIST then
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
        ns.Print("HereBeDragons missing, routes are not available.")
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
    WidenLook()
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
        ns.Print("No run target right now. Start one with /gcr run.")
        return
    end
    local node = run.target
    node.emptyUntil = time() + SKIP_TIME
    run.visited[node] = true
    ns.Print(("%s marked empty for %d min."):format(node.name, SKIP_TIME / 60))
    Plan(true)
end

-- Called by the recorder after a node was harvested (it is on cooldown now)
local function OnHarvested(node)
    node.emptyStreak = nil -- it had something: back to normal
    local run = ns.run
    if run then
        run.visited[node] = true
        local px, py = PlayerWorld()
        if px then
            table.insert(run.harvests, { wx = px, wy = py, t = time() })
            if #run.harvests > 20 then table.remove(run.harvests, 1) end
        end
        RequestPlan("harvest")
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
        ns.Print("No available nodes on this continent (check /gcr zones).")
        return
    end
    local path, length = PlanPath(open, px, py)
    preview = { path = path, length = length, instance = instance, px = px, py = py }
    DrawLine(path, length, instance, px, py)
    ns.Print(("Route preview: %d nodes in %d zone(s), path %d yd. /gcr route again to hide."):format(
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
