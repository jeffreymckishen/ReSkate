#include "plugin_api.h"
#include "lua.h"
#include "lualib.h"
#include <new>
#include <string>
#include <string_view>

namespace dingosdk::plugins {
namespace {
constexpr char trace_type[] = "reskate.skater.input_trace";
struct TraceValue { std::uint64_t owner{}; input_trace::Handle handle{}; };
int failure(lua_State* L, const char* why) { lua_pushnil(L); lua_pushstring(L, why); return 2; }
void text(lua_State* L, const char* key, std::uint64_t value) {
    const auto s = std::to_string(value); lua_pushlstring(L, s.data(), s.size()); lua_setfield(L, -2, key);
}
void number(lua_State* L, const char* key, std::uint32_t value) { lua_pushnumber(L, value); lua_setfield(L, -2, key); }
void boolean(lua_State* L, const char* key, bool value) { lua_pushboolean(L, value); lua_setfield(L, -2, key); }
TraceValue handle(lua_State* L, Plugin& p) {
    if (lua_gettop(L) != 1) luaL_error(L, "an input trace handle is the only argument");
    const auto value = *static_cast<const TraceValue*>(luaL_checkudata(L, 1, trace_type));
    if (value.owner != p.instance()) luaL_error(L, "input trace belongs to another plugin instance");
    return value;
}
}
struct InputTraceApi {
    static Plugin& plugin(lua_State* L) {
        auto& p = plugin_of(L);
        need(L, p, "skater.input_trace", "reskate.skater input tracing");
        if (p.services_.authority()) luaL_error(L, "input tracing is client phase only");
        return p;
    }
    static int request(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 0) luaL_error(L, "input_trace takes no arguments");
        const double now = p.services_.now_ms();
        if (now - p.input_trace_second_ >= 1000) { p.input_trace_second_ = now; p.input_traces_ = 0; }
        if (++p.input_traces_ > 4) return failure(L, "asked more than 4 times in a second");
        // A Lua allocation failure cannot leave a trace alive without a handle.
        auto* value = new (lua_newuserdata(L, sizeof(TraceValue))) TraceValue{p.instance(), {}};
        luaL_getmetatable(L, trace_type); lua_setmetatable(L, -2);
        input_trace::Reason reason{};
        if (!p.services_.game().input_trace_request(p.instance(), value->handle, reason)) {
            lua_pop(L, 1); return failure(L, input_trace::reason_name(reason));
        }
        if (!value->handle.sequence) { lua_pop(L, 1); return failure(L, "input trace handle unavailable"); }
        return 1;
    }
    static int state(lua_State* L) {
        auto& p = plugin(L); const auto value = handle(L, p); input_trace::Receipt r;
        if (!p.services_.game().input_trace_read(p.instance(), value.handle, r)) return failure(L, "input trace unavailable");
        if (r.handle.sequence != value.handle.sequence || r.record_count > r.records.size() ||
            r.expires_ms < r.requested_ms || r.expires_ms - r.requested_ms != 5000 ||
            std::string_view(input_trace::status_name(r.status)) == "invalid")
            return failure(L, "input trace receipt has invalid observations");
        for (std::size_t i = 0; i < r.record_count; ++i) {
            const auto& row = r.records[i];
            if (row.observed_ms < r.requested_ms || row.observed_ms >= r.expires_ms ||
                row.asset_token > input_trace::asset_token_capacity ||
                (row.lane != input_trace::Lane::interpreter && row.lane != input_trace::Lane::alternate))
                return failure(L, "input trace record has invalid observations");
        }
        lua_createtable(L, 0, 10);
        lua_pushstring(L, input_trace::status_name(r.status)); lua_setfield(L, -2, "status");
        boolean(L, "terminal", r.status != input_trace::Status::active);
        text(L, "sequence", r.handle.sequence); text(L, "requested_ms", r.requested_ms); text(L, "expires_ms", r.expires_ms);
        text(L, "seen", r.seen); text(L, "duplicates", r.duplicates); text(L, "dropped", r.dropped);
        text(L, "observer_busy_at_start", r.observer_busy_at_start); text(L, "observer_busy_total", r.observer_busy_total);
        lua_createtable(L, static_cast<int>(r.record_count), 0);
        for (std::size_t i = 0; i < r.record_count; ++i) {
            const auto& row = r.records[i]; lua_createtable(L, 0, 11);
            text(L, "observed_ms", row.observed_ms); number(L, "thread_id", row.thread_id);
            lua_pushstring(L, row.lane == input_trace::Lane::interpreter ? "interpreter" : "alternate"); lua_setfield(L, -2, "lane");
            number(L, "asset_token", row.asset_token);
            boolean(L, "condition_known", row.condition_known);
            if (row.condition_known) boolean(L, "condition", row.condition);
            boolean(L, "local_tuple_known", row.local_tuple_known);
            boolean(L, "container_matches_local", row.container_matches_local);
            boolean(L, "snapshot_stable", row.snapshot_stable);
            number(L, "issue", row.issue);
            lua_rawseti(L, -2, static_cast<int>(i + 1));
        }
        lua_setfield(L, -2, "records"); return 1;
    }
    static int stop(lua_State* L) {
        auto& p = plugin(L); const auto value = handle(L, p);
        const bool ok = p.services_.game().input_trace_stop(p.instance(), value.handle);
        lua_pushboolean(L, ok); if (ok) return 1;
        lua_pushstring(L, "input trace unavailable"); return 2;
    }
    static int acknowledge(lua_State* L) {
        auto& p = plugin(L); const auto value = handle(L, p);
        const bool ok = p.services_.game().input_trace_acknowledge(p.instance(), value.handle);
        lua_pushboolean(L, ok); if (ok) return 1;
        lua_pushstring(L, "input trace is active or unavailable"); return 2;
    }
};
void install_input_trace_api(Plugin&, lua_State* L) {
    luaL_newmetatable(L, trace_type);
    lua_pushstring(L, "locked"); lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true); lua_pop(L, 1);
    add_functions(L, "skater", {{"input_trace", InputTraceApi::request}, {"input_trace_state", InputTraceApi::state},
        {"input_trace_stop", InputTraceApi::stop}, {"input_trace_acknowledge", InputTraceApi::acknowledge}});
}
} // namespace dingosdk::plugins
