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

---------------------------------------------------------------------------
-- Which nodes get a ring (Q2): in the zone you are in, within the radius,
-- and only what this character can gather - the profession (what the map
-- filter knows) and enough skill (the trainer colour is not red; a bonus
-- counts). Chests only while chests are shown. Not a node just harvested or
-- found empty, nor one parked as always empty (the run's own rest times).
---------------------------------------------------------------------------
-- Options > Map & minimap: 50, 75 (default) or 100 yards
local RADII = { 50, 75, 100 }
ns.QUEST_RADII = RADII
local RADIUS = 75
-- Q4: every TICK it looks whether anything changed: MOVE yards walked, a new
-- zone, a node changed, or REFRESH seconds gone (rest times run out, your
-- skill went up). Only then the zone's nodes are gone through again.
local TICK = 0.5
local MOVE = 5      -- yards
local REFRESH = 2   -- seconds

local function Radius()
    local r = ns.db and ns.db.questRadius
    for _, v in ipairs(RADII) do if v == r then return r end end
    return RADIUS
end
ns.QuestRadius = Radius

local function CanGather(n)
    if not (n and n.x and n.y) or n.pendingReport then return false end
    if ns.IsOnCooldown and ns.IsOnCooldown(n) then return false end
    if ns.IsParked and ns.IsParked(n) then return false end
    if n.type == "chest" then return not ns.db.chestsHidden end
    if n.type ~= "herb" and n.type ~= "ore" then return false end
    if ns.GatherProfessions then
        local herb, ore, known = ns.GatherProfessions()
        if known and not ((n.type == "herb" and herb) or (n.type == "ore" and ore)) then return false end
    end
    local rank, _, effective
    if ns.GetSkill then rank, _, effective = ns.GetSkill(n.type) end
    if not rank or ns.AnySecret("questing mode", rank, effective) then return false end
    local level = ns.SkillLevel(n.name, n.id, rank, effective)
    if level == "red" then return false end
    -- Options > Leveling, "Hide grey nodes": no more skill-ups, no ring either
    if level == "grey" and ns.db.hideGreyNodes then return false end
    return true
end
ns.QuestCanGather = CanGather

-- the nodes to light now: mapID, set (node -> true), or nil
local function Pick()
    local mapID, px, py = ns.GetPlayerPos()
    if not (mapID and px and py) then return end
    local want, r = {}, Radius()
    local nearest, nearestD
    for _, n in ipairs(ns.db.nodes[mapID] or {}) do
        if CanGather(n) then
            -- in whole yards, as the game shows them (75.0000001 is 75)
            local d = math.floor(ns.Distance(mapID, px, py, n.x, n.y) + 0.5)
            if d <= r then
                want[n] = true
                if not nearestD or d < nearestD then nearest, nearestD = n, d end
            end
        end
    end
    return mapID, want, nearest
end

-- Options: an arrow to the nearest ring (UI.lua draws it). Only which way
-- and how far: no route, no line. Off by default.
local arrowNode, arrowMap
ns.QuestArrowNode = function()
    if On() and ns.db.questArrow and arrowNode then return arrowNode, arrowMap end
end

local ticker
local picks = 0 -- how often the nodes were gone through (the tests count it)
local last = { at = -math.huge }
local dirty = true

local function Update()
    if not (On() and ns.SetQuestRings) then return end
    picks = picks + 1
    local mapID, px, py = ns.GetPlayerPos()
    last.map, last.x, last.y, last.at = mapID, px, py, GetTime()
    dirty = false
    local want, nearest
    mapID, want, nearest = Pick()
    arrowNode, arrowMap = nearest, mapID
    ns.SetQuestRings(mapID, want)
    if ns.UpdateArrow then ns.UpdateArrow() end
end
ns.UpdateQuestRings = Update
ns.QuestPicks = function() return picks end

-- every TICK while on: go through the nodes only when something changed
local function Tick()
    if not On() then return end
    if not dirty and GetTime() - last.at < REFRESH then
        local mapID, px, py = ns.GetPlayerPos()
        if mapID == last.map and px and last.x and ns.Distance(mapID, last.x, last.y, px, py) < MOVE then return end
    end
    Update()
end

-- the gathering help (Fishing.lua) follows it too
table.insert(listeners, function() if ns.UpdateGatherHelp then ns.UpdateGatherHelp("questing mode") end end)

-- the rings follow the state: a ticker only while it is on
table.insert(listeners, function(on)
    if ticker then ticker:Cancel() ticker = nil end
    if on then
        ticker = C_Timer.NewTicker(TICK, Tick)
        Update()
    else
        arrowNode, arrowMap = nil, nil
        if ns.SetQuestRings then ns.SetQuestRings(nil, nil) end
        if ns.UpdateArrow then ns.UpdateArrow() end
    end
end)

-- a node came, went or changed (harvested, found empty, options): look again
table.insert(ns.nodeListeners, function() dirty = true end)

-- Key binding (Bindings.xml)
function Gathercraft_QuestMode() ns.ToggleQuestMode() end

local loader = CreateFrame("Frame", "GathercraftQuestWatch")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function()
    -- kept from the last session: the rings come back on their own
    if On() then Changed() end
end)
