#pragma once
#include "bmx_chassis_ride.h"
#include "bmx_native_chassis.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <type_traits>
#include <utility>

namespace dingosdk::bmx::ride_trace {
enum class InputSource : unsigned { adapter_sample, flat_rehearsal, ramp_rehearsal, catalog_rehearsal, trick_rehearsal, private_switch_neutral };
struct Sample {
    chassis_ride::Step step;
    RawInput input;
    native_chassis::Status producer;
    std::array<float,3> rider_position{};
    bool offboard{},standable{},motion_supported{};
    RawInput sampled_input; // before any private rehearsal or mount/impact gate
    InputSource input_source{};
    bool input_neutralized{};
    bool private_switch_gate{};
};
static_assert(std::is_trivially_copyable_v<Sample>,"Accepted trace rows must never allocate while being copied.");
// Fixed storage: no allocation, serialization or file IO on accepted ride steps.
// A mount is a separate history; duplicate/stale steps cannot rewrite evidence.
template<std::size_t Capacity=240> class History {
    static_assert(Capacity>0);
    std::array<Sample,Capacity> samples_{};
    std::size_t next_{},size_{};
    std::uint64_t token_{},serial_{};
    std::uint64_t accepted_{},overwritten_{};
    bool sealed_{};
public:
    bool record(const Sample& sample) noexcept {
        const auto& step=sample.step;
        if(sealed_||!step.ready||!step.body_token||!step.serial||step.serial<=serial_||
           (token_&&step.body_token!=token_))return false;
        token_=step.body_token;serial_=step.serial;
        samples_[next_]=sample;next_=(next_+1)%Capacity;
        if(size_<Capacity)++size_;
        else if(overwritten_!=std::numeric_limits<std::uint64_t>::max())++overwritten_;
        if(accepted_!=std::numeric_limits<std::uint64_t>::max())++accepted_;
        return true;
    }
    void reset() noexcept {next_=size_=0;token_=serial_=accepted_=overwritten_=0;sealed_=false;}
    bool seal() noexcept {if(sealed_||!size_)return false;sealed_=true;return true;}
    std::size_t size() const noexcept{return size_;}
    std::uint64_t token() const noexcept{return token_;}
    static constexpr std::size_t capacity() noexcept{return Capacity;}
    std::uint64_t total_accepted() const noexcept{return accepted_;}
    std::uint64_t overwritten() const noexcept{return overwritten_;}
    const Sample* first() const noexcept{return size_?&samples_[(next_+Capacity-size_)%Capacity]:nullptr;}
    const Sample* last() const noexcept{return size_?&samples_[(next_+Capacity-1)%Capacity]:nullptr;}
    template<class Visit> void each(Visit&& visit) const {
        const auto first=(next_+Capacity-size_)%Capacity;
        for(std::size_t i=0;i<size_;++i)visit(samples_[(first+i)%Capacity]);
    }
};
inline constexpr std::size_t long_capacity=3600;
inline constexpr unsigned long_capture_limit=8;
enum class Freeze {empty,pending,limit,ready};
// Explicit diagnostic only. Allocate both fixed buffers once before chassis
// activation. Sealing exchanges pointers; it never copies a large live history.
template<std::size_t Capacity=long_capacity,unsigned Limit=long_capture_limit> class BufferPair {
    std::unique_ptr<History<Capacity>> active_,pending_;
    bool attempted_{},failed_{},recording_{};unsigned captures_{};
public:
    template<class Make> bool prepare(Make&& make) noexcept {
        if(attempted_)return ready();attempted_=true;
        try {
            auto active=make(),pending=make();
            if(!active||!pending){failed_=true;return false;}
            active_=std::move(active);pending_=std::move(pending);return true;
        }catch(...){failed_=true;return false;}
    }
    bool prepare() noexcept {return prepare([]{return std::make_unique<History<Capacity>>();});}
    bool ready() const noexcept{return active_&&pending_;}
    bool failed() const noexcept{return failed_;}
    bool begin() noexcept {recording_=false;if(!ready()||captures_>=Limit)return false;active_->reset();recording_=true;return true;}
    bool record(const Sample& sample) noexcept{return recording_&&active_->record(sample);}
    Freeze freeze(bool report_pending) noexcept {
        if(!recording_||!active_->seal())return Freeze::empty;
        recording_=false;
        if(report_pending)return Freeze::pending;
        if(captures_>=Limit)return Freeze::limit;
        active_.swap(pending_);++captures_;return Freeze::ready;
    }
    const History<Capacity>& pending() const noexcept{return *pending_;}
    unsigned captures() const noexcept{return captures_;}
};
}
