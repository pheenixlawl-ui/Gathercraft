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

-- Skill-up chance of a recipe at a skill: 1 orange, falling off to 0 at grey
function Core.Chance(skill, req, yellow, grey)
    if skill < req then return 0 end
    if skill < yellow then return 1 end
    if skill >= grey then return 0 end
    return (grey - skill) / (grey - yellow)
end
local Chance = Core.Chance

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

-- The recipes the plan can use, with what one craft costs to buy:
--   cost      the sum of the prices that are known or estimated
--   estimated one of them is an estimate
--   unknown   how many of its materials (pieces) have no price at all - such
--             a recipe is "not fully comparable": its cost is a part sum and
--             never wins a comparison because of it
local function Candidates(input)
    local list = {}
    for _, r in ipairs(Sorted(input.recipes[input.prof])) do
        if r.yellow and r.grey and r.reagents and #r.reagents > 0 and r.learn then
            local cost, estimated, unknown = 0, false, 0
            for _, reagent in ipairs(r.reagents) do
                local p = PriceOf(input, reagent.id)
                if p.status == "unknown" then
                    unknown = unknown + reagent.n
                else
                    cost = cost + p.copper * reagent.n
                    estimated = estimated or p.status == "estimated"
                end
            end
            list[#list + 1] = {
                key = r.key, name = r.name, product = r.product, made = r.made,
                req = math.max(1, r.req or 1), yellow = r.yellow, grey = r.grey, reagents = r.reagents,
                cost = cost, estimated = estimated, unknown = unknown, comparable = unknown == 0,
                how = r.learn, fee = r.fee, recipeItem = r.recipeItem,
            }
        end
    end
    return list
end

-- Per skill point the recipe to use: points[skill] = candidate, and where
-- the plan got stuck (if). Recipes whose whole cost is known (or estimated)
-- are compared by cost per expected point. One with a material nobody has a
-- price for is not fully comparable: it is taken only where no comparable
-- recipe gives a point - then the one with the fewest pieces without a
-- price - and the plan says so (notComparable).
local function ChoosePoints(input, cands)
    local points, current, stuck, notComparable = {}, nil, nil, false
    for skill = input.skill, input.target - 1 do
        local best, bestScore, bestGap
        -- below 5 % only when nothing else is left (a gap before the next recipe)
        for _, minChance in ipairs({ 0.05, 0 }) do
            for _, comparable in ipairs({ true, false }) do
                for _, c in ipairs(cands) do
                    local chance = Chance(skill, c.req, c.yellow, c.grey)
                    if chance > minChance and c.comparable == comparable then
                        local score = (c.cost + 1) / chance
                        local gap = c.unknown / chance
                        if c ~= current then score, gap = score * SWITCH_PENALTY, gap * SWITCH_PENALTY end
                        if not best or gap < bestGap or (gap == bestGap and score < bestScore) then
                            best, bestScore, bestGap = c, score, gap
                        end
                    end
                end
                if best then break end
            end
            if best then break end
        end
        if not best then
            stuck = skill
            break
        end
        if not best.comparable then notComparable = true end
        points[skill] = best
        current = best
    end
    return points, stuck, notComparable
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

local function Note(ctx, code, key, extra)
    local id = code .. ":" .. tostring(key)
    if ctx.noted[id] then return end
    ctx.noted[id] = true
    local d = extra or {}
    d.code = code
    ctx.diagnostics[#ctx.diagnostics + 1] = d
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
        local n = ctx.input.stock[id] or 0
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

-- The steps, carried out on the ledger. An extra craft of the planned
-- profession can give a skill point itself (concept 4.3): while such crafts
-- are needed and their recipe still gives points, they come as a step of
-- their own ("for materials") and count towards the skill with their chance
-- like any other craft - no point is promised, none is counted twice, and
-- the step after them starts later and needs less.
local function Walk(ctx, points, stuck)
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
        local segTo, expected = skill, 0
        while segTo < endSkill and points[segTo] == c do
            expected = expected + 1 / Chance(segTo, c.req, c.yellow, c.grey)
            segTo = segTo + 1
        end
        local crafts = math.ceil(expected - 0.001)
        -- what this segment would have to make extra, on a copy of the books
        local trial = CopyLedger(L)
        Apply(ctx, trial, c, crafts, skill)
        local material
        for _, r in ipairs(trial.extraList) do
            local more = trial.extra[r] - (L.extra[r] or 0)
            if more > 0 and r.prof == input.prof and r.yellow and r.grey then
                local chance = Chance(skill, math.max(1, r.req or 1), r.yellow, r.grey)
                local forPoint = chance > 0 and math.ceil(1 / chance - 0.001) or nil
                if forPoint and forPoint <= more then
                    material = { recipe = ctx.candOf[r.key] or r, crafts = forPoint, expected = 1 / chance, raw = r }
                    break
                end
            end
        end
        if material then
            Apply(ctx, L, material.raw, material.crafts, skill)
            local last = steps[#steps]
            if last and last.forMaterials and last.recipe == material.recipe then
                last.to, last.expected, last.crafts = skill + 1, last.expected + material.expected, last.crafts + material.crafts
            else
                steps[#steps + 1] = { recipe = material.recipe, from = skill, to = skill + 1, expected = material.expected,
                    crafts = material.crafts, forMaterials = true }
            end
            skill = skill + 1
        else
            Apply(ctx, L, c, crafts, skill)
            steps[#steps + 1] = { recipe = c, from = skill, to = segTo, expected = expected, crafts = crafts }
            skill = segTo
        end
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
-- and the ones used for extra crafts)
local function LearnCosts(input, steps, L)
    local seen = {}
    local c = { fees = 0, feesUnknown = 0, trainer = 0, items = 0, itemCost = 0, itemsUnknown = 0 }
    local function Count(how, fee, recipeItem, key)
        if seen[key] then return end
        seen[key] = true
        if how == "trainer" then
            c.trainer = c.trainer + 1
            if type(fee) == "number" then c.fees = c.fees + fee else c.feesUnknown = c.feesUnknown + 1 end
        elseif how == "vendor" then
            c.items = c.items + 1
            local price = recipeItem and input.recipeItemPrices and input.recipeItemPrices[recipeItem]
            if price then c.itemCost = c.itemCost + price else c.itemsUnknown = c.itemsUnknown + 1 end
        end
    end
    for _, s in ipairs(steps) do
        local r = s.recipe
        Count(r.how or r.learn, r.fee, r.recipeItem, r.key)
    end
    for _, r in ipairs(L.extraList) do
        if r.prof == input.prof then Count(r.learn, r.fee, r.recipeItem, r.key) end
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
--                diagnostics: stuck, a chain that leads back to itself) |
--                "invalid" (nothing to plan from: never shown as a plan)
--   valid, complete
--   steps        { recipe, from, to, expected, crafts, forMaterials }
--   materials    { id, need, have, missing, cost, node, planned, madeFrom }
--   ledger       [item] = { start, bought, madePlan, madeExtra, used, rest }
--   extras       { recipe, times } - the extra crafts, in the order first needed
--   cost         { known, estimated, estimatedItems, unknownItems } of what
--                is missing; total = known + estimated (never a made-up price)
--   notComparable  a recipe was chosen although a material of it has no price
--   stuck, learn, diagnostics
function Core.Compute(input)
    local why = Invalid(input)
    if why then
        return { status = "invalid", valid = false, complete = false, reason = why, steps = {}, materials = {}, ledger = {}, extras = {},
            total = 0, cost = { known = 0, estimated = 0, estimatedItems = {}, unknownItems = {} },
            learn = { fees = 0, feesUnknown = 0, trainer = 0, items = 0, itemCost = 0, itemsUnknown = 0, matsUnknown = 0 },
            diagnostics = { { code = "invalid", reason = why } } }
    end
    local ctx = { input = input, unit = {}, noted = {}, diagnostics = {}, producers = {} }
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
    local cands = Candidates(input)
    ctx.candOf = {}
    for _, c in ipairs(cands) do ctx.candOf[c.key] = c end
    local points, stuck, notComparable = ChoosePoints(input, cands)
    local steps, L = Walk(ctx, points, stuck)
    local materials, ledger, cost = Rows(ctx, L)
    local learn = LearnCosts(input, steps, L)
    learn.matsUnknown = #cost.unknownItems
    local extras = {}
    for _, r in ipairs(L.extraList) do extras[#extras + 1] = { recipe = r, times = L.extra[r] } end
    if stuck then Note(ctx, "stuck", stuck, { skill = stuck }) end
    local done = input.skill >= input.target
    local complete = not stuck and #ctx.diagnostics == 0
    return { prof = input.prof, from = input.skill, target = input.target,
        status = done and "done" or complete and "ok" or "incomplete", valid = true, complete = complete,
        steps = steps, materials = materials, ledger = ledger, extras = extras, stuck = stuck,
        cost = cost, total = cost.known + cost.estimated, notComparable = notComparable,
        learn = learn, diagnostics = ctx.diagnostics }
end
