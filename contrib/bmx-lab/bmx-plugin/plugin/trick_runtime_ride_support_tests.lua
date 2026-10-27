-- Constructed frames and decoded-ray-shaped records, not gameplay evidence.
-- The runner must stage the real adapter with only RIDE_SUPPORT_QUALIFIED=true
-- as this private fixture. The installed module retains its false literal.
local Runtime = require("./trick_runtime")
local Qualified = require("./trick_runtime_ride_support_qualified_fixture")
local Fixture = require("./trick_runtime_tests")
local Tricks = require("./tricks")
local M = require("./force_math")
local Tests = {}
local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}; for k, x in pairs(v) do out[k] = copy(x) end; return out
end
local function ray(point, normal, surface)
    return {status="hit",normal_available=true,surface_velocity_available=true,motion="measured",
        position=copy(point),normal=copy(normal),surface_velocity=copy(surface)}
end
local function packet(f, ground, opts)
    local frame, contact, actions = f:next(ground, opts)
    contact.status="available"
    contact.query.status="available";contact.query.measurements_complete=true;contact.query.native_casts=2
    contact.query.actor_lane="named_categories_absent";contact.query.requested_query_preset="camera"
    contact.query.local_actor_excluded=false;contact.query.named_actor_categories_absent=true
    contact.rays={ray({0,0,1},f.normal,f.surface),ray({0,0,-1},f.normal,f.surface)}
    contact.support={known=true,grounded_known=true,grounded=ground,
        provenance="measured_rays_authored_wheel_geometry",epoch=frame.physics_epoch,native_collision_contact=false,
        actor_lane="named_categories_absent",actor_tripwire="authored_rider_crossings_clear_v1",
        actor_tripwire_serial=frame.serial,landing_vectors_available=ground}
    if ground then
        contact.support.wheel_index=1;contact.support.point=copy(contact.rays[1].position)
        contact.support.normal=M.unit(contact.rays[1].normal);contact.support.surface_velocity=copy(contact.rays[1].surface_velocity)
    end
    return frame,contact,actions
end
local function identity(contact)
    contact.query.actor_lane="identity";contact.query.local_actor_excluded=true
    contact.query.named_actor_categories_absent=nil;contact.query.requested_query_preset=nil
    contact.support.actor_lane="identity";contact.support.actor_tripwire="not_required_identity_lane"
    contact.support.actor_tripwire_serial=nil
end
function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function scenario(run) cases+=1;run() end
    local function refused(v) return not v.valid and v.visual_targets==nil and v.model_events==nil end
    local function accepted(r,f,ground,opts) return r:step(packet(f,ground,opts)) end
    scenario(function()
        local f=Fixture.fixture(1/60)
        local out=Runtime.new():step(packet(f,true))
        check(refused(out) and out.issue=="physical_support_unqualified","installed gate refuses derived Ride support")
        local legacy=Runtime.new():step(Fixture.fixture():next(true))
        check(legacy.valid and legacy.issue=="primed","existing constructed measured_support contract stays accepted")
    end)
    scenario(function()
        local r,f=Qualified.new(),Fixture.fixture(1/60)
        check(accepted(r,f,true).valid,"declared category lane primes")
        local frame,c,a=packet(f,false);c.rays={{status="clear"},{status="clear"}}
        local out=r:step(frame,c,a)
        check(out.valid and out.model_events.took_off,"two measured clears plus derived airborne support start a model air")
        check(not out.realized and out.visual_targets.realized==false,"accepted packet still makes model-only targets")
    end)
    scenario(function()
        local frame,c,a=packet(Fixture.fixture(1/60),true);identity(c)
        check(Qualified.new():step(frame,c,a).valid,"identity lane needs no tripwire or camera claim")
        c.query.named_actor_categories_absent=true
        check(refused(Qualified.new():step(frame,c,a)),"identity and category claims cannot contradict")
        c.query.named_actor_categories_absent="true"
        check(refused(Qualified.new():step(frame,c,a)),"identity lane refuses a nonboolean category fact")
    end)
    scenario(function()
        local mutations={
            function(c) c.status="unavailable" end,
            function(c) c.query.status="unavailable" end,
            function(c) c.query.measurements_complete=false end,
            function(c) c.query.epoch_matches=false end,
            function(c) c.query.accounting_known=false end,
            function(c) c.query.budget_exhausted=true end,
            function(c) c.query.owned_bodies_excluded=false end,
            function(c) c.query.native_casts=1 end,
            function(c) c.query.native_casts=5 end,
            function(c) c.query.native_casts=0/0 end,
            function(c) c.query.local_actor_excluded=true end,
            function(c) c.query.named_actor_categories_absent=false end,
            function(c) c.query.requested_query_preset="terrain" end,
            function(c) c.query.actor_lane="none" end,
            function(c) c.support.actor_lane="identity" end,
            function(c) c.support.native_collision_contact=true end,
            function(c) c.support.epoch=newproxy() end,
            function(c) c.support.known=false end,
            function(c) c.support.grounded_known=false end,
        }
        for i,mutate in ipairs(mutations) do
            local frame,c,a=packet(Fixture.fixture(1/60),true);mutate(c)
            check(refused(Qualified.new():step(frame,c,a)),"missing or contradictory query fact refuses: "..i)
        end
    end)
    scenario(function()
        local mutations={
            function(c) c.binding.body_handle=newproxy() end,
            function(c) c.binding.physics_epoch=newproxy() end,
            function(c) c.binding.lease_handle=newproxy() end,
            function(c) c.frame.serial="1" end,
            function(c) c.frame.time+=.001 end,
            function(c) c.frame.seconds+=.001 end,
        }
        for _,name in ipairs({"generation","user","sequence","source_epoch","context_generation","observation_serial","observed_ms","packet"}) do
            table.insert(mutations,function(c) c.frame.source[name]=nil end)
        end
        for i,mutate in ipairs(mutations) do
            local frame,c,a=packet(Fixture.fixture(1/60),true);mutate(c)
            local out=Qualified.new():step(frame,c,a)
            check(refused(out) and out.issue=="contact_frame_mismatch","exact frame/source binding refuses: "..i)
        end
    end)
    scenario(function()
        local f=Fixture.fixture(1/60);f.serial="9007199254741000"
        local prior=f.serial
        local frame,c,a=packet(f,true)
        c.support.actor_tripwire_serial=prior;c.support.actor_tripwire="authored_rider_crossings_clear_previous_epoch_v1"
        check(Qualified.new():step(frame,c,a).valid,"one-epoch tripwire above2^53 is exact")
        for _,serial in ipairs({"9007199254740999","9007199254741002","09007199254741000","0"}) do
            c.support.actor_tripwire_serial=serial
            check(refused(Qualified.new():step(frame,c,a)),"stale/future/noncanonical tripwire refuses")
        end
        c.support.actor_tripwire_serial=frame.serial
        check(refused(Qualified.new():step(frame,c,a)),"current serial cannot carry previous-epoch label")
        c.support.actor_tripwire="authored_rider_crossings_clear_v1"
        check(Qualified.new():step(frame,c,a).valid,"matching current serial and label admitted")
        c.support.actor_tripwire_serial=nil
        check(refused(Qualified.new():step(frame,c,a)),"label alone supplies no measured age")
    end)
    scenario(function()
        local frame,c,a=packet(Fixture.fixture(1/60),true)
        c.rays[1].position={0,-.5,1} -- Earlier ray is distant; Ride selected rear support.
        c.support.wheel_index=2;c.support.point=copy(c.rays[2].position)
        check(Qualified.new():step(frame,c,a).valid,"selected rear support keeps its exact measured hit")
        c.support.point=copy(c.rays[1].position)
        check(refused(Qualified.new():step(frame,c,a)),"support cannot silently switch to the first ray")
    end)
    scenario(function()
        local mutations={
            function(c) c.rays[1]={status="clear"} end,
            function(c) c.rays[2]=nil end,
            function(c) c.rays[3]={status="clear"} end,
            function(c) c.rays[1].motion="unknown" end,
            function(c) c.rays[1].normal_available=false end,
            function(c) c.rays[1].surface_velocity_available=false end,
            function(c) c.rays[1].normal={0,2,0} end,
            function(c) c.rays[1].surface_velocity={0,51,0} end,
            function(c) c.support.wheel_index=3 end,
            function(c) c.support.point[1]+=.01 end,
            function(c) c.support.normal={1,0,0} end,
            function(c) c.support.surface_velocity[1]=.01 end,
            function(c) c.support.point[4]=0 end,
            function(c) c.support.landing_vectors_available=false end,
        }
        for i,mutate in ipairs(mutations) do
            local frame,c,a=packet(Fixture.fixture(1/60),true);mutate(c)
            check(refused(Qualified.new():step(frame,c,a)),"malformed selected measurement refuses: "..i)
        end
    end)
    scenario(function()
        local frame,c,a=packet(Fixture.fixture(1/60),false)
        c.support.point={0,0,0}
        check(refused(Qualified.new():step(frame,c,a)),"airborne support cannot carry a selected impact")
    end)
    scenario(function()
        local r,f=Qualified.new(),Fixture.fixture(1/60)
        local frame,c,a=packet(f,true)
        check(r:step(frame,c,a).valid,"prime")
        local updates=r:status().model_updates
        local duplicate=r:step(frame,c,a)
        check(duplicate.valid and not duplicate.advanced and r:status().model_updates==updates,"duplicate does not advance")
        local gap=accepted(r,f,false,{steps=2})
        check(refused(gap) and gap.issue=="body_serial_gap","missing physical epoch cancels instead of fabricating elapsed trick time")
        check(accepted(r,f,true).valid,"fresh grounded observation primes after interruption")
    end)
    scenario(function()
        local original,captured=Tricks.new,nil
        Tricks.new=function(settings) local m=original(settings);captured=m;return m end
        local ok,r=pcall(Qualified.new);Tricks.new=original
        check(ok and captured~=nil,"captured real pure model")
        local inputs={};local update=captured.update
        captured.update=function(self,seconds,input) table.insert(inputs,copy(input));return update(self,seconds,input) end
        local f=Fixture.fixture(1/60)
        check(accepted(r,f,true).valid,"prime before support-retention sequence")
        f.v={0,-2,3};f.w={1,0,0}
        check(accepted(r,f,false).valid,"last unsupported body is the measured approach")
        local frame,c,a=packet(f,true)
        check(r:step(frame,c,a).valid,"first selected impact accepted")
        c.support.point[3]=100;c.rays[1].position[3]=100 -- Cannot alias retained impact.
        f.normal={.6,.8,0};f.surface={0,2,0}
        frame,c,a=packet(f,true)
        c.support.wheel_index=2;c.support.point=copy(c.rays[2].position)
        check(r:step(frame,c,a).valid,"later settled observation remains bound")
        local current=inputs[#inputs]
        check(current.landing_quality_available and current.body_up_alignment==1 and current.support_up_alignment==1,
            "settling keeps first-impact normal instead of later wheel normal")
        check(math.abs(current.closing_normal_speed-3)<1e-8,"settling retains copied first point and surface velocity")
        captured.update=update
    end)
    scenario(function()
        local r,f=Qualified.new(),Fixture.fixture(1/60)
        check(accepted(r,f,true).valid,"prime before stationary hop")
        f.v={0,-1,0}
        check(accepted(r,f,false).valid,"stationary unsupported observation")
        local out=accepted(r,f,true)
        check(refused(out) and out.issue=="preimpact_quality_unavailable","stationary hop cannot invent travel heading or fakie quality")
    end)
    scenario(function()
        local original,captured=Tricks.new,nil
        Tricks.new=function(settings) local m=original(settings);captured=m;return m end
        local ok,r=pcall(Qualified.new);Tricks.new=original
        check(ok and captured~=nil,"capture policy for bounce sequence")
        local inputs={};local update=captured.update
        captured.update=function(self,seconds,input) table.insert(inputs,copy(input));return update(self,seconds,input) end
        local f=Fixture.fixture(1/60)
        check(accepted(r,f,true).valid,"prime before bounce")
        f.v={0,-2,3};f.w={1,0,0}
        check(accepted(r,f,false).valid and accepted(r,f,true).valid,"first approach and impact")
        check(math.abs(inputs[#inputs].closing_normal_speed-3)<1e-8,"first impact uses initial contact")
        f.v={0,-1,3};f.w={0,0,0};f.surface={0,2,0};f.normal={.6,.8,0}
        check(accepted(r,f,false).valid,"unsupported interval clears first impact")
        local frame,c,a=packet(f,true)
        c.support.wheel_index=2;c.support.point=copy(c.rays[2].position)
        check(r:step(frame,c,a).valid,"recontact accepts new exact support")
        local input=inputs[#inputs]
        check(input.landing_quality_available and math.abs(input.body_up_alignment-.8)<1e-8
            and math.abs(input.closing_normal_speed-2.4)<1e-8,"bounce does not inherit prior normal or closing maximum")
        captured.update=update
    end)
    scenario(function()
        local r,f=Qualified.new(),Fixture.fixture(1/60)
        check(accepted(r,f,true).valid and accepted(r,f,false).valid,"source replacement begins during a measured air")
        f.source_epoch=Fixture.increment(f.source_epoch)
        local out=accepted(r,f,false)
        check(refused(out) and out.issue=="neutral_ground_prime_required","replacement source cannot finish another source's air")
        out=accepted(r,f,true)
        check(out.valid and out.issue=="primed" and not out.model_events.landed,"new neutral ground primes without old landing credit")
    end)
    return {cases=cases,assertions=assertions}
end
return Tests
