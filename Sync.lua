local ADDON_NAME, ns = ...

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
---------------------------------------------------------------------------
local PREFIX = "Gathercraft"
local CHANNEL = "GathercraftSync"
local CONFIRMATIONS = 3       -- different players needed for a public node
local PUSH_KNOWN_LIMIT = 3    -- stop live-sending a node once this many others reported it
local MERGE_RADIUS = 10       -- yards: same kind closer than this = same node
local SEND_INTERVAL = 1.2     -- seconds between outgoing messages
local MAX_MSG_LEN = 240
local RECV_BUDGET = 40        -- max incoming messages processed per second
local BUSY_RATE = 20          -- incoming messages per second above which we send less
local RATE_WINDOW = 60        -- seconds
local RATE_MAX_NODES = 150    -- max nodes accepted per sender per window
local QUERY_COOLDOWN = 600    -- seconds before asking for the same zone again
local MAX_RESPONDERS = 3
local PENDING_MAX_AGE = 3 * 24 * 3600
local PENDING_MAX_PER_ZONE = 300 -- unconfirmed reports kept per zone (oldest go first)
local PENDING_PER_REPORTER = 30  -- one stranger can't fill the list with fake reports
local JOIN_DELAY = 8          -- seconds after login (let General/Trade join first)

local TYPE_CODE = { herb = "h", ore = "o", chest = "c" }
local CODE_TYPE = { h = "herb", o = "ore", c = "chest" }

local queue = {}              -- outgoing messages { text, target }
local channelID
local rate = {}               -- sender -> { start, count }
local lastQuery = {}          -- mapID -> time
local answering = {}          -- mapID -> { responders = {} }
local recv = { start = 0, count = 0, processed = 0 }
local incomingRate = 0        -- smoothed messages per second
local stats = { received = 0, imported = 0, dropped = 0, skippedKnown = 0, skippedBusy = 0, peers = {} }
local stress                  -- running stress test (fake data, nothing stored)

local function DB()
    return ns.db.sync
end

local function Debug(text)
    ns.Debug("|cff66ccffsync|r " .. text)
end

---------------------------------------------------------------------------
-- Names and trust
---------------------------------------------------------------------------
local playerName

local function ShortName(sender)
    return Ambiguate and Ambiguate(sender, "none") or sender
end

local function IsSelf(sender)
    return sender == playerName or ShortName(sender) == UnitName("player")
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
local function Enqueue(text, target)
    queue[#queue + 1] = { text = text, target = target }
end

local function SendNext()
    local item = table.remove(queue, 1)
    if not item then return end
    local ok
    if item.target == "GUILD" then
        if IsInGuild() then
            ok = C_ChatInfo.SendAddonMessage(PREFIX, item.text, "GUILD")
        end
    elseif channelID and channelID > 0 then
        ok = C_ChatInfo.SendAddonMessage(PREFIX, item.text, "CHANNEL", channelID)
    end
    Debug(("sent [%s] %s -> %s"):format(item.target, item.text:sub(1, 60), tostring(ok)))
end

local function Coord(v)
    return math.floor(v * 10000 + 0.5)
end

local function EncodeNode(n)
    return ("%s,%s,%d,%d,%d"):format(n.id, TYPE_CODE[n.type] or "x", Coord(n.x), Coord(n.y), n.item or 0)
end

-- Sends a list of nodes of one zone, packed into as few messages as possible
local function SendNodes(mapID, nodes, targets)
    local head = "N:" .. mapID
    local msg = head
    local function flush()
        if msg ~= head then
            for _, t in ipairs(targets) do Enqueue(msg, t) end
        end
        msg = head
    end
    for _, n in ipairs(nodes) do
        local part = ";" .. EncodeNode(n)
        if #msg + #part > MAX_MSG_LEN then flush() end
        msg = msg .. part
    end
    flush()
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
    return n.id and n.id:match("^o%d+$") and n.type and not n.source
        and not (ns.IsKnownSpawn and ns.IsKnownSpawn(mapID, n.id, n.x, n.y))
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
local function QueryZone(mapID)
    if not DB().enabled or not mapID then return end
    if time() - (lastQuery[mapID] or 0) < QUERY_COOLDOWN then return end
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
    for _, t in ipairs(Targets()) do Enqueue(("Q:%d:%d"):format(mapID, known), t) end
    Debug(("asked for zone %d (we know %d)"):format(mapID, known))
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
    if nodeType == "chest" then return "Unknown Chest" end -- loot says nothing about the name
    local name = item and item > 0 and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(item)
    return name or (nodeType == "herb" and "Unknown Herb" or "Unknown Ore")
end

local function Import(mapID, p)
    ns.db.nodes[mapID] = ns.db.nodes[mapID] or {}
    local node = {
        id = p.id, name = DisplayName(p.id, p.item, p.type), type = p.type,
        x = p.x, y = p.y, count = p.rc or 1, last = time(),
        item = p.item > 0 and p.item or nil, source = "sync",
        heard = p.rc or 1,
    }
    table.insert(ns.db.nodes[mapID], node)
    stats.imported = stats.imported + 1
    ns.NotifyNodesChanged("add", mapID, node) -- adds just this pin, keeps the index current
end

local function HandleNode(mapID, entry, sender, trusted, dry)
    local id, code, xs, ys, items = strsplit(",", entry)
    local x, y, item = tonumber(xs), tonumber(ys), tonumber(items) or 0
    local nodeType = CODE_TYPE[code or ""]
    -- Validation: only real game objects, valid type and coordinates
    if not (id and id:match("^o%d+$") and nodeType and x and y) then return end
    if x < 0 or x > 10000 or y < 0 or y > 10000 then return end
    x, y = x / 10000, y / 10000
    local who = ShortName(sender)

    -- Already known: just remember that others know it too (for push suppression)
    local known = ns.FindNode(mapID, id, x, y, MERGE_RADIUS)
    if known then
        if not dry and (known.heard or 0) < PUSH_KNOWN_LIMIT then
            known.heardBy = known.heardBy or {}
            if not known.heardBy[who] then
                known.heardBy[who] = true
                known.heard = (known.heard or 0) + 1
            end
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
        if #list >= PENDING_MAX_PER_ZONE then
            table.remove(list, 1) -- oldest unconfirmed report goes
        end
        p = { id = id, type = nodeType, x = x, y = y, item = item, reporters = {}, rc = 0, first = time(), by = who }
        table.insert(list, p)
    end
    if not p.reporters[who] then
        p.reporters[who] = true
        p.rc = p.rc + 1
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
            Import(mapID, p)
            Debug(("imported %s in %d (%s)"):format(id, mapID, trusted and "trusted" or (p.rc .. " reports")))
        end
    end
end

local function OnNodes(body, sender, trusted, dry)
    local parts = { strsplit(";", body) }
    local mapID = tonumber(parts[1])
    if not mapID or not C_Map.GetMapInfo(mapID) then return end
    if not RateOK(sender, #parts - 1) then
        Debug("rate limit hit by " .. sender)
        return
    end
    -- Someone answered a zone query: we may not need to answer ourselves
    if answering[mapID] then
        answering[mapID].responders[sender] = true
    end
    for i = 2, #parts do
        HandleNode(mapID, parts[i], sender, trusted, dry)
    end
end

-- Nodes we can tell a newcomer about: our own harvests plus nodes that
-- reached us through sync and were confirmed (trusted or several reporters)
local function OwnNodes(mapID)
    local own = {}
    for _, n in ipairs(ns.db.nodes[mapID] or {}) do
        local ok = Shareable(n, mapID) or (n.source == "sync" and n.id and n.id:match("^o%d+$") and n.type
            and not (ns.IsKnownSpawn and ns.IsKnownSpawn(mapID, n.id, n.x, n.y)))
        if ok then own[#own + 1] = n end
    end
    return own
end

local function OnQuery(body, sender, distribution)
    local mapID, theirCount = body:match("^(%d+):?(%d*)$")
    mapID, theirCount = tonumber(mapID), tonumber(theirCount) or 0
    if not mapID or answering[mapID] then return end
    local own = OwnNodes(mapID)
    -- Only answer if we can add something
    if #own <= theirCount then return end
    if Busy() then return end
    -- Wait a random moment; if enough others answer first, stay quiet
    answering[mapID] = { responders = {} }
    C_Timer.After(2 + math.random() * 6, function()
        local a = answering[mapID]
        answering[mapID] = nil
        local count = 0
        for _ in pairs(a.responders) do count = count + 1 end
        if count >= MAX_RESPONDERS then return end
        SendNodes(mapID, own, { distribution == "GUILD" and "GUILD" or "CHANNEL" })
        Debug(("answered zone %d with %d nodes (they knew %d)"):format(mapID, #own, theirCount))
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
    if prefix ~= PREFIX or not DB().enabled then return end
    if not dry then
        Debug(("recv [%s] %s: %s"):format(distribution, sender, text:sub(1, 60)))
        if IsSelf(sender) then return end
    end
    if DB().blocked[ShortName(sender)] then return end
    if distribution == "CHANNEL" and not DB().public then return end
    if not WithinBudget() then return end

    if not dry then
        stats.received = stats.received + 1
        stats.peers[ShortName(sender)] = time()
    end

    local kind, body = text:match("^(%u):(.*)$")
    if kind == "N" then
        OnNodes(body, sender, not dry and IsTrusted(sender, distribution), dry)
    elseif kind == "Q" and not dry then
        OnQuery(body, sender, distribution)
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
    local mapID = C_Map.GetBestMapForUnit("player") or 1412
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
end

local function LeaveChannel()
    if GetChannelName(CHANNEL) and GetChannelName(CHANNEL) > 0 then
        LeaveChannelByName(CHANNEL)
    end
    channelID = nil
end

local function CurrentZoneQuery()
    local mapID = C_Map.GetBestMapForUnit("player")
    QueryZone(mapID)
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
    local peers, now = 0, time()
    for _, t in pairs(stats.peers) do
        if now - t < 3600 then peers = peers + 1 end
    end
    ns.Print(("Sync %s, public channel %s (%s), guild %s."):format(
        DB().enabled and "|cff00ff00ON|r" or "|cffff0000OFF|r",
        DB().public and "on" or "off",
        (channelID and channelID > 0) and ("#" .. channelID) or "not joined",
        IsInGuild() and "yes" or "no"))
    print(("  Players seen (1h): %d   Messages received: %d   Incoming: %.1f/s"):format(
        peers, stats.received, incomingRate))
    print(("  Imported this session: %d   Waiting for confirmation: %d"):format(stats.imported, CountPending()))
    print(("  Not sent (already known): %d   Not sent (busy): %d   Dropped (budget): %d"):format(
        stats.skippedKnown, stats.skippedBusy, stats.dropped))
    print(("  Confirmations needed: %d (guild and friends count instantly)"):format(CONFIRMATIONS))
end

local function Command(rest)
    local cmd, arg = (rest or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local db = DB()
    if cmd == "on" then
        db.enabled = true
        JoinChannel()
        ns.Print("Sync enabled.")
    elseif cmd == "off" then
        db.enabled = false
        LeaveChannel()
        ns.Print("Sync disabled.")
    elseif cmd == "public" then
        db.public = not db.public
        if db.public then JoinChannel() else LeaveChannel() end
        ns.Print("Public sync " .. (db.public and "on" or "off (guild and friends only)") .. ".")
    elseif cmd == "block" and arg ~= "" then
        db.blocked[arg] = true
        ns.Print("Ignoring sync data from " .. arg .. ".")
    elseif cmd == "unblock" and arg ~= "" then
        db.blocked[arg] = nil
        ns.Print("No longer ignoring " .. arg .. ".")
    elseif cmd == "ask" then
        lastQuery = {}
        CurrentZoneQuery()
        ns.Print("Asked other players for nodes in this zone.")
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

        -- Drop old unconfirmed reports
        for mapID, list in pairs(s.pending) do
            for i = #list, 1, -1 do
                if time() - (list[i].first or 0) > PENDING_MAX_AGE then
                    table.remove(list, i)
                end
            end
            if #list == 0 then s.pending[mapID] = nil end
        end

        playerName = UnitName("player") .. "-" .. (GetNormalizedRealmName() or "")
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        C_Timer.NewTicker(SEND_INTERVAL, SendNext)
        C_Timer.After(JOIN_DELAY, function()
            JoinChannel()
            C_Timer.After(2, CurrentZoneQuery)
        end)
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, distribution, sender = ...
        Receive(prefix, text, distribution, sender, false)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if ns.db and ns.db.sync then
            C_Timer.After(3, CurrentZoneQuery)
        end
    end
end)

ns.SyncShare = ShareHarvest
ns.SyncCommand = Command
