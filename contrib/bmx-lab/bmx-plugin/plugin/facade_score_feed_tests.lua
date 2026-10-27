-- Real public facade and staged Core, with constructed SDK services only.
-- No qualified Ride is created; terminal-row pass-through also needs source review.
local Runtime=require("./bike_runtime")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case(run) cases+=1;run() end
    local function empty(out,gap)
        check(type(out)=="table" and getmetatable(out)==nil and out.generation==0 and out.n==0
            and type(out.rows)=="table" and next(out.rows)==nil and out.gap==gap,
            "the facade preserves the empty score-feed contract")
        local keys=0
        for key in out do
            keys+=1
            check(key=="generation" or key=="n" or key=="rows" or key=="gap",
                "score-feed packets contain no lifecycle or cleanup fields")
        end
        check(keys==4,"the empty feed contains exactly its four public fields")
    end
    case(function()
        local calls=0
        local services=setmetatable({}, {__index=function() calls+=1;error("SDK lookup during cold feed",0) end})
        local owner=Runtime.new(services)
        local first=owner:score_feed()
        empty(first,false);empty(owner:score_feed(0),false)
        empty(owner:score_feed(1),true);empty(owner:score_feed(-1),true)
        empty(owner:score_feed("0"),true)
        first.n=99;first.rows[1]={n=1,control="ended"};first.gap=true
        empty(owner:score_feed(),false)
        local state=owner:status()
        check(state.phase=="idle" and not state.startup.pending and not state.startup.core_ready,
            "score reads leave the deferred runtime cold")
        check(owner:request_mount(0)==false,"the feed does not open public mounting")
        check(calls==0,"cold reads and the public mount refusal resolve no SDK service")
    end)
    case(function()
        local calls=0
        local services=setmetatable({}, {__index=function() calls+=1;error("SDK lookup after cold stop",0) end})
        local owner=Runtime.new(services)
        check(owner:request_stop("no Ride exists"),"stopping the cold facade is accepted")
        empty(owner:score_feed(),false)
        local state=owner:unload()
        check(state.unloaded and not state.startup.core_ready,"cold unload does not construct Core")
        empty(owner:score_feed(0),false);empty(owner:score_feed(1),true)
        check(calls==0,"post-stop and post-unload cold feeds remain inert")
    end)
    case(function()
        local f={now=1000,calls=0,native=0}
        local s={time={},input={},skater={},level={},storage={},json={},menu={},entities={},world={physics={}}}
        local function touch() f.calls+=1 end
        function s.time.now() touch();return f.now end
        function s.input.focus() touch();return {focused=true,interface_open=true,gameplay=true} end
        function s.input.allowed() touch();return true end
        function s.menu.game() touch();return {open=true} end
        function s.skater.get() touch();return {airborne=false,position=vector.create(0,0,0),heading=0} end
        function s.skater.telemetry()
            touch();return {skater=true,airborne=false,teleport_pending=false,
                watch={valid=true,state=504,ragdoll_known=true,ragdoll=false,wipeouts=0}}
        end
        function s.level.current() touch();return {name="sanvan"} end
        function s.storage.get() touch();return nil end
        function s.json.encode() touch();return "constructed score-feed fixture" end
        function s.storage.set() touch() end
        local function forbidden() f.native+=1;error("no native or input action is allowed",0) end
        s.input.pulse=forbidden
        for _,name in {"bounds","set","status","remove"} do s.entities[name]=forbidden end
        for _,name in {"create","read","release","reserve_follow","publish_follow","read_follow",
            "stop_follow","acknowledge_follow","probe_batch","submit","receipt","acknowledge"} do
            s.world.physics[name]=forbidden
        end
        local owner=Runtime.new(s)
        check(owner:request_stock_toggle(0),"ordinary stock intent enters staged startup")
        local before=f.calls
        empty(owner:score_feed(),false)
        check(f.calls==before and not owner:status().startup.core_ready,
            "reading during pending startup does not advance it or consult services")
        local state
        for _=1,8 do
            f.now+=16;state=owner:step(16)
            if state.startup.core_ready then break end
        end
        check(state.startup.core_ready and state.startup.pending,
            "real Core is constructed before stock handoff or an input action")
        before=f.calls
        empty(owner:score_feed(0),false);empty(owner:score_feed(7),true)
        check(f.calls==before,"constructed Core feed reads remain free of SDK calls")
        check(owner:request_stop("stop before stock handoff"),"pending intent stops after Core construction")
        before=f.calls
        empty(owner:score_feed(),false);empty(owner:score_feed(7),true)
        check(f.calls==before,"the facade still exposes Core's feed after Stop")
        state=owner:unload()
        check(state.unloaded and state.startup.core_ready,"unload keeps the constructed Core owner")
        before=f.calls
        empty(owner:score_feed(0),false);empty(owner:score_feed(7),true)
        check(f.calls==before and f.native==0,"post-unload reads add no SDK or native action")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests
