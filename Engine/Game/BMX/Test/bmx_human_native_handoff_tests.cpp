#include "Engine/Game/BMX/bmx_human_native_handoff.h"
#include <cstdlib>
#include <iostream>
#include <limits>
namespace h=dingosdk::bmx::human_native_handoff;
namespace n=dingosdk::bmx::native_input_handoff;
namespace b=dingosdk::input::native_board_bridge;
unsigned checks{};
void check(bool ok,const char* why){++checks;if(!ok){std::cerr<<"FAIL: "<<why<<'\n';std::exit(1);}}
n::Ticket ticket(){return {{1,2,3,4,5,6},{7,8,9,10,11},{20,21,22,23,24,1,1},16000,10,1.0};}
b::Pad chord(){b::Pad p;p.buttons=0x8100;return p;}
h::Guard guard(unsigned slot=0,std::uint64_t now=1032){return {now,now,ticket().owner,1u<<slot,true,true,true};}
n::Sample sample(std::uint64_t now=1032,std::uint64_t serial=12,double time=1.032){
    n::Sample s;s.now=s.sampled_ms=now;s.serial=serial;s.native_time=time;s.owner=ticket().owner;s.body=ticket().body;s.counters=ticket().counters;s.physics=504;
    s.configuration=s.gates=s.canonical=s.clock_coherent=s.pool_released=s.sdk_idle=s.motion_released=s.publication_inactive=s.parts_zero=s.capture_released=true;
    s.sdk_quiet=s.gesture_released=s.offboard=s.standable=s.motion_supported=true;return s;
}
void note(h::Intent& i,unsigned slot,std::uint64_t now,b::Pad p={}){i.note(true,slot,true,now,3,p);}
h::Intent admitted(unsigned slot=0){h::Intent i;note(i,slot,980);note(i,slot,1000,chord());check(i.admit(1000,1u<<slot,ticket().owner),"fresh actual original chord admitted");return i;}
h::Intent queued(unsigned slot=0){auto i=admitted(slot);check(i.transfer(ticket(),1000),"full cleanup ticket transferred");note(i,slot,1016);
    i.observe(sample(1016,11,1.016),guard(slot,1016));check(!i.pulse().used,"first advanced release sample waits");
    note(i,slot,1032);i.observe(sample(),guard(slot));check(i.pulse().live(),"second released sample queues one pulse");return i;}
void admission(){
    for(unsigned slot=0;slot<4;++slot){auto i=admitted(slot);check(i.slot()==slot,"actual slot mapping");check(i.generation()==1,"first generation");}
    for(unsigned device:{0u,3u,5u,15u,0x100u,0x424d5803u}){h::Intent i;note(i,0,980);note(i,0,1000,chord());check(!i.admit(1000,device,ticket().owner),"non-single-XInput source rejected");}
    {h::Intent i;note(i,0,1000,chord());check(!i.admit(1000,1,ticket().owner),"held-at-first-read is not a fresh chord");}
    {h::Intent i;note(i,0,980);auto p=chord();p.buttons=0x8000;note(i,0,990,p);note(i,0,1000,chord());check(!i.admit(1000,1,ticket().owner),"late LB on held North rejected");}
    {h::Intent i;i.note(false,0,true,980,3,{});i.note(false,0,true,1000,3,chord());check(!i.admit(1000,1,ticket().owner),"SDK/nested reads cannot prove source");}
    for(unsigned delta:{251u,1000u}){h::Intent i;note(i,0,980);note(i,0,1000,chord());check(!i.admit(1000+delta,1,ticket().owner),"stale actual chord rejected");}
    {h::Intent i;note(i,0,980);note(i,0,1001,chord());check(!i.admit(1000,1,ticket().owner),"future original rejected");}
    {h::Intent i;note(i,0,980);note(i,0,1000,chord());note(i,1,999);check(!i.admit(1000,1,ticket().owner),"fresh additional original slot rejected");}
    {h::Intent i;note(i,0,980);note(i,0,1000,chord());i.note(true,0,false,1001,0,{});check(!i.admit(1001,1,ticket().owner),"failed original never fabricates release/chord");}
    {auto i=admitted();i.cancel("test");check(!i.admit(1001,1,ticket().owner),"same held rise spent after cancellation");}
    {auto i=admitted(2);i.cancel("test");check(!i.admit(1001,1,ticket().owner)&&i.slot()==2&&i.generation()==1,"rejected other-slot request cannot relabel prior accepted generation");}
    {h::Intent i;note(i,0,980);auto p=chord();p.buttons|=1;note(i,0,1000,p);check(!i.admit(1000,1,ticket().owner),"D-pad during admission does not park");}
    {h::Intent i;note(i,0,980);auto p=chord();p.left_trigger=13;note(i,0,1000,p);check(!i.admit(1000,1,ticket().owner),"active trigger does not park");}
}
void release_and_context(){
    {auto i=admitted(2);check(i.transfer(ticket(),1000),"held ticket accepted");auto v=sample(1016,11,1.016);v.sdk_quiet=v.gesture_released=false;
        auto g=guard(2,1016);g.sdk_released=false;note(i,2,1016,chord());i.observe(v,g);check(i.active()&&!i.pulse().used,"held chord waits without fake quiet");
        note(i,2,1032);v=sample();v.capture_released=false;i.observe(v,guard(2));check(i.active()&&!i.pulse().used,"capture-through-release waits");
        note(i,2,1048);i.observe(sample(1048,13,1.048),guard(2,1048));check(!i.pulse().used,"first post-lease sample waits");
        note(i,2,1064);i.observe(sample(1064,14,1.064),guard(2,1064));check(i.pulse().live(),"next post-lease sample ready");}
    for(unsigned k=0;k<11;++k){auto i=admitted();auto g=guard(0,1016);g.sdk_released=false;
        switch(k){case 0:g.allowed=false;break;case 1:++g.owner[3];break;case 2:g.device=2;break;case 3:g.device=3;break;
        case 4:g.now=999;break;case 5:g.now=16000;break;case 6:g.sampled_ms=0;break;case 7:g.sampled_ms=g.now+1;break;
        case 8:g.sampled_ms=g.now-251;break;case 9:g.sdk_gesture_only=false;break;case 10:i.note(true,0,false,1016,0,{});break;}
        check(!i.guard(g)&&!i.active(),"changed context cannot defer intent");check(!i.guard(guard()),"later neutral does not retry");}
    {auto i=admitted();note(i,0,1016);note(i,0,1017,chord());check(!i.active(),"physical reentry before SDK release cancels");}
    {auto i=admitted();note(i,1,1016);check(!i.active(),"new second original device cancels");}
    {auto i=admitted();i.note(true,0,true,999,3,{});check(!i.active(),"source wall rollback cancels");}
    {auto i=admitted();auto t=ticket();++t.body.token;t.owner[1]++;check(!i.transfer(t,1001)&&!i.active(),"foreign cleanup ticket refuses with no fallback");}
    {auto i=admitted();auto t=ticket();t.deadline_ms=16002;check(!i.transfer(t,1001)&&!i.active(),"cleanup ticket cannot renew 15s");}
    {auto i=admitted();auto t=ticket();t.deadline_ms=16001;check(!i.transfer(t,1001)&&!i.active(),"one millisecond admission deadline extension rejected");}
    for(unsigned variant=0;variant<4;++variant){auto i=admitted();check(i.transfer(ticket(),1000),"held native clock ticket");
        auto s=sample(1016,20,1.20);s.sdk_quiet=s.gesture_released=false;auto g=guard(0,1016);g.sdk_released=false;
        note(i,0,1016,chord());i.observe(s,g);check(i.active(),"held coherent clock is observed");
        s=sample(1032,variant==0?19:variant==1?20:variant==2?21:19,variant==0?1.19:variant==1?1.21:variant==2?1.20:1.19);
        g=guard(0,1032);
        if(variant!=3){s.sdk_quiet=s.gesture_released=false;g.sdk_released=false;note(i,0,1032,chord());}else note(i,0,1032);
        i.observe(s,g);check(!i.active(),"held/first released native regression or unmatched serial-time pair rejected");}
}
void input_and_native(){
    for(unsigned slot=0;slot<4;++slot){auto i=queued(slot);
        auto r=i.poll(1032,slot,true,true,true,504,{});check(r.rewrite&&!r.north,"native baseline");
        r=i.poll(1052,slot,true,true,true,504,{});check(r.rewrite&&r.north,"single North rise");
        r=i.poll(1132,slot,true,true,true,504,{});check(r.rewrite&&r.north,"press hold");
        r=i.poll(1212,slot,true,true,true,504,{});check(r.rewrite&&!r.north,"genuine release offer");
        r=i.poll(1232,slot,true,true,true,504,{});check(!r.rewrite&&i.session().phase()==n::Phase::observing,"transport complete is not native success");
        auto v=sample(1700,20,1.7);v.physics=103;note(i,slot,1700);i.observe(v,guard(slot,1700));check(i.session().saw103(),"real observed native103");
        v=sample(1800,21,1.8);v.physics=100;note(i,slot,1800);i.observe(v,guard(slot,1800));check(i.active()&&i.session().saw100(),"native100 still needs dwell");
        v=sample(4051,22,4.051);v.physics=100;note(i,slot,4051);i.observe(v,guard(slot,4051));check(!i.active()&&i.session().phase()==n::Phase::complete,"native and wall dwell complete");
        const auto p=i.packet(slot,3,{},true);note(i,slot,4100);note(i,slot,4116,chord());check(i.admit(4116,1u<<slot,ticket().owner),"new real chord admits next generation");
        check(i.generation()==2&&i.packet(slot,3,{},false)==p,"request reset preserves packet domain");}
    for(unsigned k=0;k<5;++k){auto i=queued();auto p=b::Pad{};if(k==3)p.buttons=1;
        const auto r=i.poll(k==4?16000:1032,0,k!=0,k!=1,k!=2,504,p);check(!r.rewrite&&!i.active(),"callback identity focus capture activity deadline failures cancel");}
    {auto i=queued();auto r=i.poll(1032,0,true,true,true,504,{});check(r.rewrite,"first baseline");r=i.poll(1153,0,true,true,true,504,{});check(!r.rewrite&&!i.active(),"poll stall has no retry");}
    {auto i=queued();auto v=sample(1048,13,1.048);v.physics=200;note(i,0,1048);i.observe(v,guard(0,1048));check(!i.active(),"software200 route rejected");}
    for(unsigned k=0;k<17;++k){auto i=queued();auto v=sample(1048,13,1.048);note(i,0,1048);
        switch(k){case 0:v.configuration=false;break;case 1:v.gates=false;break;case 2:v.canonical=false;break;case 3:v.protected_owner=true;break;
        case 4:++v.body.generation;break;case 5:v.pool_released=false;break;case 6:++v.counters[3];break;case 7:v.clock_coherent=false;break;
        case 8:v.native_time=std::numeric_limits<double>::quiet_NaN();break;case 9:v.serial=11;break;case 10:v.sdk_idle=false;break;
        case 11:v.motion_released=false;break;case 12:v.publication_inactive=false;break;case 13:v.parts_zero=false;break;
        case 14:v.capture_released=false;break;case 15:v.sdk_quiet=false;break;case 16:v.gesture_released=false;break;}
        i.observe(v,guard(0,1048));check(!i.active(),"all cleanup and current-native proof gates retained after queue");}
}
// Successful stamp and BUSY proof are built independently of the Sample's
// aggregate gates, so contradictory producer flags are meaningful negatives.
h::ReadWitness clock_reads(const n::Sample& s,std::uint64_t observed,bool busy=false){
    h::ReadWitness r;r.present=true;r.clock_mutex_busy=busy;r.clock_observed_ms=observed;
    r.sdk_sampled_ms=s.sampled_ms;r.sdk_device=s.sdk_device;
    r.sdk_available=r.sdk_focused=r.sdk_overlay_ready=r.gameplay_ready=true;
    r.frame_available=r.frame_timing_available=true;r.frame_serial=s.serial;r.frame_time=s.native_time;
    r.canonical_read_attempted=r.canonical_read_succeeded=r.canonical_owner_evaluated=r.canonical_owner_equal=true;
    r.clock_read_attempted=true;
    if(!busy){r.clock_read_succeeded=r.clock_equality_evaluated=r.clock_equal=r.physics_read_attempted=r.physics_read_succeeded=true;
        r.clock_serial=s.serial;r.clock_time=s.native_time;}
    return r;
}
n::Sample actual_sample(unsigned slot,std::uint64_t now,std::uint64_t serial,double time,unsigned physics=504){
    auto s=sample(now,serial,time);s.sdk_device=1u<<slot;s.physics=physics;return s;
}
h::Intent delivered(unsigned slot=0,std::uint64_t observed=1248){
    auto i=queued(slot);
    for(auto now:{1032u,1052u,1132u,1212u,1232u})(void)i.poll(now,slot,true,true,true,504,{});
    check(i.pulse().phase==b::Phase::complete&&i.session().phase()==n::Phase::observing,"fixture actually delivers one complete original Pulse");
    auto s=actual_sample(slot,1248,13,1.248);note(i,slot,1248);i.observe(s,guard(slot,1248),clock_reads(s,observed));
    check(i.active(),"coherent post-delivery sample remains observing");return i;
}
void clock_busy_observation(){
    for(unsigned slot=0;slot<4;++slot){auto i=delivered(slot);auto s=actual_sample(slot,1264,14,1.264,0);s.clock_coherent=false;
        auto g=guard(slot,1264);g.allowed=false;const auto reads=clock_reads(s,0,true);
        const auto latest=i.session().latest();const auto rewrites=i.pulse().rewrites,press=i.pulse().press_reports,release=i.pulse().release_reports;
        check(i.observe_clock_busy(s,g,reads)&&i.active(),"actual selected slot BUSY permits only passive post-delivery pause");
        check(!s.clock_coherent&&!g.allowed&&s.sdk_device==(1u<<slot)&&!s.original_slot0_fresh&&!s.only_slot0,"BUSY never rewrites failed clock/Guard or normalizes actual source sample");
        check(i.session().observation_paused()&&!i.session().ready()&&!i.session().callback_snapshot_ready(1264),"BUSY explicitly invalidates callback proof and readiness");
        check(i.session().latest().serial==latest.serial&&i.session().latest().native_time==latest.native_time&&i.session().latest().now==latest.now&&
            i.session().latest().physics==latest.physics&&!i.session().saw103()&&!i.session().saw100(),"unread frame does not replace accepted sample or invent103/100");
        check(i.coherent_feed_observed_ms()==1248&&i.busy_observation().count==1&&i.busy_observation().first_wall==1264&&
            i.busy_observation().last_wall==1264&&i.busy_observation().last_coherent_feed_observed_ms==1248,"BUSY receipt retains actual last coherent feed stamp");
        check(!i.admit(1264,1u<<slot,ticket().owner)&&i.busy_observation().count==1&&i.coherent_feed_observed_ms()==1248,
            "rejected admission cannot clear another generation's BUSY evidence");
        const auto r=i.poll(1264,slot,true,true,true,504,{});
        check(!r.rewrite&&i.pulse().rewrites==rewrites&&i.pulse().press_reports==press&&i.pulse().release_reports==release,"passive BUSY cannot replay a completed Pulse");
        auto fresh=actual_sample(slot,1280,15,1.280);note(i,slot,1280);i.observe(fresh,guard(slot,1280),clock_reads(fresh,1280));
        check(i.active()&&!i.session().observation_paused()&&i.session().callback_snapshot_ready(1280),"only a fully validated coherent sample restores callback proof");
        i.cancel("fixture ended");note(i,slot,1290);note(i,slot,1300,chord());check(i.admit(1300,1u<<slot,ticket().owner),"new genuine chord admits a new generation");
        check(i.busy_observation().count==0&&i.coherent_feed_observed_ms()==0&&!i.session().current_dwell().started,"successful admission resets BUSY and current dwell receipts");
    }
    for(unsigned age:{249u,250u,251u}){auto i=delivered();const auto now=1248+age;auto s=actual_sample(0,now,14,1.4,0);s.clock_coherent=false;
        auto g=guard(0,now);g.allowed=false;note(i,0,now);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true))==(age<250),"native feed freshness is strict at250ms, never Sample.now based");
        check(i.active()==(age<250),"expired feed BUSY is terminal");}
    {auto i=delivered();for(unsigned age:{100u,200u,249u,250u}){const auto now=1248+age;auto s=actual_sample(0,now,14,1.4,0);s.clock_coherent=false;
            auto g=guard(0,now);g.allowed=false;note(i,0,now);check(i.observe_clock_busy(s,g,clock_reads(s,0,true))==(age<250),"repeated BUSY never refreshes coherent feed budget");}
        check(i.busy_observation().count==3&&i.busy_observation().first_wall==1348&&i.busy_observation().last_wall==1497&&
            i.coherent_feed_observed_ms()==1248,"only admitted pauses count; expiration does not renew or overwrite their evidence");}
    for(unsigned delta:{9u,10u}){auto i=delivered(0,1008);const auto now=1248+delta;auto s=actual_sample(0,now,14,1.3,0);s.clock_coherent=false;
        auto g=guard(0,now);g.allowed=false;note(i,0,now);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true))==(delta==9),"already240ms-old helper feed retains only its actual remaining9ms budget");}
    for(auto stamp:{std::uint64_t(0),std::uint64_t(999),std::uint64_t(1249)}){auto i=delivered(0,stamp);auto s=actual_sample(0,1264,14,1.264,0);s.clock_coherent=false;
        auto g=guard(0,1264);g.allowed=false;note(i,0,1264);
        check(!i.observe_clock_busy(s,g,clock_reads(s,0,true))&&!i.active(),"missing/stale/future successful-helper stamp cannot enable BUSY wait");}
    {auto i=delivered();auto s=actual_sample(0,1264,14,1.264,103);note(i,0,1264);i.observe(s,guard(0,1264),clock_reads(s,1264));
        s=actual_sample(0,1280,15,1.280,100);note(i,0,1280);i.observe(s,guard(0,1280),clock_reads(s,1280));
        s=actual_sample(0,2280,16,2.280,100);note(i,0,2280);i.observe(s,guard(0,2280),clock_reads(s,2280));
        check(i.session().current_dwell().started&&i.session().current_dwell().first_wall==1280,"native100 dwell is genuinely running before interruption");
        s=actual_sample(0,2300,17,2.300,0);s.clock_coherent=false;auto g=guard(0,2300);g.allowed=false;note(i,0,2300);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true)),"BUSY interrupts a partial100 dwell");
        const auto& d=i.session().current_dwell();check(!d.started&&!d.first_wall&&!d.last_wall&&!d.last_serial&&d.first_native==0&&d.last_native==0,"BUSY clears every current dwell anchor");
        check(i.first100().now==1280&&i.first103().now==1264&&i.session().saw103()&&i.session().saw100(),"historical first103/100 remain historical, no gap progress");
        for(auto now:{2316u,3550u,4567u}){s=actual_sample(0,now,now==2316?17:now==3550?18:19,double(now)/1000,100);note(i,0,now);i.observe(s,guard(0,now),clock_reads(s,now));
            check(i.active()==(now!=4567),"100 must meet full new native AND wall dwell after BUSY");}
        check(i.session().phase()==n::Phase::complete&&i.session().current_dwell().first_wall==2316&&i.first100().now==1280,"completed receipt distinguishes current dwell from old historical100");}
    for(unsigned unread_physics:{0u,103u,100u,200u}){auto i=delivered();auto s=actual_sample(0,1264,14,1.264,unread_physics);s.clock_coherent=false;auto g=guard(0,1264);g.allowed=false;note(i,0,1264);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true)),"BUSY before any103 can pause without observing physics");
        s=actual_sample(0,1280,15,1.280,100);note(i,0,1280);i.observe(s,guard(0,1280),clock_reads(s,1280));
        check(!i.active()&&!i.session().saw103()&&std::string(i.issue())=="native100_without_observed103","BUSY cannot invent a missed103 to admit100");}
    {auto i=delivered();auto s=actual_sample(0,15900,100,15.9);note(i,0,15900);i.observe(s,guard(0,15900),clock_reads(s,15900));
        check(i.active()&&i.coherent_feed_observed_ms()==15900,"deadline fixture has a genuinely fresh late native feed");
        s=actual_sample(0,15999,101,15.999,0);s.clock_coherent=false;auto g=guard(0,15999);g.allowed=false;note(i,0,15999);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true)),"fresh feed permits passive pause just before original deadline");
        s.now=s.sampled_ms=16000;g.now=g.sampled_ms=16000;note(i,0,16000);
        check(!i.observe_clock_busy(s,g,clock_reads(s,0,true))&&!i.active()&&
            std::string(i.issue())=="original_switch_deadline_or_wall_clock","still-fresh feed cannot renew original15s deadline");
        check(i.session().ticket().deadline_ms==16000&&i.busy_observation().count==1,"deadline and accepted BUSY count remain fixed");}
    {auto i=delivered();auto s=actual_sample(0,1264,14,1.264,0);s.clock_coherent=false;auto g=guard(0,1264);g.allowed=false;note(i,0,1264);
        auto reads=clock_reads(s,0,true);reads.sdk_focused=false;
        check(!i.observe_clock_busy(s,g,reads)&&!i.active(),"actual producer focus loss rejects the BUSY path");
        const auto frozen=i.first_guard_rejection();
        check(frozen.present&&frozen.origin==h::GuardOrigin::clock_busy_observer&&frozen.guard.now==1264&&
            !frozen.reads.sdk_focused&&frozen.reads.clock_mutex_busy&&frozen.offered.sample.serial==14,
            "first BUSY refusal retains actual typed read, Guard and offered sample");
        note(i,0,1280);s=actual_sample(0,1280,15,1.280);i.observe(s,guard(0,1280),clock_reads(s,1280));
        check(i.first_guard_rejection().guard.now==1264&&!i.first_guard_rejection().reads.sdk_focused&&
            i.first_guard_rejection().offered.sample.serial==14,"later calls cannot overwrite first BUSY refusal");}
    for(unsigned missing=0;missing<2;++missing){auto i=delivered();auto s=actual_sample(0,1264,14,1.264,103);note(i,0,1264);i.observe(s,guard(0,1264),clock_reads(s,1264));
        s=actual_sample(0,1280,15,1.280,100);note(i,0,1280);i.observe(s,guard(0,1280),clock_reads(s,1280));
        s=actual_sample(0,1300,16,1.300,0);s.clock_coherent=false;auto g=guard(0,1300);g.allowed=false;note(i,0,1300);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true)),"one-sided dwell fixture interrupts prior100");
        s=actual_sample(0,1320,16,1.320,100);note(i,0,1320);i.observe(s,guard(0,1320),clock_reads(s,1320));
        const auto now=missing==0?3600u:1400u;const auto native_time=missing==0?1.5:3.6;
        s=actual_sample(0,now,17,native_time,100);note(i,0,now);i.observe(s,guard(0,now),clock_reads(s,now));
        check(i.active()&&i.session().phase()==n::Phase::observing,"neither wall duration alone nor native duration alone can finish restarted dwell");}
    // Every phase before complete delivery remains fail-closed, including
    // cleanup_wait, queued waiting, baseline, press, and release.
    for(unsigned phase=0;phase<7;++phase){auto i=phase==0?admitted():phase==1?admitted():queued();
        if(phase==1)check(i.transfer(ticket(),1000),"cleanup-only phase fixture");
        if(phase>=3)(void)i.poll(1032,0,true,true,true,504,{});
        if(phase>=4)(void)i.poll(1052,0,true,true,true,504,{});
        if(phase>=5){(void)i.poll(1132,0,true,true,true,504,{});(void)i.poll(1212,0,true,true,true,504,{});}
        if(phase==6)i.cancel("fixture terminal");
        auto s=actual_sample(0,1220,13,1.220,0);s.clock_coherent=false;auto g=guard(0,1220);g.allowed=false;note(i,0,1220);
        const auto count=i.pulse().rewrites;check(!i.observe_clock_busy(s,g,clock_reads(s,0,true))&&!i.active(),"BUSY before completed Pulse or after terminal cannot defer");
        check(i.pulse().rewrites==count&&i.busy_observation().count==0,"phase rejection never offers input or credits BUSY");}
    // Independently mutate actual immutable identities, all counters, context,
    // cleanup leases, input, clocks and guard proof. None can hide behind BUSY.
    for(unsigned variant=0;variant<53;++variant){auto i=delivered();auto s=actual_sample(0,1348,14,1.348,0);s.clock_coherent=false;
        auto g=guard(0,1348);g.allowed=false;note(i,0,1348);auto reads=clock_reads(s,0,true);
        if(variant<6){++s.owner[variant];g.owner=s.owner;}
        else if(variant<13)++s.counters[variant-6];
        else switch(variant){case 13:++s.body.world;break;case 14:++s.body.state;break;case 15:++s.body.index;break;
        case 16:++s.body.generation;break;case 17:++s.body.token;break;case 18:s.configuration=false;break;case 19:s.gates=false;break;
        case 20:s.canonical=false;break;case 21:s.protected_owner=true;break;case 22:s.pool_released=false;break;case 23:s.sdk_idle=false;break;
        case 24:s.motion_released=false;break;case 25:s.publication_inactive=false;break;case 26:s.parts_zero=false;break;case 27:s.capture_released=false;break;
        case 28:s.gesture_released=false;break;case 29:s.sdk_quiet=false;break;case 30:g.sdk_gesture_only=false;break;case 31:g.sdk_released=false;break;
        case 32:s.sdk_device=g.device=2;reads.sdk_device=2;break;case 33:s.sdk_device=2;break;case 34:++g.owner[0];break;
        case 35:s.sampled_ms=g.sampled_ms=reads.sdk_sampled_ms=0;break;case 36:s.sampled_ms=g.sampled_ms=reads.sdk_sampled_ms=1349;break;
        case 37:s.sampled_ms=g.sampled_ms=reads.sdk_sampled_ms=1097;break;case 38:--s.now;break;case 39:--s.sampled_ms;break;
        case 40:s.serial=12;reads.frame_serial=s.serial;break;case 41:s.native_time=1.2;reads.frame_time=s.native_time;break;
        case 42:s.serial=13;reads.frame_serial=s.serial;break;case 43:s.native_time=1.248;reads.frame_time=s.native_time;break;
        case 44:s.native_time=std::numeric_limits<double>::quiet_NaN();reads.frame_time=s.native_time;break;
        case 45:--reads.frame_serial;break;case 46:reads.frame_time=1.5;break;case 47:g.allowed=true;break;
        case 48:s.clock_coherent=true;break;case 49:s.now=s.sampled_ms=g.now=g.sampled_ms=reads.sdk_sampled_ms=1247;break;
        case 50:s.now=s.sampled_ms=g.now=g.sampled_ms=reads.sdk_sampled_ms=16000;break;
        case 51:i.note(true,0,false,1348,0,{});break;case 52:note(i,1,1348);break;}
        check(!i.observe_clock_busy(s,g,reads)&&!i.active(),"actual owner/body/counter/context/source/release/clock failure stays terminal despite typed BUSY");}
    for(unsigned variant=0;variant<32;++variant){auto i=delivered();auto s=actual_sample(0,1348,14,1.348,0);s.clock_coherent=false;
        auto g=guard(0,1348);g.allowed=false;note(i,0,1348);auto r=clock_reads(s,0,true);
        switch(variant){case 0:r.present=false;break;case 1:r.clock_mutex_busy=false;break;case 2:r.clock_read_attempted=false;break;
        case 3:r.clock_read_succeeded=true;break;case 4:r.clock_equality_evaluated=true;break;case 5:r.clock_equal=true;break;
        case 6:r.clock_observed_ms=1248;break;case 7:r.physics_read_attempted=true;break;case 8:r.physics_read_succeeded=true;break;
        case 9:r.gameplay_ready=false;break;case 10:r.multiplayer_active=true;break;case 11:r.lobby_joining=true;break;
        case 12:r.sdk_available=false;break;case 13:r.sdk_focused=false;break;case 14:r.sdk_overlay_ready=false;break;
        case 15:r.sdk_menu_blocked=true;break;case 16:r.sdk_menu_requested=true;break;case 17:r.sdk_capture_blocked=true;break;
        case 18:r.sdk_capturing=true;break;case 19:r.sdk_keyboard=true;break;case 20:r.sdk_buttons=0x8000;break;
        case 21:r.sdk_device=2;break;case 22:--r.sdk_sampled_ms;break;case 23:r.frame_available=false;break;
        case 24:r.frame_timing_available=false;break;case 25:r.canonical_read_attempted=false;break;case 26:r.canonical_read_succeeded=false;break;
        case 27:r.canonical_owner_evaluated=false;break;case 28:r.canonical_owner_equal=false;break;
        case 29:++r.frame_serial;break;case 30:r.frame_time=std::numeric_limits<double>::infinity();break;case 31:r.frame_time=1.1;break;}
        check(!i.observe_clock_busy(s,g,r)&&!i.active(),"contradictory producer witness cannot rescue aggregate Sample.gates=true");}
    for(unsigned variant=0;variant<9;++variant){auto i=delivered();b::Pad p{};
        switch(variant){case 0:p.buttons=1;break;case 1:p.left_trigger=13;break;case 2:p.right_trigger=13;break;
        case 3:p.left_x=1639;break;case 4:p.left_y=-1639;break;case 5:p.right_x=1639;break;case 6:p.right_y=-1639;break;
        case 7:p.buttons=0x100;break;case 8:p.buttons=0x8000;break;}
        note(i,0,1348,p);auto s=actual_sample(0,1348,14,1.348,0);s.clock_coherent=false;auto g=guard(0,1348);g.allowed=false;
        check(!i.observe_clock_busy(s,g,clock_reads(s,0,true))&&!i.active(),"new actual physical control remains terminal during BUSY");}
    // Source age retains its original inclusive250ms boundary separately from
    // the stricter native feed cutoff; feed itself is only100ms old here.
    for(unsigned age:{250u,251u}){auto i=delivered();auto s=actual_sample(0,1348,14,1.348,0);s.clock_coherent=false;s.sampled_ms=1348-age;
        auto g=guard(0,1348);g.allowed=false;g.sampled_ms=s.sampled_ms;note(i,0,1348);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true))==(age==250),"BUSY retains ordinary SDK freshness boundary without broadening it");}
    {auto i=queued();for(auto now:{1032u,1052u,1132u,1212u,1232u})(void)i.poll(now,0,true,true,true,504,{});
        auto s=actual_sample(0,1248,13,1.248);i.observe(s,guard(0,1248),clock_reads(s,1248));
        check(i.active(),"last coherent sample may use original source already216ms old");
        s=actual_sample(0,1348,14,1.348,0);s.clock_coherent=false;auto g=guard(0,1348);g.allowed=false;
        check(!i.observe_clock_busy(s,g,clock_reads(s,0,true))&&!i.active(),"fresh SDK and feed cannot hide a stale selected original source");}
    {auto i=delivered();note(i,0,1349);auto s=actual_sample(0,1348,14,1.348,0);s.clock_coherent=false;auto g=guard(0,1348);g.allowed=false;
        check(!i.observe_clock_busy(s,g,clock_reads(s,0,true))&&!i.active(),"future selected original source is not fresh during BUSY");}
    {auto i=delivered();auto s=actual_sample(0,1348,14,1.348,0);s.clock_coherent=false;auto g=guard(0,1348);g.allowed=false;note(i,0,1348);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true)),"fresh-source setup before source disappearance");
        s=actual_sample(0,1498,14,1.348,0);s.clock_coherent=false;g=guard(0,1498);g.allowed=false;
        check(!i.observe_clock_busy(s,g,clock_reads(s,0,true))&&!i.active(),"fresh SDK cannot extend original coherent feed expiry");}
    for(unsigned variant=0;variant<5;++variant){auto i=delivered();auto s=actual_sample(0,1264,14,1.264,0);s.clock_coherent=false;auto g=guard(0,1264);g.allowed=false;note(i,0,1264);
        check(i.observe_clock_busy(s,g,clock_reads(s,0,true)),"resumed proof negative fixture paused");
        s=actual_sample(0,1280,15,1.280);g=guard(0,1280);note(i,0,1280);
        switch(variant){case 0:++s.owner[2];break;case 1:++s.body.token;break;case 2:++s.counters[0];break;case 3:s.capture_released=false;break;case 4:s.clock_coherent=false;break;}
        i.observe(s,g,clock_reads(s,1280));check(!i.active()&&!i.session().callback_snapshot_ready(1280),"next coherent offer must pass full ordinary proof before callback restoration");}
}
void packet_domains(){
    h::Intent i;b::Pad p{};check(i.packet(0,3,p,false)==3,"default-off passthrough");
    const auto a=i.packet(2,0xffffffffu,p,true);check(a==0,"counter wraps naturally");
    p.buttons=0x8000;check(i.packet(2,0xffffffffu,p,true)==a+1,"press packet advances");
    p.buttons=0;check(i.packet(2,0xffffffffu,p,false)==a+2,"release advances even when original is unchanged");
    check(i.packet(2,0xffffffffu,p,false)==a+2,"unchanged return stable");
    p.buttons=1;check(i.packet(2,0xffffffffu,p,false)==a+3&&p.buttons==1,"later ordinary D-pad advances and is not swallowed");
    check(i.packet(1,3,{},false)==3,"unselected slot domain unchanged");
}

h::AdmissionContext pending_context(unsigned slot=0,std::uint64_t now=1000,std::uint64_t serial=10,double time=1.0){
    return {now,now,serial,time,ticket().owner,1u<<slot,true,true};
}
void pending_note(h::Intent& i,h::AdmissionWait& w,unsigned slot,std::uint64_t now,b::Pad p={},bool success=true){
    i.note(true,slot,success,now,4,p);w.note(slot,success,now,i);
}
void pending_admission(){
    for(unsigned slot=0;slot<4;++slot)for(unsigned initial:{0u,0x100u}){
        h::Intent i;h::AdmissionWait w;auto raw=chord();raw.buttons=static_cast<std::uint16_t>(initial);note(i,slot,1000,raw);
        check(!i.admit(1000,1u<<slot,ticket().owner),"SDK precedes genuine original North: strict admission refuses");
        check(w.begin(pending_context(slot),i),"only neutral/LB armed original begins bounded wait");
        check(!i.active()&&!i.pulse().used&&i.generation()==0,"pending cannot acquire body or Pulse");
        auto c=pending_context(slot,1008,11,1.008);check(w.update(c,i)==h::AdmissionWaitResult::waiting,"unchanged original waits without another SDK edge");
        pending_note(i,w,slot,1016,chord());c=pending_context(slot,1016,12,1.016);
        check(w.update(c,i)==h::AdmissionWaitResult::ready&&w.active(),"source-ready wait stays guarded until atomic consumption");
        check(w.consume(c,i)&&!w.active(),"fresh original witness consumes once before strict admission");
        check(i.admit(c.now,c.device,c.owner)&&i.generation()==1,"same unchanged strict policy admits after genuine proof");
        check(w.update(c,i)==h::AdmissionWaitResult::idle&&!w.begin(c,i),"consumed wait cannot admit or rearm active Intent");
    }
    for(unsigned initial:{0u,0x100u})for(unsigned delta:{249u,250u,251u}){
        h::Intent i;h::AdmissionWait w;auto raw=chord();raw.buttons=static_cast<std::uint16_t>(initial);note(i,0,1000,raw);check(w.begin(pending_context(),i),"deadline wait begins");
        pending_note(i,w,0,1000+delta,chord());const auto c=pending_context(0,1000+delta,11,1.3);
        check((w.update(c,i)==h::AdmissionWaitResult::ready)==(delta<=250),"original 250ms boundary is inclusive and never renewed");
    }
    for(unsigned variant=0;variant<17;++variant){
        h::Intent i;h::AdmissionWait w;note(i,0,1000);check(w.begin(pending_context(),i),"guard negative setup");
        auto c=pending_context(0,1016,11,1.016);
        switch(variant){case 0:c.allowed=false;break;case 1:c.sdk_chord_held=false;break;case 2:++c.owner[2];break;case 3:c.device=2;break;
        case 4:c.device=3;break;case 5:c.now=999;c.sampled_ms=999;break;case 6:c.sampled_ms=999;break;
        case 7:c.sampled_ms=0;break;case 8:c.sampled_ms=c.now+1;break;case 9:c.now=1251;c.sampled_ms=c.now;break;
        case 10:c.serial=9;break;case 11:c.native_time=.9;break;case 12:c.serial=10;break;case 13:c.native_time=1;break;
        case 14:c.native_time=std::numeric_limits<double>::quiet_NaN();break;case 15:c.serial=0;break;case 16:c.owner={};break;}
        check(w.update(c,i)==h::AdmissionWaitResult::canceled&&!w.active(),"menu/focus/release/input/owner/device/native and SDK clocks cancel");
        pending_note(i,w,0,1020,chord());check(w.update(pending_context(0,1020,12,1.02),i)==h::AdmissionWaitResult::idle,"cancellation never defers later held chord");
    }
    for(unsigned variant=0;variant<12;++variant){
        h::Intent i;h::AdmissionWait w;auto raw=chord();raw.buttons=0x100;note(i,0,1000,raw);check(w.begin(pending_context(),i),"sticky original negative setup");
        raw=chord();
        switch(variant){case 0:raw.buttons=0;break;case 1:raw.buttons=0x8000;break;case 2:raw.buttons|=1;break;case 3:raw.left_trigger=13;break;
        case 4:raw.right_trigger=13;break;case 5:raw.left_x=1639;break;case 6:raw.right_y=-1639;break;
        case 7:pending_note(i,w,0,1010,{},false);break;case 8:pending_note(i,w,1,1010);break;
        case 9:pending_note(i,w,0,999,raw);break;case 10:pending_note(i,w,0,1010,raw);raw.buttons=0x100;break;
        case 11:pending_note(i,w,0,1010,raw);raw.buttons=0;break;}
        if(variant<7||variant>=10)pending_note(i,w,0,1011,raw);
        check(!w.active(),"genuine transient release/new activity/disconnect/extra slot cancels sticky");
        pending_note(i,w,0,1016,chord());check(w.update(pending_context(0,1016,12,1.016),i)==h::AdmissionWaitResult::idle,"later raw reentry cannot revive same gesture");
    }
    {h::Intent i;h::AdmissionWait w;note(i,0,1000);check(w.begin(pending_context(),i),"simultaneous starts from original neutral");
        auto raw=chord();raw.buttons=0x100;pending_note(i,w,0,1008,raw);pending_note(i,w,0,1016,chord());
        check(w.update(pending_context(0,1016,11,1.016),i)==h::AdmissionWaitResult::ready,"neutral then original LB then North is supported");}
    {h::Intent i;h::AdmissionWait w;note(i,0,1000);check(w.begin(pending_context(),i),"Y-first negative setup");
        auto raw=chord();raw.buttons=0x8000;pending_note(i,w,0,1008,raw);pending_note(i,w,0,1016,chord());
        check(!w.active()&&w.update(pending_context(0,1016,11,1.016),i)==h::AdmissionWaitResult::idle,"late original LB on held Y never satisfies pending");}
    {h::Intent i;h::AdmissionWait w;note(i,0,1000);check(w.begin(pending_context(),i),"nonrenewable wait setup");
        check(w.update(pending_context(0,1249,11,1.249),i)==h::AdmissionWaitResult::waiting,"late waiting poll preserves start");
        pending_note(i,w,0,1251,chord());check(w.update(pending_context(0,1251,12,1.251),i)!=h::AdmissionWaitResult::ready&&w.started_ms()==1000,"poll never renews original wait deadline");}
    for(unsigned variant=0;variant<9;++variant){h::Intent i;h::AdmissionWait w;auto c=pending_context();auto raw=chord();raw.buttons=0x100;
        switch(variant){case 0:note(i,0,1000,chord());break;case 1:raw.buttons=0x8000;note(i,0,1000,raw);break;
        case 2:note(i,0,1000,raw);note(i,1,1000);break;case 3:note(i,0,749,raw);break;case 4:note(i,0,1001,raw);break;
        case 5:i.note(false,0,true,1000,4,raw);break;case 6:note(i,0,1000,raw);c.allowed=false;break;
        case 7:note(i,0,1000,raw);c.sdk_chord_held=false;break;case 8:note(i,0,1000,raw);c.device=0;break;}
        check(!w.begin(c,i),"already-ready/held Y/foreign/stale/future/SDK-only/invalid context cannot arm wait");}
}

void rejected_guard_diagnostics(){
    {auto i=queued(2);const auto accepted=i.session().latest();auto offered=sample(1048,13,1.048);
        auto g=guard(2,1048);g.allowed=false;g.device=0;g.sampled_ms=1049;++g.owner[3];offered.owner=g.owner;offered.sampled_ms=g.sampled_ms;
        h::ReadWitness reads;reads.present=true;reads.sdk_keyboard=true;reads.sdk_device=0x424d5803;reads.sdk_sampled_ms=g.sampled_ms;
        reads.frame_available=reads.frame_timing_available=reads.clock_read_attempted=true;reads.frame_serial=13;reads.frame_time=1.048;
        note(i,2,1048);i.observe(offered,g,reads);
        const auto frozen=i.first_guard_rejection();
        check(!i.active()&&std::string(i.issue())=="human_context_owner_device_or_source_changed","diagnostic observer retains unchanged cancellation decision");
        check(frozen.present&&frozen.origin==h::GuardOrigin::forward_observer,"first rejected guard identifies observer origin");
        check(frozen.bits==(h::context_disallowed|h::owner_changed|h::device_changed|h::sample_future),"all failing context predicates retained without unsigned future-age underflow");
        check(frozen.expected_owner==ticket().owner&&frozen.selected_slot==2&&frozen.expected_device==4&&frozen.fresh_original_mask==4,"expected actual source and fresh mask frozen");
        check(frozen.guard.now==1048&&frozen.guard.sampled_ms==1049&&frozen.guard.owner==g.owner&&frozen.guard.device==0&&!frozen.guard.allowed,"exact rejected Guard frozen");
        check(frozen.originals[2].wall==1048&&frozen.originals[2].success&&frozen.originals[2].packet==3&&h::quiet(frozen.originals[2].raw),"original source snapshot comes from rejection time");
        check(frozen.offered.present&&frozen.offered.sample.serial==13&&frozen.offered.sample.owner==g.owner&&frozen.offered.sample.sampled_ms==1049,"offered rejected sample is not the prior Session sample");
        check(frozen.reads.present&&frozen.reads.sdk_keyboard&&frozen.reads.sdk_device==0x424d5803&&frozen.reads.clock_read_attempted&&!frozen.reads.clock_read_succeeded,"existing failed producer read witness frozen");
        check(i.session().latest().serial==accepted.serial&&i.session().latest().now==accepted.now,"guard rejection preserves last Session sample");
        check(i.latest_offered_observation().present&&i.latest_offered_observation().sample.serial==13,"latest offered observer diagnostic includes rejected sample");
        note(i,2,1064);auto later=sample(1064,14,1.064);reads.sdk_device=8;reads.sdk_keyboard=false;reads.clock_read_succeeded=true;
        i.observe(later,guard(2,1064),reads);check(!i.guard(guard(2,1064)),"later inactive observer/guard cannot retry");
        check(i.first_guard_rejection().guard.now==1048&&i.first_guard_rejection().originals[2].wall==1048&&i.first_guard_rejection().reads.sdk_keyboard,
            "later source, guard and read changes cannot overwrite first failure");
        check(i.latest_offered_observation().sample.serial==13,"inactive offers cannot overwrite the terminal offered sample");
        check(!i.admit(1064,4,ticket().owner)&&i.first_guard_rejection().present,"admission without a new gesture does not clear diagnostics");
        check(!i.admit(1064,3,ticket().owner)&&i.first_guard_rejection().present,"rejected device admission does not clear diagnostics");
        note(i,2,1080);note(i,2,1096,chord());check(i.admit(1096,4,ticket().owner)&&i.generation()==2,"new genuine gesture admits next generation");
        check(!i.first_guard_rejection().present&&!i.latest_offered_observation().present,"only accepted next generation resets rejection and offered diagnostics");
    }
    {auto i=admitted(1);auto g=guard(1,1016);g.allowed=false;h::ReadWitness reads;reads.present=true;reads.sdk_device=2;
        check(!i.guard(g,h::GuardOrigin::pre_ticket,nullptr,&reads),"pre-ticket guard still rejects disallowed context");
        const auto& frozen=i.first_guard_rejection();check(frozen.present&&frozen.origin==h::GuardOrigin::pre_ticket&&!frozen.offered.present&&frozen.reads.present,
            "pre-ticket rejection explicitly has no offered observer sample");
        check(!i.latest_offered_observation().present,"pre-ticket guard does not invent observer sample");
    }
    {auto i=admitted();auto g=guard(0,1251);check(!i.guard(g),"stale original still rejects with fresh SDK sample");
        check(i.first_guard_rejection().bits==h::selected_original_not_fresh&&i.first_guard_rejection().fresh_original_mask==0,
            "selected-original freshness failure separated from SDK freshness");}
    {auto i=admitted();auto g=guard(0,1016);g.sampled_ms=0;check(!i.guard(g),"missing SDK timestamp still rejects");
        check(i.first_guard_rejection().bits==h::sample_missing,"missing timestamp is not double-labelled stale");}
    {auto i=admitted();auto g=guard(0,1016);g.now=999;check(!i.guard(g),"wall rollback still rejects before context branch");
        check(i.first_guard_rejection().bits==h::wall_reversed&&i.first_guard_rejection().previous_wall==1000,"clock branch retains original prior guard time");}
    {auto i=admitted();auto g=guard(0,1016);g.sdk_gesture_only=false;check(!i.guard(g),"SDK activity still rejects");
        check(i.first_guard_rejection().bits==h::sdk_activity&&std::string(i.issue())=="new_physical_activity","activity branch kept separate from context failure");}
    // A witness cannot change authorization. Deliberately contradictory passive
    // read flags must neither reject a valid Sample nor rescue an invalid Guard.
    for(bool reject:{false,true}){auto without=queued(),with=queued();auto v=sample(1048,13,1.048);auto g=guard(0,1048);g.allowed=!reject;
        h::ReadWitness reads;reads.present=true;reads.sdk_keyboard=true;reads.clock_read_attempted=true;
        note(without,0,1048);note(with,0,1048);without.observe(v,g);with.observe(v,g,reads);
        check(with.active()==without.active()&&with.session().phase()==without.session().phase()&&with.pulse().phase==without.pulse().phase&&
            std::string(with.issue())==without.issue(),"passive read witness leaves successful and rejected control decisions unchanged");}
}

int main(){pending_admission();admission();release_and_context();input_and_native();clock_busy_observation();packet_domains();rejected_guard_diagnostics();std::cout<<checks<<" human native handoff checks passed\n";}
