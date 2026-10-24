// Exact V2 entry through the real Host/API/storage; native routing facts are constructed.
// V1's fixture and its fifteen cases remain unchanged.
namespace passive_sync_routes_trial_test {
using dingosdk::Json;
using passive_sync_trial_test::Fixture;
using passive_sync_trial_test::contents;
constexpr const char* title = "Passive Sync Routes V2";
constexpr const char* key = "passive_sync_native_v2";

void button(Fixture& f, const char* widget) {
    f.environment.panels_open = true; f.environment.fake.focus_now.interface_open = true;
    f.environment.actions = {plugin_ui::Action{f.id, title, widget, false}};
    f.step();
}
Json flush(Fixture& f) {
    f.no_actuation(); f.host.apply({});
    check(f.environment.fake.calls == std::vector<std::string>{"entities clear " + f.id} &&
        f.environment.fake.released == std::vector<std::string>{f.id}, "V2 only expected owner teardown");
    const auto document = Json::parse(contents(f.storage()));
    check(document.dump().size() < 62000 && !document.contains(passive_sync_trial_test::key),
        "V2 keeps a bounded fresh namespace without rewriting V1");
    return document.at(key);
}
void copied_routing(const Json& actual, const dingosdk::body_sync_probe::Routing& expected) {
    check(actual.size() == 5 && actual.at("entries").get<std::uint32_t>() == expected.entries &&
        actual.at("other").get<std::uint32_t>() == expected.other &&
        actual.at("already_recorded").get<std::uint32_t>() == expected.already_recorded &&
        actual.at("expired_entries").get<std::uint32_t>() == expected.expired_entries,
        "V2 preserves all independent scalar routing counters");
    passive_sync_trial_test::copied_numbers(actual.at("matches"), expected.matches);
}
}

void the_tracked_passive_sync_routes_trial_copies_validated_route_counts() {
    using namespace passive_sync_routes_trial_test;
    namespace sync = dingosdk::body_sync_probe;
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "passive-sync-routes-trial";
    const std::map<std::string, std::string> exact{{manifest_file, contents(directory / manifest_file)},
        {"plugin/main.lua", contents(directory / "plugin" / "main.lua")}};
    check(check_package_files(directory).empty(), "required V2 routing fixture contains sandbox source only");
    check(title == std::string("Passive Sync Routes V2") && std::string_view(title).size() <= 24 &&
        exact.at("plugin/main.lua").find("LuaPassiveSyncProbe_20261024_v2") != std::string::npos &&
        exact.at("plugin/main.lua").find("a22f6ade-3380-41a0-99ed-45d3a5ed84ec") != std::string::npos,
        "V2 source uses its separately versioned page, package and run identity");
    const auto declaration = parse_manifest(exact.at(manifest_file));
    check(declaration.permissions == decltype(declaration.permissions){"world.physics", "world.physics.observe", "skater.read", "input", "menu", "storage"} &&
        declaration.side == Side::client && declaration.entry == "plugin/main.lua", "V2 adds no authority");
    for (const bool expired : {false, true}) {
        Fixture f(expired ? "routes-expired" : "routes-observed", exact);
        f.no_trial_calls(); button(f, "arm"); f.admit();
        auto& g = f.environment.fake;
        check(g.body_create_calls == 1 && g.body_read_calls == 1 && g.sync_probe_starts == 1 && g.sync_probe_polls == 1,
            "exact V2 entry admits one context body and immediate pending poll through actual APIs");
        // Deliberately inconsistent sums/order remain valid independent lower bounds.
        const sync::Routing pending{2, {7, 0, 4294967295U, 4}, 11, 25, 99};
        g.sync_probe.result.routing = pending; f.step();
        g.complete_sync_probe();
        auto& result = g.sync_probe.result;
        result.routing = {1, {3, 8, 5, 6}, 4294967295U, 12, 17};
        if (expired) {
            result.status = sync::Status::expired; result.observed_mask = 3;
            result.observed_epoch = {}; result.records[2] = {}; result.records[3] = {};
        }
        const auto history = result; f.step();
        check(g.sync_probe_polls == 3 && g.body_read_calls == 2 && g.body_release_calls == 1,
            "V2 terminal projection does not extend observation, polling or cleanup");
        // Constructed later backend mutation must not rewrite the already copied Lua ledger.
        result.routing.entries = 1234; result.routing.matches[0] = 5678;
        button(f, "arm"); button(f, "retry"); button(f, "stop"); f.admit(); f.step(2000);
        check(g.body_create_calls == 1 && g.sync_probe_starts == 1 && g.sync_probe_polls == 3 && g.body_release_calls == 1,
            "terminal V2 cannot reacquire, repoll or retry release");
        const auto ledger = flush(f);
        check(ledger.at("id").string() == "LuaPassiveSyncProbe_20261024_v2" &&
            ledger.at("run_id").string() == "a22f6ade-3380-41a0-99ed-45d3a5ed84ec" &&
            ledger.at("outcome").string() == (expired ? "expired" : "observed_matches") &&
            ledger.at("polls").size() == 3, "fresh V2 identity and terminal status remain honest");
        copied_routing(ledger.at("polls").at(0).at("routing"), sync::Routing{});
        copied_routing(ledger.at("polls").at(1).at("routing"), pending);
        copied_routing(ledger.at("polls").at(2).at("routing"), history.routing);
        copied_routing(ledger.at("last_probe").at("routing"), history.routing);
        copied_routing(ledger.at("terminal_probe").at("routing"), history.routing);
        passive_sync_trial_test::copied_probe(ledger.at("terminal_probe"), history);
        passive_sync_trial_test::honest_cleanup(ledger, true);
    }
    const std::vector<std::pair<std::string, std::string>> malformed{
        {"missing-routing", "r.routing=nil"}, {"missing-counter", "r.routing.entries=nil"},
        {"extra-field", "r.routing.unexpected=0"}, {"counter-type", "r.routing.entries='1'"},
        {"negative", "r.routing.other=-1"}, {"fraction", "r.routing.already_recorded=.5"},
        {"overflow", "r.routing.expired_entries=4294967296"}, {"nonfinite", "r.routing.entries=0/0"},
        {"matches-type", "r.routing.matches=false"}, {"matches-short", "r.routing.matches[4]=nil"},
        {"matches-long", "r.routing.matches[5]=0"}, {"matches-key", "r.routing.matches.extra=0"},
        {"matches-negative", "r.routing.matches[1]=-1"}, {"matches-overflow", "r.routing.matches[1]=4294967296"}
    };
    for (const auto& [name, mutation] : malformed) {
        // Fault-only factory: exact frozen source and actual opaque API call;
        // only returned routing facts are malformed before the real packed() runs.
        auto injected = exact;
        injected["plugin/frozen_entry.lua"] = "return function(reskate)\n" + exact.at("plugin/main.lua") + "\nend\n";
        injected["plugin/main.lua"] = R"(
            local api=table.clone(reskate);api.world=table.clone(reskate.world)
            api.world.physics=table.clone(reskate.world.physics)
            local original=reskate.world.physics.poll_sync_probe
            api.world.physics.poll_sync_probe=function(probe)
                local r,why=original(probe)
                if r then
        )" + mutation + R"(
                end
                return r,why
            end
            require("./frozen_entry")(api)
        )";
        Fixture f("routes-bad-" + name, injected);
        button(f, "arm"); f.admit();
        const auto& g = f.environment.fake;
        check(g.sync_probe_starts == 1 && g.sync_probe_polls == 1 && g.body_read_calls == 1 && g.body_release_calls == 1,
            "malformed route projection stops after one actual poll and one known-body release");
        const auto ledger = flush(f);
        check(ledger.at("stop_reason").string() == "malformed probe result" && ledger.at("polls").empty() &&
            !ledger.contains("last_probe") && !ledger.contains("terminal_probe") &&
            ledger.at("poll_refusal").at("detail").string() == "malformed copied probe facts",
            "strict V2 projection never persists malformed routing as usable observations");
        passive_sync_trial_test::honest_cleanup(ledger, true);
    }
    {
        auto denied = exact; auto permissions = Json::parse(denied.at(manifest_file));
        auto kept = Json::array();
        for (const auto& permission : permissions.at("permissions"))
            if (permission.string() != "world.physics.observe") kept.push_back(permission);
        permissions["permissions"] = std::move(kept); denied[manifest_file] = permissions.dump();
        Fixture f("routes-denied-observe", denied); button(f, "arm"); f.admit();
        const auto& g = f.environment.fake;
        check(g.body_create_calls == 1 && !g.sync_probe_starts && !g.sync_probe_polls && g.body_release_calls == 1,
            "actual API permission denial prevents V2 observer backend admission");
        const auto ledger = flush(f);
        check(!ledger.at("begin").at("pcall_ok").get<bool>() &&
            ledger.at("begin").at("detail").string().find("world.physics.observe") != std::string::npos &&
            !ledger.contains("last_probe") && !ledger.contains("terminal_probe"), "permission error remains an actual API fact");
        passive_sync_trial_test::honest_cleanup(ledger, true);
    }
    std::cout << "tracked passive sync routes V2: 17 constructed Host cases; copied lower-bound counters, zero actuation; no native invocation/consumption proof\n";
}
