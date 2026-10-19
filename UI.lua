local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Farm panel
---------------------------------------------------------------------------
local panel = CreateFrame("Frame", "WoWFFarmPanel", UIParent, "BackdropTemplate")
panel:SetSize(230, 78)
panel:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
panel:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
panel:SetBackdropColor(0, 0, 0, 0.8)
panel:SetClampedToScreen(true)
panel:SetMovable(true)
panel:EnableMouse(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ns.db.ui = { point = point, relPoint = relPoint, x = x, y = y }
end)
panel:Hide()

local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOPLEFT", 10, -10)
title:SetText("WoWFFarm")

local targetText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
targetText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)

local infoText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
infoText:SetPoint("TOPLEFT", targetText, "BOTTOMLEFT", 0, -4)

local stopButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
stopButton:SetSize(56, 20)
stopButton:SetPoint("BOTTOMRIGHT", -8, 8)
stopButton:SetText("Stop")
stopButton:SetScript("OnClick", function() ns.StopRun() end)

local skipButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
skipButton:SetSize(56, 20)
skipButton:SetPoint("RIGHT", stopButton, "LEFT", -4, 0)
skipButton:SetText("Skip")
skipButton:SetScript("OnClick", function() ns.SkipNode() end)

---------------------------------------------------------------------------
-- Live update
---------------------------------------------------------------------------
local function CountVisited(visited)
    local n = 0
    for _ in pairs(visited) do n = n + 1 end
    return n
end

local function Update()
    local run = ns.run
    if not run or not run.target then
        if panel:IsShown() then panel:Hide() end
        return
    end

    local t = run.target
    targetText:SetText(t.name)

    local mapID, x, y = ns.GetPlayerPos()
    local distText = "?"
    if mapID and mapID == run.mapID then
        distText = ("%d yd"):format(ns.Distance(mapID, x, y, t.x, t.y))
    end
    infoText:SetText(("%s  |  Round %d  |  %d done"):format(
        distText, run.round, CountVisited(run.visited)))

    if not panel:IsShown() then panel:Show() end
end

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    local ui = ns.db and ns.db.ui
    if ui then
        panel:ClearAllPoints()
        panel:SetPoint(ui.point, UIParent, ui.relPoint, ui.x, ui.y)
    end
    C_Timer.NewTicker(0.2, Update)
end)