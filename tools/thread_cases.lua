-- Ways (0.2.4 a7, S1.1): the thread of Ways.lua for ways given in a file, for
-- the independent checker tools/thread_check.py (which never reads this code).
--
-- Usage:
--   luajit tools/thread_cases.lua <Gathercraft folder> <ways.txt> <threads.txt> [ahead=off] [factor=N]
--     ways.txt     per way:  way <id> <points>
--                            then one line per point: <x> <y> <kind>   (zone yards; kind of the edge
--                            into the point: 1 OBS, 2 REV, 3 CON, 4 GREV, -1 for you, the first
--                            square and the node)
--                            end
--     threads.txt  per way:  way <id> <state> <reason> <booked> <limit> <repairs>
--                            p <x> <y> <anchor 0/1> <slot>        the thread's points
--                            e <slot> <kind> <s> <r> <x> <y>       the events (kind 0 corner,
--                                                                  1 side across x, 2 across y, 3 anchor)
--                            d <k> <k> ...                         the points drawn
--                            end
-- Only Ways.lua's core is used (ns.WaysCore); the rest of the addon is not loaded.
local ROOT, IN, OUT = arg[1], arg[2], arg[3]
assert(OUT, "usage: thread_cases.lua <Gathercraft folder> <ways.txt> <threads.txt>")
if jit then jit.off() end

-- the little of WoW that loading Ways.lua needs
CreateFrame = function()
    return { Hide = function() end, Show = function() end, SetScript = function() end }
end
GetTime = function() return 0 end
debugprofilestop = function() return os.clock() * 1000 end
local ns = {}
assert(loadfile(ROOT .. "/Ways.lua"))("Gathercraft", ns)
local M = assert(ns.WaysCore, "no ns.WaysCore")

-- (the checks of the checks) ahead=off: no protective anchors looked ahead for, so the events find what
-- is to be repaired; factor=N: the counter at N instead of 4 times the passages
for i = 4, #arg do
    local k, v = arg[i]:match("^(%w+)=(.+)$")
    if k == "ahead" and v == "off" then M.threadAhead = false end
    if k == "factor" then FACTOR = tonumber(v) end
end
local T = M.NewThread()
local out = assert(io.open(OUT, "w"))
local function g(v) return ("%.17g"):format(v) end
local count = 0
local f = assert(io.open(IN, "r"))
local line = f:read("*l")
while line do
    local id, n = line:match("^way (%S+) (%d+)$")
    if id then
        n = tonumber(n)
        local c = M.NewCentre()
        local raw = 0
        for i = 1, n do
            local x, y, kind = f:read("*l"):match("^(%S+) (%S+) (%S+)$")
            x, y, kind = tonumber(x), tonumber(y), tonumber(kind)
            c.x[i], c.y[i], c.kind[i] = x, y, kind
            c.key[i] = (i == 1 or i == n) and -1 or math.floor(y / 25) * 1024 + math.floor(x / 25)
            if i > 1 then
                local dx, dy = x - c.x[i - 1], y - c.y[i - 1]
                raw = raw + math.sqrt(dx * dx + dy * dy)
            end
            c.raw[i] = raw
        end
        assert(f:read("*l") == "end", "way " .. id .. ": no end")
        c.n, c.len = n, raw
        do
            local dx, dy = c.x[2] - c.x[1], c.y[2] - c.y[1]
            c.head = math.sqrt(dx * dx + dy * dy)
            dx, dy = c.x[n] - c.x[n - 1], c.y[n] - c.y[n - 1]
            c.tail = math.sqrt(dx * dx + dy * dy)
        end
        M.ThreadStart(T, c, 1)
        if FACTOR and T.state == "work" then T.limit = FACTOR * (n - 3) end
        while T.state == "work" do M.ThreadStep(T, math.huge) end
        local state, reason = T.state, T.reason
        out:write(("way %s %s %s %d %d %d\n"):format(id, state, reason or "-", T.used, T.limit, T.repairs))
        if state == "done" then
            local t = T.t
            for k = 1, t.n do
                out:write(("p %s %s %d %d\n"):format(g(t.x[k]), g(t.y[k]), T.va[k], T.vu[k]))
            end
            for e = 1, T.en do
                out:write(("e %d %d %s %s %s %s\n"):format(T.eu[e], T.ek[e], g(T.es[e]), g(T.er[e]), g(T.ex[e]), g(T.ey[e])))
            end
            local d = {}
            for k = 1, t.dn do d[k] = tostring(t.dk[k]) end
            out:write("d " .. table.concat(d, " ") .. "\n")
        end
        out:write("end\n")
        count = count + 1
    end
    line = f:read("*l")
end
f:close()
out:close()
print(("%d ways"):format(count))
