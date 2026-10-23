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
    bool acquire_ok{true}, inspect_ok{true}, enable_ok{true}, retire_ok{true}, clock_enabled{};
    DWORD thread_override{};
    unsigned acquire_calls{}, enable_calls{}, inspect_calls{}, retire_calls{}, disable_calls{};
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
bool acquire(std::uint64_t owner, std::uint64_t sequence, Admission admission, Actor& out, Reason& reason) noexcept {
    auto& f = fixture::env; ++f.acquire_calls; out = {}; reason = Reason::unavailable;
    State state; state.known = true; state.value = 42;
    if (!f.acquire_ok || !admission || !admission(state)) return false;
    control::Ticket ticket;
    if (!f.arbiter.reserve(owner, control::Domain::equipment, ticket)) return false;
    Actor value;
    value.base = 1; value.client = 2; value.entity = 3; value.player = 4; value.player_handle = 5;
    value.component = 6; value.core = 7; value.context = 8; value.selector = 9; value.causes = 10;
    value.rig = 11; value.game_context = 12; value.world = 13; value.world_state = 14;
    value.world_generation = value.lifetime_epoch = value.actor_epoch = 1; value.ticket = ticket;
    if (!f.arbiter.publish(owner, ticket)) { (void)f.arbiter.abandon(owner, ticket); return false; }
    f.owner = owner; f.clock_sequence = sequence; f.current = value; out = value; reason = Reason::none;
    SetLastError(0x7654); // The real service must preserve its caller's error across providers.
    return true;
}
bool inspect(std::uint64_t owner, std::uint64_t sequence, const Actor& expected,
    Actor& out, State& state, Reason& reason, bool) noexcept {
    ++fixture::env.inspect_calls; out = {}; state = {}; reason = Reason::unavailable;
    if (!fixture::env.inspect_ok || !fixture::owns(owner, sequence, expected)) return false;
    out = expected; state.known = true; state.value = 42; reason = Reason::none; return true;
}
bool enter(std::uint64_t owner, std::uint64_t sequence, const Actor& value, control::Call& call) noexcept {
    return fixture::owns(owner, sequence, value) && fixture::env.arbiter.enter(owner, value.ticket, call);
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
    out = {};
    return fixture::owns(owner, sequence, value) && fixture::env.clock.read(fixture::env.clock_key, fixture::env.wall, out);
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
    check(!service::request(1, 0, 0x1000, invalid, refusal) && refusal == model::Reason::unavailable,
        "client readiness is required before source admission");
    time(100); service::tick(1, 2, true);
    check(!service::request(1, 0, 0x1000, invalid, refusal) && refusal == model::Reason::source_unavailable && !env.acquire_calls,
        "SDK does not invent a connected source without an actual successful outer observation");
    prime(100);
    env.thread_override = GetCurrentThreadId() + 1;
    check(!service::request(1, 0, 0x1000, invalid, refusal) && refusal == model::Reason::unavailable && !env.acquire_calls,
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
    const auto frozen = result.observed_ms; time(500); service::tick(1, 2, true);
    check(read(h).observed_ms == frozen, "terminal read remains a historical witness");
    check(service::acknowledge(1, h) && !service::read(1, h, ignored), "only explicit safe acknowledgement removes retained record");
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
    (void)frame(280); check(!read(h).report_debt && read(h).neutral_publications == 1, "unfiltered same-source neutral resolves duty");
    retire(281); check(read(h).status == model::Status::revoked, "interference revocation is not normal successful completion");
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
    model::Handle h; model::Reason reason{};
    check(!service::request(1, 0, 0x1000, h, reason) && !h.sequence && reason == model::Reason::unavailable, "provider failure does not expose a misleading request handle");
    if (fault == "acquire_failure") check(env.enable_calls == 0 && env.arbiter.publication_allowed(), "failed acquisition never enables clock or owns actor");
    else if (fault == "clock_enable_failure") check(env.retire_calls == 1 && env.arbiter.publication_allowed(), "clock-enable failure retires the already-acquired claim");
    else {
        const model::Handle private_handle{env.clock_sequence};
        check(read(private_handle).orphaned && !read(private_handle).claim_released && !env.arbiter.publication_allowed(), "failed retirement retains an unreachable orphan claim");
        check(!service::request(2, 0, 0x1000, h, reason) && reason == model::Reason::busy, "unresolved acquisition cleanup blocks other owners");
        env.retire_ok = true; retire(101); model::Receipt gone;
        check(!service::read(1, private_handle, gone), "later proven orphan retirement frees its retained slot");
    }
    env.acquire_ok = env.enable_ok = env.retire_ok = true;
    prime(200); h = request(2); check(service::cancel(2, h), "provider recovery permits a new nonreused request"); retire(200);
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
    const auto h = press(); env.inspect_ok = false;
    check(frame(250).value.Gamepad.wButtons == 0 && !read(h).report_debt, "same-source raw neutral cleanup does not write or require an old actor's clock");
    retire(251); check(read(h).status == model::Status::revoked, "lost actor qualification cannot continue assertions");
}
void environment_guards() {
    for (unsigned guard = 0; guard < 4; ++guard) {
        const auto base = 100 + static_cast<std::uint64_t>(guard) * 1100;
        const auto h = press(1, base);
        if (guard == 0) env.focus = false;
        if (guard == 1) env.gameplay = false;
        if (guard == 2) env.menu = false;
        if (guard == 3) env.interference = false;
        check(frame(base + 150).value.Gamepad.wButtons == 0 && read(h).press_publications == 1,
            "each actual environment predicate stops further assertions");
        if (guard == 3) check(read(h).report_debt, "environment interference cannot masquerade as qualified cleanup");
        env.focus = env.gameplay = env.menu = env.interference = true;
        (void)frame(base + 180); retire(base + 181);
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
