#pragma once
#include <array>
#include <optional>
#include <string_view>

// The plugin time budget: how long each plugin may take of a client tick, on average over a second,
// before the plugin host stops it (Extension/Plugins/plugin_vm.h, Limits::tick_ms). The player picks
// it in the launcher (Settings, GAME, Plugin time budget), which saves it with its other settings
// (ReSkateLauncher.settings.json, under the --dev-data-root when there is one) and launches the game
// with it as --plugin-tick-ms, which reaches the game as RESKATE_PLUGIN_TICK_MS. The game's plugin
// host gives it to every plugin as it loads (game_limits, plugin_host.h). A plugin has no say: its
// manifest cannot name a budget and its sandbox has no environment to read or set.
//
// 2 ms is what every plugin had before there was a setting, and stays the default. Plugins that
// drive a body's physics each tick measured 3.6-3.7 ms in game, so a player who runs one can allow
// more, up to 6 ms: a tick at 60 a second is 16.7 ms, and a few plugins at 6 ms would cost frames.
namespace dingosdk::plugin_time_budget {
inline constexpr int default_ms = 2;
inline constexpr std::array<int, 5> choices_ms{2, 3, 4, 5, 6};
inline constexpr wchar_t variable[] = L"RESKATE_PLUGIN_TICK_MS";
// Where it is changed, named in a stopped plugin's reason and in plugin list.
inline constexpr char setting[] = "the launcher: Settings, GAME, Plugin time budget";

constexpr bool allowed(long long ms) noexcept {
    for (const int choice : choices_ms)
        if (choice == ms) return true;
    return false;
}

// "4" is 4. Anything but one of the choices, in whole milliseconds and nothing else, is none.
template <class Char> constexpr std::optional<int> parse(std::basic_string_view<Char> text) noexcept {
    if (text.empty() || text.size() > 2) return std::nullopt;
    int ms = 0;
    for (const Char c : text) {
        if (c < Char('0') || c > Char('9')) return std::nullopt;
        ms = ms * 10 + static_cast<int>(c - Char('0'));
    }
    return allowed(ms) ? std::optional<int>(ms) : std::nullopt;
}
constexpr std::optional<int> parse(std::string_view text) noexcept { return parse<char>(text); }
constexpr std::optional<int> parse(std::wstring_view text) noexcept { return parse<wchar_t>(text); }

// A saved value: its choice, or the default for one that is not a choice (a settings file edited
// by hand). The game reads its variable with launcher::plugin_tick_ms (launcher_support.h).
constexpr int or_default(long long ms) noexcept { return allowed(ms) ? static_cast<int>(ms) : default_ms; }
}
