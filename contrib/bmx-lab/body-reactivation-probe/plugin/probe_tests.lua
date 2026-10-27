-- Pure injected-adapter tests. No game, native body, input, Follow or pose API is called.
-- Ray clearance is sampled segment evidence plus an operator observation, never a volume proof.
-- The four-second watchdog is observed only when tick runs; it is not an independent timer.
local Probe=require("./probe")
local cases,assertions=0,0
local function check(ok,message)
    assertions+=1
    if not ok then error(message or "check failed",2) end
end
local function test(name,fn)
    cases+=1
    local ok,why=pcall(fn)
    if not ok then error(name..": "..tostring(why),0) end
end
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
local STAGES={"initial_park","initial_park_observed","transform","categories","collisions",
    "motion","wake","dynamic_observed","repark","repark_observed"}
local SERIALS={"9007199254740993","9007199254740994","9007199254740995","9007199254740996",
    "9007199254740997","9007199254740998","9007199254740999","9007199254741000","9007199254741001","9007199254741002"}
local function receipt()
    local records={}
    for i,name in ipairs(STAGES) do
        local epoch={serial=SERIALS[i],time=1+i*.02,seconds=1/60}
        local observation={available=false}
        if i~=1 and i~=9 then
            observation={available=true,shape_count=1,categories={0},collisions={(i>=5 and i<=8) and 257 or 0},
                dynamic=i>=6 and i<=8,angular_fourth=0,force={0,0,0,0},torque={0,0,0,0},
                sample={epoch=copy(epoch),position={0,1,3},rotation={0,0,0,1},velocity={0,0,0},
                    angular_velocity={0,0,0},inertia={2,3,4},mass=12}}
        end
        records[i]={stage=name,passed=true,epoch=epoch,observation=observation}
    end
    return {status="observed",phase="terminal",terminal=true,cleanup="confirmed",cleanup_owed=false,
        first_failure="none",cycle_count=1,native_retirement_known=false,record_count=10,records=records,
        target_position={0,1,3},target_rotation={0,0,0,1},elapsed_ms=240}
end
local function fixture()
    local f={t=0,calls={now=0,context=0,ray=0,capabilities=0,prepare=0,create=0,read=0,begin=0,poll=0,release=0},
        hooks={},approved=false,capable=true,prepare_ready=true,body={},probe={},poll_rows={},poll_index=0,
        ctx={level="synthetic-level",position={0,1,0},heading=0,speed=0,on_foot=true,airborne=false,
            focused=true,gameplay=true,menu_known=true,menu_open=false,interface_open=false}}
    local api={}
    local function called(name,...)
        f.calls[name]+=1
        local hook=f.hooks[name]
        if hook then return true,hook(...) end
        return false
    end
    api.now=function()
        local used,a,b=called("now");if used then return a,b end;return f.t
    end
    api.context=function()
        local used,a,b=called("context");if used then return a,b end;return copy(f.ctx)
    end
    api.capabilities=function()
        local used,a,b=called("capabilities");if used then return a,b end;return f.capable
    end
    api.prepare=function()
        local used,a,b=called("prepare");if used then return a,b end;return f.prepare_ready,"synthetic-warmup"
    end
    api.ray=function(from,to)
        f.last_ray_from,f.last_ray_to=from,to
        local used,a,b=called("ray",from,to);if used then return a,b end
        if from[2]>to[2] then
            local fraction=from[2]/(from[2]-to[2])
            return {status="hit",fraction=fraction,position={from[1]+(to[1]-from[1])*fraction,0,
                from[3]+(to[3]-from[3])*fraction}}
        end
        return {status="clear"}
    end
    api.create=function(definition)
        check(f.approved,"create before explicit visual approval")
        f.created_definition=definition
        local used,a,b=called("create",definition);if used then return a,b end;return f.body
    end
    api.read=function(body)
        check(f.approved and body==f.body,"read without the approved body")
        local used,a,b=called("read",body);if used then return a,b end
        f.read_value={serial=SERIALS[1],time=1,seconds=1/60,position=copy(f.created_definition.position),
            rotation={0,0,0,1},velocity={0,0,0},angular_velocity={0,0,0},inertia={2,3,4},mass=12}
        return f.read_value
    end
    api.begin=function(body)
        check(f.approved and body==f.body,"begin without the approved body")
        f.begin_t=f.t
        local used,a,b=called("begin",body);if used then return a,b end;return f.probe
    end
    api.poll=function(probe)
        check(probe==f.probe,"poll only this fixture's handle")
        local used,a,b=called("poll",probe);if used then return a,b end
        f.poll_index+=1
        local row=f.poll_rows[f.poll_index]
        if not row then return nil,"synthetic pending" end
        return row.value,row.reason
    end
    api.release=function(body)
        check(f.approved and body==f.body,"release only the approved body")
        check(f.calls.begin==0,"ordinary release after a begin attempt")
        local used,a,b=called("release",body);if used then return a,b end;return true
    end
    f.api=table.freeze(api)
    f.object=Probe.new(f.api)
    return f
end
local function bounded(f)
    check(f.calls.create<=1 and f.calls.begin<=1,"one create and one begin attempt at most")
    check(f.calls.release<=1,"ordinary release cannot retry")
    local s=f.object:snapshot()
    check(s.counts.create==f.calls.create and s.counts.begin==f.calls.begin and s.counts.release==f.calls.release,
        "observable mutation counts agree")
    return s
end
local function untouched(f)
    check(f.calls.create==0 and f.calls.read==0 and f.calls.begin==0 and f.calls.release==0,"no normal body mutation before admission")
    bounded(f)
end
local function tick(f,delta)
    f.t+=delta or 16
    local polls,rays=f.calls.poll,f.calls.ray
    f.object:tick()
    check(f.calls.poll-polls<=1,"at most one poll per tick")
    check(f.calls.ray-rays<=Probe.limits.ray_budget,"bounded ray budget per tick")
    if not f.approved then untouched(f) end
    return bounded(f)
end
local function advance_to(f,phase,max_ticks)
    local s=f.object:snapshot()
    for _=1,max_ticks or 12 do
        if s.phase==phase then return s end
        check(not s.terminal,"terminal before "..phase..": "..tostring(s.reason))
        s=tick(f)
    end
    error("did not reach "..phase..": "..s.phase,2)
end
local function prepare(f)
    untouched(f)
    check(f.object:prepare(),"explicit Prepare accepted")
    check(f.calls.prepare==0,"Prepare click queues work")
    local s=tick(f)
    check(s.phase=="prepared",s.reason)
    return s
end
local function surveyed(f)
    prepare(f)
    check(f.object:survey(),"explicit survey accepted")
    check(f.calls.ray==0,"survey click queues work")
    local s=advance_to(f,"await_visual_approval")
    untouched(f)
    return s
end
local function approved(f)
    local s=surveyed(f)
    check(f.object:approve(s.candidate.id),"exact displayed candidate approved")
    f.approved=true
    check(f.calls.create==0 and f.calls.begin==0,"approval itself performs no body work")
    return f.object:snapshot()
end
local function running(f)
    approved(f)
    local s=advance_to(f,"polling")
    check(f.calls.create==1 and f.calls.begin==1 and f.calls.release==0,"single admitted native cycle")
    check(s.cleanup=="pending" and not s.terminal)
    return s
end
local function terminal(f,phase,reason)
    local s=bounded(f)
    check(s.terminal and s.phase==phase,"expected terminal "..phase..", got "..s.phase)
    if reason then check(string.find(s.reason,reason,1,true)~=nil,tostring(s.reason)) end
    local calls=copy(f.calls)
    f.object:tick();f.object:stop();f.object:unload()
    check(not f.object:prepare() and not f.object:survey() and not f.object:approve(1),"terminal arm cannot be reused")
    for _,name in ipairs({"create","read","begin","poll","release","prepare","ray"}) do
        check(f.calls[name]==calls[name],"terminal operation retried "..name)
    end
    return s
end

local function run()
    cases,assertions=0,0
    test("idle is inert and explicit Prepare permits at most eight separate warmup attempts",function()
        local f=fixture()
        check(f.object:snapshot().phase=="idle")
        check(not f.object:survey() and not f.object:approve(1))
        tick(f);untouched(f);check(f.calls.prepare==0 and f.calls.ray==0)
        f.prepare_ready=false
        for n=1,8 do
            check(f.object:prepare())
            check(not f.object:prepare(),"duplicate queued click")
            local s=tick(f)
            check(s.phase=="prepare_pending" and f.calls.prepare==n)
            tick(f);check(f.calls.prepare==n,"pending warmup never retries automatically")
        end
        check(not f.object:prepare(),"bounded explicit attempts")
        untouched(f)
    end)
    test("warmup becomes ready only after a new explicit Prepare click",function()
        local f=fixture();f.prepare_ready=false
        check(f.object:prepare());tick(f)
        f.prepare_ready=true
        tick(f);check(f.calls.prepare==1 and f.object:snapshot().phase=="prepare_pending")
        check(f.object:prepare());tick(f)
        check(f.calls.prepare==2 and f.object:snapshot().phase=="prepared")
        untouched(f)
    end)
    test("capability and clock errors refuse before body work",function()
        for _,kind in ipairs({"capability_false","capability_throw","prepare_nil","prepare_throw","clock_nan","clock_throw"}) do
            local f=fixture()
            if kind=="capability_false" then f.capable=false
            elseif kind=="capability_throw" then f.hooks.capabilities=function() error("synthetic capability fault") end
            elseif kind=="prepare_nil" then f.hooks.prepare=function() return nil end
            elseif kind=="prepare_throw" then f.hooks.prepare=function() error("synthetic prepare fault") end
            elseif kind=="clock_nan" then f.hooks.now=function() return 0/0 end
            else f.hooks.now=function() error("synthetic clock fault") end end
            f.object:prepare();tick(f)
            untouched(f)
            local s=f.object:snapshot()
            check(s.terminal and (s.phase=="refused" or s.phase=="unconfirmed"))
        end
    end)
    test("survey is 38 bounded finite segments and preserves its evidence scope",function()
        local f=fixture();local s=surveyed(f)
        check(s.initial_survey.ray_count==38 and #s.initial_survey.observations==38 and f.calls.ray==38)
        check(s.initial_survey.scope=="bounded_segments_plus_operator_observation_not_volume_clearance")
        check(s.candidate.id==1 and s.candidate.position[1]==0 and s.candidate.position[2]==1 and s.candidate.position[3]==3)
        check(s.actor_generation_available==false,"this adapter does not invent actor-generation evidence")
        for _,row in ipairs(s.initial_survey.observations) do
            check(row.kind=="floor" or row.kind=="obstacle")
            for j=1,3 do check(row.from[j]==row.from[j] and row.to[j]==row.to[j]) end
        end
        untouched(f)
    end)
    test("unknown rays, bad floor hits and obstacle hits refuse admission",function()
        for _,kind in ipairs({"unknown","off_segment","missing_floor","obstacle"}) do
            local f=fixture();prepare(f)
            f.hooks.ray=function(from,to)
                if kind=="unknown" then return {status="unknown"} end
                if from[2]>to[2] then
                    if kind=="missing_floor" then return {status="clear"} end
                    local fraction=from[2]/(from[2]-to[2])
                    return {status="hit",fraction=fraction,position={from[1]+(kind=="off_segment" and .1 or 0),0,from[3]}}
                end
                return {status="hit",fraction=.5,position={0,1,3}}
            end
            check(f.object:survey())
            for _=1,8 do if f.object:snapshot().terminal then break end;tick(f) end
            terminal(f,"refused");untouched(f)
        end
    end)
    test("approval requires displayed id and later closed-interface refresh",function()
        local f=fixture();surveyed(f)
        check(not f.object:approve(2) and not f.object:approve("1"))
        tick(f);untouched(f)
        f.ctx.interface_open=true
        check(f.object:approve(1));f.approved=true
        check(not f.object:approve(1),"approval cannot be reused")
        local rays=f.calls.ray
        local s=tick(f)
        check(s.phase=="approval_wait" and f.calls.ray==rays and f.calls.create==0)
        f.ctx.interface_open=false
        s=advance_to(f,"create_ready")
        check(s.refresh.ray_count==38 and f.calls.ray==76 and f.calls.create==0)
        check(s.approval.position[3]==3 and s.approval.action=="explicit_menu_visual_approval")
    end)
    test("expired candidates and stale approval windows never create a body",function()
        local f=fixture();surveyed(f);f.t+=Probe.limits.approval_ms+1
        check(not f.object:approve(1));terminal(f,"refused","candidate_expired");untouched(f)
        local g=fixture();approved(g);g.ctx.interface_open=true
        tick(g,Probe.limits.wait_ms+1)
        terminal(g,"refused","approval_expired");untouched(g)
    end)
    test("review or approved context changes stick and cannot be erased by moving back",function()
        for _,moment in ipairs({"review","approved"}) do
            for _,kind in ipairs({"level","position","heading"}) do
                local f=fixture()
                if moment=="review" then surveyed(f) else approved(f) end
                local old=copy(f.ctx)
                if kind=="level" then f.ctx.level="other-synthetic-level"
                elseif kind=="position" then f.ctx.position[1]=.051
                else f.ctx.heading=.031 end
                tick(f)
                f.ctx=old
                terminal(f,"refused",kind=="level" and "level_changed" or "actor_moved_since_survey")
                untouched(f)
            end
        end
    end)
    test("refreshed survey freshness and capabilities are rechecked before creation",function()
        for _,kind in ipairs({"stale","capability","focus"}) do
            local f=fixture();approved(f);advance_to(f,"create_ready")
            if kind=="capability" then f.capable=false elseif kind=="focus" then f.ctx.focused=false end
            tick(f,kind=="stale" and Probe.limits.fresh_ms+1 or 10)
            terminal(f,"refused");untouched(f)
        end
    end)
    test("the complete refreshed survey must remain within 500 ms at create and begin",function()
        local f=fixture();approved(f);tick(f)
        check(f.object:snapshot().phase=="refreshing")
        for _=1,5 do tick(f,100) end
        check(f.object:snapshot().phase=="create_ready","exactly 500 ms survey can finish")
        tick(f)
        terminal(f,"refused","refreshed_survey_stale");untouched(f)
        local g=fixture();approved(g);tick(g)
        for _=1,5 do tick(g,90) end
        check(g.object:snapshot().phase=="create_ready")
        tick(g);check(g.object:snapshot().phase=="read_ready")
        g.hooks.read=function()
            g.t+=20
            return {serial=SERIALS[1],time=1,seconds=1/60,position={0,1,3},rotation={0,0,0,1},
                velocity={0,0,0},angular_velocity={0,0,0},inertia={2,3,4},mass=12}
        end
        tick(g)
        local s=terminal(g,"refused","body_read_stale")
        check(g.calls.create==1 and g.calls.begin==0 and g.calls.release==1 and s.cleanup=="unconfirmed")
    end)
    test("one ten-stage receipt succeeds without losing serial precision above 2^53",function()
        local f=fixture();running(f)
        local r=receipt();f.poll_rows={{value=r}}
        local s=tick(f)
        check(s.initial_read.serial=="9007199254740993" and s.initial_read.epoch==nil,"ordinary adapter sample")
        check(s.last_result.records[1].epoch.serial==SERIALS[1] and s.last_result.records[10].epoch.serial==SERIALS[10])
        check(type(s.last_result.records[1].epoch.serial)=="string")
        check(s.cleanup=="confirmed" and not s.operator_end_required)
        terminal(f,"observed","one_mechanism_cycle_only")
        check(f.calls.create==1 and f.calls.begin==1 and f.calls.poll==1 and f.calls.release==0)
    end)
    test("create refusal or unknown exception is terminal without a blind retry",function()
        for _,throws in ipairs({false,true}) do
            local f=fixture();approved(f);advance_to(f,"create_ready")
            f.hooks.create=function() if throws then error("synthetic create fault") end;return nil,"refused" end
            tick(f)
            local s=terminal(f,"refused","create_refused_or_unknown")
            check(s.cleanup=="unconfirmed" and s.operator_end_required and f.calls.create==1 and f.calls.begin==0 and f.calls.release==0)
        end
    end)
    test("bad or stale coherent read attempts ordinary release once without claiming cleanup",function()
        for _,kind in ipairs({"nil","throw","serial_number","mass","stale"}) do
            local f=fixture();approved(f);advance_to(f,"read_ready")
            f.hooks.read=function()
                if kind=="nil" then return nil end
                if kind=="throw" then error("synthetic read fault") end
                local value={serial=kind=="serial_number" and 9007199254740994 or SERIALS[1],time=1,seconds=1/60,
                    position={0,1,3},rotation={0,0,0,1},velocity={0,0,0},angular_velocity={0,0,0},inertia={2,3,4},
                    mass=kind=="mass" and 13 or 12}
                if kind=="stale" then f.t+=Probe.limits.fresh_ms+1 end
                return value
            end
            tick(f)
            local s=terminal(f,"refused")
            check(f.calls.create==1 and f.calls.begin==0 and f.calls.release==1)
            check(s.release.accepted==true and s.cleanup=="unconfirmed" and s.operator_end_required,"regular release is not final-park proof")
        end
    end)
    test("begin refusal consumes its attempt and never calls regular release",function()
        for _,throws in ipairs({false,true}) do
            local f=fixture();approved(f);advance_to(f,"read_ready")
            f.hooks.begin=function() if throws then error("synthetic begin fault") end;return nil,"refused" end
            tick(f)
            local s=terminal(f,"unconfirmed","begin_refused_or_unknown")
            check(s.counts.begin==1 and s.cleanup=="unconfirmed" and s.operator_end_required and f.calls.release==0)
        end
    end)
    test("nil polls and first failure remain pending until final cleanup receipt",function()
        local f=fixture();running(f)
        local done=receipt()
        f.poll_rows={{reason="nil pending"},{value={terminal=false,phase="repark",cleanup="pending",cleanup_owed=true,first_failure="wake_failed"}},
            {reason="nil during cleanup"},{value=done}}
        local s=tick(f);check(s.phase=="polling" and s.cleanup=="pending" and not s.terminal)
        s=tick(f);check(s.first_failure=="wake_failed" and s.cleanup=="pending" and not s.terminal)
        s=tick(f);check(s.first_failure=="wake_failed" and not s.terminal)
        s=tick(f);check(s.cleanup=="confirmed" and not s.operator_end_required and s.first_failure=="wake_failed")
        terminal(f,"failed","wake_failed")
        check(f.calls.poll==4 and f.calls.release==0,"native provider owns repark after begin")
    end)
    test("stop keeps polling native cleanup while unload records cleanup as unknown",function()
        local f=fixture();running(f);f.object:stop()
        check(f.object:snapshot().stop_requested and not f.object:snapshot().terminal and f.calls.release==0)
        f.poll_rows={{value=receipt()}};tick(f)
        check(f.object:snapshot().cleanup=="confirmed")
        terminal(f,"failed","terminal_result_not_success")
        local g=fixture();running(g);g.object:unload()
        local s=terminal(g,"unconfirmed","unloaded_before_terminal_receipt")
        check(s.operator_end_required and s.cleanup=="unconfirmed" and g.calls.release==0)
    end)
    test("four-second watchdog is tick-observed and never substitutes release for cleanup",function()
        local f=fixture();running(f)
        f.t=f.begin_t+Probe.limits.watchdog_ms
        check(not f.object:snapshot().terminal,"elapsed wall time alone cannot execute a Lua tick")
        local polls=f.calls.poll
        local s=tick(f,0)
        check(f.calls.poll==polls and f.calls.release==0 and s.operator_end_required and s.cleanup=="unconfirmed")
        terminal(f,"unconfirmed","tick_observed_watchdog_expired")
    end)
    test("clock failures during admitted native work remain unconfirmed without release",function()
        for _,kind in ipairs({"backward","nan","throw"}) do
            local f=fixture();running(f)
            if kind=="backward" then f.t=f.begin_t-1
            elseif kind=="nan" then f.hooks.now=function() return 0/0 end
            else f.hooks.now=function() error("synthetic clock error") end end
            f.object:tick()
            local s=terminal(f,"unconfirmed","clock_unavailable_or_regressed")
            check(s.cleanup=="unconfirmed" and s.operator_end_required and f.calls.release==0)
        end
    end)
    test("snapshot, callback argument and receipt aliases cannot alter private state",function()
        local f=fixture();local display=surveyed(f)
        display.candidate.position[3]=99;display.candidate.id=99;display.initial_survey.observations[1].from[1]=99
        check(f.object:approve(1));f.approved=true;advance_to(f,"polling")
        check(f.created_definition.position[3]==3,"display mutation cannot relocate approved body")
        f.created_definition.position[3]=99;f.read_value.position[3]=99;f.last_ray_from[1]=99
        local pending={terminal=false,phase="motion",cleanup="pending",first_failure="none",extra={x=1}}
        f.poll_rows={{value=pending},{value=receipt()}}
        local s=tick(f);pending.extra.x=99;s.last_result.extra.x=99;s.counts.begin=99;s.approval.position[3]=99
        local private=f.object:snapshot()
        check(private.last_result.extra.x==1 and private.counts.begin==1 and private.approval.position[3]==3)
        check(private.definition.position[3]==3 and private.initial_read.position[3]==3,"callback values were detached")
        tick(f);terminal(f,"observed");check(f.calls.release==0)
    end)
    test("malformed pending data and invalid success receipts never count as success",function()
        local f=fixture();running(f)
        local cyclic={terminal=false};cyclic.self=cyclic
        f.poll_rows={{value=cyclic},{value={terminal="false"}},{value=receipt()}}
        check(not tick(f).terminal and not tick(f).terminal,"malformed polls retain cleanup responsibility")
        tick(f);terminal(f,"observed");check(f.calls.release==0)
        local h=fixture();running(h)
        h.hooks.poll=function()
            if h.calls.poll==1 then error("synthetic poll fault") end
            return receipt()
        end
        check(not tick(h).terminal,"poll exception does not discard cleanup responsibility")
        tick(h);terminal(h,"observed");check(h.calls.release==0)
        for _,kind in ipairs({"serial","serial_order","epoch_seconds","sample_epoch","stage","categories","collision","target","transform","force","elapsed","cleanup","cleanup_witness"}) do
            local g=fixture();running(g);local r=receipt()
            if kind=="serial" then r.records[2].epoch.serial="18446744073709551616"
            elseif kind=="serial_order" then r.records[2].epoch.serial=r.records[1].epoch.serial
            elseif kind=="epoch_seconds" then r.records[2].epoch.seconds=.1
            elseif kind=="sample_epoch" then r.records[3].observation.sample.epoch.serial=SERIALS[2]
            elseif kind=="stage" then r.records[5].stage="wrong"
            elseif kind=="categories" then r.records[4].observation.categories[1]=1
            elseif kind=="collision" then r.records[5].observation.collisions[1]=0
            elseif kind=="target" then r.target_position[1]=.1
            elseif kind=="transform" then r.records[3].observation.sample.position[3]=4
            elseif kind=="force" then r.records[10].observation.force[4]=1
            elseif kind=="elapsed" then r.elapsed_ms=3000
            elseif kind=="cleanup_witness" then r.records[10].epoch.serial=r.records[9].epoch.serial
            else r.cleanup="pending";r.cleanup_owed=true end
            g.poll_rows={{value=r}};tick(g)
            local s=terminal(g,"failed")
            check(g.calls.release==0 and s.phase~="observed")
            if kind=="cleanup" or kind=="cleanup_witness" or kind=="force" then check(s.cleanup=="unconfirmed" and s.operator_end_required) end
        end
    end)
    test("terminal record shapes and sample epochs cannot counterfeit cleanup proof",function()
        local f=fixture();running(f)
        local malformed=receipt();malformed.records[5]=42
        f.poll_rows={{value=malformed},{value=receipt()}}
        local waiting=tick(f)
        check(not waiting.terminal and waiting.phase=="polling" and waiting.cleanup=="pending",
            "primitive terminal record keeps native cleanup pending")
        check(waiting.events[#waiting.events].name=="poll_malformed" and f.calls.release==0)
        tick(f);terminal(f,"observed");check(f.calls.poll==2 and f.calls.release==0)
        for _,field in ipairs({"serial","time","seconds"}) do
            local g=fixture();running(g)
            local failed=receipt();failed.status="failed";failed.first_failure="synthetic_native_failure"
            local witness=failed.records[10].observation.sample.epoch
            if field=="serial" then witness.serial=SERIALS[9]
            elseif field=="time" then witness.time-=.001
            else witness.seconds=.02 end
            g.poll_rows={{value=failed}};tick(g)
            local result=terminal(g,"failed","synthetic_native_failure")
            check(result.cleanup=="unconfirmed" and result.operator_end_required and g.calls.release==0,
                "cleanup witness must share record "..field)
        end
        local h=fixture();running(h)
        local mismatch=receipt();mismatch.records[3].observation.sample.epoch.seconds=.02
        h.poll_rows={{value=mismatch}};tick(h)
        local result=terminal(h,"failed","terminal_result_not_success")
        check(result.cleanup=="confirmed" and not result.operator_end_required and h.calls.release==0,
            "bad success sample seconds rejects success while a distinct valid repark still proves cleanup")
    end)
    return {cases=cases,assertions=assertions,native_calls=0,game_evidence=false}
end
return {run=run}
