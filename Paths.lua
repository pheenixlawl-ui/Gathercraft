local ADDON_NAME, ns = ...
local Wrap = ns.PerfWrap or function(_, fn) return fn end -- (/gcr perf on, Perf.lua: measured only while it is on)
local C_Timer = (C_Timer and ns.PerfTimers) and ns.PerfTimers("Paths") or C_Timer -- (/gcr perf on: every timer of this file)
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Paths (v0.1.22, part W): where you can ride, learned from where you ride.
--   Collected only - nothing uses it yet, nothing is sent, nothing leaves
--   this computer. Later a route can go around a cliff instead of through it.
--
--   A zone is cut into squares of 25 yards. Whenever you cross from one
--   square into a neighbour, that crossing ("path piece", an edge from ->
--   to) is counted with
--     - how often,
--     - its cost: the way you made inside the square you left (time x your
--       speed) divided by the straight line between the two squares'
--       centres. 1 = straight through; more = a detour, a slope you fought,
--       a wall you ran along. Speed x time makes walking, riding and every
--       level the same,
--     - how often you fell on it (in the air for a second or more - a jump
--       is shorter; such a piece may only go downwards). (0.2.3, 23.11.2026)
--       The time up there counts from the second look in the air on: at the
--       first one it is not known how long you have been up there. So a fall
--       is three looks in the air in a row, a second or more for sure; a
--       jump (about 0.8 s, two looks at most) never is one. Before, the
--       first look counted the whole half second before it, and two looks
--       of a jump made a "fall". Crossings made on the way down before the
--       fall is known get it when it is (as the old count gave it them);
--       landing first, they do not.
--     - how often you swam on it,
--     - the day you last used it (the day only, never a time).
--   No trace is kept: no list of the squares in the order you went, no
--   times, no names. (What is promised is that much. The pieces lie in a
--   table; nobody looked at whether the order they are written to the file
--   in tells anything about the order they were made in.)
--
--   No height is used. Where it was looked at (Sven's probe of 12.11.2026)
--   UnitPosition gave 0; that is one place, not a rule about the client.
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)

local TILE = 25           -- yards: the side of a square (W1)
local TICK = 0.5          -- seconds between two looks (W5: never more than two a second)
local GRID = 1024         -- squares per row in a key (a zone up to 25,600 yards wide)
local MAX_TOTAL = 30000   -- path pieces kept in all zones together (W4)
local MAX_ZONE = 8000     -- ... and in one zone
local PRUNE_SHARE = 0.1   -- at a limit this share goes, the longest unused first
local COUNT_MAX = 255     -- counts stop here (8 bits)
local COST_MAX = 1023     -- cost in hundredths stops here (10 bits: 10.23)
local FALL_SECONDS = 1.0  -- in the air this long without a break: a fall (a jump takes about 0.8 s)
local GAP_MAX = 2         -- seconds between two looks: longer was a hitch or a loading screen
local DAY0 = 20454        -- the day 2026-01-01, counted from 1970: days are kept from here (14 bits)
local BYTES_PER_PIECE = 27 -- one path piece in the saved file, about (measured in the smoke test)

local floor, min, max = math.floor, math.min, math.max
local SQRT2 = math.sqrt(2)

-- the eight neighbours: (dy + 1) * 3 + (dx + 1), 4 is the square itself
local function Dir(dx, dy) return (dy + 1) * 3 + (dx + 1) end

---------------------------------------------------------------------------
-- (0.2.4 S1) Whoever makes a net of the pieces (Ways.lua, only during a farm
-- run that shows its way) is told what changed in them:
--   "new"    a piece more in the zone mapID
--   "class"  a piece of the zone changed its fall class: it may be ridden the
--            other way now, or no longer
--   "gone"   pieces were removed (a limit, /gcr paths clear) - mapID nil: in
--            any zone
--   "data"   other saved data (a login, damaged data put right)
-- Nothing is told about a piece's cost or its count. With nobody listening
-- this is one empty check. Nothing new is saved for it and what is recorded
-- is what it was.
--   The fall class of a piece, from its counts as they are saved (they stop
--   at 255): 0 normal (no fall, or also ridden without one - those marks were
--   jumps), 1 an unsure fall (ridden once, with a fall), 2 a sure fall
--   (ridden twice or more, every time with a fall).
---------------------------------------------------------------------------
local listener
local function Changed(mapID, kind)
    if listener then listener(mapID, kind) end
end
local function FallClass(count, falls)
    if falls == 0 or falls < count then return 0 end
    if count >= 2 then return 2 end
    return 1
end

---------------------------------------------------------------------------
-- The saved data: ns.db.paths = {
--     off = true            only when turned off (on by default)
--     hinted = true         the one-time note was shown
--     total = n             path pieces in all zones
--     zones = { [mapID] = { n = pieces, e = { [key] = value } } }
-- }
--   key   = (ty * GRID + tx) * 9 + direction    the square you left and where to
--   value = (((swims * 256 + falls) * 1024 + cost) * 256 + count) * 16384 + day
--           (what is mostly 0 sits on top: the number stays short in the file)
---------------------------------------------------------------------------
-- Saved data can come back damaged (a file cut off, an edit by hand, a
-- version in between). It is looked through once when it is taken over -
-- never at every look - and put right where it is damaged, nowhere else
-- (R1 W-H1): a zone that is no zone goes, a zone without its table of pieces
-- starts empty, a piece that is not one whole number goes, and every count
-- is what is really there. Whoever recorded nothing wrong loses nothing.
local VALUE_MAX = 2 ^ 48
local KEY_MAX = GRID * GRID * 9
local function LookThrough(p)
    local total, gone = 0, {}
    for mapID, z in pairs(p.zones) do
        local n = 0
        if type(mapID) == "number" and type(z) == "table" then
            if type(z.e) ~= "table" then z.e = {} end
            local bad
            for key, v in pairs(z.e) do
                if type(key) == "number" and type(v) == "number" and key >= 0 and key < KEY_MAX and key == floor(key)
                    and v >= 0 and v < VALUE_MAX and v == floor(v) then
                    n = n + 1
                else
                    bad = bad or {}
                    bad[#bad + 1] = key
                end
            end
            if bad then
                for _, key in ipairs(bad) do z.e[key] = nil end
            end
            z.n = n
        end
        if n == 0 then gone[#gone + 1] = mapID end
        total = total + n
    end
    for _, mapID in ipairs(gone) do p.zones[mapID] = nil end
    p.total = total
end

local lookedThrough -- the saved table that was looked through (another one after a login or a profile change: again)
local function DB()
    local db = ns.db
    if not db then return end
    local p = db.paths
    if type(p) ~= "table" then
        p = {}
        db.paths = p
    end
    if type(p.zones) ~= "table" then
        p.zones, p.total = {}, 0
        Changed(nil, "data")
    end
    if type(p.total) ~= "number" then p.total = 0 end
    if lookedThrough ~= p then
        lookedThrough = p
        LookThrough(p)
        Changed(nil, "data")
    end
    return p
end

local function Pack(count, cost, falls, swims, day)
    return (((swims * 256 + falls) * 1024 + cost) * 256 + count) * 16384 + day
end

local function Unpack(v)
    local day = v % 16384
    v = (v - day) / 16384
    local count = v % 256
    v = (v - count) / 256
    local cost = v % 1024
    v = (v - cost) / 1024
    local falls = v % 256
    return count, cost, falls, (v - falls) / 256, day
end

local function Today()
    return max(0, min(16383, floor(time() / 86400) - DAY0))
end

-- A limit is reached: the pieces not used for the longest go first, about
-- a tenth of them (so this runs once in a few thousand new pieces, not at
-- every one). Within the last day that has to give, the rarely used first.
local function Prune(p, onlyZone)
    local days, total = {}, 0
    for mapID, z in pairs(p.zones) do
        if not onlyZone or mapID == onlyZone then
            for _, v in pairs(z.e) do
                local day = v % 16384
                days[day] = (days[day] or 0) + 1
                total = total + 1
            end
        end
    end
    if total < (onlyZone and MAX_ZONE or MAX_TOTAL) then
        -- no limit is reached: a count was wrong, not the data. Nothing has to go.
        LookThrough(p)
        Changed(onlyZone, "gone") -- (damaged pieces may have gone)
        return 0
    end
    local need = max(1, floor(total * PRUNE_SHARE + 0.5))
    local order = {}
    for day in pairs(days) do order[#order + 1] = day end
    table.sort(order)
    local cut, fromCut = order[1], need -- every day before `cut` goes, and `fromCut` pieces of that day
    for _, day in ipairs(order) do
        cut = day
        if days[day] >= fromCut then break end
        fromCut = fromCut - days[day]
    end
    -- of the day that is cut in part: the least used first
    local limit, counts = COUNT_MAX, {}
    if fromCut < days[cut] then
        for mapID, z in pairs(p.zones) do
            if not onlyZone or mapID == onlyZone then
                for _, v in pairs(z.e) do
                    if v % 16384 == cut then
                        local c = ((v - cut) / 16384) % 256
                        counts[c] = (counts[c] or 0) + 1
                    end
                end
            end
        end
        local left = fromCut
        for c = 0, COUNT_MAX do
            limit = c
            left = left - (counts[c] or 0)
            if left <= 0 then break end
        end
    end
    local removed = 0
    for mapID, z in pairs(p.zones) do
        if not onlyZone or mapID == onlyZone then
            local gone = {}
            for key, v in pairs(z.e) do
                local day = v % 16384
                if day < cut or (day == cut and fromCut > 0 and ((v - day) / 16384) % 256 <= limit) then
                    gone[#gone + 1] = key
                    if day == cut then fromCut = fromCut - 1 end
                end
            end
            for _, key in ipairs(gone) do z.e[key] = nil end
            z.n = z.n - #gone
            removed = removed + #gone
            if z.n <= 0 then p.zones[mapID] = nil end
        end
    end
    p.total = max(0, p.total - removed)
    Changed(onlyZone, "gone")
    return removed
end

-- One crossing: from square (tx, ty) of the zone into its neighbour (dx, dy)
local function Record(p, mapID, tx, ty, dx, dy, cost, fell, swam)
    local z = p.zones[mapID]
    if not z then
        z = { n = 0, e = {} }
        p.zones[mapID] = z
    end
    local key = (ty * GRID + tx) * 9 + Dir(dx, dy)
    local hundredths = max(100, min(COST_MAX, floor(cost * 100 + 0.5)))
    local v = z.e[key]
    if v then
        local count, mean, falls, swims = Unpack(v)
        local counted = count < COUNT_MAX
        local class = listener and FallClass(count, falls) -- (0.2.4 S1: only looked at while somebody listens)
        if counted then
            count = count + 1
            if fell then falls = falls + 1 end
            if swam then swims = swims + 1 end
        end
        -- The kept cost goes towards this crossing's by the step of the mean
        -- ((new - kept) / count, rounded to a hundredth) and by one hundredth
        -- at least whenever the two differ (R1 W-M2: rounding the mean itself
        -- lost every step under half a hundredth - after 255 crossings at
        -- 2.00 a thousand at 1.00 changed nothing). So: with few crossings it
        -- is the mean; a cost ridden again and again is reached after at
        -- most as many crossings as it is hundredths away; with mixed costs
        -- and many crossings it settles near the one ridden most (the
        -- middle one), not at the mean. Nothing more is kept for it.
        local diff = hundredths - mean
        if diff ~= 0 then
            local step = max(1, floor(math.abs(diff) / count + 0.5))
            mean = mean + (diff > 0 and step or -step)
        end
        z.e[key] = Pack(count, max(100, min(COST_MAX, mean)), falls, swims, Today())
        if class and class ~= FallClass(count, falls) then Changed(mapID, "class") end
        return counted, key
    end
    if z.n >= MAX_ZONE then
        Prune(p, mapID)
        z = p.zones[mapID]
        if not z then
            z = { n = 0, e = {} }
            p.zones[mapID] = z
        end
    end
    if p.total >= MAX_TOTAL then
        Prune(p)
        z = p.zones[mapID]
        if not z then
            z = { n = 0, e = {} }
            p.zones[mapID] = z
        end
    end
    z.e[key] = Pack(1, hundredths, fell and 1 or 0, swam and 1 or 0, Today())
    z.n = z.n + 1
    p.total = p.total + 1
    Changed(mapID, "new")
    return true, key
end

-- (0.2.3) a fall known only now: one more for a piece that counted its
-- crossing a moment ago without it (gone meanwhile: nothing)
local function AddFall(p, mapID, key)
    local z = p.zones[mapID]
    local v = z and z.e[key]
    if not v then return end
    local count, cost, falls, swims, day = Unpack(v)
    if falls < count then
        z.e[key] = Pack(count, cost, falls + 1, swims, day)
        if listener and FallClass(count, falls) ~= FallClass(count, falls + 1) then Changed(mapID, "class") end
    end
end

---------------------------------------------------------------------------
-- Looking: twice a second, a fixed handful of calls each time (W5)
---------------------------------------------------------------------------
local here = {} -- the square you are in: map, tx, ty, way (yards made in it), air, fell, swam, at
-- (0.2.3) and the way down: aloft (the look before was in the air too), air0 (the time before the first
-- look up there), the crossings made up there that wait for the fall to be known (map and key, the first pendN)
here.pendMap, here.pendKey, here.pendN = {}, {}, 0

---------------------------------------------------------------------------
-- (0.2.4 a15) The landing seen early (F1) and a jump pressed (J). Order 2026-11-26_claude_auftrag_0.2.4-sturz-fix,
-- Fassung 3; the diagnosis 2026-11-26_claude-code_diagnose-kamera-sturz (Sven, 26.11.2026: standing, the right mouse
-- button held, jumping again and again - between two looks the ground was touched for a moment, the looks saw one
-- long time up there and called it a fall).
--   F1: a look that sees you in the air starts one watcher, an OnUpdate that asks IsFalling() at every frame. The
-- first frame on the ground is the landing: the time up there ends there, once, and the watcher goes.
--   In Sven's words (the exception to W5, never more than two looks a second):
-- W5-Ausnahme (Sven, 26.11.): nur während der Luftzeit, nur `IsFalling()`, bis zur ersten Bodenberührung oder zum Abbruch.
--   Whether it was a fall is decided at the looks only, as before: the time up there is the sum of the intervals of
-- the valid looks, a fall from FALL_SECONDS on, and the crossings that waited for it get it then. The watcher can only
-- end a time up there earlier - never book a fall. Landed before the fall is known: the crossings that waited are let go.
--   J: a passive post-hook on JumpOrAscendStart keeps the time of the press - nothing else, installed once a UI session
-- (at the first start of the recording). Only the looks read it. A press in the time up there before the fall is known
-- starts that time anew, at the press: the crossings that waited for the time before are let go (the rides stay
-- booked, only their fall can no longer come). A press after the fall is known changes nothing - the square keeps the
-- fall it earned, and no crossing gets a second one from a key. A press from before the time up there (standing, or
-- the jump that took you up) never counts; a landing and an abort let it go. No hook (no JumpOrAscendStart, no
-- hooksecurefunc): F1 alone, the diagnosis says so.
--   Bewusster Sollwert (the price of J): whoever presses jump during a real fall, before it is a second long, can lose
-- its mark (Codex' probe: a fall from 0.10 to 1.60 s, a press at 0.90 s - 0 of 10). A press in the middle of a fall and
-- a new jump after a landing no frame saw look the same.
---------------------------------------------------------------------------
local watcher = CreateFrame("Frame")
local watching = false
local jumpAt              -- the time of the last jump pressed (nil: none that counts)
local jumpTried, jumpHooked = false, false
local counts = { looks = 0, frames = 0, hooks = 0 } -- (the looks, the watcher's frames, the hook's calls: for the tests)

local function Unwatch()
    if watching then
        watching = false
        watcher:SetScript("OnUpdate", nil)
    end
end

-- the diagnosis line of a time up there (/gcr paths diag on): at its end - its looks, the time seen, the time before
-- the first look, the last interval of the looks, a fall or not; the frames the watcher saw up there, the touches of the
-- ground it saw, the jumps pressed, the yards sideways between the first look up there and the last, the hook; and why
-- it was stopped, where it ended without a landing
local function Diag(stopped)
    if not (here.diag and here.aloft) then return end
    local dx, dy = (here.ex or 0) - (here.sx or 0), (here.ey or 0) - (here.sy or 0)
    print((L["Gathercraft paths diag: in the air %d looks, %.2f s seen from the second look (%.2f s before the first), a look every %.2f s - %s; %d frames up there, %d touches of the ground seen, %d jumps pressed, %.1f yd sideways, jump hook %s"]):format(
        here.looks or 0, here.air, here.air0, here.lastDt or 0, here.air >= FALL_SECONDS and L["a fall"] or L["no fall"], here.frames or 0,
        here.touches or 0, counts.hooks - (here.hooks0 or counts.hooks), math.sqrt(dx * dx + dy * dy), jumpHooked and L["yes"] or L["no"])
        .. (stopped and (L[" - stopped without a landing: %s"]):format(stopped) or ""))
end

-- (M3) The one abort, safe to call any time: the watcher goes, the press, the time up there and the crossings that
-- waited are let go. It makes no landing up and books nothing.
local function Abort(why)
    if here.aloft then Diag(why) end
    Unwatch()
    jumpAt = nil
    here.aloft, here.air, here.air0, here.pendN = false, 0, 0, 0
end

-- the landing, seen by the watcher or by a look: the time up there ends, once
local function Land()
    Diag()
    Unwatch()
    jumpAt = nil
    here.aloft, here.air, here.pendN = false, 0, 0
end

-- the watcher's frame: IsFalling() and nothing else (W5-Ausnahme, see above); a value that cannot be read ends it
local function Watch()
    counts.frames = counts.frames + 1
    local falling = IsFalling and IsFalling()
    if ns.AnySecret("paths falling", falling) or type(falling) ~= "boolean" then return Abort(L["the fall value cannot be read"]) end
    if falling then
        here.frames = (here.frames or 0) + 1
        return
    end
    here.touches = (here.touches or 0) + 1
    Land()
end
Watch = Wrap("Paths", Watch) -- (/gcr perf on: under Paths)

local function OnJump()
    counts.hooks = counts.hooks + 1
    jumpAt = GetTime()
end
OnJump = Wrap("Paths", OnJump)

-- once a UI session, at the first start of the recording
local function HookJump()
    if jumpTried then return end
    jumpTried = true
    if type(hooksecurefunc) == "function" and type(JumpOrAscendStart) == "function" then
        hooksecurefunc("JumpOrAscendStart", OnJump)
        jumpHooked = true
    end
end

local function Forget(why)
    here.map = nil
    Abort(why)
end

local function ZoneSize(mapID)
    if not (HBD and HBD.GetZoneSize) then return end
    local w, h = HBD:GetZoneSize(mapID)
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then return w, h end
end

-- Not on your own feet or not in the open world: nothing is learned (W3)
local function Elsewhere()
    if IsInInstance and IsInInstance() then return true end
    if UnitOnTaxi and UnitOnTaxi("player") then return true end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return true end
    if UnitInVehicle and UnitInVehicle("player") then return true end
    if IsFlying and IsFlying() then return true end
    return false
end

-- (0.2.4 a10, Sven 26.11.2026) A continent's map (mapType 2) is no place to learn: the game gives it as your map
-- where it knows no zone (a mountain ridge beyond a zone's edge, the sea). Its pieces never join a zone's net, and a
-- continent is wider than a row of squares. The type of a map does not change: asked once per map - (0.2.4 a13,
-- Codex' check of a10, M2) once it is read. No information or no type yet (or one that cannot be read): nil - the look
-- is left out, and the type is asked again at the next one.
local MAP_CONTINENT = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
local continent = {}
local function Continent(mapID)
    local c = continent[mapID]
    if c == nil then
        if not (C_Map and C_Map.GetMapInfo) then return false end -- (a client without it: no continent, as before a10)
        local info = C_Map.GetMapInfo(mapID)
        local t = info and info.mapType
        if t == nil or ns.AnySecret("paths map type", t) or type(t) ~= "number" or t < 0 or t ~= floor(t) then return nil end
        c = t == MAP_CONTINENT
        continent[mapID] = c
    end
    return c
end

local function Look()
    local p = DB()
    if not p or p.off then return end
    local now = GetTime()
    local last = here.at
    local dt = last and (now - last) or 0
    here.at = now
    if not last then here.map = nil end -- (the first look: a start, nothing to measure yet)
    if last and (dt <= 0 or dt > GAP_MAX) then return Forget(L["a gap between two looks"]) end
    if Elsewhere() then return Forget(L["a taxi, flying, dead, a vehicle or an instance"]) end
    local speed = GetUnitSpeed and GetUnitSpeed("player")
    local falling = IsFalling and IsFalling()
    local swimming = IsSwimming and IsSwimming()
    if ns.AnySecret("paths", speed, falling, swimming) or type(speed) ~= "number" then return Forget(L["values the game hides"]) end
    local mapID, x, y = ns.GetPlayerPos()
    if not mapID or not x or not y then return Forget(L["no position"]) end
    if Continent(mapID) ~= false then return Forget(L["a continent's map"]) end
    local w, h = ZoneSize(mapID)
    if not w then return Forget(L["no size of the zone"]) end
    local tx, ty = floor(x * w / TILE), floor(y * h / TILE)
    if tx < 0 or ty < 0 or tx >= GRID or ty >= GRID then return Forget(L["no size of the zone"]) end
    counts.looks = counts.looks + 1

    if here.map ~= mapID then
        -- a new start (login, another zone, after anything that was skipped)
        Abort(L["another zone"])
        here.map, here.tx, here.ty, here.way, here.air, here.fell, here.swam = mapID, tx, ty, 0, 0, false, false
        return
    end
    if speed > 0 then here.way = here.way + speed * dt end
    local px, py = x * w, y * h
    if falling == true then
        if here.aloft then
            if jumpAt and jumpAt > here.airAt and jumpAt <= now and not here.confirmed then
                -- (J) a jump pressed in the time up there before the fall is known: it starts anew at the press; the
                -- crossings that waited for the time before are let go (the rides stay booked) - see the price above
                here.air, here.air0, here.airAt, here.pendN = now - jumpAt, 0, jumpAt, 0
            else
                here.air = here.air + dt
            end
            here.looks = here.looks + 1
        else
            -- the first look in the air: how long you have been up there is not known - from here on
            here.aloft, here.air, here.air0, here.looks = true, 0, dt, 1
            here.airAt, here.confirmed, here.frames, here.touches = now, false, 0, 0
            here.sx, here.sy = px, py
            -- (the jumps pressed up there: the hook's calls from the look before on - the jump that took you up too)
            here.hooks0 = counts.hooks - ((jumpAt and jumpAt > now - dt) and 1 or 0)
            -- (a press before this look - standing, or the jump that took you up - never counts)
            jumpAt = nil
            -- (F1) one watcher for the frames up there
            if not watching then
                watching = true
                watcher:SetScript("OnUpdate", Watch)
            end
        end
        here.ex, here.ey, here.lastDt = px, py, dt
        if here.air >= FALL_SECONDS then
            here.fell, here.confirmed = true, true
            jumpAt = nil -- (a press after it changes nothing)
            -- the crossings of this way down that waited: theirs too
            for i = 1, here.pendN do AddFall(p, here.pendMap[i], here.pendKey[i]) end
            here.pendN = 0
        end
    else
        -- the landing seen by a look (the watcher saw none before it): the time up there ends, once. (0.2.4 r1, jump
        -- diagnosis) /gcr paths diag on: its line, see Diag
        if here.aloft then
            here.lastDt = dt
            Land()
        end
        jumpAt = nil -- (a press on the ground never counts for a later time up there)
    end
    if swimming == true then here.swam = true end

    local dx, dy = tx - here.tx, ty - here.ty
    if dx == 0 and dy == 0 then return end
    if dx >= -1 and dx <= 1 and dy >= -1 and dy <= 1 then
        local line = TILE * ((dx ~= 0 and dy ~= 0) and SQRT2 or 1)
        -- Carried across (a boat, a lift, a knock-back) is no way of yours
        -- (R1 W-M1). The rule for standing and being carried:
        --   - seen in the next square with no speed of your own: no piece,
        --     however far you went in the square before. (Stopping within
        --     the half second after the edge looks the same and is not kept
        --     either; the next ride over it is.)
        --   - standing still changes nothing: the way made so far stays;
        --   - the square you arrive in starts from nothing either way.
        -- (0.2.3 S0, Sven 22.11.2026) Any way of your own will do: a square
        -- cut at its corner is a piece too (its cost is then 1.00). Before,
        -- half the straight line had to be made in the square - the gaps in
        -- the net came mostly from that.
        if speed > 0 then
            local counted, key = Record(p, mapID, here.tx, here.ty, dx, dy, here.way / line, here.fell, here.swam)
            -- (0.2.3) crossed in the air before a fall is known, where the old count (from the look before the
            -- first one up there) had a second already: it waits - the fall is its, if it comes
            if counted and here.aloft and not here.fell and here.air + here.air0 >= FALL_SECONDS then
                here.pendN = here.pendN + 1
                here.pendMap[here.pendN], here.pendKey[here.pendN] = mapID, key
            end
        end
    end
    -- (further than a neighbour in one look: a teleport or a hitch - no piece, a new start here)
    here.tx, here.ty, here.way, here.fell, here.swam = tx, ty, 0, here.air >= FALL_SECONDS, false
end

---------------------------------------------------------------------------
-- On and off, the note, /gcr paths
---------------------------------------------------------------------------
local ticker

local function Enabled()
    local p = DB()
    return p ~= nil and not p.off
end

local function StartStop()
    if Enabled() then
        HookJump()
        if not ticker then
            Forget()
            here.at = nil -- (the time it was off is no hitch)
            ticker = C_Timer.NewTicker(TICK, Look)
        end
    elseif ticker then
        ticker:Cancel()
        ticker = nil
        Forget(L["recording off"])
    end
end

local function SetEnabled(on)
    local p = DB()
    if not p then return end
    p.off = (not on) or nil
    StartStop()
end

local function Count()
    local p = DB()
    local zones = 0
    if p then for _ in pairs(p.zones) do zones = zones + 1 end end
    return p and p.total or 0, zones
end

local function Status()
    local p = DB()
    if not p then return end
    local total, zones = Count()
    ns.Print((L["Paths: recording is %s. %d path pieces in %d zones (at most %d), about %d KB in the saved data. Only on this computer."]):format(
        p.off and L["|cffff0000OFF|r"] or L["|cff00ff00ON|r"], total, zones, MAX_TOTAL, floor(total * BYTES_PER_PIECE / 1024 + 0.5)))
    local list = {}
    for mapID, z in pairs(p.zones) do list[#list + 1] = { mapID = mapID, n = z.n } end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.mapID < b.mapID end)
    for i = 1, min(10, #list) do
        print(("  %s: %d"):format(ns.GetZoneName and ns.GetZoneName(list[i].mapID) or tostring(list[i].mapID), list[i].n))
    end
    if #list > 10 then print((L["  ... and %d more zones"]):format(#list - 10)) end
    print("  /gcr paths | /gcr paths on | /gcr paths off | /gcr paths clear")
end

local function Command(rest)
    local cmd, arg = (rest or ""):lower():match("^(%S*)%s*(.-)%s*$")
    local p = DB()
    if not p then return end
    if cmd == "on" or cmd == "off" then
        SetEnabled(cmd == "on")
        Status()
    elseif cmd == "diag" then
        -- (0.2.4 r1) the jump diagnosis: a line in chat for every time in the air (see Look); this session only
        if arg == "on" or arg == "off" then here.diag = arg == "on" or nil end
        print("Gathercraft paths diag: " .. (here.diag and "on - a line for every time in the air" or "off") .. " (this session only). /gcr paths diag on | off")
    elseif cmd == "clear" then
        local total = p.total
        if arg == "yes" then
            p.zones, p.total = {}, 0
            Forget(L["paths cleared"])
            Changed(nil, "gone")
            ns.Print((L["Recorded paths deleted (%d path pieces). Your nodes and everything else are untouched."]):format(total))
        elseif total == 0 then
            ns.Print(L["No paths recorded yet."])
        else
            ns.Print((L["This deletes the %d recorded path pieces and nothing else. To do it: /gcr paths clear yes"]):format(total))
        end
    else
        Status()
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LEAVING_WORLD")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        local p = DB()
        if not p then return end
        StartStop()
        if not p.hinted then
            p.hinted = true
            -- once, some seconds after the first login with this version (the chat is quiet by then)
            C_Timer.After(12, function()
                local now = DB()
                if now and not now.off then
                    ns.Print((L["New: Gathercraft notes which ways you ride, as small pieces per map square - only on this computer, nothing is sent. Later routes can go around obstacles with it. Switch: Options, %s. What it holds: /gcr paths"]):format(L["Sharing"]))
                end
            end)
        end
    else
        -- a loading screen: whatever square you were in, the next look starts anew
        Forget(L["a loading screen"])
    end
end)

ns.PathsLook = Look
-- (0.2.4 a15, the tests) the watcher's frame; the looks, the watcher's frames and the hook's calls so far; whether
-- the watcher runs and the hook is in
ns.PathsWatch = function() return watcher, counts.looks, counts.frames, counts.hooks, watching, jumpHooked end
ns.PathsEnabled = Enabled
ns.PathsSetEnabled = SetEnabled
ns.PathsCount = Count
ns.PathsCommand = Command
ns.PathsLimits = function() return MAX_TOTAL, MAX_ZONE, TILE, BYTES_PER_PIECE end
-- What is known about the crossing from square (tx, ty) into its neighbour
-- (dx, dy): count, cost (1 = straight), falls, swims, days since 2026-01-01
ns.PathsPiece = function(mapID, tx, ty, dx, dy)
    local p = DB()
    local z = p and p.zones[mapID]
    local v = z and z.e[(ty * GRID + tx) * 9 + Dir(dx, dy)]
    if not v then return end
    local count, cost, falls, swims, day = Unpack(v)
    return count, cost / 100, falls, swims, day
end
-- (0.2.4 S1) for Ways.lua: who is told what changed (one listener, nil: nobody); the fall class;
-- a zone's pieces as they are saved ({ [key] = value } and how many - to be read, never written);
-- a zone's size in yards as the squares are cut from it
ns.PathsListen = function(fn) listener = fn end
ns.PathsChanged = Changed
ns.PathsFallClass = FallClass
ns.PathsZone = function(mapID)
    local p = DB()
    local z = p and p.zones[mapID]
    if z then return z.e, z.n end
end
ns.PathsZoneSize = ZoneSize
-- The square of a place in a zone (map coordinates 0-1), nil where the zone has no size
ns.PathsSquare = function(mapID, x, y)
    local w, h = ZoneSize(mapID)
    if not w then return end
    return floor(x * w / TILE), floor(y * h / TILE)
end
-- (/gcr perf on: the event script above, measured while it is on)
frame:SetScript("OnEvent", Wrap("Paths", frame:GetScript("OnEvent")))
