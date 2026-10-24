#pragma once
#include "owned_body.h"
#include <array>
#include <cstdint>

namespace dingosdk::body_sync_probe {
// Copied diagnostic facts. None is an actor/input lease, command receipt,
// native-consumption barrier or authorization to publish a follow target.
enum class Status : std::uint8_t { pending, observed, expired, invalidated };
struct Record {
    bool present{}, pending_before{}, pending_after{}, transform_matches{};
    std::uint32_t before_flags{}, after_flags{};
    std::array<float, 16> supplied{};
    owned_body::Vec com_position{}, origin{}, local_com{};
    // Public convention is Hamilton XYZW; native WXYZ never leaks as a guess.
    std::array<float, 4> rotation{}, local_rotation{};
    owned_body::Epoch epoch{};
};
struct Result {
    Status status{Status::pending};
    owned_body::Epoch armed_epoch{}, observed_epoch{};
    std::uint32_t observed_mask{}, rejected{}, dropped{};
    std::array<Record, 4> records{};
};
} // namespace dingosdk::body_sync_probe
