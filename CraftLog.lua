local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Craft log: what each finished craft did to your skill (the data a better
-- skill plan needs: how often a recipe of a colour really gives a point)
--   * one entry per craft, kept on this computer only, never shared:
--     time, game build, profession, recipe spell and name, skill before and
--     after, the rank's maximum, the colour from the recipe's thresholds
--     (orange / yellow / grey, "unknown" without them; no green threshold
--     is made up) and how many items it made
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

-- the colour of a recipe at a skill: orange below the yellow threshold,
-- grey from the grey one, "yellow" in between. The shipped colours keep
-- only yellow and grey; no green threshold is made up (v0.1.20 K3, skill
-- plan 2.0 concept 4.1) - the real statistic is the distance to grey below
local function Colour(spell, skill)
    local c = GathercraftRecipeData and GathercraftRecipeData.colors and GathercraftRecipeData.colors[spell]
    local yellow, grey
    if c then yellow, grey = c:match("^(%d+):(%d+)$") end
    yellow, grey = tonumber(yellow), tonumber(grey)
    if not (yellow and grey and skill) then return "unknown", yellow, grey end
    if skill < yellow then return "orange", yellow, grey end
    if skill < grey then return "yellow", yellow, grey end
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

---------------------------------------------------------------------------
-- No reliable "before" (v0.1.21 T8). Sven, 11.11.2026: recording switched
-- off and on again for a craft or two in the middle of Create All (Cooking,
-- every craft exactly +1 in the chat) - and the log said "a craft there
-- gave more than one point" and stopped counting Cooking's series.
-- What happened: the cast running through the switch is over for the log,
-- its success is ignored. The next cast starts in the same moment - its
-- start is seen, the skill is read, but the point of the ignored craft has
-- not arrived yet. 1.5 s after its own success the skill is two higher: a
-- craft "alone" with +2.
-- The skill read at a start is a "before" only when no craft the log is
-- not reading has just succeeded. So every craft success the log does not
-- read itself is noted (`unread`): one made while recording is off, one of
-- a cast that was over for the log (begun before a switch or a clear), one
-- with a hidden cast ID, readings dropped by a hard break, and whatever
-- happened before this file could see anything (login, reload, a loading
-- screen). A cast that starts within SETTLE of that, and a success whose
-- start was never seen at all, is "blind":
--   * it is marked overlapping at once - which it is: its reading shares
--     the time with a craft before it - so it is in no rate, opens and
--     joins no series, and is never proof of a multi-point craft;
--   * the entry says why (blind = "settle" / "start"); without a seen start
--     no "before" is kept at all - what was read then is none.
-- Nothing is estimated: the crafts after it in the same Create All stay
-- overlapping as well (each start falls into the reading of the one
-- before), until a craft starts with nothing left to settle.
--
-- A success that cannot be told apart (v0.1.21 R1; Codex 11.11.2026, M1 -
-- a guess about the client, closed all the same): a success of the player
-- that comes without a cast ID, or whose spell the client hides while the
-- cast is not one the log is following. It may have been a craft. Whether
-- the client ever sends one like that is not known, and the log does not
-- depend on it: such a success is treated as a craft the log does not
-- read - what starts within SETTLE of it is blind, what is being read
-- right now shares its reading - and nothing else: no entry, no recipe, no
-- point, no craft counted. What it is NOT: a success whose spell can be
-- read and is no recipe is no craft, whatever its cast ID. There is no
-- further guess at "was a profession window open": a wrong "no" would
-- open the gap again, and the price of leaving it out is one craft (and
-- the Create All it begins) that starts within 1.5 s of a spell the client
-- hid.
---------------------------------------------------------------------------
local unread = GetTime and GetTime() or nil -- when the last craft the log does not read succeeded
local function Unread() unread = GetTime() end
local function Unsettled() return unread ~= nil and GetTime() - unread < SETTLE end
---------------------------------------------------------------------------
-- Series (v0.1.20 K2, Sven 09.11.): "Create All" casts the same recipe
-- again the moment the last one succeeded, so every craft but the last is
-- still being read when the next starts. Alone they say nothing; together
-- they do: n casts, the skill before the first and after the last. Such a
-- block counts (n tries, k skill-ups) only when it is clear - one recipe
-- throughout, no failure, abort or hidden value in it, not at the rank's
-- maximum, k <= n, the same colour for every skill the series passes and,
-- for yellow/green, the same distance group to grey (orange has none: it
-- is never in the distance lines). Otherwise all of it stays
-- "overlapping" as before: nothing is estimated or split.
--
-- A series ended by a cast that failed or was aborted (v0.1.21 T7; Sven,
-- 11.11.2026: Create All is usually ended by moving, and 5 clean crafts
-- were lost with the sixth cast): that cast is not one of the series'
-- crafts. It leaves the series - logged as failed or interrupted, as
-- before - and the block is the successes before it, by all the rules
-- above. Only when a cast of the same series succeeds after it was the
-- failure "inside": then nothing of the series counts, as before.
-- Why the block's end is right: its "after" is read SETTLE after the last
-- success, and between the first cast's start and that reading nothing
-- but the series' own successes gave a point - a cast that fails or is
-- aborted makes nothing and gives none, and any other craft starting or
-- ending in that time breaks the series (Chain, Overlap).
--
-- k points = k crafts that gave a point (Sven 09.11., Codex B2): in WoW:
-- Forever a craft gives at most ONE skill point (Classic rules), so k
-- points in n crafts are k successes, also for 0 < k < n. This is an
-- assumption, and it is watched: the moment one craft alone is measured
-- with more than one point (a single craft, or the first of a series read
-- before the next one succeeded), the profession is noted in
-- ns.db.craftMulti and its series are no longer counted - they stay
-- "overlapping", and /gcr craftlog says so. Nothing is guessed or split.
-- /gcr craftlog clear forgets the note with everything else.
---------------------------------------------------------------------------
local series            -- the open series: its last craft is still being read
local inSeries = setmetatable({}, { __mode = "k" }) -- entry -> its series

-- a reading is going on: what starts or ends now shares it (and breaks an
-- open series: the shared reading is no longer one recipe's)
local function Overlap(c)
    if not next(reading) then return end
    if c then c.overlap = true end
    for e in pairs(reading) do e.overlap = true end
    if series then series.broken = true end
end

-- a cast of the series still running (started, not yet succeeded or failed)
local function Pending(s)
    for _, c in pairs(casts) do
        if c.series == s then return true end
    end
    return false
end

-- a cast starting while the one before is still read: the same recipe
-- continues (or opens) a series; anything else is an overlap
local function Chain(c)
    if not next(reading) then
        if series and not Pending(series) then series = nil end
        return false
    end
    if not series then
        local e = next(reading)
        if next(reading, e) ~= nil or e.overlap or inSeries[e] or e.spell ~= c.spell then return false end
        series = { spell = c.spell, entries = { e }, n = 1 }
        inSeries[e] = series
    elseif series.broken or series.spell ~= c.spell then
        series.broken = true
        return false
    end
    series.n = series.n + 1
    c.series = series -- (also after a failure in it: only a success after it breaks the series, see Succeeded)
    return true
end

local function Bucket(gap) return math.min(4, math.floor(math.max(0, gap) / 5)) end -- 0-4, 5-9, 10-14, 15-19, 20+

-- one craft alone gave more than one point in this profession (see above)
local function SawMulti(prof)
    if not prof then return end
    ns.db.craftMulti = ns.db.craftMulti or {}
    ns.db.craftMulti[prof] = true
end
-- ever seen: the note, or a clear single craft in the log that says so
-- (logs of 0.1.18 / 0.1.19 have no note yet)
local function MultiSeen(prof)
    local m = ns.db.craftMulti
    if m and m[prof] then return true end
    for _, e in ipairs(DB()) do
        if e.multi and e.prof == prof and not e.kind and not e.overlap and not e.secret and not e.blind then
            SawMulti(prof)
            return true
        end
    end
    return false
end

-- the series is over (its last reading is done): one block when it is clear
local function Finish(s)
    for _, e in ipairs(s.entries) do e.overlap = true end -- each alone says nothing
    if s.broken or #s.entries < 2 or #s.entries ~= s.n then return end
    for _, e in ipairs(s.entries) do
        if e.result ~= "ok" or e.secret or e.spell ~= s.spell then return end
    end
    local first, last = s.entries[1], s.entries[#s.entries]
    local before, after = first.before, last.after
    if not (before and after) then return end
    local gain = after - before
    if gain < 0 or gain > s.n then return end
    -- k points are k successes only while no craft of this profession was
    -- ever seen to give more than one (Codex B2)
    if MultiSeen(first.prof) then return end
    if first.max and after >= first.max then return end
    local colour, yellow, grey = Colour(s.spell, before)
    if colour == "unknown" then return end
    -- the same colour for every skill the series passes; the same distance
    -- group to grey only for yellow/green. Orange is left out on purpose
    -- (Sven 09.11., Codex B4): an orange craft always gives its point, and
    -- orange never goes into the distance lines (Tally below), so its
    -- distance to grey says nothing about the block.
    for skill = before, after do
        local c = Colour(s.spell, skill)
        if c ~= colour then return end
        if colour ~= "orange" and Bucket(grey - skill) ~= Bucket(grey - before) then return end
    end
    for _, e in ipairs(s.entries) do e.inSeries = true end -- counted by the block, not as overlapping
    if On() then
        Add({ kind = "series", t = first.t, build = first.build, prof = first.prof, spell = s.spell, recipe = first.recipe,
            n = s.n, before = before, after = after, gain = gain, max = first.max, colour = colour, yellow = yellow, grey = grey,
            result = "ok" })
    end
end
local done = {}    -- castGUID -> true: logged, later events of it change nothing
local doneOrder = {}

-- ignored: over for the log without having been logged (begun while off,
-- or open at a hard break) - its success, when it comes, is a craft the log
-- does not read (T8). A cast that was logged stays "logged".
local function Done(guid, ignored)
    if done[guid] == nil then
        doneOrder[#doneOrder + 1] = guid
        if #doneOrder > 200 then done[table.remove(doneOrder, 1)] = nil end
    end
    if done[guid] ~= true then done[guid] = ignored and "ignored" or true end
end

---------------------------------------------------------------------------
-- A hard break (Codex 09.11., B1): recording switched off or on, or the log
-- cleared. Nothing open lives on past it: casts still running are over for
-- the log (their later events change nothing), crafts still being read are
-- dropped (their second reading would fall into the other state), an open
-- series ends broken - what it already logged stays "overlapping".
---------------------------------------------------------------------------
local function Break()
    generation = generation + 1
    if next(reading) then Unread() end -- their points may still be on the way (T8)
    wipe(reading)
    for guid in pairs(casts) do Done(guid, true) end
    wipe(casts)
    local s = series
    series = nil
    if s then
        s.broken = true
        for _, e in ipairs(s.entries) do e.overlap = true end
    end
end
ns.CraftLogBreak = Break -- the option's switch (Options.lua)

-- on or off now; a change since the last look is a hard break. The option
-- calls Break itself; this also catches a change made any other way, at the
-- next event or reading.
local wasOn
local function State()
    local on = On() and true or false
    if wasOn ~= nil and on ~= wasOn then Break() end
    wasOn = on
    return on
end

-- late: the cast's start was not seen - "ok" when it has succeeded now,
-- "failed" when it failed (a failure makes nothing: handled as before)
local function Start(guid, spell, late)
    local r = Recipe(spell)
    if not r then return end
    local before, maxRank, secret = Rank(r.prof)
    local product = Product(r.prof, r.key)
    local had, hidden = Count(product)
    local c = { spell = spell, prof = r.prof, key = r.key, before = before, max = maxRank, secret = secret or hidden,
        product = product, had = had, t = time() }
    if late == "ok" or Unsettled() then
        -- no reliable "before" (T8, see above): overlapping from the start,
        -- in no series; what is being read now shares its reading with it
        c.blind = late == "ok" and "start" or "settle"
        if late == "ok" then c.before = nil end
        Overlap(c)
        c.overlap = true
        if series then series.broken = true end
    else
        if late then c.blind = "start" end
        if not Chain(c) then Overlap(c) end
    end
    casts[guid] = c
    return c
end

local function Entry(c, result)
    local colour, yellow, grey = Colour(c.spell, c.before)
    local build = GetBuildInfo and select(2, GetBuildInfo())
    return { t = c.t, build = tonumber(build) or build, prof = c.prof, spell = c.spell, recipe = c.key,
        before = c.before, max = c.max, colour = colour, yellow = yellow, grey = grey,
        result = result, secret = c.secret or nil, overlap = c.overlap or nil, blind = c.blind,
        atCap = (c.before and c.max and c.before >= c.max) or nil }
end

local function Succeeded(guid, spell)
    local c = casts[guid] or Start(guid, spell, "ok") -- (a start that was never seen: blind, T8)
    if not c then return end
    casts[guid] = nil
    Done(guid)
    local e = Entry(c, "ok")
    if c.series then
        -- a success after a cast of the series failed: that failure was
        -- inside the series, not its end - no block (T7)
        if c.series.ended then c.series.broken = true end
        inSeries[e] = c.series
        table.insert(c.series.entries, e)
    else
        Overlap(e)
    end
    reading[e] = true
    local gen = generation
    C_Timer.After(SETTLE, function()
        State() -- switched off meanwhile: a hard break, this reading is dropped
        reading[e] = nil
        if gen ~= generation then return end -- cleared or switched meanwhile (Codex N2, B1)
        local after, _, secret = Rank(c.prof)
        e.after = after
        if secret then e.secret = true end
        if e.before and after then
            local gain = after - e.before
            e.gain = gain
            if gain > 1 then
                e.multi = true
                -- this craft alone gave them: a single one, or the first of
                -- a series while no later one has succeeded yet. (Later ones
                -- may hold the point of the craft before: not proof.)
                local s = inSeries[e]
                if not e.overlap and not e.secret and (not s or (s.entries[1] == e and #s.entries == 1)) then
                    SawMulti(c.prof)
                end
            end
        end
        if c.product and c.had then
            local now, hidden = Count(c.product)
            if hidden then e.secret = true end
            if now and now >= c.had then e.made = now - c.had end
        end
        if On() then Add(e) end
        local s = inSeries[e]
        if s and not next(reading) and not Pending(s) then
            -- the last reading of the series, no cast of it running: the
            -- block is judged now
            if series == s then series = nil end
            Finish(s)
        end
    end)
end

local function Failed(guid, spell, result)
    local c = casts[guid] or Start(guid, spell, "failed") -- also a cast that never started
    if not c then return end
    casts[guid] = nil
    Done(guid)
    if On() then Add(Entry(c, result)) end
    local s = c.series
    if s then
        -- not one of the series' crafts: it leaves the series, which ends
        -- with the success before it (T7; a success after it breaks it)
        s.n = s.n - 1
        s.ended = true
        if not next(reading) and not Pending(s) then
            if series == s then series = nil end
            Finish(s) -- nothing left to read: its entries are marked now
        end
    end
end

local HIDDEN_REPEAT = 0.5 -- seconds; no craft is that fast
local hiddenLast = {}     -- recipe spell -> when its last hidden-ID success came

-- a craft has succeeded that the log does not read: a recipe's spell, or a
-- spell the client hid (it may be one)
local function UnreadCraft(event, spell)
    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end
    if ns.AnySecret("craft log unread", spell) or Recipe(spell) then Unread() end
end

-- A craft the log does not read has succeeded while another cast is
-- running (Codex 12.11.2026, round 2, V1). That cast has read its "before"
-- at its start already and will read its "after" once it succeeds - the
-- other craft's point lies in between. It is overlapping from here on
-- (blind = "during"), its series is broken. The same rule as for what
-- starts next and for what is being read; no new time window.
local function OverlapRunning()
    for _, c in pairs(casts) do
        c.overlap = true
        c.blind = c.blind or "during"
        if c.series then c.series.broken = true end
    end
end

-- the same for a success that cannot be told apart while recording is on
-- (R1): what is being read now shares its reading with it, too - and what
-- is being cast (V1)
local function UntoldSuccess(event, spell)
    if event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end
    if ns.AnySecret("craft log untold", spell) or Recipe(spell) then
        Overlap()
        OverlapRunning()
        Unread()
    end
end

local watch = CreateFrame("Frame")
for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED" }) do
    if watch.RegisterUnitEvent then pcall(watch.RegisterUnitEvent, watch, e, "player") else pcall(watch.RegisterEvent, watch, e) end
end
pcall(watch.RegisterEvent, watch, "PLAYER_ENTERING_WORLD")
watch:SetScript("OnEvent", function(_, event, unit, guid, spell)
    if event == "PLAYER_ENTERING_WORLD" then
        -- login, reload, a loading screen: what succeeded just before was not seen (T8)
        Unread()
        return
    end
    if unit ~= "player" then return end
    if not State() then
        -- off: nothing is recorded. A cast seen now is over for the log, so
        -- its success after switching on again is not taken for a new craft
        -- (and any craft now, of whatever recipe, has ended an open series:
        -- the switch was a hard break)
        if guid ~= nil and not ns.AnySecret("craft log off", guid) then Done(guid, true) end
        UnreadCraft(event, spell)
        return
    end
    if ns.AnySecret("craft log " .. event, guid) then
        -- the client hid which cast it was. A craft only when its spell can
        -- be read and is a recipe (a hidden spell is no craft at all; Codex
        -- M2); its events repeat without an ID to tell them apart: one
        -- success of a recipe within HIDDEN_REPEAT is the same craft
        if event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end
        if ns.AnySecret("craft log " .. event, spell) then
            -- neither the cast nor the spell can be read: no craft is
            -- logged, but it may have been one (R1)
            UntoldSuccess(event, spell)
            return
        end
        local r = Recipe(spell)
        if not r then return end
        local now = GetTime()
        if hiddenLast[spell] and now - hiddenLast[spell] < HIDDEN_REPEAT then return end
        hiddenLast[spell] = now
        local e = { t = time(), prof = r.prof, spell = spell, recipe = r.key, result = "ok", secret = true, colour = "unknown" }
        -- a craft all the same: one still being read shares its readings (Codex B1)
        Overlap(e)
        OverlapRunning() -- (and one being cast, V1)
        Add(e)
        Unread() -- its own point is read by nobody (T8)
        return
    end
    if not guid then
        -- no cast ID at all: nothing to follow or to log; a success of a
        -- recipe or of a hidden spell is a craft the log does not read (R1)
        UntoldSuccess(event, spell)
        return
    end
    if done[guid] then
        -- over for the log. Never logged (begun while off, open at a hard
        -- break): its success now is a craft the log does not read (T8).
        -- Logged already: a repeated event, nothing new.
        if done[guid] == "ignored" then UntoldSuccess(event, spell) end
        return
    end
    if not casts[guid] and ns.AnySecret("craft log " .. event, spell) then
        -- a cast the log is not following, and its spell is hidden: nothing
        -- to log. It is over for the log; its success - now or later - is one
        -- that cannot be told apart (R1)
        Done(guid, true)
        UntoldSuccess(event, spell)
        return
    end
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
-- "yellow" stands for everything between the yellow and the grey threshold
-- and says so ("yellow/green"); entries of 0.1.18/0.1.19 that still carry
-- "green" are counted there
local COLOURS = { "orange", "yellow", "grey", "unknown" }
local COLOUR_CODE = { orange = "|cffff8040", yellow = "|cffffff00", grey = "|cff808080", unknown = "|cffffffff" }
local COLOUR_LABEL = { orange = "orange", yellow = "yellow/green", grey = "grey", unknown = "unknown" }
local function ColourKey(colour) return colour == "green" and "yellow" or colour end

-- attempts and skill-ups of the finished crafts that count: read skill
-- before and after, not at the rank's maximum
local function Summary(log)
    local byColour, byGap = {}, {}
    local other = { failed = 0, secret = 0, cap = 0, multi = 0, overlap = 0, series = 0, seriesTries = 0, seriesUps = 0 }
    local function Tally(colour, grey, before, tries, ups)
        local key = ColourKey(colour)
        local c = byColour[key] or { tries = 0, ups = 0 }
        byColour[key] = c
        c.tries, c.ups = c.tries + tries, c.ups + ups
        if grey and before and colour ~= "orange" then
            local bucket = Bucket(grey - before)
            local g = byGap[bucket] or { tries = 0, ups = 0 }
            byGap[bucket] = g
            g.tries, g.ups = g.tries + tries, g.ups + ups
        end
    end
    for _, e in ipairs(log) do
        if e.kind == "series" then
            -- a clear block (K2): n tries, k skill-ups, one colour and distance group
            other.series, other.seriesTries, other.seriesUps = other.series + 1, other.seriesTries + e.n, other.seriesUps + e.gain
            Tally(e.colour, e.grey, e.before, e.n, e.gain)
        elseif e.result ~= "ok" then
            other.failed = other.failed + 1
        elseif e.inSeries then
            -- counted by its block
        elseif e.overlap then
            other.overlap = other.overlap + 1
        elseif e.secret or not e.gain then
            other.secret = other.secret + 1
        elseif e.atCap then
            other.cap = other.cap + 1
        else
            if e.multi then other.multi = other.multi + 1 end
            Tally(e.colour, e.grey, e.before, 1, e.gain > 0 and 1 or 0)
        end
    end
    return byColour, byGap, other
end
ns.CraftLogSummary = function() return Summary(DB()) end

-- how many crafts the log knows of (Codex B3): a block stands for its n
-- casts, and those casts (inSeries) are not counted a second time - also
-- right when the oldest of them have left a full log. Finished crafts only
-- (v0.1.21 T7): a cast that failed or was interrupted made nothing, it
-- stands under "Not counted" alone.
local function Crafts(log)
    local n = 0
    for _, e in ipairs(log) do
        if e.kind == "series" then
            n = n + e.n
        elseif e.result == "ok" and not e.inSeries then
            n = n + 1
        end
    end
    return n
end
ns.CraftLogCrafts = function() return Crafts(DB()) end

local function Rate(x) return x.tries > 0 and math.floor(100 * x.ups / x.tries + 0.5) or 0 end

ns.CraftLogCommand = function(rest)
    rest = (rest or ""):lower()
    if rest == "clear" then
        -- a hard break: crafts still being read are dropped too (Codex N2),
        -- a series in the middle gives no block, casts still running are
        -- done already (Codex B2)
        Break()
        ns.db.craftLog = {}
        ns.db.craftMulti = nil -- what was measured is gone, the note with it
        ns.Print(L["Craft log cleared."])
        return
    end
    local log = DB()
    ns.Print((L["Craft log: %d crafts (kept on this computer, never shared)."]):format(Crafts(log)))
    if ns.db.craftLogOff then print(L["  Recording is off (Options > General)."]) end
    if #log == 0 then return end
    local byColour, byGap, other = Summary(log)
    for _, colour in ipairs(COLOURS) do
        local c = byColour[colour]
        if c then
            local label = COLOUR_CODE[colour] .. L[COLOUR_LABEL[colour]] .. "|r"
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
    if other.series > 0 then
        print((L["  from series (Create All): %d series, %d crafts, %d skill-ups - counted above"]):format(other.series, other.seriesTries, other.seriesUps))
    end
    -- professions whose series are no longer counted (a craft gave more than one point)
    local noSeries = {}
    for prof in pairs(ns.db.craftMulti or {}) do noSeries[#noSeries + 1] = prof end
    table.sort(noSeries)
    for _, prof in ipairs(noSeries) do
        print((L["  Series of %s are not counted: a craft there gave more than one point."]):format(L[prof]))
    end
    print((L["  Not counted: %d failed or interrupted, %d unreadable, %d overlapping, %d at the rank's maximum; %d gave more than one point."]):format(
        other.failed, other.secret, other.overlap, other.cap, other.multi))
end
