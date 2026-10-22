#include "Extension/BMX/bmx_grip_world_markers.h"
#include "Extension/BMX/bmx_world_transform.h"
#include "Engine/Core/Json/json.h"
#include <cstdio>
#include <cstdlib>

namespace g=dingosdk::bmx::world::grip_markers;
namespace p=dingosdk::bmx::grip_world_marker_policy;
namespace w=dingosdk::bmx::world;
namespace v=dingosdk::bmx::visual;
namespace m=dingosdk::multiplayer;
unsigned checks{};
void check(bool good,const char* text){++checks;if(!good){std::fprintf(stderr,"FAIL %s\n",text);std::exit(1);}}
p::Matrix identity(){p::Matrix m{};m[0]=m[5]=m[10]=m[15]=1;return m;}
m::ClientPropHandle bar_handle(){return {101,102,103,11,104};}
m::ClientPropTransformReadback readback(const m::ClientPropHandle& h,const p::Matrix& requested){
    m::ClientPropTransformReadback r;r.owner=h;r.collection=0x9000;r.count=1;r.attempted=r.bytes_read=r.owner_fenced=
        r.collection_fenced=r.matrix_unchanged=r.matrix_finite=r.matrix_valid=true;r.requested=r.observed=requested;return r;
}
struct Fake {
    static inline unsigned updates{},releases{};
    static inline bool allow_release{true},short_batch{},bad_marker_owner{},bad_marker_matrix{},null_factory{};
    static void reset(){updates=releases=0;allow_release=true;short_batch=bad_marker_owner=bad_marker_matrix=null_factory=false;}
    static m::ClientPropBatchResult update(std::uintptr_t base,std::uintptr_t client,std::uintptr_t owner,
        std::span<m::ClientPropHandle> handles,std::span<const m::ClientPropPlacement> placements) noexcept {
        ++updates;check(base==11&&client==22&&owner==33&&handles.size()==2&&placements.size()==2,"separate two-marker batch only");
        m::ClientPropBatchResult r;if(null_factory)return r;
        for(unsigned i=0;i<2;++i){
            check(placements[i].blueprint==(i==0?"reskate/bmx/left_pedal":"reskate/bmx/right_pedal"),"exact known small blueprint no fallback");
            check(p::rigid(placements[i].transform),"native marker transform rigid");
            if(!handles[i].entity){handles[i]={1000+i,102,103,base,2000+i};++r.created;}
            if(placements[i].readback){*placements[i].readback=readback(handles[i],placements[i].transform);
                if(bad_marker_owner)++placements[i].readback->owner.generation;
                if(bad_marker_matrix)placements[i].readback->observed[12]+=.01f;}
            ++r.placed;++r.live;
            if(short_batch){r.ready=true;return r;}
        }r.ready=true;return r;
    }
    static bool release(std::span<m::ClientPropHandle> handles) noexcept {
        ++releases;if(!allow_release)return false;for(auto& h:handles)h={};return true;
    }
};
using Controller=g::Controller<Fake>;
void tick(Controller& c,std::uint64_t now,bool selected=true,bool riding=true,std::uint64_t token=44,
    m::ClientPropHandle h=bar_handle(),bool normal=true,p::Matrix bars=identity()){
    c.tick(selected,now,riding,normal,11,22,33,token,77,h,bars,readback(h,bars));
}
void geometry(){
    for(bool quaternion:{false,true})for(float steer:{-.4f,0.f,.4f}){
        v::Frame frame;frame.position={300.25f,274.5f,-480.125f};frame.yaw=.8f;frame.pitch=.1f;frame.roll=-.06f;
        frame.steer=steer;frame.barspin=.24f;frame.movement_bike_pitch=.07f;frame.movement_bike_roll=-.03f;
        frame.chassis_quaternion_available=quaternion;frame.chassis_quaternion={0,std::sin(.4f),0,std::cos(.4f)};
        std::array<w::Matrix,w::part_count> parts{};check(w::transforms(frame,parts),"articulated eight-part transform fixture valid");
        for(bool left:{false,true}){
            p::Matrix marker;const auto contact=dingosdk::bmx::geometry::pedal(left).contact;
            const auto grip=dingosdk::bmx::geometry::grip(left).center;
            check(p::marker_transform(parts[5],contact,grip,marker),"pedal contact anchor calibration succeeds");
            const auto a=p::point(marker,contact),b=p::point(parts[5],grip);
            for(unsigned axis=0;axis<3;++axis)check(std::abs(a[axis]-b[axis])<=.0000611f,"authored upper-face anchor equals articulated grip without doubled steering");
            for(unsigned i=0;i<12;++i)check(marker[i]==parts[5][i],"observed bar basis unchanged no marker scaling");
        }
    }
    auto bars=identity();p::Matrix out;bars[0]=.2f;check(!p::marker_transform(bars,{},{},out),"downscale refused");
    bars=identity();bars[4]=.02f;check(!p::marker_transform(bars,{},{},out),"shear refused");
    bars=identity();bars[15]=0;check(!p::marker_transform(bars,{},{},out),"invalid affine matrix refused");
    bars=identity();bars[12]=std::numeric_limits<float>::quiet_NaN();check(!p::marker_transform(bars,{},{},out),"nonfinite bar transform refused");
    bars=identity();bars[12]=1000001;check(!p::marker_transform(bars,{},{},out),"out-of-world marker refused");
    bars=identity();check(!p::marker_transform(bars,{std::numeric_limits<float>::infinity(),0,0},{},out),"nonfinite mesh anchor refused");
}
void lifetime(){
    Fake::reset();Controller c;tick(c,1000);check(Fake::updates==0&&Fake::releases==0&&!c.session.used,"default off no marker native calls");
    check(!c.session.request(false,1000)&&!c.session.request(true,0)&&!c.session.used,"unselected/zero-clock arm refused without consuming request");
    check(!c.session.request(true,UINT64_MAX-p::pending_limit_ms+1),"overflowing pending interval refused");
    check(c.session.request(true,1000)&&!c.session.request(true,1001),"one accepted arm only");
    tick(c,1001,true,false);check(Fake::updates==0&&c.session.phase==p::Phase::pending,"pending inactive wait creates nothing");
    tick(c,2000);check(Fake::updates==1&&c.creation_calls==2&&c.placement_calls==2&&c.live()==2&&c.session.display_ms==2000,"first complete batch starts bounded display");
    auto moved=identity();moved[12]=1;tick(c,3000,true,true,44,bar_handle(),true,moved);
    check(Fake::updates==2&&c.creation_calls==2&&c.placement_calls==4&&c.session.display_ms==2000,"same-client motion reuses handles and cannot extend display clock");
    for(unsigned i=0;i<2;++i)for(unsigned axis=0;axis<3;++axis)
        check(std::abs(c.last.requested_grip_points[i][axis]-c.last.observed_marker_contact_points[i][axis])<.000001f,"native readback contact anchor matches source grip");
    tick(c,7000);check(Fake::updates==2&&Fake::releases==1&&c.live()==0&&c.session.phase==p::Phase::sealed&&c.session.stop==p::Stop::expired,"exact5s expiry releases without another placement");
    check(!c.session.request(true,8000),"sealed display cannot rearm");
    tick(c,9000);check(Fake::updates==2&&Fake::releases==1,"sealed ticks do not retry native creation");
    const auto parsed=dingosdk::Json::parse(g::report(c,true));
    check(parsed.at("created").get<unsigned>()==2&&parsed.at("placed").get<unsigned>()==4&&parsed.at("live_handles").get<unsigned>()==0,"bounded report retains truthful creation placement cleanup counters");
    check(parsed.at("last_attempt").at("bars").at("requested").size()==16&&parsed.at("last_attempt").at("markers").size()==2,"report includes separate bar and marker requested/observed matrices");
    check(g::report(c,true).size()<=g::report_limit_bytes&&c.sealed_ms==7000,"fixed report and actual cleanup time bounded");
    Fake::reset();Controller waiting;waiting.session.request(true,1000);tick(waiting,30999,true,false);
    check(waiting.session.phase==p::Phase::pending&&Fake::updates==0,"pending can wait below30s");
    tick(waiting,31000,true,false);check(waiting.session.phase==p::Phase::sealed&&waiting.session.stop==p::Stop::pending_timeout&&Fake::updates==0,"exact30s wait seals without creation");
}
void refusals(){
    for(unsigned kind=0;kind<8;++kind){
        Fake::reset();Controller c;c.session.request(true,1000);tick(c,1001);check(c.live()==2,"refusal fixture displayed");
        auto h=bar_handle();if(kind==0)++h.context;if(kind==1)++h.entity;if(kind==2)++h.generation;if(kind==3)++h.base;
        if(kind<4)tick(c,1002,true,true,44,h);
        if(kind==4)tick(c,1002,true,true,45);
        if(kind==5)tick(c,1002,false);
        if(kind==6)tick(c,1002,true,false);
        if(kind==7)tick(c,1000);
        check(c.live()==0&&c.session.phase==p::Phase::sealed&&Fake::updates==1,"owner token context scope withdrawal clock failure removes markers without retry");
    }
    for(unsigned fault=0;fault<8;++fault){
        Fake::reset();Controller c;c.session.request(true,1000);auto bars=identity();auto h=bar_handle();auto read=readback(h,bars);
        if(fault==0)read.attempted=false;if(fault==1)read.bytes_read=false;if(fault==2)read.owner_fenced=false;
        if(fault==3)read.collection_fenced=false;if(fault==4)read.matrix_unchanged=false;if(fault==5)read.matrix_valid=false;
        if(fault==6)++read.owner.generation;if(fault==7)read.observed[12]=.01f;
        c.tick(true,1001,true,true,11,22,33,44,77,h,bars,read);
        check(Fake::updates==0&&c.session.phase==p::Phase::sealed&&c.session.stop==p::Stop::bar_readback_failed,"unqualified observed bars never authorizes marker placement");
    }
    for(unsigned field=0;field<2;++field){
        Fake::reset();Controller c;c.session.request(true,1000);tick(c,1001);const auto bars=identity();const auto h=bar_handle();
        c.tick(true,1002,true,true,11,field==0?23:22,field==1?34:33,44,78,h,bars,readback(h,bars));
        check(Fake::updates==1&&c.live()==0&&c.session.stop==p::Stop::owner_changed,"rider/client owner change cannot place markers");
    }
    for(unsigned fault=0;fault<5;++fault){
        Fake::reset();Controller c;c.session.request(true,1000);
        if(fault==0)Fake::short_batch=true;if(fault==1)Fake::bad_marker_owner=true;if(fault==2)Fake::bad_marker_matrix=true;if(fault==3)Fake::null_factory=true;
        tick(c,1001,true,true,44,bar_handle(),fault!=4);
        check(c.live()==0&&c.session.phase==p::Phase::sealed&&c.successful_batches==0,"partial creation/readback/normal-part failure seals and cleans up");
        const auto n=Fake::updates;tick(c,1002);check(Fake::updates==n,"failed one-shot never retries creation");
    }
    Fake::reset();Controller deferred;deferred.session.request(true,1000);tick(deferred,1001);Fake::allow_release=false;
    tick(deferred,6001);check(deferred.session.phase==p::Phase::releasing&&deferred.live()==2&&Fake::updates==1,"wrong-realm cleanup retains live handles");
    tick(deferred,6002,false);check(deferred.live()==2&&Fake::updates==1,"cleanup-only retry does not restart marker placement");
    Fake::allow_release=true;tick(deferred,6003,false);
    check(deferred.session.phase==p::Phase::sealed&&deferred.live()==0&&deferred.handles_removed==2&&deferred.release_successes==1,"later valid realm clears retained handles and preserves first stop");
    check(deferred.session.stop==p::Stop::expired&&!deferred.session.request(true,7000)&&deferred.first_cleanup_ms==6001&&deferred.last_cleanup_ms==6003&&deferred.sealed_ms==6003,"cleanup preserves terminal cause, first/last timing and one-shot consumption");
}
int main(){geometry();lifetime();refusals();std::printf("BMX grip world markers: %u checks passed\n",checks);}
