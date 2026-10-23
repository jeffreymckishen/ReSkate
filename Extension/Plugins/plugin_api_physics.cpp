#include "plugin_api.h"
#include "lua.h"
#include "lualib.h"
#include <charconv>
#include <cmath>
#include <cstring>
#include <new>

namespace dingosdk::plugins {
namespace {
using namespace owned_body;
constexpr char handle_type[] = "reskate.world.physics.body";
constexpr char epoch_type[] = "reskate.world.physics.epoch";
struct BodyValue { std::uint64_t owner{}; Handle handle{}; };
struct EpochValue { std::uint64_t owner{}; Handle handle{}; Epoch epoch{}; };
int fail(lua_State* L, const std::string& why) { lua_pushnil(L); lua_pushlstring(L, why.data(), why.size()); return 2; }
int result(lua_State* L, const std::string& why) {
    lua_pushboolean(L, why.empty()); if (why.empty()) return 1;
    lua_pushlstring(L, why.data(), why.size()); return 2;
}
void fields(lua_State* L, int at, std::initializer_list<const char*> names) {
    luaL_checktype(L, at, LUA_TTABLE); at = lua_absindex(L, at); lua_pushnil(L);
    while (lua_next(L, at)) {
        const char* key = lua_type(L, -2) == LUA_TSTRING ? lua_tostring(L, -2) : nullptr;
        bool found{}; if (key) for (const char* expected : names) found = found || std::strcmp(key, expected) == 0;
        if (!found) luaL_error(L, "unknown native body field");
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
    opaque(L, EpochValue{b.owner, b.handle, sample.epoch}, epoch_type); lua_setfield(L, -2, "epoch");
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
}

struct PhysicsApi {
    static Plugin& plugin(lua_State* L) {
        auto& p = plugin_of(L); need(L, p, "world.physics", "reskate.world.physics");
        if (p.services_.authority()) luaL_error(L, "native bodies are client phase only");
        return p;
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
    static int submit(lua_State* L) {
        auto& p = plugin(L); const auto b = body(L, p, 1);
        const auto& epoch = *static_cast<const EpochValue*>(luaL_checkudata(L, 2, epoch_type));
        if (epoch.owner != p.instance() || epoch.handle != b.handle) luaL_error(L, "body epoch belongs to another body or plugin instance");
        fields(L, 3, {"force", "torque", "impulse", "impulse_id"});
        Command command; command.epoch = epoch.epoch; command.force = vec_field(L, 3, "force", true);
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
    static int receipt(lua_State* L) {
        auto& p = plugin(L); const auto b = body(L, p, 1); Receipt receipt;
        const auto selected = lua_isnoneornil(L, 2) ? std::uint64_t{} : sequence(L, 2);
        const auto why = p.services_.game().body_receipt(p.instance(), b.handle, selected, receipt);
        if (!why.empty()) return fail(L, why);
        lua_createtable(L, 0, 9);
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
    metatable(L, handle_type); metatable(L, epoch_type);
    lua_getfield(L, -1, "world"); lua_setreadonly(L, -1, false);
    add_functions(L, "physics", {{"create", PhysicsApi::create}, {"read", PhysicsApi::read}, {"submit", PhysicsApi::submit},
        {"receipt", PhysicsApi::receipt}, {"acknowledge", PhysicsApi::acknowledge}, {"release", PhysicsApi::release}});
    lua_setreadonly(L, -1, true); lua_pop(L, 1);
}
} // namespace dingosdk::plugins
