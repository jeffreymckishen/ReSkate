// Actual World admission and cleanup with constructed native arrays and counted
// substitute leaves. The trusted completed Follow precondition is constructed;
// this fixture does not execute or qualify a retail Follow callback/return chain.
#if defined(DINGOSDK_BODY_REACTIVATION_QUALIFICATION) && DINGOSDK_BODY_REACTIVATION_QUALIFICATION
struct PostFollowReactivationFixture : ReactivationFixture {
    static constexpr std::uint64_t follow_sequence=73, body_sequence=91;
    RetirementBasis completed_basis;
    RetainedParkReceipt completed_park;
    explicit PostFollowReactivationFixture(bool acknowledge_body=true, bool record_handoff=true) {
        auto& s=slot();BodyReleaseHold hold;
        check(acquire_release_hold(owner,original_source,hold) && hold.available() && !s.never_held,
            "post-Follow setup did not acquire a real World dependency hold");
        Command command;command.epoch=original_source.sample().epoch;
        check(s.mailbox.submit(command,command.epoch,test_clock::now,body_sequence),"post-Follow command seed failed");
        advance();const auto latest=source();Command produced;
        check(s.mailbox.consume(latest.sample().epoch,test_clock::now,produced) && s.mailbox.finish(true,true,true),
            "post-Follow constructed applied command did not retain receipt debt");
        check(request_held_release(owner,hold) && capture_retirement_basis(owner,original_source,completed_basis),
            "post-Follow setup lost its cleanup-only retirement basis");
        // The retaining service's drain/final-return has been constructed here.
        // The real World hold, release, later observation and seal run below.
        check(release_body_hold(owner,hold) && !hold.available() && release(owner,handle).empty(),
            "post-Follow setup could not release and park the exact retained body");
        check(calls.size()==7 && s.retained && !s.active && !s.quarantined && s.release_requested && !s.release_hold,
            "post-Follow setup did not execute the existing park setter sequence");
        advance();
        check(observe_retained_park(owner,completed_basis,completed_park) &&
            seal_parked_command_cleanup(owner,completed_basis,completed_park),"post-Follow setup could not seal its later park history");
        if(record_handoff)
            check(record_completed_follow_ack(owner,follow_sequence,completed_basis,completed_park)==CompletedAckHandoff::recorded,
                "post-Follow setup did not record exact immutable completion provenance");
        if(acknowledge_body) {
            Receipt out;
            check(receipt(owner,handle,body_sequence,out).empty() && out.outcome==Outcome::applied &&
                out.cleanup_disposition==CleanupDisposition::parked_without_successor && !out.successor_available &&
                acknowledge(owner,handle,body_sequence).empty(),"post-Follow body debt did not receive its separate exact ACK");
        }
        advance();calls.clear();
    }
    void advance() { test_clock::now+=10;service.tick_at=test_clock::now;step(); }
    void refused_unchanged(const char* message) {
        const ParkSlotSnapshot before(slot());const auto writes=calls.size();
        check(!begin().empty() && !sequence && calls.size()==writes && before.same(slot()),message);
        check(test_facts::reactivation_allocations==0 && test_facts::reactivation_capsules==0,
            "refused post-Follow admission allocated a replacement body or shape");
    }
};
void post_follow_reactivation_keeps_retained_identity_and_reparks_once() {
    PostFollowReactivationFixture f;auto& s=f.slot();const auto body=s.body;const auto handle=s.handle;
    const auto shapes=s.shapes;const auto parked=s.parked_ms;const auto allocation=s.allocation;
    const auto generation=service.generation,release_generation=service.release_generation;
    std::array<unsigned char,sizeof(Mailbox)> mailbox{};std::memcpy(mailbox.data(),&s.mailbox,mailbox.size());SetLastError(0xBA21);
    check(f.begin().empty() && f.sequence && GetLastError()==0xBA21 && f.calls.empty(),
        "post-Follow admission wrote native state, failed or changed LastError");
    const auto admitted=f.poll();
    check(admitted.phase==br::Phase::activation && admitted.status==br::Status::pending && admitted.cleanup_owed &&
        admitted.record_count==2 && admitted.records[0].stage==br::Stage::initial_park && admitted.records[0].historical_park_basis &&
        !admitted.records[0].observation.available && !admitted.records[1].historical_park_basis &&
        admitted.records[0].epoch==f.completed_basis.epoch() && admitted.records[1].stage==br::Stage::initial_park_observed &&
        admitted.records[1].observation.available && !admitted.records[1].observation.dynamic &&
        admitted.records[1].epoch.serial>f.completed_park.observed_epoch().serial &&
        !s.never_held && s.mailbox.failed && !s.active && s.retained,
        "post-Follow admission lost historical/fresh park distinction, cleanup duty or retained latches");
    const auto first=f.poll(),second=f.poll();
    check(first.phase==second.phase && first.record_count==second.record_count && first.elapsed_ms==second.elapsed_ms && f.calls.empty(),
        "post-Follow polling advanced native stages or renewed the proof");
    f.no_extra_authority();const auto out=reactivation_finish(f);
    const std::vector<ReactivationCall> expected{ReactivationCall::transform,ReactivationCall::categories,ReactivationCall::collisions,
        ReactivationCall::dynamic_motion,ReactivationCall::wake,ReactivationCall::categories,ReactivationCall::collisions,
        ReactivationCall::clear_force,ReactivationCall::clear_torque,ReactivationCall::linear,ReactivationCall::angular,ReactivationCall::park_motion};
    check(f.calls==expected && out.status==br::Status::observed && out.cleanup==br::Cleanup::confirmed && !out.cleanup_owed &&
        out.first_failure==br::Check::none && out.cycle_count==1 && !out.native_retirement_known && !f.native_dynamic(),
        "post-Follow cycle omitted explicit repark or granted a stronger native lifetime claim");
    for(std::size_t i=0;i<out.record_count;++i)
        check(out.records[i].historical_park_basis==(i==0),"post-Follow trace marked a newly performed stage as historical");
    check(s.body==body && s.handle==handle && s.shapes==shapes && s.parked_ms==parked && !s.never_held && s.release_requested &&
        !s.release_hold && s.retained && !s.active && s.completed_ack_sequence==f.follow_sequence &&
        matches_retained_park(owner,f.completed_basis,f.completed_park) &&
        s.allocation.body_confirmed==allocation.body_confirmed && s.allocation.shapes_attempted==allocation.shapes_attempted &&
        s.allocation.shapes_confirmed==allocation.shapes_confirmed && service.generation==generation && service.release_generation==release_generation &&
        std::memcmp(mailbox.data(),&s.mailbox,mailbox.size())==0,
        "post-Follow cycle replaced allocation, restamped park, reset a latch, changed mailbox debt or renewed ordinary authority");
    f.no_extra_authority();const auto writes=f.calls.size();
    for(unsigned pass=0;pass<3;++pass)f.later();
    check(f.calls.size()==writes && f.poll().cycle_count==1,"post-Follow terminal ticks repeated activation");
    f.refused_unchanged("post-Follow diagnostic permitted a second process-lifetime attempt");
}
void post_follow_reactivation_preserves_never_held_history_kind() {
    ReactivationFixture f;check(f.begin().empty() && f.sequence,"never-held history-kind baseline admission failed");
    const auto admitted=f.poll();
    check(admitted.record_count==1 && admitted.records[0].stage==br::Stage::initial_park &&
        !admitted.records[0].historical_park_basis,"new never-held park command was mislabeled as completed Follow history");
    const auto out=reactivation_finish(f);
    check(out.status==br::Status::observed && out.cleanup==br::Cleanup::confirmed,"never-held history-kind baseline did not complete its cycle");
    for(std::size_t i=0;i<out.record_count;++i)
        check(!out.records[i].historical_park_basis,"never-held cycle inherited a post-Follow historical park marker");
    f.no_extra_authority();
}
void post_follow_reactivation_requires_exact_completed_history() {
    { PostFollowReactivationFixture f(true,false);f.refused_unchanged("retained former dependency without CompletedAckHandoff was admitted"); }
    for(unsigned fault=0;fault<7;++fault) {
        PostFollowReactivationFixture f;auto& s=f.slot();
        if(fault==0)s.completed_ack_sequence=0;
        if(fault==1)s.completed_ack_basis={};
        if(fault==2)s.completed_ack_park={};
        if(fault==3)++s.parked_ms;
        if(fault==4)s.never_held=true;
        if(fault==5)s.release_requested=false;
        if(fault==6)s.mailbox.failed=false;
        f.refused_unchanged("post-Follow admission accepted missing, altered or inconsistent completed history");
    }
    PostFollowReactivationFixture f;const ParkSlotSnapshot before(f.slot());
    RetainedParkReceipt later;check(observe_retained_park(owner,f.completed_basis,later),"later constructed park receipt unavailable");
    check(record_completed_follow_ack(owner+1,f.follow_sequence,f.completed_basis,f.completed_park)==CompletedAckHandoff::unavailable &&
        record_completed_follow_ack(owner,f.follow_sequence+1,f.completed_basis,f.completed_park)==CompletedAckHandoff::unavailable &&
        record_completed_follow_ack(owner,f.follow_sequence,f.completed_basis,later)==CompletedAckHandoff::unavailable && before.same(f.slot()),
        "foreign owner, different Follow sequence or later replacement receipt changed original handoff");
}
void post_follow_reactivation_keeps_body_receipt_ack_separate() {
    PostFollowReactivationFixture f(false);auto& s=f.slot();const auto oldest=s.mailbox.oldest();
    check(s.completed_ack_sequence==f.follow_sequence && s.mailbox.count==1,"completed history incorrectly paid body receipt debt");
    f.refused_unchanged("post-Follow admission consumed or bypassed unacknowledged body debt");
    check(!acknowledge(owner,f.handle,f.body_sequence+1).empty() && s.mailbox.count==1 &&
        s.mailbox.oldest().sequence==oldest.sequence && s.mailbox.oldest().cleanup_disposition==oldest.cleanup_disposition &&
        acknowledge(owner,f.handle,f.body_sequence).empty() && !s.mailbox.count && s.mailbox.failed && !s.never_held,
        "body debt lost its independent exact-sequence ACK or ACK restored ordinary body authority");
    for(unsigned fault=0;fault<2;++fault) {
        PostFollowReactivationFixture other;
        if(fault==0)other.slot().mailbox.pending=true;else other.slot().mailbox.producing=true;
        other.refused_unchanged("post-Follow admission bypassed pending or producing command work");
    }
}
void post_follow_reactivation_refuses_owner_allocation_and_sticky_faults() {
    for(unsigned fault=0;fault<17;++fault) {
        PostFollowReactivationFixture f;auto& s=f.slot();
        if(fault==0)s.reuse_faulted=true;if(fault==1)s.owner_closed=true;
        if(fault==2)service.owner_close_uncertain=true;if(fault==3)s.quarantined=true;
        if(fault==4)s.creation_failed=true;if(fault==5)s.release_hold=17;
        if(fault==6)s.allocation.body_confirmed=false;if(fault==7)++s.allocation.shapes_attempted;
        if(fault==8)s.allocation.shapes_confirmed=0;if(fault==9)s.body_observed=false;
        if(fault==10)++s.body.generation;if(fault==11)++s.shapes[0].generation;
        if(fault==12)++s.owner;if(fault==13)++s.handle.generation;
        if(fault==14)++service.world_generation;if(fault==15)s.active=true;if(fault==16)s.retained=false;
        f.refused_unchanged("post-Follow admission accepted wrong owner/allocation/hold/authority or a sticky closure fault");
    }
    PostFollowReactivationFixture f;const ParkSlotSnapshot before(f.slot());
    check(!f.begin(owner+1).empty() && !f.sequence && before.same(f.slot()) && f.calls.empty(),
        "foreign caller admitted another owner's retained allocation");
}
void post_follow_reactivation_requires_fresh_coherent_parked_native_state() {
    for(unsigned fault=0;fault<12;++fault) {
        PostFollowReactivationFixture f;
        if(fault==0)put(f.dynamics,1U<<body_index);
        if(fault==1)put(f.categories+shape_index*4,std::uint32_t{1});
        if(fault==2)put(f.collisions+shape_index*4,r::safe_world_collisions);
        if(fault==3)put(f.velocity+body_index*sizeof(V4),V4{1,0,0,0});
        if(fault==4)put(f.spin+body_index*sizeof(V4),V4{0,1,0,0});
        if(fault==5)put(load<std::uintptr_t>(f.state+r::pending_force)+body_index*sizeof(V4),V4{0,0,1,0});
        if(fault==6)put(load<std::uintptr_t>(f.state+r::pending_torque)+body_index*sizeof(V4),V4{0,0,0,1});
        if(fault==7)put(load<std::uintptr_t>(f.state+r::shape_body_indices)+shape_index*4,body_index+1);
        if(fault==8)put(f.context+test_world_field,f.world+64);
        if(fault==9)put(f.allocations,std::uint32_t{0});
        if(fault==10)clock_feed.serial=0;
        if(fault==11)f.qualified=false;
        f.refused_unchanged("post-Follow admission accepted unparked, foreign, missing, stale or unqualified native facts");
    }
    for(std::uint64_t lateness:{0ULL,1ULL}) {
        PostFollowReactivationFixture f;test_clock::now=clock_feed.observed+command_lifetime_ms+lateness;service.tick_at=test_clock::now;
        f.refused_unchanged("post-Follow admission accepted a clock at or beyond its exact age bound");
    }
    PostFollowReactivationFixture f;test_clock::now=clock_feed.observed+command_lifetime_ms-1;service.tick_at=test_clock::now;
    check(f.begin().empty() && f.sequence && f.calls.empty(),"fresh post-Follow clock was refused before the declared age bound");
}
void post_follow_reactivation_rejects_nonadvancing_completion_clock() {
    for(unsigned fault=0;fault<5;++fault) {
        PostFollowReactivationFixture f;const auto completed=f.completed_park.observed_epoch();
        if(fault==0 || fault==1) {
            clock_feed.serial=completed.serial;clock_feed.time=completed.time;
            clock_feed.observed=f.completed_park.observed_ms();
            if(fault==1) { --clock_feed.serial;clock_feed.time-=completed.seconds;clock_feed.observed-=10; }
        }
        if(fault==2)clock_feed.time=completed.time;
        if(fault==3)clock_feed.observed=f.completed_park.observed_ms();
        if(fault==4)clock_feed.serial=completed.serial;
        clock_feed.sequence=clock_feed.serial;
        f.refused_unchanged("same, regressed or only partly advancing clock replaced the completed Follow park observation");
    }
}
void post_follow_reactivation_refuses_concurrent_probes() {
    for(unsigned fault=0;fault<5;++fault) {
        PostFollowReactivationFixture f;
        if(fault<2) {
            service.probe.owner=owner+fault;service.probe.handle=f.handle;service.probe.sequence=1;
            service.probe.result.status=body_sync_probe::Status::pending;
        } else {
            motion_probe.owner=owner;motion_probe.sequence=fault==4?0:1;motion_probe.deadline=test_clock::now+100;
            motion_probe.result.status=fault==2?mp::Status::pending:mp::Status::observed;
            motion_probe.inflight=fault==3;motion_probe.requested=fault==4;
        }
        f.refused_unchanged("post-Follow admission overlapped another pending or in-flight diagnostic");
    }
}
void post_follow_reactivation_rechecks_closing_handoff_and_identity() {
    for(unsigned fault=0;fault<9;++fault) {
        PostFollowReactivationFixture f;bool fired{};std::array<unsigned char,sizeof(Slot)> injected{};
        f.qualification_interleave=[&](unsigned call){
            if(call!=2)return;fired=true;f.qualification_interleave={};auto& s=f.slot();
            if(fault==0)++s.completed_ack_sequence;if(fault==1)s.completed_ack_basis={};if(fault==2)s.completed_ack_park={};
            if(fault==3)s.release_hold=17;if(fault==4)s.mailbox.pending=true;if(fault==5)s.owner_closed=true;
            if(fault==6)s.definition.position[0]+=1;if(fault==7)++s.shapes[0].generation;if(fault==8)++service.world_generation;
            std::memcpy(injected.data(),&s,injected.size());
        };
        check(!f.begin().empty() && fired && !f.sequence && f.calls.empty() &&
            std::memcmp(injected.data(),&f.slot(),injected.size())==0,
            "post-Follow closing admission ignored changed handoff/identity/debt or mutated refused state");
    }
}
void post_follow_reactivation_handoff_loss_stops_activation_but_keeps_cleanup() {
    constexpr std::array stages{br::Stage::transform,br::Stage::categories,br::Stage::collisions,br::Stage::motion,br::Stage::wake};
    for(const auto stage:stages) {
        PostFollowReactivationFixture f;check(f.begin().empty() && f.sequence,"post-Follow stage-loss admission failed");
        for(unsigned step=0;step<5 && reactivation_probe.next_stage!=stage;++step)f.later();
        check(reactivation_probe.result.phase==br::Phase::activation && reactivation_probe.next_stage==stage,
            "post-Follow test did not reach its selected next activation writer");
        const bool dynamic=stage==br::Stage::wake;
        check(f.native_dynamic()==dynamic,"post-Follow stage-loss fixture has the wrong motion state before cleanup");
        const auto writes=f.calls.size();clear_reuse_handoff(f.slot());
        f.later();const auto failed=f.poll();
        // park() clears force and torque only for a dynamic allocation. Earlier
        // activation stages still use its five-leaf already-parked cleanup path.
        std::vector<ReactivationCall> cleanup{ReactivationCall::categories,ReactivationCall::collisions};
        if(dynamic) { cleanup.push_back(ReactivationCall::clear_force);cleanup.push_back(ReactivationCall::clear_torque); }
        cleanup.push_back(ReactivationCall::linear);cleanup.push_back(ReactivationCall::angular);cleanup.push_back(ReactivationCall::park_motion);
        const bool cleanup_only=f.calls.size()==writes+cleanup.size() &&
            std::equal(cleanup.begin(),cleanup.end(),f.calls.data()+writes);
        check(failed.first_failure==br::Check::dependency && failed.failure_phase==br::Phase::activation &&
            failed.phase==br::Phase::await_repark && failed.cleanup_owed && cleanup_only &&
            f.slot().reuse_faulted && !f.slot().never_held,"lost completion provenance reached another activation writer or dropped cleanup");
        const auto out=reactivation_finish(f);
        check(out.status!=br::Status::observed && out.first_failure==failed.first_failure && out.cleanup==br::Cleanup::confirmed &&
            !out.cleanup_owed && !out.native_retirement_known && !f.native_dynamic() && f.slot().retained && !f.slot().active &&
            f.calls.size()==writes+cleanup.size(),
            "post-Follow provenance loss erased its failure, repeated writes or prevented exact retained repark cleanup");
        f.no_extra_authority();
    }
}
void post_follow_reactivation_lost_handoff_cannot_publish_dynamic_success() {
    PostFollowReactivationFixture f;check(f.begin().empty() && f.sequence,"post-Follow dynamic-loss admission failed");
    reactivation_until(f,br::Phase::await_dynamic);
    check(f.native_dynamic() && reactivation_call_count(f,ReactivationCall::dynamic_motion)==1 &&
        reactivation_call_count(f,ReactivationCall::wake)==1,"post-Follow loss test never reached its dynamic observation fence");
    clear_reuse_handoff(f.slot());f.later();const auto failed=f.poll();
    check(failed.first_failure!=br::Check::none && failed.cleanup_owed && failed.status!=br::Status::observed &&
        f.slot().reuse_faulted && !f.slot().never_held,"lost post-Follow provenance was accepted as dynamic success");
    const auto out=reactivation_finish(f);
    for(std::size_t i=0;i<out.record_count;++i)
        check(out.records[i].stage!=br::Stage::dynamic_observed || !out.records[i].passed,
            "post-Follow observation published passing dynamic evidence after its handoff was lost");
    check(out.status!=br::Status::observed && out.first_failure==failed.first_failure && out.cleanup==br::Cleanup::confirmed &&
        !out.cleanup_owed && !f.native_dynamic() && !out.native_retirement_known &&
        reactivation_call_count(f,ReactivationCall::dynamic_motion)==1 && reactivation_call_count(f,ReactivationCall::wake)==1,
        "post-Follow dynamic provenance loss repeated activation, lost its failure or dropped explicit repark cleanup");
    f.no_extra_authority();
}
void post_follow_reactivation_owns_cleanup_before_first_setter() {
    PostFollowReactivationFixture f;bool witnessed{};
    f.interleave=[&](ReactivationCall call){
        if(call==ReactivationCall::transform)witnessed=reactivation_probe.result.cleanup_owed &&
            f.slot().retained && !f.slot().active && !f.slot().never_held;
    };
    f.fail_at=1;f.fail_after_write=true;
    check(f.begin().empty() && f.sequence && f.calls.empty(),"post-Follow first-setter fault admission failed");
    f.later();const auto failed=f.poll();
    check(witnessed && failed.first_failure==br::Check::transform && failed.cleanup_owed &&
        reactivation_call_count(f,ReactivationCall::dynamic_motion)==0,"first post-Follow setter ran without durable cleanup duty");
    const auto out=reactivation_finish(f);
    check(out.status!=br::Status::observed && out.first_failure==br::Check::transform && out.cleanup==br::Cleanup::confirmed &&
        !out.cleanup_owed && !f.native_dynamic() && !f.slot().never_held && f.slot().mailbox.failed,
        "partial first post-Follow writer escaped explicit cleanup or reset retained history");
    f.no_extra_authority();
}
#endif
