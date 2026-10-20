local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- What's best to craft?
--   Every profession, every recipe we know of:
--     * recipes that ship with Gathercraft (Data\RecipeData.lua, collected
--       in game from trainers and profession windows)
--     * recipes any of your characters saw at a trainer
--     * recipes your characters know (profession window, also gives the
--       skill-up color)
--   and works out for each one:
--     sells for  = auction price of what you make x how many you make,
--                  minus the 5% auction house cut
--     costs      = the reagents: auction price, or the real vendor price
--                  for things vendors sell (thread, vials, flux, ...)
--     profit     = sells for - costs
--     can make   = how often with the reagents in your bags and bank
--   Nothing is crafted, bought or sold for you: this only shows numbers.
---------------------------------------------------------------------------
local AH_CUT = 0.95
-- Reagents vendors sell. Their real price is learned when you visit a vendor;
-- until then: about 4x what the vendor pays you for it.
local VENDOR_REAGENTS = {
    [2320] = true, [2321] = true, [4291] = true, [8343] = true, [14341] = true, -- thread
    [3371] = true, [3372] = true, [8925] = true, [18256] = true,                -- vials
    [2880] = true, [3466] = true, [3857] = true,                                -- flux, coal
    [2324] = true, [2325] = true, [2604] = true, [2605] = true, [4340] = true,
    [4341] = true, [4342] = true, [6260] = true, [6261] = true, [10290] = true, -- dyes, bleach
    [2678] = true, [2692] = true, [3713] = true, [159] = true, [1179] = true,
    [30817] = true, [2596] = true, [4289] = true, [4399] = true, [4400] = true, -- cooking, salt, wood
    [6217] = true, [6256] = true, [5956] = true, [2901] = true, [7005] = true,  -- rods, tools
}
local VENDOR_MARKUP = 4
local DIFF = { optimal = 0, medium = 1, easy = 2, trivial = 3 }
-- Professions with their icon and a short label for the sub tabs
local PROFESSIONS = {
    { name = "Alchemy", short = "Alchemy", icon = "Interface\\Icons\\Trade_Alchemy" },
    { name = "Blacksmithing", short = "Blacksmith", icon = "Interface\\Icons\\Trade_BlackSmithing" },
    { name = "Enchanting", short = "Enchanting", icon = "Interface\\Icons\\Trade_Engraving" },
    { name = "Engineering", short = "Engineering", icon = "Interface\\Icons\\Trade_Engineering" },
    { name = "Leatherworking", short = "Leather", icon = "Interface\\Icons\\Trade_LeatherWorking" },
    { name = "Tailoring", short = "Tailoring", icon = "Interface\\Icons\\Trade_Tailoring" },
    { name = "Cooking", short = "Cooking", icon = "Interface\\Icons\\INV_Misc_Food_15" },
    { name = "First Aid", short = "First Aid", icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
    { name = "Mining", short = "Smelting", icon = "Interface\\Icons\\Trade_Mining" },
}
-- short profession names for the sub-tabs where the real ones are long
local SHORT_LABELS = {
    deDE = { Alchemy = "Alchemie", Blacksmithing = "Schmied", Enchanting = "Verzaubern", Engineering = "Ingenieur", Leatherworking = "Leder",
        Tailoring = "Schneider", Cooking = "Kochen", ["First Aid"] = "Erste Hilfe", Mining = "Verhüttung" },
    frFR = { Enchanting = "Enchant.", Engineering = "Ingénierie", Leatherworking = "Cuir", ["First Aid"] = "Secourisme",
        Mining = "Fonte" },
    esES = { Enchanting = "Encantam.", Leatherworking = "Peletería", ["First Aid"] = "Primeros aux.", Mining = "Fundición" },
    esMX = { Enchanting = "Encantam.", Leatherworking = "Peletería", ["First Aid"] = "Primeros aux.", Mining = "Fundición" },
}

-- where the game's own name is a known mistranslation
local FULL_LABELS = { deDE = { Alchemy = "Alchemie" } }

local DIFF_COLORS = { [0] = "|cffff8040", [1] = "|cffffff00", [2] = "|cff40c040", [3] = "|cff808080" }

local function ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

local function CharKey()
    return (UnitName("player") or "?") .. "-" .. ((GetNormalizedRealmName and GetNormalizedRealmName()) or "?")
end

---------------------------------------------------------------------------
-- Every client language: professions and recipes are stored under their
-- English names (like the shipped data), shown in the client's language.
---------------------------------------------------------------------------
local englishClient = not GetLocale or GetLocale():sub(1, 2) == "en"

local function SpellNameOf(id)
    if not id then return end
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end

-- profession spell IDs: their names are the professions in the client's language
local PROF_SPELLS = {
    Alchemy = 2259, Blacksmithing = 2018, Enchanting = 7411, Engineering = 4036, Leatherworking = 2108,
    Tailoring = 3908, Cooking = 2550, ["First Aid"] = 3273, Mining = 2575,
}
local profAlias
local function ProfKey(name)
    if not name or name == "" then return name end
    if not profAlias then
        profAlias = { smelting = "Mining", alchemie = "Alchemy" }
        for en, id in pairs(PROF_SPELLS) do
            profAlias[en:lower()] = en
            local loc = SpellNameOf(id)
            if loc and loc ~= "" then profAlias[loc:lower()] = en end
        end
        local smelting = SpellNameOf(2656)
        if smelting and smelting ~= "" then profAlias[smelting:lower()] = "Mining" end
    end
    return profAlias[name:lower()] or name
end
ns.ProfKey = ProfKey

-- a profession's name to show: the game's own, with known slips fixed
local function ProfLabel(prof)
    if englishClient then return prof end
    local fixed = FULL_LABELS and (FULL_LABELS[GetLocale()] or {})[prof]
    if fixed then return fixed end
    local loc = SpellNameOf(prof == "Mining" and 2656 or PROF_SPELLS[prof])
    return (loc and loc ~= "") and loc or prof
end

-- shipped recipes by name in the client's language and by product
local localIndex, productIndex = {}, {}
local function ShippedSpells(prof)
    local s = GathercraftRecipeData and GathercraftRecipeData.spells
    return (s and s[prof]) or {}
end
local indexedData
local function BuildIndex(prof)
    if indexedData ~= GathercraftRecipeData then -- (only changes in tests)
        indexedData, localIndex, productIndex = GathercraftRecipeData, {}, {}
    end
    if localIndex[prof] then return end
    local li, pi = {}, {}
    local shipped = GathercraftRecipeData and GathercraftRecipeData.professions
    local spells = ShippedSpells(prof)
    for en, packed in pairs((shipped and shipped[prof]) or {}) do
        li[en:lower()] = li[en:lower()] or en
        local product = tonumber(packed:match("^(%d+)"))
        if product and product > 0 and not pi[product] then pi[product] = en end
        if not englishClient and spells[en] then
            local loc = SpellNameOf(spells[en])
            if loc and loc ~= "" then li[loc:lower()] = li[loc:lower()] or en end
        end
    end
    localIndex[prof], productIndex[prof] = li, pi
end

-- the name a recipe is stored under (English for every shipped recipe)
local function Canon(prof, name, product)
    if not name then return name end
    BuildIndex(prof)
    return localIndex[prof][name:lower()]
        or (product and product > 0 and productIndex[prof][product])
        or name
end

-- the name to show (the client's language)
local function DisplayName(prof, name)
    if englishClient then return name end
    local loc = SpellNameOf(ShippedSpells(prof)[name])
    return (loc and loc ~= "") and loc or name
end

-- Tooltip texts in the client's language, from the game's own strings
local function Escape(text) return (text:gsub("([%^%$%(%)%.%[%]%*%+%-%?%%])", "%%%1")) end
local function PatternFromFormat(fmt)
    if type(fmt) ~= "string" or fmt == "" then return end
    local p = fmt:gsub("%%%d%$", "%%")                -- "%1$s" -> "%s"
    p = p:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")  -- magic characters
    p = p:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. p .. "$"
end
local REQUIRES_PATTERNS = { "^Requires (.+) %((%d+)%)$", PatternFromFormat(_G.ITEM_MIN_SKILL) }
local USE_PREFIX = (type(_G.ITEM_SPELL_TRIGGER_ONUSE) == "string" and _G.ITEM_SPELL_TRIGGER_ONUSE ~= "") and _G.ITEM_SPELL_TRIGGER_ONUSE or "Use:"
local REAGENT_PREFIXES = { "Reagents:" }
if type(_G.SPELL_REAGENTS) == "string" then
    local prefix = _G.SPELL_REAGENTS:gsub("%%s", ""):gsub("|n", ""):gsub("%s+$", "")
    if prefix ~= "" and prefix ~= "Reagents:" then REAGENT_PREFIXES[#REAGENT_PREFIXES + 1] = prefix end
end

local function MatchRequires(text)
    for _, pattern in ipairs(REQUIRES_PATTERNS) do
        local p, r = text:match(pattern)
        if p and tonumber(r) then return p, tonumber(r) end
    end
end

-- Every recipe any character of this account has seen, per profession:
-- name -> "product:min:max:requiredSkill|reagent:count,..."
local function RecipeDB()
    ns.db.recipeDB = ns.db.recipeDB or {}
    return ns.db.recipeDB
end

-- Keep the best we know: amounts from the profession window, the required
-- skill from the trainer
local function MergeRecipe(prof, name, product, nMin, nMax, req, reagentText)
    prof = ProfKey(prof)
    name = Canon(prof, name, product)
    local db = RecipeDB()
    db[prof] = db[prof] or {}
    local old = db[prof][name]
    if old then
        local _, oMin, oMax, oReq = old:match("^(%d+):(%d+):(%d+):(%d+)|")
        if not req or req == 0 then req = tonumber(oReq) end
        if not nMin then nMin, nMax = tonumber(oMin), tonumber(oMax) end
    end
    db[prof][name] = ("%d:%d:%d:%d|%s"):format(product, nMin or 1, nMax or nMin or 1, req or 0, reagentText)
end

-- Saved data from older versions or other client languages: move it under
-- the English names (once per session)
local normalized = false
local function Normalize()
    if normalized or not ns.db then return end
    normalized = true
    local function ProductOf(packed) return tonumber(packed:match("^(%d+)")) end
    -- account recipe book: prof -> name -> packed
    local db = ns.db.recipeDB or {}
    local profs = {}
    for prof in pairs(db) do profs[#profs + 1] = prof end
    for _, prof in ipairs(profs) do
        local key, list = ProfKey(prof), db[prof]
        local fixed = (key ~= prof and db[key]) or {}
        for name, packed in pairs(list) do
            local new = Canon(key, name, ProductOf(packed))
            fixed[new] = fixed[new] or packed
        end
        db[prof] = nil
        db[key] = fixed
    end
    -- each character: prof -> { list = name -> packed }
    for _, char in pairs(ns.db.recipes or {}) do
        local cprofs = {}
        for prof in pairs(char) do cprofs[#cprofs + 1] = prof end
        for _, prof in ipairs(cprofs) do
            local key, info = ProfKey(prof), char[prof]
            local fixed = {}
            for name, packed in pairs(info.list or {}) do
                fixed[Canon(key, name, ProductOf(packed))] = packed
            end
            info.list = fixed
            char[prof] = nil
            char[key] = info
        end
    end
end

local function CharRecipes()
    ns.db.recipes = ns.db.recipes or {}
    Normalize()
    local key = CharKey()
    ns.db.recipes[key] = ns.db.recipes[key] or {}
    return ns.db.recipes[key]
end

---------------------------------------------------------------------------
-- Reading the profession window
--   recipe string: "product:min:max:difficulty|reagent:count,reagent:count"
---------------------------------------------------------------------------
local function Pack(product, nMin, nMax, diff, reagents)
    return ("%d:%d:%d:%d|%s"):format(product, nMin or 1, nMax or nMin or 1, diff or 3, table.concat(reagents, ","))
end

local function ReadModern()
    local api = C_TradeSkillUI
    if not (api and api.GetAllRecipeIDs and api.GetRecipeSchematic) then return end
    if api.IsTradeSkillLinked and api.IsTradeSkillLinked() then return end -- someone else's
    if api.IsTradeSkillGuild and api.IsTradeSkillGuild() then return end
    local ok, ids = pcall(api.GetAllRecipeIDs)
    if not ok or type(ids) ~= "table" or #ids == 0 then return end
    local prof
    if api.GetBaseProfessionInfo then
        local info = api.GetBaseProfessionInfo()
        prof = info and info.professionName
    end
    if not prof and api.GetTradeSkillLine then
        local _, name = api.GetTradeSkillLine()
        prof = name
    end
    if not prof or prof == "" then return end
    local recipes = {}
    for _, id in ipairs(ids) do
        local info = api.GetRecipeInfo and api.GetRecipeInfo(id)
        if info and info.learned then
            local okS, sch = pcall(api.GetRecipeSchematic, id, false)
            local product = okS and sch and sch.outputItemID
            if product then
                local reagents = {}
                for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
                    local r = slot.reagents and slot.reagents[1]
                    -- basic reagents only (optional / finishing ones are extras)
                    if r and r.itemID and (slot.reagentType == nil or slot.reagentType == 1) then
                        reagents[#reagents + 1] = r.itemID .. ":" .. (slot.quantityRequired or 1)
                    end
                end
                recipes[info.name or tostring(id)] = Pack(product, sch.quantityMin, sch.quantityMax,
                    info.relativeDifficulty, reagents)
            end
        end
    end
    return prof, recipes
end

local function ReadClassic()
    if not (GetNumTradeSkills and GetTradeSkillLine) then return end
    if IsTradeSkillLinked and IsTradeSkillLinked() then return end
    local prof = GetTradeSkillLine()
    if not prof or prof == "UNKNOWN" then return end
    local recipes = {}
    for i = 1, GetNumTradeSkills() or 0 do
        local name, kind = GetTradeSkillInfo(i)
        if name and kind ~= "header" and kind ~= "subheader" then
            local product = ItemIDFromLink(GetTradeSkillItemLink(i))
            if product then
                local nMin, nMax = GetTradeSkillNumMade(i)
                local reagents = {}
                for r = 1, GetTradeSkillNumReagents(i) or 0 do
                    local _, _, count = GetTradeSkillReagentInfo(i, r)
                    local id = ItemIDFromLink(GetTradeSkillReagentItemLink(i, r))
                    if id and count then reagents[#reagents + 1] = id .. ":" .. count end
                end
                recipes[name] = Pack(product, nMin, nMax, DIFF[kind], reagents)
            end
        end
    end
    return prof, recipes
end

-- Enchanting in classic clients uses its own "craft" window; only recipes
-- that make an item (wands, oils, rods) can be sold
local function ReadCraft()
    if not (GetNumCrafts and GetCraftDisplaySkillLine) then return end
    local prof = GetCraftDisplaySkillLine()
    if not prof then return end
    local recipes = {}
    for i = 1, GetNumCrafts() or 0 do
        local name, _, kind = GetCraftInfo(i)
        if name and kind ~= "header" then
            local product = ItemIDFromLink(GetCraftItemLink and GetCraftItemLink(i))
            if product then
                local reagents = {}
                for r = 1, GetCraftNumReagents(i) or 0 do
                    local _, _, count = GetCraftReagentInfo(i, r)
                    local id = ItemIDFromLink(GetCraftReagentItemLink(i, r))
                    if id and count then reagents[#reagents + 1] = id .. ":" .. count end
                end
                recipes[name] = Pack(product, 1, 1, DIFF[kind], reagents)
            end
        end
    end
    return prof, recipes
end

local told = {}
local function Learn(reader)
    if not ns.db then return end
    local ok, prof, recipes = pcall(reader)
    if not ok then
        ns.Debug("CRAFT read failed: " .. tostring(prof))
        return
    end
    if not (prof and recipes) then return end
    local shownProf = prof
    prof = ProfKey(prof)
    local count = 0
    local canon = {}
    for name, packed in pairs(recipes) do
        count = count + 1
        canon[Canon(prof, name, tonumber(packed:match("^(%d+)")))] = packed
    end
    recipes = canon
    if count == 0 then return end
    local mine = CharRecipes()
    -- the window can hide recipes (collapsed groups, filters): keep what we knew
    local old = mine[prof] and mine[prof].list or {}
    for name, packed in pairs(recipes) do
        old[name] = packed
        local product, nMin, nMax, _, reagentText = packed:match("^(%d+):(%d+):(%d+):(%d+)|(.*)$")
        if product then MergeRecipe(prof, name, tonumber(product), tonumber(nMin), tonumber(nMax), nil, reagentText) end
    end
    mine[prof] = { list = old, updated = time() }
    if not told[prof] then
        told[prof] = true
        local total = 0
        for _ in pairs(old) do total = total + 1 end
        ns.Print((L["Learned %d %s recipes. See the Crafting tab for what's worth making."]):format(total, ProfLabel(prof)))
    end
    if ns.RefreshCraftPage then ns.RefreshCraftPage() end
end

local pending = false
local function Schedule(reader)
    if pending then return end
    pending = true
    C_Timer.After(0.5, function()
        pending = false
        Learn(reader or function()
            local prof, recipes = ReadModern()
            if prof then return prof, recipes end
            return ReadClassic()
        end)
    end)
end

---------------------------------------------------------------------------
-- Trainers: every recipe they teach, with the skill it needs (also the ones
-- you can't learn yet). Works at any profession trainer, even without the
-- profession. The trainer's filters are opened for a moment and put back.
---------------------------------------------------------------------------
local readingTrainer = false
local lastTrainerCount, trainerToldEmpty = nil, false

-- The trainer's profession, for clients that don't name it per recipe
local function TrainerProfession()
    local frameTitle = ClassTrainerFrameTitleText or (ClassTrainerFrame and ClassTrainerFrame.TitleText)
    local text = frameTitle and frameTitle.GetText and frameTitle:GetText()
    if not text then return end
    for _, p in ipairs(PROFESSIONS) do
        if text:find(p.name, 1, true) then return p.name end
    end
end

-- Clients differ: some want true/false, some 1/0
local function SetFilter(kind, on)
    if pcall(SetTrainerServiceTypeFilter, kind, on) then return true end
    return pcall(SetTrainerServiceTypeFilter, kind, on and 1 or 0)
end

-- tooltip text of a trainer entry
local scanTip
local function TrainerTooltipLines(i)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetTrainerService then
        local ok, data = pcall(C_TooltipInfo.GetTrainerService, i)
        if ok and data and data.lines then
            for _, line in ipairs(data.lines) do lines[#lines + 1] = line.leftText or "" end
            if #lines > 0 then return lines end
        end
    end
    if not CreateFrame then return lines end
    scanTip = scanTip or CreateFrame("GameTooltip", "GathercraftScanTip", nil, "GameTooltipTemplate")
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    scanTip:ClearLines()
    if not (scanTip.SetTrainerService and pcall(scanTip.SetTrainerService, scanTip, i)) then return lines end
    for n = 1, scanTip:NumLines() or 0 do
        local fs = _G["GathercraftScanTipTextLeft" .. n]
        lines[#lines + 1] = (fs and fs:GetText()) or ""
    end
    scanTip:Hide()
    return lines
end

-- "Reagents: Linen Cloth (2), Coarse Thread" -> { {"Linen Cloth", 2}, {"Coarse Thread", 1} }
local function ParseReagentLine(lines)
    for _, text in ipairs(lines or {}) do
        local clean = text:gsub("|n", " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        local rest
        for _, prefix in ipairs(REAGENT_PREFIXES) do
            rest = rest or clean:match("^%s*" .. Escape(prefix) .. "%s*(.+)$")
        end
        if rest then
            local out = {}
            for part in rest:gmatch("[^,]+") do
                local nm, n = part:match("^%s*(.-)%s*%((%d+)%)%s*$")
                if not nm then nm, n = part:match("^%s*(.-)%s*$"), 1 end
                if nm and nm ~= "" then out[#out + 1] = { nm, tonumber(n) } end
            end
            if #out > 0 then return out end
        end
    end
end

local function ReadTrainerServices()
    local changed = {}
    if GetTrainerServiceTypeFilter and SetTrainerServiceTypeFilter then
        for _, t in ipairs({ "available", "unavailable", "used" }) do
            local ok, shown = pcall(GetTrainerServiceTypeFilter, t)
            if ok and not shown and SetFilter(t, true) then
                changed[#changed + 1] = t
            end
        end
    end
    local count, profName, waiting = 0, nil, 0
    local why = { total = 0, header = 0, noItem = 0, noSkill = 0, noReagents = 0 }
    local fallbackSkill = TrainerProfession and TrainerProfession()
    for i = 1, GetNumTrainerServices() or 0 do
        local name, _, kind = GetTrainerServiceInfo(i)
        local product = ItemIDFromLink(GetTrainerServiceItemLink and GetTrainerServiceItemLink(i))
        why.total = why.total + 1
        if not name or kind == "header" then
            why.header = why.header + 1
        else
            local skill, req = nil, nil
            if GetTrainerServiceSkillReq then skill, req = GetTrainerServiceSkillReq(i) end
            if skill == "" then skill = nil end
            skill = skill or (GetTrainerServiceSkillLine and GetTrainerServiceSkillLine(i)) or fallbackSkill
            local reagents = {}
            for r = 1, (GetTrainerServiceNumReagents and GetTrainerServiceNumReagents(i)) or 0 do
                local _, _, n = GetTrainerServiceReagentInfo(i, r)
                local id = ItemIDFromLink(GetTrainerServiceReagentLink and GetTrainerServiceReagentLink(i, r))
                if id and n then reagents[#reagents + 1] = id .. ":" .. n end
            end
            if not skill then
                why.noSkill = why.noSkill + 1
            elseif product and #reagents > 0 then
                MergeRecipe(skill, name, product, nil, nil, tonumber(req), table.concat(reagents, ","))
                count, profName = count + 1, skill
            else
                -- this client leaves links out: read the tooltip ("Reagents: ...")
                local named = ParseReagentLine(TrainerTooltipLines(i))
                if not named then
                    if product then why.noReagents = why.noReagents + 1 else why.noItem = why.noItem + 1 end
                else
                    local productName = name
                    if product then
                        productName = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(product)) or name
                        ns.NoteItemName(productName, product)
                    end
                    if ns.RememberRecipe(skill, tonumber(req), productName, named) then
                        count = count + 1
                    else
                        waiting = waiting + 1
                    end
                    profName = skill
                end
            end
        end
    end
    for _, t in ipairs(changed) do SetFilter(t, false) end
    why.waiting = waiting
    return count, profName, why
end

local function ReadTrainer()
    if readingTrainer or not (GetNumTrainerServices and GetTrainerServiceInfo and GetTrainerServiceItemLink) then return end
    readingTrainer = true
    if ns.InvalidateNameIndex then ns.InvalidateNameIndex() end
    local ok, count, profName, why = pcall(ReadTrainerServices)
    readingTrainer = false
    if not ok then
        ns.Print(L["Could not read this trainer: "] .. tostring(count))
        return
    end
    local waiting = why and why.waiting or 0
    if count + waiting > 0 then
        if count ~= lastTrainerCount then
            if waiting > 0 then
                ns.Print((L["Noted %d %s recipes from this trainer, %d more as soon as their items are known (AH scan or vendor visit)."]):format(
                    count, ProfLabel(ProfKey(profName)), waiting))
            else
                ns.Print((L["Noted %d %s recipes from this trainer."]):format(count, ProfLabel(ProfKey(profName))))
            end
        end
        lastTrainerCount = count
        if ns.RefreshCraftPage then ns.RefreshCraftPage() end
    elseif why and why.total > why.header + why.noItem and not trainerToldEmpty then
        trainerToldEmpty = true
        ns.Print((L["Trainer: %d entries, none noted (headers %d, no item %d, no skill %d, no reagents %d). Please send this line."]):format(
            why.total, why.header, why.noItem, why.noSkill, why.noReagents))
    end
end

-- The list fills in a moment after the window opens (and again when the
-- filters change), so read once more on updates, at most every 0.5 s.
local trainerQueued = false
local function QueueTrainerRead()
    if trainerQueued then return end
    trainerQueued = true
    C_Timer.After(0.5, function() trainerQueued = false; ReadTrainer() end)
end
ns.ReadTrainer = ReadTrainer

---------------------------------------------------------------------------
-- Real vendor prices (learned at any vendor)
---------------------------------------------------------------------------
-- One merchant slot: name, price, stack size, stock (-1 = unlimited), extra cost?
-- (newer clients have C_MerchantFrame.GetItemInfo, older ones GetMerchantItemInfo)
local function MerchantItem(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        if ok and type(info) == "table" then
            return info.name, info.price, info.stackCount, info.numAvailable, info.hasExtendedCost
        end
    end
    if GetMerchantItemInfo then
        local name, _, price, quantity, numAvailable, _, _, extendedCost = GetMerchantItemInfo(i)
        return name, price, quantity, numAvailable, extendedCost
    end
end

local function LearnMerchant()
    if not GetMerchantNumItems then return end
    ns.db.vendorPrices = ns.db.vendorPrices or {}
    for i = 1, GetMerchantNumItems() or 0 do
        local itemName, price, quantity, numAvailable, extendedCost = MerchantItem(i)
        local id = ItemIDFromLink(GetMerchantItemLink and GetMerchantItemLink(i))
        if id and itemName and ns.NoteItemName then ns.NoteItemName(itemName, id) end
        -- unlimited stock, paid in gold: that's a reagent anyone can buy
        if id and price and price > 0 and not extendedCost and numAvailable == -1 then
            ns.db.vendorPrices[id] = price / math.max(1, quantity or 1)
        end
    end
end

---------------------------------------------------------------------------
-- Recipe items (Recipe:, Pattern:, Plans:, ...) at vendors, at the auction
-- house and under your mouse: their tooltip says what they teach, what it
-- needs and which skill. Names are turned into item IDs as soon as we know
-- the items (most reagents are on the auction house anyway).
---------------------------------------------------------------------------
local RECIPE_PREFIXES = { "Recipe:", "Pattern:", "Plans:", "Formula:", "Schematic:", "Manual:" }
local function IsRecipeName(name)
    if not name then return false end
    for _, p in ipairs(RECIPE_PREFIXES) do
        if name:sub(1, #p) == p then return true end
    end
    -- other languages: "Rezept: ...", "Recette : ..."; the tooltip decides
    return not englishClient and name:find(":", 1, true) ~= nil
end

local function Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- tooltip lines -> profession, required skill, product name, { {name, count} }
local function ParseRecipeLines(lines)
    if not (lines[1] and IsRecipeName(lines[1])) then return end
    local prof, req, reagentLine
    for i, text in ipairs(lines) do
        local p, r = MatchRequires(text)
        if p and not prof then prof, req = p, r end
        if text:find("Teaches you how to", 1, true) or text:sub(1, #USE_PREFIX) == USE_PREFIX then
            reagentLine = reagentLine or lines[i + 1]
        end
    end
    local product = lines[2] and Trim(lines[2])
    -- enchanting formulas make no item: line 2 is already the "Use:" text,
    -- the recipe is named after the formula ("Formula: Enchant Bracer - ...")
    if not product or product == "" or product:sub(1, #USE_PREFIX) == USE_PREFIX or product:find("Teaches you", 1, true) then
        product = Trim(lines[1]:gsub("^[^:]+:%s*", ""))
    end
    if not (prof and product and product ~= "" and reagentLine) then return end
    if not PROF_SPELLS[ProfKey(prof)] then return end -- "Requires" something else (a reputation, a level, ...)
    local reagents = {}
    for part in reagentLine:gmatch("[^,]+") do
        local name, n = part:match("^%s*(.-)%s*%((%d+)%)%s*$")
        if not name then name, n = Trim(part), 1 end
        if name ~= "" then reagents[#reagents + 1] = { name, tonumber(n) } end
    end
    if #reagents == 0 then return end
    return prof, req, product, reagents
end

-- item name (lower case) -> item ID, from every item we have seen
local nameIndex
local function NameIndex(rebuild)
    if nameIndex and not rebuild then return nameIndex end
    nameIndex = {}
    local function add(id)
        local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
        if name then nameIndex[name:lower()] = id end
    end
    for _, p in pairs(ns.db.prices or {}) do
        for id in pairs(p.items or {}) do add(id) end
    end
    for id in pairs(ns.db.vendorPrices or {}) do add(id) end
    for id in pairs(VENDOR_REAGENTS) do add(id) end
    -- everything in the bags is loaded, so its name is known
    local bags = C_Container or _G
    if bags.GetContainerNumSlots then
        for bag = 0, 4 do
            for slot = 1, bags.GetContainerNumSlots(bag) or 0 do
                local id = bags.GetContainerItemID and bags.GetContainerItemID(bag, slot)
                if id then add(id) end
            end
        end
    end
    for name, id in pairs(ns.db.itemNames or {}) do nameIndex[name] = nameIndex[name] or id end
    for _, list in pairs(ns.db.recipeDB or {}) do
        for _, packed in pairs(list) do
            for id in packed:gmatch("(%d+):") do add(tonumber(id)) end
        end
    end
    return nameIndex
end

-- Recipes we read but whose items we can't name yet:
-- prof -> product name -> "req|reagent name:count;..."
-- Item names shipped with the addon (Data/ItemNames.lua, from Questie),
-- turned into a table the first time a recipe needs one
local shippedNames
local function ShippedNames()
    if shippedNames then return shippedNames end
    shippedNames = {}
    for id, name in (GathercraftItemNames or ""):gmatch("(%d+)\t([^\r\n]+)") do
        shippedNames[name:lower()] = tonumber(id)
    end
    return shippedNames
end

-- Tooltip text can carry escape codes: |n (line break), |cffRRGGBB ... |r
local function CleanName(name)
    name = name:gsub("|n", " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return Trim(name)
end

-- item ID -> (English) name from the shipped list, for items not loaded yet
local shippedById
ns.ShippedItemName = function(id)
    if not shippedById then
        shippedById = {}
        for sid, name in (GathercraftItemNames or ""):gmatch("(%d+)\t([^\r\n]+)") do shippedById[tonumber(sid)] = name end
    end
    return shippedById[id]
end

-- name -> item ID: what we noted, the shipped list, else ask the game
local function Lookup(idx, name)
    name = CleanName(name)
    local key = name:lower()
    if idx[key] then return idx[key] end
    local shipped = ShippedNames()[key]
    if shipped then return shipped end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if getInfo then
        local ok, _, link = pcall(getInfo, name)
        local id = ok and ItemIDFromLink(link)
        if id then
            ns.NoteItemName(name, id)
            return id
        end
    end
end

local function TryResolve(prof, product, req, reagents)
    product = CleanName(product)
    local idx = NameIndex()
    local productID = Lookup(idx, product)
    local parts = {}
    for _, r in ipairs(reagents) do
        local id = Lookup(idx, r[1])
        if not id then return false end
        parts[#parts + 1] = id .. ":" .. r[2]
    end
    -- a recipe we ship: its product is known (0 for enchants), in any language
    if not productID then
        local profKey = ProfKey(prof)
        local shipped = GathercraftRecipeData and GathercraftRecipeData.professions
        local packed = shipped and shipped[profKey] and shipped[profKey][Canon(profKey, product)]
        if packed then productID = tonumber(packed:match("^(%d+)")) end
    end
    -- enchants make no item: product 0, we still know what the materials cost
    if not productID and product:find("^Enchant ") then productID = 0 end
    if not productID then return false end
    MergeRecipe(prof, product, productID, nil, nil, req, table.concat(parts, ","))
    return true
end

local lastIndexBuild
local function RememberRecipe(prof, req, product, reagents)
    if ns.db.recipeDB and ns.db.recipeDB[prof] and ns.db.recipeDB[prof][product] then
        if req and req > 0 then MergeRecipe(prof, product, tonumber(ns.db.recipeDB[prof][product]:match("^(%d+)")), nil, nil, req,
            ns.db.recipeDB[prof][product]:match("|(.*)$")) end
        return true
    end
    local resolved = TryResolve(prof, product, req, reagents)
    if not resolved and (not lastIndexBuild or GetTime() - lastIndexBuild > 10) then
        -- items seen since the last look (AH, bags) may name it now
        lastIndexBuild = GetTime()
        NameIndex(true)
        resolved = TryResolve(prof, product, req, reagents)
    end
    if resolved then
        ns.Debug(("RECIPE %s (%s %d) added"):format(product, prof, req or 0))
        if ns.RefreshCraftPage then ns.RefreshCraftPage() end
        return true
    end
    ns.db.recipePending = ns.db.recipePending or {}
    ns.db.recipePending[prof] = ns.db.recipePending[prof] or {}
    local parts = {}
    for _, r in ipairs(reagents) do parts[#parts + 1] = r[1] .. ":" .. r[2] end
    ns.db.recipePending[prof][product] = (req or 0) .. "|" .. table.concat(parts, ";")
    return false
end
ns.RememberRecipe = RememberRecipe
ns.InvalidateNameIndex = function() lastIndexBuild = nil end
-- Item names we have seen, kept across sessions: the game only knows names
-- of items it has loaded, and recipe tooltips give names, not links.
ns.NoteItemName = function(name, id)
    if not (name and id) or name == "" then return end
    local key = name:lower()
    ns.db.itemNames = ns.db.itemNames or {}
    if ns.db.itemNames[key] ~= id then ns.db.itemNames[key] = id end
    if nameIndex then nameIndex[key] = id end
end

ns.NoteReagentName = function(name, id) ns.NoteItemName(name, id) end
local function ResolvePendingLater() if ns.ResolvePending then ns.ResolvePending() end end

-- Names of items with an auction price that we don't have yet: ask the
-- game to load them (a few per frame), note each one as it arrives.
local nameWaiting, nameLoading, resolveQueued = {}, false, false
local function OnItemLoaded(id)
    if not nameWaiting[id] then return end
    nameWaiting[id] = nil
    local name = C_Item.GetItemNameByID(id)
    if name then ns.NoteItemName(name, id) end
    -- names arrive one by one: look at the waiting recipes once they settle
    if not resolveQueued then
        resolveQueued = true
        C_Timer.After(2, function() resolveQueued = false; ResolvePendingLater() end)
    end
end
local function LearnPriceNames()
    if nameLoading or not (C_Item and C_Item.GetItemNameByID) then return end
    local have = {}
    for _, id in pairs(ns.db.itemNames or {}) do have[id] = true end
    local ids = {}
    for _, p in pairs(ns.db.prices or {}) do
        for id in pairs(p.items or {}) do
            if not have[id] then ids[#ids + 1] = id; have[id] = true end
        end
    end
    if #ids == 0 then return end
    nameLoading = true
    local i = 0
    local function step()
        for _ = 1, 40 do
            i = i + 1
            local id = ids[i]
            if not id then
                nameLoading = false
                ns.Debug(("NAMES learned, %d still loading"):format((function() local n = 0 for _ in pairs(nameWaiting) do n = n + 1 end return n end)()))
                C_Timer.After(3, ResolvePendingLater)
                return
            end
            local name = C_Item.GetItemNameByID(id)
            if name then
                ns.NoteItemName(name, id)
            elseif C_Item.RequestLoadItemDataByID then
                nameWaiting[id] = true
                pcall(C_Item.RequestLoadItemDataByID, id)
            end
        end
        C_Timer.After(0.05, step)
    end
    step()
end
ns.LearnPriceNames = LearnPriceNames

-- try the waiting ones again (after scans, vendor visits, ...)
local function ResolvePending()
    if not ns.db.recipePending then return end
    NameIndex(true)
    local added = 0
    for prof, list in pairs(ns.db.recipePending) do
        for product, packed in pairs(list) do
            local req, rest = packed:match("^(%d+)|(.*)$")
            local reagents = {}
            for name, n in (rest or ""):gmatch("([^;]+):(%d+)") do reagents[#reagents + 1] = { name, tonumber(n) } end
            if TryResolve(prof, product, tonumber(req), reagents) then
                list[product] = nil
                added = added + 1
            end
        end
    end
    if added > 0 then
        ns.Print((L["Added %d waiting recipes, their items are known now."]):format(added))
        if ns.RefreshCraftPage then ns.RefreshCraftPage() end
    end
end
ns.ResolvePending = ResolvePending

local function TooltipLines(itemID)
    if not (C_TooltipInfo and C_TooltipInfo.GetItemByID) then return end
    local ok, data = pcall(C_TooltipInfo.GetItemByID, itemID)
    if not ok or not data or not data.lines then return end
    local lines = {}
    for _, line in ipairs(data.lines) do lines[#lines + 1] = line.leftText or "" end
    return lines
end

local function ReadRecipeItem(itemID)
    local lines = TooltipLines(itemID)
    if not lines then return end
    local prof, req, product, reagents = ParseRecipeLines(lines)
    if prof then RememberRecipe(prof, req, product, reagents) end
end

-- Every recipe item we know a price for (auction house), a few per frame
local function ReadRecipeItemsFromPrices()
    local ids = {}
    for _, p in pairs(ns.db.prices or {}) do
        for id in pairs(p.items or {}) do
            local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
            if IsRecipeName(name) then ids[#ids + 1] = id end
        end
    end
    local i = 0
    local function step()
        for _ = 1, 10 do
            i = i + 1
            if not ids[i] then
                ResolvePending()
                return
            end
            ReadRecipeItem(ids[i])
        end
        C_Timer.After(0.05, step)
    end
    step()
end

-- hovering a recipe item reads it too
local function OnTooltipLines(lines)
    local prof, req, product, reagents = ParseRecipeLines(lines)
    if prof then RememberRecipe(prof, req, product, reagents) end
end
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if not (ns.db and data and data.lines) then return end
        local lines = {}
        for _, line in ipairs(data.lines) do lines[#lines + 1] = line.leftText or "" end
        pcall(OnTooltipLines, lines)
    end)
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT", "PLAYER_LOGIN", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED", "NEW_RECIPE_LEARNED", "CRAFT_SHOW", "CRAFT_UPDATE", "MERCHANT_SHOW",
    "TRAINER_SHOW", "TRAINER_UPDATE", "TRAINER_CLOSED", "AUCTION_HOUSE_CLOSED" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
        if arg1 then OnItemLoaded(arg1) end
    elseif event == "PLAYER_LOGIN" then
        C_Timer.After(20, function()
            if not ns.db then return end
            -- older versions took the "Use:" line of enchanting formulas as the item
            for _, list in pairs(ns.db.recipePending or {}) do
                for product in pairs(list) do
                    if product:find("^Use:") or product:find("\n") then list[product] = nil end
                end
            end
            LearnPriceNames()
        end)
    elseif event == "MERCHANT_SHOW" then
        LearnMerchant()
        -- recipe items this vendor sells
        for i = 1, (GetMerchantNumItems and GetMerchantNumItems()) or 0 do
            local name = MerchantItem(i)
            local id = ItemIDFromLink(GetMerchantItemLink and GetMerchantItemLink(i))
            if id and IsRecipeName(name) then ReadRecipeItem(id) end
        end
        C_Timer.After(1, ResolvePending)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        C_Timer.After(1, ReadRecipeItemsFromPrices)
        C_Timer.After(2, LearnPriceNames)
    elseif event == "TRAINER_SHOW" then
        lastTrainerCount, trainerToldEmpty = nil, false
        LearnPriceNames()
        C_Timer.After(0.3, ReadTrainer)
    elseif event == "TRAINER_UPDATE" then
        if not readingTrainer then QueueTrainerRead() end
    elseif event == "TRAINER_CLOSED" then
        lastTrainerCount, trainerToldEmpty = nil, false
    elseif event == "CRAFT_SHOW" or event == "CRAFT_UPDATE" then
        Schedule(ReadCraft)
    else
        Schedule(nil)
    end
end)

---------------------------------------------------------------------------
-- The numbers
---------------------------------------------------------------------------
local function Have(itemID)
    if C_Item and C_Item.GetItemCount then
        local ok, n = pcall(C_Item.GetItemCount, itemID, true)
        if ok and n then return n end
    end
    return GetItemCount and GetItemCount(itemID, true) or 0
end

-- What one reagent costs to get: copper, source, guessed?
local function ReagentCost(itemID)
    local vendor = ns.db.vendorPrices and ns.db.vendorPrices[itemID]
    local ah, source = ns.GetPrice(itemID)
    if source == "vendor" then ah, source = nil, nil end -- that's a sell price, not a buy price
    if vendor and (not ah or vendor <= ah) then return vendor, "vendor" end
    if ah then return ah, source end
    if VENDOR_REAGENTS[itemID] then
        local _, sellSource = ns.GetPrice(itemID)
        local sell = sellSource == "vendor" and select(1, ns.GetPrice(itemID))
        if sell then return sell * VENDOR_MARKUP, L["vendor (est.)"], true end
    end
    return nil
end

local function Unpack(packed)
    local head, reagentText = packed:match("^([^|]+)|(.*)$")
    if not head then return end
    local product, nMin, nMax, extra = head:match("^(%d+):(%d+):(%d+):(%d+)$")
    if not product then return end
    local reagents = {}
    for id, n in (reagentText or ""):gmatch("(%d+):(%d+)") do
        reagents[#reagents + 1] = { id = tonumber(id), n = tonumber(n) }
    end
    return tonumber(product), (tonumber(nMin) + tonumber(nMax)) / 2, tonumber(extra), reagents
end

-- Every recipe of a profession we know of: name -> packed (shipped data,
-- account recipe book, this character's own recipes)
local function AllRecipes(prof)
    local out = {}
    local shipped = GathercraftRecipeData and GathercraftRecipeData.professions
    for name, packed in pairs((shipped and shipped[prof]) or {}) do out[name] = packed end
    for name, packed in pairs((ns.db.recipeDB and ns.db.recipeDB[prof]) or {}) do out[name] = packed end
    return out
end

local function KnownProfessions()
    local set = {}
    local shipped = GathercraftRecipeData and GathercraftRecipeData.professions
    for prof in pairs(shipped or {}) do set[prof] = true end
    for prof in pairs(ns.db.recipeDB or {}) do set[prof] = true end
    for prof in pairs(CharRecipes()) do set[prof] = true end
    return set
end

-- One profession (or nil = the ones this character has), with numbers,
-- best profit first. mineOnly = only recipes this character knows.
local function Evaluate(profFilter, mineOnly)
    local rows = {}
    local mine = CharRecipes()
    local profs = {}
    if profFilter then
        profs[1] = profFilter
    else
        for prof in pairs(mine) do profs[#profs + 1] = prof end
    end
    for _, prof in ipairs(profs) do
        local known = mine[prof] and mine[prof].list or {}
        local all = AllRecipes(prof)
        for name, packed in pairs(known) do all[name] = all[name] or packed end
        for name, packed in pairs(all) do
            local learned = known[name] ~= nil
            if learned or not mineOnly then
                local product, made, req, reagents = Unpack(packed)
                local diff
                if learned then
                    local _, kMade, kDiff = Unpack(known[name])
                    diff, made = kDiff, kMade or made
                    if all[name] == known[name] then req = nil end -- own data has no required skill
                end
                local price, source = nil, nil
                local enchant = product == 0
                if product and not enchant then price, source = ns.GetPrice(product) end
                if product and #reagents > 0 then
                    local value = (price or 0) * made * (source == "vendor" and 1 or AH_CUT)
                    local cost, missing, guessed, canMake = 0, not price and not enchant, false, math.huge
                    local parts = {}
                    for _, r in ipairs(reagents) do
                        local c, from, guess = ReagentCost(r.id)
                        if c then cost = cost + c * r.n else missing = true end
                        guessed = guessed or guess
                        local have = Have(r.id)
                        canMake = math.min(canMake, math.floor(have / r.n))
                        parts[#parts + 1] = { id = r.id, n = r.n, cost = c, from = from, have = have }
                    end
                    -- estimated in the shipped data and not yet seen at a trainer?
                    local ownReq = ns.db.recipeDB and ns.db.recipeDB[prof] and ns.db.recipeDB[prof][name]
                    local shippedGuess = GathercraftRecipeData and GathercraftRecipeData.guessed
                        and GathercraftRecipeData.guessed[prof] and GathercraftRecipeData.guessed[prof][name]
                    local reqGuessed = shippedGuess and not (ownReq and ownReq:match("^%d+:%d+:%d+:(%d+)") ~= "0") or false
                    rows[#rows + 1] = {
                        prof = prof, name = DisplayName(prof, name), key = name, product = product, made = made, diff = diff, req = req, reqGuessed = reqGuessed,
                        learned = learned, value = value, valueSource = source, cost = cost, enchant = enchant,
                        profit = value - cost, missing = missing, guessed = guessed,
                        canMake = canMake == math.huge and 0 or canMake, reagents = parts,
                    }
                end
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.missing ~= b.missing then return not a.missing end
        if a.enchant ~= b.enchant then return not a.enchant end
        if math.abs(a.profit - b.profit) > 0.5 then return a.profit > b.profit end
        return a.name < b.name
    end)
    return rows
end

local function Professions()
    local list = {}
    for prof in pairs(CharRecipes()) do list[#list + 1] = prof end
    table.sort(list)
    return list
end

---------------------------------------------------------------------------
-- /gcr crafttest : what this client offers in the profession window
---------------------------------------------------------------------------
local function CraftTest()
    ns.Print("Crafting check (open a profession window first)")
    local api = C_TradeSkillUI
    local function Check(label, value) print(("  %s: %s"):format(label, value and "|cff00ff00yes|r" or "|cffff5555no|r")) end
    Check("C_TradeSkillUI.GetAllRecipeIDs (modern)", api and api.GetAllRecipeIDs)
    Check("C_TradeSkillUI.GetRecipeSchematic", api and api.GetRecipeSchematic)
    Check("GetNumTradeSkills (classic)", GetNumTradeSkills)
    Check("GetNumCrafts (classic enchanting)", GetNumCrafts)
    local prof, recipes = ReadModern()
    local n = 0
    for _ in pairs(recipes or {}) do n = n + 1 end
    print(("  modern reader: %s, %d recipes"):format(tostring(prof), n))
    prof, recipes = ReadClassic()
    n = 0
    for _ in pairs(recipes or {}) do n = n + 1 end
    print(("  classic reader: %s, %d recipes"):format(tostring(prof), n))
    for p, data in pairs(CharRecipes()) do
        local c = 0
        for _ in pairs(data.list or {}) do c = c + 1 end
        print(("  stored: %s %d recipes"):format(p, c))
    end
    local rows = Evaluate()
    for i = 1, math.min(3, #rows) do
        local r = rows[i]
        print(("  %d. %s: profit %s (sells %s, costs %s)"):format(i, r.name, ns.Money(r.profit), ns.Money(r.value), ns.Money(r.cost)))
    end
end

---------------------------------------------------------------------------
-- Page in the main window ("Crafting" tab)
---------------------------------------------------------------------------
local ROW_H = 24

ns.BuildCraftPage = function(page, style)
    local header = style.header(page, "What's best to craft?", 4, -2)
    style.divider(page, header)

    local sub = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 6, -28)
    sub:SetWidth(520)
    sub:SetJustifyH("LEFT")

    local filter = "mine" -- "mine" = my professions, or a profession name
    local mineOnly = false
    local tabs = {}
    local Refresh

    -- Sub tabs: my professions + every profession, with its icon
    local function SubTab(i, key, label, icon, full)
        local b = tabs[i]
        if not b then
            b = CreateFrame("Button", nil, page, "BackdropTemplate")
            b:SetSize(68, 42)
            b:SetPoint("TOPLEFT", 2 + (i - 1) * 70, -44)
            b:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 10,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetSize(20, 20)
            b.icon:SetPoint("TOP", 0, -4)
            b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            b.text:SetPoint("BOTTOM", 0, 4)
            b.text:SetWidth(66)
            b.text:SetWordWrap(false)
            local hl = b:CreateTexture(nil, "HIGHLIGHT")
            hl:SetPoint("TOPLEFT", 3, -3)
            hl:SetPoint("BOTTOMRIGHT", -3, 3)
            hl:SetColorTexture(1, 0.8, 0.3, 0.12)
            tabs[i] = b
        end
        b.icon:SetTexture(icon)
        b.text:SetText(L[label])
        -- long names: smaller letters, full name on hover
        if not b.baseFont and b.text.GetFont then b.baseFont = { b.text:GetFont() } end
        local font, size, flags = unpack(b.baseFont or {})
        if font and size then
            b.text:SetFont(font, size, flags)
            while b.text:GetStringWidth() > 64 and size > 7 do
                size = size - 1
                b.text:SetFont(font, size, flags)
            end
        end
        b.full = full or label
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(self.full, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", function()
            filter = key
            ns.db.craftTab = key
            Refresh()
        end)
        local selected = filter == key
        if selected then
            b:SetBackdropColor(0.42, 0.10, 0.04, 1)
            b:SetBackdropBorderColor(1, 0.82, 0.3, 1)
            b.text:SetTextColor(1, 0.95, 0.8)
        else
            b:SetBackdropColor(0.10, 0.09, 0.08, 1)
            b:SetBackdropBorderColor(0.40, 0.38, 0.35, 1)
            b.text:SetTextColor(1, 0.82, 0.3)
        end
        b:Show()
    end

    local mineCheck = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    mineCheck:SetSize(22, 22)
    mineCheck:SetPoint("TOPRIGHT", -150, -22)
    local mineLabel = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mineLabel:SetPoint("LEFT", mineCheck, "RIGHT", 2, 0)
    ns.LText(mineLabel, "Only recipes I know")
    mineCheck:SetScript("OnClick", function(self)
        mineOnly = self:GetChecked() and true or false
        ns.db.craftMineOnly = mineOnly
        Refresh()
    end)

    local function Col(text, x, width, justify)
        local fs = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", x, -94)
        fs:SetWidth(width)
        fs:SetJustifyH(justify or "LEFT")
        ns.LText(fs, text)
    end
    Col("Item", 30, 330)
    Col("Profit", 364, 80, "RIGHT")
    Col("Sells for", 448, 80, "RIGHT")
    Col("Costs", 532, 80, "RIGHT")
    Col("Can make", 616, 80, "RIGHT")

    local scroll = CreateFrame("ScrollFrame", "GathercraftCraftScroll", page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -110)
    scroll:SetPoint("BOTTOMRIGHT", -24, 34)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(700, 10)
    scroll:SetScrollChild(content)

    local function ShowTooltip(row)
        local r = row.data
        if not r then return end
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:AddLine(r.name, 1, 1, 1)
        GameTooltip:AddLine((L["%s · makes %s"]):format(ProfLabel(r.prof), r.made % 1 == 0 and tostring(r.made) or ("%.1f"):format(r.made)), 0.7, 0.7, 0.7)
        if r.learned then
            GameTooltip:AddLine(L["You know this recipe"], 0.4, 1, 0.4)
        else
            GameTooltip:AddLine(L["Not learned"] .. ((r.req and r.req > 0) and (L[" · needs skill "] .. (r.reqGuessed and "~" or "") .. r.req) or ""), 0.8, 0.8, 0.8)
            if r.reqGuessed then
                GameTooltip:AddLine(L["Estimated for Forever. Visit the trainer once and Gathercraft notes the real value."], 0.6, 0.6, 0.6, true)
            end
        end
        if r.enchant then
            GameTooltip:AddLine(L["Enchant: makes no item. Below is what the materials cost, handy for pricing your service."], 0.6, 0.8, 1, true)
        end
        if not r.enchant then GameTooltip:AddDoubleLine(L["Sells for"], ns.Money(r.value) .. "  |cff999999(" .. tostring(r.valueSource)
            .. (r.valueSource ~= "vendor" and L[", after 5% AH cut"] or "") .. ")|r", 1, 0.82, 0, 1, 1, 1) end
        GameTooltip:AddLine(" ")
        for _, p in ipairs(r.reagents) do
            local name = ns.ItemName and ns.ItemName(p.id) or (L["item "] .. p.id)
            local haveColor = p.have >= p.n and "|cff55ff55" or "|cffff7070"
            GameTooltip:AddDoubleLine((L["%dx %s  %s(have %d)|r"]):format(p.n, name, haveColor, p.have),
                p.cost and (ns.Money(p.cost * p.n) .. "  |cff999999" .. p.from .. "|r") or L["|cffff7070no price|r"],
                1, 1, 1, 1, 1, 1)
        end
        GameTooltip:AddLine(" ")
        if r.enchant then
            GameTooltip:AddDoubleLine(L["Materials"], ns.Money(r.cost), 1, 0.82, 0, 1, 1, 1)
        else GameTooltip:AddDoubleLine(L["Profit per craft"], (r.profit >= 0 and "|cff55ff55" or "|cffff7070") .. ns.Money(math.abs(r.profit))
            .. (r.profit < 0 and L[" loss"] or "") .. "|r", 1, 0.82, 0, 1, 1, 1) end
        if r.guessed then GameTooltip:AddLine(L["Vendor price estimated: visit a vendor that sells it to learn the real one."], 0.6, 0.6, 0.6, true) end
        if r.missing then GameTooltip:AddLine(L["Some reagents have no price yet: scan the auction house."], 1, 0.5, 0.5, true) end
        GameTooltip:Show()
    end

    local rows = {}
    local function Row(i)
        if rows[i] then return rows[i] end
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(700, ROW_H)
        row:SetPoint("TOPLEFT", 4, -(i - 1) * ROW_H)
        row:EnableMouse(true)
        row:SetScript("OnEnter", ShowTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(1, 0.8, 0.3, i % 2 == 0 and 0.035 or 0)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 2, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local function Text(x, width, justify)
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            fs:SetPoint("LEFT", x, 0)
            fs:SetWidth(width)
            fs:SetJustifyH(justify)
            fs:SetWordWrap(false)
            return fs
        end
        row.name = Text(26, 330, "LEFT")
        row.profit = Text(360, 80, "RIGHT")
        row.value = Text(444, 80, "RIGHT")
        row.cost = Text(528, 80, "RIGHT")
        row.can = Text(612, 80, "RIGHT")
        rows[i] = row
        return row
    end

    local empty = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOPLEFT", 8, -120)
    empty:SetWidth(680)
    empty:SetJustifyH("LEFT")

    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 6, 6)
    hint:SetWidth(710)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["Colored names: recipes you know (color = skill-up chance). Grey: not learned yet, with the skill it needs. "] ..
        L["Hover a line for the reagents. \"Can make\" counts bags and bank. Visit trainers to add their recipes."])

    Refresh = function()
        filter = filter == "mine" and (ns.db.craftTab or "mine") or filter
        mineOnly = ns.db.craftMineOnly or false
        mineCheck:SetChecked(mineOnly)
        -- sub tabs: mine, the nine professions, then any other we have data for
        SubTab(1, "mine", "Mine", "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\IconRound")
        local i, listed = 1, {}
        for _, p in ipairs(PROFESSIONS) do
            i = i + 1
            local full = p.name == "Mining" and L["Smelting"] or p.name
            local label = p.short
            if not englishClient then
                local loc = SpellNameOf(p.name == "Mining" and 2656 or PROF_SPELLS[p.name])
                if loc and loc ~= "" then full = loc end
                label = (SHORT_LABELS[GetLocale()] or {})[p.name] or full
            full = (FULL_LABELS[GetLocale()] or {})[p.name] or full
            end
            SubTab(i, p.name, label, p.icon, full)
            listed[p.name] = true
        end
        for prof in pairs(KnownProfessions()) do
            if not listed[prof] and i < 10 then
                i = i + 1
                SubTab(i, prof, prof, "Interface\\Icons\\INV_Misc_QuestionMark")
            end
        end
        for j = i + 1, #tabs do tabs[j]:Hide() end

        sub:SetText((L["Profit after the 5%% auction cut  ·  %s"]):format(ns.PriceSourceText and ns.PriceSourceText() or ""))

        local list = Evaluate(filter ~= "mine" and filter or nil, filter == "mine" or mineOnly)
        for i, r in ipairs(list) do
            local row = Row(i)
            row.data = r
            row.icon:SetTexture(r.enchant and "Interface\\Icons\\Trade_Engraving"
                or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(r.product)) or 134400)
            if r.learned then
                row.name:SetText((DIFF_COLORS[r.diff] or "|cffffffff") .. r.name .. "|r")
            else
                row.name:SetText("|cffa0a0a0" .. r.name .. "|r" .. ((r.req and r.req > 0) and ("  |cff777777(" .. (r.reqGuessed and "~" or "") .. r.req .. ")|r") or ""))
            end
            if r.enchant then
                row.profit:SetText(r.missing and L["|cff777777?|r"] or L["|cff777777-|r"])
            elseif r.missing then
                ns.LText(row.profit, "|cff777777?|r")
            elseif r.profit >= 0 then
                row.profit:SetText("|cff55ff55" .. ns.Money(r.profit, true) .. "|r")
            else
                row.profit:SetText(L["|cffff7070-"] .. ns.Money(-r.profit, true) .. "|r")
            end
            row.value:SetText(r.enchant and L["|cff99ccffEnchant|r"] or ns.Money(r.value, true))
            row.cost:SetText((r.guessed and "~" or "") .. ns.Money(r.cost, true))
            row.can:SetText(r.canMake > 0 and (L["|cffffffff%d|r"]):format(r.canMake) or L["|cff7777770|r"])
            row:Show()
        end
        for i = #list + 1, #rows do rows[i]:Hide() end
        content:SetHeight(math.max(10, #list * ROW_H))
        if #list == 0 then
            local knowsHere = filter ~= "mine" and CharRecipes()[filter] and next(CharRecipes()[filter].list or {})
            empty:SetText(filter == "mine" and #Professions() == 0
                and L["Open a profession window (e.g. Alchemy) so Gathercraft can read your recipes."]
                or filter ~= "mine" and mineOnly and not knowsHere
                and (L["You don't know any %s recipes on this character yet. Untick \"Only recipes I know\" to see all of them."]):format(filter)
                or filter ~= "mine" and not next(AllRecipes(filter))
                and L["No recipes for this profession yet. Visit its trainer once (any character) to add them."]
                or L["No recipe with a known price yet. Scan the auction house (Gathercraft tab there)."])
            empty:Show()
        else
            empty:Hide()
        end
    end

    page:SetScript("OnShow", Refresh)
    ns.RefreshCraftPage = function()
        if page:IsVisible() then Refresh() end
    end
    return Refresh
end

-- /gcr recipetest : hover a recipe item (bag, vendor, auction house) and type
-- this, to see what the client tells addons about it
ns.RecipeTest = function()
    local _, link = GameTooltip:GetItem()
    local id = ItemIDFromLink(link)
    ns.Print("Recipe check" .. (id and (" for item " .. id) or " (hover a recipe item first)"))
    if not id then return end
    local classID, subID = select(6, C_Item.GetItemInfoInstant(id))
    print(("  item class %s / %s (recipes are class 9)"):format(tostring(classID), tostring(subID)))
    local spellName, spellID = GetItemSpell and GetItemSpell(id)
    print(("  GetItemSpell: %s (%s)"):format(tostring(spellName), tostring(spellID)))
    local api = C_TradeSkillUI
    if api and api.GetRecipeSchematic and spellID then
        local ok, sch = pcall(api.GetRecipeSchematic, spellID, false)
        print(("  GetRecipeSchematic: %s, product %s"):format(tostring(ok and sch ~= nil), tostring(ok and sch and sch.outputItemID)))
    else
        print("  GetRecipeSchematic: not available")
    end
    print(("  C_TooltipInfo: %s"):format(tostring(C_TooltipInfo ~= nil)))
    for i = 1, GameTooltip:NumLines() do
        local left = _G["GameTooltipTextLeft" .. i]
        local text = left and left:GetText()
        if text then print(("  line %d: %s"):format(i, text)) end
    end
end

ns.CraftAdvice = Evaluate
ns.CraftTest = CraftTest

-- /gcr trainertest : what this client tells us at a trainer (window open)
ns.TrainerTest = function()
    ns.Print("Trainer check (talk to a profession trainer first)")
    ResolvePending()
    local function Has(n) return _G[n] and "|cff00ff00yes|r" or "|cffff5555no|r" end
    for _, n in ipairs({ "GetNumTrainerServices", "GetTrainerServiceInfo", "GetTrainerServiceItemLink",
        "GetTrainerServiceSkillReq", "GetTrainerServiceNumReagents", "GetTrainerServiceReagentInfo",
        "GetTrainerServiceReagentLink", "IsTradeskillTrainer", "GetTrainerServiceTypeFilter" }) do
        print(("  %s: %s"):format(n, Has(n)))
    end
    if IsTradeskillTrainer then print("  IsTradeskillTrainer(): " .. tostring(IsTradeskillTrainer())) end
    if GetTrainerServiceTypeFilter then
        for _, t in ipairs({ "available", "unavailable", "used" }) do
            local ok, v = pcall(GetTrainerServiceTypeFilter, t)
            print(("  filter %s: %s %s"):format(t, tostring(ok), tostring(v)))
        end
    end
    local num = GetNumTrainerServices and GetNumTrainerServices() or 0
    print("  services: " .. tostring(num) .. "   title: " .. tostring((TrainerProfession())))
    local shown = 0
    for i = 1, num do
        local name, sub, kind = GetTrainerServiceInfo(i)
        if kind ~= "header" and shown < 4 then
            shown = shown + 1
            local link = GetTrainerServiceItemLink and GetTrainerServiceItemLink(i)
            local skill, req = nil, nil
            if GetTrainerServiceSkillReq then skill, req = GetTrainerServiceSkillReq(i) end
            local nr = GetTrainerServiceNumReagents and GetTrainerServiceNumReagents(i)
            print(("  #%d %s [%s] item=%s skill=%s %s reagents=%s"):format(i, tostring(name), tostring(kind),
                tostring(link and link:match("item:%d+")), tostring(skill), tostring(req), tostring(nr)))
            for n, text in ipairs(TrainerTooltipLines(i)) do
                if n <= 8 then print(("     tip %d: %s"):format(n, text)) end
            end
            if nr and nr > 0 then
                local rn, _, rc = GetTrainerServiceReagentInfo(i, 1)
                local rl = GetTrainerServiceReagentLink and GetTrainerServiceReagentLink(i, 1)
                print(("     reagent 1: %s x%s %s"):format(tostring(rn), tostring(rc), tostring(rl and rl:match("item:%d+"))))
            end
        end
    end
    local db = ns.db.recipeDB or {}
    local parts = {}
    for prof, list in pairs(db) do
        local n = 0
        for _ in pairs(list) do n = n + 1 end
        parts[#parts + 1] = prof .. " " .. n
    end
    print("  saved: " .. (#parts > 0 and table.concat(parts, ", ") or "nothing yet"))
    local names = 0
    for _ in pairs(ns.db.itemNames or {}) do names = names + 1 end
    print("  item names known: " .. names)
    local idx = NameIndex(true)
    local missing, shownMissing, pendingCount = {}, 0, 0
    for _, list in pairs(ns.db.recipePending or {}) do
        for product, packed in pairs(list) do
            if not Lookup(idx, product) and not product:find("^Enchant ") then missing[product] = true end
            for nm in (packed:match("|(.*)$") or ""):gmatch("([^;]+):%d+") do
                if not Lookup(idx, nm) then missing[nm] = true end
            end
            pendingCount = pendingCount + 1
        end
    end
    local out = {}
    for nm in pairs(missing) do
        shownMissing = shownMissing + 1
        if shownMissing <= 12 then out[#out + 1] = nm end
    end
    print(("  %d recipes waiting for %d item names: %s"):format(pendingCount, shownMissing, table.concat(out, ", ")))
    local nWait = 0
    for _ in pairs(nameWaiting) do nWait = nWait + 1 end
    print(("  names still loading: %d"):format(nWait))
end
