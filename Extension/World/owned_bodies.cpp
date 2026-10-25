#include "owned_bodies.h"
#include "Engine/Core/Hooks/hooks.h"
#include "Engine/Core/Platform/memory.h"
#include "Engine/Game/Build/addresses.h"
#include "Engine/Game/Build/image_identity.h"
#include "Engine/Game/Build/20260929/engine.h"
#include "Engine/Game/Build/20260929/no_bail.h"
#include "Engine/Game/Build/20260929/remote_collision.h"
#include "Engine/Game/Build/20260929/rigid_bodies.h"
#include "Engine/Game/Build/20260929/skater_state.h"
#include "Engine/Game/Build/20260929/sync_probe.h"
#include "Engine/Game/Build/20260929/motion_refresh_probe.h"
#include "Engine/Game/World/body_hit_identity.h"
#include "Engine/Game/World/body_contact_read.h"
#include "Extension/Multiplayer/Session/session.h"
#include "Extension/Multiplayer/Remote/native_skater.h"
#include "Extension/Skater/actor_control.h"
#include "Extension/Skater/no_bail.h"
#include "Extension/Profile/local_profile_runtime.h"
#include <Windows.h>
#include <intrin.h>
#include <algorithm>
#include <atomic>
#include <bit>
#include <cstring>

namespace dingosdk::owned_bodies {
namespace {
using namespace owned_body;
namespace r = addr::rigid_bodies;
namespace c = addr::remote_collision;
namespace e = addr::engine;
namespace k = addr::skater_state;
namespace n = addr::sync_probe;
using V4 = std::array<float, 4>;
using NativeHandle = body_hit_identity::NativeHandle;
static_assert(sizeof(NativeHandle) == 16);
using World = std::uintptr_t (*)(std::uintptr_t);
using Allocate = NativeHandle* (*)(std::uintptr_t, NativeHandle*);
using CapsuleCall = NativeHandle* (*)(std::uintptr_t, NativeHandle*, const NativeHandle*, const float*, const float*, float);
using SetInt = void (*)(NativeHandle*, int);
using SetFloat = void (*)(NativeHandle*, float);
using Touch = void (*)(NativeHandle*);
using SetMask = void (*)(NativeHandle*, const std::uint32_t*);
using SetOwner = void (*)(NativeHandle*, const NativeHandle*);
using SetVector = void (*)(NativeHandle*, const float*);
using Valid = bool (*)(const NativeHandle*);
using Synchronize = std::uintptr_t (*)(NativeHandle*, std::uintptr_t);
struct Api {
    std::uintptr_t base{};
    World world{}; Allocate allocate{}; CapsuleCall capsule{};
    SetInt motion{}; SetFloat inverse_mass{}; Touch clear{}, wake{};
    SetMask categories{}, collides{}; SetOwner owner{};
    SetVector com{}, transform{}, linear{}, angular{}, force{}, torque{}, inertia{}, clear_force{}, clear_torque{};
    Valid body_valid{}, shape_valid{};
};
struct Watch { std::uintptr_t address{}; std::size_t size{}; std::array<unsigned char, 16> bytes{}; };
struct Anchor {
    std::uintptr_t client{}, context{}, entity{}, core{}, skater_context{}, rig{}, world{}, state{};
    std::array<Watch, 128> watches{};
    std::size_t count{};
    std::array<std::uintptr_t, 32> wrappers{};
    bool same(const Anchor& b) const noexcept {
        return client == b.client && context == b.context && entity == b.entity && core == b.core &&
            skater_context == b.skater_context && rig == b.rig && world == b.world && state == b.state;
    }
};
struct Clock {
    SRWLOCK lock = SRWLOCK_INIT;
    std::atomic<std::uint64_t> sequence{};
    NoBailSkater owner{};
    std::uintptr_t game_context{}, world{}, state{};
    std::uint64_t serial{}, observed{};
    double time{};
    float seconds{};
};
struct Slot {
    std::uint64_t owner{};
    Handle handle{};
    Definition definition{};
    Anchor anchor{};
    NativeHandle body{};
    std::array<NativeHandle, maximum_capsules> shapes{};
    std::size_t made{};
    bool attempted{}, body_observed{}, active{}, retained{}, quarantined{}, creation_failed{};
    AllocationProgress allocation{};
    std::uint64_t release_hold{};
    bool release_requested{};
    std::uint64_t parked_ms{}; // immutable successful retained park; never slot reuse
    Sample latest{};
    Mailbox mailbox{};
};
// One finite diagnostic uses existing opaque owned-body ownership. It is not
// a second actor owner, follow lease or reusable native body allocation.
struct SyncProbe {
    std::uint64_t owner{}, sequence{}, world_generation{}, opened_ms{}, deadline{};
    Handle handle{};
    actor_control_native::Actor actor{};
    std::uintptr_t packets{};
    body_sync_probe::Result result{};
    std::array<NativeHandle, 4> bodies{};
};
struct SyncBefore {
    std::uint64_t owner{}, sequence{}, world_generation{}, deadline{};
    Handle handle{};
    actor_control_native::Actor actor{};
    NativeHandle body{};
    std::uintptr_t incoming{}, wrapper{}, packets{};
    std::size_t index{};
    body_sync_probe::Record record{};
    bool ready{};
};
struct Service {
    SRWLOCK lock = SRWLOCK_INIT;
    Api api{};
    std::array<Slot, retained_capacity> slots{};
    std::atomic<Synchronize> original{};
    std::atomic<bool> hooked{};
    bool hook_attempted{}, listener{}, initialization_requested{};
    std::uintptr_t base{}, client{}, world{}, state{}, context{};
    DWORD thread{};
    bool eligible{};
    std::uint64_t generation{}, world_generation{}, tick_at{}, command_sequence{};
    std::uint64_t release_generation{}; // process lifetime, never wraps
    SyncProbe probe{};
    std::uint32_t probe_generation{};
    // High32 is the immutable probe generation, low32 a bounded loss count.
    // Old callbacks cannot attribute a loss to a replacement probe.
    std::atomic<std::uint64_t> probe_losses{};
    // Each fixed counter has its own generation tag. A delayed old callback
    // cannot count against a replacement probe or mutate a terminal copy.
    std::array<std::atomic<std::uint64_t>, 8> probe_routes{};
    std::atomic<std::uint32_t> probe_live{};
};
// Static fixed storage exists before any hook can run. Physics callbacks never construct
// a function-local singleton, allocate, format text, call Lua or wait for a lock.
Service service;
Clock clock_feed;
// Shared read-only clock setup need not install the owned-body synchronizer
// or create a capsule. The client publishes only the checked world reader.
std::atomic<World> clock_world{};
void motion_tick(std::uintptr_t base, bool ready) noexcept;
void sync_capture_routes(SyncProbe& probe) noexcept;
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
struct LastError { DWORD value = GetLastError(); ~LastError() { SetLastError(value); } };
struct Locked { SRWLOCK& lock; explicit Locked(SRWLOCK& value) : lock(value) { AcquireSRWLockExclusive(&lock); } ~Locked() { ReleaseSRWLockExclusive(&lock); } };
template<class T> bool peek(std::uintptr_t at, T& value) noexcept { return memory::peek_bytes(at, &value, sizeof(value)); }
bool pointer(std::uintptr_t p) noexcept { return p >= 0x10000 && p < memory::highest_user_address - 0x20000; }
bool watched(const Anchor& a) noexcept {
    if (!a.count || a.count > a.watches.size()) return false;
    for (std::size_t i = 0; i < a.count; ++i) {
        const auto& w = a.watches[i]; std::array<unsigned char, 16> bytes{};
        if (!w.size || w.size > bytes.size() || !memory::peek_bytes(w.address, bytes.data(), w.size) || bytes != w.bytes) return false;
    }
    return true;
}
struct ReadFailure {};
struct Reader {
    Anchor& anchor;
    template<class T> T get(std::uintptr_t at) {
        static_assert(sizeof(T) <= 16);
        T value{};
        if (!pointer(at) || !peek(at, value) || anchor.count == anchor.watches.size()) throw ReadFailure{};
        auto& watch = anchor.watches[anchor.count++]; watch.address = at; watch.size = sizeof(T);
        std::memcpy(watch.bytes.data(), &value, sizeof(T)); return value;
    }
    std::uintptr_t ptr(std::uintptr_t at) { return get<std::uintptr_t>(at); }
};
void require(bool value) { if (!value) throw ReadFailure{}; }
bool native_world(World call, std::uintptr_t context, std::uintptr_t& out) noexcept {
    __try { out = call(context); return pointer(out); } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool valid_handle(Valid call, const NativeHandle& h) noexcept {
    __try { return pointer(h.world) && h.index != 0xffffffffU && call(&h); } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool allocate(const Api& a, std::uintptr_t world, NativeHandle& out) noexcept {
    __try { return a.allocate(world, &out) == &out && out.world == world && valid_handle(a.body_valid, out); }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool set_int(SetInt call, NativeHandle& h, int value) noexcept {
    __try { call(&h, value); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool scalar(SetFloat call, NativeHandle& h, float value) noexcept {
    __try { call(&h, value); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool vector(SetVector call, NativeHandle& h, const float* value) noexcept {
    __try { call(&h, value); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool touch(Touch call, NativeHandle& h) noexcept {
    __try { call(&h); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool mask(SetMask call, NativeHandle& h, std::uint32_t value) noexcept {
    __try { call(&h, &value); return true; } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool clear_owner(SetOwner call, NativeHandle& h) noexcept {
    __try { const NativeHandle none{h.world, 0xffffffffU, 0}; call(&h, &none); return true; }
    __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool capsule(const Api& a, Slot& slot, std::size_t index) noexcept {
    const auto& definition = slot.definition.capsules[index];
    alignas(16) const V4 bottom{definition.a[0], definition.a[1], definition.a[2], 0};
    alignas(16) const V4 top{definition.b[0], definition.b[1], definition.b[2], 0};
    __try {
        auto& shape = slot.shapes[index];
        return a.capsule(slot.anchor.world, &shape, &slot.body, bottom.data(), top.data(), definition.radius) == &shape &&
            shape.world == slot.anchor.world && valid_handle(a.shape_valid, shape);
    } __except (EXCEPTION_EXECUTE_HANDLER) { return false; }
}
bool matches(std::uintptr_t base, const game::build::Fingerprint& f) noexcept {
    std::array<unsigned char, 32> actual{};
    return memory::peek_bytes(base + f.rva, actual.data(), actual.size()) && actual == f.bytes;
}
bool resolve(std::uintptr_t base, Api& a) noexcept {
    if (!supported_build::running_image_matches(base)) return false;
    for (const auto* f : {&c::physics_world, &c::allocate_body, &c::create_capsule, &c::set_motion_type,
        &c::set_body_980, &c::clear_body_aa0, &c::set_categories, &c::set_collides_with, &c::set_shape_owner,
        &c::set_center_of_mass, &c::set_transform, &c::set_linear_velocity, &c::set_angular_velocity,
        &c::wake_body, &c::body_valid, &c::shape_valid, &r::linear_force, &r::angular_torque,
        &r::body_reset, &r::body_quaternion, &r::set_inertia_ratio, &r::overwrite_force, &r::overwrite_torque,
        &r::synchronizer}) if (!matches(base, *f)) return false;
    a.base = base; a.world = reinterpret_cast<World>(base + c::physics_world.rva);
    a.allocate = reinterpret_cast<Allocate>(base + c::allocate_body.rva); a.capsule = reinterpret_cast<CapsuleCall>(base + c::create_capsule.rva);
    a.motion = reinterpret_cast<SetInt>(base + c::set_motion_type.rva); a.inverse_mass = reinterpret_cast<SetFloat>(base + c::set_body_980.rva);
    a.clear = reinterpret_cast<Touch>(base + c::clear_body_aa0.rva); a.wake = reinterpret_cast<Touch>(base + c::wake_body.rva);
    a.categories = reinterpret_cast<SetMask>(base + c::set_categories.rva); a.collides = reinterpret_cast<SetMask>(base + c::set_collides_with.rva);
    a.owner = reinterpret_cast<SetOwner>(base + c::set_shape_owner.rva); a.com = reinterpret_cast<SetVector>(base + c::set_center_of_mass.rva);
    a.transform = reinterpret_cast<SetVector>(base + c::set_transform.rva); a.linear = reinterpret_cast<SetVector>(base + c::set_linear_velocity.rva);
    a.angular = reinterpret_cast<SetVector>(base + c::set_angular_velocity.rva); a.force = reinterpret_cast<SetVector>(base + r::linear_force.rva);
    a.torque = reinterpret_cast<SetVector>(base + r::angular_torque.rva); a.inertia = reinterpret_cast<SetVector>(base + r::set_inertia_ratio.rva);
    a.clear_force = reinterpret_cast<SetVector>(base + r::overwrite_force.rva); a.clear_torque = reinterpret_cast<SetVector>(base + r::overwrite_torque.rva);
    a.body_valid = reinterpret_cast<Valid>(base + c::body_valid.rva); a.shape_valid = reinterpret_cast<Valid>(base + c::shape_valid.rva);
    return true;
}
bool client_context(const Anchor& a) noexcept {
    std::uint32_t index{}, phase{}; std::uintptr_t tls{}, current{}, context{}; std::uint8_t active{};
    return peek(a.client + r::client_context, context) && context == a.context &&
        peek(a.client + r::client_phase, phase) && (phase == 13 || phase == 21) &&
        peek(service.base + e::tls_index, index) && index <= 4095 &&
        peek(static_cast<std::uintptr_t>(__readgsqword(0x58)) + std::uintptr_t{index} * sizeof(std::uintptr_t), tls) && pointer(tls) &&
        peek(tls + r::tls_active, active) && active && peek(tls + r::tls_context, current) && current == a.context;
}
bool capture(Anchor& a) noexcept {
    try {
        a = {}; a.client = service.client; Reader reader{a};
        const auto ptr = [&](std::uintptr_t at) { return reader.ptr(at); };
        const auto u32 = [&](std::uintptr_t at) { return reader.get<std::uint32_t>(at); };
        const auto u8 = [&](std::uintptr_t at) { return reader.get<std::uint8_t>(at); };
        require(ptr(a.client) == service.base + e::client_vtable);
        a.context = ptr(a.client + r::client_context);
        const auto phase = u32(a.client + r::client_phase); require(phase == 13 || phase == 21);
        const auto offset = u32(service.base + e::context_player_manager_offset); require(offset <= 0x1000000);
        const auto manager = ptr(a.context + offset); require(ptr(manager) == service.base + e::local_player_manager_vtable);
        const auto begin = ptr(manager + r::player_begin), end = ptr(manager + r::player_end);
        require(pointer(begin) && end == begin + sizeof(std::uintptr_t));
        const auto player = ptr(begin);
        require(ptr(player) == service.base + e::local_player_vtable && ptr(player + r::player_context) == a.context &&
            u8(player + r::player_local) == 1 && u8(player + r::player_remote) == 0);
        a.entity = ptr(player + r::player_entity); const auto handle = ptr(player + r::player_handle);
        require(ptr(a.entity) == service.base + e::skater_entity_vtable && ptr(a.entity + r::entity_context) == a.context &&
            ptr(a.entity + r::entity_player) == player && ptr(handle) == a.entity + sizeof(std::uintptr_t) && u8(a.entity + r::entity_teleport) == 0);
        const auto collection = ptr(a.entity + r::entity_collection), component = ptr(a.entity + r::entity_component);
        require(ptr(collection) == a.entity && ptr(component) == service.base + e::skater_component_vtable && ptr(component + r::component_collection) == collection);
        a.core = ptr(component + r::component_core); a.skater_context = ptr(a.core + r::core_context); a.rig = ptr(a.core + r::core_rig);
        require(ptr(a.core) == service.base + addr::no_bail::bail_core_vtable && ptr(a.rig) == a.skater_context && ptr(a.rig + r::rig_core) == a.core);
        const auto board = ptr(ptr(a.core + k::board_holder_offset) + k::board_physics_offset), rig = ptr(a.rig + k::rig_physics_offset);
        require(ptr(board) == service.base + k::board_physics_vtable && ptr(rig) == service.base + k::rig_physics_vtable);
        const auto board_parts = ptr(board + k::physics_bodies_offset), rig_parts = ptr(rig + k::physics_bodies_offset);
        require(u32(board_parts) == k::board_body_count && u32(rig_parts) == k::rig_body_count);
        for (std::size_t i = 0; i < a.wrappers.size(); ++i) {
            const auto part = i < 9 ? board_parts + i * k::physics_body_size : rig_parts + (i - 8) * k::physics_body_size;
            require(ptr(part + k::body_owner_offset) == (i < 9 ? board : rig)); a.wrappers[i] = part + k::body_owner_offset;
        }
        require(client_context(a) && native_world(service.api.world, a.context, a.world));
        require(peek(a.world + r::world_state, a.state) && pointer(a.state));
        return watched(a) && client_context(a);
    } catch (...) { return false; }
}
void physics_step(const NoBailSkater& owner, float seconds, bool) noexcept {
    const auto sequence = clock_feed.sequence.fetch_add(1, std::memory_order_acq_rel) + 1;
    std::uintptr_t context{}, world{}, state{};
    const auto world_call = clock_world.load(std::memory_order_acquire);
    if (!world_call || !calibrated(seconds) || !peek(owner.entity + r::entity_context, context) || !pointer(context) ||
        !native_world(world_call, context, world) || !peek(world + r::world_state, state) || !pointer(state) ||
        !TryAcquireSRWLockExclusive(&clock_feed.lock)) return;
    auto& f = clock_feed;
    if (f.owner.entity != owner.entity || f.owner.core != owner.core || f.owner.context != owner.context || f.owner.rig != owner.rig ||
        f.game_context != context || f.world != world || f.state != state) f.time = 0;
    f.owner = owner; f.serial = sequence; f.time += seconds; f.seconds = seconds; f.observed = GetTickCount64();
    f.game_context = context; f.world = world; f.state = state;
    ReleaseSRWLockExclusive(&f.lock);
}
bool clock(const Anchor& a, Epoch& epoch, std::uint64_t* observed = nullptr) noexcept {
    if (observed) *observed = 0;
    if (!TryAcquireSRWLockShared(&clock_feed.lock)) return false;
    const auto& f = clock_feed;
    const bool ok = f.owner.base == service.base && f.owner.entity == a.entity && f.owner.core == a.core &&
        f.owner.context == a.skater_context && f.owner.rig == a.rig && f.game_context == a.context && f.world == a.world && f.state == a.state &&
        f.serial && f.serial == f.sequence.load(std::memory_order_acquire) && GetTickCount64() - f.observed < 250 &&
        calibrated(f.seconds) && std::isfinite(f.time);
    if (ok) {
        epoch.serial = f.serial; epoch.time = f.time; epoch.seconds = f.seconds;
        if (observed) *observed = f.observed;
    }
    ReleaseSRWLockShared(&clock_feed.lock);
    float h{}; return ok && peek(a.skater_context + r::context_seconds, h) && calibrated(h);
}
bool allocated(std::uintptr_t state, std::uint32_t index, bool dynamic = false) noexcept {
    std::uint32_t capacity{}, again{}, bits{}, check_bits{}, dynamic_bits{}, dynamic_check{};
    std::uintptr_t source{}, check{}, dynamics{}, dynamics_again{};
    const auto word = std::uintptr_t{index >> 5} * sizeof(std::uint32_t); const auto bit = 1U << (index & 31U);
    if (!peek(state + r::body_capacity, capacity) || !capacity || capacity > 1048576 || index >= capacity ||
        !peek(state + r::allocated_bits, source) || !pointer(source) || !peek(source + word, bits) || !(bits & bit)) return false;
    if (dynamic && (!peek(state + r::dynamic_bits, dynamics) || !pointer(dynamics) || !peek(dynamics + word, dynamic_bits) || !(dynamic_bits & bit))) return false;
    return peek(state + r::body_capacity, again) && again == capacity && peek(state + r::allocated_bits, check) && check == source &&
        peek(source + word, check_bits) && check_bits == bits && (!dynamic || (peek(state + r::dynamic_bits, dynamics_again) &&
        dynamics_again == dynamics && peek(dynamics + word, dynamic_check) && dynamic_check == dynamic_bits));
}
bool anchor_current(const Anchor& a) noexcept {
    std::uintptr_t world{}, state{};
    return watched(a) && client_context(a) && native_world(service.api.world, a.context, world) && world == a.world &&
        peek(world + r::world_state, state) && state == a.state && watched(a);
}
bool body_current(const Slot& s, bool dynamic = false) noexcept {
    return s.body_observed && anchor_current(s.anchor) && s.body.world == s.anchor.world && allocated(s.anchor.state, s.body.index, dynamic) &&
        valid_handle(service.api.body_valid, s.body) && anchor_current(s.anchor) && allocated(s.anchor.state, s.body.index, dynamic);
}
bool array4(std::uintptr_t state, std::uintptr_t offset, std::uint32_t index, V4& value, std::uintptr_t& source) noexcept {
    std::uintptr_t check{};
    if (!peek(state + offset, source) || !pointer(source) || !peek(source + std::uintptr_t{index} * sizeof(V4), value) ||
        !peek(state + offset, check) || check != source) return false;
    for (float v : value) if (!std::isfinite(v) || std::abs(v) > 1000000) return false;
    return true;
}
bool configured(const Slot& s) noexcept {
    const auto& d = s.definition; V4 ratio{}, again{}; std::uintptr_t source{}, source_again{}, masses{}, masses_again{}; float inverse{}, inverse_again{};
    const V4 expected{d.mass / d.inertia[0], d.mass / d.inertia[1], d.mass / d.inertia[2], 0};
    return array4(s.anchor.state, r::inertia_ratio_array, s.body.index, ratio, source) && ratio == expected &&
        peek(s.anchor.state + r::inverse_mass_array, masses) && pointer(masses) && peek(masses + std::uintptr_t{s.body.index} * 4, inverse) && inverse == 1.f / d.mass &&
        array4(s.anchor.state, r::inertia_ratio_array, s.body.index, again, source_again) && source == source_again && ratio == again &&
        peek(s.anchor.state + r::inverse_mass_array, masses_again) && masses_again == masses &&
        peek(masses + std::uintptr_t{s.body.index} * 4, inverse_again) && inverse_again == inverse;
}
bool shape_current(const Slot& s, std::size_t i, bool masks = true) noexcept {
    if (i >= s.made || !body_current(s) || s.shapes[i].world != s.anchor.world || !valid_handle(service.api.shape_valid, s.shapes[i])) return false;
    if (!masks) return anchor_current(s.anchor);
    std::uintptr_t owners{}, categories{}, with{}; std::uint32_t owner{}, category{}, collides{};
    const auto offset = std::uintptr_t{s.shapes[i].index} * 4;
    return peek(s.anchor.state + r::shape_owners, owners) && pointer(owners) && peek(owners + offset, owner) && owner == 0xffffffffU &&
        peek(s.anchor.state + r::shape_categories, categories) && pointer(categories) && peek(categories + offset, category) && category == r::safe_categories &&
        peek(s.anchor.state + r::shape_collides, with) && pointer(with) && peek(with + offset, collides) &&
        (collides == 0 || collides == r::safe_world_collisions) && body_current(s);
}
bool pool_current(const Slot& s, bool dynamic = false) noexcept {
    if (!body_current(s, dynamic) || s.made != s.definition.count || !configured(s)) return false;
    for (std::size_t i = 0; i < s.made; ++i) if (!shape_current(s, i)) return false;
    return body_current(s, dynamic);
}
bool producer_owner(const Slot& s, const NativeHandle& incoming) noexcept {
    if (!pool_current(s, true) || incoming.world != s.anchor.world || !allocated(s.anchor.state, incoming.index) || !valid_handle(service.api.body_valid, incoming)) return false;
    for (std::size_t i = 0; i < s.made; ++i) {
        std::uintptr_t masks{}; std::uint32_t collides{};
        if (!peek(s.anchor.state + r::shape_collides, masks) || !pointer(masks) ||
            !peek(masks + std::uintptr_t{s.shapes[i].index} * 4, collides) || collides != r::safe_world_collisions) return false;
    }
    return pool_current(s, true) && allocated(s.anchor.state, incoming.index) && valid_handle(service.api.body_valid, incoming);
}
bool pending_zero(const Slot& s) noexcept {
    V4 force{}, torque{}; std::uintptr_t a{}, b{};
    return array4(s.anchor.state, r::pending_force, s.body.index, force, a) && force == V4{} &&
        array4(s.anchor.state, r::pending_torque, s.body.index, torque, b) && torque == V4{};
}
bool park(Slot& s) noexcept {
    s.mailbox.cancel();
    if (!body_current(s)) return false;
    for (std::size_t i = 0; i < s.made; ++i)
        if (!shape_current(s, i) || !mask(service.api.categories, s.shapes[i], 0) || !shape_current(s, i) ||
            !mask(service.api.collides, s.shapes[i], 0) || !shape_current(s, i)) return false;
    for (std::size_t i = 0; i < s.made; ++i) {
        std::uintptr_t categories{}, with{}; std::uint32_t category{}, collides{};
        const auto offset = std::uintptr_t{s.shapes[i].index} * 4;
        if (!body_current(s) || !peek(s.anchor.state + r::shape_categories, categories) || !pointer(categories) ||
            !peek(categories + offset, category) || category != 0 || !peek(s.anchor.state + r::shape_collides, with) || !pointer(with) ||
            !peek(with + offset, collides) || collides != 0 || !shape_current(s, i)) return false;
    }
    alignas(16) const V4 zero{};
    if (allocated(s.anchor.state, s.body.index, true) && (!vector(service.api.clear_force, s.body, zero.data()) || !body_current(s) ||
        !vector(service.api.clear_torque, s.body, zero.data()) || !body_current(s))) return false;
    return pending_zero(s) && vector(service.api.linear, s.body, zero.data()) && body_current(s) &&
        vector(service.api.angular, s.body, zero.data()) && body_current(s) && set_int(service.api.motion, s.body, 2) && body_current(s) && pending_zero(s);
}
void retire(Slot& s, bool may_park) noexcept {
    if (service.probe.owner == s.owner && service.probe.handle == s.handle &&
        service.probe.result.status == body_sync_probe::Status::pending) {
        service.probe.result.status = body_sync_probe::Status::invalidated;
        service.probe_live.store(0, std::memory_order_release);
        sync_capture_routes(service.probe);
    }
    s.mailbox.cancel();
    // A dependent native service owns release ordering, including VM unload.
    // Retain active SDK allocation state for its cleanup-only basis capture.
    if (s.release_hold) { s.release_requested = true; return; }
    const bool parked = may_park && park(s);
    s.active = false; s.retained = true; s.quarantined = s.allocation.quarantine(parked); s.latest = {};
    s.parked_ms = s.quarantined ? 0 : GetTickCount64();
    // No qualified native destructor exists. This slot is never recycled and its old
    // handles are never adopted by another owner, even after a level reload.
}
bool command_clock(const Slot& s, Epoch& out) noexcept {
    out.world = s.latest.epoch.world; out.body = s.handle.generation;
    return clock(s.anchor, out);
}
void produce(NativeHandle* incoming_pointer, std::uintptr_t wrapper) noexcept {
    if (!service.hooked.load(std::memory_order_acquire) || !TryAcquireSRWLockExclusive(&service.lock)) return;
    for (auto& s : service.slots) {
        if (!s.active || s.release_requested || !s.mailbox.pending) continue;
        if (GetTickCount64() >= s.mailbox.deadline) { Command ignored; (void)s.mailbox.consume(s.mailbox.command.epoch, GetTickCount64(), ignored); continue; }
        if (std::find(s.anchor.wrappers.begin(), s.anchor.wrappers.end(), wrapper) == s.anchor.wrappers.end()) continue;
        NativeHandle incoming{}; Epoch current{};
        if (!peek(reinterpret_cast<std::uintptr_t>(incoming_pointer), incoming) || !producer_owner(s, incoming) || !command_clock(s, current)) {
            s.mailbox.cancel(); s.quarantined = true; s.active = false; continue;
        }
        Command command{};
        if (!s.mailbox.consume(current, GetTickCount64(), command)) continue;
        Vec force = command.force;
        for (std::size_t i = 0; i < 3; ++i) force[i] += command.impulse[i] / command.epoch.seconds;
        alignas(16) const V4 f{force[0], force[1], force[2], 0}, t{command.torque[0], command.torque[1], command.torque[2], 0};
        const auto qualified = [&]() noexcept {
            Epoch epoch{}; return GetTickCount64() < s.mailbox.deadline && command_clock(s, epoch) && epoch == current && producer_owner(s, incoming);
        };
        bool attempted_force{}, attempted_torque{}, ok{};
        if (qualified()) {
            attempted_force = true;
            if (vector(service.api.force, s.body, f.data()) && qualified()) {
                attempted_torque = true;
                ok = vector(service.api.torque, s.body, t.data()) && qualified();
            }
        }
        s.mailbox.finish(attempted_force, attempted_torque, ok);
        if (!ok) { s.quarantined = true; s.active = false; }
    }
    ReleaseSRWLockExclusive(&service.lock);
}
std::uintptr_t synchronize_hook(NativeHandle* incoming, std::uintptr_t wrapper);
bool initialize() noexcept {
    if (service.hook_attempted) return service.hooked.load(std::memory_order_acquire);
    service.hook_attempted = true;
    if (!resolve(service.base, service.api)) return false;
    clock_world.store(service.api.world, std::memory_order_release);
    const auto init = hook_initialize(); if (init != HookOk && init != HookAlreadyInitialized) return false;
    void* original{}; auto* target = reinterpret_cast<void*>(service.base + r::synchronizer.rva);
    if (hook_prepare(target, reinterpret_cast<void*>(&synchronize_hook), &original) != HookOk || !original) return false;
    service.original.store(reinterpret_cast<Synchronize>(original), std::memory_order_release);
    {
        HookBatch batch;
        if (hook_enable(target) != HookOk || !start_no_bail(service.base)) return false;
    }
    // After the batch, the existing attached target answers without another transaction.
    if (hook_enable(target) != HookOk || !add_no_bail_step_listener(&physics_step)) return false;
    service.listener = true; service.hooked.store(true, std::memory_order_release); return true;
}
bool eligible() noexcept {
    if (!service.eligible || GetCurrentThreadId() != service.thread || GetTickCount64() - service.tick_at >= 250) return false;
    try { const auto mp = multiplayer::model(); return !mp.active && !mp.lobby_joining; } catch (...) { return false; }
}
Slot* lookup(std::uint64_t owner, const Handle& handle) noexcept {
    if (!owner || !handle.generation || handle.slot >= service.slots.size()) return nullptr;
    auto& s = service.slots[handle.slot]; return s.attempted && s.owner == owner && s.handle == handle ? &s : nullptr;
}
bool fresh(const Slot& s) noexcept {
    Anchor a; return eligible() && capture(a) && s.anchor.same(a) && pool_current(s, s.active);
}
struct Ring {
    std::uintptr_t values{}; std::uint32_t elements{}; std::uint16_t current{}, planes{};
    bool operator==(const Ring&) const = default;
};
static_assert(sizeof(Ring) == 16);
bool ring(const Slot& s, std::uintptr_t offset, Ring& header, V4& value) noexcept {
    if (!peek(s.anchor.state + offset, header) || !pointer(header.values) || !header.elements || header.elements > 1048576 ||
        s.body.index >= header.elements || !header.planes || header.planes > 64 || header.current >= header.planes) return false;
    const std::uint32_t quads = header.elements * 4;
    const std::uint32_t bytes = (((quads & 0x7ffffffU) * 4 + 0x3cU) & 0xffffffc0U);
    const auto at = header.values + std::uintptr_t{bytes} * header.current + std::uintptr_t{s.body.index} * sizeof(V4);
    if (at < header.values || !peek(at, value)) return false;
    for (float v : value) if (!std::isfinite(v) || std::abs(v) > 1000000) return false;
    return true;
}
// Callers select their admission edge. Both paths use the same bounded native
// ring/layout checks; neither publishes latest or observes mailbox receipts.
template<class Qualify>
bool observe_checked(const Slot& s, Sample& out, Qualify qualify) noexcept {
    Epoch before{}; before.world = service.world_generation; before.body = s.handle.generation;
    if (!qualify(s) || !clock(s.anchor, before)) return false;
    const std::array<std::uintptr_t, 4> offsets{r::position_ring, r::rotation_ring, r::velocity_ring, r::spin_ring};
    std::array<Ring, 4> headers{}; std::array<V4, 4> values{};
    for (std::size_t i = 0; i < offsets.size(); ++i) if (!ring(s, offsets[i], headers[i], values[i])) return false;
    double norm{}; for (float v : values[1]) norm += static_cast<double>(v) * v;
    if (norm < .9 || norm > 1.1) return false;
    for (std::size_t i = 2; i < 4; ++i) for (float v : values[i]) if (std::abs(v) > 100) return false;
    V4 com{}, local{}, ratio{}; std::uintptr_t com_source{}, local_source{}, ratio_source{}, masses{}; float inverse{};
    if (!array4(s.anchor.state, r::local_com, s.body.index, com, com_source) || com != V4{} ||
        !array4(s.anchor.state, r::local_rotation, s.body.index, local, local_source) || local != V4{1, 0, 0, 0} ||
        !array4(s.anchor.state, r::inertia_ratio_array, s.body.index, ratio, ratio_source) ||
        !peek(s.anchor.state + r::inverse_mass_array, masses) || !pointer(masses) ||
        !peek(masses + std::uintptr_t{s.body.index} * 4, inverse) || !std::isfinite(inverse) || inverse <= 0) return false;
    for (unsigned pass = 0; pass < 2; ++pass) {
        for (std::size_t i = 0; i < offsets.size(); ++i) {
            Ring again; V4 value{}; if (!ring(s, offsets[i], again, value) || headers[i] != again || values[i] != value) return false;
        }
        V4 value{}; std::uintptr_t source{};
        if (!array4(s.anchor.state, r::local_com, s.body.index, value, source) || source != com_source || value != com ||
            !array4(s.anchor.state, r::local_rotation, s.body.index, value, source) || source != local_source || value != local || !configured(s)) return false;
        std::uintptr_t inverse_source{}; float inverse_again{};
        if (!array4(s.anchor.state, r::inertia_ratio_array, s.body.index, value, source) || source != ratio_source || value != ratio ||
            !peek(s.anchor.state + r::inverse_mass_array, inverse_source) || inverse_source != masses ||
            !peek(inverse_source + std::uintptr_t{s.body.index} * 4, inverse_again) || inverse_again != inverse) return false;
    }
    Epoch after{}; after.world = service.world_generation; after.body = s.handle.generation;
    if (!qualify(s) || !clock(s.anchor, after) || after != before) return false;
    out = {}; out.epoch = after;
    for (std::size_t i = 0; i < 3; ++i) { out.position[i] = values[0][i]; out.velocity[i] = values[2][i]; out.angular_velocity[i] = values[3][i]; }
    out.rotation = {values[1][1], values[1][2], values[1][3], values[1][0]};
    out.mass = 1.f / inverse;
    for (std::size_t i = 0; i < 3; ++i) out.inertia[i] = 1.f / (inverse * ratio[i]);
    return true;
}
// Caller holds service.lock. This is the native callback admission, not the
// client API: fresh()/eligible()/capture() can query a model or block.
bool callback_source_current(const Slot& s) noexcept {
    const auto now = GetTickCount64();
    if (!service.hooked.load(std::memory_order_acquire) || service.api.base != service.base ||
        !service.eligible || now < service.tick_at || now - service.tick_at >= 250 ||
        !s.active || s.retained || s.quarantined || s.release_requested || !producer_owner(s, s.body)) return false;
    std::uintptr_t generations{}, again{}, state{}; std::uint32_t generation{}, after{};
    const auto offset = std::uintptr_t{s.body.index} * sizeof(std::uint32_t);
    return peek(s.body.world + r::world_state, state) && state == s.anchor.state &&
        peek(s.body.world + r::world_body_generations, generations) && pointer(generations) &&
        peek(generations + offset, generation) && generation == s.body.generation &&
        producer_owner(s, s.body) &&
        peek(s.body.world + r::world_body_generations, again) && again == generations &&
        peek(generations + offset, after) && after == generation &&
        peek(s.body.world + r::world_state, state) && state == s.anchor.state;
}
bool observe_callback(const Slot& s, Sample& out) noexcept {
    return observe_checked(s, out, [](const Slot& slot) noexcept { return callback_source_current(slot); });
}
// Client API retains its original full client/model admission checks.
bool observe(const Slot& s, Sample& out) noexcept {
    return observe_checked(s, out, [](const Slot& slot) noexcept { return fresh(slot); });
}
bool sample(Slot& s, Sample& out) noexcept {
    if (!observe(s, out)) return false;
    s.latest = out;
    (void)s.mailbox.observe_successor(out);
    return true;
}
bool create_native(Slot& s) noexcept {
    if (!anchor_current(s.anchor) || !allocate(service.api, s.anchor.world, s.body)) return false;
    s.body_observed = true;
    s.allocation.body_confirmed = true;
    // Do not configure an unexpected allocation or infer that a zero handle is a body.
    // These are the constructor defaults the existing qualified body path requires.
    V4 initial_ratio{}, initial_com{}, initial_local{};
    std::uintptr_t source{}, masses{}; float inverse{};
    if (!body_current(s) || !array4(s.anchor.state, r::inertia_ratio_array, s.body.index, initial_ratio, source) || initial_ratio != V4{1, 1, 1, 0} ||
        !array4(s.anchor.state, r::local_com, s.body.index, initial_com, source) || initial_com != V4{} ||
        !array4(s.anchor.state, r::local_rotation, s.body.index, initial_local, source) || initial_local != V4{1, 0, 0, 0} ||
        !peek(s.anchor.state + r::inverse_mass_array, masses) || !pointer(masses) ||
        !peek(masses + std::uintptr_t{s.body.index} * 4, inverse) || inverse != 1 || !pending_zero(s) || !body_current(s)) return false;
    constexpr std::array<std::uintptr_t, 4> rings{r::position_ring, r::rotation_ring, r::velocity_ring, r::spin_ring};
    for (std::size_t i = 0; i < rings.size(); ++i) {
        Ring header; V4 value{}; if (!ring(s, rings[i], header, value)) return false;
        if (i == 1) { double norm{}; for (float v : value) norm += static_cast<double>(v) * v; if (norm < .9 || norm > 1.1) return false; }
        if (i >= 2) for (float v : value) if (std::abs(v) > 100) return false;
    }
    alignas(16) const V4 zero{}, ratio{s.definition.mass / s.definition.inertia[0], s.definition.mass / s.definition.inertia[1], s.definition.mass / s.definition.inertia[2], 0};
    if (!body_current(s) || !set_int(service.api.motion, s.body, 2) || !body_current(s) ||
        !scalar(service.api.inverse_mass, s.body, 1.f / s.definition.mass) || !body_current(s) ||
        !vector(service.api.inertia, s.body, ratio.data()) || !body_current(s) || !configured(s) ||
        !touch(service.api.clear, s.body) || !body_current(s) || !vector(service.api.com, s.body, zero.data()) || !body_current(s)) return false;
    for (std::size_t i = 0; i < s.definition.count; ++i) {
        if (!body_current(s)) return false;
        ++s.allocation.shapes_attempted;
        if (!capsule(service.api, s, i)) return false;
        ++s.made;
        ++s.allocation.shapes_confirmed;
        for (std::size_t j = 0; j < i; ++j) if (s.shapes[i] == s.shapes[j]) return false;
        if (!shape_current(s, i, false) || !clear_owner(service.api.owner, s.shapes[i]) || !shape_current(s, i, false) ||
            !mask(service.api.categories, s.shapes[i], r::safe_categories) || !shape_current(s, i, false) ||
            !mask(service.api.collides, s.shapes[i], 0) || !shape_current(s, i)) return false;
    }
    const auto& d = s.definition;
    alignas(16) const std::array<float, 8> pose{d.rotation[0], d.rotation[1], d.rotation[2], d.rotation[3], d.position[0], d.position[1], d.position[2], 1};
    if (!pool_current(s) || !pending_zero(s) || !vector(service.api.transform, s.body, pose.data()) || !pool_current(s)) return false;
    for (std::size_t i = 0; i < s.made; ++i)
        if (!mask(service.api.collides, s.shapes[i], r::safe_world_collisions) || !shape_current(s, i)) return false;
    if (!set_int(service.api.motion, s.body, 3) || !pool_current(s, true) || !touch(service.api.wake, s.body) || !pool_current(s, true)) return false;
    s.active = true; return true;
}
} // namespace

const char* park_observation_check_name(ParkObservationCheck check) noexcept {
    switch (check) {
    case ParkObservationCheck::not_attempted: return "not_attempted";
    case ParkObservationCheck::passed: return "passed";
    case ParkObservationCheck::output_occupied: return "output_occupied";
    case ParkObservationCheck::owner: return "owner";
    case ParkObservationCheck::client_phase: return "client_phase";
    case ParkObservationCheck::world_lock: return "world_lock";
    case ParkObservationCheck::retained_identity: return "retained_identity";
    case ParkObservationCheck::fresh_allocation: return "fresh_allocation";
    case ParkObservationCheck::shape_identity: return "shape_identity";
    case ParkObservationCheck::clock_unavailable: return "clock_unavailable";
    case ParkObservationCheck::clock_serial: return "clock_serial";
    case ParkObservationCheck::clock_time: return "clock_time";
    case ParkObservationCheck::clock_after_fence: return "clock_after_fence";
    case ParkObservationCheck::clock_after_park: return "clock_after_park";
    case ParkObservationCheck::category_storage: return "category_storage";
    case ParkObservationCheck::collision_storage: return "collision_storage";
    case ParkObservationCheck::dynamic_storage: return "dynamic_storage";
    case ParkObservationCheck::dynamic_bit: return "dynamic_bit";
    case ParkObservationCheck::linear_read: return "linear_read";
    case ParkObservationCheck::linear_zero: return "linear_zero";
    case ParkObservationCheck::angular_read: return "angular_read";
    case ParkObservationCheck::angular_zero: return "angular_zero";
    case ParkObservationCheck::force_read: return "force_read";
    case ParkObservationCheck::force_zero: return "force_zero";
    case ParkObservationCheck::torque_read: return "torque_read";
    case ParkObservationCheck::torque_zero: return "torque_zero";
    case ParkObservationCheck::shape_category_read: return "shape_category_read";
    case ParkObservationCheck::shape_category_zero: return "shape_category_zero";
    case ParkObservationCheck::shape_collision_read: return "shape_collision_read";
    case ParkObservationCheck::shape_collision_zero: return "shape_collision_zero";
    case ParkObservationCheck::shape_current: return "shape_current";
    case ParkObservationCheck::categories_unchanged: return "categories_unchanged";
    case ParkObservationCheck::collisions_unchanged: return "collisions_unchanged";
    case ParkObservationCheck::dynamic_unchanged: return "dynamic_unchanged";
    case ParkObservationCheck::linear_header: return "linear_header";
    case ParkObservationCheck::linear_values: return "linear_values";
    case ParkObservationCheck::angular_header: return "angular_header";
    case ParkObservationCheck::angular_values: return "angular_values";
    case ParkObservationCheck::force_storage: return "force_storage";
    case ParkObservationCheck::force_values: return "force_values";
    case ParkObservationCheck::torque_storage: return "torque_storage";
    case ParkObservationCheck::torque_values: return "torque_values";
    case ParkObservationCheck::closing_clock: return "closing_clock";
    case ParkObservationCheck::closing_epoch: return "closing_epoch";
    case ParkObservationCheck::closing_stamp: return "closing_stamp";
    case ParkObservationCheck::clock_freshness: return "clock_freshness";
    }
    return "unknown";
}

void tick(std::uintptr_t base, std::uintptr_t client, bool ready) noexcept {
    LastError error;
    if (!service.thread) service.thread = GetCurrentThreadId();
    if (GetCurrentThreadId() != service.thread) return;
    bool prepare{};
    {
        Locked lock(service.lock);
        service.base = base; service.client = client; service.tick_at = GetTickCount64(); service.eligible = ready;
        motion_tick(base, eligible());
        if (service.probe.sequence && service.probe.result.status == body_sync_probe::Status::pending && service.tick_at >= service.probe.deadline) {
            const auto losses = service.probe_losses.load(std::memory_order_acquire);
            if ((losses >> 32) == service.probe.sequence) service.probe.result.dropped = static_cast<std::uint32_t>(losses);
            service.probe.result.status = body_sync_probe::Status::expired;
            service.probe_live.store(0, std::memory_order_release);
            sync_capture_routes(service.probe);
        }
        if (!eligible()) {
            service.initialization_requested = false;
            for (auto& s : service.slots) if (s.attempted && !s.retained) retire(s, false);
            service.world = service.state = service.context = 0;
            return;
        }
        prepare = service.initialization_requested && !service.hook_attempted;
        service.initialization_requested = false;
    }
    // Process-lifetime producer setup can suspend threads. It runs outside both
    // the plugin VM budget and this service lock, and never queues a definition
    // or allocates a plugin body. Only a later explicit create can do that.
    if (prepare) (void)initialize();
    Locked lock(service.lock);
    // Setup may be slow. Do not refresh tick_at to disguise stale readiness.
    if (!eligible()) {
        for (auto& s : service.slots) if (s.attempted && !s.retained) retire(s, false);
        service.world = service.state = service.context = 0;
        return;
    }
    if (!service.hooked.load(std::memory_order_acquire)) return;
    Anchor a;
    if (!capture(a)) { for (auto& s : service.slots) if (s.active) retire(s, false); return; }
    if (a.world != service.world || a.state != service.state || a.context != service.context) {
        for (auto& s : service.slots) if (s.attempted && !s.retained) retire(s, false);
        service.world = a.world; service.state = a.state; service.context = a.context; ++service.world_generation;
    }
    for (auto& s : service.slots) if (s.attempted && !s.retained) {
        if (!s.anchor.same(a)) retire(s, false);
        else if (!s.active || s.quarantined) retire(s, fresh(s));
    }
}
std::string prepare() noexcept {
    LastError error;
    try {
        if (!eligible()) return "owned bodies require the current local client phase outside multiplayer";
        Locked lock(service.lock);
        // The lock may have waited. Do not enqueue setup using stale or foreign
        // client readiness, even though preparation retains no body request.
        if (!eligible()) return "owned bodies require the current local client phase outside multiplayer";
        if (!service.hooked.load(std::memory_order_acquire)) {
            if (service.hook_attempted) return "native body ABI or producer hook unavailable; another producer may own it";
            service.initialization_requested = true;
            return "native body producer setup pending; call prepare again explicitly";
        }
        Anchor anchor; Epoch epoch;
        if (!capture(anchor) || !clock(anchor, epoch)) return "waiting for a fresh qualified 60 Hz physics step";
        // Readiness is sampled only. In particular, do not reconcile worlds,
        // retire prior slots, retain a definition, reserve a slot or allocate.
        return {};
    } catch (...) { return "native body preparation failed closed"; }
}
std::string create(std::uint64_t owner, const Definition& definition, Handle& out) noexcept {
    LastError error; out = {};
    try {
        if (!owner || !valid(definition)) return "invalid body definition";
        if (!eligible()) return "owned bodies require the current local client phase outside multiplayer";
        Locked lock(service.lock);
        if (!service.hooked.load(std::memory_order_acquire)) {
            if (service.hook_attempted) return "native body ABI or producer hook unavailable; another producer may own it";
            // Preparation is generic and process-lifetime: no owner, definition,
            // position or allocation request survives this refused call.
            service.initialization_requested = true;
            return "waiting for a fresh qualified 60 Hz physics step";
        }
        Anchor anchor; Epoch epoch;
        if (!capture(anchor) || !clock(anchor, epoch)) return "waiting for a fresh qualified 60 Hz physics step";
        if (anchor.world != service.world || anchor.state != service.state || anchor.context != service.context) {
            for (auto& s : service.slots) if (s.attempted && !s.retained) retire(s, false);
            service.world = anchor.world; service.state = anchor.state; service.context = anchor.context; ++service.world_generation;
        }
        for (const auto& prior : service.slots)
            if (prior.creation_failed && prior.anchor.world == anchor.world && prior.anchor.state == anchor.state && prior.anchor.context == anchor.context)
                return "a previous partial allocation in this world prohibits another native allocation";
        const auto at = std::find_if(service.slots.begin(), service.slots.end(), [](const Slot& s) { return !s.attempted; });
        if (at == service.slots.end()) return "the eight retained body slots are exhausted; native destruction is unproven";
        auto& s = *at; s.attempted = true; s.owner = owner; s.definition = definition; s.anchor = anchor;
        s.handle = {++service.generation, static_cast<std::uint32_t>(at - service.slots.begin())};
        if (!create_native(s)) {
            s.creation_failed = true; retire(s, anchor_current(s.anchor));
            return s.quarantined ? "partial native body creation retained in quarantine; allocation retry prohibited" :
                "partial native body creation retained and parked; allocation retry prohibited";
        }
        out = s.handle; return {};
    } catch (...) { return "native body creation failed closed"; }
}
std::string read(std::uint64_t owner, const Handle& handle, Sample& out) noexcept {
    LastError error; out = {};
    try {
        if (!eligible()) return "body observation unavailable in this client phase";
        Locked lock(service.lock); auto* s = lookup(owner, handle);
        if (!s || !s->active || s->retained || s->quarantined || s->release_requested) return "body owner or generation unavailable";
        if (!sample(*s, out)) return "body snapshot or native epoch changed; no sample published";
        return {};
    } catch (...) { return "native body observation failed closed"; }
}

bool capture_source(std::uint64_t owner, const Handle& handle, MeasuredSource& out) noexcept {
    LastError error; out = {};
    try {
        if (!eligible()) return false;
        Locked lock(service.lock);
        auto* s = lookup(owner, handle);
        if (!s || !s->active || s->retained || s->quarantined || s->release_requested || !producer_owner(*s, s->body)) return false;
        Epoch before{}; before.world = service.world_generation; before.body = handle.generation;
        std::uint64_t observed{};
        if (!clock(s->anchor, before, &observed)) return false;
        Sample measured{};
        // observe() does not publish latest or observe a mailbox successor.
        if (!observe(*s, measured) || measured.epoch != before) return false;
        Epoch after{}; after.world = service.world_generation; after.body = handle.generation;
        std::uint64_t observed_after{};
        if (!producer_owner(*s, s->body) || !clock(s->anchor, after, &observed_after) ||
            after != before || observed_after != observed) return false;
        const auto now = GetTickCount64();
        if (!observed || now < observed || now - observed >= command_lifetime_ms) return false;
        MeasuredSource value;
        value.owner_ = owner; value.handle_ = handle; value.world_generation_ = service.world_generation;
        value.sample_ = measured; value.clock_observed_ms_ = observed; value.captured_ms_ = now;
        value.base_ = service.base; value.world_ = s->anchor.world; value.state_ = s->anchor.state;
        value.body_index_ = s->body.index; value.body_generation_ = s->body.generation;
        out = value;
        return true;
    } catch (...) { return false; }
}
bool try_measure_source(std::uint64_t owner, const MeasuredSource& identity, MeasuredSource& out) noexcept {
    LastError error;
    // Refuse aliases before clearing output: a persistent identity must not be
    // silently overwritten with a newer pose by an in-place refresh call.
    if (&identity == &out) return false;
    out = {};
    if (!owner || owner != identity.owner_ || !TryAcquireSRWLockShared(&service.lock)) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockShared(&service.lock); } } unlock;
    const auto* s = lookup(owner, identity.handle_);
    if (!s || service.base != identity.base_ || service.world != identity.world_ ||
        service.state != identity.state_ || service.world_generation != identity.world_generation_ ||
        s->anchor.world != identity.world_ || s->anchor.state != identity.state_ ||
        s->body.world != identity.world_ || s->body.index != identity.body_index_ ||
        s->body.generation != identity.body_generation_ || !callback_source_current(*s)) return false;
    Epoch before{}; before.world = service.world_generation; before.body = s->handle.generation;
    std::uint64_t observed{};
    if (!clock(s->anchor, before, &observed)) return false;
    Sample measured{};
    if (!observe_callback(*s, measured) || measured.epoch != before) return false;
    Epoch after{}; after.world = service.world_generation; after.body = s->handle.generation;
    std::uint64_t observed_after{};
    if (!callback_source_current(*s) || !clock(s->anchor, after, &observed_after) ||
        after != before || observed_after != observed) return false;
    const auto now = GetTickCount64();
    if (!observed || now < observed || now - observed >= command_lifetime_ms ||
        now < service.tick_at || now - service.tick_at >= 250) return false;
    // The old immutable measurement selected identity only. Its timestamps and
    // pose are not restamped; this is a separate, newly observed value.
    MeasuredSource value = identity;
    value.sample_ = measured; value.clock_observed_ms_ = observed; value.captured_ms_ = now;
    out = value;
    return true;
}
SourceBorrow::~SourceBorrow() {
    LastError error;
    if (held_) ReleaseSRWLockShared(&service.lock);
}
const MeasuredSource* SourceBorrow::get() const noexcept {
    LastError error;
    if (!held_ || thread_ != GetCurrentThreadId()) return nullptr;
    const auto& source = source_;
    const auto now = GetTickCount64();
    // The client tick's cached readiness is read under service.lock. It does
    // not grant gameplay or native-write authority to the eventual consumer.
    if (!service.hooked.load(std::memory_order_acquire) || !service.eligible ||
        !source.owner_ || !source.clock_observed_ms_ || !source.captured_ms_ ||
        now < service.tick_at || now - service.tick_at >= 250 ||
        now < source.captured_ms_ || source.captured_ms_ < source.clock_observed_ms_ ||
        now - source.clock_observed_ms_ >= command_lifetime_ms ||
        service.base != source.base_ || service.world != source.world_ || service.state != source.state_ ||
        service.world_generation != source.world_generation_) return nullptr;
    const auto* s = lookup(source.owner_, source.handle_);
    if (!s || !s->active || s->retained || s->quarantined || s->release_requested ||
        s->body.world != source.world_ || s->anchor.world != source.world_ || s->anchor.state != source.state_ ||
        s->body.index != source.body_index_ || s->body.generation != source.body_generation_ ||
        source.sample_.epoch.world != source.world_generation_ ||
        source.sample_.epoch.body != source.handle_.generation || !producer_owner(*s, s->body)) return nullptr;
    Epoch before{}; before.world = service.world_generation; before.body = s->handle.generation;
    std::uint64_t observed{};
    if (!clock(s->anchor, before, &observed) || observed < source.clock_observed_ms_ ||
        before.serial < source.sample_.epoch.serial ||
        (before.serial == source.sample_.epoch.serial ? before.time != source.sample_.epoch.time :
            before.time <= source.sample_.epoch.time)) return nullptr;
    // A moving body may have a newer current clock. Never replace the retained
    // sample's epoch, pose or original wall age with that clock or a new read.
    Epoch after{}; after.world = service.world_generation; after.body = s->handle.generation;
    std::uint64_t observed_after{};
    if (!producer_owner(*s, s->body) || !clock(s->anchor, after, &observed_after) ||
        after != before || observed_after != observed) return nullptr;
    const auto finished = GetTickCount64();
    if (finished < now || finished - source.clock_observed_ms_ >= command_lifetime_ms ||
        finished - service.tick_at >= 250) return nullptr;
    return &source;
}
const MeasuredSource* SourceBorrow::current() const noexcept {
    LastError error;
    const auto* source = get();
    if (!source) return nullptr;
    const auto* s = lookup(source->owner_, source->handle_);
    Epoch before{}; before.world = source->world_generation_; before.body = source->handle_.generation;
    std::uint64_t observed{};
    Sample measured{};
    if (!s || !callback_source_current(*s) || !clock(s->anchor, before, &observed) ||
        before != source->sample_.epoch || observed != source->clock_observed_ms_ ||
        !observe_callback(*s, measured) || !body_query::same_sample(measured, source->sample_)) return nullptr;
    Epoch after{}; after.world = source->world_generation_; after.body = source->handle_.generation;
    std::uint64_t observed_after{};
    if (!get() || !callback_source_current(*s) || !clock(s->anchor, after, &observed_after) ||
        after != before || observed_after != observed) return nullptr;
    const auto finished = GetTickCount64();
    if (finished < source->captured_ms_ || finished < source->clock_observed_ms_ ||
        finished - source->clock_observed_ms_ >= command_lifetime_ms ||
        finished < service.tick_at || finished - service.tick_at >= 250) return nullptr;
    return &source_;
}
bool try_borrow_source(std::uint64_t owner, const MeasuredSource& source, SourceBorrow& out) noexcept {
    LastError error;
    if (out.held_) return false;
    if (!owner || owner != source.owner_ || !TryAcquireSRWLockShared(&service.lock)) return false;
    out.source_ = source; out.thread_ = GetCurrentThreadId(); out.held_ = true;
    if (out.get()) return true;
    out.held_ = false; out.source_ = {}; out.thread_ = 0;
    ReleaseSRWLockShared(&service.lock);
    return false;
}

bool acquire_release_hold(std::uint64_t owner, const MeasuredSource& source, BodyReleaseHold& out) noexcept {
    LastError error;
    if (out.available() || !owner || owner != source.owner_ || !eligible() ||
        !TryAcquireSRWLockExclusive(&service.lock)) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockExclusive(&service.lock); } } unlock;
    auto* s = lookup(owner, source.handle_);
    if (!s || s->release_hold || s->release_requested || !callback_source_current(*s) ||
        service.release_generation == std::numeric_limits<std::uint64_t>::max() || source.base_ != service.base ||
        source.world_generation_ != service.world_generation || source.world_ != s->anchor.world ||
        source.state_ != s->anchor.state || source.body_index_ != s->body.index ||
        source.body_generation_ != s->body.generation || !source.clock_observed_ms_ ||
        source.captured_ms_ < source.clock_observed_ms_) return false;
    Epoch before{}; before.world = service.world_generation; before.body = s->handle.generation;
    std::uint64_t observed{};
    Sample measured{};
    if (!clock(s->anchor, before, &observed) || before != source.sample_.epoch ||
        observed != source.clock_observed_ms_ || !observe_callback(*s, measured) ||
        !body_query::same_sample(measured, source.sample_)) return false;
    Epoch after{}; after.world = service.world_generation; after.body = s->handle.generation;
    std::uint64_t observed_after{};
    if (!callback_source_current(*s) || !clock(s->anchor, after, &observed_after) ||
        after != before || observed_after != observed) return false;
    const auto finished = GetTickCount64();
    if (finished < source.captured_ms_ || finished < observed ||
        finished - observed >= command_lifetime_ms || finished < service.tick_at ||
        finished - service.tick_at >= 250) return false;
    BodyReleaseHold value;
    value.owner_ = owner; value.id_ = ++service.release_generation;
    value.world_generation_ = service.world_generation; value.handle_ = s->handle;
    value.base_ = service.base; value.world_ = s->anchor.world; value.state_ = s->anchor.state;
    value.body_index_ = s->body.index; value.body_generation_ = s->body.generation;
    s->release_hold = value.id_;
    out = value;
    return true;
}
bool release_requested(std::uint64_t owner, const BodyReleaseHold& hold, bool& out) noexcept {
    LastError error; out = false;
    if (!owner || owner != hold.owner_ || !hold.id_ || !TryAcquireSRWLockShared(&service.lock)) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockShared(&service.lock); } } unlock;
    const auto* s = lookup(owner, hold.handle_);
    if (service.base != hold.base_ || service.world_generation != hold.world_generation_ ||
        service.world != hold.world_ || service.state != hold.state_ ||
        !s || s->release_hold != hold.id_ || s->anchor.world != hold.world_ ||
        s->anchor.state != hold.state_ || s->body.world != hold.world_ ||
        s->body.index != hold.body_index_ || s->body.generation != hold.body_generation_) return false;
    out = s->release_requested;
    return true;
}
bool release_body_hold(std::uint64_t owner, BodyReleaseHold& hold) noexcept {
    LastError error;
    if (!owner || owner != hold.owner_ || !hold.id_ || !TryAcquireSRWLockExclusive(&service.lock)) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockExclusive(&service.lock); } } unlock;
    auto* s = lookup(owner, hold.handle_);
    if (!s || s->release_hold != hold.id_ || s->anchor.world != hold.world_ ||
        s->anchor.state != hold.state_ || s->body.world != hold.world_ ||
        s->body.index != hold.body_index_ || s->body.generation != hold.body_generation_) return false;
    // No callback into an actor service and no native write under this lock.
    // The trusted holder already established its actual release precondition.
    s->release_hold = 0;
    hold = {};
    return true;
}

bool request_held_release(std::uint64_t owner, const BodyReleaseHold& hold) noexcept {
    LastError error;
    if (!owner || owner != hold.owner_ || !hold.id_ || !TryAcquireSRWLockExclusive(&service.lock)) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockExclusive(&service.lock); } } unlock;
    auto* s = lookup(owner, hold.handle_);
    if (!s || s->release_hold != hold.id_ || s->anchor.world != hold.world_ ||
        s->anchor.state != hold.state_ || s->body.world != hold.world_ ||
        s->body.index != hold.body_index_ || s->body.generation != hold.body_generation_) return false;
    s->release_requested = true;
    s->mailbox.cancel();
    return true;
}

bool capture_retirement_basis(std::uint64_t owner, const MeasuredSource& source, RetirementBasis& out) noexcept {
    LastError error;
    if (out.available() || !owner || owner != source.owner_ || !eligible() ||
        !TryAcquireSRWLockShared(&service.lock)) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockShared(&service.lock); } } unlock;
    const auto* s = lookup(owner, source.handle_);
    if (!s || !s->active || s->retained || s->quarantined || !fresh(*s) ||
        source.base_ != service.base || source.world_generation_ != service.world_generation ||
        source.world_ != s->anchor.world || source.state_ != s->anchor.state ||
        source.body_index_ != s->body.index || source.body_generation_ != s->body.generation ||
        !s->made || s->made != s->definition.count || s->made > maximum_capsules) return false;
    RetirementBasis value;
    value.epoch_.world = service.world_generation; value.epoch_.body = s->handle.generation;
    std::uint64_t observed{};
    if (!clock(s->anchor, value.epoch_, &observed)) return false;
    value.owner_ = owner; value.handle_ = s->handle; value.world_generation_ = service.world_generation;
    value.base_ = service.base; value.world_ = s->anchor.world; value.state_ = s->anchor.state;
    value.body_ = {s->body.world, s->body.index, s->body.generation}; value.made_ = s->made;
    for (std::size_t i = 0; i < s->made; ++i)
        value.shapes_[i] = {s->shapes[i].world, s->shapes[i].index, s->shapes[i].generation};
    Epoch after{}; after.world = service.world_generation; after.body = s->handle.generation;
    std::uint64_t observed_after{};
    if (!fresh(*s) || !clock(s->anchor, after, &observed_after) || after != value.epoch_ || observed_after != observed) return false;
    const auto finished = GetTickCount64();
    if (!observed || finished < observed || finished - observed >= command_lifetime_ms) return false;
    value.captured_ms_ = finished; out = value; return true;
}

bool observe_retained_park(std::uint64_t owner, const RetirementBasis& basis, RetainedParkReceipt& out) noexcept {
    ParkObservationDiagnostic diagnostic;
    return observe_retained_park(owner, basis, out, diagnostic);
}
bool observe_retained_park(std::uint64_t owner, const RetirementBasis& basis, RetainedParkReceipt& out,
    ParkObservationDiagnostic& diagnostic) noexcept {
    LastError error; diagnostic = {};
    const auto failed = [&](ParkObservationCheck check, bool value) noexcept {
        if (value && diagnostic.check == ParkObservationCheck::not_attempted) diagnostic.check = check;
        return value;
    };
    const auto different = [&](ParkObservationCheck check, const V4& value, const V4& expected) noexcept {
        if (value == expected) return false;
        if (diagnostic.check == ParkObservationCheck::not_attempted) {
            diagnostic.check = check; diagnostic.lanes_known = true;
            for (std::size_t lane = 0; lane < value.size(); ++lane)
                if (value[lane] != expected[lane]) diagnostic.failed_lanes |= static_cast<std::uint8_t>(1U << lane);
            if (check == ParkObservationCheck::angular_zero) {
                // ring() already qualified these finite lanes. Copy that read;
                // do not reread a native value or infer the fourth lane's role.
                diagnostic.angular_fourth_available = true;
                diagnostic.angular_fourth_value = value[3];
                diagnostic.angular_fourth_bits = std::bit_cast<std::uint32_t>(value[3]);
            }
        }
        return true;
    };
    using Check = ParkObservationCheck;
    if (failed(Check::output_occupied, out.available()) || failed(Check::owner, !owner || owner != basis.owner_) ||
        failed(Check::client_phase, !eligible()) || failed(Check::world_lock, !TryAcquireSRWLockShared(&service.lock))) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockShared(&service.lock); } } unlock;
    const auto* s = lookup(owner, basis.handle_);
    const auto identity = [&] {
        if (failed(Check::retained_identity, !s || s->active || !s->retained || s->quarantined || !s->parked_ms ||
            s->parked_ms < basis.captured_ms_ || basis.base_ != service.base ||
            basis.world_generation_ != service.world_generation || basis.world_ != s->anchor.world ||
            basis.state_ != s->anchor.state || basis.body_.world != s->body.world ||
            basis.body_.index != s->body.index || basis.body_.generation != s->body.generation ||
            !basis.made_ || basis.made_ != s->made || s->made > maximum_capsules) ||
            failed(Check::fresh_allocation, !fresh(*s))) return false;
        for (std::size_t i = 0; i < s->made; ++i)
            if (failed(Check::shape_identity, basis.shapes_[i].world != s->shapes[i].world || basis.shapes_[i].index != s->shapes[i].index ||
                basis.shapes_[i].generation != s->shapes[i].generation)) return false;
        return true;
    };
    if (!identity()) return false;
    Epoch before{}; before.world = service.world_generation; before.body = s->handle.generation;
    std::uint64_t observed{};
    if (failed(Check::clock_unavailable, !clock(s->anchor, before, &observed)) ||
        failed(Check::clock_serial, before.serial <= basis.epoch_.serial) ||
        failed(Check::clock_time, before.time <= basis.epoch_.time) ||
        failed(Check::clock_after_fence, observed <= basis.captured_ms_) ||
        failed(Check::clock_after_park, observed <= s->parked_ms)) return false;
    std::uintptr_t categories{}, collides{}, dynamics{};
    std::uint32_t dynamic_word{};
    const auto word = std::uintptr_t{s->body.index >> 5} * sizeof(std::uint32_t);
    const auto bit = 1U << (s->body.index & 31U);
    if (failed(Check::category_storage, !peek(s->anchor.state + r::shape_categories, categories) || !pointer(categories)) ||
        failed(Check::collision_storage, !peek(s->anchor.state + r::shape_collides, collides) || !pointer(collides)) ||
        failed(Check::dynamic_storage, !peek(s->anchor.state + r::dynamic_bits, dynamics) || !pointer(dynamics) ||
            !peek(dynamics + word, dynamic_word)) || failed(Check::dynamic_bit, (dynamic_word & bit) != 0)) return false;
    Ring linear_header, angular_header; V4 linear{}, angular{}, force{}, torque{};
    std::uintptr_t force_source{}, torque_source{};
    // The native angular setter and its zero check compare XYZ. Keep the
    // qualified fourth lane for the unchanged full-vector readback below.
    if (failed(Check::linear_read, !ring(*s, r::velocity_ring, linear_header, linear)) || different(Check::linear_zero, linear, V4{}) ||
        failed(Check::angular_read, !ring(*s, r::spin_ring, angular_header, angular)) || different(Check::angular_zero, angular, V4{0, 0, 0, angular[3]}) ||
        failed(Check::force_read, !array4(s->anchor.state, r::pending_force, s->body.index, force, force_source)) || different(Check::force_zero, force, V4{}) ||
        failed(Check::torque_read, !array4(s->anchor.state, r::pending_torque, s->body.index, torque, torque_source)) || different(Check::torque_zero, torque, V4{})) return false;
    for (unsigned pass = 0; pass < 2; ++pass) {
        for (std::size_t i = 0; i < s->made; ++i) {
            std::uint32_t category{}, collision{};
            const auto offset = std::uintptr_t{s->shapes[i].index} * sizeof(std::uint32_t);
            if (failed(Check::shape_category_read, !peek(categories + offset, category)) || failed(Check::shape_category_zero, category != 0) ||
                failed(Check::shape_collision_read, !peek(collides + offset, collision)) || failed(Check::shape_collision_zero, collision != 0) ||
                failed(Check::shape_current, !shape_current(*s, i))) return false;
        }
        std::uintptr_t again{}; std::uint32_t bits{}; Ring header; V4 value{};
        if (failed(Check::categories_unchanged, !peek(s->anchor.state + r::shape_categories, again) || again != categories) ||
            failed(Check::collisions_unchanged, !peek(s->anchor.state + r::shape_collides, again) || again != collides) ||
            failed(Check::dynamic_unchanged, !peek(s->anchor.state + r::dynamic_bits, again) || again != dynamics ||
                !peek(dynamics + word, bits) || bits != dynamic_word) ||
            failed(Check::linear_read, !ring(*s, r::velocity_ring, header, value)) || failed(Check::linear_header, header != linear_header) || different(Check::linear_values, value, linear) ||
            failed(Check::angular_read, !ring(*s, r::spin_ring, header, value)) || failed(Check::angular_header, header != angular_header) || different(Check::angular_values, value, angular) ||
            failed(Check::force_read, !array4(s->anchor.state, r::pending_force, s->body.index, value, again)) || failed(Check::force_storage, again != force_source) || different(Check::force_values, value, force) ||
            failed(Check::torque_read, !array4(s->anchor.state, r::pending_torque, s->body.index, value, again)) || failed(Check::torque_storage, again != torque_source) || different(Check::torque_values, value, torque) ||
            !identity()) return false;
    }
    Epoch after{}; after.world = service.world_generation; after.body = s->handle.generation;
    std::uint64_t observed_after{};
    if (!identity() || failed(Check::closing_clock, !clock(s->anchor, after, &observed_after)) ||
        failed(Check::closing_epoch, after != before) || failed(Check::closing_stamp, observed_after != observed)) return false;
    const auto finished = GetTickCount64();
    if (failed(Check::clock_freshness, finished < observed || finished - observed >= command_lifetime_ms)) return false;
    RetainedParkReceipt value; value.basis_ = basis; value.observed_epoch_ = before;
    value.parked_ms_ = s->parked_ms; value.observed_ms_ = observed;
    out = value; diagnostic.check = Check::passed; return true;
}

// Both callers already hold the World lock. This checks stored terminal
// identities only; it does not recapture an actor, clock or native allocation.
bool matches_retained_park_locked(std::uint64_t owner, const RetirementBasis& basis, const RetainedParkReceipt& receipt) noexcept {
    if (!owner || owner != basis.owner_ || !receipt.available()) return false;
    const auto* s = lookup(owner, basis.handle_);
    const auto& recorded = receipt.basis_;
    if (!s || s->body.world != basis.body_.world || s->body.index != basis.body_.index ||
        s->body.generation != basis.body_.generation || s->made != basis.made_ || s->made > maximum_capsules) return false;
    for (std::size_t i = 0; i < s->made; ++i)
        if (s->shapes[i].world != basis.shapes_[i].world || s->shapes[i].index != basis.shapes_[i].index ||
            s->shapes[i].generation != basis.shapes_[i].generation) return false;
    // No fresh retirement observation or timestamp refresh. Fresh actor/input
    // authority is separate from this immutable, irreversible terminal history.
    return !s->active && s->retained && !s->quarantined && s->parked_ms == receipt.parked_ms_ &&
        s->parked_ms >= basis.captured_ms_ && basis.base_ == service.base &&
        basis.world_generation_ == service.world_generation && basis.world_ == s->anchor.world && basis.state_ == s->anchor.state &&
        basis.owner_ == recorded.owner_ && basis.handle_ == recorded.handle_ && basis.world_generation_ == recorded.world_generation_ &&
        basis.base_ == recorded.base_ && basis.world_ == recorded.world_ && basis.state_ == recorded.state_ &&
        basis.body_ == recorded.body_ && basis.shapes_ == recorded.shapes_ && basis.made_ == recorded.made_ &&
        basis.epoch_ == recorded.epoch_ && basis.captured_ms_ == recorded.captured_ms_ &&
        receipt.observed_epoch_.world == basis.epoch_.world && receipt.observed_epoch_.body == basis.epoch_.body &&
        receipt.observed_epoch_.serial > basis.epoch_.serial && receipt.observed_epoch_.time > basis.epoch_.time &&
        receipt.observed_ms_ > s->parked_ms && receipt.observed_ms_ > basis.captured_ms_;
}

bool matches_retained_park(std::uint64_t owner, const RetirementBasis& basis, const RetainedParkReceipt& receipt) noexcept {
    LastError error;
    if (!TryAcquireSRWLockShared(&service.lock)) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockShared(&service.lock); } } unlock;
    return matches_retained_park_locked(owner, basis, receipt);
}

bool seal_parked_command_cleanup(std::uint64_t owner, const RetirementBasis& basis, const RetainedParkReceipt& receipt) noexcept {
    LastError error;
    if (GetCurrentThreadId() != service.thread || !TryAcquireSRWLockExclusive(&service.lock)) return false;
    struct Unlock { ~Unlock() { ReleaseSRWLockExclusive(&service.lock); } } unlock;
    if (!matches_retained_park_locked(owner, basis, receipt)) return false;
    auto* s = lookup(owner, basis.handle_);
    if (!s || s->active || !s->retained || s->quarantined || !s->release_requested || s->release_hold) return false;
    return s->mailbox.seal_parked_without_successor(basis.epoch_, receipt.observed_epoch_);
}

#include "owned_body_sync_probe.inl"
#include "owned_body_motion_refresh_probe.inl"

body_query::Result probe_batch(std::uint64_t owner, const Handle& handle, const body_query::Request& request, unsigned allowance) noexcept {
    LastError error;
    body_query::Result failed; failed.count = request.count <= body_query::maximum_rays ? request.count : 0;
    unsigned performed{};
    bool ray_entered{};
    try {
        if (!body_query::valid(request, 1000)) { failed.failure = body_query::Failure::invalid; return failed; }
        if (!eligible()) { failed.failure = body_query::Failure::client_phase_unavailable; return failed; }
        Locked lock(service.lock);
        const auto* selected = lookup(owner, handle);
        const auto& canonical = request.observation; const auto& requested_epoch = canonical.epoch;
        if (!selected || !selected->active || selected->retained || selected->quarantined || selected->release_requested || !fresh(*selected) ||
            !body_query::same_sample(canonical, selected->latest) || requested_epoch.world != service.world_generation ||
            requested_epoch.body != selected->handle.generation) {
            failed.failure = body_query::Failure::observation_changed; return failed;
        }
        const auto& anchor = selected->anchor;
        const auto generation = service.world_generation;
        std::array<const Slot*, body_query::maximum_exclusions + 1> owners{};
        std::size_t excluded_count = 1; owners[0] = selected;
        for (std::size_t i = 0; i < request.exclusions; ++i) {
            const auto* other = lookup(owner, request.excluded[i]);
            if (!other || !other->active || other->retained || other->quarantined || other->release_requested || !fresh(*other) ||
                !selected->anchor.same(other->anchor)) { failed.failure = body_query::Failure::observation_changed; return failed; }
            if (std::find(owners.begin(), owners.begin() + excluded_count, other) == owners.begin() + excluded_count)
                owners[excluded_count++] = other;
        }
        // The placement root resolver takes a packed entity key, not the raw
        // SkaterEntity pointer held by Anchor. Actor conversion and the root
        // descriptor's actor support are unqualified; never submit that pointer.
        if (request.exclude_local_actor) { failed.failure = body_query::Failure::local_actor_exclusion_unavailable; return failed; }
        for (const auto field : {anchor.state + r::shape_allocated_bits, anchor.state + r::shape_generations,
            anchor.state + r::shape_body_indices, anchor.world + r::world_body_generations}) {
            std::uintptr_t array{};
            if (!peek(field, array) || !pointer(array)) { failed.failure = body_query::Failure::body_exclusions_unavailable; return failed; }
        }
        body_hit_identity::Witnesses<body_query::maximum_rays> witnesses;
        std::array<body_contact_read::Motion,body_query::maximum_rays> motions{};
        std::size_t motion_count{};
        const auto world_current = [&] { return service.world_generation == generation && anchor_current(anchor); };
        const auto qualify = [&](const NativeHandle& shape, NativeHandle& body) {
            return body_hit_identity::resolve(anchor.world, anchor.state, shape, body,
                [](std::uintptr_t at, auto& value) { return peek(at, value); }, world_current,
                [&](const NativeHandle& value) { return valid_handle(service.api.shape_valid, value) && world_current(); },
                [&](std::uint32_t index) { return allocated(anchor.state, index); },
                [&](const NativeHandle& value) {
                    return value.world == anchor.world && world_current() && allocated(anchor.state, value.index) &&
                        valid_handle(service.api.body_valid, value) && allocated(anchor.state, value.index) && world_current();
                });
        };
        const auto motion_body_current = [&](const NativeHandle& body) {
            return world_current() && body.world==anchor.world && allocated(anchor.state,body.index) &&
                valid_handle(service.api.body_valid,body) && allocated(anchor.state,body.index) && world_current();
        };
        const auto read_contact = [](std::uintptr_t at, auto& value) { return peek(at,value); };
        const auto fence = [&] {
            Anchor current; Epoch epoch{};
            if (!eligible() || service.world_generation != generation || !capture(current) || !anchor.same(current) ||
                !watched(anchor) || !watched(current) || !clock(current, epoch)) return false;
            epoch.world = generation; epoch.body = selected->handle.generation;
            if (epoch != requested_epoch || !body_query::same_sample(canonical, selected->latest)) return false;
            for (std::size_t i = 0; i < excluded_count; ++i)
                if (!owners[i]->active || owners[i]->retained || owners[i]->quarantined || !fresh(*owners[i])) return false;
            Sample measured;
            if (!observe(*selected, measured) || !body_query::same_sample(canonical, measured) ||
                !witnesses.current([&](const body_hit_identity::Witness& witness) {
                    NativeHandle body; return qualify(witness.shape, body) && body == witness.body;
                })) return false;
            for (std::size_t i=0;i<motion_count;++i)
                if (!body_contact_read::motion_current(anchor.world,anchor.state,motions[i],read_contact,motion_body_current)) return false;
            Epoch after{}; after.world = generation; after.body = selected->handle.generation;
            return world_current() && clock(anchor, after) && after == requested_epoch &&
                body_query::same_sample(canonical, selected->latest);
        };
        const auto query = [&](const body_query::Ray& ray, unsigned permitted) {
            body_query::Probe out;
            // Native ignored IDs are owner indices. Query without either list or
            // the ECS owner resolver; classify only the actual nearest hit below.
            ray_entered = true;
            // The preset selects the native filter only. The nearest hit it returns
            // still passes the same owned-body, identity, contact and fence checks.
            const auto counted = probe_local_surface_geometry_bounded(ray.from, ray.to, permitted, request.require_contact, request.preset);
            performed += counted.native_casts; out.native_casts = counted.native_casts; out.budget_exhausted = counted.budget_exhausted;
            const auto& hit = counted.surface;
            if (!hit.available || hit.context != anchor.context || hit.world != anchor.world) return out;
            if (!hit.hit) { out.hit.status = body_query::Status::clear; return out; }
            NativeHandle shape, body;
            std::memcpy(&shape, hit.hit_body.data(), sizeof(shape));
            if (!qualify(shape, body)) return out;
            for (std::size_t i = 0; i < excluded_count; ++i)
                if (body.world == owners[i]->body.world && body.index == owners[i]->body.index) return out;
            if (!witnesses.add({shape, body})) return out;
            out.hit.status = body_query::Status::hit; out.hit.position = hit.position; out.hit.fraction = hit.fraction;
            out.hit.normal=hit.normal; out.hit.normal_available=hit.normal_available;
            body_contact_read::Motion motion;
            if (request.require_contact && hit.normal_available && body_contact_read::motion(anchor.world,anchor.state,body,hit.position,motion,read_contact,motion_body_current) &&
                motion_count<motions.size()) {
                motions[motion_count++]=motion;
                out.hit.surface_velocity=motion.velocity; out.hit.surface_velocity_available=true;
            }
            // No public native body identity is minted. Unknown details stay absent;
            // actor exclusions above remain unavailable until their own conversion is qualified.
            return out;
        };
        return body_query::execute(request, allowance, 1000, query, fence);
    } catch (...) {
        failed.native_casts = performed; failed.accounting_valid = !ray_entered;
        failed.failure = ray_entered ? body_query::Failure::query_backend_exception : body_query::Failure::query_preconditions_unavailable;
        return failed;
    }
}
std::string submit(std::uint64_t owner, const Handle& handle, const Command& command, std::uint64_t& sequence) noexcept {
    LastError error; sequence = 0;
    try {
        if (!eligible()) return "body commands require the current local client phase";
        Locked lock(service.lock); auto* s = lookup(owner, handle);
        if (!s || !s->active || s->retained || s->quarantined || s->release_requested || !fresh(*s)) return "body owner or generation changed";
        Epoch current{};
        if (!command_clock(*s, current) || current != s->latest.epoch) return "measured native body epoch expired";
        if (service.command_sequence == std::numeric_limits<std::uint64_t>::max() ||
            !s->mailbox.submit(command, current, GetTickCount64(), service.command_sequence + 1))
            return "body command invalid, repeated, stopped, pending or receipt ring full";
        sequence = ++service.command_sequence;
        return {};
    } catch (...) { return "native body command failed closed"; }
}
std::string receipt(std::uint64_t owner, const Handle& handle, std::uint64_t selected, Receipt& out) noexcept {
    LastError error; out = {};
    try {
        if (GetCurrentThreadId() != service.thread) return "body receipts are client phase only";
        Locked lock(service.lock); auto* s = lookup(owner, handle); if (!s) return "body owner or generation unavailable";
        if (s->mailbox.pending && GetTickCount64() >= s->mailbox.deadline) {
            Command ignored; (void)s->mailbox.consume(s->mailbox.command.epoch, GetTickCount64(), ignored);
        }
        if (s->active && !s->quarantined && !s->release_requested && s->mailbox.needs_successor()) { Sample observed; (void)sample(*s, observed); }
        if (!s->mailbox.find(selected, out)) return "body receipt sequence unavailable for this owner and generation";
        out.retained = s->retained; out.quarantined = s->quarantined; return {};
    } catch (...) { return "native body receipt failed closed"; }
}
std::string release(std::uint64_t owner, const Handle& handle) noexcept {
    LastError error;
    try {
        if (GetCurrentThreadId() != service.thread) return "body release is client phase only";
        Locked lock(service.lock); auto* s = lookup(owner, handle); if (!s) return "body owner or generation unavailable";
        if (s->release_hold) {
            retire(*s, false); // request only; held dependent allocation is not parked
            return "body release deferred while native dependent work remains";
        }
        if (!s->retained) retire(*s, eligible() && fresh(*s));
        return s->quarantined ? "body retained in quarantine; fresh owner unavailable, no native destruction attempted" : std::string{};
    } catch (...) { return "native body release failed closed"; }
}
std::string acknowledge(std::uint64_t owner, const Handle& handle, std::uint64_t sequence) noexcept {
    LastError error;
    if (GetCurrentThreadId() != service.thread) return "body acknowledgement is client phase only";
    Locked lock(service.lock); auto* s = lookup(owner, handle);
    if (!s || !s->mailbox.acknowledge(sequence)) return "receipt unavailable, already acknowledged or awaiting a measured successor";
    return {};
}
void release_all(std::uint64_t owner) noexcept {
    LastError error;
    cancel_motion_refresh_probes(owner);
    if (GetCurrentThreadId() != service.thread) return;
    Locked lock(service.lock);
    if (owner && service.probe.owner == owner && service.probe.result.status == body_sync_probe::Status::pending) {
        service.probe.result.status = body_sync_probe::Status::invalidated;
        service.probe_live.store(0, std::memory_order_release);
        sync_capture_routes(service.probe);
    }
    for (auto& s : service.slots) if (s.attempted && s.owner == owner && !s.retained) retire(s, eligible() && fresh(s));
}
} // namespace dingosdk::owned_bodies
