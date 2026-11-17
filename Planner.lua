local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Skill planner: a way from your skill to a target skill, chosen by cost
--   (a heuristic: a good plan, not proven to be the best one)
--   * every recipe you know, a trainer teaches or a vendor sells (drops and
--     quests are left out: you can't count on them)
--   * skill-up chance from the recipe's colours (Data/RecipeData.lua colors):
--     orange 100 %, yellow and green fall off towards grey
--     (chance = (grey - skill) / (grey - yellow), the usual Classic rule)
--   * per skill point the recipe that costs the least gold on top of what
--     you have, per expected point (PlanCore.lua); staying on the same
--     recipe is preferred a little (fewer steps)
--   * the material list: what you have and need (bags, reagent bag, bank),
--     what is missing and what that costs; what you can make yourself
--     (your professions, the recipe known or learned in the plan, skill
--     high enough) is made when that costs less than buying it; herbs and
--     ore you can gather get a button that starts a farm run for them
--   * trainer fees and recipe items of the recipes the plan uses count
--     in the choice, once each; where you have to train the next rank is a
--     step of its own; prices and fees nobody knows yet are counted as
--     unknown, never as 0
---------------------------------------------------------------------------
local CAPS = { 75, 150, 225, 300 }
local ROW_H = 18
local WIDE_W = 492  -- a line without a right column (hints, notes): the whole row, wrapped

local function Data() return ns.CraftData end

-- Can this character learn the recipe somewhere reliable?
local function HowToLearn(prof, key, spell, known, req, grey)
    if known[key] then return "known" end
    local src = GathercraftRecipeSources
    if src and src.trainer and src.trainer[spell] then return "trainer", src.trainer[spell] end
    local item = src and src.scroll and src.scroll[spell]
    local packed = item and src.items and src.items[item]
    if packed and packed:find("V:", 1, true) then
        local mine = UnitFactionGroup and UnitFactionGroup("player")
        local letter = mine == "Alliance" and "A" or mine == "Horde" and "H" or nil
        for list in packed:gmatch("V:([%d,]+)") do
            for id in list:gmatch("%d+") do
                local npc = src.npcs and src.npcs[tonumber(id)]
                local friendly = npc and npc:match("^[^|]*|%d*|([^|]*)")
                if friendly and (not letter or friendly == "" or friendly:find(letter, 1, true)) then
                    return "vendor", nil, item
                end
            end
        end
    end
    -- no trainer fee and no recipe item, and only for the first steps: taught
    -- with the profession itself (anything else comes from quests or drops)
    if (req or 0) <= 1 and not item and grey and grey <= 75 then return "start" end
end

-- A recipe read from a profession window has no required skill: take the shipped one
local function RequiredOf(prof, key, req)
    if (req or 0) == 0 then
        local shipped = GathercraftRecipeData.professions and GathercraftRecipeData.professions[prof]
        if shipped and shipped[key] then
            local _, _, shippedReq = Data().Unpack(shipped[key])
            req = shippedReq or req
        end
    end
    return req
end

-- Herbs and ore: which node gives the item (for a farm run)
local nodeOfItem
local function NodeFor(itemID)
    if not nodeOfItem then
        nodeOfItem = {}
        local kinds = GathercraftQuestieData and GathercraftQuestieData.kinds or {}
        for _, kind in pairs(kinds) do
            local t, item, name = kind[1], kind[2], kind[3]
            if (t == "h" or t == "o") and item and item > 0 and name then
                local have = nodeOfItem[item]
                -- the plain node ("Copper Vein"), not a rare variant, names the run
                if not have or #name < #have then nodeOfItem[item] = name end
            end
        end
    end
    return nodeOfItem[itemID]
end

---------------------------------------------------------------------------
-- The snapshot for the calculation (PlanCore.lua): everything the plan
-- reads from the game goes through here, once per item (so one plan sees
-- one state), and only what the calculation asks for.
---------------------------------------------------------------------------
-- the recipes of a profession as the calculation wants them; onlyKnown: the
-- ones this character knows (the professions next to the planned one)
local function RecipeList(prof, onlyKnown)
    local d = Data()
    local spells = GathercraftRecipeData and GathercraftRecipeData.spells and GathercraftRecipeData.spells[prof] or {}
    local colors = GathercraftRecipeData and GathercraftRecipeData.colors or {}
    local known = d.Known(prof)
    local source = {}
    if not onlyKnown then
        for key, packed in pairs(d.AllRecipes(prof)) do source[key] = packed end
    end
    for key, packed in pairs(known) do source[key] = packed end
    local list = {}
    for key, packed in pairs(source) do
        local product, made, req, reagents = d.Unpack(packed)
        if reagents then
            -- "makes 1 to 2": Unpack gives the mean; that it is one is passed on
            local least, most = packed:match("^%d+:(%d+):(%d+):")
            local spell = spells[key]
            local c = spell and colors[spell]
            local yellow, grey
            if c then yellow, grey = c:match("^(%d+):(%d+)$") end
            yellow, grey = tonumber(yellow), tonumber(grey)
            req = RequiredOf(prof, key, req)
            local learn, fee, recipeItem
            if known[key] then learn = "known" elseif not onlyKnown then learn, fee, recipeItem = HowToLearn(prof, key, spell, known, req, grey) end
            list[#list + 1] = { prof = prof, key = key, name = d.DisplayName(prof, key), spell = spell, product = product, made = made,
                madeVaries = least ~= most, packed = packed,
                req = req, yellow = yellow, grey = grey, reagents = reagents, learn = learn, fee = fee, recipeItem = recipeItem }
        end
    end
    return list
end

local SkillState -- (your skill in a profession, as the window reads it: further down)

-- source, seenAt: "lastSeen" (and when) for a skill that is not read now
local function Snapshot(prof, from, to, source, seenAt)
    local d = Data()
    local input = { prof = prof, skill = from, target = to, recipes = {}, professions = {} }
    if source == "lastSeen" then input.skillSource, input.skillSeenAt = "lastSeen", seenAt end
    input.recipes[prof] = RecipeList(prof)
    -- The professions you have, each read like the planned one (Codex round
    -- 3, R3-M1) - a remembered skill and remembered recipes are no proof:
    --   * read now: its known recipes can be used
    --   * the whole skill list can be read and it is NOT in it: you do not
    --     have it (any more) - nothing is made with it, whatever was kept
    --     from its window. (What was kept stays: it counts again when the
    --     profession is back.)
    --   * its skill cannot be read now, one was seen before: used with the
    --     skill seen last, said to be that - a plan that makes something
    --     with it is a preview (PlanCore.lua)
    --   * nothing known about it: not used
    for _, p in ipairs(d.Professions) do
        local state, rank, _, _, rankSource, rankSeenAt = SkillState(p.name)
        if state == "learned" then
            input.professions[p.name] = { rank = rank, source = rankSource == "lastSeen" and "lastSeen" or nil,
                seenAt = rankSource == "lastSeen" and rankSeenAt or nil }
            if p.name ~= prof then input.recipes[p.name] = RecipeList(p.name, true) end
        end
    end
    -- what you have (bags, reagent bag, bank - counted as since 0.1.18, no
    -- parameter guessed): read once per item and plan. A count that cannot
    -- be read (a hidden value, an error, no answer) is "unknown", not 0 -
    -- also when the game has neither of its counting functions: the 0 the
    -- counting falls back to then is no count (Codex round 1, B6).
    local canCount = (C_Item and C_Item.GetItemCount) or GetItemCount
    input.stock = setmetatable({}, { __index = function(t, id)
        local ok, n = false, nil
        if canCount then ok, n = pcall(d.Have, id) end
        local entry
        if ok and n ~= nil and not ns.AnySecret("skill plan stock", n) and type(n) == "number" then
            entry = { n = n }
        else
            entry = { unknown = true }
        end
        rawset(t, id, entry)
        return entry
    end })
    -- what one costs to buy: the price the Crafting tab uses (a vendor who
    -- showed it, else the auction price by the 0.1.16 rule; what a vendor
    -- PAYS for an item is no buying price). Its own estimate for a few
    -- vendor goods is marked estimated; no price at all is unknown - nothing
    -- is made up for it (the old stand-ins, 2000c and four times the vendor's
    -- price, are gone).
    input.prices = setmetatable({}, { __index = function(t, id)
        local price, source, guessed = d.ReagentCost(id)
        local entry
        if type(price) == "number" then
            entry = { status = guessed and "estimated" or "known", copper = price, source = source,
                age = ns.PriceAgeOf and ns.PriceAgeOf(id) or nil }
        else
            entry = { status = "unknown" }
        end
        rawset(t, id, entry)
        return entry
    end })
    input.recipeItemPrices = setmetatable({}, { __index = function(t, id)
        local price = ns.db.vendorPrices and ns.db.vendorPrices[id]
        rawset(t, id, price or false)
        return price or false
    end })
    local _, maxRank = nil, nil
    if ns.ProfessionRank then _, maxRank = ns.ProfessionRank(prof) end
    input.maxRank = (type(maxRank) == "number" and maxRank > 0) and maxRank or nil
    input.caps = CAPS
    input.nodes = setmetatable({}, { __index = function(_, id) return NodeFor(id) end })
    return input
end

ns.SkillPlanSnapshot = Snapshot

---------------------------------------------------------------------------
-- One plan per state (concept 4.6): the plan is calculated on a snapshot
-- and gets a revision. As long as nothing it read has changed - skill,
-- target, recipes, the counts and prices it asked for - the same plan
-- stays, with the same revision: a burst of bag events, an event that
-- comes twice or late, changes nothing. Only the open window calculates.
-- "Recipes" means all of a recipe the calculation uses (RecipeSignature): a
-- recipe the profession window read anew with other ingredients or another
-- output is another state, and gives a new plan.
--   ns.SkillPlanResult()   the last result for a second reader (later: the
--                          shopping list): { revision, prof, from, target,
--                          status, valid, complete, skillSource, skillSeenAt,
--                          reliable, items = { [item] =
--                          { need, have, haveKnown, missing, covered,
--                          planned, make, costStatus } } } - or nil.
--                          reliable = false (status "preview"): the plan is
--                          from the skill seen last, not from the skill read
--                          now - nothing to count as reached or to buy by.
--                          updating = true: the state has changed and a new
--                          plan is being worked out (or would be, were the
--                          window open or a plan run active) - this one is
--                          the last finished one.
--   ns.SkillPlanBusy()     is the window working out a plan right now?
--   ns.skillPlanListeners  functions called with that result when a new
--                          revision is there
--   ns.SkillPlanFor()      the plan for a plan run, the second reader (below)
---------------------------------------------------------------------------
local calc = { revision = 0 }
ns.skillPlanListeners = ns.skillPlanListeners or {}

-- Everything of a recipe the calculation uses (Codex round 1, B4): its
-- record as the game gave it - the product, how many a craft makes, every
-- ingredient with its amount - and what the snapshot adds: the skill it
-- needs, its colours, how it is learned and what that costs. Written out in
-- full, no sum over it: two different recipes never look the same.
local function RecipeSignature(r)
    return table.concat({ r.key, tostring(r.packed), tostring(r.learn), tostring(r.req), tostring(r.yellow), tostring(r.grey),
        tostring(r.fee), tostring(r.recipeItem) }, "\031")
end

-- what is not read through the lazy tables: skill, target, ranks, recipes
local function Signature(input)
    -- (a skill seen last is another state than the same skill read now)
    local parts = { input.prof, tostring(input.skill), tostring(input.target), tostring(input.maxRank), tostring(input.skillSource) }
    local profs = {}
    for prof in pairs(input.recipes) do profs[#profs + 1] = prof end
    table.sort(profs)
    for _, prof in ipairs(profs) do
        local list = {}
        for i, r in ipairs(input.recipes[prof]) do list[i] = RecipeSignature(r) end
        table.sort(list) -- (the same recipes in another order are the same state)
        local own = input.professions[prof]
        -- (a skill seen last is another state than the same skill read now)
        parts[#parts + 1] = ("%s:%s:%s:%d:"):format(prof, tostring(own and own.rank), tostring(own and own.source), #list) .. table.concat(list, "\030")
    end
    return table.concat(parts, "|")
end

-- did anything the last plan read change? (reads them again, once each)
local function SameReads(old, new)
    for id, e in pairs(old.stock) do
        local n = new.stock[id]
        if (e.unknown or false) ~= (n.unknown or false) or e.n ~= n.n then return false end
    end
    for id, e in pairs(old.prices) do
        local n = new.prices[id]
        if e.status ~= n.status or e.copper ~= n.copper then return false end
    end
    for id, e in pairs(old.recipeItemPrices) do
        if new.recipeItemPrices[id] ~= e then return false end
    end
    return true
end

-- The finished plans of the readers outside the window (0.2 B3 R1-M1): one
-- for each profession and target, at most KEPT_PLANS. A plan run and the
-- list of zones of another profession each find their own plan here, as
-- long as nothing it read has changed - and so do not set each other's
-- calculation off again. (The result kept is a copy: what the window marks
-- as being updated is the window's.)
local KEPT_PLANS = 4
local function PlanKey(prof, target) return tostring(prof) .. ":" .. tostring(target) end
local function Keep(input, sig, plan, result)
    calc.kept = calc.kept or {}
    local copy = {}
    for k, v in pairs(result) do copy[k] = v end
    copy.updating = nil
    calc.kept[PlanKey(input.prof, input.target)] = { input = input, sig = sig, plan = plan, result = copy, at = calc.revision }
    local n, oldest = 0, nil
    for key, e in pairs(calc.kept) do
        n = n + 1
        if not oldest or e.at < calc.kept[oldest].at then oldest = key end
    end
    if n > KEPT_PLANS then calc.kept[oldest] = nil end
end

-- a finished plan becomes THE plan: a new revision, a new result
local function Publish(input, sig, plan)
    calc.plan, calc.input, calc.sig = plan, input, sig
    calc.revision = calc.revision + 1
    plan.revision = calc.revision
    local result = ns.PlanCore.Result(plan)
    result.revision = calc.revision
    -- why a plan is incomplete, as far as it says (for a plan run that ends
    -- on it, 0.2 B3 R1-M4): where it got stuck, what is made from itself
    local why = {}
    for _, diag in ipairs(plan.diagnostics or {}) do
        if diag.code == "stuck" or diag.code == "cycle" then why[#why + 1] = { code = diag.code, skill = diag.skill, item = diag.item } end
    end
    result.why = why
    calc.result = result
    Keep(input, sig, plan, result)
    for _, fn in ipairs(ns.skillPlanListeners) do pcall(fn, result) end
end

-- the plan for this state, and whether it is a new one - worked out in ONE
-- GO: the whole calculation runs inside this call (the window does it in
-- parts, below). For the tests and for a caller that needs the plan at
-- once, outside of play. NOT for a call on every event in the game: a big
-- plan would hold the game up for its whole length. A later reader of the
-- plan (the shopping list) does not call this - it takes what the window
-- worked out, ns.SkillPlanResult() and ns.skillPlanListeners, and goes by
-- its status, reliable and updating.
local function Calculate(prof, skill, target, source, seenAt)
    local input = Snapshot(prof, skill, target, source, seenAt)
    local sig = Signature(input)
    if calc.plan and calc.sig == sig and SameReads(calc.input, input) then
        return calc.plan, false
    end
    Publish(input, sig, ns.PlanCore.Compute(input))
    return calc.plan, true
end
ns.SkillPlanCalculate = Calculate
ns.SkillPlanResult = function() return calc.result end

---------------------------------------------------------------------------
-- The window's plan is worked out in parts (Codex round 2, R2-M4). A big
-- plan takes a while, and one long call would hold the whole game up. So
-- the calculation runs as a coroutine: it works for BUDGET_MS, is put down
-- at one of its resting places (PlanCore.lua, Rest) and goes on in the next
-- frame - until it is done.
--   * one part per frame, each at most BUDGET_MS plus the short way to the
--     next resting place. The first part runs right away: a small plan is
--     there at once, as before.
--   * while it is worked out the plan of before stays on the screen, marked
--     "Updating the plan ..."; only a finished plan takes its place. Nothing
--     of a plan that is half done is ever shown or given out.
--   * a new state while it is worked out (the bags, the skill, the target,
--     a price): what was begun is dropped and the calculation starts anew.
--     The snapshot is read as the calculation asks for it - over several
--     frames - so a finished plan is only taken when a fresh look at the
--     game shows everything it read unchanged: never a plan from two states.
--   * the window is closed: nothing goes on.
--   * the calculation breaks (an error, in whatever part): what was begun is
--     dropped, the window is drawn anew - the plan of before without
--     "Updating", and a line that says the plan could not be worked out -
--     and THEN the error is raised: reported as an error, not swallowed.
--     Nothing is begun again for the same state (it would break again, part
--     after part); a new state, opening the window or setting a target is.
--   * the plan is the one the calculation in one go gives (the same code;
--     where it rests changes nothing it works out).
-- 4 ms: a quarter of a frame at 60 frames a second. ns.SkillPlanClock (ms)
-- stands in for the game's clock in the tests.
---------------------------------------------------------------------------
--
-- One calculation at a time, in order (0.2 B3 R2-M1): the calculation that
-- runs belongs to ONE plan - a profession and a target (PlanKey) - and the
-- state it was begun for.
--   * another plan that is wanted meanwhile (the plan run and the list of
--     zones read different plans) does not drop it: it waits its turn - at
--     most once for each plan, a plan that asks again is the same wait.
--   * a finished calculation is taken for its own plan - after a fresh look
--     at the game with what it was begun for - and kept (Keep), before the
--     next one begins. Out of date by then: begun anew for the same plan, at
--     the end of the line.
--   * the plan that runs is dropped or begun anew only for its own plan: a
--     new state of it (the bags, the skill, a price, the recipes).
--   * the window comes first: what it shows is worked out at once; a
--     calculation of another plan is put aside as far as it got and goes on
--     once the window is closed.
local BUDGET_MS = 4
local job -- the calculation that is running: { key, args, input, sig, co, deadline, parts, plan (once done), failed (its error) }
local waiting = {} -- the plans that wait their turn, oldest first: calculations like `job`, at most one for each plan
local broke = {} -- for each plan, the state its calculation broke for: { input, sig, err, reported }

local function Clock()
    local clock = ns.SkillPlanClock or debugprofilestop
    if clock then return clock() end
    return GetTimePreciseSec and GetTimePreciseSec() * 1000 or 0
end

-- args: what the snapshot was taken with (prof, skill, target, source, seenAt)
local function NewJob(input, sig, args)
    local j = { key = PlanKey(args[1], args[3]), args = args, input = input, sig = sig, parts = 0 }
    local function Pause()
        if Clock() >= j.deadline then coroutine.yield() end
    end
    j.co = coroutine.create(function() return ns.PlanCore.Compute(input, Pause) end)
    return j
end

-- one part of the work, until BUDGET_MS after `since` (now, when nothing
-- else was done in this call before it). An error in the calculation ends
-- it: what was begun is dropped and the error kept for this state - the
-- window is drawn first and raises it then (Refresh).
local function Part(j, since)
    j.parts = j.parts + 1
    j.deadline = (since or Clock()) + BUDGET_MS
    local ok, plan = coroutine.resume(j.co)
    if not ok then
        j.failed = plan == nil and "the skill plan calculation failed" or plan
        if job == j then job = nil end
        broke[j.key] = { input = j.input, sig = j.sig, err = j.failed, reported = false }
        return
    end
    if coroutine.status(j.co) == "dead" then j.plan = plan end
end

-- the parts after the first: one per frame, while the window is open and
-- this is still the calculation that is wanted. The frame after the last
-- part takes the finished plan (a fresh look at the game, then the window is
-- drawn) - not the frame that did the last part as well.
local runnerOn = false -- a plan run reads the plan too (0.2 B3, below)
local function WindowShown()
    local shown = _G.GathercraftSkillPlan
    return (shown and shown:IsShown()) and true or false
end
-- a part is done or broke: whoever reads the plan looks again - the open
-- window, else the plan run
local function Advance()
    if WindowShown() then
        ns.RefreshSkillPlan()
    elseif runnerOn and ns.PlanRunLook then
        ns.PlanRunLook()
    end
end
-- nothing goes on: no window, no reader
local function DropAll()
    job = nil
    waiting = {}
end
-- a plan waits its turn: once - a plan that waits already waits on, or with
-- the newer state if its own changed (R2-M1)
local function Wait(j)
    for i, w in ipairs(waiting) do
        if w.key == j.key then
            waiting[i] = j
            return
        end
    end
    waiting[#waiting + 1] = j
    if #waiting > KEPT_PLANS then table.remove(waiting, 1) end
end
local function Waiting(key)
    for i, w in ipairs(waiting) do
        if w.key == key then return w, i end
    end
end
local Drive
-- the next plan in line, when nothing runs - not while the window is open:
-- it comes first, the line goes on once it is closed (the readers look
-- again then, R1-M2)
local function StartNext()
    if job or not waiting[1] then return end
    if not WindowShown() then
        if not runnerOn then
            DropAll()
            return
        end
        job = table.remove(waiting, 1)
        Drive(job)
    end
end
-- a plan is wanted for another state now, or not at all: what was begun or
-- broke for it, or waits, is dropped - only for this plan
local function Forget(key)
    broke[key] = nil
    local _, i = Waiting(key)
    if i then table.remove(waiting, i) end
    if job and job.key == key then
        job = nil
        StartNext()
    end
end
-- a finished calculation goes to its own plan: a fresh look at the game
-- with what it was begun for - nothing it read has changed: given out and
-- kept; else begun anew for the same plan, at the end of the line. Then the
-- next plan's turn. (Its own reader takes it when it looks, as before; this
-- is for when another reader looks first.) The look takes the skill of the
-- profession as it is now - its rank, read now or seen last - not the one it
-- was begun with; one that cannot be read (or is not learned) now: nothing is
-- given out or begun, its reader looks itself again (R3 A-N1).
local function Settle(j)
    job = nil
    local prof, target = j.args[1], j.args[3]
    local skillState, rank, _, _, source, seenAt = SkillState(prof)
    if skillState ~= "learned" then
        StartNext()
        return
    end
    local args = { prof, rank, target, source == "lastSeen" and "lastSeen" or nil, seenAt }
    local fresh = Snapshot(unpack(args, 1, 5))
    local sig = Signature(fresh)
    if sig == j.sig and SameReads(j.input, fresh) then
        Publish(j.input, j.sig, j.plan)
    else
        local again = NewJob(fresh, sig, args)
        again.window = j.window
        Wait(again)
    end
    StartNext()
end
Drive = function(j)
    -- (a calculation put aside and taken up again is driven by its newest call only)
    j.turn = (j.turn or 0) + 1
    local turn = j.turn
    C_Timer.After(0, function()
        if job ~= j or j.turn ~= turn then return end
        if not WindowShown() and not runnerOn then
            DropAll() -- closed and no plan run: nothing goes on
            return
        end
        if j.plan then
            Advance() -- (whoever reads the plan looks: its own reader takes it)
            return
        end
        Part(j)
        if j.failed then
            -- it broke in this part: the window is drawn without "Updating"
            -- and raises the error
            Advance()
            StartNext()
            return
        end
        Drive(j)
    end)
end

-- The plan to show for this state, whether a new one is being worked out,
-- and - when the calculation broke for this state - what broke: the plan of
-- this state when it is there; else the last finished plan of this
-- profession (nil when there is none) while the new one is worked out in
-- parts, or after it broke. Another plan's calculation that runs meanwhile
-- is not dropped: this one waits its turn (R2-M1) - unless the window asks.
local function PlanToShow(prof, skill, target, source, seenAt)
    local began = Clock() -- (taking the snapshot is part of this call's time)
    local key = PlanKey(prof, target)
    if job and job.plan and job.key ~= key then Settle(job) end -- (another plan's, finished: its own first)
    local input = Snapshot(prof, skill, target, source, seenAt)
    local sig = Signature(input)
    -- begun for this very state of this plan, and nothing it read has changed
    local function Fits(j) return j ~= nil and j.key == key and j.sig == sig and SameReads(j.input, input) end
    if calc.plan and calc.sig == sig and SameReads(calc.input, input) then
        Forget(key) -- (whatever was begun or broke for this plan was for another state of it)
        calc.result.updating = nil
        return calc.plan, false
    end
    local before = (calc.plan and calc.plan.prof == prof) and calc.plan or nil
    local b = broke[key]
    if b and b.sig == sig and SameReads(b.input, input) then
        -- it broke for this very state: not begun again. The plan of before
        -- is out of date, and nothing is on its way.
        if calc.result then calc.result.updating = true end
        return before, false, b
    end
    broke[key] = nil
    local window = WindowShown() -- (the window asks: SkillPlanFor does not while it is shown)
    if job and job.key == key then
        if Fits(job) then
            if job.plan then
                -- finished and not taken yet
                local j = job
                job = nil
                Publish(j.input, j.sig, j.plan)
                StartNext()
                return calc.plan, false
            end
            if calc.result then calc.result.updating = true end
            return before, true
        end
        job = nil -- begun for another state of this plan: begun anew, below
    elseif job and window then
        -- the window comes first: a reader's calculation of another plan is
        -- put aside, as far as it got, and goes on once the window is closed;
        -- one the window began for what it showed before is dropped, as before
        if not job.window then table.insert(waiting, 1, job) end
        job = nil
    end
    local args = { prof, skill, target, source, seenAt }
    if job then
        -- another plan is worked out: this one waits its turn
        if not Fits((Waiting(key))) then Wait(NewJob(input, sig, args)) end
        if calc.result then calc.result.updating = true end
        return before, true
    end
    -- this plan's turn: as far as it got while it waited, if that still fits
    local j, i = Waiting(key)
    if i then table.remove(waiting, i) end
    if not Fits(j) then j = NewJob(input, sig, args) end
    j.window = window
    job = j
    Part(j, began)
    if j.failed then
        if calc.result then calc.result.updating = true end
        StartNext()
        return before, false, broke[key]
    end
    if j.plan then
        -- done in this part (what it read before, it read again just now)
        job = nil
        Publish(j.input, j.sig, j.plan)
        StartNext()
        return calc.plan, false
    end
    Drive(j)
    if calc.result then calc.result.updating = true end
    return before, true
end
-- the window shows no plan (no profession, a skill that cannot be read):
-- nothing is worked out for it (a calculation of a reader goes on)
local function DropJob()
    if job and job.window then
        job = nil
        StartNext()
    end
end
-- the player asks again (opens the window, sets a target): what broke
-- before may be tried once more
local function TryAgain() broke = {} end
ns.SkillPlanBusy = function() return job ~= nil or waiting[1] ~= nil end
ns.SkillPlanWaiting = function() return #waiting end -- (how many plans wait their turn: for the tests)

---------------------------------------------------------------------------
-- The second reader: an active plan run (0.2 B3, concept shopping list 4.1,
-- Codex P1). It reads the SAME plan as the window - one calculation, one
-- revision, worked out in the same parts - and nothing of its own:
--   * the window is open: it decides what is planned. The run gets the
--     result when it is the plan of its profession and target, and
--     "window" when the window shows something else (the run then knows
--     nothing new and decides nothing).
--   * the window is closed: the run asks for the plan of its profession
--     and target, as the window would.
--   * no window and no run (ns.SkillPlanRunner(false)): nothing is worked
--     out, as before.
-- ns.SkillPlanFor(prof, target) -> the result (never one that is being
-- updated), or nil and why: "off", "window", "skill" (it cannot be read or
-- the profession is not learned), "working" (on its way: ns.PlanRunLook is
-- called when it is there), "broke".
---------------------------------------------------------------------------
ns.SkillPlanRunner = function(on)
    runnerOn = on and true or false
    -- the last reader is gone and the window is closed: what was begun (or
    -- finished and not taken yet) is dropped - nothing goes on, nothing waits
    if not runnerOn and not WindowShown() then DropAll() end
end
ns.SkillPlanFor = function(prof, target)
    if not runnerOn then return nil, "off" end
    if WindowShown() then
        -- (what the window shows now - not what it showed before: a plan of
        -- this profession left from earlier is not kept up to date)
        local shownProf, shownTarget = ns.SkillPlanShown()
        if shownProf ~= prof or shownTarget ~= target then return nil, "window" end
        local r = calc.result
        if not (r and r.prof == prof and r.target == target) then return nil, "working" end
        if r.updating or job then return nil, "working" end
        return r
    end
    local skillState, rank, _, _, source, seenAt = SkillState(prof)
    if skillState ~= "learned" then
        Forget(PlanKey(prof, target)) -- (only this plan: another reader's goes on, R2-M1)
        return nil, "skill"
    end
    -- another plan's calculation is finished: it goes to its own plan first
    -- (R2-M1) - this reader may need nothing worked out and not ask further
    if job and job.plan and job.key ~= PlanKey(prof, target) then Settle(job) end
    -- its own plan, kept, and nothing it read has changed: that one - without
    -- touching what is worked out for another reader (R1-M1)
    local kept = calc.kept and calc.kept[PlanKey(prof, target)]
    if kept then
        local input = Snapshot(prof, rank, target, source == "lastSeen" and "lastSeen" or nil, seenAt)
        if kept.sig == Signature(input) and SameReads(kept.input, input) then return kept.result end
    end
    local plan, updating, broken = PlanToShow(prof, rank, target, source == "lastSeen" and "lastSeen" or nil, seenAt)
    if broken then
        -- reported once, like any other error - after the run has been told
        if not broken.reported then
            broken.reported = true
            local err = broken.err
            C_Timer.After(0, function() error(err, 0) end)
        end
        return nil, "broke"
    end
    if updating or not plan or plan ~= calc.plan then return nil, "working" end
    kept = calc.kept and calc.kept[PlanKey(prof, target)]
    return (kept and kept.plan == plan) and kept.result or calc.result
end

-- steps, materials, cost of the missing materials, where the plan got stuck,
-- whether stand-in prices were used, and info = { learn costs, missing
-- materials without a price }. The calculation itself is ns.PlanCore.Compute
-- (PlanCore.lua); this takes the snapshot for it.
-- Like ns.SkillPlanCalculate it works the plan out in one go, inside the
-- call, and keeps nothing: for the tests, not for a call on every event in
-- the game (see there).
ns.SkillPlan = function(prof, from, to)
    local plan = ns.PlanCore.Compute(Snapshot(prof, from, to))
    local steps = {}
    for _, s in ipairs(plan.steps) do
        if not s.chanceUnknown then steps[#steps + 1] = s end -- counted steps only
    end
    return steps, plan.materials, plan.total, plan.stuck, plan.notComparable, plan.learn, plan
end

---------------------------------------------------------------------------
-- Window (concept 5, as Sven set it on 08.11.)
--   * the plan of exactly ONE profession: the one chosen on the Crafting
--     tab (or named on the command line). No switch for the profession in
--     here; none chosen: "Choose a profession first."
--   * your skill is read, never assumed: learned -> the plan from there;
--     positively not learned -> a preview from 1, said so; not readable ->
--     "skill unknown" and no plan (not a start at 1) - also when the
--     profession is in the skill list and only its skill cannot be read
--   * not readable now, but seen before (Codex round 2, R2-M3): the skill
--     seen last, said to be that and how old it is - a PREVIEW from there.
--     No "done", the materials and the sum marked as a preview, the result
--     not reliable.
--   * the same for a profession next to it that the plan makes something
--     with (Codex round 3, R3-M1): a line names it, the sum says "preview",
--     no "done". A profession you no longer have makes nothing.
--   * the target comes from a small menu (75 / 150 / 225 / 300, a value of
--     your own, back to the default) and stays as you set it - per character
--     and profession in ns.db.planTargets. Reached: "done", no jump to the
--     next rank.
--   * everywhere "have / need"; a tick (a game texture) and a green row only
--     when what you really have covers the need
--   * steps: skill range, recipe, chance, about how many crafts with the
--     model's range; training the next rank is a row between
--   * the amounts are a planning estimate (PlanCore.lua): the window says so
--     under the materials and in their tooltips, and marks an output that
--     varies
--   * what a recipe needs beyond its ingredients (a tool, a forge, an anvil,
--     a cooldown) is not checked: one line under the materials says so
--   * a big plan is worked out in parts over several frames (above): the
--     plan of before stays, marked "Updating the plan ..."; with none to
--     show: "Working out the plan ..."
--   * it only shows: nothing is crafted, bought, learned or moved from here
---------------------------------------------------------------------------
local win, profText, skillText, targetLabel, targetButton, targetMenu, targetEdit, content, totalText, noteText
local rows = {}
local state = { prof = nil, hint = nil }

local TICK = "Interface\\RaidFrame\\ReadyCheck-Ready"
local GOLD, GREY, DIM, RED, GREEN, WHITE = { 1, 0.82, 0.3 }, { 0.7, 0.7, 0.7 }, { 0.6, 0.6, 0.6 }, { 1, 0.5, 0.4 }, { 0.45, 1, 0.45 }, { 1, 1, 1 }

local function ItemName(id)
    return (ns.ItemName and ns.ItemName(id)) or (L["item "] .. id)
end

local function CharKey()
    return (ns.Readable(UnitName("player"), "skill plan") or "?") .. "-" .. ((GetNormalizedRealmName and GetNormalizedRealmName()) or "?")
end

-- What the skill list itself says about a profession, line by line, by the
-- profession each line names:
--   "rank", rank, maximum   its line is there and its skill can be read
--   "hidden"                its line is there, its skill cannot be read
--   "absent"                the whole list could be read - it is there, every
--                           line readable, no group folded - and the
--                           profession is not in it
--   nil                     the list cannot be read
local function ListSays(prof)
    if not (GetNumSkillLines and GetSkillLineInfo) then return nil end
    local okN, count = pcall(GetNumSkillLines)
    if not okN or count == nil or ns.AnySecret("skill plan skills", count) or type(count) ~= "number" or count <= 0 then return nil end
    for i = 1, count do
        local okL, name, isHeader, isExpanded, lineRank, _, _, lineMax = pcall(GetSkillLineInfo, i)
        if not okL or name == nil or ns.AnySecret("skill plan skills", name, isHeader, isExpanded) or type(name) ~= "string" then return nil end
        if isHeader and isExpanded == false then return nil end
        if not isHeader and (ns.ProfKey and ns.ProfKey(name) or name) == prof then
            if lineRank == nil or ns.AnySecret("skill plan skill", lineRank) or type(lineRank) ~= "number" then return "hidden" end
            if lineMax ~= nil and (ns.AnySecret("skill plan skill", lineMax) or type(lineMax) ~= "number" or lineMax <= 0) then lineMax = nil end
            return "rank", lineRank, lineMax
        end
    end
    return "absent"
end

-- Your skill in a profession:
--   "learned", rank, maximum, nil, source, seenAt
--                 source "current": the skill read now. "lastSeen": it cannot
--                 be read now - the rank is the one seen last (seenAt: when,
--                 nil when that was not kept). Never shown or counted as the
--                 current skill (Codex round 2, R2-M3).
--   "unlearned"   only with proof: the whole skill list could be read AND the
--                 profession is not in it (a skill seen earlier does not
--                 stand against that)
--   "unknown"     everything else. With "rank" as the fourth value when the
--                 profession was FOUND but its skill cannot be read (hidden,
--                 no number): that is never "not learned" (Codex round 1, B5).
-- Every value is checked for being readable before it is compared, counted
-- with or shown.
SkillState = function(prof)
    local ok, rank, maxRank, source, seenAt = pcall(ns.ProfessionRank, prof)
    if not ok then return "unknown" end
    if rank ~= nil and source ~= "lastSeen" then
        if ns.AnySecret("skill plan skill", rank) or type(rank) ~= "number" then return "unknown", nil, nil, "rank" end
        if maxRank ~= nil and (ns.AnySecret("skill plan skill", maxRank) or type(maxRank) ~= "number" or maxRank <= 0) then maxRank = nil end
        return "learned", rank, maxRank, nil, "current"
    end
    -- The reader gave no current skill (it leaves out a line with a hidden
    -- value). The list itself says whether the profession is there.
    local says, lineRank, lineMax = ListSays(prof)
    if says == "rank" then
        -- (a line the reader left out for another hidden value: its skill
        -- is read now all the same, and kept as the one seen last)
        if ns.ProfessionRankSeen then pcall(ns.ProfessionRankSeen, prof, lineRank) end
        return "learned", lineRank, lineMax, nil, "current"
    end
    if says == "absent" then return "unlearned" end
    -- its skill cannot be read now: the one seen last, said to be that
    if rank ~= nil and not ns.AnySecret("skill plan skill", rank) and type(rank) == "number" then
        if seenAt ~= nil and (ns.AnySecret("skill plan skill", seenAt) or type(seenAt) ~= "number") then seenAt = nil end
        return "learned", rank, nil, nil, "lastSeen", seenAt
    end
    -- the profession is there with an unreadable skill: "unknown", never "not learned"
    if says == "hidden" then return "unknown", nil, nil, "rank" end
    return "unknown"
end
ns.SkillPlanSkillState = SkillState

-- The target: kept per character and profession. The default (the next rank
-- end above your skill) is set once, when a profession's plan is first
-- opened, or when you ask for it again.
local function Targets()
    ns.db.planTargets = ns.db.planTargets or {}
    local key = CharKey()
    ns.db.planTargets[key] = ns.db.planTargets[key] or {}
    return ns.db.planTargets[key]
end
local function DefaultTarget(skill)
    for _, cap in ipairs(CAPS) do
        if cap > skill then return cap end
    end
    return CAPS[#CAPS]
end
local function TargetFor(prof, skill)
    local t = Targets()[prof]
    if type(t) ~= "number" then
        t = DefaultTarget(skill)
        Targets()[prof] = t
    end
    return t
end
-- value: a number or text from the menu; nil or "": back to the default.
-- true, or false and what to tell the player
local function SetTarget(prof, value, skill)
    if value == nil or value == "" then
        Targets()[prof] = DefaultTarget(skill)
        return true
    end
    local n = tonumber(value)
    if not n or n ~= math.floor(n) or n < 1 or n > CAPS[#CAPS] then
        return false, (L["Enter a whole number from %d to %d."]):format(1, CAPS[#CAPS])
    end
    if n <= skill then
        return false, (L["Your skill is already %d: choose a higher target."]):format(skill)
    end
    Targets()[prof] = n
    return true
end
ns.SkillPlanSetTarget = function(value)
    if not state.prof then return false end
    local ok, hint = SetTarget(state.prof, value, state.skill or 1)
    state.hint = hint
    TryAgain()
    if ns.RefreshSkillPlan then ns.RefreshSkillPlan() end
    return ok, hint
end
-- What the open window plans: the profession and its target (nil while it
-- is closed or shows no plan). 1 and the highest target there is.
ns.SkillPlanShown = function()
    if not WindowShown() or not state.prof or not state.skill then return nil end
    return state.prof, TargetFor(state.prof, state.skill)
end
ns.SkillPlanTargetRange = function() return 1, CAPS[#CAPS] end

-- when the bank was last opened on this character (for the tooltip)
local bankWatch = CreateFrame("Frame")
pcall(bankWatch.RegisterEvent, bankWatch, "BANKFRAME_OPENED")
bankWatch:SetScript("OnEvent", function()
    if not ns.db then return end
    ns.db.planBankSeen = ns.db.planBankSeen or {}
    ns.db.planBankSeen[CharKey()] = time()
end)

local function Ago(seconds)
    local mins = math.floor(seconds / 60)
    return mins < 1 and L["just now"] or mins < 60 and (mins .. L[" min ago"])
        or mins < 2880 and (math.floor(mins / 60) .. L[" h ago"]) or (math.floor(mins / 1440) .. L[" days ago"])
end

-- what the window shows: the plan it was drawn with (its profession, skill
-- and target), and whether it has rows of places (R3 B-M1)
local shown

-- where a recipe item is sold: the nearest vendor (Places.lua, from
-- Data/RecipeSources.lua), else the first as before
local function VendorOf(recipe)
    if shown then shown.places = true end
    return recipe.recipeItem and ns.PlacesVendor and ns.PlacesVendor(recipe.recipeItem) or nil
end

-- the nearest trainer (Places.lua, Data/Trainers.lua): its text, worked out
-- when the window is drawn; the tooltip and the click only use it
local function TrainerPlace(prof, need)
    if shown then shown.places = true end
    local t = ns.PlacesTrainer and ns.PlacesTrainer(prof, need)
    if not t then return nil end
    local text = ((t.far and L["Trainer on another continent: %s (%s)"] or L["Nearest trainer: %s (%s)"])):format(t.name, ns.GetZoneName(t.mapID))
    return { place = t, text = text, zone = ns.GetZoneName(t.mapID) }
end
local function PlaceTip(tt, p)
    tt:AddLine(p.text, 0.9, 0.9, 0.9, true)
    if p.place.unsure then tt:AddLine(L["May not teach this rank."], 1, 0.5, 0.4, true) end
    tt:AddLine(L["Place from the Questie database: the NPC may not be there right now."], 0.6, 0.6, 0.6, true)
    tt:AddLine(L["Click: set a waypoint."], 0.6, 0.6, 0.6, true)
end
local function PlaceClick(p)
    return function()
        if ns.SetWaypoint and ns.SetWaypoint(p.place.mapID, p.place.x, p.place.y) then
            ns.Print((L["Waypoint set: %s (%s)."]):format(p.place.name, p.zone))
        end
    end
end

local function Row(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, content)
    row:SetSize(500, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row.check = row:CreateTexture(nil, "ARTWORK")
    row.check:SetSize(14, 14)
    row.check:SetPoint("LEFT", 2, 0)
    row.check:SetTexture(TICK)
    row.check:Hide()
    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", 4, 0)
    row.left:SetWidth(300)
    row.left:SetJustifyH("LEFT")
    row.left:SetWordWrap(false)
    row.mid = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.mid:SetPoint("LEFT", 196, 0)
    row.mid:SetWidth(84)
    row.mid:SetJustifyH("RIGHT")
    row.mid:SetWordWrap(false)
    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", -64, 0)
    row.right:SetWidth(150)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWordWrap(false)
    row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.button:SetSize(58, 16)
    row.button:SetPoint("RIGHT", -2, 0)
    ns.LText(row.button, "Farm")
    row.button:Hide()
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self.tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        self.tip(GameTooltip)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    row:SetScript("OnMouseUp", function(self)
        if self.click then self.click() end
    end)
    rows[i] = row
    return row
end

local function Percent(p) return math.floor(p * 100 + 0.5) .. " %" end
local function ChanceText(s)
    if s.chanceUnknown then return L["chance unknown"] end
    local a, b = Percent(s.chanceFrom), Percent(s.chanceTo)
    if a == b then return a end
    return math.floor(s.chanceFrom * 100 + 0.5) .. "-" .. b
end
-- "24x" when it is certain, "~31x (24-40)" with the model's range
local function CountText(s)
    if s.low == s.high then return (L["%dx"]):format(s.crafts) end
    return "~" .. (L["%dx"]):format(s.crafts) .. (" (%d-%d)"):format(s.low, s.high)
end

-- "Farm for plan" and the list of zones (0.2 B3, PlanFarm.lua): a row of
-- two buttons over the materials, there while a material that has nodes
-- on the map is still open. What the tooltip says is worked out when the
-- window is drawn, not while you point at a button.
local planButtons
local function ShowPlanButtons(prof, target, y)
    if not (ns.PlanButtonInfo and ns.PlanFarmStart and ns.PlanZoneListShow) then return 0 end
    local info = ns.PlanButtonInfo(prof, target)
    if not info.show then return 0 end
    if not planButtons then
        planButtons = CreateFrame("Frame", "GathercraftSkillPlanFarm", content)
        planButtons:SetSize(500, 26)
        local farm = CreateFrame("Button", nil, planButtons, "UIPanelButtonTemplate")
        farm:SetSize(170, 22)
        farm:SetPoint("LEFT", 4, 0)
        farm:SetScript("OnClick", function() ns.PlanFarmStart(planButtons.prof, planButtons.target) end)
        farm:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            for i, line in ipairs(ns.PlanButtonTooltip(planButtons.info)) do
                GameTooltip:AddLine(line[1], line[2], line[3], line[4], i == 2)
            end
            GameTooltip:Show()
        end)
        farm:SetScript("OnLeave", GameTooltip_Hide)
        local zones = CreateFrame("Button", nil, planButtons, "UIPanelButtonTemplate")
        zones:SetSize(170, 22)
        zones:SetPoint("LEFT", farm, "RIGHT", 8, 0)
        zones:SetScript("OnClick", function() ns.PlanZoneListShow(planButtons.prof, planButtons.target) end)
        zones:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(L["Where to farm"], 1, 0.82, 0)
            GameTooltip:AddLine(L["The zones of this continent with known spots for what your plan still needs."], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        zones:SetScript("OnLeave", GameTooltip_Hide)
        planButtons.farm, planButtons.zones = farm, zones
    end
    planButtons.farm:SetText(L["Farm for plan"])
    planButtons.zones:SetText(L["Where to farm"])
    planButtons.prof, planButtons.target, planButtons.info = prof, target, info
    planButtons:ClearAllPoints()
    planButtons:SetPoint("TOPLEFT", 0, -y)
    planButtons:Show()
    return 26
end

local haveSaid = {} -- item -> the last debug line about its count
-- keep: what the window showed - drawn again with it, the plan not asked for
-- again (where you are changed, R3 B-M1); nil: the plan of the state as it is
local function Draw(keep)
    shown = nil
    if not (win and win:IsShown() and Data()) then return end
    if planButtons then planButtons:Hide() end
    local d = Data()
    local prof = state.prof
    if targetMenu and not keep then targetMenu:Hide() end -- (you walk while choosing a target: it stays open)
    -- rows one below the other; a line without a right column (hints, notes)
    -- takes the whole width and wraps, so long translations and big amounts
    -- are not cut off: its row grows with the text
    local n, y = 0, 0
    local function Line(left, right, color)
        n = n + 1
        local row = Row(n)
        local wide = right == nil
        row.left:ClearAllPoints()
        row.left:SetPoint("LEFT", 4, 0)
        row.left:SetWidth(wide and WIDE_W or 300)
        row.left:SetWordWrap(wide)
        row.left:SetText(left)
        row.right:SetText(right or "")
        row.mid:ClearAllPoints()
        row.mid:SetPoint("LEFT", 196, 0)
        row.mid:SetWidth(84)
        row.mid:SetText("")
        row.check:Hide()
        row.left:SetTextColor(unpack(color or WHITE))
        row.button:Hide()
        row.tip, row.click = nil, nil
        local h = ROW_H
        if wide then h = math.max(ROW_H, math.ceil((row.left:GetStringHeight() or 0) + 6)) end
        row:SetHeight(h)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        y = y + h
        row:Show()
        return row
    end
    local function Finish(total, note)
        for i = n + 1, #rows do rows[i]:Hide() end
        content:SetHeight(math.max(1, y))
        totalText:SetText(total or "")
        noteText:SetText(state.hint and ("|cffff7070" .. state.hint .. "|r") or note or "")
    end

    -- no single profession chosen: say so, no plan of some other one
    if not prof then
        profText:SetText("")
        skillText:SetText("")
        targetLabel:Hide()
        targetButton:Hide()
        DropJob()
        Line(L["Choose a profession first."], nil, GOLD)
        Line(L["Pick one profession on the Crafting tab, then click Skill plan."], nil, GREY)
        Finish()
        return
    end
    profText:SetText(d.ProfLabel(prof))
    local skillState, rank, maxRank, _, skillSource, seenAt = SkillState(prof)
    local lastSeen = skillState == "learned" and skillSource == "lastSeen"
    if skillState == "unknown" then
        -- not readable is not "1": no plan from a guess
        state.skill = nil
        skillText:SetText(L["Your skill: ? (open your profession window once)"])
        targetLabel:Hide()
        targetButton:Hide()
        DropJob()
        Line(L["Your skill could not be read, so there is no plan yet."], nil, RED)
        Finish()
        return
    end
    local from = skillState == "learned" and rank or 1
    state.skill = from
    local target = TargetFor(prof, from)
    targetLabel:Show()
    targetButton:Show()
    targetButton:SetText(tostring(target))
    if skillState == "unlearned" then
        skillText:SetText(L["Not learned yet"])
    elseif lastSeen then
        skillText:SetText((L["Skill last seen: %d"]):format(rank)) -- never "Your skill: ..."
    else
        skillText:SetText(maxRank and (L["Your skill: %d / %d"]):format(rank, maxRank) or (L["Your skill: %d"]):format(rank))
    end

    local plan, updating, broken
    if keep and keep.prof == prof and keep.from == from and keep.target == target and keep.lastSeen == lastSeen then
        plan, updating, broken = keep.plan, keep.updating, keep.broken
    else
        plan, updating, broken = PlanToShow(prof, from, target, lastSeen and "lastSeen" or nil, seenAt)
    end
    shown = { prof = prof, from = from, target = target, lastSeen = lastSeen, plan = plan, updating = updating, broken = broken }
    -- The calculation broke (Codex round 3): the window is drawn first - no
    -- "Updating" and no "Working out" stays behind, a line says what happened
    -- - and then the error is raised, once, so it is reported like any other.
    local function Report()
        if broken and not broken.reported then
            broken.reported = true
            error(broken.err, 0)
        end
    end
    if not plan then
        if broken then
            Line(L["The plan could not be worked out: an error occurred."], nil, RED)
        else
            -- being worked out, and no finished plan of this profession to
            -- show meanwhile: nothing of a plan, only that it is on its way
            Line(L["Working out the plan ..."], nil, GOLD)
        end
        Finish()
        Report()
        return
    end
    if not plan.valid then
        Line(L["No plan: there is nothing to plan from."], nil, RED)
        Finish()
        Report()
        return
    end
    local info = plan.learn
    -- the plan of before, while the new one is worked out - or after it
    -- could not be: said first
    if broken then
        Line(L["The plan could not be worked out: an error occurred."], nil, RED)
    elseif updating then
        Line(L["Updating the plan ..."], nil, GOLD)
    end
    -- (what marks a preview goes by the plan that is shown)
    local preview = plan.skillSource == "lastSeen"

    if skillState == "unlearned" then
        Line(L["Not learned yet - learn it from a trainer. This is a preview from skill 1."], nil, GOLD)
    elseif lastSeen then
        -- how old the skill is, and what makes it current again
        local age = seenAt and (time() - seenAt) or nil
        Line((age and age >= 0) and (L["Your skill cannot be read right now. This is a preview from the skill seen last (%s): open your profession window to update it."]):format(Ago(age))
            or L["Your skill cannot be read right now. This is a preview from the skill seen last: open your profession window to update it."], nil, GOLD)
    end
    -- another profession the plan makes something with, by a skill that was
    -- only seen last
    local otherSeen = plan.lastSeenProfessions or {}
    for _, other in ipairs(otherSeen) do
        Line((L["Your %s skill cannot be read right now. The plan makes materials with it, going by the skill seen last: until it can be read, this is a preview."]):format(d.ProfLabel(other)), nil, GOLD)
    end
    Line(L["Steps"], nil, GOLD)
    if prof == "Mining" then
        Line(L["Mining also rises when you mine veins: a farm run for ore often does both."], nil, GREY)
    end
    -- training the next rank: a row of its own, where it has to happen
    local trainAt = {}
    for _, t in ipairs(plan.training) do trainAt[t.at] = t end
    local function Train(at)
        local t = trainAt[at]
        if not t then return end
        trainAt[at] = nil
        local row = Line(t.assumed and (L["Train the next rank at your trainer (at ~%d, cap assumed)."]):format(at)
            or (L["Train the next rank at your trainer (needed at %d)."]):format(at), nil, GOLD)
        -- where: the nearest trainer who can teach the next rank
        local p = TrainerPlace(prof, ns.PlacesRankAfter(at))
        if p then
            local sub = Line("    " .. p.text .. (p.place.unsure and ("  |cffff7070" .. L["May not teach this rank."] .. "|r") or ""), nil, GREY)
            for _, r in ipairs({ row, sub }) do
                r.tip = function(tt) PlaceTip(tt, p) end
                r.click = PlaceClick(p)
            end
        end
    end
    local gaps = false
    for _, s in ipairs(plan.steps) do
        local r = s.recipe
        Train(s.from)
        local tag = ""
        if s.forMaterials then tag = "  |cff999999" .. L["(for materials)"] .. "|r"
        elseif r.how == "trainer" then tag = "  |cff999999" .. L["(trainer)"] .. "|r"
        elseif r.how == "vendor" then tag = "  |cff999999" .. L["(buy the recipe)"] .. "|r" end
        local row
        if s.chanceUnknown then
            row = Line(("%d+  %s%s"):format(s.from, r.name, tag), "|cffff7070" .. L["chance unknown"] .. "|r")
        else
            local colour = s.chanceFrom >= 1 and "|cffff8040" or "|cffffff00"
            gaps = gaps or s.comparable == false
            row = Line(("%d-%d  %s%s|r%s"):format(s.from, s.to, colour, r.name, tag),
                ("|cff999999%s|r  %s%s"):format(ChanceText(s), CountText(s), s.comparable == false and " ?" or ""))
        end
        row.tip = function(tt)
            tt:AddLine(r.name, 1, 1, 1)
            if s.chanceUnknown then
                tt:AddLine(L["Chance unknown: this recipe has no colour data, so it is not counted."], 1, 0.5, 0.4, true)
                return
            end
            tt:AddLine((L["Chance for a skill point per craft: %s"]):format(ChanceText(s)), 1, 0.82, 0.3, true)
            if s.low ~= s.high then
                tt:AddLine((L["About %d crafts on average; in 8 of 10 cases between %d and %d."]):format(s.crafts, s.low, s.high), 0.9, 0.9, 0.9, true)
                tt:AddLine(L["A range of the model, not a guarantee."], 0.6, 0.6, 0.6, true)
            end
            if s.outputAssumed then
                tt:AddLine(L["Counted with the average output per craft - what a craft really makes varies."], 0.7, 0.7, 0.7, true)
            end
            if s.forMaterials then
                tt:AddLine(L["Made for materials the plan needs - each craft can give a skill point too."], 0.9, 0.9, 0.9, true)
            elseif s.why then
                tt:AddLine(" ")
                tt:AddLine((L["Why this recipe: about %s per skill point on top of what you have."]):format(ns.Money(math.max(0, s.why.score - 1))), 0.9, 0.9, 0.9, true)
                if s.why.other then
                    tt:AddLine((L["Next best: %s, about %s per skill point."]):format(s.why.other.name, ns.Money(math.max(0, s.why.other.score - 1))), 0.7, 0.7, 0.7, true)
                end
                if s.comparable == false or (s.why.other and s.why.other.comparable == false) then
                    tt:AddLine(L["Not fully comparable: a part of the cost is unknown."], 1, 0.5, 0.4, true)
                elseif s.estimated then
                    tt:AddLine(L["Counted with an estimated price."], 0.7, 0.7, 0.7, true)
                end
            end
        end
    end
    if plan.steps[#plan.steps] and not plan.steps[#plan.steps].chanceUnknown then Train(plan.steps[#plan.steps].to) end
    for at in pairs(trainAt) do Train(at) end -- (at your maximum with nothing planned after it)
    if gaps then Line(L["? = a part of the cost is unknown: this choice is not fully comparable."], nil, DIM) end
    -- what the plan says about itself
    for _, diag in ipairs(plan.diagnostics) do
        if diag.code == "stuck" and prof == "Mining" then
            Line((L["From %d on: mine veins to go up (farm run for ore)."]):format(diag.skill), nil, RED)
        elseif diag.code == "stuck" then
            Line((L["No recipe found for skill %d: visit your trainer, the plan goes on from there."]):format(diag.skill), nil, RED)
        elseif diag.code == "cycle" then
            Line((L["%s can only be made from itself here: it is not made."]):format(ItemName(diag.item)), nil, RED)
        end
    end
    -- (only a plan from the skill read now is ever "done" - and only the
    -- plan of the state as it is: not the one of before while a new one is
    -- worked out)
    if plan.status == "done" and not updating and not broken then
        Line((L["Done: you have reached your target (%d)."]):format(plan.target), nil, GREEN)
    end
    -- the recipes to learn, with where
    if #info.list > 0 then
        Line(" ")
        Line(L["Recipes to learn"], nil, GOLD)
        for _, entry in ipairs(info.list) do
            local r = entry.recipe
            local row
            if entry.how == "trainer" then
                row = Line(r.name, ("%s  %s"):format((L["%s trainer"]):format(d.ProfLabel(prof)),
                    entry.cost and ns.Money(entry.cost) or ("|cffff7070" .. L["fee unknown"] .. "|r")))
                local p = TrainerPlace(prof, ns.PlacesRankOf(r.req or 1))
                if p then
                    row.tip = function(tt)
                        tt:AddLine(r.name, 1, 1, 1)
                        PlaceTip(tt, p)
                    end
                    row.click = PlaceClick(p)
                end
            else
                local vendor = VendorOf(r)
                local vendorZone = vendor and vendor.mapID and ns.GetZoneName(vendor.mapID)
                local cost = entry.cost and ns.Money(entry.cost) or L["|cffff7070no price|r"]
                row = Line(r.name, ("%s  %s"):format(vendor and vendor.name or L["vendor"], cost))
                row.tip = function(tt)
                    tt:AddLine(r.name, 1, 1, 1)
                    if vendor and vendor.mapID then
                        tt:AddLine((L["Sold by %s (%s)."]):format(vendor.name, vendorZone), 0.9, 0.9, 0.9, true)
                        tt:AddLine(L["Place from the Questie database: the NPC may not be there right now."], 0.6, 0.6, 0.6, true)
                        tt:AddLine(L["Click: set a waypoint."], 0.6, 0.6, 0.6, true)
                    elseif vendor then
                        tt:AddLine((L["Sold by %s (%s)."]):format(vendor.name, L["place unknown"]), 0.9, 0.9, 0.9, true)
                    else
                        tt:AddLine(L["Sold by a vendor; which one is not known."], 0.9, 0.9, 0.9, true)
                    end
                end
                if vendor and vendor.mapID then
                    row.click = function()
                        if ns.SetWaypoint and ns.SetWaypoint(vendor.mapID, vendor.x, vendor.y) then
                            ns.Print((L["Waypoint set: %s (%s)."]):format(vendor.name, vendorZone))
                        end
                    end
                end
            end
        end
        if info.trainer > 0 then
            Line((L["Trainer fees for new recipes: %s"]):format(ns.Money(info.fees))
                .. (info.feesUnknown > 0 and ("  |cffff7070" .. (L["(+%d without a known fee)"]):format(info.feesUnknown) .. "|r") or ""),
                nil, GREY)
        end
        if info.items > 0 then
            local text = (L["Recipes to buy from a vendor: %d"]):format(info.items)
            if info.itemCost > 0 then text = text .. "  " .. (L["about %s"]):format(ns.Money(info.itemCost)) end
            if info.itemsUnknown > 0 then text = text .. "  |cffff7070" .. (L["(+%d without a price)"]):format(info.itemsUnknown) .. "|r" end
            Line(text, nil, GREY)
        end
    end

    -- the materials: have / need, what is missing, where it comes from, what it costs
    Line(" ")
    local head = Line(L["Materials"], L["missing"], GOLD)
    -- the column's head may be longer than the numbers below it ("tienes /
    -- necesitas"): it ends where they end and grows to the left
    head.left:SetWidth(130)
    head.mid:ClearAllPoints()
    head.mid:SetPoint("RIGHT", head, "LEFT", 280, 0)
    head.mid:SetWidth(140)
    head.mid:SetText("|cff999999" .. L["have / need"] .. "|r")
    if preview then
        Line(L["Preview - the amounts below are for the skill seen last, not for your skill now."], nil, GOLD)
    end
    -- (not while a new plan is on its way, not for a preview: nothing to farm by)
    if not updating and not preview then y = y + ShowPlanButtons(prof, target, y) end
    local unread = false
    -- the amounts are a planning estimate where a step's number of crafts is
    -- a mean, a varying output was counted with its mean, or extra crafts
    -- could give skill points that are not counted: said in every material's
    -- tooltip and in a line under the list
    local isEstimate = plan.estimate and (plan.estimate.crafts or plan.estimate.output or plan.estimate.skill) or false
    for _, m in ipairs(plan.materials) do
        local name = ItemName(m.id)
        -- /gcr debug: where the count comes from (once, and again when it changes)
        if ns.db.debug and d.HaveParts then
            local okP, total, bags, reagent, bank = pcall(d.HaveParts, m.id)
            if okP then
                local text = ("PLAN have %s: bags %s, reagent bag %s, bank %s, total %d"):format(name,
                    tostring(bags or "?"), tostring(reagent or "?"), tostring(bank or "?"), total)
                if haveSaid[m.id] ~= text then
                    haveSaid[m.id] = text
                    ns.Debug(text)
                end
            end
        end
        local right
        if m.covered then
            right = "|cff55ff55" .. L["enough"] .. "|r" -- only what you really have ticks a row
        elseif m.missing == 0 and m.madeFrom then
            right = "|cff999999" .. (L["(make it: %s)"]):format(d.ProfLabel(m.madeFrom.prof)) .. "|r"
        elseif m.missing == 0 then
            right = "|cff999999" .. L["(from the plan's steps)"] .. "|r" -- a forecast, not stock
        else
            -- to buy (a part of it may be made as well: the tooltip says so)
            local source = m.price.status == "unknown" and "" or (m.price.source == "vendor" and L["vendor"] or L["AH"])
            right = ("|cffff7070%d|r  |cff999999%s|r %s%s"):format(m.missing, source, m.costStatus == "estimated" and "~" or "",
                m.cost and ns.Money(m.cost) or L["|cffff7070no price|r"])
        end
        local row = Line(name, right, m.covered and GREEN or WHITE)
        row.left:ClearAllPoints()
        row.left:SetPoint("LEFT", 20, 0)
        row.left:SetWidth(176)
        row.check:SetShown(m.covered and true or false)
        if not m.haveKnown then unread = true end
        row.mid:SetText(("%s%s / %d|r"):format(m.covered and "|cff55ff55" or "|cffcccccc", m.haveKnown and tostring(m.have) or "?", m.need))
        row.tip = function(tt)
            tt:AddLine(name, 1, 1, 1)
            if not m.haveKnown then
                tt:AddLine(L["How many you have could not be read."], 1, 0.5, 0.4, true)
                tt:AddLine(L["What is missing is counted as if you had none."], 0.9, 0.9, 0.9, true)
            else
                tt:AddLine((L["You have %d of the %d the plan needs."]):format(m.have, m.need), 0.9, 0.9, 0.9, true)
                local okP, _, bags, reagent, bank = pcall(d.HaveParts or function() end, m.id)
                if okP and bags and not ns.AnySecret("skill plan parts", bags, reagent, bank) then
                    tt:AddLine((L["Bags %d, reagent bag %d, bank %d."]):format(bags, reagent or 0, bank or 0), 0.7, 0.7, 0.7, true)
                    local seen = ns.db.planBankSeen and ns.db.planBankSeen[CharKey()]
                    tt:AddLine(seen and (L["Bank as the game counts it; last opened %s."]):format(Ago(time() - seen))
                        or L["Bank as the game counts it; not opened yet on this character."], 0.6, 0.6, 0.6, true)
                    if (bank or 0) > 0 then tt:AddLine(L["What is in the bank has to be fetched before you can craft with it."], 0.6, 0.6, 0.6, true) end
                end
            end
            if m.planned > 0 then
                tt:AddLine((L["The plan's own steps will make %d - a forecast, not stock."]):format(m.planned), 0.7, 0.7, 0.7, true)
            end
            if m.madeFrom then
                tt:AddLine((L["The rest you make yourself (%s)."]):format(d.ProfLabel(m.madeFrom.prof)), 0.7, 0.7, 0.7, true)
            end
            if m.outputAssumed then
                tt:AddLine(L["Counted with the average output per craft - what a craft really makes varies."], 0.7, 0.7, 0.7, true)
            end
            if isEstimate then
                tt:AddLine(L["Planning estimate from the average number of crafts per step - what you really need varies."], 0.6, 0.6, 0.6, true)
            end
            if m.missing > 0 then
                if m.price.status == "unknown" then
                    tt:AddLine(L["No price known: its cost is not in the sum."], 1, 0.5, 0.4, true)
                else
                    local source = tostring(m.price.source or "?")
                    if m.price.age then source = source .. ", " .. Ago(m.price.age) end
                    tt:AddLine((L["Price: %s each (%s)."]):format(ns.Money(m.price.copper), source)
                        .. (m.price.status == "estimated" and (" " .. L["An estimate."]) or ""), 0.7, 0.7, 0.7, true)
                end
            end
        end
        if m.node and m.missing > 0 then
            row.button:Show()
            row.button:SetScript("OnClick", function()
                -- every node that gives the item, in any client language
                ns.StartRun("item:" .. m.id)
            end)
            row.button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine((L["Farm run for %s"]):format(name), 1, 1, 1)
                GameTooltip:Show()
            end)
            row.button:SetScript("OnLeave", GameTooltip_Hide)
        end
    end
    if unread then Line(L["? in have / need: that count could not be read."], nil, DIM) end
    if isEstimate then
        Line(L["Planning estimate from the average number of crafts per step - what you really need varies."], nil, DIM)
    end
    -- What the plan does not check (concept 4.7, as Sven set it for building
    -- block 1 on 10.11.2026): a forge, an anvil, a cooldown - like
    -- reputation or character level - are not in the shipped data. Nothing
    -- is made up for them; one line says so. Tools are not listed at all.
    if #plan.steps > 0 then
        Line(L["Some recipes also need a tool, a forge or an anvil, or have a cooldown - the plan does not check that."], nil, DIM)
    end

    -- the sum: what is known, what of it is only estimated, and how many
    -- materials have no price at all - those count as unknown, never as 0
    local cost, total, unknownCount = plan.cost, plan.total, #plan.cost.unknownItems
    local estimated = cost.estimated > 0 and ("  |cff999999" .. (L["(%s of it estimated)"]):format(ns.Money(cost.estimated)) .. "|r") or ""
    local totalLine
    if unknownCount > 0 and total == 0 then
        totalLine = (L["Missing materials cost: unknown (%d without a price)"]):format(unknownCount)
    elseif unknownCount > 0 then
        totalLine = (L["Missing materials cost about %s"]):format(ns.Money(total)) .. estimated .. "  |cffff7070"
            .. (L["(+%d without a price)"]):format(unknownCount) .. "|r"
    else
        totalLine = (L["Missing materials cost about %s"]):format(ns.Money(total)) .. estimated
    end
    -- what the sum rests on, in the line below it: a count that could not be
    -- read is counted as none (what to buy and the sum may then be too high);
    -- else a choice that is not fully comparable: what is open, and what helps
    local note = ""
    local assumed = plan.cost.assumedItems and #plan.cost.assumedItems or 0
    if preview then
        -- first of all: the sum is that of a preview (the sum line itself
        -- has no room for it in most languages)
        note = L["A preview from the skill seen last, not from your skill now."]
    elseif #otherSeen > 0 then
        note = L["A preview: it uses a profession whose skill cannot be read right now."]
    elseif assumed > 0 then
        note = (L["Counted as if you had none of the %d marked ?: the sum may be too high."]):format(assumed)
    elseif plan.notComparable then
        note = (plan.openLearn and not plan.openPrices) and L["A learning cost is unknown: your trainer or the vendor shows it."]
            or L["Some prices are unknown: scan the auction house for a better plan."]
    end
    Finish(totalLine, note)
    Report()
end
local function Refresh() Draw() end
ns.RefreshSkillPlan = Refresh
-- Where you are changed while the window is open (a zone change, a longer
-- way, another faction: Places.lua): its rows of trainers and vendors are
-- drawn again - text, tooltip and click - with the plan it shows. Nothing is
-- worked out because you move (R3 B-M1).
local PLACES_LOOK = 1 -- seconds between two looks
local function PlacesAgain()
    if shown and shown.places and ns.PlacesStale and ns.PlacesStale() then Draw(shown) end
end

local function Build()
    win = ns.MakeCard("GathercraftSkillPlan", 560, 520)
    ns.LText(win.title, "Skill plan")

    -- the profession: a label, no switch (Mining shows as Smelting)
    profText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    profText:SetPoint("TOPLEFT", 26, -65)
    profText:SetWidth(150)
    profText:SetJustifyH("LEFT")
    profText:SetWordWrap(false)

    skillText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    skillText:SetPoint("TOPLEFT", 182, -66)
    skillText:SetWidth(200)
    skillText:SetJustifyH("LEFT")
    skillText:SetWordWrap(false)

    targetLabel = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetLabel:SetPoint("TOPRIGHT", -112, -66)
    targetLabel:SetWidth(90)
    targetLabel:SetJustifyH("RIGHT")
    targetLabel:SetWordWrap(false)
    ns.LText(targetLabel, "Target")

    -- the target: a button that opens a small menu. Plain frames and
    -- buttons only - nothing of a menu system this client may not have.
    targetButton = CreateFrame("Button", "GathercraftSkillPlanTarget", win, "UIPanelButtonTemplate")
    targetButton:SetSize(64, 20)
    targetButton:SetPoint("TOPRIGHT", -40, -62)
    targetMenu = CreateFrame("Frame", "GathercraftSkillPlanTargetMenu", win, "BackdropTemplate")
    targetMenu:SetSize(150, 6 * 22 + 34)
    targetMenu:SetPoint("TOPRIGHT", targetButton, "BOTTOMRIGHT", 0, -2)
    targetMenu:SetFrameStrata("FULLSCREEN_DIALOG")
    if targetMenu.SetBackdrop then
        targetMenu:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    end
    targetMenu:Hide()
    targetMenu.items = {}
    local function Item(i, label, value)
        local b = CreateFrame("Button", nil, targetMenu, "UIPanelButtonTemplate")
        b:SetSize(138, 20)
        b:SetPoint("TOP", 0, -6 - (i - 1) * 22)
        if type(label) == "number" then b:SetText(tostring(label)) else ns.LText(b, label) end
        b.value = value
        b:SetScript("OnClick", function()
            targetMenu:Hide()
            ns.SkillPlanSetTarget(value)
        end)
        targetMenu.items[i] = b
        return b
    end
    for i, cap in ipairs(CAPS) do Item(i, cap, cap) end
    Item(#CAPS + 1, "Default", nil)
    -- a value of your own: type it, Enter
    local customLabel = targetMenu:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    customLabel:SetPoint("TOPLEFT", 8, -8 - (#CAPS + 1) * 22)
    customLabel:SetWidth(134)
    customLabel:SetJustifyH("LEFT")
    customLabel:SetWordWrap(false)
    ns.LText(customLabel, "Custom value")
    targetEdit = CreateFrame("EditBox", "GathercraftSkillPlanTargetEdit", targetMenu, "InputBoxTemplate")
    targetEdit:SetSize(60, 18)
    targetEdit:SetPoint("TOPLEFT", 12, -24 - (#CAPS + 1) * 22)
    targetEdit:SetAutoFocus(false)
    targetEdit:SetMaxLetters(3)
    targetEdit:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        self:ClearFocus()
        targetMenu:Hide()
        ns.SkillPlanSetTarget(text)
    end)
    targetEdit:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        targetMenu:Hide()
    end)
    targetButton:SetScript("OnClick", function()
        if targetMenu:IsShown() then
            targetMenu:Hide()
        else
            targetEdit:SetText("")
            targetMenu:Show()
        end
    end)

    local scroll = CreateFrame("ScrollFrame", "GathercraftSkillPlanScroll", win, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 22, -94)
    scroll:SetPoint("BOTTOMRIGHT", -40, 66)
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(500, 10)
    scroll:SetScrollChild(content)

    totalText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    totalText:SetPoint("BOTTOMLEFT", 24, 42)
    totalText:SetWidth(512) -- one line inside the card, whatever the language
    totalText:SetJustifyH("LEFT")
    totalText:SetWordWrap(false)
    noteText = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    noteText:SetPoint("BOTTOMLEFT", 24, 24)
    noteText:SetWidth(500)
    noteText:SetJustifyH("LEFT")
    win:SetScript("OnShow", Refresh)
    -- closed: the window no longer decides what is planned - a plan run or
    -- the list of zones it held up reads its own plan again at once, not
    -- only with the next bag event or step (0.2 B3 R1-M2)
    win:HookScript("OnHide", function()
        if runnerOn and ns.PlanReadersWake then ns.PlanReadersWake() end
    end)
    -- what the plan read can change while it is open (loot, crafting, the
    -- bank, a skill point, a new recipe): looked at again, once for a burst
    -- of events - and calculated again only when something really changed.
    -- Events this client doesn't know are left out. Closed: nothing.
    local pending
    win:SetScript("OnEvent", function()
        if pending or not win:IsShown() then return end
        pending = true
        C_Timer.After(0.2, function()
            pending = false
            Refresh()
        end)
    end)
    for _, e in ipairs({ "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
        "PLAYERBANKSLOTS_CHANGED", "PLAYERREAGENTBANKSLOTS_CHANGED",
        "SKILL_LINES_CHANGED", "NEW_RECIPE_LEARNED", "TRADE_SKILL_LIST_UPDATE" }) do
        pcall(win.RegisterEvent, win, e)
    end
    -- where you are can change too: looked at once a second while it is open
    -- (only shown frames are updated) - its rows of places, never the plan
    local sinceLook = 0
    win:SetScript("OnUpdate", function(_, elapsed)
        sinceLook = sinceLook + (elapsed or 0)
        if sinceLook < PLACES_LOOK then return end
        sinceLook = 0
        PlacesAgain()
    end)
end

-- Opens the plan of ONE profession: the one named, else the one chosen on
-- the Crafting tab. None (the tab shows your own or all): the window says
-- "Choose a profession first." - never a plan of some other profession.
local function ShowSkillPlan(prof)
    if not Data() then return end
    if not win then Build() end
    local wanted = prof
    if wanted == nil or wanted == "" then
        wanted = (ns.CraftFilter and ns.CraftFilter()) or (ns.db and ns.db.craftTab) or nil
    end
    local chosen
    if type(wanted) == "string" and wanted ~= "" then
        local key = ns.ProfKey and ns.ProfKey(wanted) or wanted
        for _, p in ipairs(Data().Professions) do
            if p.name:lower() == tostring(key):lower() then chosen = p.name end
        end
    end
    state.prof, state.hint = chosen, nil
    TryAgain()
    -- (showing it refreshes it - OnShow; an open window is refreshed here)
    if win:IsShown() then Refresh() else win:Show() end
    -- another profession in the window: a reader it held up may be free
    -- again (the run's own), or held up now - either way it looks (R1-M2)
    if runnerOn and ns.PlanReadersWake then ns.PlanReadersWake() end
end
ns.ShowSkillPlan = ShowSkillPlan
