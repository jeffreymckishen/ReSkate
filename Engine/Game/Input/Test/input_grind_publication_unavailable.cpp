#include "Engine/Core/Debug/crash_report.h"
#include "Engine/Core/Debug/trace.h"
// The full overlay TU references these unrelated UI/native paths. None belongs
// to a grind-setter test. Fail loudly if any is reached; never fabricate guards,
// actor observations, a throwdown match, a window, or a successfully installed hook.
#include "Extension/UI/Overlay/overlay_internal.h"
#include "Extension/UI/Overlay/input_capture.h"
#include "Extension/UI/Overlay/cursor.h"
#include "Extension/Skater/no_bail.h"
#include "Extension/Throwdowns/throwdown_kit.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>

namespace {
std::atomic<unsigned> unavailable_calls{};
[[noreturn]] void unavailable(const char* name) noexcept {
    unavailable_calls.fetch_add(1);
    std::fputs("Unrelated native/UI path reached by grind regression: ", stderr);
    std::fputs(name, stderr); std::fputc('\n', stderr);
    std::abort();
}
}
extern "C" unsigned input_grind_unavailable_calls() noexcept { return unavailable_calls.load(); }
extern "C" bool input_grind_unavailable_tls_clean() noexcept {
    return dingosdk::overlay::detail::overlay_input_access == 0;
}
namespace dingosdk::overlay::detail {
// In production this datum is defined by playstation_input.cpp. Do not bring the
// HID/device reader into a constructed test merely to supply unused TLS storage.
thread_local unsigned overlay_input_access = 0;
State& state() { unavailable("overlay::detail::state"); }
bool install(Hook&, void*, void*) { unavailable("overlay::detail::install"); }
bool interactive_visible(const State&) { unavailable("overlay::detail::interactive_visible"); }
bool owns_menu_cursor(const State&) { unavailable("overlay::detail::owns_menu_cursor"); }
bool game_window_foreground(HWND) { unavailable("overlay::detail::game_window_foreground"); }
}
namespace dingosdk::throwdowns::kit {
Match match() noexcept { unavailable("throwdowns::kit::match"); }
}
namespace dingosdk {
bool inspect_no_bail_owner(std::uintptr_t, std::uintptr_t, NoBailSkater&, bool&) noexcept {
    unavailable("inspect_no_bail_owner");
}
bool inspect_bmx_switch_admission_owner(std::uintptr_t, std::uintptr_t,
    NoBailSkater&, BmxSwitchAdmissionProtection&) noexcept {
    unavailable("inspect_bmx_switch_admission_owner");
}
bool try_no_bail_skater(std::uintptr_t, NoBailSkater&, std::uintptr_t&) noexcept {
    unavailable("try_no_bail_skater");
}
}

// Logging is linked for its real ordinary write path. These lifecycle paths
// remain forbidden in this constructed test; never start crash collection.
namespace dingosdk::crash_report {
StartResult start(const std::filesystem::path&) noexcept { unavailable("crash_report::start"); }
void stop() noexcept { unavailable("crash_report::stop"); }
void capture(EXCEPTION_POINTERS*) noexcept { unavailable("crash_report::capture"); }
}
namespace dingosdk::trace {
bool start() noexcept { unavailable("trace::start"); }
}