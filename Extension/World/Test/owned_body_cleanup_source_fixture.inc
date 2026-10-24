// Actual owned_bodies.cpp with constructed native arrays. No retail lifetime,
// force setter, park mutator or actor service executes in this source fixture.
struct ParkedCommandFixture {
    Fixture f;
    RetirementBasis basis;
    RetainedParkReceipt parked;
    std::uint64_t sequence=9007199254740994ULL;
    ParkedCommandFixture() {
        test_clock::now=10010;f.step();
        const auto source=f.source();
        auto requested=source.sample().epoch;--requested.serial;requested.time-=requested.seconds;
        auto& s=f.slot();s.mailbox={};Command command;command.epoch=requested;
        Command produced;
        check(s.mailbox.submit(command,requested,0,sequence) && s.mailbox.consume(source.sample().epoch,1,produced) &&
            s.mailbox.finish(true,true,true),"source cleanup command seed failed");
        check(capture_retirement_basis(owner,source,basis),"source cleanup basis capture failed");
        // Construct the already-completed native park leaf; actual observe checks
        // every array and later clock before issuing its private receipt below.
        s.mailbox.cancel();s.active=false;s.retained=true;s.quarantined=false;s.release_requested=true;s.parked_ms=10011;
        put(f.dynamics,std::uint32_t{0});put(f.categories+shape_index*4,std::uint32_t{0});put(f.collisions+shape_index*4,std::uint32_t{0});
        put(f.velocity+body_index*sizeof(V4),V4{});put(f.spin+body_index*sizeof(V4),V4{});
        const auto force=f.arena.take(capacity*sizeof(V4)),torque=f.arena.take(capacity*sizeof(V4));
        put(f.state+r::pending_force,force);put(f.state+r::pending_torque,torque);
        put(force+body_index*sizeof(V4),V4{});put(torque+body_index*sizeof(V4),V4{});
        test_clock::now=10020;service.tick_at=test_clock::now;f.step();
        check(observe_retained_park(owner,basis,parked),"actual retained park observation refused constructed arrays");
    }
};
void command_cleanup_uses_exact_immutable_history_without_native_reread() {
    ParkedCommandFixture p;const auto before=p.f.slot().mailbox.oldest();
    const auto worlds=test_facts::world_calls.load(),bodies=test_facts::body_calls.load(),shapes=test_facts::shape_calls.load();
    p.f.protect_position(PAGE_NOACCESS);
    check(seal_parked_command_cleanup(owner,p.basis,p.parked),"actual World cleanup seal refused exact retained park");
    Receipt out;check(receipt(owner,p.f.handle,p.sequence,out).empty() && out.outcome==Outcome::applied &&
        out.cleanup_disposition==CleanupDisposition::parked_without_successor && !out.successor_available && out.retained && !out.quarantined &&
        out.requested==before.requested && out.produced==before.produced,"actual receipt lost original result or cleanup disposition");
    check(acknowledge(owner,p.f.handle,p.sequence).empty() && !acknowledge(owner,p.f.handle,p.sequence).empty(),"actual exact World ACK was not once-only");
    check(test_facts::world_calls.load()==worlds && test_facts::body_calls.load()==bodies && test_facts::shape_calls.load()==shapes,
        "historical seal/receipt/ACK reread a native owner or body");
    p.f.protect_position(PAGE_READWRITE);
}
void command_cleanup_rejects_changed_identity_busy_hold_and_quarantine() {
    for(unsigned fault=0;fault<9;++fault) {
        ParkedCommandFixture p;auto& s=p.f.slot();
        if(fault==0)++service.world_generation;if(fault==1)++s.body.generation;if(fault==2)++s.shapes[0].generation;
        if(fault==3)s.quarantined=true;if(fault==4)s.release_hold=17;if(fault==5)s.release_requested=false;
        if(fault==6)s.mailbox.pending=true;if(fault==7)s.mailbox.producing=true;if(fault==8)s.active=true;
        check(!seal_parked_command_cleanup(owner,p.basis,p.parked) && s.mailbox.oldest().cleanup_disposition==CleanupDisposition::none,
            "actual World cleanup erased changed/unknown retained authority");
    }
    ParkedCommandFixture p;
    check(!seal_parked_command_cleanup(owner+1,p.basis,p.parked),"foreign plugin sealed retained force record");
    std::atomic<bool> locked{},resume{};
    std::thread holder([&]{AcquireSRWLockExclusive(&service.lock);locked=true;while(!resume.load())std::this_thread::yield();ReleaseSRWLockExclusive(&service.lock);});
    while(!locked.load())std::this_thread::yield();
    const bool accepted=seal_parked_command_cleanup(owner,p.basis,p.parked);resume=true;holder.join();
    check(!accepted && p.f.slot().mailbox.oldest().cleanup_disposition==CleanupDisposition::none,"busy World seal blocked or partially changed records");
    check(seal_parked_command_cleanup(owner,p.basis,p.parked),"later exact cleanup retry lost immutable proof");
}
