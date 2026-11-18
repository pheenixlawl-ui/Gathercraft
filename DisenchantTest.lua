local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- /gcr detest - the disenchant diagnosis (0.3, disenchanting step 1;
-- concept "Entzauberungswerte" version 3, 4.1 and 4.2, gate G1). Before a
-- disenchant result is ever counted, a live test has to show how the item
-- you cast on can be bound to the loot it gives. This prints what the
-- client tells about it; a person reads it.
--   * /gcr detest turns it on for this session, /gcr detest off turns it
--     off. On or off is kept in a local only, never in the saved data:
--     after /reload it is off.
--   * it only listens and prints: no cast, no item picked, no loot taken,
--     no dialog, no CVar. Nothing is saved.
--   * on turning it on, once: which functions the client has (yes/no), the
--     build and the interface (an error in it is said; the events are
--     registered all the same)
--   * its events are registered only while it is on, each in a pcall; one
--     the client does not have is named, not an error
--   * then each of your casts (SENT, START, SUCCEEDED, FAILED, FAILED_QUIET,
--     INTERRUPTED, STOP) with GetTime and all its values; a bag slot whose
--     lock changes with its link, item ID, item GUID and lock; at
--     BAG_UPDATE_DELAYED the items gone from those slots; each loot window
--     (READY, OPENED, SLOT_CLEARED, CLOSED) with every slot's link, all
--     values of GetLootSlotInfo and GetLootSourceInfo and IsFishingLoot -
--     and whether a source is the GUID of a "locked item" (one whose lock
--     changed) or of one gone from its slot
--   * every value goes through ns.AnySecret first: a hidden one is printed
--     as <secret>, never compared, formatted or taken apart
--   * at most 40 lines a loot window, then "... N more"; outside one at most
--     20 lines in 2 s and 10 of a disenchant's casts besides them, then
--     "... N lines skipped" (Codex detest round 1, M2)
--   * English only, like /gcr test (a tool for the live test); not in the
--     help list
---------------------------------------------------------------------------
local WHERE = "disenchant test"
local DISENCHANT = 13262 -- the spell as the concept assumes it (the live test tells)
local MAX_LINES = 40     -- lines a loot window
local BURST_TIME = 2     -- outside a loot window: in this many seconds ...
local BURST_LINES = 20   -- ... at most this many lines ...
local BURST_OWN = 10     -- ... and this many of a disenchant's casts besides them
local KEEP = 8           -- locked items, and items gone from their slots, kept to compare with

local EVENTS = { "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
    "UNIT_SPELLCAST_FAILED_QUIET", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_STOP", "ITEM_LOCK_CHANGED",
    "BAG_UPDATE_DELAYED", "LOOT_READY", "LOOT_OPENED", "LOOT_SLOT_CLEARED", "LOOT_CLOSED" }
-- the functions of the API part (concept 4.2, and the ones the event part reads with)
local APIS = { "GetLootSourceInfo", "IsFishingLoot", "GetNumLootItems", "GetLootSlotInfo", "GetLootSlotLink",
    "C_Item.GetItemGUID", "ItemLocation", "ItemLocation:CreateFromBagAndSlot", "ItemLocation:CreateFromEquipmentSlot",
    "C_Item.DoesItemExist", "C_Item.IsLocked", "C_Container.GetContainerItemInfo", "C_Container.GetContainerItemLink",
    "C_Container.GetContainerItemID", "C_Item.GetItemInfoInstant", "GetItemInfo", "issecretvalue",
    "C_FriendList.GetNumFriends", "C_FriendList.GetFriendInfoByIndex" }

local on = false        -- this session only
local registered = {}   -- event -> true while it is registered
local seen, gone = {}, {} -- the locked items (newest last), the ones gone from their slots
local window            -- while a loot window is open: { lines = n, more = n }
local watch = CreateFrame("Frame", "GathercraftDisenchantTest")

local burst             -- outside a loot window, for BURST_TIME seconds: { at, lines, own, skipped, id }
local bursts = 0

-- a line as it is: the API part and the answers to the command
local function Line(text) print("detest " .. text) end
-- the end of BURST_TIME seconds (or a loot window begins, or off): how many lines were left out
local function Flush()
    if burst and burst.skipped > 0 then Line(("... %d lines skipped"):format(burst.skipped)) end
    burst = nil
end
local function Clock()
    local t = GetTime()
    if ns.AnySecret(WHERE, t) or type(t) ~= "number" then return nil end
    return t
end
-- an event's line. In a loot window at most MAX_LINES. Outside one at most
-- BURST_LINES in BURST_TIME seconds, and BURST_OWN lines of a disenchant's
-- casts (own) besides them - they are never pushed out by a flood of lock
-- changes or bag updates; the rest is counted and said once.
local function Out(text, own)
    if window then
        window.lines = window.lines + 1
        if window.lines > MAX_LINES then
            window.more = window.more + 1
            return
        end
        return Line(text)
    end
    local t = Clock()
    if burst and t and t - burst.at >= BURST_TIME then Flush() end
    if not burst then
        bursts = bursts + 1
        burst = { at = t or 0, lines = 0, own = 0, skipped = 0, id = bursts }
    end
    local b = burst
    if own then b.own = b.own + 1 else b.lines = b.lines + 1 end
    if own and b.own <= BURST_OWN or not own and b.lines <= BURST_LINES then return Line(text) end
    b.skipped = b.skipped + 1
    if b.skipped == 1 then
        -- said when the seconds are over, also when nothing else comes
        local id = b.id
        if C_Timer and type(C_Timer.After) == "function" then
            pcall(C_Timer.After, math.max(BURST_TIME - ((t or b.at) - b.at), 0.01), function()
                if burst and burst.id == id then Flush() end
            end)
        end
    end
end
local function EndWindow()
    if window and window.more > 0 then Line(("... %d more"):format(window.more)) end
    window = nil
end

-- a value as text; a hidden one as <secret>
local function Show(v)
    if ns.AnySecret(WHERE, v) then return "<secret>" end
    if v == "" then return '""' end
    return tostring(v)
end
local function Pack(...) return { n = select("#", ...), ... } end
-- the values of t from index from on, each shown: "(3) a, b, c"
local function All(t, from)
    local out = {}
    for i = from or 1, t.n do out[#out + 1] = Show(t[i]) end
    return "(" .. #out .. ")" .. (#out > 0 and (" " .. table.concat(out, ", ")) or "")
end
-- fn(...) in a pcall: { n, ok, values ... }; nil when the client has no such function
local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    return Pack(pcall(fn, ...))
end
-- all values of a call, shown
local function Values(r)
    if not r then return "no API" end
    if not r[1] then return "error " .. Show(r[2]) end
    return All(r, 2)
end
-- the first value of a call: shown, and as it is when it can be read
local function First(r)
    if not r then return "no API" end
    if not r[1] then return "error " .. Show(r[2]) end
    return Show(r[2]), ns.Readable(r[2], WHERE)
end
-- what a GetContainerItemInfo call (r) handed out: the text, and its kind ("table", "secret",
-- "unreadable", "nil", "values"). The table itself is checked first where the client can tell
-- hidden values (issecretvalue) - a hidden one is not opened. ns.AnySecret is not asked first:
-- without issecretvalue its stand-in test takes every table for hidden. Its field is read in a
-- pcall, so a table that cannot be read ends as "unreadable", not as a Lua error.
local function Info(r)
    if not r then return "no API", "values" end
    if not r[1] then return "error " .. Show(r[2]), "values" end
    local v = r[2]
    if type(issecretvalue) == "function" then
        local ok, hidden = pcall(issecretvalue, v)
        if not ok then return "unreadable", "unreadable" end
        if hidden then return "<secret>", "secret" end
    end
    if type(v) == "table" then
        local ok, locked = pcall(function() return v.isLocked end)
        if not ok then return "unreadable", "unreadable" end
        return Show(locked), "table"
    end
    if ns.AnySecret(WHERE, v) then return "<secret>", "secret" end
    if v == nil then return "nil", "nil" end
    return Values(r), "values"
end

---------------------------------------------------------------------------
-- The API part
---------------------------------------------------------------------------
local function Lookup(path) -- "C_Item.GetItemGUID", "ItemLocation:CreateFromBagAndSlot"
    local v = _G
    for part in path:gmatch("[^%.:]+") do
        if type(v) ~= "table" then return nil end
        v = v[part]
    end
    return v
end

-- what C_Container.GetContainerItemInfo hands out: a table with isLocked, or
-- values (the first item in your bags is looked at)
local function InfoShape()
    local C = C_Container
    local info, slots = C and C.GetContainerItemInfo, C and C.GetContainerNumSlots
    if type(info) ~= "function" or type(slots) ~= "function" then return "no API" end
    for bag = 0, 4 do
        local _, n = First(Call(slots, bag))
        for slot = 1, type(n) == "number" and n or 0 do
            local text, kind = Info(Call(info, bag, slot))
            local where = (" (bag %d slot %d)"):format(bag, slot)
            if kind == "table" then return "a table, isLocked " .. text .. where end
            if kind == "unreadable" then return "a table that cannot be read" .. where end
            if kind == "secret" then return "<secret>" .. where end
            if kind ~= "nil" then return (text:find("^error ") and "" or "values ") .. text .. where end
        end
    end
    return "no item in your bags to look at"
end

local function ApiPart()
    Line("GetBuildInfo: " .. Values(Call(GetBuildInfo)))
    for _, name in ipairs(APIS) do
        Line("API " .. name .. ": " .. (Lookup(name) ~= nil and "yes" or "no"))
    end
    Line("GetContainerItemInfo: " .. InfoShape())
    local name = First(Call(C_Spell and C_Spell.GetSpellName or GetSpellInfo, DISENCHANT))
    Line(("spell %d: name %s, IsPlayerSpell %s"):format(DISENCHANT, name, (First(Call(IsPlayerSpell, DISENCHANT)))))
end

---------------------------------------------------------------------------
-- The event part
---------------------------------------------------------------------------
local function Now()
    local t = GetTime()
    if ns.AnySecret(WHERE, t) or type(t) ~= "number" then return "<secret>" end
    return ("%.2f"):format(t)
end
local function Say(event, text, own) Out(Now() .. " " .. event .. " " .. text, own) end

local function SpellName(id)
    if ns.AnySecret(WHERE, id) or type(id) ~= "number" then return nil end
    return (First(Call(C_Spell and C_Spell.GetSpellName or GetSpellInfo, id)))
end
-- a cast of Disenchant: the spell 13262, or one with the client's name of it
-- (a hidden spell cannot be told: it counts with the rest)
local function IsDisenchant(id)
    if ns.AnySecret(WHERE, id) or type(id) ~= "number" then return false end
    if id == DISENCHANT then return true end
    local getName = C_Spell and C_Spell.GetSpellName or GetSpellInfo
    local _, name = First(Call(getName, id))
    local _, disenchant = First(Call(getName, DISENCHANT))
    return type(name) == "string" and name == disenchant
end

local function Where(bag, slot)
    if not ns.AnySecret(WHERE, slot) and slot == nil then return "equipment slot " .. Show(bag) end
    return "bag " .. Show(bag) .. " slot " .. Show(slot)
end

-- what a bag slot (with no slot: an equipment slot) holds now. Shown values,
-- and the item ID and GUID as they are when they can be read.
local function ReadSlot(bag, slot)
    local s, C = {}, C_Container or {}
    local equipment = not ns.AnySecret(WHERE, slot) and slot == nil
    local link, id, loc
    if equipment then
        link, id = Call(GetInventoryItemLink, "player", bag), Call(GetInventoryItemID, "player", bag)
        loc = Call(ItemLocation and ItemLocation.CreateFromEquipmentSlot, ItemLocation, bag)
    else
        link = Call(C.GetContainerItemLink or GetContainerItemLink, bag, slot)
        id = Call(C.GetContainerItemID or GetContainerItemID, bag, slot)
        loc = Call(ItemLocation and ItemLocation.CreateFromBagAndSlot, ItemLocation, bag, slot)
    end
    loc = loc and loc[1] and loc[2] or nil
    s.link = First(link)
    s.idText, s.id = First(id)
    s.empty = id ~= nil and id[1] == true and s.idText == "nil"
    local exists
    s.exists, exists = First(loc and Call(C_Item and C_Item.DoesItemExist, loc))
    if exists == false then
        s.guidText, s.lock = "-", "-" -- (no item there: nothing to ask)
    else
        s.guidText, s.guid = First(loc and Call(C_Item and C_Item.GetItemGUID, loc))
        s.lock = First(loc and Call(C_Item and C_Item.IsLocked, loc))
    end
    if type(s.guid) ~= "string" then s.guid = nil end
    if equipment then
        s.info = "-"
    else
        s.info = Info(Call(C.GetContainerItemInfo or GetContainerItemInfo, bag, slot))
    end
    return s
end

-- is the item kept as e still what the slot holds (s)? true or false, and
-- by what it was told; nil when it cannot be told
local function Same(e, s)
    if e.guid and s.guid then return e.guid == s.guid, "GUID" end
    if s.empty then return false end
    if e.id and s.id then return e.id == s.id, "item id" end
end

local function Keep(list, e)
    for i = #list, 1, -1 do if list[i].key == e.key then table.remove(list, i) end end
    list[#list + 1] = e
    if #list > KEEP then table.remove(list, 1) end
end

local function LockChanged(args)
    local bag, slot = args[1], args[2]
    local s, where = ReadSlot(bag, slot), Where(bag, slot)
    Say("ITEM_LOCK_CHANGED", ("%s | %s: link %s, id %s, guid %s, exists %s, locked %s, info.isLocked %s"):format(
        All(args), where, s.link, s.idText, s.guidText, s.exists, s.lock, s.info))
    -- kept to compare with later: a bag slot that can be read, with an item in
    -- it. An equipment slot (no slot) is shown only: equipment is not
    -- disenchanted, and the KEEP places stay for bag items.
    if s.id == nil or ns.AnySecret(WHERE, bag, slot) or slot == nil then return end
    Keep(seen, { key = where, bag = bag, slot = slot, where = where, link = s.link, id = s.id, guid = s.guid, guidText = s.guidText })
end

local function BagsDone(args)
    local text = {}
    for i = #seen, 1, -1 do
        local e = seen[i]
        if Same(e, ReadSlot(e.bag, e.slot)) == false then
            table.remove(seen, i)
            Keep(gone, e)
            table.insert(text, 1, ("gone from %s: %s, id %s, guid %s"):format(e.where, e.link, Show(e.id), e.guidText))
        end
    end
    Say("BAG_UPDATE_DELAYED", All(args) .. (#text > 0 and (" | " .. table.concat(text, "; ")) or ""))
end

-- a readable GUID against the locked items and the gone ones (only readable ones are kept)
local function Match(guid)
    for i = #seen, 1, -1 do if seen[i].guid == guid then return "locked item " .. seen[i].where .. " " .. seen[i].link end end
    for i = #gone, 1, -1 do if gone[i].guid == guid then return "gone item " .. gone[i].where .. " " .. gone[i].link end end
end

local function Loot(event, args)
    if not window then
        Flush() -- (what was left out before it, first)
        window = { lines = 0, more = 0 }
    end
    Say(event, All(args))
    local countText, count = First(Call(GetNumLootItems))
    Out(("  loot: %s slots, IsFishingLoot %s"):format(countText, (First(Call(IsFishingLoot)))))
    for _, e in ipairs(seen) do
        local same, by = Same(e, ReadSlot(e.bag, e.slot))
        Out(("  locked item %s %s %s: %s"):format(e.where, e.link, e.guidText, same == nil and "cannot tell if it is still in its slot"
            or same and ("still in its slot (same " .. by .. ")") or "no longer in its slot"))
    end
    if type(count) ~= "number" then return end
    local sources, different, matching = {}, 0, 0
    for slot = 1, count do
        local src = Call(GetLootSourceInfo, slot)
        Out(("  slot %d: link %s | GetLootSlotInfo %s | GetLootSourceInfo %s"):format(slot, (First(Call(GetLootSlotLink, slot))),
            Values(Call(GetLootSlotInfo, slot)), Values(src)))
        local hidden = 0
        for i = 2, src and src[1] and src.n or 0 do
            local v = src[i]
            if ns.AnySecret(WHERE, v) then
                hidden = hidden + 1
            elseif type(v) == "string" then -- a GUID (the amounts between them are numbers)
                local hit = Match(v)
                if not sources[v] then
                    sources[v] = true
                    different = different + 1
                    if hit then matching = matching + 1 end
                end
                if hit then Out(("  slot %d: source matches %s"):format(slot, hit)) end
            end
        end
        if hidden > 0 then Out(("  slot %d: %d hidden source values, not compared"):format(slot, hidden)) end
    end
    Out(("  sources: %d different, %d of them a locked or gone item"):format(different, matching))
end

watch:SetScript("OnEvent", function(_, event, ...)
    if not on then return end
    local args = Pack(...)
    if event == "ITEM_LOCK_CHANGED" then
        LockChanged(args)
    elseif event == "BAG_UPDATE_DELAYED" then
        BagsDone(args)
    elseif event == "LOOT_READY" or event == "LOOT_OPENED" then
        Loot(event, args)
    elseif event == "LOOT_CLOSED" then
        EndWindow()
        Say(event, All(args))
    elseif event == "LOOT_SLOT_CLEARED" then
        Say(event, All(args))
    else -- your casts
        local unit = args[1]
        if not ns.AnySecret(WHERE, unit) and unit ~= "player" then return end
        local spell = args[event == "UNIT_SPELLCAST_SENT" and 4 or 3]
        local name = SpellName(spell)
        Say(event, All(args) .. (name and (" - " .. name) or ""), IsDisenchant(spell))
    end
end)

---------------------------------------------------------------------------
-- On and off
---------------------------------------------------------------------------
local function Register()
    local n = 0
    for _, e in ipairs(EVENTS) do
        local ok
        if e ~= "UNIT_SPELLCAST_SENT" and e:find("^UNIT_SPELLCAST_") and watch.RegisterUnitEvent then
            ok = pcall(watch.RegisterUnitEvent, watch, e, "player")
        else
            -- (SENT as Core.lua registers it)
            ok = pcall(watch.RegisterEvent, watch, e)
        end
        if ok then
            registered[e] = true
            n = n + 1
        else
            Line("event not available: " .. e)
        end
    end
    Line(("listening to %d of %d events"):format(n, #EVENTS))
end

local function Unregister()
    for e in pairs(registered) do pcall(watch.UnregisterEvent, watch, e) end
    registered = {}
end

function ns.DisenchantTest(rest)
    rest = type(rest) == "string" and rest:lower() or ""
    if rest == "off" then
        if not on then Line("already off") return end
        EndWindow()
        Flush()
        Unregister()
        on, seen, gone = false, {}, {}
        Line("off")
    elseif rest == "" or rest == "on" then
        if on then Line("already on (/gcr detest off ends it)") return end
        on = true
        Line("on: what the client tells about a disenchant, printed only - nothing is done in the game, nothing is saved; /gcr detest off or /reload ends it")
        -- an error in the API part (a client table that throws when looked
        -- into) is said, and the events are registered all the same: never on
        -- without listening
        local ok, err = pcall(ApiPart)
        if not ok then Line("API part stopped by an error: " .. Show(err)) end
        Register()
    else
        Line("/gcr detest turns the disenchant diagnosis on, /gcr detest off turns it off")
    end
end
