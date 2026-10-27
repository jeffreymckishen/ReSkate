cmake_minimum_required(VERSION 3.24)
project(ReSkateBmxLuauRunner LANGUAGES CXX)

# Runs the BMX plugin's pure Lua suites on vendored Luau with the shared JSON writer. It builds no SDK target and reads
# no shared build output, so it can run while the main tree is mid-build or broken. The static
# runtime keeps the test executable runnable without a Visual Studio environment on PATH.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
get_filename_component(luau_runner_source_root "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(luau_runner_luau "${luau_runner_source_root}/External/luau")
set(luau_runner_plugin "${luau_runner_source_root}/contrib/bmx-lab/bmx-plugin/plugin")
set(luau_runner_qualified "${CMAKE_CURRENT_BINARY_DIR}/qualified-plugin")

# The same five parts as cmake/Dependencies.cmake, compiled into this build tree only: no CodeGen,
# Analysis, CLI or Require. The vendored sources keep their own warning level, as there.
file(GLOB luau_runner_vendored_sources CONFIGURE_DEPENDS
    "${luau_runner_luau}/Common/src/*.cpp"
    "${luau_runner_luau}/Ast/src/*.cpp"
    "${luau_runner_luau}/Bytecode/src/*.cpp"
    "${luau_runner_luau}/Compiler/src/*.cpp"
    "${luau_runner_luau}/VM/src/*.cpp")
if(NOT luau_runner_vendored_sources)
    message(FATAL_ERROR "External/luau is missing from ${luau_runner_source_root}")
endif()
add_library(bmx_luau_runner_luau STATIC ${luau_runner_vendored_sources})
target_include_directories(bmx_luau_runner_luau SYSTEM PUBLIC
    "${luau_runner_luau}/Common/include"
    "${luau_runner_luau}/Ast/include"
    "${luau_runner_luau}/Bytecode/include"
    "${luau_runner_luau}/Compiler/include"
    "${luau_runner_luau}/VM/include")
target_include_directories(bmx_luau_runner_luau PRIVATE
    "${luau_runner_luau}/VM/src" "${luau_runner_luau}/Bytecode/src")
target_compile_features(bmx_luau_runner_luau PRIVATE cxx_std_17)
if(MSVC)
    target_compile_definitions(bmx_luau_runner_luau PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

# Use the same JSON value model/writer as the SDK for test-only ledger byte measurement.
# RapidJSON is already vendored; no plugin Host, API or game target is linked.
add_library(bmx_luau_runner_json STATIC "${luau_runner_source_root}/Engine/Core/Json/json.cpp")
target_compile_features(bmx_luau_runner_json PRIVATE cxx_std_20)
set_target_properties(bmx_luau_runner_json PROPERTIES CXX_EXTENSIONS OFF)
target_include_directories(bmx_luau_runner_json SYSTEM PRIVATE "${luau_runner_source_root}/External")

add_executable(bmx_luau_tests luau_tests.cpp)
target_compile_features(bmx_luau_tests PRIVATE cxx_std_20)
set_target_properties(bmx_luau_tests PROPERTIES CXX_EXTENSIONS OFF)
target_include_directories(bmx_luau_tests PRIVATE "${luau_runner_source_root}")
target_link_libraries(bmx_luau_tests PRIVATE bmx_luau_runner_luau bmx_luau_runner_json)
if(MSVC)
    target_compile_options(bmx_luau_runner_json PRIVATE /W4 /WX /permissive- /EHsc)
    target_compile_options(bmx_luau_tests PRIVATE /W4 /WX /permissive- /EHsc)
else()
    target_compile_options(bmx_luau_runner_json PRIVATE -Wall -Wextra -Wpedantic -Werror)
    target_compile_options(bmx_luau_tests PRIVATE -Wall -Wextra -Wpedantic -Werror)
    if(MINGW)
        # As in contrib/bmx-lab: runnable outside the compiler's PATH.
        target_link_options(bmx_luau_tests PRIVATE -static)
    endif()
endif()

enable_testing()

# ride_runtime_tests requires ride_runtime_qualified_fixture, which must never ship in the plugin.
# The runner makes it the way Extension/Plugins/Test/bmx_contact_runtime_host_fixture.inc does, in
# a build-dir copy of the plugin, before every test run that needs it, so the copy follows the
# source without a rebuild. It is C++ rather than a CMake script because CMake's file(READ) and
# file(WRITE) translate line endings on Windows, and the copy must differ from the source only in
# the gate.
add_test(NAME bmx_lua.stage_qualified_ride
    COMMAND bmx_luau_tests --stage-qualified-ride "${luau_runner_plugin}" "${luau_runner_qualified}")
set_tests_properties(bmx_lua.stage_qualified_ride PROPERTIES
    FIXTURES_SETUP bmx_lua_qualified_ride TIMEOUT 60 LABELS bmx_lua)

# One test per suite. The glob is re-checked on every build, so a suite another change adds is
# registered without editing this file; its text is read here to decide whether it needs the
# qualified copy, so a suite's file is also a configure dependency.
file(GLOB luau_runner_suites CONFIGURE_DEPENDS LIST_DIRECTORIES false
    "${luau_runner_plugin}/*_tests.lua" "${luau_runner_plugin}/tests.lua")
if(NOT luau_runner_suites)
    message(FATAL_ERROR "No BMX Lua suites were found in ${luau_runner_plugin}")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${luau_runner_suites})
set(luau_runner_staged_suites "")
foreach(suite IN LISTS luau_runner_suites)
    get_filename_component(module "${suite}" NAME_WLE)
    file(READ "${suite}" suite_text)
    # Requiring the fixture, or a suite that requires it, means running against the copy.
    string(REGEX MATCH "ride_runtime_qualified_fixture|ride_runtime_tricks_qualified_fixture|main_score_entry_fixture|trick_runtime_ride_support_qualified_fixture|contact_runtime_category_qualified_fixture|mounted_pose_qualified_fixture|force_stage_[a-z_]+_fixture|bike_spawn_floor_qualified_fixture|bike_runtime_core_provisional_follow_fixture|bike_runtime_core_follow_renewal_fixture|bike_runtime_core_follow_lead_fixture|bike_runtime_core_ride_guard_fixture|bike_runtime_core_mounted_pose_fixture|\\./ride_runtime_tests|\\./ride_runtime_join_tests|\\./ride_runtime_metrics_tests"
        needs_qualified "${suite_text}")
    if(needs_qualified)
        add_test(NAME bmx_lua.${module} COMMAND bmx_luau_tests "${luau_runner_qualified}" "${module}")
        set_tests_properties(bmx_lua.${module} PROPERTIES FIXTURES_REQUIRED bmx_lua_qualified_ride)
        list(APPEND luau_runner_staged_suites "${module}")
    else()
        add_test(NAME bmx_lua.${module} COMMAND bmx_luau_tests "${luau_runner_plugin}" "${module}")
    endif()
    set_tests_properties(bmx_lua.${module} PROPERTIES TIMEOUT 120 LABELS bmx_lua)
endforeach()
list(LENGTH luau_runner_suites luau_runner_suite_count)
message(STATUS "BMX Lua suites: ${luau_runner_suite_count}; against the qualified copy: ${luau_runner_staged_suites}")

# The runner's own boundary: require is ./name in one folder, globals are read only, there is no
# reskate API, and a bad name or a module without run() is refused with its reason.
add_test(NAME bmx_lua_runner.self_test COMMAND bmx_luau_tests --self-test "${luau_runner_plugin}")
add_test(NAME bmx_lua_runner.refuses_path_name COMMAND bmx_luau_tests "${luau_runner_plugin}" "../plugin/forces")
set_tests_properties(bmx_lua_runner.refuses_path_name PROPERTIES
    PASS_REGULAR_EXPRESSION "bmx_luau_tests failed: a suite name is 1 to 128 letters")
add_test(NAME bmx_lua_runner.refuses_module_without_run COMMAND bmx_luau_tests "${luau_runner_plugin}" force_math)
set_tests_properties(bmx_lua_runner.refuses_module_without_run PROPERTIES
    PASS_REGULAR_EXPRESSION "bmx_luau_tests failed: .*force_math has no run\\(\\) function")
add_test(NAME bmx_lua_runner.refuses_missing_suite COMMAND bmx_luau_tests "${luau_runner_plugin}" no_such_suite_tests)
set_tests_properties(bmx_lua_runner.refuses_missing_suite PROPERTIES
    PASS_REGULAR_EXPRESSION "bmx_luau_tests failed: .*there is no no_such_suite_tests\\.lua")
set_tests_properties(bmx_lua_runner.self_test bmx_lua_runner.refuses_path_name
    bmx_lua_runner.refuses_module_without_run bmx_lua_runner.refuses_missing_suite PROPERTIES TIMEOUT 60 LABELS bmx_lua_runner)

# Staging's refusals and manifest. Each case fills a scratch folder of its own, which it must find
# absent, with a four-module stand-in plugin and its destinations, so the real plugin is neither read
# nor written and a case never removes a file it did not make. The setup test clears the case
# folders first. They are siblings, not one parent, so cases running in parallel never race to make
# a shared folder.
set(luau_runner_stage_scratch "${CMAKE_CURRENT_BINARY_DIR}/stage-regression")
add_test(NAME bmx_lua_runner.stage_regression_reset COMMAND "${CMAKE_COMMAND}" -E rm -rf
    "${luau_runner_stage_scratch}-unrelated-destination" "${luau_runner_stage_scratch}-planted-fixture"
    "${luau_runner_stage_scratch}-exact-manifest" "${luau_runner_stage_scratch}-category-manifest"
    "${luau_runner_stage_scratch}-force-stage-manifest" "${luau_runner_stage_scratch}-floor-manifest")
set_tests_properties(bmx_lua_runner.stage_regression_reset PROPERTIES FIXTURES_SETUP bmx_lua_stage_regression)
# Unrelated .lua files alone, beside a fixture-named file (the old heuristic deleted them there) and
# inside a real earlier copy: each refused, with every byte left as it was.
add_test(NAME bmx_lua_runner.stage_refuses_unrelated_destination COMMAND bmx_luau_tests --stage-regression
    unrelated-destination "${luau_runner_stage_scratch}-unrelated-destination")
# The fixture planted in the source plugin: refused before any copy folder exists.
add_test(NAME bmx_lua_runner.stage_refuses_planted_fixture COMMAND bmx_luau_tests --stage-regression
    planted-fixture "${luau_runner_stage_scratch}-planted-fixture")
# A fresh stage, a rerun and a dropped module: exactly the modules, the fixture and their manifest.
add_test(NAME bmx_lua_runner.stage_writes_exact_manifest COMMAND bmx_luau_tests --stage-regression
    exact-manifest "${luau_runner_stage_scratch}-exact-manifest")
add_test(NAME bmx_lua_runner.stage_writes_category_manifest COMMAND bmx_luau_tests --stage-regression
    category-manifest "${luau_runner_stage_scratch}-category-manifest")
add_test(NAME bmx_lua_runner.stage_writes_force_stage_manifest COMMAND bmx_luau_tests --stage-regression
    force-stage-manifest "${luau_runner_stage_scratch}-force-stage-manifest")
add_test(NAME bmx_lua_runner.stage_writes_floor_manifest COMMAND bmx_luau_tests --stage-regression
    floor-manifest "${luau_runner_stage_scratch}-floor-manifest")
set_tests_properties(bmx_lua_runner.stage_refuses_unrelated_destination bmx_lua_runner.stage_refuses_planted_fixture
    bmx_lua_runner.stage_writes_exact_manifest bmx_lua_runner.stage_writes_category_manifest
    bmx_lua_runner.stage_writes_force_stage_manifest bmx_lua_runner.stage_writes_floor_manifest PROPERTIES FIXTURES_REQUIRED bmx_lua_stage_regression)
set_tests_properties(bmx_lua_runner.stage_regression_reset bmx_lua_runner.stage_refuses_unrelated_destination
    bmx_lua_runner.stage_refuses_planted_fixture bmx_lua_runner.stage_writes_exact_manifest bmx_lua_runner.stage_writes_category_manifest
    bmx_lua_runner.stage_writes_force_stage_manifest bmx_lua_runner.stage_writes_floor_manifest PROPERTIES
    TIMEOUT 60 LABELS bmx_lua_runner)
