local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Skill data
--   For every harvest we store the player's skill before and after.
--   Per node kind (language independent) this teaches us:
--     minSkill : lowest skill this kind was gathered with (upper bound of the requirement)
--     maxUp    : highest skill at which a skill point was gained
--     minNoUp  : lowest skill at which no point was gained
---------------------------------------------------------------------------
local SKILL_LINE = { herb = 182, ore = 186, fish = 356, cook = 185, aid = 129 } -- Herbalism, Mining, Fishing, Cooking, First Aid
-- Compared in lower case. string.lower leaves Cyrillic capitals alone, so the
-- Russian names are here as the client writes them too.
local SKILL_NAMES = {
    herb = { ["herbalism"] = true, ["kräuterkunde"] = true, ["herboristerie"] = true, ["herboristería"] = true,
        ["erbalismo"] = true, ["herborismo"] = true, ["травничество"] = true,
        ["Травничество"] = true, ["약초채집"] = true, ["草药学"] = true, ["草藥學"] = true },
    ore = { ["mining"] = true, ["bergbau"] = true, ["minage"] = true, ["minería"] = true,
        ["estrazione"] = true, ["mineração"] = true, ["горное дело"] = true,
        ["Горное дело"] = true, ["채광"] = true, ["采矿"] = true, ["採礦"] = true },
    fish = { ["fishing"] = true, ["angeln"] = true, ["pêche"] = true, ["pesca"] = true, ["рыбная ловля"] = true,
        ["Рыбная ловля"] = true, ["낚시"] = true, ["钓鱼"] = true, ["釣魚"] = true },
    cook = { ["cooking"] = true, ["kochkunst"] = true, ["cuisine"] = true, ["cocina"] = true, ["cucina"] = true,
        ["culinária"] = true, ["кулинария"] = true,
        ["Кулинария"] = true, ["요리"] = true, ["烹饪"] = true, ["烹飪"] = true },
    aid = { ["first aid"] = true, ["erste hilfe"] = true, ["secourisme"] = true, ["primeros auxilios"] = true,
        ["primo soccorso"] = true, ["primeiros socorros"] = true, ["первая помощь"] = true,
        ["Первая помощь"] = true, ["응급치료"] = true, ["急救"] = true },
}
-- The clients whose names are in the lists above: only there can the old
-- skill list say that a profession is missing
local SKILL_NAME_LOCALES = { enUS = true, enGB = true, deDE = true, esES = true, esMX = true, frFR = true,
    itIT = true, koKR = true, ptBR = true, ruRU = true, zhCN = true, zhTW = true }
local PROFESSION_LABEL = { herb = "Herbalism", ore = "Mining" }
local CHECK_DELAY = 1.5 -- seconds after the harvest before reading the new skill
local STATS_VERSION = 3 -- v2: only the first gather of each spawn counts; v3: keyed by type + name

-- A vein can be mined several times, but only the first gather can give a
-- skill point. Later gathers of the same spawn are not counted.
local countedSpawns = {}

-- Current skill for "herb" / "ore", or nil if the profession is not learned.
-- Returns rank, maxRank, effective: effective adds bonuses from gear and buffs
-- (gloves, enchants, Goldthorn Tea...). Bonuses let you gather higher nodes,
-- skill-ups still go by your own rank.
local function Bonus(modifier)
    modifier = tonumber(modifier) or 0
    return modifier > 0 and modifier or 0
end

local function GetSkill(nodeType)
    if GetProfessions and GetProfessionInfo then
        -- prof1, prof2, archaeology, fishing, cooking, first aid (some may be nil)
        local profs = { GetProfessions() }
        for i = 1, 6 do
            local index = profs[i]
            if index then
                local _, _, rank, maxRank, _, _, skillLine, modifier = GetProfessionInfo(index)
                if skillLine == SKILL_LINE[nodeType] then
                    return rank, maxRank, rank + Bonus(modifier)
                end
            end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank, _, modifier, maxRank = GetSkillLineInfo(i)
            if not isHeader and name and SKILL_NAMES[nodeType] and SKILL_NAMES[nodeType][name:lower()] then
                return rank, maxRank, rank + Bonus(modifier)
            end
        end
    end
end

-- GetSkill found nothing: true when that may only be because the old skill
-- list hides it (a collapsed header in the skill window), false when the
-- profession is really not learned (any more)
local function SkillListIncomplete()
    if not (GetNumSkillLines and GetSkillLineInfo) then return not (GetProfessions and GetProfessionInfo) end
    for i = 1, GetNumSkillLines() do
        local _, isHeader, isExpanded = GetSkillLineInfo(i)
        if isHeader and not isExpanded then return true end
    end
    return false
end

-- The stats table, migrated to the current format
local function KindStats()
    local db = ns.db
    if db.kindStatsVersion == 2 and db.kindStats then
        -- v2 was keyed by object ID: merge into type + name keys
        local merged = {}
        for key, s in pairs(db.kindStats) do
            local nk = (s.type or "?") .. ":" .. (s.name or key):lower()
            local m = merged[nk]
            if not m then
                merged[nk] = s
            else
                m.n, m.ups = (m.n or 0) + (s.n or 0), (m.ups or 0) + (s.ups or 0)
                m.minSkill = math.min(m.minSkill or s.minSkill or 0, s.minSkill or m.minSkill or 0)
                m.maxSkill = math.max(m.maxSkill or 0, s.maxSkill or 0)
                if s.maxUp then m.maxUp = math.max(m.maxUp or 0, s.maxUp) end
                if s.minNoUp then m.minNoUp = math.min(m.minNoUp or s.minNoUp, s.minNoUp) end
            end
        end
        db.kindStats = merged
        db.kindStatsVersion = STATS_VERSION
    elseif db.kindStatsVersion ~= STATS_VERSION then
        -- Older data counted repeated gathers of the same vein: start fresh
        db.kindStats = {}
        db.kindStatsVersion = STATS_VERSION
    end
    db.kindStats = db.kindStats or {}
    return db.kindStats
end

---------------------------------------------------------------------------
-- Skill-up verdict
--   Classic rule: from the required skill a node is orange (skill-up every
--   time) for 25 points, then yellow (likely) for 25, green (sometimes) up to
--   +100, then grey (never). Requirements of the classic nodes are known;
--   for new Forever nodes we fall back to what we learned while gathering.
---------------------------------------------------------------------------
local REQUIRED = {
    ["Peacebloom"] = 1, ["Silverleaf"] = 1, ["Earthroot"] = 15, ["Mageroyal"] = 50,
    ["Briarthorn"] = 70, ["Stranglekelp"] = 85, ["Bruiseweed"] = 100, ["Wild Steelbloom"] = 115,
    ["Grave Moss"] = 120, ["Kingsblood"] = 125, ["Liferoot"] = 150, ["Fadeleaf"] = 160,
    ["Goldthorn"] = 170, ["Khadgar's Whisker"] = 185, ["Wintersbite"] = 195, ["Firebloom"] = 205,
    ["Purple Lotus"] = 210, ["Arthas' Tears"] = 220, ["Sungrass"] = 230, ["Blindweed"] = 235,
    ["Ghost Mushroom"] = 245, ["Gromsblood"] = 250, ["Golden Sansam"] = 260, ["Dreamfoil"] = 270,
    ["Mountain Silversage"] = 280, ["Plaguebloom"] = 285, ["Icecap"] = 290, ["Black Lotus"] = 300,
    ["Copper Vein"] = 1, ["Tin Vein"] = 65, ["Incendicite Mineral Vein"] = 65, ["Silver Vein"] = 75,
    ["Lesser Bloodstone Deposit"] = 75, ["Iron Deposit"] = 125, ["Indurium Mineral Vein"] = 150,
    ["Gold Vein"] = 155, ["Mithril Deposit"] = 175, ["Truesilver Deposit"] = 230,
    ["Dark Iron Deposit"] = 230, ["Small Thorium Vein"] = 245, ["Rich Thorium Vein"] = 275,
    ["Ooze Covered Silver Vein"] = 75, ["Ooze Covered Gold Vein"] = 155,
    ["Ooze Covered Mithril Deposit"] = 175, ["Ooze Covered Truesilver Deposit"] = 230,
    ["Ooze Covered Thorium Vein"] = 245, ["Ooze Covered Rich Thorium Vein"] = 275,
    -- Forever starter variants: same requirement as the normal node
    ["Poor Copper Vein"] = 1, ["Wilted Peacebloom"] = 1, ["Stunted Silverleaf"] = 1,
}

local function Required(id, name)
    -- English name via the known spawn data, so it works in every client language
    local data = GathercraftQuestieData
    local kind = data and id and data.kinds[id]
    return (kind and REQUIRED[kind[3]]) or (name and REQUIRED[name])
end

-- The trainer colour of a node for your skill: "orange" (skill-up every
-- time), "yellow" (likely), "green" (sometimes), "grey" (never), "red" (your
-- skill is too low). nil: requirement unknown. Pass mine/effective from
-- GetSkill when you already have them (pins colour thousands of nodes).
local function SkillLevel(name, id, mine, effective)
    local req = Required(id, name)
    if not req or not mine then return nil, req end
    local d = mine - req
    if d < 0 then
        -- above your own skill, but your bonus (gloves, tea...) reaches it
        if effective and effective >= req then return "orange", req end
        return "red", req
    end
    if d < 25 then return "orange", req end
    if d < 50 then return "yellow", req end
    if d < 100 then return "green", req end
    return "grey", req
end

local LEVEL_RANK = { orange = 0, yellow = 1, green = 2, grey = 3, red = 4 }

-- Returns sort rank (lower = better to farm) and a coloured text
local function SkillVerdict(nodeType, name, id, key)
    if nodeType == "chest" then return 5, L["|cffaaaaaaChest|r"] end
    local mine, maxRank, effective = GetSkill(nodeType)
    if not mine then return 6, L["|cffff5555Profession not learned|r"] end
    local level, req = SkillLevel(name, id, mine, effective)
    if level then
        local rank = LEVEL_RANK[level]
        -- at the end of a rank (75/75...) nothing gives a point until you train
        if level ~= "grey" and level ~= "red" and maxRank and maxRank > 0 and maxRank < 300 and mine >= maxRank then
            return rank, L["|cffffd060No skill-ups until you train the next rank|r"]
        end
        if level == "orange" then return rank, L["|cffff8040Skill-up guaranteed|r"] end
        if level == "yellow" then return rank, L["|cffffff00Skill-up likely|r"] end
        if level == "green" then return rank, L["|cff40ff40Skill-up sometimes|r"] end
        if level == "grey" then return rank, L["|cff999999No more skill-ups|r"] end
        return rank, (L["|cffff5555Needs skill %d|r"]):format(req)
    end
    local s = key and KindStats()[key]
    if s and s.maxUp and mine <= s.maxUp then return 1, L["|cff55ff55Skill-ups seen|r"] end
    return 2, L["|cffffd060Skill-ups unknown|r"]
end

local function Stats(key)
    local s = KindStats()[key]
    if not s then
        s = { n = 0, ups = 0 }
        ns.db.kindStats[key] = s
    end
    return s
end

-- Called by the recorder when a gather cast starts
-- skillBefore = own rank (skill-ups), reachBefore = with bonus (what you
-- could gather: the upper bound of a node's requirement)
local function OnGatherStart(pending)
    local rank, maxRank, effective = GetSkill(pending.type)
    pending.skillBefore, pending.reachBefore, pending.maxBefore = rank, effective or rank, maxRank
end

-- Called by the recorder after a node was recorded
local function OnGathered(node, pending)
    local before = pending.skillBefore
    if not before then return end
    if pending.spawn then
        if countedSpawns[pending.spawn] then
            ns.Debug(("SKILL %s: same spawn again, not counted"):format(node.name))
            return
        end
        countedSpawns[pending.spawn] = true
    end
    -- at the end of a rank (75/75, 150/150, 225/225) no gather can give a
    -- point until you train: it says nothing about the kind's skill-up chance
    -- (300 is the real end, counted as before)
    local cap = pending.maxBefore
    if cap and cap > 0 and cap < 300 and before >= cap then
        ns.Debug(("SKILL %s: at the end of your rank (%d/%d), not counted"):format(node.name, before, cap))
        return
    end
    local key = ns.KindKey(node)
    C_Timer.After(CHECK_DELAY, function()
        local after = GetSkill(pending.type) or before
        local s = Stats(key)
        s.name, s.type = node.name, node.type
        s.n = s.n + 1
        local reach = pending.reachBefore or before
        s.minSkill = math.min(s.minSkill or reach, reach)
        s.maxSkill = math.max(s.maxSkill or reach, reach)
        if after > before then
            s.ups = s.ups + 1
            s.maxUp = math.max(s.maxUp or before, before)
        else
            s.minNoUp = math.min(s.minNoUp or before, before)
        end
        ns.Debug(("SKILL %s: %d -> %d (%s)"):format(node.name, before, after,
            after > before and L["skill-up"] or L["no point"]))
    end)
end

-- Extra tooltip lines for a node pin
local function AddTooltipLines(tooltip, node)
    if not node.type then return end
    local key = ns.KindKey(node)
    local s = KindStats()[key]
    local mine, _, effective = GetSkill(node.type)
    local _, verdict = SkillVerdict(node.type, node.name, node.id, key)
    tooltip:AddLine(verdict)
    if mine then
        local bonus = (effective and effective > mine) and (" |cff7bd35f(+%d)|r"):format(effective - mine) or ""
        tooltip:AddLine((L["Your %s: %d"]):format(L[PROFESSION_LABEL[node.type]], mine) .. bonus, 0.8, 0.8, 0.8)
    end
    if s and s.minSkill then
        tooltip:AddLine((s.n == 1 and L["Gathered from skill %d (1 node)"] or L["Gathered from skill %d (%d nodes)"]):format(
            s.minSkill, s.n), 0.6, 0.6, 0.6)
        if s.maxUp then
            local r, g, b = 0.4, 1, 0.4
            if mine and mine > s.maxUp then r, g, b = 0.6, 0.6, 0.6 end
            tooltip:AddLine((L["Skill points seen up to %d"]):format(s.maxUp), r, g, b)
        end
    end
end

-- /gcr skills : what we learned so far
local function ShowSkills()
    for _, t in ipairs({ "herb", "ore" }) do
        local rank, maxRank, effective = GetSkill(t)
        local bonus = (rank and effective and effective > rank) and (" (+%d)"):format(effective - rank) or ""
        ns.Print(("%s: %s"):format(L[PROFESSION_LABEL[t]], rank and (rank .. "/" .. maxRank .. bonus) or L["not learned"]))
    end
    local list = {}
    for key, s in pairs(KindStats()) do
        list[#list + 1] = s
    end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return (a.type or "") < (b.type or "") end
        return (a.minSkill or 0) < (b.minSkill or 0)
    end)
    if #list == 0 then
        print(L["  No skill data yet. Gather something!"])
        return
    end
    for _, s in ipairs(list) do
        print((L["  %s [%s]: from %s, points up to %s, %d nodes (%d skill-ups)"]):format(
            s.name or "?", s.type or "?", tostring(s.minSkill or "?"), tostring(s.maxUp or "-"),
            s.n, s.ups))
    end
end

---------------------------------------------------------------------------
-- Which gathering professions this character has (map filter, right-click).
-- Right after login the game may not have told yet: then nothing is known
-- and everything stays as it was. Only events read it: the map asks per node.
-- "Not learned" needs a sure read: professions listed with their skill line,
-- or the whole old skill list in a language we have the names of. Anything
-- else leaves it unknown, and unknown hides nothing and blocks nothing.
---------------------------------------------------------------------------
local PROFESSIONS_SETTLE = 5 -- seconds after login: only then "none found" can be believed
local gather = { known = false, herb = false, ore = false }
local settled = false
local professionLine -- the last read, in words (/gcr debug)

-- true when the game lists professions, each with its skill line. No
-- profession listed proves nothing: it may just not have told yet.
local function ProfessionIDsWork()
    if not (GetProfessions and GetProfessionInfo) then return false end
    local profs = { GetProfessions() }
    local any = false
    for i = 1, 6 do
        if profs[i] then
            local skillLine = select(7, GetProfessionInfo(profs[i]))
            if (tonumber(skillLine) or 0) <= 0 then return false end
            any = true
        end
    end
    return any
end

-- true when a name missing from the old skill list means it is not learned.
-- The list is empty until the game has sent it.
local function SkillListProves()
    if not (GetNumSkillLines and GetSkillLineInfo) or GetNumSkillLines() == 0 then return false end
    return SKILL_NAME_LOCALES[GetLocale()] and not SkillListIncomplete()
end

-- herb, ore, known, source: known is nil while nothing can be said
local function ReadGatherProfessions()
    local herb, ore = GetSkill("herb") and true or false, GetSkill("ore") and true or false
    if ProfessionIDsWork() then
        if herb or ore or settled then return herb, ore, true, "IDs" end
        return herb, ore, nil, "IDs"
    end
    local source = GetNumSkillLines and GetSkillLineInfo and "skill lines" or "nothing"
    if herb and ore then return herb, ore, true, source end
    if (herb or ore or settled) and SkillListProves() then return herb, ore, true, source end
    return herb, ore, nil, source
end

local function UpdateGatherProfessions()
    if not ns.db then return end
    local herb, ore, known, source = ReadGatherProfessions()
    local line = ("PROFESSIONS from %s: herb=%s ore=%s, %s"):format(source, tostring(herb), tostring(ore),
        known and "sure" or "not sure")
    if line ~= professionLine then
        professionLine = line
        ns.Debug(line)
    end
    if not known then
        -- what it knew stays (a header collapsed in the skill window), but a
        -- profession found counts at once: only a sure read can say "not learned"
        herb, ore = herb or gather.herb, ore or gather.ore
        if not gather.known or (herb == gather.herb and ore == gather.ore) then return end
    end
    local changed = (not gather.known or gather.herb) ~= herb or (not gather.known or gather.ore) ~= ore
    gather.known, gather.herb, gather.ore = true, herb, ore
    if changed and ns.NotifyNodesChanged then ns.NotifyNodesChanged() end
    if not herb and not ore and not ns.db.allGatherPins and not ns.db.noProfessionHint then
        ns.db.noProfessionHint = true
        ns.Print(L["No gathering profession: herb and ore pins are hidden. To show them, untick \"Only show nodes my professions can gather\" in Options, Map & minimap."])
    end
end

-- From a fresh start (login): nothing known, "none found" counts after a while
local function WatchGatherProfessions()
    gather.known, gather.herb, gather.ore = false, false, false
    settled = false
    UpdateGatherProfessions()
    C_Timer.After(PROFESSIONS_SETTLE, function()
        settled = true
        UpdateGatherProfessions()
    end)
end

local professionWatch = CreateFrame("Frame")
professionWatch:RegisterEvent("PLAYER_LOGIN")
professionWatch:RegisterEvent("SKILL_LINES_CHANGED")
professionWatch:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then WatchGatherProfessions() else UpdateGatherProfessions() end
end)

-- herb, ore, known (see above)
function ns.GatherProfessions()
    return gather.herb, gather.ore, gather.known
end

-- Options, Map & minimap: herbs need Herbalism, ores Mining. Chests and
-- fishing spots have their own switches.
function ns.HiddenByProfession(n)
    if ns.db.allGatherPins or not gather.known then return false end
    if n.type == "herb" then return not gather.herb end
    if n.type == "ore" then return not gather.ore end
    return false
end

-- /gcr debug switched on: the last read, without waiting for a new one
function ns.DebugGatherProfessions()
    if professionLine then ns.Debug(professionLine) end
end

ns.WatchGatherProfessions = WatchGatherProfessions -- for the tests (tools/smoke_test.lua)
ns.GetSkill = GetSkill
ns.SkillVerdict = SkillVerdict
ns.SkillLevel = SkillLevel
ns.SkillListIncomplete = SkillListIncomplete
ns.RequiredSkill = function(id, name) return Required(id, name) or 0 end
ns.KindStats = KindStats
ns.OnGatherStart = OnGatherStart
ns.OnGathered = OnGathered
ns.SkillTooltip = AddTooltipLines
ns.ShowSkills = ShowSkills
