local addonName, ns = ...

---------------------------------------------------------------------------
-- Where to learn (0.2, the places of trainers and vendors): the nearest
-- trainer of a profession for your faction (Data/Trainers.lua) and the
-- nearest vendor of a recipe item (Data/RecipeSources.lua), both from the
-- Questie database, converted when the files are made.
--
--   * the nearest by straight line on your continent; else one on another
--     continent (sure before unsure, then the lowest NPC ID: the zone is
--     named). No route, no path finding.
--   * a trainer's rank is the one its English title named when the file was
--     made (1 Apprentice ... 5 Master, 0 = none): a trainer whose title names
--     a lower rank than the step needs is not taken; one whose title names
--     none is, and for Expert and up it is marked "unsure". On your continent
--     a sure one comes before an unsure one.
--   * worked out when the skill plan is drawn and kept: again only on a zone
--     change, a bigger move (MOVE yards) or another faction - never while you
--     point at a row.
--   * no data, no map or no place: nil (the plan says what it said before).
---------------------------------------------------------------------------
local MOVE = 300
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)

local cache, here = {}, nil
ns.PlacesSearches = 0 -- (how often a search really ran: for the tests)

local function Faction()
    local mine = UnitFactionGroup and UnitFactionGroup("player")
    if ns.AnySecret and ns.AnySecret("faction", mine) then return nil end
    return mine == "Alliance" and "A" or mine == "Horde" and "H" or nil
end

-- the cache holds while you stay near where it was made
local function Fresh()
    local map, x, y
    if ns.GetPlayerPos then map, x, y = ns.GetPlayerPos() end
    local letter = Faction()
    local keep = here and here.letter == letter and here.map == map
    if keep and map then
        local d = HBD and HBD:GetZoneDistance(here.map, here.x, here.y, map, x, y)
        keep = d ~= nil and d <= MOVE
    end
    if not keep then
        cache = {}
        here = { map = map, x = x, y = y, letter = letter }
    end
    return here
end

-- how far a place is from you; nil = not on your continent (or no position)
local function Distance(at, mapID, x, y)
    if not (at.map and HBD and ns.GetContinent) then return nil end
    if ns.GetContinent(mapID) ~= ns.GetContinent(at.map) then return nil end
    return HBD:GetZoneDistance(at.map, at.x, at.y, mapID, x, y)
end

-- the better of two candidates: on your continent, sure, nearer, lower ID
local function Better(a, b)
    if not b then return true end
    if (a.d ~= nil) ~= (b.d ~= nil) then return a.d ~= nil end
    if a.unsure ~= b.unsure then return not a.unsure end
    if a.d and b.d and a.d ~= b.d then return a.d < b.d end
    return a.id < b.id
end

-- Data/Trainers.lua, read once per profession (again only if the table is another)
local trainers = {}
local function TrainersOf(prof)
    local packed = GathercraftTrainers and GathercraftTrainers[prof]
    local list = trainers[prof]
    if list and list.src == packed then return list end
    list = { src = packed }
    for id, text in pairs(packed or {}) do
        local name, rank, friendly, places = text:match("^([^|]*)|(%d+)|([^|]*)|(.*)$")
        if name then
            local t = { id = id, name = name, rank = tonumber(rank), friendly = friendly, places = {} }
            for area, x, y in places:gmatch("(%d+):(%d+):(%d+)") do
                t.places[#t.places + 1] = { area = tonumber(area), x = tonumber(x) / 10000, y = tonumber(y) / 10000 }
            end
            list[#list + 1] = t
        end
    end
    trainers[prof] = list
    return list
end

-- The nearest trainer of a profession who can teach rank `need` (1-5; nil:
-- any): { name, mapID, x, y, unsure, far } or nil
function ns.PlacesTrainer(prof, need)
    local at = Fresh()
    local key = "t:" .. tostring(prof) .. ":" .. tostring(need)
    if cache[key] ~= nil then return cache[key] or nil end
    ns.PlacesSearches = ns.PlacesSearches + 1
    local maps = GathercraftAreaMaps or {}
    local best
    for _, t in ipairs(TrainersOf(prof)) do
        local friendly = t.friendly ~= "" and (not at.letter or t.friendly:find(at.letter, 1, true))
        local teaches = not need or t.rank == 0 or t.rank >= need
        if friendly and teaches then
            local unsure = need ~= nil and need >= 3 and t.rank == 0
            for _, p in ipairs(t.places) do
                local mapID = maps[p.area]
                if mapID then
                    local c = { id = t.id, name = t.name, mapID = mapID, x = p.x, y = p.y, unsure = unsure }
                    c.d = Distance(at, mapID, p.x, p.y)
                    if Better(c, best) then best = c end
                end
            end
        end
    end
    if best then best.far = best.d == nil end
    cache[key] = best or false
    return best
end

-- The nearest vendor of a recipe item (Data/RecipeSources.lua): on your
-- continent the nearest, else the first by NPC ID as before; a vendor
-- without a known map only by name. { name, mapID, x, y, far } or nil
function ns.PlacesVendor(recipeItem)
    local at = Fresh()
    local key = "v:" .. tostring(recipeItem)
    if cache[key] ~= nil then return cache[key] or nil end
    ns.PlacesSearches = ns.PlacesSearches + 1
    local src, maps = GathercraftRecipeSources, GathercraftAreaMaps
    local packed = recipeItem and src and src.items and src.items[recipeItem]
    local best, named
    for list in (packed or ""):gmatch("V:([%d,]+)") do
        for id in list:gmatch("%d+") do
            id = tonumber(id)
            local npc = src.npcs and src.npcs[id]
            local name, area, friendly, x, y = (npc or ""):match("^([^|]*)|(%d*)|([^|]*)|(%d+)|(%d+)")
            if name and (not at.letter or friendly == "" or friendly:find(at.letter, 1, true)) then
                local mapID = maps and area and maps[tonumber(area)]
                if mapID then
                    local c = { id = id, name = name, mapID = mapID, x = tonumber(x) / 10000, y = tonumber(y) / 10000, unsure = false }
                    c.d = Distance(at, mapID, c.x, c.y)
                    if Better(c, best) then best = c end
                elseif not named or id < named.id then
                    named = { id = id, name = name }
                end
            end
        end
    end
    if best then best.far = best.d == nil end
    best = best or named
    cache[key] = best or false
    return best
end

-- the rank a skill step needs: after the cap at 75 Journeyman (2), 150
-- Expert (3), 225 Artisan (4), 300 Master (5)
local CAPS = { 75, 150, 225, 300 }
function ns.PlacesRankAfter(at)
    local rank = 1
    for _, cap in ipairs(CAPS) do if at >= cap then rank = rank + 1 end end
    return rank
end
-- the rank a recipe of a skill belongs to: up to 75 Apprentice, ... (a
-- recipe of 76-150 is a Journeyman's)
function ns.PlacesRankOf(skill)
    local rank = 1
    for _, cap in ipairs(CAPS) do if skill > cap then rank = rank + 1 end end
    return rank
end

local events = CreateFrame("Frame")
events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
events:SetScript("OnEvent", function() here = nil end)
