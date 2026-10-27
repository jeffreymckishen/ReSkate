#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace dingosdk::bmx::original_canary {
inline constexpr std::size_t maximum_manifest_bytes = 1024 * 1024;
inline constexpr std::size_t maximum_payload_bytes = 8 * 1024 * 1024;
inline constexpr std::size_t maximum_total_payload_bytes = 64 * 1024 * 1024;
inline constexpr std::size_t maximum_obj_bytes = 128 * 1024;
inline constexpr std::size_t maximum_recipe_bytes = 4096;
inline constexpr std::string_view expected_manifest_sha256 =
    "882fb6ba4e3f01d3ea08cfba3c231d37c53eca1a0a0275e193d93dd8835183d9";

using Payloads = std::map<std::string, std::string>;
struct Vertex {
    std::array<double, 3> position{}, normal{};
    std::array<double, 2> uv{};
};
struct Component {
    std::string label, material;
    std::size_t first_vertex{}, vertex_count{}, first_triangle{}, triangle_count{};
};
struct Bounds { std::array<double, 3> min{}, max{}; };
struct AdmittedPart {
    std::vector<Vertex> vertices;
    std::vector<std::array<std::uint32_t, 3>> triangles;
    std::vector<Component> components;
    Bounds bounds;
    std::string manifest_sha256;
};

// Only these fixed leaves belong to the original package. This library never
// opens paths; callers must supply one bounded, immutable byte snapshot.
const std::array<std::string_view, 13>& payload_names();
std::string sha256(std::string_view bytes);
// Structural admission is also a synthetic-test seam. The CLI must compare
// manifest_sha256 with the reviewed recipe pin; self-consistent hashes are not provenance.
AdmittedPart admit_original(std::string_view manifest, const Payloads& payloads);

// Validates metadata only. Success never authorizes native packing or install:
// native identities must remain null and the original manifest pin must match.
void validate_unqualified_recipe(std::string_view recipe);
}
