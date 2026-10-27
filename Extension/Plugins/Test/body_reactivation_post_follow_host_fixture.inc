// Include after body_reactivation_probe_host_fixture.inc in plugin_tests.cpp.
// These are actual Host/permission/DTO binding checks over a constructed Game.
// They do not execute the native post-Follow completion or reactivation path.
namespace body_reactivation_post_follow_host_test {
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
using namespace body_reactivation_host_test;
void historical_park_flag_is_explicit_copied_and_stage_scoped() {
    check(!r::Record{}.historical_park_basis,"new ordinary records defaulted to historical park provenance");
    for(const bool historical:{false,true})for(const bool terminal:{false,true}) {
        TestEnvironment e;Host host(e,Side::client);
        const auto candidate=script(std::string("reactivation-park-kind-")+(historical?"historical-":"new-")+(terminal?"terminal":"pending"),
            body_setup+std::string("local historical=")+(historical?"true":"false")+
            ";local terminal="+(terminal?"true":"false")+R"(
                local probe=assert(P.begin_body_reactivation_probe(body));local done=false
                reskate.on('tick',function()
                    if done then return end
                    local value=assert(P.poll_body_reactivation_probe(probe))
                    assert(value.terminal==terminal and value.status==(terminal and 'observed' or 'pending'))
                    assert(#value.records==(terminal and 10 or 2))
                    assert(value.records[1].stage=='initial_park' and value.records[1].passed)
                    assert(value.records[1].epoch.serial=='100' and not value.records[1].observation.available)
                    -- Historical park provenance and the fresh observed row stay distinct even while pending.
                    local fresh=value.records[2]
                    assert(fresh.stage=='initial_park_observed' and fresh.passed and fresh.observation.available)
                    assert(not fresh.observation.dynamic and fresh.epoch.serial=='101' and fresh.epoch.time>value.records[1].epoch.time)
                    assert(fresh.observation.sample.epoch.serial==fresh.epoch.serial and fresh.observation.sample.epoch.time==fresh.epoch.time)
                    for i,row in value.records do
                        assert(type(row.historical_park_basis)=='boolean')
                        assert(row.historical_park_basis==(historical and i==1))
                    end
                    value.records[1].historical_park_basis=not historical
                    value.records[2].historical_park_basis=true
                    local again=assert(P.poll_body_reactivation_probe(probe))
                    assert(again.records[1].historical_park_basis==historical and again.records[2].historical_park_basis==false)
                    assert(not again.native_retirement_known and again.cleanup_owed==(not terminal))
                    done=true;reskate.log('reactivation park provenance copied without authority')
                end)
            )",permissions);
        const auto arm=arm_for(e.fake,candidate);(void)arm;
        host.apply({candidate});running(host,candidate.id,e);
        seed_observed_trace(e.fake,true);auto& result=e.fake.reactivation_result;
        result.records[0].historical_park_basis=historical;
        if(!terminal) {
            result.status=r::Status::pending;result.phase=r::Phase::activation;
            result.cleanup=r::Cleanup::pending;result.cleanup_owed=true;result.record_count=2;
        }
        e.fake.reactivation_cleanup_duty=result.cleanup_owed;
        const bool owed=e.fake.reactivation_cleanup_duty;
        ticks(host,e,1);running(host,candidate.id,e);
        check(e.logged("reactivation park provenance copied without authority") && e.fake.reactivation_polls==2 &&
            e.fake.reactivation_provider_calls==1 && e.fake.reactivation_retirements==1 &&
            result.records[0].historical_park_basis==historical && !result.records[1].historical_park_basis &&
            e.fake.reactivation_cleanup_duty==owed,"historical park serialization mutated provider history or cleanup duty");
        no_other_authority(e);
    }
}
void contradictory_historical_park_flags_fail_closed() {
    struct Fault { const char* name; void (*apply)(r::Result&); };
    const std::array faults{
        Fault{"observed-first",[](r::Result& value){
            auto& first=value.records[0];first.historical_park_basis=true;
            first.observation=value.records[1].observation;first.observation.sample.epoch=first.epoch;
        }},
        Fault{"failed-first",[](r::Result& value){
            value.status=r::Status::invalidated;value.first_failure=r::Check::initial_park;
            value.failure_phase=r::Phase::initial_park;value.records[0].passed=false;value.records[0].historical_park_basis=true;
        }},
        Fault{"later-park",[](r::Result& value){value.records[8].historical_park_basis=true;}},
        Fault{"later-observation",[](r::Result& value){value.records[1].historical_park_basis=true;}},
        Fault{"transform",[](r::Result& value){value.records[2].historical_park_basis=true;}},
        Fault{"missing-epoch",[](r::Result& value){value.records[0].historical_park_basis=true;value.records[0].epoch={};}},
        Fault{"invalid-unavailable",[](r::Result& value){value.records[0].historical_park_basis=true;value.records[0].observation.dynamic=true;}}
    };
    for(const auto& fault:faults) {
        TestEnvironment e;Host host(e,Side::client);
        const auto candidate=script(std::string("reactivation-invalid-park-kind-")+fault.name,body_setup+R"(
            local probe=assert(P.begin_body_reactivation_probe(body));local done=false
            reskate.on('tick',function()
                if done then return end
                local value,why=P.poll_body_reactivation_probe(probe)
                assert(value==nil and type(why)=='string' and why:find('invalid observations',1,true))
                done=true;reskate.log('contradictory historical park flag refused')
            end)
        )",permissions);
        const auto arm=arm_for(e.fake,candidate);(void)arm;
        host.apply({candidate});running(host,candidate.id,e);
        seed_observed_trace(e.fake,true);fault.apply(e.fake.reactivation_result);
        ticks(host,e,1);running(host,candidate.id,e);
        check(e.logged("contradictory historical park flag refused") && e.fake.reactivation_polls==1 &&
            e.fake.reactivation_provider_calls==1 && e.fake.reactivation_retirements==1 && e.fake.reactivation_cleanup_duty,
            std::string("contradictory historical park DTO escaped or changed cleanup duty: ")+fault.name);
        no_other_authority(e);
    }
}
void historical_park_field_does_not_bypass_permission() {
    TestEnvironment e;Host host(e,Side::client);
    const auto candidate=script("reactivation-park-kind-denied",R"(
        local P=reskate.world.physics
        for _,method in {'begin_body_reactivation_probe','poll_body_reactivation_probe'} do
            local ok,why=pcall(P[method],{historical_park_basis=true})
            assert(not ok and why:find('permission',1,true))
        end
    )",R"("world.physics")");
    host.apply({candidate});running(host,candidate.id,e);
    check(!e.fake.reactivation_begins && !e.fake.reactivation_polls && !e.fake.reactivation_provider_calls &&
        !e.fake.body_create_calls,"historical park-shaped data bypassed permission denial before provider dispatch");
    no_other_authority(e);
}
#endif
} // namespace body_reactivation_post_follow_host_test

void body_reactivation_post_follow_host_fixture_v1() {
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
    using namespace body_reactivation_post_follow_host_test;
    historical_park_flag_is_explicit_copied_and_stage_scoped();
    contradictory_historical_park_flags_fail_closed();
    historical_park_field_does_not_bypass_permission();
#else
    bool refused{};
    try { (void)parse_manifest(manifest(R"("world.physics.qualify_body_reactivation")")); }
    catch(const std::exception& error) { refused=std::string(error.what()).find("unknown permission")!=std::string::npos; }
    check(refused,"default-OFF build recognized private post-Follow qualification permission");
    TestEnvironment e;Host host(e,Side::client);
    const auto candidate=script("reactivation-park-kind-off",R"(
        local P=reskate.world.physics
        assert(P.begin_body_reactivation_probe==nil and P.poll_body_reactivation_probe==nil)
    )",R"("world.physics")");
    host.apply({candidate});running(host,candidate.id,e);
    check(!e.fake.body_create_calls && !e.fake.sync_probe_starts && !e.fake.motion_refresh_starts,
        "default-OFF post-Follow omission dispatched provider work");
    body_reactivation_host_test::no_other_authority(e);
#endif
}
