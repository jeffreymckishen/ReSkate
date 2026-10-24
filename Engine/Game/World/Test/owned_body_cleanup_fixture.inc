// Pure mailbox contract cases. No native park is established by these epochs.
void parked_cleanup_preserves_applied_and_absent_successor() {
    Mailbox box; const auto c = request(); Command out;
    check(box.submit(c,c.epoch,0,9007199254740994ULL) && box.consume(next(c.epoch),1,out) && box.finish(true,true,true),
        "cleanup applied fixture failed");
    const auto original=box.oldest(); box.cancel();
    check(!box.acknowledge(original.sequence),"cancel invented applied successor eligibility");
    const auto floor=next(c.epoch), parked=next(floor);
    check(box.seal_parked_without_successor(floor,parked),"qualified stopped mailbox refused cleanup seal");
    const auto sealed=box.oldest();
    check(sealed.outcome==Outcome::applied && sealed.requested==original.requested && sealed.produced==original.produced &&
        sealed.force_attempted && sealed.torque_attempted && !sealed.successor_available &&
        sealed.cleanup_disposition==CleanupDisposition::parked_without_successor,"cleanup rewrote original result or invented successor");
    Sample future; future.epoch=next(parked);
    check(!box.needs_successor() && !box.observe_successor(future) && !box.oldest().successor_available,"cleanup history reopened as a new sample");
    check(!box.acknowledge(original.sequence+1) && box.acknowledge(original.sequence) && !box.acknowledge(original.sequence),
        "exact cleanup ACK or once-only retirement failed");
    auto later=c;later.epoch=next(parked);++later.impulse_id;
    check(!box.submit(later,later.epoch,3),"cleanup ACK reopened stopped command authority");
}
void cleanup_seal_refuses_inflight_domains_and_partial_ring_commit() {
    const auto c=request(); Command out; Mailbox applied;
    check(applied.submit(c,c.epoch,0) && applied.consume(next(c.epoch),1,out) && applied.finish(true,true,true),"negative cleanup fixture failed");
    auto floor=next(c.epoch),parked=next(floor);
    check(!applied.seal_parked_without_successor(floor,parked),"active mailbox accepted cleanup seal");
    applied.cancel();
    for(unsigned fault=0;fault<8;++fault) {
        auto box=applied;auto f=floor,p=parked;
        if(fault==0)box.pending=true;if(fault==1)box.producing=true;if(fault==2)++f.world;
        if(fault==3)++p.body;if(fault==4)p.serial=f.serial;if(fault==5)p.time=f.time;
        if(fault==6)box.receipts[0].produced.serial=f.serial+1;
        if(fault==7)box.receipts[0].torque_attempted=false;
        check(!box.seal_parked_without_successor(f,p) && box.oldest().cleanup_disposition==CleanupDisposition::none,
            "unqualified/inflight/domain mismatch sealed a force record");
    }
    auto box=applied;box.count=2;box.receipts[1]=box.receipts[0];box.receipts[1].sequence=2;box.sequence=2;
    ++box.receipts[1].requested.body;
    check(!box.seal_parked_without_successor(floor,parked) && box.receipts[0].cleanup_disposition==CleanupDisposition::none &&
        box.receipts[1].cleanup_disposition==CleanupDisposition::none,"failed later ring row left a partial seal");
    Mailbox partial;check(partial.submit(c,c.epoch,0) && partial.consume(next(c.epoch),1,out) && partial.finish(true,false,false),"partial seed failed");
    check(partial.seal_parked_without_successor(floor,parked) && partial.oldest().outcome==Outcome::partial &&
        partial.oldest().cleanup_disposition==CleanupDisposition::none,"cleanup relabelled a partial result");
}
void cleanup_seal_rejects_every_malformed_occupied_row_atomically() {
    Mailbox valid;auto c=request();Command out;
    check(valid.submit(c,c.epoch,0,10)&&valid.consume(next(c.epoch),1,out)&&valid.finish(true,true,true),"first occupied input failed");
    c.epoch=next(c.epoch);++c.impulse_id;
    check(valid.submit(c,c.epoch,2,20)&&valid.consume(next(c.epoch),3,out)&&valid.finish(true,true,true),"second occupied input failed");
    valid.cancel();const auto floor=next(c.epoch),observed=next(floor);
    for(unsigned fault=0;fault<42;++fault){
        auto box=valid;auto& row=box.receipts[1];
        if(fault==0)row={}; // Exact reported default/count corruption witness.
        if(fault==1)row.outcome=Outcome::none;
        if(fault==2)row.outcome=static_cast<Outcome>(255);
        if(fault==3)row.outcome=Outcome::queued;
        if(fault==4)row.sequence=0;
        if(fault==5)row.sequence=10;
        if(fault==6)row.sequence=21;
        if(fault==7)++row.requested.world;
        if(fault==8)++row.requested.body;
        if(fault==9)row.requested.serial=0;
        if(fault==10)row.requested.serial=std::numeric_limits<std::uint64_t>::max();
        if(fault==11)row.requested.serial=valid.receipts[0].requested.serial;
        if(fault==12)row.requested.time=std::numeric_limits<double>::quiet_NaN();
        if(fault==13)row.requested.time=valid.receipts[0].requested.time;
        if(fault==14)row.requested.seconds*=2;
        if(fault==15)row.produced={};
        if(fault==16)++row.produced.world;
        if(fault==17)++row.produced.body;
        if(fault==18)++row.produced.serial;
        if(fault==19)row.produced.time+=row.produced.seconds;
        if(fault==20)row.produced.seconds*=2;
        if(fault==21)row.force_attempted=false;
        if(fault==22){row.outcome=Outcome::partial;row.force_attempted=row.torque_attempted=false;}
        if(fault==23)row.outcome=Outcome::rejected;
        if(fault==24){row.outcome=Outcome::expired;row.force_attempted=row.torque_attempted=false;}
        if(fault==25)row.cleanup_disposition=static_cast<CleanupDisposition>(255);
        if(fault==26){row.outcome=Outcome::partial;row.cleanup_disposition=CleanupDisposition::parked_without_successor;}
        if(fault==27){row.successor_available=true;row.cleanup_disposition=CleanupDisposition::parked_without_successor;}
        if(fault>=28&&fault<=33){
            row.successor_available=true;row.successor.epoch=next(floor);
            if(fault==28)row.successor.epoch={};
            if(fault==29)++row.successor.epoch.world;
            if(fault==30)++row.successor.epoch.body;
            if(fault==31)row.successor.epoch.serial=row.produced.serial;
            if(fault==32)row.successor.epoch.time=row.produced.time;
            if(fault==33)row.successor.epoch.seconds*=2;
        }
        if(fault==34)row.requested.serial=floor.serial+1;
        if(fault==35)row.requested.time=floor.time+floor.seconds;
        if(fault==36){row.outcome=Outcome::partial;row.produced={};}
        if(fault==37){row.outcome=Outcome::expired;row.produced={};row.force_attempted=row.torque_attempted=false;row.successor_available=true;}
        if(fault==38){row.outcome=Outcome::rejected;row.produced={};row.force_attempted=row.torque_attempted=false;row.cleanup_disposition=CleanupDisposition::parked_without_successor;}
        if(fault==39){row.outcome=static_cast<Outcome>(255);row.cleanup_disposition=CleanupDisposition::parked_without_successor;}
        if(fault==40)row.sequence=9;
        if(fault==41){row.successor_available=true;row.successor.epoch=next(floor);row.successor.epoch.time=std::numeric_limits<double>::quiet_NaN();}
        const auto original_cleanup=row.cleanup_disposition;
        check(!box.seal_parked_without_successor(floor,observed)&&
            box.receipts[0].cleanup_disposition==CleanupDisposition::none&&row.cleanup_disposition==original_cleanup,
            "malformed occupied row permitted a marker or left a partial ring mutation");
    }
    for(unsigned fault=0;fault<2;++fault){
        auto box=valid;if(fault==0)box.head=receipt_capacity;else box.count=receipt_capacity+1;
        check(!box.seal_parked_without_successor(floor,observed)&&box.receipts[0].cleanup_disposition==CleanupDisposition::none,
            "malformed bounded ring indexes permitted a marker");
    }
}
void cleanup_seal_preserves_api_terminal_ring_variants() {
    const auto initial=request();Command out;
    // Actual API transitions: an applied row, then a timed-out row, then a
    // pending row cancelled at stop. Global assigned sequences may have gaps.
    Mailbox mixed;auto c=initial;
    check(mixed.submit(c,c.epoch,0,10)&&mixed.consume(next(c.epoch),1,out)&&mixed.finish(true,true,true),"mixed applied seed failed");
    c.epoch=next(c.epoch);++c.impulse_id;
    check(mixed.submit(c,c.epoch,2,20)&&!mixed.consume(next(c.epoch),102,out),"mixed expiry seed failed");
    c.epoch=next(c.epoch);++c.impulse_id;
    check(mixed.submit(c,c.epoch,103,30),"mixed cancelled seed failed");mixed.cancel();
    const auto floor=next(c.epoch),observed=next(floor);
    check(mixed.seal_parked_without_successor(floor,observed)&&mixed.receipts[0].cleanup_disposition==CleanupDisposition::parked_without_successor&&
        mixed.receipts[1].outcome==Outcome::expired&&mixed.receipts[1].cleanup_disposition==CleanupDisposition::none&&
        mixed.receipts[2].outcome==Outcome::rejected&&mixed.receipts[2].produced==Epoch{}&&mixed.receipts[2].cleanup_disposition==CleanupDisposition::none,
        "legitimate mixed terminal ring changed its outcomes or lost cleanup eligibility");
    check(mixed.acknowledge(10)&&mixed.acknowledge(20)&&mixed.acknowledge(30)&&
        mixed.seal_parked_without_successor(floor,observed),"FIFO/empty stopped ring no longer validates");
    // A consumed packet can reject before either setter or partially attempt
    // either/both setters. These records are terminal, but never relabelled.
    for(unsigned attempts=0;attempts<4;++attempts){
        Mailbox box;check(box.submit(initial,initial.epoch,0)&&box.consume(next(initial.epoch),1,out)&&
            box.finish((attempts&1)!=0,(attempts&2)!=0,false),"consumed terminal seed failed");
        const auto f=next(initial.epoch);const auto original=box.oldest();
        check(box.seal_parked_without_successor(f,next(f))&&box.oldest().outcome==original.outcome&&
            box.oldest().produced==original.produced&&box.oldest().cleanup_disposition==CleanupDisposition::none&&box.acknowledge(1),
            "consumed rejected/partial metadata was refused or relabelled");
    }
    // Preserve a real already-attached successor exactly as accepted by the
    // mailbox observation API; cleanup does not replace it or mint a marker.
    Mailbox sampled;check(sampled.submit(initial,initial.epoch,0)&&sampled.consume(next(initial.epoch),1,out)&&sampled.finish(true,true,true),"sampled seed failed");
    Sample sample;sample.epoch=next(next(initial.epoch));check(sampled.observe_successor(sample),"real successor seed failed");sampled.cancel();
    check(sampled.seal_parked_without_successor(sample.epoch,next(sample.epoch))&&sampled.oldest().successor_available&&
        sampled.oldest().successor.epoch==sample.epoch&&sampled.oldest().cleanup_disposition==CleanupDisposition::none&&sampled.acknowledge(1),
        "already observed applied result lost its original ACK contract");
    for(unsigned mode=0;mode<3;++mode){
        Mailbox box;check(box.submit(initial,initial.epoch,0),"unproduced terminal seed failed");
        if(mode==0)box.cancel();
        if(mode==1){auto wrong=next(initial.epoch);++wrong.world;check(!box.consume(wrong,1,out),"wrong-world input was consumed");box.cancel();}
        if(mode==2){check(!box.consume(next(next(initial.epoch)),1,out),"skipped input was consumed");box.cancel();}
        const auto f=next(next(initial.epoch));
        check(box.seal_parked_without_successor(f,next(f))&&box.oldest().produced==Epoch{}&&
            box.oldest().cleanup_disposition==CleanupDisposition::none&&box.acknowledge(1),"legitimate zero-producer rejection/expiry was refused");
    }
    Mailbox wrapped;check(wrapped.submit(initial,initial.epoch,0)&&wrapped.consume(next(initial.epoch),1,out)&&wrapped.finish(true,true,true),"wrapped seed failed");
    check(wrapped.observe_successor(sample)&&wrapped.acknowledge(1),"wrapped head seed failed");
    c=initial;c.epoch=sample.epoch;++c.impulse_id;
    check(wrapped.submit(c,c.epoch,2,20)&&wrapped.consume(next(c.epoch),3,out)&&wrapped.finish(true,true,true),"wrapped second seed failed");wrapped.cancel();
    const auto f=next(c.epoch);check(wrapped.head==1&&wrapped.seal_parked_without_successor(f,next(f))&&wrapped.acknowledge(20),"valid nonzero ring head was refused");
    Mailbox maximum;check(maximum.submit(initial,initial.epoch,0,std::numeric_limits<std::uint64_t>::max())&&
        maximum.consume(next(initial.epoch),1,out)&&maximum.finish(true,true,true),"maximum sequence seed failed");maximum.cancel();
    const auto end=next(initial.epoch);
    check(maximum.seal_parked_without_successor(end,next(end))&&maximum.acknowledge(std::numeric_limits<std::uint64_t>::max()),
        "valid final global sequence was refused");
}
