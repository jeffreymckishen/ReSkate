// Compile the complete production overlay TU, with only its wall clock supplied
// by the constructed report fixture. No native hook or game is initialized.
#include <Windows.h>
#include <cstdint>

extern "C" ULONGLONG WINAPI input_grind_test_now() noexcept;
#ifndef DINGOSDK_GRIND_OVERLAY_SOURCE
#define DINGOSDK_GRIND_OVERLAY_SOURCE "Extension/UI/Overlay/input_capture.cpp"
#endif
#define GetTickCount64 input_grind_test_now
#include DINGOSDK_GRIND_OVERLAY_SOURCE
#undef GetTickCount64

extern "C" bool input_grind_test_on(bool turn) noexcept {
    return turn ? dingosdk::overlay::detail::grind_stick_turn().on.load() :
        dingosdk::overlay::detail::grind_stick_lean().on.load();
}
extern "C" std::uint64_t input_grind_test_until(bool turn) noexcept {
    return turn ? dingosdk::overlay::detail::grind_stick_turn().until.load() :
        dingosdk::overlay::detail::grind_stick_lean().until.load();
}
extern "C" std::uint64_t input_grind_test_duration() noexcept {
    return dingosdk::overlay::detail::stick_lease;
}
extern "C" bool input_grind_test_observer_inactive() noexcept {
    const auto& observer = dingosdk::bmx::board_handoff_trace::store;
    return !observer.enabled.load() && !observer.armed.load() && !observer.attempted &&
        !observer.ever_armed && !observer.count && observer.root.empty();
}
