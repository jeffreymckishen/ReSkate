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
namespace actor = dingosdk::actor_control_native;
namespace control = dingosdk::actor_control;
namespace clock_policy = dingosdk::actor_clock;

// The actual Windows service is linked below against these private providers.
// Constructed actor/source facts do not qualify any real game's native guards.
namespace fixture {
unsigned checks{};
void check(bool value, const char* why) {
    ++checks;
    if (!value) { std::cerr << "game input pulse: " << why << '\n'; std::exit(1); }
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
    bool outer{true}, clean{true};
    std::uint32_t user{};
    std::uint64_t original_ms{};
};
Buffer finish(service::Poll& cookie, Frame frame) {
    Buffer output; output.value.dwPacketNumber = frame.prior_packet; output.value.Gamepad = frame.transformed;
    const auto tail = output.tail;
    service::finish(cookie, frame.outer, frame.user, frame.original,
        frame.original_ms ? frame.original_ms : env.wall, frame.raw_packet, frame.raw,
        frame.returned, &output.value, frame.clean);
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
void lifecycle() {
    model::Handle invalid{999}; model::Reason refusal{};
    check(!service::request(0, 0, 0x1000, invalid, refusal) && !invalid.sequence && refusal == model::Reason::invalid_owner,
        "invalid owner cannot leave a stale output handle");
    check(!service::request(1, 4, 0x1000, invalid, refusal) && refusal == model::Reason::invalid_source,
        "out-of-range user slot refuses before actor acquisition");
    check(!service::request(1, 0, 3, invalid, refusal) && refusal == model::Reason::invalid_button,
        "combined button bits refuse before actor acquisition");
    check(!service::request(1, 0, 0x1000, invalid, refusal) && !invalid.sequence && refusal == model::Reason::client_not_ready && !env.acquire_calls,
        "client readiness is required before source admission");
    time(100); service::tick(1, 2, true);
    check(!service::request(1, 0, 0x1000, invalid, refusal) && refusal == model::Reason::source_unavailable && !env.acquire_calls,
        "SDK does not invent a connected source without an actual successful outer observation");
    prime(100);
    env.thread_override = GetCurrentThreadId() + 1;
    check(!service::request(1, 0, 0x1000, invalid, refusal) && !invalid.sequence && refusal == model::Reason::wrong_thread && !env.acquire_calls,
        "request from an unqualified client thread refuses");
    env.thread_override = 0;
    SetLastError(0x1234); const auto h = request();
    check(GetLastError() == 0x1234, "request preserves LastError despite provider mutation");
    model::Receipt ignored;
    check(!service::read(2, h, ignored) && !service::cancel(2, h) && !service::acknowledge(2, h), "foreign owner cannot read, cancel or acknowledge");
    check(!service::acknowledge(1, h), "active request cannot be acknowledged");
    model::Handle blocked; model::Reason reason{};
    check(!service::request(2, 0, 0x2000, blocked, reason) && reason == model::Reason::busy, "global active claim interlocks another VM");
    for (const auto ms : {100u, 134u, 167u}) check(frame(ms).value.Gamepad.wButtons == 0, "neutral warmup publishes no press");
    check(frame(200).value.Gamepad.wButtons == 0x1000, "generic press publishes after qualified warmup");
    check(frame(300).value.Gamepad.wButtons == 0x1000, "bounded held report is still published before 200 ms");
    {
        time(400); service::Poll cookie; service::begin(true, 0, cookie);
        check(cookie.call.active() && env.arbiter.snapshot().in_flight == 1, "actual Call protects publication");
        check(finish(cookie, {}).value.Gamepad.wButtons == 0, "deadline publishes untouched raw neutral");
        check(!read(h).report_debt && !read(h).claim_released, "report cleanup and actor claim retirement are distinct");
        service::tick(1, 2, true);
        check(!env.arbiter.publication_allowed() && !read(h).claim_released, "claim cannot retire while a real Call is alive");
    }
    retire(401); const auto result = read(h);
    check(result.status == model::Status::released && result.press_publications == 2 && result.neutral_publications == 1 &&
        result.claim_released && !result.report_debt, "normal lifecycle records buffer witnesses and a retired claim");
    check(result.first_rejection_mask == 0 && result.first_rejection_stage == model::RejectionStage::none,
        "successful lifecycle does not invent a rejection witness");
    const auto frozen = result.observed_ms; time(500); service::tick(1, 2, true);
    check(read(h).observed_ms == frozen, "terminal read remains a historical witness");
    check(service::acknowledge(1, h) && !service::read(1, h, ignored), "only explicit safe acknowledgement removes retained record");
    const auto acquisitions = env.acquire_calls;
    (void)frame(751); // Fresh original source, but the last ready client tick was500.
    invalid = {999};
    check(!service::request(1, 0, 0x1000, invalid, refusal) && !invalid.sequence &&
        refusal == model::Reason::client_tick_stale && env.acquire_calls == acquisitions && env.arbiter.publication_allowed(),
        "stale client eligibility is distinguished from a fresh source and cannot reserve an actor");
    time(499); invalid = {999};
    check(!service::request(1, 0, 0x1000, invalid, refusal) && !invalid.sequence &&
        refusal == model::Reason::client_tick_stale && env.acquire_calls == acquisitions,
        "regressed eligibility clock refuses before source or actor access");
    prime(800); const auto after_tick = request();
    check(service::cancel(1, after_tick), "a new ready tick permits a new explicit request after stale refusal");
    retire(800);
}
void rate() {
    for (const auto ms : {100u, 300u, 500u, 700u}) {
        prime(ms); const auto h = request(); check(service::cancel(1, h), "pending request accepts stop");
        retire(ms); check(service::acknowledge(1, h), "unasserted cancellation safely acknowledges");
    }
    prime(900); model::Handle h; model::Reason reason{};
    check(!service::request(8, 0, 0x1000, h, reason) && reason == model::Reason::rate_limited && !h.sequence,
        "actual global rolling rate blocks fifth start even under another VM");
    prime(1100); h = request(8); check(service::cancel(8, h), "oldest start ages out at exactly 1000 ms");
    retire(1100); check(service::acknowledge(8, h), "aged-window request cleans up");
}
void capacity() {
    std::array<model::Handle, model::retained_capacity> retained{};
    for (std::size_t i = 0; i < retained.size(); ++i) {
        const auto ms = 100 + static_cast<std::uint64_t>(i) * 1100;
        prime(ms); retained[i] = request(); check(service::cancel(1, retained[i]), "cancel retained unasserted request");
        retire(ms);
    }
    prime(9000); model::Handle h; model::Reason reason{};
    check(!service::request(2, 0, 0x1000, h, reason) && reason == model::Reason::capacity, "eight actual retained records enforce backpressure");
    check(service::acknowledge(1, retained[0]), "safe owner acknowledgement releases one retained slot");
    h = request(2); check(h.sequence > retained.back().sequence, "reused record slot never reuses sequence");
}
void stale_inflight(bool unload) {
    const auto h = press();
    {
        time(250); service::Poll cookie; service::begin(true, 0, cookie);
        check(cookie.call.active(), "pre-original cookie owns a real Call");
        if (unload) service::release_all(1); else check(service::cancel(1, h), "cancel invalidates the in-flight generation");
        check(finish(cookie, {}).value.Gamepad.wButtons == 0, "old original cannot publish a press after stop/unload");
        check(read(h).report_debt && !read(h).claim_released, "stale generation cannot claim a neutral cleanup");
        service::tick(1, 2, true); check(!env.arbiter.publication_allowed(), "stopped call and report debt retain shared claim");
    }
    check(frame(280).value.Gamepad.wButtons == 0 && !read(h).report_debt, "new qualifying source return resolves report debt");
    retire(281);
    if (unload) { model::Receipt gone; check(!service::read(1, h, gone), "orphan is removed only after actual cleanup and claim drain"); }
    else check(read(h).status == model::Status::cancelled && service::acknowledge(1, h), "cancel outcome remains distinct from normal release");
}
void original_failure(DWORD error) {
    const auto h = press(); Frame failed; failed.original = failed.returned = error;
    failed.prior_packet = 0x12345678; failed.transformed = {0xffff, 255, 254, 1, 2, 3, 4};
    const auto output = frame(250, failed);
    check(output.value.dwPacketNumber == failed.prior_packet && std::memcmp(&output.value.Gamepad, &failed.transformed, sizeof(failed.transformed)) == 0,
        "failed original preserves every supplied output field");
    auto r = read(h); check(r.original_result_known && r.original_result == error &&
        r.original_failures == 1 && r.report_debt && r.quarantined, "disconnect keeps debt with the original error witness");
    check((r.first_rejection_mask & pulse_policy::failure_bit(pulse_policy::FailedCheck::source_fresh)) != 0 &&
        r.first_rejection_stage == model::RejectionStage::service_plan,
        "observed disconnect retains the service source rejection before core ticket invalidation");
    check(frame(280).value.Gamepad.wButtons == 0, "reconnected stream is never forced pressed");
    r = read(h); check(r.report_debt && r.quarantined && !r.claim_released, "new source epoch cannot impersonate old release");
    service::release_all(1); time(1200); service::tick(1, 2, true);
    check(read(h).orphaned && read(h).report_debt && !env.arbiter.publication_allowed(), "unload/deadline do not discard quarantined debt");
    model::Handle blocked; model::Reason reason{};
    check(!service::request(2, 0, 0x1000, blocked, reason) && reason == model::Reason::busy, "quarantine prevents another VM rearming");
}
void filter_equal_bytes() {
    const auto h = press(); Frame filtered; filtered.clean = false;
    check(frame(250, filtered).value.Gamepad.wButtons == 0, "known competing filter returns its unchanged neutral bytes");
    check(read(h).report_debt && read(h).neutral_publications == 0, "equal bytes do not turn a known filter into source cleanup");
    const auto rejected = read(h);
    check(rejected.first_rejection_mask == pulse_policy::failure_bit(pulse_policy::FailedCheck::interference) &&
        rejected.first_rejection_stage == model::RejectionStage::core_plan,
        "equal-byte filter rejection names the actual failed clean-transport check");
    (void)frame(280); check(!read(h).report_debt && read(h).neutral_publications == 1, "unfiltered same-source neutral resolves duty");
    retire(281); check(read(h).status == model::Status::revoked, "interference revocation is not normal successful completion");
    check(read(h).first_rejection_mask == rejected.first_rejection_mask &&
        read(h).first_rejection_stage == rejected.first_rejection_stage,
        "raw cleanup and retirement cannot overwrite the first failure witness");
}
void source_stale() {
    const auto h = press(); Frame old; old.original_ms = 149;
    check(frame(250, old).value.Gamepad.wButtons == 0 && read(h).report_debt, "stale original timestamp cannot assert or clear debt");
    (void)frame(280); check(!read(h).report_debt, "fresh unchanged stream can provide later raw cleanup");
    retire(281);
}
void packet_domain(bool wrap) {
    Frame value; value.prior_packet = wrap ? UINT32_MAX : 0x1234; value.raw_packet = wrap ? UINT32_MAX : 7;
    time(100); service::tick(1, 2, true);
    check(frame(100, value).value.dwPacketNumber == value.prior_packet, "inactive finalizer preserves existing capture/hidden packet tag");
    const auto h = request();
    for (const auto ms : {100u, 134u, 167u})
        check(frame(ms, value).value.dwPacketNumber == value.prior_packet, "unactivated warmup preserves tagged packet domain");
    const auto first = frame(200, value).value;
    check(first.dwPacketNumber == static_cast<DWORD>(value.prior_packet + 1) && first.Gamepad.wButtons == 0x1000,
        "first activation advances actual returned tag, including modulo wrap");
    value.raw_packet = wrap ? 0 : 8;
    const auto held = frame(300, value).value;
    check(held.dwPacketNumber == static_cast<DWORD>(first.dwPacketNumber + 1), "raw packet change is visible even when pre-finalizer tag is unchanged");
    const auto neutral = frame(400, value).value;
    check(neutral.Gamepad.wButtons == 0 && neutral.dwPacketNumber == static_cast<DWORD>(held.dwPacketNumber + 1), "same raw packet still publishes a distinct neutral release");
    retire(401); check(service::acknowledge(1, h), "retire packet-domain request");
    const auto after = frame(402, value).value;
    check(after.dwPacketNumber == static_cast<DWORD>(neutral.dwPacketNumber + 1) && after.dwPacketNumber != value.prior_packet,
        "retirement does not restore a colliding raw/tagged counter");
    Frame unrelated = value; unrelated.user = 1; unrelated.prior_packet = 0x99;
    check(frame(403, unrelated).value.dwPacketNumber == 0x99, "unrelated slot keeps its own inactive domain");
    unrelated.outer = false; unrelated.prior_packet = 0x88;
    check(frame(404, unrelated).value.dwPacketNumber == 0x88, "inner poll bypasses process publication finalizer");
}
void provider_failure(std::string_view fault) {
    prime(100);
    env.acquire_ok = fault != "acquire_failure";
    env.enable_ok = false;
    env.retire_ok = fault != "clock_retire_failure";
    model::Handle h{999}; model::Reason reason{};
    const auto expected = fault == "acquire_failure" ? model::Reason::actor_unavailable :
        fault == "clock_enable_failure" ? model::Reason::clock_unavailable : model::Reason::cleanup_pending;
    check(!service::request(1, 0, 0x1000, h, reason) && !h.sequence && reason == expected,
        "provider refusal identifies its admission phase without exposing a misleading handle");
    std::uint64_t recovery_at = 200;
    if (fault == "acquire_failure") {
        check(env.enable_calls == 0 && env.arbiter.publication_allowed(), "failed acquisition never enables clock or owns actor");
        constexpr std::array native_reasons{actor::Reason::focus_changed, actor::Reason::world_changed,
            actor::Reason::motion_owned, actor::Reason::protection_conflict};
        constexpr std::array mapped_reasons{model::Reason::focus_lost, model::Reason::actor_changed,
            model::Reason::busy, model::Reason::interference};
        for (std::size_t i = 0; i < native_reasons.size(); ++i) {
            recovery_at = 1200 + static_cast<std::uint64_t>(i) * 1100;
            prime(recovery_at); env.acquire_reason = native_reasons[i]; h = {999};
            check(!service::request(1, 0, 0x1000, h, reason) && !h.sequence && reason == mapped_reasons[i] &&
                !env.enable_calls && env.arbiter.publication_allowed(),
                "specific native acquisition reasons keep their existing classification without a claim or clock");
        }
        recovery_at += 1100;
    } else if (fault == "clock_enable_failure") check(env.retire_calls == 1 && env.arbiter.publication_allowed(), "clock-enable failure retires the already-acquired claim");
    else {
        const model::Handle private_handle{env.clock_sequence};
        check(read(private_handle).orphaned && !read(private_handle).claim_released &&
            read(private_handle).reason == model::Reason::cleanup_pending && !env.arbiter.publication_allowed(),
            "failed retirement retains an unreachable orphan claim with explicit cleanup-pending reason");
        check(!service::request(2, 0, 0x1000, h, reason) && reason == model::Reason::busy, "unresolved acquisition cleanup blocks other owners");
        env.retire_ok = true; retire(101); model::Receipt gone;
        check(!service::read(1, private_handle, gone), "later proven orphan retirement frees its retained slot");
    }
    env.acquire_ok = env.enable_ok = env.retire_ok = true;
    prime(recovery_at); h = request(2); check(service::cancel(2, h), "provider recovery permits a new nonreused request"); retire(recovery_at);
}
void publication_deadline() {
    const auto h = press(); (void)frame(299);
    time(399); service::Poll cookie; service::begin(true, 0, cookie);
    const auto before = read(h).press_publications;
    env.reads_before_jump = 1; env.jump_to = 400; // First plan sees399; pre-write recheck sees400.
    check(finish(cookie, {}).value.Gamepad.wButtons == 0, "publication-time deadline recheck prevents the expired assertion");
    const auto r = read(h);
    check(r.observed_ms == 400 && r.press_publications == before && r.neutral_publications == 1 && !r.report_debt,
        "deadline plan is not counted as an actual press buffer publication");
}
void physical_conflict() {
    const auto h = press(); Frame physical;
    physical.raw = physical.transformed = {0x1100, 1, 2, -32768, 32767, -123, 456};
    const auto out = frame(250, physical);
    check(std::memcmp(&out.value.Gamepad, &physical.raw, sizeof(physical.raw)) == 0, "actual service never clears or rewrites physical axes, triggers or held buttons");
    check(read(h).report_debt && read(h).neutral_publications == 0, "physical conflict retains potential release duty");
    (void)frame(280); retire(281);
}
void actor_clock_lost() {
    namespace observed = dingosdk::actor_observation;
    const auto h = press(); env.inspect_ok = false;
    check(frame(250).value.Gamepad.wButtons == 0 && !read(h).report_debt, "same-source raw neutral cleanup does not write or require an old actor's clock");
    const auto rejected = read(h);
    check((rejected.first_rejection_mask & pulse_policy::failure_bit(pulse_policy::FailedCheck::actor)) != 0 &&
        rejected.first_rejection_stage == model::RejectionStage::core_plan,
        "failed actor qualification is recorded at the actual service core plan");
    const auto& first = rejected.first_actor_observation;
    check(first.known && first.owner_present && first.call_active && first.inspect_attempted && !first.inspect_succeeded &&
        !first.actor_equal && !first.clock_attempted && !first.clock_known && first.inspect == env.inspect_failure,
        "failed inspection retains its real phase and records that the clock was never probed");
    retire(251); check(read(h).status == model::Status::revoked, "lost actor qualification cannot continue assertions");
    check(service::acknowledge(1, h), "retired actor-loss receipt can be explicitly acknowledged");
    env.inspect_ok = true;
    const auto clock_handle = press(1, 1200); env.clock_enabled = false;
    check(frame(1350).value.Gamepad.wButtons == 0 && !read(clock_handle).report_debt,
        "independent clock loss still permits fresh raw neutral cleanup");
    const auto clock_rejected = read(clock_handle);
    check((clock_rejected.first_rejection_mask & pulse_policy::failure_bit(pulse_policy::FailedCheck::native_clock)) != 0 &&
        (clock_rejected.first_rejection_mask & pulse_policy::failure_bit(pulse_policy::FailedCheck::actor)) == 0,
        "missing clock is distinguished from actor inspection failure");
    const auto& clock_observation = clock_rejected.first_actor_observation;
    check(clock_observation.known && clock_observation.call_active && clock_observation.inspect_attempted &&
        clock_observation.inspect_succeeded && clock_observation.actor_equal && clock_observation.clock_attempted &&
        !clock_observation.clock_known && clock_observation.enter.phase == observed::Phase::qualified &&
        clock_observation.inspect.phase == observed::Phase::qualified,
        "an actually attempted unavailable clock remains distinct from its short-circuited absence");
    retire(1351);
    check(service::acknowledge(1, clock_handle), "resolved clock-loss receipt can be acknowledged");
    for (unsigned fault = 0; fault < 4; ++fault) {
        const auto base = 2300 + static_cast<std::uint64_t>(fault) * 1100;
        prime(base); const auto handle = request();
        for (const auto offset : {0u, 34u, 67u}) (void)frame(base + offset);
        constexpr observed::Phase phases[]{observed::Phase::inspect_owner_lock, observed::Phase::controls_profile, observed::Phase::context};
        if (fault == 0) env.enter_ok = false;
        else {
            env.inspect_ok = false;
            env.inspect_failure = {phases[fault - 1], fault == 3 ? actor::Reason::context_changed : actor::Reason::unavailable};
        }
        const auto reads = env.clock_reads, inspections = env.inspect_calls;
        check(frame(base + 100).value.Gamepad.wButtons == 0, "diagnostic observations do not bypass a failed warmup guard");
        const auto receipt = read(handle); const auto witness = receipt.first_actor_observation;
        check(receipt.first_rejection_mask == (pulse_policy::failure_bit(pulse_policy::FailedCheck::actor) |
            pulse_policy::failure_bit(pulse_policy::FailedCheck::native_clock)) && !receipt.press_candidates &&
            !receipt.press_publications && !receipt.neutral_publications && env.clock_reads == reads,
            "warmup rejection preserves the existing mask and zero publications without probing the clock");
        if (fault == 0) check(witness.known && !witness.call_active && !witness.inspect_attempted &&
            env.inspect_calls == inspections && witness.enter == env.enter_failure &&
            witness.inspect.phase == observed::Phase::not_attempted, "failed call admission cannot be presented as an inspection failure");
        else check(witness.known && witness.call_active && witness.inspect_attempted && !witness.inspect_succeeded &&
            witness.inspect == env.inspect_failure, "first inspection phase and native reason survive at the real service boundary");
        env.enter_ok = env.inspect_ok = true;
        (void)frame(base + 101); retire(base + 102);
        const auto terminal = read(handle);
        check(terminal.first_actor_observation == witness && terminal.status == model::Status::revoked &&
            terminal.claim_released && !terminal.report_debt && service::acknowledge(1, handle),
            "later positive facts and cleanup do not rewrite the first actor witness or revive the same pulse");
    }
}
void environment_guards() {
    for (unsigned guard = 0; guard < 5; ++guard) {
        const auto base = 100 + static_cast<std::uint64_t>(guard) * 1100;
        const auto h = press(1, base);
        if (guard == 0) env.focus = false;
        if (guard == 1) env.gameplay = false;
        if (guard == 2) env.menu = false;
        if (guard == 3) env.interference = false;
        if (guard == 4) { time(base + 150); service::tick(1, 2, false); }
        check(frame(base + 150).value.Gamepad.wButtons == 0 && read(h).press_publications == 1,
            "each actual environment predicate stops further assertions");
        if (guard == 3) check(read(h).report_debt, "environment interference cannot masquerade as qualified cleanup");
        const auto rejected = read(h);
        if (guard < 4) {
            constexpr std::array guard_checks{pulse_policy::FailedCheck::focus, pulse_policy::FailedCheck::gameplay,
                pulse_policy::FailedCheck::menu, pulse_policy::FailedCheck::interference};
            check(rejected.first_rejection_mask == pulse_policy::failure_bit(guard_checks[guard]) &&
                rejected.first_rejection_stage == model::RejectionStage::core_plan,
                "actual failed environment check is precisely retained");
        } else check(rejected.first_rejection_mask == 0 && rejected.first_rejection_stage == model::RejectionStage::tick_ready,
            "client tick unavailability is distinct from a failed report-plan predicate");
        env.focus = env.gameplay = env.menu = env.interference = true;
        (void)frame(base + 180); retire(base + 181);
        check(read(h).first_rejection_mask == rejected.first_rejection_mask &&
            read(h).first_rejection_stage == rejected.first_rejection_stage,
            "later cleanup leaves the immutable initial rejection intact");
        check(read(h).status == model::Status::revoked && service::acknowledge(1, h),
            "guard stop remains revoked after genuine raw cleanup and claim release");
    }
}
}

int main(int argc, char** argv) {
    if (argc != 2) { std::cerr << "one named scenario is required\n"; return 2; }
    const std::string_view name(argv[1]);
    if (name == "lifecycle") lifecycle();
    else if (name == "rate") rate();
    else if (name == "capacity") capacity();
    else if (name == "cancel_inflight") stale_inflight(false);
    else if (name == "unload_inflight") stale_inflight(true);
    else if (name == "disconnect") original_failure(ERROR_DEVICE_NOT_CONNECTED);
    else if (name == "original_failure") original_failure(ERROR_GEN_FAILURE);
    else if (name == "filter_equal_bytes") filter_equal_bytes();
    else if (name == "source_stale") source_stale();
    else if (name == "packet_domain") packet_domain(false);
    else if (name == "packet_wrap") packet_domain(true);
    else if (name == "acquire_failure" || name == "clock_enable_failure" || name == "clock_retire_failure") provider_failure(name);
    else if (name == "publication_deadline") publication_deadline();
    else if (name == "physical_conflict") physical_conflict();
    else if (name == "actor_clock_lost") actor_clock_lost();
    else if (name == "environment_guards") environment_guards();
    else { std::cerr << "unknown scenario: " << name << '\n'; return 2; }
    std::cout << "game_input_pulse " << name << " checks=" << checks << " native_actions=0\n";
}
