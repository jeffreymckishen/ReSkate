#pragma once
#include <cstdint>
#include <string_view>

// What the score reader (Extension/Skater/score_hud.cpp) reads of skate.'s score HUD: the fields of
// ScoringHUDViewModel (hud_corner.h's score_view_schema, ui/features/hud/scoring) and of its trick
// list's rows, by the hashes of their names in the game's own type data. Code finds every offset by
// hash from the type at run time; the offsets below are what the type held when it was mapped.
//
// Mapped from two read-only probe launches on 2026-11-05: on foot (Jump, Roll, Slam, Slide and Back
// Pose actions; scoremap1) and on the board (Ollie, Heelflip, Kickflip, switch, sketchy and clean
// landings, a manual; scoremap4), with the probe's change log, UI model dumps on the bank ticks and
// screenshots. Not seen: a board bail, a grind or any action that added more than one row on the
// board, and the board after on-foot actions in one session.
namespace dingosdk::game::build::v20260929::score_hud {
// ---- ScoringHUDViewModel
// f32 LineScore @0x2a0: the line's action points WITHOUT the multiplier (on foot 5+7+5+3+2 = 22 at
// x1.5, 425+367 = 792 at x2; on the board 2+22+2+22+2 = 50 at x1.5), raised the tick after an action
// ends (one bank per action), 0 on the tick the line ends. It is what was banked, not what was shown:
// a sketchy Switch Kickflip showed 15 and banked 13.
inline constexpr std::uint32_t line_score = 0x40bff667;
inline constexpr std::uint32_t multiplier = 0x6a41d8c6;    // f32 Multiplier @0x1d8: 0 outside a line, 1.5 or 2 seen
inline constexpr std::uint32_t action_active = 0x7aab675c; // bool ActionActive @0x250: on for each scored action
// f32 LineTimer @0x24c, 0..1: 1 at a line's first bank, drains 0.1 a second, held at 0 while an
// action goes on, 0 on the tick the line ends. Lines that ran out read 0.035 or below on their last
// tick; the two on-foot falls that ended a line early read 0.188 and 0.778.
inline constexpr std::uint32_t line_timer = 0xbd9da937;
// bool IsSlam @0x37a: went true at the first on-foot action of a session (a Jump) and stayed true for
// the rest of that on-foot session, through two falls and six Slam rows; false all through a
// board-only session. Whether a board line clears it is unknown. Not a slam signal, so not read.
inline constexpr std::uint32_t is_slam = 0xaf6e13b9;
// LabelViewModels: SequenceHeader @0xa0 read "" all through both launches; SequenceDescriptor @0x1e0
// held a string id ("ID_SCORING_SLAM_TIER_1", drawn "OUCH") from an on-foot action passing 400
// points. (SequenceState, int32 @0x248, is hud_corner.h's sequence_state: 1 while ActionActive is on.)
inline constexpr std::uint32_t sequence_header = 0xb3e9db3c, sequence_descriptor = 0xe8264626;

// ---- The trick list: a StackViewModel @0x0 of the root, whose Items (hud_corner.h's stack_items) are
// stack items (StackItemViewModel, 1424 bytes) of UI/Features/HUD/Scoring/TrickHistoryStackItem. Each
// item's Content (hud_corner.h's item_content) is a presenter whose data Ref holds a row model's
// handle. The newest row is at [0]; the list keeps at most 5 (the widget draws 3) and is emptied
// about 150 ms after the line ends. An action's first row comes on the tick ActionActive rises;
// on foot an action can add more rows while it goes on (a Slide added Slide, Back Pose, Back Pose).
// Row models are reused with a new generation in the handle's top 16 bits.
inline constexpr std::uint32_t trick_list = 0x84db5623;
inline constexpr std::uint32_t content_data = 0x25e4d6c8; // Content's data Ref @+0x8 (16 bytes)
inline constexpr std::uint32_t ref_handle = 0xecfbf5f3;   // the Ref's handle @+0x8: the row model
inline constexpr unsigned most_trick_rows = 5;
// The row model (2048 bytes). Its labels hold ids or the bare name; the HUD composes what it draws
// ("Switch Kickflip Sketchy", "Harsh Slam") from them.
inline constexpr std::uint32_t trick_row_schema = 0xbf5e8a16;
inline constexpr std::uint16_t trick_row_size = 2048;
inline constexpr std::uint32_t row_name = 0x53bac52d;    // label @0x0: "Ollie", "Kickflip", "Manual", "Jump", "Slam", "Back Pose"
inline constexpr std::uint32_t row_landing = 0x0205e59c; // label @0x150: ID_TRICK_LANDING_CLEAN or _SKETCHY, written at the landing
inline constexpr std::uint32_t row_stance = 0x062499e8;  // label @0x1f0: ID_STANCE_SWITCH with the name, "" in regular stance
inline constexpr std::uint32_t row_damage = 0xfce95488;  // label @0x520: ID_DAMAGE_BRUISED or _SPRAINED on Slam rows, else ""
// Asset @0x68, the row's icon: img_Icon_Scoring_SkateTrick_64 on every board row,
// img_Icon_Scoring_Wipeout_64 on Jump and Roll rows, and slam_icon on all 4 Slam rows dumped (21
// dumps; in one, 36 ms before its bank, the newest had no damage label yet). So a row is a slam when
// its damage is set or it has slam_icon. (Each row model's own IsSlam, 0xaf6e13b9, read 1 on Jump and
// Roll rows too, so it is not read.)
inline constexpr std::uint32_t row_icon = 0xc9d594c3;
inline constexpr std::string_view slam_icon = "UI/Textures/Icons/Scoring/img_Icon_Scoring_Wipeout_Broken_64";

// ---- LabelViewModel (104 bytes): its Text (kind 7, a char*) @+0x0.
inline constexpr std::uint32_t label_schema = 0xbfe23948;
inline constexpr std::uint32_t label_text = 0x4d8e01b9;

// ---- What a plugin's own line (Extension/UI/score_line_hud.cpp) writes: a ScoringHUDViewModel of
// the SDK's own, never the game's, shown by an item of ours in HudViewModel's DpadScoringStack.
// Mapped on foot in scoremap1 (P1: the score probe's change log, its UI model dumps and the moment
// screenshots) and checked by drawing one in the scorep2 launch on 2026-11-06 (P2: probe DLL B815AA96,
// screenshots p2-a_1-t007 and p2-a_8-t014 showed "1234" and the timer arc at 0.75 from our model).
inline constexpr std::uint16_t score_view_size = 896; // ScoringHUDViewModel's size, checked before one is made
// The widgets: the score HUD (the Content of the game's own DpadScoringStack item, P1 "stack 1 item 1")
// and a trick list row (the Content of each trick list item, P1's dumps).
inline constexpr std::string_view score_widget = "UI/Features/HUD/Scoring/ScoringHUD_Widget";
inline constexpr std::string_view trick_row_widget = "UI/Features/HUD/Scoring/TrickHistoryStackItem";
inline constexpr unsigned trick_rows_drawn = 3; // of most_trick_rows, the widget drew the newest 3 in every screenshot
// Label @0x108: the big number beside the ring, the current action's points as text ("5", "425"). The
// game sets it at an action's start and never clears it; the widget hides it in the LINE summary.
inline constexpr std::uint32_t action_points = 0x7d1e237c;
// Label @0x170: the ring's number ("1.5", "2"; "0" at rest draws an empty dark ring). It changed on
// the same tick as Multiplier every time, so both are written; which of the two the ring draws is not
// known. P2's ring stayed empty with both written and ring_on below left false.
inline constexpr std::uint32_t multiplier_text = 0x9acb7cf0;
// f32 @0x2a4: the number of "LINE: N", shown exactly while it is above 0. The game kept it 2.0 s after
// each line. The widget drives it itself: in P2 it wrote ours from 4321 to 0 33 ms after we set it with
// LineScore 0, so a line of ours writes LineScore and leaves this to the widget.
inline constexpr std::uint32_t line_shown = 0x9a6daa54;
// f32 @0x364: the ring's orange fill, the action's points over the tier's (exact for 13 actions in
// P1: 5 gave 0.0125, 236 gave 0.59); 400 before a line's first tier, 800 after it.
inline constexpr std::uint32_t action_fill = 0x739c95e8;
inline constexpr float action_fill_points = 400;
// bools @0x251 and @0x252: the game set the first with a line's first LineScore bank and the second
// with its first multiplier (the tick of Multiplier 1.5 and LineTimer 1), and cleared both at the
// line's end (P1, P2). P2's ring stayed empty with the second left false, so it is taken to be the
// ring's; that setting it draws ours is not yet seen. The first rises with the LINE label in a line,
// but the LINE summary after a line showed with it false ("LINE: 937", P1 m5_4), so a closed line of
// ours sets it false as the game does.
inline constexpr std::uint32_t line_on = 0xa0bfc5b4, ring_on = 0x2a7d50b4;
// Ref @0x290 {ScoringDataResource/ActiveScoringData, the game's live scoring model}: never copied into
// a model of ours (its create gives {0, 0}).
inline constexpr std::uint32_t scoring_data = 0xcdffb552;
// A second stack @0x50, always empty in play; emptied in ours with the trick list after a copy.
inline constexpr std::uint32_t second_stack = 0x1a93e458;
// ScoringWidgetExtraInfoStyle (hud_corner.h's extra_info_style): 0 shows the LINE label (0 all
// through both mapped launches).
inline constexpr std::int32_t extra_info_line_score = 0;
// A row model's handle back into the score model that holds it (P1: the game root's handle with 1,
// its trick list). A row of ours keeps what its create gives, never the game's.
inline constexpr std::uint32_t row_back = 0xb99b6691;
}
