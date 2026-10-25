#include "Engine/Core/Hooks/hooks.h"
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
    std::fputs("Unrelated native/UI path reached by question ownership regression: ", stderr);
    std::fputs(name, stderr); std::fputc('\n', stderr);
    std::abort();
}
}
// Keep the aborting destructor call indirect for compiler return analysis.
namespace {
void (*volatile destructor_failure)(const char*) noexcept = &unavailable;
}
extern "C" unsigned question_unavailable_calls() noexcept { return unavailable_calls.load(); }
extern "C" bool question_unavailable_tls_clean() noexcept {
    return dingosdk::overlay::detail::overlay_input_access == 0;
}
namespace dingosdk::overlay::detail {
// In production this datum is defined by playstation_input.cpp. Do not bring the
// HID/device reader into a constructed test merely to supply unused TLS storage.
thread_local unsigned overlay_input_access = 0;



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

// These are hard failures, never successful hook substitutes. The real overlay
// install function is linked; reaching it must stop before any hook operation.
namespace dingosdk {
HookStatus WINAPI hook_initialize() { unavailable("hook_initialize"); }
HookStatus WINAPI hook_prepare(void*, void*, void**) { unavailable("hook_prepare"); }
HookStatus WINAPI hook_enable(void*) { unavailable("hook_enable"); }
HookStatus WINAPI hook_disable(void*) { unavailable("hook_disable"); }
HookStatus WINAPI hook_remove(void*) { unavailable("hook_remove"); }
HookStatus WINAPI hook_queue_enable(void*) { unavailable("hook_queue_enable"); }
HookStatus WINAPI hook_apply_queued() { unavailable("hook_apply_queued"); }
HookStatus WINAPI hook_shutdown() { unavailable("hook_shutdown"); }
const char* WINAPI hook_status_string(HookStatus) { unavailable("hook_status_string"); }
HookFailure hook_last_failure() noexcept { unavailable("hook_last_failure"); }
HookStatistics hook_statistics() { unavailable("hook_statistics"); }
HookBatch::HookBatch() noexcept { unavailable("HookBatch"); }
HookBatch::~HookBatch() { destructor_failure("~HookBatch"); }
}
