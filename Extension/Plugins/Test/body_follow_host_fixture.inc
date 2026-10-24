// The real Host/VM/API over constructed Game leaf results. These cases do not
// execute the native Service, prove a park/drain, or establish gameplay parity.
namespace {
void body_follow_host_fixture_v1() {
    namespace f = dingosdk::body_follow_api;
    const std::string permissions = R"("world.physics","world.physics.follow")";
    const std::string setup = R"(
        local P=reskate.world.physics;local v=vector.create
        local function make_body()
            return assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
                capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
        end
        local body=make_body()
        local attachment={offset_from_com=v(0,.4,0),root_in_body={0,0,0,1}}
    )";
    unsigned cases{};
    const auto id = [&] { return "body-follow-" + std::to_string(++cases); };
    const auto no_unrelated_effects = [](const TestEnvironment& e) {
        check(!e.fake.body_submit_entries && !e.fake.batch_calls && !e.rays && !e.fake.input_pulse_requests &&
            !e.fake.native_action_requests && !e.fake.native_recovery_requests && e.teleports.empty(),
            "follow binding invoked unrelated forces, queries, input, equipment or recovery");
    };

    // Both permissions and client-side authority are checked before arguments.
    for (const auto& granted : {std::string{}, std::string{R"("world.physics")"},
        std::string{R"("world.physics.follow")"}}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,R"(
            for _,method in {'reserve_follow','publish_follow','read_follow','stop_follow','acknowledge_follow'} do
                local ok,why=pcall(reskate.world.physics[method],{},{},{})
                assert(not ok and why:find('world.physics',1,true),method)
            end
        )",granted)}); running(host,name,e);
        check(!e.fake.follow_reserves && !e.fake.follow_publishes && !e.fake.follow_reads &&
            !e.fake.follow_stops && !e.fake.follow_acks,"missing permission reached follow backend");
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::server); const auto name=id();
        host.apply({package(name,{{manifest_file,manifest(permissions,"server")},{"plugin/main.lua",R"(
            for _,method in {'reserve_follow','publish_follow','read_follow','stop_follow','acknowledge_follow'} do
                local ok,why=pcall(reskate.world.physics[method],{},{},{})
                assert(not ok and why:find('client phase only',1,true),method)
            end
        )"}})}); running(host,name,e);
        check(!e.fake.follow_reserves && !e.fake.follow_publishes && !e.fake.follow_reads &&
            !e.fake.follow_stops && !e.fake.follow_acks,"server reached follow backend");
        no_unrelated_effects(e);
    }
    check(known_permission("world.physics.follow"),"new permission is absent from manifest registry");
    {
        dingosdk::skater_action::State state{true,true,false,true,false,504};
        check(f::eligible(state),"known upright grounded actor refused");
        state.in_air=true; check(f::eligible(state),"generic admission accidentally requires grounded callbacks");
        state.ragdoll=true; check(!f::eligible(state),"ragdoll admitted");
        state.ragdoll=false; state.ragdoll_known=false; check(!f::eligible(state),"unknown ragdoll state admitted");
        state.ragdoll_known=true; state.in_air_known=false; check(!f::eligible(state),"unknown airborne state admitted");
        state.in_air_known=true; state.value=100; check(!f::eligible(state),"board actor admitted");
        state.value=504; state.known=false; check(!f::eligible(state),"unknown actor state admitted");
    }

    // Optional cleanup selects only the stopped-body authority path. These
    // Host controls prove argument delivery, never native cleanup or a park.
    for (const auto& policy : {std::string{}, std::string{"actor_lifetime"}, std::string{"owned_body"}}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        const auto selection=policy.empty()?std::string{}:"attachment.cleanup='"+policy+"'\n";
        host.apply({script(name,setup+selection+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
        )",permissions)}); running(host,name,e);
        const auto expected=policy=="owned_body"?f::CleanupPolicy::owned_body:f::CleanupPolicy::actor_lifetime;
        check(e.fake.follow_reserves==1 && e.fake.follow_fixture.attachment.cleanup==expected &&
            !e.fake.follow_publishes && !e.fake.follow_stops && !e.fake.follow_acks,
            "cleanup selection was lost or performed an unrelated follow operation\n"+e.all());
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            for _,bad in {'unknown','owned_body\0other',true,7,{},function()end} do
                attachment.cleanup=bad
                local ok,why=pcall(P.reserve_follow,body,attachment)
                assert(not ok and why:find('cleanup',1,true))
            end
        )",permissions)}); running(host,name,e);
        check(!e.fake.follow_reserves,"invalid cleanup option reached the backend\n"+e.all());
        f::Attachment malformed;malformed.cleanup=static_cast<f::CleanupPolicy>(255);
        check(!f::valid(malformed),"unknown C++ cleanup policy accepted");
        no_unrelated_effects(e);
    }

    // Strict finite attachment and opaque handle/arity boundaries. No caller
    // can supply an admission callback, native identity, completion or proof.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            assert(not pcall(P.reserve_follow,body))
            assert(not pcall(P.reserve_follow,body,attachment,true))
            for _,bad in {
                {},{offset_from_com=v(0,0,0),root_in_body={0,0,0,0}},
                {offset_from_com=v(11,0,0),root_in_body={0,0,0,1}},
                {offset_from_com=v(0,0,0),root_in_body={0,0,0,1,2}},
                {offset_from_com=v(0,0,0),root_in_body={0,0,0,1,proof=true}},
                {offset_from_com=v(0,0,0),root_in_body={0,0,0,1},parked=true},
                {offset_from_com=v(0,0,0),root_in_body={0,0,0,1},admission=function()return true end},
                {offset_from_com=v(0,0,0),root_in_body={0/0,0,0,1}}
            } do assert(not pcall(P.reserve_follow,body,bad)) end
            assert(not pcall(P.reserve_follow,{},attachment))
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(type(h)=='userdata' and getmetatable(h)=='locked')
            assert(not pcall(function()return h.sequence end))
            for _,method in {P.publish_follow,P.read_follow,P.stop_follow,P.acknowledge_follow} do
                assert(not pcall(method,h,true))
                for _,bad in {body,{},'9007199254740995',1,false,newproxy()} do
                    assert(not pcall(method,bad))
                end
            end
            assert(not pcall(P.read,h) and not pcall(P.poll_motion_refresh_probe,h))
            reskate.log('strict follow arguments remain opaque')
        )",permissions)}); running(host,name,e);
        check(e.logged("strict follow arguments remain opaque") && e.fake.follow_reserves==1 &&
            !e.fake.follow_publishes && !e.fake.follow_reads && !e.fake.follow_stops && !e.fake.follow_acks,
            "malformed attachment or forged authority reached backend\n"+e.all());
        no_unrelated_effects(e);
    }

    // Independent fixed quotas reset once per plugin tick. Completed copied
    // history preserves all u64s exactly, and old handles cannot stop reuse.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.reserve_follow(body,attachment)==nil)
            for i=1,8 do
                local r=assert(P.read_follow(h));assert(r.phase=='reserved' and not r.terminal)
                assert(r.sequence=='9007199254740995' and r.final_revision=='0' and
                    r.final_native_epoch=='0' and r.returned_revision=='0')
                assert(not r.native_retirement_known and #r.pending==0)
            end
            assert(P.read_follow(h)==nil)
            assert(not P.acknowledge_follow(h) and not P.acknowledge_follow(h))
            assert(P.publish_follow(h) and not P.publish_follow(h))
            assert(P.stop_follow(h) and not P.stop_follow(h))
            local done=false
            reskate.on('tick',function()
                if done then return end
                local r=assert(P.read_follow(h));assert(r.phase=='completed' and r.terminal)
                assert(r.final_revision=='9007199254740997' and r.returned_revision==r.final_revision and
                    r.final_native_epoch=='9007199254741001')
                assert(r.park_observed and not r.claim_known and not r.native_retirement_known and #r.pending==0)
                r.final_revision='forged';r.pending[1]='forged';r.native_retirement_known=true
                local again=assert(P.read_follow(h));assert(again.final_revision=='9007199254740997' and
                    not again.native_retirement_known and #again.pending==0)
                assert(P.acknowledge_follow(h) and not P.acknowledge_follow(h))
                assert(P.read_follow(h)==nil)
                local next_body=make_body()
                local replacement,why=P.reserve_follow(next_body,attachment);assert(replacement and why==nil)
                assert(P.publish_follow(replacement))
                assert(not P.stop_follow(h))
                assert(P.read_follow(replacement).phase=='following')
                done=true;reskate.log('completed follow acknowledged and remounted with fresh authority')
            end)
        )",permissions)}); running(host,name,e);
        const auto old=e.fake.follow_fixture;
        e.fake.construct_follow_forwarded(); e.fake.construct_follow_completed(); ticks(host,e,1); running(host,name,e);
        check(e.logged("completed follow acknowledged and remounted with fresh authority") &&
            e.fake.follow_reserves==2 && e.fake.follow_publishes==2 && e.fake.follow_reads==12 &&
            e.fake.follow_stops==2 && e.fake.follow_acks==2,"quota, copied receipt or remount boundary failed\n"+e.all());
        const auto fresh=e.fake.follow_fixture;
        check(!e.fake.body_follow_stop(old.owner,old.receipt.handle) &&
            !e.fake.body_follow_acknowledge(old.owner,old.receipt.handle) &&
            e.fake.follow_fixture.receipt.handle.sequence==fresh.receipt.handle.sequence,
            "old sequence stopped or acknowledged replacement follow");
        no_unrelated_effects(e);
    }

    // Refusals consume the fixed quota. A partial reservation still returns
    // its cleanup capability; never-published ACK does not release the body.
    for (const bool partial : {false,true}) {
        TestEnvironment e; e.fake.follow_partial_refusal=partial; e.fake.follow_reserve_refusal=!partial;
        Host host(e,Side::client); const auto name=id();
        const std::string expectation=partial?R"(
            assert(h and why=='motion_owned')
            assert(P.read_follow(h).phase=='stopping')
            assert(not P.publish_follow(h))
            assert(not P.acknowledge_follow(h))
            local done=false
            reskate.on('tick',function()
                if done then return end
                assert(P.read_follow(h).phase=='abandoned')
                assert(P.acknowledge_follow(h))
                assert(P.read(body),'clean never-published ACK must not release caller body')
                assert(P.release(body))
                done=true;reskate.log('partial follow cleanup retained until clean abandon')
            end)
        )":R"(assert(h==nil and why=='unavailable'))";
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment)
            assert(P.reserve_follow(body,attachment)==nil)
        )"+expectation,permissions)}); running(host,name,e);
        check(e.fake.follow_reserves==1,"native reserve refusal was not charged to fixed quota");
        if (partial) {
            e.fake.construct_follow_abandoned(); ticks(host,e,1); running(host,name,e);
            check(e.logged("partial follow cleanup retained until clean abandon") && e.fake.follow_acks==2 &&
                e.fake.body_release_calls==1,"partial refused handle or clean body ownership was lost\n"+e.all());
        }
        no_unrelated_effects(e);
    }

    // Dropping a capability requests no native cleanup. This is not a forced
    // GC run (the sandbox does not export collectgarbage). Unload stops first,
    // retains the old owner, and a replacement VM gets no old authority.
    for (const bool published : {false,true}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        const std::string publication=published?"assert(P.publish_follow(h))":"";
        const auto candidate=script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
        )"+publication+R"(;h=nil)",permissions);
        host.apply({candidate}); running(host,name,e);
        const auto old=e.fake.follow_fixture;
        check(!e.fake.follow_stops && !e.fake.follow_acks,"dropping userdata released native follow authority");
        host.apply({});
        check(e.fake.follow_closes==1 && e.fake.follow_closed_before_body_cleanup &&
            e.fake.follow_fixture.owner==old.owner && e.fake.follow_fixture.receipt.orphaned,
            "unload lost owner cleanup or released body before follow stop");
        check(!e.fake.construct_orphan_host_cleanup(),"unresolved orphan duty was automatically acknowledged");
        const auto replacement=script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h==nil and why=='busy')
            local done=false
            reskate.on('tick',function()
                if done then return end
                local fresh,why=P.reserve_follow(body,attachment);assert(fresh and why==nil)
                assert(P.read_follow(fresh).phase=='reserved')
                done=true;reskate.log('fresh owner reserves after authenticated old-owner host cleanup')
            end)
        )",permissions);
        host.apply({replacement}); running(host,name,e);
        const auto replacement_owner=e.fake.owned.rbegin()->second.owner;
        f::Receipt denied;
        check(replacement_owner!=old.owner && !e.fake.body_follow_read(replacement_owner,old.receipt.handle,denied) &&
            !e.fake.body_follow_stop(replacement_owner,old.receipt.handle) &&
            !e.fake.body_follow_acknowledge(replacement_owner,old.receipt.handle),
            "replacement VM inherited abandoned owner's authority");
        if (published) e.fake.construct_follow_completed();
        else e.fake.construct_follow_abandoned();
        check(e.fake.construct_orphan_host_cleanup() && e.fake.follow_host_cleanups==1,
            "constructed qualified old-owner host cleanup failed");
        ticks(host,e,1);running(host,name,e);
        check(e.logged("fresh owner reserves after authenticated old-owner host cleanup") &&
            e.fake.follow_fixture.owner==replacement_owner &&
            e.fake.follow_fixture.receipt.handle.sequence!=old.receipt.handle.sequence,
            "clean orphan slot did not admit fresh replacement identity\n"+e.all());
        check(!e.fake.body_follow_stop(old.owner,old.receipt.handle) &&
            !e.fake.body_follow_acknowledge(old.owner,old.receipt.handle),
            "old owner's late callback adopted replacement authority");
        no_unrelated_effects(e);
    }

    // The ordinary plugin transport refuses userdata before calling the other
    // plugin's API. No integer/string/table can stand in for the capability.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            reskate.expose({handle=function()return h end})
        )",permissions),script(name+"-foreign",R"(
            reskate.console.command('follow-transfer','x',function()
                local library=assert(reskate.require_plugin(')"+name+R"('))
                assert(not pcall(library.handle))
                reskate.log('follow userdata cannot cross plugin transport')
            end)
        )",permissions+R"(,"console")")});
        running(host,name,e); running(host,name+"-foreign",e);
        check(host.run_console("follow-transfer") && e.logged("follow userdata cannot cross plugin transport") &&
            !e.fake.follow_reads && !e.fake.follow_stops && !e.fake.follow_acks,"plugin transport leaked follow authority\n"+e.all());
        no_unrelated_effects(e);
    }

    // Invalid backend observations cannot be laundered into copied completion.
    for (unsigned corruption=1;corruption<=15;++corruption) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.publish_follow(h));local done=false
            reskate.on('tick',function()
                if done then return end
                local r,why=P.read_follow(h);assert(r==nil and why:find('invalid observations',1,true))
                done=true;reskate.log('malformed follow facts rejected')
            end)
        )",permissions)}); running(host,name,e);
        e.fake.construct_follow_forwarded(); e.fake.follow_corruption=corruption;
        ticks(host,e,1); running(host,name,e);
        check(e.logged("malformed follow facts rejected") && e.fake.follow_reserves==1 &&
            e.fake.follow_publishes==1 && e.fake.follow_reads==1 && !e.fake.follow_stops && !e.fake.follow_acks,
            "malformed follow DTO corruption "+std::to_string(corruption)+"\n"+e.all());
        no_unrelated_effects(e);
    }
    std::cout << "Body follow Lua: 9 groups, " << cases << " constructed Host scenarios; native Service not executed\n";
}
} // namespace
