-- Small, independent contracts; also called by smoke_test.lua.
return function(mode, c)
    local ns = c.ns
    local D = assert(ns.WaysDonation, "ways donation module missing")
    local function Pack(n, cost, falls, swims, day)
        return (((swims * 256 + falls) * 1024 + cost) * 256 + n) * 16384 + day
    end
    local function Key(x, y, d) return (y * 1024 + x) * 9 + d end
    local function Finish(p, id)
        local j = D.New(p, "0.2.3-a13", id or "0123456789abcdef")
        local frames = 0
        repeat D.Step(j) frames = frames + 1 until j.done or j.error or frames > 100000
        assert(j.done and not j.error, "export failed: " .. tostring(j.error))
        return j, frames
    end
    if mode == "codec" then
        assert(D.Checksum("Wikipedia") == "11e60398", "Adler-32 test vector")
        local p = { total = 2, zones = {
            [1413] = { e = { [Key(8, 10, 0)] = Pack(255, 1023, 254, 253, 16383) } },
            [1412] = { e = { [Key(1, 2, 5)] = Pack(2, 123, 1, 0, 317) } },
        }, owner = "PRIVATE_PLAYER", realm = "PRIVATE_REALM", day = "PRIVATE_DAY",
            foreign = { SECRET_FOREIGN = 99 }, nodes = { SECRET_NODE = 42 }, prices = { SECRET_PRICE = 7 } }
        local j = Finish(p)
        local text = table.concat(j.parts)
        assert(j.count == 2 and #j.parts == 1)
        assert(text:match("^GCWAYS2|"), "expected GCWAYS2 export")
        assert(text:find("Z1412:AEAgg\nZ1413:AgCgG\n",1,true), "payload fields/order/day removal")
        for _, secret in ipairs({"PRIVATE_", "SECRET_", "E,"}) do
            assert(not text:find(secret,1,true), "private/unrequested field: " .. secret)
        end
        assert(p.zones[1412].e[Key(1,2,5)] == Pack(2,123,1,0,317), "source changed")
        local p2 = { zones = { [1412] = p.zones[1412], [1413] = p.zones[1413] } }
        assert(table.concat(Finish(p2).parts) == text, "noncanonical output")
        p2 = { zones = {
            [1412] = { e = { [Key(1, 2, 5)] = Pack(9, 100, 0, 9, 999) } },
            [1413] = { e = { [Key(8, 10, 0)] = Pack(12, 250, 11, 0, 0) } },
        } }
        assert(table.concat(Finish(p2).parts) == text, "day, count, exact cost or swim leaked")

        local one = Pack(2, 100, 0, 0, 1)
        local a = {[Key(10,20,5)]=one} -- Concept §3.5: known start and east step.
        local b = {
            [Key(21,20,7)]=one, [Key(22,20,3)]=one,
            [Key(20,20,5)]=one, [Key(21,20,5)]=one,
            [Key(1022,1023,5)]=Pack(2, 250, 2, 1, 1),
            [Key(1023,1023,3)]=one,
        }
        local chains = Finish({zones={[1434]={e=a},[1412]={e=b}}})
        assert(chains.parts[1]:find("Z1412:BQFAggYw._7_wnY\nZ1434:AoFAg\n",1,true),
            "greedy branch, cycle, gap, grid edge or single-edge zone")
        local steps = {}
        for i, cost in ipairs({100,124,125,174,175,249,250,1023}) do
            steps[Key(i,2,5)] = Pack(2, cost, 0, 0, i)
        end
        local quantized = Finish({zones={[1412]={e=steps}}})
        assert(quantized.parts[1]:find("Z1412:AEAgggiikkmm\n",1,true), "cost stage boundaries")

        -- The final step reaches the border; an outward step cannot start there.
        local outside = D.New({zones={[1412]={e={[Key(1023,1023,5)]=one}}}}, "0.2.3-a13", "0123456789abcdef")
        repeat D.Step(outside) until outside.done or outside.error
        assert(outside.error, "direction left the grid")
        local clock, secret, ms = debugprofilestop, ns.AnySecret, 0
        debugprofilestop = function() return ms end
        -- Time advances with validation work, not with calls to the clock.
        -- Removing the clock check must not freeze this test's time.
        ns.AnySecret = function() ms = ms + 0.02 return false end
        local timed={zones={[1412]={e={}}}}
        for i=1,64 do timed.zones[1412].e[Key(i,2,5)]=Pack(1,100,0,0,1) end
        local sliced=D.New(timed,"0.2.3-a13","0123456789abcdef")
        local timedOK, timedError=pcall(function()
            repeat
                local start=ms; D.Step(sliced)
                assert(ms-start < 0.5,"slice does not consult the clock")
            until sliced.done or sliced.error
        end)
        debugprofilestop, ns.AnySecret=clock, secret
        assert(timedOK,timedError)
        assert(sliced.done)
        local bad = D.New({zones={[1412]={e={[Key(1,2,4)]=Pack(1,100,0,0,1)}}}}, "0.2.3-a13", "0123456789abcdef")
        repeat D.Step(bad) until bad.done or bad.error
        assert(bad.error, "self direction accepted")
        local huge = { zones = {} }
        for z=1,4 do
            local e={} huge.zones[1400+z]={e=e}
            -- Include a continuous 8,000-step snake. It must survive line and part breaks.
            for i=0,(z == 4 and 5999 or 7999) do
                local row, col = math.floor(i/1000), i%1000
                local x = row%2 == 0 and col or 999-col
                local dir = col == 999 and 7 or (row%2 == 0 and 5 or 3)
                e[Key(x,row+1,dir)] = Pack(255,1023,255,255,i)
            end
        end
        local large, frames = Finish(huge)
        assert(large.count == 30000 and #large.parts > 1 and frames > 100, "not sliced/multipart")
        local chars=0
        for _, part in ipairs(large.parts) do
            assert(#part<=20000,"part too long")
            local payload = part:match("\n(.*)")
            for line in payload:gmatch("([^\n]+)") do
                assert(#line<=1024 and line:match("^Z%d+:"), "noncanonical line wrapping")
            end
            chars=chars+#part
        end
        assert(#large.parts[1] >= 19790, "premature part split")
        assert(chars<=1280000 and #large.parts<=64,"total limit")
        local extra = Key(1001,1,5)
        huge.zones[1401].e[extra]=one
        local tooManyInZone=D.New(huge,"0.2.3-a13","0123456789abcdef")
        repeat D.Step(tooManyInZone) until tooManyInZone.done or tooManyInZone.error
        assert(tooManyInZone.error=="limit","zone limit ignored")
        huge.zones[1401].e[extra]=nil
        huge.zones[1500]={e={[Key(1,1,5)]=Pack(1,100,0,0,1)}}
        local over=D.New(huge,"0.2.3-a13","0123456789abcdef")
        repeat D.Step(over) until over.done or over.error
        assert(over.error,"count limit ignored")
        if c.output then
            for i, part in ipairs(large.parts) do
                local f=assert(io.open(c.output .. "/part-" .. i .. ".txt","wb"));f:write(part);f:close()
            end
        end
    end
end
