local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Skill plan, the calculation (v0.2 building block 1, concept "Skill plan
-- 2.0" section 3.1): pure functions. Everything comes in through `input`,
-- the plan goes out as a table - no window, no event, no saved variable, no
-- game function is touched here, so the whole of it runs in a test without
-- the game. Planner.lua takes the snapshot, calls Compute and shows the plan.
--
-- A big plan takes a while. Compute(input, pause) calls `pause` at many
-- places where it can be put down and taken up again later (Rest, below):
-- Planner.lua runs it as a coroutine and yields in there once a frame's
-- share of time is used up, so no single call holds the game up (Codex
-- round 2, R2-M4). Without `pause` it runs through in one go. Either way it
-- is the same calculation and the same plan: nothing here looks at a clock.
-- (No pause is ever asked for inside a sort or behind a protected call - a
-- coroutine could not yield there.)
--
-- input = {
--   prof     the profession to plan ("Leatherworking")
--   skill    your skill now (a number)
--   skillSource  "lastSeen" when that is not the skill read now but the one
--            that was seen last (skillSeenAt: when, if known). The plan is
--            then a PREVIEW: worked out all the same, but never "done", not
--            complete, not reliable - nobody may take it for your state now
--            (Codex round 2, R2-M3).
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
--   professions  [profession] = { rank = skill } for every one you have;
--            source = "lastSeen" (and seenAt) when that skill is not read
--            now but was only seen last. A profession you do not have is
--            not in here, whatever recipes of it are remembered. What the
--            plan makes with a "lastSeen" profession is not certain: such a
--            plan is a PREVIEW (Codex round 3, R3-M1).
--   stock    [item] = how many you have: a number, or { n = number,
--            bags, reagent, bank, ... } with the parts for the window, or
--            { unknown = true } when it could not be read. "Could not be
--            read" is not 0 (concept 4.4): the books then go on with 0 so
--            the plan stays carried out, but the row says the count is not
--            known, gets no tick, and the plan is not called complete.
--            What is missing of such an item (and so its cost) is counted
--            AS IF you had none - an assumption, marked on the row
--            (missingAssumed), in the sum (cost.assumedItems) and for a
--            second reader (Core.Result) - Codex round 1, B6.
--            An item the snapshot does not list counts as none.
--   prices   [item] = { status = "known" | "estimated" | "unknown",
--                       copper (nil when unknown), source, age (seconds) }
--            A price is never made up here: unknown stays unknown, in the
--            recipe choice, in every sum and in the plan (concept 4.5).
--   recipeItemPrices  [recipe item] = copper (a vendor showed it)
--   nodes    [item] = the node that gives it (for a farm run)
-- }
-- What a recipe needs beyond its record - a tool, a forge or an anvil, a
-- cooldown, reputation, a character level - is not in the input and not in
-- the plan: nothing here says such a thing is met or missing (concept 4.7,
-- set apart for building block 1; the window says that it is not checked).
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
--   its mean), skill (extra crafts "for materials" could give skill points
--   that are not counted - Codex round 2, R2-N1) }, step.outputAssumed,
--   material.outputAssumed.
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

-- What an item out of your stock is worth in the recipe choice (0.2.3; Sven,
-- 22.11.2026, proposal A of the blacksmith diagnosis): input.values[item] =
-- { status, copper } - its auction price by the 0.1.16 rule, else what a
-- vendor pays for it (a lower bound: estimated), else unknown. An input
-- without values (the tests' own tables) gives an item the worth of buying it.
local function ValueOf(input, id)
    local values = input.values
    if not values then return PriceOf(input, id) end
    local v = values[id]
    if type(v) ~= "table" or type(v.copper) ~= "number" or v.status == "unknown" then return UNKNOWN end
    if v.status ~= "estimated" and v.status ~= "known" then return { status = "known", copper = v.copper } end
    return v
end

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

-- a place to rest: the calculation may be put down here and go on later
local function Rest(ctx)
    local pause = ctx.pause
    if pause then pause() end
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
local idOf = setmetatable({}, { __mode = "k" })
local function RecipeId(r)
    local id = idOf[r]
    if not id then
        id = tostring(r.prof) .. "/" .. tostring(r.key)
        idOf[r] = id
    end
    return id
end

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
--     (and is used by whatever needs it later)
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

-- SHORTCUTS: the two places where the calculation does not work a thing out
-- again that it has worked out before (Remember / Recall and Repeats, below).
-- Each of them is used only where what it leaves out would come to exactly
-- the same entries in the books and the same cost - never to save time at
-- the price of another result (Codex round 2, R2-M2). With false, everything
-- is worked out in full, need by need and batch by batch: that is the
-- reference the tests compare whole plans with (tools/smoke_test.lua loads
-- this file a second time with the switch off). Nothing else reads it.
local SHORTCUTS = true

-- Both sets of books - the plan's own and the recipe choice's - count whole
-- crafts and whole batches: a part of a batch cannot be made (Codex round 2,
-- R2-M1). choice: the books of the recipe choice (they spread a one-time
-- cost over the points a recipe gives, and report nothing).
local function NewLedger(choice)
    return { have = {}, start = {}, used = {}, bought = {}, madePlan = {}, madeExtra = {}, madeBy = {}, extra = {}, extraList = {},
        unknown = {}, learned = {}, varies = {}, journal = {}, jn = 0, marks = 0, choice = choice or false, share = 1, memo = {} }
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

-- What was written since the mark, as changes: for the amounts (what is in
-- stock, used, bought, made) how much they went up or down, for the rest
-- (learned, made by which recipe) the value. Written again with Redo - on
-- the books as they were at the mark that gives the same entries; and where
-- only amounts differ that the writing did not depend on, the same changes.
local AMOUNT = { have = true, used = true, bought = true, madeExtra = true, madePlan = true, extra = true }
local FOLLOWS = { start = true, unknown = true, extraList = true } -- (written along with "have" and "extra")
local function Changes(ctx, L, mark)
    local j, out, n = L.journal, {}, 0
    local seen = ctx.seen
    for i = mark + 1, L.jn, 3 do
        local name, key = j[i], j[i + 1]
        if not FOLLOWS[name] then
            local s = seen[name]
            if not s then
                s = {}
                seen[name] = s
            end
            if not s[key] then
                s[key] = true
                local value = rawget(L, name)[key]
                if AMOUNT[name] then
                    local before = j[i + 2]
                    if before == nil then before = name == "have" and L.start[key] or 0 end
                    value = value - before
                end
                out[n + 1], out[n + 2], out[n + 3] = name, key, value
                n = n + 3
            end
        end
    end
    for i = 1, n, 3 do seen[out[i]][out[i + 1]] = nil end
    out.n = n
    return out
end
-- `times`: the same changes that many times over (amounts only differ)
local function Redo(ctx, L, changes, times)
    for i = 1, changes.n, 3 do
        local name, key, value = changes[i], changes[i + 1], changes[i + 2]
        if name == "have" then
            local have = Stock(ctx, L, key)
            if value ~= 0 then W(L, "have", key, have + value * times) end
        elseif name == "extra" then
            local n = L.extra[key]
            if n == nil then
                W(L, "extraList", #L.extraList + 1, key)
                n = 0
            end
            W(L, "extra", key, n + value * times)
        elseif AMOUNT[name] then
            W(L, name, key, (rawget(L, name)[key] or 0) + value * times)
        else
            W(L, name, key, value)
        end
    end
end

---------------------------------------------------------------------------
-- Getting what the stock lacks: buy it or make it (concept 4.2 / 4.5; Codex
-- round 1, B1). Decided for THIS need - the amount that is lacking now -
-- by what each way uses up, tried out on the books:
--   * a piece bought costs its price; a piece out of the stock you had - also
--     the raw materials further down - costs what it is worth (ValueOf, 0.2.3:
--     never nothing; a worth nobody knows is like a price nobody knows). It is
--     used up as it is used: the same piece is not counted twice, and what the
--     plan made itself was paid for where it was made
--   * making it costs whole batches; what a batch makes too much is no saving
--   * a recipe the plan has not learned yet costs its fee or its recipe item,
--     once
--   * ways to choose from: buy all of it; make batch by batch as long as a
--     batch costs less than buying what it replaces, and buy the rest (so
--     raw stock for a part of the need is used for that part); or make all
--     of it in one go (what the batches need is then got together - a batch
--     further down may be worth it for all of them where it is not for one)
--   * a way with a whole cost (known or estimated) is compared by that cost,
--     buying keeps a tie, batch by batch keeps one against all in one go. A
--     way with a part nobody knows (a price, a fee) never wins by its known
--     part: it is taken only when no way has a whole cost - then making it
--     (from things you may be able to get) before buying at a price nobody
--     knows.
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
-- Each need is decided when it comes up; what a later step may still need
-- of the same thing is not counted in (a heuristic, like the recipe choice).
---------------------------------------------------------------------------
-- (0.2.3) stock  the worth of what it took out of your stock (ValueOf)
--        sgap   pieces of your stock whose worth nobody knows: like a price nobody knows
--        Neither is in the plan's sums of what you lack - only in the choice.
local function NewAcc() return { copper = 0, once = 0, gap = 0, stock = 0, sgap = 0 } end

local function Add(into, a)
    into.copper, into.once, into.gap = into.copper + a.copper, into.once + a.once, into.gap + a.gap
    into.stock, into.sgap = (into.stock or 0) + (a.stock or 0), (into.sgap or 0) + (a.sgap or 0)
    if a.stockEstimated then into.stockEstimated = true end
    if a.stockGap then into.stockGap = true end
    if a.estimated then into.estimated = true end
    if a.priceGap then into.priceGap = true end
    if a.feeGap then into.feeGap = true end
    if a.open then into.open = true end
    if a.openPrice then into.openPrice = true end
    if a.openLearn then into.openLearn = true end
end

-- what a way costs when it is compared: its one-time costs count whole in
-- the plan's books, with the recipe's share in the recipe choice (L.share)
local function Value(L, a) return a.copper + (a.stock or 0) + a.once * L.share end
-- what in a way has no known worth: pieces without a price, fees, stock (0.2.3)
local function Gap(a) return a.gap + (a.sgap or 0) end

-- what `batches` crafts make: whole pieces (a mean output like 1.5 is
-- rounded down over all the crafts)
local function Produced(L, batches, made)
    return math.floor(batches * made + 1e-9)
end

---------------------------------------------------------------------------
-- What a piece of the calculation looked at (only with SHORTCUTS). Getting
-- an item is worked out from the books: from how many of some items are in
-- stock, and from whether some recipes are learned. While a piece is worked
-- out, a watch notes what it looked at and HOW the outcome hangs on it:
--   * an item whose stock covered every need it met: the outcome is the same
--     with any stock that covers them as well - noted is the lowest the
--     stock went in anything that was tried (first - min: how much it takes)
--   * an item whose stock did NOT cover a need (also: none in stock): what
--     was lacking came from the exact count - the outcome is the same only
--     with exactly that many in stock (exact)
--   * a recipe that was to be learned or not: the same only when that is so
--     again (learned)
--   * the skill: the same from the highest skill a recipe that could be used
--     needs (low) up to where a recipe that could not yet be used can (till)
--   * the share of a one-time cost, where one was counted (share)
--   * a chain that came back to an item being made further up (cyc): the
--     outcome hangs on what is being made around it - never remembered
-- A watch inside another hands what it noted up to it when it is done.
-- Nothing else on the books is looked at to decide anything: what is used,
-- bought and made so far is only added to.
---------------------------------------------------------------------------
-- (0.2.3) how much of the stock you had is left: it is used first (what the plan
-- makes goes on top of it), so it is what you had minus all that was used
local function OrigLeft(ctx, L, id)
    local start = L.start[id]
    if start == nil then start = StockNumber(ctx.input, id) end
    return math.max(0, start - (L.used[id] or 0))
end

local function Watch(ctx)
    local w = { n = 0, ids = {}, first = {}, min = {}, exact = {}, orig = {}, ln = 0, lids = {}, lwas = {}, low = 0, till = math.huge,
        share = false, cyc = nil, parent = ctx.watch }
    ctx.watch = w
    return w
end

-- the watch `w` is done: what it noted counts for the one around it too
local function HandUp(w)
    local p = w.parent
    if not p then return end
    local first, min, exact = p.first, p.min, p.exact
    for i = 1, w.n do
        local id = w.ids[i]
        if first[id] == nil then
            p.n = p.n + 1
            p.ids[p.n], first[id], min[id] = id, w.first[id], w.min[id]
            p.orig[id] = w.orig[id]
        elseif w.min[id] < min[id] then
            min[id] = w.min[id]
        end
        if w.exact[id] then exact[id] = true end
    end
    for i = 1, w.ln do
        local rid = w.lids[i]
        if p.lwas[rid] == nil then
            p.ln = p.ln + 1
            p.lids[p.ln], p.lwas[rid] = rid, w.lwas[rid]
        end
    end
    if w.low > p.low then p.low = w.low end
    if w.till < p.till then p.till = w.till end
    if w.share then p.share = true end
    if w.cyc then
        p.cyc = p.cyc or {}
        for id in pairs(w.cyc) do p.cyc[id] = true end
    end
end

-- how many of an item are in stock, without writing anything
local function Peek(ctx, L, id)
    local have = L.have[id]
    if have == nil then
        have = ctx.base[id]
        if have == nil then
            have = StockNumber(ctx.input, id)
            ctx.base[id] = have
        end
    end
    return have
end

-- Getting `rest` of an item was worked out with the watch `w`: remembered
-- with what it rests on, what it wrote (as changes) and what it cost.
local function Remember(ctx, L, id, rest, w, changes, acc)
    local e = { n = w.n, ids = w.ids, exact = {}, value = {}, orig = {}, ln = w.ln, lids = w.lids, lwas = {}, low = w.low, till = w.till,
        share = w.share and L.share or false, changes = changes, acc = acc }
    for i = 1, w.n do
        local item = w.ids[i]
        e.orig[i] = w.orig[item]
        if w.exact[item] then
            e.exact[i], e.value[i] = true, w.first[item]
        else
            e.value[i] = w.first[item] - w.min[item]
        end
    end
    for i = 1, w.ln do e.lwas[i] = w.lwas[w.lids[i]] end
    local byRest = L.memo[id]
    if not byRest then
        byRest = {}
        L.memo[id] = byRest
    end
    byRest[rest] = e
end

-- Is what was remembered for this need still what working it out would
-- give? Only when everything it rests on is as it was, in the sense above.
local function Recall(ctx, L, id, rest, skillNow, stack)
    local byRest = L.memo[id]
    local e = byRest and byRest[rest]
    if not e then return nil end
    if skillNow < e.low or skillNow >= e.till then return nil end
    if e.share and e.share ~= L.share then return nil end
    local deep = ctx.depth > 0
    local onBooks, base = L.have, ctx.base
    for i = 1, e.n do
        local item = e.ids[i]
        local have = onBooks[item]
        if have == nil then
            have = base[item]
            if have == nil then have = Peek(ctx, L, item) end
        end
        if e.exact[i] then
            if have ~= e.value[i] then return nil end
        elseif have < e.value[i] then
            return nil
        end
        -- an item it looked at is being made further up now: the chain could
        -- come back to it
        if deep and stack[item] then return nil end
        -- (0.2.3) the worth of what it took from your stock rests on how much of it is left
        if e.orig[i] ~= nil and OrigLeft(ctx, L, item) ~= e.orig[i] then return nil end
    end
    local learned = L.learned
    for i = 1, e.ln do
        if (learned[e.lids[i]] and true or false) ~= e.lwas[i] then return nil end
    end
    return e
end

-- what was remembered is used inside a piece that is being watched: what it
-- rests on, the piece rests on as well (in terms of the books as they are)
local function Inherit(ctx, L, w, e)
    local first, min, exact = w.first, w.min, w.exact
    for i = 1, e.n do
        local item = e.ids[i]
        local have = Peek(ctx, L, item)
        if first[item] == nil then
            w.n = w.n + 1
            w.ids[w.n], first[item], min[item] = item, have, have
            w.orig[item] = e.orig[i]
        end
        if e.exact[i] then
            exact[item] = true
        elseif have - e.value[i] < min[item] then
            min[item] = have - e.value[i]
        end
    end
    for i = 1, e.ln do
        local rid = e.lids[i]
        if w.lwas[rid] == nil then
            w.ln = w.ln + 1
            w.lids[w.ln], w.lwas[rid] = rid, e.lwas[i]
        end
    end
    if e.low > w.low then w.low = e.low end
    if e.till < w.till then w.till = e.till end
    if e.share then w.share = true end
end

-- One batch was tried out with the watch `w` and is taken (its entries are
-- on the books). How many MORE batches would go exactly the same way - the
-- same things tried, the same things taken, the same cost? As many as leave
-- everything the batch looked at as it was, in the sense above:
--   * what the batch did not change does not limit it
--   * an item it used up from a stock that covered every need: as long as
--     the stock still covers what a batch takes (min / used per batch)
--   * an item whose exact count mattered and that the batch changed, a
--     recipe the batch learned: the next batch is another one - none
-- At most `limit`. Also notes on the watch how low the stock goes then.
local function Repeats(ctx, L, w, limit)
    local more = limit
    for i = 1, w.ln do
        local rid = w.lids[i]
        if (L.learned[rid] and true or false) ~= w.lwas[rid] then return 0 end
    end
    for i = 1, w.n do
        local id = w.ids[i]
        local used = w.first[id] - Peek(ctx, L, id)
        if used ~= 0 then
            if used < 0 or w.exact[id] then return 0 end
            local fits = math.floor(w.min[id] / used + 1e-9)
            if fits < more then
                more = fits
                if more <= 0 then return 0 end
            end
        end
    end
    -- (0.2.3) what the batch took from the stock you had (it is used first): the
    -- same again only while it lasts - after it, a batch takes what the plan made
    for i = 1, w.n do
        local id = w.ids[i]
        if w.orig[id] ~= nil then
            local left = OrigLeft(ctx, L, id)
            local fromOrig = w.orig[id] - left
            if fromOrig > 0 then
                local fits = math.floor(left / fromOrig + 1e-9)
                if fits < more then
                    more = fits
                    if more <= 0 then return 0 end
                end
            end
        end
    end
    for i = 1, w.n do
        local id = w.ids[i]
        local used = w.first[id] - Peek(ctx, L, id)
        if used > 0 then w.min[id] = w.min[id] - used * more end
    end
    return more
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
    ctx.depth = ctx.depth + 1
    for _, reagent in ipairs(Reagents(ctx, r)) do
        Take(ctx, L, reagent.id, reagent.n * batches, skillNow, stack, acc)
    end
    ctx.depth = ctx.depth - 1
    stack[id] = nil
end

-- the crafts are done: learned (once), their output into the books; `covered`
-- of it goes straight to the need they were made for
local function Made(ctx, L, id, r, batches, covered, acc)
    local recipeId = RecipeId(r)
    local w = ctx.watch
    if w and w.lwas[recipeId] == nil then
        w.ln = w.ln + 1
        w.lids[w.ln], w.lwas[recipeId] = recipeId, L.learned[recipeId] and true or false
    end
    if not L.learned[recipeId] then
        local fee, unknown = OneTime(ctx, r, L.learned)
        acc.once = acc.once + fee
        if fee > 0 and w then w.share = true end
        if unknown then
            acc.gap = acc.gap + 1
            acc.feeGap = true
        end
        W(L, "learned", recipeId, true)
    end
    local produced = Produced(L, batches, math.max(1, r.made or 1))
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

-- all of it in one go
local function MakeAll(ctx, L, id, r, rest, skillNow, stack, acc)
    local batches = math.ceil(rest / math.max(1, r.made or 1) - 1e-9)
    Batches(ctx, L, id, r, batches, skillNow, stack, acc)
    Made(ctx, L, id, r, batches, rest, acc)
end

-- batch by batch, as long as the next batch costs less than buying what it
-- replaces; what is left is bought. Returns the batches made. (The one-time
-- cost of learning r is not part of a batch: it counts when this way is
-- compared with the others.)
local function MakeSome(ctx, L, id, r, rest, skillNow, stack, acc)
    local price = PriceOf(ctx.input, id)
    local made = math.max(1, r.made or 1)
    local remaining, batches = rest, 0
    -- (a mean output like 1.5 gives another number of pieces from batch to
    -- batch: never counted on, below)
    local even = SHORTCUTS and made == math.floor(made)
    while remaining > EPS do
        Rest(ctx)
        local covers = math.min(remaining, Produced(L, batches + 1, made) - Produced(L, batches, made))
        local a = NewAcc()
        local w = even and Watch(ctx) or nil
        local mark = Mark(L)
        Batches(ctx, L, id, r, 1, skillNow, stack, a)
        if w then ctx.watch = w.parent end
        if a.cyclic or Gap(a) > 0 or Value(L, a) >= price.copper * covers then
            Rollback(L, mark)
            if w then HandUp(w) end
            break
        end
        -- The batch is taken. The batches after it that go exactly the same
        -- way are not tried out one by one: their entries are this batch's,
        -- that many times over (SHORTCUTS - see Repeats). Only whole batches
        -- that are needed in full: the last one may replace fewer pieces.
        local more = 0
        if w and covers == made then
            local limit = math.floor((remaining - covers) / made + 1e-9)
            if limit > 0 then more = Repeats(ctx, L, w, limit) end
        end
        if more > 0 then
            local changes = Changes(ctx, L, mark)
            Keep(L)
            Redo(ctx, L, changes, more)
        else
            Keep(L)
        end
        if w then HandUp(w) end
        Add(acc, a)
        if more > 0 then
            if a.copper % 1 == 0 and a.once % 1 == 0 and a.gap % 1 == 0 and a.stock % 1 == 0 and a.sgap % 1 == 0 then
                -- (whole numbers: the same sum whether added batch by batch or at once)
                acc.copper, acc.once, acc.gap = acc.copper + a.copper * more, acc.once + a.once * more, acc.gap + a.gap * more
                acc.stock, acc.sgap = (acc.stock or 0) + a.stock * more, (acc.sgap or 0) + a.sgap * more
            else
                for _ = 1, more do Add(acc, a) end
            end
        end
        batches, remaining = batches + 1 + more, remaining - covers * (1 + more)
    end
    if batches > 0 then Made(ctx, L, id, r, batches, rest - remaining, acc) end
    if remaining > EPS then Buy(ctx, L, id, remaining, acc) end
    return batches
end

-- is way `w` to be taken instead of `than`? (the earlier one keeps a tie)
local function Better(L, w, than)
    local a, b = w.acc, than.acc
    local wholeA, wholeB = Gap(a) == 0, Gap(b) == 0
    if wholeA ~= wholeB then return wholeA end
    if wholeA then return Value(L, a) < Value(L, b) end
    -- no way has a whole cost: making before buying at a price nobody knows
    if (w.kind == "buy") ~= (than.kind == "buy") then return than.kind == "buy" end
    if Gap(a) ~= Gap(b) then return Gap(a) < Gap(b) end
    return Value(L, a) < Value(L, b)
end

-- `rest` of an item the stock does not have, for a craft at this point of
-- the plan: every way is tried out on the books and taken back, the least
-- costly one is then carried out. Returns what it wrote, as changes.
local function Decide(ctx, L, id, rest, skillNow, stack, acc)
    Rest(ctx)
    local price = PriceOf(ctx.input, id)
    local buy = NewAcc()
    if price.copper then
        buy.copper, buy.estimated = price.copper * rest, price.status == "estimated"
    else
        buy.gap, buy.priceGap = rest, true
    end
    -- The ways in the order they are tried; `best` is the one to take so
    -- far (the earlier one keeps a tie). What a way wrote is kept only when
    -- it is the best so far: no other one can be carried out in the end.
    local best = { kind = "buy", acc = buy }
    local ways = { best }
    local w = ctx.watch
    for _, r in ipairs(ctx.producers[id] or {}) do
        if w and r.prof == ctx.input.prof and r.learn ~= nil then
            -- (a recipe of the planned profession: usable from its skill on)
            local req = r.req or 0
            if req > skillNow then
                if req < w.till then w.till = req end
            elseif req > w.low then
                w.low = req
            end
        end
        if CanMake(ctx, r, skillNow) then
            if price.copper then
                local a = NewAcc()
                local mark = Mark(L)
                local batches = MakeSome(ctx, L, id, r, rest, skillNow, stack, a)
                if batches > 0 then
                    local way = { kind = "some", recipe = r, acc = a }
                    ways[#ways + 1] = way
                    if Better(L, way, best) then
                        way.changes = Changes(ctx, L, mark)
                        best = way
                    end
                end
                Rollback(L, mark)
            end
            local a = NewAcc()
            local mark = Mark(L)
            MakeAll(ctx, L, id, r, rest, skillNow, stack, a)
            -- (a chain that came back to itself: this way is dropped)
            if not a.cyclic then
                local way = { kind = "all", recipe = r, acc = a }
                ways[#ways + 1] = way
                if Better(L, way, best) then
                    way.changes = Changes(ctx, L, mark)
                    best = way
                end
            end
            Rollback(L, mark)
        end
    end
    if Gap(best.acc) == 0 then
        for _, way in ipairs(ways) do
            if way.kind ~= "buy" and Gap(way.acc) > 0 and Value(L, way.acc) < Value(L, best.acc) then
                -- a way to make it, with a part nobody knows, could have cost less
                acc.open = true
                if way.acc.feeGap then acc.openLearn = true end
                if way.acc.priceGap or way.acc.stockGap then acc.openPrice = true end
            end
        end
    end
    if best.kind == "buy" then
        Buy(ctx, L, id, rest, acc)
        return { "bought", id, rest, n = 3 }
    end
    -- as it was tried: written again, not decided again
    Redo(ctx, L, best.changes, 1)
    Add(acc, best.acc)
    return best.changes
end

-- `rest` of an item the stock does not have. The chain came back to an item
-- that is being made further up: it is not made from itself - the way that
-- led here is dropped by the one that tried it. Reported when the plan's own
-- books meet it, not when the recipe choice only looked at such a recipe.
-- Else: decided (Decide) - or, with SHORTCUTS, what was decided before for
-- the same need written again, when all it rested on is as it was.
local function Get(ctx, L, id, rest, skillNow, stack, acc)
    if stack[id] then
        if not L.choice then Note(ctx, "cycle", id, { item = id }) end
        acc.cyclic = true
        local w = ctx.watch
        if w then
            w.cyc = w.cyc or {}
            w.cyc[id] = true
        end
        Buy(ctx, L, id, rest, acc)
        return
    end
    if not SHORTCUTS then
        Decide(ctx, L, id, rest, skillNow, stack, acc)
        return
    end
    local e = Recall(ctx, L, id, rest, skillNow, stack)
    if e then
        if ctx.watch then Inherit(ctx, L, ctx.watch, e) end
        Redo(ctx, L, e.changes, 1)
        Add(acc, e.acc)
        return
    end
    local w = Watch(ctx)
    local a = NewAcc()
    local changes = Decide(ctx, L, id, rest, skillNow, stack, a)
    ctx.watch = w.parent
    if w.cyc then
        -- (a chain back to THIS item was closed in here: nothing outside)
        w.cyc[id] = nil
        if next(w.cyc) == nil then w.cyc = nil end
    end
    if not w.cyc then Remember(ctx, L, id, rest, w, changes, a) end
    HandUp(w)
    Add(acc, a)
end

-- takes qty of an item out of the stock for a craft at this point of the
-- plan; what the stock lacks is made (with all it needs) or bought now
Take = function(ctx, L, id, qty, skillNow, stack, acc)
    local have = Stock(ctx, L, id)
    local w = ctx.watch
    if w then
        if w.first[id] == nil then
            w.n = w.n + 1
            w.ids[w.n], w.first[id], w.min[id] = id, have, have
            w.orig[id] = OrigLeft(ctx, L, id)
        end
        if have < qty then
            w.exact[id] = true -- what is lacking comes from the exact count
        elseif have - qty < w.min[id] then
            w.min[id] = have - qty
        end
    end
    local take = math.min(have, qty)
    -- (0.2.3) what comes out of the stock you had is used up: it costs what it is
    -- worth (ValueOf), never nothing; worth nobody knows is like a price nobody
    -- knows. What the plan made itself is on top of it and was paid for there.
    local own = math.min(take, OrigLeft(ctx, L, id))
    if own > EPS then
        local v = ValueOf(ctx.input, id)
        if v.copper then
            acc.stock = (acc.stock or 0) + v.copper * own
            if v.status == "estimated" then acc.stockEstimated = true end
        else
            acc.sgap = (acc.sgap or 0) + own
            acc.stockGap = true
        end
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
-- The recipe choice (concept 4.2; 0.2.3, Sven 22.11.2026)
--   What is compared, skill point by skill point: what the crafts that point
--   is expected to take use up - the pieces bought at their price, the pieces
--   out of your stock at their market worth (ValueOf) - and its share of the
--   one-time costs. (What is shown as missing stays the gold you lack.)
--   * asked on books of its own (the choice's), with the same rules as the
--     plan's books: what you have is used up as the choice uses it - the
--     same stock is not counted for every later recipe - and a material is
--     bought or made, whichever uses up less at that point (raw stock
--     further down included)
--   * a tie (the same before the switch's 8 %) goes to the recipe that uses
--     up stock worth less, then to fewer pieces a point (Prefer)
--   * what a point costs is what the material balance would count for its
--     crafts (Codex round 2, R2-M1): WHOLE crafts with whole batches of what
--     they need, or the piece bought - never a part of a batch. The number
--     of crafts a point is expected to take (1 / chance) is kept apart from
--     that: where it is no whole number, the cost of the whole number below
--     it and of the one above it are worked out, each as the balance would,
--     and weighed by how far the expected number lies between them (1.25
--     crafts: three quarters of the cost of one craft, a quarter of the cost
--     of two).
--   * the point that was chosen is carried out on the choice's books in
--     whole crafts, counted on like the plan's steps: the crafts of the
--     points of one recipe in a row, rounded up together.
--   * learning a recipe (trainer fee, recipe item) is a one-time cost,
--     spread over the points the recipe can still give (the next LOOKAHEAD
--     at most) - its own, and that of a recipe it would learn for an
--     intermediate; once the plan has learned it, it costs nothing more
--   * a recipe with a part nobody has a price for (a material, its fee, its
--     recipe item) is not fully comparable: taken only where no comparable
--     recipe gives a point, then the one with the smallest gap
--   * a recipe of unknown chance is never compared with a number
--   A heuristic: a sensible plan, not proven to be the least costly one.
--   Every recipe that gives a point is judged in full at every point (what
--   that asks for again and again is what Get remembers).
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

-- the share of a one-time cost a point of this recipe carries: one over the
-- points it can still give from here, within the next LOOKAHEAD
-- (it gives points up to its grey skill, so that many are left: counted,
-- not tried skill by skill)
local function Share(ctx, c, skill)
    local last = math.min(ctx.input.target, skill + LOOKAHEAD, math.ceil(c.grey))
    return 1 / math.max(1, last - skill)
end

-- the whole number of crafts below the expected number for a point at
-- chance p, and how far the expected number lies above it (0: it is whole)
local function WholeAndPart(p)
    local expected = 1 / p
    local whole = math.floor(expected + 1e-9)
    local part = expected - whole
    if part < 1e-9 then part = 0 end
    return whole, part
end

-- what `crafts` crafts of c would cost on the choice's books as they are:
-- tried out as the material balance would carry them out, and taken back.
-- With SHORTCUTS what it came to is remembered like a need is (Remember /
-- Recall, with the recipe in the place of the item): the same crafts cost
-- the same again as long as all they rested on is as it was.
local function Trial(ctx, c, crafts, skill)
    local CL = ctx.choice
    if SHORTCUTS then
        local e = Recall(ctx, CL, c, crafts, skill, ctx.stack)
        if e then return e.acc end
    end
    local w = SHORTCUTS and Watch(ctx) or nil
    local acc = NewAcc()
    local mark = Mark(CL)
    for _, reagent in ipairs(Reagents(ctx, c)) do
        Take(ctx, CL, reagent.id, reagent.n * crafts, skill, ctx.stack, acc)
    end
    Rollback(CL, mark)
    if w then
        ctx.watch = w.parent
        if not w.cyc then Remember(ctx, CL, c, crafts, w, nil, acc) end
    end
    return acc
end

-- a recipe for the point at `skill`, where its chance is p (above 0):
-- { score (copper for this point on top of what you have, plus its share of
-- the one-time costs), gap (pieces without a price), comparable, estimated }
local function Evaluate(ctx, c, skill, p)
    local CL = ctx.choice
    local share = Share(ctx, c, skill)
    local fee, feeUnknown = OneTime(ctx, c, CL.learned)
    CL.share = share
    local whole, part = WholeAndPart(p)
    local acc = Trial(ctx, c, whole, skill)
    if part > 0 then
        -- between two whole numbers of crafts: each counted as it would be
        -- carried out, weighed by where the expected number lies
        local more = Trial(ctx, c, whole + 1, skill)
        local mixed = NewAcc()
        Add(mixed, acc)
        Add(mixed, more)
        mixed.copper = acc.copper * (1 - part) + more.copper * part
        mixed.once = acc.once * (1 - part) + more.once * part
        mixed.gap = acc.gap * (1 - part) + more.gap * part
        mixed.stock = acc.stock * (1 - part) + more.stock * part
        mixed.sgap = acc.sgap * (1 - part) + more.sgap * part
        acc = mixed
    end
    local gap = acc.gap + acc.sgap + (feeUnknown and 1 or 0)
    -- (0.2.3) pieces a point: what one craft takes, as often as a point takes crafts
    local pieces = 0
    for _, reagent in ipairs(Reagents(ctx, c)) do pieces = pieces + reagent.n end
    return { score = acc.copper + acc.stock + (acc.once + fee) * share + 1, gap = gap, comparable = gap == 0,
        estimated = acc.estimated or acc.stockEstimated or false,
        fee = fee, feeUnknown = feeUnknown, share = share, learnGap = feeUnknown or acc.feeGap or false,
        priceGap = acc.priceGap or acc.stockGap or false, stock = acc.stock, pieces = pieces / p }
end

-- Per skill point the recipe to use: points[skill] = candidate, info[skill]
-- = how it was judged (for "why this recipe"), where the plan got stuck
-- (if), and whether a choice was not fully comparable.
-- is e to be taken before f? The less worth used up a point first, with the
-- switch's 8 % on every recipe but the one in use. (0.2.3, Sven 22.11.) Where
-- two cost the same before the 8 % (a tie), the 8 % does not hold the one in
-- use: the stock worth less goes first, then fewer pieces a point; only then
-- the one in use keeps it, else the recipes' own order (by name, the earlier).
local TIE = 1e-6
local function Same(a, b) return math.abs(a - b) <= TIE * math.max(1, math.abs(a), math.abs(b)) end
local function Prefer(e, f)
    if not (Same(e.rawGap, f.rawGap) and Same(e.rawScore, f.rawScore)) then
        if e.gap ~= f.gap then return e.gap < f.gap end
        if e.score ~= f.score then return e.score < f.score end
    end
    if not Same(e.stock, f.stock) then return e.stock < f.stock end
    if not Same(e.pieces, f.pieces) then return e.pieces < f.pieces end
    if e.inUse ~= f.inUse then return e.inUse end
    return false
end

local function ChoosePoints(ctx, cands, unknownChance, trainAt)
    local input = ctx.input
    local CL = ctx.choice
    local points, info, current, stuck, notComparable, unknownAt = {}, {}, nil, nil, false, nil
    local runExpected, runCrafts = 0, 0 -- the points of one recipe in a row: their crafts, and how many are carried out
    for skill = input.skill, input.target - 1 do
        -- every recipe that gives a point here, judged in the recipes' own order
        local live = {}
        for _, c in ipairs(cands) do
            local p = Chance(skill, c.req, c.yellow, c.grey)
            if p > 0 then
                local e = Evaluate(ctx, c, skill, p)
                e.rawScore, e.rawGap, e.inUse = e.score, e.gap, c == current
                if c ~= current then e.score, e.gap = e.score * SWITCH_PENALTY, e.gap * SWITCH_PENALTY end
                Rest(ctx)
                live[#live + 1] = { c = c, p = p, e = e }
            end
        end
        local best, bestE, runner, runnerE
        for _, minChance in ipairs({ MIN_CHANCE, 0 }) do
            for _, comparable in ipairs({ true, false }) do
                for _, x in ipairs(live) do
                    local e = x.e
                    if x.p > minChance and e.comparable == comparable then
                        local c = x.c
                        if not best or Prefer(e, bestE) then
                            runner, runnerE = best, bestE
                            best, bestE = c, e
                        elseif not runner or Prefer(e, runnerE) then
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
            -- (0.2.3) what it is worth a point without the 8 %, and how much of it is your stock
            value = bestE.rawScore - 1, stock = bestE.stock,
            other = runner and { name = runner.name, key = runner.key, score = runnerE.score, comparable = runnerE.comparable,
                value = runnerE.rawScore - 1 } or nil }
        -- this point is planned: on the choice's books its materials are used
        -- up, its output is there, its recipe (and what it learned for an
        -- intermediate) is learned.
        -- In whole crafts, counted on like a step of the plan: the crafts
        -- of this recipe's points in a row are rounded up together (a new
        -- count after another recipe and where a rank is trained).
        if best ~= current or trainAt[skill] then runExpected, runCrafts = 0, 0 end
        runExpected = runExpected + 1 / Chance(skill, best.req, best.yellow, best.grey)
        local crafts = math.ceil(runExpected - 0.001) - runCrafts
        runCrafts = runCrafts + crafts
        CL.share = bestE.share
        Apply(ctx, CL, best, crafts, skill, NewAcc())
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
    if acc.open or Gap(acc) > 0 then step.comparable = false end
    if acc.estimated or acc.stockEstimated then step.estimated = true end
    if acc.openLearn or acc.feeGap then step.learnOpen = true end
    if acc.openPrice or acc.priceGap or acc.stockGap then step.priceOpen = true end
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
        Rest(ctx)
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
        local step
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
            step = last
        else
            Apply(ctx, L, c, crafts, skill, acc)
            step = joined
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
        end
        -- Extra crafts that were made for this piece and are no step of their
        -- own: where their recipe still gives skill points, those points are
        -- not counted (never a part of a point) - the plan then asks for
        -- rather too much. That is an estimate, and said to be one.
        for _, r in ipairs(L.extraList) do
            if L.extra[r] > (before[r] or 0) and r.prof == input.prof then
                local chance = ChanceOf(r, skill)
                if chance and chance > 0 then
                    ctx.skillNotCounted = true
                    step.extraSkill = true
                end
            end
        end
        skill = material and skill + 1 or segTo
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
--            estimatedItems = { id, ... }, unknownItems = { id, ... },
--            assumedItems = { id, ... } }
-- A missing material without a price is in unknownItems, in no sum. An item
-- whose count could not be read is in assumedItems: what the plan buys or
-- makes of it is counted as if you had none.
local function Rows(ctx, L)
    local input = ctx.input
    local list, ledger = {}, {}
    local cost = { known = 0, estimated = 0, estimatedItems = {}, unknownItems = {}, assumedItems = {} }
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
        if not haveKnown then
            Note(ctx, "stock_unknown", id, { item = id })
            cost.assumedItems[#cost.assumedItems + 1] = id
        end
        list[#list + 1] = { id = id, need = L.used[id], have = have, haveKnown = haveKnown, stock = input.stock[id],
            covered = haveKnown and have >= L.used[id], missing = missing, cost = copper, costStatus = status,
            price = price, node = input.nodes and input.nodes[id], planned = L.madePlan[id] or 0, made = L.madeExtra[id] or 0,
            outputAssumed = L.varies[id] or nil, missingAssumed = not haveKnown or nil,
            madeFrom = by and { prof = by.prof, key = by.key, made = math.max(1, by.made or 1), reagents = by.reagents, recipe = by,
                lastSeen = (by.prof ~= input.prof and input.professions and input.professions[by.prof]
                    and input.professions[by.prof].source == "lastSeen") or nil } or nil }
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
--                "preview" (from the skill seen last, not the one read now,
--                or making something with another profession whose skill
--                was only seen last: never "done" or "ok", whatever it
--                comes to) |
--                "invalid" (nothing to plan from: never shown as a plan)
--   valid, complete
--   skillSource  "current" | "lastSeen", skillSeenAt (when, if known),
--                reliable (false for a preview: nothing in it says what you
--                need or have reached NOW)
--   lastSeenProfessions  the professions next to the planned one whose skill
--                was only seen last AND that the plan makes something with
--                (their materials: madeFrom.lastSeen)
--   steps        { recipe, from, to, expected, crafts, low, high (the model's
--                80 % range of crafts), chanceFrom, chanceTo, forMaterials,
--                comparable, estimated, learnOpen, priceOpen, outputAssumed
--                (its output varies: counted with the mean), extraSkill
--                (extra crafts made for it could give points that are not
--                counted), why } and,
--                last, a step of unknown chance { recipe, from,
--                chanceUnknown = true } where the plan cannot go on with a
--                number
--   training     { at, assumed } - where the next rank has to be trained
--   materials    { id, need, have, haveKnown, covered (what you really have
--                covers the need - the tick), missing (to buy), planned (what
--                the plan's own steps will make: a forecast, no stock), made
--                (made extra for the plan), cost, costStatus, price, stock
--                (the snapshot's entry), node, madeFrom, outputAssumed (its
--                amount rests on the mean of a varying output),
--                missingAssumed (your count is not known: what is missing
--                or made is counted as if you had none) }
--   ledger       [item] = { start, bought, madePlan, madeExtra, used, rest }
--   extras       { recipe, times } - the extra crafts, in the order first needed
--   cost         { known, estimated, estimatedItems, unknownItems,
--                assumedItems } of what is missing; total = known +
--                estimated (never a made-up price)
--   crafts       the expected number of crafts of all steps (a sum of means;
--                the steps' ranges are not added up - concept 4.1)
--   estimate     { crafts, output, skill }: the amounts and the cost are a
--                planning estimate because a step's number of crafts is a
--                mean / because a varying output was counted with its mean /
--                because extra crafts could give skill points that are not
--                counted (the plan then asks for rather too much). All
--                false: under the model the amounts are exact.
--   notComparable  a choice was made although a part of a cost is unknown -
--                of the recipe taken, or of a way that could have cost less;
--                openPrices / openLearn say what kind (a price, a learning cost)
--   stuck, learn, diagnostics
function Core.Compute(input, pause)
    local why = Invalid(input)
    if why then
        return { status = "invalid", valid = false, complete = false, reason = why, steps = {}, training = {}, materials = {}, ledger = {}, extras = {},
            total = 0, crafts = 0, cost = { known = 0, estimated = 0, estimatedItems = {}, unknownItems = {}, assumedItems = {} },
            estimate = { crafts = false, output = false, skill = false }, reliable = false, lastSeenProfessions = {},
            learn = { fees = 0, feesUnknown = 0, trainer = 0, items = 0, itemCost = 0, itemsUnknown = 0, matsUnknown = 0, list = {} },
            diagnostics = { { code = "invalid", reason = why } } }
    end
    local ctx = { input = input, noted = {}, diagnostics = {}, producers = {}, sorted = {}, stack = {}, choice = NewLedger(true), unlocks = {},
        seen = {}, depth = 0, watch = nil, base = {}, pause = type(pause) == "function" and pause or nil }
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
        Rest(ctx)
    end
    local cands, unknownChance = Candidates(input)
    Rest(ctx)
    ctx.candOf = {}
    for _, c in ipairs(cands) do ctx.candOf[c.key] = c end
    local training, trainAt = Training(input)
    local points, info, stuck, notComparable, unknownAt = ChoosePoints(ctx, cands, unknownChance, trainAt)
    local steps, L = Walk(ctx, points, info, stuck, trainAt)
    Rest(ctx)
    local materials, ledger, cost = Rows(ctx, L)
    Rest(ctx)
    local learn = LearnCosts(input, steps, L)
    learn.matsUnknown = #cost.unknownItems
    local extras = {}
    for _, r in ipairs(L.extraList) do extras[#extras + 1] = { recipe = r, times = L.extra[r] } end
    local crafts, openLearn, openPrices = 0, false, false
    local estimate = { crafts = false, output = false, skill = ctx.skillNotCounted == true }
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
    -- from a skill that was only seen last: said in the plan, and no plan to rely on
    local lastSeen = input.skillSource == "lastSeen"
    if lastSeen then Note(ctx, "skill_last_seen", input.prof, { seenAt = input.skillSeenAt }) end
    -- the same for a profession next to the planned one (Codex round 3,
    -- R3-M1): where the plan MAKES something with a profession whose skill
    -- was only seen last, that is not certain - named, and no plan to rely on.
    -- (A plan that makes nothing with it rests on nothing uncertain.)
    local seenOnly, lastSeenProfessions = {}, {}
    for _, r in ipairs(L.extraList) do
        local own = r.prof ~= input.prof and input.professions and input.professions[r.prof]
        if own and own.source == "lastSeen" and not seenOnly[r.prof] then
            seenOnly[r.prof] = true
            lastSeenProfessions[#lastSeenProfessions + 1] = r.prof
        end
    end
    table.sort(lastSeenProfessions)
    for _, prof in ipairs(lastSeenProfessions) do
        Note(ctx, "profession_last_seen", prof, { prof = prof, seenAt = input.professions[prof].seenAt })
    end
    local preview = lastSeen or #lastSeenProfessions > 0
    if stuck then Note(ctx, "stuck", stuck, { skill = stuck }) end
    if unknownAt then
        -- the plan cannot go on with a number: the recipe is named, not counted
        Note(ctx, "chance_unknown", unknownAt.key, { skill = stuck, recipe = unknownAt.key })
        steps[#steps + 1] = { recipe = unknownAt, from = stuck, to = stuck, chanceUnknown = true }
    end
    local done = input.skill >= input.target
    local complete = not stuck and #ctx.diagnostics == 0
    return { prof = input.prof, from = input.skill, target = input.target,
        status = preview and "preview" or done and "done" or complete and "ok" or "incomplete", valid = true, complete = complete,
        skillSource = lastSeen and "lastSeen" or "current", skillSeenAt = lastSeen and input.skillSeenAt or nil, reliable = not preview,
        lastSeenProfessions = lastSeenProfessions,
        steps = steps, training = training, materials = materials, ledger = ledger, extras = extras, stuck = stuck,
        cost = cost, total = cost.known + cost.estimated, crafts = crafts, notComparable = notComparable,
        openLearn = openLearn, openPrices = openPrices, estimate = estimate,
        learn = learn, diagnostics = ctx.diagnostics }
end

-- What a second reader of the plan needs (later: the shopping list), in one
-- small table: per item need / have (and whether that is known) / missing,
-- and what the plan is - also that its amounts are a planning estimate
-- (estimate: any of crafts / output / skill) and which items rest on the mean of a varying output
-- (outputAssumed). An item whose count could not be read has no "have"; its
-- "missing" is a number all the same - counted as if you had none - and is
-- marked missingAssumed (stockAssumed: how many such items). A plan from the
-- skill seen last says so: skillSource "lastSeen", skillSeenAt, reliable
-- false, status "preview" - nothing to tick off or to buy by. The same when
-- it makes something with another profession whose skill was only seen
-- last: lastSeenProfessions names them, makeLastSeen marks the items. Made
-- from a finished plan; nothing is calculated here.
function Core.Result(plan)
    local items, assumed = {}, 0
    for _, m in ipairs(plan.materials or {}) do
        items[m.id] = { need = m.need, have = m.haveKnown and m.have or nil, haveKnown = m.haveKnown, missing = m.missing,
            covered = m.covered, planned = m.planned, make = m.madeFrom ~= nil, costStatus = m.costStatus,
            makeLastSeen = m.madeFrom ~= nil and m.madeFrom.lastSeen == true,
            outputAssumed = m.outputAssumed == true, missingAssumed = m.missingAssumed == true }
        if m.missingAssumed then assumed = assumed + 1 end
    end
    local e = plan.estimate or {}
    local lastSeenProfessions = {}
    for i, prof in ipairs(plan.lastSeenProfessions or {}) do lastSeenProfessions[i] = prof end
    return { prof = plan.prof, from = plan.from, target = plan.target, status = plan.status, valid = plan.valid == true,
        complete = plan.complete == true, items = items,
        skillSource = plan.skillSource, skillSeenAt = plan.skillSeenAt, reliable = plan.reliable == true,
        lastSeenProfessions = lastSeenProfessions,
        estimate = { crafts = e.crafts == true, output = e.output == true, skill = e.skill == true },
        stockAssumed = assumed }
end
