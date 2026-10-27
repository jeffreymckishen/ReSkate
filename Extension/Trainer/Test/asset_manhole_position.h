#pragma once

#include "asset_manhole_candidate.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace dingosdk::trainer::asset_tools {
enum class Binary16Class {
    positive_zero, negative_zero, subnormal, normal, positive_infinity, negative_infinity, nan
};
struct Binary16Value {
    Binary16Class classification{};
    // Nonfinite encodings have no numeric substitute that geometry could accidentally consume.
    std::optional<double> finite_value;
};

// This is an authored IEEE binary16 hypothesis, not a game format or fourth-lane interpretation.
inline Binary16Value inspect_binary16_word(std::uint16_t word) noexcept {
    const bool negative = (word & 0x8000U) != 0;
    const unsigned exponent = (word >> 10) & 31U;
    const unsigned fraction = word & 0x03ffU;
    if (exponent == 31) {
        if (fraction != 0) return {Binary16Class::nan, std::nullopt};
        return {negative ? Binary16Class::negative_infinity : Binary16Class::positive_infinity, std::nullopt};
    }
    if (exponent == 0 && fraction == 0)
        return {negative ? Binary16Class::negative_zero : Binary16Class::positive_zero, negative ? -0.0 : 0.0};
    const double magnitude = exponent == 0 ? std::ldexp(static_cast<double>(fraction), -24) :
        std::ldexp(static_cast<double>(1024U + fraction), static_cast<int>(exponent) - 25);
    return {exponent == 0 ? Binary16Class::subnormal : Binary16Class::normal, negative ? -magnitude : magnitude};
}

struct HalfLaneSummary {
    // Refused lanes are excluded only from finite extrema; fourth-lane refusals never reject XYZ.
    std::size_t total{}, finite{}, refused{};
    std::size_t positive_zero{}, negative_zero{}, subnormal{}, normal{}, positive_infinity{}, negative_infinity{}, nan{};
    bool extrema_available{};
    double minimum{}, maximum{};
};
struct ManholeCoverage {
    std::size_t total{}, eligible{}, refused{};
    // These captured populations are nonempty; an uninspected default is not complete coverage.
    bool complete() const noexcept { return total != 0 && eligible == total && refused == 0; }
};
struct ManholePositionAabb {
    bool available{};
    std::array<double, 3> minimum{}, maximum{};
};
struct ManholePositionTriangles {
    ManholeCoverage coverage;
    std::size_t numerical_zero_count{};
    bool extrema_available{};
    double minimum_cross_squared{}, maximum_cross_squared{};
};
struct ManholePositionSection {
    ManholeCoverage vertices;
    std::array<HalfLaneSummary, 4> components;
    ManholePositionAabb aabb;
    ManholePositionTriangles triangles;
};
struct ManholeXyzOverlap {
    std::array<ManholeCoverage, 2> coverage;
    bool available{};
    // Membership counts each input record; multiset intersection also respects duplicate multiplicity.
    std::array<std::size_t, 2> directional_matches{};
    std::size_t multiset_matches{};
};
struct ManholeTriangleOverlap {
    std::array<ManholeCoverage, 2> coverage;
    bool available{};
    std::size_t multiset_matches{};
};
struct ManholePositionInspection {
    bool inspected{};
    const char* refusal{"decoded_size_mismatch"};
    ManholeIndexInspection indices;
    HalfLaneSummary xyz_lanes, fourth_lanes;
    std::array<ManholePositionSection, 2> sections;
    ManholeXyzOverlap xyz_overlap;
    ManholeTriangleOverlap triangle_overlap;
};

namespace manhole_position_detail {
inline void observe(HalfLaneSummary& summary, const Binary16Value& value) noexcept {
    ++summary.total;
    switch (value.classification) {
    case Binary16Class::positive_zero: ++summary.positive_zero; break;
    case Binary16Class::negative_zero: ++summary.negative_zero; break;
    case Binary16Class::subnormal: ++summary.subnormal; break;
    case Binary16Class::normal: ++summary.normal; break;
    case Binary16Class::positive_infinity: ++summary.positive_infinity; break;
    case Binary16Class::negative_infinity: ++summary.negative_infinity; break;
    case Binary16Class::nan: ++summary.nan; break;
    }
    if (!value.finite_value) { ++summary.refused; return; }
    ++summary.finite;
    const double number = *value.finite_value;
    if (!summary.extrema_available) {
        summary.minimum = summary.maximum = number;
        summary.extrema_available = true;
    } else {
        if (number < summary.minimum) summary.minimum = number;
        if (number > summary.maximum) summary.maximum = number;
    }
}

// Every caller uses fixed offsets after the exact-size and complete index gates below.
inline std::uint16_t word_at(std::span<const std::byte> bytes, std::size_t offset) noexcept {
    return static_cast<std::uint16_t>(std::to_integer<unsigned int>(bytes[offset]) |
                                     (std::to_integer<unsigned int>(bytes[offset + 1]) << 8));
}
using XyzKey = std::array<std::uint16_t, 3>;
using TriangleKey = std::array<XyzKey, 3>;
struct Position {
    XyzKey key;
    std::array<double, 3> xyz;
    bool finite{};
};

inline TriangleKey cyclic_key(const XyzKey& a, const XyzKey& b, const XyzKey& c) noexcept {
    TriangleKey best{a, b, c};
    const TriangleKey second{b, c, a}, third{c, a, b};
    if (second < best) best = second;
    if (third < best) best = third;
    return best;
}

template <class Key>
inline std::size_t multiset_matches(std::span<const Key> left, std::span<const Key> right) noexcept {
    std::size_t first{}, second{}, matches{};
    while (first < left.size() && second < right.size()) {
        if (left[first] < right[second]) ++first;
        else if (right[second] < left[first]) ++second;
        else { ++matches; ++first; ++second; }
    }
    return matches;
}
} // namespace manhole_position_detail

// Return aggregates only. The eight-byte records remain a hypothesis; no vertex or resource is emitted.
inline ManholePositionInspection inspect_manhole_position_candidate(std::span<const std::byte> decoded) noexcept {
    using namespace manhole_position_detail;
    ManholePositionInspection result;
    result.indices = inspect_manhole_candidate_indices(decoded);
    if (!result.indices.inspected || !result.indices.consistent) {
        result.refusal = result.indices.refusal;
        return result;
    }

    constexpr std::array<std::size_t, 2> vertex_starts{0, 4032}, vertex_counts{252, 109}, index_starts{4912, 5992};
    constexpr std::size_t triangles_per_section = 180;
    std::array<std::array<Position, 252>, 2> positions{};
    std::array<std::array<TriangleKey, triangles_per_section>, 2> triangle_keys{};
    for (std::size_t section = 0; section < 2; ++section) {
        auto& output = result.sections[section];
        output.vertices.total = vertex_counts[section];
        for (std::size_t vertex = 0; vertex < vertex_counts[section]; ++vertex) {
            auto& position = positions[section][vertex];
            position.finite = true;
            for (std::size_t component = 0; component < 4; ++component) {
                const auto bits = word_at(decoded, vertex_starts[section] + vertex * 8 + component * 2);
                const auto value = inspect_binary16_word(bits);
                observe(output.components[component], value);
                if (component == 3) {
                    observe(result.fourth_lanes, value);
                    continue;
                }
                observe(result.xyz_lanes, value);
                position.key[component] = bits;
                if (value.finite_value) position.xyz[component] = *value.finite_value;
                else position.finite = false;
            }
            if (position.finite) ++output.vertices.eligible;
            else ++output.vertices.refused;
        }
        if (output.vertices.complete()) {
            output.aabb.available = true;
            output.aabb.minimum = output.aabb.maximum = positions[section][0].xyz;
            for (std::size_t vertex = 1; vertex < vertex_counts[section]; ++vertex) {
                for (std::size_t component = 0; component < 3; ++component) {
                    const double value = positions[section][vertex].xyz[component];
                    if (value < output.aabb.minimum[component]) output.aabb.minimum[component] = value;
                    if (value > output.aabb.maximum[component]) output.aabb.maximum[component] = value;
                }
            }
        }

        auto& triangles = output.triangles;
        triangles.coverage.total = triangles_per_section;
        for (std::size_t triangle = 0; triangle < triangles_per_section; ++triangle) {
            const std::size_t index_offset = index_starts[section] + triangle * 6;
            const auto& a = positions[section][word_at(decoded, index_offset)];
            const auto& b = positions[section][word_at(decoded, index_offset + 2)];
            const auto& c = positions[section][word_at(decoded, index_offset + 4)];
            if (!a.finite || !b.finite || !c.finite) { ++triangles.coverage.refused; continue; }
            triangle_keys[section][triangles.coverage.eligible] = cyclic_key(a.key, b.key, c.key);
            ++triangles.coverage.eligible;
            std::array<double, 3> ab{}, ac{};
            for (std::size_t component = 0; component < 3; ++component) {
                ab[component] = b.xyz[component] - a.xyz[component];
                ac[component] = c.xyz[component] - a.xyz[component];
            }
            const std::array<double, 3> cross{
                ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0]};
            // This reports the computed double cross, not exact mathematical collinearity or an epsilon test.
            if (cross[0] == 0.0 && cross[1] == 0.0 && cross[2] == 0.0) ++triangles.numerical_zero_count;
            const double squared = cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2];
            // Finite binary16 inputs bound these operations far inside double's finite range.
            if (!triangles.extrema_available) {
                triangles.minimum_cross_squared = triangles.maximum_cross_squared = squared;
                triangles.extrema_available = true;
            } else {
                if (squared < triangles.minimum_cross_squared) triangles.minimum_cross_squared = squared;
                if (squared > triangles.maximum_cross_squared) triangles.maximum_cross_squared = squared;
            }
        }
        result.xyz_overlap.coverage[section] = output.vertices;
        result.triangle_overlap.coverage[section] = triangles.coverage;
    }

    if (result.xyz_overlap.coverage[0].complete() && result.xyz_overlap.coverage[1].complete()) {
        auto& overlap = result.xyz_overlap;
        std::array<std::array<XyzKey, 252>, 2> keys{};
        for (std::size_t section = 0; section < 2; ++section) {
            for (std::size_t vertex = 0; vertex < vertex_counts[section]; ++vertex) keys[section][vertex] = positions[section][vertex].key;
            std::sort(keys[section].begin(), keys[section].begin() + static_cast<std::ptrdiff_t>(vertex_counts[section]));
        }
        // Unsigned raw-word ordering preserves signed-zero differences; the fourth word is absent from keys.
        for (std::size_t section = 0; section < 2; ++section) {
            const std::size_t other = 1 - section;
            const auto end = keys[other].begin() + static_cast<std::ptrdiff_t>(vertex_counts[other]);
            for (std::size_t vertex = 0; vertex < vertex_counts[section]; ++vertex)
                if (std::binary_search(keys[other].begin(), end, positions[section][vertex].key)) ++overlap.directional_matches[section];
        }
        overlap.multiset_matches = multiset_matches<XyzKey>(
            {keys[0].data(), vertex_counts[0]}, {keys[1].data(), vertex_counts[1]});
        overlap.available = true;
    }
    // Invalid unreferenced vertices do not withhold overlap for an otherwise fully finite triangle population.
    if (result.triangle_overlap.coverage[0].complete() && result.triangle_overlap.coverage[1].complete()) {
        std::sort(triangle_keys[0].begin(), triangle_keys[0].end());
        std::sort(triangle_keys[1].begin(), triangle_keys[1].end());
        result.triangle_overlap.multiset_matches = multiset_matches<TriangleKey>(triangle_keys[0], triangle_keys[1]);
        result.triangle_overlap.available = true;
    }
    // Cyclic canonicalization preserves winding. Degenerate triangles are included, but their winding is uninformative.
    result.inspected = true;
    result.refusal = "none";
    return result;
}
} // namespace dingosdk::trainer::asset_tools
