#pragma once

#include "asset_chunk_locator.h"
#include "Engine/Resource/mesh_set.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <string_view>

namespace dingosdk::trainer::asset_tools {
inline constexpr std::string_view manhole_toc_name = "Win32/levels/game/bam_levelroot/bam_levelroot.toc";
inline constexpr std::string_view manhole_bundle_name = "win32/levels/game/bam_levelroot/bam_levelroot";
inline constexpr std::string_view manhole_resource_name =
    "world/props/common/roads/cmn_prp_manhole_01/cmn_prp_manhole_03_mesh";
inline constexpr std::size_t manhole_encoded_limit = 4096, manhole_decoded_size = 7072,
    manhole_oodle_buffer_limit = 269216, manhole_resource_decoded_size = 3616;
inline constexpr std::array<std::byte, 16> manhole_geometry_identity{
    std::byte{0x01}, std::byte{0x56}, std::byte{0xd8}, std::byte{0x0f},
    std::byte{0x72}, std::byte{0x25}, std::byte{0x05}, std::byte{0x48},
    std::byte{0xe4}, std::byte{0xd4}, std::byte{0x73}, std::byte{0x02},
    std::byte{0xb9}, std::byte{0xfe}, std::byte{0x31}, std::byte{0x79}};

struct ManholeAdmission {
    bool accepted{};
    const char* refusal{};
};
struct ManholeWindow {
    std::string_view name;
    std::size_t begin{}, end{};
};
// These windows are an authored hypothesis from the captured declarations, not decoded semantics.
inline constexpr std::array<ManholeWindow, 7> manhole_windows{{
    {"section0_stream0", 0, 2016}, {"section0_stream1", 2016, 3024},
    {"section0_stream2", 3024, 4032}, {"section1_stream0", 4032, 4904},
    {"vertex_padding", 4904, 4912}, {"section0_indices", 4912, 5992},
    {"section1_indices", 5992, 7072}}};

namespace manhole_candidate_detail {
inline constexpr std::array<std::byte, 20> resource_sha1{
    std::byte{0x86}, std::byte{0x22}, std::byte{0x27}, std::byte{0xa0},
    std::byte{0x28}, std::byte{0x74}, std::byte{0xf2}, std::byte{0xbd},
    std::byte{0xa2}, std::byte{0x32}, std::byte{0xf9}, std::byte{0x78},
    std::byte{0x49}, std::byte{0x24}, std::byte{0x12}, std::byte{0x14},
    std::byte{0xe4}, std::byte{0x9e}, std::byte{0x46}, std::byte{0xf3}};
inline constexpr std::array<frostbite::MeshElementObservation, 3> first_elements{{
    {1, 8, 0, 0}, {33, 6, 0, 1}, {52, 13, 0, 2}}};
inline constexpr std::array<frostbite::MeshStreamObservation, 3> first_streams{{{8, 0}, {4, 0}, {4, 0}}};
inline constexpr std::array<frostbite::MeshElementObservation, 1> second_elements{{{1, 8, 0, 0}}};
inline constexpr std::array<frostbite::MeshStreamObservation, 1> second_streams{{{8, 0}}};

inline bool section_matches(const frostbite::MeshSectionObservation& section, std::size_t resource_offset,
                            std::uint32_t first_index, std::uint32_t vertex_start, std::uint32_t vertex_count,
                            std::span<const frostbite::MeshElementObservation> elements,
                            std::span<const frostbite::MeshStreamObservation> streams) noexcept {
    if (section.resource_offset != resource_offset || section.primitive_raw != 3 || section.triangle_count_raw != 180 ||
        section.first_index_raw != first_index || section.vertex_start_raw != vertex_start ||
        section.vertex_count_raw != vertex_count || !section.declarations_observed ||
        section.element_count_raw != elements.size() || section.stream_count_raw != streams.size() ||
        section.elements.size() != elements.size() || section.streams.size() != streams.size()) return false;
    for (std::size_t i = 0; i < elements.size(); ++i) {
        const auto& actual = section.elements[i];
        const auto& expected = elements[i];
        if (actual.usage_raw != expected.usage_raw || actual.format_raw != expected.format_raw ||
            actual.offset_raw != expected.offset_raw || actual.stream_raw != expected.stream_raw) return false;
    }
    for (std::size_t i = 0; i < streams.size(); ++i)
        if (section.streams[i].stride_raw != streams[i].stride_raw ||
            section.streams[i].classification_raw != streams[i].classification_raw) return false;
    return true;
}
} // namespace manhole_candidate_detail

// Matching the manifest hash binds metadata only; no payload digest is authenticated here.
inline ManholeAdmission manhole_resource_gate(const frostbite::BundleAsset& resource) noexcept {
    if (resource.kind != frostbite::AssetKind::resource || std::string_view{resource.name} != manhole_resource_name ||
        resource.resourceType != 0x49b156d4 || resource.resourceId != 0x08b4cc352279fb17ULL ||
        resource.originalSize != manhole_resource_decoded_size || resource.sha1.bytes != manhole_candidate_detail::resource_sha1)
        return {false, "resource_metadata_changed"};
    return {true, "none"};
}

// Admission authorizes only this inspection hypothesis. It does not make kind 0 supported or select a native layout.
inline ManholeAdmission manhole_candidate_gate(const frostbite::MeshLodMetadata& mesh,
                                               const ChunkLocationLookup& lookup) noexcept {
    using namespace manhole_candidate_detail;
    constexpr std::array<std::uint32_t, 4> header{192, 176, 384, 0};
    if (mesh.header != header || mesh.skinned || mesh.lod_kind_supported || mesh.complete || mesh.lod_kind != 0 ||
        mesh.lod_count != 3 || mesh.lod_index != 0 || mesh.lod_offset != 208 || !mesh.static_common_offsets)
        return {false, "lod_observation_changed"};
    const auto& common = *mesh.static_common_offsets;
    if (common.section_count_raw != 2 || common.section_pointer_raw != 720 || common.index_format_raw != 33 ||
        common.index_bytes_raw != 2160 || common.vertex_bytes_raw != 4912 || common.geometry_identity_raw != manhole_geometry_identity)
        return {false, "common_observation_changed"};
    if (mesh.static_section_candidates.size() != 2) return {false, "section_candidates_changed"};
    const frostbite::MeshSectionCandidateObservation* candidate{};
    std::size_t observed_384{}, observed_416{};
    for (const auto& observed : mesh.static_section_candidates) {
        if (observed.stride == 384) { ++observed_384; candidate = &observed; }
        if (observed.stride == 416) ++observed_416;
    }
    // Keep the alternate raw attempt intact; this gate does not infer its meaning or mutate either observation.
    if (observed_384 != 1 || observed_416 != 1 || !candidate) return {false, "section_candidates_changed"};
    if (!candidate->table_pointer_resolved || !candidate->table_span_valid || !candidate->observation_complete ||
        candidate->table_offset != 736 || candidate->span_bytes != 768 || candidate->sections.size() != 2 ||
        candidate->diagnostic_count != 0 || !candidate->diagnostics.empty()) return {false, "section_table_changed"};
    if (!section_matches(candidate->sections[0], 736, 0, 0, 252, first_elements, first_streams) ||
        !section_matches(candidate->sections[1], 1120, 540, 4032, 109, second_elements, second_streams))
        return {false, "section_observation_changed"};
    if (!lookup.resolved || lookup.zero_identity || lookup.duplicate || lookup.conflict || lookup.removed_matches != 0 ||
        lookup.bundle_matches != 0 || lookup.toc_matches != 1 || lookup.retained != 1 || lookup.omitted != 0 ||
        !lookup.refusal || std::string_view{lookup.refusal} != "none") return {false, "location_not_unique"};
    const auto& location = lookup.observations[0];
    if (location.scope != ChunkLocationScope::toc || location.index != 9977 || location.removed ||
        !location.payload_present || !location.range_valid || location.payload.location.patch ||
        location.payload.location.installChunk != 2016875820 || location.payload.location.archive != 27 ||
        location.payload.offset != 472228264 || location.payload.size != 2820 || location.range_end != 472231084)
        return {false, "location_metadata_changed"};
    return {true, "none"};
}

struct ManholeIndexSection {
    std::size_t count{}, outside_count{};
    std::uint16_t minimum{}, maximum{};
};
struct ManholeBadIndex {
    std::size_t section{}, index{}, byte_offset{};
    std::uint16_t value{};
};
struct ManholeIndexInspection {
    bool inspected{}, consistent{};
    const char* refusal{"decoded_size_mismatch"};
    std::size_t total_count{}, outside_count{}, retained{}, omitted{};
    std::array<ManholeIndexSection, 2> sections{};
    std::array<ManholeBadIndex, 8> bad_indices{};
};

// Inspect only the two index windows as candidate uint16-LE values. Vertex bytes remain uninterpreted.
inline ManholeIndexInspection inspect_manhole_candidate_indices(std::span<const std::byte> decoded) noexcept {
    ManholeIndexInspection result;
    if (decoded.size() != manhole_decoded_size) return result;
    constexpr std::array<std::size_t, 2> starts{4912, 5992};
    constexpr std::array<std::uint16_t, 2> vertex_limits{252, 109};
    constexpr std::size_t indices_per_section = 540;
    for (std::size_t section = 0; section < starts.size(); ++section) {
        auto& summary = result.sections[section];
        summary.minimum = std::numeric_limits<std::uint16_t>::max();
        for (std::size_t index = 0; index < indices_per_section; ++index) {
            const auto offset = starts[section] + index * 2;
            const auto value = static_cast<std::uint16_t>(std::to_integer<unsigned int>(decoded[offset]) |
                                                        (std::to_integer<unsigned int>(decoded[offset + 1]) << 8));
            ++summary.count;
            ++result.total_count;
            if (value < summary.minimum) summary.minimum = value;
            if (value > summary.maximum) summary.maximum = value;
            if (value < vertex_limits[section]) continue;
            ++summary.outside_count;
            ++result.outside_count;
            if (result.retained < result.bad_indices.size())
                result.bad_indices[result.retained++] = {section, index, offset, value};
            else ++result.omitted;
        }
    }
    result.inspected = true;
    result.consistent = result.outside_count == 0;
    result.refusal = result.consistent ? "none" : "candidate_index_out_of_range";
    return result;
}
} // namespace dingosdk::trainer::asset_tools
