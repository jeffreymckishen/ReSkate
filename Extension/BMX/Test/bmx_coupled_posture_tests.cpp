#include "Extension/BMX/bmx_coupled_posture_delta.h"
#include "fixtures/bmx_coupled_native_pose.h"
#include <bmx/suspension.hpp>
#include <cstring>
#include <iostream>
#include <limits>

namespace cp=dingosdk::bmx::rider::coupled_posture;
namespace p=dingosdk::bmx::rider::pose;
namespace ab=dingosdk::bmx::avatar_binding;
namespace np=dingosdk::bmx::native_coupled::policy;
namespace cat=dingosdk::bmx::catalog;
namespace sc=::bmx::detail::source::catalog;
unsigned assertions{},loaded_nonzero{},trick_nonzero{},released_contact_cases{};
void check(bool v,const char* text){++assertions;if(!v){std::cerr<<text<<'\n';std::exit(1);}}
bool close(float a,float b,float e=.00001f){return std::abs(a-b)<e;}
bool close(np::Vec a,np::Vec b,float e=.00001f){return np::length(ab::sub(a,b))<e;}
struct Data {
    actual276::Fixture fixture=actual276::get();p::SpringBinding binding;
    std::vector<p::Bone> mounted;ab::Observation actual;
    ::bmx::RiderSettings settings=::bmx::streets_observed_v2().movement.rider;
    cp::NeutralFrame neutral;
    Data(){
        check(fixture.bones.size()==395&&fixture.rig.parents.size()==386,"actual276 captured native rig shape");
        mounted=fixture.bones;const auto r=p::solve(mounted,fixture.rig,fixture.frame,nullptr,false,&binding);
        check(r.ready&&r.spring_calibrated&&r.hand_error<.003f&&r.foot_error<.003f,"actual276 completed mounted neutral calibration replay");
        actual=fixture.frame.spring_avatar.actual;
        // Synthetic successor of the genuine frozen endpoint, with unchanged
        // actual body transforms: this is a portable test, not native epoch proof.
        ++actual.epoch.serial;actual.epoch.time+=double(actual.epoch.seconds);
        const auto profile=::bmx::streets_observed_v2();
        neutral.center_from_bike_root=profile.coupled.rider_neutral_com_from_root;
        neutral.orientation_from_bike=profile.coupled.rider_orientation_from_chassis;
        const auto g=p::compose(mounted,fixture.rig);
        const auto average=[&](auto a,auto b,unsigned i,unsigned j){return .5*(p::length(p::sub(g[static_cast<std::size_t>(a[i])].position,g[static_cast<std::size_t>(a[j])].position))+
            p::length(p::sub(g[static_cast<std::size_t>(b[i])].position,g[static_cast<std::size_t>(b[j])].position)));};
        settings.upper_arm=average(fixture.rig.left_arm,fixture.rig.right_arm,0,1);
        settings.forearm=average(fixture.rig.left_arm,fixture.rig.right_arm,1,2);
        settings.thigh=average(fixture.rig.left_leg,fixture.rig.right_leg,0,1);
        settings.shin=average(fixture.rig.left_leg,fixture.rig.right_leg,1,2);
        check(cp::settings_valid(settings),"actual native segment lengths satisfy module settings contract");
    }
    cp::Motion motion(double preload=0) const {
        cp::Motion m;m.selected=m.committed=m.logical.valid=true;
        m.accepted_epoch=fixture.frame.spring_avatar.actual.epoch;m.logical.actions.preload=preload;return m;
    }
    p::SpringTargets targets() const {
        p::SpringTargets s;s.hip=ab::add(actual.spring_com,np::rotate(actual.spring_orientation,binding.local_hip));
        s.chest=ab::add(actual.spring_com,np::rotate(actual.spring_orientation,binding.local_chest));
        s.hip_rotation=np::multiply(actual.spring_orientation,binding.local_hip_basis);s.model_rotation=actual.spring_orientation;return s;
    }
};
void neutral_and_preload(){
    const Data d;auto m=d.motion();const auto before=m;const auto body=d.actual;
    const auto zero=cp::sample(m,d.actual,d.settings,d.neutral);check(zero.ready,"neutral is a valid zero presentation delta");
    check(zero.hip_world==np::Vec{}&&zero.chest_world==np::Vec{},"neutral subtraction has exact zero deltas");
    const auto target=d.targets();const auto applied=cp::apply(zero,d.actual.epoch,target.hip,target.chest,1);
    check(applied.ready&&std::memcmp(applied.hip.data(),target.hip.data(),sizeof(target.hip))==0&&
          std::memcmp(applied.chest.data(),target.chest.data(),sizeof(target.chest))==0,"exact native calibration targets retain bytes at neutral");
    check(std::memcmp(&m,&before,sizeof(m))==0&&d.actual.epoch==body.epoch&&d.actual.spring_com==body.spring_com,"pure sampler leaves logical/native inputs untouched");
    double previous{};const auto up=np::rotate(d.actual.spring_orientation,{0,1,0});
    for(double preload:{.25,.5,.75,1.}){
        const auto delta=cp::sample(d.motion(preload),d.actual,d.settings,d.neutral);check(delta.ready,"bounded source-profile preload admitted");
        const double length=np::length(delta.hip_world);check(length>previous&&std::abs(length-d.settings.preload_crouch*preload)<.000001,"module preload crouch is monotonic source-profile magnitude");previous=length;
        check(p::dot(delta.hip_world,up)<0&&std::abs(np::length(delta.chest_world)-length*d.settings.chest_preload_fraction)<.000001,"hip/chest delta follows measured Spring up and source fraction");
    }
    auto poisoned=d.motion(.5);poisoned.logical.body.center_of_mass={NAN,NAN,NAN};poisoned.logical.rider.hips={INFINITY,INFINITY,INFINITY};
    poisoned.logical.bike_root={-999999,-999999,-999999};poisoned.logical.force={INFINITY,0,0};
    const auto a=cp::sample(poisoned,d.actual,d.settings,d.neutral),b=cp::sample(d.motion(.5),d.actual,d.settings,d.neutral);
    check(a.ready&&a.hip_world==b.hip_world&&a.chest_world==b.chest_world,"retained/predicted body and world targets are never used");
    auto rotated=d.actual;rotated.spring_orientation=np::multiply(p::axis(2,.5f),rotated.spring_orientation);
    const auto moved=cp::sample(d.motion(.5),rotated,d.settings,d.neutral);
    check(moved.ready&&close(moved.hip_world,np::rotate(p::axis(2,.5f),b.hip_world)),"delta is recomputed in CURRENT actual Spring rotation");
    auto off=d.motion(.5);off.selected=false;check(!cp::sample(off,d.actual,d.settings,d.neutral).ready,"explicit opt-out has no target delta");
    const auto strength0=cp::apply(b,d.actual.epoch,target.hip,target.chest,0);
    check(strength0.ready&&strength0.hip==target.hip&&strength0.chest==target.chest,"candidate fallback0 preserves calibrated target exactly");
}
void guards(){
    const Data d;const auto good=d.motion(.5);
    auto m=good;m.committed=false;check(cp::sample(m,d.actual,d.settings,d.neutral).issue==cp::Issue::uncommitted,"unacknowledged logical state refused");
    for(unsigned i=0;i<8;++i){m=good;++m.accepted_epoch.owner_world[i];check(cp::sample(m,d.actual,d.settings,d.neutral).issue==cp::Issue::stale_logical,"every foreign owner/world field refused");}
    for(unsigned role=0;role<2;++role)for(unsigned field=0;field<3;++field){m=good;auto& key=m.accepted_epoch.bodies[role];
        if(field==0)++key.world;else if(field==1)++key.index;else ++key.generation;
        check(!cp::sample(m,d.actual,d.settings,d.neutral).ready,"every foreign actual body identity refused");}
    m=good;++m.accepted_epoch.token;check(!cp::sample(m,d.actual,d.settings,d.neutral).ready,"foreign physical token refused");
    for(unsigned mode=0;mode<6;++mode){m=good;
        if(mode==0)++m.accepted_epoch.serial;else if(mode==1)--m.accepted_epoch.serial;else if(mode==2)m.accepted_epoch.time+=.001;
        else if(mode==3)m.accepted_epoch.seconds=.01f;else if(mode==4)m.accepted_epoch.serial=UINT64_MAX;else m.accepted_epoch.time=NAN;
        check(!cp::sample(m,d.actual,d.settings,d.neutral).ready,"same/stale/gap/rewind/native-h/overflow clocks refused");}
    for(unsigned mode=0;mode<7;++mode){auto a=d.actual;
        if(mode==0)a.available=false;else if(mode==1)a.epoch.owner_world[0]=0;else if(mode==2)a.spring_com[1]=NAN;
        else if(mode==3)a.spring_orientation={0,0,0,0};else if(mode==4)a.spring_velocity={51,0,0};
        else if(mode==5)a.epoch.bodies[1].index=a.epoch.bodies[0].index;else a.bike_root={INFINITY,0,0};
        check(!cp::sample(good,a,d.settings,d.neutral).ready,"invalid actual Spring/body epoch cannot provide targets");}
    for(double value:{-1.,1.01,std::numeric_limits<double>::quiet_NaN(),std::numeric_limits<double>::infinity()}){m=good;m.logical.actions.preload=value;check(!cp::sample(m,d.actual,d.settings,d.neutral).ready,"invalid accepted preload refused");}
    m=good;m.logical.valid=false;check(!cp::sample(m,d.actual,d.settings,d.neutral).ready,"invalid accepted output refused");
    m=good;m.logical.tricks.movement_id=static_cast<sc::TrickId>(200);check(!cp::sample(m,d.actual,d.settings,d.neutral).ready,"uncatalogued selection refused");
    m=good;m.logical.tricks.movement_phase=.5;check(!cp::sample(m,d.actual,d.settings,d.neutral).ready,"none selection cannot fabricate trick phase");
    for(unsigned mode=0;mode<6;++mode){auto settings=d.settings;
        if(mode==0)settings.upper_arm=NAN;else if(mode==1)settings.forearm=0;else if(mode==2)settings.motion_scale=3;
        else if(mode==3)settings.shoulder_axis={0,0,0};else if(mode==4)settings.elbow_poles[0]={0,0,0};else settings.chest_preload_fraction=1.01;
        check(!cp::sample(good,d.actual,settings,d.neutral).ready,"invalid measured native dimensions/config refused");}
    auto settings=d.settings;settings.preload_crouch=1;
    check(cp::sample(d.motion(1),d.actual,settings,d.neutral).issue==cp::Issue::over_bound,"oversized proximal request rejected, never clamped into apparently valid motion");
    auto neutral=d.neutral;neutral.orientation_from_bike={0,0,0,0};check(!cp::sample(good,d.actual,d.settings,neutral).ready,"invalid neutral source frame refused");
    neutral=d.neutral;neutral.center_from_bike_root[1]=3;check(!cp::sample(good,d.actual,d.settings,neutral).ready,"oversized neutral source frame refused");
    const auto delta=cp::sample(good,d.actual,d.settings,d.neutral);const auto target=d.targets();auto current=d.actual.epoch;
    ++current.serial;current.time+=double(current.seconds);check(!cp::apply(delta,current,target.hip,target.chest,1).ready,"application cannot reuse delta at later actual epoch");
    current=d.actual.epoch;++current.token;check(!cp::apply(delta,current,target.hip,target.chest,1).ready,"application cannot reuse delta on foreign actual token");
    for(float strength:{-1.f,1.01f,NAN,INFINITY})check(!cp::apply(delta,d.actual.epoch,target.hip,target.chest,strength).ready,"invalid candidate strength refused");
    auto forged=delta;forged.hip_world={.2f,.2f,.2f};check(!cp::apply(forged,d.actual.epoch,target.hip,target.chest,1).ready,"application rechecks delta length, not only components");
}
void candidate_and_released_targets(){
    const Data d;const auto native=d.targets();
    for(double preload:{.25,.5,1.}){
        auto frame=d.fixture.frame;frame.preload=static_cast<float>(preload);
        const auto delta=cp::sample(d.motion(preload),d.actual,d.settings,d.neutral);check(delta.ready,"loaded native-rig delta available");
        bool adopted=false;
        for(float strength:{1.f,.5f,0.f}){
            auto candidate=d.mounted;for(int i:p::changed(d.fixture.rig))candidate[static_cast<std::size_t>(i)].rotation=d.fixture.rig.bind[static_cast<std::size_t>(i)];
            auto targets=native;const auto t=cp::apply(delta,d.actual.epoch,native.hip,native.chest,strength);check(t.ready,"guarded target candidate constructed");targets.hip=t.hip;targets.chest=t.chest;
            const auto solved=p::solve_riding_candidate(candidate,d.fixture.rig,frame,strength,nullptr,&targets);
            if(!solved.ready||solved.hand_error>=.003f||solved.foot_error>=.003f||!p::proposed_small_bike_anatomy(candidate,d.fixture.rig,frame))continue;
            check(solved.hand_error<.003f&&solved.foot_error<.003f,"nonzero loaded candidate retains strict intended contacts");
            for(std::size_t i=0;i<candidate.size();++i){check(std::memcmp(candidate[i].scale.data(),d.mounted[i].scale.data(),sizeof(candidate[i].scale))==0,"native scale/metadata unmodified");
                if(i!=static_cast<std::size_t>(d.fixture.rig.hips))check(std::memcmp(candidate[i].position.data(),d.mounted[i].position.data(),sizeof(candidate[i].position))==0,"no new native translation channel");}
            if(strength>0){++loaded_nonzero;adopted=true;}break;
        }
        check(adopted,"actual276 anatomy admits a NONZERO preload cue, not only zero fallback");
    }
    for(const auto id:{sc::TrickId::one_hander_left,sc::TrickId::superman,sc::TrickId::nothing}){
        auto motion=d.motion();motion.logical.tricks.movement_id=id;motion.logical.tricks.movement_phase=.7;motion.logical.tricks.movement_progress=.5;
        const auto delta=cp::sample(motion,d.actual,d.settings,d.neutral);check(delta.ready,"accepted catalog procedural delta bounded");
        if(np::length(delta.hip_world)+np::length(delta.chest_world)>0)++trick_nonzero;
        auto frame=d.fixture.frame;frame.movement_id=static_cast<cat::TrickId>(id);frame.movement_phase=.7f;frame.movement_progress=.5f;frame.airborne=true;
        const auto* entry=cat::find(frame.movement_id);check(entry!=nullptr,"matching current native catalog exists");
        frame.release_left_hand=(entry->release_mask&1)?1.f:0.f;frame.release_right_hand=(entry->release_mask&2)?1.f:0.f;
        frame.release_left_foot=(entry->release_mask&4)?1.f:0.f;frame.release_right_foot=(entry->release_mask&8)?1.f:0.f;
        bool adopted=false;
        for(float strength:{1.f,.5f,0.f}){
            auto candidate=d.mounted;for(int i:p::changed(d.fixture.rig))candidate[static_cast<std::size_t>(i)].rotation=d.fixture.rig.bind[static_cast<std::size_t>(i)];
            auto targets=native;const auto t=cp::apply(delta,d.actual.epoch,native.hip,native.chest,strength);targets.hip=t.hip;targets.chest=t.chest;
            const auto r=p::solve_riding_candidate(candidate,d.fixture.rig,frame,strength,nullptr,&targets);
            if(!r.ready||r.hand_error>=.003f||r.foot_error>=.003f||!p::proposed_small_bike_anatomy(candidate,d.fixture.rig,frame))continue;
            const auto g=p::compose(candidate,d.fixture.rig);
            for(bool left:{true,false}){
                const auto wrist=g[static_cast<std::size_t>(left?d.fixture.rig.left_arm[2]:d.fixture.rig.right_arm[2])];
                const auto palm=p::add(wrist.position,p::turn(wrist.rotation,p::mul(p::palm_bar_offset(left),wrist.scale)));
                check(p::length(p::sub(palm,p::palm_target(frame,left)))<.003f,"strict hand error is intended solved target");
                if(p::hand_release(frame,left)>0){check(p::length(p::sub(palm,p::grip(frame,left)))>.01f,"released palm may leave bars while planned-target error remains below3mm");++released_contact_cases;}
                else check(p::length(p::sub(palm,p::grip(frame,left)))<.003f,"closed palm remains on actual grip");
                const auto ankle=g[static_cast<std::size_t>(left?d.fixture.rig.left_leg[2]:d.fixture.rig.right_leg[2])].position;
                check(p::length(p::sub(ankle,p::foot_target(frame,left)))<.003f,"strict foot error is intended solved target");
                if(p::foot_release(frame,left)==0)check(p::length(p::sub(ankle,p::pedal(frame,left)))<.003f,"closed ankle remains on current pedal");
            }
            adopted=true;break;
        }
        check(adopted,"released-target semantics exercised with actual276 rig");
        motion.logical.tricks.movement_phase=0;motion.logical.tricks.movement_progress=1;
        const auto endpoint=cp::sample(motion,d.actual,d.settings,d.neutral);check(endpoint.ready&&endpoint.hip_world==np::Vec{}&&endpoint.chest_world==np::Vec{},"catalog phase endpoint restores exact neutral deltas");
    }
    check(loaded_nonzero==3&&trick_nonzero>0&&released_contact_cases>0,"portable tests exercise actual nonzero preload/trick and released contacts");
}
void integrated_native_solver(){
    Data d;auto frame=d.fixture.frame;frame.spring_avatar.actual=d.actual;
    frame.coupled_motion_epoch=d.fixture.frame.spring_avatar.actual.epoch;
    frame.coupled_motion_committed=true;frame.preload=.5f;
    d.binding.completed_pose_write=true;
    auto baseline=d.fixture.bones;auto base_binding=d.binding;
    const auto old=p::solve(baseline,d.fixture.rig,frame,nullptr,false,&base_binding);
    check(old.ready&&old.spring_applied&&!old.coupled_posture_applied,"opt-out retains the calibrated bound native pose");
    auto enabled=frame;enabled.coupled_posture_selected=true;
    auto animated=d.fixture.bones;auto live_binding=d.binding;
    const auto moved=p::solve(animated,d.fixture.rig,enabled,nullptr,false,&live_binding);
#if defined(DINGOSDK_BMX_STANDALONE_MOVEMENT) && defined(DINGOSDK_BMX_NATIVE_COUPLED)
    check(moved.ready&&moved.coupled_posture_requested&&moved.coupled_posture_applied&&moved.posture_scale>0,
        "actual native solver adopts a nonzero acknowledged procedural preload");
    check(moved.hand_error<.003f&&moved.foot_error<.003f&&p::proposed_small_bike_anatomy(animated,d.fixture.rig,enabled),
        "integrated procedural candidate retains native anatomy and strict intended contacts");
    const auto old_world=p::compose(baseline,d.fixture.rig),new_world=p::compose(animated,d.fixture.rig);
    check(p::length(p::sub(old_world[static_cast<std::size_t>(d.fixture.rig.hips)].position,new_world[static_cast<std::size_t>(d.fixture.rig.hips)].position))>.02f,
        "integration moves the actual solved hips rather than only returning a delta");
    for(std::size_t i=0;i<animated.size();++i){
        // Captured bones376/377 carry NaN metadata W=0xFFC00000 in scale.
        // Float equality rejects an unchanged NaN. Preserve all four raw lanes,
        // including metadata and signed zero, using exact bitwise comparison.
        check(std::memcmp(animated[i].scale.data(),d.fixture.bones[i].scale.data(),sizeof(animated[i].scale))==0,
            "integrated motion preserves native scales and metadata bits");
        if(i!=static_cast<std::size_t>(d.fixture.rig.hips))check(
            std::memcmp(animated[i].position.data(),d.fixture.bones[i].position.data(),sizeof(animated[i].position))==0,
            "integrated motion preserves every nonpelvis native translation");
    }
    for(unsigned refusal=0;refusal<5;++refusal){
        auto refused=enabled;auto binding=d.binding;
        if(refusal==0)refused.coupled_motion_committed=false;
        if(refusal==1)++refused.coupled_motion_epoch.serial;
        if(refusal==2)++refused.coupled_motion_epoch.owner_world[1];
        if(refusal==3)++refused.coupled_motion_epoch.token;
        if(refusal==4)binding.completed_pose_write=false;
        auto bones=d.fixture.bones;const auto result=p::solve(bones,d.fixture.rig,refused,nullptr,false,&binding);
        check(result.ready&&!result.coupled_posture_applied&&std::memcmp(bones.data(),baseline.data(),bones.size()*sizeof(p::Bone))==0,
            "uncommitted/stale/foreign cue or incomplete render preserves exact calibrated baseline");
    }
    auto neutral=enabled;neutral.preload=0;
    auto neutral_off=neutral;neutral_off.coupled_posture_selected=false;
    auto a=d.fixture.bones,b=d.fixture.bones;auto ba=d.binding,bb=d.binding;
    const auto ra=p::solve(a,d.fixture.rig,neutral,nullptr,false,&ba),rb=p::solve(b,d.fixture.rig,neutral_off,nullptr,false,&bb);
    check(ra.ready&&rb.ready&&!ra.coupled_posture_applied&&std::memcmp(a.data(),b.data(),a.size()*sizeof(p::Bone))==0,
        "enabled neutral preserves exact existing native solve bytes");
    auto calibration=d.fixture.frame;calibration.coupled_posture_selected=calibration.coupled_motion_committed=true;
    calibration.coupled_motion_epoch=frame.coupled_motion_epoch;
    a=d.fixture.bones;b=d.fixture.bones;ba={};bb={};auto calibration_off=calibration;calibration_off.coupled_posture_selected=false;
    const auto ca=p::solve(a,d.fixture.rig,calibration,nullptr,false,&ba),cb=p::solve(b,d.fixture.rig,calibration_off,nullptr,false,&bb);
    check(ca.ready&&cb.ready&&ca.spring_calibrated&&!ca.coupled_posture_applied&&std::memcmp(a.data(),b.data(),a.size()*sizeof(p::Bone))==0,
        "first genuine quiet calibration is unchanged despite optional cue selection");
    auto foreign=enabled;++foreign.entity;a=d.fixture.bones;ba=d.binding;
    check(!p::solve(a,d.fixture.rig,foreign,nullptr,false,&ba).ready&&std::memcmp(a.data(),d.fixture.bones.data(),a.size()*sizeof(p::Bone))==0,
        "foreign rider ownership refuses entire bound pose before mutation");
#else
    check(moved.ready&&!moved.coupled_posture_requested&&!moved.coupled_posture_applied&&
        std::memcmp(animated.data(),baseline.data(),animated.size()*sizeof(p::Bone))==0,
        "compile-disabled procedural route preserves exact native baseline even with a selected frame");
#endif
}
int main(){neutral_and_preload();guards();candidate_and_released_targets();integrated_native_solver();
    std::cout<<assertions<<" pure actual-rig assertions passed; nonzero preload="<<loaded_nonzero<<" procedural catalog="<<trick_nonzero<<" released hand cases="<<released_contact_cases<<'\n';}
