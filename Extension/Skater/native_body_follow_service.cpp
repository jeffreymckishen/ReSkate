#include "native_body_follow_service.h"
#include "native_actions.h"
#include <atomic>
#include <cmath>
#include <limits>
#include <Windows.h>

namespace dingosdk::body_follow_service {
namespace {
constexpr std::uint64_t lease_ms = 3000;
constexpr unsigned stopped_bit = 1, invoking_bit = 2;
struct LastError {
    DWORD value{GetLastError()};
    ~LastError() { SetLastError(value); }
};
struct Forwarded {
    std::uint64_t revision{};
    owned_bodies::MeasuredSource source;
    std::array<float, 16> value{};
    std::uint8_t flags{};
};
struct Service {
    SRWLOCK lock = SRWLOCK_INIT;
    // Dispatch commits and stop sets stopped_bit under this same lock. A
    // preparation already holding the lock may commit before stop acquires it;
    // its exact revision is then retained as cleanup duty. No lock spans original.
    std::atomic<unsigned> edge{stopped_bit};
    // Identity remains fixed while occupied. Stop revalidates it under the
    // lock before changing edge, so a stale stop cannot affect a reused slot.
    std::atomic<std::uint64_t> owner{}, sequence{};
    body_follow_native::Binding binding;
    body_follow_native::Attachment attachment;
    body_follow_native::ParkFence park_fence;
    owned_bodies::RetainedParkReceipt park_receipt;
    owned_bodies::BodyReleaseHold release_hold;
    owned_body::Handle body;
    Forwarded final;
    std::atomic<std::uint64_t> returned_revision{};
    std::uint64_t next_sequence{}, started{}, deadline{};
    actor_control_native::Reason reason{actor_control_native::Reason::unavailable};
    actor_control_native::Reason park_reason{actor_control_native::Reason::unavailable};
    bool occupied{}, orphaned{}, body_release_requested{}, body_release_started{}, stop_cause_recorded{};
};
// Initialized with the runtime, before any existing native hook is enabled.
// The native dispatch path must not allocate on its first invocation.
Service process_service;
Service& service() noexcept { return process_service; }
struct Unlock {
    SRWLOCK& lock;
    ~Unlock() { ReleaseSRWLockExclusive(&lock); }
};
bool matches(const Service& s, std::uint64_t owner, Handle handle) noexcept {
    return s.occupied && owner && owner == s.binding.owner && handle.sequence &&
        handle.sequence == s.binding.sequence;
}
void stop_locked(Service& s, actor_control_native::Reason reason) noexcept {
    s.edge.fetch_or(stopped_bit, std::memory_order_acq_rel);
    if (!s.stop_cause_recorded) { s.reason = reason; s.stop_cause_recorded = true; }
    if (s.binding.published || s.orphaned) s.body_release_requested = true;
    if (s.release_hold.available() && s.body_release_requested)
        (void)owned_bodies::request_held_release(s.binding.owner, s.release_hold);
    (void)body_follow_native::stop(s.binding);
}
bool completed(const Service& s) noexcept {
    // A published binding clears reserved only after actual exact retirement.
    return s.binding.published && s.binding.stopped && !s.binding.reserved && s.park_receipt.available();
}
bool abandoned_ack_ready(const Service& s) noexcept {
    return s.binding.stopped && !s.binding.published && !s.binding.reserved &&
        s.edge.load(std::memory_order_acquire) == stopped_bit && !s.release_hold.available() &&
        !s.orphaned && !s.body_release_requested && !s.body_release_started &&
        !s.park_fence.available() && !s.park_receipt.available() && !s.final.revision &&
        !s.returned_revision.load(std::memory_order_acquire);
}
bool completed_ack_ready(const Service& s) noexcept {
    return completed(s) && s.edge.load(std::memory_order_acquire) == stopped_bit &&
        !s.release_hold.available() && s.body_release_requested && s.body_release_started &&
        s.park_fence.available() && s.final.revision == s.returned_revision.load(std::memory_order_acquire) &&
        body_follow_native::completed_history_matches(s.binding, s.park_fence, s.park_receipt);
}
bool abandoned_release_handed_off(const Service& s) noexcept {
    // Host-only after release_all: no target/body pointer was ever forwarded.
    // A known accepted exact World release cancelled its mailbox and retained
    // the allocation there. Unknown/quarantined release never sets started.
    return s.orphaned && s.binding.stopped && !s.binding.published && !s.binding.reserved &&
        s.edge.load(std::memory_order_acquire) == stopped_bit && !s.release_hold.available() &&
        s.body_release_requested && s.body_release_started && !s.park_fence.available() &&
        !s.park_receipt.available() && !s.final.revision &&
        !s.returned_revision.load(std::memory_order_acquire);
}
void acknowledge_locked(Service& s) noexcept {
    // Both ACK callers have already proved a terminal SDK receipt. This resets
    // only that receipt; native pose state, World slots and generations remain.
    s.owner.store(0, std::memory_order_release);
    s.sequence.store(0, std::memory_order_release);
    s.binding = {}; s.attachment = {}; s.park_fence = {}; s.park_receipt = {};
    s.release_hold = {}; s.body = {}; s.final = {};
    s.returned_revision.store(0, std::memory_order_release);
    s.started = s.deadline = 0;
    s.reason = s.park_reason = actor_control_native::Reason::unavailable;
    s.orphaned = s.body_release_requested = s.body_release_started = s.stop_cause_recorded = false;
    // edge remains stopped_bit. next_sequence and the actual Arbiter are never
    // reset, so stale handles cannot become valid after receipt or owner reuse.
    s.occupied = false;
}
void acknowledge_orphan_locked(Service& s) noexcept {
    const auto owner = s.owner.load(std::memory_order_acquire);
    const Handle handle{s.sequence.load(std::memory_order_acquire)};
    if (!s.orphaned || !matches(s, owner, handle)) return;
    if (completed_ack_ready(s) || abandoned_release_handed_off(s)) acknowledge_locked(s);
}
bool quiet() noexcept {
    // Each participating publisher takes an IdleCall from the actual Arbiter.
    // Reserve has already excluded those publishers; these queries distinguish
    // old tuning/restoration duty from a merely empty dispatch count.
    return skater_action::follow_duties_idle();
}
bool valid_attachment(const body_follow_native::Attachment& value) noexcept {
    if (!owned_body::finite(value.offset_from_com, 10)) return false;
    double norm{};
    for (const auto lane : value.root_in_body) {
        if (!std::isfinite(lane)) return false;
        norm += static_cast<double>(lane) * lane;
    }
    return std::abs(norm - 1.0) <= .0001;
}
}

bool reserve(std::uint64_t owner, const owned_body::Handle& body,
    const owned_bodies::MeasuredSource& expected, const body_follow_native::Attachment& attachment,
    actor_control_native::Admission admission, Handle& out, actor_control_native::Reason& reason) noexcept {
    LastError error; out = {}; reason = actor_control_native::Reason::unavailable;
    auto& s = service();
    if (!owner || !admission || !valid_attachment(attachment) || !TryAcquireSRWLockExclusive(&s.lock)) return false;
    Unlock unlock{s.lock};
    if (s.occupied || s.next_sequence == std::numeric_limits<std::uint64_t>::max()) {
        reason = actor_control_native::Reason::receipt_capacity; return false;
    }
    owned_bodies::MeasuredSource actual;
    if (!owned_bodies::capture_source(owner, body, actual) || !actual.same_allocation(expected) ||
        !body_query::same_sample(actual.sample(), expected.sample())) return false;
    s.occupied = true; s.body = body; s.attachment = attachment;
    const auto sequence = ++s.next_sequence;
    if (!body_follow_native::reserve_binding(owner, sequence, actual, admission, s.binding, reason)) {
        if (!s.binding.reserved) { s.occupied = false; s.binding = {}; return false; }
        s.owner.store(owner, std::memory_order_release);
        s.sequence.store(sequence, std::memory_order_release);
        out.sequence = sequence; stop_locked(s, reason); return false;
    }
    out.sequence = sequence;
    s.edge.store(0, std::memory_order_release);
    s.owner.store(owner, std::memory_order_release);
    s.sequence.store(sequence, std::memory_order_release);
    if (!quiet() || !owned_bodies::acquire_release_hold(owner, actual, s.release_hold)) {
        reason = actor_control_native::Reason::motion_owned;
        stop_locked(s, reason); return false;
    }
    s.started = GetTickCount64();
    if (s.started > std::numeric_limits<std::uint64_t>::max() - lease_ms) {
        reason = actor_control_native::Reason::expired;
        stop_locked(s, reason); return false;
    }
    s.deadline = s.started + lease_ms;
    s.reason = reason = actor_control_native::Reason::none;
    return true;
}

bool publish(std::uint64_t owner, Handle handle, actor_control_native::Reason& reason) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return false;
    Unlock unlock{s.lock};
    if (!matches(s, owner, handle) || s.binding.stopped || s.edge.load(std::memory_order_acquire) || !s.release_hold.available() ||
        GetTickCount64() < s.started || GetTickCount64() >= s.deadline || !quiet()) return false;
    bool release_requested{};
    if (!owned_bodies::release_requested(owner, s.release_hold, release_requested) || release_requested ||
        !body_follow_native::publish_binding(s.binding, reason)) {
        stop_locked(s, reason); return false;
    }
    const auto published_ms = GetTickCount64();
    if (s.edge.load(std::memory_order_acquire) || published_ms < s.started || published_ms >= s.deadline) {
        reason = s.edge.load(std::memory_order_acquire) ? actor_control_native::Reason::cancelled :
            actor_control_native::Reason::expired;
        stop_locked(s, reason); return false;
    }
    s.reason = reason = actor_control_native::Reason::none;
    return true;
}

bool read(std::uint64_t owner, Handle handle, Receipt& out) noexcept {
    LastError error; out = {};
    auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return false;
    Unlock unlock{s.lock};
    if (!matches(s, owner, handle)) return false;
    const auto claim = actor_control_native::follow_snapshot(owner, handle.sequence, s.binding.actor);
    const bool abandoned = abandoned_ack_ready(s);
    const bool sdk_completed = completed(s);
    out.phase = sdk_completed ? Phase::completed : abandoned ? Phase::abandoned : s.binding.stopped ? (s.park_receipt.available() ? Phase::retained : Phase::stopping) :
        (s.binding.published ? Phase::following : Phase::reserved);
    out.reason = s.reason; out.park_reason = s.park_reason; out.final_revision = s.final.revision;
    out.final_native_epoch = s.final.source.sample().epoch.serial;
    out.returned_revision = s.returned_revision.load(std::memory_order_acquire);
    out.pending = (abandoned || sdk_completed) ? actor_control::Barrier::none : claim.available ? claim.pending :
        actor_control::Barrier::body_parked;
    out.in_flight = claim.available ? claim.in_flight : 0;
    out.claim_known = claim.available;
    out.orphaned = s.orphaned; out.park_observed = s.park_receipt.available();
    // SDK ownership completion is separate from native pose-history retirement.
    // Neither actual park nor an ACK claims all native consumers forgot a pose.
    out.native_retirement_known = false;
    return true;
}

bool stop(std::uint64_t owner, Handle handle) noexcept {
    LastError error; auto& s = service();
    // Avoid invalid/foreign handles stopping someone else's slot.
    if (!owner || !handle.sequence || s.owner.load(std::memory_order_acquire) != owner ||
        s.sequence.load(std::memory_order_acquire) != handle.sequence) return false;
    AcquireSRWLockExclusive(&s.lock);
    Unlock unlock{s.lock};
    if (!matches(s, owner, handle)) return false;
    stop_locked(s, actor_control_native::Reason::cancelled);
    return true;
}
bool acknowledge_abandoned(std::uint64_t owner, Handle handle) noexcept {
    LastError error; auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return false;
    Unlock unlock{s.lock};
    // Only stop(Binding) can clear reserved on an occupied receipt, after the
    // actual exact-owner/ticket Arbiter abandonment succeeds. An unavailable
    // follow_snapshot is not evidence of abandonment or native retirement.
    if (!matches(s, owner, handle) || !abandoned_ack_ready(s)) return false;
    acknowledge_locked(s);
    return true;
}
bool acknowledge_completed(std::uint64_t owner, Handle handle) noexcept {
    LastError error; auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return false;
    Unlock unlock{s.lock};
    if (!matches(s, owner, handle) || !completed_ack_ready(s)) return false;
    // Request/orphan/final/park fields are fulfilled terminal history here.
    // Foreign callers still cannot consume the exact owner's receipt.
    acknowledge_locked(s);
    return true;
}
void release_all(std::uint64_t owner) noexcept {
    LastError error; auto& s = service();
    if (!owner || s.owner.load(std::memory_order_acquire) != owner) return;
    AcquireSRWLockExclusive(&s.lock);
    Unlock unlock{s.lock};
    if (!s.occupied || !owner || s.binding.owner != owner) return;
    // Owner-wide VM cleanup applies to the current receipt for this owner;
    // unlike stop, it intentionally does not select one historical sequence.
    s.orphaned = true;
    stop_locked(s, actor_control_native::Reason::owner_released);
}

void tick(bool ready) noexcept {
    LastError error; auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return;
    Unlock unlock{s.lock};
    if (!s.occupied) return;
    if (completed(s)) {
        // release_all authenticated this old owner before the VM disappeared.
        // The host consumes only its same proven terminal receipt, never an
        // unknown duty or a handle transferred to a replacement VM.
        acknowledge_orphan_locked(s);
        return;
    }
    bool release_requested{}, release_known{true};
    if (s.release_hold.available()) {
        release_known = owned_bodies::release_requested(s.binding.owner, s.release_hold, release_requested);
        if (release_known && release_requested) s.body_release_requested = true;
        if (!release_known || release_requested)
            stop_locked(s, actor_control_native::Reason::owner_released);
    }
    if (!ready || GetTickCount64() < s.started || GetTickCount64() >= s.deadline)
        stop_locked(s, ready ? actor_control_native::Reason::expired : actor_control_native::Reason::unavailable);
    if (!s.binding.stopped) return;
    // Retry bounded revoke/abandon. Never drop a partially acquired claim.
    (void)body_follow_native::stop(s.binding);
    if (!s.binding.published) {
        if (s.binding.reserved) return;
        if (s.release_hold.available()) {
            // An unknown release query is not clean abandonment. Retain the
            // actual hold until a later exact query can resolve the request.
            if (!release_known || !owned_bodies::release_body_hold(s.binding.owner, s.release_hold)) return;
        }
        if (s.body_release_requested && !s.body_release_started) {
            const auto issue = owned_bodies::release(s.binding.owner, s.body);
            if (issue.empty()) s.body_release_started = true;
        }
        // A live caller keeps its body and explicitly ACKs clean abandonment.
        // For an orphan with known accepted release, World owns its retained
        // allocation cleanup independently; no FOLLOW callback remains.
        acknowledge_orphan_locked(s);
        return;
    }
    // An unknown exact hold/request query must not be hidden by later park.
    // Retain the token until a subsequent real query resolves that state.
    if (!release_known) return;
    if (!s.park_fence.available() &&
        !body_follow_native::capture_park_fence(s.binding, s.park_fence, s.park_reason)) return;
    if (!s.body_release_started) {
        if (s.release_hold.available() &&
            !owned_bodies::release_body_hold(s.binding.owner, s.release_hold)) return;
        const auto issue = owned_bodies::release(s.binding.owner, s.body);
        if (!issue.empty()) return;
        s.body_release_started = true;
    }
    if (!body_follow_native::observe_park(s.binding, s.park_fence, s.park_receipt, s.park_reason)) return;
    // Only a normal completed original, actual stop/drain and matching park
    // can close this SDK claim. Unknown native pose history remains unknown.
    if (s.edge.load(std::memory_order_acquire) != stopped_bit || s.release_hold.available() ||
        !s.body_release_requested || !s.body_release_started ||
        s.final.revision != s.returned_revision.load(std::memory_order_acquire)) return;
    if (body_follow_native::complete_stop(s.binding, s.park_fence, s.park_receipt))
        acknowledge_orphan_locked(s);
}

bool dispatch(Original original, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, std::uint8_t flags) {
    LastError error;
    body_follow_native::PreparedTarget target;
    auto& s = service();
    std::uint64_t revision{};
    {
        if (!original || !TryAcquireSRWLockExclusive(&s.lock)) return false;
        Unlock unlock{s.lock};
        if (!s.occupied || !s.binding.published || s.binding.stopped ||
            s.binding.actor.rig != rig || s.binding.actor.context != context) return false;
        // An original still invoking is ordinary concurrent work, not evidence
        // of failure. Do not mistake its not-yet-returned revision for debt.
        if (s.edge.load(std::memory_order_acquire) & invoking_bit) return false;
        // A committed original without a normal return stays unresolved. A
        // later successful invocation must not overwrite that failure history.
        if (s.final.revision != s.returned_revision.load(std::memory_order_acquire)) {
            stop_locked(s, actor_control_native::Reason::unavailable); return false;
        }
        if (GetTickCount64() < s.started || GetTickCount64() >= s.deadline || s.final.revision == std::numeric_limits<std::uint64_t>::max()) {
            stop_locked(s, actor_control_native::Reason::expired); return false;
        }
        if (!body_follow_native::prepare_target(s.binding, rig, context, supplied, s.attachment, target, s.reason) ||
            !body_follow_native::current_target(s.binding, target, s.reason)) {
            stop_locked(s, s.reason); return false;
        }
        const auto forwarding_ms = GetTickCount64();
        if (forwarding_ms < s.started || forwarding_ms >= s.deadline) {
            stop_locked(s, actor_control_native::Reason::expired); return false;
        }
        unsigned idle{};
        if (!s.edge.compare_exchange_strong(idle, invoking_bit, std::memory_order_acq_rel)) return false;
        revision = s.final.revision + 1;
        s.final = {revision, target.source, target.value, flags};
    }
    struct LeaveEdge {
        std::atomic<unsigned>& edge;
        ~LeaveEdge() { edge.fetch_and(~invoking_bit, std::memory_order_acq_rel); }
    } leave{s.edge};
    // Committed edge above is the linearization point. Stop cannot cancel an
    // already committed invocation: it retains this exact final revision and
    // waits for the native Call to drain. Neither lock nor body borrow spans it.
    SetLastError(error.value);
    original(rig, context, &target.value, flags);
    error.value = GetLastError();
    s.returned_revision.store(revision, std::memory_order_release);
    return true;
}
} // namespace dingosdk::body_follow_service
