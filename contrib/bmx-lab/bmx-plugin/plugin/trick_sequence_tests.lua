-- Pure event bookkeeping over authored observations, not native trick proof.
-- Keep these new cases separate from the Host-pinned trick_tests suite.
local Tricks = require("./tricks")
local catalog = require("./catalog")
local Tests = {}
function Tests.run()
    local assertions, cases = 0, 0
    local function check(ok, why) assertions += 1; assert(ok, why) end
    local function near(a, b) return math.abs(a - b) < 1e-8 end
    local function scenario(run) cases += 1; run() end
    local function fixture(settings)
        local r = {model = Tricks.new(settings), input = Tricks.input({enabled = true, owner = "detail-fixture", device = 0,
            bar_neutral = true, rear_neutral = true})}
        function r:tick() return self.model:update(.01, self.input) end
        function r:wait(n) for _ = 1, n do self:tick() end end
        function r:air() self.input.grounded = false; return self:tick() end
        function r:land() self.input.grounded = true; return self:tick() end
        function r:bar(dir)
            self.input.barspin, self.input.bar_neutral = dir or "left", false
            self:tick(); self.input.barspin, self.input.bar_neutral = "none", true
        end
        function r:move(id)
            self.input.movement, self.input.rear_neutral = id, false
            self:tick(); self.input.movement = catalog.none
        end
        r:tick(); return r
    end
    scenario(function()
        local r = fixture(); check(r:air().took_off, "one observed takeoff")
        r.input.barspin, r.input.tailwhip = "left", "right"
        r.input.bar_neutral, r.input.rear_neutral = false, false
        local live = r:tick()
        r.input.barspin, r.input.tailwhip = "none", "none"
        r.input.bar_neutral, r.input.rear_neutral = true, true
        r:wait(62)
        local s, e = r.model:state(), r:land()
        check(live.sequence == nil and s.sequence == nil and s.overflow == nil, "no sequence copy in live events or state")
        check(e.combo_landed and e.barspins == 1 and e.tailwhips == 1 and #e.sequence == 2, "caught parts accompany existing totals")
        local b, t = e.sequence[1], e.sequence[2]
        check(b.kind == "bar" and b.id == 34 and b.dir == -1 and t.kind == "tail" and t.id == 52 and t.dir == 1,
            "channel identity preserves direction")
        check(near(b.start, .01) and near(t.start, b.start) and near(b.finish - b.start, .45)
            and near(t.finish - t.start, .55) and b.hold == 0 and t.hold == 0, "rotation intervals exclude catch blend")
        check(e.landing == nil and not e.overflow and not e.fakie_takeoff and near(e.air_seconds, .63), "unknown quality stays absent")
        e.sequence[1].id = 77
        check(r:tick().sequence == nil and r.model:state().sequence == nil, "landing log is one-shot and detached")
        r:air(); r:wait(30); local next_air = r:land()
        check(#next_air.sequence == 0 and not next_air.overflow, "next flight clears prior parts")
    end)
    scenario(function()
        local r = fixture(); r:air()
        r.input.tailwhip, r.input.rear_neutral = "left", false; r:tick()
        r.input.tailwhip, r.input.rear_neutral = "none", true
        r:bar("right"); r:wait(62)
        local e = r:land()
        check(e.sequence[1].kind == "tail" and e.sequence[2].kind == "bar", "start order survives opposite catch order")
        check(e.sequence[1].start < e.sequence[2].start and e.sequence[1].finish > e.sequence[2].finish,
            "overlap uses rotation duration instead of catch order")
    end)
    scenario(function()
        local r = fixture(); r:air(); r:move(24)
        r:wait(18); r:wait(30)
        check(r.model:state().movement_holding, "pose reached plateau before release")
        r.input.rear_neutral = true; r:tick(); r:wait(12)
        local e = r:land(); local row = e.sequence[1]
        check(e.combo_landed and e.movements == 1 and #e.sequence == 1, "recovered pose becomes one completed part")
        check(row.kind == "move" and row.id == 24 and row.dir == 0 and near(row.hold, .31), "hold counts plateau through neutral observation")
        check(near(row.finish - row.start, .18 + row.hold) and row.finish < e.air_seconds,
            "pose interval excludes recovery and includes only entry plus hold")
    end)
    scenario(function()
        local r = fixture(); r:air(); r:move(54)
        r.input.rear_neutral = true; r:wait(60)
        local e = r:land(); local row = e.sequence[1]
        check(e.movements == 1 and row.id == 54 and row.kind == "move" and row.hold == 0,
            "cycle movement never earns pose hold")
        check(near(row.finish - row.start, .45), "cycle interval ends before recovery")
    end)
    scenario(function()
        local r = fixture(); r:air(); r:bar(); r:wait(52)
        r.input.tailwhip, r.input.rear_neutral = "right", false; r:tick()
        local e = r:land()
        check(e.landed and e.failed and e.failure == "under_rotated" and not e.combo_landed and e.units == 0,
            "new details never convert failed landing into success")
        check(#e.sequence == 1 and e.sequence[1].kind == "bar", "uncaught parts are absent even on failed landing")
        check(r.model:state().tally.failed_combos == 1, "existing failure tally stays authoritative")
    end)
    scenario(function()
        local r = fixture({bar_seconds = .15, catch_blend = .01}); r:air()
        for _ = 1, 17 do r:bar(); r:wait(17) end
        local e = r:land()
        check(e.combo_landed and e.barspins == 17 and e.units == 17, "log cap cannot alter model counts")
        check(#e.sequence == 16 and e.overflow, "seventeenth caught part marks bounded overflow")
        r:air(); r:bar(); r:wait(17); r.model:cancel()
        r.input.grounded = true; r:tick(); r:air(); r:wait(30)
        local clean = r:land()
        check(#clean.sequence == 0 and not clean.overflow, "cancel discards flight-local bookkeeping")
    end)
    scenario(function()
        local r = fixture(); r.input.body_yaw = math.pi; r:tick(); r:air(); r:wait(30)
        r.input.landing_quality_available = true
        r.input.body_up_alignment, r.input.closing_normal_speed = .98, 4.32
        check(not r:land().landed, "known quality uses unchanged settle period")
        local e
        for _ = 1, 6 do e = r:tick() end
        check(e.landed and e.fakie_takeoff and near(e.landing.heading_cos, -1), "signed fakie heading survives landing")
        check(near(e.landing.body_up, .98) and near(e.landing.closing, 4.32) and near(e.air_seconds, .30),
            "landing numbers remain measured and settle time does not inflate air")
    end)
    scenario(function()
        for _, turn in ipairs({{2, 1, "spin_radians"}, {1, 1, "flip_radians"}, {1, -1, "flip_radians"}, {3, -1, "roll_radians"}}) do
            local r = fixture(); r.input.orientation_available = true; r:tick(); r:air()
            for n = 1, 40 do
                local angle = turn[2] * n * 2 * math.pi / 40
                local q = {0, 0, 0, math.cos(angle / 2)}; q[turn[1]] = math.sin(angle / 2)
                r.input.body_quaternion = q; r:tick()
            end
            local e = r:land()
            check(e.combo_landed and near(e[turn[3]], turn[2] * 2 * math.pi), "event keeps signed integrated rotation")
            check(near(e.air_seconds, .4) and #e.sequence == 0, "body rotations do not create channel parts")
        end
    end)
    return {cases = cases, assertions = assertions, native_actions = 0}
end
return Tests
