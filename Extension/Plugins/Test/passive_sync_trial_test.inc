// Actual Host/VM/API/menu/storage regression for the required tracked Lua trial.
// FakeGame supplies constructed native samples, never retail observation proof.
namespace passive_sync_trial_test {
using dingosdk::Json;
constexpr const char* title = "Passive Sync Probe V1";
constexpr const char* key = "passive_sync_native_v1";

std::string contents(const std::filesystem::path& path) {
    std::ifstream file(path, std::ios::binary);
    check(file.good(), "required passive sync fixture: " + path.string());
    return std::string(std::istreambuf_iterator<char>(file), {});
}

struct Fixture {
    TestEnvironment environment;
    Host host;
    std::string id;
    Fixture(const std::string& suffix, const std::map<std::string, std::string>& files,
        bool prior = false, bool startup_refused = false)
        : host(environment, Side::client), id("passive-sync-" + suffix) {
        environment.local_skater = SkaterState{};
        environment.fake.focus_now = {true, true, true};
        check(!std::filesystem::exists(storage()), "each passive case requires fresh storage");
        if (prior) write(storage(), R"({"passive_sync_native_v1":{"prior":"unchanged"}})");
        host.set_level("sanvan");
        host.apply({package(id, files)});
        if (startup_refused) return;
        running(host, id, environment);
        environment.panels_open = true; environment.shown = id;
        step(0);
    }
    std::filesystem::path storage() { return environment.storage_root() / id / "storage.json"; }
    void step(double elapsed = 100) {
        environment.now += elapsed; host.tick(elapsed); running(host, id, environment);
    }
    void button(const char* widget) {
        environment.panels_open = true; environment.fake.focus_now.interface_open = true;
        environment.actions = {plugin_ui::Action{id, title, widget, false}};
        step(); // Real Host pages/actions rebuild at most once per 100ms.
    }
    void admit() {
        environment.panels_open = false; environment.fake.focus_now.interface_open = false;
        step();
    }
    std::string info(const char* label) const {
        for (const auto& panel : environment.panels)
            if (panel.plugin == id && panel.page && panel.title == title)
                for (const auto& widget : panel.widgets)
                    if (widget.kind == plugin_ui::Widget::Kind::info && widget.text == label) return widget.help;
        throw std::runtime_error(id + ": missing actual menu info " + label + "\n" + environment.all());
    }
    void no_actuation() const {
        const auto& g = environment.fake;
        check(!g.body_submit_entries && !g.body_submissions && !g.batch_calls &&
            !g.input_pulse_requests && !g.input_pulse_reads && !g.input_pulse_cancels && !g.input_pulse_acks &&
            !g.native_action_requests && !g.native_action_reads && !g.native_action_cancels && !g.native_action_acks &&
            !g.native_recovery_requests && !g.native_recovery_reads && !g.native_recovery_cancels && !g.native_recovery_acks &&
            g.calls.empty() && environment.teleports.empty() && !environment.rays,
            id + ": no body-submit ENTRY (including rejected/zero packets), actor action, or query is allowed");
    }
    void no_trial_calls() const {
        const auto& g = environment.fake;
        check(!g.body_create_calls && !g.body_read_calls && !g.body_release_calls &&
            !g.sync_probe_starts && !g.sync_probe_polls && g.owned.empty(), id + ": no trial backend admission");
        no_actuation();
    }
    Json flush() {
        no_actuation(); // Host owner teardown below is housekeeping, not a Lua admission.
        host.apply({});
        check(environment.fake.calls == std::vector<std::string>{"entities clear " + id} &&
            environment.fake.released == std::vector<std::string>{id}, id + ": only expected owner teardown");
        const auto document = Json::parse(contents(storage()));
        check(document.dump().size() < 62000, id + ": bounded actual persisted storage");
        return document.at(key);
    }
};

template<class Values> void copied_numbers(const Json& actual, const Values& expected) {
    check(actual.is_array() && actual.size() == expected.size(), "full copied numeric array");
    for (std::size_t i = 0; i < expected.size(); ++i)
        check(actual.at(i).get<double>() == static_cast<double>(expected[i]), "copied numeric element");
}
void copied_epoch(const Json& actual, const owned_body::Epoch& expected) {
    check(actual.size() == 3 && actual.at("serial").string() == std::to_string(expected.serial) &&
        actual.at("time").get<double>() == expected.time && actual.at("seconds").get<double>() == expected.seconds,
        "copied scalar epoch preserves uint64 string without raw body/world identity");
}
void copied_probe(const Json& actual, const dingosdk::body_sync_probe::Result& expected) {
    const auto status = expected.status == dingosdk::body_sync_probe::Status::observed ? "observed" :
        expected.status == dingosdk::body_sync_probe::Status::expired ? "expired" : "invalidated";
    check(actual.at("status").string() == status && actual.at("terminal").get<bool>() &&
        actual.at("observed_mask").get<unsigned>() == expected.observed_mask &&
        actual.at("rejected").get<unsigned>() == expected.rejected &&
        actual.at("dropped").get<unsigned>() == expected.dropped, "actual copied terminal status/counts");
    copied_epoch(actual.at("armed_epoch"), expected.armed_epoch);
    if (expected.status == dingosdk::body_sync_probe::Status::observed)
        copied_epoch(actual.at("observed_epoch"), expected.observed_epoch);
    else check(!actual.contains("observed_epoch"), "partial history has no fabricated full observation epoch");
    const auto& rows = actual.at("records");
    check(rows.size() == 4, "all four packet positions remain represented");
    unsigned mismatches = 0;
    for (std::size_t i = 0; i < expected.records.size(); ++i) {
        const auto& row = rows.at(i); const auto& native = expected.records[i];
        check(row.at("present").get<bool>() == native.present, "record presence preserved");
        if (!native.present) { check(row.size() == 1, "absent record is not zero-filled"); continue; }
        check(row.size() == 13 && row.at("pending_before").get<bool>() == native.pending_before &&
            row.at("pending_after").get<bool>() == native.pending_after &&
            row.at("transform_matches").get<bool>() == native.transform_matches &&
            row.at("before_flags").get<std::uint32_t>() == native.before_flags &&
            row.at("after_flags").get<std::uint32_t>() == native.after_flags, "full copied flags and booleans");
        copied_numbers(row.at("supplied"), native.supplied);
        copied_numbers(row.at("com_position"), native.com_position);
        copied_numbers(row.at("origin"), native.origin);
        copied_numbers(row.at("local_com"), native.local_com);
        copied_numbers(row.at("rotation"), native.rotation);
        copied_numbers(row.at("local_rotation"), native.local_rotation);
        copied_epoch(row.at("epoch"), native.epoch);
        if (!native.transform_matches) ++mismatches;
    }
    check(actual.at("mismatching_records").get<unsigned>() == mismatches, "mismatch count remains diagnostic");
}
void unchanged_history(const dingosdk::body_sync_probe::Result& a, const dingosdk::body_sync_probe::Result& b) {
    check(a.status == b.status && a.armed_epoch == b.armed_epoch && a.observed_epoch == b.observed_epoch &&
        a.observed_mask == b.observed_mask && a.rejected == b.rejected && a.dropped == b.dropped,
        "release/unload must not relabel immutable terminal history");
    for (std::size_t i = 0; i < a.records.size(); ++i) {
        const auto& x = a.records[i]; const auto& y = b.records[i];
        check(x.present == y.present && x.pending_before == y.pending_before && x.pending_after == y.pending_after &&
            x.transform_matches == y.transform_matches && x.before_flags == y.before_flags && x.after_flags == y.after_flags &&
            x.supplied == y.supplied && x.com_position == y.com_position && x.origin == y.origin && x.local_com == y.local_com &&
            x.rotation == y.rotation && x.local_rotation == y.local_rotation && x.epoch == y.epoch,
            "all terminal record fields survive owner cleanup");
    }
}
void honest_cleanup(const Json& ledger, bool accepted, bool unknown_allocation = false) {
    check(!ledger.at("native_consumed").get<bool>() && !ledger.at("follow_published").get<bool>() &&
        !ledger.at("park_observed").get<bool>() && !ledger.at("submitted_commands").get<unsigned>(),
        "diagnostic facts cannot become consumption/follow/park/force proof");
    check(ledger.at("creation_unknown").get<bool>() == unknown_allocation &&
        ledger.at("cleanup_unknown").get<bool>() == (!accepted || unknown_allocation), "cleanup uncertainty retained honestly");
    check(ledger.at("calls").at("store").get<unsigned>() <= 5, "bounded one-shot storage attempts");
}
}

void the_tracked_passive_sync_trial_runs_once_and_keeps_observation_separate() {
    using namespace passive_sync_trial_test;
    namespace sync = dingosdk::body_sync_probe;
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "passive-sync-trial";
    const std::map<std::string, std::string> exact{{manifest_file, contents(directory / manifest_file)},
        {"plugin/main.lua", contents(directory / "plugin" / "main.lua")}};
    check(check_package_files(directory).empty(), "required passive fixture is sandbox source only");
    const auto declaration = parse_manifest(exact.at(manifest_file));
    check(declaration.permissions == decltype(declaration.permissions){"world.physics", "world.physics.observe", "skater.read", "input", "menu", "storage"} &&
        declaration.side == Side::client && declaration.entry == "plugin/main.lua",
        "exact narrow manifest grants no lease/capture/pulse, pose, camera, or actor action authority");
    {
        Fixture f("inert", exact);
        f.environment.fake.focus_now.interface_open = false; // Usable focused gameplay, even while this test renders the menu.
        ticks(f.host, f.environment, 60); running(f.host, f.id, f.environment);
        check(f.info("Phase") == "idle", "actual exact fixture renders idle under normal Host budgets");
        check(std::find(f.environment.pages.begin(), f.environment.pages.end(), plugin_ui::PageEntry{f.id, title}) !=
            f.environment.pages.end(), "actual 21-byte page title registers");
        for (const auto* name : {"arm", "retry", "stop"}) {
            bool found = false;
            for (const auto& panel : f.environment.panels) for (const auto& widget : panel.widgets)
                found = found || (panel.plugin == f.id && widget.kind == plugin_ui::Widget::Kind::button && widget.id == name);
            check(found, "actual fixture exposes explicit one-shot controls");
        }
        f.no_trial_calls(); check(!std::filesystem::exists(f.storage()), "inert ticks do not store a ledger");
    }
    {
        Fixture f("prior", exact, true);
        const auto prior = contents(f.storage());
        check(f.info("Phase") == "existing storage", "prior ledger refuses the exact entry before Arm");
        f.button("arm"); f.admit(); f.step(120000); f.no_trial_calls();
        f.host.apply({});
        check(contents(f.storage()) == prior, "existing trial ledger must remain byte-exact");
    }
    // Real production permission enforcement; no C++ fake permission validator.
    for (const auto* missing : {"menu", "storage", "world.physics", "world.physics.observe"}) {
        auto denied = exact;
        auto permissions = Json::parse(denied.at(manifest_file));
        auto kept = Json::array();
        for (const auto& permission : permissions.at("permissions")) if (permission.string() != missing) kept.push_back(permission);
        permissions["permissions"] = std::move(kept); denied[manifest_file] = permissions.dump();
        const bool menu_denied = std::string_view(missing) == "menu";
        Fixture f("denied-" + std::string(missing), denied, false, menu_denied);
        if (menu_denied) {
            const auto status = status_of(f.host, f.id);
            check(status.state == "stopped" && status.reason == "plugin/main.lua raised an error as it ran" &&
                f.environment.logged("reskate.menu.page needs the \"menu\" permission in reskate-plugin.json"),
                "startup refusal uses generic Host status and precise fresh environment log separately");
            check(!f.environment.fake.body_create_calls && !f.environment.fake.sync_probe_starts &&
                !f.environment.fake.body_submit_entries, "menu denial never admits a native body");
            continue;
        }
        f.no_trial_calls(); f.button("arm"); f.admit();
        if (std::string_view(missing) == "storage") {
            f.no_trial_calls(); f.host.apply({});
            check(!std::filesystem::exists(f.storage()), "denied storage.get refuses admission and does not write");
        } else {
            check(!f.environment.fake.sync_probe_starts && !f.environment.fake.sync_probe_polls,
                "missing physics/observe permission never reaches observer backend");
            const bool observe_denied = std::string_view(missing) == "world.physics.observe";
            check(f.environment.fake.body_create_calls == (observe_denied ? 1u : 0u) &&
                f.environment.fake.body_release_calls == (observe_denied ? 1u : 0u),
                "observe denial releases its one known body; physics denial never enters create backend");
            const auto ledger = f.flush();
            if (observe_denied) {
                check(!ledger.at("begin").at("pcall_ok").get<bool>() &&
                    ledger.at("begin").at("detail").string().find("world.physics.observe") != std::string::npos,
                    "actual caught observe permission error remains in ledger");
                honest_cleanup(ledger, true);
            } else honest_cleanup(ledger, false, true);
        }
    }
    {
        Fixture f("two-preallocation-refusals", exact);
        auto& g = f.environment.fake;
        g.test_body_create_refusal = "body_preallocation_unavailable";
        f.button("arm"); f.step(7000); check(!g.body_create_calls, "open menu cannot create before either attempt");
        f.admit(); check(g.body_create_calls == 1 && !g.body_creates, "first exact refusal allocates no body");
        for (unsigned i = 0; i < 5; ++i) f.step();
        check(g.body_create_calls == 1, "ticks never auto-retry preallocation");
        f.button("retry"); f.admit();
        check(g.body_create_calls == 2 && !g.body_creates && !g.body_read_calls &&
            !g.sync_probe_starts && !g.sync_probe_polls && !g.body_release_calls, "second exact refusal stops before any body/probe exists");
        f.button("retry"); f.button("arm"); f.button("stop"); f.admit(); f.step(120000);
        check(g.body_create_calls == 2, "no third create after second exact known refusal");
        const auto ledger = f.flush();
        check(ledger.at("phase").string() == "stopped" && !ledger.at("creation_unknown").get<bool>() &&
            !ledger.at("cleanup_unknown").get<bool>() && !ledger.at("body_handle_retained").get<bool>() &&
            ledger.at("creates").size() == 2 && ledger.at("calls").at("create").get<unsigned>() == 2 &&
            ledger.at("stop_reason").string() == "second known preallocation refusal; no body allocated",
            "P2 regression: second exact preallocation refusal is known no-allocation, never cleanup-unknown");
    }
    {
        // Fault-only variant: the exact frozen body is a module factory parameterized
        // by reskate. Only storage.set is replaced; all other APIs and menu limits
        // remain production Host implementations. This is not the global-entry case.
        auto injected = exact;
        injected["plugin/frozen_entry.lua"] = "return function(reskate)\n" + exact.at("plugin/main.lua") + "\nend\n";
        injected["plugin/main.lua"] = R"(
            local api=table.clone(reskate)
            api.storage={get=reskate.storage.get,set=function() error(string.rep("E",300),0) end}
            require("./frozen_entry")(api)
        )";
        Fixture f("long-storage-error", injected);
        f.button("arm");
        check(f.info("Phase") == "armed" && f.info("Detail") == "storage cache refused: " + std::string(177, 'E'),
            "P2 regression: real menu renders exactly 200 bytes from longer storage error");
        f.step(); f.button("stop"); f.step();
        check(f.info("Phase") == "stopped" && f.info("Detail").size() == 200 &&
            !f.environment.logged("the page Passive Sync Probe V1:") && !f.environment.logged("an info line's value"),
            "long constructed storage error never becomes a real UI argument failure");
        f.no_trial_calls(); f.host.apply({});
        check(!std::filesystem::exists(f.storage()), "constructed failing set cannot claim persisted storage");
    }
    // Actual opaque APIs marshal these constructed C++ Result values. No Lua
    // positive probe table, actor packet, native dispatch, or mount is fabricated.
    for (unsigned scenario = 0; scenario < 5; ++scenario) {
        Fixture f("terminal-" + std::to_string(scenario), exact);
        auto& g = f.environment.fake;
        f.button("arm"); f.step(7000); check(!g.body_create_calls, "explicit Arm waits for menu closure");
        f.admit();
        check(g.body_create_calls == 1 && g.body_creates == 1 && g.body_read_calls == 1 &&
            g.sync_probe_starts == 1 && g.sync_probe_polls == 1, "one capsule, measured read, opaque probe, immediate pending poll");
        f.step(99); check(g.sync_probe_polls == 1, "pending poll interval remains at least 100ms");
        g.complete_sync_probe();
        auto& result = g.sync_probe.result;
        if (scenario == 1) result.records[0].transform_matches = false;
        if (scenario == 2 || scenario == 3) {
            result.status = scenario == 2 ? sync::Status::expired : sync::Status::invalidated;
            result.observed_mask = 3; result.observed_epoch = {}; result.records[2] = {}; result.records[3] = {};
        }
        if (scenario == 4) g.test_body_release_refused = true;
        const auto history = result;
        f.step(1);
        check(g.body_read_calls == 2 && g.sync_probe_starts == 1 && g.sync_probe_polls == 2 &&
            g.body_release_calls == 1, "terminal result triggers one final read and one release attempt");
        check(g.owned.begin()->second.released == (scenario != 4), "release refusal leaves actual fake body retained before owner teardown");
        f.button("arm"); f.button("retry"); f.button("stop"); f.admit(); f.step(2000);
        check(g.body_create_calls == 1 && g.body_read_calls == 2 && g.sync_probe_starts == 1 &&
            g.sync_probe_polls == 2 && g.body_release_calls == 1, "terminal history cannot reacquire, repoll or retry release");
        const auto ledger = f.flush();
        const auto outcome = scenario == 1 ? "observed_with_mismatch" : scenario == 2 ? "expired" :
            scenario == 3 ? "invalidated" : "observed_matches";
        check(ledger.at("outcome").string() == outcome && ledger.at("polls").size() == 2 &&
            ledger.at("calls").at("create").get<unsigned>() == 1 && ledger.at("calls").at("read").get<unsigned>() == 2 &&
            ledger.at("calls").at("begin").get<unsigned>() == 1 && ledger.at("calls").at("poll").get<unsigned>() == 2 &&
            ledger.at("calls").at("release").get<unsigned>() == 1, "persisted outcome and exact calls retain one-shot history");
        copied_probe(ledger.at("terminal_probe"), history); copied_probe(ledger.at("last_probe"), history);
        unchanged_history(history, g.sync_probe.result);
        check(ledger.at("initial_sample").at("serial").string() == "100" &&
            ledger.at("final_sample").at("serial").string() == "9007199254740994" &&
            !ledger.at("initial_sample").contains("epoch") && !ledger.at("final_sample").contains("epoch"),
            "sample data remains copied scalars, separate from fresh opaque authority");
        check(ledger.at("release").at("accepted").get<bool>() == (scenario != 4) &&
            ledger.at("body_handle_retained").get<bool>() == (scenario == 4), "release acceptance and retained cleanup are distinct");
        honest_cleanup(ledger, scenario != 4);
    }
    {
        Fixture f("unknown-create", exact);
        f.environment.fake.test_body_create_refusal = "constructed opaque allocation uncertainty";
        f.button("arm"); f.admit(); f.button("retry"); f.button("arm"); f.admit();
        check(f.environment.fake.body_create_calls == 1 && !f.environment.fake.body_creates &&
            !f.environment.fake.body_release_calls && !f.environment.fake.sync_probe_starts, "unknown create cannot allocate/retry a second body or invent a release handle");
        const auto ledger = f.flush(); honest_cleanup(ledger, false, true);
    }
    {
        Fixture f("pending-watchdog", exact);
        f.button("arm"); f.admit(); f.step(1500);
        check(f.environment.fake.sync_probe_polls == 1 && f.environment.fake.body_release_calls == 1,
            "1.5-second delivery watchdog stops before a late poll without changing native expiry");
        const auto ledger = f.flush();
        check(ledger.at("stop_reason").string() == "probe delivery watchdog; SDK limit remains one second" &&
            !ledger.contains("terminal_probe"), "watchdog never fabricates terminal probe history");
        honest_cleanup(ledger, true);
    }
    std::cout << "tracked passive sync trial: 15 constructed Host cases; actual VM/menu/API/storage, zero body-submit entries; no native gameplay proof\n";
}
