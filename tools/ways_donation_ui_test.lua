return function(c)
    local ns = c.ns
    assert(ns.OpenWaysDonation, "donation window missing")
    local oldURL, oldPaths, oldCreate = ns.WaysDonationFormURL, ns.db.paths, CreateFrame
    local oldDBHints, oldOff = ns.db.waysDonationHints, ns.db.waysDonationHintOff
    local oldPlayer, oldCombat, oldTime = ns.PlayerKey, InCombatLockdown, GetTime
    local function Restore()
        if _G.GathercraftWaysDonation then _G.GathercraftWaysDonation:Hide() end
        ns.WaysDonationFormURL, ns.db.paths, CreateFrame = oldURL, oldPaths, oldCreate
        ns.db.waysDonationHints, ns.db.waysDonationHintOff = oldDBHints, oldOff
        ns.PlayerKey, InCombatLockdown, GetTime = oldPlayer, oldCombat, oldTime
        ns.WaysDonationHintRefresh()
    end
    local ok, err = pcall(function()
        ns.WaysDonationFormURL = ""
        ns.OpenWaysDonation()
        assert(not _G.GathercraftWaysDonation or not _G.GathercraftWaysDonation:IsShown(), "window without link")
        assert(not ns.WaysDonationLink(), "empty link accepted")
        ns.WaysDonationFormURL = "https://example.invalid/manual-form"
        CreateFrame = function(kind,...)
            local f = oldCreate(kind,...)
            if kind == "EditBox" then
                f.SetFocus=function(self) self.focus=true end
                f.ClearFocus=function(self) self.focus=false end
                f.HighlightText=function(self) self.highlight=true end
            end
            return f
        end
        local e={}
        for i=1,2000 do e[((math.floor(i/100)+1)*1024+i%100+1)*9+5] = (100*256+1)*16384+600 end
        ns.db.paths={zones={[1412]={e=e}},total=2000}
        local sent=#c.sent
        ns.OpenWaysDonation()
        local f=assert(_G.GathercraftWaysDonation)
        assert(f:IsShown() and f.job and not f.job.done, "did not open immediately preparing")
        assert(f.edit.focus and f.edit.highlight, "initial focus/selection")
        for _=1,10000 do local update=f:GetScript("OnUpdate") if not update then break end update(f,1/60) end
        assert(f.parts and #f.parts>1 and not f.job, "did not finish/release job")
        local text=f.edit:GetText()
        assert(text:match('^GCWAYS1') and #text<=20000 and f.edit.focus and f.edit.highlight)
        f.edit:SetText("tampered") f.edit:GetScript("OnTextChanged")(f.edit,true)
        assert(f.edit:GetText()==text, "editable export")
        f.next:GetScript("OnClick")(f.next)
        assert(f.part==2 and f.edit:GetText()~=text and f.edit.highlight, "next part")
        f.previous:GetScript("OnClick")(f.previous)
        assert(f.part==1 and f.edit:GetText()==text, "previous part")
        f.link:GetScript("OnMouseUp")(f.link)
        assert(f.link.focus and f.link.highlight, "link not copyable")
        f.link:GetScript("OnEscapePressed")(f.link)
        assert(not f:IsShown() and not f.edit.focus and not f.link.focus, "Escape/focus")
        assert(not f.parts and not f.job and f.edit:GetText()=="" and f.link:GetText()=="", "retained export")
        ns.OpenWaysDonation() f.edit:GetScript("OnEscapePressed")(f.edit)
        assert(not f.job and not f:GetScript("OnUpdate"), "preparing cannot cancel")
        assert(#c.sent==sent,"donation sent channel traffic")
        assert(ns.db.paths.zones[1412].e==e and ns.db.paths.total==2000,"changed paths")
        -- Login clock, two characters, reload, combat, switch and link gating.
        local now, combat, who=0,false,"Player-TEST-A"
        GetTime=function() return now end InCombatLockdown=function() return combat end
        ns.PlayerKey=function() return who end
        ns.db.waysDonationHints=nil ns.db.waysDonationHintOff=nil
        local lines=0;local oldPrint=ns.Print
        ns.Print=function(s) if s:find('/gcr shareways',1,true) then lines=lines+1 end end
        local good, why=pcall(function()
            c.fire("PLAYER_LOGIN")
            local hint=assert(ns.WaysDonationHintFrame)
            local function tick(t) now=t local fn=hint:GetScript("OnUpdate") if fn then fn(hint,5) end end
            tick(59) assert(lines==0,"early hint")
            combat=true tick(60) assert(lines==0,"combat hint")
            combat=false tick(65) assert(lines==1,"missing hint")
            tick(100) assert(lines==1,"repeated hint")
            c.fire("PLAYER_LOGIN") tick(170) assert(lines==1,"reload repeat")
            who="Player-TEST-B" c.fire("PLAYER_LOGIN")
            ns.WaysDonationHintSet(false) tick(240) assert(lines==1,"hint despite off")
            ns.WaysDonationHintSet(true) tick(245) assert(lines==2,"other character hint")
            who="Player-TEST-C" ns.WaysDonationFormURL="" c.fire("PLAYER_LOGIN")
            tick(1000) assert(lines==2 and not hint:GetScript("OnUpdate"),"no-link hint/idle work")
        end)
        ns.Print=oldPrint assert(good,why)
    end)
    Restore()
    assert(ok,err)
end
