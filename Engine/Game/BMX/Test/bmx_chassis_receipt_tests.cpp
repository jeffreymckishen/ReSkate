#include "Engine/Game/BMX/bmx_chassis_receipt.h"
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <limits>

namespace r=dingosdk::bmx::chassis_receipt;
unsigned checks{};
void check(bool okay,const char* name){++checks;if(!okay){std::fprintf(stderr,"FAIL %s\n",name);std::exit(1);}}
r::Queued queued(bool hop=false){return {7,400,1200,3,8.25,.01666666567325592,hop};}
r::Observed successor(const r::Queued& q){return {q.token,q.serial+1,q.applications_before+1,q.serial,
    q.hop_events_before+std::uint64_t{q.hop},q.time+q.seconds,q.seconds,false};}
int main(){
    for(const bool hop:{false,true}) {
        const auto q=queued(hop);const auto after=successor(q);
        check(r::valid(q)&&r::confirm(q,after)==r::Result::confirmed,"one complete application at the exact next body confirms the lease");
        auto before=after;before.serial=q.serial;before.time=q.time;before.applications=q.applications_before;
        before.hop_events=q.hop_events_before;before.last_applied_serial=q.serial-1;
        check(r::confirm(q,before)==r::Result::waiting,"same native body waits while lease has not executed");
        before=after;before.serial=q.serial;before.time=q.time;
        check(r::confirm(q,before)==r::Result::waiting,"completed producer on the same native body cannot advance the controller");
        before.producer_failed=true;
        check(r::confirm(q,before)==r::Result::producer_failed,"partial producer failure does not hide behind a duplicate body");
        auto skipped=after;skipped.applications=q.applications_before;skipped.last_applied_serial=q.serial-1;
        skipped.hop_events=q.hop_events_before;
        check(r::confirm(q,skipped)==r::Result::application_unconfirmed,"dropped or expired lease cannot feed predicted rotors to the next solve");
        auto partial=after;partial.producer_failed=true;
        check(r::confirm(q,partial)==r::Result::producer_failed,"producer last_serial set before partial failure is not a complete application");
        auto unrelated=after;unrelated.last_applied_serial=q.serial-1;
        check(r::confirm(q,unrelated)==r::Result::application_unconfirmed,"an old successful command cannot confirm this queue");
        unrelated=after;unrelated.applications++;
        check(r::confirm(q,unrelated)==r::Result::application_unconfirmed,"extra application cannot be mistaken for exactly one step");
        auto wrong_hop=after;wrong_hop.hop_events=hop?q.hop_events_before:q.hop_events_before+1;
        check(r::confirm(q,wrong_hop)==r::Result::hop_unconfirmed,"native hop counter must agree with the queued hop");
        auto owner=after;owner.token++;
        check(r::confirm(q,owner)==r::Result::token_changed,"a replacement mount cannot acknowledge the prior lease");
        auto skipped_body=after;skipped_body.serial++;skipped_body.time+=q.seconds;
        check(r::confirm(q,skipped_body)==r::Result::clock_discontinuity,"a missed native body does not fabricate a consecutive receipt");
        auto wrong_clock=after;wrong_clock.time+=1e-5;
        check(r::confirm(q,wrong_clock)==r::Result::clock_discontinuity,"serial without matching native time cannot confirm");
        wrong_clock=after;wrong_clock.seconds*=2;
        check(r::confirm(q,wrong_clock)==r::Result::clock_discontinuity,"changed native timestep cannot confirm");
    }
    auto q=queued();q.applications_before=std::numeric_limits<std::uint64_t>::max();
    check(!r::valid(q),"application counter exhaustion is rejected before queueing native work");
    q=queued(true);q.hop_events_before=std::numeric_limits<std::uint64_t>::max();
    check(!r::valid(q),"hop counter exhaustion is rejected before queueing a hop");
    q=queued();q.serial=std::numeric_limits<std::uint64_t>::max();
    check(!r::valid(q),"serial exhaustion cannot wrap a receipt into an old body");
    q=queued();q.time=std::numeric_limits<double>::quiet_NaN();
    check(!r::valid(q),"invalid native time cannot create a receipt");
    const auto fresh=queued();auto invalid=successor(fresh);invalid.time=std::numeric_limits<double>::infinity();
    check(r::confirm(fresh,invalid)==r::Result::invalid_epoch,"invalid current time cannot acknowledge native work");
    std::printf("chassis command receipt: %u checks PASS\n",checks);
}
