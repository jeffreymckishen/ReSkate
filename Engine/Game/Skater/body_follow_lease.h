#pragma once
#include "native_action.h"
#include <cstdint>
#include <limits>

// The lease of one owned-body Follow, as pure policy: no game access, no clock
// and no lock. The native Service supplies its own clock, the client tick's
// packed guard word and the body serials, and applies every stop itself.
// A fixed lease is the original three seconds from reservation. A renewable
// lease starts the same way and moves forward only on proof that the plugin
// holds a newly issued sample of a body whose physics clock is stepping. A
// timer, a counter, an old sample or repeated publication never renews it,
// and a lapsed lease is never revived.
namespace dingosdk::body_follow_lease {
inline constexpr std::uint64_t base_ms = 3000;              // from reservation; the floor of a renewable lease
inline constexpr std::uint64_t renewal_ms = 500;            // from the native time of an accepted renewal
inline constexpr std::uint64_t maximum_lifetime_ms = 120000; // hard ceiling from reservation
inline constexpr std::uint64_t proof_steps = 6;             // 100 ms of 60 Hz body steps
inline constexpr std::uint64_t guard_age_ms = 250;          // the same window as World's client tick

// Why a lease ended. Only the cause of a receipt's first stop is kept; a stop
// from anywhere else (a level change, a body fault, an explicit stop) is other.
enum class Revocation : std::uint8_t {
    none, deadline, lifetime, clock, client_not_ready, focus_lost, menu_open, pause_menu_open,
    debug_control, actor_state, other
};
// Why a renewal was refused. The lease still bounds every refusal that does
// not stop the Follow, so a plugin may simply try again on a later tick.
enum class Refusal : std::uint8_t {
    none, not_renewable, not_following, sample_not_advanced, sample_stale, body_unavailable, busy,
    lifetime_exhausted, expired, client_not_ready, focus_lost, menu_open, pause_menu_open,
    debug_control, actor_state
};
constexpr const char* revocation_name(Revocation value) noexcept {
    switch (value) {
    case Revocation::none: return "none";
    case Revocation::deadline: return "deadline";
    case Revocation::lifetime: return "lifetime";
    case Revocation::clock: return "clock";
    case Revocation::client_not_ready: return "client_not_ready";
    case Revocation::focus_lost: return "focus_lost";
    case Revocation::menu_open: return "menu_open";
    case Revocation::pause_menu_open: return "pause_menu_open";
    case Revocation::debug_control: return "debug_control";
    case Revocation::actor_state: return "actor_state";
    case Revocation::other: return "other";
    }
    return nullptr;
}
constexpr const char* refusal_name(Refusal value) noexcept {
    switch (value) {
    case Refusal::none: return "none";
    case Refusal::not_renewable: return "not_renewable";
    case Refusal::not_following: return "not_following";
    case Refusal::sample_not_advanced: return "sample_not_advanced";
    case Refusal::sample_stale: return "sample_stale";
    case Refusal::body_unavailable: return "body_unavailable";
    case Refusal::busy: return "busy";
    case Refusal::lifetime_exhausted: return "lifetime_exhausted";
    case Refusal::expired: return "expired";
    case Refusal::client_not_ready: return "client_not_ready";
    case Refusal::focus_lost: return "focus_lost";
    case Refusal::menu_open: return "menu_open";
    case Refusal::pause_menu_open: return "pause_menu_open";
    case Refusal::debug_control: return "debug_control";
    case Refusal::actor_state: return "actor_state";
    }
    return nullptr;
}
// The lease's own clock: past the deadline, past the ceiling, or before reservation.
constexpr bool lapse(Revocation cause) noexcept {
    return cause == Revocation::deadline || cause == Revocation::lifetime || cause == Revocation::clock;
}
// A stop keeps to receipt reasons that existed before renewal, so a consumer
// that knows the original reason set reads a renewable Follow unchanged. The
// exact cause is the lease report's revocation. A menu reads as focus_changed.
constexpr skater_action::Reason receipt_reason(Revocation cause) noexcept {
    switch (cause) {
    case Revocation::none: return skater_action::Reason::none;
    case Revocation::deadline:
    case Revocation::lifetime:
    case Revocation::clock: return skater_action::Reason::expired;
    case Revocation::client_not_ready: return skater_action::Reason::unavailable;
    case Revocation::focus_lost:
    case Revocation::menu_open:
    case Revocation::pause_menu_open:
    case Revocation::debug_control: return skater_action::Reason::focus_changed;
    case Revocation::actor_state: return skater_action::Reason::unsupported_state;
    case Revocation::other: return skater_action::Reason::unavailable;
    }
    return skater_action::Reason::unavailable;
}
// The refusal a renewal reports when the lease check stops the Follow.
constexpr Refusal refusal(Revocation cause) noexcept {
    switch (cause) {
    case Revocation::none: return Refusal::none;
    case Revocation::deadline:
    case Revocation::lifetime:
    case Revocation::clock: return Refusal::expired;
    case Revocation::client_not_ready: return Refusal::client_not_ready;
    case Revocation::focus_lost: return Refusal::focus_lost;
    case Revocation::menu_open: return Refusal::menu_open;
    case Revocation::pause_menu_open: return Refusal::pause_menu_open;
    case Revocation::debug_control: return Refusal::debug_control;
    case Revocation::actor_state: return Refusal::actor_state;
    case Revocation::other: return Refusal::not_following;
    }
    return Refusal::not_following;
}

// Facts the client tick samples once per tick, for a renewable lease only.
// Each one can only revoke; none admits a Follow or authorizes an effect.
struct Guard {
    std::uint64_t sampled_ms{};   // native clock at sampling
    bool ready{};                 // client phase ready, not loading, no debug request in flight
    bool focused{};               // the foreground window belongs to the game
    bool menu_closed{};           // the ReSkate interface is closed
    bool pause_menu_known{};      // the game's own menu state was actually read
    bool pause_menu_closed{};     // and no game menu is up
    bool debug_control_clear{};   // no noclip and no free camera
    bool actor_upright{};         // the local actor is upright on foot
};
// One atomic word: bits 0..55 hold the sample time, bits 56..62 the facts.
// Zero means never sampled, and a time that does not fit also packs to zero.
inline constexpr std::uint64_t guard_time_mask = (std::uint64_t{1} << 56) - 1;
constexpr std::uint64_t pack(const Guard& guard) noexcept {
    if (!guard.sampled_ms || guard.sampled_ms > guard_time_mask) return 0;
    return guard.sampled_ms | (static_cast<std::uint64_t>(guard.ready) << 56) |
        (static_cast<std::uint64_t>(guard.focused) << 57) | (static_cast<std::uint64_t>(guard.menu_closed) << 58) |
        (static_cast<std::uint64_t>(guard.pause_menu_known) << 59) |
        (static_cast<std::uint64_t>(guard.pause_menu_closed) << 60) |
        (static_cast<std::uint64_t>(guard.debug_control_clear) << 61) |
        (static_cast<std::uint64_t>(guard.actor_upright) << 62);
}
constexpr Guard unpack(std::uint64_t word) noexcept {
    Guard guard;
    guard.sampled_ms = word & guard_time_mask;
    guard.ready = ((word >> 56) & 1) != 0;
    guard.focused = ((word >> 57) & 1) != 0;
    guard.menu_closed = ((word >> 58) & 1) != 0;
    guard.pause_menu_known = ((word >> 59) & 1) != 0;
    guard.pause_menu_closed = ((word >> 60) & 1) != 0;
    guard.debug_control_clear = ((word >> 61) & 1) != 0;
    guard.actor_upright = ((word >> 62) & 1) != 0;
    return guard;
}
// The same sampled reading a plugin gets from skater.telemetry's watch: known
// on-foot state 504 and a known ragdoll flag that is false. No lifetime stamp.
constexpr bool actor_upright(bool valid, std::uint32_t state, bool ragdoll_known, bool ragdoll) noexcept {
    return valid && state == 504 && ragdoll_known && !ragdoll;
}
// The first failing fact, in the input lease's order. A word sampled after the
// caller read its clock is fresh, not stale. Unknown menu state is not ready.
constexpr Revocation guard_cause(std::uint64_t word, std::uint64_t now) noexcept {
    const auto guard = unpack(word);
    if (!word || (now > guard.sampled_ms && now - guard.sampled_ms >= guard_age_ms) || !guard.ready ||
        !guard.pause_menu_known) return Revocation::client_not_ready;
    if (!guard.focused) return Revocation::focus_lost;
    if (!guard.menu_closed) return Revocation::menu_open;
    if (!guard.pause_menu_closed) return Revocation::pause_menu_open;
    if (!guard.debug_control_clear) return Revocation::debug_control;
    if (!guard.actor_upright) return Revocation::actor_state;
    return Revocation::none;
}

struct State {
    std::uint64_t started{}, deadline{}, ceiling{};
    std::uint64_t renewals{}, last_serial{}; // last_serial is the proof of the last accepted renewal
    bool renewable{};
    Revocation revocation{Revocation::none};  // latched by the Service at the receipt's first stop
};
// Refuses a clock so near its maximum that the ceiling could not be represented.
// A refusal leaves the state empty, so every later edge sees a lapsed lease.
constexpr bool start(State& state, std::uint64_t now, bool renewable) noexcept {
    state = {};
    const auto span = renewable ? maximum_lifetime_ms : base_ms;
    if (now > (std::numeric_limits<std::uint64_t>::max)() - span) return false;
    state.started = now;
    state.deadline = now + base_ms;
    state.ceiling = now + span; // a fixed lease's ceiling is its deadline
    state.renewable = renewable;
    return true;
}
constexpr Revocation expiry(const State& state, std::uint64_t now) noexcept {
    if (now < state.started) return Revocation::clock;
    if (now >= state.deadline)
        return state.renewable && state.deadline == state.ceiling ? Revocation::lifetime : Revocation::deadline;
    return Revocation::none;
}
// A fixed lease ignores the guard, so a Follow that did not opt in keeps the
// original revocation set.
constexpr Revocation check(const State& state, std::uint64_t now, std::uint64_t guard_word) noexcept {
    if (const auto lapsed = expiry(state, now); lapsed != Revocation::none) return lapsed;
    return state.renewable ? guard_cause(guard_word, now) : Revocation::none;
}
// The checks that need no body: a proof not newer than the last accepted one,
// or a deadline already at the ceiling, refuses before any World work.
constexpr Refusal precheck(const State& state, std::uint64_t proof_serial) noexcept {
    if (!state.renewable) return Refusal::not_renewable;
    if (proof_serial <= state.last_serial) return Refusal::sample_not_advanced;
    if (state.deadline >= state.ceiling) return Refusal::lifetime_exhausted;
    return Refusal::none;
}
// proof_serial is the body serial of the sample the plugin presented, already
// shown by World to be that body's latest issued sample; current_serial is the
// body's current physics step, observed under 100 ms ago. The deadline becomes
// max(deadline, min(now + renewal_ms, ceiling)) and is never shortened.
constexpr Refusal renew(State& state, std::uint64_t now, std::uint64_t proof_serial, std::uint64_t current_serial,
    std::uint64_t guard_word, std::uint64_t& remaining_ms) noexcept {
    remaining_ms = 0;
    if (!state.renewable) return Refusal::not_renewable;
    if (const auto cause = check(state, now, guard_word); cause != Revocation::none) return refusal(cause);
    if (const auto refused = precheck(state, proof_serial); refused != Refusal::none) return refused;
    if (proof_serial > current_serial || current_serial - proof_serial > proof_steps) return Refusal::sample_stale;
    // now < deadline <= ceiling here, so neither sum can overflow.
    const auto window = state.ceiling - now > renewal_ms ? now + renewal_ms : state.ceiling;
    if (window > state.deadline) state.deadline = window;
    state.last_serial = proof_serial;
    ++state.renewals;
    remaining_ms = state.deadline - now;
    return Refusal::none;
}
constexpr std::uint64_t remaining(const State& state, std::uint64_t now) noexcept {
    return now >= state.started && now < state.deadline ? state.deadline - now : 0;
}
} // namespace dingosdk::body_follow_lease
