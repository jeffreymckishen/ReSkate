#include "native_prop.h"
#include "Engine/Core/Platform/memory.h"
#include "native_skater_internal.h"
#include "native_creation_list.h"
#include "Engine/Core/Log/logging.h"
#include "Engine/Game/Abi/native_data.h"
#include "Engine/Game/Build/20260929/engine.h"
#include "Engine/Game/Build/20260929/world_props.h"
#include <cmath>
#include <intrin.h>
#include <optional>
#include <unordered_map>

namespace dingosdk::multiplayer {
using namespace native_skater_detail;
namespace props = addr::world_props;
namespace {
// ---- Placed props, and the engine taking them away
// Every prop entity placed and not yet destroyed. The engine's destruction hook takes an entity
// out before it is freed, under the same lock that every move and removal holds, so nothing
// moves a freed prop. (Recursive: a removal is a destruction of our own.)
struct Registry {
    std::recursive_mutex mutex;
    std::vector<std::uintptr_t> live;
    std::unordered_map<std::uintptr_t, std::uint64_t> generations;
    std::uint64_t next_generation{1};
    std::atomic<std::size_t> count{};
};
Registry &registry() {
    static auto *r = new Registry;
    return *r;
}
bool tracked(std::uintptr_t entity) {
    auto &r = registry();
    return entity && std::find(r.live.begin(), r.live.end(), entity) != r.live.end();
}
void track(std::uintptr_t entity) {
    auto &r = registry();
    r.live.push_back(entity);
    r.generations[entity] = r.next_generation++;
    r.count.store(r.live.size(), std::memory_order_release);
}
void untrack(std::uintptr_t entity) {
    auto &r = registry();
    std::erase(r.live, entity);
    r.generations.erase(entity);
    r.count.store(r.live.size(), std::memory_order_release);
}
std::uint64_t tracked_generation(std::uintptr_t entity) {
    const auto& generations = registry().generations;
    const auto found = generations.find(entity);
    return found == generations.end() ? 0 : found->second;
}

struct Prop {
    std::uintptr_t entity{}, parent{}, context{};
};
// A blueprint the way the cone's is one (world_props.h), or the skateboard's or the skater
// code's; `chain` gets what it was, for the log.
bool is_blueprint(std::uintptr_t base, std::uintptr_t object, std::string &chain) {
    const auto vtable = ptr(object);
    chain = std::format("vtable Skate+{:#x}", vtable - base);
    if (vtable == base + props::object_blueprint_vtable || vtable == base + addr::engine::blueprint_vtable) return true;
    auto type = ptr(object, 8);
    for (int depth = 0; depth < 8 && type; ++depth) {
        if (type == base + addr::engine::board_blueprint_type || type == base + entities::blueprint_type) return true;
        const auto super = ptr(type, 0x20);
        if (super == type) break;
        type = super;
    }
    return false;
}
// A loaded named blueprint, from whichever asset domain holds it; 0 when none does.
std::uintptr_t find_named_blueprint(std::uintptr_t base, std::string_view name) {
    const auto find = game::native_data().find_asset;
    require(find != nullptr, "Native asset lookup is unavailable.");
    const std::string text(name);
    for (std::uint16_t domain = 0; domain < 0xbbf; ++domain) {
        if (!ptr(base, addr::engine::domain_owners + domain * std::uintptr_t{8})) continue;
        if (const auto asset = find(domain, text.c_str())) {
            std::string chain;
            if (!is_blueprint(base, asset, chain))
                throw std::runtime_error(std::format("{} is not a blueprint ({}).", name, chain));
            return asset;
        }
    }
    return 0;
}
// Whether entities can be created now, on this thread: the hooks are in, the engine is ready
// and the client's job context is this one. Throws only when something is wrong; false is "wait",
// and `why` (when given) gets what is waited for.
bool can_create(std::uintptr_t base, const NativeFrame &local, std::string *why = nullptr) {
    install(base);
    require(shared().hooks, "The native entity hooks are not installed.");
    require(GetCurrentThreadId() == shared().engine_thread, "Props are created on the client thread.");
    const auto wait = [&](std::string reason) {
        if (why) *why = std::move(reason);
        return false;
    };
    if (read<std::uint8_t>(base, addr::engine::entity_creation_ready) == 0) return wait("the engine is not ready to create entities");
    const auto tls_index = read<std::uint32_t>(base, addr::engine::tls_index);
    require(tls_index <= 4095, "Native TLS index changed.");
    const auto tls = ptr(static_cast<std::uintptr_t>(__readgsqword(0x58)), std::uintptr_t{tls_index} * 8);
    if (read<std::uint8_t>(tls, 0xb19) == 0) return wait("this thread may not create entities now");
    if (const auto context = ptr(tls, 0x550); context != local.context)
        return wait(std::format("the thread's job context {:#x} is not the local skater's {:#x}", context, local.context));
    return true;
}
bool current_prop_context(std::uintptr_t base, std::uintptr_t context) {
    if (!shared().hooks || shared().base != base || GetCurrentThreadId() != shared().engine_thread) return false;
    const auto index = read<std::uint32_t>(base, addr::engine::tls_index);
    if (index > 4095) return false;
    const auto tls = ptr(static_cast<std::uintptr_t>(__readgsqword(0x58)), std::uintptr_t{index} * 8);
    return read<std::uint8_t>(tls, 0xb19) != 0 && ptr(tls, 0x550) == context;
}
// As the remote skateboard is made (native_skater_spawn.cpp): a fresh entity through a creation
// list, the list initialized, then placed with its lifecycle callbacks. `kinds` gets the vtable
// of each entity the list made. Under the registry lock.
Prop create_prop(std::uintptr_t base, const NativeFrame &local, std::uintptr_t blueprint, const std::array<float, 16> &where,
                 std::string *kinds = nullptr) {
    alignas(16) const auto matrix = where;
    NativeCreationList list{};
    alignas(16) std::array<std::uint8_t, 0x190> descriptor{};
    using Init = void *(*)(void *, std::uintptr_t, std::uintptr_t, const void *);
    reinterpret_cast<Init>(base + entities::descriptor_init)(descriptor.data(), 0, local.parent, matrix.data());
    struct DescriptorScope {
        std::uintptr_t base;
        void *data;
        ~DescriptorScope() { reinterpret_cast<void (*)(void *)>(base + entities::descriptor_destroy)(static_cast<std::uint8_t *>(data) + 0x10); }
    } scope{base, descriptor.data()};
    const std::uint32_t id = 255; // local, unassociated
    std::memcpy(descriptor.data() + 0x38, &id, sizeof(id));
    descriptor[0x151] = 0;
    auto *list_pointer = &list;
    std::memcpy(descriptor.data() + 0x158, &list_pointer, sizeof(list_pointer));
    std::array<std::uintptr_t, 3> result{};
    using Create = void *(*)(void *, void *, std::uintptr_t, std::uintptr_t, std::uintptr_t);
    reinterpret_cast<Create>(base + entities::create_entity)(result.data(), descriptor.data(), blueprint, 0, 0);
    if (result[1]) reinterpret_cast<void (*)(std::uintptr_t)>(base + entities::release_reference)(result[1]);
    const auto created = read_native_creation_list(readable, list);
    if (kinds)
        for (const auto entity : created.entities) *kinds += std::format(" Skate+{:#x}", ptr(entity) - base);
    if (!created.pages.empty()) reinterpret_cast<void (*)(void *)>(base + native::initialize_creation_list)(&list);
    for (const auto page : created.pages) {
        const std::uint32_t empty = 0;
        (void)write(page + 8, &empty, sizeof(empty));
        reinterpret_cast<void (*)(void *, std::uintptr_t, std::size_t)>(base + native::free_creation_page)(&list, page, 0x1f0);
    }
    require(result[0] != 0, "The engine did not create the prop.");
    using InitializePlacement = void (*)(std::uintptr_t, const void *, std::uintptr_t, std::uint8_t);
    reinterpret_cast<InitializePlacement>(base + entities::initialize_placement)(result[0], matrix.data(), 0, 1);
    track(result[0]);
    return {result[0], ptr(result[0], 0x40), local.context};
}
// The plain entity transform setter: what moves a prop smoothly (world_props.h). Under the lock.
void place(std::uintptr_t base, const Prop &prop, const std::array<float, 16> &where) {
    alignas(16) const auto matrix = where;
    reinterpret_cast<void (*)(std::uintptr_t, const void *)>(base + entities::place_entity)(prop.entity, matrix.data());
}
// Under the lock. One the engine already took is only forgotten.
void destroy(const Prop &prop) {
    if (!tracked(prop.entity)) return;
    untrack(prop.entity);
    if (shared().hooks && ptr(prop.entity, 0x20) == prop.context) shared().original_destroy(prop.entity, prop.parent);
}
bool release_client_prop(ClientPropHandle& handle) {
    if (!handle.entity || !handle.generation || tracked_generation(handle.entity) != handle.generation) {
        handle = {};
        return true;
    }
    if (!current_prop_context(handle.base, handle.context)) return false;
    require(ptr(handle.entity) == handle.base + props::static_model_entity_vtable &&
        ptr(handle.entity, 0x20) == handle.context && ptr(handle.entity, 0x40) == handle.parent,
        "Client prop destruction ownership changed.");
    destroy({handle.entity, handle.parent, handle.context});
    handle = {};
    return true;
}
bool valid_prop_transform(const std::array<float, 16>& matrix) {
    for (const auto value : matrix) if (!std::isfinite(value)) return false;
    if (matrix[3] != 0 || matrix[7] != 0 || matrix[11] != 0 || matrix[15] != 1) return false;
    for (unsigned axis = 0; axis < 3; ++axis) {
        if (std::abs(matrix[12 + axis]) > 1000000) return false;
        float length{};
        for (unsigned row = 0; row < 3; ++row) length += matrix[axis * 4 + row] * matrix[axis * 4 + row];
        if (length < .99f || length > 1.01f) return false;
        for (unsigned other = axis + 1; other < 3; ++other) {
            float dot{};
            for (unsigned row = 0; row < 3; ++row) dot += matrix[axis * 4 + row] * matrix[other * 4 + row];
            if (std::abs(dot) > .01f) return false;
        }
    }
    return true;
}

// Existing registry lock is held. All failures are optional observation only.
// The source-exact setter at2f7ebc0 stores64B through this collection/index path.
ClientPropTransformReadback observe_prop_transform(std::uintptr_t base,std::uintptr_t expected_context,
    const ClientPropHandle& handle,const std::array<float,16>& requested) noexcept {
    struct PreserveError{DWORD saved=GetLastError();~PreserveError(){SetLastError(saved);}} error;
    ClientPropTransformReadback out;out.attempted=true;out.owner=handle;out.requested=requested;
    const auto owns=[&]() noexcept {
        std::uintptr_t vtable{},context{},parent{};
        return base&&expected_context&&handle.entity&&handle.generation&&handle.base==base&&handle.context==expected_context&&
            tracked_generation(handle.entity)==handle.generation&&memory::peek(handle.entity,vtable)&&
            vtable==base+props::static_model_entity_vtable&&memory::peek(handle.entity+0x20,context)&&context==expected_context&&
            memory::peek(handle.entity+0x40,parent)&&parent==handle.parent;
    };
    if(!owns()){out.issue="prop_owner_unavailable";return out;}
    constexpr auto highest=memory::highest_user_address;
    std::uintptr_t collection{},collection_owner{};
    if(!memory::peek(handle.entity+0x70,collection)||collection<0x10000||collection>highest-0x2000||(collection&7)||
       !memory::peek(collection,collection_owner)||collection_owner!=handle.entity||
       !memory::peek(collection+8,out.count)||!memory::peek(collection+9,out.first)||!memory::peek(collection+10,out.extra)||
       out.count>128||out.first>128||out.extra>32){out.issue="collection_or_index_unavailable";return out;}
    out.collection=collection;
    const auto address=collection+0x10+(std::uintptr_t{out.first}+2*std::uintptr_t{out.extra})*0x20;
    if(!memory::peek(address,out.observed)){out.issue="matrix_unavailable";return out;}
    out.bytes_read=true;out.matrix_finite=true;
    for(const auto value:out.observed)out.matrix_finite=std::isfinite(value)&&out.matrix_finite;
    out.matrix_valid=out.matrix_finite&&valid_prop_transform(out.observed);
    std::array<float,16> after{};std::uintptr_t after_collection{},after_owner{};std::uint8_t count{},first{},extra{};
    out.collection_fenced=memory::peek(handle.entity+0x70,after_collection)&&after_collection==collection&&
        memory::peek(collection,after_owner)&&after_owner==handle.entity&&memory::peek(collection+8,count)&&count==out.count&&
        memory::peek(collection+9,first)&&first==out.first&&memory::peek(collection+10,extra)&&extra==out.extra;
    out.matrix_unchanged=out.collection_fenced&&memory::peek(address,after)&&std::memcmp(after.data(),out.observed.data(),sizeof(after))==0;
    out.owner_fenced=owns();
    out.issue=!out.owner_fenced?"prop_owner_changed":!out.collection_fenced?"collection_or_index_changed":
        !out.matrix_unchanged?"matrix_changed_during_read":"fenced_entity_matrix_not_render_completion";
    return out;
}

} // namespace

void prop_entity_destroyed(std::uintptr_t entity) noexcept {
    auto &r = registry();
    if (!r.count.load(std::memory_order_acquire)) return; // every destruction passes through here
    std::lock_guard lock(r.mutex);
    if (tracked(entity)) untrack(entity);
}

bool release_client_props(std::span<ClientPropHandle> handles) noexcept {
    try {
        std::lock_guard lock(registry().mutex);
        bool complete = true;
        for (auto& handle : handles) complete = release_client_prop(handle) && complete;
        return complete;
    } catch (...) { return false; }
}

ClientPropBatchResult update_client_props(std::uintptr_t base, std::uintptr_t client,
    std::uintptr_t expected_local_entity, std::span<ClientPropHandle> handles,
    std::span<const ClientPropPlacement> placements) noexcept {
    ClientPropBatchResult result;
    try {
        require(!handles.empty() && handles.size() <= 16 && handles.size() == placements.size(), "Invalid client prop batch.");
        std::lock_guard lock(registry().mutex);
        for (std::size_t i = 0; i < handles.size(); ++i) {
            require(!placements[i].blueprint.empty() && placements[i].blueprint.size() < 256 &&
                valid_prop_transform(placements[i].transform), "Invalid client prop blueprint or transform.");
            if (handles[i].entity && tracked_generation(handles[i].entity) != handles[i].generation) handles[i] = {};
        }
        const auto local = capture_local(base, client, false);
        require(local.ready && local.entity == expected_local_entity && local.context && local.parent,
            "Client prop local rider is unavailable or changed.");
        const auto phase = read<std::uint32_t>(client, 0xc4);
        require(phase == 13 || phase == 21, "Client props require an active native world.");
        if (!can_create(base, local)) { result.issue = "Waiting for native entity creation readiness."; return result; }
        std::array<std::uintptr_t, 16> blueprints{};
        // Preflight the complete batch so a missing model pack cannot display a
        // misleading partial bike, or substitute an unrelated in-game object.
        for (std::size_t i = 0; i < handles.size(); ++i) {
            auto& handle = handles[i];
            if (handle.entity && (handle.base != base || handle.context != local.context)) {
                if (!release_client_prop(handle)) { result.issue = "Waiting for previous native prop context cleanup."; return result; }
            }
            if (!handle.entity) {
                blueprints[i] = find_named_blueprint(base, placements[i].blueprint);
                if (!blueprints[i]) { result.issue = "Native model blueprint is not loaded: " + std::string(placements[i].blueprint); return result; }
            }
        }
        for (std::size_t i = 0; i < handles.size(); ++i) {
            auto& handle = handles[i];
            if (!handle.entity) {
                const auto prop = create_prop(base, local, blueprints[i], placements[i].transform);
                handle = {prop.entity, prop.parent, prop.context, base, tracked_generation(prop.entity)};
                ++result.created;
            }
            require(handle.generation && tracked_generation(handle.entity) == handle.generation &&
                ptr(handle.entity) == base + props::static_model_entity_vtable &&
                ptr(handle.entity, 0x20) == local.context && ptr(handle.entity, 0x40) == handle.parent,
                "Client prop native entity ownership changed.");
            place(base, {handle.entity, handle.parent, handle.context}, placements[i].transform);
            if(placements[i].readback)*placements[i].readback=observe_prop_transform(base,local.context,handle,placements[i].transform);
            ++result.placed;
            ++result.live;
        }
        result.ready = result.live == handles.size();
        return result;
    } catch (const std::exception& error) {
        result.issue = error.what();
    } catch (...) { result.issue = "Native client prop operation failed."; }
    (void)release_client_props(handles);
    result.live = 0;
    result.ready = false;
    return result;
}

} // namespace dingosdk::multiplayer
