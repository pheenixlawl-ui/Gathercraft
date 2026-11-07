local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Rare alert (local only, nothing is sent to anyone)
--   Watches what your own client shows you: nameplates, mouseover and
--   target. A rare or rare elite in range: the announcer shouts "RARE!"
--   and a big warning shows on screen.
--   Range = your nameplate range, so keep enemy nameplates on (V key).
---------------------------------------------------------------------------
local REPEAT_AFTER = 300 -- seconds before the same rare alerts again
local RARE = { rare = true, rareelite = true }

local seen = {} -- GUID -> time of last alert

local function Enabled()
    return ns.db and ns.db.rareAlert ~= false
end

local ANNOUNCER = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\Rare.ogg"

-- Announcer "RARE!" (Media\Rare.ogg), and/or the classic raid warning sound
local function Sound()
    local played = false
    if ns.db.rareAnnouncer ~= false then
        played = PlaySoundFile(ANNOUNCER, "Master") and true or false
    end
    if ns.db.rareSound or not played and ns.db.rareAnnouncer ~= false then
        PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
    end
end

local function Alert(unit)
    local guid = ns.Readable(UnitGUID(unit), "rare alert")
    local dead, isPlayer = UnitIsDead(unit), UnitIsPlayer(unit)
    if not guid or ns.AnySecret("rare alert", dead, isPlayer) or dead or isPlayer then return end
    local now = GetTime()
    if seen[guid] and now - seen[guid] < REPEAT_AFTER then return end
    seen[guid] = now

    local name = ns.Readable(UnitName(unit), "rare alert") or "?"
    local elite = ns.Readable(UnitClassification(unit), "rare alert") == "rareelite"
    local level = ns.Readable(UnitLevel(unit), "rare alert")
    local tapped = ns.Readable(UnitIsTapDenied and UnitIsTapDenied(unit), "rare alert")
    local label = (L["RARE%s: %s%s"]):format(elite and L[" ELITE"] or "", name,
        (level and level > 0) and (" (" .. level .. ")") or "")

    Sound()
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, label, { r = 1, g = 0.55, b = 0.1 })
    end
    local mapID, x, y = ns.GetPlayerPos()
    ns.Print((L["|cffff8c1a%s|r%s%s"]):format(label,
        tapped and L[" |cff999999(already tagged)|r"] or "",
        mapID and (L[" near %.1f, %.1f"]):format(x * 100, y * 100) or ""))
    if FlashClientIcon then FlashClientIcon() end
end

local function Check(unit)
    if not Enabled() or ns.AnySecret("rare alert", unit) or not unit then return end
    if not ns.Readable(UnitExists(unit), "rare alert") then return end
    local classification = ns.Readable(UnitClassification(unit), "rare alert")
    if classification and RARE[classification] then
        Alert(unit)
    end
end

local events = CreateFrame("Frame")
events:RegisterEvent("NAME_PLATE_UNIT_ADDED")
events:RegisterEvent("PLAYER_TARGET_CHANGED")
events:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
events:SetScript("OnEvent", function(_, event, unit)
    if event == "NAME_PLATE_UNIT_ADDED" then
        Check(unit)
    elseif event == "PLAYER_TARGET_CHANGED" then
        Check("target")
    else
        Check("mouseover")
    end
end)

-- /gcr rare : quick test of the alert
ns.TestRareAlert = function()
    Sound()
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "RARE: Test Rare (12)", { r = 1, g = 0.55, b = 0.1 })
    end
end
