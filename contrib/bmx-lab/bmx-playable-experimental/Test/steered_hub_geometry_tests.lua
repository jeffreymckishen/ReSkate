-- Constructed geometry and actual Ride query plumbing only; no native or
-- landing/support/steering-joint qualification. This fixture is authored UNRUN.
local G=require("./bike_geometry")
local M=require("./force_math")
local Forces=require("./forces")
local Visual=require("./bike_visual")
local Fixtures=require("./ride_runtime_tests")
local Tests={}
local function apply(m,p)
    return {m[1]*p[1]+m[5]*p[2]+m[9]*p[3]+m[13],
        m[2]*p[1]+m[6]*p[2]+m[10]*p[3]+m[14],
        m[3]*p[1]+m[7]*p[2]+m[11]*p[3]+m[15]}
end
local function near(a,b,e)
    for i=1,3 do if math.abs(a[i]-b[i])>e then return false end end
    return true
end
function Tests.run()
    local cases,assertions=0,0
    local function check(value,why) assertions+=1;assert(value,why) end
    local function case(run) cases+=1;run() end
    case(function()
        local axle=G.front_axle_at(G,0)
        check(axle~=G.front_axle and near(axle,G.front_axle,0),"neutral axle is exact and detached")
        axle[1]=123
        check(G.front_axle[1]==0,"query preparation cannot mutate fitted anchors")
        check(G.wheel_radius==Forces.wheel_radius and G.wheelbase==Forces.tuning().wheelbase,
            "rendered and physical nominal dimensions remain identical")
        check(math.abs(G.front_axle[3]-G.rear_axle[3]-G.wheelbase)<1e-12,
            "fitted neutral wheelbase is retained")
        local neutral_only={front_axle={1,2,3}}
        check(near(G.front_axle_at(neutral_only,0),neutral_only.front_axle,0),
            "existing neutral-only geometry snapshots retain their path")
        check(G.front_axle_at(neutral_only,.1)==nil,"nonzero steering requires its actual pivot and axis")
        check(G.front_axle_at(G,0/0)==nil and G.front_axle_at(G,math.huge)==nil
            and G.front_axle_at(G,1.01)==nil,"unknown/out-of-policy steering refuses")
        local zero_axis={front_axle=G.front_axle,steering_pivot=G.steering_pivot,steering_axis={0,0,0}}
        check(G.front_axle_at(zero_axis,.1)==nil,"a zero steering axis does not invent a frame")
    end)
    case(function()
        local root={14,3,-21}
        for _,q in ipairs({{0,0,0,1},{0,.6,0,.8}}) do
            for _,steer in ipairs({0,.4,-.4}) do
                local pose=Visual.neutral();pose.steer=steer
                pose.front_wheel_phase=.73;pose.rear_wheel_phase=-.28
                local matrices=Visual.matrices(root,q,pose)
                local front=G.front_axle_at(G,steer)
                local expected=M.add(root,M.turn(q,front))
                check(near(apply(matrices[4],G.front_axle),expected,1e-11),
                    "front hub equals the real visual's steered hub in the same frame")
                check(near(apply(matrices[3],G.rear_axle),M.add(root,M.turn(q,G.rear_axle)),1e-11),
                    "rear hub stays unchanged by front steering and wheel spin")
            end
        end
        local left,right=G.front_axle_at(G,.4),G.front_axle_at(G,-.4)
        check(left[1]>.015 and right[1]<-.015,"the fitted fork offset is not silently discarded")
        check(math.abs(left[1]+right[1])<1e-12 and math.abs(left[2]-right[2])<1e-12
            and math.abs(left[3]-right[3])<1e-12,"opposite steer is symmetric about the fitted plane")
    end)
    case(function()
        local f=Fixtures.fixture({no_tricks=true})
        local old_sample=f.sample
        function f.sample()
            local row=old_sample()
            row.position=vector.create(4,3,-2);row.rotation={0,.6,0,.8}
            return row
        end
        f.plans={}
        f.on_probe=function(epoch,rays,settings)
            check(epoch==f.read.epoch and #rays==2 and settings.require_contact and settings.exclude_local_actor,
                "actual Ride keeps the same exact epoch, two rays and query guards")
            f.plans[#f.plans+1]=rays
            return {status="available",epoch=epoch,rays={},local_actor_excluded=true,owned_bodies_excluded=true}
        end
        local first=f.observe()
        check(first.submitted==1 and first.presentation_pose.steer==0,"first accepted pose is neutral")
        f.pad.left_x=-1;f.mode="applied";f.advance()
        local accepted=f.observe()
        check(accepted.submitted==2 and accepted.presentation_pose.steer~=0,
            "actual Mapping/Forces publish a fresh accepted steering pose")
        local previous=accepted.presentation_pose
        f.pad.left_x=1;f.advance();f.successor=f.sample()
        f.on_submit=function() return false,"constructed refusal" end
        local refused=f.observe()
        check(refused.stop_requested and refused.presentation_pose==previous,
            "current refused input cannot replace the accepted pose")
        local rays=f.plans[3]
        local p=f.read.position
        local center={p.x,p.y,p.z}
        local front=M.add(center,M.turn(f.read.rotation,M.sub(G.front_axle_at(G,previous.steer),G.com)))
        local rear=M.add(center,M.turn(f.read.rotation,M.sub(G.rear_axle,G.com)))
        local front_native=vector.create(front[1],front[2],front[3])
        local rear_native=vector.create(rear[1],rear[2],rear[3])
        check(rays[1].from==front_native and rays[2].from==rear_native,
            "query starts use the previous accepted hub in the actual fresh body frame")
        local unsteered=M.add(center,M.turn(f.read.rotation,M.sub(G.front_axle,G.com)))
        check(not near(front,unsteered,1e-5),"the regression exercises a real offset, not a neutral-only case")
        local root=M.sub(center,M.turn(f.read.rotation,G.com))
        local matrices=Visual.matrices(root,f.read.rotation,previous)
        check(near(apply(matrices[4],G.front_axle),front,1e-11),
            "query and drawn front hub agree after the same body/source transform")
    end)
    return {cases=cases,assertions=assertions}
end
return Tests