// Actual Host/API fixtures over controlled Game leaf results. No fixture is a
// native collector, actor qualification, stock-origin or consumption witness.
// Source-only candidate: the integrator owns every eventual compile/run.
namespace {
void motion_refresh_host_fixture_v1() {
    namespace m = dingosdk::motion_refresh_probe;
    const std::string permissions = R"("world.physics","world.physics.observe")";
    unsigned cases{};
    const auto id = [&] { return "motion-refresh-" + std::to_string(++cases); };
    const auto no_effects = [](const TestEnvironment& e, bool body_fixture = false, bool closed = false) {
        const auto& g = e.fake;
        check(!g.body_submit_entries && !g.body_submissions && !g.batch_calls && !g.batch_rays && !g.native_casts &&
            !e.rays && !e.native_ray_casts && e.teleports.empty() && !g.input_pulse_requests &&
            !g.native_action_requests && !g.native_recovery_requests && g.binds.empty(),
            "passive actor observation reached a force, query or actor-action entry");
        if (!body_fixture) check(!g.body_create_calls && !g.body_read_calls && !g.body_release_calls && g.owned.empty(),
            "actor-only observation depends on an owned body");
        if (!closed) check(g.calls.empty(), "passive observation invoked a wider Game action");
    };
    const std::string body_setup = R"(
        local P=reskate.world.physics;local v=vector.create
        local body=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
            capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
    )";

    // 1. Both existing permissions and the client phase precede argument work.
    for (const auto& granted : {std::string{},std::string(R"("world.physics")"),std::string(R"("world.physics.observe")")}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        const auto missing = granted == R"("world.physics")" ? "world.physics.observe" : "world.physics";
        const auto expected = "\"" + std::string(missing) + "\"";
        host.apply({script(name,std::string(R"(
            local P=reskate.world.physics
            for _,method in {'begin_motion_refresh_probe','poll_motion_refresh_probe'} do
                local ok,why=pcall(P[method],{}, {}, {})
                assert(not ok and why:find(')")+expected+R"(',1,true),method)
            end
        )",granted)}); running(host,name,e);
        check(!e.fake.motion_refresh_starts && !e.fake.motion_refresh_polls,"permission denial reached actor backend");
        no_effects(e);
    }
    {
        TestEnvironment e; Host host(e,Side::server); const auto name=id();
        host.apply({package(name,{{manifest_file,manifest(permissions,"server")},{"plugin/main.lua",R"(
            for _,method in {'begin_motion_refresh_probe','poll_motion_refresh_probe'} do
                local ok,why=pcall(reskate.world.physics[method],{}, {}, {})
                assert(not ok and why:find('client phase only'),method)
            end
        )"}})}); running(host,name,e);
        check(!e.fake.motion_refresh_starts && !e.fake.motion_refresh_polls,"server reached actor backend"); no_effects(e);
    }

    // 2. Actor-only admission, strict arguments, full zero DTO and copied facts.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,R"(
            local P=reskate.world.physics
            assert(not pcall(P.begin_motion_refresh_probe,nil))
            assert(not pcall(P.begin_motion_refresh_probe,{}))
            assert(not pcall(P.begin_motion_refresh_probe,newproxy(),{}))
            local probe=assert(P.begin_motion_refresh_probe())
            assert(type(probe)=='userdata' and getmetatable(probe)=='locked')
            assert(not pcall(function()return probe.sequence end))
            assert(not pcall(P.read,probe))
            assert(not pcall(P.poll_motion_refresh_probe))
            for _,bad in {{},'9007199254740995',1,false,newproxy()} do
                assert(not pcall(P.poll_motion_refresh_probe,bad))
            end
            assert(not pcall(P.poll_motion_refresh_probe,probe,probe))
            for i=1,8 do
                local r=assert(P.poll_motion_refresh_probe(probe))
                assert(r.status=='pending' and r.terminal==nil and not r.client_revalidated and r.elapsed_ms==0)
                assert(r.armed_epoch.world_generation=='9007199254740995')
                assert(r.armed_epoch.lifetime_epoch=='9007199254740997')
                assert(r.armed_epoch.actor_epoch=='0' and r.armed_epoch.serial=='9007199254741001')
                for _,key in {'world_generation','lifetime_epoch','actor_epoch','serial'} do
                    assert(r.confirmed_epoch[key]=='0' and r.record.before_epoch[key]=='0' and r.record.after_epoch[key]=='0')
                end
                assert(r.confirmed_epoch.time==0 and r.confirmed_epoch.seconds==0)
                assert(r.record.before_epoch.time==0 and r.record.before_epoch.seconds==0 and
                    r.record.after_epoch.time==0 and r.record.after_epoch.seconds==0)
                assert(not r.record.present and not r.record.unchanged_forwarding and r.record.flag==0 and #r.record.input==4)
                for _,value in r.record.input do assert(value==0)end
                for _,edge in {r.record.before,r.record.after} do
                    assert(#edge.root==16 and #edge.inverse==16 and #edge.caches==3 and #edge.packets==4 and #edge.flags==4)
                    for _,matrix in {edge.root,edge.inverse} do
                        for _,value in matrix do assert(value==0)end
                    end
                    for _,matrices in {edge.caches,edge.packets} do
                        for _,matrix in matrices do for _,value in matrix do assert(value==0)end end
                    end
                    for _,value in edge.flags do assert(value==0)end
                end
            end
            assert(P.poll_motion_refresh_probe(probe)==nil)
            assert(P.begin_motion_refresh_probe()==nil)
            local done=false
            reskate.on('tick',function()
                if done then return end
                local r=assert(P.poll_motion_refresh_probe(probe));local x=r.record
                assert(r.status=='observed' and r.client_revalidated and r.terminal==nil and x.present and x.unchanged_forwarding)
                assert(x.flag==165 and #x.input==4 and x.input[1]==.125 and x.input[2]==-.25)
                assert(x.before_epoch.serial=='9007199254741002' and x.after_epoch.serial==x.before_epoch.serial)
                assert(x.before_epoch.time==x.after_epoch.time and r.confirmed_epoch.serial=='9007199254741003')
                assert(x.before.root[13]==5 and x.before.inverse[13]==-5 and x.before.caches[3][13]==22)
                assert(x.after.packets[4][13]==43 and x.after.flags[4]==2147483651)
                assert(r.routing.entries==128 and r.routing.matching==200 and r.routing.other==201 and
                    r.routing.rejected==202 and r.routing.dropped==203 and r.routing.limit_reached)
                assert(not r.sequence and not r.actor and not r.body and not r.address and not r.native_consumed)
                assert(not x.before_epoch.world and not x.before_epoch.body and not x.before_epoch.address)
                assert(not pcall(P.read,r.armed_epoch))
                x.input[1]=999;x.before.root[13]=999;x.before.inverse[13]=999;x.before.caches[3][13]=999
                x.after.packets[4][13]=999;x.after.flags[4]=0;x.before_epoch.world_generation='1';r.routing.matching=0
                local copy=assert(P.poll_motion_refresh_probe(probe))
                assert(copy.record.input[1]==.125 and copy.record.before.root[13]==5 and copy.record.before.inverse[13]==-5)
                assert(copy.record.before.caches[3][13]==22 and copy.record.after.packets[4][13]==43)
                assert(copy.record.after.flags[4]==2147483651 and copy.record.before_epoch.world_generation=='9007199254740995')
                assert(copy.routing.matching==200)
                done=true;reskate.log('motion copied without native authority')
            end)
        )",permissions)}); running(host,name,e);
        check(e.fake.motion_refresh_starts==1 && e.fake.motion_refresh_polls==8,"invalid arguments or ninth poll reached actor backend");
        const auto deadline=e.fake.motion_refresh.deadline_ms;
        e.fake.complete_motion_refresh_probe(); ticks(host,e,1); running(host,name,e);
        check(e.logged("motion copied without native authority") && e.fake.motion_refresh_polls==10 &&
            e.fake.motion_refresh.deadline_ms==deadline, e.all()); no_effects(e);
    }
    for (const bool zero_sequence : {false,true}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        e.fake.motion_refresh_actor_available=zero_sequence;
        e.fake.motion_refresh_zero_sequence=zero_sequence;
        host.apply({script(name,R"(
            local P=reskate.world.physics;local h,why=P.begin_motion_refresh_probe()
            assert(h==nil and type(why)=='string' and #why>0)
            assert(P.begin_motion_refresh_probe()==nil)
        )",permissions)}); running(host,name,e);
        check(e.fake.motion_refresh_starts==1 && !e.fake.motion_refresh_polls,"unavailable/malformed admission bypassed shared quota");
        no_effects(e); host.apply({});
        check(!e.fake.motion_refresh.sequence,"owner close failed to clear an admitted malformed-sequence fixture");
    }

    // 3. Existing body/epoch/probe userdata and plugin transport cannot forge it.
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,body_setup+R"(
            local epoch=assert(P.read(body)).epoch
            local actor=assert(P.begin_motion_refresh_probe())
            assert(not pcall(P.begin_motion_refresh_probe,body) and not pcall(P.begin_motion_refresh_probe,epoch))
            assert(not pcall(P.poll_motion_refresh_probe,body) and not pcall(P.poll_motion_refresh_probe,epoch))
            assert(not pcall(P.poll_sync_probe,actor))
            local done=false
            reskate.on('tick',function()
                if done then return end
                local old=assert(P.begin_sync_probe(body))
                assert(not pcall(P.poll_motion_refresh_probe,old))
                assert(P.release(body))
                assert(assert(P.poll_motion_refresh_probe(actor)).status=='pending')
                done=true;reskate.log('motion probe type separation')
            end)
        )",permissions)}); running(host,name,e); ticks(host,e,1); running(host,name,e);
        check(e.logged("motion probe type separation") && e.fake.motion_refresh_polls==1 && !e.fake.sync_probe_polls,e.all());
        no_effects(e,true);
    }
    {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        const auto library=name+"-library";
        host.apply({script(library,R"(
            local h=assert(reskate.world.physics.begin_motion_refresh_probe())
            reskate.expose({probe=function()return h end})
        )",permissions),script(name,"local library='"+library+R"('
            reskate.console.command('motion-transfer','x',function()
                local other=assert(reskate.require_plugin(library))
                assert(not pcall(other.probe));reskate.log('motion transport denied')
            end)
        )",permissions+R"(,"console")")}); running(host,name,e); running(host,library,e);
        check(host.run_console("motion-transfer") && e.logged("motion transport denied") &&
            e.fake.motion_refresh_starts==1 && !e.fake.motion_refresh_polls,e.all()); no_effects(e);
    }

    // 4. One combined start, in both API orders, including backend refusals.
    for (const bool actor_first : {false,true}) for (const bool refused : {false,true}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        if (actor_first && refused) e.fake.motion_refresh_begin_error="constructed admission refusal";
        std::string code=body_setup;
        if (!actor_first && refused) code+="assert(P.release(body))\n";
        code+=actor_first?"local first=P.begin_motion_refresh_probe()\n":"local first=P.begin_sync_probe(body)\n";
        code+=refused?"assert(first==nil)\n":"assert(type(first)=='userdata')\n";
        code+=actor_first?"assert(P.begin_sync_probe(body)==nil)\n":"assert(P.begin_motion_refresh_probe()==nil)\n";
        code+=R"(local done=false;reskate.on('tick',function()if done then return end
        )";
        code+=actor_first?"assert(P.begin_sync_probe(body))\n":"assert(P.begin_motion_refresh_probe())\n";
        code+="done=true;reskate.log('motion shared start reset')end)";
        host.apply({script(name,code,permissions)}); running(host,name,e);
        check(e.fake.motion_refresh_starts==(actor_first?1u:0u) && e.fake.sync_probe_starts==(actor_first?0u:1u),
            "second start reached another backend in the same VM window");
        ticks(host,e,1); running(host,name,e);
        check(e.logged("motion shared start reset") && e.fake.motion_refresh_starts==1 && e.fake.sync_probe_starts==1,e.all());
        no_effects(e,true);
    }

    // 5. Eight combined polls; a timer and tick handler share one reset window.
    for (const bool actor_first : {false,true}) for (const bool refused : {false,true}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        if (refused) e.fake.motion_refresh_poll_error="constructed poll refusal";
        const auto code=body_setup+"local actor_first="+(actor_first?"true":"false")+
            ";local refused="+(refused?"true":"false")+R"(
            local actor=assert(P.begin_motion_refresh_probe());local old;local stage=0
            local function poll(actor_kind)
                local r,why
                if actor_kind then r,why=P.poll_motion_refresh_probe(actor) else r,why=P.poll_sync_probe(old)end
                if actor_kind and refused then assert(r==nil and why=='constructed poll refusal')else assert(type(r)=='table')end
            end
            reskate.on('tick',function()
                if stage==0 then
                    old=assert(P.begin_sync_probe(body));stage=1
                    reskate.time.after(0,function()for i=1,4 do poll(actor_first)end end)
                elseif stage==1 then
                    for i=1,4 do poll(not actor_first)end
                    assert(P.poll_motion_refresh_probe(actor)==nil and P.poll_sync_probe(old)==nil)
                    stage=2;reskate.log('motion eight shared polls')
                elseif stage==2 then
                    poll(true);poll(false);stage=3;reskate.log('motion shared poll reset')
                end
            end)
        )";
        host.apply({script(name,code,permissions)}); running(host,name,e); ticks(host,e,2); running(host,name,e);
        check(e.logged("motion eight shared polls") && e.fake.motion_refresh_polls==4 && e.fake.sync_probe_polls==4,e.all());
        ticks(host,e,1); running(host,name,e);
        check(e.logged("motion shared poll reset") && e.fake.motion_refresh_polls==5 && e.fake.sync_probe_polls==5,e.all());
        no_effects(e,true);
    }

    // 6. Nonobserved states may retain a record; elapsed/counters aren't clamped.
    for (const auto status : {m::Status::pending,m::Status::expired,m::Status::invalidated}) for (const bool present : {false,true}) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        e.fake.motion_refresh_actor.actor_epoch=9007199254740999ULL;
        host.apply({script(name,std::string(R"(
            local P=reskate.world.physics;local h=assert(P.begin_motion_refresh_probe())
            reskate.on('tick',function()
                local r=assert(P.poll_motion_refresh_probe(h))
                assert(r.status==')")+(status==m::Status::pending?"pending":status==m::Status::expired?"expired":"invalidated")+R"(')
                assert(r.armed_epoch.actor_epoch=='9007199254740999' and not r.client_revalidated and r.terminal==nil)
                for _,key in {'world_generation','lifetime_epoch','actor_epoch','serial'} do assert(r.confirmed_epoch[key]=='0')end
                assert(r.confirmed_epoch.time==0 and r.confirmed_epoch.seconds==0)
                assert(r.record.present==)"+(present?"true":"false")+R"( and r.routing.dropped==4294967295)
                assert(r.elapsed_ms==)"+(status==m::Status::pending?"100":"1500")+R"()
                reskate.log('motion valid nonobserved shape')
            end)
        )",permissions)}); running(host,name,e);
        if (present) e.fake.complete_motion_refresh_probe();
        auto& result=e.fake.motion_refresh.result;
        result.status=status;result.client_revalidated=false;result.confirmed_epoch={};
        result.elapsed_ms=status==m::Status::pending?100:1500;
        result.routing={128,UINT32_MAX,UINT32_MAX,UINT32_MAX,UINT32_MAX,true};
        const auto deadline=e.fake.motion_refresh.deadline_ms;
        ticks(host,e,1); running(host,name,e);
        check(e.logged("motion valid nonobserved shape") && e.fake.motion_refresh_starts==1 &&
            e.fake.motion_refresh.deadline_ms==deadline,e.all()); no_effects(e);
    }

    // 7. Corrupt only invariants in the pinned model; no body-epoch/mask rules.
    using Corrupt=void(*)(m::Result&);
    struct Fault { const char* name; Corrupt apply; };
    const Fault faults[] = {
        {"status",[](auto& r){r.status=static_cast<m::Status>(255);}},
        {"armed world",[](auto& r){r.armed_epoch.world_generation=0;}},
        {"armed lifetime",[](auto& r){r.armed_epoch.lifetime_epoch=0;}},
        {"armed serial",[](auto& r){r.armed_epoch.serial=0;}},
        {"armed time",[](auto& r){r.armed_epoch.time=-1;}},
        {"armed nonfinite",[](auto& r){r.armed_epoch.time=std::numeric_limits<double>::quiet_NaN();}},
        {"armed step",[](auto& r){r.armed_epoch.seconds=.01f;}},
        {"elapsed negative",[](auto& r){r.elapsed_ms=-1;}},
        {"elapsed nonfinite",[](auto& r){r.elapsed_ms=std::numeric_limits<double>::infinity();}},
        {"observed deadline",[](auto& r){r.elapsed_ms=1000;}},
        {"entry bound",[](auto& r){r.routing.entries=129;}},
        {"limit without entries",[](auto& r){r.routing.entries=0;r.routing.limit_reached=true;}},
        {"entries without limit",[](auto& r){r.routing.entries=128;r.routing.limit_reached=false;}},
        {"observed absent",[](auto& r){r.record={};}},
        {"observed not revalidated",[](auto& r){r.client_revalidated=false;}},
        {"changed forwarding",[](auto& r){r.record.unchanged_forwarding=false;}},
        {"input nonfinite",[](auto& r){r.record.input[3]=std::numeric_limits<float>::quiet_NaN();}},
        {"before world",[](auto& r){++r.record.before_epoch.world_generation;r.record.after_epoch=r.record.before_epoch;}},
        {"before lifetime",[](auto& r){++r.record.before_epoch.lifetime_epoch;r.record.after_epoch=r.record.before_epoch;}},
        {"before actor",[](auto& r){++r.record.before_epoch.actor_epoch;r.record.after_epoch=r.record.before_epoch;}},
        {"before serial",[](auto& r){r.record.before_epoch.serial=r.armed_epoch.serial;r.record.after_epoch=r.record.before_epoch;}},
        {"before time",[](auto& r){r.record.before_epoch.time=r.armed_epoch.time;r.record.after_epoch=r.record.before_epoch;}},
        {"before step",[](auto& r){r.record.before_epoch.seconds=.01f;r.record.after_epoch=r.record.before_epoch;}},
        {"after world",[](auto& r){++r.record.after_epoch.world_generation;}},
        {"after lifetime",[](auto& r){++r.record.after_epoch.lifetime_epoch;}},
        {"after actor",[](auto& r){++r.record.after_epoch.actor_epoch;}},
        {"after serial",[](auto& r){++r.record.after_epoch.serial;}},
        {"after time",[](auto& r){r.record.after_epoch.time+=.001;}},
        {"after step",[](auto& r){r.record.after_epoch.seconds=.01f;}},
        {"confirmed world",[](auto& r){++r.confirmed_epoch.world_generation;}},
        {"confirmed lifetime",[](auto& r){++r.confirmed_epoch.lifetime_epoch;}},
        {"confirmed actor",[](auto& r){++r.confirmed_epoch.actor_epoch;}},
        {"confirmed serial",[](auto& r){r.confirmed_epoch.serial=r.record.after_epoch.serial;}},
        {"confirmed time",[](auto& r){r.confirmed_epoch.time=r.record.after_epoch.time;}},
        {"confirmed step",[](auto& r){r.confirmed_epoch.seconds=.01f;}},
        {"nonobserved confirmation",[](auto& r){r.status=m::Status::expired;r.client_revalidated=false;}},
        {"nonobserved revalidated",[](auto& r){r.status=m::Status::invalidated;r.confirmed_epoch={};}},
        {"absent default",[](auto& r){r.status=m::Status::pending;r.client_revalidated=false;r.confirmed_epoch={};r.record={};r.record.input[0]=1;}},
    };
    const auto reject = [&](const char* why, Corrupt corrupt) {
        TestEnvironment e; Host host(e,Side::client); const auto name=id();
        host.apply({script(name,R"(
            local P=reskate.world.physics;local h=assert(P.begin_motion_refresh_probe())
            reskate.on('tick',function()
                local r,why=P.poll_motion_refresh_probe(h)
                assert(r==nil and type(why)=='string' and why:find('invalid observations'))
                reskate.log('motion malformed rejected')
            end)
        )",permissions)}); running(host,name,e);e.fake.complete_motion_refresh_probe();corrupt(e.fake.motion_refresh.result);
        ticks(host,e,1);running(host,name,e);
        check(e.logged("motion malformed rejected") && e.fake.motion_refresh_starts==1 && e.fake.motion_refresh_polls==1,
            std::string(why)+"\n"+e.all());no_effects(e);
    };
    for (const auto& fault : faults) reject(fault.name,fault.apply);
    for (unsigned field=0;field!=8;++field) {
        TestEnvironment e; Host host(e,Side::client);const auto name=id();
        host.apply({script(name,R"(
            local P=reskate.world.physics;local h=assert(P.begin_motion_refresh_probe())
            reskate.on('tick',function()local r,why=P.poll_motion_refresh_probe(h)
                assert(r==nil and why:find('invalid observations'));reskate.log('motion endpoint rejected')end)
        )",permissions)});running(host,name,e);e.fake.complete_motion_refresh_probe();
        auto& record=e.fake.motion_refresh.result.record;
        auto& endpoints=field<4?record.before:record.after;
        auto& value=field%4==0?endpoints.root[15]:field%4==1?endpoints.inverse[15]:
            field%4==2?endpoints.caches[2][15]:endpoints.packets[3][15];
        value=std::numeric_limits<float>::quiet_NaN();
        ticks(host,e,1);running(host,name,e);check(e.logged("motion endpoint rejected"),e.all());no_effects(e);
    }

    // 8. Owner close erases pending AND terminal results without any body.
    for (const bool terminal : {false,true}) {
        TestEnvironment e;Host host(e,Side::client);const auto name=id();
        const auto candidate=script(name,"assert(reskate.world.physics.begin_motion_refresh_probe())",permissions);
        host.apply({candidate});running(host,name,e);if(terminal)e.fake.complete_motion_refresh_probe();
        const auto old=e.fake.motion_refresh;m::Result out;
        check(!e.fake.poll_motion_refresh_probe(old.owner+1,old.sequence,out).empty() &&
            !e.fake.poll_motion_refresh_probe(old.owner,old.sequence+1,out).empty(),"foreign/stale collector identity was accepted");
        e.fake.cancel_motion_refresh_probe(0);e.fake.body_release_all(old.owner+1);
        check(e.fake.motion_refresh.owner==old.owner && e.fake.motion_refresh.sequence==old.sequence,"another owner's close canceled this probe");
        host.apply({});
        check(!e.fake.motion_refresh.sequence && e.fake.motion_refresh_cancels==1 &&
            !e.fake.poll_motion_refresh_probe(old.owner,old.sequence,out).empty(),"matching owner close retained pending/terminal actor authority");
        e.fake.body_release_all(old.owner);check(e.fake.motion_refresh_cancels==1,"repeated owner cancellation is not idempotent");
        host.apply({candidate});running(host,name,e);
        check(e.fake.motion_refresh.owner!=old.owner && e.fake.motion_refresh.sequence!=old.sequence &&
            !e.fake.poll_motion_refresh_probe(e.fake.motion_refresh.owner,old.sequence,out).empty(),"replacement VM inherited old actor probe");
        no_effects(e,false,true);
    }
    for (const bool terminal : {false,true}) {
        TestEnvironment e;Host host(e,Side::client);const auto name=id();const auto other=name+"-other";
        const auto first=script(name,"assert(reskate.world.physics.begin_motion_refresh_probe())",permissions);
        host.apply({first});running(host,name,e);const auto prior=e.fake.motion_refresh;
        if(terminal)e.fake.complete_motion_refresh_probe();
        const auto second=script(other,terminal?
            "assert(reskate.world.physics.begin_motion_refresh_probe())":R"(
                local h,why=reskate.world.physics.begin_motion_refresh_probe()
                assert(h==nil and why:find('occupied'))
            )",permissions);
        host.apply({first,second});running(host,name,e);running(host,other,e);
        check(e.fake.motion_refresh_starts==2,"independent VM budgets hid the collector's global occupancy rule");
        const auto retained=e.fake.motion_refresh;
        if(terminal) {
            m::Result stale;
            check(retained.owner!=prior.owner && retained.sequence!=prior.sequence &&
                !e.fake.poll_motion_refresh_probe(prior.owner,prior.sequence,stale).empty(),
                "new admission did not replace old terminal actor history");
            host.apply({second});
        } else {
            check(retained.owner==prior.owner && retained.sequence==prior.sequence,"pending actor request was replaced");
            host.apply({first});
        }
        check(e.fake.motion_refresh.owner==retained.owner && e.fake.motion_refresh.sequence==retained.sequence,
            "unrelated VM close erased another owner's actor observer");
        host.apply({});check(e.fake.motion_refresh_cancels==1 && !e.fake.motion_refresh.sequence,
            "current owner close failed after pending/refused or terminal/replacement admission");
        no_effects(e,false,true);
    }
    std::cout << "actor motion refresh: 8 Host groups, " << cases
        << " constructed cases; copied Game facts only, no native collector qualification\n";
}
}
