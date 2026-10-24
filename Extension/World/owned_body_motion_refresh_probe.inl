// Included by owned_bodies.cpp. General read-only mover diagnostics only.
namespace {
namespace mp = motion_refresh_probe;
namespace ma = addr::motion_refresh_probe;
enum class MotionRoute : std::size_t { entries, matching, other, rejected, dropped };
struct MotionBefore {
    std::uint64_t cookie{};
    actor_control_native::Actor actor{};
    std::uintptr_t input{}, packet_owner{}, packets{};
    mp::Record record{};
};
struct MotionProbe {
    SRWLOCK lock = SRWLOCK_INIT;
    std::uint64_t owner{}, sequence{}, opened{}, deadline{};
    std::uint32_t generation{};
    std::uintptr_t base{};
    actor_control_native::Actor actor{};
    mp::Result result{};
    MotionBefore before{};
    bool requested{}, ready{}, inflight{};
    std::atomic<std::uint32_t> live{};
    std::array<std::atomic<std::uint64_t>, 5> routes{};
};
MotionProbe motion_probe;

std::uint32_t motion_route_count(std::uint64_t sequence, MotionRoute route) noexcept {
    const auto word = motion_probe.routes[static_cast<std::size_t>(route)].load(std::memory_order_acquire);
    return (word >> 32) == sequence ? static_cast<std::uint32_t>(word) : 0;
}
std::uint32_t motion_route(std::uint64_t sequence, MotionRoute route) noexcept {
    auto& counter = motion_probe.routes[static_cast<std::size_t>(route)];
    auto word = counter.load(std::memory_order_acquire);
    const auto limit = route == MotionRoute::entries ? mp::callback_limit : UINT32_MAX;
    for (unsigned attempt = 0; attempt < 4; ++attempt) {
        if ((word >> 32) != sequence || static_cast<std::uint32_t>(word) >= limit) return 0;
        if (counter.compare_exchange_strong(word, word + 1, std::memory_order_acq_rel))
            return static_cast<std::uint32_t>(word) + 1;
    }
    return 0;
}
void motion_routes(mp::Routing& out, std::uint64_t sequence) noexcept {
    out.entries = motion_route_count(sequence, MotionRoute::entries);
    out.matching = motion_route_count(sequence, MotionRoute::matching);
    out.other = motion_route_count(sequence, MotionRoute::other);
    out.rejected = motion_route_count(sequence, MotionRoute::rejected);
    out.dropped = motion_route_count(sequence, MotionRoute::dropped);
    out.limit_reached = out.entries == mp::callback_limit;
}
void motion_finish(mp::Status status, std::uint64_t now) noexcept {
    auto& p = motion_probe;
    p.live.store(0, std::memory_order_release);
    p.result.status = status;
    p.result.elapsed_ms = static_cast<double>(now >= p.opened ? now - p.opened : 0);
    motion_routes(p.result.routing, p.sequence);
}
bool motion_clock(const actor_control_native::Actor& actor, mp::Epoch& out) noexcept {
    if (!actor.world_generation || !actor.lifetime_epoch || !TryAcquireSRWLockShared(&clock_feed.lock)) return false;
    const auto& f = clock_feed;
    const auto now = GetTickCount64();
    const bool valid = f.owner.base == actor.base && f.owner.entity == actor.entity && f.owner.core == actor.core &&
        f.owner.context == actor.context && f.owner.rig == actor.rig && f.game_context == actor.game_context &&
        f.world == actor.world && f.state == actor.world_state && f.serial &&
        f.serial == f.sequence.load(std::memory_order_acquire) && now >= f.observed && now - f.observed < 250 &&
        calibrated(f.seconds) && std::isfinite(f.time) && f.time >= 0;
    if (valid) out = {actor.world_generation, actor.lifetime_epoch, actor.actor_epoch, f.serial, f.time, f.seconds};
    ReleaseSRWLockShared(&clock_feed.lock);
    float seconds{};
    return valid && peek(actor.context + r::context_seconds, seconds) && calibrated(seconds);
}
bool motion_newer(const mp::Epoch& value, const mp::Epoch& before) noexcept {
    return value.world_generation == before.world_generation && value.lifetime_epoch == before.lifetime_epoch &&
        value.actor_epoch == before.actor_epoch && value.serial > before.serial && value.time > before.time;
}
bool motion_matrix(std::uintptr_t at, mp::Matrix& out) noexcept {
    if (!pointer(at) || !peek(at, out)) return false;
    for (const auto value : out) if (!std::isfinite(value) || std::abs(value) > 1000000) return false;
    return true;
}
bool motion_packets(const actor_control_native::Actor& actor, std::uintptr_t& owner, std::uintptr_t& packets) noexcept {
    std::uintptr_t owner_after{}, packets_after{};
    return pointer(actor.rig) && peek(actor.rig + n::packet_owner, owner) && pointer(owner) &&
        peek(owner + n::packet_array, packets) && pointer(packets) &&
        peek(actor.rig + n::packet_owner, owner_after) && owner_after == owner &&
        peek(owner + n::packet_array, packets_after) && packets_after == packets;
}
bool motion_endpoints(const actor_control_native::Actor& actor, std::uintptr_t owner, std::uintptr_t packets,
    mp::Endpoints& out) noexcept {
    std::uintptr_t owner_after{}, packets_after{};
    if (!motion_packets(actor, owner_after, packets_after) || owner_after != owner || packets_after != packets ||
        !motion_matrix(actor.rig + ma::root, out.root) || !motion_matrix(actor.rig + ma::inverse, out.inverse)) return false;
    for (std::size_t i = 0; i < out.caches.size(); ++i)
        if (!motion_matrix(actor.rig + ma::caches[i], out.caches[i])) return false;
    for (std::size_t i = 0; i < out.packets.size(); ++i)
        if (!motion_matrix(packets + i*n::packet_stride + n::transform, out.packets[i]) ||
            !peek(packets + i*n::packet_stride + n::pending, out.flags[i])) return false;
    return motion_packets(actor, owner_after, packets_after) && owner_after == owner && packets_after == packets;
}
bool motion_snapshot(const actor_control_native::Actor& actor, std::uintptr_t owner, std::uintptr_t packets,
    mp::Epoch& epoch, mp::Endpoints& endpoints) noexcept {
    mp::Epoch after{}; mp::Endpoints check{};
    return motion_clock(actor, epoch) && motion_endpoints(actor, owner, packets, endpoints) &&
        motion_endpoints(actor, owner, packets, check) && check == endpoints && motion_clock(actor, after) && after == epoch;
}
std::uint64_t motion_before(const NoBailMoverEvent& event) noexcept {
    const auto live = motion_probe.live.load(std::memory_order_acquire);
    if (!live) return 0;
    const auto invocation = motion_route(live, MotionRoute::entries);
    if (!invocation) { (void)motion_route(live, MotionRoute::dropped); return 0; }
    if (!TryAcquireSRWLockShared(&motion_probe.lock)) { (void)motion_route(live, MotionRoute::dropped); return 0; }
    const auto& p = motion_probe;
    const bool pending = p.sequence == live && p.result.status == mp::Status::pending && GetTickCount64() < p.deadline;
    const auto actor = p.actor;
    const auto armed = p.result.armed_epoch;
    const bool busy = p.inflight || p.result.record.present;
    ReleaseSRWLockShared(&motion_probe.lock);
    if (!pending) return 0;
    if (event.rig != actor.rig || event.context != actor.context) { (void)motion_route(live, MotionRoute::other); return 0; }
    (void)motion_route(live, MotionRoute::matching);
    if (busy) { (void)motion_route(live, MotionRoute::dropped); return 0; }
    MotionBefore value;
    actor_control_native::Actor current;
    std::array<float, 4> input_after{};
    value.cookie = (std::uint64_t{live} << 32) | invocation;
    value.actor = actor; value.input = event.input;
    auto& record = value.record;
    record.flag = event.flag; record.unchanged_forwarding = true;
    bool valid = actor_control_native::observe_actor(current) && current == actor && pointer(event.input) &&
        peek(event.input, record.input) && motion_packets(actor, value.packet_owner, value.packets) &&
        motion_snapshot(actor, value.packet_owner, value.packets, record.before_epoch, record.before) &&
        motion_newer(record.before_epoch, armed) && peek(event.input, input_after) && input_after == record.input;
    for (const auto component : record.input) if (!std::isfinite(component)) valid = false;
    valid = valid && actor_control_native::observe_actor(current) && current == actor;
    if (!valid) { (void)motion_route(live, MotionRoute::rejected); return 0; }
    if (!TryAcquireSRWLockExclusive(&motion_probe.lock)) { (void)motion_route(live, MotionRoute::dropped); return 0; }
    auto& selected = motion_probe;
    const bool accept = selected.sequence == live && selected.result.status == mp::Status::pending &&
        selected.actor == actor && !selected.inflight && !selected.result.record.present && GetTickCount64() < selected.deadline;
    if (accept) { selected.before = value; selected.inflight = true; }
    ReleaseSRWLockExclusive(&selected.lock);
    return accept ? value.cookie : 0;
}
void motion_after(const NoBailMoverEvent& event, std::uint64_t cookie) noexcept {
    if (!cookie) return;
    const auto sequence = cookie >> 32;
    if (!TryAcquireSRWLockShared(&motion_probe.lock)) { (void)motion_route(sequence, MotionRoute::dropped); return; }
    const auto& p = motion_probe;
    const bool pending = p.sequence == sequence && p.result.status == mp::Status::pending && p.inflight && p.before.cookie == cookie;
    MotionBefore value;
    if (pending) value = p.before;
    ReleaseSRWLockShared(&motion_probe.lock);
    if (!pending) return;
    actor_control_native::Actor current;
    const auto& actor = value.actor;
    auto record = value.record;
    const bool valid = event.rig == actor.rig && event.context == actor.context && event.input == value.input && event.flag == record.flag &&
        actor_control_native::observe_actor(current) && current == actor &&
        motion_snapshot(actor, value.packet_owner, value.packets, record.after_epoch, record.after) &&
        record.after_epoch == record.before_epoch && actor_control_native::observe_actor(current) && current == actor;
    if (!TryAcquireSRWLockExclusive(&motion_probe.lock)) { (void)motion_route(sequence, MotionRoute::dropped); return; }
    auto& selected = motion_probe;
    if (selected.sequence == sequence && selected.result.status == mp::Status::pending && selected.inflight && selected.before.cookie == cookie) {
        selected.inflight = false;
        if (valid && GetTickCount64() < selected.deadline) {
            record.present = true; selected.result.record = record;
            // Freeze the first admitted complete record; later client recapture
            // determines observed/invalidated. No allocation is pinned here.
            selected.live.store(0, std::memory_order_release);
        } else (void)motion_route(sequence, MotionRoute::rejected);
    }
    ReleaseSRWLockExclusive(&selected.lock);
}
std::uint64_t motion_observer(const NoBailMoverEvent& event, std::uint64_t cookie) noexcept {
    LastError error;
    if (event.edge == NoBailMoverEdge::before_original) return motion_before(event);
    motion_after(event, cookie); return 0;
}
void motion_tick(std::uintptr_t base, bool ready) noexcept {
    bool prepare{};
    {
        Locked lock(motion_probe.lock);
        auto& p = motion_probe;
        const auto now = GetTickCount64();
        if (p.sequence && p.result.status == mp::Status::pending) {
            if (!ready || p.base != base) motion_finish(mp::Status::invalidated, now);
            else if (now >= p.deadline) motion_finish(mp::Status::expired, now);
        }
        prepare = ready && p.requested && !p.ready;
        p.requested = false;
    }
    if (!prepare) return;
    // Deferred client-phase read-only setup. No synchronizer hook, allocation,
    // new mover detour or native motion claim is requested by a cold begin.
    if (!supported_build::running_image_matches(base) || !matches(base, c::physics_world)) return;
    clock_world.store(reinterpret_cast<World>(base + c::physics_world.rva), std::memory_order_release);
    if (!add_no_bail_step_listener(&physics_step) || !add_no_bail_mover_observer(&motion_observer)) return;
    Locked lock(motion_probe.lock);
    motion_probe.base = base; motion_probe.ready = true;
}
} // namespace

std::string begin_motion_refresh_probe(std::uint64_t owner, std::uint64_t& sequence) {
    LastError error; sequence = 0;
    try {
        if (!owner || !eligible()) return "native motion observation requires the current local client phase";
        {
            Locked lock(motion_probe.lock);
            if (!motion_probe.ready) {
                motion_probe.requested = true;
                return "native motion observation waiting for deferred read-only clock setup; begin again explicitly";
            }
        }
        if (!no_bail_mover_observation_available(service.base))
            return "native motion observation waiting for an actual attested mover hook entry";
        for (const auto* prefix : {&ma::rebuild_root, &ma::refresh_caches, &ma::refresh_packets,
            &n::packet_a_writer, &n::packet_b_writer, &n::packet_tail_writer})
            if (!matches(service.base, *prefix)) return "native motion observation source bytes differ";
        actor_control_native::Actor actor, current;
        mp::Epoch epoch{}, after{};
        if (!actor_control_native::observe_actor(actor) || actor.ticket || actor.base != service.base || actor.client != service.client ||
            !motion_clock(actor, epoch) || !actor_control_native::observe_actor(current) || current != actor ||
            !motion_clock(actor, after) || after != epoch) return "native motion observation actor or clock unavailable";
        Locked lock(motion_probe.lock);
        auto& p = motion_probe;
        const auto now = GetTickCount64();
        if (p.sequence && p.result.status == mp::Status::pending && now < p.deadline)
            return "a bounded native motion observation is already pending";
        if (p.generation == UINT32_MAX || p.base != actor.base || now > UINT64_MAX - mp::lifetime_ms)
            return "native motion observation generation or source unavailable";
        p.live.store(0, std::memory_order_release);
        p.owner = owner; p.sequence = ++p.generation; p.actor = actor;
        p.opened = now; p.deadline = now + mp::lifetime_ms; p.inflight = false; p.before = {};
        p.result = {}; p.result.armed_epoch = epoch;
        for (auto& route : p.routes) route.store(p.sequence << 32, std::memory_order_release);
        p.live.store(static_cast<std::uint32_t>(p.sequence), std::memory_order_release);
        sequence = p.sequence; return {};
    } catch (...) { return "native motion observation failed closed"; }
}
std::string poll_motion_refresh_probe(std::uint64_t owner, std::uint64_t sequence, mp::Result& out) {
    LastError error; out = {};
    try {
        if (!owner || !sequence || GetCurrentThreadId() != service.thread) return "native motion observation is client phase only";
        actor_control_native::Actor expected;
        std::uintptr_t packet_owner{}, packets{};
        bool has_record{};
        {
            Locked lock(motion_probe.lock);
            const auto& p = motion_probe;
            if (p.owner != owner || p.sequence != sequence) return "native motion observation owner or sequence unavailable";
            if (p.result.status != mp::Status::pending) { out = p.result; return {}; }
            expected = p.actor;
            has_record = p.result.record.present;
            if (has_record) { packet_owner = p.before.packet_owner; packets = p.before.packets; }
        }
        actor_control_native::Actor current, after;
        mp::Epoch epoch{}, checked{};
        std::uintptr_t owner_now{}, packets_now{};
        const bool valid = eligible() && actor_control_native::observe_actor(current) && current == expected &&
            motion_clock(current, epoch) && (!has_record || (motion_packets(current, owner_now, packets_now) &&
                owner_now == packet_owner && packets_now == packets)) &&
            actor_control_native::observe_actor(after) && after == expected &&
            motion_clock(after, checked) && checked == epoch;
        Locked lock(motion_probe.lock);
        auto& p = motion_probe;
        if (p.owner != owner || p.sequence != sequence) return "native motion observation owner or sequence changed";
        if (p.result.status == mp::Status::pending) {
            const auto now = GetTickCount64();
            if (now >= p.deadline) motion_finish(mp::Status::expired, now);
            else if (!valid || current != p.actor) motion_finish(mp::Status::invalidated, now);
            // A record arriving while this poll was outside the lock did not
            // receive this poll's saved O/P closure. Confirm on a later poll.
            else if (has_record && p.result.record.present && motion_newer(epoch, p.result.record.after_epoch)) {
                p.result.confirmed_epoch = epoch; p.result.client_revalidated = true;
                motion_finish(mp::Status::observed, now);
            } else if (!p.inflight && !p.result.record.present && motion_route_count(sequence, MotionRoute::entries) == mp::callback_limit)
                motion_finish(mp::Status::expired, now);
            if (p.result.status == mp::Status::pending) {
                p.result.elapsed_ms = static_cast<double>(now - p.opened); motion_routes(p.result.routing, sequence);
            }
        }
        out = p.result; return {};
    } catch (...) { return "native motion observation poll failed closed"; }
}
void cancel_motion_refresh_probes(std::uint64_t owner) noexcept {
    LastError error;
    if (!owner) return;
    Locked lock(motion_probe.lock);
    auto& p = motion_probe;
    if (p.owner != owner) return;
    p.live.store(0, std::memory_order_release);
    p.owner = p.sequence = p.opened = p.deadline = 0;
    p.actor = {}; p.result = {}; p.before = {}; p.inflight = false;
}
