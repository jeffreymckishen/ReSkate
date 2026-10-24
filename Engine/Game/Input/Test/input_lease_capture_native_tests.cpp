#include "Extension/Skater/native_input_pulse.h"
#include "Extension/Skater/native_input_pulse_environment.h"
#include "Extension/Skater/actor_control.h"
#include "input_publication_atomic_cases.h"
#include <array>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string_view>

namespace service = dingosdk::native_input_pulse;
namespace model = dingosdk::game_input_pulse;
namespace pulse_policy = dingosdk::input_pulse;
namespace lease = dingosdk::input_lease;
namespace capture = dingosdk::input_lease_capture;
namespace actor = dingosdk::actor_control_native;
namespace control = dingosdk::actor_control;
namespace clock_policy = dingosdk::actor_clock;

// The actual Windows service is linked below against these private providers.
// Constructed actor/source facts do not qualify any real game's native guards.
namespace fixture {
unsigned checks{};
void check(bool value, const char* why) {
    ++checks;
    if (!value) { std::cerr << "input capture native: " << why << '\n'; std::exit(1); }
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

namespace capture_fixture {
using fixture::check;
using fixture::env;
using fixture::Buffer;
struct Frame {
    DWORD original{ERROR_SUCCESS}, returned{ERROR_SUCCESS}, raw_packet{7}, prior_packet{7};
    XINPUT_GAMEPAD raw{}, candidate{};
    std::uint64_t original_ms{};
    std::uint32_t user{};
    bool outer{true}, clean{true}, known{true};
};
struct Result { Buffer output; DWORD returned{}; };

std::uint64_t revision() {
    check(!service::publication_held(), "fixture never holds gate around original or callback staging");
    service::PublicationScope scope;
    const auto value = service::publication_revision(scope);
    check(scope.owns() && value, "actual native service supplies a valid publication revision");
    return value;
}
void changed(service::PublicationChange kind = service::PublicationChange::interference) {
    check(!service::publication_held(), "setter interleaves outside original/callback staging");
    service::PublicationScope scope;
    check(scope.owns(), "actual setter owns publication scope");
    service::publication_changed(scope, kind);
}
Frame physical(std::uint32_t user = 0) {
    Frame f; f.user = user;
    f.raw = f.candidate = {0xA905, 17, 231, -32768, 32767, -12345, 23456};
    return f;
}
Buffer original_buffer(const Frame& f) {
    Buffer out; out.value.dwPacketNumber = f.prior_packet; out.value.Gamepad = f.raw; return out;
}
DWORD finish(service::Poll& poll, const Frame& f, std::uint64_t staged, Buffer* out, bool prepared = false) {
    check(!service::publication_held(), "actor/protection preparation occurs outside publication gate");
    if (!prepared) service::prepare_finish(poll);
    else check(poll.prepared, "adversarial setter interleaves after completed actor preparation");
    XINPUT_STATE candidate{}; candidate.dwPacketNumber = f.prior_packet; candidate.Gamepad = f.candidate;
    service::PublicationScope scope;
    check(scope.owns(), "actual finalizer acquires the native gate");
    return service::finish_staged(poll, scope, f.outer, f.user, f.original,
        f.original_ms ? f.original_ms : env.wall, f.raw_packet, f.raw,
        f.returned, candidate, staged, out ? &out->value : nullptr, f.clean, f.known);
}
Result frame(std::uint64_t ms, Frame f = {}) {
    fixture::time(ms);
    service::Poll poll; service::begin(f.outer, f.user, poll);
    Result result; result.output = original_buffer(f); const auto tail = result.output.tail;
    result.returned = finish(poll, f, revision(), &result.output);
    check(result.output.tail == tail, "actual staged finalizer preserves trailing buffer canaries");
    return result;
}
void prime(std::uint64_t ms) {
    fixture::time(ms); service::tick(1, 2, true); (void)frame(ms);
}
lease::Handle lease_request(std::uint64_t owner = 21) {
    lease::Handle handle; lease::Reason reason{};
    check(service::lease_request(owner, 0, handle, reason) && handle.sequence && reason == lease::Reason::none,
        "fresh staged original source admits observation lease");
    return handle;
}
lease::Snapshot sample(lease::Handle handle, std::uint64_t owner = 21) {
    lease::Snapshot snapshot; lease::Reason reason{};
    check(service::lease_read(owner, handle, snapshot, reason) && snapshot.handle == handle,
        "actual broker issues exact observed snapshot");
    return snapshot;
}
capture::Receipt state(lease::Handle handle, std::uint64_t owner = 21) {
    capture::Receipt receipt;
    check(service::capture_state(owner, handle, receipt) && receipt.key.owner == owner &&
        receipt.key.lease_sequence == handle.sequence, "owner reads actual native capture receipt");
    return receipt;
}
lease::Handle arm(std::uint64_t base = 100, bool active = true, std::uint64_t owner = 21) {
    prime(base); const auto handle = lease_request(owner);
    (void)frame(base + 10); const auto snapshot = sample(handle, owner);
    capture::Reason reason{};
    check(service::capture_request(owner, handle, snapshot, reason) && reason == capture::Reason::none,
        "capture admits only exact issued selected-source snapshot");
    check(state(handle, owner).phase == capture::Phase::waiting_neutral && !state(handle, owner).debt,
        "admission waits for a later fresh neutral without invented report debt");
    if (active) {
        const auto first = frame(base + 20);
        check(first.returned == ERROR_SUCCESS && first.output.value.Gamepad.wButtons == 0 &&
            state(handle, owner).phase == capture::Phase::capturing && state(handle, owner).debt &&
            state(handle, owner).publications == 1, "first actual neutral publication starts capture and retains handoff debt");
    }
    return handle;
}
void no_actor_calls() {
    check(env.acquire_calls == 0 && env.inspect_calls == 0 && env.enable_calls == 0 && env.retire_calls == 0 &&
        env.disable_calls == 0 && env.clock_reads == 0, "capture never acquires or clocks a second ActorArbiter claim");
}
void no_lease_read(lease::Handle handle, std::uint64_t owner = 21) {
    lease::Snapshot snapshot; lease::Reason reason{};
    check(!service::lease_read(owner, handle, snapshot, reason) && !snapshot.handle.sequence,
        "invalidated source authority cannot be read as fresh controls");
}
void source_cleanup(lease::Handle handle, std::uint64_t owner = 21) {
    lease::Receipt receipt; lease::Reason reason{};
    if (service::lease_state(owner, handle, receipt, reason)) {
        if (!lease::terminal(receipt.status))
            check(service::lease_release(owner, handle, reason), "owner releases passive observation after capture handoff");
        check(service::lease_acknowledge(owner, handle, reason), "terminal observation receipt acknowledges after cleanup");
    }
}
void handoff(lease::Handle handle, std::uint64_t owner = 21) {
    auto receipt = state(handle, owner);
    if (receipt.phase == capture::Phase::capturing || receipt.phase == capture::Phase::waiting_neutral)
        check(service::capture_release(owner, handle), "owner explicitly ends capture");
    receipt = state(handle, owner);
    if (receipt.phase != capture::Phase::complete) {
        (void)frame(env.wall + 10);
        receipt = state(handle, owner);
    }
    check(receipt.phase == capture::Phase::complete && !receipt.debt,
        "clean fresh same-source neutral completes actual handoff");
    check(service::capture_acknowledge(owner, handle), "capture acknowledges only after handoff and poll drain");
    source_cleanup(handle, owner);
}

// A readable private buffer whose entire page refuses writes makes the actual
// service SEH publication path fail deterministically. This does not depend on
// an instruction-specific partial store or touch any game memory.
class ReadonlyOutput {
public:
    explicit ReadonlyOutput(const Buffer& value) {
        value_ = static_cast<Buffer*>(VirtualAlloc(nullptr, sizeof(Buffer), MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE));
        check(value_ != nullptr, "fixture allocates its own output buffer");
        *value_ = value;
        DWORD prior{};
        check(VirtualProtect(value_, sizeof(Buffer), PAGE_READONLY, &prior) != FALSE,
            "fixture makes private output readable but unwriteable");
    }
    ~ReadonlyOutput() { if (value_) (void)VirtualFree(value_, 0, MEM_RELEASE); }
    ReadonlyOutput(const ReadonlyOutput&) = delete;
    ReadonlyOutput& operator=(const ReadonlyOutput&) = delete;
    Buffer* get() const noexcept { return value_; }
private:
    Buffer* value_{};
};

void lifecycle() {
    const auto handle = arm();
    const auto input = physical(); const auto output = frame(130, input);
    check(output.returned == ERROR_SUCCESS,
        "successful source transport remains successful during capture");
    const XINPUT_GAMEPAD neutral{};
    check(std::memcmp(&output.output.value.Gamepad, &neutral, sizeof(neutral)) == 0,
        "actual selected-source report suppresses all physical buttons, triggers and axes");
    const auto observed = sample(handle);
    check(observed.pad == lease::Pad{0xA905, 17, 231, -32768, 32767, -12345, 23456},
        "mapper source cache keeps original raw controls separately from neutral returned report");
    check(!service::capture_release(22, handle) && !service::capture_acknowledge(22, handle),
        "foreign owner cannot release or acknowledge capture");
    capture::Receipt foreign;
    check(!service::capture_state(22, handle, foreign), "foreign owner cannot read capture receipt");
    handoff(handle); no_actor_calls();
}
void staged_race(bool warming, bool fail_write) {
    const auto handle = arm(100, !warming);
    fixture::time(130); Frame f = physical(); f.candidate.wButtons = 0x1000; f.clean = false;
    {
        service::Poll poll; service::begin(true, 0, poll);
        const auto staged = revision();
        service::prepare_finish(poll);
        check(poll.prepared && !service::publication_held(), "race prepares actor facts before setter and final gate acquisition");
        changed();
        if (warming) {
            check(state(handle).phase == capture::Phase::complete && !state(handle).debt,
                "setter alone completes an unasserted waiting request before the stale fallback attempts a write");
            check(!service::capture_acknowledge(21, handle),
                "outer source poll retains a completed waiting key before stale fallback can restore attempted-write debt");
        }
        Buffer output = original_buffer(f); const auto before = output;
        if (fail_write) {
            ReadonlyOutput denied(output);
            check(finish(poll, f, staged, denied.get(), true) == ERROR_SUCCESS, "uncertain fallback never changes successful original result");
            check(std::memcmp(denied.get(), &before, sizeof(before)) == 0, "failed owned write leaves fixture's readonly buffer unchanged");
        } else {
            check(finish(poll, f, staged, &output, true) == ERROR_SUCCESS, "revision race preserves original success transport");
            const XINPUT_GAMEPAD neutral{};
            check(std::memcmp(&output.value.Gamepad, &neutral, sizeof(neutral)) == 0 && output.tail == before.tail,
                "stale scripted candidate is bounded to neutral before the actual output publication");
        }
        const auto receipt = state(handle);
        check(receipt.phase == capture::Phase::releasing && receipt.debt,
            "stale stage fallback retains owned neutralization debt including waiting admission");
        if (fail_write) check(receipt.reason == capture::Reason::publication_unconfirmed,
            "attempted fallback write records unconfirmed publication rather than successful cleanup");
        check(!service::capture_acknowledge(21, handle), "in-flight stale poll cannot discard retained capture key");
    }
    no_lease_read(handle); handoff(handle); no_actor_calls();
}
void failed_owned_write() {
    const auto handle = arm(); const auto before = state(handle);
    fixture::time(130); const auto f = physical();
    {
        service::Poll poll; service::begin(true, 0, poll);
        ReadonlyOutput denied(original_buffer(f));
        check(finish(poll, f, revision(), denied.get()) == ERROR_SUCCESS, "failed capture buffer publication preserves transport result");
        const auto stopped = state(handle);
        check(stopped.phase == capture::Phase::releasing && stopped.debt &&
            stopped.reason == capture::Reason::publication_unconfirmed && stopped.publications == before.publications &&
            stopped.neutral_releases == 0, "uncertain owned write retains debt without inventing a neutral publication witness");
    }
    handoff(handle); no_actor_calls();
}
void original_failure(bool stale_stage) {
    const auto handle = arm(); const auto before = state(handle);
    fixture::time(130); Frame f; f.original = ERROR_DEVICE_NOT_CONNECTED; f.returned = ERROR_SUCCESS;
    f.known = false; f.clean = false; f.candidate = physical().candidate;
    Buffer out = original_buffer(f); out.value.Gamepad = {0x4321, 7, 9, 1, 2, 3, 4}; const auto supplied = out;
    {
        service::Poll poll; service::begin(true, 0, poll);
        const auto staged = revision();
        if (stale_stage) {
            changed();
            check(finish(poll, f, staged, &out) == ERROR_DEVICE_NOT_CONNECTED,
                "stale scripted returned success cannot replace original failure with successful transport");
            check(std::memcmp(&out, &supplied, sizeof(out)) == 0,
                "failed original with stale stage leaves every caller-supplied report byte and canary unchanged");
        } else {
            check(finish(poll, f, staged, &out) == ERROR_SUCCESS && out.tail == supplied.tail &&
                std::memcmp(&out.value.Gamepad, &f.candidate, sizeof(f.candidate)) == 0,
                "current scripted stand-in retains its legacy success/report as competitor passthrough");
        }
    }
    const auto stopped = state(handle);
    check(stopped.debt && stopped.publications == before.publications && stopped.neutral_releases == 0,
        "original failure cannot discharge debt or create publication evidence");
    no_lease_read(handle); no_actor_calls();
}
void unknown_original(bool stale_stage) {
    const auto handle = arm(100, false);
    fixture::time(130); Frame f = physical(); f.known = false;
    Buffer out = original_buffer(f); const auto supplied = out;
    {
        service::Poll poll; service::begin(true, 0, poll);
        const auto staged = revision();
        if (stale_stage) changed();
        check(finish(poll, f, staged, &out) == ERROR_SUCCESS && std::memcmp(&out, &supplied, sizeof(out)) == 0,
            "successful original without a readable raw copy preserves transport and every caller byte");
        const auto stopped = state(handle);
        check(stopped.phase == capture::Phase::complete && !stopped.debt && stopped.publications == 0 &&
            stopped.neutral_releases == 0, "unavailable raw copy never attempts or charges owned neutralization debt");
        no_lease_read(handle);
        check(!service::capture_acknowledge(21, handle), "unasserted capture key remains retained while source poll is live");
    }
    check(service::capture_acknowledge(21, handle), "unasserted unknown-copy capture acknowledges after poll drain");
    source_cleanup(handle); no_actor_calls();
}
void owner_release() {
    const auto handle = arm(); lease::Reason reason{};
    check(service::lease_release(21, handle, reason), "passive owner release requests capture handoff too");
    no_lease_read(handle);
    check(state(handle).phase == capture::Phase::releasing && state(handle).debt,
        "source owner release retains native report debt independently of readable lease");
    (void)frame(130, physical(1));
    check(state(handle).debt && state(handle).neutral_releases == 0, "another source cannot discharge selected-source handoff");
    handoff(handle); no_actor_calls();
}
void source_epoch() {
    const auto handle = arm();
    Frame failed; failed.original = failed.returned = ERROR_DEVICE_NOT_CONNECTED; failed.known = false;
    (void)frame(130, failed);
    (void)frame(140);
    const auto stopped = state(handle);
    check(stopped.phase == capture::Phase::releasing && stopped.debt && stopped.quarantined && stopped.neutral_releases == 0,
        "reconnected source epoch cannot impersonate old selected-source neutral release");
    check(!service::capture_acknowledge(21, handle), "quarantined old-source debt cannot acknowledge");
    model::Handle blocked; model::Reason reason{};
    check(!service::request(55, 0, 0x1000, blocked, reason) && reason == model::Reason::busy && !env.acquire_calls,
        "quarantined capture debt blocks pulse admission before actor access");
    no_actor_calls();
}
void pulse_exclusion() {
    const auto handle = arm(); model::Handle blocked; model::Reason reason{};
    check(!service::request(55, 0, 0x1000, blocked, reason) && reason == model::Reason::busy && !env.acquire_calls,
        "active capture excludes pulse without obtaining second actor claim");
    check(service::capture_release(21, handle), "fixture requests handoff before pulse");
    check(!service::request(55, 0, 0x1000, blocked, reason) && reason == model::Reason::busy,
        "releasing capture debt keeps pulse exclusion until neutral handoff");
    handoff(handle);
    const auto pulse = fixture::request(55);
    check(env.acquire_calls == 1, "completed capture allows later pulse actor admission");
    lease::Handle lease_blocked; lease::Reason lease_reason{};
    check(!service::lease_request(21, 0, lease_blocked, lease_reason) && lease_reason == lease::Reason::busy,
        "pulse excludes source/capture admission in the opposite direction");
    check(service::cancel(55, pulse), "fixture cancels unstarted pulse");
    fixture::retire(env.wall + 1);
    check(service::acknowledge(55, pulse), "pulse claim cleanup remains independent after capture");
}
void packet_continuity() {
    const auto handle = arm();
    const auto first = frame(130);
    const auto same = frame(140);
    check(first.output.value.dwPacketNumber == same.output.value.dwPacketNumber,
        "unchanged captured report cannot double-advance one persistent packet finalizer");
    const auto changed_raw = frame(150, physical());
    check(changed_raw.output.value.dwPacketNumber == static_cast<DWORD>(same.output.value.dwPacketNumber + 1),
        "one raw report change advances existing finalizer exactly once even while all output is neutral");
    const auto raw = sample(handle);
    check(raw.packet == 7 && raw.pad.buttons == 0xA905, "capture cache retains original packet and buttons");
    check(service::capture_release(21, handle), "fixture requests packet-domain handoff");
    const auto neutral = frame(160);
    check(neutral.output.value.dwPacketNumber == static_cast<DWORD>(changed_raw.output.value.dwPacketNumber + 1),
        "capture stop and raw neutral share one packet translation instead of two writers");
    handoff(handle);
    const auto after = frame(170);
    check(after.output.value.dwPacketNumber != 7,
        "capture acknowledgement never restores a colliding raw packet counter");
    no_actor_calls();
}
enum class HeldPhase { capturing, releasing, complete };
void delayed(HeldPhase phase, bool neutral_raw, bool long_delay = false, bool equal_stamp = false) {
    const auto handle = arm();
    fixture::time(130); Frame old = neutral_raw ? Frame{} : physical(); old.original_ms = equal_stamp ? 140 : 130;
    {
        service::Poll poll; service::begin(true, 0, poll);
        if (phase != HeldPhase::capturing)
            check(service::capture_release(21, handle), "fixture begins handoff while earlier source poll remains live");
        lease::Snapshot accepted;
        if (!long_delay) {
            (void)frame(140, phase == HeldPhase::complete ? Frame{} : physical());
            if (phase == HeldPhase::capturing) accepted = sample(handle);
        }
        const auto before = state(handle);
        lease::Receipt source_before; lease::Reason source_reason{};
        check(service::lease_state(21, handle, source_before, source_reason), "fixture retains source receipt before delayed continuation");
        if (phase == HeldPhase::complete) {
            check(before.phase == capture::Phase::complete && !before.debt && before.neutral_releases == 1,
                "newer real neutral completes handoff while older captured poll is still outstanding");
            check(!service::capture_acknowledge(21, handle), "outstanding old captured poll retains the completed key");
        }
        env.wall = long_delay ? 250 : 150;
        Buffer out = original_buffer(old); const auto tail = out.tail;
        // The external stage may finish after a setter/newer original. Give it
        // the current revision so lifecycle-cookie protection is exercised
        // independently of the already-covered stale-stage neutral fallback.
        check(finish(poll, old, revision(), &out) == ERROR_SUCCESS, "delayed known original retains successful transport");
        const XINPUT_GAMEPAD neutral{};
        check(std::memcmp(&out.value.Gamepad, &neutral, sizeof(neutral)) == 0 && out.tail == tail,
            "captured continuation remains full neutral without touching canaries");
        const auto after = state(handle);
        check(after.debt && after.neutral_releases == before.neutral_releases && after.publications == before.publications + 1,
            "delayed publication records only its actual write and cannot discharge prior same-key debt");
        check(after.phase == (phase == HeldPhase::capturing && !long_delay ? capture::Phase::capturing : capture::Phase::releasing),
            "valid capturing continuation stays capturing; stopped, completed or over-age continuation retains releasing debt");
        lease::Receipt source_after;
        check(service::lease_state(21, handle, source_after, source_reason), "owner retains source receipt after continuation");
        if (phase == HeldPhase::capturing && equal_stamp && !long_delay) {
            check(source_after.last_observation > source_before.last_observation &&
                source_after.observed_ms == source_before.observed_ms && source_after.renewals == source_before.renewals,
                "equal-millisecond capturing report advances serialized finalizer ordinal without a hardware chronology claim");
            const auto current = sample(handle);
            const auto expected = neutral_raw ? lease::Pad{} : lease::Pad{0xA905, 17, 231, -32768, 32767, -12345, 23456};
            check(current.observation_serial > accepted.observation_serial && current.observed_ms == accepted.observed_ms &&
                current.source_epoch == accepted.source_epoch && current.pad == expected,
                "equal-stamp controls remain qualified in honest finalizer order while capture keeps the returned report neutral");
        } else {
            check(source_after.last_observation == source_before.last_observation && source_after.observed_ms == source_before.observed_ms &&
                source_after.renewals == source_before.renewals,
                "historical or over-age continuation cannot advance accepted source cache, observation ordinal or renewal count");
            if (phase == HeldPhase::capturing && !long_delay)
                check(sample(handle) == accepted, "older timestamp leaves the newer readable controls snapshot intact");
            else no_lease_read(handle);
        }
        check(!service::capture_acknowledge(21, handle), "held old continuation cannot acknowledge the debt it just retained");
    }
    handoff(handle); no_actor_calls();
}
void preacquire_inflight() {
    prime(100); const auto handle = lease_request(); (void)frame(110); const auto old = sample(handle);
    capture::Reason reason{};
    {
        fixture::time(115); service::Poll earlier; service::begin(true, 0, earlier);
        check(!service::capture_request(21, handle, old, reason) && reason == capture::Reason::busy,
            "unbound earlier selected-source poll prevents capture acquisition without waiting or mutation");
        capture::Receipt none;
        check(!service::capture_state(21, handle, none) && sample(handle) == old,
            "busy admission leaves source authority intact and creates no capture request or debt");
        env.wall = 120; Buffer out = original_buffer({});
        check(finish(earlier, {}, revision(), &out) == ERROR_SUCCESS,
            "pre-acquire source original completes normally before admission can be retried");
    }
    check(!service::capture_request(21, handle, old, reason), "pre-drain issued snapshot cannot impersonate the newer completed report");
    const auto fresh = sample(handle);
    {
        fixture::time(125); service::Poll other; service::begin(true, 1, other);
        check(service::capture_request(21, handle, fresh, reason), "another controller's outstanding poll does not block selected-source capture");
        check(state(handle).phase == capture::Phase::waiting_neutral && !state(handle).debt,
            "successful retry still waits for its own later neutral report");
        Frame unrelated; unrelated.user = 1; Buffer out = original_buffer(unrelated);
        check(finish(other, unrelated, revision(), &out) == ERROR_SUCCESS && !state(handle).debt,
            "other-source completion cannot start selected-source capture");
    }
    (void)frame(130);
    check(state(handle).phase == capture::Phase::capturing && state(handle).debt,
        "fresh selected-source neutral starts capture only after the admission barrier drains");
    handoff(handle); no_actor_calls();
}
void postcomplete_new_call() {
    const auto handle = arm();
    check(service::capture_release(21, handle), "fixture releases capture before any new source call begins");
    (void)frame(140);
    const auto completed = state(handle);
    check(completed.phase == capture::Phase::complete && !completed.debt, "real neutral handoff completes before later call begins");
    {
        fixture::time(150); service::Poll later; service::begin(true, 0, later);
        check(later.capture_key == capture::Key{}, "new post-completion source call cannot inherit obsolete retained capture key");
        const auto staged = revision();
        (void)frame(160, physical());
        env.wall = 170; auto old = physical(); old.original_ms = 150;
        Buffer out = original_buffer(old); const auto tail = out.tail;
        check(finish(later, old, staged, &out) == ERROR_SUCCESS && out.tail == tail &&
            std::memcmp(&out.value.Gamepad, &old.candidate, sizeof(old.candidate)) == 0,
            "late original from a newly begun unowned call remains ordinary passthrough");
        const auto unchanged = state(handle);
        check(unchanged.phase == capture::Phase::complete && !unchanged.debt &&
            unchanged.publications == completed.publications && unchanged.neutral_releases == completed.neutral_releases,
            "post-completion call never reopens obsolete capture debt or creates owned publication evidence");
    }
    check(service::capture_acknowledge(21, handle), "completed retained capture acknowledges after ordinary later calls drain");
    source_cleanup(handle); no_actor_calls();
}
void publication_atomic() {
    std::uint64_t base{}; lease::Handle handle;
    const auto arm_case = [&]() { base += 1000; handle = arm(base); };
    const auto conclude = [&](bool invalidated) {
        const auto receipt = state(handle);
        if (invalidated) {
            no_lease_read(handle);
            check(receipt.phase == capture::Phase::releasing && receipt.debt,
                "actual atomic setter invalidates source authority and retains armed capture debt");
        } else {
            (void)sample(handle);
            check(receipt.phase == capture::Phase::capturing && receipt.debt,
                "unchanged value or invalid token preserves actual source and capture authority");
        }
        handoff(handle);
    };
    dingosdk::input_publication_atomic_test::run_publication_atomic_cases(check, arm_case, conclude);
    no_actor_calls();
}
}

#ifndef DINGOSDK_CAPTURE_NATIVE_NO_MAIN
int main(int argc, char** argv) {
    if (argc != 2) { std::cerr << "one named capture scenario is required\n"; return 2; }
    const std::string_view name(argv[1]);
    if (name == "lifecycle") capture_fixture::lifecycle();
    else if (name == "staged_race") capture_fixture::staged_race(false, false);
    else if (name == "staged_race_failed_write") capture_fixture::staged_race(false, true);
    else if (name == "warming_race_failed_write") capture_fixture::staged_race(true, true);
    else if (name == "failed_owned_write") capture_fixture::failed_owned_write();
    else if (name == "original_failure") capture_fixture::original_failure(true);
    else if (name == "original_failure_passthrough") capture_fixture::original_failure(false);
    else if (name == "unknown_original") capture_fixture::unknown_original(false);
    else if (name == "unknown_original_stale") capture_fixture::unknown_original(true);
    else if (name == "owner_release") capture_fixture::owner_release();
    else if (name == "source_epoch") capture_fixture::source_epoch();
    else if (name == "pulse_exclusion") capture_fixture::pulse_exclusion();
    else if (name == "packet_continuity") capture_fixture::packet_continuity();
    else if (name == "older_capturing_held") capture_fixture::delayed(capture_fixture::HeldPhase::capturing, false);
    else if (name == "older_capturing_neutral") capture_fixture::delayed(capture_fixture::HeldPhase::capturing, true);
    else if (name == "older_releasing_held") capture_fixture::delayed(capture_fixture::HeldPhase::releasing, false);
    else if (name == "older_releasing_neutral") capture_fixture::delayed(capture_fixture::HeldPhase::releasing, true);
    else if (name == "older_complete_held") capture_fixture::delayed(capture_fixture::HeldPhase::complete, false);
    else if (name == "older_complete_neutral") capture_fixture::delayed(capture_fixture::HeldPhase::complete, true);
    else if (name == "long_delay_held") capture_fixture::delayed(capture_fixture::HeldPhase::capturing, false, true);
    else if (name == "long_delay_neutral") capture_fixture::delayed(capture_fixture::HeldPhase::capturing, true, true);
    else if (name == "equal_capturing_held") capture_fixture::delayed(capture_fixture::HeldPhase::capturing, false, false, true);
    else if (name == "equal_capturing_neutral") capture_fixture::delayed(capture_fixture::HeldPhase::capturing, true, false, true);
    else if (name == "equal_releasing_held") capture_fixture::delayed(capture_fixture::HeldPhase::releasing, false, false, true);
    else if (name == "equal_releasing_neutral") capture_fixture::delayed(capture_fixture::HeldPhase::releasing, true, false, true);
    else if (name == "equal_complete_held") capture_fixture::delayed(capture_fixture::HeldPhase::complete, false, false, true);
    else if (name == "equal_complete_neutral") capture_fixture::delayed(capture_fixture::HeldPhase::complete, true, false, true);
    else if (name == "preacquire_inflight") capture_fixture::preacquire_inflight();
    else if (name == "postcomplete_new_call") capture_fixture::postcomplete_new_call();
    else if (name == "publication_atomic") capture_fixture::publication_atomic();
    else { std::cerr << "unknown capture scenario: " << name << '\n'; return 2; }
    std::cout << "input_lease_capture_native " << name << " checks=" << fixture::checks << " native_actions=0\n";
}
#endif
