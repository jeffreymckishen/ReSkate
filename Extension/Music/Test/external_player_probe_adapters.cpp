// This standalone probe observes Windows media sessions. In-game account and
// audio services are deliberately absent; their unavailable adapters preserve
// the real external_player fallback path without launching the runtime or UI.
#include "Extension/Music/plex_web.h"
#include "Extension/Music/spotify_device.h"
#include "Extension/Music/youtube_music.h"

namespace dingosdk::plex_web {
NowPlaying now_playing() { return {}; }
bool control(Action) { return false; }
}
namespace dingosdk::spotify_device {
bool connected() noexcept { return false; }
external_player::Track now() { return {}; }
std::uint64_t revision() noexcept { return 0; }
void send(external_player::Command) noexcept {}
}
namespace dingosdk::youtube_music {
bool on() noexcept { return false; }
external_player::Track now() { return {}; }
std::uint64_t revision() noexcept { return 0; }
void send(external_player::Command) noexcept {}
}
