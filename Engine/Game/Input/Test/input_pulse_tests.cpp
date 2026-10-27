#include "Engine/Game/Input/input_pulse.h"
#include <cstdlib>
#include <iostream>

namespace t = dingosdk::input_pulse;
namespace {
unsigned checks{};
const char* scenario = "";
constexpr t::Key key{7, 1, 9, 11, 0};
// The left stick just outside its rest radius: the smallest physical activity.
constexpr std::int16_t past_rest = static_cast<std::int16_t>(t::left_stick_rest + 1);

void check(bool value, const char* expression, const char* test, int line) {
    ++checks;
    if (!value) {
        std::cerr << "input pulse: " << test << ':' << line << " [" << scenario << "] " << expression << '\n';
        std::exit(1);
    }
}
#define CHECK(value) check((value), #value, __func__, __LINE__)

// Constructed readiness facts exercise the policy, not real game/source qualification.
t::Input input(std::uint64_t ms) {
    t::Input in;
    in.key = key;
    in.now_ms = in.source_observed_ms = in.clock_observed_ms = ms;
    in.serial = ms;
    in.seconds = static_cast<double>(ms) / 1000;
    in.has_output = in.outer_game_poll = in.source_fresh = in.actor_current = true;
    in.focused = in.gameplay = in.menu_closed = in.interference_clear = true;
    return in;
}
t::Output apply(t::Pulse& pulse, const t::Input& in, bool published = true) {
    const auto out = pulse.poll(pulse.ticket(), in);
    (void)pulse.confirm(out, published);
    return out;
}
t::Output poll(t::Pulse& pulse, std::uint64_t ms) { return apply(pulse, input(ms)); }
// This input deliberately has no actor or native clock observation. Only the
// trusted service's separate, precise reason classifier may choose to defer it.
t::Input deferred_input(std::uint64_t ms) {
    auto in = input(ms);
    in.actor_current = false;
    in.serial = in.clock_observed_ms = 0;
    in.seconds = 0;
    return in;
}
bool same_output(const t::Output& left, const t::Output& right) {
    return left.result == right.result && left.packet == right.packet && left.pad == right.pad &&
        left.press_candidate == right.press_candidate && left.release_candidate == right.release_candidate &&
        left.revision == right.revision && left.generation == right.generation;
}
void begin_partial_warmup(t::Pulse& pulse) {
    CHECK(pulse.request(key, 0x1000, 100));
    for (const auto time : {100u, 134u, 167u}) CHECK(!poll(pulse, time).press_candidate);
    CHECK(pulse.phase() == t::Phase::warming && !pulse.release_debt());
}
void begin_press(t::Pulse& pulse) {
    CHECK(pulse.request(key, 0x1000, 100));
    for (const auto time : {100u, 134u, 167u}) CHECK(!poll(pulse, time).press_candidate);
    CHECK(poll(pulse, 200).press_candidate);
    CHECK(pulse.release_debt());
}

// XInput's own dead zones decide rest: sticks inside a circle, triggers at or
// under the threshold, and no button at all.
static_assert(t::neutral({}) && t::neutral({0, 30, 30, 7849, 0, 0, -8689}));
static_assert(!t::neutral({0, 0, 0, 7850, 0, 0, 0}) && !t::neutral({0, 0, 31, 0, 0, 0, 0}));
void rest_thresholds_define_neutral() {
    CHECK(t::left_stick_rest == 7849 && t::right_stick_rest == 8689 && t::trigger_rest == 30);
    CHECK(t::neutral({0, 0, 0, 7849, 0, 0, 0}) && !t::neutral({0, 0, 0, 7850, 0, 0, 0}));
    CHECK(t::neutral({0, 0, 0, 0, -7849, 0, 0}) && !t::neutral({0, 0, 0, 0, -7850, 0, 0}));
    CHECK(t::neutral({0, 0, 0, 0, 0, 8689, 0}) && !t::neutral({0, 0, 0, 0, 0, 8690, 0}));
    CHECK(t::neutral({0, 0, 0, 0, 0, 0, -8689}) && !t::neutral({0, 0, 0, 0, 0, 0, -8690}));
    // Radial, not per-axis: each axis is inside the radius in both, but only
    // the first diagonal is inside the circle.
    CHECK(t::neutral({0, 0, 0, 5550, 5550, 0, 0}) && !t::neutral({0, 0, 0, 6000, 6000, 0, 0}));
    CHECK(t::neutral({0, 0, 0, 0, 0, 6143, -6143}) && !t::neutral({0, 0, 0, 0, 0, 6200, -6200}));
    // The left radius is the smaller one; it does not apply to the right stick.
    CHECK(!t::neutral({0, 0, 0, 8000, 0, 0, 0}) && t::neutral({0, 0, 0, 0, 0, 8000, 0}));
    CHECK(!t::neutral({0, 0, 0, -32768, -32768, 0, 0}) && !t::neutral({0, 0, 0, 0, 0, 32767, 32767}));
    CHECK(t::neutral({0, 30, 0, 0, 0, 0, 0}) && !t::neutral({0, 31, 0, 0, 0, 0, 0}));
    CHECK(t::neutral({0, 0, 30, 0, 0, 0, 0}) && !t::neutral({0, 0, 255, 0, 0, 0, 0}));
    for (unsigned bit = 0; bit < 16; ++bit)
        CHECK(!t::neutral({static_cast<std::uint16_t>(1u << bit), 0, 0, 0, 0, 0, 0}));
    CHECK(t::neutral({0, 30, 12, 7000, -3000, -8000, 2000}));
}

// A controller resting in the hands warms, presses and releases a pulse. Its
// noise passes through untouched beside the pressed button, and a stick just
// past its rest radius is still physical activity.
void resting_noise_pulses() {
    constexpr t::Pad resting{0, 30, 12, 7000, -3000, -8000, 2000};
    const auto noisy = [&](std::uint64_t ms) { auto in = input(ms); in.raw = in.returned = resting; return in; };
    t::Pulse pulse;
    CHECK(pulse.request(key, 0x1000, 100));
    for (const auto time : {100u, 134u, 167u}) CHECK(!apply(pulse, noisy(time)).press_candidate);
    const auto press = apply(pulse, noisy(200));
    CHECK((press.press_candidate && press.pad == t::Pad{0x1000, 30, 12, 7000, -3000, -8000, 2000}));
    CHECK(apply(pulse, noisy(300)).press_candidate && pulse.phase() == t::Phase::press);
    const auto release = apply(pulse, noisy(400));
    CHECK(!release.press_candidate && release.release_candidate && release.pad == resting);
    CHECK(pulse.phase() == t::Phase::complete && !pulse.release_debt());

    t::Pulse deferred;
    begin_partial_warmup(deferred);
    auto waiting = deferred_input(199);
    waiting.raw = waiting.returned = resting;
    t::Output out;
    CHECK(deferred.defer_warmup(deferred.ticket(), waiting, out) && out.pad == resting && !out.press_candidate);

    t::Pulse pushed;
    begin_press(pushed);
    auto active = noisy(250);
    active.raw.left_x = active.returned.left_x = past_rest;
    CHECK(!apply(pushed, active).press_candidate &&
        pushed.first_rejection_mask() == t::failure_bit(t::FailedCheck::physical_activity));
    active = noisy(260);
    active.raw.left_x = active.returned.left_x = past_rest;
    CHECK(!apply(pushed, active).release_candidate && pushed.release_debt());
    CHECK(apply(pushed, noisy(270)).release_candidate && !pushed.release_debt());
}

void neutral_warmup_and_bounded_press() {
    t::Pulse pulse;
    begin_press(pulse);
    CHECK(poll(pulse, 299).press_candidate);
    CHECK(poll(pulse, 399).press_candidate);
    const auto released = poll(pulse, 400);
    CHECK(released.release_candidate && !released.press_candidate);
    CHECK(pulse.phase() == t::Phase::complete && !pulse.release_debt());
    CHECK(pulse.acknowledge(key));
    CHECK(!pulse.request(key, 0x1000, 401));
    auto next = key;
    ++next.sequence;
    CHECK(pulse.request(next, 0x2000, 401));
    CHECK(!pulse.request(next, 0x1000, 402));
    for (const auto mask : {0u, 0x3u, 0x400u, 0x800u}) {
        t::Pulse invalid;
        CHECK(!invalid.request(key, static_cast<std::uint16_t>(mask), 100));
    }
    t::Pulse duplicate;
    CHECK(duplicate.request(key, 0x1000, 100));
    auto same = input(100);
    for (unsigned i = 0; i < 10; ++i) CHECK(!apply(duplicate, same).press_candidate);
    CHECK(duplicate.phase() == t::Phase::warming);
    same.now_ms = 201;
    CHECK(!apply(duplicate, same).press_candidate);
    CHECK(duplicate.phase() == t::Phase::revoked);
}

void repeated_native_sample_cannot_launch() {
    t::Pulse pulse;
    CHECK(pulse.request(key, 0x1000, 100));
    for (const auto time : {100u, 101u, 102u, 103u}) CHECK(!poll(pulse, time).press_candidate);
    auto duplicate = input(103);
    duplicate.now_ms = 200; // Age and poll gap are both 97 ms, so freshness alone admits it.
    CHECK(!apply(pulse, duplicate).press_candidate);
    CHECK(pulse.phase() == t::Phase::warming && !pulse.release_debt());
    CHECK(poll(pulse, 201).press_candidate);
}

void physical_inputs_are_preserved() {
    t::Pulse pulse;
    begin_press(pulse);
    auto in = input(250);
    in.raw = {0x2, 31, 47, 123, -456, 789, -1234};
    in.returned = in.raw;
    const auto out = apply(pulse, in);
    CHECK(!out.press_candidate && out.pad == in.raw && out.result == in.original_result && out.packet == in.original_packet);
    CHECK(pulse.phase() == t::Phase::releasing && pulse.release_debt());
    in = input(260);
    in.raw.buttons = 0x1000;
    in.returned = in.raw;
    const auto physical = apply(pulse, in);
    CHECK(!physical.press_candidate && physical.pad == in.raw);
    CHECK(pulse.phase() == t::Phase::releasing && pulse.release_debt());
    CHECK(!pulse.acknowledge(key));
    in = input(270);
    in.raw.left_x = past_rest;
    in.returned = in.raw;
    CHECK(!apply(pulse, in).release_candidate && pulse.release_debt());
    CHECK(poll(pulse, 280).release_candidate && pulse.phase() == t::Phase::revoked);

    t::Pulse target;
    begin_press(target);
    in = input(250);
    in.raw.buttons = 0x1000;
    in.returned = in.raw;
    const auto held = apply(target, in);
    CHECK(!held.press_candidate && held.pad.buttons == 0x1000 && target.release_debt());
    CHECK(poll(target, 280).release_candidate);
}

void admission_failures_revoke_without_rewriting() {
    constexpr const char* faults[] = {
        "disconnected", "no output", "unrelated inner poll", "stale source", "actor lost", "source epoch",
        "actor ticket", "focus lost", "gameplay lost", "menu open", "interference", "filtered pad",
        "nonfinite native clock", "unrelated slot", "foreign owner", "foreign sequence"
    };
    for (unsigned fault = 0; fault < 16; ++fault) {
        if (fault == 2 || fault == 13) continue;
        scenario = faults[fault];
        t::Pulse pulse;
        begin_press(pulse);
        auto in = input(250);
        switch (fault) {
        case 0: in.original_result = 1167; break;
        case 1: in.has_output = false; break;
        case 3: in.source_fresh = false; break;
        case 4: in.actor_current = false; break;
        case 5: ++in.key.source_epoch; break;
        case 6: ++in.key.actor_ticket; break;
        case 7: in.focused = false; break;
        case 8: in.gameplay = false; break;
        case 9: in.menu_closed = false; break;
        case 10: in.interference_clear = false; break;
        case 11: in.returned.buttons = 2; break;
        case 12: in.seconds = std::numeric_limits<double>::quiet_NaN(); break;
        case 14: ++in.key.owner; break;
        case 15: ++in.key.sequence; break;
        }
        const auto out = apply(pulse, in);
        CHECK(!out.press_candidate && out.pad == in.returned && out.result == in.original_result);
        if (pulse.release_debt()) {
            CHECK(!pulse.acknowledge(key));
            CHECK(poll(pulse, 280).release_candidate);
        }
        CHECK(pulse.phase() == t::Phase::revoked && !pulse.release_debt());
    }
    constexpr const char* clocks[] = {"wall rewind", "serial rewind", "native time rewind", "future observation", "serial without time"};
    for (unsigned fault = 0; fault < 5; ++fault) {
        scenario = clocks[fault];
        t::Pulse pulse;
        begin_press(pulse);
        auto in = input(250);
        if (fault == 0) in.now_ms = 199;
        if (fault == 1) in.serial = 199;
        if (fault == 2) in.seconds = .19;
        if (fault == 3) in.clock_observed_ms = 251;
        if (fault == 4) { in.serial = 201; in.seconds = .2; }
        const auto stopped = apply(pulse, in);
        CHECK(!stopped.press_candidate);
        if (fault == 0) {
            CHECK(pulse.release_debt());
            CHECK(poll(pulse, 280).release_candidate);
        } else {
            // Native-clock faults stop pressing, but do not invalidate this
            // separately fresh original neutral report from the same source.
            CHECK(stopped.release_candidate && !pulse.release_debt());
        }
        CHECK(pulse.phase() == t::Phase::revoked && !pulse.release_debt());
    }
    scenario = "";
    t::Pulse unloaded;
    begin_press(unloaded);
    const auto flight = unloaded.ticket();
    CHECK(unloaded.revoke(key));
    CHECK(!unloaded.poll(flight, input(250)).press_candidate && unloaded.release_debt());
    CHECK(poll(unloaded, 280).release_candidate);
    CHECK(unloaded.acknowledge(key));
    CHECK(!unloaded.poll(flight, input(281)).press_candidate);

    t::Pulse late;
    begin_press(late);
    CHECK(!poll(late, 450).press_candidate);
    CHECK(poll(late, 451).release_candidate || !late.release_debt());
    t::Pulse timeout;
    CHECK(timeout.request(key, 0x1000, 100));
    for (unsigned time = 100; time <= 1000; time += 50) {
        auto in = input(time);
        in.raw.left_x = past_rest;
        in.returned = in.raw;
        CHECK(!apply(timeout, in).press_candidate);
    }
    CHECK(!poll(timeout, 1100).press_candidate && timeout.phase() == t::Phase::revoked);

    t::Pulse stale;
    begin_press(stale);
    auto old = input(250);
    old.clock_observed_ms = 149;
    old.source_observed_ms = 149;
    CHECK(!apply(stale, old).press_candidate && stale.release_debt());
    auto failed = input(260);
    failed.original_result = 1167;
    failed.returned = {0xffff, 255, 255, 1, 2, 3, 4};
    const auto untouched = apply(stale, failed);
    CHECK(untouched.pad == failed.returned && untouched.result == 1167 && stale.release_debt());
    CHECK(poll(stale, 280).release_candidate);

    t::Pulse gap;
    begin_press(gap);
    auto jumped = input(250);
    jumped.seconds = .5;
    CHECK(apply(gap, jumped).release_candidate && gap.phase() == t::Phase::revoked && !gap.release_debt());
    t::Pulse routed;
    begin_press(routed);
    auto unrelated = input(250);
    unrelated.key.source = 1;
    CHECK(!apply(routed, unrelated).press_candidate && routed.phase() == t::Phase::press);
    unrelated = input(260);
    unrelated.outer_game_poll = false;
    CHECK(!apply(routed, unrelated).press_candidate && routed.phase() == t::Phase::press);
    CHECK(poll(routed, 280).press_candidate);
}

void neutral_cleanup_does_not_reuse_native_actor_authority() {
    t::Pulse pulse;
    begin_press(pulse);
    auto lost_actor = input(250);
    lost_actor.actor_current = false;
    lost_actor.serial = lost_actor.clock_observed_ms = 0;
    lost_actor.seconds = std::numeric_limits<double>::quiet_NaN();
    const auto release = apply(pulse, lost_actor);
    CHECK(!release.press_candidate && release.release_candidate && release.pad == lost_actor.raw);
    CHECK(pulse.phase() == t::Phase::revoked && !pulse.release_debt());

    for (unsigned fault = 0; fault < 7; ++fault) {
        t::Pulse guarded;
        begin_press(guarded);
        CHECK(guarded.revoke(key));
        auto cleanup = input(250);
        cleanup.actor_current = false;
        cleanup.serial = cleanup.clock_observed_ms = 0;
        switch (fault) {
        case 0: ++cleanup.key.source_epoch; break;
        case 1: cleanup.original_result = 1167; break;
        case 2: cleanup.source_observed_ms = 149; break;
        case 3: cleanup.source_observed_ms = 251; break;
        case 4: cleanup.now_ms = 199; break;
        case 5: cleanup.returned.buttons = 2; break;
        case 6: cleanup.interference_clear = false; break;
        }
        CHECK(!apply(guarded, cleanup).release_candidate && guarded.release_debt());
        cleanup = input(280);
        cleanup.actor_current = false;
        cleanup.serial = cleanup.clock_observed_ms = 0;
        CHECK(apply(guarded, cleanup).release_candidate && !guarded.release_debt());
    }
}

void packet_domain_survives_full_lifecycle() {
    t::PacketContinuity packets;
    t::Pad raw, pressed;
    pressed.buttons = 0x1000;
    CHECK(packets.translate(1, 0, 7, raw, raw, false) == 7);
    CHECK(packets.translate(1, 1, 7, raw, pressed, true) == 8);
    CHECK(packets.translate(1, 1, 7, raw, pressed, false) == 8);
    CHECK(packets.translate(1, 2, 7, raw, raw, false) == 9);
    CHECK(packets.translate(1, 3, 7, raw, raw, false) == 10);
    CHECK(packets.translate(1, 3, 10, raw, raw, false) == 11);
    CHECK(packets.translate(2, 3, 10, raw, raw, false) == 12);
    raw.right_y = 1;
    CHECK(packets.translate(2, 3, 10, raw, raw, false) == 13);
    t::PacketContinuity wrap;
    CHECK(wrap.translate(1, 0, UINT32_MAX, t::Pad{}, t::Pad{}, false) == UINT32_MAX);
    CHECK(wrap.translate(1, 1, UINT32_MAX, t::Pad{}, pressed, true) == 0);
    CHECK(wrap.translate(1, 2, 0, t::Pad{}, t::Pad{}, false) == 1);
    raw = pressed;
    CHECK(wrap.translate(1, 2, 0, raw, pressed, false) == 2);

    t::Pulse pulse;
    t::PacketContinuity shared;
    CHECK(pulse.request(key, 0x1000, 100));
    const auto publish = [&](std::uint64_t ms) {
        auto in = input(ms);
        in.original_packet = 17;
        const auto out = apply(pulse, in);
        return shared.translate(key.source_epoch, out.revision, in.original_packet, in.raw, out.pad, out.press_candidate);
    };
    CHECK(publish(100) == 17);
    CHECK(publish(134) == 17);
    CHECK(publish(167) == 17);
    CHECK(publish(200) == 18);
    CHECK(publish(300) == 18);
    CHECK(publish(400) == 19);
    CHECK(pulse.acknowledge(key));
    CHECK(publish(401) == 20);

    t::PacketContinuity filtered;
    constexpr std::uint32_t tag = 0x80000000;
    CHECK(filtered.translate(1, 0, 7, 7 ^ tag, t::Pad{}, t::Pad{}, false) == (7 ^ tag));
    CHECK(filtered.translate(1, 0, 7, 7, t::Pad{}, t::Pad{}, false) == 7);
    CHECK(filtered.translate(1, 1, 7, 7, t::Pad{}, pressed, true) == 8);
    CHECK(filtered.translate(1, 1, 7, 7 ^ tag, t::Pad{}, pressed, false) == 9);
    CHECK(filtered.translate(1, 1, 7 ^ tag, 7 ^ tag, t::Pad{}, pressed, false) == 10);
    CHECK(filtered.translate(1, 2, 7 ^ tag, 7 ^ tag, t::Pad{}, t::Pad{}, false) == 11);
}

void publication_confirmation_and_counter_exhaustion() {
    t::Pulse pulse;
    begin_press(pulse);
    CHECK(poll(pulse, 300).press_candidate);
    const auto release = pulse.poll(pulse.ticket(), input(400));
    CHECK(release.release_candidate && pulse.release_debt() && pulse.phase() == t::Phase::releasing);
    CHECK(!pulse.confirm(release, false) && pulse.release_debt());
    CHECK(pulse.revoke(key));
    CHECK(!pulse.confirm(release, true) && pulse.release_debt());
    CHECK(poll(pulse, 401).release_candidate && !pulse.release_debt());
    CHECK(pulse.acknowledge(key));
    t::Pulse uncertain;
    CHECK(uncertain.request(key, 0x1000, 100));
    for (const auto time : {100u, 134u, 167u}) (void)poll(uncertain, time);
    CHECK(apply(uncertain, input(200), false).press_candidate);
    CHECK(uncertain.release_debt() && uncertain.phase() == t::Phase::releasing);
    CHECK(poll(uncertain, 250).release_candidate);

    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    t::Pulse exhausted(maximum, 0), revision_end(0, maximum), reserved(maximum - 3, maximum - 6);
    CHECK(!exhausted.request(key, 0x1000, 100));
    CHECK(!revision_end.request(key, 0x1000, 100));
    begin_press(reserved);
    CHECK(reserved.revoke(key));
    const auto token = reserved.ticket();
    const auto revision = reserved.revision();
    for (unsigned i = 0; i < 10; ++i) {
        CHECK(reserved.revoke(key) && reserved.ticket().generation == token.generation && reserved.revision() == revision);
    }
    CHECK(poll(reserved, 250).release_candidate);
    CHECK(reserved.acknowledge(key));
    auto next = key;
    ++next.sequence;
    CHECK(!reserved.request(next, 0x1000, 251));
    t::Pulse revision_reserved(0, maximum - 6);
    begin_press(revision_reserved);
    (void)poll(revision_reserved, 300);
    (void)poll(revision_reserved, 400);
    CHECK(revision_reserved.acknowledge(key));
    CHECK(!revision_reserved.request(next, 0x1000, 401));
}

void first_rejection_records_checks_once() {
    using Check = t::FailedCheck;
    constexpr Check facts[] = {
        Check::original_result, Check::output, Check::source_fresh, Check::transport_result,
        Check::interference, Check::key, Check::raw_equality, Check::source_clock,
        Check::native_clock, Check::native_continuity, Check::actor, Check::focus,
        Check::gameplay, Check::menu, Check::native_gap, Check::poll_gap, Check::physical_activity
    };
    for (const auto fact : facts) {
        t::Pulse pulse;
        begin_press(pulse);
        CHECK(pulse.first_rejection_mask() == 0);
        auto in = input(250);
        switch (fact) {
        case Check::original_result: in.original_result = 1167; break;
        case Check::output: in.has_output = false; break;
        case Check::source_fresh: in.source_fresh = false; break;
        case Check::transport_result: in.transport_matches = false; break;
        case Check::interference: in.interference_clear = false; break;
        case Check::key: ++in.key.owner; break;
        case Check::raw_equality: in.returned.buttons = 2; break;
        case Check::source_clock: in.source_observed_ms = 149; break;
        case Check::native_clock: in.serial = 0; break;
        case Check::native_continuity: in.serial = 199; break;
        case Check::actor: in.actor_current = false; break;
        case Check::focus: in.focused = false; break;
        case Check::gameplay: in.gameplay = false; break;
        case Check::menu: in.menu_closed = false; break;
        case Check::native_gap: in.seconds = .5; break;
        case Check::poll_gap: in = input(351); break;
        case Check::physical_activity: in.raw.left_x = past_rest; in.returned = in.raw; break;
        case Check::deadline: break; // Its full lifetime is exercised separately below.
        }
        CHECK(!apply(pulse, in).press_candidate);
        CHECK(pulse.first_rejection_mask() == t::failure_bit(fact));
        // Cleanup failures and successful raw neutral publication cannot rewrite
        // the first fact set, nor can acknowledgement erase its historical value.
        auto later = input(in.now_ms + 1);
        later.focused = later.gameplay = false;
        (void)apply(pulse, later);
        CHECK(pulse.first_rejection_mask() == t::failure_bit(fact));
        if (pulse.release_debt()) CHECK(poll(pulse, in.now_ms + 2).release_candidate);
        CHECK(pulse.acknowledge(key));
        CHECK(pulse.first_rejection_mask() == t::failure_bit(fact));
        auto next = key; ++next.sequence;
        CHECK(pulse.request(next, 0x1000, in.now_ms + 3));
        CHECK(pulse.first_rejection_mask() == 0);
    }

    t::Pulse combined;
    begin_press(combined);
    auto bad = input(250);
    bad.focused = bad.menu_closed = bad.actor_current = false;
    (void)apply(combined, bad);
    const auto expected = t::failure_bit(Check::focus) | t::failure_bit(Check::menu) | t::failure_bit(Check::actor);
    CHECK(combined.first_rejection_mask() == expected);
    CHECK(poll(combined, 280).press_candidate == false && combined.first_rejection_mask() == expected);

    t::Pulse absent;
    begin_press(absent);
    bad = input(250); bad.serial = bad.clock_observed_ms = 0;
    bad.seconds = std::numeric_limits<double>::quiet_NaN();
    (void)apply(absent, bad);
    CHECK(absent.first_rejection_mask() == t::failure_bit(Check::native_clock));

    t::Pulse cancelled;
    begin_press(cancelled);
    const auto stale = cancelled.ticket();
    CHECK(cancelled.revoke(key));
    bad = input(250); bad.focused = false;
    CHECK(!cancelled.poll(stale, bad).press_candidate && cancelled.first_rejection_mask() == 0);
    (void)apply(cancelled, bad);
    CHECK(cancelled.first_rejection_mask() == 0);

    t::Pulse deadline;
    CHECK(deadline.request(key, 0x1000, 100));
    for (unsigned ms = 100; ms <= 1050; ms += 50) {
        auto waiting = input(ms); waiting.raw.left_x = past_rest; waiting.returned = waiting.raw;
        CHECK(!apply(deadline, waiting).press_candidate && deadline.first_rejection_mask() == 0);
    }
    (void)poll(deadline, 1100);
    CHECK(deadline.first_rejection_mask() == t::failure_bit(Check::deadline));
}

void deferred_warmup_requires_a_new_dwell() {
    t::Pulse pulse;
    begin_partial_warmup(pulse);
    const auto ticket = pulse.ticket();
    const auto revision = pulse.revision();
    auto waiting = deferred_input(199);
    waiting.original_packet = 37;
    t::Output out;
    CHECK(pulse.defer_warmup(ticket, waiting, out));
    CHECK(out.result == 0 && out.packet == 37 && out.pad == waiting.raw);
    CHECK(!out.press_candidate && !out.release_candidate);
    CHECK(out.generation == ticket.generation && out.revision == revision);
    CHECK(pulse.ticket().generation == ticket.generation && pulse.revision() == revision);
    CHECK(pulse.phase() == t::Phase::warming && !pulse.release_debt() && pulse.first_rejection_mask() == 0);
    for (const auto time : {200u, 234u, 267u}) CHECK(!poll(pulse, time).press_candidate);
    CHECK(poll(pulse, 300).press_candidate && pulse.release_debt());

    t::Pulse duplicate;
    begin_partial_warmup(duplicate);
    CHECK(duplicate.defer_warmup(duplicate.ticket(), deferred_input(199), out));
    auto old = input(200);
    old.serial = old.clock_observed_ms = 167;
    old.seconds = .167;
    CHECK(!apply(duplicate, old).press_candidate);
    // The duplicate cannot count or start a dwell inherited by the first new
    // sample. Four new samples span only 90 ms here, so a fifth is needed.
    for (const auto time : {230u, 260u, 290u, 320u}) CHECK(!poll(duplicate, time).press_candidate);
    CHECK(poll(duplicate, 330).press_candidate);
}

void deferred_warmup_keeps_the_original_deadline_and_counters() {
    t::Pulse pulse;
    begin_partial_warmup(pulse);
    const auto ticket = pulse.ticket();
    const auto revision = pulse.revision();
    t::Output out;
    for (std::uint64_t ms = 200; ms <= 1050; ms += 50) {
        CHECK(pulse.defer_warmup(ticket, deferred_input(ms), out));
        CHECK(pulse.ticket().generation == ticket.generation && pulse.revision() == revision);
        CHECK(!out.press_candidate && !out.release_candidate && !pulse.release_debt());
        CHECK(pulse.first_rejection_mask() == 0);
    }
    CHECK(pulse.defer_warmup(ticket, deferred_input(1099), out));
    const auto before = out;
    CHECK(!pulse.defer_warmup(ticket, deferred_input(1100), out));
    CHECK(same_output(out, before) && pulse.phase() == t::Phase::warming);
    CHECK(pulse.ticket().generation == ticket.generation && pulse.revision() == revision && pulse.first_rejection_mask() == 0);
    CHECK(!apply(pulse, deferred_input(1100)).press_candidate && pulse.phase() == t::Phase::revoked);
    CHECK((pulse.first_rejection_mask() & t::failure_bit(t::FailedCheck::deadline)) != 0);

    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    t::Pulse reserved(maximum - 3, maximum - 6);
    CHECK(reserved.request(key, 0x1000, 100));
    const auto reserved_ticket = reserved.ticket();
    const auto reserved_revision = reserved.revision();
    for (std::uint64_t ms = 100; ms <= 190; ms += 10) {
        CHECK(reserved.defer_warmup(reserved_ticket, deferred_input(ms), out));
        CHECK(reserved.ticket().generation == reserved_ticket.generation && reserved.revision() == reserved_revision);
    }
    for (const auto time : {200u, 234u, 267u}) CHECK(!poll(reserved, time).press_candidate);
    CHECK(poll(reserved, 300).press_candidate);
    CHECK(poll(reserved, 400).press_candidate);
    CHECK(poll(reserved, 500).release_candidate && reserved.acknowledge(key));
    auto next = key; ++next.sequence;
    CHECK(!reserved.request(next, 0x1000, 501));

    t::Pulse near_end;
    const auto start = maximum - 1200;
    CHECK(near_end.request(key, 0x1000, start));
    const auto near_ticket = near_end.ticket();
    for (std::uint64_t elapsed = 0; elapsed <= 900; elapsed += 100)
        CHECK(near_end.defer_warmup(near_ticket, deferred_input(start + elapsed), out));
    CHECK(near_end.defer_warmup(near_ticket, deferred_input(start + 999), out));
    CHECK(!near_end.defer_warmup(near_ticket, deferred_input(start + 1000), out));
    CHECK(!apply(near_end, deferred_input(start + 1000)).press_candidate && near_end.phase() == t::Phase::revoked);
}

void deferred_warmup_retains_native_high_water_marks() {
    constexpr const char* faults[] = {
        "native serial rewind after defer", "same serial changed time after defer", "new serial same time after defer",
        "native gap after defer", "future native observation after defer", "stale native observation after defer",
        "wall rewind after defer", "poll gap after defer"
    };
    for (unsigned fault = 0; fault < 8; ++fault) {
        scenario = faults[fault];
        t::Pulse pulse;
        begin_partial_warmup(pulse);
        t::Output out;
        CHECK(pulse.defer_warmup(pulse.ticket(), deferred_input(200), out));
        auto resumed = input(201);
        auto expected = t::FailedCheck::native_continuity;
        switch (fault) {
        case 0: resumed.serial = 166; resumed.seconds = .166; break;
        case 1: resumed.serial = 167; resumed.seconds = .168; break;
        case 2: resumed.serial = 168; resumed.seconds = .167; break;
        case 3: resumed.seconds = .5; expected = t::FailedCheck::native_gap; break;
        case 4: resumed.clock_observed_ms = 202; expected = t::FailedCheck::native_clock; break;
        case 5: resumed.clock_observed_ms = 100; expected = t::FailedCheck::native_clock; break;
        case 6: resumed = input(199); expected = t::FailedCheck::source_clock; break;
        case 7: resumed = input(301); expected = t::FailedCheck::poll_gap; break;
        }
        CHECK(!apply(pulse, resumed).press_candidate);
        CHECK(pulse.phase() == t::Phase::revoked && !pulse.release_debt());
        CHECK((pulse.first_rejection_mask() & t::failure_bit(expected)) != 0);
    }
    scenario = "";
}

void rejected_deferrals_do_not_mutate_or_hide_normal_rejection() {
    constexpr const char* faults[] = {
        "original failure", "no output", "inner poll", "stale source", "transport mismatch", "interference",
        "filtered returned pad", "physical button", "physical axis", "focus lost", "gameplay lost", "menu open",
        "foreign owner", "foreign sequence", "source epoch changed", "actor ticket changed", "unrelated slot",
        "missing source timestamp", "future source timestamp", "old source timestamp", "wall rewind", "poll gap",
        "original deadline", "actor unexpectedly known", "partial native serial", "partial native timestamp",
        "partial native time", "negative native time", "nonfinite native time", "infinite native time"
    };
    for (unsigned fault = 0; fault < 30; ++fault) {
        scenario = faults[fault];
        t::Pulse pulse;
        begin_partial_warmup(pulse);
        auto reference = pulse;
        auto fallback = pulse;
        auto in = deferred_input(199);
        switch (fault) {
        case 0: in.original_result = 1167; break;
        case 1: in.has_output = false; break;
        case 2: in.outer_game_poll = false; break;
        case 3: in.source_fresh = false; break;
        case 4: in.transport_matches = false; break;
        case 5: in.interference_clear = false; break;
        case 6: in.returned.buttons = 2; break;
        case 7: in.raw.buttons = 2; in.returned = in.raw; break;
        case 8: in.raw.left_x = past_rest; in.returned = in.raw; break;
        case 9: in.focused = false; break;
        case 10: in.gameplay = false; break;
        case 11: in.menu_closed = false; break;
        case 12: ++in.key.owner; break;
        case 13: ++in.key.sequence; break;
        case 14: ++in.key.source_epoch; break;
        case 15: ++in.key.actor_ticket; break;
        case 16: ++in.key.source; break;
        case 17: in.source_observed_ms = 0; break;
        case 18: in.source_observed_ms = 200; break;
        case 19: in.source_observed_ms = 98; break;
        case 20: in = deferred_input(166); break;
        case 21: in = deferred_input(268); break;
        case 22: in = deferred_input(1100); break;
        case 23: in.actor_current = true; break;
        case 24: in.serial = 199; break;
        case 25: in.clock_observed_ms = 199; break;
        case 26: in.seconds = .199; break;
        case 27: in.seconds = -.001; break;
        case 28: in.seconds = std::numeric_limits<double>::quiet_NaN(); break;
        case 29: in.seconds = std::numeric_limits<double>::infinity(); break;
        }
        t::Output out{123, 456, {3, 4, 5, 6, 7, 8, 9}, true, true, 789, 999};
        const auto sentinel = out;
        CHECK(!pulse.defer_warmup(pulse.ticket(), in, out));
        CHECK(same_output(out, sentinel));
        CHECK(pulse.phase() == reference.phase() && pulse.release_debt() == reference.release_debt());
        CHECK(pulse.ticket().generation == reference.ticket().generation && pulse.revision() == reference.revision());
        CHECK(pulse.first_rejection_mask() == 0);
        // Matching future decisions also expose a hidden warmup/high-water or
        // request-start mutation that the public status alone would not reveal.
        for (const auto time : {200u, 250u, 300u, 400u})
            CHECK(same_output(poll(pulse, time), poll(reference, time)));
        const auto ordinary = apply(fallback, in);
        CHECK(!ordinary.press_candidate);
        if (fault == 2 || fault == 16) {
            CHECK(fallback.phase() == t::Phase::warming && fallback.first_rejection_mask() == 0);
        } else {
            CHECK(fallback.phase() == t::Phase::revoked && fallback.first_rejection_mask() != 0);
        }
    }
    scenario = "";
}

void deferral_cannot_reenter_after_assertion_or_retirement() {
    const auto refused = [](t::Pulse& pulse, t::Ticket ticket, std::uint64_t ms) {
        t::Output out{1, 2, {}, true, true, 3, 4};
        const auto sentinel = out;
        const auto phase = pulse.phase();
        const auto generation = pulse.ticket().generation;
        const auto revision = pulse.revision();
        const auto mask = pulse.first_rejection_mask();
        const auto debt = pulse.release_debt();
        CHECK(!pulse.defer_warmup(ticket, deferred_input(ms), out));
        CHECK(same_output(out, sentinel) && pulse.phase() == phase && pulse.release_debt() == debt);
        CHECK(pulse.ticket().generation == generation && pulse.revision() == revision && pulse.first_rejection_mask() == mask);
    };
    t::Pulse idle;
    refused(idle, idle.ticket(), 100);
    const auto old = idle.ticket();
    begin_partial_warmup(idle);
    refused(idle, old, 199);
    t::Output out;
    CHECK(idle.defer_warmup(idle.ticket(), deferred_input(199), out));
    const auto cancelled = idle.ticket();
    CHECK(idle.revoke(key));
    refused(idle, cancelled, 200);
    refused(idle, idle.ticket(), 200);
    CHECK(idle.acknowledge(key));
    refused(idle, idle.ticket(), 201);

    t::Pulse asserted;
    begin_press(asserted);
    refused(asserted, asserted.ticket(), 250);
    CHECK(poll(asserted, 300).press_candidate);
    const auto release = asserted.poll(asserted.ticket(), input(400));
    CHECK(release.release_candidate && asserted.release_debt());
    refused(asserted, asserted.ticket(), 401);
    CHECK(asserted.confirm(release, true) && asserted.phase() == t::Phase::complete);
    refused(asserted, asserted.ticket(), 402);

    t::Pulse rejected;
    begin_partial_warmup(rejected);
    CHECK(!apply(rejected, deferred_input(199)).press_candidate && rejected.first_rejection_mask() != 0);
    refused(rejected, rejected.ticket(), 200);
    t::Pulse exhausted(std::numeric_limits<std::uint64_t>::max());
    CHECK(!exhausted.request(key, 0x1000, 100));
    refused(exhausted, exhausted.ticket(), 100);
}
}

int main() {
    rest_thresholds_define_neutral();
    resting_noise_pulses();
    neutral_warmup_and_bounded_press();
    repeated_native_sample_cannot_launch();
    physical_inputs_are_preserved();
    admission_failures_revoke_without_rewriting();
    neutral_cleanup_does_not_reuse_native_actor_authority();
    packet_domain_survives_full_lifecycle();
    publication_confirmation_and_counter_exhaustion();
    first_rejection_records_checks_once();
    deferred_warmup_requires_a_new_dwell();
    deferred_warmup_keeps_the_original_deadline_and_counters();
    deferred_warmup_retains_native_high_water_marks();
    rejected_deferrals_do_not_mutate_or_hide_normal_rejection();
    deferral_cannot_reenter_after_assertion_or_retirement();
    std::cout << "input_pulse checks=" << checks << " native_actions=0\n";
}
