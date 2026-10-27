// Runs one BMX plugin Lua suite on the vendored Luau. Modules are compiled from text the way
// Extension/Plugins/plugin_vm.cpp compiles them (optimization and debug level 1, standard libraries
// sandboxed), but this is not the plugin Host: there is no reskate API, no permission, no call or
// tick time limit, no multiplayer and no game. A suite passes only when its run() returns whole,
// positive cases and assertions counts; a failed assert reaches here with its message and stack.
// --stage-qualified-ride builds the test-only copy the Ride suites need, and --stage-regression checks
// that staging against a stand-in plugin. They are the only modes that write: the first only into the
// copy folder it is given, the second only inside a scratch folder that must not exist yet.
#include "Engine/Core/Json/json.h"
#include "lua.h"
#include "luacode.h"
#include "lualib.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <Windows.h>
#endif

namespace {
// Far above any BMX module; it only stops a runaway file from being read whole.
constexpr std::uintmax_t most_module_bytes = 4u << 20;
// A loose bound on modules loading at once. A loop through require is refused by name before this.
constexpr std::size_t most_nested_loads = 32;

// Test-only conversion mirrors Extension/Plugins/plugin_api.cpp::lua_to_json.
// The value model and compact/pretty bytes below use the production Json::dump.
// This is not a permissioned reskate API or plugin Host execution.
using dingosdk::Json;

// What turning Lua into JSON may cost outside the VM's own heap.
struct Budget {
    std::size_t values = 1u << 20;
    std::size_t bytes = 16u << 20;
    void spend(std::size_t count, std::size_t size) {
        if (count > values || size > bytes) throw std::runtime_error("the value is too large to turn into JSON");
        values -= count;
        bytes -= size;
    }
};

Json to_json(lua_State* L, int index, int depth, Budget& budget) {
    if (depth > 32) throw std::runtime_error("tables nested deeper than 32 cannot be turned into JSON");
    index = lua_absindex(L, index);
    budget.spend(1, 0);
    switch (lua_type(L, index)) {
    case LUA_TNIL: return nullptr;
    case LUA_TBOOLEAN: return lua_toboolean(L, index) != 0;
    case LUA_TNUMBER: {
        const double value = lua_tonumber(L, index);
        if (!std::isfinite(value)) throw std::runtime_error("JSON has no NaN or infinity");
        if (value == std::floor(value) && std::fabs(value) <= 9007199254740992.0) return static_cast<std::int64_t>(value);
        return value;
    }
    case LUA_TSTRING: {
        std::size_t length = 0;
        const char* text = lua_tolstring(L, index, &length);
        budget.spend(0, length);
        return std::string(text, length);
    }
    case LUA_TVECTOR: { // a position: [x, y, z]
        const float* v = lua_tovector(L, index);
        if (!std::isfinite(v[0]) || !std::isfinite(v[1]) || !std::isfinite(v[2])) throw std::runtime_error("JSON has no NaN or infinity");
        budget.spend(3, 0);
        return Json::array({static_cast<double>(v[0]), static_cast<double>(v[1]), static_cast<double>(v[2])});
    }
    case LUA_TTABLE: {
        luaL_checkstack(L, 4, "tables nested too deep");
        const int length = lua_objlen(L, index);
        bool list = length > 0;
        int count = 0;
        lua_pushnil(L);
        while (lua_next(L, index)) {
            ++count;
            if (lua_type(L, -2) != LUA_TNUMBER) list = false;
            else {
                const double key = lua_tonumber(L, -2);
                if (key != std::floor(key) || key < 1 || key > length) list = false;
            }
            lua_pop(L, 1);
        }
        if (list && count == length) {
            auto result = Json::array();
            for (int i = 1; i <= length; ++i) {
                lua_rawgeti(L, index, i);
                result.push_back(to_json(L, -1, depth + 1, budget));
                lua_pop(L, 1);
            }
            return result;
        }
        auto result = Json::object();
        lua_pushnil(L);
        while (lua_next(L, index)) {
            if (lua_type(L, -2) != LUA_TSTRING)
                throw std::runtime_error("only a list (keys 1 to n) or a table with string keys can be turned into JSON");
            std::size_t size = 0;
            const char* key = lua_tolstring(L, -2, &size);
            budget.spend(0, size);
            result[std::string_view(key, size)] = to_json(L, -1, depth + 1, budget);
            lua_pop(L, 1);
        }
        return result;
    }
    default:
        throw std::runtime_error(std::string("a ") + lua_typename(L, lua_type(L, index)) + " cannot be turned into JSON");
    }
}

int encode_json(lua_State* state) {
    luaL_checkany(state, 1);
    Budget budget;
    const auto text = to_json(state, 1, 0, budget).dump(lua_toboolean(state, 2) ? 2 : -1);
    lua_pushlstring(state, text.data(), text.size());
    return 1;
}

bool module_character(char value) {
    return (value >= 'a' && value <= 'z') || (value >= 'A' && value <= 'Z') || (value >= '0' && value <= '9') ||
        value == '_' || value == '-';
}

// No separators, dots or drive letters can appear, so a name can only mean a file in the folder.
bool valid_module_name(std::string_view name) {
    return !name.empty() && name.size() <= 128 && std::all_of(name.begin(), name.end(), module_character);
}

// Added where the error is raised, while the failing frames are still on the stack.
int traceback(lua_State* state) {
    std::string text = lua_isstring(state, 1) ? lua_tostring(state, 1) : "an error that is not a string";
    if (const char* trace = lua_debugtrace(state); trace && *trace) {
        text += "\n";
        text += trace;
    }
    lua_pushlstring(state, text.data(), text.size());
    return 1;
}

// Text only: the bytecode the VM runs is always this compiler's own, as in the plugin VM. On
// failure the message is left on the stack in place of the function.
bool compile(lua_State* state, std::string_view source, const std::string& chunk) {
    lua_CompileOptions options{};
    options.optimizationLevel = 1;
    options.debugLevel = 1;
    std::size_t bytes = 0;
    const std::unique_ptr<char, decltype(&std::free)> bytecode(
        luau_compile(source.data(), source.size(), &options, &bytes), &std::free);
    if (!bytecode) {
        lua_pushstring(state, "it could not be compiled");
        return false;
    }
    return luau_load(state, chunk.c_str(), bytecode.get(), bytes, 0) == 0;
}

std::filesystem::path open_folder(const std::filesystem::path& folder) {
    std::error_code code;
    auto root = std::filesystem::canonical(folder, code);
    if (code || !std::filesystem::is_directory(root, code))
        throw std::runtime_error("the folder does not exist: " + folder.string());
    return root;
}

// Bytes as they are on disk: no line-ending translation, so a copy can differ only where meant to.
std::string read_text(const std::filesystem::path& file, std::string& problem) {
    std::error_code code;
    const auto size = std::filesystem::file_size(file, code);
    if (code || size > most_module_bytes) {
        problem = file.generic_string() + " is unreadable or over the runner's 4 MiB limit";
        return {};
    }
    std::ifstream stream(file, std::ios::binary);
    std::string text{std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>()};
    if (!stream.good() && !stream.eof()) problem = file.generic_string() + " could not be read";
    return text;
}

bool is_lua_file(const std::filesystem::directory_entry& entry) {
    return entry.is_regular_file() && entry.path().extension() == ".lua";
}

bool within(const std::filesystem::path& folder, const std::filesystem::path& candidate) {
    auto child = candidate.begin();
    for (const auto& part : folder) {
        if (child == candidate.end()) return false;
#ifdef _WIN32
        if (CompareStringOrdinal(part.c_str(), -1, child->c_str(), -1, TRUE) != CSTR_EQUAL) return false;
#else
        if (part != *child) return false;
#endif
        ++child;
    }
    return true;
}

// Check the supplied spelling before canonicalization hides a junction or symlink ancestor.
void refuse_reparse_path(const std::filesystem::path& path) {
    namespace fs = std::filesystem;
    const auto absolute = fs::absolute(path);
    const auto check = [](const fs::path& part) {
#ifdef _WIN32
        const auto attributes = GetFileAttributesW(part.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) {
            const auto error = GetLastError();
            if (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND) return;
            throw std::runtime_error("could not inspect staging path: " + part.generic_string());
        }
        if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
#else
        std::error_code code;
        const auto status = fs::symlink_status(part, code);
        if (code == std::errc::no_such_file_or_directory) return;
        if (code) throw std::runtime_error("could not inspect staging path: " + part.generic_string());
        if (fs::is_symlink(status))
#endif
            throw std::runtime_error("staging refuses a reparse or symlink path: " + part.generic_string());
    };
    auto part = absolute.root_path();
    check(part);
    for (const auto& component : absolute.relative_path()) {
        part /= component;
        check(part);
    }
}

bool stage_module_name(const std::filesystem::path& name) {
    return name == name.filename() && name.extension() == ".lua" && valid_module_name(name.stem().string());
}

// Canonical spelling alone need not expand every Windows directory alias (for example 8.3 names).
bool has_directory_ancestor(const std::filesystem::path& path, const std::filesystem::path& directory) {
    namespace fs = std::filesystem;
    for (auto part = path; !part.empty();) {
        if (fs::exists(part) && fs::equivalent(part, directory)) return true;
        const auto parent = part.parent_path();
        if (parent == part) break;
        part = parent;
    }
    return false;
}

// The copy the qualified Ride suites run against, made the way
// Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc makes it in memory: every plugin module
// byte for byte, plus ride_runtime_qualified_fixture.lua, which is ride_runtime.lua with its one
// inactive gate flipped, plus an optional qualified Contact copy for the category-lane suites and an
// optional qualified mounted_pose copy for its suite. Optional force_stage copies use synthetic
// stage/cap literals for policy tests. No fixture may exist in the plugin itself; each
// is refused there.
// A rerun owns only the manifest's exact file set; a fixture filename alone proves no ownership.
void stage_qualified_ride(const std::filesystem::path& plugin_folder, const std::filesystem::path& copy_folder) {
    namespace fs = std::filesystem;
    refuse_reparse_path(plugin_folder);
    refuse_reparse_path(copy_folder);
    const auto source = open_folder(plugin_folder);
    const fs::path fixture = "ride_runtime_qualified_fixture.lua";
    const fs::path main_fixture = "main_score_entry_fixture.lua";
    const fs::path category_fixture = "contact_runtime_category_qualified_fixture.lua";
    const fs::path pose_fixture = "mounted_pose_qualified_fixture.lua";
    const fs::path force_support_fixture = "force_stage_support_fixture.lua";
    const fs::path force_pedal_fixture = "force_stage_pedal_fixture.lua";
    const fs::path force_support_uncapped_fixture = "force_stage_support_uncapped_fixture.lua";
    const fs::path force_pedal_uncapped_fixture = "force_stage_pedal_uncapped_fixture.lua";
    const fs::path force_low_cap_fixture = "force_stage_low_cap_fixture.lua";
    const fs::path force_invalid_fixture = "force_stage_invalid_fixture.lua";
    const fs::path force_support_torque_fixture = "force_stage_support_torque_fixture.lua";
    const fs::path force_pedal_torque_fixture = "force_stage_pedal_torque_fixture.lua";
    const fs::path force_low_torque_fixture = "force_stage_low_torque_fixture.lua";
    const fs::path force_torque_zero_fixture = "force_stage_torque_zero_fixture.lua";
    const fs::path force_torque_negative_fixture = "force_stage_torque_negative_fixture.lua";
    const fs::path force_torque_infinite_fixture = "force_stage_torque_infinite_fixture.lua";
    const fs::path force_torque_nan_fixture = "force_stage_torque_nan_fixture.lua";
    const fs::path force_torque_string_fixture = "force_stage_torque_string_fixture.lua";
    const fs::path force_torque_boolean_fixture = "force_stage_torque_boolean_fixture.lua";
    const fs::path force_torque_excess_fixture = "force_stage_torque_excess_fixture.lua";
    const fs::path force_ride_fixture = "force_stage_ride_fixture.lua";
    const fs::path force_ride_uncapped_fixture = "force_stage_ride_uncapped_fixture.lua";
    const fs::path force_ride_low_force_fixture = "force_stage_ride_low_force_fixture.lua";
    const fs::path force_ride_low_torque_fixture = "force_stage_ride_low_torque_fixture.lua";
    const fs::path force_hop_fixture = "force_stage_hop_fixture.lua";
    const fs::path force_hop_uncapped_fixture = "force_stage_hop_uncapped_fixture.lua";
    const fs::path force_hop_invalid_vertical_fixture = "force_stage_hop_invalid_vertical_fixture.lua";
    const fs::path force_hop_low_vertical_fixture = "force_stage_hop_low_vertical_fixture.lua";
    const fs::path floor_fixture = "bike_spawn_floor_qualified_fixture.lua";
    const fs::path follow_fixture = "bike_runtime_core_provisional_follow_fixture.lua";
    const fs::path renewal_fixture = "bike_runtime_core_follow_renewal_fixture.lua";
    const fs::path lead_fixture = "bike_runtime_core_follow_lead_fixture.lua";
    const fs::path guard_fixture = "bike_runtime_core_ride_guard_fixture.lua";
    const fs::path core_pose_fixture = "bike_runtime_core_mounted_pose_fixture.lua";
    const fs::path manifest = ".bmx-qualified-ride-files-v1";
    constexpr std::string_view manifest_header = "bmx-qualified-ride-files-v1";
    for (const auto& planted : {fixture, main_fixture, category_fixture, pose_fixture, force_support_fixture, force_pedal_fixture,
             force_support_uncapped_fixture, force_pedal_uncapped_fixture, force_low_cap_fixture, force_invalid_fixture,
             force_support_torque_fixture, force_pedal_torque_fixture, force_low_torque_fixture,
             force_torque_zero_fixture, force_torque_negative_fixture, force_torque_infinite_fixture,
             force_torque_nan_fixture, force_torque_string_fixture, force_torque_boolean_fixture, force_torque_excess_fixture,
             force_ride_fixture, force_ride_uncapped_fixture, force_ride_low_force_fixture, force_ride_low_torque_fixture,
             force_hop_fixture, force_hop_uncapped_fixture, force_hop_invalid_vertical_fixture, force_hop_low_vertical_fixture,
             floor_fixture, follow_fixture, renewal_fixture, lead_fixture, guard_fixture, core_pose_fixture})
        if (fs::exists(source / planted))
            throw std::runtime_error(planted.string() + " belongs only in test copies, not in " + source.generic_string());
    const auto wanted = fs::weakly_canonical(copy_folder);
    if (within(source, wanted) || within(wanted, source) || has_directory_ancestor(wanted, source) ||
        (fs::exists(wanted) && has_directory_ancestor(source, wanted)))
        throw std::runtime_error("the qualified copy must be outside the plugin folder: " + wanted.generic_string());

    // Read and validate everything before creating, removing or overwriting any destination entry.
    std::map<fs::path, std::string> files;
    std::string problem;
    for (const auto& entry : fs::directory_iterator(source)) {
        refuse_reparse_path(entry.path());
        if (!is_lua_file(entry)) continue;
        const auto name = entry.path().filename();
        if (!stage_module_name(name)) throw std::runtime_error("invalid staging module name: " + name.string());
        for (const auto& [earlier, unused] : files) {
            (void)unused;
            if (within(earlier, name) && within(name, earlier))
                throw std::runtime_error("case-alias staging module: " + name.string());
        }
        auto text = read_text(entry.path(), problem);
        if (!problem.empty()) throw std::runtime_error(problem);
        files.emplace(name, std::move(text));
    }
    const auto main_file = files.find("main.lua");
    if (main_file == files.end()) throw std::runtime_error("main.lua is missing from the plugin folder");
    const auto ride_file = files.find("ride_runtime.lua");
    if (ride_file == files.end()) throw std::runtime_error("ride_runtime.lua is missing from the plugin folder");
    auto ride = ride_file->second;
    const std::string_view inactive = "local ACTIVATION_QUALIFIED = false";
    const auto gate = ride.find(inactive);
    if (gate == std::string::npos || ride.find(inactive, gate + inactive.size()) != std::string::npos)
        throw std::runtime_error("ride_runtime.lua must keep exactly one '" + std::string(inactive) + "' gate");
    ride.replace(gate, inactive.size(), "local ACTIVATION_QUALIFIED = true");
    const auto modules = files.size();
    files.emplace(fixture, std::move(ride));
    // Parameters supply only the entry suite's constructed services. All source bytes stay intact.
    files.emplace(main_fixture, "return function(reskate, require)\n" + main_file->second + "\nend");
    // The small staging stand-ins need no Contact module. A real plugin that
    // has one must keep its literal false and gets only this private test copy.
    const auto contact_file = files.find("contact_runtime.lua");
    if (contact_file != files.end()) {
        auto contact = contact_file->second;
        constexpr std::string_view inactive_category = "local CATEGORY_WHEEL_LANE_QUALIFIED=false";
        const auto category_gate = contact.find(inactive_category);
        if (category_gate == std::string::npos ||
            contact.find(inactive_category, category_gate + inactive_category.size()) != std::string::npos)
            throw std::runtime_error("contact_runtime.lua must keep exactly one '" + std::string(inactive_category) + "' gate");
        contact.replace(category_gate, inactive_category.size(), "local CATEGORY_WHEEL_LANE_QUALIFIED=true");
        files.emplace(category_fixture, std::move(contact));
    }
    // The same for the mounted pose: its gate stays false in the plugin until a game run shows the pose.
    const auto pose_file = files.find("mounted_pose.lua");
    if (pose_file != files.end()) {
        auto pose = pose_file->second;
        constexpr std::string_view inactive_pose = "local MOUNTED_POSE_QUALIFIED = false";
        const auto pose_gate = pose.find(inactive_pose);
        if (pose_gate == std::string::npos || pose.find(inactive_pose, pose_gate + inactive_pose.size()) != std::string::npos)
            throw std::runtime_error("mounted_pose.lua must keep exactly one '" + std::string(inactive_pose) + "' gate");
        pose.replace(pose_gate, inactive_pose.size(), "local MOUNTED_POSE_QUALIFIED = true");
        files.emplace(pose_fixture, std::move(pose));
    }

    // Force stages and their caps are authored in Lua. These synthetic copies exercise
    // policy branches only; the shipped source must remain zero-force and uncapped.
    const auto force_file = files.find("force_stage.lua");
    if (force_file != files.end()) {
        const auto& force = force_file->second;
        constexpr std::string_view inactive_stage = "local STAGE = \"zero_force\"";
        constexpr std::string_view inactive_caps = "local AUTHORED_CAPS = nil";
        const auto stage_at = force.find(inactive_stage);
        const auto caps_at = force.find(inactive_caps);
        if (stage_at == std::string::npos || force.find(inactive_stage, stage_at + inactive_stage.size()) != std::string::npos)
            throw std::runtime_error("force_stage.lua must keep exactly one '" + std::string(inactive_stage) + "' literal");
        if (caps_at == std::string::npos || force.find(inactive_caps, caps_at + inactive_caps.size()) != std::string::npos)
            throw std::runtime_error("force_stage.lua must keep exactly one '" + std::string(inactive_caps) + "' literal");
        const auto add_force_fixture = [&](const fs::path& name, std::string_view stage, std::string_view caps) {
            auto copy = force;
            copy.replace(copy.find(inactive_stage), inactive_stage.size(), "local STAGE = \"" + std::string(stage) + "\"");
            copy.replace(copy.find(inactive_caps), inactive_caps.size(), "local AUTHORED_CAPS = " + std::string(caps));
            files.emplace(name, std::move(copy));
        };
        add_force_fixture(force_support_fixture, "support", "{force=20000,speed=10}");
        add_force_fixture(force_pedal_fixture, "pedal", "{force=20000,speed=10}");
        add_force_fixture(force_support_uncapped_fixture, "support", "nil");
        add_force_fixture(force_pedal_uncapped_fixture, "pedal", "nil");
        add_force_fixture(force_low_cap_fixture, "support", "{force=100,speed=10}");
        add_force_fixture(force_invalid_fixture, "invalid_stage", "nil");
        add_force_fixture(force_support_torque_fixture, "support", "{force=20000,speed=10,torque=4000}");
        add_force_fixture(force_pedal_torque_fixture, "pedal", "{force=20000,speed=10,torque=4000}");
        add_force_fixture(force_low_torque_fixture, "support", "{force=20000,speed=10,torque=35}");
        add_force_fixture(force_torque_zero_fixture, "support", "{force=20000,speed=10,torque=0}");
        add_force_fixture(force_torque_negative_fixture, "support", "{force=20000,speed=10,torque=-1}");
        add_force_fixture(force_torque_infinite_fixture, "support", "{force=20000,speed=10,torque=math.huge}");
        add_force_fixture(force_torque_nan_fixture, "support", "{force=20000,speed=10,torque=0/0}");
        add_force_fixture(force_torque_string_fixture, "support", "{force=20000,speed=10,torque=\"4000\"}");
        add_force_fixture(force_torque_boolean_fixture, "support", "{force=20000,speed=10,torque=false}");
        add_force_fixture(force_torque_excess_fixture, "support", "{force=20000,speed=10,torque=4000.001}");
        add_force_fixture(force_ride_fixture, "ride", "{force=6000,speed=3,torque=2000}");
        add_force_fixture(force_ride_uncapped_fixture, "ride", "nil");
        add_force_fixture(force_ride_low_force_fixture, "ride", "{force=100,speed=3,torque=2000}");
        add_force_fixture(force_ride_low_torque_fixture, "ride", "{force=6000,speed=3,torque=35}");
        add_force_fixture(force_hop_fixture, "hop", "{force=6000,speed=3,torque=2000,vertical_speed=6}");
        add_force_fixture(force_hop_uncapped_fixture, "hop", "nil");
        add_force_fixture(force_hop_invalid_vertical_fixture, "hop", "{force=6000,speed=3,torque=2000,vertical_speed=0}");
        add_force_fixture(force_hop_low_vertical_fixture, "hop", "{force=6000,speed=3,torque=2000,vertical_speed=.1}");
    }

    // Floor placement stays inactive in the shipped module. Its suite alone
    // receives the reviewed single-literal trial substitution, without an API option.
    const auto spawn_file = files.find("bike_spawn.lua");
    if (spawn_file != files.end()) {
        auto spawn = spawn_file->second;
        constexpr std::string_view inactive_floor = "local FLOOR_SPAWN_QUALIFIED=false";
        const auto floor_gate = spawn.find(inactive_floor);
        if (floor_gate == std::string::npos || spawn.find(inactive_floor, floor_gate + inactive_floor.size()) != std::string::npos)
            throw std::runtime_error("bike_spawn.lua must keep exactly one '" + std::string(inactive_floor) + "' gate");
        spawn.replace(floor_gate, inactive_floor.size(), "local FLOOR_SPAWN_QUALIFIED=true");
        files.emplace(floor_fixture, std::move(spawn));
    }

    // Follow trials change one literal each. The active-guard fixture also
    // binds the separately qualified Ride copy, so both owners participate.
    // Validate every substitution before staging; the plugin receives no fixture.
    const auto core_file = files.find("bike_runtime_core.lua");
    if (core_file != files.end()) {
        const auto flipped = [&](std::string_view inactive, std::string_view active) {
            auto core = core_file->second;
            const auto gate = core.find(inactive);
            if (gate == std::string::npos || core.find(inactive, gate + inactive.size()) != std::string::npos)
                throw std::runtime_error("bike_runtime_core.lua must keep exactly one '" + std::string(inactive) + "' gate");
            core.replace(gate, inactive.size(), active);
            return core;
        };
        auto follow = flipped("local M1_PROVISIONAL_FOLLOW_OFFSET=false", "local M1_PROVISIONAL_FOLLOW_OFFSET=true");
        auto renewal = flipped("local FOLLOW_RENEWAL_QUALIFIED=false", "local FOLLOW_RENEWAL_QUALIFIED=true");
        auto lead = flipped("local FOLLOW_LEAD_QUALIFIED=false", "local FOLLOW_LEAD_QUALIFIED=true");
        auto guard = flipped("local RIDE_COMPOSITION_QUALIFIED=false", "local RIDE_COMPOSITION_QUALIFIED=true");
        constexpr std::string_view ride_binding = "local Ride=require(\"./ride_runtime\")";
        const auto ride_at = guard.find(ride_binding);
        if (ride_at == std::string::npos || guard.find(ride_binding, ride_at + ride_binding.size()) != std::string::npos)
            throw std::runtime_error("bike_runtime_core.lua must keep exactly one canonical Ride binding");
        guard.replace(ride_at, ride_binding.size(), "local Ride=require(\"./ride_runtime_qualified_fixture\")");
        // This copy changes only the lazy pose binding. Core, Ride and native gates stay closed.
        if (pose_file == files.end())
            throw std::runtime_error("mounted_pose.lua is required for the Core mounted pose fixture");
        auto core_pose = core_file->second;
        constexpr std::string_view pose_binding = "MountedPose=require(\"./mounted_pose\")";
        constexpr std::string_view qualified_pose_binding = "MountedPose=require(\"./mounted_pose_qualified_fixture\")";
        const auto pose_at = core_pose.find(pose_binding);
        if (pose_at == std::string::npos || core_pose.find(pose_binding, pose_at + pose_binding.size()) != std::string::npos ||
            core_pose.find(qualified_pose_binding) != std::string::npos)
            throw std::runtime_error("bike_runtime_core.lua must keep exactly one canonical MountedPose binding and no qualified binding");
        core_pose.replace(pose_at, pose_binding.size(), qualified_pose_binding);
        files.emplace(core_pose_fixture, std::move(core_pose));
        files.emplace(follow_fixture, std::move(follow));
        files.emplace(renewal_fixture, std::move(renewal));
        files.emplace(lead_fixture, std::move(lead));
        files.emplace(guard_fixture, std::move(guard));
    }

    std::set<fs::path> owned;
    bool earlier_copy = false;
    if (fs::exists(wanted)) {
        if (!fs::is_directory(wanted)) throw std::runtime_error("the qualified copy is not a folder");
        std::set<fs::path> actual;
        for (const auto& entry : fs::directory_iterator(wanted)) {
            refuse_reparse_path(entry.path());
            if (!entry.is_regular_file()) throw std::runtime_error("unexpected staging entry: " + entry.path().generic_string());
            actual.insert(entry.path().filename());
        }
        if (!actual.empty()) {
            // A legacy copy, a mistyped folder or anyone else's files: none of it is this runner's to remove.
            if (!actual.contains(manifest))
                throw std::runtime_error(wanted.generic_string() + " holds files but no " + manifest.string() +
                    " owned-file manifest, so this runner did not make it; nothing was removed: stage into a fresh folder");
            const auto text = read_text(wanted / manifest, problem);
            if (!problem.empty()) throw std::runtime_error(problem);
            std::istringstream lines(text);
            std::string line;
            if (!std::getline(lines, line) || line != manifest_header)
                throw std::runtime_error("nonempty qualified copy needs its explicit owned-file manifest");
            while (std::getline(lines, line)) {
                const fs::path name(line);
                if (!stage_module_name(name)) throw std::runtime_error("invalid owned staging filename");
                for (const auto& earlier : owned)
                    if (within(earlier, name) && within(name, earlier)) throw std::runtime_error("duplicate owned staging filename");
                owned.insert(name);
            }
            auto expected = owned;
            expected.insert(manifest);
            if (!owned.contains(fixture) || actual != expected)
                throw std::runtime_error("qualified copy has unexpected or missing files; nothing was removed");
            earlier_copy = true;
        }
    }

    fs::create_directories(wanted);
    // Unlink the declared entries first, so even an owned hardlink is never truncated in place.
    for (const auto& name : owned)
        if (!fs::remove(wanted / name)) throw std::runtime_error("could not remove owned staging file: " + name.string());
    if (earlier_copy && !fs::remove(wanted / manifest)) throw std::runtime_error("could not replace staging manifest");
    const auto write = [&](const fs::path& name, const std::string& text) {
        std::ofstream out(wanted / name, std::ios::binary);
        out.write(text.data(), static_cast<std::streamsize>(text.size()));
        out.close();
        if (!out) throw std::runtime_error("could not write " + (wanted / name).generic_string());
    };
    std::string ownership = std::string(manifest_header) + '\n';
    for (const auto& [name, text] : files) {
        write(name, text);
        ownership += name.generic_string() + '\n';
    }
    write(manifest, ownership); // Commit ownership last; a partial stage is not silently adopted.
    std::cout << "bmx_luau_tests: staged " << modules << " modules and qualified test fixtures in "
              << wanted.generic_string() << '\n';
}

// --stage-regression <case> <scratch-folder>: staging's refusals and manifest as CTest cases. A case
// builds a two-module stand-in plugin and its destinations inside a scratch folder that must not exist
// yet, so it neither reads nor writes the real plugin and never removes a file this run did not make.
// CMake clears the scratch folders in a setup test before the cases run.
using Inventory = std::map<std::filesystem::path, std::optional<std::string>>;

// The stand-in's one gate and the fixture it must become, a CRLF module that must arrive untranslated,
// and the bytes someone else owns.
constexpr std::string_view regression_ride =
    "-- stand-in for ride_runtime.lua\nlocal ACTIVATION_QUALIFIED = false\nreturn { qualified = ACTIVATION_QUALIFIED }\n";
constexpr std::string_view regression_fixture =
    "-- stand-in for ride_runtime.lua\nlocal ACTIVATION_QUALIFIED = true\nreturn { qualified = ACTIVATION_QUALIFIED }\n";
constexpr std::string_view regression_math = "local force_math = {}\r\nreturn force_math\r\n";
constexpr std::string_view regression_main =
    "-- stand-in for main.lua\r\nreskate.on(\"tick\", function() return require(\"./force_math\") end)\r\n";
constexpr std::string_view regression_main_fixture =
    "return function(reskate, require)\n"
    "-- stand-in for main.lua\r\nreskate.on(\"tick\", function() return require(\"./force_math\") end)\r\n"
    "\nend";
constexpr std::string_view regression_unrelated = "return { owner = \"someone else\" }\n";
constexpr std::string_view regression_pose =
    "-- stand-in for mounted_pose.lua\nlocal MOUNTED_POSE_QUALIFIED = false\nreturn { qualified = MOUNTED_POSE_QUALIFIED }\n";
constexpr std::string_view regression_pose_fixture =
    "-- stand-in for mounted_pose.lua\nlocal MOUNTED_POSE_QUALIFIED = true\nreturn { qualified = MOUNTED_POSE_QUALIFIED }\n";

void expect(bool condition, const std::string& failure) {
    if (!condition) throw std::runtime_error("stage regression: " + failure);
}

void make_folder(const std::filesystem::path& folder) {
    expect(std::filesystem::create_directory(folder), folder.generic_string() + " already exists");
}

void write_file(const std::filesystem::path& file, std::string_view text) {
    std::ofstream out(file, std::ios::binary);
    out.write(text.data(), static_cast<std::streamsize>(text.size()));
    out.close();
    expect(!out.fail(), "could not write " + file.generic_string());
}

// Every direct entry by name, with a regular file's exact bytes; any other entry has none.
Inventory inventory(const std::filesystem::path& folder) {
    Inventory entries;
    for (const auto& entry : std::filesystem::directory_iterator(folder)) {
        std::optional<std::string> bytes;
        if (entry.is_regular_file()) {
            std::string problem;
            bytes = read_text(entry.path(), problem);
            expect(problem.empty(), problem);
        }
        entries.emplace(entry.path().filename(), std::move(bytes));
    }
    return entries;
}

// Three stand-in modules, including the real entry shape, beside a note that is not a module.
void make_stand_in(const std::filesystem::path& folder) {
    make_folder(folder);
    write_file(folder / "ride_runtime.lua", regression_ride);
    write_file(folder / "force_math.lua", regression_math);
    write_file(folder / "main.lua", regression_main);
    write_file(folder / "notes.txt", "not a module\n");
}

// Staging that must be refused for the given reason, leaving the destination exactly as it was, or
// still absent.
void expect_refused(const std::filesystem::path& source, const std::filesystem::path& destination, std::string_view reason) {
    const bool existed = std::filesystem::exists(destination);
    const auto before = existed ? inventory(destination) : Inventory{};
    try {
        stage_qualified_ride(source, destination);
    } catch (const std::exception& error) {
        const std::string message = error.what();
        expect(message.find(reason) != std::string::npos, "staging into " + destination.generic_string() +
            " was refused, but not because of '" + std::string(reason) + "': " + message);
        expect(std::filesystem::exists(destination) == existed,
            "a refused stage created or removed " + destination.generic_string());
        expect(!existed || inventory(destination) == before, "a refused stage changed " + destination.generic_string());
        return;
    }
    expect(false, "staging into " + destination.generic_string() + " was accepted; it must be refused because of '" +
        std::string(reason) + "'");
}

// A destination this runner did not make is refused and keeps every byte: someone's Lua alone; that Lua
// beside a file named like the fixture, which the old filename heuristic took as ownership before
// deleting every direct .lua file; and that Lua dropped into a real earlier copy that does not list it.
void unrelated_destination(const std::filesystem::path& scratch) {
    const auto source = scratch / "source";
    make_stand_in(source);
    const auto source_before = inventory(source);

    const auto alone = scratch / "unrelated-alone";
    make_folder(alone);
    write_file(alone / "unrelated.lua", regression_unrelated);
    expect_refused(source, alone, "no .bmx-qualified-ride-files-v1 owned-file manifest");

    const auto named = scratch / "unrelated-beside-fixture-name";
    make_folder(named);
    write_file(named / "unrelated.lua", regression_unrelated);
    write_file(named / "ride_runtime_qualified_fixture.lua", "return 'not made by the runner'\n");
    expect_refused(source, named, "no .bmx-qualified-ride-files-v1 owned-file manifest");

    const auto earlier = scratch / "unrelated-in-earlier-copy";
    stage_qualified_ride(source, earlier);
    write_file(earlier / "unrelated.lua", regression_unrelated);
    expect_refused(source, earlier, "unexpected or missing files");

    expect(inventory(source) == source_before, "staging changed its source");
}

// A fixture planted in the plugin is refused before any copy folder exists, and the same stand-in
// without it stages, so the plant alone is the reason.
void planted_fixture(const std::filesystem::path& scratch) {
    const auto planted = scratch / "planted-source";
    make_stand_in(planted);
    write_file(planted / "ride_runtime_qualified_fixture.lua", regression_fixture);
    const auto planted_before = inventory(planted);
    expect_refused(planted, scratch / "planted-copy", "belongs only in test copies");
    expect(inventory(planted) == planted_before, "a refused stage changed its source");

    const auto clean = scratch / "clean-source";
    make_stand_in(clean);
    stage_qualified_ride(clean, scratch / "clean-copy");

    // The mounted pose fixture is refused in the plugin the same way, and a plugin with mounted_pose.lua
    // stages it with only the gate flipped; a second gate is refused.
    const auto pose_planted = scratch / "pose-planted-source";
    make_stand_in(pose_planted);
    write_file(pose_planted / "mounted_pose.lua", regression_pose);
    write_file(pose_planted / "mounted_pose_qualified_fixture.lua", regression_pose_fixture);
    expect_refused(pose_planted, scratch / "pose-planted-copy", "belongs only in test copies");

    const auto pose_source = scratch / "pose-source";
    make_stand_in(pose_source);
    write_file(pose_source / "mounted_pose.lua", regression_pose);
    stage_qualified_ride(pose_source, scratch / "pose-copy");
    const auto pose_copy = inventory(scratch / "pose-copy");
    const auto staged_pose = pose_copy.find("mounted_pose_qualified_fixture.lua");
    expect(staged_pose != pose_copy.end() && staged_pose->second == std::string(regression_pose_fixture),
        "the mounted pose fixture is not mounted_pose.lua with only its gate flipped");

    const auto pose_twice = scratch / "pose-twice-source";
    make_stand_in(pose_twice);
    write_file(pose_twice / "mounted_pose.lua", std::string(regression_pose) + "local MOUNTED_POSE_QUALIFIED = false\n");
    expect_refused(pose_twice, scratch / "pose-twice-copy", "must keep exactly one");
}

// A fresh stage holds the stand-in modules, gate fixture and byte-exact entry wrapper with their
// explicit manifest; a rerun, as CTest makes on every run, leaves it
// identical; and a module dropped from the source leaves the copy and its manifest on the next stage.
void exact_manifest(const std::filesystem::path& scratch) {
    const auto source = scratch / "source";
    make_stand_in(source);
    const auto source_before = inventory(source);
    const auto destination = scratch / "copy";
    const Inventory staged{
        {".bmx-qualified-ride-files-v1",
            std::string("bmx-qualified-ride-files-v1\nforce_math.lua\nmain.lua\nmain_score_entry_fixture.lua\nride_runtime.lua\nride_runtime_qualified_fixture.lua\n")},
        {"force_math.lua", std::string(regression_math)},
        {"main.lua", std::string(regression_main)},
        {"main_score_entry_fixture.lua", std::string(regression_main_fixture)},
        {"ride_runtime.lua", std::string(regression_ride)},
        {"ride_runtime_qualified_fixture.lua", std::string(regression_fixture)}};
    stage_qualified_ride(source, destination);
    expect(inventory(destination) == staged, "a fresh stage does not hold exactly the modules, the fixture and their manifest");
    stage_qualified_ride(source, destination);
    expect(inventory(destination) == staged, "a rerun into its own copy changed it");
    expect(inventory(source) == source_before, "staging changed its source");

    write_file(source / "main_score_entry_fixture.lua", regression_main_fixture);
    expect_refused(source, destination, "belongs only in test copies");
    expect_refused(source, scratch / "entry-planted-copy", "belongs only in test copies");
    expect(std::filesystem::remove(source / "main_score_entry_fixture.lua"), "could not remove the planted entry wrapper");
    expect(std::filesystem::remove(source / "main.lua"), "could not remove the owned main dependency");
    expect_refused(source, destination, "main.lua is missing");
    expect_refused(source, scratch / "entry-missing-main-copy", "main.lua is missing");
    write_file(source / "main.lua", regression_main);
    expect(inventory(source) == source_before, "entry wrapper refusal checks changed source bytes");

    expect(std::filesystem::remove(source / "force_math.lua"), "could not drop force_math.lua from the stand-in");
    stage_qualified_ride(source, destination);
    const Inventory dropped{
        {".bmx-qualified-ride-files-v1",
            std::string("bmx-qualified-ride-files-v1\nmain.lua\nmain_score_entry_fixture.lua\nride_runtime.lua\nride_runtime_qualified_fixture.lua\n")},
        {"main.lua", std::string(regression_main)},
        {"main_score_entry_fixture.lua", std::string(regression_main_fixture)},
        {"ride_runtime.lua", std::string(regression_ride)},
        {"ride_runtime_qualified_fixture.lua", std::string(regression_fixture)}};
    expect(inventory(destination) == dropped, "a module dropped from the source stayed in the copy or its manifest");
}

// Contact qualification exists only in a test copy and must not change any
// source bytes or a destination rejected by gate/ownership validation.
void category_manifest(const std::filesystem::path& scratch) {
    const auto source = scratch / "source";
    make_stand_in(source);
    constexpr std::string_view contact = "local CATEGORY_WHEEL_LANE_QUALIFIED=false\nreturn CATEGORY_WHEEL_LANE_QUALIFIED\n";
    constexpr std::string_view qualified = "local CATEGORY_WHEEL_LANE_QUALIFIED=true\nreturn CATEGORY_WHEEL_LANE_QUALIFIED\n";
    write_file(source / "contact_runtime.lua", contact);
    const auto before = inventory(source);
    const auto destination = scratch / "copy";
    stage_qualified_ride(source, destination);
    const auto staged = inventory(destination);
    expect(staged.at("contact_runtime.lua") == std::string(contact), "canonical Contact changed in the copy");
    expect(staged.at("contact_runtime_category_qualified_fixture.lua") == std::string(qualified), "Contact fixture changed more than one literal");
    expect(staged.at(".bmx-qualified-ride-files-v1") == std::string(
        "bmx-qualified-ride-files-v1\ncontact_runtime.lua\ncontact_runtime_category_qualified_fixture.lua\nforce_math.lua\nmain.lua\nmain_score_entry_fixture.lua\nride_runtime.lua\nride_runtime_qualified_fixture.lua\n"),
        "Contact fixture missing from exact ownership manifest");
    expect(staged.size() == 8, "Contact stage has unexpected entries");
    stage_qualified_ride(source, destination);
    expect(inventory(destination) == staged && inventory(source) == before, "Contact rerun changed source or destination bytes");
    write_file(source / "contact_runtime.lua", qualified);
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "contact_runtime.lua", std::string(contact) + std::string(contact));
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "contact_runtime.lua", contact);
    write_file(source / "contact_runtime_category_qualified_fixture.lua", qualified);
    expect_refused(source, scratch / "planted-copy", "belongs only in test copies");
}

// The shipped force stage stays zero-force with no authored caps. Only these private
// copies differ, and a malformed source or a planted fixture leaves every destination byte alone.
void force_stage_manifest(const std::filesystem::path& scratch) {
    namespace fs = std::filesystem;
    constexpr std::string_view force =
        "-- stand-in for force_stage.lua\r\nlocal STAGE = \"zero_force\"\r\nlocal AUTHORED_CAPS = nil\r\n"
        "return { stage = STAGE, caps = AUTHORED_CAPS }\r\n";
    struct Fixture {
        fs::path name;
        std::string_view stage, caps;
    };
    const std::vector<Fixture> fixtures{
        {"force_stage_support_fixture.lua", "support", "{force=20000,speed=10}"},
        {"force_stage_pedal_fixture.lua", "pedal", "{force=20000,speed=10}"},
        {"force_stage_support_uncapped_fixture.lua", "support", "nil"},
        {"force_stage_pedal_uncapped_fixture.lua", "pedal", "nil"},
        {"force_stage_low_cap_fixture.lua", "support", "{force=100,speed=10}"},
        {"force_stage_invalid_fixture.lua", "invalid_stage", "nil"},
        {"force_stage_support_torque_fixture.lua", "support", "{force=20000,speed=10,torque=4000}"},
        {"force_stage_pedal_torque_fixture.lua", "pedal", "{force=20000,speed=10,torque=4000}"},
        {"force_stage_low_torque_fixture.lua", "support", "{force=20000,speed=10,torque=35}"},
        {"force_stage_torque_zero_fixture.lua", "support", "{force=20000,speed=10,torque=0}"},
        {"force_stage_torque_negative_fixture.lua", "support", "{force=20000,speed=10,torque=-1}"},
        {"force_stage_torque_infinite_fixture.lua", "support", "{force=20000,speed=10,torque=math.huge}"},
        {"force_stage_torque_nan_fixture.lua", "support", "{force=20000,speed=10,torque=0/0}"},
        {"force_stage_torque_string_fixture.lua", "support", "{force=20000,speed=10,torque=\"4000\"}"},
        {"force_stage_torque_boolean_fixture.lua", "support", "{force=20000,speed=10,torque=false}"},
        {"force_stage_torque_excess_fixture.lua", "support", "{force=20000,speed=10,torque=4000.001}"},
        {"force_stage_ride_fixture.lua", "ride", "{force=6000,speed=3,torque=2000}"},
        {"force_stage_ride_uncapped_fixture.lua", "ride", "nil"},
        {"force_stage_ride_low_force_fixture.lua", "ride", "{force=100,speed=3,torque=2000}"},
        {"force_stage_ride_low_torque_fixture.lua", "ride", "{force=6000,speed=3,torque=35}"},
        {"force_stage_hop_fixture.lua", "hop", "{force=6000,speed=3,torque=2000,vertical_speed=6}"},
        {"force_stage_hop_uncapped_fixture.lua", "hop", "nil"},
        {"force_stage_hop_invalid_vertical_fixture.lua", "hop", "{force=6000,speed=3,torque=2000,vertical_speed=0}"},
        {"force_stage_hop_low_vertical_fixture.lua", "hop", "{force=6000,speed=3,torque=2000,vertical_speed=.1}"}};
    const auto source = scratch / "source";
    make_stand_in(source);
    write_file(source / "force_stage.lua", force);
    const auto before = inventory(source);
    const auto destination = scratch / "copy";
    stage_qualified_ride(source, destination);
    const auto staged = inventory(destination);
    expect(staged.at("force_stage.lua") == std::string(force), "canonical ForceStage changed in the copy");
    for (const auto& fixture : fixtures) {
        const auto expected = "-- stand-in for force_stage.lua\r\nlocal STAGE = \"" + std::string(fixture.stage) +
            "\"\r\nlocal AUTHORED_CAPS = " + std::string(fixture.caps) + "\r\nreturn { stage = STAGE, caps = AUTHORED_CAPS }\r\n";
        expect(staged.at(fixture.name) == expected, fixture.name.string() + " changed bytes beyond its two authored literals");
    }
    expect(staged.at(".bmx-qualified-ride-files-v1") == std::string(
        "bmx-qualified-ride-files-v1\nforce_math.lua\nforce_stage.lua\nforce_stage_hop_fixture.lua\n"
        "force_stage_hop_invalid_vertical_fixture.lua\nforce_stage_hop_low_vertical_fixture.lua\n"
        "force_stage_hop_uncapped_fixture.lua\nforce_stage_invalid_fixture.lua\n"
        "force_stage_low_cap_fixture.lua\nforce_stage_low_torque_fixture.lua\nforce_stage_pedal_fixture.lua\n"
        "force_stage_pedal_torque_fixture.lua\nforce_stage_pedal_uncapped_fixture.lua\n"
        "force_stage_ride_fixture.lua\nforce_stage_ride_low_force_fixture.lua\n"
        "force_stage_ride_low_torque_fixture.lua\nforce_stage_ride_uncapped_fixture.lua\nforce_stage_support_fixture.lua\n"
        "force_stage_support_torque_fixture.lua\nforce_stage_support_uncapped_fixture.lua\n"
        "force_stage_torque_boolean_fixture.lua\nforce_stage_torque_excess_fixture.lua\nforce_stage_torque_infinite_fixture.lua\n"
        "force_stage_torque_nan_fixture.lua\nforce_stage_torque_negative_fixture.lua\nforce_stage_torque_string_fixture.lua\n"
        "force_stage_torque_zero_fixture.lua\nmain.lua\nmain_score_entry_fixture.lua\nride_runtime.lua\nride_runtime_qualified_fixture.lua\n"),
        "force fixtures missing from exact ownership manifest");
    expect(staged.size() == 31, "force stage has unexpected entries");
    stage_qualified_ride(source, destination);
    expect(inventory(destination) == staged && inventory(source) == before, "force rerun changed source or destination bytes");

    for (const auto& fixture : fixtures) {
        write_file(source / fixture.name, regression_unrelated);
        expect_refused(source, destination, "belongs only in test copies");
        expect_refused(source, scratch / (fixture.name.stem().string() + "-absent-copy"), "belongs only in test copies");
        expect(fs::remove(source / fixture.name), "could not remove the planted stand-in fixture");
    }
    const std::vector<std::string> malformed{
        "local STAGE = \"support\"\nlocal AUTHORED_CAPS = nil\n",
        "local AUTHORED_CAPS = nil\n",
        std::string(force) + "local STAGE = \"zero_force\"\n",
        "local STAGE = \"zero_force\"\n",
        std::string(force) + "local AUTHORED_CAPS = nil\n",
        "local STAGE = \"zero_force\"\nlocal AUTHORED_CAPS = {force=20000,speed=10}\n"};
    std::size_t invalid_index = 0;
    for (const auto& invalid : malformed) {
        write_file(source / "force_stage.lua", invalid);
        expect_refused(source, destination, "force_stage.lua must keep exactly one");
        expect_refused(source, scratch / ("invalid-force-" + std::to_string(invalid_index++) + "-copy"),
            "force_stage.lua must keep exactly one");
    }
    write_file(source / "force_stage.lua", force);
    expect(inventory(source) == before, "force refusal checks changed other source bytes");

    expect(fs::remove(source / "force_stage.lua"), "could not drop force_stage.lua from the stand-in");
    stage_qualified_ride(source, destination);
    const Inventory dropped{
        {".bmx-qualified-ride-files-v1",
            std::string("bmx-qualified-ride-files-v1\nforce_math.lua\nmain.lua\nmain_score_entry_fixture.lua\nride_runtime.lua\nride_runtime_qualified_fixture.lua\n")},
        {"force_math.lua", std::string(regression_math)},
        {"main.lua", std::string(regression_main)},
        {"main_score_entry_fixture.lua", std::string(regression_main_fixture)},
        {"ride_runtime.lua", std::string(regression_ride)},
        {"ride_runtime_qualified_fixture.lua", std::string(regression_fixture)}};
    expect(inventory(destination) == dropped, "dropped ForceStage or its fixtures stayed in the copy or manifest");
}

// The floor gate is a separate test-only copy, with the same exact-file ownership
// and source-byte checks. Even a true, duplicate or planted gate is refused first.
void floor_manifest(const std::filesystem::path& scratch) {
    const auto source = scratch / "source";
    make_stand_in(source);
    constexpr std::string_view spawn = "local FLOOR_SPAWN_QUALIFIED=false\r\nreturn FLOOR_SPAWN_QUALIFIED\r\n";
    constexpr std::string_view qualified = "local FLOOR_SPAWN_QUALIFIED=true\r\nreturn FLOOR_SPAWN_QUALIFIED\r\n";
    write_file(source / "bike_spawn.lua", spawn);
    constexpr std::string_view core = "local M1_PROVISIONAL_FOLLOW_OFFSET=false\r\nlocal FOLLOW_RENEWAL_QUALIFIED=false\r\n"
        "local FOLLOW_LEAD_QUALIFIED=false\r\nlocal RIDE_COMPOSITION_QUALIFIED=false\r\nlocal Ride=require(\"./ride_runtime\")\r\nlocal MountedPose\r\nMountedPose=require(\"./mounted_pose\")\r\nreturn M1_PROVISIONAL_FOLLOW_OFFSET\r\n";
    constexpr std::string_view core_qualified = "local M1_PROVISIONAL_FOLLOW_OFFSET=true\r\nlocal FOLLOW_RENEWAL_QUALIFIED=false\r\n"
        "local FOLLOW_LEAD_QUALIFIED=false\r\nlocal RIDE_COMPOSITION_QUALIFIED=false\r\nlocal Ride=require(\"./ride_runtime\")\r\nlocal MountedPose\r\nMountedPose=require(\"./mounted_pose\")\r\nreturn M1_PROVISIONAL_FOLLOW_OFFSET\r\n";
    constexpr std::string_view core_renewal = "local M1_PROVISIONAL_FOLLOW_OFFSET=false\r\nlocal FOLLOW_RENEWAL_QUALIFIED=true\r\n"
        "local FOLLOW_LEAD_QUALIFIED=false\r\nlocal RIDE_COMPOSITION_QUALIFIED=false\r\nlocal Ride=require(\"./ride_runtime\")\r\nlocal MountedPose\r\nMountedPose=require(\"./mounted_pose\")\r\nreturn M1_PROVISIONAL_FOLLOW_OFFSET\r\n";
    constexpr std::string_view core_lead = "local M1_PROVISIONAL_FOLLOW_OFFSET=false\r\nlocal FOLLOW_RENEWAL_QUALIFIED=false\r\n"
        "local FOLLOW_LEAD_QUALIFIED=true\r\nlocal RIDE_COMPOSITION_QUALIFIED=false\r\nlocal Ride=require(\"./ride_runtime\")\r\nlocal MountedPose\r\nMountedPose=require(\"./mounted_pose\")\r\nreturn M1_PROVISIONAL_FOLLOW_OFFSET\r\n";
    constexpr std::string_view core_guard = "local M1_PROVISIONAL_FOLLOW_OFFSET=false\r\nlocal FOLLOW_RENEWAL_QUALIFIED=false\r\n"
        "local FOLLOW_LEAD_QUALIFIED=false\r\nlocal RIDE_COMPOSITION_QUALIFIED=true\r\nlocal Ride=require(\"./ride_runtime_qualified_fixture\")\r\nlocal MountedPose\r\nMountedPose=require(\"./mounted_pose\")\r\nreturn M1_PROVISIONAL_FOLLOW_OFFSET\r\n";
    constexpr std::string_view core_pose = "local M1_PROVISIONAL_FOLLOW_OFFSET=false\r\nlocal FOLLOW_RENEWAL_QUALIFIED=false\r\n"
        "local FOLLOW_LEAD_QUALIFIED=false\r\nlocal RIDE_COMPOSITION_QUALIFIED=false\r\nlocal Ride=require(\"./ride_runtime\")\r\n"
        "local MountedPose\r\nMountedPose=require(\"./mounted_pose_qualified_fixture\")\r\nreturn M1_PROVISIONAL_FOLLOW_OFFSET\r\n";
    write_file(source / "mounted_pose.lua", regression_pose);
    write_file(source / "bike_runtime_core.lua", core);
    const auto before = inventory(source);
    const auto destination = scratch / "copy";
    stage_qualified_ride(source, destination);
    const auto staged = inventory(destination);
    expect(staged.at("bike_spawn.lua") == std::string(spawn), "canonical Spawn changed in the copy");
    expect(staged.at("bike_runtime_core.lua") == std::string(core), "canonical Core changed in the copy");
    expect(staged.at("bike_runtime_core_provisional_follow_fixture.lua") == std::string(core_qualified), "provisional Follow fixture changed more than one literal");
    expect(staged.at("bike_runtime_core_follow_renewal_fixture.lua") == std::string(core_renewal), "Follow renewal fixture changed more than one literal");
    expect(staged.at("bike_runtime_core_follow_lead_fixture.lua") == std::string(core_lead), "Follow lead fixture changed more than one literal");
    expect(staged.at("bike_runtime_core_ride_guard_fixture.lua") == std::string(core_guard), "active Core guard fixture changed more than its gate and Ride binding");
    expect(staged.at("bike_runtime_core_mounted_pose_fixture.lua") == std::string(core_pose), "mounted pose Core fixture changed more than its binding");
    expect(staged.at("mounted_pose.lua") == std::string(regression_pose), "canonical mounted pose changed in the copy");
    expect(staged.at("mounted_pose_qualified_fixture.lua") == std::string(regression_pose_fixture), "mounted pose dependency fixture changed more than its gate");
    expect(staged.at("bike_spawn_floor_qualified_fixture.lua") == std::string(qualified), "floor fixture changed more than one literal");
    expect(staged.at(".bmx-qualified-ride-files-v1") == std::string(
        "bmx-qualified-ride-files-v1\nbike_runtime_core.lua\nbike_runtime_core_follow_lead_fixture.lua\nbike_runtime_core_follow_renewal_fixture.lua\nbike_runtime_core_mounted_pose_fixture.lua\nbike_runtime_core_provisional_follow_fixture.lua\nbike_runtime_core_ride_guard_fixture.lua\nbike_spawn.lua\nbike_spawn_floor_qualified_fixture.lua\nforce_math.lua\nmain.lua\nmain_score_entry_fixture.lua\nmounted_pose.lua\nmounted_pose_qualified_fixture.lua\nride_runtime.lua\nride_runtime_qualified_fixture.lua\n"),
        "floor fixture missing from exact ownership manifest");
    expect(staged.size() == 16, "floor stage has unexpected entries");
    stage_qualified_ride(source, destination);
    expect(inventory(destination) == staged && inventory(source) == before, "floor rerun changed source or destination bytes");
    write_file(source / "bike_spawn.lua", qualified);
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_spawn.lua", std::string(spawn) + std::string(spawn));
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_spawn.lua", spawn);
    write_file(source / "bike_runtime_core.lua", core_qualified);
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_runtime_core.lua", std::string(core) + std::string(core));
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_runtime_core.lua", core_renewal);
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_runtime_core.lua", std::string(core) + "local FOLLOW_RENEWAL_QUALIFIED=false\r\n");
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_runtime_core.lua", core_lead);
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_runtime_core.lua", std::string(core) + "local FOLLOW_LEAD_QUALIFIED=false\r\n");
    expect_refused(source, destination, "must keep exactly one");
    auto missing_lead = std::string(core);
    constexpr std::string_view inactive_lead = "local FOLLOW_LEAD_QUALIFIED=false";
    missing_lead.erase(missing_lead.find(inactive_lead), inactive_lead.size());
    write_file(source / "bike_runtime_core.lua", missing_lead);
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_runtime_core.lua", core_guard);
    expect_refused(source, destination, "must keep exactly one");
    write_file(source / "bike_runtime_core.lua", std::string(core) + "local RIDE_COMPOSITION_QUALIFIED=false\r\n");
    expect_refused(source, destination, "must keep exactly one");
    auto missing_guard = std::string(core);
    constexpr std::string_view inactive_guard = "local RIDE_COMPOSITION_QUALIFIED=false";
    missing_guard.erase(missing_guard.find(inactive_guard), inactive_guard.size());
    write_file(source / "bike_runtime_core.lua", missing_guard);
    expect_refused(source, destination, "must keep exactly one");
    constexpr std::string_view canonical_ride = "local Ride=require(\"./ride_runtime\")";
    auto qualified_ride = std::string(core);
    qualified_ride.replace(qualified_ride.find(canonical_ride), canonical_ride.size(), "local Ride=require(\"./ride_runtime_qualified_fixture\")");
    write_file(source / "bike_runtime_core.lua", qualified_ride);
    expect_refused(source, destination, "must keep exactly one canonical Ride binding");
    write_file(source / "bike_runtime_core.lua", std::string(core) + std::string(canonical_ride));
    expect_refused(source, destination, "must keep exactly one canonical Ride binding");
    auto missing_ride = std::string(core);
    missing_ride.erase(missing_ride.find(canonical_ride), canonical_ride.size());
    write_file(source / "bike_runtime_core.lua", missing_ride);
    expect_refused(source, destination, "must keep exactly one canonical Ride binding");
    write_file(source / "bike_runtime_core.lua", core);
    constexpr std::string_view canonical_pose = "MountedPose=require(\"./mounted_pose\")";
    constexpr std::string_view qualified_pose = "MountedPose=require(\"./mounted_pose_qualified_fixture\")";
    write_file(source / "bike_runtime_core.lua", core_pose);
    expect_refused(source, destination, "must keep exactly one canonical MountedPose binding");
    expect_refused(source, scratch / "core-pose-invalid-binding-copy", "must keep exactly one canonical MountedPose binding");
    write_file(source / "bike_runtime_core.lua", std::string(core) + std::string(canonical_pose));
    expect_refused(source, destination, "must keep exactly one canonical MountedPose binding");
    expect_refused(source, scratch / "core-pose-invalid-binding-copy", "must keep exactly one canonical MountedPose binding");
    write_file(source / "bike_runtime_core.lua", std::string(core) + std::string(qualified_pose));
    expect_refused(source, destination, "must keep exactly one canonical MountedPose binding");
    expect_refused(source, scratch / "core-pose-invalid-binding-copy", "must keep exactly one canonical MountedPose binding");
    auto missing_pose_binding = std::string(core);
    missing_pose_binding.erase(missing_pose_binding.find(canonical_pose), canonical_pose.size());
    write_file(source / "bike_runtime_core.lua", missing_pose_binding);
    expect_refused(source, destination, "must keep exactly one canonical MountedPose binding");
    expect_refused(source, scratch / "core-pose-invalid-binding-copy", "must keep exactly one canonical MountedPose binding");
    write_file(source / "bike_runtime_core.lua", core);
    expect(std::filesystem::remove(source / "mounted_pose.lua"), "could not remove the owned pose dependency");
    expect_refused(source, destination, "mounted_pose.lua is required");
    expect_refused(source, scratch / "core-pose-missing-dependency-copy", "mounted_pose.lua is required");
    write_file(source / "mounted_pose.lua", regression_pose);
    write_file(source / "bike_runtime_core_mounted_pose_fixture.lua", core_pose);
    expect_refused(source, destination, "belongs only in test copies");
    expect_refused(source, scratch / "core-pose-planted-copy", "belongs only in test copies");
    expect(std::filesystem::remove(source / "bike_runtime_core_mounted_pose_fixture.lua"), "could not remove the owned pose Core plant");
    write_file(source / "bike_runtime_core_provisional_follow_fixture.lua", core_qualified);
    expect_refused(source, scratch / "core-planted-copy", "belongs only in test copies");
    expect(std::filesystem::remove(source / "bike_runtime_core_provisional_follow_fixture.lua"), "could not remove the owned Core plant");
    write_file(source / "bike_runtime_core_follow_renewal_fixture.lua", core_renewal);
    expect_refused(source, scratch / "core-renewal-planted-copy", "belongs only in test copies");
    expect(std::filesystem::remove(source / "bike_runtime_core_follow_renewal_fixture.lua"), "could not remove the owned renewal plant");
    write_file(source / "bike_runtime_core_follow_lead_fixture.lua", core_lead);
    expect_refused(source, scratch / "core-lead-planted-copy", "belongs only in test copies");
    expect(std::filesystem::remove(source / "bike_runtime_core_follow_lead_fixture.lua"), "could not remove the owned lead plant");
    write_file(source / "bike_runtime_core_ride_guard_fixture.lua", core_guard);
    expect_refused(source, scratch / "core-guard-planted-copy", "belongs only in test copies");
    expect(std::filesystem::remove(source / "bike_runtime_core_ride_guard_fixture.lua"), "could not remove the owned guard plant");
    expect(inventory(destination) == staged, "refused Core literals changed the earlier copy");
    write_file(source / "bike_spawn_floor_qualified_fixture.lua", qualified);
    expect_refused(source, scratch / "planted-copy", "belongs only in test copies");
}

void run_stage_regression(std::string_view name, const std::filesystem::path& scratch) {
    void (*stage_case)(const std::filesystem::path&) = nullptr;
    if (name == "unrelated-destination") stage_case = unrelated_destination;
    else if (name == "planted-fixture") stage_case = planted_fixture;
    else if (name == "exact-manifest") stage_case = exact_manifest;
    else if (name == "category-manifest") stage_case = category_manifest;
    else if (name == "force-stage-manifest") stage_case = force_stage_manifest;
    else if (name == "floor-manifest") stage_case = floor_manifest;
    else throw std::runtime_error("the stage regression cases are unrelated-destination, planted-fixture, exact-manifest, category-manifest, force-stage-manifest and floor-manifest");
    refuse_reparse_path(scratch);
    if (std::filesystem::exists(scratch))
        throw std::runtime_error("the stage regression scratch folder must not exist yet, so a case never removes "
                                 "what an earlier run left: " + scratch.generic_string());
    std::filesystem::create_directories(scratch);
    stage_case(scratch);
    std::cout << "bmx_luau_tests: stage regression " << name << " passed in " << scratch.generic_string() << '\n';
}

// The suite driver. Fields beyond the two counts (comparisons, native_actions and so on) are
// printed so a run shows what a suite skipped without its C++ reference rows, but not judged.
constexpr std::string_view suite_driver = R"lua(
local module_name, json_helper = ...
local suite = require("./" .. module_name)
assert(type(suite) == "table" and type(suite.run) == "function", module_name .. " has no run() function")
local result
if json_helper ~= nil then result = suite.run(json_helper)
else result = suite.run() end
assert(type(result) == "table", module_name .. ".run() must return a table with cases and assertions")
for _, field in {"cases", "assertions"} do
    local count = result[field]
    assert(type(count) == "number" and count > 0 and count < math.huge and count == math.floor(count),
        module_name .. ".run() must report a whole, positive " .. field .. " count")
end
local extra = {}
for key, value in result do
    if type(key) == "string" and key ~= "cases" and key ~= "assertions"
        and (type(value) == "number" or type(value) == "boolean") then
        table.insert(extra, key .. "=" .. tostring(value))
    end
end
table.sort(extra)
print("bmx_luau_tests: module=" .. module_name .. " cases=" .. result.cases .. " assertions=" .. result.assertions
    .. (#extra > 0 and " " .. table.concat(extra, " ") or ""))
)lua";

// Checks the runner's own boundary against a real module that requires nothing (force_math), so it
// needs no fixture file. Every refusal must come from require itself, not from a missing file.
constexpr std::string_view self_test = R"lua(
for _, name in {"force_math", "../force_math", "./../force_math", "./plugin/force_math", "./force_math.lua",
        ".\\force_math", "./", "/force_math", "./FORCE_MATH", "./no_such_module"} do
    local ok, message = pcall(require, name)
    assert(not ok and type(message) == "string" and string.find(message, "require(", 1, true),
        "require(\"" .. name .. "\") must be refused, got " .. tostring(message))
end
local force_math = require("./force_math")
assert(type(force_math) == "table" and require("./force_math") == force_math, "a module runs once and its table is kept")
assert(reskate == nil, "the runner offers no reskate API: it is not the plugin Host")
assert(bmx_luau_runner == nil and getfenv(force_math.finite).bmx_luau_runner == nil,
    "ordinary modules cannot see the JSON test helper")
assert(not pcall(function() bmx_luau_runner_probe = true end), "globals are read only")
assert(not pcall(function() string.bmx_luau_runner_probe = true end), "standard libraries are read only")
print("bmx_luau_tests: self-test passed: ./name in one folder only, modules kept once, read-only globals, no reskate API")
)lua";

// One folder of modules, never written. require("./name") loads <folder>/name.lua once and keeps
// its table. That is the only form BMX modules use; anything else is refused, not searched for.
class ModuleHost {
public:
    explicit ModuleHost(const std::filesystem::path& folder) : root_(open_folder(folder)), state_(luaL_newstate()) {
        if (!state_) throw std::runtime_error("the Luau state could not be allocated");
        lua_callbacks(state_)->userdata = this;
        luaL_openlibs(state_);
        lua_pushcfunction(state_, require_module, "require");
        lua_setglobal(state_, "require");

        // From here globals and the standard libraries are read only, as in a plugin.
        luaL_sandbox(state_);
    }
    ~ModuleHost() { lua_close(state_); }
    ModuleHost(const ModuleHost&) = delete;
    ModuleHost& operator=(const ModuleHost&) = delete;

    void run_suite(std::string_view module) {
        if (!valid_module_name(module))
            throw std::runtime_error("a suite name is 1 to 128 letters, digits, underscores or hyphens, with no path or extension");
        const bool json_helper = module == "json_encoding_tests" || module == "bike_runtime_ledger_size_tests";
        execute(suite_driver, "@bmx_luau_tests", module, json_helper);
    }

    void run_self_test() { execute(self_test, "@bmx_luau_tests_self_test", {}, false); }

private:
    void execute(std::string_view source, const std::string& chunk, std::string_view argument, bool json_helper) {
        lua_settop(state_, 0);
        lua_pushcfunction(state_, traceback, "traceback");
        if (!compile(state_, source, chunk)) throw std::runtime_error(top_text());
        int arguments = 0;
        if (!argument.empty()) {
            lua_pushlstring(state_, argument.data(), argument.size());
            arguments = 1;
        }
        // Only the two serialization suites receive this explicit run() argument.
        // Required production modules use the ordinary globals and never see it.
        if (json_helper) {
            lua_createtable(state_, 0, 1);
            lua_pushcfunction(state_, encode_json, "json_encode");
            lua_setfield(state_, -2, "json_encode");
            lua_setreadonly(state_, -1, true);
            ++arguments;
        }
        if (lua_pcall(state_, arguments, 0, 1) != 0) throw std::runtime_error(top_text());
        lua_settop(state_, 0);
    }

    static int require_module(lua_State* state) {
        const char* name = luaL_checkstring(state, 1);
        return static_cast<ModuleHost*>(lua_callbacks(state)->userdata)->load(state, name);
    }

    // Every refusal is a Lua error raised here, so the driver's traceback shows which require asked.
    int load(lua_State* state, std::string_view requested) {
        const std::string asked(requested);
        if (!requested.starts_with("./") || !valid_module_name(requested.substr(2)))
            luaL_error(state, "require(\"%s\"): only ./name, a module in the runner's one plugin folder, is accepted",
                asked.c_str());
        const std::string name(requested.substr(2));
        if (const auto kept = modules_.find(name); kept != modules_.end()) {
            lua_getref(state, kept->second);
            return 1;
        }
        if (loading_.contains(name))
            luaL_error(state, "require(\"%s\"): it requires itself, through another module", asked.c_str());
        if (loading_.size() >= most_nested_loads)
            luaL_error(state, "require(\"%s\"): more than %d modules are loading at once", asked.c_str(),
                static_cast<int>(most_nested_loads));
        std::string problem;
        const auto file = module_file(name, problem);
        const auto source = problem.empty() ? read_text(file, problem) : std::string{};
        if (!problem.empty()) luaL_error(state, "require(\"%s\"): %s", asked.c_str(), problem.c_str());
        loading_.insert(name);
        // Errors leave through here as exceptions (Luau is built without longjmp), so this runs.
        struct Done {
            std::set<std::string>& loading;
            const std::string& name;
            ~Done() { loading.erase(name); }
        } done{loading_, name};
        if (!compile(state, source, "@" + file.generic_string())) lua_error(state);
        lua_call(state, 0, 1);
        if (lua_isnil(state, -1)) luaL_error(state, "require(\"%s\"): the module returned nil, not its table", asked.c_str());
        modules_.emplace(name, lua_ref(state, -1));
        return 1;
    }

    // The exact name has to be listed in the folder: Windows would open FORCE_MATH.lua as
    // force_math.lua, and not every standard library's canonical() reports the case on disk.
    bool listed(const std::filesystem::path& file_name) const {
        std::error_code code;
        for (std::filesystem::directory_iterator entry(root_, code), end; !code && entry != end; entry.increment(code))
            if (entry->path().filename() == file_name) return true;
        return false;
    }

    std::filesystem::path module_file(const std::string& name, std::string& problem) const {
        const std::filesystem::path file_name = name + ".lua";
        std::error_code code;
        const auto file = listed(file_name) ? std::filesystem::canonical(root_ / file_name, code) : std::filesystem::path{};
        if (file.empty() || code || !std::filesystem::is_regular_file(file, code)) {
            problem = "there is no " + file_name.string() + " in " + root_.generic_string();
            return {};
        }
        // A link that leads out of the folder is not one of its modules.
        if (file.parent_path() != root_) {
            problem = file_name.string() + " resolves to " + file.generic_string() + ", outside the folder";
            return {};
        }
        return file;
    }

    std::string top_text() const {
        const char* text = lua_tostring(state_, -1);
        return text ? text : "Luau failed with an error that is not a string";
    }

    std::filesystem::path root_;
    lua_State* state_ = nullptr;
    std::map<std::string, int> modules_;
    std::set<std::string> loading_;
};
}

int main(int argc, char** argv) {
    try {
        const std::vector<std::string_view> arguments(argv + 1, argv + argc);
        if (arguments.size() == 2 && arguments[0] == "--self-test") {
            ModuleHost host{std::filesystem::path(arguments[1])};
            host.run_self_test();
            return 0;
        }
        if (arguments.size() == 3 && arguments[0] == "--stage-qualified-ride") {
            stage_qualified_ride(std::filesystem::path(arguments[1]), std::filesystem::path(arguments[2]));
            return 0;
        }
        if (arguments.size() == 3 && arguments[0] == "--stage-regression") {
            run_stage_regression(arguments[1], std::filesystem::path(arguments[2]));
            return 0;
        }
        if (arguments.size() != 2 || arguments[0].starts_with("--"))
            throw std::runtime_error("usage: bmx_luau_tests <plugin-folder> <suite-name> | --self-test <plugin-folder> | "
                                     "--stage-qualified-ride <plugin-folder> <copy-folder> | "
                                     "--stage-regression <case> <scratch-folder>");
        ModuleHost host{std::filesystem::path(arguments[0])};
        host.run_suite(arguments[1]);
        std::cout << "Boundary: vendored Luau with the suite's own constructed fixtures; not the plugin Host, "
                     "no permissions, no time limits, no game.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "bmx_luau_tests failed: " << error.what() << '\n';
        return 1;
    }
}
