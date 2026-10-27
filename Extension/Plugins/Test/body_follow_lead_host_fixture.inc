// The real Host/VM/parser over constructed Game results. This fixture checks
// argument delivery and denial, not native samples, prediction or gameplay.
namespace {
void body_follow_lead_host_fixture_v1() {
    namespace f = dingosdk::body_follow_api;
    const std::string permissions = R"("world.physics","world.physics.follow")";
    const std::string setup = R"(
        local P=reskate.world.physics;local v=vector.create
        local body=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
            capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
        local attachment={offset_from_com=v(0,.4,0),root_in_body={0,0,0,1}}
    )";
    unsigned scenarios{};
    const auto fixture_id = [&] { return "body-follow-lead-" + std::to_string(++scenarios); };
    const auto no_unrelated_effects = [](const TestEnvironment& e) {
        check(!e.fake.body_submit_entries && !e.fake.batch_calls && !e.rays && !e.fake.input_pulse_requests &&
            !e.fake.native_action_requests && !e.fake.native_recovery_requests && e.teleports.empty(),
            "follow lead invoked forces, queries, input, equipment, recovery or teleport");
    };

    // Permissions precede both handle parsing and lead parsing. The physics-only
    // case has a real Host-created body, so its refusal is specifically Follow.
    struct Grant { const char* permissions; const char* missing; bool actual_body; };
    for (const auto& grant : {
        Grant{"", "world.physics", false},
        Grant{R"("world.physics")", "world.physics.follow", true},
        Grant{R"("world.physics.follow")", "world.physics", false}}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=fixture_id();
        const std::string prefix = grant.actual_body ? setup :
            "local P=reskate.world.physics;local body={};local attachment={}\n";
        host.apply({script(name,prefix+"local missing='"+grant.missing+"'\n"+R"(
            for _,lead in {{steps=2,angular=true},{steps='bad',angular='bad'}} do
                attachment.lead=lead
                local ok,why=pcall(P.reserve_follow,body,attachment)
                assert(not ok and why:find('permission',1,true) and why:find(missing,1,true),why)
            end
            reskate.log('lead permission denied')
        )",grant.permissions)}); running(host,name,e);
        check(e.logged("lead permission denied") && !e.fake.follow_reserves && !e.fake.follow_publishes &&
            !e.fake.follow_reads && !e.fake.follow_stops && !e.fake.follow_acks &&
            !e.fake.follow_renewals && !e.fake.follow_lease_reads,
            "missing permission reached the lead backend\n"+e.all());
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::server); const auto name=fixture_id();
        host.apply({package(name,{{manifest_file,manifest(permissions,"server")},{"plugin/main.lua",R"(
            local ok,why=pcall(reskate.world.physics.reserve_follow,{},{lead={steps=2,angular=true}})
            assert(not ok and why:find('client phase only',1,true),why)
            reskate.log('server lead refused')
        )"}})}); running(host,name,e);
        check(e.logged("server lead refused") && !e.fake.follow_reserves,
            "server reached the lead backend\n"+e.all());
        no_unrelated_effects(e);
    }

    // Only the existing two permissions are granted. Every step/angular pair
    // is copied before Lua mutates the original nested table and replaces it.
    const auto selected = [&](const std::string& selection, f::Lead expected,
        f::MotionPolicy policy=f::MotionPolicy::native_lifetime,
        f::CleanupPolicy cleanup=f::CleanupPolicy::actor_lifetime) {
        TestEnvironment e; Host host(e,Side::client); const auto name=fixture_id();
        host.apply({script(name,setup+selection+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil,why)
            local original=attachment.lead
            if original then original.steps=255;original.angular='changed' end
            attachment.lead={steps=99,angular='replacement'}
            local r=assert(P.read_follow(h))
            local n=0 for _ in pairs(r) do n+=1 end
            assert(n==14 and r.lead==nil,'lead must not change the receipt schema')
            assert(r.phase=='reserved' and not r.native_retirement_known)
            reskate.log('lead copied at reserve')
        )",permissions)}); running(host,name,e);
        const auto& copied=e.fake.follow_fixture.attachment;
        check(e.logged("lead copied at reserve") && e.fake.follow_reserves==1 && e.fake.follow_reads==1 &&
            copied.lead.steps==expected.steps && copied.lead.angular==expected.angular &&
            copied.motion_policy==policy && copied.cleanup==cleanup && copied.lifetime==f::Lifetime::fixed &&
            !e.fake.follow_publishes && !e.fake.follow_stops && !e.fake.follow_acks &&
            !e.fake.follow_renewals && !e.fake.follow_lease_reads,
            "lead/default policy was lost, changed by table mutation, or acted elsewhere\n"+e.all());
        no_unrelated_effects(e);
    };
    selected("",{});
    selected("attachment.lead=nil\n",{});
    for (unsigned steps=0; steps<=3; ++steps) {
        for (const bool angular : {false,true}) {
            selected("attachment.lead={steps="+std::to_string(steps)+",angular="+
                (angular ? "true" : "false")+"}\n",{static_cast<std::uint8_t>(steps),angular});
        }
    }
    selected("attachment.lead={steps=-0.0,angular=false}\n",{});
    selected("attachment.cleanup='owned_body';attachment.motion_policy='callback_entry'\n"
        "attachment.lead={steps=2,angular=true}\n",{2,true},
        f::MotionPolicy::callback_entry,f::CleanupPolicy::owned_body);

    // Each invalid group gets a fresh VM and ends with one valid reservation.
    // That successful reserve proves parser failures never spent its quota.
    const auto rejected = [&](const std::string& attempts) {
        TestEnvironment e; Host host(e,Side::client); const auto name=fixture_id();
        host.apply({script(name,setup+R"(
            local function denied(lead,expected)
                attachment.lead=lead
                local ok,why=pcall(P.reserve_follow,body,attachment)
                assert(not ok and why:find(expected,1,true),tostring(why))
            end
        )"+attempts+R"(
            attachment.lead={steps=2,angular=true}
            local h,why=P.reserve_follow(body,attachment)
            assert(h and why==nil,'invalid lead spent the reserve quota: '..tostring(why))
            reskate.log('invalid lead refused before reserve')
        )",permissions)}); running(host,name,e);
        check(e.logged("invalid lead refused before reserve") && e.fake.follow_reserves==1 &&
            e.fake.follow_fixture.attachment.lead.steps==2 && e.fake.follow_fixture.attachment.lead.angular &&
            !e.fake.follow_publishes && !e.fake.follow_reads && !e.fake.follow_stops && !e.fake.follow_acks,
            "malformed lead reached the backend or consumed reserve quota\n"+e.all());
        no_unrelated_effects(e);
    };
    rejected(R"(
        for _,bad in {false,true,0,2,'2','lead',newproxy(),vector.create(0,0,0),function()end} do
            denied(bad,'follow lead is a table with steps and angular')
        end
    )");
    rejected(R"(
        denied({},'follow lead steps is an integer 0 to 3')
        denied({angular=true},'follow lead steps is an integer 0 to 3')
        for _,bad in {false,true,'0','2',{},newproxy(),vector.create(0,0,0),function()end,
            0/0,math.huge,-math.huge,-1,4,.5,3.5,1e300,-1e-100,3.000001} do
            denied({steps=bad,angular=true},'follow lead steps is an integer 0 to 3')
        end
    )");
    rejected(R"(
        denied({steps=2},'follow lead angular is a boolean')
        for _,bad in {0,1,'true','false','',{},newproxy(),vector.create(0,0,0),function()end} do
            denied({steps=2,angular=bad},'follow lead angular is a boolean')
        end
    )");
    rejected(R"(
        for _,bad in {
            {steps=2,angular=true,feed=false},
            {steps=2,angular=true,max_speed=28},
            {steps=2,angular=true,velocity=vector.create(1,0,0)},
            {steps=2,angular=true,[1]=0},
            {steps=2,angular=true,[false]=true},
            {steps=2,angular=true,['steps\0extra']=2},
            {steps=2,angular=true,['angular\0extra']=true}
        } do denied(bad,'unknown native body field') end
    )");
    rejected(R"(
        denied(setmetatable({steps=2,angular=true},{}),'follow lead must be a plain table')
        denied(setmetatable({steps=2,angular=true},{__metatable='locked'}),'follow lead must be a plain table')
        local invoked=false
        local inherited=setmetatable({}, {__index=function()
            invoked=true
            error('lead metamethod must not run')
        end})
        denied(inherited,'follow lead must be a plain table')
        assert(not invoked,'lead parsing invoked a metamethod')
    )");
    std::cout<<"Body follow lead Lua: "<<scenarios<<" constructed Host scenarios; native Service not executed\n";
}
} // namespace