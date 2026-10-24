#pragma once
#include <cstdint>
#include "Engine/Game/Skater/native_action.h"
#include "Engine/Game/Skater/actor_control_policy.h"

namespace dingosdk::skater_action {
enum class MotionGuardStatus : std::uint8_t { idle, active, unavailable };
using MotionGuard = MotionGuardStatus (*)() noexcept;
// Providers register before their first publication. Registration is set-once;
// each provider checks publication_allowed inside its own publication lock.
bool register_motion_guard(MotionGuard guard) noexcept;
bool motion_publication_allowed() noexcept;
// Actual native dispatch and immediate mutation use a scope, not the sampled
// publication query. The marker takes no NoBail/provider lock, so existing
// provider critical sections can enter it without adding a reverse lock edge.
bool enter_motion_writer(actor_control::IdleCall& call) noexcept;
// Observe only while an actual follow claim excludes new optional writers.
// Contention, stale readiness, or unresolved native duties refuse admission.
// This does not clear protections, native requests, or restoration state.
bool follow_no_bail_duties_idle() noexcept;
// Parent composition combines each concrete provider's current-duty query.
// Call after follow reservation; this is not a universal guard registry.
bool follow_duties_idle() noexcept;
bool request(std::uint64_t owner, Kind kind, Handle& handle, Reason& reason) noexcept;
bool read(std::uint64_t owner, Handle handle, Receipt& receipt) noexcept;
bool cancel(std::uint64_t owner, Handle handle) noexcept;
bool acknowledge(std::uint64_t owner, Handle handle) noexcept;
void release_all(std::uint64_t owner) noexcept;
void tick(std::uintptr_t image_base, std::uintptr_t client, bool ready) noexcept;
} // namespace dingosdk::skater_action
