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
--   oracle=1         ignore the addon, always ride to the nearest node that is up
--                    (nobody can know that: the best any route could ever do)
--
-- Model: every spawn point of a kind (e.g. Peacebloom) can hold a node; about
-- `active` of them do at any time. A gathered node comes back after `respawn`
-- seconds at a random free spawn point of the same kind (that's how Classic
-- spreads nodes). You ride straight lines (no mountains, no mobs), gather
-- every node you see within `see` yards, 5 seconds per node.

local ROOT = arg[1] or "."
local opts = {
    zone = 1412, mode = "herb", minutes = 60, speed = 11.2, active = 0.35, respawn = 600,
    see = 40, track = 0, arrive = 25, seed = 1, runs = 1, oracle = 0,
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
    h.profs[1][2], h.profs[1][3] = 300, 300
    h.profs[2][2], h.profs[2][3] = 300, 300
    h.fire("ADDON_LOADED", "Gathercraft")
    player.map, player.x, player.y = opts.zone, 0.5, 0.5
    h.fire("PLAYER_LOGIN")
    h.fire("PLAYER_ENTERING_WORLD")
    h.advance(5)
    ns.db.arriveDist = opts.arrive
    ns.db.debug = false

    -- the world: spawn points of this zone, grouped by kind
    local data = GathercraftQuestieData
    local packed = data.zones[opts.zone]
    assert(packed, "no known spawn points for zone " .. tostring(opts.zone))
    local TYPES = { h = "herb", o = "ore" }
    local points, byKind = {}, {}
    for id, xs, ys in packed:gmatch("(%d+),(%d+),(%d+)") do
        local kind = data.kinds["o" .. id]
        local t = kind and TYPES[kind[1]]
        if t and (opts.mode == "both" or opts.mode == t) then
            local p = { id = tonumber(id), type = t, item = kind[2], x = tonumber(xs) / 10000, y = tonumber(ys) / 10000 }
            p.wx, p.wy = p.x * WORLD_W + OffsetX(opts.zone), p.y * WORLD_H
            points[#points + 1] = p
            byKind[id] = byKind[id] or {}
            table.insert(byKind[id], p)
        end
    end
    assert(#points > 0, "no " .. opts.mode .. " spawn points in zone " .. opts.zone)
    -- which spawn points hold a node right now
    for _, list in pairs(byKind) do
        local want = math.max(1, math.floor(#list * opts.active + 0.5))
        local order = {}
        for i = 1, #list do order[i] = list[i] end
        for i = #order, 2, -1 do local j = math.random(i) order[i], order[j] = order[j], order[i] end
        for i = 1, want do order[i].up = true end
    end
    local respawns = {} -- { at, kind }

    local function Respawn(now)
        for i = #respawns, 1, -1 do
            local r = respawns[i]
            if now >= r.at then
                table.remove(respawns, i)
                local free = {}
                for _, p in ipairs(byKind[r.kind]) do if not p.up then free[#free + 1] = p end end
                if #free > 0 then free[math.random(#free)].up = true end
            end
        end
    end

    local spawnSeq = 0
    local function Gather(p, now)
        spawnSeq = spawnSeq + 1
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
    local start = h.now()
    local stop = start + opts.minutes * 60
    local busyUntil = 0
    while h.now() < stop do
        local now = h.now()
        Respawn(now)
        if now >= busyUntil then
            local px, py = player.x * WORLD_W + OffsetX(opts.zone), player.y * WORLD_H
            -- a node in sight: take it
            local best, bestD
            for _, p in ipairs(points) do
                if p.up then
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
                        if p.up then
                            local d = math.sqrt((p.wx - px) ^ 2 + (p.wy - py) ^ 2)
                            if not goal or d < goal.d then goal = { wx = p.wx, wy = p.wy, d = d } end
                        end
                    end
                end
                if not goal and opts.track > 0 then
                    for _, p in ipairs(points) do
                        if p.up then
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
    for _, n in ipairs(ns.db.nodes[opts.zone] or {}) do
        if (n.emptyStreak or 0) > 0 then stats.emptyArrivals = stats.emptyArrivals + n.emptyStreak end
    end
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
    out(("  seed %d: %d nodes (%.0f/h), %.0f yd ridden, %.0f s idle, %d empty arrivals, %d targets reached, %d spawn points\n")
        :format(opts.seed + r, s.gathered, s.perHour, s.distance, s.idle, s.emptyArrivals, s.arrivals, s.points))
    for k, v in pairs(s) do sum[k] = (sum[k] or 0) + v end
end
if opts.runs > 1 then
    out(("  average: %.1f nodes/h, %.0f yd ridden, %.0f s idle, %.1f empty arrivals\n")
        :format(sum.perHour / opts.runs, sum.distance / opts.runs, sum.idle / opts.runs, sum.emptyArrivals / opts.runs))
end
