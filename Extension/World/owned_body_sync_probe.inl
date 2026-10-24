// Included once inside owned_bodies.cpp. Uses that exact Service, Slot, native
// clock, validators and existing synchronizer; no second hook or actor owner.
namespace {
constexpr std::uint64_t sync_probe_lifetime_ms = 1000;
constexpr std::uint32_t sync_all_records = 15;
using SyncRecord = body_sync_probe::Record;
using SyncStatus = body_sync_probe::Status;

void sync_loss(std::uint64_t sequence) noexcept {
    auto word = service.probe_losses.load(std::memory_order_acquire);
    for (unsigned attempt = 0; attempt < 4; ++attempt) {
        if ((word >> 32) != sequence || static_cast<std::uint32_t>(word) == UINT32_MAX) return;
        if (service.probe_losses.compare_exchange_weak(word, word + 1, std::memory_order_acq_rel)) return;
    }
    // Contention implies another loss was recorded. This is a bounded lower
    // bound, never an exact callback count or evidence of a global barrier.
}
void sync_reject(std::uint64_t sequence) noexcept {
    if (!TryAcquireSRWLockExclusive(&service.lock)) { sync_loss(sequence); return; }
    auto& probe = service.probe;
    if (probe.sequence == sequence && probe.result.status == SyncStatus::pending && probe.result.rejected != UINT32_MAX)
        ++probe.result.rejected;
    ReleaseSRWLockExclusive(&service.lock);
}
void sync_expire(std::uint64_t sequence) noexcept {
    if (!TryAcquireSRWLockExclusive(&service.lock)) { sync_loss(sequence); return; }
    auto& probe = service.probe;
    if (probe.sequence == sequence && probe.result.status == SyncStatus::pending && GetTickCount64() >= probe.deadline) {
        const auto losses = service.probe_losses.load(std::memory_order_acquire);
        if ((losses >> 32) == sequence) probe.result.dropped = static_cast<std::uint32_t>(losses);
        probe.result.status = SyncStatus::expired;
        service.probe_live.store(0, std::memory_order_release);
    }
    ReleaseSRWLockExclusive(&service.lock);
}
bool sync_lifetime(const actor_control_native::Actor& actor) noexcept {
    // This existing epoch reader uses lock-free native hook state, not the
    // NoBail owner lock. It is safe at a final world-service closure.
    std::uint64_t epoch{};
    return actor.continuity == actor_control_native::Continuity::native_lifetime && actor.lifetime_epoch &&
        multiplayer::entity_destruction_epoch(actor.base, epoch) && epoch == actor.lifetime_epoch;
}
bool sync_actor(const actor_control_native::Actor& actor, const Anchor& anchor) noexcept {
    return !actor.ticket && actor.base == service.base && actor.client == anchor.client &&
        actor.entity == anchor.entity && actor.core == anchor.core && actor.context == anchor.skater_context &&
        actor.rig == anchor.rig && actor.game_context == anchor.context && actor.world == anchor.world &&
        actor.world_state == anchor.state && sync_lifetime(actor);
}
bool sync_packets(const Anchor& anchor, std::uintptr_t& packets) noexcept {
    std::uintptr_t owner{}, after{}, again{};
    constexpr auto end = n::packet_stride * 3 + n::pending + sizeof(std::uint32_t);
    return peek(anchor.rig + n::packet_owner, owner) && pointer(owner) &&
        peek(owner + n::packet_array, packets) && pointer(packets) && packets <= memory::highest_user_address - end &&
        peek(anchor.rig + n::packet_owner, after) && after == owner &&
        peek(owner + n::packet_array, again) && again == packets;
}
bool sync_source(const SyncProbe& probe) noexcept {
    const auto* slot = lookup(probe.owner, probe.handle);
    std::uintptr_t packets{};
    const auto now = GetTickCount64();
    return service.hooked.load(std::memory_order_acquire) && service.eligible &&
        now >= service.tick_at && now - service.tick_at < 250 &&
        service.world_generation == probe.world_generation && slot && slot->active && !slot->retained && !slot->quarantined &&
        sync_actor(probe.actor, slot->anchor) && producer_owner(*slot, slot->body) &&
        sync_packets(slot->anchor, packets) && packets == probe.packets;
}
bool sync_native_body(const Anchor& anchor, const NativeHandle& body) noexcept {
    std::uintptr_t state{}, generations{}, again{}; std::uint32_t generation{}, after{};
    const auto offset = std::uintptr_t{body.index} * sizeof(std::uint32_t);
    return body.world == anchor.world && allocated(anchor.state, body.index) &&
        peek(body.world + r::world_state, state) && state == anchor.state &&
        peek(body.world + r::world_body_generations, generations) && pointer(generations) &&
        peek(generations + offset, generation) && generation == body.generation &&
        valid_handle(service.api.body_valid, body) && allocated(anchor.state, body.index) &&
        peek(body.world + r::world_body_generations, again) && again == generations &&
        peek(generations + offset, after) && after == generation &&
        peek(body.world + r::world_state, state) && state == anchor.state;
}
bool sync_ring(const Anchor& anchor, const NativeHandle& body, std::uintptr_t offset, Ring& header, V4& value) noexcept {
    if (!peek(anchor.state + offset, header) || !pointer(header.values) || !header.elements || header.elements > 1048576 ||
        body.index >= header.elements || !header.planes || header.planes > 64 || header.current >= header.planes) return false;
    const auto bytes = (((header.elements * 4 & 0x7ffffffU) * 4 + 0x3cU) & 0xffffffc0U);
    const auto at = header.values + std::uintptr_t{bytes} * header.current + std::uintptr_t{body.index} * sizeof(V4);
    if (at < header.values || !peek(at, value)) return false;
    for (const auto component : value) if (!std::isfinite(component) || std::abs(component) > 1000000) return false;
    return true;
}
struct SyncPose {
    Ring position_header{}, rotation_header{};
    V4 position{}, rotation{}, local_com{}, local_rotation{};
    std::uintptr_t com_source{}, rotation_source{};
    bool operator==(const SyncPose&) const = default;
};
bool sync_pose(const Anchor& anchor, const NativeHandle& body, SyncPose& pose) noexcept {
    if (!sync_native_body(anchor, body) ||
        !sync_ring(anchor, body, r::position_ring, pose.position_header, pose.position) ||
        !sync_ring(anchor, body, r::rotation_ring, pose.rotation_header, pose.rotation) ||
        !array4(anchor.state, r::local_com, body.index, pose.local_com, pose.com_source) ||
        !array4(anchor.state, r::local_rotation, body.index, pose.local_rotation, pose.rotation_source)) return false;
    for (unsigned pass = 0; pass < 2; ++pass) {
        Ring header; V4 value{}; std::uintptr_t source{};
        if (!sync_ring(anchor, body, r::position_ring, header, value) || header != pose.position_header || value != pose.position ||
            !sync_ring(anchor, body, r::rotation_ring, header, value) || header != pose.rotation_header || value != pose.rotation ||
            !array4(anchor.state, r::local_com, body.index, value, source) || source != pose.com_source || value != pose.local_com ||
            !array4(anchor.state, r::local_rotation, body.index, value, source) || source != pose.rotation_source || value != pose.local_rotation ||
            !sync_native_body(anchor, body)) return false;
    }
    return true;
}
bool sync_quaternion(const V4& native, V4& value) noexcept {
    double norm{};
    for (const auto component : native) { if (!std::isfinite(component)) return false; norm += static_cast<double>(component) * component; }
    if (std::abs(norm - 1) > .002) return false;
    value = {native[1], native[2], native[3], native[0]};
    return true;
}
V4 sync_product(const V4& left, const V4& right) noexcept {
    return {left[3]*right[0] + left[0]*right[3] + left[1]*right[2] - left[2]*right[1],
        left[3]*right[1] - left[0]*right[2] + left[1]*right[3] + left[2]*right[0],
        left[3]*right[2] + left[0]*right[1] - left[1]*right[0] + left[2]*right[3],
        left[3]*right[3] - left[0]*right[0] - left[1]*right[1] - left[2]*right[2]};
}
Vec sync_rotate(const V4& q, const Vec& v) noexcept {
    const Vec twice{2*(q[1]*v[2] - q[2]*v[1]), 2*(q[2]*v[0] - q[0]*v[2]), 2*(q[0]*v[1] - q[1]*v[0])};
    return {v[0] + q[3]*twice[0] + q[1]*twice[2] - q[2]*twice[1],
        v[1] + q[3]*twice[1] + q[2]*twice[0] - q[0]*twice[2],
        v[2] + q[3]*twice[2] + q[0]*twice[1] - q[1]*twice[0]};
}
bool sync_transform(const SyncPose& pose, SyncRecord& record) noexcept {
    V4 ring_rotation{}, local_rotation{};
    if (!sync_quaternion(pose.rotation, ring_rotation) || !sync_quaternion(pose.local_rotation, local_rotation)) return false;
    record.rotation = sync_product(ring_rotation, local_rotation);
    record.local_rotation = local_rotation;
    for (std::size_t i = 0; i < 3; ++i) {
        record.com_position[i] = pose.position[i]; record.local_com[i] = pose.local_com[i];
    }
    // Native setter 25dc000 stores q_ring=q_target*conjugate(q_local) and
    // p_ring=p_target-rotate(q_ring,localCOM). Recompose that convention.
    const auto offset = sync_rotate(ring_rotation, record.local_com);
    record.transform_matches = true;
    for (std::size_t i = 0; i < 3; ++i) {
        record.origin[i] = record.com_position[i] + offset[i];
        if (!std::isfinite(record.origin[i])) return false;
        if (std::abs(record.origin[i] - record.supplied[12 + i]) > .002f) record.transform_matches = false;
    }
    for (std::size_t axis = 0; axis < 3; ++axis) {
        Vec unit{}; unit[axis] = 1;
        const auto column = sync_rotate(record.rotation, unit);
        for (std::size_t i = 0; i < 3; ++i)
            if (std::abs(column[i] - record.supplied[axis*4 + i]) > .002f) record.transform_matches = false;
    }
    return true;
}
bool sync_same_matrix(const std::array<float, 16>& left, const std::array<float, 16>& right) noexcept {
    return std::memcmp(left.data(), right.data(), sizeof(left)) == 0;
}
bool sync_clock(const SyncProbe& probe, Epoch& epoch, std::uint64_t& observed) noexcept {
    const auto* slot = lookup(probe.owner, probe.handle);
    epoch.world = probe.world_generation; epoch.body = probe.handle.generation;
    const auto now = GetTickCount64();
    return slot && clock(slot->anchor, epoch, &observed) && observed >= probe.opened_ms && now >= observed &&
        now - observed < command_lifetime_ms && now < probe.deadline &&
        epoch.serial > probe.result.armed_epoch.serial && epoch.time > probe.result.armed_epoch.time;
}
void sync_before(NativeHandle* incoming, std::uintptr_t wrapper, SyncBefore& out) noexcept {
    LastError error;
    const auto live = service.probe_live.load(std::memory_order_acquire);
    if (!live) return;
    if (!TryAcquireSRWLockShared(&service.lock)) { sync_loss(live); return; }
    const auto& probe = service.probe;
    if (probe.sequence == live && probe.result.status == SyncStatus::pending && GetTickCount64() >= probe.deadline) {
        ReleaseSRWLockShared(&service.lock); sync_expire(live); return;
    }
    std::size_t index = probe.result.records.size();
    if (probe.sequence == live && probe.result.status == SyncStatus::pending)
        for (std::size_t i = 0; i < probe.result.records.size(); ++i)
            if (wrapper == probe.packets + n::wrapper + i*n::packet_stride) index = i;
    if (index == probe.result.records.size() || probe.result.records[index].present) { ReleaseSRWLockShared(&service.lock); return; }
    const auto actor = probe.actor;
    ReleaseSRWLockShared(&service.lock);
    actor_control_native::Actor current;
    if (!actor_control_native::observe_actor(current) || current != actor) { sync_reject(live); return; }
    if (!TryAcquireSRWLockShared(&service.lock)) { sync_loss(live); return; }
    const auto& selected = service.probe;
    const auto* slot = lookup(selected.owner, selected.handle);
    SyncBefore value; std::uint64_t observed{}; Epoch after{}; std::uint64_t observed_after{};
    NativeHandle again{}; std::array<float, 16> matrix_after{}; std::uint32_t flags_after{};
    bool valid = selected.sequence == live && selected.actor == actor && selected.result.status == SyncStatus::pending &&
        !selected.result.records[index].present && sync_source(selected) && sync_clock(selected, value.record.epoch, observed) &&
        slot && peek(reinterpret_cast<std::uintptr_t>(incoming), value.body) && sync_native_body(slot->anchor, value.body) &&
        peek(wrapper + n::transform - n::wrapper, value.record.supplied) && peek(wrapper + n::pending - n::wrapper, value.record.before_flags);
    if (valid) for (const auto component : value.record.supplied) if (!std::isfinite(component)) valid = false;
    valid = valid && peek(reinterpret_cast<std::uintptr_t>(incoming), again) && again == value.body &&
        peek(wrapper + n::transform - n::wrapper, matrix_after) && sync_same_matrix(matrix_after, value.record.supplied) &&
        peek(wrapper + n::pending - n::wrapper, flags_after) && flags_after == value.record.before_flags &&
        sync_source(selected) && sync_clock(selected, after, observed_after) && after == value.record.epoch && observed_after == observed;
    if (valid) {
        value.owner = selected.owner; value.handle = selected.handle; value.sequence = selected.sequence;
        value.world_generation = selected.world_generation; value.deadline = selected.deadline;
        value.actor = actor; value.packets = selected.packets; value.index = index;
        value.incoming = reinterpret_cast<std::uintptr_t>(incoming); value.wrapper = wrapper;
        value.record.pending_before = (value.record.before_flags & n::transform_bit) != 0;
    }
    ReleaseSRWLockShared(&service.lock);
    if (!valid || !actor_control_native::observe_actor(current) || current != actor) { sync_reject(live); return; }
    value.ready = true; out = value;
}
void sync_after(NativeHandle* incoming, std::uintptr_t wrapper, const SyncBefore& before) noexcept {
    LastError error;
    if (!before.ready || before.incoming != reinterpret_cast<std::uintptr_t>(incoming) || before.wrapper != wrapper) return;
    actor_control_native::Actor current;
    if (!actor_control_native::observe_actor(current) || current != before.actor) { sync_reject(before.sequence); return; }
    if (!TryAcquireSRWLockExclusive(&service.lock)) { sync_loss(before.sequence); return; }
    auto& probe = service.probe;
    const auto* slot = lookup(before.owner, before.handle);
    SyncRecord record = before.record; SyncPose pose, pose_after;
    NativeHandle body{}; Epoch epoch{}, after{}; std::uint64_t observed{}, observed_after{};
    std::array<float, 16> matrix{}; std::uint32_t flags{};
    bool valid = probe.sequence == before.sequence && probe.owner == before.owner && probe.handle == before.handle &&
        probe.world_generation == before.world_generation && probe.actor == before.actor && probe.packets == before.packets &&
        probe.result.status == SyncStatus::pending && !probe.result.records[before.index].present && slot && sync_source(probe) &&
        sync_clock(probe, epoch, observed) && epoch == before.record.epoch &&
        peek(reinterpret_cast<std::uintptr_t>(incoming), body) && body == before.body && sync_native_body(slot->anchor, body) &&
        peek(wrapper + n::transform - n::wrapper, matrix) && sync_same_matrix(matrix, before.record.supplied) &&
        peek(wrapper + n::pending - n::wrapper, record.after_flags) && sync_pose(slot->anchor, body, pose) && sync_transform(pose, record);
    valid = valid && peek(reinterpret_cast<std::uintptr_t>(incoming), body) && body == before.body &&
        peek(wrapper + n::transform - n::wrapper, matrix) && sync_same_matrix(matrix, before.record.supplied) &&
        peek(wrapper + n::pending - n::wrapper, flags) && flags == record.after_flags && sync_native_body(slot->anchor, body) &&
        sync_source(probe) && sync_pose(slot->anchor, body, pose_after) && pose_after == pose &&
        sync_lifetime(before.actor) && sync_clock(probe, after, observed_after) && after == epoch && observed_after == observed;
    const auto finished = GetTickCount64();
    valid = valid && finished >= observed && finished - observed < command_lifetime_ms && finished < before.deadline;
    if (valid) {
        record.present = true; record.pending_after = (record.after_flags & n::transform_bit) != 0;
        probe.bodies[before.index] = before.body; probe.result.records[before.index] = record;
        probe.result.observed_mask |= 1U << before.index;
    } else if (probe.sequence == before.sequence && probe.result.status == SyncStatus::pending && probe.result.rejected != UINT32_MAX)
        ++probe.result.rejected;
    ReleaseSRWLockExclusive(&service.lock);
}
std::uintptr_t synchronize_hook(NativeHandle* incoming, std::uintptr_t wrapper) {
    SyncBefore observed;
    sync_before(incoming, wrapper, observed);
    const auto original = service.original.load(std::memory_order_acquire);
    const auto result = original(incoming, wrapper); LastError error;
    sync_after(incoming, wrapper, observed);
    produce(incoming, wrapper); return result;
}
} // namespace

std::string begin_sync_probe(std::uint64_t owner, const Handle& handle, std::uint64_t& sequence) {
    LastError error; sequence = 0;
    try {
        if (!owner || !eligible()) return "native sync observation requires an owned body in the client phase";
        actor_control_native::Actor actor;
        if (!actor_control_native::observe_actor(actor)) return "native actor lifetime observation unavailable";
        Locked lock(service.lock); const auto* slot = lookup(owner, handle);
        if (!slot || !slot->active || slot->retained || slot->quarantined || !fresh(*slot) || !sync_actor(actor, slot->anchor))
            return "native sync body or actor ownership changed";
        auto& previous = service.probe;
        if (previous.result.status == SyncStatus::pending && previous.sequence && GetTickCount64() < previous.deadline)
            return "a bounded native sync observation is already pending";
        if (service.probe_generation == UINT32_MAX) return "native sync observation generation exhausted";
        // The existing synchronizer and target setter can already be Detoured.
        // Their installation checked original bytes; checking their patched
        // entry again here would make every real observation refuse forever.
        if (!service.hooked.load(std::memory_order_acquire) || !service.original.load(std::memory_order_acquire) ||
            service.api.base != service.base) return "qualified native synchronizer unavailable";
        for (const auto* prefix : {&n::packet_a_writer, &n::packet_b_writer, &n::packet_tail_writer})
            if (!matches(service.base, *prefix)) return "native sync observation source bytes differ";
        SyncProbe value; value.owner = owner; value.handle = handle; value.actor = actor;
        value.world_generation = service.world_generation;
        value.result.armed_epoch.world = service.world_generation; value.result.armed_epoch.body = handle.generation;
        std::uint64_t observed{}; Epoch after{}; after.world = service.world_generation; after.body = handle.generation;
        std::uint64_t observed_after{};
        if (!sync_packets(slot->anchor, value.packets) || !clock(slot->anchor, value.result.armed_epoch, &observed) ||
            !fresh(*slot) || !sync_actor(actor, slot->anchor) || !clock(slot->anchor, after, &observed_after) ||
            after != value.result.armed_epoch || observed_after != observed) return "native sync observation arm fence changed";
        const auto finished = GetTickCount64();
        if (!observed || finished < observed || finished - observed >= command_lifetime_ms ||
            finished > UINT64_MAX - sync_probe_lifetime_ms) return "native sync observation clock unavailable";
        value.opened_ms = finished; value.deadline = finished + sync_probe_lifetime_ms;
        value.sequence = ++service.probe_generation;
        service.probe = value;
        service.probe_losses.store(value.sequence << 32, std::memory_order_release);
        service.probe_live.store(static_cast<std::uint32_t>(value.sequence), std::memory_order_release);
        sequence = value.sequence; return {};
    } catch (...) { return "native sync observation failed closed"; }
}
std::string poll_sync_probe(std::uint64_t owner, const Handle& handle, std::uint64_t sequence, body_sync_probe::Result& out) {
    LastError error; out = {};
    try {
        if (!owner || !sequence || GetCurrentThreadId() != service.thread) return "native sync observations are client phase only";
        {
            Locked lock(service.lock); const auto& probe = service.probe;
            if (probe.owner != owner || probe.handle != handle || probe.sequence != sequence)
                return "native sync observation unavailable for this owner and body generation";
            if (probe.result.status != SyncStatus::pending) { out = probe.result; return {}; }
        }
        actor_control_native::Actor actor;
        const bool actor_current = actor_control_native::observe_actor(actor);
        Locked lock(service.lock); auto& probe = service.probe;
        if (probe.owner != owner || probe.handle != handle || probe.sequence != sequence)
            return "native sync observation unavailable for this owner and body generation";
        if (probe.result.status == SyncStatus::pending) {
            const auto losses = service.probe_losses.load(std::memory_order_acquire);
            if ((losses >> 32) == sequence) probe.result.dropped = static_cast<std::uint32_t>(losses);
            if (GetTickCount64() >= probe.deadline) probe.result.status = SyncStatus::expired;
            else if (!actor_current || actor != probe.actor || !sync_source(probe)) probe.result.status = SyncStatus::invalidated;
            else if (probe.result.observed_mask == sync_all_records) {
                const auto* slot = lookup(owner, handle);
                Epoch later{}; std::uint64_t observed{};
                bool current = slot && sync_clock(probe, later, observed);
                for (std::size_t i = 0; current && i < probe.result.records.size(); ++i)
                    current = sync_native_body(slot->anchor, probe.bodies[i]) && later.serial > probe.result.records[i].epoch.serial &&
                        later.time > probe.result.records[i].epoch.time;
                Epoch after{}; std::uint64_t observed_after{};
                current = current && sync_source(probe) && sync_clock(probe, after, observed_after) && after == later && observed_after == observed;
                const auto finished = GetTickCount64();
                if (current && finished >= observed && finished - observed < command_lifetime_ms && finished < probe.deadline) {
                    probe.result.observed_epoch = later; probe.result.status = SyncStatus::observed;
                }
            }
            if (probe.result.status != SyncStatus::pending) service.probe_live.store(0, std::memory_order_release);
        }
        out = probe.result; return {};
    } catch (...) { return "native sync observation poll failed closed"; }
}
