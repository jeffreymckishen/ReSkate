-- Model-only release projection from actual trick policy over constructed
-- frames. This suite does not enable Ride support or send a native pose.
local Runtime=require("./trick_runtime")
local Fixture=require("./trick_runtime_tests")
local Tricks=require("./tricks")
local Tests={}
local function copy(v)
    if type(v)~="table" then return v end
    local out={};for k,x in pairs(v) do out[k]=copy(x) end;return out
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function scenario(run) cases+=1;run() end
    local function tick(r,f,ground,opts) return r:step(f:next(ground,opts)) end
    local function air(r,f)
        check(tick(r,f,true).valid,"constructed neutral support primes")
        check(tick(r,f,false).model_events.took_off,"constructed unsupported successor begins model air")
    end
    scenario(function()
        local out=tick(Runtime.new(),Fixture.fixture(),true)
        local t=out.visual_targets
        check(t.barspin_release==0 and t.tailwhip_release==0,"neutral pose exposes both zero channel releases")
        check(not t.realized and t.scope=="model_target_only","release projection retains authored model provenance")
    end)
    for _,channel in ipairs({{request="handlebar",release="barspin_release",angle="barspin",ticks=46,state="bar_waiting_catch",caught="bar_caught"},
        {request="tailwhip",release="tailwhip_release",angle="tailwhip",ticks=56,state="tail_waiting_catch",caught="tail_caught"}}) do
        scenario(function()
            local r,f=Runtime.new(),Fixture.fixture();air(r,f)
            local request={neutral=false};request[channel.request]="left"
            local out=tick(r,f,false,request)
            check(out.valid,"fresh selected channel request")
            for _=1,channel.ticks do out=tick(r,f,false,{neutral=false});check(out.valid,"bounded channel rotation") end
            check(out.model_state[channel.state] and math.abs(math.abs(out.visual_targets[channel.angle])-2*math.pi)<1e-8,
                "completed rotation is still waiting for catch at2pi")
            check(out.visual_targets[channel.release]==1,"waiting catch keeps the channel released despite neutral geometric angle")
            out=tick(r,f,false)
            check(out.valid and out.model_events[channel.caught] and out.visual_targets[channel.release]==1,
                "catch starts with the existing released endpoint")
            out=tick(r,f,false)
            check(out.visual_targets[channel.release]>0 and out.visual_targets[channel.release]<1,"next sample blends channel toward its grip")
            for _=1,8 do out=tick(r,f,false);check(out.valid,"catch recovery stays valid") end
            check(out.visual_targets[channel.release]==0,"channel reaches the caught endpoint after its own blend")
        end)
        scenario(function()
            local r,f=Runtime.new(),Fixture.fixture();air(r,f)
            local request={neutral=false};request[channel.request]="right"
            check(tick(r,f,false,request).valid,"opposite channel direction starts")
            local out
            for _=1,channel.ticks+15 do out=tick(r,f,false,{neutral=false});check(out.valid,"uncaught flight stays a model observation") end
            check(not out.model_state[channel.caught] and out.visual_targets[channel.release]==1,
                "missed catch does not visually reclaim the bars or pedals")
        end)
    end
    scenario(function()
        local r,f=Runtime.new(),Fixture.fixture();air(r,f)
        check(tick(r,f,false,{movement=24,neutral=false}).valid,"existing pose movement starts")
        local out=tick(r,f,false,{neutral=false})
        local t=out.visual_targets
        check(t.barspin_release==0 and t.tailwhip_release==0,"pose mask never fabricates a bar or tail channel release")
        check(t.release_left_hand+t.release_right_hand+t.release_left_foot+t.release_right_foot>0,
            "existing movement mask releases remain separately projected")
    end)
    scenario(function()
        local r,f=Runtime.new(),Fixture.fixture();air(r,f)
        check(tick(r,f,false,{handlebar="left",neutral=false}).valid,"bar starts before projection checks")
        local out=tick(r,f,false,{neutral=false})
        local expected=out.visual_targets.barspin_release
        check(expected>0,"test observes nonzero release")
        local public=Runtime.public_snapshot(out)
        out.visual_targets.barspin_release=999
        check(public.visual_targets.barspin_release==expected and r:status().visual_targets.barspin_release==expected,
            "result/public/status have detached release values")
        public.visual_targets.tailwhip_release=.8
        check(r:status().visual_targets.tailwhip_release==0,"mutation of projected release cannot alter adapter state")
    end)
    scenario(function()
        local base=tick(Runtime.new(),Fixture.fixture(),true)
        for _,field in ipairs({"barspin_release","tailwhip_release"}) do
            for _,bad in ipairs({-1,1.01,0/0,math.huge,"1"}) do
                local raw=copy(base);raw.visual_targets[field]=bad
                check(Runtime.public_snapshot(raw)==nil,"nonfinite or out-of-range channel release is rejected")
            end
            local missing=copy(base);missing.visual_targets[field]=nil
            check(Runtime.public_snapshot(missing)==nil,"channel release cannot disappear from a complete target")
        end
    end)
    scenario(function()
        local original,captured=Tricks.new,nil
        Tricks.new=function(settings) local m=original(settings);captured=m;return m end
        local ok,r=pcall(Runtime.new);Tricks.new=original
        check(ok and captured~=nil,"capture actual pure policy without a production test option")
        local state=captured.state
        captured.state=function(self) local s=state(self);s.bar_release=1.1;return s end
        local out=tick(r,Fixture.fixture(),true)
        captured.state=state
        check(not out.valid and out.issue=="invalid_model_targets" and out.visual_targets==nil,
            "invalid producer channel release is refused before presentation")
    end)
    return {cases=cases,assertions=assertions}
end
return Tests
