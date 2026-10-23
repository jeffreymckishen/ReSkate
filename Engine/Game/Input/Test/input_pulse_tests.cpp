#include "Engine/Game/Input/input_pulse.h"
#include <cstdlib>
#include <iostream>

namespace t = dingosdk::input_pulse;
namespace {
unsigned checks{};
const char* scenario = "";
constexpr t::Key key{7, 1, 9, 11, 0};

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
void begin_press(t::Pulse& pulse) {
    CHECK(pulse.request(key, 0x1000, 100));
    for (const auto time : {100u, 134u, 167u}) CHECK(!poll(pulse, time).press_candidate);
    CHECK(poll(pulse, 200).press_candidate);
    CHECK(pulse.release_debt());
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
    in.raw.left_x = 1;
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
        in.raw.left_x = 1;
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
}

int main() {
    neutral_warmup_and_bounded_press();
    repeated_native_sample_cannot_launch();
    physical_inputs_are_preserved();
    admission_failures_revoke_without_rewriting();
    neutral_cleanup_does_not_reuse_native_actor_authority();
    packet_domain_survives_full_lifecycle();
    publication_confirmation_and_counter_exhaustion();
    std::cout << "input_pulse checks=" << checks << " native_actions=0\n";
}
