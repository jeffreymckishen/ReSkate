#pragma once
#include "native_body_follow.h"

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
    dispatch_unreturned, dispatch_expired, dispatch_prepare, dispatch_current, dispatch_forwarding_expired
};
enum class CleanupOrigin : std::uint8_t { capture_fence, observe_park, complete_stop, release_query, release_hold, body_release };
struct DiagnosticState {
    // Stop captures these stored fields before requesting release or applying
    // Binding::stop; cleanup captures them at the first provider refusal.
    std::uint64_t sequence{}, final_revision{}, returned_revision{};
    bool published{}, stopped{}, release_hold{}, release_requested{}, release_started{}, fence{}, park{};
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
bool read(std::uint64_t owner, Handle, Receipt&) noexcept;
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
