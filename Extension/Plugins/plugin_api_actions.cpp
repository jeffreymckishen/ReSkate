#include "plugin_api.h"
#include "lua.h"
#include "lualib.h"
#include <cstdint>
#include <cmath>
#include <new>
#include <string>
#include <string_view>

namespace dingosdk::plugins {
namespace {
constexpr char action_type[] = "reskate.skater.native_action";
constexpr char recovery_type[] = "reskate.skater.native_recovery";
struct ActionValue { std::uint64_t owner{}; skater_action::Handle handle{}; };
struct RecoveryValue { std::uint64_t owner{}; skater_recovery::Handle handle{}; };
int failure(lua_State* L, const char* why) { lua_pushnil(L); lua_pushstring(L, why); return 2; }
int result(lua_State* L, bool ok, const char* why) {
    lua_pushboolean(L, ok);
    if (ok) return 1;
    lua_pushstring(L, why); return 2;
}
void integer_text(lua_State* L, const char* field, std::uint64_t value) {
    const auto text = std::to_string(value);
    lua_pushlstring(L, text.data(), text.size()); lua_setfield(L, -2, field);
}
void number(lua_State* L, const char* field, std::uint32_t value) {
    lua_pushnumber(L, value); lua_setfield(L, -2, field);
}
void boolean(lua_State* L, const char* field, bool value) {
    lua_pushboolean(L, value); lua_setfield(L, -2, field);
}
ActionValue action(lua_State* L, Plugin& plugin) {
    const auto value = *static_cast<const ActionValue*>(luaL_checkudata(L, 1, action_type));
    if (value.owner != plugin.instance()) luaL_error(L, "native action belongs to another plugin instance");
    return value;
}
RecoveryValue recovery(lua_State* L, Plugin& plugin) {
    if (lua_gettop(L) != 1) luaL_error(L, "a recovery handle is the only argument");
    const auto value = *static_cast<const RecoveryValue*>(luaL_checkudata(L, 1, recovery_type));
    if (value.owner != plugin.instance()) luaL_error(L, "native recovery belongs to another plugin instance");
    return value;
}
void scalar(lua_State* L, const char* field, double value) { lua_pushnumber(L, value); lua_setfield(L, -2, field); }
}

struct NativeActionsApi {
    static Plugin& plugin(lua_State* L) {
        auto& p = plugin_of(L);
        need(L, p, "skater.control", "reskate.skater native actions");
        if (p.services_.authority()) luaL_error(L, "native actions are client phase only");
        return p;
    }
    static int request(lua_State* L) {
        auto& p = plugin(L);
        luaL_checktype(L, 1, LUA_TSTRING);
        std::size_t size{}; const char* text = luaL_checklstring(L, 1, &size);
        const std::string_view kind(text, size);
        if (kind != "board" && kind != "on_foot") luaL_argerror(L, 1, "a native action is board or on_foot");
        const double now = p.services_.now_ms();
        if (now - p.control_second_ >= 1000) { p.control_second_ = now; p.controls_ = 0; }
        if (++p.controls_ > 4) return failure(L, "asked more than 4 times in a second");
        // Allocate the Lua wrapper before enqueueing any native request.
        auto* value = new (lua_newuserdata(L, sizeof(ActionValue))) ActionValue{p.instance(), {}};
        luaL_getmetatable(L, action_type); lua_setmetatable(L, -2);
        skater_action::Reason reason{};
        if (!p.services_.game().native_action_request(p.instance(), kind == "board" ? skater_action::Kind::board : skater_action::Kind::on_foot,
                value->handle, reason)) {
            lua_pop(L, 1); return failure(L, skater_action::reason_name(reason));
        }
        if (!value->handle.sequence) { lua_pop(L, 1); return failure(L, "native action handle unavailable"); }
        return 1;
    }
    static int state(lua_State* L) {
        auto& p = plugin(L); const auto value = action(L, p); skater_action::Receipt receipt;
        if (!p.services_.game().native_action_read(p.instance(), value.handle, receipt))
            return failure(L, "native action receipt unavailable");
        if (receipt.handle.sequence != value.handle.sequence) return failure(L, "native action receipt changed");
        lua_createtable(L, 0, 16);
        lua_pushstring(L, receipt.kind == skater_action::Kind::board ? "board" : "on_foot"); lua_setfield(L, -2, "kind");
        lua_pushstring(L, skater_action::status_name(receipt.status)); lua_setfield(L, -2, "status");
        lua_pushstring(L, skater_action::reason_name(receipt.reason)); lua_setfield(L, -2, "reason");
        integer_text(L, "sequence", receipt.handle.sequence);
        integer_text(L, "requested_ms", receipt.requested_ms);
        if (receipt.offered_ms) integer_text(L, "offered_ms", receipt.offered_ms);
        if (receipt.observed_ms) integer_text(L, "observed_ms", receipt.observed_ms);
        if (receipt.original_known) number(L, "original_candidate", receipt.original_candidate);
        if (receipt.final_known) number(L, "final_candidate", receipt.final_candidate);
        if (receipt.committed_known) number(L, "committed_state", receipt.committed_state);
        if (receipt.ragdoll_known) boolean(L, "ragdoll", receipt.ragdoll);
        if (receipt.in_air_known) boolean(L, "in_air", receipt.in_air);
        boolean(L, "flag_restored", receipt.flag_restored);
        boolean(L, "quarantined", receipt.quarantined);
        boolean(L, "terminal", skater_action::terminal(receipt.status));
        return 1;
    }
    static int cancel(lua_State* L) {
        auto& p = plugin(L); const auto value = action(L, p);
        return result(L, p.services_.game().native_action_cancel(p.instance(), value.handle), "native action cannot be cancelled now");
    }
    static int acknowledge(lua_State* L) {
        auto& p = plugin(L); const auto value = action(L, p);
        return result(L, p.services_.game().native_action_acknowledge(p.instance(), value.handle), "native action is in flight, quarantined or unavailable");
    }
    static int recover(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 0) luaL_error(L, "recover takes no arguments");
        const double now = p.services_.now_ms();
        if (now - p.control_second_ >= 1000) { p.control_second_ = now; p.controls_ = 0; }
        if (++p.controls_ > 4) return failure(L, "asked more than 4 times in a second");
        // Lua allocation must finish before the backend can acquire authority.
        auto* value = new (lua_newuserdata(L, sizeof(RecoveryValue))) RecoveryValue{p.instance(), {}};
        luaL_getmetatable(L, recovery_type); lua_setmetatable(L, -2);
        skater_recovery::Reason reason{};
        if (!p.services_.game().native_recovery_request(p.instance(), value->handle, reason)) {
            lua_pop(L, 1); return failure(L, skater_recovery::reason_name(reason));
        }
        if (!value->handle.sequence) { lua_pop(L, 1); return failure(L, "native recovery handle unavailable"); }
        return 1;
    }
    static int recovery_state(lua_State* L) {
        auto& p = plugin(L); const auto value = recovery(L, p); skater_recovery::Receipt r;
        if (!p.services_.game().native_recovery_read(p.instance(), value.handle, r))
            return failure(L, "native recovery receipt unavailable");
        if (r.handle.sequence != value.handle.sequence) return failure(L, "native recovery receipt changed");
        if (std::string_view(skater_recovery::status_name(r.status)) == "invalid" ||
            std::string_view(skater_recovery::reason_name(r.reason)) == "invalid" ||
            r.native_true_calls > 1 || r.native_reset_calls > 64 ||
            (r.true_entered && (!r.true_serial || !std::isfinite(r.true_time) || r.true_time < 0)) ||
            (r.reset_false && (!r.reset_serial || !std::isfinite(r.reset_time) || r.reset_time < 0)) ||
            !std::isfinite(r.standing_seconds) || r.standing_seconds < 0 ||
            !std::isfinite(r.standing_required_seconds) || r.standing_required_seconds < 0)
            return failure(L, "native recovery receipt has invalid observations");
        lua_createtable(L, 0, 36);
        lua_pushstring(L, "get_up"); lua_setfield(L, -2, "kind");
        lua_pushstring(L, skater_recovery::status_name(r.status)); lua_setfield(L, -2, "status");
        lua_pushstring(L, skater_recovery::reason_name(r.reason)); lua_setfield(L, -2, "reason");
        integer_text(L, "sequence", r.handle.sequence); integer_text(L, "requested_ms", r.requested_ms);
        number(L, "native_true_calls", static_cast<std::uint32_t>(r.native_true_calls));
        number(L, "native_reset_calls", static_cast<std::uint32_t>(r.native_reset_calls));
        if (r.observed_ms) integer_text(L, "observed_ms", r.observed_ms);
        if (r.true_entered) {
            integer_text(L, "true_ms", r.true_ms); integer_text(L, "true_serial", r.true_serial); scalar(L, "true_time", r.true_time);
        }
        if (r.reset_false) {
            integer_text(L, "reset_ms", r.reset_ms); integer_text(L, "reset_serial", r.reset_serial); scalar(L, "reset_time", r.reset_time);
        }
        if (r.prior_known) boolean(L, "prior_value", r.prior_value);
        boolean(L, "true_entered", r.true_entered); boolean(L, "true_returned", r.true_returned);
        if (r.true_readback_known) boolean(L, "true_readback", r.true_readback);
        boolean(L, "reset_pending", r.reset_pending); boolean(L, "reset_entered", r.reset_entered);
        boolean(L, "reset_returned", r.reset_returned); boolean(L, "reset_readback_known", r.reset_readback_known);
        boolean(L, "reset_false", r.reset_false); boolean(L, "cleared_before_reset", r.cleared_before_reset);
        boolean(L, "unresolved", r.unresolved); boolean(L, "actor_retired", r.actor_retired);
        boolean(L, "quarantined", r.quarantined); boolean(L, "terminal", skater_recovery::terminal(r.status));
        number(L, "start_attempts", r.start_attempts); number(L, "cleanup_attempts", r.cleanup_attempts);
        if (r.state.known) number(L, "committed_state", r.state.value);
        if (r.state.ragdoll_known) boolean(L, "ragdoll", r.state.ragdoll);
        if (r.state.in_air_known) boolean(L, "in_air", r.state.in_air);
        boolean(L, "standing_observed", r.standing_observed); boolean(L, "stable_observed", r.stable_observed);
        number(L, "standing_samples", r.standing_samples); scalar(L, "standing_seconds", r.standing_seconds);
        scalar(L, "standing_required_seconds", r.standing_required_seconds);
        return 1;
    }
    static int recovery_cancel(lua_State* L) {
        auto& p = plugin(L); const auto value = recovery(L, p);
        return result(L, p.services_.game().native_recovery_cancel(p.instance(), value.handle), "native recovery cannot be cancelled now");
    }
    static int recovery_acknowledge(lua_State* L) {
        auto& p = plugin(L); const auto value = recovery(L, p);
        return result(L, p.services_.game().native_recovery_acknowledge(p.instance(), value.handle), "native recovery is in flight, quarantined or unavailable");
    }
};
void install_native_actions_api(Plugin&, lua_State* L) {
    luaL_newmetatable(L, action_type);
    lua_pushstring(L, "locked"); lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true); lua_pop(L, 1);
    luaL_newmetatable(L, recovery_type);
    lua_pushstring(L, "locked"); lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true); lua_pop(L, 1);
    add_functions(L, "skater", {{"action", NativeActionsApi::request}, {"action_state", NativeActionsApi::state},
        {"action_cancel", NativeActionsApi::cancel}, {"action_acknowledge", NativeActionsApi::acknowledge},
        {"recover", NativeActionsApi::recover}, {"recovery_state", NativeActionsApi::recovery_state},
        {"recovery_cancel", NativeActionsApi::recovery_cancel}, {"recovery_acknowledge", NativeActionsApi::recovery_acknowledge}});
}
} // namespace dingosdk::plugins
