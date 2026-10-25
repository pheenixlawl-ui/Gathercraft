local _, ns = ...

---------------------------------------------------------------------------
-- Interact targeting (soft target): observation only
--   With "interact targeting" on (SoftTargetInteract 2 or 3) the game picks
--   the object in front of you that the interact key would use. A herb or
--   vein there is there right now: we note that it was seen and write a
--   debug line. Nothing else: no harvest, no skill point, no value, no
--   "empty" or "up", no sync, no pins, no route. A missing one proves
--   nothing (looked away, out of range, setting off), and one that is gone
--   again was not necessarily picked.
--   The game says which object (its GUID: object ID and spawn), not where
--   it is: it is somewhere within the interact range in front of you. So
--   your own position is never taken as the place of the object.
--   No setting is changed here. Without the event (other clients) or with
--   interact targeting off, nothing happens at all.
--
--   What is remembered, and for how long (all in memory, gone after a
--   reload or logout):
--     * one entry per object (GUID), at most MAX_SEEN; a new one beyond
--       that pushes out the one looked at longest ago
--     * times are time() seconds, the clock of the route checks; an entry
--       is forgotten KEEP seconds after it was last in the soft target
--     * a run started or stopped: everything is forgotten (sightings belong
--       to the run they were made in, or to the time without one)
--     * another continent or instance: its entries are forgotten; another
--       zone of the same continent keeps them (world positions)
--   Debug lines: one per object when it is first seen, again at most every
--   SAY_AGAIN seconds while it is looked at, and never more than SAY_MAX in
--   SAY_WINDOW seconds (the rest is counted and named with the next line).
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)

local EVENT = "PLAYER_SOFT_INTERACT_CHANGED"
local KEEP = 60          -- seconds after the last look: the sighting is forgotten
local MAX_SEEN = 20      -- objects remembered at most
local SAY_AGAIN = 30     -- seconds before the same object gets a debug line again
local SAY_WINDOW, SAY_MAX = 10, 5 -- at most this many debug lines in that many seconds
local NEAR_EXTRA = 10    -- yards beyond the interact range: records of the kind looked for
local KIND_CACHE_MAX = 64

local seen = {}          -- guid -> sighting
local count = 0
local seq = 0            -- order of the sightings (time() has whole seconds only)
local owner = false      -- the run the sightings belong to (nil: no run)
local current            -- GUID in the soft target right now (as far as we were told)
local stats = { events = 0, gained = 0, again = 0, lost = 0, switched = 0, other = 0, notObject = 0,
    lootSame = 0, lootOther = 0, lootUnseen = 0 }
local lastArgs = "-"
local said = { at = -1e9, n = 0, held = 0 }
local kinds, kindsN = {}, 0 -- object ID -> { type, name } or false (no herb or vein)
local registered

local function Debug(text)
    if not (ns.db and ns.db.debug) then return end
    local now = GetTime()
    if now - said.at >= SAY_WINDOW then said.at, said.n = now, 0 end
    if said.n >= SAY_MAX then
        said.held = said.held + 1
        return
    end
    said.n = said.n + 1
    if said.held > 0 then
        text = text .. (" (%d soft target line(s) held back before)"):format(said.held)
        said.held = 0
    end
    ns.Debug(text)
end

local function CVar(name)
    local ok, v = pcall(GetCVar, name)
    return ok and v or nil
end

-- A herb or vein: the shipped kinds, or one we recorded ourselves (a new
-- Forever object). Anything else (bobber, chest, mailbox) is left alone.
local function KindOf(oid, mapID)
    local k = kinds[oid]
    if k ~= nil then return k or nil end
    local data = GathercraftQuestieData
    local d = data and data.kinds and data.kinds["o" .. oid]
    if d and (d[1] == "h" or d[1] == "o") then
        local names = GathercraftNodeNames and GathercraftNodeNames[GetLocale()]
        k = { type = d[1] == "h" and "herb" or "ore", name = names and names[oid] or d[3] }
    elseif not d then
        for _, n in ipairs(mapID and ns.db.nodes[mapID] or {}) do
            if n.id == "o" .. oid and (n.type == "herb" or n.type == "ore") then
                k = { type = n.type, name = n.name }
                break
            end
        end
    end
    if kindsN >= KIND_CACHE_MAX then kinds, kindsN = {}, 0 end
    kinds[oid], kindsN = k or false, kindsN + 1
    return k
end

-- Forget what is too old, from another run, or from another continent
local function Prune()
    if owner ~= ns.run then
        wipe(seen)
        count, owner = 0, ns.run
    end
    local inst = HBD and select(3, HBD:GetPlayerWorldPosition())
    local now = time()
    for guid, s in pairs(seen) do
        if now - s.last > KEEP or (inst and s.inst ~= inst) then
            seen[guid], count = nil, count - 1
        end
    end
end

-- Records of this object and of its kind near where you looked (for the
-- debug line only; the object itself is somewhere within the range)
local function Nearby(s)
    local same, nearest, kin = 0, nil, 0
    if not (HBD and s.wx and s.mapID) then return same, nearest, kin end
    local key = ns.KindKey and ns.KindKey({ id = "o" .. s.oid, name = s.name, type = s.type })
    local reach = s.range + NEAR_EXTRA
    for _, n in ipairs(ns.db.nodes[s.mapID] or {}) do
        if n.type == s.type and n.x then
            local wx, wy, inst = HBD:GetWorldCoordinatesFromZone(n.x, n.y, s.mapID)
            local d = wx and inst == s.inst and math.sqrt((wx - s.wx) ^ 2 + (wy - s.wy) ^ 2)
            if d and d <= reach then
                if n.id == "o" .. s.oid then
                    same = same + 1
                    if not nearest or d < nearest then nearest = d end
                elseif key and ns.KindKey(n) == key then
                    kin = kin + 1
                end
            end
        end
    end
    return same, nearest, kin
end

local function Say(s, first)
    if not (ns.db and ns.db.debug) then return end
    if not first and time() - (s.saidAt or 0) < SAY_AGAIN then return end
    s.saidAt = time()
    local same, nearest, kin = Nearby(s)
    Debug(("SOFT %s [o%d] spawn %s %s (look %d, mode %s, range %s, arc %s): you at map %s %.1f/%.1f, the object is somewhere within ~%d yd; records of this object within %d yd: %d%s, other records of its kind: %d"):format(
        tostring(s.name), s.oid, tostring(s.spawn), first and "in interact targeting" or "still looked at", s.looks,
        tostring(CVar("SoftTargetInteract")), tostring(CVar("SoftTargetInteractRange")), tostring(CVar("SoftTargetInteractArc")),
        tostring(s.mapID), (s.x or 0) * 100, (s.y or 0) * 100, s.range, s.range + NEAR_EXTRA, same,
        nearest and (" (nearest %d yd from you)"):format(nearest) or "", kin))
end

local function OnChanged(...)
    stats.events = stats.events + 1
    if not ns.db then return end
    local a, b = ...
    lastArgs = ("%s, %s"):format(tostring(a), tostring(b)):sub(1, 120)
    local ok, guid = pcall(UnitGUID, "softinteract")
    guid = ok and guid or nil
    if guid == current then return end
    if current and seen[current] then seen[current].lost = seen[current].lost + 1 end
    if current then
        if guid then stats.switched = stats.switched + 1 else stats.lost = stats.lost + 1 end
    end
    current = guid
    if not guid then return end
    local unitType, _, _, _, _, id, spawn = strsplit("-", guid)
    if unitType ~= "GameObject" then
        stats.notObject = stats.notObject + 1
        return
    end
    local oid = tonumber(id)
    local mapID, x, y = ns.GetPlayerPos and ns.GetPlayerPos()
    local kind = oid and KindOf(oid, mapID)
    if not kind then
        stats.other = stats.other + 1
        return
    end
    Prune()
    local wx, wy, inst
    if HBD then wx, wy, inst = HBD:GetPlayerWorldPosition() end
    local range = math.max(10, tonumber(CVar("SoftTargetInteractRange")) or 10)
    local s = seen[guid]
    local first = not s
    if s then
        stats.again = stats.again + 1
    else
        if count >= MAX_SEEN then
            local oldest
            for g, o in pairs(seen) do
                local b = oldest and seen[oldest]
                if not b or o.last < b.last or (o.last == b.last and o.seq < b.seq) then oldest = g end
            end
            seen[oldest], count = nil, count - 1
        end
        s = { guid = guid, oid = oid, spawn = spawn, type = kind.type, name = kind.name, first = time(), looks = 0, lost = 0 }
        seen[guid], count = s, count + 1
        stats.gained = stats.gained + 1
    end
    seq = seq + 1
    s.last, s.seq, s.looks = time(), seq, s.looks + 1
    -- where you were at the latest look (not where the object is)
    s.wx, s.wy, s.inst, s.mapID, s.x, s.y, s.range = wx, wy, inst, mapID, x, y, range
    Say(s, first)
end

-- After a recorded gather: was it the object seen in interact targeting?
-- (the same spawn in the loot source = the same object). Only counted and
-- written to debug.
table.insert(ns.gatherListeners, function(node, p)
    if not (p and p.objectID) then return end
    Prune()
    local exact, others = nil, {}
    for _, s in pairs(seen) do
        if s.oid == p.objectID then
            if p.spawn and s.spawn == p.spawn then exact = s else others[#others + 1] = tostring(s.spawn) end
        end
    end
    if exact then
        stats.lootSame = stats.lootSame + 1
        exact.looted = (exact.looted or 0) + 1
        Debug(("SOFT loot of %s [o%d] spawn %s: the object seen in interact targeting (first %d s, last %d s ago)"):format(
            tostring(exact.name), exact.oid, tostring(p.spawn), time() - exact.first, time() - exact.last))
    elseif #others > 0 then
        stats.lootOther = stats.lootOther + 1
        Debug(("SOFT loot of [o%d] spawn %s: not one of the %d sighting(s) of this object (spawn %s)"):format(
            p.objectID, tostring(p.spawn), #others, table.concat(others, ", ")))
    else
        stats.lootUnseen = stats.lootUnseen + 1
    end
end)

local frame = CreateFrame("Frame")
registered = pcall(frame.RegisterEvent, frame, EVENT) and true or false
frame:SetScript("OnEvent", function(_, _, ...) OnChanged(...) end)

-- /gcr softtest: what the client offers and what was seen (changes nothing)
ns.SoftTargetTest = function()
    Prune()
    ns.Print("Interact targeting check (observation only, nothing is changed)")
    print(("  %s: %s, received %d time(s), last arguments: %s"):format(EVENT, registered and "registered" or "NOT available",
        stats.events, lastArgs))
    print(("  SoftTargetInteract %s (0 off, 1 gamepad, 2 keyboard/mouse, 3 both), Range %s, Arc %s, OnlyInRange %s, RangeIsHard %s"):format(
        tostring(CVar("SoftTargetInteract")), tostring(CVar("SoftTargetInteractRange")), tostring(CVar("SoftTargetInteractArc")),
        tostring(CVar("SoftTargetInteractOnlyInRange")), tostring(CVar("SoftTargetInteractRangeIsHard"))))
    local ok, guid = pcall(UnitGUID, "softinteract")
    print(("  In interact targeting now: %s"):format(ok and guid or "nothing"))
    print(("  Since login: %d herb/vein sightings, %d looked at again, %d lost, %d switched, %d other objects, %d not objects"):format(
        stats.gained, stats.again, stats.lost, stats.switched, stats.other, stats.notObject))
    print(("  Gathers: %d the seen object (same spawn), %d another spawn of a seen object, %d without a sighting"):format(
        stats.lootSame, stats.lootOther, stats.lootUnseen))
    print(("  Remembered: %d of at most %d (forgotten %d s after the last look, at run start/stop, on another continent)"):format(
        count, MAX_SEEN, KEEP))
    for _, s in pairs(seen) do
        print(("    %s [o%d] spawn %s: first %d s ago, last %d s ago, %d look(s), lost %d time(s), gathered %d time(s)"):format(
            tostring(s.name), s.oid, tostring(s.spawn), time() - s.first, time() - s.last, s.looks, s.lost, s.looted or 0))
    end
end

-- for the tests
ns.SoftTargetState = function() Prune() return seen, count, stats, registered end
