#include "native_input_pulse.h"
#include "actor_control.h"
#include "native_input_pulse_environment.h"
#include "Engine/Game/Input/input_lease_policy.h"
#include <array>
#include <atomic>
#include <limits>

namespace dingosdk::native_input_pulse {
namespace {
namespace model = game_input_pulse;
namespace policy = input_pulse;
namespace lease = input_lease;
namespace capture = input_lease_capture;
using Actor = actor_control_native::Actor;
constexpr std::size_t no_entry = model::retained_capacity;
struct LastError {
    DWORD value = GetLastError();
    ~LastError() { SetLastError(value); }
};
struct Lock {
    SRWLOCK& lock;
    explicit Lock(SRWLOCK& value) noexcept : lock(value) { AcquireSRWLockExclusive(&lock); }
    ~Lock() { ReleaseSRWLockExclusive(&lock); }
};
struct Source {
    std::uint64_t epoch{}, observed_ms{};
    bool connected{};
    policy::PacketContinuity packets;
    lease::Source observation;
    std::uint64_t in_flight{};
    bool capture_eligible{};
    // Controls a capture release finished at its bound while they were still
    // held, and the stream epoch they belong to. The capture slot is free, but
    // each stays out of this stream's reports until it is seen at rest.
    capture::Held held_back;
    std::uint64_t held_epoch{};
};
static_assert(policy::left_stick_rest == XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE &&
    policy::right_stick_rest == XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE &&
    policy::trigger_rest == XINPUT_GAMEPAD_TRIGGER_THRESHOLD, "the SDK's rest thresholds are XInput's own");
struct Entry {
    model::Receipt receipt;
    Actor actor;
    std::uint64_t owner{};
    model::Status ending{model::Status::released};
    bool occupied{}, admitting{}, started{}, rejection_recorded{};
};
struct Shared {
    SRWLOCK lock = SRWLOCK_INIT;
    std::array<Entry, model::retained_capacity> entries;
    std::array<Source, 4> sources;
    std::array<std::uint64_t, 4> starts{};
    policy::Pulse pulse;
    lease::Broker leases;
    capture::Capture capture;
    std::size_t active{no_entry};
    std::uint64_t next_sequence{1}, next_epoch{1}, eligible_at{};
    std::uint64_t next_observation{1}, next_context{1}, context_generation{};
    std::uintptr_t observed_base{}, observed_client{};
    std::uint64_t report_revision{1}, seen_pulse_revision{}, seen_capture_revision{}, seen_publication_revision{1};
    DWORD client_thread{};
    bool ready{}, capture_orphaned{};
};
Shared shared;
struct Publication {
    SRWLOCK lock = SRWLOCK_INIT;
    std::atomic<bool> failed{};
    std::uint64_t revision{1};
};
Publication publication;
thread_local const PublicationScope* publication_owner{};
struct EnvironmentFacts {
    bool focused{}, gameplay{}, menu_closed{}, interference_clear{};
};
thread_local EnvironmentFacts publication_facts;
void sample_environment(const PublicationScope& scope) noexcept {
    if (!scope.owns()) { publication_facts = {}; return; }
    // In particular interference_clear may inspect the scripted-pad mutex.
    // Every caller samples before taking Shared or another native-state mutex.
    publication_facts = {environment::focused(), environment::gameplay(),
        environment::menu_closed(), environment::interference_clear()};
}

bool capture_busy() noexcept {
    const auto& receipt = shared.capture.state();
    return shared.capture.reserved() || (receipt.phase != capture::Phase::idle &&
        receipt.key.user < 4 && shared.sources[receipt.key.user].in_flight);
}
void publication_advance() noexcept {
    if (publication.revision == std::numeric_limits<std::uint64_t>::max()) publication.failed.store(true);
    else ++publication.revision;
}
policy::Pad pad(const XINPUT_GAMEPAD& value) noexcept {
    return {value.wButtons, value.bLeftTrigger, value.bRightTrigger,
        value.sThumbLX, value.sThumbLY, value.sThumbRX, value.sThumbRY};
}
XINPUT_GAMEPAD gamepad(const policy::Pad& value) noexcept {
    return {value.buttons, value.left_trigger, value.right_trigger, value.left_x, value.left_y, value.right_x, value.right_y};
}
void increment(std::uint64_t& value) noexcept {
    if (value != std::numeric_limits<std::uint64_t>::max()) ++value;
}
void stamp(model::Receipt& receipt, std::uint64_t now) noexcept {
    if (now >= receipt.observed_ms && now >= receipt.requested_ms) receipt.observed_ms = now;
}
std::uint64_t issue(std::uint64_t& next) noexcept {
    const auto value = next;
    if (next) next = next == std::numeric_limits<std::uint64_t>::max() ? 0 : next + 1;
    return value;
}
lease::Guard lease_guard(std::uint64_t now) noexcept {
    lease::Guard guard;
    guard.now_ms = now; guard.context_generation = shared.context_generation;
    guard.ready = !publication.failed.load() && shared.ready && shared.observed_base && shared.observed_client &&
        shared.context_generation && shared.eligible_at && now >= shared.eligible_at &&
        now - shared.eligible_at <= 250;
    guard.focused = publication_facts.focused; guard.gameplay = publication_facts.gameplay;
    guard.menu_closed = publication_facts.menu_closed; guard.interference_clear = publication_facts.interference_clear;
    return guard;
}
capture::Input capture_input(const Source& source, const lease::Guard& guard,
    const policy::Pad& returned, bool has_output, DWORD original_result, DWORD returned_result) noexcept {
    capture::Input input;
    const auto& observation = source.observation;
    const auto& key = shared.capture.state().key;
    input.user = observation.user; input.source_epoch = source.epoch;
    input.context_generation = shared.context_generation;
    input.observation_serial = observation.observation_serial;
    input.observed_ms = observation.observed_ms; input.now_ms = guard.now_ms;
    input.raw = observation.pad; input.returned = returned;
    input.original_result = original_result; input.returned_result = returned_result;
    input.outer_game_poll = true; input.has_output = has_output;
    input.source_connected = source.connected;
    input.safety.source_authorized = source.capture_eligible &&
        shared.leases.accepted(key.owner, {key.lease_sequence}, observation);
    input.safety.ready = guard.ready; input.safety.focused = guard.focused;
    input.safety.gameplay = guard.gameplay; input.safety.menu_closed = guard.menu_closed;
    input.safety.interference_clear = guard.interference_clear;
    return input;
}
void capture_cleanup() noexcept {
    const auto& receipt = shared.capture.state();
    if (shared.capture_orphaned && receipt.phase == capture::Phase::complete &&
        receipt.key.user < 4 && !shared.sources[receipt.key.user].in_flight) {
        (void)shared.capture.acknowledge(receipt.key);
        shared.capture_orphaned = false;
    }
}
void capture_sync(const lease::Guard& guard) noexcept {
    const auto& receipt = shared.capture.state();
    if (receipt.phase != capture::Phase::idle && receipt.phase != capture::Phase::complete &&
        receipt.phase != capture::Phase::releasing) {
        lease::Receipt source_receipt;
        if (!shared.leases.state(receipt.key.owner, {receipt.key.lease_sequence}, source_receipt) ||
            lease::terminal(source_receipt.status)) shared.capture.revoke(capture::Reason::authority_lost);
        else if (!guard.ready) shared.capture.revoke(capture::Reason::authority_lost);
        else if (!guard.focused) shared.capture.revoke(capture::Reason::focus_lost);
        else if (!guard.gameplay) shared.capture.revoke(capture::Reason::gameplay_inactive);
        else if (!guard.menu_closed) shared.capture.revoke(capture::Reason::menu_open);
        else if (!guard.interference_clear) shared.capture.revoke(capture::Reason::interference);
        else if (receipt.key.context_generation != guard.context_generation) shared.capture.revoke(capture::Reason::context_changed);
        else if (guard.now_ms >= receipt.expires_ms) shared.capture.revoke(capture::Reason::deadline);
    }
    if (receipt.phase == capture::Phase::releasing && receipt.key.user < 4) {
        const auto& source = shared.sources[receipt.key.user];
        shared.capture.sync(guard.now_ms, source.connected && source.epoch == receipt.key.source_epoch);
    }
    capture_cleanup();
}
std::uint64_t report_revision() noexcept {
    const auto pulse_revision = shared.pulse.revision();
    const auto capture_revision = shared.capture.state().revision;
    if (pulse_revision != shared.seen_pulse_revision || capture_revision != shared.seen_capture_revision ||
        publication.revision != shared.seen_publication_revision) {
        if (shared.report_revision == std::numeric_limits<std::uint64_t>::max()) publication.failed.store(true);
        else ++shared.report_revision;
        shared.seen_pulse_revision = pulse_revision; shared.seen_capture_revision = capture_revision;
        shared.seen_publication_revision = publication.revision;
    }
    return shared.report_revision;
}
bool lease_client(lease::Reason& reason) noexcept {
    if (!shared.ready || !shared.context_generation || !shared.observed_base || !shared.observed_client) {
        reason = lease::Reason::client_not_ready; return false;
    }
    if (environment::thread() != shared.client_thread) {
        reason = lease::Reason::wrong_thread; return false;
    }
    return true;
}
Entry* find(std::uint64_t owner, model::Handle handle) noexcept {
    if (!owner || !handle.sequence) return nullptr;
    for (auto& entry : shared.entries)
        if (entry.occupied && entry.owner == owner && entry.receipt.handle == handle) return &entry;
    return nullptr;
}
policy::Key key(const Entry& entry) noexcept {
    return {entry.owner, entry.receipt.handle.sequence, entry.receipt.source_epoch,
        entry.actor.ticket.generation, entry.receipt.user};
}
bool eligible_state(const actor_control_native::State& state) noexcept { return state.known; }
bool warmup_profile_lock(const Entry& entry, const model::ActorObservation& observation) noexcept {
    using Phase = actor_observation::Phase;
    using Reason = actor_control_native::Reason;
    const auto& receipt = entry.receipt;
    // Only a positively identified profile Try-lock refusal may defer a sample.
    // Skipped actor/clock facts remain absent; none becomes ready by waiting.
    return entry.started && entry.ending == model::Status::released && !entry.rejection_recorded &&
        receipt.status == model::Status::warming && !receipt.press_candidates && !receipt.press_publications &&
        !receipt.neutral_publications && !receipt.report_debt && !receipt.orphaned && !receipt.quarantined &&
        !receipt.claim_released && receipt.first_rejection_mask == 0 &&
        receipt.first_rejection_stage == model::RejectionStage::none &&
        observation.known && observation.owner_present && observation.call_active &&
        observation.enter.phase == Phase::qualified && observation.enter.reason == Reason::none &&
        observation.inspect_attempted && !observation.inspect_succeeded && !observation.actor_equal &&
        observation.inspect.phase == Phase::controls_profile_lock && observation.inspect.reason == Reason::unavailable &&
        !observation.clock_attempted && !observation.clock_known;
}
model::Reason native_issue(actor_control_native::Reason reason) noexcept {
    using Native = actor_control_native::Reason;
    switch (reason) {
    case Native::busy: case Native::motion_owned: return model::Reason::busy;
    case Native::focus_changed: return model::Reason::focus_lost;
    case Native::actor_changed: case Native::actor_destroyed: case Native::world_changed:
    case Native::native_lifetime_changed: case Native::context_changed: return model::Reason::actor_changed;
    case Native::protection_conflict: case Native::request_bits_conflict: return model::Reason::interference;
    default: return model::Reason::actor_unavailable;
    }
}
bool publish(XINPUT_STATE* output, const XINPUT_STATE& value) noexcept {
    __try { *output = value; return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool copy(XINPUT_STATE* output, XINPUT_STATE& value) noexcept {
    __try { value = *output; return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
void remember_rejection(Entry& entry, std::uint32_t mask, model::RejectionStage stage,
    const model::ActorObservation* observation = nullptr) noexcept {
    if (entry.rejection_recorded) return;
    entry.rejection_recorded = true;
    entry.receipt.first_rejection_mask = mask;
    entry.receipt.first_rejection_stage = stage;
    if (observation) entry.receipt.first_actor_observation = *observation;
}
model::Reason policy_reason(std::uint32_t mask) noexcept {
    using Check = policy::FailedCheck;
    // A combined failure stays generic. The mask retains every observed failed
    // check, without guessing which provider or condition caused another one.
    if (mask == policy::failure_bit(Check::focus)) return model::Reason::focus_lost;
    if (mask == policy::failure_bit(Check::menu)) return model::Reason::menu_open;
    if (mask == policy::failure_bit(Check::gameplay)) return model::Reason::gameplay_inactive;
    if (mask == policy::failure_bit(Check::interference) || mask == policy::failure_bit(Check::physical_activity))
        return model::Reason::interference;
    if (mask == policy::failure_bit(Check::actor)) return model::Reason::actor_changed;
    if (mask == policy::failure_bit(Check::native_clock)) return model::Reason::clock_unavailable;
    if (mask == policy::failure_bit(Check::native_continuity)) return model::Reason::clock_regressed;
    if (mask == policy::failure_bit(Check::deadline)) return model::Reason::deadline;
    return model::Reason::unavailable;
}
void remember_policy_rejection(Entry& entry, model::RejectionStage stage, const model::ActorObservation& observation) noexcept {
    const auto mask = shared.pulse.first_rejection_mask();
    if (mask) remember_rejection(entry, mask, stage, &observation);
}
void revoke(Entry& entry, model::Status ending, model::Reason reason) noexcept {
    if (model::terminal(entry.receipt.status)) return;
    if (entry.ending == model::Status::released) {
        remember_rejection(entry, 0, model::RejectionStage::none);
        entry.ending = ending;
        entry.receipt.reason = reason;
    }
    if (entry.started) (void)shared.pulse.revoke(key(entry));
    entry.receipt.report_debt = entry.started && shared.pulse.release_debt();
    entry.receipt.status = model::Status::releasing;
}
void note_source(Source& source, DWORD result, bool has_output, std::uint64_t observed) noexcept {
    if (!observed || observed < source.observed_ms) return;
    const bool connected = result == ERROR_SUCCESS && has_output;
    if (connected != source.connected || (connected && !source.epoch)) source.epoch = issue(shared.next_epoch);
    source.connected = connected;
    source.observed_ms = observed;
}
}

PublicationScope::PublicationScope(bool enabled) noexcept {
    if (!enabled) return;
    if (publication_owner) { publication.failed.store(true); return; }
    AcquireSRWLockExclusive(&publication.lock);
    acquired_ = true; thread_ = GetCurrentThreadId(); publication_owner = this;
}
PublicationScope::~PublicationScope() {
    if (!acquired_) return;
    publication_owner = nullptr;
    ReleaseSRWLockExclusive(&publication.lock);
}
bool PublicationScope::owns() const noexcept {
    return acquired_ && thread_ == GetCurrentThreadId() && publication_owner == this;
}
bool publication_held() noexcept { return publication_owner != nullptr; }
std::uint64_t publication_revision(const PublicationScope& scope) noexcept {
    return scope.owns() && !publication.failed.load() ? publication.revision : 0;
}
void publication_changed(const PublicationScope& scope, PublicationChange change) noexcept {
    LastError error;
    if (!scope.owns()) { publication.failed.store(true); return; }
    publication_advance();
    Lock lock(shared.lock);
    if (change == PublicationChange::context) {
        // A window/readiness/failure publication invalidates admission now,
        // before the next client tick can supply a fresh native context.
        shared.ready = false; shared.eligible_at = 0;
        shared.context_generation = issue(shared.next_context);
    }
    shared.leases.invalidate(change == PublicationChange::context ? lease::Reason::context_changed : lease::Reason::interference);
    shared.capture.revoke(change == PublicationChange::paused ? capture::Reason::paused :
        change == PublicationChange::context ? capture::Reason::context_changed : capture::Reason::interference);
    if (shared.active != no_entry) revoke(shared.entries[shared.active], model::Status::revoked, model::Reason::interference);
    for (auto& source : shared.sources) source.capture_eligible = false;
}

Poll::~Poll() {
    if (!source_call_active || source_user > 3) return;
    LastError error; PublicationScope scope;
    if (!scope.owns()) return;
    Lock lock(shared.lock);
    auto& source = shared.sources[source_user];
    if (source.in_flight) --source.in_flight;
    capture_cleanup();
}

bool request(std::uint64_t owner, std::uint32_t user, std::uint16_t button,
    model::Handle& handle, model::Reason& reason) noexcept {
    LastError error;
    handle = {}; reason = model::Reason::none;
    if (!owner) { reason = model::Reason::invalid_owner; return false; }
    if (user > 3) { reason = model::Reason::invalid_source; return false; }
    if (!model::valid_button(button)) { reason = model::Reason::invalid_button; return false; }
    std::size_t slot = no_entry;
    std::uint64_t sequence{};
    const auto now = environment::now();
    {
        PublicationScope scope;
        if (!scope.owns() || !publication_revision(scope)) { reason = model::Reason::unavailable; return false; }
        Lock lock(shared.lock);
        if (!shared.ready) { reason = model::Reason::client_not_ready; return false; }
        if (environment::thread() != shared.client_thread) { reason = model::Reason::wrong_thread; return false; }
        if (now < shared.eligible_at || now - shared.eligible_at > 250) {
            reason = model::Reason::client_tick_stale; return false;
        }
        if (shared.active != no_entry || shared.leases.active().sequence || capture_busy()) { reason = model::Reason::busy; return false; }
        const auto& source = shared.sources[user];
        if (!source.connected || !source.epoch || now < source.observed_ms || now - source.observed_ms > 100) {
            reason = model::Reason::source_unavailable; return false;
        }
        unsigned recent{};
        for (const auto started : shared.starts) if (started && (now < started || now - started < 1000)) ++recent;
        if (recent == shared.starts.size()) { reason = model::Reason::rate_limited; return false; }
        for (std::size_t i = 0; i < shared.entries.size(); ++i) if (!shared.entries[i].occupied) { slot = i; break; }
        if (slot == no_entry) { reason = model::Reason::capacity; return false; }
        sequence = issue(shared.next_sequence);
        if (!sequence || now > std::numeric_limits<std::uint64_t>::max() - model::lifetime_ms) {
            reason = model::Reason::sequence_exhausted; return false;
        }
        auto& entry = shared.entries[slot];
        entry = {}; entry.occupied = entry.admitting = true; entry.owner = owner;
        auto& r = entry.receipt;
        r.handle = {sequence}; r.user = user; r.button = button;
        r.requested_ms = r.observed_ms = now; r.expires_ms = now + model::lifetime_ms; r.source_epoch = source.epoch;
        shared.active = slot;
        for (auto& started : shared.starts) if (!started || (now >= started && now - started >= 1000)) { started = now; break; }
    }
    Actor actor; actor_control_native::Reason native_reason{};
    const bool acquired = actor_control_native::acquire(owner, sequence, &eligible_state, actor, native_reason,
        actor_control_native::Continuity::observed_context);
    const bool clock = acquired && actor_control_native::enable_clock(owner, sequence, actor, native_reason);
    const bool abandoned = acquired && !clock && actor_control_native::retire(owner, sequence, actor, true);
    {
        PublicationScope scope;
        if (!scope.owns()) { reason = model::Reason::unavailable; return false; }
        Lock lock(shared.lock);
        auto& entry = shared.entries[slot];
        if (!clock) {
            if (!acquired || abandoned) { entry = {}; shared.active = no_entry; }
            else {
                entry.actor = actor; entry.admitting = false; entry.receipt.orphaned = true;
                revoke(entry, model::Status::revoked, model::Reason::cleanup_pending);
            }
            reason = !acquired ? native_issue(native_reason) :
                abandoned ? model::Reason::clock_unavailable : model::Reason::cleanup_pending;
            return false;
        }
        entry.actor = actor; entry.admitting = false;
        handle = {sequence};
        if (entry.receipt.orphaned) revoke(entry, model::Status::cancelled, model::Reason::cancelled);
    }
    return true;
}

bool read(std::uint64_t owner, model::Handle handle, model::Receipt& receipt) noexcept {
    LastError error; PublicationScope scope; if (!scope.owns()) return false;
    Lock lock(shared.lock);
    const auto* entry = find(owner, handle);
    if (!entry) return false;
    receipt = entry->receipt; return true;
}
bool cancel(std::uint64_t owner, model::Handle handle) noexcept {
    LastError error; PublicationScope scope; if (!scope.owns()) return false;
    Lock lock(shared.lock);
    auto* entry = find(owner, handle);
    if (!entry || entry->admitting || model::terminal(entry->receipt.status)) return false;
    revoke(*entry, model::Status::cancelled, model::Reason::cancelled); return true;
}
bool acknowledge(std::uint64_t owner, model::Handle handle) noexcept {
    LastError error; PublicationScope scope; if (!scope.owns()) return false;
    Lock lock(shared.lock);
    auto* entry = find(owner, handle);
    if (!entry || !model::terminal(entry->receipt.status) || entry->receipt.report_debt || !entry->receipt.claim_released) return false;
    *entry = {}; return true;
}
void release_all(std::uint64_t owner) noexcept {
    LastError error; PublicationScope scope; if (!scope.owns()) return;
    Lock lock(shared.lock);
    for (auto& entry : shared.entries) if (entry.occupied && entry.owner == owner) {
        entry.receipt.orphaned = true;
        if (model::terminal(entry.receipt.status) && entry.receipt.claim_released && !entry.receipt.report_debt) entry = {};
        else revoke(entry, model::Status::cancelled, model::Reason::cancelled);
    }
}

bool lease_request(std::uint64_t owner, std::uint32_t user,
    lease::Handle& handle, lease::Reason& reason) noexcept {
    LastError error; PublicationScope scope;
    if (!scope.owns()) { handle = {}; reason = lease::Reason::unavailable; return false; }
    sample_environment(scope);
    Lock lock(shared.lock);
    handle = {}; reason = lease::Reason::none;
    if (!owner) { reason = lease::Reason::invalid_owner; return false; }
    if (user > 3) { reason = lease::Reason::invalid_source; return false; }
    if (!lease_client(reason)) return false;
    return shared.leases.request(owner, user, shared.sources[user].observation,
        lease_guard(environment::now()), shared.active != no_entry || capture_busy(), handle, reason);
}
bool lease_read(std::uint64_t owner, lease::Handle handle,
    lease::Snapshot& snapshot, lease::Reason& reason) noexcept {
    LastError error; PublicationScope scope;
    if (!scope.owns()) { snapshot = {}; reason = lease::Reason::unavailable; return false; }
    sample_environment(scope);
    Lock lock(shared.lock);
    snapshot = {}; reason = lease::Reason::none;
    if (!owner) { reason = lease::Reason::invalid_owner; return false; }
    if (!lease_client(reason)) return false;
    const auto guard = lease_guard(environment::now());
    const bool result = shared.leases.read(owner, handle, guard, snapshot, reason);
    capture_sync(guard);
    return result;
}
bool lease_renew(std::uint64_t owner, lease::Handle handle,
    const lease::Snapshot& snapshot, lease::Reason& reason) noexcept {
    LastError error; PublicationScope scope;
    if (!scope.owns()) { reason = lease::Reason::unavailable; return false; }
    sample_environment(scope);
    Lock lock(shared.lock);
    reason = lease::Reason::none;
    if (!owner) { reason = lease::Reason::invalid_owner; return false; }
    if (!lease_client(reason)) return false;
    const auto guard = lease_guard(environment::now());
    const bool result = shared.leases.renew(owner, handle, snapshot, guard, reason);
    if (result && shared.capture.state().key.owner == owner && shared.capture.state().key.lease_sequence == handle.sequence &&
        shared.capture.reserved()) {
        lease::Receipt receipt;
        if (shared.leases.state(owner, handle, receipt)) {
            const auto& source = shared.sources[receipt.user];
            (void)shared.capture.renew(shared.capture.state().key, receipt.expires_ms,
                capture_input(source, guard, source.observation.pad, true, ERROR_SUCCESS, ERROR_SUCCESS));
        }
    }
    capture_sync(guard);
    return result;
}
bool lease_release(std::uint64_t owner, lease::Handle handle, lease::Reason& reason) noexcept {
    LastError error; PublicationScope scope;
    if (!scope.owns()) { reason = lease::Reason::unavailable; return false; }
    Lock lock(shared.lock);
    const bool released = shared.leases.release(owner, handle);
    if (released) {
        const auto& receipt = shared.capture.state();
        if (receipt.key.owner == owner && receipt.key.lease_sequence == handle.sequence) {
            (void)shared.capture.release(receipt.key); publication_advance();
        }
    }
    reason = released ? lease::Reason::none : lease::Reason::unavailable;
    return released;
}
bool lease_state(std::uint64_t owner, lease::Handle handle,
    lease::Receipt& receipt, lease::Reason& reason) noexcept {
    LastError error; PublicationScope scope;
    if (!scope.owns()) { receipt = {}; reason = lease::Reason::unavailable; return false; }
    sample_environment(scope);
    Lock lock(shared.lock);
    const auto guard = lease_guard(environment::now());
    shared.leases.tick(guard); capture_sync(guard);
    receipt = {};
    const bool found = shared.leases.state(owner, handle, receipt);
    const auto& held = shared.capture.state();
    receipt.capture_reserved = found && held.key.owner == owner && held.key.lease_sequence == handle.sequence &&
        held.key.user == receipt.user && held.key.source_epoch == receipt.source_epoch &&
        held.key.context_generation == receipt.context_generation && capture_busy();
    if (receipt.capture_reserved) receipt.source_released = false;
    reason = found ? lease::Reason::none : lease::Reason::unavailable;
    return found;
}
bool lease_acknowledge(std::uint64_t owner, lease::Handle handle, lease::Reason& reason) noexcept {
    LastError error; PublicationScope scope;
    if (!scope.owns()) { reason = lease::Reason::unavailable; return false; }
    Lock lock(shared.lock);
    const auto& held = shared.capture.state();
    if (held.key.owner == owner && held.key.lease_sequence == handle.sequence && capture_busy()) {
        reason = lease::Reason::busy; return false;
    }
    const bool acknowledged = shared.leases.acknowledge(owner, handle);
    reason = acknowledged ? lease::Reason::none : lease::Reason::unavailable;
    return acknowledged;
}
void lease_release_all(std::uint64_t owner) noexcept {
    LastError error; PublicationScope scope; if (!scope.owns()) return;
    Lock lock(shared.lock);
    const auto& held = shared.capture.state();
    if (held.key.owner == owner && held.phase != capture::Phase::idle) {
        shared.capture_orphaned = true;
        (void)shared.capture.release(held.key); publication_advance();
    }
    shared.leases.release_all(owner);
    capture_cleanup();
}

bool capture_request(std::uint64_t owner, lease::Handle handle,
    const lease::Snapshot& snapshot, capture::Reason& reason) noexcept {
    LastError error; PublicationScope scope;
    reason = capture::Reason::authority_lost;
    if (!scope.owns() || !publication_revision(scope)) return false;
    sample_environment(scope);
    Lock lock(shared.lock);
    lease::Reason client_reason{};
    if (!lease_client(client_reason)) return false;
    const auto guard = lease_guard(environment::now());
    shared.leases.tick(guard); capture_sync(guard);
    lease::Receipt receipt;
    if (!shared.leases.state(owner, handle, receipt) || receipt.status != lease::Status::active ||
        !shared.leases.issued(owner, handle, snapshot) || receipt.user > 3) return false;
    const auto& source = shared.sources[receipt.user];
    // Do not assign a new capture key while an unbound earlier original call
    // can still return. No waiting occurs here: the owner retries after drain
    // using a fresh exact issued observation.
    if (source.in_flight) { reason = capture::Reason::busy; return false; }
    if (!source.capture_eligible || !shared.leases.accepted(owner, handle, source.observation) ||
        snapshot.observation_serial != source.observation.observation_serial || snapshot.pad != source.observation.pad)
        return false;
    const capture::Key key{owner, handle.sequence, receipt.source_epoch, receipt.context_generation, receipt.user};
    auto input = capture_input(source, guard, source.observation.pad, true, ERROR_SUCCESS, ERROR_SUCCESS);
    input.safety.source_authorized = true; // Exact owned issued+accepted tuple verified immediately above.
    const bool result = shared.capture.request(key, receipt.expires_ms, input, shared.active != no_entry, reason);
    if (result) { shared.capture_orphaned = false; publication_advance(); }
    return result;
}
bool capture_state(std::uint64_t owner, lease::Handle handle, capture::Receipt& receipt) noexcept {
    LastError error; PublicationScope scope; receipt = {};
    if (!scope.owns()) return false;
    sample_environment(scope);
    Lock lock(shared.lock);
    const auto guard = lease_guard(environment::now());
    shared.leases.tick(guard); capture_sync(guard);
    const auto& held = shared.capture.state();
    if (!owner || !handle.sequence || held.phase == capture::Phase::idle ||
        held.key.owner != owner || held.key.lease_sequence != handle.sequence) return false;
    receipt = held; return true;
}
bool capture_release(std::uint64_t owner, lease::Handle handle) noexcept {
    LastError error; PublicationScope scope; if (!scope.owns()) return false;
    Lock lock(shared.lock);
    const auto& held = shared.capture.state();
    if (!owner || held.key.owner != owner || held.key.lease_sequence != handle.sequence) return false;
    const bool result = shared.capture.release(held.key);
    if (result) { shared.leases.invalidate(lease::Reason::cancelled); publication_advance(); }
    return result;
}
bool capture_acknowledge(std::uint64_t owner, lease::Handle handle) noexcept {
    LastError error; PublicationScope scope; if (!scope.owns()) return false;
    Lock lock(shared.lock);
    const auto& held = shared.capture.state();
    if (!owner || held.key.owner != owner || held.key.lease_sequence != handle.sequence ||
        held.key.user > 3 || shared.sources[held.key.user].in_flight) return false;
    return shared.capture.acknowledge(held.key);
}

void begin(bool outer, std::uint32_t user, Poll& poll) noexcept {
    LastError error;
    if (!outer || user > 3 || poll.source_call_active) return;
    Actor actor; std::uint64_t owner{};
    {
        PublicationScope scope; if (!scope.owns()) return;
        Lock lock(shared.lock);
        auto& source = shared.sources[user];
        if (source.in_flight == std::numeric_limits<std::uint64_t>::max()) {
            publication.failed.store(true); return;
        }
        ++source.in_flight; poll.source_call_active = true; poll.source_user = user;
        if (shared.leases.active_user() == user) poll.lease_handle = shared.leases.active();
        const auto& held = shared.capture.state();
        if (shared.capture.reserved() && held.key.user == user) {
            poll.capture_key = held.key; poll.capture_ticket = shared.capture.ticket();
        }
        if (shared.active == no_entry) return;
        const auto& entry = shared.entries[shared.active];
        if (entry.admitting || entry.receipt.user != user) return;
        poll.sequence = entry.receipt.handle.sequence; poll.ticket = shared.pulse.ticket();
        actor = entry.actor; owner = entry.owner;
    }
    (void)actor_control_native::enter(owner, poll.sequence, actor, poll.call, poll.enter_observation);
}

void prepare_finish(Poll& poll) noexcept {
    LastError error;
    poll.prepared = false;
    Actor actor; std::uint64_t owner{};
    {
        PublicationScope scope; if (!scope.owns()) return;
        Lock lock(shared.lock);
        if (shared.active != no_entry) {
            const auto& entry = shared.entries[shared.active];
            if (!entry.admitting && entry.receipt.handle.sequence == poll.sequence) { actor = entry.actor; owner = entry.owner; }
        }
    }
    Actor live; actor_control_native::State state; actor_control_native::Reason actor_issue{};
    model::ActorObservation observation;
    observation.known = true; observation.owner_present = owner != 0;
    observation.call_active = poll.call.active(); observation.enter = poll.enter_observation;
    observation.inspect_attempted = observation.owner_present && observation.call_active;
    observation.inspect_succeeded = observation.inspect_attempted &&
        actor_control_native::inspect(owner, poll.sequence, actor, live, state, actor_issue, observation.inspect);
    observation.actor_equal = observation.inspect_succeeded && live == actor;
    const bool actor_current = observation.actor_equal;
    actor_control_native::Clock clock;
    observation.clock_attempted = actor_current;
    const bool clock_known = actor_current && actor_control_native::read_clock(owner, poll.sequence, actor, clock);
    observation.clock_known = clock_known;
    poll.staged_actor = observation;
    poll.staged_actor_current = actor_current; poll.staged_clock_known = clock_known;
    poll.staged_serial = clock_known ? clock.serial : 0;
    poll.staged_clock_ms = clock_known ? clock.observed_ms : 0;
    poll.staged_seconds = clock_known ? clock.seconds : 0;
    poll.prepared = true;
}

static DWORD finish_core(Poll& poll, const PublicationScope& scope, bool outer, std::uint32_t user,
    DWORD original_result, std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, const XINPUT_STATE& candidate, std::uint64_t staged_revision,
    XINPUT_STATE* output, bool interference_clear, bool original_output_known, bool staged_lane, bool private_lane) noexcept {
    LastError error;
    if (!outer || user > 3 || !scope.owns()) return original_result;
    const bool stage_current = staged_revision && staged_revision == publication_revision(scope);
    const bool stale_stage = staged_lane && !stage_current;
    const DWORD selected_result = stale_stage ? original_result : returned_result;
    XINPUT_STATE returned = candidate;
    if (stale_stage) returned.Gamepad = {};
    // Successful transport without a valid original report cannot authorize an
    // invented neutral write. A fresh scripted success over an original failure
    // remains its separate legacy competitor report, never a raw-source fact.
    const bool has_output = output && selected_result == ERROR_SUCCESS &&
        (original_output_known || original_result != ERROR_SUCCESS);
    const auto& observation = poll.staged_actor;
    const bool actor_current = poll.prepared && poll.staged_actor_current;
    const bool clock_known = poll.prepared && poll.staged_clock_known;
    sample_environment(scope);
    Lock lock(shared.lock);
    auto& source = shared.sources[user];
    const auto fallback_key = shared.capture.state().key;
    const bool fallback_owned = stale_stage && has_output && fallback_key.user == user &&
        (shared.capture.reserved() || poll.capture_key == fallback_key) &&
        shared.capture.retain_neutralization(fallback_key);
    const auto prior_phase = shared.capture.state().phase;
    const bool historical_capture = staged_lane && stage_current && has_output && original_output_known &&
        original_result == ERROR_SUCCESS && selected_result == ERROR_SUCCESS &&
        poll.capture_key == shared.capture.state().key && poll.capture_key.user == user &&
        source.connected && source.epoch == poll.capture_key.source_epoch &&
        interference_clear && publication_facts.interference_clear && pad(returned.Gamepad) == pad(raw) &&
        ((prior_phase == capture::Phase::complete && shared.capture.state().neutral_releases) ||
            (prior_phase == capture::Phase::releasing &&
                poll.capture_ticket.generation != shared.capture.ticket().generation));
    note_source(source, original_result, original_output_known, original_ms);
    const auto now = environment::now();
    const auto raw_pad = pad(raw);
    const auto guard = lease_guard(now);
    bool observation_updated{};
    // A delayed older completion is not a new source event. Keep the accepted
    // source cache intact instead of revoking a lease because callbacks finished
    // out of order. Equal millisecond stamps use this gate's ordinal order only;
    // neither field claims a physical controller or native consumption order.
    if (original_ms && original_ms == source.observed_ms && !historical_capture) {
        // The cookie predates the original call. A poll already in flight when a
        // lease was admitted can update the cache, but cannot qualify its first read.
        // New failures still reach observe, even when their cookie is an old one.
        observation_updated = true;
        source.observation = {user, raw_packet, source.epoch, issue(shared.next_observation),
            original_ms, shared.context_generation, raw_pad,
            original_result == ERROR_SUCCESS && original_output_known,
            original_result == ERROR_SUCCESS && original_output_known && has_output && selected_result == original_result &&
            !private_lane && !stale_stage && pad(returned.Gamepad) == raw_pad && interference_clear && guard.ready && guard.focused &&
            guard.gameplay && guard.menu_closed && guard.interference_clear &&
            now >= original_ms && now - original_ms <= lease::maximum_age_ms};
        source.capture_eligible = staged_lane && stage_current && source.observation.eligible;
        shared.leases.observe(poll.lease_handle, source.observation, guard);
    }
    capture_sync(guard);
    policy::Output plan{original_result, raw_packet, has_output ? pad(returned.Gamepad) : policy::Pad{}};
    policy::Input input;
    bool deferred{};
    Entry* entry{};
    if (shared.active != no_entry) {
        auto& pulse_entry = shared.entries[shared.active];
        if (!pulse_entry.admitting && pulse_entry.receipt.handle.sequence == poll.sequence && pulse_entry.receipt.user == user) entry = &pulse_entry;
    }
    if (entry) {
        auto& r = entry->receipt;
        r.original_result_known = true; r.original_result = original_result; stamp(r, now);
        if (original_result != ERROR_SUCCESS) increment(r.original_failures);
        const bool same_source = source.connected && source.epoch == r.source_epoch && source.epoch &&
            original_ms == source.observed_ms && now >= original_ms && now - original_ms <= 100;
        if (!same_source) {
            auto mask = policy::failure_bit(policy::FailedCheck::source_fresh);
            if (original_result != ERROR_SUCCESS) mask |= policy::failure_bit(policy::FailedCheck::original_result);
            if (!has_output) mask |= policy::failure_bit(policy::FailedCheck::output);
            if (selected_result != original_result) mask |= policy::failure_bit(policy::FailedCheck::transport_result);
            if (!original_ms || now < original_ms || now - original_ms > policy::Pulse::maximum_gap_ms)
                mask |= policy::failure_bit(policy::FailedCheck::source_clock);
            remember_rejection(*entry, mask, model::RejectionStage::service_plan, &observation);
            revoke(*entry, model::Status::revoked, model::Reason::source_changed);
        }
        if (now >= r.expires_ms) {
            remember_rejection(*entry, policy::failure_bit(policy::FailedCheck::deadline), model::RejectionStage::service_plan, &observation);
            revoke(*entry, model::Status::expired, model::Reason::deadline);
        }
        if (!entry->started && entry->ending == model::Status::released && actor_current && clock_known && same_source) {
            entry->started = shared.pulse.request(key(*entry), r.button, r.requested_ms);
            if (!entry->started) revoke(*entry, model::Status::revoked, model::Reason::sequence_exhausted);
            else poll.ticket = shared.pulse.ticket();
        }
        if (entry->started) {
            input.key = key(*entry); input.now_ms = now; input.source_observed_ms = original_ms;
            input.clock_observed_ms = clock_known ? poll.staged_clock_ms : 0;
            input.serial = clock_known ? poll.staged_serial : 0; input.seconds = clock_known ? poll.staged_seconds : 0;
            input.original_result = original_result; input.original_packet = raw_packet;
            input.raw = raw_pad; input.returned = plan.pad;
            input.has_output = has_output; input.transport_matches = selected_result == original_result;
            input.outer_game_poll = true; input.source_fresh = same_source; input.actor_current = actor_current;
            input.focused = publication_facts.focused; input.gameplay = publication_facts.gameplay;
            input.menu_closed = publication_facts.menu_closed;
            input.interference_clear = !private_lane && !stale_stage && interference_clear && publication_facts.interference_clear;
            deferred = warmup_profile_lock(*entry, observation) && shared.pulse.defer_warmup(poll.ticket, input, plan);
            if (deferred) increment(r.warmup_deferrals);
            else {
                plan = shared.pulse.poll(poll.ticket, input);
                remember_policy_rejection(*entry, model::RejectionStage::core_plan, observation);
            }
            if (plan.press_candidate) increment(r.press_candidates);
            r.report_debt = shared.pulse.release_debt();
        }
    }
    if (has_output) {
        if (entry && entry->started && (plan.press_candidate || plan.release_candidate)) {
            // Recheck deadlines and current capture facts at the publication
            // boundary, without dropping the generation/publication gate.
            input.focused = publication_facts.focused; input.gameplay = publication_facts.gameplay;
            input.menu_closed = publication_facts.menu_closed;
            input.interference_clear = !private_lane && !stale_stage && interference_clear && publication_facts.interference_clear;
            input.now_ms = environment::now();
            input.source_fresh = source.connected && source.epoch == entry->receipt.source_epoch &&
                source.epoch && original_ms == source.observed_ms && input.now_ms >= original_ms &&
                input.now_ms - original_ms <= 100;
            plan = shared.pulse.poll({plan.generation}, input);
            remember_policy_rejection(*entry, model::RejectionStage::prepublish, observation);
            stamp(entry->receipt, input.now_ms);
            entry->receipt.report_debt = shared.pulse.release_debt();
        }
        returned.Gamepad.wButtons = plan.pad.buttons;
        capture::Plan capture_plan{pad(returned.Gamepad)};
        const auto continuation_key = shared.capture.state().key;
        const auto continuation_phase = shared.capture.state().phase;
        const bool raw_fresh = original_ms && now >= original_ms && now - original_ms <= lease::maximum_age_ms;
        const bool cleanup_old_ticket = continuation_phase == capture::Phase::releasing &&
            poll.capture_ticket.generation != shared.capture.ticket().generation;
        const bool delayed_bound = staged_lane && stage_current && !private_lane && original_output_known &&
            original_result == ERROR_SUCCESS && selected_result == ERROR_SUCCESS && original_ms &&
            (!observation_updated || !raw_fresh || cleanup_old_ticket ||
                (continuation_phase == capture::Phase::complete && shared.capture.state().neutral_releases)) &&
            poll.capture_key == continuation_key && continuation_key.user == user &&
            source.connected && source.epoch == continuation_key.source_epoch &&
            interference_clear && publication_facts.interference_clear && pad(returned.Gamepad) == raw_pad;
        // A newer neutral may have completed cleanup while this older captured
        // call remained in flight. Reopen that retained key before masking its
        // old report; the old neutral itself is never a new release witness.
        const bool reopened = delayed_bound && continuation_phase == capture::Phase::complete &&
            shared.capture.state().neutral_releases && shared.capture.retain_neutralization(continuation_key);
        const bool continuation = delayed_bound && (reopened || (shared.capture.state().debt &&
            (continuation_phase == capture::Phase::releasing ||
                (continuation_phase == capture::Phase::capturing &&
                    poll.capture_ticket.generation == shared.capture.ticket().generation))));
        // Never manufacture a fresh raw observation from an older completion.
        // Capture plans exactly once per accepted outer report, after all safety
        // facts have been sampled under the final publication/state gates.
        if (!continuation && staged_lane && stage_current && observation_updated && !stale_stage &&
            shared.capture.state().key.user == user) {
            auto capture_facts = capture_input(source, lease_guard(environment::now()), pad(returned.Gamepad),
                has_output, original_result, selected_result);
            capture_facts.safety.interference_clear = interference_clear && capture_facts.safety.interference_clear;
            capture_plan = shared.capture.plan(poll.capture_ticket, capture_facts);
            if (capture_plan.suppress) {
                returned.Gamepad = {capture_plan.pad.buttons, capture_plan.pad.left_trigger, capture_plan.pad.right_trigger,
                    capture_plan.pad.left_x, capture_plan.pad.left_y, capture_plan.pad.right_x, capture_plan.pad.right_y};
            }
        }
        // After the capture has planned (it compares returned with raw), held
        // controls stay neutral in the owed stream's reports. The private lane
        // writes its own report below, so nothing is held back from it.
        bool withheld{};
        const auto withhold = [&](const capture::Held& held) {
            if (private_lane) return;
            const auto before = pad(returned.Gamepad), masked = held.mask(before);
            withheld = withheld || masked != before;
            returned.Gamepad = gamepad(masked);
        };
        // While a release is open, on every report the capture does not write
        // itself: one another filter or script owns, or one it could not plan.
        // Otherwise a control held through the stop would reach the game at once.
        const auto& owed = shared.capture.state();
        if (!capture_plan.suppress && owed.phase == capture::Phase::releasing && owed.key.user == user &&
            source.connected && source.epoch == owed.key.source_epoch) withhold(shared.capture.held());
        // What a bounded release left held, until an in-order original shows it
        // at rest. A new epoch is a new stream.
        if (source.held_back.any()) {
            if (!source.connected || source.epoch != source.held_epoch) source.held_back = {};
            else {
                if (observation_updated && original_result == ERROR_SUCCESS && original_output_known)
                    source.held_back.rest(raw_pad);
                withhold(source.held_back);
            }
        }
        if (continuation) returned.Gamepad = {};
        // A stale scripted/filter stage never lends even one pressed button to
        // a pulse. The approved bounded fallback is one full neutral report.
        if (stale_stage) returned.Gamepad = {};
        if (private_lane) returned.Gamepad = candidate.Gamepad;
        const auto revision = report_revision();
        if (publication.failed.load() && !private_lane) {
            if (entry) revoke(*entry, model::Status::revoked, model::Reason::sequence_exhausted);
            if (capture_plan.suppress) {
                (void)shared.capture.retain_neutralization(shared.capture.state().key);
                shared.capture.revoke(capture::Reason::exhausted);
            }
            returned.Gamepad = {};
        }
        returned.dwPacketNumber = source.packets.translate(source.epoch, revision,
            raw_packet, returned.dwPacketNumber, raw_pad, pad(returned.Gamepad),
            plan.press_candidate || capture_plan.suppress || continuation || stale_stage || withheld);
        const bool published = publish(output, returned);
        if (capture_plan.suppress && shared.capture.confirm(capture_plan, published) && capture_plan.release &&
            capture_plan.held.any()) {
            if (source.held_epoch != source.epoch) source.held_back = {};
            source.held_back.hold(capture_plan.held); source.held_epoch = source.epoch;
        }
        if (continuation) shared.capture.continuation_result(continuation_key, published);
        if (fallback_owned) shared.capture.neutralization_result(fallback_key, published);
        if (entry && entry->started && !private_lane) {
            if (!deferred) (void)shared.pulse.confirm(plan, published);
            auto& r = entry->receipt;
            if (published && plan.press_candidate) increment(r.press_publications);
            if (published && plan.release_candidate) increment(r.neutral_publications);
            r.report_debt = shared.pulse.release_debt();
            if (!published) {
                remember_rejection(*entry, 0, model::RejectionStage::publication, &observation);
                revoke(*entry, model::Status::revoked, model::Reason::publication_unconfirmed);
            }
        }
    }
    if (entry && entry->started) {
        auto& r = entry->receipt;
        switch (shared.pulse.phase()) {
        case policy::Phase::warming: r.status = model::Status::warming; break;
        case policy::Phase::press: r.status = model::Status::pressing; break;
        case policy::Phase::releasing: r.status = model::Status::releasing; break;
        case policy::Phase::complete: r.status = model::Status::releasing; break;
        case policy::Phase::revoked:
            if (entry->ending == model::Status::released) {
                entry->ending = model::Status::revoked; r.reason = policy_reason(r.first_rejection_mask);
            }
            r.status = model::Status::releasing; break;
        default: break;
        }
        r.quarantined = r.report_debt && (!source.connected || source.epoch != r.source_epoch);
    }
    return selected_result;
}

DWORD finish_staged(Poll& poll, const PublicationScope& scope, bool outer, std::uint32_t user,
    DWORD original_result, std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, const XINPUT_STATE& candidate, std::uint64_t staged_revision,
    XINPUT_STATE* output, bool interference_clear, bool original_output_known) noexcept {
    return finish_core(poll, scope, outer, user, original_result, original_ms, raw_packet, raw,
        returned_result, candidate, staged_revision, output, interference_clear, original_output_known, true, false);
}

void finish(Poll& poll, bool outer, std::uint32_t user, DWORD original_result,
    std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, XINPUT_STATE* output, bool interference_clear) noexcept {
    LastError error;
    if (!outer || user > 3) return;
    XINPUT_STATE candidate{};
    const bool copied = output && returned_result == ERROR_SUCCESS && copy(output, candidate);
    prepare_finish(poll);
    PublicationScope scope; if (!scope.owns()) return;
    // Compatibility adapter supplies passive observations, never evidence that
    // the complete staged capture publication contract was used.
    (void)finish_core(poll, scope, outer, user, original_result, original_ms, raw_packet, raw,
        returned_result, candidate, publication_revision(scope), output,
        interference_clear, original_result == ERROR_SUCCESS && copied, false, false);
}

void finish_private(Poll& poll, bool outer, std::uint32_t user, DWORD original_result,
    std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, XINPUT_STATE* output, bool original_output_known) noexcept {
    LastError error;
    if (!outer || user > 3) return;
    XINPUT_STATE candidate{};
    if (output && returned_result == ERROR_SUCCESS && !copy(output, candidate)) return;
    prepare_finish(poll);
    PublicationScope scope; if (!scope.owns()) return;
    (void)finish_core(poll, scope, outer, user, original_result, original_ms, raw_packet, raw,
        returned_result, candidate, publication_revision(scope), output, false, original_output_known, false, true);
}

void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept {
    LastError error;
    Actor actor; std::uint64_t owner{}, sequence{};
    {
        PublicationScope scope; if (!scope.owns()) return;
        sample_environment(scope);
        Lock lock(shared.lock);
        const auto now = environment::now();
        if (shared.observed_base != base || shared.observed_client != client || shared.ready != ready ||
            shared.client_thread != environment::thread()) {
            shared.context_generation = issue(shared.next_context);
            shared.observed_base = base; shared.observed_client = client;
        }
        shared.ready = ready; shared.eligible_at = now; shared.client_thread = environment::thread();
        const auto guard = lease_guard(now);
        shared.leases.tick(guard); capture_sync(guard);
        if (shared.active == no_entry) return;
        auto& entry = shared.entries[shared.active];
        if (entry.admitting) return;
        if (!guard.ready) {
            remember_rejection(entry, 0, model::RejectionStage::tick_ready);
            revoke(entry, model::Status::revoked, model::Reason::unavailable);
        }
        if (now >= entry.receipt.expires_ms) {
            remember_rejection(entry, policy::failure_bit(policy::FailedCheck::deadline), model::RejectionStage::tick_deadline);
            revoke(entry, model::Status::expired, model::Reason::deadline);
        }
        const auto phase = shared.pulse.phase();
        if (entry.receipt.report_debt || (entry.started && phase != policy::Phase::complete && phase != policy::Phase::revoked)) return;
        if (!entry.started && entry.ending == model::Status::released) return;
        actor = entry.actor; owner = entry.owner; sequence = entry.receipt.handle.sequence;
    }
    (void)actor_control_native::disable_clock(owner, sequence, actor);
    if (!actor_control_native::retire(owner, sequence, actor, true)) return;
    PublicationScope scope; if (!scope.owns()) return;
    Lock lock(shared.lock);
    if (shared.active == no_entry) return;
    auto& entry = shared.entries[shared.active];
    if (entry.owner != owner || entry.receipt.handle.sequence != sequence || entry.receipt.report_debt) return;
    entry.receipt.claim_released = true; entry.receipt.status = entry.ending;
    stamp(entry.receipt, environment::now());
    if (entry.started) (void)shared.pulse.acknowledge(key(entry));
    shared.active = no_entry;
    if (entry.receipt.orphaned) entry = {};
}
}
