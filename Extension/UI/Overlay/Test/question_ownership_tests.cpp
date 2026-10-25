#include "Extension/UI/Overlay/overlay_internal.h"
#include "Extension/UI/Overlay/overlay.h"

// Reuse the real capture broker fixture, with its single menu provider adapted
// to the actual production overlay predicate. No actor/native guards are real.
#define DINGOSDK_CAPTURE_NATIVE_REAL_OVERLAY_MENU
#define DINGOSDK_CAPTURE_NATIVE_NO_MAIN
#include "Engine/Game/Input/Test/input_lease_capture_native_tests.cpp"

extern "C" unsigned question_unavailable_calls() noexcept;
extern "C" bool question_unavailable_tls_clean() noexcept;

namespace {
namespace ui = dingosdk::overlay;
namespace detail = dingosdk::overlay::detail;
using fixture::check;

void all_owners_clear() {
    const auto& s = detail::state();
    check(!s.visible && !s.console_visible && !s.editor_visible && !s.chat_visible &&
        !s.hub_typing && !s.hub_pointer && !s.prompt_pointer && !s.item_search_visible &&
        !s.plugin_screen_visible && !s.plugin_dialog_visible && !s.prompt_input_active &&
        !ui::menu_open_flag() && !ui::question_asking() && !ui::message_asking(),
        "fresh process has every actual interactive owner clear");
    check(!detail::interactive_visible(s) && !ui::interface_open(),
        "actual overlay guard admits the all-clear positive control");
}

void positive_control() {
    all_owners_clear();
    capture_fixture::prime(1000);
    const auto handle = capture_fixture::lease_request();
    (void)capture_fixture::frame(1010);
    const auto sample = capture_fixture::sample(handle);
    check(sample.handle == handle, "all-clear fresh source yields a real issued broker snapshot");
    capture_fixture::source_cleanup(handle);
}

void fresh_refusal() {
    auto& s = detail::state();
    // The completed positive control precedes this transition. Do not refresh
    // render aggregates or client prompt capture after opening the question.
    s.hub_pointer.store(true);
    check(ui::interface_open(), "native page pointer initially owns the real overlay guard");
    const auto revision = capture_fixture::revision();
    ui::ask_question("FIXTURE", "QUESTION", "Unapplied changes", "YES", "NO", {});
    check(capture_fixture::revision() > revision,
        "actual question creation advances real publication authority immediately");
    s.hub_pointer.store(false);
    check(ui::question_asking() && !s.prompt_pointer && !s.prompt_input_active,
        "question remains active before either aggregate prompt poll");
    check(detail::interactive_visible(s) && ui::interface_open(),
        "actual question owns interface immediately after native page closes");
    lease::Handle blocked;
    lease::Reason reason{};
    check(!service::lease_request(21, 0, blocked, reason) && !blocked.sequence &&
        reason == lease::Reason::menu_open,
        "actual broker rejects fresh admission specifically through real overlay menu guard");
    ui::question_answer(false);
    check(!ui::question_asking() && !ui::interface_open(),
        "answer clears only the dedicated owner when other owners are absent");
}

void other_prompt() {
    auto& s = detail::state();
    s.prompt_pointer.store(true);
    unsigned answers{};
    ui::ask_question("FIXTURE", "QUESTION", "Another prompt exists", "YES", "NO",
        [&](bool yes) { check(!yes, "actual callback receives its selected answer"); ++answers; });
    ui::question_answer(false);
    check(answers == 1 && !ui::question_asking() && s.prompt_pointer &&
        detail::interactive_visible(s) && ui::interface_open(),
        "answer preserves another actual prompt owner and the real admission fence");
    s.prompt_pointer.store(false);
    check(!ui::interface_open(), "only the test-owned remaining prompt is cleared afterward");
}

void reentrant() {
    unsigned first{}, second{};
    ui::ask_question("FIXTURE", "FIRST", "Reentrant answer", "YES", "NO",
        [&](bool yes) {
            check(yes && !service::publication_held(),
                "answer callback runs after the real publication gate is released");
            ++first;
            ui::ask_question("FIXTURE", "SECOND", "Created by callback", "YES", "NO",
                [&](bool answer) {
                    check(!answer && !service::publication_held(),
                        "nested question answer also runs without a publication token");
                    ++second;
                });
        });
    ui::question_answer(true);
    check(first == 1 && second == 0 && ui::question_asking() && ui::interface_open(),
        "callback-created question retains its independent immediate ownership");
    ui::question_answer(false);
    ui::question_answer(false);
    check(first == 1 && second == 1 && !ui::question_asking() && !ui::interface_open(),
        "each callback is consumed once and an empty answer cannot replay one");
    check(capture_fixture::revision() != 0 && !service::publication_held(),
        "reentrant callback never poisons or leaks the real nonrecursive gate");
}

void no_unexpected_work() {
    capture_fixture::no_actor_calls();
    check(!question_unavailable_calls() && question_unavailable_tls_clean(),
        "unexpected hooks, native calls and unrelated UI paths remain untouched");
}
}

int main(int argc, char** argv) {
    if (argc != 2) { std::cerr << "one question scenario required\n"; return 2; }
    positive_control();
    const std::string_view scenario(argv[1]);
    if (scenario == "fresh_refusal") fresh_refusal();
    else if (scenario == "other_prompt") other_prompt();
    else if (scenario == "reentrant") reentrant();
    else { std::cerr << "unknown question scenario\n"; return 2; }
    no_unexpected_work();
    std::cout << "question_ownership " << scenario << " checks=" << fixture::checks
              << " native_actions=0\n";
}
