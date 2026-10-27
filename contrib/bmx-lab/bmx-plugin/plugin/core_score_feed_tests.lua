-- Cold Core score-feed reads only; no qualified Ride or native effect is exercised.
local Core=require("./bike_runtime_core")
local Tests={}
function Tests.run()
    local cases,assertions=0,0
    local function check(v,why) assertions+=1;assert(v,why) end
    local function case(run) cases+=1;run() end
    case(function()
        local calls=0
        local services=setmetatable({}, {__index=function() calls+=1;error("SDK lookup during empty feed",0) end})
        local core=Core.new(services)
        local empty=core:score_feed()
        check(empty.generation==0 and empty.n==0 and #empty.rows==0 and not empty.gap,
            "Core without a Ride reports the reserved empty-feed generation")
        check(core:score_feed(0).gap==false and core:score_feed(1).gap==true and core:score_feed(-1).gap==true,
            "only an empty cursor can match a Core that has no Ride")
        pcall(function() empty.rows[1]={n=1,control="ended"};empty.n=99 end)
        local next_read=core:score_feed()
        check(next_read.n==0 and #next_read.rows==0,"mutating an empty packet cannot create cached Core events")
        check(calls==0,"empty feed reads resolve no SDK function and acquire no gameplay authority")
    end)
    case(function()
        local calls=0
        local services=setmetatable({}, {__index=function() calls+=1;error("public Core touched SDK",0) end})
        local core=Core.new(services)
        local accepted=core:request_mount(0)
        check(accepted==false,"score-feed plumbing does not open the production mount gate")
        core:request_stop("nothing mounted");core:unload()
        local out=core:score_feed()
        check(out.generation==0 and out.n==0 and #out.rows==0 and not out.gap,
            "stopping or unloading a cold Core invents neither a Ride nor a ride-ended row")
        check(calls==0,"public refusal and cold unload leave the empty score feed free of SDK side effects")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return Tests