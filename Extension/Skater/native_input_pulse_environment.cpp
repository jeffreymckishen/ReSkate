#include "native_input_pulse_environment.h"
#include "Extension/UI/Overlay/overlay.h"
#include "Extension/UI/Overlay/input_capture.h"
#include "Extension/UI/NativeMenu/throwdown_menu.h"

namespace dingosdk::native_input_pulse::environment {
std::uint64_t now() noexcept { return GetTickCount64(); }
DWORD thread() noexcept { return GetCurrentThreadId(); }
bool focused() noexcept {
    DWORD process{};
    const auto window = GetForegroundWindow();
    return window && GetWindowThreadProcessId(window, &process) && process == GetCurrentProcessId();
}
bool gameplay() noexcept { return multiplayer::native_throwdown_gameplay_input_allowed(); }
bool menu_closed() noexcept { return !overlay::interface_open(); }
bool interference_clear() noexcept { return overlay::detail::input_pulse_available(); }
}
