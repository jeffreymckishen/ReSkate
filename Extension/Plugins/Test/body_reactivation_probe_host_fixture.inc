// Actual Host/API checks over constructed provider facts. Pure FrozenArm cases
// execute shared bookkeeping, not RealGame environment parsing/path validation.
// No case is native reactivation, cleanup, contact or Follow qualification.
namespace body_reactivation_host_test {
void no_other_authority(const TestEnvironment& e) {
    const auto& g = e.fake;
    check(!g.body_submit_entries && !g.body_submissions && !g.batch_calls && !g.native_casts &&
        !g.input_pulse_requests && !g.native_action_requests && !g.native_recovery_requests &&
        !g.follow_reserves && !g.follow_publishes && !g.follow_reads && !g.follow_stops && !g.follow_acks &&
        !g.follow_renewals && !g.follow_lease_reads && e.teleports.empty() && !e.rays && g.binds.empty(),
        "reactivation fixture reached ordinary command, Follow, input, query or actor authority");
}
#ifdef DINGOSDK_BODY_REACTIVATION_QUALIFICATION
namespace r = dingosdk::body_reactivation_probe;
const std::string permissions = R"("world.physics","world.physics.qualify_body_reactivation")";
const std::string body_setup = R"(
    local P=reskate.world.physics;local v=vector.create
    local body=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
        capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
)";
r::LaunchArmValues launch_values(const Candidate& candidate) {
    r::LaunchArmValues value;
    value.opted_in = value.isolation_current = true;
    value.profile_root = scratch / "constructed-isolated-profile";
    value.plugin_root = candidate.directory;
    value.plugin_id = candidate.id; value.run_id = "constructed-run-1";
    return value;
}
struct ArmState {
    r::LaunchArmValues values;
    r::FrozenArm arm;
    explicit ArmState(r::LaunchArmValues value) : values(std::move(value)), arm(values) {}
};
std::shared_ptr<ArmState> arm_for(FakeGame& game, const Candidate& candidate) {
    auto state = std::make_shared<ArmState>(launch_values(candidate));
    game.reactivation_admit = [state](std::uint64_t owner, std::string_view id, const std::filesystem::path& path) {
        return state->arm.begin(state->values, owner, id, path);
    };
    game.reactivation_current = [state](std::uint64_t owner) { return state->arm.current(state->values, owner); };
    game.reactivation_close_arm = [state](std::uint64_t owner) { state->arm.close(owner); };
    return state;
}
void frozen_arm_values() {
    const Candidate candidate{"pure-arm", scratch / "mods" / "pure-arm", "1", {}};
    const auto original = launch_values(candidate);
    constexpr std::uint64_t owner = 91;
    {
        r::FrozenArm absent;
        check(!absent.begin(original, owner, candidate.id, candidate.directory) && !absent.consumed(),
            "late launch values armed a process whose snapshot was absent");
    }
    for (unsigned field = 0; field != 6; ++field) {
        auto incomplete = original;
        switch (field) {
        case 0: incomplete.opted_in = false; break;
        case 1: incomplete.isolation_current = false; break;
        case 2: incomplete.profile_root.clear(); break;
        case 3: incomplete.plugin_root.clear(); break;
        case 4: incomplete.plugin_id.clear(); break;
        case 5: incomplete.run_id.clear(); break;
        }
        r::FrozenArm arm(incomplete);
        check(!arm.begin(incomplete, owner, candidate.id, candidate.directory) && !arm.consumed(),
            "incomplete frozen launch arm admitted a matching package");
        check(!arm.begin(original, owner, candidate.id, candidate.directory), "later complete values repaired a frozen missing arm");
    }
    for (unsigned field = 0; field != 6; ++field) {
        r::FrozenArm arm(original); auto changed = original;
        switch (field) {
        case 0: changed.opted_in = false; break;
        case 1: changed.isolation_current = false; break;
        case 2: changed.profile_root /= "changed"; break;
        case 3: changed.plugin_root /= "changed"; break;
        case 4: changed.plugin_id += "-changed"; break;
        case 5: changed.run_id += "-changed"; break;
        }
        check(!arm.revalidate(changed) && arm.revoked(), "changed launch component did not revoke frozen arm");
        check(!arm.begin(original, owner, candidate.id, candidate.directory), "restoring launch values reversed sticky revocation");
    }
    for (const auto& invalid : {std::string{}, std::string(129, 'x'), std::string("space run"), std::string("bad\nrun")}) {
        auto values = original; values.run_id = invalid; r::FrozenArm arm(values);
        check(!arm.begin(values, owner, candidate.id, candidate.directory), "invalid bounded run token armed the process");
    }
    for (unsigned field = 0; field != 4; ++field) {
        auto invalid = original;
        if (field == 0) invalid.profile_root = "relative-profile";
        if (field == 1) invalid.plugin_root = "relative-package";
        if (field == 2) invalid.profile_root = std::filesystem::path("C:\\") / std::string(181, 'p');
        if (field == 3) invalid.plugin_root = std::filesystem::path("C:\\") / std::string(1025, 'p');
        r::FrozenArm invalid_arm(invalid);
        check(!invalid_arm.begin(invalid, owner, invalid.plugin_id, invalid.plugin_root), "relative or oversized frozen path admitted");
    }
    {
        r::FrozenArm active(original); auto changed = original;
        check(active.begin(original, owner, candidate.id, candidate.directory), "exact arm did not admit before current check");
        changed.run_id += "-changed";
        check(!active.current(changed, owner) && active.revoked() && !active.current(original, owner),
            "changed launch values after admission did not revoke activation permanently");
    }
    r::FrozenArm arm(original);
    check(!arm.begin(original, 0, candidate.id, candidate.directory) &&
        !arm.begin(original, owner, "another-package", candidate.directory) &&
        !arm.begin(original, owner, candidate.id, candidate.directory / "another") && !arm.consumed(),
        "wrong caller consumed the exact package's arm");
    check(arm.begin(original, owner, candidate.id, candidate.directory) && arm.consumed() && arm.bound_owner() == owner,
        "first exact owner/package did not consume the arm");
    check(!arm.begin(original, owner, candidate.id, candidate.directory) &&
        !arm.begin(original, owner + 1, candidate.id, candidate.directory), "retry or replacement owner reused a consumed arm");
    arm.close(owner + 1);
    check(arm.current(original, owner), "foreign owner close revoked the bound arm");
    arm.close(owner); arm.close(owner);
    check(arm.revoked() && !arm.current(original, owner) &&
        !arm.begin(original, owner + 1, candidate.id, candidate.directory), "close or reload restored qualification");
}
void permission_and_phase_denials() {
    for (const auto& granted : {std::string{}, std::string(R"("world.physics")"),
            std::string(R"("world.physics.qualify_body_reactivation")")}) {
        TestEnvironment e; Host host(e, Side::client);
        const auto name = "reactivation-denied-" + std::to_string(granted.size());
        host.apply({script(name, R"(
            local P=reskate.world.physics
            for _,method in {'begin_body_reactivation_probe','poll_body_reactivation_probe'} do
                local ok,why=pcall(P[method],{}, {}, {})
                assert(not ok and why:find('permission',1,true))
            end
        )", granted)}); running(host, name, e);
        check(!e.fake.reactivation_begins && !e.fake.reactivation_polls && !e.fake.reactivation_provider_calls,
            "permission denial parsed arguments or reached the facade/provider"); no_other_authority(e);
    }
    TestEnvironment e; Host host(e, Side::server);
    host.apply({package("reactivation-server", {{manifest_file, manifest(permissions, "server")}, {"plugin/main.lua", R"(
        for _,method in {'begin_body_reactivation_probe','poll_body_reactivation_probe'} do
            local ok,why=pcall(reskate.world.physics[method],{}, {}, {})
            assert(not ok and why:find('client phase only',1,true))
        end
    )"}})}); running(host, "reactivation-server", e);
    check(!e.fake.reactivation_begins && !e.fake.reactivation_polls && !e.fake.reactivation_provider_calls,
        "server denial reached the facade/provider"); no_other_authority(e);
}
void opacity_copies_and_poll_bounds() {
    TestEnvironment e; Host host(e, Side::client);
    const auto candidate = script("reactivation-opaque", body_setup + R"(
        local epoch=assert(P.read(body)).epoch
        for _,bad in {false,1,'1',{},newproxy(),epoch} do
            assert(not pcall(P.begin_body_reactivation_probe,bad))
        end
        assert(not pcall(P.begin_body_reactivation_probe) and not pcall(P.begin_body_reactivation_probe,body,{}))
        local probe=assert(P.begin_body_reactivation_probe(body))
        assert(type(probe)=='userdata' and getmetatable(probe)=='locked')
        assert(not pcall(function()return probe.sequence end))
        assert(not pcall(P.begin_body_reactivation_probe,probe) and not pcall(P.poll_body_reactivation_probe,body))
        assert(not pcall(P.poll_body_reactivation_probe,epoch) and not pcall(P.poll_body_reactivation_probe,{}))
        assert(not pcall(P.poll_body_reactivation_probe) and not pcall(P.poll_body_reactivation_probe,probe,probe))
        assert(not pcall(P.poll_sync_probe,probe) and not pcall(P.poll_motion_refresh_probe,probe))
        assert(P.read(body)==nil)
        for i=1,8 do
            local value=assert(P.poll_body_reactivation_probe(probe))
            assert(value.status=='pending' and value.cleanup_owed and not value.native_retirement_known)
            assert(value.cycle_count==0 and value.elapsed_ms==0 and #value.records==0)
            assert(not value.sequence and not value.owner and not value.handle and not value.run_id)
            value.target_rotation[4]=999;value.elapsed_ms=999;value.records[1]={passed=true}
        end
        assert(P.poll_body_reactivation_probe(probe)==nil)
        assert(P.begin_body_reactivation_probe(body)==nil)
        local done=false
        reskate.on('tick',function()
            if done then return end
            local a=assert(P.poll_body_reactivation_probe(probe))
            assert(a.elapsed_ms==0 and a.target_rotation[4]==1 and #a.records==0)
            assert(P.begin_body_reactivation_probe(body)==nil)
            assert(assert(P.poll_body_reactivation_probe(probe)).status=='pending')
            done=true;reskate.log('reactivation copied bounded pending history')
        end)
    )", permissions + R"(,"world.physics.observe")");
    const auto arm = arm_for(e.fake, candidate);
    host.apply({candidate}); running(host, candidate.id, e);
    check(e.fake.reactivation_begins == 1 && e.fake.reactivation_provider_calls == 1 &&
        e.fake.reactivation_retirements == 1 && e.fake.reactivation_polls == 8,
        "invalid args or shared budgets reached provider admission/polling");
    check(e.fake.reactivation_id == candidate.id && e.fake.reactivation_directory == candidate.directory &&
        e.fake.reactivation_owner == arm->arm.bound_owner() && e.fake.reactivation_owner != 0,
        "binding did not forward the trusted VM instance/package/directory");
    ticks(host, e, 1); running(host, candidate.id, e);
    check(e.logged("reactivation copied bounded pending history") && e.fake.reactivation_polls == 10 &&
        e.fake.reactivation_provider_calls == 1 && e.fake.reactivation_result.elapsed_ms == 0 &&
        e.fake.reactivation_result.record_count == 0 && e.fake.reactivation_cleanup_duty,
        "poll advanced, renewed, acknowledged or cleared constructed cleanup duty"); no_other_authority(e);
}
void arm_refusals_consume_only_matching_attempt() {
    for (unsigned mode = 0; mode != 5; ++mode) {
        TestEnvironment e; Host host(e, Side::client);
        const auto candidate = script("reactivation-refused-" + std::to_string(mode), body_setup + R"(
            assert(P.begin_body_reactivation_probe(body)==nil)
            local done=false
            reskate.on('tick',function()
                if done then return end
                assert(P.begin_body_reactivation_probe(body)==nil);done=true
            end)
        )", permissions);
        std::shared_ptr<ArmState> arm;
        if (mode != 0) arm = arm_for(e.fake, candidate);
        if (mode == 1) arm->values.run_id = "changed-before-begin";
        if (mode == 2) e.fake.reactivation_begin_error = "constructed provider admission refusal";
        if (mode == 3) e.fake.reactivation_next = std::numeric_limits<std::uint64_t>::max();
        if (mode == 4) e.fake.reactivation_zero_sequence = true;
        host.apply({candidate}); running(host, candidate.id, e); ticks(host, e, 1); running(host, candidate.id, e);
        check(e.fake.reactivation_begins == 2 && e.fake.reactivation_provider_calls == (mode < 2 ? 0u : 1u) &&
            e.fake.reactivation_retirements == (mode == 4 ? 1u : 0u),
            "unarmed/changed/repeated/refused/malformed admission crossed provider boundary");
        if (arm) check(arm->arm.consumed() == (mode >= 2), "matching attempt was not consumed before provider refusal");
        host.apply({});
        if (mode == 4) check(e.fake.reactivation_cleanup_duty && !e.fake.reactivation_access,
            "malformed admitted sequence lost cleanup duty on owner close");
        no_other_authority(e);
    }
}
void seed_copied_record(FakeGame& game) {
    auto& result = game.reactivation_result;
    result.record_count = 1;
    auto& record = result.records[0];
    record.stage = r::Stage::initial_park; record.passed = true;
    record.epoch = game.owned.at(game.reactivation_body.generation).sample.epoch;
    auto& observation = record.observation;
    observation.available = true; observation.shape_count = 1;
    observation.sample = game.owned.at(game.reactivation_body.generation).sample;
    observation.categories[0] = r::qualified_categories;
    observation.collisions[0] = 0;
    observation.angular_fourth = .25f; // A copied lane, with no semantic inference.
}
void seed_observed_trace(FakeGame& game, bool omit_write_observations) {
    seed_copied_record(game);
    auto& result = game.reactivation_result;
    constexpr std::array stages{r::Stage::initial_park, r::Stage::initial_park_observed, r::Stage::transform,
        r::Stage::categories, r::Stage::collisions, r::Stage::motion, r::Stage::wake,
        r::Stage::dynamic_observed, r::Stage::repark, r::Stage::repark_observed};
    const auto seed = result.records[0];
    result.status = r::Status::observed; result.phase = r::Phase::terminal;
    result.cleanup = r::Cleanup::confirmed; result.cleanup_owed = false;
    result.first_failure = r::Check::none; result.cycle_count = 1;
    result.record_count = static_cast<std::uint32_t>(stages.size());
    for (std::size_t i = 0; i != stages.size(); ++i) {
        auto& record = result.records[i]; record = seed; record.stage = stages[i];
        record.epoch.serial += i;
        record.epoch.time += static_cast<double>(i) * owned_body::native_seconds;
        record.observation.sample.epoch = record.epoch;
        const bool dynamic = stages[i] == r::Stage::motion || stages[i] == r::Stage::wake ||
            stages[i] == r::Stage::dynamic_observed;
        const bool collisions = dynamic || stages[i] == r::Stage::collisions;
        record.observation.dynamic = dynamic;
        record.observation.collisions[0] = collisions ? r::qualified_collisions : 0U;
        if (omit_write_observations && (stages[i] == r::Stage::initial_park || stages[i] == r::Stage::repark))
            record.observation = {}; // A returned write need not already carry a native observation.
    }
}
void copied_record_and_terminal_history() {
    struct History { r::Status status; bool omit_write_observations; };
    constexpr History histories[]{{r::Status::pending, false}, {r::Status::observed, true},
        {r::Status::observed, false}, {r::Status::expired, false}, {r::Status::invalidated, false}};
    for (const auto history : histories) {
        const auto status = history.status;
        TestEnvironment e; Host host(e, Side::client);
        const auto candidate = script("reactivation-history-" + std::to_string(static_cast<unsigned>(status)) +
            (history.omit_write_observations ? "-write-only" : "-copied"), body_setup + R"(
            local probe=assert(P.begin_body_reactivation_probe(body));local done=false
            reskate.on('tick',function()
                if done then return end
                local a=assert(P.poll_body_reactivation_probe(probe))
                assert(#a.records==(a.status=='observed' and 10 or 1) and a.records[1].stage=='initial_park' and a.records[1].passed)
                assert(a.records[1].epoch.serial=='100' and not a.native_retirement_known)
                if a.status=='observed' then
                    for i,row in a.records do
                        local o=row.observation
                        if o.available then
                            local dynamic=i==6 or i==7 or i==8
                            assert(o.dynamic==dynamic and o.categories[1]==0)
                            assert(o.collisions[1]==((dynamic or i==5) and 257 or 0))
                        else assert(i==1 or i==9) end
                    end
                end
                local status,cleanup,elapsed=a.status,a.cleanup,a.elapsed_ms
                a.records[1].passed=false;a.records[1].epoch.serial='forged';a.elapsed_ms=99999
                local b=assert(P.poll_body_reactivation_probe(probe))
                assert(b.records[1].passed and b.records[1].epoch.serial=='100')
                assert(b.status==status and b.cleanup==cleanup and b.elapsed_ms==elapsed)
                assert(P.acknowledge_body_reactivation_probe==nil and P.renew_body_reactivation_probe==nil)
                assert(P.cancel_body_reactivation_probe==nil)
                done=true;reskate.log('reactivation immutable copied history')
            end)
        )", permissions);
        const auto arm = arm_for(e.fake, candidate); (void)arm;
        host.apply({candidate}); running(host, candidate.id, e); seed_copied_record(e.fake);
        auto& result = e.fake.reactivation_result; result.status = status;
        const double elapsed = status == r::Status::expired ? 2500 : status == r::Status::invalidated ? 3500 : 1250;
        result.elapsed_ms = elapsed;
        if (status != r::Status::pending) {
            result.phase = r::Phase::terminal;
            result.cleanup = status == r::Status::invalidated ? r::Cleanup::unconfirmed : r::Cleanup::confirmed;
            result.cleanup_owed = status == r::Status::invalidated;
            if (status == r::Status::observed) seed_observed_trace(e.fake, history.omit_write_observations);
            else {
                result.first_failure = status == r::Status::expired ? r::Check::run_deadline : r::Check::qualification;
                result.failure_phase = r::Phase::activation;
            }
        }
        e.fake.reactivation_cleanup_duty = result.cleanup_owed;
        const bool owed = e.fake.reactivation_cleanup_duty;
        ticks(host, e, 1); running(host, candidate.id, e);
        check(e.logged("reactivation immutable copied history") && e.fake.reactivation_polls == 2 &&
            e.fake.reactivation_provider_calls == 1 && result.elapsed_ms == elapsed && result.records[0].passed &&
            e.fake.reactivation_cleanup_duty == owed,
            "poll mutated or failed to copy valid provider history"); no_other_authority(e);
    }
}
void issued_body_cannot_be_rebound() {
    for (unsigned fault = 0; fault != 3; ++fault) {
        TestEnvironment e; Host host(e, Side::client);
        const auto candidate = script("reactivation-body-identity-" + std::to_string(fault), body_setup + R"(
            local done=false
            reskate.on('tick',function()
                if done then return end
                assert(P.begin_body_reactivation_probe(body)==nil);done=true
            end)
        )", permissions);
        const auto arm = arm_for(e.fake, candidate);
        host.apply({candidate}); running(host, candidate.id, e);
        auto& body = e.fake.owned.begin()->second;
        if (fault == 0) ++body.owner;
        if (fault == 1) ++body.handle.generation;
        if (fault == 2) body.released = true;
        ticks(host, e, 1); running(host, candidate.id, e);
        check(arm->arm.consumed() && e.fake.reactivation_provider_calls == 1 && !e.fake.reactivation_retirements &&
            !e.fake.reactivation_cleanup_duty, "issued stale/foreign/retired body acquired diagnostic authority");
        no_other_authority(e);
    }
}
void shared_passive_probe_budgets() {
    TestEnvironment e; Host host(e, Side::client);
    const auto candidate = script("reactivation-shared-budget", body_setup + R"(
        local actor=assert(P.begin_motion_refresh_probe())
        assert(P.begin_body_reactivation_probe(body)==nil)
        local stage=0;local probe
        reskate.on('tick',function()
            if stage==0 then
                probe=assert(P.begin_body_reactivation_probe(body))
                for i=1,4 do
                    assert(P.poll_body_reactivation_probe(probe))
                    assert(P.poll_motion_refresh_probe(actor))
                end
                assert(P.poll_body_reactivation_probe(probe)==nil and P.poll_motion_refresh_probe(actor)==nil)
                stage=1
            elseif stage==1 then
                assert(P.poll_body_reactivation_probe(probe));stage=2
                reskate.log('reactivation shared passive quotas preserved')
            end
        end)
    )", permissions + R"(,"world.physics.observe")");
    const auto arm = arm_for(e.fake, candidate);
    host.apply({candidate}); running(host, candidate.id, e);
    check(!arm->arm.consumed() && !e.fake.reactivation_begins, "shared start refusal consumed the process arm");
    ticks(host, e, 2); running(host, candidate.id, e);
    check(e.logged("reactivation shared passive quotas preserved") && e.fake.reactivation_begins == 1 &&
        e.fake.reactivation_provider_calls == 1 && e.fake.reactivation_polls == 5 && e.fake.motion_refresh_polls == 4 &&
        e.fake.motion_refresh_starts == 1, "private diagnostic bypassed shared passive start/poll quotas");
    no_other_authority(e);
}
void changed_live_arm_keeps_cleanup_duty() {
    TestEnvironment e; Host host(e, Side::client);
    const auto candidate = script("reactivation-live-arm", body_setup + R"(
        local probe=assert(P.begin_body_reactivation_probe(body))
        reskate.on('tick',function()assert(P.poll_body_reactivation_probe(probe)==nil)end)
    )", permissions);
    const auto arm = arm_for(e.fake, candidate);
    host.apply({candidate}); running(host, candidate.id, e);
    const auto original = arm->values;
    arm->values.run_id += "-changed";
    ticks(host, e, 1); running(host, candidate.id, e);
    arm->values = original;
    ticks(host, e, 1); running(host, candidate.id, e);
    check(arm->arm.revoked() && e.fake.reactivation_polls == 2 && e.fake.reactivation_provider_calls == 1 &&
        e.fake.reactivation_cleanup_duty, "changed/restored arm renewed access or erased outstanding cleanup");
    no_other_authority(e);
}
void wrong_package_cannot_take_arm() {
    TestEnvironment e; Host host(e, Side::client);
    const auto accepted = script("reactivation-approved-package", body_setup +
        "assert(P.begin_body_reactivation_probe(body))", permissions);
    const auto other = script("reactivation-unapproved-package", body_setup +
        "assert(P.begin_body_reactivation_probe(body)==nil)", permissions);
    const auto arm = arm_for(e.fake, accepted);
    host.apply({other}); running(host, other.id, e);
    check(!arm->arm.consumed() && !e.fake.reactivation_provider_calls, "unapproved package took the one process arm");
    host.apply({other, accepted}); running(host, accepted.id, e);
    check(arm->arm.consumed() && e.fake.reactivation_begins == 2 && e.fake.reactivation_provider_calls == 1 &&
        e.fake.reactivation_id == accepted.id && e.fake.reactivation_directory == accepted.directory,
        "approved trusted package could not use the arm after foreign refusal"); no_other_authority(e);
}
void malformed_copied_results() {
    using Fault = void(*)(r::Result&);
    const Fault faults[] = {
        [](auto& x){x.status=static_cast<r::Status>(255);},
        [](auto& x){x.phase=static_cast<r::Phase>(255);},
        [](auto& x){x.cleanup=static_cast<r::Cleanup>(255);},
        [](auto& x){x.first_failure=static_cast<r::Check>(255);},
        [](auto& x){x.failure_phase=static_cast<r::Phase>(255);},
        [](auto& x){x.native_retirement_known=true;},
        [](auto& x){x.failure_shape_known=true;x.failure_shape=255;},
        [](auto& x){x.failure_shape_known=false;x.failure_shape=1;},
        [](auto& x){x.cleanup=r::Cleanup::confirmed;x.cleanup_owed=true;},
        [](auto& x){x.cleanup=r::Cleanup::unconfirmed;x.cleanup_owed=false;},
        [](auto& x){x.phase=r::Phase::terminal;},
        [](auto& x){x.status=r::Status::observed;},
        [](auto& x){x.record_count=2;x.records[1]=x.records[0];},
        [](auto& x){x.records[0].observation.available=false;},
        [](auto& x){x.records[0].observation.sample.mass=0;},
        [](auto& x){x.records[0].observation.sample.inertia[0]=-1;},
        [](auto& x){x.records[0].observation.sample.velocity[1]=std::numeric_limits<float>::infinity();},
        [](auto& x){x.records[0].observation.force[3]=std::numeric_limits<float>::infinity();},
        [](auto& x){x.records[0].observation.torque[1]=std::numeric_limits<float>::quiet_NaN();},
        [](auto& x){++x.records[0].observation.sample.epoch.serial;},
        [](auto& x){x.cycle_count=2;},
        [](auto& x){x.record_count=static_cast<std::uint32_t>(r::record_capacity+1);},
        [](auto& x){x.elapsed_ms=-1;},
        [](auto& x){x.elapsed_ms=std::numeric_limits<double>::infinity();},
        [](auto& x){x.target_position[0]=std::numeric_limits<float>::quiet_NaN();},
        [](auto& x){x.target_rotation[3]=std::numeric_limits<float>::infinity();},
        [](auto& x){x.record_count=1;x.records[0].stage=static_cast<r::Stage>(255);},
        [](auto& x){x.record_count=1;x.records[0].observation.shape_count=255;},
        [](auto& x){x.record_count=1;x.records[0].epoch.time=std::numeric_limits<double>::quiet_NaN();},
        [](auto& x){x.record_count=1;x.records[0].observation.angular_fourth=std::numeric_limits<float>::infinity();},
    };
    unsigned index{};
    for (const auto fault : faults) {
        TestEnvironment e; Host host(e, Side::client);
        const auto candidate = script("reactivation-invalid-" + std::to_string(++index), body_setup + R"(
            local probe=assert(P.begin_body_reactivation_probe(body));local done=false
            reskate.on('tick',function()
                if done then return end
                local value,why=P.poll_body_reactivation_probe(probe)
                assert(value==nil and type(why)=='string');done=true
                reskate.log('reactivation malformed refused')
            end)
        )", permissions);
        const auto arm = arm_for(e.fake, candidate); (void)arm;
        host.apply({candidate}); running(host, candidate.id, e);
        seed_copied_record(e.fake);
        fault(e.fake.reactivation_result);
        ticks(host, e, 1); running(host, candidate.id, e);
        check(e.logged("reactivation malformed refused") && e.fake.reactivation_polls == 1 &&
            e.fake.reactivation_retirements == 1 && e.fake.reactivation_cleanup_duty,
            "malformed provider copy escaped validation or altered cleanup duty"); no_other_authority(e);
    }
}
void contradictory_observed_history() {
    struct Fault { std::string name; std::function<void(r::Result&)> apply; };
    std::vector<Fault> faults;
    for (const std::size_t at : {0U, 1U, 2U, 3U, 8U, 9U})
        faults.push_back({"parked-mask-" + std::to_string(at), [at](auto& x) {
            x.records[at].observation.collisions[0] = r::qualified_collisions;
        }});
    for (const std::size_t at : {5U, 6U, 7U})
        faults.push_back({"missing-dynamic-" + std::to_string(at), [at](auto& x) { x.records[at].observation.dynamic = false; }});
    for (const std::size_t at : {4U, 9U})
        faults.push_back({"unexpected-dynamic-" + std::to_string(at), [at](auto& x) { x.records[at].observation.dynamic = true; }});
    for (const std::size_t at : {4U, 5U, 6U, 7U})
        faults.push_back({"missing-mask-" + std::to_string(at), [at](auto& x) { x.records[at].observation.collisions[0] = 0; }});
    faults.push_back({"wrong-categories", [](auto& x) { x.records[3].observation.categories[0] = 1; }});
    for (const std::size_t at : {1U, 2U, 3U, 4U, 5U, 6U, 7U, 9U})
        faults.push_back({"missing-observation-" + std::to_string(at), [at](auto& x) { x.records[at].observation = {}; }});
    for (const bool world : {false, true})
        faults.push_back({world ? "foreign-world" : "foreign-body", [world](auto& x) {
            auto& record = x.records[5];
            if (world) ++record.epoch.world; else ++record.epoch.body;
            record.observation.sample.epoch = record.epoch;
        }});
    for (const bool serial : {false, true})
        faults.push_back({serial ? "regressing-serial" : "regressing-time", [serial](auto& x) {
            auto& record = x.records[4];
            if (serial) record.epoch.serial = x.records[3].epoch.serial - 1;
            else record.epoch.time = x.records[3].epoch.time - .001;
            record.observation.sample.epoch = record.epoch;
        }});
    faults.push_back({"same-serial-different-time", [](auto& x) {
        x.records[4].epoch.serial = x.records[3].epoch.serial;
        x.records[4].observation.sample.epoch = x.records[4].epoch;
    }});
    constexpr std::array floors{std::pair{0U, 1U}, std::pair{6U, 7U}, std::pair{8U, 9U}};
    for (const auto [floor, observed] : floors) for (unsigned component = 0; component != 3; ++component)
        faults.push_back({"not-later-" + std::to_string(observed) + "-" + std::to_string(component),
            [floor, observed, component](auto& x) {
                auto& record = x.records[observed];
                if (component != 2) record.epoch.serial = x.records[floor].epoch.serial;
                if (component != 1) record.epoch.time = x.records[floor].epoch.time;
                record.observation.sample.epoch = record.epoch;
            }});
    check(faults.size() == 38, "the semantic contradiction table lost a stage or epoch case");
    for (const auto& fault : faults) {
        TestEnvironment e; Host host(e, Side::client);
        const auto candidate = script("reactivation-contradiction-" + fault.name, body_setup + R"(
            local probe=assert(P.begin_body_reactivation_probe(body));local done=false
            reskate.on('tick',function()
                if done then return end
                local value,why=P.poll_body_reactivation_probe(probe)
                assert(value==nil and type(why)=='string');done=true
                reskate.log('reactivation contradiction refused')
            end)
        )", permissions);
        const auto arm = arm_for(e.fake, candidate); (void)arm;
        host.apply({candidate}); running(host, candidate.id, e);
        seed_observed_trace(e.fake, false); fault.apply(e.fake.reactivation_result);
        ticks(host, e, 1); running(host, candidate.id, e);
        check(e.logged("reactivation contradiction refused") && e.fake.reactivation_polls == 1 &&
            e.fake.reactivation_retirements == 1 && e.fake.reactivation_cleanup_duty,
            "contradictory observed DTO escaped the binding: " + fault.name); no_other_authority(e);
    }
}
void partial_failed_history_stays_readable() {
    for (const bool zero_epoch : {false, true}) {
        TestEnvironment e; Host host(e, Side::client);
        const auto candidate = script(zero_epoch ? "reactivation-zero-failure" : "reactivation-copied-failure", body_setup + R"(
            local probe=assert(P.begin_body_reactivation_probe(body));local done=false
            reskate.on('tick',function()
                if done then return end
                local value=assert(P.poll_body_reactivation_probe(probe))
                assert(value.status=='invalidated' and value.terminal and value.cleanup=='unconfirmed' and value.cleanup_owed)
                assert(value.first_failure=='transform' and value.failure_shape_known and value.failure_shape==0)
                assert(#value.records==2 and value.records[1].passed and not value.records[2].passed)
                assert(value.records[2].stage=='transform' and not value.native_retirement_known)
                local failed=value.records[2]
                if failed.observation.available then
                    assert(failed.epoch.serial=='100' and failed.observation.dynamic and failed.observation.collisions[1]==257)
                else assert(failed.epoch.serial=='0' and failed.epoch.time==0) end
                done=true;reskate.log('reactivation partial failure preserved')
            end)
        )", permissions);
        const auto arm = arm_for(e.fake, candidate); (void)arm;
        host.apply({candidate}); running(host, candidate.id, e); seed_copied_record(e.fake);
        auto& result = e.fake.reactivation_result;
        result.status = r::Status::invalidated; result.phase = r::Phase::terminal;
        result.cleanup = r::Cleanup::unconfirmed; result.first_failure = r::Check::transform;
        result.failure_phase = r::Phase::activation; result.failure_shape_known = true;
        result.record_count = 2;
        auto& failed = result.records[1]; failed = result.records[0];
        failed.stage = r::Stage::transform; failed.passed = false;
        if (zero_epoch) { failed.epoch = {}; failed.observation = {}; }
        else { failed.observation.dynamic = true; failed.observation.collisions[0] = r::qualified_collisions; }
        ticks(host, e, 1); running(host, candidate.id, e);
        check(e.logged("reactivation partial failure preserved") && e.fake.reactivation_polls == 1 &&
            e.fake.reactivation_cleanup_duty && result.first_failure == r::Check::transform,
            "partial/failed evidence was hidden or relabeled as completed cleanup"); no_other_authority(e);
    }
}
void owner_close_preserves_constructed_duty() {
    for (const auto phase : {r::Phase::initial_park, r::Phase::await_initial_park, r::Phase::activation,
            r::Phase::await_dynamic, r::Phase::repark, r::Phase::await_repark, r::Phase::terminal}) {
        TestEnvironment e; Host host(e, Side::client);
        const auto candidate = script("reactivation-close-" + std::to_string(static_cast<unsigned>(phase)), body_setup + R"(
            local probe=P.begin_body_reactivation_probe(body)
            if not probe then reskate.log('replacement owner refused') end
        )", permissions);
        const auto arm = arm_for(e.fake, candidate);
        host.apply({candidate}); running(host, candidate.id, e);
        auto& g = e.fake; g.reactivation_result.phase = phase;
        if (phase == r::Phase::terminal) {
            g.reactivation_result.status = r::Status::invalidated;
            g.reactivation_result.cleanup = r::Cleanup::unconfirmed;
            g.reactivation_result.first_failure = r::Check::cleanup_deadline;
        }
        const auto owner = g.reactivation_owner, sequence = g.reactivation_sequence;
        const auto body = g.reactivation_body;
        g.close_reactivation_fixture(owner + 1);
        check(g.reactivation_access && !g.reactivation_closes, "foreign owner close revoked this run");
        host.apply({});
        r::Result out;
        check(!g.reactivation_access && g.reactivation_cleanup_duty && g.reactivation_result.cleanup_owed &&
            g.reactivation_result.phase == phase && g.reactivation_closes == 1 && arm->arm.revoked() &&
            !g.poll_body_reactivation_probe(owner, body, sequence, out).empty(),
            "owner unload erased stage/duty or retained poll access");
        g.close_reactivation_fixture(owner);
        check(g.reactivation_closes == 1 && g.reactivation_cleanup_duty, "repeated close changed cleanup duty");
        host.apply({candidate}); running(host, candidate.id, e);
        check(e.logged("replacement owner refused") && g.reactivation_provider_calls == 1 &&
            g.reactivation_retirements == 1 && g.reactivation_owner == owner,
            "reloaded owner inherited the launch arm or replaced cleanup history"); no_other_authority(e);
    }
}
void typed_transport_cannot_forge_identity() {
    TestEnvironment e; Host host(e, Side::client);
    const auto library = script("reactivation-library", body_setup + R"(
        local probe=assert(P.begin_body_reactivation_probe(body))
        reskate.expose({body=function()return body end,probe=function()return probe end})
    )", permissions);
    const auto arm = arm_for(e.fake, library); (void)arm;
    const auto caller = script("reactivation-foreign", R"(
        reskate.console.command('reactivation-transfer','x',function()
            local other=assert(reskate.require_plugin('reactivation-library'))
            assert(not pcall(other.body) and not pcall(other.probe))
            reskate.log('reactivation transport refused')
        end)
    )", permissions + R"(,"console")");
    host.apply({library, caller}); running(host, library.id, e); running(host, caller.id, e);
    check(host.run_console("reactivation-transfer") && e.logged("reactivation transport refused") &&
        e.fake.reactivation_begins == 1 && !e.fake.reactivation_polls,
        "body/probe crossed VM transport or reached foreign provider polling");
    r::Result out;
    const auto owner=e.fake.reactivation_owner, sequence=e.fake.reactivation_sequence;
    const auto body=e.fake.reactivation_body;
    check(!e.fake.poll_body_reactivation_probe(owner+1,body,sequence,out).empty() &&
        !e.fake.poll_body_reactivation_probe(owner,{body.generation+1,body.slot},sequence,out).empty() &&
        !e.fake.poll_body_reactivation_probe(owner,body,sequence+1,out).empty(),
        "constructed provider accepted foreign owner/body generation/request sequence"); no_other_authority(e);
}
#endif
} // namespace body_reactivation_host_test

void body_reactivation_probe_host_fixture_v1() {
    using namespace body_reactivation_host_test;
#ifdef DINGOSDK_BODY_REACTIVATION_QUALIFICATION
    check(parse_manifest(manifest(permissions)).permissions.contains("world.physics.qualify_body_reactivation"),
        "qualification build does not recognize its dedicated permission");
    frozen_arm_values();
    permission_and_phase_denials();
    opacity_copies_and_poll_bounds();
    arm_refusals_consume_only_matching_attempt();
    copied_record_and_terminal_history();
    issued_body_cannot_be_rebound();
    shared_passive_probe_budgets();
    changed_live_arm_keeps_cleanup_duty();
    wrong_package_cannot_take_arm();
    malformed_copied_results();
    contradictory_observed_history();
    partial_failed_history_stays_readable();
    owner_close_preserves_constructed_duty();
    typed_transport_cannot_forge_identity();
#else
    bool refused{};
    try { (void)parse_manifest(manifest(R"("world.physics.qualify_body_reactivation")")); }
    catch (const std::exception& error) { refused=std::string(error.what()).find("unknown permission")!=std::string::npos; }
    check(refused, "normal build recognized private qualification permission");
    for (const auto side : {Side::client, Side::server}) {
        TestEnvironment e; Host host(e, side);
        const auto candidate=package("reactivation-off", {{manifest_file, manifest(R"("world.physics","world.physics.observe")",
            side==Side::client?"client":"server")}, {"plugin/main.lua",R"(
            local P=reskate.world.physics
            assert(P.begin_body_reactivation_probe==nil and P.poll_body_reactivation_probe==nil)
            assert(type(P.begin_sync_probe)=='function' and type(P.poll_sync_probe)=='function')
            assert(type(P.begin_motion_refresh_probe)=='function' and type(P.poll_motion_refresh_probe)=='function')
        )"}});
        host.apply({candidate}); running(host,candidate.id,e);
        check(!e.fake.sync_probe_starts && !e.fake.sync_probe_polls && !e.fake.motion_refresh_starts &&
            !e.fake.motion_refresh_polls && !e.fake.body_create_calls, "normal build omission admitted a diagnostic");
        no_other_authority(e);
    }
#endif
}