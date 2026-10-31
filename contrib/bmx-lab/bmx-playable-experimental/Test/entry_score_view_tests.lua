-- Cached score bridge only. These are local constructed status facts, not native credit.
local Entry=require("./bmx_playable_entry")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;local ok,why=pcall(fn);assert(ok,name..": "..tostring(why)) end
    local function fixture()
        local f={row={},reads=0,steps=0,failed=false}
        local owner={}
        function owner:step() f.steps+=1;if f.failed then error("constructed unavailable") end;return f.row end
        function owner:status() f.reads+=1;error("score bridge must not poll") end
        function owner:request_stop() return true end
        local runtime={new=function()return owner end}
        f.entry=Entry.new({},runtime,{}, {admitted=true,slot=0})
        return f
    end
    case("absent ride is hidden and cached score is shared without polling",function()
        local f=fixture()
        local view,issue,phase=f.entry:score_view()
        check(view==nil and issue=="ride_unavailable" and phase=="unavailable","idle sentinel")
        check(f.steps==0 and f.reads==0,"idle accessor calls no lifecycle method")
        local score=table.freeze({scope="authored_mod_score_only",total=0,native_score=false,calibration="C0_UNRUN"})
        f.row={ride={mod_score=score,mod_score_issue="pending",mod_landing_phase="airborne"}}
        f.entry:step(16)
        for _=1,3 do
            view,issue,phase=f.entry:score_view()
            check(rawequal(view,score) and issue=="pending" and phase=="airborne","same bounded cached score")
        end
        check(f.steps==1 and f.reads==0,"accessor never steps or polls the owner")
    end)
    case("real score fault stays visible and unknown lifecycle hides stale score",function()
        local f=fixture()
        f.row={ride={mod_score_issue="score_disabled",mod_landing_phase="stopped"}}
        f.entry:step(16)
        local view,issue,phase=f.entry:score_view()
        check(view==nil and issue=="score_disabled" and phase=="stopped","real fault is not absent-ride sentinel")
        f.failed=true;f.entry:step(16)
        view,issue,phase=f.entry:score_view()
        check(view==nil and issue=="ride_unavailable" and phase=="unavailable","unknown step never reuses old score")
        check(f.reads==0 and f.steps==2,"no diagnostic owner.status call")
    end)
    return {cases=cases,assertions=assertions}
end
return Tests
