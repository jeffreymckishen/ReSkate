-- Pure formatter examples and bounds; no native score or game evidence.
local Names = require("./trick_names")
local Catalog = require("./score_catalog")
local Tests = {}
local function part(id, start, finish, amount)
    local row = Catalog.get(id)
    return {key=row.key,display=row.display,count=amount or 1,start=start,finish=finish}
end
function Tests.run()
    local cases, assertions = 0, 0
    local function check(ok, message) assertions += 1; assert(ok, message) end
    local function case(body) cases += 1; body() end
    local function named(descriptor, expected)
        check(Names.format(descriptor) == expected, "expected trick name: " .. expected)
    end
    case(function()
        named({}, "Bunny Hop")
        named({parts={part(34,0,.45)}}, "Barspin")
        named({parts={part(44,0,.45)}}, "Barspin")
        named({parts={part(52,0,.55)}}, "Tailwhip")
        named({parts={part(56,0,.55)}}, "Tailwhip")
        named({parts={part(37,0,.18)}}, "X-Up")
        named({parts={part(41,0,.18)}}, "X-Up")
        named({parts={part(34,0,.9,2)}}, "Double Barspin")
        named({parts={part(56,0,1.65,3)}}, "Triple Tailwhip")
        named({parts={part(34,0,1.8,4)}}, "4x Barspin")
    end)
    case(function()
        named({parts={part(37,0,.18),part(34,.3,.75)}}, "X-Up to Barspin")
        named({parts={part(34,0,.45),part(52,.1,.65)}}, "Barspin + Tailwhip")
        named({parts={part(34,0,.45),part(52,.45,1)}}, "Barspin to Tailwhip")
        named({parts={part(34,.2,.2),part(52,.2,.7)}}, "Barspin to Tailwhip")
        named({parts={part(7,0,1),part(34,.1,.3),part(52,.4,.8)}},
            "Superman + Barspin to Tailwhip")
        local a, b = table.freeze(part(52,.5,1)), table.freeze(part(34,0,.45))
        local parts = table.freeze({a,b})
        local descriptor = table.freeze({parts=parts})
        named(descriptor, "Barspin to Tailwhip")
        check(parts[1] == a and parts[2] == b and a.start == .5 and b.finish == .45,
            "sorting and display never mutate caller input")
    end)
    case(function()
        named({spin_half_turns=1}, "180")
        named({spin_half_turns=3,parts={part(52,0,.55)}}, "540 Tailwhip")
        named({spin_half_turns=2,parts={part(34,0,.45)}}, "Truckdriver")
        named({spin_half_turns=4,parts={part(44,0,.9,2)}}, "Double Truckdriver")
        named({spin_half_turns=2,parts={part(34,0,.9,2)}}, "360 Double Barspin")
        named({spin_half_turns=4,parts={part(44,0,.45)}}, "720 Barspin")
        named({spin_half_turns=2,parts={part(34,0,.45),part(52,.1,.65)}}, "Truckdriver + Tailwhip")
        named({spin_half_turns=2,parts={part(33,0,.45)}}, "360 Bus Driver")
    end)
    case(function()
        named({fakie_takeoff=true}, "Fakie Bunny Hop")
        named({fakie_takeoff=true,parts={part(34,0,.45)}}, "Fakie Barspin")
        named({fakie_takeoff=true,spin_half_turns=1}, "Half Cab")
        named({fakie_takeoff=true,spin_half_turns=1,parts={part(52,0,.55)}}, "Half Cab Tailwhip")
        named({fakie_takeoff=true,spin_half_turns=2,parts={part(34,0,.45)}}, "Fakie Truckdriver")
        named({spin_half_turns=1,heading_cos=-1}, "180 to Fakie")
        named({fakie_takeoff=true,spin_half_turns=1,heading_cos=-.01}, "Half Cab to Fakie")
        named({spin_half_turns=1,heading_cos=0}, "180")
        named({spin_half_turns=1,heading_cos=.2}, "180")
    end)
    case(function()
        named({front_flips=1}, "Frontflip")
        named({back_flips=2}, "Double Backflip")
        named({barrel_rolls=3}, "Triple Barrel Roll")
        named({front_flips=4}, "4x Frontflip")
        named({back_flips=1,parts={part(52,0,.55)}}, "Backflip Tailwhip")
        named({spin_half_turns=2,front_flips=1,barrel_rolls=1}, "360 Frontflip Barrel Roll")
    end)
    case(function()
        local parts = {}
        for i = 1, Names.MAX_PARTS do
            parts[i] = {key="long_label",display=string.rep("A",48),count=16,start=i,finish=i+.5}
        end
        local output = Names.format({parts=parts,heading_cos=-1})
        check(#output == Names.MAX_LENGTH and string.sub(output,-3) == "...", "long output has an explicit bounded suffix")
        table.insert(parts, part(34,17,17.45))
        named({parts=parts}, "Trick")
        named({parts={[1]=part(34,0,.45),[3]=part(52,.5,1)}}, "Trick")
        named({parts={label=part(34,0,.45)}}, "Trick")
        named({parts=setmetatable({}, {__index=function() error("must not run") end})}, "Trick")
        check(table.isfrozen(Names), "formatter exports are immutable")
    end)
    case(function()
        named(nil, "Trick")
        named(false, "Trick")
        named("Barspin", "Trick")
        named(setmetatable({}, {__index=function() error("must not run") end}), "Trick")
        for _, key in ipairs({"spin_half_turns","front_flips","back_flips","barrel_rolls"}) do
            for _, value in ipairs({-1,.5,33,math.huge,0/0,"1"}) do named({[key]=value}, "Trick") end
        end
        named({fakie_takeoff=1}, "Trick")
        for _, value in ipairs({-1.01,1.01,math.huge,0/0,"-1"}) do named({heading_cos=value}, "Trick") end
    end)
    case(function()
        local faults = {{"key",""},{"key","barspin_left!"},{"display",""},{"display","bad\nlabel"},
            {"display",string.rep("A",49)},{"count",0},{"count",17},{"count",1.5},
            {"start",-.1},{"start",math.huge},{"start",0/0},{"finish",-.1},{"finish",0/0}}
        for _, fault in ipairs(faults) do
            local row = part(34,0,.45)
            row[fault[1]] = fault[2]
            named({parts={row}}, "Trick")
        end
        named({parts={setmetatable(part(34,0,.45),{})}}, "Trick")
        named({parts={false}}, "Trick")
        named({parts={part(34,.5,.1)}}, "Trick")
        named({parts={{key="barspin",display="Barspin",start=0,finish=.45}}}, "Barspin")
    end)
    case(function()
        local bar = part(34,0,1.4,2)
        local early = table.freeze({start=0,finish=.4})
        local late = table.freeze({start=1,finish=1.4})
        -- Deliberately reversed input order: intervals are copied, never sorted in place.
        bar.intervals = table.freeze({late,early})
        table.freeze(bar)
        named({parts={bar,part(52,.5,.9)}}, "Double Barspin to Tailwhip")
        named({parts={bar,part(52,1.1,1.6)}}, "Double Barspin + Tailwhip")
        named({parts={bar,part(52,.4,1)}}, "Double Barspin to Tailwhip")
        check(bar.intervals[1] == late and bar.intervals[2] == early,
            "real rotation intervals remain unchanged")
        local invalid = {
            {}, {[1]={start=0,finish=.1},[3]={start=.2,finish=.45}},
            {{start=-.1,finish=.45}}, {{start=0,finish=.46}},
            {{start=.1,finish=.45}}, {{start=0,finish=.4}},
            {{start=.4,finish=.1}}, {{start=0/0,finish=.45}},
            {{start=0,finish=math.huge}}, {false},
            setmetatable({{start=0,finish=.45}},{}),
            {setmetatable({start=0,finish=.45},{})},
        }
        for _, intervals in ipairs(invalid) do
            local row = part(34,0,.45)
            row.intervals = intervals
            named({parts={row}}, "Trick")
        end
        local too_many = part(34,0,.45)
        too_many.intervals = {}
        for i = 1, Names.MAX_PARTS+1 do too_many.intervals[i]={start=0,finish=.45} end
        named({parts={too_many}}, "Trick")
    end)
    return {cases=cases,assertions=assertions,native_actions=0,game_evidence=false}
end
return table.freeze(Tests)
