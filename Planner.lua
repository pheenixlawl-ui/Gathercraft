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

local function Snapshot(prof, from, to)
    local d = Data()
    local input = { prof = prof, skill = from, target = to, recipes = {}, professions = {} }
    input.recipes[prof] = RecipeList(prof)
    for _, p in ipairs(d.Professions) do
        local rank = ns.ProfessionRank and ns.ProfessionRank(p.name)
        if rank then
            input.professions[p.name] = { rank = rank }
            if p.name ~= prof then input.recipes[p.name] = RecipeList(p.name, true) end
        end
    end
    -- what you have (bags, reagent bag, bank - counted as since 0.1.18, no
    -- parameter guessed): read once per item and plan. A count that cannot
    -- be read (a hidden value, an error, no answer) is "unknown", not 0.
    input.stock = setmetatable({}, { __index = function(t, id)
        local ok, n = pcall(d.Have, id)
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
--                          status, valid, complete, items = { [item] =
--                          { need, have, haveKnown, missing, covered,
--                          planned, make, costStatus } } } - or nil
--   ns.skillPlanListeners  functions called with that result when a new
--                          revision is there (nobody listens yet)
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
    local parts = { input.prof, tostring(input.skill), tostring(input.target), tostring(input.maxRank) }
    local profs = {}
    for prof in pairs(input.recipes) do profs[#profs + 1] = prof end
    table.sort(profs)
    for _, prof in ipairs(profs) do
        local list = {}
        for i, r in ipairs(input.recipes[prof]) do list[i] = RecipeSignature(r) end
        table.sort(list) -- (the same recipes in another order are the same state)
        local own = input.professions[prof]
        parts[#parts + 1] = ("%s:%s:%d:"):format(prof, tostring(own and own.rank), #list) .. table.concat(list, "\030")
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

-- the plan for this state, and whether it is a new one
local function Calculate(prof, skill, target)
    local input = Snapshot(prof, skill, target)
    local sig = Signature(input)
    if calc.plan and calc.sig == sig and SameReads(calc.input, input) then
        return calc.plan, false
    end
    calc.plan = ns.PlanCore.Compute(input)
    calc.input, calc.sig = input, sig
    calc.revision = calc.revision + 1
    calc.plan.revision = calc.revision
    local result = ns.PlanCore.Result(calc.plan)
    result.revision = calc.revision
    calc.result = result
    for _, fn in ipairs(ns.skillPlanListeners) do pcall(fn, result) end
    return calc.plan, true
end
ns.SkillPlanCalculate = Calculate
ns.SkillPlanResult = function() return calc.result end

-- steps, materials, cost of the missing materials, where the plan got stuck,
-- whether stand-in prices were used, and info = { learn costs, missing
-- materials without a price }. The calculation itself is ns.PlanCore.Compute
-- (PlanCore.lua); this takes the snapshot for it.
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

-- Your skill in a profession:
--   "learned", rank, maximum
--   "unlearned"   only with proof: the whole skill list could be read - it
--                 is there, every line readable, no group folded - AND the
--                 profession is not in it
--   "unknown"     everything else. With "rank" as the fourth value when the
--                 profession was FOUND but its skill cannot be read (hidden,
--                 no number): that is never "not learned" (Codex round 1, B5).
-- Every value is checked for being readable before it is compared, counted
-- with or shown.
local function SkillState(prof)
    local ok, rank, maxRank = pcall(ns.ProfessionRank, prof)
    if not ok then return "unknown" end
    if rank ~= nil then
        if ns.AnySecret("skill plan skill", rank) or type(rank) ~= "number" then return "unknown", nil, nil, "rank" end
        if maxRank ~= nil and (ns.AnySecret("skill plan skill", maxRank) or type(maxRank) ~= "number" or maxRank <= 0) then maxRank = nil end
        return "learned", rank, maxRank
    end
    -- The reader found no skill (it leaves out a line with a hidden value).
    -- The list itself says whether the profession is there: line by line,
    -- by the profession each line names.
    if not (GetNumSkillLines and GetSkillLineInfo) then return "unknown" end
    local okN, count = pcall(GetNumSkillLines)
    if not okN or count == nil or ns.AnySecret("skill plan skills", count) or type(count) ~= "number" or count <= 0 then return "unknown" end
    for i = 1, count do
        local okL, name, isHeader, isExpanded, lineRank, _, _, lineMax = pcall(GetSkillLineInfo, i)
        if not okL or name == nil or ns.AnySecret("skill plan skills", name, isHeader, isExpanded) or type(name) ~= "string" then return "unknown" end
        if isHeader and isExpanded == false then return "unknown" end
        if not isHeader and (ns.ProfKey and ns.ProfKey(name) or name) == prof then
            -- the profession is there: its skill, or "unknown" - never "not learned"
            if lineRank == nil or ns.AnySecret("skill plan skill", lineRank) or type(lineRank) ~= "number" then return "unknown", nil, nil, "rank" end
            if lineMax ~= nil and (ns.AnySecret("skill plan skill", lineMax) or type(lineMax) ~= "number" or lineMax <= 0) then lineMax = nil end
            return "learned", lineRank, lineMax
        end
    end
    return "unlearned"
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
    if ns.RefreshSkillPlan then ns.RefreshSkillPlan() end
    return ok, hint
end

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

-- where a recipe item is sold (Data/RecipeSources.lua: vendor, area, place)
local function VendorOf(recipe)
    local src, maps = GathercraftRecipeSources, GathercraftAreaMaps
    local packed = recipe.recipeItem and src and src.items and src.items[recipe.recipeItem]
    if not packed then return end
    local mine = UnitFactionGroup and UnitFactionGroup("player")
    local letter = mine == "Alliance" and "A" or mine == "Horde" and "H" or nil
    local ids = {}
    for list in packed:gmatch("V:([%d,]+)") do
        for id in list:gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
    end
    table.sort(ids)
    local named
    for _, id in ipairs(ids) do
        local npc = src.npcs and src.npcs[id]
        local name, area, friendly, x, y = (npc or ""):match("^([^|]*)|(%d*)|([^|]*)|(%d+)|(%d+)")
        if name and (not letter or friendly == "" or friendly:find(letter, 1, true)) then
            local mapID = maps and area and maps[tonumber(area)]
            if mapID then
                return { name = name, mapID = mapID, x = tonumber(x) / 10000, y = tonumber(y) / 10000 }
            end
            named = named or { name = name }
        end
    end
    return named
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

local haveSaid = {} -- item -> the last debug line about its count
local function Refresh()
    if not (win and win:IsShown() and Data()) then return end
    local d = Data()
    local prof = state.prof
    if targetMenu then targetMenu:Hide() end
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
        Line(L["Choose a profession first."], nil, GOLD)
        Line(L["Pick one profession on the Crafting tab, then click Skill plan."], nil, GREY)
        Finish()
        return
    end
    profText:SetText(d.ProfLabel(prof))
    local skillState, rank, maxRank = SkillState(prof)
    if skillState == "unknown" then
        -- not readable is not "1": no plan from a guess
        state.skill = nil
        skillText:SetText(L["Your skill: ? (open your profession window once)"])
        targetLabel:Hide()
        targetButton:Hide()
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
    else
        skillText:SetText(maxRank and (L["Your skill: %d / %d"]):format(rank, maxRank) or (L["Your skill: %d"]):format(rank))
    end

    local plan = Calculate(prof, from, target)
    if not plan.valid then
        Line(L["No plan: there is nothing to plan from."], nil, RED)
        Finish()
        return
    end
    local info = plan.learn

    if skillState == "unlearned" then
        Line(L["Not learned yet - learn it from a trainer. This is a preview from skill 1."], nil, GOLD)
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
        Line(t.assumed and (L["Train the next rank at your trainer (at ~%d, cap assumed)."]):format(at)
            or (L["Train the next rank at your trainer (needed at %d)."]):format(at), nil, GOLD)
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
    if plan.status == "done" then
        Line((L["Done: you have reached your target (%d)."]):format(target), nil, GREEN)
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
            else
                local vendor = VendorOf(r)
                local cost = entry.cost and ns.Money(entry.cost) or L["|cffff7070no price|r"]
                row = Line(r.name, ("%s  %s"):format(vendor and vendor.name or L["vendor"], cost))
                row.tip = function(tt)
                    tt:AddLine(r.name, 1, 1, 1)
                    if vendor and vendor.mapID then
                        tt:AddLine((L["Sold by %s (%s)."]):format(vendor.name, ns.GetZoneName(vendor.mapID)), 0.9, 0.9, 0.9, true)
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
                            ns.Print((L["Waypoint set: %s (%s)."]):format(vendor.name, ns.GetZoneName(vendor.mapID)))
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
    local unread = false
    -- the amounts are a planning estimate where a step's number of crafts is
    -- a mean or a varying output was counted with its mean: said in every
    -- material's tooltip and in a line under the list
    local isEstimate = plan.estimate and (plan.estimate.crafts or plan.estimate.output) or false
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
    -- a choice that is not fully comparable: what is open, and what helps
    local note = ""
    if plan.notComparable then
        note = (plan.openLearn and not plan.openPrices) and L["A learning cost is unknown: your trainer or the vendor shows it."]
            or L["Some prices are unknown: scan the auction house for a better plan."]
    end
    Finish(totalLine, note)
end
ns.RefreshSkillPlan = Refresh

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
    win:Show()
    Refresh()
end
ns.ShowSkillPlan = ShowSkillPlan
