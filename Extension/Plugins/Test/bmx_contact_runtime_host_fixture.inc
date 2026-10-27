// Actual Host and Lua modules over constructed coordinator boundaries. The
// qualified Ride below exists only in this test package, never in the mod.
void bmx_lua_contacts_use_actual_decoder_and_force_modules() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin" / "plugin";
    const auto contents = [](const std::filesystem::path& path) {
        std::ifstream file(path, std::ios::binary);
        check(file.good(), "BMX contact regression source is available: " + path.string());
        return std::string(std::istreambuf_iterator<char>(file), {});
    };
    std::map<std::string, std::string> files{{manifest_file, manifest("")}};
    for (const auto* name : {"force_math.lua", "tire.lua", "brake.lua", "pump.lua", "force_solver.lua", "forces.lua",
            "lease_identity.lua", "catalog.lua", "input.lua", "ride_input_mapping.lua", "bike_geometry.lua",
            "frame_identity.lua", "contact_runtime.lua", "ride_inflight.lua", "ride_runtime.lua", "ride_runtime_tests.lua"})
        files[std::string("plugin/") + name] = contents(directory / name);

    const std::string inactive = "local ACTIVATION_QUALIFIED = false";
    auto qualified = files.at("plugin/ride_runtime.lua");
    const auto gate = qualified.find(inactive);
    check(gate != std::string::npos && qualified.find(inactive, gate + inactive.size()) == std::string::npos,
        "production Ride must retain exactly one inactive qualification gate");
    qualified.replace(gate, inactive.size(), "local ACTIVATION_QUALIFIED = true");
    files["plugin/ride_runtime_qualified_fixture.lua"] = std::move(qualified);
    check(contents(directory / "bike_runtime_core.lua").find("local RIDE_COMPOSITION_QUALIFIED=false") != std::string::npos,
        "production Core force composition remains inactive");

    files["plugin/main.lua"] = R"(
        -- Dependencies are warmed one module per call before their importers.
        local paths = {"./force_math", "./tire", "./brake", "./pump", "./force_solver", "./forces",
            "./lease_identity", "./catalog", "./input", "./ride_input_mapping", "./bike_geometry",
            "./frame_identity", "./contact_runtime", "./ride_inflight", "./ride_runtime", "./ride_runtime_qualified_fixture",
            "./ride_runtime_tests"}
        local loading, tests, job, complete = 1, nil, nil, false
        local completed_cases, completed_assertions = 0, 0
        reskate.on("tick", function()
            if complete then return end
            if loading <= #paths then
                local exports = require(paths[loading])
                if loading == #paths then tests = exports end
                loading += 1
                return
            end
            if not job then
                job = coroutine.create(function()
                    return tests.run(function(cases, assertions)
                        assert(cases == completed_cases + 1 and assertions > completed_assertions,
                            "contact case progress must advance exactly once")
                        completed_cases, completed_assertions = cases, assertions
                        coroutine.yield()
                    end)
                end)
            end
            local ok, result = coroutine.resume(job)
            assert(ok, result)
            if coroutine.status(job) ~= "dead" then return end
            complete = true
            assert(result.cases == 48 and result.assertions == 129,
                string.format("unexpected contact coverage: %s/%s", tostring(result.cases), tostring(result.assertions)))
            assert(completed_cases == result.cases and completed_assertions == result.assertions,
                "contact final coverage must match every yielded case")
            reskate.log("BMX Lua contacts: 48 cases, 129 assertions, constructed SDK boundaries")
        end)
    )";
    check(Limits{}.call_ms == 50 && Limits{}.tick_ms == 2,
        "contact Host regression uses unchanged default call and tick limits");
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-contact-runtime-tests", files)});
    running(host, "bmx-lua-contact-runtime-tests", environment);
    check(!environment.logged("BMX Lua contacts:"), "Contact suite does not execute during startup");
    // Seventeen cold imports, forty-eight completed case yields, one return.
    // No production limit is increased, and no assertion is skipped.
    for (unsigned tick = 0; tick < 66; ++tick) {
        environment.now += 1000.0 / 60.0;
        host.tick(1000.0 / 60.0);
        running(host, "bmx-lua-contact-runtime-tests", environment);
        if (tick < 65) check(!environment.logged("BMX Lua contacts:"), "Contact suite cannot complete before all forty-eight cases");
    }
    check(environment.logged("BMX Lua contacts: 48 cases, 129 assertions") &&
            environment.fake.calls.empty() && environment.fake.binds.empty() && environment.teleports.empty() &&
            !environment.rays && !environment.native_ray_casts && !environment.fake.batch_calls &&
            !environment.fake.body_prepares && !environment.fake.body_create_calls && !environment.fake.body_read_calls &&
            !environment.fake.body_submit_entries && !environment.fake.follow_reserves && !environment.fake.follow_publishes &&
            !environment.fake.input_pulse_requests && !environment.fake.native_action_requests && !environment.fake.native_recovery_requests,
        "Actual Lua contact coordinator modules complete without SDK gameplay requests\n" + environment.all());
    const auto completed = environment.all();
    ticks(host, environment, 2);
    running(host, "bmx-lua-contact-runtime-tests", environment);
    check(environment.all() == completed, "The contact coordinator suite runs only once");
    std::cout << environment.all();
}
