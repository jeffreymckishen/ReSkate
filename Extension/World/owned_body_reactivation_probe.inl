// Included once by owned_bodies.cpp. Only an explicitly armed qualification
// build can enter this retained-body diagnostic. No ordinary authority returns.
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
namespace {
namespace rp = body_reactivation_probe;
static_assert(rp::qualified_categories == r::safe_categories && rp::qualified_collisions == r::safe_world_collisions);
struct ReactivationProbe {
    std::uint64_t owner{}, sequence{}, generation{}, opened{}, run_deadline{}, cleanup_deadline{};
    std::uint64_t world_generation{}, original_parked_ms{}, phase_ms{};
    std::uintptr_t base{};
    Handle handle{};
    Anchor anchor{};
    NativeHandle body{};
    std::array<NativeHandle, maximum_capsules> shapes{};
    std::size_t made{};
    Definition definition{};
    RetirementBasis basis{};
    RetainedParkReceipt initial_park{};
    // Only the trusted Follow ACK can supply this immutable terminal history.
    // A zero sequence retains the original never-held diagnostic path.
    std::uint64_t completed_ack_sequence{};
    RetainedParkReceipt completed_ack_park{};
    Epoch phase_epoch{};
    rp::QualificationCheck qualification{};
    rp::Stage next_stage{rp::Stage::transform};
    rp::Status failure_status{rp::Status::invalidated};
    rp::Result result{};
    bool revoked{}, cleanup_attempted{}, dynamic_observed{};
};
ReactivationProbe reactivation_probe;
std::atomic<std::uint64_t> reactivation_live_owner{};
std::atomic<bool> reactivation_close_requested{};

bool reactivation_bytes() noexcept {
    if (!supported_build::running_image_matches(service.base) || !service.hooked.load(std::memory_order_acquire) ||
        !service.original.load(std::memory_order_acquire) || service.api.base != service.base ||
        !service.api.motion || !service.api.transform || !service.api.categories || !service.api.collides ||
        !service.api.linear || !service.api.angular || !service.api.clear_force || !service.api.clear_torque || !service.api.wake)
        return false;
    // The synchronizer may already be Detoured. Its installed original is checked
    // above; only these unchanged native leaves are fingerprinted again.
    for (const auto* prefix : {&c::physics_world, &c::set_motion_type, &c::set_transform,
        &c::set_categories, &c::set_collides_with, &c::set_linear_velocity, &c::set_angular_velocity,
        &c::wake_body, &c::body_valid, &c::shape_valid, &r::overwrite_force, &r::overwrite_torque})
        if (!matches(service.base, *prefix)) return false;
    return true;
}
bool reactivation_allocation(const Slot& s) noexcept {
    return s.body_observed && !s.creation_failed && s.allocation.body_confirmed && s.made &&
        s.made == s.definition.count && s.made <= maximum_capsules &&
        s.allocation.shapes_attempted == s.made && s.allocation.shapes_confirmed == s.made;
}
bool reactivation_debt_free(const Slot& s) noexcept {
    return !s.mailbox.count && !s.mailbox.pending && !s.mailbox.producing;
}
bool reactivation_definition(const Definition& a, const Definition& b) noexcept {
    if (a.count != b.count || a.count > maximum_capsules || a.mass != b.mass || a.inertia != b.inertia ||
        a.position != b.position || a.rotation != b.rotation) return false;
    for (std::size_t i = 0; i < a.count; ++i)
        if (a.capsules[i].a != b.capsules[i].a || a.capsules[i].b != b.capsules[i].b || a.capsules[i].radius != b.capsules[i].radius) return false;
    return true;
}
bool reactivation_completed_history(const ReactivationProbe& p, const Slot& s) noexcept {
    // This is optional SDK provenance, not a native retirement certificate.
    // Pair both saved receipts with the exact basis; no fresh observation may
    // replace the original completed handoff or restore a cleared latch.
    return p.completed_ack_sequence && !s.never_held && s.release_requested && s.mailbox.failed &&
        s.completed_ack_sequence == p.completed_ack_sequence &&
        matches_retained_park_locked(p.owner, p.basis, p.completed_ack_park) &&
        matches_retained_park_locked(p.owner, s.completed_ack_basis, p.completed_ack_park) &&
        matches_retained_park_locked(p.owner, p.basis, s.completed_ack_park) &&
        s.completed_ack_park.observed_epoch() == p.completed_ack_park.observed_epoch() &&
        s.completed_ack_park.observed_ms() == p.completed_ack_park.observed_ms() &&
        s.completed_ack_park.parked_ms() == p.completed_ack_park.parked_ms();
}
bool reactivation_other_probe_pending() noexcept {
    if (service.probe.sequence && service.probe.result.status == body_sync_probe::Status::pending) return true;
    // A busy observer is unknown, even if its last copied status was terminal.
    if (!TryAcquireSRWLockShared(&motion_probe.lock)) return true;
    const bool pending = motion_probe.requested || motion_probe.inflight ||
        (motion_probe.sequence && motion_probe.result.status == mp::Status::pending);
    ReleaseSRWLockShared(&motion_probe.lock);
    return pending;
}
bool reactivation_dependency_current(const ReactivationProbe& p, const Slot& s) noexcept {
    return p.completed_ack_sequence ? reactivation_allocation(s) && reactivation_completed_history(p, s) &&
        !reactivation_other_probe_pending() : s.never_held;
}
Slot* reactivation_slot(const ReactivationProbe& p) noexcept {
    auto* s = lookup(p.owner, p.handle);
    if (!s || s->body != p.body || s->shapes != p.shapes || s->made != p.made ||
        !s->anchor.same(p.anchor) || !reactivation_definition(s->definition, p.definition)) return nullptr;
    return s;
}
bool reactivation_current(const ReactivationProbe& p, const Slot& s, bool retained = true) noexcept {
    if (service.base != p.base || service.world_generation != p.world_generation || service.world != p.anchor.world ||
        service.state != p.anchor.state || service.client != p.anchor.client || service.context != p.anchor.context ||
        s.retained != retained || s.active == retained || s.release_hold || !reactivation_debt_free(s) || !fresh(s) || !sync_native_body(s.anchor, s.body)) return false;
    std::uintptr_t mappings{}, after{};
    if (!peek(s.anchor.state + r::shape_body_indices, mappings) || !pointer(mappings)) return false;
    for (std::size_t i = 0; i < s.made; ++i) {
        std::uint32_t attached{}, again{}; const auto at = mappings + std::uintptr_t{s.shapes[i].index} * sizeof(std::uint32_t);
        if (!shape_current(s, i) || !peek(at, attached) || attached != s.body.index ||
            !peek(at, again) || again != attached || !shape_current(s, i)) return false;
    }
    return peek(s.anchor.state + r::shape_body_indices, after) && after == mappings && body_current(s);
}
void reactivation_fail(rp::Check check, rp::Status status = rp::Status::invalidated, std::size_t shape = maximum_capsules) noexcept {
    auto& p = reactivation_probe;
    if (p.result.first_failure == rp::Check::none) {
        p.result.first_failure = check; p.result.failure_phase = p.result.phase; p.failure_status = status;
        if (shape < maximum_capsules) { p.result.failure_shape_known = true; p.result.failure_shape = static_cast<std::uint8_t>(shape); }
    }
    p.revoked = true;
    if (auto* s = reactivation_slot(p)) taint_reuse(*s);
    if (p.result.phase != rp::Phase::await_repark && p.result.phase != rp::Phase::terminal) p.result.phase = rp::Phase::repark;
}
bool reactivation_record(rp::Stage stage, bool passed, const Epoch& epoch = {}, const rp::Observation& observation = {},
    bool historical_park_basis = false) noexcept {
    auto& p = reactivation_probe;
    if (p.result.record_count >= p.result.records.size() || (p.result.record_count &&
        stage <= p.result.records[p.result.record_count - 1].stage) ||
        (historical_park_basis && (stage != rp::Stage::initial_park || !passed || observation.available || !p.completed_ack_sequence))) {
        reactivation_fail(rp::Check::observation); return false;
    }
    auto& record = p.result.records[p.result.record_count++];
    record.stage = stage; record.passed = passed; record.historical_park_basis = historical_park_basis;
    record.epoch = epoch; record.observation = observation;
    return true;
}
void reactivation_finish(bool confirmed, std::uint64_t now) noexcept {
    auto& p = reactivation_probe;
    p.result.cleanup = confirmed ? rp::Cleanup::confirmed : rp::Cleanup::unconfirmed;
    p.result.cleanup_owed = !confirmed;
    p.result.status = p.result.first_failure == rp::Check::none && p.dynamic_observed && confirmed ? rp::Status::observed : p.failure_status;
    p.result.phase = rp::Phase::terminal;
    p.result.elapsed_ms = static_cast<double>(now >= p.opened ? now - p.opened : 0);
    if (!confirmed) if (auto* s = reactivation_slot(p)) { s->quarantined = true; taint_reuse(*s); }
}
bool reactivation_masks(const Slot& s, std::uint32_t collision,
    std::array<std::uint32_t, maximum_capsules>& categories, std::array<std::uint32_t, maximum_capsules>& collisions) noexcept {
    std::uintptr_t category_source{}, collision_source{}, after{};
    if (!peek(s.anchor.state + r::shape_categories, category_source) || !pointer(category_source) ||
        !peek(s.anchor.state + r::shape_collides, collision_source) || !pointer(collision_source)) return false;
    for (std::size_t i = 0; i < s.made; ++i) {
        const auto offset = std::uintptr_t{s.shapes[i].index} * sizeof(std::uint32_t);
        if (!peek(category_source + offset, categories[i]) || categories[i] != r::safe_categories ||
            !peek(collision_source + offset, collisions[i]) || collisions[i] != collision || !shape_current(s, i)) return false;
    }
    return peek(s.anchor.state + r::shape_categories, after) && after == category_source &&
        peek(s.anchor.state + r::shape_collides, after) && after == collision_source;
}
bool reactivation_observe(const ReactivationProbe& p, const Slot& s, bool dynamic, std::uint32_t collision,
    rp::Observation& out) noexcept {
    rp::Observation value; value.dynamic = dynamic; value.shape_count = static_cast<std::uint8_t>(s.made);
    const auto qualify = [&](const Slot& slot) noexcept { return reactivation_current(p, slot) && pool_current(slot, dynamic); };
    if (!observe_checked(s, value.sample, qualify)) return false;
    std::uintptr_t dynamics{}, again{}, force_source{}, torque_source{};
    std::uint32_t bits{}, checked{}; const auto word = std::uintptr_t{s.body.index >> 5} * sizeof(std::uint32_t);
    const auto bit = 1U << (s.body.index & 31U);
    Ring linear_header{}, angular_header{}; V4 linear{}, angular{};
    if (!peek(s.anchor.state + r::dynamic_bits, dynamics) || !pointer(dynamics) || !peek(dynamics + word, bits) ||
        ((bits & bit) != 0) != dynamic || !ring(s, r::velocity_ring, linear_header, linear) ||
        !ring(s, r::spin_ring, angular_header, angular) ||
        !array4(s.anchor.state, r::pending_force, s.body.index, value.force, force_source) ||
        !array4(s.anchor.state, r::pending_torque, s.body.index, value.torque, torque_source) ||
        !reactivation_masks(s, collision, value.categories, value.collisions)) return false;
    if (!dynamic && (linear != V4{} || angular != V4{0, 0, 0, angular[3]} || value.force != V4{} || value.torque != V4{})) return false;
    value.angular_fourth = angular[3];
    std::array<std::uint32_t, maximum_capsules> categories{}, collisions{};
    Ring header{}; V4 vector_value{};
    if (!peek(s.anchor.state + r::dynamic_bits, again) || again != dynamics || !peek(dynamics + word, checked) || checked != bits ||
        !ring(s, r::velocity_ring, header, vector_value) || header != linear_header || vector_value != linear ||
        !ring(s, r::spin_ring, header, vector_value) || header != angular_header || vector_value != angular ||
        !array4(s.anchor.state, r::pending_force, s.body.index, vector_value, again) || again != force_source || vector_value != value.force ||
        !array4(s.anchor.state, r::pending_torque, s.body.index, vector_value, again) || again != torque_source || vector_value != value.torque ||
        !reactivation_masks(s, collision, categories, collisions) || categories != value.categories || collisions != value.collisions || !qualify(s)) return false;
    Epoch closing{}; closing.world = service.world_generation; closing.body = s.handle.generation;
    std::uint64_t observed{};
    if (!clock(s.anchor, closing, &observed) || closing != value.sample.epoch || !observed ||
        GetTickCount64() < observed || GetTickCount64() - observed >= command_lifetime_ms) return false;
    value.available = true; out = value; return true;
}
bool reactivation_later(const ReactivationProbe& p, const Slot& s, bool& waiting, Epoch& epoch) noexcept {
    waiting = false; epoch.world = service.world_generation; epoch.body = s.handle.generation;
    std::uint64_t observed{};
    if (!clock(s.anchor, epoch, &observed)) return false;
    const auto now = GetTickCount64();
    if (!observed || now < observed || now - observed >= command_lifetime_ms) return false;
    waiting = epoch.serial <= p.phase_epoch.serial || epoch.time <= p.phase_epoch.time || observed <= p.phase_ms;
    return true;
}
bool reactivation_write_guard(Slot& s, bool cleanup, std::size_t shape = maximum_capsules) noexcept {
    auto& p = reactivation_probe;
    const auto deadline = cleanup ? p.cleanup_deadline : p.run_deadline;
    const auto expired = [&]() noexcept {
        if (GetTickCount64() < deadline) return false;
        reactivation_fail(cleanup ? rp::Check::cleanup_deadline : rp::Check::run_deadline, rp::Status::expired, shape); return true;
    };
    if (expired()) return false;
    if (!eligible() || !reactivation_current(p, s) || !reactivation_bytes()) { reactivation_fail(rp::Check::identity, rp::Status::invalidated, shape); return false; }
    if (!cleanup && (p.revoked || reactivation_close_requested.load(std::memory_order_acquire) ||
        !reactivation_dependency_current(p, s) || s.reuse_faulted || s.owner_closed || s.quarantined ||
        service.owner_close_uncertain.load(std::memory_order_acquire))) { reactivation_fail(rp::Check::qualification, rp::Status::invalidated, shape); return false; }
    Epoch before{}; before.world = p.world_generation; before.body = p.handle.generation;
    std::uint64_t observed{};
    if (!clock(s.anchor, before, &observed) || !observed) { reactivation_fail(rp::Check::clock); return false; }
    if (!cleanup && p.next_stage != rp::Stage::wake) {
        std::uintptr_t dynamics{}, again{}; std::uint32_t bits{}, checked{};
        const auto word = std::uintptr_t{s.body.index >> 5} * sizeof(std::uint32_t); const auto bit = 1U << (s.body.index & 31U);
        Ring header{}; V4 linear{}, angular{};
        if (!peek(s.anchor.state + r::dynamic_bits, dynamics) || !pointer(dynamics) || !peek(dynamics + word, bits) || (bits & bit) ||
            !pending_zero(s) || !ring(s, r::velocity_ring, header, linear) || linear != V4{} ||
            !ring(s, r::spin_ring, header, angular) || angular != V4{0,0,0,angular[3]} ||
            !peek(s.anchor.state + r::dynamic_bits, again) || again != dynamics || !peek(dynamics + word, checked) || checked != bits) {
            reactivation_fail(rp::Check::observation, rp::Status::invalidated, shape); return false;
        }
    }
    Epoch closing{}; closing.world = p.world_generation; closing.body = p.handle.generation;
    std::uint64_t observed_after{};
    if (!clock(s.anchor, closing, &observed_after) || closing != before || observed_after != observed) {
        reactivation_fail(rp::Check::clock); return false;
    }
    if (!cleanup && p.completed_ack_sequence && (s.reuse_faulted || s.owner_closed || s.quarantined ||
        service.owner_close_uncertain.load(std::memory_order_acquire) || !reactivation_dependency_current(p, s))) {
        reactivation_fail(rp::Check::dependency); return false;
    }
    const auto now = GetTickCount64();
    if (now < observed || now - observed >= command_lifetime_ms) { reactivation_fail(rp::Check::clock); return false; }
    // Native validation and fingerprint reads can themselves consume the budget.
    return !expired();
}
bool reactivation_park_check(Slot& s) noexcept { return reactivation_write_guard(s, true); }
void reactivation_tick_metadata(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept {
    Locked lock(service.lock); auto& p = reactivation_probe;
    if (!p.sequence || p.result.status != rp::Status::pending) return;
    const auto now = GetTickCount64(); p.result.elapsed_ms = static_cast<double>(now >= p.opened ? now - p.opened : 0);
    if (reactivation_close_requested.load(std::memory_order_acquire)) reactivation_fail(rp::Check::owner_closed);
    if (!ready) reactivation_fail(rp::Check::client_phase);
    if (base != p.base || client != p.anchor.client) reactivation_fail(rp::Check::identity);
    if (now >= p.run_deadline && !p.cleanup_attempted) reactivation_fail(rp::Check::run_deadline, rp::Status::expired);
    if (now >= p.cleanup_deadline) {
        reactivation_fail(rp::Check::cleanup_deadline, rp::Status::expired);
        (void)reactivation_record(rp::Stage::repark_observed, false);
        reactivation_finish(false, now);
    }
}
void reactivation_tick_advance() noexcept {
    auto& p = reactivation_probe;
    if (!p.sequence || p.result.status != rp::Status::pending) return;
    // The process-lifetime facade verifier never enters World. It runs outside
    // this lock on every tick, including every separate activation stage.
    const bool qualified = p.qualification && p.qualification(p.owner);
    RetainedParkReceipt observed_park; ParkObservationDiagnostic diagnostic;
    bool observed_initial{};
    if (qualified && !p.revoked && p.result.phase == rp::Phase::await_initial_park && eligible())
        observed_initial = observe_retained_park(p.owner, p.basis, observed_park, diagnostic);
    if (!TryAcquireSRWLockExclusive(&service.lock)) return;
    struct Unlock { ~Unlock() { ReleaseSRWLockExclusive(&service.lock); } } unlock;
    if (!p.sequence || p.result.status != rp::Status::pending) return;
    if (!qualified) reactivation_fail(rp::Check::qualification);
    if (reactivation_close_requested.load(std::memory_order_acquire)) reactivation_fail(rp::Check::owner_closed);
    if (GetTickCount64() >= p.cleanup_deadline) {
        reactivation_fail(rp::Check::cleanup_deadline, rp::Status::expired);
        (void)reactivation_record(rp::Stage::repark_observed, false);
        reactivation_finish(false, GetTickCount64()); return;
    }
    if (!eligible()) { reactivation_fail(rp::Check::client_phase); return; }
    auto* s = reactivation_slot(p);
    if (!s || !reactivation_current(p, *s) || s->parked_ms != p.original_parked_ms) { reactivation_fail(rp::Check::identity); return; }
    // Lost completion provenance invalidates the observation as well as every
    // later activation write. Cleanup still owns the unchanged retained body.
    if (p.completed_ack_sequence && (s->reuse_faulted || s->owner_closed || s->quarantined ||
        service.owner_close_uncertain.load(std::memory_order_acquire) || !reactivation_dependency_current(p, *s)))
        reactivation_fail(rp::Check::dependency);
    if (GetTickCount64() >= p.run_deadline && !p.cleanup_attempted) reactivation_fail(rp::Check::run_deadline, rp::Status::expired);
    if (p.result.phase == rp::Phase::await_initial_park) {
        if (!observed_initial) {
            if (diagnostic.check == ParkObservationCheck::clock_serial || diagnostic.check == ParkObservationCheck::clock_time ||
                diagnostic.check == ParkObservationCheck::clock_after_fence || diagnostic.check == ParkObservationCheck::clock_after_park) return;
            reactivation_fail(rp::Check::observation); return;
        }
        rp::Observation observation;
        if (!reactivation_observe(p, *s, false, 0, observation) || observation.sample.epoch != observed_park.observed_epoch()) {
            reactivation_fail(rp::Check::observation); return;
        }
        p.initial_park = observed_park;
        if (!reactivation_record(rp::Stage::initial_park_observed, true, observation.sample.epoch, observation)) return;
        p.result.phase = rp::Phase::activation; return;
    }
    if (p.result.phase == rp::Phase::activation) {
        if (!reactivation_write_guard(*s, false)) return;
        const auto stage = p.next_stage; bool ok{};
        rp::Observation before_stage;
        const bool before_dynamic = stage == rp::Stage::wake;
        const auto before_collision = stage >= rp::Stage::motion ? r::safe_world_collisions : 0U;
        if (!reactivation_observe(p, *s, before_dynamic, before_collision, before_stage) || !reactivation_write_guard(*s, false)) {
            reactivation_fail(rp::Check::observation); return;
        }
        std::size_t failed_shape = maximum_capsules;
        rp::Check check = rp::Check::observation;
        if (stage == rp::Stage::transform) {
            check = rp::Check::transform; rp::Observation parked;
            const auto& d = p.definition;
            alignas(16) const std::array<float, 8> pose{d.rotation[0],d.rotation[1],d.rotation[2],d.rotation[3],d.position[0],d.position[1],d.position[2],1};
            ok = reactivation_observe(p, *s, false, 0, parked) && reactivation_write_guard(*s, false) &&
                vector(service.api.transform, s->body, pose.data()) && reactivation_current(p, *s);
        } else if (stage == rp::Stage::categories || stage == rp::Stage::collisions) {
            check = stage == rp::Stage::categories ? rp::Check::categories : rp::Check::collisions; ok = true;
            for (std::size_t i = 0; i < s->made; ++i) {
                const auto call = stage == rp::Stage::categories ? service.api.categories : service.api.collides;
                const auto value = stage == rp::Stage::categories ? r::safe_categories : r::safe_world_collisions;
                std::uintptr_t source{}; std::uint32_t actual{};
                const auto offset = stage == rp::Stage::categories ? r::shape_categories : r::shape_collides;
                if (!reactivation_write_guard(*s, false, i) || !shape_current(*s, i) || !reactivation_write_guard(*s, false, i) || !mask(call, s->shapes[i], value) ||
                    !shape_current(*s, i) || !peek(s->anchor.state + offset, source) || !pointer(source) ||
                    !peek(source + std::uintptr_t{s->shapes[i].index} * sizeof(std::uint32_t), actual) || actual != value) {
                    ok = false; failed_shape = i; break;
                }
            }
        } else if (stage == rp::Stage::motion) {
            check = rp::Check::motion;
            ok = set_int(service.api.motion, s->body, 3) && reactivation_current(p, *s) && pool_current(*s, true);
        } else if (stage == rp::Stage::wake) {
            check = rp::Check::wake;
            ok = touch(service.api.wake, s->body) && reactivation_current(p, *s) && pool_current(*s, true);
        }
        rp::Observation observation;
        const bool dynamic = stage == rp::Stage::motion || stage == rp::Stage::wake;
        const auto collision = stage >= rp::Stage::collisions ? r::safe_world_collisions : 0U;
        ok = ok && reactivation_observe(p, *s, dynamic, collision, observation);
        if (ok && stage == rp::Stage::transform)
            ok = observation.sample.position == p.result.target_position && observation.sample.rotation == p.result.target_rotation;
        if (GetTickCount64() >= p.run_deadline) { reactivation_fail(rp::Check::run_deadline, rp::Status::expired); ok = false; }
        if (!reactivation_record(stage, ok, observation.available ? observation.sample.epoch : Epoch{}, observation)) return;
        if (!ok) { reactivation_fail(check, rp::Status::invalidated, failed_shape); return; }
        if (stage == rp::Stage::wake) {
            p.phase_epoch = observation.sample.epoch; p.phase_ms = GetTickCount64(); p.result.phase = rp::Phase::await_dynamic;
        } else p.next_stage = static_cast<rp::Stage>(static_cast<unsigned>(stage) + 1U);
        return;
    }
    if (p.result.phase == rp::Phase::await_dynamic) {
        bool waiting{}; Epoch epoch{};
        if (!reactivation_later(p, *s, waiting, epoch)) { reactivation_fail(rp::Check::clock); return; }
        if (waiting) return;
        rp::Observation observation;
        if (!reactivation_observe(p, *s, true, r::safe_world_collisions, observation) || observation.sample.epoch != epoch) {
            reactivation_fail(rp::Check::observation); return;
        }
        if (GetTickCount64() >= p.run_deadline) {
            reactivation_fail(rp::Check::run_deadline, rp::Status::expired);
            (void)reactivation_record(rp::Stage::dynamic_observed, false, epoch, observation); return;
        }
        if (!reactivation_record(rp::Stage::dynamic_observed, true, epoch, observation)) return;
        p.dynamic_observed = true; p.result.phase = rp::Phase::repark; return;
    }
    if (p.result.phase == rp::Phase::repark) {
        if (p.cleanup_attempted || !reactivation_write_guard(*s, true)) return;
        Epoch floor{}; floor.world = p.world_generation; floor.body = p.handle.generation;
        if (!clock(s->anchor, floor)) { reactivation_fail(rp::Check::clock); return; }
        p.cleanup_attempted = true;
        const bool parked = park(*s, &reactivation_park_check); // NOT retire(): original parked_ms is immutable
        p.phase_epoch = floor; p.phase_ms = GetTickCount64();
        (void)reactivation_record(rp::Stage::repark, parked, floor);
        if (!parked) reactivation_fail(rp::Check::repark);
        p.result.phase = rp::Phase::await_repark; return;
    }
    if (p.result.phase == rp::Phase::await_repark) {
        bool waiting{}; Epoch epoch{};
        if (!reactivation_later(p, *s, waiting, epoch)) { reactivation_fail(rp::Check::clock); return; }
        if (waiting) return;
        rp::Observation observation;
        const bool coherent = reactivation_observe(p, *s, false, 0, observation) && observation.sample.epoch == epoch;
        const auto finished = GetTickCount64();
        if (finished >= p.cleanup_deadline) {
            reactivation_fail(rp::Check::cleanup_deadline, rp::Status::expired);
            (void)reactivation_record(rp::Stage::repark_observed, false, epoch, observation);
            reactivation_finish(false, finished); return;
        }
        if (!coherent) { reactivation_fail(rp::Check::observation); return; }
        if (!reactivation_record(rp::Stage::repark_observed, true, epoch, observation)) return;
        reactivation_finish(true, finished);
    }
}
} // namespace

std::string begin_body_reactivation_probe(std::uint64_t owner, const Handle& handle, std::uint64_t& sequence,
    body_reactivation_probe::QualificationCheck qualification) {
    LastError error; sequence = 0;
    try {
        if (!owner || !qualification || !qualification(owner) || !eligible()) return "body reactivation qualification is not armed in this client phase";
        if (!reactivation_bytes()) return "body reactivation native leaves are not qualified";
        ReactivationProbe value;
        {
            if (!TryAcquireSRWLockExclusive(&service.lock)) return "body reactivation World is busy";
            struct Unlock { ~Unlock() { ReleaseSRWLockExclusive(&service.lock); } } unlock;
            const auto* s = lookup(owner, handle);
            if (reactivation_probe.sequence || reactivation_probe.generation == UINT64_MAX) return "body reactivation attempt unavailable";
            if (!s || s->quarantined || s->reuse_faulted || s->owner_closed || s->release_hold ||
                service.owner_close_uncertain.load(std::memory_order_acquire) ||
                !reactivation_allocation(*s) || !reactivation_debt_free(*s) || !fresh(*s)) return "body reactivation owner, allocation or debt unavailable";
            if (service.probe.sequence && service.probe.owner == owner && service.probe.handle == handle &&
                service.probe.result.status == body_sync_probe::Status::pending) return "another body observation is pending";
            value.owner = owner; value.handle = handle; value.base = service.base; value.world_generation = service.world_generation;
            value.anchor = s->anchor; value.body = s->body; value.shapes = s->shapes; value.made = s->made; value.definition = s->definition;
            if (s->never_held) {
                if (!s->active || s->retained || s->release_requested) return "body reactivation never-held authority unavailable";
            } else {
                value.completed_ack_sequence = s->completed_ack_sequence;
                value.basis = s->completed_ack_basis; value.completed_ack_park = s->completed_ack_park;
                value.original_parked_ms = s->parked_ms;
                if (!reactivation_completed_history(value, *s) || reactivation_other_probe_pending())
                    return "body reactivation completed Follow history unavailable";
            }
        }
        if (value.completed_ack_sequence) {
            // A retained body cannot become a measured source again. Observe its
            // parked state freshly using the original, non-restamped handoff.
            if (!observe_retained_park(owner, value.basis, value.initial_park) ||
                value.initial_park.observed_epoch().serial <= value.completed_ack_park.observed_epoch().serial ||
                value.initial_park.observed_epoch().time <= value.completed_ack_park.observed_epoch().time ||
                value.initial_park.observed_ms() <= value.completed_ack_park.observed_ms())
                return "body reactivation fresh completed park unavailable";
        } else {
            MeasuredSource source;
            if (!capture_source(owner, handle, source) || !capture_retirement_basis(owner, source, value.basis))
                return "body reactivation source or retirement basis unavailable";
        }
        if (!qualification(owner)) return "body reactivation qualification was revoked";
        if (!TryAcquireSRWLockExclusive(&service.lock)) return "body reactivation World is busy";
        struct Unlock { ~Unlock() { ReleaseSRWLockExclusive(&service.lock); } } unlock;
        auto* s = reactivation_slot(value);
        const bool completed_follow = value.completed_ack_sequence != 0;
        if (reactivation_probe.sequence || !s || !eligible() || !reactivation_bytes() || s->quarantined ||
            s->reuse_faulted || s->owner_closed || !reactivation_dependency_current(value, *s) || s->release_hold ||
            (!completed_follow && s->release_requested) ||
            service.owner_close_uncertain.load(std::memory_order_acquire) || !reactivation_allocation(*s) ||
            !reactivation_debt_free(*s) || !reactivation_current(value, *s, completed_follow)) return "body reactivation closing admission changed";
        rp::Observation parked_observation;
        if (completed_follow && (s->parked_ms != value.original_parked_ms ||
            !reactivation_observe(value, *s, false, 0, parked_observation) ||
            parked_observation.sample.epoch != value.initial_park.observed_epoch()))
            return "body reactivation closing parked observation unavailable";
        Epoch epoch{}; epoch.world = service.world_generation; epoch.body = handle.generation;
        std::uint64_t observed{}, observed_after{}; Epoch closing{};
        closing.world = service.world_generation; closing.body = handle.generation;
        const auto& admitted_epoch = completed_follow ? value.initial_park.observed_epoch() : value.basis.epoch();
        if (!clock(s->anchor, epoch, &observed) || epoch != admitted_epoch || !observed ||
            (completed_follow && observed != value.initial_park.observed_ms()) ||
            !reactivation_current(value, *s, completed_follow) || !reactivation_dependency_current(value, *s) ||
            !clock(s->anchor, closing, &observed_after) || closing != epoch || observed_after != observed)
            return "body reactivation closing clock unavailable";
        if (completed_follow && (reactivation_slot(value) != s || s->release_hold || s->reuse_faulted || s->owner_closed ||
            s->quarantined || !reactivation_debt_free(*s) || service.owner_close_uncertain.load(std::memory_order_acquire) ||
            !reactivation_dependency_current(value, *s))) return "body reactivation final completed history changed";
        const auto now = GetTickCount64();
        if (now < observed || now - observed >= command_lifetime_ms || now > UINT64_MAX - rp::cleanup_lifetime_ms)
            return "body reactivation closing clock unavailable";
        value.opened = now; value.run_deadline = now + rp::run_lifetime_ms; value.cleanup_deadline = now + rp::cleanup_lifetime_ms;
        value.sequence = value.generation = reactivation_probe.generation + 1; value.qualification = qualification;
        value.result.target_position = s->definition.position; value.result.target_rotation = s->definition.rotation;
        value.result.cycle_count = 1; value.result.cleanup_owed = true; value.phase_epoch = epoch; value.phase_ms = now;
        reactivation_probe = value;
        reactivation_close_requested.store(false, std::memory_order_release);
        reactivation_live_owner.store(owner, std::memory_order_release);
        if (completed_follow) {
            // Cleanup is now owned, before any future activation setter. The
            // first row is the prior completed park's write floor, not a new
            // park command. The second is the freshly checked parked state.
            // Neither ordinary authority nor the original park time changes.
            (void)reactivation_record(rp::Stage::initial_park, true, value.basis.epoch(), {}, true);
            (void)reactivation_record(rp::Stage::initial_park_observed, true, epoch, parked_observation);
            reactivation_probe.result.phase = rp::Phase::activation;
            sequence = reactivation_probe.sequence; return {};
        }
        // Admission owns cleanup from this point. Even a failed park returns its
        // opaque diagnostic sequence with ordinary body authority already closed.
        s->active = false; s->retained = true; s->latest = {};
        retire(*s, true, &reactivation_park_check);
        auto& p = reactivation_probe; p.original_parked_ms = s->parked_ms;
        const bool parked = s->retained && !s->active && !s->quarantined && s->parked_ms;
        (void)reactivation_record(rp::Stage::initial_park, parked, epoch);
        p.result.phase = rp::Phase::await_initial_park;
        if (!parked) reactivation_fail(rp::Check::initial_park);
        const auto finished = GetTickCount64();
        p.result.elapsed_ms = static_cast<double>(finished >= p.opened ? finished - p.opened : 0);
        if (finished >= p.run_deadline) reactivation_fail(rp::Check::run_deadline, rp::Status::expired);
        if (finished >= p.cleanup_deadline) {
            reactivation_fail(rp::Check::cleanup_deadline, rp::Status::expired);
            (void)reactivation_record(rp::Stage::repark_observed, false);
            reactivation_finish(false, finished);
        }
        sequence = p.sequence; return {};
    } catch (...) { return "body reactivation admission failed closed"; }
}
std::string poll_body_reactivation_probe(std::uint64_t owner, const Handle& handle, std::uint64_t sequence,
    body_reactivation_probe::Result& out) {
    LastError error; out = {};
    if (!owner || !sequence || GetCurrentThreadId() != service.thread) return "body reactivation poll is client phase only";
    if (!TryAcquireSRWLockShared(&service.lock)) return "body reactivation World is busy";
    struct Unlock { ~Unlock() { ReleaseSRWLockShared(&service.lock); } } unlock;
    const auto& p = reactivation_probe;
    if (p.owner != owner || p.handle != handle || p.sequence != sequence || reactivation_close_requested.load(std::memory_order_acquire))
        return "body reactivation observation unavailable for this owner and generation";
    out = p.result; return {};
}
void revoke_body_reactivation_probe(std::uint64_t owner) noexcept {
    LastError error;
    if (owner && reactivation_live_owner.load(std::memory_order_acquire) == owner)
        reactivation_close_requested.store(true, std::memory_order_release);
}
#endif
