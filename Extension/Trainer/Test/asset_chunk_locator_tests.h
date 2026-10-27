#pragma once

#include "asset_chunk_locator.h"
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace dingosdk::trainer::asset_tools {
namespace chunk_locator_test_detail {
namespace fb = frostbite;

struct Fixture {
    fb::Guid wanted;
    vfs::GameBundle bundle;
    fb::TocDocument toc;

    Fixture() {
        for (std::size_t i = 0; i < wanted.bytes.size(); ++i)
            wanted.bytes[i] = static_cast<std::byte>(i + 1);
    }
};

inline fb::BundleFileInfo sample_location() { return {{true, 7, 2}, 64, 128}; }

inline void add_bundle(Fixture& fixture, const fb::Guid& id, fb::BundleFileInfo payload = sample_location()) {
    fb::BundleAsset asset;
    asset.kind = fb::AssetKind::chunk;
    asset.guid = id;
    fixture.bundle.manifest.chunks.push_back(asset);
    fixture.bundle.payloads.push_back(payload);
}

inline void add_toc(Fixture& fixture, const fb::Guid& id, fb::BundleFileInfo payload = sample_location(), bool removed = false) {
    fixture.toc.chunks.push_back({id, payload.location, payload.offset, payload.size, removed});
}
} // namespace chunk_locator_test_detail

// These cases enter before GameData is constructed and use only synthetic manifests.
inline int chunk_locator_self_test() {
    using namespace chunk_locator_test_detail;
    std::size_t cases{}, checks{}, failures{};
    const auto check = [&](bool condition, const char* message) {
        ++checks;
        if (!condition) throw std::runtime_error(message);
    };
    const auto run = [&](const char* name, const auto& test) {
        ++cases;
        try { test(); }
        catch (const std::exception& error) {
            ++failures;
            std::cerr << "FAILED: " << name << ": " << error.what() << '\n';
        }
    };
    const auto lookup = [](const Fixture& fixture) {
        return locate_chunk_candidate(fixture.wanted, fixture.bundle, fixture.toc);
    };
    const auto reason = [](const ChunkLocationLookup& result, std::string_view expected) {
        return result.refusal && std::string_view(result.refusal) == expected;
    };

    run("absent identity", [&] {
        const auto result = lookup(Fixture{});
        check(!result.resolved && !result.zero_identity && reason(result, "absent"), "absent identity refuses");
        check(result.bundle_matches == 0 && result.toc_matches == 0 && result.removed_matches == 0,
              "absence counts both selected scopes");
        check(result.retained == 0 && result.omitted == 0 && !result.duplicate && !result.conflict,
              "absence fabricates no observation");
    });
    run("bundle payload follows EBX and RES prefixes", [&] {
        Fixture fixture;
        fixture.bundle.manifest.ebx.resize(1);
        fixture.bundle.manifest.resources.resize(2);
        fixture.bundle.payloads.resize(3, {{false, 99, 8}, 123, 456});
        auto other = fixture.wanted;
        other.bytes[15] = std::byte{0xff};
        add_bundle(fixture, other, {{false, 8, 9}, 900, 100});
        add_bundle(fixture, fixture.wanted);
        const auto result = lookup(fixture);
        check(result.resolved && reason(result, "none") && result.bundle_matches == 1 && result.toc_matches == 0,
              "unique bundle identity resolves");
        check(result.retained == 1 && !result.duplicate && !result.conflict, "only the matching chunk is retained");
        const auto& observed = result.observations[0];
        check(observed.scope == ChunkLocationScope::bundle && observed.index == 1 && !observed.removed &&
              observed.payload_present && observed.range_valid, "bundle scope and location availability are explicit");
        check(observed.payload.location == sample_location().location && observed.payload.offset == 64 &&
              observed.payload.size == 128 && observed.range_end == 192, "payload uses the complete manifest prefix");
    });
    run("unique TOC location", [&] {
        Fixture fixture;
        auto other = fixture.wanted;
        other.bytes[0] = std::byte{0xff};
        add_toc(fixture, other);
        add_toc(fixture, fixture.wanted);
        const auto result = lookup(fixture);
        check(result.resolved && result.bundle_matches == 0 && result.toc_matches == 1 && result.retained == 1,
              "independent TOC table resolves without a bundle chunk");
        const auto& observed = result.observations[0];
        check(observed.scope == ChunkLocationScope::toc && observed.index == 1 && !observed.removed &&
              observed.payload_present && observed.range_valid && observed.range_end == 192, "TOC location retains its source index");
    });
    run("every Guid byte participates", [&] {
        for (std::size_t byte = 0; byte < 16; ++byte) {
            Fixture fixture;
            auto other = fixture.wanted;
            other.bytes[byte] ^= std::byte{0x80};
            add_bundle(fixture, other);
            add_toc(fixture, other);
            const auto result = lookup(fixture);
            check(!result.resolved && result.bundle_matches == 0 && result.toc_matches == 0 && result.retained == 0 &&
                  reason(result, "absent"), "a one-byte mismatch in either scope is not an identity match");
        }
    });
    run("TOC decoder normalization", [&] {
        Fixture fixture;
        add_toc(fixture, fixture.wanted);
        const auto bytes = fb::write_patch_toc({}, fixture.toc.chunks);
        fixture.toc = fb::read_toc(bytes);
        check(fixture.toc.chunks.size() == 1 && fixture.toc.chunks[0].guid == fixture.wanted,
              "the established TOC decoder restores the original Guid bytes");
        const auto result = lookup(fixture);
        check(result.resolved && result.toc_matches == 1 && result.bundle_matches == 0,
              "normalized TOC bytes match without a second byte-order conversion");
    });
    run("names and alternative endian spellings do not match", [&] {
        Fixture fixture;
        auto other = fixture.wanted;
        std::swap(other.bytes[0], other.bytes[3]);
        std::swap(other.bytes[1], other.bytes[2]);
        std::swap(other.bytes[4], other.bytes[5]);
        std::swap(other.bytes[6], other.bytes[7]);
        add_bundle(fixture, other);
        fixture.bundle.manifest.chunks[0].name = fixture.wanted.string();
        add_toc(fixture, other);
        const auto result = lookup(fixture);
        check(!result.resolved && result.bundle_matches == 0 && result.toc_matches == 0 && reason(result, "absent"),
              "the formatted name and swapped Guid are not fallback identities");
    });
    run("zero identity refuses before matching", [&] {
        Fixture fixture;
        fixture.wanted = {};
        add_bundle(fixture, fixture.wanted);
        add_toc(fixture, fixture.wanted);
        const auto result = lookup(fixture);
        check(result.zero_identity && !result.resolved && reason(result, "zero_identity"), "zero identity is not a location request");
        check(result.bundle_matches == 0 && result.toc_matches == 0 && result.retained == 0,
              "zero identity never matches default manifest fields");
    });
    run("duplicate bundle identities", [&] {
        Fixture fixture;
        add_bundle(fixture, fixture.wanted);
        add_bundle(fixture, fixture.wanted);
        const auto result = lookup(fixture);
        check(!result.resolved && result.duplicate && !result.conflict && reason(result, "duplicate_identity"),
              "identical bundle duplicates still refuse selection");
        check(result.bundle_matches == 2 && result.toc_matches == 0 && result.retained == 2,
              "both bundle records remain counted and visible");
    });
    run("duplicate TOC identities", [&] {
        Fixture fixture;
        add_toc(fixture, fixture.wanted);
        add_toc(fixture, fixture.wanted);
        const auto result = lookup(fixture);
        check(!result.resolved && result.duplicate && !result.conflict && reason(result, "duplicate_identity"),
              "identical TOC duplicates still refuse selection");
        check(result.bundle_matches == 0 && result.toc_matches == 2 && result.retained == 2,
              "both TOC records remain counted and visible");
    });
    run("identical cross-scope alias", [&] {
        Fixture fixture;
        add_bundle(fixture, fixture.wanted);
        add_toc(fixture, fixture.wanted);
        const auto result = lookup(fixture);
        check(!result.resolved && result.duplicate && !result.conflict && reason(result, "duplicate_identity"),
              "matching locations do not conceal duplicate identity records");
        check(result.bundle_matches == 1 && result.toc_matches == 1 && result.retained == 2,
              "both selected scopes participate in uniqueness");
    });
    run("each location component can conflict", [&] {
        for (std::size_t field = 0; field < 5; ++field) {
            Fixture fixture;
            add_bundle(fixture, fixture.wanted);
            auto changed = sample_location();
            switch (field) {
            case 0: changed.location.patch = false; break;
            case 1: ++changed.location.installChunk; break;
            case 2: ++changed.location.archive; break;
            case 3: ++changed.offset; break;
            default: ++changed.size; break;
            }
            add_toc(fixture, fixture.wanted, changed);
            const auto result = lookup(fixture);
            check(!result.resolved && result.duplicate && result.conflict && reason(result, "conflicting_locations"),
                  "a changed location component is a conflict");
            check(result.bundle_matches == 1 && result.toc_matches == 1 && result.retained == 2,
                  "conflict does not discard either observation");
        }
    });
    run("removed TOC identity", [&] {
        Fixture fixture;
        add_toc(fixture, fixture.wanted, sample_location(), true);
        const auto result = lookup(fixture);
        check(!result.resolved && result.removed_matches == 1 && result.toc_matches == 1 && reason(result, "removed"),
              "a tombstone refuses location resolution");
        check(result.retained == 1 && result.observations[0].removed && !result.observations[0].payload_present &&
              !result.observations[0].range_valid, "removed entries do not expose stale location fields");
    });
    run("live bundle plus TOC tombstone", [&] {
        Fixture fixture;
        add_bundle(fixture, fixture.wanted);
        add_toc(fixture, fixture.wanted, {{false, 99, 9}, 987, 654}, true);
        const auto result = lookup(fixture);
        check(!result.resolved && result.duplicate && !result.conflict && result.removed_matches == 1 && reason(result, "removed"),
              "a live bundle does not override a selected TOC tombstone");
        check(result.bundle_matches == 1 && result.toc_matches == 1 && result.retained == 2 &&
              result.observations[0].payload_present && !result.observations[1].payload_present,
              "live and removed records retain distinct availability");
    });
    run("missing bundle location", [&] {
        Fixture fixture;
        add_bundle(fixture, fixture.wanted);
        fixture.bundle.payloads.clear();
        const auto result = lookup(fixture);
        check(!result.resolved && result.bundle_matches == 1 && result.retained == 1 && reason(result, "missing_location"),
              "identity without its payload record refuses");
        check(!result.observations[0].payload_present && !result.observations[0].range_valid,
              "missing location is not synthesized from zero fields");
    });
    run("zero compressed size in either scope", [&] {
        for (const bool toc_scope : {false, true}) {
            Fixture fixture;
            auto empty = sample_location();
            empty.size = 0;
            if (toc_scope) add_toc(fixture, fixture.wanted, empty);
            else add_bundle(fixture, fixture.wanted, empty);
            const auto result = lookup(fixture);
            check(!result.resolved && result.retained == 1 && reason(result, "empty_range"), "empty compressed range refuses");
            check(result.observations[0].payload_present && !result.observations[0].range_valid &&
                  result.observations[0].payload.size == 0, "present but empty is distinct from missing");
        }
    });
    run("late conflict beyond observation cap", [&] {
        Fixture fixture;
        for (std::size_t i = 0; i < 16; ++i) add_toc(fixture, fixture.wanted);
        auto changed = sample_location();
        ++changed.offset;
        add_toc(fixture, fixture.wanted, changed);
        const auto result = lookup(fixture);
        check(!result.resolved && result.duplicate && result.conflict && reason(result, "conflicting_locations"),
              "a conflict after retained observations still refuses");
        check(result.toc_matches == 17 && result.retained == 16 && result.omitted == 1,
              "reporting cap does not cap the identity scan");
        for (std::size_t i = 0; i < result.retained; ++i)
            check(result.observations[i].index == i && result.observations[i].payload.offset == 64,
                  "retained observations preserve original order without overwriting the last slot");
    });
    run("late tombstone beyond observation cap", [&] {
        Fixture fixture;
        for (std::size_t i = 0; i < 16; ++i) add_toc(fixture, fixture.wanted);
        add_toc(fixture, fixture.wanted, sample_location(), true);
        const auto result = lookup(fixture);
        check(!result.resolved && result.duplicate && result.removed_matches == 1 && reason(result, "removed"),
              "an omitted tombstone still blocks resolution");
        check(result.toc_matches == 17 && result.retained == 16 && result.omitted == 1,
              "removed observations participate in total and omitted counts");
    });
    run("exact observation cap", [&] {
        Fixture fixture;
        for (std::size_t i = 0; i < 16; ++i) add_bundle(fixture, fixture.wanted);
        const auto result = lookup(fixture);
        check(!result.resolved && result.duplicate && !result.conflict && result.bundle_matches == 16,
              "all identical duplicate identities remain refused");
        check(result.retained == 16 && result.omitted == 0, "an exactly full observation array is not truncated");
    });
    run("range end is promoted before addition", [&] {
        for (const bool toc_scope : {false, true}) {
            Fixture fixture;
            const fb::BundleFileInfo wide{{true, 7, 2}, std::numeric_limits<std::uint32_t>::max(), 2};
            if (toc_scope) add_toc(fixture, fixture.wanted, wide);
            else add_bundle(fixture, fixture.wanted, wide);
            const auto result = lookup(fixture);
            check(result.resolved && result.retained == 1 && result.observations[0].range_valid,
                  "a representable range crossing 4 GiB is not falsely refused");
            check(result.observations[0].range_end == std::uint64_t{4294967297}, "the end does not wrap through uint32");
        }
    });
    run("zero location identifiers remain raw", [&] {
        Fixture fixture;
        add_toc(fixture, fixture.wanted, {{false, 0, 0}, 0, 1});
        const auto result = lookup(fixture);
        check(result.resolved && result.retained == 1 && result.observations[0].range_end == 1,
              "metadata lookup does not invent invalid catalog or archive identifiers");
    });

    std::cout << "chunk_locator: " << cases << " cases, " << checks << " checks, " << failures << " failures\n";
    return failures ? 1 : 0;
}
} // namespace dingosdk::trainer::asset_tools
