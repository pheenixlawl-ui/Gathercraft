local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Gathercraft's lines in item tooltips (0.2 B2 C4)
--   One hook, one renderer, sections in a fixed order:
--     1. the price: for every item we have an own auction price of - what
--        kind of price it is, how old, how many were listed, and which
--        price is really used when it is not ours
--     2. for herbs, ores and reagents the block: the price line also
--        without an own price, the last 14 days, and with Shift the last 7
--        days, the zone with the most known spawn points and the
--        professions that use it
--   (a later building block adds a third section; the list below is where)
--
--   What is true must be said, what is not known is "unknown" or "?":
--   a browse list's lowest offer is no market price, a quantity only shows
--   with the price it was seen with, an age nobody tells is no "today".
--
--   Cheap while hovering: the price is asked for anew every time (so the 6
--   hour and 7 day borders and a change in Auctionator show without a
--   scan), everything else is read from caches that know when they are
--   old: the price revision and the UTC day, the spawn count revision and
--   the continent, the recipe revision, the language. The indexes behind
--   them are built after login in small steps - and not at all while the
--   option is off.
---------------------------------------------------------------------------
local floor = math.floor
local HEADER = "|cffffd060Gathercraft|r"
local GREY, ORANGE, CLOSE = "|cff999999", "|cffff8040", "|r"
local SEP = " · "
local RECIPES_PER_STEP = 150 -- recipes read per build step
local STEP = 0.05            -- seconds between build steps
local LOGIN_DELAY = 1        -- seconds after login before the build starts

local state = "off"          -- "off", "building", "ready"
local run = 0                -- counts up with every start and stop: steps of an older build end themselves
local loggedIn = false
local buildMs, buildCount = 0, 0
local gather                 -- itemID -> true: the main item of a herb or ore node kind
local usedIn                 -- itemID -> { profession -> number of recipes }; nil while it is built
local usedBuild = 0          -- counts up with every finished recipe index
local builtRecipeRev         -- the recipe revision the index was built from
local recipeCount, reagentCount = 0, 0
local langRev = 0
local continent = 0          -- the player's continent (0: not known)

local function Enabled()
    return not (ns.db and ns.db.tooltipPrices == false)
end

---------------------------------------------------------------------------
-- The indexes: which items get the block, which professions use an item
---------------------------------------------------------------------------
local function Build(myRun)
    local d = ns.CraftData
    local t0 = debugprofilestop()
    state, usedIn = "building", nil
    if not gather then
        local g = {}
        local data = GathercraftQuestieData
        for _, kind in pairs((data and data.kinds) or {}) do
            if (kind[1] == "h" or kind[1] == "o") and kind[2] > 0 then g[kind[2]] = true end
        end
        gather = g
    end
    local startRev = ns.RecipeRev and ns.RecipeRev() or 0
    local profs = {}
    for _, p in ipairs((d and d.Professions) or {}) do profs[#profs + 1] = p.name end
    local index, recipes, reagents = {}, 0, 0
    local pi, list, key, prof = 0, nil, nil, nil
    buildMs = buildMs + (debugprofilestop() - t0)
    local function Step()
        if myRun ~= run then return end
        local s0 = debugprofilestop()
        local budget = RECIPES_PER_STEP
        while budget > 0 do
            if not list then
                pi = pi + 1
                prof = profs[pi]
                if not prof then
                    usedIn, builtRecipeRev, usedBuild = index, startRev, usedBuild + 1
                    recipeCount, reagentCount = recipes, reagents
                    state = "ready"
                    buildCount = buildCount + 1
                    buildMs = buildMs + (debugprofilestop() - s0)
                    return
                end
                list, key = d.AllRecipes(prof), nil
            end
            local name, packed = next(list, key)
            if name == nil then
                list = nil
            else
                key = name
                budget = budget - 1
                recipes = recipes + 1
                local _, _, _, parts = d.Unpack(packed)
                for i, r in ipairs(parts or {}) do
                    -- (a reagent named twice in one recipe is one recipe)
                    local again = false
                    for j = 1, i - 1 do if parts[j].id == r.id then again = true end end
                    if not again then
                        local u = index[r.id]
                        if not u then
                            u = {}
                            index[r.id] = u
                            reagents = reagents + 1
                        end
                        u[prof] = (u[prof] or 0) + 1
                    end
                end
            end
        end
        buildMs = buildMs + (debugprofilestop() - s0)
        C_Timer.After(STEP, Step)
    end
    C_Timer.After(STEP, Step)
end

local function Start()
    if state ~= "off" or not loggedIn or not Enabled() then return end
    run, buildMs = run + 1, 0
    if ns.SpawnCountsStart then ns.SpawnCountsStart("tooltip") end
    Build(run)
end

local function Stop()
    run = run + 1
    state, gather, usedIn, builtRecipeRev = "off", nil, nil, nil
    if ns.SpawnCountsStop then ns.SpawnCountsStop("tooltip") end
end

-- The option was switched: off ends a running build and drops the indexes,
-- on builds them
ns.ItemTooltipSetEnabled = function(on)
    if ns.db then ns.db.tooltipPrices = on and true or false end
    if on then Start() else Stop() end
end

---------------------------------------------------------------------------
-- Texts
---------------------------------------------------------------------------
local function Ago(secs)
    local mins = floor(secs / 60)
    return mins < 1 and L["just now"] or mins < 60 and (mins .. L[" min ago"])
        or mins < 2880 and (floor(mins / 60) .. L[" h ago"]) or (floor(mins / 1440) .. L[" days ago"])
end

-- "12s 50c  (own scan, 3 h ago, 240 listed)": our own price with what kind
-- of price it is, its age, and the quantity seen with it
local function OwnText(info)
    local kind = info.kind == "market" and L["own scan"] or info.kind == "lowest" and L["lowest offer"] or L["own data"]
    if info.tooOld then
        return ("%s  %s(%s, %s – %s)%s"):format(ns.Money(info.own), ORANGE, kind, Ago(info.ownAge), L["too old, not used"], CLOSE)
    end
    return ("%s  %s(%s, %s, %s)%s"):format(ns.Money(info.own), info.old and ORANGE or GREY, kind, Ago(info.ownAge),
        (L["%s listed"]):format(info.qty and ("%d"):format(info.qty) or "?"), CLOSE)
end

-- The line that says which price is used when it is not our own. Prices
-- of Auctionator and TSM are named, not repeated (their own line shows the
-- number); an age nobody tells is "age unknown", never "today".
local function UsesText(info)
    local source = info.source
    if not source or source == "AH scan" then return end
    if source == "Auctionator" then
        local age, text = info.age, nil
        if type(age) ~= "number" or age ~= age or age == math.huge or age < 0 then
            text = L["age unknown"]
        else
            local days = floor(age / 86400)
            text = days == 0 and L["today"] or days == 1 and L["1 day"] or (L["%d days"]):format(days)
        end
        return (L["uses Auctionator price (%s)"]):format(text)
    elseif source == "TSM" then
        return L["uses TSM DBMarket price (external, age unknown)"]
    elseif source == "auction" then
        return (L["uses auction addon price: %s (age unknown)"]):format(ns.Money(info.used))
    elseif source == "vendor" then
        return (L["uses vendor price: %s"]):format(ns.Money(info.used))
    end
end

-- The last 14 days of an item, worked out once per price revision and UTC
-- day: { days, usual, text14, text7 }
local hist, histRev, histDay, histLang = {}, nil, nil, nil
local function History(itemID)
    local rev, day = ns.PriceRev(), floor(time() / 86400)
    if rev ~= histRev or day ~= histDay or langRev ~= histLang then
        hist, histRev, histDay, histLang = {}, rev, day, langRev
    end
    local h = hist[itemID]
    if h then return h end
    h = { days = 0 }
    local list = ns.PriceHistoryWindow(itemID, day)
    h.days = #list
    if #list > 0 then
        local low, high, byDay = list[1][2], list[1][2], {}
        for _, e in ipairs(list) do
            if e[2] < low then low = e[2] end
            if e[2] > high then high = e[2] end
            byDay[e[1]] = e[2]
        end
        h.usual = ns.UsualPrice(itemID) -- (the median of the days before today in the window, from three days on)
        h.text14 = ("%s  %s(%s)%s"):format(
            (L["low %s · usual %s · high %s"]):format(ns.Money(low), h.usual and ns.Money(h.usual) or "?", ns.Money(high)),
            GREY, #list == 1 and L["1 day with data"] or (L["%d days with data"]):format(#list), CLOSE)
        local parts = {}
        for d = day - 6, day do parts[#parts + 1] = byDay[d] and ns.Money(byDay[d], true) or "–" end
        h.text7 = table.concat(parts, SEP)
    end
    hist[itemID] = h
    return h
end

-- The zone with the most known spawn points: on the player's continent if
-- there is one, else anywhere. nil while the counts are not current.
local zoneText, zoneRev, zoneCont, zoneLang = {}, nil, nil, nil
local function ZoneLine(itemID)
    if not gather[itemID] then return L["unknown (not a gathered item)"] end
    if not ns.SpawnCounts then return end
    local rev = ns.SpawnCountsRev()
    if rev ~= zoneRev or continent ~= zoneCont or langRev ~= zoneLang then
        zoneText, zoneRev, zoneCont, zoneLang = {}, rev, continent, langRev
    end
    local text = zoneText[itemID]
    if text ~= nil then return text or nil end
    local list = ns.SpawnCounts(itemID)
    if not list then return end -- being counted: no line, and nothing kept
    local best
    if continent ~= 0 then
        for _, z in ipairs(list) do
            if ns.GetContinent(z.mapID) == continent then best = z break end
        end
    end
    best = best or list[1]
    if not best then
        text = false
    elseif best.own > 0 and best.questie > 0 then
        text = (L["%s (%d known: Questie data, %d yours)"]):format(ns.GetZoneName(best.mapID), best.total, best.own)
    elseif best.own > 0 then
        text = (L["%s (%d known: yours)"]):format(ns.GetZoneName(best.mapID), best.total)
    else
        text = (L["%s (%d known: Questie data)"]):format(ns.GetZoneName(best.mapID), best.total)
    end
    zoneText[itemID] = text
    return text or nil
end

-- "Alchemy 10 · Cooking 1  (recipe data)": the professions with a recipe
-- that needs the item. nil without one, and while the index is built.
local usedText, usedKey, usedLang = {}, nil, nil
local function UsedLine(itemID)
    local u = usedIn and usedIn[itemID]
    if not u then return end
    if usedKey ~= usedBuild or usedLang ~= langRev then usedText, usedKey, usedLang = {}, usedBuild, langRev end
    local text = usedText[itemID]
    if text then return text end
    local d = ns.CraftData
    local profs = {}
    for prof, n in pairs(u) do
        -- (mining recipes are smelting: that is what the player does with the ore)
        profs[#profs + 1] = { name = prof == "Mining" and L["Smelting"] or d.ProfLabel(prof), n = n }
    end
    table.sort(profs, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.name < b.name
    end)
    local parts = {}
    for _, p in ipairs(profs) do parts[#parts + 1] = p.name .. " " .. p.n end
    text = ("%s  %s(%s)%s"):format(table.concat(parts, SEP), GREY, L["recipe data"], CLOSE)
    usedText[itemID] = text
    return text
end

---------------------------------------------------------------------------
-- The sections
---------------------------------------------------------------------------
local function Label(text) return "  " .. text end

-- 1. The price of an item that gets no block: one line, only when we have
--    a price of our own (as before 0.2), with what is used instead and how
--    it stands against the usual price
local function PriceSection(tooltip, itemID, ctx)
    if ctx.block then return end
    local info = ns.PriceInfo(itemID)
    if not info.own then return end
    local own, tooOld = info.own, info.tooOld
    tooltip:AddDoubleLine(L["|cffffd060Gathercraft|r AH"], OwnText(info), 1, 1, 1, 1, 1, 1)
    local uses = UsesText(info)
    if uses then tooltip:AddLine("    " .. uses, 0.7, 0.7, 0.7) end
    local usual = not tooOld and History(itemID).usual
    if usual and usual > 0 then
        local ratio = own / usual
        if ratio >= 1.2 or ratio <= 0.8 then
            tooltip:AddDoubleLine(L["    usually"], ("%s  %s%+d%%|r"):format(ns.Money(usual), ratio > 1 and "|cff55ff55" or "|cffff7070",
                floor((ratio - 1) * 100 + 0.5)), 0.7, 0.7, 0.7, 1, 1, 1)
        end
    end
    return true
end

-- 2. The block for herbs, ores and reagents
local function BlockSection(tooltip, itemID, ctx)
    if not ctx.block then return end
    local info = ns.PriceInfo(itemID)
    tooltip:AddLine(HEADER)
    tooltip:AddDoubleLine(Label(L["AH price"]), info.own and OwnText(info) or (GREY .. L["unknown – scan at the auction house"] .. CLOSE), 0.8, 0.8, 0.8, 1, 1, 1)
    local uses = UsesText(info)
    if uses then tooltip:AddLine("      " .. uses, 0.7, 0.7, 0.7) end
    local h = History(itemID)
    local days = h.text14
    if not days then
        days = GREY .. ((ns.PriceTracksHistory and not ns.PriceTracksHistory(itemID)) and L["unknown (only trade goods are tracked)"]
            or L["unknown (no price in the last 14 days)"]) .. CLOSE
    end
    tooltip:AddDoubleLine(Label(L["14 days"]), days, 0.8, 0.8, 0.8, 1, 1, 1)
    if not ctx.shift then return true end
    if h.text7 then
        tooltip:AddDoubleLine(Label(L["Last 7 days"]), h.text7, 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddLine("      " .. L["UTC days; own data, scans and lowest offers"], 0.6, 0.6, 0.6)
    end
    local zone = ZoneLine(itemID)
    if zone then tooltip:AddDoubleLine(Label(L["Most spawn points"]), zone, 0.8, 0.8, 0.8, 1, 1, 1) end
    local used = UsedLine(itemID)
    if used then tooltip:AddDoubleLine(Label(L["Used in"]), used, 0.8, 0.8, 0.8, 1, 1, 1) end
    return true
end

local SECTIONS = { PriceSection, BlockSection }

-- Puts our lines into a tooltip. true when lines were added.
local ctx = {}
local function Render(tooltip, itemID)
    if not (tooltip and itemID and ns.PriceInfo) or not Enabled() then return false end
    -- the recipe book changed since the index was built: built anew, the
    -- "used in" line is gone meanwhile (no old number)
    if state == "ready" and ns.RecipeRev and ns.RecipeRev() ~= builtRecipeRev then
        run = run + 1
        Build(run)
    end
    ctx.block = (gather and (gather[itemID] or (usedIn and usedIn[itemID] ~= nil))) and true or false
    ctx.shift = IsShiftKeyDown and IsShiftKeyDown() and true or false -- (the client builds the tooltip anew when Shift changes - or the details come with the next hover)
    local added = false
    for _, section in ipairs(SECTIONS) do
        if section(tooltip, itemID, ctx) then added = true end
    end
    return added
end
ns.TooltipSections = { Render = Render }

---------------------------------------------------------------------------
-- The hook
--   One way only: the client's tooltip data (where it has it) or
--   OnTooltipSetItem. Registered once, whatever loads this file twice.
--   And apart from that: once per build of a tooltip. The client may call
--   us several times for one build; a build ends when the tooltip is
--   cleared (OnTooltipCleared). Where a tooltip has no such script, the
--   number of lines after our block is the mark: the same item (and the
--   same Shift) with at least that many lines is the same build - other
--   addons may have added theirs after ours; a tooltip built anew starts
--   below the mark.
---------------------------------------------------------------------------
local built = setmetatable({}, { __mode = "k" })   -- tooltip -> true / { item, lines }: our lines are in this build
local watched = setmetatable({}, { __mode = "k" }) -- tooltip -> true: cleared tooltips tell us; false: they cannot
local stats = { way = "none", calls = 0, builds = 0, ms = 0, renders = 0, recent = {} }

local function Watch(tooltip)
    local known = watched[tooltip]
    if known ~= nil then return known end
    local can = false
    if tooltip.HasScript and tooltip.HookScript then
        local ok, has = pcall(tooltip.HasScript, tooltip, "OnTooltipCleared")
        if ok and has == true then
            can = pcall(tooltip.HookScript, tooltip, "OnTooltipCleared", function(self) built[self] = nil end) and true or false
        end
    end
    watched[tooltip] = can
    return can
end

local function Lines(tooltip)
    if not tooltip.NumLines then return end
    local ok, n = pcall(tooltip.NumLines, tooltip)
    if ok and type(n) == "number" then return n end
end

local function Shift()
    return IsShiftKeyDown and IsShiftKeyDown() and true or false
end

-- One call of the hook: our lines, unless this build has them already
local function OnItem(tooltip, itemID)
    stats.calls = stats.calls + 1
    if not Enabled() then return false end
    local cleared = Watch(tooltip)
    local mark = built[tooltip]
    if mark then
        if cleared then
            stats.recent[#stats.recent] = (stats.recent[#stats.recent] or 1) + 1
            return false
        end
        local n = Lines(tooltip)
        if mark.item == itemID and mark.shift == Shift() and mark.lines and n and n >= mark.lines then
            stats.recent[#stats.recent] = (stats.recent[#stats.recent] or 1) + 1
            return false
        end
    end
    local t0 = debugprofilestop()
    local added = Render(tooltip, itemID)
    stats.ms, stats.renders = stats.ms + (debugprofilestop() - t0), stats.renders + 1
    stats.builds = stats.builds + 1
    stats.recent[#stats.recent + 1] = 1
    if #stats.recent > 20 then table.remove(stats.recent, 1) end
    if cleared then
        built[tooltip] = true
    elseif added then
        local m = type(mark) == "table" and mark or {}
        m.item, m.lines, m.shift = itemID, Lines(tooltip), Shift()
        built[tooltip] = m
    else
        built[tooltip] = nil
    end
    return added
end

local function ReadableTable(v, where)
    if issecretvalue then v = ns.Readable(v, where) end
    if type(v) == "table" then return v end
end

local function ItemIDFromLink(link)
    link = ns.Readable(link, "item link")
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

if not ns.itemTooltipHooked then
    ns.itemTooltipHooked = true
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item then
        stats.way = "TooltipDataProcessor"
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
            tooltip, data = ReadableTable(tooltip, "item tooltip"), ReadableTable(data, "item tooltip")
            if not (tooltip and data and tooltip.AddDoubleLine) then return end
            local itemID = ns.Readable(data.id, "item tooltip")
            if type(itemID) ~= "number" then return end
            OnItem(tooltip, itemID)
        end)
    else
        for _, name in ipairs({ "GameTooltip", "ItemRefTooltip" }) do
            local tt = _G[name]
            if tt and tt.HookScript then
                stats.way = "OnTooltipSetItem"
                tt:HookScript("OnTooltipSetItem", function(self)
                    local _, link = self:GetItem()
                    local itemID = ItemIDFromLink(link)
                    if itemID and OnItem(self, itemID) then self:Show() end
                end)
            end
        end
    end
end

---------------------------------------------------------------------------
-- What makes the caches old: the language, the continent; and the start
-- after login
---------------------------------------------------------------------------
if ns.languageListeners then
    table.insert(ns.languageListeners, function() langRev = langRev + 1 end)
end

local function ReadContinent()
    local mapID = C_Map and C_Map.GetBestMapForUnit and ns.Readable(C_Map.GetBestMapForUnit("player"), "item tooltip")
    continent = (type(mapID) == "number" and ns.GetContinent and ns.GetContinent(mapID)) or 0
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
pcall(events.RegisterEvent, events, "ZONE_CHANGED_NEW_AREA")
events:SetScript("OnEvent", function(_, event)
    ReadContinent()
    if event == "PLAYER_LOGIN" and not loggedIn then
        loggedIn = true
        C_Timer.After(LOGIN_DELAY, Start)
    end
end)

-- For /gcr tooltiptest: the state of the indexes and of the hook
ns.ItemTooltipState = function()
    return { state = state, buildMs = buildMs, builds = buildCount, recipes = recipeCount, reagents = reagentCount, way = stats.way,
        calls = stats.calls, tooltips = stats.builds, renders = stats.renders, ms = stats.ms, recent = stats.recent, continent = continent }
end
