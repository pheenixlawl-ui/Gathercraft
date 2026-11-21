-- visitlog_report.lua: what the visit log (/gcr visitlog, VisitLog.lua, dev-0.2-diag) says about
-- where a gathered node comes back - at the same point, or at some other free point of the zone.
--
--   lua tools/visitlog_report.lua <file> [min=15] [radius=12] [passed=0] [points=20]
--   lua tools/visitlog_report.lua selftest
-- (with tools/lua_runner.py: python lua_runner.py run <addon folder> tools/visitlog_report.lua <file> ...)
--
--   <file>    a COPY of the SavedVariables file Gathercraft.lua (never the one in the WoW folder
--             while the game runs), or a file route_sim.lua wrote with vlout= (one block per run)
--   min=15    minutes: revisits at least this long after the last look count as "later"
--   radius=12 yards: entries this close (same type) are one point
--   passed=1  also count points passed on the way without a harvest as empty (off: you may
--             simply not have stopped for them)
--   points=20 how many points the table per point shows
--
-- What it counts. A look at a point is "full" when you gathered there (G, booked or
-- resumed; the same spawn once more and cultivated copies are left out) and "empty" when the
-- route checked it as its target and nothing was harvested (V empty, flag T, not in combat).
-- Each look after the first one at a point is a revisit: what the look before it was (a
-- harvest or empty), how long ago, and whether the point was full now.
--
-- The two models (route_sim's "random free point" is the second):
--   same point:        a gathered node grows again where it was. After a harvest the point is
--                      full again once the respawn time is over, nearly always (others may take
--                      it first). A point found empty is one that has no node of its own: it
--                      stays empty, unless another player had just taken its node.
--   random free point: a gathered node grows again at any free spawn point of its kind in
--                      the zone. What a point was before says nothing after a while: later
--                      revisits are full about as often after a harvest as after an empty look,
--                      and both only as often as a point holds a node at all.
-- So it compares later revisits after a harvest with later revisits after an empty look, within
-- each kind (the set of kinds seen at a point): a kind that holds a node more often is harvested
-- more often and is full again more often, so over all points at once "after a harvest" is fuller
-- in both worlds. The difference is the weighted mean of the kinds' differences (weights
-- n1 n2 / (n1 + n2), 95 % interval from their variances). It compares:
--   same point        when after a harvest at least 80 % are full (lower bound of the 95 %
--                     interval) and that is at least 25 points more than after an empty look
--                     (lower bound of the difference within kinds): a point comes back nearly
--                     always, and it matters what it was
--   random free point when the difference within kinds is below 15 points and after a harvest
--                     below 80 % are full (both upper bounds) - and the revisits reach past the
--                     respawn time: after a harvest at least 10 % full (lower bound) and the
--                     difference not clearly below zero (upper bound not below -5 points)
--   undecided         else, or fewer than 20 later revisits on either side. Revisits that come
--                     before the respawn time (a short round, a long respawn) look like a random
--                     free point in both worlds: after a harvest the point is still empty, at
--                     the same point too. Then it says so and asks for longer rounds.
-- Points differ even within a kind (a place several kinds share, a point the zone seldom fills).
-- Then "after a harvest" is fuller in both worlds: in route_sim rides of Arathi herbs, where a
-- node always comes back at a random free point, by 9 to 16 points within kinds. Such numbers
-- give "undecided", never "same point": compare them with route_sim rides of the same zone.
-- The 80 %, 25, 15, 10 and 5 points are judgement, not measured; the tables show what they rest on.

local M = {}

local BINS = { 0, 5, 10, 15, 20, 30, 45, 60, 90, 180, 360 } -- minutes

-- 95 % interval of a share (Wilson)
local function Wilson(k, n)
    if n == 0 then return 0, 0, 1 end
    local z, p = 1.959964, k / n
    local d = 1 + z * z / n
    local c = (p + z * z / (2 * n)) / d
    local h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return p, math.max(0, c - h), math.min(1, c + h)
end
M.Wilson = Wilson

-- 95 % interval of the difference of two shares (Newcombe, from the two Wilson intervals)
local function DiffInterval(k1, n1, k2, n2)
    local p1, l1, u1 = Wilson(k1, n1)
    local p2, l2, u2 = Wilson(k2, n2)
    local d = p1 - p2
    return d, d - math.sqrt((p1 - l1) ^ 2 + (u2 - p2) ^ 2), d + math.sqrt((u1 - p1) ^ 2 + (p2 - l2) ^ 2)
end
M.DiffInterval = DiffInterval

local function Split(text)
    local f = {}
    for v in (text .. ";"):gmatch("([^;]*);") do f[#f + 1] = v end
    return f
end

-- one entry -> a table, or nil when it is none
local function Parse(text)
    local f = Split(text)
    local ev = f[1]
    if ev ~= "V" and ev ~= "S" and ev ~= "G" then return end
    local e = { ev = ev, t = tonumber(f[2]), map = f[3], type = f[4], id = f[5], x = tonumber(f[6]), y = tonumber(f[7]),
        wx = tonumber(f[8]), wy = tonumber(f[9]), result = f[10], flags = f[11], sk = f[12] }
    if not (e.t and e.wx and e.wy) then return end
    return e
end
M.Parse = Parse

-- the blocks of entries in a file: a SavedVariables copy has one, a route_sim file one per run
function M.ReadFile(path)
    local f = assert(io.open(path, "r"), "can't open " .. tostring(path))
    local text = f:read("*a")
    f:close()
    if text:find("GathercraftDB", 1, true) then
        local env = {}
        local chunk = assert((loadstring or load)(text, "=" .. path))
        if setfenv then setfenv(chunk, env) else chunk = assert(load(text, "=" .. path, "t", env)) end
        chunk()
        local db = env.GathercraftDB or {}
        return { { label = "SavedVariables", entries = db.visitLog or {}, dropped = db.visitLogDropped or 0, on = db.visitLogOn } }
    end
    local blocks, cur = {}, nil
    for line in text:gmatch("[^\r\n]+") do
        if line:sub(1, 1) == "#" then
            cur = { label = line:sub(3), entries = {} }
            blocks[#blocks + 1] = cur
        elseif line:find("^[VSG];") then
            if not cur then
                cur = { label = "lines", entries = {} }
                blocks[#blocks + 1] = cur
            end
            cur.entries[#cur.entries + 1] = line
        end
    end
    return blocks
end

-- looks per point from a block of entries
local function Points(entries, opt)
    local points, grid, counts = {}, {}, { full = 0, empty = 0, other = 0 }
    local cell = opt.radius * 2
    local function Find(e)
        local gx, gy = math.floor(e.wx / cell), math.floor(e.wy / cell)
        local best, bd
        for dx = -1, 1 do
            for dy = -1, 1 do
                for _, p in ipairs(grid[e.map .. ":" .. e.type .. ":" .. (gx + dx) .. ":" .. (gy + dy)] or {}) do
                    local d = math.sqrt((p.wx - e.wx) ^ 2 + (p.wy - e.wy) ^ 2)
                    if d <= opt.radius and (not bd or d < bd) then best, bd = p, d end
                end
            end
        end
        if best then return best end
        local p = { map = e.map, type = e.type, wx = e.wx, wy = e.wy, x = e.x, y = e.y, kinds = {}, looks = {} }
        local key = e.map .. ":" .. e.type .. ":" .. gx .. ":" .. gy
        grid[key] = grid[key] or {}
        table.insert(grid[key], p)
        points[#points + 1] = p
        return p
    end
    for _, text in ipairs(entries) do
        local e = Parse(text)
        local look
        if e and e.ev == "G" and (e.result == "booked" or e.result == "resumed") then
            look = true
        elseif e and e.ev == "V" and e.result == "empty" and e.flags == "T" then
            look = false
        elseif e and e.ev == "V" and e.result == "passed" and opt.passed then
            look = false
        end
        if look ~= nil then
            local p = Find(e)
            p.kinds[e.id] = true
            p.looks[#p.looks + 1] = { t = e.t, full = look }
            counts[look and "full" or "empty"] = counts[look and "full" or "empty"] + 1
        elseif e then
            counts.other = counts.other + 1
        end
    end
    for _, p in ipairs(points) do table.sort(p.looks, function(a, b) return a.t < b.t end) end
    return points, counts
end

local function Bin(minutes)
    for i = #BINS, 1, -1 do
        if minutes >= BINS[i] then return i end
    end
    return 1
end

-- everything the report says, as numbers (the self-test checks these)
function M.Analyse(entries, opt)
    opt = opt or {}
    opt.min, opt.radius = opt.min or 15, opt.radius or 12
    local points, counts = Points(entries, opt)
    local r = { points = #points, counts = counts, bins = { harvest = {}, empty = {} }, later = { harvest = { 0, 0 }, empty = { 0, 0 } },
        first = { 0, 0 }, intervals = {}, perPoint = {}, strata = {} }
    for i = 1, #BINS do r.bins.harvest[i], r.bins.empty[i] = { 0, 0 }, { 0, 0 } end
    for _, p in ipairs(points) do
        local looks = p.looks
        if looks[1] then
            r.first[2] = r.first[2] + 1
            if looks[1].full then r.first[1] = r.first[1] + 1 end
        end
        local pp = { p = p, looks = #looks, full = 0, revisitsAfterHarvest = 0, fullAfterHarvest = 0 }
        local kinds = {}
        for k in pairs(p.kinds) do kinds[#kinds + 1] = k end
        table.sort(kinds)
        local stratum = table.concat(kinds, "+")
        r.strata[stratum] = r.strata[stratum] or { harvest = { 0, 0 }, empty = { 0, 0 } }
        local lastHarvest
        for i, l in ipairs(looks) do
            if l.full then
                pp.full = pp.full + 1
                if lastHarvest then r.intervals[#r.intervals + 1] = (l.t - lastHarvest) / 60 end
                lastHarvest = l.t
            end
            local prev = looks[i - 1]
            if prev and l.t - prev.t >= 60 then -- (the same stay: not a revisit)
                local side = prev.full and "harvest" or "empty"
                local minutes = (l.t - prev.t) / 60
                local b = r.bins[side][Bin(minutes)]
                b[2] = b[2] + 1
                if l.full then b[1] = b[1] + 1 end
                if minutes >= opt.min then
                    for _, s in ipairs({ r.later[side], r.strata[stratum][side] }) do
                        s[2] = s[2] + 1
                        if l.full then s[1] = s[1] + 1 end
                    end
                end
                if prev.full then
                    pp.revisitsAfterHarvest = pp.revisitsAfterHarvest + 1
                    if l.full then pp.fullAfterHarvest = pp.fullAfterHarvest + 1 end
                end
            end
        end
        r.perPoint[#r.perPoint + 1] = pp
    end
    table.sort(r.perPoint, function(a, b)
        if a.looks ~= b.looks then return a.looks > b.looks end
        return a.p.wx < b.p.wx
    end)
    table.sort(r.intervals)
    -- the verdict
    local h, e = r.later.harvest, r.later.empty
    local ph, lh, uh = Wilson(h[1], h[2])
    r.afterHarvest = { ph, lh, uh }
    r.pooled = { DiffInterval(h[1], h[2], e[1], e[2]) }
    -- within kinds: the weighted mean of the kinds' differences (a kind counts only with revisits on both sides)
    local sw, swd, swv, used = 0, 0, 0, 0
    for _, s in pairs(r.strata) do
        local n1, n2 = s.harvest[2], s.empty[2]
        if n1 > 0 and n2 > 0 then
            local p1, p2 = s.harvest[1] / n1, s.empty[1] / n2
            local q1, q2 = (s.harvest[1] + 1) / (n1 + 2), (s.empty[1] + 1) / (n2 + 2) -- (for the variance: never 0)
            local w = n1 * n2 / (n1 + n2)
            sw, swd = sw + w, swd + w * (p1 - p2)
            swv = swv + w * w * (q1 * (1 - q1) / n1 + q2 * (1 - q2) / n2)
            used = used + 1
        end
    end
    local d, ld, ud = 0, -1, 1
    if sw > 0 then
        d = swd / sw
        local half = 1.959964 * math.sqrt(swv) / sw
        ld, ud = d - half, d + half
    end
    r.difference, r.kindsUsed = { d, ld, ud }, used
    if h[2] < 20 or e[2] < 20 then
        r.verdict = "undecided"
        r.why = ("too few later revisits (after a harvest %d, after an empty look %d; at least 20 each)"):format(h[2], e[2])
    elseif lh >= 0.8 and ld >= 0.25 then
        r.verdict = "same point"
        r.why = "after a harvest the point is full again in at least 80 % of later revisits, at least 25 points more often than after an empty look of its kind"
    elseif lh < 0.1 or ud < -0.05 then
        r.verdict = "undecided"
        r.why = "after a harvest the point is hardly ever full again, or clearly less often than after an empty look: "
            .. "the later revisits probably come before the respawn time - ride longer rounds"
    elseif uh < 0.8 and ud < 0.15 then
        r.verdict = "random free point"
        r.why = "after a harvest below 80 % full, and less than 15 points more often than after an empty look of its kind"
    else
        r.verdict = "undecided"
        r.why = "the numbers fit neither rule (more revisits, or compare with route_sim rides of this zone)"
    end
    return r
end

local function Pct(v) return ("%3.0f %%"):format(v * 100) end

local function Share(k, n)
    if n == 0 then return "        -          " end
    local p, l, u = Wilson(k, n)
    return ("%4d  %s [%s; %s]"):format(n, Pct(p), Pct(l), Pct(u))
end

local function Quantile(list, q)
    if #list == 0 then return nil end
    return list[math.max(1, math.min(#list, math.floor(q * (#list - 1) + 1.5)))]
end

function M.Print(r, label, opt, out)
    out = out or io.write
    out(("== %s\n"):format(label))
    out(("looks: %d full (own gathers), %d empty (target, nothing there); %d other entries; %d points\n"):format(
        r.counts.full, r.counts.empty, r.counts.other, r.points))
    out(("first look at a point: %s full\n"):format(Share(r.first[1], r.first[2])))
    out("\nrevisits by minutes since the look before (n, share full [95 % interval]):\n")
    out("  minutes      after a harvest                after an empty look\n")
    for i = 1, #BINS do
        local h, e = r.bins.harvest[i], r.bins.empty[i]
        if h[2] + e[2] > 0 then
            local name = BINS[i + 1] and ("%d-%d"):format(BINS[i], BINS[i + 1]) or (BINS[i] .. "+")
            out(("  %-10s  %s    %s\n"):format(name, Share(h[1], h[2]), Share(e[1], e[2])))
        end
    end
    out(("\nlater revisits (at least %d minutes):\n"):format(opt.min))
    out(("  after a harvest:     %s\n"):format(Share(r.later.harvest[1], r.later.harvest[2])))
    out(("  after an empty look: %s\n"):format(Share(r.later.empty[1], r.later.empty[2])))
    local d, q = r.difference, r.pooled
    out(("  difference over all: %+.0f points [%+.0f; %+.0f]\n"):format(q[1] * 100, q[2] * 100, q[3] * 100))
    out(("  within kinds:        %+.0f points [%+.0f; %+.0f] (%d kinds with revisits on both sides)\n"):format(
        d[1] * 100, d[2] * 100, d[3] * 100, r.kindsUsed))
    if #r.intervals > 0 then
        out(("\nminutes between two own gathers at the same point: %d, min %.1f, median %.1f, 90 %% %.1f, max %.1f\n"):format(
            #r.intervals, r.intervals[1], Quantile(r.intervals, 0.5), Quantile(r.intervals, 0.9), r.intervals[#r.intervals]))
    end
    out(("\npoints with the most looks (at most %d):\n"):format(opt.points or 20))
    out("  map   type  x      y      kinds  looks  full  revisits after a harvest: full\n")
    for i = 1, math.min(opt.points or 20, #r.perPoint) do
        local pp = r.perPoint[i]
        local kinds = 0
        for _ in pairs(pp.p.kinds) do kinds = kinds + 1 end
        out(("  %-5s %-5s %5.1f  %5.1f  %5d  %5d  %4d  %d of %d\n"):format(pp.p.map, pp.p.type, (pp.p.x or 0) * 100, (pp.p.y or 0) * 100,
            kinds, pp.looks, pp.full, pp.fullAfterHarvest, pp.revisitsAfterHarvest))
    end
    out(("\nverdict: %s - %s\n"):format(r.verdict, r.why))
    out("(rules: the comment at the top of tools/visitlog_report.lua; their limits are judgement, not measured)\n\n")
end

---------------------------------------------------------------------------
-- Self-test: two toy worlds the verdict has to tell apart. A loop of
-- points ridden again and again (rounds of 15 and of 35 minutes), 35 % of
-- the points hold a node, a gathered node grows again after 10 minutes -
-- at the same point, or at a random free point. A few rivals take nodes too.
-- And one it must not judge: the same point, but 30 minutes to grow again
-- and only rounds of 15 minutes.
-- o: { respawn = seconds, rounds = { minutes, ... }, shares = { share, ... } } instead of 600,
-- 15, 15, 15, 35, 35, 35 and one kind with 35 %: the points take the kinds in turn, each kind with
-- its share of nodes, and a node comes back at a free point of its own kind
---------------------------------------------------------------------------
local function Toy(world, seed, o)
    o = o or {}
    local s = seed
    local function rnd() -- (its own generator: the same numbers everywhere)
        s = (s * 1103515245 + 12345) % 2147483648
        return s / 2147483648
    end
    local N, RESPAWN, entries = 120, o.respawn or 600, {}
    local shares = o.shares or { 0.35 }
    local up, alive, pending, kind = {}, {}, {}, {}
    for i = 1, N do
        kind[i] = (i - 1) % #shares + 1
        alive[i] = rnd() < shares[kind[i]]
        up[i] = alive[i]
    end
    local t = 1000000
    local function Respawn(now)
        for i = #pending, 1, -1 do
            local q = pending[i]
            if q.at <= now then
                table.remove(pending, i)
                local at = q.point
                if world == "pool" then
                    local free = {}
                    for j = 1, N do if not up[j] and kind[j] == kind[q.point] then free[#free + 1] = j end end
                    at = free[math.floor(rnd() * #free) + 1]
                end
                if at then up[at] = true end
            end
        end
    end
    local function Take(i, now) -- a node gathered (by you or a rival)
        up[i] = false
        pending[#pending + 1] = { at = now + RESPAWN, point = i }
    end
    for _, round in ipairs(o.rounds or { 15, 15, 15, 35, 35, 35 }) do
        local step = round * 60 / N
        for i = 1, N do
            t = t + step
            Respawn(t)
            -- rivals: now and then one takes a node somewhere
            if rnd() < 0.02 then
                local j = math.floor(rnd() * N) + 1
                if up[j] then Take(j, t) end
            end
            local wx, wy = 1000 + 60 * i, 2000
            local head = ("%%s;%d;1424;herb;o%d;%.4f;0.5000;%.1f;%.1f"):format(t, 1616 + kind[i], i / 200, wx, wy)
            if up[i] then
                entries[#entries + 1] = head:format("G") .. (";booked;R;-;%.4f;0.5000;0.0;1;TOY%06d"):format(i / 200, #entries)
                entries[#entries + 1] = head:format("V") .. ";harvested;T;-;25"
                Take(i, t)
            else
                entries[#entries + 1] = head:format("V") .. ";empty;T;-;25"
            end
        end
    end
    return entries
end
M.Toy = Toy

function M.SelfTest(out)
    out = out or function() end
    local results = {}
    for _, world in ipairs({ "same", "pool" }) do
        for _, seed in ipairs({ 1, 2, 3 }) do
            local r = M.Analyse(Toy(world, seed), { min = 15, radius = 12 })
            M.Print(r, ("self-test: toy world %s, seed %d"):format(world, seed), { min = 15, points = 3 }, out)
            local want = world == "same" and "same point" or "random free point"
            results[#results + 1] = { world = world, seed = seed, verdict = r.verdict, want = want, r = r }
        end
    end
    for _, seed in ipairs({ 1, 2, 3 }) do
        local r = M.Analyse(Toy("pool", seed, { shares = { 0.7, 0.1 } }), { min = 15, radius = 12 })
        M.Print(r, ("self-test: toy world pool, two kinds (70 %% and 10 %% up), seed %d"):format(seed), { min = 15, points = 3 }, out)
        results[#results + 1] = { world = "pool, two kinds", seed = seed, verdict = r.verdict, want = "random free point", r = r }
    end
    for _, seed in ipairs({ 1, 2, 3 }) do
        local r = M.Analyse(Toy("same", seed, { respawn = 1800, rounds = { 15, 15, 15, 15, 15, 15 } }), { min = 15, radius = 12 })
        M.Print(r, ("self-test: toy world same, 30 min respawn, rounds of 15 min, seed %d"):format(seed), { min = 15, points = 3 }, out)
        results[#results + 1] = { world = "same, slow", seed = seed, verdict = r.verdict, want = "undecided", r = r }
    end
    return results
end

local function Main(args)
    local file
    local opt = { min = 15, radius = 12, passed = false, points = 20 }
    for _, a in ipairs(args) do
        local k, v = a:match("^(%w+)=(.+)$")
        if k == "passed" then
            opt.passed = v ~= "0"
        elseif k and opt[k] ~= nil then
            opt[k] = assert(tonumber(v), "not a number: " .. a)
        else
            file = a
        end
    end
    if file == "selftest" then
        local bad = 0
        for _, x in ipairs(M.SelfTest(io.write)) do
            local ok = x.verdict == x.want
            if not ok then bad = bad + 1 end
            io.write(("self-test %s seed %d: %s (want %s) %s\n"):format(x.world, x.seed, x.verdict, x.want, ok and "ok" or "WRONG"))
        end
        io.write(bad == 0 and "self-test ok\n" or ("self-test: %d wrong\n"):format(bad))
        return bad == 0
    end
    assert(file, "usage: visitlog_report.lua <copy of Gathercraft.lua | route_sim vlout file> [min=15] [radius=12] [passed=0] [points=20] | selftest")
    for _, b in ipairs(M.ReadFile(file)) do
        local label = b.label .. (": %d entries"):format(#b.entries) .. ((b.dropped or 0) > 0 and (", %d older ones dropped"):format(b.dropped) or "")
        M.Print(M.Analyse(b.entries, opt), label, opt)
    end
    return true
end

if ... == "module" then return M end
local args = {}
for i = 1, #(arg or {}) do args[#args + 1] = arg[i] end
-- through lua_runner.py the first argument is the addon folder
if args[1] then
    local f = io.open(args[1] .. "/Gathercraft.toc", "r")
    if f then
        f:close()
        table.remove(args, 1)
    end
end
Main(args)
