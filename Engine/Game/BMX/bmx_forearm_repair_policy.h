#pragma once
#include <cmath>

namespace dingosdk::bmx::forearm_repair {
// Private presentation experiment. This selector never admits a native write.
struct Scope {bool requested{},private_profile{},human_ride{},native_chassis{},conflict{};};
inline bool selected(const Scope& s) noexcept {
    return s.requested&&s.private_profile&&s.human_ride&&s.native_chassis&&!s.conflict;
}
inline constexpr float maximum_extra_drop=.01f;
inline constexpr unsigned search_iterations=8;
struct Search {bool ready{};float extra_drop{};unsigned evaluations{};};
// Each predicate call must solve from the same immutable source and verify all
// existing contacts/anatomy. Retain the last verified candidate, never a failed
// midpoint. Failure of the bounded endpoint is conservative, not a wider gate.
template<class Try>
inline Search minimum_drop(Try&& accepts) {
    Search out;out.evaluations=1;
    if(!accepts(maximum_extra_drop))return out;
    float low=0,high=maximum_extra_drop;
    for(unsigned i=0;i<search_iterations;++i){const float middle=(low+high)*.5f;++out.evaluations;
        if(accepts(middle))high=middle;else low=middle;}
    out.ready=true;out.extra_drop=high;return out;
}
}
