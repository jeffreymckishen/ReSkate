#pragma once
#include "native_body_follow.h"
#include "Engine/Game/Skater/body_follow_lease.h"

namespace dingosdk::body_follow_service {
// Internal service only. No Lua registration or runtime admission caller is
// included until the native callback and retirement edges are qualified.
struct Handle { std::uint64_t sequence{}; };
enum class Phase : std::uint8_t { reserved, following, stopping, retained, abandoned, completed };
struct Receipt {
    Phase phase{Phase::reserved};
    actor_control_native::Reason reason{actor_control_native::Reason::unavailable};
    actor_control_native::Reason park_reason{actor_control_native::Reason::unavailable};
    std::uint64_t final_revision{}, final_native_epoch{}, returned_revision{};
    actor_control::Barrier pending{actor_control::Barrier::none};
    unsigned in_flight{};
    bool claim_known{}, orphaned{}, park_observed{}, native_retirement_known{};
};
// Internal diagnostics, separate from Receipt and all plugin DTOs. Exactly one
// first-stop and first-cleanup observation is retained for the current receipt.
// A separate one-slot latest categorical cleanup failure may coalesce changes.
enum class StopOrigin : std::uint8_t {
    reserve_binding, reserve_hold, reserve_clock, publish_binding, publish_closing,
    explicit_stop, owner_release, release_query, runtime_not_ready, tick_expired,
    dispatch_unreturned, dispatch_expired, dispatch_prepare, dispatch_current, dispatch_forwarding_expired,
    // A renewable lease's guard at publish, tick or renewal; a lapse found by a
    // renewal; the guard at a callback; and revision exhaustion, apart from a lapse.
    lease_guard, renew_expired, dispatch_guard, dispatch_revision_exhausted
};
enum class CleanupOrigin : std::uint8_t { capture_fence, observe_park, complete_stop, release_query, release_hold, body_release };
struct DiagnosticState {
    // Stop captures these stored fields before requesting release or applying
    // Binding::stop; cleanup captures them at the first provider refusal.
    std::uint64_t sequence{}, final_revision{}, returned_revision{};
    bool published{}, stopped{}, release_hold{}, release_requested{}, release_started{}, fence{}, park{};
    // Lease facts at the same point: accepted renewals, callbacks skipped on a
    // busy lock, and the revocation latched by this receipt's first stop.
    std::uint64_t renewals{}, dispatch_busy{};
    body_follow_lease::Revocation revocation{body_follow_lease::Revocation::none};
    bool operator==(const DiagnosticState&) const = default;
};
struct StopDiagnostic {
    DiagnosticState state;
    StopOrigin origin{StopOrigin::runtime_not_ready};
    actor_control_native::Reason reason{actor_control_native::Reason::unavailable};
    body_follow_native::Diagnostic provider;
    bool available{};
};
struct CleanupDiagnostic {
    DiagnosticState state;
    CleanupOrigin origin{CleanupOrigin::capture_fence};
    actor_control_native::Reason park_reason{actor_control_native::Reason::unavailable};
    body_follow_native::Diagnostic provider;
    bool available{};
};
const char* stop_origin_name(StopOrigin) noexcept;
const char* cleanup_origin_name(CleanupOrigin) noexcept;
// Client tick only. Copies/marks at most one of each under the service lock;
// formatting/logging happens after return. ACK/reuse may discard an undrained
// receipt; diagnostics never block either operation or change authority.
void take_diagnostics(StopDiagnostic&, CleanupDiagnostic&) noexcept;
// The legacy overload never consumes latest. This overload copies it only when
// its categorical failure/state changed since the last copy, under the same Try lock.
void take_diagnostics(StopDiagnostic&, CleanupDiagnostic&, CleanupDiagnostic& latest) noexcept;
using Original = body_follow_native::NativeMotionEntry::Original;

// Client thread. Fixed one-slot capacity is secured before the actual claim.
// Source must join the supplied body to an actual same-allocation measurement.
// A false result with a nonzero handle still owns unresolved cleanup duty.
bool reserve(std::uint64_t owner, const owned_body::Handle& body,
    const owned_bodies::MeasuredSource&, const body_follow_native::Attachment&,
    actor_control_native::Admission, Handle&, actor_control_native::Reason&) noexcept;
bool publish(std::uint64_t owner, Handle, actor_control_native::Reason&) noexcept;
// One Try lock. busy is a missed Try, apart from a foreign or reset receipt.
body_follow_api::ReadStatus read_status(std::uint64_t owner, Handle, Receipt&) noexcept;
bool read(std::uint64_t owner, Handle, Receipt&) noexcept; // read_status(...) == ok
// Client thread, renewable lease only. Two short Try windows on this lock with
// World's shared Try check of the proof between them; no World work holds this
// lock. The proof must be the followed body's latest issued sample, newer than
// the last accepted proof and at most proof_steps behind a physics step observed
// under 100 ms ago. A lapse or a revoking guard found here stops the Follow.
// True moves the deadline to max(deadline, min(now + 500, ceiling)) and
// reports the whole native milliseconds left.
bool renew(std::uint64_t owner, Handle, const owned_body::Handle& body, const owned_body::Epoch& proof,
    std::uint64_t& remaining_ms, body_follow_lease::Refusal&) noexcept;
// Copied lease facts for either lifetime; one Try lock, no state change.
body_follow_api::ReadStatus read_lease(std::uint64_t owner, Handle, body_follow_api::LeaseReceipt&) noexcept;
bool stop(std::uint64_t owner, Handle) noexcept;
// Explicit client-thread receipt ACK, only after exact never-published
// abandonment and actual dependency-hold drop. It neither releases a body nor
// acknowledges native retirement. A published receipt cannot be acknowledged.
bool acknowledge_abandoned(std::uint64_t owner, Handle) noexcept;
// Separate terminal receipt ACK after actual published SDK claim retirement
// and matching park history. This never acknowledges native pose erasure.
bool acknowledge_completed(std::uint64_t owner, Handle) noexcept;
void release_all(std::uint64_t owner) noexcept;
// Called after actual owned-body tick, even while the VM has gone away. This
// completes only exact stopped/drained SDK ownership plus positive park. It
// never claims native pose-history consumption from a return or passive probe.
// The guard is stored as one atomic word before the lock is tried, so a missed
// Try still publishes the facts to the renewal, publish or callback that follows.
// A fixed lease ignores every fact but ready.
using LeaseGuard = body_follow_lease::Guard;
void tick(const LeaseGuard&) noexcept;
// The same tick with only readiness known; every other guard fact reads false.
void tick(bool ready) noexcept;

// Existing native wrapper calls this BEFORE IdleCall dispatch. A true result
// means this function invoked the supplied original exactly once. A false
// result invoked it zero times, so the wrapper retains ordinary forwarding.
// No SDK service/body/actor lock spans original; one native Call does span it.
bool dispatch(Original, std::uintptr_t rig, std::uintptr_t context,
    const std::array<float, 16>* supplied, std::uint8_t flags);
// Only the genuine wrapper can mint this live entry in production. The raw
// overload above cannot author a callback_entry binding.
bool dispatch(body_follow_native::NativeMotionEntry&);
} // namespace dingosdk::body_follow_service
