local ADDON_NAME, ns = ...

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
options:SetSize(320, 360)
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
title:SetText("Gathercraft - Options")

local close = CreateFrame("Button", nil, options, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)

local controls = {}
local nextY = -44

local function AddHeader(text)
    local fs = options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", 16, nextY)
    fs:SetText(text)
    nextY = nextY - 18
end

-- get() returns the current state, set(on) changes it
local function AddCheck(label, get, set)
    local cb = CreateFrame("CheckButton", nil, options, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("TOPLEFT", 14, nextY)
    local fs = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    fs:SetText(label)
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        options:Refresh()
    end)
    cb.get = get
    controls[#controls + 1] = cb
    nextY = nextY - 22
end

-- Farm runs: how close you must get before the arrow moves to the next node
local arriveText
local function AddArrive()
    local label = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 20, nextY - 4)
    label:SetText("Next node at")

    local minus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", 120, nextY)
    minus:SetText("-")

    arriveText = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    arriveText:SetPoint("LEFT", minus, "RIGHT", 6, 0)
    arriveText:SetWidth(40)

    local plus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    plus:SetSize(24, 20)
    plus:SetPoint("LEFT", arriveText, "RIGHT", 6, 0)
    plus:SetText("+")

    local hint = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", plus, "RIGHT", 10, 0)
    hint:SetText("(once you can see whether the node is there)")

    local function Change(delta)
        local lo, hi = ns.ARRIVE_LIMITS[1], ns.ARRIVE_LIMITS[2]
        ns.db.arriveDist = math.max(lo, math.min(hi, ns.ArriveDistance() + delta))
        options:Refresh()
    end
    minus:SetScript("OnClick", function() Change(-5) end)
    plus:SetScript("OnClick", function() Change(5) end)
    nextY = nextY - 30
end

local pinSizeText
local function AddPinSize()
    local label = options:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 20, nextY - 4)
    label:SetText("Pin size")

    local minus = CreateFrame("Button", nil, options, "UIPanelButtonTemplate")
    minus:SetSize(24, 20)
    minus:SetPoint("TOPLEFT", 120, nextY)
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

function options:Refresh()
    for _, cb in ipairs(controls) do
        cb:SetChecked(cb.get())
    end
    if arriveText and ns.ArriveDistance then
        arriveText:SetText(ns.ArriveDistance() .. " yd")
    end
    if pinSizeText then
        pinSizeText:SetText(tostring(ns.db.pinSize or PIN_SIZE_DEFAULT))
    end
end
options:SetScript("OnShow", options.Refresh)

local function Build()
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

    AddHeader("Sync")
    AddCheck("Share nodes with other players",
        function() return ns.db.sync and ns.db.sync.enabled end,
        function(on) ns.SyncCommand(on and "on" or "off") end)
    AddCheck("Public channel (off = guild and friends only)",
        function() return ns.db.sync and ns.db.sync.public end,
        function(on)
            if ns.db.sync.public ~= on then ns.SyncCommand("public") end
        end)

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

    AddHeader("Fishing")
    AddCheck("Fish key applies a lure when the pole has none",
        function() return ns.db.fishLure ~= false end,
        function(on) ns.db.fishLure = on end)

    AddHeader("Other")
    AddCheck("Price alerts in chat (something you can gather sells well)",
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

    local hint = options:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", 16, 14)
    hint:SetWidth(480)
    hint:SetJustifyH("LEFT")
    hint:SetText("Key bindings: Esc > Options > Keybindings > AddOns > Gathercraft\n|cff999999Gathercraft by pheenixlawl · Node data from Questie (github.com/Questie/Questie) · Map pins via HereBeDragons|r")
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
        tooltip:AddLine("Left-click: open Gathercraft", 1, 1, 1)
        tooltip:AddLine(ns.run and "Right-click: stop farm run" or "Right-click: start farm run", 1, 1, 1)
        tooltip:AddLine("Shift-click: options", 1, 1, 1)
        tooltip:AddLine("Drag: move button", 0.6, 0.6, 0.6)
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
BINDING_NAME_GATHERCRAFT_TOGGLERUN = "Start / stop farm run"
BINDING_NAME_GATHERCRAFT_SKIP = "Skip current node (empty)"
BINDING_NAME_GATHERCRAFT_ZONES = "Zones and materials window"

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
