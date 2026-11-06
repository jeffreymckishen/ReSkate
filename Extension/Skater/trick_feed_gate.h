#pragma once
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <set>
#include <string>
#include <utility>
#include <vector>

// Which writes of the trick list's fields are a trick's (trick_feed.cpp). Other HUD models write text
// to the same field numbers: with in-game music on, the song's title is a string at the name's field
// (0x0002) of another model, and read as a trick name (reported 2026-11-03: about one name in ten on a
// server's first day). So a write is told apart by the model it belongs to, its entry (the write's
// handle >> 16, the model's own handle): a name, spin or board spin goes out only from a model the
// score HUD reader has seen in the game's own trick list (know). The name is written 10-13 ms before
// the row shows in the list, so it waits up to `hold_ms` for that, and is left out after. A side,
// landing, stance or modifier (each checked against the game's own ids) goes out at once.
//
// (It was keyed by the UI model record the game's lookup returns before, taken to be one per model.
// That lookup returns one record per field of a model type, the type's base + 8 x the field, the same
// for every model of the type: on the board one row's name, landing and stance came from three records,
// so no name ever went out, and keying names by the type's record would let any row of that type in.)
// Pure, so it tests.
namespace dingosdk::tricks::feed {
template <class Note> class EntryGate {
public:
    static constexpr std::uint64_t hold_ms = 2000;
    static constexpr std::size_t most_held = 64, most_known = 64;

    // A note from `entry` at `now_ms`; `sure` when its kind is one only a trick row writes. What may go
    // out now goes into `out`, in order.
    void add(const Note& note, std::uint64_t entry, bool sure, std::uint64_t now_ms, std::vector<Note>& out) {
        expire(now_ms);
        if (sure || known(entry)) out.push_back(note);
        else if (held_.size() < most_held) held_.push_back({note, entry, now_ms});
        else left_out_.push_back(note);
    }
    // The score HUD reader saw `entry` in the game's trick list: what waited for it goes out first, as
    // it was written, and its notes go out at once from now on. The newest `most_known` are kept (a
    // row model reused for a new row comes with a new entry).
    void know(std::uint64_t entry, std::uint64_t now_ms, std::vector<Note>& out) {
        expire(now_ms);
        if (!known(entry)) {
            if (known_.size() >= most_known) known_.pop_front();
            known_.push_back(entry);
        }
        for (auto it = held_.begin(); it != held_.end();)
            if (it->entry == entry) {
                out.push_back(it->note);
                it = held_.erase(it);
            } else ++it;
    }
    bool known(std::uint64_t entry) const { return std::find(known_.begin(), known_.end(), entry) != known_.end(); }
    // Notes that waited too long: never a trick's.
    void expire(std::uint64_t now_ms) {
        for (auto it = held_.begin(); it != held_.end();)
            if (now_ms - it->at >= hold_ms) {
                left_out_.push_back(it->note);
                it = held_.erase(it);
            } else ++it;
    }
    // What was left out since the last call (for the log).
    std::vector<Note> take_left_out() { return std::exchange(left_out_, {}); }
    void clear() {
        known_.clear();
        held_.clear();
        left_out_.clear();
    }

private:
    struct Held {
        Note note;
        std::uint64_t entry{};
        std::uint64_t at{};
    };
    std::deque<std::uint64_t> known_;
    std::vector<Held> held_;
    std::vector<Note> left_out_;
};

// Which left-out notes the log says: each model and text once (the settings toggles alone write
// dozens of ID_ON and ID_OFF names at a level load, and a song's title over and over), at most
// `most_said` until it is cleared.
class LeftOutLog {
public:
    static constexpr std::size_t most_said = 32;
    bool say(std::uint64_t entry, const std::string& text) {
        if (said_.size() >= most_said) return false;
        return said_.insert({entry, text}).second;
    }
    void clear() { said_.clear(); }

private:
    std::set<std::pair<std::uint64_t, std::string>> said_;
};
} // namespace dingosdk::tricks::feed
