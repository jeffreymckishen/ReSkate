-- One source-only regression: preserve classification/edge acceptance and
-- name the first failed original facet clause in a bounded refusal reason.
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
    local function cast(ray,slope,step)
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
        if slope then
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
    local function cast_plan(rays,slope,step)
        local out={}
        for i,ray in ipairs(rays)do out[i]=cast(ray,slope,step)end
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
    return {cases=1,assertions=n,native_qualified=false}
end
return Tests
