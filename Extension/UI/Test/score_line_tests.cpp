// A plugin's own line in skate.'s score HUD (Extension/UI/score_line.h), apart from the game: one
// plugin's line at a time on a 500 ms lease, the yield to skate.'s own line, the take-out that is
// never dropped, the game's root picked over ours, and what a line writes.
#include "Extension/UI/score_line.h"
#include <cstdint>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

using namespace dingosdk::score_line;
namespace {
void check(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}
Line barspin() {
    Line line;
    line.tricks = {"Barspin", "Tailwhip"};
    line.points = 550;
    line.line = 4200;
    line.multiplier = 2.4f;
    return line;
}

void one_plugin_shows_its_line_at_a_time() {
    LineOwner owner;
    check(owner.ask("bmx", barspin(), 0).empty(), "the first plugin's line was refused");
    check(owner.ask("other", barspin(), 100) == "bmx shows its line there", "a second plugin was not told whose line is up");
    check(owner.owner() == "bmx" && owner.current(100) && owner.current(100)->tricks.size() == 2, "the first plugin's line was not kept");
    check(owner.ask("other", std::nullopt, 150).empty() && owner.current(150), "another plugin's nil cleared the line");
    // Once the first lets its lease run out, the second may show its own.
    check(owner.ask("other", barspin(), 700).empty() && owner.owner() == "other", "a line past its lease still held the HUD");
}

void a_line_lasts_500_ms_after_its_last_call() {
    LineOwner owner;
    owner.ask("bmx", barspin(), 1000);
    check(owner.current(1400) != nullptr, "the line went before its lease ran out");
    owner.ask("bmx", barspin(), 1400);
    check(owner.current(1900) != nullptr, "setting the line again did not renew its lease");
    check(owner.current(1901) == nullptr && owner.owner().empty(), "the line stayed 500 ms after its last call");
    check(owner.current(1950) == nullptr, "a let-go line came back");
}

void nil_and_release_clear_the_line() {
    LineOwner owner;
    owner.ask("bmx", barspin(), 0);
    check(owner.ask("bmx", std::nullopt, 10).empty() && !owner.current(10), "nil did not clear the plugin's line");
    owner.ask("bmx", barspin(), 20);
    owner.release("other");
    check(owner.current(20) != nullptr, "another plugin's release took the line");
    owner.release("bmx");
    check(!owner.current(20) && owner.owner().empty(), "stopping the plugin did not take its line");
}

void the_games_line_holds_a_plugins_down() {
    GameLine game;
    check(!game.running(0), "an idle game ran a line");
    game.observe({}, 0);
    check(!game.running(0), "idle values (Multiplier 0 at rest) ran a line");
    const GameSignals each[] = {{.action = true}, {.multiplier = 1.5f}, {.line_score = 22}, {.line_shown = 22}, {.item = true}};
    const char* names[] = {"ActionActive", "Multiplier 1.5", "LineScore 22", "LINE 22", "its score item"};
    double now = 1000;
    for (std::size_t i = 0; i < std::size(each); ++i, now += 10000) {
        game.observe(each[i], now);
        check(game.running(now) && game.why() == names[i], names[i]);
        game.observe({}, now + 16);
        check(game.running(now + 499), "the hold ended before 500 ms of idle");
        check(!game.running(now + 500), "the hold lasted past 500 ms of idle");
    }
    // Small values are idle: a multiplier, a score or a LINE number that rounds to nothing.
    GameLine small;
    small.observe({.multiplier = 0.005f, .line_score = 0.4f, .line_shown = 0.4f}, 0);
    check(!small.running(0), "values below the thresholds ran a line");
    // The game's item keeps it up while the values are idle (the LINE summary's last 0.3 s).
    GameLine item;
    for (double t = 0; t <= 300; t += 16) item.observe({.item = true}, t);
    check(item.running(700), "the game's item did not keep the line up");
}

void the_take_out_is_never_dropped() {
    ItemPresence presence;
    check(!presence.must_scan(), "nothing was in, yet a scan was asked for");
    presence.inserting();
    check(presence.must_scan(), "an insert did not ask for a scan");
    // A failed tick calls nothing: the scan is still due.
    check(presence.must_scan(), "a failed tick dropped the take-out");
    presence.scanned(true);
    check(presence.must_scan(), "a scan that found ours ended the take-out");
    presence.scanned(false);
    check(!presence.must_scan(), "a scan that found none of ours kept asking");
    presence.inserting();
    presence.registry_changed();
    check(!presence.must_scan(), "a new registry kept a scan of the old one's stack");
}

struct Model {
    std::uint64_t handle{};
};
struct Root {
    Model model;
};
void the_games_root_is_picked_over_ours() {
    const std::vector<Root> roots{{{0x177c10000}}, {{0x1000103270000}}};
    const auto* game = pick_game_root(roots, 0x177c10000);
    check(game && game->model.handle == 0x1000103270000, "our root was picked");
    check(pick_game_root(roots, 0)->model.handle == 0x177c10000, "with none of ours the first root was not picked");
    check(!pick_game_root(std::vector<Root>{{{0x177c10000}}}, 0x177c10000), "our root alone was taken for the game's");
}

void only_new_rows_come_in() {
    using Names = std::vector<std::string>;
    check(fresh_rows({}, {"Barspin"}) == 1, "a first row was not new");
    check(fresh_rows({"Barspin"}, {"Tailwhip", "Barspin"}) == 1, "a trick added to the line renewed the older row");
    check(fresh_rows({"Barspin"}, {"Barspin", "Barspin"}) == 1, "a repeated trick was not one new row");
    check(fresh_rows({"C", "B", "A", "Z", "Y"}, {"D", "C", "B", "A", "Z"}) == 1, "the list at its cap did not keep the newest four");
    check(fresh_rows({"Barspin", "Tailwhip"}, {"Barspin", "Tailwhip"}) == 0, "the same rows were made again");
    check(fresh_rows({"Barspin"}, {"Tuck", "Nohander"}) == 2, "a new line kept an old row");
    check(fresh_rows({"Barspin"}, Names{}) == 0, "no rows were counted as new");
}

void a_line_looks_like_the_games() {
    auto line = barspin();
    auto look = look_of(line, 400);
    check(look.hud_active && look.ring_on && look.line_on, "a running line did not show the ring and LINE");
    check(look.points == "550" && look.multiplier_text == "2.4" && look.line_score == 4200, "a line's numbers differ");
    check(look.fill == 1.f, "the ring's fill was not capped at full");
    check(look.rows == std::vector<std::string>{"Tailwhip", "Barspin"}, "the rows are not newest first");
    line.points = 100;
    line.multiplier = 2;
    check(look_of(line, 400).fill == 0.25f && look_of(line, 400).multiplier_text == "2", "the fill or a whole multiplier differs");
    check(multiplier_text(1.5f) == "1.5" && multiplier_text(1.04f) == "1" && multiplier_text(99) == "99", "the ring's number differs");
    line.line = 0;
    check(!look_of(line, 400).line_on, "LINE showed for a line with nothing banked");
    line.line = 937;
    line.closed = true;
    look = look_of(line, 400);
    check(!look.hud_active && !look.ring_on && !look.line_on && look.line_score == 937, "a closed line is not the game's LINE summary");
    line.tricks = {"1", "2", "3", "4", "5", "6", "7"};
    check(look_of(line, 400).rows == std::vector<std::string>{"7", "6", "5", "4", "3"}, "more rows than the list keeps");
}
} // namespace

int main() {
    try {
        one_plugin_shows_its_line_at_a_time();
        a_line_lasts_500_ms_after_its_last_call();
        nil_and_release_clear_the_line();
        the_games_line_holds_a_plugins_down();
        the_take_out_is_never_dropped();
        the_games_root_is_picked_over_ours();
        only_new_rows_come_in();
        a_line_looks_like_the_games();
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
    std::cout << "score line tests passed\n";
    return 0;
}
