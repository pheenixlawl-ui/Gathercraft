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
    if type(key) ~= "string" or key == "" or ns.AnySecret("plan loot", key) then return end
    if type(p.items) ~= "table" or #p.items == 0 then return end -- loot nobody could read is no observation
    local main = ns.PlanBaseItem(key)
    local once = {}
    for _, it in ipairs(p.items) do
        local id = type(it) == "table" and it.id
        if type(id) == "number" and not ns.AnySecret("plan loot", id) and id > 0 and id ~= main then once[id] = true end
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
        local wasOn = pr ~= nil
        if ns.SkillPlanRunner then ns.SkillPlanRunner(true) end
        local plan = Evaluate(spec)
        if not wasOn and ns.SkillPlanRunner and (plan.state == "success" or plan.state == "blocked" or plan.state == "invalid") then ns.SkillPlanRunner(false) end
        if plan.state == "success" then
            ns.Print(plan.status == "done" and L["Target reached: nothing left to farm for your plan."] or L["Everything from the map is gathered for your plan."])
            return nil
        elseif plan.state == "blocked" then
            ns.Print((L["Nothing you can farm for this plan here: %s"]):format(ReasonList(plan.reasons)))
            for _, r in ipairs(plan.reasons) do
                if r.reason == "not_in_zone" and ns.PlanZoneListShow then ns.PlanZoneListShow(prof, target) break end
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
    if ns.SkillPlanRunner then ns.SkillPlanRunner(true) end
end

-- Route.lua, StopRun of a plan run (whoever stopped it)
ns.PlanRunStopped = function()
    pr = nil
    if ns.SkillPlanRunner then ns.SkillPlanRunner(false) end
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
local function Look()
    lookPending = false
    if pr and ns.run and ns.run.plan == pr.spec and ns.RouteReplan then ns.RouteReplan() end
end
ns.PlanRunLook = function()
    if not pr or lookPending then return end
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
if ns.skillPlanListeners then
    table.insert(ns.skillPlanListeners, function() if pr then ns.PlanRunLook() end end)
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
        frozen = pr.state == "invalid" }
end
-- how the last plan run ended and how many ended at all (tests, the windows)
ns.PlanRunLastEnd = function() return lastEnd, ends end
-- What a click on "Farm for plan" would find in this zone - nothing starts:
-- { state, why, rows, offMap, reasons, candidates }
ns.PlanRunCheck = function(prof, target, zone)
    local filter = ns.PlanFilter(prof, target)
    if not filter then return { state = "invalid", why = "invalid" } end
    local wasOn = pr ~= nil
    if ns.SkillPlanRunner then ns.SkillPlanRunner(true) end
    local plan = Evaluate({ prof = prof, target = target, zone = zone, filter = filter })
    if not wasOn and ns.SkillPlanRunner then ns.SkillPlanRunner(false) end
    return plan
end
