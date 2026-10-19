local ADDON_NAME, ns = ...

local PREFIX = "|cff33ff99WoWFFarm|r: "
local MERGE_RADIUS = 15   -- yards: same node kind closer than this = same node
local NEXT_MIN_DIST = 10  -- yards: /fg next skips nodes you are standing on
local ARRIVE_DIST = 10    -- yards: counts as "arrived" during a run
local SKIP_TIME = 300     -- seconds a skipped (empty) node stays out of runs
local RESPAWN_TIME = 300  -- seconds a harvested node stays out of runs
local WAIT_RETRY = 5      -- seconds between retries while all nodes are on cooldown
local LOOT_WAIT = 1.5     -- seconds to wait for the loot window after a gather
local TICK = 0.5          -- seconds between arrival checks
local LIST_MAX = 15
local DEBUG_WINDOW = "WoWFFarm"

-- Gathering spells by (lowercased) spell name -> node type
local GATHER_SPELLS = {
    ["herb gathering"] = "herb",
    ["herbalism"] = "herb",
    ["kräutersammeln"] = "herb",
    ["kräuterkunde"] = "herb",
    ["mining"] = "ore",
    ["bergbau"] = "ore",
}

local TYPE_COLORS = { herb = "|cff66ff66", ore = "|cffffcc66" }

-- Other files register functions here to hear about database changes
ns.nodeListeners = ns.nodeListeners or {}

local function Print(text)
    print(PREFIX .. text)
end

-- Finds the chat window named "WoWFFarm" or creates it
local function GetDebugFrame()
    for i = 1, NUM_CHAT_WINDOWS do
        local name = GetChatWindowInfo(i)
        if name == DEBUG_WINDOW and _G["ChatFrame" .. i] then
            return _G["ChatFrame" .. i]
        end
    end
    if FCF_OpenNewWindow then
        local f = FCF_OpenNewWindow(DEBUG_WINDOW)
        if f then return f end
    end
    return DEFAULT_CHAT_FRAME
end

local function Debug(text)
    if ns.db and ns.db.debug then
        GetDebugFrame():AddMessage("|cff999999WoWFFarm debug|r: " .. text)
    end
end

local function TypeTag(nodeType)
    if not nodeType then return "" end
    return " " .. (TYPE_COLORS[nodeType] or "") .. "[" .. nodeType .. "]|r"
end

local function NodesChanged()
    if ns.OnNodesChanged then
        ns.OnNodesChanged()
    end
    for _, fn in ipairs(ns.nodeListeners) do
        fn()
    end
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
--   node = { id, name, type, x, y, count, last, emptyUntil, lastSpawn, item }
--   id: "o<objectID>" (game object, language independent) or
--       "i<itemID>" (first loot item) or nil (manual nodes)
--   lastSpawn: spawn UID of the last gather (same spawn = not counted again)
--   item: first loot item ID (used for map icons)
---------------------------------------------------------------------------
local function GetZoneNodes(mapID, create)
    local nodes = ns.db.nodes
    if not nodes[mapID] and create then
        nodes[mapID] = {}
    end
    return nodes[mapID]
end

-- Key that identifies a kind of node (e.g. all Peacebloom), language independent if possible
local function KindKey(n)
    return n.id or ("n:" .. n.name:lower())
end

-- Selection from the zones window (/fg zones)
local function IsNodeEnabled(n, mapID)
    if ns.db.disabledZones[mapID] then return false end
    if ns.db.disabledKinds[KindKey(n)] then return false end
    return true
end

local function SameKind(n, id, nameKey)
    if id and n.id then
        return n.id == id
    end
    return n.name:lower() == nameKey
end

local function AddNodeAt(mapID, x, y, name, nodeType, id, spawn, item)
    local list = GetZoneNodes(mapID, true)
    local nameKey = name:lower()

    -- Merge with an existing node of the same kind nearby
    for _, n in ipairs(list) do
        if SameKind(n, id, nameKey) and Distance(mapID, x, y, n.x, n.y) <= MERGE_RADIUS then
            if spawn and n.lastSpawn == spawn then
                -- Same spawn gathered again (e.g. a vein mined twice): don't count it again
                n.last = time()
                Debug(("Same spawn of %s gathered again, not counted."):format(n.name))
                return n
            end
            n.x = (n.x * n.count + x) / (n.count + 1)
            n.y = (n.y * n.count + y) / (n.count + 1)
            n.count = n.count + 1
            n.last = time()
            n.id = n.id or id
            n.type = n.type or nodeType
            n.item = n.item or item
            n.lastSpawn = spawn or n.lastSpawn
            Print(("Merged %s%s (seen %d times)."):format(n.name, TypeTag(n.type), n.count))
            NodesChanged()
            return n
        end
    end

    local node = {
        id = id, name = name, type = nodeType, x = x, y = y,
        count = 1, last = time(), lastSpawn = spawn, item = item,
    }
    table.insert(list, node)
    Print(("Added %s%s at %.1f / %.1f (%d nodes in %s)."):format(
        name, TypeTag(nodeType), x * 100, y * 100, #list, GetZoneName(mapID)))
    NodesChanged()
    return node
end

local function AddNode(name)
    local mapID, x, y = GetPlayerPos()
    if not mapID then
        Print("No position available here (instance?).")
        return
    end
    return AddNodeAt(mapID, x, y, name)
end

-- Returns nodes of the current zone sorted by distance.
-- Filter matches the node type ("herb", "ore") or part of the name.
-- useSelection: only nodes checked in the zones window.
local function GetSortedNodes(filter, useSelection)
    local mapID, x, y = GetPlayerPos()
    if not mapID then return end
    local list = GetZoneNodes(mapID)
    local result = {}
    if list then
        filter = filter and filter ~= "" and filter:lower() or nil
        for i, n in ipairs(list) do
            local match = not filter or n.type == filter or n.name:lower():find(filter, 1, true)
            if match and useSelection and not IsNodeEnabled(n, mapID) then
                match = false
            end
            if match then
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
            status = ("  |cff999999cooldown %ds|r"):format(e.node.emptyUntil - time())
        end
        local idText = (ns.db.debug and e.node.id) and ("  |cff999999" .. e.node.id .. "|r") or ""
        print(("  %s%s  %.1f / %.1f  %d yd  (x%d)%s%s"):format(
            e.node.name, TypeTag(e.node.type), e.node.x * 100, e.node.y * 100,
            e.dist, e.node.count, status, idText))
    end
    if #sorted > LIST_MAX then
        print(("  ... and %d more"):format(#sorted - LIST_MAX))
    end
end

local function NextNode(filter)
    local sorted, mapID = GetSortedNodes(filter, true)
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
    NodesChanged()
end

local function Stats()
    local zones, total, herbs, ores = 0, 0, 0, 0
    for _, list in pairs(ns.db.nodes) do
        if #list > 0 then
            zones = zones + 1
            total = total + #list
            for _, n in ipairs(list) do
                if n.type == "herb" then
                    herbs = herbs + 1
                elseif n.type == "ore" then
                    ores = ores + 1
                end
            end
        end
    end
    Print(("%d nodes in %d zones (%d herbs, %d ores)."):format(total, zones, herbs, ores))
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
    run.lastTry = time()
    run.target = nil

    local sorted, mapID = GetSortedNodes(run.filter, true)
    if not sorted then return end -- no position right now, retry later
    if #sorted == 0 then
        Print("No matching nodes in this zone (check /fg zones).")
        StopRun()
        return
    end

    -- Only nodes that are not on cooldown
    local available = {}
    for _, e in ipairs(sorted) do
        if not IsOnCooldown(e.node) then
            table.insert(available, e)
        end
    end
    if #available == 0 then
        if not run.waiting then
            Print("All matching nodes are on cooldown. Waiting for respawns...")
            C_Map.ClearUserWaypoint()
        end
        run.waiting = true
        return
    end
    run.waiting = nil

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
    if not run then return end

    -- Waiting for respawns (or no position): retry every few seconds
    if not run.target then
        if time() - (run.lastTry or 0) >= WAIT_RETRY then
            AdvanceRun()
        end
        return
    end

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
        Print("No run target right now. Start one with /fg run.")
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
-- Recorder: detect herb gathering / mining and store the node
--   1. UNIT_SPELLCAST_SENT      -> gathering spell? remember name + position
--   2. UNIT_SPELLCAST_SUCCEEDED -> gather worked
--   3. LOOT_READY / LOOT_OPENED -> read object ID, spawn UID, item ID
--   4. record (or record without IDs if no loot window shows up in time)
---------------------------------------------------------------------------
local function SpellName(spellID)
    if not spellID then return end
    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spellID)
    elseif GetSpellInfo then
        return (GetSpellInfo(spellID))
    end
end

local function GetGatherType(spellID)
    local name = SpellName(spellID)
    if not name then return nil, nil end
    return GATHER_SPELLS[name:lower()], name
end

local function GetTooltipTitle()
    if GameTooltip and GameTooltip:IsShown() then
        local line = _G.GameTooltipTextLeft1
        return line and line:GetText()
    end
end

-- Reads the loot source (game object ID + spawn UID) and the first item ID
local function ReadLoot()
    local objectID, spawn, itemID, firstGUID
    local count = GetNumLootItems and GetNumLootItems() or 0
    for slot = 1, count do
        if GetLootSourceInfo and not objectID then
            local guid = GetLootSourceInfo(slot)
            if guid then
                firstGUID = firstGUID or guid
                local unitType, _, _, _, _, id, spawnUID = strsplit("-", guid)
                if unitType == "GameObject" then
                    objectID = tonumber(id)
                    spawn = spawnUID
                end
            end
        end
        if not itemID then
            local link = GetLootSlotLink(slot)
            if link then
                itemID = tonumber(link:match("item:(%d+)"))
            end
        end
    end
    return objectID, spawn, itemID, firstGUID, count
end

local function TryRecord()
    local p = ns.pending
    if not p or not p.succeeded or p.done then return end
    if not p.lootSeen and GetTime() - p.succeededAt < LOOT_WAIT then
        return -- give the loot window a moment
    end
    p.done = true
    ns.pending = nil

    local id
    if p.objectID then
        id = "o" .. p.objectID
    elseif p.itemID then
        id = "i" .. p.itemID
    end
    Debug(("RECORD name=%s type=%s id=%s spawn=%s item=%s"):format(
        p.name, p.type, tostring(id), tostring(p.spawn), tostring(p.itemID)))

    local node = AddNodeAt(p.mapID, p.x, p.y, p.name, p.type, id, p.spawn, p.itemID)
    if not node then return end
    node.emptyUntil = time() + RESPAWN_TIME

    local run = ns.run
    if run then
        run.visited[node] = true
        if run.target == node then
            AdvanceRun()
        end
    end
end

local function OnSpellcastSent(unit, target, castGUID, spellID)
    if unit ~= "player" then return end
    local nodeType, spellName = GetGatherType(spellID)
    Debug(("SENT spell=%s (%s) target=%s type=%s"):format(
        tostring(spellName), tostring(spellID), tostring(target), tostring(nodeType)))
    if not nodeType then return end

    local name = (target and target ~= "") and target or GetTooltipTitle()
    if not name or name == "" then
        name = (nodeType == "herb") and "Unknown Herb" or "Unknown Ore"
    end

    local mapID, x, y = GetPlayerPos()
    if not mapID then return end
    ns.pending = {
        castGUID = castGUID, name = name, type = nodeType,
        mapID = mapID, x = x, y = y, sentAt = GetTime(),
    }
end

local function OnSpellcastSucceeded(castGUID, spellID)
    Debug(("SUCCEEDED spell=%s (%s)"):format(tostring(SpellName(spellID)), tostring(spellID)))
    local p = ns.pending
    if not p or p.castGUID ~= castGUID then return end
    p.succeeded = true
    p.succeededAt = GetTime()
    TryRecord()
    C_Timer.After(LOOT_WAIT + 0.1, TryRecord)
end

local function OnSpellcastFailed(castGUID)
    local p = ns.pending
    if p and p.castGUID == castGUID then
        ns.pending = nil
        Debug("Gathering failed or interrupted, nothing recorded.")
    end
end

local function OnLoot()
    local objectID, spawn, itemID, guid, count = ReadLoot()
    Debug(("LOOT slots=%d source=%s item=%s"):format(count, tostring(guid), tostring(itemID)))

    local p = ns.pending
    if not p or p.lootSeen or GetTime() - p.sentAt > 10 then return end
    p.lootSeen = true
    p.objectID = objectID
    p.spawn = spawn
    p.itemID = itemID
    TryRecord()
end

---------------------------------------------------------------------------
-- Maintenance
---------------------------------------------------------------------------
local function WipeNodes(scope)
    if scope == "zone" then
        local mapID = GetPlayerPos()
        if not mapID then
            Print("No position available here.")
            return
        end
        local count = ns.db.nodes[mapID] and #ns.db.nodes[mapID] or 0
        ns.db.nodes[mapID] = nil
        StopRun(true)
        Print(("Deleted %d nodes in %s."):format(count, GetZoneName(mapID)))
    elseif scope == "all" then
        wipe(ns.db.nodes)
        StopRun(true)
        Print("All nodes deleted.")
    else
        Print("Usage: /fg wipe zone  or  /fg wipe all")
        return
    end
    NodesChanged()
end

local function ToggleDebug()
    ns.db.debug = not ns.db.debug
    Print("Debug mode " .. (ns.db.debug and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
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
    check("C_Spell.GetSpellName", C_Spell and C_Spell.GetSpellName)
    check("GetLootSourceInfo", GetLootSourceInfo)
    check("LibStub", LibStub)
    check("HereBeDragons", LibStub and LibStub("HereBeDragons-2.0", true))
    check("HereBeDragons-Pins", LibStub and LibStub("HereBeDragons-Pins-2.0", true))
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
frame:RegisterEvent("UNIT_SPELLCAST_SENT")
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
frame:RegisterEvent("LOOT_READY")
frame:RegisterEvent("LOOT_OPENED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            WoWFFarmDB = WoWFFarmDB or {}
            WoWFFarmDB.version = WoWFFarmDB.version or 1
            WoWFFarmDB.nodes = WoWFFarmDB.nodes or {}
            WoWFFarmDB.disabledZones = WoWFFarmDB.disabledZones or {}
            WoWFFarmDB.disabledKinds = WoWFFarmDB.disabledKinds or {}
            ns.db = WoWFFarmDB
        end
    elseif event == "PLAYER_LOGIN" then
        Print("loaded. Type /fg help for commands.")
        if ns.db.debug then
            Print("Debug mode is ON (/fg debug to turn off).")
        end
        -- Resume a run that was active before reload/logout
        if ns.db.activeRun then
            C_Timer.After(2, function()
                if ns.db.activeRun then
                    StartRun(ns.db.activeRun.filter)
                end
            end)
        end
    elseif event == "UNIT_SPELLCAST_SENT" then
        OnSpellcastSent(...)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, castGUID, spellID = ...
        OnSpellcastSucceeded(castGUID, spellID)
    elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
        local _, castGUID = ...
        OnSpellcastFailed(castGUID)
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        OnLoot()
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Help()
    Print("commands:")
    print("  /fg zones        - choose zones and node kinds")
    print("  /fg run [herb|ore|name] - farm run, auto-advances on arrival")
    print("  /fg skip         - current node is empty, go to next")
    print("  /fg stop         - stop the farm run")
    print("  /fg pins         - show/hide map and minimap pins")
    print("  /fg list [filter] - list nodes in this zone")
    print("  /fg next [filter] - waypoint to nearest node")
    print("  /fg add <name>   - store a node manually")
    print("  /fg del          - delete the node you stand at")
    print("  /fg wipe zone|all - delete stored nodes")
    print("  /fg stats        - node totals")
    print("  /fg clear        - remove waypoint")
    print("  /fg debug        - toggle debug output")
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
    elseif cmd == "zones" then
        if ns.ToggleZones then
            ns.ToggleZones()
        end
    elseif cmd == "pins" then
        if ns.TogglePins then
            ns.TogglePins()
        else
            Print("Pins are not available (HereBeDragons missing?).")
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
    elseif cmd == "wipe" then
        WipeNodes(rest:lower())
    elseif cmd == "clear" then
        StopRun(true)
        C_Map.ClearUserWaypoint()
        Print("Waypoint cleared.")
    elseif cmd == "stats" then
        Stats()
    elseif cmd == "debug" then
        ToggleDebug()
    elseif cmd == "test" then
        ApiTest()
    else
        Help()
    end
end

---------------------------------------------------------------------------
-- Shared with other files
---------------------------------------------------------------------------
ns.TYPE_COLORS = TYPE_COLORS
ns.Print = Print
ns.Debug = Debug
ns.GetPlayerPos = GetPlayerPos
ns.Distance = Distance
ns.GetZoneName = GetZoneName
ns.KindKey = KindKey
ns.IsOnCooldown = IsOnCooldown
ns.IsNodeEnabled = IsNodeEnabled
ns.StartRun = StartRun
ns.StopRun = StopRun
ns.SkipNode = SkipNode