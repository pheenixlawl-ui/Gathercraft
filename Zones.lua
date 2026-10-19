local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Zones window (/gcr zones)
--   Continent -> materials on the continent
--             -> zones -> materials in the zone
--   A node is shown and routed only if every level above it is checked.
---------------------------------------------------------------------------
local ROW_HEIGHT = 22
local WIDTH = 400
local INDENT = 18

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
title:SetText("Gathercraft - Zones")

local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
hint:SetText("Unchecked continents, zones and materials are hidden and not routed.")

local scroll = CreateFrame("ScrollFrame", "GathercraftZonesScroll", window, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -56)
scroll:SetPoint("BOTTOMRIGHT", -32, 44)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(WIDTH - 50, 10)
scroll:SetScrollChild(content)

local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("TOPLEFT", 4, -4)
empty:SetText("No nodes stored yet. Go gather something!")

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

local function CollectTree()
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
            local z = { mapID = mapID, name = ns.GetZoneName(mapID), total = #list, kinds = {} }
            local zoneKinds = {}
            for _, n in ipairs(list) do
                AddKind(z.kinds, zoneKinds, n)
                AddKind(c.kinds, c.kindsByKey, n)
            end
            SortKinds(z.kinds)
            table.insert(c.zones, z)
            c.total = c.total + #list
        end
    end
    for _, c in ipairs(continents) do
        SortKinds(c.kinds)
        table.sort(c.zones, function(a, b) return a.name < b.name end)
    end
    table.sort(continents, function(a, b) return a.name < b.name end)
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

    rows[i] = row
    return row
end

-- opts: indent, text, font, checked (nil = no checkbox), onToggle,
--       isExpanded (nil = no expand button), onExpand
local function PlaceRow(i, y, opts)
    local row = GetRow(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetWidth(content:GetWidth())

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
    row.onToggle = opts.onToggle
    row.onExpand = opts.onExpand
    row:Show()
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------
local Refresh

local function Changed()
    ns.NotifyNodesChanged() -- updates the pins and the route
    Refresh()               -- and this window right away
end

local function KindText(k)
    local color = ns.TYPE_COLORS[k.type] or "|cffffffff"
    return ("%s%s|r  |cff999999x%d|r"):format(color, k.name, k.count)
end

Refresh = function()
    if not window:IsShown() or not ns.db then return end
    local db = ns.db
    local tree = CollectTree()
    local playerMap = C_Map.GetBestMapForUnit("player")
    local currentContinent = playerMap and ns.GetContinent(playerMap)
    local i, y = 0, 0

    local function Add(opts)
        i = i + 1
        PlaceRow(i, y, opts)
        y = y + ROW_HEIGHT
    end

    for _, c in ipairs(tree) do
        local cKey = "c" .. c.id
        local cOpen = IsExpanded(cKey, c.id == currentContinent)
        Add({
            indent = 0,
            font = "GameFontNormalLarge",
            text = ("%s  |cff999999(%d nodes)|r"):format(c.name, c.total),
            checked = not db.disabledContinents[c.id],
            onToggle = function(on)
                db.disabledContinents[c.id] = (not on) or nil
                Changed()
            end,
            isExpanded = cOpen,
            onExpand = function()
                expanded[cKey] = not cOpen
                Refresh()
            end,
        })

        if cOpen then
            -- Materials on the whole continent
            Add({ indent = INDENT, font = "GameFontNormalSmall", text = "Materials on this continent:" })
            for _, k in ipairs(c.kinds) do
                local key = c.id .. ":" .. k.key
                Add({
                    indent = INDENT,
                    text = KindText(k),
                    checked = not db.disabledContinentKinds[key],
                    onToggle = function(on)
                        db.disabledContinentKinds[key] = (not on) or nil
                        Changed()
                    end,
                })
            end

            -- Zones
            Add({ indent = INDENT, font = "GameFontNormalSmall", text = "Zones:" })
            for _, z in ipairs(c.zones) do
                local zKey = "z" .. z.mapID
                local zOpen = IsExpanded(zKey, false)
                Add({
                    indent = INDENT,
                    font = "GameFontNormal",
                    text = ("%s  |cff999999(%d nodes)|r"):format(z.name, z.total),
                    checked = not db.disabledZones[z.mapID],
                    onToggle = function(on)
                        db.disabledZones[z.mapID] = (not on) or nil
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
                                db.disabledKinds[key] = (not on) or nil
                                Changed()
                            end,
                        })
                    end
                end
            end
        end
        y = y + 8
    end

    for j = i + 1, #rows do
        rows[j]:Hide()
    end
    content:SetHeight(math.max(y, 10))
    empty:SetShown(#tree == 0)
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------
local function SetAll(on)
    local db = ns.db
    for _, c in ipairs(CollectTree()) do
        db.disabledContinents[c.id] = (not on) or nil
        for _, k in ipairs(c.kinds) do
            db.disabledContinentKinds[c.id .. ":" .. k.key] = (not on) or nil
        end
        for _, z in ipairs(c.zones) do
            db.disabledZones[z.mapID] = (not on) or nil
            for _, k in ipairs(z.kinds) do
                db.disabledKinds[z.mapID .. ":" .. k.key] = (not on) or nil
            end
        end
    end
    Changed()
end

local startButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
startButton:SetSize(110, 24)
startButton:SetPoint("BOTTOMLEFT", 12, 12)
startButton:SetText("Start run")
startButton:SetScript("OnClick", function()
    ns.StartRun("")
    window:Hide()
end)

local noneButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
noneButton:SetSize(70, 24)
noneButton:SetPoint("BOTTOMRIGHT", -12, 12)
noneButton:SetText("None")
noneButton:SetScript("OnClick", function() SetAll(false) end)

local allButton = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
allButton:SetSize(70, 24)
allButton:SetPoint("RIGHT", noneButton, "LEFT", -6, 0)
allButton:SetText("All")
allButton:SetScript("OnClick", function() SetAll(true) end)

window:SetScript("OnShow", Refresh)

---------------------------------------------------------------------------
-- Shared
---------------------------------------------------------------------------
ns.ToggleZones = function()
    window:SetShown(not window:IsShown())
end
-- Many changes in a row (e.g. sync imports) only refresh the window once
local refreshPending = false
ns.OnNodesChanged = function()
    if refreshPending or not window:IsShown() then return end
    refreshPending = true
    C_Timer.After(0.5, function()
        refreshPending = false
        Refresh()
    end)
end
