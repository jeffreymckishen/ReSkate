#pragma once

#include "asset_manhole_position.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <vector>

namespace dingosdk::trainer::asset_tools {
namespace manhole_position_test_detail {
inline void put_word(std::vector<std::byte>& bytes, std::size_t offset, std::uint16_t word) {
    if (offset > bytes.size() || bytes.size() - offset < 2)
        throw std::runtime_error("Synthetic position word exceeds its buffer");
    bytes[offset] = static_cast<std::byte>(word & 0xff);
    bytes[offset + 1] = static_cast<std::byte>(word >> 8);
}
inline std::size_t vertex_count(std::size_t section) {
    if (section > 1) throw std::runtime_error("Synthetic position section is invalid");
    return section == 0 ? 252 : 109;
}
inline void put_vertex(std::vector<std::byte>& bytes, std::size_t section, std::size_t index,
                       const std::array<std::uint16_t, 4>& words) {
    if (index >= vertex_count(section)) throw std::runtime_error("Synthetic position vertex is invalid");
    const std::size_t start = section == 0 ? 0 : 4032;
    for (std::size_t component = 0; component < 4; ++component)
        put_word(bytes, start + index * 8 + component * 2, words[component]);
}
inline void put_triangle(std::vector<std::byte>& bytes, std::size_t section, std::size_t triangle,
                         const std::array<std::uint16_t, 3>& indices) {
    if (section > 1 || triangle >= 180) throw std::runtime_error("Synthetic position triangle is invalid");
    const std::size_t start = section == 0 ? 4912 : 5992;
    for (std::size_t corner = 0; corner < 3; ++corner)
        put_word(bytes, start + triangle * 6 + corner * 2, indices[corner]);
}
inline std::vector<std::byte> zero_geometry() {
    // Only these independent literal windows are populated. Unused bytes are deliberately nonzero.
    std::vector<std::byte> bytes(7072, std::byte{0xab});
    for (std::size_t section = 0; section < 2; ++section) {
        for (std::size_t vertex = 0; vertex < vertex_count(section); ++vertex)
            put_vertex(bytes, section, vertex, {0, 0, 0, 0});
        for (std::size_t triangle = 0; triangle < 180; ++triangle)
            put_triangle(bytes, section, triangle, {0, 0, 0});
    }
    return bytes;
}
inline std::vector<std::byte> unit_triangle_geometry() {
    auto bytes = zero_geometry();
    for (std::size_t section = 0; section < 2; ++section) {
        // A=(0,0,0), B=(1,0,0), C=(0,1,0). Other records repeat A.
        put_vertex(bytes, section, 1, {0x3c00, 0, 0, 0});
        put_vertex(bytes, section, 2, {0, 0x3c00, 0, 0});
        for (std::size_t triangle = 0; triangle < 180; ++triangle)
            put_triangle(bytes, section, triangle, {0, 1, 2});
    }
    return bytes;
}
inline bool coverage_is(const ManholeCoverage& coverage, std::size_t total, std::size_t eligible) {
    return coverage.total == total && coverage.eligible == eligible && coverage.refused == total - eligible &&
        coverage.complete() == (total != 0 && total == eligible);
}
inline bool classes_sum(const HalfLaneSummary& lanes) {
    return lanes.total == lanes.positive_zero + lanes.negative_zero + lanes.subnormal + lanes.normal +
            lanes.positive_infinity + lanes.negative_infinity + lanes.nan &&
        lanes.finite == lanes.positive_zero + lanes.negative_zero + lanes.subnormal + lanes.normal &&
        lanes.refused == lanes.positive_infinity + lanes.negative_infinity + lanes.nan &&
        lanes.total == lanes.finite + lanes.refused;
}
} // namespace manhole_position_test_detail

// These are authored bytes and mathematical oracles, not a read of a game asset or format qualification.
inline int manhole_position_self_test() {
    using namespace manhole_position_test_detail;
    std::size_t cases{}, checks{}, failures{};
    const auto check = [&](bool accepted, std::string_view message) {
        ++checks;
        if (!accepted) { ++failures; std::cerr << "FAIL: " << message << '\n'; }
    };
    const auto run = [&](std::string_view name, const auto& test) {
        ++cases;
        try { test(); }
        catch (const std::exception& error) { ++failures; std::cerr << "FAIL: " << name << ": " << error.what() << '\n'; }
    };

    run("binary16 finite values and signed zero", [&] {
        struct Known { std::uint16_t bits; Binary16Class classification; double value; };
        constexpr std::array<Known, 12> known{{
            {0x0000, Binary16Class::positive_zero, 0.0}, {0x8000, Binary16Class::negative_zero, -0.0},
            {0x0001, Binary16Class::subnormal, 0x1p-24}, {0x8001, Binary16Class::subnormal, -0x1p-24},
            {0x03ff, Binary16Class::subnormal, 1023.0 / 16777216.0},
            {0x0400, Binary16Class::normal, 0x1p-14}, {0x3c00, Binary16Class::normal, 1.0},
            {0xbc00, Binary16Class::normal, -1.0}, {0x3e00, Binary16Class::normal, 1.5},
            {0x4000, Binary16Class::normal, 2.0}, {0x7bff, Binary16Class::normal, 65504.0},
            {0xfbff, Binary16Class::normal, -65504.0}}};
        for (const auto& value : known) {
            const auto decoded = inspect_binary16_word(value.bits);
            check(decoded.classification == value.classification, "known binary16 bits retain their exact class");
            check(decoded.finite_value && *decoded.finite_value == value.value, "known finite binary16 value is not normalized or clamped");
            if ((value.bits & 0x7fff) == 0)
                check(decoded.finite_value && std::signbit(*decoded.finite_value) == ((value.bits & 0x8000) != 0),
                      "the sign of an encoded zero survives finite decoding");
        }
    });
    run("binary16 infinities and NaNs have no finite replacement", [&] {
        constexpr std::array<std::pair<std::uint16_t, Binary16Class>, 5> known{{
            {std::uint16_t{0x7c00}, Binary16Class::positive_infinity}, {std::uint16_t{0xfc00}, Binary16Class::negative_infinity},
            {std::uint16_t{0x7e00}, Binary16Class::nan}, {std::uint16_t{0x7c01}, Binary16Class::nan}, {std::uint16_t{0xffff}, Binary16Class::nan}}};
        for (const auto& [bits, classification] : known) {
            const auto decoded = inspect_binary16_word(bits);
            check(decoded.classification == classification, "all special encodings retain their class and infinity sign");
            check(!decoded.finite_value, "nonfinite data has no sanitized numeric replacement");
        }
    });
    run("exact decoded size precedes every position aggregate", [&] {
        for (const std::size_t size : {0u, 7071u, 7073u, 14144u}) {
            const std::vector<std::byte> bytes(size, std::byte{0xff});
            const auto result = inspect_manhole_position_candidate(bytes);
            check(!result.inspected && result.refusal && std::string_view(result.refusal) == "decoded_size_mismatch",
                  "wrong decoded size refuses the entire hypothesis inspection");
            check(result.xyz_lanes.total == 0 && result.fourth_lanes.total == 0 && result.indices.total_count == 0 &&
                  result.sections[0].vertices.total == 0 && result.sections[1].vertices.total == 0 &&
                  !result.xyz_overlap.available && !result.triangle_overlap.available,
                  "size refusal produces no invented or partially read geometry statistics");
        }
    });
    run("last invalid index refuses before position decoding", [&] {
        for (std::size_t section = 0; section < 2; ++section) {
            auto bytes = unit_triangle_geometry();
            put_word(bytes, section == 0 ? 5990 : 7070, section == 0 ? std::uint16_t{252} : std::uint16_t{109});
            const auto result = inspect_manhole_position_candidate(bytes);
            check(!result.inspected && result.indices.inspected && !result.indices.consistent &&
                  result.indices.total_count == 1080 && result.indices.outside_count == 1,
                  "the final invalid index in either section blocks the position pass");
            check(result.xyz_lanes.total == 0 && result.fourth_lanes.total == 0 &&
                  result.sections[0].vertices.total == 0 && result.sections[1].triangles.coverage.total == 0 &&
                  !result.xyz_overlap.available && !result.triangle_overlap.available,
                  "all index validation finishes before any position statistic is populated");
        }
    });
    run("complete finite unit triangle fixture", [&] {
        const auto result = inspect_manhole_position_candidate(unit_triangle_geometry());
        check(result.inspected && result.refusal && std::string_view(result.refusal) == "none" &&
              result.indices.consistent && result.indices.total_count == 1080, "the authored complete fixture is inspected");
        check(result.xyz_lanes.total == 1083 && result.xyz_lanes.finite == 1083 && result.xyz_lanes.positive_zero == 1079 &&
              result.xyz_lanes.normal == 4 && classes_sum(result.xyz_lanes), "XYZ classification covers exactly three lanes per record");
        check(result.fourth_lanes.total == 361 && result.fourth_lanes.positive_zero == 361 &&
              classes_sum(result.fourth_lanes), "fourth lanes are classified separately from XYZ");
        for (std::size_t section = 0; section < 2; ++section) {
            const auto& value = result.sections[section];
            check(coverage_is(value.vertices, vertex_count(section), vertex_count(section)), "all section vertices have finite XYZ");
            check(value.aabb.available && value.aabb.minimum == std::array<double, 3>{0, 0, 0} &&
                  value.aabb.maximum == std::array<double, 3>{1, 1, 0}, "AABB comes from complete finite section coverage");
            check(coverage_is(value.triangles.coverage, 180, 180) && value.triangles.numerical_zero_count == 0 &&
                  value.triangles.extrema_available && value.triangles.minimum_cross_squared == 1 &&
                  value.triangles.maximum_cross_squared == 1, "unit right triangles have cross-length-squared one");
            for (const auto& component : value.components)
                check(component.total == vertex_count(section) && classes_sum(component), "every component retains its own complete lane denominator");
        }
        check(result.xyz_overlap.available && result.xyz_overlap.directional_matches == std::array<std::size_t, 2>{252, 109} &&
              result.xyz_overlap.multiset_matches == 109, "directional coverage and multiplicity are separate metrics");
        check(result.triangle_overlap.available && result.triangle_overlap.multiset_matches == 180,
              "identical oriented triangle multisets retain all duplicate occurrences");
    });
    run("disjoint class counts and finite extrema", [&] {
        auto bytes = zero_geometry();
        constexpr std::array<std::uint16_t, 8> words{0, 0x8000, 0x0001, 0x8001, 0x3c00, 0x7c00, 0xfc00, 0x7e01};
        for (std::size_t i = 0; i < words.size(); ++i) {
            put_word(bytes, (i / 3) * 8 + (i % 3) * 2, words[i]);
            put_word(bytes, i * 8 + 6, words[i]);
        }
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.inspected && classes_sum(result.xyz_lanes) && classes_sum(result.fourth_lanes), "special values do not abort complete raw lane classification");
        for (const auto* lanes : {&result.xyz_lanes, &result.fourth_lanes}) {
            check(lanes->negative_zero == 1 && lanes->subnormal == 2 && lanes->normal == 1 &&
                  lanes->positive_infinity == 1 && lanes->negative_infinity == 1 && lanes->nan == 1 && lanes->refused == 3,
                  "every special and finite class is disjoint and counted exactly once");
            check(lanes->extrema_available && lanes->minimum == -0x1p-24 && lanes->maximum == 1,
                  "finite-only lane extrema exclude infinities and NaNs without hiding their counts");
        }
        check(result.xyz_lanes.total == 1083 && result.xyz_lanes.finite == 1080 && result.xyz_lanes.positive_zero == 1076,
              "XYZ total and finite/refused coverage remain explicit");
        check(result.fourth_lanes.total == 361 && result.fourth_lanes.finite == 358 && result.fourth_lanes.positive_zero == 354,
              "fourth-lane total and finite/refused coverage remain explicit");
    });
    run("nonfinite fourth words never affect XYZ geometry", [&] {
        auto bytes = unit_triangle_geometry();
        constexpr std::array<std::uint16_t, 3> fourths{0x7e01, 0x7c00, 0xfc00};
        std::size_t ordinal{};
        for (std::size_t section = 0; section < 2; ++section)
            for (std::size_t vertex = 0; vertex < vertex_count(section); ++vertex)
                put_word(bytes, (section == 0 ? 0 : 4032) + vertex * 8 + 6, fourths[ordinal++ % 3]);
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.inspected && result.xyz_lanes.finite == 1083 && result.xyz_lanes.refused == 0, "fourth specials do not contaminate XYZ coverage");
        check(result.fourth_lanes.total == 361 && result.fourth_lanes.finite == 0 && result.fourth_lanes.refused == 361 &&
              result.fourth_lanes.nan == 121 && result.fourth_lanes.positive_infinity == 120 &&
              result.fourth_lanes.negative_infinity == 120 && !result.fourth_lanes.extrema_available,
              "all uninterpreted special fourth words remain visible without invented finite extrema");
        for (const auto& section : result.sections)
            check(section.vertices.complete() && section.aabb.available && section.triangles.coverage.complete() &&
                  section.triangles.numerical_zero_count == 0 && section.triangles.minimum_cross_squared == 1 &&
                  section.triangles.maximum_cross_squared == 1, "bounds and triangles ignore the unknown fourth lane");
        check(result.xyz_overlap.available && result.xyz_overlap.multiset_matches == 109 &&
              result.triangle_overlap.available && result.triangle_overlap.multiset_matches == 180,
              "record and triangle keys exclude the fourth word");
    });
    run("finite fourth values are not a scale or divisor", [&] {
        auto bytes = unit_triangle_geometry();
        put_word(bytes, 1 * 8 + 6, 0x7bff);
        put_word(bytes, 4032 + 2 * 8 + 6, 0xfbff);
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.fourth_lanes.finite == 361 && result.fourth_lanes.minimum == -65504 && result.fourth_lanes.maximum == 65504,
              "finite fourth-word extremes are reported as their own lane values");
        for (const auto& section : result.sections)
            check(section.aabb.available && section.aabb.maximum == std::array<double, 3>{1, 1, 0} &&
                  section.triangles.minimum_cross_squared == 1 && section.triangles.maximum_cross_squared == 1,
                  "no position division or scale is inferred from the fourth component");
        check(result.triangle_overlap.available && result.triangle_overlap.multiset_matches == 180,
              "different fourth values do not change the oriented XYZ triangle keys");
    });
    run("referenced nonfinite XYZ refuses every affected triangle", [&] {
        auto bytes = unit_triangle_geometry();
        put_word(bytes, 8, 0x7c00);
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.inspected && coverage_is(result.sections[0].vertices, 252, 251) && !result.sections[0].aabb.available,
              "an infinity cannot be replaced with a finite position or silently omitted from the AABB");
        check(coverage_is(result.sections[0].triangles.coverage, 180, 0) &&
              !result.sections[0].triangles.extrema_available && result.sections[0].triangles.numerical_zero_count == 0,
              "every triangle referencing the invalid vertex is refused without invented numerical data");
        check(result.sections[1].aabb.available && coverage_is(result.sections[1].triangles.coverage, 180, 180),
              "the untouched section retains independent complete geometry coverage");
        check(!result.xyz_overlap.available && !result.triangle_overlap.available &&
              coverage_is(result.xyz_overlap.coverage[0], 252, 251) && coverage_is(result.triangle_overlap.coverage[0], 180, 0),
              "unavailable overlaps retain the reasons in their coverage denominators");
    });
    run("partially eligible triangle ranges retain refused counts", [&] {
        auto bytes = unit_triangle_geometry();
        put_vertex(bytes, 0, 3, {0, 0, 0x3c00, 0});
        for (std::size_t triangle = 1; triangle < 180; ++triangle) put_triangle(bytes, 0, triangle, {0, 2, 3});
        put_word(bytes, 8, 0x7e00);
        const auto result = inspect_manhole_position_candidate(bytes);
        const auto& triangles = result.sections[0].triangles;
        check(coverage_is(triangles.coverage, 180, 179) && triangles.extrema_available &&
              triangles.minimum_cross_squared == 1 && triangles.maximum_cross_squared == 1 && triangles.numerical_zero_count == 0,
              "numerical ranges describe only the explicitly counted 179 eligible triangles");
        check(!result.sections[0].aabb.available && coverage_is(result.sections[0].vertices, 252, 251),
              "triangle eligibility does not invent complete vertex coverage");
        check(!result.triangle_overlap.available && coverage_is(result.triangle_overlap.coverage[0], 180, 179),
              "an incomplete triangle set cannot report a full overlap comparison");
    });
    run("unreferenced nonfinite vertex leaves triangle coverage intact", [&] {
        auto bytes = unit_triangle_geometry();
        put_word(bytes, 251 * 8, 0x7e01);
        const auto result = inspect_manhole_position_candidate(bytes);
        check(coverage_is(result.sections[0].vertices, 252, 251) && !result.sections[0].aabb.available &&
              !result.xyz_overlap.available && result.xyz_overlap.multiset_matches == 0,
              "an unused invalid XYZ record still withholds complete bounds and vertex overlap");
        check(coverage_is(result.sections[0].triangles.coverage, 180, 180) &&
              result.sections[0].triangles.extrema_available && result.sections[0].triangles.minimum_cross_squared == 1,
              "finite indexed triangles do not inherit an unrelated unreferenced vertex refusal");
        check(result.triangle_overlap.available && result.triangle_overlap.multiset_matches == 180 &&
              coverage_is(result.triangle_overlap.coverage[0], 180, 180) &&
              coverage_is(result.triangle_overlap.coverage[1], 180, 180), "triangle overlap has its own complete eligibility denominator");
    });
    run("all nonfinite XYZ retains complete raw classification", [&] {
        auto bytes = zero_geometry();
        for (std::size_t section = 0; section < 2; ++section)
            for (std::size_t vertex = 0; vertex < vertex_count(section); ++vertex)
                put_vertex(bytes, section, vertex, {0x7e00, 0x7c00, 0xfc00, 0});
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.inspected && result.xyz_lanes.total == 1083 && result.xyz_lanes.finite == 0 &&
              result.xyz_lanes.refused == 1083 && result.xyz_lanes.nan == 361 && result.xyz_lanes.positive_infinity == 361 &&
              result.xyz_lanes.negative_infinity == 361 && !result.xyz_lanes.extrema_available,
              "raw inspection completes without fabricating any finite XYZ values");
        check(result.fourth_lanes.total == 361 && result.fourth_lanes.finite == 361, "valid fourth words cannot rescue invalid XYZ");
        for (std::size_t section = 0; section < 2; ++section)
            check(coverage_is(result.sections[section].vertices, vertex_count(section), 0) &&
                  coverage_is(result.sections[section].triangles.coverage, 180, 0) && !result.sections[section].aabb.available &&
                  !result.sections[section].triangles.extrema_available, "all geometric aggregates explicitly refuse their complete populations");
        check(!result.xyz_overlap.available && !result.triangle_overlap.available, "no overlap is claimed without finite geometry coverage");
    });
    run("little endian words and component order", [&] {
        auto bytes = zero_geometry();
        put_vertex(bytes, 0, 0, {0x3c01, 0x4000, 0x4200, 0x4400});
        const auto first = inspect_manhole_position_candidate(bytes);
        check(first.sections[0].aabb.available && first.sections[0].aabb.maximum == std::array<double, 3>{1.0009765625, 2, 3},
              "asymmetric words and XYZ components are decoded in their authored order");
        check(first.fourth_lanes.maximum == 4, "the fourth component is not interchanged with Z");
        std::swap(bytes[0], bytes[1]);
        const auto swapped = inspect_manhole_position_candidate(bytes);
        check(swapped.sections[0].aabb.maximum == std::array<double, 3>{316.0 / 16777216.0, 2, 3} &&
              swapped.sections[0].components[0].subnormal == 1, "swapping the two bytes changes the numerical hypothesis rather than being normalized away");
    });
    run("the final position record is included", [&] {
        auto bytes = zero_geometry();
        put_vertex(bytes, 1, 108, {0xbc00, 0x3800, 0x4400, 0x7c00});
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.sections[1].aabb.available && result.sections[1].aabb.minimum == std::array<double, 3>{-1, 0, 0} &&
              result.sections[1].aabb.maximum == std::array<double, 3>{0, 0.5, 4}, "all XYZ lanes in the last stride8 record participate");
        check(result.fourth_lanes.positive_infinity == 1 && result.fourth_lanes.refused == 1 &&
              coverage_is(result.sections[1].vertices, 109, 109), "the final unknown fourth word remains independent of finite vertex coverage");
    });
    run("cyclic triangle rotations preserve winding", [&] {
        auto bytes = unit_triangle_geometry();
        for (std::size_t triangle = 0; triangle < 180; ++triangle) put_triangle(bytes, 1, triangle, {1, 2, 0});
        const auto rotated = inspect_manhole_position_candidate(bytes);
        check(rotated.triangle_overlap.available && rotated.triangle_overlap.multiset_matches == 180,
              "cyclic ABC and BCA rotations represent the same oriented triangle");
        for (std::size_t triangle = 0; triangle < 180; ++triangle) put_triangle(bytes, 1, triangle, {0, 2, 1});
        const auto reversed = inspect_manhole_position_candidate(bytes);
        check(reversed.triangle_overlap.available && reversed.triangle_overlap.multiset_matches == 0,
              "reversed winding cannot match through vertex sorting or reversed canonicalization");
        check(reversed.xyz_overlap.available && reversed.xyz_overlap.multiset_matches == 109 &&
              reversed.sections[1].triangles.minimum_cross_squared == 1, "a winding mismatch does not invent vertex or numerical-area mismatches");
    });
    run("triangle multiset intersection preserves duplicate multiplicity", [&] {
        auto bytes = unit_triangle_geometry();
        for (std::size_t section = 0; section < 2; ++section) put_vertex(bytes, section, 3, {0, 0, 0x3c00, 0});
        for (std::size_t triangle = 150; triangle < 180; ++triangle) put_triangle(bytes, 0, triangle, {0, 2, 3});
        for (std::size_t triangle = 0; triangle < 180; ++triangle)
            put_triangle(bytes, 1, triangle, triangle < 100 ? std::array<std::uint16_t, 3>{1, 2, 0} : std::array<std::uint16_t, 3>{2, 3, 0});
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.triangle_overlap.available && result.triangle_overlap.multiset_matches == 130,
              "min(150,100) ABC plus min(30,80) ACD gives 130, not set equality or all 180");
        for (const auto& section : result.sections)
            check(coverage_is(section.triangles.coverage, 180, 180) && section.triangles.numerical_zero_count == 0,
                  "duplicate triangle counts retain their full finite denominators");
    });
    run("directional XYZ membership is not multiset multiplicity", [&] {
        auto bytes = zero_geometry();
        for (std::size_t vertex = 0; vertex < 10; ++vertex) put_vertex(bytes, 0, vertex, {0x3c00, 0, 0, 0});
        for (std::size_t vertex = 0; vertex < 100; ++vertex) put_vertex(bytes, 1, vertex, {0x3c00, 0, 0, 0});
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.xyz_overlap.available && result.xyz_overlap.directional_matches == std::array<std::size_t, 2>{252, 109},
              "every record belongs to a key present in the other section even when duplicate populations differ");
        check(result.xyz_overlap.multiset_matches == 19, "min(242,9) zero records plus min(10,100) unit records gives 19");
        check(result.triangle_overlap.available && result.triangle_overlap.multiset_matches == 180 &&
              result.sections[0].triangles.numerical_zero_count == 180 && result.sections[1].triangles.numerical_zero_count == 180,
              "repeated-point triangles remain in overlap counts although their winding is uninformative");
    });
    run("signed zero remains distinct in bit-exact overlap", [&] {
        auto bytes = zero_geometry();
        for (std::size_t vertex = 0; vertex < 109; ++vertex) put_vertex(bytes, 1, vertex, {0x8000, 0, 0, 0});
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.xyz_lanes.negative_zero == 109 && result.xyz_lanes.finite == 1083,
              "negative zero is finite but retains its distinct raw classification");
        check(result.xyz_overlap.available && result.xyz_overlap.directional_matches == std::array<std::size_t, 2>{0, 0} &&
              result.xyz_overlap.multiset_matches == 0, "numeric zero equality cannot replace raw XYZ-key equality");
        check(result.triangle_overlap.available && result.triangle_overlap.multiset_matches == 0,
              "triangle keys also preserve the signs of zero words");
        for (const auto& section : result.sections)
            check(section.aabb.available && section.aabb.minimum == std::array<double, 3>{0, 0, 0} &&
                  section.aabb.maximum == std::array<double, 3>{0, 0, 0} && section.triangles.numerical_zero_count == 180,
                  "numerical geometry may agree while its raw bit keys differ");
    });
    run("numerical degeneracy includes repeated and collinear points", [&] {
        auto bytes = zero_geometry();
        for (std::size_t section = 0; section < 2; ++section) {
            put_vertex(bytes, section, 1, {0x3c00, 0, 0, 0});
            put_vertex(bytes, section, 2, {0x4000, 0, 0, 0});
            put_vertex(bytes, section, 3, {0, 0x3c00, 0, 0});
            for (std::size_t triangle = 0; triangle < 179; ++triangle)
                put_triangle(bytes, section, triangle, triangle < 90 ? std::array<std::uint16_t, 3>{0, 0, 1} : std::array<std::uint16_t, 3>{0, 1, 2});
            put_triangle(bytes, section, 179, {0, 1, 3});
        }
        const auto result = inspect_manhole_position_candidate(bytes);
        for (const auto& section : result.sections)
            check(coverage_is(section.triangles.coverage, 180, 180) && section.triangles.numerical_zero_count == 179 &&
                  section.triangles.minimum_cross_squared == 0 && section.triangles.maximum_cross_squared == 1,
                  "90 repeated plus 89 collinear triangles have zero numerical cross product, with one nonzero triangle retained");
        check(result.triangle_overlap.available && result.triangle_overlap.multiset_matches == 180,
              "degenerate triangles are not silently removed from oriented-multiset denominators");
    });
    run("subnormal-sized triangles are not discarded by an epsilon", [&] {
        auto bytes = unit_triangle_geometry();
        for (std::size_t section = 0; section < 2; ++section) {
            put_vertex(bytes, section, 1, {0x0001, 0, 0, 0});
            put_vertex(bytes, section, 2, {0, 0x0001, 0, 0});
        }
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.xyz_lanes.subnormal == 4 && result.xyz_lanes.finite == 1083, "smallest positive half values remain finite inputs");
        for (const auto& section : result.sections)
            check(coverage_is(section.triangles.coverage, 180, 180) && section.triangles.numerical_zero_count == 0 &&
                  section.triangles.extrema_available && section.triangles.minimum_cross_squared == 0x1p-96 &&
                  section.triangles.maximum_cross_squared == 0x1p-96,
                  "edges of two to minus24 give nonzero cross-length-squared two to minus96 without a guessed tolerance");
    });
    run("maximum finite coordinates remain finite in double geometry", [&] {
        auto bytes = unit_triangle_geometry();
        for (std::size_t section = 0; section < 2; ++section) {
            put_vertex(bytes, section, 0, {0xfbff, 0xfbff, 0, 0});
            put_vertex(bytes, section, 1, {0x7bff, 0xfbff, 0, 0});
            put_vertex(bytes, section, 2, {0xfbff, 0x7bff, 0, 0});
        }
        const auto result = inspect_manhole_position_candidate(bytes);
        for (const auto& section : result.sections) {
            check(section.aabb.available && section.aabb.minimum == std::array<double, 3>{-65504, -65504, 0} &&
                  section.aabb.maximum == std::array<double, 3>{65504, 65504, 0}, "finite extrema are neither display-clamped nor rescaled");
            check(coverage_is(section.triangles.coverage, 180, 180) && section.triangles.numerical_zero_count == 0 &&
                  std::isfinite(section.triangles.minimum_cross_squared) && section.triangles.minimum_cross_squared > 1e20 &&
                  section.triangles.minimum_cross_squared < 1e21 &&
                  section.triangles.minimum_cross_squared == section.triangles.maximum_cross_squared,
                  "the largest half-coordinate differences do not overflow the double cross-length calculation");
        }
    });
    run("UV basis and padding windows remain outside this hypothesis", [&] {
        auto bytes = unit_triangle_geometry();
        std::fill(bytes.begin() + 2016, bytes.begin() + 4032, std::byte{0xff});
        std::fill(bytes.begin() + 4904, bytes.begin() + 4912, std::byte{0xff});
        const auto result = inspect_manhole_position_candidate(bytes);
        check(result.inspected && result.xyz_lanes.finite == 1083 && result.xyz_lanes.normal == 4 &&
              result.fourth_lanes.positive_zero == 361, "uninterpreted streams and padding cannot add or change position lanes");
        for (const auto& section : result.sections)
            check(section.aabb.available && section.aabb.maximum == std::array<double, 3>{1, 1, 0} &&
                  section.triangles.numerical_zero_count == 0 && section.triangles.minimum_cross_squared == 1,
                  "the position-only pass never interprets the deferred four-byte streams");
        check(result.xyz_overlap.multiset_matches == 109 && result.triangle_overlap.multiset_matches == 180,
              "unrelated bytes do not alter the bit-exact XYZ and triangle comparison");
    });

    std::cout << "manhole_position: " << cases << " cases, " << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
} // namespace dingosdk::trainer::asset_tools
