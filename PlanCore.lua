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
--     recipe = { prof, key, name, product (0: none), made (per craft;
--                madeVaries = true when a craft makes a varying number
--                and made is the mean of it),
--                req, yellow, grey, reagents = { { id, n }, ... },
--                learn = "known" | "trainer" | "vendor" | "start" | nil,
--                fee, recipeItem }
--   professions  [profession] = { rank = skill } for every one you have
--   stock    [item] = how many you have: a number, or { n = number,
--            bags, reagent, bank, ... } with the parts for the window, or
--            { unknown = true } when it could not be read. "Could not be
--            read" is not 0 (concept 4.4): the books then go on with 0 so
--            the plan stays carried out, but the row says the count is not
--            known, gets no tick, and the plan is not called complete.
--            An item the snapshot does not list counts as none.
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
--
-- AMOUNTS ARE A PLANNING ESTIMATE (Sven, 10.11.2026, after Codex round 1,
-- B3 - a deliberate change of concept 4.1 / 4.3 for 0.2):
--   * a step is counted with the rounded-up MEAN number of its crafts
--     (rather a little too much than too little). The materials, the
--     outputs and the cost of the whole plan follow from these numbers.
--   * that is NOT an expected value over all the ways a plan can go: when a
--     step takes fewer crafts than its mean, a later step may lack what the
--     missing crafts would have made, and the other way round. Such joint
--     effects are not modelled (Codex' case JOINT_EXPECTATION: 2 here, 2.5
--     on average over all ways).
--   * extra crafts "for materials" count towards the skill only as a whole
--     point, once the crafts needed reach the mean for one - never a part
--     of a point, so no point is counted that mostly does not come. Their
--     materials and their output are counted in full either way.
--   * a craft that makes a varying number of items is counted with the mean
--     of it (Varies below): an assumption, marked on the step and on the
--     items that rest on it - no known amount.
--   The plan says all this about itself: plan.estimate = { crafts (a step's
--   number of crafts is a mean), output (a varying output was counted with
--   its mean) }, step.outputAssumed, material.outputAssumed.
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

-- how many of an item you have: the number for the books, and whether it
-- is known at all
local function StockNumber(input, id)
    local s = input.stock[id]
    if type(s) == "number" then return s, true end
    if type(s) == "table" then
        if s.unknown or type(s.n) ~= "number" then return 0, false end
        return s.n, true
    end
    return 0, true -- not listed: none
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

-- a recipe as the books know it when it is learned: by its profession and
-- its key (two professions may each have a recipe of the same name)
local function RecipeId(r) return tostring(r.prof) .. "/" .. tostring(r.key) end

-- what learning a recipe costs, once: copper, and whether it is unknown.
-- `learned`: the recipes the plan has learned by now (they cost nothing more)
local function OneTime(ctx, r, learned)
    local how = r.how or r.learn
    if how == "known" or how == "start" or learned[RecipeId(r)] then return 0, false end
    if how == "trainer" then
        if type(r.fee) == "number" then return r.fee, false end
        return 0, true
    end
    if how == "vendor" then
        local price = r.recipeItem and ctx.input.recipeItemPrices and ctx.input.recipeItemPrices[r.recipeItem]
        if type(price) == "number" then return price, false end
        return 0, true
    end
    return 0, false
end

-- does a craft of this recipe make a varying number of items? (said by the
-- snapshot, or to be seen from a mean that is no whole number)
local function Varies(r)
    return r.madeVaries == true or (type(r.made) == "number" and r.made % 1 ~= 0)
end

-- the ingredients of a recipe, always in the same order
local function Reagents(ctx, r)
    local list = ctx.sorted[r.reagents]
    if not list then
        list = {}
        for i, reagent in ipairs(r.reagents) do list[i] = reagent end
        table.sort(list, function(a, b) return a.id < b.id end)
        ctx.sorted[r.reagents] = list
    end
    return list
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
--     with the skill it needs
--   * a chain that leads back to itself is not made (reported, never hidden)
-- The books per item: start + bought + made by the steps + made extra
--                     = used + rest (Core.CheckBalance).
--
-- The books can be tried out: Mark, do something, look at what it cost, and
-- Rollback puts every entry back (or Keep leaves it). That is how buying is
-- compared with making - on the same books, in the state they are in when
-- the need comes up - and how the recipe choice asks what a point would cost.
---------------------------------------------------------------------------
local EPS = 1e-9

-- fractional: the books of the recipe choice. They count in expected
-- amounts (1 / chance crafts for a point, parts of a batch); the plan's own
-- books count whole crafts and whole batches.
local function NewLedger(fractional)
    return { have = {}, start = {}, used = {}, bought = {}, madePlan = {}, madeExtra = {}, madeBy = {}, extra = {}, extraList = {},
        unknown = {}, learned = {}, varies = {}, journal = {}, jn = 0, marks = 0, fractional = fractional or false, share = 1 }
end

-- every entry of the books is written through here, so it can be taken back
local function W(L, name, key, value)
    local t = rawget(L, name)
    if L.marks > 0 then
        local j, n = L.journal, L.jn
        j[n + 1], j[n + 2], j[n + 3] = name, key, t[key]
        L.jn = n + 3
    end
    t[key] = value
end
local function Mark(L)
    L.marks = L.marks + 1
    return L.jn
end
local function Rollback(L, mark)
    local j = L.journal
    for i = L.jn - 2, mark + 1, -3 do
        rawget(L, j[i])[j[i + 1]] = j[i + 2]
    end
    L.jn = mark
    L.marks = L.marks - 1
    if L.marks == 0 then L.journal, L.jn = {}, 0 end
end
local function Keep(L)
    L.marks = L.marks - 1
    if L.marks == 0 then L.journal, L.jn = {}, 0 end
end
-- what was written since the mark, to be written again later without
-- deciding everything again (on the books as they were at the mark)
local function Capture(L, mark)
    local j, out, n = L.journal, {}, 0
    for i = mark + 1, L.jn, 3 do
        local name, key = j[i], j[i + 1]
        out[n + 1], out[n + 2], out[n + 3] = name, key, rawget(L, name)[key]
        n = n + 3
    end
    out.n = n
    return out
end
local function Replay(L, writes)
    for i = 1, writes.n, 3 do W(L, writes[i], writes[i + 1], writes[i + 2]) end
end

local function Stock(ctx, L, id)
    local have = L.have[id]
    if have == nil then
        local n, known = StockNumber(ctx.input, id)
        W(L, "have", id, n)
        W(L, "start", id, n)
        if not known then W(L, "unknown", id, true) end
        have = n
    end
    return have
end

---------------------------------------------------------------------------
-- Getting what the stock lacks: buy it or make it (concept 4.2 / 4.5; Codex
-- round 1, B1). Decided for THIS need - the amount that is lacking now -
-- by what each way costs on top of what you have, tried out on the books:
--   * what is in stock is free, also the raw materials further down (and it
--     is used up as it is used: the same piece is not free twice)
--   * making it costs whole batches; what a batch makes too much is no saving
--   * a recipe the plan has not learned yet costs its fee or its recipe item,
--     once
--   * ways to choose from: buy all of it; make all of it; or make batch by
--     batch as long as a batch costs less than buying what it replaces, and
--     buy the rest (so raw stock for a part of the need is used for that part)
--   * a way with a whole cost (known or estimated) is compared by that cost,
--     buying keeps a tie. A way with a part nobody knows (a price, a fee)
--     never wins by its known part: it is taken only when no way has a whole
--     cost - then making it (from things you may be able to get) before
--     buying at a price nobody knows.
--   * when such a way of MAKING it could have been the less costly one (its
--     known part is below the cost of the way taken), the choice is marked
--     open: the plan is then not called fully comparable. (No price to buy
--     the item itself next to a wholly known way to make it is not open, as
--     before: there is nothing to compare the making with.)
-- What it cost goes into `acc`:
--   copper  materials bought at a known or estimated price
--   once    one-time learning costs of the recipes used for it
--   gap     pieces without a price, fees nobody knows (0: a whole cost)
--   estimated, priceGap, feeGap, open, openPrice, openLearn  what kind
--   lumpy   a cost in it does not grow with the amount: a one-time cost, or
--           a batch that made more than was needed
-- Each need is decided when it comes up; what a later step may still need
-- of the same thing is not counted in (a heuristic, like the recipe choice).
---------------------------------------------------------------------------
local function NewAcc() return { copper = 0, once = 0, gap = 0 } end

local function Add(into, a)
    into.copper, into.once, into.gap = into.copper + a.copper, into.once + a.once, into.gap + a.gap
    if a.estimated then into.estimated = true end
    if a.priceGap then into.priceGap = true end
    if a.feeGap then into.feeGap = true end
    if a.open then into.open = true end
    if a.openPrice then into.openPrice = true end
    if a.openLearn then into.openLearn = true end
    if a.lumpy then into.lumpy = true end
end

-- what a way costs when it is compared: its one-time costs count whole in
-- the plan's books, with the recipe's share in the recipe choice (L.share)
local function Value(L, a) return a.copper + a.once * L.share end

local function Produced(L, batches, made)
    local n = batches * made
    if L.fractional then return n end
    return math.floor(n + 1e-9)
end

local Take

local function Buy(ctx, L, id, rest, acc)
    W(L, "bought", id, (L.bought[id] or 0) + rest)
    local price = PriceOf(ctx.input, id)
    if price.copper then
        acc.copper = acc.copper + price.copper * rest
        if price.status == "estimated" then acc.estimated = true end
    else
        acc.gap = acc.gap + rest -- not 0: unknown
        acc.priceGap = true
    end
end

-- the ingredients of `batches` crafts of r out of the stock (and what that
-- lacks, in turn, made or bought)
local function Batches(ctx, L, id, r, batches, skillNow, stack, acc)
    stack[id] = true
    for _, reagent in ipairs(Reagents(ctx, r)) do
        Take(ctx, L, reagent.id, reagent.n * batches, skillNow, stack, acc)
    end
    stack[id] = nil
end

-- the crafts are done: learned (once), their output into the books; `covered`
-- of it goes straight to the need they were made for
local function Made(ctx, L, id, r, batches, covered, acc)
    local recipeId = RecipeId(r)
    if not L.learned[recipeId] then
        local fee, unknown = OneTime(ctx, r, L.learned)
        acc.once = acc.once + fee
        if fee > 0 then acc.lumpy = true end
        if fee > 0 or unknown then
            ctx.touched = ctx.touched + 1
            if ctx.measure then ctx.measure.deps["#" .. recipeId] = true end
        end
        if unknown then
            acc.gap = acc.gap + 1
            acc.feeGap = true
        end
        W(L, "learned", recipeId, true)
    end
    local produced = Produced(L, batches, math.max(1, r.made or 1))
    if produced - covered > EPS then acc.lumpy = true end
    W(L, "madeExtra", id, (L.madeExtra[id] or 0) + produced)
    W(L, "have", id, Stock(ctx, L, id) + produced - covered)
    W(L, "madeBy", id, r)
    if Varies(r) then
        -- how many crafts that takes rests on the mean output: the item
        -- and what the crafts use are counted on an assumption
        W(L, "varies", id, true)
        for _, reagent in ipairs(r.reagents) do W(L, "varies", reagent.id, true) end
    end
    if not L.extra[r] then
        W(L, "extra", r, 0)
        W(L, "extraList", #L.extraList + 1, r)
    end
    W(L, "extra", r, L.extra[r] + batches)
end

local function MakeAll(ctx, L, id, r, rest, skillNow, stack, acc)
    local batches = rest / math.max(1, r.made or 1)
    if not L.fractional then batches = math.ceil(batches - 1e-9) end
    Batches(ctx, L, id, r, batches, skillNow, stack, acc)
    Made(ctx, L, id, r, batches, rest, acc)
end

-- batch by batch, as long as the next batch costs less than buying what it
-- replaces; what is left is bought. Returns the batches made, what was
-- bought, and whether making ALL of it can still be the better way: it
-- cannot when the batch that was turned down cost plainly by the piece (no
-- one-time cost in it, no batch further down that made more than needed) -
-- stock only gets less, so no later batch costs less than that one.
-- (The one-time cost of learning r is not part of a batch: it counts when
-- this way is compared with the others.)
local function MakeSome(ctx, L, id, r, rest, skillNow, stack, acc)
    local price = PriceOf(ctx.input, id)
    local made = math.max(1, r.made or 1)
    local remaining, batches, allCanWin = rest, 0, false
    local whole = made == math.floor(made) -- (a mean output like 1.5 is counted batch by batch)
    local try -- the size of the next lot: twice the one that was just taken
    while remaining > EPS do
        -- Many batches that all cost the same are judged in one go: as long
        -- as no stock runs out inside them and no cost in them is a
        -- one-time one, each of them costs what the others cost. Where that
        -- is not so, the lot is halved until it is, down to a single batch;
        -- after a lot that was taken the next one may be twice as big (so
        -- the place where a stock runs out is found in a few tries, and
        -- what comes after it is one lot again).
        local b = 1
        if L.fractional then
            b = remaining / made
        elseif whole and remaining >= made then
            b = math.floor(remaining / made + 1e-9)
        end
        if try and try < b then b = try end
        local taken = false
        while true do
            local covers = math.min(remaining, Produced(L, batches + b, made) - Produced(L, batches, made))
            local a = NewAcc()
            local edges = ctx.edges
            local mark = Mark(L)
            Batches(ctx, L, id, r, b, skillNow, stack, a)
            if b > 1 + EPS and (ctx.edges ~= edges or a.lumpy) then
                Rollback(L, mark)
                b = b / 2
                if not L.fractional then b = math.floor(b) end
                if b < 1 then b = 1 end
            elseif a.cyclic or a.gap > 0 or Value(L, a) >= price.copper * covers then
                allCanWin = not a.cyclic and (a.gap > 0 or a.lumpy or false)
                Rollback(L, mark)
                break
            else
                Keep(L)
                Add(acc, a)
                batches, remaining, taken = batches + b, remaining - covers, true
                try = b * 2
                break
            end
        end
        if not taken then break end
    end
    if batches > 0 then Made(ctx, L, id, r, batches, rest - remaining, acc) end
    if remaining > EPS then Buy(ctx, L, id, remaining, acc) else remaining = 0 end
    return batches, remaining, allCanWin
end

-- is way `w` to be taken instead of `than`? (the earlier one keeps a tie)
local function Better(L, w, than)
    local a, b = w.acc, than.acc
    local wholeA, wholeB = a.gap == 0, b.gap == 0
    if wholeA ~= wholeB then return wholeA end
    if wholeA then return Value(L, a) < Value(L, b) end
    -- no way has a whole cost: making before buying at a price nobody knows
    if (w.kind == "buy") ~= (than.kind == "buy") then return than.kind == "buy" end
    if a.gap ~= b.gap then return a.gap < b.gap end
    return Value(L, a) < Value(L, b)
end

-- `rest` of an item the stock does not have, for a craft at this point of
-- the plan: the least costly way is carried out on the books
local function GetExact(ctx, L, id, rest, skillNow, stack, acc)
    if stack[id] then
        -- the chain came back to this item: it is not made from itself. The
        -- way that led here is dropped by the one that tried it. Reported
        -- when the plan's own books meet it - not when the recipe choice
        -- only looked at a recipe with such a chain.
        if not L.fractional then Note(ctx, "cycle", id, { item = id }) end
        ctx.touched = ctx.touched + 1
        acc.cyclic = true
        Buy(ctx, L, id, rest, acc)
        return
    end
    local price = PriceOf(ctx.input, id)
    local buy = NewAcc()
    if price.copper then
        buy.copper, buy.estimated = price.copper * rest, price.status == "estimated"
    else
        buy.gap, buy.priceGap = rest, true
    end
    local best = { kind = "buy", acc = buy }
    local ways = { best }
    for _, r in ipairs(ctx.producers[id] or {}) do
        local m = ctx.measure
        if m and r.prof == ctx.input.prof and r.learn ~= nil and (r.req or 0) > skillNow and r.req < m.till then
            m.till = r.req -- (from that skill on the recipe can be used: worked out again then)
        end
        if CanMake(ctx, r, skillNow) then
            local tryAll = true
            if price.copper then
                local a = NewAcc()
                local mark = Mark(L)
                local batches, bought, allCanWin = MakeSome(ctx, L, id, r, rest, skillNow, stack, a)
                if batches > 0 then ways[#ways + 1] = { kind = "some", recipe = r, acc = a, writes = Capture(L, mark) } end
                Rollback(L, mark)
                tryAll = bought > 0 and allCanWin
            end
            if tryAll then
                local a = NewAcc()
                local mark = Mark(L)
                MakeAll(ctx, L, id, r, rest, skillNow, stack, a)
                if not a.cyclic then ways[#ways + 1] = { kind = "all", recipe = r, acc = a, writes = Capture(L, mark) } end
                Rollback(L, mark)
            end
        end
    end
    for _, w in ipairs(ways) do
        if Better(L, w, best) then best = w end
    end
    if best.acc.gap == 0 then
        for _, w in ipairs(ways) do
            if w.kind ~= "buy" and w.acc.gap > 0 and Value(L, w.acc) < Value(L, best.acc) then
                -- a way to make it, with a part nobody knows, could have cost less
                acc.open = true
                if w.acc.feeGap then acc.openLearn = true end
                if w.acc.priceGap then acc.openPrice = true end
            end
        end
    end
    if best.kind == "buy" then
        Buy(ctx, L, id, rest, acc)
    else
        -- as it was tried: written again, not decided again
        Replay(L, best.writes)
        Add(acc, best.acc)
    end
end

-- The recipe choice asks for the same things again and again, point after
-- point and recipe after recipe. Where getting an item touches no stock, no
-- one-time cost and no chain back to itself - nothing in it and below it -
-- its cost simply grows with the amount: it has been worked out for one
-- piece (Measure, below) and is counted by the piece. Such an item changes
-- nothing the choice's books are kept for (what is in stock, what is
-- learned), so nothing is written for it. Everything else, and all of the
-- plan's own books, is worked out in full every time.
local function Get(ctx, L, id, rest, skillNow, stack, acc)
    local e = L.fractional and ctx.unit[id]
    if not (e and e.linear and skillNow < e.till) then return GetExact(ctx, L, id, rest, skillNow, stack, acc) end
    local unit = e.acc
    acc.copper, acc.gap = acc.copper + unit.copper * rest, acc.gap + unit.gap * rest
    if unit.estimated then acc.estimated = true end
    if unit.priceGap then acc.priceGap = true end
    if unit.open then acc.open = true end
    if unit.openPrice then acc.openPrice = true end
    local m = ctx.measure
    if m then
        -- what this rests on, the one being measured rests on as well
        for dep in pairs(e.deps) do m.deps[dep] = true end
        if e.till < m.till then m.till = e.till end
    end
end

-- takes qty of an item out of the stock for a craft at this point of the
-- plan; what the stock lacks is made (with all it needs) or bought now
Take = function(ctx, L, id, qty, skillNow, stack, acc)
    local have = Stock(ctx, L, id)
    if ctx.measure then ctx.measure.deps[id] = true end
    local take = math.min(have, qty)
    if take > 0 then
        ctx.touched = ctx.touched + 1
        if have < qty - EPS then ctx.edges = ctx.edges + 1 end -- the stock runs out within this need
    end
    W(L, "have", id, have - take)
    W(L, "used", id, (L.used[id] or 0) + qty)
    local rest = qty - take
    if rest > EPS then Get(ctx, L, id, rest, skillNow, stack, acc) end
end

-- one planned craft step: its ingredients out, then its output in. What the
-- ingredients cost to get goes into acc.
local function Apply(ctx, L, recipe, crafts, skillNow, acc)
    for _, reagent in ipairs(Reagents(ctx, recipe)) do
        Take(ctx, L, reagent.id, reagent.n * crafts, skillNow, ctx.stack, acc)
    end
    local product = recipe.product
    if product and product > 0 then
        local out = Produced(L, crafts, recipe.made or 1)
        W(L, "have", product, Stock(ctx, L, product) + out)
        W(L, "madePlan", product, (L.madePlan[product] or 0) + out)
        if Varies(recipe) then W(L, "varies", product, true) end
    end
    W(L, "learned", RecipeId(recipe), true)
end

---------------------------------------------------------------------------
-- The recipe choice (concept 4.2)
--   What is compared, skill point by skill point: the gold you would have
--   to spend ON TOP of what you have for the crafts that point is expected
--   to take.
--   * asked on books of its own (the choice's: expected amounts, parts of a
--     batch), with the same rules as the plan's books: what you have costs
--     nothing but is used up as the choice uses it - the same stock does not
--     make every later recipe free - and a material is bought or made,
--     whichever costs less at that point (raw stock further down included)
--   * learning a recipe (trainer fee, recipe item) is a one-time cost,
--     spread over the points the recipe can still give (the next LOOKAHEAD
--     at most) - its own, and that of a recipe it would learn for an
--     intermediate; once the plan has learned it, it costs nothing more
--   * a recipe with a part nobody has a price for (a material, its fee, its
--     recipe item) is not fully comparable: taken only where no comparable
--     recipe gives a point, then the one with the smallest gap
--   * a recipe of unknown chance is never compared with a number
--   A heuristic: a sensible plan, not proven to be the least costly one.
--
--   Kept fast without changing what is chosen:
--   * what an item costs by the piece, where that does not depend on the
--     books (Measure), is worked out once and kept until something it
--     rests on changes - the stock of an item it looked at, a recipe that
--     is learned, a recipe that can be used from a higher skill on
--   * a recipe is judged in full only while it can still be the best or
--     the next best one: every recipe first gets a lower bound (what the
--     by-the-piece items alone cost; all the rest counted as free), and
--     the judging goes from the least bound up and stops where no bound
--     is below the next best recipe found.
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

-- What one piece of an item costs to get on the choice's books as they are,
-- and whether that is a cost by the piece ("linear": no stock, no one-time
-- cost, no chain back to itself in it or below it). Worked out with the
-- books untouched (never inside a trial), what it is made from first. Kept
-- with what it rests on:
--   deps   the items whose stock was looked at, the recipes ("#key") whose
--          learning cost counted - when one of them changes, it is dropped
--   till   the skill from which a recipe below it can be used that cannot
--          be used yet - from there on it is worked out again
local function Measure(ctx, L, id, skill, seen)
    local e = ctx.unit[id]
    if e and skill < e.till then return end
    if seen[id] then return end -- (a chain back to itself: worked out in full where it is met)
    seen[id] = true
    for _, r in ipairs(ctx.producers[id] or {}) do
        if CanMake(ctx, r, skill) then
            for _, reagent in ipairs(r.reagents) do Measure(ctx, L, reagent.id, skill, seen) end
        end
    end
    seen[id] = nil
    local m = { deps = {}, till = math.huge }
    local touched = ctx.touched
    local unit = NewAcc()
    ctx.measure = m
    local mark = Mark(L)
    GetExact(ctx, L, id, 1, skill, ctx.stack, unit)
    Rollback(L, mark)
    ctx.measure = nil
    ctx.unit[id] = { linear = ctx.touched == touched and not unit.cyclic, acc = unit, deps = m.deps, till = m.till }
    for dep in pairs(m.deps) do
        local list = ctx.dependents[dep]
        if not list then
            list = {}
            ctx.dependents[dep] = list
        end
        list[#list + 1] = id
    end
end

-- something changed on the choice's books: what rested on it is dropped
local function Changed(ctx, dep)
    local list = ctx.dependents[dep]
    if not list then return end
    ctx.dependents[dep] = nil
    for _, id in ipairs(list) do ctx.unit[id] = nil end
end

-- the share of a one-time cost a point of this recipe carries: one over the
-- points it can still give from here, within the next LOOKAHEAD
local function Share(ctx, c, skill)
    local count = 0
    for s = skill, math.min(ctx.input.target, skill + LOOKAHEAD) - 1 do
        if Chance(s, c.req, c.yellow, c.grey) <= 0 then break end
        count = count + 1
    end
    return 1 / math.max(1, count)
end

-- a recipe for the point at `skill`: { score (copper for this point on top
-- of what you have, plus its share of the one-time costs), gap (pieces
-- without a price), comparable, estimated } - nil when it gives no point
-- here. Tried out on the choice's books and taken back.
local function Evaluate(ctx, c, skill)
    local p = Chance(skill, c.req, c.yellow, c.grey)
    if p <= 0 then return nil end
    local CL = ctx.choice
    local share = Share(ctx, c, skill)
    local fee, feeUnknown = OneTime(ctx, c, CL.learned)
    CL.share = share
    local acc = NewAcc()
    local mark = Mark(CL)
    for _, reagent in ipairs(Reagents(ctx, c)) do
        Take(ctx, CL, reagent.id, reagent.n / p, skill, ctx.stack, acc)
    end
    Rollback(CL, mark)
    local gap = acc.gap + (feeUnknown and 1 or 0)
    return { score = acc.copper + (acc.once + fee) * share + 1, gap = gap, comparable = gap == 0, estimated = acc.estimated or false,
        fee = fee, feeUnknown = feeUnknown, share = share, learnGap = feeUnknown or acc.feeGap or false, priceGap = acc.priceGap or false }
end

-- What Evaluate can at least come to: gap and score from the items that
-- cost by the piece alone (they cost exactly that), its own learning cost,
-- and everything else counted as free.
local function Bound(ctx, c, skill, p)
    local CL = ctx.choice
    local copper, gap = 0, 0
    for _, reagent in ipairs(c.reagents) do
        local lack = reagent.n / p - Stock(ctx, CL, reagent.id)
        if lack > EPS then
            local e = ctx.unit[reagent.id]
            if e and e.linear and skill < e.till then
                copper, gap = copper + e.acc.copper * lack, gap + e.acc.gap * lack
            end
        end
    end
    local fee, feeUnknown = OneTime(ctx, c, CL.learned)
    return gap + (feeUnknown and 1 or 0), copper + fee * Share(ctx, c, skill) + 1
end

-- Per skill point the recipe to use: points[skill] = candidate, info[skill]
-- = how it was judged (for "why this recipe"), where the plan got stuck
-- (if), and whether a choice was not fully comparable.
local function ChoosePoints(ctx, cands, unknownChance)
    local input = ctx.input
    local CL = ctx.choice
    local points, info, current, stuck, notComparable, unknownAt = {}, {}, nil, nil, false, nil
    local seen = {}
    for skill = input.skill, input.target - 1 do
        -- the recipes that give a point here, each with its lower bound
        local live = {}
        for order, c in ipairs(cands) do
            local p = Chance(skill, c.req, c.yellow, c.grey)
            if p > 0 then
                for _, reagent in ipairs(c.reagents) do Measure(ctx, CL, reagent.id, skill, seen) end
                local gap, score = Bound(ctx, c, skill, p)
                if c ~= current then gap, score = gap * SWITCH_PENALTY, score * SWITCH_PENALTY end
                live[#live + 1] = { c = c, p = p, order = order, gap = gap, score = score }
            end
        end
        local byBound = {}
        for i, x in ipairs(live) do byBound[i] = x end
        table.sort(byBound, function(a, b)
            if a.gap ~= b.gap then return a.gap < b.gap end
            if a.score ~= b.score then return a.score < b.score end
            return a.order < b.order
        end)
        local function Judge(x)
            local e = x.judged
            if not e then
                e = Evaluate(ctx, x.c, skill)
                if x.c ~= current then e.score, e.gap = e.score * SWITCH_PENALTY, e.gap * SWITCH_PENALTY end
                x.judged = e
            end
            return e
        end
        local best, bestE, runner, runnerE
        for _, minChance in ipairs({ MIN_CHANCE, 0 }) do
            for _, comparable in ipairs({ true, false }) do
                -- judged from the least bound up, until no bound is below the
                -- second best found (so the best and the next best are among
                -- the judged ones)
                local firstGap, firstScore, secondGap, secondScore
                for _, x in ipairs(byBound) do
                    if x.p > minChance and not (comparable and x.gap > 0) then
                        if secondGap and (x.gap > secondGap or (x.gap == secondGap and x.score - 1e-6 > secondScore)) then break end
                        local e = Judge(x)
                        if e.comparable == comparable then
                            if not firstGap or e.gap < firstGap or (e.gap == firstGap and e.score < firstScore) then
                                firstGap, firstScore, secondGap, secondScore = e.gap, e.score, firstGap, firstScore
                            elseif not secondGap or e.gap < secondGap or (e.gap == secondGap and e.score < secondScore) then
                                secondGap, secondScore = e.gap, e.score
                            end
                        end
                    end
                end
                -- among them, in the recipes' own order (a tie goes to the
                -- same recipe whatever was judged first)
                for _, x in ipairs(live) do
                    local e = x.judged
                    if e and x.p > minChance and e.comparable == comparable then
                        local c = x.c
                        if not best or e.gap < bestE.gap or (e.gap == bestE.gap and e.score < bestE.score) then
                            runner, runnerE = best, bestE
                            best, bestE = c, e
                        elseif not runner or e.gap < runnerE.gap or (e.gap == runnerE.gap and e.score < runnerE.score) then
                            runner, runnerE = c, e
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
            learnGap = bestE.learnGap, priceGap = bestE.priceGap,
            other = runner and { name = runner.name, key = runner.key, score = runnerE.score, comparable = runnerE.comparable } or nil }
        -- this point is planned: on the choice's books its materials are used
        -- up, its output is there, its recipe (and what it learned for an
        -- intermediate) is learned. What rested on any of that is dropped.
        CL.share = bestE.share
        local mark = Mark(CL)
        Apply(ctx, CL, best, 1 / Chance(skill, best.req, best.yellow, best.grey), skill, NewAcc())
        local j = CL.journal
        for i = mark + 1, CL.jn, 3 do
            if j[i] == "have" then Changed(ctx, j[i + 1]) elseif j[i] == "learned" then Changed(ctx, "#" .. j[i + 1]) end
        end
        Keep(CL)
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

-- what getting a step's ingredients said about the choice (acc), on the step
local function Flag(step, acc)
    if acc.open or acc.gap > 0 then step.comparable = false end
    if acc.estimated then step.estimated = true end
    if acc.openLearn or acc.feeGap then step.learnOpen = true end
    if acc.openPrice or acc.priceGap then step.priceOpen = true end
end

-- The skills at which a recipe further down the ingredients of c becomes
-- usable (a recipe of the planned profession, at its required skill): from
-- there on a thing that was bought may be made.
local function Unlocks(ctx, c)
    local set = ctx.unlocks[c.key]
    if set then return set end
    set = {}
    local seen = {}
    local function Down(reagents)
        for _, reagent in ipairs(reagents) do
            if not seen[reagent.id] then
                seen[reagent.id] = true
                for _, r in ipairs(ctx.producers[reagent.id] or {}) do
                    if r.prof == ctx.input.prof and r.learn ~= nil then set[r.req or 0] = true end
                    Down(r.reagents)
                end
            end
        end
    end
    Down(c.reagents)
    ctx.unlocks[c.key] = set
    return set
end

-- The steps, carried out on the ledger. A step never runs across the end of
-- a rank (training comes between). An extra craft of the planned profession
-- can give a skill point itself (concept 4.3): while such crafts are needed
-- and their recipe still gives points, they come as a step of their own
-- ("for materials") and count towards the skill with their chance like any
-- other craft - no point is promised, none is counted twice, and the step
-- after them starts later and needs less.
--
-- What can be made is asked with the skill reached at that craft (Codex
-- round 1, B2): the crafts of one recipe are carried out in pieces that end
-- where a recipe further down its ingredients becomes usable - before that
-- skill the thing is bought, from it on it may be made. The pieces are one
-- step of the plan all the same: one row, the crafts of the whole step
-- (rounded up once, each piece getting its part of them in order), one
-- range.
local function Walk(ctx, points, info, stuck, trainAt)
    local input = ctx.input
    local L = NewLedger(false)
    local steps = {}
    local endSkill = stuck or input.target
    local skill = input.skill
    local guard = 0
    while skill < endSkill do
        guard = guard + 1
        if guard > 5000 then break end
        local c = points[skill]
        local unlock = Unlocks(ctx, c)
        local segTo, expected, ps = skill, 0, {}
        while segTo < endSkill and points[segTo] == c and not (segTo > skill and (trainAt[segTo] or unlock[segTo])) do
            local p = Chance(segTo, c.req, c.yellow, c.grey)
            ps[#ps + 1] = p
            expected = expected + 1 / p
            segTo = segTo + 1
        end
        -- the piece before this one, when both are one step
        local last = steps[#steps]
        local joined = last and not last.forMaterials and last.recipe == c and last.to == skill and not trainAt[skill] and last or nil
        local crafts = math.ceil(expected - 0.001)
        if joined then crafts = math.ceil(joined.expected + expected - 0.001) - joined.crafts end
        -- what this piece would have to make extra: tried out, taken back
        local before = {}
        for _, r in ipairs(L.extraList) do before[r] = L.extra[r] end
        local mark = Mark(L)
        Apply(ctx, L, c, crafts, skill, NewAcc())
        local material
        for _, r in ipairs(L.extraList) do
            local more = L.extra[r] - (before[r] or 0)
            if more > 0 and r.prof == input.prof then
                local chance = ChanceOf(r, skill)
                local forPoint = chance and chance > 0 and math.ceil(1 / chance - 0.001) or nil
                if forPoint and forPoint <= more then
                    material = { recipe = ctx.candOf[r.key] or r, crafts = forPoint, expected = 1 / chance, raw = r, p = chance }
                    break
                end
            end
        end
        Rollback(L, mark)
        local acc = NewAcc()
        if material then
            Apply(ctx, L, material.raw, material.crafts, skill, acc)
            if last and last.forMaterials and last.recipe == material.recipe and not trainAt[skill] then
                last.to, last.expected, last.crafts = skill + 1, last.expected + material.expected, last.crafts + material.crafts
                last.ps[#last.ps + 1] = material.p
            else
                last = { recipe = material.recipe, from = skill, to = skill + 1, expected = material.expected,
                    crafts = material.crafts, forMaterials = true, ps = { material.p }, comparable = true,
                    outputAssumed = Varies(material.raw) or nil }
                steps[#steps + 1] = last
            end
            Flag(last, acc)
            skill = skill + 1
        else
            Apply(ctx, L, c, crafts, skill, acc)
            local step = joined
            if step then
                step.to, step.expected, step.crafts = segTo, step.expected + expected, step.crafts + crafts
                for _, p in ipairs(ps) do step.ps[#step.ps + 1] = p end
            else
                step = { recipe = c, from = skill, to = segTo, expected = expected, crafts = crafts, ps = ps, comparable = true, estimated = false,
                    why = info[skill], outputAssumed = ((c.product or 0) > 0 and Varies(c)) or nil }
                steps[#steps + 1] = step
            end
            for s = skill, segTo - 1 do
                local i = info[s]
                if i then
                    if not i.comparable then
                        step.comparable = false
                        if i.learnGap then step.learnOpen = true end
                        if i.priceGap then step.priceOpen = true end
                    end
                    if i.estimated then step.estimated = true end
                end
            end
            Flag(step, acc)
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
        -- what you really have (concept 4.6): the tick only when THAT covers
        -- the need. What the plan will make (planned) lowers what has to be
        -- bought - it is a forecast, no stock, and never ticks a row.
        local haveKnown = not L.unknown[id]
        local have = L.start[id] or 0
        if not haveKnown then Note(ctx, "stock_unknown", id, { item = id }) end
        list[#list + 1] = { id = id, need = L.used[id], have = have, haveKnown = haveKnown, stock = input.stock[id],
            covered = haveKnown and have >= L.used[id], missing = missing, cost = copper, costStatus = status,
            price = price, node = input.nodes and input.nodes[id], planned = L.madePlan[id] or 0, made = L.madeExtra[id] or 0,
            outputAssumed = L.varies[id] or nil,
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
--                leads back to itself, a count that could not be read) |
--                "invalid" (nothing to plan from: never shown as a plan)
--   valid, complete
--   steps        { recipe, from, to, expected, crafts, low, high (the model's
--                80 % range of crafts), chanceFrom, chanceTo, forMaterials,
--                comparable, estimated, learnOpen, priceOpen, outputAssumed
--                (its output varies: counted with the mean), why } and,
--                last, a step of unknown chance { recipe, from,
--                chanceUnknown = true } where the plan cannot go on with a
--                number
--   training     { at, assumed } - where the next rank has to be trained
--   materials    { id, need, have, haveKnown, covered (what you really have
--                covers the need - the tick), missing (to buy), planned (what
--                the plan's own steps will make: a forecast, no stock), made
--                (made extra for the plan), cost, costStatus, price, stock
--                (the snapshot's entry), node, madeFrom, outputAssumed (its
--                amount rests on the mean of a varying output) }
--   ledger       [item] = { start, bought, madePlan, madeExtra, used, rest }
--   extras       { recipe, times } - the extra crafts, in the order first needed
--   cost         { known, estimated, estimatedItems, unknownItems } of what
--                is missing; total = known + estimated (never a made-up price)
--   crafts       the expected number of crafts of all steps (a sum of means;
--                the steps' ranges are not added up - concept 4.1)
--   estimate     { crafts, output }: the amounts and the cost are a planning
--                estimate because a step's number of crafts is a mean /
--                because a varying output was counted with its mean. Both
--                false: under the model the amounts are exact.
--   notComparable  a choice was made although a part of a cost is unknown -
--                of the recipe taken, or of a way that could have cost less;
--                openPrices / openLearn say what kind (a price, a learning cost)
--   stuck, learn, diagnostics
function Core.Compute(input)
    local why = Invalid(input)
    if why then
        return { status = "invalid", valid = false, complete = false, reason = why, steps = {}, training = {}, materials = {}, ledger = {}, extras = {},
            total = 0, crafts = 0, cost = { known = 0, estimated = 0, estimatedItems = {}, unknownItems = {} },
            estimate = { crafts = false, output = false },
            learn = { fees = 0, feesUnknown = 0, trainer = 0, items = 0, itemCost = 0, itemsUnknown = 0, matsUnknown = 0, list = {} },
            diagnostics = { { code = "invalid", reason = why } } }
    end
    local ctx = { input = input, noted = {}, diagnostics = {}, producers = {}, sorted = {}, stack = {}, choice = NewLedger(true), unit = {}, dependents = {}, unlocks = {}, touched = 0, edges = 0 }
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
    local crafts, openLearn, openPrices = 0, false, false
    local estimate = { crafts = false, output = false }
    for _, m in ipairs(materials) do
        if m.outputAssumed then estimate.output = true end
    end
    for _, s in ipairs(steps) do
        crafts = crafts + s.expected
        if s.chanceFrom < 1 or s.chanceTo < 1 then estimate.crafts = true end
        if s.outputAssumed then estimate.output = true end
        if s.comparable == false then notComparable = true end
        openLearn, openPrices = openLearn or s.learnOpen == true, openPrices or s.priceOpen == true
    end
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
        openLearn = openLearn, openPrices = openPrices, estimate = estimate,
        learn = learn, diagnostics = ctx.diagnostics }
end

-- What a second reader of the plan needs (later: the shopping list), in one
-- small table: per item need / have (and whether that is known) / missing,
-- and what the plan is - also that its amounts are a planning estimate
-- (estimate) and which items rest on the mean of a varying output
-- (outputAssumed). Made from a finished plan; nothing is calculated here.
function Core.Result(plan)
    local items = {}
    for _, m in ipairs(plan.materials or {}) do
        items[m.id] = { need = m.need, have = m.haveKnown and m.have or nil, haveKnown = m.haveKnown, missing = m.missing,
            covered = m.covered, planned = m.planned, make = m.madeFrom ~= nil, costStatus = m.costStatus,
            outputAssumed = m.outputAssumed == true }
    end
    local e = plan.estimate or {}
    return { prof = plan.prof, from = plan.from, target = plan.target, status = plan.status, valid = plan.valid == true,
        complete = plan.complete == true, items = items, estimate = { crafts = e.crafts == true, output = e.output == true } }
end
