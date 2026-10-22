#include "fixtures/bmx_coupled_native_pose.h"
#include "Extension/BMX/bmx_forearm_diagnostic.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

namespace d=dingosdk::bmx::rider::forearm_debug;
namespace c=dingosdk::bmx::rider::coupled_debug;
namespace p=dingosdk::bmx::rider::pose;
namespace v=dingosdk::bmx::visual;
using dingosdk::Json;
std::atomic<unsigned> allocations{};
void* operator new(std::size_t n){allocations.fetch_add(1);if(auto* result=std::malloc(n?n:1))return result;throw std::bad_alloc();}
void* operator new[](std::size_t n){return ::operator new(n);}
void operator delete(void* p) noexcept {std::free(p);}
void operator delete[](void* p) noexcept {std::free(p);}
void operator delete(void* p,std::size_t) noexcept {std::free(p);}
void operator delete[](void* p,std::size_t) noexcept {std::free(p);}
unsigned checks{};
void check(bool value,const char* why){++checks;if(!value){std::fprintf(stderr,"FAIL %s\n",why);std::exit(1);}}
v::Frame neutral(const actual276::Fixture& fixture){auto f=fixture.frame;f.spring_avatar={};f.coupled_posture_selected=f.coupled_motion_committed=false;
    f.forearm_repair_selected=true;f.mount_token=0;f.mount_progress=f.rider_blend=1;f.airborne=false;
    f.air_extension_available=true;f.air_extension_blend=0;f.rider_posture_available=false;f.rider_uphill_blend=f.rider_gaze_counterpitch=0;return f;}
int main(){
    const auto source=actual276::get();auto frame=neutral(source);p::EntryContacts entry;p::SpringBinding binding;
    p::Result valid;valid.ready=valid.forearm_repair_requested=valid.forearm_baseline_valid=true;
    c::Stage stage=c::Stage::solved;
    d::Store disabled;
    {auto t=disabled.observe(false,frame,false,source.rig,source.bones,entry,binding,valid,{},stage);t.completed();}
    frame.forearm_repair_selected=false;
    {auto t=disabled.observe(true,frame,false,source.rig,source.bones,entry,binding,valid,{},stage);t.completed();}
    check(disabled.value(d::Count::selected_solves)==0&&!disabled.preparation_attempted,"animation/unselected observers neither count nor prepare");
    frame.forearm_repair_selected=true;
    d::Store failed;unsigned factories{};
    failed.prepare(source.rig,[&]()->std::unique_ptr<d::Buffers>{++factories;throw std::bad_alloc();});
    failed.prepare(source.rig,[&]{++factories;return std::make_unique<d::Buffers>();});
    check(factories==1&&failed.preparation_failed&&!failed.snapshot(0),"allocation failure is sticky with no later allocation attempt");
    {auto t=failed.observe(true,frame,false,source.rig,source.bones,entry,binding,valid,{},stage);t.completed();}
    check(failed.value(d::Count::selected_solves)==1&&failed.value(d::Count::completed_writes)==1,"allocation failure remains observational and does not manufacture a capture");
    d::Store once;once.prepare(source.rig);once.prepare(source.rig,[]()->std::unique_ptr<d::Buffers>{throw std::bad_alloc();});
    check(once.preparation_attempted&&!once.preparation_failed,"successful preparation is not repeated");
    frame.steer=.1273f;frame.pedal_effort=1;
    {auto t=once.observe(true,frame,false,source.rig,source.bones,entry,binding,valid,{},stage);}
    check(!once.snapshot(0)&&once.value(d::Count::neutral_eligible)==1,"304-like low fork angle is eligible but not a high-angle snapshot");
    auto uphill=frame;uphill.rider_posture_available=true;uphill.rider_uphill_blend=.5f;
    p::Result preserved;preserved.ready=true;
    {auto t=once.observe(true,uphill,false,source.rig,source.bones,entry,binding,preserved,{},stage);t.completed();}
    check(once.value(d::Count::uphill_eligible)==1&&once.value(d::Count::requested)==1,
        "eligible uphill winner is counted independently of unchanged false Result.requested");
    frame.steer=.4f;frame.pedal_effort=0;
    {auto t=once.observe(true,frame,false,source.rig,source.bones,entry,binding,valid,{},stage);}
    check(!once.snapshot(0),"high fork angle without pedal load does not claim high-angle-loaded snapshot");
    frame.pedal_effort=1;
    for(unsigned exclusion=0;exclusion<3;++exclusion){auto bad=frame;if(exclusion==0)bad.airborne=true;if(exclusion==1)bad.preload=.1f;
        {auto t=once.observe(true,bad,exclusion==2,source.rig,source.bones,entry,binding,valid,{},stage);}
        check(!once.snapshot(0),"air/load/observed exclusions cannot become high-angle eligible snapshots");}
    auto bones=source.bones;bones[0].position[3]=std::bit_cast<float>(0x7fc12345u);bones[0].scale[3]=std::bit_cast<float>(0xffc12345u);
    frame.crank_phase=.7853981634f;
    const auto before=allocations.load();
    {auto t=once.observe(true,frame,false,source.rig,bones,entry,binding,valid,{12,13,14,15,16,17},stage);
        check(once.snapshot(0)&&!once.snapshot(0)->callback_exited,"complete copied snapshot can be read before its separate callback exit");
        stage=c::Stage::completed;t.completed();t.completed();}
    check(allocations.load()==before,"selected counter/range sampling and first capture allocate no memory in hook");
    check(once.snapshot(0)->callback_exited&&once.snapshot(0)->completed_write&&
        once.snapshot(0)->exit_stage==static_cast<unsigned>(c::Stage::completed),"completed write and final callback stage are separate from solve readiness");
    const auto original_snapshot=once.snapshot(0);frame.entity=999;bones[0].position[0]=123;
    {auto t=once.observe(true,frame,false,source.rig,bones,entry,binding,valid,{99},stage);t.completed();}
    check(once.snapshot(0)==original_snapshot&&original_snapshot->fixture.frame.entity==source.frame.entity&&
        original_snapshot->witness.frame_revision==12&&original_snapshot->fixture.original[0].position[0]!=123,"later frames/source mutations cannot replace first high-angle fixture");
    auto invalid=valid;invalid.ready=invalid.forearm_baseline_valid=false;frame.steer=.1f;stage=c::Stage::solved;
    {auto t=once.observe(true,frame,false,source.rig,bones,entry,binding,invalid,{22},stage);stage=c::Stage::owner_recheck;}
    check(once.snapshot(1)&&!once.snapshot(1)->completed_write&&once.snapshot(1)->callback_exited,
        "requested-invalid result is retained without inventing a completed write or search attempt");
    auto applied=invalid;applied.ready=applied.forearm_repair_attempted=applied.forearm_repair_applied=true;
    applied.forearm_repair_extra_drop=.006f;applied.forearm_repair_evaluations=9;
    {auto t=once.observe(true,frame,false,source.rig,bones,entry,binding,applied,{33},stage);t.completed();}
    check(once.snapshot(1)->witness.frame_revision==22&&!once.snapshot(1)->fixture.result.forearm_repair_attempted,
        "later successful repair cannot overwrite first requested-invalid solve");
    check(once.value(d::Count::attempted)==1&&once.value(d::Count::applied)==1&&once.value(d::Count::requested_unready)==1&&
        once.value(d::Count::completed_applied)==1,"attempt/apply/unready and completed-apply counts remain distinct");
    const auto parsed=Json::parse(once.report().dump());const auto& captured=parsed.at("snapshots").at(0);
    check(captured.at("original_bones").size()==395&&captured.at("rig").at("parents").size()==386,"deferred export retains exact native input shape");
    check(captured.at("original_bones").at(0).at("position_bits").at(3).get<std::uint32_t>()==0x7fc12345u&&
        captured.at("original_bones").at(0).at("scale_bits").at(3).get<std::uint32_t>()==0xffc12345u,"nonfinite native metadata W is preserved by float bits");
    check(captured.at("frame").at("forearm_repair_selected").get<bool>()&&
        captured.at("result").at("forearm_baseline_valid").get<bool>()&&
        !captured.at("result").at("forearm_repair_applied").get<bool>(),"forearm selection and Result fields are preserved beyond old coupled serializer");
    check(parsed.at("eligible_input_ranges").at("steer_rad").at("max").get<float>()==.4f&&
        parsed.at("counts").at("ineligible").get<unsigned>()==3,"eligible extents are separate from selected-only exclusion counts");
    d::Store racing;racing.prepare(source.rig);std::vector<std::thread> workers;
    for(unsigned i=1;i<=8;++i)workers.emplace_back([&,i]{auto f=neutral(source);f.steer=.39f;f.pedal_effort=1;f.position[0]=static_cast<float>(i);
        auto original=source.bones;original[0].position[0]=static_cast<float>(i);auto result=applied;result.hand_error=static_cast<float>(i);
        auto at=c::Stage::solved;for(unsigned n=0;n<8;++n){auto t=racing.observe(true,f,false,source.rig,original,entry,binding,result,{i},at);at=c::Stage::completed;t.completed();}});
    for(auto& worker:workers)worker.join();
    check(racing.value(d::Count::selected_solves)==64&&racing.value(d::Count::completed_writes)==64,"concurrent selected callbacks retain exact independent counters");
    for(unsigned i=0;i<2;++i){const auto* s=racing.snapshot(i);check(s&&s->fixture.frame.position[0]==s->fixture.original[0].position[0]&&
        s->fixture.result.hand_error==s->fixture.frame.position[0]&&s->witness.frame_revision==static_cast<unsigned>(s->fixture.frame.position[0]),
        "each concurrently claimed immutable snapshot is one coherent callback, not a mixture");}
    // One real solve verifies that passive capture preserves both its native
    // source and its control result, then the retained input can reproduce it.
    auto actual_frame=neutral(source);actual_frame.steer=.4f;actual_frame.pedal_effort=1;actual_frame.crank_phase=.7853981634f;
    auto actual=source.bones;const auto result=p::solve(actual,source.rig,actual_frame);
    check(result.ready&&result.forearm_repair_applied,"actual historical fixture supplies a genuine repaired solve");
    d::Store actual_capture;actual_capture.prepare(source.rig);stage=c::Stage::solved;
    const auto count_before=allocations.load();
    {auto t=actual_capture.observe(true,actual_frame,false,source.rig,source.bones,entry,binding,result,{},stage);t.completed();}
    check(allocations.load()==count_before,"actual first repair snapshot and completion do not allocate");
    const auto* saved=actual_capture.snapshot(1);auto replay=saved->fixture.original;
    const auto again=p::solve(replay,saved->fixture.rig,saved->fixture.frame);
    check(replay.size()==actual.size()&&!std::memcmp(replay.data(),actual.data(),actual.size()*sizeof(p::Bone))&&
        again.ready==result.ready&&again.forearm_repair_extra_drop==result.forearm_repair_extra_drop&&
        again.forearm_repair_evaluations==result.forearm_repair_evaluations,"same-callback immutable source/frame/rig reproduces actual repaired bytes and result");
    const auto repaired_json=Json::parse(actual_capture.report().dump()).at("snapshots").at(1).at("result");
    check(repaired_json.at("forearm_repair_requested").get<bool>()&&repaired_json.at("forearm_repair_attempted").get<bool>()&&
        repaired_json.at("forearm_repair_applied").get<bool>()&&!repaired_json.at("forearm_baseline_valid").get<bool>()&&
        repaired_json.at("forearm_repair_extra_drop").get<float>()==result.forearm_repair_extra_drop&&
        repaired_json.at("forearm_repair_evaluations").get<unsigned>()==result.forearm_repair_evaluations,
        "all six true/false forearm Result fields survive deferred serialization");
    check(once.report().at("snapshot_states").at(0).at("later_matches_not_retained").get<unsigned>()==1&&
        failed.report().at("snapshot_states").at(0).at("state").get<std::string>()=="preparation_failed_no_retry",
        "bounded first-only capture and unavailable preparation are explicit in export");
    std::printf("private forearm diagnostic: %u checks PASS; capture allocations0; two bounded snapshots\n",checks);
}
