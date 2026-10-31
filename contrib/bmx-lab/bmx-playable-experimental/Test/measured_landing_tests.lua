-- Constructed per-read body/ray/receipt records only, not native qualification.
-- The producer, rather than this fixture, computes every landing-quality field.
local Landing=require("./measured_landing")
local Score=require("./score_runtime")
local Forces=require("./forces")
local G=require("./bike_geometry")
local M=require("./force_math")
local Tests={}
local H=Forces.native_seconds
local function fixture()
    local owner,lease=newproxy(),newproxy()
    local f={producer=Landing.new(),score=Score.new()}
    function f:at(n,height,steer)
        steer=steer or 0 -- Fixture choice only; producer has no default.
        local epoch=newproxy()
        local y=G.com[2]-math.min(G.front_axle[2],G.rear_axle[2])+G.wheel_radius+(height or 0)
        local body={mass=106,inertia_body={26,32,10},center_of_mass={0,y,2*n*H},orientation={0,0,0,1},
            linear_velocity={0,0,2},angular_velocity={0,0,0}}
        local sample={epoch=epoch,serial=tostring(100+n),time=10+n*H,seconds=H,mass=106,
            inertia={x=26,y=32,z=10},position={x=0,y=y,z=body.center_of_mass[3]},
            velocity={x=0,y=0,z=2},angular_velocity={x=0,y=0,z=0},rotation={0,0,0,1}}
        local source={lease_handle=lease,generation=1,user=0,sequence="7",source_epoch="8",context_generation="9",
            observation_serial=tostring(500+n),observed_ms=tostring(1000+n),packet=n}
        local frame={valid=true,fresh=true,body_handle=owner,physics_epoch=epoch,serial=sample.serial,time=sample.time,
            seconds=H,sample=sample,body=body,source=source,
            owner={body_handle=owner,lease_handle=lease},gates={focused=true,menu_open=false}}
        local contact={samples={},decoded={valid=true,status="available",binding={body_handle=owner,physics_epoch=epoch,lease_handle=lease},
            frame={serial=frame.serial,time=frame.time,seconds=H,source=source},rays={},
            query={epoch_matches=true,measurements_complete=true,owned_bodies_excluded=true,budget_exhausted=false,
                actor_lane="identity",local_actor_excluded=true}},grounded=false}
        for i,axle in ipairs({G.front_axle_at(G,steer),G.rear_axle})do
            local center=M.add(body.center_of_mass,M.sub(axle,G.com))
            local point={center[1],0,center[3]}
            contact.samples[i]={contact={status="hit",point=point,normal={0,1,0},forward={0,0,1},surface_velocity={0,0,0}},
                separation=center[2]-G.wheel_radius,wheel_center=center,wheel_radius=G.wheel_radius,
                verified_plane=false,balance_normal_available=false}
            contact.decoded.rays[i]={status="hit",position=point,normal={0,1,0},surface_velocity={0,0,0},
                normal_available=true,surface_velocity_available=true,motion="measured"}
            contact.grounded=contact.grounded or Forces.eligible_support(body,contact.samples[i],.005,.10)
        end
        contact.support={known=true,grounded_known=true,grounded=contact.grounded,epoch=epoch,
            provenance="measured_rays_authored_wheel_geometry",native_collision_contact=false,
            actor_lane="identity",actor_tripwire="not_required_identity_lane",landing_quality_available=false}
        -- A different per-read token is expected. Serial/time and all physical
        -- values, not token equality, correlate this observation to the frame.
        local successor=table.clone(sample);successor.epoch=newproxy()
        local request={sequence=tostring(1000+n-2),serial=tostring(100+n-2),time=10+(n-2)*H,seconds=H}
        local row={sequence=request.sequence,requested_serial=request.serial,produced_serial=tostring(100+n-1),
            outcome="applied",force_attempted=true,torque_attempted=true,retained=false,quarantined=false,
            cleanup_disposition="none",successor=successor}
        return frame,contact,{authored_steer=steer,applied_successors={{request=request,receipt=row}}}
    end
    function f:catch(frame)
        return {valid=true,scope="predictive_accepted_ray_barspin_only",realized=false,completion_qualified=false,
            serial=frame.serial,accepted_sequence="1002",authored_events={{kind="authored_channel_catch",
                scope="mod_authored_accepted_step",channel="barspin",direction=1,catch_phase="regrip_complete",
                authored_completion=true,body_serial=frame.serial,accepted_sequence="1002",
                source_observation_serial=frame.source.observation_serial,prediction_only=true,
                native_application="unobserved",native_application_observed=false,native_catch=false,native_landing=false,
                landing_quality_available=false,completion_qualified=false}}}
    end
    return f
end
function Tests.run()
    local n,cases=0,0
    local function check(ok,why)n+=1;assert(ok,why)end
    cases+=1 do
        local f=fixture()
        local last_frame,last_contact,last_proofs,qualified
        for i=0,7 do
            local frame,contact,proofs=f:at(i,(i==1 or i==2) and .2 or 0,.4)
            if i==4 then check(f.score:observe(frame,proofs.applied_successors[1].receipt),"exact observed command successor confirms catch's underlying command") end
            local result=f.producer:step(frame,contact,proofs)
            if i==2 then
                check(result.accepting_catches,"only current fully tracked air admits authored catches")
                check(f.score:queue(frame,f:catch(frame)),"queue one authored catch during measured air")
            end
            if i<7 then check(not result.landed,"air/recontact/pending settle cannot credit early at sample"..i) end
            if result.landed then
                check(result.phase=="landed" and result.quality.available and result.quality.qualified,"producer concludes only after bounded measured settle")
                check(f.score:land(frame,result.quality),"the producer's actual computed record satisfies the frozen ledger contract")
                qualified=result.quality
            end
            check(contact.support.landing_quality_available==false,"producer never relabels the original ray adapter's quality flag")
            last_frame,last_contact,last_proofs=frame,contact,proofs
        end
        check(qualified and qualified.settled_samples==5 and math.abs(qualified.settled_seconds-4*H)<1e-6,
            "five distinct supported observations provide four actual intervals over60ms")
        check(qualified.body_up_alignment==1 and qualified.support_up_alignment==1 and qualified.heading_cos==1
            and qualified.closing_normal_speed==0 and qualified.native_landing==false,"quality derives measured body/normal/travel values")
        check(f.score:view().banked_total==300 and f.score:view().landed_combos==1,"one authored local credit, never native score")
        check(not f.producer:step(last_frame,last_contact,last_proofs).landed,"duplicate body cannot emit a second landing")
        check(f.score:view().banked_total==300,"no duplicate or time-only credit")
    end
    cases+=1 do
        local f=fixture()
        local saw_unavailable=false
        for i=0,8 do
            local frame,contact,proofs=f:at(i,(i>=1 and i<=3) and .2 or 0)
            if i==3 then proofs={authored_steer=0,applied_successors={}} end
            local result=f.producer:step(frame,contact,proofs)
            if i==2 then
                check(result.accepting_catches and f.score:queue(frame,f:catch(frame)),"tracked air queues a pending edge before observation loss")
            end
            if i>=3 then check(not result.accepting_catches,"failed air and recontact cannot admit a later catch") end
            if result.landed then
                check(result.quality.available==false,"missing applied successor cannot be replaced by prediction or later proof")
                f.score:land(frame,result.quality);saw_unavailable=true
            end
            if i==4 then check(not f.score:observe(frame,proofs.applied_successors[1].receipt),"late observed command cannot resurrect lost air") end
        end
        check(saw_unavailable and f.score:view().banked_total==0 and not f.score:view().active,
            "incomplete air is lost and later stable contact cannot resurrect it")
    end
    cases+=1 do
        local f=fixture()
        local frame,contact,proofs=f:at(0,0);f.producer:step(frame,contact,proofs)
        frame,contact,proofs=f:at(1,.2)
        proofs.applied_successors[1].receipt.successor.velocity={x=1,y=0,z=2}
        local changed=f.producer:step(frame,contact,proofs)
        check(changed.landed and changed.quality.available==false and changed.issue=="application_successor_changed",
            "applied flags and matching serial cannot hide a different measured body")
        check(f.producer:cancel("recovery"),"actual owner recovery permanently cancels producer")
        frame,contact,proofs=f:at(2,0)
        local stopped=f.producer:step(frame,contact,proofs)
        check(stopped.phase=="stopped" and not stopped.landed,"cancelled owner never credits a later contact")
    end
    cases+=1 do
        local f=fixture()
        local frame,contact,proofs=f:at(0,0,.4)
        proofs.authored_steer=nil
        local missing=f.producer:step(frame,contact,proofs)
        check(missing.landed and not missing.quality.available and missing.issue=="authored_probe_geometry_unavailable",
            "missing current accepted steer cannot silently become neutral geometry")
        frame,contact,proofs=f:at(1,0,.4)
        proofs.authored_steer=0
        local wrong=f.producer:step(frame,contact,proofs)
        check(wrong.landed and not wrong.quality.available and wrong.issue=="measured_geometry_mismatch",
            "a straight-center assertion cannot qualify a current steered-center query")
    end
    return {cases=cases,assertions=n,native_actions=0,game_evidence=false,calibration="C0_UNRUN"}
end
return table.freeze(Tests)