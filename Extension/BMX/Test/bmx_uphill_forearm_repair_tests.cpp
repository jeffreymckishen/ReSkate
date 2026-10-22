#include "fixtures/bmx_coupled_native_pose.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>

namespace p=dingosdk::bmx::rider::pose;
namespace v=dingosdk::bmx::visual;
namespace policy=dingosdk::bmx::forearm_repair;
using Bones=std::vector<p::Bone>;
unsigned checks{},frames{},preserved{},repaired{},fallbacks{};
float maximum_drop{},maximum_hand{},maximum_foot{},maximum_step{},maximum_rotation{},maximum_repair_step{};
void check(bool okay,const char* why){++checks;if(!okay){std::fprintf(stderr,"FAIL %s frame=%u\n",why,frames);std::exit(1);}}
bool exact(const Bones& a,const Bones& b){return a.size()==b.size()&&!std::memcmp(a.data(),b.data(),a.size()*sizeof(p::Bone));}
bool same_result(const p::Result& a,const p::Result& b){
#define FIELD(x) if(std::memcmp(&a.x,&b.x,sizeof(a.x)))return false
    FIELD(forearm_repair_requested);FIELD(forearm_baseline_valid);FIELD(forearm_repair_attempted);FIELD(forearm_repair_applied);
    FIELD(forearm_repair_extra_drop);FIELD(forearm_repair_evaluations);FIELD(ready);FIELD(hand_error);FIELD(foot_error);FIELD(hand_contact);FIELD(foot_contact);
    FIELD(posture_attempts);FIELD(posture_scale);FIELD(posture_fit_adjustment);FIELD(posture_gaze);FIELD(posture_requested);FIELD(posture_fallback);
    FIELD(observed_requested);FIELD(observed_applied);FIELD(observed_strength);FIELD(spring_requested);FIELD(spring_calibrated);FIELD(spring_applied);FIELD(spring_fit_adjustment);
    FIELD(coupled_posture_requested);FIELD(coupled_posture_applied);
#undef FIELD
    return true;
}
v::Frame frame_for(const actual276::Fixture& fixture){auto f=fixture.frame;f.spring_avatar={};f.coupled_posture_selected=f.coupled_motion_committed=false;
    f.forearm_repair_selected=true;f.mount_token=0;f.mount_progress=f.rider_blend=1;f.air_extension_available=true;f.air_extension_blend=0;
    f.rider_posture_available=true;f.rider_uphill_blend=.5f;f.rider_gaze_counterpitch=.1f;f.crank_phase=.7853981634f;f.steer=.4f;f.pedal_effort=1;return f;}
bool strict(const Bones& bones,const p::Rig& rig,const v::Frame& frame,const p::Result& r){return r.ready&&std::isfinite(r.hand_error)&&std::isfinite(r.foot_error)&&
    r.hand_error<.003f&&r.foot_error<.003f&&p::finite_riding_output(bones,rig)&&p::proposed_small_bike_anatomy(bones,rig,frame);}
Bones proposal(const actual276::Fixture& fixture,const v::Frame& frame,float amount){auto bones=fixture.bones;
    for(int joint:p::changed(fixture.rig))bones[static_cast<unsigned>(joint)].rotation=fixture.rig.bind[static_cast<unsigned>(joint)];
    p::solve_riding_candidate(bones,fixture.rig,frame,amount);return bones;}
void lanes(const Bones& actual,const Bones& reference,const p::Rig& rig){
    std::vector<int> allowed{rig.shoulders[0],rig.shoulders[1]};for(auto chain:{rig.left_arm,rig.right_arm})for(int i:chain)allowed.push_back(i);
    for(auto fingers:{rig.left_fingers,rig.right_fingers})for(auto finger:fingers){if(finger.metacarpal>=0)allowed.push_back(finger.metacarpal);for(int i:finger.joints)if(i>=0)allowed.push_back(i);}
    for(unsigned i=0;i<actual.size();++i){check(!std::memcmp(actual[i].position.data(),reference[i].position.data(),sizeof(p::Bone::position)),"all position/W lanes equal same-amount proposal");
        check(!std::memcmp(actual[i].scale.data(),reference[i].scale.data(),sizeof(p::Bone::scale)),"all scale/metadata lanes equal same-amount proposal");
        if(std::find(allowed.begin(),allowed.end(),static_cast<int>(i))==allowed.end())check(!std::memcmp(actual[i].rotation.data(),reference[i].rotation.data(),sizeof(p::Bone::rotation)),
            "root/hip/spine/head/leg/unrelated rotations equal same-amount proposal");}
}
void budgets(){std::array<unsigned,3> calls{};volatile bool enabled=true,disabled=false,accept_refused=false;
    volatile unsigned last_amount=2;volatile float late_threshold=.006f,first_threshold=.004f;
    const auto late=policy::retry_posture([&](unsigned){return enabled;},[&](unsigned i,float drop){++calls[i];return i==last_amount&&drop>=late_threshold;});
    check(late.ready&&late.proposal==2&&late.evaluations==11&&calls==std::array<unsigned,3>{1,1,9},"late success executes two refused endpoints then unchanged nine-evaluation search");
    check(late.evaluations==policy::maximum_posture_evaluations&&3+late.evaluations==14,"retained three-reference proposals bound complete solve count at14");
    calls={};const auto first=policy::retry_posture([&](unsigned){return enabled;},[&](unsigned i,float drop){++calls[i];return drop>=first_threshold;});
    check(first.ready&&first.proposal==0&&first.evaluations==9&&calls==std::array<unsigned,3>{9,0,0},"first success stops before all lower amounts");
    calls={};const auto refused=policy::retry_posture([&](unsigned){return enabled;},[&](unsigned i,float){++calls[i];return accept_refused;});
    check(!refused.ready&&refused.evaluations==3&&calls==std::array<unsigned,3>{1,1,1},"three failed bounds never widen or spend midpoint budget");
    unsigned skipped_calls{};const auto skipped=policy::retry_posture([&](unsigned){return disabled;},[&](unsigned,float){++skipped_calls;return accept_refused;});
    check(!skipped.ready&&skipped.evaluations==0&&skipped_calls==0,"ineligible retained proposals never call candidate generator");
}
p::Result run(const actual276::Fixture& fixture,v::Frame frame,bool expect_fix=false){++frames;auto original=fixture.bones,actual=fixture.bones;
    frame.forearm_repair_selected=false;const auto baseline=p::solve(original,fixture.rig,frame);
    frame.forearm_repair_selected=true;const auto result=p::solve(actual,fixture.rig,frame);
    if(strict(original,fixture.rig,frame,baseline)){++preserved;check(exact(original,actual)&&same_result(baseline,result),"valid original winner and every result field preserved bitwise");}
    else if(expect_fix){check(!baseline.ready&&exact(original,fixture.bones),"known original posture failure remains explicit and source-uncommitted");
        check(result.forearm_repair_applied&&strict(actual,fixture.rig,frame,result),"otherwise invalid same-amount proposal repaired under unchanged strict gates");}
    if(result.forearm_repair_applied){++repaired;check(strict(actual,fixture.rig,frame,result),"repair cannot bypass anatomy/contact/finite output");
        check(result.forearm_repair_requested&&result.forearm_repair_attempted&&!result.forearm_baseline_valid&&result.posture_requested,
            "private repair receipt distinguishes original rejection");
        check(result.posture_attempts==3&&!result.posture_fallback&&result.posture_scale==1&&result.forearm_repair_evaluations==9,
            "actual native matrix retains full original pass plus first-amount nine-evaluation repair accounting");
        check(result.forearm_repair_evaluations<=policy::maximum_posture_evaluations&&result.posture_attempts+result.forearm_repair_evaluations<=14,
            "actual candidate work respects retained-reference bound");
        lanes(actual,proposal(fixture,frame,result.posture_scale),fixture.rig);maximum_drop=std::max(maximum_drop,result.forearm_repair_extra_drop);}
    maximum_hand=std::max(maximum_hand,result.hand_error);maximum_foot=std::max(maximum_foot,result.foot_error);return result;
}
void reachable_matrix(const actual276::Fixture& fixture){
    for(unsigned phase=0;phase<48;++phase)for(float steer:{-.4f,-.375f,0.f,.375f,.4f})for(float pedal:{0.f,.5f,1.f})
    for(float hill:{.05f,.25f,.5f,.75f,1.f})for(float gaze:{0.f,.1f})for(float incline:{0.f,.1f,.25f}){auto frame=frame_for(fixture);
        frame.crank_phase=phase*6.28318530718f/48;frame.steer=steer;frame.pedal_effort=pedal;frame.rider_uphill_blend=hill;frame.rider_gaze_counterpitch=gaze;
        frame.chassis_quaternion=p::multiply(p::axis(1,.2f),p::axis(0,-incline));run(fixture,frame,true);}
    check(frames==21600&&preserved==21000&&repaired==600,"all600 reachable historical failures repaired and21000 valid winners unchanged");
}
void fallback_witnesses(const actual276::Fixture& source){
    // Synthetic origin perturbations test selection policy, not native likeness.
    for(float shift:{-.024f,-.032f})for(float phase:{0.f,.7853981634f}){auto fixture=source;
        fixture.bones[static_cast<unsigned>(fixture.rig.spine[0])].position[1]+=shift;auto frame=frame_for(fixture);frame.rider_uphill_blend=1;frame.pedal_effort=0;frame.steer=0;frame.crank_phase=phase;
        auto expected=fixture.bones,actual=fixture.bones;frame.forearm_repair_selected=false;const auto baseline=p::solve(expected,fixture.rig,frame);
        frame.forearm_repair_selected=true;const auto result=p::solve(actual,fixture.rig,frame);const float amount=shift==-.024f?.5f:0.f;
        check(baseline.ready&&baseline.posture_scale==amount&&baseline.posture_fallback,"synthetic input executes intended existing half/zero fallback");
        check(exact(expected,actual)&&same_result(baseline,result)&&!result.forearm_repair_requested,"valid original fallback precedes private repair and stays exact");++fallbacks;}
}
void exclusions(const actual276::Fixture& fixture){
    for(unsigned mode=0;mode<38;++mode){auto frame=frame_for(fixture);bool observed=false;
        if(mode==0)frame.forearm_repair_selected=false;if(mode==1)frame.active=false;if(mode==2)frame.entity=0;if(mode==3)frame.native_body_token=0;
        if(mode==4){frame.mount_token=1;frame.mount_progress=.5f;}if(mode==5)frame.rider_blend=.5f;if(mode==6)frame.rider_mode=v::RiderMode::carrying;
        if(mode==7)frame.spring_avatar.requested=true;if(mode==8)frame.coupled_posture_selected=true;if(mode==9)frame.coupled_motion_committed=true;
        if(mode==10)observed=true;if(mode==11)frame.airborne=true;if(mode==12)frame.air_extension_blend=.00001f;
        if(mode==13)frame.preload=.00001f;if(mode==14)frame.front_weight=.00001f;if(mode==15)frame.rear_weight=.00001f;if(mode==16)frame.landing_compression=.00001f;
        if(mode==17)frame.release_left_hand=.00001f;if(mode==18)frame.release_right_hand=.00001f;if(mode==19)frame.release_left_foot=.00001f;if(mode==20)frame.release_right_foot=.00001f;
        if(mode==21)frame.barspin_release=.00001f;if(mode==22)frame.tailwhip_release=.00001f;if(mode==23)frame.barspin=.00001f;if(mode==24)frame.tailwhip=.00001f;
        if(mode==25)frame.movement_phase=.00001f;if(mode==26)frame.movement_holding=true;if(mode==27)frame.movement_recovering=true;
        if(mode==28)frame.steer=.40001f;if(mode==29)frame.rider_posture_available=false;if(mode==30)frame.chassis_quaternion_available=false;
        if(mode==31)frame.movement_id=dingosdk::bmx::catalog::entries[0].id;if(mode==32)frame.movement_progress=.00001f;
        if(mode==33)frame.movement_bike_pitch=.00001f;if(mode==34)frame.movement_bike_roll=.00001f;if(mode==35)frame.mount_progress=.999f;if(mode==36)frame.rider_mode=v::RiderMode::none;
        if(mode==37){frame.rider_posture_available=false;frame.rider_uphill_blend=frame.rider_gaze_counterpitch=std::numeric_limits<float>::quiet_NaN();}
        check(!p::uphill_forearm_repair_eligible(frame,observed),"each private admission/ownership/mode/contact/load exclusion denies repair");
        auto actual=fixture.bones,expected=fixture.bones;p::EntryContacts a,b;p::SpringBinding sa,sb;
        const auto result=p::solve(actual,fixture.rig,frame,&a,observed,&sa);frame.forearm_repair_selected=false;
        const auto baseline=p::solve(expected,fixture.rig,frame,&b,observed,&sb);
        check(exact(actual,expected)&&same_result(result,baseline)&&!result.forearm_repair_requested,"excluded route preserves old solve and all result fields");
    }
}
void invalid_sources(const actual276::Fixture& source){const float nan=std::numeric_limits<float>::quiet_NaN();
    for(unsigned mode=0;mode<22;++mode){auto fixture=source;auto frame=frame_for(fixture);
        if(mode==0)fixture.rig.parents[static_cast<unsigned>(fixture.rig.left_arm[1])]=-1;
        if(mode==1)fixture.rig.bind[7][0]=nan;if(mode==2)fixture.bones[1].rotation[0]=nan;if(mode==3)fixture.bones[1].rotation={0,0,0,2};
        if(mode==4)fixture.bones[1].position[0]=nan;if(mode==5)fixture.bones[1].position[0]=1000001;if(mode==6)fixture.bones[7].scale[0]=0;
        if(mode==7)fixture.bones[7].scale[0]=nan;if(mode==8)frame.position[0]=nan;if(mode==9)frame.position[0]=1000001;
        if(mode==10)frame.chassis_quaternion={0,0,0,0};if(mode==11)frame.chassis_quaternion[0]=nan;if(mode==12)frame.rider_uphill_blend=nan;
        if(mode==13)frame.rider_gaze_counterpitch=nan;if(mode==14)frame.rider_uphill_blend=1.001f;if(mode==15)frame.pedal_effort=1.001f;
        if(mode==16)frame.rider_blend=nan;if(mode==17)frame.steer=nan;if(mode==18)frame.crank_phase=nan;
        if(mode==19)frame.rider_gaze_counterpitch=dingosdk::bmx::rider_posture::maximum_counterpitch+.001f;
        if(mode==20)fixture.rig.bind[7]={0,0,0,0};if(mode==21)fixture.bones[7].scale[0]=20.1f;
        const auto untouched=fixture.bones;const auto result=p::solve(fixture.bones,fixture.rig,frame);
        check(!result.ready&&exact(fixture.bones,untouched)&&!result.forearm_repair_requested&&!result.forearm_repair_attempted&&result.forearm_repair_evaluations==0,
            "source/frame/root validation rejects before any private retry or write");
    }
    auto short_arm=source;short_arm.bones[static_cast<unsigned>(short_arm.rig.left_arm[2])].position[0]*=.3f;
    const auto untouched=short_arm.bones;auto frame=frame_for(short_arm);const auto refused=p::solve(short_arm.bones,short_arm.rig,frame);
    check(!refused.ready&&exact(untouched,short_arm.bones)&&refused.forearm_repair_requested&&!refused.forearm_repair_attempted&&refused.forearm_repair_evaluations==0,
        "valid but unreachable native chain cannot bypass strict contacts or commit a failed proposal");
}
void continuity(const actual276::Fixture& fixture){for(unsigned sequence=0;sequence<6;++sequence){std::vector<p::Transform> prior,prior_reference;
    for(unsigned step=0;step<=256;++step){auto frame=frame_for(fixture);const float t=step<=128?step/128.f:(256-step)/128.f;
        if(sequence==0)frame.rider_uphill_blend=t;if(sequence==1){frame.chassis_quaternion=p::axis(0,-.2f);frame.rider_gaze_counterpitch=.25f*t;}
        if(sequence==2)frame.pedal_effort=t;if(sequence==3)frame.steer=.3f+.1f*t;
        if(sequence==4)frame.crank_phase=std::fmod(6.08318530718f+step*.003125f,6.28318530718f);if(sequence==5)frame.chassis_quaternion=p::axis(0,-.3f*t);
        auto bones=fixture.bones;const auto result=p::solve(bones,fixture.rig,frame);check(strict(bones,fixture.rig,frame,result),"uphill/gaze/pedal/steer/wrap/incline sequence stays strict valid");
        const auto current=p::compose(bones,fixture.rig),reference=p::compose(proposal(fixture,frame,result.posture_scale),fixture.rig);
        if(!prior.empty())for(unsigned i=0;i<current.size();++i){maximum_step=std::max(maximum_step,p::length(p::sub(current[i].position,prior[i].position)));
            const auto delta=p::normal(p::multiply(p::inverse(prior[i].rotation),current[i].rotation));
            maximum_rotation=std::max(maximum_rotation,2*std::atan2(p::length({delta[0],delta[1],delta[2]}),std::abs(delta[3])));
            maximum_repair_step=std::max(maximum_repair_step,p::length(p::sub(p::sub(current[i].position,reference[i].position),p::sub(prior[i].position,prior_reference[i].position))));}
        prior=current;prior_reference=reference;
    }}
    check(maximum_step<.005f&&maximum_rotation<.02f&&maximum_repair_step<.0005f,"sampled transitions bound total motion and isolate repair-induced changes");
}
int main(){budgets();const auto fixture=actual276::get();reachable_matrix(fixture);fallback_witnesses(fixture);exclusions(fixture);invalid_sources(fixture);continuity(fixture);
    check(p::active_compose_cache==nullptr,"all selected posture cache scopes released");
    std::printf("PASS %u checks; %u reachable frames, %u original byte-preserved, %u repaired, %u synthetic half/zero fallbacks; max drop=%.9f hand=%.9f foot=%.9f m; sequence XYZ=%.9f rotation=%.9f repair delta=%.9f; policy max11extra/14total\n",
        checks,frames,preserved,repaired,fallbacks,maximum_drop,maximum_hand,maximum_foot,maximum_step,maximum_rotation,maximum_repair_step);
}
