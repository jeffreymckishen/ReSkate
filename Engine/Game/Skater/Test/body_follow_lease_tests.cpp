#include "Engine/Game/Skater/body_follow_lease.h"
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string_view>

namespace lease = dingosdk::body_follow_lease;
using Reason = dingosdk::skater_action::Reason;
using lease::Refusal;
using lease::Revocation;

namespace {
unsigned checks{}, cases{};
std::string_view current_case;

void check(bool condition, const char* why) {
    ++checks;
    if (!condition) {
        std::cerr << "body follow lease [" << current_case << "]: " << why << '\n';
        std::exit(1);
    }
}
void start(std::string_view name) {
    current_case = name;
    ++cases;
}

constexpr std::uint64_t reserved_at = 100000;

lease::Guard clear_guard(std::uint64_t now) {
    lease::Guard guard;
    guard.sampled_ms = now;
    guard.ready = guard.focused = guard.menu_closed = guard.pause_menu_known = guard.pause_menu_closed =
        guard.debug_control_clear = guard.actor_upright = true;
    return guard;
}
std::uint64_t clear_word(std::uint64_t now) { return lease::pack(clear_guard(now)); }

lease::State renewable_lease() {
    lease::State state;
    check(lease::start(state, reserved_at, true), "a renewable lease starts at an ordinary clock");
    return state;
}
// One renewal at `at`, with a proof one step newer than the last and current.
Refusal renew_at(lease::State& state, std::uint64_t at, std::uint64_t& remaining) {
    const auto proof = state.last_serial + 1;
    return lease::renew(state, at, proof, proof, clear_word(at), remaining);
}

void fixed_lease_is_the_original_three_seconds() {
    start("fixed_lease_is_the_original_three_seconds");
    lease::State state;
    check(lease::start(state, reserved_at, false), "a fixed lease starts");
    check(state.started == reserved_at && state.deadline == reserved_at + 3000 && state.ceiling == state.deadline,
        "a fixed lease ends at reservation + 3000 and its ceiling is its deadline");
    check(!state.renewable && !state.renewals && !state.last_serial && state.revocation == Revocation::none,
        "a fixed lease starts with no renewal state");
    std::uint64_t remaining = 99;
    check(lease::renew(state, reserved_at + 100, 1, 1, clear_word(reserved_at + 100), remaining) == Refusal::not_renewable &&
        !remaining, "a fixed lease refuses renewal and reports no time");
    check(state.deadline == reserved_at + 3000 && !state.renewals && !state.last_serial, "a refused renewal changes nothing");
    check(lease::precheck(state, 5) == Refusal::not_renewable, "the body-free checks refuse a fixed lease first");
    // Every guard fact false, and a never-sampled word, are ignored by a fixed lease.
    check(lease::check(state, reserved_at + 2999, 0) == Revocation::none, "a fixed lease ignores an unsampled guard");
    lease::Guard bad; bad.sampled_ms = reserved_at;
    check(lease::check(state, reserved_at + 2999, lease::pack(bad)) == Revocation::none, "a fixed lease ignores false facts");
    check(lease::check(state, reserved_at + 3000, clear_word(reserved_at + 3000)) == Revocation::deadline,
        "a fixed lease lapses at reservation + 3000 with deadline");
    check(lease::remaining(state, reserved_at + 1) == 2999 && lease::remaining(state, reserved_at + 3000) == 0,
        "remaining counts down to zero at the deadline");
}

void floor_extension_and_no_revival() {
    start("floor_extension_and_no_revival");
    auto state = renewable_lease();
    check(state.deadline == reserved_at + 3000 && state.ceiling == reserved_at + 120000, "the renewable floor and ceiling");
    std::uint64_t remaining{};
    check(renew_at(state, reserved_at + 100, remaining) == Refusal::none, "an early renewal is accepted");
    check(state.deadline == reserved_at + 3000 && state.renewals == 1 && remaining == 2900,
        "a renewal inside the floor leaves the deadline at reservation + 3000 and counts once");
    check(renew_at(state, reserved_at + 2800, remaining) == Refusal::none && state.deadline == reserved_at + 3300 &&
        remaining == 500, "a renewal at R+2800 moves the deadline to R+3300");
    check(lease::check(state, reserved_at + 3299, clear_word(reserved_at + 3299)) == Revocation::none,
        "nothing at R+3299 stops it");
    check(lease::check(state, reserved_at + 3300, clear_word(reserved_at + 3300)) == Revocation::deadline,
        "R+3300 stops it with deadline");
    // A renewal at or after the deadline cannot bring it back.
    const auto before = state;
    for (const auto at : {reserved_at + 3300, reserved_at + 3301, reserved_at + 60000}) {
        check(lease::renew(state, at, state.last_serial + 1, state.last_serial + 1, clear_word(at), remaining) ==
            Refusal::expired && !remaining, "a renewal at or after the deadline is expired");
        check(state.deadline == before.deadline && state.renewals == before.renewals &&
            state.last_serial == before.last_serial, "an expired renewal changes nothing");
        check(lease::check(state, at, clear_word(at)) == Revocation::deadline, "the lease stays revoked");
    }
}

void never_shorten_and_ceiling() {
    start("never_shorten_and_ceiling");
    auto state = renewable_lease();
    std::uint64_t remaining{};
    // Renew every 200 ms: the deadline only ever moves forward. The last one,
    // at R+119400, leaves the deadline at R+119900.
    std::uint64_t previous = state.deadline;
    for (std::uint64_t at = reserved_at + 2000; at <= reserved_at + 119400; at += 200) {
        check(renew_at(state, at, remaining) == Refusal::none, "a regular renewal is accepted");
        check(state.deadline >= previous && remaining == state.deadline - at, "the deadline never moves back");
        previous = state.deadline;
    }
    check(state.deadline == reserved_at + 119900, "the rolling window follows the last renewal");
    check(renew_at(state, reserved_at + 119800, remaining) == Refusal::none && state.deadline == reserved_at + 120000 &&
        remaining == 200, "a renewal at R+119800 caps the deadline at R+120000");
    const auto capped = state;
    check(renew_at(state, reserved_at + 119900, remaining) == Refusal::lifetime_exhausted && !remaining,
        "the next renewal is lifetime_exhausted");
    check(lease::precheck(state, state.last_serial + 1) == Refusal::lifetime_exhausted, "and so is the body-free check");
    check(state.deadline == capped.deadline && state.renewals == capped.renewals, "an exhausted renewal changes nothing");
    check(lease::check(state, reserved_at + 119999, clear_word(reserved_at + 119999)) == Revocation::none, "live to the end");
    check(lease::check(state, reserved_at + 120000, clear_word(reserved_at + 120000)) == Revocation::lifetime,
        "R+120000 stops it with lifetime");
    check(lease::renew(state, reserved_at + 120000, state.last_serial + 1, state.last_serial + 1,
        clear_word(reserved_at + 120000), remaining) == Refusal::expired, "past the ceiling a renewal is expired");
    // At the edge of the last window: a live lease constructed near the ceiling.
    auto near = renewable_lease();
    near.deadline = reserved_at + 119600;
    check(renew_at(near, reserved_at + 119500, remaining) == Refusal::none && near.deadline == reserved_at + 120000,
        "ceiling - now == 500 takes the ceiling");
    auto under = renewable_lease();
    under.deadline = reserved_at + 119600;
    check(renew_at(under, reserved_at + 119499, remaining) == Refusal::none && under.deadline == reserved_at + 119999,
        "ceiling - now > 500 takes now + 500");
}

void proof_serial_rules() {
    start("proof_serial_rules");
    auto state = renewable_lease();
    std::uint64_t remaining{};
    const auto at = reserved_at + 2900;
    const auto word = clear_word(at);
    check(lease::renew(state, at, 0, 10, word, remaining) == Refusal::sample_not_advanced,
        "serial zero never advances past the initial state");
    check(lease::renew(state, at, 10, 10, word, remaining) == Refusal::none && state.last_serial == 10, "a fresh proof renews");
    check(lease::renew(state, at, 10, 11, word, remaining) == Refusal::sample_not_advanced, "an equal serial does not advance");
    check(lease::renew(state, at, 9, 11, word, remaining) == Refusal::sample_not_advanced, "a lower serial does not advance");
    check(lease::precheck(state, 10) == Refusal::sample_not_advanced && lease::precheck(state, 11) == Refusal::none,
        "the body-free check applies the same rule");
    check(lease::renew(state, at, 12, 11, word, remaining) == Refusal::sample_stale, "a proof newer than the current step is stale");
    check(lease::renew(state, at, 11, 18, word, remaining) == Refusal::sample_stale, "a proof 7 steps behind is stale");
    check(state.renewals == 1 && state.last_serial == 10, "refused proofs change nothing");
    check(lease::renew(state, at, 12, 18, word, remaining) == Refusal::none && state.last_serial == 12,
        "a proof exactly 6 steps behind renews");
    check(lease::renew(state, at, 13, 13, word, remaining) == Refusal::none && state.renewals == 3,
        "a proof at the current step renews");
}

void guard_facts_and_order() {
    start("guard_facts_and_order");
    const auto now = reserved_at + 1000;
    auto state = renewable_lease();
    check(lease::guard_cause(clear_word(now), now) == Revocation::none, "a clear fresh guard admits");
    check(lease::guard_cause(0, now) == Revocation::client_not_ready, "a never-sampled word is client_not_ready");
    check(lease::guard_cause(clear_word(now - 249), now) == Revocation::none, "a 249 ms old guard is fresh");
    check(lease::guard_cause(clear_word(now - 250), now) == Revocation::client_not_ready, "a 250 ms old guard is stale");
    check(lease::guard_cause(clear_word(now + 16), now) == Revocation::none,
        "a guard sampled after the caller read its clock is fresh");
    struct Case { bool lease::Guard::*fact; Revocation cause; };
    const Case facts[] = {
        {&lease::Guard::ready, Revocation::client_not_ready},
        {&lease::Guard::pause_menu_known, Revocation::client_not_ready},
        {&lease::Guard::focused, Revocation::focus_lost},
        {&lease::Guard::menu_closed, Revocation::menu_open},
        {&lease::Guard::pause_menu_closed, Revocation::pause_menu_open},
        {&lease::Guard::debug_control_clear, Revocation::debug_control},
        {&lease::Guard::actor_upright, Revocation::actor_state},
    };
    for (const auto& item : facts) {
        auto guard = clear_guard(now);
        guard.*item.fact = false;
        check(lease::guard_cause(lease::pack(guard), now) == item.cause, "each false fact gives its own cause");
        check(lease::check(state, now, lease::pack(guard)) == item.cause, "the lease check reports that cause");
        std::uint64_t remaining{};
        auto copy = state;
        check(lease::renew(copy, now, 1, 1, lease::pack(guard), remaining) == lease::refusal(item.cause) &&
            copy.deadline == state.deadline && !copy.renewals, "a renewal under a revoking guard refuses and changes nothing");
    }
    // The documented order: ready first, then focus, interface, game menu, debug control, actor.
    lease::Guard all_false; all_false.sampled_ms = now;
    check(lease::guard_cause(lease::pack(all_false), now) == Revocation::client_not_ready, "readiness wins");
    auto guard = all_false; guard.ready = guard.pause_menu_known = true;
    check(lease::guard_cause(lease::pack(guard), now) == Revocation::focus_lost, "then focus");
    guard.focused = true;
    check(lease::guard_cause(lease::pack(guard), now) == Revocation::menu_open, "then the ReSkate interface");
    guard.menu_closed = true;
    check(lease::guard_cause(lease::pack(guard), now) == Revocation::pause_menu_open, "then the game's menu");
    guard.pause_menu_closed = true;
    check(lease::guard_cause(lease::pack(guard), now) == Revocation::debug_control, "then debug control");
    guard.debug_control_clear = true;
    check(lease::guard_cause(lease::pack(guard), now) == Revocation::actor_state, "then the actor");
    // The lease's own clock comes before the guard.
    check(lease::check(state, reserved_at + 3000, 0) == Revocation::deadline, "a lapse is reported before an unsampled guard");
}

void pack_round_trip() {
    start("pack_round_trip");
    for (unsigned bits = 0; bits < 128; ++bits) {
        lease::Guard guard;
        guard.sampled_ms = lease::guard_time_mask - bits;
        guard.ready = (bits & 1) != 0; guard.focused = (bits & 2) != 0; guard.menu_closed = (bits & 4) != 0;
        guard.pause_menu_known = (bits & 8) != 0; guard.pause_menu_closed = (bits & 16) != 0;
        guard.debug_control_clear = (bits & 32) != 0; guard.actor_upright = (bits & 64) != 0;
        const auto word = lease::pack(guard);
        const auto back = lease::unpack(word);
        check(word != 0 && (word >> 63) == 0, "a sampled guard packs to a nonzero word with bit 63 clear");
        check(back.sampled_ms == guard.sampled_ms && back.ready == guard.ready && back.focused == guard.focused &&
            back.menu_closed == guard.menu_closed && back.pause_menu_known == guard.pause_menu_known &&
            back.pause_menu_closed == guard.pause_menu_closed && back.debug_control_clear == guard.debug_control_clear &&
            back.actor_upright == guard.actor_upright, "every fact and the 56-bit time round-trip");
    }
    lease::Guard zero = clear_guard(0);
    check(lease::pack(zero) == 0, "a zero sample time packs to the never-sampled word");
    lease::Guard wide = clear_guard(lease::guard_time_mask + 1);
    check(lease::pack(wide) == 0, "a time past 56 bits packs to the never-sampled word");
    check(lease::guard_cause(lease::pack(wide), lease::guard_time_mask + 1) == Revocation::client_not_ready,
        "and so fails closed");
}

void actor_fact_matches_upright_on_foot() {
    start("actor_fact_matches_upright_on_foot");
    // The same truth table as a plugin's upright-on-foot reading of the watch:
    // valid, state 504, ragdoll known and false. Board state 100 is not on foot.
    for (unsigned bits = 0; bits < 8; ++bits)
        for (const std::uint32_t state : {0u, 100u, 103u, 300u, 504u}) {
            const bool valid = (bits & 1) != 0, known = (bits & 2) != 0, ragdoll = (bits & 4) != 0;
            const bool expected = valid && state == 504 && known && !ragdoll;
            check(lease::actor_upright(valid, state, known, ragdoll) == expected, "actor_upright truth table");
        }
}

void receipt_reasons_are_existing_names() {
    start("receipt_reasons_are_existing_names");
    const Revocation all[] = {Revocation::none, Revocation::deadline, Revocation::lifetime, Revocation::clock,
        Revocation::client_not_ready, Revocation::focus_lost, Revocation::menu_open, Revocation::pause_menu_open,
        Revocation::debug_control, Revocation::actor_state, Revocation::other};
    for (const auto cause : all) {
        const std::string_view name = dingosdk::skater_action::reason_name(lease::receipt_reason(cause));
        check(name != "invalid", "every revocation maps to an existing receipt reason");
        check(lease::revocation_name(cause) != nullptr, "every revocation has a name");
        check(lease::refusal_name(lease::refusal(cause)) != nullptr, "every revocation has a refusal name");
    }
    check(lease::receipt_reason(Revocation::deadline) == Reason::expired &&
        lease::receipt_reason(Revocation::lifetime) == Reason::expired &&
        lease::receipt_reason(Revocation::clock) == Reason::expired, "lapses read expired");
    check(lease::receipt_reason(Revocation::client_not_ready) == Reason::unavailable, "readiness reads unavailable");
    check(lease::receipt_reason(Revocation::focus_lost) == Reason::focus_changed &&
        lease::receipt_reason(Revocation::menu_open) == Reason::focus_changed &&
        lease::receipt_reason(Revocation::pause_menu_open) == Reason::focus_changed &&
        lease::receipt_reason(Revocation::debug_control) == Reason::focus_changed, "menus and debug read focus_changed");
    check(lease::receipt_reason(Revocation::actor_state) == Reason::unsupported_state, "the actor reads unsupported_state");
    check(lease::lapse(Revocation::deadline) && lease::lapse(Revocation::lifetime) && lease::lapse(Revocation::clock) &&
        !lease::lapse(Revocation::focus_lost) && !lease::lapse(Revocation::none), "only the clock's causes are lapses");
    const std::string_view names[] = {"none", "not_renewable", "not_following", "sample_not_advanced", "sample_stale",
        "body_unavailable", "busy", "lifetime_exhausted", "expired", "client_not_ready", "focus_lost", "menu_open",
        "pause_menu_open", "debug_control", "actor_state"};
    for (unsigned i = 0; i < 15; ++i)
        check(lease::refusal_name(static_cast<Refusal>(i)) == names[i], "refusal names are the documented strings");
    check(lease::refusal_name(static_cast<Refusal>(15)) == nullptr && lease::revocation_name(static_cast<Revocation>(11)) == nullptr,
        "unknown values have no name");
}

void clock_regression_and_overflow() {
    start("clock_regression_and_overflow");
    auto state = renewable_lease();
    check(lease::check(state, reserved_at - 1, clear_word(reserved_at - 1)) == Revocation::clock,
        "a clock before reservation revokes with clock");
    std::uint64_t remaining{};
    check(lease::renew(state, reserved_at - 1, 1, 1, clear_word(reserved_at - 1), remaining) == Refusal::expired,
        "and refuses renewal as expired");
    constexpr auto top = (std::numeric_limits<std::uint64_t>::max)();
    lease::State edge;
    check(lease::start(edge, top - 120000, true) && edge.ceiling == top, "the last representable renewable start");
    check(!lease::start(edge, top - 119999, true) && edge.deadline == 0 && edge.ceiling == 0 && !edge.renewable,
        "a renewable ceiling past the maximum refuses and leaves the state empty");
    check(lease::start(edge, top - 3000, false) && edge.deadline == top, "the last representable fixed start");
    check(!lease::start(edge, top - 2999, false), "a fixed deadline past the maximum refuses");
    check(lease::check(edge, 5, 0) == Revocation::deadline, "an empty state reads lapsed");
}

void one_per_step_for_two_minutes() {
    start("one_per_step_for_two_minutes");
    auto state = renewable_lease();
    std::uint64_t remaining{}, accepted{}, exhausted{};
    for (std::uint64_t step = 1; step <= 7200; ++step) {
        const auto at = reserved_at + step * 1000 / 60;
        const auto result = lease::renew(state, at, step, step, clear_word(at), remaining);
        if (result == Refusal::none) ++accepted;
        else if (result == Refusal::lifetime_exhausted) ++exhausted;
        else check(step == 7200 && result == Refusal::expired, "only the step at the ceiling lapses");
    }
    // Step 7170 lands at R+119500, the last window that reaches the ceiling.
    check(accepted == 7170 && state.renewals == 7170 && state.last_serial == 7170, "one renewal per step until the ceiling");
    check(exhausted == 29 && state.deadline == state.ceiling, "then lifetime_exhausted until the ceiling passes");
    check(lease::check(state, reserved_at + 120000, clear_word(reserved_at + 120000)) == Revocation::lifetime,
        "the lease ends at the ceiling");
}
} // namespace

int main() {
    fixed_lease_is_the_original_three_seconds();
    floor_extension_and_no_revival();
    never_shorten_and_ceiling();
    proof_serial_rules();
    guard_facts_and_order();
    pack_round_trip();
    actor_fact_matches_upright_on_foot();
    receipt_reasons_are_existing_names();
    clock_regression_and_overflow();
    one_per_step_for_two_minutes();
    std::cout << "body_follow_lease cases=" << cases << " checks=" << checks << '\n';
    return 0;
}
