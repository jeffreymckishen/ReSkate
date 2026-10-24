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

namespace test_clock {
std::atomic<ULONGLONG> now{10000};
std::atomic<unsigned> reads{};
std::atomic<bool> inject_after_open_clock{}, advance_at_world_read{};
}
ULONGLONG WINAPI source_test_now() noexcept {
    // get() first reads its wall, then clock() reads its own freshness wall.
    // Arm an external feed at that opening clock read; the next native world
    // ABI read occurs after the shared clock lock has been released.
    if (++test_clock::reads == 2 && test_clock::inject_after_open_clock.load())
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
std::atomic<bool> multiplayer_active{};
std::function<dingosdk::BoundedLocalSurfaceProbe(const std::array<float,3>&,const std::array<float,3>&,unsigned,bool)> probe_callback;
}
namespace dingosdk::multiplayer {
MultiplayerModel model() {
    ++test_facts::model_calls;
    MultiplayerModel out;
    out.active = test_facts::multiplayer_active.load();
    return out;
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
BoundedLocalSurfaceProbe probe_local_surface_geometry_bounded(const std::array<float, 3>& from,
    const std::array<float, 3>& to, unsigned allowed, bool contact) {
    if(test_facts::probe_callback) return test_facts::probe_callback(from,to,allowed,contact);
    ++test_facts::forbidden_links;return {};
}
namespace supported_build {
bool running_image_matches(std::uintptr_t) noexcept { ++test_facts::forbidden_links; return false; }
}
}

namespace dingosdk::owned_bodies::source_test {
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
    ++test_facts::shape_calls;
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
NativeHandle* forbidden_allocate(std::uintptr_t, NativeHandle*) { ++test_facts::mutations; return nullptr; }
NativeHandle* forbidden_capsule(std::uintptr_t, NativeHandle*, const NativeHandle*, const float*, const float*, float) {
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
        test_facts::model_calls = 0; test_facts::world_calls = 0;
        test_facts::body_calls = 0; test_facts::shape_calls = 0;
        test_facts::mutations = 0; test_facts::multiplayer_active = false; test_facts::probe_callback={};
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
        core = arena.take(0x1000); skater_context = arena.take(0x2000); rig = arena.take(0x5000);
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
        service.base = base; service.client = client; service.world = world; service.state = state;
        service.context = context; service.generation = handle.generation; service.world_generation = 23;
        service.eligible = true; service.tick_at = test_clock::now; service.hooked = true;
        service.api.base = base; service.api.world = world_read;
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

template<class F> void run(const char* name, F function) {
    function();
    check(test_facts::mutations.load() == 0, "source path invoked a native mutator/allocator");
    check(test_facts::forbidden_links.load() == 0, "source path entered unrelated hook/query/constructor dependency");
    ++cases;
    std::cout << "PASS " << name << '\n';
}
} // namespace dingosdk::owned_bodies::source_test

int main() {
    using namespace dingosdk::owned_bodies::source_test;
    try {
        run("capture_nonmutation_and_immutable_measurement", capture_does_not_publish);
        run("owner_generation_world_pool_and_native_lifetime", owner_generation_world_and_pool_failures);
        run("original_age_and_clock_continuity", original_age_and_clock_failures);
        run("unreadable_and_failed_capture_nonmutation", unreadable_and_failed_capture_nonmutation);
        run("owner_clock_and_closing_clock_refusal", owner_clock_and_closing_clock_refusal);
        run("try_locks_thread_affinity_and_last_error", try_locks_and_thread_affinity);
        run("actual_sdk_release_serialization", sdk_release_cannot_cross_borrow);
        run("service_contact_opt_in_and_read_only",service_contact_opt_in_and_read_only);
        run("service_whole_batch_contact_fences",service_whole_batch_contact_fences);
        run("service_actor_and_nearest_hit_refusals",service_actor_and_nearest_hit_refusals);
        std::cout << cases << " actual-Service cases, " << checks << " checks passed; native mutations "
                  << test_facts::mutations.load() << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
