-- Route simulator: plays a farm run in one zone with the real addon code
-- (Route.lua, Core.lua, ...) inside the mini WoW of tools/smoke_test.lua, on
-- the real known spawn points, and measures what a player would get.
--
-- Usage:
--   luajit tools/route_sim.lua <Gathercraft folder> [options]
-- Options (all optional):
--   zone=1412        map ID (1412 Mulgore, 1411 Durotar, 1413 Barrens, 1438 Teldrassil, ...)
--   mode=herb        herb | ore | both
--   minutes=60       length of the run
--   speed=11.2       yards per second (7 = running, 11.2 = 60% mount, 14 = 100% mount)
--   active=0.35      share of the spawn points that have a node at a time
--   respawn=600      seconds until a gathered node grows again (somewhere of its kind)
--   see=40           yards: a node in front of you is visible from here
--   track=0          yards: minimap tracking (Find Herbs / Minerals); you ride to nodes it shows
--   arrive=25        the addon's "Next node at" option
--   seed=1           random seed (same seed = same world)
--   runs=1           repeat with seeds seed .. seed+runs-1 and average
--   dead=0           share of the known spawn points that never have a node (old data, changed zones)
--   skew=0           uneven spawn points: 0 = all alike, 1 = some points get nodes far more often
--   warm=0           minutes farmed before measuring (the addon has learned its spawn points)
--   skill=300        herbalism and mining skill at the start (goes up while gathering, classic rules)
--   goal=auto        the addon's route goal: auto | skill | gold | nodes
--   loop=0           1 = route type Loop (a fixed round, like farming guides)
--   tune=a:1,b:2     override ns.RouteTune values (spawn point learning), e.g. tune=prune:0,learn:0
--   oracle=1         ignore the addon, always ride to the nearest node that is up
--                    (nobody can know that: the best any route could ever do)
--
-- Model: every spawn point of a kind (e.g. Peacebloom) can hold a node; about
-- `active` of them do at any time. A gathered node comes back after `respawn`
-- seconds at a random free spawn point of the same kind (that's how Classic
-- spreads nodes). You ride straight lines (no mountains, no mobs), gather
-- every node you see within `see` yards, 5 seconds per node. Gold uses the
-- rough prices below (the addon gets them too, as if you had scanned).

local ROOT = arg[1] or "."
local opts = {
    zone = 1412, mode = "herb", minutes = 60, speed = 11.2, active = 0.35, respawn = 600,
    see = 40, track = 0, arrive = 25, seed = 1, runs = 1, oracle = 0, tune = "",
    dead = 0, skew = 0, warm = 0, skill = 300, goal = "auto", loop = 0,
}
for i = 2, #arg do
    local k, v = arg[i]:match("^(%w+)=(.+)$")
    if k and opts[k] ~= nil then opts[k] = tonumber(v) or v end
end

local GATHER_TIME = 5
local DT = 0.5
-- Zone sizes in yards (Classic maps), so distances are real
local SIZES = {
    [1411] = { 5287, 3525 }, [1412] = { 5137, 3425 }, [1413] = { 10133, 6756 }, [1416] = { 2800, 1866 },
    [1417] = { 3600, 2400 }, [1418] = { 2487, 1658 }, [1419] = { 3350, 2233 }, [1420] = { 6879, 4587 },
    [1421] = { 4200, 2800 }, [1422] = { 4300, 2866 }, [1423] = { 4031, 2687 }, [1424] = { 4850, 3233 },
    [1425] = { 3850, 2566 }, [1426] = { 7500, 5000 }, [1427] = { 2231, 1487 }, [1428] = { 3152, 2100 },
    [1429] = { 4925, 3283 }, [1430] = { 2500, 1666 }, [1431] = { 2700, 1800 }, [1432] = { 2758, 1839 },
    [1433] = { 2170, 1447 }, [1434] = { 6381, 4254 }, [1435] = { 2293, 1529 }, [1436] = { 7000, 4667 },
    [1437] = { 4135, 2756 }, [1438] = { 5091, 3393 }, [1439] = { 6550, 4367 }, [1440] = { 5767, 3844 },
    [1441] = { 4400, 2933 }, [1442] = { 4883, 3255 }, [1443] = { 4496, 2998 }, [1444] = { 6950, 4633 },
    [1445] = { 5250, 3500 }, [1446] = { 6900, 4600 }, [1447] = { 5070, 3380 }, [1448] = { 5750, 3833 },
    [1449] = { 3700, 2466 }, [1450] = { 2308, 1538 }, [1451] = { 3483, 2322 }, [1452] = { 7100, 4733 },
}
local function Size(zone) local s = SIZES[zone] or { 5000, 3333 } return s[1], s[2] end
local function OffsetX(zone) return (zone - 1400) * 12000 end -- zones side by side, never overlapping
local SPELL = { herb = 2366, ore = 2575 }
-- rough auction prices in copper per node (2 items), only for the simulation
local PRICES = {
    ["Peacebloom"] = 800, ["Silverleaf"] = 600, ["Earthroot"] = 1600, ["Mageroyal"] = 3000,
    ["Briarthorn"] = 5000, ["Stranglekelp"] = 3000, ["Bruiseweed"] = 8000, ["Wild Steelbloom"] = 6000,
    ["Grave Moss"] = 6000, ["Kingsblood"] = 8000, ["Liferoot"] = 10000, ["Fadeleaf"] = 8000,
    ["Goldthorn"] = 10000, ["Khadgar's Whisker"] = 12000, ["Copper Vein"] = 3000, ["Tin Vein"] = 6000,
    ["Silver Vein"] = 15000, ["Iron Deposit"] = 10000, ["Gold Vein"] = 30000,
    ["Incendicite Mineral Vein"] = 2000, ["Lesser Bloodstone Deposit"] = 3000,
}
local out = io.write

local function RunOnce(seed)
    GathercraftDB, WoWFFarmDB = nil, nil -- every run starts with fresh saved data
    HARNESS_ONLY = true
    arg = { ROOT }
    local h = dofile(ROOT .. "/tools/smoke_test.lua")
    local ns, player = h.ns, h.player
    math.randomseed(seed)
    local WORLD_W, WORLD_H = Size(opts.zone)
    -- the mini WoW's map with real zone sizes (the addon plans with these)
    local HBD = LibStub("HereBeDragons-2.0")
    HBD.GetWorldCoordinatesFromZone = function(_, x, y, map)
        local w, hh = Size(map)
        return x * w + OffsetX(map), y * hh, 1
    end
    HBD.GetPlayerWorldPosition = function()
        local w, hh = Size(player.map)
        return player.x * w + OffsetX(player.map), player.y * hh, 1
    end

    -- a character that can gather everything here
    h.profs[1][2], h.profs[1][3] = opts.skill, 300
    h.profs[2][2], h.profs[2][3] = opts.skill, 300
    h.fire("ADDON_LOADED", "Gathercraft")
    player.map, player.x, player.y = opts.zone, 0.5, 0.5
    h.fire("PLAYER_LOGIN")
    h.fire("PLAYER_ENTERING_WORLD")
    h.advance(5)
    ns.db.arriveDist = opts.arrive
    -- plans are cut off by real time in the game; here they always finish,
    -- so the same seed gives the same result however busy the computer is
    debugprofilestop = function() return 0 end
    ns.db.routeGoal = opts.goal
    ns.db.routeMode = opts.loop == 1 and "loop" or nil
    local GetPrice = ns.GetPrice
    ns.GetPrice = function(itemID)
        for _, kind in pairs(GathercraftQuestieData.kinds) do
            if kind[2] == itemID and PRICES[kind[3]] then return PRICES[kind[3]] / 2, "scan" end
        end
        return GetPrice(itemID)
    end
    for k, v in tostring(opts.tune):gmatch("(%w+):([%w%.%-]+)") do
        assert(ns.RouteTune[k] ~= nil, "unknown tune value " .. k)
        if type(ns.RouteTune[k]) == "boolean" then ns.RouteTune[k] = v ~= "0" and v ~= "false"
        else ns.RouteTune[k] = tonumber(v) end
    end
    ns.db.debug = false
    -- count every arrival at a spawn point that turned out empty
    local emptyCount = 0
    local Debug = ns.Debug
    ns.Debug = function(msg, ...)
        if type(msg) == "string" and msg:find("was empty", 1, true) then emptyCount = emptyCount + 1 end
        return Debug(msg, ...)
    end

    -- the world: spawn points of this zone, grouped by kind
    local data = GathercraftQuestieData
    local packed = data.zones[opts.zone]
    assert(packed, "no known spawn points for zone " .. tostring(opts.zone))
    local TYPES = { h = "herb", o = "ore" }
    local function oidOf(id) return "o" .. id end
    local points, byKind = {}, {}
    for id, xs, ys in packed:gmatch("(%d+),(%d+),(%d+)") do
        local kind = data.kinds["o" .. id]
        local t = kind and TYPES[kind[1]]
        if t and (opts.mode == "both" or opts.mode == t) then
            local p = { id = tonumber(id), type = t, item = kind[2], x = tonumber(xs) / 10000, y = tonumber(ys) / 10000 }
            p.wx, p.wy = p.x * WORLD_W + OffsetX(opts.zone), p.y * WORLD_H
            p.req = ns.RequiredSkill(oidOf(id), kind[3])
            points[#points + 1] = p
            byKind[id] = byKind[id] or {}
            table.insert(byKind[id], p)
        end
    end
    assert(#points > 0, "no " .. opts.mode .. " spawn points in zone " .. opts.zone)
    -- how often each spawn point gets a node (dead points never)
    local function Normal()
        return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
    end
    for _, p in ipairs(points) do
        p.weight = math.random() < opts.dead and 0 or math.exp(opts.skew * Normal())
    end
    local function PickFree(list)
        local total = 0
        for _, p in ipairs(list) do if not p.up then total = total + p.weight end end
        if total <= 0 then return end
        local r = math.random() * total
        for _, p in ipairs(list) do
            if not p.up then
                r = r - p.weight
                if r <= 0 then return p end
            end
        end
    end
    -- which spawn points hold a node right now
    for _, list in pairs(byKind) do
        local live = 0
        for _, p in ipairs(list) do if p.weight > 0 then live = live + 1 end end
        local want = math.floor(#list * opts.active + 0.5)
        if live > 0 then want = math.max(1, math.min(want, live)) end
        for _ = 1, want do
            local p = PickFree(list)
            if p then p.up = true end
        end
    end
    local respawns = {} -- { at, kind }

    local function Respawn(now)
        for i = #respawns, 1, -1 do
            local r = respawns[i]
            if now >= r.at then
                table.remove(respawns, i)
                local p = PickFree(byKind[r.kind])
                if p then p.up = true end
            end
        end
    end

    local spawnSeq = 0
    local skillUps, gold = 0, 0
    local function Gather(p, now)
        spawnSeq = spawnSeq + 1
        local kindName = data.kinds["o" .. p.id][3]
        local prof = h.profs[p.type == "herb" and 1 or 2]
        local req = ns.RequiredSkill("o" .. p.id, kindName)
        local d = prof[2] - req
        local chance = d < 25 and 1 or d < 50 and 0.75 or d < 100 and 0.25 or 0
        if prof[2] < 300 and math.random() < chance then
            prof[2] = prof[2] + 1
            skillUps = skillUps + 1
        end
        gold = gold + (PRICES[kindName] or 1000)
        player.x, player.y = p.x, p.y
        local cast = "simcast" .. spawnSeq
        h.fire("UNIT_SPELLCAST_SENT", "player", data.kinds["o" .. p.id][3], cast, SPELL[p.type])
        h.fire("UNIT_SPELLCAST_SUCCEEDED", "player", cast, SPELL[p.type])
        h.setLoot({ { guid = ("GameObject-0-1-1-1-%d-SIM%06d"):format(p.id, spawnSeq), item = p.item, qty = 2 } })
        h.fire("LOOT_READY")
        h.setLoot({})
        p.up = false
        respawns[#respawns + 1] = { at = now + opts.respawn, kind = tostring(p.id) }
    end

    -- ride
    local stats = { gathered = 0, distance = 0, idle = 0, arrivals = 0, emptyArrivals = 0, detours = 0 }
    local lastTarget
    ns.StartRun(opts.mode, opts.zone)
    h.advance(1)
    local start = h.now() + opts.warm * 60
    local stop = start + opts.minutes * 60
    local busyUntil = 0
    local measuring = opts.warm <= 0
    while h.now() < stop do
        local now = h.now()
        if not measuring and now >= start then
            measuring = true
            for k in pairs(stats) do stats[k] = 0 end
            emptyCount, skillUps, gold = 0, 0, 0
        end
        Respawn(now)
        if now >= busyUntil then
            local px, py = player.x * WORLD_W + OffsetX(opts.zone), player.y * WORLD_H
            -- a node in sight: take it
            local best, bestD
            for _, p in ipairs(points) do
                if p.up and h.profs[p.type == "herb" and 1 or 2][2] >= p.req then
                    local d = math.sqrt((p.wx - px) ^ 2 + (p.wy - py) ^ 2)
                    if d <= opts.see and (not bestD or d < bestD) then best, bestD = p, d end
                end
            end
            if best then
                stats.distance = stats.distance + bestD
                Gather(best, now)
                stats.gathered = stats.gathered + 1
                busyUntil = now + GATHER_TIME + bestD / opts.speed
            else
                -- where to ride: a tracked node on the minimap, else the addon's target
                local goal
                if opts.oracle == 1 then
                    for _, p in ipairs(points) do
                        if p.up and h.profs[p.type == "herb" and 1 or 2][2] >= p.req then
                            local d = math.sqrt((p.wx - px) ^ 2 + (p.wy - py) ^ 2)
                            if not goal or d < goal.d then goal = { wx = p.wx, wy = p.wy, d = d } end
                        end
                    end
                end
                if not goal and opts.track > 0 then
                    for _, p in ipairs(points) do
                        if p.up and h.profs[p.type == "herb" and 1 or 2][2] >= p.req then
                            local d = math.sqrt((p.wx - px) ^ 2 + (p.wy - py) ^ 2)
                            if d <= opts.track and (not goal or d < goal.d) then goal = { wx = p.wx, wy = p.wy, d = d, tracked = true } end
                        end
                    end
                end
                local run = ns.run
                local tp = run and run.targetPoint
                if not goal and tp and opts.oracle ~= 1 then goal = { wx = tp.wx, wy = tp.wy, d = math.sqrt((tp.wx - px) ^ 2 + (tp.wy - py) ^ 2) } end
                if goal then
                    if goal.tracked then stats.detours = stats.detours + 1 end
                    if tp and lastTarget ~= tp.node then
                        if lastTarget then stats.arrivals = stats.arrivals + 1 end
                        lastTarget = tp.node
                    end
                    local step = math.min(goal.d, opts.speed * DT)
                    if goal.d > 0.01 then
                        px = px + (goal.wx - px) / goal.d * step
                        py = py + (goal.wy - py) / goal.d * step
                    end
                    player.x, player.y = (px - OffsetX(opts.zone)) / WORLD_W, py / WORLD_H
                    stats.distance = stats.distance + step
                else
                    stats.idle = stats.idle + DT
                end
            end
        end
        h.advance(DT)
    end
    local minutes = (h.now() - start) / 60
    stats.perHour = stats.gathered / minutes * 60
    stats.points = #points
    stats.rounds = ns.run and ns.run.round or 0
    -- arrivals at spawn points that turned out empty (the addon marks them)
    stats.emptyArrivals = emptyCount
    stats.skillUpsPerHour = skillUps / minutes * 60
    stats.goldPerHour = gold / minutes * 60 / 10000
    stats.skillEnd = h.profs[opts.mode == "ore" and 2 or 1][2]
    if #h.errors > 0 then
        out("errors:\n")
        for _, e in ipairs(h.errors) do out("  " .. e .. "\n") end
    end
    return stats
end

out(("Route simulator: zone %s, %s, %d min, speed %.1f yd/s, %d%% of spawn points up, respawn %ds, see %d yd, tracking %s, next node at %d yd\n")
    :format(opts.zone, opts.mode, opts.minutes, opts.speed, opts.active * 100, opts.respawn, opts.see,
        opts.track > 0 and (opts.track .. " yd") or "off", opts.arrive))
local sum = {}
for r = 0, opts.runs - 1 do
    local s = RunOnce(opts.seed + r)
    out(("  seed %d: %d nodes (%.0f/h), %.0f skill-ups/h (skill %d at the end), %.1fg/h, %.0f yd ridden, %.0f s idle, %d empty arrivals, %d spawn points\n")
        :format(opts.seed + r, s.gathered, s.perHour, s.skillUpsPerHour, s.skillEnd, s.goldPerHour, s.distance, s.idle, s.emptyArrivals, s.points))
    for k, v in pairs(s) do sum[k] = (sum[k] or 0) + v end
end
if opts.runs > 1 then
    out(("  average: %.1f nodes/h, %.1f skill-ups/h, %.1fg/h, %.0f yd ridden, %.1f empty arrivals\n")
        :format(sum.perHour / opts.runs, sum.skillUpsPerHour / opts.runs, sum.goldPerHour / opts.runs,
            sum.distance / opts.runs, sum.emptyArrivals / opts.runs))
end
