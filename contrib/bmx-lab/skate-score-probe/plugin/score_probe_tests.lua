-- Synthetic source tests only. No SDK/game imports or live observation.
local Recorder = require("./recorder")
local KEY = "skate_score_probe_v1"
local cases, assertions = {}, 0
local function check(condition, message)
    assertions = assertions + 1
    assert(condition, message)
end
local function test(name, body) cases[#cases + 1] = { name, body } end

-- Independent bounded-data test encoder. Production always uses reskate.json.encode.
local function quote(value)
    return '"' .. string.gsub(value, '[%z\1-\31\\"]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        return string.format('\\u%04x', string.byte(c))
    end) .. '"'
end
local function json(value)
    local kind = type(value)
    if kind == "string" then return quote(value) end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        assert(value == value and value ~= math.huge and value ~= -math.huge, "finite JSON")
        return string.format("%.17g", value)
    end
    if kind == "nil" then return "null" end
    assert(kind == "table", "plain test JSON data")
    local keys = {}
    for key in pairs(value) do keys[#keys + 1] = key end
    local array = #keys > 0
    for _, key in ipairs(keys) do
        if type(key) ~= "number" or key < 1 or key > #keys or key % 1 ~= 0 then array = false end
    end
    local rows = {}
    if array then
        for i = 1, #keys do rows[#rows + 1] = json(value[i]) end
        return "[" .. table.concat(rows, ",") .. "]"
    end
    table.sort(keys)
    for _, key in ipairs(keys) do rows[#rows + 1] = quote(key) .. ":" .. json(value[key]) end
    return "{" .. table.concat(rows, ",") .. "}"
end
local function fresh(encoder)
    local r = Recorder.new(encoder or json)
    r:time(100)
    return r
end
local function score(line)
    return { line = line, multiplier = 1.5, in_trick = false, trick = "Ollie", detail = "Clean", manual = false }
end
local function fake()
    local f = { now = 1000, stores = 0, gets = 0, polls = 0, handlers = {}, logs = {}, fail = false }
    f.sdk = {
        json = { encode = json },
        time = { now = function() if f.clock_error then error("clock unavailable") end; return f.now end },
        score = { current = function()
            f.polls = f.polls + 1
            if f.score_error then error("HUD unavailable") end
            return f.current
        end },
        storage = {
            get = function(key)
                f.gets = f.gets + 1
                check(key == KEY, "private key read")
                if f.prior ~= nil then return f.prior end
                return f.saved
            end,
            keys = function() return f.keys or (f.saved and { KEY } or {}) end,
            set = function(key, value)
                f.stores = f.stores + 1
                check(key == KEY, "only owned storage key written")
                check(#json({ [key] = value }) <= 256 * 1024, "whole keyed storage JSON bounded")
                if f.fail then error("synthetic storage refusal") end
                f.saved = value
            end,
        },
        on = function(event, handler)
            check(f.handlers[event] == nil, "one handler per event")
            f.handlers[event] = handler
        end,
        log = function(message) f.logs[#f.logs + 1] = message end,
    }
    return f
end

test("actual event payloads and opaque note identity", function()
    local r = fresh()
    r:event("trick_started", {}, 100)
    r:event("trick_landed", { points = 12.5, multiplier = 2, name = "Ollie", ms = 350 }, 450)
    r:event("line_broken", { reason = "slam" }, 460)
    r:event("trick_notes", { notes = { { entry = "18446744073709551615", kind = "l", text = "Clean" } } }, 461)
    local rows = r:report().rows
    check(#rows == 4, "all four event types retained")
    check(rows[2].ms == 350 and rows[2].observed_ms == 450 and rows[2].elapsed_ms == 350, "duration and observation clocks distinct")
    check(rows[2].points == 12.5 and rows[2].multiplier == 2 and rows[2].name == "Ollie", "SDK fields unchanged")
    check(rows[4].entry == "18446744073709551615", "uint64 identity never converted to a number")
    check(rows[1].at == nil and rows[3].reason == "slam", "positions omitted; actual reason preserved")
end)

test("score changes include nil and query errors", function()
    local r = fresh()
    r:score(nil, true, 100)
    r:score(nil, true, 101)
    r:score(score(10), true, 102)
    r:score(score(10), true, 103)
    r:score(score(11), true, 104)
    r:score(nil, false, 105)
    r:score(nil, true, 106)
    local rows = r:report().rows
    check(#rows == 5, "unchanged observations deduplicated")
    check(rows[1].available == false and rows[1].line == nil, "unavailable is not zero")
    check(rows[2].available and rows[2].in_trick == false and rows[2].manual == false, "actual booleans retained")
    check(rows[4].reason == "api_error" and rows[5].reason == "unavailable", "query failure distinguished from nil")
end)

test("ring evicts oldest rows and keeps sequence", function()
    local r = fresh()
    for i = 1, 2001 do r:event("trick_started", {}, 100 + i) end
    local report = r:report()
    check(report.row_count == 2000 and #report.rows == 2000, "row hard limit")
    check(report.rows[1].seq == 2 and report.rows[2000].seq == 2001, "chronological retained suffix")
    check(report.counters.rows_evicted == 1, "eviction visible")
end)

test("byte cap includes escaped text and storage key", function()
    local r, stored = fresh(), nil
    for i = 1, 2000 do
        r:event("trick_landed", { points = i, multiplier = 1.5, name = string.rep('"', 160), ms = 123 }, 100 + i)
    end
    check(r.count < 2000, "bytes can evict before row limit")
    check(r:persist(function(key, report) stored = { [key] = report } end, 2200, true), "bounded checkpoint accepted")
    check(#json(stored) <= 256 * 1024, "key and metadata included in byte bound")
    check(stored[KEY].counters.rows_evicted > 0, "byte eviction reported")
end)

test("bounded UTF8 text does not cut characters", function()
    local r = fresh()
    local euro = string.char(226, 130, 172)
    r:event("line_broken", { reason = string.rep("a", 159) .. euro }, 100)
    r:event("line_broken", { reason = string.char(224, 128, 128, 0) .. "ok" }, 101)
    local report = r:report()
    check(#report.rows[1].reason == 159, "whole multibyte suffix omitted")
    check(report.rows[2].reason == "????ok", "invalid UTF8 and control bytes sanitized")
    check(report.counters.text_truncations == 1 and report.counters.text_sanitizations == 1, "text information loss counted")
end)

test("note batches are bounded without inventing payload shape", function()
    local r, notes = fresh(), {}
    for i = 1, 40 do notes[i] = { entry = tostring(i), kind = "n", text = "Ollie" } end
    r:event("trick_notes", { notes = notes }, 100)
    r:event("trick_notes", { kind = "l", text = "not the SDK shape" }, 101)
    local report = r:report()
    check(report.row_count == 33 and report.counters.notes_omitted == 8, "bounded notes plus malformed diagnostic")
    check(report.rows[33].payload_status == "malformed", "unsupported prose shape not invented")
end)

test("malformed numeric and note fields are not coerced", function()
    local r = fresh()
    r:event("trick_landed", { points = 0/0, multiplier = 1, name = "Ollie", ms = 1 }, 100)
    r:event("trick_notes", { notes = { { entry = 9007199254740992, kind = "n", text = "Ollie" } } }, 101)
    r:score({ line = math.huge, multiplier = 1, in_trick = false, manual = false, trick = "", detail = "" }, true, 102)
    local report = r:report()
    check(report.counters.malformed_payloads == 3, "malformed inputs counted")
    check(report.rows[1].points == nil and report.rows[2].entry == nil and report.rows[3].line == nil, "no invented measured values")
    check(#json(report) > 0, "malformed input never reaches JSON as nonfinite data")
end)

test("clock failure stops rather than fabricating zero", function()
    local r = fresh()
    r:event("trick_started", {}, 100)
    check(r:time(99) == nil, "regression refused")
    r:event("trick_started", {}, 100)
    local report = r:report()
    check(report.collection_state == "clock_regressed" and report.row_count == 1, "observation halted")
    check(report.last_observed_ms == 100 and report.counters.clock_errors == 1, "last real time retained")
    local empty = Recorder.new(json)
    check(empty:time(nil) == nil and empty:report().started_ms == nil, "missing first clock is not zero")
end)

test("timing gap and provenance remain diagnostic", function()
    local r = fresh()
    r:tick(100); r:tick(110); r:tick(1000)
    local report = r:report()
    check(report.counters.tick_gaps == 1 and report.max_tick_gap_ms == 890, "authored gap threshold measured")
    check(report.rows[1].event == "probe.tick_gap" and report.rows[1].previous_observed_ms == 110 and report.rows[1].observed_ms == 1000 and report.rows[1].gap_ms == 890, "instrumentation locates the missed interval")
    check(report.c0 == "UNKNOWN" and report.disk_durability == "UNCONFIRMED", "no calibration or durability claim")
    check(report.collection_settings.provenance == "AUTHORED", "collection settings labeled")
    check(string.find(report.provenance.trick_landed_points, "inferred", 1, true) ~= nil, "SDK inference not called ledger")
end)

test("adapter checkpoint cadence and final unload", function()
    local f = fake()
    local r = Recorder.start(f.sdk)
    check(f.stores == 1 and r.count == 1, "initial unavailable snapshot saved to SDK memory")
    for i = 1, 99 do f.now = 1000 + i * 10; f.handlers.tick() end
    check(f.stores == 1, "no full checkpoint each tick")
    f.now = 2000; f.handlers.tick()
    check(f.stores == 2, "one checkpoint at authored interval")
    f.now, f.current = 2001, score(100)
    f.handlers.tick()
    check(r.count == 2 and f.stores == 2, "changed score retained between checkpoints")
    f.handlers.unload()
    check(f.stores == 3 and f.saved.ended and f.saved.c0 == "UNKNOWN", "unload captures final bounded report")
    f.handlers.unload()
    check(f.stores == 3, "unload is idempotent")
end)

test("existing or foreign storage blocks without mutation", function()
    local f = fake(); f.prior = { previous = "evidence" }
    local blocked = Recorder.start(f.sdk)
    check(blocked.active == false and f.stores == 0 and next(f.handlers) == nil, "prior evidence untouched")
    f = fake(); f.prior = false
    blocked = Recorder.start(f.sdk)
    check(blocked.active == false and f.stores == 0, "false is present evidence, not an empty key")
    f = fake(); f.prior = {}
    blocked = Recorder.start(f.sdk)
    check(blocked.active == false and f.stores == 0, "an existing empty object is not overwritten")
    f = fake(); f.keys = { "another_key" }
    blocked = Recorder.start(f.sdk)
    check(blocked.active == false and f.stores == 0, "foreign storage cannot escape total quota")
    check(Recorder.start(nil).active == false, "missing SDK blocks without throwing")
end)

test("storage failures are visible and retry cadence bounded", function()
    local f = fake(); f.fail = true
    local r = Recorder.start(f.sdk)
    check(r.counters.storage_failures == 1 and f.stores == 1, "failed initial set counted")
    f.now = 1001; f.handlers.tick()
    check(f.stores == 1, "failure does not trigger per-tick retries")
    f.now, f.fail = 2000, false; f.handlers.tick()
    check(f.stores == 2 and f.saved.counters.storage_failures == 1, "later accepted snapshot retains failure evidence")
end)

test("adapter event clock failure records terminal status", function()
    local f = fake()
    local r = Recorder.start(f.sdk)
    f.clock_error = true
    f.handlers.trick_started({})
    check(r.state == "clock_unavailable", "callback clock failure halts")
    check(f.saved.collection_state == "clock_unavailable" and f.saved.counters.clock_errors == 1, "terminal failure checkpointed without new timestamp")
    local attempts = f.stores
    f.handlers.tick(); f.handlers.tick()
    check(f.stores == attempts, "terminal checkpoint attempted only once before unload")
end)

test("exact oversized envelope refuses storage", function()
    local r = fresh(function(value)
        if value[KEY] then return string.rep("x", 256 * 1024 + 1) end
        return json(value)
    end)
    r:event("trick_started", {}, 100)
    local writes = 0
    check(not r:persist(function() writes = writes + 1 end, 100, true), "oversize refused")
    check(writes == 0 and r.state == "storage_envelope_limit", "nothing sent beyond exact bound")
end)

test("encoder failure stops and rejects row", function()
    local r = fresh(function() error("synthetic JSON failure") end)
    r:event("trick_started", {}, 100)
    check(r.count == 0 and r.state == "encoding_error", "failed row encoding cannot enter ring")
    check(r.counters.encoding_errors == 1, "codec failure counted")
end)

test("malformed note containers expose unknown loss", function()
    local r = fresh()
    r:event("trick_notes", { notes = { garbage = "not an array" } }, 100)
    r:event("trick_notes", { notes = { [1] = { entry = "1", kind = "n", text = "a" }, [3] = { entry = "3", kind = "n", text = "b" } } }, 101)
    local oversized = {}
    for i = 1, 257 do oversized[i] = { entry = tostring(i), kind = "n", text = "x" } end
    r:event("trick_notes", { notes = oversized }, 102)
    local report = r:report()
    check(report.counters.note_batches_refused == 3 and report.counters.malformed_payloads == 3, "dictionary, holes and unverified size refused")
    check(report.counters.notes_omitted == 0, "unknown missing-note count not invented")
    check(#report.rows == 3 and report.rows[3].reason == "notes_shape_unverified", "refused interval retained")
end)

test("note kind must be exactly the SDK one-character tag", function()
    local r = fresh()
    r:event("trick_notes", { notes = { { entry = "1", kind = string.rep("n", 1000), text = "x" } } }, 100)
    check(r:report().rows[1].payload_status == "malformed", "overlong kind never becomes a measured label")
    check(r.counters.malformed_payloads == 1, "bad kind counted")
end)

return { run = function()
    assertions = 0
    for _, case in ipairs(cases) do
        local ok, why = pcall(case[2])
        assert(ok, case[1] .. ": " .. tostring(why))
    end
    return { cases = #cases, assertions = assertions, native_actions = 0 }
end }
