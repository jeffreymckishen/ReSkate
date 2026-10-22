#include "Extension/BMX/bmx_world.h"
#include "Extension/BMX/bmx_world_transform.h"
#include "Extension/Multiplayer/Remote/native_prop.h"
#include "Engine/Core/Json/json.h"
#include <cstdio>
#include <cstdlib>

unsigned checks{},normal_updates{},marker_updates{},marker_releases{},normal_releases{};
bool marker_readback_bad{};
void check(bool b,const char* text){++checks;if(!b){std::fprintf(stderr,"FAIL %s\n",text);std::exit(1);}}
bool scope_yes() noexcept {return true;}
bool scope_no() noexcept {return false;}
namespace dingosdk::multiplayer {
bool release_client_props(std::span<ClientPropHandle> handles) noexcept {
    check(handles.size()==8||handles.size()==2,"only original bike and separate marker batches exist");
    if(handles.size()==2)++marker_releases;else ++normal_releases;
    for(auto& h:handles)h={};return true;
}
ClientPropBatchResult update_client_props(std::uintptr_t base,std::uintptr_t client,std::uintptr_t owner,
    std::span<ClientPropHandle> handles,std::span<const ClientPropPlacement> placements) noexcept {
    const bool markers=handles.size()==2;
    check((markers||handles.size()==8)&&handles.size()==placements.size()&&base==100&&client==200&&owner==33,"native adapter owner/batch contract");
    if(markers)++marker_updates;else ++normal_updates;
    ClientPropBatchResult result;
    for(unsigned i=0;i<handles.size();++i){
        if(!handles[i].entity){handles[i]={static_cast<std::uintptr_t>((markers?2000:1000)+i),300,400,base,static_cast<std::uint64_t>((markers?200:100)+i)};++result.created;}
        if(placements[i].readback){auto& r=*placements[i].readback;r={};r.owner=handles[i];r.collection=0x9000;r.count=1;
            r.attempted=r.bytes_read=r.owner_fenced=r.collection_fenced=r.matrix_unchanged=r.matrix_finite=r.matrix_valid=true;
            r.requested=r.observed=placements[i].transform;
            if(markers&&marker_readback_bad)++r.owner.generation;
        }
        ++result.placed;++result.live;
    }
    result.ready=true;return result;
}
}
int main(){
    namespace w=dingosdk::bmx::world;namespace v=dingosdk::bmx::visual;
    v::Frame frame;frame.active=true;frame.entity=33;frame.native_body_token=44;frame.position={300,274,-480};frame.steer=.3f;frame.yaw=.8f;
    const auto before=w::tick(100,200,frame,1);
    check(before.complete&&before.live==8&&before.placed==8&&normal_updates==1&&marker_updates==0,"default eight-part receipt unchanged with marker code present");
    check(!w::arm_grip_markers(scope_no),"unselected arm rejected without factory");
    check(w::arm_grip_markers(scope_yes)&&!w::arm_grip_markers(scope_yes),"explicit arm accepted once");
    const auto first=w::tick(100,200,frame,2);
    check(first.complete&&first.revision==2&&first.entity==33&&first.live==8&&first.placed==8&&normal_updates==2&&marker_updates==1,"markers use separate batch without changing normal placement receipt");
    auto report=dingosdk::Json::parse(w::grip_markers_report());
    check(report.at("phase").get<std::string>()=="displaying_calibration_markers"&&report.at("live_handles").get<unsigned>()==2&&report.at("last_successful_revision").get<unsigned>()==2,"actual world adapter binds native bar/marker readback to current client revision");
    const auto normal=w::snapshot();
    check(normal.entities_created==8&&normal.entity_placements==16&&normal.live_parts==8,"normal counters exclude marker entities and placements");
    marker_readback_bad=true;const auto failed=w::tick(100,200,frame,3);
    check(failed.complete&&failed.live==8&&failed.placed==8&&normal_updates==3&&marker_updates==2&&marker_releases==1,"marker witness failure cleans only marker handles and preserves eight-part admission");
    report=dingosdk::Json::parse(w::grip_markers_report());
    check(report.at("phase").get<std::string>()=="sealed_no_rearm"&&report.at("live_handles").get<unsigned>()==0&&report.at("stop").get<std::string>()=="marker_readback_unqualified","terminal source failure remains explicit");
    check(!w::arm_grip_markers(scope_yes),"failed private trial cannot rearm");
    const auto after=w::tick(100,200,frame,4);
    check(after.complete&&normal_updates==4&&marker_updates==2,"normal world continues after marker failure with no private recreation");
    const auto inactive=w::tick(100,200,{},5);
    check(!inactive.complete&&normal_releases==1&&w::snapshot().live_parts==0,"normal inactive lifecycle still cleans normal eight parts");
    std::printf("BMX grip marker/world integration: %u checks passed\n",checks);
}
