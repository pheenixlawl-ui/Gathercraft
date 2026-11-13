local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Spawn points of an item per zone (0.2 B2 C3)
--   "Where are the most known spawn points of Peacebloom?" - for the item
--   tooltip, later for the shopping list. Counted are places, not entries:
--
--   * Questie data: the same place can stand under several object IDs of
--     one item (Incendicite in the Wetlands: 58 entries, 29 places). So per
--     item and zone the DIFFERENT packed coordinates over all the item's
--     node kinds are counted - a union, not a sum. Exactly equal
--     coordinates only: two places close to each other stay two.
--   * Your own points: nodes you gathered yourself (no source, not just
--     seen on the minimap), of a kind the spawn data knows. One counts only
--     when no Questie place of the same ITEM (whatever object ID) is within
--     15 yards - the rule of ns.IsKnownSpawn, but over all kinds of the
--     item. Own points are not merged with each other: the recorder has
--     decided what is one node and what is a neighbour.
--   * Not counted: nodes from sync, starter data, minimap sightings and
--     unconfirmed reports (Sven, 12.11.2026). A synced node you gathered
--     yourself is yours and counts.
--   * The item of a node is the main item of its kind in the spawn data,
--     not what happened to be in the loot.
--
--   Nothing is built when the file loads (the data files come later in the
--   TOC) and nothing while nobody uses it: a user says Start and Stop. The
--   Questie part is built once, a few zones per frame; the own part per
--   zone, a moment after the last change there. While an item's numbers
--   are not current, there are none - never an old number.
---------------------------------------------------------------------------
local KNOWN_RADIUS = 15  -- yards: an own point this close to a Questie place is that place (Starter.lua: MERGE_RADIUS * 1.5)
local KNOWN_BOX = 0.01   -- share of the map checked before the distance is worked out (as ns.IsKnownSpawn)
local ZONES_PER_STEP = 2 -- Questie zones read per frame step
local STEP = 0.05        -- seconds between steps
local SETTLE = 3         -- seconds after the last node change before the own part is counted again
local COMBAT_WAIT = 1    -- seconds until a waiting step looks again: in combat nothing is counted

local function Fighting()
    return InCombatLockdown and InCombatLockdown() and true or false
end

local users = {}         -- who wants the counts (name -> true)
local state = "off"      -- "off", "building", "ready"
local run = 0            -- counts up with every Start/Stop: steps of an older build end themselves
local rev = 0            -- counts up whenever numbers change or stop being current
local buildMs = 0        -- time spent building, in ms (for /gcr tooltiptest)

local questie            -- itemID -> mapID -> number of different places
local own                -- mapID -> itemID -> number of own points
local lists              -- itemID -> { { mapID, total, questie, own }, ... } most places first
local stale = {}         -- itemID -> true: its numbers wait for the recount
local staleAll = false   -- every item waits
local dirty = {}         -- mapID -> true: the own part of this zone must be counted again
local dirtyAll = false
local settle             -- the running timer for the recount

local function Kind(id)
    local data = GathercraftQuestieData
    local kind = data and id and data.kinds[id]
    if kind and (kind[1] == "h" or kind[1] == "o") and kind[2] > 0 then return kind end
end

-- The item's zone list, most places first (then the smaller map ID, so the
-- order is the same every time)
local function BuildList(itemID)
    local zones, seen = {}, {}
    for mapID, n in pairs(questie[itemID] or {}) do
        seen[mapID] = true
        local mine = own[mapID] and own[mapID][itemID] or 0
        zones[#zones + 1] = { mapID = mapID, total = n + mine, questie = n, own = mine }
    end
    for mapID, items in pairs(own) do
        if not seen[mapID] and items[itemID] then
            zones[#zones + 1] = { mapID = mapID, total = items[itemID], questie = 0, own = items[itemID] }
        end
    end
    table.sort(zones, function(a, b)
        if a.total ~= b.total then return a.total > b.total end
        return a.mapID < b.mapID
    end)
    lists[itemID] = #zones > 0 and zones or nil
end

-- The own points of one zone, counted anew. Returns the items whose number
-- changed.
local function CountOwn(mapID)
    local data = GathercraftQuestieData
    local before = own[mapID] or {}
    local mine, wanted
    for _, n in ipairs((ns.db and ns.db.nodes and ns.db.nodes[mapID]) or {}) do
        if n.source == nil and not n.seenOnly and (n.type == "herb" or n.type == "ore") and n.x and n.y then
            local kind = Kind(n.id)
            if kind then
                mine = mine or {}
                mine[#mine + 1] = n
                wanted = wanted or {}
                wanted[kind[2]] = wanted[kind[2]] or {}
            end
        end
    end
    local now = {}
    if mine then
        -- the Questie places of the items in question, all their kinds together
        for id, x, y in ((data and data.zones[mapID]) or ""):gmatch("(%d+),(%d+),(%d+)") do
            local kind = Kind("o" .. id)
            local places = kind and wanted[kind[2]]
            if places then
                places[#places + 1] = tonumber(x) / 10000
                places[#places + 1] = tonumber(y) / 10000
            end
        end
        for _, n in ipairs(mine) do
            local itemID = Kind(n.id)[2]
            local places, known = wanted[itemID], false
            for i = 1, #places, 2 do
                if math.abs(places[i] - n.x) < KNOWN_BOX and math.abs(places[i + 1] - n.y) < KNOWN_BOX
                    and ns.Distance(mapID, n.x, n.y, places[i], places[i + 1]) <= KNOWN_RADIUS then
                    known = true
                    break
                end
            end
            if not known then now[itemID] = (now[itemID] or 0) + 1 end
        end
    end
    own[mapID] = next(now) and now or nil
    local changed = {}
    for itemID, n in pairs(now) do if before[itemID] ~= n then changed[itemID] = true end end
    for itemID in pairs(before) do if not now[itemID] then changed[itemID] = true end end
    return changed
end

-- The recount after node changes: zone by zone, then the lists of the items
-- whose numbers moved; after that everything is current again
local function Recount(myRun)
    local zones = {}
    if dirtyAll then
        local seen = {}
        for mapID in pairs((ns.db and ns.db.nodes) or {}) do seen[mapID] = true zones[#zones + 1] = mapID end
        for mapID in pairs(own) do if not seen[mapID] then zones[#zones + 1] = mapID end end
    else
        for mapID in pairs(dirty) do zones[#zones + 1] = mapID end
    end
    dirty, dirtyAll = {}, false
    table.sort(zones)
    local i, changed = 0, {}
    local function Step()
        if myRun ~= run then return end
        if Fighting() then
            C_Timer.After(COMBAT_WAIT, Step)
            return
        end
        local t0 = debugprofilestop()
        i = i + 1
        local mapID = zones[i]
        if mapID then
            for itemID in pairs(CountOwn(mapID)) do changed[itemID] = true end
            buildMs = buildMs + (debugprofilestop() - t0)
            C_Timer.After(STEP, Step)
            return
        end
        for itemID in pairs(changed) do BuildList(itemID) end
        buildMs = buildMs + (debugprofilestop() - t0)
        -- changes that came in meanwhile wait for their own recount
        if settle or dirtyAll or next(dirty) then return end
        stale, staleAll = {}, false
        rev = rev + 1
    end
    Step()
end

local function Settle()
    if state ~= "ready" then return end -- (the first build counts every zone at its end)
    local myRun = run
    if settle then settle:Cancel() end
    settle = C_Timer.NewTimer(SETTLE, function()
        settle = nil
        if myRun == run then Recount(myRun) end
    end)
end

-- Node changes: the item of a single node waits, or - when nobody says which
-- node - every item
table.insert(ns.nodeListeners, function(kind, mapID, node)
    if state == "off" then return end
    local nodeKind = node and Kind(node.id)
    if mapID and nodeKind then
        dirty[mapID] = true
        if not stale[nodeKind[2]] then
            stale[nodeKind[2]] = true
            rev = rev + 1
        end
    elseif mapID and node then
        return -- a chest, a fishing spot, a kind the spawn data does not know: no count moves
    else
        if mapID then dirty[mapID] = true else dirtyAll = true end
        if not staleAll then
            staleAll = true
            rev = rev + 1
        end
    end
    Settle()
end)

-- The first build: the Questie part (it never changes while the game
-- runs), then the own points of every zone
local function Build(myRun)
    local data = GathercraftQuestieData
    questie, own, lists = {}, {}, {}
    local zones = {}
    for mapID in pairs((data and data.zones) or {}) do zones[#zones + 1] = mapID end
    table.sort(zones)
    local i = 0
    local function Step()
        if myRun ~= run then return end
        if Fighting() then
            C_Timer.After(COMBAT_WAIT, Step)
            return
        end
        local t0 = debugprofilestop()
        for _ = 1, ZONES_PER_STEP do
            i = i + 1
            local mapID = zones[i]
            if not mapID then
                -- the Questie part is done: lists for every item, then the own points
                for itemID in pairs(questie) do BuildList(itemID) end
                buildMs = buildMs + (debugprofilestop() - t0)
                state = "ready"
                dirtyAll, staleAll = true, true
                Recount(myRun)
                return
            end
            local seen = {}
            for id, x, y in data.zones[mapID]:gmatch("(%d+),(%d+),(%d+)") do
                local kind = Kind("o" .. id)
                if kind then
                    local itemID = kind[2]
                    local place = itemID .. ":" .. x .. ":" .. y
                    if not seen[place] then
                        seen[place] = true
                        local perZone = questie[itemID]
                        if not perZone then
                            perZone = {}
                            questie[itemID] = perZone
                        end
                        perZone[mapID] = (perZone[mapID] or 0) + 1
                    end
                end
            end
        end
        buildMs = buildMs + (debugprofilestop() - t0)
        C_Timer.After(STEP, Step)
    end
    Step()
end

-- A user wants the counts: built if they are not there yet
ns.SpawnCountsStart = function(who)
    users[who or "?"] = true
    if state ~= "off" then return end
    state, run, rev, buildMs = "building", run + 1, rev + 1, 0
    stale, staleAll, dirty, dirtyAll = {}, true, {}, false
    Build(run)
end

-- A user needs them no longer: without any user a running build ends and
-- the numbers are dropped
ns.SpawnCountsStop = function(who)
    users[who or "?"] = nil
    if next(users) or state == "off" then return end
    state, run, rev = "off", run + 1, rev + 1
    if settle then settle:Cancel() settle = nil end
    questie, own, lists = nil, nil, nil
    stale, staleAll, dirty, dirtyAll = {}, false, {}, false
end

-- The zones of an item, most places first: { { mapID, total, questie, own }, ... }.
-- nil while the numbers are being built or wait for a recount (never an
-- old number); an empty table for an item nobody gathers from a node.
-- Don't change the tables.
local NONE = {}
ns.SpawnCounts = function(itemID)
    if state ~= "ready" or staleAll or stale[itemID] then return nil end
    return lists[itemID] or NONE
end

-- "off" / "building" / "ready", the time spent building in ms, the revision
ns.SpawnCountsState = function()
    return state, buildMs, rev
end
ns.SpawnCountsRev = function() return rev end
