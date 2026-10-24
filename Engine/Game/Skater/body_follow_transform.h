#pragma once
#include "Engine/Game/World/owned_body.h"
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>

// Plain target arithmetic only. Native actor/source admission belongs to the caller.
namespace dingosdk::body_follow_transform {
inline constexpr std::uint8_t no_failed_lane = 16;

// Fourth words are preserved data, outside the XYZ finiteness contract.
inline std::uint8_t first_nonfinite_xyz(const std::array<float, 16>& value) noexcept {
    for (std::size_t row = 0; row < 4; ++row)
        for (std::size_t component = 0; component < 3; ++component) {
            const auto lane = row * 4 + component;
            if (!std::isfinite(value[lane])) return static_cast<std::uint8_t>(lane);
        }
    return no_failed_lane;
}

inline bool unit(const owned_body::Quaternion& value) noexcept {
    double norm{};
    for (const auto component : value) {
        if (!std::isfinite(component)) return false;
        norm += static_cast<double>(component) * component;
    }
    return std::abs(norm - 1.0) <= .0001;
}
inline owned_body::Quaternion product(const owned_body::Quaternion& left, const owned_body::Quaternion& right) noexcept {
    return {left[3]*right[0] + left[0]*right[3] + left[1]*right[2] - left[2]*right[1],
        left[3]*right[1] - left[0]*right[2] + left[1]*right[3] + left[2]*right[0],
        left[3]*right[2] + left[0]*right[1] - left[1]*right[0] + left[2]*right[3],
        left[3]*right[3] - left[0]*right[0] - left[1]*right[1] - left[2]*right[2]};
}
inline owned_body::Vec rotate(const owned_body::Quaternion& q, const owned_body::Vec& value) noexcept {
    const owned_body::Vec twice{2*(q[1]*value[2] - q[2]*value[1]),
        2*(q[2]*value[0] - q[0]*value[2]), 2*(q[0]*value[1] - q[1]*value[0])};
    return {value[0] + q[3]*twice[0] + q[1]*twice[2] - q[2]*twice[1],
        value[1] + q[3]*twice[1] + q[2]*twice[0] - q[0]*twice[2],
        value[2] + q[3]*twice[2] + q[0]*twice[1] - q[1]*twice[0]};
}
inline bool transform(const owned_body::Sample& sample, const owned_body::Vec& offset_from_com,
    const owned_body::Quaternion& root_in_body, std::array<float, 16>& target) noexcept {
    if (!owned_body::finite(offset_from_com, 10) || !owned_body::finite(sample.position, 100000) ||
        !unit(sample.rotation) || !unit(root_in_body)) return false;
    const auto rotation = product(sample.rotation, root_in_body);
    if (!unit(rotation)) return false;
    // The point is COM-relative in BODY coordinates. Alignment affects the
    // root basis, not the COM-relative point. No authored-origin assumption.
    const auto offset = rotate(sample.rotation, offset_from_com);
    owned_body::Vec position{};
    for (unsigned axis = 0; axis < 3; ++axis) position[axis] = sample.position[axis] + offset[axis];
    if (!owned_body::finite(position, 100000)) return false;
    for (unsigned axis = 0; axis < 3; ++axis) {
        owned_body::Vec unit_axis{}; unit_axis[axis] = 1;
        const auto column = rotate(rotation, unit_axis);
        for (unsigned component = 0; component < 3; ++component) target[axis*4 + component] = column[component];
        target[12 + axis] = position[axis];
    }
    // The stock target's homogeneous/padding words 3,7,11,15 remain exact.
    return true;
}
}
