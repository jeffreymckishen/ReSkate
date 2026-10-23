#pragma once
#include "Engine/Game/Skater/actor_control_policy.h"
#include "Engine/Game/Skater/native_recovery.h"
#include <cstdint>

namespace dingosdk::skater_recovery {
// Internal native identity only. None of these addresses is exposed to Lua.
// The No Bail owner service captures and repeats its complete local chain.
struct RecoveryActor {
    std::uintptr_t base{}, client{}, entity{}, player{}, player_handle{}, component{}, core{}, context{},
        selector{}, causes{}, rig{}, game_context{}, world{}, world_state{};
    std::uint64_t world_generation{}, lifetime_epoch{}, actor_epoch{};
    actor_control::Ticket ticket{};
    bool operator==(const RecoveryActor&) const = default;
};

// Implemented alongside the shared actor arbiter in no_bail.cpp. These calls
// acquire its lock internally; the recovery service never holds its own lock
// across them or enters native code while that arbiter lock is held.
bool recovery_acquire(std::uint64_t owner, std::uint64_t sequence,
    RecoveryActor& actor, Reason& reason) noexcept;
bool recovery_inspect(std::uint64_t owner, std::uint64_t sequence, const RecoveryActor& expected,
    RecoveryActor& actor, State& state, Reason& reason, bool cleanup = false) noexcept;
bool recovery_enter(std::uint64_t owner, std::uint64_t sequence,
    const RecoveryActor& actor, actor_control::Call& call) noexcept;
// duty_resolved means no SDK true entry, untouched prior true, or a false read
// measured in the canonical binding after a true attempt. Otherwise the service
// independently requires exact actor retirement; unrelated destruction cannot
// discharge this possible native store.
bool recovery_retire(std::uint64_t owner, std::uint64_t sequence,
    const RecoveryActor& actor, bool duty_resolved) noexcept;

bool request(std::uint64_t owner, Handle& handle, Reason& reason) noexcept;
bool read(std::uint64_t owner, Handle handle, Receipt& receipt) noexcept;
bool cancel(std::uint64_t owner, Handle handle) noexcept;
bool acknowledge(std::uint64_t owner, Handle handle) noexcept;
void release_all(std::uint64_t owner) noexcept;
// Client phase only. Installs the one generic typed callback and publishes
// availability; stopping client eligibility never drops a pending reset duty.
void tick(std::uintptr_t image_base, std::uintptr_t client, bool ready) noexcept;
} // namespace dingosdk::skater_recovery
