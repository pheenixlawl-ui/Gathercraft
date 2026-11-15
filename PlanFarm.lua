local ADDON_NAME, ns = ...

---------------------------------------------------------------------------
-- "Farm for plan": the shopping list of the skill plan on the map (0.2 B3)
--
-- Part 1 - which node kinds bring a material:
--
--   * base: the checked spawn data and nothing else. A node kind (herb or
--     ore) whose main item is the material. Only this decides what a plan
--     run routes to and what glows fully. What a node happened to give
--     you (n.item, the first loot the recorder saw) is NOT a base - not
--     even on a kind the spawn data knows. Chests have no item and are
--     never part of it.
--   * seen: your own gathers, counted by a listener that only reads. Per
--     node kind (its object ID): how many recorded gathers, and in how
--     many of them an item was in the loot. No quantities (the recorder
--     cannot tell a read 1 from an unreadable one), no chances. Shown
--     from 20 gathers of the kind and 5 with the item on - as "seen in 7
--     of 23 recorded gathers". A seen item glows weaker and is never
--     routed to, never counts for the end of a run.
--     The listener does not see every gather: the same spawn opened again
--     never reaches it, a second cultivated copy neither. So this is no
--     full yield statistic.
--   * never: sync data (it knows one item a node), lists from memory.
---------------------------------------------------------------------------
local SEEN_MIN_GATHERS = 20 -- recorded gathers of a kind before anything of it is shown
local SEEN_MIN_ITEM = 5     -- gathers with the item in the loot before it is shown
local SEEN_MAX_ITEMS = 50   -- items remembered per kind; the rarest makes room for a new one

---------------------------------------------------------------------------
-- base
---------------------------------------------------------------------------
local baseKinds -- itemID -> { kind key, ... } in a fixed order; built on first use (the data files load later)

local function Kinds()
    local data = GathercraftQuestieData
    return data and data.kinds
end

local function BuildBase()
    local kinds = Kinds()
    if not kinds then return {} end -- (not kept: the data may still come)
    local index = {}
    for key, kind in pairs(kinds) do
        if (kind[1] == "h" or kind[1] == "o") and type(kind[2]) == "number" and kind[2] > 0 then
            local list = index[kind[2]]
            if not list then
                list = {}
                index[kind[2]] = list
            end
            list[#list + 1] = key
        end
    end
    for _, list in pairs(index) do table.sort(list) end
    baseKinds = index
    return index
end

-- The main item of a node kind ("o1731" -> 2770), nil for a chest, a
-- fishing spot or a kind the spawn data does not know
ns.PlanBaseItem = function(kindKey)
    local kinds = Kinds()
    local kind = kinds and type(kindKey) == "string" and kinds[kindKey]
    if kind and (kind[1] == "h" or kind[1] == "o") and type(kind[2]) == "number" and kind[2] > 0 then return kind[2] end
    return nil
end

-- The node kinds whose main item this is: { "o1731", ... } or nil. Don't
-- change the table.
ns.PlanBaseKinds = function(itemID)
    return (baseKinds or BuildBase())[itemID]
end

-- Does this node bring one of the wanted materials (a set itemID -> true)?
-- Asked of the node's KIND; what the node itself says it gave is ignored.
ns.PlanNodeMatches = function(node, wanted)
    local item = node and ns.PlanBaseItem(node.id)
    return (item and wanted and wanted[item]) and true or false
end

---------------------------------------------------------------------------
-- seen
---------------------------------------------------------------------------
local seenRev = 0   -- counts up with every counted gather
local seenIndex, seenIndexRev, seenIndexTable -- itemID -> { { id, seen, n }, ... } over the threshold

local function CountGather(node, p)
    if type(node) ~= "table" or type(p) ~= "table" then return end
    if node.type ~= "herb" and node.type ~= "ore" then return end
    local key = node.id
    -- (asked whether it is hidden BEFORE it is compared with anything)
    if ns.AnySecret("plan loot", key) or type(key) ~= "string" or key == "" then return end
    if type(p.items) ~= "table" or #p.items == 0 then return end -- loot nobody could read is no observation
    local main = ns.PlanBaseItem(key)
    local once = {}
    for _, it in ipairs(p.items) do
        local id = type(it) == "table" and it.id
        if not ns.AnySecret("plan loot", id) and type(id) == "number" and id > 0 and id ~= main then once[id] = true end
    end
    local db = ns.db
    if type(db) ~= "table" then return end
    if type(db.kindLoot) ~= "table" then db.kindLoot = {} end
    local entry = db.kindLoot[key]
    if type(entry) ~= "table" or type(entry.n) ~= "number" or type(entry.items) ~= "table" then
        entry = { n = 0, items = {} }
        db.kindLoot[key] = entry
    end
    entry.n = entry.n + 1
    local items = entry.items
    for id in pairs(once) do
        if items[id] then
            items[id] = items[id] + 1
        else
            local count, rarest, rarestCount = 0, nil, nil
            for other, c in pairs(items) do
                count = count + 1
                if not rarest or c < rarestCount or (c == rarestCount and other > rarest) then rarest, rarestCount = other, c end
            end
            if count >= SEEN_MAX_ITEMS then items[rarest] = nil end
            items[id] = 1
        end
    end
    seenRev = seenRev + 1
end

-- The listener: only reads the node and the gather, and keeps its own
-- errors to itself (the listeners are called one after the other without a
-- pcall - an error here must not stop the others)
table.insert(ns.gatherListeners, function(node, p)
    local ok, err = pcall(CountGather, node, p)
    if not ok and ns.Debug then ns.Debug("PLAN loot listener: " .. tostring(err)) end
end)

-- The node kinds this item was seen at often enough:
-- { { id = "o1731", seen = 7, n = 23 }, ... } most gathers with it first,
-- or nil. Never a base, never routed to. Don't change the tables.
ns.PlanSeen = function(itemID)
    local loot = ns.db and ns.db.kindLoot
    if type(loot) ~= "table" then return nil end
    if seenIndexRev ~= seenRev or seenIndexTable ~= loot then
        local index = {}
        for key, entry in pairs(loot) do
            if type(entry) == "table" and type(entry.n) == "number" and entry.n >= SEEN_MIN_GATHERS and type(entry.items) == "table" then
                for id, c in pairs(entry.items) do
                    if type(c) == "number" and c >= SEEN_MIN_ITEM then
                        local list = index[id]
                        if not list then
                            list = {}
                            index[id] = list
                        end
                        list[#list + 1] = { id = key, seen = c, n = entry.n }
                    end
                end
            end
        end
        for _, list in pairs(index) do
            table.sort(list, function(a, b)
                if a.seen ~= b.seen then return a.seen > b.seen end
                return a.id < b.id
            end)
        end
        seenIndex, seenIndexRev, seenIndexTable = index, seenRev, loot
    end
    return seenIndex[itemID]
end

-- 20, 5, 50: the thresholds, for texts and tests
ns.PlanSeenLimits = function() return SEEN_MIN_GATHERS, SEEN_MIN_ITEM, SEEN_MAX_ITEMS end
ns.PlanSeenRev = function() return seenRev end

---------------------------------------------------------------------------
-- Part 2 - the plan run (concept 4.2, 4.3, 4.5, 4.6, 4.8)
--
-- A plan run is an ordinary run with the filter "plan:v1:<profkey>:<target>"
-- in ONE zone. What it farms is not kept: it is read from the skill plan
-- (ns.SkillPlanFor - the same plan the window shows, one calculation, one
-- revision) every time something changes:
--   B  what the plan still needs (need > 0)
--   K  those of B with a base kind (part 1) - the only thing the end of
--      the run is checked against
--   R  the nodes the route may take: K not yet covered, in the run's zone,
--      picked and not parked, of a kind you can gather
-- Loot never counts: a material is covered when the plan says you HAVE
-- what it needs, and that count is known.
--
-- The state, worked out anew after every change (and before the route's
-- own ways of ending - an empty route never ends a plan run):
--   invalid   no plan to go by: the skill cannot be read, the plan is only
--             a preview (skill seen last: reliable == false), the window
--             shows another profession, the calculation broke. Nothing is
--             decided, the last materials stay ("plan unknown right now").
--   waiting   loot or a skill change is on its way to the bags, or the
--             plan is being worked out anew (updating): decided on the
--             next plan.
--   success   a complete plan, and every material of K is covered with a
--             known count. Also with no K at all.
--   blocked   no success, and no node left to go to here. Why, per
--             material: no_skill, not_in_zone, kinds_off, parked - or
--             the plan itself is incomplete.
--   active    else.
-- success and blocked end the run, once and silently (no "Run stopped.",
-- no run summary); blocked shows a small window that says why (Sven V5).
---------------------------------------------------------------------------
local L = ns.L or setmetatable({}, { __index = function(_, k) return k end })
local SETTLE_NO_BAGS = 2  -- seconds after the loot window closed without a bag update: the bags count as settled (V9)
local SETTLE_SAFETY = 10  -- seconds after loot or a skill change without any sign of the bags: the same
local LOOK_DELAY = 0.2    -- a burst of events is one look

-- ---- the filter
local profByKey, keyByProf
local function ProfKeys()
    if profByKey then return profByKey, keyByProf end
    local d = ns.CraftData
    if not (d and d.Professions) then return {}, {} end
    profByKey, keyByProf = {}, {}
    for _, p in ipairs(d.Professions) do
        local key = p.name:lower():gsub(" ", "_")
        profByKey[key], keyByProf[p.name] = p.name, key
    end
    return profByKey, keyByProf
end

-- "plan:v1:first_aid:150" for a profession (its English name, as in the
-- recipe data) and a target; nil for anything else
ns.PlanFilter = function(prof, target)
    local _, keys = ProfKeys()
    local lo, hi = 1, 300
    if ns.SkillPlanTargetRange then lo, hi = ns.SkillPlanTargetRange() end
    if not keys[prof] or type(target) ~= "number" or target ~= math.floor(target) or target < lo or target > hi then return nil end
    return ("plan:v1:%s:%d"):format(keys[prof], target)
end

-- The profession and target of a plan filter - read back through an exact
-- table of the keys, never through a name in some language. nil for
-- another version, an unknown profession, a target out of range.
ns.PlanFilterParse = function(filter)
    if type(filter) ~= "string" then return nil end
    local version, key, target = filter:match("^plan:v(%d+):([a-z_]+):(%d+)$")
    if version ~= "1" then return nil end
    local profs = ProfKeys()
    local prof = profs[key]
    target = tonumber(target)
    local lo, hi = 1, 300
    if ns.SkillPlanTargetRange then lo, hi = ns.SkillPlanTargetRange() end
    if not prof or not target or target < lo or target > hi then return nil end
    return prof, target
end

-- ---- the run
local pr          -- the plan run: { prof, target, zone, filter, wanted, ... } - nil without one
local probeSet    -- the materials a question about a zone asks for (no run needed)
local probeFilter
local lastEnd     -- how the last plan run ended: { kind, prof, target, zone, rows, offMap, reasons }
local ends = 0    -- counts every end (success or blocked)
local resuming = false
local RefreshZoneList -- (part 3)
local SetGlow         -- (part 4)

-- who of this file reads the skill plan right now ("run", "list", "ask"):
-- with nobody, and the window closed, nothing is worked out
local readers = {}
local function Runner(who, on)
    readers[who] = on and true or nil
    if ns.SkillPlanRunner then ns.SkillPlanRunner(next(readers) ~= nil) end
end

local REASON_TEXT = {
    no_skill = "can't gather yet",
    not_in_zone = "not in this zone",
    kinds_off = "node types switched off",
    parked = "parked",
    plan_incomplete = "the plan is incomplete - see the skill plan",
}
local INVALID_TEXT = {
    window = "the skill plan shows another profession",
    skill = "your skill can't be read",
    broke = "the plan could not be worked out",
    preview = "the plan is only a preview (skill last seen)",
    off = "there is no plan to go by",
    invalid = "there is no plan to go by",
}

-- Does this node count for the plan run (or for the question being asked)?
ns.PlanRunMatches = function(node, filter)
    if probeSet and filter == probeFilter then return ns.PlanNodeMatches(node, probeSet) end
    if pr and filter == pr.filter then return ns.PlanNodeMatches(node, pr.wanted) end
    return false
end

-- ---- are the bags settled?
local settle = { lootOpen = false, since = nil, closedAt = nil }
local function Unsettled()
    if not settle.since then return false end
    local now = GetTime()
    if settle.closedAt and now - settle.closedAt >= SETTLE_NO_BAGS then return false end
    if not settle.lootOpen and not settle.closedAt and now - settle.since >= SETTLE_NO_BAGS and settle.cause == "skill" then return false end
    if now - settle.since >= SETTLE_SAFETY then return false end
    return true
end
local function Unsettle(cause)
    settle.since, settle.cause, settle.closedAt = GetTime(), cause, nil
end

-- ---- the plan, read
-- { state = "invalid", why } | { state = "waiting" } | { state = ..., rows, offMap, wanted, complete }
--   rows:   the materials of K: { item, need, have (nil: not known), ok }
--   offMap: the rest of B: { item, need, have, ok, seen (part 1) }
local function ReadPlan(prof, target)
    if not ns.SkillPlanFor then return { state = "invalid", why = "off" } end
    local result, why = ns.SkillPlanFor(prof, target)
    if not result then
        if why == "working" then return { state = "waiting", why = "plan" } end
        return { state = "invalid", why = why or "off" }
    end
    if result.updating then return { state = "waiting", why = "plan" } end
    if not result.valid then return { state = "invalid", why = "invalid" } end
    -- a preview (the skill was only seen last) says nothing about what you
    -- need or have reached now: no end, no tick from it
    if not result.reliable then return { state = "invalid", why = "preview" } end
    local rows, offMap, wanted = {}, {}, {}
    local ids = {}
    for item in pairs(result.items) do ids[#ids + 1] = item end
    table.sort(ids)
    for _, item in ipairs(ids) do
        local m = result.items[item]
        if type(m.need) == "number" and m.need > 0 then
            local known = m.haveKnown == true and type(m.have) == "number"
            local row = { item = item, need = m.need, have = known and m.have or nil, ok = known and m.have >= m.need }
            if ns.PlanBaseKinds(item) then
                rows[#rows + 1] = row
                if not row.ok then wanted[item] = true end
            else
                row.seen = ns.PlanSeen(item)
                offMap[#offMap + 1] = row
            end
        end
    end
    return { state = "read", rows = rows, offMap = offMap, wanted = wanted, revision = result.revision,
        complete = result.complete == true or result.status == "done", status = result.status }
end

-- why a wanted material has no node to go to in this zone
local function ReasonFor(item, zone)
    local kinds = {}
    for _, key in ipairs(ns.PlanBaseKinds(item) or {}) do kinds[key] = true end
    local inZone, picked, free = 0, 0, 0
    for _, n in ipairs((ns.db.nodes and ns.db.nodes[zone]) or {}) do
        if n.type ~= "chest" and kinds[n.id] then
            inZone = inZone + 1
            if ns.IsNodeEnabled(n, zone) then
                picked = picked + 1
                if not (ns.IsParked and ns.IsParked(n)) then free = free + 1 end
            end
        end
    end
    if inZone == 0 then return "not_in_zone" end
    if picked == 0 then return "kinds_off" end
    if free == 0 then return "parked" end
    return "no_skill"
end

-- The state of a plan run in a zone. points/weights: the run's own (from
-- its planning); without them the zone is asked.
local function Evaluate(spec, points, weights, read)
    local plan = read or ReadPlan(spec.prof, spec.target)
    if plan.state ~= "read" then return plan end
    if Unsettled() then
        plan.state, plan.why = "waiting", "bags"
        return plan
    end
    local open = next(plan.wanted) ~= nil
    if not open then
        if plan.complete then
            plan.state = "success"
        else
            plan.state, plan.reasons = "blocked", { { reason = "plan_incomplete" } }
        end
        return plan
    end
    if not points then
        local keepSet, keepFilter = probeSet, probeFilter
        probeSet, probeFilter = plan.wanted, spec.filter
        points, weights = ns.PlanRouteCandidates(spec.filter, spec.zone)
        probeSet, probeFilter = keepSet, keepFilter
        if not points then
            plan.state, plan.why = "waiting", "position"
            return plan
        end
    end
    local has, candidates = {}, 0
    for _, p in ipairs(points) do
        if (weights[p.kind] or 1) > 0 then
            local item = ns.PlanBaseItem(p.node.id)
            if item and plan.wanted[item] then
                has[item] = true
                candidates = candidates + 1
            end
        end
    end
    plan.candidates = candidates
    for _, row in ipairs(plan.rows) do
        if not row.ok and not has[row.item] then row.reason = ReasonFor(row.item, spec.zone) end
    end
    if candidates == 0 then
        plan.state, plan.reasons = "blocked", {}
        for _, row in ipairs(plan.rows) do
            if row.reason then plan.reasons[#plan.reasons + 1] = { item = row.item, reason = row.reason } end
        end
    else
        plan.state = "active"
    end
    return plan
end

local function ItemLabel(item)
    return (ns.ItemName and ns.ItemName(item)) or ("item " .. tostring(item))
end
local function ReasonList(reasons)
    local parts = {}
    for _, r in ipairs(reasons or {}) do
        local text = L[REASON_TEXT[r.reason] or r.reason]
        parts[#parts + 1] = r.item and ("%s (%s)"):format(ItemLabel(r.item), text) or text
    end
    return table.concat(parts, ", ")
end
ns.PlanReasonText = function(reason) return L[REASON_TEXT[reason] or reason] end

-- ---- the small window of a blocked end (Sven V5: a chat line is overlooked)
local hint
local function ShowHint(plan)
    if not hint then
        hint = CreateFrame("Frame", "GathercraftPlanHint", UIParent, "BackdropTemplate")
        hint:SetSize(380, 190)
        hint:SetPoint("CENTER", 0, 140)
        if hint.SetBackdrop then
            hint:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
                tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 11, top = 11, bottom = 11 } })
        end
        hint:SetFrameStrata("DIALOG")
        hint:SetClampedToScreen(true)
        hint:EnableMouse(true)
        hint:SetMovable(true)
        hint:RegisterForDrag("LeftButton")
        hint:SetScript("OnDragStart", hint.StartMoving)
        hint:SetScript("OnDragStop", hint.StopMovingOrSizing)
        hint:Hide()
        if UISpecialFrames then tinsert(UISpecialFrames, "GathercraftPlanHint") end
        hint.title = hint:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        hint.title:SetPoint("TOPLEFT", 24, -22)
        hint.title:SetWidth(332)
        hint.title:SetJustifyH("LEFT")
        hint.body = hint:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        hint.body:SetPoint("TOPLEFT", hint.title, "BOTTOMLEFT", 0, -10)
        hint.body:SetWidth(332)
        hint.body:SetJustifyH("LEFT")
        hint.body:SetWordWrap(true)
        hint.zones = CreateFrame("Button", nil, hint, "UIPanelButtonTemplate")
        hint.zones:SetSize(170, 24)
        hint.zones:SetPoint("BOTTOMLEFT", 22, 20)
        hint.zones:SetScript("OnClick", function()
            hint:Hide()
            if ns.PlanZoneListShow and hint.spec then ns.PlanZoneListShow(hint.spec.prof, hint.spec.target) end
        end)
        hint.close = CreateFrame("Button", nil, hint, "UIPanelButtonTemplate")
        hint.close:SetSize(110, 24)
        hint.close:SetPoint("BOTTOMRIGHT", -22, 20)
        hint.close:SetScript("OnClick", function() hint:Hide() end)
    end
    hint.title:SetText(L["Nothing left to farm for your plan here"])
    local lines = {}
    for _, r in ipairs(plan.reasons or {}) do
        local text = L[REASON_TEXT[r.reason] or r.reason]
        lines[#lines + 1] = r.item and ("%s: %s"):format(ItemLabel(r.item), text) or text
    end
    hint.body:SetText(table.concat(lines, "\n"))
    hint.zones:SetText(L["Where to farm"])
    hint.close:SetText(L["Close"])
    hint.spec = { prof = plan.prof, target = plan.target }
    hint.shown = (hint.shown or 0) + 1
    hint:Show()
end

-- ---- the end: once
local function Finish(run, plan, kind)
    if run.finished then return end
    run.finished = true
    plan.prof, plan.target = pr.prof, pr.target
    lastEnd = { kind = kind, prof = pr.prof, target = pr.target, zone = pr.zone, rows = plan.rows, offMap = plan.offMap, reasons = plan.reasons }
    ends = ends + 1
    ns.StopRun(true) -- silent: no "Run stopped.", no run summary; the saved run is gone
    if kind == "blocked" then
        ShowHint(plan)
    elseif ns.PlanRunGathered then
        ns.PlanRunGathered(lastEnd) -- the window "Gathered for your plan" (part 5)
    end
end

-- Route.lua, before every planning of a plan run: the plan's materials now.
-- A change of them collects the nodes anew. While the plan is not known the
-- last ones stay.
ns.PlanRunRefresh = function(run)
    if not pr or run.plan ~= pr.spec then return end
    -- the same profession in the open window with another target: the run follows (Sven V7)
    if ns.SkillPlanShown then
        local prof, target = ns.SkillPlanShown()
        if prof == pr.prof and target and target ~= pr.target then
            local filter = ns.PlanFilter(prof, target)
            if filter then
                pr.target, pr.filter, pr.spec.target = target, filter, target
                run.filter = filter
                if ns.db.activeRun then ns.db.activeRun.filter = filter end
                run.pointsDirty = true
            end
        end
    end
    local plan = ReadPlan(pr.prof, pr.target)
    pr.read = plan
    if plan.state ~= "read" then return end
    local same = true
    for item in pairs(plan.wanted) do if not pr.wanted[item] then same = false end end
    for item in pairs(pr.wanted) do if not plan.wanted[item] then same = false end end
    if not same then
        pr.wanted = plan.wanted
        run.pointsDirty = true
    end
    -- what glows follows the plan: the pins are told when it changed
    local glowChanged = SetGlow and SetGlow(plan)
    if (not same or glowChanged) and ns.PlanPinsChanged then ns.PlanPinsChanged() end
end

-- Route.lua, in every planning of a plan run, before the route's own ways
-- of ending: "go" (plan the route), "hold" (nothing is decided now), "end"
-- (the run has been ended here)
ns.PlanRunJudge = function(run, points, weights)
    if not pr or run.plan ~= pr.spec or run.finished then return "hold" end
    local read = pr.read
    pr.read = nil
    local plan = Evaluate(pr, points, weights, read)
    pr.state, pr.plan = plan.state, plan
    if plan.rows then pr.known = plan end -- (what was last read stays for the window while the plan is not known)
    if plan.state == "success" or plan.state == "blocked" then
        Finish(run, plan, plan.state)
        return "end"
    end
    if plan.state == "active" then return "go" end
    -- waiting or no plan to go by: nothing is decided and nothing ends. The
    -- route goes on with the materials read last (Sven V4), if it has a node.
    for _, p in ipairs(points) do
        if (weights[p.kind] or 1) > 0 then return "go" end
    end
    return "hold"
end

-- Route.lua, StartRun with a plan filter - before anything is stopped. The
-- run's spec { prof, target } or nil (said why: no run).
ns.PlanRunBegin = function(filter, zone)
    local prof, target = ns.PlanFilterParse(filter)
    if not prof then
        ns.Print(L["That is no plan run Gathercraft knows (unknown format). Start it from the skill plan."])
        return nil
    end
    if not zone then
        ns.Print(L["No position available here."])
        return nil
    end
    local spec = { prof = prof, target = target, zone = zone, filter = filter }
    if not resuming then
        -- asked for now (a click, a command): with everything gathered, nothing
        -- to farm here or no plan to go by there is no run, only why
        Runner("ask", true)
        local plan = Evaluate(spec)
        Runner("ask", false)
        if plan.state == "success" then
            ns.Print(plan.status == "done" and L["Target reached: nothing left to farm for your plan."] or L["Everything from the map is gathered for your plan."])
            return nil
        elseif plan.state == "blocked" then
            ns.Print((L["Nothing you can farm for this plan here: %s"]):format(ReasonList(plan.reasons)))
            -- a material is open and has no node to go to here: the list of
            -- zones opens (Sven V12) - it starts nothing
            for _, r in ipairs(plan.reasons) do
                if r.item and ns.PlanZoneListShow then ns.PlanZoneListShow(prof, target) break end
            end
            return nil
        elseif plan.state == "invalid" then
            ns.Print((L["No plan run: %s."]):format(L[INVALID_TEXT[plan.why] or INVALID_TEXT.invalid]))
            return nil
        end
    end
    return spec
end

-- Route.lua, after the run before was stopped: this plan run is the one now
ns.PlanRunBegun = function(spec)
    pr = { spec = spec, prof = spec.prof, target = spec.target, zone = spec.zone, filter = spec.filter, wanted = {} }
    settle.since, settle.closedAt, settle.lootOpen = nil, nil, false
    Runner("run", true)
    -- (a run has begun: the list of zones has done its work)
    local zones = _G.GathercraftPlanZones
    if zones and zones:IsShown() then zones:Hide() end
    -- everything that is not of the plan steps back at once
    if ns.PlanPinsChanged then ns.PlanPinsChanged() end
end

-- Route.lua, StopRun of a plan run (whoever stopped it)
ns.PlanRunStopped = function()
    pr = nil
    Runner("run", false)
    -- no plan run, no factor: every pin is as it was
    if ns.PlanPinsChanged then ns.PlanPinsChanged() end
end

-- Core.lua, after a reload: the saved plan run goes on - or, with a format
-- this version does not know, is dropped and said so (no other route
-- instead, no search by name)
ns.PlanRunResume = function(saved)
    local prof = ns.PlanFilterParse(saved and saved.filter)
    if not prof or type(saved.zone) ~= "number" then
        ns.db.activeRun = nil
        ns.Print(L["Your saved plan run can't be resumed (unknown format). Start it again from the skill plan."])
        return false
    end
    resuming = true
    local ok, err = pcall(ns.StartRun, saved.filter, saved.zone)
    resuming = false
    if not ok then error(err, 0) end
    return ns.run ~= nil
end

-- Something the plan reads may have changed: one look for a burst of events
local lookPending = false
local listWaits = false -- the list of zones waits for a plan that is being worked out
local function Look()
    lookPending = false
    if pr and ns.run and ns.run.plan == pr.spec and ns.RouteReplan then ns.RouteReplan() end
    if listWaits and RefreshZoneList then RefreshZoneList() end
end
ns.PlanRunLook = function()
    if not (pr or listWaits) or lookPending then return end
    lookPending = true
    C_Timer.After(LOOK_DELAY, Look)
end

local watch = CreateFrame("Frame")
for _, e in ipairs({ "BAG_UPDATE_DELAYED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYERBANKSLOTS_CHANGED", "PLAYERREAGENTBANKSLOTS_CHANGED",
    "SKILL_LINES_CHANGED", "NEW_RECIPE_LEARNED", "TRADE_SKILL_LIST_UPDATE", "LOOT_OPENED", "LOOT_READY", "LOOT_CLOSED" }) do
    pcall(watch.RegisterEvent, watch, e)
end
watch:SetScript("OnEvent", function(_, event)
    if not pr then return end
    if event == "LOOT_OPENED" or event == "LOOT_READY" then
        settle.lootOpen = true
        Unsettle("loot")
    elseif event == "LOOT_CLOSED" then
        settle.lootOpen = false
        if settle.since then
            settle.closedAt = GetTime()
            -- no bag update may follow (full bags, nothing taken): look again then
            C_Timer.After(SETTLE_NO_BAGS + 0.05, ns.PlanRunLook)
        end
    elseif event == "SKILL_LINES_CHANGED" then
        -- a skill point comes before the bags of the craft or the gather that gave it
        if not settle.since then
            Unsettle("skill")
            C_Timer.After(SETTLE_NO_BAGS + 0.05, ns.PlanRunLook)
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        if not settle.lootOpen then settle.since, settle.closedAt = nil, nil end
    end
    ns.PlanRunLook()
end)
-- a new plan (the window worked one out while it was open): looked at
local OnNewPlan -- (part 3: the list of zones is worked out anew with a new plan)
if ns.skillPlanListeners then
    table.insert(ns.skillPlanListeners, function()
        if pr then ns.PlanRunLook() end
        if OnNewPlan then OnNewPlan() end
    end)
end
-- a gather that was booked: its loot is on the way to the bags
table.insert(ns.gatherListeners, function()
    if not pr then return end
    if not settle.since then Unsettle("loot") end
    C_Timer.After(SETTLE_SAFETY + 0.05, ns.PlanRunLook)
end)

-- For the run window, the tests and /gcr debug: the plan run now
-- { prof, target, zone, filter, state, why, rows, offMap, reasons, candidates } or nil
ns.PlanRunState = function()
    if not pr then return nil end
    local plan = pr.plan or {}
    local known = plan.rows and plan or pr.known or {}
    -- frozen: the rows are the ones read last, the plan is not known right now
    return { prof = pr.prof, target = pr.target, zone = pr.zone, filter = pr.filter, state = pr.state or "waiting", why = plan.why,
        rows = known.rows, offMap = known.offMap, reasons = plan.reasons, candidates = plan.candidates, wanted = pr.wanted,
        frozen = pr.state == "invalid", hidden = pr.hidden or 0 }
end
-- how the last plan run ended and how many ended at all (tests, the windows)
ns.PlanRunLastEnd = function() return lastEnd, ends end
-- What a click on "Farm for plan" would find in this zone - nothing starts:
-- { state, why, rows, offMap, reasons, candidates }
ns.PlanRunCheck = function(prof, target, zone)
    local filter = ns.PlanFilter(prof, target)
    if not filter then return { state = "invalid", why = "invalid" } end
    Runner("ask", true)
    local plan = Evaluate({ prof = prof, target = target, zone = zone, filter = filter })
    Runner("ask", false)
    return plan
end

---------------------------------------------------------------------------
-- Part 3 - which zone (concept 4.7, Sven E6/E9, V11, V12)
--
-- A plan run farms ONE zone: the one you stand in when you click "Farm for
-- plan" (a capital counts as its zone; one node to go to is enough), or
-- the one you click in the list "Where to farm for your plan". Nothing
-- ever picks another zone for you: no jump to the nearest zone, no group
-- of zones, no change of zone while the run goes.
--
-- The list: the zones of your continent that have a node to go to for a
-- material still open (the rules of R, zone by zone), with the number of
-- different known places of each such material there - counted as the item
-- tooltip counts them (SpawnCounts.lua: places, not entries; its own user
-- "plan", whatever the tooltip option says). Most places first, your zone
-- marked. No "best", no gold, no distance. It is worked out when it opens
-- and when the plan has a new revision - not while you point at it.
---------------------------------------------------------------------------
local LIST_ROWS = 10      -- zones shown at once (the wheel moves the list)
local LIST_ITEMS = 3      -- materials named in a row, then "+N more"
local list                -- the window
local listSpec            -- { prof, target, filter } while it is shown
local listData            -- what it shows: { state, why, zones = { ... }, revision }
local listBuilds = 0      -- how often the list was worked out (tests)
local listOffset = 0

local function Here()
    local here = ns.GetPlayerPos and ns.GetPlayerPos()
    return here and ((ns.CITY_ZONE and ns.CITY_ZONE[here]) or here) or nil
end

-- The zones for a plan: { state, why, here, zones = { { mapID, name, here, places, candidates,
-- items = { { item, places (nil: not counted yet), candidates }, ... } }, ... }, counting }
local function BuildZoneList(spec)
    listBuilds = listBuilds + 1
    local plan = ReadPlan(spec.prof, spec.target)
    local data = { state = plan.state, why = plan.why, zones = {}, revision = plan.revision, here = Here() }
    if plan.state ~= "read" then return data end
    data.state = "ok"
    if not next(plan.wanted) then return data end
    local continent = data.here and ns.GetContinent and ns.GetContinent(data.here)
    if not continent then return data end
    local maps = {}
    for mapID in pairs(ns.db.nodes or {}) do
        if type(mapID) == "number" and ns.GetContinent(mapID) == continent then maps[#maps + 1] = mapID end
    end
    table.sort(maps)
    local keepSet, keepFilter = probeSet, probeFilter
    probeSet, probeFilter = plan.wanted, spec.filter
    for _, mapID in ipairs(maps) do
        local points, weights = ns.PlanRouteCandidates(spec.filter, mapID)
        local per, any = {}, false
        for _, p in ipairs(points or {}) do
            if (weights[p.kind] or 1) > 0 then
                local item = ns.PlanBaseItem(p.node.id)
                if item and plan.wanted[item] then
                    per[item] = (per[item] or 0) + 1
                    any = true
                end
            end
        end
        if any then
            local zone = { mapID = mapID, name = ns.GetZoneName(mapID), here = mapID == data.here, places = 0, candidates = 0, items = {} }
            local ids = {}
            for item in pairs(per) do ids[#ids + 1] = item end
            table.sort(ids)
            for _, item in ipairs(ids) do
                -- the different known places of the item in this zone (never a sum over its node kinds)
                local places
                local counts = ns.SpawnCounts and ns.SpawnCounts(item)
                if counts then
                    places = 0
                    for _, z in ipairs(counts) do if z.mapID == mapID then places = z.total end end
                else
                    data.counting = true
                end
                zone.items[#zone.items + 1] = { item = item, places = places, candidates = per[item] }
                zone.places = zone.places + (places or 0)
                zone.candidates = zone.candidates + per[item]
            end
            table.sort(zone.items, function(a, b)
                if (a.places or 0) ~= (b.places or 0) then return (a.places or 0) > (b.places or 0) end
                return a.item < b.item
            end)
            data.zones[#data.zones + 1] = zone
        end
    end
    probeSet, probeFilter = keepSet, keepFilter
    table.sort(data.zones, function(a, b)
        if a.places ~= b.places then return a.places > b.places end
        if a.candidates ~= b.candidates then return a.candidates > b.candidates end
        return a.mapID < b.mapID
    end)
    return data
end

local function DrawZoneList()
    if not (list and list:IsShown() and listData) then return end
    local data = listData
    local zones = data.zones
    if listOffset > math.max(0, #zones - LIST_ROWS) then listOffset = math.max(0, #zones - LIST_ROWS) end
    list.title:SetText(L["Where to farm for your plan"])
    list.sub:SetText(L["Known spots for what you still need"])
    local note
    if data.state == "waiting" then
        note = L["Working out the plan ..."]
    elseif data.state ~= "ok" then
        note = (L["No plan to go by: %s."]):format(L[INVALID_TEXT[data.why] or INVALID_TEXT.invalid])
    elseif #zones == 0 then
        note = L["No known spots for the missing materials yet."]
    elseif data.counting then
        note = L["Counting the known spots ..."]
    elseif #zones > LIST_ROWS then
        note = (L["Zones %d-%d of %d (mouse wheel)"]):format(listOffset + 1, math.min(#zones, listOffset + LIST_ROWS), #zones)
    end
    list.note:SetText(note or "")
    for i = 1, LIST_ROWS do
        local row, zone = list.rows[i], zones[listOffset + i]
        if zone and data.state == "ok" then
            row.zone = zone
            row.name:SetText(zone.here and ("|cffffd060%s|r"):format(zone.name) or zone.name)
            local parts = {}
            for k = 1, math.min(LIST_ITEMS, #zone.items) do
                local it = zone.items[k]
                parts[k] = ("%s %s"):format(ItemLabel(it.item), it.places and tostring(it.places) or "...")
            end
            if #zone.items > LIST_ITEMS then parts[#parts + 1] = (L["+%d more"]):format(#zone.items - LIST_ITEMS) end
            row.items:SetText((zone.here and ("|cffffd060(%s)|r "):format(L["you are here"]) or "") .. table.concat(parts, " · "))
            row.go:SetText(L["Go"])
            row:Show()
        else
            row.zone = nil
            row:Hide()
        end
    end
end

RefreshZoneList = function()
    if not (list and list:IsShown() and listSpec) then
        listWaits = false
        return
    end
    listData = BuildZoneList(listSpec)
    listWaits = listData.state == "waiting"
    DrawZoneList()
    -- the counts are being built (the first time, or after a node change):
    -- worked out once more when they are there - asked for once a second,
    -- which costs nothing
    if listData.counting and not list.recount then
        list.recount = true
        local function Ask()
            if not (list:IsShown() and listData and listData.counting) then
                list.recount = nil
                return
            end
            for _, zone in ipairs(listData.zones) do
                for _, it in ipairs(zone.items) do
                    if not ns.SpawnCounts(it.item) then
                        C_Timer.After(1, Ask)
                        return
                    end
                end
            end
            list.recount = nil
            RefreshZoneList()
        end
        C_Timer.After(1, Ask)
    end
end

-- a new plan while the list is open: worked out anew, once per revision
OnNewPlan = function()
    if list and list:IsShown() and listSpec then
        C_Timer.After(0, function() if list:IsShown() then RefreshZoneList() end end)
    end
end

local function CloseZoneList()
    if list and list:IsShown() then list:Hide() end
end

-- "Go": a plan run in exactly this zone - the click is the choice
ns.PlanZoneListGo = function(mapID)
    local spec = listSpec
    if not spec or type(mapID) ~= "number" then return false end
    CloseZoneList()
    ns.StartRun(spec.filter, mapID)
    return ns.run ~= nil and ns.run.zone == mapID
end

-- Opens the list for a plan. It starts nothing.
ns.PlanZoneListShow = function(prof, target)
    local filter = ns.PlanFilter(prof, target)
    if not filter then return false end
    if not list then
        list = CreateFrame("Frame", "GathercraftPlanZones", UIParent, "BackdropTemplate")
        list:SetSize(520, 150 + LIST_ROWS * 24)
        list:SetPoint("CENTER", 0, 60)
        if list.SetBackdrop then
            list:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
                tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 11, top = 11, bottom = 11 } })
        end
        list:SetFrameStrata("DIALOG")
        list:SetClampedToScreen(true)
        list:EnableMouse(true)
        list:SetMovable(true)
        list:RegisterForDrag("LeftButton")
        list:SetScript("OnDragStart", list.StartMoving)
        list:SetScript("OnDragStop", list.StopMovingOrSizing)
        list:Hide()
        if UISpecialFrames then tinsert(UISpecialFrames, "GathercraftPlanZones") end
        list.title = list:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        list.title:SetPoint("TOPLEFT", 24, -22)
        list.sub = list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        list.sub:SetPoint("TOPLEFT", list.title, "BOTTOMLEFT", 0, -6)
        list.rows = {}
        for i = 1, LIST_ROWS do
            local row = CreateFrame("Frame", nil, list)
            row:SetSize(476, 22)
            row:SetPoint("TOPLEFT", 22, -70 - (i - 1) * 24)
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.name:SetPoint("LEFT", 2, 0)
            row.name:SetWidth(150)
            row.name:SetJustifyH("LEFT")
            row.name:SetWordWrap(false)
            row.items = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.items:SetPoint("LEFT", 156, 0)
            row.items:SetWidth(252)
            row.items:SetJustifyH("LEFT")
            row.items:SetWordWrap(false)
            row.go = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            row.go:SetSize(60, 20)
            row.go:SetPoint("RIGHT", 0, 0)
            row.go:SetScript("OnClick", function() if row.zone then ns.PlanZoneListGo(row.zone.mapID) end end)
            -- the whole row, uncut (a long zone name, many materials): only what the list has worked out
            if row.EnableMouse then row:EnableMouse(true) end
            row:SetScript("OnEnter", function(self)
                local zone = self.zone
                if not zone then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(zone.name, 1, 0.82, 0)
                if zone.here then GameTooltip:AddLine(L["you are here"], 0.6, 0.6, 0.6) end
                for _, it in ipairs(zone.items) do
                    GameTooltip:AddDoubleLine(ItemLabel(it.item), it.places and tostring(it.places) or "...", 1, 1, 1, 1, 1, 1)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            list.rows[i] = row
        end
        list.note = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        list.note:SetPoint("BOTTOMLEFT", 24, 24)
        list.note:SetWidth(340)
        list.note:SetJustifyH("LEFT")
        list.close = CreateFrame("Button", nil, list, "UIPanelButtonTemplate")
        list.close:SetSize(110, 24)
        list.close:SetPoint("BOTTOMRIGHT", -22, 18)
        list.close:SetScript("OnClick", CloseZoneList)
        if list.EnableMouseWheel then list:EnableMouseWheel(true) end
        list:SetScript("OnMouseWheel", function(_, delta)
            local max = math.max(0, #((listData and listData.zones) or {}) - LIST_ROWS)
            listOffset = math.max(0, math.min(max, listOffset - (delta or 0)))
            DrawZoneList() -- (only drawn: nothing is worked out for a turn of the wheel)
        end)
        list:SetScript("OnHide", function()
            listSpec, listData, listWaits = nil, nil, false
            Runner("list", false)
            if ns.SpawnCountsStop then ns.SpawnCountsStop("plan") end
        end)
    end
    list.close:SetText(L["Close"])
    listSpec, listOffset = { prof = prof, target = target, filter = filter }, 0
    Runner("list", true)
    if ns.SpawnCountsStart then ns.SpawnCountsStart("plan") end
    list:Show()
    RefreshZoneList()
    return true
end

-- what the list shows (tests, later the windows): the data, how often it
-- was worked out, the window
ns.PlanZoneListState = function() return listData, listBuilds, list end

-- "Farm for plan": a run for this plan in the zone you stand in - or, with
-- nothing to go to here, the list. Never another zone without a click.
ns.PlanFarmStart = function(prof, target)
    local filter = ns.PlanFilter(prof, target)
    local zone = Here()
    if not filter then return false end
    if not zone then
        ns.Print(L["No position available here."])
        return false
    end
    ns.StartRun(filter, zone)
    return ns.run ~= nil and ns.run.plan ~= nil
end

---------------------------------------------------------------------------
-- Part 4 - what glows (concept 4.9, Sven E2, E7)
--
-- While a plan run goes, Pins.lua asks for every pin, every time it sets
-- the pin's alpha or ring: is this node one of the plan (1), one a wanted
-- material was seen at (2), or neither (0)? Without a plan run the answer
-- is nil and the pins are as they always are. Nothing is kept at a pin.
-- The sets behind the answer are built when the plan's materials change,
-- never per pin.
---------------------------------------------------------------------------
ns.PlanGlowFor = function(node)
    if not pr then return nil end
    local id = node and node.id
    if not id or node.type == "chest" then return 0 end
    local item = ns.PlanBaseItem(id)
    if item and pr.wanted[item] then return 1 end
    if pr.seenKinds and pr.seenKinds[id] then return 2 end
    return 0
end

-- The kinds an open material without a base was seen at (part 1), and how
-- many of the plan's nodes in the run's zone "Hide grey nodes" keeps off
-- the map. Worked out with the plan's materials (PlanRunRefresh).
SetGlow = function(plan)
    local kinds, changed = {}, false
    for _, row in ipairs(plan.offMap or {}) do
        if not row.ok then
            for _, s in ipairs(row.seen or {}) do kinds[s.id] = true end
        end
    end
    local old = pr.seenKinds or {}
    for id in pairs(kinds) do if not old[id] then changed = true end end
    for id in pairs(old) do if not kinds[id] then changed = true end end
    pr.seenKinds = kinds
    local hidden = 0
    if ns.PinHiddenGrey then
        for _, n in ipairs((ns.db.nodes and ns.db.nodes[pr.zone]) or {}) do
            if ns.PlanNodeMatches(n, plan.wanted) and ns.PinHiddenGrey(n) then hidden = hidden + 1 end
        end
    end
    pr.hidden = hidden
    return changed
end

---------------------------------------------------------------------------
-- Part 5 - what you see (concept 3, 4.3, 4.8; Sven E8, V6)
--
--   * under the run window: the plan's materials, "have / need" with a
--     bar, a tick when your real count covers the need, "?" when the count
--     is not known, why a material has no node here; then "Not on the
--     map" (what the plan needs and no node kind brings: with have / need
--     and - if your own gathers found it - "seen in 7 of 23 recorded
--     gathers", no chance, no amount). At most 6 materials, then "+N
--     more". In the slim window: "Plan 3/5".
--   * when everything from the map is gathered: once, the window "Gathered
--     for your plan" - what was gathered for the plan and what is still
--     open and not routable. No run numbers (Sven V6). It comes also with
--     "Hide the run window" on.
---------------------------------------------------------------------------
local PANEL_ROWS = 6
local TICK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local planPanel, gathered

local function ProfLabelOf(prof)
    local d = ns.CraftData
    return (d and d.ProfLabel and d.ProfLabel(prof)) or prof
end

-- "Plan: Smelting 75" for the run window's title, nil for another filter
ns.PlanRunLabel = function(filter)
    local prof, target = ns.PlanFilterParse(filter)
    if not prof then return nil end
    return (L["Plan: %s %d"]):format(ProfLabelOf(prof), target)
end

local function SeenText(row)
    local s = row.seen and row.seen[1]
    if not s then return nil end
    return (L["seen in %d of %d recorded gathers"]):format(s.seen, s.n)
end

local function Count(row)
    return ("%s / %d"):format(row.have ~= nil and tostring(row.have) or "?", row.need)
end

-- What the run window shows for the plan run - plain data, drawn below:
-- { compact, lines = { { kind = "row" | "off" | "head" | "more" | "note", ... } }, done, total }
ns.PlanPanelLines = function()
    local s = ns.PlanRunState()
    if not s then return nil end
    local lines, done, total = {}, 0, 0
    local rows, off = s.rows or {}, s.offMap or {}
    for _, row in ipairs(rows) do
        total = total + 1
        if row.ok and not s.frozen then done = done + 1 end
    end
    local shown, more = 0, 0
    -- what is still open first, then what is ticked
    for pass = 1, 2 do
        for _, row in ipairs(rows) do
            if (pass == 1) == (not row.ok) then
                if shown < PANEL_ROWS then
                    shown = shown + 1
                    local unknown = s.frozen or row.have == nil
                    lines[#lines + 1] = { kind = "row", item = row.item, name = ItemLabel(row.item), need = row.need, have = (not s.frozen) and row.have or nil,
                        count = s.frozen and ("? / %d"):format(row.need) or Count(row), ok = row.ok and not s.frozen, unknown = unknown,
                        bar = (not unknown and row.need > 0) and math.min(row.have, row.need) / row.need or 0,
                        reason = (not row.ok and row.reason) and ns.PlanReasonText(row.reason) or nil }
                    -- (why it has no node here: a line of its own, a column would cut it off)
                    if lines[#lines].reason then lines[#lines + 1] = { kind = "sub", text = lines[#lines].reason } end
                else
                    more = more + 1
                end
            end
        end
    end
    local offShown = 0
    for _, row in ipairs(off) do
        if shown < PANEL_ROWS then
            if offShown == 0 then lines[#lines + 1] = { kind = "head", text = L["Not on the map"] } end
            shown, offShown = shown + 1, offShown + 1
            lines[#lines + 1] = { kind = "off", item = row.item, name = ItemLabel(row.item), need = row.need, have = (not s.frozen) and row.have or nil,
                count = s.frozen and ("? / %d"):format(row.need) or Count(row), ok = row.ok and not s.frozen, source = SeenText(row) }
            if lines[#lines].source then lines[#lines + 1] = { kind = "sub", text = lines[#lines].source } end
        else
            more = more + 1
        end
    end
    if more > 0 then lines[#lines + 1] = { kind = "more", n = more, text = (L["+%d more"]):format(more) } end
    if s.frozen then lines[#lines + 1] = { kind = "note", text = L["plan unknown right now"] } end
    if (s.hidden or 0) > 0 then lines[#lines + 1] = { kind = "note", text = (L["%d plan nodes hidden"]):format(s.hidden) } end
    local compact = (L["Plan %d/%d"]):format(done, total)
    if total > 0 and done == total then compact = compact .. " " .. TICK end
    return { lines = lines, done = done, total = total, compact = compact, frozen = s.frozen }
end

local ROW_H, PANEL_W, BAR_W = 16, 340, 60
local function PanelRow(i)
    local row = planPanel.rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, planPanel)
    row:SetSize(PANEL_W - 16, ROW_H)
    row:SetPoint("TOPLEFT", 8, -6 - (i - 1) * ROW_H)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", 2, 0)
    row.name:SetWidth(120)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.count = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.count:SetPoint("LEFT", 124, 0)
    row.count:SetWidth(58)
    row.count:SetJustifyH("RIGHT")
    row.count:SetWordWrap(false)
    row.barBack = row:CreateTexture(nil, "BACKGROUND")
    row.barBack:SetPoint("LEFT", 188, 0)
    row.barBack:SetSize(BAR_W, 8)
    row.barBack:SetColorTexture(0.2, 0.2, 0.2, 0.8)
    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetPoint("LEFT", 188, 0)
    row.bar:SetSize(1, 8)
    row.bar:SetColorTexture(1, 0.82, 0.1, 1)
    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.info:SetPoint("LEFT", 252, 0)
    row.info:SetWidth(70)
    row.info:SetJustifyH("LEFT")
    row.info:SetWordWrap(false)
    planPanel.rows[i] = row
    return row
end

-- Draws the plan under the run window (UI.lua calls this with every update
-- of the window). Nothing is worked out here: it shows what the run read.
ns.PlanPanelUpdate = function(runPanel, compact)
    local data = ns.PlanPanelLines()
    if not data or not runPanel or not runPanel:IsShown() or compact then
        if planPanel and planPanel:IsShown() then planPanel:Hide() end
        return data and data.compact or nil
    end
    if not planPanel then
        planPanel = CreateFrame("Frame", "GathercraftPlanPanel", runPanel, "BackdropTemplate")
        planPanel:SetPoint("TOPLEFT", runPanel, "BOTTOMLEFT", 0, 2)
        if planPanel.SetBackdrop then
            planPanel:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            planPanel:SetBackdropColor(0.05, 0.04, 0.03, 0.9)
        end
        planPanel.rows = {}
    end
    for i, line in ipairs(data.lines) do
        local row = PanelRow(i)
        local isRow = line.kind == "row" or line.kind == "off"
        row.name:SetWidth(isRow and 120 or PANEL_W - 24)
        if isRow then
            row.name:SetText(line.name)
            row.count:SetText(line.count .. (line.ok and (" " .. TICK) or ""))
        else
            row.name:SetText((line.kind == "head" and "|cffffd060" or "|cff999999") .. (line.kind == "sub" and "   " or "") .. line.text .. "|r")
            row.count:SetText("")
        end
        row.info:SetText("")
        local bar = line.kind == "row" and not line.unknown
        row.barBack:SetShown(line.kind == "row")
        row.bar:SetShown(bar and line.bar > 0)
        if bar and line.bar > 0 then row.bar:SetWidth(math.max(1, BAR_W * line.bar)) end
        row.line = line
        row:Show()
    end
    for i = #data.lines + 1, #planPanel.rows do planPanel.rows[i]:Hide() end
    planPanel:SetSize(PANEL_W, 12 + #data.lines * ROW_H)
    planPanel:SetShown(#data.lines > 0)
    return data.compact
end

-- The end with everything from the map gathered: once, this window
ns.PlanRunGathered = function(ended)
    if not gathered then
        gathered = CreateFrame("Frame", "GathercraftPlanGathered", UIParent, "BackdropTemplate")
        gathered:SetSize(400, 260)
        gathered:SetPoint("CENTER", 0, 140)
        if gathered.SetBackdrop then
            gathered:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
                tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 11, top = 11, bottom = 11 } })
        end
        gathered:SetFrameStrata("DIALOG")
        gathered:SetClampedToScreen(true)
        gathered:EnableMouse(true)
        gathered:SetMovable(true)
        gathered:RegisterForDrag("LeftButton")
        gathered:SetScript("OnDragStart", gathered.StartMoving)
        gathered:SetScript("OnDragStop", gathered.StopMovingOrSizing)
        gathered:Hide()
        if UISpecialFrames then tinsert(UISpecialFrames, "GathercraftPlanGathered") end
        gathered.title = gathered:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        gathered.title:SetPoint("TOPLEFT", 24, -22)
        gathered.sub = gathered:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        gathered.sub:SetPoint("TOPLEFT", gathered.title, "BOTTOMLEFT", 0, -6)
        gathered.body = gathered:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        gathered.body:SetPoint("TOPLEFT", gathered.sub, "BOTTOMLEFT", 0, -10)
        gathered.body:SetWidth(352)
        gathered.body:SetJustifyH("LEFT")
        gathered.body:SetWordWrap(true)
        gathered.back = CreateFrame("Button", nil, gathered, "UIPanelButtonTemplate")
        gathered.back:SetSize(170, 24)
        gathered.back:SetPoint("BOTTOMLEFT", 22, 20)
        gathered.back:SetScript("OnClick", function()
            gathered:Hide()
            if ns.ShowSkillPlan and gathered.prof then ns.ShowSkillPlan(gathered.prof) end
        end)
        gathered.close = CreateFrame("Button", nil, gathered, "UIPanelButtonTemplate")
        gathered.close:SetSize(110, 24)
        gathered.close:SetPoint("BOTTOMRIGHT", -22, 20)
        gathered.close:SetScript("OnClick", function() gathered:Hide() end)
    end
    gathered.title:SetText(L["Gathered for your plan"])
    gathered.sub:SetText((L["Plan: %s %d"]):format(ProfLabelOf(ended.prof), ended.target) .. " · " .. ns.GetZoneName(ended.zone))
    local lines, shown, more = {}, 0, 0
    for _, row in ipairs(ended.rows or {}) do
        if shown < PANEL_ROWS then
            shown = shown + 1
            lines[#lines + 1] = ("%s  %s %s"):format(ItemLabel(row.item), Count(row), TICK)
        else
            more = more + 1
        end
    end
    if #(ended.rows or {}) == 0 then lines[#lines + 1] = L["Your plan needs nothing from the map."] end
    local open = {}
    for _, row in ipairs(ended.offMap or {}) do if not row.ok then open[#open + 1] = row end end
    if #open > 0 then
        lines[#lines + 1] = " "
        lines[#lines + 1] = "|cffffd060" .. L["Still open, not routable:"] .. "|r"
        for _, row in ipairs(open) do
            if shown < PANEL_ROWS then
                shown = shown + 1
                local seen = SeenText(row)
                lines[#lines + 1] = ("%s  %s%s"):format(ItemLabel(row.item), Count(row), seen and ("  |cff999999" .. seen .. "|r") or "")
            else
                more = more + 1
            end
        end
    end
    if more > 0 then lines[#lines + 1] = "|cff999999" .. (L["+%d more"]):format(more) .. "|r" end
    gathered.body:SetText(table.concat(lines, "\n"))
    gathered.back:SetText(L["Back to skill plan"])
    gathered.close:SetText(L["Close"])
    gathered.prof = ended.prof
    gathered.shown = (gathered.shown or 0) + 1
    gathered.lines = lines
    gathered:Show()
end

-- For the skill plan's buttons: what "Farm for plan" would find where you
-- stand - { show (a material of the map is open), state, onMap = { rows },
-- blocked = { { item, reason } }, offMap = { rows } }. Worked out when the
-- window is drawn, not while you point at the button.
ns.PlanButtonInfo = function(prof, target)
    local zone = Here()
    if not ns.PlanFilter(prof, target) or not zone then return { show = false, state = "invalid" } end
    local plan = ns.PlanRunCheck(prof, target, zone)
    local info = { state = plan.state, why = plan.why, onMap = {}, blocked = {}, offMap = {}, show = false }
    for _, row in ipairs(plan.rows or {}) do
        if not row.ok then
            info.show = true
            if row.reason then info.blocked[#info.blocked + 1] = row else info.onMap[#info.onMap + 1] = row end
        end
    end
    for _, row in ipairs(plan.offMap or {}) do
        if not row.ok then info.offMap[#info.offMap + 1] = row end
    end
    return info
end
-- the lines of the button's tooltip: { { text, r, g, b }, ... }
ns.PlanButtonTooltip = function(info)
    local lines = { { L["Farm for plan"], 1, 0.82, 0 }, { L["Starts a farm run for what your plan still needs, in the zone you are in."], 1, 1, 1 } }
    local function Section(head, rows, text)
        if #rows == 0 then return end
        lines[#lines + 1] = { head, 1, 0.82, 0 }
        for i, row in ipairs(rows) do
            if i > PANEL_ROWS then
                lines[#lines + 1] = { (L["+%d more"]):format(#rows - PANEL_ROWS), 0.6, 0.6, 0.6 }
                break
            end
            lines[#lines + 1] = { text(row), 1, 1, 1 }
        end
    end
    Section(L["On the map here:"], info.onMap or {}, function(row) return ("%s  %s"):format(ItemLabel(row.item), Count(row)) end)
    Section(L["Not here right now:"], info.blocked or {}, function(row) return ("%s  %s  (%s)"):format(ItemLabel(row.item), Count(row), ns.PlanReasonText(row.reason)) end)
    Section(L["Not on the map"] .. ":", info.offMap or {}, function(row)
        local seen = SeenText(row)
        return ("%s  %s%s"):format(ItemLabel(row.item), Count(row), seen and ("  (" .. seen .. ")") or "")
    end)
    return lines
end
