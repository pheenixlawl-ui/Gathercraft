local ADDON_NAME, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })

---------------------------------------------------------------------------
-- Questing mode (v0.1.19, Sven 08.11.2026): gather along the way while you
-- quest, without a farm run. Nodes near you that you can gather get the
-- gold ring of a run target on the minimap. Nothing else: no window, no
-- numbers, no route, no line.
--   * on / off: Ctrl + right-click on the minimap button, /gcr quest, a key
--     binding, Options > Map & minimap; kept over /reload and login
--   * a farm run or fishing turns it off (it says so); it stays off after
--   * it only shows: nothing moves, targets, gathers or changes a setting
---------------------------------------------------------------------------

local function On() return ns.db and ns.db.questMode and true or false end
ns.QuestModeOn = On

local listeners = {} -- called with the new state (the rings, Q2)
ns.questModeListeners = listeners

local function Changed()
    for _, fn in ipairs(listeners) do fn(On()) end
end

local OFF_REASON = {
    run = "Questing mode off: a farm run started.",
    fishing = "Questing mode off: you started fishing.",
}

-- on: true / false. why: nil (you switched it) or a key of OFF_REASON
local function SetQuestMode(on, why)
    if not ns.db then return end
    on = on and true or false
    if on == On() then return end
    ns.db.questMode = on or nil
    if on then
        ns.Print(L["Questing mode on – nearby nodes get a gold ring"])
    else
        ns.Print(L[OFF_REASON[why] or "Questing mode off"])
    end
    Changed()
end
ns.SetQuestMode = SetQuestMode

ns.ToggleQuestMode = function() SetQuestMode(not On()) end

-- a farm run or fishing starts (Route.lua, Fishing.lua)
ns.QuestModeOff = function(why)
    if On() then SetQuestMode(false, why) end
end

-- Key binding (Bindings.xml)
function Gathercraft_QuestMode() ns.ToggleQuestMode() end

local loader = CreateFrame("Frame", "GathercraftQuestWatch")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    -- kept from the last session: the rings come back on their own
    if On() then Changed() end
end)
