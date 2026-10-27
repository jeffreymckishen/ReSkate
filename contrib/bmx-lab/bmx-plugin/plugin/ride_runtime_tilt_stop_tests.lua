-- Ride's tilt stop: a measured body tipped more than 15 deg from world up, or
-- rolling faster than 1 rad/s about its own forward axis, stops Ride on that
-- sample, before any query or command. Constructed boundaries only; the runner
-- stages the real Ride with only its private literal enabled.
local Fixtures=require("./ride_runtime_tests")
local Tests={}
local function count(f,name) local n=0 for _,c in ipairs(f.calls) do if c==name then n+=1 end end return n end
-- A unit quaternion turning by angle about the unit axis.
local function about(axis,degrees)
    local half=math.rad(degrees)/2
    local s=math.sin(half)
    return {axis[1]*s,axis[2]*s,axis[3]*s,math.cos(half)}
end
-- One accepted upright step, then a body at serial+1 with the given rotation
-- and spin. Returns the fixture and that step's status.
local function tipped(rotation,spin)
    local f=Fixtures.fixture({no_tricks=true})
    f.observe()
    -- Applied and awaiting its successor: the next step may submit again.
    f.mode="applied"
    f.advance()
    local raw=f.sample()
    raw.rotation=rotation or raw.rotation
    if spin then raw.angular_velocity=vector.create(spin[1],spin[2],spin[3]) end
    local probes,submits=count(f,"probe"),count(f,"submit")
    local s=f.observe(nil,raw)
    return f,s,count(f,"probe")-probes,count(f,"submit")-submits
end

function Tests.run()
    local cases,assertions=0,0
    local function check(ok,why) assertions+=1;assert(ok,why) end
    local function case(_,run) cases+=1;run() end

    for _,spec in ipairs({{"a roll",{0,0,1}},{"a nose-up pitch",{1,0,0}},{"a lean about a diagonal",{.6,0,.8}}}) do
        case(spec[1].." under 15 deg rides on",function()
            local _,s,probes,submits=tipped(about(spec[2],14.9))
            check(not s.stop_requested and probes==1 and submits==1,spec[1].." of 14.9 deg is not a stop: "..tostring(s.issue))
        end)
        case(spec[1].." past 15 deg stops before any query or command",function()
            local f,s,probes,submits=tipped(about(spec[2],15.2))
            check(s.stop_requested and s.issue=="measured tilt 15.2 deg over the 15 deg Ride stop","the named stop: "..tostring(s.issue))
            check(probes==0 and submits==0,"no contact batch and no command from the tipped sample")
            check(s.observed_steps==1 and s.model_steps==1,"the tipped sample is consumed but never modelled")
            -- The command already admitted keeps its receipt duty.
            f.mode="rejected";local drained=f.ride:drain()
            check(not drained.force_pending and drained.acknowledged==1,"the earlier command still drains")
        end)
    end
    case("the first sample is checked too",function()
        local f=Fixtures.fixture({no_tricks=true})
        local raw=f.sample();raw.rotation=about({0,0,1},40)
        local s=f.observe(nil,raw)
        check(s.stop_requested and s.issue=="measured tilt 40.0 deg over the 15 deg Ride stop" and count(f,"probe")==0,
            "a body already down never rides: "..tostring(s.issue))
    end)
    case("an upside-down body stops",function()
        local _,s=tipped(about({0,0,1},180))
        check(s.stop_requested and s.issue=="measured tilt 180.0 deg over the 15 deg Ride stop",tostring(s.issue))
    end)
    case("a roll faster than 1 rad/s stops before any query or command",function()
        local _,s,probes,submits=tipped(nil,{0,0,1.05})
        check(s.stop_requested and s.issue=="measured roll rate 1.05 rad/s over the 1 rad/s Ride stop","the named stop: "..tostring(s.issue))
        check(probes==0 and submits==0,"no contact batch and no command")
        local _,back=tipped(nil,{0,0,-1.2})
        check(back.stop_requested and back.issue=="measured roll rate 1.20 rad/s over the 1 rad/s Ride stop","either way: "..tostring(back.issue))
    end)
    case("a roll under 1 rad/s rides on",function()
        local _,s,probes,submits=tipped(about({0,0,1},5),{0,0,.95})
        check(not s.stop_requested and probes==1 and submits==1,"0.95 rad/s while leaning 5 deg: "..tostring(s.issue))
    end)
    case("yaw and pitch rates are not roll",function()
        local _,yaw=tipped(nil,{0,3,0})
        check(not yaw.stop_requested,"3 rad/s of yaw, a hard turn: "..tostring(yaw.issue))
        local _,pitch=tipped(nil,{2,0,0})
        check(not pitch.stop_requested,"2 rad/s of pitch about the bike's lateral axis: "..tostring(pitch.issue))
    end)
    case("roll is about the bike's own forward axis",function()
        -- Heading +X: world X is now the bike's forward axis, and world Z its lateral one.
        local heading=about({0,1,0},90)
        local _,rolled=tipped(heading,{1.2,0,0})
        check(rolled.stop_requested and rolled.issue=="measured roll rate 1.20 rad/s over the 1 rad/s Ride stop",
            "spin about world X rolls a bike heading +X: "..tostring(rolled.issue))
        local _,pitched=tipped(heading,{0,0,1.2})
        check(not pitched.stop_requested,"spin about world Z only pitches it: "..tostring(pitched.issue))
    end)
    case("a duplicate of a tipped sample cannot restart the ride",function()
        local f,s=tipped(about({0,0,1},20))
        check(s.stop_requested,"stopped")
        local again=f.observe()
        check(again.stop_requested and again.issue==s.issue and count(f,"submit")==1,"the first cause stays, no command")
    end)
    return {cases=cases,assertions=assertions}
end
return table.freeze(Tests)
