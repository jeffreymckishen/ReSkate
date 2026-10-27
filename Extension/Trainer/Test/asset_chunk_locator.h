#pragma once
#include "Engine/Vfs/game_bundles.h"
#include <array>
#include <cstddef>
#include <cstdint>

namespace dingosdk::trainer::asset_tools {
enum class ChunkLocationScope { bundle, toc };

struct ChunkLocationObservation {
    ChunkLocationScope scope{};
    std::size_t index{};
    bool removed{}, payload_present{}, range_valid{};
    frostbite::BundleFileInfo payload{};
    std::uint64_t range_end{};
};

struct ChunkLocationLookup {
    std::size_t bundle_matches{}, toc_matches{}, removed_matches{}, retained{}, omitted{};
    bool zero_identity{}, duplicate{}, conflict{}, resolved{};
    const char* refusal{"absent"};
    std::array<ChunkLocationObservation, 16> observations{};
};

inline ChunkLocationLookup locate_chunk_candidate(const frostbite::Guid& wanted, const vfs::GameBundle& bundle,
                                                  const frostbite::TocDocument& toc) noexcept {
    ChunkLocationLookup result;
    if (wanted == frostbite::Guid{}) {
        result.zero_identity = true;
        result.refusal = "zero_identity";
        return result;
    }
    frostbite::BundleFileInfo first_location{};
    bool have_first_location{};
    const auto observe = [&](ChunkLocationObservation observation) {
        if (observation.removed) ++result.removed_matches;
        if (observation.payload_present && !observation.removed) {
            // Both fields are uint32; promotion avoids wrap without inventing a 4 GiB file limit.
            // This validates a nonempty metadata range, not the archive's physical file bounds.
            observation.range_end = std::uint64_t{observation.payload.offset} + observation.payload.size;
            observation.range_valid = observation.payload.size != 0;
            if (have_first_location) {
                if (observation.payload.location != first_location.location ||
                    observation.payload.offset != first_location.offset || observation.payload.size != first_location.size)
                    result.conflict = true;
            } else {
                first_location = observation.payload;
                have_first_location = true;
            }
        }
        // Every match contributes to refusal, even after the bounded observation list fills.
        if (result.retained < result.observations.size()) result.observations[result.retained++] = observation;
        else ++result.omitted;
    };
    // Both parsers already normalize Guid bytes. Do not try alternate byte orders or string prefixes.
    for (std::size_t index = 0; index < bundle.manifest.chunks.size(); ++index) {
        if (bundle.manifest.chunks[index].guid != wanted) continue;
        ++result.bundle_matches;
        ChunkLocationObservation observation;
        observation.scope = ChunkLocationScope::bundle;
        observation.index = index;
        if (const auto* payload = bundle.payload(frostbite::AssetKind::chunk, index)) {
            observation.payload_present = true;
            observation.payload = *payload;
        }
        observe(observation);
    }
    for (std::size_t index = 0; index < toc.chunks.size(); ++index) {
        const auto& chunk = toc.chunks[index];
        if (chunk.guid != wanted) continue;
        ++result.toc_matches;
        ChunkLocationObservation observation;
        observation.scope = ChunkLocationScope::toc;
        observation.index = index;
        observation.removed = chunk.removed;
        if (!chunk.removed) {
            observation.payload_present = true;
            observation.payload = {chunk.location, chunk.offset, chunk.size};
        }
        observe(observation);
    }
    result.duplicate = result.bundle_matches > 1 || result.toc_matches > 1 ||
                       (result.bundle_matches != 0 && result.toc_matches != 0);
    if (!result.bundle_matches && !result.toc_matches) return result;
    if (result.removed_matches) result.refusal = "removed";
    else if (result.conflict) result.refusal = "conflicting_locations";
    else if (result.duplicate) result.refusal = "duplicate_identity";
    else if (!result.observations[0].payload_present) result.refusal = "missing_location";
    else if (!result.observations[0].range_valid) result.refusal = "empty_range";
    else {
        result.resolved = true;
        result.refusal = "none";
    }
    return result;
}
} // namespace dingosdk::trainer::asset_tools
