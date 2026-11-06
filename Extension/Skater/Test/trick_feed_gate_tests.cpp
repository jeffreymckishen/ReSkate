// The trick feed's gate (Extension/Skater/trick_feed_gate.h), apart from the game: a song title the
// music writes to the name's field never goes out as a trick, while a trick's name does once the score
// HUD reader has seen its row model in the game's trick list, also when the name comes first.
#include "Extension/Skater/trick_feed_gate.h"
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using namespace dingosdk::tricks::feed;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
using Gate = EntryGate<std::string>;
using Notes = std::vector<std::string>;
// Row models as the board's trick list held them (entry = handle >> 16), and the music's model.
constexpr std::uint64_t ollie_row = 0x1763f, heelflip_row = 0x1767f, music = 0x16e1c;

void a_song_title_never_goes_out() {
    Gate gate;
    Notes out;
    gate.add("Uptown Top Ranking", music, false, 0, out);
    gate.add("Uptown Top Ranking", music, false, 500, out);
    check(out.empty(), "a name from a model not seen in the trick list went out at once");
    // A row the reader saw: the song stays held.
    gate.know(ollie_row, 600, out);
    check(out.empty(), "knowing a row let out another model's name");
    gate.add("Beneath The Wheel", music, false, 2600, out);
    check(out.empty(), "a song title went out");
    const auto left = gate.take_left_out();
    check(left.size() == 2 && left[0] == "Uptown Top Ranking", "the song titles that waited were not left out");
    gate.expire(5000);
    check(gate.take_left_out() == Notes{"Beneath The Wheel"}, "a later song title was not left out");
}

// A name is written 10-13 ms before its row shows in the list: it waits for the reader, and goes first.
void a_known_row_model_passes_names_without_a_landing() {
    Gate gate;
    Notes out;
    gate.add("Jump", ollie_row, false, 1000, out);
    gate.add("Seawall - Plot 03 - ENT", music, false, 1005, out);
    check(out.empty(), "a name went out before its row was seen");
    gate.know(ollie_row, 1012, out);
    check(out == Notes{"Jump"}, "the held name did not go out when its row was seen");
    out.clear();
    gate.add("Roll", ollie_row, false, 1500, out);
    check(out == Notes{"Roll"}, "a known row's next name waited");
    out.clear();
    gate.expire(4000);
    check(gate.take_left_out() == Notes{"Seawall - Plot 03 - ENT"}, "the place name from another model was not left out");
}

// A side, landing, stance or modifier is the game's own id: it goes out at once, and does not admit
// its model's names on its own (only the reader does).
void a_sure_note_goes_out_but_admits_nothing() {
    Gate gate;
    Notes out;
    gate.add("Kickflip", heelflip_row, false, 600, out);
    gate.add("ID_STANCE_SWITCH", heelflip_row, true, 600, out);
    check(out == Notes{"ID_STANCE_SWITCH"}, "a stance waited, or let its model's name out");
    out.clear();
    gate.know(heelflip_row, 610, out);
    check(out == Notes{"Kickflip"}, "the name waiting for its row did not go out");
    out.clear();
    gate.add("ID_TRICK_LANDING_CLEAN", music, true, 700, out);
    gate.add("Seawall", music, false, 700, out);
    check(out == Notes{"ID_TRICK_LANDING_CLEAN"}, "an id from another model let its names out");
}

void a_known_model_survives_while_newer_ones_come() {
    Gate gate;
    Notes out;
    gate.know(ollie_row, 0, out);
    for (std::uint64_t i = 1; i < Gate::most_known; ++i) gate.know(0x20000 + i, 0, out);
    gate.add("Ollie", ollie_row, false, 10, out);
    check(out == Notes{"Ollie"}, "a known row was forgotten before the most known were");
    out.clear();
    for (std::uint64_t i = 0; i < 6; ++i) gate.know(0x30000 + i, 20, out);
    check(!gate.known(ollie_row) && gate.known(0x30005) && gate.known(0x20000 + Gate::most_known - 1), "the oldest known went first");
    gate.clear();
    gate.add("Kickflip", 0x30005, false, 30, out);
    check(out.empty(), "clearing the gate kept what it knew");
}

void only_so_many_wait() {
    Gate gate;
    Notes out;
    for (int i = 0; i < 70; ++i) gate.add("x", music, false, 6000, out);
    check(out.empty() && gate.take_left_out().size() == 70 - Gate::most_held, "more than the most held were kept");
}

void left_out_says_each_model_and_text_once() {
    LeftOutLog log;
    check(log.say(music, "Uptown Top Ranking") && !log.say(music, "Uptown Top Ranking"), "a repeat was said again");
    check(log.say(music, "Beneath The Wheel") && log.say(0x1000000b2, "Uptown Top Ranking"), "another text, or another model, was not said");
    std::size_t said = 3;
    for (std::uint64_t i = 0; i < 40; ++i) said += log.say(0x100000000 + i, "ID_ON") ? 1 : 0;
    check(said == LeftOutLog::most_said, "more than the most were said");
    log.clear();
    check(log.say(music, "Uptown Top Ranking"), "clearing it did not let a line be said again");
}
}

int main() {
    try {
        a_song_title_never_goes_out();
        a_known_row_model_passes_names_without_a_landing();
        a_sure_note_goes_out_but_admits_nothing();
        a_known_model_survives_while_newer_ones_come();
        only_so_many_wait();
        left_out_says_each_model_and_text_once();
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
    std::cout << "trick feed gate tests passed\n";
    return 0;
}
