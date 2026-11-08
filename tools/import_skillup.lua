-- Builds Data/RecipeData.lua from SkillUp Forever's recipe tables
-- (https://github.com/cjber/skillup-forever, GPL-3.0-or-later; its data is
-- read from the WoW: Forever client tables via wago.tools and CMaNGOS
-- classic-db). Only recipe facts are taken: profession, name, product,
-- amount, required skill and reagents.
--
-- Usage (LuaJIT or Lua 5.1):
--   luajit tools/import_skillup.lua <skillup-forever checkout> Data/ItemNames.lua > Data/RecipeData.lua
local root, namesFile = arg[1], arg[2]
assert(root, "usage: import_skillup.lua <skillup-forever dir> [Data/ItemNames.lua]")

local ns = {}
local function load(file)
    local chunk = assert(loadfile(root .. "/Data/" .. file))
    chunk("SkillUpForever", ns)
end
load("Recipes.lua") load("Thresholds.lua") load("Trainer.lua")

-- product names as a last resort for recipes whose name is ambiguous
local itemName = {}
if namesFile then
    GathercraftItemNames = nil
    dofile(namesFile)
    for id, name in (GathercraftItemNames or ""):gmatch("(%d+)\t([^\r\n]+)") do itemName[tonumber(id)] = name end
end

local WANT = { -- skill line -> Gathercraft profession name
    [171] = "Alchemy", [164] = "Blacksmithing", [333] = "Enchanting", [202] = "Engineering",
    [165] = "Leatherworking", [197] = "Tailoring", [185] = "Cooking", [129] = "First Aid", [186] = "Mining",
}

-- spell ID -> recipe name, per skill line
local spellName = {}
for line, list in pairs(ns.RecipeNames or {}) do
    for name, id in pairs(list) do
        if id then spellName[id] = spellName[id] or name end
    end
end

-- Blizzard hotfixes that came after the SkillUp data. Only what Blizzard's
-- hotfix text says; applied on top of the import.
--   06.11.2026, WoW: Forever hotfixes: Tanning Rack (Leatherworking) needs
--   skill 125 instead of 140, its skill-up thresholds are 15 lower.
-- Each one is bound to the source values it was written for ("from": the
-- required skill and the yellow and grey thresholds before the hotfix). A
-- source that has the new values already is left alone (with a note); one
-- with other values too, with a warning: look at the hotfix again.
local HOTFIXES = {
    [1263031] = { name = "Tanning Rack", from = { required = 140, yellow = 140, grey = 145 }, required = 125, shift = -15 },
}
local function Warn(text) io.stderr:write("hotfix " .. text .. "\n") end
for spell, h in pairs(HOTFIXES) do
    local t = ns.Thresholds and ns.Thresholds[spell]
    if t and t[2] == h.from.yellow and t[4] == h.from.grey then
        for i = 1, 4 do if t[i] then t[i] = t[i] + h.shift end end
    elseif t and t[2] == h.from.yellow + h.shift and t[4] == h.from.grey + h.shift then
        Warn(("%s: the source has the new thresholds already, left as they are"):format(h.name))
    elseif t then
        Warn(("%s: thresholds %s:%s in the source, the hotfix is for %d:%d: left as they are"):format(h.name,
            tostring(t[2]), tostring(t[4]), h.from.yellow, h.from.grey))
    end
end

local out, counts, skipped, guessed, nGuessed, spellOf = {}, {}, 0, {}, 0, {}
for spell, r in pairs(ns.RecipeData) do
    local prof = WANT[r.skillLine]
    local name = spellName[spell]
    local product, qty = 0, 1
    if r.output then product, qty = r.output.itemID, r.output.quantity or 1 end
    if not name and product > 0 then name = itemName[product] end
    if prof and name and r.reagents and #r.reagents > 0 then
        local req = 0
        local fee = ns.TrainerFees and ns.TrainerFees[spell]
        local scroll = ns.RecipeScrolls and ns.RecipeScrolls[spell]
        local t = ns.Thresholds and ns.Thresholds[spell]
        -- SkillUp moved some trainer requirements from Classic's by as much as
        -- Forever moved the recipe's colours: right for most, not all
        local isGuess = ns.TrainerInferred and ns.TrainerInferred[spell] ~= nil
        if type(fee) == "table" and fee[2] then req = fee[2]
        elseif scroll and scroll[2] then req = scroll[2]
        elseif t and t[1] and t[1] > 1 then req = t[1] end
        local h = HOTFIXES[spell]
        if h and req == h.from.required then
            req, isGuess = h.required, false
        elseif h and req ~= h.required then
            Warn(("%s: skill %d in the source, the hotfix is for %d: left as it is"):format(h.name, req, h.from.required))
        end
        local parts = {}
        for _, g in ipairs(r.reagents) do parts[#parts + 1] = g.itemID .. ":" .. g.quantity end
        local lo, hi = math.floor(qty), math.ceil(qty)
        local packed = ("%d:%d:%d:%d|%s"):format(product, lo, hi, req, table.concat(parts, ","))
        out[prof] = out[prof] or {}
        if not out[prof][name] then
            out[prof][name] = packed
            spellOf[prof] = spellOf[prof] or {}
            spellOf[prof][name] = spell
            counts[prof] = (counts[prof] or 0) + 1
            if isGuess and req > 0 then
                guessed[prof] = guessed[prof] or {}
                guessed[prof][name] = true
                nGuessed = nGuessed + 1
            end
        end
    else
        skipped = skipped + 1
    end
end

local function q(s) return ("%q"):format(s) end
local profs = {}
for p in pairs(out) do profs[#profs + 1] = p end
table.sort(profs)
local total, summary = 0, {}
for _, p in ipairs(profs) do total = total + counts[p]; summary[#summary + 1] = p .. " " .. counts[p] end
print("-- Generated by tools/import_skillup.lua, do not edit by hand.")
print("-- Recipes from SkillUp Forever (https://github.com/cjber/skillup-forever, GPL-3.0-or-later),")
print("-- which reads them from the WoW: Forever client tables (wago.tools) and CMaNGOS classic-db.")
print("-- Blizzard hotfixes applied on top: see HOTFIXES in tools/import_skillup.lua.")
print("-- " .. total .. " recipes: " .. table.concat(summary, ", "))
print('-- profession -> recipe name -> "product:min:max:requiredSkill|reagent:count,..." (product 0 = no item, e.g. enchants)')
print("GathercraftRecipeData = {")
print('    version = "skillup-forever",')
print("    professions = {")
for _, p in ipairs(profs) do
    print("        [" .. q(p) .. "] = {")
    local names = {}
    for n in pairs(out[p]) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do print("            [" .. q(n) .. "] = " .. q(out[p][n]) .. ",") end
    print("        },")
end
print("    },")
print("    -- recipe spell IDs: the game names them in the client's language")
print("    spells = {")
for _, p in ipairs(profs) do
    local names = {}
    for n in pairs(spellOf[p]) do names[#names + 1] = n end
    table.sort(names)
    local parts = {}
    for _, n in ipairs(names) do parts[#parts + 1] = "[" .. q(n) .. "]=" .. spellOf[p][n] end
    print("        [" .. q(p) .. "] = { " .. table.concat(parts, ", ") .. " },")
end
print("    },")
-- skill-up colours per recipe spell: "yellow:grey" (orange from the required
-- skill, green halfway between yellow and grey) - for the skill planner
print("    -- skill-up colours per recipe spell: \"yellow:grey\"")
print("    colors = {")
local spellList = {}
for _, p in ipairs(profs) do
    for _, spell in pairs(spellOf[p]) do spellList[#spellList + 1] = spell end
end
table.sort(spellList)
local seen, parts = {}, {}
for _, spell in ipairs(spellList) do
    local t = ns.Thresholds and ns.Thresholds[spell]
    if t and not seen[spell] and t[2] and t[4] and t[4] > t[2] then
        seen[spell] = true
        parts[#parts + 1] = ("[%d]=\"%d:%d\""):format(spell, t[2], t[4])
        if #parts == 8 then print("        " .. table.concat(parts, ", ") .. ",") parts = {} end
    end
end
if #parts > 0 then print("        " .. table.concat(parts, ", ") .. ",") end
print("    },")
print("    -- required skill estimated (Forever moved it from Classic's); a trainer visit confirms it")
print("    guessed = {")
for _, p in ipairs(profs) do
    if guessed[p] then
        local names = {}
        for n in pairs(guessed[p]) do names[#names + 1] = n end
        table.sort(names)
        local parts = {}
        for _, n in ipairs(names) do parts[#parts + 1] = "[" .. q(n) .. "] = true" end
        print("        [" .. q(p) .. "] = { " .. table.concat(parts, ", ") .. " },")
    end
end
print("    },")
print("}")
io.stderr:write(("recipes %d (%s), skipped %d, estimated skill %d\n"):format(total, table.concat(summary, ", "), skipped, nGuessed))
