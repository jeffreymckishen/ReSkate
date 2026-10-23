-- Pure policy tests. Loading this module performs no tests or native actions.
local Equipment = require("./equipment")
local tests = {}

function tests.run(reference)
    local assertions, cases, comparisons = 0, 0, 0
    local function check(ok, why) assertions += 1; assert(ok, why) end
    do
        local key = Equipment.toggle()
        check(not key:update(true,true) and not key:update(true,true), "startup-held toggle never fires")
        check(not key:update(false,true) and key:update(true,true), "fresh neutral then press fires once")
        check(not key:update(true,true), "held toggle cannot repeat")
        check(not key:update(false,false) and not key:update(true,true), "focus/menu loss discards arming")
        key:update(false,true); key:reset()
        check(not key:update(true,true), "explicit owner suspension discards arming")
        key:update(false,true)
        check(not key:update(nil,true) and not key:update(true,true), "malformed sample discards arming")
        cases += 1
    end
    do
        local b = Equipment.interaction()
        local trace = {
            {true,true,1,"none"},{true,true,600,"none"},{false,true,601,"none"},
            {true,true,602,"none"},{false,true,800,"tap"},{false,true,801,"none"},
            {true,true,900,"none"},{true,true,1399,"none"},{true,true,1400,"hold"},
            {true,true,3000,"none"},{false,true,3001,"none"},{true,true,3002,"none"},
            {true,false,3100,"none"},{true,true,4000,"none"},{false,true,4001,"none"},
            {true,true,4002,"none"},{false,true,3999,"none"},{false,true,4003,"none"},
        }
        for _, row in trace do check(b:update(row[1],row[2],row[3]) == row[4], "original tap/hold/focus/rollback trace") end
        local last = 9007199254740991
        b:reset(); b:update(false,true,last-1000); b:update(true,true,last-999)
        check(b:update(true,true,last-500) == "none" and b:update(true,true,last-499) == "hold",
            "exact integer timestamp boundary preserves 500ms threshold without addition overflow")
        check(b:update(false,true,last) == "none", "hold release cannot become tap")
        cases += 1
    end
    do
        local q, now = Equipment.quick_switch(), 1
        local function step(north, shoulder, allowed, device, observed, owner)
            local e = q:update(north,shoulder,allowed ~= false,device or 1,observed ~= false,owner or "rider-a",now)
            now += 1; return e
        end
        check(not step(true,true).pressed, "preheld shortcut never switches")
        step(true,true); step(false,false)
        local e = step(true,true)
        check(e.pressed and e.suppress_north and e.capture_north, "fresh simultaneous shortcut requests once")
        e.pressed, e.capture_north = false, false
        for _ = 1,100 do
            e = step(true,true)
            check(not e.pressed and e.suppress_north and e.capture_north, "held shortcut and caller-mutated output cannot repeat or leak")
        end
        e = step(true,false); check(e.capture_north and e.suppress_north, "modifier-first release keeps North claimed")
        e = step(false,false); check(e.capture_north and not e.suppress_north, "release observation keeps capture without creating tap")
        check(not step(false,false).capture_north, "next neutral ends shortcut capture")
        check(not step(false,true,false).capture_north, "lost readiness releases shortcut capture")
        step(false,false)
        e = step(false,true,true,1,false)
        check(e.capture_north and not q:owner_sample_needed(false,true), "modifier reserves next edge without owner poll")
        check(q:owner_sample_needed(true,true), "fresh shortcut requires canonical owner observation")
        check(step(true,true).pressed, "modifier then fresh North requests without delay")
        cases += 1
    end
    do
        local q, ordinary = Equipment.quick_switch(), Equipment.interaction()
        q:update(false,false,true,1,false,nil,100); ordinary:update(false,true,100)
        local e = q:update(true,false,true,1,false,nil,101)
        check(not e.pressed and not e.suppress_north and ordinary:update(true,true,101) == "none", "unmodified North starts ordinary press")
        e = q:update(true,true,true,1,false,nil,601)
        check(not e.pressed and not e.suppress_north and ordinary:update(true,not e.suppress_north,601) == "hold",
            "adding shoulder after North preserves ordinary carry hold")
        check(ordinary:update(false,true,602) == "none", "late-shoulder carry never also taps")
        cases += 1
    end
    do
        -- Composition matches the native prototype: quick suppression gates the
        -- ordinary latch, even when its clock remains monotonic through a fault.
        for failure = 0,6 do for _, hold in {false,true} do
            local q, ordinary = Equipment.quick_switch(), Equipment.interaction()
            local device, input_clock, ordinary_clock, allowed, owner = 1,100,100,true,"rider-a"
            local function step(north, shoulder)
                local need = q:owner_sample_needed(north,shoulder)
                local e = q:update(north,shoulder,allowed,device,need,owner,input_clock)
                local action = ordinary:update(north,allowed and not e.suppress_north,ordinary_clock)
                input_clock += 1; ordinary_clock += 1
                return e, action
            end
            step(false,false)
            if failure == 0 then device = 2 end
            if failure == 1 then device = 2; step(false,true) end
            if failure == 2 then input_clock = 5 end
            if failure == 3 then allowed = false; step(true,true); allowed = true end
            if failure == 4 then owner = nil end
            if failure == 5 then
                check(step(true,true).pressed, "owner-change fixture binds first owner")
                step(false,false); step(false,false); owner = "rider-b"
            end
            if failure == 6 then q:reset() end
            local e, action = step(true,true)
            check(not e.pressed and e.suppress_north and e.capture_north and action == "none", "invalidated chord cannot switch or leak ordinary press")
            if hold then
                input_clock += 600; ordinary_clock += 600
                e, action = step(true,true)
                check(not e.pressed and e.suppress_north and action == "none", "invalidated hold cannot become carry or deferred switch")
                e, action = step(true,false)
                check(e.capture_north and e.suppress_north and action == "none", "modifier-first fault release cannot leak North")
            end
            owner = failure == 5 and "rider-b" or "rider-a"
            e, action = step(false,false)
            check(not e.pressed and e.capture_north and action == "none", "fault release cannot become tap")
            check(not step(false,false).capture_north, "fresh neutral ends fault capture")
            e, action = step(true,false)
            check(not e.suppress_north and action == "none", "fresh ordinary press works after fault")
            local _, tap = step(false,false)
            check(tap == "tap", "fresh ordinary release works after fault")
        end end
        cases += 1
    end
    do
        local q = Equipment.quick_switch()
        q:update(false,false,true,1,false,nil,0)
        check(not q:update(true,true,true,1,false,nil,1).pressed, "missing owner observation never executes")
        check(not q:update(true,true,true,1,true,"rider-a",2).pressed, "later owner observation cannot spend a held old edge")
        for _, bad in {0,-1,.5,4294967296,math.huge,0/0,"1",false} do
            q:reset(); q:update(false,false,true,1,false,nil,10)
            check(not q:update(true,true,true,bad,true,"rider-a",11).pressed, "invalid source identity cannot authorize shortcut")
            check(not q:update(true,true,true,1,true,"rider-a",12).pressed, "bad source cannot retain neutral arming")
        end
        for _, bad in {-1,.5,9007199254740992,math.huge,0/0,"1",false} do
            q:reset(); q:update(false,false,true,1,false,nil,10)
            check(not q:update(true,true,true,1,true,"rider-a",bad).pressed, "invalid wall clock cannot authorize shortcut")
        end
        for _, bad in {"",string.rep("x",129),0,-1,.5,math.huge,0/0,true,false,{}} do
            check(not Equipment.owner_valid(bad), "malformed model owner is unavailable")
        end
        check(not Equipment.owner_valid(nil) and Equipment.owner_valid("rider-a") and Equipment.owner_valid(1), "bounded stable model owners")
        cases += 1
    end
    do
        for bits = 0,31 do
            local a,p,m,k,c = bit32.band(bits,1)~=0,bit32.band(bits,2)~=0,bit32.band(bits,4)~=0,bit32.band(bits,8)~=0,bit32.band(bits,16)~=0
            local expected = "equip_bike"
            if k or c then expected = "nearby_bike" end
            if a then expected = "skateboard" end
            if p or m then expected = "none" end
            check(Equipment.quick_action(a,p,m,k,c) == expected, "all32 equipment-state combinations route requests without native actions")
        end
        check(Equipment.quick_action(nil,false,false,false,false) == "none", "missing state cannot imply equip")
        check(Equipment.quick_action(false,false,false,false,0) == "none", "numeric truthiness cannot imply equip")
        for _, state in {0,99,100,101,102,103,104,200,201,504,math.huge,0/0,"100"} do
            check(Equipment.natural_dismount_state(state) == (state == 100 or state == 103), "only native neutral/crouch permit natural dismount")
        end
        check(Equipment.natural_dismount_selection(100,100) and Equipment.natural_dismount_selection(103,103), "matching observed/committed board state")
        check(not Equipment.natural_dismount_selection(100,103) and not Equipment.natural_dismount_selection(103,100), "mismatched publications cannot authorize dismount")
        cases += 1
    end
    if reference then
        local q, ordinary, toggle
        for _, row in reference do
            if row.reset then q, ordinary, toggle = Equipment.quick_switch(), Equipment.interaction(), Equipment.toggle() end
            if row.quick_reset then q:reset() end
            local observed = q:owner_sample_needed(row.north,row.shoulder)
            check(observed == row.observed, "canonical owner observation request matches retained C++")
            local e = q:update(row.north,row.shoulder,row.allowed,row.device,observed,row.owner,row.clock)
            check(e.pressed == row.pressed, "shortcut press matches retained C++")
            check(e.suppress_north == row.suppress, "ordinary suppression matches retained C++")
            check(e.capture_north == row.capture, "release capture matches retained C++")
            local source_allowed = row.allowed and row.device > 0
            check(ordinary:update(row.north,source_allowed and not e.suppress_north,row.wall) == row.interaction,
                "composed tap/hold matches retained C++")
            check(toggle:update(row.north,source_allowed) == row.toggle, "neutral-rearmed toggle matches retained C++")
            comparisons += 1
        end
        cases += 1
    end
    return {cases=cases, assertions=assertions, comparisons=comparisons, native_actions=0}
end

return tests
