#include "bmx_world.h"
#include "bmx_world_transform.h"
#include "bmx_grip_world_markers.h"
#ifdef _WIN32
#include "bmx_prop_transform_trace.h"
#endif
#include "Extension/Multiplayer/Remote/native_prop.h"
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <mutex>

namespace dingosdk::bmx::world {
namespace {
struct State {
    std::array<multiplayer::ClientPropHandle, part_count> handles{}; // client thread only
    std::uintptr_t owner{};
    std::chrono::steady_clock::time_point next_attempt{};
    std::mutex mutex;
    Snapshot report;
};
State& state() { static auto* value = new State; return *value; }
struct MarkerState {
    std::mutex mutex;
    grip_markers::Controller<> controller;
    bool (*selected)() noexcept {};
    std::uint64_t thread{};
};
MarkerState marker_state;
std::atomic<bool> marker_used{};
std::uint64_t marker_wall() noexcept {
#ifdef _WIN32
    return GetTickCount64();
#else
    return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
#endif
}
std::uint64_t marker_thread() noexcept {
#ifdef _WIN32
    return GetCurrentThreadId();
#else
    return 1; // Portable fixture only; native commands exist in the Windows runtime.
#endif
}
bool marker_readback_needed() noexcept {
    if(!marker_used.load(std::memory_order_acquire))return false;
    try {
        auto& m=marker_state;std::lock_guard lock(m.mutex);
        const bool selected=m.selected&&m.thread==marker_thread()&&m.selected();
        m.controller.poll(selected,marker_wall());
        return m.controller.session.phase==grip_world_marker_policy::Phase::pending||
            m.controller.session.phase==grip_world_marker_policy::Phase::displaying;
    }catch(...){return false;}
}
void tick_markers(std::uintptr_t base,std::uintptr_t client,const visual::Frame& frame,
    const PlacementReceipt& receipt,const multiplayer::ClientPropHandle& bars,const Matrix& requested,
    const multiplayer::ClientPropTransformReadback& observed) noexcept {
    if(!marker_used.load(std::memory_order_acquire))return;
    try {
        auto& m=marker_state;std::lock_guard lock(m.mutex);
        const bool selected=m.selected&&m.thread==marker_thread()&&m.selected();
        const bool riding=frame.active&&frame.entity&&frame.native_body_token&&frame.rider_mode==visual::RiderMode::riding&&
            frame.mount_progress==1&&frame.rider_blend==1;
        m.controller.tick(selected,marker_wall(),riding,receipt.complete,base,client,frame.entity,
            frame.native_body_token,receipt.revision,bars,requested,observed);
        // Environment/realm selection can be revoked during a factory call.
        // Recheck before returning, and preserve cleanup-only handling afterward.
        m.controller.poll(m.selected&&m.thread==marker_thread()&&m.selected(),marker_wall());
    }catch(...){/* Existing native prop API owns failure cleanup; next client tick retains retry of cleanup only. */}
}
unsigned handles_present(const State& value) {
    return static_cast<unsigned>(std::count_if(value.handles.begin(), value.handles.end(),
        [](const auto& handle) { return handle.entity != 0; }));
}
void report(State& value, bool active, bool ready, const multiplayer::ClientPropBatchResult& result,
    std::string issue) {
    std::lock_guard lock(value.mutex);
    value.report.active = active;
    value.report.ready = ready;
    value.report.live_parts = ready ? result.live : handles_present(value);
    value.report.entities_created += result.created;
    value.report.entity_placements += result.placed;
    value.report.issue = std::move(issue);
}
} // namespace

PlacementReceipt tick(std::uintptr_t base, std::uintptr_t client, const visual::Frame& frame, std::uint64_t revision) noexcept {
    auto& value = state();PlacementReceipt receipt;receipt.revision=revision;receipt.entity=frame.entity;
    Matrix marker_requested{};multiplayer::ClientPropTransformReadback marker_observed;
    // Observes this exact normal placement result on every return. Marker
    // placement/cleanup cannot alter the eight-part receipt or pose admission.
    struct MarkerTick {
        std::uintptr_t base{},client{};const visual::Frame& frame;const PlacementReceipt& receipt;
        const multiplayer::ClientPropHandle& bars;const Matrix& requested;
        const multiplayer::ClientPropTransformReadback& observed;
        ~MarkerTick(){tick_markers(base,client,frame,receipt,bars,requested,observed);}
    } marker_tick{base,client,frame,receipt,value.handles[5],marker_requested,marker_observed};
    try {
        if (!frame.active || !frame.entity || !base || !client) {
#ifdef _WIN32
            prop_transform_trace::poll_export(true);
#endif
            const auto removed = multiplayer::release_client_props(value.handles);
            if (removed) { value.owner = 0; value.next_attempt = {}; }
            report(value, false, false, {}, removed ? "Inactive." : "Waiting for native world cleanup.");
            return receipt;
        }
        if (value.owner && value.owner != frame.entity) {
            if (!multiplayer::release_client_props(value.handles)) {
                report(value, true, false, {}, "Waiting for previous rider model cleanup.");
                return receipt;
            }
            value.owner = 0;
            value.next_attempt = {};
        }
        std::array<Matrix, part_count> matrices{};
        if (!transforms(frame, matrices)) {
            (void)multiplayer::release_client_props(value.handles);
            report(value, true, false, {}, "Invalid bike world transform.");
            return receipt;
        }
        const auto now = std::chrono::steady_clock::now();
        if (!handles_present(value) && now < value.next_attempt) return receipt;
        std::array<multiplayer::ClientPropPlacement, part_count> placements{};
        for (unsigned part = 0; part < placements.size(); ++part)
            placements[part] = {blueprints[part], matrices[part]};
#ifdef _WIN32
        auto* measured=prop_transform_trace::begin(base,client,frame,revision);
        if(measured)for(unsigned part=0;part<placements.size();++part)placements[part].readback=&measured->parts_readback[part];
#endif
        if(marker_readback_needed()&&!placements[5].readback){
            marker_requested=matrices[5];placements[5].readback=&marker_observed;
        }
        const auto result = multiplayer::update_client_props(base, client, frame.entity, value.handles, placements);
#ifdef _WIN32
        prop_transform_trace::finish(measured,result);
#endif
        value.owner = frame.entity;receipt.live=result.live;receipt.placed=result.placed;
        receipt.complete=result.ready&&result.live==part_count&&result.placed==part_count;
        if (!receipt.complete) {
            (void)multiplayer::release_client_props(value.handles);
            value.next_attempt = now + std::chrono::seconds(1);
        }
        report(value, true, receipt.complete, result, receipt.complete ? "Native bike entities placed." :
            result.issue.empty()?"Incomplete native bike placement batch.":result.issue);
    } catch (...) {
        receipt.complete=false;
        (void)multiplayer::release_client_props(value.handles);
        try { report(value, frame.active, false, {}, "Native bike model update failed."); } catch (...) {}
    }
    return receipt;
}

Snapshot snapshot() {
    auto& value = state();
    std::lock_guard lock(value.mutex);
    return value.report;
}
bool arm_grip_markers(bool (*selected)() noexcept) noexcept {
    try {
        if(!selected||!selected())return false;
        auto& m=marker_state;std::lock_guard lock(m.mutex);
        if(!m.controller.session.request(true,marker_wall()))return false;
        m.selected=selected;m.thread=marker_thread();marker_used.store(true,std::memory_order_release);return true;
    }catch(...){return false;}
}
std::string grip_markers_report() noexcept {
    try {
        auto& m=marker_state;std::lock_guard lock(m.mutex);
        const bool selected=m.selected&&m.thread==marker_thread()&&m.selected();
#ifdef _WIN32
        return grip_markers::report(m.controller,selected,GetCurrentProcessId(),m.thread);
#else
        return grip_markers::report(m.controller,selected,0,m.thread);
#endif
    }catch(...){return "{\"issue\":\"private_marker_report_unavailable\"}";}
}
} // namespace dingosdk::bmx::world
