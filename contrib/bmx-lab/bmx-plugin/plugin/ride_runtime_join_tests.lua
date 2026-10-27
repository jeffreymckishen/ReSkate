-- Exact BFAF helper join. Positive support below is CONSTRUCTED model policy,
-- never actual Contact output, SDK exclusion evidence or native support proof.
local Fixtures=require("./ride_runtime_tests")
local Trick=require("./trick_runtime")
local Alignment=require("./rider_alignment")
local Recovery=require("./recovery_runtime")
local Tests={}
local function count(f,name) local n=0 for _,c in ipairs(f.calls) do if c==name then n+=1 end end return n end
local function constructed(options)
    local model=Trick.new()
    options=options or {}
    options.models=options.models or {}
    options.models.tricks=model
    local f=Fixtures.fixture(options)
    f.on_decode=function(out)
        out.fixture_provenance="CONSTRUCTED_MODEL_POLICY_ONLY"
        out.query.accounting_known=true
        out.support={known=true,grounded_known=true,grounded=not f.clear,provenance="measured_support",
            point={0,0,0},normal={0,1,0},surface_velocity={0,0,0}}
    end
    return f,model
end
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    cases+=1 do
        local model=Trick.new()
        local f=Fixtures.fixture({actual_contact=true,models={tricks=model}})
        f.on_probe=function(epoch)
            return {status="available",epoch=epoch,native_casts=2,budget_exhausted=false,
                local_actor_excluded=true,owned_bodies_excluded=true,rays={{status="clear"},{status="clear"}}}
        end
        local s=f.observe()
        -- The trick adapter still refuses physical support, but a refused trick
        -- is presentation only: the ride goes on without one.
        check(not s.stop_requested and string.find(s.model.trick_status,"physical_support_unqualified",1,true),
            "actual decoder still refuses physical support: "..tostring(s.model.trick_status))
        check(count(f,"submit")==1 and model:status().model_updates==0 and s.model.trick_fallbacks==1,
            "actual unknown support never advances the trick model; the force goes on without a trick")
    end
    cases+=1 do
        local f,model=constructed();check(f.observe().submitted==1,"constructed ground primes exact BFAF")
        for _=1,4 do f.advance();f.observe() end
        check(model:status().model_updates==5,"exact BFAF observes each consecutive sample while queued")
        check(count(f,"submit")==1,"pending force blocks only another submit")
        f.mode="applied";f.successor=f.sample();f.advance();f.observe()
        check(model:status().model_updates==6,"ACK cannot cancel or rewind BFAF model")
        check(count(f,"ack")==1,"original force transaction acknowledged once")
    end
    cases+=1 do
        local f,model=constructed();f.observe();f.clear=true;f.advance();f.observe()
        check(model:status().model_updates==2,"constructed airborne neutral model observed")
        f.pad.buttons.rb=true;f.pad.right_y=-1;f.new_input();f.observe()
        f.pad.buttons.rb=false;f.pad.right_y=0;f.new_input();f.observe()
        f.advance();local s=f.observe()
        check(model:status().model_updates==3,"single actual body progress advances model once")
        check(model:status().model_state.bar_rotating==true,"queued non-hop selection precedes later neutral release")
        check(s.input_queued>=1 and count(f,"submit")==1,"later input stays ordered while force pending")
        f.advance();f.observe()
        check(model:status().model_updates==4,"next real body consumes next native input")
        check(not f.ride:status().stop_requested,"ordered non-hop actions remain structurally valid")
    end
    cases+=1 do
        local monitor=Recovery.new()
        local f,model=constructed({models={alignment=Alignment,recovery=monitor},
            ride_options={alignment={enabled=true,bike_basis="y_up_z_forward_x_left"}}})
        local s=f.observe()
        check(s.submitted==1 and model:status().model_updates==1,"exact full companion graph remains pure before force submit")
        check(s.model.alignment_status=="targets_only","whole private BFAF result reaches target-only alignment")
        check(monitor:status().native_actions==0,"default recovery has no native action")
    end
    return {cases=cases,assertions=assertions}
end
return Tests
