local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Questing mode (v0.1.19, Sven 08.11.2026): gather along the way while you
-- quest, without a farm run. Nodes near you that you can gather get the
-- gold ring of a run target on the minimap. Nothing else: no window, no
-- numbers, no route, no line.
--   * on / off: Ctrl + right-click on the minimap button, /gcr quest, a key
--     binding, Options > Map & minimap; kept over /reload and login
--   * a farm run or fishing turns it off (it says so); it stays off after
--   * it only shows: nothing moves, targets, gathers or changes a setting
---------------------------------------------------------------------------

local function On() return ns.db and ns.db.questMode and true or false end
ns.QuestModeOn = On

local listeners = {} -- called with the new state (the rings, Q2)
ns.questModeListeners = listeners

local function Changed()
    for _, fn in ipairs(listeners) do fn(On()) end
end

local OFF_REASON = {
    run = "Questing mode off: a farm run started.",
    fishing = "Questing mode off: you started fishing.",
}

-- on: true / false. why: nil (you switched it) or a key of OFF_REASON
local function SetQuestMode(on, why)
    if not ns.db then return end
    on = on and true or false
    if on == On() then return end
    ns.db.questMode = on or nil
    if on then
        ns.Print(L["Questing mode on – nearby nodes get a gold ring"])
    else
        ns.Print(L[OFF_REASON[why] or "Questing mode off"])
    end
    Changed()
end
ns.SetQuestMode = SetQuestMode

ns.ToggleQuestMode = function() SetQuestMode(not On()) end

-- a farm run or fishing starts (Route.lua, Fishing.lua)
ns.QuestModeOff = function(why)
    if On() then SetQuestMode(false, why) end
end

---------------------------------------------------------------------------
-- Which nodes get a ring (Q2): in the zone you are in, within the radius,
-- and only what this character can gather - the profession (what the map
-- filter knows) and enough skill (the trainer colour is not red; a bonus
-- counts). Chests only while chests are shown. Not a node just harvested or
-- found empty, nor one parked as always empty (the run's own rest times).
--
-- One ring per PLACE (T1 of 0.1.21; Sven, 10.11.2026, Hillsbrad 57.0 / 8.5):
-- the starter data has one entry per sort a spawn point can hold - Copper,
-- Tin and Silver Vein at the very same spot. Mining the tin put only the
-- tin entry to rest; copper and silver there could still be gathered, so
-- the ring stayed after the vein was gone. Now, for the rings only:
--   * entries of one kind (herb, ore, chest) no further apart than SAME_PLACE
--     are one place, and a place gets at most one ring
--   * while any entry of that kind there rests (harvested, found empty,
--     parked), the whole place gets none
--   * the ring sits on an entry this character can gather; with none, no ring
-- Nothing is written to a node for this: the recorder, routes, sync and
-- statistics see what they saw. Places are made up among the nodes within
-- the radius only.
---------------------------------------------------------------------------
-- Options > Map & minimap: 50, 75 (default) or 100 yards
local RADII = { 50, 75, 100 }
ns.QUEST_RADII = RADII
local RADIUS = 75
-- Q4: every TICK it looks whether anything changed: MOVE yards walked, a new
-- zone, a node changed, or REFRESH seconds gone (rest times run out, your
-- skill went up). Only then the zone's nodes are gone through again.
local TICK = 0.5
local MOVE = 5      -- yards
local REFRESH = 2   -- seconds
-- yards: entries of one kind this close are one place - the recorder's own
-- rule for "the same node" (MERGE_RADIUS in Core.lua)
local SAME_PLACE = 10

local function Radius()
    local r = ns.db and ns.db.questRadius
    for _, v in ipairs(RADII) do if v == r then return r end end
    return RADIUS
end
ns.QuestRadius = Radius

-- One look goes through every node of the zone - several hundred in a full
-- one. So that this does not hitch while you walk (Sven, 10.11.2026, T3 of
-- 0.1.21: reading your skill went through the whole skill list of the game
-- for EVERY node, also for the ones far away):
--   * what this character can gather - the professions, the skill for herbs
--     and for ore - is read ONCE per look and handed to the check of each
--     node (the pins do the same, see Skills.lua)
--   * what costs nothing is asked first: is it a kind that gets a ring at
--     all, is it within the radius. Only the few nodes near you are asked
--     whether they rest and whether your skill is enough.
-- Which nodes get a ring is exactly what it was.

-- What this character can gather, for one look: the professions now, the
-- skills when the first node of that kind asks for them
local function Abilities()
    local a = { skill = {} }
    if ns.GatherProfessions then
        a.asked = true
        a.herb, a.ore, a.known = ns.GatherProfessions()
    end
    return a
end

-- the skill for "herb" / "ore": { rank, effective }, or false when there is
-- none to go by (not learned, hidden)
local function SkillOf(a, kind)
    local s = a.skill[kind]
    if s == nil then
        s = false
        local rank, _, effective
        if ns.GetSkill then rank, _, effective = ns.GetSkill(kind) end
        if rank and not ns.AnySecret("questing mode", rank, effective) then s = { rank, effective } end
        a.skill[kind] = s
    end
    return s
end

-- the kind of a node the questing mode can light at all ("herb", "ore",
-- "chest" while chests are shown), else nil. Asks the game nothing.
local function Kind(n)
    if not (n and n.x and n.y) or n.pendingReport then return nil end
    local kind = n.type
    if kind == "chest" then
        if ns.db.chestsHidden then return nil end
        return kind
    end
    if kind == "herb" or kind == "ore" then return kind end
    return nil
end

-- just harvested, found empty, or parked as always empty
local function Resting(n)
    if ns.IsOnCooldown and ns.IsOnCooldown(n) then return true end
    if ns.IsParked and ns.IsParked(n) then return true end
    return false
end

-- can this character gather a node of its kind: the profession and enough
-- skill (a chest needs neither)
local function Able(n, a)
    local kind = n.type
    if kind == "chest" then return true end
    if a.asked and a.known and not ((kind == "herb" and a.herb) or (kind == "ore" and a.ore)) then return false end
    local s = SkillOf(a, kind)
    if not s then return false end
    local level = ns.SkillLevel(n.name, n.id, s[1], s[2])
    if level == "red" then return false end
    -- Options > Leveling, "Hide grey nodes": no more skill-ups, no ring either
    if level == "grey" and ns.db.hideGreyNodes then return false end
    return true
end

-- a: what Abilities() gave for this look (read here when it is left out)
local function CanGather(n, a)
    if not Kind(n) or Resting(n) then return false end
    return Able(n, a or Abilities())
end
ns.QuestCanGather = function(n) return CanGather(n) end

local look = {} -- the last look, for /gcr debug: ms, nodes, near, rings

-- the nodes to light now: mapID, set (node -> true), or nil
local function Pick()
    local mapID, px, py = ns.GetPlayerPos()
    if not (mapID and px and py) then return end
    local want, r = {}, Radius()
    -- how many yards the map is wide and high: asked once, and counted with
    -- as ns.Distance counts (the same numbers, node for node)
    local w, h = ns.Distance(mapID, 0, 0, 1, 0), ns.Distance(mapID, 0, 0, 0, 1)
    local a = Abilities()
    local nodes, near, rings = 0, 0, 0
    -- the places near you, in the order their first entry comes in the zone:
    -- { kind, x, y (yards from you), resting, node (the entry that carries
    -- the ring), d }
    local places = {}
    local same = SAME_PLACE * SAME_PLACE
    for _, n in ipairs(ns.db.nodes[mapID] or {}) do
        nodes = nodes + 1
        local kind = Kind(n)
        if kind then
            local dx, dy = (n.x - px) * w, (n.y - py) * h
            if dx <= r + 1 and dx >= -r - 1 and dy <= r + 1 and dy >= -r - 1 then
                -- in whole yards, as the game shows them (75.0000001 is 75)
                local d = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
                if d <= r then
                    near = near + 1
                    local place
                    for i = 1, #places do
                        local s = places[i]
                        if s.kind == kind and (s.x - dx) * (s.x - dx) + (s.y - dy) * (s.y - dy) <= same then
                            place = s
                            break
                        end
                    end
                    if not place then
                        place = { kind = kind, x = dx, y = dy }
                        places[#places + 1] = place
                    end
                    if Resting(n) then
                        place.resting = true -- the whole place: no ring
                    elseif not place.resting and not place.node and Able(n, a) then
                        place.node, place.d = n, d
                    end
                end
            end
        end
    end
    local nearest, nearestD
    for i = 1, #places do
        local s = places[i]
        if s.node and not s.resting then
            want[s.node] = true
            rings = rings + 1
            if not nearestD or s.d < nearestD then nearest, nearestD = s.node, s.d end
        end
    end
    look.nodes, look.near, look.rings = nodes, near, rings
    return mapID, want, nearest
end

-- Options: an arrow to the nearest ring (UI.lua draws it). Only which way
-- and how far: no route, no line. Off by default.
local arrowNode, arrowMap
ns.QuestArrowNode = function()
    if On() and ns.db.questArrow and arrowNode then return arrowNode, arrowMap end
end

local ticker
local picks = 0 -- how often the nodes were gone through (the tests count it)
local last = { at = -math.huge }
local dirty = true

-- /gcr debug: how long a look took, at most one line every SAY_EVERY seconds
local SAY_EVERY = 5
local saidAt = -math.huge

local function Update()
    if not (On() and ns.SetQuestRings) then return end
    picks = picks + 1
    local clock = debugprofilestop
    local began = clock and clock()
    local mapID, px, py = ns.GetPlayerPos()
    last.map, last.x, last.y, last.at = mapID, px, py, GetTime()
    dirty = false
    look.nodes, look.near, look.rings = 0, 0, 0
    local want, nearest
    mapID, want, nearest = Pick()
    arrowNode, arrowMap = nearest, mapID
    ns.SetQuestRings(mapID, want)
    if ns.UpdateArrow then ns.UpdateArrow() end
    look.ms = began and (clock() - began) or nil
    if ns.db.debug and ns.Debug and GetTime() - saidAt >= SAY_EVERY then
        saidAt = GetTime()
        ns.Debug(("QUEST look %s ms: %d nodes in the zone, %d near, %d rings"):format(
            look.ms and ("%.2f"):format(look.ms) or "?", look.nodes, look.near, look.rings))
    end
end
ns.UpdateQuestRings = Update
ns.QuestPicks = function() return picks end
ns.QuestLook = function() return look end -- (the tests)

-- every TICK while on: go through the nodes only when something changed
local function Tick()
    if not On() then return end
    if not dirty and GetTime() - last.at < REFRESH then
        local mapID, px, py = ns.GetPlayerPos()
        if mapID == last.map and px and last.x and ns.Distance(mapID, last.x, last.y, px, py) < MOVE then return end
    end
    Update()
end

-- the gathering help (Fishing.lua) follows it too
table.insert(listeners, function() if ns.UpdateGatherHelp then ns.UpdateGatherHelp("questing mode") end end)

-- the rings follow the state: a ticker only while it is on
table.insert(listeners, function(on)
    if ticker then ticker:Cancel() ticker = nil end
    if on then
        ticker = C_Timer.NewTicker(TICK, Tick)
        Update()
    else
        arrowNode, arrowMap = nil, nil
        if ns.SetQuestRings then ns.SetQuestRings(nil, nil) end
        if ns.UpdateArrow then ns.UpdateArrow() end
    end
end)

-- a node came, went or changed (harvested, found empty, options): look again
table.insert(ns.nodeListeners, function() dirty = true end)

-- Key binding (Bindings.xml)
function Gathercraft_QuestMode() ns.ToggleQuestMode() end

local loader = CreateFrame("Frame", "GathercraftQuestWatch")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    -- kept from the last session: the rings come back on their own
    if On() then Changed() end
end)
