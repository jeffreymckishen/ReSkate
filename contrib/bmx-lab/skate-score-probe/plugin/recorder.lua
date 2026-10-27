-- Read-only HUD/event observations. All collection limits are authored, not Skate rules.
local Recorder = {}
Recorder.__index = Recorder
local KEY = "skate_score_probe_v1"
local MAX_ROWS, MAX_BYTES, ROW_BYTES = 2000, 256 * 1024, 240 * 1024
local TEXT_BYTES, NOTE_BATCH, NOTE_SCAN, SAVE_MS, GAP_MS = 160, 32, 256, 1000, 250
local COUNTER_MAX, CLOCK_MAX = 2147483647, 9007199254740991
local NOTE_KINDS = { n = true, s = true, l = true, b = true, r = true, k = true, m = true }
local COUNTERS = {
    "rows_recorded", "rows_evicted", "rows_rejected", "notes_omitted", "note_batches_refused", "malformed_payloads",
    "text_truncations", "text_sanitizations", "score_polls", "score_unavailable", "score_errors",
    "clock_errors", "tick_gaps", "encoding_errors", "storage_attempts", "storage_failures",
}

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function copy(source)
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

function Recorder.new(encode)
    assert(type(encode) == "function", "JSON encoder required")
    local counters = {}
    for _, name in ipairs(COUNTERS) do counters[name] = 0 end
    return setmetatable({ encode = encode, ring = {}, sizes = {}, head = 1, count = 0,
        row_bytes = 0, sequence = 0, counters = counters, dirty = true,
        state = "observing", ended = false, max_tick_gap_ms = 0 }, Recorder)
end

function Recorder:bump(name, amount)
    local value = self.counters[name] + (amount or 1)
    if value > COUNTER_MAX then self.counter_saturated = true end
    self.counters[name] = math.min(COUNTER_MAX, value)
    self.dirty = true
end

function Recorder:halt(reason)
    if self.state == "observing" then self.state = reason end
    self.dirty = true
end

function Recorder:time(value)
    if not finite(value) or value < 0 or value > CLOCK_MAX then
        self:bump("clock_errors")
        self:halt("clock_unavailable")
        return nil
    end
    local ms = math.floor(value)
    if self.last_ms ~= nil and ms < self.last_ms then
        self:bump("clock_errors")
        self:halt("clock_regressed")
        return nil
    end
    self.started_ms = self.started_ms or ms
    self.last_ms = ms
    return ms
end

-- Only inspect a bounded prefix. Invalid UTF-8/control bytes become '?'; do not cut a codepoint.
function Recorder:text(value)
    local output, index, used, changed = {}, 1, 0, false
    local size = #value
    while index <= size and index <= TEXT_BYTES and used < TEXT_BYTES do
        local a = string.byte(value, index)
        local width = a < 128 and 1 or (a >= 194 and a <= 223 and 2
            or (a >= 224 and a <= 239 and 3 or (a >= 240 and a <= 244 and 4 or 0)))
        if width > 1 then
            if index + width - 1 > size then width = 0 else
                local b = string.byte(value, index + 1)
                if b < 128 or b > 191 or (a == 224 and b < 160) or (a == 237 and b > 159)
                    or (a == 240 and b < 144) or (a == 244 and b > 143) then width = 0 end
                if width >= 3 then
                    local c = string.byte(value, index + 2)
                    if c < 128 or c > 191 then width = 0 end
                end
                if width == 4 then
                    local d = string.byte(value, index + 3)
                    if d < 128 or d > 191 then width = 0 end
                end
            end
        end
        if width > 0 and (index + width - 1 > TEXT_BYTES or used + width > TEXT_BYTES) then break end
        if width == 0 or a < 32 or a == 127 then
            output[#output + 1], index, used, changed = "?", index + 1, used + 1, true
        else
            output[#output + 1] = string.sub(value, index, index + width - 1)
            index, used = index + width, used + width
        end
    end
    if index <= size then self:bump("text_truncations") end
    if changed then self:bump("text_sanitizations") end
    return table.concat(output)
end

function Recorder:encoded(value)
    local ok, encoded = pcall(self.encode, value)
    if not ok or type(encoded) ~= "string" then
        self:bump("encoding_errors")
        self:halt("encoding_error")
        return nil
    end
    return encoded
end

function Recorder:evict()
    self.row_bytes = self.row_bytes - self.sizes[self.head]
    self.ring[self.head], self.sizes[self.head] = nil, nil
    self.head = self.head % MAX_ROWS + 1
    self.count = self.count - 1
    self:bump("rows_evicted")
end

function Recorder:append(row, ms)
    if self.state ~= "observing" or self.ended or ms == nil then return end
    if self.sequence >= COUNTER_MAX then self:halt("sequence_limit"); return end
    self.sequence = self.sequence + 1
    row.seq, row.observed_ms, row.elapsed_ms = self.sequence, ms, ms - self.started_ms
    local encoded = self:encoded(row)
    if not encoded then return end
    local bytes = #encoded + 1 -- Includes a row separator; the exact envelope is checked before storage.
    if bytes > ROW_BYTES then self:bump("rows_rejected"); return end
    while self.count > 0 and (self.count >= MAX_ROWS or self.row_bytes + bytes > ROW_BYTES) do self:evict() end
    local slot = (self.head + self.count - 1) % MAX_ROWS + 1
    self.ring[slot], self.sizes[slot] = row, bytes
    self.count, self.row_bytes = self.count + 1, self.row_bytes + bytes
    self:bump("rows_recorded")
end

function Recorder:malformed(event, ms, reason)
    self:bump("malformed_payloads")
    self:append({ event = event, payload_status = "malformed", reason = reason }, ms)
end

function Recorder:event(event, payload, ms)
    if self.state ~= "observing" or self.ended then return end
    if type(payload) ~= "table" then self:malformed(event, ms); return end
    if event == "trick_started" then
        -- The only SDK field is a position vector. The probe needs timing, not world coordinates.
        self:append({ event = event }, ms)
    elseif event == "trick_landed" then
        if not finite(payload.points) or not finite(payload.multiplier) or not finite(payload.ms)
            or payload.ms < 0 or type(payload.name) ~= "string" then self:malformed(event, ms); return end
        self:append({ event = event, points = payload.points, multiplier = payload.multiplier,
            ms = payload.ms, name = self:text(payload.name) }, ms)
    elseif event == "line_broken" then
        if type(payload.reason) ~= "string" then self:malformed(event, ms); return end
        self:append({ event = event, reason = self:text(payload.reason) }, ms)
    elseif event == "trick_notes" then
        if type(payload.notes) ~= "table" then self:malformed(event, ms); return end
        local count, seen, key = #payload.notes, 0, nil
        local shape_ok = count <= NOTE_SCAN
        while shape_ok do
            key = next(payload.notes, key)
            if key == nil then break end
            seen = seen + 1
            shape_ok = seen <= NOTE_SCAN and type(key) == "number" and key >= 1 and key <= count and key % 1 == 0
        end
        if not shape_ok or seen ~= count then
            -- Count refused batches, not an invented number of missing notes.
            self:bump("note_batches_refused")
            self:malformed(event, ms, "notes_shape_unverified")
            return
        end
        if count > NOTE_BATCH then self:bump("notes_omitted", count - NOTE_BATCH) end
        for i = 1, math.min(count, NOTE_BATCH) do
            local note = payload.notes[i]
            if type(note) ~= "table" or type(note.entry) ~= "string" or #note.entry < 1 or #note.entry > 20
                or not string.match(note.entry, "^%d+$") or (#note.entry == 20 and note.entry > "18446744073709551615")
                or type(note.kind) ~= "string" or #note.kind ~= 1 or not NOTE_KINDS[note.kind] or type(note.text) ~= "string" then
                self:malformed(event, ms)
            else
                self:append({ event = event, entry = note.entry, kind = note.kind, text = self:text(note.text) }, ms)
            end
        end
    end
end

function Recorder:score(value, ok, ms)
    if self.state ~= "observing" or self.ended then return end
    self:bump("score_polls")
    local row = { event = "score.current", available = false }
    if not ok then row.reason = "api_error"; self:bump("score_errors")
    elseif value == nil then row.reason = "unavailable"; self:bump("score_unavailable")
    elseif type(value) ~= "table" or not finite(value.line) or not finite(value.multiplier)
        or type(value.in_trick) ~= "boolean" or type(value.manual) ~= "boolean"
        or type(value.trick) ~= "string" or type(value.detail) ~= "string" then
        row.reason = "malformed"; self:bump("malformed_payloads")
    else
        row.available, row.line, row.multiplier = true, value.line, value.multiplier
        row.in_trick, row.manual = value.in_trick, value.manual
        row.trick, row.detail = self:text(value.trick), self:text(value.detail)
    end
    local key = self:encoded(row)
    if key and key ~= self.score_key then
        self.score_key = key
        self:append(row, ms)
    end
end

function Recorder:tick(ms)
    if self.last_tick_ms ~= nil then
        local gap = ms - self.last_tick_ms
        if gap > GAP_MS then
            self:bump("tick_gaps")
            self:append({ event = "probe.tick_gap", previous_observed_ms = self.last_tick_ms, gap_ms = gap }, ms)
        end
        self.max_tick_gap_ms = math.max(self.max_tick_gap_ms, gap)
    end
    self.last_tick_ms = ms
end

function Recorder:report()
    local rows = {}
    for i = 0, self.count - 1 do rows[#rows + 1] = self.ring[(self.head + i - 1) % MAX_ROWS + 1] end
    return {
        schema = 1, probe = "skate_score_probe_v1", c0 = "UNKNOWN", collection_state = self.state,
        ended = self.ended, disk_durability = "UNCONFIRMED", clock = "reskate.time.now steady milliseconds",
        started_ms = self.started_ms, last_observed_ms = self.last_ms, sequence = self.sequence,
        row_count = self.count, rows = rows, counters = copy(self.counters),
        counter_saturated = self.counter_saturated == true, max_tick_gap_ms = self.max_tick_gap_ms,
        provenance = { score_current = "SDK HUD snapshot; not game scoring ledger",
            trick_landed_points = "SDK TrickWatch inferred HUD unscaled delta; unverified scoring rule",
            trick_landed_ms = "SDK watch start to emission; not qualified physical airtime",
            note_entry = "opaque uint64 decimal string; not a trick identifier" },
        collection_settings = { provenance = "AUTHORED", max_rows = MAX_ROWS, max_storage_bytes = MAX_BYTES,
            row_byte_budget = ROW_BYTES, max_text_bytes = TEXT_BYTES, max_notes_per_callback = NOTE_BATCH,
            max_note_shape_entries = NOTE_SCAN,
            checkpoint_interval_ms = SAVE_MS, tick_gap_threshold_ms = GAP_MS,
            score_changes = "per tick after bounded text projection; unavailable transitions included" },
    }
end

function Recorder:persist(set, ms, force)
    if not self.dirty then return true end
    if not force and (ms == nil or (self.last_attempt_ms and ms - self.last_attempt_ms < SAVE_MS)) then return false end
    self.last_attempt_ms = ms
    self:bump("storage_attempts")
    local report = self:report()
    local encoded = self:encoded({ [KEY] = report })
    if not encoded then return false end
    if #encoded > MAX_BYTES then
        self:bump("encoding_errors")
        self:halt("storage_envelope_limit")
        return false
    end
    local ok = pcall(set, KEY, report)
    if not ok then self:bump("storage_failures"); return false end
    -- Accepted into SDK memory only. close()/unload saves later and disk errors are log-only.
    self.dirty = false
    return true
end

local function warn(sdk, message)
    if type(sdk) == "table" and type(sdk.log) == "function" then pcall(sdk.log, "Skate score probe: " .. message, "warn") end
end

function Recorder.start(sdk)
    local function blocked(reason)
        warn(sdk, reason .. "; existing evidence was not changed")
        return { active = false, reason = reason }
    end
    if type(sdk) ~= "table" or type(sdk.on) ~= "function" or type(sdk.json) ~= "table"
        or type(sdk.json.encode) ~= "function" or type(sdk.storage) ~= "table"
        or type(sdk.storage.get) ~= "function" or type(sdk.storage.keys) ~= "function"
        or type(sdk.storage.set) ~= "function" or type(sdk.time) ~= "table"
        or type(sdk.time.now) ~= "function" or type(sdk.score) ~= "table"
        or type(sdk.score.current) ~= "function" then return blocked("required API unavailable") end
    local got, prior = pcall(sdk.storage.get, KEY)
    local listed, keys = pcall(sdk.storage.keys)
    if not got or not listed or type(keys) ~= "table" then return blocked("storage inspection failed") end
    if prior ~= nil or next(keys) ~= nil then return blocked("archive and clear this probe's private storage before a new capture") end
    local self = Recorder.new(sdk.json.encode)
    local function clock()
        local ok, value = pcall(sdk.time.now)
        return self:time(ok and value or nil)
    end
    local storage_warned = false
    local function save(ms, force)
        local failures = self.counters.storage_failures
        local result = self:persist(sdk.storage.set, ms, force)
        if self.counters.storage_failures > failures and not storage_warned then
            storage_warned = true
            warn(sdk, "storage.set failed; capture is incomplete and retries are bounded")
        end
        return result
    end
    local terminal_attempted = false
    local function save_terminal()
        if self.state ~= "observing" and not terminal_attempted then
            terminal_attempted = true
            warn(sdk, self.state .. "; observation stopped, C0 remains UNKNOWN")
            save(nil, true)
        end
    end
    local ms = clock()
    if ms ~= nil then
        local ok, current = pcall(sdk.score.current)
        self:score(current, ok, ms)
    end
    save(ms, true)
    save_terminal()
    for _, event in ipairs({ "trick_started", "trick_landed", "line_broken", "trick_notes" }) do
        sdk.on(event, function(payload)
            if self.state ~= "observing" or self.ended then return end
            local at = clock()
            if at ~= nil then self:event(event, payload, at) end
            save_terminal()
        end)
    end
    sdk.on("tick", function()
        if self.ended then return end
        if self.state ~= "observing" then save_terminal(); return end
        local at = clock()
        if at == nil then save_terminal(); return end
        self:tick(at)
        local ok, current = pcall(sdk.score.current)
        self:score(current, ok, at)
        save(at, false)
        save_terminal()
    end)
    sdk.on("unload", function()
        if self.ended then return end
        -- A bad final clock does not manufacture an observation timestamp.
        local at = self.state == "observing" and clock() or nil
        self.ended, self.dirty = true, true
        save(at, true)
    end)
    return self
end

return Recorder
