// The real Host/VM/API over constructed Game leaf results for a renewable
// Follow lease. No native Service, World proof, guard or game clock runs here;
// the bounds themselves are covered by the constructed Service target.
namespace {
void body_follow_renew_host_fixture_v1() {
    namespace f = dingosdk::body_follow_api;
    using Refusal = dingosdk::body_follow_lease::Refusal;
    const std::string permissions = R"("world.physics","world.physics.follow","world.physics.follow.renew")";
    const std::string setup = R"(
        local P=reskate.world.physics;local v=vector.create
        local function make_body()
            return assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
                capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
        end
        local body=make_body()
        local attachment={offset_from_com=v(0,.4,0),root_in_body={0,0,0,1},cleanup='owned_body',lifetime='renewable'}
    )";
    const std::string session_permissions = permissions + R"(,"world.physics.follow.session")";
    unsigned cases{};
    const auto id = [&] { return "body-follow-renew-" + std::to_string(++cases); };
    const auto no_unrelated_effects = [](const TestEnvironment& e) {
        check(!e.fake.body_submit_entries && !e.fake.batch_calls && !e.rays && !e.fake.input_pulse_requests &&
            !e.fake.native_action_requests && !e.fake.native_recovery_requests && e.teleports.empty(),
            "follow renewal invoked forces, queries, input, equipment, recovery or teleport");
    };
    check(known_permission("world.physics.follow.renew"), "the renewal permission is in the manifest registry");
    check(known_permission("world.physics.follow.session"), "the session permission is in the manifest registry");

    // Each missing permission is named before any argument is read, and a
    // denied renewable reserve spends no reserve quota.
    struct Grant { std::string granted, missing; bool can_reserve; };
    for (const auto& grant : {
        Grant{"", R"("world.physics")", false},
        Grant{R"("world.physics")", R"("world.physics.follow")", false},
        Grant{R"("world.physics","world.physics.follow")", R"("world.physics.follow.renew")", true},
        Grant{R"("world.physics","world.physics.follow.renew")", R"("world.physics.follow")", false},
        Grant{R"("world.physics.follow","world.physics.follow.renew")", R"("world.physics")", false}}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        const std::string missing = "local missing=[[" + grant.missing + "]]\n";
        const std::string reserve = grant.can_reserve ? R"(
            local P=reskate.world.physics;local v=vector.create
            local body=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
                capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
            -- The attachment is parsed first: a malformed one raises its own error.
            local ok,why=pcall(P.reserve_follow,body,{offset_from_com=v(0,0,0),root_in_body={0,0,0,0},
                cleanup='owned_body',lifetime='renewable'})
            assert(not ok and why:find('attachment',1,true) and not why:find('permission',1,true),why)
            ok,why=pcall(P.reserve_follow,body,{offset_from_com=v(0,0,0),root_in_body={0,0,0,1},lifetime='renewable'})
            assert(not ok and why:find('cleanup=owned_body',1,true) and not why:find('permission',1,true),why)
            -- Then the permission, before the quota.
            ok,why=pcall(P.reserve_follow,body,{offset_from_com=v(0,0,0),root_in_body={0,0,0,1},
                cleanup='owned_body',lifetime='renewable'})
            assert(not ok and why:find(missing,1,true),why)
            local h,refused=P.reserve_follow(body,{offset_from_com=v(0,0,0),root_in_body={0,0,0,1},cleanup='owned_body'})
            assert(h and refused==nil,'the denied renewable reserve spent the reserve quota')
        )" : R"(
            local ok,why=pcall(reskate.world.physics.reserve_follow,{},{lifetime='renewable',cleanup='owned_body'})
            assert(not ok and why:find('permission',1,true),why)
        )";
        host.apply({script(name,missing+R"(
            for _,method in {'renew_follow','read_follow_lease'} do
                local ok,why=pcall(reskate.world.physics[method],{},{})
                assert(not ok and why:find(missing,1,true),method..': '..tostring(why))
            end
        )"+reserve+"reskate.log('renew permission denied')\n",grant.granted)}); running(host,name,e);
        check(e.logged("renew permission denied") && e.fake.follow_reserves==(grant.can_reserve?1u:0u) &&
            !e.fake.follow_renewals && !e.fake.follow_lease_reads && !e.fake.follow_publishes && !e.fake.follow_reads,
            "a missing permission reached the renewal backend or spent reserve quota\n"+e.all());
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::server); const auto name=id();
        host.apply({package(name,{{manifest_file,manifest(permissions,"server")},{"plugin/main.lua",R"(
            for _,call in {function() return reskate.world.physics.renew_follow({},{}) end,
                function() return reskate.world.physics.read_follow_lease({}) end,
                function() return reskate.world.physics.reserve_follow({},{lifetime='renewable',cleanup='owned_body'}) end} do
                local ok,why=pcall(call)
                assert(not ok and why:find('client phase only',1,true),why)
            end
            reskate.log('server renewal refused')
        )"}})}); running(host,name,e);
        check(e.logged("server renewal refused") && !e.fake.follow_reserves && !e.fake.follow_renewals && !e.fake.follow_lease_reads,
            "the server reached the renewal backend\n"+e.all());
        no_unrelated_effects(e);
    }

    // Lifetime parsing: omitted, nil and "fixed" keep the fixed lease; only the
    // exact "renewable" with owned-body cleanup opts in. Bad values raise before the backend.
    struct LifetimeCase { const char* source; f::Lifetime expected; };
    for (const auto& lifetime : {LifetimeCase{"attachment.lifetime=nil\n", f::Lifetime::fixed},
        LifetimeCase{"attachment.lifetime='fixed'\n", f::Lifetime::fixed}, LifetimeCase{"", f::Lifetime::renewable},
        LifetimeCase{"attachment.lifetime='session_renewable'\n", f::Lifetime::session_renewable}}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+lifetime.source+R"(
            for _,bad in {'Renewable','renewable ','renewable\0x','Session_renewable','session_renewable ','session_renewable\0x','',false,true,7,{},function()end} do
                local saved=attachment.lifetime
                attachment.lifetime=bad
                local ok,why=pcall(P.reserve_follow,body,attachment)
                assert(not ok and why:find('lifetime',1,true),tostring(why))
                attachment.lifetime=saved
            end
            if attachment.lifetime=='renewable' or attachment.lifetime=='session_renewable' then
                for _,cleanup in {false,true} do
                    attachment.cleanup=if cleanup then 'actor_lifetime' else nil
                    local ok,why=pcall(P.reserve_follow,body,attachment)
                    assert(not ok and why:find('lifetime='..attachment.lifetime..' requires explicit cleanup=owned_body',1,true),why)
                end
                attachment.cleanup='owned_body'
            end
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            attachment.lifetime='fixed';attachment.cleanup='actor_lifetime'
            local r=assert(P.read_follow(h))
            local n=0 for _ in pairs(r) do n+=1 end
            assert(n==14 and r.lifetime==nil,'the receipt keeps its fourteen fields and echoes no lifetime')
            reskate.log('lifetime parsed')
        )",session_permissions)}); running(host,name,e);
        check(e.logged("lifetime parsed") && e.fake.follow_reserves==1 &&
            e.fake.follow_fixture.attachment.lifetime==lifetime.expected &&
            e.fake.follow_fixture.attachment.cleanup==f::CleanupPolicy::owned_body,
            "the lifetime was lost, changed by table mutation, or reached the backend malformed\n"+e.all());
        no_unrelated_effects(e);
    }
    {
        f::Attachment attachment; attachment.lifetime=f::Lifetime::renewable;
        check(!f::valid(attachment),"C++ renewable lifetime accepted the default actor-lifetime cleanup");
        attachment.cleanup=f::CleanupPolicy::owned_body;
        check(f::valid(attachment),"C++ renewable lifetime refused owned-body cleanup");
        attachment.lifetime=f::Lifetime::session_renewable; attachment.cleanup=f::CleanupPolicy::actor_lifetime;
        check(!f::valid(attachment),"C++ session lifetime accepted actor-lifetime cleanup");
        attachment.cleanup=f::CleanupPolicy::owned_body;
        check(f::valid(attachment),"C++ session lifetime refused owned-body cleanup");
        attachment.lifetime=static_cast<f::Lifetime>(255);
        check(!f::valid(attachment),"C++ unknown lifetime accepted");
    }

    // Arguments: strict arity, the opaque handle, and an epoch of this VM for
    // the followed body. A receipt successor's epoch reaches the backend; whether
    // it is still the body's latest sample is the runtime's check.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.publish_follow(h))
            local s=assert(P.read(body))
            local other=make_body()
            local o=assert(P.read(other))
            assert(not pcall(P.renew_follow,h))
            assert(not pcall(P.renew_follow,h,s.epoch,1))
            for _,bad in {{},1,'1',false,newproxy(),body,h} do assert(not pcall(P.renew_follow,h,bad)) end
            for _,bad in {{},1,'9007199254740995',false,newproxy(),body,s.epoch} do assert(not pcall(P.renew_follow,bad,s.epoch)) end
            local ok,why=pcall(P.renew_follow,h,o.epoch)
            assert(not ok and why:find('another body',1,true),why)
            assert(not pcall(P.read_follow_lease,h,true))
            for _,bad in {{},1,'9007199254740995',false,newproxy(),body,s.epoch} do assert(not pcall(P.read_follow_lease,bad)) end
            assert(P.submit(body,s.epoch,{force=v(0,10,0)}))
            local done=false
            reskate.on('tick',function()
                if done then return end
                local r=assert(P.receipt(body))
                if not r.successor then return end
                local renewed,remaining=P.renew_follow(h,r.successor.epoch)
                assert(renewed==true and remaining==500)
                done=true;reskate.log('successor epoch renewed '..r.successor.serial)
            end)
        )",permissions)}); running(host,name,e);
        check(!e.fake.follow_renewals && !e.fake.follow_lease_reads,"a malformed argument reached the renewal backend\n"+e.all());
        e.fake.body_producer_step(); ticks(host,e,1); running(host,name,e);
        e.fake.body_producer_step(); ticks(host,e,1); running(host,name,e);
        check(e.logged("successor epoch renewed 102") && e.fake.follow_renewals==1 && e.fake.follow_renew_epoch.serial==102,
            "a receipt successor's epoch did not reach the backend\n"+e.all());
    }
    // An epoch cannot travel to another plugin instance at all.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local s=assert(P.read(body))
            reskate.expose({epoch=function()return s.epoch end})
        )",permissions),script(name+"-foreign",R"(
            reskate.console.command('epoch-transfer','x',function()
                local library=assert(reskate.require_plugin(')"+name+R"('))
                assert(not pcall(library.epoch))
                reskate.log('body epoch cannot cross plugin transport')
            end)
        )",permissions+R"(,"console")")});
        running(host,name,e); running(host,name+"-foreign",e);
        check(host.run_console("epoch-transfer") && e.logged("body epoch cannot cross plugin transport") && !e.fake.follow_renewals,
            "plugin transport leaked a body epoch\n"+e.all());
    }

    // Quotas: one renewal and eight lease reads a tick, on their own counters.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.publish_follow(h))
            local s=assert(P.read(body))
            local ok,remaining=P.renew_follow(h,s.epoch);assert(ok==true and remaining==500)
            local again,why2=P.renew_follow(h,s.epoch)
            assert(again==false and why2=='asked to renew follow more than once in one tick')
            for i=1,8 do assert(P.read_follow_lease(h)) end
            local l,why3=P.read_follow_lease(h)
            assert(l==nil and why3=='asked to read follow lease more than 8 times in one tick')
            for i=1,8 do assert(P.read_follow(h)) end
            local done=false
            reskate.on('tick',function()
                if done then return end
                assert(P.renew_follow(h,assert(P.read(body)).epoch))
                assert(P.read_follow_lease(h))
                done=true;reskate.log('renewal quotas reset')
            end)
        )",permissions)}); running(host,name,e);
        check(e.fake.follow_renewals==1 && e.fake.follow_lease_reads==8 && e.fake.follow_reads==8,
            "a quota refusal reached the backend, or renewal shared the receipt read counter\n"+e.all());
        ticks(host,e,1); running(host,name,e);
        check(e.logged("renewal quotas reset") && e.fake.follow_renewals==2 && e.fake.follow_lease_reads==9,
            "the renewal quotas did not reset on the next tick\n"+e.all());
        no_unrelated_effects(e);
    }

    // Returns: true with whole milliseconds from 1 to 120000 only, and each
    // refusal string unchanged. A refused or malformed result is never true.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.publish_follow(h))
            reskate.on('tick',function()
                local ok,v=P.renew_follow(h,assert(P.read(body)).epoch)
                reskate.log('renew '..tostring(ok)..' '..tostring(v))
            end)
        )",permissions)}); running(host,name,e);
        const std::string invalid = "renew false follow renewal returned invalid observations";
        for (const auto& [remaining, expected] : std::initializer_list<std::pair<std::uint64_t, std::string>>{
            {1, "renew true 1"}, {120000, "renew true 120000"}, {0, invalid}, {120001, invalid}}) {
            e.fake.follow_renew_remaining = remaining; e.logs.clear();
            ticks(host,e,1); running(host,name,e);
            check(e.logged(expected),"renewal time "+std::to_string(remaining)+" was not "+expected+"\n"+e.all());
        }
        e.fake.follow_renew_remaining = 500;
        for (const auto refusal : {Refusal::not_renewable, Refusal::not_following, Refusal::sample_not_advanced,
            Refusal::sample_stale, Refusal::body_unavailable, Refusal::busy, Refusal::lifetime_exhausted, Refusal::expired,
            Refusal::client_not_ready, Refusal::focus_lost, Refusal::menu_open, Refusal::pause_menu_open,
            Refusal::debug_control, Refusal::actor_state}) {
            e.fake.follow_renew_refusal = refusal; e.logs.clear();
            ticks(host,e,1); running(host,name,e);
            const std::string expected = std::string("renew false ") + dingosdk::body_follow_lease::refusal_name(refusal);
            check(e.logged(expected),"refusal was not passed through unchanged: "+expected+"\n"+e.all());
        }
        e.fake.follow_renew_refusal = static_cast<Refusal>(200); e.logs.clear();
        ticks(host,e,1); running(host,name,e);
        check(e.logged(invalid),"an unknown refusal reached Lua\n"+e.all());
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            attachment.lifetime=nil
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.publish_follow(h))
            local ok,v=P.renew_follow(h,assert(P.read(body)).epoch)
            assert(ok==false and v=='not_renewable')
            local l=assert(P.read_follow_lease(h))
            assert(l.renewable==false and l.lifetime_ms==3000 and l.remaining_ms==l.lifetime_remaining_ms)
            reskate.log('fixed follow reports a fixed lease')
        )",permissions)}); running(host,name,e);
        check(e.logged("fixed follow reports a fixed lease") && e.fake.follow_renewals==1,
            "a fixed Follow's renewal or lease report changed\n"+e.all());
    }

    // The lease report: a freshly copied thirteen-field table, and malformed
    // backend facts refused rather than passed on.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.publish_follow(h))
            assert(P.renew_follow(h,assert(P.read(body)).epoch))
            local l=assert(P.read_follow_lease(h))
            local n=0 for _ in pairs(l) do n+=1 end
            assert(n==13 and l.session_renewable==false,'thirteen lease fields; legacy mode remains explicit')
            assert(l.sequence=='9007199254740995' and l.renewable==true and l.active==true and l.renewals=='1' and
                l.last_serial=='9007199254740991' and l.remaining_ms==1500 and l.lifetime_remaining_ms==90000 and
                l.base_ms==3000 and l.renewal_ms==500 and l.lifetime_ms==120000 and l.revocation=='none' and
                l.dispatch_busy=='9007199254740993')
            l.renewals='99';l.revocation='other'
            local again=assert(P.read_follow_lease(h))
            assert(again.renewals=='1' and again.revocation=='none','editing the copy changed nothing')
            local r=assert(P.read_follow(h))
            local fields=0 for _ in pairs(r) do fields+=1 end
            assert(fields==14 and r.phase=='following' and r.reason=='none','a renewed receipt keeps its shape')
            reskate.log('lease report copied')
            reskate.on('tick',function()
                local lease,why2=P.read_follow_lease(h)
                reskate.log('lease '..(if lease then 'table' else 'nil')..' '..tostring(why2))
            end)
        )",permissions)}); running(host,name,e);
        check(e.logged("lease report copied"),"the lease report fields\n"+e.all());
        const std::string refused = "lease nil follow lease returned invalid observations";
        for (unsigned corruption = 1; corruption <= 19; ++corruption) {
            e.fake.follow_lease_corruption = corruption; e.logs.clear();
            ticks(host,e,1); running(host,name,e);
            check(e.logged(refused),"malformed lease corruption "+std::to_string(corruption)+" was passed on\n"+e.all());
        }
        e.fake.follow_lease_corruption = 0; e.logs.clear();
        ticks(host,e,1); running(host,name,e);
        check(e.logged("lease table nil"),"a well-formed lease was refused after the malformed ones\n"+e.all());
        no_unrelated_effects(e);
    }

    // Busy and unavailable reads are told apart, and each spends a read.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            reskate.on('tick',function()
                local r,why2=P.read_follow(h)
                reskate.log('read '..tostring(r and r.phase)..' '..tostring(why2))
                local l,why3=P.read_follow_lease(h)
                reskate.log('lease '..tostring(l and l.revocation)..' '..tostring(why3))
            end)
        )",permissions)}); running(host,name,e);
        e.fake.follow_read_busy = e.fake.follow_lease_busy = true;
        ticks(host,e,1); running(host,name,e);
        check(e.logged("read nil follow receipt busy") && e.logged("lease nil follow lease busy"),
            "a busy read was not reported as busy\n"+e.all());
        e.fake.follow_read_busy = e.fake.follow_lease_busy = false;
        e.fake.follow_fixture = {}; e.logs.clear();
        ticks(host,e,1); running(host,name,e);
        check(e.logged("read nil follow receipt unavailable") && e.logged("lease nil follow lease unavailable"),
            "an unavailable read lost its original string\n"+e.all());
        check(e.fake.follow_reads==2 && e.fake.follow_lease_reads==2,"each busy or unavailable read reached the backend once\n"+e.all());
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        e.fake.follow_read_busy = true;
        host.apply({script(name,setup+R"(
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            for i=1,8 do local r,why2=P.read_follow(h);assert(r==nil and why2=='follow receipt busy') end
            local r,why3=P.read_follow(h)
            assert(r==nil and why3=='asked to read follow more than 8 times in one tick')
            reskate.log('busy reads spend the read quota')
        )",permissions)}); running(host,name,e);
        check(e.logged("busy reads spend the read quota") && e.fake.follow_reads==8,"a busy read did not spend a read\n"+e.all());
    }
    // Session reserve adds a permission before quota/backend. The old renewable
    // mode remains available without it; no denied call can spend that reserve.
    for (const bool grant_renew : {false, true}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        const auto granted = grant_renew ? permissions :
            std::string(R"("world.physics","world.physics.follow","world.physics.follow.session")");
        const auto missing = grant_renew ? "world.physics.follow.session" : "world.physics.follow.renew";
        host.apply({script(name,setup+"local missing='"+missing+"'\n"+R"(
            attachment.lifetime='session_renewable'
            for i=1,3 do
                local ok,why=pcall(P.reserve_follow,body,attachment)
                assert(not ok and why:find(missing,1,true),why)
            end
            reskate.log('session reserve permission refused')
            local done=false
            reskate.on('tick',function()
                if done then return end
                for i=1,3 do
                    local ok,why=pcall(P.reserve_follow,body,attachment)
                    assert(not ok and why:find(missing,1,true),why)
                end
                attachment.lifetime=if missing=='world.physics.follow.session' then 'renewable' else 'fixed'
                local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
                done=true;reskate.log('denied session spent no reserve')
            end)
        )",granted)}); running(host,name,e);
        check(e.logged("session reserve permission refused") && !e.fake.follow_reserves && !e.fake.follow_renewals &&
            !e.fake.follow_lease_reads && !e.fake.follow_publishes,
            "a denied session request reached the native backend\n"+e.all());
        ticks(host,e,1); running(host,name,e);
        check(e.logged("denied session spent no reserve") && e.fake.follow_reserves==1 &&
            e.fake.follow_fixture.attachment.lifetime==(grant_renew?f::Lifetime::renewable:f::Lifetime::fixed),
            "session permission denial consumed authority or changed a legacy mode\n"+e.all());
        no_unrelated_effects(e);
    }

    // A session's copied DTO has no absolute lifetime. It still carries a
    // positive short deadline, and an invalid combination is never a lease.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            attachment.lifetime='session_renewable'
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            attachment.lifetime='fixed'
            assert(P.publish_follow(h))
            local other=make_body()
            local epoch=assert(P.read(body)).epoch
            local wrong=assert(P.read(other)).epoch
            local ok,refused=pcall(P.renew_follow,h,wrong)
            assert(not ok and refused:find('another body',1,true),refused)
            for _,bad in {{},false,body,epoch} do
                assert(not pcall(P.renew_follow,bad,epoch))
                assert(not pcall(P.read_follow_lease,bad))
            end
            reskate.log('session foreign authority refused')
            local done=false
            reskate.on('tick',function()
                local ok2,v=P.renew_follow(h,assert(P.read(body)).epoch)
                local l,why2=P.read_follow_lease(h)
                if not done then
                    assert(ok2 and v==500)
                    assert(l and l.session_renewable==true and l.renewable==true and l.active==true and
                        l.lifetime_ms==0 and l.lifetime_remaining_ms==0 and l.remaining_ms==1500 and
                        l.base_ms==3000 and l.renewal_ms==500 and l.renewals=='1',why2)
                    local count=0 for _ in pairs(l) do count+=1 end
                    assert(count==13)
                    done=true;reskate.log('session lease copied')
                end
                reskate.log('session renew '..tostring(ok2)..' '..tostring(v))
                reskate.log('session lease '..(if l then 'table' else 'nil')..' '..tostring(why2))
            end)
        )",session_permissions)}); running(host,name,e);
        check(e.logged("session foreign authority refused") && !e.fake.follow_renewals && !e.fake.follow_lease_reads &&
            e.fake.follow_reserves==1 && e.fake.follow_fixture.attachment.lifetime==f::Lifetime::session_renewable,
            "foreign session authority reached renewal/lease backend or attachment mutation changed its lifetime\n"+e.all());
        ticks(host,e,1); running(host,name,e);
        check(e.logged("session lease copied"),"session DTO lost its explicit lifetime semantics\n"+e.all());
        for (unsigned corruption=1;corruption<=19;++corruption) {
            e.fake.follow_lease_corruption=corruption;e.logs.clear();
            ticks(host,e,1);running(host,name,e);
            check(e.logged("session lease nil follow lease returned invalid observations"),
                "malformed session lease "+std::to_string(corruption)+" reached Lua\n"+e.all());
        }
        no_unrelated_effects(e);
    }
    // Each bound gets a fresh VM and environment. Clearing captured logs does
    // not reset the VM's real 50-lines-per-second allowance from the DTO cases.
    for (const auto remaining : {std::uint64_t{1},std::uint64_t{2900},std::uint64_t{3000},std::uint64_t{0},std::uint64_t{3001}}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        e.fake.follow_renew_remaining=remaining;
        const std::string expected = remaining && remaining<=3000 ?
            "assert(ok==true and value=="+std::to_string(remaining)+")\n" :
            "assert(ok==false and value=='follow renewal returned invalid observations')\n";
        host.apply({script(name,setup+R"(
            attachment.lifetime='session_renewable'
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.publish_follow(h))
            local ok,value=P.renew_follow(h,assert(P.read(body)).epoch)
        )"+expected+R"(
            reskate.log('session renewal bound checked')
        )",session_permissions)});running(host,name,e);
        check(e.logged("session renewal bound checked") && e.fake.follow_renewals==1 &&
            e.fake.follow_fixture.attachment.lifetime==f::Lifetime::session_renewable,
            "session renewal bound "+std::to_string(remaining)+" was not checked exactly once\n"+e.all());
        no_unrelated_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,setup+R"(
            attachment.lifetime='session_renewable'
            local h,why=P.reserve_follow(body,attachment);assert(h and why==nil)
            assert(P.publish_follow(h));assert(P.stop_follow(h))
            local l=assert(P.read_follow_lease(h))
            assert(l.session_renewable and l.renewable and not l.active and l.remaining_ms==0 and
                l.lifetime_remaining_ms==0 and l.lifetime_ms==0 and l.revocation=='other')
            local ok,refused=P.renew_follow(h,assert(P.read(body)).epoch)
            assert(not ok and refused=='not_following')
            reskate.log('stopped session stays stopped')
        )",session_permissions)});running(host,name,e);
        check(e.logged("stopped session stays stopped") && e.fake.follow_stops==1 && e.fake.follow_renewals==1,
            "a stopped session hid cleanup or revived\n"+e.all());
        no_unrelated_effects(e);
    }
    std::cout << "Body follow renewal Lua: " << cases << " constructed Host scenarios; native Service not executed\n";
}
} // namespace
