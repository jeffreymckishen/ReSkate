#pragma once
#include "Engine/Game/Input/game_input_pulse.h"
#include "Engine/Game/Input/input_pulse.h"
#include "Engine/Game/Skater/actor_control_policy.h"
#include <Windows.h>
#include <Xinput.h>

namespace dingosdk::native_input_pulse {
bool request(std::uint64_t owner, std::uint32_t user, std::uint16_t button,
    game_input_pulse::Handle& handle, game_input_pulse::Reason& reason) noexcept;
bool read(std::uint64_t owner, game_input_pulse::Handle handle, game_input_pulse::Receipt& receipt) noexcept;
bool cancel(std::uint64_t owner, game_input_pulse::Handle handle) noexcept;
bool acknowledge(std::uint64_t owner, game_input_pulse::Handle handle) noexcept;
void release_all(std::uint64_t owner) noexcept;
void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept;

// One stack cookie per outer wrapper invocation. The actor Call drains before
// a later client-phase claim retirement; it is not an input-consumption receipt.
struct Poll {
    std::uint64_t sequence{};
    input_pulse::Ticket ticket{};
    actor_control::Call call;
};
void begin(bool outer, std::uint32_t user, Poll& poll) noexcept;
void finish(Poll& poll, bool outer, std::uint32_t user, DWORD original_result,
    std::uint64_t original_ms, DWORD raw_packet, const XINPUT_GAMEPAD& raw,
    DWORD returned_result, XINPUT_STATE* output, bool interference_clear) noexcept;
}
