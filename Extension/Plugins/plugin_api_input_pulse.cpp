#include "plugin_api.h"
#include "lua.h"
#include "lualib.h"
#include <cmath>
#include <new>
#include <string>
#include <string_view>

namespace dingosdk::plugins {
namespace {
constexpr char pulse_type[] = "reskate.input.pulse";
struct PulseValue {
    std::uint64_t owner{};
    game_input_pulse::Handle handle{};
    std::uint32_t user{};
    std::uint16_t button{};
};
int failure(lua_State* L, const char* why) { lua_pushnil(L); lua_pushstring(L, why); return 2; }
void text(lua_State* L, const char* key, std::uint64_t value) {
    const auto s = std::to_string(value);
    lua_pushlstring(L, s.data(), s.size()); lua_setfield(L, -2, key);
}
void boolean(lua_State* L, const char* key, bool value) { lua_pushboolean(L, value); lua_setfield(L, -2, key); }
void number(lua_State* L, const char* key, std::uint32_t value) { lua_pushnumber(L, value); lua_setfield(L, -2, key); }
std::uint32_t integer(lua_State* L, int index, double low, double high, const char* why) {
    luaL_checktype(L, index, LUA_TNUMBER);
    const double value = lua_tonumber(L, index);
    if (!std::isfinite(value) || std::floor(value) != value || value < low || value > high) luaL_argerror(L, index, why);
    return static_cast<std::uint32_t>(value);
}
std::uint16_t button(lua_State* L) {
    if (lua_type(L, 2) == LUA_TSTRING) {
        std::size_t size{}; const auto* value = luaL_checklstring(L, 2, &size);
        const std::string_view name(value, size);
        struct NamedButton { std::string_view name; std::uint16_t bit; };
        static constexpr NamedButton names[] = {
            {"up", 0x1}, {"down", 0x2}, {"left", 0x4}, {"right", 0x8}, {"start", 0x10}, {"back", 0x20},
            {"left_stick", 0x40}, {"right_stick", 0x80}, {"lb", 0x100}, {"rb", 0x200},
            {"a", 0x1000}, {"b", 0x2000}, {"x", 0x4000}, {"y", 0x8000}
        };
        for (const auto& item : names) if (item.name == name) return item.bit;
        luaL_argerror(L, 2, "a canonical XInput button name or one valid button bit");
    }
    const auto bit = static_cast<std::uint16_t>(integer(L, 2, 1, 65535, "one valid XInput button bit"));
    if (!game_input_pulse::valid_button(bit)) luaL_argerror(L, 2, "one valid XInput button bit");
    return bit;
}
PulseValue handle(lua_State* L, Plugin& plugin) {
    if (lua_gettop(L) != 1) luaL_error(L, "an input pulse handle is the only argument");
    const auto value = *static_cast<const PulseValue*>(luaL_checkudata(L, 1, pulse_type));
    if (value.owner != plugin.instance()) luaL_error(L, "input pulse belongs to another plugin instance");
    return value;
}
}

struct InputPulseApi {
    static Plugin& plugin(lua_State* L) {
        auto& p = plugin_of(L);
        need(L, p, "input.control", "reskate.input report pulses");
        if (p.services_.authority()) luaL_error(L, "input pulses are client phase only");
        return p;
    }
    static int request(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 2) luaL_error(L, "pulse takes a user slot and one button");
        const auto user = integer(L, 1, 0, 3, "an integral XInput user slot from 0 to 3");
        const auto bit = button(L);
        const double now = p.services_.now_ms();
        if (now - p.control_second_ >= 1000) { p.control_second_ = now; p.controls_ = 0; }
        if (++p.controls_ > 4) return failure(L, "asked more than 4 times in a second");
        // Allocate before enqueueing so VM allocation failure cannot strand native duty.
        auto* value = new (lua_newuserdata(L, sizeof(PulseValue))) PulseValue{p.instance(), {}, user, bit};
        luaL_getmetatable(L, pulse_type); lua_setmetatable(L, -2);
        game_input_pulse::Reason reason{};
        if (!p.services_.game().input_pulse_request(p.instance(), user, bit, value->handle, reason)) {
            lua_pop(L, 1); return failure(L, game_input_pulse::reason_name(reason));
        }
        if (!value->handle.sequence) { lua_pop(L, 1); return failure(L, "input pulse handle unavailable"); }
        return 1;
    }
    static int state(lua_State* L) {
        auto& p = plugin(L); const auto value = handle(L, p); game_input_pulse::Receipt r;
        if (!p.services_.game().input_pulse_read(p.instance(), value.handle, r)) return failure(L, "input pulse unavailable");
        if (r.handle != value.handle || r.user != value.user || r.button != value.button ||
            !game_input_pulse::valid_button(r.button) || r.expires_ms < r.requested_ms ||
            r.expires_ms - r.requested_ms != game_input_pulse::lifetime_ms || r.observed_ms < r.requested_ms ||
            r.press_publications > r.press_candidates || std::string_view(game_input_pulse::status_name(r.status)) == "invalid" ||
            std::string_view(game_input_pulse::reason_name(r.reason)) == "invalid" ||
            (r.first_rejection_mask & ~input_pulse::failure_bits) ||
            std::string_view(game_input_pulse::rejection_stage_name(r.first_rejection_stage)) == "invalid" ||
            std::string_view(actor_observation::phase_name(r.first_actor_observation.enter.phase)) == "invalid" ||
            std::string_view(actor_observation::phase_name(r.first_actor_observation.inspect.phase)) == "invalid" ||
            std::string_view(skater_action::reason_name(r.first_actor_observation.enter.reason)) == "invalid" ||
            std::string_view(skater_action::reason_name(r.first_actor_observation.inspect.reason)) == "invalid")
            return failure(L, "input pulse receipt has invalid observations");
        lua_createtable(L, 0, 48);
        lua_pushstring(L, game_input_pulse::status_name(r.status)); lua_setfield(L, -2, "status");
        lua_pushstring(L, game_input_pulse::reason_name(r.reason)); lua_setfield(L, -2, "reason");
        number(L, "first_rejection_mask", r.first_rejection_mask);
        lua_pushstring(L, game_input_pulse::rejection_stage_name(r.first_rejection_stage)); lua_setfield(L, -2, "first_rejection_stage");
        const auto& a = r.first_actor_observation;
        boolean(L, "first_actor_observation_known", a.known);
        boolean(L, "first_actor_owner_present", a.owner_present);
        boolean(L, "first_actor_call_active", a.call_active);
        boolean(L, "first_actor_inspect_attempted", a.inspect_attempted);
        boolean(L, "first_actor_inspect_succeeded", a.inspect_succeeded);
        boolean(L, "first_actor_equal", a.actor_equal);
        boolean(L, "first_actor_clock_attempted", a.clock_attempted);
        boolean(L, "first_actor_clock_known", a.clock_known);
        lua_pushstring(L, actor_observation::phase_name(a.enter.phase)); lua_setfield(L, -2, "first_actor_enter_phase");
        lua_pushstring(L, skater_action::reason_name(a.enter.reason)); lua_setfield(L, -2, "first_actor_enter_reason");
        lua_pushstring(L, actor_observation::phase_name(a.inspect.phase)); lua_setfield(L, -2, "first_actor_inspect_phase");
        lua_pushstring(L, skater_action::reason_name(a.inspect.reason)); lua_setfield(L, -2, "first_actor_inspect_reason");
        boolean(L, "terminal", game_input_pulse::terminal(r.status));
        lua_pushstring(L, "xinput"); lua_setfield(L, -2, "transport");
        lua_pushstring(L, "observed_stream"); lua_setfield(L, -2, "source_identity");
        lua_pushstring(L, "process_outer_xinput_buffer"); lua_setfield(L, -2, "publication_scope");
        lua_pushstring(L, "unobserved"); lua_setfield(L, -2, "consumption");
        lua_pushstring(L, "unobserved"); lua_setfield(L, -2, "semantic_completion");
        number(L, "user", r.user); number(L, "button", r.button);
        text(L, "sequence", r.handle.sequence); text(L, "requested_ms", r.requested_ms);
        text(L, "expires_ms", r.expires_ms); text(L, "observed_ms", r.observed_ms); text(L, "source_epoch", r.source_epoch);
        text(L, "press_candidates", r.press_candidates); text(L, "press_publications", r.press_publications);
        text(L, "neutral_publications", r.neutral_publications); text(L, "original_failures", r.original_failures);
        text(L, "contentions", r.contentions); text(L, "warmup_deferrals", r.warmup_deferrals);
        boolean(L, "report_debt", r.report_debt); boolean(L, "claim_released", r.claim_released);
        boolean(L, "actor_retired", r.actor_retired); boolean(L, "orphaned", r.orphaned); boolean(L, "quarantined", r.quarantined);
        boolean(L, "original_result_known", r.original_result_known);
        if (r.original_result_known) number(L, "original_result", r.original_result);
        return 1;
    }
    static int cancel(lua_State* L) {
        auto& p = plugin(L); const auto value = handle(L, p);
        const bool ok = p.services_.game().input_pulse_cancel(p.instance(), value.handle);
        lua_pushboolean(L, ok); if (ok) return 1;
        lua_pushstring(L, "input pulse is busy, terminal or unavailable"); return 2;
    }
    static int acknowledge(lua_State* L) {
        auto& p = plugin(L); const auto value = handle(L, p);
        const bool ok = p.services_.game().input_pulse_acknowledge(p.instance(), value.handle);
        lua_pushboolean(L, ok); if (ok) return 1;
        lua_pushstring(L, "input pulse duty or claim is unresolved, or handle unavailable"); return 2;
    }
};

void install_input_pulse_api(Plugin&, lua_State* L) {
    luaL_newmetatable(L, pulse_type);
    lua_pushstring(L, "locked"); lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true); lua_pop(L, 1);
    add_functions(L, "input", {{"pulse", InputPulseApi::request}, {"pulse_state", InputPulseApi::state},
        {"pulse_cancel", InputPulseApi::cancel}, {"pulse_acknowledge", InputPulseApi::acknowledge}});
}
}
