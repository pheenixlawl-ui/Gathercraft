local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- Rare alert (local only, nothing is sent to anyone)
--   Watches what your own client shows you: nameplates, mouseover and
--   target. A rare or rare elite in range gives a sound, a voice "Rare!"
--   (if the client has text-to-speech) and a big warning on screen.
--   Range = your nameplate range, so keep enemy nameplates on (V key).
---------------------------------------------------------------------------
local REPEAT_AFTER = 300 -- seconds before the same rare alerts again
local RARE = { rare = true, rareelite = true }

local seen = {} -- GUID -> time of last alert

local function Enabled()
    return ns.db and ns.db.rareAlert ~= false
end

-- Deep US English male voice if the system has one (Windows: David / Mark,
-- macOS: Alex / Fred), else the default text-to-speech voice
local PREFERRED_VOICES = { "david", "mark", "guy", "alex", "fred", "male" }
local voiceID

local function PickVoice()
    if voiceID ~= nil then return voiceID end
    voiceID = false
    local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
    if voices and #voices > 0 then
        for _, wanted in ipairs(PREFERRED_VOICES) do
            for _, v in ipairs(voices) do
                if v.name and v.name:lower():find(wanted, 1, true) then
                    voiceID = v.voiceID
                    return voiceID
                end
            end
        end
        voiceID = voices[1].voiceID
    end
    return voiceID
end

-- Returns true when the voice could be played
local function Speak(text)
    if ns.db.rareVoice == false or not (C_VoiceChat and C_VoiceChat.SpeakText) then return false end
    local voice = PickVoice()
    if not voice then return false end
    local rate = -2 -- a little slower sounds deeper and more dramatic
    -- The signature changed between client versions: try both
    if Enum and Enum.VoiceTtsDestination then
        if pcall(C_VoiceChat.SpeakText, voice, text, Enum.VoiceTtsDestination.LocalPlayback, rate, 100) then return true end
    end
    return (pcall(C_VoiceChat.SpeakText, voice, text, rate, 100, true))
end

local function Sound(spoke)
    -- Extra sound only if wanted, or as a fallback when no voice could play
    if ns.db.rareSound or not spoke then
        PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
    end
end

local function Alert(unit)
    local guid = UnitGUID(unit)
    if not guid or UnitIsDead(unit) or UnitIsPlayer(unit) then return end
    local now = GetTime()
    if seen[guid] and now - seen[guid] < REPEAT_AFTER then return end
    seen[guid] = now

    local name = UnitName(unit) or "?"
    local elite = UnitClassification(unit) == "rareelite"
    local level = UnitLevel(unit)
    local tapped = UnitIsTapDenied and UnitIsTapDenied(unit)
    local label = ("RARE%s: %s%s"):format(elite and " ELITE" or "", name,
        (level and level > 0) and (" (" .. level .. ")") or "")

    Sound(Speak(elite and "Rare elite!" or "Rare!"))
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, label, { r = 1, g = 0.55, b = 0.1 })
    end
    local mapID, x, y = ns.GetPlayerPos()
    ns.Print(("|cffff8c1a%s|r%s%s"):format(label,
        tapped and " |cff999999(already tagged)|r" or "",
        mapID and (" near %.1f, %.1f"):format(x * 100, y * 100) or ""))
    if FlashClientIcon then FlashClientIcon() end
end

local function Check(unit)
    if not Enabled() or not unit or not UnitExists(unit) then return end
    if RARE[UnitClassification(unit)] then
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
    Sound(Speak("Rare!"))
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "RARE: Test Rare (12)", { r = 1, g = 0.55, b = 0.1 })
    end
end
