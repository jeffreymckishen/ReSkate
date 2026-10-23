#pragma once
#include <Windows.h>
#include <cstdint>

// Private platform predicates, linked separately so the actual service can be
// exercised with constructed facts without launching or driving the game.
namespace dingosdk::native_input_pulse::environment {
std::uint64_t now() noexcept;
DWORD thread() noexcept;
bool focused() noexcept;
bool gameplay() noexcept;
bool menu_closed() noexcept;
bool interference_clear() noexcept;
}
