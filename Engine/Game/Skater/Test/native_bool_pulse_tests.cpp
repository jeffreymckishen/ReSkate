#include "Engine/Game/Skater/native_bool_pulse.h"
#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>

namespace n = dingosdk::skater_intent;
namespace {
unsigned checks{};
void require(bool condition, const char* why) {
    ++checks;
    if (!condition) { std::cerr << "native Bool pulse: " << why << '\n'; std::exit(1); }
}
struct Fixture {
    n::Pulse pulse;
    n::PulseKey key{0x1000, 0x4000000000000010ULL, 600, 10.0};
    std::uintptr_t property{0x2000};
    std::uint64_t started{1000}, now{1001};
    bool eligible{true}, cancelled{}, owner_changed{}, resolves{true}, qualified{true}, allowed{true};
    bool get_ok{true}, returns{true}, store{true}, throw_get{}, throw_set{}, throw_allowed{}, mutate_allowed{}, recurse{}, rearm_in_set{}, rearmed{true};
    unsigned qualify_calls{}, deny_qualification_at{}, mutate_on_get{}, fail_get_at{}, get_calls{}, allowed_calls{}, resolve_calls{};
    std::uint8_t value{};
    std::vector<std::uint8_t> writes;
    std::vector<std::uintptr_t> properties;
    Fixture() { require(pulse.rearm(false), "fresh generation is explicitly armed"); }
    void run() {
        pulse.dispatch(key, started, now, eligible, cancelled, owner_changed,
            [&](std::uintptr_t& out) { ++resolve_calls; out = property; return resolves; },
            [&](const n::PulseKey& captured, bool) {
                ++qualify_calls;
                return qualified && (!deny_qualification_at || qualify_calls != deny_qualification_at) && captured == key;
            },
            [&](const n::PulseKey& captured) {
                ++allowed_calls;
                if (throw_allowed) throw std::runtime_error("native Allowed unavailable");
                const bool result = allowed && captured == key;
                if (mutate_allowed) key.handle ^= std::uint64_t{1} << 48;
                return result;
            },
            [&](std::uintptr_t current, std::uintptr_t binding, std::uint8_t& out) {
                require(current == property && binding == key.binding, "get uses freshly resolved property/current callback binding");
                ++get_calls; properties.push_back(current); out = value;
                if (get_calls == mutate_on_get) key.time += .001;
                if (throw_get) throw std::runtime_error("read failed");
                return get_ok && get_calls != fail_get_at;
            },
            [&](std::uintptr_t current, std::uintptr_t binding, std::uint8_t next) {
                require(current == property && binding == key.binding, "set uses freshly resolved property/current callback binding");
                properties.push_back(current); writes.push_back(next); if (store) value = next;
                require(pulse.unresolved(), "cleanup duty precedes possible true or false setter entry");
                if (rearm_in_set) rearmed = pulse.rearm(true);
                if (recurse) run();
                if (throw_set) throw std::runtime_error("fault after possible store");
                return returns;
            });
    }
    void next() { ++key.serial; key.time += 1.0 / 60; now += 17; }
};
void qualified_pulse_and_cleanup() {
    Fixture f;
    f.allowed = false; f.run();
    require(f.writes.empty() && f.allowed_calls == 1, "fresh native Allowed=false never writes");
    f.next(); f.allowed = true; f.run();
    require(f.writes == std::vector<std::uint8_t>{1} && f.pulse.written.load() && f.pulse.pending(), "one qualified true is read back");
    require(f.pulse.true_serial.load() == f.key.serial && f.pulse.true_time.load() == f.key.time, "full true native clock retained");
    require(!f.pulse.rearm(true), "cancellation cannot discard a pending true");
    f.run(); require(f.writes.size() == 1, "same native clock cannot reset");
    f.property += 0x100; f.next(); f.now = 9000; f.cancelled = true; f.eligible = false; f.allowed = false; f.run();
    require(f.writes == std::vector<std::uint8_t>({1, 0}) && !f.pulse.unresolved() && f.pulse.reset_false.load(), "later qualified clear survives cancel/unload/start expiry/Allowed=false");
    require(f.allowed_calls == 2 && f.properties.back() == f.property, "cleanup neither reuses saved property nor queries Allowed");
    f.next(); f.run(); require(f.writes.size() == 2, "reset generation never repeats");
    require(!f.pulse.rearm(false) && f.pulse.rearm(true), "verified clear also needs terminal lifecycle before rearm");
}
void native_clear_and_preexisting_value() {
    Fixture native; native.run(); native.value = 0; native.next(); native.run();
    require(native.writes == std::vector<std::uint8_t>{1} && native.pulse.cleared_before_reset.load() && !native.pulse.unresolved(), "fresh false read avoids needless false setter without attributing its cause");
    Fixture prior; prior.value = 1; prior.run(); prior.next(); prior.run();
    require(prior.writes.empty() && prior.pulse.phase.load() == n::PulsePhase::preexisting_true && prior.allowed_calls == 0, "preexisting true is untouched and never becomes SDK cleanup");
    Fixture invalid; invalid.value = 2; invalid.run();
    require(invalid.writes.empty() && !invalid.pulse.prior_available.load(), "non-Bool typed getter fails closed");
    Fixture unreadable; unreadable.get_ok = false; unreadable.run();
    require(unreadable.writes.empty() && !unreadable.pulse.prior_available.load(), "unavailable prior is not assumed false");
}
void owner_and_native_clock_fences() {
    Fixture f; f.run(); const auto entered = f.key;
    for (unsigned lane = 0; lane < 7; ++lane) {
        f.key = entered; f.next();
        switch (lane) {
        case 0: f.key.binding += 8; break;
        case 1: f.key.handle ^= std::uint64_t{1} << 48; break;
        case 2: f.key.serial = entered.serial; break;
        case 3: f.key.time = entered.time; break;
        case 4: f.key.time = entered.time - .1; break;
        case 5: f.key.time = std::numeric_limits<double>::quiet_NaN(); break;
        case 6: f.key.handle = 0; break;
        }
        f.run(); require(f.writes.size() == 1 && f.pulse.cleanup_attempts.load() == 0, "different binding/full handle or invalid/nonlater clock cannot reset");
    }
    f.key = entered; f.next(); f.owner_changed = true; f.run();
    require(f.writes.size() == 1 && f.pulse.phase.load() == n::PulsePhase::owner_lost && f.pulse.unresolved(), "owner retirement is not false verification");
    require(!f.pulse.rearm(true), "owner loss cannot erase uncertain store");
    f.owner_changed = false; f.next(); f.run();
    require(f.writes.size() == 1, "lost owner never resumes on a replacement callback");
}
void all_native_call_boundaries_requalify() {
    // Baseline true path has six qualification edges through its final getter.
    Fixture baseline; baseline.run(); const auto edges = baseline.qualify_calls;
    require(edges >= 6, "baseline exercises complete read/write transaction fences");
    for (unsigned edge = 1; edge <= edges; ++edge) {
        Fixture f; f.deny_qualification_at = edge; f.run();
        require(!f.pulse.written.load(), "a failed transaction fence never publishes verified true");
        require(f.writes.size() <= 1, "qualification failure never replays true");
        if (!f.writes.empty()) require(f.pulse.unresolved(), "post-write qualification failure retains cleanup");
    }
    Fixture false_read; false_read.run(); false_read.value = 0; false_read.next();
    false_read.mutate_on_get = false_read.get_calls + 1; false_read.run();
    require(false_read.pulse.unresolved() && !false_read.pulse.reset_false.load(), "clock drift during natural-false read is not reset proof");
    Fixture true_read; true_read.mutate_on_get = 1; true_read.run();
    require(true_read.writes.empty(), "clock drift in prior getter refuses before true entry");
    Fixture allowed_drift; allowed_drift.mutate_allowed = true; allowed_drift.run();
    require(allowed_drift.writes.empty(), "full entity generation drift during native Allowed prevents true entry");
    Fixture allowed_fault; allowed_fault.throw_allowed = true; allowed_fault.run();
    require(allowed_fault.writes.empty() && allowed_fault.pulse.faulted.load(), "unavailable/throwing native Allowed never enters setter");
}
void uncertain_and_throwing_setters() {
    Fixture uncertain; uncertain.returns = false; uncertain.run(); uncertain.run();
    require(uncertain.writes.size() == 1 && uncertain.pulse.unresolved() && !uncertain.pulse.written.load(), "false return after possible true cannot retry or claim success");
    uncertain.returns = true; uncertain.next(); uncertain.run();
    require(!uncertain.pulse.unresolved() && uncertain.writes.size() == 2, "uncertain true is cleared through later qualified callback");
    Fixture throws; throws.throw_set = true; throws.run();
    require(throws.pulse.unresolved() && throws.pulse.faulted.load() && throws.writes.size() == 1, "exception after true retains duty and unlocks dispatcher");
    throws.throw_set = false; throws.next(); throws.run();
    require(!throws.pulse.unresolved(), "later callback can clean after throwing true setter");
    Fixture failed_clear; failed_clear.run(); failed_clear.next(); failed_clear.returns = false; failed_clear.run();
    require(failed_clear.value == 0 && failed_clear.pulse.unresolved(), "false-returning reset cannot claim verified cleanup on its call edge");
    failed_clear.next(); failed_clear.run();
    require(!failed_clear.pulse.unresolved() && failed_clear.writes.size() == 2, "next-clock qualified false resolves uncertain cleanup without repeating setter");
    Fixture read_throws; read_throws.throw_get = true; read_throws.run();
    require(read_throws.writes.empty() && read_throws.pulse.faulted.load(), "prewrite read exception never enters setter");
    Fixture readback; readback.fail_get_at = 2; readback.run();
    require(readback.writes.size() == 1 && !readback.pulse.written.load() && readback.pulse.unresolved(), "unavailable true readback retains duty without claiming written");
}
void cleanup_boundaries_cannot_publish_unverified_false() {
    Fixture baseline; baseline.run(); baseline.next();
    const auto before = baseline.qualify_calls; baseline.run();
    const auto edges = baseline.qualify_calls - before;
    require(edges >= 6, "cleanup baseline exercises resolve/get/set/readback fences");
    for (unsigned edge = 1; edge <= edges; ++edge) {
        Fixture f; f.run(); f.next();
        f.deny_qualification_at = f.qualify_calls + edge; f.run();
        require(f.pulse.unresolved() && !f.pulse.reset_false.load() && !f.pulse.rearm(true),
            "failed cleanup qualification cannot free an uncertain generation");
        require(f.writes.size() <= 2, "cleanup qualification failure never replays true");
        f.deny_qualification_at = 0; f.next(); f.run();
        require(!f.pulse.unresolved() && f.pulse.reset_false.load(), "only a later separately qualified cleanup resolves debt");
        require(f.writes == std::vector<std::uint8_t>({1, 0}), "possible false store is not repeated when later read already proves clear");
    }
}
void bounded_retry_and_reentrant_entry() {
    Fixture f; f.resolves = false;
    f.run(); f.run(); require(f.resolve_calls == 1, "one start preflight per native clock");
    for (unsigned i = 1; i < n::maximum_start_attempts; ++i) { f.next(); f.now = 1001; f.run(); }
    f.next(); f.now = 1001; f.run();
    require(f.resolve_calls == n::maximum_start_attempts && f.pulse.phase.load() == n::PulsePhase::start_exhausted, "start retries and counters have a hard bound");
    require(!f.pulse.unresolved() && f.pulse.rearm(true), "no-entry exhaustion may rearm after terminal lifecycle");
    Fixture cleanup; cleanup.run(); cleanup.resolves = false;
    for (unsigned i = 0; i < n::maximum_cleanup_attempts; ++i) { cleanup.next(); cleanup.run(); }
    const auto calls = cleanup.resolve_calls; cleanup.next(); cleanup.run();
    require(cleanup.resolve_calls == calls && cleanup.pulse.phase.load() == n::PulsePhase::cleanup_exhausted, "cleanup retries stop at fixed bound");
    require(cleanup.pulse.unresolved() && !cleanup.pulse.rearm(true), "exhausted cleanup retains native uncertainty rather than rearming");
    Fixture recursive; recursive.recurse = true; recursive.rearm_in_set = true; recursive.run();
    require(recursive.writes.size() == 1 && !recursive.rearmed && recursive.pulse.generation.load() == 1, "nested dispatch/rearm cannot replace in-flight generation");
    recursive.next(); recursive.run();
    require(recursive.writes.size() == 2 && recursive.pulse.reset_calls.load() == 1, "recursive cleanup remains single-entry");
    Fixture busy; busy.pulse.busy.test_and_set(); busy.run(); busy.pulse.busy.clear();
    require(!busy.resolve_calls && busy.writes.empty(), "busy dispatcher skips all native work without waiting");
}
void admission_and_generation_edges() {
    for (unsigned reason = 0; reason < 5; ++reason) {
        Fixture f;
        switch (reason) {
        case 0: f.eligible = false; break;
        case 1: f.cancelled = true; break;
        case 2: f.now = 999; break;
        case 3: f.now = 1250; break;
        case 4: f.key.serial = 0; break;
        }
        f.run(); require(f.resolve_calls == 0 && f.writes.empty(), "invalid/expired/cancelled admission refuses before native reads");
    }
    n::Pulse unarmed; unsigned calls{};
    unarmed.dispatch({1, 2, 3, 4}, 100, 100, true, false, false,
        [&](std::uintptr_t&) { ++calls; return false; }, [](auto, bool) { return true; },
        [](auto) { return true; }, [](auto, auto, auto&) { return true; }, [](auto, auto, auto) { return true; });
    require(calls == 0, "fresh object cannot dispatch without explicit generation");
    Fixture exhausted; exhausted.pulse.generation.store(std::numeric_limits<std::uint64_t>::max());
    require(!exhausted.pulse.rearm(true), "generation never wraps");
}
}
int main() {
    qualified_pulse_and_cleanup(); native_clear_and_preexisting_value(); owner_and_native_clock_fences();
    all_native_call_boundaries_requalify(); uncertain_and_throwing_setters(); cleanup_boundaries_cannot_publish_unverified_false();
    bounded_retry_and_reentrant_entry(); admission_and_generation_edges();
    std::cout << "native Bool pulse: " << checks << " checks passed\n";
}
