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

// Constructed reader diagnostics only. No retail setter or park mutator runs.
using ParkCheck = ParkObservationCheck;
struct ParkSlotSnapshot {
    std::array<unsigned char, sizeof(Slot)> bytes{};
    explicit ParkSlotSnapshot(const Slot& slot) { std::memcpy(bytes.data(), &slot, bytes.size()); }
    bool same(const Slot& slot) const { return std::memcmp(bytes.data(), &slot, bytes.size()) == 0; }
};
struct ParkLeafCounts {
    unsigned worlds=test_facts::world_calls.load(), bodies=test_facts::body_calls.load(), shapes=test_facts::shape_calls.load();
    unsigned clocks=test_clock::reads.load();
    bool advanced(unsigned world_count,unsigned body_count,unsigned shape_count,unsigned clock_count) const {
        return test_facts::world_calls.load()-worlds==world_count && test_facts::body_calls.load()-bodies==body_count &&
            test_facts::shape_calls.load()-shapes==shape_count && test_clock::reads.load()-clocks==clock_count;
    }
};
struct ParkReadPage {
    void* memory=VirtualAlloc(nullptr,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    ParkReadPage() { check(memory!=nullptr,"park diagnostic page allocation failed"); }
    ~ParkReadPage() { if(memory)VirtualFree(memory,0,MEM_RELEASE); }
    ParkReadPage(const ParkReadPage&)=delete;
    std::uintptr_t address() const { return reinterpret_cast<std::uintptr_t>(memory); }
    void deny() { DWORD old{};check(VirtualProtect(memory,4096,PAGE_NOACCESS,&old)!=0,"park diagnostic page protection failed"); }
};
std::uintptr_t park_vector_address(ParkedCommandFixture& p,unsigned stream) {
    if(stream<2)return (stream?p.f.spin:p.f.velocity)+body_index*sizeof(V4);
    return load<std::uintptr_t>(p.f.state+(stream==2?r::pending_force:r::pending_torque))+body_index*sizeof(V4);
}
void park_vector_source(ParkedCommandFixture& p,unsigned stream,std::uintptr_t values) {
    if(stream<2) {
        const auto at=p.f.state+(stream?r::spin_ring:r::velocity_ring);
        auto header=load<Ring>(at);header.values=values;put(at,header);
    } else put(p.f.state+(stream==2?r::pending_force:r::pending_torque),values);
}
void park_refusal(ParkedCommandFixture& p,ParkCheck expected,std::uint8_t mask=0,bool known=false,
    bool opening_only=false,bool legacy_parity=true,std::uint64_t caller=owner,bool no_native=false) {
    const ParkSlotSnapshot authority(p.f.slot());
    RetainedParkReceipt out;
    std::array<unsigned char,sizeof(out)> before{};std::memcpy(before.data(),&out,before.size());
    ParkObservationDiagnostic diagnostic{ParkCheck::passed,15,true};
    ParkObservationDiagnostic expected_diagnostic{expected,mask,known};
    if(expected==ParkCheck::angular_zero && known) {
        const auto supplied=load<V4>(park_vector_address(p,1));
        expected_diagnostic.angular_fourth_available=true;
        expected_diagnostic.angular_fourth_value=supplied[3];
        expected_diagnostic.angular_fourth_bits=std::bit_cast<std::uint32_t>(supplied[3]);
    }
    const ParkLeafCounts leaves;
    SetLastError(0xD151);
    const bool accepted=observe_retained_park(caller,p.basis,out,diagnostic);
    check(GetLastError()==0xD151,"park refusal changed LastError");
    check(!accepted && !out.available() && std::memcmp(before.data(),&out,before.size())==0,
        "park refusal published or changed output proof");
    check(diagnostic==expected_diagnostic,"park diagnostic lost first predicate, exact lanes or existing-read fourth value");
    check(authority.same(p.f.slot()),"park diagnostic changed Slot authority, latest or mailbox");
    check(test_facts::mutations.load()==0,"park diagnostic invoked a native mutator");
    if(no_native)check(test_facts::world_calls.load()==leaves.worlds && test_facts::body_calls.load()==leaves.bodies &&
        test_facts::shape_calls.load()==leaves.shapes,"early park refusal performed a native validation");
    // A vector failure follows exactly the opening identity/clock, with no
    // closing validator reads. Counts are source-derived expectations, not evidence.
    if(opening_only)check(leaves.advanced(9,4,1,3),"vector refusal changed the opening short-circuit read footprint");
    if(legacy_parity) {
        RetainedParkReceipt legacy;
        SetLastError(0xD152);
        const bool old=observe_retained_park(caller,p.basis,legacy);
        check(GetLastError()==0xD152 && !old && !legacy.available(),"legacy park overload changed refusal or LastError");
        check(authority.same(p.f.slot()),"legacy park overload changed retained authority");
    }
}
void park_at_clock(unsigned relative,std::function<void()> change,bool& fired) {
    const auto target=test_clock::reads.load()+relative;
    test_clock::park_read_hook=[target,change=std::move(change),&fired](unsigned at) {
        if(at!=target)return;
        auto once=std::exchange(test_clock::park_read_hook,{});(void)once;
        fired=true;change();
    };
}
void park_at_shape(unsigned relative,std::function<void()> change,bool& fired) {
    const auto target=test_facts::shape_calls.load()+relative;
    test_facts::park_shape_hook=[target,change=std::move(change),&fired](unsigned at) {
        if(at!=target)return;
        auto once=std::exchange(test_facts::park_shape_hook,{});(void)once;
        fired=true;change();
    };
}
void park_diagnostic_valid_legacy_parity_and_signed_zero() {
    for(unsigned stream=0;stream<4;++stream) {
        ParkedCommandFixture p;put(park_vector_address(p,stream),V4{-0.f,0.f,-0.f,0.f});
        const ParkSlotSnapshot authority(p.f.slot());
        RetainedParkReceipt out,legacy;ParkObservationDiagnostic diagnostic{ParkCheck::force_zero,15,true};
        const ParkLeafCounts leaves;
        SetLastError(0xD153);
        check(observe_retained_park(owner,p.basis,out,diagnostic) && GetLastError()==0xD153,"valid park diagnostic refused or changed LastError");
        check(diagnostic==ParkObservationDiagnostic{ParkCheck::passed,0,false},"success retained stale failure/lane data");
        check(leaves.advanced(44,20,6,8),"successful observer added or removed native validation/clock reads");
        const ParkLeafCounts old_leaves;
        check(observe_retained_park(owner,p.basis,legacy) && old_leaves.advanced(44,20,6,8) && GetLastError()==0xD153,
            "legacy acceptance/read footprint or LastError differs");
        check(out.available() && out.observed_epoch()==legacy.observed_epoch() && out.observed_ms()==legacy.observed_ms() &&
            out.parked_ms()==legacy.parked_ms(),"diagnostic overload relabeled the legacy park receipt");
        check(authority.same(p.f.slot()),"successful diagnostic changed authority, latest or mailbox");
    }
}
void park_diagnostic_owner_busy_and_occupied_output() {
    { ParkedCommandFixture p;park_refusal(p,ParkCheck::owner,0,false,false,true,0,true); }
    { ParkedCommandFixture p;park_refusal(p,ParkCheck::owner,0,false,false,true,owner+1,true); }
    {
        ParkedCommandFixture p;const ParkSlotSnapshot authority(p.f.slot());const ParkLeafCounts leaves;
        const auto epoch=p.parked.observed_epoch();const auto stamp=p.parked.observed_ms(),parked=p.parked.parked_ms();
        std::array<unsigned char,sizeof(p.parked)> before{};std::memcpy(before.data(),&p.parked,before.size());
        ParkObservationDiagnostic diagnostic{ParkCheck::force_zero,8,true};
        SetLastError(0xD154);
        check(!observe_retained_park(0,p.basis,p.parked,diagnostic) && GetLastError()==0xD154,"occupied output was replaced");
        check(diagnostic==ParkObservationDiagnostic{ParkCheck::output_occupied,0,false} && p.parked.observed_epoch()==epoch &&
            p.parked.observed_ms()==stamp && p.parked.parked_ms()==parked && std::memcmp(before.data(),&p.parked,before.size())==0,
            "occupied output precedence/proof changed");
        check(!observe_retained_park(0,p.basis,p.parked) && GetLastError()==0xD154 &&
            std::memcmp(before.data(),&p.parked,before.size())==0,"legacy occupied output was not preserved");
        check(leaves.advanced(0,0,0,0) && authority.same(p.f.slot()),"occupied-output refusal touched native/Slot state");
    }
    {
        ParkedCommandFixture p;std::atomic<bool> locked{},release{};
        std::thread holder([&]{AcquireSRWLockExclusive(&service.lock);locked=true;while(!release.load())std::this_thread::yield();ReleaseSRWLockExclusive(&service.lock);});
        while(!locked.load())std::this_thread::yield();
        // Release/join before any check can throw; a blocking observer would
        // instead fail Root's unchanged bounded process timeout.
        RetainedParkReceipt out;ParkObservationDiagnostic diagnostic;const ParkSlotSnapshot authority(p.f.slot());
        std::array<unsigned char,sizeof(out)> before{};std::memcpy(before.data(),&out,before.size());
        const ParkLeafCounts leaves;SetLastError(0xD155);
        const bool accepted=observe_retained_park(owner,p.basis,out,diagnostic);const auto error=GetLastError();
        release=true;holder.join();
        check(!accepted && !out.available() && std::memcmp(before.data(),&out,before.size())==0 &&
            diagnostic==ParkObservationDiagnostic{ParkCheck::world_lock,0,false} && error==0xD155,
            "busy park observer blocked, published proof or mislabeled Try refusal");
        check(leaves.advanced(0,0,0,1) && authority.same(p.f.slot()),"busy refusal entered native validation or changed Slot");
        ParkObservationDiagnostic later;check(observe_retained_park(owner,p.basis,out,later) && later.check==ParkCheck::passed,
            "busy diagnostic attempt consumed later exact park observation");
    }
}
void park_diagnostic_identity_clock_and_dynamic_guards() {
    for(unsigned fault=0;fault<27;++fault) {
        ParkedCommandFixture p;auto& s=p.f.slot();ParkCheck expected=ParkCheck::retained_identity;
        switch(fault) {
        case 0:++s.owner;break;
        case 1:++s.handle.generation;break;
        case 2:++service.world_generation;break;
        case 3:++s.body.generation;break;
        case 4:s.anchor.world+=64;break;
        case 5:s.anchor.state+=64;break;
        case 6:s.active=true;break;
        case 7:s.retained=false;break;
        case 8:s.quarantined=true;break;
        case 9:s.parked_ms=0;break;
        case 10:s.parked_ms=p.basis.captured_ms()-1;break;
        case 11:s.made=0;break;
        case 12:put(p.f.body_generations+body_index*4,body_generation+1);expected=ParkCheck::fresh_allocation;break;
        case 13:put(p.f.context+test_world_field,p.f.world+64);expected=ParkCheck::fresh_allocation;break;
        case 14:put(load<std::uintptr_t>(p.f.state+r::shape_generations)+shape_index,std::uint8_t{shape_generation+1});expected=ParkCheck::fresh_allocation;break;
        case 15:++s.shapes[0].generation;put(load<std::uintptr_t>(p.f.state+r::shape_generations)+shape_index,std::uint8_t{shape_generation+1});expected=ParkCheck::shape_identity;break;
        case 16:clock_feed.serial=p.basis.epoch().serial;clock_feed.sequence=clock_feed.serial;expected=ParkCheck::clock_serial;break;
        case 17:clock_feed.time=p.basis.epoch().time;expected=ParkCheck::clock_time;break;
        case 18:clock_feed.observed=p.basis.captured_ms();expected=ParkCheck::clock_after_fence;break;
        case 19:clock_feed.observed=s.parked_ms;expected=ParkCheck::clock_after_park;break;
        case 20:clock_feed.serial=0;clock_feed.sequence=0;expected=ParkCheck::clock_unavailable;break;
        case 21:clock_feed.observed=test_clock::now-250;expected=ParkCheck::clock_unavailable;break;
        case 22:put(p.f.dynamics,1U<<body_index);expected=ParkCheck::dynamic_bit;break;
        case 23:test_clock::now=service.tick_at+250;expected=ParkCheck::client_phase;break;
        case 24:put(load<std::uintptr_t>(p.f.state+r::shape_owners)+shape_index*4,std::uint32_t{3});expected=ParkCheck::fresh_allocation;break;
        case 25:put(p.f.categories+shape_index*4,std::uint32_t{1});expected=ParkCheck::fresh_allocation;break;
        case 26:put(p.f.allocations,std::uint32_t{});expected=ParkCheck::fresh_allocation;break;
        }
        park_refusal(p,expected);
    }
}
void park_diagnostic_finite_lane_masks_and_first_failure() {
    const std::array<ParkCheck,4> expected_checks{ParkCheck::linear_zero,ParkCheck::angular_zero,ParkCheck::force_zero,ParkCheck::torque_zero};
    for(unsigned stream=0;stream<4;++stream)for(const auto mask:std::array<std::uint8_t,5>{1,2,4,8,11}) {
        // A finite W-only angular row now reaches the remaining predicates;
        // the separate acceptance group below exercises that complete path.
        if(stream==1 && mask==8)continue;
        ParkedCommandFixture p;V4 value{};
        for(unsigned lane=0;lane<4;++lane)if(mask&(1U<<lane))value[lane]=(lane&1U)?-.5f:.5f;
        put(park_vector_address(p,stream),value);
        const auto compared_mask=static_cast<std::uint8_t>(stream==1?mask&7U:mask);
        park_refusal(p,expected_checks[stream],compared_mask,true,true);
    }
    ParkedCommandFixture p;put(park_vector_address(p,0),V4{1,0,0,0});
    put(park_vector_address(p,1),V4{std::bit_cast<float>(0x7FC00000U),0,0,0});
    park_refusal(p,ParkCheck::linear_zero,1,true,true);
}
void park_diagnostic_angular_fourth_exact_existing_read() {
    for(const auto bits:std::array<std::uint32_t,5>{0x3F800001U,0xBF000000U,0x00800001U,0x00000000U,0x80000000U}) {
        ParkedCommandFixture p;const float supplied=std::bit_cast<float>(bits);
        // Nonzero X makes a failed angular comparison even when W is +/-zero.
        put(park_vector_address(p,1),V4{.25f,0,0,supplied});
        put(park_vector_address(p,2),V4{0,0,0,17.f});put(park_vector_address(p,3),V4{0,0,0,19.f});
        const ParkSlotSnapshot authority(p.f.slot());const ParkLeafCounts leaves;
        RetainedParkReceipt out;ParkObservationDiagnostic diagnostic;SetLastError(0xD161);
        check(!observe_retained_park(owner,p.basis,out,diagnostic) && !out.available() && GetLastError()==0xD161,
            "angular fourth diagnostic changed refusal/proof/LastError");
        check(diagnostic.check==ParkCheck::angular_zero && diagnostic.lanes_known && diagnostic.failed_lanes==1 &&
            diagnostic.angular_fourth_available && diagnostic.angular_fourth_value==supplied && diagnostic.angular_fourth_bits==bits,
            "angular fourth value/bits did not come from the failed qualified spin read");
        check(leaves.advanced(9,4,1,3) && authority.same(p.f.slot()) && test_facts::mutations.load()==0,
            "fourth diagnostic added validator reads or changed native/SDK authority");
        auto different=diagnostic;different.angular_fourth_bits^=1;
        check(!(different==diagnostic),"coalescing equality hid a changed exact fourth-lane bit pattern");
        different=diagnostic;different.angular_fourth_available=false;
        check(!(different==diagnostic),"coalescing equality hid fourth-lane availability change");
    }
    {
        ParkedCommandFixture p;auto header=load<Ring>(p.f.state+r::spin_ring);
        const auto stride=(std::uintptr_t{header.elements}*sizeof(V4)+63U)&~std::uintptr_t{63U};
        const auto planes=p.f.arena.take(stride*2);header.values=planes;header.current=1;header.planes=2;
        put(planes+body_index*sizeof(V4),V4{0,0,0,.75f});
        put(planes+stride+body_index*sizeof(V4),V4{.25f,0,0,-.5f});
        put(p.f.state+r::spin_ring,header);
        RetainedParkReceipt out;ParkObservationDiagnostic diagnostic;
        check(!observe_retained_park(owner,p.basis,out,diagnostic) && diagnostic.check==ParkCheck::angular_zero &&
            diagnostic.failed_lanes==1 && diagnostic.angular_fourth_available && diagnostic.angular_fourth_value==-.5f &&
            diagnostic.angular_fourth_bits==0xBF000000U,"fourth diagnostic read a stale rather than selected current plane");
    }
}
void park_diagnostic_angular_fourth_unavailable_resets() {
    for(unsigned fault=0;fault<4;++fault) {
        ParkedCommandFixture p;ParkObservationDiagnostic diagnostic{ParkCheck::angular_zero,8,true};
        diagnostic.angular_fourth_available=true;diagnostic.angular_fourth_value=42.f;diagnostic.angular_fourth_bits=0x42280000U;
        if(fault==0)put(park_vector_address(p,1),V4{0,0,0,std::bit_cast<float>(0x7FC00000U)});
        if(fault==1)put(park_vector_address(p,1),V4{0,0,0,std::bit_cast<float>(0x7F800000U)});
        if(fault==2)put(park_vector_address(p,0),V4{1,0,0,0});
        RetainedParkReceipt out;const auto expected=fault<2?ParkCheck::angular_read:fault==2?ParkCheck::linear_zero:ParkCheck::passed;
        const bool accepted=observe_retained_park(owner,p.basis,out,diagnostic);
        check(accepted==(fault==3) && diagnostic.check==expected && !diagnostic.angular_fourth_available &&
            diagnostic.angular_fourth_value==0.f && diagnostic.angular_fourth_bits==0,
            "invalid read/earlier predicate/success retained a stale angular fourth observation");
    }
}
void park_diagnostic_failed_reads_leave_lanes_unknown() {
    const std::array<ParkCheck,4> expected_checks{ParkCheck::linear_read,ParkCheck::angular_read,ParkCheck::force_read,ParkCheck::torque_read};
    for(unsigned stream=0;stream<4;++stream)for(unsigned fault=0;fault<5;++fault) {
        ParkedCommandFixture p;ParkReadPage page;
        if(fault==0){park_vector_source(p,stream,page.address());page.deny();}
        else {
            const float value=fault==1?std::bit_cast<float>(0x7FC00000U):fault==2?std::bit_cast<float>(0x7F800000U):
                fault==3?std::bit_cast<float>(0xFF800000U):1000001.f;
            // Invalid fourth lanes are failed qualified reads, not known mask8.
            put(park_vector_address(p,stream),V4{0,0,0,value});
        }
        park_refusal(p,expected_checks[stream],0,false,true);
    }
    ParkedCommandFixture p;put(park_vector_address(p,0),V4{std::bit_cast<float>(0x7FC00000U),0,0,0});
    put(park_vector_address(p,1),V4{1,0,0,0});park_refusal(p,ParkCheck::linear_read,0,false,true);
}
void park_diagnostic_opening_storage_and_mask_edges() {
    const std::array<ParkCheck,8> expected_checks{ParkCheck::category_storage,ParkCheck::collision_storage,ParkCheck::dynamic_storage,
        ParkCheck::dynamic_bit,ParkCheck::shape_category_zero,ParkCheck::shape_collision_zero,ParkCheck::shape_category_read,ParkCheck::shape_collision_read};
    for(unsigned fault=0;fault<expected_checks.size();++fault) {
        ParkedCommandFixture p;ParkReadPage page;bool fired=false;
        if(fault>=6)page.deny();
        // Opening clock is after the actual fresh-allocation predicate. The
        // same mutations before fresh correctly refuse as fresh_allocation.
        park_at_clock(3,[&]{
            if(fault==0)put(p.f.state+r::shape_categories,std::uintptr_t{});
            if(fault==1)put(p.f.state+r::shape_collides,std::uintptr_t{});
            if(fault==2)put(p.f.state+r::dynamic_bits,std::uintptr_t{});
            if(fault==3)put(p.f.dynamics,1U<<body_index);
            if(fault==4)put(p.f.categories+shape_index*4,std::uint32_t{1});
            if(fault==5)put(p.f.collisions+shape_index*4,r::safe_world_collisions);
            if(fault==6)put(p.f.state+r::shape_categories,page.address());
            if(fault==7)put(p.f.state+r::shape_collides,page.address());
        },fired);
        park_refusal(p,expected_checks[fault],0,false,true,false);
        check(fired,"opening post-fresh synthetic mutation did not execute");
    }
}
void park_diagnostic_both_closing_passes_keep_fences() {
    const std::array<ParkCheck,11> expected_checks{ParkCheck::linear_header,ParkCheck::angular_header,ParkCheck::linear_values,
        ParkCheck::angular_values,ParkCheck::force_storage,ParkCheck::torque_storage,ParkCheck::force_values,
        ParkCheck::torque_values,ParkCheck::categories_unchanged,ParkCheck::collisions_unchanged,ParkCheck::dynamic_unchanged};
    for(unsigned pass=0;pass<2;++pass)for(unsigned fault=0;fault<expected_checks.size();++fault) {
        ParkedCommandFixture p;bool fired=false;
        const auto replacement=p.f.arena.take(capacity*sizeof(V4));put(replacement+body_index*sizeof(V4),V4{});
        park_at_shape(pass?4:2,[&]{
            if(fault<2){const auto at=p.f.state+(fault?r::spin_ring:r::velocity_ring);auto h=load<Ring>(at);--h.elements;put(at,h);}
            if(fault==2 || fault==3)put(park_vector_address(p,fault-2),V4{0,0,0,.25f});
            if(fault==4 || fault==5)park_vector_source(p,fault-2,replacement);
            if(fault==6 || fault==7)put(park_vector_address(p,fault-4),V4{.25f,0,-.25f,0});
            if(fault==8)put(p.f.state+r::shape_categories,replacement);
            if(fault==9)put(p.f.state+r::shape_collides,replacement);
            if(fault==10)put(p.f.dynamics,1U<<body_index);
        },fired);
        const bool values=fault==2 || fault==3 || fault==6 || fault==7;
        const std::uint8_t mask=fault==2 || fault==3?8:values?5:0;
        park_refusal(p,expected_checks[fault],mask,values,false,false);
        check(fired,"closing-pass mutation did not reach the actual native validator");
    }
}
void park_diagnostic_closing_identity_clock_and_final_age() {
    const std::array<ParkCheck,8> expected_checks{ParkCheck::shape_current,ParkCheck::shape_current,ParkCheck::shape_current,
        ParkCheck::closing_epoch,ParkCheck::closing_stamp,ParkCheck::closing_clock,ParkCheck::fresh_allocation,ParkCheck::clock_freshness};
    for(unsigned fault=0;fault<expected_checks.size();++fault) {
        ParkedCommandFixture p;bool fired=false;
        const auto change=[&]{
            if(fault==0)put(p.f.body_generations+body_index*4,body_generation+1);
            if(fault==1)put(load<std::uintptr_t>(p.f.state+r::shape_generations)+shape_index,std::uint8_t{shape_generation+1});
            if(fault==2)put(p.f.context+test_world_field,p.f.world+64);
            if(fault==3){++test_clock::now;p.f.step();}
            if(fault==4)--clock_feed.observed;
            if(fault==5){clock_feed.serial=0;clock_feed.sequence=0;}
            if(fault==6)put(p.f.entity+r::entity_teleport,std::uint8_t{1});
            if(fault==7)test_clock::now=clock_feed.observed+command_lifetime_ms;
        };
        if(fault==6)park_at_clock(6,change,fired);
        else if(fault==7)park_at_clock(8,change,fired);
        else park_at_shape(2,change,fired);
        park_refusal(p,expected_checks[fault],0,false,false,false);
        check(fired,"closing identity/clock synthetic interleaving did not execute");
    }
}

// Regression sources for the angular-only domain correction. These call the
// actual observer; native arrays/clock and external ABI leaves are constructed.
// No retail setter, park mutator, ACK or SDK retirement runs in these cases.
void park_angular_xyz_zero_accepts_only_complete_observation() {
    for(const auto bits:std::array<std::uint32_t,6>{0x3F800000U,0xBF000000U,0x00800001U,0x3F800001U,0x49742400U,0xC9742400U}) {
        ParkedCommandFixture p;const float fourth=std::bit_cast<float>(bits);
        put(park_vector_address(p,1),V4{0,-0.f,0,fourth});
        const ParkSlotSnapshot authority(p.f.slot());const ParkLeafCounts leaves;
        RetainedParkReceipt out;ParkObservationDiagnostic diagnostic{ParkCheck::angular_zero,8,true};
        diagnostic.angular_fourth_available=true;diagnostic.angular_fourth_value=17.f;diagnostic.angular_fourth_bits=0x41880000U;
        SetLastError(0xD170);
        check(observe_retained_park(owner,p.basis,out,diagnostic) && out.available() && GetLastError()==0xD170,
            "finite W-only angular row did not pass the actual complete retained observer");
        check(diagnostic==ParkObservationDiagnostic{ParkCheck::passed,0,false},"angular XYZ success retained stale diagnostic data");
        check(leaves.advanced(44,20,6,8) && authority.same(p.f.slot()) && test_facts::mutations.load()==0,
            "angular XYZ success skipped validators, changed authority or invoked a native mutation");
        check(out.observed_epoch()==p.parked.observed_epoch() && out.observed_ms()==p.parked.observed_ms() &&
            out.parked_ms()==p.parked.parked_ms(),"angular XYZ success changed the qualified receipt identity");
        RetainedParkReceipt legacy;const ParkLeafCounts old_leaves;
        check(observe_retained_park(owner,p.basis,legacy) && old_leaves.advanced(44,20,6,8) &&
            GetLastError()==0xD170 && legacy.observed_epoch()==out.observed_epoch() && authority.same(p.f.slot()),
            "legacy overload did not share the complete angular XYZ observer");
    }
}
void park_angular_xyz_nonzero_and_invalid_fourth_refuse() {
    for(unsigned lane=0;lane<3;++lane)for(const float sign:std::array<float,2>{-1.f,1.f}) {
        ParkedCommandFixture p;V4 angular{0,0,0,.75f};angular[lane]=sign*.25f;
        put(park_vector_address(p,1),angular);
        park_refusal(p,ParkCheck::angular_zero,static_cast<std::uint8_t>(1U<<lane),true,true);
    }
    for(const auto bits:std::array<std::uint32_t,5>{0x7FC00000U,0x7F800000U,0xFF800000U,0x49742410U,0xC9742410U}) {
        ParkedCommandFixture p;put(park_vector_address(p,1),V4{0,0,0,std::bit_cast<float>(bits)});
        park_refusal(p,ParkCheck::angular_read,0,false,true);
    }
    ParkedCommandFixture p;put(park_vector_address(p,1),V4{0,0,0,.75f});
    put(park_vector_address(p,0),V4{0,0,0,.5f});
    park_refusal(p,ParkCheck::linear_zero,8,true,true);
}
void park_angular_xyz_zero_keeps_fourth_stability_and_headers() {
    for(unsigned pass=0;pass<2;++pass)for(unsigned fault=0;fault<4;++fault) {
        ParkedCommandFixture p;put(park_vector_address(p,1),V4{0,0,0,.5f});bool fired=false;
        park_at_shape(pass?4:2,[&]{
            if(fault==0)put(park_vector_address(p,1),V4{0,0,0,.75f});
            if(fault==1)put(park_vector_address(p,1),V4{0,0,0,std::bit_cast<float>(0x7FC00000U)});
            if(fault==2)put(park_vector_address(p,1),V4{0,0,0,std::bit_cast<float>(0x7F800000U)});
            if(fault==3){auto header=load<Ring>(p.f.state+r::spin_ring);--header.elements;put(p.f.state+r::spin_ring,header);}
        },fired);
        const auto expected=fault==0?ParkCheck::angular_values:fault==3?ParkCheck::angular_header:ParkCheck::angular_read;
        park_refusal(p,expected,static_cast<std::uint8_t>(fault==0?8:0),fault==0,false,false);
        check(fired,"finite W-only regression did not reach the selected closing readback");
    }
}
void park_angular_xyz_zero_keeps_later_pending_commands() {
    for(unsigned stream=2;stream<4;++stream)for(unsigned lane=0;lane<4;++lane) {
        ParkedCommandFixture p;put(park_vector_address(p,1),V4{0,0,0,-.5f});V4 pending{};pending[lane]=.25f;
        put(park_vector_address(p,stream),pending);
        park_refusal(p,stream==2?ParkCheck::force_zero:ParkCheck::torque_zero,static_cast<std::uint8_t>(1U<<lane),true,true);
    }
}
void park_angular_xyz_zero_keeps_closing_identity_clock_and_age() {
    const std::array<ParkCheck,8> expected_checks{ParkCheck::shape_current,ParkCheck::shape_current,ParkCheck::shape_current,
        ParkCheck::closing_epoch,ParkCheck::closing_stamp,ParkCheck::closing_clock,ParkCheck::fresh_allocation,ParkCheck::clock_freshness};
    for(unsigned fault=0;fault<expected_checks.size();++fault) {
        ParkedCommandFixture p;put(park_vector_address(p,1),V4{0,0,0,.5f});bool fired=false;
        const auto change=[&]{
            if(fault==0)put(p.f.body_generations+body_index*4,body_generation+1);
            if(fault==1)put(load<std::uintptr_t>(p.f.state+r::shape_generations)+shape_index,std::uint8_t{shape_generation+1});
            if(fault==2)put(p.f.context+test_world_field,p.f.world+64);
            if(fault==3){++test_clock::now;p.f.step();}
            if(fault==4)--clock_feed.observed;
            if(fault==5){clock_feed.serial=0;clock_feed.sequence=0;}
            if(fault==6)put(p.f.entity+r::entity_teleport,std::uint8_t{1});
            if(fault==7)test_clock::now=clock_feed.observed+command_lifetime_ms;
        };
        if(fault==6)park_at_clock(6,change,fired);
        else if(fault==7)park_at_clock(8,change,fired);
        else park_at_shape(2,change,fired);
        park_refusal(p,expected_checks[fault],0,false,false,false);
        check(fired,"finite W-only regression did not reach the selected closing fence");
    }
}
