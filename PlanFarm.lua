local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- "Farm for plan": the shopping list of the skill plan on the map (0.2 B3)
--
-- Part 1 - which node kinds bring a material:
--
--   * base: the checked spawn data and nothing else. A node kind (herb or
--     ore) whose main item is the material. Only this decides what a plan
--     run routes to and what glows fully. What a node happened to give
--     you (n.item, the first loot the recorder saw) is NOT a base - not
--     even on a kind the spawn data knows. Chests have no item and are
--     never part of it.
--   * seen: your own gathers, counted by a listener that only reads. Per
--     node kind (its object ID): how many recorded gathers, and in how
--     many of them an item was in the loot. No quantities (the recorder
--     cannot tell a read 1 from an unreadable one), no chances. Shown
--     from 20 gathers of the kind and 5 with the item on - as "seen in 7
--     of 23 recorded gathers". A seen item glows weaker and is never
--     routed to, never counts for the end of a run.
--     The listener does not see every gather: the same spawn opened again
--     never reaches it, a second cultivated copy neither. So this is no
--     full yield statistic.
--   * never: sync data (it knows one item a node), lists from memory.
---------------------------------------------------------------------------
local SEEN_MIN_GATHERS = 20 -- recorded gathers of a kind before anything of it is shown
local SEEN_MIN_ITEM = 5     -- gathers with the item in the loot before it is shown
local SEEN_MAX_ITEMS = 50   -- items remembered per kind; the rarest makes room for a new one

---------------------------------------------------------------------------
-- base
---------------------------------------------------------------------------
local baseKinds -- itemID -> { kind key, ... } in a fixed order; built on first use (the data files load later)

local function Kinds()
    local data = GathercraftQuestieData
    return data and data.kinds
end

local function BuildBase()
    local kinds = Kinds()
    if not kinds then return {} end -- (not kept: the data may still come)
    local index = {}
    for key, kind in pairs(kinds) do
        if (kind[1] == "h" or kind[1] == "o") and type(kind[2]) == "number" and kind[2] > 0 then
            local list = index[kind[2]]
            if not list then
                list = {}
                index[kind[2]] = list
            end
            list[#list + 1] = key
        end
    end
    for _, list in pairs(index) do table.sort(list) end
    baseKinds = index
    return index
end

-- The main item of a node kind ("o1731" -> 2770), nil for a chest, a
-- fishing spot or a kind the spawn data does not know
ns.PlanBaseItem = function(kindKey)
    local kinds = Kinds()
    local kind = kinds and type(kindKey) == "string" and kinds[kindKey]
    if kind and (kind[1] == "h" or kind[1] == "o") and type(kind[2]) == "number" and kind[2] > 0 then return kind[2] end
    return nil
end

-- The node kinds whose main item this is: { "o1731", ... } or nil. Don't
-- change the table.
ns.PlanBaseKinds = function(itemID)
    return (baseKinds or BuildBase())[itemID]
end

-- Does this node bring one of the wanted materials (a set itemID -> true)?
-- Asked of the node's KIND; what the node itself says it gave is ignored.
ns.PlanNodeMatches = function(node, wanted)
    local item = node and ns.PlanBaseItem(node.id)
    return (item and wanted and wanted[item]) and true or false
end

---------------------------------------------------------------------------
-- seen
---------------------------------------------------------------------------
local seenRev = 0   -- counts up with every counted gather
local seenIndex, seenIndexRev, seenIndexTable -- itemID -> { { id, seen, n }, ... } over the threshold

local function CountGather(node, p)
    if type(node) ~= "table" or type(p) ~= "table" then return end
    if node.type ~= "herb" and node.type ~= "ore" then return end
    local key = node.id
    if type(key) ~= "string" or key == "" or ns.AnySecret("plan loot", key) then return end
    if type(p.items) ~= "table" or #p.items == 0 then return end -- loot nobody could read is no observation
    local main = ns.PlanBaseItem(key)
    local once = {}
    for _, it in ipairs(p.items) do
        local id = type(it) == "table" and it.id
        if type(id) == "number" and not ns.AnySecret("plan loot", id) and id > 0 and id ~= main then once[id] = true end
    end
    local db = ns.db
    if type(db) ~= "table" then return end
    if type(db.kindLoot) ~= "table" then db.kindLoot = {} end
    local entry = db.kindLoot[key]
    if type(entry) ~= "table" or type(entry.n) ~= "number" or type(entry.items) ~= "table" then
        entry = { n = 0, items = {} }
        db.kindLoot[key] = entry
    end
    entry.n = entry.n + 1
    local items = entry.items
    for id in pairs(once) do
        if items[id] then
            items[id] = items[id] + 1
        else
            local count, rarest, rarestCount = 0, nil, nil
            for other, c in pairs(items) do
                count = count + 1
                if not rarest or c < rarestCount or (c == rarestCount and other > rarest) then rarest, rarestCount = other, c end
            end
            if count >= SEEN_MAX_ITEMS then items[rarest] = nil end
            items[id] = 1
        end
    end
    seenRev = seenRev + 1
end

-- The listener: only reads the node and the gather, and keeps its own
-- errors to itself (the listeners are called one after the other without a
-- pcall - an error here must not stop the others)
table.insert(ns.gatherListeners, function(node, p)
    local ok, err = pcall(CountGather, node, p)
    if not ok and ns.Debug then ns.Debug("PLAN loot listener: " .. tostring(err)) end
end)

-- The node kinds this item was seen at often enough:
-- { { id = "o1731", seen = 7, n = 23 }, ... } most gathers with it first,
-- or nil. Never a base, never routed to. Don't change the tables.
ns.PlanSeen = function(itemID)
    local loot = ns.db and ns.db.kindLoot
    if type(loot) ~= "table" then return nil end
    if seenIndexRev ~= seenRev or seenIndexTable ~= loot then
        local index = {}
        for key, entry in pairs(loot) do
            if type(entry) == "table" and type(entry.n) == "number" and entry.n >= SEEN_MIN_GATHERS and type(entry.items) == "table" then
                for id, c in pairs(entry.items) do
                    if type(c) == "number" and c >= SEEN_MIN_ITEM then
                        local list = index[id]
                        if not list then
                            list = {}
                            index[id] = list
                        end
                        list[#list + 1] = { id = key, seen = c, n = entry.n }
                    end
                end
            end
        end
        for _, list in pairs(index) do
            table.sort(list, function(a, b)
                if a.seen ~= b.seen then return a.seen > b.seen end
                return a.id < b.id
            end)
        end
        seenIndex, seenIndexRev, seenIndexTable = index, seenRev, loot
    end
    return seenIndex[itemID]
end

-- 20, 5, 50: the thresholds, for texts and tests
ns.PlanSeenLimits = function() return SEEN_MIN_GATHERS, SEEN_MIN_ITEM, SEEN_MAX_ITEMS end
ns.PlanSeenRev = function() return seenRev end
