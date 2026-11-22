-- Gathercraft: your own best runs per zone (0.2.3 P3, R8)
--
-- A short history of your farm runs - the last KEEP of every zone - and the best
-- ones derived from it. Kept on this computer only: Sync knows nothing of it, and
-- the run summary's "Share" line does not carry it.
--
-- Saved data, one account-wide key: GathercraftDB.runHistory[mapID] = { run, ... }
-- (the oldest first), every run { t = when it ended (time()), f = filter ("herb",
-- "ore", "both", "item:..." ...), g = route goal as the run resolved it ("skill",
-- "gold", "nodes"; "plan" for Farm for plan), k = the way it rode ("smart", "loop",
-- "plan"), a = seconds of riding, e = seconds from start to end, n = nodes,
-- v = copper from items with a known price, u = nodes with an item without a
-- price, s = skill-ups, c = the character (its GUID, ns.PlayerKey), h / o = its
-- Herbalism / Mining skill at the start }. Older versions do not know the key
-- and leave it alone.
--
-- Best runs are per character (a character on foot does not race one on an
-- epic mount), zone, filter and route goal: nodes per hour and gold per hour,
-- each the highest of the runs that count. A run counts from MIN_ACTIVE seconds
-- of riding. Per hour is per hour from start to end, as the run summary shows
-- it: a pause only makes a run slower, never better.
local _, ns = ...

local KEEP = 20          -- runs kept per zone; the oldest goes
local MIN_ACTIVE = 600   -- seconds of riding before a run counts for a best run
local GATHER_ACTIVE = 10 -- seconds after a gather that count as riding (you stand at the node)
local JUMP = 300         -- yards in a second: a teleport, a taxi - not riding

ns.RUN_HISTORY_KEEP, ns.RUN_HISTORY_MIN_ACTIVE = KEEP, MIN_ACTIVE -- (the tests)

---------------------------------------------------------------------------
-- The run that goes: how long you really rode, nodes without a price
---------------------------------------------------------------------------
local acc -- { run, active, unknown, lastGather, at, x, y, instance, herb, ore }

local function Fresh(run)
    local herb = ns.GetSkill and ns.GetSkill("herb")
    local ore = ns.GetSkill and ns.GetSkill("ore")
    if ns.AnySecret("skills", herb, ore) then herb, ore = nil, nil end
    acc = { run = run, active = 0, unknown = 0, lastGather = nil, herb = herb, ore = ore }
    return acc
end
local function Acc(run)
    if not acc or acc.run ~= run then return Fresh(run) end
    return acc
end

table.insert(ns.gatherListeners, function(_, p)
    local run = ns.run
    if not run then return end
    local a = Acc(run)
    a.lastGather = GetTime()
    -- (Prices.lua, before this: items of the node without a price)
    if p and (p.valueMissing or 0) > 0 then a.unknown = a.unknown + 1 end
end)

-- where you are, if it can be read (a hidden position is never compared)
local function Position()
    local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
    if not HBD then return end
    local x, y, instance = HBD:GetPlayerWorldPosition()
    if ns.AnySecret("position", x, y, instance) or type(x) ~= "number" or type(y) ~= "number" then return end
    return x, y, instance
end

-- Once a second while a run goes: a second of riding is one in which you moved
-- (at least a yard, no jump), or gathered a moment ago. Dead, a ghost, on a taxi
-- or where the position can't be read: not riding.
local function Tick()
    local run = ns.run
    if not run then return end
    local a = Acc(run)
    local now = GetTime()
    local dt = a.at and math.min(now - a.at, 2) or 0 -- (a hitch counts as at most 2 s)
    a.at = now
    local dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")
    local taxi = UnitOnTaxi and UnitOnTaxi("player")
    if ns.AnySecret("player", dead, taxi) then dead = true end
    local x, y, instance = Position()
    local moved = false
    if x and a.x and instance == a.instance then
        local d = math.sqrt((x - a.x) ^ 2 + (y - a.y) ^ 2)
        moved = d >= 1 and d <= JUMP * math.max(dt, 1)
    end
    a.x, a.y, a.instance = x, y, instance
    if dt > 0 and x and not dead and not taxi and (moved or (a.lastGather and now - a.lastGather <= GATHER_ACTIVE)) then
        a.active = a.active + dt
    end
end
ns.RunHistoryTick = Tick -- (the tests)
if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(1, Tick) end

-- the one zone a run farms: its own (a zone's run), else the zone of a route
-- that has only one; a run over several zones has none
local function RunZone(run)
    if run.zone then return run.zone end
    if run.zones == 1 then
        local list = run.path or run.loop
        local first = list and list[1]
        return first and first.mapID
    end
end

-- (UI.lua: what the run snapshot adds for the history)
ns.RunHistoryFill = function(s, run)
    if not (s and run) then return end
    local a = Acc(run)
    s.active, s.unknownPrice = a.active, a.unknown
    s.zone = RunZone(run)
    s.filter = run.filter or "all"
    s.goal = run.plan and "plan" or run.goal or "nodes"
    s.way = run.plan and "plan" or run.loopMode and "loop" or "smart"
    s.herbSkill, s.oreSkill = a.herb, a.ore
end

---------------------------------------------------------------------------
-- The history and the best runs
---------------------------------------------------------------------------
local function Rates(e)
    local hours = (e.e or 0) / 3600
    if hours <= 0 then return 0, 0 end
    return (e.n or 0) / hours, (e.v or 0) / hours
end

-- the best of the runs that count: nodes per hour and gold per hour (each its
-- own highest), for one character, filter and route goal
local function Best(list, char, filter, goal)
    local nodes, gold
    for _, e in ipairs(list or {}) do
        if e.c == char and e.f == filter and e.g == goal and (e.a or 0) >= MIN_ACTIVE then
            local n, g = Rates(e)
            if not nodes or n > nodes then nodes = n end
            if not gold or g > gold then gold = g end
        end
    end
    if nodes then return { nodes = nodes, gold = gold } end
end
ns.RunHistoryBest = function(mapID, char, filter, goal)
    local all = ns.db and ns.db.runHistory
    return Best(all and all[mapID], char, filter, goal)
end

-- Keeps the run that just ended (Route.lua, StopRun) and says how it stands:
-- { counted, first, newBest, nodes, gold (the best now, of the runs kept),
-- unknown (this run's nodes without a price), goal, minutes, keep }
-- or nil (no zone of its own, no time).
ns.RunHistoryAdd = function(s)
    if not (s and s.zone and (s.elapsed or 0) > 0 and ns.db) then return end
    local all = ns.db.runHistory
    if type(all) ~= "table" then
        all = {}
        ns.db.runHistory = all
    end
    local list = all[s.zone]
    if type(list) ~= "table" then
        list = {}
        all[s.zone] = list
    end
    local char = ns.PlayerKey and ns.PlayerKey() or "?"
    local e = {
        t = time(), f = s.filter, g = s.goal, k = s.way, a = math.floor((s.active or 0) + 0.5), e = math.floor(s.elapsed + 0.5),
        n = s.nodes or 0, v = math.floor((s.value or 0) + 0.5), u = s.unknownPrice or 0, s = s.skill or 0, c = char,
        h = s.herbSkill, o = s.oreSkill,
    }
    local before = Best(list, char, e.f, e.g)
    list[#list + 1] = e
    while #list > KEEP do table.remove(list, 1) end
    -- (0.2.3 P3-M1, Codex) the best shown is the best kept now, once the
    -- oldest went out - what RunHistoryBest says; a new best is one better
    -- than the best before this run, not one that is first only because the
    -- best run just went out
    local now = Best(list, char, e.f, e.g)
    local counted = e.a >= MIN_ACTIVE
    local n, g = Rates(e)
    local result = { counted = counted, unknown = e.u, goal = e.g, minutes = math.floor(MIN_ACTIVE / 60), keep = KEEP }
    if counted and not before then
        result.first = true
    elseif counted then
        result.newNodes, result.newGold = n > before.nodes, g > before.gold
        result.newBest = result.newNodes or result.newGold
    end
    if now then result.nodes, result.gold = now.nodes, now.gold end
    return result
end
