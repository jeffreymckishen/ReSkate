#pragma once

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

// Reader-only phase: no game content, geometry decoding, or native qualification.
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

    std::cout << "manhole_candidate: " << cases << " cases, " << checks << " checks, " << failures
              << " failures, " << unavailable << " unavailable fixtures\n";
    return failures ? 1 : 0;
#endif
}
} // namespace dingosdk::trainer::asset_tools
