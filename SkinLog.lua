local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Skinning log (v0.1.19 Q7, Sven 08.11.2026): the data for skinning areas
-- later. Nothing is shown on the map yet.
--   * after you skin a beast: its NPC ID (from the loot source
--     "Creature-..."), its name, the zone, a rough position (about 50 yd),
--     your Skinning skill, the items and amounts, time and game build
--   * "Requires Skinning N" when you try: the skill that beast needs, when
--     the beast is clear (your target or the one under the mouse, not two)
--   * on this computer only, never shared; the newest MAX_ENTRIES are kept;
--     Options > General turns it off
--   * it only watches: no action, no target, nothing done for you. No
--     player names. Values the client hides are not compared or kept.
--   * a loot window seen twice (READY, OPENED, READY, CLOSED, CLOSED) is
--     one skinning: one entry per corpse
--   /gcr skinlog         what the log says
--   /gcr skinlog clear   empties it
---------------------------------------------------------------------------
local MAX_ENTRIES = 5000
local SKINNING_SPELLS = { [8613] = true, [8617] = true, [8618] = true, [10768] = true } -- Apprentice .. Artisan
local CAST_WINDOW = 5 -- seconds from the skinning cast to its loot

local function DB()
    ns.db.skinLog = ns.db.skinLog or {}
    return ns.db.skinLog
end
local function Needs()
    ns.db.skinNeeds = ns.db.skinNeeds or {}
    return ns.db.skinNeeds
end
local function On() return ns.db and not ns.db.skinLogOff end

local function Secret(...) return ns.AnySecret("skinning log", ...) end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return ns.Readable(C_Spell.GetSpellName(id), "spell name") end
    return GetSpellInfo and ns.Readable((GetSpellInfo(id)), "spell name")
end
-- the name the client gives Skinning (for its error message)
local function SkinningName() return SpellName(8613) end

local function IsSkinning(spell)
    if spell == nil or Secret(spell) then return false end
    if SKINNING_SPELLS[spell] then return true end
    local name, skin = SpellName(spell), SkinningName()
    return name ~= nil and skin ~= nil and name == skin
end

-- the NPC ID of a creature GUID, or nil (players, objects, hidden)
local function NpcID(guid)
    if type(guid) ~= "string" or Secret(guid) then return end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" then return tonumber(id) end
end

local function Add(e)
    local log = DB()
    log[#log + 1] = e
    if #log > MAX_ENTRIES then
        local drop = #log - MAX_ENTRIES
        for i = 1, #log - drop do log[i] = log[i + drop] end
        for i = #log, #log - drop + 1, -1 do log[i] = nil end
    end
end

local function Skill()
    local rank = ns.GetSkill and ns.GetSkill("skin")
    if rank ~= nil and not Secret(rank) then return rank end
end

local function Build()
    local build = GetBuildInfo and select(2, GetBuildInfo())
    if build ~= nil and not Secret(build) then return tonumber(build) or build end
end

-- the creature you skin: your target or the one under the mouse, the same
-- or only one of them; its name only when it is no player
local function Beast()
    local found
    for _, unit in ipairs({ "target", "mouseover" }) do
        local guid = UnitGUID and UnitGUID(unit)
        if guid ~= nil and not Secret(guid) and NpcID(guid) then
            if found and found.guid ~= guid then return end -- two beasts: not clear
            if not found then
                local name = UnitName and UnitName(unit)
                local player = UnitIsPlayer and UnitIsPlayer(unit)
                if Secret(name, player) or player then name = nil end
                found = { guid = guid, npc = NpcID(guid), name = name }
            end
        end
    end
    return found
end

local lastCast       -- { at = GetTime(), beast = Beast() at the cast }
local done = {}      -- corpse GUID -> true: its skinning is logged
local doneOrder = {}
local function Done(guid)
    done[guid] = true
    doneOrder[#doneOrder + 1] = guid
    if #doneOrder > 200 then done[table.remove(doneOrder, 1)] = nil end
end

local function Position()
    if not ns.GetPlayerPos then return end
    local mapID, x, y = ns.GetPlayerPos() -- (not "x and f()": that keeps one value)
    if not (mapID and x and y) then return end
    -- rough: two decimals, about 50 yards in a zone
    return mapID, math.floor(x * 100 + 0.5) / 100, math.floor(y * 100 + 0.5) / 100
end

-- the loot window of a skinning: what it holds, once per corpse
local function ReadLoot()
    if not (lastCast and GetTime() - lastCast.at <= CAST_WINDOW) then return end
    local count = GetNumLootItems and GetNumLootItems()
    if count == nil or Secret(count) or count == 0 then return end
    local corpse, items, any = nil, {}, false
    for slot = 1, count do
        local guid = GetLootSourceInfo and GetLootSourceInfo(slot)
        if guid == nil or Secret(guid) or not NpcID(guid) then return end -- not a beast (a chest, a herb, hidden)
        if corpse and corpse ~= guid then return end -- two sources: not one skinning
        corpse = guid
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        local qty = GetLootSlotInfo and select(3, GetLootSlotInfo(slot))
        if Secret(link, qty) then return end
        local item = type(link) == "string" and tonumber(link:match("item:(%d+)"))
        if item then
            items[item] = (items[item] or 0) + (tonumber(qty) or 1)
            any = true
        end
    end
    if not (corpse and any) or done[corpse] then return end
    -- the corpse you cast on (when it could be told)
    if lastCast.beast and lastCast.beast.guid ~= corpse then return end
    Done(corpse)
    local beast = lastCast.beast or Beast()
    lastCast = nil
    local mapID, x, y = Position()
    Add({ t = time(), build = Build(), npc = NpcID(corpse), name = beast and beast.guid == corpse and beast.name or nil,
        map = mapID, x = x, y = y, skill = Skill(), items = items })
end

-- "Requires Skinning 100": the pattern of the client's own message
-- (ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI, "Requires %s %d" in English), with
-- the client's name of Skinning. Positions like %1$s are taken as they are.
local function NeedPattern()
    local template, skin = _G.ERR_USE_LOCKED_WITH_SPELL_KNOWN_SI, SkinningName()
    if type(template) ~= "string" or not skin then return end
    local order, p = {}, ""
    local i = 1
    while i <= #template do
        local a, b, _, kind = template:find("^%%(%d?)%$?([sd])", i)
        if a then
            order[#order + 1] = kind
            p = p .. (kind == "s" and "(.-)" or "(%d+)")
            i = b + 1
        else
            local c = template:sub(i, i)
            p = p .. (c:match("%W") and ("%" .. c) or c)
            i = i + 1
        end
    end
    -- (a numbered form like "%2$d %1$s" works too: the values come in the
    -- order they stand, and order says which is which)
    return "^" .. p .. "$", order, skin
end

local function OnError(message)
    if type(message) ~= "string" or Secret(message) then return end
    local pattern, order, skin = NeedPattern()
    if not pattern then return end
    local caps = { message:match(pattern) }
    if #caps == 0 then return end
    local name, need
    for k, kind in ipairs(order) do
        if kind == "s" then name = caps[k] else need = tonumber(caps[k]) end
    end
    if name ~= skin or not need then return end
    local beast = Beast()
    if not beast then return end -- which beast is not clear: nothing
    Needs()[beast.npc] = need
end

local watch = CreateFrame("Frame", "GathercraftSkinWatch")
for _, e in ipairs({ "UNIT_SPELLCAST_SUCCEEDED", "LOOT_READY", "LOOT_OPENED", "UI_ERROR_MESSAGE" }) do
    pcall(watch.RegisterEvent, watch, e)
end
watch:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if not On() then return end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 == "player" and IsSkinning(a3) then lastCast = { at = GetTime(), beast = Beast() } end
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        ReadLoot()
    elseif event == "UI_ERROR_MESSAGE" then
        -- (errorType, message) in newer clients, (message) in older ones
        OnError(type(a2) == "string" and a2 or a1)
    end
end)

---------------------------------------------------------------------------
-- /gcr skinlog
---------------------------------------------------------------------------
local function Summary(log)
    local beasts, kinds, items, low, high = {}, 0, {}, nil, nil
    for _, e in ipairs(log) do
        if e.npc then
            local b = beasts[e.npc]
            if not b then
                b = { n = 0, name = e.name }
                beasts[e.npc] = b
                kinds = kinds + 1
            end
            b.n = b.n + 1
            b.name = b.name or e.name
            if e.skill then
                b.low, b.high = math.min(b.low or e.skill, e.skill), math.max(b.high or e.skill, e.skill)
                low, high = math.min(low or e.skill, e.skill), math.max(high or e.skill, e.skill)
            end
        end
        for item, qty in pairs(e.items or {}) do items[item] = (items[item] or 0) + qty end
    end
    return beasts, kinds, items, low, high
end
ns.SkinLogSummary = function() return Summary(DB()) end

ns.SkinLogCommand = function(rest)
    rest = (rest or ""):lower()
    if rest == "clear" then
        ns.db.skinLog, ns.db.skinNeeds = {}, {}
        lastCast = nil
        ns.Print(L["Skinning log cleared."])
        return
    end
    local log = DB()
    local beasts, kinds, items, low, high = Summary(log)
    ns.Print((L["Skinning log: %d skinned, %d kinds of beasts (kept on this computer, never shared)."]):format(#log, kinds))
    if ns.db.skinLogOff then print(L["  Recording is off (Options > General)."]) end
    if #log == 0 then return end
    if low then print((L["  Your skill while skinning: %d-%d"]):format(low, high)) end
    local list = {}
    for npc, b in pairs(beasts) do list[#list + 1] = { npc = npc, b = b } end
    table.sort(list, function(x, y) return x.b.n > y.b.n end)
    for i = 1, math.min(10, #list) do
        local b = list[i].b
        local need = ns.db.skinNeeds and ns.db.skinNeeds[list[i].npc]
        print((L["  %s: %d skinned, skill %s"]):format(b.name or ("NPC " .. list[i].npc), b.n,
            b.low and (b.low == b.high and tostring(b.low) or (b.low .. "-" .. b.high)) or "?")
            .. (need and (" " .. (L["(needs %d)"]):format(need)) or ""))
    end
    local got = {}
    for item, qty in pairs(items) do got[#got + 1] = { item = item, qty = qty } end
    table.sort(got, function(x, y) return x.qty > y.qty end)
    for i = 1, math.min(8, #got) do
        local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(got[i].item)
        if name ~= nil and Secret(name) then name = nil end
        print(("  %s: %d"):format(name or ("item " .. got[i].item), got[i].qty))
    end
end
