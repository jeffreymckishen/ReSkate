#pragma once
#include "Engine/Game/World/owned_body.h"
#include "native_action_policy.h"
#include <cstdint>

namespace dingosdk::body_follow_api {
// Copied plugin-facing values. Native identity, measured-source credentials,
// actor claims and park fences remain inside the runtime services.
struct Handle { std::uint64_t sequence{}; };
// Explicit cleanup only. This never changes native actor admission or actuation.
enum class CleanupPolicy : std::uint8_t { actor_lifetime, owned_body };
constexpr bool valid_cleanup(CleanupPolicy policy) noexcept {
    return policy == CleanupPolicy::actor_lifetime || policy == CleanupPolicy::owned_body;
}
// Selection is copied at reserve. It is not a native identity or lifetime proof.
// The default preserves full native-lifetime continuity between callbacks.
enum class MotionPolicy : std::uint8_t { native_lifetime, callback_entry };
constexpr bool valid_motion_policy(MotionPolicy policy) noexcept {
    return policy == MotionPolicy::native_lifetime || policy == MotionPolicy::callback_entry;
}
struct Attachment {
    owned_body::Vec offset_from_com{};
    owned_body::Quaternion root_in_body{0, 0, 0, 1};
    CleanupPolicy cleanup{CleanupPolicy::actor_lifetime};
    MotionPolicy motion_policy{MotionPolicy::native_lifetime};
};
enum class Phase : std::uint8_t { reserved, following, stopping, retained, abandoned, completed };
enum class Pending : std::uint8_t { none, body_parked };
using Reason = skater_action::Reason;
struct Receipt {
    Handle handle{};
    Phase phase{Phase::reserved};
    Reason reason{Reason::unavailable}, park_reason{Reason::unavailable};
    std::uint64_t final_revision{}, final_native_epoch{}, returned_revision{};
    Pending pending{Pending::none};
    unsigned in_flight{};
    bool claim_known{}, orphaned{}, park_observed{}, native_retirement_known{};
};
inline constexpr unsigned reserve_limit = 1, read_limit = 8, publish_limit = 1,
    stop_limit = 1, acknowledge_limit = 1;
constexpr bool terminal(Phase phase) noexcept {
    return phase == Phase::abandoned || phase == Phase::completed;
}
constexpr const char* phase_name(Phase phase) noexcept {
    switch (phase) {
    case Phase::reserved: return "reserved";
    case Phase::following: return "following";
    case Phase::stopping: return "stopping";
    case Phase::retained: return "retained";
    case Phase::abandoned: return "abandoned";
    case Phase::completed: return "completed";
    }
    return nullptr;
}
inline bool valid(const Attachment& attachment) noexcept {
    if (!valid_cleanup(attachment.cleanup) || !valid_motion_policy(attachment.motion_policy) ||
        (attachment.motion_policy == MotionPolicy::callback_entry && attachment.cleanup != CleanupPolicy::owned_body)) return false;
    if (!owned_body::finite(attachment.offset_from_com, 10)) return false;
    double norm{};
    for (const float lane : attachment.root_in_body) {
        if (!std::isfinite(lane)) return false;
        norm += static_cast<double>(lane) * lane;
    }
    return std::abs(norm - 1.0) <= .0001;
}
// Trusted runtime admission, not a callback or a state supplied by a plugin.
// Known airborne upright actors remain eligible. Retail state continuity
// across hops still needs a native test; constructed Host cases cannot prove it.
constexpr bool eligible(const skater_action::State& state) noexcept {
    return state.known && state.value == 504 && state.ragdoll_known && !state.ragdoll && state.in_air_known;
}
} // namespace dingosdk::body_follow_api
