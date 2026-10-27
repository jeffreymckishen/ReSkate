-- Original intent deadlines and the narrowly inert producer-setup gap.
local Runtime=require("./bike_runtime")
local Core=require("./bike_runtime_core")
local Provisional=require("./bike_runtime_core_provisional_follow_fixture")
local Renewal=require("./bike_runtime_core_follow_renewal_fixture")
local Lead=require("./bike_runtime_core_follow_lead_fixture")
local Guard=require("./bike_runtime_core_ride_guard_fixture")
local Mounted=require("./bike_runtime_core_mounted_pose_fixture")
local Trick=require("./bike_runtime_core_trick_wiring_fixture")
local Floor=require("./bike_spawn_floor_qualified_fixture")
local Fixture=require("./core_native_prepare_fixture")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    cases+=1 do
        local f=Fixture.new(Core,Floor,function() return false,Fixture.setup_pending end)
        f.core=Runtime.new(f.sdk,{qualification_only=true})
        local admitted=f.now
        check(f.arm(),"facade admits the original intent")
        local out=f.until_status(function(row) return f.prepares>0 or row.stop_latched end,100,100)
        check(f.prepares==1 and not out.stop_latched and f.now>admitted+1000,
            "cold module staging consumes time before native preparation")
        check(out.mount_deadline_ms==admitted+60000 and f.unacquired(),
            "staging and preparation share the original deadline")
        f.core:request_stop("bounded staging deadline case complete")
    end
    cases+=1 do
        local f=Fixture.new(Provisional,Floor,function(state)
            if state.prepares==1 then return false,Fixture.setup_pending end
            return true
        end)
        check(f.arm(),"pending preparation mount")
        local out=f.tick()
        local deadline=out.mount_deadline_ms
        f.menu_open=true
        out=f.tick(5000)
        check(not out.stop_latched and out.native_preparation.phase=="pending" and f.prepares==1
            and f.unacquired() and out.mount_deadline_ms==deadline,
            "long inert setup gap skips preparation and acquisition even with menu open")
        f.menu_open=false
        out=f.tick(5000)
        check(not out.stop_latched and f.prepares==1 and f.unacquired()
            and out.mount_deadline_ms==deadline,"repeated long ticks do not advance or extend preparation")
        out=f.tick()
        check(out.native_preparation.phase=="ready" and f.prepares==2 and f.unacquired()
            and out.mount_deadline_ms==deadline,"later normal tick rechecks readiness without resetting deadline")
        f.core:request_stop("bounded setup gap case complete")
    end
    cases+=1 do
        local f=Fixture.new(Renewal,Floor,function() return false,Fixture.setup_pending end)
        check(f.arm(),"deadline case mount")
        local out=f.tick()
        local deadline=out.mount_deadline_ms
        f.menu_open=true
        out=f.tick(30000)
        check(not out.stop_latched and f.prepares==1 and f.unacquired(),"first inert gap remains within deadline")
        out=f.tick(30000)
        check(out.stop_latched and out.native_preparation.phase=="cancelled" and f.prepares==1
            and out.mount_deadline_ms==deadline and f.unacquired(),
            "original deadline closes pending preparation despite menu-open long ticks")
    end
    cases+=1 do
        local f=Fixture.new(Lead,Floor)
        check(f.arm(),"ready long-tick guard case mount")
        local out=f.tick()
        check(out.native_preparation.phase=="ready","preparation is no longer pending")
        out=f.tick(400)
        check(out.stop_latched and f.prepares==1 and f.unacquired(),
            "setup-only long-gap allowance never relaxes the ordinary ready-state guard")
    end
    cases+=1 do
        local f=Fixture.new(Guard,Floor,function() return false,Fixture.step_pending end)
        check(f.arm(),"same Host tick case mount")
        f.tick()
        local out=f.core:step(16)
        check(out.stop_latched and f.prepares==1 and out.native_preparation.attempts==1 and f.unacquired(),
            "a second Core step with the same clock cannot spend a second Host preparation quota")
    end
    cases+=1 do
        local f=Fixture.new(Mounted,Floor)
        f.now=1000.75;f.state=100
        local admitted=f.now
        check(f.arm(),"fractional board100 admission")
        local out=f.tick()
        check(out.native_preparation.phase=="ready" and not out.call_counts["equipment.request"],
            "fractional cold readiness still yields before equipment")
        out=f.tick()
        check(not out.stop_latched and out.phase=="equipment_acquiring"
            and out.call_counts["equipment.request"]==1,"delayed real equipment accepts integral API timestamp")
        local progress=f.records[out.equipment.progress_key]
        check(type(progress)=="table" and out.mount_deadline_ms==admitted+60000
            and progress.arm_started_ms==math.floor(admitted),
            "only equipment boundary rounds; original fractional mount deadline remains unchanged")
        check(f.prepares==1 and f.unacquired(),"equipment admission has not acquired Source or native body")
        f.core:request_stop("stop before equipment pulse")
    end
    cases+=1 do
        local f=Fixture.new(Trick,Floor)
        f.now=9007199254740991-60000+1
        local accepted,_,out=f.arm()
        check(not accepted and out.stop_latched and f.prepares==0 and f.unacquired(),
            "unrepresentable original deadline closes before preparation")
    end
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)