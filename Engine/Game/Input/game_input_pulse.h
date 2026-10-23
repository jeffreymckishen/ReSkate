#pragma once
#include "input_pulse.h"
#include <cstdint>

namespace dingosdk::game_input_pulse {
inline constexpr unsigned retained_capacity = 8;
inline constexpr std::uint64_t lifetime_ms = 1000;
struct Handle {
    std::uint64_t sequence{};
    bool operator==(const Handle&) const = default;
};
enum class Status { queued, warming, pressing, releasing, released, cancelled, expired, revoked };
enum class RejectionStage { none, service_plan, core_plan, prepublish, tick_ready, tick_deadline, publication };
constexpr const char* rejection_stage_name(RejectionStage stage) noexcept {
    switch (stage) {
    case RejectionStage::none: return "none";
    case RejectionStage::service_plan: return "service_plan";
    case RejectionStage::core_plan: return "core_plan";
    case RejectionStage::prepublish: return "prepublish";
    case RejectionStage::tick_ready: return "tick_ready";
    case RejectionStage::tick_deadline: return "tick_deadline";
    case RejectionStage::publication: return "publication";
    }
    return "invalid";
}
enum class Reason {
    none, invalid_owner, invalid_source, invalid_button, rate_limited, busy, capacity, unavailable,
    unsupported_transport, source_unavailable, source_changed, actor_changed, focus_lost, menu_open,
    gameplay_inactive, interference, clock_unavailable, clock_regressed, deadline, cancelled,
    publication_unconfirmed, cleanup_pending, sequence_exhausted,
    client_not_ready, wrong_thread, client_tick_stale, actor_unavailable
};
constexpr bool valid_button(std::uint16_t button) noexcept {
    return button && !(button & (button - 1)) && !(button & 0x0c00);
}
constexpr bool terminal(Status status) noexcept {
    return status == Status::released || status == Status::cancelled || status == Status::expired || status == Status::revoked;
}
constexpr const char* status_name(Status status) noexcept {
    switch (status) {
    case Status::queued: return "queued";
    case Status::warming: return "warming";
    case Status::pressing: return "pressing";
    case Status::releasing: return "releasing";
    case Status::released: return "released";
    case Status::cancelled: return "cancelled";
    case Status::expired: return "expired";
    case Status::revoked: return "revoked";
    }
    return "invalid";
}
constexpr const char* reason_name(Reason reason) noexcept {
    switch (reason) {
    case Reason::none: return "none";
    case Reason::invalid_owner: return "invalid_owner";
    case Reason::invalid_source: return "invalid_source";
    case Reason::invalid_button: return "invalid_button";
    case Reason::rate_limited: return "rate_limited";
    case Reason::busy: return "busy";
    case Reason::capacity: return "capacity";
    case Reason::unavailable: return "unavailable";
    case Reason::client_not_ready: return "client_not_ready";
    case Reason::wrong_thread: return "wrong_thread";
    case Reason::client_tick_stale: return "client_tick_stale";
    case Reason::actor_unavailable: return "actor_unavailable";
    case Reason::unsupported_transport: return "unsupported_transport";
    case Reason::source_unavailable: return "source_unavailable";
    case Reason::source_changed: return "source_changed";
    case Reason::actor_changed: return "actor_changed";
    case Reason::focus_lost: return "focus_lost";
    case Reason::menu_open: return "menu_open";
    case Reason::gameplay_inactive: return "gameplay_inactive";
    case Reason::interference: return "interference";
    case Reason::clock_unavailable: return "clock_unavailable";
    case Reason::clock_regressed: return "clock_regressed";
    case Reason::deadline: return "deadline";
    case Reason::cancelled: return "cancelled";
    case Reason::publication_unconfirmed: return "publication_unconfirmed";
    case Reason::cleanup_pending: return "cleanup_pending";
    case Reason::sequence_exhausted: return "sequence_exhausted";
    }
    return "invalid";
}
// A publication is an SDK output-buffer witness, not normal wrapper return or
// native consumption. An observed source epoch is not physical-device identity.
struct Receipt {
    Handle handle{};
    Status status{Status::queued};
    Reason reason{Reason::none};
    RejectionStage first_rejection_stage{RejectionStage::none};
    std::uint32_t first_rejection_mask{};
    std::uint32_t user{};
    std::uint16_t button{};
    std::uint64_t requested_ms{}, expires_ms{}, observed_ms{}, source_epoch{};
    std::uint64_t press_candidates{}, press_publications{}, neutral_publications{}, original_failures{}, contentions{};
    bool report_debt{}, claim_released{}, actor_retired{}, orphaned{}, quarantined{};
    bool original_result_known{};
    std::uint32_t original_result{};
};
}
