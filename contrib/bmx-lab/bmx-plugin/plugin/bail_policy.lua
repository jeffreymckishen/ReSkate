-- Port of Engine/Game/BMX/bmx_bail_policy.h; "h:N" below cites its lines.
-- Classification only: it never requests a fall, moves a body, reads native
-- state or chooses a recovery. The caller owns every query and must supply
-- freshly measured guard contacts. A query that was not made is not clear.
-- The thresholds are the retained C++ initial prototype values (h:44). They
-- are authored here, not recovered BMX Streets settings.
local Bail = {}
local MAX_SAFE = 9007199254740991
local MAX_U64 = "18446744073709551615"
-- h:38 holds eight GuardContact rows; a longer list is invalid (h:106).
Bail.MAX_CONTACTS = 8
-- h:9 is the float 1/60 native step, kept as its exact double value.
Bail.native_seconds = .01666666567325592
Bail.regions = table.freeze({"none", "frame", "torso", "head"}) -- h:10
Bail.reasons = table.freeze({"none", "hard_rider_contact", "severe_contact_tilt",
    "large_frame_impact_proxy", "swept_body_crossing"}) -- h:11
Bail.issues = table.freeze({"none", "invalid_sample", "unsupported_step", "stale_contact"}) -- h:12

local tuning_names = {"contact_gap", "maximum_penetration", "hard_rider_closing", "severe_alignment",
    "immediate_tilt_closing", "slow_opening_limit", "normal_continuity", "slow_tilt_steps",
    "frame_proxy_impulse", "frame_proxy_closing", "swept_penetration", "swept_closing"}
local defaults = {
    contact_gap = .005, maximum_penetration = .15, -- h:46
    hard_rider_closing = 2, severe_alignment = .25, immediate_tilt_closing = .5, -- h:47
    slow_opening_limit = .05, normal_continuity = .95, -- h:48
    slow_tilt_steps = 2, -- h:49
    frame_proxy_impulse = 200, frame_proxy_closing = 2, -- h:50
    swept_penetration = 1.5, swept_closing = .5, -- h:51
}
local body_regions = {frame = true, torso = true, head = true} -- h:122, frame through head

local function plain(v) return type(v) == "table" and getmetatable(v) == nil end
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function within(x, lo, hi) return finite(x) and x >= lo and x <= hi end
local function dot(a, b) return a[1]*b[1] + a[2]*b[2] + a[3]*b[3] end -- h:67, same summation order

-- h:63-66: every component finite and no larger than the limit.
local function vec(v, limit)
    if not plain(v) then return nil end
    local out = {}
    for i = 1, 3 do
        local x = rawget(v, i)
        if not finite(x) or math.abs(x) > limit then return nil end
        out[i] = x
    end
    return out
end
local function unit(v) -- h:68
    local c = vec(v, 2)
    if c and math.abs(dot(c, c) - 1) <= .001 then return c end
    return nil
end

-- Serials are u64 values: an exact integer up to 2^53-1 or a canonical decimal
-- string, as native sample serials arrive. Both become one decimal key so the
-- consecutive test (h:115) never passes an absolute u64 through a double.
local function serial_key(v)
    if type(v) == "number" then
        if v == v and v >= 0 and v <= MAX_SAFE and v % 1 == 0 then return string.format("%d", v) end
        return nil
    end
    if type(v) ~= "string" or #v == 0 or #v > 20 or not string.match(v, "^%d+$") then return nil end
    if #v > 1 and string.sub(v, 1, 1) == "0" then return nil end
    if #v == 20 and v > MAX_U64 then return nil end
    return v
end
-- Decimal increment. The successor of the largest u64 has 21 digits, so it can
-- never equal a valid key, matching the C++ wrap to the refused serial 0.
local function successor(key)
    local digits = {string.byte(key, 1, #key)}
    local i = #digits
    while i >= 1 and digits[i] == 57 do digits[i] = 48; i -= 1 end
    if i == 0 then table.insert(digits, 1, 49) else digits[i] += 1 end
    return string.char(table.unpack(digits))
end

-- C++ Owner (h:13-18) bundles native pointers with a mount token. Lua instead
-- takes one opaque token compared with rawequal: userdata, a short string or
-- a positive integer. It must change for every new mount, and it must never
-- be a game address; the shape of a token proves no ownership by itself.
local function token(v)
    return type(v) == "userdata" or (type(v) == "string" and #v > 0 and #v <= 128)
        or (type(v) == "number" and v == v and v >= 1 and v <= MAX_SAFE and v % 1 == 0)
end

function Bail.defaults()
    local out = {}
    for _, name in ipairs(tuning_names) do out[name] = defaults[name] end
    return out
end
-- h:72-85. Unknown keys also fail, so a misspelt override cannot silently
-- leave its default in force.
function Bail.valid_tuning(t)
    if not plain(t) then return false end
    for key in pairs(t) do if defaults[key] == nil then return false end end
    local steps = rawget(t, "slow_tilt_steps")
    return within(t.contact_gap, 0, .01) and within(t.maximum_penetration, 0, .25)
        and finite(t.hard_rider_closing) and t.hard_rider_closing > 0 and t.hard_rider_closing <= 20
        and within(t.severe_alignment, -1, .5) and within(t.immediate_tilt_closing, 0, 20)
        and within(t.slow_opening_limit, 0, .1) and within(t.normal_continuity, .5, 1)
        -- h:49 and h:80: an unsigned frame count from 2 to 6.
        and type(steps) == "number" and steps % 1 == 0 and steps >= 2 and steps <= 6
        -- h:81 keeps the frame proxy above the 53.02 N*s residual of a known
        -- successful landing (Run87, recorded in the C++ test).
        and finite(t.frame_proxy_impulse) and t.frame_proxy_impulse > 53 and t.frame_proxy_impulse <= 10000
        and finite(t.frame_proxy_closing) and t.frame_proxy_closing > 0 and t.frame_proxy_closing <= 20
        and finite(t.swept_penetration) and t.swept_penetration >= t.maximum_penetration
        and t.swept_penetration <= 1.5
        and finite(t.swept_closing) and t.swept_closing > 0 and t.swept_closing <= 20
end
local function merge(overrides)
    if overrides ~= nil and not plain(overrides) then return nil end
    local out = Bail.defaults()
    for key, value in pairs(overrides or {}) do out[key] = value end
    return out
end
-- Returns the merged tuning and whether it is valid. An invalid tuning is not
-- an error here: like the C++, every mounted step then reports invalid_sample.
function Bail.tuning(overrides)
    local out = merge(overrides)
    if not out then return nil, false end
    return table.freeze(out), Bail.valid_tuning(out)
end

local function contacts_list(t)
    if t == nil then return {} end
    if not plain(t) then return nil end
    local n = 0
    for key in pairs(t) do
        n += 1
        if n > Bail.MAX_CONTACTS or type(key) ~= "number" or key % 1 ~= 0 or key < 1 then return nil end
    end
    local out = {}
    for i = 1, n do
        local row = rawget(t, i)
        if row == nil then return nil end
        out[i] = row
    end
    return out
end
-- Every check of h:122-124 that does not depend on history is folded into bad.
-- A row that is not a table, or whose hit flag is not a boolean, is treated
-- as a malformed hit so it can never be skipped as if it were clear.
local function contact_copy(raw, t)
    if not plain(raw) then return {hit = true, bad = true} end
    local hit = rawget(raw, "hit")
    if hit == false then return {hit = false} end -- h:121 skips rows without a hit
    if hit ~= true then return {hit = true, bad = true} end
    local swept = rawget(raw, "swept_crossing")
    if swept == nil then swept = false end -- the C++ member default (h:30)
    local region = rawget(raw, "region")
    local c = {hit = true, region = region, point = vec(rawget(raw, "point"), 1e6),
        normal = unit(rawget(raw, "normal")), separation = rawget(raw, "separation"),
        closing_speed = rawget(raw, "closing_speed"), swept = swept,
        query = serial_key(rawget(raw, "query_serial"))}
    c.bad = rawget(raw, "available") ~= true or type(region) ~= "string" or not body_regions[region]
        or not c.point or not c.normal or not finite(c.separation) or not finite(c.closing_speed)
        or math.abs(c.closing_speed) > 100 or type(swept) ~= "boolean"
        or c.separation < -(swept and t.swept_penetration or t.maximum_penetration)
        or not c.query
    return c
end
local function copy_contacts(list, t)
    local out = {}
    for i = 1, #list do out[i] = contact_copy(list[i], t) end
    return out
end
-- h:104-112. Returns nil and an issue for a sample the C++ refuses before
-- looking at history. Contact rows are only collected here; they are checked
-- after the duplicate-serial test, in C++ order.
local function read(s, tuning_ok)
    if not plain(s) then return nil, "invalid_sample" end
    local mounted = rawget(s, "mounted")
    if mounted == false then return {mounted = false} end
    if mounted ~= true then return nil, "invalid_sample" end
    local owner, key, up = rawget(s, "owner"), serial_key(rawget(s, "serial")), unit(rawget(s, "body_up"))
    local list = contacts_list(rawget(s, "contacts"))
    local residual_available = rawget(s, "residual_available")
    if residual_available == nil then residual_available = false end
    local residual = rawget(s, "residual_impulse_ns")
    if not tuning_ok or not token(owner) or not key or key == "0" or not up or not list
        or type(residual_available) ~= "boolean"
        or residual_available and (not finite(residual) or residual < 0 or residual > 1e6) then
        return nil, "invalid_sample"
    end
    local seconds = rawget(s, "seconds")
    if not finite(seconds) or math.abs(seconds - Bail.native_seconds) > 1e-8 then
        return nil, "unsupported_step"
    end
    return {mounted = true, owner = owner, key = key, up = up, list = list,
        residual_available = residual_available, residual = residual}
end
local function result(latched)
    return {valid = false, bail = false, latched = latched, issue = "none", reason = "none",
        region = "none", contact_index = 0, alignment = 0, closing_speed = 0, tilt_steps = 0}
end

-- contact_index is the 1-based row of the triggering contact, 0 without a
-- bail; the C++ reports the 0-based index.
function Bail.new(overrides)
    local tuning = merge(overrides)
    local tuning_ok = tuning ~= nil and Bail.valid_tuning(tuning)
    if tuning then table.freeze(tuning) end
    local P = {owner = nil, serial = nil, latched = false, tilt_region = "none", tilt_normal = {0, 0, 0}, tilt_steps = 0}
    local function clear_tilt() P.tilt_region = "none"; P.tilt_normal = {0, 0, 0}; P.tilt_steps = 0 end
    local function clear_history() P.serial = nil; clear_tilt() end -- h:95
    local object = {}
    function object:reset() P.owner = nil; P.latched = false; clear_history() end -- h:98
    -- h:99-101: pause discards time and contact history but cannot replay an
    -- already fired bail for the same mount. Only reset or a new owner rearms.
    function object:pause() clear_history() end
    function object:status()
        return table.freeze({latched = P.latched, tilt_steps = P.tilt_steps, observed = P.serial ~= nil,
            owned = P.owner ~= nil, tuning_valid = tuning_ok})
    end
    function object:tuning() return tuning and table.clone(tuning) or nil end
    function object:step(s)
        local out = result(P.latched) -- h:103
        local ok, sample, issue = pcall(read, s, tuning_ok)
        if not ok then sample, issue = nil, "invalid_sample" end
        if sample and not sample.mounted then clear_history(); out.valid = true; return table.freeze(out) end -- h:104
        if not sample then clear_history(); out.issue = issue; return table.freeze(out) end -- h:108, h:111
        if not rawequal(sample.owner, P.owner) then -- h:113
            P.owner = sample.owner; P.latched = false; clear_history(); out.latched = false
        end
        -- h:114: a duplicate call cannot earn another frame.
        if sample.key == P.serial then out.valid = true; return table.freeze(out) end
        local consecutive = P.serial ~= nil and sample.key == successor(P.serial) -- h:115
        if not consecutive then clear_tilt() end -- h:116
        local copied, contacts = pcall(copy_contacts, sample.list, tuning)
        if not copied then clear_history(); out.issue = "invalid_sample"; return table.freeze(out) end
        -- h:117-129: validate every supplied hit before evaluating any trigger.
        -- A stale or malformed later entry must not be hidden by an earlier
        -- severe hit.
        for i = 1, #contacts do
            local c = contacts[i]
            if c.hit then
                if c.bad or c.swept and (not consecutive or c.separation >= 0) then
                    clear_history(); out.issue = "invalid_sample"; return table.freeze(out)
                end
                if c.query ~= sample.key then clear_history(); out.issue = "stale_contact"; return table.freeze(out) end
            end
        end
        P.serial = sample.key; out.valid = true -- h:130
        if P.latched then out.latched = true; return table.freeze(out) end -- h:131
        local function trigger(reason, c, index, alignment) -- h:132-135
            P.latched = true; out.bail = true; out.latched = true; out.reason = reason
            out.region = c.region; out.contact_index = index; out.alignment = alignment
            out.closing_speed = c.closing_speed
        end
        local slow, slow_index, slow_alignment = nil, 0, 1 -- h:136
        for i = 1, #contacts do -- h:137-159
            local c = contacts[i]
            if c.hit and c.separation <= tuning.contact_gap then
                local alignment = dot(sample.up, c.normal)
                if c.swept and c.closing_speed >= tuning.swept_closing then
                    trigger("swept_body_crossing", c, i, alignment); return table.freeze(out)
                end
                if (c.region == "head" or c.region == "torso") and c.closing_speed >= tuning.hard_rider_closing then
                    trigger("hard_rider_contact", c, i, alignment); return table.freeze(out)
                end
                if alignment < tuning.severe_alignment then
                    if c.closing_speed >= tuning.immediate_tilt_closing then
                        trigger("severe_contact_tilt", c, i, alignment); return table.freeze(out)
                    end
                    if c.closing_speed >= -tuning.slow_opening_limit and alignment < slow_alignment then
                        slow, slow_index, slow_alignment = c, i, alignment
                    end
                end
                if c.region == "frame" and sample.residual_available and
                    sample.residual >= tuning.frame_proxy_impulse and c.closing_speed >= tuning.frame_proxy_closing then
                    trigger("large_frame_impact_proxy", c, i, alignment); return table.freeze(out)
                end
            end
        end
        if slow then -- h:160-165
            local same = consecutive and P.tilt_region == slow.region
                and dot(P.tilt_normal, slow.normal) >= tuning.normal_continuity
            P.tilt_steps = same and P.tilt_steps + 1 or 1
            P.tilt_region = slow.region; P.tilt_normal = slow.normal
            out.tilt_steps = P.tilt_steps
            if P.tilt_steps >= tuning.slow_tilt_steps then
                trigger("severe_contact_tilt", slow, slow_index, slow_alignment)
            end
        else
            clear_tilt()
        end
        return table.freeze(out)
    end
    return table.freeze(object)
end
return table.freeze(Bail)
