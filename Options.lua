local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Minimap button, options window and key bindings
---------------------------------------------------------------------------
local BUTTON_RIM_OFFSET = 10 -- pixels outside the minimap edge
local PIN_SIZE_MIN, PIN_SIZE_MAX, PIN_SIZE_DEFAULT = 8, 24, 14

local function ToggleRun()
    if ns.run then
        ns.StopRun()
    else
        ns.StartRun("")
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
    nextY = nextY - 20
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
    nextY = nextY - 26
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

    AddHeader("Other")
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
    hint:SetWidth(290)
    hint:SetJustifyH("LEFT")
    hint:SetText("Key bindings: Esc > Options > Keybindings > AddOns > Gathercraft")
end

local function ToggleOptions()
    options:SetShown(not options:IsShown())
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
local button = CreateFrame("Button", "GathercraftMinimapButton", Minimap)
button:SetSize(31, 31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")
button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local bg = button:CreateTexture(nil, "BACKGROUND")
bg:SetSize(20, 20)
bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
bg:SetPoint("TOPLEFT", 7, -5)

local icon = button:CreateTexture(nil, "ARTWORK")
icon:SetSize(18, 18)
icon:SetTexture("Interface\\Icons\\INV_Misc_Flower_02")
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
icon:SetPoint("TOPLEFT", 7, -6)

local border = button:CreateTexture(nil, "OVERLAY")
border:SetSize(53, 53)
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetPoint("TOPLEFT")

local function PlaceButton()
    local angle = math.rad(ns.db.minimapAngle or 220)
    -- Sit on the rim, whatever size this client's minimap has
    local radius = (Minimap:GetWidth() or 140) / 2 + BUTTON_RIM_OFFSET
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function DragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    local atan2 = math.atan2 or atan2
    ns.db.minimapAngle = math.deg(atan2(cy - my, cx - mx))
    PlaceButton()
end

button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", DragUpdate)
end)
button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)

button:SetScript("OnClick", function(self, mouse)
    if mouse == "RightButton" then
        ToggleRun()
    elseif IsShiftKeyDown() then
        ToggleOptions()
    else
        ns.ToggleZones()
    end
end)

button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Gathercraft")
    GameTooltip:AddLine("Left-click: zones and materials", 1, 1, 1)
    GameTooltip:AddLine(ns.run and "Right-click: stop farm run" or "Right-click: start farm run", 1, 1, 1)
    GameTooltip:AddLine("Shift-click: options", 1, 1, 1)
    GameTooltip:AddLine("Drag: move button", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function UpdateMinimapButton()
    if ns.db.minimapHidden then
        button:Hide()
    else
        PlaceButton()
        button:Show()
    end
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

ns.ToggleOptions = ToggleOptions
ns.UpdateMinimapButton = UpdateMinimapButton
