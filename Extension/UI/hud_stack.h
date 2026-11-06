#pragma once
#include "Extension/UI/NativeMenu/native_menu_data.h"
#include <cstdint>
#include <optional>
#include <string>

// skate.'s bottom left HUD stack (HudViewModel's DpadScoringStack, Engine/Game/Build/20260929/hud_corner.h)
// as the SDK's items go into it: the d-pad's own stack found, and an item of ours put in or taken out
// by its key while the game's items stay as they are. hud_corner.cpp's cover and score_line_hud.cpp's
// score line use it. Client thread, under the model lock (game::ModelWriteLock).
namespace dingosdk::hud_stack {
using multiplayer::menu_data::Context;
using multiplayer::menu_data::Value;
// The most items read from the stack (it holds the d-pad, and the score HUD during a line).
inline constexpr unsigned most_items = 16;

// An asset's name, or "" for none.
std::string asset_name(std::uintptr_t asset);
// The widget a stack item shows: its Content's blueprint's name.
std::string widget_of(const Context& context, const Value& item);
// A stack's Items array.
Value items_of(const Context& context, const Value& stack);
// The DpadScoringStack that holds the d-pad (HUDDpad_Widget), or none while the HUD is not loaded.
Value find_dpad_stack(const Context& context);
// Where the stack's item with `key` is, if it holds one.
std::optional<unsigned> find_key(const Context& context, const Value& stack, std::uint32_t key);
// Puts `item` (a stack item model of ours) last into the stack's items.
void insert_item(const Context& context, const Value& stack, const Value& item);
// Takes the item with `key` out of the stack's items; false when it held none.
bool remove_key(const Context& context, const Value& stack, std::uint32_t key);
} // namespace dingosdk::hud_stack
