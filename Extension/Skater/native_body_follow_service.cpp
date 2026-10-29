#include "native_body_follow_service.h"
#include "native_actions.h"
#include <atomic>
#include <cmath>
#include <limits>
#include <Windows.h>

namespace dingosdk::body_follow_native {
std::atomic<std::uint64_t> NativeMotionEntry::next_serial_{};
thread_local NativeMotionEntry* NativeMotionEntry::active_{};
NativeMotionEntry::NativeMotionEntry(Original original, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, std::uint8_t flags) noexcept
    : previous_(active_), original_(original), rig_(rig), context_(context), supplied_(supplied), flags_(flags) {
    const auto error = GetLastError();
    thread_ = GetCurrentThreadId();
    auto next = next_serial_.load(std::memory_order_relaxed);
    // Contention may refuse authoring, never spin in an engine callback.
    for (unsigned attempt = 0; attempt < 4 && next != std::numeric_limits<std::uint64_t>::max(); ++attempt) {
        if (next_serial_.compare_exchange_weak(next, next + 1, std::memory_order_relaxed)) {
            serial_ = next + 1;
            break;
        }
    }
    active_ = this;
    SetLastError(error);
}
NativeMotionEntry::~NativeMotionEntry() {
    if (active_ == this) active_ = previous_;
}
bool NativeMotionEntry::current() const noexcept {
    const auto error = GetLastError();
    const auto thread = GetCurrentThreadId();
    SetLastError(error);
    return active_ == this && !previous_ && !used_ && serial_ && original_ && supplied_ && thread_ == thread;
}
} // namespace dingosdk::body_follow_native

namespace dingosdk::body_follow_service {
const char* stop_origin_name(StopOrigin origin) noexcept {
    switch (origin) {
    case StopOrigin::reserve_binding: return "reserve_binding";
    case StopOrigin::reserve_hold: return "reserve_hold";
    case StopOrigin::reserve_clock: return "reserve_clock";
    case StopOrigin::publish_binding: return "publish_binding";
    case StopOrigin::publish_closing: return "publish_closing";
    case StopOrigin::explicit_stop: return "explicit_stop";
    case StopOrigin::owner_release: return "owner_release";
    case StopOrigin::release_query: return "release_query";
    case StopOrigin::runtime_not_ready: return "runtime_not_ready";
    case StopOrigin::tick_expired: return "tick_expired";
    case StopOrigin::dispatch_unreturned: return "dispatch_unreturned";
    case StopOrigin::dispatch_expired: return "dispatch_expired";
    case StopOrigin::dispatch_prepare: return "dispatch_prepare";
    case StopOrigin::dispatch_current: return "dispatch_current";
    case StopOrigin::dispatch_forwarding_expired: return "dispatch_forwarding_expired";
    case StopOrigin::lease_guard: return "lease_guard";
    case StopOrigin::renew_expired: return "renew_expired";
    case StopOrigin::dispatch_guard: return "dispatch_guard";
    case StopOrigin::dispatch_revision_exhausted: return "dispatch_revision_exhausted";
    }
    return "unknown";
}
const char* cleanup_origin_name(CleanupOrigin origin) noexcept {
    switch (origin) {
    case CleanupOrigin::capture_fence: return "capture_fence";
    case CleanupOrigin::observe_park: return "observe_park";
    case CleanupOrigin::complete_stop: return "complete_stop";
    case CleanupOrigin::release_query: return "release_query";
    case CleanupOrigin::release_hold: return "release_hold";
    case CleanupOrigin::body_release: return "body_release";
    }
    return "unknown";
}
namespace {
using body_follow_lease::Refusal;
using body_follow_lease::Revocation;
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
    std::uint64_t next_sequence{};
    // Written under the lock only; every deadline edge reads it under the lock.
    body_follow_lease::State lease;
    // The client tick's packed revocation facts. Stored before that tick tries
    // the lock, so no lock holder can hide them. Describes the client, not a
    // receipt, so an ACK leaves it in place.
    std::atomic<std::uint64_t> guard{};
    // Callbacks that found this lock busy while the slot was live, and so were
    // not followed. Counted outside the lock; reset at reserve and at ACK.
    std::atomic<std::uint64_t> dispatch_busy{};
    // Under the service lock; counted only when the fallback is committed.
    std::uint64_t lead_skipped{};
    actor_control_native::Reason reason{actor_control_native::Reason::unavailable};
    actor_control_native::Reason park_reason{actor_control_native::Reason::unavailable};
    bool occupied{}, orphaned{}, body_release_requested{}, body_release_started{}, stop_cause_recorded{}, command_cleanup_sealed{};
    StopDiagnostic first_stop;
    CleanupDiagnostic first_cleanup, latest_cleanup;
    bool stop_drained{}, cleanup_drained{}, latest_cleanup_drained{};
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
DiagnosticState diagnostic_state(const Service& s) noexcept {
    return {s.binding.sequence, s.final.revision, s.returned_revision.load(std::memory_order_acquire),
        s.binding.published, s.binding.stopped, s.release_hold.available(), s.body_release_requested,
        s.body_release_started, s.park_fence.available(), s.park_receipt.available(),
        s.lease.renewals, s.dispatch_busy.load(std::memory_order_relaxed), s.lease.revocation, s.lead_skipped};
}
void cleanup_observation(Service& s, CleanupOrigin origin, const body_follow_native::Diagnostic& provider) noexcept {
    const CleanupDiagnostic next{diagnostic_state(s), origin, s.park_reason, provider, true};
    if (!s.first_cleanup.available) {
        s.first_cleanup = s.latest_cleanup = next;
        // The first record is already delivered by the immutable first channel.
        s.latest_cleanup_drained = true;
        return;
    }
    const auto& previous = s.latest_cleanup;
    if (previous.state == next.state && previous.origin == next.origin && previous.park_reason == next.park_reason &&
        previous.provider.stage == next.provider.stage && previous.provider.world_park == next.provider.world_park) return;
    s.latest_cleanup = next; s.latest_cleanup_drained = false;
}
void stop_locked(Service& s, actor_control_native::Reason reason, StopOrigin origin,
    const body_follow_native::Diagnostic& provider = {}) noexcept {
    s.edge.fetch_or(stopped_bit, std::memory_order_acq_rel);
    if (!s.stop_cause_recorded) {
        s.reason = reason; s.stop_cause_recorded = true;
        s.first_stop = {diagnostic_state(s), origin, reason, provider, true};
    }
    if (s.binding.published || s.orphaned) s.body_release_requested = true;
    if (s.release_hold.available() && s.body_release_requested)
        (void)owned_bodies::request_held_release(s.binding.owner, s.release_hold);
    (void)body_follow_native::stop(s.binding);
}
// The same stop, from a lease edge. The revocation is latched only when this is
// the receipt's first stop, so it always names the stop the receipt's reason
// describes; a stop from anywhere else leaves it unset and the lease reads other.
void lease_stop(Service& s, Revocation cause, StopOrigin origin) noexcept {
    // Every lease edge passes a cause; never stop with reason none.
    if (cause == Revocation::none || cause == Revocation::other) cause = Revocation::deadline;
    if (!s.stop_cause_recorded) s.lease.revocation = cause;
    stop_locked(s, body_follow_lease::receipt_reason(cause), origin);
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
bool seal_completed_commands(Service& s) noexcept {
    if (s.command_cleanup_sealed) return true;
    if (!completed_ack_ready(s) ||
        !body_follow_native::seal_command_cleanup(s.binding, s.park_fence, s.park_receipt)) return false;
    s.command_cleanup_sealed = true;
    return true;
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
    s.lease = {};
    s.dispatch_busy.store(0, std::memory_order_relaxed);
    s.lead_skipped = 0;
    s.reason = s.park_reason = actor_control_native::Reason::unavailable;
    s.orphaned = s.body_release_requested = s.body_release_started = s.stop_cause_recorded = s.command_cleanup_sealed = false;
    s.first_stop = {}; s.first_cleanup = {}; s.latest_cleanup = {};
    s.stop_drained = s.cleanup_drained = s.latest_cleanup_drained = false;
    // edge remains stopped_bit. next_sequence and the actual Arbiter are never
    // reset, so stale handles cannot become valid after receipt or owner reuse.
    // The guard word stays: it is the client's latest sample, not this receipt's.
    s.occupied = false;
}
void acknowledge_orphan_locked(Service& s) noexcept {
    const auto owner = s.owner.load(std::memory_order_acquire);
    const Handle handle{s.sequence.load(std::memory_order_acquire)};
    if (!s.orphaned || !matches(s, owner, handle)) return;
    if (completed_ack_ready(s)) {
        if (seal_completed_commands(s)) acknowledge_locked(s);
    } else if (abandoned_release_handed_off(s)) acknowledge_locked(s);
}
bool quiet() noexcept {
    // Each participating publisher takes an IdleCall from the actual Arbiter.
    // Reserve has already excluded those publishers; these queries distinguish
    // old tuning/restoration duty from a merely empty dispatch count.
    return skater_action::follow_duties_idle();
}
bool valid_attachment(const body_follow_native::Attachment& value) noexcept {
    if (!body_follow_api::valid_cleanup(value.cleanup)) return false;
    if (!body_follow_native::valid_motion_policy(value.motion_policy) ||
        (value.motion_policy == body_follow_native::MotionPolicy::callback_entry &&
            value.cleanup != body_follow_native::CleanupPolicy::owned_body)) return false;
    // A renewable lease holds the body for longer, so only the owned-body
    // cleanup path that completed in game may carry it.
    if (!body_follow_api::valid_lifetime(value.lifetime) ||
        (body_follow_api::renewable_lifetime(value.lifetime) &&
            value.cleanup != body_follow_native::CleanupPolicy::owned_body)) return false;
    if (!body_follow_api::valid_lead(value.lead) || !owned_body::finite(value.offset_from_com, 10)) return false;
    double norm{};
    for (const auto lane : value.root_in_body) {
        if (!std::isfinite(lane)) return false;
        norm += static_cast<double>(lane) * lane;
    }
    return std::abs(norm - 1.0) <= .0001;
}
}

namespace {
void take_diagnostics_impl(StopDiagnostic& stop, CleanupDiagnostic& cleanup, CleanupDiagnostic* latest) noexcept {
    LastError error; stop = {}; cleanup = {}; if (latest) *latest = {};
    auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return;
    Unlock unlock{s.lock};
    if (s.first_stop.available && !s.stop_drained) {
        stop = s.first_stop; s.stop_drained = true;
    }
    if (s.first_cleanup.available && !s.cleanup_drained) {
        cleanup = s.first_cleanup; s.cleanup_drained = true;
    }
    if (latest && s.latest_cleanup.available && !s.latest_cleanup_drained) {
        *latest = s.latest_cleanup; s.latest_cleanup_drained = true;
    }
}
}
void take_diagnostics(StopDiagnostic& stop, CleanupDiagnostic& cleanup) noexcept {
    take_diagnostics_impl(stop, cleanup, nullptr);
}
void take_diagnostics(StopDiagnostic& stop, CleanupDiagnostic& cleanup, CleanupDiagnostic& latest) noexcept {
    take_diagnostics_impl(stop, cleanup, &latest);
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
    const bool renewable = body_follow_api::renewable_lifetime(attachment.lifetime);
    const bool session_renewable = attachment.lifetime == body_follow_native::Lifetime::session_renewable;
    if (renewable) {
        // A renewable lease starts only with every revocation fact clear, and
        // refuses before any claim: nothing is occupied and no cleanup is owed.
        const auto word = s.guard.load(std::memory_order_acquire);
        const auto cause = body_follow_lease::guard_cause(word, GetTickCount64());
        if (cause != Revocation::none) { reason = body_follow_lease::receipt_reason(cause); return false; }
    }
    owned_bodies::MeasuredSource actual;
    if (!owned_bodies::capture_source(owner, body, actual) || !actual.same_allocation(expected) ||
        !body_query::same_sample(actual.sample(), expected.sample())) return false;
    s.occupied = true; s.body = body; s.attachment = attachment;
    s.dispatch_busy.store(0, std::memory_order_relaxed);
    s.lead_skipped = 0;
    s.binding.cleanup = attachment.cleanup;
    s.binding.motion_policy = attachment.motion_policy;
    const auto sequence = ++s.next_sequence;
    if (!body_follow_native::reserve_binding(owner, sequence, actual, admission, s.binding, reason)) {
        if (!s.binding.reserved) { s.occupied = false; s.binding = {}; return false; }
        s.owner.store(owner, std::memory_order_release);
        s.sequence.store(sequence, std::memory_order_release);
        out.sequence = sequence; stop_locked(s, reason, StopOrigin::reserve_binding); return false;
    }
    out.sequence = sequence;
    s.edge.store(0, std::memory_order_release);
    s.owner.store(owner, std::memory_order_release);
    s.sequence.store(sequence, std::memory_order_release);
    if (!quiet() || !owned_bodies::acquire_release_hold(owner, actual, s.release_hold)) {
        reason = actor_control_native::Reason::motion_owned;
        stop_locked(s, reason, StopOrigin::reserve_hold); return false;
    }
    // Every mode starts with three seconds. The legacy renewable mode keeps
    // its 120 s ceiling; an explicit session keeps only the rolling deadline.
    if (!body_follow_lease::start(s.lease, GetTickCount64(), renewable, session_renewable)) {
        reason = actor_control_native::Reason::expired;
        stop_locked(s, reason, StopOrigin::reserve_clock); return false;
    }
    s.reason = reason = actor_control_native::Reason::none;
    return true;
}

bool publish(std::uint64_t owner, Handle handle, actor_control_native::Reason& reason) noexcept {
    LastError error; reason = actor_control_native::Reason::unavailable;
    auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return false;
    Unlock unlock{s.lock};
    if (!matches(s, owner, handle) || s.binding.stopped || s.edge.load(std::memory_order_acquire) || !s.release_hold.available() ||
        GetTickCount64() < s.lease.started || GetTickCount64() >= s.lease.deadline || !quiet()) return false;
    if (s.lease.renewable) {
        const auto word = s.guard.load(std::memory_order_acquire);
        const auto cause = body_follow_lease::guard_cause(word, GetTickCount64());
        if (cause != Revocation::none) {
            reason = body_follow_lease::receipt_reason(cause);
            lease_stop(s, cause, StopOrigin::lease_guard); return false;
        }
    }
    bool release_requested{};
    if (!owned_bodies::release_requested(owner, s.release_hold, release_requested) || release_requested ||
        !body_follow_native::publish_binding(s.binding, reason)) {
        stop_locked(s, reason, StopOrigin::publish_binding); return false;
    }
    const auto published_ms = GetTickCount64();
    if (s.edge.load(std::memory_order_acquire) || published_ms < s.lease.started || published_ms >= s.lease.deadline) {
        if (s.edge.load(std::memory_order_acquire)) {
            reason = actor_control_native::Reason::cancelled;
            stop_locked(s, reason, StopOrigin::publish_closing);
        } else {
            reason = actor_control_native::Reason::expired;
            lease_stop(s, body_follow_lease::expiry(s.lease, published_ms), StopOrigin::publish_closing);
        }
        return false;
    }
    s.reason = reason = actor_control_native::Reason::none;
    return true;
}

body_follow_api::ReadStatus read_status(std::uint64_t owner, Handle handle, Receipt& out) noexcept {
    LastError error; out = {};
    auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return body_follow_api::ReadStatus::busy;
    Unlock unlock{s.lock};
    if (!matches(s, owner, handle)) return body_follow_api::ReadStatus::unavailable;
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
    return body_follow_api::ReadStatus::ok;
}
bool read(std::uint64_t owner, Handle handle, Receipt& out) noexcept {
    return read_status(owner, handle, out) == body_follow_api::ReadStatus::ok;
}

namespace {
// The receipt a renewal names is still this exact one: same owner, sequence and
// body, renewable, published and not stopped. A callback inside its original
// call is allowed; the deadline it already checked is unaffected.
bool renewal_target(const Service& s, std::uint64_t owner, Handle handle, const owned_body::Handle& body,
    Refusal& refusal) noexcept {
    refusal = Refusal::not_following;
    if (!matches(s, owner, handle) || !(s.body == body)) return false;
    if (!s.lease.renewable) { refusal = Refusal::not_renewable; return false; }
    return s.binding.published && !s.binding.stopped && !s.stop_cause_recorded &&
        !(s.edge.load(std::memory_order_acquire) & stopped_bit);
}
// The lease check every renewal window makes first. A lapse or a revoking guard
// stops the Follow here, through the ordinary stop and cleanup, and is never
// renewed away. Then the checks that need no body.
bool renewal_window(Service& s, std::uint64_t proof_serial, std::uint64_t& now, std::uint64_t& word,
    Refusal& refusal) noexcept {
    word = s.guard.load(std::memory_order_acquire);
    now = GetTickCount64();
    const auto cause = body_follow_lease::check(s.lease, now, word);
    if (cause != Revocation::none) {
        lease_stop(s, cause, body_follow_lease::lapse(cause) ? StopOrigin::renew_expired : StopOrigin::lease_guard);
        refusal = body_follow_lease::refusal(cause); return false;
    }
    refusal = body_follow_lease::precheck(s.lease, proof_serial);
    return refusal == Refusal::none;
}
} // namespace

bool renew(std::uint64_t owner, Handle handle, const owned_body::Handle& body, const owned_body::Epoch& proof,
    std::uint64_t& remaining_ms, Refusal& refusal) noexcept {
    LastError error; remaining_ms = 0; refusal = Refusal::busy;
    auto& s = service();
    owned_bodies::MeasuredSource identity;
    std::uint64_t sequence{}, now{}, word{};
    {
        // Window A: compare and copy only. The reserved measured source selects
        // the exact allocation; World's check below holds no Follow lock.
        if (!TryAcquireSRWLockExclusive(&s.lock)) return false;
        Unlock unlock{s.lock};
        if (!renewal_target(s, owner, handle, body, refusal) || !renewal_window(s, proof.serial, now, word, refusal)) return false;
        identity = s.binding.source;
        sequence = s.binding.sequence;
    }
    std::uint64_t current_serial{};
    switch (owned_bodies::check_renewal_proof(owner, identity, proof, current_serial)) {
    case owned_bodies::RenewalProof::current: break;
    case owned_bodies::RenewalProof::busy: refusal = Refusal::busy; return false;
    case owned_bodies::RenewalProof::not_latest:
    case owned_bodies::RenewalProof::clock_stale: refusal = Refusal::sample_stale; return false;
    case owned_bodies::RenewalProof::body_unavailable:
    default: refusal = Refusal::body_unavailable; return false;
    }
    // Window B: the same receipt again. A stop, or an ACK and a new reserve,
    // between the windows makes this not_following, and nothing commits.
    if (!TryAcquireSRWLockExclusive(&s.lock)) { refusal = Refusal::busy; return false; }
    Unlock unlock{s.lock};
    if (!renewal_target(s, owner, handle, body, refusal) || s.binding.sequence != sequence) {
        refusal = Refusal::not_following; return false;
    }
    if (!renewal_window(s, proof.serial, now, word, refusal)) return false;
    refusal = body_follow_lease::renew(s.lease, now, proof.serial, current_serial, word, remaining_ms);
    return refusal == Refusal::none;
}

body_follow_api::ReadStatus read_lease(std::uint64_t owner, Handle handle, body_follow_api::LeaseReceipt& out) noexcept {
    LastError error; out = {};
    auto& s = service();
    if (!TryAcquireSRWLockExclusive(&s.lock)) return body_follow_api::ReadStatus::busy;
    Unlock unlock{s.lock};
    if (!matches(s, owner, handle)) return body_follow_api::ReadStatus::unavailable;
    const auto now = GetTickCount64();
    const auto& lease = s.lease;
    const bool stopped = s.stop_cause_recorded || s.binding.stopped;
    const bool live = !stopped && body_follow_lease::remaining(lease, now) != 0;
    out.handle = {handle.sequence};
    out.renewable = lease.renewable;
    out.session_renewable = lease.session_renewable;
    out.active = live && s.binding.published;
    out.renewals = lease.renewals;
    out.last_serial = lease.last_serial;
    out.dispatch_busy = s.dispatch_busy.load(std::memory_order_relaxed);
    out.remaining_ms = live ? lease.deadline - now : 0;
    out.lifetime_remaining_ms = live && !lease.session_renewable ? lease.ceiling - now : 0;
    out.base_ms = body_follow_lease::base_ms;
    out.renewal_ms = body_follow_lease::renewal_ms;
    out.lifetime_ms = lease.session_renewable ? 0 :
        lease.renewable ? body_follow_lease::maximum_lifetime_ms : body_follow_lease::base_ms;
    out.revocation = lease.revocation != Revocation::none ? lease.revocation : stopped ? Revocation::other : Revocation::none;
    return body_follow_api::ReadStatus::ok;
}

bool stop(std::uint64_t owner, Handle handle) noexcept {
    LastError error; auto& s = service();
    // Avoid invalid/foreign handles stopping someone else's slot.
    if (!owner || !handle.sequence || s.owner.load(std::memory_order_acquire) != owner ||
        s.sequence.load(std::memory_order_acquire) != handle.sequence) return false;
    AcquireSRWLockExclusive(&s.lock);
    Unlock unlock{s.lock};
    if (!matches(s, owner, handle)) return false;
    stop_locked(s, actor_control_native::Reason::cancelled, StopOrigin::explicit_stop);
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
    if (!matches(s, owner, handle) || !completed_ack_ready(s) || !seal_completed_commands(s)) return false;
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
    stop_locked(s, actor_control_native::Reason::owner_released, StopOrigin::owner_release);
}

void tick(bool ready) noexcept {
    LeaseGuard guard;
    guard.sampled_ms = GetTickCount64();
    guard.ready = ready;
    tick(guard);
}
void tick(const LeaseGuard& guard) noexcept {
    LastError error; auto& s = service();
    // Publish first: a missed Try below must not hide a revoking fact.
    const auto word = body_follow_lease::pack(guard);
    s.guard.store(word, std::memory_order_release);
    const bool ready = guard.ready;
    if (!TryAcquireSRWLockExclusive(&s.lock)) return;
    Unlock unlock{s.lock};
    if (!s.occupied) return;
    if (completed(s)) {
        (void)seal_completed_commands(s);
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
            stop_locked(s, actor_control_native::Reason::owner_released, StopOrigin::release_query);
    }
    // A renewable lease's guard and clock, above the cleanup below, so a stop
    // here reaches today's cleanup in this same tick.
    const auto now = GetTickCount64();
    if (s.lease.renewable) {
        const auto cause = body_follow_lease::check(s.lease, now, word);
        if (cause != Revocation::none)
            lease_stop(s, cause, body_follow_lease::lapse(cause) ? StopOrigin::tick_expired : StopOrigin::lease_guard);
    }
    if (!ready || now < s.lease.started || now >= s.lease.deadline)
        lease_stop(s, ready ? body_follow_lease::expiry(s.lease, now) : Revocation::client_not_ready,
            ready ? StopOrigin::tick_expired : StopOrigin::runtime_not_ready);
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
    if (!release_known) {
        cleanup_observation(s, CleanupOrigin::release_query, {}); return;
    }
    // The opt-in body-authority route cannot drop its dependency hold or even
    // capture a park floor while a committed original is invoking/unreturned.
    // Zero/zero is valid when no original was ever committed. Legacy ordering stays.
    if (s.binding.cleanup == body_follow_native::CleanupPolicy::owned_body &&
        (s.edge.load(std::memory_order_acquire) != stopped_bit ||
            s.final.revision != s.returned_revision.load(std::memory_order_acquire))) {
        s.park_reason = actor_control_native::Reason::unavailable;
        cleanup_observation(s, CleanupOrigin::capture_fence, {}); return;
    }
    body_follow_native::Diagnostic diagnostic;
    if (!s.park_fence.available() &&
        !body_follow_native::capture_park_fence(s.binding, s.park_fence, s.park_reason, diagnostic)) {
        cleanup_observation(s, CleanupOrigin::capture_fence, diagnostic); return;
    }
    if (!s.body_release_started) {
        if (s.release_hold.available() &&
            !owned_bodies::release_body_hold(s.binding.owner, s.release_hold)) {
            cleanup_observation(s, CleanupOrigin::release_hold, {}); return;
        }
        const auto issue = owned_bodies::release(s.binding.owner, s.body);
        if (!issue.empty()) {
            cleanup_observation(s, CleanupOrigin::body_release, {}); return;
        }
        s.body_release_started = true;
    }
    if (!body_follow_native::observe_park(s.binding, s.park_fence, s.park_receipt, s.park_reason, diagnostic)) {
        cleanup_observation(s, CleanupOrigin::observe_park, diagnostic); return;
    }
    // Only a normal completed original, actual stop/drain and matching park
    // can close this SDK claim. Unknown native pose history remains unknown.
    if (s.edge.load(std::memory_order_acquire) != stopped_bit || s.release_hold.available() ||
        !s.body_release_requested || !s.body_release_started ||
        s.final.revision != s.returned_revision.load(std::memory_order_acquire)) return;
    if (body_follow_native::complete_stop(s.binding, s.park_fence, s.park_receipt, diagnostic)) {
        (void)seal_completed_commands(s);
        acknowledge_orphan_locked(s);
    }
    else cleanup_observation(s, CleanupOrigin::complete_stop, diagnostic);
}

namespace {
template<class CommitEntry>
bool dispatch_impl(Original original, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, std::uint8_t flags,
    body_follow_native::NativeMotionEntry* entry, CommitEntry commit_entry) {
    LastError error;
    body_follow_native::PreparedTarget target;
    auto& s = service();
    std::uint64_t revision{};
    {
        if (!original) return false;
        if (!TryAcquireSRWLockExclusive(&s.lock)) {
            // This callback is not followed; the wrapper keeps its own writers.
            // Count it while the slot is live so a skipped callback is visible.
            if (!(s.edge.load(std::memory_order_relaxed) & stopped_bit))
                s.dispatch_busy.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        Unlock unlock{s.lock};
        if (!s.occupied || !s.binding.published || s.binding.stopped ||
            s.binding.actor.rig != rig || s.binding.actor.context != context) return false;
        if (!body_follow_native::valid_motion_policy(s.binding.motion_policy)) return false;
        const bool scoped = s.binding.motion_policy == body_follow_native::MotionPolicy::callback_entry;
        if (scoped && (!entry || !entry->current() ||
            s.binding.cleanup != body_follow_native::CleanupPolicy::owned_body)) return false;
        // An original still invoking is ordinary concurrent work, not evidence
        // of failure. Do not mistake its not-yet-returned revision for debt.
        if (s.edge.load(std::memory_order_acquire) & invoking_bit) return false;
        // A committed original without a normal return stays unresolved. A
        // later successful invocation must not overwrite that failure history.
        if (s.final.revision != s.returned_revision.load(std::memory_order_acquire)) {
            stop_locked(s, actor_control_native::Reason::unavailable, StopOrigin::dispatch_unreturned); return false;
        }
        const auto now = GetTickCount64();
        if (const auto lapsed = body_follow_lease::expiry(s.lease, now); lapsed != Revocation::none) {
            lease_stop(s, lapsed, StopOrigin::dispatch_expired); return false;
        }
        // Same receipt reason as before, with its own origin so a lapse and an
        // exhausted revision counter can be told apart.
        if (s.final.revision == std::numeric_limits<std::uint64_t>::max()) {
            stop_locked(s, actor_control_native::Reason::expired, StopOrigin::dispatch_revision_exhausted); return false;
        }
        // One atomic load under the lock this callback already holds; no allocation.
        if (s.lease.renewable) {
            const auto cause = body_follow_lease::guard_cause(s.guard.load(std::memory_order_acquire), now);
            if (cause != Revocation::none) { lease_stop(s, cause, StopOrigin::dispatch_guard); return false; }
        }
        body_follow_native::Diagnostic diagnostic;
        StopOrigin origin{StopOrigin::dispatch_prepare};
        const bool prepared = scoped ?
            body_follow_native::prepare_target(s.binding, *entry, s.attachment, target, s.reason, diagnostic) :
            body_follow_native::prepare_target(s.binding, rig, context, supplied, s.attachment, target, s.reason, diagnostic);
        if (!prepared ||
            (origin = StopOrigin::dispatch_current,
                !(scoped ? body_follow_native::current_target(s.binding, *entry, target, s.reason, diagnostic) :
                    body_follow_native::current_target(s.binding, target, s.reason, diagnostic)))) {
            stop_locked(s, s.reason, origin, diagnostic); return false;
        }
        const auto forwarding_ms = GetTickCount64();
        if (const auto lapsed = body_follow_lease::expiry(s.lease, forwarding_ms); lapsed != Revocation::none) {
            lease_stop(s, lapsed, StopOrigin::dispatch_forwarding_expired); return false;
        }
        unsigned idle{};
        if (scoped && !entry->current()) return false;
        if (!s.edge.compare_exchange_strong(idle, invoking_bit, std::memory_order_acq_rel)) return false;
        if (scoped) commit_entry();
        revision = s.final.revision + 1;
        s.final = {revision, target.source, target.value, flags};
        if (target.lead_skipped && s.lead_skipped != std::numeric_limits<std::uint64_t>::max()) ++s.lead_skipped;
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
} // namespace
bool dispatch(Original original, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, std::uint8_t flags) {
    return dispatch_impl(original, rig, context, supplied, flags, nullptr, []() noexcept {});
}
bool dispatch(body_follow_native::NativeMotionEntry& entry) {
    return dispatch_impl(entry.original_, entry.rig_, entry.context_, entry.supplied_, entry.flags_, &entry,
        [&entry]() noexcept { entry.used_ = true; });
}
} // namespace dingosdk::body_follow_service
