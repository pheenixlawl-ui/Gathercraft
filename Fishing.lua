local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- One-button fishing
--   Bind ONE key ("Fish" under Keybindings > AddOns > Gathercraft).
--   Every key press does exactly one thing, chosen out of combat:
--     1. no fishing pole in hand  -> equip the pole from your bags
--     2. no lure on the pole      -> apply the best lure from your bags
--     3. otherwise                -> cast Fishing
--     4. while the line is out    -> the same key interacts with the bobber
--   Nothing happens without a key press: this only picks the action.
---------------------------------------------------------------------------
local BUTTON_NAME = "GathercraftFishButton"
local BINDING = "CLICK " .. BUTTON_NAME .. ":LeftButton"
local FISHING_SPELLS = { 131474, 7620, 7731, 7732, 18248 } -- newest first
local POLE_CLASS, POLE_SUBCLASS = 2, 20 -- Weapon / Fishing Pole
-- Lures, best first: item ID -> bonus
local LURES = {
    { id = 6533, bonus = 100 }, -- Aquadynamic Fish Attractor
    { id = 6811, bonus = 50 },  -- Aquadynamic Fish Lens
    { id = 7307, bonus = 75 },  -- Flesh Eating Worm
    { id = 6532, bonus = 75 },  -- Bright Baubles
    { id = 6530, bonus = 50 },  -- Nightcrawlers
    { id = 6529, bonus = 25 },  -- Shiny Bauble
}

local button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate")
button:RegisterForClicks("AnyUp", "AnyDown")
button:Hide()

local owner = CreateFrame("Frame") -- holds the temporary "reel in" binding
local lineOut = false

-- Does the player know this spell? IsPlayerSpell works in Forever (Ketho's
-- tools call it deprecated: newer clients moved it to C_SpellBook)
local function PlayerKnows(id)
    ---@diagnostic disable-next-line: deprecated
    if IsPlayerSpell then return IsPlayerSpell(id) and true or false end
    if C_SpellBook and C_SpellBook.IsSpellKnown then
        local ok, known = pcall(C_SpellBook.IsSpellKnown, id)
        return ok and known and true or false
    end
    return false
end

local function FishingSpell()
    for _, id in ipairs(FISHING_SPELLS) do
        if PlayerKnows(id) then return id end
    end
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return GetSpellInfo and (GetSpellInfo(id))
end

local function IsPole(itemID)
    if not itemID then return false end
    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID)
    return classID == POLE_CLASS and subClassID == POLE_SUBCLASS
end

local function ItemCount(id)
    if C_Item and C_Item.GetItemCount then return C_Item.GetItemCount(id) end
    ---@diagnostic disable-next-line: deprecated -- fallback for clients without the C_ version
    return GetItemCount and GetItemCount(id) or 0
end

-- First fishing pole in the bags
local function PoleInBags()
    local numSlots = C_Container and C_Container.GetContainerNumSlots
    if not numSlots then return end
    for bag = 0, 4 do
        for slot = 1, numSlots(bag) do
            local id = C_Container.GetContainerItemID(bag, slot)
            if IsPole(id) then return id end
        end
    end
end

local function BestLure()
    for _, lure in ipairs(LURES) do
        if ItemCount(lure.id) > 0 then return lure.id end
    end
end

local function HasLure()
    local hasMainHand = GetWeaponEnchantInfo()
    return hasMainHand
end

-- Picks what the next key press does (out of combat only)
local function Prepare()
    if InCombatLockdown() then return end
    local mainHand = GetInventoryItemID("player", 16)
    if not IsPole(mainHand) then
        local pole = PoleInBags()
        if pole then
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/equip item:" .. pole)
            button.next = "equip pole"
            return
        end
    elseif ns.db.fishLure ~= false and not HasLure() then
        local lure = BestLure()
        if lure then
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/use item:" .. lure .. "\n/use 16")
            button.next = "apply lure"
            return
        end
    end
    local spell = FishingSpell()
    if spell then
        button:SetAttribute("type", "spell")
        button:SetAttribute("spell", SpellName(spell) or spell)
        button.next = "cast"
    else
        button:SetAttribute("type", nil)
        button.next = nil
    end
end

button:SetScript("PreClick", function()
    if not InCombatLockdown() then Prepare() end
    if not button.next and not InCombatLockdown() then
        ns.Print(L["You don't know Fishing yet. Visit a fishing trainer first."])
    end
end)

---------------------------------------------------------------------------
-- Line out: the same key interacts with the bobber
---------------------------------------------------------------------------
local function SetReelBinding(on)
    if InCombatLockdown() then return end
    ClearOverrideBindings(owner)
    if not on then return end
    for _, key in ipairs({ GetBindingKey(BINDING) }) do
        SetOverrideBinding(owner, true, key, "INTERACTTARGET")
    end
end

-- While the line is out, the interact key must be able to reach the bobber:
-- by default "interact" only finds things about 10 yards in front of you,
-- the bobber lands further away. We widen it for the cast and put your
-- settings back afterwards.
local BOBBER_CVARS = { SoftTargetInteractRange = 30, SoftTargetInteractArc = 2 }
local savedCVars

local function WidenInteract()
    if not (GetCVar and SetCVar) then return end
    if savedCVars then return end
    savedCVars = {}
    -- 0 = off, 1 = gamepad only, 2 = keyboard/mouse only, 3 = both:
    -- the keyboard needs 2 or 3
    local mode = GetCVar("SoftTargetInteract")
    if mode ~= "2" and mode ~= "3" then
        savedCVars.SoftTargetInteract = mode
        pcall(SetCVar, "SoftTargetInteract", "3")
    end
    for name, value in pairs(BOBBER_CVARS) do
        local current = GetCVar(name)
        if current and tonumber(current) and tonumber(current) < value then
            savedCVars[name] = current
            pcall(SetCVar, name, tostring(value))
        end
    end
end

local function RestoreInteract()
    if not savedCVars then return end
    for name, value in pairs(savedCVars) do
        pcall(SetCVar, name, value)
    end
    savedCVars = nil
end

local function IsFishingCast(spellID)
    for _, id in ipairs(FISHING_SPELLS) do
        if id == spellID then return true end
    end
    local name = spellID and SpellName(spellID)
    local fishing = FishingSpell()
    return name and fishing and name == SpellName(fishing)
end

-- Fishing session (see further down)
local SESSION_IDLE = 300 -- seconds without casting: the session is over
local fishing = { active = false }

local function StartFishingSession()
    fishing.active = true
    fishing.start = GetTime()
    fishing.catches, fishing.items, fishing.value = 0, 0, 0
    fishing.skillStart = ns.GetSkill and ns.GetSkill("fish") or 0
    fishing.source = nil
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("BAG_UPDATE_DELAYED")
events:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
events:SetScript("OnEvent", function(_, event, _, _, spellID)
    if event == "UNIT_SPELLCAST_CHANNEL_START" then
        if IsFishingCast(spellID) then
            if not fishing.active or GetTime() - (fishing.last or 0) > SESSION_IDLE then StartFishingSession() end
            fishing.last = GetTime()
            lineOut = true
            SetReelBinding(true)
            WidenInteract()
            ns.Debug(("FISH line out (spell %s), reel key: %s, interact %s range %s arc %s"):format(
                tostring(spellID), tostring(GetBindingKey(BINDING)), tostring(GetCVar("SoftTargetInteract")),
                tostring(GetCVar("SoftTargetInteractRange")), tostring(GetCVar("SoftTargetInteractArc"))))
        end
    elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        if lineOut then
            lineOut = false
            fishing.reeledAt = GetTime()
            SetReelBinding(false)
            RestoreInteract()
            C_Timer.After(0.3, Prepare)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        SetReelBinding(lineOut)
        Prepare()
    else
        Prepare()
    end
end)

---------------------------------------------------------------------------
-- Fishing session: catches, catches per hour, gold per hour, skill points
--   Starts with your first cast, ends after a few idle minutes (or Stop on
--   the panel). The farm panel shows it while no farm run is going.
---------------------------------------------------------------------------

local function ReadLoot()
    local items = {}
    for slot = 1, (GetNumLootItems and GetNumLootItems() or 0) do
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then
            local qty = GetLootSlotInfo and select(3, GetLootSlotInfo(slot))
            items[#items + 1] = { id = id, qty = tonumber(qty) or 1 }
        end
    end
    return items
end

local function OnFishingLoot()
    local isFish = IsFishingLoot and IsFishingLoot()
    if not isFish and not (fishing.reeledAt and GetTime() - fishing.reeledAt < 4) then return end
    fishing.reeledAt = nil
    if not fishing.active then StartFishingSession() end
    local items = ReadLoot()
    if #items == 0 then return end
    local value, source = 0, nil
    if ns.LootValue then value, source = ns.LootValue(items) end
    fishing.catches = fishing.catches + 1
    for _, it in ipairs(items) do fishing.items = fishing.items + it.qty end
    fishing.value = fishing.value + value
    fishing.source = fishing.source or source
    fishing.last = GetTime()
    if ns.AddSessionValue then ns.AddSessionValue(value, source) end
    ns.Debug(("FISH catch %d: %d item(s), worth %s"):format(fishing.catches, #items, ns.Money and ns.Money(value) or value))
end

local lootEvents = CreateFrame("Frame")
lootEvents:RegisterEvent("LOOT_READY")
lootEvents:SetScript("OnEvent", OnFishingLoot)

-- Current session or nil (ended or idle too long)
ns.FishingSession = function()
    if fishing.active and GetTime() - (fishing.last or fishing.start) > SESSION_IDLE and not lineOut then
        fishing.active = false
    end
    return fishing.active and fishing or nil
end
ns.StopFishing = function() fishing.active = false end
-- Seconds left on the lure, or nil
ns.LureTimeLeft = function()
    local has, expiration = GetWeaponEnchantInfo()
    if has and expiration then return math.floor(expiration / 1000) end
end

_G["BINDING_NAME_" .. BINDING] = "Fish (pole, lure, cast, reel in)"
ns.FishBinding = BINDING

---------------------------------------------------------------------------
-- Herbs / minerals switch: one click (or one key) switches the minimap
-- tracking between Find Herbs and Find Minerals. A normal button press, like
-- an action bar button: nothing ever switches on its own.
---------------------------------------------------------------------------
local TRACK_BUTTON = "GathercraftTrackButton"
local TRACK_BINDING = "CLICK " .. TRACK_BUTTON .. ":LeftButton"
local FIND_HERBS, FIND_MINERALS = 2383, 2580
local TRACK_ICONS = {
    [FIND_HERBS] = "Interface\\Icons\\INV_Misc_Flower_02",
    [FIND_MINERALS] = "Interface\\Icons\\Spell_Nature_Earthquake",
}

-- sits on the minimap's edge like the minimap buttons (nothing covers it)
local track = CreateFrame("Button", TRACK_BUTTON, Minimap, "SecureActionButtonTemplate")
track:RegisterForClicks("AnyUp", "AnyDown")
track:SetSize(31, 31)
track:SetFrameStrata(Minimap:GetFrameStrata() or "LOW")
track:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
track:RegisterForDrag("LeftButton")
track:Hide()
track.bg = track:CreateTexture(nil, "BACKGROUND")
track.bg:SetSize(24, 24)
track.bg:SetPoint("CENTER")
track.bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
track.icon = track:CreateTexture(nil, "ARTWORK")
track.icon:SetSize(20, 20)
track.icon:SetPoint("CENTER")
track.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
track.border = track:CreateTexture(nil, "OVERLAY")
track.border:SetSize(53, 53)
track.border:SetPoint("TOPLEFT")
track.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
track:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local lastTracked

local function KnowsSpell(id)
    return PlayerKnows(id)
end

-- Which of the two the minimap tracks right now (nil: something else / none)
local function ActiveTracking()
    if C_Minimap and C_Minimap.GetNumTrackingTypes and C_Minimap.GetTrackingInfo then
        for i = 1, C_Minimap.GetNumTrackingTypes() or 0 do
            local info = C_Minimap.GetTrackingInfo(i)
            local active, spellID, texture
            if type(info) == "table" then
                active, spellID, texture = info.active, info.spellID, info.texture
            else
                local _
                _, texture, active, _, _, spellID = C_Minimap.GetTrackingInfo(i)
            end
            if active and (spellID == FIND_HERBS or spellID == FIND_MINERALS) then return spellID end
        end
    end
    return lastTracked
end

-- The click switches to the other one; with only one of them known it puts
-- that one back on (after dying, for example)
local function NextTracking()
    local herbs, minerals = KnowsSpell(FIND_HERBS), KnowsSpell(FIND_MINERALS)
    if herbs and minerals then
        return ActiveTracking() == FIND_HERBS and FIND_MINERALS or FIND_HERBS
    end
    return herbs and FIND_HERBS or minerals and FIND_MINERALS or nil
end

local function PrepareTrack()
    local active = ActiveTracking()
    track.icon:SetTexture(TRACK_ICONS[active or FIND_HERBS])
    track.icon:SetDesaturated(active == nil)
    if InCombatLockdown() then return end
    local nextSpell = NextTracking()
    track.next = nextSpell
    if nextSpell then
        track:SetAttribute("type", "spell")
        track:SetAttribute("spell", SpellName(nextSpell) or nextSpell)
    else
        track:SetAttribute("type", nil)
    end
end

-- On the minimap's edge at an angle (degrees, 0 = right, counter-clockwise)
local TRACK_ANGLE = 250
local function PlaceTrack()
    if InCombatLockdown() then return end
    local angle = math.rad(ns.db and ns.db.trackButtonAngle or TRACK_ANGLE)
    local r = (Minimap:GetWidth() or 140) / 2 + 5
    track:ClearAllPoints()
    track:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

-- Shown when you know both (option, out of combat)
local function UpdateTrackButton()
    if InCombatLockdown() or not ns.db then return end
    local show = not ns.db.trackButtonHidden and KnowsSpell(FIND_HERBS) and KnowsSpell(FIND_MINERALS)
    track:SetShown(show and true or false)
    PrepareTrack()
end
ns.UpdateTrackButton = UpdateTrackButton

track:SetScript("PreClick", function()
    if not InCombatLockdown() then PrepareTrack() end
    if not track.next and not InCombatLockdown() then
        ns.Print(L["You know neither Find Herbs nor Find Minerals yet."])
    end
end)
track:SetScript("PostClick", function()
    lastTracked = track.next
    C_Timer.After(0.3, PrepareTrack)
end)
-- Shift-drag: along the minimap's edge
track:SetScript("OnDragStart", function(self)
    if not IsShiftKeyDown() or InCombatLockdown() then return end
    self:SetScript("OnUpdate", function()
        if InCombatLockdown() then self:SetScript("OnUpdate", nil) return end
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale() or 1
        if not (mx and cx) then return end
        ns.db.trackButtonAngle = math.floor(math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360 + 0.5)
        PlaceTrack()
    end)
end)
track:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
end)
track:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(L["Find Herbs / Find Minerals"], 1, 0.82, 0)
    if self.next then
        GameTooltip:AddLine((L["Click: switch to %s"]):format(SpellName(self.next) or ""), 1, 1, 1)
    end
    local key = GetBindingKey(TRACK_BINDING)
    if key then GameTooltip:AddLine((L["Key: %s"]):format(GetBindingText and GetBindingText(key) or key), 0.7, 0.7, 0.7) end
    GameTooltip:AddLine(L["Shift-drag: move the button"], 0.6, 0.6, 0.6)
    GameTooltip:Show()
end)
track:SetScript("OnLeave", GameTooltip_Hide)

local trackEvents = CreateFrame("Frame")
trackEvents:RegisterEvent("PLAYER_LOGIN")
trackEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
trackEvents:RegisterEvent("MINIMAP_UPDATE_TRACKING")
trackEvents:RegisterEvent("SPELLS_CHANGED")
trackEvents:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then PlaceTrack() end
    if event == "MINIMAP_UPDATE_TRACKING" then PrepareTrack() return end
    UpdateTrackButton()
end)

-- A macro for the action bar: "/click" the switch (the macro lives in your
-- macros, /macro, and on the cursor right away to drop it on a bar)
local TRACK_MACRO = "GC Tracking"
function ns.TrackMacro()
    if InCombatLockdown() then
        ns.Print(L["Not possible in combat."])
        return
    end
    if not (GetMacroIndexByName and CreateMacro) then return end
    local body = "/click " .. TRACK_BUTTON
    local index = GetMacroIndexByName(TRACK_MACRO) or 0
    if index == 0 then
        local account = GetNumMacros and GetNumMacros() or 0
        if account >= (MAX_ACCOUNT_MACROS or 120) then
            ns.Print(L["Your macro slots are full."])
            return
        end
        index = CreateMacro(TRACK_MACRO, "INV_Misc_Flower_02", body, nil) or 0
    else
        EditMacro(index, TRACK_MACRO, nil, body)
    end
    if index > 0 then
        if PickupMacro then PickupMacro(index) end
        ns.Print((L["Macro \"%s\" is on your cursor: drop it on an action bar (you also find it under /macro)."]):format(TRACK_MACRO))
    end
end

local function TrackBindingName()
    _G["BINDING_NAME_" .. TRACK_BINDING] = L["Switch Find Herbs / Find Minerals"]
end
TrackBindingName()
if ns.languageListeners then table.insert(ns.languageListeners, TrackBindingName) end
