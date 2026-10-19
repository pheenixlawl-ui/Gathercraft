local ADDON_NAME, ns = ...

local PREFIX = "|cff33ff99WoWFFarm|r: "
local MERGE_RADIUS = 15   -- yards: same node type closer than this = same node
local NEXT_MIN_DIST = 10  -- yards: /fg next skips nodes you are standing on
local ARRIVE_DIST = 10    -- yards: counts as "arrived" during a run
local SKIP_TIME = 300     -- seconds a skipped (empty) node stays out of runs
local TICK = 0.5          -- seconds between arrival checks
local LIST_MAX = 15

local function Print(text)
    print(PREFIX .. text)
end

---------------------------------------------------------------------------
-- Position & distance helpers
---------------------------------------------------------------------------
local function GetPlayerPos()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    return mapID, x, y
end

-- Distance in yards between two map coordinates (0-1) on the same map
local function Distance(mapID, x1, y1, x2, y2)
    local w, h
    if C_Map.GetMapWorldSize then
        w, h = C_Map.GetMapWorldSize(mapID)
    end
    if not w or w == 0 then
        w, h = 1000, 1000 -- rough fallback if map size is unknown
    end
    local dx = (x2 - x1) * w
    local dy = (y2 - y1) * h
    return math.sqrt(dx * dx + dy * dy)
end

local function GetZoneName(mapID)
    local info = C_Map.GetMapInfo(mapID)
    return info and info.name or ("Map " .. mapID)
end

local function SetWaypoint(mapID, x, y)
    if not C_Map.CanSetUserWaypointOnMap(mapID) then
        Print("Waypoints are not allowed on this map.")
        return false
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    return true
end

local function IsOnCooldown(node)
    return node.emptyUntil and node.emptyUntil > time()
end

---------------------------------------------------------------------------
-- Node database
---------------------------------------------------------------------------
local function GetZoneNodes(mapID, create)
    local nodes = ns.db.nodes
    if not nodes[mapID] and create then
        nodes[mapID] = {}
    end
    return nodes[mapID]
end

local function AddNode(name)
    local mapID, x, y = GetPlayerPos()
    if not mapID then
        Print("No position available here (instance?).")
        return
    end

    local list = GetZoneNodes(mapID, true)
    local key = name:lower()

    -- Merge with an existing node of the same type nearby
    for _, n in ipairs(list) do
        if n.name:lower() == key and Distance(mapID, x, y, n.x, n.y) <= MERGE_RADIUS then
            n.x = (n.x * n.count + x) / (n.count + 1)
            n.y = (n.y * n.count + y) / (n.count + 1)
            n.count = n.count + 1
            n.last = time()
            Print(("Merged with existing %s (seen %d times)."):format(n.name, n.count))
            return
        end
    end

    table.insert(list, { name = name, x = x, y = y, count = 1, last = time() })
    Print(("Added %s at %.1f / %.1f (%d nodes in %s)."):format(
        name, x * 100, y * 100, #list, GetZoneName(mapID)))
end

-- Returns nodes of the current zone sorted by distance, optionally filtered
local function GetSortedNodes(filter)
    local mapID, x, y = GetPlayerPos()
    if not mapID then return end
    local list = GetZoneNodes(mapID)
    local result = {}
    if list then
        filter = filter and filter ~= "" and filter:lower() or nil
        for i, n in ipairs(list) do
            if not filter or n.name:lower():find(filter, 1, true) then
                table.insert(result, {
                    node = n,
                    index = i,
                    dist = Distance(mapID, x, y, n.x, n.y),
                })
            end
        end
        table.sort(result, function(a, b) return a.dist < b.dist end)
    end
    return result, mapID
end

local function ListNodes(filter)
    local sorted, mapID = GetSortedNodes(filter)
    if not sorted then
        Print("No position available here.")
        return
    end
    if #sorted == 0 then
        Print("No nodes stored in " .. GetZoneName(mapID) .. ".")
        return
    end
    Print(("%d nodes in %s:"):format(#sorted, GetZoneName(mapID)))
    for i = 1, math.min(#sorted, LIST_MAX) do
        local e = sorted[i]
        local status = ""
        if IsOnCooldown(e.node) then
            status = ("  |cff999999empty, %ds|r"):format(e.node.emptyUntil - time())
        end
        print(("  %s  %.1f / %.1f  %d yd  (x%d)%s"):format(
            e.node.name, e.node.x * 100, e.node.y * 100, e.dist, e.node.count, status))
    end
    if #sorted > LIST_MAX then
        print(("  ... and %d more"):format(#sorted - LIST_MAX))
    end
end

local function NextNode(filter)
    local sorted, mapID = GetSortedNodes(filter)
    if not sorted then
        Print("No position available here.")
        return
    end
    for _, e in ipairs(sorted) do
        if e.dist > NEXT_MIN_DIST and not IsOnCooldown(e.node) then
            if SetWaypoint(mapID, e.node.x, e.node.y) then
                Print(("Next: %s, %d yd away."):format(e.node.name, e.dist))
            end
            return
        end
    end
    Print("No further nodes found in this zone.")
end

local function DeleteNearest()
    local sorted, mapID = GetSortedNodes()
    if not sorted or #sorted == 0 then
        Print("Nothing to delete here.")
        return
    end
    local e = sorted[1]
    if e.dist > MERGE_RADIUS then
        Print(("Nearest node (%s) is %d yd away. Stand closer to delete it."):format(
            e.node.name, e.dist))
        return
    end
    table.remove(GetZoneNodes(mapID), e.index)
    Print("Deleted " .. e.node.name .. ".")
end

local function Stats()
    local zones, total = 0, 0
    for _, list in pairs(ns.db.nodes) do
        if #list > 0 then
            zones = zones + 1
            total = total + #list
        end
    end
    Print(("%d nodes stored in %d zones."):format(total, zones))
end

---------------------------------------------------------------------------
-- Farm run: auto-advance to the next unvisited node
---------------------------------------------------------------------------
local function StopRun(silent)
    ns.db.activeRun = nil
    if ns.ticker then
        ns.ticker:Cancel()
        ns.ticker = nil
    end
    if ns.run then
        ns.run = nil
        C_Map.ClearUserWaypoint()
        if not silent then
            Print("Run stopped.")
        end
    end
end

local function CountVisited(visited)
    local n = 0
    for _ in pairs(visited) do n = n + 1 end
    return n
end

local function AdvanceRun()
    local run = ns.run
    if not run then return end

    local sorted, mapID = GetSortedNodes(run.filter)
    if not sorted or #sorted == 0 then
        Print("No matching nodes in this zone.")
        StopRun()
        return
    end

    -- Only nodes that are not marked empty
    local available = {}
    for _, e in ipairs(sorted) do
        if not IsOnCooldown(e.node) then
            table.insert(available, e)
        end
    end
    if #available == 0 then
        Print("All matching nodes are marked empty right now.")
        StopRun()
        return
    end

    local pick
    for _, e in ipairs(available) do
        if not run.visited[e.node] then
            pick = e
            break
        end
    end

    -- Everything visited: start the next round
    if not pick then
        Print(("Round %d complete, starting again."):format(run.round))
        run.round = run.round + 1
        wipe(run.visited)
        for _, e in ipairs(available) do
            if e.dist > NEXT_MIN_DIST then
                pick = e
                break
            end
        end
        pick = pick or available[1]
    end

    run.mapID = mapID
    run.target = pick.node
    if SetWaypoint(mapID, pick.node.x, pick.node.y) then
        Print(("Next: %s, %d yd (%d/%d this round)."):format(
            pick.node.name, pick.dist, CountVisited(run.visited) + 1, #available))
    end
end

local function CheckArrival()
    local run = ns.run
    if not run or not run.target then return end
    local mapID, x, y = GetPlayerPos()
    if mapID ~= run.mapID then return end
    if Distance(mapID, x, y, run.target.x, run.target.y) <= ARRIVE_DIST then
        run.visited[run.target] = true
        if SOUNDKIT and SOUNDKIT.MAP_PING then
            PlaySound(SOUNDKIT.MAP_PING)
        end
        AdvanceRun()
    end
end

local function SkipNode()
    local run = ns.run
    if not run or not run.target then
        Print("No run active. Start one with /fg run.")
        return
    end
    local node = run.target
    node.emptyUntil = time() + SKIP_TIME
    run.visited[node] = true
    Print(("%s marked empty for %d min."):format(node.name, SKIP_TIME / 60))
    AdvanceRun()
end

local function StartRun(filter)
    StopRun(true)
    ns.run = {
        filter = (filter and filter ~= "" and filter) or nil,
        visited = {},
        round = 1,
    }
    ns.db.activeRun = { filter = ns.run.filter }
    Print("Run started" .. (ns.run.filter and (" (" .. ns.run.filter .. ")") or "") .. ".")
    AdvanceRun()
    if ns.run then
        ns.ticker = C_Timer.NewTicker(TICK, CheckArrival)
    end
end

---------------------------------------------------------------------------
-- API check
---------------------------------------------------------------------------
local function check(label, value)
    print(("  %s: %s"):format(label, value and "|cff00ff00yes|r" or "|cffff0000no|r"))
end

local function ApiTest()
    local _, build, _, iface = GetBuildInfo()
    Print("API check")
    print(("  Build: %s  Interface: %s"):format(build, iface))
    check("C_Map", C_Map)
    check("C_Map.SetUserWaypoint", C_Map.SetUserWaypoint)
    check("C_Map.GetMapWorldSize", C_Map.GetMapWorldSize)
    check("C_SuperTrack", C_SuperTrack)
    local mapID, x, y = GetPlayerPos()
    if mapID then
        print(("  Zone: %s (%d)  Position: %.2f / %.2f"):format(
            GetZoneName(mapID), mapID, x * 100, y * 100))
    end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        WoWFFarmDB = WoWFFarmDB or {}
        WoWFFarmDB.version = WoWFFarmDB.version or 1
        WoWFFarmDB.nodes = WoWFFarmDB.nodes or {}
        ns.db = WoWFFarmDB
    elseif event == "PLAYER_LOGIN" then
        Print("loaded. Type /fg help for commands.")
        -- Resume a run that was active before reload/logout
        if ns.db.activeRun then
            C_Timer.After(2, function()
                if ns.db.activeRun then
                    StartRun(ns.db.activeRun.filter)
                end
            end)
        end
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Help()
    Print("commands:")
    print("  /fg add <name>   - store a node at your position")
    print("  /fg list [name]  - list nodes in this zone")
    print("  /fg next [name]  - waypoint to nearest node")
    print("  /fg run [name]   - farm run, auto-advances on arrival")
    print("  /fg skip         - current node is empty, go to next")
    print("  /fg stop         - stop the farm run")
    print("  /fg del          - delete the node you stand at")
    print("  /fg clear        - remove waypoint")
    print("  /fg stats        - total stored nodes")
    print("  /fg test         - API check")
end

SLASH_WOWFFARM1 = "/fg"
SlashCmdList.WOWFFARM = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()

    if cmd == "add" then
        if rest == "" then
            Print("Usage: /fg add <name>")
        else
            AddNode(rest)
        end
    elseif cmd == "list" then
        ListNodes(rest)
    elseif cmd == "next" then
        NextNode(rest)
    elseif cmd == "run" then
        StartRun(rest)
    elseif cmd == "skip" then
        SkipNode()
    elseif cmd == "stop" then
        StopRun()
    elseif cmd == "del" then
        DeleteNearest()
    elseif cmd == "clear" then
        StopRun(true)
        C_Map.ClearUserWaypoint()
        Print("Waypoint cleared.")
    elseif cmd == "stats" then
        Stats()
    elseif cmd == "test" then
        ApiTest()
    else
        Help()
    end
end

---------------------------------------------------------------------------
-- Shared with other files
---------------------------------------------------------------------------
ns.Print = Print
ns.GetPlayerPos = GetPlayerPos
ns.Distance = Distance
ns.StartRun = StartRun
ns.StopRun = StopRun
ns.SkipNode = SkipNode