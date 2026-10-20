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
local SKILL_NAMES = {
    herb = { ["herbalism"] = true, ["kräuterkunde"] = true, ["herboristerie"] = true, ["herboristería"] = true,
        ["erbalismo"] = true, ["herborismo"] = true, ["травничество"] = true },
    ore = { ["mining"] = true, ["bergbau"] = true, ["minage"] = true, ["minería"] = true,
        ["estrazione"] = true, ["mineração"] = true, ["горное дело"] = true },
    fish = { ["fishing"] = true, ["angeln"] = true, ["pêche"] = true, ["pesca"] = true, ["рыбная ловля"] = true },
    cook = { ["cooking"] = true, ["kochkunst"] = true, ["cuisine"] = true, ["cocina"] = true, ["cucina"] = true,
        ["culinária"] = true, ["кулинария"] = true },
    aid = { ["first aid"] = true, ["erste hilfe"] = true, ["secourisme"] = true, ["primeros auxilios"] = true,
        ["primo soccorso"] = true, ["primeiros socorros"] = true, ["первая помощь"] = true },
}
local PROFESSION_LABEL = { herb = "Herbalism", ore = "Mining" }
local CHECK_DELAY = 1.5 -- seconds after the harvest before reading the new skill
local STATS_VERSION = 3 -- v2: only the first gather of each spawn counts; v3: keyed by type + name

-- A vein can be mined several times, but only the first gather can give a
-- skill point. Later gathers of the same spawn are not counted.
local countedSpawns = {}

-- Current skill for "herb" / "ore", or nil if the profession is not learned
local function GetSkill(nodeType)
    if GetProfessions and GetProfessionInfo then
        -- prof1, prof2, archaeology, fishing, cooking, first aid (some may be nil)
        local profs = { GetProfessions() }
        for i = 1, 6 do
            local index = profs[i]
            if index then
                local _, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
                if skillLine == SKILL_LINE[nodeType] then
                    return rank, maxRank
                end
            end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for i = 1, GetNumSkillLines() do
            local name, isHeader, _, rank, _, _, maxRank = GetSkillLineInfo(i)
            if not isHeader and name and SKILL_NAMES[nodeType] and SKILL_NAMES[nodeType][name:lower()] then
                return rank, maxRank
            end
        end
    end
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

-- Returns sort rank (lower = better to farm) and a coloured text
local function SkillVerdict(nodeType, name, id, key)
    if nodeType == "chest" then return 5, L["|cffaaaaaaChest|r"] end
    local mine = GetSkill(nodeType)
    if not mine then return 6, L["|cffff5555Profession not learned|r"] end
    local req = Required(id, name)
    if req then
        local d = mine - req
        if d < 0 then return 4, (L["|cffff5555Needs skill %d|r"]):format(req) end
        if d < 25 then return 0, L["|cffff8040Skill-up guaranteed|r"] end
        if d < 50 then return 1, L["|cffffff00Skill-up likely|r"] end
        if d < 100 then return 2, L["|cff40ff40Skill-up sometimes|r"] end
        return 3, L["|cff999999No more skill-ups|r"]
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
local function OnGatherStart(pending)
    pending.skillBefore = GetSkill(pending.type)
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
    local key = ns.KindKey(node)
    C_Timer.After(CHECK_DELAY, function()
        local after = GetSkill(pending.type) or before
        local s = Stats(key)
        s.name, s.type = node.name, node.type
        s.n = s.n + 1
        s.minSkill = math.min(s.minSkill or before, before)
        s.maxSkill = math.max(s.maxSkill or before, before)
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
    local mine = GetSkill(node.type)
    local _, verdict = SkillVerdict(node.type, node.name, node.id, key)
    tooltip:AddLine(verdict)
    if mine then
        tooltip:AddLine((L["Your %s: %d"]):format(L[PROFESSION_LABEL[node.type]], mine), 0.8, 0.8, 0.8)
    end
    if s and s.minSkill then
        tooltip:AddLine((L["Gathered from skill %d (%d nodes)"]):format(s.minSkill, s.n), 0.6, 0.6, 0.6)
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
        local rank, maxRank = GetSkill(t)
        ns.Print(("%s: %s"):format(L[PROFESSION_LABEL[t]], rank and (rank .. "/" .. maxRank) or L["not learned"]))
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

ns.GetSkill = GetSkill
ns.SkillVerdict = SkillVerdict
ns.RequiredSkill = function(id, name) return Required(id, name) or 0 end
ns.KindStats = KindStats
ns.OnGatherStart = OnGatherStart
ns.OnGathered = OnGathered
ns.SkillTooltip = AddTooltipLines
ns.ShowSkills = ShowSkills
