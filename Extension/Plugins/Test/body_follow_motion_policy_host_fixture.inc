// Actual Host/VM/parser over constructed Game results. This fixture does not
// execute NativeMotionEntry, Service dispatch, native lifetime or body park.
namespace {
void body_follow_motion_policy_host_fixture_v1() {
    namespace f = dingosdk::body_follow_api;
    const std::string permissions = R"("world.physics","world.physics.follow")";
    const std::string setup = R"(
        local P=reskate.world.physics;local v=vector.create
        local body=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
            capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
        local attachment={offset_from_com=v(0,.4,0),root_in_body={0,0,0,1}}
    )";
    unsigned scenarios{};
    const auto fixture_id = [&] { return "body-follow-motion-policy-" + std::to_string(++scenarios); };
    const auto no_unrelated_effects = [](const TestEnvironment& e) {
        check(!e.fake.body_submit_entries && !e.fake.batch_calls && !e.rays && !e.fake.input_pulse_requests &&
            !e.fake.native_action_requests && !e.fake.native_recovery_requests && e.teleports.empty(),
            "motion selection invoked forces, queries, input, equipment, recovery or teleport");
    };

    // The same two existing permissions precede attachment/handle parsing.
    // No additional permission, console command or caller proof is introduced.
    for (const auto& granted : {std::string{}, std::string{R"("world.physics")"},
        std::string{R"("world.physics.follow")"}}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=fixture_id();
        host.apply({script(name,R"(
            local ok,why=pcall(reskate.world.physics.reserve_follow,{},
                {motion_policy='callback_entry',cleanup='owned_body'})
            assert(not ok and why:find('world.physics',1,true))
        )",granted)}); running(host,name,e);
        check(!e.fake.follow_reserves && !e.fake.follow_publishes && !e.fake.follow_reads &&
            !e.fake.follow_stops && !e.fake.follow_acks,"missing permission reached selected-policy backend\n"+e.all());
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::server); const auto name=fixture_id();
        host.apply({package(name,{{manifest_file,manifest(permissions,"server")},{"plugin/main.lua",R"(
            local ok,why=pcall(reskate.world.physics.reserve_follow,{},
                {motion_policy='callback_entry',cleanup='owned_body'})
            assert(not ok and why:find('client phase only',1,true))
        )"}})}); running(host,name,e);
        check(!e.fake.follow_reserves,"server selected a native motion policy\n"+e.all());
        no_unrelated_effects(e);
    }
    check(known_permission("world.physics.follow"),"existing follow permission missing");

    struct Selection {
        const char* source;
        f::MotionPolicy expected_policy;
        f::CleanupPolicy expected_cleanup;
    };
    for (const auto& selection : {
        Selection{"",f::MotionPolicy::native_lifetime,f::CleanupPolicy::actor_lifetime},
        Selection{"attachment.motion_policy=nil\n",f::MotionPolicy::native_lifetime,f::CleanupPolicy::actor_lifetime},
        Selection{"attachment.motion_policy='native_lifetime'\n",f::MotionPolicy::native_lifetime,f::CleanupPolicy::actor_lifetime},
        Selection{"attachment.cleanup='owned_body';attachment.motion_policy='native_lifetime'\n",f::MotionPolicy::native_lifetime,f::CleanupPolicy::owned_body},
        Selection{"attachment.cleanup='owned_body';attachment.motion_policy='callback_entry'\n",f::MotionPolicy::callback_entry,f::CleanupPolicy::owned_body}}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=fixture_id();
        host.apply({script(name,setup+selection.source+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            attachment.motion_policy='unknown';attachment.cleanup='actor_lifetime'
            local r=assert(P.read_follow(h))
            assert(r.phase=='reserved' and not r.native_retirement_known)
            assert(r.motion_policy==nil and r.cleanup==nil,'receipt is unchanged, not a requested-policy echo')
            assert(P.publish_follow(h))
            assert(P.read_follow(h).phase=='following')
            reskate.log('motion selection copied at reserve')
        )",permissions)}); running(host,name,e);
        check(e.logged("motion selection copied at reserve") && e.fake.follow_reserves==1 &&
            e.fake.follow_publishes==1 && e.fake.follow_reads==2 &&
            e.fake.follow_fixture.attachment.motion_policy==selection.expected_policy &&
            e.fake.follow_fixture.attachment.cleanup==selection.expected_cleanup &&
            !e.fake.follow_stops && !e.fake.follow_acks,
            "default/explicit motion selection was lost, changed by table mutation, or acted elsewhere\n"+e.all());
        no_unrelated_effects(e);
    }

    // Invalid selectors fail in the real parser, before the reserve quota/backend.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=fixture_id();
        host.apply({script(name,setup+R"(
            attachment.cleanup='owned_body'
            for _,bad in {'','unknown','Callback_entry','callback_entry ','callback_entry\0other',
                'native_lifetime\0other',false,true,7,{},function()end} do
                attachment.motion_policy=bad
                local ok,why=pcall(P.reserve_follow,body,attachment)
                assert(not ok and why:find('motion_policy',1,true))
            end
            attachment.motion_policy='callback_entry'
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
        )",permissions)}); running(host,name,e);
        check(e.fake.follow_reserves==1 && e.fake.follow_fixture.attachment.motion_policy==f::MotionPolicy::callback_entry,
            "invalid motion selector reached backend or consumed reserve quota\n"+e.all());
        f::Attachment malformed; malformed.cleanup=f::CleanupPolicy::owned_body;
        malformed.motion_policy=static_cast<f::MotionPolicy>(255);
        check(!f::valid(malformed),"unknown C++ motion policy accepted");
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=fixture_id();
        host.apply({script(name,setup+R"(
            attachment.motion_policy='callback_entry'
            for _,explicit in {false,true} do
                attachment.cleanup=if explicit then 'actor_lifetime' else nil
                local ok,why=pcall(P.reserve_follow,body,attachment)
                assert(not ok and why:find('requires explicit cleanup=owned_body',1,true))
            end
            attachment.cleanup='owned_body'
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
        )",permissions)}); running(host,name,e);
        check(e.fake.follow_reserves==1 && e.fake.follow_fixture.attachment.motion_policy==f::MotionPolicy::callback_entry &&
            e.fake.follow_fixture.attachment.cleanup==f::CleanupPolicy::owned_body,
            "callback policy silently selected cleanup or rejected explicit owned cleanup\n"+e.all());
        f::Attachment callback_attachment; callback_attachment.motion_policy=f::MotionPolicy::callback_entry;
        check(!f::valid(callback_attachment),"C++ callback policy accepted default actor-lifetime cleanup");
        callback_attachment.cleanup=f::CleanupPolicy::owned_body;
        check(f::valid(callback_attachment),"C++ callback policy refused explicit owned cleanup");
        callback_attachment.cleanup=f::CleanupPolicy::actor_lifetime;
        check(!f::valid(callback_attachment),"C++ callback policy accepted explicit actor-lifetime cleanup");
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=fixture_id();
        host.apply({script(name,setup+R"(
            attachment.motion_policy='callback_entry';attachment.cleanup='owned_body'
            for _,bad in {newproxy(),{},'9007199254740995',1,false} do
                assert(not pcall(P.reserve_follow,bad,attachment))
            end
            attachment.scope=true;assert(not pcall(P.reserve_follow,body,attachment));attachment.scope=nil
            attachment.admission=function()return true end
            assert(not pcall(P.reserve_follow,body,attachment));attachment.admission=nil
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
        )",permissions)}); running(host,name,e);
        check(e.fake.follow_reserves==1,"selector accepted a forged body/scope/admission or spent its valid attempt\n"+e.all());
        no_unrelated_effects(e);
    }
    std::cout<<"Body follow motion policy Lua: "<<scenarios<<" constructed Host scenarios; native Service not executed\n";
}
} // namespace
