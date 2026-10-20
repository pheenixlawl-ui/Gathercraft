local ADDON_NAME, ns = ...

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

local function FishingSpell()
    for _, id in ipairs(FISHING_SPELLS) do
        if IsPlayerSpell and IsPlayerSpell(id) then return id end
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
        ns.Print("You don't know Fishing yet. Visit a fishing trainer first.")
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
