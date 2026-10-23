#include "Engine/Game/Skater/native_recovery_policy.h"
#include <cstdlib>
#include <iostream>
#include <limits>

namespace r = dingosdk::skater_recovery;
namespace {
unsigned checks{};
void require(bool condition, const char* why) {
    ++checks;
    if (!condition) { std::cerr << "native recovery: " << why << '\n'; std::exit(1); }
}
const r::State standing{true, true, false, true, false, 504};
const r::NativeClock reset{100, 0};
void eligible_suffix(r::StandingTracker& tracker) {
    for (unsigned i = 0; i <= 120; ++i)
        (void)tracker.observe(standing, reset, {101 + i, 1 + static_cast<double>(i) / 60}, 1000 + i * 17);
    require(tracker.snapshot().eligible && !tracker.snapshot().frozen, "qualified two-second suffix is eligible but not yet completed");
}
void thresholds_are_independent_and_native_clock_based() {
    r::StandingTracker tracker(504);
    require(!tracker.freeze(), "no samples cannot complete");
    for (unsigned i = 0; i < 120; ++i)
        require(!tracker.observe(standing, reset, {101 + i, 1 + static_cast<double>(i) / 60}, 1000 + i * 17), "many samples cannot replace two simulated seconds");
    require(tracker.observe(standing, reset, {221, 3}, 3040), "two seconds and enough distinct clocks qualify");
    require(tracker.snapshot().samples == 121 && tracker.snapshot().seconds == 2 && tracker.snapshot().last.serial == 221,
        "threshold witness contains actual distinct samples and exact native interval");
    r::StandingTracker sparse(504);
    for (unsigned i = 0; i < 29; ++i)
        require(!sparse.observe(standing, reset, {101 + i, 1 + static_cast<double>(i) / 14}, 1000 + i * 80), "two-second interval alone cannot replace thirty samples");
    require(sparse.snapshot().samples == 29 && sparse.snapshot().seconds == 2, "sparse two-second witness retained without completion");
    require(sparse.observe(standing, reset, {130, 3.01}, 3300), "thirtieth later sample completes independent count threshold");
    const auto before = sparse.snapshot();
    require(sparse.observe(standing, reset, before.last, 99999) && sparse.snapshot() == before,
        "same serial/time duplicate neither increments count nor changes original observed timestamp");
}
void bad_predicates_and_incoherent_clocks_clear_candidates() {
    for (unsigned lane = 0; lane < 6; ++lane) {
        r::StandingTracker tracker(504);
        (void)tracker.observe(standing, reset, {101, 1}, 1000);
        auto bad = standing;
        switch (lane) {
        case 0: bad.known = false; break; case 1: bad.value = 100; break;
        case 2: bad.ragdoll_known = false; break; case 3: bad.ragdoll = true; break;
        case 4: bad.in_air_known = false; break; case 5: bad.in_air = true; break;
        }
        require(!tracker.observe(bad, reset, {102, 1.1}, 1100) && !tracker.snapshot().observed && !tracker.freeze(),
            "unknown/wrong-state/ragdoll/air observation clears the suffix");
        (void)tracker.observe(standing, reset, {103, 1.2}, 1200);
        require(tracker.snapshot().samples == 1, "later good sample starts a new suffix");
    }
    for (unsigned lane = 0; lane < 8; ++lane) {
        r::StandingTracker tracker(504);
        (void)tracker.observe(standing, reset, {110, 2}, 2000);
        r::NativeClock next{111, 2.1}; auto key = reset; std::uint64_t wall = 2100;
        switch (lane) {
        case 0: next.serial = 109; break;
        case 1: next.serial = 110; break;
        case 2: next.time = 2; break;
        case 3: next.time = 1.9; break;
        case 4: next.time = std::numeric_limits<double>::quiet_NaN(); break;
        case 5: next.serial = 0; break;
        case 6: key.serial = 99; break;
        case 7: wall = 1999; break;
        }
        require(!tracker.observe(standing, key, next, wall) && !tracker.snapshot().observed,
            "rewound/incoherent/nonfinite clock or changed reset proof rejects and clears");
    }
    r::StandingTracker pre_reset(504);
    require(!pre_reset.observe(standing, reset, {100, 1}, 1000), "same reset serial is not a later physical observation");
    require(!pre_reset.observe(standing, reset, {101, 0}, 1000), "later serial without later time is not post-reset");
    r::StandingTracker supplied_state(17); auto generic = standing; generic.value = 17;
    (void)supplied_state.observe(generic, reset, {101, 1}, 1000);
    require(supplied_state.snapshot().observed, "expected native state is supplied by caller, not hardcoded into generic tracker");
}
void gaps_and_freshness_do_not_invent_samples() {
    r::StandingTracker tracker(504);
    (void)tracker.observe(standing, reset, {101, 1}, 1000);
    (void)tracker.observe(standing, reset, {102, 1.25}, 1250);
    require(tracker.snapshot().samples == 2, "exact maximum gap is accepted");
    (void)tracker.observe(standing, reset, {103, 1.50001}, 1501);
    require(tracker.snapshot().samples == 1 && tracker.snapshot().first.serial == 103, "larger gap begins a new suffix rather than bridging it");
    const auto saved = tracker.snapshot();
    tracker.check_fresh(true, {104, 1.6});
    require(tracker.snapshot() == saved, "freshness alone does not observe a new state or increment samples");
    tracker.check_fresh(true, {105, 1.8});
    require(!tracker.snapshot().observed, "stale current clock clears incomplete suffix");
    for (unsigned lane = 0; lane < 5; ++lane) {
        r::StandingTracker current(504); (void)current.observe(standing, reset, {110, 2}, 2000);
        r::NativeClock clock{111, 2.1}; bool available = true;
        switch (lane) {
        case 0: available = false; break; case 1: clock.serial = 109; break;
        case 2: clock.serial = 110; break; case 3: clock.time = 2; break;
        case 4: clock.time = std::numeric_limits<double>::infinity(); break;
        }
        current.check_fresh(available, clock);
        require(!current.snapshot().observed && !current.freeze(), "unknown or incoherent freshness cannot complete");
    }
}
void only_explicit_completion_freezes_the_historical_witness() {
    r::StandingTracker candidate(504); eligible_suffix(candidate);
    candidate.unavailable();
    require(!candidate.snapshot().eligible && !candidate.freeze(), "bad observation before client completion publication removes candidate eligibility");
    eligible_suffix(candidate);
    candidate.check_fresh(true, {999, 8});
    require(!candidate.snapshot().eligible && !candidate.freeze(), "stale clock before terminal publication removes candidate eligibility");
    r::StandingTracker completed(504); eligible_suffix(completed);
    require(completed.freeze(), "client explicitly seals an eligible completion");
    const auto historical = completed.snapshot();
    require(historical.frozen && historical.state == standing && historical.observed_ms == 3040,
        "completion seals final state, wall timestamp, native clock, count and interval");
    auto unknown = standing; unknown.known = false;
    (void)completed.observe(unknown, {0, 0}, {999, 8}, 9000);
    completed.check_fresh(false, {0, std::numeric_limits<double>::quiet_NaN()});
    completed.unavailable();
    (void)completed.observe(standing, reset, {999, 8}, 9000);
    require(completed.snapshot() == historical && completed.freeze(), "later five-second/stale/unknown inputs never erase or retime completed proof");
}
}
int main() {
    thresholds_are_independent_and_native_clock_based();
    bad_predicates_and_incoherent_clocks_clear_candidates();
    gaps_and_freshness_do_not_invent_samples();
    only_explicit_completion_freezes_the_historical_witness();
    std::cout << "native recovery standing tracker: " << checks << " checks passed\n";
}
