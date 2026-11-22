-- 0.2.3 P3: an older Gathercraft leaves the run history alone (tools only).
--
--   python -I -B <lua_runner.py> run <Gathercraft folder, any version> <this file> [old|new]
--
-- Loads the version in the folder in its own mini WoW (its tools/smoke_test.lua),
-- with saved data that hold a run history (GathercraftDB.runHistory, 0.2.3),
-- farms a short run, ends it, logs out. Then: no error line, and
--   old - the history is exactly as it was (a version that does not know the key);
--   new - the history is kept and has the new run at the end of its zone.
-- One line "ok ..." / "FAIL ...", then "--- errors: N".
local ROOT, WANT = arg[1], arg[2] or "old"
local function Say(s) io.write(s, "\n") io.stdout:flush() end
local function Copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = Copy(v) end
    return c
end
local function Same(a, b, path)
    if type(a) ~= type(b) then return false, path end
    if type(a) ~= "table" then return a == b, path end
    for k, v in pairs(a) do
        local ok, where = Same(v, b[k], path .. "." .. tostring(k))
        if not ok then return false, where end
    end
    for k in pairs(b) do if a[k] == nil then return false, path .. "." .. tostring(k) end end
    return true
end

local HISTORY = {
    [1412] = {
        { t = 1763700000, f = "herb", g = "gold", k = "smart", a = 900, e = 1000, n = 30, v = 30000, u = 0, s = 2, c = "Player-1-0000AAAA", h = 150, o = 60 },
        { t = 1763703600, f = "both", g = "skill", k = "loop", a = 1700, e = 1800, n = 55, v = 41000, u = 3, s = 9, c = "Player-1-0000AAAA", h = 151, o = 62 },
    },
    [1411] = { { t = 1763707200, f = "ore", g = "nodes", k = "smart", a = 650, e = 700, n = 12, v = 9000, u = 0, s = 1, c = "Player-1-0000BBBB", o = 120 } },
}
local errors = 0
local ok, err = pcall(function()
    GathercraftDB, WoWFFarmDB = { runHistory = Copy(HISTORY) }, nil
    HARNESS_ONLY = true
    arg = { ROOT }
    local h = dofile(ROOT .. "/tools/smoke_test.lua")
    local ns, player = h.ns, h.player
    h.fire("ADDON_LOADED", "Gathercraft")
    player.map, player.x, player.y = 1412, 0.40, 0.50
    h.fire("PLAYER_LOGIN")
    h.fire("PLAYER_ENTERING_WORLD")
    h.advance(5)
    assert(ns.db and ns.db.runHistory, "the saved run history is gone after the login")
    ns.StartRun("herb", 1412)
    h.advance(1)
    assert(ns.run, "test setup: no run")
    for i = 1, 150 do
        player.x = player.x + 0.0004
        if i % 30 == 0 then
            for _, f in ipairs(ns.gatherListeners) do f({ type = "herb", name = "Peacebloom" }, { items = { { id = 2447, qty = 2 } } }) end
        end
        h.advance(1)
    end
    ns.StopRun()
    h.fire("PLAYER_LOGOUT")
    h.advance(1)
    assert(#h.errors == 0, "error lines: " .. table.concat(h.errors, " | "))
    local now = GathercraftDB and GathercraftDB.runHistory
    if WANT == "old" then
        local same, where = Same(HISTORY, now, "runHistory")
        assert(same, "the older version changed the run history at " .. tostring(where))
        Say("ok an older version (" .. ROOT .. ") keeps the run history as it was")
    else
        assert(type(now) == "table" and #now[1412] == 3 and #now[1411] == 1, "the run history was not kept and added to")
        local same, where = Same(HISTORY[1412][2], now[1412][2], "runHistory[1412][2]")
        assert(same and now[1412][3].f == "herb" and now[1412][3].n == 5, "the history's runs changed, or the new run is not at the end: " .. tostring(where))
        Say("ok this version (" .. ROOT .. ") keeps the run history and adds the new run")
    end
end)
if not ok then
    errors = errors + 1
    Say("FAIL " .. WANT .. ": " .. tostring(err))
end
Say("--- errors: " .. errors)
