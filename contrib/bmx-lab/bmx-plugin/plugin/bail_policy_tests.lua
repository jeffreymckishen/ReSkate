-- Constructed vectors only; requiring this module is inert. It shows that the
-- Lua port agrees with results derived by reading
-- Engine/Game/BMX/bmx_bail_policy.h ("h:N"), and that the guard decoder never
-- turns a missing query into a clear one. None of it is in-game evidence.
-- newproxy handles stand in for native userdata; Lua cannot authenticate them.
local Bail = require("./bail_policy")
local Guard = require("./bail_guard")
local Geometry = require("./bike_geometry")
local M = require("./force_math")
local Frame = require("./frame_identity")
local Contact = require("./contact_runtime")
local tests = {}

function tests.run()
    local assertions, cases = 0, 0
    local function check(ok, why) assertions += 1; assert(ok, why) end
    local function near(a, b, e) return type(a) == "number" and math.abs(a - b) <= (e or 1e-9) end
    local N = Bail.native_seconds
    local NAN = 0/0
    local e = 1e-6
    local function copy(t)
        if type(t) ~= "table" then return t end
        local out = {}
        for k, v in t do out[k] = copy(v) end
        return out
    end

    -- sample(), hit() and next() of bmx_bail_policy_tests.cpp. Its Owner
    -- {1,2,3,4,5,6,0,1,1} becomes the opaque integer token 1.
    local function sample()
        return {owner = 1, serial = 1, seconds = N, mounted = true, body_up = {0, 1, 0}, contacts = {}}
    end
    local function contact(region, closing, normal, separation, swept)
        return {region = region, available = true, hit = true, query_serial = 0, point = {0, 0, 0},
            normal = normal or {0, 1, 0}, separation = separation or 0, closing_speed = closing or 0,
            swept_crossing = swept}
    end
    local function hit(s, region, closing, normal)
        local c = contact(region, closing, normal); c.query_serial = s.serial
        s.contacts = {c}
    end
    local function advance(s)
        s.serial += 1
        for _, c in s.contacts do c.query_serial = s.serial end
    end
    local function single(contacts, changes, tuning)
        local p = Bail.new(tuning); local s = sample(); s.contacts = contacts
        for _, c in contacts do c.query_serial = s.serial end
        for k, v in changes or {} do s[k] = v end
        return p:step(s), p, s
    end
    -- One empty seed sample first, so a swept row has consecutive history.
    local function swept_step(c, changes)
        local p = Bail.new(); local s = sample(); p:step(s); advance(s)
        c.query_serial = s.serial; s.contacts = {c}
        for k, v in changes or {} do s[k] = v end
        return p:step(s)
    end
    local function two(first, second, up)
        local p = Bail.new(); local s = sample(); s.body_up = up or {1, 0, 0}
        first.query_serial = s.serial; s.contacts = {first}
        local a = p:step(s)
        s.serial += 1; second.query_serial = s.serial; s.contacts = {second}
        return a, p:step(s)
    end

    -- natural_air_and_landing()
    do
        local p = Bail.new(); local s = sample(); s.body_up = {0, -1, 0}
        for _ = 1, 60 do check(not p:step(s).bail, "airborne inversion alone must never bail"); advance(s) end
        s.body_up = {0, 1, 0}; hit(s, "frame", 2.5); s.residual_available = true; s.residual_impulse_ns = 53.02
        local landing = p:step(s)
        check(landing.valid and not landing.bail, "known successful Run87 landing residual is below frame bail threshold")
        advance(s); s.residual_impulse_ns = 300; s.contacts[1].separation = .02
        check(not p:step(s).bail, "full query skin is not actual guard contact")
        advance(s); s.contacts = {}
        check(not p:step(s).bail, "large proxy without actual guard contact is not a collision claim")
        cases += 1
    end
    -- rider_and_frame_impacts()
    do
        for _, region in {"head", "torso"} do
            local p = Bail.new(); local s = sample(); hit(s, region, 2.01)
            local r = p:step(s)
            check(r.valid and r.bail and r.reason == "hard_rider_contact", "fresh head/torso closing contact bails immediately")
            advance(s)
            check(not p:step(s).bail and p:step(s).latched, "one native request per mount")
            p:pause(); advance(s)
            check(not p:step(s).bail, "pause must not replay a latched bail")
            s.owner += 1; advance(s)
            check(p:step(s).bail, "explicit new mount token rearms a current fresh contact")
        end
        local p = Bail.new(); local s = sample(); hit(s, "frame", 2.1); s.residual_available = true; s.residual_impulse_ns = 201
        check(p:step(s).reason == "large_frame_impact_proxy",
            "frame-only hard event requires explicit impulse proxy plus measured closing contact")
        cases += 1
    end
    -- slow_tilt_continuity()
    do
        local p = Bail.new(); local s = sample(); s.body_up = {1, 0, 0}; hit(s, "torso")
        check(not p:step(s).bail and p:step(s).tilt_steps == 0, "duplicate serial cannot add another tilt frame")
        advance(s); local r = p:step(s)
        check(r.bail and r.tilt_steps == 2, "two fresh slow severe contact frames bail")
        for variant = 0, 6 do
            p:reset(); s = sample(); s.body_up = {1, 0, 0}; hit(s, "torso")
            check(not p:step(s).bail, "first tilt frame seeds only")
            advance(s)
            if variant == 0 then p:pause()
            elseif variant == 1 then s.owner += 1 -- C++ ++entity
            elseif variant == 2 then s.owner += 2 -- C++ ++world
            elseif variant == 3 then advance(s)
            elseif variant == 4 then s.contacts[1].region = "head"
            elseif variant == 5 then s.contacts[1].normal = {0, 0, 1}
            else s.contacts[1].closing_speed = -.1 end
            check(not p:step(s).bail, "pause/owner/world/gap/region/normal/opening changes cannot retain old tilt credit")
        end
        p:reset(); s = sample(); s.body_up = {1, 0, 0}; hit(s, "frame", .6)
        check(p:step(s).reason == "severe_contact_tilt", "fast severe contact tilt does not wait for rest debounce")
        cases += 1
    end
    -- invalid_and_stale_samples()
    do
        local issues = {"stale_contact", "invalid_sample", "invalid_sample", "invalid_sample", "invalid_sample",
            "invalid_sample", "invalid_sample", "unsupported_step", "invalid_sample", "invalid_sample"}
        for variant = 0, 9 do
            local p = Bail.new(); local s = sample(); hit(s, "head", 3)
            if variant == 0 then s.contacts[1].query_serial = 0
            elseif variant == 1 then s.contacts[1].normal = {0, 0, 0}
            elseif variant == 2 then s.contacts[1].point[1] = NAN
            elseif variant == 3 then s.contacts[1].separation = -.2
            elseif variant == 4 then s.contacts[1].available = false
            elseif variant == 5 then s.contacts[1].region = "none"
            elseif variant == 6 then s.body_up = {0, 2, 0}
            elseif variant == 7 then s.seconds = .02
            elseif variant == 8 then for i = 2, 9 do s.contacts[i] = copy(s.contacts[1]) end
            else s.owner = 0 end -- C++ owner.world=0
            local r = p:step(s)
            check(not r.valid and not r.bail, "invalid/stale geometry or ownership must fail without a bail request")
            check(r.issue == issues[variant + 1], "each refusal names its C++ issue")
        end
        local p = Bail.new(); local s = sample(); hit(s, "head", 3)
        s.contacts[2] = copy(s.contacts[1]); s.contacts[2].query_serial = 0
        check(not p:step(s).bail, "later stale contact must invalidate the complete sample before an earlier hard contact fires")
        s = sample(); s.body_up = {1, 0, 0}; hit(s, "torso")
        check(not p:step(s).bail, "valid slow contact starts a fresh history")
        advance(s); s.seconds = .02
        check(not p:step(s).valid, "unsupported timing rejects and clears prior contact history")
        advance(s); s.seconds = N
        check(not p:step(s).bail, "invalid timing cannot lend a later frame old tilt credit")
        cases += 1
    end
    -- witnessed_swept_crossings()
    do
        local p = Bail.new(); local s = sample()
        check(not p:step(s).bail, "crossing starts with a prior current-owner sample")
        advance(s); hit(s, "frame", 5, {0, 0, -1}); s.contacts[1].separation = -1; s.contacts[1].swept_crossing = true
        local crossing = p:step(s)
        check(crossing.valid and crossing.bail and crossing.reason == "swept_body_crossing",
            "proven consecutive face crossing bails even beyond ordinary overlap depth and independent of tilt")
        for variant = 0, 5 do
            p:reset(); s = sample(); check(not p:step(s).bail, "seed crossing history"); advance(s)
            hit(s, "frame", 5, {0, 0, -1}); s.contacts[1].separation = -1; s.contacts[1].swept_crossing = true
            if variant == 0 then s.contacts[1].swept_crossing = false
            elseif variant == 1 then s.contacts[1].separation = -1.51
            elseif variant == 2 then s.contacts[1].separation = .01
            elseif variant == 3 then advance(s)
            elseif variant == 4 then s.owner += 1 -- C++ ++world
            else s.contacts[1].query_serial = 0 end
            local r = p:step(s)
            check(not r.valid and not r.bail, "unproven/deep/opening/stale/foreign sweep cannot bypass ordinary contact guards")
        end
        cases += 1
    end

    -- Parity vectors. Each expected row was derived by stepping the C++ Policy
    -- by hand (h:102-167) with default Tuning. Columns: valid, bail, latched,
    -- issue, reason, region, contact_index (1-based, C++ index + 1),
    -- alignment, closing_speed, tilt_steps.
    do
        local up0, upX, upZ = {0, 1, 0}, {1, 0, 0}, {0, 0, 1}
        local function K(region, closing, normal, separation, query, swept)
            local c = contact(region, closing, normal, separation, swept); c.query_serial = query
            return c
        end
        local function S(owner, serial, up, contacts, extra)
            local s = {owner = owner, serial = serial, seconds = N, mounted = true, body_up = up, contacts = contacts}
            for k, v in extra or {} do s[k] = v end
            return s
        end
        local nan_point = K("head", 3, up0, 0, 10); nan_point.point = {NAN, 0, 0}
        local n99 = {0, .99, .1410673597966588}
        local n96 = {0, .96, .28}
        local tilt3 = function(q) return {K("frame", 0, {0, .8, .6}, 0, q), K("torso", 0, {0, .9797958971132712, .2}, 0, q),
            K("head", 0, {0, .99498743710662, .1}, 0, q)} end
        local steps = {
            -- seed; then a duplicate is a no-op even with a NaN row (h:114 precedes h:117)
            {nil, S(7, 10, up0, {}), {true, false, false, "none", "none", "none", 0, 0, 0, 0}},
            {nil, S(7, 10, up0, {nan_point}), {true, false, false, "none", "none", "none", 0, 0, 0, 0}},
            -- slow tilt: torso at alignment 0, then a continuous normal (dot .99) on the next serial
            {nil, S(7, 11, upX, {K("torso", 0, up0, 0, 11)}), {true, false, false, "none", "none", "none", 0, 0, 0, 1}},
            {nil, S(7, 12, upX, {K("torso", 0, n99, 0, 12)}),
                {true, true, true, "none", "severe_contact_tilt", "torso", 1, 0, 0, 2}},
            -- latched: no second request, through pause and a dismount
            {nil, S(7, 13, up0, {K("head", 3, up0, 0, 13)}), {true, false, true, "none", "none", "none", 0, 0, 0, 0}},
            {"pause", S(7, 14, up0, {K("head", 3, up0, 0, 14)}), {true, false, true, "none", "none", "none", 0, 0, 0, 0}},
            {nil, S(7, 15, up0, {}, {mounted = false}), {true, false, true, "none", "none", "none", 0, 0, 0, 0}},
            -- a new owner rearms; separation exactly contact_gap still counts (h:139)
            {nil, S(8, 1, up0, {K("head", 2, up0, .005, 1)}),
                {true, true, true, "none", "hard_rider_contact", "head", 1, 1, 2, 0}},
            -- reset rearms; impulse and closing exactly at the proxy thresholds (h:155-156)
            {"reset", S(8, 2, up0, {K("frame", 2, up0, 0, 2)}, {residual_available = true, residual_impulse_ns = 200}),
                {true, true, true, "none", "large_frame_impact_proxy", "frame", 1, 1, 2, 0}},
            -- timing is refused before the owner test, so the old latch is reported (h:110-113)
            {nil, S(9, 5, up0, {}, {seconds = .02}), {false, false, true, "unsupported_step", "none", "none", 0, 0, 0, 0}},
            -- the owner change commits before the stale row is found (h:113, h:128)
            {nil, S(9, 5, up0, {K("head", 3, up0, 0, 4)}), {false, false, false, "stale_contact", "none", "none", 0, 0, 0, 0}},
            -- fast severe tilt: alignment 0, closing .6 >= .5
            {nil, S(9, 6, up0, {K("frame", .6, upX, 0, 6)}),
                {true, true, true, "none", "severe_contact_tilt", "frame", 1, 0, .6, 0}},
            -- after reset there is no history, so a swept row is invalid (h:125)
            {"reset", S(9, 7, up0, {K("frame", 5, {0, 0, -1}, -.5, 7, true), K("torso", 0, up0, 0, 7)}),
                {false, false, false, "invalid_sample", "none", "none", 0, 0, 0, 0}},
            {nil, S(9, 8, up0, {}), {true, false, false, "none", "none", "none", 0, 0, 0, 0}},
            {nil, S(9, 9, up0, {K("frame", .5, {0, 0, -1}, -.5, 9, true)}),
                {true, true, true, "none", "swept_body_crossing", "frame", 1, 0, .5, 0}},
            -- a region change restarts the count; opening faster than .05 removes it
            {"reset", S(9, 20, upX, {K("torso", 0, up0, 0, 20), K("head", 0, up0, .006, 20)}),
                {true, false, false, "none", "none", "none", 0, 0, 0, 1}},
            {nil, S(9, 21, upX, {K("frame", -.05, up0, 0, 21)}), {true, false, false, "none", "none", "none", 0, 0, 0, 1}},
            {nil, S(9, 22, upX, {K("frame", -.0500001, up0, 0, 22)}), {true, false, false, "none", "none", "none", 0, 0, 0, 0}},
            -- equal alignments keep the earlier row as the slow candidate (h:151)
            {nil, S(9, 23, upX, {K("frame", 0, up0, 0, 23), K("torso", 0, n96, 0, 23)}),
                {true, false, false, "none", "none", "none", 0, 0, 0, 1}},
            {nil, S(9, 24, upX, {K("frame", 0, n96, 0, 24)}),
                {true, true, true, "none", "severe_contact_tilt", "frame", 1, 0, 0, 2}},
            -- the lowest alignment below .25 becomes the slow candidate
            {"reset", S(9, 30, upZ, tilt3(30)), {true, false, false, "none", "none", "none", 0, 0, 0, 1}},
            {nil, S(9, 31, upZ, tilt3(31)), {true, true, true, "none", "severe_contact_tilt", "head", 3, .1, 0, 2}},
            -- a later hard rider contact fires before the earlier slow candidate is counted
            {"reset", S(9, 40, up0, {K("frame", .3, upX, 0, 40), K("head", 2.2, up0, .001, 40)}),
                {true, true, true, "none", "hard_rider_contact", "head", 2, 1, 2.2, 0}},
            -- per row, severe tilt precedes the frame proxy and the hard rider test precedes tilt
            {"reset", S(9, 50, up0, {K("frame", 2.5, upX, 0, 50)}, {residual_available = true, residual_impulse_ns = 300}),
                {true, true, true, "none", "severe_contact_tilt", "frame", 1, 0, 2.5, 0}},
            {"reset", S(9, 60, up0, {K("torso", 2.5, upX, 0, 60)}),
                {true, true, true, "none", "hard_rider_contact", "torso", 1, 0, 2.5, 0}},
            {nil, S(9, 61, up0, {K("frame", 9, {0, 0, -1}, -1.4, 61, true)}),
                {true, false, true, "none", "none", "none", 0, 0, 0, 0}},
            -- the string "9" is another owner: history clears, so the sweep is invalid
            {nil, S("9", 62, up0, {K("frame", 9, {0, 0, -1}, -1.4, 62, true)}),
                {false, false, false, "invalid_sample", "none", "none", 0, 0, 0, 0}},
            -- a row without a hit is skipped whatever else it holds (h:121)
            {nil, S("9", 63, up0, {{hit = false, region = "bogus", point = "x"}, K("head", 3, up0, 0, 63)}),
                {true, true, true, "none", "hard_rider_contact", "head", 2, 1, 3, 0}},
        }
        local fields = {"valid", "bail", "latched", "issue", "reason", "region", "contact_index", "alignment",
            "closing_speed", "tilt_steps"}
        local p = Bail.new()
        for index, step in steps do
            if step[1] == "pause" then p:pause() elseif step[1] == "reset" then p:reset() end
            local r = p:step(step[2])
            for i, name in fields do
                local want, got = step[3][i], r[name]
                check(got == want or type(want) == "number" and near(got, want, 1e-12),
                    "parity step " .. index .. " " .. name .. ": expected " .. tostring(want) .. ", got " .. tostring(got))
            end
        end
        cases += 1
    end

    -- Every threshold one micro-unit either side.
    do
        local function K(region, closing, normal, separation, swept)
            return contact(region, closing, normal, separation, swept)
        end
        local function tilted(a) return {math.sqrt(1 - a*a), a, 0} end
        -- contact_gap h:46, used at h:139
        check(single({K("head", 3, nil, .005)}).bail and single({K("head", 3, nil, .005 - e)}).bail, "within contact gap")
        local r = single({K("head", 3, nil, .005 + e)})
        check(r.valid and not r.bail, "just beyond the contact gap is not contact")
        -- hard_rider_closing h:47, h:144
        check(single({K("torso", 2)}).reason == "hard_rider_contact", "hard rider closing at threshold")
        check(not single({K("torso", 2 - e)}).bail, "hard rider closing below threshold")
        -- severe_alignment h:47, h:147; body_up {0,1,0} makes the alignment exactly a
        check(single({K("frame", 1, tilted(.25 - e))}).reason == "severe_contact_tilt", "alignment below .25 is severe")
        check(not single({K("frame", 1, tilted(.25))}).bail, "alignment at .25 is not severe")
        check(not single({K("frame", 1, tilted(.25 + e))}).bail, "alignment above .25 is not severe")
        -- immediate_tilt_closing h:47, h:148
        check(single({K("frame", .5, {1, 0, 0})}).reason == "severe_contact_tilt", "immediate tilt at threshold")
        r = single({K("frame", .5 - e, {1, 0, 0})})
        check(not r.bail and r.tilt_steps == 1, "slower severe contact only seeds the debounce")
        -- slow_opening_limit h:48, h:151
        local a, b = two(K("frame", -.05 + e), K("frame", -.05))
        check(a.tilt_steps == 1 and b.bail and b.reason == "severe_contact_tilt" and b.tilt_steps == 2, "opening at the limit still rests")
        a, b = two(K("frame", -.05), K("frame", -.05 - e))
        check(a.tilt_steps == 1 and not b.bail and b.tilt_steps == 0, "opening beyond the limit clears tilt credit")
        -- normal_continuity h:48, h:161; dot((0,1,0), (0,c,z)) is exactly c
        local function continuous(c) return {0, c, math.sqrt(1 - c*c)} end
        a, b = two(K("torso", 0), K("torso", 0, continuous(.95)))
        check(b.bail and b.tilt_steps == 2, "normal continuity at threshold keeps credit")
        a, b = two(K("torso", 0), K("torso", 0, continuous(.95 - e)))
        check(not b.bail and b.tilt_steps == 1, "normal continuity below threshold restarts")
        -- frame_proxy_impulse and frame_proxy_closing h:50, h:155-156
        local function residual(x) return {residual_available = true, residual_impulse_ns = x} end
        check(single({K("frame", 2.5)}, residual(200)).reason == "large_frame_impact_proxy", "proxy impulse at threshold")
        check(not single({K("frame", 2.5)}, residual(200 - e)).bail, "proxy impulse below threshold")
        check(single({K("frame", 2)}, residual(300)).reason == "large_frame_impact_proxy", "proxy closing at threshold")
        check(not single({K("frame", 2 - e)}, residual(300)).bail, "proxy closing below threshold")
        check(not single({K("frame", 2.5)}, {residual_available = false, residual_impulse_ns = 300}).bail,
            "an unavailable residual is no proxy")
        -- h:155 limits the proxy to frame rows. The default hard_rider_closing
        -- equals frame_proxy_closing, so a rider row would bail first; raising
        -- it shows a closing rider row alone never fires the frame proxy.
        local slow_rider = {hard_rider_closing = 5}
        for _, region in {"torso", "head"} do
            r = single({K(region, 3)}, residual(300), slow_rider)
            check(r.valid and not r.bail, region .. " contact with a large residual is not the frame proxy")
        end
        check(single({K("frame", 3)}, residual(300), slow_rider).reason == "large_frame_impact_proxy",
            "the same closing frame contact is the proxy")
        -- swept_closing h:51, h:141
        check(swept_step(K("frame", .5, nil, -.5, true)).reason == "swept_body_crossing", "swept closing at threshold")
        r = swept_step(K("frame", .5 - e, nil, -.5, true))
        check(r.valid and not r.bail, "swept closing below threshold")
        -- maximum_penetration h:46 and swept_penetration h:51, both at h:124
        check(single({K("frame", 0, nil, -.15)}).valid, "overlap at the ordinary depth limit")
        check(single({K("frame", 0, nil, -.15 - e)}).issue == "invalid_sample", "overlap beyond the ordinary depth limit")
        check(swept_step(K("frame", 1, nil, -1.5, true)).reason == "swept_body_crossing", "crossing at the swept depth limit")
        check(swept_step(K("frame", 1, nil, -1.5 - e, true)).issue == "invalid_sample", "crossing beyond the swept depth limit")
        check(swept_step(K("frame", 1, nil, -e, true)).bail, "a crossing just behind the face")
        check(swept_step(K("frame", 1, nil, 0, true)).issue == "invalid_sample", "a crossing must end behind the face (h:125)")
        -- native step h:9, h:110
        check(single({}, {seconds = N + 9e-9}).valid and single({}, {seconds = N - 9e-9}).valid, "native step within 1e-8")
        check(single({}, {seconds = N + 1e-6}).issue == "unsupported_step" and single({}, {seconds = N - 1e-6}).issue == "unsupported_step",
            "native step beyond tolerance")
        check(single({}, {seconds = N + 1.1e-8}).issue == "unsupported_step", "native step just beyond 1e-8")
        check(single({}, {seconds = 1/60}).valid, "the double 1/60 is within 1e-8 of the float step")
        check(single({}, {seconds = NAN}).issue == "unsupported_step", "a NaN step is unsupported")
        -- unit tolerance h:68
        check(single({}, {body_up = {0, math.sqrt(1.001 - e), 0}}).valid, "long body_up within .001")
        check(single({}, {body_up = {0, math.sqrt(1.001 + e), 0}}).issue == "invalid_sample", "long body_up beyond .001")
        check(single({}, {body_up = {0, math.sqrt(.999 + e), 0}}).valid, "short body_up within .001")
        check(single({}, {body_up = {0, math.sqrt(.999 - e), 0}}).issue == "invalid_sample", "short body_up beyond .001")
        -- closing magnitude h:124, residual h:107, point h:63-66
        check(single({K("frame", 100)}).valid and single({K("frame", -100)}).valid, "closing magnitude at 100")
        check(single({K("frame", 100 + e)}).issue == "invalid_sample" and single({K("frame", -100 - e)}).issue == "invalid_sample",
            "closing magnitude beyond 100")
        check(single({}, residual(0)).valid and single({}, residual(1e6)).valid, "residual bounds")
        check(single({}, residual(-e)).issue == "invalid_sample" and single({}, residual(1e6 + e)).issue == "invalid_sample",
            "residual beyond bounds")
        check(single({}, {residual_available = false, residual_impulse_ns = NAN}).valid, "an unavailable residual is not read")
        local far = K("frame", 0); far.point = {1e6, -1e6, 0}
        check(single({far}).valid, "point at the coordinate bound")
        far = K("frame", 0); far.point = {1e6 + e, 0, 0}
        check(single({far}).issue == "invalid_sample", "point beyond the coordinate bound")
        cases += 1
    end

    -- Every Reason and Issue, with the latch held until reset or a new owner.
    do
        local seen = {}
        local function note(r) seen[r.reason] = true; seen[r.issue] = true end
        note(single({contact("head", 3)}))
        note(single({contact("frame", 1, {1, 0, 0})}))
        note(single({contact("frame", 3)}, {residual_available = true, residual_impulse_ns = 250}))
        note(swept_step(contact("torso", 1, nil, -.4, true)))
        note(single({}, {seconds = .02}))
        local stale = contact("head", 3); stale.query_serial = 7
        local p = Bail.new(); local s = sample(); s.contacts = {stale}; note(p:step(s))
        note(single({}, {owner = false}))
        for _, name in Bail.reasons do check(seen[name], "reason " .. name .. " was produced") end
        for _, name in Bail.issues do check(seen[name], "issue " .. name .. " was produced") end

        p = Bail.new(); s = sample(); hit(s, "head", 3)
        check(p:step(s).bail, "first hard contact bails")
        for _ = 1, 30 do
            advance(s); local r = p:step(s)
            check(r.valid and r.latched and not r.bail, "a latched mount never requests again")
        end
        p:pause(); advance(s); check(not p:step(s).bail and p:status().latched, "pause keeps the latch")
        advance(s); s.mounted = false
        local r = p:step(s); check(r.valid and r.latched and not r.bail, "a dismount is a pause, not a rearm")
        s.mounted = true; advance(s); check(not p:step(s).bail, "remounting the same owner stays latched")
        advance(s); s.seconds = .02; r = p:step(s); s.seconds = N
        check(r.issue == "unsupported_step" and r.latched, "a refused sample reports and keeps the latch")
        advance(s); s.body_up = {0, 0, 0}; r = p:step(s); s.body_up = {0, 1, 0}
        check(r.issue == "invalid_sample" and r.latched and p:status().latched, "an invalid sample keeps the latch")
        advance(s); check(not p:step(s).bail, "still latched after refusals")
        p:reset(); advance(s); r = p:step(s)
        check(r.bail and r.reason == "hard_rider_contact", "reset rearms")
        s.owner = 2; advance(s); check(p:step(s).bail, "a new owner rearms")
        s.owner = "2"; advance(s); check(p:step(s).bail, "a token of another type is another owner")

        -- Pause clears history only: the owner and latch survive, consecutive history does not.
        p = Bail.new(); s = sample(); check(p:step(s).valid, "seed")
        p:pause(); check(p:status().owned and not p:status().observed, "pause keeps the owner and drops the serial")
        advance(s); s.contacts = {contact("frame", 5, {0, 0, -1}, -1, true)}; s.contacts[1].query_serial = s.serial
        check(p:step(s).issue == "invalid_sample", "a crossing after pause has no consecutive history")
        cases += 1
    end

    -- A stale or malformed later entry hides nothing behind an earlier severe hit.
    do
        local mutations = {
            {"zero query", function(c) c.query_serial = 0 end, "stale_contact"},
            {"previous query", function(c, s) c.query_serial = s.serial - 1 end, "stale_contact"},
            {"future query", function(c, s) c.query_serial = s.serial + 1 end, "stale_contact"},
            {"text query", function(c) c.query_serial = "x" end, "invalid_sample"},
            {"fractional query", function(c) c.query_serial = 1.5 end, "invalid_sample"},
            {"negative query", function(c) c.query_serial = -1 end, "invalid_sample"},
            {"missing query", function(c) c.query_serial = nil end, "invalid_sample"},
            {"NaN point", function(c) c.point = {NAN, 0, 0} end, "invalid_sample"},
            {"short point", function(c) c.point = {0, 0} end, "invalid_sample"},
            {"missing point", function(c) c.point = nil end, "invalid_sample"},
            {"vector point", function(c) c.point = vector.create(0, 0, 0) end, "invalid_sample"},
            {"zero normal", function(c) c.normal = {0, 0, 0} end, "invalid_sample"},
            {"long normal", function(c) c.normal = {0, 1.01, 0} end, "invalid_sample"},
            {"missing normal", function(c) c.normal = nil end, "invalid_sample"},
            {"region none", function(c) c.region = "none" end, "invalid_sample"},
            {"unknown region", function(c) c.region = "wheel" end, "invalid_sample"},
            {"missing region", function(c) c.region = nil end, "invalid_sample"},
            {"numeric region", function(c) c.region = 1 end, "invalid_sample"},
            {"unavailable", function(c) c.available = false end, "invalid_sample"},
            {"missing availability", function(c) c.available = nil end, "invalid_sample"},
            {"text availability", function(c) c.available = "true" end, "invalid_sample"},
            {"deep overlap", function(c) c.separation = -.2 end, "invalid_sample"},
            {"NaN separation", function(c) c.separation = NAN end, "invalid_sample"},
            {"text separation", function(c) c.separation = "0" end, "invalid_sample"},
            {"NaN closing", function(c) c.closing_speed = NAN end, "invalid_sample"},
            {"huge closing", function(c) c.closing_speed = 101 end, "invalid_sample"},
            {"missing closing", function(c) c.closing_speed = nil end, "invalid_sample"},
            {"text sweep", function(c) c.swept_crossing = "yes" end, "invalid_sample"},
            {"sweep without history", function(c) c.swept_crossing = true; c.separation = -.5 end, "invalid_sample"},
            {"text hit", function(c) c.hit = "yes" end, "invalid_sample"},
            {"missing hit", function(c) c.hit = nil end, "invalid_sample"},
        }
        for _, m in mutations do
            local p = Bail.new(); local s = sample(); hit(s, "head", 3)
            local later = copy(s.contacts[1]); m[2](later, s); s.contacts[2] = later
            local r = p:step(s)
            check(not r.bail and not r.valid and r.issue == m[3], "later " .. m[1] .. " entry is not hidden by an earlier hard contact")
            -- The refusal also clears history: the next serial is not consecutive.
            s.body_up = {1, 0, 0}; s.contacts = {contact("torso")}; advance(s)
            check(p:step(s).tilt_steps == 1, "a refused " .. m[1] .. " sample lends no history")
        end
        for _, bad in {true, "row", 5, setmetatable({hit = true}, {})} do
            local p = Bail.new(); local s = sample(); hit(s, "head", 3); s.contacts[2] = bad
            local r = p:step(s)
            check(not r.bail and r.issue == "invalid_sample", "a later row that is not a plain table is malformed")
        end
        local containers = {
            function(s) s.contacts[3] = copy(s.contacts[1]) end, -- a hole at 2
            function(s) for i = 2, 9 do s.contacts[i] = copy(s.contacts[1]) end end,
            function(s) s.contacts.extra = true end,
            function(s) s.contacts = "rows" end,
            function(s) s.contacts = setmetatable(s.contacts, {}) end,
        }
        for _, change in containers do
            local p = Bail.new(); local s = sample(); hit(s, "head", 3); change(s)
            local r = p:step(s)
            check(not r.bail and r.issue == "invalid_sample", "a malformed contact list is refused whole")
        end
        -- Rows are checked in order: an earlier stale row is reported before a later malformed one.
        local p = Bail.new(); local s = sample(); hit(s, "head", 3); s.contacts[1].query_serial = 0
        s.contacts[2] = copy(s.contacts[1]); s.contacts[2].query_serial = 1; s.contacts[2].normal = {0, 0, 0}
        check(p:step(s).issue == "stale_contact", "the first failing row names the issue")
        cases += 1
    end

    -- Duplicate serials, owner tokens and serial forms.
    do
        local p = Bail.new(); local s = sample(); s.body_up = {1, 0, 0}; hit(s, "torso")
        check(p:step(s).tilt_steps == 1, "first slow frame")
        for _ = 1, 5 do
            local r = p:step(s); check(r.valid and r.tilt_steps == 0 and not r.bail, "duplicates earn no frames")
        end
        local dup = copy(s); dup.contacts[1].point = {NAN, 0, 0}
        local r = p:step(dup); check(r.valid and r.issue == "none", "a duplicate is a no-op before its rows are checked (h:114)")
        dup.serial = "1"; r = p:step(dup); check(r.valid and r.issue == "none", "the string serial \"1\" is the same serial")
        advance(s); r = p:step(s); check(r.bail and r.tilt_steps == 2, "duplicates left the tilt history intact")
        r = p:step(s); check(r.valid and r.latched and not r.bail, "a duplicate after a bail only reports the latch")

        local valid = {1, 9007199254740991, "mount", string.rep("m", 128)}
        if type(newproxy) == "function" then table.insert(valid, newproxy(false)) end
        for _, owner in valid do
            s = sample(); s.owner = owner; check(Bail.new():step(s).valid, "opaque owner token accepted")
        end
        for _, owner in {0, -1, 1.5, 9007199254740992, NAN, math.huge, "", string.rep("m", 129), {}, true, false,
            function() end, vector.create(1, 2, 3)} do
            s = sample(); s.owner = owner
            check(Bail.new():step(s).issue == "invalid_sample", "owner " .. tostring(owner) .. " refused")
        end
        s = sample(); s.owner = nil; check(Bail.new():step(s).issue == "invalid_sample", "a missing owner is refused")

        local function crossing_after(first, second, query)
            local q = Bail.new(); local x = sample(); x.serial = first; q:step(x)
            x.serial = second; x.contacts = {contact("frame", 5, {0, 0, -1}, -1, true)}; x.contacts[1].query_serial = query or second
            return q:step(x)
        end
        check(crossing_after(5, "6").reason == "swept_body_crossing", "integer and string serials are one sequence")
        check(crossing_after("99", "100").reason == "swept_body_crossing", "decimal carry is consecutive")
        check(crossing_after("9007199254740992", "9007199254740993").reason == "swept_body_crossing", "serials beyond 2^53 stay exact")
        check(crossing_after("18446744073709551614", "18446744073709551615").reason == "swept_body_crossing", "the last u64 serial")
        check(crossing_after(7, 8, "8").reason == "swept_body_crossing", "a string query matches an integer serial")
        check(crossing_after(7, 9).issue == "invalid_sample", "a skipped serial is not consecutive")
        check(crossing_after("9007199254740992", "9007199254740994").issue == "invalid_sample", "exact large gaps are not consecutive")
        -- As doubles these pairs round to n and n+1, so only decimal counting
        -- sees the gap of two.
        check(crossing_after("9007199254740991", "9007199254740993").issue == "invalid_sample",
            "a gap of two across 2^53 is not consecutive")
        check(crossing_after("18446744073709551613", "18446744073709551615").issue == "invalid_sample",
            "a gap of two below the last u64 is not consecutive")
        check(crossing_after("9007199254740993", "9007199254740994").reason == "swept_body_crossing",
            "an odd serial above 2^53 has an exact successor")
        for _, serial in {0, "0", "01", " 1", "1 ", "-1", -1, 1.5, 9007199254740992, NAN, "", "1e3", true, {},
            "18446744073709551616", "99999999999999999999"} do
            s = sample(); s.serial = serial
            check(Bail.new():step(s).issue == "invalid_sample", "serial " .. tostring(serial) .. " refused")
        end
        cases += 1
    end

    -- Tuning bounds h:72-85 and the authored defaults h:46-51.
    do
        local d = Bail.defaults()
        check(d.contact_gap == .005 and d.maximum_penetration == .15 and d.hard_rider_closing == 2
            and d.severe_alignment == .25 and d.immediate_tilt_closing == .5 and d.slow_opening_limit == .05
            and d.normal_continuity == .95 and d.slow_tilt_steps == 2 and d.frame_proxy_impulse == 200
            and d.frame_proxy_closing == 2 and d.swept_penetration == 1.5 and d.swept_closing == .5, "defaults match h:46-51")
        check(Bail.valid_tuning(d) and Bail.native_seconds == .01666666567325592, "defaults are valid; native step h:9")
        local bounds = {
            {"contact_gap", {0, .01}, {-e, .01 + e}},
            {"maximum_penetration", {0, .25}, {-e, .25 + e}},
            {"hard_rider_closing", {e, 20}, {0, 20 + e}},
            {"severe_alignment", {-1, .5}, {-1 - e, .5 + e}},
            {"immediate_tilt_closing", {0, 20}, {-e, 20 + e}},
            {"slow_opening_limit", {0, .1}, {-e, .1 + e}},
            {"normal_continuity", {.5, 1}, {.5 - e, 1 + e}},
            {"slow_tilt_steps", {2, 3, 6}, {1, 7, 2.5}},
            {"frame_proxy_impulse", {53 + e, 10000}, {53, 10000 + e}},
            {"frame_proxy_closing", {e, 20}, {0, 20 + e}},
            {"swept_penetration", {.15, 1.5}, {.15 - e, 1.5 + e}},
            {"swept_closing", {e, 20}, {0, 20 + e}},
        }
        for _, row in bounds do
            for _, value in row[2] do
                local _, ok = Bail.tuning({[row[1]] = value}); check(ok, row[1] .. " accepts " .. value)
            end
            for _, value in row[3] do
                local _, ok = Bail.tuning({[row[1]] = value}); check(not ok, row[1] .. " refuses " .. value)
            end
            for _, value in {NAN, math.huge, "1", true} do
                local _, ok = Bail.tuning({[row[1]] = value}); check(not ok, row[1] .. " refuses a non-finite value")
            end
        end
        local _, ok = Bail.tuning({maximum_penetration = .2, swept_penetration = .19})
        check(not ok, "the swept depth may not be shallower than the ordinary depth")
        _, ok = Bail.tuning({contact_gaps = .004}); check(not ok, "a misspelt override is refused")
        check(Bail.tuning("tight") == nil, "a non-table override is refused")
        local p = Bail.new({slow_tilt_steps = 7}); local s = sample()
        check(p:step(s).issue == "invalid_sample" and not p:status().tuning_valid, "invalid tuning refuses every mounted sample")
        s.mounted = false; check(p:step(s).valid, "a dismount is still valid under invalid tuning")
        check(Bail.new("tight"):step(sample()).issue == "invalid_sample", "a malformed override table refuses samples")
        p = Bail.new({slow_tilt_steps = 3}); s = sample(); s.body_up = {1, 0, 0}; hit(s, "torso")
        check(not p:step(s).bail, "tilt 1 of 3"); advance(s)
        check(not p:step(s).bail, "tilt 2 of 3"); advance(s)
        local r = p:step(s); check(r.bail and r.tilt_steps == 3, "a three-frame debounce bails on its third frame")
        check(p:tuning().slow_tilt_steps == 3, "the policy reports its own tuning copy")
        cases += 1
    end

    -- Guard spheres, ray plans and the never-clear decode.
    -- Each frame carries its own synthetic Ride Framev1, so each plan is bound
    -- to one body read and its epoch. Time comes from the serial's last nine
    -- digits, so serials past 2^53 still advance by exactly one step.
    local body_handle, lease_handle = newproxy(), newproxy()
    local function body_frame(serial, com, v, q, w, owner)
        local p, vel, rot, spin = com, v or {0, 0, 0}, q or {0, 0, 0, 1}, w or {0, 0, 0}
        local key, epoch = tostring(serial), newproxy()
        local time = (tonumber(string.sub(key, -9)) or 0) * N
        local body = {mass = 12, inertia_body = {1, 1, 1}, center_of_mass = p, orientation = rot,
            linear_velocity = vel, angular_velocity = spin}
        local function xyz(a) return {x = a[1], y = a[2], z = a[3]} end
        local query = {valid = true, fresh = true, body_handle = body_handle, physics_epoch = epoch,
            serial = key, time = time, seconds = N, body = body,
            sample = {epoch = epoch, serial = key, time = time, seconds = N, mass = 12, inertia = xyz({1, 1, 1}),
                position = xyz(p), velocity = xyz(vel), angular_velocity = xyz(spin), rotation = rot},
            source = {lease_handle = lease_handle, generation = 1, user = 0, packet = 1, sequence = "1",
                source_epoch = "1", context_generation = "1", observation_serial = key, observed_ms = key},
            owner = {body_handle = body_handle, lease_handle = lease_handle}, gates = {focused = true, menu_open = false}}
        return {serial = serial, seconds = N, owner = owner or 1, body = body, query_frame = query}
    end
    -- The read epoch each plan and witness plan was made for, for cast().
    local epochs = setmetatable({}, {__mode = "k"})
    local function plan_for(frame, previous)
        local plan, why = Guard.plan(frame, previous)
        if plan then epochs[plan] = frame.query_frame.physics_epoch end
        return plan, why
    end
    local function witness_for(plan, batch)
        local w = Guard.witness(plan, batch)
        epochs[w] = epochs[plan]
        return w
    end
    local function world(frame, index)
        local g = Guard.guards[index]
        return M.add(frame.body.center_of_mass, M.turn(frame.body.orientation, M.sub(g.center, Geometry.com)))
    end
    local function surface(normal, offset, accept) return {normal = normal, offset = offset, accept = accept} end
    -- The Plane of bmx_body_guard_tests.cpp, returning measured probe rows for
    -- any ray list: a first plan or a witness plan, cast in its own read.
    -- arrays imitates a Contact.decode copy, which the guard refuses.
    local function cast(plan, surfaces, arrays)
        local rows = {}
        for i, ray in plan.rays do
            local a, b = {ray.from.x, ray.from.y, ray.from.z}, {ray.to.x, ray.to.y, ray.to.z}
            local best
            for _, f in surfaces do
                local start, finish = M.dot(a, f.normal) - f.offset, M.dot(b, f.normal) - f.offset
                if start > 0 and finish <= 0 then
                    local t = start/(start - finish)
                    local point = M.add(a, M.mul(M.sub(b, a), t))
                    if (not f.accept or f.accept(point)) and (not best or t < best.t) then
                        best = {t = t, point = point, normal = f.normal}
                    end
                end
            end
            if not best then
                rows[i] = arrays and {status = "clear", visual_hit = false, normal_available = false,
                    surface_velocity_available = false, motion = "unknown"} or {status = "clear"}
            elseif arrays then
                rows[i] = {status = "hit", visual_hit = true, position = best.point, fraction = best.t,
                    normal_available = true, surface_velocity_available = true, normal = copy(best.normal),
                    surface_velocity = {0, 0, 0}, motion = "measured"}
            else
                local p, n = best.point, best.normal
                rows[i] = {status = "hit", position = vector.create(p[1], p[2], p[3]), fraction = best.t,
                    normal_available = true, surface_velocity_available = true, normal = vector.create(n[1], n[2], n[3]),
                    surface_velocity = vector.create(0, 0, 0), motion = "measured"}
            end
        end
        return {status = "available", native_casts = #rows, budget_exhausted = false, epoch = epochs[plan],
            local_actor_excluded = true, owned_bodies_excluded = true, rays = rows}
    end
    local function hits(decoded)
        local out = {}
        for i, c in decoded.contacts do if c.hit then table.insert(out, i) end end
        return table.concat(out, ",")
    end
    -- Both batches of one body step: the inspection rays, then the witnesses.
    local function guard_decode(plan, surfaces, arrays)
        local first = cast(plan, surfaces, arrays)
        local witness = witness_for(plan, first)
        check(witness.available and #witness.rays <= Guard.MAX_RAYS, "constructed first batch gives a witness plan")
        local second = #witness.rays > 0 and cast(witness, surfaces, arrays) or nil
        return Guard.decode(witness, second), witness, first
    end
    local function step_frames(policy, frames, surfaces, residual)
        local last
        for i, f in frames do
            local plan = assert(plan_for(f, frames[i - 1]))
            local decoded = guard_decode(plan, surfaces)
            check(decoded.available, "constructed guard batches decode")
            last = {plan = plan, decoded = decoded, result = policy:step(Guard.policy_sample(plan, decoded, residual))}
        end
        return last
    end
    local function vnear(v, want, tolerance)
        return typeof(v) == "vector" and near(v.x, want[1], tolerance) and near(v.y, want[2], tolerance)
            and near(v.z, want[3], tolerance)
    end
    local function slot_of(plan, guard, kind)
        for i, slot in plan.slots do if slot.guard == guard and slot.kind == kind then return i end end
        return nil
    end
    local up0 = {0, 1, 0}

    do
        local s = Geometry.scale
        local expected = {
            {{0, .45*s, -.30*s}, .12*s, "frame"}, {{0, .60*s, .20*s}, .12*s, "frame"},
            {Geometry.right_grip, .055*s, "frame"}, {Geometry.left_grip, .055*s, "frame"},
            {{0, .89, -.305}, .16, "torso"}, {{0, .97, -.30}, .18, "torso"}, {{0, 1.20, -.15}, .18, "torso"},
            {{0, 1.385, .135}, .16, "head"},
        }
        check(#Guard.guards == 8, "eight guard spheres")
        for i, want in expected do
            local g = Guard.guards[i]
            check(g.center[1] == want[1][1] and g.center[2] == want[1][2] and g.center[3] == want[1][3]
                and g.radius == want[2] and g.region == want[3], "guard " .. i .. " matches bmx_collision_envelope.h")
        end
        check(table.isfrozen(Guard.guards) and table.isfrozen(Guard.guards[1].center), "guards are read-only copies")
        check(Geometry.capsules[3].a[2] == .45*s, "bike_geometry was not modified")

        local still = body_frame(1, {0, 5, 0})
        local plan = assert(plan_for(still))
        check(#plan.rays == 8 and not plan.consecutive and plan.serial == "1" and plan.owner == 1, "a still body probes down only")
        check(plan.options.require_contact == true and plan.options.exclude_local_actor == true, "normals and rider exclusion are requested")
        for i, ray in plan.rays do
            local keys = 0
            for _ in ray do keys += 1 end
            local length = vector.magnitude(ray.to - ray.from)
            check(keys == 2 and typeof(ray.from) == "vector" and typeof(ray.to) == "vector" and length > 1e-5 and length <= 1000,
                "ray " .. i .. " is exactly probe_batch shaped")
            check(plan.slots[i].kind == "down" and plan.slots[i].guard == i, "slot metadata names each ray")
            -- guard:42-45: radius + .15 above the center to radius/.3 + .06 below it.
            local center, r = world(still, i), Guard.guards[i].radius
            check(vnear(ray.from, M.add(center, M.mul(up0, r + .15)), 1e-6)
                and vnear(ray.to, M.sub(center, M.mul(up0, r/.3 + .06)), 1e-6), "down ray " .. i .. " spans guard:42-45")
        end
        local moving = body_frame(2, {0, 5, .5/6}, {0, 0, 5})
        local moving_plan = assert(plan_for(moving))
        check(#moving_plan.rays == 16, "a moving body adds a movement ray per guard")
        for i = 1, 8 do
            -- The movement ray looks back along -velocity: up = (0,0,-1).
            local ray = moving_plan.rays[assert(slot_of(moving_plan, i, "movement"))]
            local center, r, back = world(moving, i), Guard.guards[i].radius, {0, 0, -1}
            check(vnear(ray.from, M.add(center, M.mul(back, r + .15)), 1e-6)
                and vnear(ray.to, M.sub(center, M.mul(back, r/.3 + .06)), 1e-6), "movement ray " .. i .. " looks along the motion")
        end
        local previous = body_frame(1, {0, 5, 0}, {0, 0, 5})
        plan = assert(plan_for(moving, previous))
        check(#plan.rays == 24 and plan.consecutive, "a consecutive moving body adds the swept path")
        for i = 1, 8 do
            -- guard:42 and 90: the swept ray starts at the previous center.
            local ray = plan.rays[assert(slot_of(plan, i, "swept"))]
            local center, before, r = world(moving, i), world(previous, i), Guard.guards[i].radius
            local up = M.unit(M.sub(before, center))
            check(vnear(ray.from, before, 1e-6) and vnear(ray.to, M.sub(center, M.mul(up, r/.3 + .06)), 1e-6),
                "swept ray " .. i .. " follows the center path")
        end
        check(not plan_for(moving, body_frame(3, {0, 5, 0}, {0, 0, 5})).consecutive, "a later serial lends no history")
        check(not plan_for(moving, body_frame(1, {0, 5, 0}, {0, 0, 5}, nil, nil, 2)).consecutive, "another owner lends no history")
        check(plan_for(moving, body_frame("1", {0, 5, 0}, {0, 0, 5})).consecutive, "string serials are consecutive too")
        local big = body_frame("9007199254740993", {0, 5, .5/6}, {0, 0, 5})
        check(not plan_for(big, body_frame("9007199254740991", {0, 5, 0}, {0, 0, 5})).consecutive,
            "guard history counts serials in decimal across 2^53")
        check(plan_for(big, body_frame("9007199254740992", {0, 5, 0}, {0, 0, 5})).consecutive, "the exact predecessor above 2^53")

        -- guard:84-86: the movement ray needs speed over .5 m/s and a direction
        -- that is not nearly straight down.
        local function count(v, previous_frame, com)
            return #assert(plan_for(body_frame(2, com or {0, 5, 0}, v), previous_frame)).rays
        end
        check(count({0, 0, .4999}) == 8 and count({0, 0, .5001}) == 16, "movement ray speed gate at .5 m/s")
        check(count({0, -5, 0}) == 8, "a straight fall adds no movement ray")
        local function falling(c) return M.mul({math.sqrt(1 - c*c), c, 0}, -5) end
        check(count(falling(.9799)) == 16 and count(falling(.9801)) == 8, "movement ray direction gate at .98")
        -- guard:90: the swept ray needs a center path over 2 cm and up to 1.5 m.
        for _, case in {{.019, 8}, {.021, 16}, {1.49, 16}, {1.51, 8}} do
            check(count({0, 0, 0}, body_frame(1, {0, 5, -case[1]})) == case[2],
                "a center path of " .. case[1] .. " m gives " .. case[2] .. " rays")
        end
        -- A spinning body: every guard moves at v + w x r, so the head of a
        -- forward flip looks back along -(w x r).
        local spin = body_frame(1, {0, 5, 0}, {0, 0, 0}, nil, {8, 0, 0})
        local spin_plan = assert(plan_for(spin))
        local head_slot = slot_of(spin_plan, 8, "movement")
        local c8 = world(spin, 8)
        local back = M.unit(M.mul(M.cross({8, 0, 0}, M.sub(c8, {0, 5, 0})), -1))
        check(head_slot and vnear(spin_plan.rays[head_slot].from, M.add(c8, M.mul(back, Guard.guards[8].radius + .15)), 1e-6),
            "a spinning guard's movement ray uses its own point velocity")

        -- Seeded poses never exceed the probe_batch limit.
        local seed = 77
        local function rand() seed = seed*16807 % 2147483647; return seed/2147483647 end
        for i = 1, 50 do
            local q = {rand()*2 - 1, rand()*2 - 1, rand()*2 - 1, rand()*2 - 1}
            local norm = math.sqrt(q[1]^2 + q[2]^2 + q[3]^2 + q[4]^2)
            for k = 1, 4 do q[k] /= norm end
            local v = {rand()*80 - 40, rand()*80 - 40, rand()*80 - 40}
            local w = {rand()*40 - 20, rand()*40 - 20, rand()*40 - 20}
            local com = {rand()*2000 - 1000, rand()*100, rand()*2000 - 1000}
            local now = body_frame(i + 1, com, v, q, w)
            local before = body_frame(i, M.sub(com, M.mul(v, N)), v, q, w)
            local p = assert(plan_for(now, before))
            check(#p.rays >= 8 and #p.rays <= 24 and #p.rays <= Guard.MAX_RAYS and #p.slots == #p.rays, "seeded plan stays within budget")
        end
        for _, bad in {
            body_frame(0, {0, 5, 0}), body_frame(1, {0, NAN, 0}), body_frame(1, {0, 5, 0}, nil, {0, 0, 0, 2}),
            body_frame(1, {0, 5, 0}, {2000, 0, 0}), body_frame(1, {95000, 5, 0}), body_frame(1, {0, 5, 0}, nil, nil, nil, {}),
            {serial = 1, owner = 1}, "frame",
        } do
            check(plan_for(bad) == nil, "an invalid guard frame has no plan")
        end
        cases += 1
    end

    do
        local frame = body_frame(1, {0, 5, 0})
        local plan = assert(plan_for(frame))
        local clear, clear_witness = guard_decode(plan, {})
        check(#clear_witness.rays == 0 and clear.available and #clear.contacts == 8 and clear.rays == 8
            and clear.witness_rays == 0, "clear air needs no witness and decodes to eight rows")
        for i, c in clear.contacts do
            check(c.available and not c.hit and c.query_serial == "1" and c.region == Guard.guards[i].region,
                "a clear guard row is available, fresh and without a hit")
        end
        local sample_row = Guard.policy_sample(plan, clear)
        check(sample_row and Bail.new():step(sample_row).valid, "a clear guard sample is a valid policy sample")

        local function refused(batch, reason, why)
            local witness = witness_for(plan, batch)
            check(not witness.available and witness.reason == reason and #witness.rays == 0, why .. " gives no witness rays")
            local decoded = Guard.decode(witness, nil)
            check(not decoded.available and #decoded.contacts == 0 and decoded.reason == reason, why)
            check(Guard.policy_sample(plan, decoded) == nil, why .. " gives the policy no sample")
        end
        refused({status = "unavailable", reason = "local_actor_exclusion_unavailable", rays = {}},
            "local_actor_exclusion_unavailable", "an unavailable batch is not clear")
        refused({valid = false, status = "unavailable", reason = "query_epoch_mismatch", rays = {}},
            "guard_query_unavailable", "a rejected Contact.decode is not clear")
        refused("batch", "guard_query_unavailable", "a non-table batch is not clear")
        local partial = cast(plan, {}); partial.rays[4] = {status = "unavailable"}
        refused(partial, "guard_ray_unavailable", "one unavailable ray among clears is not clear")
        partial = cast(plan, {}); partial.rays[8] = nil
        refused(partial, "guard_rays_incomplete", "a missing ray is not clear")
        partial = cast(plan, {}); partial.rays[9] = {status = "clear"}
        refused(partial, "guard_rays_incomplete", "an extra ray is refused")
        partial = cast(plan, {}); partial.rays[2] = {status = "maybe"}
        refused(partial, "guard_ray_unavailable", "an unknown status is not clear")
        partial = cast(plan, {}); partial.rays[2] = "clear"
        refused(partial, "guard_ray_unavailable", "a non-table row is not clear")
        partial = cast(plan, {}); partial.rays[3] = {status = "clear", position = vector.create(0, 0, 0)}
        refused(partial, "malformed_guard_clear", "a clear row with geometry is contradictory")
        partial = cast(plan, {}); partial.budget_exhausted = true
        refused(partial, "guard_query_unavailable", "an exhausted budget is not clear")

        -- A floor under guard 1 gives measured hits to mutate.
        local floor_frame = body_frame(1, {0, Guard.guards[1].radius - (Guard.guards[1].center[2] - Geometry.com[2]), 0})
        local floor_plan = assert(plan_for(floor_frame))
        local floor = {surface({0, 1, 0}, 0)}
        local function first_hit(batch)
            for i, row in batch.rays do if row.status == "hit" then return i end end
            return nil
        end
        local function mutated(change, reason, why)
            local batch = cast(floor_plan, floor); local i = assert(first_hit(batch)); change(batch.rays[i])
            local decoded = Guard.decode(witness_for(floor_plan, batch), nil)
            check(not decoded.available and decoded.reason == reason and #decoded.contacts == 0, why)
        end
        mutated(function(row) row.normal_available = false; row.normal = nil end, "guard_normal_unavailable",
            "a hit without a measured normal is unavailable, not clear")
        mutated(function(row) row.position = row.position + vector.create(.03, 0, 0) end, "malformed_guard_hit",
            "a hit off its own segment is refused")
        mutated(function(row) row.fraction = 1.5 end, "malformed_guard_hit", "a fraction beyond the segment is refused")
        mutated(function(row) row.normal = vector.create(0, -1, 0) end, "backfacing_guard_normal", "a backfacing normal is refused")
        mutated(function(row) row.normal = vector.create(0, 1.01, 0) end, "malformed_guard_normal", "a non-unit normal is refused")
        local decoded, witness = guard_decode(floor_plan, floor)
        local as_arrays = witness_for(floor_plan, cast(floor_plan, floor, true))
        check(decoded.available and hits(decoded) == "1" and not as_arrays.available
            and as_arrays.reason == "malformed_guard_hit" and not Guard.decode(as_arrays, nil).available,
            "raw vector rows decode; Contact.decode-shaped array rows have no raw-query authority")
        check(near(decoded.contacts[1].separation, 0, 1e-5) and near(decoded.contacts[1].normal[2], 1), "floor contact geometry")
        check(decoded.rays == 9 and decoded.witness_rays == 1, "the decode counts both batches")

        -- guard:71-72: one witness along the measured normal through the center,
        -- from radius + .16 in front of it to radius + .06 behind it.
        local c1, r1 = world(floor_frame, 1), Guard.guards[1].radius
        check(#witness.rays == 1 and witness.slots[1].guard == 1 and witness.slots[1].kind == "witness"
            and witness.slots[1].region == "frame" and rawequal(witness.options, floor_plan.options)
            and witness.serial == "1" and witness.owner == 1, "one witness ray for the one candidate")
        check(vnear(witness.rays[1].from, M.add(c1, M.mul(up0, r1 + .16)), 1e-6)
            and vnear(witness.rays[1].to, M.sub(c1, M.mul(up0, r1 + .06)), 1e-6), "the witness spans guard:71-72")
        check(table.isfrozen(witness) and table.isfrozen(witness.rays) and table.isfrozen(witness.rays[1]),
            "a witness plan is read-only")

        -- Plan and witness identity.
        check(witness_for(table.clone(floor_plan), cast(floor_plan, floor)).reason == "unknown_guard_plan",
            "a copied plan is not an issued plan")
        check(Guard.decode(floor_plan, cast(floor_plan, floor)).reason == "unknown_guard_witness",
            "the first batch alone cannot be decoded without its witnesses")
        check(Guard.decode(table.clone(witness), cast(witness, floor)).reason == "unknown_guard_witness",
            "a copied witness plan is not an issued one")
        check(Guard.policy_sample(plan, decoded) == nil, "one plan's sample cannot use another plan's decode")
        check(Guard.policy_sample(floor_plan, decoded) ~= nil, "the plan's own decode gives a sample")

        -- The witness batch is never clear by default. prepare edits the first
        -- batch before Guard.witness reads it; change returns the second batch.
        local function witness_refused(change, reason, why, prepare)
            local first = cast(floor_plan, floor)
            if prepare then prepare(first) end
            local w = witness_for(floor_plan, first)
            check(w.available and #w.rays == 1, why .. ": the first batch is usable")
            local d = Guard.decode(w, change(cast(w, floor)))
            check(not d.available and d.reason == reason and #d.contacts == 0, why)
            check(Guard.policy_sample(floor_plan, d) == nil, why .. " gives the policy no sample")
        end
        local function edit(f) return function(b) f(b); return b end end
        witness_refused(function() return nil end, "guard_query_unavailable", "an uncast witness is not clear")
        witness_refused(function() return {status = "unavailable", reason = "backend", rays = {{status = "unavailable"}}} end,
            "backend", "an unavailable witness batch is not clear")
        witness_refused(edit(function(b) b.budget_exhausted = true end), "guard_query_unavailable", "an exhausted witness budget")
        witness_refused(edit(function(b) b.rays[1] = nil end), "guard_rays_incomplete", "a missing witness row")
        witness_refused(edit(function(b) b.rays[2] = {status = "clear"} end), "guard_rays_incomplete", "an extra witness row")
        witness_refused(edit(function(b) b.rays[1] = {status = "unavailable"} end), "guard_ray_unavailable",
            "an unavailable witness row")
        witness_refused(edit(function(b) b.rays[1].normal_available = false; b.rays[1].normal = nil end),
            "guard_normal_unavailable", "a witness hit without a measured normal")
        witness_refused(edit(function(b) b.rays[1].fraction = .5 end), "malformed_guard_hit", "a witness hit off its own segment")
        local other = body_frame(1, floor_frame.body.center_of_mass).query_frame.physics_epoch
        witness_refused(edit(function(b) b.epoch = newproxy() end), "guard_witness_epoch_mismatch",
            "a witness with an unknown epoch")
        witness_refused(edit(function(b) b.epoch = other end), "guard_witness_epoch_mismatch",
            "a witness from another read of the same pose and serial")
        witness_refused(edit(function(b) b.epoch = nil end), "guard_witness_epoch_mismatch", "a witness without an epoch")
        witness_refused(edit(function(b) b.local_actor_excluded = false end), "guard_exclusion_unqualified",
            "a witness that may have stopped on the rider")
        witness_refused(edit(function(b) b.owned_bodies_excluded = nil end), "guard_exclusion_unqualified",
            "a witness without the owned-body exclusion fact")
        witness_refused(edit(function(b) b.query = {} end), "guard_batch_not_raw", "a witness with decoded fields")
        witness_refused(edit(function(b) b.native_casts = nil end), "malformed_available_batch",
            "a witness without cast accounting")
        witness_refused(edit(function(b) b.native_casts = 3 end), "malformed_available_batch",
            "a witness with impossible cast accounting")
        witness_refused(edit(function(b)
            b.rays[1].surface_velocity_available = false; b.rays[1].surface_velocity = nil; b.rays[1].motion = "unknown"
        end), "guard_measurements_unavailable", "a witness hit without measured surface motion")
        witness_refused(edit(function(b) b.rays[1].visual_hit = true end), "malformed_guard_hit", "a decoded witness row")
        do
            local w = witness_for(floor_plan, cast(floor_plan, floor))
            check(hits(Guard.decode(w, cast(w, floor))) == "1", "a witness in the first batch's read decodes")
        end
        -- guard:73-74: a clear witness, or one off the measured plane by more
        -- than 2.5 mm, is no contact. Near y = 0 the float vectors resolve far
        -- below the 1e-6 margin.
        local function shifted(by)
            local first = cast(floor_plan, floor)
            local w = witness_for(floor_plan, first)
            local second = cast(w, floor)
            if by then second.rays[1].position -= vector.create(0, by, 0) else second.rays[1] = {status = "clear"} end
            return Guard.decode(w, second)
        end
        check(hits(shifted(.0025 - e)) == "1", "a witness within 2.5 mm of the plane")
        local off = shifted(.0025 + e)
        check(off.available and hits(off) == "" and off.counts.unwitnessed == 1, "a witness beyond 2.5 mm of the plane")
        off = shifted(nil)
        check(off.available and hits(off) == "" and off.counts.unwitnessed == 1, "a clear witness is no contact")
        -- Candidates of one guard on one measured plane share their witness.
        local sliding = body_frame(1, floor_frame.body.center_of_mass, {0, -2, 2})
        local sliding_plan = assert(plan_for(sliding))
        local slid, slid_witness, slid_first = guard_decode(sliding_plan, floor)
        local guard1_hits = 0
        for i, row in slid_first.rays do if row.status == "hit" and sliding_plan.slots[i].guard == 1 then guard1_hits += 1 end end
        check(guard1_hits == 2 and #slid_witness.rays == 1 and hits(slid) == "1",
            "down and movement hits on one plane share one witness ray")

        -- Oblique faces are witnessed down to the .3 alignment gate (guard:43-45, 54).
        for _, degrees in {0, 5, 10, 15, 20, 30, 45, 60, 70} do
            local a = math.rad(degrees)
            local n = {math.sin(a), math.cos(a), 0}
            local center = world(frame, 1)
            local d = guard_decode(plan, {surface(n, M.dot(center, n) - Guard.guards[1].radius)})
            local row = d.contacts[1]
            check(d.available and row.hit and near(row.separation, 0, 1e-5) and near(row.normal[1], n[1], 1e-6)
                and near(M.dot(M.sub(center, row.point), n), Guard.guards[1].radius, 1e-5),
                "a resting guard on a " .. degrees .. " degree face is witnessed contact")
        end
        local steep = {math.sin(math.rad(75)), math.cos(math.rad(75)), 0}
        local beyond = guard_decode(plan, {surface(steep, M.dot(world(frame, 1), steep) - Guard.guards[1].radius)})
        check(beyond.available and not beyond.contacts[1].hit and beyond.counts.grazing >= 1, "a 75 degree face is beyond the gate")
        local grazing = guard_decode(plan, {surface({.96, .28, 0}, M.dot(world(frame, 1), {.96, .28, 0}) - .05)})
        check(grazing.available and hits(grazing) == "" and grazing.counts.grazing >= 1 and grazing.counts.grazing == grazing.counts.hits,
            "a face below the .3 alignment gate is grazing")
        cases += 1
    end

    -- The scenarios of bmx_body_guard_tests.cpp with whole-bike poses.
    do
        local function decode(now, before, surfaces)
            local plan = assert(plan_for(now, before))
            local decoded, witness = guard_decode(plan, surfaces)
            check(decoded.available, "constructed scenario decodes")
            return decoded, plan, witness
        end
        -- Place a body so guard index sits at a world point, upright.
        local function at(serial, index, point, v)
            return body_frame(serial, M.sub(point, M.sub(Guard.guards[index].center, Geometry.com)), v)
        end
        -- Floor under guard 1: the incoming speed of the previous step is kept.
        local floor = {surface({0, 1, 0}, 0)}
        local y = Guard.guards[1].radius - (Guard.guards[1].center[2] - Geometry.com[2])
        local before, now = body_frame(1, {0, y + .08, 0}, {0, -5, 0}), body_frame(2, {0, y, 0}, {0, -.1, 0})
        local d = decode(now, before, floor)
        local c = d.contacts[1]
        check(hits(d) == "1" and near(c.separation, 0, 1e-5) and near(c.normal[2], 1) and near(c.closing_speed, 5, 1e-9)
            and not c.swept_crossing, "fresh floor fit preserves measured incoming speed")
        local r = step_frames(Bail.new(), {before, now}, floor).result
        check(r.valid and not r.bail, "a level landing without the proxy is no bail")
        r = step_frames(Bail.new(), {before, now}, floor, 201).result
        check(r.reason == "large_frame_impact_proxy" and r.contact_index == 1, "the same landing with a large residual is the frame proxy")

        -- A thin wall crossed between two steps at 30 m/s.
        local wall = {surface({1, 0, 0}, 0)}
        before, now = body_frame(1, {.45, 2, 0}, {-30, 0, 0}), body_frame(2, {-.05, 2, 0}, {-30, 0, 0})
        local crossing, _, crossing_witness = decode(now, before, wall)
        d = crossing
        check(hits(d) == "1,2,3,5,6,7,8", "every guard whose center crossed the face reports it")
        check(#crossing_witness.rays == 0, "a guard with a crossing needs no witness ray")
        for _, i in {1, 2, 3, 5, 6, 7, 8} do
            check(d.contacts[i].swept_crossing and d.contacts[i].separation < -.14 and near(d.contacts[i].closing_speed, 30, 1e-9),
                "guard " .. i .. " crossing is witnessed by its own swept path")
        end
        local seeded = decode(before, nil, wall)
        check(hits(seeded) == "", "the step before the wall has no contact")
        r = step_frames(Bail.new(), {before, now}, wall).result
        check(r.bail and r.reason == "swept_body_crossing" and r.contact_index == 1 and r.region == "frame",
            "a consecutive center crossing is a swept bail")
        d = decode(now, nil, wall)
        for _, row in d.contacts do check(not row.swept_crossing, "a center crossing requires consecutive history") end
        -- guard:64 also needs the previous center in front of the measured
        -- face. A hit may be reported up to 25 mm off its segment; one moved
        -- 20 mm toward a previous center 10 mm in front leaves that center
        -- behind, so the deep current overlap is no crossing.
        local function grazing_start(shift)
            local plan = assert(plan_for(body_frame(2, {-.49, 2, 0}, {-30, 0, 0}), body_frame(1, {.01, 2, 0}, {-30, 0, 0})))
            local batch = cast(plan, wall)
            local i = assert(slot_of(plan, 1, "swept"))
            batch.rays[i].position += vector.create(shift, 0, 0)
            local w = witness_for(plan, batch)
            return Guard.decode(w, #w.rays > 0 and cast(w, wall) or nil)
        end
        check(grazing_start(0).contacts[1].swept_crossing, "a previous center 10 mm in front of the face crosses it")
        d = grazing_start(.02)
        check(d.available and not d.contacts[1].hit and d.counts.outside_gap >= 1,
            "a previous center behind the measured face is no new crossing")

        -- Deep existing overlap without a new crossing stays unauthorized.
        local ceiling = {surface({0, 1, 0}, 2)}
        local head = Guard.guards[8].center[2] - Geometry.com[2]
        d = decode(body_frame(2, {0, 1.97 - head, 0}, {0, -1.8, 0}), body_frame(1, {0, 1.99 - head, 0}, {0, -1.8, 0}), ceiling)
        check(hits(d) == "" and d.counts.outside_gap >= 1, "existing deep overlap without a new center crossing stays unauthorized")

        -- A finite face: a crossing inside its real edge counts, one beyond it does not.
        local finite_floor = {surface({0, 1, 0}, 2, function(p) return p[1] <= 0 end)}
        local z = Guard.guards[8].center[3] - Geometry.com[3]
        local inside_before = body_frame(1, {-.30, 2.08 - head, -z}, {0, 0, 0})
        local inside = body_frame(2, {-.02, 1.98 - head, -z}, {16.8, -6, 0})
        d = decode(inside, inside_before, finite_floor)
        check(hits(d) == "8" and d.contacts[8].swept_crossing and near(d.contacts[8].separation, -.18, 1e-5)
            and near(d.contacts[8].closing_speed, 6, 1e-9), "finite face accepts a historical center crossing inside its real edge")
        local seed_row = decode(inside_before, nil, finite_floor)
        check(hits(seed_row) == "8" and near(seed_row.contacts[8].separation, -.08, 1e-5) and seed_row.contacts[8].closing_speed == 0,
            "the previous shallow nonclosing head contact")
        local last = step_frames(Bail.new(), {inside_before, inside}, finite_floor)
        check(last.result.bail and last.result.reason == "swept_body_crossing" and last.result.contact_index == 8,
            "a shallow nonclosing seed then a witnessed crossing is a swept bail")
        d = decode(body_frame(2, {-.02, 1.98 - head, -z}, {-19.2, -6, 0}), body_frame(1, {.30, 2.08 - head, -z}, {-19.2, -6, 0}), finite_floor)
        check(hits(d) == "", "finite face beneath the current center cannot authorize a crossing beyond its edge")

        -- "oblique current surface is fitted": the head on a 45 degree face.
        local q = math.sqrt(.5)
        d = decode(at(1, 8, {0, .16/q, 0}, {0, -3, 0}), nil, {surface({q, q, 0}, 0)})
        check(d.contacts[8].hit and near(d.contacts[8].normal[1], q, 1e-6) and near(d.contacts[8].separation, 0, 1e-5),
            "oblique current surface is witnessed")
        -- "finite lip cannot become an infinite collision plane beyond its
        -- edge": the lower torso guard (radius .18) on a 22 degree face that
        -- ends at x = 0. The first ray hits the face, but the foot of the
        -- center lies beyond the edge, so the witness misses.
        local slope = .4040262258
        local norm = math.sqrt(1 + slope*slope)
        local lip_n = {-slope/norm, 1/norm, 0}
        local lip = {surface(lip_n, 0, function(p) return p[1] <= 0 end)}
        d = decode(at(1, 6, {-.026, .1815, 0}, {0, -3, 0}), nil, lip)
        check(d.available and not d.contacts[6].hit and d.counts.hits >= 1 and d.counts.unwitnessed >= 1,
            "finite lip cannot become an infinite collision plane beyond its edge")
        -- The same face with the guard moved along it inside the edge.
        local along = M.mul({1/norm, slope/norm, 0}, -.2)
        local center = M.add({-.026, .1815, 0}, along)
        d = decode(at(1, 6, center, {0, -3, 0}), nil, lip)
        local row = d.contacts[6]
        local foot = M.sub(center, M.mul(lip_n, M.dot(center, lip_n)))
        check(row.hit and near(row.separation, M.dot(center, lip_n) - .18, 1e-5) and near(row.normal[1], lip_n[1], 1e-6)
            and near(row.point[1], foot[1], 1e-5) and near(row.point[2], foot[2], 1e-5),
            "the same face inside its edge is witnessed at the center's foot")

        -- guard:77: each guard keeps its smallest witnessed gap. The down ray
        -- sees a floor and the movement ray a wall, at two different gaps.
        local c1, r1 = {0, 1, 0}, Guard.guards[1].radius
        local pose = at(1, 1, c1, {1, 0, 0})
        local function two(floor_gap, wall_gap)
            return decode(pose, nil, {surface({0, 1, 0}, c1[2] - r1 - floor_gap), surface({-1, 0, 0}, -(c1[1] + r1 + wall_gap))})
                .contacts[1]
        end
        row = two(.03, .01)
        check(row.hit and near(row.normal[1], -1) and near(row.separation, .01, 1e-6), "a later smaller gap replaces an earlier one")
        row = two(.01, .03)
        check(row.hit and near(row.normal[2], 1) and near(row.separation, .01, 1e-6), "a later larger gap does not")

        -- Spin. The guard velocity is v + w x (center - com) for the current
        -- step and for the previous one, each with its own orientation.
        local function about_x(angle) return {math.sin(angle/2), 0, 0, math.cos(angle/2)} end
        local r8 = Guard.guards[8].radius
        local wall_n = {0, 0, -1}
        local function head_wall(face_z, above) return {surface(wall_n, -face_z, function(p) return p[2] > above end)} end
        local spin = body_frame(1, {0, 5, 0}, {0, 0, 0}, nil, {8, 0, 0})
        local c8 = world(spin, 8)
        local faces = head_wall(c8[3] + r8, 5.3)
        d = decode(spin, nil, faces)
        local want = -M.dot(M.point_velocity(spin.body, c8), wall_n)
        check(hits(d) == "8" and near(d.contacts[8].separation, 0, 1e-5) and near(d.contacts[8].closing_speed, want, 1e-9)
            and near(want, 8*(c8[2] - 5), 1e-12), "a flipping head closes at its point velocity (w x r)")
        r = step_frames(Bail.new(), {spin}, faces).result
        check(r.bail and r.reason == "hard_rider_contact" and r.contact_index == 8, "a spinning head strike is a hard rider contact")

        -- The previous step was spinning and tilted; the current one is at rest.
        before = body_frame(1, {0, 5, 0}, {0, 0, 0}, about_x(-.3), {12, 0, 0})
        now = body_frame(2, {0, 5, 0})
        local now8, before8 = world(now, 8), world(before, 8)
        d = decode(now, before, head_wall(now8[3] + r8, 5.3))
        want = -M.dot(M.point_velocity(before.body, before8), wall_n)
        local unturned = -M.dot(M.point_velocity(before.body, now8), wall_n)
        check(d.contacts[8].hit and near(d.contacts[8].closing_speed, want, 1e-9) and math.abs(want - unturned) > .3,
            "the previous closing uses the previous orientation's point velocity")

        -- A crossing made by rotation alone: the previous head was clear of the
        -- face only in its previous orientation.
        before = body_frame(1, {0, 5, 0}, {0, 0, 0}, about_x(-.6), {36, 0, 0})
        now = body_frame(2, {0, 5, 0}, {0, 0, 0}, nil, {36, 0, 0})
        now8, before8 = world(now, 8), world(before, 8)
        local face = now8[3] - .05
        faces = head_wall(face, 5.4)
        check(face - before8[3] > r8 + .06, "the previous head sphere was clear of the face")
        check(hits(decode(before, nil, faces)) == "", "the previous step alone has no contact")
        d = decode(now, before, faces)
        row = d.contacts[8]
        want = math.max(-M.dot(M.point_velocity(now.body, now8), wall_n), -M.dot(M.point_velocity(before.body, before8), wall_n))
        local t = (face - before8[3])/(now8[3] - before8[3])
        check(row.hit and row.swept_crossing and near(row.separation, -.05 - r8, 1e-6) and near(row.closing_speed, want, 1e-9)
            and near(row.point[2], before8[2] + (now8[2] - before8[2])*t, 1e-5), "a rotation crossing is found on the previous-to-current center path")
        last = step_frames(Bail.new(), {before, now}, faces)
        check(last.result.bail and last.result.reason == "swept_body_crossing" and last.result.contact_index == 8,
            "a rotation crossing is a swept bail")
        cases += 1
    end

    -- Composition: plan, constructed batches, decode, policy.
    do
        local quarter = math.sqrt(.5)
        local side = {0, 0, quarter, quarter} -- lying on its right side, body_up {-1,0,0}
        local g3 = M.turn(side, M.sub(Guard.guards[3].center, Geometry.com))
        local lying = {0, Guard.guards[3].radius - g3[2], 0}
        local floor = {surface({0, 1, 0}, 0)}
        local p = Bail.new()
        local first = step_frames(p, {body_frame(1, lying, nil, side)}, floor)
        check(hits(first.decoded) == "3" and first.result.tilt_steps == 1 and not first.result.bail, "the grip on the floor seeds a tilt")
        local last = step_frames(p, {body_frame(1, lying, nil, side), body_frame(2, lying, nil, side)}, floor)
        check(last.result.bail and last.result.reason == "severe_contact_tilt" and last.result.region == "frame"
            and last.result.contact_index == 3 and last.result.tilt_steps == 2 and near(last.result.alignment, 0, 1e-12),
            "a bike at rest on its side is a debounced severe tilt")

        -- Head into a beam at 5 m/s; the beam starts above the torso and grips.
        local beam = {surface({0, 0, -1}, -3, function(q) return q[2] > 1.25 end)}
        local head = M.sub(Guard.guards[8].center, Geometry.com)
        local now = body_frame(1, {0, .9, 3 - Guard.guards[8].radius - head[3]}, {0, 0, 5})
        last = step_frames(Bail.new(), {now}, beam)
        check(hits(last.decoded) == "8" and near(last.decoded.contacts[8].closing_speed, 5) and last.result.bail
            and last.result.reason == "hard_rider_contact" and last.result.contact_index == 8, "a head strike is a hard rider contact")

        -- Inverted and spinning in clear air never bails.
        p = Bail.new()
        local frames = {}
        for i = 1, 60 do frames[i] = body_frame(i, {0, 10 - i*.05, i*.1}, {0, -3, 6}, {0, 0, 1, 0}, {0, 0, 4}) end
        for i = 1, 60 do
            local plan = assert(plan_for(frames[i], frames[i - 1]))
            local decoded = guard_decode(plan, {})
            local r = p:step(Guard.policy_sample(plan, decoded))
            check(r.valid and not r.bail, "inversion and spin in clear air are not a bail")
        end
        cases += 1
    end

    -- Every plan's raw query: this read's epoch, both exclusions, cast
    -- accounting and measured rows, through the real Contact.decode. Each
    -- first batch here is otherwise a valid all-clear batch, the case where a
    -- stale batch of the same size would once have passed as fresh.
    do
        local function denied(change, reason, why)
            local frame = body_frame(2, {0, 5, 0})
            local plan = assert(plan_for(frame))
            local batch = cast(plan, {})
            change(batch)
            local w = witness_for(plan, batch)
            local d = Guard.decode(w, nil)
            check(not w.available and w.reason == reason and #w.rays == 0 and not d.available and d.reason == reason
                and #d.contacts == 0 and Guard.policy_sample(plan, d) == nil, why)
        end
        denied(function(b) b.epoch = newproxy() end, "query_epoch_mismatch", "a batch from an unknown read")
        denied(function(b) b.epoch = body_frame(1, {0, 5, 0}).query_frame.physics_epoch end, "query_epoch_mismatch",
            "a stale all-clear batch from the previous read is not fresh")
        denied(function(b) b.epoch = nil end, "query_epoch_mismatch", "a batch without an epoch")
        denied(function(b) b.local_actor_excluded = false end, "guard_exclusion_unqualified", "a batch that may have hit the rider")
        denied(function(b) b.local_actor_excluded = nil end, "guard_exclusion_unqualified", "a batch without the rider fact")
        denied(function(b) b.local_actor_excluded = 1 end, "guard_exclusion_unqualified", "a non-boolean rider fact")
        denied(function(b) b.owned_bodies_excluded = false end, "guard_exclusion_unqualified",
            "a batch that may have hit the bike's own bodies")
        denied(function(b) b.owned_bodies_excluded = nil end, "guard_exclusion_unqualified", "a batch without the owned-body fact")
        denied(function(b) b.native_casts = nil end, "malformed_available_batch", "a batch without cast accounting")
        denied(function(b) b.native_casts = 0 end, "malformed_available_batch", "fewer native casts than rays")
        denied(function(b) b.native_casts = #b.rays*2 + 1 end, "malformed_available_batch", "more than two casts per ray")
        denied(function(b) b.budget_exhausted = nil end, "guard_query_unavailable", "a batch without a budget fact")
        denied(function(b) b.budget_exhausted = true end, "guard_query_unavailable", "an exhausted batch")
        denied(function(b) b.source = {sequence = "2"} end, "guard_batch_not_raw", "a batch with an invented source field")
        denied(function(b) b.reason = "available_but_unqualified" end, "malformed_available_batch",
            "an available batch with a reason")

        -- Contact.decode alone calls a batch without the rider exclusion
        -- available, with only a force_reason saying so. The guard refuses it.
        local frame = body_frame(2, {0, 5, 0})
        local plan = assert(plan_for(frame))
        check(#plan.rays == 8 and plan.bound == nil, "a frame with its Framev1 gives a plan, with no caller-bound kind")
        local batch = cast(plan, {}); batch.local_actor_excluded = false
        local copy = Contact.decode(frame.query_frame, plan.rays, batch)
        check(copy.valid and copy.status == "available" and copy.force_reason == "actor_exclusion_unqualified"
            and witness_for(plan, batch).reason == "guard_exclusion_unqualified",
            "an available decode with an unqualified rider exclusion is refused")
        batch = cast(plan, {})
        copy = Contact.decode(frame.query_frame, plan.rays, batch)
        check(copy.valid and copy.status == "available" and not copy.force_ready,
            "the real decoder accepts this clear raw batch, without force authority")
        check(witness_for(plan, copy).reason == "guard_batch_not_raw", "a Contact.decode copy cannot stand in for the raw batch")
        check(witness_for(plan, Contact.public_snapshot(copy)).reason == "guard_batch_not_raw",
            "nor can its public snapshot")
        local d = Guard.decode(witness_for(plan, batch), nil)
        check(d.available and #d.contacts == 8 and d.contacts[1].query_serial == "2" and Guard.policy_sample(plan, d) ~= nil,
            "the raw batch itself decodes, without force_ready")
        frame.query_frame.physics_epoch = newproxy()
        frame.body.center_of_mass[2] = 20
        check(Guard.decode(witness_for(plan, batch), nil).available, "the plan keeps its own copy of the frame")

        -- Rows: measured, raw and complete. Guard 1 rests on a floor.
        local floor = {surface({0, 1, 0}, 0)}
        local floor_frame = body_frame(1, {0, Guard.guards[1].radius - (Guard.guards[1].center[2] - Geometry.com[2]), 0})
        local floor_plan = assert(plan_for(floor_frame))
        local function row_refused(change, reason, why)
            local b = cast(floor_plan, floor)
            check(b.rays[1].status == "hit", why .. ": guard 1's down ray hits the floor")
            change(b.rays[1])
            check(witness_for(floor_plan, b).reason == reason, why)
        end
        row_refused(function(r) r.surface_velocity_available = false; r.surface_velocity = nil; r.motion = "unknown" end,
            "guard_measurements_unavailable", "require_contact needs measured surface motion")
        row_refused(function(r) r.position = {r.position.x, r.position.y, r.position.z} end, "malformed_guard_hit",
            "array geometry is not a raw SDK vector")
        row_refused(function(r) r.surface_velocity = vector.create(0/0, 0, 0) end, "malformed_hit",
            "a nonfinite surface velocity")
        row_refused(function(r) r.motion = nil end, "malformed_hit", "a measured surface velocity without its motion")
        row_refused(function(r) r.body = 7 end, "malformed_guard_hit", "a hit body that is not native userdata")
        cases += 1
    end

    -- The frame every plan is made from must be one coherent, fresh,
    -- focused Framev1 read, and only its coherent successor lends history.
    do
        local function no_plan(change, why)
            local frame = body_frame(2, {0, 5, 0})
            change(frame)
            check(Guard.plan(frame) == nil, why)
        end
        no_plan(function(f) f.query_frame = false end, "a query_frame that is not a frame")
        no_plan(function(f) f.query_frame.source = nil end, "a frame without its source")
        no_plan(function(f) f.query_frame.body_handle = nil end, "a frame without its body handle")
        no_plan(function(f) f.query_frame.sample.epoch = newproxy() end, "a sample from another read")
        no_plan(function(f) f.query_frame.source.lease_handle = newproxy() end, "a source lease that is not the owner's")
        no_plan(function(f) f.query_frame.fresh = false end, "a frame its owner did not mark fresh")
        no_plan(function(f) f.query_frame.gates.focused = false end, "an unfocused frame")
        no_plan(function(f) f.query_frame.gates.menu_open = true end, "a frame read in the menu")
        no_plan(function(f) f.serial = 3 end, "a guard serial that is not the frame's")
        no_plan(function(f) f.seconds *= 2 end, "a guard step that is not the frame's")
        no_plan(function(f) f.body = table.clone(f.body); f.body.center_of_mass = {0, 6, 0} end,
            "a guard body that is not the frame's")
        no_plan(function(f) f.body.center_of_mass = {0, 6, 0} end, "a frame body that is not its sample")
        no_plan(function(f) f.query_frame = Frame.public_snapshot(f.query_frame) end, "a public snapshot without handles")
        no_plan(function(f) f.query_frame.sample.velocity.x = NAN end, "a nonfinite sample")

        local function lends(change)
            local before, now = body_frame(1, {0, 5, 0}), body_frame(2, {0, 5, .1}, {0, 0, 6})
            if change then change(before, now) end
            return assert(plan_for(now, before)).consecutive
        end
        check(lends(), "a coherent same-source successor lends sweep history")
        check(not lends(function(_, now) now.query_frame.source.context_generation = "2" end),
            "a source identity change lends no history")
        check(not lends(function(_, now)
            now.query_frame.body_handle = newproxy(); now.query_frame.owner.body_handle = now.query_frame.body_handle
        end), "a body identity change lends no history")
        check(not lends(function(before, now)
            now.query_frame.physics_epoch = before.query_frame.physics_epoch
            now.query_frame.sample.epoch = before.query_frame.physics_epoch
        end), "a relabelled read credential lends no history")
        check(not lends(function(_, now) now.query_frame.time += .01; now.query_frame.sample.time += .01 end),
            "a physical elapsed time other than one step lends no history")
        check(not lends(function(before) before.query_frame.fresh = false end), "a previous read not marked fresh lends none")
        check(not lends(function(before) before.query_frame = nil end), "a previous frame without its Framev1 lends none")
        cases += 1
    end

    -- A frame without its Framev1 has no plan. It once gave a caller-bound
    -- plan whose batches were held only to an epoch the caller matched, with
    -- no cast accounting, no measured surface motion and no body or source
    -- binding; ride_composer.lua made every plan that way. Every plan is now
    -- bound, and the composer passes its Framev1 or plans no guard at all.
    do
        local function unbound(serial, com, v)
            local f = body_frame(serial, com, v)
            f.query_frame = nil
            return f
        end
        local plan, why = Guard.plan(unbound(1, {0, 5, 0}))
        check(plan == nil and why == "invalid_guard_frame", "a frame without its Framev1 has no plan")
        local old = body_frame(1, {0, 5, 0})
        plan, why = Guard.plan({serial = old.serial, seconds = old.seconds, owner = old.owner, body = old.body})
        check(plan == nil and why == "invalid_guard_frame", "the composer's former {serial, seconds, owner, body} frame has no plan")
        local moving = body_frame(2, {0, 5, .5/6}, {0, 0, 5})
        check(not plan_for(moving, unbound(1, {0, 5, 0}, {0, 0, 5})).consecutive,
            "a previous frame without its Framev1 lends a bound one no history")
        check(plan_for(moving, body_frame(1, {0, 5, 0}, {0, 0, 5})).consecutive, "its bound predecessor does")
        cases += 1
    end

    -- Every check applies to both batches of every plan. Guard 1 rests on a
    -- floor, so the first batch has a measured hit and one witness ray, and
    -- the witness batch has a measured hit. Each edit is made to the first
    -- batch, then separately to the witness batch of an untouched first one.
    -- Some of these are refused before Contact.decode runs (the epoch, the
    -- exclusion facts, the raw schema); contact_issue keeps its own checks of
    -- the same facts, and this table pins which check refuses each and why.
    do
        local floor = {surface({0, 1, 0}, 0)}
        local floor_frame = body_frame(1, {0, Guard.guards[1].radius - (Guard.guards[1].center[2] - Geometry.com[2]), 0})
        local other_epoch = body_frame(1, floor_frame.body.center_of_mass).query_frame.physics_epoch
        local row = function(f) return function(b) f(b.rays[1]) end end
        local edits = {
            {function(b) b.epoch = newproxy() end, "query_epoch_mismatch", "guard_witness_epoch_mismatch", "an unknown epoch"},
            {function(b) b.epoch = nil end, "query_epoch_mismatch", "guard_witness_epoch_mismatch", "no epoch"},
            {function(b) b.epoch = other_epoch end, "query_epoch_mismatch", "guard_witness_epoch_mismatch",
                "another read's epoch for the same pose and serial"},
            {function(b) b.local_actor_excluded = false end, "guard_exclusion_unqualified", nil, "the rider exclusion false"},
            {function(b) b.local_actor_excluded = nil end, "guard_exclusion_unqualified", nil, "no rider exclusion fact"},
            {function(b) b.local_actor_excluded = 1 end, "guard_exclusion_unqualified", nil, "a non-boolean rider fact"},
            {function(b) b.owned_bodies_excluded = false end, "guard_exclusion_unqualified", nil, "the owned-body exclusion false"},
            {function(b) b.owned_bodies_excluded = nil end, "guard_exclusion_unqualified", nil, "no owned-body fact"},
            {function(b) b.native_casts = nil end, "malformed_available_batch", nil, "no cast accounting"},
            {function(b) b.native_casts = 0 end, "malformed_available_batch", nil, "fewer native casts than rays"},
            {function(b) b.native_casts = #b.rays*2 + 1 end, "malformed_available_batch", nil, "more than two casts per ray"},
            {function(b) b.native_casts = 1.5 end, "invalid_cast_accounting", nil, "a fractional cast count"},
            {function(b) b.budget_exhausted = nil end, "guard_query_unavailable", nil, "no budget fact"},
            {function(b) b.budget_exhausted = true end, "guard_query_unavailable", nil, "an exhausted budget"},
            {function(b) b.reason = "available_but_unqualified" end, "malformed_available_batch", nil, "an available batch with a reason"},
            {function(b) b.requested_query_preset = "bogus" end, "malformed_batch", nil, "an unknown query preset"},
            {function(b) b.source = {sequence = "2"} end, "guard_batch_not_raw", nil, "an invented source field"},
            {function(b) b.query = {} end, "guard_batch_not_raw", nil, "a decoded field"},
            {function(b) b.status = "unavailable"; b.reason = "backend" end, "backend", nil, "an unavailable batch"},
            {function(b) b.rays[1] = {status = "unavailable"} end, "guard_ray_unavailable", nil, "an unavailable row"},
            {row(function(r) r.surface_velocity_available = false; r.surface_velocity = nil; r.motion = "unknown" end),
                "guard_measurements_unavailable", nil, "a hit without measured surface motion"},
            {row(function(r) r.motion = nil end), "malformed_hit", nil, "a measured surface velocity without its motion"},
            {row(function(r) r.surface_velocity = vector.create(0/0, 0, 0) end), "malformed_hit", nil,
                "a nonfinite surface velocity"},
            {row(function(r) r.position = {r.position.x, r.position.y, r.position.z} end), "malformed_guard_hit", nil,
                "array geometry"},
            {row(function(r) r.body = 7 end), "malformed_guard_hit", nil, "a hit body that is not native userdata"},
            {row(function(r) r.visual_hit = true end), "malformed_guard_hit", nil, "a decoded row field"},
        }
        local plan = assert(plan_for(floor_frame))
        do
            local w = witness_for(plan, cast(plan, floor))
            local d = Guard.decode(w, cast(w, floor))
            check(w.available and #w.rays == 1 and d.available and hits(d) == "1", "control: both batches unedited decode")
        end
        for _, e in edits do
            local first = cast(plan, floor)
            check(first.rays[1].status == "hit", e[4] .. ": the first batch's row 1 is a measured hit")
            e[1](first)
            local w = witness_for(plan, first)
            local d = Guard.decode(w, nil)
            check(not w.available and w.reason == e[2] and not d.available and d.reason == e[2] and #d.contacts == 0
                and Guard.policy_sample(plan, d) == nil, e[4] .. " in the first batch is refused as " .. e[2])
            w = witness_for(plan, cast(plan, floor))
            check(w.available and #w.rays == 1, e[4] .. ": an unedited first batch gives one witness")
            local second = cast(w, floor)
            check(second.rays[1].status == "hit", e[4] .. ": the witness row is a measured hit")
            e[1](second)
            d = Guard.decode(w, second)
            local want = e[3] or e[2]
            check(not d.available and d.reason == want and #d.contacts == 0 and Guard.policy_sample(plan, d) == nil,
                e[4] .. " in the witness batch is refused as " .. want)
        end
        cases += 1
    end

    -- A finite face beside the witness line. Guard 3's down ray meets a tiny
    -- face 24 mm from the center's perpendicular foot, on a plane tangent to
    -- the sphere. A witness row may lie up to 25 mm off its own ray, so one
    -- reporting that same point passes the plane test; its separation is the
    -- point's own distance, outside the policy's 5 mm contact gap.
    do
        local frame = body_frame(1, {0, 5, 0})
        local plan = assert(plan_for(frame))
        local index = 3
        local r, tangent = Guard.guards[index].radius, .024
        local a = math.atan(tangent/r)
        local n = {math.sin(a), math.cos(a), 0}
        local center = world(frame, index)
        local function measured(point, ray)
            local from, to = {ray.from.x, ray.from.y, ray.from.z}, {ray.to.x, ray.to.y, ray.to.z}
            local delta = M.sub(to, from)
            return {status = "hit", position = vector.create(point[1], point[2], point[3]),
                fraction = M.dot(M.sub(point, from), delta)/M.dot(delta, delta), normal_available = true,
                normal = vector.create(n[1], n[2], n[3]), surface_velocity_available = true,
                surface_velocity = vector.create(0, 0, 0), motion = "measured"}
        end
        local face = M.sub(center, {0, r/math.cos(a), 0})
        local first = cast(plan, {})
        first.rays[index] = measured(face, plan.rays[index])
        local w = witness_for(plan, first)
        check(w.available and #w.rays == 1 and w.slots[1].guard == index, "the tilted face needs one witness")
        local d = Guard.decode(w, cast(w, {}))
        check(d.available and not d.contacts[index].hit and d.counts.unwitnessed == 1, "the witness line misses the tiny face")
        local point_gap = math.sqrt(r*r + tangent*tangent) - r
        local beside = cast(w, {}); beside.rays[1] = measured(face, w.rays[1])
        d = Guard.decode(w, beside)
        check(d.available and d.contacts[index].hit and point_gap > .005
            and near(d.contacts[index].separation, point_gap, 1e-5), "a point beside the witness line keeps its own distance")
        local sample = assert(Guard.policy_sample(plan, d))
        sample.body_up = {0, -1, 0}
        local result = Bail.new():step(sample)
        check(result.valid and not result.bail and result.tilt_steps == 0, "so its extended plane cannot seed a severe tilt")
        local foot = cast(w, {}); foot.rays[1] = measured(M.sub(center, M.mul(n, r)), w.rays[1])
        d = Guard.decode(w, foot)
        check(d.available and d.contacts[index].hit and near(d.contacts[index].separation, 0, 1e-5),
            "a witness at the foot is contact at the sphere's radius")
        cases += 1
    end

    -- Seeded parity: 1000 generated samples through one Policy, with reset and
    -- pause between some. Each result is formatted as one line and hashed. The
    -- expected hash and counts were printed by a scratch C++ program that ran
    -- this same generator against the real bmx_bail_policy.h (cl /std:c++20
    -- /W4 /WX, at aad4248), so this checks the port against the compiled C++,
    -- not just against reading it. The in-tree C++ fixture
    -- (Extension/Plugins/Test/bmx_bail_parity_fixture.inc) is not written yet.
    do
        local seed = 20261025
        local function rand() seed = seed*16807 % 2147483647; return seed end
        local function pick(n) return rand() % n end
        local function unit01() return rand()/2147483647 end
        local ups = {{0, 1, 0}, {0, 1, 0}, {0, 1, 0}, {0, 1, 0}, {0, 1, 0}, {0, 1, 0}, {1, 0, 0}, {1, 0, 0},
            {1, 0, 0}, {0, 0, 1}, {0, -1, 0}, {0, .96, .28}, {.6, .8, 0}, {0, .9995, 0}, {0, 1.0005, 0}, {0, 0, -1}}
        local normals = {{0, 1, 0}, {0, 1, 0}, {0, 1, 0}, {0, 1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, -1}, {0, 0, 1},
            {0, .96, .28}, {0, .99, .1410673597966588}, {.9682458365518543, .25, 0}, {.9682458365518543, .2499999, 0},
            {0, .9797958971132712, .2}, {.8, .6, 0}, {0, .8, .6}, {0, 1.002, 0}}
        local closings = {0, 0, 0, .3, .5, .4999999, -.05, -.0500001, 2, 2, 1.9999999, 2.5, 2.5, 5, 5, -1, 101, .2, 3, .6}
        local separations = {0, 0, 0, 0, .005, .0050001, .02, -.01, -.01, -.1, -.15, -.1500001, -.0001, .06, .001, -.05}
        local crossings = {-.5, -1.5, -1.5000001, -.0001, 0, -1.4999999}
        local residuals = {53.02, 199.9999, 200, 250, 300, 500, -1, 1e6, 2e6, 210}
        local function region(n)
            return n == 0 and "none" or n <= 7 and "frame" or n <= 13 and "torso" or "head"
        end
        local p = Bail.new()
        local serial, owner, hash = 0, 1, 0
        local counts = {}
        for step = 1, 1000 do
            local action = pick(12)
            if action == 0 then p:reset() elseif action == 1 then p:pause() end
            local s = {}
            local r = pick(25)
            if r == 0 then s.serial = serial
            elseif r == 1 then serial += 2; s.serial = serial
            elseif r == 2 then serial = 1; s.serial = 1
            elseif r == 3 then s.serial = 0
            else serial += 1; s.serial = serial end
            if pick(30) == 0 then owner = 1 + pick(3) end
            s.owner = pick(80) == 0 and 0 or owner
            s.mounted = pick(40) ~= 0
            local sec = pick(40)
            s.seconds = sec == 0 and .02 or sec == 1 and N + 5e-9 or sec == 2 and N + 2e-8 or N
            s.body_up = ups[pick(16) + 1]
            local count = pick(4)
            if pick(100) == 0 then count = 9 end
            s.contacts = {}
            for i = 1, count do
                local c = {}
                c.region = region(pick(20))
                c.available = pick(40) ~= 0
                c.hit = pick(5) ~= 0
                c.query_serial = pick(30) == 0 and s.serial - 1 or s.serial
                if pick(100) == 0 then c.point = {NAN, 0, 0} else c.point = {unit01(), 0, 0} end
                c.normal = normals[pick(16) + 1]
                c.swept_crossing = pick(8) == 0
                if c.swept_crossing then c.separation = crossings[pick(6) + 1] else c.separation = separations[pick(16) + 1] end
                if pick(4) == 0 then c.closing_speed = unit01()*6 - 1 else c.closing_speed = closings[pick(20) + 1] end
                s.contacts[i] = c
            end
            s.residual_available = pick(3) == 0
            s.residual_impulse_ns = residuals[pick(10) + 1]
            local out = p:step(s)
            local index = out.bail and out.contact_index - 1 or 0
            local line = string.format("%d %d%d%d %s %s %s %d %.17g %.17g %d\n", step, out.valid and 1 or 0,
                out.bail and 1 or 0, out.latched and 1 or 0, out.issue, out.reason, out.region, index,
                out.alignment, out.closing_speed, out.tilt_steps)
            for i = 1, #line do hash = (hash*31 + string.byte(line, i)) % 2147483647 end
            counts[out.reason] = (counts[out.reason] or 0) + 1
            counts[out.issue] = (counts[out.issue] or 0) + 1
        end
        check(hash == 776057259, "seeded results match the compiled C++ Policy line for line")
        check(counts.hard_rider_contact == 26 and counts.severe_contact_tilt == 21 and counts.large_frame_impact_proxy == 3
            and counts.swept_body_crossing == 3 and counts.invalid_sample == 420 and counts.unsupported_step == 41
            and counts.stale_contact == 14 and counts.none == 1472, "the seeded run covers every reason and issue")
        cases += 1
    end
    return {cases = cases, assertions = assertions, native_actions = 0}
end
return tests
