#include "Extension/Skater/native_input_pulse.h"
#include "Extension/Skater/native_input_pulse_environment.h"
#include "Extension/Skater/actor_control.h"
#include <array>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string_view>

namespace service = dingosdk::native_input_pulse;
namespace model = dingosdk::game_input_pulse;
namespace pulse_policy = dingosdk::input_pulse;
namespace lease = dingosdk::input_lease;
namespace actor = dingosdk::actor_control_native;
namespace control = dingosdk::actor_control;
namespace clock_policy = dingosdk::actor_clock;

// The actual Windows service is linked below against these private providers.
// Constructed actor/source facts do not qualify any real game's native guards.
namespace fixture {
unsigned checks{};
void check(bool value, const char* why) {
    ++checks;
    if (!value) { std::cerr << "input lease native: " << why << '\n'; std::exit(1); }
}
struct Environment {
    std::uint64_t wall{100}, last_step{}, clock_sequence{}, owner{};
    bool focus{true}, gameplay{true}, menu{true}, interference{true};
    bool acquire_ok{true}, inspect_ok{true}, enter_ok{true}, enable_ok{true}, retire_ok{true}, clock_enabled{};
    actor::Reason acquire_reason{actor::Reason::unavailable};
    actor::Observation inspect_failure{dingosdk::actor_observation::Phase::capture, actor::Reason::unavailable};
    actor::Observation enter_failure{dingosdk::actor_observation::Phase::enter_owner_lock, actor::Reason::unavailable};
    DWORD thread_override{};
    unsigned acquire_calls{}, enable_calls{}, inspect_calls{}, retire_calls{}, disable_calls{}, clock_reads{};
    unsigned reads_before_jump{};
    std::uint64_t jump_to{};
    actor::Actor current;
    control::Arbiter arbiter;
    clock_policy::Ledger<actor::Actor> clock;
    clock_policy::Key<actor::Actor> clock_key;
} env;

bool owns(std::uint64_t owner, std::uint64_t sequence, const actor::Actor& value) noexcept {
    return owner == env.owner && sequence == env.clock_sequence && value == env.current &&
        env.arbiter.owns(owner, value.ticket, control::Domain::equipment);
}
void time(std::uint64_t ms) {
    env.wall = ms;
    if (!env.clock_enabled) return;
    clock_policy::Feed<actor::Actor> feed;
    const double dt = env.last_step && ms > env.last_step && ms - env.last_step <= 100 ?
        static_cast<double>(ms - env.last_step) / 1000 : 1.0 / 60;
    check(env.clock.begin(env.clock_key, feed) && env.clock.publish(feed, dt, ms), "fixture publishes a real qualified-clock ledger sample");
    env.last_step = ms;
}
struct Buffer {
    XINPUT_STATE value{};
    std::array<std::uint64_t, 4> tail{0x1122334455667788ULL, 2, 3, 4};
};
struct Frame {
    DWORD original{ERROR_SUCCESS}, returned{ERROR_SUCCESS}, raw_packet{7}, prior_packet{7};
    XINPUT_GAMEPAD raw{}, transformed{};
    bool outer{true}, clean{true}, null_output{};
    std::uint32_t user{};
    std::uint64_t original_ms{};
};
Buffer finish(service::Poll& cookie, Frame frame) {
    Buffer output; output.value.dwPacketNumber = frame.prior_packet; output.value.Gamepad = frame.transformed;
    const auto tail = output.tail;
    service::finish(cookie, frame.outer, frame.user, frame.original,
        frame.original_ms ? frame.original_ms : env.wall, frame.raw_packet, frame.raw,
        frame.returned, frame.null_output ? nullptr : &output.value, frame.clean);
    check(output.tail == tail, "actual publication does not overwrite extended/trailing fields");
    return output;
}
Buffer frame(std::uint64_t ms, Frame value = {}) {
    time(ms);
    service::Poll cookie;
    service::begin(value.outer, value.user, cookie);
    return finish(cookie, value);
}
void prime(std::uint64_t ms, std::uint32_t user = 0) {
    time(ms); service::tick(1, 2, true);
    Frame value; value.user = user; (void)frame(ms, value);
}
model::Handle request(std::uint64_t owner = 1, std::uint32_t user = 0, std::uint16_t button = 0x1000) {
    model::Handle handle; model::Reason reason{};
    check(service::request(owner, user, button, handle, reason) && handle.sequence && reason == model::Reason::none,
        "actual service admits an owned generic report request");
    return handle;
}
model::Receipt read(model::Handle handle, std::uint64_t owner = 1) {
    model::Receipt receipt;
    check(service::read(owner, handle, receipt) && receipt.handle == handle, "owner reads exact actual-service receipt");
    return receipt;
}
model::Handle press(std::uint64_t owner = 1, std::uint64_t base = 100) {
    prime(base); const auto handle = request(owner);
    for (const auto offset : {0u, 34u, 67u}) check(frame(base + offset).value.Gamepad.wButtons == 0, "warmup preserves neutral");
    check(frame(base + 100).value.Gamepad.wButtons == 0x1000, "actual service publishes the selected button after warmup");
    check(read(handle, owner).press_publications == 1, "receipt counts the actual first buffer write");
    return handle;
}
void retire(std::uint64_t ms) {
    time(ms); service::tick(1, 2, true);
    check(env.arbiter.publication_allowed(), "actual service retires the real shared claim after calls drain");
}
}

namespace dingosdk::native_input_pulse::environment {
std::uint64_t now() noexcept {
    auto& value = fixture::env;
    if (value.jump_to) {
        if (!value.reads_before_jump) { value.wall = value.jump_to; value.jump_to = 0; }
        else --value.reads_before_jump;
    }
    return value.wall;
}
DWORD thread() noexcept { return fixture::env.thread_override ? fixture::env.thread_override : GetCurrentThreadId(); }
bool focused() noexcept { return fixture::env.focus; }
bool gameplay() noexcept { return fixture::env.gameplay; }
bool menu_closed() noexcept { return fixture::env.menu; }
bool interference_clear() noexcept { return fixture::env.interference; }
}

namespace dingosdk::actor_control_native {
bool acquire(std::uint64_t owner, std::uint64_t sequence, Admission admission, Actor& out, Reason& reason,
    Continuity continuity) noexcept {
    auto& f = fixture::env; ++f.acquire_calls; out = {}; reason = f.acquire_reason;
    fixture::check(continuity == Continuity::observed_context,
        "report publication explicitly requests sampled context continuity, not native write lifetime");
    State state; state.known = true; state.value = 42;
    if (!f.acquire_ok || !admission || !admission(state)) return false;
    control::Ticket ticket;
    if (!f.arbiter.reserve(owner, control::Domain::equipment, ticket)) return false;
    Actor value;
    value.base = 1; value.client = 2; value.entity = 3; value.player = 4; value.player_handle = 5;
    value.component = 6; value.core = 7; value.context = 8; value.selector = 9; value.causes = 10;
    value.rig = 11; value.game_context = 12; value.world = 13; value.world_state = 14;
    value.world_generation = value.lifetime_epoch = value.actor_epoch = 1; value.ticket = ticket;
    value.continuity = continuity;
    if (!f.arbiter.publish(owner, ticket)) { (void)f.arbiter.abandon(owner, ticket); return false; }
    f.owner = owner; f.clock_sequence = sequence; f.current = value; out = value; reason = Reason::none;
    SetLastError(0x7654); // The real service must preserve its caller's error across providers.
    return true;
}
bool inspect(std::uint64_t owner, std::uint64_t sequence, const Actor& expected,
    Actor& out, State& state, Reason& reason, bool) noexcept {
    ++fixture::env.inspect_calls; out = {}; state = {}; reason = fixture::env.inspect_failure.reason;
    SetLastError(0x8765); // Exercise the service's preservation across a refusing provider too.
    if (!fixture::env.inspect_ok || !fixture::owns(owner, sequence, expected)) return false;
    out = expected; state.known = true; state.value = 42; reason = Reason::none; return true;
}
bool enter(std::uint64_t owner, std::uint64_t sequence, const Actor& value, control::Call& call) noexcept {
    return fixture::env.enter_ok && fixture::owns(owner, sequence, value) && fixture::env.arbiter.enter(owner, value.ticket, call);
}
bool inspect(std::uint64_t owner, std::uint64_t sequence, const Actor& expected,
    Actor& out, State& state, Reason& reason, Observation& observation, bool cleanup) noexcept {
    const bool result = inspect(owner, sequence, expected, out, state, reason, cleanup);
    observation = result ? Observation{dingosdk::actor_observation::Phase::qualified, Reason::none} : fixture::env.inspect_failure;
    return result;
}
bool enter(std::uint64_t owner, std::uint64_t sequence, const Actor& value, control::Call& call, Observation& observation) noexcept {
    const bool result = enter(owner, sequence, value, call);
    observation = result ? Observation{dingosdk::actor_observation::Phase::qualified, Reason::none} : fixture::env.enter_failure;
    return result;
}
bool retire(std::uint64_t owner, std::uint64_t sequence, const Actor& value, bool duty_resolved) noexcept {
    auto& f = fixture::env; ++f.retire_calls;
    if (!f.retire_ok || !duty_resolved || !fixture::owns(owner, sequence, value)) return false;
    if (!f.arbiter.revoke(owner, value.ticket) || !f.arbiter.retire(owner, value.ticket)) return false;
    f.owner = f.clock_sequence = 0; f.current = {}; return true;
}
bool enable_clock(std::uint64_t owner, std::uint64_t sequence, const Actor& value, Reason& reason) noexcept {
    auto& f = fixture::env; ++f.enable_calls; reason = Reason::unavailable;
    if (!f.enable_ok || !fixture::owns(owner, sequence, value)) return false;
    f.clock_key = {owner, sequence, value.ticket.generation, value};
    if (!f.clock.enable(f.clock_key)) return false;
    f.last_step = 0; f.clock_enabled = true; reason = Reason::none; return true;
}
bool read_clock(std::uint64_t owner, std::uint64_t sequence, const Actor& value, Clock& out) noexcept {
    ++fixture::env.clock_reads; out = {};
    return fixture::env.clock_enabled && fixture::owns(owner, sequence, value) &&
        fixture::env.clock.read(fixture::env.clock_key, fixture::env.wall, out);
}
bool disable_clock(std::uint64_t owner, std::uint64_t sequence, const Actor& value) noexcept {
    auto& f = fixture::env; ++f.disable_calls;
    if (!fixture::owns(owner, sequence, value)) return false;
    f.clock_enabled = false; return f.clock.disable(f.clock_key);
}
}

namespace {
using namespace fixture;
lease::Handle lease_request(std::uint64_t owner = 21, std::uint32_t user = 0) {
    lease::Handle handle; lease::Reason reason{};
    SetLastError(0x5A6B);
    check(service::lease_request(owner, user, handle, reason) && handle.sequence && reason == lease::Reason::none,
        "qualified observed selected source admits a lease");
    check(GetLastError() == 0x5A6B, "lease admission preserves caller LastError");
    return handle;
}
lease::Snapshot sample(lease::Handle handle, std::uint64_t owner = 21) {
    lease::Snapshot out; lease::Reason reason{};
    check(service::lease_read(owner, handle, out, reason) && reason == lease::Reason::none && out.handle == handle,
        "owner reads a qualified actual-service snapshot");
    return out;
}
lease::Receipt state(lease::Handle handle, std::uint64_t owner = 21) {
    lease::Receipt out; lease::Reason reason{};
    check(service::lease_state(owner, handle, out, reason) && reason == lease::Reason::none && out.handle == handle,
        "owner reads its retained lease receipt");
    return out;
}
void release(lease::Handle handle, std::uint64_t owner = 21) {
    lease::Reason reason{};
    check(service::lease_release(owner, handle, reason) && reason == lease::Reason::none, "owner releases selected source");
    check(state(handle, owner).source_released && state(handle, owner).status == lease::Status::released,
        "observation release has no report or actor debt");
    check(service::lease_acknowledge(owner, handle, reason), "released observation receipt is acknowledgeable");
}
void unavailable(lease::Handle handle, lease::Reason expected = lease::Reason::unavailable, std::uint64_t owner = 21) {
    lease::Snapshot out; out.source_epoch = 999;
    lease::Reason reason{};
    check(!service::lease_read(owner, handle, out, reason) && reason == expected && !out.handle.sequence && !out.source_epoch,
        "unqualified read refuses and clears output instead of reusing cached state");
}
void no_actor_calls() {
    check(env.acquire_calls == 0 && env.enable_calls == 0 && env.inspect_calls == 0 && env.retire_calls == 0 &&
        env.disable_calls == 0 && env.clock_reads == 0, "source lease never obtains, inspects, retires or clocks an actor claim");
}
Frame physical(std::uint32_t user = 0) {
    Frame f; f.user = user;
    f.raw = f.transformed = {0xA905, 17, 231, -32768, 32767, -12345, 23456};
    f.raw_packet = f.prior_packet = 0x11773355;
    return f;
}
void raw_cache() {
    prime(100); const auto handle = lease_request();
    unavailable(handle); // The pre-admission source is a boundary, never a first usable sample.
    const auto f = physical();
    SetLastError(0x9988); const auto output = frame(110, f);
    check(GetLastError() == 0x9988, "source observation preserves LastError");
    check(output.value.dwPacketNumber == f.prior_packet && std::memcmp(&output.value.Gamepad, &f.raw, sizeof(f.raw)) == 0,
        "observation does not rewrite original analog, trigger, button or packet bytes");
    const auto observed = sample(handle);
    check(observed.user == 0 && observed.source_epoch && observed.observation_serial && observed.context_generation &&
        observed.observed_ms == 110 && observed.packet == f.raw_packet && observed.pad ==
        lease::Pad{0xA905, 17, 231, -32768, 32767, -12345, 23456}, "snapshot contains the exact selected original raw report");
    check(state(handle).status == lease::Status::active, "fresh outer observation makes warming lease active");
    check(sample(handle) == observed, "repeated reads return the same cached observation without inventing a poll");
    lease::Reason reason{};
    check(service::lease_renew(21, handle, observed, reason), "exact previously issued snapshot renews");
    check(state(handle).renewals == 1 && state(handle).expires_ms == 360, "renewal extends owner TTL from actual current wall time");
    auto changed = f; ++changed.raw_packet; ++changed.prior_packet;
    changed.raw.sThumbLX = changed.transformed.sThumbLX = 123;
    (void)frame(120, changed);
    const auto same_slot = sample(handle);
    check(same_slot.source_epoch == observed.source_epoch && same_slot.observation_serial > observed.observation_serial &&
        same_slot.packet == changed.raw_packet && same_slot.pad.left_x == 123,
        "changing report contents advances observation without claiming a physical-device replacement");
    release(handle); no_actor_calls();
}
void lanes() {
    prime(100); const auto handle = lease_request();
    time(110); service::Poll selected; service::begin(true, 0, selected);
    check(selected.lease_handle == handle && !selected.sequence && !selected.call.active(),
        "outer begin records exact lease before original without opening an actor call");
    Frame nested = physical(); nested.outer = false;
    const auto nested_out = frame(110, nested);
    check(nested_out.value.dwPacketNumber == nested.prior_packet && nested_out.value.Gamepad.wButtons == nested.raw.wButtons,
        "nested lane report stays byte-for-byte ordinary output");
    unavailable(handle);
    const auto other = physical(1); (void)frame(111, other); unavailable(handle);
    auto selected_frame = physical(); selected_frame.original_ms = 112; env.wall = 112;
    (void)finish(selected, selected_frame);
    const auto before = sample(handle);
    check(before.user == 0 && before.observed_ms == 112, "selected outer original supplies its own report");
    (void)frame(113, other);
    check(sample(handle) == before, "other controller reports are never aggregated into selected-source cache");
    service::Poll invalid; service::begin(true, 4, invalid);
    check(!invalid.lease_handle.sequence && !invalid.sequence, "out-of-range wrapper lane cannot claim a source");
    release(handle); no_actor_calls();
}
void inflight() {
    prime(100);
    time(105); service::Poll before; service::begin(true, 0, before);
    const auto first = lease_request();
    env.wall = 110; (void)finish(before, {}); unavailable(first);
    (void)frame(120); (void)sample(first);
    time(125); service::Poll old; service::begin(true, 0, old);
    check(old.lease_handle == first, "in-flight original remembers old owner token");
    release(first);
    const auto next = lease_request(22);
    check(next != first, "replacement owner gets a distinct opaque sequence");
    env.wall = 130; (void)finish(old, {}); unavailable(next, lease::Reason::unavailable, 22);
    (void)frame(140); const auto latest = sample(next, 22);
    check(latest.observed_ms == 140 && latest.handle == next, "only post-admission outer call qualifies replacement source");
    release(next, 22); no_actor_calls();
}
void composition() {
    prime(100);
    control::Ticket ticket;
    check(env.arbiter.reserve(77, control::Domain::follow, ticket) && env.arbiter.publish(77, ticket),
        "fixture holds a separate actor follow reservation");
    const auto handle = lease_request(); (void)frame(110); (void)sample(handle);
    check(env.arbiter.owns(77, ticket, control::Domain::follow) && !env.arbiter.publication_allowed(),
        "source observation composes without a second ActorArbiter reservation or releasing follow owner");
    release(handle); no_actor_calls();
    check(env.arbiter.owns(77, ticket, control::Domain::follow), "source cleanup cannot clear another owner's actor claim");
}
void exclusion() {
    prime(100); const auto handle = lease_request();
    model::Handle pulse; model::Reason reason{};
    check(!service::request(55, 0, 0x1000, pulse, reason) && reason == model::Reason::busy && !pulse.sequence && !env.acquire_calls,
        "same-slot report pulse refuses before actor acquisition while lease holds source");
    check(!service::request(55, 1, 0x1000, pulse, reason) && reason == model::Reason::busy && !env.acquire_calls,
        "global pulse exclusion also covers another slot while source lease active");
    release(handle);
    pulse = request(55);
    check(env.acquire_calls == 1, "released lease immediately permits independent pulse actor admission");
    lease::Handle blocked; lease::Reason refusal{};
    check(!service::lease_request(21, 0, blocked, refusal) && refusal == lease::Reason::busy && !blocked.sequence,
        "live pulse interlocks passive source lease in the opposite direction");
    check(service::cancel(55, pulse), "fixture cancels pulse without publishing a report");
    retire(101);
    check(service::acknowledge(55, pulse), "unstarted pulse joins existing claim retirement");
    const auto next = lease_request(); release(next);
}
void disconnect() {
    prime(100); const auto first = lease_request(); (void)frame(110); const auto original = sample(first);
    Frame bad; bad.original = bad.returned = ERROR_DEVICE_NOT_CONNECTED;
    const auto output = frame(120, bad);
    check(output.value.dwPacketNumber == bad.prior_packet && output.value.Gamepad.wButtons == 0,
        "original disconnect result never creates a successful report");
    check(state(first).status == lease::Status::revoked && state(first).reason == lease::Reason::source_unavailable &&
        state(first).source_released, "observed original disconnect revokes and releases source");
    unavailable(first, lease::Reason::source_unavailable);
    (void)frame(130);
    const auto next = lease_request(22); (void)frame(140); const auto replacement = sample(next, 22);
    check(replacement.source_epoch != original.source_epoch, "positively observed disconnect/reconnect changes source epoch");
    check(replacement.user == original.user, "epoch change is observed slot continuity, not physical-device identity");
    release(next, 22); no_actor_calls();
}
void refusal(std::string_view name) {
    prime(100); const auto handle = lease_request(); (void)frame(110); (void)sample(handle);
    Frame f = physical();
    if (name == "original_failure") f.original = ERROR_GEN_FAILURE;
    else if (name == "returned_failure") f.returned = ERROR_GEN_FAILURE;
    else if (name == "raw_mismatch") f.transformed.wButtons ^= 0x0040;
    else if (name == "scripted_equal") f.clean = false;
    else if (name == "null_output") f.null_output = true;
    else { check(false, "unknown original-path fixture case"); }
    const auto output = frame(120, f);
    check(output.value.dwPacketNumber == f.prior_packet &&
        std::memcmp(&output.value.Gamepad, &f.transformed, sizeof(f.transformed)) == 0,
        "refusing original/returned/filter path is never cleared or replaced by observation lease");
    const auto stopped = state(handle);
    check(stopped.status == lease::Status::revoked && stopped.reason == lease::Reason::source_unavailable && stopped.source_released,
        "unqualified original or transformed return revokes instead of publishing raw-looking authority");
    unavailable(handle, lease::Reason::source_unavailable); no_actor_calls();
}
void guard(std::string_view name) {
    prime(100); const auto handle = lease_request(); (void)frame(110); (void)sample(handle);
    lease::Reason expected{};
    if (name == "focus") { env.focus = false; expected = lease::Reason::focus_lost; }
    else if (name == "gameplay") { env.gameplay = false; expected = lease::Reason::gameplay_inactive; }
    else if (name == "menu") { env.menu = false; expected = lease::Reason::menu_open; }
    else if (name == "interference") { env.interference = false; expected = lease::Reason::interference; }
    else if (name == "readiness") { env.wall = 120; service::tick(1, 2, false); expected = lease::Reason::client_not_ready; }
    else { check(false, "unknown guard fixture"); }
    env.wall = 120; unavailable(handle, expected);
    env.focus = env.gameplay = env.menu = env.interference = true;
    service::tick(1, 2, true);
    check(state(handle).status == lease::Status::revoked && state(handle).reason == expected && state(handle).source_released,
        "guard loss retains its precise terminal reason after environment recovers");
    unavailable(handle, expected); no_actor_calls();
}
void admission() {
    lease::Handle handle{999}; lease::Reason reason{};
    check(!service::lease_request(0, 0, handle, reason) && !handle.sequence && reason == lease::Reason::invalid_owner,
        "zero owner refuses and clears prior handle");
    check(!service::lease_request(21, 4, handle, reason) && reason == lease::Reason::invalid_source,
        "invalid selected user refuses without observation");
    check(!service::lease_request(21, 0, handle, reason) && reason == lease::Reason::client_not_ready,
        "no observed client context cannot request lease");
    service::tick(1, 2, true);
    check(!service::lease_request(21, 0, handle, reason) && reason == lease::Reason::source_unavailable,
        "readiness alone never invents source connection");
    (void)frame(101);
    env.thread_override = GetCurrentThreadId() + 1;
    check(!service::lease_request(21, 0, handle, reason) && reason == lease::Reason::wrong_thread,
        "other thread cannot acquire source authority");
    env.thread_override = 0; handle = lease_request(); (void)frame(110); const auto observed = sample(handle);
    env.thread_override = GetCurrentThreadId() + 1;
    unavailable(handle, lease::Reason::wrong_thread);
    check(!service::lease_renew(21, handle, observed, reason) && reason == lease::Reason::wrong_thread,
        "other thread cannot refresh a retained lease");
    env.thread_override = 0;
    unavailable(handle, lease::Reason::unavailable, 22);
    check(!service::lease_release(22, handle, reason) && !service::lease_acknowledge(22, handle, reason),
        "foreign owner cannot release or acknowledge observed source");
    check(!service::lease_acknowledge(21, handle, reason), "active observation cannot be acknowledged early");
    release(handle); no_actor_calls();
}
void context() {
    prime(100); const auto handle = lease_request(); (void)frame(110); const auto before = sample(handle);
    env.wall = 120; service::tick(1, 9, true);
    check(state(handle).status == lease::Status::revoked && state(handle).reason == lease::Reason::context_changed,
        "observed client replacement revokes current source context");
    lease::Handle blocked; lease::Reason reason{};
    check(!service::lease_request(22, 0, blocked, reason) && reason == lease::Reason::context_changed,
        "old source report cannot be relabeled as replacement context");
    (void)frame(130); const auto next = lease_request(22); (void)frame(140); const auto after = sample(next, 22);
    check(after.context_generation != before.context_generation && after.source_epoch == before.source_epoch,
        "context and observed connection epochs remain distinct rather than inventing disconnect");
    release(next, 22); no_actor_calls();
}
void renewal() {
    prime(100); const auto handle = lease_request(); (void)frame(110); const auto first = sample(handle);
    lease::Reason reason{}; auto forged = first; ++forged.source_epoch;
    check(!service::lease_renew(21, handle, forged, reason) && reason == lease::Reason::stale_epoch,
        "caller supplied epochs cannot renew");
    forged = first; ++forged.pad.buttons;
    check(!service::lease_renew(21, handle, forged, reason) && reason == lease::Reason::stale_epoch,
        "altered source contents cannot renew an issued snapshot");
    check(service::lease_renew(21, handle, first, reason), "exact issued current observation renews once");
    check(!service::lease_renew(21, handle, first, reason) && reason == lease::Reason::stale_epoch,
        "replay cannot keep source alive indefinitely");
    (void)frame(150); const auto second = sample(handle);
    check(!service::lease_renew(21, handle, first, reason) && reason == lease::Reason::stale_epoch,
        "older issued snapshot cannot replace most recently read opaque snapshot");
    check(service::lease_renew(21, handle, second, reason) && state(handle).renewals == 2,
        "strictly advancing real observation permits next renewal");
    (void)frame(160); const auto unrenewed = sample(handle);
    (void)frame(210); env.wall = 261;
    check(!service::lease_renew(21, handle, unrenewed, reason) && reason == lease::Reason::source_stale,
        "fresh newer cache does not make last issued older snapshot young again");
    const auto newest = sample(handle);
    check(newest.observed_ms == 210 && service::lease_renew(21, handle, newest, reason),
        "new actual read supplies the correct fresh renewal proof");
    release(handle); no_actor_calls();
}
void stale_source() {
    prime(100); const auto handle = lease_request(); (void)frame(110); (void)sample(handle);
    env.wall = 211; unavailable(handle, lease::Reason::source_stale);
    check(state(handle).status == lease::Status::expired && state(handle).reason == lease::Reason::source_stale && state(handle).source_released,
        "source freshness expires independently of longer request TTL");
    no_actor_calls();
}
void clocks(std::string_view name) {
    prime(100); const auto handle = lease_request(); (void)frame(110); const auto before = sample(handle);
    lease::Reason expected{};
    if (name == "clock_regression") { env.wall = 109; expected = lease::Reason::stale_epoch; }
    else if (name == "old_original") {
        Frame delayed; delayed.original_ms = 105;
        const auto output = frame(120, delayed);
        check(output.value.dwPacketNumber == delayed.prior_packet && output.value.Gamepad.wButtons == 0,
            "delayed old original completion does not write new input");
        check(sample(handle) == before && state(handle).status == lease::Status::active &&
            state(handle).last_observation == before.observation_serial,
            "old completion leaves newer accepted snapshot, observation ordinal and active lifecycle unchanged");
        no_actor_calls(); return;
    } else if (name == "client_tick_stale") {
        for (const auto ms : {180u, 260u, 340u}) {
            (void)frame(ms); const auto s = sample(handle); lease::Reason reason{};
            check(service::lease_renew(21, handle, s, reason), "fresh source renews within client tick eligibility window");
        }
        env.wall = 351; expected = lease::Reason::client_not_ready;
    } else { check(false, "unknown clock fixture"); }
    unavailable(handle, expected);
    env.wall = 400; service::tick(1, 2, true);
    check(state(handle).status == lease::Status::revoked && state(handle).reason == expected,
        "clock/readiness failure is retained without rebuilding authority from an old cache");
    no_actor_calls();
}
void ttl() {
    prime(100); const auto handle = lease_request();
    for (const auto ms : {150u, 230u, 310u}) { (void)frame(ms); (void)sample(handle); }
    env.wall = 350; service::tick(1, 2, true);
    check(state(handle).status == lease::Status::expired && state(handle).reason == lease::Reason::deadline,
        "continued fresh reports do not renew lease without exact owner renewal");
    unavailable(handle, lease::Reason::deadline); no_actor_calls();
}
void unload() {
    prime(100);
    for (unsigned i = 0; i < 20; ++i) {
        const auto handle = lease_request(); (void)frame(101 + i); (void)sample(handle);
        service::lease_release_all(21);
        lease::Receipt receipt; lease::Reason reason{};
        check(!service::lease_state(21, handle, receipt, reason) && reason == lease::Reason::unavailable,
            "owner unload removes observation receipt and reservation without accumulated capacity debt");
    }
    const auto handle = lease_request(22);
    service::lease_release_all(21);
    check(state(handle, 22).status == lease::Status::warming, "unloading stopped owner cannot release another VM's source");
    release(handle, 22); no_actor_calls();
}
void packet_continuity() {
    const auto pulse = press();
    const auto pressed = frame(250);
    check(pressed.value.Gamepad.wButtons == 0x1000 && pressed.value.dwPacketNumber != 7,
        "actual pulse establishes persistent packet domain before lease begins");
    check(service::cancel(1, pulse), "fixture ends report pulse");
    const auto neutral = frame(280); retire(281);
    check(service::acknowledge(1, pulse), "pulse proves neutral and retires before source lease");
    const auto before = frame(290);
    check(before.value.Gamepad.wButtons == 0 && before.value.dwPacketNumber == static_cast<DWORD>(neutral.value.dwPacketNumber + 1),
        "post-retirement revision stays in the original persistent packet domain");
    const auto handle = lease_request(); const auto leased = frame(300);
    check(leased.value.dwPacketNumber == before.value.dwPacketNumber && leased.value.Gamepad.wButtons == 0,
        "adding observation neither restarts nor double-advances the one persistent packet finalizer");
    const auto observed = sample(handle);
    check(observed.packet == 7 && observed.pad == lease::Pad{},
        "source lease sees original raw packet rather than virtualized returned packet domain");
    release(handle);
    check(frame(310).value.dwPacketNumber == leased.value.dwPacketNumber,
        "observation release does not perturb packet continuity either");
}
}

int main(int argc, char** argv) {
    if (argc != 2) { std::cerr << "one named scenario is required\n"; return 2; }
    const std::string_view name(argv[1]);
    if (name == "raw_cache") raw_cache();
    else if (name == "lanes") lanes();
    else if (name == "inflight") inflight();
    else if (name == "composition") composition();
    else if (name == "exclusion") exclusion();
    else if (name == "disconnect") disconnect();
    else if (name == "admission") admission();
    else if (name == "context") context();
    else if (name == "renewal") renewal();
    else if (name == "stale_source") stale_source();
    else if (name == "ttl") ttl();
    else if (name == "unload") unload();
    else if (name == "packet_continuity") packet_continuity();
    else if (name == "clock_regression" || name == "old_original" || name == "client_tick_stale") clocks(name);
    else if (name == "focus" || name == "gameplay" || name == "menu" || name == "interference" || name == "readiness") guard(name);
    else if (name == "original_failure" || name == "returned_failure" || name == "raw_mismatch" || name == "scripted_equal" || name == "null_output") refusal(name);
    else { std::cerr << "unknown scenario: " << name << '\n'; return 2; }
    std::cout << "input_lease_native " << name << " checks=" << checks << " native_actions=0\n";
}
