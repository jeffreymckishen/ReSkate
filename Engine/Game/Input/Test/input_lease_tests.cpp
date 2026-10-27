#include "Engine/Game/Input/input_lease_policy.h"
#include "Engine/Game/Input/input_lease_capture_policy.h"
#include <array>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <string_view>

namespace lease = dingosdk::input_lease;
namespace capture = dingosdk::input_lease_capture;

namespace {
unsigned checks{}, cases{};
std::string_view current_case;

void check(bool condition, const char* why) {
    ++checks;
    if (!condition) {
        std::cerr << "input lease [" << current_case << "]: " << why << '\n';
        std::exit(1);
    }
}

void start(std::string_view name) {
    current_case = name;
    ++cases;
}

lease::Guard guard(std::uint64_t now = 1000) {
    return {now, 17, true, true, true, true, true};
}

lease::Source source(std::uint64_t now = 1000, std::uint64_t ordinal = 41,
    std::uint32_t user = 2) {
    lease::Source out;
    out.user = user;
    out.packet = 73;
    out.epoch = 91;
    out.observation_serial = ordinal;
    out.observed_ms = now;
    out.context_generation = 17;
    out.pad = {0x1000, 23, 45, -123, 456, 789, -987};
    out.connected = out.eligible = true;
    return out;
}

lease::Snapshot sentinel() {
    lease::Snapshot out;
    out.handle.sequence = 999;
    out.source_epoch = 888;
    out.observation_serial = 777;
    out.observed_ms = 666;
    out.context_generation = 555;
    out.user = 3;
    out.packet = 444;
    out.pad = {0xffff, 255, 254, -32768, 32767, 42, -42};
    return out;
}

bool same_receipt(const lease::Receipt& a, const lease::Receipt& b) {
    return a.handle == b.handle && a.status == b.status && a.reason == b.reason &&
        a.user == b.user && a.requested_ms == b.requested_ms && a.expires_ms == b.expires_ms &&
        a.observed_ms == b.observed_ms && a.source_epoch == b.source_epoch &&
        a.context_generation == b.context_generation && a.last_observation == b.last_observation &&
        a.renewals == b.renewals && a.source_released == b.source_released && a.orphaned == b.orphaned;
}

lease::Receipt state(const lease::Broker& broker, lease::Handle handle, std::uint64_t owner = 7) {
    lease::Receipt out;
    check(broker.state(owner, handle, out), "owned receipt exists");
    check(out.handle == handle, "receipt preserves opaque handle exactly");
    return out;
}

lease::Handle request(lease::Broker& broker, const lease::Source& sample,
    const lease::Guard& facts, std::uint64_t owner = 7) {
    lease::Handle handle{999};
    lease::Reason reason = lease::Reason::cancelled;
    check(broker.request(owner, sample.user, sample, facts, false, handle, reason), "valid source lease admitted");
    check(handle.sequence != 0 && handle.sequence != 999 && reason == lease::Reason::none,
        "successful admission returns exact handle and clears refusal reason");
    return handle;
}

lease::Snapshot read(lease::Broker& broker, lease::Handle handle, const lease::Guard& facts,
    std::uint64_t owner = 7) {
    auto out = sentinel();
    lease::Reason reason = lease::Reason::cancelled;
    check(broker.read(owner, handle, facts, out, reason), "fresh owner reads qualified sample");
    check(out.handle == handle && reason == lease::Reason::none, "sample belongs to exact opaque lease");
    return out;
}

struct Running {
    lease::Broker broker;
    lease::Guard facts{guard()};
    lease::Source sample{source()};
    lease::Handle handle;

    Running() : handle(request(broker, sample, facts)) {
        advance();
        check(state(broker, handle).status == lease::Status::active, "post-begin observation activates lease");
    }

    void advance(std::uint64_t milliseconds = 1) {
        const auto cookie = broker.active();
        facts.now_ms += milliseconds;
        sample.observed_ms = facts.now_ms;
        ++sample.observation_serial;
        broker.observe(cookie, sample, facts);
    }
};

void admission_and_warming() {
    start("admission and warming");
    lease::Broker broker;
    check(broker.active() == lease::Handle{} && broker.active_user() == 4, "empty broker has no selected slot");
    const auto sample = source();
    const auto facts = guard();
    const auto handle = request(broker, sample, facts);
    const auto receipt = state(broker, handle);
    check(receipt.status == lease::Status::warming && !receipt.source_released,
        "request reserves source without publishing a sample");
    check(receipt.requested_ms == facts.now_ms && receipt.expires_ms == facts.now_ms + lease::lifetime_ms,
        "initial deadline is bounded from admitted time");
    check(broker.active() == handle && broker.active_user() == sample.user,
        "warming lease owns only selected observed source");
    auto out = sentinel();
    const auto before = out;
    lease::Reason reason{};
    check(!broker.read(7, handle, facts, out, reason) && out == before,
        "request-time baseline cannot masquerade as post-begin input");
    check(!broker.acknowledge(7, handle), "live lease cannot be acknowledged away");
    broker.observe(handle, sample, facts);
    check(state(broker, handle).status == lease::Status::warming,
        "same request-time ordinal does not activate");
}

void request_refusals() {
    start("admission refusals preserve output");
    const auto attempt = [](std::uint64_t owner, std::uint32_t user, lease::Source sample,
        lease::Guard facts, bool pulse_busy, lease::Reason expected) {
        lease::Broker broker;
        lease::Handle out{0x12345678};
        lease::Reason reason{};
        check(!broker.request(owner, user, sample, facts, pulse_busy, out, reason), "invalid admission refused");
        check(out.sequence == 0x12345678 && reason == expected, "refusal preserves caller handle and identifies reason");
        check(broker.active() == lease::Handle{} && broker.active_user() == 4, "refusal creates no live lease");
    };
    attempt(0, 2, source(), guard(), false, lease::Reason::invalid_owner);
    attempt(7, 4, source(), guard(), false, lease::Reason::invalid_source);
    attempt(7, 2, source(), guard(), true, lease::Reason::busy);
    auto sample = source(); sample.user = 1;
    attempt(7, 2, sample, guard(), false, lease::Reason::invalid_source);
    sample = source(); sample.connected = false;
    attempt(7, 2, sample, guard(), false, lease::Reason::source_unavailable);
    sample = source(); sample.eligible = false;
    attempt(7, 2, sample, guard(), false, lease::Reason::source_unavailable);
    sample = source(); sample.epoch = 0;
    attempt(7, 2, sample, guard(), false, lease::Reason::invalid_source);
    sample = source(); sample.observation_serial = 0;
    attempt(7, 2, sample, guard(), false, lease::Reason::invalid_source);
    sample = source(); sample.observed_ms = 0;
    attempt(7, 2, sample, guard(), false, lease::Reason::invalid_source);
    sample = source(); sample.observed_ms = 1001;
    attempt(7, 2, sample, guard(), false, lease::Reason::stale_epoch);
    sample = source(); sample.observed_ms = 899;
    attempt(7, 2, sample, guard(), false, lease::Reason::source_stale);
    sample = source(); sample.context_generation = 18;
    attempt(7, 2, sample, guard(), false, lease::Reason::context_changed);
    auto facts = guard(); facts.ready = false;
    attempt(7, 2, source(), facts, false, lease::Reason::client_not_ready);
    facts = guard(); facts.focused = false;
    attempt(7, 2, source(), facts, false, lease::Reason::focus_lost);
    facts = guard(); facts.gameplay = false;
    attempt(7, 2, source(), facts, false, lease::Reason::gameplay_inactive);
    facts = guard(); facts.menu_closed = false;
    attempt(7, 2, source(), facts, false, lease::Reason::menu_open);
    facts = guard(); facts.interference_clear = false;
    attempt(7, 2, source(), facts, false, lease::Reason::interference);
    facts = guard(); facts.context_generation = 0;
    attempt(7, 2, source(), facts, false, lease::Reason::context_changed);
    facts = guard(); facts.now_ms = 0;
    attempt(7, 2, source(), facts, false, lease::Reason::stale_epoch);
}

void measured_source_activation() {
    start("measured source activation");
    Running run;
    const auto immutable = run.sample;
    const auto snapshot = read(run.broker, run.handle, run.facts);
    check(snapshot.source_epoch == run.sample.epoch && snapshot.observation_serial == run.sample.observation_serial &&
        snapshot.observed_ms == run.sample.observed_ms && snapshot.context_generation == run.sample.context_generation &&
        snapshot.user == run.sample.user && snapshot.packet == run.sample.packet && snapshot.pad == run.sample.pad,
        "sample preserves actual raw report and observed identity");
    check(run.sample.pad == immutable.pad && run.sample.packet == immutable.packet,
        "observation does not mutate the raw report");
    auto other = run.sample; other.user = 0; other.epoch = 123;
    ++other.observation_serial;
    run.broker.observe(run.handle, other, run.facts);
    check(read(run.broker, run.handle, run.facts) == snapshot, "unselected slot cannot replace selected source");
}

void stale_inflight_cookie() {
    start("old in-flight cookie cannot qualify a new lease");
    lease::Broker broker;
    auto facts = guard(); auto sample = source();
    const auto old = request(broker, sample, facts);
    const auto in_flight = broker.active();
    check(broker.release(7, old) && broker.acknowledge(7, old), "old reservation retires immediately");
    ++facts.now_ms; sample.observed_ms = facts.now_ms; ++sample.observation_serial;
    const auto fresh = request(broker, sample, facts);
    check(fresh != old, "new reservation has a distinct sequence");
    ++facts.now_ms; sample.observed_ms = facts.now_ms; ++sample.observation_serial;
    broker.observe(in_flight, sample, facts);
    check(state(broker, fresh).status == lease::Status::warming, "pre-admission poll cannot activate later lease");
    auto snapshot = sentinel(); const auto untouched = snapshot; lease::Reason reason{};
    check(!broker.read(7, fresh, facts, snapshot, reason) && snapshot == untouched,
        "old cookie cannot provide readable sample to new owner");
    ++facts.now_ms; sample.observed_ms = facts.now_ms; ++sample.observation_serial;
    broker.observe(fresh, sample, facts);
    check(read(broker, fresh, facts).observation_serial == sample.observation_serial,
        "new matching cookie can qualify subsequent observation");
}

void ordinal_and_packet_continuity() {
    start("observation ordinal and DWORD packet continuity");
    {
        Running run;
        const auto before = read(run.broker, run.handle, run.facts);
        run.broker.observe(run.handle, run.sample, run.facts);
        check(read(run.broker, run.handle, run.facts) == before, "identical duplicate observation is idempotent");
        ++run.sample.pad.right_x;
        run.broker.observe(run.handle, run.sample, run.facts);
        const auto receipt = state(run.broker, run.handle);
        check(receipt.status == lease::Status::revoked && receipt.reason == lease::Reason::stale_epoch,
            "same ordinal with changed report cannot silently replace sample");
    }
    {
        Running run;
        --run.sample.observation_serial;
        run.broker.observe(run.handle, run.sample, run.facts);
        check(state(run.broker, run.handle).reason == lease::Reason::stale_epoch, "regressing ordinal revokes source");
    }
    {
        Running run;
        ++run.sample.observation_serial; --run.sample.observed_ms;
        run.broker.observe(run.handle, run.sample, run.facts);
        check(state(run.broker, run.handle).reason == lease::Reason::stale_epoch, "regressing source timestamp revokes");
    }
    {
        Running run;
        run.sample.packet = std::numeric_limits<std::uint32_t>::max(); run.advance();
        check(read(run.broker, run.handle, run.facts).packet == std::numeric_limits<std::uint32_t>::max(),
            "maximum native DWORD packet is valid");
        run.sample.packet = 0; run.advance();
        check(read(run.broker, run.handle, run.facts).packet == 0,
            "real packet wrap is allowed when SDK observation ordinal advances");
        run.advance();
        check(read(run.broker, run.handle, run.facts).packet == 0,
            "unchanged native packet is allowed on a later raw observation");
    }
}

void owner_isolation() {
    start("owner and handle isolation");
    Running run;
    const auto issued = read(run.broker, run.handle, run.facts);
    const auto before = state(run.broker, run.handle);
    auto out = sentinel(); const auto untouched = out; lease::Reason reason{};
    check(!run.broker.read(8, run.handle, run.facts, out, reason) && out == untouched,
        "another owner cannot read source data");
    lease::Receipt receipt = before;
    check(!run.broker.state(8, run.handle, receipt) && same_receipt(receipt, before),
        "wrong-owner state leaves receipt untouched");
    check(!run.broker.renew(8, run.handle, issued, run.facts, reason), "another owner cannot renew");
    check(!run.broker.release(8, run.handle) && !run.broker.acknowledge(8, run.handle),
        "another owner cannot retire reservation or receipt");
    const lease::Handle wrong_handle{run.handle.sequence + 1};
    check(!run.broker.read(7, wrong_handle, run.facts, out, reason) && out == untouched,
        "unissued handle cannot read source data or change output");
    check(!run.broker.state(7, wrong_handle, receipt) && same_receipt(receipt, before),
        "unissued handle cannot reveal or replace owner's receipt");
    check(!run.broker.renew(7, wrong_handle, issued, run.facts, reason), "wrong handle cannot renew using an owned snapshot");
    check(!run.broker.release(7, wrong_handle) && !run.broker.acknowledge(7, wrong_handle),
        "wrong handle cannot release reservation or erase evidence");
    check(same_receipt(state(run.broker, run.handle), before), "unauthorized attempts do not alter owner's lease");
}

void opaque_single_use_renewal() {
    start("opaque snapshot renewal and single use");
    Running run;
    const auto first = read(run.broker, run.handle, run.facts);
    auto forged = first; ++forged.pad.left_x;
    lease::Reason reason{};
    const auto initial = state(run.broker, run.handle);
    check(!run.broker.renew(7, run.handle, forged, run.facts, reason), "edited snapshot is not renewal authority");
    check(same_receipt(state(run.broker, run.handle), initial), "forged renewal preserves deadline and state");
    check(run.broker.renew(7, run.handle, first, run.facts, reason) && reason == lease::Reason::none,
        "actual issued snapshot can renew once");
    check(state(run.broker, run.handle).renewals == 1, "successful renewal has one observed witness");
    check(!run.broker.renew(7, run.handle, first, run.facts, reason), "same snapshot cannot renew repeatedly");
    check(read(run.broker, run.handle, run.facts) == first, "rereading same observation does not fabricate progress");
    check(!run.broker.renew(7, run.handle, first, run.facts, reason), "reread cannot turn used ordinal into another renewal");
    run.advance(20);
    const auto second = read(run.broker, run.handle, run.facts);
    run.advance(20);
    check(run.broker.renew(7, run.handle, second, run.facts, reason),
        "new source arrival does not invalidate a still-fresh exact issued snapshot");
    const auto renewed = state(run.broker, run.handle);
    check(renewed.renewals == 2 && renewed.expires_ms == run.facts.now_ms + lease::lifetime_ms,
        "renewal extends bounded deadline from trusted current time");
    const auto latest = read(run.broker, run.handle, run.facts);
    check(!run.broker.renew(7, run.handle, second, run.facts, reason), "older issuance cannot replace latest issued authority");
    check(run.broker.renew(7, run.handle, latest, run.facts, reason), "latest issued observation renews independently");
}

void guessed_and_cross_lease_snapshots() {
    start("unissued and cross-lease snapshot refusal");
    Running run;
    lease::Snapshot guessed;
    guessed.handle = run.handle; guessed.source_epoch = run.sample.epoch;
    guessed.observation_serial = run.sample.observation_serial; guessed.observed_ms = run.sample.observed_ms;
    guessed.context_generation = run.sample.context_generation; guessed.user = run.sample.user;
    guessed.packet = run.sample.packet; guessed.pad = run.sample.pad;
    lease::Reason reason{};
    check(!run.broker.renew(7, run.handle, guessed, run.facts, reason),
        "matching public facts without an issued read are not renewal authority");
    const auto old = read(run.broker, run.handle, run.facts);
    check(run.broker.release(7, run.handle) && run.broker.acknowledge(7, run.handle), "first lease retires");
    const auto replacement = request(run.broker, run.sample, run.facts);
    ++run.facts.now_ms; ++run.sample.observation_serial; run.sample.observed_ms = run.facts.now_ms;
    run.broker.observe(replacement, run.sample, run.facts);
    check(!run.broker.renew(7, replacement, old, run.facts, reason), "prior lease issuance cannot renew replacement");
    auto counterfeit = old; counterfeit.handle = replacement;
    check(!run.broker.renew(7, replacement, counterfeit, run.facts, reason), "rewriting old handle does not establish issuance");
}

void freshness_and_deadline() {
    start("freshness and exact deadline boundaries");
    {
        Running run;
        auto facts = run.facts; facts.now_ms += lease::maximum_age_ms;
        check(read(run.broker, run.handle, facts).observed_ms == run.sample.observed_ms,
            "age exactly at inclusive freshness bound remains readable");
        ++facts.now_ms;
        auto out = sentinel(); const auto untouched = out; lease::Reason reason{};
        check(!run.broker.read(7, run.handle, facts, out, reason) && out == untouched,
            "one millisecond beyond source freshness refuses and preserves output");
        check(lease::terminal(state(run.broker, run.handle).status), "stale stream relinquishes source reservation");
    }
    {
        lease::Broker broker; auto facts = guard(); const auto handle = request(broker, source(), facts);
        facts.now_ms += lease::maximum_age_ms + 1;
        broker.tick(facts);
        check(state(broker, handle).reason == lease::Reason::source_stale,
            "warming without a post-begin sample cannot wait beyond freshness window");
    }
    {
        Running run;
        const auto deadline = state(run.broker, run.handle).expires_ms;
        while (run.facts.now_ms + 50 < deadline) run.advance(50);
        const auto delta = deadline - 1 - run.facts.now_ms;
        if (delta) run.advance(delta);
        check(read(run.broker, run.handle, run.facts).handle == run.handle, "lease remains active immediately before deadline");
        ++run.facts.now_ms;
        run.broker.tick(run.facts);
        const auto receipt = state(run.broker, run.handle);
        check(receipt.status == lease::Status::expired && receipt.reason == lease::Reason::deadline && receipt.source_released,
            "exact deadline expires without requiring another raw poll");
    }
}

void stale_issued_renewal() {
    start("old issued sample cannot renew a fresh stream");
    Running run;
    const auto old = read(run.broker, run.handle, run.facts);
    run.advance(60); run.advance(41);
    lease::Reason reason{};
    const auto before = state(run.broker, run.handle);
    check(!run.broker.renew(7, run.handle, old, run.facts, reason),
        "continued source observations cannot freshen old issued snapshot");
    check(same_receipt(state(run.broker, run.handle), before), "stale issuance refusal does not renew or revoke fresh stream");
    const auto latest = read(run.broker, run.handle, run.facts);
    check(run.broker.renew(7, run.handle, latest, run.facts, reason), "fresh latest issuance still renews");
}

void guard_revocations() {
    start("guard and client context revocations");
    using Edit = void (*)(lease::Guard&);
    struct Row { Edit edit; lease::Reason reason; };
    const std::array<Row, 6> rows{{
        {[](lease::Guard& g) { g.ready = false; }, lease::Reason::client_not_ready},
        {[](lease::Guard& g) { g.focused = false; }, lease::Reason::focus_lost},
        {[](lease::Guard& g) { g.gameplay = false; }, lease::Reason::gameplay_inactive},
        {[](lease::Guard& g) { g.menu_closed = false; }, lease::Reason::menu_open},
        {[](lease::Guard& g) { g.interference_clear = false; }, lease::Reason::interference},
        {[](lease::Guard& g) { ++g.context_generation; }, lease::Reason::context_changed}
    }};
    for (const auto& row : rows) {
        Running run;
        auto invalid = run.facts; row.edit(invalid);
        run.broker.tick(invalid);
        const auto receipt = state(run.broker, run.handle);
        check(receipt.status == lease::Status::revoked && receipt.reason == row.reason && receipt.source_released,
            "guard failure promptly revokes source with precise reason");
        check(run.broker.active() == lease::Handle{} && run.broker.active_user() == 4,
            "revocation releases source slot immediately");
        auto out = sentinel(); const auto untouched = out; lease::Reason reason{};
        check(!run.broker.read(7, run.handle, run.facts, out, reason) && out == untouched,
            "restored guard cannot revive a terminal lease");
    }
}

void source_revocations_without_cookie() {
    start("observed source changes revoke without a matching cookie");
    using Edit = void (*)(lease::Source&);
    const std::array<Edit, 4> edits{{
        [](lease::Source& s) { ++s.epoch; },
        [](lease::Source& s) { s.connected = false; },
        [](lease::Source& s) { s.eligible = false; },
        [](lease::Source& s) { ++s.context_generation; }
    }};
    for (const auto edit : edits) {
        Running run;
        edit(run.sample);
        run.broker.observe({}, run.sample, run.facts);
        const auto receipt = state(run.broker, run.handle);
        check(receipt.status == lease::Status::revoked && receipt.source_released,
            "disconnect or observed identity loss promptly revokes despite unowned in-flight cookie");
    }
    {
        Running run;
        const auto old = run.handle;
        check(run.broker.release(7, old), "old source owner releases");
        const auto replacement = request(run.broker, run.sample, run.facts);
        ++run.sample.epoch;
        run.broker.observe(old, run.sample, run.facts);
        check(state(run.broker, replacement).reason == lease::Reason::source_changed,
            "old in-flight report still revokes replacement when selected observed source identity changes");
    }
}

void trusted_clock_regression() {
    start("trusted clock regression");
    {
        Running run;
        auto facts = run.facts; --facts.now_ms;
        auto out = sentinel(); const auto untouched = out; lease::Reason reason{};
        check(!run.broker.read(7, run.handle, facts, out, reason) && out == untouched,
            "regressing trusted read clock refuses without output");
        check(state(run.broker, run.handle).reason == lease::Reason::stale_epoch, "clock regression revokes instead of extending lifetime");
    }
    {
        Running run;
        const auto issued = read(run.broker, run.handle, run.facts);
        auto facts = run.facts; --facts.now_ms; lease::Reason reason{};
        check(!run.broker.renew(7, run.handle, issued, facts, reason), "clock regression cannot renew");
        check(state(run.broker, run.handle).status == lease::Status::revoked, "regressing renewal leaves terminal reservation");
    }
}

void global_exclusion() {
    start("global lease and pulse exclusion");
    Running run;
    auto competing = run.sample; competing.user = 0;
    lease::Handle handle{555}; lease::Reason reason{};
    check(!run.broker.request(8, 0, competing, run.facts, false, handle, reason) &&
        reason == lease::Reason::busy && handle.sequence == 555,
        "second lease cannot reserve even a different slot while source owner is active");
    check(run.broker.release(7, run.handle), "current owner releases observation reservation");
    check(!run.broker.request(8, 0, competing, run.facts, true, handle, reason) && reason == lease::Reason::busy,
        "pulse busy excludes new source lease after former owner release");
    check(run.broker.request(8, 0, competing, run.facts, false, handle, reason),
        "retained terminal receipt does not keep global source ownership");
}

void release_acknowledge_and_unload() {
    start("release, acknowledge, unload and absence of publication debt");
    Running run;
    const auto raw = run.sample.pad;
    const auto initial = state(run.broker, run.handle);
    run.broker.release_all(8);
    check(same_receipt(state(run.broker, run.handle), initial), "another owner's unload cannot release active reservation");
    check(run.broker.release(7, run.handle), "observation lease releases immediately");
    const auto receipt = state(run.broker, run.handle);
    check(receipt.status == lease::Status::released && receipt.source_released,
        "release retains terminal receipt without a neutral report phase");
    check(run.sample.pad == raw && run.broker.active() == lease::Handle{},
        "release leaves raw report untouched and no active publication reservation");
    check(run.broker.acknowledge(7, run.handle), "terminal lease can be acknowledged immediately without another game poll");
    lease::Receipt untouched = receipt;
    check(!run.broker.state(7, run.handle, untouched) && same_receipt(untouched, receipt),
        "acknowledgement erases receipt without altering failed output");
    auto foreign = request(run.broker, run.sample, run.facts, 8);
    check(run.broker.release(8, foreign), "foreign owner retains released receipt");
    const auto own = request(run.broker, run.sample, run.facts);
    run.broker.release_all(7);
    check(run.broker.active() == lease::Handle{} && !run.broker.state(7, own, untouched),
        "unload retires and erases owned active lease without polling or publication debt");
    check(state(run.broker, foreign, 8).status == lease::Status::released, "unload preserves another owner's retained receipt");
    run.broker.release_all(8);
    check(!run.broker.state(8, foreign, untouched), "unload erases owned retained receipts too");
}

void capacity_and_acknowledgement() {
    start("bounded retained capacity");
    lease::Broker broker;
    const auto facts = guard(); const auto sample = source();
    std::array<lease::Handle, lease::retained_capacity> retained{};
    for (auto& handle : retained) {
        handle = request(broker, sample, facts);
        check(broker.release(7, handle), "released lease occupies bounded retained slot");
    }
    lease::Handle rejected{777}; lease::Reason reason{};
    check(!broker.request(7, 2, sample, facts, false, rejected, reason) &&
        reason == lease::Reason::capacity && rejected.sequence == 777,
        "eight unacknowledged records refuse ninth without evicting evidence");
    for (const auto handle : retained) check(state(broker, handle).status == lease::Status::released, "capacity refusal preserves prior receipts");
    check(broker.acknowledge(7, retained.front()), "acknowledgement frees exactly one retained slot");
    const auto fresh = request(broker, sample, facts);
    check(fresh.sequence == retained.back().sequence + 1, "capacity refusal consumes no opaque sequence");
}

void opaque_integer_limits() {
    start("opaque integer precision and exhaustion");
    constexpr std::uint64_t beyond_lua_number = (std::uint64_t{1} << 53) + 1;
    const auto facts = guard(); const auto sample = source();
    {
        lease::Broker broker(beyond_lua_number);
        lease::Handle handle; lease::Reason reason{};
        check(broker.request(7, 2, sample, facts, false, handle, reason) && handle.sequence == beyond_lua_number,
            "opaque handle remains exact beyond floating-point integer range");
        check(broker.release(7, handle) && broker.acknowledge(7, handle), "large opaque handle retires exactly");
        check(broker.request(7, 2, sample, facts, false, handle, reason) && handle.sequence == beyond_lua_number + 1,
            "successor remains exact beyond 2^53");
    }
    {
        lease::Broker broker(std::numeric_limits<std::uint64_t>::max());
        lease::Handle handle; lease::Reason reason{};
        check(broker.request(7, 2, sample, facts, false, handle, reason) &&
            handle.sequence == std::numeric_limits<std::uint64_t>::max(), "final uint64 sequence may be issued exactly once");
        check(broker.release(7, handle) && broker.acknowledge(7, handle), "last sequence retires");
        handle.sequence = 123;
        check(!broker.request(7, 2, sample, facts, false, handle, reason) &&
            reason == lease::Reason::sequence_exhausted && handle.sequence == 123,
            "sequence exhaustion latches without wrapping or reusing identity");
    }
    {
        lease::Broker broker(0); lease::Handle handle{456}; lease::Reason reason{};
        check(!broker.request(7, 2, sample, facts, false, handle, reason) &&
            reason == lease::Reason::sequence_exhausted && handle.sequence == 456,
            "zero sequence seed starts exhausted");
    }
}

void deadline_overflow() {
    start("deadline arithmetic at uint64 boundary");
    constexpr auto maximum = std::numeric_limits<std::uint64_t>::max();
    {
        lease::Broker broker;
        const auto facts = guard(maximum - lease::lifetime_ms + 1);
        const auto sample = source(facts.now_ms);
        lease::Handle out{456}; lease::Reason reason{};
        check(!broker.request(7, 2, sample, facts, false, out, reason) &&
            reason == lease::Reason::deadline && out.sequence == 456 && broker.active() == lease::Handle{},
            "deadline overflow refuses without publishing handle or reservation");
    }
    {
        lease::Broker broker;
        auto facts = guard(maximum - lease::lifetime_ms);
        auto sample = source(facts.now_ms);
        const auto handle = request(broker, sample, facts);
        check(state(broker, handle).expires_ms == maximum, "last representable deadline does not wrap");
        ++facts.now_ms; ++sample.observation_serial; sample.observed_ms = facts.now_ms;
        broker.observe(handle, sample, facts);
        const auto issued = read(broker, handle, facts);
        const auto before = state(broker, handle);
        lease::Reason reason{};
        check(!broker.renew(7, handle, issued, facts, reason) && reason == lease::Reason::deadline,
            "renewal cannot overflow representable expiration");
        check(same_receipt(state(broker, handle), before), "overflow refusal leaves original bounded deadline intact");
    }
}

// The portable capture policy alone, over constructed clean same-source reports:
// one report per call, never a native write or a physical-controller claim.
struct CaptureRig {
    capture::Capture policy{10, 20};
    capture::Key key{7, 1, 91, 17, 2};
    std::uint64_t serial{41}, now{1000}, epoch{91};
    capture::Input report(const lease::Pad& pad) {
        capture::Input in;
        in.source_epoch = epoch; in.context_generation = 17; in.user = 2;
        in.observation_serial = ++serial; in.observed_ms = in.now_ms = ++now;
        in.raw = in.returned = pad;
        in.safety = {true, true, true, true, true, true};
        in.outer_game_poll = in.has_output = in.source_connected = true;
        return in;
    }
    capture::Plan publish(const lease::Pad& pad) {
        const auto plan = policy.plan(policy.ticket(), report(pad));
        if (plan.suppress) check(policy.confirm(plan, true), "constructed owned report confirms");
        return plan;
    }
    void admit() {
        capture::Reason reason{};
        const auto in = report({});
        check(policy.request(key, now + 200, in, false, reason) && reason == capture::Reason::none,
            "constructed capture admits");
    }
    void capturing() {
        admit();
        check(publish({}).start && policy.state().phase == capture::Phase::capturing, "a neutral report starts capture");
    }
    void release() { check(policy.release(key) && policy.state().phase == capture::Phase::releasing, "owner ends capture"); }
};
constexpr lease::Pad resting{0, 30, 12, 7000, -3000, -8000, 2000};
constexpr std::uint16_t button_a = 0x1000, button_b = 0x2000;

void capture_rest_admission() {
    start("capture admits and releases a resting pad, not an active one");
    CaptureRig rig; rig.admit();
    for (const lease::Pad active : {lease::Pad{0, 0, 0, 6000, 6000, 0, 0}, lease::Pad{0, 0, 0, 0, 0, 0, 8690},
             lease::Pad{0, 31, 0, 0, 0, 0, 0}, lease::Pad{0, 0, 255, 0, 0, 0, 0}, lease::Pad{0x0020, 0, 0, 0, 0, 0, 0}}) {
        const auto plan = rig.publish(active);
        check(!plan.suppress && plan.pad == active && rig.policy.state().phase == capture::Phase::waiting_neutral,
            "a pushed stick, held trigger or button neither starts capture nor is rewritten");
    }
    const auto first = rig.publish(resting);
    check(first.suppress && first.start && first.pad == lease::Pad{} && rig.policy.state().phase == capture::Phase::capturing,
        "resting noise starts capture, which writes an exact neutral report");
    rig.release();
    const auto handoff = rig.publish(resting);
    check(handoff.suppress && handoff.release && handoff.pad == resting && !handoff.held.any(),
        "a resting pad finishes the handoff on its first report, noise and all");
    const auto& receipt = rig.policy.state();
    check(receipt.phase == capture::Phase::complete && !receipt.debt && receipt.neutral_releases == 1,
        "the resting handoff is a witnessed neutral release");
}

void capture_held_hand_back() {
    start("release hands each control back once it rests");
    CaptureRig rig; rig.capturing();
    check(rig.publish({button_a, 0, 0, 20000, 0, 0, 0}).pad == lease::Pad{}, "capture suppresses held controls");
    rig.release();
    auto plan = rig.publish({button_a, 0, 0, 20000, 0, 0, 0});
    capture::Held held{button_a}; held.left_stick = true;
    check(plan.pad == lease::Pad{} && !plan.release && plan.held == held,
        "A and the pushed stick stay held back; resting controls are handed back");
    plan = rig.publish({button_a, 0, 200, 0, 0, 0, 0});
    check(plan.pad == lease::Pad{0, 0, 200, 0, 0, 0, 0} && !plan.release && plan.held == capture::Held{button_a},
        "a control seen at rest reaches the game at once; A stays out");
    plan = rig.publish({button_a | button_b, 0, 0, 20000, 0, 0, 0});
    check(plan.pad == lease::Pad{button_b, 0, 0, 20000, 0, 0, 0} && !plan.release,
        "after resting once, a new push or press passes while A is still held back");
    plan = rig.publish({button_b, 0, 0, 0, 0, 0, 0});
    check(plan.release && plan.pad == lease::Pad{button_b, 0, 0, 0, 0, 0, 0} && !plan.held.any() &&
        rig.policy.state().phase == capture::Phase::complete && !rig.policy.state().debt,
        "releasing A completes the handoff");
}

void capture_release_bound() {
    start("release ends at its bound and hands what is held to the caller");
    CaptureRig rig; rig.capturing(); rig.release();
    auto plan = rig.publish({button_a, 0, 0, 0, 0, 0, 0});
    const auto started = rig.now;
    check(!plan.release && plan.pad == lease::Pad{} && plan.held == capture::Held{button_a}, "the clock starts, A held back");
    rig.now = started + capture::Capture::maximum_release_ms - 2;
    plan = rig.publish({button_a, 0, 0, 0, 0, 0, 0});
    check(!plan.release && rig.policy.state().phase == capture::Phase::releasing, "inside its bound a held A keeps the release open");
    plan = rig.publish({button_a, 0, 0, 0, 0, 0, 0});
    check(rig.now - started == capture::Capture::maximum_release_ms, "constructed report lands on the bound");
    check(plan.suppress && plan.release && plan.pad == lease::Pad{} && plan.held == capture::Held{button_a},
        "at the bound the last owned report still holds A back and hands it to the caller");
    const auto& receipt = rig.policy.state();
    check(receipt.phase == capture::Phase::complete && !receipt.debt && !receipt.quarantined && receipt.neutral_releases == 1,
        "the slot frees with a witnessed release");
    check(rig.policy.acknowledge(rig.key), "the bounded release acknowledges");
    capture::Held held{button_a};
    held.rest({button_a, 0, 0, 0, 0, 0, 0});
    check(held.mask({button_a | button_b, 9, 9, 9, 9, 9, 9}) == lease::Pad{button_b, 9, 9, 9, 9, 9, 9},
        "the caller's hand-back keeps only A out while it is held");
    held.rest({});
    check(!held.any() && held.mask({button_a, 0, 0, 0, 0, 0, 0}) == lease::Pad{button_a, 0, 0, 0, 0, 0, 0},
        "once A rests, a new press passes");
}

void capture_lost_source_bound() {
    start("a lost stream's release ends quarantined at the bound");
    CaptureRig rig; rig.capturing(); rig.release();
    const auto publications = rig.policy.state().publications;
    rig.epoch = 92;
    check(!rig.publish({button_a, 0, 0, 0, 0, 0, 0}).suppress, "a new epoch is never rewritten");
    const auto started = rig.now;
    check(rig.policy.state().phase == capture::Phase::releasing && rig.policy.state().quarantined,
        "the old stream's debt is quarantined");
    rig.policy.sync(started + capture::Capture::maximum_release_ms - 1, false);
    check(rig.policy.state().phase == capture::Phase::releasing && rig.policy.state().debt, "inside its bound it waits");
    CaptureRig present; present.capturing(); present.release();
    (void)present.publish({button_a, 0, 0, 0, 0, 0, 0});
    present.policy.sync(present.now + capture::Capture::maximum_release_ms, true);
    check(present.policy.state().phase == capture::Phase::releasing,
        "a present stream finishes only on a report, which carries its hand-back");
    rig.policy.sync(started + capture::Capture::maximum_release_ms, false);
    const auto& receipt = rig.policy.state();
    check(receipt.phase == capture::Phase::complete && !receipt.debt && receipt.quarantined &&
        receipt.neutral_releases == 0 && receipt.publications == publications,
        "at the bound it ends quarantined, without a neutral release");
    check(rig.policy.acknowledge(rig.key), "the ended capture acknowledges");
}

void capture_interfered_release() {
    start("an interfered release leaves held controls to the caller and still sees rest");
    CaptureRig rig; rig.capturing(); rig.release();
    check(rig.policy.held() == capture::Held::all(), "at the stop every control is held back");
    auto in = rig.report({button_a, 0, 0, 20000, 0, 0, 0});
    in.safety.interference_clear = false;
    auto plan = rig.policy.plan(rig.policy.ticket(), in);
    capture::Held held{button_a}; held.left_stick = true;
    check(!plan.suppress && plan.pad == in.returned && rig.policy.held() == held,
        "another filter's report is not rewritten; what stays held is the caller's to keep neutral in it");
    in = rig.report({button_a, 0, 0, 0, 0, 0, 0});
    in.returned = {button_a | button_b, 0, 0, 0, 0, 0, 0};
    plan = rig.policy.plan(rig.policy.ticket(), in);
    check(!plan.suppress && rig.policy.held() == capture::Held{button_a},
        "the stick, at rest under a script's report, is handed back all the same");
    check(rig.policy.state().phase == capture::Phase::releasing && rig.policy.state().debt, "only a clean report ends it");
    plan = rig.publish({});
    check(plan.release && rig.policy.state().phase == capture::Phase::complete && !rig.policy.held().any(),
        "a clean resting report completes it, and nothing is held after");
}

void capture_neutral_write_rearms() {
    start("a full neutral report during a release holds every control again");
    CaptureRig rig; rig.capturing(); rig.release();
    const auto started = rig.now + 1;
    capture::Held stick; stick.left_stick = true;
    check(rig.publish({0, 0, 0, 20000, 0, 0, 0}).held == stick, "only the pushed stick stays held");
    rig.policy.continuation_result(rig.key, true);
    check(rig.policy.held() == capture::Held::all(), "a delayed report written fully neutral re-arms every control");
    auto plan = rig.publish({button_a, 0, 0, 20000, 0, 0, 0});
    capture::Held held{button_a}; held.left_stick = true;
    check(plan.pad == lease::Pad{} && plan.held == held && !plan.release,
        "A, handed back before, now stays out until it rests");
    check(rig.policy.retain_neutralization(rig.key) && rig.policy.held() == capture::Held::all(),
        "a stale-stage neutral fallback re-arms every control too");
    rig.now = started + capture::Capture::maximum_release_ms - 1;
    plan = rig.publish({button_a, 0, 0, 0, 0, 0, 0});
    check(plan.release && plan.held == capture::Held{button_a},
        "re-arming never moves the bound: the release still ends there and hands A to the caller");
}
}

int main() {
    admission_and_warming();
    request_refusals();
    measured_source_activation();
    stale_inflight_cookie();
    ordinal_and_packet_continuity();
    owner_isolation();
    opaque_single_use_renewal();
    guessed_and_cross_lease_snapshots();
    freshness_and_deadline();
    stale_issued_renewal();
    guard_revocations();
    source_revocations_without_cookie();
    trusted_clock_regression();
    global_exclusion();
    release_acknowledge_and_unload();
    capacity_and_acknowledgement();
    opaque_integer_limits();
    deadline_overflow();
    capture_rest_admission();
    capture_held_hand_back();
    capture_release_bound();
    capture_lost_source_bound();
    capture_interfered_release();
    capture_neutral_write_rearms();
    std::cout << "input lease policy: " << cases << " cases, " << checks << " checks passed\n";
}
