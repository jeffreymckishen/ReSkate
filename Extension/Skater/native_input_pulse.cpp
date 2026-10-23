#include "native_input_pulse.h"
#include "actor_control.h"
#include "native_input_pulse_environment.h"
#include <array>
#include <limits>

namespace dingosdk::native_input_pulse {
namespace {
namespace model = game_input_pulse;
namespace policy = input_pulse;
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
};
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
    std::size_t active{no_entry};
    std::uint64_t next_sequence{1}, next_epoch{1}, eligible_at{};
    DWORD client_thread{};
    bool ready{};
};
Shared shared;
policy::Pad pad(const XINPUT_GAMEPAD& value) noexcept {
    return {value.wButtons, value.bLeftTrigger, value.bRightTrigger,
        value.sThumbLX, value.sThumbLY, value.sThumbRX, value.sThumbRY};
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
model::Reason native_issue(actor_control_native::Reason reason) noexcept {
    using Native = actor_control_native::Reason;
    switch (reason) {
    case Native::busy: case Native::motion_owned: return model::Reason::busy;
    case Native::focus_changed: return model::Reason::focus_lost;
    case Native::actor_changed: case Native::actor_destroyed: case Native::world_changed:
    case Native::native_lifetime_changed: case Native::context_changed: return model::Reason::actor_changed;
    case Native::protection_conflict: case Native::request_bits_conflict: return model::Reason::interference;
    default: return model::Reason::unavailable;
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
void remember_rejection(Entry& entry, std::uint32_t mask, model::RejectionStage stage) noexcept {
    if (entry.rejection_recorded) return;
    entry.rejection_recorded = true;
    entry.receipt.first_rejection_mask = mask;
    entry.receipt.first_rejection_stage = stage;
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
void remember_policy_rejection(Entry& entry, model::RejectionStage stage) noexcept {
    const auto mask = shared.pulse.first_rejection_mask();
    if (mask) remember_rejection(entry, mask, stage);
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
        Lock lock(shared.lock);
        if (!shared.ready || environment::thread() != shared.client_thread || now < shared.eligible_at ||
            now - shared.eligible_at > 250) { reason = model::Reason::unavailable; return false; }
        if (shared.active != no_entry) { reason = model::Reason::busy; return false; }
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
    const bool acquired = actor_control_native::acquire(owner, sequence, &eligible_state, actor, native_reason);
    const bool clock = acquired && actor_control_native::enable_clock(owner, sequence, actor, native_reason);
    const bool abandoned = acquired && !clock && actor_control_native::retire(owner, sequence, actor, true);
    {
        Lock lock(shared.lock);
        auto& entry = shared.entries[slot];
        if (!clock) {
            if (!acquired || abandoned) { entry = {}; shared.active = no_entry; }
            else {
                entry.actor = actor; entry.admitting = false; entry.receipt.orphaned = true;
                revoke(entry, model::Status::revoked, model::Reason::unavailable);
            }
            reason = native_issue(native_reason); return false;
        }
        entry.actor = actor; entry.admitting = false;
        handle = {sequence};
        if (entry.receipt.orphaned) revoke(entry, model::Status::cancelled, model::Reason::cancelled);
    }
    return true;
}

bool read(std::uint64_t owner, model::Handle handle, model::Receipt& receipt) noexcept {
    LastError error; Lock lock(shared.lock);
    const auto* entry = find(owner, handle);
    if (!entry) return false;
    receipt = entry->receipt; return true;
}
bool cancel(std::uint64_t owner, model::Handle handle) noexcept {
    LastError error; Lock lock(shared.lock);
    auto* entry = find(owner, handle);
    if (!entry || entry->admitting || model::terminal(entry->receipt.status)) return false;
    revoke(*entry, model::Status::cancelled, model::Reason::cancelled); return true;
}
bool acknowledge(std::uint64_t owner, model::Handle handle) noexcept {
    LastError error; Lock lock(shared.lock);
    auto* entry = find(owner, handle);
    if (!entry || !model::terminal(entry->receipt.status) || entry->receipt.report_debt || !entry->receipt.claim_released) return false;
    *entry = {}; return true;
}
void release_all(std::uint64_t owner) noexcept {
    LastError error; Lock lock(shared.lock);
    for (auto& entry : shared.entries) if (entry.occupied && entry.owner == owner) {
        entry.receipt.orphaned = true;
        if (model::terminal(entry.receipt.status) && entry.receipt.claim_released && !entry.receipt.report_debt) entry = {};
        else revoke(entry, model::Status::cancelled, model::Reason::cancelled);
    }
}

void begin(bool outer, std::uint32_t user, Poll& poll) noexcept {
    LastError error;
    if (!outer || user > 3) return;
    Actor actor; std::uint64_t owner{};
    {
        Lock lock(shared.lock);
        if (shared.active == no_entry) return;
        const auto& entry = shared.entries[shared.active];
        if (entry.admitting || entry.receipt.user != user) return;
        poll.sequence = entry.receipt.handle.sequence; poll.ticket = shared.pulse.ticket();
        actor = entry.actor; owner = entry.owner;
    }
    (void)actor_control_native::enter(owner, poll.sequence, actor, poll.call);
}

void finish(Poll& poll, bool outer, std::uint32_t user, DWORD original_result,
    std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, XINPUT_STATE* output, bool interference_clear) noexcept {
    LastError error;
    if (!outer || user > 3) return;
    Actor actor; std::uint64_t owner{};
    {
        Lock lock(shared.lock);
        if (shared.active != no_entry) {
            const auto& entry = shared.entries[shared.active];
            if (!entry.admitting && entry.receipt.handle.sequence == poll.sequence) { actor = entry.actor; owner = entry.owner; }
        }
    }
    Actor live; actor_control_native::State state; actor_control_native::Reason issue{};
    const bool actor_current = owner && poll.call.active() &&
        actor_control_native::inspect(owner, poll.sequence, actor, live, state, issue) && live == actor;
    actor_control_native::Clock clock;
    const bool clock_known = actor_current && actor_control_native::read_clock(owner, poll.sequence, actor, clock);
    XINPUT_STATE returned{};
    const bool has_output = output && returned_result == ERROR_SUCCESS && copy(output, returned);
    Lock lock(shared.lock);
    auto& source = shared.sources[user];
    note_source(source, original_result, output != nullptr, original_ms);
    const auto now = environment::now();
    const auto raw_pad = pad(raw);
    policy::Output plan{original_result, raw_packet, has_output ? pad(returned.Gamepad) : policy::Pad{}};
    policy::Input input;
    Entry* entry{};
    if (shared.active != no_entry) {
        auto& candidate = shared.entries[shared.active];
        if (!candidate.admitting && candidate.receipt.handle.sequence == poll.sequence && candidate.receipt.user == user) entry = &candidate;
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
            if (returned_result != original_result) mask |= policy::failure_bit(policy::FailedCheck::transport_result);
            if (!original_ms || now < original_ms || now - original_ms > policy::Pulse::maximum_gap_ms)
                mask |= policy::failure_bit(policy::FailedCheck::source_clock);
            remember_rejection(*entry, mask, model::RejectionStage::service_plan);
            revoke(*entry, model::Status::revoked, model::Reason::source_changed);
        }
        if (now >= r.expires_ms) {
            remember_rejection(*entry, policy::failure_bit(policy::FailedCheck::deadline), model::RejectionStage::service_plan);
            revoke(*entry, model::Status::expired, model::Reason::deadline);
        }
        if (!entry->started && entry->ending == model::Status::released && actor_current && clock_known && same_source) {
            entry->started = shared.pulse.request(key(*entry), r.button, r.requested_ms);
            if (!entry->started) revoke(*entry, model::Status::revoked, model::Reason::sequence_exhausted);
            else poll.ticket = shared.pulse.ticket();
        }
        if (entry->started) {
            input.key = key(*entry); input.now_ms = now; input.source_observed_ms = original_ms;
            input.clock_observed_ms = clock_known ? clock.observed_ms : 0;
            input.serial = clock_known ? clock.serial : 0; input.seconds = clock_known ? clock.seconds : 0;
            input.original_result = original_result; input.original_packet = raw_packet;
            input.raw = raw_pad; input.returned = plan.pad;
            input.has_output = has_output; input.transport_matches = returned_result == original_result;
            input.outer_game_poll = true; input.source_fresh = same_source; input.actor_current = actor_current;
            input.focused = environment::focused(); input.gameplay = environment::gameplay();
            input.menu_closed = environment::menu_closed();
            input.interference_clear = interference_clear && environment::interference_clear();
            plan = shared.pulse.poll(poll.ticket, input);
            remember_policy_rejection(*entry, model::RejectionStage::core_plan);
            if (plan.press_candidate) increment(r.press_candidates);
            r.report_debt = shared.pulse.release_debt();
        }
    }
    if (has_output) {
        if (entry && entry->started && (plan.press_candidate || plan.release_candidate)) {
            // Recheck deadlines and current capture facts at the publication
            // boundary, without dropping the generation/publication gate.
            input.focused = environment::focused(); input.gameplay = environment::gameplay();
            input.menu_closed = environment::menu_closed();
            input.interference_clear = interference_clear && environment::interference_clear();
            input.now_ms = environment::now();
            input.source_fresh = source.connected && source.epoch == entry->receipt.source_epoch &&
                source.epoch && original_ms == source.observed_ms && input.now_ms >= original_ms &&
                input.now_ms - original_ms <= 100;
            plan = shared.pulse.poll({plan.generation}, input);
            remember_policy_rejection(*entry, model::RejectionStage::prepublish);
            stamp(entry->receipt, input.now_ms);
            entry->receipt.report_debt = shared.pulse.release_debt();
        }
        returned.Gamepad.wButtons = plan.pad.buttons;
        returned.dwPacketNumber = source.packets.translate(source.epoch, shared.pulse.revision(),
            raw_packet, returned.dwPacketNumber, raw_pad, pad(returned.Gamepad), plan.press_candidate);
        const bool published = publish(output, returned);
        if (entry && entry->started) {
            (void)shared.pulse.confirm(plan, published);
            auto& r = entry->receipt;
            if (published && plan.press_candidate) increment(r.press_publications);
            if (published && plan.release_candidate) increment(r.neutral_publications);
            r.report_debt = shared.pulse.release_debt();
            if (!published) {
                remember_rejection(*entry, 0, model::RejectionStage::publication);
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
}

void tick(std::uintptr_t, std::uintptr_t, bool ready) noexcept {
    LastError error;
    Actor actor; std::uint64_t owner{}, sequence{};
    {
        Lock lock(shared.lock);
        const auto now = environment::now();
        shared.ready = ready; shared.eligible_at = now; shared.client_thread = environment::thread();
        if (shared.active == no_entry) return;
        auto& entry = shared.entries[shared.active];
        if (entry.admitting) return;
        if (!ready) {
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
