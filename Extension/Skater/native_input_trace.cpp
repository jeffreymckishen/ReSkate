#include "native_input_trace.h"
#include "no_bail.h"
#include "Engine/Core/Hooks/hooks.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/image_identity.h"
#include "Engine/Game/Build/20260929/native_input_trace.h"
#include "Extension/Multiplayer/Remote/native_skater.h"
#include <array>
#include <atomic>
#include <intrin.h>
#include <limits>
#include <string>

// Written once before the hook is enabled. The assembly unknown lane reads
// only these frozen cells and never acquires a C++ callback prototype.
extern "C" {
std::uintptr_t reskate_native_input_trace_relay{};
std::uintptr_t reskate_native_input_trace_interpreter_return{};
std::uintptr_t reskate_native_input_trace_alternate_return{};
void reskate_native_input_trace_gate();
}

namespace dingosdk::native_input_trace {
namespace {
namespace native = addr::native_input_trace;
using Update = void (__fastcall*)(std::uintptr_t, std::uintptr_t);
constexpr std::uint64_t cache_fresh_ms = 250;
constexpr std::size_t asset_capacity = input_trace::asset_token_capacity;
static_assert(sizeof(std::uintptr_t) == 8);

struct LastError {
    DWORD value = GetLastError();
    ~LastError() { SetLastError(value); }
};
struct Exclusive {
    SRWLOCK& lock;
    explicit Exclusive(SRWLOCK& value) noexcept : lock(value) { AcquireSRWLockExclusive(&lock); }
    ~Exclusive() { ReleaseSRWLockExclusive(&lock); }
};
struct TryExclusive {
    SRWLOCK& lock;
    bool held;
    explicit TryExclusive(SRWLOCK& value) noexcept : lock(value), held(TryAcquireSRWLockExclusive(&lock) != 0) {}
    ~TryExclusive() { if (held) ReleaseSRWLockExclusive(&lock); }
};
struct Cache {
    std::uintptr_t base{}, client{};
    std::uint64_t observed_ms{};
    DWORD thread{};
    bool ready{};
};
struct Tokens {
    std::uint64_t owner{}, sequence{}, busy_at_start{};
    std::uint32_t count{};
    std::array<std::uintptr_t, asset_capacity> assets{};
};
struct Shared {
    SRWLOCK lock = SRWLOCK_INIT;
    input_trace::Ledger ledger;
    std::array<Tokens, input_trace::ticket_capacity> tokens;
    Cache cache;
    std::atomic<std::uintptr_t> installed_base{};
    std::atomic<std::uint64_t> active_until{}, observer_busy{};
    std::atomic<bool> attempted{};
};
// Construct the fixed ledger and lock before publishing any native hook.
Shared shared;

bool span(std::uintptr_t address, std::size_t bytes) noexcept {
    return address >= 0x10000 && bytes && bytes <= memory::highest_user_address &&
        address <= memory::highest_user_address - bytes;
}
template<class T> bool get(std::uintptr_t address, T& value) noexcept { return memory::peek(address, value); }
bool word(std::uintptr_t object, std::uintptr_t offset, std::uintptr_t& value) noexcept {
    return span(object, offset + sizeof(value)) && get(object + offset, value);
}
template<std::size_t N>
bool matches(std::uintptr_t address, const std::array<unsigned char, N>& expected) noexcept {
    std::array<unsigned char, N> actual{};
    return get(address, actual) && actual == expected;
}
bool current(const Cache& cache, std::uint64_t now) noexcept {
    return cache.ready && cache.base && cache.client && now >= cache.observed_ms &&
        now - cache.observed_ms <= cache_fresh_ms;
}
bool initialize(const Cache& cache) noexcept {
    const auto installed = shared.installed_base.load(std::memory_order_acquire);
    if (installed) return installed == cache.base;
    if (shared.attempted.exchange(true, std::memory_order_acq_rel)) return false;
    if (!supported_build::running_image_matches(cache.base) ||
        !matches(cache.base + native::update, native::update_code) ||
        !matches(cache.base + native::interpreter_lane, native::interpreter_code) ||
        !matches(cache.base + native::alternate_lane, native::alternate_code)) return false;
    if (!multiplayer::entity_destruction_hook_available(cache.base)) {
        std::string detail;
        if (!multiplayer::install_entity_hooks(cache.base, detail)) return false;
    }
    if (!multiplayer::entity_destruction_hook_available(cache.base)) return false;
    const auto status = hook_initialize();
    if (status != HookOk && status != HookAlreadyInitialized) return false;
    auto* target = reinterpret_cast<void*>(cache.base + native::update);
    void* relay{};
    if (hook_prepare(target, reinterpret_cast<void*>(&reskate_native_input_trace_gate), &relay) != HookOk || !relay) return false;
    reskate_native_input_trace_relay = reinterpret_cast<std::uintptr_t>(relay);
    reskate_native_input_trace_interpreter_return = cache.base + native::interpreter_return;
    reskate_native_input_trace_alternate_return = cache.base + native::alternate_return;
    HookBatch batch;
    if (hook_enable(target) != HookOk || hook_apply_queued() != HookOk) {
        // Do not let the batch destructor retry an uncertain failed attach.
        // The original relay remains permanent even when this target retires.
        (void)hook_remove(target);
        return false;
    }
    shared.installed_base.store(cache.base, std::memory_order_release);
    return true;
}
Tokens* find_tokens(std::uint64_t owner, std::uint64_t sequence) noexcept {
    for (auto& tokens : shared.tokens)
        if (tokens.owner == owner && tokens.sequence == sequence) return &tokens;
    return nullptr;
}
std::uint32_t asset_token(Tokens& tokens, std::uintptr_t asset) noexcept {
    if (!asset) return 0;
    for (std::uint32_t i = 0; i < tokens.count; ++i)
        if (tokens.assets[i] == asset) return i + 1;
    if (tokens.count == tokens.assets.size()) return 0;
    tokens.assets[tokens.count] = asset;
    return ++tokens.count;
}

struct Borrowed {
    std::uintptr_t node{}, raw_data{}, data{}, container{}, raw_asset{}, asset{};
    std::uint8_t condition{};
    bool condition_known{}, known{};
    bool operator==(const Borrowed&) const = default;
};
Borrowed borrowed(std::uintptr_t event, std::uintptr_t condition) noexcept {
    Borrowed result;
    result.condition_known = get(condition, result.condition) && result.condition <= 1;
    if (!get(event, result.node) || !word(result.node, native::node_data, result.raw_data)) return result;
    result.data = result.raw_data & ~native::reference_tag;
    if (!word(result.node, native::node_container, result.container) ||
        !word(result.data, native::data_asset, result.raw_asset)) return result;
    result.asset = result.raw_asset & ~native::reference_tag;
    result.known = true;
    return result;
}
struct Local {
    NoBailSkater actor;
    std::uintptr_t client{}, root{}, raw_word{};
    bool known{};
};
bool same_actor(const NoBailSkater& a, const NoBailSkater& b) noexcept {
    return a.base == b.base && a.entity == b.entity && a.core == b.core &&
        a.context == b.context && a.rig == b.rig;
}
bool same_local(const Local& a, const Local& b) noexcept {
    return a.known && b.known && same_actor(a.actor, b.actor) && a.client == b.client &&
        a.root == b.root && a.raw_word == b.raw_word;
}
Local local(const Cache& cache) noexcept {
    Local result;
    if (!try_no_bail_skater(0, result.actor, result.client) || result.actor.base != cache.base ||
        result.client != cache.client || !word(result.actor.core, native::core_input_root, result.root) ||
        !word(result.root, native::input_context_word, result.raw_word)) return result;
    result.known = true;
    return result;
}
struct Sample {
    Borrowed input;
    Local owner;
    std::uint64_t epoch{};
    Issue issue{Issue::none};
    bool epoch_known{};
};
Sample sample(const Cache& cache, std::uintptr_t event, std::uintptr_t condition, std::uint64_t now) noexcept {
    Sample result;
    if (!current(cache, now)) { result.issue = Issue::service_unavailable; return result; }
    result.epoch_known = multiplayer::entity_destruction_epoch(cache.base, result.epoch);
    result.input = borrowed(event, condition);
    result.owner = local(cache);
    std::uint64_t after{};
    result.epoch_known = result.epoch_known &&
        multiplayer::entity_destruction_epoch(cache.base, after) && after == result.epoch;
    if (!result.epoch_known) result.issue = Issue::epoch_unavailable;
    else if (!result.owner.actor.entity) result.issue = Issue::local_owner_unavailable;
    else if (!result.owner.known) result.issue = Issue::local_tuple_unavailable;
    else if (!result.input.known) result.issue = Issue::borrowed_unavailable;
    else if (!result.input.condition_known) result.issue = Issue::condition_invalid;
    return result;
}
struct Invocation {
    input_trace::Snapshot tickets;
    Cache cache;
    Sample before;
};
Invocation begin(std::uintptr_t event, std::uintptr_t condition, std::uint64_t now) noexcept {
    Invocation invocation;
    if (now >= shared.active_until.load(std::memory_order_acquire)) return invocation;
    {
        TryExclusive lock(shared.lock);
        if (!lock.held) {
            shared.observer_busy.fetch_add(1, std::memory_order_relaxed);
            return invocation;
        }
        invocation.tickets = shared.ledger.begin(now);
        invocation.cache = shared.cache;
    }
    if (invocation.tickets.count) invocation.before = sample(invocation.cache, event, condition, now);
    return invocation;
}
void finish(const Invocation& invocation, std::uintptr_t event, std::uintptr_t condition,
            input_trace::Lane lane, std::uint64_t now) noexcept {
    if (!invocation.tickets.count) return;
    const auto after = sample(invocation.cache, event, condition, now);
    const auto& before = invocation.before;
    input_trace::Observation row;
    row.observed_ms = now;
    row.thread_id = GetCurrentThreadId();
    row.lane = lane;
    row.condition_known = before.input.condition_known;
    row.condition = before.input.condition != 0;
    row.local_tuple_known = before.owner.known && after.owner.known;
    const bool input_stable = before.input.known && after.input.known && before.input == after.input;
    row.snapshot_stable = input_stable && before.input.condition_known && after.input.condition_known &&
        same_local(before.owner, after.owner) &&
        before.epoch_known && after.epoch_known && before.epoch == after.epoch;
    row.container_matches_local = row.snapshot_stable && span(before.input.container, sizeof(std::uintptr_t)) &&
        before.input.container == (before.owner.raw_word & ~native::reference_tag);
    Issue issue = before.issue != Issue::none ? before.issue : after.issue;
    if (issue == Issue::none && !row.snapshot_stable) issue = Issue::snapshot_changed;
    const auto asset = input_stable ? before.input.asset : 0;
    if (issue == Issue::none && !asset) issue = Issue::asset_unavailable;
    TryExclusive lock(shared.lock);
    if (!lock.held) {
        shared.observer_busy.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    const auto finished_ms = GetTickCount64();
    for (std::uint32_t i = 0; i < invocation.tickets.count; ++i) {
        const auto ticket = invocation.tickets.tickets[i];
        auto* tokens = find_tokens(ticket.owner, ticket.sequence);
        if (!tokens) continue; // VM unload/ack or a different never-reused request.
        auto qualified = row;
        qualified.asset_token = asset_token(*tokens, asset);
        auto token_issue = issue;
        if (token_issue == Issue::none && !qualified.asset_token) token_issue = Issue::token_capacity;
        qualified.issue = static_cast<std::uint8_t>(token_issue);
        input_trace::Snapshot single;
        single.began_ms = invocation.tickets.began_ms;
        single.count = 1;
        single.tickets[0] = ticket;
        (void)shared.ledger.finish(single, qualified, finished_ms);
    }
}
} // namespace

// The assembly tail gate admits only two exact native opcode1 return PCs.
// Every other caller reaches the original relay without entering this function.
extern "C" __declspec(noinline) void __fastcall reskate_native_input_trace_known(
    std::uintptr_t event, std::uintptr_t condition) {
    const auto caller = reinterpret_cast<std::uintptr_t>(_ReturnAddress());
    const auto lane = caller == reskate_native_input_trace_alternate_return ?
        input_trace::Lane::alternate : input_trace::Lane::interpreter;
    const DWORD entry_error = GetLastError();
    const auto invocation = begin(event, condition, GetTickCount64());
    SetLastError(entry_error);
    // The permanent relay is published before hook_enable, never replaced, and
    // called exactly once with the unchanged two native storage pointers.
    reinterpret_cast<Update>(reskate_native_input_trace_relay)(event, condition);
    const DWORD original_error = GetLastError();
    finish(invocation, event, condition, lane, GetTickCount64());
    SetLastError(original_error);
}

bool request(std::uint64_t owner, input_trace::Handle& handle, input_trace::Reason& reason) noexcept {
    LastError error;
    handle = {};
    reason = input_trace::Reason::unavailable;
    if (!owner) { reason = input_trace::Reason::invalid_owner; return false; }
    Cache cache;
    { Exclusive lock(shared.lock); cache = shared.cache; }
    auto now = GetTickCount64();
    if (!current(cache, now) || cache.thread != GetCurrentThreadId() || !initialize(cache)) return false;
    now = GetTickCount64();
    Exclusive lock(shared.lock);
    if (!current(shared.cache, now) || shared.cache.base != cache.base || shared.cache.client != cache.client) return false;
    if (!shared.ledger.start(owner, now, handle, reason)) return false;
    for (auto& tokens : shared.tokens) {
        if (tokens.owner) continue;
        tokens = {};
        tokens.owner = owner;
        tokens.sequence = handle.sequence;
        tokens.busy_at_start = shared.observer_busy.load(std::memory_order_relaxed);
        const auto until = now + input_trace::duration_ms; // Ledger refused overflow before acceptance.
        if (until > shared.active_until.load(std::memory_order_relaxed)) shared.active_until.store(until, std::memory_order_release);
        return true;
    }
    // Fixed private metadata has the same capacity/lifetime as the ledger.
    // Refuse any internal disagreement without leaving an invisible trace.
    (void)shared.ledger.stop(owner, handle, now);
    (void)shared.ledger.acknowledge(owner, handle, now);
    handle = {};
    reason = input_trace::Reason::capacity;
    return false;
}
bool read(std::uint64_t owner, input_trace::Handle handle, input_trace::Receipt& receipt) noexcept {
    LastError error;
    Exclusive lock(shared.lock);
    if (!shared.ledger.read(owner, handle, GetTickCount64(), receipt)) return false;
    const auto* tokens = find_tokens(owner, handle.sequence);
    if (!tokens) return false;
    // Service-wide cumulative metadata, not an exact missing-row count. This
    // lets a caller detect omissions even when contention preceded a ticket.
    receipt.observer_busy_at_start = tokens->busy_at_start;
    receipt.observer_busy_total = shared.observer_busy.load(std::memory_order_relaxed);
    return true;
}
bool stop(std::uint64_t owner, input_trace::Handle handle) noexcept {
    LastError error;
    Exclusive lock(shared.lock);
    return shared.ledger.stop(owner, handle, GetTickCount64());
}
bool acknowledge(std::uint64_t owner, input_trace::Handle handle) noexcept {
    LastError error;
    Exclusive lock(shared.lock);
    if (!shared.ledger.acknowledge(owner, handle, GetTickCount64())) return false;
    if (auto* tokens = find_tokens(owner, handle.sequence)) *tokens = {};
    return true;
}
void release_all(std::uint64_t owner) noexcept {
    LastError error;
    Exclusive lock(shared.lock);
    shared.ledger.release_all(owner);
    for (auto& tokens : shared.tokens) if (tokens.owner == owner) tokens = {};
}
void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept {
    LastError error;
    Exclusive lock(shared.lock);
    shared.cache = {base, client, GetTickCount64(), GetCurrentThreadId(), ready};
    const auto installed = shared.installed_base.load(std::memory_order_acquire);
    if (installed && installed != base) shared.cache.ready = false;
}
} // namespace dingosdk::native_input_trace
