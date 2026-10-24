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
using Original = void (*)(std::uintptr_t, std::uintptr_t, const std::array<float, 16>*, std::uint8_t);

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
} // namespace dingosdk::body_follow_service
