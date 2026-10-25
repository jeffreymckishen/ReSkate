#include "plugin_api.h"
#include "Engine/Game/World/motion_refresh_probe.h"
#include "lua.h"
#include "lualib.h"
#include <charconv>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>

namespace dingosdk::plugins {
namespace {
using namespace owned_body;
constexpr char handle_type[] = "reskate.world.physics.body";
constexpr char epoch_type[] = "reskate.world.physics.epoch";
constexpr char sync_probe_type[] = "reskate.world.physics.sync_probe";
constexpr char motion_refresh_probe_type[] = "reskate.world.physics.motion_refresh_probe";
constexpr char follow_type[] = "reskate.world.physics.follow";
constexpr char hit_body_type[] = "reskate.world.physics.hit_body";
struct BodyValue { std::uint64_t owner{}; Handle handle{}; };
struct EpochValue { std::uint64_t owner{}; Handle handle{}; Sample sample{}; };
// The numeric sequence is private authority, inseparable from this VM and body.
struct SyncProbeValue { std::uint64_t owner{}; Handle handle{}; std::uint64_t sequence{}; };
// An actor-scoped diagnostic request, never an SDK body or a submit epoch.
struct MotionRefreshProbeValue { std::uint64_t owner{}, sequence{}; };
struct FollowValue { std::uint64_t owner{}; body_follow_api::Handle handle{}; };
// Equality only inside one returned batch. This is not a usable owned-body handle,
// native identity, feature identity, or claim about the body's motion.
struct HitBodyValue { std::uint64_t owner{}, batch{}; std::uint32_t ordinal{}; };
int hit_body_equal(lua_State* L) {
    const auto& a = *static_cast<const HitBodyValue*>(luaL_checkudata(L, 1, hit_body_type));
    const auto& b = *static_cast<const HitBodyValue*>(luaL_checkudata(L, 2, hit_body_type));
    lua_pushboolean(L, a.owner == b.owner && a.batch == b.batch && a.ordinal == b.ordinal); return 1;
}
int fail(lua_State* L, const std::string& why) { lua_pushnil(L); lua_pushlstring(L, why.data(), why.size()); return 2; }
int result(lua_State* L, const std::string& why) {
    lua_pushboolean(L, why.empty()); if (why.empty()) return 1;
    lua_pushlstring(L, why.data(), why.size()); return 2;
}
void fields(lua_State* L, int at, std::initializer_list<const char*> names) {
    luaL_checktype(L, at, LUA_TTABLE); at = lua_absindex(L, at); lua_pushnil(L);
    while (lua_next(L, at)) {
        std::size_t size{};
        const char* key = lua_type(L, -2) == LUA_TSTRING ? lua_tolstring(L, -2, &size) : nullptr;
        bool found{}; if (key) for (const char* expected : names) found = found || std::string_view(key, size) == expected;
        if (!found) luaL_error(L, "unknown native body field");
        lua_pop(L, 1);
    }
}
void array_fields(lua_State* L, int at, std::size_t count) {
    at = lua_absindex(L, at); lua_pushnil(L);
    while (lua_next(L, at)) {
        if (lua_type(L, -2) != LUA_TNUMBER) luaL_error(L, "ray batch lists have only sequential integer keys");
        const double key = lua_tonumber(L, -2);
        if (!std::isfinite(key) || key < 1 || key > static_cast<double>(count) || std::floor(key) != key)
            luaL_error(L, "ray batch lists have only sequential integer keys");
        lua_pop(L, 1);
    }
}
Vec vec_field(lua_State* L, int at, const char* name, bool optional = false) {
    lua_getfield(L, at, name);
    Vec v{}; if (!optional || !lua_isnil(L, -1)) v = position_of(L, -1, name);
    lua_pop(L, 1); return v;
}
float number_field(lua_State* L, int at, const char* name) {
    lua_getfield(L, at, name); const double v = luaL_checknumber(L, -1); lua_pop(L, 1);
    if (!std::isfinite(v) || std::abs(v) > 1000000) luaL_error(L, "native body %s must be finite and bounded", name);
    return static_cast<float>(v);
}
BodyValue body(lua_State* L, Plugin& p, int at) {
    const auto& value = *static_cast<const BodyValue*>(luaL_checkudata(L, at, handle_type));
    if (value.owner != p.instance()) luaL_error(L, "native body belongs to another plugin instance");
    return value;
}
void metatable(lua_State* L, const char* name) {
    luaL_newmetatable(L, name); lua_pushstring(L, "locked"); lua_setfield(L, -2, "__metatable"); lua_setreadonly(L, -1, true); lua_pop(L, 1);
}
template<class T> void opaque(lua_State* L, const T& value, const char* name) {
    new (lua_newuserdata(L, sizeof(T))) T(value);
    luaL_getmetatable(L, name); lua_setmetatable(L, -2);
}
void text_number(lua_State* L, std::uint64_t value) { const auto text = std::to_string(value); lua_pushlstring(L, text.data(), text.size()); }
std::uint64_t sequence(lua_State* L, int at) {
    luaL_checktype(L, at, LUA_TSTRING);
    std::size_t size{}; const char* text = luaL_checklstring(L, at, &size); std::uint64_t value{};
    const auto parsed = std::from_chars(text, text + size, value);
    if (!size || text[0] == '0' || parsed.ec != std::errc{} || parsed.ptr != text + size || !value) luaL_argerror(L, at, "a receipt's sequence string");
    return value;
}
void push_sample(lua_State* L, const BodyValue& b, const Sample& sample) {
    lua_createtable(L, 0, 9);
    opaque(L, EpochValue{b.owner, b.handle, sample}, epoch_type); lua_setfield(L, -2, "epoch");
    text_number(L, sample.epoch.serial); lua_setfield(L, -2, "serial");
    lua_pushnumber(L, sample.epoch.time); lua_setfield(L, -2, "time");
    lua_pushnumber(L, sample.epoch.seconds); lua_setfield(L, -2, "seconds");
    push_position(L, sample.position); lua_setfield(L, -2, "position");
    push_position(L, sample.velocity); lua_setfield(L, -2, "velocity");
    push_position(L, sample.angular_velocity); lua_setfield(L, -2, "angular_velocity");
    push_position(L, sample.inertia); lua_setfield(L, -2, "inertia");
    lua_pushnumber(L, sample.mass); lua_setfield(L, -2, "mass");
    lua_createtable(L, 4, 0);
    for (int i = 0; i < 4; ++i) { lua_pushnumber(L, sample.rotation[static_cast<std::size_t>(i)]); lua_rawseti(L, -2, i + 1); }
    lua_setfield(L, -2, "rotation");
}
const char* sync_status(body_sync_probe::Status status) noexcept {
    switch (status) {
    case body_sync_probe::Status::pending: return "pending";
    case body_sync_probe::Status::observed: return "observed";
    case body_sync_probe::Status::expired: return "expired";
    case body_sync_probe::Status::invalidated: return "invalidated";
    }
    return nullptr;
}
bool sync_epoch(const Epoch& e) noexcept {
    return e.world && e.body && e.serial && std::isfinite(e.time) && e.time >= 0 && calibrated(e.seconds);
}
template<std::size_t N> bool finite_values(const std::array<float, N>& values) noexcept {
    for (float v : values) if (!std::isfinite(v)) return false;
    return true;
}
bool sync_result(const body_sync_probe::Result& out) noexcept {
    if (!sync_status(out.status) || !sync_epoch(out.armed_epoch) || (out.observed_mask & ~15u)) return false;
    for (std::size_t i = 0; i < out.records.size(); ++i) {
        const auto& r = out.records[i];
        if (r.present != ((out.observed_mask & (1u << i)) != 0)) return false;
        if (!r.present) continue;
        if (!sync_epoch(r.epoch) || r.epoch.world != out.armed_epoch.world || r.epoch.body != out.armed_epoch.body ||
            r.epoch.serial <= out.armed_epoch.serial || r.epoch.time <= out.armed_epoch.time ||
            r.pending_before != ((r.before_flags & 1u) != 0) || r.pending_after != ((r.after_flags & 1u) != 0) ||
            !finite_values(r.supplied) || !finite_values(r.com_position) || !finite_values(r.origin) ||
            !finite_values(r.local_com) || !finite_values(r.rotation) || !finite_values(r.local_rotation)) return false;
    }
    if (out.status == body_sync_probe::Status::observed) {
        if (out.observed_mask != 15 || !sync_epoch(out.observed_epoch) ||
            out.observed_epoch.world != out.armed_epoch.world || out.observed_epoch.body != out.armed_epoch.body) return false;
        for (const auto& r : out.records) if (out.observed_epoch.serial <= r.epoch.serial || out.observed_epoch.time <= r.epoch.time) return false;
    }
    return true;
}
void push_sync_epoch(lua_State* L, const Epoch& e) {
    lua_createtable(L, 0, 3);
    text_number(L, e.serial); lua_setfield(L, -2, "serial");
    lua_pushnumber(L, e.time); lua_setfield(L, -2, "time");
    lua_pushnumber(L, e.seconds); lua_setfield(L, -2, "seconds");
}
template<std::size_t N> void push_values(lua_State* L, const std::array<float, N>& values) {
    lua_createtable(L, static_cast<int>(N), 0);
    for (std::size_t i = 0; i < N; ++i) { lua_pushnumber(L, values[i]); lua_rawseti(L, -2, static_cast<int>(i + 1)); }
}
const char* motion_refresh_status(motion_refresh_probe::Status status) noexcept {
    switch (status) {
    case motion_refresh_probe::Status::pending: return "pending";
    case motion_refresh_probe::Status::observed: return "observed";
    case motion_refresh_probe::Status::expired: return "expired";
    case motion_refresh_probe::Status::invalidated: return "invalidated";
    }
    return nullptr;
}
bool motion_refresh_epoch(const motion_refresh_probe::Epoch& epoch) noexcept {
    // actor_epoch is a destruction counter whose valid initial value is zero.
    return epoch.world_generation && epoch.lifetime_epoch && epoch.serial &&
        std::isfinite(epoch.time) && epoch.time >= 0 && calibrated(epoch.seconds);
}
bool motion_refresh_identity(const motion_refresh_probe::Epoch& a, const motion_refresh_probe::Epoch& b) noexcept {
    return a.world_generation == b.world_generation && a.lifetime_epoch == b.lifetime_epoch && a.actor_epoch == b.actor_epoch;
}
bool motion_refresh_values(const motion_refresh_probe::Endpoints& endpoints) noexcept {
    if (!finite_values(endpoints.root) || !finite_values(endpoints.inverse)) return false;
    for (const auto& matrix : endpoints.caches) if (!finite_values(matrix)) return false;
    for (const auto& matrix : endpoints.packets) if (!finite_values(matrix)) return false;
    return true;
}
bool motion_refresh_result(const motion_refresh_probe::Result& out) noexcept {
    if (!motion_refresh_status(out.status) || !motion_refresh_epoch(out.armed_epoch) ||
        !std::isfinite(out.elapsed_ms) || out.elapsed_ms < 0 ||
        out.routing.entries > motion_refresh_probe::callback_limit ||
        out.routing.limit_reached != (out.routing.entries == motion_refresh_probe::callback_limit)) return false;
    const auto& record = out.record;
    if (record.present) {
        if (!record.unchanged_forwarding || !finite_values(record.input) ||
            !motion_refresh_epoch(record.before_epoch) || !motion_refresh_identity(record.before_epoch, out.armed_epoch) ||
            record.before_epoch.serial <= out.armed_epoch.serial || record.before_epoch.time <= out.armed_epoch.time ||
            record.after_epoch != record.before_epoch || !motion_refresh_values(record.before) ||
            !motion_refresh_values(record.after)) return false;
    } else if (record.unchanged_forwarding || record.flag || record.input != std::array<float, 4>{} ||
        record.before_epoch != motion_refresh_probe::Epoch{} || record.after_epoch != motion_refresh_probe::Epoch{} ||
        record.before != motion_refresh_probe::Endpoints{} || record.after != motion_refresh_probe::Endpoints{}) return false;
    if (out.status == motion_refresh_probe::Status::observed) {
        return record.present && out.client_revalidated && motion_refresh_epoch(out.confirmed_epoch) &&
            motion_refresh_identity(out.confirmed_epoch, out.armed_epoch) &&
            out.confirmed_epoch.serial > record.after_epoch.serial && out.confirmed_epoch.time > record.after_epoch.time &&
            out.elapsed_ms < motion_refresh_probe::lifetime_ms;
    }
    // Terminal non-observed results may retain a present native-return record.
    // Other routing counters are independent lower bounds, not a sum of entries.
    return !out.client_revalidated && out.confirmed_epoch == motion_refresh_probe::Epoch{};
}
void push_motion_refresh_epoch(lua_State* L, const motion_refresh_probe::Epoch& epoch) {
    lua_createtable(L, 0, 6);
    text_number(L, epoch.world_generation); lua_setfield(L, -2, "world_generation");
    text_number(L, epoch.lifetime_epoch); lua_setfield(L, -2, "lifetime_epoch");
    text_number(L, epoch.actor_epoch); lua_setfield(L, -2, "actor_epoch");
    text_number(L, epoch.serial); lua_setfield(L, -2, "serial");
    lua_pushnumber(L, epoch.time); lua_setfield(L, -2, "time");
    lua_pushnumber(L, epoch.seconds); lua_setfield(L, -2, "seconds");
}
void push_motion_refresh_endpoints(lua_State* L, const motion_refresh_probe::Endpoints& endpoints) {
    lua_createtable(L, 0, 5);
    push_values(L, endpoints.root); lua_setfield(L, -2, "root");
    push_values(L, endpoints.inverse); lua_setfield(L, -2, "inverse");
    lua_createtable(L, static_cast<int>(endpoints.caches.size()), 0);
    for (std::size_t i = 0; i < endpoints.caches.size(); ++i) {
        push_values(L, endpoints.caches[i]); lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, -2, "caches");
    lua_createtable(L, static_cast<int>(endpoints.packets.size()), 0);
    for (std::size_t i = 0; i < endpoints.packets.size(); ++i) {
        push_values(L, endpoints.packets[i]); lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, -2, "packets");
    lua_createtable(L, static_cast<int>(endpoints.flags.size()), 0);
    for (std::size_t i = 0; i < endpoints.flags.size(); ++i) {
        lua_pushnumber(L, endpoints.flags[i]); lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    lua_setfield(L, -2, "flags");
}
void push_motion_refresh_result(lua_State* L, const motion_refresh_probe::Result& out) {
    lua_createtable(L, 0, 7);
    lua_pushstring(L, motion_refresh_status(out.status)); lua_setfield(L, -2, "status");
    push_motion_refresh_epoch(L, out.armed_epoch); lua_setfield(L, -2, "armed_epoch");
    push_motion_refresh_epoch(L, out.confirmed_epoch); lua_setfield(L, -2, "confirmed_epoch");
    lua_pushboolean(L, out.client_revalidated); lua_setfield(L, -2, "client_revalidated");
    lua_pushnumber(L, out.elapsed_ms); lua_setfield(L, -2, "elapsed_ms");
    lua_createtable(L, 0, 8);
    lua_pushboolean(L, out.record.present); lua_setfield(L, -2, "present");
    lua_pushboolean(L, out.record.unchanged_forwarding); lua_setfield(L, -2, "unchanged_forwarding");
    lua_pushnumber(L, out.record.flag); lua_setfield(L, -2, "flag");
    push_values(L, out.record.input); lua_setfield(L, -2, "input");
    push_motion_refresh_epoch(L, out.record.before_epoch); lua_setfield(L, -2, "before_epoch");
    push_motion_refresh_epoch(L, out.record.after_epoch); lua_setfield(L, -2, "after_epoch");
    push_motion_refresh_endpoints(L, out.record.before); lua_setfield(L, -2, "before");
    push_motion_refresh_endpoints(L, out.record.after); lua_setfield(L, -2, "after");
    lua_setfield(L, -2, "record");
    lua_createtable(L, 0, 6);
    lua_pushnumber(L, out.routing.entries); lua_setfield(L, -2, "entries");
    lua_pushnumber(L, out.routing.matching); lua_setfield(L, -2, "matching");
    lua_pushnumber(L, out.routing.other); lua_setfield(L, -2, "other");
    lua_pushnumber(L, out.routing.rejected); lua_setfield(L, -2, "rejected");
    lua_pushnumber(L, out.routing.dropped); lua_setfield(L, -2, "dropped");
    lua_pushboolean(L, out.routing.limit_reached); lua_setfield(L, -2, "limit_reached");
    lua_setfield(L, -2, "routing");
}
FollowValue follow(lua_State* L, Plugin& p) {
    if (lua_gettop(L) != 1) luaL_error(L, "an opaque follow handle is the only argument");
    const auto value = *static_cast<const FollowValue*>(luaL_checkudata(L, 1, follow_type));
    if (value.owner != p.instance()) luaL_error(L, "follow handle belongs to another plugin instance");
    return value;
}
body_follow_api::Attachment follow_attachment(lua_State* L, int at) {
    fields(L, at, {"offset_from_com", "root_in_body", "cleanup", "motion_policy"});
    body_follow_api::Attachment attachment;
    attachment.offset_from_com = vec_field(L, at, "offset_from_com");
    lua_getfield(L, at, "root_in_body"); luaL_checktype(L, -1, LUA_TTABLE);
    if (lua_objlen(L, -1) != 4) luaL_error(L, "follow root_in_body has four Hamilton XYZW values");
    array_fields(L, -1, 4);
    for (int i = 0; i < 4; ++i) {
        lua_rawgeti(L, -1, i + 1);
        attachment.root_in_body[static_cast<std::size_t>(i)] = static_cast<float>(luaL_checknumber(L, -1));
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
    lua_getfield(L, at, "cleanup");
    if (!lua_isnil(L, -1)) {
        if (lua_type(L, -1) != LUA_TSTRING) luaL_error(L, "follow cleanup is actor_lifetime or owned_body");
        std::size_t length{};
        const auto* text = lua_tolstring(L, -1, &length);
        const std::string_view cleanup{text, length};
        if (cleanup == "owned_body") attachment.cleanup = body_follow_api::CleanupPolicy::owned_body;
        else if (cleanup != "actor_lifetime") luaL_error(L, "follow cleanup is actor_lifetime or owned_body");
    }
    lua_pop(L, 1);
    lua_getfield(L, at, "motion_policy");
    if (!lua_isnil(L, -1)) {
        if (lua_type(L, -1) != LUA_TSTRING) luaL_error(L, "follow motion_policy is native_lifetime or callback_entry");
        std::size_t length{};
        const auto* text = lua_tolstring(L, -1, &length);
        const std::string_view policy{text, length};
        if (policy == "callback_entry") attachment.motion_policy = body_follow_api::MotionPolicy::callback_entry;
        else if (policy != "native_lifetime") luaL_error(L, "follow motion_policy is native_lifetime or callback_entry");
    }
    lua_pop(L, 1);
    if (attachment.motion_policy == body_follow_api::MotionPolicy::callback_entry &&
        attachment.cleanup != body_follow_api::CleanupPolicy::owned_body)
        luaL_error(L, "follow callback_entry requires explicit cleanup=owned_body");
    if (!body_follow_api::valid(attachment))
        luaL_error(L, "follow attachment needs a finite COM offset within +/-10m and a unit Hamilton XYZW rotation");
    return attachment;
}
bool follow_receipt(const body_follow_api::Receipt& receipt, body_follow_api::Handle handle) noexcept {
    using namespace body_follow_api;
    if (!handle.sequence || receipt.handle.sequence != handle.sequence || !phase_name(receipt.phase) ||
        std::string_view(skater_action::reason_name(receipt.reason)) == "invalid" ||
        std::string_view(skater_action::reason_name(receipt.park_reason)) == "invalid" ||
        (receipt.pending != Pending::none && receipt.pending != Pending::body_parked) ||
        receipt.in_flight > 255 || receipt.returned_revision > receipt.final_revision ||
        ((!receipt.final_revision) != (!receipt.final_native_epoch)) || receipt.native_retirement_known) return false;
    if (receipt.phase == Phase::reserved &&
        (receipt.final_revision || receipt.park_observed || receipt.pending != Pending::none)) return false;
    if (receipt.phase == Phase::abandoned && (receipt.final_revision || receipt.in_flight || receipt.park_observed ||
        receipt.pending != Pending::none)) return false;
    if (receipt.phase == Phase::completed && (!receipt.park_observed || receipt.in_flight ||
        receipt.pending != Pending::none || receipt.returned_revision != receipt.final_revision)) return false;
    return true;
}
void push_follow_receipt(lua_State* L, const body_follow_api::Receipt& receipt) {
    lua_createtable(L, 0, 15);
    lua_pushstring(L, body_follow_api::phase_name(receipt.phase)); lua_setfield(L, -2, "phase");
    lua_pushstring(L, skater_action::reason_name(receipt.reason)); lua_setfield(L, -2, "reason");
    lua_pushstring(L, skater_action::reason_name(receipt.park_reason)); lua_setfield(L, -2, "park_reason");
    text_number(L, receipt.handle.sequence); lua_setfield(L, -2, "sequence");
    text_number(L, receipt.final_revision); lua_setfield(L, -2, "final_revision");
    text_number(L, receipt.final_native_epoch); lua_setfield(L, -2, "final_native_epoch");
    text_number(L, receipt.returned_revision); lua_setfield(L, -2, "returned_revision");
    lua_createtable(L, receipt.pending == body_follow_api::Pending::body_parked ? 1 : 0, 0);
    if (receipt.pending == body_follow_api::Pending::body_parked) { lua_pushstring(L, "body_parked"); lua_rawseti(L, -2, 1); }
    lua_setfield(L, -2, "pending");
    lua_pushnumber(L, receipt.in_flight); lua_setfield(L, -2, "in_flight");
    lua_pushboolean(L, receipt.claim_known); lua_setfield(L, -2, "claim_known");
    lua_pushboolean(L, receipt.orphaned); lua_setfield(L, -2, "orphaned");
    lua_pushboolean(L, receipt.park_observed); lua_setfield(L, -2, "park_observed");
    lua_pushboolean(L, receipt.native_retirement_known); lua_setfield(L, -2, "native_retirement_known");
    lua_pushboolean(L, body_follow_api::terminal(receipt.phase)); lua_setfield(L, -2, "terminal");
}
int follow_result(lua_State* L, bool ok, const char* why) {
    lua_pushboolean(L, ok);
    if (ok) return 1;
    lua_pushstring(L, why); return 2;
}
}

struct PhysicsApi {
    static Plugin& plugin(lua_State* L) {
        auto& p = plugin_of(L); need(L, p, "world.physics", "reskate.world.physics");
        if (p.services_.authority()) luaL_error(L, "native bodies are client phase only");
        return p;
    }
    static int prepare(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 0) luaL_error(L, "prepare takes no arguments");
        if (p.body_prepares_ >= 1) return result(L, "asked to prepare native bodies more than once in one tick");
        ++p.body_prepares_;
        return result(L, p.services_.game().body_prepare());
    }
    static Plugin& follow_plugin(lua_State* L) {
        auto& p = plugin(L);
        need(L, p, "world.physics.follow", "reskate.world.physics follow");
        return p;
    }
    static int reserve_follow(lua_State* L) {
        auto& p = follow_plugin(L);
        if (lua_gettop(L) != 2) luaL_error(L, "reserve_follow takes one owned body and one attachment");
        const auto b = body(L, p, 1); const auto attachment = follow_attachment(L, 2);
        if (p.follow_reserves_ >= body_follow_api::reserve_limit) return fail(L, "asked to reserve follow more than once in one tick");
        ++p.follow_reserves_;
        // Allocate before native admission. There is deliberately no __gc:
        // dropping userdata cannot release or acknowledge a native claim.
        auto* value = new (lua_newuserdata(L, sizeof(FollowValue))) FollowValue{p.instance(), {}};
        luaL_getmetatable(L, follow_type); lua_setmetatable(L, -2);
        body_follow_api::Reason reason{body_follow_api::Reason::unavailable};
        const bool accepted = p.services_.game().body_follow_reserve(p.instance(), b.handle, attachment, value->handle, reason);
        const auto reason_name = skater_action::reason_name(reason);
        const bool valid_reason = std::string_view(reason_name) != "invalid";
        const char* why = !valid_reason ? "follow reserve returned an invalid reason" :
            reason == body_follow_api::Reason::none ? "follow reserve was refused" : reason_name;
        if (!value->handle.sequence) {
            lua_pop(L, 1);
            return fail(L, accepted ? "follow reserve did not return owned authority" : why);
        }
        // A nonzero refused reservation still owns cleanup duty. Returning nil
        // here would hide it. The second result must be checked before publish.
        if (accepted && valid_reason && reason == body_follow_api::Reason::none) lua_pushnil(L);
        else lua_pushstring(L, why);
        return 2;
    }
    static int publish_follow(lua_State* L) {
        auto& p = follow_plugin(L); const auto value = follow(L, p);
        if (p.follow_publishes_ >= body_follow_api::publish_limit) return follow_result(L, false, "asked to publish follow more than once in one tick");
        ++p.follow_publishes_;
        body_follow_api::Reason reason{body_follow_api::Reason::unavailable};
        const bool ok = p.services_.game().body_follow_publish(p.instance(), value.handle, reason);
        return follow_result(L, ok, skater_action::reason_name(reason));
    }
    static int read_follow(lua_State* L) {
        auto& p = follow_plugin(L); const auto value = follow(L, p);
        if (p.follow_reads_ >= body_follow_api::read_limit) return fail(L, "asked to read follow more than 8 times in one tick");
        ++p.follow_reads_;
        body_follow_api::Receipt receipt;
        if (!p.services_.game().body_follow_read(p.instance(), value.handle, receipt)) return fail(L, "follow receipt unavailable");
        if (!follow_receipt(receipt, value.handle)) return fail(L, "follow receipt returned invalid observations");
        push_follow_receipt(L, receipt); return 1;
    }
    static int stop_follow(lua_State* L) {
        auto& p = follow_plugin(L); const auto value = follow(L, p);
        if (p.follow_stops_ >= body_follow_api::stop_limit) return follow_result(L, false, "asked to stop follow more than once in one tick");
        ++p.follow_stops_;
        return follow_result(L, p.services_.game().body_follow_stop(p.instance(), value.handle), "follow cannot stop now");
    }
    static int acknowledge_follow(lua_State* L) {
        auto& p = follow_plugin(L); const auto value = follow(L, p);
        if (p.follow_acknowledgements_ >= body_follow_api::acknowledge_limit)
            return follow_result(L, false, "asked to acknowledge follow more than once in one tick");
        ++p.follow_acknowledgements_;
        return follow_result(L, p.services_.game().body_follow_acknowledge(p.instance(), value.handle),
            "follow cleanup is incomplete or receipt unavailable");
    }
    static int create(lua_State* L) {
        auto& p = plugin(L);
        fields(L, 1, {"capsules", "mass", "inertia", "position", "rotation"});
        Definition d; d.mass = number_field(L, 1, "mass"); d.inertia = vec_field(L, 1, "inertia"); d.position = vec_field(L, 1, "position");
        lua_getfield(L, 1, "rotation"); luaL_checktype(L, -1, LUA_TTABLE);
        if (lua_objlen(L, -1) != 4) luaL_error(L, "a body rotation has four XYZW values");
        for (int i = 0; i < 4; ++i) { lua_rawgeti(L, -1, i + 1); d.rotation[static_cast<std::size_t>(i)] = static_cast<float>(luaL_checknumber(L, -1)); lua_pop(L, 1); }
        lua_pop(L, 1);
        lua_getfield(L, 1, "capsules"); luaL_checktype(L, -1, LUA_TTABLE); d.count = lua_objlen(L, -1);
        if (!d.count || d.count > maximum_capsules) luaL_error(L, "a body has 1 to 8 capsules");
        for (std::size_t i = 0; i < d.count; ++i) {
            lua_rawgeti(L, -1, static_cast<int>(i + 1)); fields(L, -1, {"a", "b", "radius"}); const auto at = lua_absindex(L, -1);
            d.capsules[i] = {vec_field(L, at, "a"), vec_field(L, at, "b"), number_field(L, at, "radius")}; lua_pop(L, 1);
        }
        lua_pop(L, 1);
        if (!valid(d)) luaL_error(L, "invalid native body: mass 1..1000, inertia .01..10000, unit XYZW rotation, capsule endpoints +/-10m and radius .01..2m");
        Handle h; const auto why = p.services_.game().body_create(p.instance(), d, h);
        if (!why.empty()) return fail(L, why);
        if (!h.generation || h.slot >= retained_capacity) return fail(L, "native body did not return an owned generation");
        opaque(L, BodyValue{p.instance(), h}, handle_type); return 1;
    }
    static int read(lua_State* L) {
        auto& p = plugin(L); const auto b = body(L, p, 1); Sample sample;
        const auto why = p.services_.game().body_read(p.instance(), b.handle, sample);
        if (!why.empty()) return fail(L, why);
        push_sample(L, b, sample); return 1;
    }
    static Plugin& sync_plugin(lua_State* L) {
        auto& p = plugin(L);
        need(L, p, "world.physics.observe", "reskate.world.physics synchronizer observation");
        return p;
    }
    static int begin_sync_probe(lua_State* L) {
        auto& p = sync_plugin(L);
        if (lua_gettop(L) != 1) luaL_error(L, "begin_sync_probe takes one owned body");
        const auto b = body(L, p, 1);
        if (p.sync_probe_starts_ >= 1) return fail(L, "asked to begin a synchronizer probe more than once in one tick");
        ++p.sync_probe_starts_;
        // Allocate before admission so a Lua allocation failure leaves no orphan probe.
        auto* probe = new (lua_newuserdata(L, sizeof(SyncProbeValue))) SyncProbeValue{p.instance(), b.handle, 0};
        luaL_getmetatable(L, sync_probe_type); lua_setmetatable(L, -2);
        const auto why = p.services_.game().body_begin_sync_probe(p.instance(), b.handle, probe->sequence);
        if (!why.empty()) { lua_pop(L, 1); return fail(L, why); }
        if (!probe->sequence) { lua_pop(L, 1); return fail(L, "synchronizer probe did not return owned authority"); }
        return 1;
    }
    static int poll_sync_probe(lua_State* L) {
        auto& p = sync_plugin(L);
        if (lua_gettop(L) != 1) luaL_error(L, "poll_sync_probe takes one opaque probe");
        const auto probe = *static_cast<const SyncProbeValue*>(luaL_checkudata(L, 1, sync_probe_type));
        if (probe.owner != p.instance()) luaL_error(L, "synchronizer probe belongs to another plugin instance");
        if (p.sync_probe_polls_ >= 8) return fail(L, "asked to poll synchronizer probes more than 8 times in one tick");
        ++p.sync_probe_polls_;
        body_sync_probe::Result out;
        const auto why = p.services_.game().body_poll_sync_probe(p.instance(), probe.handle, probe.sequence, out);
        if (!why.empty()) return fail(L, why);
        if (!sync_result(out)) return fail(L, "synchronizer probe returned invalid observations");
        lua_createtable(L, 0, 9);
        lua_pushstring(L, sync_status(out.status)); lua_setfield(L, -2, "status");
        lua_pushboolean(L, out.status != body_sync_probe::Status::pending); lua_setfield(L, -2, "terminal");
        push_sync_epoch(L, out.armed_epoch); lua_setfield(L, -2, "armed_epoch");
        if (out.status == body_sync_probe::Status::observed) { push_sync_epoch(L, out.observed_epoch); lua_setfield(L, -2, "observed_epoch"); }
        lua_pushnumber(L, out.observed_mask); lua_setfield(L, -2, "observed_mask");
        lua_pushnumber(L, out.rejected); lua_setfield(L, -2, "rejected");
        lua_pushnumber(L, out.dropped); lua_setfield(L, -2, "dropped");
        lua_createtable(L, 0, 5);
        lua_pushnumber(L, out.routing.entries); lua_setfield(L, -2, "entries");
        lua_pushnumber(L, out.routing.other); lua_setfield(L, -2, "other");
        lua_pushnumber(L, out.routing.already_recorded); lua_setfield(L, -2, "already_recorded");
        lua_pushnumber(L, out.routing.expired_entries); lua_setfield(L, -2, "expired_entries");
        lua_createtable(L, 4, 0);
        for (std::size_t i = 0; i < out.routing.matches.size(); ++i) {
            lua_pushnumber(L, out.routing.matches[i]); lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        lua_setfield(L, -2, "matches"); lua_setfield(L, -2, "routing");
        lua_createtable(L, 4, 0);
        for (std::size_t i = 0; i < out.records.size(); ++i) {
            const auto& r = out.records[i]; lua_createtable(L, 0, r.present ? 13 : 1);
            lua_pushboolean(L, r.present); lua_setfield(L, -2, "present");
            if (r.present) {
                lua_pushboolean(L, r.pending_before); lua_setfield(L, -2, "pending_before");
                lua_pushboolean(L, r.pending_after); lua_setfield(L, -2, "pending_after");
                lua_pushboolean(L, r.transform_matches); lua_setfield(L, -2, "transform_matches");
                lua_pushnumber(L, r.before_flags); lua_setfield(L, -2, "before_flags");
                lua_pushnumber(L, r.after_flags); lua_setfield(L, -2, "after_flags");
                push_values(L, r.supplied); lua_setfield(L, -2, "supplied");
                push_position(L, r.com_position); lua_setfield(L, -2, "com_position");
                push_position(L, r.origin); lua_setfield(L, -2, "origin");
                push_position(L, r.local_com); lua_setfield(L, -2, "local_com");
                push_values(L, r.rotation); lua_setfield(L, -2, "rotation");
                push_values(L, r.local_rotation); lua_setfield(L, -2, "local_rotation");
                push_sync_epoch(L, r.epoch); lua_setfield(L, -2, "epoch");
            }
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        lua_setfield(L, -2, "records"); return 1;
    }
    static int begin_motion_refresh_probe(lua_State* L) {
        auto& p = sync_plugin(L);
        if (lua_gettop(L) != 0) luaL_error(L, "begin_motion_refresh_probe takes no arguments");
        if (p.sync_probe_starts_ >= 1) return fail(L, "asked to begin passive probes more than once in one tick");
        ++p.sync_probe_starts_;
        // Allocate before backend admission; a failed Lua allocation cannot
        // leave an admitted request without its only owning opaque handle.
        auto* probe = new (lua_newuserdata(L, sizeof(MotionRefreshProbeValue))) MotionRefreshProbeValue{p.instance(), 0};
        luaL_getmetatable(L, motion_refresh_probe_type); lua_setmetatable(L, -2);
        const auto why = p.services_.game().begin_motion_refresh_probe(p.instance(), probe->sequence);
        if (!why.empty()) { lua_pop(L, 1); return fail(L, why); }
        if (!probe->sequence) { lua_pop(L, 1); return fail(L, "motion refresh probe did not return an owned request"); }
        return 1;
    }
    static int poll_motion_refresh_probe(lua_State* L) {
        auto& p = sync_plugin(L);
        if (lua_gettop(L) != 1) luaL_error(L, "poll_motion_refresh_probe takes one opaque probe");
        const auto probe = *static_cast<const MotionRefreshProbeValue*>(luaL_checkudata(L, 1, motion_refresh_probe_type));
        if (probe.owner != p.instance()) luaL_error(L, "motion refresh probe belongs to another plugin instance");
        if (p.sync_probe_polls_ >= 8) return fail(L, "asked to poll passive probes more than 8 times in one tick");
        ++p.sync_probe_polls_;
        motion_refresh_probe::Result out;
        const auto why = p.services_.game().poll_motion_refresh_probe(p.instance(), probe.sequence, out);
        if (!why.empty()) return fail(L, why);
        if (!motion_refresh_result(out)) return fail(L, "motion refresh probe returned invalid observations");
        push_motion_refresh_result(L, out); return 1;
    }
    static int submit(lua_State* L) {
        auto& p = plugin(L); const auto b = body(L, p, 1);
        const auto& epoch = *static_cast<const EpochValue*>(luaL_checkudata(L, 2, epoch_type));
        if (epoch.owner != p.instance() || epoch.handle != b.handle) luaL_error(L, "body epoch belongs to another body or plugin instance");
        fields(L, 3, {"force", "torque", "impulse", "impulse_id"});
        Command command; command.epoch = epoch.sample.epoch; command.force = vec_field(L, 3, "force", true);
        command.torque = vec_field(L, 3, "torque", true); command.impulse = vec_field(L, 3, "impulse", true);
        lua_getfield(L, 3, "impulse_id");
        if (!lua_isnil(L, -1)) {
            const double id = luaL_checknumber(L, -1);
            if (!std::isfinite(id) || id < 1 || id > 4294967295.0 || std::floor(id) != id) luaL_error(L, "impulse_id is a positive uint32 event number");
            command.impulse_id = static_cast<std::uint32_t>(id);
        }
        lua_pop(L, 1);
        if (!valid(command)) luaL_error(L, "native body command exceeds its force, torque or one-shot impulse bound");
        std::uint64_t assigned{}; const auto why = p.services_.game().body_submit(p.instance(), b.handle, command, assigned);
        if (!why.empty()) return result(L, why);
        if (!assigned) return result(L, "native body did not return a command sequence");
        lua_pushboolean(L, true); lua_pushnil(L); text_number(L, assigned); return 3;
    }
    static int probe_batch(lua_State* L) {
        auto& p = plugin(L); need(L, p, "world.raycast", "reskate.world.physics.probe_batch");
        if (lua_gettop(L) < 3 || lua_gettop(L) > 4) luaL_error(L, "probe_batch takes body, measured epoch, rays and optional query options");
        const auto b = body(L, p, 1);
        const auto& epoch = *static_cast<const EpochValue*>(luaL_checkudata(L, 2, epoch_type));
        if (epoch.owner != p.instance() || epoch.handle != b.handle) luaL_error(L, "body epoch belongs to another body or plugin instance");
        body_query::Request request; request.observation = epoch.sample;
        luaL_checktype(L, 3, LUA_TTABLE); request.count = lua_objlen(L, 3);
        if (!request.count || request.count > body_query::maximum_rays) luaL_error(L, "a ray batch has 1 to 32 rays");
        array_fields(L, 3, request.count);
        for (std::size_t i = 0; i < request.count; ++i) {
            lua_rawgeti(L, 3, static_cast<int>(i + 1)); fields(L, -1, {"from", "to"});
            const auto at = lua_absindex(L, -1); request.rays[i] = {vec_field(L, at, "from"), vec_field(L, at, "to")}; lua_pop(L, 1);
        }
        bool preset_requested{};
        if (!lua_isnoneornil(L, 4)) {
            fields(L, 4, {"exclude_bodies", "exclude_local_actor", "require_contact", "query_preset", "include_shape_categories"});
            lua_getfield(L, 4, "query_preset");
            if (!lua_isnil(L, -1)) {
                // Only an actual string naming a fixed preset; numbers are not coerced
                // and no raw native filter can be expressed.
                std::size_t size{};
                const char* text = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &size) : nullptr;
                bool known{};
                for (const auto preset : {body_query::QueryPreset::camera, body_query::QueryPreset::terrain})
                    if (text && std::string_view(text, size) == body_query::name(preset)) { request.preset = preset; known = true; }
                if (!known) luaL_error(L, "query_preset is \"camera\" or \"terrain\"");
                preset_requested = true;
            }
            lua_pop(L, 1);
            lua_getfield(L, 4, "require_contact");
            if (!lua_isnil(L,-1)) { luaL_checktype(L,-1,LUA_TBOOLEAN); request.require_contact=lua_toboolean(L,-1)!=0; }
            lua_pop(L,1);
            lua_getfield(L, 4, "exclude_local_actor");
            if (!lua_isnil(L, -1)) { luaL_checktype(L, -1, LUA_TBOOLEAN); request.exclude_local_actor = lua_toboolean(L, -1) != 0; }
            lua_pop(L, 1); lua_getfield(L, 4, "exclude_bodies");
            if (!lua_isnil(L, -1)) {
                luaL_checktype(L, -1, LUA_TTABLE); request.exclusions = lua_objlen(L, -1);
                if (request.exclusions > body_query::maximum_exclusions) luaL_error(L, "a ray batch excludes at most 8 additional owned bodies");
                array_fields(L, -1, request.exclusions);
                for (std::size_t i = 0; i < request.exclusions; ++i) {
                    lua_rawgeti(L, -1, static_cast<int>(i + 1)); request.excluded[i] = body(L, p, -1).handle; lua_pop(L, 1);
                }
            }
            lua_pop(L, 1); lua_getfield(L, 4, "include_shape_categories");
            // Passive hit metadata: only an actual boolean, and true also needs the
            // observation permission before any ray counter or backend work.
            if (!lua_isnil(L, -1)) { luaL_checktype(L, -1, LUA_TBOOLEAN); request.include_shape_categories = lua_toboolean(L, -1) != 0; }
            lua_pop(L, 1);
            if (request.include_shape_categories) need(L, p, "world.physics.observe", "reskate.world.physics.probe_batch include_shape_categories");
        }
        const float distance_limit = p.limits_.raycast_metres < 1000 ? p.limits_.raycast_metres : 1000;
        if (!body_query::valid(request, distance_limit)) luaL_error(L, "invalid ray batch: finite nonzero rays within the configured distance");
        if (static_cast<std::int64_t>(p.raycasts_) + static_cast<std::int64_t>(request.count) > p.limits_.raycasts_per_tick)
            luaL_error(L, "more than %d raycasts in one tick", p.limits_.raycasts_per_tick);
        p.raycasts_ += static_cast<int>(request.count);
        const auto allowed = p.native_casts_.remaining();
        body_query::Result out;
        if (!allowed) { out.failure = body_query::Failure::budget; out.budget_exhausted = true; }
        else out = p.services_.game().body_probe_batch(p.instance(), b.handle, request, allowed);
        const bool accounted = out.accounting_valid && p.native_casts_.consume(out.native_casts, allowed);
        if (!accounted) {
            p.native_casts_.poison(); out.available = false;
            if (out.accounting_valid || out.failure != body_query::Failure::query_backend_exception)
                out.failure = body_query::Failure::backend;
        }
        if (out.available) {
            bool valid = out.count == request.count && out.failure == body_query::Failure::none &&
                out.native_casts >= request.count && out.native_casts <= request.count * body_query::casts_per_ray;
            for (std::size_t i = 0; i < request.count && valid; ++i) valid = body_query::consistent(request.rays[i], out.rays[i]) &&
                out.rays[i].body <= request.count && (!request.require_contact || out.rays[i].status!=body_query::Status::hit ||
                    (out.rays[i].normal_available && out.rays[i].surface_velocity_available));
            if (!valid) { out.available = false; out.failure = body_query::Failure::backend; }
        }
        if (p.body_query_sequence_ == std::numeric_limits<std::uint64_t>::max()) return fail(L, "ray batch identity sequence exhausted");
        const auto batch = ++p.body_query_sequence_;
        lua_createtable(L, 0, 5);
        lua_pushstring(L, out.available ? "available" : "unavailable"); lua_setfield(L, -2, "status");
        if (!out.available) { lua_pushstring(L, body_query::name(out.failure == body_query::Failure::none ? body_query::Failure::unavailable : out.failure)); lua_setfield(L, -2, "reason"); }
        if (accounted) { lua_pushinteger(L, static_cast<int>(out.native_casts)); lua_setfield(L, -2, "native_casts"); }
        lua_pushboolean(L, out.budget_exhausted); lua_setfield(L, -2, "budget_exhausted");
        lua_pushvalue(L,2); lua_setfield(L,-2,"epoch");
        lua_pushboolean(L,out.available && request.exclude_local_actor); lua_setfield(L,-2,"local_actor_excluded");
        lua_pushboolean(L,out.available); lua_setfield(L,-2,"owned_bodies_excluded");
        // Only a call that named a preset gets this field, so callers that allow-list
        // the earlier result fields see an unchanged table. It repeats the request:
        // native_casts and status say what ran, and nothing here says what was hit.
        if (preset_requested) { lua_pushstring(L, body_query::name(request.preset)); lua_setfield(L, -2, "requested_query_preset"); }
        lua_createtable(L, static_cast<int>(request.count), 0);
        for (std::size_t i = 0; i < request.count; ++i) {
            const auto& hit = out.rays[i]; const bool present = out.available && hit.status == body_query::Status::hit;
            lua_createtable(L, 0, 5); lua_pushstring(L, !out.available ? "unavailable" : present ? "hit" : "clear"); lua_setfield(L, -2, "status");
            if (present) {
                push_position(L, hit.position); lua_setfield(L, -2, "position"); lua_pushnumber(L, hit.fraction); lua_setfield(L, -2, "fraction");
                lua_pushstring(L, hit.surface_velocity_available ? "measured" : "unknown"); lua_setfield(L,-2,"motion");
                lua_pushboolean(L,hit.normal_available); lua_setfield(L,-2,"normal_available");
                lua_pushboolean(L,hit.surface_velocity_available); lua_setfield(L,-2,"surface_velocity_available");
                if (hit.normal_available) { push_position(L,hit.normal); lua_setfield(L,-2,"normal"); }
                if (hit.surface_velocity_available) { push_position(L,hit.surface_velocity); lua_setfield(L,-2,"surface_velocity"); }
                if (hit.body) { opaque(L, HitBodyValue{p.instance(), batch, hit.body}, hit_body_type); lua_setfield(L, -2, "body"); }
                // Only a request that opted in sees it; absent means unavailable, never zero.
                if (request.include_shape_categories && hit.in_categories_available) { lua_pushnumber(L, hit.in_categories); lua_setfield(L, -2, "in_categories"); }
            }
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        lua_setfield(L, -2, "rays"); return 1;
    }
    static int receipt(lua_State* L) {
        auto& p = plugin(L); const auto b = body(L, p, 1); Receipt receipt;
        const auto selected = lua_isnoneornil(L, 2) ? std::uint64_t{} : sequence(L, 2);
        const auto why = p.services_.game().body_receipt(p.instance(), b.handle, selected, receipt);
        if (!why.empty()) return fail(L, why);
        const char* cleanup = name(receipt.cleanup_disposition);
        if (!cleanup || (receipt.cleanup_disposition == CleanupDisposition::parked_without_successor &&
            (receipt.outcome != Outcome::applied || receipt.successor_available || !receipt.retained ||
                receipt.quarantined || !receipt.force_attempted || !receipt.torque_attempted)))
            return fail(L, "body receipt cleanup disposition is invalid");
        lua_createtable(L, 0, 10);
        lua_pushstring(L, cleanup); lua_setfield(L, -2, "cleanup_disposition");
        lua_pushstring(L, name(receipt.outcome)); lua_setfield(L, -2, "outcome");
        text_number(L, receipt.sequence); lua_setfield(L, -2, "sequence");
        text_number(L, receipt.requested.serial); lua_setfield(L, -2, "requested_serial");
        text_number(L, receipt.produced.serial); lua_setfield(L, -2, "produced_serial");
        lua_pushboolean(L, receipt.force_attempted); lua_setfield(L, -2, "force_attempted");
        lua_pushboolean(L, receipt.torque_attempted); lua_setfield(L, -2, "torque_attempted");
        lua_pushboolean(L, receipt.retained); lua_setfield(L, -2, "retained");
        lua_pushboolean(L, receipt.quarantined); lua_setfield(L, -2, "quarantined");
        if (receipt.successor_available) { push_sample(L, b, receipt.successor); lua_setfield(L, -2, "successor"); }
        return 1;
    }
    static int acknowledge(lua_State* L) {
        auto& p = plugin(L); const auto b = body(L, p, 1);
        return result(L, p.services_.game().body_acknowledge(p.instance(), b.handle, sequence(L, 2)));
    }
    static int release(lua_State* L) {
        auto& p = plugin(L); const auto b = body(L, p, 1);
        return result(L, p.services_.game().body_release(p.instance(), b.handle));
    }
};
void install_physics_api(Plugin&, lua_State* L) {
    metatable(L, handle_type); metatable(L, epoch_type); metatable(L, sync_probe_type);
    metatable(L, motion_refresh_probe_type);
    metatable(L, follow_type);
    luaL_newmetatable(L, hit_body_type); lua_pushstring(L, "locked"); lua_setfield(L, -2, "__metatable");
    lua_pushcfunction(L, hit_body_equal, "hit body equality"); lua_setfield(L, -2, "__eq"); lua_setreadonly(L, -1, true); lua_pop(L, 1);
    lua_getfield(L, -1, "world"); lua_setreadonly(L, -1, false);
    add_functions(L, "physics", {{"prepare", PhysicsApi::prepare}, {"create", PhysicsApi::create}, {"read", PhysicsApi::read}, {"submit", PhysicsApi::submit},
        {"receipt", PhysicsApi::receipt}, {"acknowledge", PhysicsApi::acknowledge}, {"release", PhysicsApi::release}, {"probe_batch", PhysicsApi::probe_batch},
        {"begin_sync_probe", PhysicsApi::begin_sync_probe}, {"poll_sync_probe", PhysicsApi::poll_sync_probe},
        {"begin_motion_refresh_probe", PhysicsApi::begin_motion_refresh_probe}, {"poll_motion_refresh_probe", PhysicsApi::poll_motion_refresh_probe},
        {"reserve_follow", PhysicsApi::reserve_follow}, {"publish_follow", PhysicsApi::publish_follow},
        {"read_follow", PhysicsApi::read_follow}, {"stop_follow", PhysicsApi::stop_follow}, {"acknowledge_follow", PhysicsApi::acknowledge_follow}});
    lua_setreadonly(L, -1, true); lua_pop(L, 1);
}
} // namespace dingosdk::plugins
