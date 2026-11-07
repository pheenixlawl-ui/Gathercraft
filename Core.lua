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
local SEEN_MERGE = 30     -- yards: a harvest this close to a node only seen on the minimap is that node ...
local SEEN_MERGE_MAX = 70 -- ... or further, when the guess was rough (minimap zoomed out): 2.5 x its error
-- (lookErr: how far off a single look at it could be, the worst of its looks;
-- the average is closer, but may still sit on one side of the real spot)
local function SeenMergeRadius(n)
    return math.max(SEEN_MERGE, math.min(SEEN_MERGE_MAX, 2 * (n.lookErr or n.seenErr or 24)))
end
local NEXT_MIN_DIST = 10  -- yards: /gcr next skips nodes you are standing on
local RESPAWN_TIME = 300  -- seconds a harvested node stays out of runs
local RESPAWN_BY_TYPE = { chest = 900 } -- chests take longer
local LOOT_WAIT = 1.5     -- seconds after a gather: first look whether its loot came
local IDENTITY_WAIT = 10  -- seconds after the cast: a gather with no name waits this long for its loot
                          -- (our own upper bound, not a rule of the game client)
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

-- The name of a known herb or vein (by object, else by the item it gave) in
-- the chosen language
local function KindNameFor(objectID, itemID)
    local data = GathercraftQuestieData
    if not data then return end
    local oid = objectID and ("o" .. objectID)
    local kind = oid and data.kinds[oid]
    if not kind and itemID then
        for id, k in pairs(data.kinds) do
            if k[2] == itemID and (k[1] == "h" or k[1] == "o") and (not kind or #k[3] < #kind[3]) then
                oid, kind = id, k -- the plain node, not a rare variant
            end
        end
    end
    if not kind then return end
    local lang = ns.NameLanguage and ns.NameLanguage() or GetLocale()
    local names = lang:sub(1, 2) ~= "en" and GathercraftNodeNames and GathercraftNodeNames[lang]
    return (names and names[tonumber(oid:sub(2))]) or kind[3]
end
ns.KindNameFor = KindNameFor

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

-- Finds the chat window named "Gathercraft" or creates it. A window of that
-- name can exist but be closed (closed tabs keep their name, and chat
-- settings can come from another client): then it is opened again.
local triedOpen = false
local function GetDebugFrame()
    for i = 1, NUM_CHAT_WINDOWS do
        local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
        local frame = _G["ChatFrame" .. i]
        if name == DEBUG_WINDOW and frame and (shown or docked or frame:IsShown()) then
            return frame
        end
    end
    -- open a tab (reuses a closed window, also our own old one); only once a
    -- session, so a full chat (no free window) doesn't try on every line
    if FCF_OpenNewWindow and not triedOpen then
        triedOpen = true
        local f = FCF_OpenNewWindow(DEBUG_WINDOW)
        if f then return f end
        for i = 1, NUM_CHAT_WINDOWS do
            if GetChatWindowInfo(i) == DEBUG_WINDOW and _G["ChatFrame" .. i] then return _G["ChatFrame" .. i] end
        end
    end
    return DEFAULT_CHAT_FRAME
end

local function Debug(text)
    if ns.db and ns.db.debug then
        GetDebugFrame():AddMessage("|cff999999Gathercraft debug|r: " .. text)
    end
end

-- The client hides values from addons in dungeons and combat ("secret
-- values"): comparing or reading one is an error. Whatever comes from an event,
-- a unit or a tooltip there goes through these two first. /gcr debug tells once
-- per place and session.
local function Compare(v) return v < (type(v) == "number" and 0 or "") end
local function IsSecret(v)
    if issecretvalue then return issecretvalue(v) end
    local kind = type(v)
    return kind ~= "nil" and kind ~= "boolean" and not pcall(Compare, v)
end
local toldSecret = {}
local function Skipped(where)
    if not where or toldSecret[where] or not (ns.db and ns.db.debug) then return end
    toldSecret[where] = true
    Debug("secret value skipped in " .. where)
end
-- v, or nil if it is secret
function ns.Readable(v, where)
    if IsSecret(v) then
        Skipped(where)
        return nil
    end
    return v
end
-- true if one of the values is secret
function ns.AnySecret(where, ...)
    for i = 1, select("#", ...) do
        if IsSecret((select(i, ...))) then
            Skipped(where)
            return true
        end
    end
    return false
end
local Readable, AnySecret = ns.Readable, ns.AnySecret

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
function ns.PlayerMap()
    return Readable(C_Map.GetBestMapForUnit("player"), "position")
end

-- capital cities belong to the zone around them (also Route.lua)
ns.CITY_ZONE = {
    [1453] = 1429, -- Stormwind City -> Elwynn Forest
    [1454] = 1411, -- Orgrimmar -> Durotar
    [1455] = 1426, -- Ironforge -> Dun Morogh
    [1456] = 1412, -- Thunder Bluff -> Mulgore
    [1457] = 1438, -- Darnassus -> Teldrassil
    [1458] = 1420, -- Undercity -> Tirisfal Glades
}

local function GetPlayerPos()
    local mapID = ns.PlayerMap()
    if not mapID then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if AnySecret("position", x, y) then return end
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

-- The nodes of a zone by kind id, built once and kept up to date by
-- NodesChanged ("add" appends, bigger changes drop it)
local function ZoneIndex(mapID)
    local list = ns.db.nodes[mapID]
    if not list then return end
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
    return byId
end

-- Fast lookup: a node of this kind near x/y (map coordinates) or nil.
-- Uses an index per zone and kind instead of scanning every node.
local function FindNode(mapID, id, x, y, radius)
    local byId = id and ZoneIndex(mapID)
    if not byId then return end
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

-- "Unknown Herb" / "Unknown Ore" in any language (a gather that had no name,
-- saved under the language of then): a placeholder, no name of the object
local placeholders
local function IsPlaceholder(name)
    if not placeholders then
        placeholders = { ["unknown herb"] = true, ["unknown ore"] = true }
        for _, t in pairs(ns.Locales or {}) do
            for _, key in ipairs({ "Unknown Herb", "Unknown Ore" }) do
                if type(t[key]) == "string" then placeholders[t[key]:lower()] = true end
            end
        end
    end
    return name ~= nil and placeholders[name:lower()] == true
end

-- Name of a node kind in our own language, if we harvested it ourselves.
-- A name that only came from the item (a node from sync, n.itemName) is no
-- name of the object, even once we harvested that node ourselves; neither
-- is a placeholder
local function KnownName(id)
    if not nameCache then
        nameCache = {}
        for _, list in pairs(ns.db.nodes) do
            for _, n in ipairs(list) do
                if n.id and not n.source and not n.itemName and not IsPlaceholder(n.name) and not nameCache[n.id] then
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
    local c = continentCache[mapID]
    if c then
        return c.id, c.id == 0 and L["Other"] or c.name -- "Other": in the language of now
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

-- Selection from the zones window (/gcr zones): what "Start run" farms (and
-- the map, only with the option "Hide zones and materials unticked ...").
-- A node is used only if all levels are checked: continent, zone, material in the zone.
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

-- canonKey: the kind's language independent name (CanonicalName), lower case
local function SameKind(n, id, nameKey, canonKey)
    -- a guess from the minimap got one of the kind's object IDs (Peacebloom
    -- has several): any object of that kind can be the harvest of it
    if n.seenOnly and canonKey then
        return (CanonicalName(n.id, n.name) or n.name):lower() == canonKey or n.name:lower() == nameKey
    end
    if id and n.id then
        return n.id == id
    end
    return n.name:lower() == nameKey
end

-- Tauren "Cultivation" (Forever) grows a copy of a herb right on top of the
-- one just picked; the copy is gone for good once picked. A copy = a Tauren
-- picks the same kind of herb again, from where they just stood (the cast
-- needs you right at the herb), a different spawn, within a minute.
local CULTIVATED_RANGE = 5      -- yards between the two picking spots
local CULTIVATED_WINDOW = 60    -- seconds
local lastPick = setmetatable({}, { __mode = "k" }) -- node -> { x, y, t, spawn } (this session)

local function IsTauren()
    if not UnitRace then return false end
    local _, raceFile = UnitRace("player")
    return raceFile == "Tauren"
end

local function CultivatedCopy(mapID, x, y, nodeType, id, nameKey, spawn)
    if not spawn or nodeType ~= "herb" or not IsTauren() then return end
    for n, lp in pairs(lastPick) do
        if lp.mapID == mapID and lp.spawn ~= spawn and time() - lp.t <= CULTIVATED_WINDOW
            and SameKind(n, id, nameKey) and Distance(mapID, x, y, lp.x, lp.y) <= CULTIVATED_RANGE then
            return n
        end
    end
end

-- Nodes whose lastSpawn was seen in this session. Forever keeps a spawn's ID
-- only for one session: an ID saved from an earlier one says nothing about
-- the spawn there now
local spawnThisSession = setmetatable({}, { __mode = "k" })

local function AddNodeAt(mapID, x, y, name, nodeType, id, spawn, item)
    local list = GetZoneNodes(mapID, true)
    local nameKey = name:lower()
    local canonKey = (CanonicalName(id, name) or name):lower()

    local copyOf = CultivatedCopy(mapID, x, y, nodeType, id, nameKey, spawn)
    if copyOf then
        Debug(("Cultivated copy of %s picked, not a new node."):format(copyOf.name))
        return copyOf, true
    end

    -- Find the closest existing node of the same kind that this gather can belong to
    local best, bestDist, bestResumed
    for _, n in ipairs(list) do
        if SameKind(n, id, nameKey, canonKey) then
            local d = n.seenOnly and ns.Yards(mapID, x, y, n.x, n.y) or Distance(mapID, x, y, n.x, n.y)
            -- only seen on the minimap so far: its position is a rough guess
            if d <= (n.seenOnly and SeenMergeRadius(n) or MERGE_RADIUS) then
                if spawn and n.lastSpawn == spawn then
                    -- Same spawn gathered again (e.g. a vein mined twice): don't count it again
                    n.last = time()
                    spawnThisSession[n] = true
                    Debug(("Same spawn of %s gathered again, not counted."):format(n.name))
                    return n, true
                end
                -- A different spawn next to a node harvested minutes ago can't be its
                -- respawn: it is a neighbour node (e.g. two veins close together).
                -- Not so with an ID from an earlier session: the spawn there,
                -- still resting, can have a new ID now. It is that same spawn.
                local tooSoon = spawn and n.lastSpawn and IsOnCooldown(n)
                local resumed = tooSoon and not spawnThisSession[n]
                if (resumed or not tooSoon) and (not bestDist or d < bestDist) then
                    best, bestDist, bestResumed = n, d, resumed
                end
            end
        end
    end

    if best and bestResumed then
        -- counted when it was gathered first; from now on known by its new ID
        best.lastSpawn, best.last = spawn, time()
        spawnThisSession[best] = true
        Debug(("Resting %s gathered again under a new spawn ID, not counted."):format(best.name))
        return best, true, true
    end

    if best then
        local n = best
        if n.seenOnly then
            -- harvested now: the real spot replaces the guess from the minimap
            if ns.db.debug then
                local east = ns.Yards(mapID, n.x, y, x, y) * (n.x > x and 1 or -1)
                local south = ns.Yards(mapID, x, n.y, x, y) * (n.y > y and 1 or -1)
                Debug(("SEEN guess of %s was %d yd off: %d yd %s, %d yd %s (%d looks)"):format(n.name,
                    ns.Yards(mapID, n.x, n.y, x, y), math.abs(east), east >= 0 and "east" or "west",
                    math.abs(south), south >= 0 and "south" or "north", n.seenLooks or 1))
            end
            n.x, n.y, n.count, n.seenOnly = x, y, 0, nil
            n.id = id or n.id -- the real object, not the one guessed from the name
        end
        n.x = (n.x * n.count + x) / (n.count + 1)
        n.y = (n.y * n.count + y) / (n.count + 1)
        n.count = n.count + 1
        n.last = time()
        n.id = n.id or id
        n.type = n.type or nodeType
        n.item = n.item or item
        -- harvested ourselves a node that came from sync: what we saw (the
        -- gathering spell's kind, the loot's item) beats what the report said
        if spawn and n.source == "sync" then
            n.type = nodeType or n.type
            n.item = item or n.item
        end
        n.lastSpawn = spawn or n.lastSpawn
        if spawn then
            spawnThisSession[n] = true
            n.source = nil -- harvested ourselves: our own node now
        end
        Debug(("Merged %s%s (seen %d times)."):format(n.name, TypeTag(n.type), n.count))
        NodesChanged("update", mapID, n)
        return n
    end

    local node = {
        id = id, name = name, type = nodeType, x = x, y = y,
        count = 1, last = time(), lastSpawn = spawn, item = item,
    }
    table.insert(list, node)
    if spawn then spawnThisSession[node] = true end
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
        return Readable(C_Spell.GetSpellName(spellID), "spell name")
    elseif GetSpellInfo then
        return Readable((GetSpellInfo(spellID)), "spell name")
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

-- The name of what the mouse points at in the world (the game's tooltip for
-- herbs, veins and chests). A tooltip of a button (our herbs/minerals switch,
-- an action bar) is no node name.
local function GetTooltipTitle()
    if GameTooltip and GameTooltip:IsShown() then
        local owner = GameTooltip:GetOwner()
        if owner and owner ~= UIParent and owner ~= WorldFrame then return end
        local line = _G.GameTooltipTextLeft1
        return line and line:GetText()
    end
end

-- Reads the loot source (game object ID + spawn UID) and the first item ID
-- Items herbs and veins give (Forever adds seeds and rare reagents like
-- Frilled Lichen to herbs: those are extras, not what the node is)
local nodeItems
local function IsNodeItem(id)
    if not nodeItems then
        nodeItems = {}
        local kinds = GathercraftQuestieData and GathercraftQuestieData.kinds or {}
        for _, k in pairs(kinds) do
            if (k[1] == "h" or k[1] == "o") and k[2] and k[2] > 0 then nodeItems[k[2]] = true end
        end
    end
    return nodeItems[id]
end

local function ReadLoot()
    local objectID, spawn, itemID, firstGUID
    local firstItem
    local count = Readable(GetNumLootItems and GetNumLootItems(), "loot") or 0
    for slot = 1, count do
        if GetLootSourceInfo and not objectID then
            local guid = Readable(GetLootSourceInfo(slot), "loot")
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
            local link = Readable(GetLootSlotLink(slot), "loot")
            local id = link and tonumber(link:match("item:(%d+)"))
            if id then
                firstItem = firstItem or id
                if IsNodeItem(id) then itemID = id end
            end
        end
    end
    -- the herb or ore itself; else (a new Forever node) the first item
    return objectID, spawn, itemID or firstItem, firstGUID, count
end

-- Every item in the loot window with its amount (for the gold value)
local function ReadLootItems()
    local items = {}
    local count = Readable(GetNumLootItems and GetNumLootItems(), "loot") or 0
    for slot = 1, count do
        local link = Readable(GetLootSlotLink and GetLootSlotLink(slot), "loot")
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then
            local qty = Readable(GetLootSlotInfo and select(3, GetLootSlotInfo(slot)), "loot")
            items[#items + 1] = { id = id, qty = tonumber(qty) or 1 }
        end
    end
    return items
end

-- A gather knows what it was: a name from the game (cast target or tooltip)
-- or its loot (object or item)
local function HasName(p)
    return p.name and p.name ~= L["Unknown Herb"] and p.name ~= L["Unknown Ore"]
end

-- The name our records give an object that the spawn data doesn't know (a
-- new Forever node such as Wilted Peacebloom): your own gathers first, else
-- any record of the zone (beta starter data, sync). nil: never seen.
-- Never a name that only came from the item: sync sends no object names, so
-- a node from sync is named after its loot (Peacebloom for a Wilted
-- Peacebloom) and would make our own gather of it look like another kind.
-- Sync nodes from before n.itemName existed are skipped as well, and so is a
-- placeholder ("Unknown Herb" of a gather that had no name).
-- Both lookups use indexes (KnownName's cache, the zone index of FindNode):
-- no walk over a zone's nodes per loot.
local function ObjectName(objectID, mapID)
    local oid = "o" .. objectID
    local known = KnownName(oid)
    if known then return known end
    local byId = mapID and ZoneIndex(mapID)
    for _, n in ipairs(byId and byId[oid] or {}) do
        if not n.itemName and n.source ~= "sync" and not IsPlaceholder(n.name) then return n.name end
    end
    return nil
end
ns.ObjectName = ObjectName -- for the tests (tools/smoke_test.lua)

-- Does this loot belong to this gather? Checked by kind (the kind names of
-- the spawn data, so two objects of the same herb both fit), not by one
-- object ID. A new Forever object goes by the name our records give it,
-- never by its item: Wilted Peacebloom is its own herb, even where its loot
-- holds a Peacebloom item. An object nobody has a name for can't be checked.
-- A guess (any spell cast on something with a name: a buff, an attack) only
-- fits the loot of a known herb, ore or chest object.
local function LootFits(p, objectID, itemID)
    if p.guess then return KnownObjectType(objectID) and true or false end
    if p.type == "chest" then return true end
    local objType = objectID and KnownObjectType(objectID)
    if objType and objType ~= p.type then return false end
    if not HasName(p) then return true end
    local name = p.name:lower()
    local data = GathercraftQuestieData
    local kind = objectID and data and data.kinds["o" .. objectID]
    if kind then
        return name == kind[3]:lower() or name == (KindNameFor(objectID) or ""):lower()
    end
    if objectID then
        local known = ObjectName(objectID, p.mapID)
        return not known or name == known:lower()
    end
    -- no object at all: the item's kind (in the game's language or English)
    if itemID and data then
        local fits, any = false, false
        for _, k in pairs(data.kinds) do
            if k[2] == itemID and (k[1] == "h" or k[1] == "o") then
                any = true
                if name == k[3]:lower() then fits = true end
            end
        end
        if any then return fits or name == (KindNameFor(nil, itemID) or ""):lower() end
    end
    return true
end

-- Gathers that succeeded but whose loot hadn't come when the next cast
-- started: they wait for their own loot (up to IDENTITY_WAIT). A loot goes
-- to the one gather it fits; if it fits several (the same herb twice, a vein
-- mined again), nobody can tell whose it is: all of them are dropped. A
-- spawn booked without its loot would let one vein count three times.
local awaiting = {}

-- Did the cast itself name this object? The strong proof for learning a spell:
-- its target (never a tooltip: the mouse can rest on a herb during any cast)
-- is the object's name, in English or the client's language.
local function TargetNamesObject(p, objectID)
    local kind = p.castTarget and GathercraftQuestieData and GathercraftQuestieData.kinds["o" .. objectID]
    if not kind then return false end
    local target = p.castTarget:lower()
    return target == kind[3]:lower() or target == (KindNameFor(objectID) or ""):lower()
end

-- p: this gather (default: the one waiting)
local function TryRecord(p)
    p = p or ns.pending
    if not p or not p.succeeded or p.done then return end
    if not p.lootSeen then
        -- one rule for every gather: it is booked only with its own loot
        -- (object, spawn, item). It waits for it up to IDENTITY_WAIT (our own
        -- bound); without it nothing is booked - a name alone has no spawn, and
        -- a vein mined three times would count three times
        if GetTime() - p.sentAt < IDENTITY_WAIT then
            if not p.waiting then
                p.waiting = true
                C_Timer.After(IDENTITY_WAIT - (GetTime() - p.sentAt) + 0.1, function() TryRecord(p) end)
            end
            return
        end
    end
    p.done = true
    if ns.pending == p then ns.pending = nil end
    for i = #awaiting, 1, -1 do
        if awaiting[i] == p then table.remove(awaiting, i) end
    end
    if p.guess or not p.type then return end -- not a gather after all
    local why = (p.lootAmbiguous and not p.lootSeen and "its loot can't be told from another gather's")
        or (p.lootConflict and not p.lootSeen and "only loot of another kind")
        or (not p.lootSeen and "no loot of its own came")
    if why then
        Debug(("DROPPED gather %s (%s): %s (%.1f s), nothing recorded"):format(tostring(p.castGUID), tostring(p.name),
            why, GetTime() - p.sentAt))
        -- it did succeed: the route must not call a spot of its type close by
        -- empty because of it (nothing is learned from it either way)
        if ns.OnGatherUncertain then ns.OnGatherUncertain(p) end
        return
    end

    local id
    if p.objectID then
        id = "o" .. p.objectID
    elseif p.itemID then
        id = "i" .. p.itemID
    end
    -- a known herb or vein: its own name (whatever a tooltip said). With no
    -- name from the game: a new Forever object goes by the name our records
    -- give it (never by its item: Wilted Peacebloom is no Peacebloom), and
    -- only loot without any object is named after its item
    local better = p.objectID and KnownObjectType(p.objectID) ~= "chest" and KindNameFor(p.objectID)
    if not better and not HasName(p) then
        if p.objectID then
            better = ObjectName(p.objectID, p.mapID)
        elseif p.itemID then
            better = KindNameFor(nil, p.itemID)
        end
    end
    if better then p.name = better end
    Debug(("RECORD name=%s type=%s id=%s spawn=%s item=%s"):format(
        p.name, p.type, tostring(id), tostring(p.spawn), tostring(p.itemID)))

    local node, again, resumed = AddNodeAt(p.mapID, p.x, p.y, p.name, p.type, id, p.spawn, p.itemID)
    if not node then return end
    node.emptyUntil = time() + (RESPAWN_BY_TYPE[node.type] or RESPAWN_TIME)
    if not again or resumed then
        lastPick[node] = { mapID = p.mapID, x = p.x, y = p.y, t = time(), spawn = p.spawn }
    end
    -- the same node a second time (vein mined again, cultivated herb): nothing
    -- new for routes or sync; skill stats still look at it (spawn-checked there)
    if again then
        if ns.OnGathered then ns.OnGathered(node, p) end
        -- the same spawn again (its loot window opened once more, a vein
        -- mined again): counted once already, so the run, session and value
        -- counts leave it out. A cultivated copy is another spawn and counts.
        if p.spawn and node.lastSpawn == p.spawn then return end
        -- a cultivated copy (another spawn on top of this node) counts once:
        -- its spawn is remembered with the pick it grew from (this session)
        local lp = p.spawn and lastPick[node]
        if lp then
            lp.copies = lp.copies or {}
            if lp.copies[p.spawn] then return end
            lp.copies[p.spawn] = true
        end
        for _, fn in ipairs(ns.gatherListeners) do fn(node, p) end
        return
    end

    if ns.OnHarvested then
        ns.OnHarvested(node, p.spawn, p) -- p: where the gather started
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
    -- a gather has a readable name: without one nothing is booked, not even a guess
    if AnySecret("UNIT_SPELLCAST_SENT", unit, target, castGUID, spellID) then return end
    if unit ~= "player" then return end
    local nodeType, spellName = GetGatherType(spellID)
    Debug(("SENT spell=%s (%s) target=%s type=%s"):format(
        tostring(spellName), tostring(spellID), tostring(target), tostring(nodeType)))
    local name = (target and target ~= "") and target or GetTooltipTitle()
    if AnySecret("the tooltip", name) then return end
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
    -- the gather before is not finished yet (its loot didn't come): it keeps
    -- waiting for its own loot (see awaiting); never booked without it
    local old = ns.pending
    if old and not old.done then
        if old.succeeded then
            old.awaiting = true
            awaiting[#awaiting + 1] = old
            TryRecord(old) -- schedules its end (or ends it, if its time is up)
        else
            old.done = true
            Debug(("DROPPED gather %s: a new cast started before it succeeded"):format(tostring(old.castGUID)))
        end
    end
    ns.pending = {
        castGUID = castGUID, name = name, type = nodeType, guess = guess, spellID = spellID,
        castTarget = (target and target ~= "") and target or nil,
        mapID = mapID, x = x, y = y, sentAt = GetTime(),
    }
    if ns.OnGatherStart and not guess then
        ns.OnGatherStart(ns.pending)
    end
end

local function OnSpellcastSucceeded(castGUID, spellID)
    if AnySecret("UNIT_SPELLCAST_SUCCEEDED", castGUID, spellID) then return end
    Debug(("SUCCEEDED spell=%s (%s)"):format(tostring(SpellName(spellID)), tostring(spellID)))
    local p = ns.pending
    if not p or p.castGUID ~= castGUID then return end
    p.succeeded = true
    p.succeededAt = GetTime()
    TryRecord(p)
    C_Timer.After(LOOT_WAIT + 0.1, function() TryRecord(p) end) -- this gather, even if a next one started
end

local function OnSpellcastFailed(castGUID)
    if AnySecret("UNIT_SPELLCAST_FAILED", castGUID) then return end
    local p = ns.pending
    if p and p.castGUID == castGUID then
        ns.pending = nil
        Debug("Gathering failed or interrupted, nothing recorded.")
    end
end

local function OnLoot()
    local objectID, spawn, itemID, guid, count = ReadLoot()
    Debug(("LOOT slots=%d source=%s item=%s"):format(count, tostring(guid), tostring(itemID)))

    -- a loot event that tells nothing (no object, no item): wait for the next
    if not objectID and not itemID then
        Debug("LOOT without source or item: waiting for the next loot event")
        return
    end
    -- whose loot is it? The current gather and the earlier ones still waiting
    -- for theirs, if it fits their kind
    local now, fits = GetTime(), {}
    local cur = ns.pending
    if cur and not cur.done and not cur.lootSeen and now - cur.sentAt <= IDENTITY_WAIT then
        if LootFits(cur, objectID, itemID) then
            fits[#fits + 1] = cur
        elseif not cur.guess then
            cur.lootConflict = true -- unless loot that fits still comes, nothing is recorded
            Debug(("LOOT of object %s does not fit the gather of %s (%s)"):format(
                tostring(objectID), tostring(cur.name), tostring(cur.castGUID)))
        end
    end
    for i = #awaiting, 1, -1 do
        local a = awaiting[i]
        if a.done or now - a.sentAt > IDENTITY_WAIT then
            table.remove(awaiting, i)
        elseif not a.lootSeen and LootFits(a, objectID, itemID) then
            fits[#fits + 1] = a
        end
    end
    if #fits == 0 then return end
    -- a real gather goes first: a guess next to it was no gather
    local real = {}
    for _, f in ipairs(fits) do
        if not f.guess then real[#real + 1] = f end
    end
    if #real > 0 and #real < #fits then
        for _, f in ipairs(fits) do
            if f.guess then
                f.done = true
                if ns.pending == f then ns.pending = nil end
                Debug(("LOOT of object %s goes to a real gather: spell %s was none"):format(tostring(objectID), tostring(f.spellID)))
            end
        end
        fits = real
    end
    if #fits > 1 then
        -- the same kind gathered twice (or a vein mined again) before the loot
        -- came: nobody can tell whose it is, so none of them is booked
        local casts = {}
        for _, f in ipairs(fits) do
            f.lootAmbiguous = true
            casts[#casts + 1] = tostring(f.castGUID)
        end
        Debug(("LOOT of object %s fits %d gathers (%s): can't tell whose, all dropped"):format(
            tostring(objectID), #fits, table.concat(casts, ", ")))
        return
    end
    local p = fits[1]
    if p.lootAmbiguous then return end -- once in doubt, it stays dropped
    p.lootSeen = true
    p.items = ReadLootItems()
    p.objectID = objectID
    p.spawn = spawn
    p.itemID = itemID
    if p.guess then
        -- only a known herb, ore or chest object makes a guess a gather
        local known = KnownObjectType(objectID)
        if not known then
            p.done = true
            if ns.pending == p then ns.pending = nil end
            return
        end
        p.type, p.guess = known, false
        -- remember the spell, so next time it counts from the start. Only with
        -- the cast's own target on this object: loot of a known object alone
        -- also comes after a buff or an attack. This loot itself still counts.
        if p.spellID and known ~= "chest" and not TargetNamesObject(p, objectID) then
            Debug(("GUESS not learned: spell %s target=%s object=%s"):format(
                tostring(p.spellID), tostring(p.castTarget), tostring(objectID)))
        else
            if p.spellID and known ~= "chest" then
                ns.db.gatherSpells = ns.db.gatherSpells or {}
                ns.db.gatherSpells[p.spellID] = known
            end
            Debug(("GUESS confirmed: spell %s is %s"):format(tostring(p.spellID), known))
        end
        if ns.OnGatherStart then ns.OnGatherStart(p) end
    end
    TryRecord(p)
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

-- The "Gathercraft" chat tab is made with the first debug line: write one
-- right away, so you see where the output goes (a fresh client has no tab yet)
local function ShowDebugTab()
    if ns.db.debug then
        triedOpen = false -- turned on by hand: try to open the tab again
        Debug("debug output goes to this tab")
    end
end

local function ToggleDebug()
    ns.db.debug = not ns.db.debug
    Print(L["Debug mode "] .. (ns.db.debug and L["|cff00ff00ON|r"] or L["|cffff0000OFF|r"]))
    ShowDebugTab()
    if ns.db.debug and ns.DebugGatherProfessions then ns.DebugGatherProfessions() end
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
    check("issecretvalue", issecretvalue)
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
            -- nothing saved yet: a new player (Welcome.lua shows the welcome)
            ns.freshInstall = GathercraftDB == nil
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
            if GathercraftDB.gatherSpellsVersion ~= 2 then
                -- v0.1.16: older versions could learn a buff or an attack as a
                -- gathering spell, and an entry doesn't say what proved it.
                -- All of them go once; a real one comes back with its next gather.
                GathercraftDB.gatherSpells = nil
                GathercraftDB.gatherSpellsVersion = 2
            end
            ns.db = GathercraftDB
        end
    elseif event == "PLAYER_LOGIN" then
        if ns.MoveCityGuesses then ns.MoveCityGuesses() end
        if ns.ConsolidateSeen then
            local n = 0
            for mapID in pairs(ns.db.nodes) do n = n + ns.ConsolidateSeen(mapID) end
            if n > 0 then
                Debug(("%d rough minimap guesses merged into nodes seen before"):format(n))
                NodesChanged()
            end
        end
        -- v0.1.13: herbs gathered while our herbs/minerals switch showed its
        -- tooltip were named after it: give them a real name
        local wrong = { ["find herbs / find minerals"] = true, [L["Find Herbs / Find Minerals"]:lower()] = true }
        local fixed = 0
        for _, list in pairs(ns.db.nodes) do
            for _, n in ipairs(list) do
                if n.name and wrong[n.name:lower()] then
                    local oid = n.id and tonumber(n.id:match("^o(%d+)$"))
                    n.name = KindNameFor(oid, n.item) or (n.type == "ore" and L["Unknown Ore"] or L["Unknown Herb"])
                    fixed = fixed + 1
                end
            end
        end
        for key in pairs(ns.db.kindStats or {}) do
            for w in pairs(wrong) do
                if key:lower():find(w, 1, true) then ns.db.kindStats[key] = nil end
            end
        end
        if fixed > 0 then
            Debug(("%d nodes named after the herbs/minerals switch renamed"):format(fixed))
            NodesChanged()
        end
        Print(L["by pheenixlawl loaded. Type /gcr help for commands."])
        if ns.migratedOld then
            Print(L["Your WoWFFarm data was taken over. Welcome to Gathercraft!"])
        end
        if ns.db.debug then
            Print(L["Debug mode is ON (/gcr debug to turn off)."])
            ShowDebugTab()
        end
        -- Resume a run that was active before reload/logout
        if ns.db.activeRun then
            C_Timer.After(2, function()
                if ns.db.activeRun then
                    ns.StartRun(ns.db.activeRun.filter, ns.db.activeRun.zone, ns.db.activeRun.quick)
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
    print(L["  /gcr unreachable  - can't get to the current node: leave it out for a while"])
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
    print(L["  /gcr plan [profession] - skill plan with material list"])
    print(L["  /gcr welcome      - show the welcome again"])
    print(L["  /gcr whatsnew     - what's new in this version"])
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
    elseif cmd == "unreachable" or cmd == "cantreach" then
        if ns.UnreachableNode then ns.UnreachableNode() end
    elseif cmd == "skip" then
        ns.SkipNode()
    elseif cmd == "stop" then
        -- no farm run, but fishing: that ends
        if not ns.run and ns.FishingSession and ns.FishingSession() then ns.StopFishing(true) else ns.StopRun() end
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
    elseif cmd == "mmtest" then
        ns.MinimapTest()
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
    elseif cmd == "plan" then
        if ns.ShowSkillPlan then ns.ShowSkillPlan(rest) end
    elseif cmd == "welcome" then
        if ns.ShowWelcome then ns.ShowWelcome() end
    elseif cmd == "whatsnew" or cmd == "new" then
        if ns.WhatsNew then ns.WhatsNew(true) end
    else
        Help()
    end
end

---------------------------------------------------------------------------
-- Seen on the minimap
--   Pointing at a tracked herb or vein on the minimap shows its name in a
--   tooltip. Only what the player points at himself is read (no scanning).
--   From the cursor position we work out where it is: the node is up right
--   now, and a spawn point we didn't know yet is learned without walking
--   there ("seenOnly": rough position until it is harvested).
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local SEEN_SNAP = 25      -- yards: a node of that kind this close is the one we see ...
local SEEN_SNAP_MAX = 60  -- ... up to this far when the minimap is zoomed out (2 x the error of the look)
local SEEN_BLIP_PX = 10   -- pixels: how far off the cursor can be while the tooltip of a blip shows (measured in Forever)
local SEEN_ERR_MIN = 4    -- yards: a position never counts as more exact than this
local SEEN_POLL = 0.1     -- seconds between looks at the tooltip
local SEEN_SAMPLE = 0.03  -- seconds between cursor samples while a blip's tooltip shows
local SEEN_HOVER_MAX = 0.6 -- a hover longer than this counts as one look, then a new one starts
local SEEN_AGAIN = 5      -- seconds before the same name at the same place counts again
local SEEN_LOOKS_MAX = 10 -- a rough position is the average of at most this many looks (newer ones count more after that)
local MINIMAP_DIAMETER = { -- yards across the minimap per zoom level (as HereBeDragons)
    indoor = { [0] = 300, 240, 180, 120, 80, 50 },
    outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 6, 200, 133 + 1 / 3 },
}

-- Yards per pixel of the minimap right now (nil when it can't be told)
function ns.MinimapYardsPerPixel()
    if not (Minimap and Minimap.GetWidth and Minimap.GetZoom) then return end
    local halfW = (Minimap:GetWidth() or 0) / 2
    if halfW <= 0 then return end
    local radius = C_Minimap and C_Minimap.GetViewRadius and C_Minimap.GetViewRadius()
    if not radius then
        local zoom = Minimap:GetZoom() or 0
        local indoors = (tonumber(GetCVar("minimapZoom")) or 0) ~= zoom and "indoor" or "outdoor"
        radius = (MINIMAP_DIAMETER[indoors][zoom] or 466) / 2
    end
    if ns.AnySecret("position", radius) or not radius or radius <= 0 then return end
    return radius / halfW
end

-- Real yards between two points of a zone (Distance() guesses the map size
-- on clients without C_Map.GetMapWorldSize)
local function Yards(mapID, x1, y1, x2, y2)
    if HBD and HBD.GetZoneDistance then
        local d = HBD:GetZoneDistance(mapID, x1, y1, mapID, x2, y2)
        if d then return d end
    end
    return Distance(mapID, x1, y1, x2, y2)
end
ns.Yards = Yards

-- name (lower case, client language) -> { id, type, item }: shipped kinds,
-- their names in this language, and kinds we met ourselves (new Forever ones)
local seenKinds
local function SeenKinds()
    if seenKinds then return seenKinds end
    seenKinds = {}
    local function add(name, id, t, item)
        if name and (t == "herb" or t == "ore") then
            local key = name:lower()
            seenKinds[key] = seenKinds[key] or {}
            for _, k in ipairs(seenKinds[key]) do if k.id == id then return end end
            table.insert(seenKinds[key], { id = id, type = t, item = item })
        end
    end
    for _, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do add(n.name, n.id, n.type, n.item) end
    end
    local kinds = GathercraftQuestieData and GathercraftQuestieData.kinds
    local names = GathercraftNodeNames and GathercraftNodeNames[GetLocale()]
    for id, k in pairs(kinds or {}) do
        local t = k[1] == "h" and "herb" or k[1] == "o" and "ore" or nil
        local num = tonumber(id:match("^o(%d+)$"))
        add(names and num and names[num] or k[3], id, t, k[2])
    end
    return seenKinds
end

local function CleanLine(text)
    text = text:gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Where on the map the cursor points (minimap -> zone coordinates)
local function CursorOnMap()
    if not (HBD and HBD.GetPlayerWorldPosition and HBD.GetZoneCoordinatesFromWorld) then return end
    local px, py, instance = HBD:GetPlayerWorldPosition()
    local mapID = ns.PlayerMap()
    if AnySecret("position", px, py, instance) or not (px and mapID) then return end
    -- from a city (Thunder Bluff on its mesa) the minimap shows the zone
    -- around it: herbs below were put on the small city map (v0.1.17)
    mapID = ns.CITY_ZONE[mapID] or mapID
    local scale = Minimap:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    if AnySecret("position", cx, cy) then return end
    local mx, my = Minimap:GetCenter()
    if not (cx and mx) then return end
    local ox, oy = cx / scale - mx, cy / scale - my
    local halfW, halfH = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
    if halfW <= 0 or halfH <= 0 then return end
    local radius, source
    local zoom = Minimap:GetZoom() or 0
    if C_Minimap and C_Minimap.GetViewRadius then
        radius, source = C_Minimap.GetViewRadius(), "api"
    else
        local indoors = (tonumber(GetCVar("minimapZoom")) or 0) ~= zoom and "indoor" or "outdoor"
        radius, source = (MINIMAP_DIAMETER[indoors][zoom] or 466) / 2, indoors
    end
    if not radius or radius <= 0 then return end
    -- the reverse of how HereBeDragons places minimap pins
    local xDist, yDist = ox / halfW * radius, -oy / halfH * radius
    if GetCVar("rotateMinimap") == "1" and GetPlayerFacing then
        local f = Readable(GetPlayerFacing(), "position")
        if not f then return end
        local s, c = math.sin(f), math.cos(f)
        xDist, yDist = xDist * c + yDist * s, -xDist * s + yDist * c
    end
    local x, y = HBD:GetZoneCoordinatesFromWorld(px - xDist, py - yDist, mapID)
    if not x or x < 0 or x > 1 or y < 0 or y > 1 then return end
    local ypp = radius / halfW -- yards per pixel
    return mapID, x, y, math.sqrt(xDist * xDist + yDist * yDist), ypp,
        ("zoom %d, %s, %.1f yd/px"):format(zoom, source, ypp)
end

-- How far off a look can be: a few pixels of the blip, in yards
local function LookError(ypp)
    return math.max(SEEN_ERR_MIN, (ypp or 3.3) * SEEN_BLIP_PX)
end

-- The node a look at the minimap means: the nearest of that kind within the
-- look's error. One that can be up beats a closer one harvested a moment ago
-- (the look is a few yards off, the neighbour may be the closer guess).
local function MatchSeen(mapID, x, y, name, err, candidates)
    candidates = candidates or SeenKinds()[name:lower()]
    if not candidates then return end
    local snap = math.max(SEEN_SNAP, math.min(SEEN_SNAP_MAX, 2 * err))
    local best, bestDist, cooled, cooledDist
    for _, n in ipairs(GetZoneNodes(mapID) or {}) do
        for _, k in ipairs(candidates) do
            if n.id == k.id or (not n.id and n.name:lower() == name:lower()) then
                local d = Yards(mapID, x, y, n.x, n.y)
                -- a rough guess of our own may be further off too
                local r = n.seenOnly and math.max(snap, math.min(SEEN_SNAP_MAX, 2 * (n.lookErr or n.seenErr or err))) or snap
                if d <= r then
                    if IsOnCooldown(n) then
                        if not cooledDist or d < cooledDist then cooled, cooledDist = n, d end
                    elseif not bestDist or d < bestDist then
                        best, bestDist = n, d
                    end
                end
                break
            end
        end
    end
    -- only a node on cooldown there: it came back sooner than we thought
    if not best then return cooled, cooledDist end
    return best, bestDist
end

local lastSeen = {} -- name -> { t, x, y }
local kindsBuiltAt = 0
local Calibrate -- below
local function OnSeen(mapID, x, y, name, err)
    err = err or 20
    local candidates = SeenKinds()[name:lower()]
    if not candidates and time() - kindsBuiltAt > 30 then
        -- maybe a kind we only met a moment ago: look again (not too often)
        seenKinds, kindsBuiltAt = nil, time()
        candidates = SeenKinds()[name:lower()]
    end
    if not candidates then return end
    local last = lastSeen[name]
    local snap = math.max(SEEN_SNAP, math.min(SEEN_SNAP_MAX, 2 * err))
    if last and time() - last.t < SEEN_AGAIN and Yards(mapID, x, y, last.x, last.y) < snap then return end
    lastSeen[name] = { t = time(), x = x, y = y }

    -- a node of that kind close by: that's the one, it is up right now
    local best, bestDist = MatchSeen(mapID, x, y, name, err, candidates)
    if best then
        -- seen with your own eyes: a parked node is real after all
        if ns.IsParked and ns.IsParked(best) and ns.SyncUnpark then ns.SyncUnpark(best, "seen on the minimap") end
        best.seenAt, best.upAt = time(), time()
        best.emptyUntil, best.emptyAt = nil, nil -- there it is: respawned
        if best.seenOnly then
            -- every look is a guess: the average gets closer. Looks with the
            -- minimap zoomed in are more exact and count more (1 / error²).
            local wNew = 1 / (err * err)
            local w = best.seenW or (1 / ((best.seenErr or err) ^ 2))
            w = math.min(w, SEEN_LOOKS_MAX * wNew) -- newer looks keep a say
            best.x = (best.x * w + x * wNew) / (w + wNew)
            best.y = (best.y * w + y * wNew) / (w + wNew)
            best.seenW = w + wNew
            best.seenErr = math.max(SEEN_ERR_MIN, 1 / math.sqrt(best.seenW))
            best.seenLooks = (best.seenLooks or 1) + 1
            best.lookErr = math.max(best.lookErr or best.seenErr or err, err)
        end
        Debug(("SEEN %s up (%d yd from the known spot%s)"):format(best.name, bestDist,
            best.seenOnly and (", position from %d looks, ~%d yd exact"):format(best.seenLooks, best.seenErr) or ""))
        NodesChanged("update", mapID, best)
        return
    end

    -- new spawn point: learned from the minimap
    local k = candidates[1]
    local list = GetZoneNodes(mapID, true)
    local node = {
        id = k.id, name = name, type = k.type, x = x, y = y, count = 1, last = time(),
        item = k.item, seenOnly = true, seenAt = time(), upAt = time(),
        seenErr = err, seenW = 1 / (err * err), lookErr = err,
    }
    table.insert(list, node)
    nameCache = nil
    Debug(("SEEN new %s at %.1f / %.1f (~%d yd exact)"):format(name, x * 100, y * 100, err))
    Print((L["%s learned from the minimap (position is a rough guess until you harvest it)."]):format(name))
    NodesChanged("add", mapID, node)
end

-- Up to 0.1.16 a look at the minimap from a city was put on the city map
-- (seen in Thunder Bluff: Mulgore herbs below the mesa). Such guesses (never
-- harvested) go to the zone around the city, at the same spot of the world;
-- the same position, only on the right map. Nothing is deleted. Once.
function ns.MoveCityGuesses()
    if ns.db.cityGuessesMoved or not (HBD and HBD.GetWorldCoordinatesFromZone and HBD.GetZoneCoordinatesFromWorld) then return 0 end
    local moved = 0
    for city, zone in pairs(ns.CITY_ZONE) do
        local list = ns.db.nodes[city]
        if list then
            for i = #list, 1, -1 do
                local n = list[i]
                if n.seenOnly and n.x and n.y then
                    local wx, wy = HBD:GetWorldCoordinatesFromZone(n.x, n.y, city)
                    local zx, zy
                    if wx and wy then zx, zy = HBD:GetZoneCoordinatesFromWorld(wx, wy, zone) end
                    if zx and zx >= 0 and zx <= 1 and zy >= 0 and zy <= 1 then
                        table.remove(list, i)
                        n.x, n.y, n.movedFrom = zx, zy, city
                        table.insert(GetZoneNodes(zone, true), n)
                        moved = moved + 1
                    end
                end
            end
            if #list == 0 then ns.db.nodes[city] = nil end
        end
    end
    ns.db.cityGuessesMoved = true
    if moved > 0 then
        Print((L["%d rough minimap guesses moved from a city map to the zone around it."]):format(moved))
        NodesChanged()
    end
    return moved
end

-- Rough guesses of the same kind that lie within their errors of each other
-- are one node seen several times (older versions made a new one each time
-- the guess was more than 25 yd off). Merged into their weighted average.
local function ConsolidateSeen(mapID)
    local list = GetZoneNodes(mapID)
    if not list then return 0 end
    local merged = 0
    local i = 1
    while i <= #list do
        local a = list[i]
        local removed = false
        if a.seenOnly then
            for j = #list, i + 1, -1 do
                local b = list[j]
                if b.seenOnly and SameKind(b, a.id, a.name:lower(), (CanonicalName(a.id, a.name) or a.name):lower()) then
                    local ea, eb = a.seenErr or 24, b.seenErr or 24
                    local la, lb = a.lookErr or math.max(ea, 24), b.lookErr or math.max(eb, 24)
                    local r = math.max(SEEN_SNAP, math.min(SEEN_SNAP_MAX, 2 * math.max(la, lb)))
                    if Yards(mapID, a.x, a.y, b.x, b.y) <= r then
                        local wa, wb = a.seenW or (1 / (ea * ea)), b.seenW or (1 / (eb * eb))
                        a.x = (a.x * wa + b.x * wb) / (wa + wb)
                        a.y = (a.y * wa + b.y * wb) / (wa + wb)
                        a.seenW = wa + wb
                        a.seenErr = math.max(SEEN_ERR_MIN, 1 / math.sqrt(a.seenW))
                        a.seenLooks = (a.seenLooks or 1) + (b.seenLooks or 1)
                        a.lookErr = math.max(la, lb)
                        a.seenAt = math.max(a.seenAt or 0, b.seenAt or 0)
                        a.upAt = math.max(a.upAt or 0, b.upAt or 0)
                        table.remove(list, j)
                        merged = merged + 1
                    end
                end
            end
        end
        if not removed then i = i + 1 end
    end
    return merged
end
ns.ConsolidateSeen = ConsolidateSeen

local function FrameName(f)
    if not f then return "none" end
    return (f.GetName and f:GetName()) or (f.GetDebugName and f:GetDebugName()) or "unnamed"
end

-- What is under the mouse (newer clients: a list, older ones: one frame)
local function MouseFocus()
    if GetMouseFoci then
        local foci = GetMouseFoci()
        return foci and foci[1]
    end
    return GetMouseFocus and GetMouseFocus()
end

-- The game's own minimap tooltip, not a pin of ours or of another addon:
-- the minimap itself is under the mouse (a pin would be), and the tooltip
-- belongs to the minimap or to the screen (WoW Forever: UIParent)
local function IsMinimapTooltip()
    local owner = GameTooltip:GetOwner()
    if owner and owner.node then return false end -- one of our pins
    local focus = MouseFocus()
    if focus ~= nil and focus ~= Minimap then return false end
    if owner == nil or owner == Minimap or owner == MinimapCluster or owner == MinimapBackdrop
        or owner == UIParent then
        return true
    end
    if MinimapCluster and owner == MinimapCluster.MinimapContainer then return true end
    local name = owner.GetName and owner:GetName()
    return name and name:match("^Minimap") and true or false
end

local function TooltipLines()
    local lines = {}
    for i = 1, Readable(GameTooltip:NumLines(), "the tooltip") or 0 do
        local fs = _G["GameTooltipTextLeft" .. i]
        local text = fs and fs:GetText()
        -- one line hidden: the tooltip says nothing we can trust
        if AnySecret("the tooltip", text) then return {} end
        if text then
            -- several blips under the cursor: one name per line ("|n" too)
            text = text:gsub("|n", "\n")
            for part in text:gmatch("[^\n]+") do
                part = CleanLine(part)
                if part ~= "" then lines[#lines + 1] = part end
            end
        end
    end
    return lines
end

-- Debug: pointing at one of OUR minimap pins whose real spot we know shows
-- how far the minimap maths is off (radius/zoom right in this client?)
local calibrated
Calibrate = function(pin)
    local owner = pin or GameTooltip:GetOwner()
    local n = owner and owner.node
    if not (n and owner.isMini and not n.seenOnly and not n.pendingReport) or calibrated == n then return end
    calibrated = n
    local mapID, x, y, dist, _, info = CursorOnMap()
    local pm, px, py = GetPlayerPos()
    if not (mapID and pm == mapID and owner.mapID == mapID) then return end
    local off = Yards(mapID, x, y, n.x, n.y)
    local real = Yards(mapID, px, py, n.x, n.y)
    local tip = ""
    local pcx, pcy = owner:GetCenter()
    local cx, cy = GetCursorPosition()
    local es = owner:GetEffectiveScale()
    if pcx and cx and es and es > 0 then
        local dx, dy = cx / es - pcx, cy / es - pcy
        tip = (" – cursor tip %d px %s, %d px %s of the pin's centre"):format(math.abs(dx), dx >= 0 and "right" or "left",
            math.abs(dy), dy >= 0 and "above" or "below")
    end
    Debug(("CALIB %s: guess %d yd off, distance %d yd vs real %d yd (x%.2f) – %s%s"):format(
        n.name, off, dist, real, real > 0 and dist / real or 0, info, tip))
end

local seenFrame = CreateFrame("Frame")
local seenElapsed, lastTooltip = 0, nil
-- While the tooltip of a blip shows, the cursor is somewhere on the blip:
-- all positions of one hover are averaged (nearer the middle of the blip than
-- the edge you came in from), then counted as one look.
local hover -- { text, names, mapID, x, y, n, ypp, age }
local function EndHover()
    local h = hover
    hover = nil
    if not h or h.n == 0 then return end
    local x, y = h.x / h.n, h.y / h.n
    for _, name in ipairs(h.names) do OnSeen(h.mapID, x, y, name, LookError(h.ypp)) end
end
local function Sample(h)
    local mapID, x, y, _, ypp = CursorOnMap()
    if not mapID or (h.mapID and mapID ~= h.mapID) then return end
    h.mapID, h.ypp = mapID, ypp
    h.x, h.y, h.n = h.x + x, h.y + y, h.n + 1
end
-- Our minimap pins let the mouse through to the game's blips (Pins.lua), and
-- the game rebuilds or hides GameTooltip over the minimap all the time. What
-- we know goes into a tooltip of our own: right below the game's tooltip when
-- it shows one, else next to the pin under the cursor.
local miniTip
local function MiniTip()
    if not miniTip then
        miniTip = CreateFrame("GameTooltip", "GathercraftMinimapTooltip", UIParent, "GameTooltipTemplate")
        miniTip:SetFrameStrata("TOOLTIP")
    end
    return miniTip
end
local function HideMiniTip()
    if miniTip and miniTip:IsShown() then miniTip:Hide() end
    if miniTip then miniTip.node, miniTip.under, miniTip.anchor = nil, nil, nil end
end
-- the node the game's tooltip names near the cursor, else our pin under it
local function MiniTipTarget(names)
    local mapID, x, y, _, ypp = CursorOnMap()
    if mapID and names then
        for _, name in ipairs(names) do
            local n = MatchSeen(mapID, x, y, name, LookError(ypp))
            if n then return n, nil, true end
        end
    end
    local pin = ns.MinimapPinUnderCursor and ns.MinimapPinUnderCursor()
    return pin and pin.node, pin, false
end
local function UpdateMiniTip()
    if not (ns.AddNodeTooltipLines and Minimap:IsMouseOver()) then return HideMiniTip() end
    local focus = MouseFocus()
    if focus ~= nil and focus ~= Minimap then return HideMiniTip() end
    local gameShows = GameTooltip:IsShown() and IsMinimapTooltip()
    local names = gameShows and TooltipLines() or nil
    if names and #names == 0 then names, gameShows = nil, false end
    local node, pin, named = MiniTipTarget(names)
    if not node then return HideMiniTip() end
    local anchor = gameShows and GameTooltip or pin
    if not anchor then return HideMiniTip() end
    local tip = MiniTip()
    if tip:IsShown() and tip.node == node and tip.anchor == anchor then return end
    tip:SetOwner(UIParent, "ANCHOR_NONE")
    tip:ClearAllPoints()
    if anchor == GameTooltip then
        tip:SetPoint("TOPLEFT", GameTooltip, "BOTTOMLEFT", 0, 2)
    else
        tip:SetPoint("BOTTOMLEFT", anchor, "TOPRIGHT", 2, 2)
    end
    -- right below the game's tooltip naming it: a short heading; below a
    -- tooltip about something else (a quest area): with its name
    ns.AddNodeTooltipLines(tip, node, gameShows and named)
    tip:Show()
    tip.node, tip.anchor = node, anchor
    if ns.db.debug and pin then Calibrate(pin) end
end
ns.UpdateMinimapTooltip = UpdateMiniTip -- tests

local tipElapsed = 0
seenFrame:SetScript("OnUpdate", function(_, elapsed)
    -- our tooltip keeps up on its own (also while a look is being measured)
    tipElapsed = tipElapsed + elapsed
    if tipElapsed >= SEEN_POLL and ns.db then
        tipElapsed = 0
        UpdateMiniTip()
    end
    seenElapsed = seenElapsed + elapsed
    if hover then
        hover.age = hover.age + elapsed
        if seenElapsed < SEEN_SAMPLE then return end
        seenElapsed = 0
        if ns.db.minimapLearnOff or not (GameTooltip:IsShown() and Minimap:IsMouseOver())
            or table.concat(TooltipLines(), "|") ~= hover.text or not IsMinimapTooltip() then
            EndHover()
            return
        end
        Sample(hover)
        if hover.age >= SEEN_HOVER_MAX then EndHover() end -- a long hover: count it, start again
        return
    end
    if seenElapsed < SEEN_POLL then return end
    seenElapsed = 0
    if not ns.db then return end
    if not (GameTooltip:IsShown() and Minimap:IsMouseOver()) then lastTooltip = nil return end
    local lines = TooltipLines()
    local mine = IsMinimapTooltip()
    if ns.db.minimapLearnOff then return end
    local joined = table.concat(lines, "|")
    if ns.db.debug and joined ~= lastTooltip and joined ~= "" then
        Debug(("minimap tooltip [%s%s]: %s"):format(FrameName(GameTooltip:GetOwner()), mine and "" or ", ignored", joined))
    end
    lastTooltip = joined
    if not mine then
        if ns.db.debug then Calibrate() end
        return
    end
    if #lines == 0 then return end
    hover = { text = joined, names = lines, x = 0, y = 0, n = 0, age = 0 }
    Sample(hover)
    if hover.n == 0 then hover = nil end
end)
-- new kinds (harvested, language switched): look the names up again
table.insert(ns.languageListeners or {}, function() seenKinds = nil end)
ns.ForgetSeenKinds = function() seenKinds = nil end
ns.SeenOnMinimap = OnSeen -- tests

-- /gcr mmtest: 20 seconds of what the minimap and its tooltip look like to us
local function MinimapTest()
    Print("minimap test: point at a tracked herb or vein on the minimap for 20 seconds")
    local last, ticks = nil, 0
    local ticker
    ticker = C_Timer.NewTicker(0.5, function()
        ticks = ticks + 1
        local foci = GetMouseFoci and GetMouseFoci() or (GetMouseFocus and { GetMouseFocus() }) or {}
        local names = {}
        for _, f in ipairs(foci) do names[#names + 1] = FrameName(f) end
        local tips = {}
        for _, tip in ipairs({ "GameTooltip", "ItemRefTooltip", "EmbeddedItemTooltip", "MinimapTooltip" }) do
            local t = _G[tip]
            if t and t.IsShown and t:IsShown() then tips[#tips + 1] = tip end
        end
        local mapID, x, y, dist, _, info = CursorOnMap()
        local line = ("over=%s tips=%s owner=%s mine=%s text=%s focus=%s pos=%s"):format(
            tostring(Minimap:IsMouseOver()), table.concat(tips, ","), FrameName(GameTooltip:GetOwner()),
            tostring(IsMinimapTooltip()), table.concat(TooltipLines(), "|"), table.concat(names, ","),
            mapID and ("%.1f/%.1f %dyd (%s)"):format(x * 100, y * 100, dist, info) or "-")
        if line ~= last then print("|cff33ff99GC|r " .. line) last = line end
        if ticks >= 40 then
            ticker:Cancel()
            Print("minimap test done")
        end
    end)
end
ns.MinimapTest = MinimapTest
ns.CursorOnMap = CursorOnMap

---------------------------------------------------------------------------
-- Shared with other files
---------------------------------------------------------------------------
ns.TYPE_COLORS = TYPE_COLORS
ns.Print = Print
ns.Debug = Debug
ns.ShowDebugTab = ShowDebugTab
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
