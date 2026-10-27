// Includes the actual proposed translation unit. Wall time is substituted and
// named native ABI stand-ins read constructed arrays or return a counted query.
// The actual Service/Slot/Clock, capture/observe/borrow/query implementation,
// memory::peek and SRW locks execute below; no retail native code executes.
#include <Windows.h>
#include <intrin.h>
#include <array>
#include <atomic>
#include <bit>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <functional>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>

namespace test_clock {
std::atomic<ULONGLONG> now{10000};
std::atomic<unsigned> reads{};
std::atomic<bool> inject_after_open_clock{}, advance_at_world_read{};
std::function<void(unsigned)> park_read_hook;
}
ULONGLONG WINAPI source_test_now() noexcept {
    // get() first reads its wall, then clock() reads its own freshness wall.
    // Arm an external feed at that opening clock read; the next native world
    // ABI read occurs after the shared clock lock has been released.
    const auto read = ++test_clock::reads;
    // Keep the test callable alive when its one-shot body clears the hook.
    const auto park_read = test_clock::park_read_hook;
    if (park_read) park_read(read);
    if (read == 2 && test_clock::inject_after_open_clock.load())
        test_clock::advance_at_world_read = true;
    return test_clock::now.load();
}
#define GetTickCount64 source_test_now
#include "../owned_bodies.cpp"
#undef GetTickCount64

// A genuine compiler-created static TLS block, reached through the same GS:58
// module TLS vector as client_context(). No TEB/TLS vector is overwritten.
extern "C" unsigned long _tls_index;
__declspec(align(16)) __declspec(thread) unsigned char source_test_tls[0x4000];

namespace test_facts {
std::atomic<unsigned> model_calls{}, world_calls{}, body_calls{}, shape_calls{}, mutations{}, forbidden_links{};
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
std::atomic<bool> reactivation_image_allowed{};
std::atomic<unsigned> reactivation_image_queries{}, reactivation_allocations{}, reactivation_capsules{};
#endif
std::atomic<bool> multiplayer_active{}, inspect_initializer_lock{}, initializer_unlocked{};
std::atomic<ULONGLONG> initializer_elapsed{};
std::atomic<bool> motion_actor_enabled{}, motion_available{};
dingosdk::actor_control_native::Actor motion_actor{};
std::function<void()> motion_observe_once;
std::function<void(unsigned)> park_shape_hook;
std::function<dingosdk::BoundedLocalSurfaceProbe(const std::array<float,3>&,const std::array<float,3>&,unsigned,bool)> probe_callback;
std::vector<dingosdk::body_query::QueryPreset> probe_presets; // What the Service forwarded, per counted query.
}
namespace dingosdk::multiplayer {
MultiplayerModel model() {
    ++test_facts::model_calls;
    MultiplayerModel out;
    out.active = test_facts::multiplayer_active.load();
    return out;
}
}

// These constructed link leaves cannot observe a native actor or lifetime.
// Existing source tests never request a synchronizer probe. The routing-only
// cases seed a private pending probe and count the one intentional failed actor
// read separately; none qualifies a retail actor or begins a native probe.
namespace dingosdk::actor_control_native {
bool observe_actor(Actor& actor) noexcept {
    if (test_facts::motion_actor_enabled.load()) {
        // One scripted native leaf interleaving, removed before it can recurse.
        auto interleave = std::exchange(test_facts::motion_observe_once, {});
        if (interleave) interleave();
        actor = test_facts::motion_actor;
        SetLastError(0xB015);
        return true;
    }
    ++test_facts::forbidden_links;
    actor = {};
    return false;
}
}
namespace dingosdk::multiplayer {
bool entity_destruction_epoch(std::uintptr_t, std::uint64_t& epoch) noexcept {
    ++test_facts::forbidden_links;
    epoch = 0;
    return false;
}
}

// Unrelated create/hook links fail closed and are counted. Only the named
// contact-query cases install the counted, constructed native-query ABI stand-in.
namespace dingosdk {
HookStatus WINAPI hook_initialize() { ++test_facts::forbidden_links; return HookNotInitialized; }
HookStatus WINAPI hook_prepare(void*, void*, void**) { ++test_facts::forbidden_links; return HookNotInitialized; }
HookStatus WINAPI hook_enable(void*) { ++test_facts::forbidden_links; return HookNotInitialized; }
HookBatch::HookBatch() noexcept { ++test_facts::forbidden_links; }
HookBatch::~HookBatch() { ++test_facts::forbidden_links; }
bool start_no_bail(std::uintptr_t) noexcept { ++test_facts::forbidden_links; return false; }
bool add_no_bail_step_listener(NoBailStepObserver) noexcept { ++test_facts::forbidden_links; return false; }
bool add_no_bail_mover_observer(NoBailMoverObserver) noexcept { ++test_facts::forbidden_links; return false; }
bool no_bail_mover_observation_available(std::uintptr_t base) noexcept {
    return test_facts::motion_available.load() && test_facts::motion_actor.base == base;
}
BoundedLocalSurfaceProbe probe_local_surface_geometry_bounded(const std::array<float, 3>& from,
    const std::array<float, 3>& to, unsigned allowed, bool contact, body_query::QueryPreset preset) {
    test_facts::probe_presets.push_back(preset);
    if(test_facts::probe_callback) return test_facts::probe_callback(from,to,allowed,contact);
    ++test_facts::forbidden_links;return {};
}
namespace supported_build {
bool running_image_matches(std::uintptr_t) noexcept {
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
    if (test_facts::reactivation_image_allowed.load()) {
        ++test_facts::reactivation_image_queries;
        return true; // Counted image-identity leaf; provider prefix reads remain real.
    }
#endif
    ++test_facts::forbidden_links;
    if (test_facts::inspect_initializer_lock.load()) {
        const bool unlocked = TryAcquireSRWLockExclusive(&owned_bodies::service.lock) != 0;
        test_facts::initializer_unlocked = unlocked;
        if (unlocked) ReleaseSRWLockExclusive(&owned_bodies::service.lock);
        test_clock::now += test_facts::initializer_elapsed.load();
    }
    return false;
}
}
}

#if !defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) || !DINGOSDK_BODY_REACTIVATION_QUALIFICATION
// These names conflict at compile time if an OFF translation unit exposes the
// diagnostic entry points. They are data sentinels, never executable routes.
namespace dingosdk::owned_bodies {
inline constexpr bool begin_body_reactivation_probe=false;
inline constexpr bool poll_body_reactivation_probe=false;
inline constexpr bool revoke_body_reactivation_probe=false;
}
#endif
namespace dingosdk::owned_bodies::source_test {
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
void reset_reactivation_source_fixture();
#endif
unsigned checks{}, cases{};
void check(bool value, const char* why) {
    ++checks;
    if (!value) throw std::runtime_error(why);
}
constexpr std::uint64_t owner = 101;
constexpr std::uintptr_t test_world_field = 0x80; // synthetic ABI stand-in only
constexpr std::uint32_t capacity = 8, body_index = 3, body_generation = 7;
constexpr std::uint32_t shape_index = 5, shape_generation = 11;

class Arena {
public:
    Arena() {
        memory_ = VirtualAlloc(nullptr, bytes, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (!memory_) throw std::runtime_error("synthetic arena allocation failed");
    }
    ~Arena() { VirtualFree(memory_, 0, MEM_RELEASE); }
    Arena(const Arena&) = delete;
    std::uintptr_t take(std::size_t size, std::size_t alignment = 64) {
        used_ = (used_ + alignment - 1) & ~(alignment - 1);
        if (size > bytes - used_) throw std::runtime_error("bounded arena exhausted");
        const auto result = reinterpret_cast<std::uintptr_t>(memory_) + used_;
        used_ += size;
        return result;
    }
private:
    static constexpr std::size_t bytes = 1 << 20;
    void* memory_{};
    std::size_t used_{};
};
template<class T> void put(std::uintptr_t at, const T& value) {
    std::memcpy(reinterpret_cast<void*>(at), &value, sizeof(value));
}
template<class T> T load(std::uintptr_t at) {
    T value{};
    check(peek(at, value), "test inspection read failed");
    return value;
}
void install_tls(std::uintptr_t game_context) {
    const auto table = static_cast<std::uintptr_t>(__readgsqword(0x58));
    check(table && _tls_index <= 4095, "real static TLS vector/index absent");
    const auto block = load<std::uintptr_t>(table + _tls_index * sizeof(std::uintptr_t));
    const auto begin = reinterpret_cast<std::uintptr_t>(source_test_tls);
    const auto end = begin + sizeof(source_test_tls);
    check(block + r::tls_context >= begin && block + r::tls_context + sizeof(std::uintptr_t) <= end &&
        block + r::tls_active >= begin && block + r::tls_active + 1 <= end,
        "TLS fixture fields would touch another module/CRT TLS object");
    put(block + r::tls_context, game_context);
    put(block + r::tls_active, std::uint8_t{1});
}

std::uintptr_t world_read(std::uintptr_t context) {
    ++test_facts::world_calls;
    SetLastError(0xB011);
    if (test_clock::advance_at_world_read.exchange(false)) {
        const auto owner_at_feed = clock_feed.owner;
        physics_step(owner_at_feed, 1.f / 60.f, false);
    }
    std::uintptr_t result{};
    return peek(context + test_world_field, result) ? result : 0;
}
// Native validators are read-only ABI stand-ins over constructed native arrays,
// not a precomputed answer for capture(), fresh(), pool_current() or the bridge.
bool body_valid_read(const NativeHandle* handle) {
    ++test_facts::body_calls;
    SetLastError(0xB012);
    std::uintptr_t state{}, generations{}, bits{};
    std::uint32_t limit{}, allocation{}, generation{};
    return handle && peek(handle->world + r::world_state, state) &&
        peek(state + r::body_capacity, limit) && limit && limit <= capacity && handle->index < limit &&
        peek(state + r::allocated_bits, bits) && peek(bits, allocation) &&
        (allocation & (1U << handle->index)) && peek(handle->world + r::world_body_generations, generations) &&
        peek(generations + handle->index * sizeof(std::uint32_t), generation) && generation == handle->generation;
}
bool shape_valid_read(const NativeHandle* handle) {
    const auto call = ++test_facts::shape_calls;
    const auto park_shape = test_facts::park_shape_hook;
    if (park_shape) park_shape(call);
    SetLastError(0xB013);
    std::uintptr_t state{}, generations{}, bits{};
    std::uint32_t allocation{};
    std::uint8_t generation{};
    return handle && handle->index < capacity && peek(handle->world + r::world_state, state) &&
        peek(state + r::shape_allocated_bits, bits) && peek(bits, allocation) &&
        (allocation & (1U << handle->index)) && peek(state + r::shape_generations, generations) &&
        peek(generations + handle->index, generation) && generation == handle->generation;
}
void forbidden_vector(NativeHandle*, const float*) { ++test_facts::mutations; }
void forbidden_integer(NativeHandle*, int) { ++test_facts::mutations; }
void forbidden_scalar(NativeHandle*, float) { ++test_facts::mutations; }
void forbidden_touch(NativeHandle*) { ++test_facts::mutations; }
void forbidden_mask(NativeHandle*, const std::uint32_t*) { ++test_facts::mutations; }
void forbidden_owner(NativeHandle*, const NativeHandle*) { ++test_facts::mutations; }
NativeHandle* forbidden_allocate(std::uintptr_t, NativeHandle*) {
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
    ++test_facts::reactivation_allocations;
#endif
    ++test_facts::mutations; return nullptr;
}
NativeHandle* forbidden_capsule(std::uintptr_t, NativeHandle*, const NativeHandle*, const float*, const float*, float) {
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
    ++test_facts::reactivation_capsules;
#endif
    ++test_facts::mutations; return nullptr;
}

class Fixture {
public:
    Arena arena;
    std::uintptr_t base{}, client{}, context{}, entity{}, core{}, skater_context{}, rig{}, world{}, state{};
    std::uintptr_t position{}, rotation{}, velocity{}, spin{}, body_generations{}, allocations{}, dynamics{}, categories{}, collisions{};
    Handle handle{17, 0};
    Fixture() {
        test_clock::now = 10000;
        test_clock::reads = 0; test_clock::inject_after_open_clock = false;
        test_clock::advance_at_world_read = false;
        test_clock::park_read_hook = {};
        test_facts::model_calls = 0; test_facts::world_calls = 0;
        test_facts::body_calls = 0; test_facts::shape_calls = 0;
        test_facts::mutations = 0; test_facts::multiplayer_active = false; test_facts::probe_callback={};
        test_facts::motion_actor_enabled = false; test_facts::motion_available = false; test_facts::motion_actor = {};
        test_facts::motion_observe_once = {};
        test_facts::park_shape_hook = {};
        InitializeSRWLock(&motion_probe.lock);
        motion_probe.owner = motion_probe.sequence = motion_probe.opened = motion_probe.deadline = 0;
        motion_probe.generation = 0; motion_probe.base = 0; motion_probe.actor = {}; motion_probe.result = {};
        motion_probe.before = {}; motion_probe.requested = motion_probe.ready = motion_probe.inflight = false;
        motion_probe.live = 0; for (auto& route : motion_probe.routes) route = 0;
        // Only reserve address space up to the largest used RVA; commit two
        // data pages. No retail code/data is copied or executed.
        image_ = VirtualAlloc(nullptr, e::tls_index + 0x1000, MEM_RESERVE, PAGE_NOACCESS);
        if (!image_) throw std::runtime_error("synthetic image reservation failed");
        base = reinterpret_cast<std::uintptr_t>(image_);
        for (const auto offset : {e::context_player_manager_offset, e::tls_index}) {
            const auto page = (base + offset) & ~std::uintptr_t{4095};
            check(VirtualAlloc(reinterpret_cast<void*>(page), 4096, MEM_COMMIT, PAGE_READWRITE) != nullptr,
                "sparse image data commit failed");
        }
        put(base + e::context_player_manager_offset, std::uint32_t{0x100});
        put(base + e::tls_index, static_cast<std::uint32_t>(_tls_index));
        client = arena.take(0x1000); context = arena.take(0x2000);
        const auto manager = arena.take(0x1000), list = arena.take(64), player = arena.take(0x1000);
        entity = arena.take(0x1000); const auto player_handle = arena.take(64);
        const auto collection = arena.take(64), component = arena.take(0x1000);
        core = arena.take(0x1000); skater_context = arena.take(0x2000); rig = arena.take(0x6000);
        const auto holder = arena.take(64), board = arena.take(0x1000), rig_physics = arena.take(0x1000);
        const auto board_parts = arena.take(0x1000), rig_parts = arena.take(0x3000);
        world = arena.take(0x1000); state = arena.take(0x2000);
        put(client, base + e::client_vtable); put(client + r::client_context, context);
        put(client + r::client_phase, std::uint32_t{13}); put(context + 0x100, manager);
        put(manager, base + e::local_player_manager_vtable);
        put(manager + r::player_begin, list); put(manager + r::player_end, list + sizeof(std::uintptr_t)); put(list, player);
        put(player, base + e::local_player_vtable); put(player + r::player_context, context);
        put(player + r::player_local, std::uint8_t{1}); put(player + r::player_remote, std::uint8_t{0});
        put(player + r::player_entity, entity); put(player + r::player_handle, player_handle);
        put(player_handle, entity + sizeof(std::uintptr_t)); put(entity, base + e::skater_entity_vtable);
        put(entity + r::entity_context, context); put(entity + r::entity_player, player);
        put(entity + r::entity_collection, collection); put(entity + r::entity_component, component);
        put(collection, entity); put(component, base + e::skater_component_vtable);
        put(component + r::component_collection, collection); put(component + r::component_core, core);
        put(core, base + addr::no_bail::bail_core_vtable); put(core + r::core_context, skater_context);
        put(core + r::core_rig, rig); put(rig, skater_context); put(rig + r::rig_core, core);
        put(core + k::board_holder_offset, holder); put(holder + k::board_physics_offset, board);
        put(rig + k::rig_physics_offset, rig_physics);
        put(board, base + k::board_physics_vtable); put(rig_physics, base + k::rig_physics_vtable);
        put(board + k::physics_bodies_offset, board_parts); put(rig_physics + k::physics_bodies_offset, rig_parts);
        put(board_parts, k::board_body_count); put(rig_parts, k::rig_body_count);
        for (std::size_t i = 0; i < 32; ++i) {
            const auto part = i < 9 ? board_parts + i * k::physics_body_size : rig_parts + (i - 8) * k::physics_body_size;
            put(part + k::body_owner_offset, i < 9 ? board : rig_physics);
        }
        put(context + test_world_field, world); put(world + r::world_state, state);
        put(skater_context + r::context_seconds, 1.f / 60.f);
        install_tls(context);
        setup_pool();
        InitializeSRWLock(&service.lock); InitializeSRWLock(&clock_feed.lock);
        service.slots = {}; service.api = {}; service.thread = GetCurrentThreadId();
        service.owner_close_uncertain.store(false, std::memory_order_relaxed); // isolate constructed process cases
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
        reset_reactivation_source_fixture();
#endif
        service.base = base; service.client = client; service.world = world; service.state = state;
        service.context = context; service.generation = handle.generation; service.world_generation = 23;
        service.eligible = true; service.tick_at = test_clock::now; service.hooked = true;
        service.api.base = base; service.api.world = world_read;
        clock_world.store(world_read, std::memory_order_release);
        service.api.body_valid = body_valid_read; service.api.shape_valid = shape_valid_read;
        service.api.allocate = forbidden_allocate; service.api.capsule = forbidden_capsule;
        service.api.motion = forbidden_integer; service.api.inverse_mass = forbidden_scalar;
        service.api.clear = forbidden_touch; service.api.wake = forbidden_touch;
        service.api.categories = forbidden_mask; service.api.collides = forbidden_mask; service.api.owner = forbidden_owner;
        service.api.com = service.api.transform = service.api.linear = service.api.angular = service.api.force =
            service.api.torque = service.api.inertia = service.api.clear_force = service.api.clear_torque = forbidden_vector;
        Anchor actual;
        check(capture(actual), "actual full capture failed in seeded native/TLS fixture");
        auto& s = slot(); s.owner = owner; s.handle = handle; s.anchor = actual;
        s.definition.mass = 12; s.definition.inertia = {2, 3, 4}; s.definition.count = 1;
        s.definition.capsules[0] = {{0, 0, 0}, {0, 1, 0}, .2f}; s.definition.rotation = {0, 0, 0, 1};
        s.body = {world, body_index, body_generation}; s.shapes[0] = {world, shape_index, shape_generation};
        s.made = 1; s.attempted = s.body_observed = s.active = true;
        s.latest.mass = 999; s.latest.position = {-13, -0.f, 42}; s.latest.epoch = {23, handle.generation, 77, 9, 1.f / 60.f};
        s.mailbox.count = 1; s.mailbox.sequence = 44;
        s.mailbox.receipts[0].outcome = Outcome::applied; s.mailbox.receipts[0].sequence = 44;
        s.mailbox.receipts[0].produced = {23, handle.generation, 0, 0, 1.f / 60.f};
        clock_feed.sequence = 0; clock_feed.serial = clock_feed.observed = 0; clock_feed.time = 0;
        clock_feed.owner = {}; clock_feed.game_context = clock_feed.world = clock_feed.state = 0;
        step();
        check(pool_current(s, true) && producer_owner(s, s.body), "actual pool qualification failed in fixture");
    }
    ~Fixture() {
        service.hooked = false; service.eligible = false; service.slots = {};
        VirtualFree(image_, 0, MEM_RELEASE);
    }
    Slot& slot() { return service.slots[0]; }
    void step() { physics_step({base, entity, core, skater_context, rig}, 1.f / 60.f, false); }
    MeasuredSource source() {
        MeasuredSource value;
        SetLastError(0x1234);
        check(capture_source(owner, handle, value), "actual client source capture failed");
        check(GetLastError() == 0x1234, "capture changed LastError");
        return value;
    }
    void protect_position(DWORD mode) {
        DWORD old{};
        check(VirtualProtect(reinterpret_cast<void*>(position), 4096, mode, &old) != 0, "position guard failed");
    }
private:
    void* image_{};
    void setup_pool() {
        position = arena.take(4096, 4096); rotation = arena.take(4096, 4096);
        velocity = arena.take(4096, 4096); spin = arena.take(4096, 4096);
        put(state + r::position_ring, Ring{position, capacity, 0, 1});
        put(state + r::rotation_ring, Ring{rotation, capacity, 0, 1});
        put(state + r::velocity_ring, Ring{velocity, capacity, 0, 1});
        put(state + r::spin_ring, Ring{spin, capacity, 0, 1});
        put(position + body_index * sizeof(V4), V4{12.5f, -0.f, 7, 0});
        put(rotation + body_index * sizeof(V4), V4{1, 0, 0, 0});
        put(velocity + body_index * sizeof(V4), V4{2, -0.f, 3, 0});
        put(spin + body_index * sizeof(V4), V4{});
        const auto com = arena.take(capacity * sizeof(V4)), local = arena.take(capacity * sizeof(V4));
        const auto ratio = arena.take(capacity * sizeof(V4)), inverse = arena.take(capacity * sizeof(float));
        put(state + r::local_com, com); put(state + r::local_rotation, local);
        put(state + r::inertia_ratio_array, ratio); put(state + r::inverse_mass_array, inverse);
        put(local + body_index * sizeof(V4), V4{1, 0, 0, 0});
        put(ratio + body_index * sizeof(V4), V4{6, 4, 3, 0}); put(inverse + body_index * sizeof(float), 1.f / 12.f);
        body_generations = arena.take(capacity * sizeof(std::uint32_t));
        allocations = arena.take(64); dynamics = arena.take(64);
        put(world + r::world_body_generations, body_generations);
        put(body_generations + body_index * sizeof(std::uint32_t), body_generation);
        put(state + r::allocated_bits, allocations); put(allocations, 1U << body_index);
        put(state + r::dynamic_bits, dynamics); put(dynamics, 1U << body_index);
        const auto shape_bits = arena.take(64), shape_generations = arena.take(64), shape_owners = arena.take(capacity * 4);
        categories = arena.take(capacity * 4); collisions = arena.take(capacity * 4);
        put(state + r::shape_allocated_bits, shape_bits); put(shape_bits, 1U << shape_index);
        put(state + r::shape_generations, shape_generations); put(shape_generations + shape_index, std::uint8_t{shape_generation});
        put(state + r::shape_owners, shape_owners); put(shape_owners + shape_index * 4, 0xffffffffU);
        put(state + r::shape_categories, categories); put(categories + shape_index * 4, r::safe_categories);
        put(state + r::shape_collides, collisions); put(collisions + shape_index * 4, r::safe_world_collisions);
    }
};

void capture_does_not_publish() {
    Fixture f;
    std::array<unsigned char, sizeof(Mailbox)> mailbox{};
    std::memcpy(mailbox.data(), &f.slot().mailbox, mailbox.size());
    const auto latest = f.slot().latest;
    const auto source = f.source();
    check(body_query::same_sample(f.slot().latest, latest), "capture mutated latest");
    check(std::memcmp(mailbox.data(), &f.slot().mailbox, mailbox.size()) == 0, "capture mutated mailbox or successor");
    check(source.sample().position[0] == 12.5f && source.sample().mass != latest.mass, "source copied latest instead of native measurement");
    check(std::bit_cast<std::uint32_t>(source.sample().position[1]) == 0x80000000U, "measurement normalized signed zero");
    check(source.native_world() == f.world && source.native_state() == f.state, "native join identity lost");
    check(source.sample().epoch.world == 23 && source.sample().epoch.body == f.handle.generation, "original SDK epochs lost");
    check(source.clock_observed_ms() == 10000 && source.captured_ms() == 10000, "clock/capture walls relabeled");
    const auto saved = source.sample();
    put(f.position + body_index * sizeof(V4), V4{99, 88, 77, 0});
    test_clock::now = 10010; f.step();
    f.protect_position(PAGE_NOACCESS);
    const auto model_before = test_facts::model_calls.load();
    SourceBorrow borrow;
    SetLastError(0x1234);
    check(try_borrow_source(owner, source, borrow) && borrow.get(), "new current clock rejected old fresh immutable source");
    check(GetLastError() == 0x1234, "borrow/get changed LastError");
    check(body_query::same_sample(borrow.get()->sample(), saved), "borrow reread/rewrote old measured pose/time");
    check(borrow.get()->clock_observed_ms() == 10000, "borrow refreshed original clock age");
    check(test_facts::model_calls.load() == model_before, "native borrow called multiplayer model");
    check(!try_borrow_source(owner, source, borrow) && borrow.get(), "occupied-out refusal implicitly released prior borrow");
    f.protect_position(PAGE_READWRITE);
}

void owner_generation_world_and_pool_failures() {
    Fixture f;
    const auto source = f.source();
    const auto refuses = [&](const char* why) {
        SourceBorrow borrow;
        SetLastError(0x1234);
        check(!try_borrow_source(owner, source, borrow) && !borrow.get(), why);
        check(GetLastError() == 0x1234, "refused borrow changed LastError");
    };
    { SourceBorrow b; check(!try_borrow_source(owner + 1, source, b), "wrong owner accepted"); }
    ++f.slot().handle.generation; refuses("wrong SDK generation accepted"); --f.slot().handle.generation;
    ++service.world_generation; refuses("wrong SDK body-world generation accepted"); --service.world_generation;
    f.slot().active = false; refuses("inactive accepted"); f.slot().active = true;
    f.slot().retained = true; refuses("retained accepted"); f.slot().retained = false;
    f.slot().quarantined = true; refuses("quarantine accepted"); f.slot().quarantined = false;
    put(f.allocations, std::uint32_t{0}); refuses("unallocated native body accepted"); put(f.allocations, 1U << body_index);
    put(f.dynamics, std::uint32_t{0}); refuses("nondynamic native body accepted"); put(f.dynamics, 1U << body_index);
    put(f.categories + shape_index * 4, std::uint32_t{1}); refuses("changed pool category accepted");
    put(f.categories + shape_index * 4, r::safe_categories);
    put(f.collisions + shape_index * 4, std::uint32_t{0}); refuses("parked collision mask accepted");
    put(f.collisions + shape_index * 4, r::safe_world_collisions);
    put(f.context + test_world_field, f.world + 64); refuses("changed native world accepted");
    put(f.context + test_world_field, f.world);
    put(f.world + r::world_state, f.state + 64); refuses("changed native state accepted"); put(f.world + r::world_state, f.state);
    put(f.entity + r::entity_teleport, std::uint8_t{1}); refuses("changed captured owner field accepted");
    put(f.entity + r::entity_teleport, std::uint8_t{0});
    SourceBorrow b;
    check(try_borrow_source(owner, source, b), "restored constructed identities should pass sampled checks");
    put(f.body_generations + body_index * sizeof(std::uint32_t), body_generation + 1);
    check(!b.get(), "SDK shared lock falsely pinned changed native generation");
    put(f.body_generations + body_index * sizeof(std::uint32_t), body_generation);
    check(b.get() != nullptr, "same-value restoration should expose declared endpoint/ABA limitation");
}

void original_age_and_clock_failures() {
    Fixture f;
    const auto source = f.source();
    test_clock::now = 10099;
    const auto recaptured = f.source();
    check(recaptured.captured_ms() == 10099 && recaptured.clock_observed_ms() == 10000,
        "recapture disguised original clock age");
    { SourceBorrow b; check(try_borrow_source(owner, source, b), "fresh99ms source refused"); }
    test_clock::now = 10100;
    { SourceBorrow b; check(!try_borrow_source(owner, source, b), "100ms source accepted"); }
    { SourceBorrow b; check(!try_borrow_source(owner, recaptured, b), "recapture extended original expiry"); }
    MeasuredSource empty;
    check(!capture_source(owner, f.handle, empty) && !empty.sample().epoch.serial, "stale capture published source");
    test_clock::now = 9999;
    { SourceBorrow b; check(!try_borrow_source(owner, source, b), "wall rewind accepted"); }
    test_clock::now = 10000;
    ++clock_feed.sequence;
    { SourceBorrow b; check(!try_borrow_source(owner, source, b), "unpublished clock sequence accepted"); }
    --clock_feed.sequence;
    clock_feed.time = -1;
    { SourceBorrow b; check(!try_borrow_source(owner, source, b), "clock regression accepted"); }
    clock_feed.time = 1.f / 60.f;
    ++clock_feed.serial; ++clock_feed.sequence;
    { SourceBorrow b; check(!try_borrow_source(owner, source, b), "advanced serial without time advance accepted"); }
}

void unreadable_and_failed_capture_nonmutation() {
    Fixture f;
    const auto source = f.source();
    std::array<unsigned char, sizeof(Mailbox)> mailbox{};
    std::memcpy(mailbox.data(), &f.slot().mailbox, mailbox.size());
    const auto latest = f.slot().latest;
    f.protect_position(PAGE_NOACCESS);
    MeasuredSource failed = source;
    SetLastError(0x1234);
    check(!capture_source(owner, f.handle, failed) && !failed.sample().epoch.serial, "unreadable pose capture did not clear output");
    check(GetLastError() == 0x1234, "failed capture changed LastError");
    check(body_query::same_sample(f.slot().latest, latest) && std::memcmp(mailbox.data(), &f.slot().mailbox, mailbox.size()) == 0,
        "failed capture mutated command/latest state");
    f.protect_position(PAGE_READWRITE);
    void* guard = VirtualAlloc(nullptr, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_NOACCESS);
    check(guard != nullptr, "unreadable native allocation fixture failed");
    put(f.state + r::allocated_bits, reinterpret_cast<std::uintptr_t>(guard));
    { SourceBorrow b; check(!try_borrow_source(owner, source, b), "unreadable native allocation accepted"); }
    put(f.state + r::allocated_bits, f.allocations);
    VirtualFree(guard, 0, MEM_RELEASE);
}

void owner_clock_and_closing_clock_refusal() {
    Fixture f;
    const auto source = f.source();
    const auto owner_before = clock_feed.owner;
    clock_feed.owner.entity += 64;
    { SourceBorrow b; check(!try_borrow_source(owner, source, b), "wrong owner clock accepted"); }
    clock_feed.owner = owner_before;
    const auto serial_before = clock_feed.serial;
    test_clock::reads = 0; test_clock::inject_after_open_clock = true;
    {
        SourceBorrow b;
        check(!try_borrow_source(owner, source, b) && !b.get(), "closing clock advance crossed whole-operation fence");
    }
    test_clock::inject_after_open_clock = false;
    check(clock_feed.serial == serial_before + 1 && !test_clock::advance_at_world_read.load(),
        "test did not inject exactly one real feed between opening and closing clocks");
    { SourceBorrow b; check(try_borrow_source(owner, source, b), "stable later clock refused after rejected operation"); }
    check(source.sample().epoch.serial == serial_before, "rejected operation rebased the immutable source");
}

void try_locks_and_thread_affinity() {
    Fixture f;
    const auto source = f.source();
    bool accepted = true;
    AcquireSRWLockExclusive(&service.lock);
    std::thread blocked([&] { install_tls(f.context); SourceBorrow b; accepted = try_borrow_source(owner, source, b); });
    blocked.join();
    ReleaseSRWLockExclusive(&service.lock);
    check(!accepted, "native borrow waited for or crossed SDK exclusive lock");
    AcquireSRWLockExclusive(&clock_feed.lock);
    { SourceBorrow b; check(!try_borrow_source(owner, source, b), "native borrow crossed busy clock lock"); }
    ReleaseSRWLockExclusive(&clock_feed.lock);
    bool capture_ok = true;
    std::thread wrong_client([&] { MeasuredSource b; capture_ok = capture_source(owner, f.handle, b); });
    wrong_client.join();
    check(!capture_ok, "client capture accepted wrong thread");
    { SourceBorrow b; SetLastError(0x5678); check(try_borrow_source(owner, source, b), "final scoped borrow failed"); }
    check(GetLastError() == 0x5678, "borrow destruction changed LastError");
}

void sdk_release_cannot_cross_borrow() {
    Fixture f;
    const auto source = f.source();
    HANDLE held = CreateEventW(nullptr, TRUE, FALSE, nullptr), leave = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE release_entered = CreateEventW(nullptr, TRUE, FALSE, nullptr), release_finished = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    check(held && leave && release_entered && release_finished, "thread coordination failed");
    bool borrow_ok{}, blocked{};
    std::thread native([&] {
        install_tls(f.context);
        SourceBorrow b;
        borrow_ok = try_borrow_source(owner, source, b);
        SetEvent(held);
        WaitForSingleObject(leave, 2000);
    });
    check(WaitForSingleObject(held, 2000) == WAIT_OBJECT_0 && borrow_ok, "native thread could not hold actual shared borrow");
    std::thread controller([&] {
        WaitForSingleObject(release_entered, 2000);
        blocked = WaitForSingleObject(release_finished, 50) == WAIT_TIMEOUT;
        SetEvent(leave);
    });
    // Multiplayer becoming active is an independent constructed fact: release
    // must retain/quarantine rather than call native setters after lock drain.
    test_facts::multiplayer_active = true;
    SetEvent(release_entered);
    const auto result = release(owner, f.handle);
    SetEvent(release_finished);
    native.join(); controller.join();
    check(blocked && f.slot().retained && !f.slot().active, "SDK release crossed an active shared borrow");
    check(!result.empty() && f.slot().quarantined, "unknown park duty was disguised as clean retirement");
    for (const auto handle : {held, leave, release_entered, release_finished}) CloseHandle(handle);
}

// A renewal proof is World's latest issued sample of the exact measured
// allocation, with a physics step observed under 100 ms ago. One Try shared
// lock: a callback's shared borrow never refuses it. No model query, and
// latest and the mailbox are left as they were.
void renewal_proof_latest_fresh_shared_and_read_only() {
    Fixture f;
    const auto identity = f.source();
    Sample issued{};
    check(read(owner, f.handle, issued).empty(), "World read did not issue a latest sample");
    const auto latest = f.slot().latest;
    std::array<unsigned char, sizeof(Mailbox)> mailbox{};
    std::memcpy(mailbox.data(), &f.slot().mailbox, mailbox.size());
    const auto models = test_facts::model_calls.load();
    std::uint64_t current{};
    SetLastError(0x1234);
    check(check_renewal_proof(owner, identity, issued.epoch, current) == RenewalProof::current &&
        current == issued.epoch.serial, "the latest issued sample with a fresh clock was refused");
    check(GetLastError() == 0x1234, "the renewal proof changed LastError");
    check(test_facts::model_calls.load() == models, "the renewal proof queried the multiplayer model");
    check(body_query::same_sample(f.slot().latest, latest) &&
        std::memcmp(mailbox.data(), &f.slot().mailbox, mailbox.size()) == 0, "the renewal proof changed latest or the mailbox");
    {
        HANDLE held = CreateEventW(nullptr, TRUE, FALSE, nullptr), leave = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        check(held && leave, "thread coordination failed");
        bool borrowed{};
        std::thread native([&] {
            install_tls(f.context);
            SourceBorrow b;
            borrowed = try_borrow_source(owner, identity, b);
            SetEvent(held);
            WaitForSingleObject(leave, 2000);
        });
        const bool holding = WaitForSingleObject(held, 2000) == WAIT_OBJECT_0 && borrowed;
        const auto shared = check_renewal_proof(owner, identity, issued.epoch, current);
        SetEvent(leave); native.join();
        CloseHandle(held); CloseHandle(leave);
        check(holding, "native thread could not hold a shared borrow");
        check(shared == RenewalProof::current, "a callback's shared borrow refused the renewal proof");
    }
    AcquireSRWLockExclusive(&service.lock);
    const auto busy = check_renewal_proof(owner, identity, issued.epoch, current);
    ReleaseSRWLockExclusive(&service.lock);
    check(busy == RenewalProof::busy && !current, "an exclusive World holder did not read busy");
    // A physics step holding the clock feed is busy too, not a stale clock; a
    // feed that names another actor is still stale.
    AcquireSRWLockExclusive(&clock_feed.lock);
    const auto feed_busy = check_renewal_proof(owner, identity, issued.epoch, current);
    ReleaseSRWLockExclusive(&clock_feed.lock);
    check(feed_busy == RenewalProof::busy && !current, "a busy clock feed did not read busy");
    const auto feed_owner = clock_feed.owner;
    clock_feed.owner.entity += 64;
    const auto foreign_feed = check_renewal_proof(owner, identity, issued.epoch, current);
    clock_feed.owner = feed_owner;
    check(foreign_feed == RenewalProof::clock_stale && !current, "another actor's clock feed did not read clock_stale");
    check(check_renewal_proof(owner, identity, issued.epoch, current) == RenewalProof::current, "the restored clock feed was refused");
    // A newer physics step: the proof is still the latest, and the step is reported.
    test_clock::now = 10016; f.step();
    check(check_renewal_proof(owner, identity, issued.epoch, current) == RenewalProof::current &&
        current == issued.epoch.serial + 1, "a newer physics step was not reported");
    // A newer read leaves the older genuine sample behind.
    Sample newer{};
    check(read(owner, f.handle, newer).empty() && newer.epoch.serial == issued.epoch.serial + 1, "the second read failed");
    check(check_renewal_proof(owner, identity, issued.epoch, current) == RenewalProof::not_latest && !current,
        "an older genuine sample passed as the latest");
    check(check_renewal_proof(owner, identity, newer.epoch, current) == RenewalProof::current, "the newer sample was refused");
    // The current step must have been observed under 100 ms ago.
    test_clock::now = 10115;
    check(check_renewal_proof(owner, identity, newer.epoch, current) == RenewalProof::current, "a 99 ms old step was refused");
    test_clock::now = 10116;
    check(check_renewal_proof(owner, identity, newer.epoch, current) == RenewalProof::clock_stale && !current,
        "a 100 ms old step was accepted");
    test_clock::now = 10016;
    // The exact identity, a body still live, and the client thread only.
    ++service.world_generation;
    check(check_renewal_proof(owner, identity, newer.epoch, current) == RenewalProof::body_unavailable,
        "a changed SDK world generation passed");
    --service.world_generation;
    f.slot().release_requested = true;
    check(check_renewal_proof(owner, identity, newer.epoch, current) == RenewalProof::body_unavailable,
        "a release-requested body passed");
    f.slot().release_requested = false;
    check(check_renewal_proof(owner + 1, identity, newer.epoch, current) == RenewalProof::body_unavailable,
        "another owner passed");
    RenewalProof off_thread{RenewalProof::current};
    std::thread wrong([&] { std::uint64_t ignored{}; off_thread = check_renewal_proof(owner, identity, newer.epoch, ignored); });
    wrong.join();
    check(off_thread == RenewalProof::body_unavailable, "the check ran off the client thread");
    check(check_renewal_proof(owner, identity, newer.epoch, current) == RenewalProof::current, "the restored facts were refused");
}

// These cases execute actual probe_batch/Service/Slot/Clock and body-hit
// qualification over constructed native arrays. The one external native query
// is a counted ABI stand-in; it does not prove retail ray safety or consumption.
class ContactFixture : public Fixture {
public:
    static constexpr std::uint32_t foreign_index=1, foreign_generation=9;
    static constexpr std::array<std::uint32_t,2> hit_shapes{2,3};
    static constexpr std::array<std::uint8_t,2> hit_generations{13,14};
    unsigned calls{};
    bool normals=true, hit_owned{}, hit_unknown{};
    std::function<void(unsigned)> during_query;
    std::vector<bool> contact_options;
    std::uintptr_t shape_bodies{};
    ContactFixture() {
        put(allocations,(1U<<body_index)|(1U<<foreign_index));
        put(body_generations+foreign_index*4,foreign_generation);
        put(position+foreign_index*sizeof(V4),V4{0,0,0,0});
        put(velocity+foreign_index*sizeof(V4),V4{2,0,0,0});
        put(spin+foreign_index*sizeof(V4),V4{0,1,0,0});
        const auto bits=load<std::uintptr_t>(state+r::shape_allocated_bits);
        const auto generations=load<std::uintptr_t>(state+r::shape_generations);
        put(bits,(1U<<shape_index)|(1U<<hit_shapes[0])|(1U<<hit_shapes[1]));
        shape_bodies=arena.take(capacity*4);
        put(state+r::shape_body_indices,shape_bodies);
        put(shape_bodies+shape_index*4,body_index);
        for(std::size_t i=0;i<hit_shapes.size();++i) {
            put(generations+hit_shapes[i],hit_generations[i]);
            put(shape_bodies+hit_shapes[i]*4,foreign_index);
        }
        test_facts::probe_callback=[&](const auto& from,const auto& to,unsigned allowed,bool contact) {
            ++calls;contact_options.push_back(contact);
            check(allowed>=1 && allowed<=2,"Service lost actual cast budget");
            if(during_query) during_query(calls);
            BoundedLocalSurfaceProbe result;
            result.native_casts=1;auto& hit=result.surface;
            hit.available=true;hit.hit=true;hit.context=context;hit.world=world;
            hit.fraction=.5f;
            for(std::size_t i=0;i<from.size();++i) hit.position[i]=(from[i]+to[i])*.5f;
            const auto ordinal=(calls-1)%hit_shapes.size();
            NativeHandle shape{world,hit_owned?shape_index:hit_shapes[ordinal],
                hit_owned?shape_generation:hit_generations[ordinal]};
            if(hit_unknown) shape.generation++;
            std::memcpy(hit.hit_body.data(),&shape,sizeof(shape));
            hit.normal={0,1,0};hit.normal_available=contact && normals;
            if(hit.normal_available) hit.position[2]+=.01f;
            return result;
        };
    }
    ~ContactFixture(){test_facts::probe_callback={};}
    body_query::Request request(std::size_t rays=1,bool contact=true) {
        body_query::Request out;out.count=rays;out.require_contact=contact;
        check(read(owner,handle,out.observation).empty(),"Service test could not publish measured canonical sample");
        for(std::size_t i=0;i<rays;++i) out.rays[i]={{1,2,0},{1,-2,0}};
        return out;
    }
};

void service_contact_opt_in_and_read_only() {
    ContactFixture f;auto request=f.request(1,false);
    std::array<unsigned char,sizeof(Mailbox)> mailbox{};
    std::memcpy(mailbox.data(),&f.slot().mailbox,mailbox.size());
    const auto latest=f.slot().latest;
    SetLastError(0x4321);
    auto out=probe_batch(owner,f.handle,request,64);
    check(GetLastError()==0x4321,"Service contact changed LastError");
    check(out.available && out.native_casts==1 && !out.rays[0].normal_available &&
        !out.rays[0].surface_velocity_available && !f.contact_options.back(),"legacy Service geometry collected contact");
    request.require_contact=true;out=probe_batch(owner,f.handle,request,64);
    check(out.available && out.native_casts==1 && out.rays[0].normal_available && f.contact_options.back(),
        "actual Service did not join required contact");
    check(out.rays[0].position==Vec{1,0,.01f} && out.rays[0].surface_velocity_available &&
        out.rays[0].surface_velocity==Vec{2.01f,0,-1},
        "actual Service fabricated static motion or lost cross sign");
    check((load<std::uint32_t>(f.dynamics)&(1U<<f.foreign_index))==0,
        "moving foreign witness unexpectedly depended on a dynamic bit");
    f.normals=false;out=probe_batch(owner,f.handle,request,64);
    check(!out.available && out.failure==body_query::Failure::contact_measurement_unavailable && out.native_casts==1,
        "required unknown normal became support");
    f.normals=true;put(f.velocity+f.foreign_index*sizeof(V4),V4{NAN,0,0,0});
    out=probe_batch(owner,f.handle,request,64);
    check(!out.available && out.failure==body_query::Failure::contact_measurement_unavailable && out.native_casts==1,
        "required malformed foreign motion became support");
    request.require_contact=false;out=probe_batch(owner,f.handle,request,64);
    check(out.available && !out.rays[0].surface_velocity_available && !f.contact_options.back(),
        "legacy geometry gained a foreign motion read/fence dependency");
    check(body_query::same_sample(latest,f.slot().latest) &&
        std::memcmp(mailbox.data(),&f.slot().mailbox,mailbox.size())==0,"contact query published a pose/command/receipt");
}

void service_whole_batch_contact_fences() {
    for(unsigned variant=0;variant<3;++variant) {
        ContactFixture f;auto request=f.request(2);
        f.during_query=[&](unsigned calls) {
            if(calls!=2)return;
            if(variant==0)put(f.velocity+f.foreign_index*sizeof(V4),V4{3,0,0,0});
            if(variant==1)put(f.shape_bodies+f.hit_shapes[0]*4,body_index);
            if(variant==2)f.step();
        };
        const auto out=probe_batch(owner,f.handle,request,64);
        check(f.calls==2 && out.native_casts==2,"contact fence lost actual two-cast accounting");
        check(!out.available && out.failure==body_query::Failure::observation_changed,
            "Service accepted changed foreign motion/individual shape/canonical native clock");
        check(out.rays[0].status==body_query::Status::unavailable && !out.rays[0].normal_available &&
            !out.rays[1].surface_velocity_available,"whole-batch refusal leaked partial contacts");
    }
}

void service_actor_and_nearest_hit_refusals() {
    ContactFixture f;auto request=f.request();request.exclude_local_actor=true;
    auto out=probe_batch(owner,f.handle,request,64);
    check(!out.available && out.failure==body_query::Failure::local_actor_exclusion_unavailable &&
        out.native_casts==0 && f.calls==0,"actor exclusion was bypassed or reached a native cast");
    request.exclude_local_actor=false;f.hit_owned=true;out=probe_batch(owner,f.handle,request,64);
    check(!out.available && out.native_casts==1 && f.calls==1,"owned nearest hit became clear or was recast through");
    f.hit_owned=false;f.hit_unknown=true;out=probe_batch(owner,f.handle,request,64);
    check(!out.available && out.native_casts==1 && f.calls==2,"unknown nearest hit became foreign/clear or retried");
}

// The actual Service forwards the preset to its one counted geometry query and
// changes nothing else: the same measured-contact, owned-hit, actor and fence rules.
void service_forwards_query_preset_without_relaxing_refusals() {
    using body_query::QueryPreset;
    test_facts::probe_presets.clear();
    {
        ContactFixture f;auto request=f.request();
        auto out=probe_batch(owner,f.handle,request,64);
        check(out.available && f.calls==1 && test_facts::probe_presets==std::vector<QueryPreset>{QueryPreset::camera},
            "default Service query did not send the camera preset");
        request.preset=QueryPreset::terrain;SetLastError(0x5150);
        out=probe_batch(owner,f.handle,request,64);
        check(GetLastError()==0x5150,"terrain Service query changed LastError");
        check(out.available && out.native_casts==1 && f.calls==2 && test_facts::probe_presets.back()==QueryPreset::terrain &&
            f.contact_options.back(),"Service dropped the terrain preset or its contact request");
        check(out.rays[0].normal_available && out.rays[0].normal==Vec{0,1,0} && out.rays[0].surface_velocity_available &&
            out.rays[0].surface_velocity==Vec{2.01f,0,-1},"terrain lost the measured normal or the moving surface's point motion");
        f.normals=false;out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==body_query::Failure::contact_measurement_unavailable && out.native_casts==1 && f.calls==3,
            "terrain admitted a required contact without a measured normal");
        f.normals=true;
        for(const auto preset:{QueryPreset::camera,QueryPreset::terrain}) {
            request.preset=preset;request.exclude_local_actor=true;const auto calls=f.calls;
            out=probe_batch(owner,f.handle,request,64);
            check(!out.available && out.failure==body_query::Failure::local_actor_exclusion_unavailable && !out.native_casts && f.calls==calls,
                "a preset bypassed the zero-cast actor exclusion refusal");
        }
        request.exclude_local_actor=false;request.preset=QueryPreset::terrain;f.hit_owned=true;
        out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.native_casts==1 && f.calls==4 && test_facts::probe_presets.back()==QueryPreset::terrain,
            "terrain owned nearest hit became clear or was recast through");
        f.hit_owned=false;
        for(const auto unknown:{static_cast<QueryPreset>(3),static_cast<QueryPreset>(255)}) {
            request.preset=unknown;const auto presets=test_facts::probe_presets.size();
            out=probe_batch(owner,f.handle,request,64);
            check(!out.available && out.failure==body_query::Failure::invalid && !out.native_casts && f.calls==4 &&
                test_facts::probe_presets.size()==presets,"an unknown preset reached the counted geometry query");
        }
    }
    ContactFixture f;auto request=f.request(2);request.preset=QueryPreset::terrain;
    f.during_query=[&](unsigned calls) { if(calls==2) f.step(); };
    const auto out=probe_batch(owner,f.handle,request,64);
    check(f.calls==2 && out.native_casts==2 && !out.available && out.failure==body_query::Failure::observation_changed &&
        out.rays[0].status==body_query::Status::unavailable && !out.rays[0].normal_available,
        "terrain batch escaped the closing whole-batch fence");
}

// Optional shape categories over the actual Service: opt-in only, read after the
// actual hit qualified and was not owned, keyed by the hit shape rather than its
// mapped body, gated by the pinned getter bytes, and fenced before publication.
void service_shape_categories_are_opt_in_shape_bound_and_fenced() {
    using body_query::Failure;
    const auto pin=[](ContactFixture& f,bool exact) {
        // Commit only the synthetic image page that holds the pinned getter bytes.
        const auto at=f.base+r::shape_in_categories.rva;
        check(VirtualAlloc(reinterpret_cast<void*>(at&~std::uintptr_t{4095}),4096,MEM_COMMIT,PAGE_READWRITE)!=nullptr,
            "getter byte page commit failed");
        auto bytes=r::shape_in_categories.bytes;
        if(!exact) bytes[31]=static_cast<unsigned char>(bytes[31]^0x01U);
        put(at,bytes);
    };
    const auto masks=[](ContactFixture& f) {
        put(f.categories+ContactFixture::hit_shapes[0]*4,0x80000000U);
        put(f.categories+ContactFixture::hit_shapes[1]*4,0xffffffffU);
        // The mapped foreign body's own index holds a decoy for a body-index read.
        put(f.categories+ContactFixture::foreign_index*4,7U);
    };
    const auto none=[](const body_query::Result& out) {
        for(const auto& hit:out.rays) if(hit.in_categories_available) return false;
        return true;
    };
    {
        ContactFixture f;masks(f);auto request=f.request(2,false);request.include_shape_categories=true;
        auto out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.native_casts==2 && none(out),"unreadable getter bytes refused the batch or still read categories");
        pin(f,true);request.include_shape_categories=false;
        out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.native_casts==2 && none(out),"a default Service batch carried categories");
        request.include_shape_categories=true;SetLastError(0x5157);
        out=probe_batch(owner,f.handle,request,64);
        check(GetLastError()==0x5157,"category capture changed LastError");
        check(out.available && out.native_casts==2 && f.calls==6 &&
            out.rays[0].in_categories_available && out.rays[0].in_categories==0x80000000U &&
            out.rays[1].in_categories_available && out.rays[1].in_categories==0xffffffffU,
            "the Service lost, mixed or body-indexed its hit shape categories");
        check(out.rays[0].status==body_query::Status::hit && !out.rays[0].body,"categories minted a hit identity");
        pin(f,false);out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.native_casts==2 && none(out),"a getter byte mismatch refused the batch or still read categories");
        pin(f,true);request.exclude_local_actor=true;const auto calls=f.calls;
        out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::local_actor_exclusion_unavailable && !out.native_casts && f.calls==calls && none(out),
            "the option bypassed the zero-cast actor exclusion refusal");
        request.exclude_local_actor=false;f.hit_owned=true;out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.native_casts==1 && none(out),"an owned nearest hit was given a category or recast");
    }
    {
        // Category-only drift while the second ray runs drops only the first value.
        ContactFixture f;masks(f);pin(f,true);auto request=f.request(2,false);request.include_shape_categories=true;
        const auto second=f.calls+2;
        f.during_query=[&,second](unsigned calls) { if(calls==second) put(f.categories+ContactFixture::hit_shapes[0]*4,1U); };
        const auto out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.native_casts==2 && !out.rays[0].in_categories_available &&
            out.rays[1].in_categories_available && out.rays[1].in_categories==0xffffffffU,
            "category drift refused the batch or kept a stale value");
    }
    {
        // An identical copy at another address is still a replaced array.
        ContactFixture f;masks(f);pin(f,true);auto request=f.request(2,false);request.include_shape_categories=true;
        const auto copy=f.arena.take(capacity*4);
        for(std::uint32_t i=0;i<capacity;++i) put(copy+i*4,load<std::uint32_t>(f.categories+i*4));
        const auto second=f.calls+2;
        f.during_query=[&,second,copy](unsigned calls) { if(calls==second) put(f.state+r::shape_categories,copy); };
        const auto out=probe_batch(owner,f.handle,request,64);
        check(out.available && !out.rays[0].in_categories_available && out.rays[1].in_categories_available,
            "a replaced category array kept the old witness or refused the batch");
    }
    {
        // Identity drift is still a whole-batch refusal, with no category at all.
        ContactFixture f;masks(f);pin(f,true);auto request=f.request(2,false);request.include_shape_categories=true;
        const auto second=f.calls+2;
        f.during_query=[&,second](unsigned calls) { if(calls==second) put(f.shape_bodies+ContactFixture::hit_shapes[0]*4,body_index); };
        const auto out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::observation_changed && out.native_casts==2 && none(out),
            "shape identity drift became a missing category instead of a refusal");
    }
}

// The rest of the S-1 set over the actual Service. The named-actor-category
// requirement is refused with zero casts unless the preset's filter and the pinned
// getter qualify, is judged after the closing fence over the surviving values, and
// only then sets its fact; local_actor_excluded is never set. Each refused nearest
// hit names its reason, and hit owner slots follow the category rules.
void service_named_actor_categories_reasons_and_hit_owners() {
    using body_query::Failure; using body_query::QueryPreset;
    constexpr std::uint32_t static_template=0x2F90U, terrain_template=0xAD1U;
    const auto pin=[](ContactFixture& f,bool exact) {
        const auto at=f.base+r::shape_in_categories.rva;
        check(VirtualAlloc(reinterpret_cast<void*>(at&~std::uintptr_t{4095}),4096,MEM_COMMIT,PAGE_READWRITE)!=nullptr,
            "getter byte page commit failed");
        auto bytes=r::shape_in_categories.bytes;
        if(!exact) bytes[0]=static_cast<unsigned char>(bytes[0]^0x01U);
        put(at,bytes);
    };
    const auto masks=[](ContactFixture& f,std::uint32_t first,std::uint32_t second) {
        put(f.categories+ContactFixture::hit_shapes[0]*4,first);
        put(f.categories+ContactFixture::hit_shapes[1]*4,second);
    };
    // No value and no fact survives.
    const auto none=[](const body_query::Result& out) {
        for(const auto& hit:out.rays) if(hit.in_categories_available||hit.owner_available) return false;
        return !out.local_actor_excluded && !out.named_actor_categories_absent;
    };
    const auto required=[](ContactFixture& f,bool contact) {
        auto out=f.request(2,contact);out.require_named_actor_categories_absent=true;return out;
    };
    {
        // Before any cast: unreadable or mismatched getter bytes, a filter with a
        // named bit, and, first of all, the unchanged actor exclusion refusal.
        ContactFixture f;masks(f,static_template,static_template);auto request=required(f,false);
        test_facts::probe_presets.clear();
        auto out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::named_actor_categories_unavailable && !out.native_casts && !f.calls && none(out),
            "the requirement cast without readable getter bytes");
        pin(f,false);out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::named_actor_categories_unavailable && !out.native_casts && !f.calls && none(out),
            "the requirement cast past a getter byte mismatch");
        pin(f,true);request.preset=QueryPreset::all;out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::named_actor_categories_unavailable && !out.native_casts && !f.calls &&
            test_facts::probe_presets.empty() && none(out),"all reached a cast under the requirement");
        for(const auto preset:{QueryPreset::camera,QueryPreset::all}) {
            request.preset=preset;request.exclude_local_actor=true;out=probe_batch(owner,f.handle,request,64);
            check(!out.available && out.failure==Failure::local_actor_exclusion_unavailable && !out.native_casts && !f.calls && none(out),
                "the requirement displaced the zero-cast actor exclusion refusal");
        }
        // all as a diagnostic, without the requirement, reaches its counted query.
        request.exclude_local_actor=request.require_named_actor_categories_absent=false;request.include_shape_categories=true;
        out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.native_casts==2 && f.calls==2 &&
            test_facts::probe_presets==std::vector<QueryPreset>{QueryPreset::all,QueryPreset::all} &&
            out.rays[0].in_categories==static_template && !out.named_actor_categories_absent && !out.local_actor_excluded,
            "the all diagnostic did not reach its counted query or claimed a fact");
    }
    for(const bool contact:{false,true}) {
        // Static-template hits pass under camera, with or without measured contact,
        // and their values appear only when they are also asked for.
        ContactFixture f;masks(f,static_template,static_template);pin(f,true);auto request=required(f,contact);
        auto out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.native_casts==2 && out.named_actor_categories_absent && !out.local_actor_excluded &&
            !out.rays[0].in_categories_available && !out.rays[1].in_categories_available,
            "a Static-template batch was refused, claimed an exclusion or showed categories");
        check(!contact || (out.rays[0].normal_available && out.rays[1].surface_velocity_available),"the requirement lost measured contact");
        request.include_shape_categories=true;out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.named_actor_categories_absent && out.rays[0].in_categories==static_template &&
            out.rays[1].in_categories_available,"the requirement and the category diagnostic did not combine");
    }
    {
        // The overlap rule uses the preset's own filter: Static lacks the Terrain bit.
        ContactFixture f;masks(f,terrain_template,static_template);pin(f,true);auto request=required(f,false);
        request.preset=QueryPreset::terrain;
        auto out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::hit_categories_inconsistent && out.native_casts==2 && none(out),
            "a Static-template hit passed the terrain filter's overlap rule");
        masks(f,terrain_template,terrain_template);out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.named_actor_categories_absent && test_facts::probe_presets.back()==QueryPreset::terrain,
            "a Terrain-template batch was refused under terrain");
    }
    for(const unsigned bit:{2U,3U,21U,25U,26U,28U,29U,31U}) {
        ContactFixture f;masks(f,static_template,static_template|(1U<<bit));pin(f,true);auto request=required(f,false);
        request.include_shape_categories=true;
        const auto out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::hit_named_actor_category && out.native_casts==2 && none(out) &&
            out.rays[1].status==body_query::Status::unavailable,"a hit carrying a named actor category passed or leaked");
    }
    for(const std::uint32_t missed:{0x40U,0U}) {
        ContactFixture f;masks(f,static_template,missed);pin(f,true);auto request=required(f,false);
        const auto out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::hit_categories_inconsistent && out.native_casts==2 && none(out),
            "a hit whose categories miss the filter passed");
    }
    {
        // A replacement array whose elements 0-3 lie on an unreadable page: both hit
        // shapes' values cannot be read, while the owned shape's element 5 can.
        ContactFixture f;pin(f,true);
        const auto pages=f.arena.take(8192,4096);DWORD old{};
        check(VirtualProtect(reinterpret_cast<void*>(pages),4096,PAGE_NOACCESS,&old)!=0,"category guard failed");
        put(f.state+r::shape_categories,pages+4096-16);
        auto request=required(f,false);
        auto out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::hit_categories_unavailable && out.native_casts==2 && none(out),
            "an unreadable category passed the requirement");
        request.require_named_actor_categories_absent=false;request.include_shape_categories=true;
        out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.native_casts==2 && !out.rays[0].in_categories_available && !out.rays[1].in_categories_available,
            "without the requirement an unreadable category was not merely absent");
        check(VirtualProtect(reinterpret_cast<void*>(pages),4096,PAGE_READWRITE,&old)!=0,"category guard restore failed");
    }
    {
        // A value changed before the closing fence is dropped, so it cannot pass.
        ContactFixture f;masks(f,static_template,static_template);pin(f,true);auto request=required(f,false);
        f.during_query=[&](unsigned calls) { if(calls==2) put(f.categories+ContactFixture::hit_shapes[0]*4,static_template|1U); };
        const auto out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::hit_categories_unavailable && out.native_casts==2 && none(out),
            "a category dropped at the closing fence passed the requirement");
    }
    for(const bool requirement:{false,true}) {
        // Each refused nearest hit names its reason, with its one actual cast.
        ContactFixture f;masks(f,static_template,static_template);pin(f,true);auto request=f.request(2,false);
        request.require_named_actor_categories_absent=requirement;
        f.hit_owned=true;auto out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::owned_body_hit && out.native_casts==1 && f.calls==1 && none(out),
            "an owned nearest hit did not name its reason");
        f.hit_owned=false;f.hit_unknown=true;out=probe_batch(owner,f.handle,request,64);
        check(!out.available && out.failure==Failure::hit_identity_unqualified && out.native_casts==1 && f.calls==2 && none(out),
            "an unqualified nearest hit did not name its reason");
    }
    {
        // Owner slots: read at the hit shape's own element, unassigned is not absent,
        // only an opt-in sees them, and a change before the closing fence drops one.
        ContactFixture f;auto request=f.request(2,false);request.include_hit_owner=true;
        const auto slots=load<std::uintptr_t>(f.state+r::shape_owners);
        put(slots+ContactFixture::hit_shapes[0]*4,r::unassigned_shape_owner);
        put(slots+ContactFixture::hit_shapes[1]*4,std::uint32_t{0x2a});
        // A decoy at the mapped foreign body's own index.
        put(slots+ContactFixture::foreign_index*4,std::uint32_t{0x99});
        auto out=probe_batch(owner,f.handle,request,64);
        check(out.available && out.native_casts==2 && out.rays[0].owner_available && !out.rays[0].owner_assigned &&
            out.rays[1].owner_available && out.rays[1].owner_assigned && out.rays[1].owner==0x2a &&
            !out.rays[0].in_categories_available && !out.local_actor_excluded,"the Service lost, mixed or body-indexed its hit owner slots");
        request.include_hit_owner=false;out=probe_batch(owner,f.handle,request,64);
        check(out.available && !out.rays[0].owner_available && !out.rays[1].owner_available,"a default batch carried owner slots");
        request.include_hit_owner=true;const auto second=f.calls+2;
        f.during_query=[&,second,slots](unsigned calls) { if(calls==second) put(slots+ContactFixture::hit_shapes[0]*4,std::uint32_t{7}); };
        out=probe_batch(owner,f.handle,request,64);
        check(out.available && !out.rays[0].owner_available && out.rays[1].owner_available && out.rays[1].owner==0x2a,
            "an owner slot change refused the batch or kept a stale slot");
    }
}

void submit_late_refusals_preserve_command_state() {
    Fixture f;
    Sample issued_sample;
    check(read(owner, f.handle, issued_sample).empty(), "submit fixture could not publish its first sample");
    // Fixture seeds an applied receipt. This case starts with an empty inbox.
    f.slot().mailbox = {};
    const auto saved_command_sequence = service.command_sequence;
    service.command_sequence = 42;
    const auto native_mutations_before = test_facts::mutations.load();
    Command request_command{};
    request_command.epoch = issued_sample.epoch;
    request_command.force = {1, 0, 0};
    const auto check_refusal = [&](std::uint64_t requested_owner, const char* expected) {
        std::array<unsigned char, sizeof(Mailbox)> mailbox_before{};
        std::memcpy(mailbox_before.data(), &f.slot().mailbox, mailbox_before.size());
        const auto latest_before = f.slot().latest;
        const auto sequence_before = service.command_sequence;
        std::uint64_t assigned_sequence = 999;
        SetLastError(0x1234);
        const auto refusal = submit(requested_owner, f.handle, request_command, assigned_sequence);
        const auto last_error_after = GetLastError();
        check(refusal == expected, "submit returned the wrong refusal token");
        check(assigned_sequence == 0, "refused submit published a sequence");
        check(service.command_sequence == sequence_before, "refused submit spent a global command sequence");
        // The byte comparison also protects an applied receipt awaiting acknowledgement.
        check(std::memcmp(mailbox_before.data(), &f.slot().mailbox, mailbox_before.size()) == 0,
            "refused submit changed mailbox history");
        check(body_query::same_sample(f.slot().latest, latest_before), "refused submit changed the latest issued sample");
        check(test_facts::mutations.load() == native_mutations_before, "refused submit reached a native setter");
        check(last_error_after == 0x1234, "refused submit changed LastError");
    };
    const auto feed_sequence_before = clock_feed.sequence.load();
    clock_feed.sequence = feed_sequence_before + 1;
    check_refusal(owner + 1, "body owner or generation changed");
    check_refusal(owner, "body_clock_unavailable");
    clock_feed.sequence = feed_sequence_before;
    f.step(); // Advance the actual feed without publishing another body read.
    check_refusal(owner, "body_epoch_expired");
    Sample newer_sample;
    check(read(owner, f.handle, newer_sample).empty() && newer_sample.epoch.serial > issued_sample.epoch.serial,
        "submit fixture could not publish its later sample");
    // A newer read invalidates the earlier command even when the clock matches latest.
    check_refusal(owner, "body_epoch_expired");
    request_command.epoch = newer_sample.epoch;
    std::uint64_t accepted_sequence = 0;
    SetLastError(0x5678);
    const auto accepted = submit(owner, f.handle, request_command, accepted_sequence);
    const auto accepted_last_error = GetLastError();
    check(accepted.empty() && accepted_sequence == 43 && service.command_sequence == 43,
        "current measured command was refused");
    check(f.slot().mailbox.pending && f.slot().mailbox.count == 1 && f.slot().mailbox.command.epoch == newer_sample.epoch,
        "accepted command did not reserve exactly one measured packet");
    check(test_facts::mutations.load() == native_mutations_before, "submit applied native effects instead of only queuing");
    check(accepted_last_error == 0x5678, "accepted submit changed LastError");
    // Construct only the producer outcome; actual Service receipt() must sample
    // the successor. No native setter or producer wrapper runs in this fixture.
    f.step();
    Epoch produced_epoch{};
    Command consumed{};
    check(command_clock(f.slot(), produced_epoch) &&
        f.slot().mailbox.consume(produced_epoch, test_clock::now.load(), consumed) &&
        f.slot().mailbox.finish(true, true, true), "could not construct the applied command receipt");
    check(f.slot().mailbox.needs_successor(), "constructed receipt already had a successor");
    f.step();
    Receipt completed{};
    check(receipt(owner, f.handle, accepted_sequence, completed).empty() &&
        completed.outcome == Outcome::applied && completed.successor_available &&
        completed.successor.epoch.serial > produced_epoch.serial && completed.successor.epoch.time > produced_epoch.time &&
        body_query::same_sample(f.slot().latest, completed.successor),
        "receipt did not publish its independently measured successor");
    Epoch current_after_receipt{};
    check(command_clock(f.slot(), current_after_receipt) && current_after_receipt == f.slot().latest.epoch,
        "receipt regression requires the clock to match the newly published sample");
    check_refusal(owner, "body_epoch_expired");
    check(acknowledge(owner, f.handle, accepted_sequence).empty(), "completed receipt could not be acknowledged");
    check_refusal(owner, "body_epoch_expired");
    request_command.epoch = completed.successor.epoch;
    request_command.force = {40001, 0, 0};
    check_refusal(owner, "body command invalid, repeated, stopped, pending or receipt ring full");
    request_command.force = {1, 0, 0};
    check(submit(owner, f.handle, request_command, accepted_sequence).empty() && accepted_sequence == 44 &&
        service.command_sequence == 44 && f.slot().mailbox.pending && f.slot().mailbox.count == 1 &&
        f.slot().mailbox.command.epoch == completed.successor.epoch,
        "receipt successor command did not reserve exactly one packet after acknowledgement");
    check(test_facts::mutations.load() == native_mutations_before, "receipt successor path reached a native setter");
    service.command_sequence = saved_command_sequence;
}

void deferred_initialization_stays_outside_create_and_service_lock() {
    Fixture f;
    const auto definition=f.slot().definition;
    const auto read_api=service.api;
    service.slots={};service.hooked=false;service.hook_attempted=false;
    service.initialization_requested=false;service.listener=false;service.original=nullptr;
    service.api={};test_facts::forbidden_links=0;
    const auto no_allocation=[] {
        return std::none_of(service.slots.begin(),service.slots.end(),[](const Slot& slot){return slot.attempted;});
    };
    Handle out{77,3};
    check(create(0,definition,out)=="invalid body definition" && !out.generation && !service.initialization_requested,
        "ownerless create queued producer preparation");
    auto invalid=definition;invalid.mass=0;
    check(create(owner,invalid,out)=="invalid body definition" && !service.initialization_requested,
        "invalid definition queued producer preparation");
    std::string wrong_thread;
    std::thread other([&]{Handle ignored;wrong_thread=create(owner,definition,ignored);});other.join();
    check(!wrong_thread.empty() && !service.initialization_requested,"wrong thread queued producer preparation");
    test_facts::multiplayer_active=true;
    check(!create(owner,definition,out).empty() && !service.initialization_requested,"multiplayer queued producer preparation");
    test_facts::multiplayer_active=false;
    SetLastError(0x1234);
    check(create(owner,definition,out)=="body_preallocation_unavailable" && !out.generation &&
        service.initialization_requested && !service.hook_attempted && test_facts::forbidden_links==0 && no_allocation(),
        "cold create initialized hooks or reserved a body rather than only requesting setup");
    check(GetLastError()==0x1234,"cold preparation request changed LastError");
    check(create(owner+1,definition,out)=="body_preallocation_unavailable" &&
        service.initialization_requested && test_facts::forbidden_links==0 && no_allocation(),
        "a second generic preparation request performed native work");
    tick(f.base,f.client,false);
    check(!service.initialization_requested && !service.hook_attempted && test_facts::forbidden_links==0 && no_allocation(),
        "ineligible tick retained or executed a stale preparation request");
    tick(f.base,f.client,true);
    check(!service.hook_attempted && test_facts::forbidden_links==0,"eligibility restoration automatically prepared without a new request");
    check(create(owner,definition,out)=="body_preallocation_unavailable","fresh explicit preparation request refused");
    test_facts::inspect_initializer_lock=true;test_facts::initializer_unlocked=false;test_facts::initializer_elapsed=251;
    const auto requested_at=test_clock::now.load();
    SetLastError(0x5678);tick(f.base,f.client,true);
    test_facts::inspect_initializer_lock=false;test_facts::initializer_elapsed=0;
    check(GetLastError()==0x5678,"deferred initializer tick changed LastError");
    check(service.hook_attempted && !service.hooked && !service.initialization_requested &&
        test_facts::forbidden_links==1 && test_facts::initializer_unlocked && no_allocation(),
        "actual fail-closed initializer did not run exactly once outside the service SRW lock");
    check(service.tick_at==requested_at && test_clock::now==requested_at+251 && !eligible(),
        "slow producer setup refreshed old readiness instead of failing closed");
    tick(f.base,f.client,true);
    check(create(owner,definition,out)=="native body ABI or producer hook unavailable; another producer may own it" &&
        !service.initialization_requested && test_facts::forbidden_links==1 && no_allocation(),
        "failed producer initialization was disguised as retryable warmup");
    tick(f.base,f.client,true);
    check(test_facts::forbidden_links==1 && no_allocation(),"failed initialization automatically repeated");
    // Constructed ready state tests the later create gate, not native hook success.
    service.api=read_api;service.hooked=true;clock_feed.serial=0;clock_feed.sequence=0;
    tick(f.base,f.client,true);
    check(create(owner,definition,out)=="body_preallocation_unavailable" && no_allocation() &&
        !service.initialization_requested && test_facts::mutations==0,
        "constructed producer readiness bypassed the original fresh clock or allocated automatically");
}


// These cases execute the actual hook/router with a constructed pending probe.
// They do not prove begin_sync_probe admission, native synchronizer invocation
// in retail, actor lifetime or record-pose qualification.
std::atomic<unsigned> routing_original_calls{};
std::uintptr_t routing_original(NativeHandle*, std::uintptr_t) {
    ++routing_original_calls;
    SetLastError(0x5EED);
    return 0x7A5E;
}
void seed_routing_probe(Fixture& fixture, std::uint32_t sequence, bool recorded = false) {
    test_facts::forbidden_links = 0; routing_original_calls = 0;
    SyncProbe value; value.owner = owner; value.handle = fixture.handle;
    value.sequence = sequence; value.world_generation = service.world_generation;
    value.packets = fixture.arena.take(0x1000);
    value.opened_ms = test_clock::now.load(); value.deadline = value.opened_ms + sync_probe_lifetime_ms;
    value.result.armed_epoch = fixture.slot().latest.epoch;
    if (recorded) {
        value.result.observed_mask = sync_all_records;
        for (auto& record : value.result.records) record.present = true;
    }
    service.probe = value;
    service.probe_losses = std::uint64_t{sequence} << 32;
    sync_reset_routes(sequence);
    service.original = routing_original;
    service.probe_live = sequence;
}
bool same_routing(const body_sync_probe::Routing& a, const body_sync_probe::Routing& b) {
    return a.entries == b.entries && a.matches == b.matches && a.other == b.other &&
        a.already_recorded == b.already_recorded && a.expired_entries == b.expired_entries;
}
void route_call(Fixture& fixture, std::uintptr_t wrapper) {
    SetLastError(0x1234);
    check(synchronize_hook(&fixture.slot().body, wrapper) == 0x7A5E, "routing changed the raw original result");
    check(GetLastError() == 0x5EED, "routing changed original LastError");
}
void sync_routes_distinguish_wrapper_and_record_paths() {
    Fixture fixture; seed_routing_probe(fixture, 31, true);
    const auto packets = service.probe.packets;
    // The 32 producer wrappers are a different selection from these four.
    route_call(fixture, fixture.slot().anchor.wrappers[0]);
    for (std::size_t i = 0; i < 4; ++i) route_call(fixture, packets + n::wrapper + i*n::packet_stride);
    route_call(fixture, packets + n::wrapper);
    route_call(fixture, 1); // Never dereference a foreign wrapper to classify it.
    sync_capture_routes(service.probe);
    auto counts = service.probe.result.routing;
    check(counts.entries == 7 && counts.other == 2 && counts.already_recorded == 5,
        "entry/foreign/already-recorded routing branches were conflated");
    check(counts.matches == std::array<std::uint32_t,4>{2,1,1,1} && counts.expired_entries == 0,
        "four exact wrappers were not counted before record suppression");
    check(routing_original_calls == 7 && service.probe.result.rejected == 0 && service.probe.result.dropped == 0,
        "passive routing changed original count or qualification/loss facts");
    // One matched unrecorded wrapper reaches the existing unavailable actor
    // stand-in; its route is still visible without fabricating a record.
    service.probe.result.records[2].present = false; service.probe.result.observed_mask &= ~4u;
    route_call(fixture, packets + n::wrapper + 2*n::packet_stride);
    sync_capture_routes(service.probe); counts = service.probe.result.routing;
    check(counts.entries == 8 && counts.matches[2] == 2 && counts.already_recorded == 5 &&
        service.probe.result.rejected == 1 && !service.probe.result.records[2].present,
        "matched qualification refusal vanished or became an observed record");
    check(routing_original_calls == 8, "qualification refusal skipped or repeated original");
    service.probe_live = 0;
}
void sync_routes_account_lock_loss_and_freeze_expiry() {
    Fixture fixture; seed_routing_probe(fixture, 41);
    bool raw_passed{};
    AcquireSRWLockExclusive(&service.lock);
    std::thread callback([&] {
        SetLastError(0x1234);
        const auto raw = synchronize_hook(&fixture.slot().body, 1);
        raw_passed = raw == 0x7A5E && GetLastError() == 0x5EED;
    });
    callback.join(); ReleaseSRWLockExclusive(&service.lock);
    check(raw_passed && routing_original_calls == 1, "Try-lock refusal waited or altered original passthrough");
    sync_capture_routes(service.probe);
    check(service.probe.result.routing.entries == 1 && service.probe.result.routing.other == 0 &&
        static_cast<std::uint32_t>(service.probe_losses.load()) == 1,
        "contended entry was hidden or incorrectly classified foreign");
    test_clock::now = service.probe.deadline;
    route_call(fixture, 1);
    const auto frozen = service.probe.result;
    check(frozen.status == SyncStatus::expired && !service.probe_live && frozen.routing.entries == 2 &&
        frozen.routing.expired_entries == 1 && frozen.routing.other == 0 && frozen.dropped == 1,
        "expiry-at-entry was classified foreign or existing dropped loss was changed");
    // Model a callback that captured the old live generation before closure.
    sync_route(41, SyncRoute::entry); sync_route(41, SyncRoute::other); sync_loss(41); sync_reject(41);
    route_call(fixture, 1);
    body_sync_probe::Result read;
    check(!poll_sync_probe(owner + 1, fixture.handle, 41, read).empty(), "wrong owner read a route ledger");
    auto wrong_body = fixture.handle; ++wrong_body.generation;
    check(!poll_sync_probe(owner, wrong_body, 41, read).empty(), "wrong body generation read routes");
    check(!poll_sync_probe(owner, fixture.handle, 40, read).empty(), "old sequence read routes");
    check(poll_sync_probe(owner, fixture.handle, 41, read).empty() && same_routing(read.routing, frozen.routing) &&
        read.dropped == frozen.dropped && read.rejected == frozen.rejected,
        "terminal route/result facts changed after delayed entry or repeated read");
    read.routing.entries = 99;
    check(poll_sync_probe(owner, fixture.handle, 41, read).empty() && same_routing(read.routing, frozen.routing),
        "mutating a returned copy changed terminal routing ownership");
    seed_routing_probe(fixture, 42);
    sync_route(41, SyncRoute::entry); sync_route(41, SyncRoute::other); sync_expire(41);
    // A callback with a stale live capture must not label the new probe foreign.
    service.probe_live = 41; route_call(fixture, 1); service.probe_live = 42;
    sync_capture_routes(service.probe);
    check(service.probe.result.routing.entries == 0 && service.probe.result.routing.other == 0 &&
        service.probe.result.status == SyncStatus::pending, "old callback contaminated or closed the replacement probe");
    route_call(fixture, 1); sync_capture_routes(service.probe);
    check(service.probe.result.routing.entries == 1 && service.probe.result.routing.other == 1,
        "replacement probe failed to count its own route");
    service.probe_live = 0;
}
void sync_routes_freeze_other_closures_and_saturate() {
    for (unsigned closure = 0; closure < 3; ++closure) {
        Fixture fixture; seed_routing_probe(fixture, 51 + closure);
        route_call(fixture, 1);
        if (closure == 0) retire(fixture.slot(), false);
        if (closure == 1) { service.eligible = false; release_all(owner); }
        if (closure == 2) {
            test_clock::now = service.probe.deadline;
            tick(fixture.base, fixture.client, false);
        }
        const auto frozen = service.probe.result;
        check(frozen.status == (closure == 2 ? SyncStatus::expired : SyncStatus::invalidated) &&
            frozen.routing.entries == 1 && frozen.routing.other == 1 && !service.probe_live,
            "release/retirement/tick terminal path did not freeze routes");
        sync_route(51 + closure, SyncRoute::entry);
        body_sync_probe::Result read;
        check(poll_sync_probe(owner, fixture.handle, 51 + closure, read).empty() && same_routing(read.routing, frozen.routing),
            "closure reopened routing or depended on an actor observation");
    }
    Fixture fixture; seed_routing_probe(fixture, UINT32_MAX);
    auto& counter = service.probe_routes[static_cast<std::size_t>(SyncRoute::entry)];
    counter = (std::uint64_t{UINT32_MAX} << 32) | (UINT32_MAX - 1);
    sync_route(UINT32_MAX, SyncRoute::entry); sync_route(UINT32_MAX, SyncRoute::entry);
    sync_route(UINT32_MAX - 1, SyncRoute::entry); sync_capture_routes(service.probe);
    check(service.probe.result.routing.entries == UINT32_MAX && (counter.load() >> 32) == UINT32_MAX,
        "bounded route count wrapped, changed generation or accepted an old generation");
    service.probe_live = 0;
}

// Constructed native leaves exercise the actual actor-scoped collector. These
// cases do not execute retail motion or prove hook installation/retirement.
class MotionFixture : public Fixture {
public:
    std::uintptr_t packet_owner{}, packets{}, input{};
    MotionFixture() {
        test_facts::forbidden_links = 0;
        service.slots = {}; service.hooked = false;
        auto& actor = test_facts::motion_actor;
        actor.base = base; actor.client = client; actor.entity = entity; actor.core = core;
        actor.context = skater_context; actor.rig = rig; actor.game_context = context;
        actor.world = world; actor.world_state = state; actor.world_generation = 23;
        actor.lifetime_epoch = 31; actor.actor_epoch = 0;
        test_facts::motion_actor_enabled = true; test_facts::motion_available = true;
        motion_probe.ready = true; motion_probe.base = base;
        for (const auto* prefix : {&ma::rebuild_root, &ma::refresh_caches, &ma::refresh_packets,
            &n::packet_a_writer, &n::packet_b_writer, &n::packet_tail_writer}) {
            const auto page = (base + prefix->rva) & ~std::uintptr_t{4095};
            check(VirtualAlloc(reinterpret_cast<void*>(page), 4096, MEM_COMMIT, PAGE_READWRITE) != nullptr,
                "motion prefix sparse fixture page failed");
            put(base + prefix->rva, prefix->bytes);
        }
        packet_owner = arena.take(0x300); packets = arena.take(0x600); input = arena.take(64);
        put(rig + n::packet_owner, packet_owner); put(packet_owner + n::packet_array, packets);
        const mp::Matrix identity{1,0,0,0, 0,1,0,0, 0,0,1,0, 2,3,4,1};
        put(rig + ma::root, identity); put(rig + ma::inverse, identity);
        for (const auto offset : ma::caches) put(rig + offset, identity);
        for (std::size_t i = 0; i < 4; ++i) {
            put(packets + i*n::packet_stride + n::transform, identity);
            put(packets + i*n::packet_stride + n::pending, std::uint32_t{1});
        }
        put(input, std::array<float,4>{7,8,9,1});
    }
    ~MotionFixture() { test_facts::motion_actor_enabled = false; }
    std::uint64_t arm() {
        std::uint64_t sequence{};
        SetLastError(0x1234);
        check(begin_motion_refresh_probe(owner, sequence).empty() && sequence, "actual motion begin refused constructed actor/clock");
        check(GetLastError() == 0x1234, "motion begin changed LastError");
        return sequence;
    }
    NoBailMoverEvent event(NoBailMoverEdge edge = NoBailMoverEdge::before_original) const {
        return {edge, rig, skater_context, input, 0xA5};
    }
    std::uint64_t before() {
        SetLastError(0xCA11);
        const auto cookie = motion_observer(event(), 0);
        check(GetLastError() == 0xCA11, "motion pre observer changed LastError");
        return cookie;
    }
    void after(std::uint64_t cookie) {
        SetLastError(0xCA12);
        (void)motion_observer(event(NoBailMoverEdge::original_returned), cookie);
        check(GetLastError() == 0xCA12, "motion post observer changed LastError");
    }
};
void motion_zero_body_begin_and_completed_record() {
    MotionFixture f;
    const auto sequence = f.arm();
    check(!f.before() && motion_route_count(sequence, MotionRoute::rejected) == 1,
        "same armed native epoch was admitted as a later mover");
    f.step(); const auto cookie = f.before(); check(cookie != 0, "later exact mover did not create a cookie");
    auto changed = load<mp::Matrix>(f.rig + ma::root); changed[12] = 12;
    put(f.rig + ma::root, changed); put(f.packets + n::transform, changed);
    f.after(cookie);
    mp::Result out;
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == mp::Status::pending &&
        out.record.present && !out.client_revalidated && out.confirmed_epoch == mp::Epoch{},
        "normal-return record claimed later-client confirmation at the same epoch");
    check(out.record.input == std::array<float,4>{7,8,9,1} && out.record.flag == 0xA5 &&
        out.record.unchanged_forwarding && out.record.before.root[12] == 2 && out.record.after.root[12] == 12 &&
        out.record.before_epoch == out.record.after_epoch && motion_newer(out.record.before_epoch, out.armed_epoch),
        "actual motion record lost copied input/flag/endpoints/epoch qualification");
    f.step();
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == mp::Status::observed &&
        out.record.present && out.client_revalidated && motion_newer(out.confirmed_epoch, out.record.after_epoch),
        "later actual client observation did not confirm the copied normal-return record");
    const auto frozen = out;
    test_facts::motion_actor.world += 64; test_clock::now += 2000;
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == frozen.status &&
        out.elapsed_ms == frozen.elapsed_ms && out.confirmed_epoch == frozen.confirmed_epoch,
        "terminal diagnostic was silently refreshed from changed native state");
    check(std::none_of(service.slots.begin(), service.slots.end(), [](const Slot& s) { return s.attempted; }),
        "actor-scoped observation required or reserved a body");
}
void motion_refusals_close_generation_and_read_bounds() {
    MotionFixture f; std::uint64_t sequence{};
    check(!begin_motion_refresh_probe(0, sequence).empty() && !sequence, "zero owner armed a motion probe");
    test_facts::motion_available = false;
    check(!begin_motion_refresh_probe(owner, sequence).empty(), "unseen/unavailable mover relay was admitted");
    test_facts::motion_available = true;
    put(f.base + ma::rebuild_root.rva, std::uint8_t{0});
    check(!begin_motion_refresh_probe(owner, sequence).empty(), "changed helper source prefix was admitted");
    put(f.base + ma::rebuild_root.rva, ma::rebuild_root.bytes);
    sequence = f.arm(); std::uint64_t blocked{};
    check(!begin_motion_refresh_probe(owner+1, blocked).empty() && !blocked, "second owner replaced a pending probe");
    f.step(); const auto cookie = f.before(); check(cookie != 0, "motion pre admission failed");
    check(!f.before(), "nested original invocation overwrote the selected mover cookie");
    cancel_motion_refresh_probes(owner+1);
    mp::Result out;
    check(!poll_motion_refresh_probe(owner+1, sequence, out).empty(), "foreign owner read a motion probe");
    cancel_motion_refresh_probes(owner); f.after(cookie);
    check(!poll_motion_refresh_probe(owner, sequence, out).empty() && !motion_probe.live.load(),
        "owner close without bodies left a pollable record or live callback generation");
    const auto next = f.arm(); check(next != sequence, "cancel reused a generation");
    f.after(cookie);
    check(poll_motion_refresh_probe(owner, next, out).empty() && !out.record.present,
        "late original return published into replacement generation");
    f.step();
    auto invalid = f.event(); invalid.input = 1;
    check(!motion_observer(invalid, 0) && motion_route_count(next, MotionRoute::rejected) == 1,
        "unreadable input was dereferenced/admitted rather than refused");
}
void motion_clock_packet_identity_expiry_and_cap() {
    MotionFixture f; auto sequence = f.arm(); f.step();
    auto cookie = f.before(); check(cookie != 0, "motion before failed before epoch change");
    f.step(); f.after(cookie);
    check(!motion_probe.result.record.present && motion_route_count(sequence, MotionRoute::rejected) == 1,
        "native epoch change inside original was accepted");
    cookie = f.before(); check(cookie != 0, "retry after refused native edge failed");
    put(f.packet_owner + n::packet_array, f.packets + 16); f.after(cookie);
    check(!motion_probe.result.record.present, "changed O/P packet chain was accepted");
    put(f.packet_owner + n::packet_array, f.packets);
    cookie = f.before(); check(cookie != 0, "fresh endpoint pre failed"); f.after(cookie);
    check(motion_probe.result.record.present, "valid copied endpoint was not retained");
    test_clock::now = motion_probe.deadline + 7;
    mp::Result out;
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == mp::Status::expired &&
        out.record.present && !out.client_revalidated && out.confirmed_epoch == mp::Epoch{} && out.elapsed_ms == 1007,
        "expiry widened/clamped the deadline or erased a separate native-return record");
    test_clock::now = 10000; service.tick_at = test_clock::now; f.step();
    sequence = f.arm(); auto other = f.event(); other.rig += 64;
    for (unsigned i = 0; i < mp::callback_limit + 20; ++i) (void)motion_observer(other, 0);
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == mp::Status::expired &&
        out.routing.entries == mp::callback_limit && out.routing.other == mp::callback_limit &&
        out.routing.limit_reached && !out.record.present, "fixed callback cap failed to close without widening reads");
    sequence = f.arm();
    test_facts::motion_actor.world += 64;
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == mp::Status::invalidated &&
        !out.client_revalidated && !out.record.present, "changed actor/world retained a live request");
    test_facts::motion_actor.world -= 64; sequence = f.arm(); f.step();
    cookie = f.before(); check(cookie != 0, "packet-client-check pre failed"); f.after(cookie); f.step();
    put(f.packet_owner + n::packet_array, f.packets + 16);
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == mp::Status::invalidated &&
        out.record.present && !out.client_revalidated,
        "client confirmation ignored a changed copied-packet allocation chain");
}
void motion_try_lock_cold_setup_and_stale_routes() {
    MotionFixture f; auto sequence = f.arm();
    AcquireSRWLockExclusive(&motion_probe.lock);
    std::thread callback([&] { (void)motion_observer(f.event(), 0); }); callback.join();
    ReleaseSRWLockExclusive(&motion_probe.lock);
    check(motion_route_count(sequence, MotionRoute::entries) == 1 && motion_route_count(sequence, MotionRoute::dropped) == 1,
        "busy collector lock blocked or hid the bounded callback loss");
    const auto old = sequence;
    cancel_motion_refresh_probes(owner); sequence = f.arm();
    (void)motion_route(old, MotionRoute::rejected);
    check(motion_route_count(sequence, MotionRoute::rejected) == 0, "old route increment crossed generation");
    cancel_motion_refresh_probes(owner); motion_probe.ready = false;
    std::uint64_t pending{};
    check(!begin_motion_refresh_probe(owner, pending).empty() && !pending && motion_probe.requested &&
        !service.initialization_requested && !motion_probe.sequence,
        "cold actor probe allocated/armed a body producer instead of requesting read-only preparation");
    tick(f.base, f.client, false);
    check(!motion_probe.requested && !motion_probe.sequence, "ineligible tick retained a cold motion preparation request");
    tick(f.base, f.client, true);
    check(!motion_probe.ready && !motion_probe.sequence, "eligibility restoration automatically armed a motion probe");
}
void motion_record_arrives_during_client_poll() {
    MotionFixture f; const auto sequence = f.arm(); f.step();
    test_facts::motion_observe_once = [&] {
        const auto cookie = f.before(); check(cookie != 0, "interleaved real collector pre failed");
        f.after(cookie); f.step();
        put(f.packet_owner + n::packet_array, f.packets + 16);
    };
    mp::Result out;
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == mp::Status::pending &&
        out.record.present && !out.client_revalidated,
        "poll confirmed a newly arrived record without its saved O/P validation snapshot");
    check(poll_motion_refresh_probe(owner, sequence, out).empty() && out.status == mp::Status::invalidated &&
        out.record.present && !out.client_revalidated,
        "next client poll failed to reject the interleaved copied-packet chain change");
}

#include "body_prepare_source_fixture.inc"
#include "owned_body_cleanup_source_fixture.inc"
#include "body_reactivation_probe_source_fixture.inc"

template<class F> void run(const char* name, F function, unsigned expected_links=0) {
    function();
    check(test_facts::mutations.load() == 0, "source path invoked a native mutator/allocator");
    check(test_facts::forbidden_links.load() == expected_links, "source path entered an unexpected hook/query/constructor dependency");
    ++cases;
    std::cout << "PASS " << name << '\n';
}
} // namespace dingosdk::owned_bodies::source_test

int main() {
    using namespace dingosdk::owned_bodies::source_test;
    try {
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
        run("reactivation_begin_actual_no_hold_retirement",reactivation_begin_retires_without_a_follow_hold);
        run("reactivation_one_cycle_explicit_retained_repark",reactivation_one_cycle_explicitly_reparks_retained_identity);
        run("reactivation_all_receipt_debt_preserved",reactivation_receipt_debt_and_pending_states_are_preserved);
        run("reactivation_never_held_witness",reactivation_actual_dependency_permanently_revokes_never_held_witness);
        run("reactivation_admission_identity_configuration_clock",reactivation_admission_rejects_identity_allocation_configuration_and_clock_faults);
        run("reactivation_owner_thread_lock_sequence",reactivation_admission_owner_thread_lock_and_sequence_fences);
        run("reactivation_each_setter_failure_cleanup",reactivation_setter_faults_preserve_first_failure_and_cleanup_duty);
        run("reactivation_void_setter_exact_readback",reactivation_silent_setter_refusal_requires_exact_readback);
        run("reactivation_setter_identity_qualification_interleavings",reactivation_each_activation_setter_rechecks_identity_and_qualification);
        run("reactivation_later_epoch_nonadvancing_poll",reactivation_later_epoch_and_copied_poll_do_not_advance_early);
        run("reactivation_readiness_exit_cleanup_deadlines",reactivation_readiness_early_returns_still_expire_cleanup_metadata);
        run("reactivation_owner_close_keeps_cleanup",reactivation_owner_close_keeps_cleanup_and_old_result_private);
        run("reactivation_deadline_qualification_revocation",reactivation_deadline_and_qualification_revocation_stop_activation);
        run("reactivation_closing_readback_deadline_equality",reactivation_final_readback_deadline_is_a_closing_fence);
        run("reactivation_dynamic_observation_exact_native_facts",reactivation_dynamic_observation_rejects_changed_native_facts);
        run("reactivation_closing_admission_interleavings",reactivation_closing_admission_revalidates_unlocked_capture);
        run("reactivation_second_shape_failure_index",reactivation_second_shape_mask_failure_reports_exact_index);
        run("reactivation_write_guard_closing_age_boundary",reactivation_write_guard_samples_age_after_closing_clock);
        run("reactivation_slow_qualification_same_tick_cleanup",reactivation_slow_qualification_closes_cleanup_in_same_tick);
        run("reactivation_slow_park_setter_stops_later_writes",reactivation_slow_park_setter_stops_following_writes_and_closes_cleanup);
#else
        run("reactivation_default_off_provider_absent",reactivation_default_off_has_no_executable_provider);
#endif
        run("park_angular_xyz_zero_complete_observation",park_angular_xyz_zero_accepts_only_complete_observation);
        run("park_angular_xyz_nonzero_invalid_fourth",park_angular_xyz_nonzero_and_invalid_fourth_refuse);
        run("park_angular_xyz_fourth_stability_headers",park_angular_xyz_zero_keeps_fourth_stability_and_headers);
        run("park_angular_xyz_later_pending_commands",park_angular_xyz_zero_keeps_later_pending_commands);
        run("park_angular_xyz_closing_identity_clock_age",park_angular_xyz_zero_keeps_closing_identity_clock_and_age);
        run("command_cleanup_exact_history_no_native_reread",command_cleanup_uses_exact_immutable_history_without_native_reread);
        run("command_cleanup_identity_busy_hold_quarantine",command_cleanup_rejects_changed_identity_busy_hold_and_quarantine);
        run("completed_ack_exact_history_and_body_debt",completed_ack_history_is_exact_idempotent_and_preserves_body_debt);
        run("completed_ack_later_foreign_unpaired",completed_ack_history_rejects_later_foreign_and_unpaired_proofs);
        run("completed_ack_busy_unclosed_nonmutating",completed_ack_history_busy_and_unclosed_are_nonmutating);
        run("completed_ack_ineligible_terminal_body_ack",completed_ack_ineligible_history_keeps_terminal_body_ack);
        run("completed_ack_owner_close_retained",completed_ack_owner_close_covers_already_retained_slots);
        run("completed_ack_sticky_fault_after_park",completed_ack_fault_survives_later_successful_park);
        run("completed_ack_new_hold_clears_provenance",completed_ack_new_hold_clears_only_old_provenance);
        run("completed_ack_offthread_close_atomic_only",completed_ack_offthread_owner_close_is_atomic_metadata_only);
        run("park_diagnostic_valid_legacy_parity_signed_zero",park_diagnostic_valid_legacy_parity_and_signed_zero);
        run("park_diagnostic_owner_busy_occupied_output",park_diagnostic_owner_busy_and_occupied_output);
        run("park_diagnostic_identity_clock_dynamic",park_diagnostic_identity_clock_and_dynamic_guards);
        run("park_diagnostic_finite_lane_masks_first_failure",park_diagnostic_finite_lane_masks_and_first_failure);
        run("park_diagnostic_angular_fourth_exact_existing_read",park_diagnostic_angular_fourth_exact_existing_read);
        run("park_diagnostic_angular_fourth_unavailable_resets",park_diagnostic_angular_fourth_unavailable_resets);
        run("park_diagnostic_failed_reads_unknown",park_diagnostic_failed_reads_leave_lanes_unknown);
        run("park_diagnostic_opening_storage_masks",park_diagnostic_opening_storage_and_mask_edges);
        run("park_diagnostic_both_closing_passes",park_diagnostic_both_closing_passes_keep_fences);
        run("park_diagnostic_closing_identity_clock_age",park_diagnostic_closing_identity_clock_and_final_age);
        run("capture_nonmutation_and_immutable_measurement", capture_does_not_publish);
        run("owner_generation_world_pool_and_native_lifetime", owner_generation_world_and_pool_failures);
        run("original_age_and_clock_continuity", original_age_and_clock_failures);
        run("unreadable_and_failed_capture_nonmutation", unreadable_and_failed_capture_nonmutation);
        run("owner_clock_and_closing_clock_refusal", owner_clock_and_closing_clock_refusal);
        run("submit_late_refusals_preserve_command_state", submit_late_refusals_preserve_command_state);
        run("try_locks_thread_affinity_and_last_error", try_locks_and_thread_affinity);
        run("actual_sdk_release_serialization", sdk_release_cannot_cross_borrow);
        run("renewal_proof_latest_fresh_shared_and_read_only", renewal_proof_latest_fresh_shared_and_read_only);
        run("service_contact_opt_in_and_read_only",service_contact_opt_in_and_read_only);
        run("service_whole_batch_contact_fences",service_whole_batch_contact_fences);
        run("service_actor_and_nearest_hit_refusals",service_actor_and_nearest_hit_refusals);
        run("service_forwards_query_preset_without_relaxing_refusals",service_forwards_query_preset_without_relaxing_refusals);
        run("service_shape_categories_opt_in_shape_bound_and_fenced",service_shape_categories_are_opt_in_shape_bound_and_fenced);
        run("service_named_actor_categories_reasons_and_hit_owners",service_named_actor_categories_reasons_and_hit_owners);
        run("deferred_producer_initialization_without_allocation",deferred_initialization_stays_outside_create_and_service_lock,1);
        run("prepare_cold_queues_only_deferred_setup",prepare_cold_queues_only_deferred_setup);
        run("prepare_deferred_failure_is_terminal_without_retry",prepare_deferred_failure_is_terminal_without_retry,1);
        run("prepare_warm_readiness_needs_fresh_capture_and_clock",prepare_warm_readiness_needs_fresh_capture_and_clock);
        run("prepare_does_not_reconcile_world_or_touch_existing_slots",prepare_does_not_reconcile_world_or_touch_existing_slots);
        run("sync_routes_wrapper_selection_and_suppression",sync_routes_distinguish_wrapper_and_record_paths,1);
        run("sync_routes_try_lock_expiry_and_generation_freeze",sync_routes_account_lock_loss_and_freeze_expiry);
        run("sync_routes_terminal_paths_and_saturation",sync_routes_freeze_other_closures_and_saturate);
        run("motion_zero_body_begin_and_completed_record",motion_zero_body_begin_and_completed_record);
        run("motion_refusals_close_generation_and_read_bounds",motion_refusals_close_generation_and_read_bounds);
        run("motion_clock_packet_identity_expiry_and_cap",motion_clock_packet_identity_expiry_and_cap);
        run("motion_try_lock_cold_setup_and_stale_routes",motion_try_lock_cold_setup_and_stale_routes);
        run("motion_record_arrives_during_client_poll",motion_record_arrives_during_client_poll);
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
        run("reactivation_slow_setup_exit_cleanup_deadline",reactivation_slow_initializer_exit_accounts_cleanup_deadline,1);
#endif
        std::cout << cases << " actual-Service cases, " << checks << " checks passed; native mutations "
                  << test_facts::mutations.load() << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
