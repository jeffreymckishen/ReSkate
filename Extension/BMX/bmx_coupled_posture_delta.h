#pragma once
#include "Engine/Game/BMX/bmx_spring_avatar_binding.h"
#include <bmx/movement.hpp>
#include <algorithm>
#include <cmath>
#include <limits>

// Pure procedural presentation adapter. Native integration and ownership,
// placement, completed calibration and contact acceptance remain caller gates.
// This never adopts retained/predicted world poses or moves a physical body.
namespace dingosdk::bmx::rider::coupled_posture {
namespace ab=avatar_binding;namespace np=native_coupled::policy;
using Vec=np::Vec;using Quat=np::Quat;
enum class Issue {disabled,uncommitted,invalid_actual,stale_logical,invalid_motion,invalid_settings,over_bound,ready};
struct Motion {
    bool selected{},committed{};
    np::Epoch accepted_epoch;
    ::bmx::Output logical; // ONLY valid,preload and accepted catalog phase are read.
};
struct NeutralFrame {
    ::bmx::Vec3 center_from_bike_root{};
    ::bmx::Quat orientation_from_bike{0,0,0,1};
};
struct Delta {
    bool ready{};Issue issue{Issue::disabled};
    np::Epoch source_epoch,actual_epoch;
    Vec hip_world{},chest_world{};
};
// Explicit presentation limits, not recovered Streets configuration.
inline constexpr double maximum_hip_delta=.25,maximum_chest_delta=.30;
inline bool finite(const ::bmx::Vec3& v,double bound) noexcept {
    for(double x:v)if(!std::isfinite(x)||std::abs(x)>bound)return false;
    return true;
}
inline bool unit(const ::bmx::Quat& q) noexcept {
    double n{};for(double x:q){if(!std::isfinite(x))return false;n+=x*x;}
    return std::abs(n-1)<=.00001;
}
inline double length(const ::bmx::Vec3& v) noexcept {return std::hypot(v[0],v[1],v[2]);}
inline bool settings_valid(const ::bmx::RiderSettings& s) noexcept {
    for(double v:{s.upper_arm,s.forearm,s.thigh,s.shin})if(!std::isfinite(v)||v<.05||v>1.5)return false;
    for(double v:{s.shoulder_half_width,s.hip_joint_half_width})if(!std::isfinite(v)||v<.01||v>.5)return false;
    for(const auto& v:{s.hips,s.chest,s.head_from_chest,s.shoulder_center_from_chest,s.hip_joint_center_from_hips})
        if(!finite(v,5))return false;
    for(const auto& v:{s.shoulder_axis,s.hip_joint_axis})if(!finite(v,1)||std::abs(length(v)-1)>.000005)return false;
    for(const auto& poles:{s.elbow_poles,s.knee_poles})for(const auto& v:poles)if(!finite(v,5)||length(v)<.0001)return false;
    return std::isfinite(s.motion_scale)&&s.motion_scale>=0&&s.motion_scale<=2&&
        std::isfinite(s.preload_crouch)&&s.preload_crouch>=0&&s.preload_crouch<=1&&
        std::isfinite(s.chest_preload_fraction)&&s.chest_preload_fraction>=0&&s.chest_preload_fraction<=1;
}
inline bool next_actual(const np::Epoch& before,const np::Epoch& actual) noexcept {
    return ab::same_identity(before,actual)&&before.serial!=std::numeric_limits<std::uint64_t>::max()&&
        actual.serial==before.serial+1&&actual.seconds==before.seconds&&actual.time==before.time+double(before.seconds);
}
inline bool motion_valid(const ::bmx::Output& o) noexcept {
    const auto& t=o.tricks;
    if(!o.valid||!std::isfinite(o.actions.preload)||o.actions.preload<0||o.actions.preload>1||
       !std::isfinite(t.movement_phase)||t.movement_phase<0||t.movement_phase>1||
       !std::isfinite(t.movement_progress)||t.movement_progress<0||t.movement_progress>1)return false;
    using Id=::bmx::detail::source::catalog::TrickId;
    if(t.movement_id==Id::none)return t.movement_phase==0&&t.movement_progress==0&&!t.movement_holding&&!t.movement_recovering;
    return ::bmx::detail::source::catalog::find(t.movement_id)&&!(t.movement_holding&&t.movement_recovering)&&
        (!(t.movement_holding||t.movement_recovering)||t.movement_progress==1);
}
inline Delta sample(const Motion& motion,const ab::Observation& actual,const ::bmx::RiderSettings& native_settings,
                    const NeutralFrame& neutral) noexcept {
    Delta out;
    if(!motion.selected)return out;
    if(!motion.committed){out.issue=Issue::uncommitted;return out;}
    if(!ab::valid(actual)){out.issue=Issue::invalid_actual;return out;}
    if(!next_actual(motion.accepted_epoch,actual.epoch)){out.issue=Issue::stale_logical;return out;}
    if(!motion_valid(motion.logical)){out.issue=Issue::invalid_motion;return out;}
    if(!settings_valid(native_settings)||!finite(neutral.center_from_bike_root,2)||!unit(neutral.orientation_from_bike)){
        out.issue=Issue::invalid_settings;return out;
    }
    np::Quat bike_q,spring_q;
    if(!np::unit(actual.bike_orientation,bike_q)||!np::unit(actual.spring_orientation,spring_q)){
        out.issue=Issue::invalid_actual;return out;
    }
    ::bmx::RiderFrame current;
    for(unsigned i=0;i<3;++i)current.center_of_mass[i]=actual.spring_com[i];
    for(unsigned i=0;i<4;++i)current.orientation[i]=spring_q[i];
    current.neutral_center_from_bike_root=neutral.center_from_bike_root;
    current.neutral_orientation_from_bike=neutral.orientation_from_bike;
    // Reconstruct only accepted logical pose fields. In particular, the retained
    // output's body/rider/world positions are neither validated nor adopted.
    ::bmx::Output animated;
    animated.valid=true;animated.physical_trick_rotation=true;
    for(unsigned i=0;i<3;++i)animated.bike_root[i]=actual.bike_root[i];
    for(unsigned i=0;i<4;++i)animated.body.orientation[i]=bike_q[i];
    animated.actions.preload=motion.logical.actions.preload;
    animated.tricks.movement_id=motion.logical.tricks.movement_id;
    animated.tricks.movement_phase=motion.logical.tricks.movement_phase;
    animated.tricks.movement_progress=motion.logical.tricks.movement_progress;
    auto resting=animated;resting.actions.preload=0;resting.tricks={};
    const auto moved=::bmx::rider_pose(animated,native_settings,&current);
    const auto baseline=::bmx::rider_pose(resting,native_settings,&current);
    ::bmx::Vec3 hips{},chest{};
    for(unsigned i=0;i<3;++i){hips[i]=moved.hips[i]-baseline.hips[i];chest[i]=moved.chest[i]-baseline.chest[i];}
    if(!finite(hips,maximum_hip_delta)||!finite(chest,maximum_chest_delta)||
       length(hips)>maximum_hip_delta||length(chest)>maximum_chest_delta){out.issue=Issue::over_bound;return out;}
    for(unsigned i=0;i<3;++i){out.hip_world[i]=static_cast<float>(hips[i]);out.chest_world[i]=static_cast<float>(chest[i]);}
    out.source_epoch=motion.accepted_epoch;out.actual_epoch=actual.epoch;
    out.ready=true;out.issue=Issue::ready;return out;
}
struct Targets {bool ready{};Vec hip{},chest{};};
inline Targets apply(const Delta& delta,const np::Epoch& current,const Vec& calibrated_hip,const Vec& calibrated_chest,float strength) noexcept {
    Targets out;
    if(!delta.ready||delta.issue!=Issue::ready||current!=delta.actual_epoch||!next_actual(delta.source_epoch,delta.actual_epoch)||!np::finite(delta.hip_world,static_cast<float>(maximum_hip_delta))||
       !np::finite(delta.chest_world,static_cast<float>(maximum_chest_delta))||
       np::length(delta.hip_world)>maximum_hip_delta||np::length(delta.chest_world)>maximum_chest_delta||
       !np::finite(calibrated_hip)||!np::finite(calibrated_chest)||!std::isfinite(strength)||strength<0||strength>1)return out;
    out.hip=calibrated_hip;out.chest=calibrated_chest;
    // Exactly neutral/disabled strength preserves the calibrated vector bytes,
    // including signed zero. No add-zero operation changes the neutral result.
    if(strength!=0)for(unsigned i=0;i<3;++i){
        if(delta.hip_world[i]!=0)out.hip[i]+=delta.hip_world[i]*strength;
        if(delta.chest_world[i]!=0)out.chest[i]+=delta.chest_world[i]*strength;
    }
    out.ready=np::finite(out.hip)&&np::finite(out.chest);return out;
}
}
