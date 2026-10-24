#include "plugin_api.h"
#include "lua.h"
#include "lualib.h"
#include <cmath>
#include <limits>
#include <new>
#include <string>
#include <string_view>

namespace dingosdk::plugins {
namespace {
namespace lease = input_lease;
namespace capture = input_lease_capture;
constexpr char lease_type[] = "reskate.input.lease";
constexpr char epoch_type[] = "reskate.input.lease.epoch";
struct LeaseValue {
    std::uint64_t owner{};
    lease::Handle handle{};
    std::uint32_t user{};
    capture::Key admitted_capture{};
};
// Only a sample returned to this VM can renew its own selected reader. Mutable
// Lua fields and caller-supplied source epochs never become native facts.
struct EpochValue { LeaseValue lease{}; input_lease::Snapshot sample{}; };
int failure(lua_State* L, const char* why) { lua_pushnil(L); lua_pushstring(L, why); return 2; }
const char* refusal(lease::Reason reason) {
    const auto* name = lease::reason_name(reason);
    return reason == lease::Reason::none || std::string_view(name) == "invalid" ? "input lease unavailable" : name;
}
int failure(lua_State* L, lease::Reason reason) { return failure(L, refusal(reason)); }
int result(lua_State* L, bool ok, lease::Reason reason) {
    lua_pushboolean(L, ok); if (ok) return 1;
    lua_pushstring(L, refusal(reason)); return 2;
}
void text(lua_State* L, const char* key, std::uint64_t value) {
    const auto value_text = std::to_string(value);
    lua_pushlstring(L, value_text.data(), value_text.size()); lua_setfield(L, -2, key);
}
void boolean(lua_State* L, const char* key, bool value) { lua_pushboolean(L, value); lua_setfield(L, -2, key); }
void number(lua_State* L, const char* key, double value) { lua_pushnumber(L, value); lua_setfield(L, -2, key); }
void metadata(lua_State* L) {
    lua_pushstring(L, "xinput"); lua_setfield(L, -2, "transport");
    lua_pushstring(L, "observed_stream"); lua_setfield(L, -2, "source_identity");
    lua_pushstring(L, "unobserved"); lua_setfield(L, -2, "physical_device_identity");
    lua_pushstring(L, "observe"); lua_setfield(L, -2, "mode");
    boolean(L, "capturing", false); boolean(L, "report_debt", false);
}
void metatable(lua_State* L, const char* name) {
    luaL_newmetatable(L, name);
    lua_pushstring(L, "locked"); lua_setfield(L, -2, "__metatable");
    lua_setreadonly(L, -1, true); lua_pop(L, 1);
}
template<class T> T* opaque(lua_State* L, const char* name) {
    auto* value = new (lua_newuserdata(L, sizeof(T))) T{};
    luaL_getmetatable(L, name); lua_setmetatable(L, -2); return value;
}
LeaseValue handle(lua_State* L, Plugin& p, int index) {
    const auto value = *static_cast<const LeaseValue*>(luaL_checkudata(L, index, lease_type));
    if (value.owner != p.instance()) luaL_error(L, "input lease belongs to another plugin instance");
    return value;
}
bool valid(const LeaseValue& value, const lease::Snapshot& sample) {
    return sample.handle == value.handle && sample.user == value.user && sample.user <= 3 &&
        sample.source_epoch && sample.observation_serial && sample.context_generation && sample.observed_ms &&
        sample.observed_ms <= std::numeric_limits<std::uint64_t>::max() - lease::lifetime_ms;
}
bool valid(const LeaseValue& value, const lease::Receipt& receipt) {
    if (receipt.handle != value.handle || receipt.user != value.user || receipt.user > 3 ||
        !receipt.source_epoch || !receipt.context_generation || !receipt.requested_ms ||
        receipt.requested_ms > std::numeric_limits<std::uint64_t>::max() - lease::lifetime_ms ||
        receipt.expires_ms < receipt.requested_ms || receipt.expires_ms - receipt.requested_ms < lease::lifetime_ms ||
        (!receipt.last_observation && (receipt.observed_ms || receipt.status == lease::Status::active)) ||
        (receipt.last_observation && receipt.observed_ms < receipt.requested_ms) ||
        std::string_view(lease::status_name(receipt.status)) == "invalid" ||
        std::string_view(lease::reason_name(receipt.reason)) == "invalid" ||
        (receipt.source_released && (!lease::terminal(receipt.status) || receipt.capture_reserved)) ||
        (lease::terminal(receipt.status) && !receipt.source_released && !receipt.capture_reserved) ||
        (receipt.capture_reserved && value.admitted_capture != capture::Key{value.owner, value.handle.sequence,
            receipt.source_epoch, receipt.context_generation, receipt.user})) return false;
    return receipt.status != lease::Status::active || (receipt.last_observation && receipt.observed_ms < receipt.expires_ms);
}
const char* capture_phase(capture::Phase phase) {
    switch (phase) {
    case capture::Phase::idle: return "idle";
    case capture::Phase::waiting_neutral: return "waiting_neutral";
    case capture::Phase::capturing: return "capturing";
    case capture::Phase::releasing: return "releasing";
    case capture::Phase::complete: return "complete";
    }
    return "invalid";
}
const char* capture_reason(capture::Reason reason) {
    switch (reason) {
    case capture::Reason::none: return "none";
    case capture::Reason::unavailable: return "unavailable";
    case capture::Reason::invalid_key: return "invalid_key";
    case capture::Reason::busy: return "busy";
    case capture::Reason::exhausted: return "exhausted";
    case capture::Reason::source_changed: return "source_changed";
    case capture::Reason::source_stale: return "source_stale";
    case capture::Reason::clock_regressed: return "clock_regressed";
    case capture::Reason::authority_lost: return "authority_lost";
    case capture::Reason::context_changed: return "context_changed";
    case capture::Reason::deadline: return "deadline";
    case capture::Reason::focus_lost: return "focus_lost";
    case capture::Reason::gameplay_inactive: return "gameplay_inactive";
    case capture::Reason::menu_open: return "menu_open";
    case capture::Reason::paused: return "paused";
    case capture::Reason::interference: return "interference";
    case capture::Reason::cancelled: return "cancelled";
    case capture::Reason::publication_unconfirmed: return "publication_unconfirmed";
    }
    return "invalid";
}
bool valid(const LeaseValue& value, const capture::Receipt& receipt) {
    const auto& key = receipt.key;
    if (!value.admitted_capture.owner || key != value.admitted_capture ||
        key.owner != value.owner || key.lease_sequence != value.handle.sequence || key.user != value.user || key.user > 3 ||
        !key.source_epoch || !key.context_generation || !receipt.generation || !receipt.revision || !receipt.expires_ms ||
        receipt.phase == capture::Phase::idle || std::string_view(capture_phase(receipt.phase)) == "invalid" ||
        std::string_view(capture_reason(receipt.reason)) == "invalid" || receipt.neutral_releases > receipt.publications)
        return false;
    switch (receipt.phase) {
    case capture::Phase::waiting_neutral:
        return !receipt.debt && !receipt.publications && !receipt.neutral_releases && !receipt.quarantined;
    case capture::Phase::capturing: return receipt.debt && receipt.publications && !receipt.quarantined;
    case capture::Phase::releasing: return receipt.debt;
    case capture::Phase::complete: return !receipt.debt;
    case capture::Phase::idle: return false;
    }
    return false;
}
void capture_metadata(lua_State* L, const capture::Receipt& receipt) {
    metadata(L);
    lua_pushstring(L, "capture"); lua_setfield(L, -2, "mode");
    lua_pushstring(L, "selected_observed_xinput_stream"); lua_setfield(L, -2, "capture_scope");
    lua_pushstring(L, "process_outer_xinput_buffer"); lua_setfield(L, -2, "publication_scope");
    lua_pushstring(L, "unobserved"); lua_setfield(L, -2, "consumption");
    lua_pushstring(L, "unobserved"); lua_setfield(L, -2, "semantic_completion");
    boolean(L, "capturing", receipt.phase == capture::Phase::capturing);
    boolean(L, "report_debt", receipt.debt);
}
double stick(std::int16_t value) {
    // Preserve both endpoints and neutral without adding game or feature policy.
    return static_cast<double>(value) / (value < 0 ? 32768.0 : 32767.0);
}
void pad(lua_State* L, const lease::Pad& value) {
    lua_createtable(L, 0, 8);
    number(L, "left_x", stick(value.left_x)); number(L, "left_y", stick(value.left_y));
    number(L, "right_x", stick(value.right_x)); number(L, "right_y", stick(value.right_y));
    number(L, "left_trigger", static_cast<double>(value.left_trigger) / 255.0);
    number(L, "right_trigger", static_cast<double>(value.right_trigger) / 255.0);
    boolean(L, "playstation", false);
    lua_createtable(L, 0, 14);
    struct Button { const char* name; std::uint16_t bit; };
    static constexpr Button names[] = {
        {"up", 0x1}, {"down", 0x2}, {"left", 0x4}, {"right", 0x8}, {"start", 0x10}, {"back", 0x20},
        {"left_stick", 0x40}, {"right_stick", 0x80}, {"lb", 0x100}, {"rb", 0x200},
        {"a", 0x1000}, {"b", 0x2000}, {"x", 0x4000}, {"y", 0x8000}
    };
    for (const auto& item : names) boolean(L, item.name, (value.buttons & item.bit) != 0);
    lua_setfield(L, -2, "buttons");
}
}

struct InputLeaseApi {
    static Plugin& plugin(lua_State* L, bool capturing = false) {
        auto& p = plugin_of(L);
        need(L, p, "input.lease", "reskate.input source leases");
        if (capturing) need(L, p, "input.capture", "reskate.input selected-stream capture");
        if (p.services_.authority()) luaL_error(L, "input leases are client phase only");
        return p;
    }
    static int request(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 1) luaL_error(L, "lease takes one XInput user slot");
        luaL_checktype(L, 1, LUA_TNUMBER);
        const double selected = lua_tonumber(L, 1);
        if (!std::isfinite(selected) || std::floor(selected) != selected || selected < 0 || selected > 3)
            luaL_argerror(L, 1, "an integral XInput user slot from 0 to 3");
        const auto user = static_cast<std::uint32_t>(selected);
        const double now = p.services_.now_ms();
        if (now - p.control_second_ >= 1000) { p.control_second_ = now; p.controls_ = 0; }
        if (++p.controls_ > 4) return failure(L, "asked more than 4 times in a second");
        // Allocate the only owning Lua handle before asking the backend to reserve.
        auto* value = opaque<LeaseValue>(L, lease_type);
        value->owner = p.instance(); value->user = user;
        lease::Reason reason{};
        if (!p.services_.game().input_lease_request(p.instance(), user, value->handle, reason)) {
            lua_pop(L, 1); return failure(L, reason);
        }
        if (!value->handle.sequence) { lua_pop(L, 1); return failure(L, "input lease handle unavailable"); }
        return 1;
    }
    static int read(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 1) luaL_error(L, "an input lease handle is the only argument");
        const auto value = handle(L, p, 1); lease::Snapshot sample; lease::Reason reason{};
        if (!p.services_.game().input_lease_read(p.instance(), value.handle, sample, reason)) return failure(L, reason);
        if (!valid(value, sample)) return failure(L, "input lease sample has invalid observations");
        lua_createtable(L, 0, 16); metadata(L);
        opaque<EpochValue>(L, epoch_type)->lease = value;
        auto* epoch = static_cast<EpochValue*>(lua_touserdata(L, -1)); epoch->sample = sample;
        lua_setfield(L, -2, "epoch");
        text(L, "sequence", sample.handle.sequence); text(L, "source_epoch", sample.source_epoch);
        text(L, "observation_serial", sample.observation_serial); text(L, "observed_ms", sample.observed_ms);
        text(L, "context_generation", sample.context_generation);
        number(L, "user", sample.user); number(L, "packet", sample.packet);
        pad(L, sample.pad); lua_setfield(L, -2, "pad");
        return 1;
    }
    static int renew(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 2) luaL_error(L, "lease_renew takes its handle and an observed sample epoch");
        const auto value = handle(L, p, 1);
        const auto epoch = *static_cast<const EpochValue*>(luaL_checkudata(L, 2, epoch_type));
        if (epoch.lease.owner != p.instance() || epoch.lease.handle != value.handle || epoch.lease.user != value.user)
            luaL_error(L, "input lease epoch belongs to another lease or plugin instance");
        if (!valid(value, epoch.sample)) luaL_error(L, "input lease epoch has invalid observations");
        lease::Reason reason{};
        const bool ok = p.services_.game().input_lease_renew(p.instance(), value.handle, epoch.sample, reason);
        return result(L, ok, reason);
    }
    static int release(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 1) luaL_error(L, "an input lease handle is the only argument");
        const auto value = handle(L, p, 1); lease::Reason reason{};
        const bool ok = p.services_.game().input_lease_release(p.instance(), value.handle, reason);
        return result(L, ok, reason);
    }
    static int state(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 1) luaL_error(L, "an input lease handle is the only argument");
        const auto value = handle(L, p, 1); lease::Receipt receipt; lease::Reason reason{};
        if (!p.services_.game().input_lease_state(p.instance(), value.handle, receipt, reason)) return failure(L, reason);
        if (!valid(value, receipt)) return failure(L, "input lease receipt has invalid observations");
        lua_createtable(L, 0, 22); metadata(L);
        // Observation itself has no report duty. A separate capture can still
        // reserve its source; lease_capture_state reports that capture's debt.
        boolean(L, "capture_reserved", receipt.capture_reserved);
        lua_pushstring(L, lease::status_name(receipt.status)); lua_setfield(L, -2, "status");
        lua_pushstring(L, lease::reason_name(receipt.reason)); lua_setfield(L, -2, "reason");
        boolean(L, "terminal", lease::terminal(receipt.status));
        text(L, "sequence", receipt.handle.sequence); number(L, "user", receipt.user);
        text(L, "source_epoch", receipt.source_epoch); text(L, "context_generation", receipt.context_generation);
        text(L, "requested_ms", receipt.requested_ms); text(L, "expires_ms", receipt.expires_ms);
        text(L, "observed_ms", receipt.observed_ms); text(L, "last_observation", receipt.last_observation);
        text(L, "renewals", receipt.renewals);
        boolean(L, "source_released", receipt.source_released); boolean(L, "orphaned", receipt.orphaned);
        return 1;
    }
    static int acknowledge(lua_State* L) {
        auto& p = plugin(L);
        if (lua_gettop(L) != 1) luaL_error(L, "an input lease handle is the only argument");
        const auto value = handle(L, p, 1); lease::Reason reason{};
        const bool ok = p.services_.game().input_lease_acknowledge(p.instance(), value.handle, reason);
        return result(L, ok, reason);
    }
    static int capture_request(lua_State* L) {
        auto& p = plugin(L, true);
        if (lua_gettop(L) != 2) luaL_error(L, "lease_capture takes its handle and an observed sample epoch");
        const auto value = handle(L, p, 1);
        const auto epoch = *static_cast<const EpochValue*>(luaL_checkudata(L, 2, epoch_type));
        if (epoch.lease.owner != p.instance() || epoch.lease.handle != value.handle || epoch.lease.user != value.user)
            luaL_error(L, "input lease epoch belongs to another lease or plugin instance");
        if (!valid(value, epoch.sample)) luaL_error(L, "input lease epoch has invalid observations");
        capture::Reason reason{};
        if (!p.services_.game().input_lease_capture_request(p.instance(), value.handle, epoch.sample, reason)) {
            lua_pushboolean(L, false);
            const auto* why = capture_reason(reason);
            lua_pushstring(L, reason == capture::Reason::none || std::string_view(why) == "invalid" ? "input lease capture unavailable" : why);
            return 2;
        }
        // Keep receipt admission tied to the exact immutable observation that
        // native code accepted, even after the passive lease has been released.
        auto* held = static_cast<LeaseValue*>(lua_touserdata(L, 1));
        held->admitted_capture = {p.instance(), value.handle.sequence, epoch.sample.source_epoch,
            epoch.sample.context_generation, value.user};
        lua_pushboolean(L, true); return 1;
    }
    static int capture_state(lua_State* L) {
        auto& p = plugin(L, true);
        if (lua_gettop(L) != 1) luaL_error(L, "an input lease handle is the only argument");
        const auto value = handle(L, p, 1);
        if (!value.admitted_capture.owner) return failure(L, "input lease capture unavailable");
        capture::Receipt receipt;
        if (!p.services_.game().input_lease_capture_state(p.instance(), value.handle, receipt))
            return failure(L, "input lease capture unavailable");
        if (!valid(value, receipt)) return failure(L, "input lease capture receipt has invalid observations");
        lua_createtable(L, 0, 26); capture_metadata(L, receipt);
        lua_pushstring(L, capture_phase(receipt.phase)); lua_setfield(L, -2, "phase");
        lua_pushstring(L, capture_reason(receipt.reason)); lua_setfield(L, -2, "reason");
        boolean(L, "terminal", receipt.phase == capture::Phase::complete);
        boolean(L, "quarantined", receipt.quarantined);
        text(L, "sequence", receipt.key.lease_sequence); number(L, "user", receipt.key.user);
        text(L, "source_epoch", receipt.key.source_epoch); text(L, "context_generation", receipt.key.context_generation);
        text(L, "generation", receipt.generation); text(L, "revision", receipt.revision);
        text(L, "expires_ms", receipt.expires_ms); text(L, "publications", receipt.publications);
        text(L, "neutral_releases", receipt.neutral_releases);
        return 1;
    }
    static int capture_release(lua_State* L) {
        auto& p = plugin(L, true);
        if (lua_gettop(L) != 1) luaL_error(L, "an input lease handle is the only argument");
        const auto value = handle(L, p, 1);
        const bool ok = p.services_.game().input_lease_capture_release(p.instance(), value.handle);
        lua_pushboolean(L, ok); if (ok) return 1;
        lua_pushstring(L, "input lease capture unavailable or already released"); return 2;
    }
    static int capture_acknowledge(lua_State* L) {
        auto& p = plugin(L, true);
        if (lua_gettop(L) != 1) luaL_error(L, "an input lease handle is the only argument");
        const auto value = handle(L, p, 1);
        const bool ok = p.services_.game().input_lease_capture_acknowledge(p.instance(), value.handle);
        lua_pushboolean(L, ok);
        if (ok) {
            static_cast<LeaseValue*>(lua_touserdata(L, 1))->admitted_capture = {};
            return 1;
        }
        lua_pushstring(L, "input lease capture report duty is unresolved or unavailable"); return 2;
    }
};

void install_input_lease_api(Plugin&, lua_State* L) {
    metatable(L, lease_type); metatable(L, epoch_type);
    add_functions(L, "input", {{"lease", InputLeaseApi::request}, {"lease_read", InputLeaseApi::read},
        {"lease_renew", InputLeaseApi::renew}, {"lease_release", InputLeaseApi::release},
        {"lease_state", InputLeaseApi::state}, {"lease_acknowledge", InputLeaseApi::acknowledge},
        {"lease_capture", InputLeaseApi::capture_request}, {"lease_capture_state", InputLeaseApi::capture_state},
        {"lease_release_capture", InputLeaseApi::capture_release}, {"lease_acknowledge_capture", InputLeaseApi::capture_acknowledge}});
}
}
