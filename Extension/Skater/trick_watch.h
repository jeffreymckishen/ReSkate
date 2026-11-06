#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <optional>
#include <string>
#include <vector>

// When a trick lands and what it was worth, from the score HUD's values each tick (score_hud.h), and
// which of the trick list's rows were its. Apart from the game, so its rules are tested alone. The
// start event is where a caller records where a trick began.
//
// Measured on build 20260929 in two read-only probe launches (2026-11-05: on foot, and on the board):
// - ActionActive is on for each scored action. Its points bank into LineScore on the tick after it
//   goes off (all 27 on-foot and 10 board actions), and the next action started at least 101 ms later.
// - LineScore is the sum of the actions' points without the multiplier (on foot 425+367 = 792 at x2,
//   on the board 2+22+2+22+2 = 50 at x1.5). So a trick's points are LineScore at its bank less
//   LineScore at its start, at the Multiplier after the bank. LineScore is what was banked, not what
//   was shown: a sketchy Switch Kickflip showed 15 and banked 13.
// - Once (the session's first on-foot move) the bank started the line, Multiplier 0 to 1.5 and
//   LineTimer 0 to 1, without raising LineScore: the game kept those points back, so it lands with 0.
// - The line ends on the tick Multiplier goes to 0 (LineScore with it). Lines that ran out had
//   LineTimer at 0.035 or below on the tick before; the two on-foot falls that ended a line had 0.188
//   and 0.778. So a line that ends with more than 0.05 left was cut short, whatever cut it.
// - On foot a Slam is a scored action like any other: its row is named "Slam" and its points bank into
//   the line. The rows tell it apart (TrickRow::slam).
// - IsSlam is not a slam signal (the build header's score_hud.h says what it did) and is not read.
namespace dingosdk::tricks {
// The score HUD's values (ScoringHUDViewModel), and whether the skater is in a wipeout (physics
// states 300-399).
struct TrickSignals {
    bool action{};
    float line_score{}, multiplier{}, line_timer{};
    bool wipeout{};
};
struct TrickEvent {
    enum class Kind { none, started, landed, broken } kind{Kind::none};
    float points{};     // landed: LineScore at the bank less LineScore at the trick's start
    float multiplier{}; // landed: the Multiplier after the bank
    // broken: a wipeout ended the trick going on, or the game's line ended with time left on it.
    enum class Why { none, wipeout, ended } why{Why::none};
    int late{};         // ticks between it happening and it being told (a start on a tick with a break or landing)
    bool score_moved{}; // landed: LineScore changed while the trick went on, which was never seen in play
};
class TrickWatch {
public:
    // `wait_ticks`: how long after a trick ends its points may take to show in the line's score.
    explicit TrickWatch(int wait_ticks = 20) : wait_ticks_(wait_ticks) {}
    // One tick's values. At most one event comes out a tick; when two happen on one tick, the second
    // comes out on the next (a break first, then a landing, then a start).
    TrickEvent update(const TrickSignals& signals);
    bool in_trick() const noexcept { return action_; }
    // Waiting for the points of a trick that just ended.
    bool waiting() const noexcept { return waiting_ > 0 || grace_ > 0; }

private:
    struct Told {
        TrickEvent event;
        std::uint64_t tick{};
    };
    void tell(TrickEvent event) { told_.push_back({event, tick_}); }
    int wait_ticks_;
    std::uint64_t tick_{};
    bool seen_{}, action_{};
    int waiting_{}, grace_{};
    bool broken_said_{}; // a wipeout broke the trick, and no trick has started since: the line's end says nothing more
    bool moved_{};
    float start_score_{}; // LineScore on the tick the trick started
    TrickSignals last_;   // the previous tick's values
    std::deque<Told> told_;
};

// One row of the trick list as the score HUD reader read it.
struct TrickRow {
    std::uint64_t handle{}; // the row model's handle, its generation included: a reused row is a new one
    std::string name;       // the bare name the game wrote ("Kickflip", "Back Pose", "Slam"); display text
    std::string landing, stance, damage; // ids, "" when unset: ID_TRICK_LANDING_SKETCHY, ID_STANCE_SWITCH, ID_DAMAGE_BRUISED
    bool slam{};            // a Slam row: its damage is set, or it carries the game's slam icon
};
// What one scored action added to the trick list.
struct ActionRows {
    std::vector<std::string> names; // oldest first
    std::string name, landing, stance; // the newest row's
    std::string damage;                // the newest damage set on any of its rows
    bool slam{};                       // any of its rows is a slam
};
// Which rows of the trick list a scored action added. Rows are told apart by their full handle, as the
// game reuses a row model with a new generation; a row counts from the tick it is first seen. An
// action's rows are those first seen from one tick before its start on: its first row's name is
// written 10-13 ms before ActionActive rises, and a reader tick can fall between the two.
class TrickRows {
public:
    static constexpr std::size_t most_rows = 5; // the list keeps no more
    // Each tick, before TrickWatch's update: the list, newest first. `readable` false when it could not
    // be read this tick (what was seen stays).
    void observe(const std::vector<TrickRow>& newest_first, bool readable = true);
    // On the start event, `ticks_ago` its TrickEvent::late.
    void mark_start(int ticks_ago = 0);
    // The rows of the action started last, while they are in the list.
    ActionRows since_start() const;

private:
    struct Seen {
        TrickRow row;
        std::uint64_t first{};
    };
    std::vector<Seen> rows_; // newest first, as last read
    std::uint64_t tick_{};
    std::optional<std::uint64_t> start_;
};
}
