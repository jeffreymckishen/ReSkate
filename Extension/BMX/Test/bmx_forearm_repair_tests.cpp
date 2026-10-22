#include "fixtures/bmx_coupled_native_pose.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <set>
#include <string>

namespace p=dingosdk::bmx::rider::pose;
namespace v=dingosdk::bmx::visual;
namespace policy=dingosdk::bmx::forearm_repair;
unsigned checks{},cases{},baseline_failures{},repaired{},retained_excluded_failures{},new_failures{},valid_baseline_preserved{};
float maximum_drop{},maximum_hand{},maximum_foot{},maximum_sequence_step{},maximum_sequence_rotation{};
void check(bool okay,const char* why){++checks;if(!okay){std::fprintf(stderr,"FAIL %s case=%u\n",why,cases);std::exit(1);}}
bool exact(const std::vector<p::Bone>& a,const std::vector<p::Bone>& b){return a.size()==b.size()&&!std::memcmp(a.data(),b.data(),a.size()*sizeof(p::Bone));}
v::Frame neutral(const actual276::Fixture& fixture){auto f=fixture.frame;f.spring_avatar={};f.coupled_posture_selected=f.coupled_motion_committed=false;
    f.forearm_repair_selected=false;f.mount_token=0;f.mount_progress=f.rider_blend=1;f.air_extension_available=true;f.air_extension_blend=0;
    f.rider_posture_available=false;f.rider_uphill_blend=f.rider_gaze_counterpitch=0;return f;}
bool strict(const std::vector<p::Bone>& bones,const p::Rig& rig,const v::Frame& f,const p::Result& r){
    return r.ready&&std::isfinite(r.hand_error)&&std::isfinite(r.foot_error)&&r.hand_error<.003f&&r.foot_error<.003f&&
        p::finite_riding_output(bones,rig)&&p::proposed_small_bike_anatomy(bones,rig,f);
}
void invariants(const actual276::Fixture& fixture,const std::vector<p::Bone>& baseline,const std::vector<p::Bone>& actual){
    for(unsigned i=0;i<actual.size();++i){
        check(!std::memcmp(actual[i].scale.data(),baseline[i].scale.data(),16),"native scale and metadata remain exact");
        check(!std::memcmp(actual[i].position.data(),baseline[i].position.data(),16),"all native positions, pelvis and W lanes remain exact");
    }
    for(auto j:{1,fixture.rig.hips,fixture.rig.head,fixture.rig.spine[0],fixture.rig.spine[1],fixture.rig.spine[2],fixture.rig.spine[3],
        fixture.rig.neck[0],fixture.rig.neck[1],fixture.rig.left_leg[0],fixture.rig.left_leg[1],fixture.rig.left_leg[2],
        fixture.rig.right_leg[0],fixture.rig.right_leg[1],fixture.rig.right_leg[2]})
        check(!std::memcmp(&actual[static_cast<unsigned>(j)],&baseline[static_cast<unsigned>(j)],sizeof(p::Bone)),"trajectory, hips, head, spine and legs remain baseline exact");
    const auto g=p::compose(actual,fixture.rig);
    for(const auto& joint:g){float n{};for(float q:joint.rotation){check(std::isfinite(q),"composed output quaternion finite");n+=q*q;}
        check(std::abs(n-1)<.00001f,"composed rotation remains unit");for(float x:joint.position)check(std::isfinite(x),"composed output XYZ finite");}
}
p::Result run(const actual276::Fixture& fixture,v::Frame frame,bool require_repair=false){
    ++cases;auto baseline=fixture.bones,disabled=fixture.bones,actual=fixture.bones;
    const auto legacy=p::solve_baseline(baseline,fixture.rig,frame);const auto off=p::solve(disabled,fixture.rig,frame);
    check(exact(baseline,disabled)&&legacy.ready==off.ready&&legacy.hand_error==off.hand_error&&legacy.foot_error==off.foot_error,
        "unselected route retains baseline pose and result exactly");
    frame.forearm_repair_selected=true;const auto result=p::solve(actual,fixture.rig,frame);
    const bool base_valid=strict(baseline,fixture.rig,frame,legacy),actual_valid=strict(actual,fixture.rig,frame,result);
    if(!p::forearm_repair_eligible(frame,false))check(exact(actual,baseline)&&legacy.ready==result.ready,"loaded/released/nonordinary routes unchanged");
    if(base_valid){++valid_baseline_preserved;check(actual_valid&&exact(actual,baseline),"every valid baseline byte preserved");if(!actual_valid)++new_failures;}
    else {++baseline_failures;if(result.forearm_repair_applied)++repaired;
        else if(!p::forearm_repair_eligible(frame,false))++retained_excluded_failures;}
    if(require_repair&&!base_valid)check(result.forearm_repair_applied&&actual_valid,"known forearm failure repaired under unchanged gates");
    if(result.forearm_repair_applied){
        check(result.forearm_repair_requested&&result.forearm_repair_attempted&&!result.forearm_baseline_valid,"receipt distinguishes invalid baseline and applied correction");
        check(actual_valid&&result.forearm_repair_extra_drop>0&&result.forearm_repair_extra_drop<=policy::maximum_extra_drop,"bounded repair commits only strict valid output");
        check(result.forearm_repair_evaluations==policy::search_iterations+1,"bounded endpoint plus binary search only");
        invariants(fixture,baseline,actual);maximum_drop=std::max(maximum_drop,result.forearm_repair_extra_drop);
    }
    maximum_hand=std::max(maximum_hand,result.hand_error);maximum_foot=std::max(maximum_foot,result.foot_error);
    return result;
}
void policy_checks(){
    policy::Scope good{true,true,true,true,false};check(policy::selected(good),"exact private scope selected");
    for(auto member:{&policy::Scope::requested,&policy::Scope::private_profile,&policy::Scope::human_ride,&policy::Scope::native_chassis}){
        auto bad=good;bad.*member=false;check(!policy::selected(bad),"each private scope proof required");}
    good.conflict=true;check(!policy::selected(good)&&!policy::selected({}),"conflict and ordinary off rejected");
    float best{};const auto found=policy::minimum_drop([&](float d){if(d>=.006f){best=d;return true;}return false;});
    check(found.ready&&found.extra_drop==best&&found.extra_drop>=.006f&&found.extra_drop-.006f<.01f/256,"search returns last verified minimal bounded success");
    unsigned calls{};const auto refused=policy::minimum_drop([&](float){++calls;return false;});
    check(!refused.ready&&calls==1&&refused.evaluations==1,"failed bound never broadens or repeats search");
}
void original_matrix(const actual276::Fixture& fixture){const auto source=neutral(fixture);const unsigned failed_before=baseline_failures,repaired_before=repaired;
    for(unsigned phase=0;phase<24;++phase)for(int steer=-16;steer<=16;++steer){auto f=source;f.crank_phase=phase*6.28318530718f/24;f.steer=.025f*steer;run(fixture,f,true);}
    for(unsigned phase=0;phase<24;++phase)for(int steer=-4;steer<=4;++steer)for(unsigned cue=0;cue<6;++cue)for(unsigned level=1;level<=4;++level){
        auto f=source;f.crank_phase=phase*6.28318530718f/24;f.steer=.1f*steer;const float x=level*.25f;
        if(cue==0)f.preload=x;if(cue==1)f.landing_compression=x;if(cue==2)f.front_weight=x;if(cue==3)f.rear_weight=x;
        if(cue==4){f.airborne=true;f.air_extension_blend=x;}if(cue==5)f.pedal_effort=x;run(fixture,f,true);}
    for(unsigned phase=0;phase<24;++phase)for(float yaw:{0.f,1.5707963f,-2.4f})for(bool tilted:{false,true})for(int steer=-4;steer<=4;++steer){
        auto f=source;f.crank_phase=phase*6.28318530718f/24;f.steer=.1f*steer;
        f.chassis_quaternion=p::multiply(p::axis(1,yaw),p::multiply(p::axis(0,tilted?.18f:0.f),p::axis(2,tilted?-.15f:0.f)));run(fixture,f,true);}
    check(baseline_failures-failed_before==36&&repaired-repaired_before==36,"all original36 baseline failures retained and repaired, never relabelled valid");
}
void nearby_and_mixed(const actual276::Fixture& fixture){const auto source=neutral(fixture);const unsigned failed_before=baseline_failures,repaired_before=repaired;
    for(unsigned phase=0;phase<48;++phase)for(float steer:{-.425f,-.4f,-.375f,.375f,.4f,.425f})for(float pedal:{.5f,.75f,1.f}){
        auto f=source;f.crank_phase=phase*6.28318530718f/48;f.steer=steer;f.pedal_effort=pedal;run(fixture,f,true);}
    check(baseline_failures-failed_before==216&&repaired-repaired_before==216,"all216 nearby forearm failures repaired");
    for(unsigned phase=0;phase<24;++phase)for(int steer=-4;steer<=4;++steer)for(unsigned cue=0;cue<8;++cue)for(float pedal:{0.f,.5f,1.f}){
        auto f=source;f.crank_phase=phase*6.28318530718f/24;f.steer=.1f*steer;f.pedal_effort=pedal;
        if(cue==0){f.preload=.5f;f.landing_compression=.5f;}if(cue==1){f.preload=.5f;f.front_weight=.5f;}
        if(cue==2){f.landing_compression=.5f;f.rear_weight=.5f;}if(cue==3){f.preload=1;f.front_weight=1;}
        if(cue==4){f.airborne=true;f.air_extension_blend=.5f;f.preload=.5f;}
        if(cue==5){f.airborne=true;f.air_extension_blend=1;f.landing_compression=.5f;}
        if(cue==6){f.rear_weight=-.5f;f.landing_compression=1;}if(cue==7){f.rider_posture_available=true;f.rider_uphill_blend=.5f;f.rider_gaze_counterpitch=.1f;}
        run(fixture,f);}
}
void boundary_sequence(const actual276::Fixture& fixture){auto frame=neutral(fixture);frame.forearm_repair_selected=true;frame.crank_phase=.7853981634f;frame.steer=.4f;
    std::vector<p::Transform> previous;bool saw_baseline{},saw_repair{};
    for(unsigned sequence=0;sequence<3;++sequence){previous.clear();
    for(unsigned step=0;step<=128;++step){const float t=step<=64?step/64.f:(128-step)/64.f;
        frame.pedal_effort=sequence==0?t:1;frame.steer=sequence==1?.3f+.125f*t:.4f;
        frame.crank_phase=sequence==2?6.08318530718f+step*.003125f:.7853981634f;auto bones=fixture.bones;
        const auto result=p::solve(bones,fixture.rig,frame);check(strict(bones,fixture.rig,frame,result),"threshold sequence always strict valid");
        saw_baseline=saw_baseline||result.forearm_baseline_valid;saw_repair=saw_repair||result.forearm_repair_applied;
        const auto current=p::compose(bones,fixture.rig);if(!previous.empty())for(unsigned i=0;i<current.size();++i){
            maximum_sequence_step=std::max(maximum_sequence_step,p::length(p::sub(current[i].position,previous[i].position)));
            float dot{};for(unsigned a=0;a<4;++a)dot+=current[i].rotation[a]*previous[i].rotation[a];
            maximum_sequence_rotation=std::max(maximum_sequence_rotation,2*std::acos(std::clamp(std::abs(dot),0.f,1.f)));}
        previous=current;
    }}
    check(saw_baseline&&saw_repair&&maximum_sequence_step<.003f&&maximum_sequence_rotation<.035f,
        "effort/steer thresholds and crank wrap retain bounded position and quaternion steps");
}
void excluded_and_invalid(const actual276::Fixture& fixture){auto f=neutral(fixture);f.forearm_repair_selected=true;f.crank_phase=.7853981634f;f.steer=.4f;f.pedal_effort=1;
    for(unsigned mode=0;mode<7;++mode){auto frame=f;if(mode==0)frame.spring_avatar=fixture.frame.spring_avatar;if(mode==1)frame.rider_mode=v::RiderMode::carrying;
        if(mode==2){frame.mount_token=1;frame.mount_progress=.5f;}if(mode==3)frame.coupled_posture_selected=true;if(mode==4)frame.native_body_token=0;
        if(mode==5)frame.active=false;if(mode==6)frame.release_left_hand=1;
        auto baseline=fixture.bones,actual=fixture.bones;p::EntryContacts a,b;
        const auto old=p::solve_baseline(baseline,fixture.rig,frame,&a),result=p::solve(actual,fixture.rig,frame,&b);
        check(old.ready==result.ready&&exact(baseline,actual)&&!result.forearm_repair_requested,"Spring/carry/entry/foreign or inactive ownership remains baseline");}
    auto varied=fixture;for(auto& q:varied.bones[1].rotation)q*=1.01f;run(varied,neutral(varied));
    auto altered=fixture.bones;altered[1].rotation[0]=std::numeric_limits<float>::quiet_NaN();
    check(!p::finite_riding_output(altered,fixture.rig),"nonfinite quaternion rejected");altered=fixture.bones;altered[7].position[0]=std::numeric_limits<float>::infinity();
    check(!p::finite_riding_output(altered,fixture.rig),"nonfinite XYZ rejected");
    auto short_arm=fixture;short_arm.bones[static_cast<unsigned>(fixture.rig.left_arm[2])].position[0]*=.3f;
    auto working=short_arm.bones;const auto refused=p::solve(working,short_arm.rig,f);
    check(!refused.ready&&!refused.forearm_repair_applied,"unrepairable contact failure cannot become a private write-ready result");
}
int main(){policy_checks();const auto fixture=actual276::get();original_matrix(fixture);nearby_and_mixed(fixture);boundary_sequence(fixture);excluded_and_invalid(fixture);
    check(new_failures==0,"no new anatomy/contact failures");
    check(baseline_failures==repaired+retained_excluded_failures&&retained_excluded_failures==12,"12 mixed-cue failures remain explicitly excluded baseline cases");
    std::printf("PASS %u checks; %u cases; baseline failures=%u repaired=%u excluded baseline failures=%u valid baseline byte-preserved=%u; max extra drop=%.9f hand=%.9f foot=%.9f m; sequence XYZ=%.9f m rotation=%.9f rad\n",
        checks,cases,baseline_failures,repaired,retained_excluded_failures,valid_baseline_preserved,maximum_drop,maximum_hand,maximum_foot,maximum_sequence_step,maximum_sequence_rotation);
}
