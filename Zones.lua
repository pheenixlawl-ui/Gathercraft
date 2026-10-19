local ADDON_NAME, ns = ...

local ROW_HEIGHT = 22
local WIDTH = 360

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local window = CreateFrame("Frame", "WoWFFarmZones", UIParent, "BackdropTemplate")
window:SetSize(WIDTH, 480)
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
tinsert(UISpecialFrames, "WoWFFarmZones") -- close with ESC

local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 14, -12)
title:SetText("WoWFFarm - Zones")

local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hint:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
hint:SetText("Checked zones and node kinds are used for farm runs.")

local scroll = CreateFrame("ScrollFrame", "WoWFFarmZonesScroll", window, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", 12, -56)
scroll:SetPoint("BOTTOMRIGHT", -32, 44)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(WIDTH - 50, 10)
scroll:SetScrollChild(content)

local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
empty:SetPoint("TOPLEFT", 4, -4)
empty:SetText("No nodes stored yet. Go gather something!")

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------
local function CollectZones()
    local zones = {}
    for mapID, list in pairs(ns.db.nodes) do
        if #list > 0 then
            local z = { mapID = mapID, name = ns.GetZoneName(mapID), total = #list, kinds = {} }
            local byKey = {}
            for _, n in ipairs(list) do
                local key = ns.KindKey(n)
                local k = byKey[key]
                if not k then
                    k = { key = key, name = n.name, type = n.type, count = 0 }
                    byKey[key] = k
                    table.insert(z.kinds, k)
                end
                k.count = k.count + 1
            end
            table.sort(z.kinds, function(a, b)
                if (a.type or "") ~= (b.type or "") then
                    return (a.type or "") < (b.type or "")
                end
                return a.name < b.name
            end)
            table.insert(zones, z)
        end
    end
    table.sort(zones, function(a, b) return a.name < b.name end)
    return zones
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local rows = {}

local function GetRow(i)
    if rows[i] then return rows[i] end
    local row = CreateFrame("Frame", nil, content)
    row:SetHeight(ROW_HEIGHT)
    row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.check:SetSize(22, 22)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.label:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
    row.label:SetJustifyH("LEFT")
    row.check:SetScript("OnClick", function(self)
        if row.onToggle then
            row.onToggle(self:GetChecked())
        end
    end)
    rows[i] = row
    return row
end

local Refresh

local function PlaceRow(i, y, indent, checked, font, text, onToggle)
    local row = GetRow(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetWidth(content:GetWidth())
    row.check:ClearAllPoints()
    row.check:SetPoint("LEFT", indent, 0)
    row.check:SetChecked(checked)
    row.label:SetFontObject(font)
    row.label:SetText(text)
    row.onToggle = onToggle
    row:Show()
end

Refresh = function()
    if not window:IsShown() or not ns.db then return end
    local zones = CollectZones()
    local i, y = 0, 0

    for _, z in ipairs(zones) do
        local mapID = z.mapID
        i = i + 1
        PlaceRow(i, y, 0, not ns.db.disabledZones[mapID], "GameFontNormal",
            ("%s  |cff999999(%d nodes)|r"):format(z.name, z.total),
            function(on)
                ns.db.disabledZones[mapID] = (not on) or nil
                Refresh()
            end)
        y = y + ROW_HEIGHT

        for _, k in ipairs(z.kinds) do
            local key = k.key
            local color = ns.TYPE_COLORS[k.type] or "|cffffffff"
            i = i + 1
            PlaceRow(i, y, 20, not ns.db.disabledKinds[key], "GameFontHighlight",
                ("%s%s|r  |cff999999x%d|r"):format(color, k.name, k.count),
                function(on)
                    ns.db.disabledKinds[key] = (not on) or nil
                    Refresh()
                end)
            y = y + ROW_HEIGHT
        end
        y = y + 6
    end

    for j = i + 1, #rows do
        rows[j]:Hide()
    end
    content:SetHeight(math.max(y, 10))
    empty:SetShown(#zones == 0)
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------
local function SetAll(on)
    for _, z in ipairs(CollectZones()) do
        ns.db.disabledZones[z.mapID] = (not on) or nil
        for _, k in ipairs(z.kinds) do
            ns.db.disabledKinds[k.key] = (not on) or nil
        end
    end
    Refresh()
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
ns.OnNodesChanged = Refresh