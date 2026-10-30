-- One source-only regression: a complete static nearest floor hit retains
-- central contacts, while actual walls and unsupported facts keep their guards.
-- Constructed exact nearest segments only; no SDK, game or native evidence.
local Contact=require("./contact_runtime")
local M=require("./force_math")
local G=require("./bike_geometry")
local Tests={}
function Tests.run()
    local n=0
    local function check(ok,why)n+=1;assert(ok,why)end
    local body={mass=G.mass,inertia_body=M.copy(G.inertia),center_of_mass={0,G.com[2],G.com[3]-G.front_axle[3]-.20},
        orientation={0,0,0,1},linear_velocity={0,0,0},angular_velocity={0,0,0}}
    local frame={body=body}
    local plan,centers,context=Contact.wheel_plan(frame,G,{0,-9.81,0},.75)
    check(plan and #plan==6,"the actual wheel plan retains six nearest vertical segments")
    local function cast(ray,slope,step,road)
        local a,b=ray.from,ray.to
        local from={a.x,a.y,a.z}
        local delta={b.x-a.x,b.y-a.y,b.z-a.z}
        local best
        local function offer(t,normal,inside)
            if t<0 or t>1 or not inside or M.dot(delta,normal)>=0 then return end
            if not best or t<best.fraction then
                best={status="hit",position=M.add(from,M.mul(delta,t)),normal=normal,fraction=t,
                    normal_available=true,surface_velocity_available=true,surface_velocity={0,0,0},motion="measured"}
            end
        end
        if road then
            local den=delta[2]-road.slope*delta[3]
            if den<0 then
                local normal=M.unit({0,1,-road.slope})
                local t=(road.slope*from[3]-road.drop-from[2])/den
                offer(t,normal,from[3]+t*delta[3]<road.join)
                t=(road.slope*from[3]-from[2])/den
                offer(t,normal,from[3]+t*delta[3]>=road.join)
            end
            if delta[3]>0 then
                local t=(road.join-from[3])/delta[3]
                local y=from[2]+t*delta[2]
                local top=road.slope*road.join
                offer(t,{0,0,-1},y>=top-road.drop and y<=top)
            end
        elseif slope then
            local t=(slope*from[3]-from[2])/(delta[2]-slope*delta[3])
            offer(t,M.unit({0,1,-slope}),true)
        else
            if delta[2]<0 then
                local t=-from[2]/delta[2]
                offer(t,{0,1,0},from[3]+t*delta[3]<0)
                t=(step-from[2])/delta[2]
                offer(t,{0,1,0},from[3]+t*delta[3]>=0)
            end
            if delta[3]>0 then
                local t=-from[3]/delta[3]
                local y=from[2]+t*delta[2]
                offer(t,{0,0,-1},y>=0 and y<=step)
            end
        end
        return best or {status="clear"}
    end
    local function cast_plan(rays,slope,step,road)
        local out={}
        for i,ray in ipairs(rays)do out[i]=cast(ray,slope,step,road)end
        return out
    end
    -- A 10% grade changes gravity height by about53mm across this tyre.
    -- The old height-only classifier generated a wall query on this plane.
    local inclined=cast_plan(plan,.10)
    check(math.abs(inclined[2].position[2]-inclined[3].position[2])>.015,
        "the common plane exceeds the old15mm height-change trigger")
    local no_wall,no_candidates=Contact.edge_plan(frame,inclined,centers,context,G)
    check(no_wall and #no_wall==0 and #no_candidates==0,"all measured coplanar inclined hits generate no edge candidate")
    local planar=Contact.wheel_samples(frame,inclined,centers,context,G,{}, {})
    check(planar and planar[1].contact.status=="hit" and planar[2].contact.status=="hit"
        and planar[1].edge==nil and planar[2].edge==nil,"current central inclined-plane contacts remain measured and unchanged")
    local unknown=M.copy(inclined);unknown[2]={status="unavailable"}
    check(Contact.edge_plan(frame,unknown,centers,context,G)==nil,"unknown nearest rows never fall back through plane classification")
    -- The same real query chain must still discover and validate a finite
    -- 120mm top+wall. No real step is suppressed as an inclined road.
    local step=cast_plan(plan,nil,.12)
    local wall_plan,candidates=Contact.edge_plan(frame,step,centers,context,G)
    check(wall_plan and #wall_plan==1 and #candidates==1,"a genuine120mm discontinuity retains its measured wall phase")
    local walls=cast_plan(wall_plan,nil,.12)
    check(walls[1].status=="hit" and walls[1].normal[3]==-1,"the finite wall is actually intersected")
    local witness_plan,features=Contact.edge_witness_plan(frame,walls,candidates,G)
    check(witness_plan and #witness_plan==3 and #features==1,"a real step retains all three local witness rays")
    local samples=Contact.wheel_samples(frame,step,centers,context,G,features,cast_plan(witness_plan,nil,.12))
    check(samples and samples[1].edge and samples[1].edge.kind=="edge"
        and samples[1].edge.edge_feature.topology_known==false,"four query/projection phases retain the coherent optional edge")
    -- This unit wall passes plane_pair (d=.8), then fails wall_up before
    -- wall_outside. It was refused by the original combined boolean guard.
    local forged_walls=M.copy(walls);forged_walls[1].normal=M.unit({0,.5,-1})
    local refused,reason=Contact.edge_witness_plan(frame,forged_walls,candidates,G)
    check(refused==nil and type(reason)=="string" and #reason<=200
        and string.match(reason,"^edge facets:([%w_]+) ")=="wall_up"
        and string.find(reason,"nd=0.44721 up=0.44721",1,true)~=nil,
        "the same unsupported candidate refuses with the exact first failed clause and bounded measured numbers")
    -- A shallow inclined road has a real finite5mm seam behind the front
    -- hub. Three vertical hits are noncoplanar by5mm, but the requested
    -- horizontal segment passes above that short wall and first enters the
    -- measured top-floor facet. It supplies no vertical edge observation.
    local road={slope=.0377,join=-.4,drop=.005}
    local floor=cast_plan(plan,nil,nil,road)
    local floor_plan,floor_candidates=Contact.edge_plan(frame,floor,centers,context,G)
    check(floor_plan and #floor_plan==1 and #floor_candidates==1,
        "a real small seam plus grade still reaches the nearest optional facet query")
    local floor_hits=cast_plan(floor_plan,nil,nil,road)
    check(floor_hits[1].status=="hit" and M.dot(floor_hits[1].normal,floor_candidates[1].top.normal)>.999
        and math.abs(M.dot(M.sub(floor_hits[1].position,floor_candidates[1].top.position),floor_hits[1].normal))<1e-8,
        "the exact nearest segment measures the same bounded top-floor plane rather than its vertical seam")
    local floor_witnesses,floor_features=Contact.edge_witness_plan(frame,floor_hits,floor_candidates,G)
    check(floor_witnesses and #floor_witnesses==0 and #floor_features==0,
        "a fully measured static floor continuation generates no synthetic edge or witnesses")
    local retained=Contact.wheel_samples(frame,floor,centers,context,G,floor_features,{})
    for i=1,2 do
        local actual=floor[(i-1)*3+1]
        check(retained and retained[i].edge==nil and retained[i].contact.status=="hit"
            and M.length(M.sub(retained[i].contact.point,actual.position))<1e-8
            and M.dot(retained[i].contact.normal,actual.normal)>1-1e-8,
            "floor classification keeps each original measured central contact")
    end
    for _,fault in ipairs({"off_plane","moving_top","moving_wall","moving_lower","unknown","off_segment","nonunit"})do
        local facts=M.copy(floor_candidates)
        local hits=M.copy(floor_hits)
        if fault=="off_plane" then hits[1].position[2]+=.01
        elseif fault=="moving_top" then facts[1].top.surface_velocity[1]=.01
        elseif fault=="moving_wall" then hits[1].surface_velocity[1]=.01
        elseif fault=="moving_lower" then facts[1].lower.surface_velocity[1]=.01
        elseif fault=="unknown" then hits[1]={status="unavailable"}
        elseif fault=="off_segment" then hits[1].position[1]+=.01
        else hits[1].normal={0,2,0} end
        local rejected,why=Contact.edge_witness_plan(frame,hits,facts,G)
        check(rejected==nil and type(why)=="string" and #why<=200
            and (fault~="off_plane" or string.find(why,"pt=",1,true)~=nil),
            "unsupported floor evidence never falls back and keeps bounded missing-plane diagnostics: "..fault)
    end
    return {cases=1,assertions=n,native_qualified=false}
end
return Tests
