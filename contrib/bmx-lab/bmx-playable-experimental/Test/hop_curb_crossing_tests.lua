-- A NEW constructed hop scenario. It does not replace the failed unassisted curb cases.
-- Actual Mapping/Stage/Forces and current edge modules; no SDK or native receipt is fabricated.
local Stage=require("./force_stage")
local Forces=require("./forces")
local Contact=require("./contact_runtime")
local InFlight=require("./ride_inflight")
local Mapping=require("./ride_input_mapping")
local World=require("./sim_world")
local M=require("./force_math")
local G=require("./bike_geometry")
local Tests={}
function Tests.run()
    local n=0
    local function check(value,why)n+=1;assert(value,why)end
    local h,tuning=Forces.native_seconds,Forces.tuning()
    local speed,height,steps=2,.12,300
    local body,wheels=World.place(World.terrain.flat(),{speed=speed})
    local radius=G.wheel_radius
    for i=1,2 do
        check(math.abs(wheels[i].angular_speed-speed/wheels[i].radius)<1e-10,
            "initial wheel"..i.." is rolling at v/R rather than a stationary rotor")
    end
    local edge=World.hubs(body)[1][3]+.5
    -- Same exact finite lower/top/wall domains as the existing coherent curb fixture.
    -- Only actual nearest segment intersections reach Contact. No native collision impulses.
    local casts=0
    local function vec(v)return {v.x,v.y,v.z}end
    local function cast(ray)
        casts+=1
        local from,to=vec(ray.from),vec(ray.to)
        local delta=M.sub(to,from)
        local nearest,point,normal
        local function face(axis,value,facet_normal,inside)
            if math.abs(delta[axis])<1e-12 or M.dot(delta,facet_normal)>=0 then return end
            local fraction=(value-from[axis])/delta[axis]
            if fraction<0 or fraction>1 then return end
            local p=M.add(from,M.mul(delta,fraction))
            if inside(p) and (not nearest or fraction<nearest) then nearest,point,normal=fraction,p,facet_normal end
        end
        if from[2]<0 or from[3]>=edge and from[2]<height then return {status="unavailable"} end
        face(2,0,{0,1,0},function(p)return p[3]<edge end)
        face(2,height,{0,1,0},function(p)return p[3]>=edge end)
        face(3,edge,{0,0,-1},function(p)return p[2]>=0 and p[2]<=height end)
        if not nearest then return {status="clear"} end
        return {status="hit",position=point,normal=normal,fraction=nearest,normal_available=true,
            surface_velocity={0,0,0},surface_velocity_available=true,motion="measured"}
    end
    local function cast_plan(plan)
        local rows={}
        for i,ray in ipairs(plan)do rows[i]=cast(ray)end
        return rows
    end
    local wall_ray={from=vector.create(0,.06,edge-.1),to=vector.create(0,.06,edge+.1)}
    local wall=cast(wall_ray)
    -- vector.create rounds each endpoint independently. Use the segment actually requested,
    -- not an ideal symmetric pair around the double-precision edge coordinate.
    local wall_delta=M.sub(vec(wall_ray.to),vec(wall_ray.from))
    local wall_fraction=(edge-wall_ray.from.z)/(wall_ray.to.z-wall_ray.from.z)
    local wall_point=M.add(vec(wall_ray.from),M.mul(wall_delta,wall_fraction))
    check(wall.status=="hit" and wall_fraction>=0 and wall_fraction<=1
        and math.abs(wall.fraction-wall_fraction)<1e-8 and M.length(M.sub(wall.position,wall_point))<1e-8
        and math.abs(wall.position[3]-edge)<1e-8 and wall.position[2]>=0 and wall.position[2]<=height
        and wall.normal[1]==0 and wall.normal[2]==0 and wall.normal[3]==-1,
        "the actual float segment measures its analytic intersection on the finite 120 mm curb wall")
    check(cast({from=vector.create(0,.2,edge-.1),to=vector.create(0,.2,edge+.1)}).status=="clear",
        "the finite wall cannot supply a hit above its top")
    local function query(measured)
        local frame={body=measured}
        local plan,centers,context=Contact.wheel_plan(frame,G,tuning.gravity,.75)
        check(plan and #plan==6,"current wheel plan remains six real segments")
        local rows=cast_plan(plan)
        local wall_plan,candidates=Contact.edge_plan(frame,rows,centers,context,G)
        check(wall_plan~=nil,"actual edge plan refused: "..tostring(candidates))
        local wall_rows=cast_plan(wall_plan)
        local witness_plan,features=Contact.edge_witness_plan(frame,wall_rows,candidates,G)
        check(witness_plan~=nil,"actual facet witness plan refused: "..tostring(features))
        local witness_rows=cast_plan(witness_plan)
        check(#wall_plan<=2 and #witness_plan<=6 and #plan+#wall_plan+#witness_plan<=14,
            "coherent contacts stay within the unchanged ray/cast budget")
        local samples,why=Contact.wheel_samples(frame,rows,centers,context,G,features,witness_rows)
        check(samples~=nil,"actual contact decode refused: "..tostring(why))
        for i,sample in ipairs(samples)do
            if sample.contact.status=="hit" then
                local p,normal=sample.contact.point,sample.contact.normal
                check(normal[2]>.999 and math.abs(p[2]-(p[3]>=edge and height or 0))<1e-8,
                    "primary support belongs to an actually intersected finite floor/top face")
            end
            if sample.edge then
                local f=sample.edge.edge_feature
                check(f.topology_known==false and math.abs(f.top_point[2]-height)<1e-8
                    and math.abs(f.wall_point[3]-edge)<1e-8 and f.top_normal[2]>.999 and f.wall_normal[3]<-.999,
                    "secondary support keeps measured facets and unknown arbitrary topology")
            end
        end
        return samples
    end
    local function grounded(measured,samples)
        for _,sample in ipairs(samples)do
            if Forces.eligible_support(measured,sample,.005,.10)
                or sample.edge and Forces.eligible_support(measured,sample.edge,.005,.10) then return true end
        end
        return false
    end
    local function all_clear(samples)
        for _,sample in ipairs(samples)do
            if sample.contact.status~="clear" or sample.edge and sample.edge.contact.status~="clear" then return false end
        end
        return true
    end
    -- Independent conservative hub/radius distance to the authored solid union.
    -- This is an assertion oracle only: it never supplies support or forces.
    local function clearance(hub)
        local signed
        if hub[3]>=edge and hub[2]<=height then signed=-math.min(hub[3]-edge,height-hub[2])
        else signed=math.sqrt(math.max(edge-hub[3],0)^2+math.max(hub[2]-height,0)^2) end
        return math.min(hub[2],signed)-radius
    end
    local mapper,stage=Mapping.new(),Stage.new()
    local lease=newproxy() -- Constructed source identity, never a native lease.
    local function input_frame(serial,press)
        local buttons={}
        for _,key in ipairs({"up","down","left","right","start","back","left_stick","right_stick","lb","rb","a","b","x","y"})do buttons[key]=false end
        buttons.right_stick=press
        return {input_ok=true,lease_handle=lease,generation=1,sample={user=0,sequence="1",source_epoch="2",context_generation="3",
            observation_serial=tostring(serial),observed_ms=tostring(1000+math.floor((serial-1)*h*1000+.5)),packet=serial,
            pad={left_x=0,left_y=0,right_x=0,right_y=0,left_trigger=0,right_trigger=0,playstation=false,buttons=buttons}}}
    end
    local initial=query(body)
    check(grounded(body,initial),"hop starts on measured supported lower floor")
    local prime=mapper:observe(input_frame(1,false),{grounded=true,focused=true,menu_open=false,rotation_reserved=false})
    check(prime.valid and prime.active,"real mapper is primed by an actual neutral observation")
    local previous,visible_hop
    local hop_commands,hop_applications,air_steps,landing_steps=0,0,0,0
    local saw_air,saw_clear_air,saw_landing=false,false,false
    local crossed={false,false}
    local deepest,peak_force,peak_torque=0,0,0
    for step=1,steps do
        if visible_hop then
            check(mapper:retire_hop(visible_hop,"accepted"),"local model retires hop only after its delayed impulse is integrated")
            visible_hop=nil
        end
        local samples=query(body)
        local supported=grounded(body,samples)
        if not supported then saw_air=true;air_steps+=1
        elseif saw_air then saw_landing=true;landing_steps+=1 end
        local observed=mapper:observe(input_frame(step+1,step>=4 and step<=11),
            {grounded=supported,focused=true,menu_open=false,rotation_reserved=false})
        check(observed.valid and observed.active,"real selected-input mapping refused at step"..step..":"..tostring(observed.issue))
        local mapped=mapper:controls({physics_epoch=newproxy(),h=h,grounded=supported,rotation_reserved=false})
        check(mapped.valid and mapped.submission_allowed,"real controls refused at step"..step)
        local commands={}
        if previous then
            local command={age=1,force=previous.force,torque=previous.torque}
            if previous.hop_applied then command.impulse=previous.hop_impulse;command.impulse_id=previous.hop_event_id end
            commands[1]=command
        end
        local forecast,folded=InFlight.fold(h,tuning.gravity,commands,body,samples)
        check(forecast~=nil,"unchanged accepted-command forecast refused at step"..step..":"..tostring(folded))
        check(stage:admit_measured(body),"original measured stage envelope refused at step"..step)
        local model,candidate=stage:preview(h,forecast,wheels,folded,mapped.force_controls)
        check(model.valid,"unchanged hop/curb force packet refused at step"..step..":"..tostring(model.issue))
        check(model.contact_scale==1 and M.length(model.force)<=6000 and M.length(model.torque)<=2000,
            "no clamping or authored force/torque cap refusal is hidden")
        if all_clear(samples) and all_clear(folded) then
            saw_clear_air=true
            check(not model.grounded and model.balance_support_mask==0 and model.normal_load[1]==0 and model.normal_load[2]==0
                and model.edge_normal_impulse[1]==0 and model.edge_normal_impulse[2]==0,
                "clear measured/folded contacts never fabricate support, load or edge impulse")
        end
        stage:_adopt(candidate)
        if model.hop_applied then
            hop_commands+=1
            check(mapped.hop and model.hop_event_id==mapped.hop.id and math.abs(M.length(model.hop_impulse)-body.mass*tuning.hop_delta_speed)<1e-6,
                "only the real mapped R3 event generates the original full-strength hop impulse")
            check(mapper:claim_hop(model.hop_event_id),"local accepted model command owns its exact mapped hop")
        end
        local old_hubs=World.hubs(body)
        local applied=previous or {force={0,0,0},torque={0,0,0},hop_impulse={0,0,0}}
        body=World.integrate(body,applied,tuning.gravity,h)
        if applied.hop_applied then hop_applications+=1;visible_hop=applied.hop_event_id end
        previous=model;wheels=model.wheels
        peak_force=math.max(peak_force,M.length(model.force));peak_torque=math.max(peak_torque,M.length(model.torque))
        local hubs=World.hubs(body)
        for i,hub in ipairs(hubs)do
            deepest=math.min(deepest,clearance(hub))
            check(deepest>=-.10,"true finite-solid wheel penetration exceeds the unchanged 100 mm bound")
            if not crossed[i] and old_hubs[i][3]<edge and hub[3]>=edge then
                check(hub[2]-radius>=height-.005,"hub"..i.." crosses the actual curb with its wheel bottom above the top")
                crossed[i]=true
            end
        end
        local up=M.turn(M.normalized(body.orientation),{0,1,0})
        local forward=M.turn(M.normalized(body.orientation),{0,0,1})
        check(math.deg(math.acos(math.clamp(up[2],-1,1)))<55 and math.abs(M.dot(body.angular_velocity,forward))<8
            and math.abs(body.linear_velocity[2])<6,"original tilt/roll/vertical guards remain active")
    end
    local hubs=World.hubs(body)
    check(crossed[1] and crossed[2] and hubs[1][3]>edge+radius and hubs[2][3]>edge+radius,
        "both physical hubs fully clear the measured120 mm edge")
    check(saw_air and saw_clear_air and saw_landing and air_steps>0 and landing_steps>0,
        "actual finite-face observations show supported to air to landing without fabricated support")
    local mapped=mapper:status()
    check(hop_commands==1 and hop_applications==1 and mapped.hop_counter==1 and mapped.pending_hop==nil,
        "one held R3 gesture produces exactly one generated and one delayed integrated hop")
    check(body.center_of_mass[2]>.98 and deepest>=-.10,"bike lands on the120 mm deck with bounded penetration")
    return {cases=1,assertions=n,steps=steps,initial_speed=speed,curb_height=height,hop_commands=hop_commands,
        hop_applications=hop_applications,air_steps=air_steps,landing_steps=landing_steps,deepest=deepest,
        peak_force=peak_force,peak_torque=peak_torque,casts=casts,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
