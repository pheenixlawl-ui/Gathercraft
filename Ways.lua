local ADDON_NAME, ns = ...
local Wrap = ns.PerfWrap or function(_, fn) return fn end -- (/gcr perf on, Perf.lua: measured only while it is on)

---------------------------------------------------------------------------
-- Ways (0.2.4, S1): the route line's head and the arrow follow the ways you
-- have ridden yourself, instead of pointing straight over a cliff.
--
--   The net is built from the path pieces of the zone you are in (Paths.lua)
--   and from nothing else: nothing of other players, nothing shipped, nothing
--   read from the game's files. It lives in memory only - nothing of it is
--   saved, nothing is sent.
--   Only the line's head, the arrow's angle and one line in the run window
--   change. The planner, the choice of the next node, the distance, "Here!"
--   and the arrival are what they were.
--
-- First the net, then a way through it, then the navigation of a run.
--   Squares of 25 yards, numbered by their key, so the same pieces always
--   give the same net whatever order the game hands them out in.
--   An edge for every piece you rode, at its length times its cost (1.0 at
--   least). The other direction, where you never rode it:
--     - a piece without a fall, or one you also rode without one: the way
--       back at the same cost. It counts as ridden.
--     - a piece ridden once, with a fall (most of these marks were jumps):
--       a GUESSED way back at 1.5 times the cost.
--     - a piece ridden twice or more, every time with a fall: none. Down only.
--   Guessed connectors between two ridden squares side by side with no piece
--   between them: admitted one by one in a fixed order, and only while their
--   two squares are still in two different parts of the net. So connectors
--   never close a circle, and a detour you rode is never cut short by them.
--   Flat lists of numbers, two sets (one in use, one to build into), written
--   over and never made anew. At most 8,000 squares and 20,000 edges; above
--   that there is no net.
--   Everything is done in small pieces of work (BuildStep): the caller says
--   how many operations fit. No table.sort (it cannot be stopped half way).
--   Lua 5.1: no bit library, no goto, nothing of LuaJIT.
---------------------------------------------------------------------------
local M = {}
local floor, sqrt, huge = math.floor, math.sqrt, math.huge
local TILE = 25              -- yards: the side of a square, as in Paths.lua
local GRID = 1024            -- squares per row in a key, as in Paths.lua
local SQRT2 = sqrt(2)        -- the diagonal, as in Paths.lua
local MIN_COST = 1.0         -- a piece's cost counts as this at least (the search's estimate stays below the truth)
local DIAG = TILE * SQRT2
local UNSURE_FACTOR = 1.5    -- the guessed way back up a fall seen once
local CONNECTOR_FACTOR = 1.5 -- a guessed connector
local MAX_FIELDS = 8000      -- squares in a net at the most ...
local MAX_EDGES = 20000      -- ... and edges (ridden, ways back and connectors together)
M.TILE, M.GRID, M.MAX_FIELDS, M.MAX_EDGES = TILE, GRID, MAX_FIELDS, MAX_EDGES
-- An edge's kind (flag % 8): ridden, the way back, a guessed connector, the
-- guessed way back up a fall seen once. + 8: a sure fall, + 16: an unsure one.
local OBS, REV, CON, GREV, FALL, UNSURE = 1, 2, 3, 4, 8, 16
M.OBS, M.REV, M.CON, M.GREV, M.FALL, M.UNSURE = OBS, REV, CON, GREV, FALL, UNSURE
local POW = {}
for d = 0, 8 do POW[d] = 2 ^ d end

local function NewSet()
    return {
        n = 0, m = 0, cap = 0,
        key = {}, x = {}, y = {}, first = {}, hasIn = {}, part = {}, -- per square
        to = {}, cost = {}, flag = {},                               -- per edge
    }
end

-- One context: the two sets, the work lists of a build, the state of a search.
function M.New()
    return {
        sets = { NewSet(), NewSet() },
        active = 0, -- 0: no net; 1 or 2: the set in use
        S = { -- the build's work lists
            pk = {}, pv = {}, tk = {}, tv = {}, cnt = {}, fc = {}, ft = {},
            pf = {}, pt = {}, pr = {}, mask = {}, deg = {}, uf = {}, psz = {},
            cA = {}, cB = {}, cD = {},
            cap = {}, -- how long the lists that are written out of order have been made
        },
        job = {},
        Q = { -- the search's lists
            g = {}, f = {}, par = {}, pedge = {}, seen = {}, heap = {}, hpos = {}, gen = 0,
            rx = {}, ry = {}, rk = {}, keep = {}, stack = {},
            cap = 0, rawCap = 0, -- how long the lists per square and per point have been made
        },
        q = {},
    }
end

-- The number of the square with this key (they are sorted by it), or nil
local function Find(keys, n, k)
    local lo, hi = 1, n
    while lo <= hi do
        local mid = floor((lo + hi) / 2)
        local v = keys[mid]
        if v == k then return mid end
        if v < k then lo = mid + 1 else hi = mid - 1 end
    end
end
M.Find = Find

local function Root(uf, i)
    local p = uf[i]
    while p ~= i do
        local gp = uf[p]
        uf[i] = gp
        i = gp
        p = uf[i]
    end
    return i
end

local function Union(uf, a, b)
    a, b = Root(uf, a), Root(uf, b)
    if a < b then uf[b] = a elseif b < a then uf[a] = b end
end

---------------------------------------------------------------------------
-- Build
---------------------------------------------------------------------------
local BUILD = {}
local function Phase(fn) BUILD[#BUILD + 1] = fn end

local function Next(job)
    job.phase, job.i, job.stage = job.phase + 1, 0, 0
end

-- The pieces are copied out of the saved table: key and value into two lists.
-- Paths goes on recording meanwhile. A piece that comes or goes while the copy
-- is spread over several frames makes it start again (BuildDisturbed): going
-- on through a table that got a new key is not defined in Lua. A piece whose
-- numbers change is no trouble.
Phase(function(ctx, job, budget)
    local S, e = ctx.S, job.e
    local pk, pv = S.pk, S.pv
    if job.disturbed then
        job.disturbed, job.k, job.pieces = false, nil, 0
        job.restarts = job.restarts + 1
    end
    local k, n, used = job.k, job.pieces, 0
    while used < budget do
        local v
        k, v = next(e, k)
        if k == nil then
            job.pieces = n
            Next(job)
            return used + 1
        end
        used = used + 1
        local dir = k % 9
        local f = (k - dir) / 9
        local tx = f % GRID
        local dx = dir % 3 - 1
        local ty = (f - tx) / GRID + (dir - dir % 3) / 3 - 1
        if dir ~= 4 and tx + dx >= 0 and tx + dx < GRID and ty >= 0 and ty < GRID then
            n = n + 1
            pk[n], pv[n] = k, v
        end
    end
    job.k, job.pieces = k, n
    return used
end)

-- A stable sort by one digit; twice, the low digit first, sorts the list.
-- (It can be stopped at any place, and it makes no garbage.)
local function Radix(src, dst, csrc, cdst, div, buckets, countField)
    return function(ctx, job, budget)
        local S = ctx.S
        local a, b, cnt, n = S[src], S[dst], S.cnt, job[countField]
        local ca, cb = csrc and S[csrc], cdst and S[cdst]
        local stage, i = job.stage, job.i
        local last
        if stage == 0 then -- the counts start at 0
            last = i + budget
            if last > buckets then last = buckets end
            for j = i + 1, last do cnt[j] = 0 end
            if last == buckets then job.stage, job.i = 1, S.cap[dst] or 0 else job.i = last end
            return last - i + 1
        elseif stage == 1 then
            -- The list written to gets its length first, slot by slot: a list
            -- filled out of order would live in the table's hash part (more
            -- memory, and garbage whenever it is built again).
            if i >= n then
                job.stage, job.i = 2, 0
                return 1
            end
            last = i + budget
            if last > n then last = n end
            for j = i + 1, last do
                b[j] = 0
                if cb then cb[j] = 0 end
            end
            S.cap[dst] = last
            job.i = last
            return last - i + 1
        elseif stage == 2 then -- count the digits
            last = i + budget
            if last > n then last = n end
            for j = i + 1, last do
                local d = floor(a[j] / div) % buckets + 1
                cnt[d] = cnt[d] + 1
            end
            if last == n then job.stage, job.i, job.sum = 3, 0, 1 else job.i = last end
            return last - i + 1
        elseif stage == 3 then -- where each digit starts
            last = i + budget
            if last > buckets then last = buckets end
            local sum = job.sum
            for j = i + 1, last do
                local c = cnt[j]
                cnt[j] = sum
                sum = sum + c
            end
            job.sum = sum
            if last == buckets then job.stage, job.i = 4, 0 else job.i = last end
            return last - i + 1
        end
        last = i + budget
        if last > n then last = n end
        for j = i + 1, last do
            local v = a[j]
            local d = floor(v / div) % buckets + 1
            local at = cnt[d]
            cnt[d] = at + 1
            b[at] = v
            if ca then cb[at] = ca[j] end
        end
        if last == n then Next(job) else job.i = last end
        return last - i + 1
    end
end

-- the pieces by their key (4096 x 4096 is more than the largest key)
Phase(Radix("pk", "tk", "pv", "tv", 1, 4096, "pieces"))
Phase(Radix("tk", "pk", "tv", "pv", 4096, 4096, "pieces"))

-- Both squares of every piece, then sorted and each one once: the squares, numbered by their key
Phase(function(ctx, job, budget)
    local S = ctx.S
    local pk, fc, n = S.pk, S.fc, job.pieces
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    for j = i + 1, last do
        local k = pk[j]
        local dir = k % 9
        local f = (k - dir) / 9
        fc[2 * j - 1] = f
        fc[2 * j] = f + ((dir - dir % 3) / 3 - 1) * GRID + dir % 3 - 1
    end
    if last == n then
        job.cands = 2 * n
        Next(job)
    else
        job.i = last
    end
    return last - i + 1
end)
Phase(Radix("fc", "ft", nil, nil, 1, 1024, "cands"))
Phase(Radix("ft", "fc", nil, nil, 1024, 1024, "cands"))
Phase(function(ctx, job, budget)
    local S, set = ctx.S, job.set
    local fc, key, x, y, hasIn = S.fc, set.key, set.x, set.y, set.hasIn
    local mask, deg, uf, psz = S.mask, S.deg, S.uf, S.psz
    local n, cands = job.n, job.cands
    local i = job.i
    local last = i + budget
    if last > cands then last = cands end
    local prev = job.prev
    for j = i + 1, last do
        local k = fc[j]
        if k ~= prev then
            prev = k
            n = n + 1
            if n > MAX_FIELDS then
                job.over, job.done = "fields", true
                return j - i
            end
            local tx = k % GRID
            key[n], x[n], y[n] = k, (tx + 0.5) * TILE, ((k - tx) / GRID + 0.5) * TILE
            hasIn[n], mask[n], deg[n], uf[n], psz[n] = 0, 0, 0, n, 0
        end
    end
    job.n, job.prev = n, prev
    if last == cands then Next(job) else job.i = last end
    return last - i + 1
end)

-- Every piece gets the numbers of its two squares; which directions are
-- ridden out of a square; what hangs together.
Phase(function(ctx, job, budget)
    local S, set = ctx.S, job.set
    local pk, pf, pt, mask, deg, uf, key = S.pk, S.pf, S.pt, S.mask, S.deg, S.uf, set.key
    local n, fields = job.pieces, job.n
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    for j = i + 1, last do
        local k = pk[j]
        local dir = k % 9
        local f = (k - dir) / 9
        local fi = Find(key, fields, f)
        local ti = Find(key, fields, f + ((dir - dir % 3) / 3 - 1) * GRID + dir % 3 - 1)
        pf[j], pt[j] = fi, ti
        mask[fi] = mask[fi] + POW[dir]
        deg[fi] = deg[fi] + 1
        Union(uf, fi, ti)
    end
    if last == n then Next(job) else job.i = last end
    return last - i + 1
end)

-- The fall classes and the way back. The counts are read as they are saved
-- (they stop at 255): falls < count is normal, falls = count >= 2 a sure fall.
--   pr[j] = the way back (0 none, 1 ridden, 2 guessed) + 4 x the class
--   (0 normal, 1 an unsure fall, 2 a sure fall).
-- (the class of a saved piece: Paths' own rule, the one it tells a change of class by)
local Class = ns.PathsFallClass
M.Class = Class
Phase(function(ctx, job, budget)
    local S = ctx.S
    local pk, pv, pt, pr, mask, deg = S.pk, S.pv, S.pt, S.pr, S.mask, S.deg
    local n = job.pieces
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    local nRev, nGrev, nFall, nUnsure, nJump = job.nRev, job.nGrev, job.nFall, job.nUnsure, job.nJump
    for j = i + 1, last do
        local v = pv[j]
        local falls = floor(v / 4294967296) % 256
        local class = 0
        if falls > 0 then
            class = Class(floor(v / 16384) % 256, falls)
            if class == 2 then nFall = nFall + 1 elseif class == 1 then nUnsure = nUnsure + 1 else nJump = nJump + 1 end
        end
        local back = 0
        if class ~= 2 then
            local t = pt[j]
            if floor(mask[t] / POW[8 - pk[j] % 9]) % 2 == 0 then
                deg[t] = deg[t] + 1
                if class == 1 then
                    back = 2
                    nGrev = nGrev + 1
                else
                    back = 1
                    nRev = nRev + 1
                end
            end
        end
        pr[j] = back + class * 4
    end
    job.nRev, job.nGrev, job.nFall, job.nUnsure, job.nJump = nRev, nGrev, nFall, nUnsure, nJump
    if last == n then Next(job) else job.i = last end
    return last - i + 1
end)

-- How many parts the ridden net has (the direction plays no role; a fall's
-- two squares are one part)
Phase(function(ctx, job, budget)
    local uf = ctx.S.uf
    local n = job.n
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    local parts = job.partsObs
    for j = i + 1, last do
        if Root(uf, j) == j then parts = parts + 1 end
    end
    job.partsObs = parts
    if last == n then Next(job) else job.i = last end
    return last - i + 1
end)

-- The guessed connectors. A candidate: two ridden squares side by side with
-- no piece between them in either direction. Each pair is looked at once
-- (east, south-west, south, south-east of every square), so the candidates
-- come in a fixed order: by the key of the smaller square, then by the
-- direction. A candidate becomes a connector only if its two squares are in
-- two different parts AT THAT MOMENT; the two parts are joined at once.
local HALF = { { 1, 0, 5 }, { -1, 1, 6 }, { 0, 1, 7 }, { 1, 1, 8 } }
Phase(function(ctx, job, budget)
    local S, set = ctx.S, job.set
    local key, mask, deg, uf = set.key, S.mask, S.deg, S.uf
    local cA, cB, cD = S.cA, S.cB, S.cD
    local n, nc = job.n, job.nCon
    local i = job.i
    local last = i + floor(budget / 4) + 1
    if last > n then last = n end
    for a = i + 1, last do
        local k = key[a]
        local tx = k % GRID
        for h = 1, 4 do
            local half = HALF[h]
            local nx = tx + half[1]
            if nx >= 0 and nx < GRID then
                local b = Find(key, n, k + half[2] * GRID + half[1])
                local dir = half[3]
                if b and floor(mask[a] / POW[dir]) % 2 == 0 and floor(mask[b] / POW[8 - dir]) % 2 == 0
                    and Root(uf, a) ~= Root(uf, b) then
                    nc = nc + 1
                    cA[nc], cB[nc], cD[nc] = a, b, dir
                    deg[a], deg[b] = deg[a] + 1, deg[b] + 1
                    Union(uf, a, b)
                end
            end
        end
    end
    job.nCon = nc
    if last == n then Next(job) else job.i = last end
    return (last - i) * 4 + 1
end)

-- The edges, square by square: where each square's edges start, then the
-- ridden ones, the ways back, the connectors (always in this order).
Phase(function(ctx, job, budget)
    local S, set = ctx.S, job.set
    local deg, psz, first = S.deg, S.psz, set.first
    local n = job.n
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    local at = i == 0 and 1 or first[i + 1]
    for j = i + 1, last do
        first[j] = at
        local d = deg[j]
        deg[j] = at -- from here on: where the square's next edge goes
        at = at + d
        psz[j] = 0
    end
    first[last + 1] = at
    if last == n then
        job.m = at - 1
        if job.m > MAX_EDGES then
            job.over, job.done = "edges", true
        else
            Next(job)
            job.i = set.cap
        end
    else
        job.i = last
    end
    return last - i + 1
end)
-- (the edge lists get their length slot by slot before they are written out of order, see Radix)
Phase(function(ctx, job, budget)
    local set = job.set
    local to, cost, flag = set.to, set.cost, set.flag
    local m = job.m
    local i = job.i
    if i >= m then
        Next(job)
        return 1
    end
    local last = i + budget
    if last > m then last = m end
    for e = i + 1, last do to[e], cost[e], flag[e] = 0, 0, 0 end
    set.cap = last
    job.i = last
    return last - i + 1
end)
Phase(function(ctx, job, budget)
    local S, set = ctx.S, job.set
    local pk, pv, pf, pt, pr, cur = S.pk, S.pv, S.pf, S.pt, S.pr, S.deg
    local to, cost, flag, hasIn = set.to, set.cost, set.flag, set.hasIn
    local n = job.pieces
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    for j = i + 1, last do
        local v, f, t = pv[j], pf[j], pt[j]
        local c = (floor(v / 4194304) % 1024) / 100
        if c < MIN_COST then c = MIN_COST end
        local e = cur[f]
        cur[f] = e + 1
        to[e] = t
        cost[e] = ((pk[j] % 9) % 2 == 0 and DIAG or TILE) * c
        local class = floor(pr[j] / 4)
        flag[e] = class == 2 and OBS + FALL or (class == 1 and OBS + UNSURE or OBS)
        hasIn[t] = 1
    end
    if last == n then Next(job) else job.i = last end
    return last - i + 1
end)
Phase(function(ctx, job, budget)
    local S, set = ctx.S, job.set
    local pk, pv, pf, pt, pr, cur = S.pk, S.pv, S.pf, S.pt, S.pr, S.deg
    local to, cost, flag, hasIn = set.to, set.cost, set.flag, set.hasIn
    local n = job.pieces
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    for j = i + 1, last do
        local back = pr[j] % 4
        if back ~= 0 then
            local f, t = pf[j], pt[j]
            local c = (floor(pv[j] / 4194304) % 1024) / 100
            if c < MIN_COST then c = MIN_COST end
            local e = cur[t]
            cur[t] = e + 1
            to[e] = f
            c = ((pk[j] % 9) % 2 == 0 and DIAG or TILE) * c
            if back == 2 then
                cost[e], flag[e] = c * UNSURE_FACTOR, GREV
            else
                cost[e], flag[e] = c, REV
            end
            hasIn[f] = 1
        end
    end
    if last == n then Next(job) else job.i = last end
    return last - i + 1
end)
Phase(function(ctx, job, budget)
    local S, set = ctx.S, job.set
    local cA, cB, cD, cur = S.cA, S.cB, S.cD, S.deg
    local to, cost, flag, hasIn = set.to, set.cost, set.flag, set.hasIn
    local n = job.nCon
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    for j = i + 1, last do
        local a, b = cA[j], cB[j]
        local c = (cD[j] % 2 == 0 and DIAG or TILE) * CONNECTOR_FACTOR
        local e = cur[a]
        cur[a] = e + 1
        to[e], cost[e], flag[e] = b, c, CON
        e = cur[b]
        cur[b] = e + 1
        to[e], cost[e], flag[e] = a, c, CON
        hasIn[a], hasIn[b] = 1, 1
    end
    if last == n then Next(job) else job.i = last end
    return last - i + 1
end)

-- The parts with the connectors in: only for the quick look before a search
Phase(function(ctx, job, budget)
    local S, set = ctx.S, job.set
    local uf, psz, part = S.uf, S.psz, set.part
    local n = job.n
    local i = job.i
    local last = i + budget
    if last > n then last = n end
    local parts, largest = job.parts, job.largest
    local Q = ctx.Q
    local cap, seen, g, f, par, pedge, hpos, heap = Q.cap, Q.seen, Q.g, Q.f, Q.par, Q.pedge, Q.hpos, Q.heap
    for j = i + 1, last do
        local r = Root(uf, j)
        part[j] = r
        if r == j then parts = parts + 1 end
        local s = psz[r] + 1
        psz[r] = s
        if s > largest then largest = s end
        if j > cap then
            -- the search's lists per square get their length here, slot by slot (see Radix)
            seen[j], g[j], f[j], par[j], pedge[j], hpos[j], heap[j] = 0, 0, 0, 0, 0, 0, 0
            cap = j
        end
    end
    Q.cap = cap
    job.parts, job.largest = parts, largest
    if last == n then
        -- done: the set that was free is the one in use now, the other one is free
        set.n, set.m = n, job.m
        set.pieces, set.nRev, set.nFall, set.nCon = job.pieces, job.nRev, job.nFall, job.nCon
        set.nGrev, set.nUnsure, set.nJump = job.nGrev, job.nUnsure, job.nJump
        set.partsObs, set.parts, set.largest = job.partsObs, parts, largest
        ctx.active = job.target
        job.done = true
    else
        job.i = last
    end
    return last - i + 1
end)
M.BUILD_PHASES = #BUILD

-- A new build of the pieces `e` ({ [key] = value }, as Paths keeps them) into the free set
function M.BuildStart(ctx, e)
    local job = ctx.job
    job.e, job.k = e, nil
    job.target = ctx.active == 1 and 2 or 1
    job.set = ctx.sets[job.target]
    job.phase, job.i, job.stage = 1, 0, 0
    job.done, job.over, job.disturbed, job.restarts = false, nil, false, 0
    job.pieces, job.cands, job.n, job.m, job.prev = 0, 0, 0, 0, nil
    job.nRev, job.nFall, job.nCon = 0, 0, 0
    job.nGrev, job.nUnsure, job.nJump = 0, 0, 0
    job.partsObs, job.parts, job.largest = 0, 0, 0
    return job
end

-- One piece of work of the phase the build is in, `budget` operations at the
-- most. Returns the operations used.
function M.BuildStep(ctx, budget)
    local job = ctx.job
    return BUILD[job.phase](ctx, job, budget)
end

-- A piece came or went in the table a build is copying: the copy starts again
-- (after the copy it changes nothing - the build has its own lists by then)
function M.BuildDisturbed(ctx)
    local job = ctx.job
    if job.phase == 1 and not job.done then job.disturbed = true end
end

-- In one go (the tests; the game never does this)
function M.Build(ctx, e)
    local job = M.BuildStart(ctx, e)
    while not job.done do M.BuildStep(ctx, huge) end
    if job.over then return nil, job.over end
    return ctx.sets[ctx.active]
end

-- No net any more: both sets stay as tables to be written over, none is in use
function M.Drop(ctx)
    ctx.active = 0
end

-- The edge from the square with key ka to the one with key kb in a set: its
-- flag and its number, or nil (there is one at the most)
function M.Edge(set, ka, kb)
    local a, b = Find(set.key, set.n, ka), Find(set.key, set.n, kb)
    if not (a and b) then return end
    local to = set.to
    for e = set.first[a], set.first[a + 1] - 1 do
        if to[e] == b then return set.flag[e], e end
    end
end

---------------------------------------------------------------------------
-- A way through the net (W3)
--   Everything in yards of the zone, as the net is. A request goes through
--   its phases in small pieces of work like a build (QueryStep):
--     entry   the nearest square around you with an edge out, its middle 50
--             yards away at the most (only the 25 squares around you are
--             asked, never the whole net);
--     exit    the same around the node, with an edge in;
--     astar   a directed search with a heap that holds a square once at the
--             most; the estimate is the straight line (every edge costs its
--             length at least). At a tie the smaller f first, then the larger
--             g, then the smaller square number: the same data, the same way;
--     back    the way from the node back to you as points, its length, the
--             rule of length, the guessed share;
--     simple  simplified (Douglas-Peucker, 5 yards off the way of the net at
--             the most; with more than 32 segments 15, then 20 yards) and
--             written into the back buffer.
--   The straight line it is (result "line") when the node is nearer than 50
--   yards, there is no net, no entry or exit, both are the same square, they
--   are in two parts of the net, there is no directed way, or the way is too
--   long: longer than 3 times the straight line - or, for a new request to
--   the same node in the same run, longer than the rest of the way shown +
--   how far you are off it + 50 yards. The rest is measured along the way of
--   the net, not along its simplified line.
---------------------------------------------------------------------------
local ENTRY_TILES = 2    -- squares around a place that are asked (2: 25 lookups)
local ENTRY_YARDS = 50   -- the entry square's middle this near at the most
local NEAR_YARDS = 50    -- a node nearer than this: the straight line
local MAX_DETOUR = 3.0   -- times the straight line
local SAME_SLACK = 50    -- yards on top of the rest of the shown way and your distance to it
local TOLERANCES = { 5, 15, 20 } -- yards off the way of the net
local SEGMENTS_MINI = 32 -- segments drawn on the minimap at the most (more: the next tolerance) ...
local SEGMENTS_MAP = 48  -- ... and on the world map
local OFF_YARDS = 25     -- further off the way shown than this: it is taken back
local AHEAD_YARDS = 50   -- the progress is looked for this far ahead along the way
local ARROW_YARDS = 30   -- the arrow turns to the point this far ahead along the way
M.SEGMENTS_MINI, M.SEGMENTS_MAP = SEGMENTS_MINI, SEGMENTS_MAP

local QUERY = {}
local function QPhase(fn) QUERY[#QUERY + 1] = fn end

local function Line(q, reason)
    q.result, q.reason, q.done = "line", reason, true
end

-- The nearest square around a place with an edge out (entry) or an edge in (exit)
local function Nearest(set, px, py, wantIn)
    local key, x, y, first, hasIn, n = set.key, set.x, set.y, set.first, set.hasIn, set.n
    local tx, ty = floor(px / TILE), floor(py / TILE)
    local best, bestD, maxD = nil, huge, ENTRY_YARDS * ENTRY_YARDS
    local asked = 0
    for dy = -ENTRY_TILES, ENTRY_TILES do
        local yy = ty + dy
        if yy >= 0 and yy < GRID then
            for dx = -ENTRY_TILES, ENTRY_TILES do
                local xx = tx + dx
                if xx >= 0 and xx < GRID then
                    asked = asked + 1
                    local i = Find(key, n, yy * GRID + xx)
                    if i then
                        local ok
                        if wantIn then ok = hasIn[i] == 1 else ok = first[i + 1] > first[i] end
                        if ok then
                            local ddx, ddy = x[i] - px, y[i] - py
                            local d = ddx * ddx + ddy * ddy
                            if d <= maxD and (d < bestD or (d == bestD and best and i < best)) then best, bestD = i, d end
                        end
                    end
                end
            end
        end
    end
    return best, asked, bestD
end

QPhase(function(ctx, q, budget) -- entry
    local dx, dy = q.tx - q.px, q.ty - q.py
    q.air = sqrt(dx * dx + dy * dy)
    if q.air < NEAR_YARDS then
        Line(q, "near")
        return 1
    end
    local set = ctx.active ~= 0 and ctx.sets[ctx.active]
    if not set or set.n == 0 then
        Line(q, "nonet")
        return 1
    end
    q.set = set
    local i, asked, d = Nearest(set, q.px, q.py, false)
    if not i then
        Line(q, "noentry")
        return asked
    end
    q.entry, q.entryD = i, sqrt(d)
    q.phase = q.phase + 1
    return asked
end)

QPhase(function(ctx, q, budget) -- exit
    local set = q.set
    local i, asked, d = Nearest(set, q.tx, q.ty, true)
    if not i then
        Line(q, "noexit")
        return asked
    end
    q.exit, q.exitD = i, sqrt(d)
    if i == q.entry then
        Line(q, "same")
        return asked
    end
    if set.part[i] ~= set.part[q.entry] then
        Line(q, "parts")
        return asked
    end
    -- the search starts: the entry square alone is open
    local Q = ctx.Q
    local gen = Q.gen + 1
    Q.gen = gen
    local s = q.entry
    local hx, hy = set.x[s] - set.x[i], set.y[s] - set.y[i]
    Q.g[s], Q.f[s], Q.par[s], Q.pedge[s], Q.seen[s] = 0, sqrt(hx * hx + hy * hy), 0, 0, gen
    Q.heap[1], Q.hpos[s] = s, 1
    q.heapN, q.expanded = 1, 0
    q.phase = q.phase + 1
    return asked
end)

QPhase(function(ctx, q, budget) -- astar
    local set, Q = q.set, ctx.Q
    local first, to, cost, x, y = set.first, set.to, set.cost, set.x, set.y
    local g, f, par, pedge, seen, heap, hpos, gen = Q.g, Q.f, Q.par, Q.pedge, Q.seen, Q.heap, Q.hpos, Q.gen
    local goal, hn = q.exit, q.heapN
    local gx, gy = x[goal], y[goal]
    local used, expanded, hmax = 0, q.expanded, q.heapMax
    while used < budget do
        if hn == 0 then
            q.heapN, q.expanded, q.heapMax = 0, expanded, hmax
            Line(q, "nodirected")
            return used + 1
        end
        -- the best open square leaves the heap
        local u = heap[1]
        if u == goal then
            q.heapN, q.expanded, q.heapMax = hn, expanded, hmax
            q.cost = g[u]
            q.phase, q.stage, q.i = q.phase + 1, 0, 0
            return used + 1
        end
        hpos[u] = 0
        local w = heap[hn]
        hn = hn - 1
        if hn > 0 then
            local fw, gw = f[w], g[w]
            local at = 1
            while true do
                local c = at * 2
                if c > hn then break end
                local a = heap[c]
                if c < hn then
                    local b = heap[c + 1]
                    local fa, fb = f[a], f[b]
                    if fb < fa or (fb == fa and (g[b] > g[a] or (g[b] == g[a] and b < a))) then
                        c, a = c + 1, b
                    end
                end
                local fa = f[a]
                if fa < fw or (fa == fw and (g[a] > gw or (g[a] == gw and a < w))) then
                    heap[at], hpos[a] = a, at
                    at = c
                    used = used + 1
                else
                    break
                end
            end
            heap[at], hpos[w] = w, at
        end
        expanded = expanded + 1
        local gu = g[u]
        for e = first[u], first[u + 1] - 1 do
            used = used + 1
            local v = to[e]
            local ng = gu + cost[e]
            local known = seen[v] == gen
            if not known or ng < g[v] then
                local at
                -- A square is in the heap once at the most: one that is in it
                -- moves up (its key goes down), it is not put in a second time.
                -- (The estimate never overrates, and the squares lie on a grid:
                -- a square that left the heap is never found cheaper again.)
                if known and hpos[v] ~= 0 then
                    at = hpos[v]
                else
                    hn = hn + 1
                    at = hn
                    if hn > hmax then hmax = hn end
                end
                seen[v] = gen
                local hx, hy = x[v] - gx, y[v] - gy
                local fv = ng + sqrt(hx * hx + hy * hy)
                g[v], f[v], par[v], pedge[v] = ng, fv, u, e
                -- up the heap
                while at > 1 do
                    local p = floor(at / 2)
                    local a = heap[p]
                    local fa = f[a]
                    if fv < fa or (fv == fa and (ng > g[a] or (ng == g[a] and v < a))) then
                        heap[at], hpos[a] = a, at
                        at = p
                        used = used + 1
                    else
                        break
                    end
                end
                heap[at], hpos[v] = v, at
            end
        end
    end
    q.heapN, q.expanded, q.heapMax = hn, expanded, hmax
    return used
end)

-- The way back from the exit to the entry, as points: you, the squares'
-- middles, the node. Its length in yards and how much of it is guessed.
QPhase(function(ctx, q, budget) -- back
    local set, Q = q.set, ctx.Q
    local par, pedge, rx, ry, rk, x, y, flag, key = Q.par, Q.pedge, Q.rx, Q.ry, Q.rk, set.x, set.y, set.flag, set.key
    local used = 0
    if q.stage == 0 then -- how many squares
        local u, hops = q.i == 0 and q.exit or q.at, q.i
        while u ~= q.entry and used < budget do
            u = par[u]
            hops = hops + 1
            used = used + 1
        end
        q.at, q.i = u, hops
        if u ~= q.entry then return used end
        q.rawN = hops + 3
        q.stage = 3
        return used + 1
    elseif q.stage == 3 then -- (the lists of points get their length slot by slot, see Radix)
        local keep = Q.keep
        local cap, n = Q.rawCap, q.rawN
        while cap < n and used < budget do
            cap = cap + 1
            rx[cap], ry[cap], rk[cap], keep[cap] = 0, 0, 0, 0
            used = used + 1
        end
        Q.rawCap = cap
        if cap < n then return used end
        q.stage, q.i, q.at = 1, n - 1, q.exit
        q.guessYards = 0
        rx[1], ry[1], rk[1] = q.px, q.py, -1
        rx[n], ry[n], rk[n] = q.tx, q.ty, -1
        return used + 1
    elseif q.stage == 1 then -- the points, from the end
        local u, at, guess = q.at, q.i, q.guessYards
        while at >= 2 and used < budget do
            rx[at], ry[at], rk[at] = x[u], y[u], key[u]
            if at > 2 then
                local p = par[u]
                local kind = flag[pedge[u]] % 8
                if kind == CON or kind == GREV then
                    -- guessed: a connector, or the guessed way back up a fall seen once
                    local dx, dy = x[u] - x[p], y[u] - y[p]
                    guess = guess + sqrt(dx * dx + dy * dy)
                end
                u = p
            end
            at = at - 1
            used = used + 1
        end
        q.at, q.i, q.guessYards = u, at, guess
        if at >= 2 then return used end
        q.stage, q.i, q.yards = 2, 1, 0
        return used + 1
    end
    local i, n, yards = q.i, q.rawN, q.yards
    while i < n and used < budget do
        local dx, dy = rx[i + 1] - rx[i], ry[i + 1] - ry[i]
        yards = yards + sqrt(dx * dx + dy * dy)
        i = i + 1
        used = used + 1
    end
    q.i, q.yards = i, yards
    if i < n then return used end
    -- The rule of length: three times the straight line at the most; or, for
    -- a new request to the same node, not longer than the rest of the way
    -- shown + your distance to it + 50 yd.
    if yards > MAX_DETOUR * q.air then
        if not (q.allow and yards <= q.allow) then
            Line(q, "long")
            return used + 1
        end
        q.bySame = true
    end
    -- The guessed share: the guessed edges' length by the length of the way
    -- of the net without the first and the last bit; rounded, 1 % at least.
    q.netYards = yards - q.entryD - q.exitD
    local percent = 0
    if q.guessYards > 0 then
        percent = floor(100 * q.guessYards / q.netYards + 0.5)
        if percent < 1 then percent = 1 elseif percent > 100 then percent = 100 end
    end
    q.percent = percent
    q.phase, q.stage, q.i, q.tol = q.phase + 1, 0, 0, 1
    return used + 1
end)

-- Douglas-Peucker without recursion on the raw points 1..n: keep[i] = 1 for
-- the points that stay. Can stop anywhere; returns the operations used, done or not.
local function SimplifyStep(Q, q, n, tol, budget)
    local rx, ry, keep, stack = Q.rx, Q.ry, Q.keep, Q.stack
    local used = 0
    if q.stage == 0 then
        local i = q.i
        local last = i + budget
        if last > n then last = n end
        for j = i + 1, last do keep[j] = 0 end
        used = last - i
        if last < n then
            q.i = last
            return used, false
        end
        keep[1], keep[n] = 1, 1
        stack[1], stack[2] = 1, n
        q.stage, q.sp, q.kept, q.sa = 1, 2, 2, 0
        return used + 1, false
    end
    local sp, kept = q.sp, q.kept
    local tol2 = tol * tol
    -- the stretch a..b being looked through (a = 0: none), how far (j), the point furthest off so far
    local a, b, j, far, farD = q.sa, q.sb, q.sj, q.sfar, q.sfarD
    while used < budget do
        if a == 0 then
            if sp == 0 then break end
            a, b = stack[sp - 1], stack[sp]
            sp = sp - 2
            used = used + 1
            if b > a + 1 then
                j, far, farD = a + 1, 0, tol2
            else
                a = 0
            end
        end
        if a ~= 0 then
            local ax, ay = rx[a], ry[a]
            local vx, vy = rx[b] - ax, ry[b] - ay
            local len2 = vx * vx + vy * vy
            local last = j + (budget - used)
            if last > b - 1 then last = b - 1 end
            for i = j, last do
                local wx, wy = rx[i] - ax, ry[i] - ay
                local t = len2 > 0 and (wx * vx + wy * vy) / len2 or 0
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                local ex, ey = wx - t * vx, wy - t * vy
                local d = ex * ex + ey * ey
                if d > farD then far, farD = i, d end
            end
            used = used + (last - j + 1)
            j = last + 1
            if j > b - 1 then
                if far ~= 0 then
                    keep[far] = 1
                    kept = kept + 1
                    stack[sp + 1], stack[sp + 2], stack[sp + 3], stack[sp + 4] = a, far, far, b
                    sp = sp + 4
                end
                a = 0
            end
        end
    end
    q.sp, q.kept, q.sa, q.sb, q.sj, q.sfar, q.sfarD = sp, kept, a, b, j, far, farD
    return used, sp == 0 and a == 0
end

-- Simplify, then write the way into the back buffer: the points that stay
-- (x, y), how far along the simplified line each is (cum) and how far along
-- the way of the net (raw), which point of the way of the net it is (ri), and
-- the squares of the way of the net by their keys (rk; -1: you, the node).
-- Nothing is shown yet: the buffers change places when the way is published.
QPhase(function(ctx, q, budget) -- simple
    local Q = ctx.Q
    local used = 0
    if q.stage < 2 then
        local done
        used, done = SimplifyStep(Q, q, q.rawN, TOLERANCES[q.tol], budget)
        if not done then return used end
        if q.kept - 1 > SEGMENTS_MINI and q.tol < #TOLERANCES then
            q.tol, q.stage, q.i = q.tol + 1, 0, 0
            return used
        end
        q.stage, q.i, q.wn, q.wlen, q.wraw = 2, 0, 0, 0, 0
        return used + 1
    end
    local back = q.nav.back
    local bx, by, cum, raw, ri, brk = back.x, back.y, back.cum, back.raw, back.ri, back.rk
    local rx, ry, rk, keep = Q.rx, Q.ry, Q.rk, Q.keep
    local n, len, rawLen = q.wn, q.wlen, q.wraw
    local i, rawN = q.i, q.rawN
    local last = i + budget
    if last > rawN then last = rawN end
    for j = i + 1, last do
        if j > 1 then
            local dx, dy = rx[j] - rx[j - 1], ry[j] - ry[j - 1]
            rawLen = rawLen + sqrt(dx * dx + dy * dy)
        end
        brk[j] = rk[j]
        if keep[j] == 1 then
            n = n + 1
            bx[n], by[n] = rx[j], ry[j]
            if n > 1 then
                local dx, dy = bx[n] - bx[n - 1], by[n] - by[n - 1]
                len = len + sqrt(dx * dx + dy * dy)
            end
            cum[n], raw[n], ri[n] = len, rawLen, j
        end
    end
    used = used + (last - i) + 1
    q.wn, q.wlen, q.wraw, q.i = n, len, rawLen, last
    if last < rawN then return used end
    back.n, back.len, back.rawN = n, len, rawN
    back.yards, back.cost, back.guess, back.netYards, back.percent = q.yards, q.cost, q.guessYards, q.netYards, q.percent
    back.tx, back.ty = q.tx, q.ty
    -- where the last bit to the node starts, measured back from the end of the line
    back.tail = q.exitD
    q.segments, q.result, q.done = n - 1, "net", true
    return used
end)
M.QUERY_PHASES = #QUERY

local function NewBuffer()
    return { x = {}, y = {}, wx = {}, wy = {}, cum = {}, raw = {}, ri = {}, rk = {}, n = 0, len = 0, rawN = 0,
        yards = 0, cost = 0, guess = 0, netYards = 0, percent = 0, tail = 0, tx = 0, ty = 0 }
end

-- The state of one navigation: the buffer shown (front) and the one a
-- request writes into (back), the progress along the way shown, and the rest
-- of the way last shown as two numbers (for the rule of length).
function M.NewNav()
    return {
        state = "line", seg = 1, pos = 0, on = false,
        front = NewBuffer(), back = NewBuffer(),
        have = false, rest = 0, offD = 0,
    }
end

-- A request: from (px, py) to the node at (tx, ty), in yards of the zone.
-- `same`: the caller says this is a new request for the same node in the same
-- run - then a way may also be as long as the rest of the way last shown.
function M.QueryStart(ctx, nav, px, py, tx, ty, same)
    local q = ctx.q
    q.nav, q.px, q.py, q.tx, q.ty = nav, px, py, tx, ty
    q.allow, q.bySame = nil, false
    if same and nav.have then
        q.allow = nav.rest + sqrt(nav.offD) + SAME_SLACK
    end
    q.phase, q.stage, q.i = 1, 0, 0
    q.done, q.result, q.reason = false, nil, nil
    q.entry, q.exit = nil, nil
    q.expanded, q.cost, q.yards, q.rawN, q.segments = 0, 0, 0, 0, 0
    q.guessYards, q.netYards, q.percent = 0, 0, 0
    q.heapMax = 1
    return q
end

function M.QueryStep(ctx, budget)
    local q = ctx.q
    return QUERY[q.phase](ctx, q, budget)
end

-- The back buffer becomes the one shown. Its points must be there in the
-- coordinates you are followed in (wx, wy) - the caller writes them.
function M.Publish(nav)
    local b = nav.back
    nav.back, nav.front = nav.front, b
    nav.state, nav.seg, nav.pos, nav.on = "net", 1, 0, true
    nav.have, nav.rest, nav.offD = true, b.yards, 0
end

-- In one go, the points taken as they are (the tests; the game never does this)
function M.Query(ctx, nav, px, py, tx, ty, same)
    local q = M.QueryStart(ctx, nav, px, py, tx, ty, same)
    while not q.done do M.QueryStep(ctx, huge) end
    if q.result == "net" then
        local b = nav.back
        for i = 1, b.n do b.wx[i], b.wy[i] = b.x[i], b.y[i] end
        M.Publish(nav)
    else
        nav.state = "line"
    end
    return q.result, q.reason
end

-- The progress along the way shown: forwards only, looked for only up to 50
-- yd of way ahead (at a hairpin it does not jump to a later bit that is near).
-- nav.on: you are on the way - false when you are more than 25 yd off it.
-- No table, no string is made here.
function M.Progress(nav, px, py)
    local b = nav.front
    local x, y, cum, raw, n = b.wx, b.wy, b.cum, b.raw, b.n
    local pos = nav.pos
    local to = pos + AHEAD_YARDS
    local s = nav.seg
    local bestD, bestPos, bestSeg, bestRaw = huge, pos, s, b.yards - nav.rest
    while s < n and cum[s] <= to do
        local ax, ay = x[s], y[s]
        local vx, vy = x[s + 1] - ax, y[s + 1] - ay
        local len = cum[s + 1] - cum[s]
        local t = 0
        if len > 0 then
            t = ((px - ax) * vx + (py - ay) * vy) / (len * len)
            -- only the part of this segment between where you are and 50 yd ahead
            local lo, hi = (pos - cum[s]) / len, (to - cum[s]) / len
            if lo < 0 then lo = 0 end
            if hi > 1 then hi = 1 end
            if t < lo then t = lo elseif t > hi then t = hi end
        end
        local ex, ey = px - (ax + t * vx), py - (ay + t * vy)
        local d = ex * ex + ey * ey
        if d < bestD then
            bestD, bestPos, bestSeg = d, cum[s] + t * len, s
            bestRaw = raw[s] + t * (raw[s + 1] - raw[s])
        end
        s = s + 1
    end
    nav.pos, nav.seg = bestPos, bestSeg
    -- the rest of the way (along the way of the net) and how far off it you are
    nav.rest, nav.offD = b.yards - bestRaw, bestD
    nav.on = bestD <= OFF_YARDS * OFF_YARDS
    return nav.on
end

-- Where the arrow turns to: the point 30 yd along the rest of the way. nil:
-- the node itself (the rest is shorter, or the point lies on the last bit to it).
function M.ArrowPoint(nav)
    local b = nav.front
    local x, y, cum, n = b.wx, b.wy, b.cum, b.n
    local at = nav.pos + ARROW_YARDS
    if at >= b.len - b.tail then return end
    local s = nav.seg
    while s < n - 1 and cum[s + 1] < at do s = s + 1 end
    local len = cum[s + 1] - cum[s]
    local t = len > 0 and (at - cum[s]) / len or 0
    if t > 1 then t = 1 end
    return x[s] + t * (x[s + 1] - x[s]), y[s] + t * (y[s + 1] - y[s])
end

-- The rest of the way shown against a new net: is every edge of it still
-- there, in this direction? (After a new build the search may find another
-- way that is too long - it looks for the cheapest, not the shortest. Then
-- the way shown stays, if the new net still allows all of it.)
-- In pieces of work; job.ok when done. The guessed share is counted anew for
-- what is left: an edge may be of another kind in the new net.
function M.KeepStart(ctx, nav)
    local k = ctx.keepJob
    if not k then
        k = {}
        ctx.keepJob = k
    end
    local b = nav.front
    local i = b.ri[nav.seg] or 1
    if i < 2 then i = 2 end
    k.nav, k.i, k.done, k.ok = nav, i, false, false
    k.guess, k.yards = 0, 0
    return k
end

function M.KeepStep(ctx, budget)
    local k = ctx.keepJob
    local set = ctx.active ~= 0 and ctx.sets[ctx.active]
    if not set then
        k.done, k.ok = true, false
        return 1
    end
    local b = k.nav.front
    local rk, last = b.rk, b.rawN - 2
    local key, first, to, flag, n = set.key, set.first, set.to, set.flag, set.n
    local i, used, guess, yards = k.i, 0, k.guess, k.yards
    while i <= last and used < budget do
        local ka, kb = rk[i], rk[i + 1]
        local a, bb = Find(key, n, ka), Find(key, n, kb)
        local kind
        if a and bb then
            for e = first[a], first[a + 1] - 1 do
                if to[e] == bb then
                    kind = flag[e] % 8
                    break
                end
            end
        end
        if not kind then
            k.done, k.ok = true, false
            return used + 1
        end
        local d = kb - ka
        local len = (d == 1 or d == -1 or d == GRID or d == -GRID) and TILE or DIAG
        yards = yards + len
        if kind == CON or kind == GREV then guess = guess + len end
        i = i + 1
        used = used + 3
    end
    k.i, k.guess, k.yards = i, guess, yards
    if i <= last then return used end
    local percent = 0
    if guess > 0 and yards > 0 then
        percent = floor(100 * guess / yards + 0.5)
        if percent < 1 then percent = 1 elseif percent > 100 then percent = 100 end
    end
    k.percent, k.done, k.ok = percent, true, true
    return used + 1
end

ns.WaysCore = M

---------------------------------------------------------------------------
-- The navigation of a farm run (W3)
--
--   One state per run (`nav`), made when the run needs it and gone with it.
--   ONE place asks for a way: the run's head tick (Route.lua UpdateHead, ten
--   times a second) through ns.WaysTick. The line and the arrow only read.
--   A way is only ever shown for the context it was asked in. A request
--   carries a mark: the run (a number that counts at every start and stop),
--   the node AND its coordinates, the zone and the instance, the net it was
--   searched in, and the square you were in. A result whose mark is not the
--   one of now is dropped. Every reader looks at the run's target first: a
--   way to another node is taken back before anything of it is used.
--   Position, zone, instance and the node's coordinates are looked at for
--   being readable before anything is compared or worked out with them.
--
--   States (what ns.WaysRead tells): "net" - a way of the net is shown;
--   "line" - the straight line, drawn by the code that drew it before;
--   "none" - nothing can be read right now.
--
--   Work is done in small steps from one OnUpdate, and only as long as the
--   frame has room: all the time Ways.lua and the drawing of its line take in
--   one frame are added up (the frame sum), 1.0 ms at the most. Of that, 0.25
--   ms are kept back for taking a way back at once (hiding every dot of its
--   line in the same frame); the steps use the rest. A step aims at 0.125 ms:
--   each phase counts its operations and sets the count by the clock.
--   A request that is not done after 2 s, a build after 5 s, is given up.
---------------------------------------------------------------------------
local FRAME_MS = 1.0       -- all of S1 in one frame, at the most
local RESERVE_MS = 0.25    -- of it: kept back for hiding a way's line at once
local STEP_MS = 0.25       -- a step may take this (aimed at: half of it); a step only starts while this much is left
local STEP_AIM_MS = 0.125
local REQUEST_SECONDS = 2  -- a request not done by then is given up
local BUILD_SECONDS = 5    -- ... a build
local REBUILD_PIECES = 50  -- this many new pieces in the zone: the net is built anew
local OPS_MIN, OPS_MAX = 16, 200000
local STEPS_MAX = 64       -- steps in one frame at the most (a clock that stands still must not hold the frame)

local AnySecret = ns.AnySecret
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

local function Clock() return (ns.WaysClock or debugprofilestop)() end

-- The frame sum: what S1 took in the frame going on (a frame is one value of GetTime)
local frameAt, frameSum = -1, 0
local diag = { peak = 0, step = 0, requests = 0, cancelled = 0, late = 0, over = 0, builds = 0, invalid = 0, dropped = 0, ops = 0 }
local function Frame()
    local now = GetTime()
    if now ~= frameAt then frameAt, frameSum = now, 0 end
end
local function Spend(ms)
    Frame()
    frameSum = frameSum + ms
    if frameSum > diag.peak then diag.peak = frameSum end
end

local ctx        -- the net's lists (nil: none are held)
local nav        -- the run's navigation (nil: no S1 work)
local navRun     -- the run it belongs to
local gen = 0    -- counts at every start and stop of a run
local net = { mapID = nil, ready = false, building = false, over = nil, rev = 0, epoch = 0, fresh = 0, t0 = 0, w = 0, h = 0 }
local req = { active = false }
local keeping = false -- the rest of the way shown is being looked at against a new net
local read = { state = "none", n = 0, yards = 0, cost = 0, guessed = 0, percent = 0, seg = 1, pos = 0, serial = 0, pub = 0 }
-- Route.lua's part: the dots of the way's line. Hide() hides all of them now; Pending() says whether
-- dots are to be placed or taken off the maps; Step(ops) does up to ops of that and returns how many.
local drawer = ns.RouteWaysDrawer
local work = CreateFrame("Frame")
work:Hide()

-- how many operations a step of each kind of work does (set by the clock as it goes)
local ops = {}
local function Ops(kind, first)
    local n = ops[kind]
    if not n then
        n = first
        ops[kind] = n
    end
    return n
end
local function Tune(kind, used, ms)
    if ms > diag.step then diag.step = ms end
    if ms <= 0 or used < 1 then return end
    local n = ops[kind]
    local want = floor(used * STEP_AIM_MS / ms)
    if want < OPS_MIN then want = OPS_MIN elseif want > OPS_MAX then want = OPS_MAX end
    -- down at once, up by doubling at the most
    if want > n * 2 then want = n * 2 end
    ops[kind] = want
end

-- the line in the run window (UI.lua) and the line on the maps (Route.lua) are told at once
local function Told()
    read.serial = read.serial + 1
    if ns.UpdateRunSource then ns.UpdateRunSource() end
end

-- The way shown is taken back, in this frame: the state first, then its line
-- is hidden (all of it, without pieces of work), then the run window.
local function Withdraw()
    if not nav then return end
    keeping = false
    if nav.core.state == "net" then
        nav.core.state = "line"
        nav.core.on = false
        nav.source = nil
        if nav.state == "net" then nav.state = "line" end
        if drawer then drawer.Hide() end
        Told()
    end
end

local function SetState(state)
    if nav.state ~= state then
        nav.state = state
        Told()
    end
end

local function CancelRequest()
    if req.active then
        req.active = false
        diag.cancelled = diag.cancelled + 1
    end
    keeping = false
end

local BuildAnew, Rebuild

-- What changed in the pieces (Paths.lua tells it)
local function OnPaths(mapID, kind)
    if not nav or (mapID and mapID ~= net.mapID) then return end
    local t0 = Clock()
    if kind == "new" then
        -- a new piece: the copy of a build going on starts again; 50 of them: a new net
        net.fresh = net.fresh + 1
        if net.building then
            M.BuildDisturbed(ctx)
        elseif net.fresh >= REBUILD_PIECES and net.mapID then
            if net.ready then Rebuild() else BuildAnew() end
        end
    else
        -- a piece may go another way now, or pieces are gone: nothing found in the old net counts any more
        diag.invalid = diag.invalid + 1
        net.epoch = net.epoch + 1
        Withdraw()
        CancelRequest()
        nav.asked = false
        if net.mapID then BuildAnew() end
    end
    Spend(Clock() - t0)
end

-- A net from nothing: at the start, in another zone, after pieces changed
-- their direction or went. Whatever net was in use is not used any more.
BuildAnew = function()
    net.ready, net.building, net.over, net.fresh = false, false, nil, 0
    if ctx then M.Drop(ctx) end
    local e = ns.PathsZone and ns.PathsZone(net.mapID)
    if not e then return end -- (no piece in this zone yet: no net; 50 new ones build it)
    ctx = ctx or M.New()
    M.BuildStart(ctx, e)
    net.building, net.t0 = true, GetTime()
    diag.builds = diag.builds + 1
    work:Show()
end

-- The ordinary new build (50 new pieces): the net in use stays in use
-- until the new one is done; it is written into the other set
Rebuild = function()
    local e = ns.PathsZone and ns.PathsZone(net.mapID)
    if not (e and ctx) then return BuildAnew() end
    net.fresh = 0
    M.BuildStart(ctx, e)
    net.building, net.t0 = true, GetTime()
    diag.builds = diag.builds + 1
    work:Show()
end

-- No S1 work any more (the run ended, the option is off, nothing is shown):
-- the way is taken back and hidden in this frame, the net's lists are let go.
-- (Taking the hidden dots off the maps goes on in small steps, Route.lua.)
local function Release()
    if not nav then return end
    Withdraw()
    CancelRequest()
    nav.state = "none"
    nav, navRun = nil, nil
    read.state, read.points, read.n, read.source = "none", nil, 0, nil
    ctx = nil
    net.mapID, net.ready, net.building, net.over, net.fresh = nil, false, false, nil, 0
    if ns.PathsListen then ns.PathsListen(nil) end
    Told()
    if not (drawer and drawer.Pending()) then work:Hide() end
end

local function Begin(run)
    nav = { core = M.NewNav(), state = "none", asked = false, node = nil, nx = nil, ny = nil, tmap = nil, source = nil, stamp = -1 }
    navRun = run
    net.mapID, net.ready, net.building, net.over, net.fresh = nil, false, false, nil, 0
    req.active, keeping = false, false
    if ns.PathsListen then ns.PathsListen(OnPaths) end
end

-- Does the run show its way at all? The option, a target, and the line's head or the arrow shown.
local function Wanted(run)
    local db = ns.db
    if not (db and run and run == ns.run) or db.routeWaysOff then return false end
    if not (run.targetPoint and run.target and run.path) then return false end
    if not db.arrowHidden then return true end
    if ns.RouteLineLength and ns.RouteLineLength() == "off" then return false end
    return not (db.routeLineHidden and db.routeLineMiniHidden)
end

-- Is the way shown the way to the run's target of now? (every reader asks this first)
local function Valid(run)
    if not nav or nav.core.state ~= "net" then return false end
    local tp = run and run == navRun and run == ns.run and run.targetPoint
    local node = tp and tp.node
    if node and node == nav.node and node == run.target and tp.mapID == nav.tmap and node.x == nav.nx and node.y == nav.ny
        and run.instance == nav.inst and not (ns.db and ns.db.routeWaysOff) then
        return true
    end
    Withdraw()
    -- (the next tick takes whatever node the run has then for a new one - also the old one again:
    -- nothing of the way that was shown is used for it)
    nav.node = nil
    return false
end

local function Follow(px, py)
    local now = GetTime()
    if nav.stamp ~= now then
        nav.stamp = now
        M.Progress(nav.core, px, py)
        read.seg, read.pos = nav.core.seg, nav.core.pos
    end
    return nav.core.on
end

local function SourceText(percent)
    if percent > 0 then return (L["Path: your ridden ways (%d%% guessed)"]):format(percent) end
    return L["Path: your ridden ways"]
end

local function Ask(px, py, instance)
    if req.active then CancelRequest() end
    -- where you are in the zone, as Paths reads it (the squares are cut from that)
    local mapID, zx, zy
    if ns.GetPlayerPos then mapID, zx, zy = ns.GetPlayerPos() end
    if mapID ~= net.mapID or type(zx) ~= "number" or type(zy) ~= "number" then return end
    local w, h = net.w, net.h
    local ax, ay = zx * w, zy * h
    req.active, req.stage = true, "query"
    req.gen, req.node, req.nx, req.ny, req.tmap = gen, nav.node, nav.nx, nav.ny, nav.tmap
    req.map, req.inst, req.rev, req.epoch = net.mapID, instance, net.rev, net.epoch
    req.field = floor(ay / TILE) * GRID + floor(ax / TILE)
    req.pwx, req.pwy, req.twx, req.twy = px, py, navRun.targetPoint.wx, navRun.targetPoint.wy
    req.t0, req.i = GetTime(), 0
    nav.asked = true
    diag.requests = diag.requests + 1
    M.QueryStart(ctx, nav.core, ax, ay, nav.nx * w, nav.ny * h, nav.core.have)
    work:Show()
end

-- The one place that asks. Called at every head tick of the run with what
-- Route read of your place (world yards and instance, or nil). Returns the
-- state for the line's head: "net", "line" or "none"; nil when S1 does nothing.
local function Tick(run, px, py, instance)
    if not Wanted(run) then
        if nav then Release() end
        return nil
    end
    if nav and navRun ~= run then Release() end
    if not nav then Begin(run) end
    local tp = run.targetPoint
    local node = tp.node
    -- readable first: nothing is compared, rounded or worked out before
    if not px or AnySecret("ways", px, py, instance) or type(px) ~= "number" or type(py) ~= "number" then
        Withdraw()
        CancelRequest()
        nav.asked = false -- (readable again: asked anew)
        SetState("none")
        return "none"
    end
    local nx, ny, tmap = node.x, node.y, tp.mapID
    -- the zone you are in: the game's map of you while it is the node's zone (a number, nothing is
    -- made for it); else where Paths says you are (it knows the zone under a continent's map)
    local mapID = ns.PlayerMap and ns.PlayerMap()
    if mapID ~= tmap and ns.GetPlayerPos then mapID = ns.GetPlayerPos() end
    if instance ~= run.instance or AnySecret("ways", nx, ny, tmap) or type(nx) ~= "number" or type(ny) ~= "number"
        or type(tmap) ~= "number" or type(mapID) ~= "number" then
        Withdraw()
        CancelRequest()
        nav.asked = false
        SetState(instance == run.instance and "line" or "none")
        return nav.state
    end
    -- another node, or the same node at another place: nothing of the old one is kept
    if nav.node ~= node or nav.nx ~= nx or nav.ny ~= ny or nav.tmap ~= tmap or nav.inst ~= instance then
        Withdraw()
        CancelRequest()
        nav.node, nav.nx, nav.ny, nav.tmap, nav.inst = node, nx, ny, tmap, instance
        nav.core.have, nav.asked = false, false
    end
    -- the net is the one of the zone you are in, and only that zone's
    local w, h
    if ns.PathsZoneSize then w, h = ns.PathsZoneSize(mapID) end
    if mapID ~= tmap or not w then
        -- the node lies on another map (or this one has no size): the straight line as before
        Withdraw()
        CancelRequest()
        nav.asked = false
        if net.mapID and net.mapID ~= mapID then
            net.mapID, net.ready, net.building = nil, false, false
            if ctx then M.Drop(ctx) end
        end
        SetState("line")
        return "line"
    end
    if net.mapID ~= mapID then
        -- another zone: what was found in the old one is gone at once
        net.epoch = net.epoch + 1
        Withdraw()
        CancelRequest()
        nav.asked = false
        net.mapID, net.w, net.h = mapID, w, h
        BuildAnew()
    end
    if nav.core.state == "net" then
        -- further off the way than 25 yd: it is taken back, and asked for anew from here
        if not Follow(px, py) then
            Withdraw()
            nav.asked = false
        end
    end
    if net.ready and not nav.asked and not net.over then Ask(px, py, instance) end
    SetState(nav.core.state == "net" and "net" or "line")
    return nav.state
end

-- A request is done: is its mark still the one of now?
local function MarkHolds(anySquare)
    local run = navRun
    local tp = run and run == ns.run and run.targetPoint
    if not (nav and tp and req.gen == gen and tp.node == req.node and tp.node.x == req.nx and tp.node.y == req.ny
        and tp.mapID == req.tmap and req.rev == net.rev and req.epoch == net.epoch and req.map == net.mapID
        and run.instance == req.inst) then
        return false
    end
    if anySquare then return true end
    -- the square you are in now is the one you asked from
    local mapID, zx, zy
    if ns.GetPlayerPos then mapID, zx, zy = ns.GetPlayerPos() end
    if type(mapID) ~= "number" or type(zx) ~= "number" or type(zy) ~= "number" or mapID ~= req.map then return false end
    return floor(zy * net.h / TILE) * GRID + floor(zx * net.w / TILE) == req.field
end

local function Drop()
    req.active = false
    diag.dropped = diag.dropped + 1
    if nav then nav.asked = false end
end

-- One step of the work that is due. Returns the kind of work and the
-- operations used, or nil when there is none.
--   The order: a request goes first (it is short, and a way is waited for);
--   then the dots of a way that is shown; then a build (the ordinary one
--   works in the background - the net in use stays in use); last the hidden
--   dots that are to come off the maps.
local function Step()
    if not req.active then
        -- (first a request - below; then the dots of a way that is shown; then a build; last the hidden dots)
        local pending = drawer and drawer.Pending()
        if pending == 2 then return 202, drawer.Step(Ops(202, 6)) end
        if not net.building then
            if pending then return 203, drawer.Step(Ops(203, 20)) end
            return
        end
        local job = ctx.job
        local kind = job.phase
        local used = M.BuildStep(ctx, Ops(kind, 400))
        if job.done then
            net.building = false
            if job.over then
                -- above the limits: no net, the straight line
                net.ready, net.over = false, job.over
                diag.over = diag.over + 1
                M.Drop(ctx)
                Withdraw()
                CancelRequest()
            else
                net.ready, net.rev = true, net.rev + 1
                if nav then nav.asked = false end
            end
        end
        return kind, used
    end
    do
        if req.stage == "query" then
            local q = ctx.q
            local kind = 100 + q.phase
            local used = M.QueryStep(ctx, Ops(kind, 200))
            if q.done then
                if q.result == "net" then
                    req.stage, req.i = "world", 0
                elseif nav.core.state == "net" and q.reason ~= "near" and MarkHolds(true) then
                    -- no new way for the node whose way is shown: the way shown stays, if the net of now allows all of its rest
                    req.stage, keeping = "keep", true
                    M.KeepStart(ctx, nav.core)
                else
                    req.active = false
                    if nav.core.state == "net" then Withdraw() end
                end
            end
            return kind, used
        elseif req.stage == "world" then
            -- the points of the way in the coordinates the line is drawn in (as the head is: HereBeDragons, world yards)
            local b = nav.core.back
            local x, y, wx, wy, n = b.x, b.y, b.wx, b.wy, b.n
            local i = req.i
            local last = i + Ops(200, 16)
            if last > n then last = n end
            local w, h, mapID = net.w, net.h, req.map
            for j = i + 1, last do
                if j == 1 then
                    wx[j], wy[j] = req.pwx, req.pwy
                elseif j == n then
                    wx[j], wy[j] = req.twx, req.twy
                else
                    local ax, ay = HBD:GetWorldCoordinatesFromZone(x[j] / w, y[j] / h, mapID)
                    if type(ax) ~= "number" or type(ay) ~= "number" then
                        req.active = false
                        return 200, last - i
                    end
                    wx[j], wy[j] = ax, ay
                end
            end
            req.i = last
            if last == n then
                if MarkHolds() then
                    -- published: the buffers change places; what was shown before is hidden first
                    if nav.core.state == "net" and drawer then drawer.Hide() end
                    M.Publish(nav.core)
                    read.pub = read.pub + 1
                    nav.stamp = -1
                    nav.source = SourceText(nav.core.front.percent)
                    req.active = false
                    read.seg, read.pos = 1, 0
                    nav.state = "net"
                    Told()
                else
                    Drop()
                end
            end
            return 200, last - i + 1
        else -- "keep"
            local k = ctx.keepJob
            local used = M.KeepStep(ctx, Ops(201, 100))
            if k.done then
                req.active, keeping = false, false
                if k.ok and nav.core.state == "net" and nav.core.on and MarkHolds(true) then
                    nav.core.front.percent = k.percent
                    nav.source = SourceText(k.percent)
                    Told()
                else
                    Withdraw()
                end
            end
            return 201, used
        end
    end
end

local function Work()
    local t0 = Clock()
    Frame()
    local now = GetTime()
    if net.building and now - net.t0 > BUILD_SECONDS then
        net.building, net.ready, net.over = false, false, "time"
        diag.late = diag.late + 1
        if ctx then M.Drop(ctx) end
        Withdraw()
        CancelRequest()
    end
    if req.active and now - req.t0 > REQUEST_SECONDS then
        req.active, keeping = false, false
        diag.late = diag.late + 1
        Withdraw()
    end
    local idle, steps = false, 0
    while frameSum + STEP_MS <= FRAME_MS - RESERVE_MS and steps < STEPS_MAX do
        steps = steps + 1
        local kind, used = Step()
        if not kind then
            idle = true
            break
        end
        diag.ops = diag.ops + used
        local t1 = Clock()
        local ms = t1 - t0
        t0 = t1
        Spend(ms)
        Tune(kind, used, ms)
    end
    if idle then work:Hide() end
    Spend(Clock() - t0)
end
work:SetScript("OnUpdate", Wrap("Ways", Work))

---------------------------------------------------------------------------
-- What the rest of the addon calls
---------------------------------------------------------------------------
-- Route.lua, at every head tick of a run (the one place that asks)
ns.WaysTick = Wrap("Ways", function(run, px, py, instance)
    local t0 = Clock()
    local state = Tick(run, px, py, instance)
    Spend(Clock() - t0)
    return state
end)

-- A run started or stopped: whatever was found belongs to the run before
ns.WaysRunChanged = Wrap("Ways", function()
    local t0 = Clock()
    gen = gen + 1
    Release()
    Spend(Clock() - t0)
end)

-- What is shown now. Always an answer, the same table each time:
--   state   "net", "line" or "none"
--   points  with "net": the way's buffer (wx, wy: the points in world yards; cum: how far along each is)
--   n       its points;  yards: its length (you - net - node);  cost: the search's cost (to look at only)
--   source  "net" or "line";  guessed: yards of guessed edges in it;  percent: their share of the way of the net
--   seg, pos  where you are on it;  serial: counts whenever what is shown changes;  pub: at every new way
ns.WaysRead = Wrap("Ways", function(run)
    local t0 = Clock()
    if nav and run == navRun and Valid(run) then
        local b = nav.core.front
        read.state, read.points, read.n, read.yards, read.cost = "net", b, b.n, b.yards, b.cost
        read.source, read.guessed, read.percent = "net", b.guess, b.percent
        read.seg, read.pos = nav.core.seg, nav.core.pos
    else
        local state = nav and run == navRun and nav.state or "none"
        if state == "net" then state = "line" end
        read.state, read.points, read.n, read.yards, read.cost = state, nil, 0, 0, 0
        read.source, read.guessed, read.percent = state == "line" and "line" or nil, 0, 0
    end
    Spend(Clock() - t0)
    return read
end)

-- The arrow (UI.lua): where it turns to, in world yards - the point 30 yd
-- ahead along the way shown. nil: the node itself (no way of the net, the
-- rest is shorter, or the point lies on the last bit to the node). Only the
-- angle is this point's; the distance, the name, "Here!" and the arrival stay
-- with the node. Reading it moves the progress on (once a frame, whoever
-- reads first); more than 25 yd off the way, the way is taken back here and
-- the head tick asks anew.
ns.WaysArrow = Wrap("Ways", function(run, px, py)
    if not (nav and run == navRun) then return end
    local t0 = Clock()
    local x, y
    if Valid(run) and not AnySecret("ways", px, py) and type(px) == "number" and type(py) == "number" then
        if Follow(px, py) then
            x, y = M.ArrowPoint(nav.core)
        else
            Withdraw()
            nav.asked = false
        end
    end
    Spend(Clock() - t0)
    return x, y
end)

-- The line of the run window (UI.lua): a text kept until the way changes, or nil
ns.WaysSource = function(run)
    if not (nav and run == navRun and run == ns.run) or (ns.db and ns.db.routeWaysOff) then return nil end
    if nav.core.state == "net" then
        if Valid(run) then return nav.source end
        return L["Path: straight line"]
    end
    if nav.state == "line" then return L["Path: straight line"] end
    return nil
end

-- Route.lua has dots to place or to take off: the work goes on
ns.WaysWork = function() work:Show() end
-- Route.lua's own S1 work outside the steps (hiding a line, starting one) counts for the frame too
ns.WaysNow = Clock
ns.WaysSpend = Spend

-- for /gcr perf and the tests: the counters, and what is going on
ns.WaysDiag = function() return diag, frameSum end
ns.WaysState = function()
    return nav, net, req, ctx, ops, gen, work
end
ns.WaysLimits = function() return FRAME_MS, RESERVE_MS, STEP_MS, REQUEST_SECONDS, BUILD_SECONDS, REBUILD_PIECES end
