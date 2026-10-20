local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Best place to farm
--   Ranks the zones of your continent by expected gold per hour for herbs,
--   ores or both, counting only nodes your skill can gather.
--
--   Estimate (before you farmed a zone):
--     spawn points you can gather  -> how dense the nodes are
--     (mean distance to the nearest spawn point, only ~12% are up at once)
--     + your travel speed + a few seconds per gather  -> nodes per hour
--     x what one node is worth (your own loot so far, else price x usual yield)
--   Your runs (after 10+ minutes of farm runs in a zone):
--     the real nodes and gold per hour you made there replace the estimate.
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)

local ACTIVE_SHARE = 0.12   -- share of spawn points that have a node at a time
local DETOUR = 1.5          -- paths are never straight lines (hills, mobs, water)
local GATHER_SEC = 6        -- dismount, gather, loot
local RESPAWN_SEC = 600     -- rough respawn time, caps small zones
local YIELD = { herb = 2.0, ore = 2.0 } -- items per gather when we know nothing better
local MIN_SPOTS = 5
local REAL_MIN_SECS = 600   -- 10 minutes of runs make "your runs" numbers
local CACHE_SECS = 60
local MODES = { herb = { "herb" }, ore = { "ore" }, both = { "herb", "ore" } }
local MODE_LABELS = { herb = "Herbs", ore = "Ores", both = "Herbs + Ores" }
local TYPES = { h = "herb", o = "ore" }

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
local spotCache = {} -- mapID -> { {id, x, y, type, name, item}, ... }

local function ZoneSpots(mapID)
    local cached = spotCache[mapID]
    if cached then return cached end
    local list = {}
    local data = GathercraftQuestieData
    local packed = data and data.zones[mapID]
    if packed then
        for id, x, y in packed:gmatch("(%d+),(%d+),(%d+)") do
            local kind = data.kinds["o" .. id]
            local t = kind and TYPES[kind[1]]
            if t then
                list[#list + 1] = { id = "o" .. id, x = tonumber(x) / 10000, y = tonumber(y) / 10000,
                    type = t, name = kind[3], item = kind[2] > 0 and kind[2] or nil }
            end
        end
    end
    spotCache[mapID] = list
    return list
end

-- New nodes we know beyond the spawn data (Forever-only nodes, own finds)
local function ExtraNodes(mapID)
    local out = {}
    for _, n in ipairs(ns.db.nodes[mapID] or {}) do
        if (n.type == "herb" or n.type == "ore") and n.source ~= "questie" and n.source ~= "starter"
            and not (ns.IsKnownSpawn and n.id and ns.IsKnownSpawn(mapID, n.id, n.x, n.y)) then
            out[#out + 1] = n
        end
    end
    return out
end

local function KindKeyOf(t, name, id)
    return t .. ":" .. ((ns.CanonicalName and ns.CanonicalName(id, name)) or name or "?"):lower()
end

-- What one gather of this kind is worth (copper)
local function NodeValue(t, name, item, id)
    local kv = ns.db.kindValue and ns.db.kindValue[KindKeyOf(t, name, id)]
    if kv and kv.n >= 3 then return kv.v / kv.n, true end
    local price = item and ns.GetPrice and ns.GetPrice(item)
    return (price or 0) * (YIELD[t] or 1), false
end

local function ZoneYards(mapID)
    local x0, y0 = HBD:GetWorldCoordinatesFromZone(0, 0, mapID)
    local x1, y1 = HBD:GetWorldCoordinatesFromZone(1, 1, mapID)
    if not (x0 and x1) then return end
    return math.abs(x1 - x0), math.abs(y1 - y0)
end

-- Mean distance from each point to its nearest neighbour (grid, ~O(n))
local function MeanNearest(points)
    local CELL = 60
    local grid = {}
    for _, p in ipairs(points) do
        local key = math.floor(p[1] / CELL) .. ":" .. math.floor(p[2] / CELL)
        grid[key] = grid[key] or {}
        table.insert(grid[key], p)
    end
    local sum, count = 0, 0
    for _, p in ipairs(points) do
        local cx, cy = math.floor(p[1] / CELL), math.floor(p[2] / CELL)
        local best
        for r = 1, 12 do
            for dx = -r, r do
                for dy = -r, r do
                    for _, q in ipairs(grid[(cx + dx) .. ":" .. (cy + dy)] or {}) do
                        if q ~= p then
                            local d = math.sqrt((q[1] - p[1]) ^ 2 + (q[2] - p[2]) ^ 2)
                            -- spots on top of each other are one shared spawn point
                            if d > 3 and (not best or d < best) then best = d end
                        end
                    end
                end
            end
            if best and best <= r * CELL then break end
        end
        if best then
            sum, count = sum + best, count + 1
        end
    end
    return count > 0 and sum / count or nil
end

local function Speed()
    local level = UnitLevel and UnitLevel("player") or 1
    return level >= 40 and 11.2 or 7 -- yards per second, with or without a mount
end

local function FarmStats(mapID, mode)
    local fs = ns.db.farmStats and ns.db.farmStats[mapID]
    return fs and fs[mode]
end

-- One zone, one mode -> result row or nil
local function EvaluateZone(mapID, mode)
    local types = MODES[mode]
    local skills = {}
    for _, t in ipairs(types) do skills[t] = ns.GetSkill(t) end
    local w, h = ZoneYards(mapID)
    if not w then return end

    local points, valueSum, ups = {}, 0, 0
    local function add(t, name, id, item, x, y)
        local skill = skills[t]
        if not skill then return end
        local req = ns.RequiredSkill and ns.RequiredSkill(id, name) or 0
        if req > skill then return end
        points[#points + 1] = { x * w, y * h }
        valueSum = valueSum + NodeValue(t, name, item, id)
        if skill - req < 100 then ups = ups + 1 end
    end
    for _, s in ipairs(ZoneSpots(mapID)) do
        add(s.type, s.name, s.id, s.item, s.x, s.y)
    end
    for _, n in ipairs(ExtraNodes(mapID)) do
        add(n.type, n.name, n.id, n.item, n.x, n.y)
    end
    if #points < MIN_SPOTS then return end

    local nearest = MeanNearest(points) or 100
    local travel = nearest / math.sqrt(ACTIVE_SHARE) * DETOUR
    local perNode = travel / Speed() + GATHER_SEC
    local nodesPerHour = math.min(3600 / perNode, #points * ACTIVE_SHARE * 3600 / RESPAWN_SEC)
    local avgValue = valueSum / #points
    local row = {
        mapID = mapID, mode = mode, spots = #points,
        nodesPerHour = nodesPerHour, goldPerHour = nodesPerHour * avgValue,
        skillShare = ups / #points, real = false,
    }
    local fs = FarmStats(mapID, mode)
    if fs and fs.secs >= REAL_MIN_SECS then
        local hours = fs.secs / 3600
        row.nodesPerHour = fs.nodes / hours
        row.goldPerHour = fs.value / hours
        row.real = true
    end
    return row
end

-- Every zone with nodes for your skill, grouped by continent
-- -> { { id, name, rows = { row, ... } }, ... } (continents A-Z)
local cache = {}
local function Evaluate(mode)
    local c = cache[mode]
    if c and time() - c.at < CACHE_SECS then return c.groups end
    local zones = {}
    local data = GathercraftQuestieData
    for mapID in pairs((data and data.zones) or {}) do zones[mapID] = true end
    for mapID in pairs(ns.db.nodes) do zones[mapID] = true end
    local byID, groups = {}, {}
    for mapID in pairs(zones) do
        local cID, cName = ns.GetContinent(mapID)
        if cID and cID ~= 0 then
            local row = EvaluateZone(mapID, mode)
            if row then
                local g = byID[cID]
                if not g then
                    g = { id = cID, name = cName, rows = {} }
                    byID[cID] = g
                    groups[#groups + 1] = g
                end
                g.rows[#g.rows + 1] = row
            end
        end
    end
    table.sort(groups, function(a, b) return a.name < b.name end)
    for _, g in ipairs(groups) do
        -- best zone of the continent gets a mark
        local best
        for _, r in ipairs(g.rows) do
            if r.goldPerHour > 0 and (not best or r.goldPerHour > best.goldPerHour) then best = r end
        end
        if best then best.best = true end
    end
    cache[mode] = { at = time(), groups = groups }
    return groups
end

---------------------------------------------------------------------------
-- Learning from your runs
---------------------------------------------------------------------------
-- What each gather of a kind was worth (all loot, at today's prices)
table.insert(ns.gatherListeners, function(node, p)
    if not (p and p.value and p.value > 0) or not (node.type == "herb" or node.type == "ore") then return end
    ns.db.kindValue = ns.db.kindValue or {}
    local key = KindKeyOf(node.type, node.name, node.id)
    local kv = ns.db.kindValue[key] or { n = 0, v = 0 }
    kv.n, kv.v = kv.n + 1, kv.v + p.value
    ns.db.kindValue[key] = kv
    -- and per zone during farm runs
    local run = ns.run
    if run and MODES[run.filter or ""] and p.mapID then
        local fs = ns.FarmStatsFor(p.mapID, run.filter)
        fs.nodes = fs.nodes + 1
        fs.value = fs.value + p.value
    end
end)

ns.FarmStatsFor = function(mapID, mode)
    ns.db.farmStats = ns.db.farmStats or {}
    ns.db.farmStats[mapID] = ns.db.farmStats[mapID] or {}
    local fs = ns.db.farmStats[mapID][mode]
    if not fs then
        fs = { secs = 0, nodes = 0, value = 0 }
        ns.db.farmStats[mapID][mode] = fs
    end
    return fs
end

-- Called by the route ticker every few tenths of a second during a run
ns.CountFarmTime = function(mapID, mode, seconds)
    if mapID and MODES[mode or ""] then
        local fs = ns.FarmStatsFor(mapID, mode)
        fs.secs = fs.secs + seconds
    end
end

---------------------------------------------------------------------------
-- Page in the main window ("Farm Spots" tab)
--   Continents open and close with +/-, zones inside sorted A-Z (or by
--   gold / nodes per hour: click the column titles).
---------------------------------------------------------------------------
local ROW_H = 26

ns.BuildFarmPage = function(page, style)
    local header = style.header(page, "Best place to farm", 4, -2)
    style.divider(page, header)

    local sub = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 6, -28)
    sub:SetWidth(700)
    sub:SetJustifyH("LEFT")

    local mode, sortKey -- read from the saved choices on first show
    local modeButtons = {}
    local Refresh

    local function ModeButton(key, label, x)
        local b = style.button(page, label, key == "both" and 110 or 80)
        b:SetPoint("TOPLEFT", x, -46)
        b:SetScript("OnClick", function()
            mode = key
            ns.db.advisorMode = key
            Refresh()
        end)
        modeButtons[key] = b
    end
    ModeButton("herb", "|cff66ff66Herbs|r", 4)
    ModeButton("ore", "|cffffcc66Ores|r", 88)
    ModeButton("both", "Herbs + Ores", 172)

    -- what sells above its usual price right now (price alerts)
    local hot = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hot:SetPoint("TOPLEFT", 300, -50)
    hot:SetWidth(400)
    hot:SetJustifyH("LEFT")
    hot:SetWordWrap(true)

    -- column titles, click to sort
    local cols = {}
    local function Col(key, text, x, width, justify)
        local b = CreateFrame("Button", nil, page)
        b:SetPoint("TOPLEFT", x, -78)
        b:SetSize(width, 16)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        b.text:SetAllPoints()
        b.text:SetJustifyH(justify or "LEFT")
        b.label = text
        b:SetScript("OnClick", function()
            sortKey = key
            ns.db.advisorSort = key
            Refresh()
        end)
        cols[key] = b
    end
    Col("zone", "Zone", 26, 260)
    Col("gold", "Gold / h", 300, 90, "RIGHT")
    Col("nodes", "Nodes / h", 396, 80, "RIGHT")
    local skillTitle = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    skillTitle:SetPoint("TOPLEFT", 500, -79)
    ns.LText(skillTitle, "Skill-ups")

    local scroll = CreateFrame("ScrollFrame", "GathercraftFarmScroll", page, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, -96)
    scroll:SetPoint("BOTTOMRIGHT", -24, 34)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(700, 10)
    scroll:SetScrollChild(content)

    local rows = {}
    local function Row(i)
        if rows[i] then return rows[i] end
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(700, ROW_H)
        row:SetPoint("TOPLEFT", 4, -(i - 1) * ROW_H)
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        -- continent line
        row.expand = CreateFrame("Button", nil, row)
        row.expand:SetSize(14, 14)
        row.expand:SetPoint("LEFT", 2, 0)
        row.title = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.title:SetPoint("LEFT", 22, 0)
        -- zone line
        row.zone = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.zone:SetPoint("LEFT", 22, 0)
        row.zone:SetWidth(262)
        row.zone:SetJustifyH("LEFT")
        row.zone:SetWordWrap(false)
        row.gold = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.gold:SetPoint("LEFT", 296, 0)
        row.gold:SetWidth(90)
        row.gold:SetJustifyH("RIGHT")
        row.nodes = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.nodes:SetPoint("LEFT", 392, 0)
        row.nodes:SetWidth(70)
        row.nodes:SetJustifyH("RIGHT")
        row.skill = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.skill:SetPoint("LEFT", 496, 0)
        row.skill:SetWidth(80)
        row.skill:SetJustifyH("LEFT")
        row.go = style.button(row, L["Go"], 50)
        row.go:SetHeight(20)
        row.go:SetPoint("RIGHT", -4, 0)
        row.go:SetScript("OnClick", function()
            local r = row.data
            if not r then return end
            if ns.ImportQuestieZone then ns.ImportQuestieZone(r.mapID, true) end
            ns.StartRun(r.mode, r.mapID)
            if ns.HideMain then ns.HideMain() end
        end)
        rows[i] = row
        return row
    end

    local function ShowContinent(row, g, open)
        row.data = nil
        row.expand:Show()
        row.expand:SetNormalTexture(open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
        row.expand:SetScript("OnClick", function()
            ns.db.advisorOpen = ns.db.advisorOpen or {}
            ns.db.advisorOpen[g.id] = not open
            Refresh()
        end)
        row.title:SetText((L["%s  |cff999999(%d zones)|r"]):format(g.name, #g.rows))
        row.title:Show()
        row.bg:SetColorTexture(1, 0.8, 0.3, 0.10)
        for _, f in ipairs({ row.zone, row.gold, row.nodes, row.skill, row.go }) do f:Hide() end
    end

    local function ShowZone(row, r, here, odd)
        row.data = r
        row.expand:Hide()
        row.title:Hide()
        row.bg:SetColorTexture(1, 0.8, 0.3, odd and 0.035 or 0)
        row.zone:SetText(ns.GetZoneName(r.mapID)
            .. (r.mapID == here and L["  |cff7bd35f(here)|r"] or "")
            .. (r.best and L["  |cffffd700best|r"] or ""))
        if r.real then
            row.gold:SetText("|cff55ff55" .. (r.goldPerHour > 0 and ns.Money(r.goldPerHour, true) or "–") .. "|r")
            row.nodes:SetText((L["|cff55ff55%d|r"]):format(r.nodesPerHour))
        else
            row.gold:SetText(r.goldPerHour > 0 and ("~" .. ns.Money(r.goldPerHour, true)) or L["|cff777777–|r"])
            row.nodes:SetText(("~%d"):format(r.nodesPerHour))
        end
        if r.skillShare >= 0.5 then
            ns.LText(row.skill, "|cffff8040lots|r")
        elseif r.skillShare > 0.1 then
            ns.LText(row.skill, "|cffffff00some|r")
        elseif r.skillShare > 0 then
            ns.LText(row.skill, "|cff40ff40few|r")
        else
            ns.LText(row.skill, "|cff777777none|r")
        end
        for _, f in ipairs({ row.zone, row.gold, row.nodes, row.skill, row.go }) do f:Show() end
    end

    local empty = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOPLEFT", 8, -104)
    empty:SetWidth(500)
    empty:SetJustifyH("LEFT")

    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 6, 6)
    hint:SetWidth(710)
    hint:SetJustifyH("LEFT")
    hint:SetText(L["~ = estimate from known spawn points, your skill and prices. After 10 minutes of farm runs "] ..
        L["in a zone your real numbers are shown instead (green). Click a column title to sort."])

    local SORTS = {
        zone = function(a, b) return ns.GetZoneName(a.mapID) < ns.GetZoneName(b.mapID) end,
        gold = function(a, b)
            if math.abs(a.goldPerHour - b.goldPerHour) > 1 then return a.goldPerHour > b.goldPerHour end
            return a.nodesPerHour > b.nodesPerHour
        end,
        nodes = function(a, b) return a.nodesPerHour > b.nodesPerHour end,
    }

    Refresh = function()
        local herb, ore = ns.GetSkill("herb"), ns.GetSkill("ore")
        mode = mode or ns.db.advisorMode
        sortKey = sortKey or ns.db.advisorSort or "zone"
        if not mode or (mode == "herb" and not herb) or (mode == "ore" and not ore) then
            mode = (herb and ore and "both") or (herb and "herb") or (ore and "ore") or "both"
        end
        for key, b in pairs(modeButtons) do
            local learned = (key == "herb" and herb) or (key == "ore" and ore) or (key == "both" and (herb or ore))
            if learned then b:Enable() else b:Disable() end
            b:SetAlpha(key == mode and 1 or 0.6)
        end
        for key, b in pairs(cols) do
            b.text:SetText(key == sortKey and ("|cffffffff" .. L[b.label] .. "|r") or L[b.label])
        end

        local skillText = {}
        if herb then skillText[#skillText + 1] = L["Herbalism "] .. herb end
        if ore then skillText[#skillText + 1] = L["Mining "] .. ore end
        sub:SetText(("%s  ·  %s"):format(
            #skillText > 0 and table.concat(skillText, ", ") or L["no gathering profession"],
            ns.PriceSourceText and ns.PriceSourceText() or ""))

        local hotList = ns.HotItems and ns.HotItems() or {}
        if #hotList > 0 then
            local parts = {}
            for i = 1, math.min(3, #hotList) do
                parts[#parts + 1] = (L["%s |cff55ff55x%.1f|r"]):format(ns.ItemName(hotList[i].id), hotList[i].ratio)
            end
            hot:SetText(L["|cffffd060Hot right now:|r "] .. table.concat(parts, ", "))
        else
            hot:SetText("")
        end

        local groups = Evaluate(mode)
        local here = ns.GetPlayerPos()
        local hereContinent = here and ns.GetContinent(here)
        ns.db.advisorOpen = ns.db.advisorOpen or {}
        local i = 0
        for _, g in ipairs(groups) do
            local open = ns.db.advisorOpen[g.id]
            if open == nil then open = (g.id == hereContinent) end
            i = i + 1
            ShowContinent(Row(i), g, open)
            Row(i):Show()
            if open then
                table.sort(g.rows, SORTS[sortKey] or SORTS.zone)
                for k, r in ipairs(g.rows) do
                    i = i + 1
                    ShowZone(Row(i), r, here, k % 2 == 0)
                    Row(i):Show()
                end
            end
        end
        for j = i + 1, #rows do rows[j]:Hide() end
        content:SetHeight(math.max(10, i * ROW_H))

        if #groups == 0 then
            empty:SetText((herb or ore) and L["No zones with nodes for your skill yet."]
                or L["Learn Herbalism or Mining to see where farming pays best."])
            empty:Show()
        else
            empty:Hide()
        end
    end

    page:SetScript("OnShow", Refresh)
    return Refresh
end

ns.FarmAdvice = Evaluate
