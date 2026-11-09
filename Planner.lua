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
--   * the material list: what you need, what you have (bags and bank), what
--     is missing and what that costs; bars and bolts you can make yourself
--     (profession learned, recipe known, skill high enough) are broken down
--     into ore and cloth, all others are bought; herbs and ore you can
--     gather get a button that starts a farm run for them
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
            local spell = spells[key]
            local c = spell and colors[spell]
            local yellow, grey
            if c then yellow, grey = c:match("^(%d+):(%d+)$") end
            yellow, grey = tonumber(yellow), tonumber(grey)
            req = RequiredOf(prof, key, req)
            local learn, fee, recipeItem
            if known[key] then learn = "known" elseif not onlyKnown then learn, fee, recipeItem = HowToLearn(prof, key, spell, known, req, grey) end
            list[#list + 1] = { prof = prof, key = key, name = d.DisplayName(prof, key), spell = spell, product = product, made = made,
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
    input.stock = setmetatable({}, { __index = function(t, id)
        local n = d.Have(id) or 0
        rawset(t, id, n)
        return n
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
    input.recipeItemPrices = ns.db.vendorPrices or {}
    local _, maxRank = nil, nil
    if ns.ProfessionRank then _, maxRank = ns.ProfessionRank(prof) end
    input.maxRank = (type(maxRank) == "number" and maxRank > 0) and maxRank or nil
    input.caps = CAPS
    input.nodes = setmetatable({}, { __index = function(_, id) return NodeFor(id) end })
    return input
end

ns.SkillPlanSnapshot = Snapshot

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
-- Window
---------------------------------------------------------------------------
local win, profText, skillText, targetText, content, totalText, noteText
local rows = {}
local state = { prof = nil, target = nil }

local function ItemName(id)
    return (ns.ItemName and ns.ItemName(id)) or (L["item "] .. id)
end

local function Row(i)
    local row = rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, content)
    row:SetSize(500, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", 4, 0)
    row.left:SetWidth(300)
    row.left:SetJustifyH("LEFT")
    row.left:SetWordWrap(false)
    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", -64, 0)
    row.right:SetWidth(170)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWordWrap(false)
    row.button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.button:SetSize(58, 16)
    row.button:SetPoint("RIGHT", -2, 0)
    ns.LText(row.button, "Farm")
    row.button:Hide()
    rows[i] = row
    return row
end

local haveSaid = {} -- item -> the last debug line about its count
local function Refresh()
    if not (win and win:IsShown() and Data()) then return end
    local d = Data()
    local prof = state.prof
    profText:SetText(d.ProfLabel(prof))
    local rank, maxRank
    if ns.ProfessionRank then rank, maxRank = ns.ProfessionRank(prof) end
    if not (maxRank and maxRank > 0) then maxRank = nil end
    local from = rank or 1
    local target = state.target
    if not target or target <= from then
        target = 300
        for _, cap in ipairs(CAPS) do
            if cap > from then target = cap break end
        end
        state.target = target
    end
    skillText:SetText(rank and maxRank and (L["Your skill: %d / %d"]):format(rank, maxRank)
        or rank and (L["Your skill: %d"]):format(rank) or L["Your skill: ? (open your profession window once)"])
    -- the targets are the usual Classic caps; without your own maximum they are assumed
    targetText:SetText(maxRank and tostring(target) or ("~" .. target))

    local steps, mats, total, stuck, unknown, info, plan = ns.SkillPlan(prof, from, target)
    -- where you have to train the next rank: your own maximum, after that the
    -- usual caps (assumed)
    local trainAt = {}
    if maxRank and maxRank < target then trainAt[maxRank] = "known" end
    for _, cap in ipairs(CAPS) do
        if cap < target and cap >= from and (not maxRank or cap > maxRank) then trainAt[cap] = trainAt[cap] or "assumed" end
    end
    -- rows one below the other; a line without a right column (hints, notes)
    -- takes the whole width and wraps, so long translations and big amounts
    -- are not cut off: its row grows with the text
    local n, y = 0, 0
    local function Line(left, right, color)
        n = n + 1
        local row = Row(n)
        local wide = right == nil
        row.left:SetWidth(wide and WIDE_W or 300)
        row.left:SetWordWrap(wide)
        row.left:SetText(left)
        row.right:SetText(right or "")
        row.left:SetTextColor(unpack(color or { 1, 1, 1 }))
        row.button:Hide()
        local h = ROW_H
        if wide then h = math.max(ROW_H, math.ceil((row.left:GetStringHeight() or 0) + 6)) end
        row:SetHeight(h)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        y = y + h
        row:Show()
        return row
    end
    Line(L["Steps"], nil, { 1, 0.82, 0.3 })
    if prof == "Mining" then
        Line(L["Mining also rises when you mine veins: a farm run for ore often does both."], nil, { 0.7, 0.7, 0.7 })
    end
    local function Train(at)
        local kind = trainAt[at]
        if not kind then return end
        trainAt[at] = nil
        Line(kind == "known" and (L["Train the next rank at your trainer (needed at %d)."]):format(at)
            or (L["Train the next rank at your trainer (at ~%d, cap assumed)."]):format(at), nil, { 1, 0.82, 0.3 })
    end
    for _, s in ipairs(steps) do
        local r = s.recipe
        for at = s.from, s.to - 1 do Train(at) end
        local learn = ""
        if r.how == "trainer" then learn = "  |cff999999" .. L["(trainer)"] .. "|r"
        elseif r.how == "vendor" then learn = "  |cff999999" .. L["(buy the recipe)"] .. "|r" end
        -- ~: one of its materials has an estimated price; ?: one has no price
        -- at all, so the choice of this recipe is not fully comparable
        Line(("%d-%d  %s%s"):format(s.from, s.to, r.name, learn), (L["%dx"]):format(s.crafts)
            .. (s.comparable == false and " ?" or s.estimated and " ~" or ""))
    end
    if steps[#steps] then Train(steps[#steps].to) end
    local estimated, gaps = false, false
    for _, s in ipairs(steps) do
        estimated = estimated or (s.estimated and s.comparable ~= false)
        gaps = gaps or s.comparable == false
    end
    if estimated then Line(L["~ = planned with an estimated price."], nil, { 0.6, 0.6, 0.6 }) end
    if gaps then Line(L["? = a material has no price: this choice is not fully comparable."], nil, { 0.6, 0.6, 0.6 }) end
    -- learning the plan's recipes: shown apart, not part of the choice
    if info.trainer > 0 then
        Line((L["Trainer fees for new recipes: %s"]):format(ns.Money(info.fees))
            .. (info.feesUnknown > 0 and ("  |cffff7070" .. (L["(+%d without a known fee)"]):format(info.feesUnknown) .. "|r") or ""),
            nil, { 0.8, 0.8, 0.8 })
    end
    if info.items > 0 then
        local text = (L["Recipes to buy from a vendor: %d"]):format(info.items)
        if info.itemCost > 0 then text = text .. "  " .. (L["about %s"]):format(ns.Money(info.itemCost)) end
        if info.itemsUnknown > 0 then text = text .. "  |cffff7070" .. (L["(+%d without a price)"]):format(info.itemsUnknown) .. "|r" end
        Line(text, nil, { 0.8, 0.8, 0.8 })
    end
    if stuck and prof == "Mining" then
        Line((L["From %d on: mine veins to go up (farm run for ore)."]):format(stuck), nil, { 1, 0.5, 0.4 })
    elseif stuck then
        Line((L["No recipe found for skill %d: visit your trainer, the plan goes on from there."]):format(stuck), nil, { 1, 0.5, 0.4 })
    end
    if #steps == 0 and not stuck then
        Line(L["Nothing to do: you are there already."], nil, { 0.7, 0.7, 0.7 })
    end
    Line(" ")
    Line(L["Materials"] .. "  |cff999999" .. L["(need / have)"] .. "|r", L["missing"], { 1, 0.82, 0.3 })
    for _, m in ipairs(mats) do
        local name = ItemName(m.id)
        -- /gcr debug: where the count comes from (once, and again when it changes)
        if ns.db.debug and d.HaveParts then
            local total, bags, reagent, bank = d.HaveParts(m.id)
            local text = ("PLAN have %s: bags %s, reagent bag %s, bank %s, total %d"):format(name,
                tostring(bags or "?"), tostring(reagent or "?"), tostring(bank or "?"), total)
            if haveSaid[m.id] ~= text then
                haveSaid[m.id] = text
                ns.Debug(text)
            end
        end
        local left = ("%s  |cff999999%d / %d|r"):format(name, m.need, m.have)
        local right
        if m.madeFrom then
            right = "|cff999999" .. (L["(make it: %s)"]):format(d.ProfLabel(m.madeFrom.prof)) .. "|r"
        elseif m.missing == 0 then
            right = "|cff55ff55" .. L["enough"] .. "|r"
        else
            right = ("|cffff7070%d|r  %s%s"):format(m.missing, m.costStatus == "estimated" and "~" or "",
                m.cost and ns.Money(m.cost) or L["|cffff7070no price|r"])
        end
        local row = Line(left, right)
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
    for i = n + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(1, y))
    -- the sum: what is known, what of it is only estimated, and how many
    -- materials have no price at all - those count as unknown, never as 0
    local estimated = plan.cost.estimated > 0 and ("  |cff999999" .. (L["(%s of it estimated)"]):format(ns.Money(plan.cost.estimated)) .. "|r") or ""
    if info.matsUnknown > 0 and total == 0 then
        totalText:SetText((L["Missing materials cost: unknown (%d without a price)"]):format(info.matsUnknown))
    elseif info.matsUnknown > 0 then
        totalText:SetText((L["Missing materials cost about %s"]):format(ns.Money(total)) .. estimated .. "  |cffff7070"
            .. (L["(+%d without a price)"]):format(info.matsUnknown) .. "|r")
    else
        totalText:SetText((L["Missing materials cost about %s"]):format(ns.Money(total)) .. estimated)
    end
    noteText:SetText(unknown and L["Some prices are unknown: scan the auction house for a better plan."] or "")
end
ns.RefreshSkillPlan = Refresh

local function Cycle(list, value, delta)
    local index = 1
    for i, v in ipairs(list) do if v == value then index = i end end
    return list[(index - 1 + delta) % #list + 1]
end

local function Build()
    win = ns.MakeCard("GathercraftSkillPlan", 560, 520)
    ns.LText(win.title, "Skill plan")

    local function Arrow(text, x, y, onClick)
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        b:SetSize(24, 20)
        b:SetPoint("TOPLEFT", x, y)
        b:SetText(text)
        b:SetScript("OnClick", onClick)
        return b
    end
    -- Mining shows as Smelting: smelting ore gives Mining skill too
    local profNames = {}
    for _, p in ipairs(Data().Professions) do profNames[#profNames + 1] = p.name end
    Arrow("<", 24, -62, function() state.prof, state.target = Cycle(profNames, state.prof, -1), nil Refresh() end)
    profText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    profText:SetPoint("TOPLEFT", 52, -65)
    profText:SetWidth(130)
    Arrow(">", 186, -62, function() state.prof, state.target = Cycle(profNames, state.prof, 1), nil Refresh() end)

    skillText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    skillText:SetPoint("TOPLEFT", 222, -66)
    skillText:SetWidth(170)
    skillText:SetJustifyH("LEFT")

    local targetLabel = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    targetLabel:SetPoint("TOPLEFT", 396, -66)
    ns.LText(targetLabel, "Target")
    Arrow("<", 438, -62, function()
        state.target = Cycle(CAPS, state.target, -1) Refresh()
    end)
    targetText = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    targetText:SetPoint("TOPLEFT", 466, -65)
    targetText:SetWidth(30)
    Arrow(">", 500, -62, function()
        state.target = Cycle(CAPS, state.target, 1) Refresh()
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
    -- what you have changes while the plan is open (loot, crafting, the bank):
    -- count again, once for a burst of bag updates. Events this client
    -- doesn't know are left out.
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
        "PLAYERBANKSLOTS_CHANGED", "PLAYERREAGENTBANKSLOTS_CHANGED" }) do
        pcall(win.RegisterEvent, win, e)
    end
end

-- Opens the planner for a profession (default: one of yours)
local function ShowSkillPlan(prof)
    if not Data() then return end
    if not win then Build() end
    if prof and prof ~= "" then
        local key = ns.ProfKey and ns.ProfKey(prof) or prof
        for _, p in ipairs(Data().Professions) do
            if p.name:lower() == tostring(key):lower() then state.prof = p.name end
        end
    end
    if not state.prof then
        -- one of yours that the planner knows (not Poisons, not Smelting)
        local plannable = {}
        for _, p in ipairs(Data().Professions) do
            if p.name ~= "Mining" then plannable[p.name] = true end
        end
        for _, p in ipairs(Data().MyProfessions()) do
            if plannable[p] then state.prof = p break end
        end
        state.prof = state.prof or "Alchemy"
    end
    state.target = nil
    win:Show()
    Refresh()
end
ns.ShowSkillPlan = ShowSkillPlan
