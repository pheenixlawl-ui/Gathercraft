local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Skill plan, the calculation (v0.2 building block 1, concept "Skill plan
-- 2.0" section 3.1): pure functions. Everything comes in through `input`,
-- the plan goes out as a table - no window, no event, no saved variable, no
-- game function is touched here, so the whole of it runs in a test without
-- the game. Planner.lua takes the snapshot, calls Compute and shows the plan.
--
-- input = {
--   prof     the profession to plan ("Leatherworking")
--   skill    your skill now (a number)
--   target   the skill to reach
--   maxRank  the highest skill your rank allows (nil: not known)
--   caps     where a rank ends when maxRank does not say ({ 75, 150, ... })
--   recipes  [profession] = { recipe, ... } - the planned profession's
--            recipes and the known ones of the professions you have
--     recipe = { prof, key, name, product (0: none), made (per craft),
--                req, yellow, grey, reagents = { { id, n }, ... },
--                learn = "known" | "trainer" | "vendor" | "start" | nil,
--                fee, recipeItem }
--   professions  [profession] = { rank = skill } for every one you have
--   stock    [item] = how many you have
--   prices   [item] = { status = "known" | "estimated" | "unknown",
--                       copper (nil when unknown), source, age (seconds) }
--            A price is never made up here: unknown stays unknown, in the
--            recipe choice, in every sum and in the plan (concept 4.5).
--   recipeItemPrices  [recipe item] = copper (a vendor showed it)
--   nodes    [item] = the node that gives it (for a farm run)
-- }
---------------------------------------------------------------------------
local Core = {}
ns.PlanCore = Core

local SWITCH_PENALTY = 1.08 -- a new recipe has to be this much better per point
local MIN_CHANCE = 0.05     -- below it only when nothing else gives a point
local LOOKAHEAD = 10        -- skill points a recipe is judged over (its one-time cost spread on them)
local DEFAULT_CAPS = { 75, 150, 225, 300 }

---------------------------------------------------------------------------
-- Chance and number of crafts (concept 4.1)
--   * the colours come from the recipe's thresholds; only yellow and grey
--     are shipped, a green threshold is not made up
--   * orange 1, between yellow and grey (grey - skill) / (grey - yellow),
--     grey 0 - the Classic rule, for WoW: Forever an ASSUMPTION until a
--     measurement says so (the craft log of 0.1.18 collects it)
--   * the model: crafts are independent, a success gives ONE point (Sven,
--     09.11.: at most one point per craft in Forever). More points from one
--     craft are not modelled; they would only make a plan end sooner.
--   * thresholds missing or wrong (grey below yellow): the chance is
--     UNKNOWN - not 0, not 1. Such a recipe is never counted with a number.
--   * chance 0: no number of crafts gets you there - never divided by it
---------------------------------------------------------------------------
function Core.Chance(skill, req, yellow, grey)
    if skill < req then return 0 end
    if skill < yellow then return 1 end
    if skill >= grey then return 0 end
    return (grey - skill) / (grey - yellow)
end
local Chance = Core.Chance

-- the chance of a recipe at a skill, or nil when its thresholds don't tell
function Core.ChanceOf(r, skill)
    local yellow, grey = r.yellow, r.grey
    if type(yellow) ~= "number" or type(grey) ~= "number" or grey < yellow then return nil end
    return Chance(skill, math.max(1, r.req or 1), yellow, grey)
end
local ChanceOf = Core.ChanceOf

-- The crafts it takes to get one point at each of the chances in `ps`, one
-- after the other: { expected, low, high }.
--   expected  the mean, sum of 1 / p
--   low, high the 10th and the 90th percentile of the number of crafts: the
--             smallest n with P(done within n crafts) >= 0.1 / 0.9
-- The distribution is worked out exactly (the probability of having j
-- points after n crafts, craft by craft) - no random numbers, so the same
-- input always gives the same range. It is a range of the MODEL, 8 in 10
-- runs inside it, not a promise of a least or a most.
-- nil when one of the chances is not above 0.
function Core.Attempts(ps)
    local m = #ps
    local expected = 0
    for i = 1, m do
        local p = ps[i]
        if type(p) ~= "number" or not (p > 0) then return nil end
        expected = expected + 1 / p
    end
    if m == 0 then return { expected = 0, low = 0, high = 0 } end
    local f = { [0] = 1 } -- f[j]: the probability of j points so far (j < m)
    for j = 1, m - 1 do f[j] = 0 end
    local done, low, high, n = 0, nil, nil, 0
    while not high and n < 100000 do
        n = n + 1
        for j = m - 1, 0, -1 do
            local move = f[j] * ps[j + 1]
            f[j] = f[j] - move
            if j + 1 == m then done = done + move else f[j + 1] = f[j + 1] + move end
        end
        if not low and done >= 0.1 - 1e-12 then low = n end
        if done >= 0.9 - 1e-12 then high = n end
    end
    return { expected = expected, low = low or n, high = high or n }
end

-- the same order whatever order the input came in
local function ByKey(a, b) return a.key < b.key end
local function Sorted(list)
    local out = {}
    for i, r in ipairs(list or {}) do out[i] = r end
    table.sort(out, ByKey)
    return out
end

-- A price as the calculation reads it: { status, copper, source, age }.
-- No entry, or one without a number, is unknown - never 0.
local UNKNOWN = { status = "unknown" }
local function PriceOf(input, id)
    local p = input.prices[id]
    if type(p) ~= "table" or type(p.copper) ~= "number" or p.status == "unknown" then return UNKNOWN end
    if p.status ~= "estimated" and p.status ~= "known" then
        return { status = "known", copper = p.copper, source = p.source, age = p.age }
    end
    return p
end
Core.PriceOf = PriceOf

-- how many of an item you have, as a number for the books
local function StockNumber(input, id)
    local s = input.stock[id]
    if type(s) == "number" then return s end
    return 0
end

local function Note(ctx, code, key, extra)
    local id = code .. ":" .. tostring(key)
    if ctx.noted[id] then return end
    ctx.noted[id] = true
    local d = extra or {}
    d.code = code
    ctx.diagnostics[#ctx.diagnostics + 1] = d
end

---------------------------------------------------------------------------
-- What you can make yourself, and what an item costs to get
---------------------------------------------------------------------------
local function Price(ctx, id) return PriceOf(ctx.input, id) end

local function CanMake(ctx, r, skillNow)
    if not (r.product and r.product > 0 and r.reagents and #r.reagents > 0) then return false end
    local input = ctx.input
    if r.prof == input.prof then
        -- known, or to be learned in the plan before it is needed
        return r.learn ~= nil and (r.req or 0) <= skillNow
    end
    local own = input.professions and input.professions[r.prof]
    return own ~= nil and own.rank ~= nil and r.learn == "known" and (r.req or 0) <= own.rank
end

-- What one unit costs to get at this point of the plan:
--   { copper (nil: not known), estimated, via = "buy" | "make" | nil, recipe }
-- A way with a whole cost (known or estimated) is compared by that cost,
-- buying wins a tie. A way with a gap is taken only when no way has a whole
-- cost: then making it (from things you may be able to get) before buying
-- at a price nobody knows.
local function UnitCost(ctx, id, skillNow, stack)
    local memoKey = id .. ":" .. skillNow
    if ctx.unit[memoKey] then return ctx.unit[memoKey] end
    local buy = Price(ctx, id)
    local best = { copper = buy.copper, estimated = buy.status == "estimated", via = buy.copper and "buy" or nil }
    if stack[id] then
        -- the chain came back to this item: not made from itself
        Note(ctx, "cycle", id, { item = id })
        best.cyclic = true
        return best
    end
    stack[id] = true
    for _, r in ipairs(ctx.producers[id] or {}) do
        if CanMake(ctx, r, skillNow) then
            local sum, known, cyclic, estimated = 0, true, false, false
            for _, reagent in ipairs(r.reagents) do
                local u = UnitCost(ctx, reagent.id, skillNow, stack)
                if u.cyclic then cyclic = true end -- this recipe needs the item it is meant to make
                if u.copper then
                    sum = sum + u.copper * reagent.n
                    estimated = estimated or u.estimated
                else
                    known = false
                end
            end
            if cyclic then
                -- left out: a chain back to itself is never carried out
            elseif known then
                local c = sum / math.max(1, r.made or 1)
                if not best.copper or c < best.copper then best = { copper = c, estimated = estimated, via = "make", recipe = r } end
            elseif not best.copper and not best.recipe then
                best = { via = "make", recipe = r } -- no price either way: something you can make beats nothing
            end
        end
    end
    stack[id] = nil
    ctx.unit[memoKey] = best
    return best
end

---------------------------------------------------------------------------
-- The recipe choice (concept 4.2)
--   What is compared, skill point by skill point: the gold you would have
--   to spend ON TOP of what you have for the crafts that point is expected
--   to take.
--   * what you have costs nothing, but it is reserved as the choice uses it:
--     the same stock does not make every later recipe free
--   * a material is counted at what it costs to buy or to make, whichever
--     is less (at that point of the plan)
--   * learning a recipe (trainer fee, recipe item) is a one-time cost,
--     spread over the points the recipe can still give (the next LOOKAHEAD
--     at most); once the plan has learned it, it costs nothing more
--   * a recipe with a part nobody has a price for (a material, its fee, its
--     recipe item) is not fully comparable: taken only where no comparable
--     recipe gives a point, then the one with the smallest gap
--   * a recipe of unknown chance is never compared with a number
--   A heuristic: a sensible plan, not proven to be the least costly one.
---------------------------------------------------------------------------
-- The recipes the plan can use (known, trainer, vendor, taught with the
-- profession - not quest or drop recipes you don't have), and the ones
-- whose chance is unknown
local function Candidates(input)
    local list, unknownChance = {}, {}
    for _, r in ipairs(Sorted(input.recipes[input.prof])) do
        if r.reagents and #r.reagents > 0 and r.learn then
            local c = {
                key = r.key, name = r.name, product = r.product, made = r.made, prof = r.prof,
                req = math.max(1, r.req or 1), yellow = r.yellow, grey = r.grey, reagents = r.reagents,
                how = r.learn, learn = r.learn, fee = r.fee, recipeItem = r.recipeItem, source = r,
            }
            if ChanceOf(r, c.req) == nil then unknownChance[#unknownChance + 1] = c else list[#list + 1] = c end
        end
    end
    return list, unknownChance
end

-- what learning a recipe costs, once: copper, and whether it is unknown
local function OneTime(ctx, c)
    if c.how == "known" or c.how == "start" or ctx.learned[c.key] then return 0, false end
    if c.how == "trainer" then
        if type(c.fee) == "number" then return c.fee, false end
        return 0, true
    end
    if c.how == "vendor" then
        local price = c.recipeItem and ctx.input.recipeItemPrices and ctx.input.recipeItemPrices[c.recipeItem]
        if type(price) == "number" then return price, false end
        return 0, true
    end
    return 0, false
end

local function Free(ctx, id)
    local a = ctx.avail[id]
    if a == nil then
        a = StockNumber(ctx.input, id)
        ctx.avail[id] = a
    end
    return a
end

-- a recipe for the point at `skill`: { score (copper for this point on top
-- of what you have, plus its share of the one-time cost), gap (pieces
-- without a price), comparable, estimated } - nil when it gives no point
-- here. What is in stock and not spoken for costs nothing; the one-time
-- cost of learning it is spread over the points it can still give within
-- the next LOOKAHEAD.
local function Evaluate(ctx, c, skill)
    local input = ctx.input
    local p = Chance(skill, c.req, c.yellow, c.grey)
    if p <= 0 then return nil end
    local crafts = 1 / p
    local pay, gap, estimated = 0, 0, false
    for _, reagent in ipairs(c.reagents) do
        local units = reagent.n * crafts
        local buy = units - math.min(Free(ctx, reagent.id), units)
        if buy > 1e-9 then
            local u = UnitCost(ctx, reagent.id, skill, {})
            if u.copper then
                pay = pay + u.copper * buy
                estimated = estimated or u.estimated
            else
                gap = gap + buy
            end
        end
    end
    local fee, feeUnknown = OneTime(ctx, c)
    if fee > 0 then
        local count = 0
        for s = skill, math.min(input.target, skill + LOOKAHEAD) - 1 do
            if Chance(s, c.req, c.yellow, c.grey) <= 0 then break end
            count = count + 1
        end
        pay = pay + fee / math.max(1, count)
    end
    if feeUnknown then gap = gap + 1 end
    return { score = pay + 1, gap = gap, comparable = gap == 0, estimated = estimated, fee = fee, feeUnknown = feeUnknown }
end

-- Per skill point the recipe to use: points[skill] = candidate, info[skill]
-- = how it was judged (for "why this recipe"), where the plan got stuck
-- (if), and whether a choice was not fully comparable.
local function ChoosePoints(ctx, cands, unknownChance)
    local input = ctx.input
    local points, info, current, stuck, notComparable, unknownAt = {}, {}, nil, nil, false, nil
    for skill = input.skill, input.target - 1 do
        local best, bestE, runner, runnerE
        for _, minChance in ipairs({ MIN_CHANCE, 0 }) do
            for _, comparable in ipairs({ true, false }) do
                for _, c in ipairs(cands) do
                    if Chance(skill, c.req, c.yellow, c.grey) > minChance then
                        local e = Evaluate(ctx, c, skill)
                        if e and e.comparable == comparable then
                            if c ~= current then e.score, e.gap = e.score * SWITCH_PENALTY, e.gap * SWITCH_PENALTY end
                            if not best or e.gap < bestE.gap or (e.gap == bestE.gap and e.score < bestE.score) then
                                runner, runnerE = best, bestE
                                best, bestE = c, e
                            elseif not runner or e.gap < runnerE.gap or (e.gap == runnerE.gap and e.score < runnerE.score) then
                                runner, runnerE = c, e
                            end
                        end
                    end
                end
                if best then break end
            end
            if best then break end
        end
        if not best then
            stuck = skill
            -- nothing with a known chance: is there a recipe whose chance nobody knows?
            for _, c in ipairs(unknownChance) do
                if c.req <= skill then unknownAt = unknownAt or c end
            end
            break
        end
        if not bestE.comparable then notComparable = true end
        points[skill] = best
        info[skill] = { score = bestE.score, comparable = bestE.comparable, estimated = bestE.estimated, fee = bestE.fee,
            other = runner and { name = runner.name, key = runner.key, score = runnerE.score, comparable = runnerE.comparable } or nil }
        -- this point is planned: its materials are spoken for, its output will be there
        local p = Chance(skill, best.req, best.yellow, best.grey)
        for _, reagent in ipairs(best.reagents) do
            local free = Free(ctx, reagent.id)
            ctx.avail[reagent.id] = free - math.min(free, reagent.n / p)
        end
        if best.product and best.product > 0 then
            ctx.avail[best.product] = Free(ctx, best.product) + (best.made or 1) / p
        end
        ctx.learned[best.key] = true
        current = best
    end
    return points, info, stuck, notComparable, unknownAt
end

---------------------------------------------------------------------------
-- Where a rank ends (concept 4.2): at the rank's maximum a craft gives no
-- point, so training the next rank is a step of the plan. Your own maximum
-- is known; the ranks after it are the usual ones (assumed, said so).
---------------------------------------------------------------------------
local function Training(input)
    local list, seen = {}, {}
    local maxRank = type(input.maxRank) == "number" and input.maxRank > 0 and input.maxRank or nil
    if maxRank and maxRank < input.target and maxRank >= input.skill then
        list[#list + 1] = { at = maxRank, assumed = false }
        seen[maxRank] = true
    end
    for _, cap in ipairs(input.caps or DEFAULT_CAPS) do
        if cap < input.target and cap >= input.skill and (not maxRank or cap > maxRank) and not seen[cap] then
            list[#list + 1] = { at = cap, assumed = true }
            seen[cap] = true
        end
    end
    table.sort(list, function(a, b) return a.at < b.at end)
    return list, seen
end

---------------------------------------------------------------------------
-- The material balance (concept 4.3): ONE stock per item for the whole plan,
-- worked through in the order the plan is carried out.
--   * the stock starts with what you have; a step first uses what is there,
--     then what it lacks is made or bought at that moment, then its own
--     output goes into the stock - so nothing made later stands in for an
--     ingredient needed earlier, and no stock ever goes below zero
--   * every ingredient and every output of a planned craft counts once
--   * an extra craft of an intermediate only for the need the stock does not
--     cover, in whole batches; what a batch makes too much stays in stock
--   * made yourself only when you really can: a recipe of the planned
--     profession that you know or can learn in the plan by then (skill,
--     trainer, vendor), or a known recipe of ANY other profession you have,
--     with the skill it needs. Buying is compared with making; of several
--     recipes the least costly one, the same one whatever order they came in
--   * a chain that leads back to itself is not made (reported, never hidden)
-- The books per item: start + bought + made by the steps + made extra
--                     = used + rest (Core.CheckBalance).
---------------------------------------------------------------------------
local function NewLedger()
    return { have = {}, start = {}, used = {}, bought = {}, madePlan = {}, madeExtra = {}, madeBy = {}, extra = {}, extraList = {} }
end

local function CopyLedger(L)
    local c = {}
    for k, v in pairs(L) do
        c[k] = {}
        for a, b in pairs(v) do c[k][a] = b end
    end
    return c
end

local function Stock(ctx, L, id)
    if L.have[id] == nil then
        local n = StockNumber(ctx.input, id)
        L.have[id], L.start[id] = n, n
    end
    return L.have[id]
end

local function ReagentsInOrder(r)
    local list = {}
    for i, reagent in ipairs(r.reagents) do list[i] = reagent end
    table.sort(list, function(a, b) return a.id < b.id end)
    return list
end

-- takes qty of an item out of the stock for a craft at this point of the
-- plan; what the stock lacks is made (with all it needs) or bought now
local function Take(ctx, L, id, qty, skillNow, stack)
    local have = Stock(ctx, L, id)
    local take = math.min(have, qty)
    L.have[id] = have - take
    L.used[id] = (L.used[id] or 0) + qty
    local rest = qty - take
    if rest <= 0 then return end
    local u = UnitCost(ctx, id, skillNow, {})
    if u.via == "make" and not stack[id] then
        local r = u.recipe
        local made = math.max(1, r.made or 1)
        local batches = math.ceil(rest / made - 1e-9)
        stack[id] = true
        for _, reagent in ipairs(ReagentsInOrder(r)) do
            Take(ctx, L, reagent.id, reagent.n * batches, skillNow, stack)
        end
        stack[id] = nil
        local produced = math.floor(batches * made + 1e-9)
        L.madeExtra[id] = (L.madeExtra[id] or 0) + produced
        L.have[id] = L.have[id] + produced - rest
        L.madeBy[id] = r
        if not L.extra[r] then
            L.extra[r] = 0
            L.extraList[#L.extraList + 1] = r
        end
        L.extra[r] = L.extra[r] + batches
    else
        L.bought[id] = (L.bought[id] or 0) + rest
    end
end

-- one planned craft step: its ingredients out, then its output in
local function Apply(ctx, L, recipe, crafts, skillNow)
    for _, reagent in ipairs(ReagentsInOrder(recipe)) do
        Take(ctx, L, reagent.id, reagent.n * crafts, skillNow, {})
    end
    local product = recipe.product
    if product and product > 0 then
        local out = math.floor((recipe.made or 1) * crafts + 1e-9)
        Stock(ctx, L, product)
        L.have[product] = L.have[product] + out
        L.madePlan[product] = (L.madePlan[product] or 0) + out
    end
end

-- The steps, carried out on the ledger. A step never runs across the end of
-- a rank (training comes between). An extra craft of the planned profession
-- can give a skill point itself (concept 4.3): while such crafts are needed
-- and their recipe still gives points, they come as a step of their own
-- ("for materials") and count towards the skill with their chance like any
-- other craft - no point is promised, none is counted twice, and the step
-- after them starts later and needs less.
local function Walk(ctx, points, info, stuck, trainAt)
    local input = ctx.input
    local L = NewLedger()
    local steps = {}
    local endSkill = stuck or input.target
    local skill = input.skill
    local guard = 0
    while skill < endSkill do
        guard = guard + 1
        if guard > 5000 then break end
        local c = points[skill]
        local segTo, expected, ps = skill, 0, {}
        while segTo < endSkill and points[segTo] == c and not (segTo > skill and trainAt[segTo]) do
            local p = Chance(segTo, c.req, c.yellow, c.grey)
            ps[#ps + 1] = p
            expected = expected + 1 / p
            segTo = segTo + 1
        end
        local crafts = math.ceil(expected - 0.001)
        -- what this segment would have to make extra, on a copy of the books
        local trial = CopyLedger(L)
        Apply(ctx, trial, c, crafts, skill)
        local material
        for _, r in ipairs(trial.extraList) do
            local more = trial.extra[r] - (L.extra[r] or 0)
            if more > 0 and r.prof == input.prof then
                local chance = ChanceOf(r, skill)
                local forPoint = chance and chance > 0 and math.ceil(1 / chance - 0.001) or nil
                if forPoint and forPoint <= more then
                    material = { recipe = ctx.candOf[r.key] or r, crafts = forPoint, expected = 1 / chance, raw = r, p = chance }
                    break
                end
            end
        end
        if material then
            Apply(ctx, L, material.raw, material.crafts, skill)
            local last = steps[#steps]
            if last and last.forMaterials and last.recipe == material.recipe and not trainAt[skill] then
                last.to, last.expected, last.crafts = skill + 1, last.expected + material.expected, last.crafts + material.crafts
                last.ps[#last.ps + 1] = material.p
            else
                steps[#steps + 1] = { recipe = material.recipe, from = skill, to = skill + 1, expected = material.expected,
                    crafts = material.crafts, forMaterials = true, ps = { material.p }, comparable = true }
            end
            skill = skill + 1
        else
            Apply(ctx, L, c, crafts, skill)
            local step = { recipe = c, from = skill, to = segTo, expected = expected, crafts = crafts, ps = ps, comparable = true, estimated = false }
            for s = skill, segTo - 1 do
                local i = info[s]
                if i then
                    if not i.comparable then step.comparable = false end
                    if i.estimated then step.estimated = true end
                end
            end
            step.why = info[skill]
            steps[#steps + 1] = step
            skill = segTo
        end
    end
    for _, s in ipairs(steps) do
        local a = Core.Attempts(s.ps)
        s.low, s.high = a and a.low or s.crafts, a and a.high or s.crafts
        s.chanceFrom, s.chanceTo = s.ps[1], s.ps[#s.ps]
    end
    return steps, L
end

-- the material rows, the books behind them, and what the missing ones cost:
--   cost = { known = sum of known prices, estimated = sum of estimated ones,
--            estimatedItems = { id, ... }, unknownItems = { id, ... } }
-- A missing material without a price is in unknownItems, in no sum.
local function Rows(ctx, L)
    local input = ctx.input
    local list, ledger = {}, {}
    local cost = { known = 0, estimated = 0, estimatedItems = {}, unknownItems = {} }
    local ids = {}
    for id in pairs(L.used) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local missing = L.bought[id] or 0
        local price = Price(ctx, id)
        local copper, status = 0, "none" -- nothing to buy: no cost
        if missing > 0 then
            status = price.status
            copper = price.copper and price.copper * missing or nil
            if status == "known" then
                cost.known = cost.known + copper
            elseif status == "estimated" then
                cost.estimated = cost.estimated + copper
                cost.estimatedItems[#cost.estimatedItems + 1] = id
            else
                cost.unknownItems[#cost.unknownItems + 1] = id -- not 0: unknown
            end
        end
        local by = (L.madeExtra[id] or 0) > 0 and L.madeBy[id] or nil
        list[#list + 1] = { id = id, need = L.used[id], have = L.start[id] or 0, missing = missing, cost = copper, costStatus = status,
            price = price, node = input.nodes and input.nodes[id], planned = L.madePlan[id] or 0,
            madeFrom = by and { prof = by.prof, key = by.key, made = math.max(1, by.made or 1), reagents = by.reagents, recipe = by } or nil }
    end
    for id in pairs(L.have) do
        ledger[id] = { start = L.start[id] or 0, bought = L.bought[id] or 0, madePlan = L.madePlan[id] or 0,
            madeExtra = L.madeExtra[id] or 0, used = L.used[id] or 0, rest = L.have[id] }
    end
    table.sort(list, function(a, b)
        if (a.madeFrom ~= nil) ~= (b.madeFrom ~= nil) then return b.madeFrom ~= nil end
        if a.missing ~= b.missing then return a.missing > b.missing end
        return a.id < b.id
    end)
    return list, ledger, cost
end

-- The books of a plan, checked: for every item start + bought + made =
-- used + rest, and nothing below zero. true, or false and what is wrong.
function Core.CheckBalance(plan)
    for id, b in pairs(plan.ledger or {}) do
        if b.start + b.bought + b.madePlan + b.madeExtra ~= b.used + b.rest then
            return false, ("item %d: %d + %d + %d + %d is not %d + %d"):format(id, b.start, b.bought, b.madePlan, b.madeExtra, b.used, b.rest)
        end
        for k, v in pairs(b) do
            if v < 0 then return false, ("item %d: %s is %d"):format(id, k, v) end
        end
    end
    return true
end

-- What the recipes of the plan cost to learn, once each (the steps' recipes
-- and the ones used for extra crafts), and the list of them
local function LearnCosts(input, steps, L)
    local seen = {}
    local c = { fees = 0, feesUnknown = 0, trainer = 0, items = 0, itemCost = 0, itemsUnknown = 0, list = {} }
    local function Count(r, how, fee, recipeItem, key, at)
        if seen[key] then return end
        seen[key] = true
        if how == "trainer" then
            c.trainer = c.trainer + 1
            local known = type(fee) == "number"
            if known then c.fees = c.fees + fee else c.feesUnknown = c.feesUnknown + 1 end
            c.list[#c.list + 1] = { recipe = r, how = how, cost = known and fee or nil, at = at }
        elseif how == "vendor" then
            c.items = c.items + 1
            local price = recipeItem and input.recipeItemPrices and input.recipeItemPrices[recipeItem]
            if type(price) == "number" then c.itemCost = c.itemCost + price else c.itemsUnknown = c.itemsUnknown + 1 price = nil end
            c.list[#c.list + 1] = { recipe = r, how = how, cost = price, recipeItem = recipeItem, at = at }
        end
    end
    for _, s in ipairs(steps) do
        local r = s.recipe
        Count(r, r.how or r.learn, r.fee, r.recipeItem, r.key, s.from)
    end
    for _, r in ipairs(L.extraList) do
        if r.prof == input.prof then Count(r, r.learn, r.fee, r.recipeItem, r.key) end
    end
    return c
end

-- Is the input something a plan can be made from? nil, or why not.
local function Invalid(input)
    if type(input) ~= "table" then return "no input" end
    if type(input.prof) ~= "string" then return "no profession" end
    if type(input.skill) ~= "number" then return "no skill" end
    if type(input.target) ~= "number" then return "no target" end
    if type(input.recipes) ~= "table" or type(input.recipes[input.prof]) ~= "table" then return "no recipes" end
    if type(input.stock) ~= "table" or type(input.prices) ~= "table" then return "no stock or prices" end
    if #input.recipes[input.prof] == 0 then return "no recipes" end
end

-- The plan:
--   status       "ok" | "done" (you are there) | "incomplete" (it says so in
--                diagnostics: stuck, a recipe of unknown chance, a chain that
--                leads back to itself) | "invalid" (nothing to plan from:
--                never shown as a plan)
--   valid, complete
--   steps        { recipe, from, to, expected, crafts, low, high (the model's
--                80 % range of crafts), chanceFrom, chanceTo, forMaterials,
--                comparable, estimated, why } and, last, a step of unknown
--                chance { recipe, from, chanceUnknown = true } where the
--                plan cannot go on with a number
--   training     { at, assumed } - where the next rank has to be trained
--   materials    { id, need, have, missing, cost, costStatus, price, node,
--                planned, madeFrom }
--   ledger       [item] = { start, bought, madePlan, madeExtra, used, rest }
--   extras       { recipe, times } - the extra crafts, in the order first needed
--   cost         { known, estimated, estimatedItems, unknownItems } of what
--                is missing; total = known + estimated (never a made-up price)
--   crafts       the expected number of crafts of all steps (a sum of means;
--                the steps' ranges are not added up - concept 4.1)
--   notComparable  a recipe was chosen although a part of its cost is unknown
--   stuck, learn, diagnostics
function Core.Compute(input)
    local why = Invalid(input)
    if why then
        return { status = "invalid", valid = false, complete = false, reason = why, steps = {}, training = {}, materials = {}, ledger = {}, extras = {},
            total = 0, crafts = 0, cost = { known = 0, estimated = 0, estimatedItems = {}, unknownItems = {} },
            learn = { fees = 0, feesUnknown = 0, trainer = 0, items = 0, itemCost = 0, itemsUnknown = 0, matsUnknown = 0, list = {} },
            diagnostics = { { code = "invalid", reason = why } } }
    end
    local ctx = { input = input, unit = {}, noted = {}, diagnostics = {}, producers = {}, avail = {}, learned = {} }
    local profs = {}
    for prof in pairs(input.recipes) do profs[#profs + 1] = prof end
    table.sort(profs, function(a, b) -- the planned profession's recipes first
        if (a == input.prof) ~= (b == input.prof) then return a == input.prof end
        return a < b
    end)
    for _, prof in ipairs(profs) do
        for _, r in ipairs(Sorted(input.recipes[prof])) do
            if r.product and r.product > 0 and r.reagents and #r.reagents > 0 then
                ctx.producers[r.product] = ctx.producers[r.product] or {}
                table.insert(ctx.producers[r.product], r)
            end
        end
    end
    local cands, unknownChance = Candidates(input)
    ctx.candOf = {}
    for _, c in ipairs(cands) do ctx.candOf[c.key] = c end
    local points, info, stuck, notComparable, unknownAt = ChoosePoints(ctx, cands, unknownChance)
    local training, trainAt = Training(input)
    local steps, L = Walk(ctx, points, info, stuck, trainAt)
    local materials, ledger, cost = Rows(ctx, L)
    local learn = LearnCosts(input, steps, L)
    learn.matsUnknown = #cost.unknownItems
    local extras = {}
    for _, r in ipairs(L.extraList) do extras[#extras + 1] = { recipe = r, times = L.extra[r] } end
    local crafts = 0
    for _, s in ipairs(steps) do crafts = crafts + s.expected end
    if stuck then Note(ctx, "stuck", stuck, { skill = stuck }) end
    if unknownAt then
        -- the plan cannot go on with a number: the recipe is named, not counted
        Note(ctx, "chance_unknown", unknownAt.key, { skill = stuck, recipe = unknownAt.key })
        steps[#steps + 1] = { recipe = unknownAt, from = stuck, to = stuck, chanceUnknown = true }
    end
    local done = input.skill >= input.target
    local complete = not stuck and #ctx.diagnostics == 0
    return { prof = input.prof, from = input.skill, target = input.target,
        status = done and "done" or complete and "ok" or "incomplete", valid = true, complete = complete,
        steps = steps, training = training, materials = materials, ledger = ledger, extras = extras, stuck = stuck,
        cost = cost, total = cost.known + cost.estimated, crafts = crafts, notComparable = notComparable,
        learn = learn, diagnostics = ctx.diagnostics }
end
