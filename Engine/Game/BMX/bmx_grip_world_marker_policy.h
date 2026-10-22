#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>

namespace dingosdk::bmx::grip_world_marker_policy {
inline constexpr std::uint64_t pending_limit_ms=30000,display_limit_ms=5000;
using Matrix=std::array<float,16>;
using Vec=std::array<float,3>;
struct Owner {
    std::uintptr_t base{},client{},entity{},context{},bar_entity{};
    std::uint64_t body_token{},bar_generation{};
    bool operator==(const Owner&) const=default;
};
inline bool complete(const Owner& x) noexcept {
    return x.base&&x.client&&x.entity&&x.context&&x.bar_entity&&x.body_token&&x.bar_generation;
}
enum class Phase {unused,pending,displaying,releasing,sealed};
enum class Stop {none,expired,pending_timeout,clock_changed,scope_changed,withdrawn,owner_changed,
    normal_placement_failed,bar_readback_failed,marker_placement_failed,marker_readback_failed,invalid_transform};
inline const char* name(Phase p) noexcept {
    switch(p){case Phase::unused:return "not_armed";case Phase::pending:return "waiting_for_riding_parts";
    case Phase::displaying:return "displaying_calibration_markers";case Phase::releasing:return "cleanup_pending";
    case Phase::sealed:return "sealed_no_rearm";}return "unknown";
}
inline const char* name(Stop s) noexcept {
    switch(s){case Stop::none:return "none";case Stop::expired:return "five_second_display_complete";
    case Stop::pending_timeout:return "thirty_second_pending_timeout";case Stop::clock_changed:return "wall_clock_invalid_or_reversed";
    case Stop::scope_changed:return "private_scope_changed";case Stop::withdrawn:return "riding_publication_withdrawn";
    case Stop::owner_changed:return "owner_body_or_bar_generation_changed";case Stop::normal_placement_failed:return "normal_eight_part_batch_incomplete";
    case Stop::bar_readback_failed:return "handlebars_readback_unqualified";case Stop::marker_placement_failed:return "marker_batch_incomplete";
    case Stop::marker_readback_failed:return "marker_readback_unqualified";case Stop::invalid_transform:return "invalid_marker_transform";}
    return "unknown";
}
struct Session {
    bool used{};Phase phase{Phase::unused};Stop stop{Stop::none};Owner owner;
    std::uint64_t requested_ms{},display_ms{},last_ms{};
    bool request(bool selected,std::uint64_t now) noexcept {
        if(!selected||used||!now||now>std::numeric_limits<std::uint64_t>::max()-pending_limit_ms)return false;
        used=true;phase=Phase::pending;requested_ms=last_ms=now;return true;
    }
    void finish(Stop why) noexcept {
        if(used&&(phase==Phase::pending||phase==Phase::displaying)){phase=Phase::releasing;stop=why;}
    }
    bool poll(bool selected,std::uint64_t now) noexcept {
        if(!used||phase==Phase::releasing||phase==Phase::sealed)return false;
        if(!now||now<last_ms){finish(Stop::clock_changed);return false;}
        last_ms=now;
        if(!selected){finish(Stop::scope_changed);return false;}
        if(phase==Phase::pending&&now-requested_ms>=pending_limit_ms){finish(Stop::pending_timeout);return false;}
        if(phase==Phase::displaying&&now-display_ms>=display_limit_ms){finish(Stop::expired);return false;}
        return true;
    }
    bool admit(bool riding,const Owner& actual) noexcept {
        if(phase!=Phase::pending&&phase!=Phase::displaying)return false;
        if(!riding){if(phase==Phase::displaying)finish(Stop::withdrawn);return false;}
        if(!complete(actual)){finish(Stop::owner_changed);return false;}
        if(complete(owner)&&owner!=actual){finish(Stop::owner_changed);return false;}
        owner=actual;return true;
    }
    void placed(std::uint64_t now) noexcept {
        if(phase==Phase::pending&&complete(owner)&&now==last_ms){phase=Phase::displaying;display_ms=now;}
    }
    void cleaned(bool all_handles_removed) noexcept {
        if(phase==Phase::releasing&&all_handles_removed)phase=Phase::sealed;
    }
};
inline bool rigid(const Matrix& m) noexcept {
    for(float x:m)if(!std::isfinite(x))return false;
    if(m[3]!=0||m[7]!=0||m[11]!=0||m[15]!=1)return false;
    for(unsigned a=0;a<3;++a){
        if(std::abs(m[12+a])>1000000)return false;
        float n{};for(unsigned r=0;r<3;++r)n+=m[a*4+r]*m[a*4+r];
        if(n<.99f||n>1.01f)return false;
        for(unsigned b=a+1;b<3;++b){float d{};for(unsigned r=0;r<3;++r)d+=m[a*4+r]*m[b*4+r];if(std::abs(d)>.01f)return false;}
    }
    return true;
}
inline Vec point(const Matrix& m,const Vec& p) noexcept {
    Vec out{};for(unsigned a=0;a<3;++a)out[a]=m[12+a]+m[a]*p[0]+m[4+a]*p[1]+m[8+a]*p[2];return out;
}
// The known upper-face contact anchor of a pedal mesh maps to the grip center.
// Keep the observed bar basis exactly; meshes remain at their authored size.
inline bool marker_transform(const Matrix& bars,const Vec& pedal_contact,const Vec& grip,Matrix& out) noexcept {
    if(!rigid(bars))return false;
    for(float v:pedal_contact)if(!std::isfinite(v))return false;
    for(float v:grip)if(!std::isfinite(v))return false;
    out=bars;
    for(unsigned a=0;a<3;++a)out[12+a]+=bars[a]*(grip[0]-pedal_contact[0])+bars[4+a]*(grip[1]-pedal_contact[1])+bars[8+a]*(grip[2]-pedal_contact[2]);
    return rigid(out);
}
}
