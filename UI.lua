local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Farm panel (during a run) + Gathercraft arrow
--   Panel: what matters while farming: time, nodes gathered, nodes per
--   hour, gold per hour, skill points; the next node is the small print.
--   Arrow: our own navigation arrow pointing at the next node.
---------------------------------------------------------------------------
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local GOLD = { 1, 0.82, 0.30 }
local ARRIVE_YARDS = 12
local FILTER_LABELS = { herb = "Herbs", ore = "Ores", both = "Herbs + Ores", chest = "Chests" }

local function Skin(frame)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 32, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.10, 0.08, 0.07, 0.92)
    frame:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
end

local function Movable(frame, key)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.db[key] = { point = point, relPoint = relPoint, x = x, y = y }
    end)
end

local function Restore(frame, key)
    local pos = ns.db and ns.db[key]
    if pos then
        frame:ClearAllPoints()
        frame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end
end

---------------------------------------------------------------------------
-- Run stats
---------------------------------------------------------------------------
local stats -- { run = <run table>, start, nodes, value, skillStart }

local function TotalSkill()
    local sum = 0
    for _, t in ipairs({ "herb", "ore", "fish" }) do
        sum = sum + (ns.GetSkill(t) or 0)
    end
    return sum
end

-- "item:2770" (a skill plan's farm run) reads as the item's name
ns.RunFilterLabel = function(filter)
    local item = filter and tonumber(filter:match("^item:(%d+)$"))
    if item then return ns.ItemName and ns.ItemName(item) or filter end
    return filter
end

local function RunStats()
    local run = ns.run
    if not run then
        stats = nil
        return
    end
    if not stats or stats.run ~= run then
        stats = { run = run, start = run.startedAt or GetTime(), nodes = 0, value = 0, skillStart = TotalSkill() }
    end
    -- a run resumed right after login: professions are known a moment later
    if stats.skillStart == 0 then stats.skillStart = TotalSkill() end
    return stats
end

-- What the run brought so far (for the summary when it ends, Welcome.lua)
ns.RunSnapshot = function()
    local run, s = ns.run, stats
    if not (run and s and s.run == run) then return end
    local label = FILTER_LABELS[run.filter or ""] and L[FILTER_LABELS[run.filter]] or ns.RunFilterLabel(run.filter)
    local mapID = run.zone or (C_Map and C_Map.GetBestMapForUnit and ns.PlayerMap())
    return {
        label = label, zoneName = mapID and ns.GetZoneName(mapID), elapsed = GetTime() - s.start,
        nodes = s.nodes, value = s.value, valueSource = s.source,
        skill = math.max(0, TotalSkill() - s.skillStart),
    }
end

table.insert(ns.gatherListeners, function(node, p)
    local s = RunStats()
    if s then
        s.nodes = s.nodes + 1
        s.value = s.value + (p and p.value or 0)
        s.source = ns.BetterPriceSource(s.source, p and p.valueSource)
    end
end)

---------------------------------------------------------------------------
-- Farm panel
---------------------------------------------------------------------------
local panel = CreateFrame("Frame", "GathercraftPanel", UIParent, "BackdropTemplate")
panel:SetSize(340, 120)
panel:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
Skin(panel)
Movable(panel, "ui")
panel:Hide()

local emblem = panel:CreateTexture(nil, "OVERLAY")
emblem:SetSize(26, 26)
emblem:SetPoint("TOPLEFT", 8, -7)
emblem:SetTexture(MEDIA .. "IconRound")

-- Title and time share the top line: the time has a fixed place (wide
-- enough for "1:23:45") right before the "-" button, the title ends a few
-- pixels before the time and is cut with "..." (Sven, 08.11.: "Herbs + Ores
-- · Hillsbrad Foothills" ran into the time). Placed in Layout() below.
local CLOCK_WIDTH = 70
local title = panel:CreateFontString(nil, "OVERLAY")
title:SetFont(TITLE_FONT, 16, "")
title:SetTextColor(unpack(GOLD))
title:SetJustifyH("LEFT")
title:SetWordWrap(false)
title:SetPoint("LEFT", emblem, "RIGHT", 6, 0)
panel.title = title

local clock = panel:CreateFontString(nil, "OVERLAY")
clock:SetFont(TITLE_FONT, 16, "")
clock:SetTextColor(1, 0.95, 0.85)
clock:SetJustifyH("RIGHT")
clock:SetWordWrap(false)
clock:SetWidth(CLOCK_WIDTH)
clock:SetPoint("TOPRIGHT", -10, -11)
panel.clock = clock

-- A cut title shows the whole of it in a tooltip; dragging the title still
-- moves the window
local titleHit = CreateFrame("Frame", nil, panel)
titleHit:SetPoint("TOPLEFT", title, "TOPLEFT")
titleHit:SetPoint("BOTTOMRIGHT", title, "BOTTOMRIGHT")
titleHit:EnableMouse(true)
titleHit:RegisterForDrag("LeftButton")
titleHit:SetScript("OnDragStart", function() panel:StartMoving() end)
titleHit:SetScript("OnDragStop", function()
    local stop = panel:GetScript("OnDragStop")
    if stop then stop(panel) end
end)
titleHit:SetScript("OnEnter", function(self)
    if not (title.IsTruncated and title:IsTruncated()) then return end
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(title:GetText(), 1, 1, 1)
    GameTooltip:Show()
end)
titleHit:SetScript("OnLeave", GameTooltip_Hide)
panel.titleHit = titleHit

-- Four big numbers: gathered, per hour, gold per hour, skill points
local cells, cellLabels = {}, {}
for i, label in ipairs({ "gathered", "per hour", "gold / h", "skill" }) do
    local value = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    value:SetPoint("TOP", panel, "TOPLEFT", 8 + (i - 0.5) * 81, -40)
    local text = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("TOP", value, "BOTTOM", 0, -1)
    ns.LText(text, label)
    cells[i], cellLabels[i] = value, text
end

local nextText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
nextText:SetPoint("BOTTOMLEFT", 10, 12)
nextText:SetWidth(212)
nextText:SetJustifyH("LEFT")
nextText:SetWordWrap(false)
panel.nextText = nextText

local stopButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
stopButton:SetSize(52, 20)
stopButton:SetPoint("BOTTOMRIGHT", -8, 8)
ns.LText(stopButton, "Stop")
stopButton:SetScript("OnClick", function()
    if panel.fishing then
        ns.StopFishing(true)
        panel:Hide()
    else
        ns.StopRun()
    end
end)

local skipButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
skipButton:SetSize(52, 20)
skipButton:SetPoint("RIGHT", stopButton, "LEFT", -4, 0)
ns.LText(skipButton, "Skip")
skipButton:SetScript("OnClick", function() ns.SkipNode() end)

-- "-" / "+": one slim line (title, time, next node and distance, Skip,
-- Stop) or the full panel. Remembered (ns.db.panelCompact), the same for
-- farm runs and fishing.
local compactButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
compactButton:SetSize(20, 20)
panel.compactButton = compactButton

local function Layout()
    local compact = ns.db and ns.db.panelCompact
    for i = 1, #cells do
        cells[i]:SetShown(not compact)
        cellLabels[i]:SetShown(not compact)
    end
    emblem:ClearAllPoints()
    title:ClearAllPoints()
    clock:ClearAllPoints()
    nextText:ClearAllPoints()
    stopButton:ClearAllPoints()
    skipButton:ClearAllPoints()
    compactButton:ClearAllPoints()
    if compact then
        panel:SetSize(450, 32)
        emblem:SetSize(20, 20)
        emblem:SetPoint("LEFT", 6, 0)
        title:SetPoint("LEFT", emblem, "RIGHT", 4, 0)
        title:SetWidth(100)
        compactButton:SetPoint("RIGHT", -6, 0)
        stopButton:SetPoint("RIGHT", compactButton, "LEFT", -4, 0)
        skipButton:SetPoint("RIGHT", stopButton, "LEFT", -4, 0)
        clock:SetPoint("RIGHT", skipButton, "LEFT", -6, 0)
        -- the next node fills what is left between title and time
        nextText:SetPoint("LEFT", title, "RIGHT", 6, 0)
        nextText:SetPoint("RIGHT", clock, "LEFT", -6, 0)
        nextText:SetWidth(0)
        compactButton:SetText("+")
    else
        panel:SetSize(340, 120)
        emblem:SetSize(26, 26)
        emblem:SetPoint("TOPLEFT", 8, -7)
        compactButton:SetPoint("TOPRIGHT", -6, -8)
        clock:SetPoint("RIGHT", compactButton, "LEFT", -6, 0)
        title:SetPoint("LEFT", emblem, "RIGHT", 6, 0)
        title:SetPoint("RIGHT", clock, "LEFT", -6, 0)
        title:SetWidth(0)
        nextText:SetPoint("BOTTOMLEFT", 10, 12)
        nextText:SetWidth(212)
        stopButton:SetPoint("BOTTOMRIGHT", -8, 8)
        skipButton:SetPoint("RIGHT", stopButton, "LEFT", -4, 0)
        compactButton:SetText("-")
    end
end
ns.PanelLayout = Layout
compactButton:SetScript("OnClick", function()
    ns.db.panelCompact = not ns.db.panelCompact or nil
    Layout()
end)
compactButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(ns.db.panelCompact and L["Show the whole panel"] or L["One slim line"], 1, 1, 1)
    GameTooltip:Show()
end)
compactButton:SetScript("OnLeave", GameTooltip_Hide)

local function Clock(elapsed)
    local e = math.floor(elapsed)
    if e >= 3600 then
        return ("%d:%02d:%02d"):format(math.floor(e / 3600), math.floor(e % 3600 / 60), e % 60)
    end
    return ("%d:%02d"):format(math.floor(e / 60), e % 60)
end

-- No farm run but fishing: the same panel shows the fishing session
local function UpdateFishingPanel(f)
    local elapsed = GetTime() - f.start
    local hours = math.max(elapsed / 3600, 1 / 60)
    ns.LText(title, "Fishing")
    clock:SetText(Clock(elapsed))
    cells[1]:SetText(f.catches)
    cellLabels[1]:SetText(L["caught"])
    cells[2]:SetText(math.floor(f.catches / hours + 0.5))
    cells[3]:SetText(ns.Money and ns.Money(f.value / hours, true) or "-")
    cellLabels[3]:SetText(f.source == "vendor" and L["gold / h (vendor)"] or L["gold / h"])
    local now = ns.GetSkill("fish") or 0
    cells[4]:SetText((L["|cff55ff55+%d|r"]):format(math.max(0, now - (f.skillStart or now))))
    local lure = ns.LureTimeLeft and ns.LureTimeLeft()
    nextText:SetText(lure and (L["|cffaaaaaaLure:|r %d min left  |cffaaaaaa· worth %s|r"]):format(math.ceil(lure / 60), ns.Money(f.value))
        or (L["|cffaaaaaaNo lure  · worth|r %s"]):format(ns.Money and ns.Money(f.value) or "-"))
    skipButton:Hide()
    if not panel:IsShown() then panel:Show() end
end

local function UpdatePanel()
    local run = ns.run
    if not run then
        RunStats()
        local f = ns.FishingSession and ns.FishingSession()
        if f then
            panel.fishing = true
            -- "Hide the fishing window" (Options): the session goes on without it
            if ns.db.fishPanelHidden then
                if panel:IsShown() then panel:Hide() end
                return
            end
            UpdateFishingPanel(f)
            return
        end
        panel.fishing = nil
        if panel:IsShown() then panel:Hide() end
        return
    end
    panel.fishing = nil
    -- the numbers count from the start of the run, shown or not (Codex M1:
    -- hidden from the start, they began with the first gather)
    local s = RunStats()
    -- "Hide the run window" (Options): arrow, target ring and minimap guide on
    if ns.db.runPanelHidden then
        if panel:IsShown() then panel:Hide() end
        return
    end
    skipButton:Show()
    cellLabels[1]:SetText(L["gathered"])
    local elapsed = GetTime() - s.start
    local hours = math.max(elapsed / 3600, 1 / 60)

    local label = FILTER_LABELS[run.filter or ""] and L[FILTER_LABELS[run.filter]] or ns.RunFilterLabel(run.filter)
    if run.zone then label = (label and (label .. " · ") or "") .. ns.GetZoneName(run.zone) end
    title:SetText(L["Farm run"] .. (label and ("  |cffaaaaaa" .. label .. "|r") or ""))
    if elapsed >= 3600 then
        local e = math.floor(elapsed)
        clock:SetText(("%d:%02d:%02d"):format(math.floor(e / 3600), math.floor(e % 3600 / 60), e % 60))
    else
        local e = math.floor(elapsed)
        clock:SetText(("%d:%02d"):format(math.floor(e / 60), e % 60))
    end
    cells[1]:SetText(s.nodes)
    cells[2]:SetText(math.floor(s.nodes / hours + 0.5))
    cells[3]:SetText(ns.Money and ns.Money(s.value / hours, true) or "-")
    cellLabels[3]:SetText(s.source == "vendor" and L["gold / h (vendor)"] or L["gold / h"])
    cells[4]:SetText((L["|cff55ff55+%d|r"]):format(math.max(0, TotalSkill() - s.skillStart)))

    local left = run.path and #run.path or 0
    local t = run.target
    if t then
        local dist = ns.DistanceToTarget()
        nextText:SetText((L["|cffaaaaaaNext:|r %s  |cffaaaaaa%s · %d left|r"]):format(
            t.name, dist and (L["%d yd"]):format(math.floor(dist)) or "?", left))
        skipButton:Enable()
    else
        local wait = run.nextRespawn and run.nextRespawn - time()
        if wait and wait > 0 then
            local s = math.ceil(wait)
            nextText:SetText((L["|cffaaaaaaWaiting for respawns · next in ~%s|r"]):format(("%d:%02d"):format(math.floor(s / 60), s % 60)))
        else
            nextText:SetText((L["|cffaaaaaaWaiting for respawns · round %d|r"]):format(run.round or 1))
        end
        skipButton:Disable()
    end
    if not panel:IsShown() then panel:Show() end
end

---------------------------------------------------------------------------
-- Gathercraft arrow
---------------------------------------------------------------------------
local arrowFrame = CreateFrame("Frame", "GathercraftArrow", UIParent)
arrowFrame:SetSize(80, 100)
arrowFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 300)
Movable(arrowFrame, "arrowPos")
arrowFrame:Hide()

local arrow = arrowFrame:CreateTexture(nil, "ARTWORK")
arrow:SetSize(64, 64)
arrow:SetPoint("TOP", 0, 0)
arrow:SetTexture(MEDIA .. "Arrow")

local arrowDist = arrowFrame:CreateFontString(nil, "OVERLAY")
arrowDist:SetFont(TITLE_FONT, 15, "OUTLINE")
arrowDist:SetTextColor(1, 0.95, 0.85)
arrowDist:SetPoint("TOP", arrow, "BOTTOM", 0, -2)

local arrowName = arrowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
arrowName:SetPoint("TOP", arrowDist, "BOTTOM", 0, -1)

local function ArrowTarget()
    local run = ns.run
    if not (HBD and run and run.targetPoint and run.target) or ns.db.arrowHidden then return end
    local px, py, instance = HBD:GetPlayerWorldPosition()
    if not px or instance ~= run.instance then return end
    local facing = ns.Readable(GetPlayerFacing and GetPlayerFacing(), "position")
    if not facing then return end -- no facing info (e.g. in instances)
    local angle, dist = HBD:GetWorldVector(instance, px, py, run.targetPoint.wx, run.targetPoint.wy)
    if not angle then return end
    return angle - facing, dist, run.target
end

local elapsedArrow = 0
arrowFrame:SetScript("OnUpdate", function(self, elapsed)
    elapsedArrow = elapsedArrow + elapsed
    if elapsedArrow < 0.03 then return end
    elapsedArrow = 0
    local rot, dist, node = ArrowTarget()
    if not rot then
        self:Hide()
        return
    end
    arrow:SetRotation(rot)
    if dist <= ARRIVE_YARDS then
        arrow:SetVertexColor(0.55, 1, 0.55)
        ns.LText(arrowDist, "Here!")
    else
        arrow:SetVertexColor(1, 1, 1)
        arrowDist:SetText((L["%d yd"]):format(math.floor(dist)))
    end
    arrowName:SetText(node.name)
end)

local function UpdateArrow()
    if ArrowTarget() then
        if not arrowFrame:IsShown() then arrowFrame:Show() end
    elseif arrowFrame:IsShown() then
        arrowFrame:Hide()
    end
end
ns.UpdateArrow = UpdateArrow

---------------------------------------------------------------------------
-- Init
---------------------------------------------------------------------------
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    Layout()
    Restore(panel, "ui")
    Restore(arrowFrame, "arrowPos")
    C_Timer.NewTicker(0.25, function()
        UpdatePanel()
        UpdateArrow()
    end)
end)
