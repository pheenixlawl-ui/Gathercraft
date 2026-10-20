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
        ns.StartRun("both")
    end
end

---------------------------------------------------------------------------
-- Options window
---------------------------------------------------------------------------
local options = CreateFrame("Frame", "GathercraftOptions", UIParent, "BackdropTemplate")
options:SetSize(740, 440)
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

local controls = {}
local TOP_Y = -44
local COLUMN_X = { 14, 380 } -- two columns, the main window is wide
local colX, nextY = COLUMN_X[1], TOP_Y

local function Column(n)
    colX, nextY = COLUMN_X[n], TOP_Y
end

local function AddHeader(text)
    local fs = options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", colX + 2, nextY)
    ns.LText(fs, text)
    nextY = nextY - 20
end

-- get() returns the current state, set(on) changes it
local function AddCheck(label, get, set)
    local cb = CreateFrame("CheckButton", nil, options, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", colX, nextY)
    local fs = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    ns.LText(fs, label)
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        options:Refresh()
    end)
    cb.get = get
    controls[#controls + 1] = cb
    nextY = nextY - 24
end

-- Farm runs: how close you must get before the arrow moves to the next node
local arriveText
local function AddArrive()
    local label = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Next node at")

    local minus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + 106, nextY)
    minus:SetText("-")

    arriveText = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    arriveText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    arriveText:SetWidth(40)

    local plus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", arriveText, "RIGHT", 6, 0)
    plus:SetText("+")

    local hint = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
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
    local label = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", colX + 6, nextY - 4)
    ns.LText(label, "Pin size")

    local minus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + 106, nextY)
    minus:SetText("-")

    pinSizeText = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pinSizeText:SetPoint("LEFT", minus, "RIGHT", 10, 0)
    pinSizeText:SetWidth(24)

    local plus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", pinSizeText, "RIGHT", 10, 0)
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
    local minus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", colX + 6, nextY)
    minus:SetText("<")

    languageText = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    languageText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    languageText:SetWidth(170)

    local plus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", languageText, "RIGHT", 6, 0)
    plus:SetText(">")

    local reload = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    reload:SetSize(90, 20)
    reload:SetPoint("LEFT", plus, "RIGHT", 10, 0)
    ns.LText(reload, "Reload UI")
    reload:SetScript("OnClick", function() ReloadUI() end)

    local hint = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", colX + 6, nextY - 24)
    ns.LText(hint, "Most texts change at once, all of them after a reload")

    local function Change(delta)
        local list, index = ns.LANGUAGES, 1
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

function options:Refresh()
    for _, cb in ipairs(controls) do
        cb:SetChecked(cb.get())
    end
    if arriveText and ns.ArriveDistance then
        arriveText:SetText(ns.ArriveDistance() .. L[" yd"])
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

local function Build()
    Column(1)
    AddHeader("Map")
    AddCheck("Show nodes on map and minimap",
        function() return not ns.db.pinsHidden end,
        function(on)
            ns.db.pinsHidden = not on
            ns.NotifyNodesChanged()
        end)
    AddPinSize()
    AddCheck("Show Gathercraft arrow during farm runs",
        function() return not ns.db.arrowHidden end,
        function(on)
            ns.db.arrowHidden = not on
            if ns.UpdateArrow then ns.UpdateArrow() end
        end)
    AddArrive()
    AddCheck("Show route line",
        function() return not ns.db.routeLineHidden end,
        function(on)
            if (not ns.db.routeLineHidden) ~= on then ns.ToggleRouteLine() end
        end)

    nextY = nextY - 8
    AddHeader("Sync")
    AddCheck("Share nodes with other players",
        function() return ns.db.sync and ns.db.sync.enabled end,
        function(on) ns.SyncCommand(on and "on" or "off") end)
    AddCheck("Public channel (off = guild and friends only)",
        function() return ns.db.sync and ns.db.sync.public end,
        function(on)
            if ns.db.sync.public ~= on then ns.SyncCommand("public") end
        end)

    nextY = nextY - 8
    AddHeader("Language")
    AddLanguage()

    Column(2)
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

    nextY = nextY - 8
    AddHeader("Fishing")
    AddCheck("Fish key applies a lure when the pole has none",
        function() return ns.db.fishLure ~= false end,
        function(on) ns.db.fishLure = on end)

    nextY = nextY - 8
    AddHeader("Other")
    AddCheck("Price alerts in chat (hot items you gather)",
        function() return ns.db.priceAlerts ~= false end,
        function(on) ns.db.priceAlerts = on end)
    AddCheck("Auction prices in item tooltips",
        function() return ns.db.tooltipPrices ~= false end,
        function(on) ns.db.tooltipPrices = on end)
    AddCheck("Minimap button",
        function() return not ns.db.minimapHidden end,
        function(on)
            ns.db.minimapHidden = not on
            ns.UpdateMinimapButton()
        end)
    AddCheck("Debug output (chat tab \"Gathercraft\")",
        function() return ns.db.debug end,
        function(on) ns.db.debug = on end)

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
