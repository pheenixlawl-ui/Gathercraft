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
-- This part: the net (W1).
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

ns.WaysCore = M
