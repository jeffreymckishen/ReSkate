// Runs one BMX plugin Lua suite on the vendored Luau. Modules are compiled from text the way
// Extension/Plugins/plugin_vm.cpp compiles them (optimization and debug level 1, standard libraries
// sandboxed), but this is not the plugin Host: there is no reskate API, no permission, no call or
// tick time limit, no multiplayer and no game. A suite passes only when its run() returns whole,
// positive cases and assertions counts; a failed assert reaches here with its message and stack.
// --stage-qualified-ride builds the test-only copy the Ride suites need, and --stage-regression checks
// that staging against a stand-in plugin. They are the only modes that write: the first only into the
// copy folder it is given, the second only inside a scratch folder that must not exist yet.
#include "lua.h"
#include "luacode.h"
#include "lualib.h"

#include <algorithm>
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
// inactive gate flipped. That fixture must never exist in the plugin itself, so it is refused there.
// A rerun owns only the manifest's exact file set; a fixture filename alone proves no ownership.
void stage_qualified_ride(const std::filesystem::path& plugin_folder, const std::filesystem::path& copy_folder) {
    namespace fs = std::filesystem;
    refuse_reparse_path(plugin_folder);
    refuse_reparse_path(copy_folder);
    const auto source = open_folder(plugin_folder);
    const fs::path fixture = "ride_runtime_qualified_fixture.lua";
    const fs::path manifest = ".bmx-qualified-ride-files-v1";
    constexpr std::string_view manifest_header = "bmx-qualified-ride-files-v1";
    if (fs::exists(source / fixture))
        throw std::runtime_error(fixture.string() + " belongs only in test copies, not in " + source.generic_string());
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
    std::cout << "bmx_luau_tests: staged " << modules << " modules and the qualified Ride fixture in "
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
constexpr std::string_view regression_unrelated = "return { owner = \"someone else\" }\n";

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

// What ride_runtime.lua and force_math.lua stand in for, beside a note that is not a module.
void make_stand_in(const std::filesystem::path& folder) {
    make_folder(folder);
    write_file(folder / "ride_runtime.lua", regression_ride);
    write_file(folder / "force_math.lua", regression_math);
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
}

// A fresh stage holds exactly the stand-in's .lua modules byte for byte, the fixture with only its gate
// flipped and a manifest naming exactly those three; a rerun, as CTest makes on every run, leaves it
// identical; and a module dropped from the source leaves the copy and its manifest on the next stage.
void exact_manifest(const std::filesystem::path& scratch) {
    const auto source = scratch / "source";
    make_stand_in(source);
    const auto source_before = inventory(source);
    const auto destination = scratch / "copy";
    const Inventory staged{
        {".bmx-qualified-ride-files-v1",
            std::string("bmx-qualified-ride-files-v1\nforce_math.lua\nride_runtime.lua\nride_runtime_qualified_fixture.lua\n")},
        {"force_math.lua", std::string(regression_math)},
        {"ride_runtime.lua", std::string(regression_ride)},
        {"ride_runtime_qualified_fixture.lua", std::string(regression_fixture)}};
    stage_qualified_ride(source, destination);
    expect(inventory(destination) == staged, "a fresh stage does not hold exactly the modules, the fixture and their manifest");
    stage_qualified_ride(source, destination);
    expect(inventory(destination) == staged, "a rerun into its own copy changed it");
    expect(inventory(source) == source_before, "staging changed its source");

    expect(std::filesystem::remove(source / "force_math.lua"), "could not drop force_math.lua from the stand-in");
    stage_qualified_ride(source, destination);
    const Inventory dropped{
        {".bmx-qualified-ride-files-v1",
            std::string("bmx-qualified-ride-files-v1\nride_runtime.lua\nride_runtime_qualified_fixture.lua\n")},
        {"ride_runtime.lua", std::string(regression_ride)},
        {"ride_runtime_qualified_fixture.lua", std::string(regression_fixture)}};
    expect(inventory(destination) == dropped, "a module dropped from the source stayed in the copy or its manifest");
}

void run_stage_regression(std::string_view name, const std::filesystem::path& scratch) {
    void (*stage_case)(const std::filesystem::path&) = nullptr;
    if (name == "unrelated-destination") stage_case = unrelated_destination;
    else if (name == "planted-fixture") stage_case = planted_fixture;
    else if (name == "exact-manifest") stage_case = exact_manifest;
    else throw std::runtime_error("the stage regression cases are unrelated-destination, planted-fixture and exact-manifest");
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
local module_name = ...
local suite = require("./" .. module_name)
assert(type(suite) == "table" and type(suite.run) == "function", module_name .. " has no run() function")
local result = suite.run()
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
        execute(suite_driver, "@bmx_luau_tests", module);
    }

    void run_self_test() { execute(self_test, "@bmx_luau_tests_self_test", {}); }

private:
    void execute(std::string_view source, const std::string& chunk, std::string_view argument) {
        lua_settop(state_, 0);
        lua_pushcfunction(state_, traceback, "traceback");
        if (!compile(state_, source, chunk)) throw std::runtime_error(top_text());
        int arguments = 0;
        if (!argument.empty()) {
            lua_pushlstring(state_, argument.data(), argument.size());
            arguments = 1;
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
