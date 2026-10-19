local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Sync: share harvested nodes with other WoWFFarm users
--
--   Transport : invisible addon messages (never shown in chat)
--               * public channel "WoWFFarmSync" (everyone on the megaserver)
--               * guild channel (trusted)
--   Trust     : nodes from guild members and friends are used right away.
--               Everyone else: a node is used once CONFIRMATIONS different
--               players reported it. Single reports wait in "pending".
--   Safety    : sender names come from the server and can't be faked,
--               strict message validation, rate limit per sender, blocklist.
--   Language  : nodes are identified by object ID, names are never sent.
--
--   Messages (prefix "WoWFFarm"):
--     N:<mapID>;<id>,<h|o>,<x>,<y>,<item>;...   nodes (x/y = 0..10000)
--     Q:<mapID>                                  "who has nodes for this zone?"
---------------------------------------------------------------------------
local PREFIX = "WoWFFarm"
local CHANNEL = "WoWFFarmSync"
local CONFIRMATIONS = 2       -- different players needed for a public node
local MERGE_RADIUS = 10       -- yards: same kind closer than this = same node
local SEND_INTERVAL = 1.2     -- seconds between outgoing messages
local MAX_MSG_LEN = 240
local RATE_WINDOW = 60        -- seconds
local RATE_MAX_NODES = 150    -- max nodes accepted per sender per window
local QUERY_COOLDOWN = 600    -- seconds before asking for the same zone again
local PENDING_MAX_AGE = 14 * 24 * 3600
local JOIN_DELAY = 8          -- seconds after login (let General/Trade join first)

local TYPE_CODE = { herb = "h", ore = "o" }
local CODE_TYPE = { h = "herb", o = "ore" }

local queue = {}              -- outgoing messages { text, target }
local channelID
local rate = {}               -- sender -> { start, count }
local lastQuery = {}          -- mapID -> time
local answering = {}          -- mapID -> { responders = {}, timerSet }
local stats = { received = 0, imported = 0, peers = {} }
local importPending = false

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

local function Shareable(n)
    -- Only nodes we harvested ourselves (real game object), never re-share imports
    return n.id and n.id:match("^o%d+$") and n.type and n.source ~= "sync"
end

-- Called by the recorder after every harvest
local function ShareHarvest(mapID, node)
    if not DB().enabled or not Shareable(node) then return end
    SendNodes(mapID, { node }, Targets())
end

local function QueryZone(mapID)
    if not DB().enabled or not mapID then return end
    if time() - (lastQuery[mapID] or 0) < QUERY_COOLDOWN then return end
    lastQuery[mapID] = time()
    for _, t in ipairs(Targets()) do Enqueue("Q:" .. mapID, t) end
    Debug("asked for zone " .. mapID)
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
    for _, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            if n.id == id and n.source ~= "sync" then return n.name end
        end
    end
    local name = item and item > 0 and C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(item)
    return name or (nodeType == "herb" and "Unknown Herb" or "Unknown Ore")
end

local function ScheduleNotify()
    if importPending then return end
    importPending = true
    C_Timer.After(1, function()
        importPending = false
        ns.NotifyNodesChanged()
    end)
end

local function Import(mapID, p)
    ns.db.nodes[mapID] = ns.db.nodes[mapID] or {}
    table.insert(ns.db.nodes[mapID], {
        id = p.id, name = DisplayName(p.id, p.item, p.type), type = p.type,
        x = p.x, y = p.y, count = p.rc or 1, last = time(),
        item = p.item > 0 and p.item or nil, source = "sync",
    })
    stats.imported = stats.imported + 1
    ScheduleNotify()
end

local function HandleNode(mapID, entry, sender, trusted)
    local id, code, xs, ys, items = strsplit(",", entry)
    local x, y, item = tonumber(xs), tonumber(ys), tonumber(items) or 0
    local nodeType = CODE_TYPE[code or ""]
    -- Validation: only real game objects, valid type and coordinates
    if not (id and id:match("^o%d+$") and nodeType and x and y) then return end
    if x < 0 or x > 10000 or y < 0 or y > 10000 then return end
    x, y = x / 10000, y / 10000

    -- Already known (own or imported): nothing to do
    if FindNear(ns.db.nodes[mapID], id, mapID, x, y) then return end

    -- Pending confirmations
    local pending = DB().pending
    pending[mapID] = pending[mapID] or {}
    local p = FindNear(pending[mapID], id, mapID, x, y)
    if not p then
        p = { id = id, type = nodeType, x = x, y = y, item = item, reporters = {}, rc = 0, first = time() }
        table.insert(pending[mapID], p)
    end
    local who = ShortName(sender)
    if not p.reporters[who] then
        p.reporters[who] = true
        p.rc = p.rc + 1
    end

    if trusted or p.rc >= CONFIRMATIONS then
        for i, q in ipairs(pending[mapID]) do
            if q == p then
                table.remove(pending[mapID], i)
                break
            end
        end
        Import(mapID, p)
        Debug(("imported %s in %d (%s)"):format(id, mapID, trusted and "trusted" or (p.rc .. " reports")))
    end
end

local function OnNodes(body, sender, trusted)
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
        HandleNode(mapID, parts[i], sender, trusted)
    end
end

local function OwnNodes(mapID)
    local own = {}
    for _, n in ipairs(ns.db.nodes[mapID] or {}) do
        if Shareable(n) then own[#own + 1] = n end
    end
    return own
end

local function OnQuery(body, sender, distribution)
    local mapID = tonumber(body)
    if not mapID or answering[mapID] then return end
    local own = OwnNodes(mapID)
    if #own == 0 then return end
    -- Wait a random moment; if 3 others answer first, stay quiet
    answering[mapID] = { responders = {} }
    C_Timer.After(2 + math.random() * 6, function()
        local a = answering[mapID]
        answering[mapID] = nil
        local count = 0
        for _ in pairs(a.responders) do count = count + 1 end
        if count >= 3 then return end
        SendNodes(mapID, own, { distribution == "GUILD" and "GUILD" or "CHANNEL" })
        Debug(("answered zone %d with %d nodes"):format(mapID, #own))
    end)
end

local function OnAddonMessage(prefix, text, distribution, sender)
    if prefix ~= PREFIX or not DB().enabled then return end
    Debug(("recv [%s] %s: %s"):format(distribution, sender, text:sub(1, 60)))
    if IsSelf(sender) then return end
    if DB().blocked[ShortName(sender)] then return end
    if distribution == "CHANNEL" and not DB().public then return end

    stats.received = stats.received + 1
    stats.peers[ShortName(sender)] = time()

    local kind, body = text:match("^(%u):(.*)$")
    if kind == "N" then
        OnNodes(body, sender, IsTrusted(sender, distribution))
    elseif kind == "Q" then
        OnQuery(body, sender, distribution)
    end
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
-- Commands: /fg sync [on|off|public|block <name>|unblock <name>]
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
    print(("  Players seen (1h): %d   Messages received: %d"):format(peers, stats.received))
    print(("  Imported this session: %d   Waiting for confirmation: %d"):format(stats.imported, CountPending()))
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
    else
        Status()
        print("  /fg sync on|off  |  public  |  ask  |  block <name>  |  unblock <name>")
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
        OnAddonMessage(...)
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if ns.db and ns.db.sync then
            C_Timer.After(3, CurrentZoneQuery)
        end
    end
end)

ns.SyncShare = ShareHarvest
ns.SyncCommand = Command
