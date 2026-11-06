#include "trick_watch.h"
#include <algorithm>
#include <utility>

namespace dingosdk::tricks {
namespace {
using Kind = TrickEvent::Kind;
using Why = TrickEvent::Why;
constexpr float line_on = 0.01f;   // a Multiplier above this: the game's line is going on
constexpr float cut_short = 0.05f; // LineTimer left on the tick before the line ended, above which it was cut short
constexpr float banked = 0.5f;     // a LineScore rise above this is a bank (points are whole)
constexpr float refilled = 0.001f; // a LineTimer rise above this is the game's (it only drains otherwise)
constexpr int grace_ticks = 2;     // after the bank tick moved the line but not LineScore, for LineScore to follow
}

TrickEvent TrickWatch::update(const TrickSignals& in) {
    ++tick_;
    if (!std::exchange(seen_, true)) {
        last_ = in;
        start_score_ = in.line_score;
    }
    const bool line_was = last_.multiplier > line_on, line_is = in.multiplier > line_on;
    // A wipeout ends the trick going on, or the one whose points are awaited: it scores nothing.
    if (in.wipeout && (action_ || waiting())) {
        tell({.kind = Kind::broken, .why = Why::wipeout});
        broken_said_ = true;
    }
    // The game's line ends: a trick awaiting its points gets none, and one going on counts from the
    // next line's 0. With time left on the line it was cut short (an on-foot fall did that), unless a
    // wipeout already broke the trick.
    if (line_was && !line_is) {
        waiting_ = grace_ = 0;
        start_score_ = in.line_score;
        if (last_.line_timer > cut_short && !broken_said_) tell({.kind = Kind::broken, .why = Why::ended});
        broken_said_ = false;
    }
    if (in.wipeout) {
        // Nothing starts or lands while the skater is down.
        action_ = false;
        waiting_ = grace_ = 0;
    } else if (in.action) {
        if (!action_) {
            // A trick starts (a previous one whose points never came scored nothing).
            action_ = true;
            waiting_ = grace_ = 0;
            broken_said_ = moved_ = false;
            start_score_ = in.line_score;
            tell({.kind = Kind::started});
        } else if (in.line_score != last_.line_score && !(line_was && !line_is)) {
            // (LineScore going to 0 as the line ends is the line's end, not the trick's score moving.)
            moved_ = true;
        }
    } else {
        if (action_) { // the trick ended this tick: its points bank on the next, or on this one with a slow tick
            action_ = false;
            waiting_ = wait_ticks_;
        }
        if (waiting()) {
            if (in.line_score > last_.line_score + banked) {
                tell({.kind = Kind::landed, .points = std::max(0.0f, in.line_score - start_score_), .multiplier = in.multiplier,
                      .score_moved = moved_});
                waiting_ = grace_ = 0;
            } else if (grace_ > 0) {
                if (--grace_ == 0) { // the game moved the line for it and kept its points back
                    tell({.kind = Kind::landed, .points = 0, .multiplier = in.multiplier, .score_moved = moved_});
                    waiting_ = 0;
                }
            } else if ((!line_was && line_is) || in.line_timer > last_.line_timer + refilled) {
                grace_ = grace_ticks;
            } else --waiting_;
        }
    }
    last_ = in;
    if (told_.empty()) return {};
    auto event = told_.front().event;
    event.late = static_cast<int>(tick_ - told_.front().tick);
    told_.pop_front();
    return event;
}

void TrickRows::observe(const std::vector<TrickRow>& newest_first, bool readable) {
    ++tick_;
    if (!readable) return;
    std::vector<Seen> now;
    now.reserve(newest_first.size());
    for (const auto& row : newest_first) {
        const auto was = std::find_if(rows_.begin(), rows_.end(), [&](const Seen& seen) { return seen.row.handle == row.handle; });
        now.push_back({row, was == rows_.end() ? tick_ : was->first});
    }
    rows_ = std::move(now);
}

void TrickRows::mark_start(int ticks_ago) {
    const auto ago = static_cast<std::uint64_t>(std::max(0, ticks_ago));
    start_ = tick_ > ago ? tick_ - ago : 0;
}

ActionRows TrickRows::since_start() const {
    ActionRows out;
    if (!start_) return out;
    std::vector<const TrickRow*> mine; // newest first
    for (const auto& seen : rows_)
        if (seen.first + 1 >= *start_ && mine.size() < most_rows) mine.push_back(&seen.row);
    if (mine.empty()) return out;
    for (auto row = mine.rbegin(); row != mine.rend(); ++row) out.names.push_back((*row)->name);
    out.name = mine.front()->name;
    out.landing = mine.front()->landing;
    out.stance = mine.front()->stance;
    for (const auto* row : mine) {
        if (out.damage.empty()) out.damage = row->damage;
        out.slam = out.slam || row->slam;
    }
    return out;
}
}
