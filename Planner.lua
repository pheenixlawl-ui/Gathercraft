local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Skill planner: the cheapest way from your skill to a target skill
--   * every recipe you know, a trainer teaches or a vendor sells (drops and
--     quests are left out: you can't count on them)
--   * skill-up chance from the recipe's colours (Data/RecipeData.lua colors):
--     orange 100 %, yellow and green fall off towards grey
--     (chance = (grey - skill) / (grey - yellow), the usual Classic rule)
--   * per skill point the recipe with the lowest expected cost per point;
--     staying on the same recipe is preferred a little (fewer steps)
--   * the material list: what you need, what you have (bags and bank), what
--     is missing and what that costs; bars and bolts you can make yourself
--     are broken down into ore and cloth, and herbs and ore you can gather
--     get a button that starts a farm run for them
---------------------------------------------------------------------------
local CAPS = { 75, 150, 225, 300 }
local SWITCH_PENALTY = 1.08   -- a new recipe has to be this much cheaper per point
local UNKNOWN_PRICE = 2000     -- copper per item when no price is known (keeps such recipes possible but not first)
local ROW_H = 18

local function Data() return ns.CraftData end

-- Skill-up chance of a recipe at a skill: 1 orange, falling off to 0 at grey
local function Chance(skill, req, yellow, grey)
    if skill < req then return 0 end
    if skill < yellow then return 1 end
    if skill >= grey then return 0 end
    return (grey - skill) / (grey - yellow)
end

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
    if (req or 0) <= 1 and not item and grey <= 75 then return "start" end
end

-- The recipes the plan can use, with colours and the cost of one craft
local function Candidates(prof)
    local d = Data()
    local spells = GathercraftRecipeData and GathercraftRecipeData.spells and GathercraftRecipeData.spells[prof] or {}
    local colors = GathercraftRecipeData and GathercraftRecipeData.colors or {}
    local known = d.Known(prof)
    local list, unknownPrices = {}, false
    for key, packed in pairs(d.AllRecipes(prof)) do
        local spell = spells[key]
        local c = spell and colors[spell]
        local yellow, grey
        if c then yellow, grey = c:match("^(%d+):(%d+)$") end
        yellow, grey = tonumber(yellow), tonumber(grey)
        local product, made, req, reagents = d.Unpack(packed)
        -- a recipe read from a profession window has no required skill: take the shipped one
        if (req or 0) == 0 then
            local shipped = GathercraftRecipeData.professions and GathercraftRecipeData.professions[prof]
            if shipped and shipped[key] then
                local _, _, shippedReq = d.Unpack(shipped[key])
                req = shippedReq or req
            end
        end
        if yellow and grey and reagents and #reagents > 0 then
            local how, fee, recipeItem = HowToLearn(prof, key, spell, known, req, grey)
            if how then
                local cost, guessed = 0, false
                for _, r in ipairs(reagents) do
                    local price = d.ReagentCost(r.id)
                    if not price then
                        -- no auction price yet: a few times what a vendor pays for it
                        local sell, source
                        if ns.GetPrice then sell, source = ns.GetPrice(r.id) end
                        price = (source == "vendor" and sell and sell > 0) and sell * 4 or UNKNOWN_PRICE
                        guessed = true
                    end
                    cost = cost + price * r.n
                end
                unknownPrices = unknownPrices or guessed
                list[#list + 1] = {
                    key = key, name = d.DisplayName(prof, key), product = product, made = made,
                    req = math.max(1, req or 1), yellow = yellow, grey = grey, reagents = reagents,
                    cost = cost, how = how, fee = fee, recipeItem = recipeItem,
                }
            end
        end
    end
    return list, unknownPrices
end

-- The plan: steps { recipe, from, to, crafts } and where it got stuck (if)
local function MakePlan(prof, from, to)
    local cands, unknownPrices = Candidates(prof)
    local steps, current, stuck = {}, nil, nil
    for skill = from, to - 1 do
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

-- What makes an item: a recipe of this profession or smelting (bars)
local function Producers(prof)
    local d = Data()
    local out = {}
    for _, p in ipairs({ prof, "Mining" }) do
        for key, packed in pairs(d.AllRecipes(p)) do
            local product, made, _, reagents = d.Unpack(packed)
            if product and product > 0 and reagents and #reagents > 0 and not out[product] then
                out[product] = { prof = p, key = key, made = math.max(1, made or 1), reagents = reagents }
            end
        end
    end
    return out
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

-- Materials of the plan: { id, need, have, missing, cost, node, made = from }
local function Materials(prof, steps)
    local d = Data()
    local need = {}
    for _, s in ipairs(steps) do
        for _, r in ipairs(s.recipe.reagents) do
            need[r.id] = (need[r.id] or 0) + r.n * s.crafts
        end
    end
    -- bars, bolts...: what you don't have is made from its own materials
    -- (again and again: bronze bars need copper bars, which need ore)
    local producers = Producers(prof)
    local madeTimes, madeFrom = {}, {}
    for _ = 1, 100 do
        local changed = false
        for id, n in pairs(need) do
            local p = producers[id]
            if p then
                local times = math.ceil(math.max(0, n - d.Have(id)) / p.made)
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
    local list, total = {}, 0
    for id, n in pairs(need) do
        local have = d.Have(id)
        local missing = math.max(0, n - have)
        if madeFrom[id] then missing = 0 end -- listed by its materials
        local price = d.ReagentCost(id)
        local cost = price and price * missing or nil
        total = total + (cost or 0)
        list[#list + 1] = { id = id, need = n, have = have, missing = missing, cost = cost,
            node = NodeFor(id), madeFrom = madeFrom[id] }
    end
    table.sort(list, function(a, b)
        if (a.madeFrom ~= nil) ~= (b.madeFrom ~= nil) then return b.madeFrom ~= nil end
        if a.missing ~= b.missing then return a.missing > b.missing end
        return a.id < b.id
    end)
    return list, total
end
ns.SkillPlan = function(prof, from, to)
    local steps, stuck, unknown = MakePlan(prof, from, to)
    local mats, total = Materials(prof, steps)
    return steps, mats, total, stuck, unknown
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

local function Refresh()
    if not (win and win:IsShown() and Data()) then return end
    local d = Data()
    local prof = state.prof
    profText:SetText(d.ProfLabel(prof))
    local rank = ns.ProfessionRank and ns.ProfessionRank(prof)
    local from = rank or 1
    local target = state.target
    if not target or target <= from then
        target = 300
        for _, cap in ipairs(CAPS) do
            if cap > from then target = cap break end
        end
        state.target = target
    end
    skillText:SetText(rank and (L["Your skill: %d"]):format(rank) or L["Your skill: ? (open your profession window once)"])
    targetText:SetText(target)

    local steps, mats, total, stuck, unknown = ns.SkillPlan(prof, from, target)
    local n = 0
    local function Line(left, right, color)
        n = n + 1
        local row = Row(n)
        row.left:SetText(left)
        row.right:SetText(right or "")
        row.left:SetTextColor(unpack(color or { 1, 1, 1 }))
        row.button:Hide()
        row:Show()
        return row
    end
    Line(L["Steps"], nil, { 1, 0.82, 0.3 })
    if prof == "Mining" then
        Line(L["Mining also rises when you mine veins: a farm run for ore often does both."], nil, { 0.7, 0.7, 0.7 })
    end
    for _, s in ipairs(steps) do
        local r = s.recipe
        local learn = ""
        if r.how == "trainer" then learn = "  |cff999999" .. L["(trainer)"] .. "|r"
        elseif r.how == "vendor" then learn = "  |cff999999" .. L["(buy the recipe)"] .. "|r" end
        Line(("%d-%d  %s%s"):format(s.from, s.to, r.name, learn), (L["%dx"]):format(s.crafts))
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
        local left = ("%s  |cff999999%d / %d|r"):format(name, m.need, m.have)
        local right
        if m.madeFrom then
            left = left .. "  |cff999999" .. (L["(make it: %s)"]):format(d.ProfLabel(m.madeFrom.prof)) .. "|r"
            right = ""
        elseif m.missing == 0 then
            right = "|cff55ff55" .. L["enough"] .. "|r"
        else
            right = ("|cffff7070%d|r  %s"):format(m.missing, m.cost and ns.Money(m.cost) or L["|cffff7070no price|r"])
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
    content:SetHeight(math.max(1, n * ROW_H))
    totalText:SetText((L["Missing materials cost about %s"]):format(ns.Money(total)))
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
    noteText = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    noteText:SetPoint("BOTTOMLEFT", 24, 24)
    noteText:SetWidth(500)
    noteText:SetJustifyH("LEFT")
    win:SetScript("OnShow", Refresh)
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
