#pragma once

#include <cstddef>
#include <filesystem>
#include <string>

namespace dingosdk::bmx::original_canary {
struct Request {
    std::filesystem::path package, recipe, output, cache_root;
};
struct PreflightResult {
    std::filesystem::path output;
    std::size_t payload_bytes{}, vertex_count{}, triangle_count{};
    std::string manifest_sha256;
};

// Pure path checks, exposed for synthetic tests. The cache root comes from the
// builder's compile-time configuration, never from a recipe or CLI argument.
std::filesystem::path lexical_output_path(const Request& request);

// Read-only Windows admission. Success is an admitted original input snapshot,
// not a native qualification or an output reservation. No directory is created.
PreflightResult preflight(const Request& request);

// This admission-first mode always refuses native emission with exit code 2
// after valid input. Invalid input throws to the historical builder's handler.
int run(int argc, char* argv[], const std::filesystem::path& cache_root);
}
