local F=require("./forces")
local M=require("./force_math")
local Tire=require("./tire")
local Pump=require("./pump")
local Brake=require("./brake")
local tests={}
function tests.run(reference,projections)
    local cases,assertions=0,0
    local function check(value,why) assertions+=1 assert(value,why) end
    local function near(a,b,error) return math.abs(a-b)<=(error or 1e-7) end
    local function vector_near(a,b,error) return M.length(M.sub(a,b))<=(error or 1e-7) end
    local function fixture(speed)
        local b,w=F.proposed_body(),F.proposed_wheels() b.center_of_mass={0,.9,-.05}
        b.linear_velocity={0,0,speed or 0} for _,wheel in w do wheel.angular_speed=(speed or 0)/wheel.radius end
        local s={} for i=1,2 do s[i]={contact={status="hit",point={0,0,i==1 and .525 or -.525},normal={0,1,0},forward={0,0,1},surface_velocity={0,0,0}},separation=0,verified_plane=false,balance_normal_available=false} end
        return b,w,s
    end
    local function air(samples) local out=M.copy(samples) for _,s in out do s.contact.status="clear" end return out end
    local function energy(b,w)
        local out=.5*b.mass*M.dot(b.linear_velocity,b.linear_velocity)
        for i=1,3 do out+=.5*b.inertia_body[i]*b.angular_velocity[i]^2 end
        for _,wheel in w do out+=.5*wheel.inertia*wheel.angular_speed^2 end return out
    end
    local h=F.native_seconds
    cases+=1 do
        local b,w,s=fixture() local r=F.new():step(h,b,w,s)
        check(r.valid and r.grounded,"actual two-wheel support")
        check(near(r.force[2],106*9.8,.002),"one native gravity compensation from solved contacts")
        check(near(r.normal_load[1]+r.normal_load[2],106*9.8,.002),"actual normal impulses carry weight")
        check(r.normal_load[2]>r.normal_load[1],"rearward measured COM loads rear")
        check(vector_near(r.torque,{0,0,0},.00001),"rest has no residual steering torque")
        b.mass/=2 for i=1,3 do b.inertia_body[i]/=2 end r=F.new():step(h,b,w,s)
        check(r.valid and near(r.force[2],b.mass*9.8,.002),"measured mass replaces proposed defaults")
    end
    cases+=1 do
        local b,w,s=fixture() b.linear_velocity={1,2,3} b.angular_velocity={.2,-.4,.7}
        local r=F.new():step(h,b,w,air(s))
        check(r.valid and not r.grounded,"known-clear flight")
        check(vector_near(r.force,{0,0,0}) and vector_near(r.torque,{0,0,0}),"cold air invents no gravity/upright/damping")
        check(vector_near(b.angular_velocity,{.2,-.4,.7}),"input measured body immutable")
    end
    cases+=1 do
        local b,w=fixture() local clear={{contact={status="clear"}},{contact={status="clear"}}}
        local r=F.new():step(h,b,w,clear,{hop_strength=1,hop_event_id=1,pump_operator_available=true,ground_pump=-1})
        check(r.valid and not r.grounded and not r.hop_applied,"honest clear needs no terrain fields and grants no hop")
        check(not F.eligible_support(b,clear[1]),"honest clear cannot qualify support directly")
        check(vector_near(r.force,{0,0,0}) and vector_near(r.torque,{0,0,0}),"honest clear invents no support or pump force")
        for i=1,2 do
            check(r.normal_impulse[i]==0 and r.longitudinal_impulse[i]==0 and r.lateral_impulse[i]==0,"clear has no tire impulse "..i)
            check(clear[i].separation==nil and clear[i].contact.point==nil and clear[i].contact.normal==nil and
                clear[i].contact.forward==nil and clear[i].contact.surface_velocity==nil,"clear input never receives fabricated geometry "..i)
        end
    end
    cases+=1 do
        local b,w=fixture() b.orientation={0,0,math.sin(.3),math.cos(.3)}
        local clear={{contact={status="clear"}},{contact={status="clear"}}}
        local r=F.new():step(h,b,w,clear,{pedal=1})
        local axle=M.turn(b.orientation,{1,0,0})
        local rotor=(r.wheels[2].angular_speed-w[2].angular_speed)*w[2].inertia
        check(r.valid and r.wheels[2].angular_speed>w[2].angular_speed,"airborne pedal uses mechanical axle without terrain")
        check(vector_near(r.linear_impulse,{0,0,0}) and r.normal_impulse[1]==0 and r.normal_impulse[2]==0,"airborne pedal creates no tire force")
        check(vector_near(M.add(r.angular_impulse,M.mul(axle,rotor)),{0,0,0}),"airborne drive preserves opposite chassis/rotor angular impulse")
    end
    cases+=1 do
        local b,w=fixture(3) b.orientation={0,0,math.sin(.3),math.cos(.3)}
        local clear={{contact={status="clear"}},{contact={status="clear"}}}
        local r=F.new():step(h,b,w,clear,{brake=1})
        local axle=M.turn(b.orientation,{1,0,0}) local rotor=0
        for i=1,2 do rotor+=(r.wheels[i].angular_speed-w[i].angular_speed)*w[i].inertia end
        check(r.valid and not r.grounded and r.wheels[1].angular_speed<w[1].angular_speed and r.wheels[2].angular_speed<w[2].angular_speed,"airborne brake slows both mechanical rotors")
        check(vector_near(r.linear_impulse,{0,0,0}) and r.normal_impulse[1]==0 and r.normal_impulse[2]==0 and
            r.longitudinal_impulse[1]==0 and r.longitudinal_impulse[2]==0 and r.lateral_impulse[1]==0 and r.lateral_impulse[2]==0,"airborne braking creates no tire impulses")
        check(vector_near(M.add(r.angular_impulse,M.mul(axle,rotor)),{0,0,0}),"airborne brake reaction conserves chassis/rotor angular impulse")
    end
    cases+=1 do
        -- A tilted steerer must not add free-wheel camber to the retained model.
        -- All axes below are authored body/joint policy, never clear-ray geometry.
        local b,w=fixture(3) local bank,tilt=.2,-.15
        b.orientation={math.cos(bank/2)*math.sin(tilt/2),math.sin(bank/2)*math.sin(tilt/2),
            math.sin(bank/2)*math.cos(tilt/2),math.cos(bank/2)*math.cos(tilt/2)}
        b.linear_velocity=M.turn(b.orientation,{0,0,3}) b.inertia_body={11,37,5}
        local clear={{contact={status="clear"}},{contact={status="clear"}}}
        local tuning={rear_brake_torque=0} local controls={brake=1,steer=-.4}
        local r=F.new(tuning):step(h,b,w,clear,controls)
        local up=M.turn(b.orientation,{0,1,0}) local forward=M.turn(b.orientation,{0,0,1})
        local steerer=M.unit(M.turn(b.orientation,{0,.9601196050643921,-.2795896530151367}))
        local wheel=M.basis(up,M.around(forward,steerer,r.front_steer_angle))
        local cambered=M.unit(M.around(M.turn(b.orientation,{1,0,0}),steerer,r.front_steer_angle))
        check(r.valid and not r.grounded and wheel~=nil,"inclined-steerer free front brake remains a valid zero-camber model")
        check(math.abs(M.dot(cambered,up))>.01,"regression separates physical camber from the selected zero-camber approximation")
        check(near(M.dot(r.angular_impulse,up),0,1e-8),"free front axle stays within body-derived zero-camber plane")
        check(vector_near(r.angular_impulse,M.mul(wheel.lateral,60*h)),"front brake chassis impulse follows projected body-derived axle")
        local rotor=(r.wheels[1].angular_speed-w[1].angular_speed)*w[1].inertia
        check(near(rotor,-60*h),"isolated front brake transfers the bounded rotor impulse")
        check(vector_near(M.add(r.angular_impulse,M.mul(wheel.lateral,rotor)),{0,0,0}),"front brake conserves opposite chassis and rotor angular impulse")
        check(near(r.wheels[2].angular_speed,w[2].angular_speed),"disabled rear brake leaves rear spin unchanged")
        check(vector_near(r.linear_impulse,{0,0,0}),"derived wheel frame invents no clear tire force")
        local poisoned=M.copy(clear)
        for _,s in poisoned do
            s.separation=0/0 s.contact.normal={0/0,0,0} s.contact.forward=false
            s.contact.point="not terrain" s.contact.surface_velocity={math.huge,0,0}
        end
        local ignored=F.new(tuning):step(h,b,w,poisoned,controls)
        check(ignored.valid and not ignored.grounded,"poisoned clear terrain cannot invalidate body-derived axle policy")
        check(vector_near(r.force,ignored.force) and vector_near(r.torque,ignored.torque),"absent and poisoned clear geometry produce the same force and torque")
        for i=1,2 do
            check(near(r.wheels[i].angular_speed,ignored.wheels[i].angular_speed),"clear geometry cannot change zero-camber rotor response "..i)
            check(r.normal_impulse[i]==0 and r.longitudinal_impulse[i]==0 and r.lateral_impulse[i]==0,"zero-camber frame never becomes native contact support "..i)
            check(clear[i].contact.normal==nil and clear[i].contact.forward==nil and clear[i].contact.point==nil,"body-derived frame is not written into clear terrain "..i)
        end
    end
    cases+=1 do
        for clear_index=1,2 do
            local b,w,s=fixture(3) s[clear_index]={contact={status="clear"}}
            local r=F.new():step(h,b,w,s,{steer=.25})
            check(r.valid and r.grounded,"one honest clear wheel permits the other measured support "..clear_index)
            check(r.normal_impulse[clear_index]==0 and r.longitudinal_impulse[clear_index]==0 and r.lateral_impulse[clear_index]==0,"missing wheel geometry cannot receive contact impulse "..clear_index)
            check(r.normal_load[3-clear_index]>0,"remaining measured wheel supplies support "..clear_index)
        end
    end
    cases+=1 do
        for _,field in {"point","normal","forward","surface_velocity"} do
            local b,w,s=fixture() s[1].contact[field]=nil
            check(not F.new():step(h,b,w,s).valid,"hit still requires measured "..field)
        end
        local b,w,s=fixture() s[1].separation=nil
        check(not F.new():step(h,b,w,s).valid,"hit still requires finite measured separation")
        b,w,s=fixture() s[1].contact.surface_velocity={0,0/0,0}
        check(not F.new():step(h,b,w,s).valid,"nonfinite hit closing-motion input is never treated as clear")
        b,w,s=fixture() s[1].contact.surface_velocity={0,50.00001,0}
        check(not F.new():step(h,b,w,s).valid,"hit surface motion bounds remain intact")
    end
    cases+=1 do
        local b,w=fixture() local clear={{contact={status="clear"}},{contact={status="clear"}}}
        local malformed=M.copy(clear)
        for _,s in malformed do
            s.contact.point="unused" s.contact.normal={0/0,0,0} s.contact.forward=false
            s.contact.surface_velocity={math.huge,0,0} s.separation=0/0 s.verified_plane=true
            s.balance_normal_available=true s.balance_normal={0/0,0,0}
        end
        local expected=F.new():step(h,b,w,clear,{steer=.4,pedal=.2,brake=.3})
        local actual=F.new():step(h,b,w,malformed,{steer=.4,pedal=.2,brake=.3})
        check(expected.valid and actual.valid and not actual.grounded,"clear's unavailable terrain fields are not consumed")
        check(vector_near(actual.force,expected.force) and vector_near(actual.torque,expected.torque),"clear terrain garbage cannot change mechanical response")
        for i=1,2 do check(near(actual.wheels[i].angular_speed,expected.wheels[i].angular_speed),"clear rotor response depends on bike mechanics only "..i) end
    end
    cases+=1 do
        local b,w,s=fixture() local controller=F.new()
        check(controller:step(h,b,w,s,{recovery_step_verified=true}).grounded,"seed actual support before honest clear")
        local clear={{contact={status="clear"}},{contact={status="clear"}}}
        local r=controller:step(h,b,w,clear,{recovery_step_verified=true,hop_strength=1,hop_event_id=1})
        check(r.valid and not r.grounded and not r.hop_applied and r.balance_support_mask==0,"honest clear cannot continue stale support or hop")
        check(controller:consumed_hop_event_id()==1,"airborne event remains consumed once")
        check(not controller:step(h,b,w,s,{hop_strength=1,hop_event_id=1}).hop_applied,"clear-to-hit cannot replay consumed hop")
        clear[1].contact.status="unavailable"
        local unavailable=controller:step(h,b,w,clear)
        check(not unavailable.valid and unavailable.issue=="unavailable_contact","unavailable still refuses instead of becoming clear")
        clear[1].contact.status="other"
        check(not controller:step(h,b,w,clear).valid,"unknown contact still refuses")
        clear[1].contact.status="clear"
        check(not controller:step(h*2,b,w,clear).valid,"clear does not relax native fixed-step clock")
    end
    cases+=1 do
        local b,w,s=fixture()
        check(F.eligible_support(b,s[1]),"current support")
        s[1].separation=.005 check(F.eligible_support(b,s[1]),"strict support boundary inclusive")
        s[1].separation=.0050001 check(not F.eligible_support(b,s[1]),"skin is not grounded")
        s[1].separation=0 b.linear_velocity[2]=.050001 check(not F.eligible_support(b,s[1]),"departing wheel not supported")
        b.linear_velocity[2]=0 s[1].contact.status="unavailable"
        local r=F.new():step(h,b,w,s) check(not r.valid and r.issue=="unavailable_contact","unavailable never becomes clear")
        s[1].contact.status="hit" s[1].separation=-.10001
        r=F.new():step(h,b,w,s) check(not r.valid and r.issue=="penetration_limit","penetration bound")
    end
    cases+=1 do
        local b,w,s=fixture() local controller=F.new()
        local r,candidate=controller:preview(h,b,w,s,{hop_strength=1,hop_event_id=1})
        check(r.valid and r.hop_applied and near(r.hop_impulse[2],477),"full existing hop delta speed")
        check(controller:consumed_hop_event_id()==0 and candidate:consumed_hop_event_id()==1,"preview consumes only candidate state")
        check(vector_near(r.hop_impulse,{0,477,0}) and M.length(r.force)<.0001,"hop separate from native force")
        r=controller:step(h,b,w,s,{hop_strength=.25,hop_event_id=1})
        check(r.hop_applied and near(r.hop_impulse[2],119.25),"weak hop strength preserved")
        r=controller:step(h,b,w,s,{hop_strength=1,hop_event_id=1}) check(r.valid and not r.hop_applied,"held event not replayed")
        r=controller:step(h,b,w,air(s),{hop_strength=1,hop_event_id=2}) check(r.valid and not r.hop_applied,"airborne hop rejected")
        r=controller:step(h,b,w,s,{hop_strength=1,hop_event_id=2}) check(r.valid and not r.hop_applied,"airborne ID consumed before landing")
    end
    cases+=1 do
        local b,w,s=fixture(5)
        local right=F.new():step(h,b,w,s,{steer=1}) local left=F.new():step(h,b,w,s,{steer=-1})
        check(right.valid and left.valid and right.front_steer_angle<0 and right.force[1]<0 and right.torque[2]<0,"right stick steer physical yaw sign")
        check(left.front_steer_angle>0 and left.force[1]>0 and left.torque[2]>0,"left physical yaw sign")
        check(near(right.force[1],-left.force[1]) and near(right.torque[2],-left.torque[2]),"reflection symmetry")
        local boost={3,0,7} b.linear_velocity=M.add(b.linear_velocity,boost) for _,sample in s do sample.contact.surface_velocity=boost end
        local moving=F.new():step(h,b,w,s,{steer=1})
        check(moving.valid and vector_near(moving.force,right.force) and vector_near(moving.torque,right.torque),"moving platform covariance")
    end
    cases+=1 do
        for _,speed in {-12,-8,-2,0,2,8,12} do for _,sign in {-1,1} do
            local b,w,s=fixture(speed) local r=F.new():step(h,b,w,s,{steer=sign})
            check(r.valid and r.grounded,"supported speed/direction turn")
            check(math.abs(r.turning_lean_angle)<=.47+1e-10,"caster-projected turn matches lean envelope")
            check(M.length(r.force)<=40000 and M.length(r.torque)<=4000,"turn norm budgets")
        end end
    end
    cases+=1 do
        local b,w,s=fixture(5) local controller=F.new() check(controller:step(h,b,w,s).valid,"seed mechanical steering")
        local previous=0
        for _=1,12 do
            local r=controller:step(h,b,w,s,{steer=1})
            check(r.valid and r.front_steer_angle<=previous and math.abs(r.front_steer_angle)<=math.abs(r.requested_front_steer_angle),"shared steering actuator approaches target")
            check(math.abs(r.front_steer_angle-previous)<.03,"supported slew unchanged") previous=r.front_steer_angle
        end
    end
    cases+=1 do
        local b,w,s=fixture(5) local initial=energy(b,w) local r=F.new():step(h,b,w,s,{brake=1})
        check(r.valid and r.force[3]<0,"brake/contact joint block slows body")
        check(r.wheels[1].angular_speed<w[1].angular_speed and r.wheels[2].angular_speed<w[2].angular_speed,"both coupled rotors slow")
        check(r.brake_impulse[1]<0 and r.brake_impulse[2]<0,"signed brake impulse retained")
        local predicted=M.copy(b) predicted.linear_velocity=M.add(M.add(b.linear_velocity,{0,-9.8*h,0}),M.mul(M.add(r.linear_impulse,r.hop_impulse),1/b.mass))
        for i=1,3 do predicted.angular_velocity[i]+=r.angular_impulse[i]/b.inertia_body[i] end
        check(energy(predicted,r.wheels)<=initial+1e-5,"brake/contact response cannot add kinetic energy")
        local clear=air(s) b.angular_velocity={.2,0,0}
        r=F.new():step(h,b,w,clear,{brake=1,recovery_step_verified=true}) check(r.valid and r.air_rotation_reserved,"air braking reserves physical pitch momentum")
    end
    cases+=1 do
        local b,w,s=fixture() local manual=F.new():step(h,b,w,s,{manual=1}) local nose=F.new():step(h,b,w,s,{nose_manual=1})
        check(manual.valid and nose.valid and manual.balance_torque[1]<0 and nose.balance_torque[1]>0,"manual/nose balance request signs")
        manual=F.new():step(h,b,w,air(s),{manual=1}) nose=F.new():step(h,b,w,air(s),{nose_manual=1})
        check(manual.valid and near(manual.air_control_torque[1],-160) and near(nose.air_control_torque[1],160),"air pitch is actual torque not pose repair")
    end
    cases+=1 do
        local b,w,s=fixture() local controller=F.new()
        check(controller:step(h,b,w,s,{recovery_step_verified=true}).valid,"strict loaded support establishes flight epoch")
        check(controller:step(h,b,w,s,{recovery_step_verified=true,hop_strength=1,hop_event_id=1}).hop_applied,"neutral hop launch")
        b.angular_velocity={1,.2,-.3} local r=controller:step(h,b,w,air(s),{recovery_step_verified=true})
        check(r.valid and r.neutral_air_damping_active and not r.air_rotation_reserved,"neutral qualified hop permits passive damping")
        check(M.dot(b.angular_velocity,r.air_damping_torque)<0,"neutral damper removes rotational work")
        r=controller:step(h,b,w,air(s),{recovery_step_verified=true,steer=1,air_yaw=1})
        check(r.valid and r.air_rotation_reserved and near(r.air_control_torque[2],-200) and not r.neutral_air_damping_active,"held turn reserves player torque")
        r=controller:step(h,b,w,air(s),{recovery_step_verified=true})
        check(r.air_rotation_reserved and not r.neutral_air_damping_active and vector_near(r.torque,{0,0,0}),"released intended rotation remains reserved")
    end
    cases+=1 do
        local b,w,s=fixture() local controller=F.new()
        check(controller:step(h,b,w,s,{recovery_step_verified=true}).valid,"clock test grounded seed")
        b.angular_velocity={1,0,0} local r=controller:step(h,b,w,air(s),{recovery_step_verified=false})
        check(r.valid and not r.neutral_air_damping_active,"unproven successor cannot acquire neutral-air damping")
        r=controller:step(h*2,b,w,s) check(not r.valid and r.issue=="unsupported_step","clock gap not integrated as larger step")
        r=controller:step(h,b,w,air(s),{recovery_step_verified=true}) check(r.valid and not r.neutral_air_damping_active,"failed clock clears support history")
        r=controller:step(h,b,w,s,{pedal=0/0}) check(not r.valid,"NaN control rejected")
    end
    cases+=1 do
        local b,w,s=fixture() for _,sample in s do sample.separation=.01 end
        local r=F.new():step(h,b,w,s,{hop_strength=1,hop_event_id=1})
        check(r.valid and not r.grounded and not r.hop_applied,"positive query skin cannot grant early hop")
        r=F.new():step(h,b,w,s,{contact_compliance_available=true}) check(not r.valid and r.issue=="unsupported_policy","private compliance explicit refusal")
        r=F.new():step(h,b,w,s,nil,{{selected=true}}) check(not r.valid and r.issue=="unsupported_policy","private speculative branch explicit refusal")
    end
    cases+=1 do
        local pump=Pump.new() local sample={enabled=true,operator_available=true,supported=true,inhibited=false,input=0,manual=0,nose_manual=0,world_upward_speed=0,pedal=0}
        check(pump:step(h,sample).status=="neutral","pump requires released LS first") sample.input=-1
        local integral=0 for _=1,40 do local r=pump:step(h,sample) check(r.valid,"pump bounded sample") integral+=r.down_acceleration*h end
        check(near(integral,11*.45,1e-9),"pump finite window preserves force integral")
        sample.input=0 pump:step(h,sample) sample.input=-1 sample.manual=1 check(pump:step(h,sample).down_acceleration==0,"manual suppresses pump")
    end
    cases+=1 do
        local b,w,s=fixture() local initial=M.copy(b) local wheel=M.copy(w[1])
        local r,next_body,next_wheel=Tire.solve(h,b,w[1],{status="unavailable"})
        check(not r.valid and next_body==b and next_wheel==w[1],"unavailable tire has transactional identity")
        check(vector_near(b.linear_velocity,initial.linear_velocity) and w[1].angular_speed==wheel.angular_speed,"failed tire never mutates inputs")
        local clear=M.copy(s[1].contact) clear.status="clear"
        r,next_body,next_wheel=Tire.solve(0,b,w[1],clear,{drive_torque=75,brake_torque=60})
        check(r.valid and next_body==b and next_wheel==w[1],"paused solve applies no impulse")
    end
    cases+=1 do
        local b,w,s=fixture() local controller=F.new()
        for _,sample in s do sample.separation=-.02 sample.verified_plane=true sample.balance_normal_available=true sample.balance_normal={0,1,0} end
        local seed=controller:step(h,b,w,s,{recovery_step_verified=true})
        check(seed.valid and seed.grounded and seed.normal_load[1]>0 and seed.normal_load[2]>0,"loaded verified recovery seed")
        local independent=controller:clone() local next_samples=M.copy(s)
        -- Reusing a caller's old observation buffer cannot change retained history.
        s[1].contact.surface_velocity[1]=7 s[2].contact.surface_velocity[1]=7
        check(controller.normals[1].surface_velocity[1]==0 and controller.normals[2].surface_velocity[1]==0,"retained platform history owns its arrays")
        b.linear_velocity[2]=seed.recovery_velocity[1]
        for _,sample in next_samples do sample.separation=-.01999 end
        local observed=controller:step(h,b,w,next_samples,{recovery_step_verified=true})
        local expected=independent:step(h,b,w,next_samples,{recovery_step_verified=true})
        check(observed.valid and not observed.grounded and observed.balance_continuation_mask==3,"fresh loaded recovery retains finite continuation")
        check(expected.balance_continuation_mask==observed.balance_continuation_mask and vector_near(expected.force,observed.force) and
            vector_near(expected.torque,observed.torque),"caller buffer mutation cannot alter recovery admission or force")
    end
    local comparisons=0
    if reference then
        cases+=1
        for index,item in reference do
            local controller=F.new(item.tuning)
            local r=controller:step(item.h,item.body,item.wheels,item.samples,item.controls)
            local expected=item.result
            check(r.valid==expected.valid and r.grounded==expected.grounded and r.hop_applied==expected.hop_applied,
                "C++ kernel qualification parity "..index)
            check(r.issue==expected.issue and controller:consumed_hop_event_id()==expected.consumed_hop,"C++ rejection/event history parity "..index)
            for _,key in {"force","torque","hop_impulse","normal_load","normal_impulse","longitudinal_impulse","lateral_impulse","brake_impulse"} do
                for i,value in expected[key] do
                    check(near(r[key][i],value,1e-6*math.max(1,math.abs(value))),"C++ kernel "..index.." "..key.."/"..i)
                end
            end
            for _,key in {"front_steer_angle","requested_front_steer_angle","turning_lean_angle","contact_scale"} do
                check(near(r[key],expected[key],1e-8),"C++ kernel scalar "..index.." "..key)
            end
            if r.valid then for i=1,2 do check(near(r.wheels[i].angular_speed,expected.spin[i],1e-7),"C++ rotor parity "..index) end end
            comparisons+=1
        end
    end
    local projection_count=0
    if projections then
        cases+=1
        for index,item in projections do
            local impulse=Brake.constrained(item.k,item.g,item.limits)
            check((impulse~=nil)==item.valid,"C++ projection rejection parity "..index)
            if impulse then for i=1,3 do check(near(impulse[i],item.impulse[i],1e-9*math.max(1,math.abs(item.impulse[i]))),"C++ projection impulse parity "..index.."/"..i) end end
            local k={} for i=1,3 do for j=1,3 do k[(i-1)*3+j]=item.k[i][j] end end
            local x,y,z=Brake.project(k,item.g[1],item.g[2],item.g[3],item.limits[1],item.limits[2],item.limits[3],true)
            check((x~=nil)==item.valid,"private accelerated projection rejection parity "..index)
            if x~=nil then local fast={x,y,z} for i=1,3 do check(near(fast[i],item.impulse[i],1e-9*math.max(1,math.abs(item.impulse[i]))),"private projection impulse parity "..index.."/"..i) end end
            projection_count+=1
        end
        local id={{1,0,0},{0,1,0},{0,0,1}}
        check(Brake.constrained(id,{0/0,0,0},{1,1,1})==nil,"nonfinite projection velocity rejected")
        check(Brake.constrained({{math.huge,0,0},{0,1,0},{0,0,1}},{0,0,0},{1,1,1})==nil,"nonfinite matrix rejected")
        check(Brake.constrained(id,{0,0,0},{1,-1,1})==nil,"negative projection limit rejected")
        local flat={1,0,0,0,1,0,0,0,1}
        local x,y,z,h1,h2,h3=Brake.project(flat,3,4,0,2,2,0,true)
        check(near(x,-1.2,1e-9) and near(y,-1.6,1e-9) and near(z,0,1e-9),"known circle optimum seeds measured roots")
        check(h1>0 and h1<1 and h2>0 and h2<1 and h3>0 and h3<1,"successful project returns three measured normalized roots")
        x,y,z=Brake.project(flat,6,8,0,1,1,0,true,h1,h2,h3)
        check(near(x,-.6,1e-9) and near(y,-.8,1e-9) and near(z,0,1e-9),"warm roots reclassified after velocity and limits change")
        x,y,z=Brake.project(flat,6,8,0,1,1,0,true,0/0,1,math.huge)
        check(near(x,-.6,1e-9) and near(y,-.8,1e-9) and near(z,0,1e-9),"NaN endpoint and infinite hints fall back safely")
        x,y,z=Brake.project(flat,6,8,0,1,1,0,true,0,-1,2)
        check(near(x,-.6,1e-9) and near(y,-.8,1e-9) and near(z,0,1e-9),"noninterior hints cannot bypass classification")
        for argument=1,6 do for _,bad in {{},{"1"},{false},{0/0},{math.huge}} do
            local args={0,0,0,1,1,1} args[argument]=bad[1]
            check(Brake.project(flat,args[1],args[2],args[3],args[4],args[5],args[6],true)==nil,
                "projection arguments reject nonnumbers and nonfinite values without coercion")
        end end
    end
    return {cases=cases,assertions=assertions,comparisons=comparisons,projections=projection_count,native_actions=0}
end
return tests
