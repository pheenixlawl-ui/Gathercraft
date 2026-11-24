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
        assert(text:find("Z,1412\nE,1,2,5,2,123,1,0\nZ,1413\nE,8,10,0,255,1023,254,253\n",1,true), "payload fields/order/day removal")
        for _, secret in ipairs({"PRIVATE_", "SECRET_", ",317", ",16383"}) do
            assert(not text:find(secret,1,true), "private/unrequested field: " .. secret)
        end
        assert(p.zones[1412].e[Key(1,2,5)] == Pack(2,123,1,0,317), "source changed")
        local p2 = { zones = { [1412] = p.zones[1412], [1413] = p.zones[1413] } }
        assert(table.concat(Finish(p2).parts) == text, "noncanonical output")
        local bad = D.New({zones={[1412]={e={[Key(1,2,4)]=Pack(1,100,0,0,1)}}}}, "0.2.3-a13", "0123456789abcdef")
        repeat D.Step(bad) until bad.done or bad.error
        assert(bad.error, "self direction accepted")
        local huge = { zones = {} }
        for z=1,4 do
            local e={} huge.zones[1400+z]={e=e}
            for i=1,7500 do e[Key(i%100+1,math.floor(i/100)+1,5)]=Pack(255,1023,255,255,i%16384) end
        end
        local large, frames = Finish(huge)
        assert(large.count == 30000 and #large.parts > 1 and frames > 100, "not sliced/multipart")
        local chars=0
        for _, part in ipairs(large.parts) do assert(#part<=20000,"part too long") chars=chars+#part end
        assert(chars<=1280000 and #large.parts<=64,"total limit")
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
