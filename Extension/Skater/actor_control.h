#pragma once
#include "Engine/Game/Skater/actor_control_policy.h"
#include "Engine/Game/Skater/native_action_policy.h"
#include <cstdint>

namespace dingosdk::actor_control_native {
using State = skater_action::State;
using Reason = skater_action::Reason;

// Internal native identity only. Plugins never receive these addresses. The
// shared owner service repeats the complete local chain at each use edge.
struct Actor {
    std::uintptr_t base{}, client{}, entity{}, player{}, player_handle{}, component{}, core{}, context{},
        selector{}, causes{}, rig{}, game_context{}, world{}, world_state{};
    std::uint64_t world_generation{}, lifetime_epoch{}, actor_epoch{};
    actor_control::Ticket ticket{};
    bool operator==(const Actor&) const = default;
};

// A trusted native service supplies its eligibility predicate. A null predicate
// is refused, and the predicate runs outside the shared publication lock.
using Admission = bool (*)(const State&) noexcept;
bool acquire(std::uint64_t owner, std::uint64_t sequence, Admission admission,
    Actor& actor, Reason& reason) noexcept;
bool inspect(std::uint64_t owner, std::uint64_t sequence, const Actor& expected,
    Actor& actor, State& state, Reason& reason, bool cleanup = false) noexcept;
bool enter(std::uint64_t owner, std::uint64_t sequence,
    const Actor& actor, actor_control::Call& call) noexcept;
// The service supplies resolved cleanup duty. Otherwise only independently
// observed exact-actor retirement can retire the shared claim.
bool retire(std::uint64_t owner, std::uint64_t sequence,
    const Actor& actor, bool duty_resolved) noexcept;
} // namespace dingosdk::actor_control_native
