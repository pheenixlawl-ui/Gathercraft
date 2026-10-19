local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Skill data
--   For every harvest we store the player's skill before and after.
--   Per node kind (language independent) this teaches us:
--     minSkill : lowest skill this kind was gathered with (upper bound of the requirement)
--     maxUp    : highest skill at which a skill point was gained
--     minNoUp  : lowest skill at which no point was gained
---------------------------------------------------------------------------
local SKILL_LINE = { herb = 182, ore = 186 } -- Herbalism, Mining
local SKILL_NAMES = {
    herb = { ["herbalism"] = true, ["kräuterkunde"] = true, ["herboristerie"] = true, ["herboristería"] = true },
    ore = { ["mining"] = true, ["bergbau"] = true, ["minage"] = true, ["minería"] = true },
}
local PROFESSION_LABEL = { herb = "Herbalism", ore = "Mining" }
local CHECK_DELAY = 1.5 -- seconds after the harvest before reading the new skill
local STATS_VERSION = 2 -- v2: only the first gather of each spawn counts

-- A vein can be mined several times, but only the first gather can give a
-- skill point. Later gathers of the same spawn are not counted.
local countedSpawns = {}

-- Current skill for "herb" / "ore", or nil if the profession is not learned
local function GetSkill(nodeType)
    if GetProfessions and GetProfessionInfo then
        local p1, p2 = GetProfessions()
        for _, index in ipairs({ p1, p2 }) do
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

local function Stats(key)
    if ns.db.kindStatsVersion ~= STATS_VERSION then
        -- Older data counted repeated gathers of the same vein: start fresh
        ns.db.kindStats = {}
        ns.db.kindStatsVersion = STATS_VERSION
    end
    ns.db.kindStats = ns.db.kindStats or {}
    local s = ns.db.kindStats[key]
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
            after > before and "skill-up" or "no point"))
    end)
end

-- Extra tooltip lines for a node pin
local function AddTooltipLines(tooltip, node)
    if not node.type then return end
    local s = ns.db.kindStats and ns.db.kindStats[ns.KindKey(node)]
    local mine = GetSkill(node.type)
    if mine then
        tooltip:AddLine(("Your %s: %d"):format(PROFESSION_LABEL[node.type], mine), 0.8, 0.8, 0.8)
    end
    if s and s.minSkill then
        tooltip:AddLine(("Gathered from skill %d (%d nodes)"):format(s.minSkill, s.n), 0.6, 0.6, 0.6)
        if s.maxUp then
            local r, g, b = 0.4, 1, 0.4
            if mine and mine > s.maxUp then r, g, b = 0.6, 0.6, 0.6 end
            tooltip:AddLine(("Skill points seen up to %d"):format(s.maxUp), r, g, b)
        end
    end
end

-- /gcr skills : what we learned so far
local function ShowSkills()
    for _, t in ipairs({ "herb", "ore" }) do
        local rank, maxRank = GetSkill(t)
        ns.Print(("%s: %s"):format(PROFESSION_LABEL[t], rank and (rank .. "/" .. maxRank) or "not learned"))
    end
    local list = {}
    for key, s in pairs(ns.db.kindStats or {}) do
        list[#list + 1] = s
    end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return (a.type or "") < (b.type or "") end
        return (a.minSkill or 0) < (b.minSkill or 0)
    end)
    if #list == 0 then
        print("  No skill data yet. Gather something!")
        return
    end
    for _, s in ipairs(list) do
        print(("  %s [%s]: from %s, points up to %s, %d nodes (%d skill-ups)"):format(
            s.name or "?", s.type or "?", tostring(s.minSkill or "?"), tostring(s.maxUp or "-"),
            s.n, s.ups))
    end
end

ns.GetSkill = GetSkill
ns.OnGatherStart = OnGatherStart
ns.OnGathered = OnGathered
ns.SkillTooltip = AddTooltipLines
ns.ShowSkills = ShowSkills
