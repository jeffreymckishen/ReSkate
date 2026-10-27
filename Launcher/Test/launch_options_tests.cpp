// The launcher's settings as the flags a launch is made with (parse_launch_options), and as the game
// reads them back: here the plugin time budget, which Settings saves as plugin_tick_ms, passes as
// --plugin-tick-ms, and the game reads as RESKATE_PLUGIN_TICK_MS (launcher::plugin_tick_ms).
#include "Engine/Core/Platform/launcher_support.h"
#include "Engine/Core/Platform/plugin_time_budget.h"

#include <Windows.h>

#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

using namespace dingosdk;
namespace budget = plugin_time_budget;

namespace {

int failures = 0;

void check(bool condition, const char* what) {
    if (condition) return;
    std::cerr << "FAIL: " << what << '\n';
    ++failures;
}

bool refused(std::vector<std::wstring> arguments) {
    try {
        (void)launcher::parse_launch_options(arguments);
    } catch (const std::runtime_error&) {
        return true;
    }
    return false;
}

void the_budget_parses_and_defaults_to_two() {
    check(budget::default_ms == 2, "the default is the 2 ms every plugin had before the setting");
    check(launcher::LaunchOptions{}.plugin_tick_ms == 2, "a launch without the flag gives plugins 2 ms");
    check(launcher::parse_launch_options({}).plugin_tick_ms == 2, "and so does parsing no arguments");
    for (const int ms : budget::choices_ms) {
        const auto options = launcher::parse_launch_options({L"--plugin-tick-ms=" + std::to_wstring(ms)});
        check(options.plugin_tick_ms == ms, "each choice is taken");
        check(options.game_arguments.empty(), "and is not passed on to Skate.exe");
    }
    check(budget::choices_ms.front() == 2 && budget::choices_ms.back() == 6, "the choices run from 2 to 6 ms");
    check(budget::parse(L"4") == 4 && budget::parse("4") == 4, "\"4\" is 4");
}

void out_of_range_budgets_are_refused() {
    for (const auto* bad : {L"--plugin-tick-ms=", L"--plugin-tick-ms=0", L"--plugin-tick-ms=1", L"--plugin-tick-ms=7",
                            L"--plugin-tick-ms=60", L"--plugin-tick-ms=100", L"--plugin-tick-ms=-4", L"--plugin-tick-ms=4.5",
                            L"--plugin-tick-ms=4ms", L"--plugin-tick-ms= 4", L"--plugin-tick-ms=abc"})
        check(refused({bad}), "a budget that is not one of the choices stops the launch with a message");
    // A settings file edited by hand: the default, not a stopped launch or a bigger budget.
    check(budget::or_default(9) == 2 && budget::or_default(0) == 2 && budget::or_default(-3) == 2, "a saved value off the list is 2");
    check(budget::or_default(4'000'000'000LL) == 2, "even one past an int");
    check(budget::or_default(5) == 5, "a saved choice is kept");
}

// What the game reads: RESKATE_PLUGIN_TICK_MS as start_game sets it (launch.cpp), or as a player
// might set it by hand. `off_list` starts the other way round each time, so the read must set it.
int read_with(const wchar_t* value, bool& off_list) {
    SetEnvironmentVariableW(budget::variable, value);
    off_list = !off_list;
    return launcher::plugin_tick_ms(&off_list);
}

void the_game_reads_the_budget_from_its_variable() {
    bool off_list = false;
    check(read_with(nullptr, off_list) == 2 && !off_list, "no variable is 2 ms, with nothing to say");
    for (const int ms : budget::choices_ms) {
        const auto text = std::to_wstring(ms);
        check(read_with(text.c_str(), off_list) == ms && !off_list, "each choice the launcher passes is kept");
    }
    check(read_with(L"4", off_list) == 4 && !off_list, "\"4\" is 4");
    check(read_with(L"", off_list) == 2 && !off_list, "an empty variable is no variable");
    for (const auto* bad : {L"9", L"0", L"1", L"7", L"60", L"-4", L"4.5", L" 4", L"4ms", L"abc"})
        check(read_with(bad, off_list) == 2 && off_list, "a value off the list is 2 ms, and is said");
    check(read_with(L"1234567", off_list) == 2 && off_list, "one that just fits the read is 2 ms, and is said");
    check(read_with(L"123456789", off_list) == 2 && off_list, "one too long to read is 2 ms, and is said");
    check(read_with(L"6", off_list) == 6 && launcher::plugin_tick_ms() == 6, "and the read works without asking why");
    SetEnvironmentVariableW(budget::variable, nullptr);
}

} // namespace

int main() {
    the_budget_parses_and_defaults_to_two();
    out_of_range_budgets_are_refused();
    the_game_reads_the_budget_from_its_variable();
    if (failures) {
        std::cerr << failures << " launch option check(s) failed\n";
        return 1;
    }
    std::cout << "launch options: ok\n";
    return 0;
}
