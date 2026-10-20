local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Main window: forged frame, tabs on top (six per row; more tabs start a
-- new row and the window grows with them), the selected section below
--   Overview : profession bars, what to gather in this zone, session stats
--   Farm Spots / Crafting : Advisor.lua / Crafting.lua
--   Zones    : the zones/materials tree (Zones.lua)
--   Skills   : what we learned about skill-ups per node kind
--   Options  : the options (Options.lua)
---------------------------------------------------------------------------
local WIDTH, HEIGHT = 780, 640  -- height with one row of tabs
local TABS_PER_ROW = 6
local TAB_W, TAB_H, TAB_GAP, ROW_GAP = 117, 30, 6, 6
local TAB_TOP = -76              -- first row of tabs, below the title
local PAGE_WIDTH = WIDTH - 36 - 16 -- usable width of a section
local ICON = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\Icon"
local TITLE_FONT = "Fonts\\MORPHEUS.TTF"
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local TYPE_ICONS = {
    herb = "Interface\\Icons\\INV_Misc_Flower_02",
    ore = "Interface\\Icons\\INV_Ore_Copper_01",
    chest = "Interface\\Icons\\INV_Box_02",
}
local BAR_COLORS = {
    herb = { 0.30, 0.72, 0.28 }, ore = { 0.86, 0.52, 0.24 }, fish = { 0.25, 0.55, 0.90 },
    cook = { 0.80, 0.55, 0.20 }, aid = { 0.85, 0.25, 0.25 },
}
local GOLD = { 1, 0.82, 0.30 }
local EMBER = { 0.42, 0.10, 0.04 }
local LIST_ROWS = 10

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local main = CreateFrame("Frame", "GathercraftMain", UIParent, "BackdropTemplate")
main:SetSize(WIDTH, HEIGHT)
main:SetPoint("CENTER")
main:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 11, top = 11, bottom = 11 },
})
main:SetBackdropColor(0.10, 0.08, 0.07, 0.97)
main:SetFrameStrata("DIALOG")
main:SetToplevel(true)
main:SetClampedToScreen(true)
main:SetMovable(true)
main:EnableMouse(true)
main:RegisterForDrag("LeftButton")
main:SetScript("OnDragStart", main.StartMoving)
main:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ns.db.mainPos = { point = point, relPoint = relPoint, x = x, y = y }
end)
main:Hide()
tinsert(UISpecialFrames, "GathercraftMain")

-- Ember glow behind the header
local glow = main:CreateTexture(nil, "BACKGROUND", nil, 1)
glow:SetPoint("TOPLEFT", 12, -12)
glow:SetPoint("TOPRIGHT", -12, -12)
glow:SetHeight(80)
glow:SetColorTexture(1, 1, 1, 1)
if not (CreateColor and pcall(glow.SetGradient, glow, "VERTICAL",
        CreateColor(0.05, 0.02, 0.01, 0), CreateColor(0.45, 0.13, 0.04, 0.55))) then
    glow:SetColorTexture(0.45, 0.13, 0.04, 0.2) -- older clients: flat glow
end

-- Emblem sits on the corner like a seal
local emblem = main:CreateTexture(nil, "OVERLAY")
emblem:SetSize(78, 78)
emblem:SetPoint("TOPLEFT", -16, 16)
emblem:SetTexture(ICON)

local titleBig = main:CreateFontString(nil, "OVERLAY")
titleBig:SetFont(TITLE_FONT, 34, "OUTLINE")
titleBig:SetTextColor(unpack(GOLD))
titleBig:SetShadowColor(0, 0, 0, 1)
titleBig:SetShadowOffset(2, -2)
titleBig:SetPoint("TOPLEFT", 72, -14)
titleBig:SetText("G")

local titleRest = main:CreateFontString(nil, "OVERLAY")
titleRest:SetFont(TITLE_FONT, 25, "OUTLINE")
titleRest:SetTextColor(unpack(GOLD))
titleRest:SetShadowColor(0, 0, 0, 1)
titleRest:SetShadowOffset(2, -2)
titleRest:SetPoint("BOTTOMLEFT", titleBig, "BOTTOMRIGHT", -5, 3)
titleRest:SetText("ATHERCRAFT")

local tagline = main:CreateFontString(nil, "OVERLAY")
tagline:SetFont(TITLE_FONT, 13, "")
tagline:SetTextColor(0.85, 0.78, 0.62)
tagline:SetPoint("TOPLEFT", titleBig, "BOTTOMLEFT", 2, -1)
tagline:SetText("Gather  ·  Route  ·  Profit")

local version = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
version:SetPoint("TOPRIGHT", -40, -22)

local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

-- Content area, slightly darker than the frame
local body = CreateFrame("Frame", nil, main, "BackdropTemplate")
body:SetPoint("TOPLEFT", 18, TAB_TOP - TAB_H - 6)
body:SetPoint("BOTTOMRIGHT", -18, 18)
body:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
body:SetBackdropColor(0.03, 0.03, 0.03, 0.55)
body:SetBackdropBorderColor(0.45, 0.42, 0.38, 1)

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function Header(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFont(TITLE_FONT, 16, "")
    fs:SetTextColor(unpack(GOLD))
    fs:SetShadowColor(0, 0, 0, 1)
    fs:SetShadowOffset(1, -1)
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Divider(parent, anchor)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetHeight(1)
    t:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -3)
    t:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    t:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
    return t
end

local function Button(parent, text, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 110, 24)
    b:SetText(text)
    return b
end

local function KindIcon(type, item)
    if item and type ~= "chest" and C_Item and C_Item.GetItemIconByID then
        local icon = C_Item.GetItemIconByID(item)
        if icon then return icon end
    end
    return TYPE_ICONS[type] or "Interface\\Icons\\INV_Misc_QuestionMark"
end

---------------------------------------------------------------------------
-- Tabs (our own: dark iron, ember when selected)
---------------------------------------------------------------------------
local tabs, pages = {}, {}
local currentTab

local function StyleTab(tab, selected)
    if selected then
        tab:SetBackdropColor(EMBER[1], EMBER[2], EMBER[3], 1)
        tab:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1)
        tab.text:SetTextColor(1, 0.95, 0.8)
    else
        tab:SetBackdropColor(0.10, 0.09, 0.08, 1)
        tab:SetBackdropBorderColor(0.40, 0.38, 0.35, 1)
        tab.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
    end
end

local function SelectTab(name)
    currentTab = name
    for key, tab in pairs(tabs) do
        StyleTab(tab, key == name)
        pages[key]:SetShown(key == name)
    end
end

local tabOrder = {}

-- Six tabs per row; a 7th starts a second row and the window grows
local function LayoutTabs()
    for i, tab in ipairs(tabOrder) do
        local row, col = math.floor((i - 1) / TABS_PER_ROW), (i - 1) % TABS_PER_ROW
        tab:ClearAllPoints()
        tab:SetPoint("TOPLEFT", main, "TOPLEFT", 22 + col * (TAB_W + TAB_GAP), TAB_TOP - row * (TAB_H + ROW_GAP))
    end
    local rows = math.max(1, math.ceil(#tabOrder / TABS_PER_ROW))
    local extra = (rows - 1) * (TAB_H + ROW_GAP)
    main:SetHeight(HEIGHT + extra)
    body:ClearAllPoints()
    body:SetPoint("TOPLEFT", 18, TAB_TOP - extra - TAB_H - 6)
    body:SetPoint("BOTTOMRIGHT", -18, 18)
end

local function AddTab(key, label, index, icon)
    local tab = CreateFrame("Button", nil, main, "BackdropTemplate")
    tab:SetSize(TAB_W, TAB_H)
    tabOrder[index] = tab
    tab:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    tab.text = tab:CreateFontString(nil, "OVERLAY")
    tab.text:SetFont(TITLE_FONT, 15, "")
    tab.text:SetText(label)
    tab.icon = tab:CreateTexture(nil, "ARTWORK")
    tab.icon:SetSize(18, 18)
    tab.icon:SetTexture(icon)
    tab.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    -- icon + label centered together (text width is known once shown)
    local function Center()
        local sw = tab.text:GetStringWidth()
        if not sw or sw <= 0 then sw = #label * 8 end
        tab.icon:ClearAllPoints()
        tab.icon:SetPoint("LEFT", tab, "CENTER", -(18 + 6 + sw) / 2, 0)
    end
    tab.text:SetPoint("LEFT", tab.icon, "RIGHT", 6, -1)
    Center()
    tab:SetScript("OnShow", Center)
    local hl = tab:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 3, -3)
    hl:SetPoint("BOTTOMRIGHT", -3, 3)
    hl:SetColorTexture(1, 0.8, 0.3, 0.12)
    tab:SetScript("OnClick", function() SelectTab(key) end)
    tabs[key] = tab

    local page = CreateFrame("Frame", nil, body)
    page:SetPoint("TOPLEFT", 8, -8)
    page:SetPoint("BOTTOMRIGHT", -8, 8)
    page:Hide()
    pages[key] = page
    return page
end

local overview = AddTab("overview", "Overview", 1, "Interface\\Icons\\INV_Misc_Book_09")
local farmPage = AddTab("farm", "Farm Spots", 2, "Interface\\Icons\\INV_Misc_Coin_02")
local craftPage = AddTab("craft", "Crafting", 3, "Interface\\Icons\\Trade_BlackSmithing")
local zonesPage = AddTab("zones", "Zones", 4, "Interface\\Icons\\INV_Misc_Map_01")
local skillsPage = AddTab("skills", "Skills", 5, "Interface\\Icons\\INV_Misc_Note_01")
local optionsPage = AddTab("options", "Options", 6, "Interface\\Icons\\INV_Misc_Gear_01")
LayoutTabs()

-- "Where to farm" page (Advisor.lua) uses the same look
local pageStyle = { gold = GOLD, header = Header, divider = Divider, button = Button, width = PAGE_WIDTH }
if ns.BuildFarmPage then ns.BuildFarmPage(farmPage, pageStyle) end
if ns.BuildCraftPage then ns.BuildCraftPage(craftPage, pageStyle) end


---------------------------------------------------------------------------
-- Overview: profession bars
---------------------------------------------------------------------------
-- Two columns: gathering professions left, secondary professions right
local COL_LEFT, COL_RIGHT, COL_WIDTH = 4, 370, 340
local PROF_ICONS = {
    herb = "Interface\\Icons\\Trade_Herbalism",
    ore = "Interface\\Icons\\Trade_Mining",
    fish = "Interface\\Icons\\Trade_Fishing",
    cook = "Interface\\Icons\\INV_Misc_Food_15",
    aid = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
}
local TIERS = { [75] = "Apprentice", [150] = "Journeyman", [225] = "Expert", [300] = "Artisan" }

local gatherHeader = Header(overview, "Gathering", COL_LEFT, -2)
local gatherLine = Divider(overview, gatherHeader)
gatherLine:SetPoint("RIGHT", overview, "LEFT", COL_LEFT + COL_WIDTH, 0)
Header(overview, "Secondary", COL_RIGHT, -2)
local secLine = overview:CreateTexture(nil, "ARTWORK")
secLine:SetHeight(1)
secLine:SetPoint("TOPLEFT", overview, "TOPLEFT", COL_RIGHT, -23)
secLine:SetPoint("RIGHT", overview, "RIGHT", -6, 0)
secLine:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)

local bars = {}
local function CreateBar(type, label, x, y)
    local icon = overview:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("TOPLEFT", x + 2, y + 2)
    icon:SetTexture(PROF_ICONS[type])
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local name = overview:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetWidth(70)
    name:SetJustifyH("LEFT")
    name:SetText(label)

    local frame = CreateFrame("Frame", nil, overview, "BackdropTemplate")
    frame:SetPoint("TOPLEFT", x + 100, y + 2)
    frame:SetSize(COL_WIDTH - 100, 18)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.8)
    frame:SetBackdropBorderColor(0.5, 0.45, 0.38, 1)

    local bar = CreateFrame("StatusBar", nil, frame)
    bar:SetPoint("TOPLEFT", 3, -3)
    bar:SetPoint("BOTTOMRIGHT", -3, 3)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetStatusBarColor(unpack(BAR_COLORS[type]))
    bar:SetMinMaxValues(0, 1)

    local text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("CENTER", 0, 0)

    -- shown instead of the bar when the profession is not learned
    local missing = overview:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    missing:SetPoint("LEFT", frame, "LEFT", 4, 0)
    missing:SetText("< not learned yet >")

    bars[type] = { icon = icon, name = name, frame = frame, bar = bar, text = text, missing = missing }
end
CreateBar("herb", "Herbalism", COL_LEFT, -28)
CreateBar("ore", "Mining", COL_LEFT, -52)
CreateBar("fish", "Fishing", COL_RIGHT, -28)
CreateBar("cook", "Cooking", COL_RIGHT, -52)
CreateBar("aid", "First Aid", COL_RIGHT, -76)

local function UpdateBars()
    for type, b in pairs(bars) do
        local rank, maxRank = ns.GetSkill(type)
        local learned = rank ~= nil
        b.frame:SetShown(learned)
        b.missing:SetShown(not learned)
        b.icon:SetDesaturated(not learned)
        b.icon:SetAlpha(learned and 1 or 0.5)
        if learned then
            b.name:SetTextColor(1, 1, 1)
            b.bar:SetMinMaxValues(0, maxRank > 0 and maxRank or 1)
            b.bar:SetValue(rank)
            local tier = TIERS[maxRank]
            b.text:SetText((tier and ("|cffffd27f" .. tier .. "|r  ") or "") .. ("%d / %d"):format(rank, maxRank))
        else
            b.name:SetTextColor(0.5, 0.5, 0.5)
        end
    end
end

---------------------------------------------------------------------------
-- Overview: gather here (current zone)
---------------------------------------------------------------------------
local hereHeader = Header(overview, "Gather here", 4, -108)
local hereLine = Divider(overview, hereHeader)
hereLine:SetPoint("RIGHT", overview, "LEFT", 440, 0)

local hereEmpty = overview:CreateFontString(nil, "OVERLAY", "GameFontDisable")
hereEmpty:SetPoint("TOPLEFT", 6, -134)
hereEmpty:SetWidth(430)
hereEmpty:SetJustifyH("LEFT")
hereEmpty:SetText("No nodes known in this zone yet.")

local hereRows = {}
for i = 1, LIST_ROWS do
    local row = CreateFrame("Frame", nil, overview)
    row:SetSize(436, 26)
    row:SetPoint("TOPLEFT", 4, -130 - (i - 1) * 28)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(22, 22)
    row.icon:SetPoint("LEFT", 0, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, 1)
    row.name:SetWidth(260)
    row.name:SetJustifyH("LEFT")
    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.info:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 6, -1)
    row.info:SetWidth(290)
    row.info:SetJustifyH("LEFT")
    row:Hide()
    hereRows[i] = row
end

-- Skill-up verdict for a node kind at the current skill
local function Verdict(type, key, name, id)
    return ns.SkillVerdict(type, name, id, key)
end

local function UpdateHere()
    local mapID = ns.GetPlayerPos()
    hereHeader:SetText("Gather here" .. (mapID and ("  |cffcccccc– " .. ns.GetZoneName(mapID) .. "|r") or ""))
    local kinds, byKey = {}, {}
    for _, n in ipairs(mapID and ns.db.nodes[mapID] or {}) do
        local key = n.type ~= "chest" and ns.KindKey(n) -- chests: map icons only
        local k = key and byKey[key]
        if key and not k then
            k = { key = key, name = n.name, type = n.type, item = n.item, id = n.id, count = 0 }
            byKey[key] = k
            kinds[#kinds + 1] = k
        end
        if k then
            k.count = k.count + 1
            k.item = k.item or n.item
        end
    end
    for _, k in ipairs(kinds) do
        k.rank, k.verdict = Verdict(k.type, k.key, k.name, k.id)
    end
    table.sort(kinds, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.count > b.count
    end)
    hereEmpty:SetShown(#kinds == 0)
    for i, row in ipairs(hereRows) do
        local k = kinds[i]
        if k then
            row.icon:SetTexture(KindIcon(k.type, k.item))
            row.name:SetText(((ns.TYPE_COLORS[k.type] or "|cffffffff") .. k.name .. "|r"))
            row.info:SetText(("%d node%s  ·  %s"):format(k.count, k.count == 1 and "" or "s", k.verdict))
            row:Show()
        else
            row:Hide()
        end
    end
end

---------------------------------------------------------------------------
-- Overview: session + database (right column)
---------------------------------------------------------------------------
local session = { start = GetTime(), nodes = 0, skillStart = {} }

local sessHeader = Header(overview, "This session", 470, -108)
Divider(overview, sessHeader)
local sessText = overview:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
sessText:SetPoint("TOPLEFT", 474, -134)
sessText:SetWidth(200)
sessText:SetJustifyH("LEFT")
sessText:SetSpacing(4)

local dbHeader = Header(overview, "Your map", 470, -234)
Divider(overview, dbHeader)
local dbText = overview:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
dbText:SetPoint("TOPLEFT", 474, -260)
dbText:SetWidth(160)
dbText:SetJustifyH("LEFT")
dbText:SetSpacing(4)

local function UpdateStats()
    local hours = math.max((GetTime() - session.start) / 3600, 1 / 60)
    local ups = 0
    for _, t in ipairs({ "herb", "ore" }) do
        local now = ns.GetSkill(t)
        if now and session.skillStart[t] then
            ups = ups + math.max(0, now - session.skillStart[t])
        end
    end
    local value, _, source = 0, nil, nil
    if ns.SessionValue then value, _, source = ns.SessionValue() end
    local money = ns.Money and ns.Money(value) or "-"
    sessText:SetText(("Gathered: |cffffffff%d|r\nPer hour: |cffffffff%d|r\nWorth: %s%s\nSkill points: |cff55ff55+%d|r"):format(
        session.nodes, math.floor(session.nodes / hours + 0.5), money,
        source and ("  |cff999999(" .. source .. ")|r") or "", ups))

    local herbs, ores, zones, known = 0, 0, 0, 0
    for _, list in pairs(ns.db.nodes) do
        local any = false
        for _, n in ipairs(list) do
            if n.type == "herb" or n.type == "ore" then
                any = true
                if n.type == "herb" then herbs = herbs + 1 else ores = ores + 1 end
                if n.source then known = known + 1 end
            end
        end
        if any then zones = zones + 1 end
    end
    dbText:SetText(("|cff66ff66Herbs|r: %d\n|cffffcc66Ores|r: %d\nZones: %d\n|cff999999%d known spawns / shared|r"):format(
        herbs, ores, zones, known))
end

-- Farm run buttons: herbs, ores or both (single materials: Zones tab)
local runLabel = overview:CreateFontString(nil, "OVERLAY")
runLabel:SetFont(TITLE_FONT, 15, "")
runLabel:SetTextColor(unpack(GOLD))
runLabel:SetPoint("BOTTOMLEFT", 6, 10)
runLabel:SetText("Farm run:")

local runButtons = {}
local function RunButton(text, filter, width, anchor)
    local b = Button(overview, text, width)
    b:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
    b:SetScript("OnClick", function()
        ns.StartRun(filter)
        main:Hide()
    end)
    runButtons[#runButtons + 1] = b
    return b
end
local herbRun = RunButton("|cff66ff66Herbs|r", "herb", 80, runLabel)
local oreRun = RunButton("|cffffcc66Ores|r", "ore", 80, herbRun)
RunButton("Herbs + Ores", "both", 110, oreRun)

local stopRun = Button(overview, "Stop", 70)
stopRun:SetPoint("BOTTOMRIGHT", -4, 4)
stopRun:SetScript("OnClick", function()
    ns.StopRun()
end)

local function UpdateOverview()
    UpdateBars()
    UpdateHere()
    UpdateStats()
    if ns.run then stopRun:Enable() else stopRun:Disable() end
end
overview:SetScript("OnShow", UpdateOverview)

---------------------------------------------------------------------------
-- Skills page
---------------------------------------------------------------------------
local skillsHeader = Header(skillsPage, "What we learned about skill-ups", 4, -2)
Divider(skillsPage, skillsHeader)

local skillsScroll = CreateFrame("ScrollFrame", "GathercraftSkillsScroll", skillsPage, "UIPanelScrollFrameTemplate")
skillsScroll:SetPoint("TOPLEFT", 0, -28)
skillsScroll:SetPoint("BOTTOMRIGHT", -24, 0)
local skillsContent = CreateFrame("Frame", nil, skillsScroll)
skillsContent:SetSize(PAGE_WIDTH - 30, 10)
skillsScroll:SetScrollChild(skillsContent)

local skillsEmpty = skillsContent:CreateFontString(nil, "OVERLAY", "GameFontDisable")
skillsEmpty:SetPoint("TOPLEFT", 6, -6)
skillsEmpty:SetText("No skill data yet. Gather a few nodes!")

local skillRows = {}
local function SkillRow(i)
    local row = skillRows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, skillsContent)
    row:SetSize(PAGE_WIDTH - 30, 30)
    row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * 32)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", 0, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, 1)
    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.info:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, -1)
    row.verdict = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.verdict:SetPoint("LEFT", row.name, "RIGHT", 12, 0)
    skillRows[i] = row
    return row
end

local function UpdateSkills()
    local items = {}
    for _, list in pairs(ns.db.nodes) do
        for _, n in ipairs(list) do
            local key = ns.KindKey(n)
            if n.item and not items[key] then items[key] = n.item end
        end
    end
    local list = {}
    for key, s in pairs(ns.KindStats()) do
        if s.type ~= "chest" then list[#list + 1] = { key = key, s = s } end
    end
    table.sort(list, function(a, b)
        if (a.s.type or "") ~= (b.s.type or "") then return (a.s.type or "") < (b.s.type or "") end
        return (a.s.minSkill or 0) < (b.s.minSkill or 0)
    end)
    skillsEmpty:SetShown(#list == 0)
    for i, e in ipairs(list) do
        local s, row = e.s, SkillRow(i)
        row.icon:SetTexture(KindIcon(s.type, items[e.key]))
        row.name:SetText(((ns.TYPE_COLORS[s.type] or "|cffffffff") .. (s.name or "?") .. "|r"))
        row.info:SetText(("Gathered from %s  ·  skill points seen up to %s  ·  %d gathered, %d skill-ups"):format(
            tostring(s.minSkill or "?"), tostring(s.maxUp or "–"), s.n or 0, s.ups or 0))
        local _, verdict = Verdict(s.type, e.key, s.name)
        row.verdict:SetText(verdict)
        row:Show()
    end
    for i = #list + 1, #skillRows do
        skillRows[i]:Hide()
    end
    skillsContent:SetHeight(math.max(10, #list * 32 + 8))
end
skillsPage:SetScript("OnShow", UpdateSkills)

---------------------------------------------------------------------------
-- Open / close
---------------------------------------------------------------------------
local embedded = false
local function Embed()
    if embedded then return end
    embedded = true
    if ns.EmbedZones then ns.EmbedZones(zonesPage):Show() end
    if ns.EmbedOptions then ns.EmbedOptions(optionsPage):Show() end
end

local function Open(tab)
    Embed()
    if not main:IsShown() then main:Show() end
    SelectTab(tab or currentTab or "overview")
end

ns.ToggleMain = function(tab)
    if main:IsShown() and (not tab or tab == currentTab) then
        main:Hide()
    else
        Open(tab)
    end
end
ns.HideMain = function() main:Hide() end
ns.ToggleZones = function() ns.ToggleMain("zones") end
ns.ToggleOptions = function() ns.ToggleMain("options") end

-- Keep the open overview fresh
local ticker = 0
main:SetScript("OnUpdate", function(self, elapsed)
    ticker = ticker + elapsed
    if ticker < 2 then return end
    ticker = 0
    if currentTab == "overview" then UpdateOverview() end
end)

table.insert(ns.gatherListeners, function(node)
    if node.type ~= "chest" then session.nodes = session.nodes + 1 end
end)

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    local pos = ns.db.mainPos
    if pos then
        main:ClearAllPoints()
        main:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    end
    local v = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    version:SetText(v and ("v" .. v) or "")
    -- Professions are known a moment after login
    C_Timer.After(3, function()
        for _, t in ipairs({ "herb", "ore" }) do
            session.skillStart[t] = ns.GetSkill(t)
        end
    end)
end)
