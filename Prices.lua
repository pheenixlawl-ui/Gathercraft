local ADDON_NAME, ns = ...
local Wrap = ns.PerfWrap or function(_, fn) return fn end -- (/gcr perf on, Perf.lua: measured only while it is on)
local C_Timer = (C_Timer and ns.PerfTimers) and ns.PerfTimers("Prices") or C_Timer -- (/gcr perf on: every timer of this file)
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Prices: what the things you gather (and craft) are worth
--   1. Our own auction house data: the full scan (button at the auction
--      house, /gcr scan) plus every search you do there (any addon's)
--   2. Fallback while there is no scan yet: Auctionator, TSM or the shared
--      GetAuctionBuyout of other auction addons. Auctionator also wins over
--      our own price once that is older than FRESH_PRICE, if it is fresher.
--   3. The vendor price, which every client knows
--   Prices are stored per realm and faction and never shared with anyone.
---------------------------------------------------------------------------
local CALLER = ADDON_NAME
local SCAN_COOLDOWN = 15 * 60   -- the server allows one full scan per 15 minutes
local SCAN_TIMEOUT = 90         -- seconds to wait for the server's answer
local SCAN_CHUNK = 1500         -- auctions read per step at most (keeps the game smooth)
-- ... and a step ends after this many milliseconds (v0.1.23 P5: the scan
-- starts by itself now, and Sven's auction house had 313,401 auctions - a
-- step of 1500 is too long on a slow machine). Looked at every SCAN_LOOK
-- auctions. The prices at the end are worked out in steps of the same
-- length: there the clock is looked at after every item and every
-- PRICE_LOOK offers within one item (one item can have tens of thousands).
local SCAN_STEP_MS = 8
local SCAN_LOOK = 50
local PRICE_LOOK = 256
local FRESH_PRICE = 6 * 3600    -- older own prices count as old: Auctionator goes first
local MAX_PRICE_AGE = 7 * 86400 -- older own prices: use the fallbacks instead
local HISTORY_DAYS = 14
local MARKET_MIN = 5            -- market price: the lowest price with this many items behind it ...
local MARKET_SHARE = 0.02       -- ... or this share of the stock, if that is more
local BROWSE_TRUST = 3600       -- a search result beats a browse "lowest price" for an hour
local ALERT_HIGH = 1.5          -- price alert: 50% above the usual price ...
local ALERT_MIN_GAIN = 50       -- ... and at least 50 copper more per item
local ALERT_MIN_DAYS = 3        -- days of history before we know what "usual" is

local function RealmKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or GetRealmName() or "?"
    return realm .. "-" .. (UnitFactionGroup and UnitFactionGroup("player") or "?")
end

local function PriceDB()
    if not ns.db then return end
    ns.db.prices = ns.db.prices or {}
    local key = RealmKey()
    local p = ns.db.prices[key]
    if not p then
        p = { items = {}, qty = {}, history = {}, scanned = 0 }
        ns.db.prices[key] = p
    end
    p.seen = p.seen or {} -- itemID -> when its price was last updated
    -- what kind of price it is and whether p.qty belongs to this very price
    -- (0.2 B2), one number an item - see MARKET and LOWEST below. Entries
    -- from before have none: their kind is not known, their quantity is not
    -- shown.
    p.meta = p.meta or {}
    return p
end

-- p.meta: 1 = market price (a scan or a search, with stock behind it) with
-- its quantity, 2 = market price without, 3 = lowest offer (the cheapest of
-- a browse list) with its quantity, 4 = lowest offer without
local MARKET, LOWEST, NO_QTY = 1, 3, 1
local META_KIND = { "market", "market", "lowest", "lowest" }
local META_QTY = { true, false, true, false }

local function PriceAge(p, itemID)
    return time() - (p.seen[itemID] or p.scanned or 0)
end

local function ScanPrice(itemID)
    local p = PriceDB()
    if p and p.items[itemID] and PriceAge(p, itemID) < MAX_PRICE_AGE then
        return p.items[itemID]
    end
end

local function Positive(ok, value)
    if ok and type(value) == "number" and value > 0 then return value end
end

local function AuctionatorPrice(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.GetAuctionPriceByItemID then
        return Positive(pcall(api.GetAuctionPriceByItemID, CALLER, itemID))
    end
end

-- How old Auctionator's price is, in seconds. It counts in days and knows
-- nothing older than 21: math.huge then, nil if it can't tell at all.
local function AuctionatorAge(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionAgeByItemID) then return end
    local ok, days = pcall(api.GetAuctionAgeByItemID, CALLER, itemID)
    if not ok then return end
    return type(days) == "number" and days * 86400 or math.huge
end

local function TSMPrice(itemID)
    if TSM_API and TSM_API.GetCustomPriceValue then
        return Positive(pcall(TSM_API.GetCustomPriceValue, "dbmarket", "i:" .. itemID))
    end
end

local function SharedPrice(itemID)
    if GetAuctionBuyout then
        return Positive(pcall(GetAuctionBuyout, itemID))
    end
end

local function VendorPrice(itemID)
    local sell
    if C_Item and C_Item.GetItemInfo then
        sell = select(11, C_Item.GetItemInfo(itemID))
    end
    ---@diagnostic disable-next-line: deprecated -- fallback for clients without the C_ version
    if not sell and GetItemInfo then
        ---@diagnostic disable-next-line: deprecated
        sell = select(11, GetItemInfo(itemID))
    end
    if type(sell) == "number" and sell > 0 then return sell end
    -- not in the item cache yet: ask the server, it's there next time
    if sell == nil and C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

local SOURCES = {
    { name = "AH scan", get = ScanPrice },
    { name = "Auctionator", get = AuctionatorPrice },
    { name = "TSM", get = TSMPrice },
    { name = "auction", get = SharedPrice },
    { name = "vendor", get = VendorPrice },
}

-- Price of one item in copper and where it came from, or nil
local function GetPrice(itemID)
    if not itemID then return end
    local own = ScanPrice(itemID)
    if own then
        local age = PriceAge(PriceDB(), itemID)
        local other = age >= FRESH_PRICE and AuctionatorPrice(itemID)
        if other and (AuctionatorAge(itemID) or 0) < age then return other, "Auctionator" end
        return own, "AH scan"
    end
    for _, s in ipairs(SOURCES) do
        local p = s.get(itemID)
        if p then return p, s.name end
    end
end

-- Of two sources the one to name: "vendor" only if nothing better was involved
local function BetterSource(a, b)
    if not (a and b) then return a or b end
    for _, s in ipairs(SOURCES) do
        if s.name == a or s.name == b then return s.name end
    end
end

-- "12g 34s", "34s 5c", "5c"
local function Money(copper, short)
    local G, S, C = L["|cffffd700g|r"], L["|cffc7c7cfs|r"], L["|cffeda55fc|r"]
    copper = math.floor((copper or 0) + 0.5)
    if copper < 0 then return "-" .. Money(-copper, short) end
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if g > 0 then
        if short or g >= 100 or s == 0 then return g .. G end
        return ("%d%s %d%s"):format(g, G, s, S)
    elseif s > 0 then
        if short or c == 0 then return s .. S end
        return ("%d%s %d%s"):format(s, S, c, C)
    end
    return c .. C
end

---------------------------------------------------------------------------
-- Value of every gather (all loot slots of the node)
---------------------------------------------------------------------------
local session = { value = 0, start = GetTime(), sources = {} }

table.insert(ns.gatherListeners, Wrap("Prices", function(node, p)
    local value, source, missing = 0, nil, 0
    for _, it in ipairs(p and p.items or {}) do
        local price, from = GetPrice(it.id)
        if price then
            value = value + price * (it.qty or 1)
            source = BetterSource(source, from)
        else
            missing = missing + 1 -- (0.2.3 P3: the run history says how much it could not price)
        end
    end
    if p then
        p.value, p.valueSource, p.valueMissing = value, source, missing
    end
    session.value = session.value + value
    if source then session.sources[source] = true end
end))

-- Value of a list of loot { {id, qty}, ... } -> copper, best source
local function LootValue(items)
    local value, source = 0, nil
    for _, it in ipairs(items or {}) do
        local price, from = GetPrice(it.id)
        if price then
            value = value + price * (it.qty or 1)
            source = BetterSource(source, from)
        end
    end
    return value, source
end

-- Other income of this session (fishing) counts into "Worth" too
local function AddSessionValue(value, source)
    session.value = session.value + (value or 0)
    if source then session.sources[source] = true end
end

-- Best source used this session (for the labels)
local function SessionSource()
    for _, s in ipairs(SOURCES) do
        if session.sources[s.name] then return s.name end
    end
end

---------------------------------------------------------------------------
-- Our own auction house scan
--   One full scan (ReplicateItems) returns every auction at once. We read it
--   in small steps and keep per item a market price (the cheapest offer with
--   real stock behind it, so a single bait item doesn't fool us) and a short
--   history.
---------------------------------------------------------------------------
local AH = C_AuctionHouse
local ahOpen = false
local scan -- running scan: { state, started, index, total, acc, noItem, noCount, noBuyout }
-- the scan timed out: its answer still counts while the window is open.
-- "auto" when that scan had started by itself, "asked" after a click
-- or /gcr scan (R1-N1): the scan that reads the late answer is the same
-- kind, so a quiet one stays quiet
local lateAnswer = false
local scanButton

local function Cooldown()
    local p = PriceDB()
    local left = SCAN_COOLDOWN - (time() - (p and p.lastScanStart or 0))
    return left > 0 and left or 0
end

local function SetButton(text, enabled)
    if scanButton.label ~= text then
        scanButton.label = text
        scanButton:SetText(text)
        if scanButton.isTab and PanelTemplates_TabResize then
            pcall(PanelTemplates_TabResize, scanButton, 0, nil, 130)
        end
    end
    if scanButton.isTab then
        -- Blizzard draws a disabled tab like the selected one (golden), so the
        -- tab always stays clickable; while waiting it just looks dimmed and a
        -- click tells you how long to wait
        local fs = scanButton:GetFontString()
        if fs then
            if enabled then fs:SetTextColor(1, 0.82, 0) else fs:SetTextColor(0.5, 0.5, 0.5) end
        end
        if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, scanButton) end
    elseif enabled then
        scanButton:Enable()
    else
        scanButton:Disable()
    end
end

local function UpdateButton()
    if not scanButton then return end
    local left = Cooldown()
    if scan then
        SetButton(L["Scanning..."], false)
    elseif left > 0 then
        SetButton((L["Gathercraft %d:%02d"]):format(math.floor(left / 60), left % 60), false)
    else
        SetButton("Gathercraft Scan", true)
    end
end

-- a[1..n], numbers, in rising order - returns the table that has them (a or
-- one of its own). With pause, a long list is sorted by merging, and pause()
-- is called every PRICE_LOOK numbers: the full scan works out its prices in
-- a coroutine and rests there when its step is over.
local function Sorted(a, n, pause)
    if not pause or n <= 64 then
        table.sort(a)
        return a
    end
    local src, dst, width = a, {}, 1
    while width < n do
        for lo = 1, n, 2 * width do
            local mid, hi = math.min(lo + width, n + 1), math.min(lo + 2 * width, n + 1)
            local i, j = lo, mid
            for k = lo, hi - 1 do
                if i < mid and (j >= hi or not (src[j] < src[i])) then
                    dst[k] = src[i]
                    i = i + 1
                else
                    dst[k] = src[j]
                    j = j + 1
                end
                if k % PRICE_LOOK == 0 then pause() end
            end
        end
        src, dst, width = dst, src, width * 2
    end
    return src
end

-- The market price: the lowest unit price that has MARKET_MIN items (or
-- MARKET_SHARE of the stock, if that is more) at or below it; and the stock.
-- The offers are put together by their unit price first, and only the
-- different prices are sorted: the answer is the same as from sorting every
-- offer (offers of one price lie side by side there, and the answer is a
-- price), with far less work where many offers share few prices.
-- pause (optional): see Sorted.
local function MarketPrice(list, pause)
    -- list = { unitPrice, count, unitPrice, count, ... }
    local stock, prices, n, total = {}, {}, 0, 0
    for i = 1, #list, 2 do
        local price, count = list[i], list[i + 1]
        local had = stock[price]
        if had then
            stock[price] = had + count
        else
            n = n + 1
            prices[n] = price
            stock[price] = count
        end
        total = total + count
        if pause and (i + 1) % (2 * PRICE_LOOK) == 0 then pause() end
    end
    prices = Sorted(prices, n, pause)
    -- with less stock than that, what is there counts: the loop runs out
    local want, seen = math.max(MARKET_MIN, total * MARKET_SHARE), 0
    for i = 1, n do
        seen = seen + stock[prices[i]]
        if seen >= want then return math.floor(prices[i] + 0.5), total end
        if pause and i % PRICE_LOOK == 0 then pause() end
    end
    return math.floor(prices[n] + 0.5), total
end

local TRADE_GOODS = 7 -- item class "Tradeskill"
local function IsTradeGood(itemID)
    if not (C_Item and C_Item.GetItemInfoInstant) then return true end
    local classID = select(6, C_Item.GetItemInfoInstant(itemID))
    return classID == nil or classID == TRADE_GOODS
end

-- history: "day:price;day:price;..." (one value per day, newest last), only
-- for trade goods (herbs, ores, cloth, ...): that's what the price alerts
-- watch, and it keeps the SavedVariables small
-- the history of an item with today's price in it, or nil for none
local function HistoryWith(p, itemID, price)
    if not IsTradeGood(itemID) then return nil end
    local day = math.floor(time() / 86400)
    local kept = {}
    for d, v in (p.history[itemID] or ""):gmatch("(%d+):(%d+)") do
        if tonumber(d) ~= day and tonumber(d) > day - HISTORY_DAYS then kept[#kept + 1] = d .. ":" .. v end
    end
    kept[#kept + 1] = day .. ":" .. price
    return table.concat(kept, ";")
end

local function AddHistory(p, itemID, price)
    p.history[itemID] = HistoryWith(p, itemID, price)
end

local CheckAlerts -- price alerts, further down

-- Counts up with every price written (wherever AddHistory runs): what was
-- worked out from prices and their history is good for one revision
local priceRev = 0

-- A quantity that can be shown: a number, not negative, not endless
local function ValidQty(qty)
    return type(qty) == "number" and qty >= 0 and qty < math.huge
end

-- One item's price from a search or browse result (kind: MARKET or LOWEST).
-- Price, time and the number that says what kind of price it is and whether
-- it has a quantity are set in one go: a price without a quantity of its own
-- (qty = nil) has none - the number of the price before may stay in p.qty,
-- but it is not this price's and is never shown with it. (No comparing of
-- times: two looks in the same second are two looks.)
local function StorePrice(itemID, price, qty, kind)
    local p = PriceDB()
    if not (p and itemID and price and price > 0) then return end
    local has = ValidQty(qty)
    if has then p.qty[itemID] = qty end
    p.items[itemID], p.seen[itemID], p.meta[itemID] = math.floor(price + 0.5), time(), has and kind or kind + NO_QTY
    AddHistory(p, itemID, p.items[itemID])
    priceRev = priceRev + 1
end

-- "left out" comes for every list update the game sends: over a hundred
-- times in one scan (Sven's log, 07.11.). The first one of a kind is shown,
-- the rest counted and named once when the scan ends or the window closes.
local ignored = { n = 0 }
local function FlushIgnored()
    if ignored.n > 0 then
        ns.Debug(("SCAN REPLICATE_ITEM_LIST_UPDATE left out: %d further updates ignored (%s)"):format(ignored.n, ignored.why))
    end
    ignored.n, ignored.why = 0, nil
end
local function LeftOut(why)
    if ignored.why == why then
        ignored.n = ignored.n + 1
        return
    end
    FlushIgnored()
    ignored.why = why
    ns.Debug("SCAN REPLICATE_ITEM_LIST_UPDATE left out: " .. why)
end

-- A scan without a result: the prices stay, and the 15 minutes count from the
-- start. Nobody knows when the server would take the next one, so we wait.
-- A scan that started by itself (see StartScan) fails without a word in
-- chat: you did not ask for it. The debug tab has the line.
local function ScanFailed(message)
    FlushIgnored()
    local quiet = scan and scan.auto
    scan = nil
    if quiet then
        ns.Debug("SCAN (started on opening) without a result, not said in chat: " .. tostring(message))
    else
        ns.Print(message)
        local left = Cooldown()
        ns.Print((L["Your prices stay as they are. Next scan in %d:%02d."]):format(math.floor(left / 60), left % 60))
    end
    UpdateButton()
end

-- Every auction is read: a market price and the history for each item, in
-- steps (20,000 items in one go would hold the game for a moment), then
-- everything is put in place at once. Nothing is stored before that: a
-- scan that ends half way leaves the prices as they were.
-- (R1-M1) The time of a step is what counts, not the number of items: one
-- item with 48,000 offers is more work than 5,000 items with three. So the
-- prices are worked out in a coroutine that rests whenever the step it runs
-- in has had its SCAN_STEP_MS - after any item, and inside a long one.
-- stepStart: when the step that is running began (a step = one call from
-- the game: the event with the list, or a timer of ours).
local FinishScan
local stepStart = 0
local function Rest()
    if debugprofilestop() - stepStart >= SCAN_STEP_MS then coroutine.yield() end
end
local function PriceAll(mine)
    local p = PriceDB()
    for itemID, list in pairs(mine.acc) do
        local price, total = MarketPrice(list, Rest)
        mine.items[itemID], mine.qty[itemID] = price, total
        mine.hist[itemID] = HistoryWith(p, itemID, price) or false
        mine.count = mine.count + 1
        Rest()
    end
    -- putting the prices in place is work of its own: not at the end of a
    -- step that is half over already
    if debugprofilestop() - stepStart >= SCAN_STEP_MS / 2 then coroutine.yield() end
end
-- sameStep: called at the end of the last reading step - the time that step
-- has used counts (is it over, the prices start in the next one)
local function PriceStep(sameStep)
    if not scan or scan.state ~= "pricing" then return end
    if sameStep ~= true then stepStart = debugprofilestop() end
    local mine = scan
    mine.pricing = mine.pricing or coroutine.create(PriceAll)
    local ok, err = coroutine.resume(mine.pricing, mine)
    if not ok then
        -- an error of ours: the scan is over (no prices stored), and the error is shown
        FlushIgnored()
        scan = nil
        UpdateButton()
        error("Gathercraft scan: " .. tostring(err), 0)
    elseif coroutine.status(mine.pricing) == "dead" then
        FinishScan()
    else
        C_Timer.After(0, PriceStep)
    end
end

FinishScan = function()
    local p = PriceDB()
    local items, qty, seen = scan.items, scan.qty, {}
    local count, now = scan.count, time()
    for itemID in pairs(items) do seen[itemID] = now end
    ns.Debug(("SCAN read %d of %d: %d items, skipped %d without itemID, %d with count 0, %d with buyout 0, %d could not be read"):format(
        scan.index, scan.total, count, scan.noItem, scan.noCount, scan.noBuyout, scan.readErrors))
    if count == 0 then
        ScanFailed(L["The auction house sent no auctions. Try again in a moment."])
        return
    end
    for itemID, text in pairs(scan.hist) do p.history[itemID] = text or nil end
    priceRev = priceRev + 1
    if scan.readErrors > 0 then
        -- some auctions could not be read (R4-B2): this is no full picture.
        -- The prices read are real and replace the old ones of their items;
        -- every other price stays, and it does not count as a full scan.
        for itemID, price in pairs(items) do
            p.items[itemID], p.qty[itemID], p.seen[itemID], p.meta[itemID] = price, qty[itemID], now, MARKET
        end
        ns.Print((L["Scan incomplete: %d auctions could not be read, old prices kept (%d updated)."]):format(scan.readErrors, count))
        FlushIgnored()
        scan = nil
        UpdateButton()
        if CheckAlerts then CheckAlerts() end
        return
    end
    -- a full scan shows everything: items no longer listed have no price now
    local meta = {}
    for itemID in pairs(items) do meta[itemID] = MARKET end
    p.items, p.qty, p.seen, p.meta, p.scanned = items, qty, seen, meta, now
    ns.Print((L["Auction house scanned: %d auctions, prices for %d items."]):format(scan.total, count))
    FlushIgnored()
    scan = nil
    UpdateButton()
    if CheckAlerts then CheckAlerts() end
end

-- read = false when the game could not give this auction at all (an error,
-- or no answer): a technical gap, not an auction without a price
-- (the answer of the game is not put into a table: one table for each of
-- 300,000 auctions is a lot to clear away - v0.1.23 P5)
local function Picked(ok, ...)
    if not ok or select("#", ...) == 0 then return false end
    local name, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = ...
    return true, itemID, count, buyout, name
end
local function ReadInfo(index)
    return Picked(pcall(AH.GetReplicateItemInfo, index))
end

local function ReadStep()
    if not scan or scan.state ~= "reading" then return end
    local last = math.min(scan.index + SCAN_CHUNK, scan.total) - 1
    local t0 = debugprofilestop()
    stepStart = t0
    for i = scan.index, last do
        -- (a step ends when its time is up: the rest is read in the next one)
        if i > scan.index and (i - scan.index) % SCAN_LOOK == 0 and debugprofilestop() - t0 >= SCAN_STEP_MS then
            last = i - 1
            break
        end
        local read, itemID, count, buyout, name = ReadInfo(i + scan.base)
        if not read then
            scan.readErrors = scan.readErrors + 1
        elseif not itemID then
            scan.noItem = scan.noItem + 1
        elseif not (count and count > 0) then
            scan.noCount = scan.noCount + 1
        elseif not (buyout and buyout > 0) then
            scan.noBuyout = scan.noBuyout + 1
        else
            local list = scan.acc[itemID]
            if not list then
                list = {}
                scan.acc[itemID] = list
                if name and ns.NoteReagentName then ns.NoteReagentName(name, itemID) end
            end
            list[#list + 1] = buyout / count
            list[#list + 1] = count
        end
    end
    scan.index = last + 1
    ns.Debug(("SCAN step: %d of %d read"):format(scan.index, scan.total))
    if scan.index >= scan.total then
        -- all read: from here on the auction house is not needed any more
        scan.state, scan.items, scan.qty, scan.hist, scan.count = "pricing", {}, {}, {}, 0
        PriceStep(true)
    else
        C_Timer.After(0, ReadStep)
    end
end

local function NewScan()
    return { state = "waiting", started = GetTime(), acc = {}, noItem = 0, noCount = 0, noBuyout = 0, readErrors = 0 }
end

local function OnReplicateReady()
    -- the answer came after we gave up: it is still the whole auction house
    if not scan and lateAnswer and ahOpen then
        ns.Debug("SCAN the answer came after the timeout, reading it")
        scan = NewScan()
        scan.auto = lateAnswer == "auto" or nil
    end
    lateAnswer = false
    if not scan or scan.state ~= "waiting" then
        LeftOut(scan and "already reading" or "no scan of ours (another addon?)")
        return
    end
    scan.state = "reading"
    scan.total = AH.GetNumReplicateItems and AH.GetNumReplicateItems() or 0
    -- the list starts at 0 on the modern auction house; fall back to 1
    scan.base = ReadInfo(0) and 0 or 1
    scan.index = 0
    ns.Debug(("SCAN REPLICATE_ITEM_LIST_UPDATE after %.1f s: %d auctions, first index %d"):format(
        GetTime() - scan.started, scan.total, scan.base))
    if scan.total == 0 then
        ScanFailed(L["The auction house sent no auctions. Try again in a moment."])
        return
    end
    ReadStep()
end

-- auto (v0.1.23 P5): started by the window opening, not by a click or
-- /gcr scan. Then nothing is said in chat when it cannot start, when no
-- answer comes (another addon may have used up the server's scan) or when
-- the window closes: the debug tab has those lines. The button shows what
-- is going on, and the result is said as after a click.
local function StartScan(auto)
    auto = auto == true -- (the button hands its frame over as the first argument)
    local function Say(text)
        if auto then
            ns.Debug("SCAN (on opening) not started, not said in chat: " .. tostring(text))
        else
            ns.Print(text)
        end
    end
    if not (AH and AH.ReplicateItems) then
        Say(L["This client has no full auction house scan."])
        return
    end
    if not ahOpen then
        Say(L["Open the auction house first."])
        return
    end
    if scan then
        Say(L["Scan is already running..."])
        return
    end
    local left = Cooldown()
    if left > 0 then
        Say((L["The server allows one full scan every 15 minutes. Next scan in %d:%02d."]):format(math.floor(left / 60), left % 60))
        return
    end
    FlushIgnored()
    local ok, err = pcall(AH.ReplicateItems)
    ns.Debug("SCAN ReplicateItems called" .. (auto and " (on opening): " or ": ") .. (ok and "ok" or tostring(err)))
    if not ok then
        Say(L["Scan failed: "] .. tostring(err))
        return
    end
    PriceDB().lastScanStart = time()
    scan, lateAnswer = NewScan(), false
    scan.auto = auto or nil
    if not auto then ns.Print(L["Scanning the auction house... (this takes a few seconds)"]) end
    UpdateButton()
    local mine = scan
    C_Timer.After(SCAN_TIMEOUT, function()
        if scan == mine and scan.state == "waiting" then
            ns.Debug(("SCAN timeout: no answer after %d s"):format(SCAN_TIMEOUT))
            lateAnswer = mine.auto and "auto" or "asked"
            ScanFailed(L["The auction house didn't answer. Try again later."])
        end
    end)
end

-- Options > Rares & prices: "Scan the auction house automatically when I
-- open it", on unless turned off
local function AutoScanOn()
    return ns.db ~= nil and not ns.db.autoScanOff
end

-- Our button looks like the other tabs at the bottom of the auction house
-- (Buy, Sell, ... and tabs of other addons) and always sits after the last
-- one, however many there are. We never put it into the frame's tab list,
-- so no other addon anchors its tabs to ours.
local function DependsOnUs(frame, depth)
    if not frame or (depth or 0) > 15 then return false end
    if frame == scanButton then return true end
    for i = 1, (frame.GetNumPoints and frame:GetNumPoints() or 0) do
        local _, rel = frame:GetPoint(i)
        if rel and rel ~= frame and DependsOnUs(rel, (depth or 0) + 1) then return true end
    end
    return false
end

local function LastTab(parent)
    local best, bestRight
    local bottom = parent:GetBottom()
    if not bottom then return end
    local function consider(child)
        if child == scanButton or not child.IsShown or not child:IsShown() then return end
        if not (child.GetText and child:GetText()) then return end
        local top, right = child:GetTop(), child:GetRight()
        if not (top and right) or top > bottom + 10 or top < bottom - 45 then return end
        if (not bestRight or right > bestRight) and not DependsOnUs(child) then
            best, bestRight = child, right
        end
    end
    if type(parent.Tabs) == "table" then
        for _, tab in ipairs(parent.Tabs) do consider(tab) end
    end
    for _, child in ipairs({ parent:GetChildren() }) do
        consider(child)
        for _, inner in ipairs({ child:GetChildren() }) do consider(inner) end
    end
    return best
end

local function PlaceButton()
    local parent = scanButton and scanButton:GetParent()
    if not parent then return end
    local last = LastTab(parent)
    if last == scanButton.anchor then return end
    scanButton.anchor = last
    scanButton:ClearAllPoints()
    if last then
        scanButton:SetPoint("TOPLEFT", last, "TOPRIGHT", 3, 0)
    else
        scanButton:SetPoint("TOPRIGHT", parent, "BOTTOMRIGHT", -4, 2)
    end
end

local function CreateScanButton()
    local parent = _G.AuctionHouseFrame or _G.AuctionFrame
    if scanButton or not parent then return end
    local ok, b = pcall(CreateFrame, "Button", "GathercraftScanButton", parent, "PanelTabButtonTemplate")
    if ok and b then
        scanButton = b
        scanButton.isTab = true
        if type(parent.Tabs) == "table" and tDeleteItem then tDeleteItem(parent.Tabs, scanButton) end
    else
        scanButton = CreateFrame("Button", "GathercraftScanButton", parent, "UIPanelButtonTemplate")
        scanButton:SetSize(150, 22)
    end
    PlaceButton()
    scanButton:SetScript("OnClick", StartScan)
    scanButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(L["Gathercraft price scan"])
        GameTooltip:AddLine(L["Reads every auction once and keeps a market price per item for gold per hour and profit."], 1, 1, 1, true)
        local p = PriceDB()
        if p and (p.scanned or 0) > 0 then
            GameTooltip:AddLine((L["Last scan: %d min ago"]):format(math.floor((time() - p.scanned) / 60)), 0.7, 0.7, 0.7)
        end
        local left = Cooldown()
        if left > 0 then
            GameTooltip:AddLine(L["The server allows one full scan every 15 minutes."], 1, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end)
    scanButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    scanButton:SetScript("OnUpdate", Wrap("Prices", function(self, elapsed)
        self.t = (self.t or 0) + elapsed
        if self.t > 1 then
            self.t = 0
            UpdateButton()
            PlaceButton() -- other addons may add tabs later
        end
    end))
end

---------------------------------------------------------------------------
-- Learning from every search at the auction house
--   Whatever you (or Auctionator, or any addon) look up at the auction house
--   updates our price for those items right away: no extra click, no
--   15 minute wait. Full search results give a market price; the browse
--   list only knows the lowest price, so it only fills gaps.
---------------------------------------------------------------------------
local learned = 0
local alertPending = false
local function Learned()
    learned = learned + 1
    if not alertPending and CheckAlerts then
        alertPending = true
        C_Timer.After(2, function()
            alertPending = false
            CheckAlerts()
        end)
    end
end

local function OnCommodityResults(itemID)
    if not (itemID and AH.GetNumCommoditySearchResults and AH.GetCommoditySearchResultInfo) then
        ns.Debug("AH commodity search: not stored, no itemID or no API")
        return
    end
    local list = {}
    for i = 1, AH.GetNumCommoditySearchResults(itemID) or 0 do
        local ok, r = pcall(AH.GetCommoditySearchResultInfo, itemID, i)
        if ok and r and r.unitPrice and r.quantity and r.quantity > 0 then
            list[#list + 1] = r.unitPrice
            list[#list + 1] = r.quantity
        end
    end
    if #list == 0 then
        ns.Debug(("AH commodity search %d: not stored, no results with a price"):format(itemID))
        return
    end
    local price, total = MarketPrice(list)
    local full = AH.HasFullCommoditySearchResults and AH.HasFullCommoditySearchResults(itemID)
    StorePrice(itemID, price, full and total or nil, MARKET)
    ns.Debug(("AH commodity search %d: %d results, stored %d (%d listed, %s)"):format(itemID, #list / 2, price, total, full and "all" or "not all yet"))
    Learned()
end

local function OnItemResults(itemKey)
    if not (itemKey and itemKey.itemID and AH.GetNumItemSearchResults and AH.GetItemSearchResultInfo) then
        ns.Debug("AH item search: not stored, no itemKey or no API")
        return
    end
    local list = {}
    for i = 1, AH.GetNumItemSearchResults(itemKey) or 0 do
        local ok, r = pcall(AH.GetItemSearchResultInfo, itemKey, i)
        local buyout = ok and r and r.buyoutAmount
        local count = ok and r and (r.quantity or 1)
        if buyout and buyout > 0 and count and count > 0 then
            list[#list + 1] = buyout / count
            list[#list + 1] = count
        end
    end
    if #list == 0 then
        ns.Debug(("AH item search %d: not stored, no results with a buyout"):format(itemKey.itemID))
        return
    end
    local price, total = MarketPrice(list)
    StorePrice(itemKey.itemID, price, total, MARKET)
    ns.Debug(("AH item search %d: %d results, stored %d (%d listed)"):format(itemKey.itemID, #list / 2, price, total))
    Learned()
end

local function OnBrowseResults(event)
    if not AH.GetBrowseResults then
        ns.Debug(event .. ": not stored, no API")
        return
    end
    local ok, results = pcall(AH.GetBrowseResults)
    if not ok or type(results) ~= "table" then
        ns.Debug(event .. ": not stored, no list")
        return
    end
    -- one item can stand here several times (gear with different bonuses)
    -- (the quantity is the sum over them; when one of them tells none, the
    -- item's quantity is not known - never 0)
    local lowest, quantity, unknown = {}, {}, {}
    for _, r in ipairs(results) do
        local id = r.itemKey and r.itemKey.itemID
        if id and r.minPrice and r.minPrice > 0 then
            lowest[id] = math.min(lowest[id] or r.minPrice, r.minPrice)
            if ValidQty(r.totalQuantity) then
                quantity[id] = (quantity[id] or 0) + r.totalQuantity
            else
                unknown[id] = true
            end
        end
    end
    local p = PriceDB()
    local stored, kept = 0, 0
    for id, price in pairs(lowest) do
        -- lowest price only: don't overwrite a fresh market price from a search
        if not p.items[id] or PriceAge(p, id) > BROWSE_TRUST then
            StorePrice(id, price, not unknown[id] and quantity[id] or nil, LOWEST)
            stored = stored + 1
        else
            kept = kept + 1
        end
    end
    ns.Debug(("%s: %d results, %d stored, %d left out (price younger than %d min)"):format(
        event, #results, stored, kept, BROWSE_TRUST / 60))
    if stored > 0 then Learned() end
end

local ahEvents = CreateFrame("Frame")
local missingEvents = {}
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED",
    "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE" }) do
    -- not every client knows every event: /gcr prices names the ones missing
    if not pcall(ahEvents.RegisterEvent, ahEvents, e) then missingEvents[#missingEvents + 1] = e end
end
ahEvents:SetScript("OnEvent", function(_, event, arg)
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        -- a moment later: other addons add their tabs when the window opens
        C_Timer.After(0.3, function()
            CreateScanButton()
            if scanButton then scanButton.anchor = false end
            PlaceButton()
            UpdateButton()
            -- (v0.1.23 P5) opening the window starts the scan - when the
            -- window is still open, no scan runs and the 15 minutes are over
            if ahOpen and AutoScanOn() and not scan and Cooldown() == 0 then StartScan(true) end
        end)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen, lateAnswer = false, false
        FlushIgnored()
        if scan and scan.state == "pricing" then
            -- every auction is read, only the prices are being worked out: that goes on
            ns.Debug("SCAN auction house closed, the auctions are all read: finishing")
        elseif scan then -- also while reading: what is left of the list is gone
            ns.Debug(("SCAN cancelled, auction house closed (%s)"):format(scan.state))
            ScanFailed(L["Auction house closed, scan cancelled."])
        end
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        OnReplicateReady()
    elseif not AH then
        return
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
        OnCommodityResults(arg)
    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
        OnItemResults(arg)
    elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
        ns.Debug(event .. ": the server sent no list")
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        OnBrowseResults(event)
    end
end)

-- (The price line in item tooltips lives in ItemTooltip.lua since 0.2: one
-- hook for everything Gathercraft shows there.)

-- Price history of an item: { {day, price}, ... } oldest first
local function PriceHistory(itemID)
    local p = PriceDB()
    local out = {}
    for d, v in ((p and p.history[itemID]) or ""):gmatch("(%d+):(%d+)") do
        out[#out + 1] = { tonumber(d), tonumber(v) }
    end
    return out
end

-- The same, but only the days that count today: today and the 13 days
-- before it (UTC days, as the history is written). The history is only
-- thinned out when a price is written - without a scan for weeks it still
-- holds days long gone, and those are not "the last 14 days" (0.2 B2).
local function PriceHistoryWindow(itemID, today)
    today = today or math.floor(time() / 86400)
    local p = PriceDB()
    local out = {}
    for d, v in ((p and p.history[itemID]) or ""):gmatch("(%d+):(%d+)") do
        d = tonumber(d)
        if d <= today and d > today - HISTORY_DAYS then out[#out + 1] = { d, tonumber(v) } end
    end
    return out
end

---------------------------------------------------------------------------
-- Price alerts
--   "Usual" price = median of the last days (not today). When something you
--   can gather sells for clearly more than usual, you hear about it once a
--   day: in chat after a scan or search, and on the Farm Spots page.
--   Only days inside the 14-day window count (Sven, 12.11.2026): a price of
--   five weeks ago is not what is usual now.
---------------------------------------------------------------------------
local function UsualPrice(itemID)
    local day = math.floor(time() / 86400)
    local values = {}
    for _, h in ipairs(PriceHistoryWindow(itemID, day)) do
        if h[1] < day then values[#values + 1] = h[2] end
    end
    if #values < ALERT_MIN_DAYS then return end
    table.sort(values)
    local mid = math.floor((#values + 1) / 2)
    if #values % 2 == 0 then return (values[mid] + values[mid + 1]) / 2 end
    return values[mid]
end

-- Items you could farm: every herb and ore from the spawn data
local gatherItems
local function GatherItems()
    if gatherItems then return gatherItems end
    gatherItems = {}
    local data = GathercraftQuestieData
    for _, kind in pairs((data and data.kinds) or {}) do
        if (kind[1] == "h" or kind[1] == "o") and kind[2] > 0 then
            gatherItems[kind[2]] = kind[3]
        end
    end
    return gatherItems
end

-- Gatherable items selling well above their usual price, best first
local function HotItems()
    local p = PriceDB()
    local hot = {}
    if not p then return hot end
    for itemID in pairs(GatherItems()) do
        local price, usual = p.items[itemID], UsualPrice(itemID)
        if price and usual and usual > 0 and price >= usual * ALERT_HIGH and price - usual >= ALERT_MIN_GAIN
            and PriceAge(p, itemID) < 86400 then
            hot[#hot + 1] = { id = itemID, price = price, usual = usual, ratio = price / usual }
        end
    end
    table.sort(hot, function(a, b) return a.ratio > b.ratio end)
    return hot
end

local function ItemName(itemID)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if name then return name end
    -- not loaded yet: ask for it (next time it's there), meanwhile the shipped list
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    return GatherItems()[itemID] or (ns.ShippedItemName and ns.ShippedItemName(itemID)) or (L["item "] .. itemID)
end

CheckAlerts = function()
    if not ns.db or ns.db.priceAlerts == false then return end
    ns.db.alerted = ns.db.alerted or {}
    local day = math.floor(time() / 86400)
    local fresh = {}
    for _, h in ipairs(HotItems()) do
        if ns.db.alerted[h.id] ~= day then
            ns.db.alerted[h.id] = day
            fresh[#fresh + 1] = h
        end
    end
    if #fresh == 0 then return end
    local parts = {}
    for i = 1, math.min(3, #fresh) do
        local h = fresh[i]
        parts[#parts + 1] = (L["%s %s (usually %s, x%.1f)"]):format(ItemName(h.id), Money(h.price), Money(h.usual), h.ratio)
    end
    ns.Print(L["|cffffd060Price alert:|r "] .. table.concat(parts, " · ")
        .. (#fresh > 3 and (L[" and %d more"]):format(#fresh - 3) or "")
        .. L["  |cff999999Farm Spots shows where to farm it.|r"])
    if PlaySound and SOUNDKIT and SOUNDKIT.AUCTION_WINDOW_OPEN then PlaySound(SOUNDKIT.AUCTION_WINDOW_OPEN) end
end

ns.UsualPrice = UsualPrice
ns.HotItems = HotItems
ns.ItemName = ItemName

---------------------------------------------------------------------------
-- /gcr ahtest : which price sources and auction functions this client has
---------------------------------------------------------------------------
local SAMPLES = { 2447, 765, 2449, 785, 2770, 2771, 2835, 2589 } -- herbs, ores, stone, linen

local function Check(label, value)
    print(("  %s: %s"):format(label, value and "|cff00ff00yes|r" or "|cffff5555no|r"))
end

local function PriceTest()
    ns.Print("Price check")
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    Check("Auctionator API", api and api.GetAuctionPriceByItemID)
    Check("TSM API", TSM_API and TSM_API.GetCustomPriceValue)
    Check("GetAuctionBuyout", GetAuctionBuyout)
    Check("C_AuctionHouse (modern AH)", C_AuctionHouse)
    Check("QueryAuctionItems (classic AH)", QueryAuctionItems)
    Check("GetAuctionItemInfo", GetAuctionItemInfo)
    Check("C_AuctionHouse.ReplicateItems (full scan)", C_AuctionHouse and C_AuctionHouse.ReplicateItems)
    local canGetAll
    if CanSendAuctionQuery then canGetAll = select(2, CanSendAuctionQuery()) end
    print(("  CanSendAuctionQuery: %s, getAll: %s (only meaningful at the auction house)"):format(
        tostring(CanSendAuctionQuery ~= nil), tostring(canGetAll)))
    print(("  Auction events the client doesn't know: %s"):format(#missingEvents > 0 and table.concat(missingEvents, ", ") or "none"))
    local p = PriceDB()
    if p and (p.scanned or 0) > 0 then
        local n = 0
        for _ in pairs(p.items) do n = n + 1 end
        print(("  Own scan: %d items, %d min ago, %d searches learned this session"):format(
            n, math.floor((time() - p.scanned) / 60), learned))
    else
        print("  Own scan: none yet (button at the auction house or /gcr scan)")
    end
    for _, id in ipairs(SAMPLES) do
        local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or ("item " .. id)
        local parts = {}
        for _, s in ipairs(SOURCES) do
            local p = s.get(id)
            parts[#parts + 1] = s.name .. " " .. (p and Money(p) or "-")
        end
        print(("  %s: %s"):format(name, table.concat(parts, ", ")))
    end
end

ns.GetPrice = GetPrice

-- Everything about one item's price in one go (0.2 B2), for what shows a
-- price with where it is from. The choice of the price is GetPrice's alone:
-- this calls it and only adds what is known about the result.
--   own, ownAge   our own price (also one too old to be used) and its age in seconds
--   kind          "market", "lowest" or nil (an entry from before: not known)
--   qty           how many were listed - only when the number belongs to this price
--   old, tooOld   the own price is 6 hours old or more / 7 days or more (not used)
--   used, source  what GetPrice gives
--   age           how old the price used is, in seconds: nil = not known,
--                 math.huge = Auctionator has it but cannot say (older than it counts)
-- The table is the same one every time: read it, don't keep it.
local info = {}
local function PriceInfo(itemID)
    local p = PriceDB()
    local own = p and itemID and p.items[itemID] or nil
    info.own, info.ownAge, info.kind, info.qty, info.old, info.tooOld = own, nil, nil, nil, nil, nil
    if own then
        local age = PriceAge(p, itemID)
        local meta = p.meta[itemID]
        info.ownAge, info.kind = age, META_KIND[meta]
        if META_QTY[meta] then info.qty = p.qty[itemID] end
        info.old, info.tooOld = age >= FRESH_PRICE, age >= MAX_PRICE_AGE
    end
    local used, source = GetPrice(itemID)
    info.used, info.source, info.age = used, source, nil
    if source == "AH scan" then
        info.age = info.ownAge
    elseif source == "Auctionator" then
        info.age = AuctionatorAge(itemID)
    end
    return info
end
ns.PriceInfo = PriceInfo
ns.PriceRev = function() return priceRev end
ns.PriceHistoryWindow = PriceHistoryWindow
-- is a history kept for this item? (only for trade goods)
ns.PriceTracksHistory = IsTradeGood

-- how old the price GetPrice gives is, in seconds (nil: not known). Read
-- only, for the skill plan's price status; the choice of the price is
-- GetPrice's alone. (Built on PriceInfo: the two cannot say different things.)
ns.PriceAgeOf = function(itemID)
    return PriceInfo(itemID).age
end
ns.BetterPriceSource = BetterSource
ns.Money = Money
ns.PriceTest = PriceTest
-- The label of the price rule as a whole (Crafting, Farm Spots). Each item
-- picks its own price (GetPrice), so this names the sources in their order
-- instead of guessing one for everything (R4-H1): own auction data, a
-- fresher Auctionator price where there is one, the vendor price otherwise.
ns.PriceSourceText = function()
    local p = PriceDB()
    local last = p and (p.scanned or 0) or 0
    for _, t in pairs(p and p.seen or {}) do
        if t > last then last = t end
    end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    local since = time() - last
    if last > 0 and since < MAX_PRICE_AGE then
        local mins = math.floor(since / 60)
        local age = mins < 60 and (mins .. L[" min"]) or mins < 2880 and (math.floor(mins / 60) .. " h") or (math.floor(mins / 1440) .. L[" days"])
        if api then return (L["prices: own scan (newest %s ago), fresher Auctionator, vendor"]):format(age) end
        return (L["prices: own scan (newest %s ago), vendor"]):format(age)
    end
    if api then return L["prices: Auctionator (scan at the auction house for our own)"] end
    return L["prices: vendor (scan at the auction house for real prices)"]
end
ns.StartScan = StartScan
ns.PriceHistory = PriceHistory
ns.LootValue = LootValue
ns.AddSessionValue = AddSessionValue
ns.SessionValue = function() return session.value, session.start, SessionSource() end
-- (/gcr perf on: the event script above, measured while it is on)
ahEvents:SetScript("OnEvent", Wrap("Prices", ahEvents:GetScript("OnEvent")))
