-- Offline layout and drawing-contract checks, not native rendering qualification.
local HUD=require("./score_hud")
local Tests={}
local function view()
    return {active=true,airborne=false,rows={
        {name="Truckdriver",points=880,landing="Clean"},
        {name="Double Tailwhip",points=900,landing="Sketchy"},
        {name="X-Up to Barspin",points=440},
        {name="Bunny Hop",points=50,landing="Clean"}},
        points=2270,score=5675,multiplier=2.5,remaining=1.25,timer_total=2.5}
end
local function text_exists(ops,value)
    for _,op in ipairs(ops) do if op.kind=="text" and op.text==value then return true end end
    return false
end
local function drawing(fail_at)
    local calls={}
    local d={}
    local function call(kind,self,a,b,style)
        assert(self==d,"colon-style receiver is the supplied draw object")
        assert(type(a)=="vector" and a.z==0,"native points are vectors")
        assert(type(style)=="table" and table.isfrozen(style),"native style is the immutable validated table")
        if kind=="text" then assert(type(b)=="string","d:text takes point,text,style")
        else assert(type(b)=="vector" and b.z==0,"d:line/rect take point,point,style") end
        table.insert(calls,{kind=kind,a=a,b=b,style=style})
        if #calls==fail_at then error("constructed draw fault") end
    end
    d.text=function(...) call("text",...) end
    d.line=function(...) call("line",...) end
    d.rect=function(...) call("rect",...) end
    d.size=function() error("runtime owns d:size") end
    d.measure=function() error("layout is pure and needs no draw-time measurement") end
    return d,calls
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,message) assertions+=1;assert(ok,message) end
    local function case(body) cases+=1;body() end
    local function bounds(ops,width,height)
        check(table.isfrozen(ops) and #ops<=HUD.MAX_OPS,"frozen bounded op list")
        local bytes=0
        for _,op in ipairs(ops) do
            check(table.isfrozen(op) and table.isfrozen(op.style),"operation and style are frozen")
            for _,key in ipairs({"x","y","x2","y2"}) do
                local value=op[key]
                if value~=nil then
                    local limit=(key=="x" or key=="x2") and width or height
                    check(type(value)=="number" and value==value and value>=0 and value<=limit,
                        "finite on-screen coordinate "..key)
                end
            end
            if op.kind=="text" then
                bytes+=#op.text
                check(not string.find(op.text,"[^ -~]"),"rendered text is printable ASCII")
            end
        end
        check(bytes<=HUD.MAX_TEXT,"all text together is bounded to 500 characters")
    end
    case(function()
        local ops=HUD.layout({},vector.create(1920,1080,0))
        check(#ops==0,"idle has zero drawing operations")
        local stale={rows={{name="Old trick",points=99}},closed={outcome="banked",score=99},closed_remaining=0}
        check(#HUD.layout(stale,{x=1920,y=1080})==0,"expired close and stale rows do not keep the HUD visible")
        local ok,count=HUD.draw(nil,ops)
        check(ok and count==0,"idle draw needs no API object")
        check(table.isfrozen(HUD),"HUD constants and exports are frozen")
    end)
    case(function()
        local ops=HUD.layout(view(),{x=1920,y=1080})
        bounds(ops,1920,1080)
        check(#ops==33,"worst normal four-row view uses exactly 33 operations")
        check(text_exists(ops,"Truckdriver +880 Clean") and text_exists(ops,"Double Tailwhip +900 Sketchy"),
            "landed rows show points and known landing labels")
        check(text_exists(ops,"LINE 5675") and text_exists(ops,"x2.50"),"line score and multiplier are separate")
        local segments,on=0,0
        for _,op in ipairs(ops) do
            if op.kind=="line" then
                segments+=1
                if op.style.colour=="#BDFB77" then on+=1 end
            end
        end
        check(segments==24 and on==12,"half remaining time lights twelve of 24 ring segments")
    end)
    case(function()
        local snapshot=view()
        local small=HUD.layout(snapshot,{x=1920,y=1080})
        local large=HUD.layout(snapshot,vector.create(3840,2160,0))
        bounds(large,3840,2160)
        check(#small==#large,"resolution does not alter operation budget")
        for i,op in ipairs(small) do
            check(math.abs(large[i].x-op.x*2)<.001 and math.abs(large[i].y-op.y*2)<.001,
                "positions scale once at 2160p")
            check(large[i].style==op.style,"style sizes and thickness are not scaled twice")
        end
        check(snapshot.rows[1].name=="Truckdriver" and snapshot.score==5675,"layout leaves its input unchanged")
    end)
    case(function()
        local snapshot={airborne=true,live_name="Barspin",score=0,multiplier=1,remaining=2.5,timer_total=2.5}
        local ops=HUD.layout(snapshot,{x=1920,y=1080})
        check(ops[3].kind=="text" and ops[3].text=="Barspin","airborne header contains no provisional points")
        snapshot.live_name=nil
        check(text_exists(HUD.layout(snapshot,{x=1920,y=1080}),"Bunny Hop"),"missing live name has a useful fallback")
        snapshot={manual_kind="nose_manual",manual_seconds=.36}
        check(text_exists(HUD.layout(snapshot,{x=1920,y=1080}),"Nose Manual 0.4s"),"manual displays a bounded live counter")
        snapshot.manual_kind="manual";snapshot.manual_seconds=999
        check(text_exists(HUD.layout(snapshot,{x=1920,y=1080}),"Manual 10.0s"),"manual counter caps at its authored maximum")
    end)
    case(function()
        local snapshot={closed={outcome="banked",score=880,points=400,multiplier=2.2,new_best=true},closed_remaining=1.5}
        local ops=HUD.layout(snapshot,{x=1920,y=1080})
        check(text_exists(ops,"LINE 880") and text_exists(ops,"NEW BEST"),"bank banner displays score and new best")
        bounds(ops,1920,1080)
        snapshot.closed={outcome="lost",score=0,points=400,multiplier=2.2};snapshot.closed_remaining=1.2
        ops=HUD.layout(snapshot,{x=1920,y=1080})
        check(text_exists(ops,"BAIL") and text_exists(ops,"880"),"bail shows forfeited value despite banked score zero")
        check(#ops==5 and ops[5].kind=="line","bail strikes through the forfeited line score")
        snapshot.closed_remaining=0
        check(#HUD.layout(snapshot,{x=1920,y=1080})==0,"runtime expiry hides the bail immediately")
        snapshot.closed_remaining=1;snapshot.closed={outcome="interrupted",score=880,new_best=true}
        ops=HUD.layout(snapshot,{x=1920,y=1080})
        check(text_exists(ops,"LINE 880") and text_exists(ops,"INTERRUPTED") and not text_exists(ops,"NEW BEST"),
            "interruption banks the credited score without claiming a new best")
        snapshot.airborne=true;snapshot.live_name="Tailwhip"
        ops=HUD.layout(snapshot,{x=1920,y=1080})
        check(text_exists(ops,"Tailwhip") and not text_exists(ops,"INTERRUPTED"),"new activity takes precedence over an older close banner")
    end)
    case(function()
        local snapshot=view();snapshot.airborne=true;snapshot.live_name=string.rep("W",10000)
        snapshot.score=math.huge;snapshot.multiplier=0/0;snapshot.remaining=math.huge;snapshot.timer_total=-1
        for i=1,5 do snapshot.rows[i]={name=string.rep("W",10000).."\n",points=9007199254740992,landing="Sketchy"} end
        local ops=HUD.layout(snapshot,{x=1920,y=1080})
        bounds(ops,1920,1080)
        check(#ops==33,"oversized rows and inputs cannot expand the work budget")
        snapshot.live_name="bad\nheader"
        check(text_exists(HUD.layout(snapshot,{x=1920,y=1080}),"bad?header"),"control characters cannot create extra drawn lines")
        for _,size in ipairs({{x=0,y=1080},{x=1920,y=0},{x=0/0,y=1080},{x=1920,y=math.huge},{x=16385,y=1080}}) do
            check(#HUD.layout(snapshot,size)==0,"invalid display dimensions are refused")
        end
        check(#HUD.layout(nil,{x=1920,y=1080})==0,"invalid view is idle")
        check(#HUD.layout(setmetatable({},{__index=function() error("no view callbacks") end}),{x=1920,y=1080})==0,
            "layout does not invoke view metatables")
    end)
    case(function()
        local ops=HUD.layout(view(),{x=1920,y=1080})
        local d,calls=drawing()
        local ok,count=HUD.draw(d,ops)
        check(ok and count==#ops and #calls==#ops,"draw calls exactly the prepared native signatures")
        for i,op in ipairs(ops) do
            check(calls[i].kind==op.kind and math.abs(calls[i].a.x-op.x)<.001
                and math.abs(calls[i].a.y-op.y)<.001,"draw retains pixel positions and order")
        end
        local broken,attempts=drawing(3)
        local success,reason,drawn=HUD.draw(broken,ops)
        check(not success and reason=="draw_failed" and drawn==2 and #attempts==3,
            "draw faults stop subsequent calls and report only completed operations")
    end)
    case(function()
        local ops=HUD.layout(view(),{x=1920,y=1080})
        local d,calls=drawing();d.line=nil
        local ok,reason=HUD.draw(d,ops)
        check(not ok and reason=="draw_unavailable" and #calls==0,"all required methods are checked before drawing")
        local meta=setmetatable({},{__index=function() error("must not resolve methods") end})
        ok,reason=HUD.draw(meta,ops)
        check(not ok and reason=="draw_unavailable","draw does not invoke method lookup metatables")
        d,calls=drawing()
        local malformed=table.freeze({ops[1],table.freeze({kind="line",x=0/0,y=0,x2=1,y2=1,style=ops[#ops].style})})
        ok,reason=HUD.draw(d,malformed)
        check(not ok and reason=="invalid_ops" and #calls==0,"a malformed later op cannot draw an earlier prefix")
        local sparse=table.freeze({[1]=ops[1],[3]=ops[3]})
        check(not HUD.draw(d,sparse) and #calls==0,"sparse operations are refused")
        check(not HUD.draw(d,{ops[1]}) and #calls==0,"mutable operation arrays are refused")
        local too_many={}
        for i=1,HUD.MAX_OPS+1 do too_many[i]=ops[1] end
        check(not HUD.draw(d,table.freeze(too_many)) and #calls==0,"excess operations are refused before draw")
        local long=table.freeze({kind="text",x=0,y=0,text=string.rep("A",200),style=ops[3].style})
        check(not HUD.draw(d,table.freeze({long,long,long})) and #calls==0,"aggregate text budget is enforced before draw")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
