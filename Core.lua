local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

-- Locales.lua missing (a /reload after an update that added files: only a
-- full restart loads new files): keep working in English instead of failing
if not ns.LText then
    ns.L = L
    ns.languageListeners = ns.languageListeners or {}
    ns.Language = function() return "enUS" end
    ns.LANGUAGES = { { code = "auto", name = "Auto (game language)" } }
    ns.ApplyLanguage = function() end
    ns.LText = function(obj, key, ...)
        if obj then obj:SetText(select("#", ...) > 0 and key:format(...) or key) end
    end
end

local PREFIX = "|cff33ff99Gathercraft|r: "
local MERGE_RADIUS = 10   -- yards: same node kind closer than this can be the same node
local NEXT_MIN_DIST = 10  -- yards: /gcr next skips nodes you are standing on
local RESPAWN_TIME = 300  -- seconds a harvested node stays out of runs
local RESPAWN_BY_TYPE = { chest = 900 } -- chests take longer
local LOOT_WAIT = 1.5     -- seconds to wait for the loot window after a gather
local LIST_MAX = 15
local DEBUG_WINDOW = "Gathercraft"

-- Gathering spells by (lowercased) spell name -> node type
local GATHER_SPELLS = {
    ["herb gathering"] = "herb",
    ["herbalism"] = "herb",
    ["kräutersammeln"] = "herb",
    ["kräuterkunde"] = "herb",
    ["mining"] = "ore",
    ["bergbau"] = "ore",
    ["opening"] = "chest", -- only counts for chest-like objects, see IsChestName
    ["öffnen"] = "chest",
}

-- The same spells by ID (Classic ranks). Their names in the client's own
-- language are added at login, so detection works in every language.
local GATHER_SPELL_IDS = {
    [2366] = "herb", [2368] = "herb", [3570] = "herb", [11993] = "herb", -- Herb Gathering
    [2575] = "ore", [2576] = "ore", [3564] = "ore", [10248] = "ore",     -- Mining
    [3365] = "chest", [6247] = "chest", [6477] = "chest", [6478] = "chest", -- Opening
    [21651] = "chest", [22810] = "chest",
}

-- Known gathering objects (herbs, ores, chests by object ID) from the spawn data
local KIND_TYPES = { h = "herb", o = "ore", c = "chest" }
local function KnownObjectType(objectID)
    local data = GathercraftQuestieData
    local kind = data and objectID and data.kinds["o" .. objectID]
    return kind and KIND_TYPES[kind[1]]
end

-- "Opening" is also used for quest objects and doors: only real chests count
local CHEST_WORDS = {
    "chest", "strongbox", "footlocker", "coffer",            -- en
    "truhe", "kiste", "schatulle", "kassette",               -- de
    "coffre", "malle", "cassette",                           -- fr
    "cofre", "baúl", "arca",                                 -- es / pt
    "forziere", "baule", "cassa",                            -- it
    "сундук", "ящик", "ларец",                               -- ru
}
local function IsChestName(name)
    if not name then return false end
    name = name:lower()
    for _, word in ipairs(CHEST_WORDS) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

local TYPE_COLORS = { herb = "|cff66ff66", ore = "|cffffcc66", chest = "|cffff9955" }

-- Other files register functions here to hear about database changes
ns.nodeListeners = ns.nodeListeners or {}
ns.gatherListeners = ns.gatherListeners or {} -- fn(node, pending) after each recorded gather

local function Print(text)
    print(PREFIX .. text)
end

-- Finds the chat window named "Gathercraft" or creates it
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
        GetDebugFrame():AddMessage("|cff999999Gathercraft debug|r: " .. text)
    end
end

local function TypeTag(nodeType)
    if not nodeType then return "" end
    return " " .. (TYPE_COLORS[nodeType] or "") .. "[" .. nodeType .. "]|r"
end

-- Lookup caches, rebuilt lazily after changes (see FindNode / KnownName)
local nodeIndex = {}   -- mapID -> kind id -> { nodes }
local nameCache        -- kind id -> name we know in our own language

-- Tells everyone about database changes.
--   kind = "add" / "update" with mapID and node for a single node,
--   nil for bigger changes (delete, wipe, imports, selection)
local function NodesChanged(kind, mapID, node)
    if kind == "add" and mapID and nodeIndex[mapID] and node and node.id then
        local byId = nodeIndex[mapID]
        byId[node.id] = byId[node.id] or {}
        table.insert(byId[node.id], node)
    elseif kind ~= "update" then
        wipe(nodeIndex)
    end
    if kind ~= "update" then
        nameCache = nil
    end
    if ns.OnNodesChanged then
        ns.OnNodesChanged(kind, mapID, node)
    end
    for _, fn in ipairs(ns.nodeListeners) do
        fn(kind, mapID, node)
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
    return info and info.name or (L["Map "] .. mapID)
end

local function SetWaypoint(mapID, x, y)
    if not C_Map.CanSetUserWaypointOnMap(mapID) then
        Print(L["Waypoints are not allowed on this map."])
        return false
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    return true
end

local function IsOnCooldown(node)
    return node.emptyUntil and node.emptyUntil > time()
end

-- Fast lookup: a node of this kind near x/y (map coordinates) or nil.
-- Uses an index per zone and kind instead of scanning every node.
local function FindNode(mapID, id, x, y, radius)
    local list = ns.db.nodes[mapID]
    if not list or not id then return end
    local byId = nodeIndex[mapID]
    if not byId then
        byId = {}
        for _, n in ipairs(list) do
            if n.id then
                byId[n.id] = byId[n.id] or {}
                table.insert(byId[n.id], n)
            end
        end
        nodeIndex[mapID] = byId
    end
    local candidates = byId[id]
    if not candidates then return end
    local best, bestD
    for _, n in ipairs(candidates) do
        -- cheap pre-check before the exact distance (0.02 = 2% of the map)
        if math.abs(n.x - x) < 0.02 and math.abs(n.y - y) < 0.02 then
            local d = Distance(mapID, x, y, n.x, n.y)
            if d <= radius and (not bestD or d < bestD) then
                best, bestD = n, d
            end
        end
    end
    return best
end

-- Name of a node kind in our own language, if we harvested it ourselves
local function KnownName(id)
    if not nameCache then
        nameCache = {}
        for _, list in pairs(ns.db.nodes) do
            for _, n in ipairs(list) do
                if n.id and not n.source and not nameCache[n.id] then
                    nameCache[n.id] = n.name
                end
            end
        end
    end
    return nameCache[id]
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
-- One "kind" per material name and type: the same herb can have several
-- object IDs (e.g. two Earthroot objects), but players think in names
-- Same herb, same key in every client language: known objects use the
-- English name from the spawn data, others the name we saw
local function CanonicalName(id, name)
    local data = GathercraftQuestieData
    local kind = data and id and data.kinds[id]
    return (kind and kind[3]) or name
end
ns.CanonicalName = CanonicalName

local function KindKey(n)
    return (n.type or "?") .. ":" .. (CanonicalName(n.id, n.name) or n.id or "?"):lower()
end

-- Continent a zone belongs to (e.g. Mulgore -> Kalimdor), cached
local continentCache = {}
local CONTINENT_TYPE = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2

local function GetContinent(mapID)
    if continentCache[mapID] then
        return continentCache[mapID].id, continentCache[mapID].name
    end
    local id, name = 0, L["Other"]
    local info = C_Map.GetMapInfo(mapID)
    local guard = 0
    while info and guard < 10 do
        if info.mapType == CONTINENT_TYPE then
            id, name = info.mapID, info.name
            break
        end
        if not info.parentMapID or info.parentMapID == 0 then break end
        info = C_Map.GetMapInfo(info.parentMapID)
        guard = guard + 1
    end
    continentCache[mapID] = { id = id, name = name }
    return id, name
end

-- Selection from the zones window (/gcr zones). A node is used only if all
-- levels are checked: continent, material on the continent, zone, material in the zone.
local function IsNodeEnabled(n, mapID)
    local db = ns.db
    if db.disabledZones[mapID] then return false end
    local continent = GetContinent(mapID)
    if db.disabledContinents[continent] then return false end
    -- nothing unticked on material level: skip the string work (runs per node)
    -- (continent-wide material filters are gone: the old "None" button set
    -- them and nothing in the window could undo it)
    if not next(db.disabledKinds) then return true end
    if db.disabledKinds[mapID .. ":" .. KindKey(n)] then return false end
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

    -- Find the closest existing node of the same kind that this gather can belong to
    local best, bestDist
    for _, n in ipairs(list) do
        if SameKind(n, id, nameKey) then
            local d = Distance(mapID, x, y, n.x, n.y)
            if d <= MERGE_RADIUS then
                if spawn and n.lastSpawn == spawn then
                    -- Same spawn gathered again (e.g. a vein mined twice): don't count it again
                    n.last = time()
                    Debug(("Same spawn of %s gathered again, not counted."):format(n.name))
                    return n
                end
                -- A different spawn next to a node harvested minutes ago can't be its
                -- respawn: it is a neighbour node (e.g. two veins close together)
                local tooSoon = spawn and n.lastSpawn and IsOnCooldown(n)
                if not tooSoon and (not bestDist or d < bestDist) then
                    best, bestDist = n, d
                end
            end
        end
    end

    if best then
        local n = best
        n.x = (n.x * n.count + x) / (n.count + 1)
        n.y = (n.y * n.count + y) / (n.count + 1)
        n.count = n.count + 1
        n.last = time()
        n.id = n.id or id
        n.type = n.type or nodeType
        n.item = n.item or item
        n.lastSpawn = spawn or n.lastSpawn
        if spawn then n.source = nil end -- harvested ourselves: our own node now
        Debug(("Merged %s%s (seen %d times)."):format(n.name, TypeTag(n.type), n.count))
        NodesChanged("update", mapID, n)
        return n
    end

    local node = {
        id = id, name = name, type = nodeType, x = x, y = y,
        count = 1, last = time(), lastSpawn = spawn, item = item,
    }
    table.insert(list, node)
    Debug(("Added %s%s at %.1f / %.1f (%d nodes in %s)."):format(
        name, TypeTag(nodeType), x * 100, y * 100, #list, GetZoneName(mapID)))
    NodesChanged("add", mapID, node)
    return node
end

local function AddNode(name)
    local mapID, x, y = GetPlayerPos()
    if not mapID then
        Print(L["No position available here (instance?)."])
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
        Print(L["No position available here."])
        return
    end
    if #sorted == 0 then
        Print(L["No nodes stored in "] .. GetZoneName(mapID) .. ".")
        return
    end
    Print((L["%d nodes in %s:"]):format(#sorted, GetZoneName(mapID)))
    for i = 1, math.min(#sorted, LIST_MAX) do
        local e = sorted[i]
        local status = ""
        if IsOnCooldown(e.node) then
            status = (L["  |cff999999cooldown %ds|r"]):format(e.node.emptyUntil - time())
        end
        local idText = (ns.db.debug and e.node.id) and ("  |cff999999" .. e.node.id .. "|r") or ""
        print((L["  %s%s  %.1f / %.1f  %d yd  (x%d)%s%s"]):format(
            e.node.name, TypeTag(e.node.type), e.node.x * 100, e.node.y * 100,
            e.dist, e.node.count, status, idText))
    end
    if #sorted > LIST_MAX then
        print((L["  ... and %d more"]):format(#sorted - LIST_MAX))
    end
end

local function NextNode(filter)
    local sorted, mapID = GetSortedNodes(filter, true)
    if not sorted then
        Print(L["No position available here."])
        return
    end
    for _, e in ipairs(sorted) do
        if e.dist > NEXT_MIN_DIST and not IsOnCooldown(e.node) then
            if SetWaypoint(mapID, e.node.x, e.node.y) then
                Print((L["Next: %s, %d yd away."]):format(e.node.name, e.dist))
            end
            return
        end
    end
    Print(L["No further nodes found in this zone."])
end

local function DeleteNearest()
    local sorted, mapID = GetSortedNodes()
    if not sorted or #sorted == 0 then
        Print(L["Nothing to delete here."])
        return
    end
    local e = sorted[1]
    if e.dist > MERGE_RADIUS then
        Print((L["Nearest node (%s) is %d yd away. Stand closer to delete it."]):format(
            e.node.name, e.dist))
        return
    end
    table.remove(GetZoneNodes(mapID), e.index)
    Print(L["Deleted "] .. e.node.name .. ".")
    NodesChanged()
end

local function Stats()
    local zones, total, herbs, ores, chests = 0, 0, 0, 0, 0
    for _, list in pairs(ns.db.nodes) do
        if #list > 0 then
            zones = zones + 1
            total = total + #list
            for _, n in ipairs(list) do
                if n.type == "herb" then
                    herbs = herbs + 1
                elseif n.type == "ore" then
                    ores = ores + 1
                elseif n.type == "chest" then
                    chests = chests + 1
                end
            end
        end
    end
    Print((L["%d nodes in %d zones (%d herbs, %d ores, %d chests)."]):format(total, zones, herbs, ores, chests))
end

-- Farm runs and routes live in Route.lua

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

-- Adds the gathering spells' names in the client's language (once)
local localizedSpells = false
local function LearnSpellNames()
    if localizedSpells then return end
    localizedSpells = true
    for id, nodeType in pairs(GATHER_SPELL_IDS) do
        local name = SpellName(id)
        if name and name ~= "" and not GATHER_SPELLS[name:lower()] then GATHER_SPELLS[name:lower()] = nodeType end
    end
end

local function GetGatherType(spellID)
    LearnSpellNames()
    local name = SpellName(spellID)
    local nodeType = GATHER_SPELL_IDS[spellID]
        or (ns.db and ns.db.gatherSpells and ns.db.gatherSpells[spellID])
        or (name and GATHER_SPELLS[name:lower()])
    return nodeType, name
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

-- Every item in the loot window with its amount (for the gold value)
local function ReadLootItems()
    local items = {}
    local count = GetNumLootItems and GetNumLootItems() or 0
    for slot = 1, count do
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then
            local qty = GetLootSlotInfo and select(3, GetLootSlotInfo(slot))
            items[#items + 1] = { id = id, qty = tonumber(qty) or 1 }
        end
    end
    return items
end

local function TryRecord()
    local p = ns.pending
    if not p or not p.succeeded or p.done then return end
    if not p.lootSeen and GetTime() - p.succeededAt < LOOT_WAIT then
        return -- give the loot window a moment
    end
    p.done = true
    ns.pending = nil
    if p.guess or not p.type then return end -- not a gather after all

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
    node.emptyUntil = time() + (RESPAWN_BY_TYPE[node.type] or RESPAWN_TIME)

    if ns.OnHarvested then
        ns.OnHarvested(node)
    end
    if ns.SyncShare then
        ns.SyncShare(p.mapID, node)
    end
    if ns.OnGathered then
        ns.OnGathered(node, p)
    end
    for _, fn in ipairs(ns.gatherListeners) do
        fn(node, p)
    end
end

local function OnSpellcastSent(unit, target, castGUID, spellID)
    if unit ~= "player" then return end
    local nodeType, spellName = GetGatherType(spellID)
    Debug(("SENT spell=%s (%s) target=%s type=%s"):format(
        tostring(spellName), tostring(spellID), tostring(target), tostring(nodeType)))
    local name = (target and target ~= "") and target or GetTooltipTitle()
    -- A spell we don't know but cast on something with a name: maybe a
    -- gathering spell under another name or ID. The loot tells (see OnLoot).
    local guess = false
    if not nodeType then
        if not name or name == "" then return end
        guess = true
    end
    if nodeType == "chest" then
        -- opening a door or a quest object is not a chest; known chests
        -- (by object ID) are checked once the loot shows up
        if not IsChestName(name) then guess = true end
    end
    if not name or name == "" then
        name = (nodeType == "herb") and L["Unknown Herb"] or L["Unknown Ore"]
    end

    local mapID, x, y = GetPlayerPos()
    if not mapID then return end
    ns.pending = {
        castGUID = castGUID, name = name, type = nodeType, guess = guess, spellID = spellID,
        mapID = mapID, x = x, y = y, sentAt = GetTime(),
    }
    if ns.OnGatherStart and not guess then
        ns.OnGatherStart(ns.pending)
    end
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
    p.items = ReadLootItems()
    p.objectID = objectID
    p.spawn = spawn
    p.itemID = itemID
    if p.guess then
        -- only a known herb, ore or chest object makes a guess a gather
        local known = KnownObjectType(objectID)
        if not known then
            ns.pending = nil
            return
        end
        p.type, p.guess = known, false
        -- remember the spell, so next time it counts from the start
        if p.spellID and known ~= "chest" then
            ns.db.gatherSpells = ns.db.gatherSpells or {}
            ns.db.gatherSpells[p.spellID] = known
        end
        Debug(("GUESS confirmed: spell %s is %s"):format(tostring(p.spellID), known))
        if ns.OnGatherStart then ns.OnGatherStart(p) end
    end
    TryRecord()
end

---------------------------------------------------------------------------
-- Maintenance
---------------------------------------------------------------------------
local function WipeNodes(scope)
    if scope == "zone" then
        local mapID = GetPlayerPos()
        if not mapID then
            Print(L["No position available here."])
            return
        end
        local count = ns.db.nodes[mapID] and #ns.db.nodes[mapID] or 0
        ns.db.nodes[mapID] = nil
        if ns.StopRun then ns.StopRun(true) end
        Print((L["Deleted %d nodes in %s."]):format(count, GetZoneName(mapID)))
    elseif scope == "all" then
        wipe(ns.db.nodes)
        if ns.StopRun then ns.StopRun(true) end
        Print(L["All nodes deleted."])
    else
        Print(L["Usage: /gcr wipe zone  or  /gcr wipe all"])
        return
    end
    NodesChanged()
end

local function ToggleDebug()
    ns.db.debug = not ns.db.debug
    Print(L["Debug mode "] .. (ns.db.debug and L["|cff00ff00ON|r"] or L["|cffff0000OFF|r"]))
end

---------------------------------------------------------------------------
-- API check
---------------------------------------------------------------------------
local function check(label, value)
    print(("  %s: %s"):format(label, value and L["|cff00ff00yes|r"] or L["|cffff0000no|r"]))
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
            -- Take over the data of the old addon name (WoWFFarm) once
            if not GathercraftDB and WoWFFarmDB then
                GathercraftDB = WoWFFarmDB
                ns.migratedOld = true
            end
            WoWFFarmDB = nil
            GathercraftDB = GathercraftDB or {}
            GathercraftDB.version = GathercraftDB.version or 1
            GathercraftDB.nodes = GathercraftDB.nodes or {}
            GathercraftDB.disabledZones = GathercraftDB.disabledZones or {}
            GathercraftDB.disabledKinds = GathercraftDB.disabledKinds or {}
            GathercraftDB.disabledContinents = GathercraftDB.disabledContinents or {}
            GathercraftDB.disabledContinentKinds = GathercraftDB.disabledContinentKinds or {}
            -- hidden continent-wide material filters could hide every herb and ore
            GathercraftDB.disabledContinentKinds = {}
            if GathercraftDB.selectionVersion ~= 2 then
                -- Node kind selection is per zone now; old global entries are reset
                wipe(GathercraftDB.disabledKinds)
                GathercraftDB.selectionVersion = 2
            end
            ns.db = GathercraftDB
        end
    elseif event == "PLAYER_LOGIN" then
        Print(L["by pheenixlawl loaded. Type /gcr help for commands."])
        if ns.migratedOld then
            Print(L["Your WoWFFarm data was taken over. Welcome to Gathercraft!"])
        end
        if ns.db.debug then
            Print(L["Debug mode is ON (/gcr debug to turn off)."])
        end
        -- Resume a run that was active before reload/logout
        if ns.db.activeRun then
            C_Timer.After(2, function()
                if ns.db.activeRun then
                    ns.StartRun(ns.db.activeRun.filter, ns.db.activeRun.zone)
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
    Print(L["commands:"])
    print(L["  /gcr zones        - choose zones and node kinds"])
    print(L["  /gcr run [herb|ore|both|name] - farm run along the best route"])
    print(L["  /gcr route [herb|ore|both|name] - preview the route on the map"])
    print(L["  /gcr line         - show/hide the route line"])
    print(L["  /gcr skip         - current node is empty, go to next"])
    print(L["  /gcr stop         - stop the farm run"])
    print(L["  /gcr pins         - show/hide map and minimap pins"])
    print(L["  /gcr list [filter] - list nodes in this zone"])
    print(L["  /gcr next [filter] - waypoint to nearest node"])
    print(L["  /gcr add <name>   - store a node manually"])
    print(L["  /gcr del          - delete the node you stand at"])
    print(L["  /gcr wipe zone|all - delete stored nodes"])
    print(L["  /gcr stats        - node totals"])
    print(L["  /gcr clear        - remove waypoint"])
    print(L["  /gcr options      - options window (or shift-click the minimap button)"])
    print(L["  /gcr skills       - your gathering skills and what we learned"])
    print(L["  /gcr sync         - sync status and options"])
    print(L["  /gcr loadall      - load known spawn points for the whole continent"])
    print(L["  /gcr rare         - test the rare alert"])
    print(L["  /gcr debug        - toggle debug output"])
    print("  /gcr test         - API check")
    print(L["  /gcr scan         - scan auction house prices (at the auction house)"])
    print(L["  /gcr ahtest       - price sources and auction house check"])
end

SLASH_GATHERCRAFT1 = "/gcr"
SLASH_GATHERCRAFT2 = "/gathercraft"
SLASH_GATHERCRAFT3 = "/fg" -- old name, kept for now
SlashCmdList.GATHERCRAFT = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()

    if cmd == "" and ns.ToggleMain then
        ns.ToggleMain()
    elseif cmd == "add" then
        if rest == "" then
            Print(L["Usage: /gcr add <name>"])
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
            Print(L["Pins are not available (HereBeDragons missing?)."])
        end
    elseif cmd == "list" then
        ListNodes(rest)
    elseif cmd == "next" then
        NextNode(rest)
    elseif cmd == "run" then
        ns.StartRun(rest)
    elseif cmd == "route" then
        ns.PreviewRoute(rest)
    elseif cmd == "line" then
        ns.ToggleRouteLine()
    elseif cmd == "skip" then
        ns.SkipNode()
    elseif cmd == "stop" then
        ns.StopRun()
    elseif cmd == "del" then
        DeleteNearest()
    elseif cmd == "wipe" then
        WipeNodes(rest:lower())
    elseif cmd == "clear" then
        ns.StopRun(true)
        C_Map.ClearUserWaypoint()
        Print(L["Waypoint cleared."])
    elseif cmd == "pintest" then
        if ns.PinTest then ns.PinTest() end
    elseif cmd == "stats" then
        Stats()
    elseif cmd == "options" or cmd == "config" then
        if ns.ToggleOptions then
            ns.ToggleOptions()
        end
    elseif cmd == "skills" then
        if ns.ShowSkills then
            ns.ShowSkills()
        end
    elseif cmd == "sync" then
        if ns.SyncCommand then
            ns.SyncCommand(rest)
        end
    elseif cmd == "loadall" then
        if ns.LoadQuestieContinent then ns.LoadQuestieContinent() end
    elseif cmd == "rare" then
        if ns.TestRareAlert then ns.TestRareAlert() end
    elseif cmd == "debug" then
        ToggleDebug()
    elseif cmd == "test" then
        ApiTest()
    elseif cmd == "ahtest" or cmd == "prices" then
        if ns.PriceTest then ns.PriceTest() end
    elseif cmd == "recipetest" then
        if ns.RecipeTest then ns.RecipeTest() end
    elseif cmd == "trainertest" then
        if ns.TrainerTest then ns.TrainerTest() end
    elseif cmd == "crafttest" then
        if ns.CraftTest then ns.CraftTest() end
    elseif cmd == "scan" then
        if ns.StartScan then ns.StartScan() end
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
ns.GetContinent = GetContinent
ns.IsOnCooldown = IsOnCooldown
ns.IsNodeEnabled = IsNodeEnabled
ns.NotifyNodesChanged = NodesChanged
ns.FindNode = FindNode
ns.KnownName = KnownName
ns.SetWaypoint = SetWaypoint
