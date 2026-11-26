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
        -- (0.2.4 a7, S1.1 B1) the centre line's lists too, the back one of this navigation
        local c = q.nav.cb
        local cx, cy, craw, ckey, ckind, ccap = c.x, c.y, c.raw, c.key, c.kind, c.cap or 0
        local cbx, cby, ccv, cdk, cdcum = c.bx, c.by, c.cv, c.dk, c.dcum
        while (cap < n or ccap < n) and used < budget do
            if cap < n then
                cap = cap + 1
                rx[cap], ry[cap], rk[cap], keep[cap] = 0, 0, 0, 0
            end
            if ccap < n then
                ccap = ccap + 1
                cx[ccap], cy[ccap], craw[ccap], ckey[ccap], ckind[ccap] = 0, 0, 0, 0, 0
                cbx[ccap], cby[ccap], ccv[ccap], cdk[ccap], cdcum[ccap] = 0, 0, -1, 0, 0
            end
            used = used + 1
        end
        Q.rawCap, c.cap = cap, ccap
        if cap < n or ccap < n then return used end
        q.stage, q.i, q.at = 1, n - 1, q.exit
        q.guessYards = 0
        rx[1], ry[1], rk[1] = q.px, q.py, -1
        rx[n], ry[n], rk[n] = q.tx, q.ty, -1
        cx[1], cy[1], ckey[1], ckind[1] = q.px, q.py, -1, -1
        cx[n], cy[n], ckey[n], ckind[n] = q.tx, q.ty, -1, -1
        c.stamp = c.stamp + 1 -- (a new way in this buffer: no world place put in before counts)
        return used + 1
    elseif q.stage == 1 then -- the points, from the end
        local u, at, guess = q.at, q.i, q.guessYards
        local c = q.nav.cb
        local cx, cy, ckey, ckind = c.x, c.y, c.key, c.kind
        while at >= 2 and used < budget do
            rx[at], ry[at], rk[at] = x[u], y[u], key[u]
            cx[at], cy[at], ckey[at], ckind[at] = x[u], y[u], key[u], -1
            if at > 2 then
                local p = par[u]
                local kind = flag[pedge[u]] % 8
                ckind[at] = kind -- (the edge from the square before into this one)
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
        do
            local c = q.nav.cb
            c.raw[1], c.dn, c.dk[1], c.dcum[1] = 0, 1, 1, 0
        end
        return used + 1
    end
    local i, n, yards = q.i, q.rawN, q.yards
    local c = q.nav.cb
    local craw, dk, dcum, dn = c.raw, c.dk, c.dcum, c.dn
    while i < n and used < budget do
        local dx, dy = rx[i + 1] - rx[i], ry[i + 1] - ry[i]
        if i >= 2 then
            -- (S1.1 B1) the point i is drawn unless it lies on the point drawn before it or on the next one
            -- (you or the node on a middle: closer than a thousandth of a yard - they come from the map's
            -- fractions), or exactly on the straight line between them (F4 §B; the middles are exact)
            local k = dk[dn]
            local ax, ay = rx[i] - rx[k], ry[i] - ry[k]
            if not (ax * ax + ay * ay < 1e-6 or dx * dx + dy * dy < 1e-6 or (ax * dy - ay * dx == 0 and ax * dx + ay * dy > 0)) then
                dn = dn + 1
                dk[dn], dcum[dn] = i, craw[i]
            end
        end
        yards = yards + sqrt(dx * dx + dy * dy)
        i = i + 1
        craw[i] = yards
        used = used + 1
    end
    c.dn = dn
    q.i, q.yards = i, yards
    if i < n then return used end
    do
        dn = dn + 1
        dk[dn], dcum[dn], c.dn = n, yards, dn
        c.n, c.len, c.head, c.tail = n, yards, q.entryD, q.exitD
        local v = c.view
        v.n, v.len, v.tail = dn, yards, q.exitD
    end
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

---------------------------------------------------------------------------
-- (0.2.4 a7, S1.1 B1) The centre line of a way: the way of the net as it was
-- found - you, the middle of every square, the node - with nothing left out.
-- It is safe to show: a stretch between the middles of two squares side by
-- side lies in those two squares and crosses the side or the corner between
-- them, also on a guessed edge. The navigation never reads it (it reads the
-- a5 buffer, front, as before); the line on the maps and the arrow do.
--   Written by the way back (phase back) for free: the points, their keys,
--   the kind of the edge into each point (-1: the first and last bit), and
--   along the way the yards so far (raw). Two of them, as the a5 buffers:
--   a request writes into cb, a published way swaps cb and cf.
--   World yards only when a reader asks for a point (wx, wy fill themselves
--   from x, y - HereBeDragons is affine within a zone): the arrow needs a few
--   points at once, the maps the ones they draw.
---------------------------------------------------------------------------
M.convs = 0 -- (the tests, /gcr perf: points put into world yards so far)
local function NewCentre()
    -- x, y, raw, key, kind: every point of the way (n of them). The line drawn passes over the points
    -- that lie exactly on the straight line between their neighbours and those on the point before them
    -- (F4 §B: "kollineare Zwischenpunkte dürfen beim Zeichnen übersprungen werden"): dk[k] is the point
    -- of the k-th of the dn points drawn, dcum[k] its yards along the way. The readers (the maps, the
    -- arrow) get `view`: wx, wy, cum, n, len, tail of the line drawn, as the a5 buffer has them.
    -- bx, by: the world places put in so far (cv[i] == stamp: put in for the way written now).
    local c = { x = {}, y = {}, raw = {}, key = {}, kind = {}, dk = {}, dcum = {}, dn = 0, bx = {}, by = {}, cv = {}, stamp = 0,
        n = 0, len = 0, tail = 0, head = 0, conv = nil, map = 0, w = 1, h = 1, pwx = 0, pwy = 0, twx = 0, twy = 0 }
    local function Fill(i)
        local x, y
        if not c.conv then
            x, y = c.x[i], c.y[i] -- (no conversion given: the tests' zone yards, as M.Query does it)
        elseif i == 1 then
            x, y = c.pwx, c.pwy -- (you and the node: their world places as the a5 buffer has them)
        elseif i == c.n then
            x, y = c.twx, c.twy
        else
            x, y = c.conv(c.x[i] / c.w, c.y[i] / c.h, c.map)
            M.convs = M.convs + 1
        end
        c.bx[i], c.by[i], c.cv[i] = x, y, c.stamp
    end
    -- (the view's wx, wy stay empty: every read goes through them - nothing grows while you ride)
    local v = { wx = {}, wy = {}, cum = c.dcum, n = 0, len = 0, tail = 0, centre = c }
    setmetatable(v.wx, { __index = function(_, k)
        if k >= 1 and k <= c.dn then
            local i = c.dk[k]
            if c.cv[i] ~= c.stamp then Fill(i) end
            return c.bx[i]
        end
    end })
    setmetatable(v.wy, { __index = function(_, k)
        if k >= 1 and k <= c.dn then
            local i = c.dk[k]
            if c.cv[i] ~= c.stamp then Fill(i) end
            return c.by[i]
        end
    end })
    c.view = v
    return c
end
M.NewCentre = NewCentre

-- The state of one navigation: the buffer shown (front) and the one a
-- request writes into (back), the progress along the way shown, and the rest
-- of the way last shown as two numbers (for the rule of length). cf, cb: the
-- centre lines of front and back (S1.1); gen: counts at every way published.
function M.NewNav()
    return {
        state = "line", seg = 1, pos = 0, on = false,
        front = NewBuffer(), back = NewBuffer(),
        have = false, rest = 0, offD = 0,
        cf = NewCentre(), cb = NewCentre(), gen = 0,
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
    -- (0.2.4 a7, S1.1 B1) the centre line of the same way, in the same step: a swap, no copy
    nav.cb, nav.cf = nav.cf, nav.cb
    nav.gen = nav.gen + 1
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
    k.duty = false -- (0.2.4 a7, S1.1 B4) an edge of the rest went from smoothable to fixed or back (a9: fixed is CON only)
    return k
end

-- (0.2.4 a9, F4.6 §1) the anchor duty of an edge kept went from fixed to smoothable or back: only CON is fixed -
-- GREV -> CON (or OBS/REV -> CON) and back change it, OBS <-> GREV <-> REV do not. The guessed share below still
-- counts GREV as guessed (unchanged).
function M.DutyChanged(old, new) return (old == CON) ~= (new == CON) end

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
    local ck = k.nav.cf.kind -- (S1.1 B4: the kinds of the centre line shown, point i + 1 has the edge i -> i + 1)
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
        -- (0.2.4 a7, S1.1 B4, F3 §5, F4.1 §A) the edge's kind in the new net: does it have to stay the straight
        -- stretch between its middles now, or no longer? The caller lets the thread go at the first change (T1).
        -- The centre line takes the new kind at once - it is drawn the same whatever the kinds, and a thread
        -- is only found for them again after the check (T2); a rest not kept is taken back.
        if M.DutyChanged(ck[i + 1], kind) then k.duty = true end
        ck[i + 1] = kind
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

---------------------------------------------------------------------------
-- (0.2.4 a7, S1.1 B2) The thread: the line of a way pulled tight through its
-- squares, as a thread through a tube (F3 §3, F4 §C, §F). Only the maps and
-- the arrow show it; the navigation never reads it.
--   Between two squares of the way lies their passage: the side they share
--   (a straight step) or the corner they share (a diagonal step).
--   Anchors are points the thread goes through: the middles of the first and
--   the last square (the bits from you and to the node stay straight), both
--   middles of a guessed edge (CON, GREV: it stays the straight stretch from
--   middle to middle), the corner of every diagonal step, and protective
--   anchors (below). From anchor to anchor the shortest line through the
--   passages in their order is found with a funnel (an apex and the left and
--   the right side of what can be seen from it through the passages so far;
--   when a side crosses the other one, that side's point is a point of the
--   thread and the funnel starts again from it). A side that runs through the
--   apex is passed there.
--   Events: where the thread crosses each passage, the first point on it
--   after the event before, with the yards along the thread (s) and along
--   the way of the net (r: the middle of the side, the corner). Two passages
--   at one point are only allowed at a corner the thread turns around: two
--   straight steps on two sides at right angles (an L). Three or more (a U
--   cut short), a diagonal's corner with another passage, the same side
--   crossed back: the middles of the squares between the first and the last
--   of them become protective anchors and the thread is found anew from the
--   anchor before them. The events are checked as the thread is written (a
--   passage once a point of the thread lies beyond it; the rest when the
--   stretch is done), the group of the stretch before included (the check
--   goes over the borders).
--   (0.2.4 a8, Codex M1) Looking ahead, the funnel sees where the pattern of
--   the steps could make the thread break the rules. A protective anchor only
--   where the thread's events are sure to break them: at once where the
--   pattern alone makes it sure (a diagonal's corner with the passage after
--   it, the same side back); for a U or a side and then a diagonal over its
--   end - the thread may run along the first side and cross the passages at
--   points apart - only a proposal: decided when the funnel comes to the
--   middle after the first side (it writes the shared point next, straight
--   from the thread's last point), else when the thread is written at that
--   point (then found anew from the funnel's state kept there), else by the
--   events, repaired from the last state kept before the first new anchor -
--   one the funnel kept before it looked as far on as that anchor - or from
--   the anchor before. The thread is never longer for the look ahead than
--   the one the events alone find.
--   Every piece of work is booked on one counter before it is done: a
--   passage or point looked at by the funnel or for the events, a square made
--   an anchor, a point of the thread given back or written. At 4 times the
--   passages the thread is given up (the centre line stays).
--   No table is made: the job's lists are written over and kept.
---------------------------------------------------------------------------
local THREAD_TOL = 0.01 -- yards: two events at one point (F4.1 §C)
local ON_EPS = 1e-7     -- yards: a point on a passage (the thread's points are exact, its crossings nearly)
local HALF = TILE / 2
-- (0.2.4 a9, F4.6 §2) Two margins at the ends of a straight passage (a side): the funnel works on sides cut by
-- 6 yd at both ends (the construction margin); the finished drawing - arcs and all - must cross every side
-- inside the side cut by 4 yd (the check margin). A diagonal's corner stays a point.
local BUILD_MARGIN, CHECK_MARGIN = 6, 4
M.buildMargin, M.checkMargin = BUILD_MARGIN, CHECK_MARGIN
M.sideShare = (HALF - BUILD_MARGIN) / TILE -- (Slot, Ends: half a side less the margin, as a share of the step)

-- One job per navigation. t: the thread as a line (x, y, raw = yards along the thread; the points drawn
-- and the view as the centre line has them). Per point: vu its slot (2j: the middle of square j, 2j + 1:
-- the step from square j to j + 1; 2: you, 2n: the node), va 1 for an anchor. Per event: s, r, its point
-- (ex, ey), its slot (eu) and kind (ek 0: a corner, 1: a side across x, 2: a side across y, 3: an anchor's
-- middle - the anchors' pairs (r, s) are in the list too, B3 maps with them).
function M.NewThread()
    return {
        t = NewCentre(), vu = {}, va = {},
        es = {}, er = {}, ex = {}, ey = {}, eu = {}, ek = {}, en = 0, gs = 1,
        prot = {}, stamp = 0,
        sv = {}, pc = 0, pslot = -1, far = 0, -- (0.2.4 a8, Codex M1) the proposals' kept states, SNAP values each; how many; one seen; the funnel's furthest slot
        -- (0.2.4 a9) the finished drawing with its arcs (f), an arc's points (qx, qy), its crossings' yards (fs); the
        -- corner drawn next (ai), what the arcs made shorter so far (ad), the first event not passed yet (ae), arcs
        -- drawn, corners left sharp by the check
        f = NewCentre(), qx = {}, qy = {}, fs = {}, fx = {}, fy = {}, ai = 0, ad = 0, ae = 0, arcs = 0, sharp = 0, tries = 0,
        -- (0.2.4 a9 R1, Codex M1) the call's pieces left, units carried over to the next call, pieces worked (pairs,
        -- points, checks, a repair's squares and points; the tests look at it), the pieces of the arcs that book no unit (free); the arcs' stage and its numbers;
        -- a repair's squares (from rj to rjb, of the group from square rja), anchors made, the point it went back to
        left = 0, debt = 0, work = 0, free = 0, ast = 0, apto = 0, anext = 0, aph = 1, apn = 1, athen = 0, an2 = 0,
        asv = 0, asa = 0, asb = 0, avx = 0, avy = 0, rja = 0, rj = 0, rjb = 0, radd = 0, rk = 0, rfirst = 0,
        c = nil, gen = -1, state = "none", reason = nil, used = 0, limit = 0, repairs = 0,
        phase = 0, u = 0, ax = 0, ay = 0, au = 0, lx = 0, ly = 0, lu = 0, rx = 0, ry = 0, ru = 0,
        sk = 0, wu = 0, wk = 0, wt = 0, fk = 0,
    }
end

-- (0.2.4 a9, F4.5 §2, F4.6 §1) only a CON edge is fixed (the straight stretch from middle to middle, anchored):
-- a GREV edge joins two squares side by side, the thread stays in their tube - it is smoothed like OBS and REV
local function Fixed(kind) return kind == CON end
M.Fixed = Fixed
local function IsAnchor(T, j)
    local c = T.c
    local kind = c.kind
    return j == 2 or j == c.n - 1 or T.prot[j] == T.stamp or Fixed(kind[j]) or Fixed(kind[j + 1])
end
M.ThreadAnchor = IsAnchor

-- What lies at slot u: 0 nothing to pass (a middle that is no anchor); 1 a point to pass, x, y (an anchor's
-- middle, a diagonal's corner); 2 a side, its left and its right end looking along the way; -1 the two
-- squares are not side by side (the thread is not made, the centre line stays)
local function Slot(T, u)
    local c = T.c
    local x, y = c.x, c.y
    local j = floor(u / 2)
    if u % 2 == 0 then
        if IsAnchor(T, j) then return 1, x[j], y[j] end
        return 0
    end
    local dx, dy = x[j + 1] - x[j], y[j + 1] - y[j]
    if (dx ~= 0 and dx ~= TILE and dx ~= -TILE) or (dy ~= 0 and dy ~= TILE and dy ~= -TILE) or (dx == 0 and dy == 0) then return -1 end
    local mx, my = x[j] + dx / 2, y[j] + dy / 2
    if dx ~= 0 and dy ~= 0 then return 1, mx, my end
    -- left of the way: (-dy, dx), half a side less the construction margin at each end (0.2.4 a9, F4.6 §2)
    local hx, hy = -dy * M.sideShare, dx * M.sideShare
    return 2, mx + hx, my + hy, mx - hx, my - hy
end

-- The two ends of the passage of step j (a corner: twice the same point); nil past the way's net part.
-- (0.2.4 a9, F4.6 §2) A side is cut by the construction margin at both ends: the funnel, the events and the
-- look ahead all work on the same shortened passages.
local function Ends(c, j)
    if j < 2 or j > c.n - 2 then return end
    local x, y = c.x, c.y
    local dx, dy = x[j + 1] - x[j], y[j + 1] - y[j]
    local mx, my = x[j] + dx / 2, y[j] + dy / 2
    if dx ~= 0 and dy ~= 0 then return mx, my, mx, my, dx, dy end
    local hx, hy = -dy * M.sideShare, dx * M.sideShare
    return mx + hx, my + hy, mx - hx, my - hy, dx, dy
end

-- (0.2.4 a8, Codex M1) A proposal: the funnel's state now, after the proposal's first side, before the middle
-- of the square after it (slot T.u) - the place the thread is found anew from when the rules are found broken
-- after it. Nothing of the thread up to here depends on an anchor at that square or after it.
-- What is kept with it (for the check when the thread is written at the point, Confirm below): the step j,
-- how many squares after it would be anchors (1: a side, then a diagonal over its end; 2: a U), the point the
-- passages share (px, py), the other end of the first side (qx, qy), and how far the funnel had looked (far):
-- a point it wrote while looking at a slot further on may depend on what lies there - the kept state holds
-- for anchors further on than that only.
local SNAP = 24
local function Propose(T, j, squares, px, py, qx, qy)
    local sv = T.sv
    -- (the list goes by the passage, forwards: one kept for this passage or one after it - before the funnel
    -- went back to a point it wrote - is let go; the funnel comes to it again and keeps it anew)
    local i = T.pc
    while i > 0 and sv[(i - 1) * SNAP + 1] > T.u do i = i - 1 end
    -- (one kept here before the funnel looked further on and came back: it holds for these squares, the new
    -- state would not - it stays)
    if i > 0 and sv[(i - 1) * SNAP + 1] == T.u and sv[(i - 1) * SNAP + 24] < T.u then
        T.pc = i
        return
    end
    while i > 0 and sv[(i - 1) * SNAP + 1] >= T.u do i = i - 1 end
    local o = i * SNAP
    T.pc = i + 1
    sv[o + 1], sv[o + 2], sv[o + 3], sv[o + 4], sv[o + 5] = T.u, T.t.n, T.ax, T.ay, T.au
    sv[o + 6], sv[o + 7], sv[o + 8], sv[o + 9], sv[o + 10], sv[o + 11] = T.lx, T.ly, T.lu, T.rx, T.ry, T.ru
    sv[o + 12], sv[o + 13], sv[o + 14], sv[o + 15], sv[o + 16], sv[o + 17] = T.en, T.gs, T.wu, T.wk, T.wt, T.sk
    sv[o + 18], sv[o + 19], sv[o + 20], sv[o + 21], sv[o + 22], sv[o + 23] = j, squares, px, py, qx, qy
    sv[o + 24] = T.far
end
-- A proposal seen while the funnel takes step j's side: kept when the funnel comes to the middle after it (the
-- funnel's start of a piece of work, FunnelSlot). Only when the squares it would make anchors are none yet.
local function Pend(T, j, squares, px, py, qx, qy)
    for q = j + 1, j + squares do
        if IsAnchor(T, q) then return end
    end
    T.pslot, T.pj, T.pq, T.ppx, T.ppy, T.pqx, T.pqy = 2 * (j + 1), j, squares, px, py, qx, qy
end
-- back to proposal i (of this stretch or one before): the funnel, the thread's points and the events as they
-- were then; the proposals after it are let go
local function Resume(T, i)
    local sv, o = T.sv, (i - 1) * SNAP
    T.pc, T.pslot = i, -1
    T.u, T.t.n, T.ax, T.ay, T.au = sv[o + 1], sv[o + 2], sv[o + 3], sv[o + 4], sv[o + 5]
    T.lx, T.ly, T.lu, T.rx, T.ry, T.ru = sv[o + 6], sv[o + 7], sv[o + 8], sv[o + 9], sv[o + 10], sv[o + 11]
    T.en, T.gs, T.wu, T.wk, T.wt, T.sk = sv[o + 12], sv[o + 13], sv[o + 14], sv[o + 15], sv[o + 16], sv[o + 17]
    T.far, T.phase = sv[o + 24], 1
end

-- (looked ahead from step j, in the funnel's piece of work for it) The thread could pass two passages
-- of the way at one point they share - and then the square between them with no length. Allowed is
-- only the L (two sides at right angles around a corner); a diagonal's corner on another passage, the
-- same side or corner passed back, three sides around one point (a U) are not (F4 §C).
-- (0.2.4 a8, Codex M1) Only where the thread's events are sure to break the rules is the square between
-- an anchor at once:
--   - a diagonal's corner and the passage after it on the same point: the thread goes through the corner
--     (an anchor), and the first point on the next passage after it is that corner - one point, a
--     corner with another passage;
--   - the same side back (A -> B -> A): the first point on it after the event on it is that event's point.
-- Where the thread may cross the passages at points apart - it can run along the first side to the point
-- (Codex' nine squares: a U in the pattern, an L in the thread) - only its events can tell: a side, then a
-- diagonal over its end; three sides around one point (a U). There only a proposal is kept, so a repair
-- need not find the stretch anew from the anchor before (the counter would rarely do for it).
local function Ahead(T, j)
    local c = T.c
    local ax, ay, bx, by, adx, ady = Ends(c, j)
    local cx, cy, dx2, dy2, cdx, cdy = Ends(c, j + 1)
    if not (ax and cx) then return end
    local px, py -- the point the two share
    if ax == cx and ay == cy or ax == dx2 and ay == dy2 then px, py = ax, ay
    elseif bx == cx and by == cy or bx == dx2 and by == dy2 then px, py = bx, by
    else return end
    local straightA, straightC = adx == 0 or ady == 0, cdx == 0 or cdy == 0
    -- (the other end of the first side: the thread may come to the point along it)
    local qx, qy = ax, ay
    if ax == px and ay == py then qx, qy = bx, by end
    if not (straightA and straightC and adx * cdx + ady * cdy == 0) then
        -- not an L: the square between them - at once after a diagonal's corner or on the same side back
        if not straightA or (straightC and adx * cdy - ady * cdx == 0) then
            -- (only while the funnel has not looked at that middle or beyond: else the points it wrote then
            -- may not be the ones it writes with the anchor - the events find it, the repair goes back far enough)
            if T.far < 2 * (j + 1) then T.prot[j + 1] = T.stamp end
            return
        end
        return Pend(T, j, 1, px, py, qx, qy)
    end
    -- an L around (px, py): and the next side around the same point too (a U)?
    local ex, ey, fx, fy, edx, edy = Ends(c, j + 2)
    if ex and (edx == 0 or edy == 0) and cdx * edx + cdy * edy == 0 and (ex == px and ey == py or fx == px and fy == py) then
        return Pend(T, j, 2, px, py, qx, qy)
    end
end

local function Fail(T, reason)
    T.state, T.reason = "failed", reason
end

-- book n pieces of work; false: the counter is spent (the thread is given up). (0.2.4 a9 R1, Codex M1) What does not
-- fit into the pieces the call has left is carried over (T.debt): the next call pays it first and does nothing else
-- for it - the counter goes up by the same in all, a call by 32 at the most
local function Book(T, n)
    if T.used + T.debt + n > T.limit then
        Fail(T, "count")
        return false
    end
    local left = T.left
    local now = n < left and n or left
    T.used, T.left, T.debt = T.used + now, left - now, T.debt + n - now
    return true
end

local function AddPoint(T, x, y, u, anchor)
    local t = T.t
    local k = t.n + 1
    local dx, dy = x - t.x[k - 1], y - t.y[k - 1]
    t.x[k], t.y[k], t.raw[k] = x, y, t.raw[k - 1] + sqrt(dx * dx + dy * dy)
    T.vu[k], T.va[k] = u, anchor
    t.n = k
end

local function Restart(T, x, y, u)
    T.ax, T.ay, T.au = x, y, u
    T.lx, T.ly, T.lu, T.rx, T.ry, T.ru = x, y, u, x, y, u
    T.u = u + 1
end

-- A stretch begins at the anchor k (point k of the thread): the funnel from it, the events of its passages
-- from it on (0.2.4 a8: they run along with the funnel). The proposals of the stretches before stay: a
-- group of events over the border is repaired from them.
local function Begin(T, k)
    T.sk, T.phase = k, 1
    T.wu, T.wk, T.wt = T.vu[k] + 1, k, 0
end

-- the stretch up to the anchor just written is done: the rest of its events next
local function StretchDone(T)
    T.phase = 2
    if M.threadBendTest then M.threadBendTest(T) end -- (the tests: a bend moved off its square)
end

-- (0.2.4 a8) events to find now, while the stretch is not done: the thread up to its last point is final,
-- so the passages up to the one that point was written for, and the ones after it the point lies on too
-- (a corner the way turns around). A middle that is no anchor: the passage after it.
-- the slot of the next passage for the events (a middle that is no anchor: the passage after it); nil: an
-- anchor's middle (it ends the stretch: its pair when the stretch is done)
local function NextSlot(T)
    local u = T.wu
    if u % 2 == 0 then
        if IsAnchor(T, u / 2) then return nil end
        u = u + 1
    end
    return u
end
-- the passage of slot u holds the thread's last point
local function Holds(T, u)
    local ax, ay, bx, by = Ends(T.c, (u - 1) / 2)
    if not ax then return false end
    local t = T.t
    local px, py = t.x[t.n], t.y[t.n]
    if ax > bx then ax, bx = bx, ax end
    if ay > by then ay, by = by, ay end
    return px >= ax - ON_EPS and px <= bx + ON_EPS and py >= ay - ON_EPS and py <= by + ON_EPS
end
local function Pending(T)
    local u = NextSlot(T)
    if not u then return false end
    return u <= T.vu[T.t.n] or Holds(T, u)
end

-- (0.2.4 a8, Codex M1) The thread written from its point k straight to p (the point a proposal's passages
-- share; first side from p to (qx, qy), the passage of slot side): does it meet the first side only at p?
-- Yes when point k was written for a passage before the one before that side (the line from it crosses that
-- passage before p, its event lies on it) - or is the middle of the square before that side as an anchor (its
-- own event is the one before that side) - and the line does not run along the side (from its other end on).
-- Then the first point on that side after the event before is p (see Confirm).
local function OnlyAtP(T, k, px, py, qx, qy, side)
    local before = T.vu[k]
    if T.va[k] == 1 and before % 2 == 0 then before = before - 2 end
    if before >= side - 2 then
        -- (or it lies on the passage before that side, and that passage is the side across the square from it
        -- - the way goes straight through: from its event to point k the thread stays on it, 25 yd off)
        if before ~= side - 2 then return false end
        local j = (side - 1) / 2
        local _, _, _, _, dx1, dy1 = Ends(T.c, j - 1)
        local _, _, _, _, dx2, dy2 = Ends(T.c, j)
        if not (dx1 and dx2) or (dx1 ~= 0 and dy1 ~= 0) or dx1 ~= dx2 or dy1 ~= dy2 then return false end
    end
    local wx, wy = T.t.x[k] - px, T.t.y[k] - py
    qx, qy = qx - px, qy - py
    return not (wx * qy - wy * qx == 0 and wx * qx + wy * qy > 0)
end

-- a side, then a diagonal over its end (a proposal seen at step j = T.pj): decided at once when the funnel's
-- left or right side is the corner p after the side - the next slot is the corner itself (the middle between
-- is no anchor): the funnel writes p next, straight from its apex, the thread's last point. When that meets
-- the side only at p, the middle is a protective anchor now (booked; no thread found anew). true: decided.
local function Sure(T)
    local px, py = T.ppx, T.ppy
    if T.far >= T.u then return false end
    if not (T.lx == px and T.ly == py or T.rx == px and T.ry == py) then return false end
    local n = T.t.n
    if not OnlyAtP(T, n, px, py, T.pqx, T.pqy, 2 * T.pj + 1) then return false end
    if Book(T, 1) then T.prot[T.pj + 1] = T.stamp end
    return true
end

-- a U (three sides around p, seen at step j = T.pj): the two sides after the first one, taken by the funnel's
-- rule on a copy of its apex and sides (FunnelSlot below - the middle between them is no anchor). When the
-- first point the funnel would write there is p, from its side, it writes p straight from its apex, the
-- thread's last point; when that meets the first side only at p, the two middles are protective anchors now
-- (booked; no thread found anew). Another point first, or none: the proposal is kept. true: decided.
local function SureU(T)
    local px, py = T.ppx, T.ppy
    if T.far >= T.u then return false end
    local ax, ay, lx, ly, rx, ry = T.ax, T.ay, T.lx, T.ly, T.rx, T.ry
    if not (lx == px and ly == py or rx == px and ry == py) then return false end
    local c, j = T.c, T.pj
    local ex, ey
    for q = j + 1, j + 2 do
        local nlx, nly, nrx, nry = Ends(c, q)
        if not nlx then return false end
        if not ((nlx == ax and nly == ay) or (nrx == ax and nry == ay)) then
            if (rx - ax) * (nry - ay) - (ry - ay) * (nrx - ax) >= 0 then
                if (rx == ax and ry == ay) or (lx - ax) * (nry - ay) - (ly - ay) * (nrx - ax) < 0 then
                    rx, ry = nrx, nry
                else
                    ex, ey = lx, ly
                    break
                end
            end
            if (lx - ax) * (nly - ay) - (ly - ay) * (nlx - ax) <= 0 then
                if (lx == ax and ly == ay) or (rx - ax) * (nly - ay) - (ry - ay) * (nlx - ax) > 0 then
                    lx, ly = nlx, nly
                else
                    ex, ey = rx, ry
                    break
                end
            end
        end
    end
    if not (ex == px and ey == py) then return false end
    if not OnlyAtP(T, T.t.n, px, py, T.pqx, T.pqy, 2 * j + 1) then return false end
    if Book(T, 2) then T.prot[j + 1], T.prot[j + 2] = T.stamp, T.stamp end
    return true
end

-- the funnel: one slot
local function FunnelSlot(T)
    -- (0.2.4 a8) at the middle after a proposal's first side: the proposal is kept now - or, a side and then a
    -- diagonal over its end, decided at once when the funnel's side is that corner: the corner is the next
    -- slot, so the funnel writes it next, from its apex (the thread's last point), and Confirm's rule tells
    if T.pslot == T.u then
        T.pslot = -1
        local decided
        if T.pq == 1 then decided = Sure(T) else decided = SureU(T) end
        if not decided then Propose(T, T.pj, T.pq, T.ppx, T.ppy, T.pqx, T.pqy) end
        if T.state ~= "work" then return end
    end
    local u = T.u
    local what, a1, a2, a3, a4 = Slot(T, u)
    if what == 0 then
        -- (a middle that is no anchor: the step after it, in the same piece of work)
        u = u + 1
        T.u = u
        what, a1, a2, a3, a4 = Slot(T, u)
    end
    if what == -1 then return Fail(T, "step") end
    if u > T.far then T.far = u end
    if u % 2 == 1 and M.threadAhead ~= false then Ahead(T, (u - 1) / 2) end
    local ax, ay = T.ax, T.ay
    local nlx, nly, nrx, nry
    if what == 1 then
        if a1 == ax and a2 == ay then
            -- the anchor on the apex itself (a corner passed back): a stretch of no length
            AddPoint(T, a1, a2, u, 1)
            Restart(T, a1, a2, u)
            return StretchDone(T)
        end
        nlx, nly, nrx, nry = a1, a2, a1, a2
    else
        nlx, nly, nrx, nry = a1, a2, a3, a4
        if (nlx == ax and nly == ay) or (nrx == ax and nry == ay) then
            -- a side through the apex: the thread passes it there
            T.u = u + 1
            return
        end
    end
    local lx, ly, rx, ry = T.lx, T.ly, T.rx, T.ry
    -- the right side: narrower (or the same), unless it crosses the left one
    if (rx - ax) * (nry - ay) - (ry - ay) * (nrx - ax) >= 0 then
        if (rx == ax and ry == ay) or (lx - ax) * (nry - ay) - (ly - ay) * (nrx - ax) < 0 then
            T.rx, T.ry, T.ru = nrx, nry, u
            rx, ry = nrx, nry
        else
            AddPoint(T, lx, ly, T.lu, 0)
            return Restart(T, lx, ly, T.lu)
        end
    end
    -- the left side
    if (lx - ax) * (nly - ay) - (ly - ay) * (nlx - ax) <= 0 then
        if (lx == ax and ly == ay) or (rx - ax) * (nly - ay) - (ry - ay) * (nlx - ax) > 0 then
            T.lx, T.ly, T.lu = nlx, nly, u
        else
            local ru = T.ru
            local anchor = what == 1 and ru == u -- (the anchor itself: the stretch ends on it)
            AddPoint(T, rx, ry, ru, anchor and 1 or 0)
            Restart(T, rx, ry, ru)
            if anchor then return StretchDone(T) end
            return
        end
    end
    if what == 1 then
        -- the anchor is seen from the apex: the stretch ends on it
        AddPoint(T, a1, a2, u, 1)
        Restart(T, a1, a2, u)
        return StretchDone(T)
    end
    T.u = u + 1
end

-- The group of events at one point, from a to b: true when it breaks the rules
local function Broken(T, a, b)
    local g = b - a + 1
    if g < 2 then return false end
    local ek = T.ek
    if g >= 3 then return true end
    return ek[a] == 0 or ek[b] == 0 or ek[a] == ek[b]
end

-- (0.2.4 a9) jbTo: the last square to anchor when it is not the one of event b (a passage the thread missed)
-- (0.2.4 a9 R1, Codex M1) A repair goes on where it stood, a piece of work at a time: its squares made anchors one a
-- piece (phase 6), the thread's points given back one a piece (phase 7) - the same steps in the same order, the
-- same units booked; the piece that found the broken group starts it.
local RepairMarked
local function Repair(T, a, b, jbTo)
    local ja, jb = floor(T.eu[a] / 2), jbTo or floor(T.eu[b] / 2)
    T.rja, T.rj, T.rjb, T.radd, T.phase = ja, ja + 1, jb, 0, 6
    if ja + 1 > jb then return RepairMarked(T) end
end
-- (phase 6) one square of the repair made an anchor (the loop booked its unit)
local function RepairMark(T)
    local j = T.rj
    local anchor = M.threadAnchorTest or IsAnchor -- (the tests: a square taken for an anchor already)
    if not anchor(T, j) then
        T.prot[j] = T.stamp
        T.radd = T.radd + 1
    end
    T.work = T.work + 1
    if j < T.rjb then
        T.rj = j + 1
        return
    end
    return RepairMarked(T)
end
-- back to the last anchor of the thread before the first new one (point k); its events and the ones before stay
local function RepairBack(T, k)
    local t, vu = T.t, T.vu
    t.n = k
    local e, eu = T.en, T.eu
    while e > 1 and eu[e] > vu[k] do e = e - 1 end
    T.en = e
    local es, ek, gs = T.es, T.ek, e
    while gs > 1 and ek[gs] ~= 3 and ek[gs - 1] ~= 3 and es[e] - es[gs - 1] <= THREAD_TOL do gs = gs - 1 end
    T.gs = gs
    Restart(T, t.x[k], t.y[k], vu[k])
    Begin(T, k)
    T.far = vu[k] -- (the thread up to the anchor holds whatever lies beyond it)
end
RepairMarked = function(T)
    -- (none new: the same would be found again - the centre line stays)
    if T.radd == 0 then return Fail(T, "repair") end
    T.repairs = T.repairs + 1
    local first = 2 * (T.rja + 1)
    local t, vu, va = T.t, T.vu, T.va
    -- (0.2.4 a8, Codex M1) the last proposal kept before the passage into the first new anchor's square:
    -- the thread anew from there (the proposals after it are let go, each looked at is booked, so are the
    -- points given back). Nothing before that passage depends on the new anchors.
    local sv = T.sv
    for i = T.pc, 1, -1 do
        local o = (i - 1) * SNAP
        if sv[o + 24] < first then
            if not Book(T, T.pc - i + t.n - sv[o + 2]) then return end
            return Resume(T, i)
        end
    end
    if not Book(T, T.pc) then return end
    T.pc = 0 -- (all of them after it)
    local k = t.n
    if k > 2 and not (va[k] == 1 and vu[k] < first) then
        T.rk, T.rfirst, T.phase = k, first, 7
        return
    end
    return RepairBack(T, k)
end
-- (phase 7) one point of the thread given back (the loop booked its unit)
local function RepairWalk(T)
    local k = T.rk - 1
    T.work = T.work + 1
    if k > 2 and not (T.va[k] == 1 and T.vu[k] < T.rfirst) then
        T.rk = k
        return
    end
    return RepairBack(T, k)
end

-- (0.2.4 a8, Codex M1) The thread has just been written at a point p: is it the point a proposal's passages
-- share? Then their events may be known now. The point before p written for a passage before the one before
-- the proposal's first side (slot < 2j - 1): the straight line from it to p crosses that passage before (its
-- event lies on it) and, not running along the first side (from that side's other end on), meets the first
-- side only at p - the first point on it after the event before is p; p lies on the passages after it, so
-- their first points after it are p as well: the group of events at p holds a diagonal's corner and another
-- passage, or three sides - the rules are broken, as the events would find. The squares become protective
-- anchors and the thread is found anew from the proposal (the events of the passages before it on the way to
-- p are not worked out for nothing). Running along the first side, the thread crosses it before p, and the
-- point before p written later may lie beyond the first side: no anchor here - the events decide, as they do
-- everywhere. (Looking is part of the piece of work that wrote p: the proposals since the passage two before
-- p's, a few; the anchors and the points given back are booked.) true: repaired, or given up.
local function Confirm(T)
    local t = T.t
    local n = t.n
    local px, py, top = t.x[n], t.y[n], T.vu[n]
    local sv = T.sv
    for i = T.pc, 1, -1 do
        local o = (i - 1) * SNAP
        local su = sv[o + 1]
        -- (p is an end of the passages of a proposal at most two passages before the one it was written for;
        -- the proposal's first side is the passage before the slot it was kept at)
        local side = su - 1
        if side < top - 4 then break end
        if side <= top and sv[o + 20] == px and sv[o + 21] == py then
            if OnlyAtP(T, n - 1, px, py, sv[o + 22], sv[o + 23], side) then
                -- (a square between the passages that is an anchor already puts its middle's event between
                -- them: they are not crossed at one point - the events decide)
                local j, squares = sv[o + 18], sv[o + 19]
                local anchor = M.threadAnchorTest or IsAnchor
                local free = true
                for q = j + 1, j + squares do
                    if anchor(T, q) then free = false end
                end
                if free and sv[o + 24] < 2 * (j + 1) then
                    if not Book(T, squares + n - sv[o + 2]) then return true end
                    for q = j + 1, j + squares do T.prot[q] = T.stamp end
                    T.repairs = T.repairs + 1
                    Resume(T, i)
                    return true
                end
            end
        end
    end
    return false
end

-- an event; the group before it is checked when it is closed by one further on
local function Event(T, x, y, u, kind, r, s)
    local e = T.en + 1
    local es = T.es
    if e > 1 then
        local before = es[e - 1]
        if s < before - THREAD_TOL then return Fail(T, "order") end
        -- (F4 §F: the same r with another s cannot be mapped; the pairs never fall - a crossing found a
        -- rounding before the one before, at one point, is taken at it)
        if r <= T.er[e - 1] and s - before > THREAD_TOL then return Fail(T, "pairs") end
        if s < before then s = before end
    end
    es[e], T.er[e], T.ex[e], T.ey[e], T.eu[e], T.ek[e] = s, r, x, y, u, kind
    T.en = e
    local gs = T.gs
    if kind == 3 or s - es[gs] > THREAD_TOL or T.ek[gs] == 3 then
        if Broken(T, gs, e - 1) then
            -- (the event that closed the group goes again: it is found anew with the thread)
            T.en = e - 1
            return Repair(T, gs, e - 1)
        end
        T.gs = e
    end
end

-- (0.2.4 a7, S1.1 B5, F4 §E: the guard) The line from the event before to the point (kb, tb) lies in the
-- square of middle j (closed, THREAD_TOL): the event before, the points of the thread between and the
-- point itself - the square is convex, so the pieces between lie in it too. Every piece of the thread
-- between two events, anchors, its start and end belongs to one square of the way this way.
local function Within(T, j, kb, tb)
    local c, t = T.c, T.t
    local x0, x1 = c.x[j] - HALF - THREAD_TOL, c.x[j] + HALF + THREAD_TOL
    local y0, y1 = c.y[j] - HALF - THREAD_TOL, c.y[j] + HALF + THREAD_TOL
    local e = T.en
    local px, py = T.ex[e], T.ey[e]
    if px < x0 or px > x1 or py < y0 or py > y1 then return false end
    local tx, ty = t.x, t.y
    for k = T.wk + 1, kb do
        px, py = tx[k], ty[k]
        if px < x0 or px > x1 or py < y0 or py > y1 then return false end
    end
    if kb < t.n then
        px, py = tx[kb] + tb * (tx[kb + 1] - tx[kb]), ty[kb] + tb * (ty[kb + 1] - ty[kb])
        if px < x0 or px > x1 or py < y0 or py > y1 then return false end
    end
    return true
end

-- (0.2.4 a8, Codex M2, F4 §E) A guessed edge (CON, GREV) is the straight stretch between its middles, every
-- piece of it: the line from the event before to the point (kb, tb) - the event, the thread's points between
-- and the point - lies on the edge from middle j to middle j + 1, forwards (within THREAD_TOL), so a bend in
-- the right square before or after the crossing gives the thread up too. No table, no function made.
local function OnLine(ax, ay, dx, dy, len, px, py, last)
    local qx, qy = px - ax, py - ay
    local along, off = qx * dx + qy * dy, qx * dy - qy * dx
    if off > THREAD_TOL or off < -THREAD_TOL or along < last - THREAD_TOL or along > len + THREAD_TOL then return nil end
    if along > last then return along end
    return last
end
local function OnEdge(T, j, kb, tb)
    local c, t = T.c, T.t
    local ax, ay = c.x[j], c.y[j]
    local dx, dy = c.x[j + 1] - ax, c.y[j + 1] - ay
    local len = sqrt(dx * dx + dy * dy)
    if len <= 0 then return false end
    dx, dy = dx / len, dy / len
    local e = T.en
    local last = OnLine(ax, ay, dx, dy, len, T.ex[e], T.ey[e], 0)
    if not last then return false end
    local tx, ty = t.x, t.y
    for k = T.wk + 1, kb do
        last = OnLine(ax, ay, dx, dy, len, tx[k], ty[k], last)
        if not last then return false end
    end
    if kb < t.n then
        last = OnLine(ax, ay, dx, dy, len, tx[kb] + tb * (tx[kb + 1] - tx[kb]), ty[kb] + tb * (ty[kb + 1] - ty[kb]), last)
        if not last then return false end
    end
    return true
end

-- t from lo to hi of p + t d inside [b0, b1]
local function Clip(p, d, b0, b1, lo, hi)
    if d == 0 then
        if p < b0 or p > b1 then return 1, 0 end
        return lo, hi
    end
    local t1, t2 = (b0 - p) / d, (b1 - p) / d
    if t1 > t2 then t1, t2 = t2, t1 end
    if t1 > lo then lo = t1 end
    if t2 < hi then hi = t2 end
    return lo, hi
end

-- (0.2.4 a8) The group of events at the thread's last point, when the next passage does not hold that point:
-- it is whole (the next crossing lies a square's side on at least - the thread's points on passages are
-- the squares' corners), so it is checked now, as the next event would check it; true: it broke the rules
-- (repaired, or given up)
local function CheckLast(T)
    local gs, en = T.gs, T.en
    if en <= gs or T.ek[gs] == 3 then return false end
    local t = T.t
    local off = T.es[en] - t.raw[t.n]
    if off > THREAD_TOL or off < -THREAD_TOL or not Broken(T, gs, en) then return false end
    Repair(T, gs, en)
    return true
end

-- the stretch is checked (its last event written): the next one, or the end. (0.2.4 a8) The events found
-- while the stretch is not done (phase 4): back to the funnel when there are none to find now.
local function StretchChecked(T)
    if T.state ~= "work" then return end
    if T.phase == 4 then
        if Pending(T) then return end
        T.phase = 1
        CheckLast(T)
        return
    end
    if T.phase ~= 2 then return end
    local t = T.t
    if T.wu <= T.vu[t.n] then return end
    -- (the anchor that ends it may be a diagonal's corner with events of passages before it at it)
    local u = NextSlot(T)
    if not (u and Holds(T, u)) and CheckLast(T) then return end
    if T.vu[t.n] >= 2 * (T.c.n - 1) then
        T.phase, T.fk = 3, 0
    else
        Begin(T, t.n)
    end
end

-- the events of the stretch: one slot (phase 2: the stretch is done, up to its anchor; phase 4: the passages
-- before the passage of the thread's last point)
local function EventSlot(T)
    local t, c = T.t, T.c
    local ke = t.n
    local u = T.wu
    local what, a1, a2, a3, a4 = Slot(T, u)
    if what == 0 then
        -- (a middle that is no anchor: the step after it, in the same piece of work)
        u = u + 1
        T.wu = u
        what, a1, a2, a3, a4 = Slot(T, u)
    end
    if what == -1 then return Fail(T, "step") end
    local j = floor(u / 2)
    if u % 2 == 0 then
        -- the anchor's middle that ends the stretch: its pair (after a guessed edge into it: on that edge)
        if not Within(T, j, ke, 0) then return Fail(T, "guard") end
        if Fixed(c.kind[j]) and not OnEdge(T, j - 1, ke, 0) then return Fail(T, "guard") end
        T.wu, T.wk, T.wt = u + 1, ke, 0
        Event(T, t.x[ke], t.y[ke], u, 3, c.raw[j], t.raw[ke])
        return StretchChecked(T)
    end
    local x0, x1, y0, y1, kind
    if what == 1 then
        x0, x1, y0, y1, kind = a1, a1, a2, a2, 0
    else
        x0, x1, y0, y1 = a1, a3, a2, a4
        if x0 > x1 then x0, x1 = x1, x0 end
        if y0 > y1 then y0, y1 = y1, y0 end
        kind = x0 == x1 and 1 or 2
    end
    -- the first point of the thread on the passage from the event before
    local tx, ty, cum = t.x, t.y, t.raw
    local k, lo0 = T.wk, T.wt
    while true do
        if k >= ke then
            -- (0.2.4 a8: the stretch not done yet - the crossing lies beyond the thread written so far)
            if T.phase == 4 then
                T.phase = 1
                return
            end
            -- (0.2.4 a9, part 4) the thread written never crosses this passage (the funnel went past it: with the
            -- sides cut by the margin, a way round a corner point and back out over it): the squares from the
            -- last event's to the one beyond this passage become protective anchors, the thread is found anew
            if T.en >= 1 then return Repair(T, T.en, T.en, j + 1) end
            return Fail(T, "event")
        end
        local vx, vy = tx[k], ty[k]
        local dx, dy = tx[k + 1] - vx, ty[k + 1] - vy
        local lo, hi = Clip(vx, dx, x0 - ON_EPS, x1 + ON_EPS, lo0, 1)
        if lo <= hi then lo, hi = Clip(vy, dy, y0 - ON_EPS, y1 + ON_EPS, lo, hi) end
        if lo <= hi then
            -- (the crossing itself, not where the line comes within ON_EPS of the passage)
            if kind == 1 then
                if dx ~= 0 then lo = (x0 - vx) / dx else lo = Clip(vy, dy, y0, y1, lo0, 1) end
            elseif kind == 2 then
                if dy ~= 0 then lo = (y0 - vy) / dy else lo = Clip(vx, dx, x0, x1, lo0, 1) end
            elseif vx == x0 and vy == y0 then
                lo = lo0
            elseif tx[k + 1] == x0 and ty[k + 1] == y0 then
                lo = 1
            end
            if lo < lo0 then lo = lo0 elseif lo > 1 then lo = 1 end
            -- (the guard: from the event before to this crossing inside square j; a guessed edge crossed
            -- at the middle of its side or at its corner - the straight stretch between its middles)
            if not Within(T, j, k, lo) then return Fail(T, "guard") end
            if Fixed(c.kind[j + 1]) and not OnEdge(T, j, k, lo) then return Fail(T, "guard") end
            if Fixed(c.kind[j + 1]) then
                local mx, my = (c.x[j] + c.x[j + 1]) / 2, (c.y[j] + c.y[j + 1]) / 2
                local qx, qy = vx + lo * dx - mx, vy + lo * dy - my
                if qx * qx + qy * qy > THREAD_TOL * THREAD_TOL then return Fail(T, "guard") end
            end
            T.wk, T.wt, T.wu = k, lo, u + 1
            Event(T, vx + lo * dx, vy + lo * dy, u, kind, (c.raw[j] + c.raw[j + 1]) / 2, cum[k] + lo * (cum[k + 1] - cum[k]))
            if T.state == "work" and T.phase == 2 and u + 1 == T.vu[ke] and (u + 1) % 2 == 0 then
                -- (the anchor's middle that ends the stretch right after: its pair in the same piece of work)
                if not Within(T, j + 1, ke, 0) then return Fail(T, "guard") end
                if Fixed(c.kind[j + 1]) and not OnEdge(T, j, ke, 0) then return Fail(T, "guard") end
                T.wu, T.wk, T.wt = u + 2, ke, 0
                Event(T, t.x[ke], t.y[ke], u + 1, 3, c.raw[j + 1], t.raw[ke])
            end
            return StretchChecked(T)
        end
        -- (going on along the thread to the passage belongs to its check: bounded by the thread's
        -- points, each booked once when it is written)
        k, lo0 = k + 1, 0
    end
end

---------------------------------------------------------------------------
-- (0.2.4 a9, F4.5 §4, F4.6 §3) Arcs. The thread checked, its corners drawn round: at every point drawn where it
-- turns by 10 degrees or more - not at a diagonal's corner, not at a CON edge's middle, not at you, the first and
-- the last square's middle or the node - the corner is replaced by a circular arc that touches both stretches:
-- the radius as large as it may be up to 12 yd, the touching points no further from the corner than half the
-- shorter stretch, and the arc no further from the corner than the check margin (4 yd). Drawn as its two
-- touching points and 3 points between them (4 chords).
--   The finished drawing is checked arc by arc (the straight bits between are the thread's, checked by the
--   events): from its first touching point, in the square the thread is in there, each chord is cut at the
--   passages the thread crosses between the touching points, in their order - a side crossed inside the side
--   cut by the check margin, a diagonal's corner exactly at its point - and each piece between two cuts has both
--   ends in one square of the way (closed, THREAD_TOL; the square is convex, so the piece lies in it). An arc
--   that does not hold: that corner stays sharp (counted), the rest keeps its arcs (F4.6 §3: the one exception
--   to "never a corner", a single one at a tight place).
--   The finished drawing is T.f; one corner a piece of work, booked like the rest; nothing is made: the lists
--   are written over.
---------------------------------------------------------------------------
local cos, sin, abs = math.cos, math.sin, math.abs
local ARC_MIN = math.rad(10)   -- a turn smaller than this stays (F4.5 §4)
local ARC_MAX = math.rad(179)  -- (a turn back on itself: no circle touches both)
local ARC_RADIUS = 12          -- yards at the most
M.threadArcs = true            -- (the tests, the picture of a8 beside a9: false, no arcs)

-- the square j of the way holds (x, y), closed, within THREAD_TOL
local function InSquare(c, j, x, y)
    local cx, cy = c.x[j], c.y[j]
    return x >= cx - HALF - THREAD_TOL and x <= cx + HALF + THREAD_TOL and y >= cy - HALF - THREAD_TOL and y <= cy + HALF + THREAD_TOL
end

-- Where the chord from (px, py) to (qx, qy), from its share lo on, crosses the passage of step j (between the
-- squares j and j + 1): its share; nil: it does not; false: it crosses the side's line outside the side cut by
-- the check margin (but on the side).
local function CrossAt(c, j, px, py, qx, qy, lo)
    local x, y = c.x, c.y
    local dx, dy = x[j + 1] - x[j], y[j + 1] - y[j]
    local mx, my = x[j] + dx / 2, y[j] + dy / 2
    local vx, vy = qx - px, qy - py
    if dx ~= 0 and dy ~= 0 then
        -- a diagonal's corner: only exactly through its point
        local len2 = vx * vx + vy * vy
        if len2 <= 0 then return end
        local t = ((mx - px) * vx + (my - py) * vy) / len2
        if t < lo - 1e-9 or t > 1 + 1e-9 then return end
        local ex, ey = px + t * vx - mx, py + t * vy - my
        if ex * ex + ey * ey > 1e-12 then return end
        return t
    end
    local reach = HALF - CHECK_MARGIN
    local t
    if dx ~= 0 then
        -- a side across x (the line x = mx)
        if vx == 0 then return end
        t = (mx - px) / vx
        if t < lo - 1e-9 or t > 1 + 1e-9 then return end
        local cy = py + t * vy
        if cy < my - HALF - THREAD_TOL or cy > my + HALF + THREAD_TOL then return end
        if cy < my - reach - 1e-9 or cy > my + reach + 1e-9 then return false end
    else
        if vy == 0 then return end
        t = (my - py) / vy
        if t < lo - 1e-9 or t > 1 + 1e-9 then return end
        local cx = px + t * vx
        if cx < mx - HALF - THREAD_TOL or cx > mx + HALF + THREAD_TOL then return end
        if cx < mx - reach - 1e-9 or cx > mx + reach + 1e-9 then return false end
    end
    if t < lo then t = lo elseif t > 1 then t = 1 end
    return t
end

-- The check of an arc (T.qx, T.qy 1..5) from square j: the passages of the events from T.ae on up to the old
-- yards sb (the ones the thread crosses between the touching points), in their order. base: the drawing's yards
-- at the first touching point; the crossings' yards into T.fs (1..). true when the arc holds.
local function ArcHolds(T, j, sb, base)
    local c = T.c
    local qx, qy, fs = T.qx, T.qy, T.fs
    local es, eu, ek, en = T.es, T.eu, T.ek, T.en
    local e = T.ae
    if not InSquare(c, j, qx[1], qy[1]) then return false end
    local nf, along = 0, base
    for h = 1, 4 do
        local p1x, p1y, p2x, p2y = qx[h], qy[h], qx[h + 1], qy[h + 1]
        local len = sqrt((p2x - p1x) ^ 2 + (p2y - p1y) ^ 2)
        local lo = 0
        while true do
            -- the next event in the arc: a passage (its crossing); an anchor's middle (the corner) is passed
            while e <= en and es[e] <= sb and ek[e] == 3 do e = e + 1 end
            if not (e <= en and es[e] <= sb) then break end
            local pj = (eu[e] - 1) / 2
            if pj ~= j then return false end
            local tc = CrossAt(c, pj, p1x, p1y, p2x, p2y, lo)
            if tc == false then return false end
            if not tc then break end
            nf = nf + 1
            -- (0.2.4 a9 R1, Codex N2) and the point where the chord crosses it
            fs[nf], T.fx[nf], T.fy[nf] = along + tc * len, p1x + tc * (p2x - p1x), p1y + tc * (p2y - p1y)
            lo, j, e = tc, pj + 1, e + 1
        end
        if not InSquare(c, j, p2x, p2y) then return false end
        along = along + len
    end
    -- every passage between the touching points crossed?
    while e <= en and es[e] <= sb and ek[e] == 3 do e = e + 1 end
    return not (e <= en and es[e] <= sb)
end
M.ArcHolds = ArcHolds

-- (the arc's points, worked out into T.qx, T.qy 1..5: the touching points and the 3 between)
local function ArcPoints(T, vx, vy, ux, uy, wx, wy, th, R, tl)
    local qx, qy = T.qx, T.qy
    local ax, ay = vx - tl * ux, vy - tl * uy
    local sgn = (ux * wy - uy * wx) > 0 and 1 or -1
    local ox, oy = ax - sgn * R * uy, ay + sgn * R * ux
    local rx, ry = ax - ox, ay - oy
    qx[1], qy[1] = ax, ay
    for i = 1, 3 do
        local a = sgn * th * i / 4
        local ca, sa = cos(a), sin(a)
        qx[i + 1], qy[i + 1] = ox + rx * ca - ry * sa, oy + rx * sa + ry * ca
    end
    qx[5], qy[5] = vx + tl * wx, vy + tl * wy
end

-- write a point of the finished drawing (its yards along it in raw and dcum; it is drawn whole: dk[k] = k)
local function FPoint(F, x, y)
    local m = F.n
    local s = 0
    if m > 0 then
        local dx, dy = x - F.x[m], y - F.y[m]
        s = F.raw[m] + sqrt(dx * dx + dy * dy)
    end
    m = m + 1
    F.x[m], F.y[m], F.raw[m], F.dk[m], F.dcum[m] = x, y, s, m, s
    -- (the world places' lists get their length here, as the thread's do in FinishPoint - not while you ride)
    F.bx[m], F.by[m], F.cv[m] = 0, 0, -1
    F.n, F.dn = m, m
end

-- the square of the way the thread is in just after the last event passed (all events up to the arc's first
-- touching point are): after a passage the square beyond it, at an anchor's middle its square
local function SquareAt(T)
    local e = T.ae - 1
    if e < 1 then return 2 end
    local u = T.eu[e]
    if T.ek[e] == 3 then return floor(u / 2) end
    return (u - 1) / 2 + 1
end

local function ArcBegin(T)
    local F, t = T.f, T.t
    F.n, F.dn = 0, 0
    T.ai, T.ad, T.ae, T.arcs, T.sharp, T.tries, T.ast = 2, 0, 1, 0, 0, 0, 0
    FPoint(F, t.x[t.dk[1]], t.y[t.dk[1]])
    T.phase = 5
end

-- can the drawn point (thread point k) be drawn round at all (F4.5 §4)?
local function Roundable(T, k)
    local u, c = T.vu[k], T.c
    if u <= 4 or u >= 2 * (c.n - 1) then return false end -- (you, the first square's middle; the last one's, the node)
    local j = floor(u / 2)
    if u % 2 == 1 then
        local dx, dy = c.x[j + 1] - c.x[j], c.y[j + 1] - c.y[j]
        return dx == 0 or dy == 0 -- (a diagonal's corner stays a point)
    end
    return not (Fixed(c.kind[j]) or Fixed(c.kind[j + 1])) -- (a CON edge's middle stays)
end

-- One piece of the arcs' work (0.2.4 a9 R1, Codex M1: where it stood, one piece a call of the loop - before, a corner
-- moved all the pairs before it, wrote its five points and its arc's pairs at once, the end all the pairs left).
-- The stages (T.ast):
--   0  the next corner (or the end): decided - one unit booked, as a9 booked a corner
--   1  the pairs up to the old yards T.apto (inclusive): (0.2.4 a9, F4.6 §4) moved by what the arcs before them made
--      the drawing shorter - r stays, s is the yards along the drawing; one a piece, then stage T.anext
--   2  the points T.aph .. T.apn of T.qx, T.qy written, one a piece, then stage T.athen
--   3  the arc checked (the pairs up to its first touching point are passed): it holds - its five points, then its
--      pairs; it does not - that corner stays sharp
--   4  the pairs in the arc from the finished drawing, one a piece: a passage's s is where its chord crosses it
--      (ArcHolds wrote them in order); an anchor's middle drawn round maps to the arc's middle point. (Codex N2) The
--      event's point becomes that point of the drawing too (the thread's crossing before).
--   6  the end: the last point, the finished drawing's own numbers
-- A piece moves one pair, writes one point or checks one arc (T.work counts them); a stage with nothing to do
-- goes on to the next in the same piece. The same steps in the same order as a9: the same drawing.
local function ArcStep(T)
    local st = T.ast
    if st == 1 then
        local e = T.ae
        if e <= T.en and T.es[e] <= T.apto then
            T.es[e] = T.es[e] - T.ad
            T.ae = e + 1
            T.left, T.work, T.free = T.left - 1, T.work + 1, T.free + 1
            return
        end
        st = T.anext
        T.ast = st
    end
    if st == 2 then
        local h = T.aph
        FPoint(T.f, T.qx[h], T.qy[h])
        T.left, T.work, T.free = T.left - 1, T.work + 1, T.free + 1
        if h < T.apn then T.aph = h + 1 else T.ast = T.athen end
        return
    end
    if st == 3 then
        local F = T.f
        local dx0, dy0 = T.qx[1] - F.x[F.n], T.qy[1] - F.y[F.n]
        T.left, T.work, T.free = T.left - 1, T.work + 1, T.free + 1
        if not ArcHolds(T, SquareAt(T), T.asb, F.raw[F.n] + sqrt(dx0 * dx0 + dy0 * dy0)) then
            -- that corner stays sharp: the pairs up to it, then its point
            T.sharp = T.sharp + 1
            T.qx[6], T.qy[6] = T.avx, T.avy
            T.apto, T.anext, T.aph, T.apn, T.athen, T.ast = T.asv, 2, 6, 6, 0, 1
            return
        end
        T.aph, T.apn, T.athen, T.ast, T.an2 = 1, 5, 4, 2, 0
        return
    end
    if st == 4 then
        local e = T.ae
        if e <= T.en and T.es[e] <= T.asb then
            -- (0.2.4 a9 R1, Codex N2) its point too: the drawing's crossing, the arc's middle point
            if T.ek[e] == 3 then
                local F = T.f
                local m = F.n - 2
                T.es[e], T.ex[e], T.ey[e] = F.raw[m], F.x[m], F.y[m]
            else
                local n2 = T.an2 + 1
                T.an2, T.es[e], T.ex[e], T.ey[e] = n2, T.fs[n2], T.fx[n2], T.fy[n2]
            end
            T.ae = e + 1
            T.left, T.work, T.free = T.left - 1, T.work + 1, T.free + 1
            return
        end
        local F = T.f
        T.arcs = T.arcs + 1
        T.ad = T.ad + (T.asb - T.asa) - (F.raw[F.n] - F.raw[F.n - 4])
        T.ast = 0
    end
    local t, F = T.t, T.f
    if T.ast == 6 then
        local dn = t.dn
        FPoint(F, t.x[t.dk[dn]], t.y[t.dk[dn]])
        T.left, T.work, T.free = T.left - 1, T.work + 1, T.free + 1
        F.len, F.tail, F.head = F.raw[F.n], t.tail, t.head
        F.conv, F.map, F.w, F.h = t.conv, t.map, t.w, t.h
        F.pwx, F.pwy, F.twx, F.twy = t.pwx, t.pwy, t.twx, t.twy
        F.stamp = F.stamp + 1
        local v = F.view
        v.n, v.len, v.tail = F.n, F.len, F.tail
        T.state = "done"
        return
    end
    -- (stage 0) the next corner, or the end: one unit, as a9
    if not Book(T, 1) then return end
    local dk, i, dn = t.dk, T.ai, t.dn
    local x, y = t.x, t.y
    if i >= dn then
        T.apto, T.anext, T.ast = huge, 6, 1
        return
    end
    T.ai = i + 1
    local k = dk[i]
    local vx, vy = x[k], y[k]
    local sv = t.dcum[i]
    local px, py, qx, qy = x[dk[i - 1]], y[dk[i - 1]], x[dk[i + 1]], y[dk[i + 1]]
    local ax, ay, bx, by = vx - px, vy - py, qx - vx, qy - vy
    local la, lb = sqrt(ax * ax + ay * ay), sqrt(bx * bx + by * by)
    local th = 0
    if la > 0 and lb > 0 then
        ax, ay, bx, by = ax / la, ay / la, bx / lb, by / lb
        th = math.atan2(abs(ax * by - ay * bx), ax * bx + ay * by)
    end
    if not (M.threadArcs and th >= ARC_MIN and th <= ARC_MAX and Roundable(T, k)) then
        -- sharp: the pairs up to it, then its point
        T.qx[6], T.qy[6] = vx, vy
        T.apto, T.anext, T.aph, T.apn, T.athen, T.ast = sv, 2, 6, 6, 0, 1
        return
    end
    T.tries = T.tries + 1 -- (a corner to round)
    local half = th / 2
    local R = ARC_RADIUS
    local r2 = (la < lb and la or lb) / 2 / math.tan(half)
    if r2 < R then R = r2 end
    local r3 = CHECK_MARGIN / (1 / cos(half) - 1)
    if r3 < R then R = r3 end
    local tl = R * math.tan(half)
    ArcPoints(T, vx, vy, ax, ay, bx, by, th, R, tl)
    -- the pairs up to its first touching point, then the check
    T.asv, T.asa, T.asb, T.avx, T.avy = sv, sv - tl, sv + tl, vx, vy
    T.apto, T.anext, T.ast = sv - tl, 3, 1
end

-- the end: the node, then the points drawn (one a piece)
local function FinishPoint(T)
    local t, c = T.t, T.c
    if T.fk == 0 then
        -- (the node, and the first point drawn, in the same piece of work as the second point)
        AddPoint(T, c.x[c.n], c.y[c.n], 2 * c.n, 1)
        t.dn, t.dk[1], t.dcum[1] = 1, 1, 0
        t.bx[1], t.by[1], t.cv[1] = 0, 0, -1
        T.fk = 2
    end
    local k, n = T.fk, t.n
    -- (S1.1 B5: the world places' lists get their length here, a point at a time - not while you ride,
    -- when a reader asks for a point further on; the centre line's get it in the way back, phase back)
    t.bx[k], t.by[k], t.cv[k] = 0, 0, -1
    local x, y, dk, dn = t.x, t.y, t.dk, t.dn
    if k < n then
        -- drawn unless on the point drawn before it or on the next one, or (no anchor) on the straight
        -- line between them, between them (F3 §3.6, F4 §F: a turn back stays)
        local p = dk[dn]
        local ax, ay = x[k] - x[p], y[k] - y[p]
        local dx, dy = x[k + 1] - x[k], y[k + 1] - y[k]
        if not (ax * ax + ay * ay < 1e-6 or dx * dx + dy * dy < 1e-6 or (T.va[k] ~= 1 and ax * dy - ay * dx == 0 and ax * dx + ay * dy > 0)) then
            dn = dn + 1
            dk[dn], t.dcum[dn] = k, t.raw[k]
            t.dn = dn
        end
        T.fk = k + 1
        return
    end
    dn = dn + 1
    dk[dn], t.dcum[dn], t.dn = n, t.raw[n], dn
    t.len, t.tail, t.head = t.raw[n], c.tail, c.head
    t.conv, t.map, t.w, t.h = c.conv, c.map, c.w, c.h
    t.pwx, t.pwy, t.twx, t.twy = c.pwx, c.pwy, c.twx, c.twy
    t.stamp = t.stamp + 1 -- (a new line: no world place put in before counts)
    local v = t.view
    v.n, v.len, v.tail = dn, t.len, t.tail
    ArcBegin(T)
end

-- A thread for the centre line c (of the way generation gen). In pieces of work: ThreadStep(T, budget)
-- until T.state is "done" (T.t is the thread) or "failed" (T.reason; the centre line stays).
function M.ThreadStart(T, c, gen)
    T.c, T.gen = c, gen
    T.stamp = T.stamp + 1
    T.used, T.repairs, T.reason, T.state = 0, 0, nil, "work"
    T.debt, T.work, T.free = 0, 0, 0 -- (0.2.4 a9 R1)
    local n = c.n
    -- (0.2.4 a9, F4.3 §2, F4.4 §2) the whole budget: 16 times the passages (M.threadFactor: the tests, another one)
    T.limit = (M.threadFactor or 16) * (n - 3)
    T.en, T.gs, T.pc, T.pslot, T.far = 0, 1, 0, -1, 4
    if n < 4 then return Fail(T, "short") end -- (one square: nothing to pull tight)
    local t = T.t
    -- you and the first square's middle: the bit from you stays straight
    t.n = 1
    t.x[1], t.y[1], t.raw[1] = c.x[1], c.y[1], 0
    T.vu[1], T.va[1] = 2, 1
    AddPoint(T, c.x[2], c.y[2], 4, 1)
    Event(T, c.x[2], c.y[2], 4, 3, c.raw[2], t.raw[2])
    Restart(T, c.x[2], c.y[2], 4)
    Begin(T, 2)
end

-- (0.2.4 a9, F4.4 §2, order point 2) A call does `budget` pieces of work at the most and never more than 32, whatever
-- it is asked for. A unit is what the counter books - a passage the funnel or the events take, a point written or
-- given back, an anchor made, a corner decided. (0.2.4 a9 R1, Codex M1) Every unit booked is a piece of the call's
-- 32: units a piece books past them (a protective anchor's points given back) are carried over and paid first by
-- the next call, doing nothing else; a repair goes on where it stood, a square or a point a piece. The arcs' pairs,
-- points and checks are pieces too, booked on the counter as a9 booked them (a unit a corner): so the counter, and
-- with it every thread given up or not, is a9's. The call returns its pieces (the counter went up by no more).
local CALL_UNITS = 32
M.threadCall = CALL_UNITS
function M.ThreadStep(T, budget)
    local cap = M.threadCall
    if budget > cap then budget = cap end
    T.left = budget
    while T.left > 0 and T.state == "work" do
        if T.debt > 0 then
            -- (units booked past the call before: paid first, no work done for them now)
            local pay = T.debt < T.left and T.debt or T.left
            T.used, T.debt, T.left = T.used + pay, T.debt - pay, T.left - pay
        elseif T.phase == 5 then
            ArcStep(T)
        else
            if not Book(T, 1) then break end
            local phase = T.phase
            if phase == 1 then
                local n = T.t.n
                FunnelSlot(T)
                -- (0.2.4 a8, Codex M1) a point of the thread written: a proposal at it is confirmed or not; inside
                -- the stretch, the events of the passages before it now (a broken group is repaired near it)
                if T.state == "work" and T.t.n > n and not Confirm(T) and T.phase == 1 and Pending(T) then T.phase = 4 end
            elseif phase == 2 or phase == 4 then
                EventSlot(T)
            elseif phase == 6 then
                RepairMark(T)
            elseif phase == 7 then
                RepairWalk(T)
            else
                FinishPoint(T)
            end
        end
    end
    local done = budget - T.left
    if T.state ~= "work" and T.debt > 0 then
        -- (the thread is over: what it still owed is booked - no call works for it)
        T.used, T.debt = T.used + T.debt, 0
    end
    T.left = 0
    return done
end

-- (the tests) in one go
function M.Thread(T, c, gen)
    M.ThreadStart(T, c, gen or 0)
    while T.state == "work" do M.ThreadStep(T, huge) end
    return T.state, T.reason
end
M.THREAD_TOL = THREAD_TOL

ns.WaysCore = M

---------------------------------------------------------------------------
-- The navigation of a farm run (W3)
--
--   One state per run (`nav`), made when the run needs it and gone with it.
--   ONE place asks for a way: the run's head tick (Route.lua UpdateHead, ten
--   times a second) through ns.WaysTick. The line and the arrow only read.
--   A way is asked for when a run gets a node, when the net is new, when you
--   leave the way shown - and, while none is shown, whenever you are a
--   square's length (25 yd) from where you asked last.
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
local diag = { peak = 0, step = 0, requests = 0, cancelled = 0, late = 0, over = 0, builds = 0, invalid = 0, dropped = 0, ops = 0,
    threads = 0, repaired = 0, fellCount = 0, fellGuard = 0, fellOther = 0, booked = 0, pubReads = 0, pubPeak = 0,
    -- (0.2.4 a9, F4.5 §5, F4.6 §5) ways of the net published, their threads shown; corners drawn round and left sharp by
    -- the check; ways with a corner to round, and of them the ones with an arc
    ways = 0, shown = 0, arcs = 0, sharp = 0, roundWays = 0, arcWays = 0,
    -- (0.2.4 a9 R1, Codex M3) the generation of way each of the four way counters counted last: a way counts once,
    -- however often it is drawn (kept with new kinds of edge: drawn anew); shown, it counts among the ways too
    -- (published before the counters were reset)
    wayGen = -1, shownGen = -1, roundGen = -1, arcGen = -1 }
local function Frame()
    local now = GetTime()
    if now ~= frameAt then frameAt, frameSum = now, 0 end
end
local function Spend(ms)
    Frame()
    frameSum = frameSum + ms
    if frameSum > diag.peak then diag.peak = frameSum end
end
-- (0.2.4 r1, Codex S1-N1) Every way in from outside counts its own work into the frame's sum,
-- once: a call made while another one is counting (the run window's line asked for while a
-- tick tells it the state changed) adds nothing of its own. A count an error left open is
-- closed at the next frame.
local inside, insideAt = 0, -1
local function Enter()
    local now = GetTime()
    if now ~= insideAt then insideAt, inside = now, 0 end
    inside = inside + 1
    if inside == 1 then return Clock() end
end
local function Leave(t0)
    inside = inside - 1
    if t0 then Spend(Clock() - t0) end
end
local function Outside() return inside <= 0 or insideAt ~= GetTime() end

local ctx        -- the net's lists (nil: none are held)
local nav        -- the run's navigation (nil: no S1 work)
local navRun     -- the run it belongs to
local gen = 0    -- counts at every start and stop of a run
local net = { mapID = nil, ready = false, building = false, over = nil, rev = 0, epoch = 0, fresh = 0, t0 = 0, w = 0, h = 0 }
local req = { active = false }
local keeping = false -- the rest of the way shown is being looked at against a new net
local read = { state = "none", n = 0, yards = 0, cost = 0, guessed = 0, percent = 0, seg = 1, pos = 0, serial = 0, pub = 0, straight = false }
-- (0.2.4 a7, S1.1) What the maps and the arrow show - the display: the centre line of the way
-- published (B1), later its thread. It has its own place along it (seg, pos), worked out from the
-- yards of the way you have come (d = the way's yards - its rest, both the navigation's), and its
-- own mark: read.pub counts at every change of what is shown (the display revision); the way's
-- generation (nav.core.gen) only at a way published. The navigation never reads any of it.
local disp = { buf = nil, seg = 1, pos = 0, gen = -1, kind = "none", mi = 1 }
-- (0.2.4 a7, S1.1 B2/B3) the thread's job: one for all runs, its lists written over and kept.
-- threadWant: the way generation a thread is wanted for (nil: none) - B5 makes it in pieces.
local thread = M.NewThread()
local threadWant = nil
local threadAsk = 0 -- (counts at every thread wanted: a job begun for an earlier one is begun anew)
local function Conv(fx, fy, mapID) return HBD:GetWorldCoordinatesFromZone(fx, fy, mapID) end
-- (the points the maps put into world yards in one step of the work: 16 at the most, F4.1 §B)
local MAP_POINTS = 16
local convStep = 0
-- (0.2.4 a8, Codex M3) the distances read by Locate and ThreadAt (a change of what is shown counts them)
local seen = 0
local WALK = 4 -- forwards from the last place this many at the most, then by halves
-- The segment of a line for a place along it, forwards from s: on the border of two segments the
-- next one (the very end of the way: the last one); a segment of no length is passed over - the segment
-- before the first point beyond the place. From s a few steps forwards (once a frame it moves one or two),
-- else by halves in the distances, which never fall: O(log n) from wherever it starts.
local function Locate(b, s, at)
    local cum, n = b.cum, b.n
    if n < 3 then return 1 end
    local lo = 1
    if s and s >= 1 and s < n then
        seen = seen + 1
        if cum[s] <= at then
            for _ = 1, WALK do
                if s >= n - 1 then return n - 1 end
                seen = seen + 1
                if cum[s + 1] > at then return s end
                s = s + 1
            end
            lo = s
        end
    end
    -- the first point in lo + 1 .. n beyond the place (n - 1 when none is)
    local a, z = lo + 1, n
    while a < z do
        local m = floor((a + z) / 2)
        seen = seen + 1
        if cum[m] > at then z = m else a = m + 1 end
    end
    seen = seen + 1
    if cum[a] > at then return a - 1 end
    return n - 1
end
-- (S1.1 B3, F3 §4, F4 §A/§F) Where the yards d along the way of the net lie on the thread: between the
-- pairs (r, s) of its passages and anchors, in a straight line; never falling (two passages at one corner:
-- the place stands still); the bits from you and to the node are the centre line's (s = r there, moved by
-- what the thread is shorter). Forwards from the pair found the last time (disp.mi).
local function ThreadAt(d)
    local T = thread
    local er, es, en = T.er, T.es, T.en
    seen = seen + 2
    local first, last = er[1], er[en]
    if d <= first then
        seen = seen + 1
        return es[1] - (first - d)
    end
    if d >= last then
        seen = seen + 1
        return es[en] + (d - last)
    end
    -- (0.2.4 a8, Codex M3) the pair before the first one beyond d: a few forwards from the last one, else by
    -- halves (d lies before the last pair's r, so there is one beyond it)
    local i, lo, found = disp.mi, 1, false
    if i >= 1 and i < en then
        seen = seen + 1
        if er[i] <= d then
            for _ = 1, WALK do
                seen = seen + 1
                if er[i + 1] > d then
                    found = true
                    break
                end
                i = i + 1
            end
            lo = i
        end
    end
    if not found then
        local a, z = lo + 1, en
        while a < z do
            local m = floor((a + z) / 2)
            seen = seen + 1
            if er[m] > d then z = m else a = m + 1 end
        end
        i = a - 1
    end
    disp.mi = i
    seen = seen + 4
    local r0, r1, s0, s1 = er[i], er[i + 1], es[i], es[i + 1]
    if r1 <= r0 then return s1 end
    return s0 + (d - r0) * (s1 - s0) / (r1 - r0)
end
-- The display's place for the navigation's progress (once a frame, with Follow): the yards of the way you
-- have come (d), on the centre line the same yards, on the thread where they lie on it
local function DisplayFollow()
    local b = disp.buf
    if not (b and nav) then return end
    local core = nav.core
    local at = core.front.yards - core.rest
    if disp.kind == "thread" then at = ThreadAt(at) end
    if at < 0 then at = 0 elseif at > b.len then at = b.len end
    disp.pos = at
    disp.seg = Locate(b, disp.seg, at)
end
-- Where the arrow turns to on the display: the point 30 yd ahead of its place; nil: the node
-- itself (the point lies on the last bit to it, as in a5)
local function DisplayArrow()
    local b = disp.buf
    local at = disp.pos + ARROW_YARDS
    if at >= b.len - b.tail then return end
    local s = Locate(b, disp.seg, at)
    local cum, wx, wy = b.cum, b.wx, b.wy
    seen = seen + 2
    local c0, c1 = cum[s], cum[s + 1]
    local len = c1 - c0
    local t = len > 0 and (at - c0) / len or 0
    if t > 1 then t = 1 end
    local ax, ay, bx, by = wx[s], wy[s], wx[s + 1], wy[s + 1]
    return ax + t * (bx - ax), ay + t * (by - ay)
end
-- Route.lua's part: the dots of the way's line. Hide() hides all of them now; Pending() says whether
-- dots are to be placed or taken off the maps; Step(ops) does up to ops of that and returns how many.
local drawer = ns.RouteWaysDrawer
local work = CreateFrame("Frame")
work:Hide()

-- how many operations a step of each kind of work does (set by the clock as it goes). (0.2.4 a9 R1, Codex M2) A kind
-- is a phase of the build or the search and its stage (a radix sort's five stages cost a piece of work very
-- differently - counting, spreading - and shared one setting: after a cheap step it doubled and the dear one ran
-- over), or one of the other kinds of work. A kind starts at 32 pieces at the most and grows by a quarter at the most.
local OPS_FIRST = 32
local ops = {}
local function Ops(kind, first)
    local n = ops[kind]
    if not n then
        n = first < OPS_FIRST and first or OPS_FIRST
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
    -- down at once, up by a quarter at the most
    local up = n + floor(n / 4)
    if up < n + 1 then up = n + 1 end
    if want > up then want = up end
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
    threadWant = nil -- (S1.1: no thread for a way taken back)
    if nav.core.state == "net" then
        nav.core.state = "line"
        nav.core.on = false
        nav.source = nil
        if nav.state == "net" then nav.state = "line" end
        if drawer then drawer.Hide() end
        Told()
    end
end

-- (0.2.4 a7, S1.1 B1; F4 §B, F4.2) Another geometry shown for the same way: the navigation and its
-- progress stay as they are (this is never M.Publish); the drawing under way is given up and its
-- dots hidden in this frame; the display revision counts, so the maps start on the new geometry and
-- a step begun for the old one writes nothing.
-- (0.2.4 a8, Codex M3) Its place on the new geometry by a bounded search (Locate, ThreadAt: O(log n) from the
-- way's start), never by going along the way from the start. The distances it read are counted (/gcr perf)
-- and returned: the step it is done in books them. (Codex N2) The arrow takes the new direction in this frame.
local function PublishDisplay(buf, kind)
    if drawer then drawer.Hide() end
    disp.buf, disp.kind, disp.seg, disp.mi = buf, kind, 1, 1
    read.pub = read.pub + 1
    seen = 0
    DisplayFollow()
    read.seg, read.pos = disp.seg, disp.pos
    if ns.ArrowNow then ns.ArrowNow() end
    diag.pubReads = seen
    if seen > diag.pubPeak then diag.pubPeak = seen end
    return seen
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
    local t0 = Enter()
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
    Leave(t0)
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
-- the way is taken back and hidden in this frame; (0.2.4 a9 R1) the net's lists stay for the next run, the option
-- off lets them go - also when no run is on. (Taking the hidden dots off the maps goes on in small steps, Route.lua.)
local function Release()
    if ns.db and ns.db.routeWaysOff then ctx = nil end
    if not nav then return end
    Withdraw()
    CancelRequest()
    nav.state = "none"
    nav, navRun = nil, nil
    disp.buf, disp.kind, disp.gen, disp.seg, disp.pos, disp.mi = nil, "none", -1, 1, 0, 1
    -- (0.2.4 a8, Codex N1) the thread's job lets the last centre line go; its own lists stay for the next run
    thread.c, threadWant = nil, nil
    read.state, read.points, read.n, read.source = "none", nil, 0, nil
    -- (0.2.4 a9 R1, Codex M2) the build's and the search's lists stay from run to run, no net in use: a run made them
    -- anew - about 2.8 MB for a net of 8,000 squares, and the garbage collector's steps for them fell into S1's steps.
    -- They are written over (8,000 squares and 20,000 edges at the most); what they held of the run goes (its
    -- navigation, the keep's: the last centre line is let go, a8 N1). The option off lets them go too (Codex R3-M2).
    if ctx and not (ns.db and ns.db.routeWaysOff) then
        M.Drop(ctx)
        ctx.q.nav = nil
        if ctx.keepJob then ctx.keepJob.nav = nil end
    else
        ctx = nil
    end
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

-- (0.2.4 r1, Codex S1-M1) Where you are now, read as the head's tick reads it: the zone
-- (the game's map of you while it is the node's zone, else Paths' zone under a continent's
-- map) and the instance. nil when your place cannot be read. Read anew at every call, not
-- once a frame: a zone change and a reader in the same frame must not see the old way.
local function Here(tmap)
    local px, py, inst
    if HBD then px, py, inst = HBD:GetPlayerWorldPosition() end
    if px == nil or AnySecret("ways", px, py, inst) or type(px) ~= "number" or type(py) ~= "number" then return end
    local mapID = ns.PlayerMap and ns.PlayerMap()
    if mapID ~= tmap and ns.GetPlayerPos then mapID = ns.GetPlayerPos() end
    if type(mapID) ~= "number" or AnySecret("ways", mapID) then return end
    return mapID, inst
end

-- Is the way shown the way to the run's target of now, from where you are now? (every reader asks this first)
local function Valid(run)
    if not nav or nav.core.state ~= "net" then return false end
    local tp
    if run and run == navRun and run == ns.run then tp = run.targetPoint end
    local node = tp and tp.node
    if node and node == nav.node and node == run.target and tp.mapID == nav.tmap and node.x == nav.nx and node.y == nav.ny
        and run.instance == nav.inst and not (ns.db and ns.db.routeWaysOff) then
        -- the context of now: still in the net's zone and the instance the way was found in
        local mapID, inst = Here(nav.tmap)
        if mapID == nav.tmap and mapID == net.mapID and inst == nav.inst then return true end
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
        DisplayFollow()
        read.seg, read.pos = disp.seg, disp.pos
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
    nav.asked, nav.ax, nav.ay = true, px, py
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
    if nav.asked and not req.active and nav.core.state ~= "net" and nav.ax then
        -- No way is shown (none was found from where you asked), and you are a square's length from
        -- there: what was found for that place says nothing about this one - asked anew from here.
        -- (So the line finds your net again when you ride back onto it, not only at the next node.)
        local dx, dy = px - nav.ax, py - nav.ay
        if dx * dx + dy * dy >= TILE * TILE then nav.asked = false end
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

-- (0.2.4 a7, S1.1 B5, F4 §D, F4.1 §B/§D) The thread of the way shown: a job of its own, wanted at every way
-- published (and after a check that changed the anchors, T2). It works in steps like the rest, after a
-- request and after the maps' dots; on the one counter of its job. Done, and the way, its generation and
-- the centre line shown still the ones it was wanted for: shown (a display revision of its own). Given up
-- (the counter, the guard, an error): the centre line stays. A way of another generation, a check that
-- changed the anchors, a way taken back: the job is let go, it never shows anything.
local function ThreadWork(budget)
    if not (nav and nav.core.state == "net" and threadWant == nav.core.gen) then
        threadWant = nil
        return 0
    end
    local T = thread
    local used = 0
    if T.ask ~= threadAsk then
        T.ask = threadAsk
        M.ThreadStart(T, nav.core.cf, threadWant)
        used = 1
    end
    if T.state == "work" then used = used + M.ThreadStep(T, budget) end
    if T.state == "done" then
        threadWant = nil
        diag.threads, diag.booked = diag.threads + 1, diag.booked + T.used
        if T.repairs > 0 then diag.repaired = diag.repaired + 1 end
        diag.arcs, diag.sharp = diag.arcs + T.arcs, diag.sharp + T.sharp
        local g = T.gen
        if T.tries > 0 and diag.roundGen ~= g then diag.roundWays, diag.roundGen = diag.roundWays + 1, g end
        if T.arcs > 0 and diag.arcGen ~= g then diag.arcWays, diag.arcGen = diag.arcWays + 1, g end
        -- (0.2.4 a9, F4.6 §4) shown: the finished drawing with its arcs - the maps and the arrow read this one list
        if (disp.kind == "straight" or disp.kind == "centre") and disp.gen == nav.core.gen then
            used = used + PublishDisplay(T.f.view, "thread")
            if diag.shownGen ~= g then
                diag.shown, diag.shownGen = diag.shown + 1, g
                if diag.wayGen ~= g then diag.ways, diag.wayGen = diag.ways + 1, g end
            end
        end
    elseif T.state == "failed" then
        threadWant = nil
        diag.booked = diag.booked + T.used
        if T.reason == "count" then
            diag.fellCount = diag.fellCount + 1
        elseif T.reason == "guard" then
            diag.fellGuard = diag.fellGuard + 1
        elseif T.reason ~= "short" then
            diag.fellOther = diag.fellOther + 1
        end
    end
    return used
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
        if pending == 2 then
            convStep = M.convs -- (the maps' points of this step, see MAP_POINTS)
            return 202, drawer.Step(Ops(202, 6))
        end
        -- (S1.1 B5) the thread of the way shown, after the request and the dots (F4.1 §B: fourth)
        if threadWant then
            local used = ThreadWork(Ops(204, 50))
            if used > 0 then return 204, used end
        end
        if not net.building then
            if pending then return 203, drawer.Step(Ops(203, 20)) end
            return
        end
        local job = ctx.job
        local kind = job.phase + 1000 * job.stage -- (0.2.4 a9 R1: each stage of a phase its own setting)
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
            local kind = 100 + q.phase + 1000 * (q.stage or 0) -- (0.2.4 a9 R1: each stage its own setting)
            local used = M.QueryStep(ctx, Ops(kind, 200))
            if q.done then
                if q.result == "net" then
                    req.stage, req.i = "world", 0
                elseif nav.core.state == "net" and q.reason ~= "near" and MarkHolds(true) then
                    -- no new way for the node whose way is shown: the way shown stays, if the net of now allows all of its rest
                    req.stage, keeping = "keep", true
                    M.KeepStart(ctx, nav.core).early = false
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
                    -- (0.2.4 a9, F4.3 §1) shown: the straight line, as with the option off, until its thread is done
                    -- (the centre line stays inside: the thread is made from it, it is never drawn)
                    local c = nav.core.cf
                    c.conv, c.map, c.w, c.h = Conv, req.map, net.w, net.h
                    c.pwx, c.pwy, c.twx, c.twy = req.pwx, req.pwy, req.twx, req.twy
                    -- (M.displayCentreTest: only the pre-S1.1 steps that test the dots along a way shown - the centre
                    -- line as a8 showed it; the game never sets it)
                    local centre = M.displayCentreTest
                    disp.buf, disp.kind, disp.gen, disp.seg, disp.pos, disp.mi = centre and c.view or nil, centre and "centre" or "straight", nav.core.gen, 1, 0, 1
                    read.pub = read.pub + 1
                    -- (S1.1 B5, F4 §D) its thread: a job of its own, after this publication
                    threadWant, threadAsk = nav.core.gen, threadAsk + 1
                    if diag.wayGen ~= nav.core.gen then diag.ways, diag.wayGen = diag.ways + 1, nav.core.gen end
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
            if k.duty and not k.early then
                -- (0.2.4 a7, S1.1 B4, F4.1 §A T1) the first edge whose anchor duty changed: in this frame the
                -- thread gives way to the centre line of the way shown - the geometry only; the navigation,
                -- the percent and the source stay as they were until the check is done. No thread is made
                -- for the old kinds any more.
                k.early = true
                threadWant = nil
                -- (0.2.4 a9, F4.3 §1) the straight line, as with the option off - not the centre line
                if disp.kind == "thread" then used = used + PublishDisplay(nil, "straight") end
            end
            if k.done then
                req.active, keeping = false, false
                if k.ok and nav.core.state == "net" and nav.core.on and MarkHolds(true) then
                    nav.core.front.percent = k.percent
                    nav.source = SourceText(k.percent)
                    -- (T2) percent, source and kinds as in a5; a thread for the new kinds
                    if k.early then threadWant, threadAsk = nav.core.gen, threadAsk + 1 end
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
    Enter() -- (its own work is counted below, step by step; what it calls counts nothing of its own)
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
    Leave(nil)
end
work:SetScript("OnUpdate", Wrap("Ways", Work))

---------------------------------------------------------------------------
-- What the rest of the addon calls
---------------------------------------------------------------------------
-- Route.lua, at every head tick of a run (the one place that asks)
ns.WaysTick = Wrap("Ways", function(run, px, py, instance)
    local t0 = Enter()
    local state = Tick(run, px, py, instance)
    Leave(t0)
    return state
end)

-- A run started or stopped: whatever was found belongs to the run before
ns.WaysRunChanged = Wrap("Ways", function()
    local t0 = Enter()
    gen = gen + 1
    Release()
    Leave(t0)
end)

-- What is shown now. Always an answer, the same table each time:
--   state   "net", "line" or "none"
--   points  with "net": the way's buffer (wx, wy: the points in world yards; cum: how far along each is)
--   n       its points;  yards: its length (you - net - node);  cost: the search's cost (to look at only)
--   source  "net" or "line";  guessed: yards of guessed edges in it;  percent: their share of the way of the net
--   seg, pos  where you are on it;  serial: counts whenever what is shown changes;  pub: at every new way
ns.WaysRead = Wrap("Ways", function(run)
    local t0 = Enter()
    if nav and run == navRun and Valid(run) then
        local b = nav.core.front
        -- (0.2.4 a7, S1.1) the points and the place are the display's; the numbers the navigation's
        -- (0.2.4 a9, F4.3 §1) straight: the way of the net is the navigation's, the maps draw the straight line as
        -- with the option off (Route.lua draws its own straight head when this is set) and the arrow turns to the node
        local d = disp.buf or b
        read.state, read.points, read.n, read.yards, read.cost = "net", d, d.n, b.yards, b.cost
        read.source, read.guessed, read.percent = "net", b.guess, b.percent
        read.seg, read.pos = disp.seg, disp.pos
        read.straight = disp.kind == "straight"
    else
        local state = nav and run == navRun and nav.state or "none"
        if state == "net" then state = "line" end
        read.state, read.points, read.n, read.yards, read.cost = state, nil, 0, 0, 0
        read.source, read.guessed, read.percent = state == "line" and "line" or nil, 0, 0
        read.straight = false
    end
    Leave(t0)
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
    local t0 = Enter()
    local x, y
    if Valid(run) and not AnySecret("ways", px, py) and type(px) == "number" and type(py) == "number" then
        if Follow(px, py) then
            -- (0.2.4 a7, S1.1) on the display, from its own place
            -- (0.2.4 a9, F4.3 §1: the straight line shown - the arrow turns to the node, as with the option off)
            if disp.kind == "straight" then
                x, y = nil, nil
            elseif disp.buf then
                x, y = DisplayArrow()
            else
                x, y = M.ArrowPoint(nav.core)
            end
        else
            Withdraw()
            nav.asked = false
        end
    end
    Leave(t0)
    return x, y
end)

-- The line of the run window (UI.lua): a text kept until the way changes, or nil.
-- (0.2.4 r1, Codex S1-N1) It may be the first to see that the way no longer holds and take
-- it back: that work counts for the frame like every other reader's.
ns.WaysSource = function(run)
    if not (nav and run == navRun and run == ns.run) or (ns.db and ns.db.routeWaysOff) then return nil end
    local t0 = Enter()
    local text
    if nav.core.state == "net" then
        if Valid(run) then text = nav.source else text = L["Path: straight line"] end
    elseif nav.state == "line" then
        text = L["Path: straight line"]
    end
    Leave(t0)
    return text
end

-- The option's switch (Options.lua). Off: everything of S1 ends in this
-- frame - the way is taken back and unseen, a request and a build are given
-- up, the net's lists are let go; the line is drawn again as it was before
-- S1 and the run window loses its line. On: the next head tick starts anew.
ns.WaysOptionChanged = Wrap("Ways", function()
    local t0 = Enter()
    if ns.db and ns.db.routeWaysOff then Release() end
    Leave(t0)
    if ns.RedrawRouteLine then ns.RedrawRouteLine() end
    if ns.UpdateRunSource then ns.UpdateRunSource() end
end)

-- Route.lua has dots to place or to take off: the work goes on
ns.WaysWork = function() work:Show() end
-- (0.2.4 a7, S1.1 B1) Route.lua's drawing step asks before each dot: 16 points of the line put into
-- world yards in one step at the most (a dot needs two at the most)
ns.WaysMapFull = function() return M.convs - convStep > MAP_POINTS - 2 end
-- (the tests) another geometry for the way shown, without a new way: the centre line again
ns.WaysPublishDisplay = function(buf, kind)
    if nav and nav.core.state == "net" then
        if not kind and M.displayCentreTest then buf, kind = nav.core.cf.view, "centre" end
        PublishDisplay(buf, kind or "straight")
    end
end
ns.WaysDisplay = function() return disp end
-- (the tests, S1.1 B3) the thread of the way shown, in one go, and shown when it is done
ns.WaysThreadNow = function()
    if not (nav and nav.core.state == "net") then return "none" end
    if disp.kind == "thread" then PublishDisplay(nil, "straight") end
    local state, reason = M.Thread(thread, nav.core.cf, nav.core.gen)
    if state == "done" then PublishDisplay(thread.f.view, "thread") end
    return state, reason
end
ns.WaysThread = function() return thread, threadWant, threadAsk end
-- Route.lua's own S1 work outside the steps (hiding a line, starting one) counts for the frame too
ns.WaysNow = Clock
-- (0.2.4 r1, Codex S1-N1) not counted twice when it comes inside a call that counts already
ns.WaysSpend = function(ms) if Outside() then Spend(ms) end end

-- /gcr perf on (Perf.lua): what S1 counted since the minute began, as the last piece of its line.
-- WaysPerf(true) starts the count anew.
--   largest frame: the most time all of S1 took in one frame (the limit is 1.0 ms);
--   longest step: of the work done in pieces (aimed at 0.125 ms, 0.5 ms is too long);
--   requests: ways asked for - given up (another one came, or the context went), late (not done in
--   2 s), dropped (done, but for a context that was no longer the one of now);
--   builds: nets built - late (not done in 5 s) counts with the requests' late, over the limits
--   (more than 8,000 squares or 20,000 edges: no net); taken back at once: a piece changed its
--   direction, pieces went, other saved data.
--   (0.2.4 a7, S1.1 B5, F4.1 §D) threads: smooth lines done (of them repaired with protective anchors) and
--   the ones given up - the centre line stays - by the counter, by the guard, by another error; the work
--   they booked (a passage or point looked at, a point written).
--   (0.2.4 a8, Codex M3) a change of what is shown: the most distances one read to find its place.
--   (0.2.4 a9, F4.5 §5, F4.6 §5) given up, the straight line stays (no longer the centre line); the ways of the net
--   published and of them the ones shown as a thread; the corners drawn round and the ones the check left sharp;
--   the ways with a corner to round and of them the ones with an arc (the two quotas of F4.6 §5).
ns.WaysPerf = function(reset)
    if reset then
        diag.peak, diag.step, diag.requests, diag.cancelled, diag.late = 0, 0, 0, 0, 0
        diag.over, diag.builds, diag.invalid, diag.dropped = 0, 0, 0, 0
        diag.threads, diag.repaired, diag.fellCount, diag.fellGuard, diag.fellOther, diag.booked = 0, 0, 0, 0, 0, 0
        diag.pubPeak = 0
        diag.ways, diag.shown, diag.arcs, diag.sharp, diag.roundWays, diag.arcWays = 0, 0, 0, 0, 0, 0
        diag.wayGen, diag.shownGen, diag.roundGen, diag.arcGen = -1, -1, -1, -1
        return
    end
    return ("ways: largest frame %.2f ms (limit %.1f), longest step %.2f ms, %d requests (%d given up, %d late, %d dropped), %d builds (%d over the limits), %d taken back at once; %d threads (%d repaired), %d on the straight line (%d counter, %d guard, %d other), %d booked; a change of what is shown read %d distances at the most; %d of %d ways shown as a thread; corners: %d drawn round, %d left sharp by the check; %d of %d ways with a corner to round have an arc")
        :format(diag.peak, FRAME_MS, diag.step, diag.requests, diag.cancelled, diag.late, diag.dropped, diag.builds, diag.over, diag.invalid,
            diag.threads, diag.repaired, diag.fellCount + diag.fellGuard + diag.fellOther, diag.fellCount, diag.fellGuard, diag.fellOther, diag.booked, diag.pubPeak,
            diag.shown, diag.ways, diag.arcs, diag.sharp, diag.arcWays, diag.roundWays)
end

-- for /gcr perf and the tests: the counters, and what is going on
ns.WaysDiag = function() return diag, frameSum end
ns.WaysState = function()
    return nav, net, req, ctx, ops, gen, work
end
ns.WaysLimits = function() return FRAME_MS, RESERVE_MS, STEP_MS, REQUEST_SECONDS, BUILD_SECONDS, REBUILD_PIECES end
