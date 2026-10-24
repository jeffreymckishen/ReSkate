#include "native_body_follow.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Skater/body_follow_transform.h"
#include <cmath>

namespace dingosdk::body_follow_native {
const char* diagnostic_stage_name(DiagnosticStage stage) noexcept {
    switch (stage) {
    case DiagnosticStage::not_attempted: return "not_attempted";
    case DiagnosticStage::prepare_guard: return "prepare_guard";
    case DiagnosticStage::enter: return "enter";
    case DiagnosticStage::inspect_first: return "inspect_first";
    case DiagnosticStage::first_identity: return "first_identity";
    case DiagnosticStage::first_admission: return "first_admission";
    case DiagnosticStage::supplied_copy: return "supplied_copy";
    case DiagnosticStage::supplied_finite: return "supplied_finite";
    case DiagnosticStage::measure: return "measure";
    case DiagnosticStage::measured_allocation: return "measured_allocation";
    case DiagnosticStage::borrow: return "borrow";
    case DiagnosticStage::borrow_current: return "borrow_current";
    case DiagnosticStage::borrow_join: return "borrow_join";
    case DiagnosticStage::transform: return "transform";
    case DiagnosticStage::borrow_recheck: return "borrow_recheck";
    case DiagnosticStage::inspect_closing: return "inspect_closing";
    case DiagnosticStage::closing_identity: return "closing_identity";
    case DiagnosticStage::closing_admission: return "closing_admission";
    case DiagnosticStage::final_source: return "final_source";
    case DiagnosticStage::final_published: return "final_published";
    case DiagnosticStage::current_guard: return "current_guard";
    case DiagnosticStage::inspect_current: return "inspect_current";
    case DiagnosticStage::current_identity: return "current_identity";
    case DiagnosticStage::current_admission: return "current_admission";
    case DiagnosticStage::current_source: return "current_source";
    case DiagnosticStage::current_published: return "current_published";
    case DiagnosticStage::fence_guard: return "fence_guard";
    case DiagnosticStage::fence_actor: return "fence_actor";
    case DiagnosticStage::fence_basis: return "fence_basis";
    case DiagnosticStage::fence_world: return "fence_world";
    case DiagnosticStage::fence_state: return "fence_state";
    case DiagnosticStage::fence_closing_actor: return "fence_closing_actor";
    case DiagnosticStage::fence_drained: return "fence_drained";
    case DiagnosticStage::park_history: return "park_history";
    case DiagnosticStage::park_guard: return "park_guard";
    case DiagnosticStage::park_actor: return "park_actor";
    case DiagnosticStage::park_observe: return "park_observe";
    case DiagnosticStage::park_closing_actor: return "park_closing_actor";
    case DiagnosticStage::park_drained: return "park_drained";
    case DiagnosticStage::park_match: return "park_match";
    case DiagnosticStage::complete_drained: return "complete_drained";
    case DiagnosticStage::complete_history: return "complete_history";
    case DiagnosticStage::complete_actor: return "complete_actor";
    case DiagnosticStage::complete_closing_drained: return "complete_closing_drained";
    case DiagnosticStage::complete_retire: return "complete_retire";
    }
    return "unknown";
}
namespace {
struct LastError {
    DWORD value{GetLastError()};
    ~LastError() { SetLastError(value); }
};
void at(Diagnostic& diagnostic, DiagnosticStage stage) noexcept { diagnostic.stage = stage; }
bool inspect_at(const Binding& binding, actor_control_native::Actor& actor,
    actor_control_native::State& state, actor_control_native::Reason& reason,
    Diagnostic& diagnostic, DiagnosticStage stage, bool cleanup = false) noexcept {
    diagnostic.stage = diagnostic.actor_stage = stage;
    diagnostic.actor = {}; diagnostic.facts = {};
    const bool result = actor_control_native::inspect(binding.owner, binding.sequence, binding.actor,
        actor, state, reason, diagnostic.actor, diagnostic.facts, cleanup);
    return result;
}
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
    Diagnostic diagnostic;
    return prepare_target(binding, rig, context, supplied, attachment, out, reason, diagnostic);
}
bool prepare_target(const Binding& binding, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, const Attachment& attachment,
    PreparedTarget& out, actor_control_native::Reason& reason, Diagnostic& diagnostic) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    diagnostic = {}; at(diagnostic, DiagnosticStage::prepare_guard);
    if (out.ready || out.call.active() || !binding.reserved || !binding.published || binding.stopped ||
        !supplied || binding.actor.rig != rig || binding.actor.context != context ||
        !binding.admission || !owned_body::finite(attachment.offset_from_com, 10) || !body_follow_transform::unit(attachment.root_in_body) || !published(binding)) return false;
    diagnostic.stage = diagnostic.actor_stage = DiagnosticStage::enter;
    if (!actor_control_native::enter(binding.owner, binding.sequence, binding.actor, out.call, diagnostic.actor)) return false;
    actor_control_native::Actor first; actor_control_native::State state;
    if (!inspect_at(binding, first, state, reason, diagnostic, DiagnosticStage::inspect_first)) return false;
    reason = actor_control_native::Reason::unavailable;
    at(diagnostic, DiagnosticStage::first_identity);
    if (first != binding.actor) return false;
    at(diagnostic, DiagnosticStage::first_admission);
    if (!binding.admission(state)) { reason = actor_control_native::Reason::unsupported_state; return false; }
    at(diagnostic, DiagnosticStage::supplied_copy);
    if (!memory::peek(reinterpret_cast<std::uintptr_t>(supplied), out.value)) return false;
    at(diagnostic, DiagnosticStage::supplied_finite);
    // Validate XYZ only; keep all supplied SIMD fourth words without rewriting them.
    const auto failed_lane = body_follow_transform::first_nonfinite_xyz(out.value);
    if (failed_lane != body_follow_transform::no_failed_lane) {
        diagnostic.supplied_failed_lane = failed_lane;
        return false;
    }
    at(diagnostic, DiagnosticStage::measure);
    if (!owned_bodies::try_measure_source(binding.owner, binding.source, out.source) ||
        (at(diagnostic, DiagnosticStage::measured_allocation), !out.source.same_allocation(binding.source))) return false;
    {
        owned_bodies::SourceBorrow borrow;
        at(diagnostic, DiagnosticStage::borrow);
        if (!owned_bodies::try_borrow_source(binding.owner, out.source, borrow)) return false;
        at(diagnostic, DiagnosticStage::borrow_current);
        const auto* current = borrow.current();
        if (!current || (at(diagnostic, DiagnosticStage::borrow_join), !joined(first, *current)) ||
            (at(diagnostic, DiagnosticStage::transform), !body_follow_transform::transform(current->sample(), attachment.offset_from_com, attachment.root_in_body, out.value))) return false;
        out.sample = current->sample();
        at(diagnostic, DiagnosticStage::borrow_recheck);
        if (!borrow.current()) return false;
    }
    // No body-service lock is held during actor recapture, and no body borrow
    // may cross the future original invocation. All facts remain sampled.
    actor_control_native::Actor after;
    if (!inspect_at(binding, after, state, reason, diagnostic, DiagnosticStage::inspect_closing)) return false;
    reason = actor_control_native::Reason::unavailable;
    at(diagnostic, DiagnosticStage::closing_identity);
    if (after != first) return false;
    at(diagnostic, DiagnosticStage::closing_admission);
    if (!binding.admission(state)) { reason = actor_control_native::Reason::unsupported_state; return false; }
    at(diagnostic, DiagnosticStage::final_source);
    if (!current_source(binding.owner, out.source, &after, true) ||
        (at(diagnostic, DiagnosticStage::final_published), !published(binding))) return false;
    out.actor = binding.actor;
    out.owner = binding.owner; out.sequence = binding.sequence;
    out.ready = true; reason = actor_control_native::Reason::none;
    return true;
}
bool current_target(const Binding& binding, PreparedTarget& target,
    actor_control_native::Reason& reason) noexcept {
    Diagnostic diagnostic;
    return current_target(binding, target, reason, diagnostic);
}
bool current_target(const Binding& binding, PreparedTarget& target,
    actor_control_native::Reason& reason, Diagnostic& diagnostic) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    diagnostic = {}; at(diagnostic, DiagnosticStage::current_guard);
    const bool candidate = target.ready && target.call.active();
    target.ready = false;
    if (!candidate || !binding.reserved || !binding.published || binding.stopped ||
        target.owner != binding.owner || target.sequence != binding.sequence || target.actor != binding.actor ||
        !target.source.same_allocation(binding.source) ||
        !body_query::same_sample(target.sample, target.source.sample()) || !binding.admission || !published(binding)) return false;
    actor_control_native::Actor actor; actor_control_native::State state;
    if (!inspect_at(binding, actor, state, reason, diagnostic, DiagnosticStage::inspect_current)) return false;
    reason = actor_control_native::Reason::unavailable;
    at(diagnostic, DiagnosticStage::current_identity);
    if (actor != binding.actor || (at(diagnostic, DiagnosticStage::current_admission), !binding.admission(state)) ||
        (at(diagnostic, DiagnosticStage::current_source), !current_source(binding.owner, target.source, &actor, true)) ||
        (at(diagnostic, DiagnosticStage::current_published), !published(binding))) return false;
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
bool cleanup_actor(const Binding& binding, actor_control_native::Reason& reason,
    Diagnostic& diagnostic, DiagnosticStage stage) noexcept {
    actor_control_native::Actor actor; actor_control_native::State state;
    return inspect_at(binding, actor, state, reason, diagnostic, stage, true) &&
        actor == binding.actor;
}
}
bool capture_park_fence(const Binding& binding, ParkFence& out, actor_control_native::Reason& reason) noexcept {
    Diagnostic diagnostic;
    return capture_park_fence(binding, out, reason, diagnostic);
}
bool capture_park_fence(const Binding& binding, ParkFence& out, actor_control_native::Reason& reason,
    Diagnostic& diagnostic) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    diagnostic = {}; at(diagnostic, DiagnosticStage::fence_guard);
    if (out.available() || !drained_follow(binding) ||
        !cleanup_actor(binding, reason, diagnostic, DiagnosticStage::fence_actor)) return false;
    ParkFence value;
    // Cleanup reads a new clock floor, never renews the original source sample
    // or its actuation lease. No actor lock crosses the world-service read.
    at(diagnostic, DiagnosticStage::fence_basis);
    if (!owned_bodies::capture_retirement_basis(binding.owner, binding.source, value.basis_) ||
        (at(diagnostic, DiagnosticStage::fence_world), value.basis_.native_world() != binding.actor.world) ||
        (at(diagnostic, DiagnosticStage::fence_state), value.basis_.native_state() != binding.actor.world_state) ||
        !cleanup_actor(binding, reason, diagnostic, DiagnosticStage::fence_closing_actor) ||
        (at(diagnostic, DiagnosticStage::fence_drained), !drained_follow(binding))) {
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
    Diagnostic diagnostic;
    return observe_park(binding, fence, out, reason, diagnostic);
}
bool observe_park(const Binding& binding, const ParkFence& fence, owned_bodies::RetainedParkReceipt& out,
    actor_control_native::Reason& reason, Diagnostic& diagnostic) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    diagnostic = {}; at(diagnostic, DiagnosticStage::park_history);
    // A terminal receipt is history. Do not restamp it or repeat its retirement
    // proof every frame. Current gameplay authority is checked by its consumer.
    if (out.available()) {
        const bool matches = park_history_matches(binding, fence, out);
        if (matches) reason = actor_control_native::Reason::none;
        return matches;
    }
    at(diagnostic, DiagnosticStage::park_guard);
    if (!fence.available() || fence.owner_ != binding.owner || fence.sequence_ != binding.sequence ||
        fence.actor_ != binding.actor || !drained_follow(binding) ||
        !cleanup_actor(binding, reason, diagnostic, DiagnosticStage::park_actor)) return false;
    owned_bodies::RetainedParkReceipt observed;
    at(diagnostic, DiagnosticStage::park_observe);
    if (!owned_bodies::observe_retained_park(binding.owner, fence.basis_, observed) ||
        !cleanup_actor(binding, reason, diagnostic, DiagnosticStage::park_closing_actor) ||
        (at(diagnostic, DiagnosticStage::park_drained), !drained_follow(binding)) ||
        (at(diagnostic, DiagnosticStage::park_match), !park_history_matches(binding, fence, observed))) {
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
    Diagnostic diagnostic;
    return complete_stop(binding, fence, receipt, diagnostic);
}
bool complete_stop(Binding& binding, const ParkFence& fence,
    const owned_bodies::RetainedParkReceipt& receipt, Diagnostic& diagnostic) noexcept {
    LastError error;
    actor_control_native::Reason reason;
    diagnostic = {}; at(diagnostic, DiagnosticStage::complete_drained);
    if (!drained_follow(binding) ||
        (at(diagnostic, DiagnosticStage::complete_history), !park_history_matches(binding, fence, receipt)) ||
        !cleanup_actor(binding, reason, diagnostic, DiagnosticStage::complete_actor) ||
        (at(diagnostic, DiagnosticStage::complete_closing_drained), !drained_follow(binding)) ||
        (at(diagnostic, DiagnosticStage::complete_retire),
            !actor_control_native::retire_follow(binding.owner, binding.sequence, binding.actor, fence.basis_, receipt))) return false;
    // Only the actual matched Arbiter retirement can clear a published binding.
    // Published/stopped and the retained final history remain available to ACK.
    binding.reserved = false;
    return true;
}
} // namespace dingosdk::body_follow_native
