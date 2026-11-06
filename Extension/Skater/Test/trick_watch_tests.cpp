// Reading tricks from the score HUD's values, apart from the game: a trick's start, its points once it
// lands, a wipeout, a line cut short, a trick whose points never come, and which trick list rows were
// the action's. The values are those two probe launches read on build 20260929 (trick_watch.h).
#include "Extension/Skater/trick_watch.h"
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace dingosdk::tricks;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
// Each signal by name, so a flag cannot slide into a float.
TrickSignals idle(float score = 0, float multiplier = 0, float timer = 0) {
    return {.line_score = score, .multiplier = multiplier, .line_timer = timer};
}
TrickSignals trick(float score = 0, float multiplier = 0, float timer = 0) {
    return {.action = true, .line_score = score, .multiplier = multiplier, .line_timer = timer};
}
TrickSignals down(TrickSignals in) {
    in.wipeout = true;
    return in;
}
// The last event over `ticks` updates.
TrickEvent feed(TrickWatch& watch, const TrickSignals& in, int ticks) {
    TrickEvent last;
    for (int i = 0; i < ticks; ++i) {
        const auto e = watch.update(in);
        if (e.kind != TrickEvent::Kind::none) last = e;
    }
    return last;
}
// Every event over `ticks` updates.
std::vector<TrickEvent> all(TrickWatch& watch, const TrickSignals& in, int ticks) {
    std::vector<TrickEvent> out;
    for (int i = 0; i < ticks; ++i)
        if (const auto e = watch.update(in); e.kind != TrickEvent::Kind::none) out.push_back(e);
    return out;
}
bool near(float a, float b) { return std::abs(a - b) < 1e-4f; }
using K = TrickEvent::Kind;
using Why = TrickEvent::Why;

void a_trick_starts_then_lands_with_its_points() {
    TrickWatch w;
    feed(w, idle(), 5);
    check(w.update(trick()).kind == K::started, "A trick starts the tick ActionActive goes on");
    check(feed(w, trick(), 30).kind == K::none && w.in_trick(), "and says it once");
    check(w.update(idle()).kind == K::none && w.waiting(), "Its points are not in the tick it ends");
    const auto e = w.update(idle(11, 1.5f, 1));
    check(e.kind == K::landed && near(e.points, 11) && near(e.multiplier, 1.5f), "Landed: 11 points, the first trick of a line");
}

// LineScore is the actions' points without the multiplier (on foot 425+367 = 792 at x2), so a trick's
// points are its plain step, however the multiplier moves.
void a_second_trick_in_a_line_scores_its_own_points() {
    TrickWatch w;
    feed(w, idle(), 5);
    feed(w, trick(), 30);
    w.update(idle());
    w.update(idle(11, 1.5f, 1));
    feed(w, trick(11, 1.5f, 0.9f), 20);
    w.update(idle(11, 1.5f, 0.9f));
    const auto f = w.update(idle(708, 2.0f, 0.95f));
    check(f.kind == K::landed && near(f.points, 697) && near(f.multiplier, 2), "The multiplier's rise does not scale the trick's points");
    feed(w, trick(708, 2.0f, 0.9f), 20);
    w.update(idle(708, 2.0f, 0.9f));
    const auto g = w.update(idle(958, 2.0f, 0.9f));
    check(g.kind == K::landed && near(g.points, 250), "and the next one has its own again");
}

// The board line of the second launch: Ollie, Heelflip, Ollie, Heelflip, Ollie at x1.5.
void a_board_line_lands_each_trick_with_its_own_points() {
    TrickWatch w;
    feed(w, idle(), 3);
    const float line[] = {0, 2, 24, 26, 48, 50};
    std::vector<float> points;
    for (int i = 0; i < 5; ++i) {
        const float multiplier = i ? 1.5f : 0;
        const float timer = i ? 1.0f - 0.25f * static_cast<float>(i) : 0;
        feed(w, idle(line[i], multiplier, timer), 6);
        feed(w, trick(line[i], multiplier, timer), 25);
        w.update(idle(line[i], multiplier, timer));
        const auto e = w.update(idle(line[i + 1], 1.5f, i ? timer : 1));
        check(e.kind == K::landed && near(e.multiplier, 1.5f), "Each board trick lands at x1.5");
        points.push_back(e.points);
    }
    check(points == std::vector<float>{2, 22, 2, 22, 2}, "with exactly the points it banked (no 2.0000009)");
}

void points_are_the_line_score_step_when_the_multiplier_moves() {
    TrickWatch w;
    feed(w, idle(22, 1.5f, 0.6f), 3);
    feed(w, trick(22, 1.5f, 0.5f), 20);
    w.update(idle(22, 1.5f, 0.5f));
    const auto e = w.update(idle(258, 2.0f, 0.7f));
    check(e.kind == K::landed && near(e.points, 236) && near(e.multiplier, 2), "22 at x1.5 then 258 at x2 is a trick of 236");
}

// LineScore never moved while ActionActive was on in play. If it does, the trick still counts from its
// start (not from the tick before the bank), and the landing says LineScore moved.
void points_count_from_the_tricks_start_when_line_score_moves_during_it() {
    TrickWatch w;
    feed(w, idle(10, 1.5f, 0.8f), 3);
    check(w.update(trick(10, 1.5f, 0.7f)).kind == K::started, "A trick starts with the line at 10");
    feed(w, trick(10, 1.5f, 0.7f), 5);
    feed(w, trick(14, 1.5f, 0.7f), 5); // LineScore moves while it goes on
    check(w.update(idle(14, 1.5f, 0.7f)).kind == K::none, "Nothing on the tick it ends");
    const auto e = w.update(idle(30, 1.5f, 0.9f));
    check(e.kind == K::landed && near(e.points, 20) && e.score_moved, "It lands with 30 less the 10 at its start, and says LineScore moved");
    feed(w, trick(30, 1.5f, 0.8f), 10);
    w.update(idle(30, 1.5f, 0.8f));
    const auto f = w.update(idle(42, 1.5f, 0.9f));
    check(f.kind == K::landed && near(f.points, 12) && !f.score_moved, "and the next trick, whose LineScore held, does not say it");
    TrickWatch slow;
    feed(slow, idle(10, 1.5f, 0.8f), 3);
    feed(slow, trick(10, 1.5f, 0.7f), 5);
    feed(slow, trick(14, 1.5f, 0.7f), 2);
    const auto g = slow.update(idle(30, 1.5f, 0.9f)); // the bank on the tick the trick ends (a slow tick)
    check(g.kind == K::landed && near(g.points, 20) && g.score_moved, "A bank on the tick the trick ends counts from its start too");
}

// A line ending while a trick goes on takes LineScore to 0 on that tick: that is the line's end, not
// the trick's score moving. The trick can still land after it, counted from the next line's 0.
void a_line_ending_during_a_trick_is_not_its_score_moving() {
    TrickWatch w;
    feed(w, idle(8, 1.5f, 0.3f), 3);
    feed(w, trick(8, 1.5f, 0.3f), 5);
    const auto e = w.update(trick()); // the line ends with 0.3 of its time left
    check(e.kind == K::broken && e.why == Why::ended && w.in_trick(), "The line cut short is said, and the trick goes on");
    feed(w, trick(), 5);
    check(w.update(idle()).kind == K::none, "Nothing on the tick it ends");
    const auto f = w.update(idle(25, 1.5f, 1));
    check(f.kind == K::landed && near(f.points, 25) && !f.score_moved, "It lands with the new line's 25, and LineScore did not move for it");
}

// The count before the trick list's array: its top bit is a flag, and more rows than the list keeps is
// not this build's list, so it is refused rather than clamped.
void the_row_count_is_masked_and_refused_above_the_cap() {
    check(TrickRows::count_of(0x80000003u) == 3u, "The count's top bit is masked");
    check(TrickRows::count_of(5) == 5u && TrickRows::count_of(0) == 0u, "5 rows is the list's cap");
    check(!TrickRows::count_of(6) && !TrickRows::count_of(0x80000006u) && !TrickRows::count_of(0x7fffffffu), "and more is refused");
}

// The session's first on-foot Jump: its bank started the line (Multiplier 0 to 1.5, LineTimer 0 to 1)
// but LineScore stayed 0 until the next trick's 8.
void a_first_move_the_game_kept_back_lands_with_no_points() {
    TrickWatch w;
    feed(w, idle(), 3);
    feed(w, trick(), 20);
    check(w.update(idle()).kind == K::none, "Nothing on the tick it ends");
    check(w.update(idle(0, 1.5f, 1)).kind == K::none && w.waiting(), "The line starts, and LineScore may yet follow");
    check(w.update(idle(0, 1.5f, 0.998f)).kind == K::none, "a tick of grace");
    const auto e = w.update(idle(0, 1.5f, 0.996f));
    check(e.kind == K::landed && near(e.points, 0) && near(e.multiplier, 1.5f) && !w.waiting(), "then it lands with the 0 the game banked");
    feed(w, trick(0, 1.5f, 0.9f), 20);
    w.update(idle(0, 1.5f, 0.9f));
    const auto f = w.update(idle(8, 1.5f, 0.9f));
    check(f.kind == K::landed && near(f.points, 8), "and the next trick lands with its 8");
    // A bank that refills the timer a tick before LineScore follows is still that trick's points.
    feed(w, trick(8, 1.5f, 0.5f), 20);
    w.update(idle(8, 1.5f, 0.5f));
    check(w.update(idle(8, 1.5f, 0.6f)).kind == K::none, "The timer refills first");
    const auto g = w.update(idle(30, 1.5f, 0.6f));
    check(g.kind == K::landed && near(g.points, 22), "and LineScore follows within the grace");
}

void a_wipeout_ends_the_trick_for_nothing() {
    TrickWatch w;
    feed(w, idle(0, 1), 2);
    feed(w, trick(0, 1), 10);
    feed(w, idle(300, 1), 2);
    feed(w, trick(300, 1), 10);
    const auto e = w.update(down(trick(300, 1)));
    check(e.kind == K::broken && e.why == Why::wipeout && !w.in_trick(), "A wipeout ends the trick going on");
    check(feed(w, idle(), 30).kind == K::none, "which scores nothing");
    check(feed(w, down(idle()), 2).kind == K::none, "A wipeout with nothing going on says nothing");
    feed(w, trick(0, 1), 5);
    const auto f = w.update(down(idle(0, 1)));
    check(f.kind == K::broken && f.why == Why::wipeout, "and one while the points are awaited breaks it");
}

// While the skater is down nothing starts or lands, and at most one break comes out.
void nothing_starts_or_lands_during_a_wipeout() {
    TrickWatch w;
    feed(w, idle(10, 1.5f, 0.8f), 3);
    feed(w, trick(10, 1.5f, 0.8f), 5);
    auto said = all(w, down(trick(10, 1.5f, 0.8f)), 3);
    said.push_back(w.update(down(idle(10, 1.5f, 0.8f))));
    said.push_back(w.update(down(trick(10, 1.5f, 0.8f))));
    said.push_back(w.update(down(idle(25, 1.5f, 0.8f))));
    said.push_back(w.update(down(idle(25, 1.5f, 0.9f))));
    for (const auto& e : all(w, down(idle(25, 1.5f, 0.9f)), 5)) said.push_back(e);
    std::vector<TrickEvent> told;
    for (const auto& e : said)
        if (e.kind != K::none) told.push_back(e);
    check(told.size() == 1 && told[0].kind == K::broken && told[0].why == Why::wipeout,
          "ActionActive rising and LineScore stepping while down give one break and nothing more");
    check(feed(w, idle(25, 1.5f, 0.9f), 30).kind == K::none, "nor anything once the skater is up");
}

void a_line_cut_short_is_broken_once() {
    {
        TrickWatch w;
        feed(w, idle(8, 1.5f, 0.19f), 3);
        const auto e = w.update(idle());
        check(e.kind == K::broken && e.why == Why::ended, "A line ending with 0.19 of its time left was cut short");
        check(feed(w, idle(), 30).kind == K::none, "and that is said once");
    }
    {
        TrickWatch w;
        feed(w, idle(8, 1.5f, 0.8f), 3);
        feed(w, trick(8, 1.5f, 0.8f), 3);
        const auto said = all(w, down(trick(8, 1.5f, 0.78f)), 2);
        const auto then = all(w, down(idle()), 5);
        check(said.size() == 1 && said[0].why == Why::wipeout && then.empty(), "A wipeout and then the line cut short: one break");
    }
    {
        TrickWatch w;
        feed(w, idle(22, 1.5f, 0.008f), 3);
        check(feed(w, idle(), 10).kind == K::none, "A line that ran out says nothing");
    }
    {
        TrickWatch w;
        feed(w, idle(792, 2, 0.01f), 3);
        feed(w, trick(792, 2, 0), 40); // the line holds at 0 while the action goes on
        w.update(idle(792, 2, 0));
        const auto e = w.update(idle(877, 2, 0.1047f));
        check(e.kind == K::landed && near(e.points, 85), "A line held at 0 through a trick is refilled by its bank");
        check(feed(w, idle(877, 2, 0.1f), 10).kind == K::none, "and not broken");
    }
}

void broken_and_a_start_on_one_tick() {
    TrickWatch w;
    feed(w, idle(5, 1.5f, 0.78f), 3);
    const auto e = w.update(trick());
    check(e.kind == K::broken && e.why == Why::ended, "The line cut short comes first");
    const auto f = w.update(trick());
    check(f.kind == K::started && f.late == 1 && w.in_trick(), "and the start on the next tick, a tick late");
    w.update(idle());
    const auto g = w.update(idle(65, 1.5f, 1));
    check(g.kind == K::landed && near(g.points, 65), "That trick counts from the new line's 0");
}

void a_trick_whose_points_never_come_is_skipped() {
    TrickWatch w(5);
    feed(w, idle(50, 1), 2);
    feed(w, trick(50, 1), 10);
    const auto none = feed(w, idle(50, 1), 10);
    check(!w.waiting(), "Waiting gives up after its ticks");
    feed(w, trick(50, 1), 10);
    const auto e = feed(w, idle(90, 1), 2);
    check(none.kind == K::none && e.kind == K::landed && near(e.points, 40), "and the next trick is still read");
}

void the_line_ending_is_not_a_trick() {
    TrickWatch w;
    feed(w, idle(500, 2), 5);
    check(feed(w, idle(), 5).kind == K::none, "The line's score going back to 0 is no event");
    check(feed(w, idle(100, 1), 5).kind == K::none, "nor is a rise with no trick before it");
}

// ---- Which rows were the action's.
TrickRow row(std::uint64_t handle, std::string name) { return {.handle = handle, .name = std::move(name)}; }
using Rows = std::vector<TrickRow>;
void observe(TrickRows& rows, const Rows& list, int ticks) {
    for (int i = 0; i < ticks; ++i) rows.observe(list);
}

void one_row_per_board_trick() {
    TrickRows rows;
    observe(rows, {}, 3);
    rows.observe({row(0x00000001763f0000, "Ollie")});
    rows.mark_start();
    observe(rows, {row(0x00000001763f0000, "Ollie")}, 20);
    auto landed = rows.since_start();
    check(landed.name == "Ollie" && landed.names == std::vector<std::string>{"Ollie"}, "A board trick is its one row");
    auto heelflip = row(0x00000001767f0000, "Heelflip");
    auto ollie = row(0x00000001763f0000, "Ollie");
    ollie.landing = "ID_TRICK_LANDING_CLEAN";
    observe(rows, {ollie}, 5);
    rows.observe({heelflip, ollie});
    rows.mark_start();
    heelflip.landing = "ID_TRICK_LANDING_SKETCHY";
    heelflip.stance = "ID_STANCE_SWITCH";
    observe(rows, {heelflip, ollie}, 20);
    landed = rows.since_start();
    check(landed.name == "Heelflip" && landed.names == std::vector<std::string>{"Heelflip"} && landed.landing == "ID_TRICK_LANDING_SKETCHY" &&
              landed.stance == "ID_STANCE_SWITCH" && !landed.slam,
          "the next one its own row, with its landing and stance as last read");
}

// The 425-point Slide window on foot: Slide, then Back Pose twice while it went on.
void an_action_with_several_rows_names_them_all() {
    TrickRows rows;
    const auto jump = row(0x17830ull << 16, "Jump");
    observe(rows, {jump}, 10);
    rows.observe({row(0x17846ull << 16, "Slide"), jump});
    rows.mark_start();
    observe(rows, {row(0x17846ull << 16, "Slide"), jump}, 8);
    observe(rows, {row(0x17864ull << 16, "Back Pose"), row(0x17846ull << 16, "Slide"), jump}, 8);
    observe(rows, {row(0x17899ull << 16, "Back Pose"), row(0x17864ull << 16, "Back Pose"), row(0x17846ull << 16, "Slide"), jump}, 8);
    const auto landed = rows.since_start();
    check(landed.names == (std::vector<std::string>{"Slide", "Back Pose", "Back Pose"}) && landed.name == "Back Pose",
          "Every row the action added, oldest first, and the newest as its name");
}

void a_row_from_the_last_line_is_not_the_new_actions() {
    TrickRows rows;
    const auto carried = row(0x17830ull << 16, "Slam");
    observe(rows, {carried}, 6); // the old line's row, still there as the new line starts
    rows.mark_start();
    observe(rows, {carried}, 2);
    observe(rows, {row(0x177d8ull << 16, "Slam"), carried}, 10);
    const auto landed = rows.since_start();
    check(landed.names == std::vector<std::string>{"Slam"} && landed.name == "Slam", "A row there before the start is not counted");
    TrickRows none;
    observe(none, {carried}, 4);
    none.mark_start();
    observe(none, {carried}, 4);
    check(none.since_start().names.empty() && none.since_start().name.empty(), "and with no row of its own the action has none");
}

void a_reused_row_with_a_new_generation_is_a_new_row() {
    TrickRows rows;
    observe(rows, {row(0x00000001763f0000, "Ollie")}, 10);
    observe(rows, {}, 5); // the list is emptied after the line
    rows.observe({row(0x00010001763f0000, "Heelflip")});
    rows.mark_start();
    check(rows.since_start().name == "Heelflip", "The same row model with the next generation is a new row");
    TrickRows same;
    observe(same, {row(0x00000001763f0000, "Ollie")}, 10);
    same.mark_start();
    same.observe({row(0x00010001763f0000, "Heelflip"), row(0x00000001763f0000, "Ollie")});
    check(same.since_start().names == std::vector<std::string>{"Heelflip"}, "also while the old one is still listed");
}

void a_row_seen_a_tick_before_the_start_counts() {
    TrickRows rows;
    observe(rows, {}, 5);
    rows.observe({row(0x1763full << 16, "Manual")}); // the name and the row came a tick before the rise
    rows.observe({row(0x1763full << 16, "Manual")});
    rows.mark_start();
    check(rows.since_start().name == "Manual", "A row first seen one tick before the start is the action's");
    TrickRows late;
    observe(late, {}, 5);
    late.observe({row(0x1763full << 16, "Manual")});
    late.observe({row(0x1763full << 16, "Manual")});
    late.observe({row(0x1763full << 16, "Manual")});
    late.mark_start(1); // a start told a tick late
    check(late.since_start().name == "Manual", "counted from when it happened");
    TrickRows early;
    observe(early, {}, 5);
    observe(early, {row(0x1763full << 16, "Ollie")}, 3);
    early.mark_start();
    check(early.since_start().names.empty(), "but one seen two ticks before is not");
}

void an_action_adding_six_rows_reports_the_five_newest() {
    TrickRows rows;
    observe(rows, {}, 3);
    Rows list;
    for (int i = 0; i < 6; ++i) {
        list.insert(list.begin(), row(static_cast<std::uint64_t>(0x17800 + i) << 16, "Back Pose " + std::to_string(i)));
        if (list.size() > TrickRows::most_rows) list.pop_back(); // the list keeps 5
        rows.observe(list);
        if (i == 0) rows.mark_start();
    }
    const auto landed = rows.since_start();
    check(landed.names.size() == 5 && landed.names.front() == "Back Pose 1" && landed.name == "Back Pose 5", "The 5 the list still holds");
}

void a_slam_row_is_flagged() {
    TrickRows rows;
    observe(rows, {}, 3);
    auto slam = row(0x178640000, "Slam");
    rows.observe({slam});
    rows.mark_start();
    auto newer = row(0x177d80000, "Slam");
    newer.slam = true; // the slam icon, no damage written yet
    slam.slam = true;
    slam.damage = "ID_DAMAGE_SPRAINED";
    observe(rows, {newer, slam}, 5);
    const auto landed = rows.since_start();
    check(landed.slam && landed.damage == "ID_DAMAGE_SPRAINED" && landed.name == "Slam", "A slam row flags the action, with its damage");
    TrickRows jump;
    jump.observe({row(0x17830ull << 16, "Jump")});
    jump.mark_start();
    check(!jump.since_start().slam && jump.since_start().damage.empty(), "and a Jump is no slam");
}
}

int main() {
    try {
        a_trick_starts_then_lands_with_its_points();
        a_second_trick_in_a_line_scores_its_own_points();
        a_board_line_lands_each_trick_with_its_own_points();
        points_are_the_line_score_step_when_the_multiplier_moves();
        points_count_from_the_tricks_start_when_line_score_moves_during_it();
        a_line_ending_during_a_trick_is_not_its_score_moving();
        the_row_count_is_masked_and_refused_above_the_cap();
        a_first_move_the_game_kept_back_lands_with_no_points();
        a_wipeout_ends_the_trick_for_nothing();
        nothing_starts_or_lands_during_a_wipeout();
        a_line_cut_short_is_broken_once();
        broken_and_a_start_on_one_tick();
        a_trick_whose_points_never_come_is_skipped();
        the_line_ending_is_not_a_trick();
        one_row_per_board_trick();
        an_action_with_several_rows_names_them_all();
        a_row_from_the_last_line_is_not_the_new_actions();
        a_reused_row_with_a_new_generation_is_a_new_row();
        a_row_seen_a_tick_before_the_start_counts();
        an_action_adding_six_rows_reports_the_five_newest();
        a_slam_row_is_flagged();
        std::cout << "trick watch tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "trick watch test failed: " << error.what() << '\n';
        return 1;
    }
}
