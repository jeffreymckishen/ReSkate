#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace dingosdk::bmx::grip_probe_policy {
inline constexpr std::size_t capacity=128;
// This window follows SDK Frame.airborne, not a native contact or GPU fence.
// Four consecutive observed native serials avoid the ramp's two-step lip gap.
struct Window {
    std::uintptr_t owner{};std::uint64_t token{},last_serial{};double last_time{};
    unsigned air_steps{},count{},duplicates{},missing_clock{},serial_gaps{},busy{};
    bool armed{},sealed{},owner_changed{},clock_rewound{};
    bool observe(std::uintptr_t entity,std::uint64_t mount_token,bool clock_available,
                 std::uint64_t serial,double time,bool airborne) noexcept {
        if(sealed)return false;
        if(!clock_available||!serial||!std::isfinite(time)){++missing_clock;return false;}
        if(owner&&(owner!=entity||token!=mount_token)){owner_changed=sealed=true;return false;}
        if(!owner){owner=entity;token=mount_token;}
        if(last_serial&&serial==last_serial){++duplicates;return false;}
        if(last_serial&&(serial<last_serial||time<=last_time)){clock_rewound=sealed=true;return false;}
        if(last_serial&&serial!=last_serial+1){++serial_gaps;air_steps=0;}
        last_serial=serial;last_time=time;
        air_steps=airborne?air_steps+1:0;
        if(!armed&&air_steps>=4)armed=true;
        if(!armed)return false;
        if(++count==capacity)sealed=true;
        return true;
    }
};
struct Owner {
    std::uintptr_t client{},entity{},core{},context{},rig{};
    bool operator==(const Owner&) const=default;
};
inline bool complete(const Owner& x) noexcept {return x.client&&x.entity&&x.core&&x.context&&x.rig;}
// Readback is an observation only after fresh existing ownership/layout guards.
// A lease epoch is SDK historical association, never native write completion.
struct Edge {
    std::uintptr_t entity{},core{},context{},rig{},client{};
    std::uint64_t epoch{},lease_revision{},serial{};double time{};
    bool clock{},lease{},active{},epoch_valid{};
    Owner actual_owner{};bool actual_available{};
};
inline Owner lease_owner(const Edge& x) noexcept {return {x.client,x.entity,x.core,x.context,x.rig};}
inline bool owner_joined(const Edge& x) noexcept {
    return x.actual_available&&complete(x.actual_owner)&&x.actual_owner==lease_owner(x);
}
inline bool same_admission(const Edge& source,const Edge& before,const Edge& after) noexcept {
    const auto valid=[](const Edge& x){return x.clock&&x.lease&&x.active&&x.epoch_valid&&x.entity&&x.core&&x.context&&x.rig&&x.client&&
        x.serial&&std::isfinite(x.time)&&x.epoch&&x.epoch==x.lease_revision&&owner_joined(x);};
    const auto same=[&](const Edge& x){return valid(x)&&x.entity==source.entity&&x.core==source.core&&
        x.context==source.context&&x.rig==source.rig&&x.client==source.client&&x.epoch==source.epoch&&
        x.lease_revision==source.lease_revision&&x.serial==source.serial&&x.time==source.time&&x.actual_owner==source.actual_owner;};
    return valid(source)&&same(before)&&same(after);
}

// The stationary selector is independent of the retained airborne-ramp probe.
// Its caller proves the exact private root and launch mode before setting these
// booleans; none of these observations grants a pose, physics or input write.
struct StationaryScope {bool requested{},native_chassis{},human_ride{},private_profile{},conflict{};};
inline bool stationary_selected(const StationaryScope& s) noexcept {
    return s.requested&&s.native_chassis&&s.human_ride&&s.private_profile&&!s.conflict;
}
inline constexpr unsigned stationary_settle_samples=30;
inline constexpr std::uint64_t stationary_arm_ms=30000,stationary_capture_ms=10000;
inline constexpr double stationary_maximum_speed=.04,stationary_maximum_angular_speed=.25,stationary_maximum_drift=.02,stationary_maximum_rotation_drift=.02;
enum class StationaryStop {unused,waiting,settling,capturing,complete,timeout,owner_changed,clock_rewound,serial_gap,activity,scope_changed,withdrawn};
inline const char* name(StationaryStop s) noexcept {
    switch(s){case StationaryStop::unused:return "not_requested";case StationaryStop::waiting:return "waiting_for_stationary_presentation";
    case StationaryStop::settling:return "waiting_for_30_stable_native_samples";case StationaryStop::capturing:return "capturing_stationary_presentation";
    case StationaryStop::complete:return "bounded_capture_complete";case StationaryStop::timeout:return "bounded_wall_timeout";
    case StationaryStop::owner_changed:return "owner_or_native_body_token_changed";case StationaryStop::clock_rewound:return "wall_or_native_clock_rewound";
    case StationaryStop::serial_gap:return "native_serial_gap_after_arm";case StationaryStop::activity:return "stationary_presentation_lost_after_arm";
    case StationaryStop::scope_changed:return "private_scope_changed";case StationaryStop::withdrawn:return "riding_publication_withdrawn";}
    return "unknown";
}
struct StationarySample {
    Owner owner;std::uint64_t token{},wall{},serial{},lease_serial{};double time{},lease_time{},seconds{};
    std::array<float,3> position{},requested_velocity{};std::array<float,4> rotation{0,0,0,1};
    bool associated{},fully_mounted{},grounded_presentation{},quiet_presentation{};
};
struct StationaryWindow {
    Owner owner;std::uint64_t token{},requested_wall{},capture_wall{},last_wall{},last_serial{};double last_time{},last_seconds{};
    std::array<float,3> previous_position{},anchor{};std::array<float,4> previous_rotation{0,0,0,1},anchor_rotation{0,0,0,1};
    double maximum_step_speed{},maximum_angular_speed{},maximum_root_drift{},maximum_rotation_drift{},maximum_requested_speed{};
    unsigned stable_samples{},count{},duplicates{},invalid_samples{},serial_gaps{};
    bool used{},armed{},sealed{},have_previous{};StationaryStop stop{StationaryStop::unused};
    void finish(StationaryStop why) noexcept {if(used&&!sealed){sealed=true;stop=why;}}
    bool request(std::uint64_t now) noexcept {
        if(used||!now||now>std::numeric_limits<std::uint64_t>::max()-stationary_arm_ms)return false;
        used=true;requested_wall=last_wall=now;stop=StationaryStop::waiting;return true;
    }
    void expire(std::uint64_t now) noexcept {
        if(!used||sealed)return;
        if(now<last_wall){finish(StationaryStop::clock_rewound);return;}last_wall=now;
        const auto start=armed?capture_wall:requested_wall,limit=armed?stationary_capture_ms:stationary_arm_ms;
        if(now<start||now-start>=limit)finish(StationaryStop::timeout);
    }
    bool observe(const StationarySample& s) noexcept {
        if(!used||sealed)return false;
        expire(s.wall);if(sealed)return false;
        if(complete(owner)&&(owner!=s.owner||token!=s.token)){finish(StationaryStop::owner_changed);return false;}
        const auto finite=[](const auto& values,double bound){for(auto x:values)if(!std::isfinite(x)||std::abs(x)>bound)return false;return true;};
        double qnorm{};for(float x:s.rotation)qnorm+=double(x)*x;
        const bool clock=s.serial&&s.lease_serial&&std::isfinite(s.time)&&s.time>=0&&std::isfinite(s.lease_time)&&s.lease_time>=0&&
            std::isfinite(s.seconds)&&s.seconds>0&&s.seconds<=.1&&
            ((s.serial==s.lease_serial&&s.time==s.lease_time)||
             (s.lease_serial!=std::numeric_limits<std::uint64_t>::max()&&s.serial==s.lease_serial+1&&std::abs(s.time-s.lease_time-s.seconds)<=1e-7));
        const bool valid=s.associated&&complete(s.owner)&&s.token&&clock&&s.fully_mounted&&s.grounded_presentation&&s.quiet_presentation&&
            finite(s.position,1000000)&&finite(s.requested_velocity,50)&&finite(s.rotation,2)&&std::abs(qnorm-1)<=.001;
        const auto distance=[](const auto& a,const auto& b){double n{};for(unsigned i=0;i<3;++i)n+=(double(a[i])-b[i])*(double(a[i])-b[i]);return std::sqrt(n);};
        const std::array<float,3> zero{};
        const double requested_speed=valid?distance(s.requested_velocity,zero):0;
        maximum_requested_speed=std::max(maximum_requested_speed,requested_speed);
        bool stationary=valid&&requested_speed<=stationary_maximum_speed;
        if(!valid){++invalid_samples;if(armed)finish(StationaryStop::activity);else{stable_samples=0;have_previous=false;}return false;}
        if(!complete(owner)){owner=s.owner;token=s.token;}
        if(last_serial&&s.serial==last_serial){if(s.time!=last_time||s.seconds!=last_seconds){finish(StationaryStop::clock_rewound);return false;}++duplicates;return false;}
        if(last_serial&&(s.serial<last_serial||s.time<=last_time)){finish(StationaryStop::clock_rewound);return false;}
        const bool gap=last_serial&&(last_serial==std::numeric_limits<std::uint64_t>::max()||s.serial!=last_serial+1);
        if(gap){++serial_gaps;if(armed){finish(StationaryStop::serial_gap);return false;}stable_samples=0;have_previous=false;}
        if(have_previous){
            const double dt=s.time-last_time;
            double dot{},oldnorm{},anchor_dot{},anchor_norm{};for(unsigned i=0;i<4;++i){dot+=double(s.rotation[i])*previous_rotation[i];oldnorm+=double(previous_rotation[i])*previous_rotation[i];
                anchor_dot+=double(s.rotation[i])*anchor_rotation[i];anchor_norm+=double(anchor_rotation[i])*anchor_rotation[i];}
            const double angle=2*std::acos(std::clamp(std::abs(dot)/std::sqrt(qnorm*oldnorm),0.,1.));
            const double rotation_drift=2*std::acos(std::clamp(std::abs(anchor_dot)/std::sqrt(qnorm*anchor_norm),0.,1.));
            const double drift=distance(s.position,anchor),speed=distance(s.position,previous_position)/dt,angular_speed=angle/dt;
            maximum_step_speed=std::max(maximum_step_speed,speed);maximum_angular_speed=std::max(maximum_angular_speed,angular_speed);
            maximum_root_drift=std::max(maximum_root_drift,drift);maximum_rotation_drift=std::max(maximum_rotation_drift,rotation_drift);
            stationary=stationary&&std::abs(dt-s.seconds)<=1e-7&&speed<=stationary_maximum_speed&&
                angular_speed<=stationary_maximum_angular_speed&&drift<=stationary_maximum_drift&&rotation_drift<=stationary_maximum_rotation_drift;
        }
        last_serial=s.serial;last_time=s.time;last_seconds=s.seconds;previous_position=s.position;previous_rotation=s.rotation;
        if(!stationary){if(armed)finish(StationaryStop::activity);else{stable_samples=0;have_previous=false;stop=StationaryStop::waiting;}return false;}
        if(!have_previous){anchor=s.position;anchor_rotation=s.rotation;have_previous=true;}
        if(!armed){++stable_samples;stop=StationaryStop::settling;if(stable_samples<stationary_settle_samples)return false;
            armed=true;capture_wall=s.wall;stop=StationaryStop::capturing;}
        if(++count==capacity)finish(StationaryStop::complete);
        return true;
    }
};
}
