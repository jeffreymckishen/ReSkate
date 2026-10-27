// This opt-in fixture loads the operator's reviewed package through the actual
// sandbox Host. Only FakeGame answers services; no native provider is linked in.
namespace {
constexpr const char* hop_inert_variable = "RESKATE_HOP_INERT_FIXTURE";
constexpr const char* hop_inert_id = "BMX_Hop_Trial_warmup-p0-20261027-v1";
constexpr const char* hop_inert_directory = R"(E:\RESKATE DEV\warmup-hop-validation-20261027-v1\runtime\BMX_Hop_Trial_warmup-p0-20261027-v1)";
constexpr const char* hop_package_sha256 = "0f26f3780ec1104c94799a61cd5ddadd6b1d19fd247313adf2490b75f41e31fe";
constexpr const char* hop_files_sha256 = "bbf70085a922db639a7350587b82645a2f208f6855a8c4ff4357f9ccc3c0fc41";

std::optional<std::string> hop_inert_selection() {
#ifdef _WIN32
    char* raw{};
    std::size_t size{};
    const auto result = _dupenv_s(&raw, &size, hop_inert_variable);
    const std::unique_ptr<char, decltype(&std::free)> value(raw, &std::free);
    check(result == 0, "Could not read the hop fixture selector");
    if (!value) return std::nullopt;
    return std::string(value.get());
#else
    const auto* value = std::getenv(hop_inert_variable);
    return value ? std::optional<std::string>(value) : std::nullopt;
#endif
}
std::string hop_inert_read(const std::filesystem::path& path) {
    check(std::filesystem::is_regular_file(path) && std::filesystem::file_size(path) <= 1024 * 1024,
        "Missing or oversized hop fixture metadata: " + path.string());
    std::ifstream input(path, std::ios::binary);
    check(input.good(), "Cannot read hop fixture metadata: " + path.string());
    const std::string text(std::istreambuf_iterator<char>(input), {});
    check(!input.bad(), "Failed reading hop fixture metadata: " + path.string());
    return text;
}
std::string hop_inert_lower_hash(std::string value) {
    for (auto& c : value) if (c >= 'A' && c <= 'F') c = static_cast<char>(c + ('a' - 'A'));
    return value;
}
void hop_inert_verify(const std::filesystem::path& directory) {
    check(directory.is_absolute() && directory.lexically_normal() == std::filesystem::path(hop_inert_directory).lexically_normal(),
        "The hop fixture selector must name the exact reviewed runtime72 directory");
    check(std::filesystem::is_directory(directory) && !std::filesystem::is_symlink(std::filesystem::symlink_status(directory)),
        "The selected hop package is absent or is a symlink; a supplied fixture never skips");
    const auto seal = directory.parent_path();
    check(dingosdk::launcher::sha256_file(seal / "PACKAGE.json") == hop_package_sha256 &&
        dingosdk::launcher::sha256_file(seal / "FILES.json") == hop_files_sha256,
        "The selected hop package's reviewed external seal changed");
    const auto package = dingosdk::Json::parse(hop_inert_read(seal / "PACKAGE.json"));
    check(package.at("schema").get<int>() == 1 && package.at("files").get<int>() == 72 &&
        package.at("namespace").get<std::string>() == hop_inert_id &&
        package.at("run_id").get<std::string>() == "warmup-p0-20261027-v1" &&
        package.at("review_id").get<std::string>() == "root-fd9c45ae-20261027-p0-v1" &&
        package.at("phase").get<std::string>() == "P0" &&
        package.at("canonical_source").get<std::string>() == "062db162248d6b21c686f588924e0abc5954e99c" &&
        package.at("stage_source").get<std::string>() == "fd9c45aee7a84912d26d670cd6a1733b74068156",
        "The hop package identity does not match this fixture");
    const auto files = dingosdk::Json::parse(hop_inert_read(seal / "FILES.json"));
    check(files.is_array() && files.size() == 72, "The hop runtime seal must contain exactly 72 files");
    std::set<std::string> expected;
    for (const auto& row : files) {
        const auto name = row.at("path").get<std::string>();
        check(!name.empty() && safe_relative_path(name) == name && expected.insert(name).second,
            "Invalid or duplicate path in the reviewed hop seal");
        const auto path = directory / name;
        check(std::filesystem::is_regular_file(path) && !std::filesystem::is_symlink(std::filesystem::symlink_status(path)) &&
            std::filesystem::file_size(path) == row.at("bytes").get<std::uintmax_t>() &&
            dingosdk::launcher::sha256_file(path) == hop_inert_lower_hash(row.at("sha256").get<std::string>()),
            "The selected hop runtime file is absent or changed: " + name);
    }
    std::set<std::string> actual;
    for (const auto& entry : std::filesystem::recursive_directory_iterator(directory)) {
        check(!entry.is_symlink(), "The selected hop package contains a symlink");
        if (entry.is_directory()) continue;
        check(entry.is_regular_file(), "The selected hop package contains a non-regular file");
        actual.insert(entry.path().lexically_relative(directory).generic_string());
    }
    check(actual == expected, "The selected hop package has extra or missing files");
    check(check_package_files(directory).empty(), "The selected hop fixture must remain a source-only sandbox package");
    const auto manifest = parse_manifest(hop_inert_read(directory / manifest_file));
    const std::set<std::string, std::less<>> permissions{
        "input", "input.control", "input.lease", "input.capture", "skater.read", "skater.animation", "menu", "storage", "overlay",
        "board", "world.physics", "world.physics.follow", "world.entities", "world.raycast"};
    check(manifest.api == 1 && manifest.entry == "plugin/main.lua" && manifest.side == Side::client &&
        manifest.permissions == permissions, "The sealed hop manifest's actual permissions or entry changed");
}
void hop_inert_no_control(const TestEnvironment& environment, bool shutdown = false) {
    const auto& game = environment.fake;
    check(!game.body_prepares && !game.body_create_calls && !game.body_creates && !game.body_read_calls &&
        !game.body_release_calls && !game.body_submit_entries && !game.body_submissions && !game.body_receipt_calls &&
        !game.body_acknowledge_calls && game.owned.empty() && !game.body_command_sequence,
        "Hop bootstrap reached prepare, body, force-command or receipt services before Start");
    check(!game.follow_reserves && !game.follow_publishes && !game.follow_reads && !game.follow_stops && !game.follow_acks &&
        !game.follow_renewals && !game.follow_lease_reads && !game.batch_calls && !game.sync_probe_starts &&
        !game.sync_probe_polls && !game.motion_refresh_starts && !game.motion_refresh_polls && !game.motion_refresh_cancels,
        "Hop bootstrap reached Follow or native observation services before Start");
    check(!game.input_lease_calls && !game.input_capture_calls && !game.game_filter_calls &&
        !game.input_pulse_requests && !game.input_pulse_reads && !game.input_pulse_cancels && !game.input_pulse_acks &&
        !game.input_trace_requests && !game.input_trace_reads && !game.input_trace_stops && !game.input_trace_acks &&
        !game.native_action_requests && !game.native_action_reads && !game.native_action_cancels && !game.native_action_acks &&
        !game.native_recovery_requests && !game.native_recovery_reads && !game.native_recovery_cancels && !game.native_recovery_acks,
        "Hop bootstrap reached input, equipment or recovery services before Start");
    const std::vector<std::string> framework_calls = shutdown
        ? std::vector<std::string>{std::string("entities clear ") + hop_inert_id} : std::vector<std::string>{};
    check(game.calls == framework_calls && game.binds.empty() && game.entities.empty() && !game.entity_remove_calls &&
        game.presses.empty() && !game.probes && !game.world_picks && !game.native_casts &&
        environment.teleports.empty() && !environment.rays && !environment.native_ray_casts,
        "Hop bootstrap reached pose, legacy control, entity or world services before Start");
#ifdef DINGOSDK_BODY_REACTIVATION_QUALIFICATION
    check(!game.reactivation_begins && !game.reactivation_polls && !game.reactivation_provider_calls,
        "Hop bootstrap reached the private reactivation probe before Start");
#endif
}
void hop_inert_ready_ui(const TestEnvironment& environment, bool menu) {
    const auto layer = std::find_if(environment.layers.begin(), environment.layers.end(), [](const auto& row) {
        return row.plugin == hop_inert_id;
    });
    check(layer != environment.layers.end() && layer->shapes.size() == 2,
        "The exact hop entry must draw its two cached operator cues");
    check(std::any_of(layer->shapes.begin(), layer->shapes.end(), [](const auto& shape) {
        return shape.kind == plugin_ui::Shape::Kind::text && shape.text == "BMX trial READY / start once in menu";
    }), "The exact hop entry did not finish inert imports/construction and show READY");
    check(std::any_of(layer->shapes.begin(), layer->shapes.end(), [](const auto& shape) {
        return shape.kind == plugin_ui::Shape::Kind::text &&
            shape.text == "Sampled window unknown / evidence cache pending / unqualified";
    }), "The READY cue must not imply native readiness or qualification");
    check(std::find(environment.pages.begin(), environment.pages.end(),
        plugin_ui::PageEntry{hop_inert_id, "Private BMX hop trial"}) != environment.pages.end(),
        "The reviewed hop page must register within the real Host title bound");
    if (!menu) return;
    const auto page = std::find_if(environment.panels.begin(), environment.panels.end(), [](const auto& row) {
        return row.plugin == hop_inert_id && row.page && row.title == "Private BMX hop trial";
    });
    check(page != environment.panels.end(), "The reviewed hop menu must build under the real Host");
    const auto note = [&](std::string_view text) {
        return std::any_of(page->widgets.begin(), page->widgets.end(), [&](const auto& widget) {
            return widget.kind == plugin_ui::Widget::Kind::note && widget.text == text;
        });
    };
    check(note("Ready for one explicit P0 start."), "The hop page must affirm preparation finished without Start");
    check(note("Phase P0 / run warmup-p0-20261027-v1. One mount attempt; no automatic hop."),
        "The READY/start-once menu must be bound to the exact reviewed run");
    check(note("Lifecycle: idle. Cleanup continues after driving stops."), "Pre-Start lifecycle must remain idle");
    check(std::count_if(page->widgets.begin(), page->widgets.end(), [](const auto& widget) {
        return widget.kind == plugin_ui::Widget::Kind::button && widget.id == "hop-trial-start" && widget.text == "Start P0 once";
    }) == 1, "The reviewed hop page must expose exactly one explicit Start P0 once control");
    check(std::count_if(page->widgets.begin(), page->widgets.end(), [](const auto& widget) {
        return widget.kind == plugin_ui::Widget::Kind::button && widget.id == "hop-trial-stop" && widget.text == "Stop trial";
    }) == 1, "The reviewed hop page must retain its explicit Stop control");
}
void hop_inert_shutdown(Host& host, TestEnvironment& environment, const std::filesystem::path& storage) {
    auto& game = environment.fake;
    check(game.input_pulse_releases.empty() && game.input_trace_releases.empty() && game.native_recovery_releases.empty() &&
        game.native_action_releases.empty() && game.body_releases.empty() && game.release_order.empty() && game.released.empty(),
        "Pre-Start hop bootstrap must not have closed an owner");
    host.shutdown();
    check(host.status().empty(), "Explicit idle shutdown must remove the hop plugin");
    hop_inert_no_control(environment, true);
    // Plugin::unload closes the VM, then its destructor repeats idempotent close.
    // Host::unload calls Game::release once; the fake logs one entity-clear there.
    check(game.body_releases.size() == 2 && game.body_releases.front() != 0,
        "Idle shutdown must retain the two expected framework close receipts");
    const auto owner = game.body_releases.front();
    const std::vector<std::uint64_t> owners(2, owner);
    check(game.body_releases == owners && game.input_pulse_releases == owners && game.input_trace_releases == owners &&
        game.native_recovery_releases == owners && game.native_action_releases == owners &&
        game.released == std::vector<std::string>{hop_inert_id} && !game.follow_closes && !game.follow_host_cleanups,
        "Idle shutdown must only close the same constructed owner and release its plugin once");
    const std::vector<std::pair<std::uint64_t, std::string>> order{
        {owner, "recovery"}, {owner, "equipment"}, {owner, "body"},
        {owner, "recovery"}, {owner, "equipment"}, {owner, "body"}};
    check(game.release_order == order, "Idle framework close must not hide an acquired input or Follow duty");
    // The real entry deliberately preserves unflushed idle evidence on unload.
    // This diagnostic is not a mount ledger or a successful native cleanup receipt.
    const auto document = dingosdk::Json::parse(hop_inert_read(storage));
    constexpr const char* key = "hop.warmup-p0-20261027-v1.incomplete";
    check(document.is_object() && document.size() == 1 && document.contains(key),
        "Idle unload must persist only the exact run's incomplete diagnostic");
    const auto& record = document.at(key);
    check(record.at("schema").get<int>() == 1 && record.at("kind").get<std::string>() == "hop-trial-evidence" &&
        record.at("run_id").get<std::string>() == "warmup-p0-20261027-v1" &&
        !record.at("complete").get<bool>() && record.at("interrupted").get<bool>() &&
        record.at("emergency_attempted").get<bool>() && !record.at("final_snapshot_unavailable").get<bool>() &&
        record.at("observation_loss").get<bool>() && record.at("unqualified").get<bool>() &&
        record.at("stop_requested").get<bool>() && !record.at("storage_fault").get<bool>() &&
        record.at("first_fault").get<std::string>() == "explicit_unload_incomplete" &&
        !record.at("native_qualified").get<bool>() && !record.at("native_retirement_known").get<bool>() &&
        record.at("storage_scope").get<std::string>() == "Host cache acceptance only; disk durability unobserved.",
        "Idle unload diagnostic must preserve interruption and native uncertainty");
    check(record.at("chunks").get<int>() == 0 && record.at("stored_rows").get<int>() == 0 && record.at("dropped").get<int>() == 0 &&
        !record.at("unresolved_debt").get<bool>() && !record.at("cleanup_unknown_seen").get<bool>() &&
        !record.at("board_restore_unresolved").get<bool>() && !record.at("pose_release_unresolved").get<bool>(),
        "Idle unload must not invent persisted activity or acquired native cleanup debt");
    const auto& latest = record.at("latest");
    check(latest.at("phase").get<std::string>() == "done" && latest.at("unloaded").get<bool>() &&
        latest.at("detail").get<std::string>() == "unload before startup; no game authority acquired" &&
        latest.at("stock_toggle_blocked").get<bool>() && !latest.at("bike_authority").get<bool>() &&
        !latest.at("cleanup_pending").get<bool>() && !latest.at("cleanup_unknown").get<bool>(),
        "Idle unload must retain the facade's actual inactive final snapshot");
    for (const auto* field : {"stop_latched", "bike_cleanup_complete", "native_preparation", "body", "follow", "receipt", "source", "ride", "mounted_pose"}) {
        check(!latest.contains(field), std::string("Idle fallback must not synthesize native lifecycle evidence: ") + field);
    }
}
void the_sealed_private_hop_fixture_loads_inert_when_selected() {
    const auto selected = hop_inert_selection();
    if (!selected) {
        std::cout << "skipped sealed private hop Host inert-load: RESKATE_HOP_INERT_FIXTURE is absent; no bootstrap proof\n";
        return;
    }
    const std::filesystem::path directory(*selected);
    hop_inert_verify(directory);
    TestEnvironment environment;
    // Ready constructed stock facts make accidental auto-admission observable.
    // The exact package still owns its real permissions, module loader and API.
    environment.local_skater = SkaterState{};
    environment.fake.state = 100;
    environment.fake.pad = PadInput{};
    environment.fake.input_allowed_now = true;
    environment.fake.telemetry = SkaterTelemetry{};
    environment.fake.telemetry->skater = true;
    environment.fake.telemetry->physics_state = 100;
    environment.fake.telemetry->watch.valid = true;
    environment.fake.telemetry->watch.ragdoll_known = true;
    environment.fake.telemetry->watch.state = 100;
    environment.fake.focus_now = {true, true, true};
    environment.fake.menu_now.known = true;
    environment.fake.menu_now.open = true;
    environment.panels_open = true;
    environment.shown = hop_inert_id;
    const auto storage = environment.storage_root() / hop_inert_id / "storage.json";
    check(!std::filesystem::exists(storage), "The selected hop Host test requires fresh isolated storage");
    // Root's reviewed launcher setting is 6 ms; the normal 50 ms callback cap,
    // 64 MiB heap and three-window enforcement are not relaxed for this test.
    const auto limits = game_limits(6);
    check(limits.tick_ms == 6 && limits.call_ms == 50 && limits.unload_ms == 20 && limits.memory == (64u << 20) && limits.over_windows == 3,
        "The hop Host test must use the reviewed game's ordinary configured limits");
    Host host(environment, Side::client, limits);
    host.set_level("constructed_hop_stock_level");
    host.apply({{hop_inert_id, directory, hop_files_sha256, {}}});
    running(host, hop_inert_id, environment);
    hop_inert_no_control(environment);
    const auto advance = [&](int count) {
        for (int tick = 0; tick < count; ++tick) {
            ticks(host, environment, 1);
            running(host, hop_inert_id, environment);
            hop_inert_no_control(environment);
            check(environment.actions.empty(), "The inert-load test must never dispatch a Start or Stop action");
            check(!std::filesystem::exists(storage), "Pre-Start hop ticks must not persist an attempt or evidence ledger");
        }
    };
    advance(60); // Cold module loading and the first real menu build.
    hop_inert_ready_ui(environment, true);
    for (const bool open : {false, true, false}) {
        environment.panels_open = open;
        environment.fake.focus_now.interface_open = open;
        environment.fake.menu_now.open = open;
        advance(120);
        hop_inert_ready_ui(environment, open);
    }
    environment.panels_open = true;
    environment.fake.focus_now.interface_open = true;
    environment.fake.menu_now.known = true;
    environment.fake.menu_now.open = true;
    advance(12); // Real menu cadence is 100 ms, not every Host tick.
    hop_inert_ready_ui(environment, true);
    hop_inert_shutdown(host, environment, storage);
    hop_inert_verify(directory); // Reject a fixture changed while the Host read it.
    std::cout << "sealed private hop Host inert-load PASS: run=warmup-p0-20261027-v1 phase=P0 files=72 "
        "ticks=432 tick_ms=6 call_ms=50; READY/start-once/Lifecycle idle; 0 native-control Game entries; "
        "idle shutdown checked with only its incomplete unqualified diagnostic and expected framework cleanup; "
        "Start UNDISPATCHED, native/game qualification UNRUN\n";
    // The explicit shutdown cleared entries; the Host destructor has no owner left to unload.
}
} // namespace
