#pragma once
#include "Engine/Game/BMX/bmx_grip_world_marker_policy.h"
#include "Engine/Game/BMX/bmx_geometry.h"
#include "Extension/Multiplayer/Remote/native_prop.h"
#include <algorithm>
#include <iomanip>
#include <limits>
#include <sstream>

namespace dingosdk::bmx::world::grip_markers {
namespace policy=grip_world_marker_policy;
using multiplayer::ClientPropHandle;
using multiplayer::ClientPropTransformReadback;
using Matrix=policy::Matrix;
inline constexpr std::size_t report_limit_bytes=7600; // Leave room for the native log prefix.
inline bool same_handle(const ClientPropHandle& a,const ClientPropHandle& b) noexcept {
    return a.entity==b.entity&&a.parent==b.parent&&a.context==b.context&&a.base==b.base&&a.generation==b.generation;
}
inline bool qualified(const ClientPropTransformReadback& r,const ClientPropHandle& expected,const Matrix& requested) noexcept {
    return expected.entity&&expected.parent&&expected.context&&expected.base&&expected.generation&&
        same_handle(r.owner,expected)&&r.attempted&&r.bytes_read&&r.owner_fenced&&r.collection_fenced&&r.matrix_unchanged&&
        r.matrix_finite&&r.matrix_valid&&policy::rigid(r.observed)&&r.requested==requested&&r.observed==requested;
}
struct Native {
    static auto update(std::uintptr_t base,std::uintptr_t client,std::uintptr_t owner,
        std::span<ClientPropHandle> handles,std::span<const multiplayer::ClientPropPlacement> placements) noexcept {
        return multiplayer::update_client_props(base,client,owner,handles,placements);
    }
    static bool release(std::span<ClientPropHandle> handles) noexcept {return multiplayer::release_client_props(handles);}
};
struct Sample {
    bool present{};std::uint64_t revision{},wall_ms{};
    ClientPropTransformReadback bars;
    std::array<ClientPropTransformReadback,2> markers;
    std::array<policy::Vec,2> requested_grip_points{},observed_marker_contact_points{};
};
// Owned exclusively by a serialized native client-thread adapter. No render
// callback, native body setter, pose write, controller input or camera math.
template<class Backend=Native> struct Controller {
    policy::Session session;
    std::array<ClientPropHandle,2> handles{};
    std::uint64_t creation_calls{},placement_calls{},release_calls{},release_successes{},handles_removed{},
        successful_batches{},first_revision{},last_revision{},last_placement_ms{},first_cleanup_ms{},last_cleanup_ms{},sealed_ms{};
    Sample last;
    unsigned live() const noexcept {return static_cast<unsigned>(std::count_if(handles.begin(),handles.end(),[](const auto& h){return h.entity!=0;}));}
    void cleanup(std::uint64_t now) noexcept {
        if(session.phase!=policy::Phase::releasing)return;
        const auto before=live();
        if(before){if(!first_cleanup_ms)first_cleanup_ms=now;last_cleanup_ms=now;
            ++release_calls;const bool released=Backend::release(handles);const auto after=live();
            handles_removed+=before>=after?before-after:0;if(released&&after==0)++release_successes;}
        session.cleaned(live()==0);
        if(session.phase==policy::Phase::sealed)sealed_ms=now;
    }
    void poll(bool selected,std::uint64_t now) noexcept {session.poll(selected,now);cleanup(now);}
    void tick(bool selected,std::uint64_t now,bool riding,bool normal_complete,std::uintptr_t base,std::uintptr_t client,
        std::uintptr_t entity,std::uint64_t body_token,std::uint64_t revision,const ClientPropHandle& bar_handle,
        const Matrix& requested_bars,const ClientPropTransformReadback& bars) noexcept {
        if(!session.poll(selected,now)){cleanup(now);return;}
        if(!riding){session.admit(false,{});cleanup(now);return;}
        if(!normal_complete){session.finish(policy::Stop::normal_placement_failed);cleanup(now);return;}
        if(bar_handle.base!=base||!qualified(bars,bar_handle,requested_bars)){
            last={};last.present=true;last.revision=revision;last.wall_ms=now;last.bars=bars;
            session.finish(policy::Stop::bar_readback_failed);cleanup(now);return;
        }
        const policy::Owner actual{base,client,entity,bar_handle.context,bar_handle.entity,body_token,bar_handle.generation};
        if(!session.admit(true,actual)){cleanup(now);return;}
        last={};last.present=true;last.revision=revision;last.wall_ms=now;last.bars=bars;
        std::array<multiplayer::ClientPropPlacement,2> placements{};
        for(unsigned i=0;i<2;++i){
            const bool left=i==0;auto& p=placements[i];
            p.blueprint=left?"reskate/bmx/left_pedal":"reskate/bmx/right_pedal";
            p.readback=&last.markers[i];
            if(!policy::marker_transform(bars.observed,geometry::pedal(left).contact,geometry::grip(left).center,p.transform)){
                session.finish(policy::Stop::invalid_transform);cleanup(now);return;
            }
            last.requested_grip_points[i]=policy::point(bars.observed,geometry::grip(left).center);
        }
        const auto batch=Backend::update(base,client,entity,handles,placements);
        creation_calls+=batch.created;placement_calls+=batch.placed;
        if(!batch.ready||batch.live!=2||batch.placed!=2||live()!=2){session.finish(policy::Stop::marker_placement_failed);cleanup(now);return;}
        for(unsigned i=0;i<2;++i){
            if(handles[i].context!=actual.context||handles[i].base!=base||handles[i].entity==actual.bar_entity||
               handles[0].entity==handles[1].entity||
               !qualified(last.markers[i],handles[i],placements[i].transform)){
                session.finish(policy::Stop::marker_readback_failed);cleanup(now);return;
            }
            last.observed_marker_contact_points[i]=policy::point(last.markers[i].observed,geometry::pedal(i==0).contact);
        }
        if(!successful_batches)first_revision=revision;
        ++successful_batches;last_revision=revision;last_placement_ms=now;session.placed(now);
    }
};
inline void matrix_json(std::ostream& out,const Matrix& m) {
    out<<'[';for(unsigned i=0;i<m.size();++i){if(i)out<<',';if(std::isfinite(m[i]))out<<m[i];else out<<"null";}out<<']';
}
inline void vector_json(std::ostream& out,const policy::Vec& v) {
    out<<'[';for(unsigned i=0;i<3;++i){if(i)out<<',';if(std::isfinite(v[i]))out<<v[i];else out<<"null";}out<<']';
}
inline void readback_json(std::ostream& out,const ClientPropTransformReadback& r) {
    out<<"{\"entity\":"<<r.owner.entity<<",\"generation\":"<<r.owner.generation<<",\"context\":"<<r.owner.context
       <<",\"parent\":"<<r.owner.parent<<",\"base\":"<<r.owner.base<<",\"collection\":"<<r.collection
       <<",\"count\":"<<static_cast<unsigned>(r.count)<<",\"first\":"<<static_cast<unsigned>(r.first)<<",\"extra\":"<<static_cast<unsigned>(r.extra)
       <<",\"attempted\":"<<r.attempted<<",\"bytes_read\":"<<r.bytes_read<<",\"owner_fenced\":"<<r.owner_fenced
       <<",\"collection_fenced\":"<<r.collection_fenced<<",\"matrix_unchanged\":"<<r.matrix_unchanged
       <<",\"matrix_finite\":"<<r.matrix_finite<<",\"matrix_valid\":"<<r.matrix_valid<<",\"requested\":";
    matrix_json(out,r.requested);out<<",\"observed\":";matrix_json(out,r.observed);out<<'}';
}
template<class B> std::string report(const Controller<B>& c,bool selected,std::uint64_t process=0,std::uint64_t thread=0) {
    std::ostringstream out;out<<std::boolalpha<<std::setprecision(std::numeric_limits<float>::max_digits10);
    const auto& s=c.session;
    out<<"{\"schema\":1,\"kind\":\"private_native_grip_calibration\",\"process_id\":"<<process<<",\"client_thread\":"<<thread<<",\"selected\":"<<selected
       <<",\"one_shot_used\":"<<s.used<<",\"phase\":\""<<policy::name(s.phase)<<"\",\"stop\":\""<<policy::name(s.stop)
       <<"\",\"requested_ms\":"<<s.requested_ms<<",\"display_started_ms\":"<<s.display_ms<<",\"last_poll_ms\":"<<s.last_ms
       <<",\"pending_limit_ms\":"<<policy::pending_limit_ms<<",\"display_limit_ms\":"<<policy::display_limit_ms
       <<",\"owner\":{\"base\":"<<s.owner.base<<",\"client\":"<<s.owner.client<<",\"entity\":"<<s.owner.entity
       <<",\"context\":"<<s.owner.context<<",\"body_token\":"<<s.owner.body_token<<",\"bar_entity\":"<<s.owner.bar_entity
       <<",\"bar_generation\":"<<s.owner.bar_generation<<"},\"created\":"<<c.creation_calls<<",\"placed\":"<<c.placement_calls
       <<",\"release_calls\":"<<c.release_calls<<",\"release_successes\":"<<c.release_successes<<",\"handles_removed_by_cleanup\":"<<c.handles_removed
       <<",\"live_handles\":"<<c.live()<<",\"successful_batches\":"<<c.successful_batches<<",\"first_revision\":"<<c.first_revision
       <<",\"last_successful_revision\":"<<c.last_revision<<",\"last_placement_ms\":"<<c.last_placement_ms<<",\"last_attempt\":";
    if(!c.last.present)out<<"null";
    else {out<<"{\"revision\":"<<c.last.revision<<",\"wall_ms\":"<<c.last.wall_ms<<",\"bars\":";
        readback_json(out,c.last.bars);out<<",\"markers\":[";
        for(unsigned i=0;i<2;++i){if(i)out<<',';out<<"{\"side\":\""<<(i==0?"left":"right")<<"\",\"readback\":";
            readback_json(out,c.last.markers[i]);out<<",\"requested_grip_center\":";vector_json(out,c.last.requested_grip_points[i]);
            out<<",\"observed_pedal_contact_anchor\":";vector_json(out,c.last.observed_marker_contact_points[i]);out<<'}';}
        out<<"]}";
    }
    out<<",\"first_cleanup_ms\":"<<c.first_cleanup_ms<<",\"last_cleanup_ms\":"<<c.last_cleanup_ms<<",\"sealed_ms\":"<<c.sealed_ms
       <<",\"boundary\":\"Two rigid pedal rectangles; upper-face contact anchors calibrate grip centers. Same-client-frame fenced prop matrices only; no renderer completion, stationary qualification, hand/bone evidence or camera projection. Rectangles can occlude grips. Wall expiry is serviced on client ticks; cleanup waits for the valid native realm. Engine batch failures may also release handles internally.\"}";
    auto text=out.str();return text.size()<=report_limit_bytes?text:"{\"issue\":\"bounded_marker_report_overflow\"}";
}
}
