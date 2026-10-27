local Line=require("./score_line")
local TrickRuntime=require("./trick_runtime")
local Tests={}
local EPS=1e-9
local function pose(started,finished,hold)
    return {kind="move",id=7,dir=0,start=started,finish=finished,hold=hold}
end
local function air(row)
    return {air_seconds=1,sequence={row},landing={body_up=1,heading_cos=1,closing=4.32}}
end
local function score(packet,rules)
    return Line.new(rules):step(0,{seconds=1,mode="rolling",speed=1,air={landed=packet}})
end
local function projection(packet)
    local events={took_off=false,landed=true,combo_landed=true,failed=false,canceled=false,
        bar_caught=false,tail_caught=false,movement_caught=true,
        barspins=0,tailwhips=0,spin_half_turns=0,units=1,movements=1,
        front_flips=0,back_flips=0,barrel_rolls=0,failure="",
        air_seconds=packet.air_seconds,spin_radians=0,flip_radians=0,roll_radians=0,
        fakie_takeoff=false,overflow=false,sequence=packet.sequence,landing=packet.landing}
    return TrickRuntime.public_snapshot({valid=true,fresh=true,advanced=true,issue="none",model_events=events})
end
function Tests.run(progress)
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case(name,body)
        cases+=1
        local ok,why=pcall(body)
        if not ok then error(name..": "..tostring(why),0) end
        if type(progress)=="function" then progress(cases,assertions) end
    end
    local function accepted(out)
        check(out.issue=="none" and #out.credits==1 and out.closed==nil,"one admitted landed credit")
    end
    local function refused(packet)
        local out=score(packet)
        check(out.issue=="invalid_air" and #out.credits==0 and out.snapshot.points==0,"invalid interval refused")
    end
    -- Without clipping, an admitted sub-nanosecond excess crosses an integer score.
    local rules={hold_bonus=2,hold_seconds=.01,air_rate=0}
    local duration=((400-1e-6)/350-1)*.01/2
    local started=1-duration
    local normalized_hold=1-started
    case("ordinary strict interval retains its score",function()
        local out=score(air(pose(started,1,normalized_hold)),rules)
        accepted(out)
        check(out.credits[1].points==399,"control remains below the next integer")
    end)
    case("finish tolerance clips both finish and hold",function()
        for _,excess in ipairs({EPS/2,EPS}) do
            local finish=1+excess
            local row=pose(started,finish,finish-started)
            local out=score(air(row),rules)
            accepted(out)
            check(out.credits[1].points==399,"finish excess cannot earn the next integer")
            check(row.finish==finish and row.hold==finish-started,"caller endpoints and hold stay untouched")
        end
    end)
    case("hold tolerance clips hold to original strict interval",function()
        for _,excess in ipairs({EPS/2,EPS}) do
            local hold=normalized_hold+excess
            local row=pose(started,1,hold)
            local out=score(air(row),rules)
            accepted(out)
            check(out.credits[1].points==399,"hold excess cannot earn the next integer")
            check(row.hold==hold,"caller hold stays untouched")
        end
    end)
    case("actual public projector composes at both upper boundaries",function()
        for _,excess in ipairs({EPS/2,EPS}) do
            local finish=1+excess
            local hold=finish-started+excess
            local packet=air(pose(started,finish,hold))
            local public=projection(packet)
            check(public~=nil and public.model_events~=nil,"actual projector admits its tolerance")
            local projected=public.model_events
            check(projected.sequence~=packet.sequence and projected.sequence[1]~=packet.sequence[1],
                "actual projector detaches the sequence")
            local out=score(projected,rules)
            accepted(out)
            check(out.credits[1].points==399,"consumer normalizes before scoring")
            check(projected.sequence[1].finish==finish and projected.sequence[1].hold==hold,
                "consumer does not rewrite the projected receipt")
            check(packet.sequence[1].finish==finish and packet.sequence[1].hold==hold,
                "producer input stays intact")
        end
    end)
    case("finish beyond projector tolerance remains rejected",function()
        local packet=air(pose(started,1+2*EPS,normalized_hold))
        check(projection(packet)==nil,"projector refuses excess finish")
        refused(packet)
    end)
    case("hold beyond original interval tolerance remains rejected",function()
        local packet=air(pose(started,1,normalized_hold+2*EPS))
        check(projection(packet)==nil,"projector refuses excess hold")
        refused(packet)
        local finish=1+EPS/2
        local combined=air(pose(started,finish,finish-started+2*EPS))
        check(projection(combined)==nil,"finish tolerance does not expand hold tolerance")
        refused(combined)
    end)
    case("clipping never creates a zero duration scored interval",function()
        local packet=air(pose(1,1+EPS/2,0))
        check(projection(packet)~=nil,"producer boundary fixture is valid")
        refused(packet)
        refused(air(pose(1+EPS/4,1+EPS/2,0)))
        refused(air(pose(.5,.5,0)))
    end)
    case("negative nonfinite and nonnumeric values stay rejected",function()
        local mutations={
            function(r) r.start=-EPS/2 end,
            function(r) r.finish=-EPS/2 end,
            function(r) r.hold=-EPS/2 end,
            function(r) r.start=math.huge end,
            function(r) r.finish=math.huge end,
            function(r) r.hold=math.huge end,
            function(r) r.start=0/0 end,
            function(r) r.finish=0/0 end,
            function(r) r.hold=0/0 end,
            function(r) r.start=false end,
            function(r) r.finish=false end,
            function(r) r.hold=false end,
        }
        for _,mutate in ipairs(mutations) do
            local row=pose(.5,1,.5);mutate(row);refused(air(row))
        end
    end)
    case("start order and same family overlap remain strict",function()
        local unsorted=air(pose(.5,.7,.2))
        unsorted.sequence[2]=pose(.4,1+EPS/2,.3)
        refused(unsorted)
        local overlapping=air(pose(.4,.8,.4))
        overlapping.sequence[2]=pose(.7,1+EPS/2,.3)
        refused(overlapping)
    end)
    case("frozen producer packet can be consumed without mutation",function()
        local finish=1+EPS/2
        local packet=air(pose(started,finish,finish-started+EPS/2))
        table.freeze(packet.sequence[1]);table.freeze(packet.sequence)
        table.freeze(packet.landing);table.freeze(packet)
        local out=score(packet,rules)
        accepted(out)
        check(out.credits[1].points==399,"frozen near-boundary packet is normalized internally")
    end)
    return {cases=cases,assertions=assertions,native_actions=0}
end
return Tests
