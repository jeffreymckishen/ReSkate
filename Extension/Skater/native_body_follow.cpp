#include "native_body_follow.h"
#include "Engine/Core/Platform/memory.h"
#include <cmath>

namespace dingosdk::body_follow_native {
namespace {
struct LastError {
    DWORD value{GetLastError()};
    ~LastError() { SetLastError(value); }
};
bool joined(const actor_control_native::Actor& actor, const owned_bodies::MeasuredSource& source) noexcept {
    return actor.domain == actor_control::Domain::follow &&
        actor.continuity == actor_control_native::Continuity::native_lifetime &&
        actor.world && actor.world == source.native_world() &&
        actor.world_state && actor.world_state == source.native_state();
}
bool current_source(std::uint64_t owner, const owned_bodies::MeasuredSource& source,
    const actor_control_native::Actor* actor = nullptr, bool exact = false) noexcept {
    owned_bodies::SourceBorrow borrow;
    if (!owned_bodies::try_borrow_source(owner, source, borrow)) return false;
    const auto* current = exact ? borrow.current() : borrow.get();
    return current && (!actor || joined(*actor, *current));
}
bool published(const Binding& binding) noexcept {
    const auto value = actor_control_native::follow_snapshot(binding.owner, binding.sequence, binding.actor);
    return value.available && value.owner == binding.owner && value.ticket == binding.actor.ticket &&
        value.domain == actor_control::Domain::follow && value.phase == actor_control::Phase::published;
}
bool unit(const owned_body::Quaternion& value) noexcept {
    double norm{};
    for (const auto component : value) {
        if (!std::isfinite(component)) return false;
        norm += static_cast<double>(component) * component;
    }
    return std::abs(norm - 1.0) <= .0001;
}
owned_body::Quaternion product(const owned_body::Quaternion& left, const owned_body::Quaternion& right) noexcept {
    return {left[3]*right[0] + left[0]*right[3] + left[1]*right[2] - left[2]*right[1],
        left[3]*right[1] - left[0]*right[2] + left[1]*right[3] + left[2]*right[0],
        left[3]*right[2] + left[0]*right[1] - left[1]*right[0] + left[2]*right[3],
        left[3]*right[3] - left[0]*right[0] - left[1]*right[1] - left[2]*right[2]};
}
owned_body::Vec rotate(const owned_body::Quaternion& q, const owned_body::Vec& value) noexcept {
    const owned_body::Vec twice{2*(q[1]*value[2] - q[2]*value[1]),
        2*(q[2]*value[0] - q[0]*value[2]), 2*(q[0]*value[1] - q[1]*value[0])};
    return {value[0] + q[3]*twice[0] + q[1]*twice[2] - q[2]*twice[1],
        value[1] + q[3]*twice[1] + q[2]*twice[0] - q[0]*twice[2],
        value[2] + q[3]*twice[2] + q[0]*twice[1] - q[1]*twice[0]};
}
bool transform(const owned_body::Sample& sample, const Attachment& attachment,
    std::array<float, 16>& target) noexcept {
    if (!owned_body::finite(attachment.offset_from_com, 10) || !owned_body::finite(sample.position, 100000) ||
        !unit(sample.rotation) || !unit(attachment.root_in_body)) return false;
    const auto rotation = product(sample.rotation, attachment.root_in_body);
    if (!unit(rotation)) return false;
    // The point is COM-relative in BODY coordinates. Alignment affects the
    // root basis, not the COM-relative point. No authored-origin assumption.
    const auto offset = rotate(sample.rotation, attachment.offset_from_com);
    owned_body::Vec position{};
    for (unsigned axis = 0; axis < 3; ++axis) position[axis] = sample.position[axis] + offset[axis];
    if (!owned_body::finite(position, 100000)) return false;
    for (unsigned axis = 0; axis < 3; ++axis) {
        owned_body::Vec unit_axis{}; unit_axis[axis] = 1;
        const auto column = rotate(rotation, unit_axis);
        for (unsigned component = 0; component < 3; ++component) target[axis*4 + component] = column[component];
        target[12 + axis] = position[axis];
    }
    // The stock target's homogeneous/padding words 3,7,11,15 remain exact.
    return true;
}
}
bool reserve_binding(std::uint64_t owner, std::uint64_t sequence,
    const owned_bodies::MeasuredSource& source, actor_control_native::Admission admission,
    Binding& out, actor_control_native::Reason& reason) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    if (out.reserved || out.published || out.stopped || !owner || !sequence || !admission ||
        !current_source(owner, source)) return false;
    actor_control_native::Actor actor;
    if (!actor_control_native::reserve_follow(owner, sequence, admission, actor, reason)) return false;
    out.owner = owner; out.sequence = sequence; out.actor = actor; out.source = source; out.admission = admission; out.reserved = true;
    // Compare actual native identities, not the independent SDK generation counters.
    if (!joined(actor, source)) {
        reason = actor_control_native::Reason::world_changed;
        (void)stop(out); return false;
    }
    if (!current_source(owner, source, &actor)) {
        reason = actor_control_native::Reason::unavailable;
        (void)stop(out); return false;
    }
    return true;
}
bool publish_binding(Binding& out, actor_control_native::Reason& reason) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    if (!out.reserved || out.published || out.stopped || !out.admission) return false;
    if (!current_source(out.owner, out.source, &out.actor) ||
        !actor_control_native::publish_follow(out.owner, out.sequence, out.actor, out.admission, reason)) {
        if (reason == actor_control_native::Reason::none) reason = actor_control_native::Reason::unavailable;
        (void)stop(out); return false;
    }
    out.published = true; reason = actor_control_native::Reason::none;
    return true;
}
bool prepare_target(const Binding& binding, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, const Attachment& attachment,
    PreparedTarget& out, actor_control_native::Reason& reason) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    if (out.ready || out.call.active() || !binding.reserved || !binding.published || binding.stopped ||
        !supplied || binding.actor.rig != rig || binding.actor.context != context ||
        !binding.admission || !owned_body::finite(attachment.offset_from_com, 10) || !unit(attachment.root_in_body) || !published(binding)) return false;
    if (!actor_control_native::enter(binding.owner, binding.sequence, binding.actor, out.call)) return false;
    actor_control_native::Actor first; actor_control_native::State state;
    if (!actor_control_native::inspect(binding.owner, binding.sequence, binding.actor, first, state, reason)) return false;
    reason = actor_control_native::Reason::unavailable;
    if (first != binding.actor) return false;
    if (!binding.admission(state)) { reason = actor_control_native::Reason::unsupported_state; return false; }
    if (!memory::peek(reinterpret_cast<std::uintptr_t>(supplied), out.value)) return false;
    for (const auto value : out.value) if (!std::isfinite(value)) return false;
    if (!owned_bodies::try_measure_source(binding.owner, binding.source, out.source) ||
        !out.source.same_allocation(binding.source)) return false;
    {
        owned_bodies::SourceBorrow borrow;
        if (!owned_bodies::try_borrow_source(binding.owner, out.source, borrow)) return false;
        const auto* current = borrow.current();
        if (!current || !joined(first, *current) || !transform(current->sample(), attachment, out.value)) return false;
        out.sample = current->sample();
        if (!borrow.current()) return false;
    }
    // No body-service lock is held during actor recapture, and no body borrow
    // may cross the future original invocation. All facts remain sampled.
    actor_control_native::Actor after;
    if (!actor_control_native::inspect(binding.owner, binding.sequence, binding.actor, after, state, reason)) return false;
    reason = actor_control_native::Reason::unavailable;
    if (after != first) return false;
    if (!binding.admission(state)) { reason = actor_control_native::Reason::unsupported_state; return false; }
    if (!current_source(binding.owner, out.source, &after, true) || !published(binding)) return false;
    out.actor = binding.actor;
    out.owner = binding.owner; out.sequence = binding.sequence;
    out.ready = true; reason = actor_control_native::Reason::none;
    return true;
}
bool current_target(const Binding& binding, PreparedTarget& target,
    actor_control_native::Reason& reason) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    const bool candidate = target.ready && target.call.active();
    target.ready = false;
    if (!candidate || !binding.reserved || !binding.published || binding.stopped ||
        target.owner != binding.owner || target.sequence != binding.sequence || target.actor != binding.actor ||
        !target.source.same_allocation(binding.source) ||
        !body_query::same_sample(target.sample, target.source.sample()) || !binding.admission || !published(binding)) return false;
    actor_control_native::Actor actor; actor_control_native::State state;
    if (!actor_control_native::inspect(binding.owner, binding.sequence, binding.actor, actor, state, reason)) return false;
    reason = actor_control_native::Reason::unavailable;
    if (actor != binding.actor || !binding.admission(state) ||
        !current_source(binding.owner, target.source, &actor, true) || !published(binding)) return false;
    target.ready = true; reason = actor_control_native::Reason::none;
    return true;
}
bool stop(Binding& binding) noexcept {
    LastError error;
    if (!binding.reserved) return false;
    // Local output authority stops even if the bounded shared transition fails.
    binding.stopped = true;
    if (binding.published) {
        if (!actor_control_native::revoke_follow(binding.owner, binding.sequence, binding.actor)) return false;
        binding.stopped = true; return true;
    }
    if (!actor_control_native::abandon_follow(binding.owner, binding.sequence, binding.actor)) return false;
    binding.reserved = false; binding.stopped = true;
    return true;
}
namespace {
bool drained_follow(const Binding& binding) noexcept {
    const auto state = actor_control_native::follow_snapshot(binding.owner, binding.sequence, binding.actor);
    constexpr auto required = actor_control::Barrier::body_parked;
    return binding.reserved && binding.published && binding.stopped &&
        state.available && state.owner == binding.owner && state.ticket == binding.actor.ticket &&
        state.domain == actor_control::Domain::follow && state.phase == actor_control::Phase::revoking &&
        state.required == required && state.in_flight == 0;
}
bool cleanup_actor(const Binding& binding, actor_control_native::Reason& reason) noexcept {
    actor_control_native::Actor actor; actor_control_native::State state;
    return actor_control_native::inspect(binding.owner, binding.sequence, binding.actor, actor, state, reason, true) &&
        actor == binding.actor;
}
}
bool capture_park_fence(const Binding& binding, ParkFence& out, actor_control_native::Reason& reason) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    if (out.available() || !drained_follow(binding) || !cleanup_actor(binding, reason)) return false;
    ParkFence value;
    // Cleanup reads a new clock floor, never renews the original source sample
    // or its actuation lease. No actor lock crosses the world-service read.
    if (!owned_bodies::capture_retirement_basis(binding.owner, binding.source, value.basis_) ||
        value.basis_.native_world() != binding.actor.world || value.basis_.native_state() != binding.actor.world_state ||
        !cleanup_actor(binding, reason) || !drained_follow(binding)) {
        if (reason == actor_control_native::Reason::none) reason = actor_control_native::Reason::unavailable;
        return false;
    }
    value.owner_ = binding.owner; value.sequence_ = binding.sequence; value.actor_ = binding.actor;
    out = value; reason = actor_control_native::Reason::none; return true;
}
bool park_history_matches(const Binding& binding, const ParkFence& fence,
    const owned_bodies::RetainedParkReceipt& receipt) noexcept {
    LastError error;
    return fence.available() && fence.owner_ == binding.owner && fence.sequence_ == binding.sequence &&
        fence.actor_ == binding.actor && fence.actor_.world == fence.basis_.native_world() &&
        fence.actor_.world_state == fence.basis_.native_state() &&
        owned_bodies::matches_retained_park(binding.owner, fence.basis_, receipt);
}
bool observe_park(const Binding& binding, const ParkFence& fence, owned_bodies::RetainedParkReceipt& out,
    actor_control_native::Reason& reason) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    // A terminal receipt is history. Do not restamp it or repeat its retirement
    // proof every frame. Current gameplay authority is checked by its consumer.
    if (out.available()) {
        const bool matches = park_history_matches(binding, fence, out);
        if (matches) reason = actor_control_native::Reason::none;
        return matches;
    }
    if (!fence.available() || fence.owner_ != binding.owner || fence.sequence_ != binding.sequence ||
        fence.actor_ != binding.actor || !drained_follow(binding) || !cleanup_actor(binding, reason)) return false;
    owned_bodies::RetainedParkReceipt observed;
    if (!owned_bodies::observe_retained_park(binding.owner, fence.basis_, observed) ||
        !cleanup_actor(binding, reason) || !drained_follow(binding) || !park_history_matches(binding, fence, observed)) {
        if (reason == actor_control_native::Reason::none) reason = actor_control_native::Reason::unavailable;
        return false;
    }
    out = observed; reason = actor_control_native::Reason::none; return true;
}
bool completed_history_matches(const Binding& binding, const ParkFence& fence,
    const owned_bodies::RetainedParkReceipt& receipt) noexcept {
    LastError error;
    // Only complete_stop clears reserved on a published binding, after actual
    // World identity and same-object receipt validation plus claim retirement.
    // These objects remain immutable in the retaining Service until ACK.
    return binding.published && binding.stopped && !binding.reserved &&
        fence.available() && fence.owner_ == binding.owner && fence.sequence_ == binding.sequence &&
        fence.actor_ == binding.actor && fence.basis_.native_world() == binding.actor.world &&
        fence.basis_.native_state() == binding.actor.world_state && receipt.available() &&
        receipt.observed_epoch().world == fence.basis_.epoch().world &&
        receipt.observed_epoch().body == fence.basis_.epoch().body &&
        receipt.observed_epoch().serial > fence.basis_.epoch().serial &&
        receipt.observed_epoch().time > fence.basis_.epoch().time &&
        receipt.parked_ms() >= fence.basis_.captured_ms() &&
        receipt.observed_ms() > receipt.parked_ms() && receipt.observed_ms() > fence.basis_.captured_ms();
}
bool complete_stop(Binding& binding, const ParkFence& fence,
    const owned_bodies::RetainedParkReceipt& receipt) noexcept {
    LastError error;
    actor_control_native::Reason reason;
    if (!drained_follow(binding) || !park_history_matches(binding, fence, receipt) ||
        !cleanup_actor(binding, reason) || !drained_follow(binding) ||
        !actor_control_native::retire_follow(binding.owner, binding.sequence, binding.actor, fence.basis_, receipt)) return false;
    // Only the actual matched Arbiter retirement can clear a published binding.
    // Published/stopped and the retained final history remain available to ACK.
    binding.reserved = false;
    return true;
}
} // namespace dingosdk::body_follow_native
