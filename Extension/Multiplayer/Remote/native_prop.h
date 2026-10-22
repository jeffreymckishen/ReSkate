#pragma once
#include <array>
#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>

// Models placed in the world by ReSkate: an object blueprint loaded on the map, created as a
// client-only entity and moved every frame (Engine/Game/Build/<build>/world_props.h).
namespace dingosdk::multiplayer {
// The engine's entity destruction hook (native_skater.cpp): a prop the engine destroys (a map
// change takes them all) is forgotten before it is freed. Any thread; cheap with none placed.
void prop_entity_destroyed(std::uintptr_t entity) noexcept;

// Client-owned world models. Handles are opaque bookkeeping: callers retain them
// between client ticks and never modify their fields. No native call runs from a
// destructor or render thread. The shared destruction hook invalidates each
// generation before the engine frees its entity, including on level changes.
struct ClientPropHandle {
    std::uintptr_t entity{}, parent{}, context{}, base{};
    std::uint64_t generation{};
};
// Optional private observation only. Coherence does not establish renderer use.
struct ClientPropTransformReadback {
    ClientPropHandle owner{};
    std::uintptr_t collection{};std::uint8_t count{},first{},extra{};
    std::array<float,16> requested{},observed{};
    bool attempted{},bytes_read{},owner_fenced{},collection_fenced{},matrix_unchanged{},matrix_finite{},matrix_valid{};
    const char* issue="not_requested";
};
struct ClientPropPlacement {
    std::string_view blueprint;
    std::array<float, 16> transform{};
    // Null keeps the existing path. Storage must outlive this synchronous batch.
    ClientPropTransformReadback* readback{};
};
struct ClientPropBatchResult {
    bool ready{};
    unsigned created{}, placed{}, live{};
    std::string issue;
};
// At most sixteen static-model object blueprints; no stand-ins. All missing
// blueprints must be loaded before creation starts. Placement uses the engine's
// normal entity setter, with the same verified local owner and native TLS realm.
ClientPropBatchResult update_client_props(std::uintptr_t base, std::uintptr_t client,
    std::uintptr_t expected_local_entity, std::span<ClientPropHandle> handles,
    std::span<const ClientPropPlacement> placements) noexcept;
// True once every handle is removed or the engine has already destroyed it.
// Wrong-thread/context calls retain live handles for a later client tick.
bool release_client_props(std::span<ClientPropHandle> handles) noexcept;
} // namespace dingosdk::multiplayer
