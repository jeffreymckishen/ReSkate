#pragma once
#include <cstdint>

namespace dingosdk::plugins::joystick::detail {
// A caller can publish a request after the worker sampled its clock. That request is recent;
// subtracting it from the older clock value would wrap and incorrectly discard active input.
constexpr bool request_is_recent(std::uint64_t now, std::uint64_t asked_at, std::uint64_t timeout_ms) noexcept {
    return asked_at >= now || now - asked_at <= timeout_ms;
}

// DirectInput's DI_OK is zero. A positive no-effect result does not establish the requested
// range or dead zone, so it cannot authorize the fixed-range conversion used by the reader.
constexpr bool axis_configuration_applied(std::int32_t range_result, std::int32_t dead_zone_result) noexcept {
    return range_result == 0 && dead_zone_result == 0;
}
}
