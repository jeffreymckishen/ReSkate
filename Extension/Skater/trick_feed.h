#pragma once
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

// skate.'s score HUD lists each trick as it is done, one entry of ScoringHUDViewModel's trick list
// per trick, written through the UI model's write of one value (hud_corner.cpp's hook). This is
// SmokeyDawg58's reading of it (found with his `mode tricklog`): an entry's
// name, side, landing, body and board spin, stance and modifiers, for plugins (reskate.tricks.feed).
namespace dingosdk::tricks::feed {
struct Note {
    std::uint64_t entry{};
    char kind{}; // 'n' name, 's' side, 'l' landing, 'b' body spin, 'r' board spin, 'k' stance, 'm' modifier
    std::string text;
};
// On while any owner asks (the model write hook is kept on with it).
void ask(const std::string& owner, bool on);
bool wanted() noexcept;
std::vector<Note> take();
// From the model write hook, on whichever thread the game writes from, under the model lock:
// the write's model manager, handle, value type, value and flag (which of the two registries).
void tap(std::uintptr_t manager, std::uint64_t handle, std::uintptr_t type, const void* value, std::uint8_t flag) noexcept;
// From the score HUD reader (score_hud.cpp), on the client thread: the entries (handle >> 16) of row
// models it has just seen in the game's own trick list, whose names and spins may go out
// (trick_feed_gate.h).
void know(const std::vector<std::uint64_t>& entries) noexcept;
// The SDK's own models of the trick list's types (a plugin's score line, Extension/UI/score_line_hud.h),
// by entry: no write to them is ever a trick's, whoever writes it. At most most_owned; each call
// replaces the last set. Client thread.
inline constexpr std::size_t most_owned = 8;
void own(const std::vector<std::uint64_t>& entries) noexcept;
} // namespace dingosdk::tricks::feed
