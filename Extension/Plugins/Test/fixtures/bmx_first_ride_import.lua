-- Actual-Host import/construction fixture only. No arm, step, lease, capture,
-- owner, UI, world, body, timer, event registration or force submission occurs.
-- This entry is staged source: main owns any future Host execution.
local Identity = require("./lease_identity")
local Source = require("./lease_source")
local Mapping = require("./ride_input_mapping")
local RideInput = require("./ride_input")

-- These aliases all resolve to the same .lua package key in the real Host.
-- The C++ fixture packages only the six named .lua files, with no .luau shadow.
assert(Identity == require("lease_identity.lua"))
assert(Source == require("lease_source"))
assert(Mapping == require("./ride_input_mapping.lua"))
assert(RideInput == require("ride_input"))
assert(table.isfrozen(Identity) and table.isfrozen(Source) and table.isfrozen(RideInput))

local function protected_instance(object)
    assert(table.isfrozen(object) and getmetatable(object) == "locked")
    assert(next(object) == nil, "Source/RideInput own state stays outside the instance table")
    assert(not pcall(function() rawset(object, "fixture_mutation", true) end))
    assert(not pcall(function() setmetatable(object, {}) end))
end

local input_api = assert(reskate.input)
for _, name in ipairs({ "lease", "lease_read", "lease_renew", "lease_release", "lease_state", "lease_acknowledge",
    "lease_capture", "lease_capture_state", "lease_release_capture", "lease_acknowledge_capture" }) do
    assert(type(input_api[name]) == "function", "actual Host binding is missing: " .. name)
end
local source = Source.new(input_api)
local mapping = Mapping.new({})
local ride = RideInput.new(source, mapping, nil)
local other_source = Source.new(input_api)
local other_mapping = Mapping.new({})
local other_ride = RideInput.new(other_source, other_mapping, nil)
assert(source ~= other_source and mapping ~= other_mapping and ride ~= other_ride)

for _, object in ipairs({ source, other_source, ride, other_ride }) do
    protected_instance(object)
end

for _, object in ipairs({ source, other_source }) do
    local status = object:status()
    assert(table.isfrozen(status))
    assert(status.phase == "idle" and status.input_ok == false and status.new_observation == false)
    assert(status.generation == 0 and status.lease_handle == nil and status.sample == nil)
    assert(status.lease_state == nil and status.capture_state == nil)
    assert(status.cleanup_pending == false and status.cleanup_unknown == false)
end
for _, object in ipairs({ mapping, other_mapping }) do
    -- Mapping deliberately has an ordinary mutable Lua instance/status. Do not
    -- invent frozen/private guarantees that its current implementation lacks.
    local status = object:status()
    assert(status.valid == false and status.active == false and status.issue == "not_primed")
    assert(status.source == nil and status.pending_hop == nil and status.hop_counter == 0)
    assert(status.exhausted == false and status.uncertain == nil)
end
for _, object in ipairs({ ride, other_ride }) do
    local status = object:status()
    assert(table.isfrozen(status))
    assert(status.phase == "idle" and status.submit_forces == false and status.force_controls == nil)
    assert(status.force_stop_required == false and status.cleanup_unknown == false and status.unloaded == false)
    assert(status.physics_epoch == nil and status.body == nil and status.session == nil)
    assert(status.owner_record == nil and status.owner_facts == nil and status.source_frame == nil)
    assert(status.stop_request == nil and status.stop_outcome == nil)
    assert(table.isfrozen(status.lifecycle_token) and table.isfrozen(status.permit_token))
end

-- Host::status reports plugin lifecycle, not these Lua objects. A log marker
-- after all Lua assertions is the existing test suite's assertion channel.
reskate.log("FIRST_RIDE_IMPORT_CONSTRUCT_INERT_V1")
