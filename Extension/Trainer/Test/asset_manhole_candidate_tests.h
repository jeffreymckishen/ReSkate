#pragma once

#include "asset_manhole_candidate.h"
#include "Engine/Vfs/game_bundles.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <span>
#include <stdexcept>
#include <string_view>
#include <utility>
#ifdef _WIN32
#include <Windows.h>
#endif

namespace dingosdk::trainer::asset_tools {
namespace bounded_reader_test_detail {
namespace fs = std::filesystem;
namespace fb = frostbite;
namespace db = native_db;
constexpr std::uint32_t fixture_install = 17;
inline constexpr fb::CasIdentifier fixture_location{false, fixture_install, 1};

inline db::Node container(unsigned type, std::string name, std::vector<db::Node> children) {
    db::Node node;
    node.type = type;
    node.named = !name.empty();
    node.name = std::move(name);
    node.terminated = true;
    node.children = std::move(children);
    return node;
}

inline db::Node make_layout(const std::vector<std::pair<std::uint32_t, std::string>>& entries = {{fixture_install, "pkg"}},
                            bool inferred = false) {
    std::vector<db::Node> rows;
    for (const auto& [id, directory] : entries) {
        db::Node index;
        index.type = 8;
        index.named = true;
        index.name = "persistentIndex";
        for (unsigned shift = 0; shift < 32; shift += 8)
            index.owned.push_back(static_cast<unsigned char>((id >> shift) & 0xff));
        rows.push_back(container(2, "", {db::make_named_record("name", directory).children.front(), std::move(index)}));
    }
    auto result = container(2, "", {container(2, "installManifest", {container(1, "installChunks", std::move(rows))})});
    if (inferred) {
        db::Node files;
        files.type = 19;
        files.named = true;
        files.name = "layeredInstallChunkFiles";
        files.owned = {1, 0, static_cast<unsigned char>(fixture_install), 0, 0, 0, 0, 0};
        result.children.push_back(std::move(files));
    }
    return result;
}

#ifdef _WIN32
class Handle {
public:
    explicit Handle(HANDLE value) : value_(value) {}
    ~Handle() { if (value_ && value_ != INVALID_HANDLE_VALUE) CloseHandle(value_); }
    Handle(const Handle&) = delete;
    Handle& operator=(const Handle&) = delete;
    HANDLE get() const noexcept { return value_; }
private:
    HANDLE value_;
};

inline BY_HANDLE_FILE_INFORMATION file_information(const fs::path& path) {
    Handle file(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
    BY_HANDLE_FILE_INFORMATION information{};
    if (file.get() == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(file.get(), &information))
        throw std::runtime_error("Synthetic fixture identity query failed");
    return information;
}

inline std::uint64_t words(std::uint32_t high, std::uint32_t low) {
    return (std::uint64_t{high} << 32) | low;
}

class Fixture {
public:
    fs::path root, game_root, data_root;
    db::Node layout;
    std::vector<std::byte> bytes;

    explicit Fixture(db::Node source = make_layout()) : layout(std::move(source)) {
        temporary_parent_ = fs::canonical(fs::temp_directory_path());
        static std::atomic<std::uint64_t> sequence{};
        const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
        for (unsigned attempt = 0; attempt < 128; ++attempt) {
            const auto name = "reskate-bounded-reader-" + std::to_string(GetCurrentProcessId()) + "-" +
                std::to_string(stamp) + "-" + std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
            const auto candidate = temporary_parent_ / name;
            if (fs::create_directory(candidate)) { root = candidate; break; }
        }
        if (root.empty()) throw std::runtime_error("Could not create a unique owned synthetic fixture");
        try {
            game_root = root / "game";
            data_root = game_root / "Data";
            for (unsigned value = 0; value < 16; ++value) bytes.push_back(static_cast<std::byte>(value));
            write(archive(), bytes);
            const auto tree = db::write(layout);
            std::vector<std::byte> envelope(db::envelope_size + tree.size());
            std::memcpy(envelope.data(), db::magic, sizeof(db::magic));
            std::memcpy(envelope.data() + db::envelope_size, tree.data(), tree.size());
            write(data_root / "layout.toc", envelope);
        } catch (...) {
            cleanup();
            throw;
        }
    }
    ~Fixture() { cleanup(); }
    Fixture(const Fixture&) = delete;
    Fixture& operator=(const Fixture&) = delete;

    fs::path archive() const { return data_root / "Win32" / "pkg" / "cas_01.cas"; }

    void require_owned(const fs::path& path) const {
        const auto absolute = fs::absolute(path).lexically_normal();
        const auto owned = root.lexically_normal();
        auto value = absolute.begin();
        for (auto part = owned.begin(); part != owned.end(); ++part, ++value)
            if (value == absolute.end() || *value != *part) throw std::runtime_error("Synthetic fixture path escaped its owner");
        if (value == absolute.end()) throw std::runtime_error("Synthetic fixture operation targeted its root");
    }

    void write(const fs::path& path, std::span<const std::byte> content) const {
        require_owned(path);
        fs::create_directories(path.parent_path());
        std::ofstream output(path, std::ios::binary | std::ios::trunc);
        if (!output || !output.write(reinterpret_cast<const char*>(content.data()), static_cast<std::streamsize>(content.size())))
            throw std::runtime_error("Synthetic fixture write failed");
    }

    bool directory_link(const fs::path& link, const fs::path& target, DWORD& failure) {
        require_owned(link);
        require_owned(target);
        // The link and its target are both owned. Only the link crosses the reader's Data boundary.
        constexpr DWORD allow_unprivileged_create = 0x2;
        if (!CreateSymbolicLinkW(link.c_str(), target.c_str(), SYMBOLIC_LINK_FLAG_DIRECTORY | allow_unprivileged_create)) {
            failure = GetLastError();
            return false;
        }
        links_.push_back(link);
        return true;
    }

private:
    fs::path temporary_parent_;
    std::vector<fs::path> links_;

    void cleanup() noexcept {
        if (root.empty()) return;
        std::error_code error;
        const auto resolved = fs::canonical(root, error);
        // Verify the final absolute deletion target, not merely the generated string.
        if (error || !resolved.is_absolute() || resolved != root || resolved.parent_path() != temporary_parent_ ||
            !resolved.filename().string().starts_with("reskate-bounded-reader-")) {
            std::cerr << "Synthetic fixture cleanup refused an unverified root\n";
            return;
        }
        for (const auto& link : links_) { fs::remove(link, error); error.clear(); }
        fs::remove_all(resolved, error);
        if (error) std::cerr << "Synthetic fixture cleanup incomplete: " << error.message() << '\n';
        root.clear();
    }
};
#endif
} // namespace bounded_reader_test_detail

namespace manhole_candidate_test_detail {
inline void put_little(std::vector<std::byte>& bytes, std::size_t offset, std::uint64_t value, std::size_t width) {
    if (width > 8 || offset > bytes.size() || width > bytes.size() - offset)
        throw std::runtime_error("Synthetic manhole fixture write exceeds its buffer");
    for (std::size_t i = 0; i < width; ++i) bytes[offset + i] = static_cast<std::byte>((value >> (8 * i)) & 0xff);
}

// Capture literals are authored independently of the admission helper's expected arrays.
inline frostbite::BundleAsset synthetic_manhole_asset() {
    frostbite::BundleAsset asset;
    asset.kind = frostbite::AssetKind::resource;
    asset.name = "world/props/common/roads/cmn_prp_manhole_01/cmn_prp_manhole_03_mesh";
    asset.resourceType = 0x49b156d4;
    asset.resourceId = 0x08b4cc352279fb17ULL;
    asset.originalSize = 3616;
    asset.sha1.bytes = {std::byte{0x86}, std::byte{0x22}, std::byte{0x27}, std::byte{0xa0}, std::byte{0x28},
        std::byte{0x74}, std::byte{0xf2}, std::byte{0xbd}, std::byte{0xa2}, std::byte{0x32},
        std::byte{0xf9}, std::byte{0x78}, std::byte{0x49}, std::byte{0x24}, std::byte{0x12},
        std::byte{0x14}, std::byte{0xe4}, std::byte{0x9e}, std::byte{0x46}, std::byte{0xf3}};
    return asset;
}

inline frostbite::MeshLodMetadata synthetic_manhole_metadata() {
    std::vector<std::byte> resource(3616);
    for (const auto& [offset, value] : std::array<std::pair<std::size_t, std::uint32_t>, 4>{{{0, 192}, {4, 176}, {8, 384}, {12, 0}}})
        put_little(resource, offset, value, 4);
    put_little(resource, 180, 3, 2);
    put_little(resource, 48, 192, 8);
    put_little(resource, 56, 368, 8);
    put_little(resource, 64, 544, 8);
    put_little(resource, 208, 0, 4);
    put_little(resource, 216, 2, 4);
    put_little(resource, 220, 720, 8);
    put_little(resource, 292, 33, 4);
    put_little(resource, 296, 2160, 4);
    put_little(resource, 300, 4912, 4);
    constexpr std::array<unsigned char, 16> identity{0x01, 0x56, 0xd8, 0x0f, 0x72, 0x25, 0x05, 0x48,
                                                   0xe4, 0xd4, 0x73, 0x02, 0xb9, 0xfe, 0x31, 0x79};
    for (std::size_t i = 0; i < identity.size(); ++i) resource[324 + i] = static_cast<std::byte>(identity[i]);
    for (const std::size_t section : {736u, 1120u}) {
        put_little(resource, section + 31, 3, 1);
        put_little(resource, section + 32, 180, 4);
    }
    put_little(resource, 736 + 44, 252, 4);
    put_little(resource, 736 + 208, 3, 1);
    put_little(resource, 736 + 209, 3, 1);
    constexpr std::array<unsigned char, 12> first_elements{1, 8, 0, 0, 33, 6, 0, 1, 52, 13, 0, 2};
    constexpr std::array<unsigned char, 6> first_streams{8, 0, 4, 0, 4, 0};
    for (std::size_t i = 0; i < first_elements.size(); ++i) resource[848 + i] = static_cast<std::byte>(first_elements[i]);
    for (std::size_t i = 0; i < first_streams.size(); ++i) resource[912 + i] = static_cast<std::byte>(first_streams[i]);
    put_little(resource, 1120 + 36, 540, 4);
    put_little(resource, 1120 + 40, 4032, 4);
    put_little(resource, 1120 + 44, 109, 4);
    put_little(resource, 1120 + 208, 1, 1);
    put_little(resource, 1120 + 209, 1, 1);
    resource[1232] = std::byte{1};
    resource[1233] = std::byte{8};
    resource[1296] = std::byte{8};
    // The alternate stride lands here; these raw sentinel words do not alter the 384-byte declaration.
    put_little(resource, 1192, 0xffffffffU, 4);
    put_little(resource, 1196, 0xffffffffU, 4);
    auto result = frostbite::read_mesh_lod_metadata(resource, 0);
    if (!result.static_common_offsets || result.static_section_candidates.size() != 2 ||
        result.static_section_candidates[0].sections.size() != 2 || result.static_section_candidates[1].sections.size() != 2 ||
        result.static_section_candidates[0].sections[0].elements.size() != 3 ||
        result.static_section_candidates[0].sections[0].streams.size() != 3 ||
        result.static_section_candidates[0].sections[1].elements.size() != 1 ||
        result.static_section_candidates[0].sections[1].streams.size() != 1)
        throw std::runtime_error("Synthetic parser fixture lacks the vectors required by mutation tests");
    return result;
}

inline ChunkLocationLookup synthetic_manhole_lookup() {
    ChunkLocationLookup lookup;
    lookup.toc_matches = 1;
    lookup.retained = 1;
    lookup.resolved = true;
    lookup.refusal = "none";
    auto& location = lookup.observations[0];
    location.scope = ChunkLocationScope::toc;
    location.index = 9977;
    location.payload_present = location.range_valid = true;
    location.payload = {{false, 2016875820, 27}, 472228264, 2820};
    location.range_end = 472231084;
    return lookup;
}

inline std::vector<std::byte> synthetic_manhole_geometry() {
    std::vector<std::byte> geometry(7072, std::byte{0xab});
    for (std::size_t i = 0; i < 540; ++i) {
        put_little(geometry, 4912 + 2 * i, i % 252, 2);
        put_little(geometry, 5992 + 2 * i, i % 109, 2);
    }
    return geometry;
}
} // namespace manhole_candidate_test_detail

// Only authored synthetic files and byte arrays are used; no native qualification is inferred.
inline int manhole_candidate_self_test() {
#ifndef _WIN32
    std::cout << "manhole_candidate: unavailable; strict file identity tests require Windows\n";
    return 77;
#else
    using namespace bounded_reader_test_detail;
    std::size_t cases{}, checks{}, failures{}, unavailable{};
    const auto check = [&](bool condition, const char* message) {
        ++checks;
        if (!condition) throw std::runtime_error(message);
    };
    const auto run = [&](const char* name, const auto& body) {
        ++cases;
        try { body(); }
        catch (const std::exception& error) {
            ++failures;
            std::cerr << "FAILED: " << name << ": " << error.what() << '\n';
        }
    };
    const auto deny = [&](const auto& operation, std::string_view token) {
        bool refused{};
        try { (void)operation(); }
        catch (const std::runtime_error& error) {
            refused = true;
            check(std::string_view(error.what()).starts_with(std::string("Bounded CAS: ") + std::string(token)),
                  "refusal occurred at the expected bounded-reader gate");
        }
        check(refused, "the invalid read must refuse");
    };

    run("encoded quota precedes file opening", [&] {
        Fixture fixture;
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        fixture.require_owned(fixture.archive());
        check(fs::remove(fixture.archive()), "the synthetic archive was removed for the pre-open denial");
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 0); }, "encoded_size_out_of_bounds");
        deny([&] { return archives.read_bounded(fixture_location, 0, 0, 16); }, "encoded_size_out_of_bounds");
        deny([&] { return archives.read_bounded(fixture_location, 0, (std::numeric_limits<std::uint32_t>::max)(), 16); },
             "encoded_size_out_of_bounds");
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "file_open_failed");
    });
    run("whole range and opened-file provenance", [&] {
        Fixture fixture;
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        const auto expected = file_information(fixture.archive());
        const auto read = archives.read_bounded(fixture_location, 0, 16, 16);
        check(read.encoded == fixture.bytes && read.archive_size == 16, "bounded bytes and physical size match the synthetic file");
        check(read.path.is_absolute() && fs::equivalent(read.path, fixture.archive()), "reported path identifies the opened fixture");
        check(read.volume_serial == expected.dwVolumeSerialNumber &&
              read.file_index == words(expected.nFileIndexHigh, expected.nFileIndexLow), "reported identity matches the synthetic file");
        check(read.last_write_time == words(expected.ftLastWriteTime.dwHighDateTime, expected.ftLastWriteTime.dwLowDateTime),
              "write metadata is reported from the stable file");
    });
    run("subrange and exact EOF", [&] {
        Fixture fixture;
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        const auto middle = archives.read_bounded(fixture_location, 3, 5, 5);
        const auto tail = archives.read_bounded(fixture_location, 12, 4, 4);
        check(middle.encoded == std::vector<std::byte>(fixture.bytes.begin() + 3, fixture.bytes.begin() + 8),
              "the seek uses the requested offset");
        check(tail.encoded == std::vector<std::byte>(fixture.bytes.begin() + 12, fixture.bytes.end()),
              "a nonempty range ending exactly at EOF is admitted");
    });
    run("physical range denies before read", [&] {
        Fixture fixture;
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        deny([&] { return archives.read_bounded(fixture_location, 16, 1, 1); }, "range_outside_file");
        deny([&] { return archives.read_bounded(fixture_location, 17, 1, 1); }, "range_outside_file");
        deny([&] { return archives.read_bounded(fixture_location, 15, 2, 2); }, "range_outside_file");
        deny([&] { return archives.read_bounded(fixture_location, (std::numeric_limits<std::uint32_t>::max)(), 2, 2); },
             "range_outside_file");
    });
    run("fresh size ignores the legacy cache", [&] {
        Fixture fixture;
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        check(archives.archive_size(fixture.data_root, fixture_location) == 16, "the legacy cache was populated");
        check(archives.read_bounded(fixture_location, 0, 16, 16).encoded.size() == 16, "the first strict read sees the original size");
        fixture.require_owned(fixture.archive());
        fs::resize_file(fixture.archive(), 4);
        deny([&] { return archives.read_bounded(fixture_location, 0, 8, 8); }, "range_outside_file");
        const auto shorter = archives.read_bounded(fixture_location, 0, 4, 4);
        check(shorter.archive_size == 4 && shorter.encoded.size() == 4, "a later strict read uses the current opened-file size");
    });
    run("unknown explicit mapping", [&] {
        Fixture fixture;
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        auto unknown = fixture_location;
        ++unknown.installChunk;
        deny([&] { return archives.read_bounded(unknown, 0, 1, 1); }, "explicit_directory_unavailable");
    });
    run("duplicate explicit rows even when identical", [&] {
        for (const auto* other : {"pkg", "alternate"}) {
            Fixture fixture(make_layout({{fixture_install, "pkg"}, {fixture_install, other}}));
            fixture.write(fixture.data_root / "Win32" / "alternate" / "cas_01.cas", fixture.bytes);
            vfs::GameArchives archives(fixture.data_root, fixture.layout);
            deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "explicit_directory_ambiguous");
        }
    });
    run("duplicate container and name fields", [&] {
        for (unsigned field = 0; field < 3; ++field) {
            auto layout = make_layout();
            if (field == 0) layout.children.push_back(layout.children.front());
            else if (field == 1) layout.children[0].children.push_back(layout.children[0].children.front());
            else {
                auto& row = layout.children[0].children[0].children[0];
                row.children.push_back(row.children.front());
            }
            Fixture fixture(std::move(layout));
            vfs::GameArchives archives(fixture.data_root, fixture.layout);
            deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "explicit_directory_unavailable");
        }
    });
    run("duplicate persistent index field", [&] {
        auto layout = make_layout();
        auto& row = layout.children[0].children[0].children[0];
        row.children.push_back(row.children[1]);
        Fixture fixture(std::move(layout));
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "explicit_directory_ambiguous");
    });
    run("inferred mapping stays unavailable to strict reads", [&] {
        Fixture fixture(make_layout({}, true));
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        check(archives.directory(fixture_install) == "pkg", "the unique legacy inference exists in the fixture");
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "explicit_directory_unavailable");
    });
    run("ambiguous inferred mapping", [&] {
        Fixture fixture(make_layout({}, true));
        fixture.write(fixture.data_root / "Win32" / "alternate" / "cas_01.cas", fixture.bytes);
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        check(archives.find_directory(fixture_install) == nullptr, "two matching archive sets remain ambiguous");
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "explicit_directory_unavailable");
    });
    run("unsafe directory components", [&] {
        for (const auto* directory : {"..\\..\\outside", "C:\\outside", "pkg:stream"}) {
            Fixture fixture(make_layout({{fixture_install, directory}}));
            vfs::GameArchives archives(fixture.data_root, fixture.layout);
            deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "unsafe_directory");
        }
    });
    run("layer identity requires explicit agreement", [&] {
        Fixture fixture;
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        auto patch = fixture_location;
        patch.patch = true;
        deny([&] { return archives.read_bounded(patch, 0, 1, 1); }, "layer_mismatch");
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1, true); }, "layer_mismatch");
        check(archives.read_bounded(patch, 0, 1, 1, true).encoded == std::vector<std::byte>{std::byte{0}},
              "a caller explicitly naming the stored layer can read its own root");
    });
    run("GameData forwards the strict encoded base read", [&] {
        Fixture fixture;
        vfs::GameData data(fixture.game_root);
        const fb::BundleFileInfo payload{fixture_location, 4, 3};
        const auto result = data.read_encoded_bounded(payload, 3);
        check(result.encoded == std::vector<std::byte>(fixture.bytes.begin() + 4, fixture.bytes.begin() + 7) &&
              result.archive_size == 16, "GameData returns encoded bytes and physical provenance without decoding");
        deny([&] { return data.read_encoded_bounded(payload, 2); }, "encoded_size_out_of_bounds");
        auto patch = payload;
        patch.location.patch = true;
        deny([&] { return data.read_encoded_bounded(patch, 3); }, "layer_mismatch");
    });
    run("existing writer prevents a protected open", [&] {
        Fixture fixture;
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        Handle writer(CreateFileW(fixture.archive().c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
        check(writer.get() != INVALID_HANDLE_VALUE, "the synthetic competing writer is open");
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "file_open_failed");
    });
    run("package reparse escape", [&] {
        Fixture fixture(make_layout({{fixture_install, "escape"}}));
        const auto outside = fixture.root / "outside";
        fixture.write(outside / "cas_01.cas", fixture.bytes);
        DWORD failure{};
        if (!fixture.directory_link(fixture.data_root / "Win32" / "escape", outside, failure)) {
            ++unavailable;
            std::cout << "UNAVAILABLE: package reparse fixture, Windows error " << failure << '\n';
            return;
        }
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "path_outside_root");
    });
    run("Win32 reparse escape", [&] {
        Fixture fixture;
        const auto original = fixture.data_root / "Win32";
        const auto outside = fixture.root / "outside-win32";
        fixture.require_owned(original);
        fixture.require_owned(outside);
        fs::rename(original, outside);
        DWORD failure{};
        if (!fixture.directory_link(original, outside, failure)) {
            ++unavailable;
            std::cout << "UNAVAILABLE: Win32 reparse fixture, Windows error " << failure << '\n';
            return;
        }
        vfs::GameArchives archives(fixture.data_root, fixture.layout);
        deny([&] { return archives.read_bounded(fixture_location, 0, 1, 1); }, "path_outside_root");
    });

    using namespace manhole_candidate_test_detail;
    const auto reason = [](const auto& result, std::string_view expected) {
        return result.refusal && std::string_view(result.refusal) == expected;
    };
    run("synthetic resource passes inspection admission without promotion", [&] {
        const auto asset = synthetic_manhole_asset();
        const auto metadata = synthetic_manhole_metadata();
        const auto lookup = synthetic_manhole_lookup();
        check(manhole_resource_gate(asset).accepted, "independently authored manifest literals match");
        check(metadata.static_section_candidates.size() == 2 && metadata.static_section_candidates[0].stride == 384 &&
              metadata.static_section_candidates[1].stride == 416, "the actual parser retains both raw layout attempts");
        const auto admitted = manhole_candidate_gate(metadata, lookup);
        check(admitted.accepted && reason(admitted, "none"), "the synthetic parser result matches this inspection hypothesis");
        check(!metadata.complete && !metadata.lod_kind_supported && metadata.candidates.empty() &&
              metadata.geometry.chunk == fb::Guid{} && !metadata.diagnostics.empty(),
              "admission preserves unsupported metadata and does not create a qualified geometry identity");
    });
    run("manifest identity mutations refuse", [&] {
        for (unsigned field = 0; field < 6; ++field) {
            auto asset = synthetic_manhole_asset();
            switch (field) {
            case 0: asset.kind = fb::AssetKind::chunk; break;
            case 1: asset.name += "/other"; break;
            case 2: asset.name[0] = 'W'; break;
            case 3: ++asset.resourceType; break;
            case 4: ++asset.resourceId; break;
            default: ++asset.originalSize; break;
            }
            const auto result = manhole_resource_gate(asset);
            check(!result.accepted && reason(result, "resource_metadata_changed"), "each exact manifest identity field is enforced");
        }
        for (std::size_t byte = 0; byte < 20; ++byte) {
            auto asset = synthetic_manhole_asset();
            asset.sha1.bytes[byte] ^= std::byte{0x80};
            const auto result = manhole_resource_gate(asset);
            check(!result.accepted && reason(result, "resource_metadata_changed"), "every manifest digest byte participates");
        }
    });
    run("header LOD and interpretation mutations refuse", [&] {
        const auto lookup = synthetic_manhole_lookup();
        for (unsigned field = 0; field < 12; ++field) {
            auto mesh = synthetic_manhole_metadata();
            if (field < 4) ++mesh.header[field];
            else switch (field) {
            case 4: mesh.skinned = true; break;
            case 5: mesh.lod_kind_supported = true; break;
            case 6: mesh.complete = true; break;
            case 7: mesh.lod_kind = 1; break;
            case 8: ++mesh.lod_count; break;
            case 9: ++mesh.lod_index; break;
            case 10: ++mesh.lod_offset; break;
            default: mesh.static_common_offsets.reset(); break;
            }
            const auto result = manhole_candidate_gate(mesh, lookup);
            check(!result.accepted && reason(result, "lod_observation_changed"), "the fixed LOD hypothesis cannot broaden or promote itself");
        }
    });
    run("common fields and all geometry identity bytes refuse mutation", [&] {
        const auto lookup = synthetic_manhole_lookup();
        for (unsigned field = 0; field < 5; ++field) {
            auto mesh = synthetic_manhole_metadata();
            auto& common = *mesh.static_common_offsets;
            switch (field) {
            case 0: ++common.section_count_raw; break;
            case 1: ++common.section_pointer_raw; break;
            case 2: ++common.index_format_raw; break;
            case 3: ++common.index_bytes_raw; break;
            default: ++common.vertex_bytes_raw; break;
            }
            const auto result = manhole_candidate_gate(mesh, lookup);
            check(!result.accepted && reason(result, "common_observation_changed"), "all common scalar observations are pinned");
        }
        for (std::size_t byte = 0; byte < 16; ++byte) {
            auto mesh = synthetic_manhole_metadata();
            mesh.static_common_offsets->geometry_identity_raw[byte] ^= std::byte{0x80};
            const auto result = manhole_candidate_gate(mesh, lookup);
            check(!result.accepted && reason(result, "common_observation_changed"), "all sixteen candidate identity bytes are pinned");
        }
    });
    run("both distinct raw layout attempts remain required", [&] {
        const auto lookup = synthetic_manhole_lookup();
        for (unsigned mutation = 0; mutation < 5; ++mutation) {
            auto mesh = synthetic_manhole_metadata();
            switch (mutation) {
            case 0: mesh.static_section_candidates.clear(); break;
            case 1: mesh.static_section_candidates.pop_back(); break;
            case 2: mesh.static_section_candidates[1].stride = 384; break;
            case 3: mesh.static_section_candidates[0].stride = 416; break;
            default: mesh.static_section_candidates.push_back(mesh.static_section_candidates.front()); break;
            }
            const auto result = manhole_candidate_gate(mesh, lookup);
            check(!result.accepted && reason(result, "section_candidates_changed"), "absent or duplicated layout attempts refuse");
        }
        auto reordered = synthetic_manhole_metadata();
        std::swap(reordered.static_section_candidates[0], reordered.static_section_candidates[1]);
        check(manhole_candidate_gate(reordered, lookup).accepted, "candidate identity is its unique stride, not list order");
    });
    run("384 table availability and diagnostics remain binding", [&] {
        const auto lookup = synthetic_manhole_lookup();
        for (unsigned field = 0; field < 9; ++field) {
            auto mesh = synthetic_manhole_metadata();
            auto& candidate = mesh.static_section_candidates[0];
            switch (field) {
            case 0: candidate.table_pointer_resolved = false; break;
            case 1: candidate.table_span_valid = false; break;
            case 2: candidate.observation_complete = false; break;
            case 3: ++candidate.table_offset; break;
            case 4: ++candidate.span_bytes; break;
            case 5: candidate.sections.pop_back(); break;
            case 6: candidate.sections.push_back(candidate.sections.front()); break;
            case 7: candidate.diagnostic_count = 1; break;
            default: candidate.diagnostics.push_back("synthetic diagnostic"); break;
            }
            const auto result = manhole_candidate_gate(mesh, lookup);
            check(!result.accepted && reason(result, "section_table_changed"), "unavailable or changed 384-byte table refuses");
        }
    });
    run("every section scalar count and vector size is pinned", [&] {
        const auto lookup = synthetic_manhole_lookup();
        for (std::size_t section = 0; section < 2; ++section) {
            for (unsigned field = 0; field < 13; ++field) {
                auto mesh = synthetic_manhole_metadata();
                auto& actual = mesh.static_section_candidates[0].sections[section];
                switch (field) {
                case 0: ++actual.resource_offset; break;
                case 1: ++actual.primitive_raw; break;
                case 2: ++actual.triangle_count_raw; break;
                case 3: ++actual.first_index_raw; break;
                case 4: ++actual.vertex_start_raw; break;
                case 5: ++actual.vertex_count_raw; break;
                case 6: actual.declarations_observed = false; break;
                case 7: ++actual.element_count_raw; break;
                case 8: ++actual.stream_count_raw; break;
                case 9: actual.elements.pop_back(); break;
                case 10: actual.elements.push_back({}); break;
                case 11: actual.streams.pop_back(); break;
                default: actual.streams.push_back({}); break;
                }
                const auto result = manhole_candidate_gate(mesh, lookup);
                check(!result.accepted && reason(result, "section_observation_changed"), "each section scalar and vector length is enforced");
            }
        }
    });
    run("every declaration byte and stream mapping is pinned", [&] {
        const auto lookup = synthetic_manhole_lookup();
        for (std::size_t section = 0; section < 2; ++section) {
            const std::size_t slots = section == 0 ? 3 : 1;
            for (std::size_t slot = 0; slot < slots; ++slot) {
                for (unsigned field = 0; field < 4; ++field) {
                    auto mesh = synthetic_manhole_metadata();
                    auto& element = mesh.static_section_candidates[0].sections[section].elements[slot];
                    switch (field) {
                    case 0: ++element.usage_raw; break;
                    case 1: ++element.format_raw; break;
                    case 2: ++element.offset_raw; break;
                    default: ++element.stream_raw; break;
                    }
                    const auto result = manhole_candidate_gate(mesh, lookup);
                    check(!result.accepted && reason(result, "section_observation_changed"), "each declaration byte is enforced independently");
                }
                for (unsigned field = 0; field < 2; ++field) {
                    auto mesh = synthetic_manhole_metadata();
                    auto& stream = mesh.static_section_candidates[0].sections[section].streams[slot];
                    if (field == 0) ++stream.stride_raw;
                    else ++stream.classification_raw;
                    const auto result = manhole_candidate_gate(mesh, lookup);
                    check(!result.accepted && reason(result, "section_observation_changed"), "stream stride and classification both remain raw constraints");
                }
            }
        }
    });
    run("alternate raw section values are not promoted", [&] {
        auto mesh = synthetic_manhole_metadata();
        mesh.static_section_candidates[1].sections[1].primitive_raw = 255;
        mesh.static_section_candidates[1].sections[1].triangle_count_raw = 123456;
        const auto result = manhole_candidate_gate(mesh, synthetic_manhole_lookup());
        check(result.accepted && !mesh.complete && !mesh.lod_kind_supported && mesh.candidates.empty(),
              "uninterpreted 416-byte observations neither grant native support nor silently become a selected layout");
        check(mesh.static_section_candidates[1].sections[1].primitive_raw == 255 &&
              mesh.static_section_candidates[1].sections[1].triangle_count_raw == 123456, "alternate raw values remain intact");
    });
    run("location resolution and uniqueness flags must all agree", [&] {
        const auto mesh = synthetic_manhole_metadata();
        for (unsigned field = 0; field < 13; ++field) {
            auto lookup = synthetic_manhole_lookup();
            switch (field) {
            case 0: lookup.resolved = false; break;
            case 1: lookup.zero_identity = true; break;
            case 2: lookup.duplicate = true; break;
            case 3: lookup.conflict = true; break;
            case 4: lookup.removed_matches = 1; break;
            case 5: lookup.bundle_matches = 1; break;
            case 6: lookup.toc_matches = 0; break;
            case 7: lookup.toc_matches = 2; break;
            case 8: lookup.retained = 0; break;
            case 9: lookup.retained = 2; break;
            case 10: lookup.omitted = 1; break;
            case 11: lookup.refusal = nullptr; break;
            default: lookup.refusal = "absent"; break;
            }
            const auto result = manhole_candidate_gate(mesh, lookup);
            check(!result.accepted && reason(result, "location_not_unique"), "resolution cannot hide absence, ambiguity, removal or omitted records");
        }
    });
    run("every selected TOC location field is pinned", [&] {
        const auto mesh = synthetic_manhole_metadata();
        for (unsigned field = 0; field < 11; ++field) {
            auto lookup = synthetic_manhole_lookup();
            auto& location = lookup.observations[0];
            switch (field) {
            case 0: location.scope = ChunkLocationScope::bundle; break;
            case 1: ++location.index; break;
            case 2: location.removed = true; break;
            case 3: location.payload_present = false; break;
            case 4: location.range_valid = false; break;
            case 5: location.payload.location.patch = true; break;
            case 6: ++location.payload.location.installChunk; break;
            case 7: ++location.payload.location.archive; break;
            case 8: ++location.payload.offset; break;
            case 9: ++location.payload.size; break;
            default: ++location.range_end; break;
            }
            const auto result = manhole_candidate_gate(mesh, lookup);
            check(!result.accepted && reason(result, "location_metadata_changed"), "changed source scope, index, availability or location refuses");
        }
    });
    run("decoded size is exact before any index scan", [&] {
        for (const std::size_t size : {0u, 7071u, 7073u, 14144u}) {
            const std::vector<std::byte> bytes(size, std::byte{0xff});
            const auto result = inspect_manhole_candidate_indices(bytes);
            check(!result.inspected && !result.consistent && reason(result, "decoded_size_mismatch"), "a different decoded size refuses inspection");
            check(result.total_count == 0 && result.outside_count == 0 && result.retained == 0 && result.omitted == 0 &&
                  result.sections[0].count == 0 && result.sections[1].count == 0, "size refusal does not read or fabricate index statistics");
        }
    });
    run("all 1080 candidate indices and both section extrema", [&] {
        const auto result = inspect_manhole_candidate_indices(synthetic_manhole_geometry());
        check(result.inspected && result.consistent && reason(result, "none") && result.total_count == 1080,
              "the complete two-section candidate index span is checked");
        check(result.sections[0].count == 540 && result.sections[0].minimum == 0 && result.sections[0].maximum == 251 &&
              result.sections[1].count == 540 && result.sections[1].minimum == 0 && result.sections[1].maximum == 108,
              "statistics use each section's independent index window");
        check(result.outside_count == 0 && result.retained == 0 && result.omitted == 0,
              "valid synthetic indices produce no invented bad records");
    });
    run("last index in each section is checked", [&] {
        for (std::size_t section = 0; section < 2; ++section) {
            auto bytes = synthetic_manhole_geometry();
            const std::size_t offset = section == 0 ? 5990 : 7070;
            const auto value = section == 0 ? std::uint16_t{252} : std::uint16_t{109};
            put_little(bytes, offset, value, 2);
            const auto result = inspect_manhole_candidate_indices(bytes);
            check(result.inspected && !result.consistent && result.total_count == 1080 && result.outside_count == 1 &&
                  result.retained == 1 && result.omitted == 0 && reason(result, "candidate_index_out_of_range"),
                  "the final index cannot escape the full scan");
            check(result.sections[section].count == 540 && result.sections[section].outside_count == 1 &&
                  result.sections[section].maximum == value && result.sections[1 - section].outside_count == 0,
                  "a last-entry failure is attributed to the correct section");
            const auto& bad = result.bad_indices[0];
            check(bad.section == section && bad.index == 539 && bad.byte_offset == offset && bad.value == value,
                  "the failure retains exact section-local and byte locations");
        }
    });
    run("largest valid and first invalid indices", [&] {
        auto bytes = synthetic_manhole_geometry();
        for (std::size_t index = 0; index < 540; ++index) {
            put_little(bytes, 4912 + 2 * index, 251, 2);
            put_little(bytes, 5992 + 2 * index, 108, 2);
        }
        const auto valid = inspect_manhole_candidate_indices(bytes);
        check(valid.consistent && valid.sections[0].minimum == 251 && valid.sections[0].maximum == 251 &&
              valid.sections[1].minimum == 108 && valid.sections[1].maximum == 108, "vertex_count minus one is valid in each section");
        put_little(bytes, 4912, 252, 2);
        put_little(bytes, 5992, 109, 2);
        const auto invalid = inspect_manhole_candidate_indices(bytes);
        check(!invalid.consistent && invalid.total_count == 1080 && invalid.outside_count == 2 && invalid.retained == 2 &&
              invalid.sections[0].outside_count == 1 && invalid.sections[1].outside_count == 1,
              "vertex_count itself is outside in both sections");
    });
    run("candidate index interpretation is explicitly little endian", [&] {
        auto bytes = synthetic_manhole_geometry();
        bytes[4912] = std::byte{0x02};
        bytes[4913] = std::byte{0x01};
        const auto result = inspect_manhole_candidate_indices(bytes);
        check(result.outside_count == 1 && result.retained == 1 && result.bad_indices[0].value == 258 &&
              result.sections[0].maximum == 258, "asymmetric bytes are read as 0x0102 rather than 0x0201 or one byte");
    });
    run("bad-index reporting cap does not cap inspection", [&] {
        auto bytes = synthetic_manhole_geometry();
        std::fill(bytes.begin() + 4912, bytes.end(), std::byte{0xff});
        const auto result = inspect_manhole_candidate_indices(bytes);
        check(result.inspected && !result.consistent && result.total_count == 1080 && result.outside_count == 1080 &&
              result.retained == 8 && result.omitted == 1072, "all failures count after the eight-record retention cap");
        for (const auto& section : result.sections)
            check(section.count == 540 && section.outside_count == 540 && section.minimum == 65535 && section.maximum == 65535,
                  "both complete section windows still contribute statistics");
        for (std::size_t i = 0; i < 8; ++i)
            check(result.bad_indices[i].section == 0 && result.bad_indices[i].index == i &&
                  result.bad_indices[i].byte_offset == 4912 + 2 * i && result.bad_indices[i].value == 65535,
                  "retained failures are the first exact records without slot overwrites");
    });
    run("vertex and padding bytes remain uninterpreted", [&] {
        auto bytes = synthetic_manhole_geometry();
        for (std::size_t i = 0; i < 4912; ++i) bytes[i] = static_cast<std::byte>(i & 0xff);
        const auto result = inspect_manhole_candidate_indices(bytes);
        check(result.inspected && result.consistent && result.total_count == 1080 && result.outside_count == 0 &&
              result.sections[0].maximum == 251 && result.sections[1].maximum == 108,
              "changing every vertex and padding byte does not change candidate index consistency");
    });
    run("seven authored windows partition only the implied span", [&] {
        constexpr std::array<std::pair<std::size_t, std::size_t>, 7> expected{{
            {0, 252 * 8}, {2016, 2016 + 252 * 4}, {3024, 3024 + 252 * 4},
            {4032, 4032 + 109 * 8}, {4904, 4912}, {4912, 4912 + 180 * 3 * 2}, {5992, 5992 + 180 * 3 * 2}}};
        check(manhole_windows.size() == expected.size(), "the seven stream/padding/index windows are explicit");
        std::size_t end{};
        for (std::size_t i = 0; i < expected.size(); ++i) {
            check(manhole_windows[i].begin == expected[i].first && manhole_windows[i].end == expected[i].second &&
                  manhole_windows[i].begin == end && manhole_windows[i].end > end && !manhole_windows[i].name.empty(),
                  "each half-open window follows the independent captured count arithmetic");
            end = manhole_windows[i].end;
        }
        check(end == 7072, "the final endpoint is the implied candidate span, not a claim about an unseen payload");
    });

    std::cout << "manhole_candidate: " << cases << " cases, " << checks << " checks, " << failures
              << " failures, " << unavailable << " unavailable fixtures\n";
    return failures ? 1 : 0;
#endif
}
} // namespace dingosdk::trainer::asset_tools
