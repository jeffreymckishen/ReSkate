// Actual Host and production Lua over constructed services. No native mutation.
void bmx_lua_current_recovery_keeps_cleanup_and_explicit_stock_return() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    for (const auto* name : {"equipment_transition.lua", "bike_admission.lua", "equipment_runtime.lua", "recovery.lua",
            "current_recovery.lua", "bike_runtime_core.lua", "bike_runtime.lua", "bike_geometry.lua",
            "core_ride_staging_tests.lua", "core_current_recovery_tests.lua"}) {
        std::ifstream file(directory / "plugin" / name, std::ios::binary);
        check(file.good(), std::string("Current recovery source is available: ") + name);
        files[std::string("plugin/") + name] = std::string(std::istreambuf_iterator<char>(file), {});
    }
    files["plugin/main.lua"] = R"(
        local modules={"./equipment_transition","./bike_admission","./equipment_runtime","./recovery","./current_recovery",
            "./bike_runtime_core","./bike_runtime","./bike_geometry","./core_ride_staging_tests","./core_current_recovery_tests"}
        local loaded,runner,done=0,nil,false
        reskate.on("tick",function()
            if done then return end
            if loaded<#modules then loaded+=1;require(modules[loaded]);return end
            runner=runner or require("./core_current_recovery_tests").new_runner()
            local out=runner:step()
            assert(out.native_actions==0 and out.game_evidence==false and out.total_cases==18)
            if out.done then
                assert(out.cases==18 and out.assertions>=50)
                done=true
                reskate.log(string.format("BMX current recovery: %d cases, %d assertions",out.cases,out.assertions))
            end
        end)
    )";
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({package("bmx-current-recovery-tests", files)});
    for (int tick=0;tick<32;++tick) { host.tick(1.0/60.0); running(host,"bmx-current-recovery-tests",environment); }
    check(environment.logged("BMX current recovery: 18 cases") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
        !environment.fake.input_pulse_requests && !environment.fake.input_pulse_reads && !environment.fake.input_pulse_cancels &&
        !environment.fake.input_pulse_acks && !environment.fake.native_action_requests && !environment.fake.native_recovery_requests &&
        !environment.fake.native_recovery_reads && !environment.fake.native_recovery_cancels && !environment.fake.native_recovery_acks &&
        !environment.fake.body_creates && !environment.fake.body_submissions && environment.teleports.empty() && !environment.rays,
        "Current recovery cases must use constructed services and zero Host Game effects\n" + environment.all());
    const auto complete=environment.all(); host.tick(1.0/60.0);
    check(environment.all()==complete,"Current recovery cases must run once");
    std::cout<<environment.all();
}
