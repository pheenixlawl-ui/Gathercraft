local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- First start, updates and the end of a farm run
--   Welcome     : once after a fresh install, three steps to get going
--                 (/gcr welcome shows it again)
--   What's new  : one chat line after an update (/gcr whatsnew)
--   Run summary : when a farm run ends, what it brought - shared in guild
--                 or party chat only when you click the button
---------------------------------------------------------------------------
local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local GOLD = { 1, 0.82, 0.30 }
local SUMMARY_MIN_SECONDS = 120 -- shorter runs (a quick try) get no summary
local SUMMARY_MIN_NODES = 1

-- Highlights per version, one line each (translated in Locales)
local WHATS_NEW = {
    ["0.1.13"] = "A skill plan with a material list (Crafting tab), a summary at the end of every farm run, and right-click farms the zone you are in.",
}

local function Version()
    if C_AddOns and C_AddOns.GetAddOnMetadata then
        return C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
    end
    return GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version")
end

---------------------------------------------------------------------------
-- A small window in the look of the main window
---------------------------------------------------------------------------
local function Card(name, width, height)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetPoint("CENTER", 0, 120)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 11, top = 11, bottom = 11 },
    })
    f:SetBackdropColor(0.10, 0.08, 0.07, 0.97)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    tinsert(UISpecialFrames, name)

    local glow = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    glow:SetPoint("TOPLEFT", 12, -12)
    glow:SetPoint("TOPRIGHT", -12, -12)
    glow:SetHeight(64)
    glow:SetColorTexture(1, 1, 1, 1)
    if not (CreateColor and pcall(glow.SetGradient, glow, "VERTICAL",
            CreateColor(0.05, 0.02, 0.01, 0), CreateColor(0.45, 0.13, 0.04, 0.55))) then
        glow:SetColorTexture(0.45, 0.13, 0.04, 0.2)
    end

    local emblem = f:CreateTexture(nil, "OVERLAY")
    emblem:SetSize(64, 64)
    emblem:SetPoint("TOPLEFT", -12, 12)
    emblem:SetTexture(MEDIA .. "Icon")

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont(TITLE_FONT, 22, "OUTLINE")
    f.title:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    f.title:SetShadowColor(0, 0, 0, 1)
    f.title:SetShadowOffset(2, -2)
    f.title:SetPoint("TOPLEFT", 60, -20)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    return f
end

ns.MakeCard = Card

local function Button(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 24)
    ns.LText(b, text)
    return b
end

---------------------------------------------------------------------------
-- Welcome
---------------------------------------------------------------------------
local STEPS = {
    { icon = "Interface\\Icons\\INV_Misc_Map_01", title = "Your map is ready",
      text = "25,000+ herb and ore spots are already on your map and minimap. The Zones tab picks what you see." },
    { icon = "Interface\\Icons\\Ability_Mount_RidingHorse", title = "Start a farm run",
      text = "Click the emblem at your minimap: Farm run - Herbs, Ores or both. Ride to the gold ring; the route plans itself." },
    { icon = "Interface\\Icons\\INV_Misc_Spyglass_02", title = "Point at the minimap",
      text = "Hover a herb or vein your tracking shows on the minimap: Gathercraft learns the spot without riding there." },
}

local welcome
local function BuildWelcome()
    welcome = Card("GathercraftWelcome", 470, 370)
    ns.LText(welcome.title, "Welcome to Gathercraft")
    local tag = welcome:CreateFontString(nil, "OVERLAY")
    tag:SetFont(TITLE_FONT, 13, "")
    tag:SetTextColor(0.85, 0.78, 0.62)
    tag:SetPoint("TOPLEFT", welcome.title, "BOTTOMLEFT", 2, -2)
    ns.LText(tag, "Gather  ·  Route  ·  Profit")

    local y = -84
    for _, step in ipairs(STEPS) do
        local icon = welcome:CreateTexture(nil, "ARTWORK")
        icon:SetSize(36, 36)
        icon:SetPoint("TOPLEFT", 26, y)
        icon:SetTexture(step.icon)
        local head = welcome:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        head:SetPoint("TOPLEFT", icon, "TOPRIGHT", 12, 0)
        head:SetJustifyH("LEFT")
        ns.LText(head, step.title)
        local text = welcome:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
        text:SetWidth(360)
        text:SetJustifyH("LEFT")
        ns.LText(text, step.text)
        y = y - 72
    end

    local share = welcome:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    share:SetPoint("BOTTOMLEFT", 26, 52)
    share:SetWidth(420)
    share:SetJustifyH("LEFT")
    ns.LText(share, "Sharing is on: spots you harvest help other Gathercraft players, and theirs help you (Options - Sharing).")

    local open = Button(welcome, "Open Gathercraft", 150)
    open:SetPoint("BOTTOMRIGHT", welcome, "BOTTOM", -6, 20)
    open:SetScript("OnClick", function()
        welcome:Hide()
        local main = _G.GathercraftMain
        if ns.ToggleMain and not (main and main:IsShown()) then ns.ToggleMain("overview") end
    end)
    local ok = Button(welcome, "Got it", 150)
    ok:SetPoint("BOTTOMLEFT", welcome, "BOTTOM", 6, 20)
    ok:SetScript("OnClick", function() welcome:Hide() end)
    welcome:SetScript("OnHide", function() ns.db.welcomeSeen = true end)
end

local function ShowWelcome()
    if not welcome then BuildWelcome() end
    welcome:Show()
end
ns.ShowWelcome = ShowWelcome

local function WhatsNew(always)
    local v = Version()
    local text = v and WHATS_NEW[v]
    if text then
        ns.Print((L["New in %s: %s"]):format(v, L[text]))
    elseif always then
        ns.Print(L["All changes: Gathercraft's page on CurseForge (Changelog)."])
    end
end
ns.WhatsNew = WhatsNew

---------------------------------------------------------------------------
-- Run summary
---------------------------------------------------------------------------
local summary, cells, subLine, perHourLine, shareGuild, shareParty
local lastSummary

-- Money as plain text: chat messages can't carry the coin icons
local function PlainMoney(copper)
    copper = math.floor((copper or 0) + 0.5)
    local g, s = math.floor(copper / 10000), math.floor(copper % 10000 / 100)
    if g > 0 then return ("%dg %ds"):format(g, s) end
    return ("%ds %dc"):format(s, copper % 100)
end

local function Duration(seconds)
    local e = math.floor(seconds)
    if e >= 3600 then
        return ("%d:%02d:%02d"):format(math.floor(e / 3600), math.floor(e % 3600 / 60), e % 60)
    end
    return ("%d:%02d"):format(math.floor(e / 60), e % 60)
end

local function ShareText(s)
    local hours = math.max(s.elapsed / 3600, 1 / 60)
    local text = (L["[Gathercraft] Farm run: %d nodes in %s (%d per hour, %s per hour, +%d skill)"]):format(
        s.nodes, Duration(s.elapsed), math.floor(s.nodes / hours + 0.5), PlainMoney(s.value / hours), s.skill)
    if s.zoneName then text = text .. " - " .. s.zoneName end
    return (text:gsub("|", ""))
end

-- your own group or raid, not a battleground's
local HOME = LE_PARTY_CATEGORY_HOME
local function InGroup() return IsInGroup and IsInGroup(HOME) end
local function InRaid() return IsInRaid and IsInRaid(HOME) end

local function Share(chatType)
    if not lastSummary then return end
    if chatType == "GUILD" and not (IsInGuild and IsInGuild()) then return end
    if chatType ~= "GUILD" then
        if not InGroup() then return end
        chatType = InRaid() and "RAID" or "PARTY"
    end
    local text = ShareText(lastSummary)
    if C_ChatInfo and C_ChatInfo.SendChatMessage then
        C_ChatInfo.SendChatMessage(text, chatType)
    else
        ---@diagnostic disable-next-line: deprecated -- clients without C_ChatInfo.SendChatMessage
        SendChatMessage(text, chatType)
    end
    summary:Hide()
end

local function BuildSummary()
    summary = Card("GathercraftRunSummary", 430, 230)
    ns.LText(summary.title, "Farm run done")
    subLine = summary:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subLine:SetPoint("TOPLEFT", summary.title, "BOTTOMLEFT", 2, -4)
    subLine:SetWidth(330)
    subLine:SetJustifyH("LEFT")
    subLine:SetWordWrap(false)

    cells = {}
    for i, label in ipairs({ "gathered", "per hour", "worth", "skill" }) do
        local value = summary:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        value:SetPoint("TOP", summary, "TOPLEFT", 20 + (i - 0.5) * 97, -86)
        local text = summary:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        text:SetPoint("TOP", value, "BOTTOM", 0, -2)
        ns.LText(text, label)
        cells[i] = value
    end
    perHourLine = summary:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    perHourLine:SetPoint("TOP", summary, "TOP", 0, -140)

    shareGuild = Button(summary, "Share in guild", 124)
    shareGuild:SetPoint("BOTTOMLEFT", 22, 20)
    shareGuild:SetScript("OnClick", function() Share("GUILD") end)
    shareParty = Button(summary, "Share in group", 124)
    shareParty:SetPoint("LEFT", shareGuild, "RIGHT", 6, 0)
    shareParty:SetScript("OnClick", function() Share("PARTY") end)
    local close = Button(summary, "Close", 110)
    close:SetPoint("BOTTOMRIGHT", -22, 20)
    close:SetScript("OnClick", function() summary:Hide() end)
    for _, b in ipairs({ shareGuild, shareParty }) do
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(L["Posts this line in chat:"], 1, 0.82, 0)
            GameTooltip:AddLine(lastSummary and ShareText(lastSummary) or "", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
end

-- s = { label, zoneName, elapsed, nodes, value, valueSource, skill }
local function ShowRunSummary(s)
    if not s or ns.db.summaryOff then return end
    if s.elapsed < SUMMARY_MIN_SECONDS or s.nodes < SUMMARY_MIN_NODES then return end
    if not summary then BuildSummary() end
    lastSummary = s
    local hours = math.max(s.elapsed / 3600, 1 / 60)
    local parts = {}
    if s.label then parts[#parts + 1] = s.label end
    if s.zoneName then parts[#parts + 1] = s.zoneName end
    parts[#parts + 1] = Duration(s.elapsed)
    subLine:SetText(table.concat(parts, "  ·  "))
    cells[1]:SetText(s.nodes)
    cells[2]:SetText(math.floor(s.nodes / hours + 0.5))
    cells[3]:SetText(ns.Money and ns.Money(s.value, true) or PlainMoney(s.value))
    cells[4]:SetText((L["|cff55ff55+%d|r"]):format(s.skill))
    perHourLine:SetText((s.valueSource == "vendor" and L["%s per hour (vendor price)"] or L["%s per hour"]):format(
        ns.Money and ns.Money(s.value / hours, true) or PlainMoney(s.value / hours)))
    if IsInGuild and IsInGuild() then shareGuild:Enable() else shareGuild:Disable() end
    if InGroup() then shareParty:Enable() else shareParty:Disable() end
    summary:Show()
end
ns.ShowRunSummary = ShowRunSummary
ns.ShareRunSummary = Share

---------------------------------------------------------------------------
-- Login
---------------------------------------------------------------------------
-- new player: the welcome; after an update: one line about what's new
local function OnLogin()
    local db = ns.db
    if not db then return end
    local v = Version()
    if ns.freshInstall and not db.welcomeSeen then
        ShowWelcome()
    else
        db.welcomeSeen = true
        if v and db.lastVersion ~= v then WhatsNew() end
    end
    db.lastVersion = v
end
ns.WelcomeOnLogin = OnLogin

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    C_Timer.After(5, OnLogin)
end)
