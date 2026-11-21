local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Sync: share harvested nodes with other Gathercraft users
--
--   Transport : invisible addon messages (never shown in chat)
--               * public channel "GathercraftSync" (everyone online, one channel)
--               * guild channel (trusted)
--   Push      : a harvest is sent live only while the network doesn't know
--               the node yet (we heard it from fewer than PUSH_KNOWN_LIMIT
--               other players). The fuller the map, the quieter the channel.
--   Pull      : entering a zone we ask "I know N nodes here, who has more?".
--               Only players who know more answer, at most 3.
--   Trust     : guild members and friends count right away, everyone else
--               needs CONFIRMATIONS different reporters.
--   Load      : max RECV_BUDGET incoming messages per second are processed,
--               and when the channel is busy everyone sends less.
--   Safety    : sender names come from the server, strict validation,
--               rate limit per sender, blocklist. Received data is never run.
--
--   Messages (prefix "Gathercraft"):
--     N:<mapID>;<id>,<h|o>,<x>,<y>,<item>;...   nodes (x/y = 0..10000)
--     Q:<mapID>:<count>                          "I know <count> nodes here, who has more?"
--     V:gc<version>                              "I run Gathercraft <version>" (0.2.2 d1, see SayVersion)
---------------------------------------------------------------------------
local PREFIX = "Gathercraft"
local CHANNEL = "GathercraftSync"
local CONFIRMATIONS = 3       -- different players needed for a public node
ns.SYNC_CONFIRMATIONS = CONFIRMATIONS -- Options > Sharing says it
local PUSH_KNOWN_LIMIT = 3    -- stop live-sending a node once this many others reported it
local MERGE_RADIUS = 10       -- yards: same kind closer than this = same node
-- Self-healing: a node that only came from other players, that you found
-- empty again and again over a long time and never harvested, was most likely
-- wrong (or a fake: several characters of one player can confirm anything).
-- It is parked, not deleted: out of routes, faded on the map, not shared.
-- Real spawn points are often empty (spawn pools, other players), so this is
-- slow on purpose. A parked node comes back when a player who didn't report
-- it before reports it, or when you harvest it.
local HEAL_MISSES = 5              -- empty visits (on the run target, not in combat) ...
local HEAL_SPACING = 600           -- ... at least this many seconds apart ...
local HEAL_SPAN = 12 * 3600        -- ... spread over at least this long
local HEAL_RESET = 3 * 24 * 3600   -- no empty visit for this long: start counting again
-- reporter names remembered per node: 4 since 0.2.2 (Sync 2.0 analysis,
-- 21.11.2026, d4; up to 0.2.1: 8). They are read only by the push brake
-- (from 3), self-healing (real from more than 3), unparking (a new name)
-- and the merge of two nodes (Core.lua) - none needs more than 4. Names
-- already saved stay as they are (no migration).
local HEARD_KEEP = 4
local SEND_INTERVAL = 1.2     -- seconds between outgoing messages
local MAX_MSG_LEN = 240
local RECV_BUDGET = 40        -- max incoming messages processed per second
local BUSY_RATE = 20          -- incoming messages per second above which we send less
local RATE_WINDOW = 60        -- seconds
local RATE_MAX_NODES = 150    -- max nodes accepted per sender per window
local QUERY_COOLDOWN = 600    -- seconds before asking for the same zone again
local QUERY_HEARD = 120       -- someone else asked for the zone this recently: their answers reach us too
local QUERY_JITTER = 15       -- seconds: wait a random moment before asking (others may ask first)
local MAX_RESPONDERS = 3
local ANSWER_WAIT_MIN, ANSWER_WAIT_MAX = 2, 15 -- seconds: the random wait before an answer starts
local ANSWER_HOLD = 4        -- seconds an answer waits that was not among the first: do the first go on? (see AnswerStops)
local ANSWER_MORE_SHARE = 0.2 -- a zone question is answered only with this much more than the asker knows ...
local ANSWER_MORE_NODES = 20  -- ... and at least this many nodes more (see WorthAnswering)
local ANSWER_MIN_NODES = 2    -- ... and never fewer than this many, in all and more than the asker knows
local PENDING_MAX_AGE = 7 * 24 * 3600
local PENDING_MAX_AGE_NEW = 14 * 24 * 3600 -- zones without known spawn points (new Forever zones): keep them longer
local PENDING_MAX_TOTAL = 2000 -- unconfirmed reports kept in all zones together
local PENDING_MAX_PER_ZONE = 300 -- unconfirmed reports kept per zone (oldest go first)
local PENDING_PER_REPORTER = 30  -- one stranger can't fill the list with fake reports
local PENDING_PER_REPORTER_TOTAL = 100 -- ... in all zones together
local ANSWER_COOLDOWN = 300   -- seconds: a zone is answered at most once in this time
local QUEUE_MAX = 60          -- outgoing messages waiting at most (about a minute of sending)
local QUEUE_ANSWER_MAX = 20   -- answers to zone queries only while fewer than this wait
local MAX_ITEM_ID = 2 ^ 31 - 1
local JOIN_DELAY = 8          -- seconds after login (let General/Trade join first)
local VERSION_MAX = 24        -- characters of a version a player may send (V:gc<version>)

local TYPE_CODE = { herb = "h", ore = "o", chest = "c" }
local CODE_TYPE = { h = "herb", o = "ore", c = "chest" }

local queue = {}              -- outgoing messages { text, target, answer }
local sendTicker                -- the ticker that sends the queue, one message every SEND_INTERVAL
local channelID
local rate = {}               -- sender -> { start, count }
local lastQuery = {}          -- mapID -> time (kept in the saved data: a /reload doesn't ask again)
local answering = {}          -- mapID -> our answer to a zone question, from the question to its last packet (see OnQuery)
local answeredAt = {}         -- mapID -> time we last answered a query for it
local heardQuery = {}         -- mapID -> time someone else asked for it in the channel
local recv = { start = 0, count = 0, processed = 0 }
local incomingRate = 0        -- smoothed messages per second
local stats = { received = 0, imported = 0, dropped = 0, skippedKnown = 0, skippedBusy = 0, peers = {} }
local stress                  -- running stress test (fake data, nothing stored)
local stays = {}              -- nodes with a healStay (self-healing, see SelfHeal), looked at while you move

local function DB()
    return ns.db.sync
end

local function Debug(text)
    ns.Debug("|cff66ccffsync|r " .. text)
end

---------------------------------------------------------------------------
-- /gcr perf (v0.1.22 S3): what sharing cost in the last full minute.
--   Sven, 12.11.2026: the channel is full, receivers refuse a lot, and
--   nothing in the game said how much of the addon's time and memory is
--   sharing. Counted per minute: messages received and send attempts,
--   nodes announced, what was refused (the budget per second, the limit per
--   player), messages of other addons that pass our handler, and the time
--   in the two handlers. The command only reads.
--   What the numbers are and are not (R1 S-N2; Codex, 13.11.2026):
--     - "send attempts": every try to send, also one the client refused -
--       not what arrived anywhere;
--     - "nodes announced": the entries the messages carried, counted before
--       any of them is checked - not what was taken;
--     - "time in the receive and send handlers": the handler for incoming
--       addon messages and the tick that sends one message. Not in it:
--       work in timers (picking and packing an answer to a zone question,
--       the chat line) and whatever else sharing sets off elsewhere.
---------------------------------------------------------------------------
local perf = {} -- cur = the running minute, last = the one before it (nil in the first minute after login)

local function PerfNow()
    local minute = math.floor(GetTime() / 60)
    local cur = perf.cur
    if not cur or cur.minute ~= minute then
        if cur then
            -- (minutes nothing happened in are full minutes of zeros)
            perf.last = cur.minute == minute - 1 and cur or { minute = minute - 1, msgIn = 0, msgOut = 0, other = 0, nodes = 0, overBudget = 0, overLimit = 0, ms = 0,
                throttled = 0, chanThrottled = 0, badChannel = 0 }
        end
        cur = { minute = minute, msgIn = 0, msgOut = 0, other = 0, nodes = 0, overBudget = 0, overLimit = 0, ms = 0,
            throttled = 0, chanThrottled = 0, badChannel = 0 }
        perf.cur = cur
    end
    return cur
end

local function PerfTime(t0)
    local cur = PerfNow()
    cur.ms = cur.ms + (debugprofilestop() - t0)
end

-- The addon's memory in KB, where the client tells it (asked for only here,
-- on the command: the game adds it up for all addons)
local function PerfMemory()
    if type(UpdateAddOnMemoryUsage) ~= "function" or type(GetAddOnMemoryUsage) ~= "function" then return end
    local ok, kb = pcall(function()
        UpdateAddOnMemoryUsage()
        return GetAddOnMemoryUsage(ADDON_NAME)
    end)
    if ok and type(kb) == "number" and not ns.AnySecret("perf", kb) then return kb end
end

local function Perf()
    PerfNow()
    local b, what = perf.last, "last full minute"
    if not b then
        b, what = perf.cur, ("running minute, %d s"):format(GetTime() % 60)
    end
    local kb = PerfMemory()
    -- (v0.1.23 P1: the minimap pins registered with HereBeDragons, of the ones your zone has)
    local near, inZone = 0, 0
    if ns.MiniPinCounts then near, inZone = ns.MiniPinCounts() end
    -- (own messages heard back: since login - does this realm send our own
    -- messages back to us? AnswerStops counts on it and has a rule without it)
    ns.Print(("perf (%s): sync messages received %d, send attempts %d; nodes announced %d (before any check); refused: %d messages over the budget, %d nodes over the limit per player; refused by the game when sending: %d throttled, %d channel throttled, %d channel not valid; other addons' messages %d; time in the receive and send handlers %.1f ms; own messages heard back %d of %d send attempts since login; %s; minimap pins: %d near / %d in zone"):format(
        what, b.msgIn, b.msgOut, b.nodes, b.overBudget, b.overLimit, b.throttled or 0, b.chanThrottled or 0, b.badChannel or 0, b.other, b.ms,
        perf.back or 0, perf.sent or 0, kb and ("memory %.1f MB"):format(kb / 1024) or "memory not readable in this client", near, inZone))
end

---------------------------------------------------------------------------
-- Names and trust
---------------------------------------------------------------------------
local playerName

local function ShortName(sender)
    return Ambiguate and Ambiguate(sender, "none") or sender
end

-- Forever names can have two parts ("Syndra Earthroot"): the sender of a
-- message then has the full name, UnitName("player") may only give the first
-- part. Such a name is learned from our own messages coming back: same text
-- moments after we sent it, from a name that starts with ours.
local selfNames, sentAt = {}, {}

local function IsSelf(sender)
    local short = ShortName(sender)
    return sender == playerName or short == ns.Readable(UnitName("player"), "sync") or selfNames[short] == true
end

local function LearnSelf(sender, text)
    local t = sentAt[text]
    if not t or time() - t > 10 then return false end
    local short, me = ShortName(sender), ns.Readable(UnitName("player"), "sync")
    if me and short:sub(1, #me + 1) == me .. " " then
        selfNames[short] = true
        return true
    end
    return false
end

local function IsFriend(sender)
    if C_FriendList and C_FriendList.GetFriendInfo then
        local ok, info = pcall(C_FriendList.GetFriendInfo, ShortName(sender))
        if ok and info then return true end
    end
    return false
end

local function IsTrusted(sender, distribution)
    if distribution == "GUILD" then return true end
    return IsFriend(sender)
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local function Enqueue(text, target, answer)
    -- never more than about a minute of sending waits: a flood of work can't
    -- block our own harvest messages for long
    if #queue >= QUEUE_MAX then
        stats.dropped = stats.dropped + 1
        return false
    end
    queue[#queue + 1] = { text = text, target = target, answer = answer }
    return true
end

-- Which Gathercraft the players run (0.2.2 d1; Sync 2.0 analysis of
-- 21.11.2026): one message "V:gc<version>" after joining the channel, and
-- one per login in the guild - nothing more. A kind of its own, never a
-- token on N: an old client counts every ";..." of an N message as a node,
-- and a push with two parts would look like an answer to it (AnswerHeard).
-- The "gc" is on purpose: old clients read "^(%u):(%d+)" and would take a
-- number right after "V:" for the zone of the player. A kind other than N
-- or Q they leave alone. The version heard is kept per player in memory
-- only, with the other things of the last hour (/gcr sync).
local versionSaid = {} -- "channel" / "guild" -> true once said (this join, this login)
local function OwnVersion()
    local v = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    if type(v) ~= "string" or ns.AnySecret("sync version", v) or #v > VERSION_MAX or not v:match("^[%w%.%-]+$") then return end
    return v
end
local function SayVersion(target)
    local v = OwnVersion()
    if v then Enqueue("V:gc" .. v, target) end
end
ns.SyncVersionSaid = versionSaid -- (the tests: a new login starts with nothing said)

-- Our answer to a zone question goes out packet by packet, and before every
-- packet it is asked again whether enough others answer (v0.1.22 S2; Sven's
-- debug logs of 11. and 12.11.2026: 6-7 players answered one question. The
-- lock used to count only answers that had arrived before the own wait was
-- over - several players started before any answer was heard).
--   Who goes on? The first MAX_RESPONDERS in the channel. The channel hands
-- everyone the messages in one order, so each player can tell his place: the
-- others' answers he heard before his own first packet came back to him.
-- After that nothing is counted any more (`closed`).
--   That alone is not safe (R1 S-M1; Codex, 13.11.2026): where the own
-- packet does not come back, or comes back later than the others' packets,
-- eight players who started together each counted three ahead of them and
-- all stopped - no answer. A first packet says nothing about whether its
-- sender goes on. So nobody stops for good because of first packets:
--   - Three were ahead when our packet came back: we give way and hold the
--     rest for ANSWER_HOLD seconds. Those who are truly first send their
--     second packet in that time (`went`: others past their first packet).
--     Three of them: we stop. Fewer: we go on after all.
--   - Our packet is not back when the second one is due: it goes out.
--   - Whoever goes on without a known place (`byName`) stops only when
--     three others who went past their first packet too come before him by
--     name (`before`). A late echo changes nothing any more.
-- Past the first packet one stops only for players who are past theirs, and
-- of those the one whose name comes first never stops: one answer always
-- arrives. With everybody's echo in order it is the first three and nobody
-- else sends a second packet; with nobody's it is the three first names,
-- and the others stop after their second packet; where it is mixed, one or
-- two more may go on - rather an answer more than none.
--   Returns true when this packet must not be sent (now).
local AnswerHoldOver

local function AnswerStopped(a, why)
    a.stopped, a.held = true, nil
    if answering[a.mapID] == a then answering[a.mapID] = nil end
    stats.answersStopped = (stats.answersStopped or 0) + 1
    Debug(("stopped answering zone %d after %d of %d packets: %s"):format(a.mapID, a.sent, a.packets, why))
end

local function AnswerStops(a, item)
    if a.stopped then return true end
    if a.byName then
        if a.before >= MAX_RESPONDERS then
            AnswerStopped(a, a.before .. " others who went on come first by name")
        end
    elseif a.sent == 0 then
        -- (not started yet: as many answers as are wanted are on their way)
        if a.ahead >= MAX_RESPONDERS then AnswerStopped(a, a.ahead .. " others were first") end
    elseif a.sent == 1 and a.closed and a.ahead >= MAX_RESPONDERS then
        -- our place is known and it is not among the first: give way, and see whether they go on
        a.holding, a.held = true, { item }
        for i = #queue, 1, -1 do
            if queue[i].answer == a then table.insert(a.held, 2, table.remove(queue, i)) end
        end
        Debug(("answer to zone %d: %d others were first - waiting %d s to see whether they go on"):format(a.mapID, a.ahead, ANSWER_HOLD))
        C_Timer.After(ANSWER_HOLD, function() AnswerHoldOver(a) end)
        return true
    end
    return a.stopped
end

AnswerHoldOver = function(a)
    if a.stopped or not a.holding then return end
    a.holding = nil
    if a.went >= MAX_RESPONDERS then
        AnswerStopped(a, a.went .. " others were first and went on")
        return
    end
    -- too few of them went on: this answer is wanted after all
    a.byName = true
    for i, item in ipairs(a.held or {}) do table.insert(queue, i, item) end
    a.held = nil
    Debug(("answer to zone %d: only %d of the %d who were first went on - going on, names decide"):format(a.mapID, a.went, a.ahead))
end

local function AnswerSent(a, text)
    a.sent = a.sent + 1
    if a.sent == 1 then
        a.first = text
    elseif not a.closed then
        a.closed, a.byName = true, true
        Debug(("answer to zone %d: our first packet is not back - going on, names decide"):format(a.mapID))
    end
    if a.sent >= a.packets and answering[a.mapID] == a then answering[a.mapID] = nil end
end

-- Our own first packet came back from the channel in time: our place is known
local function AnswerEcho(text)
    for _, a in pairs(answering) do
        if a.first == text and not a.closed then a.closed = true end
    end
end

-- Somebody's nodes for a zone we are answering ourselves: an answer of his
-- (two nodes or more in his first message - one node is a harvest), and
-- with a second message he went past his first packet
local function AnswerHeard(a, sender, nodes)
    local seen = a.responders[sender]
    if not seen then
        if nodes < ANSWER_MIN_NODES then return end
        a.responders[sender] = 1
        if not a.closed then a.ahead = a.ahead + 1 end
    elseif seen == 1 then
        a.responders[sender] = 2
        a.went = a.went + 1
        local me = ns.Readable(UnitName("player"), "sync")
        if me and ShortName(sender) < me then a.before = a.before + 1 end
    end
end

-- What the game said to a send (0.2.2 d1; Sync 2.0 analysis of 21.11.2026):
-- SendAddonMessage returns a result code (Enum.SendAddonMessageResult; an
-- older client true or false). Three of them are counted - throttled (the
-- limit per prefix), the channel throttled, the channel not valid - in the
-- minute (/gcr perf) and since login (/gcr sync). The message is dropped
-- as before, never retried.
local RESULT = (Enum and Enum.SendAddonMessageResult) or {}
local REFUSED = {
    [RESULT.AddonMessageThrottle or 3] = "throttled",
    [RESULT.ChannelThrottle or 8] = "chanThrottled",
    [RESULT.InvalidChannel or 7] = "badChannel",
}
local sendRefused = { throttled = 0, chanThrottled = 0, badChannel = 0 } -- since login
local function NoteResult(result)
    local what = type(result) == "number" and REFUSED[result]
    if not what then return end
    sendRefused[what] = sendRefused[what] + 1
    local cur = PerfNow()
    cur[what] = (cur[what] or 0) + 1
end

-- A client that refuses addon messages (e.g. a trial account) may throw
-- instead of saying no: the message is dropped either way, never retried
local function Send(...)
    local cur = PerfNow()
    cur.msgOut = cur.msgOut + 1
    perf.sent = (perf.sent or 0) + 1
    local fine, result = pcall(C_ChatInfo.SendAddonMessage, ...)
    if fine then
        if not ns.AnySecret("sync send", result) then NoteResult(result) end
        return result
    end
    return false, result
end

local function SendNext()
    local item
    repeat
        -- (the packets of a stopped answer cost no turn: what waits behind them goes out now)
        item = table.remove(queue, 1)
        if not item then return end
    until not (item.answer and AnswerStops(item.answer, item))
    local ok, err
    if item.target == "GUILD" then
        if IsInGuild() then
            ok, err = Send(PREFIX, item.text, "GUILD")
        end
    elseif channelID and channelID > 0 then
        ok, err = Send(PREFIX, item.text, "CHANNEL", channelID)
    end
    if item.target ~= "GUILD" then
        sentAt[item.text] = time()
        for text, t in pairs(sentAt) do
            if time() - t > 60 then sentAt[text] = nil end
        end
    end
    if item.answer then AnswerSent(item.answer, item.text) end
    Debug(("sent [%s] %s -> %s%s"):format(item.target, item.text:sub(1, 60), tostring(ok),
        err and (" (" .. tostring(err) .. ")") or ""))
end

local function Coord(v)
    return math.floor(v * 10000 + 0.5)
end

local function EncodeNode(n)
    return ("%s,%s,%d,%d,%d"):format(n.id, TYPE_CODE[n.type] or "x", Coord(n.x), Coord(n.y), n.item or 0)
end

-- Sends a list of nodes of one zone, packed into as few messages as possible.
-- `answer`: the packets belong to this answer to a zone question (see
-- AnswerStops). Returns how many messages wait in the queue for it.
local function SendNodes(mapID, nodes, targets, answer)
    local head = "N:" .. mapID
    local msg = head
    local queued = 0
    local function flush()
        if msg ~= head then
            for _, t in ipairs(targets) do
                if Enqueue(msg, t, answer) then queued = queued + 1 end
            end
        end
        msg = head
    end
    for _, n in ipairs(nodes) do
        local part = ";" .. EncodeNode(n)
        if #msg + #part > MAX_MSG_LEN then flush() end
        msg = msg .. part
    end
    flush()
    return queued
end

local function Targets()
    local t = {}
    if DB().public and channelID and channelID > 0 then t[#t + 1] = "CHANNEL" end
    if IsInGuild() then t[#t + 1] = "GUILD" end
    return t
end

local function Shareable(n, mapID)
    -- Only nodes we harvested ourselves (real game object), never re-share
    -- imports from other players or from the beta starter data, and never
    -- known spawn points: every Gathercraft user has those already
    -- (only seen on the minimap: rough position, not shared until harvested)
    -- and never a quest object an older version booked (0.2.1 A3)
    return n.id and n.id:match("^o%d+$") and n.type and not n.source and not n.seenOnly
        and not (ns.IsKnownSpawn and ns.IsKnownSpawn(mapID, n.id, n.x, n.y))
        and not (ns.IsQuestNode and ns.IsQuestNode(n.id, n.item))
end

local function Busy()
    -- When the channel is busy, only a share of the players send
    return incomingRate > BUSY_RATE and math.random() > BUSY_RATE / incomingRate
end

-- Push: called by the recorder after every harvest
local function ShareHarvest(mapID, node)
    if not DB().enabled or not Shareable(node, mapID) then return end
    if (node.heard or 0) >= PUSH_KNOWN_LIMIT then
        stats.skippedKnown = stats.skippedKnown + 1
        Debug(("not sending %s: %d others already reported it"):format(node.name, node.heard))
        return
    end
    if Busy() then
        stats.skippedBusy = stats.skippedBusy + 1
        Debug("channel busy, not sending " .. node.name)
        return
    end
    SendNodes(mapID, { node }, Targets())
end

-- Pull: ask who knows more nodes for a zone than we do
local function QueryZone(mapID, now)
    if not DB().enabled or not mapID then return end
    if time() - (lastQuery[mapID] or 0) < QUERY_COOLDOWN then return end
    -- a moment later: when many log in at once (launch, a megaserver), the
    -- first one asks and the others just listen to the answers
    if not now then
        C_Timer.After(math.random() * QUERY_JITTER, function() QueryZone(mapID, true) end)
        return
    end
    local heard = time() - (heardQuery[mapID] or 0) < QUERY_HEARD
    -- Not in the public channel yet (e.g. right after login): don't use up the
    -- cooldown, JoinChannel asks again once we are in
    if not DB().public or (channelID and channelID > 0) then
        lastQuery[mapID] = time()
    end
    -- Count only what sync can add: nodes beyond the known spawn points
    local known = 0
    for _, n in ipairs(ns.db.nodes[mapID] or {}) do
        if n.source ~= "questie" and n.source ~= "starter"
            and not (ns.IsKnownSpawn and ns.IsKnownSpawn(mapID, n.id, n.x, n.y)) then
            known = known + 1
        end
    end
    for _, t in ipairs(Targets()) do
        -- the channel's answers to someone else's question reach us anyway
        if not (heard and t == "CHANNEL") then
            Enqueue(("Q:%d:%d"):format(mapID, known), t)
        end
    end
    Debug(("asked for zone %d (we know %d)%s"):format(mapID, known, heard and ", channel: listening to another player's answers" or ""))
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function RateOK(sender, count)
    local r = rate[sender]
    if not r or time() - r.start > RATE_WINDOW then
        r = { start = time(), count = 0 }
        rate[sender] = r
    end
    r.count = r.count + count
    return r.count <= RATE_MAX_NODES
end

local function FindNear(list, id, mapID, x, y)
    if not list then return end
    for _, n in ipairs(list) do
        if n.id == id and ns.Distance(mapID, x, y, n.x, n.y) <= MERGE_RADIUS then
            return n
        end
    end
end

local function DisplayName(id, item, nodeType)
    -- Prefer a name we already know for this object (in our own language)
    local known = ns.KnownName(id)
    if known then return known end
    if nodeType == "chest" then return L["Unknown Chest"] end -- loot says nothing about the name
    local name = item and item > 0 and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(item)
    return name or (nodeType == "herb" and L["Unknown Herb"] or L["Unknown Ore"])
end

-- For those who want to see that sharing works: now and then one line in
-- chat with what other players' spots added (never more than one line every
-- few minutes). Off unless you turn it on (since 0.1.21, T9: the line was on
-- by default and read as chat spam). The choice is kept as announceOn = true;
-- the old announceOff (0.1.20 and before: true = turned off, nil = never
-- touched) is not asked any more - both mean "off" now.
local ANNOUNCE_DELAY, ANNOUNCE_GAP = 20, 180
local announce = { zones = {}, total = 0, lastAt = 0, pending = false, round = 0 }

-- The line that waits is thrown away, with what was counted for it. A
-- timer already on its way belongs to a round that is over and says nothing
-- (R1 S-N1; Codex, 13.11.2026: off and on again within a second - the timer
-- only asked the switch when its time had come, and the old line came).
local function AnnounceDrop()
    announce.zones, announce.total, announce.pending = {}, 0, false
    announce.round = announce.round + 1
end

-- The switch in the options
local function SetAnnounce(on)
    local db = DB()
    if not db then return end
    -- off by default (0.1.21, T9); the old "turned off" mark goes with the
    -- first choice made here
    db.announceOn = on and true or nil
    db.announceOff = nil
    if not on then AnnounceDrop() end
end

local function AnnounceImport(mapID)
    if DB().announceOn ~= true then
        if announce.pending then AnnounceDrop() end
        return
    end
    announce.zones[mapID] = (announce.zones[mapID] or 0) + 1
    announce.total = announce.total + 1
    if announce.pending then return end
    announce.pending = true
    local wait = math.max(ANNOUNCE_DELAY, announce.lastAt + ANNOUNCE_GAP - time())
    local round = announce.round
    C_Timer.After(wait, function()
        if announce.round ~= round then return end
        announce.pending = false
        -- turned off while the line waited: it is dropped, and what was
        -- counted for it is not said late (v0.1.22 S4; Codex, 12.11.2026, R3-N1)
        if DB().announceOn ~= true then
            announce.zones, announce.total = {}, 0
            return
        end
        announce.lastAt = time()
        local names = {}
        for zone in pairs(announce.zones) do
            names[#names + 1] = ns.GetZoneName and ns.GetZoneName(zone) or tostring(zone)
            if #names >= 3 then break end
        end
        if announce.total > 0 then
            ns.Print((L["%d spots shared by other players added (%s)."]):format(announce.total, table.concat(names, ", ")))
        end
        announce.zones, announce.total = {}, 0
    end)
end

-- What other players sent, over all sessions (ns.db.sync.counts): a spot
-- counts once per player who sent it, and only when it is taken (a new node:
-- right away from guild and friends, after the confirmations from others)
-- or when it confirms a node you know (a player not heard for it before).
-- Reports still waiting for confirmations are not counted here.
local function Counted(what, trusted)
    local db = DB()
    db.counts = db.counts or {}
    local c = db.counts
    c.received = (c.received or 0) + 1
    if what == "new" then
        c.new = (c.new or 0) + 1
        if trusted then c.trusted = (c.trusted or 0) + 1 else c.public = (c.public or 0) + 1 end
    else
        c.confirmed = (c.confirmed or 0) + 1
    end
end

local function Import(mapID, p)
    ns.db.nodes[mapID] = ns.db.nodes[mapID] or {}
    local node = {
        id = p.id, name = DisplayName(p.id, p.item, p.type), type = p.type,
        x = p.x, y = p.y, count = p.rc or 1, last = time(),
        item = p.item > 0 and p.item or nil, source = "sync",
        heard = p.rc or 1, heardBy = {},
        -- named after its item (no name of ours for the object): never used
        -- as the object's name when our own loot is checked (Core.lua ObjectName)
        itemName = not ns.KnownName(p.id) or nil,
    }
    for who in pairs(p.reporters or {}) do node.heardBy[who] = true end
    table.insert(ns.db.nodes[mapID], node)
    stats.imported = stats.imported + 1
    ns.NotifyNodesChanged("add", mapID, node) -- adds just this pin, keeps the index current
    AnnounceImport(mapID)
end

-- Parked by self-healing (Route.lua leaves it out, Pins.lua fades it).
-- Harvesting it makes it your own node (source cleared, hits > 0): not parked.
local function IsParked(n)
    return (n and n.parked and n.source == "sync" and (n.hits or 0) == 0) and true or false
end

-- The zone a node is saved in (parking is rare: a plain search will do)
local function MapOf(n)
    for mapID, list in pairs(ns.db.nodes) do
        for _, x in ipairs(list) do
            if x == n then return mapID end
        end
    end
end

-- Parked or back: only this node's pins (they fade) and the route's node
-- list change. Telling everyone "all changed" would take every pin of the
-- continent off and on again for one node.
local function ParkChanged(n, mapID)
    mapID = mapID or MapOf(n)
    if ns.RouteNodeListChanged then ns.RouteNodeListChanged() end
    if mapID then
        ns.NotifyNodesChanged("update", mapID, n)
    else
        ns.NotifyNodesChanged()
    end
end

local function Unpark(n, why, mapID)
    if not n.parked then return end
    n.parked, n.healMisses, n.healAt, n.healFirst, n.healStay = nil, nil, nil, nil, nil
    stays[n] = nil
    Debug(("%s is back (%s)"):format(tostring(n.name), why))
    ParkChanged(n, mapID)
end

-- Route.lua calls this when the run target was found empty (not skipped,
-- not in combat). Returns true when the node was parked just now.
-- An empty visit counts once per stay: standing at the spot (or waiting
-- there through a stop and a new run) the route checks it again and again,
-- but that is still the same visit. The spot of the last counted visit is
-- kept on the node (n.healStay, world position) until you are seen clearly
-- away from it during a run (see NoteWhere).

-- Route.lua, every check of a run: where you are. pos() gives the player's
-- world position; leave: yards from the spot that count as gone from it.
local function NoteWhere(pos, leave)
    if not next(stays) then return end
    local px, py, inst = pos()
    if not px then return end
    for n in pairs(stays) do
        local s = n.healStay
        if not s or s.inst ~= inst or (px - s.wx) ^ 2 + (py - s.wy) ^ 2 > leave * leave then
            n.healStay, stays[n] = nil, nil
            if s then Debug(("left the spot of %s: its next empty visit counts again"):format(tostring(n.name))) end
        end
    end
end

-- at: { wx, wy, inst } of the spot (Route.lua); without it nothing is kept
local function SelfHeal(n, at)
    if not n or n.parked or n.source ~= "sync" or (n.hits or 0) > 0 then return end
    -- seen with your own eyes (tooltip), or more players than the first
    -- confirmations know it: real
    if n.seenAt or (n.heard or 0) > CONFIRMATIONS then return end
    -- still the stay of the last counted empty visit: not a visit of its own
    if n.healStay then return end
    local now = time()
    if n.healAt and now - n.healAt < HEAL_SPACING then return end
    if n.healAt and now - n.healAt > HEAL_RESET then
        n.healFirst, n.healMisses = nil, nil -- long ago: count from scratch
    end
    if at and at.wx then
        n.healStay = { wx = at.wx, wy = at.wy, inst = at.inst }
        stays[n] = true
    end
    n.healAt = now
    n.healFirst = n.healFirst or now
    n.healMisses = (n.healMisses or 0) + 1
    if n.healMisses < HEAL_MISSES or now - n.healFirst < HEAL_SPAN then return end
    n.parked = now
    ns.Print((L["%s was always empty and only came from other players: left out of routes until someone new reports it."]):format(n.name))
    Debug(("parked %s"):format(tostring(n.id)))
    ParkChanged(n)
    return true
end

---------------------------------------------------------------------------
-- An entry that is sent again (v0.1.23 P2)
--   Sven, 13.11.2026, /gcr perf: 580 messages and 4,460 nodes a minute,
--   380 ms a minute in the handlers - most of the nodes sent again and
--   again (six or seven players of 0.1.21 answer one question with the same
--   nodes). Every entry was taken apart, checked, and searched by distance:
--   among the known nodes of its kind, then among the waiting reports.
--   Now the text of an entry ("o1731,o,3000,3000,2770") that led to a known
--   node or to a waiting report is remembered per zone, with that node or
--   report. The same text again goes straight to it. What happens then is
--   the same code as before.
--   A remembered entry is only as good as the search would be now, so it
--   goes when the search could end differently:
--     - a node is added: what is remembered for its kind within twice the
--       merge radius of it (it could be the nearer one, or the first one);
--     - a node moved or changed ("update"): everything of that zone;
--     - anything else (deleted, cleared, imported in bulk): everything;
--     - a report leaves the waiting list: what pointed to it;
--     - the waiting list of a zone is another table than it was: not used.
--   Kept small: after EXACT_MAX remembered entries everything is dropped.
--   ns.SyncExactOff = true: the lookup is not used (the tests compare the
--   two ways with it).
---------------------------------------------------------------------------
local EXACT_MAX = 6000
local exact = {}       -- mapID -> entry text -> the known node or the waiting report it led to
local exactList = setmetatable({}, { __mode = "k" }) -- a waiting report -> the list it was found in
local exactCount = 0

local function ExactDrop(mapID)
    if mapID then
        exact[mapID] = nil
    else
        wipe(exact)
        exactCount = 0
    end
end

local function ExactKeep(mapID, entry, what, list)
    if ns.SyncExactOff then return end
    if exactCount >= EXACT_MAX then ExactDrop() end
    local zone = exact[mapID]
    if not zone then
        zone = {}
        exact[mapID] = zone
    end
    if zone[entry] == nil then exactCount = exactCount + 1 end
    zone[entry] = what
    if list then exactList[what] = list end
end

-- a report left the waiting list of mapID
local function ExactGone(mapID, p)
    local zone = exact[mapID]
    if not zone then return end
    for entry, what in pairs(zone) do
        if what == p then zone[entry] = nil end
    end
end

-- Core.lua tells every change of the nodes (NotifyNodesChanged)
table.insert(ns.nodeListeners, function(kind, mapID, node)
    if kind == "add" and mapID and node then
        local zone = exact[mapID]
        if zone and node.x and node.y then
            for entry, what in pairs(zone) do
                if what.id == node.id and ns.Distance(mapID, node.x, node.y, what.x, what.y) <= 2 * MERGE_RADIUS + 1 then
                    zone[entry] = nil
                end
            end
        elseif zone then
            ExactDrop(mapID)
        end
    elseif kind == "update" and mapID then
        ExactDrop(mapID)
    else
        ExactDrop()
    end
end)

-- What arrived and is not counted by Counted (0.2.2 d1, honest counters;
-- Sync 2.0 analysis of 21.11.2026): the same player again for a spot or a
-- waiting report ("repeats"), and a spot HEARD_KEEP players confirmed
-- already ("full"). Over all sessions, like the counts above.
local function NotCounted(what)
    local db = DB()
    db.counts = db.counts or {}
    db.counts[what] = (db.counts[what] or 0) + 1
end

-- A node we know was named by `who`: remember that others know it too (for push suppression)
local function HeardKnown(known, who, mapID)
    known.heardBy = known.heardBy or {}
    if not known.heardBy[who] then
        local names = 0
        for _ in pairs(known.heardBy) do names = names + 1 end
        -- enough names known: more of them change nothing (and one
        -- player repeating himself can't push the count up)
        if names < HEARD_KEEP then
            known.heardBy[who] = true
            known.heard = (known.heard or 0) + 1
            Counted("confirmed")
            -- someone new has it: it is real after all
            if known.parked then Unpark(known, "reported by " .. who, mapID) end
        else
            NotCounted("full")
        end
    else
        NotCounted("repeats")
    end
end

-- A waiting report was named by `who`: one more reporter, and with enough of
-- them (or from guild and friends) it becomes a node
local function HeardPending(mapID, list, p, who, trusted, dry)
    if not p.reporters[who] then
        p.reporters[who] = true
        p.rc = p.rc + 1
    elseif not dry then
        NotCounted("repeats")
    end

    if trusted or p.rc >= CONFIRMATIONS then
        for i, q in ipairs(list) do
            if q == p then
                table.remove(list, i)
                break
            end
        end
        if dry then
            stress.imported = stress.imported + 1
        else
            ExactGone(mapID, p)
            if ns.OnPendingChanged then ns.OnPendingChanged(mapID, p, "remove") end
            Import(mapID, p)
            Counted("new", trusted)
            Debug(("imported %s in %d (%s)"):format(p.id, mapID, trusted and "trusted" or (p.rc .. " reports")))
        end
    end
end

local function HandleNode(mapID, entry, who, trusted, dry)
    -- the same entry as before (see above): straight to what it led to
    if not dry and not ns.SyncExactOff then
        local zone = exact[mapID]
        local what = zone and zone[entry]
        if what then
            local list = exactList[what]
            if not list then
                HeardKnown(what, who, mapID)
                return
            elseif list == DB().pending[mapID] then
                HeardPending(mapID, list, what, who, trusted, dry)
                return
            end
            zone[entry] = nil -- (the waiting list was replaced: search again)
        end
    end
    local id, code, xs, ys, items = strsplit(",", entry)
    -- Validation: only real game objects, valid type, plain whole numbers
    -- (tonumber alone lets "nan", "1e3" or hex through)
    if not (xs and ys and xs:match("^%d+$") and ys:match("^%d+$")) then return end
    if items and items ~= "" and not items:match("^%d+$") then return end
    local x, y, item = tonumber(xs), tonumber(ys), tonumber(items) or 0
    if item > MAX_ITEM_ID then return end
    local nodeType = CODE_TYPE[code or ""]
    if not (id and id:match("^o%d+$") and nodeType and x and y) then return end
    if x > 10000 or y > 10000 then return end
    -- a quest object (its item is a quest item, 0.2.1 A3): no herb or ore.
    -- A report without an item (0) can't tell: it comes in as before.
    if item > 0 and ns.IsQuestNode and ns.IsQuestNode(id, item) then return end
    x, y = x / 10000, y / 10000

    -- Already known: just remember that others know it too (for push suppression)
    local known = ns.FindNode(mapID, id, x, y, MERGE_RADIUS)
    if known then
        if not dry then
            ExactKeep(mapID, entry, known)
            HeardKnown(known, who, mapID)
        end
        return
    end

    -- Pending confirmations
    local root = dry and stress.pending or DB().pending
    root[mapID] = root[mapID] or {}
    local list = root[mapID]
    local p = FindNear(list, id, mapID, x, y)
    if not p then
        local mine = 0
        for _, q in ipairs(list) do
            if q.by == who then mine = mine + 1 end
        end
        if mine >= PENDING_PER_REPORTER then return end
        if not trusted and not dry then
            -- one stranger in all zones together, and all reports together:
            -- the oldest unconfirmed report goes (a flood can't block others for days)
            local total, theirs, oldest, oldestMap, oldestIndex = 0, 0, nil, nil, nil
            for m, l in pairs(root) do
                for i, q in ipairs(l) do
                    total = total + 1
                    if q.by == who then theirs = theirs + 1 end
                    if not oldest or (q.first or 0) < (oldest.first or 0) then oldest, oldestMap, oldestIndex = q, m, i end
                end
            end
            if theirs >= PENDING_PER_REPORTER_TOTAL then return end
            if total >= PENDING_MAX_TOTAL and oldest then
                table.remove(root[oldestMap], oldestIndex)
                ExactGone(oldestMap, oldest)
                if ns.OnPendingChanged then ns.OnPendingChanged(oldestMap, oldest, "remove") end
            end
        end
        if #list >= PENDING_MAX_PER_ZONE then
            local gone = table.remove(list, 1) -- oldest unconfirmed report goes
            if not dry then ExactGone(mapID, gone) end
            if not dry and ns.OnPendingChanged then ns.OnPendingChanged(mapID, gone, "remove") end
        end
        p = { id = id, type = nodeType, x = x, y = y, item = item, reporters = {}, rc = 0, first = time(), by = who }
        table.insert(list, p)
        -- new zones show single reports as grey pins (Pins.lua); an instant
        -- import (guild, friends) doesn't need one
        if not dry and not trusted and ns.OnPendingChanged then ns.OnPendingChanged(mapID, p, "add") end
    end
    if not dry then ExactKeep(mapID, entry, p, list) end
    HeardPending(mapID, list, p, who, trusted, dry)
end

local function OnNodes(body, sender, trusted, dry)
    local parts = { strsplit(";", body) }
    if not (parts[1] and parts[1]:match("^%d+$")) then return end
    local mapID = tonumber(parts[1])
    if not mapID or not C_Map.GetMapInfo(mapID) then return end
    if not RateOK(sender, #parts - 1) then
        if not dry then
            local cur = PerfNow()
            cur.overLimit = cur.overLimit + #parts - 1
        end
        Debug("rate limit hit by " .. sender)
        return
    end
    if not dry then
        local cur = PerfNow()
        cur.nodes = cur.nodes + #parts - 1
    end
    -- Someone answers a zone query: we may not need to answer ourselves, or
    -- not to the end (see AnswerStops). A harvest somebody shares is one node
    -- in a message - that is no answer.
    local a = answering[mapID]
    if a and not dry then AnswerHeard(a, sender, #parts - 1) end
    local who = ShortName(sender) -- (once a message, not once an entry)
    for i = 2, #parts do
        HandleNode(mapID, parts[i], who, trusted, dry)
    end
end

-- Nodes we can tell a newcomer about: our own harvests plus nodes that
-- reached us through sync and were confirmed (trusted or several reporters)
local function OwnNodes(mapID)
    local own = {}
    for _, n in ipairs(ns.db.nodes[mapID] or {}) do
        local ok = Shareable(n, mapID) or (n.source == "sync" and not IsParked(n) and n.id and n.id:match("^o%d+$") and n.type
            and not (ns.IsKnownSpawn and ns.IsKnownSpawn(mapID, n.id, n.x, n.y))
            and not (ns.IsQuestNode and ns.IsQuestNode(n.id, n.item)))
        if ok then own[#own + 1] = n end
    end
    return own
end

-- Is an answer worth its messages? (v0.1.22 S1; Sven's debug log,
-- 12.11.2026: "answered zone 1420 with 150 nodes (they knew 151)".) What
-- counts is what would really be sent - never more than RATE_MAX_NODES, the
-- others take no more from one player in a minute - against what the asker
-- knows: at least ANSWER_MORE_SHARE more and at least ANSWER_MORE_NODES more.
-- An asker who knows fewer than that many needs only as many more as he
-- knows, so somebody who knows nothing is told whatever there is. The two
-- numbers only say how many each side knows, not which: an answer of about
-- the asker's size is mostly what he has, and it costs a message per 8 nodes.
--   Never with one node, and never for one node more (R1 S-M2; Sven,
-- 13.11.2026): a message with a single node is a harvest for everyone who
-- hears it, not an answer - nobody could count it, so nobody stopped. That
-- node goes out with its next harvest. So the first packet of every answer
-- has two nodes or more (two always fit in one message).
local function WorthAnswering(ownCount, theirCount)
    local sent = math.min(ownCount, RATE_MAX_NODES)
    local more = math.max(math.ceil(theirCount * ANSWER_MORE_SHARE), math.min(ANSWER_MORE_NODES, theirCount), ANSWER_MIN_NODES)
    return sent >= ANSWER_MIN_NODES and sent >= theirCount + more
end

local function OnQuery(body, sender, distribution)
    local mapID, theirCount = body:match("^(%d+):?(%d*)$")
    mapID, theirCount = tonumber(mapID), tonumber(theirCount) or 0
    if not mapID then return end
    -- a query costs like a few nodes: one player asking again and again is cut off
    if not RateOK(sender, 10) then return end
    -- a real question in the channel: its answers reach us too (a spammer's
    -- don't count: nobody answers those)
    if distribution ~= "GUILD" then heardQuery[mapID] = time() end
    if answering[mapID] then return end
    if time() - (answeredAt[mapID] or 0) < ANSWER_COOLDOWN then return end
    if #queue >= QUEUE_ANSWER_MAX then return end
    local own = OwnNodes(mapID)
    -- Only answer if we can add something
    if not WorthAnswering(#own, theirCount) then return end
    if Busy() then return end
    -- Wait a random moment; if enough others answer first, stay quiet. The
    -- answer is kept in `answering` until its last packet is out: the others'
    -- answers are counted for it up to the moment our place is known.
    local a = { mapID = mapID, responders = {}, ahead = 0, went = 0, before = 0, sent = 0, packets = 0 }
    answering[mapID] = a
    C_Timer.After(ANSWER_WAIT_MIN + math.random() * (ANSWER_WAIT_MAX - ANSWER_WAIT_MIN), function()
        if a.ahead >= MAX_RESPONDERS then
            if answering[mapID] == a then answering[mapID] = nil end
            return
        end
        answeredAt[mapID] = time()
        -- others take at most RATE_MAX_NODES from one player a minute: send
        -- the best known ones, no more
        if #own > RATE_MAX_NODES then
            table.sort(own, function(x, y) return (x.count or 0) > (y.count or 0) end)
            for i = #own, RATE_MAX_NODES + 1, -1 do own[i] = nil end
        end
        a.packets = SendNodes(mapID, own, { distribution == "GUILD" and "GUILD" or "CHANNEL" }, a)
        if a.packets == 0 and answering[mapID] == a then answering[mapID] = nil end
        Debug(("answering zone %d with %d nodes in %d packets (they knew %d)"):format(mapID, #own, a.packets, theirCount))
    end)
end

-- Incoming load: process at most RECV_BUDGET messages per second
local function WithinBudget()
    local now = GetTime()
    local elapsed = now - recv.start
    if elapsed >= 1 then
        incomingRate = incomingRate * 0.5 + (recv.count / elapsed) * 0.5
        recv.start, recv.count, recv.processed = now, 0, 0
    end
    recv.count = recv.count + 1
    if recv.processed >= RECV_BUDGET then
        stats.dropped = stats.dropped + 1
        return false
    end
    recv.processed = recv.processed + 1
    return true
end

local function Receive(prefix, text, distribution, sender, dry)
    if prefix ~= PREFIX then
        -- (every addon's messages pass this handler)
        if not dry then
            local cur = PerfNow()
            cur.other = cur.other + 1
        end
        return
    end
    if not DB().enabled then return end
    local msgKind, msgMap = text:match("^(%u):(%d+)")
    msgMap = tonumber(msgMap)
    if not dry then
        -- our own messages come back from the channel: not worth a debug line
        if IsSelf(sender) or LearnSelf(sender, text) then
            perf.back = (perf.back or 0) + 1
            AnswerEcho(text)
            return
        end
        local cur = PerfNow()
        cur.msgIn = cur.msgIn + 1
        if ns.db.debug then
            local zone = msgMap and ns.GetZoneName and ns.GetZoneName(msgMap)
            Debug(("recv [%s] %s: %s%s"):format(distribution, sender, text:sub(1, 60),
                zone and ("  (" .. zone .. ")") or ""))
        end
    end
    if DB().blocked[ShortName(sender)] then return end
    if distribution == "CHANNEL" and not DB().public then return end
    if not WithinBudget() then
        if not dry then
            local cur = PerfNow()
            cur.overBudget = cur.overBudget + 1
        end
        return
    end

    if not dry then
        stats.received = stats.received + 1
        local peer = stats.peers[ShortName(sender)] or { asked = 0, nodes = 0 }
        stats.peers[ShortName(sender)] = peer
        peer.t, peer.map = time(), msgMap or peer.map
        if msgKind == "Q" then peer.asked = peer.asked + 1 end
        if msgKind == "N" then
            local _, count = text:gsub(";", ";")
            peer.nodes = peer.nodes + count
        end
    end

    local kind, body = text:match("^(%u):(.*)$")
    if kind == "N" then
        OnNodes(body, sender, not dry and IsTrusted(sender, distribution), dry)
    elseif kind == "Q" and not dry then
        OnQuery(body, sender, distribution)
    elseif kind == "V" and not dry then
        -- the player's version (see SayVersion): plain letters, digits, "." and "-"
        local v = body:match("^gc([%w%.%-]+)$")
        local peer = stats.peers[ShortName(sender)]
        if v and #v <= VERSION_MAX and peer then peer.version = v end
    end
end

---------------------------------------------------------------------------
-- Stress test: /gcr sync stress <messages per second> <seconds>
--   Feeds fake messages from 300 fake players into the receiver and
--   measures the cost. Nothing is stored or sent.
---------------------------------------------------------------------------
local function StressTest(perSecond, seconds)
    if stress then
        ns.Print("A stress test is already running.")
        return
    end
    perSecond = math.max(1, math.min(2000, perSecond or 200))
    seconds = math.max(1, math.min(60, seconds or 10))
    local mapID = ns.PlayerMap() or 1412
    stress = {
        sent = 0, ms = 0, imported = 0, pending = {},
        fpsMin = math.huge, fpsSum = 0, fpsN = 0,
        dropped = stats.dropped, start = GetTime(),
    }
    ns.Print(("Stress test: %d messages/s for %d s (fake data, nothing is stored)..."):format(perSecond, seconds))

    local acc = 0
    local ticker
    ticker = C_Timer.NewTicker(0.1, function()
        acc = acc + perSecond / 10
        while acc >= 1 do
            acc = acc - 1
            local parts = {}
            for k = 1, math.random(1, 6) do
                parts[k] = ("o%d,%s,%d,%d,2447"):format(900000 + math.random(1, 60),
                    math.random() < 0.5 and "h" or "o", math.random(0, 10000), math.random(0, 10000))
            end
            local text = "N:" .. mapID .. ";" .. table.concat(parts, ";")
            local t0 = debugprofilestop()
            Receive(PREFIX, text, "CHANNEL", "StressBot" .. math.random(1, 300), true)
            stress.ms = stress.ms + (debugprofilestop() - t0)
            stress.sent = stress.sent + 1
        end
        local fps = GetFramerate()
        stress.fpsMin = math.min(stress.fpsMin, fps)
        stress.fpsSum = stress.fpsSum + fps
        stress.fpsN = stress.fpsN + 1

        if GetTime() - stress.start >= seconds then
            ticker:Cancel()
            local s = stress
            local dropped = stats.dropped - s.dropped
            stats.dropped = s.dropped -- fake drops don't count in the real stats
            ns.Print("Stress test finished:")
            print(("  Messages: %d sent, %d processed, %d dropped by the budget (%d/s)"):format(
                s.sent, s.sent - dropped, dropped, RECV_BUDGET))
            print(("  CPU: %.3f ms per message, %.1f ms per second in total"):format(
                s.sent > 0 and s.ms / s.sent or 0, s.ms / seconds))
            print(("  FPS: average %.0f, lowest %.0f"):format(s.fpsSum / math.max(1, s.fpsN), s.fpsMin))
            print(("  Fake nodes that would have been confirmed: %d"):format(s.imported))
            stress = nil
        end
    end)
end

---------------------------------------------------------------------------
-- Channel handling
---------------------------------------------------------------------------
local function HideChannelFromChat()
    if not ChatFrame_RemoveChannel then return end
    for i = 1, NUM_CHAT_WINDOWS do
        local frame = _G["ChatFrame" .. i]
        if frame then pcall(ChatFrame_RemoveChannel, frame, CHANNEL) end
    end
end

local function JoinChannel()
    if not DB().enabled or not DB().public then return end
    local id = GetChannelName(CHANNEL)
    if not id or id == 0 then
        JoinTemporaryChannel(CHANNEL)
        id = GetChannelName(CHANNEL)
    end
    channelID = id
    HideChannelFromChat()
    Debug("channel " .. CHANNEL .. " = " .. tostring(channelID))
    -- once after joining: which Gathercraft this is (0.2.2 d1)
    if channelID and channelID > 0 and not versionSaid.channel then
        versionSaid.channel = true
        SayVersion("CHANNEL")
    end
end

local function LeaveChannel()
    if GetChannelName(CHANNEL) and GetChannelName(CHANNEL) > 0 then
        LeaveChannelByName(CHANNEL)
    end
    channelID = nil
    versionSaid.channel = nil -- (joined again: said again)
end

local function CurrentZoneQuery()
    local mapID = ns.PlayerMap()
    QueryZone(mapID)
end

-- A farm run through other zones: ask for those too, so new spots others
-- found there are in the route from the start. A few zones only (the ones
-- the route reaches first), one after another - never the whole world.
local ROUTE_QUERY_MAX = 5     -- zones asked for per run
local ROUTE_QUERY_GAP = 15    -- seconds between them
local function QueryRouteZones(mapIDs)
    if not DB().enabled then return end
    -- not in the public channel (yet): the zone cooldown doesn't count there,
    -- so don't ask at all (the current zone is asked once we are in)
    if DB().public and not (channelID and channelID > 0) then return end
    local here = ns.PlayerMap()
    local n = 0
    for _, mapID in ipairs(mapIDs) do
        if mapID ~= here and time() - (lastQuery[mapID] or 0) >= QUERY_COOLDOWN and n < ROUTE_QUERY_MAX then
            n = n + 1
            C_Timer.After(n * ROUTE_QUERY_GAP, function() QueryZone(mapID) end)
        end
    end
    if n > 0 then Debug(("route: asking for %d more zone(s)"):format(n)) end
end

---------------------------------------------------------------------------
-- Commands: /gcr sync [on|off|public|ask|stress|block <name>|unblock <name>]
---------------------------------------------------------------------------
local function CountPending()
    local n = 0
    for _, list in pairs(DB().pending) do n = n + #list end
    return n
end

local function Status()
    local peers, now, recent = 0, time(), {}
    for name, p in pairs(stats.peers) do
        if now - p.t < 3600 then
            peers = peers + 1
            recent[#recent + 1] = { name = name, p = p }
        end
    end
    table.sort(recent, function(a, b) return a.p.t > b.p.t end)
    ns.Print((L["Sync %s, public channel %s (%s), guild %s."]):format(
        DB().enabled and L["|cff00ff00ON|r"] or L["|cffff0000OFF|r"],
        DB().public and "on" or "off",
        (channelID and channelID > 0) and ("#" .. channelID) or L["not joined"],
        IsInGuild() and "yes" or "no"))
    print((L["  Players seen (1h): %d   Messages received: %d   Incoming: %.1f/s"]):format(
        peers, stats.received, incomingRate))
    print((L["  Imported this session: %d   Waiting for confirmation: %d"]):format(stats.imported, CountPending()))
    local c = DB().counts or {}
    print((L["  Received from other players (all sessions): %d spots, %d new (%d guild/friends, %d public, confirmed), %d confirm spots you know"]):format(
        c.received or 0, c.new or 0, c.trusted or 0, c.public or 0, c.confirmed or 0))
    -- (0.2.2 d1) what arrived and is not counted there
    print((L["  Received but not counted (all sessions): %d repeats (the same player again), %d for spots already confirmed by %d players"]):format(
        c.repeats or 0, c.full or 0, HEARD_KEEP))
    print((L["  Not sent (already known): %d   Not sent (busy): %d   Dropped (budget): %d"]):format(
        stats.skippedKnown, stats.skippedBusy, stats.dropped))
    print((L["  Refused by the game when sending (since login): %d throttled, %d channel throttled, %d channel not valid"]):format(
        sendRefused.throttled, sendRefused.chanThrottled, sendRefused.badChannel))
    print((L["  Confirmations needed: %d (guild and friends count instantly)"]):format(CONFIRMATIONS))
    -- the versions of the players of the last hour (0.2.2 d1): a player's
    -- version is heard once, when he joins - who was online before you, or
    -- runs a version before 0.2.2, is "no version heard"
    local versions, unheard, parts = {}, 0, {}
    for _, r in ipairs(recent) do
        if r.p.version then versions[r.p.version] = (versions[r.p.version] or 0) + 1 else unheard = unheard + 1 end
    end
    local order = {}
    for v, n in pairs(versions) do order[#order + 1] = { v = v, n = n } end
    table.sort(order, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.v > b.v end)
    for _, e in ipairs(order) do parts[#parts + 1] = ("%s: %d"):format(e.v, e.n) end
    parts[#parts + 1] = (L["no version heard: %d"]):format(unheard)
    print((L["  Versions of the players seen (1h): %s"]):format(table.concat(parts, " · ")))
    -- who was active where: tells whether someone shared nodes or only asked
    for i = 1, math.min(8, #recent) do
        local r = recent[i]
        local zone = r.p.map and ns.GetZoneName and ns.GetZoneName(r.p.map) or "?"
        local what = (r.p.nodes > 0 and (L["%d nodes shared"]):format(r.p.nodes))
            or (r.p.asked > 0 and L["only asked for nodes"]) or "-"
        print(("  |cffffd100%s|r  %s  ·  %s  ·  %d min  ·  %s"):format(r.name, zone, what,
            math.floor((now - r.p.t) / 60), r.p.version or "-"))
    end
end

local function Command(rest)
    local cmd, arg = (rest or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local db = DB()
    if cmd == "on" then
        db.enabled = true
        JoinChannel()
        ns.Print(L["Sync enabled."])
    elseif cmd == "off" then
        db.enabled = false
        LeaveChannel()
        ns.Print(L["Sync disabled."])
    elseif cmd == "public" then
        db.public = not db.public
        if db.public then JoinChannel() else LeaveChannel() end
        ns.Print(L["Public sync "] .. (db.public and "on" or L["off (guild and friends only)"]) .. ".")
    elseif cmd == "block" and arg ~= "" then
        db.blocked[arg] = true
        ns.Print(L["Ignoring sync data from "] .. arg .. ".")
    elseif cmd == "unblock" and arg ~= "" then
        db.blocked[arg] = nil
        ns.Print(L["No longer ignoring "] .. arg .. ".")
    elseif cmd == "ask" then
        wipe(lastQuery)
        CurrentZoneQuery()
        ns.Print(L["Asked other players for nodes in this zone."])
    elseif cmd == "stress" then
        local a, b = arg:match("^(%d*)%s*(%d*)$")
        StressTest(tonumber(a), tonumber(b))
    else
        Status()
        print("  /gcr sync on|off | public | ask | stress [msg/s] [sec] | block <name> | unblock <name>")
    end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
-- Drop old unconfirmed reports
local function DropOldPending(s)
    for mapID, list in pairs(s.pending) do
        for i = #list, 1, -1 do
            local maxAge = (ns.HasKnownSpawns and ns.HasKnownSpawns(mapID)) and PENDING_MAX_AGE or PENDING_MAX_AGE_NEW
            if time() - (list[i].first or 0) > maxAge then
                ExactGone(mapID, table.remove(list, i))
            end
        end
        if #list == 0 then s.pending[mapID] = nil end
    end
end
ns.DropOldPending = function() DropOldPending(ns.db.sync) end -- for the tests (tools/smoke_test.lua)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        local db = ns.db
        db.sync = db.sync or {}
        local s = db.sync
        if s.enabled == nil then s.enabled = true end
        if s.public == nil then s.public = true end
        s.pending = s.pending or {}
        s.blocked = s.blocked or {}
        -- per realm and faction: an alt elsewhere talks to other players
        local scope = (GetNormalizedRealmName() or "") .. "-" .. (UnitFactionGroup and UnitFactionGroup("player") or "")
        if type(s.lastQuery) ~= "table" then s.lastQuery = {} end
        for key, list in pairs(s.lastQuery) do
            if type(list) ~= "table" then
                s.lastQuery[key] = nil
            else
                for mapID, t in pairs(list) do
                    if time() - t >= QUERY_COOLDOWN then list[mapID] = nil end
                end
                if not next(list) then s.lastQuery[key] = nil end
            end
        end
        s.lastQuery[scope] = s.lastQuery[scope] or {}
        lastQuery = s.lastQuery[scope]

        -- spots of counted empty visits you were not seen leaving yet (kept over a reload)
        for _, list in pairs(ns.db.nodes or {}) do
            for _, n in ipairs(list) do
                if n.healStay then stays[n] = true end
            end
        end

        DropOldPending(s)

        playerName = (ns.Readable(UnitName("player"), "sync") or "") .. "-" .. (GetNormalizedRealmName() or "")
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        -- (one ticker, whatever tells us about the login twice: two would send two
        -- packets of an answer before the first has come back, see AnswerStops)
        if not sendTicker then
            sendTicker = C_Timer.NewTicker(SEND_INTERVAL, function()
                local t0 = debugprofilestop()
                SendNext()
                PerfTime(t0)
            end)
        end
        C_Timer.After(JOIN_DELAY, function()
            JoinChannel()
            -- once per login in the guild: which Gathercraft this is (0.2.2 d1)
            if DB().enabled and IsInGuild() and not versionSaid.guild then
                versionSaid.guild = true
                SayVersion("GUILD")
            end
            C_Timer.After(2, CurrentZoneQuery)
        end)
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, distribution, sender = ...
        if ns.AnySecret("CHAT_MSG_ADDON", prefix, text, distribution, sender) then return end
        local t0 = debugprofilestop()
        Receive(prefix, text, distribution, sender, false)
        PerfTime(t0)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if ns.db and ns.db.sync then
            C_Timer.After(3, CurrentZoneQuery)
        end
    end
end)

ns.SyncShare = ShareHarvest
ns.SyncQueryRouteZones = QueryRouteZones
-- unconfirmed reports of one zone (grey pins in zones without known spawn points)
ns.SyncSelfHeal = SelfHeal
ns.SyncNoteWhere = NoteWhere
ns.IsParked = IsParked
-- For the options: players seen in the last hour, spots received this session, waiting
ns.SyncSummary = function()
    local peers, now = 0, time()
    for _, p in pairs(stats.peers) do
        if now - p.t < 3600 then peers = peers + 1 end
    end
    local joined = channelID and channelID > 0
    return peers, stats.imported, CountPending(), joined
end
ns.SyncUnpark = Unpark
-- over all sessions: received, new, confirmations, new from guild and friends, new from others
ns.SyncCounts = function()
    local c = (ns.db and ns.db.sync and ns.db.sync.counts) or {}
    return c.received or 0, c.new or 0, c.confirmed or 0, c.trusted or 0, c.public or 0
end
ns.SyncPending = function(mapID)
    local db = ns.db and ns.db.sync
    return db and db.pending and db.pending[mapID]
end
ns.SyncDisplayName = DisplayName
ns.SyncCommand = Command
ns.SyncSetAnnounce = SetAnnounce
ns.SyncPerf = Perf
