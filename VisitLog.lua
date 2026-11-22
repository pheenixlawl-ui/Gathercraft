local ADDON_NAME, ns = ...
local Wrap = ns.PerfWrap or function(_, fn) return fn end -- (/gcr perf on, Perf.lua: measured only while it is on)

---------------------------------------------------------------------------
-- /gcr visitlog - the visit log (diagnosis D, Sven 20.11.2026; built on
-- dev-0.2-diag, in the release since 0.2.2 P1 point 3 for the respawn
-- measurement). Does a node come back at the point it was gathered at, or at
-- some other free point of the zone? The saved data keep only the last
-- harvest of a point, so this writes every visit down.
--   * off unless you turn it on: /gcr visitlog on|off|status|clear. On or
--     off is kept in the saved data (ns.db.visitLogOn), so it stays on over
--     /reload and logouts until you turn it off.
--   * the entries are kept in the saved data only (ns.db.visitLog), on this
--     computer. Nothing of it is sent: sync never reads it.
--   * at most MAX entries; beyond that the oldest go (counted in
--     ns.db.visitLogDropped).
--   * off, nothing is written and nothing else happens. On, it only writes:
--     the route, sync and every rating read nothing of it. Each entry is
--     written in a pcall, so an error in here never reaches the route.
--   * English only, like /gcr detest (a tool for a measurement); not in the
--     help list
-- One entry is one line of text, fields split by ";" (tools/visitlog_report.lua
-- reads them):
--   V;time;map;type;id;x;y;wx;wy;result;flags;sk;secs   a route point checked
--       after arriving (time = arriving). result: harvested | empty |
--       passed (on the way, not the target) | unclear (a point without
--       identity, or a gather without own loot close by). flags: T = the
--       target, W = on the way; C = in combat. secs: arriving to the check.
--   S;time;map;type;id;x;y;wx;wy;result;flags;sk;secs   a route point left
--       out. result: skipped (/gcr skip) | unreachable; secs: how long.
--   G;time;map;type;id;x;y;wx;wy;how;run;sk;nx;ny;yd;count;spawn   an own
--       gather where it started (x, y, wx, wy), the point it was booked to
--       (nx, ny, its sk) and how far that is (yd). how: booked | again (the
--       same spawn once more) | copy (a cultivated copy) | resumed (a
--       resting point under a new spawn ID). run: R in a run, - outside.
--   x, y: zone map (0..1); wx, wy: world yards; sk: the spawn data key of a
--   point from the spawn data, else "-".
---------------------------------------------------------------------------
local MAX = 10000
local HBD = LibStub and LibStub("HereBeDragons-2.0", true)

local function Line(text) print("visitlog " .. text) end
-- WoW has date(); plain Lua (the tests) has os.date
local Date = date or (os and os.date)

local function On()
    return ns.db ~= nil and ns.db.visitLogOn == true
end
ns.VisitLogOn = On

local function Version()
    local v = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")
        or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    return tostring(v or "?")
end

-- one entry (text); only while it is on
local function Add(text)
    if not On() then return end
    local log = ns.db.visitLog
    if not log then
        log = {}
        ns.db.visitLog = log
    end
    log[#log + 1] = text
    while #log > MAX do
        table.remove(log, 1)
        ns.db.visitLogDropped = (ns.db.visitLogDropped or 0) + 1
    end
end
ns.VisitLogAdd = Add

local function Num(v, fmt)
    if type(v) ~= "number" or v ~= v then return "-" end
    return (fmt):format(v)
end

local function Field(v)
    if v == nil then return "-" end
    return (tostring(v):gsub("[;\r\n]", "_"))
end

-- where a point of a zone map is in world yards (nil when it can't be told)
local function World(mapID, x, y)
    if not (HBD and mapID and x and y) then return end
    return HBD:GetWorldCoordinatesFromZone(x, y, mapID)
end
ns.VisitLogWorld = World

-- the fields every entry has: time, map, type, id, x, y, wx, wy
local function Head(ev, t, mapID, n, x, y, wx, wy)
    return table.concat({ ev, Num(t, "%d"), Field(mapID), Field(n and n.type), Field(n and n.id),
        Num(x, "%.4f"), Num(y, "%.4f"), Num(wx, "%.1f"), Num(wy, "%.1f") }, ";")
end

local function Write(fn, ...)
    if not On() then return end
    local ok, text = pcall(fn, ...)
    if ok and type(text) == "string" then Add(text) end
end

-- the date range of the log, for status
local function Range(log)
    local first = log[1] and tonumber(log[1]:match("^%a;(%d+);"))
    local last = log[#log] and tonumber(log[#log]:match("^%a;(%d+);"))
    if not (first and last) then return "" end
    return (", from %s to %s"):format(Date("%d.%m. %H:%M", first), Date("%d.%m. %H:%M", last))
end

function ns.VisitLogCommand(rest)
    rest = type(rest) == "string" and rest:lower() or ""
    local db = ns.db
    if not db then return end
    local n = db.visitLog and #db.visitLog or 0
    if rest == "on" then
        if On() then Line("already on (/gcr visitlog off stops it)") return end
        db.visitLogOn = true
        Line("on: your route visits and gathers are written to the saved data, only on this computer - nothing is sent; /gcr visitlog off stops it")
    elseif rest == "off" then
        if not On() then Line("already off") return end
        db.visitLogOn = nil
        Line(("off: %d entries kept (/gcr visitlog clear deletes them)"):format(n))
    elseif rest == "clear" then
        db.visitLog, db.visitLogDropped = nil, nil
        Line(("cleared: %d entries deleted"):format(n))
    elseif rest == "status" or rest == "" then
        local dropped = db.visitLogDropped and (", %d older ones dropped"):format(db.visitLogDropped) or ""
        Line(("status: %s, %d entries (at most %d)%s%s; Gathercraft %s"):format(On() and "on" or "off", n, MAX, dropped,
            Range(db.visitLog or {}), Version()))
        if rest == "" then Line("/gcr visitlog on|off|status|clear") end
    else
        Line("/gcr visitlog on|off|status|clear: on writes your route visits and gathers down, off stops it, clear deletes them")
    end
end
ns.VisitLogMax = MAX

---------------------------------------------------------------------------
-- The entries. Each reads what it is given and writes one line; it changes
-- nothing (not the node, not the run, not the check).
---------------------------------------------------------------------------
local function WDist(ax, ay, bx, by)
    if not (ax and ay and bx and by) then return end
    return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
end

-- the point of the current run's path a node belongs to (nil when it is not in it)
local function PathPoint(node)
    local run = ns.run
    if not (run and node) then return end
    local tp = run.targetPoint
    if tp and tp.node == node then return tp end
    for _, p in ipairs(run.path or {}) do
        if p.node == node then return p end
    end
end

-- c: a check of the route (Route.lua CheckPending): { node, mapID, wx, wy, at, target, combat }
local function VisitText(c, result)
    local n = c.node
    return table.concat({ Head("V", c.at, c.mapID, n, n.x, n.y, c.wx, c.wy), Field(result),
        (c.target and "T" or "W") .. (c.combat and "C" or ""), Field(n.sk), Num(time() - (c.at or time()), "%d") }, ";")
end
function ns.VisitLogVisit(c, result)
    if not On() or not (c and c.node) then return end
    Write(VisitText, c, result)
end

-- a route point left out: /gcr skip, or hard to reach
local function LeftOutText(node, result, seconds)
    local p = PathPoint(node)
    local run = ns.run
    return table.concat({ Head("S", time(), p and p.mapID, node, node.x, node.y, p and p.wx, p and p.wy), Field(result),
        (run and run.target == node) and "T" or "W", Field(node.sk), Num(seconds, "%d") }, ";")
end
function ns.VisitLogLeftOut(node, result, seconds)
    if not On() or not node then return end
    Write(LeftOutText, node, result, seconds)
end

-- an own gather (Core.lua TryRecord): p = where it started, node = the point it was booked to
local function GatherText(p, node, again, resumed)
    local how = "booked"
    if again then
        if resumed then
            how = "resumed"
        elseif p.spawn and node.lastSpawn == p.spawn then
            how = "again"
        else
            how = "copy"
        end
    end
    local wx, wy = World(p.mapID, p.x, p.y)
    local nx, ny = World(p.mapID, node.x, node.y)
    return table.concat({ Head("G", time(), p.mapID, node, p.x, p.y, wx, wy), how, ns.run and "R" or "-", Field(node.sk),
        Num(node.x, "%.4f"), Num(node.y, "%.4f"), Num(WDist(wx, wy, nx, ny), "%.1f"), Num(node.count, "%d"), Field(p.spawn) }, ";")
end
function ns.VisitLogGather(p, node, again, resumed)
    if not On() or not (p and node) then return end
    Write(GatherText, p, node, again, resumed)
end
-- (/gcr perf on: what Core.lua and Route.lua call here, measured while it is on)
ns.VisitLogVisit = Wrap("VisitLog", ns.VisitLogVisit)
ns.VisitLogLeftOut = Wrap("VisitLog", ns.VisitLogLeftOut)
ns.VisitLogGather = Wrap("VisitLog", ns.VisitLogGather)
