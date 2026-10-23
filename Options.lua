local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Minimap button, options window and key bindings
---------------------------------------------------------------------------
local PIN_SIZE_MIN, PIN_SIZE_MAX, PIN_SIZE_DEFAULT = 8, 24, 14

local function ToggleRun()
    if ns.run then
        ns.StopRun()
    else
        ns.StartHereRun() -- your zone, your gathering professions
    end
end

---------------------------------------------------------------------------
-- Options window
---------------------------------------------------------------------------
local options = CreateFrame("Frame", "GathercraftOptions", UIParent, "BackdropTemplate")
options:SetSize(740, 530) -- standalone; in the main window it fills the Options tab
options:SetPoint("CENTER")
options:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
options:SetBackdropColor(0, 0, 0, 0.9)
options:SetFrameStrata("DIALOG")
options:SetClampedToScreen(true)
options:SetMovable(true)
options:EnableMouse(true)
options:RegisterForDrag("LeftButton")
options:SetScript("OnDragStart", options.StartMoving)
options:SetScript("OnDragStop", options.StopMovingOrSizing)
options:Hide()
tinsert(UISpecialFrames, "GathercraftOptions")

local title = options:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 14, -12)
ns.LText(title, "Gathercraft - Options")

local close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

---------------------------------------------------------------------------
-- Layout: a list of sections on the left, the chosen section on the right
-- (one column, a title and a short line on what it is about)
---------------------------------------------------------------------------
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local GOLD = { 1, 0.82, 0.30 }
local EMBER = { 0.42, 0.10, 0.04 }
local NAV_W, NAV_H, NAV_GAP = 160, 30, 4
local FOOTER_H = 60
local SECTIONS = {
    { key = "map", name = "Map & minimap", icon = "Interface\\Icons\\INV_Misc_Spyglass_02",
      desc = "How Gathercraft shows nodes on the world map and the minimap." },
    { key = "runs", name = "Farm runs", icon = "Interface\\Icons\\Ability_Tracking",
      desc = "What a farm run goes for and how it shows you the way." },
    { key = "sync", name = "Sharing", icon = "Interface\\Icons\\INV_Letter_15",
      desc = "Share the spots you find with other Gathercraft players – and get theirs." },
    { key = "alerts", name = "Rares & prices", icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
      desc = "Warnings for rare mobs, and auction prices where you need them." },
    { key = "general", name = "General", icon = "Interface\\Icons\\INV_Misc_Gear_01",
      desc = "Language, minimap button and the rest." },
}

local nav = CreateFrame("Frame", nil, options)
nav:SetWidth(NAV_W)
local content = CreateFrame("Frame", nil, options)
local navLine = options:CreateTexture(nil, "ARTWORK")
navLine:SetWidth(1)
navLine:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.25)

-- top: below the title when standalone, right at the top inside the main window
local function Layout(top)
    nav:ClearAllPoints()
    nav:SetPoint("TOPLEFT", options, "TOPLEFT", 14, top)
    nav:SetPoint("BOTTOMLEFT", options, "BOTTOMLEFT", 14, FOOTER_H + 6)
    navLine:ClearAllPoints()
    navLine:SetPoint("TOPLEFT", nav, "TOPRIGHT", 12, 0)
    navLine:SetPoint("BOTTOMLEFT", nav, "BOTTOMRIGHT", 12, 0)
    content:ClearAllPoints()
    content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 28, 0)
    content:SetPoint("BOTTOMRIGHT", options, "BOTTOMRIGHT", -16, FOOTER_H + 6)
end
Layout(-44)

local navButtons, sectionPages = {}, {}
local function StyleNav(b, selected)
    if selected then
        b:SetBackdropColor(EMBER[1], EMBER[2], EMBER[3], 1)
        b:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1)
        b.text:SetTextColor(1, 0.95, 0.8)
    else
        b:SetBackdropColor(0.10, 0.09, 0.08, 1)
        b:SetBackdropBorderColor(0.40, 0.38, 0.35, 1)
        b.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    end
end

local function ShowSection(key)
    if not sectionPages[key] then key = SECTIONS[1].key end
    if ns.db then ns.db.optionsSection = key ~= SECTIONS[1].key and key or nil end
    for k, page in pairs(sectionPages) do
        page:SetShown(k == key)
        StyleNav(navButtons[k], k == key)
    end
end
ns.ShowOptionsSection = ShowSection

local syncStatus, UpdateSyncStatus -- the Sharing section's status lines (below)
local controls = {}
-- Labels in front of +/- and < > controls; long translations get the
-- smaller font instead of running into the buttons
local fitLabels = {}
local LABEL_WIDTH = 150
local CONTROL_X = 160
local VALUE_W = 100 -- the value between < > or - +, the same everywhere so the buttons line up
local function FitLabels()
    for _, fs in ipairs(fitLabels) do
        fs:SetFontObject(GameFontHighlight)
        if (fs:GetStringWidth() or 0) > LABEL_WIDTH then fs:SetFontObject(GameFontHighlightSmall) end
    end
end

local page -- the section the Add* functions below fill
local colX, nextY = 0, 0

local function Section(index)
    local info = SECTIONS[index]
    page = CreateFrame("Frame", nil, content)
    page:SetAllPoints(content)
    page:Hide()
    sectionPages[info.key] = page

    local head = page:CreateFontString(nil, "OVERLAY")
    head:SetFont(TITLE_FONT, 18, "")
    head:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    head:SetShadowColor(0, 0, 0, 1)
    head:SetShadowOffset(1, -1)
    head:SetPoint("TOPLEFT", 0, -2)
    ns.LText(head, info.name)
    local line = page:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 0, -26)
    line:SetPoint("TOPRIGHT", 0, -26)
    line:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
    local desc = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    desc:SetPoint("TOPLEFT", 0, -34)
    desc:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    desc:SetJustifyH("LEFT")
    ns.LText(desc, info.desc)

    local b = CreateFrame("Button", nil, nav, "BackdropTemplate")
    b:SetSize(NAV_W, NAV_H)
    b:SetPoint("TOPLEFT", 0, -(index - 1) * (NAV_H + NAV_GAP))
    b:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetPoint("LEFT", 8, 0)
    b.icon:SetTexture(info.icon)
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.text = b:CreateFontString(nil, "OVERLAY")
    b.text:SetFont(TITLE_FONT, 14, "")
    b.text:SetPoint("LEFT", b.icon, "RIGHT", 7, -1)
    b.text:SetPoint("RIGHT", b, "RIGHT", -4, -1)
    b.text:SetJustifyH("LEFT")
    ns.LText(b.text, info.name)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 3, -3)
    hl:SetPoint("BOTTOMRIGHT", -3, 3)
    hl:SetColorTexture(1, 0.8, 0.3, 0.12)
    b:SetScript("OnClick", function() ShowSection(info.key) end)
    navButtons[info.key] = b

    colX, nextY = 0, -62
end

local function AddHeader(text)
    nextY = nextY - 6
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", colX + 2, nextY)
    ns.LText(fs, text)
    nextY = nextY - 20
end

-- a grey line under the control above it
local function AddHint(text)
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("TOPLEFT", colX + 30, nextY + 2)
    fs:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    fs:SetJustifyH("LEFT")
    ns.LText(fs, text)
    nextY = nextY - 16
end

-- get() returns the current state, set(on) changes it
local function AddCheck(label, get, set)
    local cb = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", colX, nextY)
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    ns.LText(fs, label)
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        options:Refresh()
    end)
    cb.get = get
    controls[#controls + 1] = cb
    nextY = nextY - 26
end

-- Farm runs: how close you must get before the arrow moves to the next node
local arriveText
local function AddArrive()
    local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Next node at")
    fitLabels[#fitLabels + 1] = label

    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + CONTROL_X, nextY)
    minus:SetText("-")

    arriveText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    arriveText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    arriveText:SetWidth(VALUE_W)

    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", arriveText, "RIGHT", 6, 0)
    plus:SetText("+")

    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", colX + 6, nextY - 24)
    ns.LText(hint, "Close enough to see whether the node is there")

    local function Change(delta)
        local lo, hi = ns.ARRIVE_LIMITS[1], ns.ARRIVE_LIMITS[2]
        ns.db.arriveDist = math.max(lo, math.min(hi, ns.ArriveDistance() + delta))
        options:Refresh()
    end
    minus:SetScript("OnClick", function() Change(-5) end)
    plus:SetScript("OnClick", function() Change(5) end)
    nextY = nextY - 44
end

local pinSizeText
local function AddPinSize()
    local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Pin size")
    fitLabels[#fitLabels + 1] = label

    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + CONTROL_X, nextY)
    minus:SetText("-")

    pinSizeText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pinSizeText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    pinSizeText:SetWidth(VALUE_W)

    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", pinSizeText, "RIGHT", 6, 0)
    plus:SetText("+")

    local function Change(delta)
        local size = (ns.db.pinSize or PIN_SIZE_DEFAULT) + delta
        ns.db.pinSize = math.max(PIN_SIZE_MIN, math.min(PIN_SIZE_MAX, size))
        ns.NotifyNodesChanged() -- rebuilds the pins
        options:Refresh()
    end
    minus:SetScript("OnClick", function() Change(-2) end)
    plus:SetScript("OnClick", function() Change(2) end)
    nextY = nextY - 30
end

-- Language: < name >, applies at once (a few texts after a reload)
local languageText
local function AddLanguage()
    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + 6, nextY)
    minus:SetText("<")

    languageText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    languageText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    languageText:SetWidth(170)

    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", languageText, "RIGHT", 6, 0)
    plus:SetText(">")

    local reload = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    reload:SetSize(90, 20)
    reload:SetPoint("LEFT", plus, "RIGHT", 10, 0)
    ns.LText(reload, "Reload UI")
    reload:SetScript("OnClick", function() ReloadUI() end)

    local hint = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", colX + 6, nextY - 24)
    ns.LText(hint, "Most texts change at once, all of them after a reload")

    local function Change(delta)
        local list, index = ns.UsableLanguages and ns.UsableLanguages() or ns.LANGUAGES, 1
        for i, lang in ipairs(list) do
            if lang.code == (ns.db.language or "auto") then index = i end
        end
        index = (index - 1 + delta) % #list + 1
        ns.db.language = list[index].code
        ns.ApplyLanguage()
        options:Refresh()
    end
    minus:SetScript("OnClick", function() Change(-1) end)
    plus:SetScript("OnClick", function() Change(1) end)
    nextY = nextY - 44
end

-- Route goal: < Auto | Skill-ups | Gold | Nodes >, explained in the tooltip
local GOALS = {
    { code = "auto", name = "Auto", tip = "Skill-ups while nodes here still level you, then gold." },
    { code = "skill", name = "Skill-ups", tip = "Prefers nodes that still give skill-ups." },
    { code = "gold", name = "Gold", tip = "Prefers what sells best (your auction house scan)." },
    { code = "nodes", name = "Nodes", tip = "Every node the same: as many nodes as possible." },
}
local goalText
local function CurrentGoal()
    for i, g in ipairs(GOALS) do
        if g.code == (ns.db.routeGoal or "auto") then return g, i end
    end
    return GOALS[1], 1
end
local function AddRouteGoal()
    local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Route goal")
    fitLabels[#fitLabels + 1] = label

    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + CONTROL_X, nextY)
    minus:SetText("<")

    goalText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    goalText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    goalText:SetWidth(VALUE_W)

    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", goalText, "RIGHT", 6, 0)
    plus:SetText(">")

    local function Tip(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Route goal"], 1, 0.82, 0)
        GameTooltip:AddLine(L[CurrentGoal().tip], 1, 1, 1, true)
        GameTooltip:AddLine(L["Nodes you can't gather yet are never part of a route."], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
    local function Change(delta)
        local _, index = CurrentGoal()
        index = (index - 1 + delta) % #GOALS + 1
        ns.db.routeGoal = GOALS[index].code
        if ns.RouteGoalChanged then ns.RouteGoalChanged() end
        options:Refresh()
        if GameTooltip:IsOwned(minus) or GameTooltip:IsOwned(plus) then Tip(delta < 0 and minus or plus) end
    end
    minus:SetScript("OnClick", function() Change(-1) end)
    plus:SetScript("OnClick", function() Change(1) end)
    for _, b in ipairs({ minus, plus }) do
        b:SetScript("OnEnter", Tip)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    nextY = nextY - 30
end

-- Route type: < Smart | Loop >, explained in the tooltip
local ROUTE_MODES = {
    { code = "smart", name = "Smart",
      tip = "Plans live: always rides to what most likely has a node right now." },
    { code = "loop", name = "Loop",
      tip = "One fixed round through all spawn points, ridden again and again like in farming guides. Where many players farm and spots come back fast, the round gets shorter and stays in the dense part. Empty or hard to reach points are left out until they can have a node again." },
}
local modeText
local function CurrentMode()
    return ns.db.routeMode == "loop" and ROUTE_MODES[2] or ROUTE_MODES[1], ns.db.routeMode == "loop" and 2 or 1
end
local function AddRouteMode()
    local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Route type")
    fitLabels[#fitLabels + 1] = label

    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + CONTROL_X, nextY)
    minus:SetText("<")

    modeText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    modeText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    modeText:SetWidth(VALUE_W)

    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", modeText, "RIGHT", 6, 0)
    plus:SetText(">")

    local function Tip(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Route type"], 1, 0.82, 0)
        GameTooltip:AddLine(L[CurrentMode().tip], 1, 1, 1, true)
        GameTooltip:Show()
    end
    local function Change()
        local _, index = CurrentMode()
        ns.db.routeMode = index == 1 and "loop" or nil
        if ns.RouteModeChanged then ns.RouteModeChanged() end
        options:Refresh()
        if GameTooltip:IsOwned(minus) or GameTooltip:IsOwned(plus) then
            Tip(GameTooltip:IsOwned(minus) and minus or plus)
        end
    end
    for _, b in ipairs({ minus, plus }) do
        b:SetScript("OnClick", Change)
        b:SetScript("OnEnter", Tip)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    nextY = nextY - 30
end

-- Minimap pin style: < Normal | Subtle >, explained in the tooltip
local MINI_STYLES = {
    { code = "normal", name = "Normal" },
    { code = "subtle", name = "Subtle" },
}
local miniStyleText
local function AddMiniStyle()
    local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Minimap style")
    fitLabels[#fitLabels + 1] = label

    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + CONTROL_X, nextY)
    minus:SetText("<")

    miniStyleText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    miniStyleText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    miniStyleText:SetWidth(VALUE_W)

    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", miniStyleText, "RIGHT", 6, 0)
    plus:SetText(">")

    local function Tip(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Minimap style"], 1, 0.82, 0)
        GameTooltip:AddLine(L["Subtle: a silver ring around a smaller, see-through icon. What the game's herb and mineral tracking shows right now stands out."], 1, 1, 1, true)
        GameTooltip:AddLine(L["The next node of a farm run is always shown with a gold ring."], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
    local function Change()
        -- subtle is the default (nil); "normal" has to be chosen
        ns.db.miniPinStyle = ns.SubtleMinimap() and "normal" or nil
        ns.NotifyNodesChanged() -- rebuilds the pins
        options:Refresh()
        if GameTooltip:IsOwned(minus) or GameTooltip:IsOwned(plus) then Tip(GameTooltip:IsOwned(minus) and minus or plus) end
    end
    minus:SetScript("OnClick", Change)
    plus:SetScript("OnClick", Change)
    for _, b in ipairs({ minus, plus }) do
        b:SetScript("OnEnter", Tip)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    nextY = nextY - 30
end

-- World map pin style: < Normal | Ring >
local worldStyleText
local function AddWorldStyle()
    local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "World map style")
    fitLabels[#fitLabels + 1] = label

    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + CONTROL_X, nextY)
    minus:SetText("<")

    worldStyleText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    worldStyleText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    worldStyleText:SetWidth(VALUE_W)

    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", worldStyleText, "RIGHT", 6, 0)
    plus:SetText(">")

    local function Tip(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["World map style"], 1, 0.82, 0)
        GameTooltip:AddLine(L["Ring: each icon sits in a thin silver ring, like on the minimap."], 1, 1, 1, true)
        GameTooltip:Show()
    end
    local function Change()
        -- ring is the default (nil); "normal" has to be chosen
        ns.db.worldPinStyle = ns.RingedWorldMap() and "normal" or nil
        ns.NotifyNodesChanged() -- rebuilds the pins
        options:Refresh()
        if GameTooltip:IsOwned(minus) or GameTooltip:IsOwned(plus) then Tip(GameTooltip:IsOwned(minus) and minus or plus) end
    end
    minus:SetScript("OnClick", Change)
    plus:SetScript("OnClick", Change)
    for _, b in ipairs({ minus, plus }) do
        b:SetScript("OnEnter", Tip)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    nextY = nextY - 30
end

-- Minimap opacity: - 60% +  (steps of 10%, 20% .. 100%)
local miniAlphaText
local function AddMiniAlpha()
    local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Minimap opacity")
    fitLabels[#fitLabels + 1] = label

    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + CONTROL_X, nextY)
    minus:SetText("-")

    miniAlphaText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    miniAlphaText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    miniAlphaText:SetWidth(VALUE_W)

    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", miniAlphaText, "RIGHT", 6, 0)
    plus:SetText("+")

    local function Tip(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Minimap opacity"], 1, 0.82, 0)
        GameTooltip:AddLine(L["How visible Gathercraft's pins on the minimap are. Lower: what the game's tracking shows right now stands out more."], 1, 1, 1, true)
        GameTooltip:AddLine(L["The next node of a farm run is always shown with a gold ring."], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end
    local function Change(delta)
        local pct = math.floor((ns.db.miniPinAlpha or 1) * 100 + 0.5) + delta
        pct = math.max(20, math.min(100, pct))
        ns.db.miniPinAlpha = pct < 100 and pct / 100 or nil
        ns.NotifyNodesChanged() -- rebuilds the pins
        options:Refresh()
    end
    minus:SetScript("OnClick", function() Change(-10) end)
    plus:SetScript("OnClick", function() Change(10) end)
    for _, b in ipairs({ minus, plus }) do
        b:SetScript("OnEnter", Tip)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    nextY = nextY - 30
end

-- Route line look: a color swatch (click: next, right-click: back) and < style >
local lineSwatch, lineStyleText
local function Cycle(list, code, delta)
    local index = 1
    for i, e in ipairs(list) do
        if e.code == code then index = i end
    end
    return list[(index - 1 + delta) % #list + 1].code
end
local function AddRouteLineLook()
    local label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Route line")
    fitLabels[#fitLabels + 1] = label

    lineSwatch = CreateFrame("Button", nil, page, "BackdropTemplate")
    lineSwatch:SetSize(20, 20)
    lineSwatch:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    lineSwatch.tex = lineSwatch:CreateTexture(nil, "ARTWORK")
    lineSwatch.tex:SetPoint("TOPLEFT", 3, -3)
    lineSwatch.tex:SetPoint("BOTTOMRIGHT", -3, 3)
    lineSwatch.tex:SetColorTexture(1, 1, 1)
    lineSwatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local minus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + CONTROL_X, nextY)
    minus:SetText("<")
    lineStyleText = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lineStyleText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    lineStyleText:SetWidth(VALUE_W)
    local plus = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", lineStyleText, "RIGHT", 6, 0)
    plus:SetText(">")
    lineSwatch:SetPoint("LEFT", plus, "RIGHT", 12, 0)

    local function Changed()
        if ns.RedrawRouteLine then ns.RedrawRouteLine() end
        options:Refresh()
    end
    lineSwatch:SetScript("OnClick", function(self, button)
        ns.db.routeLineColor = Cycle(ns.ROUTE_LINE_COLORS, ns.RouteLineColor().code, button == "RightButton" and -1 or 1)
        Changed()
        if GameTooltip:IsOwned(self) then self:GetScript("OnEnter")(self) end
    end)
    lineSwatch:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Route line color"], 1, 0.82, 0)
        GameTooltip:AddLine(L[ns.RouteLineColor().name], 1, 1, 1)
        GameTooltip:AddLine(L["Click: next color, right-click: back"], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    lineSwatch:SetScript("OnLeave", GameTooltip_Hide)
    minus:SetScript("OnClick", function()
        ns.db.routeLineStyle = Cycle(ns.ROUTE_LINE_STYLES, ns.RouteLineStyle().code, -1)
        Changed()
    end)
    plus:SetScript("OnClick", function()
        ns.db.routeLineStyle = Cycle(ns.ROUTE_LINE_STYLES, ns.RouteLineStyle().code, 1)
        Changed()
    end)
    nextY = nextY - 30
end

function options:Refresh()
    FitLabels()
    UpdateSyncStatus()
    for _, cb in ipairs(controls) do
        cb:SetChecked(cb.get())
    end
    if arriveText and ns.ArriveDistance then
        arriveText:SetText(ns.ArriveDistance() .. L[" yd"])
    end
    if lineSwatch and ns.RouteLineColor then
        local rgb = ns.RouteLineColor().rgb
        lineSwatch.tex:SetColorTexture(rgb[1], rgb[2], rgb[3])
        lineStyleText:SetText(L[ns.RouteLineStyle().name])
    end
    if goalText then
        goalText:SetText(L[CurrentGoal().name])
    end
    if modeText then
        modeText:SetText(L[CurrentMode().name])
    end
    if miniStyleText then
        miniStyleText:SetText(L[ns.SubtleMinimap() and MINI_STYLES[2].name or MINI_STYLES[1].name])
    end
    if worldStyleText then
        worldStyleText:SetText(L[ns.RingedWorldMap() and "Ring" or "Normal"])
    end
    if miniAlphaText then
        miniAlphaText:SetText(("%d%%"):format(math.floor((ns.db.miniPinAlpha or 1) * 100 + 0.5)))
    end
    if pinSizeText then
        pinSizeText:SetText(tostring(ns.db.pinSize or PIN_SIZE_DEFAULT))
    end
    if languageText then
        local name = ns.db.language or "auto"
        for _, lang in ipairs(ns.LANGUAGES) do
            if lang.code == name then name = lang.code == "auto" and L[lang.name] or lang.name end
        end
        languageText:SetText(name)
    end
end
options:SetScript("OnShow", options.Refresh)

-- Sharing section: what happened so far (so you see that it works)
syncStatus = nil
UpdateSyncStatus = function()
    if not (syncStatus and ns.SyncSummary and ns.db and ns.db.sync) then return end
    if not ns.db.sync.enabled then
        syncStatus:SetText(L["Sharing is off."])
        return
    end
    local peers, received, waiting, joined = ns.SyncSummary()
    local lines = {
        (L["Gathercraft players seen in the last hour: %d"]):format(peers),
        (L["Spots received this session: %d"]):format(received),
        (L["Waiting for a second player to confirm them: %d"]):format(waiting),
    }
    if ns.db.sync.public and not joined then
        lines[#lines + 1] = "|cffff8040" .. L["Not in the sharing channel yet (it is joined a few seconds after login)."] .. "|r"
    end
    syncStatus:SetText(table.concat(lines, "\n"))
end

local function Build()
    Section(1) -- Map & minimap
    AddCheck("Show nodes on the world map",
        function() return not ns.db.worldPinsHidden end,
        function(on)
            ns.db.worldPinsHidden = not on or nil
            ns.NotifyNodesChanged()
        end)
    AddCheck("Show nodes on the minimap",
        function() return not ns.db.miniPinsHidden end,
        function(on)
            ns.db.miniPinsHidden = not on or nil
            ns.NotifyNodesChanged()
        end)
    AddCheck("Show chests",
        function() return not ns.db.chestsHidden end,
        function(on)
            ns.db.chestsHidden = not on or nil
            ns.NotifyNodesChanged()
        end)
    AddCheck("Hide zones and materials unticked in the Zones tab",
        function() return ns.db.mapFollowsZones end,
        function(on)
            ns.db.mapFollowsZones = on or nil
            ns.NotifyNodesChanged()
        end)
    AddCheck("Learn nodes you point at on the minimap",
        function() return not ns.db.minimapLearnOff end,
        function(on) ns.db.minimapLearnOff = not on or nil end)
    AddHint("Hover a herb or vein on the minimap: Gathercraft remembers the spot.")
    AddCheck("Herbs / minerals switch button",
        function() return not ns.db.trackButtonHidden end,
        function(on)
            ns.db.trackButtonHidden = not on or nil
            if ns.UpdateTrackButton then ns.UpdateTrackButton() end
        end)
    AddHint("Next to the minimap, when you know both: one click switches your tracking.")
    do
        local macro = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
        macro:SetSize(180, 22)
        macro:SetPoint("TOPLEFT", colX + 30, nextY)
        ns.LText(macro, "Put it on an action bar")
        macro:SetScript("OnClick", function() if ns.TrackMacro then ns.TrackMacro() end end)
        macro:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(L["Put it on an action bar"], 1, 0.82, 0)
            GameTooltip:AddLine(L["Creates the macro \"GC Tracking\" and puts it on your cursor. Works with the button hidden too."], 1, 1, 1, true)
            GameTooltip:Show()
        end)
        macro:SetScript("OnLeave", GameTooltip_Hide)
        nextY = nextY - 28
    end
    nextY = nextY - 10
    AddWorldStyle()
    AddMiniStyle()
    AddMiniAlpha()
    AddPinSize()

    Section(2) -- Farm runs
    AddRouteMode()
    AddRouteGoal()
    nextY = nextY - 4
    AddCheck("Show Gathercraft arrow during farm runs",
        function() return not ns.db.arrowHidden end,
        function(on)
            ns.db.arrowHidden = not on
            if ns.UpdateArrow then ns.UpdateArrow() end
            if ns.RouteArrowChanged then ns.RouteArrowChanged() end
        end)
    AddCheck("Show a summary when a run ends",
        function() return not ns.db.summaryOff end,
        function(on) ns.db.summaryOff = not on end)
    nextY = nextY - 4
    AddArrive()
    AddCheck("Show route line",
        function() return not ns.db.routeLineHidden end,
        function(on)
            if (not ns.db.routeLineHidden) ~= on then ns.ToggleRouteLine() end
        end)
    nextY = nextY - 4
    AddRouteLineLook()

    Section(3) -- Sharing
    AddCheck("Share nodes with other players",
        function() return ns.db.sync and ns.db.sync.enabled end,
        function(on) ns.SyncCommand(on and "on" or "off") end)
    AddHint("Only node spots are shared. Spots learned from the minimap follow once you harvest them.")
    AddCheck("Public channel (off = guild and friends only)",
        function() return ns.db.sync and ns.db.sync.public end,
        function(on)
            if ns.db.sync.public ~= on then ns.SyncCommand("public") end
        end)
    AddCheck("Tell me in chat when spots of other players arrive",
        function() return not (ns.db.sync and ns.db.sync.announceOff) end,
        function(on) ns.db.sync.announceOff = not on or nil end)
    -- what sharing did so far, kept up to date while the section is open
    nextY = nextY - 10
    AddHeader("Right now")
    syncStatus = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    syncStatus:SetPoint("TOPLEFT", colX + 6, nextY)
    syncStatus:SetPoint("RIGHT", page, "RIGHT", 0, 0)
    syncStatus:SetJustifyH("LEFT")
    nextY = nextY - 60
    local statusElapsed = 0
    page:SetScript("OnUpdate", function(_, elapsed)
        statusElapsed = statusElapsed + elapsed
        if statusElapsed < 2 then return end
        statusElapsed = 0
        UpdateSyncStatus()
    end)

    Section(4) -- Rares & prices
    AddHeader("Rares")
    AddCheck("Alert when a rare shows up (sound + warning)",
        function() return ns.db.rareAlert ~= false end,
        function(on) ns.db.rareAlert = on end)
    AddCheck("Announcer shouts \"RARE!\"",
        function() return ns.db.rareAnnouncer ~= false end,
        function(on) ns.db.rareAnnouncer = on end)
    AddCheck("Also play the raid warning sound",
        function() return ns.db.rareSound end,
        function(on) ns.db.rareSound = on end)
    nextY = nextY - 6
    AddHeader("Prices")
    AddCheck("Price alerts in chat (hot items you gather)",
        function() return ns.db.priceAlerts ~= false end,
        function(on) ns.db.priceAlerts = on end)
    AddCheck("Auction prices in item tooltips",
        function() return ns.db.tooltipPrices ~= false end,
        function(on) ns.db.tooltipPrices = on end)

    Section(5) -- General
    AddHeader("Language")
    AddLanguage()
    nextY = nextY - 6
    AddHeader("Other")
    AddCheck("Minimap button",
        function() return not ns.db.minimapHidden end,
        function(on)
            ns.db.minimapHidden = not on
            ns.UpdateMinimapButton()
        end)
    AddCheck("Remind me to visit the trainer (5 points before the end of a rank)",
        function() return not ns.db.trainerRemindOff end,
        function(on) ns.db.trainerRemindOff = not on end)
    AddCheck("Fish key applies a lure when the pole has none",
        function() return ns.db.fishLure ~= false end,
        function(on) ns.db.fishLure = on end)
    AddCheck("Debug output (chat tab \"Gathercraft\")",
        function() return ns.db.debug end,
        function(on)
            ns.db.debug = on
            if ns.ShowDebugTab then ns.ShowDebugTab() end
        end)

    ShowSection(ns.db.optionsSection)

    -- footer: key bindings and credits, below a thin line
    local line = options:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", 16, 52)
    line:SetPoint("BOTTOMRIGHT", -16, 52)

    local keys = options:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    keys:SetPoint("BOTTOMLEFT", 16, 32)
    ns.LText(keys, "Key bindings: Esc > Options > Keybindings > AddOns > Gathercraft")

    local credits = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    credits:SetPoint("BOTTOMLEFT", 16, 14)
    credits:SetPoint("BOTTOMRIGHT", -16, 14)
    credits:SetJustifyH("LEFT")
    ns.LText(credits, "Gathercraft by pheenixlawl · GPLv3  ·  Data: Questie, SkillUp Forever (cjber)  ·  Map pins: HereBeDragons")

    local discord = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    discord:SetSize(110, 22)
    discord:SetPoint("BOTTOMRIGHT", -16, 26)
    discord:SetText("Discord")
    discord:SetScript("OnClick", function() ns.ShowDiscord() end)
end

-- Discord invite: a small popup with the link ready to copy (Ctrl+C)
local DISCORD = "https://discord.gg/Q6kH368qGC"
ns.DISCORD = DISCORD
function ns.ShowDiscord()
    if StaticPopupDialogs and StaticPopup_Show then
        StaticPopupDialogs.GATHERCRAFT_DISCORD = StaticPopupDialogs.GATHERCRAFT_DISCORD or {
            text = "",
            button1 = OKAY or "OK",
            hasEditBox = true,
            editBoxWidth = 260,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnShow = function(self)
                local eb = self.editBox or self.EditBox or (self.GetEditBox and self:GetEditBox())
                if eb then
                    eb:SetText(DISCORD)
                    eb:SetFocus()
                    eb:HighlightText()
                end
            end,
            EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        }
        StaticPopupDialogs.GATHERCRAFT_DISCORD.text = L["Join the Gathercraft Discord – press Ctrl+C to copy the link:"]
        StaticPopup_Show("GATHERCRAFT_DISCORD")
    end
    if ns.Print then ns.Print("Discord: " .. DISCORD) end
end

-- Puts the options into a tab of the main window
ns.EmbedOptions = function(parent)
    options:SetParent(parent)
    options:ClearAllPoints()
    options:SetAllPoints(parent)
    options:SetBackdrop(nil)
    options:SetMovable(false)
    options:SetScript("OnDragStart", nil)
    options:SetScript("OnDragStop", nil)
    options:SetFrameStrata(parent:GetFrameStrata())
    title:Hide()
    close:Hide()
    Layout(-4)
    tDeleteItem(UISpecialFrames, "GathercraftOptions")
    return options
end

local function ToggleOptions()
    options:SetShown(not options:IsShown())
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
local ICON = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\IconRound" -- round: fills the minimap button

-- LibDataBroker launcher + LibDBIcon: works with the plain minimap and with
-- ElvUI, minimap button collectors and broker displays like Titan Panel
local LDB = LibStub("LibDataBroker-1.1", true)
local DBIcon = LibStub("LibDBIcon-1.0", true)

local launcher = LDB and LDB:NewDataObject(ADDON_NAME, {
    type = "launcher",
    text = "Gathercraft",
    icon = ICON,
    OnClick = function(_, mouse)
        if mouse == "RightButton" then
            ToggleRun()
        elseif IsShiftKeyDown() then
            ns.ToggleOptions()
        elseif ns.ToggleMain then
            ns.ToggleMain()
        else
            ns.ToggleZones()
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:AddLine("Gathercraft")
        tooltip:AddLine(L["Left-click: open Gathercraft"], 1, 1, 1)
        tooltip:AddLine(ns.run and L["Right-click: stop farm run"] or L["Right-click: start farm run"], 1, 1, 1)
        tooltip:AddLine(L["Shift-click: options"], 1, 1, 1)
        tooltip:AddLine(L["Drag: move button"], 0.6, 0.6, 0.6)
    end,
})

local registered = false
local function UpdateMinimapButton()
    if not (launcher and DBIcon) then return end
    local db = ns.db
    if not db.minimap then
        -- take over the settings of the old self-made button
        db.minimap = { hide = db.minimapHidden or false, minimapPos = db.minimapAngle and (db.minimapAngle % 360) or 220 }
    end
    db.minimap.hide = db.minimapHidden or false
    if not registered then
        DBIcon:Register(ADDON_NAME, launcher, db.minimap)
        registered = true
        -- a bit bigger than the default so the round emblem fills the ring
        if DBIcon.SetButtonIcon then
            DBIcon:SetButtonIcon(ADDON_NAME, ICON, 22, "CENTER", 0, 0)
        end
    end
    if db.minimap.hide then DBIcon:Hide(ADDON_NAME) else DBIcon:Show(ADDON_NAME) end
end

---------------------------------------------------------------------------
-- Key bindings (see Bindings.xml)
---------------------------------------------------------------------------
BINDING_HEADER_GATHERCRAFT = "Gathercraft"
local function BindingNames()
    BINDING_NAME_GATHERCRAFT_TOGGLERUN = L["Start / stop farm run"]
    BINDING_NAME_GATHERCRAFT_SKIP = L["Skip current node (empty)"]
    BINDING_NAME_GATHERCRAFT_ZONES = L["Zones and materials window"]
end
BindingNames()
table.insert(ns.languageListeners, BindingNames)

function Gathercraft_ToggleRun() ToggleRun() end
function Gathercraft_Skip() ns.SkipNode() end
function Gathercraft_Zones() ns.ToggleZones() end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    Build()
    UpdateMinimapButton()
end)

ns.ToggleOptions = ns.ToggleOptions or ToggleOptions
ns.UpdateMinimapButton = UpdateMinimapButton
