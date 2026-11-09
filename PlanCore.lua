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
--   prices   [item] = { copper = what one costs (nil: not known),
--                       standin = a stand-in for the recipe choice }
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

-- The recipes the plan can use, with the cost of one craft
local function Candidates(input)
    local list, unknownPrices = {}, false
    for _, r in ipairs(Sorted(input.recipes[input.prof])) do
        if r.yellow and r.grey and r.reagents and #r.reagents > 0 and r.learn then
            local cost, guessed = 0, false
            for _, reagent in ipairs(r.reagents) do
                local p = input.prices[reagent.id] or {}
                local price = p.copper
                if not price then
                    price = p.standin or 0
                    guessed = true
                end
                cost = cost + price * reagent.n
            end
            unknownPrices = unknownPrices or guessed
            list[#list + 1] = {
                key = r.key, name = r.name, product = r.product, made = r.made,
                req = math.max(1, r.req or 1), yellow = r.yellow, grey = r.grey, reagents = r.reagents,
                cost = cost, how = r.learn, fee = r.fee, recipeItem = r.recipeItem, guessed = guessed,
            }
        end
    end
    return list, unknownPrices
end

-- The steps { recipe, from, to, crafts } and where the plan got stuck (if)
local function MakeSteps(input)
    local cands, unknownPrices = Candidates(input)
    local steps, current, stuck = {}, nil, nil
    for skill = input.skill, input.target - 1 do
        local best, bestScore
        -- below 5 % only when nothing else is left (a gap before the next recipe)
        for _, minChance in ipairs({ 0.05, 0 }) do
            for _, c in ipairs(cands) do
                local chance = Chance(skill, c.req, c.yellow, c.grey)
                if chance > minChance then
                    local score = (c.cost + 1) / chance
                    if c ~= current then score = score * SWITCH_PENALTY end
                    if not bestScore or score < bestScore then best, bestScore = c, score end
                end
            end
            if best then break end
        end
        if not best then
            stuck = skill
            break
        end
        local chance = Chance(skill, best.req, best.yellow, best.grey)
        local last = steps[#steps]
        if last and last.recipe == best then
            last.to, last.expected = skill + 1, last.expected + 1 / chance
        else
            steps[#steps + 1] = { recipe = best, from = skill, to = skill + 1, expected = 1 / chance }
        end
        current = best
    end
    for _, s in ipairs(steps) do s.crafts = math.ceil(s.expected - 0.001) end
    return steps, stuck, unknownPrices
end

-- What makes an item that you can make yourself: a known recipe of the
-- planned profession or of smelting, with the skill it needs
local function Producers(input)
    local out = {}
    for _, p in ipairs({ input.prof, "Mining" }) do
        local rank = p == input.prof and input.skill or (input.professions[p] and input.professions[p].rank)
        if rank then
            for _, r in ipairs(Sorted(input.recipes[p])) do
                if r.learn == "known" and r.product and r.product > 0 and r.reagents and #r.reagents > 0
                    and (r.req or 0) <= rank and not out[r.product] then
                    out[r.product] = { prof = p, key = r.key, made = math.max(1, r.made or 1), reagents = r.reagents }
                end
            end
        end
    end
    return out
end

-- Materials of the plan: { id, need, have, missing, cost, node, madeFrom },
-- the cost of what is missing, and how many missing items have no price.
-- One stock per item for the whole plan: what you have plus what the plan's
-- own steps make. An intermediate is made again only for the need that
-- stays after that stock.
local function Materials(input, steps)
    local need, planned = {}, {}
    for _, s in ipairs(steps) do
        for _, r in ipairs(s.recipe.reagents) do
            need[r.id] = (need[r.id] or 0) + r.n * s.crafts
        end
        local product = s.recipe.product
        if product and product > 0 then
            planned[product] = (planned[product] or 0) + math.floor((s.recipe.made or 1) * s.crafts)
        end
    end
    local function Have(id) return input.stock[id] or 0 end
    local function Stock(id) return Have(id) + (planned[id] or 0) end
    local producers = Producers(input)
    local madeTimes, madeFrom = {}, {}
    for _ = 1, 100 do
        local changed = false
        local ids = {}
        for id in pairs(need) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local p = producers[id]
            if p then
                local times = math.ceil(math.max(0, need[id] - Stock(id)) / p.made)
                local extra = times - (madeTimes[id] or 0)
                if extra > 0 then
                    madeTimes[id], madeFrom[id] = times, p
                    for _, r in ipairs(p.reagents) do
                        need[r.id] = (need[r.id] or 0) + r.n * extra
                    end
                    changed = true
                    break -- the table changed: start over
                end
            end
        end
        if not changed then break end
    end
    local list, total, unknown = {}, 0, 0
    for id, n in pairs(need) do
        local missing = math.max(0, n - Stock(id))
        if madeFrom[id] then missing = 0 end -- listed by its materials
        local price = (input.prices[id] or {}).copper
        local cost = price and price * missing or nil
        total = total + (cost or 0)
        if missing > 0 and not price then unknown = unknown + 1 end -- not 0: unknown
        list[#list + 1] = { id = id, need = n, have = Have(id), missing = missing, cost = cost,
            node = input.nodes and input.nodes[id], madeFrom = madeFrom[id] }
    end
    table.sort(list, function(a, b)
        if (a.madeFrom ~= nil) ~= (b.madeFrom ~= nil) then return b.madeFrom ~= nil end
        if a.missing ~= b.missing then return a.missing > b.missing end
        return a.id < b.id
    end)
    return list, total, unknown
end

-- What the recipes of the plan cost to learn, once each
local function LearnCosts(input, steps)
    local seen = {}
    local c = { fees = 0, feesUnknown = 0, trainer = 0, items = 0, itemCost = 0, itemsUnknown = 0 }
    for _, s in ipairs(steps) do
        local r = s.recipe
        if not seen[r] then
            seen[r] = true
            if r.how == "trainer" then
                c.trainer = c.trainer + 1
                if type(r.fee) == "number" then c.fees = c.fees + r.fee else c.feesUnknown = c.feesUnknown + 1 end
            elseif r.how == "vendor" then
                c.items = c.items + 1
                local price = r.recipeItem and input.recipeItemPrices and input.recipeItemPrices[r.recipeItem]
                if price then c.itemCost = c.itemCost + price else c.itemsUnknown = c.itemsUnknown + 1 end
            end
        end
    end
    return c
end

-- The plan: { steps, materials, total (cost of the missing materials),
-- stuck (the skill no recipe was found for), unknownPrices (stand-in prices
-- were used), learn (fees and recipe items), matsUnknown }
function Core.Compute(input)
    local steps, stuck, unknownPrices = MakeSteps(input)
    local materials, total, matsUnknown = Materials(input, steps)
    local learn = LearnCosts(input, steps)
    learn.matsUnknown = matsUnknown
    return { prof = input.prof, from = input.skill, target = input.target, steps = steps, materials = materials,
        total = total, stuck = stuck, unknownPrices = unknownPrices, learn = learn }
end
