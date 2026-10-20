local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Zones window (/gcr zones)
--   Continent (All / None) -> zones (always listed) -> materials in the zone
--   A node is routed only if its zone and material are checked and its
--   continent isn't switched off.
--   Chests are map icons only and never listed here.
--   Wide enough (main window): two columns, Kalimdor left, Eastern Kingdoms
--   right, any other continent (new Forever islands) below the shorter one.
---------------------------------------------------------------------------
local ROW_HEIGHT = 22
local WIDTH = 400
local INDENT = 18
local COL_GAP = 18
local TWO_COLUMNS_FROM = 600 -- content width for two columns
local KALIMDOR, EASTERN_KINGDOMS = 1414, 1415

local expanded = {} -- "c<continentID>" / "z<mapID>" -> true/false (this session)

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local window = CreateFrame("Frame", "GathercraftZones", UIParent, "BackdropTemplate")
window:SetSize(WIDTH, 520)
window:SetPoint("CENTER")
window:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
window:SetBackdropColor(0, 0, 0, 0.9)
window:SetFrameStrata("DIALOG")
window:SetClampedToScreen(true)
window:SetMovable(true)
window:EnableMouse(true)
window:RegisterForDrag("LeftButton")
window:SetScript("OnDragStart", window.StartMoving)
window:SetScript("OnDragStop", window.StopMovingOrSizing)
window:Hide()
tinsert(UISpecialFrames, "GathercraftZones") -- close with ESC

local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 14, -12)
ns.LText(title, "Gathercraft - Zones")

local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
ns.LText(hint, "Unchecked zones and materials are hidden and not routed. Click + to pick single materials.")

local scroll = CreateFrame("ScrollFrame", "GathercraftZonesScroll", window, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -56)
scroll:SetPoint("BOTTOMRIGHT", -32, 44)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(WIDTH - 50, 10)
scroll:SetScrollChild(content)

local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("TOPLEFT", 4, -4)
ns.LText(empty, "No nodes stored yet. Go gather something!")

---------------------------------------------------------------------------
-- Data: continents -> materials + zones -> materials
---------------------------------------------------------------------------
local function AddKind(list, byKey, n)
    local key = ns.KindKey(n)
    local k = byKey[key]
    if not k then
        k = { key = key, name = n.name, type = n.type, count = 0 }
        byKey[key] = k
        table.insert(list, k)
    end
    k.count = k.count + 1
end

local function SortKinds(list)
    table.sort(list, function(a, b)
        if (a.type or "") ~= (b.type or "") then
            return (a.type or "") < (b.type or "")
        end
        return a.name < b.name
    end)
end

local function CollectTree(playerContinent)
    local continents, byID = {}, {}
    for mapID, list in pairs(ns.db.nodes) do
        if #list > 0 then
            local cID, cName = ns.GetContinent(mapID)
            local c = byID[cID]
            if not c then
                c = { id = cID, name = cName, total = 0, kinds = {}, kindsByKey = {}, zones = {} }
                byID[cID] = c
                table.insert(continents, c)
            end
            local z = { mapID = mapID, name = ns.GetZoneName(mapID), total = 0, kinds = {} }
            local zoneKinds = {}
            for _, n in ipairs(list) do
                if n.type ~= "chest" then
                    AddKind(z.kinds, zoneKinds, n)
                    AddKind(c.kinds, c.kindsByKey, n)
                    z.total = z.total + 1
                end
            end
            if z.total > 0 then
                SortKinds(z.kinds)
                table.insert(c.zones, z)
                c.total = c.total + z.total
            end
        end
    end
    local current = playerContinent
    for i = #continents, 1, -1 do
        if #continents[i].zones == 0 then table.remove(continents, i) end
    end
    for _, c in ipairs(continents) do
        SortKinds(c.kinds)
        table.sort(c.zones, function(a, b) return a.name < b.name end)
    end
    table.sort(continents, function(a, b) -- your continent first
        if (a.id == current) ~= (b.id == current) then return a.id == current end
        return a.name < b.name
    end)
    return continents
end

local function IsExpanded(key, default)
    if expanded[key] == nil then return default end
    return expanded[key]
end

---------------------------------------------------------------------------
-- Rows: [+/-] [x] label
---------------------------------------------------------------------------
local rows = {}

local function GetRow(i)
    if rows[i] then return rows[i] end
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_HEIGHT)

    row.expand = CreateFrame("Button", nil, row)
    row.expand:SetSize(14, 14)
    row.expand:SetScript("OnClick", function()
        if row.onExpand then row.onExpand() end
    end)

    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(22, 22)
    row.check:SetScript("OnClick", function(self)
        if row.onToggle then row.onToggle(self:GetChecked()) end
    end)

    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)

    -- continent line: All / None for its zones
    row.none = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.none:SetSize(50, 18)
    row.none:SetPoint("RIGHT", -2, 0)
    ns.LText(row.none, "None")
    row.none:SetScript("OnClick", function() if row.onNone then row.onNone() end end)
    row.all = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.all:SetSize(44, 18)
    row.all:SetPoint("RIGHT", row.none, "LEFT", -4, 0)
    ns.LText(row.all, "All")
    row.all:SetScript("OnClick", function() if row.onAll then row.onAll() end end)

    rows[i] = row
    return row
end

-- opts: indent, text, font, checked (nil = no checkbox), onToggle,
--       isExpanded (nil = no expand button), onExpand, onAll + onNone (buttons)
local function PlaceRow(i, x0, y, width, opts)
    local row = GetRow(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", x0, -y)
    row:SetWidth(width)

    local x = opts.indent or 0
    if opts.isExpanded ~= nil then
        local tex = opts.isExpanded and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up"
        row.expand:SetNormalTexture(tex)
        row.expand:ClearAllPoints()
        row.expand:SetPoint("LEFT", x, 0)
        row.expand:Show()
    else
        row.expand:Hide()
    end
    x = x + 16

    row.label:ClearAllPoints()
    if opts.checked ~= nil then
        row.check:ClearAllPoints()
        row.check:SetPoint("LEFT", x, 0)
        row.check:SetChecked(opts.checked)
        row.check:Show()
        row.label:SetPoint("LEFT", row.check, "RIGHT", 2, 0)
    else
        row.check:Hide()
        row.label:SetPoint("LEFT", x, 0)
    end

    row.label:SetFontObject(opts.font or "GameFontHighlight")
    row.label:SetText(opts.text)
    row.label:SetPoint("RIGHT", row, "RIGHT", opts.onAll and -104 or -2, 0)
    row.onToggle = opts.onToggle
    row.onExpand = opts.onExpand
    row.onAll, row.onNone = opts.onAll, opts.onNone
    row.all:SetShown(opts.onAll ~= nil)
    row.none:SetShown(opts.onNone ~= nil)
    if opts.onAll then
        -- fit the translated texts ("Ninguno", "Nessuno", ...)
        for _, b in ipairs({ row.all, row.none }) do
            local fs = b:GetFontString()
            local w = fs and ((fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth()) or fs:GetStringWidth())
            b:SetWidth(math.max(40, (w or 30) + 16))
        end
        row.label:SetPoint("RIGHT", row, "RIGHT", -(row.all:GetWidth() + row.none:GetWidth() + 10), 0)
    end
    row:Show()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local Refresh

-- A zone and all its materials on or off together
local function SetZone(z, on)
    local db = ns.db
    db.disabledZones[z.mapID] = (not on) or nil
    for _, k in ipairs(z.kinds) do
        db.disabledKinds[z.mapID .. ":" .. k.key] = (not on) or nil
    end
end

local function Changed()
    ns.NotifyNodesChanged() -- updates the pins and the route
    Refresh()               -- and this window right away
end

local function KindText(k)
    local color = ns.TYPE_COLORS[k.type] or "|cffffffff"
    return (L["%s%s|r  |cff999999x%d|r"]):format(color, k.name, k.count)
end

Refresh = function()
    if not window:IsShown() or not ns.db then return end
    local db = ns.db
    local playerMap = C_Map.GetBestMapForUnit("player")
    local currentContinent = playerMap and ns.GetContinent(playerMap)
    local tree = CollectTree(currentContinent)
    if db.zonesV ~= 3 then -- continent-wide material filters are gone from the UI
        wipe(db.disabledContinentKinds)
        db.zonesV = 3
    end
    -- columns: Kalimdor left, Eastern Kingdoms right, the rest below the shorter one
    local scrollWidth = scroll:GetWidth() or 0
    if scrollWidth > 100 then content:SetWidth(scrollWidth) end -- the page has its size now
    local width = content:GetWidth() or 0
    local columns = (width >= TWO_COLUMNS_FROM and #tree > 1) and 2 or 1
    local colW = columns == 2 and (width - COL_GAP) / 2 or width
    local colY = { 0, 0 }
    local i, col, y = 0, 1, 0

    local function Add(opts)
        i = i + 1
        PlaceRow(i, (col - 1) * (colW + COL_GAP), y, colW, opts)
        y = y + (opts.height or ROW_HEIGHT)
    end

    local placed = {}
    for _, c in ipairs(tree) do placed[#placed + 1] = c end
    local function Rank(c)
        return (c.id == KALIMDOR and 1) or (c.id == EASTERN_KINGDOMS and 2) or 3
    end
    table.sort(placed, function(a, b)
        if Rank(a) ~= Rank(b) then return Rank(a) < Rank(b) end
        return a.name < b.name
    end)
    local hasKalimdor = placed[1] and placed[1].id == KALIMDOR

    for index, c in ipairs(placed) do
        if columns == 1 then
            col = 1
        elseif c.id == KALIMDOR then
            col = 1
        elseif c.id == EASTERN_KINGDOMS then
            col = hasKalimdor and 2 or 1
        elseif index == 1 then
            col = 1
        else
            col = colY[1] <= colY[2] and 1 or 2
        end
        y = colY[col]
        local off = db.disabledContinents[c.id]
        Add({
            indent = 0,
            font = "GameFontNormalLarge",
            text = off and ("|cff888888" .. c.name .. "|r") or c.name,
            -- the whole continent: every zone and material with it
            onAll = function()
                db.disabledContinents[c.id] = nil
                for _, z in ipairs(c.zones) do SetZone(z, true) end
                Changed()
            end,
            onNone = function()
                db.disabledContinents[c.id] = true
                for _, z in ipairs(c.zones) do SetZone(z, false) end
                Changed()
            end,
        })
        -- second line: how many nodes, and whether you are on it
        Add({
            indent = 0,
            height = 16,
            font = "GameFontHighlightSmall",
            text = (L["|cff999999%d nodes|r"]):format(c.total)
                .. (off and L["  |cff888888· off|r"] or "")
                .. (c.id == currentContinent and L["  |cff7bd35fyou are here|r"] or ""),
        })
        y = y + 4

        -- Zones stay visible; each zone opens to its materials
        for _, z in ipairs(c.zones) do
            local zKey = "z" .. z.mapID
            local here = z.mapID == playerMap
            local zOpen = IsExpanded(zKey, here)
            Add({
                indent = INDENT,
                font = "GameFontNormal",
                -- "you are here" before the count: if the line is cut, the count goes
                text = (L["%s  |cff999999(%d nodes)|r"]):format(
                    z.name .. (here and L["  |cff7bd35f< you are here >|r"] or ""), z.total),
                checked = not db.disabledZones[z.mapID],
                onToggle = function(on)
                    -- a zone ticks or unticks all its materials
                    SetZone(z, on)
                    if on then db.disabledContinents[c.id] = nil end
                    Changed()
                end,
                isExpanded = zOpen,
                onExpand = function()
                    expanded[zKey] = not zOpen
                    Refresh()
                end,
            })
            if zOpen then
                for _, k in ipairs(z.kinds) do
                    local key = z.mapID .. ":" .. k.key
                    Add({
                        indent = INDENT * 2,
                        text = KindText(k),
                        checked = not db.disabledKinds[key],
                        onToggle = function(on)
                            if on and db.disabledZones[z.mapID] then
                                -- zone was off: turn it on with only this material
                                SetZone(z, false)
                                db.disabledZones[z.mapID] = nil
                                db.disabledContinents[c.id] = nil
                            end
                            db.disabledKinds[key] = (not on) or nil
                            -- last material unticked: the zone is off too
                            if not on then
                                local any = false
                                for _, other in ipairs(z.kinds) do
                                    if not db.disabledKinds[z.mapID .. ":" .. other.key] then any = true end
                                end
                                if not any then db.disabledZones[z.mapID] = true end
                            end
                            Changed()
                        end,
                    })
                end
            end
        end
        y = y + 10
        colY[col] = y
    end

    for j = i + 1, #rows do
        rows[j]:Hide()
    end
    content:SetHeight(math.max(colY[1], colY[2], 10))
    empty:SetShown(#tree == 0)
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------
-- on: everything on (only one node type if onlyType is "herb" or "ore")
local function SetAll(on, onlyType)
    local db = ns.db
    for _, c in ipairs(CollectTree()) do
        local anyZone = false
        for _, z in ipairs(c.zones) do
            local anyKind = false
            for _, k in ipairs(z.kinds) do
                local use = on and (not onlyType or k.type == onlyType)
                db.disabledKinds[z.mapID .. ":" .. k.key] = (not use) or nil
                anyKind = anyKind or use
            end
            local zoneOn = on and (anyKind or not onlyType)
            db.disabledZones[z.mapID] = (not zoneOn) or nil
            anyZone = anyZone or zoneOn
        end
        db.disabledContinents[c.id] = (not anyZone) or nil
    end
    Changed()
end

local startButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
startButton:SetSize(110, 24)
startButton:SetPoint("BOTTOMLEFT", 12, 12)
ns.LText(startButton, "Start run")
startButton:SetScript("OnClick", function()
    ns.StartRun("")
    if ns.HideMain then ns.HideMain() else window:Hide() end
end)

local noneButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
noneButton:SetSize(70, 24)
noneButton:SetPoint("BOTTOMRIGHT", -12, 12)
ns.LText(noneButton, "None")
noneButton:SetScript("OnClick", function() SetAll(false) end)

local oreButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
oreButton:SetSize(96, 24)
oreButton:SetPoint("RIGHT", noneButton, "LEFT", -6, 0)
ns.LText(oreButton, "Only ores")
oreButton:SetScript("OnClick", function() SetAll(true, "ore") end)

local herbButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
herbButton:SetSize(96, 24)
herbButton:SetPoint("RIGHT", oreButton, "LEFT", -6, 0)
ns.LText(herbButton, "Only herbs")
herbButton:SetScript("OnClick", function() SetAll(true, "herb") end)

local allButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
allButton:SetSize(70, 24)
allButton:SetPoint("RIGHT", herbButton, "LEFT", -6, 0)
ns.LText(allButton, "All")
allButton:SetScript("OnClick", function() SetAll(true) end)

window:SetScript("OnShow", Refresh)

-- Puts the zones list into a tab of the main window
ns.EmbedZones = function(parent)
    window:SetParent(parent)
    window:ClearAllPoints()
    window:SetAllPoints(parent)
    window:SetBackdrop(nil)
    window:SetMovable(false)
    window:SetScript("OnDragStart", nil)
    window:SetScript("OnDragStop", nil)
    window:SetFrameStrata(parent:GetFrameStrata())
    title:Hide()
    close:Hide()
    hint:ClearAllPoints()
    hint:SetPoint("TOPLEFT", 6, -6)
    scroll:ClearAllPoints()
    scroll:SetPoint("TOPLEFT", 4, -26)
    scroll:SetPoint("BOTTOMRIGHT", -26, 40)
    content:SetWidth(math.max(parent:GetWidth() or 0, 480) - 40) -- width can be 0 before the first layout
    startButton:ClearAllPoints()
    startButton:SetPoint("BOTTOMLEFT", 4, 6)
    noneButton:ClearAllPoints()
    noneButton:SetPoint("BOTTOMRIGHT", -4, 6)
    tDeleteItem(UISpecialFrames, "GathercraftZones")
    return window
end

---------------------------------------------------------------------------
-- Shared
---------------------------------------------------------------------------
ns.ToggleZones = function()
    window:SetShown(not window:IsShown())
end
-- Many changes in a row (e.g. sync imports) only refresh the window once
local refreshPending = false
ns.OnNodesChanged = function()
    if refreshPending or not window:IsVisible() then return end
    refreshPending = true
    C_Timer.After(0.5, function()
        refreshPending = false
        Refresh()
    end)
end
