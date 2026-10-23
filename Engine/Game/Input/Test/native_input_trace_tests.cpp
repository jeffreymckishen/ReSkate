#include "Engine/Game/Input/native_input_trace.h"
#include <cstdlib>
#include <iostream>
#include <limits>
#include <type_traits>

namespace t = dingosdk::input_trace;
namespace {
unsigned checks{};
void check(bool value, const char* why) {
    ++checks;
    if (!value) { std::cerr << "native input trace: " << why << '\n'; std::exit(1); }
}
t::Observation observation(std::uint64_t now, std::uint32_t asset = 1, bool condition = false,
                           t::Lane lane = t::Lane::interpreter) {
    return {now,17,lane,asset,true,condition,true,true,true,0};
}
t::Handle start(t::Ledger& ledger, std::uint64_t owner, std::uint64_t now) {
    t::Handle handle; t::Reason reason{};
    check(ledger.start(owner,now,handle,reason) && handle.sequence && reason == t::Reason::none, "valid trace starts");
    return handle;
}
t::Receipt read(t::Ledger& ledger, std::uint64_t owner, t::Handle handle, std::uint64_t now) {
    t::Receipt receipt;
    check(ledger.read(owner,handle,now,receipt), "owner reads retained trace");
    check(receipt.seen == receipt.record_count + receipt.duplicates + receipt.dropped, "every counted observation is stored, duplicate or explicitly dropped");
    return receipt;
}
void owners_and_retained_capacity_are_independent() {
    t::Ledger ledger; t::Handle ignored{99}; t::Reason reason{};
    check(!ledger.start(0,0,ignored,reason) && !ignored.sequence && reason == t::Reason::invalid_owner, "zero owner refuses without authority");
    const auto first = start(ledger,1,0);
    check(!ledger.start(1,0,ignored,reason) && reason == t::Reason::busy, "one active ticket per VM");
    t::Receipt output;
    check(!ledger.read(2,first,0,output) && !ledger.stop(2,first,0) && !ledger.acknowledge(2,first,0), "foreign VM cannot inspect or change a trace");
    check(!ledger.acknowledge(1,first,0), "active trace cannot be acknowledged");
    std::array<t::Handle,8> handles{}; handles[0]=first;
    for (std::uint64_t owner=2; owner<=8; ++owner) handles[static_cast<std::size_t>(owner-1)]=start(ledger,owner,0);
    check(!ledger.start(9,0,ignored,reason) && reason == t::Reason::capacity, "eight retained tickets enforce backpressure");
    check(ledger.begin(0).count == 8, "snapshot includes each active owner once");
    check(ledger.stop(1,first,1) && !ledger.stop(1,first,1), "stop has one active-to-stopped transition");
    check(!ledger.start(9,1,ignored,reason) && reason == t::Reason::capacity, "stopping retains capacity until explicit acknowledgement");
    check(ledger.acknowledge(1,first,1) && !ledger.acknowledge(1,first,1), "only one acknowledgement frees a retained slot");
    const auto replacement=start(ledger,9,1);
    check(replacement.sequence>handles.back().sequence, "reused slot never reuses its previous sequence");
    const auto clean=read(ledger,9,replacement,1);
    check(!clean.record_count && !clean.records[0].asset_token && !clean.observer_busy_at_start && !clean.observer_busy_total,
        "new trace inherits neither records/tokens nor adapter counter baselines");
}
void dedup_preserves_per_asset_lane_transitions() {
    t::Ledger ledger; const auto h=start(ledger,1,0);
    const auto append=[&](t::Observation row) { return ledger.finish(ledger.begin(row.observed_ms),row,row.observed_ms); };
    check(append(observation(1,1,false))==1 && append(observation(2,2,false))==1, "different assets retain distinct observations");
    auto duplicate=observation(3,1,false); duplicate.thread_id=99;
    check(append(duplicate)==0, "time and thread do not split a stable key even with another asset interleaved");
    check(append(observation(4,1,true))==1 && append(observation(5,1,false))==1, "false-true-false retains the return transition");
    check(append(observation(6,1,false,t::Lane::alternate))==1, "same token on another lane has independent history");
    auto row=observation(7,1,false); row.condition_known=false;
    check(append(row)==1, "unknown condition is not known false");
    row.observed_ms=8; row.local_tuple_known=false; check(append(row)==1, "unknown local tuple changes qualification");
    row.observed_ms=9; row.container_matches_local=false; check(append(row)==1, "container equality changes qualification");
    row.observed_ms=10; row.snapshot_stable=false; check(append(row)==1, "snapshot instability changes qualification");
    row.observed_ms=11; row.issue=7; check(append(row)==1, "typed issue participates in dedup");
    row.observed_ms=12; row.thread_id=123; check(append(row)==0, "same final qualification tuple counts duplicate");
    auto result=read(ledger,1,h,12);
    check(result.seen==12 && result.duplicates==2 && result.record_count==10 && !result.dropped, "dedup counts observations rather than pretending a gap-free stream");
    check(result.records[0].observed_ms==1 && result.records[0].thread_id==17 && result.records[9].issue==7, "stored rows preserve their original timing and condition witness");
    result.records[0].asset_token=999; result.seen=0;
    const auto actual=read(ledger,1,h,12);
    check(actual.records[0].asset_token==1 && actual.seen==12, "mutating a read copy cannot change ledger records");
}
void stop_and_expiry_refuse_inflight_appends() {
    t::Ledger ledger; const auto h=start(ledger,1,100);
    const auto before=ledger.begin(101);
    check(ledger.stop(1,h,102), "stop succeeds before callback returns");
    check(ledger.finish(before,observation(103),103)==0, "snapshot begun before stop cannot append after stop");
    const auto stopped=read(ledger,1,h,103);
    check(stopped.status==t::Status::stopped && !stopped.seen && !stopped.dropped && !stopped.record_count,
        "late stopped observation cannot mutate any terminal receipt counter");
    check(ledger.acknowledge(1,h,103), "stopped ticket can be acknowledged");
    const auto next=start(ledger,1,104);
    check(ledger.finish(before,observation(105),105)==0, "ack and slot reuse do not revive the old callback ticket");
    check(read(ledger,1,next,105).seen==0, "old callback does not even charge the next trace's counters");

    t::Ledger expiring; const auto e=start(expiring,7,500);
    const auto pending=expiring.begin(5499);
    check(read(expiring,7,e,5499).status==t::Status::active, "trace remains active strictly before five seconds");
    check(expiring.finish(pending,observation(5500),5500)==0, "exact deadline refuses in-flight append");
    const auto expired=read(expiring,7,e,5500);
    check(expired.status==t::Status::expired && !expired.seen && !expired.dropped && expired.expires_ms==5500, "expiry is inclusive and freezes the bounded historical window");
    check(expiring.begin(5500).count==0 && !expiring.stop(7,e,5500), "expired ticket cannot enter another snapshot or be relabelled stopped");
    check(expiring.acknowledge(7,e,5500), "expired receipt can be released explicitly");
}
void release_and_newstart_cannot_transfer_callbacks() {
    t::Ledger ledger; const auto a=start(ledger,1,0); const auto b=start(ledger,2,0);
    const auto snapshot=ledger.begin(1);
    ledger.release_all(1); const auto replacement=start(ledger,1,2);
    check(replacement.sequence!=a.sequence && ledger.finish(snapshot,observation(3),3)==1, "released owner is excluded while the original other owner receives its row");
    check(read(ledger,1,replacement,3).record_count==0 && read(ledger,2,b,3).record_count==1, "native callback snapshot cannot subscribe an owner who started later");
    t::Receipt gone;
    check(!ledger.read(1,a,3,gone), "released handle is unavailable");
    ledger.release_all(0); check(read(ledger,2,b,3).record_count==1, "zero owner release does not affect anyone");
    ledger.release_all(2); check(!ledger.read(2,b,3,gone), "owner unload removes its retained trace");
    const auto empty=ledger.begin(4); ledger.release_all(1); const auto later=start(ledger,3,5);
    check(ledger.finish(empty,observation(6),6)==0 && read(ledger,3,later,6).seen==0, "empty/pre-existing snapshot grants no future subscriber authority");
}
void record_cap_and_duplicate_accounting_are_bounded() {
    t::Ledger ledger; const auto h=start(ledger,1,0);
    for (std::uint32_t i=0;i<128;++i) {
        auto row=observation(i+1); row.issue=static_cast<std::uint8_t>(i);
        check(ledger.finish(ledger.begin(i+1),row,i+1)==1, "each changed issue fills one bounded row");
    }
    for (std::uint32_t i=128;i<131;++i) {
        auto row=observation(i+1); row.issue=static_cast<std::uint8_t>(i);
        check(ledger.finish(ledger.begin(i+1),row,i+1)==0, "full buffer never appends or overwrites");
    }
    auto stable=observation(132); stable.issue=127; stable.thread_id=66;
    check(ledger.finish(ledger.begin(132),stable,132)==0, "full buffer still recognizes stable duplicates");
    const auto result=read(ledger,1,h,132);
    check(result.record_count==128 && result.dropped==3 && result.duplicates==1 && result.seen==132,
        "cap drops and duplicate observations stay distinct");
    check(result.status==t::Status::active && result.records.front().issue==0 && result.records.back().issue==127,
        "record cap retains first bounded history while the five-second ticket remains active");
}
void malformed_clocks_and_snapshots_fail_closed() {
    t::Ledger ledger; const auto h=start(ledger,1,100); const auto snapshot=ledger.begin(101);
    auto row=observation(102);
    check(ledger.finish(snapshot,row,100)==0, "backward finish clock cannot append");
    row.observed_ms=100; check(ledger.finish(snapshot,row,102)==0, "pre-entry timestamp cannot be relabelled as post-call observation");
    row.observed_ms=104; check(ledger.finish(snapshot,row,103)==0, "future observation time cannot append");
    row.observed_ms=104; row.lane=static_cast<t::Lane>(255);
    check(ledger.finish(snapshot,row,104)==0, "unknown lane is dropped");
    const auto result=read(ledger,1,h,104);
    check(result.seen==4 && result.dropped==4 && !result.record_count, "malformed observations disclose drops without rows");
    t::Receipt output;
    check(!ledger.read(1,h,103,output) && !output.handle.sequence, "backward read refuses and clears caller output");
    auto invalid=snapshot; invalid.count=9;
    check(ledger.finish(invalid,observation(105),105)==0 && read(ledger,1,h,105).seen==4, "out-of-range snapshot count is not traversed");
    auto repeated=ledger.begin(106); repeated.tickets[1]=repeated.tickets[0]; repeated.count=2;
    check(ledger.finish(repeated,observation(106),106)==1 && read(ledger,1,h,106).seen==5, "repeated snapshot ticket cannot double-charge or publish twice");
}
void nonreused_sequences_and_retained_orphans_have_bounds() {
    t::Ledger ledger; std::array<t::Handle,8> handles{};
    for (std::size_t i=0;i<handles.size();++i) {
        handles[i]=start(ledger,1,static_cast<std::uint64_t>(i));
        check(ledger.stop(1,handles[i],static_cast<std::uint64_t>(i)), "one VM can retain a stopped receipt before starting another");
    }
    t::Handle handle; t::Reason reason{};
    check(!ledger.start(1,8,handle,reason) && reason==t::Reason::capacity, "eight terminal receipts still enforce backpressure");
    ledger.release_all(1); handle=start(ledger,1,9);
    check(handle.sequence>handles.back().sequence && !read(ledger,1,handle,9).record_count, "VM release frees all its orphan slots without reusing authority");
    const auto max=std::numeric_limits<std::uint64_t>::max();
    t::Ledger exhausted(max-1); const auto final=start(exhausted,1,0);
    check(final.sequence==max && exhausted.stop(1,final,0) && exhausted.acknowledge(1,final,0), "last uint64 sequence remains exact and retireable");
    check(!exhausted.start(1,1,handle,reason) && !handle.sequence && reason==t::Reason::sequence_exhausted, "sequence exhaustion never wraps to a reusable handle");
    t::Ledger overflow;
    check(!overflow.start(1,max-t::duration_ms+1,handle,reason) && reason==t::Reason::clock_invalid, "expiry addition cannot overflow");
    check(start(overflow,1,0).sequence==1, "rejected overflow cannot poison the initial valid clock or sequence");
}
}
static_assert(std::is_trivially_copyable_v<t::Observation> && std::is_trivially_copyable_v<t::Snapshot>);
static_assert(sizeof(t::Receipt) <= 8192 && sizeof(t::Ledger) <= 65536 && sizeof(t::Snapshot) <= 256,
    "Fixed eight-ticket/128-record trace must stay within its bounded memory budget");
int main() {
    owners_and_retained_capacity_are_independent();
    dedup_preserves_per_asset_lane_transitions();
    stop_and_expiry_refuse_inflight_appends();
    release_and_newstart_cannot_transfer_callbacks();
    record_cap_and_duplicate_accounting_are_bounded();
    malformed_clocks_and_snapshots_fail_closed();
    nonreused_sequences_and_retained_orphans_have_bounds();
    std::cout << "native input trace ledger: " << checks << " checks passed\n";
}
