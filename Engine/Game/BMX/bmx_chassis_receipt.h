#pragma once
#include <cmath>
#include <cstdint>
#include <limits>

namespace dingosdk::bmx::chassis_receipt {
// A queued lease is not an application. Confirm the native producer at the
// genuine successor before using the predicted rotor/controller state again.
// Body/world/owner identity is qualified by the caller; token binds the mount.
struct Queued {
    std::uint64_t token{},serial{},applications_before{},hop_events_before{};
    double time{},seconds{};
    bool hop{};
};
struct Observed {
    std::uint64_t token{},serial{},applications{},last_applied_serial{},hop_events{};
    double time{},seconds{};
    bool producer_failed{};
};
enum class Result {waiting,confirmed,invalid_epoch,token_changed,clock_discontinuity,
    producer_failed,application_unconfirmed,hop_unconfirmed};
inline bool valid(const Queued& q) noexcept {
    constexpr auto maximum=std::numeric_limits<std::uint64_t>::max();
    return q.token&&q.serial!=maximum&&q.applications_before!=maximum&&
        (!q.hop||q.hop_events_before!=maximum)&&std::isfinite(q.time)&&
        std::isfinite(q.seconds)&&q.seconds>0;
}
inline Result confirm(const Queued& q,const Observed& o) noexcept {
    if(o.producer_failed)return Result::producer_failed;
    if(!valid(q)||!std::isfinite(o.time)||!std::isfinite(o.seconds)||o.seconds<=0)
        return Result::invalid_epoch;
    if(o.token!=q.token)return Result::token_changed;
    // Match the bridge's existing tolerance for native float-h clock advances.
    if(std::abs(o.seconds-q.seconds)>1e-7)return Result::clock_discontinuity;
    if(o.serial==q.serial&&std::abs(o.time-q.time)<=1e-7)return Result::waiting;
    if(o.serial!=q.serial+1||std::abs(o.time-q.time-q.seconds)>1e-7)
        return Result::clock_discontinuity;
    if(o.applications!=q.applications_before+1||o.last_applied_serial!=q.serial)
        return Result::application_unconfirmed;
    if(o.hop_events!=q.hop_events_before+std::uint64_t{q.hop})return Result::hop_unconfirmed;
    return Result::confirmed;
}
inline const char* describe(Result r) noexcept {
    switch(r) {
    case Result::waiting:return "native_chassis_waiting_for_next_body";
    case Result::confirmed:return "native_chassis_previous_command_confirmed";
    case Result::invalid_epoch:return "native_chassis_receipt_epoch_invalid";
    case Result::token_changed:return "native_chassis_receipt_token_changed";
    case Result::clock_discontinuity:return "native_chassis_receipt_clock_discontinuity";
    case Result::producer_failed:return "native_chassis_producer_failed";
    case Result::application_unconfirmed:return "native_chassis_previous_command_not_applied";
    case Result::hop_unconfirmed:return "native_chassis_previous_hop_not_applied";
    }
    return "native_chassis_receipt_invalid";
}
}
