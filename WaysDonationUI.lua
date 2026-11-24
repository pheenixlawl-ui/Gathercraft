local ADDON_NAME, ns = ...
local L = ns.L
local Wrap = ns.PerfWrap or function(_, fn) return fn end

-- Set only from Sven's supplied form address at build time. An empty value
-- deliberately disables the button, export command and one-time invitation.
ns.WaysDonationFormURL = "https://forms.gle/RjuGx3wJb9Gi9JxY8"
function ns.WaysDonationLink()
    local url = ns.WaysDonationFormURL
    if type(url) == "string" and #url <= 2048 and url:match('^https://[^%s|"<>]+$') then return url end
end

local window
local function Select(edit, text)
    edit.expected = text
    edit:SetText(text)
    edit:SetCursorPosition(0)
    edit:SetFocus()
    edit:HighlightText()
end
local function Enable(b, yes) if yes then b:Enable() else b:Disable() end end
local function Part(f, number)
    if not f.parts or number < 1 or number > #f.parts then return end
    f.part = number
    f.status:SetText((L["Part %d of %d"]):format(number, #f.parts))
    Enable(f.previous, number > 1) Enable(f.next, number < #f.parts)
    Select(f.edit, f.parts[number])
end
local function NewWindow()
    local f = CreateFrame("Frame", "GathercraftWaysDonation", UIParent, "BackdropTemplate")
    f:SetSize(620, 560)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true) f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving) f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:Hide()
    tinsert(UISpecialFrames, "GathercraftWaysDonation")
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -16) ns.LText(title, "Share my ways...")
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() f:Hide() end)
    local description = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    description:SetPoint("TOPLEFT", 20, -48) description:SetWidth(580)
    description:SetJustifyH("LEFT") description:SetWordWrap(true)
    ns.LText(description, "Help build the path network for everyone. This text contains only the ways you have ridden, as 25-yard steps: no names, no prices, no times, no character. Copy it (Ctrl+C) and paste it into the form at the link below.")
    local detail = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    detail:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -10) detail:SetWidth(580)
    detail:SetJustifyH("LEFT") detail:SetWordWrap(true)
    ns.LText(detail, "Includes today's ways and this session. Nothing is uploaded by the addon; this is a submission for manual review.")
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", detail, "BOTTOMLEFT", 0, -16)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -42, 110)
    local function Edit(parent, multiline)
        local e = CreateFrame("EditBox", nil, parent)
        e:SetFontObject(GameFontHighlightSmall) e:SetAutoFocus(false)
        e:SetMultiLine(multiline) e:SetMaxLetters(multiline and 20000 or 2048)
        if e.SetMaxBytes then e:SetMaxBytes(multiline and 20000 or 2048) end
        e:SetScript("OnTextChanged", function(self, userInput)
            if userInput then Select(self, self.expected or "") end
        end)
        e:SetScript("OnEscapePressed", function() f:Hide() end)
        e:SetScript("OnMouseUp", function(self) self:SetFocus() self:HighlightText() end)
        return e
    end
    f.edit = Edit(scroll, true)
    f.edit:SetWidth(550) f.edit:SetHeight(280)
    scroll:SetScrollChild(f.edit)
    f.link = Edit(f, false)
    f.link:SetSize(580, 24) f.link:SetPoint("BOTTOMLEFT", 20, 20)
    local linkLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    linkLabel:SetPoint("BOTTOMLEFT", f.link, "TOPLEFT", 0, 3)
    ns.LText(linkLabel, "Form link (Ctrl+C)")
    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.status:SetPoint("BOTTOM", 0, 78)
    local function Button(label, x, fn)
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(165, 24) b:SetPoint("BOTTOM", x, 75)
        ns.LText(b, label) b:SetScript("OnClick", fn) return b
    end
    f.previous = Button("Previous part", -195, function() Part(f, (f.part or 1) - 1) end)
    f.next = Button("Next part", 195, function() Part(f, (f.part or 1) + 1) end)
    f:SetScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
        self.job, self.parts, self.part = nil, nil, nil
        self.edit.expected, self.link.expected = nil, nil
        self.edit:ClearFocus() self.link:ClearFocus()
        self.edit:SetText("") self.link:SetText("") self.status:SetText("")
    end)
    return f
end
local function Update(f)
    local j = f.job
    if not j then return end
    ns.WaysDonation.Step(j)
    if j.error then
        f.status:SetText(L[j.error == "empty" and "No paths recorded yet." or "Could not prepare the ways. Close this window and try again."])
        f.job = nil f:SetScript("OnUpdate", nil)
    elseif j.done and not j.ready then
        -- Text layout/selection gets a fresh frame, not what is left of an
        -- encoding slice. WoW's actual EditBox layout is checked live.
        j.ready = true
    elseif j.done then
        f.parts, f.job = j.parts, nil
        f:SetScript("OnUpdate", nil)
        Part(f, 1)
    end
end
function ns.OpenWaysDonation()
    local url = ns.WaysDonationLink()
    if not url then ns.Print(L["The form is not ready yet"]) return end
    window = window or NewWindow()
    window:Hide() -- a second export releases the first one
    window:Show()
    Enable(window.previous, false) Enable(window.next, false)
    window.status:SetText(L["Preparing..."])
    window.link.expected = url window.link:SetText(url)
    Select(window.edit, "")
    local id = ("%04x%04x%04x%04x"):format(math.random(0, 65535), math.random(0, 65535), math.random(0, 65535), math.random(0, 65535))
    local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
    local version = get and get(ADDON_NAME, "Version") or "0.2.3-a13"
    window.job = ns.WaysDonation.New(ns.db and ns.db.paths, version, id)
    window:SetScript("OnUpdate", Wrap("WaysDonation", Update))
end

-- No new timer or allocations per frame while disabled, already shown, or
-- no form exists. Only the one-time invitation waits for a safe moment.
local hint = CreateFrame("Frame")
ns.WaysDonationHintFrame = hint
local loginAt, elapsed
local function HintTick(_, dt)
    elapsed = elapsed + dt
    if elapsed < 5 then return end
    elapsed = 0
    if GetTime() - loginAt < 60 or InCombatLockdown() then return end
    local db, who = ns.db, ns.PlayerKey()
    if not db or not who then return end
    if not ns.WaysDonationLink() or db.waysDonationHintOff or (db.waysDonationHints and db.waysDonationHints[who]) then
        hint:SetScript("OnUpdate", nil) return
    end
    local p = db.paths
    if not (p and type(p.total) == "number" and p.total >= 2000) then return end
    db.waysDonationHints = db.waysDonationHints or {}
    db.waysDonationHints[who] = true
    hint:SetScript("OnUpdate", nil)
    ns.Print((L["You have recorded %d path steps. Help build the path network for everyone: /gcr shareways (this hint will not show again)"]):format(p.total))
end
function ns.WaysDonationHintRefresh()
    local db, who = ns.db, ns.PlayerKey()
    if not loginAt or not db or db.waysDonationHintOff or not ns.WaysDonationLink()
        or (who and db.waysDonationHints and db.waysDonationHints[who]) then
        hint:SetScript("OnUpdate", nil)
    else
        elapsed = 0 hint:SetScript("OnUpdate", HintTick)
    end
end
function ns.WaysDonationHintSet(on)
    if ns.db then ns.db.waysDonationHintOff = not on or nil end
    ns.WaysDonationHintRefresh()
end
hint:RegisterEvent("PLAYER_LOGIN")
hint:SetScript("OnEvent", function()
    loginAt = GetTime()
    ns.WaysDonationHintRefresh()
end)
