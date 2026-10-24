// Actual Host/API over a constructed Game mailbox. No native park is proved.
namespace {
void body_command_cleanup_host_fixture_v1() {
    for(const auto& permission:{std::string{},std::string{R"("world.physics.follow")"}}) {
        TestEnvironment e;Host host(e,Side::client);
        host.apply({script("command-cleanup-permission",R"(
            for _,method in {'receipt','acknowledge'} do
                local ok,why=pcall(reskate.world.physics[method],{},{})
                assert(not ok and why:find('world.physics',1,true),method)
            end
        )",permission)});running(host,"command-cleanup-permission",e);
        check(!e.fake.body_create_calls && !e.fake.body_submit_entries && e.fake.owned.empty(),"missing permission entered command backend");
    }
    TestEnvironment e;Host host(e,Side::client);
    const std::string code=R"(
        local P=reskate.world.physics;local v=vector.create
        local none_completed=false;local invalid_completed=0
        local b=assert(P.create({mass=12,inertia=v(2,3,4),position=v(0,0,0),rotation={0,0,0,1},
            capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
        reskate.console.command('cleanup-none','constructed missing cleanup marker',function()
            local r=assert(P.receipt(b,'9007199254740994'))
            assert(r.outcome=='applied' and r.cleanup_disposition=='none' and r.successor==nil)
            assert(not P.acknowledge(b,r.sequence))
            none_completed=true
        end)
        reskate.console.command('cleanup-invalid','constructed invalid cleanup marker',function()
            local r,why=P.receipt(b,'9007199254740994')
            assert(r==nil and why:find('cleanup disposition',1,true))
            invalid_completed+=1
        end)
        reskate.console.command('cleanup-receipt','constructed cleanup receipt',function()
            assert(none_completed and invalid_completed==5,'cleanup negative commands did not complete')
            local r=assert(P.receipt(b,'9007199254740994'))
            assert(r.outcome=='applied' and r.successor==nil and r.retained and not r.quarantined)
            assert(r.cleanup_disposition=='parked_without_successor')
            assert(r.requested_serial=='99' and r.produced_serial=='100')
            assert(P.acknowledge(b,r.sequence));assert(not P.acknowledge(b,r.sequence))
            reskate.log('parked command cleanup DTO acknowledged without successor')
        end)
    )";
    host.apply({script("command-cleanup-dto",code,R"("world.physics","console")")});running(host,"command-cleanup-dto",e);
    check(e.fake.owned.size()==1,"cleanup Host body seed missing");auto& b=e.fake.owned.begin()->second;
    b.mailbox={};auto requested=b.sample.epoch;--requested.serial;requested.time-=requested.seconds;
    owned_body::Command c;c.epoch=requested;owned_body::Command out;
    check(b.mailbox.submit(c,requested,0,9007199254740994ULL) && b.mailbox.consume(b.sample.epoch,1,out) &&
        b.mailbox.finish(true,true,true),"cleanup Host command seed failed");
    b.released=true;b.mailbox.cancel();auto later=b.sample.epoch;++later.serial;later.time+=later.seconds;
    check(host.run_console("cleanup-none"),"Host fabricated cleanup eligibility before SDK marker");
    check(b.mailbox.seal_parked_without_successor(b.sample.epoch,later),"constructed Host cleanup marker seed failed");
    const auto saved=b.mailbox.oldest();
    for(unsigned fault=0;fault<5;++fault){
        auto& row=b.mailbox.receipts[b.mailbox.head];row=saved;
        if(fault==0)row.cleanup_disposition=static_cast<owned_body::CleanupDisposition>(255);
        if(fault==1)row.outcome=owned_body::Outcome::partial;
        if(fault==2)row.successor_available=true;
        if(fault==3)row.force_attempted=false;
        if(fault==4)row.torque_attempted=false;
        check(host.run_console("cleanup-invalid"),"Host published malformed cleanup disposition");
    }
    b.mailbox.receipts[b.mailbox.head]=saved;
    const auto reads=e.fake.body_read_calls;
    check(host.run_console("cleanup-receipt") && e.logged("parked command cleanup DTO acknowledged without successor") &&
        e.fake.body_read_calls==reads && !e.fake.body_submit_entries && !e.fake.follow_reserves && !e.fake.native_recovery_requests,
        "cleanup DTO binding reread, dispatched native work or lost exact result\n"+e.all());
}
}
