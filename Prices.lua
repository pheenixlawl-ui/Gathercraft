local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Prices: what the things you gather (and craft) are worth
--   1. Our own auction house scan (button at the auction house, /gcr scan)
--   2. Fallback while there is no scan yet: Auctionator, TSM or the shared
--      GetAuctionBuyout of other auction addons
--   3. The vendor price, which every client knows
--   Prices are stored per realm and faction and never shared with anyone.
---------------------------------------------------------------------------
local CALLER = ADDON_NAME
local SCAN_COOLDOWN = 15 * 60   -- the server allows one full scan per 15 minutes
local SCAN_TIMEOUT = 90         -- seconds to wait for the server's answer
local SCAN_CHUNK = 1500         -- auctions read per step (keeps the game smooth)
local MAX_PRICE_AGE = 7 * 86400 -- older own prices: use the fallbacks instead
local HISTORY_DAYS = 14
local MARKET_SHARE = 0.15       -- market price: what the cheapest 15% of the stock cost

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
    return p
end

local function ScanPrice(itemID)
    local p = PriceDB()
    if p and p.items[itemID] and time() - (p.scanned or 0) < MAX_PRICE_AGE then
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
    if not sell and GetItemInfo then
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
    for _, s in ipairs(SOURCES) do
        local p = s.get(itemID)
        if p then return p, s.name end
    end
end

-- "12g 34s", "34s 5c", "5c"
local G, S, C = "|cffffd700g|r", "|cffc7c7cfs|r", "|cffeda55fc|r"
local function Money(copper, short)
    copper = math.floor((copper or 0) + 0.5)
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

table.insert(ns.gatherListeners, function(node, p)
    local value, source = 0, nil
    for _, it in ipairs(p and p.items or {}) do
        local price, from = GetPrice(it.id)
        if price then
            value = value + price * (it.qty or 1)
            source = source or from
        end
    end
    if p then
        p.value, p.valueSource = value, source
    end
    session.value = session.value + value
    if source then session.sources[source] = true end
end)

-- Best source used this session (for the labels)
local function SessionSource()
    for _, s in ipairs(SOURCES) do
        if session.sources[s.name] then return s.name end
    end
end

---------------------------------------------------------------------------
-- Our own auction house scan
--   One full scan (ReplicateItems) returns every auction at once. We read it
--   in small steps and keep per item a market price (cheapest 15% of the
--   stock, so a single cheap undercut doesn't fool us) and a short history.
---------------------------------------------------------------------------
local AH = C_AuctionHouse
local ahOpen = false
local scan -- running scan: { state, started, index, total, acc }
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
    if enabled then scanButton:Enable() else scanButton:Disable() end
end

local function UpdateButton()
    if not scanButton then return end
    local left = Cooldown()
    if scan then
        SetButton("Scanning...", false)
    elseif left > 0 then
        SetButton(("Gathercraft %d:%02d"):format(math.floor(left / 60), left % 60), false)
    else
        SetButton("Gathercraft Scan", true)
    end
end

local function MarketPrice(list)
    -- list = { unitPrice, count, unitPrice, count, ... }
    local entries, total = {}, 0
    for i = 1, #list, 2 do
        entries[#entries + 1] = { list[i], list[i + 1] }
        total = total + list[i + 1]
    end
    table.sort(entries, function(a, b) return a[1] < b[1] end)
    local want, seen = math.max(1, total * MARKET_SHARE), 0
    for _, e in ipairs(entries) do
        seen = seen + e[2]
        if seen >= want then return math.floor(e[1] + 0.5), total end
    end
    return math.floor(entries[#entries][1] + 0.5), total
end

local function FinishScan()
    local p = PriceDB()
    local day = math.floor(time() / 86400)
    local items, qty = {}, {}
    local count = 0
    for itemID, list in pairs(scan.acc) do
        local price, total = MarketPrice(list)
        items[itemID], qty[itemID] = price, total
        count = count + 1
        -- history: "day:price;day:price;..." (one value per day, newest last)
        local h = p.history[itemID] or ""
        local kept = {}
        for d, v in h:gmatch("(%d+):(%d+)") do
            if tonumber(d) ~= day and tonumber(d) > day - HISTORY_DAYS then kept[#kept + 1] = d .. ":" .. v end
        end
        kept[#kept + 1] = day .. ":" .. price
        p.history[itemID] = table.concat(kept, ";")
    end
    p.items, p.qty, p.scanned = items, qty, time()
    ns.Print(("Auction house scanned: %d auctions, prices for %d items."):format(scan.total, count))
    scan = nil
    UpdateButton()
end

local function ReadInfo(index)
    local ok, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID = pcall(AH.GetReplicateItemInfo, index)
    if ok then return itemID, count, buyout end
end

local function ReadStep()
    if not scan then return end
    local last = math.min(scan.index + SCAN_CHUNK, scan.total) - 1
    for i = scan.index, last do
        local itemID, count, buyout = ReadInfo(i + scan.base)
        if itemID and count and count > 0 and buyout and buyout > 0 then
            local list = scan.acc[itemID]
            if not list then
                list = {}
                scan.acc[itemID] = list
            end
            list[#list + 1] = buyout / count
            list[#list + 1] = count
        end
    end
    scan.index = last + 1
    if scan.index >= scan.total then
        FinishScan()
    else
        C_Timer.After(0, ReadStep)
    end
end

local function OnReplicateReady()
    if not scan or scan.state ~= "waiting" then return end
    scan.state = "reading"
    scan.total = AH.GetNumReplicateItems and AH.GetNumReplicateItems() or 0
    -- the list starts at 0 on the modern auction house; fall back to 1
    scan.base = ReadInfo(0) and 0 or 1
    scan.index = 0
    ns.Debug(("SCAN %d auctions ready, first index %d"):format(scan.total, scan.base))
    if scan.total == 0 then
        ns.Print("The auction house sent no auctions. Try again in a moment.")
        scan = nil
        UpdateButton()
        return
    end
    ReadStep()
end

local function StartScan()
    if not (AH and AH.ReplicateItems) then
        ns.Print("This client has no full auction house scan.")
        return
    end
    if not ahOpen then
        ns.Print("Open the auction house first.")
        return
    end
    if scan then return end
    local left = Cooldown()
    if left > 0 then
        ns.Print(("The server allows one full scan every 15 minutes. Next scan in %d:%02d."):format(math.floor(left / 60), left % 60))
        return
    end
    local ok, err = pcall(AH.ReplicateItems)
    if not ok then
        ns.Print("Scan failed: " .. tostring(err))
        return
    end
    PriceDB().lastScanStart = time()
    scan = { state = "waiting", started = GetTime(), acc = {} }
    ns.Print("Scanning the auction house... (this takes a few seconds)")
    UpdateButton()
    C_Timer.After(SCAN_TIMEOUT, function()
        if scan and scan.state == "waiting" then
            scan = nil
            ns.Print("The auction house didn't answer. Try again later.")
            UpdateButton()
        end
    end)
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
        GameTooltip:AddLine("Gathercraft price scan")
        GameTooltip:AddLine("Reads every auction once and keeps a market price per item for gold per hour and profit.", 1, 1, 1, true)
        local p = PriceDB()
        if p and (p.scanned or 0) > 0 then
            GameTooltip:AddLine(("Last scan: %d min ago"):format(math.floor((time() - p.scanned) / 60)), 0.7, 0.7, 0.7)
        end
        local left = Cooldown()
        if left > 0 then
            GameTooltip:AddLine("The server allows one full scan every 15 minutes.", 1, 0.5, 0.5, true)
        end
        GameTooltip:Show()
    end)
    scanButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    scanButton:SetScript("OnUpdate", function(self, elapsed)
        self.t = (self.t or 0) + elapsed
        if self.t > 1 then
            self.t = 0
            UpdateButton()
            PlaceButton() -- other addons may add tabs later
        end
    end)
end

local ahEvents = CreateFrame("Frame")
for _, e in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE" }) do
    pcall(ahEvents.RegisterEvent, ahEvents, e) -- not every client knows every event
end
ahEvents:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        -- a moment later: other addons add their tabs when the window opens
        C_Timer.After(0.3, function()
            CreateScanButton()
            if scanButton then scanButton.anchor = false end
            PlaceButton()
            UpdateButton()
        end)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        if scan and scan.state == "waiting" then
            scan = nil
            ns.Print("Auction house closed, scan cancelled.")
        end
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        OnReplicateReady()
    end
end)

---------------------------------------------------------------------------
-- Auction price in every item tooltip (bags, loot, links, ...)
--   Only items that were on the auction house at our last scan: trade
--   goods and every bind-on-equip green, blue or epic. Items with random
--   bonuses ("of the Bear") share one price.
---------------------------------------------------------------------------
local function AddTooltipPrice(tooltip, itemID)
    if not (tooltip and itemID) or (ns.db and ns.db.tooltipPrices == false) then return end
    local p = PriceDB()
    local price = p and p.items[itemID]
    if not price then return end
    local age = math.floor((time() - (p.scanned or 0)) / 86400)
    local extra = ("%d listed"):format(p.qty[itemID] or 0)
    if age >= 1 then extra = extra .. (", %d day%s old"):format(age, age == 1 and "" or "s") end
    tooltip:AddDoubleLine("|cffffd060Gathercraft|r AH", Money(price) .. "  |cff999999(" .. extra .. ")|r", 1, 1, 1, 1, 1, 1)
    return true
end

local function ItemIDFromLink(link)
    return link and tonumber(link:match("item:(%d+)"))
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        AddTooltipPrice(tooltip, data and data.id)
    end)
else
    for _, name in ipairs({ "GameTooltip", "ItemRefTooltip" }) do
        local tt = _G[name]
        if tt and tt.HookScript then
            tt:HookScript("OnTooltipSetItem", function(self)
                local _, link = self:GetItem()
                if AddTooltipPrice(self, ItemIDFromLink(link)) then self:Show() end
            end)
        end
    end
end

-- Price history of an item: { {day, price}, ... } oldest first
local function PriceHistory(itemID)
    local p = PriceDB()
    local out = {}
    for d, v in ((p and p.history[itemID]) or ""):gmatch("(%d+):(%d+)") do
        out[#out + 1] = { tonumber(d), tonumber(v) }
    end
    return out
end

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
    local _, canGetAll = CanSendAuctionQuery and CanSendAuctionQuery()
    print(("  CanSendAuctionQuery: %s, getAll: %s (only meaningful at the auction house)"):format(
        tostring(CanSendAuctionQuery ~= nil), tostring(canGetAll)))
    local p = PriceDB()
    if p and (p.scanned or 0) > 0 then
        local n = 0
        for _ in pairs(p.items) do n = n + 1 end
        print(("  Own scan: %d items, %d min ago"):format(n, math.floor((time() - p.scanned) / 60)))
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
ns.Money = Money
ns.PriceTest = PriceTest
ns.StartScan = StartScan
ns.PriceHistory = PriceHistory
ns.SessionValue = function() return session.value, session.start, SessionSource() end
