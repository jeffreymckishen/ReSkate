-- Authored local defaults, not measured Skate rules. C0 calibration is pending.
local Rules = {}
Rules.MAX_SCORE = 9007199254740992 -- 2^53, the last consecutive integer in a double.
Rules.MAX_SEQUENCE = 16
Rules.MAX_REPEAT_KEYS = 128
Rules.MAX_AIR_SECONDS = 120
Rules.MAX_HALF_TURNS = 32
local spec = {
    hold_bonus = { .5, 0, 2 }, hold_seconds = { .5, .01, 10 },
    catch_step = { .5, 0, 2 }, overlap_fraction = { .5, .01, 1 }, overlap_factor = { 1.25, 1, 3 },
    repeat_step = { .25, 0, 1 }, repeat_floor = { .1, 0, 1 },
    rotation_step = { .25, 0, 1 }, flip_rotation_step = { .5, 0, 2 }, rotation_cap = { 3, 1, 10 },
    spin_base = { 150, 0, 1000000 }, spin_step = { .25, 0, 2 },
    flip_single = { 600, 0, 1000000 }, flip_double = { 1500, 0, 1000000 },
    combo_step = { .2, 0, 1 }, combo_cap = { 2, 1, 10 },
    air_rate = { 100, 0, 1000000 }, air_free_seconds = { .5, 0, 10 },
    clean_alignment = { .966, 0, 1 }, clean_heading = { .966, 0, 1 },
    clean_closing = { 5.5, 0, 100 }, sketchy_factor = { .7, 0, 1 },
    hop_base = { 50, 0, 1000000 }, hop_min_seconds = { .25, 0, 10 },
    category_step = { .5, 0, 2 }, link_step = { .25, 0, 2 }, multiplier_cap = { 4, 1, 16 },
    max_links = { 4, 0, 16 }, link_seconds = { .5, 0, 10 },
    line_seconds = { 2.5, .01, 60 }, idle_speed = { .3, 0, 10 }, idle_seconds = { 1, .01, 60 },
    manual_rate = { 120, 0, 1000000 }, nose_manual_rate = { 150, 0, 1000000 },
    manual_min_seconds = { .3, 0, 10 }, manual_max_seconds = { 10, .01, 60 },
    grind_lock = { 100, 0, 1000000 }, grind_change = { 100, 0, 1000000 },
    double_peg_rate = { 60, 0, 1000000 }, feeble_rate = { 80, 0, 1000000 },
    smith_rate = { 100, 0, 1000000 }, icepick_rate = { 110, 0, 1000000 },
    toothpick_rate = { 110, 0, 1000000 }, stall_base = { 150, 0, 1000000 },
    stall_rate = { 200, 0, 1000000 }, stall_max_seconds = { .75, 0, 10 },
}
local bases = { 100, 200, 350, 550, 800 }
function Rules.finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
function Rules.sanitize(input)
    local source, out = type(input) == "table" and input or {}, {}
    for key, row in pairs(spec) do
        local value = rawget(source, key)
        out[key] = Rules.finite(value) and math.clamp(value, row[2], row[3]) or row[1]
    end
    out.max_links = math.floor(out.max_links)
    out.manual_min_seconds = math.min(out.manual_min_seconds, out.manual_max_seconds)
    out.base = {}
    local incoming = rawget(source, "base")
    for i = 1, 5 do
        local value = type(incoming) == "table" and rawget(incoming, i) or nil
        out.base[i] = Rules.finite(value) and math.clamp(value, 0, 1000000) or bases[i]
    end
    table.freeze(out.base)
    return table.freeze(out)
end
Rules.defaults = Rules.sanitize(nil)
return table.freeze(Rules)
