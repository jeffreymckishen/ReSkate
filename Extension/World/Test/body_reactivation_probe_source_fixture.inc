// Actual World provider with constructed native storage and separately counted
// ABI leaves. No retail setter, allocator, actor or Follow implementation runs.
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
namespace br = body_reactivation_probe;
void reset_reactivation_source_fixture() {
    // A new constructed process per case, with no callbacks/threads in flight.
    reactivation_probe={};reactivation_live_owner.store(0);reactivation_close_requested.store(false);
    test_facts::reactivation_image_allowed=false;test_facts::reactivation_image_queries=0;
    test_facts::reactivation_allocations=0;test_facts::reactivation_capsules=0;
}
enum class ReactivationCall { categories, collisions, clear_force, clear_torque, linear, angular, park_motion, transform, dynamic_motion, wake };
struct ReactivationFixture : Fixture {
    inline static ReactivationFixture* current{};
    std::vector<ReactivationCall> calls;
    std::function<void(ReactivationCall)> interleave;
    std::function<void(unsigned)> qualification_interleave;
    unsigned fail_at{}, silent_at{};
    bool fail_after_write{}, qualified=true;
    unsigned qualification_calls{};
    std::uint64_t sequence{};
    MeasuredSource original_source;
    RetirementBasis original_basis;
    ReactivationFixture() {
        current=this;calls.reserve(128);test_facts::forbidden_links=0;
        auto& s=slot();s.mailbox={};s.never_held=true;
        s.allocation.body_confirmed=true;s.allocation.shapes_attempted=s.allocation.shapes_confirmed=s.made;
        s.definition.position={3,4,5};s.definition.rotation={0,0,0,1};
        const auto force=arena.take(capacity*sizeof(V4)),torque=arena.take(capacity*sizeof(V4));
        put(state+r::pending_force,force);put(state+r::pending_torque,torque);
        const auto shape_bodies=arena.take(capacity*sizeof(std::uint32_t));
        put(state+r::shape_body_indices,shape_bodies);put(shape_bodies+shape_index*4,body_index);
        service.initialization_requested=false;service.hook_attempted=true;service.original=original_leaf;
        service.probe={};service.probe_live=0;
        service.api.categories=categories_leaf;service.api.collides=collisions_leaf;
        service.api.clear_force=force_leaf;service.api.clear_torque=torque_leaf;
        service.api.linear=linear_leaf;service.api.angular=angular_leaf;
        service.api.motion=motion_leaf;service.api.transform=transform_leaf;service.api.wake=wake_leaf;
        // These are source-owned prefix bytes in non-executable pages. The
        // actual provider still reads/compares each required native fingerprint.
        for(const auto* fp:{&c::physics_world,&c::allocate_body,&c::create_capsule,&c::set_motion_type,
            &c::set_body_980,&c::clear_body_aa0,&c::set_categories,&c::set_collides_with,&c::set_shape_owner,
            &c::set_center_of_mass,&c::set_transform,&c::set_linear_velocity,&c::set_angular_velocity,
            &c::wake_body,&c::body_valid,&c::shape_valid,&r::linear_force,&r::angular_torque,&r::body_reset,
            &r::body_quaternion,&r::set_inertia_ratio,&r::overwrite_force,&r::overwrite_torque,&r::synchronizer}) pin(*fp);
        test_facts::reactivation_image_allowed=true;
        original_source=source();
        check(capture_retirement_basis(owner,original_source,original_basis),"reactivation fixture could not capture active retirement basis");
    }
    ~ReactivationFixture() { current=nullptr;test_facts::reactivation_image_allowed=false; }
    void pin(const game::build::Fingerprint& fp) {
        const auto page=(base+fp.rva)&~std::uintptr_t{4095};
        check(VirtualAlloc(reinterpret_cast<void*>(page),4096,MEM_COMMIT,PAGE_READWRITE)!=nullptr,"reactivation fingerprint page unavailable");
        std::memcpy(reinterpret_cast<void*>(base+fp.rva),fp.bytes.data(),fp.bytes.size());
    }
    static std::uintptr_t original_leaf(NativeHandle*,std::uintptr_t) { ++test_facts::forbidden_links;return 0; }
    static bool qualification(std::uint64_t selected) noexcept {
        if(!current)return false;
        ++current->qualification_calls;const auto hook=current->qualification_interleave;if(hook)hook(current->qualification_calls);
        return current->qualified && selected==owner;
    }
    static bool before(ReactivationCall call) {
        current->calls.push_back(call);
        if(current->fail_at==current->calls.size() && !current->fail_after_write)RaiseException(0xE0520101,0,0,nullptr);
        return current->silent_at!=current->calls.size();
    }
    static void after(ReactivationCall call) {
        const auto hook=current->interleave;if(hook)hook(call);
        if(current->fail_at==current->calls.size() && current->fail_after_write)RaiseException(0xE0520102,0,0,nullptr);
    }
    static void categories_leaf(NativeHandle* h,const std::uint32_t* value) {
        if(before(ReactivationCall::categories))put(current->categories+std::uintptr_t{h->index}*4,*value);
        after(ReactivationCall::categories);
    }
    static void collisions_leaf(NativeHandle* h,const std::uint32_t* value) {
        if(before(ReactivationCall::collisions))put(current->collisions+std::uintptr_t{h->index}*4,*value);
        after(ReactivationCall::collisions);
    }
    static void vector_leaf(NativeHandle* h,const float* value,ReactivationCall call,std::uintptr_t storage) {
        if(before(call)){V4 data{};std::memcpy(data.data(),value,sizeof(data));put(storage+std::uintptr_t{h->index}*sizeof(V4),data);}
        after(call);
    }
    static void force_leaf(NativeHandle* h,const float* value) {
        vector_leaf(h,value,ReactivationCall::clear_force,load<std::uintptr_t>(current->state+r::pending_force));
    }
    static void torque_leaf(NativeHandle* h,const float* value) {
        vector_leaf(h,value,ReactivationCall::clear_torque,load<std::uintptr_t>(current->state+r::pending_torque));
    }
    static void linear_leaf(NativeHandle* h,const float* value) { vector_leaf(h,value,ReactivationCall::linear,current->velocity); }
    static void angular_leaf(NativeHandle* h,const float* value) {
        // Retail angular zero semantics preserve the observed fourth lane.
        V4 data{};std::memcpy(data.data(),value,sizeof(data));data[3]=load<V4>(current->spin+std::uintptr_t{h->index}*sizeof(V4))[3];
        vector_leaf(h,data.data(),ReactivationCall::angular,current->spin);
    }
    static void motion_leaf(NativeHandle* h,int mode) {
        const auto call=mode==3?ReactivationCall::dynamic_motion:ReactivationCall::park_motion;
        if(before(call)) {
            auto bits=load<std::uint32_t>(current->dynamics);
            if(mode==3)bits|=1U<<h->index;else if(mode==2)bits&=~(1U<<h->index);else RaiseException(0xE0520103,0,0,nullptr);
            put(current->dynamics,bits);
        }
        after(call);
    }
    static void transform_leaf(NativeHandle* h,const float* value) {
        if(before(ReactivationCall::transform)) {
            put(current->position+std::uintptr_t{h->index}*sizeof(V4),V4{value[4],value[5],value[6],value[7]});
            put(current->rotation+std::uintptr_t{h->index}*sizeof(V4),V4{value[3],value[0],value[1],value[2]});
        }
        after(ReactivationCall::transform);
    }
    static void wake_leaf(NativeHandle*) { (void)before(ReactivationCall::wake);after(ReactivationCall::wake); }
    std::string begin(std::uint64_t selected=owner) {
        return begin_body_reactivation_probe(selected,handle,sequence,&qualification);
    }
    br::Result poll() {
        br::Result out;
        check(poll_body_reactivation_probe(owner,handle,sequence,out).empty(),"reactivation exact copied poll failed");
        return out;
    }
    void later(bool ready=true) { test_clock::now+=10;step();tick(base,client,ready); }
    bool native_dynamic() { return (load<std::uint32_t>(dynamics)&(1U<<body_index))!=0; }
    void no_extra_authority() {
        auto& s=slot();Sample out;MeasuredSource source_out;BodyReleaseHold hold;Command command;command.epoch=original_source.sample().epoch;
        std::uint64_t command_sequence{};const auto before=calls.size();
        check(!read(owner,handle,out).empty() && !capture_source(owner,handle,source_out) &&
            !submit(owner,handle,command,command_sequence).empty() && !command_sequence &&
            !acquire_release_hold(owner,original_source,hold) && !hold.available(),"retained probe body regained ordinary command or Follow-source authority");
        auto incoming=s.body;produce(&incoming,s.anchor.wrappers[0]);
        check(calls.size()==before && !s.release_hold && !s.mailbox.count && !s.mailbox.pending && !s.mailbox.producing &&
            test_facts::reactivation_allocations==0 && test_facts::reactivation_capsules==0 && test_facts::mutations==0 && test_facts::forbidden_links==0,
            "probe invoked a normal producer, allocator, capsule, actor or hook dependency");
    }
};
void reactivation_until(ReactivationFixture& f,br::Phase phase) {
    for(unsigned step=0;step<16;++step) {
        const auto out=f.poll();if(out.phase==phase)return;
        check(out.phase!=br::Phase::terminal,"reactivation ended before the requested observation phase");f.later();
    }
    check(false,"reactivation did not reach the requested phase within bounded synthetic steps");
}
br::Result reactivation_finish(ReactivationFixture& f) {
    for(unsigned step=0;step<16;++step) {
        const auto out=f.poll();if(out.phase==br::Phase::terminal)return out;f.later();
    }
    test_clock::now=reactivation_probe.cleanup_deadline;tick(f.base,f.client,false);
    const auto out=f.poll();check(out.phase==br::Phase::terminal,"reactivation cleanup deadline did not terminate metadata");return out;
}
void reactivation_begin_retires_without_a_follow_hold() {
    ReactivationFixture f;auto& s=f.slot();const auto handle=s.handle;const auto body=s.body;const auto shapes=s.shapes;
    check(s.active && !s.retained && !s.release_hold && !s.release_requested && s.never_held,"probe fixture did not start with ordinary never-held authority");
    SetLastError(0xBA01);
    check(f.begin().empty() && f.sequence && GetLastError()==0xBA01,"qualified no-hold begin failed or changed LastError");
    check(s.retained && !s.active && !s.quarantined && s.mailbox.failed && !s.release_requested && !s.release_hold &&
        s.handle==handle && s.body==body && s.shapes==shapes && s.parked_ms && !f.native_dynamic(),
        "begin returned before actual no-hold retirement/park or fabricated Follow release history");
    const std::vector<ReactivationCall> initial{ReactivationCall::categories,ReactivationCall::collisions,ReactivationCall::clear_force,
        ReactivationCall::clear_torque,ReactivationCall::linear,ReactivationCall::angular,ReactivationCall::park_motion};
    check(f.calls==initial,"initial retirement did not execute the actual qualified park setter order");
    const auto out=f.poll();check(out.status==br::Status::pending && out.phase==br::Phase::await_initial_park && out.cleanup_owed &&
        !out.native_retirement_known && out.target_position==s.definition.position && out.target_rotation==s.definition.rotation,
        "initial opaque diagnostic lost its immutable target or cleanup duty");
    const auto calls=f.calls.size();const auto checks=f.qualification_calls;const auto first=f.poll();const auto second=f.poll();
    check(first.phase==second.phase && first.record_count==second.record_count && first.elapsed_ms==second.elapsed_ms &&
        f.calls.size()==calls && f.qualification_calls==checks,"poll advanced or renewed the diagnostic");
    f.no_extra_authority();
}
void reactivation_one_cycle_explicitly_reparks_retained_identity() {
    ReactivationFixture f;auto& s=f.slot();const auto body=s.body;const auto shapes=s.shapes;const auto handle=s.handle;
    const auto allocation=s.allocation;check(f.begin().empty() && f.sequence,"one-cycle admission failed");
    const auto parked_ms=s.parked_ms;RetainedParkReceipt original_park;
    test_clock::now+=10;f.step();service.tick_at=test_clock::now;
    check(observe_retained_park(owner,f.original_basis,original_park),"initial later opaque park history unavailable");
    tick(f.base,f.client,true);reactivation_until(f,br::Phase::await_dynamic);
    check(f.native_dynamic() && s.retained && !s.active && s.mailbox.failed,"private activation reopened SDK authority or failed to activate native body");
    const auto writes=f.calls.size();check(release(owner,f.handle).empty() && f.calls.size()==writes && f.native_dynamic(),
        "ordinary retained release unexpectedly served as diagnostic finalization");
    f.no_extra_authority();const auto out=reactivation_finish(f);
    check(out.status==br::Status::observed && out.phase==br::Phase::terminal && out.cleanup==br::Cleanup::confirmed &&
        !out.cleanup_owed && out.first_failure==br::Check::none && out.cycle_count==1 && !out.native_retirement_known,
        "one bounded cycle did not finish with separately confirmed repark");
    const std::vector<ReactivationCall> expected{
        ReactivationCall::categories,ReactivationCall::collisions,ReactivationCall::clear_force,ReactivationCall::clear_torque,
        ReactivationCall::linear,ReactivationCall::angular,ReactivationCall::park_motion,
        ReactivationCall::transform,ReactivationCall::categories,ReactivationCall::collisions,ReactivationCall::dynamic_motion,ReactivationCall::wake,
        ReactivationCall::categories,ReactivationCall::collisions,ReactivationCall::clear_force,ReactivationCall::clear_torque,
        ReactivationCall::linear,ReactivationCall::angular,ReactivationCall::park_motion};
    check(f.calls==expected,"one-cycle native setter order omitted explicit retained-body repark or repeated activation");
    check(s.parked_ms==parked_ms && s.handle==handle && s.body==body && s.shapes==shapes && s.made==1 &&
        s.allocation.body_confirmed==allocation.body_confirmed && s.allocation.shapes_attempted==allocation.shapes_attempted &&
        s.allocation.shapes_confirmed==allocation.shapes_confirmed && matches_retained_park(owner,f.original_basis,original_park) &&
        !s.release_requested && s.retained && !s.active && !f.native_dynamic(),"diagnostic restamped original SDK park history or replaced an allocation");
    check(out.record_count<=br::record_capacity && out.record_count>0 && out.records[out.record_count-1].stage==br::Stage::repark_observed,
        "terminal result omitted bounded repark observation");
    f.no_extra_authority();const auto calls=f.calls.size();
    for(unsigned step=0;step<3;++step)f.later();
    check(f.calls.size()==calls && f.poll().cycle_count==1,"terminal diagnostic repeated a cycle on later ticks");
}
void reactivation_receipt_debt_and_pending_states_are_preserved() {
    for(unsigned fault=0;fault<8;++fault) {
        ReactivationFixture f;auto& s=f.slot();
        if(fault<6) {
            constexpr std::array<Outcome,6> outcomes{Outcome::none,Outcome::queued,Outcome::applied,Outcome::partial,Outcome::rejected,Outcome::expired};
            s.mailbox.count=1;s.mailbox.sequence=91;s.mailbox.receipts[0].sequence=91;s.mailbox.receipts[0].outcome=outcomes[fault];
            s.mailbox.receipts[0].requested=f.original_source.sample().epoch;s.mailbox.receipts[0].force_attempted=true;
        } else if(fault==6)s.mailbox.pending=true;else s.mailbox.producing=true;
        const ParkSlotSnapshot before(s);
        check(!f.begin().empty() && !f.sequence && f.calls.empty() && before.same(s),
            "admission acknowledged, cancelled or changed rejected terminal/pending/producing body debt");
        check(test_facts::reactivation_allocations==0 && test_facts::reactivation_capsules==0,"debt refusal allocated a fallback body");
    }
}
void reactivation_actual_dependency_permanently_revokes_never_held_witness() {
    ReactivationFixture f;auto& s=f.slot();BodyReleaseHold hold;
    check(s.never_held && acquire_release_hold(owner,f.original_source,hold) && hold.available() && !s.never_held,
        "actual dependency acquisition did not permanently clear never-held witness");
    check(release_body_hold(owner,hold) && !s.release_hold && !s.never_held,"dependency release restored never-held eligibility");
    const ParkSlotSnapshot before(s);
    check(!f.begin().empty() && !f.sequence && f.calls.empty() && before.same(s),"zero current hold incorrectly admitted a historically held body");
}
void reactivation_admission_rejects_identity_allocation_configuration_and_clock_faults() {
    for(unsigned fault=0;fault<28;++fault) {
        ReactivationFixture f;auto& s=f.slot();
        switch(fault) {
        case 0:s.allocation.body_confirmed=false;break;
        case 1:++s.allocation.shapes_attempted;break;
        case 2:s.allocation.shapes_confirmed=0;break;
        case 3:s.body_observed=false;break;
        case 4:s.reuse_faulted=true;break;
        case 5:s.owner_closed=true;break;
        case 6:service.owner_close_uncertain=true;break;
        case 7:s.quarantined=true;break;
        case 8:s.creation_failed=true;break;
        case 9:s.release_hold=7;break;
        case 10:s.never_held=false;break;
        case 11:++s.body.generation;break;
        case 12:++s.shapes[0].generation;break;
        case 13:put(f.context+test_world_field,f.world+64);break;
        case 14:put(f.allocations,std::uint32_t{});break;
        case 15:put(load<std::uintptr_t>(f.state+r::shape_allocated_bits),std::uint32_t{});break;
        case 16:put(load<std::uintptr_t>(f.state+r::shape_owners)+shape_index*4,std::uint32_t{3});break;
        case 17:put(f.categories+shape_index*4,std::uint32_t{1});break;
        case 18:put(f.collisions+shape_index*4,std::uint32_t{2});break;
        case 19:put(load<std::uintptr_t>(f.state+r::inverse_mass_array)+body_index*4,1.f);break;
        case 20:put(load<std::uintptr_t>(f.state+r::inertia_ratio_array)+body_index*sizeof(V4),V4{1,1,1,0});break;
        case 21:clock_feed.serial=0;break;
        case 22:test_clock::now+=command_lifetime_ms+1;service.tick_at=test_clock::now;break;
        case 23:f.protect_position(PAGE_NOACCESS);break;
        case 24:put(f.base+c::set_motion_type.rva,std::uint8_t{0});break;
        case 25:f.qualified=false;break;
        case 26:service.eligible=false;break;
        case 27:test_facts::multiplayer_active=true;break;
        }
        const ParkSlotSnapshot before(s);
        check(!f.begin().empty() && !f.sequence && f.calls.empty() && before.same(s),
            "invalid allocation/identity/configuration/clock/qualification reached admission mutation");
        if(fault==23)f.protect_position(PAGE_READWRITE);
    }
}
void reactivation_admission_owner_thread_lock_and_sequence_fences() {
    { ReactivationFixture f;const ParkSlotSnapshot before(f.slot());check(!f.begin(owner+1).empty() && !f.sequence && before.same(f.slot()) && f.calls.empty(),"foreign owner admitted body probe"); }
    { ReactivationFixture f;++f.slot().owner;const ParkSlotSnapshot before(f.slot());check(!f.begin().empty() && !f.sequence && before.same(f.slot()) && f.calls.empty(),"qualified caller bypassed the actual provider body-owner lookup"); }
    { ReactivationFixture f;const ParkSlotSnapshot before(f.slot());++f.handle.generation;check(!f.begin().empty() && !f.sequence && before.same(f.slot()),"foreign generation admitted body probe"); }
    { ReactivationFixture f;const ParkSlotSnapshot before(f.slot());std::string error;
      std::thread caller([&]{error=f.begin();});caller.join();check(!error.empty() && !f.sequence && before.same(f.slot()) && f.calls.empty(),"foreign thread admitted body probe"); }
    { ReactivationFixture f;const ParkSlotSnapshot before(f.slot());std::atomic<bool> locked{},resume{};
      std::thread holder([&]{AcquireSRWLockExclusive(&service.lock);locked=true;while(!resume.load())std::this_thread::yield();ReleaseSRWLockExclusive(&service.lock);});
      while(!locked.load())std::this_thread::yield();const auto error=f.begin();resume=true;holder.join();
      check(!error.empty() && !f.sequence && before.same(f.slot()) && f.calls.empty(),"busy World admission blocked or mutated authority"); }
    { ReactivationFixture f;reactivation_probe.generation=UINT64_MAX;check(!f.begin().empty() && !f.sequence && f.calls.empty(),"request sequence exhaustion wrapped diagnostic identity"); }
    { ReactivationFixture f;test_clock::now=UINT64_MAX-br::cleanup_lifetime_ms+1;service.tick_at=test_clock::now;f.step();
      check(!f.begin().empty() && !f.sequence && f.calls.empty(),"deadline overflow admitted body diagnostic"); }
}
std::size_t reactivation_call_count(const ReactivationFixture& f,ReactivationCall call) {
    return static_cast<std::size_t>(std::count(f.calls.begin(),f.calls.end(),call));
}
void reactivation_setter_faults_preserve_first_failure_and_cleanup_duty() {
    // Seven initial park calls, five activation calls, seven explicit repark
    // calls. Exercise exception-before and partial-write-then-exception edges.
    for(unsigned ordinal=1;ordinal<=19;++ordinal)for(bool after_write:{false,true}) {
        ReactivationFixture f;auto& s=f.slot();f.fail_at=ordinal;f.fail_after_write=after_write;
        check(f.begin().empty() && f.sequence && s.retained && !s.active,"native setter failure lost admitted diagnostic or restored ordinary authority");
        const auto parked_ms=s.parked_ms;auto failure=br::Check::none;
        for(unsigned step=0;step<16;++step) {
            const auto out=f.poll();
            if(failure==br::Check::none)failure=out.first_failure;
            else check(out.first_failure==failure,"cleanup replaced the first native setter failure");
            if(out.phase==br::Phase::terminal)break;
            f.later();
        }
        const auto out=reactivation_finish(f);
        check(f.calls.size()>=ordinal && out.first_failure!=br::Check::none && out.status!=br::Status::observed &&
            out.cleanup!=br::Cleanup::pending && !out.native_retirement_known && s.retained && !s.active && s.parked_ms==parked_ms,
            "setter fault was silently accepted, lost cleanup state or restamped original park history");
        if(failure!=br::Check::none)check(out.first_failure==failure,"deadline changed the first setter failure");
        check(reactivation_call_count(f,ReactivationCall::transform)<=1 && reactivation_call_count(f,ReactivationCall::dynamic_motion)<=1,
            "setter failure retried activation or allocated a fallback cycle");
        if(ordinal<11)check(reactivation_call_count(f,ReactivationCall::dynamic_motion)==0,"failed earlier setter still admitted motion3");
        f.no_extra_authority();
    }
}
void reactivation_silent_setter_refusal_requires_exact_readback() {
    for(unsigned ordinal:{8U,10U,11U}) {
        ReactivationFixture f;f.silent_at=ordinal;
        check(f.begin().empty() && f.sequence,"silent setter setup admission failed");
        const auto out=reactivation_finish(f);
        check(f.calls.size()>=ordinal && out.status!=br::Status::observed && out.first_failure!=br::Check::none &&
            out.cleanup!=br::Cleanup::pending && !out.native_retirement_known,"void setter return was mistaken for exact native postcondition acceptance");
        if(ordinal==10)check(reactivation_call_count(f,ReactivationCall::dynamic_motion)==0,
            "permissive pool collision check admitted motion3 without exact intended masks");
        f.no_extra_authority();
    }
}
void reactivation_each_activation_setter_rechecks_identity_and_qualification() {
    for(unsigned ordinal=8;ordinal<=12;++ordinal)for(bool identity_fault:{false,true}) {
        ReactivationFixture f;bool fired{};
        f.interleave=[&](ReactivationCall){
            if(f.calls.size()!=ordinal)return;
            fired=true;f.interleave={};
            if(identity_fault)put(f.body_generations+body_index*4,body_generation+1);else f.qualified=false;
        };
        check(f.begin().empty() && f.sequence,"activation interleave setup failed");
        const auto out=reactivation_finish(f);
        check(fired && out.status!=br::Status::observed && out.first_failure!=br::Check::none &&
            out.cleanup!=br::Cleanup::pending && !out.native_retirement_known,"interleaved identity/qualification loss was accepted or lost finalization");
        if(identity_fault)check(f.calls.size()==ordinal && out.cleanup==br::Cleanup::unconfirmed,
            "identity loss caused blind rollback writes into an unqualified allocation");
        if(ordinal<11)check(reactivation_call_count(f,ReactivationCall::dynamic_motion)==0,
            "qualification/identity loss before activation still reached motion3");
        f.no_extra_authority();
    }
}
void reactivation_later_epoch_and_copied_poll_do_not_advance_early() {
    ReactivationFixture f;check(f.begin().empty() && f.sequence,"epoch-fence admission failed");
    const auto first=f.poll();const auto calls=f.calls.size();
    for(unsigned pass=0;pass<3;++pass){++test_clock::now;tick(f.base,f.client,true);(void)f.poll();}
    check(f.calls.size()==calls && f.poll().phase==first.phase && reactivation_call_count(f,ReactivationCall::transform)==0,
        "wall-clock or polling alone manufactured a later genuine park epoch");
    f.later();reactivation_until(f,br::Phase::await_dynamic);const auto dynamic_calls=f.calls.size();
    for(unsigned pass=0;pass<3;++pass){++test_clock::now;tick(f.base,f.client,true);(void)f.poll();}
    check(f.calls.size()==dynamic_calls && f.poll().phase==br::Phase::await_dynamic,
        "same native epoch fabricated dynamic observation or advanced repark");
    const auto out=reactivation_finish(f);check(out.status==br::Status::observed && out.cleanup==br::Cleanup::confirmed,
        "later genuine epochs failed to complete otherwise-qualified observations");
}
void reactivation_readiness_early_returns_still_expire_cleanup_metadata() {
    for(unsigned route=0;route<5;++route) {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"readiness deadline setup failed");
        reactivation_until(f,br::Phase::await_dynamic);const auto writes=f.calls.size();
        test_clock::now=reactivation_probe.cleanup_deadline;
        if(route==0)tick(f.base,f.client,false);
        if(route==1){test_facts::multiplayer_active=true;tick(f.base,f.client,true);}
        if(route==2){service.hooked=false;tick(f.base,f.client,true);}
        if(route==3){put(f.context+test_world_field,std::uintptr_t{});tick(f.base,f.client,true);}
        if(route==4)tick(f.base+4096,f.client,true);
        const auto out=f.poll();
        check(out.phase==br::Phase::terminal && out.cleanup==br::Cleanup::unconfirmed && out.cleanup_owed &&
            out.first_failure!=br::Check::none && out.status!=br::Status::observed && !out.native_retirement_known,
            "readiness/base/capture early return skipped durable cleanup-deadline accounting");
        check(f.calls.size()==writes,"expired or unqualified cleanup performed blind native rollback");
        const auto failure=out.first_failure;tick(f.base,f.client,false);
        check(f.poll().first_failure==failure && f.poll().cleanup==br::Cleanup::unconfirmed,
            "later unavailable tick erased original failure or unconfirmed cleanup duty");
    }
}
void reactivation_owner_close_keeps_cleanup_and_old_result_private() {
    for(const auto phase:{br::Phase::await_initial_park,br::Phase::await_dynamic,br::Phase::await_repark}) {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"owner-close admission failed");
        reactivation_until(f,phase);const auto writes=f.calls.size();const auto parked_ms=f.slot().parked_ms;
        revoke_body_reactivation_probe(owner+1);
        check(f.poll().phase==phase && f.calls.size()==writes,"foreign owner close revoked another body's diagnostic");
        release_all(owner);const auto failure=reactivation_probe.result.first_failure;
        check(f.slot().owner_closed && reactivation_probe.result.cleanup_owed && f.slot().retained && !f.slot().active,
            "owner unload discarded private cleanup duty or reopened ordinary body authority");
        br::Result hidden;
        check(!poll_body_reactivation_probe(owner,f.handle,f.sequence,hidden).empty(),"closed owner retained public access to private diagnostic result");
        for(unsigned step=0;step<16 && reactivation_probe.result.phase!=br::Phase::terminal;++step)f.later();
        if(reactivation_probe.result.phase!=br::Phase::terminal) {
            test_clock::now=reactivation_probe.cleanup_deadline;tick(f.base,f.client,false);
        }
        const auto out=reactivation_probe.result;
        check(out.phase==br::Phase::terminal && out.status!=br::Status::observed && out.first_failure!=br::Check::none &&
            out.cleanup==br::Cleanup::confirmed && !out.cleanup_owed && !out.native_retirement_known &&
            f.slot().retained && !f.slot().active && !f.native_dynamic() && f.slot().parked_ms==parked_ms,
            "clean owner close stopped qualified repark, restamped SDK history or erased failure");
        if(phase==br::Phase::await_dynamic)check(f.calls.size()>=writes+7,
            "owner close while dynamic failed to execute explicit native repark");
        if(failure!=br::Check::none)check(out.first_failure==failure,"owner cleanup replaced its first refusal");
        const auto calls=f.calls.size();release_all(owner);revoke_body_reactivation_probe(owner);f.later();
        check(f.calls.size()==calls && reactivation_probe.result.first_failure==out.first_failure &&
            reactivation_probe.result.cleanup==out.cleanup,"repeated owner close restarted or erased terminal cleanup");
    }
}
void reactivation_deadline_and_qualification_revocation_stop_activation() {
    for(unsigned fault=0;fault<3;++fault) {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"revocation admission failed");const auto writes=f.calls.size();
        if(fault==0)test_clock::now=reactivation_probe.run_deadline;
        if(fault==1)f.qualified=false;
        if(fault==2)revoke_body_reactivation_probe(owner);
        f.later();
        check(reactivation_call_count(f,ReactivationCall::transform)==0 && reactivation_call_count(f,ReactivationCall::dynamic_motion)==0 &&
            reactivation_probe.result.first_failure!=br::Check::none && reactivation_probe.result.cleanup_owed,
            "run deadline/arm revocation admitted further activation or discarded cleanup duty");
        check(f.calls.size()>=writes,"revocation erased ordered native evidence");
        test_clock::now=reactivation_probe.cleanup_deadline;tick(f.base,f.client,false);
        check(reactivation_probe.result.phase==br::Phase::terminal && reactivation_probe.result.cleanup!=br::Cleanup::pending,
            "revoked diagnostic failed bounded metadata finalization");
    }
}
void reactivation_final_readback_deadline_is_a_closing_fence() {
    unsigned closing_reads{};
    {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"closing deadline baseline admission failed");
        reactivation_until(f,br::Phase::await_repark);
        test_clock::park_read_hook=[&](unsigned){if(reactivation_probe.result.phase==br::Phase::await_repark)++closing_reads;};
        f.later();test_clock::park_read_hook={};
        check(f.poll().status==br::Status::observed && closing_reads>=2,"closing deadline baseline did not reach genuine terminal readback");
    }
    for(std::uint64_t lateness:{0ULL,1ULL}) {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"closing deadline fault admission failed");
        reactivation_until(f,br::Phase::await_repark);unsigned reads{};bool injected{};
        // Inject at the actual final post-observation time read. Earlier reads
        // would only test stale-clock rejection and could hide a missing closing fence.
        test_clock::park_read_hook=[&](unsigned){
            if(reactivation_probe.result.phase==br::Phase::await_repark && ++reads==closing_reads) {
                injected=true;test_clock::now=reactivation_probe.cleanup_deadline+lateness;
            }
        };
        f.later();test_clock::park_read_hook={};
        const auto out=f.poll();
        check(injected && out.phase==br::Phase::terminal && out.first_failure==br::Check::cleanup_deadline &&
            out.status==br::Status::expired && out.cleanup==br::Cleanup::unconfirmed && out.cleanup_owed,
            "final post-observation clock crossing or equaling cleanup deadline failed same-tick closure");
        tick(f.base,f.client,false);
        check(f.poll().first_failure==br::Check::cleanup_deadline && f.poll().cleanup==br::Cleanup::unconfirmed && f.poll().cleanup_owed,
            "late closing observation lost durable unresolved cleanup duty");
    }
}
void reactivation_slow_initializer_exit_accounts_cleanup_deadline() {
    ReactivationFixture f;check(f.begin().empty() && f.sequence,"slow setup deadline admission failed");
    reactivation_until(f,br::Phase::await_dynamic);const auto writes=f.calls.size();
    test_clock::now=reactivation_probe.cleanup_deadline-25;
    service.initialization_requested=true;service.hook_attempted=false;
    test_facts::reactivation_image_allowed=false;test_facts::inspect_initializer_lock=true;
    test_facts::initializer_unlocked=false;test_facts::initializer_elapsed=300;
    tick(f.base,f.client,true);
    test_facts::inspect_initializer_lock=false;test_facts::initializer_elapsed=0;
    const auto out=f.poll();
    check(test_facts::forbidden_links==1 && test_facts::initializer_unlocked && test_clock::now>=reactivation_probe.cleanup_deadline,
        "slow setup fixture failed to cross cleanup deadline outside World lock");
    check(out.phase==br::Phase::terminal && out.cleanup==br::Cleanup::unconfirmed && out.cleanup_owed &&
        out.first_failure!=br::Check::none && f.calls.size()==writes,"second readiness early return deferred expired cleanup metadata to another tick");
}
void reactivation_dynamic_observation_rejects_changed_native_facts() {
    for(unsigned fault=0;fault<11;++fault) {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"dynamic observation fault admission failed");
        reactivation_until(f,br::Phase::await_dynamic);
        switch(fault) {
        case 0:put(f.collisions+shape_index*4,std::uint32_t{});break;
        case 1:put(f.categories+shape_index*4,std::uint32_t{1});break;
        case 2:put(f.dynamics,std::uint32_t{});break;
        case 3:put(load<std::uintptr_t>(f.state+r::shape_body_indices)+shape_index*4,body_index+1);break;
        case 4:put(load<std::uintptr_t>(f.state+r::inverse_mass_array)+body_index*4,1.f);break;
        case 5:put(load<std::uintptr_t>(f.state+r::inertia_ratio_array)+body_index*sizeof(V4),V4{1,1,1,0});break;
        case 6:put(f.body_generations+body_index*4,body_generation+1);break;
        case 7:put(load<std::uintptr_t>(f.state+r::shape_generations)+shape_index,std::uint8_t{shape_generation+1});break;
        case 8:f.protect_position(PAGE_NOACCESS);break;
        case 9:++service.world_generation;break;
        case 10:f.slot().definition.mass+=1;break;
        }
        f.later();const auto failure=f.poll();
        check(failure.first_failure!=br::Check::none && failure.status!=br::Status::observed,
            "changed mask/motion/configuration/attachment/native identity was accepted as later dynamic evidence");
        if(fault==8)f.protect_position(PAGE_READWRITE);
        const auto out=reactivation_finish(f);
        check(out.first_failure==failure.first_failure && out.status!=br::Status::observed && !out.native_retirement_known,
            "cleanup replaced the dynamic observation failure or granted native lifetime authority");
    }
}
void reactivation_closing_admission_revalidates_unlocked_capture() {
    for(unsigned fault=0;fault<10;++fault) {
        ReactivationFixture f;bool fired{};std::array<unsigned char,sizeof(Slot)> injected{};
        f.qualification_interleave=[&](unsigned call){
            if(call!=2)return;fired=true;f.qualification_interleave={};auto& s=f.slot();
            if(fault==0){s.mailbox.count=1;s.mailbox.receipts[0].sequence=987;s.mailbox.receipts[0].outcome=Outcome::applied;}
            if(fault==1)s.release_hold=17;if(fault==2)s.never_held=false;if(fault==3)s.owner_closed=true;
            if(fault==4)++service.world_generation;if(fault==5)++s.body.generation;if(fault==6)++s.shapes[0].generation;
            if(fault==7)s.definition.mass+=1;
            if(fault==8){++clock_feed.serial;clock_feed.sequence=clock_feed.serial;clock_feed.time+=clock_feed.seconds;}
            if(fault==9)service.hooked=false;
            std::memcpy(injected.data(),&s,injected.size());
        };
        check(!f.begin().empty() && fired && !f.sequence && f.calls.empty() && std::memcmp(injected.data(),&f.slot(),injected.size())==0,
            "closing admission ignored interleaved debt/dependency/identity/clock or changed refused body state");
    }
    ReactivationFixture f;service.probe.owner=owner;service.probe.handle=f.handle;service.probe.sequence=1;
    service.probe.result.status=body_sync_probe::Status::pending;
    const ParkSlotSnapshot before(f.slot());
    check(!f.begin().empty() && !f.sequence && f.calls.empty() && before.same(f.slot()),"competing body probe admission changed shared authority");
}
void reactivation_second_shape_mask_failure_reports_exact_index() {
    for(bool after_write:{false,true}) {
        ReactivationFixture f;auto& s=f.slot();constexpr std::uint32_t second=shape_index+1;
        s.definition.count=2;s.definition.capsules[1]=s.definition.capsules[0];s.made=2;
        s.shapes[1]={f.world,second,shape_generation+1};s.allocation.shapes_attempted=s.allocation.shapes_confirmed=2;
        const auto shape_bits=load<std::uintptr_t>(f.state+r::shape_allocated_bits);
        put(shape_bits,(1U<<shape_index)|(1U<<second));
        put(load<std::uintptr_t>(f.state+r::shape_generations)+second,std::uint8_t{shape_generation+1});
        put(load<std::uintptr_t>(f.state+r::shape_owners)+second*4,0xffffffffU);
        put(load<std::uintptr_t>(f.state+r::shape_body_indices)+second*4,body_index);
        put(f.categories+second*4,r::safe_categories);put(f.collisions+second*4,r::safe_world_collisions);
        // Initial park: nine calls. Transform: one, categories: two, then the
        // second collision setter is call fourteen; no dynamic writer follows.
        f.fail_at=14;f.fail_after_write=after_write;
        check(f.begin().empty() && f.sequence,"two-shape diagnostic admission failed");
        const auto out=reactivation_finish(f);
        check(out.first_failure==br::Check::collisions && out.failure_shape_known && out.failure_shape==1 &&
            out.status!=br::Status::observed && reactivation_call_count(f,ReactivationCall::dynamic_motion)==0 && s.made==2 &&
            s.allocation.shapes_attempted==2 && s.allocation.shapes_confirmed==2,
            "second-shape failure lost exact index, advanced activation or replaced capsule allocation");
    }
}
void reactivation_write_guard_samples_age_after_closing_clock() {
    unsigned guard_reads{};
    {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"closing age baseline admission failed");
        reactivation_until(f,br::Phase::activation);
        test_clock::park_read_hook=[&](unsigned){++guard_reads;};
        AcquireSRWLockExclusive(&service.lock);const bool allowed=reactivation_write_guard(f.slot(),false);
        ReleaseSRWLockExclusive(&service.lock);test_clock::park_read_hook={};
        check(allowed && guard_reads>=2,"closing age baseline did not qualify actual write guard");
    }
    for(std::uint64_t lateness:{0ULL,1ULL}) {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"closing age fault admission failed");
        reactivation_until(f,br::Phase::activation);unsigned reads{};bool injected{};const auto writes=f.calls.size();
        // The valid guard's final read checks the run deadline; its previous
        // read must sample wall time AFTER the second native clock observation.
        test_clock::park_read_hook=[&](unsigned){
            if(++reads==guard_reads-1){injected=true;test_clock::now=clock_feed.observed+command_lifetime_ms+lateness;}
        };
        AcquireSRWLockExclusive(&service.lock);const bool allowed=reactivation_write_guard(f.slot(),false);
        ReleaseSRWLockExclusive(&service.lock);test_clock::park_read_hook={};
        check(injected && !allowed && reactivation_probe.result.first_failure==br::Check::clock && f.calls.size()==writes &&
            reactivation_probe.result.cleanup_owed,"write guard accepted a clock reaching its age bound during closing observation");
        const auto out=reactivation_finish(f);check(out.first_failure==br::Check::clock && out.status!=br::Status::observed,
            "fresh cleanup ticks erased the original closing-clock failure");
    }
}
void reactivation_slow_qualification_closes_cleanup_in_same_tick() {
    for(std::uint64_t lateness:{0ULL,1ULL}) {
        ReactivationFixture f;check(f.begin().empty() && f.sequence,"slow qualification admission failed");
        reactivation_until(f,br::Phase::await_dynamic);const auto writes=f.calls.size();bool fired{};
        f.qualification_interleave=[&](unsigned){
            fired=true;f.qualification_interleave={};test_clock::now=reactivation_probe.cleanup_deadline+lateness;
        };
        f.later();const auto out=f.poll();
        check(fired && out.phase==br::Phase::terminal && out.cleanup==br::Cleanup::unconfirmed && out.cleanup_owed &&
            out.first_failure!=br::Check::none && out.status!=br::Status::observed && out.elapsed_ms>=br::cleanup_lifetime_ms &&
            f.calls.size()==writes,"slow qualification callback escaped same-tick cleanup deadline accounting or caused native writes");
    }
}
void reactivation_slow_park_setter_stops_following_writes_and_closes_cleanup() {
    for(bool initial:{true,false}) {
        ReactivationFixture f;
        if(!initial) { check(f.begin().empty() && f.sequence,"slow final park admission failed");reactivation_until(f,br::Phase::repark); }
        const auto writes=f.calls.size();const auto parked_ms=f.slot().parked_ms;bool fired{};
        f.interleave=[&](ReactivationCall call){
            if(call!=ReactivationCall::categories)return;
            fired=true;f.interleave={};test_clock::now=reactivation_probe.cleanup_deadline+1;
        };
        if(initial)check(f.begin().empty() && f.sequence,"slow initial park lost its admitted opaque diagnostic");else f.later();
        const auto out=f.poll();
        check(fired && f.calls.size()==writes+1 && out.phase==br::Phase::terminal && out.cleanup==br::Cleanup::unconfirmed &&
            out.cleanup_owed && out.first_failure==br::Check::cleanup_deadline && out.status==br::Status::expired &&
            f.slot().retained && !f.slot().active && !out.native_retirement_known,
            "slow park setter permitted later setters or deferred unconfirmed cleanup past the admitting call/tick");
        if(!initial)check(f.slot().parked_ms==parked_ms,"slow final park restamped the original SDK retirement history");
    }
}
#else
void reactivation_default_off_has_no_executable_provider() {
    Fixture f;
    check(!owned_bodies::begin_body_reactivation_probe && !owned_bodies::poll_body_reactivation_probe &&
        !owned_bodies::revoke_body_reactivation_probe,"OFF translation unit exposed a diagnostic mutation route");
    check(f.source().sample().mass==12 && f.slot().active && !f.slot().retained,"OFF build changed ordinary source authority");
}
#endif
