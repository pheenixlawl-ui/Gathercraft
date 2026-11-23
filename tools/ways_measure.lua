-- Ways (0.2.4 S1): what the net of your paths costs, measured with the real
-- addon code inside the mini WoW of tools/smoke_test.lua on real path pieces.
--
-- Usage:
--   luajit tools/ways_measure.lua <Gathercraft folder> <extract.lua> <zonesizes.lua> [options]
--     extract.lua    path pieces per zone: return { [mapID] = { e = { [key] = value } }, ... }
--                    (made from a copy of the saved data; it never belongs into the repository)
--     zonesizes.lua  return { [mapID] = { width, height } } in yards
--   Options:
--     zones=1434,2548,max   the zones to measure; "max" is a made-up zone at the limits
--                           (8,000 squares, about 19,000 edges)
--     requests=60           ways asked for per zone
--     seed=1
--
-- What it does per zone: a farm run to one node, 60 frames a second. The first
-- way needs the net (cold); then the node changes again and again (warm). The
-- addon's own clock for its work (ns.WaysClock) is the performance counter; the
-- numbers are what Ways.lua counts itself: the sum of all S1 work per frame and
-- its longest step.
--
-- What the numbers are worth: LuaJIT without its compiler is the nearest thing
-- to the game's Lua on this computer, and several times faster than it. The
-- maps are the mock's: placing a dot costs next to nothing here, in the game it
-- is HereBeDragons' work. So the frame sums show that the rule holds (no frame
-- above 1.0 ms by the addon's own count), not what a frame costs in the game.
local ROOT, EXTRACT, SIZEFILE = arg[1], arg[2], arg[3]
assert(SIZEFILE, "usage: ways_measure.lua <Gathercraft folder> <extract.lua> <zonesizes.lua> [zones=..] [requests=..] [seed=..]")
local opts = { zones = "1434,2548,max", requests = 60, seed = 1 }
for i = 4, #arg do
    local k, v = arg[i]:match("^(%w+)=(.+)$")
    if k and opts[k] ~= nil then opts[k] = tonumber(v) or v end
end
if jit then jit.off() end
local out = io.write
local floor, sqrt, max, min = math.floor, math.sqrt, math.max, math.min
local data, sizes = dofile(EXTRACT), dofile(SIZEFILE)
-- (two zones of WoW: Forever are not in the size table: estimated from the pieces, height = width / 1.5)
local ESTIMATED = { [2548] = 4850, [2521] = 5550 }

local Clock
do
    local ok, ffi = pcall(require, "ffi")
    if ok and ffi then
        ffi.cdef("int QueryPerformanceCounter(int64_t *); int QueryPerformanceFrequency(int64_t *);")
        local c = ffi.new("int64_t[1]")
        ffi.C.QueryPerformanceFrequency(c)
        local freq = tonumber(c[0])
        Clock = function()
            ffi.C.QueryPerformanceCounter(c)
            return tonumber(c[0]) * 1000 / freq
        end
    else
        Clock = function() return os.clock() * 1000 end
    end
end

local GRID = 1024
local function Pack(count, cost, falls) return ((falls * 1024 + cost) * 256 + count) * 16384 + 300 end
-- a made-up zone at the limits: a ride back and forth through 100 x 80 squares, and every fifth column ridden down
local function MaxZone()
    local e = {}
    local function Piece(tx, ty, dx, dy) e[(ty * GRID + tx) * 9 + (dy + 1) * 3 + (dx + 1)] = Pack(1, 100, 0) end
    for y = 0, 79 do
        for x = 0, 98 do
            if y % 2 == 0 then Piece(20 + x, 20 + y, 1, 0) else Piece(20 + x + 1, 20 + y, -1, 0) end
        end
        if y < 79 then Piece(y % 2 == 0 and 119 or 20, 20 + y, 0, 1) end
    end
    for x = 0, 99, 5 do
        for y = 0, 78 do if not (x == 0 and y % 2 == 1) then Piece(20 + x, 20 + y, 0, 1) end end
    end
    return e
end

local function Stat(list)
    local n = #list
    if n == 0 then return 0, 0, 0 end
    local s, sum = {}, 0
    for i = 1, n do
        s[i] = list[i]
        sum = sum + list[i]
    end
    table.sort(s)
    return sum / n, s[max(1, math.ceil(n * 0.9))], s[n]
end

local function Measure(zoneName)
    local mapID = zoneName == "max" and 1470 or tonumber(zoneName)
    local e, w, h
    if zoneName == "max" then
        e, w, h = MaxZone(), 5000, 3333
    else
        e = data[mapID] and data[mapID].e
        if sizes[mapID] then w, h = sizes[mapID][1], sizes[mapID][2] elseif ESTIMATED[mapID] then w, h = ESTIMATED[mapID], ESTIMATED[mapID] / 1.5 end
    end
    if not (e and w) then
        out(("zone %s: no pieces or no size\n"):format(zoneName))
        return
    end
    GathercraftDB, WoWFFarmDB = nil, nil
    HARNESS_ONLY = true
    arg = { ROOT }
    local H = dofile(ROOT .. "/tools/smoke_test.lua")
    local ns, player = H.ns, H.player
    local HBD = LibStub("HereBeDragons-2.0")
    local OFF = 100000
    HBD.GetZoneSize = function(_, map) if map == mapID then return w, h end return 0, 0 end
    HBD.GetWorldCoordinatesFromZone = function(_, x, y) return x * w + OFF, y * h, 1 end
    HBD.GetPlayerWorldPosition = function() return player.x * w + OFF, player.y * h, 1 end
    H.profs[1][2], H.profs[1][3], H.profs[2][2], H.profs[2][3] = 300, 300, 300, 300
    H.fire("ADDON_LOADED", "Gathercraft")
    player.map, player.x, player.y = mapID, 0.5, 0.5
    H.fire("PLAYER_LOGIN")
    H.fire("PLAYER_ENTERING_WORLD")
    H.advance(5)
    debugprofilestop = function() return 0 end -- (the planner always finishes its plan)
    ns.WaysClock = Clock
    local pieces = 0
    for _ in pairs(e) do pieces = pieces + 1 end
    ns.db.paths = { off = true, hinted = true, zones = { [mapID] = { n = pieces, e = e } }, total = pieces }
    ns.PathsCount()
    WorldMapFrame:Show() -- (the line on both maps)
    -- (the mock's pin functions keep every call in a list: here they only count)
    local P = LibStub("HereBeDragons-Pins-2.0")
    local placed = 0
    for _, name in ipairs({ "AddMinimapIconWorld", "AddWorldMapIconWorld" }) do P[name] = function() placed = placed + 1 end end
    for _, name in ipairs({ "RemoveMinimapIcon", "RemoveWorldMapIcon", "RemoveAllWorldMapIcons", "RemoveAllMinimapIcons" }) do P[name] = function() end end

    -- the squares that were ridden, as places to stand at and to ride to
    local squares, seen = {}, {}
    for key in pairs(e) do
        local dir = key % 9
        local f = (key - dir) / 9
        if not seen[f] then
            seen[f] = true
            squares[#squares + 1] = f
        end
    end
    table.sort(squares)
    local seed = opts.seed * 7919 + mapID
    local function Rand(n)
        seed = (seed * 16807) % 2147483647
        return seed % n
    end
    local function Place(f)
        local tx = f % GRID
        return (tx + 0.5) * 25 / w, ((f - tx) / GRID + 0.5) * 25 / h
    end
    local function Node(f)
        local x, y = Place(f)
        return { id = "o1731", name = "Copper Vein", type = "ore", x = x, y = y, count = 3, last = 1 }
    end
    local work = select(7, ns.WaysState())
    local workFn = work:GetScript("OnUpdate")
    local diag = ns.WaysDiag()
    -- one frame of a sixtieth of a second; returns what S1 took in it by its own count
    local frames, over, overStep = 0, 0, 0
    local function Frame()
        H.advance(1 / 60)
        if work:IsShown() then workFn(work, 1 / 60) end
        GathercraftArrow:GetScript("OnUpdate")(GathercraftArrow, 1 / 60)
        frames = frames + 1
        local _, sum = ns.WaysDiag()
        if sum > 1.0 then over = over + 1 end
        return sum
    end
    -- frames until the navigation has taken the run's node, asked for its way, and the line is drawn (or it is the straight line)
    local function Settle(limit)
        local n, ms = 0, 0
        local nav, net, req
        repeat
            ms = ms + Frame()
            n = n + 1
            nav, net, req = ns.WaysState()
        until n >= (limit or 600) or (nav and ns.run and nav.node == ns.run.target and nav.asked and not req.active and not net.building
            and not select(3, ns.RouteWaysHead()).job)
        return n, ms
    end

    collectgarbage("collect")
    local kb0 = collectgarbage("count")
    -- cold: the run starts, the net is built, the first way is found and drawn
    local startF = squares[1 + Rand(#squares)]
    player.x, player.y = Place(startF)
    local first = Node(squares[1 + Rand(#squares)])
    ns.db.nodes[mapID] = { first }
    ns.StartRun("ore", mapID)
    local run = ns.run
    assert(run and run.target, "no run")
    diag.peak, diag.step = 0, 0
    local coldFrames, coldMs = Settle(3000)
    -- (the net's lists are only looked at through this function: a reference kept here would keep them alive)
    local function Net()
        local _, net, _, ctx = ns.WaysState()
        local set = ctx and ctx.active ~= 0 and ctx.sets[ctx.active]
        if not set then return nil, tostring(net.over) end
        return ("%d squares, %d edges, %d parts"):format(set.n, set.m, set.parts)
    end
    local function Reason()
        local ctx = select(4, ns.WaysState())
        return ctx and tostring(ctx.q.reason) or "?"
    end
    local set, why = Net()
    out(("\nzone %s: %d pieces, %s\n"):format(zoneName, pieces, set or ("no net (" .. why .. ")")))
    out(("  cold (net built, first way found and drawn): %d frames (%.2f s at 60 frames a second), %.1f ms of S1 work in all; largest frame %.3f ms, longest step %.3f ms\n")
        :format(coldFrames, coldFrames / 60, coldMs, diag.peak, diag.step))
    if not set then return end
    local coldPeak, coldStep = diag.peak, diag.step

    -- warm: the node changes again and again, you stand somewhere on your net each time
    local results, msList, frameList = {}, {}, {}
    diag.peak, diag.step = 0, 0
    for _ = 1, opts.requests do
        local from = squares[1 + Rand(#squares)]
        local to
        for _ = 1, 50 do
            to = squares[1 + Rand(#squares)]
            local ax, ay, bx, by = from % GRID, floor(from / GRID), to % GRID, floor(to / GRID)
            local d = sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) * 25
            if d >= 100 and d <= 600 then break end
        end
        player.x, player.y = Place(from)
        local node = Node(to)
        local wx, wy = HBD:GetWorldCoordinatesFromZone(node.x, node.y, mapID)
        ns.db.nodes[mapID][1] = node
        run.target, run.targetPoint = node, { node = node, mapID = mapID, wx = wx, wy = wy }
        run.targetBest, run.progressBest, run.lastX = nil, nil, nil
        run.path[1], run.pointsDirty = run.targetPoint, true -- (the run's own list of nodes is collected anew at its next plan)
        local n, ms = Settle(600)
        local state = ns.WaysRead(run).state
        local reason = state == "net" and "net" or ("line: " .. Reason())
        results[reason] = (results[reason] or 0) + 1
        msList[#msList + 1], frameList[#frameList + 1] = ms, n
    end
    local keys = {}
    for k in pairs(results) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = ("%s %d"):format(k, results[k]) end
    local mMean, mP90, mMax = Stat(msList)
    local fMean, fP90, fMax = Stat(frameList)
    out(("  warm, %d new nodes 100 to 600 yd from you: %s\n"):format(opts.requests, table.concat(parts, ", ")))
    out(("    S1 work per node: mean %.2f ms, 9 of 10 under %.2f ms, at most %.2f ms; frames until the way is drawn: mean %.1f, 9 of 10 under %d, at most %d (%.2f s)\n")
        :format(mMean, mP90, mMax, fMean, fP90, fMax, fMax / 60))
    out(("    largest frame %.3f ms, longest step %.3f ms; frames above 1.0 ms: %d of %d\n"):format(max(diag.peak, coldPeak), max(diag.step, coldStep), over, frames))

    -- The same ride of 150 yd along a way that is shown (10 s at 15 yd a second), with the option on
    -- and off: how often a dot is placed on a map. (Placing is HereBeDragons' work in the game - the
    -- larger part of what a line costs there. The straight head places all its dots again every 1.5 yd.)
    do
        local way
        for _ = 1, 200 do
            local from = squares[1 + Rand(#squares)]
            local to = squares[1 + Rand(#squares)]
            local d = sqrt((from % GRID - to % GRID) ^ 2 + (floor(from / GRID) - floor(to / GRID)) ^ 2) * 25
            if d >= 300 and d <= 900 then
                player.x, player.y = Place(from)
                local node = Node(to)
                local wx, wy = HBD:GetWorldCoordinatesFromZone(node.x, node.y, mapID)
                ns.db.nodes[mapID][1] = node
                run.target, run.targetPoint = node, { node = node, mapID = mapID, wx = wx, wy = wy }
                run.targetBest, run.progressBest, run.lastX = nil, nil, nil
                run.path[1], run.pointsDirty = run.targetPoint, true -- (the run's own list of nodes is collected anew at its next plan)
                Settle(600)
                way = ns.WaysRead(run)
                if way.state == "net" and way.points.len >= 200 then break end
                way = nil
            end
        end
        if way then
            local xs, ys, cum = {}, {}, {}
            for i = 1, way.n do xs[i], ys[i], cum[i] = (way.points.wx[i] - OFF) / w, way.points.wy[i] / h, way.points.cum[i] end
            local n, wayYards = #xs, floor(way.points.len)
            local function Ride()
                player.x, player.y = xs[1], ys[1]
                for _ = 1, 30 do Frame() end
                local before, s = placed, 1
                for f = 1, 600 do
                    local at = f * 0.25
                    while s < n - 1 and cum[s + 1] < at do s = s + 1 end
                    local k = (at - cum[s]) / (cum[s + 1] - cum[s])
                    player.x, player.y = xs[s] + (xs[s + 1] - xs[s]) * k, ys[s] + (ys[s + 1] - ys[s]) * k
                    Frame()
                end
                return placed - before
            end
            local on = Ride()
            local stillNet = ns.WaysRead(run).state
            -- hiding the whole line at once, as when a way is taken back
            local dots = select(3, ns.RouteWaysHead()).top
            local t0 = Clock()
            ns.RouteWaysDrawer.Hide()
            local hideMs = Clock() - t0
            ns.db.routeWaysOff = true
            ns.WaysOptionChanged()
            local off = Ride()
            ns.db.routeWaysOff = nil
            ns.WaysOptionChanged()
            out(("  a ride of 150 yd along a way of %d yd (%s at its end): %d placements of a dot with the option on, %d with it off\n")
                :format(wayYards, stillNet, on, off))
            out(("  hiding the whole line at once: %d dots on each map in %.4f ms here (the mock's textures; 0.25 ms of a frame are kept back for it)\n")
                :format(dots, hideMs))
            Settle(600)
        else
            out("  (no way of 200 yd or more was found for the ride)\n")
        end
    end

    -- a new node again and again before the search is done
    local cancelled = diag.cancelled
    for i = 1, 40 do
        local node = Node(squares[1 + Rand(#squares)])
        ns.db.nodes[mapID][1] = node
        local wx, wy = HBD:GetWorldCoordinatesFromZone(node.x, node.y, mapID)
        run.target, run.targetPoint = node, { node = node, mapID = mapID, wx = wx, wy = wy }
        run.targetBest, run.progressBest = nil, nil
        run.path[1], run.pointsDirty = run.targetPoint, true -- (the run's own list of nodes is collected anew at its next plan)
        for _ = 1, 6 + i % 4 do Frame() end
    end
    Settle(600)
    out(("    40 nodes in quick succession: %d searches given up, then a way is shown as before (%s); frames above 1.0 ms: %d\n")
        :format(diag.cancelled - cancelled, ns.WaysRead(run).state, over))

    -- two ordinary new builds (50 new pieces each): both sets hold a net, the work lists are as long as they get
    for round = 1, 2 do
        for i = 1, 50 do
            e[(1000 * GRID + 900 + 2 * i + 200 * round) * 9 + 5] = Pack(1, 100, 0)
            ns.PathsChanged(mapID, "new")
        end
        Settle(3000)
    end
    collectgarbage("collect")
    local kb1 = collectgarbage("count")
    local worldDots, miniDots = ns.RouteWaysHead()
    out(("  the net after two more builds: %s; %d + %d dots were made for the line, %d placements; frames above 1.0 ms: %d\n")
        :format(Net() or "none", #worldDots, #miniDots, placed, over))
    ns.StopRun(true)
    for _ = 1, 120 do Frame() end
    collectgarbage("collect")
    local kb2 = collectgarbage("count")
    out(("  memory: with both sets, the build's work lists and the search's lists the addon held %.0f KB more than after the run, when they are let go (the dots stay to be used again)\n")
        :format(kb1 - kb2))
    out(("  counted by the addon: %d requests, %d given up, %d late, %d dropped, %d builds, %d over the limits\n")
        :format(diag.requests, diag.cancelled, diag.late, diag.dropped, diag.builds, diag.over))
end

out(("Ways, measured %s with %s\n"):format(os.date("%Y-%m-%d %H:%M"), jit and (jit.version .. ", without its compiler") or _VERSION))
for name in tostring(opts.zones):gmatch("[^,]+") do Measure(name) end
