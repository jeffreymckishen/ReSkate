#pragma once
#include "Engine/Game/World/owned_body.h"
#include "body_follow_lease.h"
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
// Opt-in only. The default keeps the fixed three-second lease from reservation.
// A renewable lease (body_follow_lease.h) needs owned-body cleanup and its own
// permission, and is extended only by proof from a newly issued body sample.
enum class Lifetime : std::uint8_t { fixed, renewable };
constexpr bool valid_lifetime(Lifetime lifetime) noexcept {
    return lifetime == Lifetime::fixed || lifetime == Lifetime::renewable;
}
// Pose lead uses only the followed body's current measured motion. It neither
// accepts a plugin velocity nor writes momentum into the actor.
inline constexpr std::uint8_t maximum_lead_steps = 3;
struct Lead { std::uint8_t steps{}; bool angular{}; };
constexpr bool valid_lead(const Lead& lead) noexcept { return lead.steps <= maximum_lead_steps; }
struct Attachment {
    owned_body::Vec offset_from_com{};
    owned_body::Quaternion root_in_body{0, 0, 0, 1};
    CleanupPolicy cleanup{CleanupPolicy::actor_lifetime};
    MotionPolicy motion_policy{MotionPolicy::native_lifetime};
    Lifetime lifetime{Lifetime::fixed};
    Lead lead{};
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
    stop_limit = 1, acknowledge_limit = 1, renew_limit = 1, lease_read_limit = 8;
// A receipt or lease read that found the Service lock busy is told apart from
// one whose receipt is foreign, reset or unknown. Neither is a native refusal.
enum class ReadStatus : std::uint8_t { ok, busy, unavailable };
// Copied lease facts, separate from Receipt so the receipt keeps its fields.
// Times are native milliseconds left, never deadlines: the native clock is not
// the plugin clock. A stopped or lapsed lease reports zero for both.
struct LeaseReceipt {
    Handle handle{};
    bool renewable{}, active{};
    std::uint64_t renewals{}, last_serial{}, dispatch_busy{};
    std::uint64_t remaining_ms{}, lifetime_remaining_ms{}, base_ms{}, renewal_ms{}, lifetime_ms{};
    body_follow_lease::Revocation revocation{body_follow_lease::Revocation::none};
};
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
    if (!valid_lifetime(attachment.lifetime) ||
        (attachment.lifetime == Lifetime::renewable && attachment.cleanup != CleanupPolicy::owned_body)) return false;
    if (!valid_lead(attachment.lead) || !owned_body::finite(attachment.offset_from_com, 10)) return false;
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
