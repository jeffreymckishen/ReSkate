#pragma once
#include "trick_watch.h"
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

// skate.'s score HUD as values (ScoringHUDViewModel, read through the game's UI models), what
// trick_watch.h turns into tricks.
namespace dingosdk::tricks {
struct ScoreHud {
    bool action{}; // a scored action is going on (ActionActive)
    float line_score{}, multiplier{};
    // The sequence's header and descriptor labels as the HUD holds them, and its sequence state: empty,
    // or 0, when this build's model does not have them readable. The header read "" all through the
    // play mapped on this build, so a trick's name comes from the rows below.
    std::string header, descriptor;
    std::uint32_t sequence_state{};
    float line_timer{}; // what is left of the line's time to keep its multiplier; 0 with no line
    float line_shown{}; // the "LINE: N" number, kept 2.0 s after the line ends; 0 while none shows
    // The trick list's rows, newest first (at most TrickRows::most_rows). rows_read is false when the
    // list could not be read this tick: its layout is not this build's, or it held more than it keeps.
    std::vector<TrickRow> rows;
    bool rows_read{};
};
// Whether the HUD names a manual going on (its header or descriptor says one).
bool names_manual(const ScoreHud& now);
// Client thread. The game's own root is read, never a plugin's line (score_line_hud.h). Empty while
// there is no score HUD model (the menu, a level loading), or when this
// game build's model has none of the fields; the model is looked for at most once a second. Rows seen
// for the first time are told to the trick feed (trick_feed.h's know) while it is on.
std::optional<ScoreHud> read_score_hud(std::uintptr_t image_base) noexcept;
}
