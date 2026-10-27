-- Pure presentation of normalized, direction-neutral scoring parts. The caller
-- groups cumulative catches and supplies rotation/entry intervals, not recovery.
local Names = { MAX_PARTS=16, MAX_LENGTH=160 }
local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function integer(value, low, high)
    return finite(value) and value % 1 == 0 and value >= low and value <= high
end
local function count(value)
    if value == nil then return 0 end
    return integer(value, 0, 32) and value or nil
end
local function repeated(display, amount)
    if amount == 1 then return display end
    if amount == 2 then return "Double " .. display end
    if amount == 3 then return "Triple " .. display end
    return tostring(amount) .. "x " .. display
end
local function intervals_copy(source, start, finish)
    if source == nil then return {{start=start,finish=finish}} end
    if not plain(source) then return nil end
    local size, highest = 0, 0
    for key in next, source do
        size += 1
        if size > Names.MAX_PARTS or not integer(key, 1, Names.MAX_PARTS) then return nil end
        highest = math.max(highest, key)
    end
    if size == 0 or highest ~= size then return nil end
    local out, first, last = {}, math.huge, -math.huge
    for i = 1, size do
        local interval = rawget(source, i)
        if not plain(interval) then return nil end
        local a, b = rawget(interval, "start"), rawget(interval, "finish")
        if not finite(a) or not finite(b) or a < start or b > finish or b < a then return nil end
        out[i] = {start=a,finish=b}
        first, last = math.min(first,a), math.max(last,b)
    end
    if first ~= start or last ~= finish then return nil end
    return out
end
local function overlaps(a, b)
    for _, left in ipairs(a.intervals) do
        for _, right in ipairs(b.intervals) do
            if math.max(left.start,right.start) < math.min(left.finish,right.finish) then return true end
        end
    end
    return false
end
local function parts_copy(source)
    if source == nil then return {} end
    if not plain(source) then return nil end
    local size, highest = 0, 0
    for key in next, source do
        size += 1
        if size > Names.MAX_PARTS or not integer(key, 1, Names.MAX_PARTS) then return nil end
        highest = math.max(highest, key)
    end
    if highest ~= size then return nil end
    local out = {}
    for i = 1, size do
        local part = rawget(source, i)
        if not plain(part) then return nil end
        local key, display = rawget(part, "key"), rawget(part, "display")
        local start, finish = rawget(part, "start"), rawget(part, "finish")
        local amount = rawget(part, "count")
        if amount == nil then amount = 1 end
        if type(key) ~= "string" or #key > 48 or not string.match(key, "^[a-z][a-z0-9_]*$")
            or type(display) ~= "string" or #display == 0 or #display > 48
            or string.find(display, "[^ -~]") or not integer(amount, 1, Names.MAX_PARTS)
            or not finite(start) or not finite(finish) or start < 0 or finish < start then return nil end
        local intervals = intervals_copy(rawget(part,"intervals"),start,finish)
        if not intervals then return nil end
        out[i] = { key=key, display=display, count=amount, start=start, finish=finish,
            order=i, intervals=intervals }
    end
    table.sort(out, function(a, b)
        if a.start ~= b.start then return a.start < b.start end
        if a.finish ~= b.finish then return a.finish < b.finish end
        return a.order < b.order
    end)
    return out
end
function Names.format(descriptor)
    if not plain(descriptor) then return "Trick" end
    local parts = parts_copy(rawget(descriptor, "parts"))
    local spin = count(rawget(descriptor, "spin_half_turns"))
    local front = count(rawget(descriptor, "front_flips"))
    local back = count(rawget(descriptor, "back_flips"))
    local roll = count(rawget(descriptor, "barrel_rolls"))
    local fakie, heading = rawget(descriptor, "fakie_takeoff"), rawget(descriptor, "heading_cos")
    if not parts or not spin or not front or not back or not roll
        or (fakie ~= nil and type(fakie) ~= "boolean")
        or (heading ~= nil and (not finite(heading) or math.abs(heading) > 1)) then return "Trick" end
    local truck_index
    for i, part in ipairs(parts) do
        if part.key == "barspin" and ((spin == 2 and part.count == 1)
            or (spin == 4 and part.count == 2)) then truck_index = i; break end
    end
    local prefix = {}
    if fakie and spin == 1 then
        table.insert(prefix, "Half Cab")
    else
        if fakie then table.insert(prefix, "Fakie") end
        if spin > 0 and not truck_index then table.insert(prefix, tostring(spin * 180)) end
    end
    for _, axis in ipairs({ {front,"Frontflip"}, {back,"Backflip"}, {roll,"Barrel Roll"} }) do
        if axis[1] > 0 then table.insert(prefix, repeated(axis[2], axis[1])) end
    end
    local sequence = {}
    for i, part in ipairs(parts) do
        if i > 1 then
            local previous = parts[i-1]
            -- Compare adjacent entries, not a transitive overlap union: a long
            -- pose must not make two separate catches appear simultaneous.
            -- A grouped catch keeps its individual intervals: the gap between
            -- two barspins must not count as overlap with a tailwhip.
            table.insert(sequence, overlaps(previous,part) and " + " or " to ")
        end
        local display = i == truck_index and repeated("Truckdriver", part.count)
            or repeated(part.display, part.count)
        table.insert(sequence, display)
    end
    if #sequence > 0 then table.insert(prefix, table.concat(sequence)) end
    if #sequence == 0 and spin == 0 and front == 0 and back == 0 and roll == 0 then
        table.insert(prefix, "Bunny Hop")
    end
    local text = table.concat(prefix, " ")
    if heading and heading < 0 then text ..= " to Fakie" end
    -- Catalog labels are ASCII; truncation cannot split a multibyte character.
    if #text > Names.MAX_LENGTH then text = string.sub(text, 1, Names.MAX_LENGTH - 3) .. "..." end
    return text
end
return table.freeze(Names)
