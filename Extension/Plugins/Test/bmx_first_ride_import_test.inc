// Source-only addition for Extension/Plugins/Test/plugin_tests.cpp, inside its
// anonymous namespace after check/package/manifest/status_of are available.
// Not a standalone runner or translation unit. Main owns adoption/build/run.
// The caller supplies the sealed plugin/ directory and exact main.lua above.
void run_bmx_first_ride_import_fixture(const std::filesystem::path& plugin_directory,
    const std::string& import_entry) {
    namespace lease = dingosdk::input_lease;
    namespace capture = dingosdk::input_lease_capture;
    // A negative backend: every API returns unavailable and cannot mint a
    // handle, epoch, source observation, capture duty, body or owner fact.
    struct ImportGame final : Game {
        std::array<unsigned, 10> callbacks{};
        std::array<unsigned, 6> vm_cleanup{};
        unsigned owner_releases{};
        bool input_lease_request(std::uint64_t, std::uint32_t, lease::Handle&, lease::Reason& reason) override {
            ++callbacks[0]; reason = lease::Reason::unavailable; return false;
        }
        bool input_lease_read(std::uint64_t, lease::Handle, lease::Snapshot&, lease::Reason& reason) override {
            ++callbacks[1]; reason = lease::Reason::unavailable; return false;
        }
        bool input_lease_renew(std::uint64_t, lease::Handle, const lease::Snapshot&, lease::Reason& reason) override {
            ++callbacks[2]; reason = lease::Reason::unavailable; return false;
        }
        bool input_lease_release(std::uint64_t, lease::Handle, lease::Reason& reason) override {
            ++callbacks[3]; reason = lease::Reason::unavailable; return false;
        }
        bool input_lease_state(std::uint64_t, lease::Handle, lease::Receipt&, lease::Reason& reason) override {
            ++callbacks[4]; reason = lease::Reason::unavailable; return false;
        }
        bool input_lease_acknowledge(std::uint64_t, lease::Handle, lease::Reason& reason) override {
            ++callbacks[5]; reason = lease::Reason::unavailable; return false;
        }
        bool input_lease_capture_request(std::uint64_t, lease::Handle, const lease::Snapshot&, capture::Reason& reason) override {
            ++callbacks[6]; reason = capture::Reason::unavailable; return false;
        }
        bool input_lease_capture_state(std::uint64_t, lease::Handle, capture::Receipt&) override {
            ++callbacks[7]; return false;
        }
        bool input_lease_capture_release(std::uint64_t, lease::Handle) override { ++callbacks[8]; return false; }
        bool input_lease_capture_acknowledge(std::uint64_t, lease::Handle) override { ++callbacks[9]; return false; }
        void input_lease_release_all(std::uint64_t) override { ++vm_cleanup[0]; }
        void input_pulse_release_all(std::uint64_t) override { ++vm_cleanup[1]; }
        void input_trace_release_all(std::uint64_t) override { ++vm_cleanup[2]; }
        void native_recovery_release_all(std::uint64_t) override { ++vm_cleanup[3]; }
        void native_action_release_all(std::uint64_t) override { ++vm_cleanup[4]; }
        void body_release_all(std::uint64_t) override { ++vm_cleanup[5]; }
        void release(std::string_view) override { ++owner_releases; }
        bool no_api_callbacks() const {
            return std::all_of(callbacks.begin(), callbacks.end(), [](unsigned value) { return value == 0; });
        }
    };
    struct ImportEnvironment final : Environment {
        ImportGame fake;
        double now{1000.25};
        unsigned game_accesses{}, world_callbacks{}, console_callbacks{};
        std::vector<std::string> logs;
        std::vector<plugin_ui::Layer> layers;
        std::vector<plugin_ui::Panel> panels;
        std::vector<plugin_ui::PageEntry> pages;
        void log(LogLevel, std::string_view text) override { logs.emplace_back(text); }
        void console(std::string_view) override { ++console_callbacks; }
        double now_ms() override { return now; }
        std::filesystem::path storage_root() override { return scratch / "first-ride-import-storage"; }
        bool builtin_command(std::string_view) override { return false; }
        Game& game() override { ++game_accesses; return fake; }
        std::optional<SkaterState> skater() override { ++world_callbacks; return std::nullopt; }
        Teleport teleport(std::string_view, const Vec3&, float) override {
            ++world_callbacks; return Teleport::unavailable;
        }
        std::optional<Vec3> raycast(const Vec3&, const Vec3&) override { ++world_callbacks; return std::nullopt; }
        Game::CountedProbe raycast_bounded(const Vec3&, const Vec3&, unsigned) override { ++world_callbacks; return {}; }
        std::optional<ScoreState> score() override { ++world_callbacks; return std::nullopt; }
        std::optional<Vec3> world_to_screen(const Vec3&) override { ++world_callbacks; return std::nullopt; }
        void toast(std::string_view, LogLevel, std::string_view) override { ++world_callbacks; }
        bool ui_sound(std::string_view) override { ++world_callbacks; return false; }
        bool panels_shown() override { return true; }
        void publish_layers(std::vector<plugin_ui::Layer> value) override { layers = std::move(value); }
        void publish_panels(std::vector<plugin_ui::Panel> value) override { panels = std::move(value); }
        void publish_pages(std::vector<plugin_ui::PageEntry> value) override { pages = std::move(value); }
        bool logged(std::string_view part) const {
            return std::any_of(logs.begin(), logs.end(), [&](const auto& line) { return line.find(part) != std::string::npos; });
        }
        std::string all() const {
            std::string result; for (const auto& line : logs) result += line + "\n"; return result;
        }
    };
    const auto contents = [](const std::filesystem::path& path) {
        std::ifstream file(path, std::ios::binary);
        check(file.good(), "required first-ride promotion source: " + path.string());
        return std::string(std::istreambuf_iterator<char>(file), {});
    };
    const auto require_running = [](const Host& host, const std::string& id, const ImportEnvironment& environment) {
        const auto status = status_of(host, id);
        check(status.state == "running", id + ": " + status.state + ": " + status.reason + "\n" + environment.all());
        check(status.commands.empty(), "import fixture registers no console commands");
    };
    check(!import_entry.empty(), "exact inert import entry is required");
    check(Limits{}.call_ms == 50 && Limits{}.tick_ms == 2, "first-ride import fixture retains default Host budgets");
    for (const auto& permissions : {std::string{}, std::string(R"("input.lease","input.capture")")}) {
        const std::string id = permissions.empty() ? "bmx-first-ride-import-denied" : "bmx-first-ride-import-capable";
        const std::string control_id = id + "-control";
        // Keep the supplied construction/assertion body exact, but execute it
        // as a warm module only after six separate cold-import tick calls.
        std::map<std::string, std::string> files{{manifest_file, manifest(permissions)},
            {"plugin/first_ride_import_checks.lua", import_entry + "\nreturn true\n"}};
        files["plugin/main.lua"] = R"(
            local paths = {"./lease_identity", "./catalog", "./input", "./lease_source",
                "./ride_input_mapping", "./ride_input"}
            local loading, complete = 1, false
            reskate.on("tick", function()
                if complete then return end
                if loading <= #paths then
                    require(paths[loading])
                    loading += 1
                    return
                end
                complete = true
                assert(require("./first_ride_import_checks") == true)
            end)
        )";
        for (const auto* name : {"lease_identity.lua", "lease_source.lua", "ride_input_mapping.lua", "ride_input.lua", "input.lua", "catalog.lua"})
            files[std::string("plugin/") + name] = contents(plugin_directory / name);
        ImportEnvironment environment, control;
        Host host(environment, Side::client), baseline(control, Side::client);
        host.apply({package(id, files)});
        baseline.apply({script(control_id, "reskate.log('FIRST_RIDE_IMPORT_CONTROL_V1')", permissions)});
        require_running(host, id, environment);
        require_running(baseline, control_id, control);
        check(!environment.logged("FIRST_RIDE_IMPORT_CONSTRUCT_INERT_V1"), "construction is deferred until cold imports finish");
        check(environment.game_accesses == 0 && control.game_accesses == 0 && environment.world_callbacks == 0,
            "import-loader startup reaches no Game or world callback");
        check(environment.fake.no_api_callbacks(), "loader startup reaches none of the ten lease/capture callbacks");
        // Both Hosts see the same seven real ticks. Only the fixture imports
        // modules and constructs Lua objects; automatic Game polling is matched.
        for (unsigned tick = 0; tick != 7; ++tick) {
            environment.now += 16.125; control.now += 16.125;
            host.tick(16.125); baseline.tick(16.125);
            require_running(host, id, environment);
            require_running(baseline, control_id, control);
            check(environment.game_accesses == control.game_accesses && environment.world_callbacks == 0 &&
                environment.fake.no_api_callbacks() && environment.console_callbacks == 0,
                "cold imports and construction add no Game or API callback beyond the empty control");
            if (tick < 6) check(!environment.logged("FIRST_RIDE_IMPORT_CONSTRUCT_INERT_V1"),
                "construction cannot run before all six cold-import calls complete");
        }
        check(environment.logged("FIRST_RIDE_IMPORT_CONSTRUCT_INERT_V1"), "all actual-Host Lua status assertions complete\n" + environment.all());
        check(environment.fake.no_api_callbacks(), "construction never reaches any of the ten lease/capture callbacks");
        for (unsigned tick = 0; tick != 60; ++tick) {
            environment.now += 16.125; control.now += 16.125;
            host.tick(16.125); baseline.tick(16.125);
        }
        require_running(host, id, environment);
        require_running(baseline, control_id, control);
        check(environment.game_accesses == control.game_accesses && environment.world_callbacks == 0 &&
            environment.fake.no_api_callbacks() && environment.console_callbacks == 0,
            "idle Host ticks add only the same automatic Game polling as an empty control entry");
        check(environment.layers.empty() && environment.panels.empty() && environment.pages.empty(),
            "import-only entry registers no overlay or menu even while Host menu building is enabled");
        check(std::count_if(environment.logs.begin(), environment.logs.end(), [](const auto& line) {
            return line.find("FIRST_RIDE_IMPORT_CONSTRUCT_INERT_V1") != std::string::npos;
        }) == 1, "all construction and status assertions run exactly once across load and sixty idle ticks");
        host.apply({}); baseline.apply({});
        check(environment.fake.no_api_callbacks() && environment.world_callbacks == 0,
            "VM close does not turn inert Lua objects into native API requests");
        // Current Plugin::unload closes the VM, then ~Plugin calls close again;
        // all six release_all callbacks precede close's L_ test. Observe this
        // existing behavior; do not change SDK cleanup for an import fixture.
        check(environment.fake.vm_cleanup == control.fake.vm_cleanup &&
            std::all_of(environment.fake.vm_cleanup.begin(), environment.fake.vm_cleanup.end(),
                [](unsigned value) { return value == 2; }) &&
            environment.fake.owner_releases == 1 && control.fake.owner_releases == 1,
            "current Host/VM cleanup matches empty control separately from ten Lua API callbacks");
        check(!std::filesystem::exists(environment.storage_root() / id / "storage.json"),
            "inert construction, ticks and VM close create no plugin storage file");
    }
}
