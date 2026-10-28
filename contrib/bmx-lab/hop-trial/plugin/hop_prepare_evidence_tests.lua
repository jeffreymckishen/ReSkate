-- Constructed observer/recorder regressions only. No SDK or Core actions are
-- started here; an assigned runner must explicitly call run().
local Services=require("./hop_services")
local Context=require("./hop_context")
local Recorder=require("./hop_recorder")
local Codec=require("./hop_evidence_codec")
local Tests={}
local setup_pending="native body producer setup pending; call prepare again explicitly"
local step_pending="waiting for a fresh qualified 60 Hz physics step"

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(name,fn) cases+=1;fn();return name end
    local function closed(unknown)
        return {phase=unknown and "cleanup_unknown" or "done",stop_latched=true,
            bike_authority=unknown==true,cleanup_pending=unknown==true,cleanup_unknown=unknown==true,
            bike_cleanup_complete=unknown~=true,force_cleanup_clear=unknown~=true,
            force_cleanup_unknown=unknown==true,stop_reason="constructed stop"}
    end
    local function fresh(delegate)
        local f={calls=0,writes={},stops=0}
        f.recorder=Recorder.new(function(key,value) f.writes[#f.writes+1]={key=key,value=value} end,"prepare_fixture")
        f.context=Context.new({stop=function(_,why) f.stops+=1;f.stop_reason=why end},f.recorder)
        f.real={world={physics={}}}
        f.real.world.physics.prepare=function(...)
            f.calls+=1;f.args=table.pack(...)
            if delegate then return delegate(...) end
            return true
        end
        f.wrapped=Services.wrap(f.real,f.context)
        return f
    end
    local function drain(f)
        for _=1,32 do
            if f.recorder:status().flushed then return end
            local ok,why=f.recorder:flush({inactive=true,terminal=true})
            check(ok,"bounded constructed flush: "..tostring(why))
        end
        error("prepare evidence exceeded bounded fixture flush")
    end
    local function rows(f)
        local chunks={}
        for _,write in ipairs(f.writes) do if write.value.rows then chunks[#chunks+1]=write.value end end
        if #chunks==0 then return {} end
        local decoded,why=Codec.decode_chunks(chunks,"prepare_fixture")
        check(decoded~=nil,"strict v4 preparation evidence decoding: "..tostring(why))
        return decoded
    end
    local function prepare_rows(f)
        local out={}
        for _,row in ipairs(rows(f)) do
            check(row.kind~="follow","preparation never becomes a Follow event")
            if row.kind=="prepare" then out[#out+1]=row.data end
        end
        return out
    end
    local function recorded(f)
        check(f.recorder:terminal(closed(false)),"constructed terminal witness is supplied separately")
        drain(f)
        return prepare_rows(f)
    end
    local function exact(actual,expected,why)
        check(actual.n==expected.n,why.." arity")
        for i=1,expected.n do check(actual[i]==expected[i],why.." value "..i) end
    end

    case("construction and missing capability are inert",function()
        local f=fresh()
        check(f.calls==0 and f.recorder:status().summary.calls==0 and #f.writes==0,
            "wrapping adds no readiness call or persistence")
        f.real.world.physics.prepare=nil
        check(f.wrapped.world.physics.prepare==nil and f.calls==0,"missing API remains absent")
    end)
    case("exact success is sampled ready and yields one event",function()
        local f=fresh()
        exact(table.pack(f.wrapped.world.physics.prepare()),table.pack(true),"ready return")
        check(f.calls==1 and f.args.n==0 and f.stops==0,"one unchanged zero-argument call")
        local before=f.recorder:status()
        check(not before.summary.cleanup_observed and before.unresolved_debt,
            "readiness gives no cleanup credit")
        local event=recorded(f)[1]
        check(event.phase=="ready" and event.call=="world.physics.prepare" and event.call_ok==true
            and event.arity==1 and event.arguments==0 and event.result==true,"strict ready observation")
        check(f.calls==1 and event.sequence==nil and event.serial==nil,"recording grants no identity or extra call")
    end)
    case("both exact wait reasons remain pending without retry",function()
        for _,reason in ipairs({setup_pending,step_pending}) do
            local f=fresh(function() return false,reason end)
            exact(table.pack(f.wrapped.world.physics.prepare()),table.pack(false,reason),"pending return")
            local event=recorded(f)[1]
            check(event.phase=="pending" and event.call_ok and event.result==false and event.arity==2
                and event.reason==reason and f.calls==1 and f.stops==0,"pending is an observation, not a retry")
        end
    end)
    case("other well-formed refusals never become pending",function()
        for _,reason in ipairs({"native body ABI or producer hook unavailable; another producer may own it",
            "owned bodies require the current local client phase outside multiplayer",
            "native body preparation failed closed","asked to prepare native bodies more than once in one tick",
            setup_pending.." changed"}) do
            local f=fresh(function() return false,reason end)
            exact(table.pack(f.wrapped.world.physics.prepare()),table.pack(false,reason),"refused return")
            local event=recorded(f)[1]
            check(event.phase=="refused" and event.result==false and event.reason==reason and f.calls==1,
                "only exact known wait tuples classify pending")
        end
    end)
    case("malformed values and nil holes are forwarded without authority",function()
        local opaque=newproxy()
        for _,reply in ipairs({table.pack(),table.pack(nil),table.pack(false),table.pack(true,"extra"),
            table.pack(false,setup_pending,nil),table.pack(opaque,nil,"tail")}) do
            local f=fresh(function() return table.unpack(reply,1,reply.n) end)
            exact(table.pack(f.wrapped.world.physics.prepare()),reply,"malformed return")
            local event=recorded(f)[1]
            check(event.phase=="malformed" and event.arity==reply.n and f.calls==1,
                "malformed tuple is recorded without repair or retry")
            check(event.body==nil and event.handle==nil and event.epoch==nil and event.sequence==nil,
                "opaque result cannot enter preparation evidence")
        end
    end)
    case("arguments are forwarded unchanged and never classified ready",function()
        local opaque=newproxy()
        local f=fresh()
        exact(table.pack(f.wrapped.world.physics.prepare(opaque,nil)),table.pack(true),"argument return")
        exact(f.args,table.pack(opaque,nil),"argument forwarding")
        local event=recorded(f)[1]
        check(event.phase=="malformed" and event.arguments==2 and event.arity==1 and f.calls==1,
            "unexpected argument shape cannot manufacture sampled readiness")
    end)
    case("raised object is rethrown exactly without stringifying",function()
        local touched=0
        local failure=setmetatable({}, {__tostring=function() touched+=1;error("must not stringify") end})
        local f=fresh(function() error(failure,0) end)
        local result=table.pack(pcall(f.wrapped.world.physics.prepare))
        check(result.n==2 and result[1]==false and result[2]==failure and f.calls==1,"same raised object reaches caller")
        local event=recorded(f)[1]
        check(event.phase=="raised" and event.call_ok==false and event.arity==0
            and event.reason=="SDK call raised" and event.result==nil and touched==0,"error evidence is scalar only")
    end)
    case("observer failure cannot change the returned tuple",function()
        for _,raises in ipairs({false,true}) do
            local calls,stops=0,0
            local opaque=newproxy()
            local real={world={physics={prepare=function() calls+=1;return false,nil,opaque end}}}
            local context={observe_service=function()
                if raises then error("constructed observer failure",0) end
                return false
            end,request_stop=function() stops+=1 end}
            local wrapped=Services.wrap(real,context)
            exact(table.pack(wrapped.world.physics.prepare()),table.pack(false,nil,opaque),"observer failure return")
            check(calls==1 and stops==1,"observer requests ordinary stop without repeating SDK call")
        end
    end)
    case("cached closure resolves replacement and removal dynamically",function()
        local f=fresh()
        local cached=f.wrapped.world.physics.prepare
        f.real.world.physics.prepare=function() f.calls+=1;return false,step_pending end
        exact(table.pack(cached()),table.pack(false,step_pending),"replacement return")
        f.real.world.physics.prepare=nil
        local removed=table.pack(pcall(cached))
        check(removed[1]==false and f.calls==1 and f.wrapped.world.physics.prepare==nil,
            "removed function is not pinned or retried")
        local events=recorded(f)
        check(#events==2 and events[1].phase=="pending" and events[2].phase=="raised",
            "replacement and removal have distinct preparation observations")
    end)
    case("terminal projection retains only named detached preparation scalars",function()
        local touched=0
        local hostile=setmetatable({}, {__index=function() touched+=1;error("index") end,
            __tostring=function() touched+=1;error("string") end,__iter=function() touched+=1;error("iterate") end})
        local f=fresh()
        local snapshot=closed(false)
        snapshot.mount_deadline_ms=61000.75
        snapshot.native_preparation={phase="ready",attempts=3,reason="last observed reason",ready_ms=1020.5,
            scope="Sampled readiness only; no body allocation or later create guarantee",
            body=hostile,epoch=newproxy(),sequence="17",reusable=true,native_retirement_known=true}
        snapshot.native_retirement_known=true
        f.context:after_step(snapshot)
        snapshot.native_preparation.phase="changed";snapshot.native_preparation.attempts=999;snapshot.mount_deadline_ms=0
        local status=f.recorder:status()
        local prep=status.latest.native_preparation
        check(prep.phase=="ready" and prep.attempts==3 and prep.reason=="last observed reason" and prep.ready_ms==1020.5
            and status.latest.mount_deadline_ms==61000.75 and type(prep.scope)=="string","original scalar copy survives mutation")
        check(prep.body==nil and prep.epoch==nil and prep.sequence==nil and prep.reusable==nil
            and prep.native_retirement_known==nil and status.latest.native_retirement_known==nil and touched==0,
            "no opaque value, identity or invented authority is copied")
        check(f.calls==0 and status.summary.native_qualified==false and status.summary.native_retirement_known==false,
            "terminal copying adds no SDK call or native qualification")
    end)
    case("preparation DTO alone cannot clear unresolved cleanup",function()
        local f=fresh()
        check(f.wrapped.world.physics.prepare()==true,"constructed readiness observed")
        check(not f.recorder:flush({inactive=true,terminal=true}),"ready does not supply a terminal witness")
        f.context:after_step({phase="armed",mount_deadline_ms=61000,
            native_preparation={phase="ready",attempts=1,ready_ms=1000,cleanup_pending=false,
                cleanup_unknown=false,bike_cleanup_complete=true,native_retirement_known=true}})
        local status=f.recorder:status()
        check(status.unresolved_debt and status.unqualified and status.latest.bike_cleanup_complete==nil,
            "nested readiness cannot replace missing top-level cleanup observations")
        check(status.latest.native_preparation.cleanup_pending==nil and status.latest.native_preparation.bike_cleanup_complete==nil,
            "preparation schema has no cleanup-credit fields")
        f.context:after_step(closed(true))
        status=f.recorder:status()
        check(status.unresolved_debt and status.summary.native_qualified==false and status.summary.native_retirement_known==false,
            "explicit unknown cleanup remains unknown after readiness")
    end)
    case("preparation evidence uses existing text and capacity bounds",function()
        local reason=string.rep("x",Recorder.limits.text_bytes+1)
        local f=fresh(function() return false,reason end)
        exact(table.pack(f.wrapped.world.physics.prepare()),table.pack(false,reason),"bounded evidence return")
        local status=f.recorder:status()
        check(status.observation_loss and status.stop_requested and f.context:status().stop_requested,
            "truncated evidence requests stop without changing the SDK refusal")
        f.recorder:terminal(closed(true));drain(f)
        local event=prepare_rows(f)[1]
        check(event.reason==string.sub(reason,1,Recorder.limits.text_bytes) and f.calls==1,
            "bounded reason is retained without an automatic retry")
        check(Recorder.limits.regular_rows==2048 and Recorder.limits.critical_rows==128,
            "preparation does not enlarge existing event capacity")
    end)
    case("listed opaque or nonfinite preparation fields fail closed",function()
        local touched=0
        local hostile=setmetatable({}, {__tostring=function() touched+=1;error("string") end})
        local f=fresh()
        local snapshot=closed(false)
        snapshot.mount_deadline_ms=0/0
        snapshot.native_preparation={phase=hostile,attempts=math.huge,ready_ms=newproxy(),scope="constructed"}
        f.context:after_step(snapshot)
        local status=f.recorder:status()
        check(status.observation_loss and status.stop_requested and status.unresolved_debt and touched==0,
            "invalid named values cannot fabricate bounded readiness or clear cleanup")
        check(status.latest.mount_deadline_ms==nil and status.latest.native_preparation.phase==nil
            and status.latest.native_preparation.attempts==nil and status.latest.native_preparation.ready_ms==nil,
            "invalid named values are omitted without conversion")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
