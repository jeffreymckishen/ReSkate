#include "native_recovery.h"
#include "no_bail.h"
#include "Engine/Core/Hooks/hooks.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Abi/native_data.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/image_identity.h"
#include "Engine/Game/Build/20260929/skater_intent.h"
#include "Engine/Game/Skater/native_bool_pulse.h"
#include "Engine/Game/Skater/native_recovery_policy.h"
#include "Extension/Multiplayer/Remote/native_skater.h"
#include <array>
#include <atomic>
#include <cmath>
#include <initializer_list>
#include <limits>
#include <memory>

namespace dingosdk::skater_recovery {
namespace {
namespace native = addr::skater_intent;
using Update = void (__fastcall*)(std::uintptr_t, std::uintptr_t, std::uintptr_t);
constexpr std::size_t receipt_capacity = 8, no_entry = receipt_capacity;
constexpr std::uint64_t clock_fresh_ms = 250, completion_limit_ms = 6000;
constexpr std::uint32_t maximum_entity_index = 0x100000;
constexpr unsigned domain_budget = 16;
struct LastError { DWORD value = GetLastError(); ~LastError() { SetLastError(value); } };
struct TryExclusive {
    SRWLOCK& lock;
    bool held;
    explicit TryExclusive(SRWLOCK& value) noexcept : lock(value), held(TryAcquireSRWLockExclusive(&value) != 0) {}
    ~TryExclusive() { if (held) ReleaseSRWLockExclusive(&lock); }
};
struct Exclusive {
    SRWLOCK& lock;
    explicit Exclusive(SRWLOCK& value) noexcept : lock(value) { AcquireSRWLockExclusive(&lock); }
    ~Exclusive() { ReleaseSRWLockExclusive(&lock); }
};
bool span(std::uintptr_t address, std::size_t count) noexcept {
    return address >= 0x10000 && count && count <= memory::highest_user_address &&
        address <= memory::highest_user_address - count;
}
template<class T> bool get(std::uintptr_t address, T& value) noexcept { return memory::peek(address, value); }
template<std::size_t N>
bool matches(std::uintptr_t address, const std::array<unsigned char, N>& expected) noexcept {
    std::array<unsigned char, N> actual{};
    return get(address, actual) && actual == expected;
}
struct Asset {
    std::uintptr_t property{};
    std::array<std::uint8_t, 16> guid{};
    bool typed{};
    bool operator==(const Asset&) const = default;
};
Asset inspect_asset(std::uintptr_t base, std::uintptr_t property) noexcept {
    Asset out; out.property = property;
    if (property < 0x10000 + native::asset_property) return out;
    const auto asset = property - native::asset_property;
    std::array<std::uintptr_t, 3> first{}, again{};
    std::array<std::uint8_t, 16> guid{};
    const auto roots = [&](auto& values) noexcept {
        return get(asset, values[0]) && get(asset + native::asset_query, values[1]) && get(property, values[2]);
    };
    out.typed = span(asset, native::asset_span) && roots(first) &&
        get(asset - native::guid_before_asset, out.guid) && roots(again) &&
        get(asset - native::guid_before_asset, guid) && first == again && guid == out.guid &&
        first[0] == base + native::asset_vtable && first[1] == base + native::query_vtable &&
        first[2] == base + native::bool_vtable;
    return out;
}
bool handle_entity(std::uintptr_t base, std::uint64_t handle, std::uintptr_t& entity) noexcept {
    entity = 0;
    std::uintptr_t manager{}, table{}, manager_again{}, table_again{};
    std::uint32_t mask{}, mask_again{};
    if (!(handle & native::full_handle_mask) || !get(base + native::entity_manager, manager) ||
        !span(manager, native::manager_span) || !get(manager + native::manager_mask, mask) ||
        !get(manager + native::manager_table, table)) return false;
    const auto index = static_cast<std::uint32_t>(handle) & mask;
    if (index > maximum_entity_index || !span(table, std::size_t{index} * native::entity_slot_size + 16)) return false;
    const auto slot = table + std::uintptr_t{index} * native::entity_slot_size;
    std::array<std::uint64_t, 2> first{}, again{};
    if (!get(slot, first) || !get(slot, again) || first != again || first[0] != handle ||
        !get(manager + native::manager_mask, mask_again) || mask != mask_again ||
        !get(manager + native::manager_table, table_again) || table != table_again ||
        !get(base + native::entity_manager, manager_again) || manager != manager_again || !span(first[1], 8)) return false;
    entity = static_cast<std::uintptr_t>(first[1]); return true;
}
struct View {
    std::uintptr_t event{}, node{}, data{}, root{}, wrapper{}, binding{}, entity{};
    std::uint64_t handle{};
    Asset input{}, mirror{};
    std::array<std::uint64_t, native::node_words> words{};
    std::array<std::uint8_t, 16> data_guid{};
    std::array<std::uint8_t, 2> reset{}, after{};
    std::uint8_t wrapper_enabled{};
    bool coherent{};
};
View inspect(std::uintptr_t base, std::uintptr_t event, std::uintptr_t input, std::uintptr_t mirror,
             bool inspect_bytes) noexcept {
    View out; out.event = event;
    std::array<std::uint64_t, native::node_words> first{}, again{};
    if (!get(event, out.node) || !get(out.node, first) || first[0] != base + native::node_vtable) return out;
    const auto word = [&](std::uintptr_t offset) noexcept { return first[offset / sizeof(std::uint64_t)]; };
    out.data = word(native::node_data) & ~native::data_tag;
    out.root = word(native::node_root); out.handle = word(native::node_handle);
    out.wrapper = word(native::node_wrapper); out.binding = word(native::node_binding);
    out.input = inspect_asset(base, word(native::node_input));
    out.mirror = word(native::node_mirror) == out.input.property ? out.input : inspect_asset(base, word(native::node_mirror));
    std::uintptr_t data{}, data_again{}, event_again{};
    std::uint64_t root{}, root_again{};
    std::array<std::uint8_t, 2> reset{}, reset_again{}, values{}, values_again{};
    std::array<std::uint8_t, 16> guid{}, guid_again{};
    if (!span(out.data, native::data_span) || !get(out.data, data) || data != base + native::data_vtable ||
        !get(out.data + native::data_reset, reset) || !get(out.data - native::guid_before_asset, guid) ||
        !get(out.data, data_again) || data != data_again ||
        !get(out.data + native::data_reset, reset_again) || reset != reset_again ||
        !get(out.data - native::guid_before_asset, guid_again) || guid != guid_again ||
        !span(out.root, native::root_span) || !get(out.root + native::root_handle, root) ||
        !get(out.root + native::root_handle, root_again) || root != root_again || root != out.handle ||
        !span(out.wrapper, native::wrapper_enabled + 1) || !get(out.wrapper + native::wrapper_enabled, out.wrapper_enabled) ||
        !span(out.binding, 8) || (!out.input.typed && !out.mirror.typed) ||
        !handle_entity(base, out.handle, out.entity)) return out;
    if (inspect_bytes && (!get(input, values[0]) || !get(mirror, values[1]) ||
        !get(input, values_again[0]) || !get(mirror, values_again[1]) || values != values_again ||
        values[0] > 1 || values[1] > 1)) return out;
    out.words = first; out.data_guid = guid; out.reset = reset; out.after = values;
    std::uint8_t wrapper_again{};
    out.coherent = get(out.node, again) && first == again && get(event, event_again) && event_again == out.node &&
        get(out.wrapper + native::wrapper_enabled, wrapper_again) && wrapper_again == out.wrapper_enabled;
    return out;
}
bool same_view(const View& a, const View& b) noexcept {
    return a.coherent && b.coherent && a.event == b.event && a.node == b.node && a.data == b.data &&
        a.root == b.root && a.wrapper == b.wrapper && a.binding == b.binding && a.handle == b.handle && a.entity == b.entity &&
        a.input == b.input && a.mirror == b.mirror && a.words == b.words && a.data_guid == b.data_guid &&
        a.reset == b.reset && a.after == b.after && a.wrapper_enabled == b.wrapper_enabled;
}
struct Clock {
    std::uintptr_t base{}, entity{}, core{}, context{}, rig{};
    std::uint64_t serial{}, observed_ms{}, lifetime_epoch{};
    double time{};
};
struct Cursor { std::uint16_t next{}, hint = native::domain_count; };
struct Entry {
    skater_intent::Pulse pulse;
    std::atomic_flag dispatch_busy = ATOMIC_FLAG_INIT;
    RecoveryActor actor;
    Receipt receipt;
    std::array<Cursor, 2> cursors;
    std::atomic<bool> cancelled{};
    std::uint64_t owner{}, sequence{}, requested_serial{};
    double requested_time{};
    StandingTracker standing{native::offboard_physics_state};
    std::uint64_t native_true_calls{}, native_reset_calls{};
    State pending_state;
    Reason pending_issue{Reason::unavailable};
    std::uint64_t pending_ms{};
    bool pending_observed{}, pending_qualified{};
    bool occupied{}, admitting{}, claim_held{}, orphan{}, retiring{};
};
struct DispatchGate {
    Entry& entry;
    bool held;
    explicit DispatchGate(Entry& value, bool acquire = true) noexcept : entry(value),
        held(acquire && !value.dispatch_busy.test_and_set(std::memory_order_acquire)) {}
    bool take() noexcept {
        if (!held) held = !entry.dispatch_busy.test_and_set(std::memory_order_acquire);
        return held;
    }
    ~DispatchGate() { if (held) entry.dispatch_busy.clear(std::memory_order_release); }
};
struct Shared {
    SRWLOCK lock = SRWLOCK_INIT, clock_lock = SRWLOCK_INIT;
    std::array<Entry, receipt_capacity> entries;
    Clock clock;
    std::atomic<Update> original{};
    std::atomic<std::uintptr_t> base{}, ready_base{};
    std::atomic<std::size_t> active{no_entry};
    std::atomic<std::uint64_t> active_sequence{};
    std::atomic<bool> eligible{};
    std::atomic<std::uint64_t> eligible_at{};
    std::uint64_t next_sequence = 1;
    DWORD client_thread{};
    bool attempted{}, step_registered{};
};
// Initialized before the hook is attached, and retained for all native relays.
Shared shared;
bool read_clock(const RecoveryActor& actor, Clock& value) noexcept {
    if (!TryAcquireSRWLockShared(&shared.clock_lock)) return false;
    value = shared.clock;
    ReleaseSRWLockShared(&shared.clock_lock);
    const auto now = GetTickCount64();
    return value.base == actor.base && value.entity == actor.entity && value.core == actor.core &&
        value.context == actor.context && value.rig == actor.rig && value.lifetime_epoch == actor.lifetime_epoch &&
        value.serial && std::isfinite(value.time) &&
        value.time >= 0 && now >= value.observed_ms && now - value.observed_ms < clock_fresh_ms;
}
void step(const NoBailSkater& actor, float seconds, bool) noexcept {
    if (!std::isfinite(seconds) || seconds < 0 || seconds > .1f) return;
    std::uint64_t epoch{}, after{};
    if (!multiplayer::entity_destruction_epoch(actor.base, epoch)) return;
    TryExclusive lock(shared.clock_lock); if (!lock.held) return;
    if (!multiplayer::entity_destruction_epoch(actor.base, after) || after != epoch) return;
    auto& clock = shared.clock;
    if (clock.base != actor.base || clock.entity != actor.entity || clock.core != actor.core ||
        clock.context != actor.context || clock.rig != actor.rig || clock.lifetime_epoch != epoch) {
        clock = {};
        clock.base = actor.base; clock.entity = actor.entity; clock.core = actor.core;
        clock.context = actor.context; clock.rig = actor.rig; clock.lifetime_epoch = epoch;
    }
    if (clock.serial == std::numeric_limits<std::uint64_t>::max() || !std::isfinite(clock.time + seconds)) return;
    ++clock.serial; clock.time += seconds; clock.observed_ms = GetTickCount64();
}
bool native_get(std::uintptr_t base, std::uintptr_t property, std::uintptr_t binding, std::uint8_t& value) noexcept {
    __try {
        value = reinterpret_cast<std::uint8_t(__fastcall*)(std::uintptr_t, std::uintptr_t)>(
            base + native::bool_get_prefix.rva)(property, binding); return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool native_set(std::uintptr_t base, std::uintptr_t property, std::uintptr_t binding, std::uint8_t value) noexcept {
    __try {
        reinterpret_cast<void(__fastcall*)(std::uintptr_t, std::uintptr_t, std::uint8_t)>(
            base + native::bool_set_prefix.rva)(property, binding, value); return true;
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool native_find(std::uint16_t domain, const char* name, std::uintptr_t& asset) noexcept {
    __try { asset = game::native_data().find_asset(domain, name); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool asset_contract(std::uintptr_t base, std::uintptr_t property,
                    const std::array<std::uint8_t, 16>& guid, bool writable) noexcept {
    const auto asset = inspect_asset(base, property);
    std::uintptr_t getter{}, setter{};
    return asset.typed && asset.guid == guid && get(base + native::bool_vtable + native::getter_slot, getter) &&
        getter == base + native::bool_get_prefix.rva && matches(getter, native::bool_get_code) &&
        (!writable || (get(base + native::bool_vtable + native::setter_slot, setter) &&
            setter == base + native::bool_set_prefix.rva && matches(setter, native::bool_set_code)));
}
struct AssetLease { std::uintptr_t property{}, owner_slot{}, owner{}; };
bool lease_current(std::uintptr_t base, const AssetLease& lease, bool allowed) noexcept {
    if (!lease.property || !asset_contract(base, lease.property, allowed ? native::allowed_guid : native::get_up_guid, !allowed))
        return false;
    std::uintptr_t owner{};
    return !lease.owner_slot || (get(lease.owner_slot, owner) && owner == lease.owner && owner != 0);
}
bool resolve_asset(Entry& entry, const View& view, bool allowed, AssetLease& lease) noexcept {
    lease = {};
    const auto base = entry.actor.base;
    const auto& guid = allowed ? native::allowed_guid : native::get_up_guid;
    for (const auto* asset : {&view.input, &view.mirror})
        if (asset->typed && asset->guid == guid && asset_contract(base, asset->property, guid, !allowed)) {
            lease.property = asset->property; return true;
        }
    if (reinterpret_cast<std::uintptr_t>(game::native_data().find_asset) != base + native::asset_find_prefix.rva ||
        !matches(base + native::asset_find_prefix.rva, native::asset_find_code)) return false;
    auto& cursor = entry.cursors[allowed ? 1 : 0];
    enum class Result { empty, miss, found };
    const auto query = [&](std::uint16_t domain) noexcept {
        const auto address = base + native::domain_owners + std::uintptr_t{domain} * native::domain_stride;
        std::uintptr_t owner{}, again{}, asset{};
        if (!get(address, owner) || !owner) return Result::empty;
        const std::array names{allowed ? native::allowed_lower : native::get_up_lower,
                               allowed ? native::allowed_upper : native::get_up_upper};
        for (const auto name : names) {
            if (!native_find(domain, name, asset) || !get(address, again) || owner != again) return Result::miss;
            if (asset) {
                if (!span(asset, native::asset_span) || !asset_contract(base, asset + native::asset_property, guid, !allowed))
                    return Result::miss;
                lease = {asset + native::asset_property, address, owner}; return Result::found;
            }
        }
        return Result::miss;
    };
    unsigned budget = domain_budget;
    const auto hint = cursor.hint;
    if (hint < native::domain_count) {
        const auto result = query(hint);
        if (result == Result::found) return true;
        if (result == Result::miss) --budget;
    }
    for (unsigned visited = 0; visited < native::domain_count && budget; ++visited) {
        const auto domain = cursor.next;
        cursor.next = static_cast<std::uint16_t>((cursor.next + 1) % native::domain_count);
        if (domain == hint) continue;
        const auto result = query(domain);
        if (result == Result::found) { cursor.hint = domain; return true; }
        if (result == Result::miss) --budget;
    }
    return false;
}
bool known_ragdoll(const RecoveryActor& actor) noexcept {
    struct Witness {
        std::uintptr_t parent{}, active{}, active_vtable{}, context{}, rig{}, board{}, expected_board{}, trick{}, offboard{};
        std::uint32_t state{};
        std::uint8_t ragdoll{};
        bool operator==(const Witness&) const = default;
    };
    const auto capture = [&](Witness& value) noexcept {
        std::uintptr_t vtable{};
        if (!get(actor.context + native::physics_state, value.state) || value.state != native::offboard_physics_state ||
            !get(actor.core + native::parent, value.parent) || !get(value.parent, vtable) ||
            vtable != actor.base + native::offboard_parent_vtable ||
            !get(value.parent + native::parent_context, value.context) || value.context != actor.context ||
            !get(value.parent + native::parent_rig, value.rig) || value.rig != actor.rig ||
            !get(value.parent + native::parent_board, value.board) ||
            !get(actor.core + native::board_holder, value.expected_board) || value.board != value.expected_board ||
            !get(value.parent + native::parent_active, value.active) || !get(value.active, value.active_vtable) ||
            !get(actor.core + native::trick_state, value.trick) ||
            !get(value.trick + native::offboard_state, value.offboard) ||
            !get(value.offboard + native::ragdoll, value.ragdoll) || value.ragdoll != 1) return false;
        for (const auto& state : native::ragdoll_states)
            if (value.active == value.parent + state[0] && value.active_vtable == actor.base + state[1]) return true;
        return false;
    };
    Witness first, again;
    return capture(first) && capture(again) && first == again;
}
void pulse_receipt(Entry& entry) noexcept {
    const auto& pulse = entry.pulse; auto& receipt = entry.receipt;
    receipt.true_ms = pulse.true_ms.load(); receipt.reset_ms = pulse.reset_ms.load();
    receipt.true_serial = pulse.true_serial.load(); receipt.reset_serial = pulse.reset_serial.load();
    receipt.true_time = pulse.true_time.load(); receipt.reset_time = pulse.reset_time.load();
    receipt.prior_known = pulse.prior_available.load(); receipt.prior_value = receipt.prior_known && !pulse.prior_false.load();
    receipt.true_entered = pulse.true_calls.load() != 0; receipt.true_returned = pulse.true_returned.load();
    receipt.true_readback_known = pulse.true_readback_available.load(); receipt.true_readback = pulse.true_readback.load();
    receipt.reset_pending = pulse.pending(); receipt.reset_entered = pulse.reset_calls.load() != 0;
    receipt.reset_returned = pulse.reset_returned.load(); receipt.reset_readback_known = pulse.reset_readback_available.load();
    receipt.reset_false = pulse.reset_false.load(); receipt.cleared_before_reset = pulse.cleared_before_reset.load();
    receipt.unresolved = pulse.unresolved(); receipt.start_attempts = pulse.start_attempts.load();
    receipt.cleanup_attempts = pulse.cleanup_attempts.load();
    receipt.native_true_calls = entry.native_true_calls; receipt.native_reset_calls = entry.native_reset_calls;
    const auto& standing = entry.standing.snapshot();
    receipt.standing_samples = standing.samples; receipt.standing_seconds = standing.seconds;
    receipt.standing_observed = standing.observed; receipt.stable_observed = standing.eligible;
    receipt.quarantined = terminal(receipt.status) && receipt.unresolved && !receipt.actor_retired;
}
void reset_standing(Entry& entry) noexcept {
    entry.standing.unavailable();
}
void observe_standing(Entry& entry, const State& state, const Clock& clock, std::uint64_t observed_ms) noexcept {
    if (!entry.pulse.reset_false.load()) { reset_standing(entry); return; }
    (void)entry.standing.observe(state, {entry.pulse.reset_serial.load(), entry.pulse.reset_time.load()},
        {clock.serial, clock.time}, observed_ms);
}
// Own both the client lifecycle lock and the nonblocking callback gate before
// reading the pulse atomics as one receipt. The individual atomics alone do
// not constitute a coherent native transaction snapshot.
void publish_entry(Entry& entry, std::uint64_t now) noexcept {
    auto& receipt = entry.receipt;
    // Completion freezes a historical qualified observation, not a promise
    // against a later fall. Its state, suffix and timestamp remain readable
    // after callbacks stop. Negative terminal records still merge reset debt.
    if (receipt.status == Status::completed) return;
    Clock current;
    const bool available = read_clock(entry.actor, current);
    entry.standing.check_fresh(available, {current.serial, current.time});
    pulse_receipt(entry);
    if (entry.pending_ms) {
        receipt.observed_ms = entry.pending_ms;
        if (entry.pending_observed) receipt.state = entry.pending_state;
    }
    if (!terminal(receipt.status)) {
        const auto phase = entry.pulse.phase.load(std::memory_order_acquire);
        if (entry.cancelled.load(std::memory_order_acquire)) {
            receipt.status = Status::cancelled;
            if (receipt.reason == Reason::none) receipt.reason = Reason::cancelled;
        } else if (phase == skater_intent::PulsePhase::preexisting_true) receipt.status = Status::already_true;
        else if (receipt.stable_observed) receipt.status = Status::completed;
        else if (phase == skater_intent::PulsePhase::start_exhausted || phase == skater_intent::PulsePhase::cleanup_exhausted) {
            receipt.status = Status::rejected; receipt.reason = Reason::unavailable;
        } else if (receipt.reset_false) receipt.status = Status::reset;
        else if (receipt.true_entered) receipt.status = Status::entered;
        if (entry.pending_ms && !entry.pending_qualified && entry.pending_issue != Reason::none &&
            entry.pending_issue != Reason::unavailable) {
            receipt.status = Status::invalidated; receipt.reason = entry.pending_issue;
        }
        if (!terminal(receipt.status) && now >= receipt.requested_ms &&
            now - receipt.requested_ms >= (receipt.true_entered ? completion_limit_ms : skater_intent::pulse_start_ms)) {
            receipt.status = Status::expired; receipt.reason = Reason::expired;
        }
        if (receipt.status == Status::completed && entry.standing.freeze()) {
            const auto& witness = entry.standing.snapshot();
            receipt.state = witness.state; receipt.observed_ms = witness.observed_ms;
        }
    }
    entry.pending_ms = 0; entry.pending_observed = entry.pending_qualified = false;
    pulse_receipt(entry);
}
// Client phase only, outside native dispatch. The retiring flag prevents a new
// callback while the shared actor claim is being revoked without this lock.
void retire_entry(std::size_t index) noexcept {
    RecoveryActor actor; std::uint64_t owner{}, sequence{}; bool resolved{};
    {
        Exclusive lock(shared.lock);
        auto& entry = shared.entries[index];
        if (!entry.occupied || !entry.claim_held || entry.admitting || entry.retiring) return;
        DispatchGate gate(entry); if (!gate.held) return;
        publish_entry(entry, GetTickCount64());
        if (!terminal(entry.receipt.status)) return;
        actor = entry.actor; owner = entry.owner; sequence = entry.sequence;
        resolved = !entry.pulse.unresolved();
        entry.retiring = true;
    }
    const bool retired = recovery_retire(owner, sequence, actor, resolved);
    {
        Exclusive lock(shared.lock);
        auto& entry = shared.entries[index];
        if (!entry.occupied || entry.owner != owner || entry.sequence != sequence) return;
        entry.retiring = false;
        if (!retired) return;
        entry.claim_held = false;
        if (!resolved) entry.receipt.actor_retired = true;
        pulse_receipt(entry);
        auto expected = index;
        if (shared.active.compare_exchange_strong(expected, no_entry, std::memory_order_acq_rel))
            shared.active_sequence.store(0, std::memory_order_release);
    }
}
void observe_update(std::uintptr_t event, std::uintptr_t input, std::uintptr_t mirror,
                    std::size_t index, std::uint64_t invocation_sequence) noexcept {
    static thread_local bool observing{};
    if (observing) return;
    struct Guard { bool& value; explicit Guard(bool& v) noexcept : value(v) { value = true; } ~Guard() { value = false; } } guard(observing);
    if (index >= receipt_capacity) return;
    auto& entry = shared.entries[index];
    DispatchGate dispatch(entry, false);
    RecoveryActor expected; std::uint64_t owner{}, sequence{}, started{}, requested_serial{}; double requested_time{};
    {
        TryExclusive lock(shared.lock); if (!lock.held) return;
        if (!entry.occupied || entry.sequence != invocation_sequence || entry.admitting || entry.retiring ||
            !entry.claim_held || !dispatch.take()) return;
        if (terminal(entry.receipt.status) && !entry.pulse.pending()) return;
        expected = entry.actor; owner = entry.owner; sequence = entry.sequence;
        started = entry.receipt.requested_ms; requested_serial = entry.requested_serial; requested_time = entry.requested_time;
    }
    State observed_state; Clock clock; bool observed{}, qualified{};
    bool matching{};
    Reason issue = Reason::unavailable;
    {
        actor_control::Call call;
        if (recovery_enter(owner, sequence, expected, call)) {
            const auto view = inspect(expected.base, event, input, mirror, true);
            const auto now = GetTickCount64();
            matching = view.coherent && view.entity == expected.entity;
            if (matching && read_clock(expected, clock) && clock.serial > requested_serial &&
                clock.time > requested_time && clock.observed_ms >= started) {
                const skater_intent::PulseKey key{view.binding, view.handle, clock.serial, clock.time};
                AssetLease get_up;
                const auto common = [&](const skater_intent::PulseKey& current, bool cleanup) noexcept {
                    RecoveryActor live; State state; Clock after;
                    if (!recovery_inspect(owner, sequence, expected, live, state, issue, cleanup) || live != expected ||
                        !same_view(view, inspect(expected.base, event, input, mirror, true)) || !read_clock(expected, after) ||
                        after.serial != current.serial || after.time != current.time) return false;
                    if (get_up.property && !lease_current(expected.base, get_up, false)) return false;
                    observed_state = state; observed = true;
                    if (!cleanup) {
                        const auto wall = GetTickCount64(), eligible_at = shared.eligible_at.load(std::memory_order_acquire);
                        if (entry.cancelled.load(std::memory_order_acquire) || !shared.eligible.load(std::memory_order_acquire) ||
                            wall < eligible_at || wall - eligible_at >= clock_fresh_ms || !known_ragdoll(live)) return false;
                    }
                    return true;
                };
                const auto allowed = [&](const skater_intent::PulseKey& current) noexcept {
                    AssetLease predicate; std::uint8_t value{};
                    return resolve_asset(entry, view, true, predicate) && common(current, false) &&
                        lease_current(expected.base, predicate, true) &&
                        native_get(expected.base, predicate.property, current.binding, value) && value == 1 &&
                        lease_current(expected.base, predicate, true) && common(current, false);
                };
                entry.pulse.dispatch(key, started, now, shared.eligible.load(std::memory_order_acquire),
                    entry.cancelled.load(std::memory_order_acquire), false,
                    [&](std::uintptr_t& property) noexcept {
                        if (!resolve_asset(entry, view, false, get_up)) return false;
                        property = get_up.property; return true;
                    },
                    common, allowed,
                    [&](auto property, auto binding, std::uint8_t& value) noexcept {
                        return property == get_up.property && lease_current(expected.base, get_up, false) &&
                            native_get(expected.base, property, binding, value) && lease_current(expected.base, get_up, false);
                    },
                    [&](auto property, auto binding, std::uint8_t value) noexcept {
                        if (!common(key, value == 0) || (value && !allowed(key)) ||
                            property != get_up.property || !lease_current(expected.base, get_up, false)) return false;
                        if (value) ++entry.native_true_calls; else ++entry.native_reset_calls;
                        return native_set(expected.base, property, binding, value);
                    });
                // After reset, eligibility to START is irrelevant. Observe the
                // unchanged actor through the same callback/clock instead.
                qualified = common(key, true);
            }
        }
    }
    if (matching) {
        // This fixed observation and the pulse atomics share dispatch_busy.
        // The client publishes them under its own lock after taking that gate;
        // this native path never blocks waiting for a receipt reader.
        entry.pending_ms = GetTickCount64(); entry.pending_state = observed_state;
        entry.pending_observed = observed; entry.pending_qualified = qualified; entry.pending_issue = issue;
        if (qualified) observe_standing(entry, observed_state, clock, entry.pending_ms); else reset_standing(entry);
    }
}
void __fastcall update_hook(std::uintptr_t event, std::uintptr_t input, std::uintptr_t mirror) {
    const auto incoming = GetLastError();
    const auto original = shared.original.load(std::memory_order_acquire);
    const auto index = shared.active.load(std::memory_order_acquire);
    const auto sequence = shared.active_sequence.load(std::memory_order_acquire);
    const auto base = shared.ready_base.load(std::memory_order_acquire);
    std::uint64_t before{}, after{};
    const bool admitted = index < receipt_capacity && sequence && base &&
        shared.active.load(std::memory_order_acquire) == index &&
        multiplayer::entity_destruction_epoch(base, before);
    SetLastError(incoming); original(event, input, mirror);
    const auto returned = GetLastError();
    // An invocation admitted after the original started, or spanning an actor
    // destruction, cannot provide this request's canonical callback context.
    if (admitted && shared.active.load(std::memory_order_acquire) == index &&
        shared.active_sequence.load(std::memory_order_acquire) == sequence &&
        multiplayer::entity_destruction_epoch(base, after) && before == after)
        observe_update(event, input, mirror, index, sequence);
    SetLastError(returned);
}
bool initialize(std::uintptr_t base) noexcept {
    if (shared.ready_base.load(std::memory_order_acquire)) return shared.ready_base.load() == base;
    if (shared.attempted) return false;
    shared.attempted = true;
    if (!supported_build::running_image_matches(base) ||
        !matches(base + native::begin_prefix.rva, native::begin_code) ||
        !matches(base + native::update_prefix.rva, native::update_code) ||
        !matches(base + native::end_prefix.rva, native::end_code) ||
        !matches(base + native::bool_get_prefix.rva, native::bool_get_code) ||
        !matches(base + native::bool_set_prefix.rva, native::bool_set_code) ||
        !matches(base + native::asset_find_prefix.rva, native::asset_find_code) ||
        reinterpret_cast<std::uintptr_t>(game::native_data().find_asset) != base + native::asset_find_prefix.rva) return false;
    for (const auto& contract : addr::offboard_flight::offboard_owner_contracts)
        if (!matches(base + contract.rva, contract.bytes)) return false;
    if (!add_no_bail_step_listener(&step)) return false;
    shared.step_registered = true;
    const auto status = hook_initialize();
    if (status != HookOk && status != HookAlreadyInitialized) return false;
    auto* target = reinterpret_cast<void*>(base + native::update_prefix.rva); void* relay{};
    if (hook_prepare(target, reinterpret_cast<void*>(&update_hook), &relay) != HookOk || !relay) return false;
    shared.base.store(base, std::memory_order_release);
    shared.original.store(reinterpret_cast<Update>(relay), std::memory_order_release);
    HookBatch batch;
    if (hook_enable(target) != HookOk || hook_apply_queued() != HookOk) {
        // The permanent relay survives retirement. Remove this queued target
        // so the batch destructor does not retry an uncertain failed attach.
        (void)hook_remove(target); return false;
    }
    shared.ready_base.store(base, std::memory_order_release); return true;
}
Entry* find(std::uint64_t owner, Handle handle) noexcept {
    if (!owner || !handle.sequence) return nullptr;
    for (auto& entry : shared.entries)
        if (entry.occupied && entry.owner == owner && entry.sequence == handle.sequence) return &entry;
    return nullptr;
}
} // namespace

bool request(std::uint64_t owner, Handle& handle, Reason& reason) noexcept {
    LastError error; handle = {}; reason = Reason::unavailable;
    if (!owner) { reason = Reason::invalid_owner; return false; }
    const auto now = GetTickCount64(), eligible_at = shared.eligible_at.load(std::memory_order_acquire);
    if (GetCurrentThreadId() != shared.client_thread || !shared.ready_base.load(std::memory_order_acquire) ||
        !shared.eligible.load(std::memory_order_acquire) || now < eligible_at || now - eligible_at >= clock_fresh_ms) return false;
    std::size_t index = no_entry; std::uint64_t sequence{};
    {
        Exclusive lock(shared.lock);
        for (const auto& entry : shared.entries) if (entry.occupied &&
            (entry.admitting || entry.claim_held || !terminal(entry.receipt.status))) { reason = Reason::busy; return false; }
        for (std::size_t i = 0; i < shared.entries.size(); ++i) if (!shared.entries[i].occupied) { index = i; break; }
        if (index == no_entry || !shared.next_sequence) { reason = Reason::receipt_capacity; return false; }
        auto& entry = shared.entries[index];
        sequence = shared.next_sequence++;
        entry.occupied = entry.admitting = true; entry.owner = owner; entry.sequence = sequence;
        entry.receipt.handle.sequence = sequence; entry.receipt.requested_ms = GetTickCount64();
        entry.receipt.standing_required_seconds = StandingTracker::required_seconds;
    }
    RecoveryActor actor, live; State state; Clock clock;
    bool acquired = recovery_acquire(owner, sequence, actor, reason);
    bool accepted = acquired && recovery_inspect(owner, sequence, actor, live, state, reason) && live == actor &&
        known_ragdoll(actor) && read_clock(actor, clock);
    {
        Exclusive lock(shared.lock); auto& entry = shared.entries[index];
        entry.actor = actor; entry.claim_held = acquired; entry.admitting = false; entry.receipt.state = state;
        if (accepted && entry.pulse.rearm(true)) {
            entry.requested_serial = clock.serial; entry.requested_time = clock.time;
            shared.active_sequence.store(sequence, std::memory_order_release);
            shared.active.store(index, std::memory_order_release); handle.sequence = sequence; reason = Reason::none;
        } else {
            accepted = false;
            if (reason == Reason::none) reason = Reason::unsupported_state;
            entry.receipt.status = Status::rejected; entry.receipt.reason = reason;
        }
    }
    if (!accepted) {
        retire_entry(index);
        Exclusive lock(shared.lock); auto& entry = shared.entries[index];
        if (!entry.claim_held) { std::destroy_at(&entry); std::construct_at(&entry); }
    }
    return accepted;
}
bool read(std::uint64_t owner, Handle handle, Receipt& receipt) noexcept {
    LastError error; std::size_t index{};
    {
        Exclusive lock(shared.lock); auto* entry = find(owner, handle);
        if (!entry) return false;
        DispatchGate gate(*entry);
        if (!gate.held) {
            // A retained published snapshot is coherent but may be old. Keep
            // its original observation timestamp; never synthesize freshness.
            receipt = entry->receipt; return true;
        }
        publish_entry(*entry, GetTickCount64());
        index = static_cast<std::size_t>(entry - shared.entries.data());
    }
    retire_entry(index);
    Exclusive lock(shared.lock); const auto* entry = find(owner, handle);
    if (!entry) return false;
    receipt = entry->receipt; return true;
}
bool cancel(std::uint64_t owner, Handle handle) noexcept {
    LastError error; std::size_t index{};
    {
        Exclusive lock(shared.lock); auto* entry = find(owner, handle);
        if (!entry) return false;
        DispatchGate gate(*entry);
        if (!gate.held) return false;
        publish_entry(*entry, GetTickCount64());
        if (entry->receipt.status != Status::pending || entry->pulse.true_calls.load(std::memory_order_acquire)) return false;
        entry->cancelled.store(true, std::memory_order_release);
        entry->receipt.reason = Reason::cancelled;
        publish_entry(*entry, GetTickCount64());
        index = static_cast<std::size_t>(entry - shared.entries.data());
    }
    retire_entry(index); return true;
}
bool acknowledge(std::uint64_t owner, Handle handle) noexcept {
    LastError error; Exclusive lock(shared.lock); auto* entry = find(owner, handle);
    if (!entry || entry->admitting || entry->retiring || entry->claim_held ||
        entry->dispatch_busy.test_and_set(std::memory_order_acquire)) return false;
    publish_entry(*entry, GetTickCount64());
    if (!terminal(entry->receipt.status) || entry->receipt.quarantined) {
        entry->dispatch_busy.clear(std::memory_order_release); return false;
    }
    std::destroy_at(entry); std::construct_at(entry); return true;
}
void release_all(std::uint64_t owner) noexcept {
    LastError error;
    {
        Exclusive lock(shared.lock);
        for (auto& entry : shared.entries) if (entry.occupied && entry.owner == owner) {
            entry.orphan = true; entry.cancelled.store(true, std::memory_order_release);
            if (!terminal(entry.receipt.status)) {
                entry.receipt.reason = Reason::owner_released;
            }
            DispatchGate gate(entry); if (gate.held) publish_entry(entry, GetTickCount64());
        }
    }
    for (std::size_t i = 0; i < receipt_capacity; ++i) retire_entry(i);
}
void tick(std::uintptr_t base, std::uintptr_t, bool ready) noexcept {
    LastError error;
    shared.client_thread = GetCurrentThreadId();
    if (ready) (void)initialize(base);
    const auto now = GetTickCount64();
    shared.eligible.store(ready && shared.ready_base.load(std::memory_order_acquire) == base, std::memory_order_release);
    shared.eligible_at.store(now, std::memory_order_release);
    {
        Exclusive lock(shared.lock);
        for (auto& entry : shared.entries) if (entry.occupied && !entry.admitting) {
            DispatchGate gate(entry); if (!gate.held) continue;
            publish_entry(entry, now);
            if (!terminal(entry.receipt.status) && (!ready || (now >= entry.receipt.requested_ms &&
                now - entry.receipt.requested_ms >= (entry.receipt.true_entered ? completion_limit_ms : skater_intent::pulse_start_ms)))) {
                entry.cancelled.store(true, std::memory_order_release);
                entry.receipt.status = ready ? Status::expired : Status::invalidated;
                entry.receipt.reason = ready ? Reason::expired : Reason::context_changed;
                reset_standing(entry); pulse_receipt(entry);
            }
        }
    }
    for (std::size_t i = 0; i < receipt_capacity; ++i) retire_entry(i);
    {
        Exclusive lock(shared.lock);
        for (auto& entry : shared.entries) if (entry.occupied && entry.orphan && !entry.admitting && !entry.retiring &&
            !entry.claim_held && terminal(entry.receipt.status) && !entry.receipt.quarantined &&
            !entry.dispatch_busy.test_and_set(std::memory_order_acquire)) {
            std::destroy_at(&entry); std::construct_at(&entry);
        }
    }
}
} // namespace dingosdk::skater_recovery
