#pragma once
#include "native_action.h"
#include <cstdint>

namespace dingosdk::skater_recovery {
using Reason = skater_action::Reason;
enum class Status : std::uint8_t {
    pending, entered, reset, completed, already_true, rejected, cancelled, expired, invalidated
};
struct Handle { std::uint64_t sequence{}; };
struct State {
    bool known{}, ragdoll_known{}, ragdoll{}, in_air_known{}, in_air{};
    std::uint32_t value{};
    bool operator==(const State&) const = default;
};
struct Receipt {
    Handle handle{};
    Status status{Status::pending};
    Reason reason{Reason::none};
    std::uint64_t requested_ms{}, observed_ms{}, true_ms{}, reset_ms{}, true_serial{}, reset_serial{};
    // Adapter counters increment only at actual native setter ABI entry.
    std::uint64_t native_true_calls{}, native_reset_calls{};
    double true_time{}, reset_time{};
    bool prior_known{}, prior_value{}, true_entered{}, true_returned{}, true_readback_known{}, true_readback{};
    bool reset_pending{}, reset_entered{}, reset_returned{}, reset_readback_known{}, reset_false{};
    // A destroyed actor may retire its claim while the old Bool remains
    // unverified. That exception never changes unresolved into reset proof.
    bool cleared_before_reset{}, unresolved{}, actor_retired{}, quarantined{};
    unsigned start_attempts{}, cleanup_attempts{};
    State state{};
    // These describe the adapter's qualified observation suffix, never visual
    // recovery or a promise that native gameplay cannot fall on a later step.
    bool standing_observed{}, stable_observed{};
    unsigned standing_samples{};
    double standing_seconds{}, standing_required_seconds{2.0};
};
constexpr bool terminal(Status status) noexcept {
    return status != Status::pending && status != Status::entered && status != Status::reset;
}
constexpr const char* status_name(Status status) noexcept {
    switch (status) {
    case Status::pending: return "pending";
    case Status::entered: return "entered";
    case Status::reset: return "reset";
    case Status::completed: return "completed";
    case Status::already_true: return "already_true";
    case Status::rejected: return "rejected";
    case Status::cancelled: return "cancelled";
    case Status::expired: return "expired";
    case Status::invalidated: return "invalidated";
    }
    return "invalid";
}
constexpr const char* reason_name(Reason reason) noexcept { return skater_action::reason_name(reason); }
} // namespace dingosdk::skater_recovery
