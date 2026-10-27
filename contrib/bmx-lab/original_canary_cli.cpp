#include "original_canary_cli.h"
#include "original_canary.h"

#include <Windows.h>
#include <algorithm>
#include <array>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <vector>

namespace dingosdk::bmx::original_canary {
namespace {
namespace fs = std::filesystem;

void require(bool condition, const char* reason) {
    if (!condition) throw std::runtime_error(std::string("Original canary: ") + reason);
}
bool same_text(std::wstring_view left, std::wstring_view right) {
    return left.size() <= static_cast<std::size_t>(std::numeric_limits<int>::max()) &&
        right.size() <= static_cast<std::size_t>(std::numeric_limits<int>::max()) &&
        CompareStringOrdinal(left.data(), static_cast<int>(left.size()), right.data(),
            static_cast<int>(right.size()), TRUE) == CSTR_EQUAL;
}
bool contains(const fs::path& ancestor, const fs::path& path, bool exact = false) {
    auto child = path.begin();
    for (const auto& component : ancestor) {
        if (child == path.end()) return false;
        const bool matches = exact ? component.native() == child->native() : same_text(component.native(), child->native());
        if (!matches) return false;
        ++child;
    }
    return true;
}
void validate_component(std::wstring_view value) {
    require(!value.empty() && value.size() <= 255, "empty or oversized path component refused");
    require(value != L"." && value != L"..", "path traversal refused");
    require(value.back() != L'.' && value.back() != L' ', "trailing dot or space in path refused");
    for (const wchar_t ch : value)
        require(ch >= 32 && std::wstring_view(L"<>:\"|?*").find(ch) == std::wstring_view::npos,
            "alternate stream or invalid path character refused");
    auto stem = value.substr(0, value.find(L'.'));
    while (!stem.empty() && stem.back() == L' ') stem.remove_suffix(1);
    for (const auto name : {L"CON", L"PRN", L"AUX", L"NUL", L"CLOCK$", L"CONIN$", L"CONOUT$"})
        require(!same_text(stem, name), "Windows device path component refused");
    if (stem.size() == 4 && (same_text(stem.substr(0, 3), L"COM") || same_text(stem.substr(0, 3), L"LPT"))) {
        const auto suffix = stem[3];
        require(!((suffix >= L'1' && suffix <= L'9') || suffix == L'\u00b9' ||
            suffix == L'\u00b2' || suffix == L'\u00b3'), "Windows device path component refused");
    }
}
fs::path checked_path(const fs::path& input) {
    require(!input.empty() && input.native().size() <= 1024, "empty or oversized path refused");
    auto path = input;
    path.make_preferred();
    const auto drive = path.root_name().native();
    require(path.is_absolute() && drive.size() == 2 && drive[1] == L':' &&
        ((drive[0] >= L'A' && drive[0] <= L'Z') || (drive[0] >= L'a' && drive[0] <= L'z')) &&
        path.root_directory().native() == L"\\", "an absolute drive path is required; UNC and device paths are refused");
    for (const auto& component : path.relative_path()) validate_component(component.native());
    return path.lexically_normal();
}

class Handle {
public:
    explicit Handle(HANDLE value) : value_(value) {}
    ~Handle() { if (value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    Handle(Handle&& other) noexcept : value_(std::exchange(other.value_, INVALID_HANDLE_VALUE)) {}
    Handle& operator=(Handle&&) = delete;
    HANDLE get() const noexcept { return value_; }
private:
    HANDLE value_{INVALID_HANDLE_VALUE};
};

fs::path final_path(HANDLE handle) {
    const auto count = GetFinalPathNameByHandleW(handle, nullptr, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    require(count > 0 && count <= 32768, "cannot resolve an input handle's final path");
    std::wstring value(static_cast<std::size_t>(count) + 1, L'\0');
    const auto written = GetFinalPathNameByHandleW(handle, value.data(), static_cast<DWORD>(value.size()),
        FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    require(written > 0 && written < value.size(), "input handle's final path changed");
    value.resize(written);
    require(value.starts_with(L"\\\\?\\") && !value.starts_with(L"\\\\?\\UNC\\"),
        "input handle is outside an ordinary local drive");
    return checked_path(fs::path(value.substr(4)));
}
BY_HANDLE_FILE_INFORMATION checked_handle(HANDLE handle, const fs::path& expected, bool directory) {
    require(GetFileType(handle) == FILE_TYPE_DISK, "non-disk input refused");
    BY_HANDLE_FILE_INFORMATION info{};
    require(GetFileInformationByHandle(handle, &info) != FALSE, "cannot inspect input handle");
    require((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0, "reparse point refused");
    require(((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) == directory,
        directory ? "expected a directory" : "expected a regular input file");
    require(directory || info.nNumberOfLinks == 1, "hard-linked input refused");
    require(same_text(final_path(handle).native(), expected.native()), "final path differs from the checked path");
    return info;
}
bool missing(DWORD error) { return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND; }

struct InputHandles {
    // Keep every opened directory and leaf pinned through all parsing and
    // hashing. Excluding write/delete sharing prevents replacement during read.
    std::vector<Handle> held;

    void directories(const fs::path& directory, bool missing_suffix_allowed) {
        auto current = directory.root_path();
        const auto open = [&](const fs::path& path) {
            Handle handle(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
            if (handle.get() == INVALID_HANDLE_VALUE) {
                const auto error = GetLastError();
                require(missing_suffix_allowed && missing(error), "cannot open a checked directory");
                return false;
            }
            (void)checked_handle(handle.get(), path, true);
            held.push_back(std::move(handle));
            return true;
        };
        if (!open(current)) return;
        for (const auto& component : directory.relative_path()) {
            current /= component;
            if (!open(current)) return;
        }
    }

    std::string read_once(const fs::path& path, std::size_t maximum) {
        Handle handle(CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr));
        require(handle.get() != INVALID_HANDLE_VALUE, "cannot open an immutable input snapshot");
        const auto before = checked_handle(handle.get(), path, false);
        LARGE_INTEGER size{};
        require(GetFileSizeEx(handle.get(), &size) != FALSE && size.QuadPart >= 0 &&
            static_cast<unsigned long long>(size.QuadPart) <= maximum, "input exceeds its byte bound");
        std::string bytes(static_cast<std::size_t>(size.QuadPart), '\0');
        std::size_t offset{};
        while (offset < bytes.size()) {
            const auto count = static_cast<DWORD>(std::min<std::size_t>(bytes.size() - offset, 1024 * 1024));
            DWORD received{};
            require(ReadFile(handle.get(), bytes.data() + offset, count, &received, nullptr) != FALSE && received > 0,
                "cannot read the complete input snapshot");
            offset += received;
        }
        const auto after = checked_handle(handle.get(), path, false);
        require(before.dwVolumeSerialNumber == after.dwVolumeSerialNumber && before.nFileIndexHigh == after.nFileIndexHigh &&
            before.nFileIndexLow == after.nFileIndexLow && before.nFileSizeHigh == after.nFileSizeHigh &&
            before.nFileSizeLow == after.nFileSizeLow &&
            CompareFileTime(&before.ftLastWriteTime, &after.ftLastWriteTime) == 0,
            "input changed during its snapshot read");
        held.push_back(std::move(handle));
        return bytes;
    }
};

void require_new_output(const fs::path& output) {
    Handle handle(CreateFileW(output.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (handle.get() != INVALID_HANDLE_VALUE) throw std::runtime_error("Original canary: output already exists");
    require(missing(GetLastError()), "cannot establish that output is new");
}
}

std::filesystem::path lexical_output_path(const Request& request) {
    const auto package = checked_path(request.package), recipe = checked_path(request.recipe);
    const auto cache = checked_path(request.cache_root), output = checked_path(request.output);
    // Windows can enable case-sensitive directories. Require the configured
    // cache prefix's exact spelling; overlap refusal stays conservative.
    require(contains(cache, output, true) && !same_text(cache.native(), output.native()),
        "output must be a strict descendant of the fixed cache root");
    require(!contains(package, output) && !contains(output, package) && !contains(output, recipe) &&
        !contains(recipe, output), "output overlaps an input");
    return output;
}

PreflightResult preflight(const Request& request) {
    const auto output = lexical_output_path(request);
    const auto package = checked_path(request.package), recipe_path = checked_path(request.recipe);
    const auto cache = checked_path(request.cache_root);
    InputHandles handles;
    handles.directories(package, false);
    handles.directories(recipe_path.parent_path(), false);
    handles.directories(cache, true);
    handles.directories(output.parent_path(), true);
    require_new_output(output);
    const auto recipe = handles.read_once(recipe_path, maximum_recipe_bytes);
    validate_unqualified_recipe(recipe);
    const auto manifest = handles.read_once(package / "manifest.json", maximum_manifest_bytes);
    Payloads payloads;
    std::size_t payload_bytes{};
    for (const auto name : payload_names()) {
        const auto per_file = name == "left_pedal.obj" ? maximum_obj_bytes : maximum_payload_bytes;
        auto bytes = handles.read_once(package / std::string(name), std::min(per_file, maximum_total_payload_bytes - payload_bytes));
        require(bytes.size() <= maximum_total_payload_bytes - payload_bytes, "aggregate payload byte bound exceeded");
        payload_bytes += bytes.size();
        payloads.emplace(std::string(name), std::move(bytes));
    }
    const auto admitted = admit_original(manifest, payloads);
    require(admitted.manifest_sha256 == expected_manifest_sha256, "manifest is not the reviewed original package");
    return {output, payload_bytes, admitted.vertices.size(), admitted.triangles.size(), admitted.manifest_sha256};
}

int run(int argc, char* argv[], const std::filesystem::path& cache_root) {
    require(argc == 5 && argv != nullptr && argv[1] != nullptr && argv[2] != nullptr &&
        argv[3] != nullptr && argv[4] != nullptr && std::string_view(argv[1]) == "--original-canary",
        "usage: builder --original-canary ORIGINAL_PACKAGE RECIPE NEW_CACHE_OUTPUT (absolute paths)");
    const auto admitted = preflight({fs::path(argv[2]), fs::path(argv[3]), fs::path(argv[4]), cache_root});
    std::cerr << "Original left_pedal admitted (" << admitted.vertex_count << " vertices, " << admitted.triangle_count
        << " triangles; manifest " << admitted.manifest_sha256 << "). Native emission remains unqualified: "
        "reviewed stock template/reflection, mesh declaration, root LOD/material identities and native manifest pins "
        "are required. No cache directory, native pack or installation was written.\n";
    return 2;
}
}
