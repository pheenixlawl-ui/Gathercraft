-- ways_donation_export.lua <root> <SavedVariables COPY> <out dir> [addon version] [export id]
-- The donation (GCWAYS2) of a saved file, made by the addon's own encoder (WaysDonation.lua), as part-NN.txt
-- files - what /gcr shareways would show for the same ways. Reads a COPY only, never the game's file; writes only
-- new files (stops if out dir has a part file already). For the round trip test of tools/ways_donation_review.py:
--   python -I -B 03-Doku/Werkzeuge/lua_runner.py run <root> tools/ways_donation_export.lua <copy> <out dir>
local ROOT, SV, OUT, VERSION, ID = arg[1], arg[2], arg[3], arg[4] or "0.2.3", arg[5] or "0123456789abcdef"
assert(ROOT and SV and OUT, "usage: ways_donation_export.lua <root> <SavedVariables copy> <out dir> [version] [id]")
debugprofilestop = debugprofilestop or function() return os.clock() * 1000 end
local ns = {}
assert(loadfile(ROOT .. "/WaysDonation.lua"))("Gathercraft", ns)
local first = io.open(OUT .. "/part-01.txt", "rb")
if first then first:close() error("there are part files in " .. OUT .. " already: nothing written") end
dofile(SV)
local db = assert(GathercraftDB, "no GathercraftDB in the copy")
local paths = assert(db.paths, "no paths in the copy")
local j = ns.WaysDonation.New(paths, VERSION, ID)
local steps = 0
repeat ns.WaysDonation.Step(j) steps = steps + 1 until j.done or j.error or steps > 10000000
assert(j.done and not j.error, "export failed: " .. tostring(j.error))
local chars = 0
for i, part in ipairs(j.parts) do
    local f = assert(io.open(("%s/part-%02d.txt"):format(OUT, i), "wb"))
    f:write(part)
    f:close()
    chars = chars + #part
end
io.write(("export: %d pieces, %d skipped, %d parts, %d characters\n"):format(j.count, j.skipped, #j.parts, chars))
