#pragma once
#include "native_recovery.h"
#include <cmath>
#include <cstdint>
#include <limits>

namespace dingosdk::skater_recovery {
struct NativeClock {
    std::uint64_t serial{};
    double time{};
    bool operator==(const NativeClock&) const = default;
};
struct StandingSnapshot {
    bool observed{}, eligible{}, frozen{};
    unsigned samples{};
    double seconds{};
    NativeClock first{}, last{};
    State state{};
    std::uint64_t observed_ms{};
    bool operator==(const StandingSnapshot&) const = default;
};

// The adapter supplies a qualified state and clocks for one actor/world. It
// serializes access and independently proves callback/lifetime identity. This
// tracker counts observed samples, not unobserved intervening native steps.
class StandingTracker {
public:
    static constexpr double required_seconds = 2.0, maximum_gap = .25;
    static constexpr unsigned required_samples = 30;
    explicit StandingTracker(std::uint32_t expected_state) noexcept : expected_state_(expected_state) {}

    bool observe(const State& state, NativeClock reset, NativeClock current, std::uint64_t observed_ms) noexcept {
        if (value_.frozen) return value_.eligible;
        if (!valid(reset) || !valid(current) || current.serial <= reset.serial || current.time <= reset.time ||
            !state.known || state.value != expected_state_ || !state.ragdoll_known || state.ragdoll ||
            !state.in_air_known || state.in_air) { unavailable(); return false; }
        if (value_.observed) {
            if (reset != reset_) { unavailable(); return false; }
            if (current.serial == value_.last.serial) {
                if (current.time != value_.last.time) unavailable();
                return value_.eligible;
            }
            if (current.serial < value_.last.serial || current.time <= value_.last.time || observed_ms < value_.observed_ms) {
                unavailable(); return false;
            }
            if (current.time - value_.last.time > maximum_gap) unavailable();
        }
        if (!value_.observed) { reset_ = reset; value_.first = current; }
        value_.observed = true; value_.last = current; value_.state = state; value_.observed_ms = observed_ms;
        if (value_.samples != std::numeric_limits<unsigned>::max()) ++value_.samples;
        value_.seconds = current.time - value_.first.time;
        value_.eligible = value_.samples >= required_samples && value_.seconds >= required_seconds;
        return value_.eligible;
    }
    // Before terminal publication, any loss of qualified observation clears the
    // candidate suffix. A completed historical witness is never aged away.
    void unavailable() noexcept {
        if (value_.frozen) return;
        value_ = {}; reset_ = {};
    }
    void check_fresh(bool available, NativeClock current) noexcept {
        if (value_.frozen || !value_.observed) return;
        if (!available || !valid(current) || current.serial < value_.last.serial ||
            (current.serial == value_.last.serial && current.time != value_.last.time) ||
            (current.serial > value_.last.serial && current.time <= value_.last.time) ||
            current.time - value_.last.time > maximum_gap) unavailable();
    }
    // Reaching the thresholds is only a candidate. The client explicitly seals
    // it when publishing terminal completion, after its final fresh checks.
    bool freeze() noexcept {
        if (!value_.eligible) return false;
        value_.frozen = true; return true;
    }
    const StandingSnapshot& snapshot() const noexcept { return value_; }
private:
    static bool valid(NativeClock clock) noexcept {
        return clock.serial && std::isfinite(clock.time) && clock.time >= 0;
    }
    std::uint32_t expected_state_{};
    NativeClock reset_{};
    StandingSnapshot value_{};
};
} // namespace dingosdk::skater_recovery
