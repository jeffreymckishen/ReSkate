#pragma once
#include "Engine/Game/Input/input_pulse.h"
#include <cstddef>
#include <cstdint>

// A selected observed XInput stream, not native actor or physical device ownership.
// No operation in this observation-only contract changes a game input report.
namespace dingosdk::input_lease {
using Pad = input_pulse::Pad;
inline constexpr std::size_t retained_capacity = 8;
inline constexpr std::uint64_t lifetime_ms = 250, maximum_age_ms = 100;
struct Handle {
    std::uint64_t sequence{};
    bool operator==(const Handle&) const = default;
};
enum class Status { warming, active, released, revoked, expired };
enum class Reason {
    none, unavailable, busy, invalid_owner, invalid_source, wrong_thread,
    client_not_ready, source_unavailable, source_changed, source_stale,
    context_changed, focus_lost, gameplay_inactive, menu_open, interference,
    deadline, stale_epoch, capacity, sequence_exhausted, cancelled
};
inline bool terminal(Status value) noexcept {
    return value == Status::released || value == Status::revoked || value == Status::expired;
}
inline const char* status_name(Status value) noexcept {
    switch (value) {
    case Status::warming: return "warming";
    case Status::active: return "active";
    case Status::released: return "released";
    case Status::revoked: return "revoked";
    case Status::expired: return "expired";
    }
    return "invalid";
}
inline const char* reason_name(Reason value) noexcept {
    switch (value) {
    case Reason::none: return "none";
    case Reason::unavailable: return "unavailable";
    case Reason::busy: return "busy";
    case Reason::invalid_owner: return "invalid_owner";
    case Reason::invalid_source: return "invalid_source";
    case Reason::wrong_thread: return "wrong_thread";
    case Reason::client_not_ready: return "client_not_ready";
    case Reason::source_unavailable: return "source_unavailable";
    case Reason::source_changed: return "source_changed";
    case Reason::source_stale: return "source_stale";
    case Reason::context_changed: return "context_changed";
    case Reason::focus_lost: return "focus_lost";
    case Reason::gameplay_inactive: return "gameplay_inactive";
    case Reason::menu_open: return "menu_open";
    case Reason::interference: return "interference";
    case Reason::deadline: return "deadline";
    case Reason::stale_epoch: return "stale_epoch";
    case Reason::capacity: return "capacity";
    case Reason::sequence_exhausted: return "sequence_exhausted";
    case Reason::cancelled: return "cancelled";
    }
    return "invalid";
}
struct Snapshot {
    Handle handle{};
    std::uint64_t source_epoch{}, observation_serial{}, observed_ms{}, context_generation{};
    std::uint32_t user{}, packet{};
    Pad pad{};
    bool operator==(const Snapshot&) const = default;
};
struct Receipt {
    Handle handle{};
    Status status{Status::warming};
    Reason reason{Reason::none};
    std::uint32_t user{};
    std::uint64_t requested_ms{}, expires_ms{}, observed_ms{}, source_epoch{}, context_generation{};
    std::uint64_t last_observation{}, renewals{};
    bool source_released{}, orphaned{};
    // A separate capture or its in-flight poll still reserves this source.
    // Capture receipts report the associated publication debt independently.
    bool capture_reserved{};
};
// Trusted native facts. Context is the observed client/readiness generation;
// it is deliberately not described as actor, body, world, or rider authority.
struct Guard {
    std::uint64_t now_ms{}, context_generation{};
    bool ready{}, focused{}, gameplay{}, menu_closed{}, interference_clear{};
};
struct Source {
    std::uint32_t user{}, packet{};
    std::uint64_t epoch{}, observation_serial{}, observed_ms{}, context_generation{};
    Pad pad{};
    bool connected{}, eligible{};
};
}
