#pragma once
#include <atomic>
#include <cmath>
#include <cstdint>
#include <limits>
#include <type_traits>

namespace dingosdk::skater_intent {
enum class PulsePhase : unsigned {
    armed, reset_pending, reset, preexisting_true, owner_lost, start_exhausted, cleanup_exhausted
};
enum class PulseStage : unsigned {
    idle, qualify, resolve, allowed, prior_get, prior_true, entry, readback,
    reset_verified, owner_lost, attempts_exhausted, callback_exception
};
struct PulseKey {
    std::uintptr_t binding{};
    std::uint64_t handle{}, serial{};
    double time{};
    bool operator==(const PulseKey&) const = default;
};
inline constexpr std::uint64_t pulse_start_ms = 250;
inline constexpr unsigned maximum_start_attempts = 64, maximum_cleanup_attempts = 64;
inline bool valid_clock(const PulseKey& key) noexcept {
    return key.binding && key.handle && key.serial && std::isfinite(key.time) && key.time >= 0;
}
inline bool later_clock(const PulseKey& before, const PulseKey& after) noexcept {
    return valid_clock(before) && valid_clock(after) && before.binding == after.binding &&
        before.handle == after.handle && after.serial > before.serial && after.time > before.time;
}
inline constexpr bool blocks_rearm(bool armed, bool lifecycle_terminal, bool unresolved) noexcept {
    return armed && (!lifecycle_terminal || unresolved);
}

// The adapter supplies a NEW current callback key for every dispatch. Its
// qualify(key,cleanup) freshly verifies the complete native owner, full entity
// handle, callback binding and exact native clock. This core never invokes a
// saved pointer or resolves an actor. It does not provide a native world lock.
// allowed(key) must measure the qualified native predicate; cleanup deliberately
// does not require the predicate, cancellation or the old start permission.
struct Pulse {
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free &&
        std::atomic<double>::is_always_lock_free, "Native pulse status requires lock-free native scalars.");
    std::atomic_flag busy = ATOMIC_FLAG_INIT;
    std::atomic<PulsePhase> phase{PulsePhase::armed};
    std::atomic<PulseStage> stage{PulseStage::idle};
    std::atomic<std::uintptr_t> binding{};
    std::atomic<std::uint64_t> handle{}, true_serial{}, reset_serial{}, true_ms{}, reset_ms{};
    std::atomic<double> true_time{}, reset_time{};
    std::atomic<std::uint64_t> getters{}, allowed_calls{}, true_calls{}, reset_calls{};
    std::atomic<std::uint64_t> preflight_serial{}, last_reset_attempt{}, generation{};
    std::atomic<double> preflight_time{}, last_reset_time{};
    std::atomic<unsigned> start_attempts{}, cleanup_attempts{};
    std::atomic<bool> prior_available{}, prior_false{}, true_returned{}, written{}, true_readback_available{},
        true_readback{}, reset_returned{}, reset_readback_available{}, reset_false{}, cleared_before_reset{}, faulted{};

    bool pending() const noexcept { return phase.load(std::memory_order_acquire) == PulsePhase::reset_pending; }
    // Owner loss and exhausted retries are unresolved too. Neither is rollback.
    bool unresolved() const noexcept {
        return true_calls.load(std::memory_order_acquire) != 0 && !reset_false.load(std::memory_order_acquire);
    }
    bool rearm(bool lifecycle_terminal) noexcept {
        if (busy.test_and_set(std::memory_order_acquire)) return false;
        struct Unlock { std::atomic_flag& flag; ~Unlock() { flag.clear(std::memory_order_release); } } unlock{busy};
        if (blocks_rearm(generation.load() != 0, lifecycle_terminal, unresolved()) ||
            generation.load() == std::numeric_limits<std::uint64_t>::max()) return false;
        binding.store(0); handle.store(0); true_serial.store(0); reset_serial.store(0);
        true_ms.store(0); reset_ms.store(0); true_time.store(0); reset_time.store(0);
        getters.store(0); allowed_calls.store(0); true_calls.store(0); reset_calls.store(0);
        preflight_serial.store(0); last_reset_attempt.store(0); preflight_time.store(0); last_reset_time.store(0);
        start_attempts.store(0); cleanup_attempts.store(0);
        prior_available.store(false); prior_false.store(false); true_returned.store(false); written.store(false);
        true_readback_available.store(false); true_readback.store(false); reset_returned.store(false);
        reset_readback_available.store(false); reset_false.store(false); cleared_before_reset.store(false); faulted.store(false);
        stage.store(PulseStage::idle); phase.store(PulsePhase::armed, std::memory_order_release);
        generation.fetch_add(1, std::memory_order_release); return true;
    }

    // All callbacks are synchronous and must be bounded by the adapter. A busy
    // invocation is skipped, never waited on. The true setter is entered at most
    // once, including a fault after a possible store. Every cleanup attempt needs
    // a later native clock; an exhausted obligation stays retained and busy at
    // the lifecycle layer instead of touching a replacement owner.
    template<class Resolve, class Qualify, class Allowed, class Get, class Set>
    void dispatch(PulseKey key, std::uint64_t started, std::uint64_t now,
        bool eligible, bool cancelled, bool owner_changed,
        Resolve&& resolve, Qualify&& qualify, Allowed&& allowed, Get&& get, Set&& set) noexcept {
        static_assert(std::is_same_v<std::invoke_result_t<Resolve&, std::uintptr_t&>, bool>,
            "Resolve must return an explicit success Bool.");
        static_assert(std::is_same_v<std::invoke_result_t<Qualify&, const PulseKey&, bool>, bool>,
            "Qualify must return known qualification, not an optional presence test.");
        static_assert(std::is_same_v<std::invoke_result_t<Allowed&, const PulseKey&>, bool>,
            "Allowed must return known native true, not an optional presence test.");
        static_assert(std::is_same_v<std::invoke_result_t<Get&, std::uintptr_t, std::uintptr_t, std::uint8_t&>, bool>,
            "Get must return an explicit typed-read success Bool.");
        static_assert(std::is_same_v<std::invoke_result_t<Set&, std::uintptr_t, std::uintptr_t, std::uint8_t>, bool>,
            "Set must return an explicit call-returned Bool.");
        if (busy.test_and_set(std::memory_order_acquire)) return;
        struct Unlock { std::atomic_flag& flag; ~Unlock() { flag.clear(std::memory_order_release); } } unlock{busy};
        if (!generation.load(std::memory_order_acquire)) return;
        const auto current = phase.load(std::memory_order_acquire);
        if (owner_changed) {
            stage.store(PulseStage::owner_lost); phase.store(PulsePhase::owner_lost, std::memory_order_release); return;
        }
        if (!valid_clock(key)) return;
        const bool cleanup = current == PulsePhase::reset_pending;
        if (cleanup) {
            const PulseKey entered{binding.load(), handle.load(), true_serial.load(), true_time.load()};
            if (!later_clock(entered, key) || now < true_ms.load()) return;
            const auto last = last_reset_attempt.load();
            if (last && (key.serial <= last || key.time <= last_reset_time.load())) return;
            if (cleanup_attempts.load() == maximum_cleanup_attempts) {
                stage.store(PulseStage::attempts_exhausted);
                phase.store(PulsePhase::cleanup_exhausted, std::memory_order_release); return;
            }
            last_reset_attempt.store(key.serial); last_reset_time.store(key.time);
            cleanup_attempts.fetch_add(1, std::memory_order_relaxed);
        } else {
            if (current != PulsePhase::armed || !eligible || cancelled || now < started || now - started >= pulse_start_ms) return;
            const auto last = preflight_serial.load();
            if (last && (key.serial <= last || key.time <= preflight_time.load())) return;
            if (start_attempts.load() == maximum_start_attempts) {
                stage.store(PulseStage::attempts_exhausted);
                phase.store(PulsePhase::start_exhausted, std::memory_order_release); return;
            }
            preflight_serial.store(key.serial); preflight_time.store(key.time);
            start_attempts.fetch_add(1, std::memory_order_relaxed);
        }
        try {
            const auto qualified = [&]() {
                stage.store(PulseStage::qualify); return qualify(key, cleanup);
            };
            std::uintptr_t property{};
            if (!qualified()) return;
            stage.store(PulseStage::resolve);
            if (!resolve(property) || !property || !qualified()) return;
            std::uint8_t prior{}; getters.fetch_add(1, std::memory_order_relaxed);
            stage.store(PulseStage::prior_get);
            if (!get(property, key.binding, prior) || prior > 1 || !qualified()) return;
            if (!cleanup) {
                prior_available.store(true); prior_false.store(prior == 0);
                if (prior) {
                    stage.store(PulseStage::prior_true);
                    phase.store(PulsePhase::preexisting_true, std::memory_order_release); return;
                }
                if (!qualified()) return;
                stage.store(PulseStage::allowed); allowed_calls.fetch_add(1, std::memory_order_relaxed);
                if (!allowed(key) || !qualified()) return;
            } else if (!prior) {
                reset_serial.store(key.serial); reset_time.store(key.time); reset_ms.store(now);
                cleared_before_reset.store(true); reset_readback_available.store(true); reset_false.store(true);
                stage.store(PulseStage::reset_verified);
                phase.store(PulsePhase::reset, std::memory_order_release); return;
            }
            if (!qualified()) return;
            stage.store(PulseStage::entry);
            if (!cleanup) {
                binding.store(key.binding); handle.store(key.handle); true_serial.store(key.serial);
                true_time.store(key.time); true_ms.store(now);
                // Publish duty before a setter that may store and then fault.
                true_calls.store(1, std::memory_order_release);
                phase.store(PulsePhase::reset_pending, std::memory_order_release);
            } else reset_calls.fetch_add(1, std::memory_order_relaxed);
            const bool returned = set(property, key.binding, cleanup ? std::uint8_t{0} : std::uint8_t{1});
            if (cleanup) reset_returned.store(returned); else true_returned.store(returned);
            if (!returned) faulted.store(true);
            if (!qualified()) return;
            std::uint8_t after{}; getters.fetch_add(1, std::memory_order_relaxed);
            stage.store(PulseStage::readback);
            const bool available = get(property, key.binding, after) && after <= 1;
            if (!qualified()) return;
            if (!cleanup) {
                true_readback_available.store(available); true_readback.store(available && after == 1);
                written.store(returned && available && after == 1);
            } else {
                reset_readback_available.store(available); reset_false.store(returned && available && after == 0);
                if (returned && available && after == 0) {
                    reset_serial.store(key.serial); reset_time.store(key.time); reset_ms.store(now);
                    stage.store(PulseStage::reset_verified);
                    phase.store(PulsePhase::reset, std::memory_order_release);
                }
            }
        } catch (...) {
            // Keep possible stores and their cleanup duty even if a callback
            // throws. No exception is permission to replay a true entry.
            faulted.store(true); stage.store(PulseStage::callback_exception);
        }
    }
};
} // namespace dingosdk::skater_intent
