local _, ns = ...
-- Manual donation format GCWAYS2. No channel, persistent state, clock/day or
-- identity in the encoder. tools/ways_donation.py is its strict reader.
local D = {}
ns.WaysDonation = D
local floor = math.floor
local MAX_ROWS, MAX_ZONES, MAX_ZONE = 30000, 256, 8000
local PAYLOAD, MAX_PARTS, MAX_CHARS = 19800, 64, 1280000
local LINE_LIMIT = 1024
local GRID, KEY_LIMIT = 1024, 1024 * 1024 * 9
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local SYMBOL = {}
for n = 0, 63 do SYMBOL[n] = ALPHABET:sub(n + 1, n + 1) end
local PATH_DIRS = { 0, 1, 2, 3, 5, 6, 7, 8 }
local function Int(v, lo, hi)
    if ns.AnySecret and ns.AnySecret("ways donation", v) then return false end
    return type(v) == "number" and v >= lo and v <= hi and v == floor(v)
end
local function Sum(s, a, b)
    for i = 1, #s do a = (a + s:byte(i)) % 65521 b = (b + a) % 65521 end
    return a, b
end
local function Hex(a, b) return ("%08x"):format(b * 65536 + a) end
function D.Checksum(s) return Hex(Sum(s, 1, 0)) end
local function Fail(j, why)
    j.error = why
    j.rows, j.buf, j.zones, j.source, j.edges = nil, nil, nil, nil, nil
    j.steps, j.lines, j.parts = nil, nil, nil
end
function D.New(paths, version, id)
    local j = { phase = "scan", rows = {}, buf = {}, steps = {}, count = 0, zoneCount = 0,
        version = version, id = id, maxMS = 0, frames = 0 }
    if type(version) ~= "string" or #version > 24 or not version:match("^[%w%.%-]+$")
        or type(id) ~= "string" or #id ~= 16 or not id:match("^[0-9a-f]+$") then
        Fail(j, "header") return j
    end
    j.source = paths
    j.zones = type(paths) == "table" and paths.zones or nil
    if type(j.zones) ~= "table" then Fail(j, "empty") end
    return j
end
local function Scan(j)
    if j.source.zones ~= j.zones then Fail(j, "changed") return end
    if not j.edges then
        local ok, zone, z = pcall(next, j.zones, j.zone)
        if not ok then Fail(j, "changed") return end
        if zone == nil then
            if j.count == 0 then Fail(j, "empty") return end
            j.phase, j.width, j.left = "sort", 1, 1
            j.source, j.zones = nil, nil
            return
        end
        j.zoneCount = j.zoneCount + 1
        if j.zoneCount > MAX_ZONES or not Int(zone, 1, 65535) or type(z) ~= "table" or type(z.e) ~= "table" then
            Fail(j, "data") return
        end
        j.zone, j.edges, j.key, j.zoneRows = zone, z.e, nil, 0
        return
    end
    if type(j.zones[j.zone]) ~= "table" or j.zones[j.zone].e ~= j.edges then Fail(j, "changed") return end
    local ok, key, value = pcall(next, j.edges, j.key)
    if not ok then Fail(j, "changed") return end
    if key == nil then j.edges, j.key = nil, nil return end
    if not Int(key, 0, KEY_LIMIT - 1) or not Int(value, 0, 2 ^ 48 - 1) then Fail(j, "data") return end
    local dir = key % 9
    local cell = (key - dir) / 9
    local x, y = cell % GRID, floor(cell / GRID)
    local dx, dy = dir % 3 - 1, floor(dir / 3) - 1
    local v = floor(value / 16384) -- the recorded day is deliberately discarded
    local count = v % 256 v = floor(v / 256)
    local cost = v % 1024 v = floor(v / 1024)
    local falls, swims = v % 256, floor(v / 256)
    if dir == 4 or x + dx < 0 or x + dx >= GRID or y + dy < 0 or y + dy >= GRID
        or count == 0 or cost < 100 or falls > count or swims > count then Fail(j, "data") return end
    j.count, j.zoneRows = j.count + 1, j.zoneRows + 1
    if j.count > MAX_ROWS or j.zoneRows > MAX_ZONE then Fail(j, "limit") return end
    -- Numeric index orders zone then Paths key; it fits exactly in a Lua number.
    -- The lookup keeps only the six wire bits, with no other saved fields.
    local index = j.zone * KEY_LIMIT + key
    local direction = dir < 4 and dir or dir - 1
    local stage = cost < 125 and 0 or cost < 175 and 1 or cost < 250 and 2 or 3
    local fall = falls >= 1 and falls == count and 1 or 0
    j.rows[j.count] = index
    j.steps[index] = direction * 8 + stage * 2 + fall
    j.key = key
end
local function Sort(j)
    -- Bottom-up merge sort, one output slot per unit. Never table.sort on a
    -- whole 30,000-piece snapshot in one frame.
    if j.width >= j.count then
        j.phase, j.at, j.parts, j.lines, j.size = "encode", 1, {}, {}, 0
        j.lineSize = 0
        j.a, j.b, j.pa, j.pb, j.characters = 1, 0, 1, 0, 0
        j.buf = nil
        return
    end
    if j.left > j.count then
        j.rows, j.buf = j.buf, j.rows
        j.width, j.left, j.i = j.width * 2, 1, nil
        return
    end
    if not j.i then
        j.i, j.k = j.left, j.left
        j.mid = math.min(j.left + j.width - 1, j.count)
        j.right = math.min(j.left + 2 * j.width - 1, j.count)
        j.r = j.mid + 1
    end
    if j.i <= j.mid and (j.r > j.right or j.rows[j.i] < j.rows[j.r]) then
        j.buf[j.k] = j.rows[j.i] j.i = j.i + 1
    else
        j.buf[j.k] = j.rows[j.r] j.r = j.r + 1
    end
    j.k = j.k + 1
    if j.k > j.right then j.left, j.i = j.right + 1, nil end
end
local function Append(j, text)
    j.lines[#j.lines + 1] = text
    j.size = j.size + #text
    j.a, j.b = Sum(text, j.a, j.b)
    j.pa, j.pb = Sum(text, j.pa, j.pb)
end
local function Flush(j)
    if #j.parts >= MAX_PARTS then Fail(j, "limit") return end
    Append(j, "\n")
    j.parts[#j.parts + 1] = { body = table.concat(j.lines), sum = Hex(j.pa, j.pb) }
    j.lines, j.size, j.pa, j.pb, j.lastZone, j.lineSize = {}, 0, 1, 0, nil, 0
end
local function ChainStart(x, y)
    local word = (x * GRID + y) * 16
    return SYMBOL[floor(word / 262144)] .. SYMBOL[floor(word / 4096) % 64]
        .. SYMBOL[floor(word / 64) % 64] .. SYMBOL[word % 64]
end
local function Encode(j)
    local index = j.follow or j.rows[j.at]
    if not index then
        if j.size > 0 then Flush(j) return end
        j.rows, j.steps, j.lines = nil, nil, nil
        j.whole, j.at, j.phase = Hex(j.a, j.b), 1, "headers"
        return
    end
    local step = j.steps[index]
    if step == nil then
        j.at = j.at + 1
        return
    end
    local zone = floor(index / KEY_LIMIT)
    local key = index % KEY_LIMIT
    local dir = key % 9
    local cell = (key - dir) / 9
    local x, y = cell % GRID, floor(cell / GRID)
    local sameLine = zone == j.lastZone and j.lineSize + (j.follow and 1 or 6) <= LINE_LIMIT
    local prefix, separator = "", ""
    if not sameLine then
        prefix = ("Z%d:"):format(zone) .. ChainStart(x, y)
        if j.size > 0 then separator = "\n" end
    elseif not j.follow then
        prefix = "." .. ChainStart(x, y)
    end
    -- Always reserve the final LF. On a break the unconsumed edge retains
    -- its place in the traversal and opens the next part with a fresh start.
    if j.size + #separator + #prefix + 2 > PAYLOAD then Flush(j) return end
    Append(j, separator .. prefix .. SYMBOL[step])
    j.lastZone = zone
    j.lineSize = (sameLine and j.lineSize or 0) + #prefix + 1

    if not j.follow then j.at = j.at + 1 end
    j.steps[index] = nil
    j.follow = nil
    local dx, dy = dir % 3 - 1, floor(dir / 3) - 1
    local nextCell = zone * KEY_LIMIT + ((y + dy) * GRID + x + dx) * 9
    for _, nextDir in ipairs(PATH_DIRS) do
        local nextEdge = nextCell + nextDir
        if j.steps[nextEdge] ~= nil then
            j.follow = nextEdge
            break
        end
    end
end
local function Headers(j)
    local p = j.parts[j.at]
    if not p then j.done, j.phase = true, nil return end
    local part = ("GCWAYS2|%s|%s|%d|%d|%s|%s\n"):format(j.version, j.id, j.at, #j.parts, p.sum, j.whole) .. p.body
    j.characters = j.characters + #part
    if #part > 20000 or j.characters > MAX_CHARS then Fail(j, "limit") return end
    j.parts[j.at], j.at = part, j.at + 1
end
function D.Step(j)
    if j.done or j.error then return end
    local start = debugprofilestop()
    -- Leave room for caller/UI overhead under the 0.5 ms frame target.
    -- One unit is one record/merge slot/short line or <=19,800-byte copy.
    for _ = 1, 2048 do
        if j.phase == "scan" then Scan(j)
        elseif j.phase == "sort" then Sort(j)
        elseif j.phase == "encode" then Encode(j)
        else Headers(j) end
        if j.done or j.error or debugprofilestop() - start >= 0.15 then break end
    end
    local elapsed = debugprofilestop() - start
    j.maxMS = math.max(j.maxMS, elapsed) j.frames = j.frames + 1
end
