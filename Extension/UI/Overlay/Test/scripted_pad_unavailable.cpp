#include "Extension/Skater/actor_control.h"
#include "Extension/Skater/native_input_pulse_environment.h"
#include <cstdio>
#include <cstdlib>

// Link the real publication gate. A scripted-pad test must never acquire an
// actor, inspect the game, or ask its environment to approve native input.
namespace {
[[noreturn]] void unavailable() noexcept {
    std::fputs("Unexpected native input path in scripted-pad regression\n", stderr);
    std::abort();
}
}
namespace dingosdk::native_input_pulse::environment {
std::uint64_t now() noexcept { unavailable(); }
DWORD thread() noexcept { unavailable(); }
bool focused() noexcept { unavailable(); }
bool gameplay() noexcept { unavailable(); }
bool menu_closed() noexcept { unavailable(); }
bool interference_clear() noexcept { unavailable(); }
}
namespace dingosdk::actor_control_native {
bool acquire(std::uint64_t, std::uint64_t, Admission, Actor&, Reason&, Continuity) noexcept { unavailable(); }
bool inspect(std::uint64_t, std::uint64_t, const Actor&, Actor&, State&, Reason&, Observation&, bool) noexcept {
    unavailable();
}
bool enter(std::uint64_t, std::uint64_t, const Actor&, actor_control::Call&, Observation&) noexcept { unavailable(); }
bool retire(std::uint64_t, std::uint64_t, const Actor&, bool) noexcept { unavailable(); }
bool enable_clock(std::uint64_t, std::uint64_t, const Actor&, Reason&) noexcept { unavailable(); }
bool read_clock(std::uint64_t, std::uint64_t, const Actor&, Clock&) noexcept { unavailable(); }
bool disable_clock(std::uint64_t, std::uint64_t, const Actor&) noexcept { unavailable(); }
}
