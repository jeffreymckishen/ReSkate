#pragma once
#include <Windows.h>
#include <Xinput.h>
#include <cstdint>
#include <vector>

// A scripted Xbox pad for player 0, read by the game through the XInput hook (PR 297, after PR 230 by
// Norms): the character room's walk presses RB on it (Extension/World/character_room.cpp). Not
// exposed to plugins: permissioned input pulses use the separate bounded report service.
namespace dingosdk::overlay {
struct PadStep {
    std::uint32_t tick{}; // game ticks from the start of the script
    XINPUT_GAMEPAD pad{};
};
// Any thread. Starts at the next game tick; each step holds until the next step's tick, so frame rate does not matter.
// After the last step the pad stays connected and neutral for 2 s.
void play_pad(std::vector<PadStep> steps);
// The game thread calls this once a game tick.
void pad_tick() noexcept;
// True when it wrote the script's pad to `state`.
bool scripted_pad(DWORD user, XINPUT_STATE &state) noexcept;
// The input revision must still match before deriving. A successful script
// reports its own resulting revision without accepting an intervening owner.
bool scripted_pad(DWORD user, XINPUT_STATE& state, std::uint64_t& staged_revision) noexcept;
// Side-effect-free admission/deadline check; the caller already holds the
// publication gate. Calls without that gate report interference conservatively.
bool scripted_pad_active() noexcept;
// One stick of the stand-in pad held at `value` (-1..1) for `milliseconds` more, the pad otherwise
// neutral, for turning the game menu's preview (reskate.room.turn); 0 lets go. `stick`: 0 left x,
// 1 left y, 2 right x, 3 right y. A script playing (play_pad) comes first. Any thread.
void hold_stick(int stick, float value, unsigned milliseconds) noexcept;
} // namespace dingosdk::overlay
