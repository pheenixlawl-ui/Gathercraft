local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Craft log: what each finished craft did to your skill (the data a better
-- skill plan needs: how often a recipe of a colour really gives a point)
--   * one entry per craft, kept on this computer only, never shared:
--     time, game build, profession, recipe spell and name, skill before and
--     after, the rank's maximum, the colour from the recipe's thresholds
--     (orange / yellow / green / grey, "unknown" without them) and how many
--     items it made
--   * marked apart: failed or interrupted casts, values the client hid
--     (secret), a gain of more than one point, a craft at the rank's maximum
--   * one entry per cast: a repeated or late event of the same cast is not
--     another craft
--   * only clear observations count (Codex M1, 08.11.): a craft that starts
--     or ends while the one before is still being read shares its readings
--     with it; both are marked overlapping and left out of the rates
--   * a cast the client hides the ID of counts only when its spell is a
--     known recipe (Codex M2); hidden amounts or skills: unreadable (V1)
--   * the newest MAX_ENTRIES are kept; Options > General turns it off
--   * nothing here crafts or changes a craft: it only watches
--   /gcr craftlog         what the log says, per colour and per distance to grey
--   /gcr craftlog clear   empties it
---------------------------------------------------------------------------
local MAX_ENTRIES = 5000
local SETTLE = 1.5 -- seconds after a craft before skill and bags are read again

local function DB()
    ns.db.craftLog = ns.db.craftLog or {}
    return ns.db.craftLog
end
local function On() return ns.db and not ns.db.craftLogOff end

-- recipe spell -> profession, recipe name (shipped data)
local bySpell
local function Recipe(spell)
    if not bySpell then
        bySpell = {}
        for prof, list in pairs(GathercraftRecipeData and GathercraftRecipeData.spells or {}) do
            for name, id in pairs(list) do bySpell[id] = { prof = prof, key = name } end
        end
    end
    return bySpell[spell]
end

-- the colour of a recipe at a skill: orange up to yellow, green from halfway
-- between yellow and grey (the shipped colours keep only yellow and grey)
local function Colour(spell, skill)
    local c = GathercraftRecipeData and GathercraftRecipeData.colors and GathercraftRecipeData.colors[spell]
    local yellow, grey
    if c then yellow, grey = c:match("^(%d+):(%d+)$") end
    yellow, grey = tonumber(yellow), tonumber(grey)
    if not (yellow and grey and skill) then return "unknown", yellow, grey end
    if skill < yellow then return "orange", yellow, grey end
    if skill < (yellow + grey) / 2 then return "yellow", yellow, grey end
    if skill < grey then return "green", yellow, grey end
    return "grey", yellow, grey
end

local function Rank(prof)
    if not ns.ProfessionRank then return end
    local rank, maxRank = ns.ProfessionRank(prof)
    if ns.AnySecret("craft log", rank, maxRank) then return nil, nil, true end
    return rank, maxRank
end

local function Product(prof, key)
    local packed = GathercraftRecipeData.professions[prof] and GathercraftRecipeData.professions[prof][key]
    local product = packed and tonumber(packed:match("^(%d+):"))
    if product and product > 0 then return product end
end

-- the amount in the bags, or nil and true when the client hid it (Codex V1)
local function Count(item)
    local d = ns.CraftData
    local v = item and d and d.Have and d.Have(item)
    if v ~= nil and ns.AnySecret("craft log", v) then return nil, true end
    return v
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

local casts = {}   -- castGUID -> the cast while it runs
local reading = {} -- entries waiting for their second reading (SETTLE)
local generation = 0 -- /gcr craftlog clear: readings started before it are dropped
-- a reading is going on: what starts or ends now shares it
local function Overlap(c)
    if not next(reading) then return end
    if c then c.overlap = true end
    for e in pairs(reading) do e.overlap = true end
end
local done = {}    -- castGUID -> true: logged, later events of it change nothing
local doneOrder = {}

local function Done(guid)
    done[guid] = true
    doneOrder[#doneOrder + 1] = guid
    if #doneOrder > 200 then done[table.remove(doneOrder, 1)] = nil end
end

local function Start(guid, spell)
    local r = Recipe(spell)
    if not r then return end
    local before, maxRank, secret = Rank(r.prof)
    local product = Product(r.prof, r.key)
    local had, hidden = Count(product)
    local c = { spell = spell, prof = r.prof, key = r.key, before = before, max = maxRank, secret = secret or hidden,
        product = product, had = had, t = time() }
    Overlap(c)
    casts[guid] = c
    return c
end

local function Entry(c, result)
    local colour, yellow, grey = Colour(c.spell, c.before)
    local build = GetBuildInfo and select(2, GetBuildInfo())
    return { t = c.t, build = tonumber(build) or build, prof = c.prof, spell = c.spell, recipe = c.key,
        before = c.before, max = c.max, colour = colour, yellow = yellow, grey = grey,
        result = result, secret = c.secret or nil, overlap = c.overlap or nil,
        atCap = (c.before and c.max and c.before >= c.max) or nil }
end

local function Succeeded(guid, spell)
    local c = casts[guid] or Start(guid, spell)
    if not c then return end
    casts[guid] = nil
    Done(guid)
    local e = Entry(c, "ok")
    Overlap(e)
    reading[e] = true
    local gen = generation
    C_Timer.After(SETTLE, function()
        reading[e] = nil
        if gen ~= generation then return end -- cleared meanwhile (Codex N2)
        local after, _, secret = Rank(c.prof)
        e.after = after
        if secret then e.secret = true end
        if e.before and after then
            local gain = after - e.before
            e.gain = gain
            if gain > 1 then e.multi = true end
        end
        if c.product and c.had then
            local now, hidden = Count(c.product)
            if hidden then e.secret = true end
            if now and now >= c.had then e.made = now - c.had end
        end
        if On() then Add(e) end
    end)
end

local function Failed(guid, spell, result)
    local c = casts[guid] or Start(guid, spell) -- also a cast that never started
    if not c then return end
    casts[guid] = nil
    Done(guid)
    if On() then Add(Entry(c, result)) end
end

local HIDDEN_REPEAT = 0.5 -- seconds; no craft is that fast
local hiddenLast = {}     -- recipe spell -> when its last hidden-ID success came

local watch = CreateFrame("Frame")
for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED" }) do
    if watch.RegisterUnitEvent then pcall(watch.RegisterUnitEvent, watch, e, "player") else pcall(watch.RegisterEvent, watch, e) end
end
watch:SetScript("OnEvent", function(_, event, unit, guid, spell)
    if not On() or unit ~= "player" then return end
    if ns.AnySecret("craft log " .. event, guid) then
        -- the client hid which cast it was. A craft only when its spell can
        -- be read and is a recipe (a hidden spell is no craft at all; Codex
        -- M2); its events repeat without an ID to tell them apart: one
        -- success of a recipe within HIDDEN_REPEAT is the same craft
        if event ~= "UNIT_SPELLCAST_SUCCEEDED" or ns.AnySecret("craft log " .. event, spell) then return end
        local r = Recipe(spell)
        if not r then return end
        local now = GetTime()
        if hiddenLast[spell] and now - hiddenLast[spell] < HIDDEN_REPEAT then return end
        hiddenLast[spell] = now
        local e = { t = time(), prof = r.prof, spell = spell, recipe = r.key, result = "ok", secret = true, colour = "unknown" }
        -- a craft all the same: one still being read shares its readings (Codex B1)
        Overlap(e)
        Add(e)
        return
    end
    if not guid or done[guid] then return end
    if event == "UNIT_SPELLCAST_START" then
        if not casts[guid] then Start(guid, spell) end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        Succeeded(guid, spell)
    elseif event == "UNIT_SPELLCAST_FAILED" then
        Failed(guid, spell, "failed")
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        Failed(guid, spell, "interrupted")
    end
end)

---------------------------------------------------------------------------
-- /gcr craftlog
---------------------------------------------------------------------------
local COLOURS = { "orange", "yellow", "green", "grey", "unknown" }
local COLOUR_CODE = { orange = "|cffff8040", yellow = "|cffffff00", green = "|cff40c040", grey = "|cff808080", unknown = "|cffffffff" }
local COLOUR_NAME = { orange = L["orange"], yellow = L["yellow"], green = L["green"], grey = L["grey"], unknown = L["unknown"] }

-- attempts and skill-ups of the finished crafts that count: read skill
-- before and after, not at the rank's maximum
local function Summary(log)
    local byColour, byGap = {}, {}
    local other = { failed = 0, secret = 0, cap = 0, multi = 0, overlap = 0 }
    for _, e in ipairs(log) do
        if e.result ~= "ok" then
            other.failed = other.failed + 1
        elseif e.overlap then
            other.overlap = other.overlap + 1
        elseif e.secret or not e.gain then
            other.secret = other.secret + 1
        elseif e.atCap then
            other.cap = other.cap + 1
        else
            if e.multi then other.multi = other.multi + 1 end
            local up = e.gain > 0 and 1 or 0
            local c = byColour[e.colour] or { tries = 0, ups = 0 }
            byColour[e.colour] = c
            c.tries, c.ups = c.tries + 1, c.ups + up
            if e.grey and e.before and e.colour ~= "orange" then
                local gap = math.max(0, e.grey - e.before)
                local bucket = math.min(4, math.floor(gap / 5)) -- 0-4, 5-9, 10-14, 15-19, 20+
                local g = byGap[bucket] or { tries = 0, ups = 0 }
                byGap[bucket] = g
                g.tries, g.ups = g.tries + 1, g.ups + up
            end
        end
    end
    return byColour, byGap, other
end
ns.CraftLogSummary = function() return Summary(DB()) end

local function Rate(x) return x.tries > 0 and math.floor(100 * x.ups / x.tries + 0.5) or 0 end

ns.CraftLogCommand = function(rest)
    rest = (rest or ""):lower()
    if rest == "clear" then
        ns.db.craftLog = {}
        -- crafts still being read are dropped too (Codex N2)
        generation = generation + 1
        wipe(reading)
        -- and casts still running: their success or failure is done already (Codex B2)
        for guid in pairs(casts) do Done(guid) end
        wipe(casts)
        ns.Print(L["Craft log cleared."])
        return
    end
    local log = DB()
    ns.Print((L["Craft log: %d crafts (kept on this computer, never shared)."]):format(#log))
    if ns.db.craftLogOff then print(L["  Recording is off (Options > General)."]) end
    if #log == 0 then return end
    local byColour, byGap, other = Summary(log)
    for _, colour in ipairs(COLOURS) do
        local c = byColour[colour]
        if c then
            local label = COLOUR_CODE[colour] .. (ns.L and ns.L[colour] or COLOUR_NAME[colour]) .. "|r"
            print((L["  %s: %d crafts, %d skill-ups (%d%%)"]):format(label, c.tries, c.ups, Rate(c)))
        end
    end
    local GAPS = { "0-4", "5-9", "10-14", "15-19", "20+" }
    for bucket = 0, 4 do
        local g = byGap[bucket]
        if g then
            print((L["  %s points below grey: %d crafts, %d skill-ups (%d%%)"]):format(GAPS[bucket + 1], g.tries, g.ups, Rate(g)))
        end
    end
    print((L["  Not counted: %d failed or interrupted, %d unreadable, %d overlapping, %d at the rank's maximum; %d gave more than one point."]):format(
        other.failed, other.secret, other.overlap, other.cap, other.multi))
end
