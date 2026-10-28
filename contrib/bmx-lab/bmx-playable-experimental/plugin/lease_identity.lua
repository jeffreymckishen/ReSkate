-- Exact native input identifiers. These numbers never become a device slot,
-- physics epoch, Lua wall-clock timestamp, or ownership credential.
local Identity = {}
local MAX_U64 = "18446744073709551615"
local MAX_SAFE = 9007199254740991

-- Whether a string is a canonical uint64 depends on the string alone. Serials
-- and counters are compared many times a tick (each compare checks both), so
-- the strings already judged are remembered; the set is emptied when it grows
-- past a few hundred, as each tick brings a few new serials.
local judged, judged_count = {}, 0
function Identity.is_u64(value)
    if type(value) ~= "string" or #value == 0 or #value > 20 then return false end
    if value == "0" then return true end
    local known = judged[value]
    if known ~= nil then return known end
    known = value:match("^[1-9][0-9]*$") ~= nil and (#value < 20 or value <= MAX_U64)
    if judged_count >= 512 then table.clear(judged); judged_count = 0 end
    judged[value], judged_count = known, judged_count + 1
    return known
end

Identity.valid_u64 = Identity.is_u64

function Identity.is_nonzero_u64(value)
    return Identity.is_u64(value) and value ~= "0"
end

function Identity.compare(a, b)
    if not Identity.is_u64(a) or not Identity.is_u64(b) then return nil, "invalid uint64" end
    if a == b then return 0 end
    if #a ~= #b then return #a < #b and -1 or 1 end
    return a < b and -1 or 1
end

function Identity.bounded_delta(later, earlier, limit)
    if type(limit) ~= "number" or limit ~= limit or limit < 0 or limit > MAX_SAFE or
        math.floor(limit) ~= limit then return nil, "invalid difference bound" end
    local order = Identity.compare(later, earlier)
    if order == nil then return nil, "invalid uint64" end
    if order < 0 then return nil, "clock regressed" end
    if order == 0 then return 0 end

    -- Subtract at most twenty digits before converting only the bounded result.
    -- No absolute native uint64 value passes through tonumber or floating point.
    local digits, borrow = {}, 0
    local j = #earlier
    for i = #later, 1, -1 do
        local a = string.byte(later, i) - 48 - borrow
        local b = j > 0 and string.byte(earlier, j) - 48 or 0
        local digit = a - b
        borrow = digit < 0 and 1 or 0
        digits[i] = digit < 0 and digit + 10 or digit
        j -= 1
    end
    local result = 0
    for i = 1, #digits do
        local digit = digits[i]
        if result > math.floor((limit - digit) / 10) then return nil, "difference exceeds bound" end
        result = result * 10 + digit
    end
    return result
end

Identity.exact_bounded_delta = Identity.bounded_delta
return table.freeze(Identity)
