#include "fixtures/bmx_coupled_native_pose.h"
#include <atomic>
#include <bit>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <thread>
#include <type_traits>

namespace p=dingosdk::bmx::rider::pose;
unsigned checks{};
void check(bool okay,const char* why){++checks;if(!okay){std::fprintf(stderr,"FAIL %s\n",why);std::exit(1);}}
bool exact(const std::vector<p::Transform>& a,const std::vector<p::Transform>& b){
    static_assert(sizeof(p::Transform)==32&&std::is_trivially_copyable_v<p::Transform>);
    return a.size()==b.size()&&!std::memcmp(a.data(),b.data(),a.size()*sizeof(p::Transform));
}
void compare(std::span<const p::Bone> bones,const p::Rig& rig,const char* why){
    const auto expected=p::compose_uncached(bones,rig),actual=p::compose(bones,rig);check(exact(expected,actual),why);
}
void scope_checks(const actual276::Fixture& fixture){
    static_assert(!std::is_copy_constructible_v<p::ComposeCacheScope>&&!std::is_copy_assignable_v<p::ComposeCacheScope>);
    static_assert(!std::is_move_constructible_v<p::ComposeCacheScope>&&!std::is_move_assignable_v<p::ComposeCacheScope>);
    check(p::active_compose_cache==nullptr,"ordinary composition has no cache scope");
    compare(fixture.bones,fixture.rig,"ordinary composition equals retained uncached function");
    {
        p::ComposeCacheScope outer;check(p::active_compose_cache==&outer.cache,"outer scope installs its own cache");
        compare(fixture.bones,fixture.rig,"outer cache composition exact");
        {
            p::ComposeCacheScope inner;check(p::active_compose_cache==&inner.cache,"nested scope owns distinct cache");
            compare(fixture.bones,fixture.rig,"nested cache composition exact");
        }
        check(p::active_compose_cache==&outer.cache,"normal nested destruction restores exact previous pointer");
        try{p::ComposeCacheScope inner;check(p::active_compose_cache==&inner.cache,"exception scope installed");throw 42;}
        catch(int value){check(value==42,"exception reaches caller");}
        check(p::active_compose_cache==&outer.cache,"exception unwinding restores exact previous pointer");
        compare(fixture.bones,fixture.rig,"outer composition remains exact after nested unwind");
        auto bones=fixture.bones;auto frame=fixture.frame;frame.spring_avatar={};frame.coupled_posture_selected=frame.coupled_motion_committed=false;
        frame.forearm_repair_selected=true;frame.mount_token=0;frame.mount_progress=frame.rider_blend=1;
        frame.air_extension_available=true;frame.air_extension_blend=0;frame.rider_posture_available=false;
        frame.rider_uphill_blend=frame.rider_gaze_counterpitch=0;frame.crank_phase=.7853981634f;frame.steer=.425f;frame.pedal_effort=1;
        const auto result=p::solve(bones,fixture.rig,frame);
        check(result.ready&&result.forearm_repair_applied,"private eligible full repair succeeds inside caller scope");
        check(p::active_compose_cache==&outer.cache,"public private solve restores caller scope");
        compare(fixture.bones,fixture.rig,"caller cache remains exact after full private solve");
    }
    check(p::active_compose_cache==nullptr,"outer normal destruction restores absent scope");
    try{p::ComposeCacheScope scope;throw 7;}catch(int value){check(value==7,"outer exception reaches caller");}
    check(p::active_compose_cache==nullptr,"outer exception restores absent scope");
    compare(fixture.bones,fixture.rig,"subsequent ordinary composition exact after all scope cleanup");
}
void mutation_checks(const actual276::Fixture& fixture){
    auto bones=fixture.bones;auto rig=fixture.rig;p::ComposeCacheScope scope;
    const auto snapshot=p::compose(bones,rig),snapshot_copy=snapshot;
    compare(bones,rig,"first cached source exact");compare(bones,rig,"unchanged cached source exact");
    bones[static_cast<std::size_t>(rig.hips)].position[1]+=.03f;
    compare(bones,rig,"ancestor translation invalidates descendants");
    bones[1].rotation=p::multiply(bones[1].rotation,p::axis(1,.17f));
    compare(bones,rig,"native root rotation invalidates descendants");
    bones[1].scale[0]*=1.01f;compare(bones,rig,"ancestor scale invalidates descendants");
    bones=fixture.bones;compare(bones,rig,"source reset invalidates changed locals");
    auto second=bones;second[static_cast<std::size_t>(rig.left_arm[1])].rotation=p::axis(2,.2f);
    compare(second,rig,"different source buffer at same topology exact");compare(bones,rig,"return to prior source buffer exact");
    check(exact(snapshot,snapshot_copy),"returned transform vectors retain snapshot value semantics");

    const auto* parent_address=rig.parents.data();const int saved_parent=rig.parents[static_cast<std::size_t>(rig.head)];
    check(saved_parent!=rig.spine[3],"reparent fixture actually changes topology");
    rig.parents[static_cast<std::size_t>(rig.head)]=rig.spine[3];
    check(parent_address==rig.parents.data(),"reparent fixture preserves parent address and count");
    compare(bones,rig,"same-address/count topology mutation invalidates hierarchy");
    rig.parents[static_cast<std::size_t>(rig.head)]=saved_parent;compare(bones,rig,"same-address topology restoration exact");
    auto other_rig=rig;compare(bones,other_rig,"different Rig identity with equal topology exact");
    compare(bones,rig,"switching back to former Rig exact");
    rig.parents.pop_back();compare(bones,rig,"smaller hierarchy invalidates cached size");
    rig.parents=fixture.rig.parents;compare(bones,rig,"restored hierarchy size exact");

    std::mt19937 random(0xC0FFEE);
    for(unsigned i=0;i<2000;++i){const auto j=static_cast<std::size_t>(random())%rig.parents.size();const unsigned op=random()%5;
        if(op==0)bones=fixture.bones;
        else if(op==1)bones[j].position[random()%3]+=(int(random()%21)-10)*.0001f;
        else if(op==2)bones[j].rotation=p::normal(p::multiply(bones[j].rotation,p::axis(random()%3,(int(random()%21)-10)*.001f)));
        else if(op==3)bones[j].scale[random()%3]*=1+(int(random()%21)-10)*.0001f;
        else bones[j].scale[3]=std::bit_cast<float>(random());
        compare(bones,rig,"local/ancestor/reset/metadata mutations preserve exact composition");
    }
}
void thread_checks(const actual276::Fixture& fixture){
    p::ComposeCacheScope caller;std::atomic<unsigned> ready{};std::array<bool,2> okay{true,true};std::array<std::uintptr_t,2> pointers{};
    const auto worker=[&](unsigned index){okay[index]=p::active_compose_cache==nullptr;
        {p::ComposeCacheScope scope;pointers[index]=reinterpret_cast<std::uintptr_t>(p::active_compose_cache);
            ready.fetch_add(1,std::memory_order_acq_rel);while(ready.load(std::memory_order_acquire)<2)std::this_thread::yield();
            auto bones=fixture.bones;const auto rig=fixture.rig;
            for(unsigned i=0;i<128;++i){bones[static_cast<std::size_t>(rig.hips)].position[index]+=.0001f;
                const auto expected=p::compose_uncached(bones,rig),actual=p::compose(bones,rig);
                okay[index]=okay[index]&&p::active_compose_cache==&scope.cache&&exact(expected,actual);}
        }okay[index]=okay[index]&&p::active_compose_cache==nullptr;
    };
    std::thread first(worker,0),second(worker,1);first.join();second.join();
    check(okay[0]&&okay[1],"concurrent independent cache scopes keep exact outputs and cleanup");
    check(pointers[0]!=pointers[1]&&pointers[0]!=reinterpret_cast<std::uintptr_t>(&caller.cache)&&pointers[1]!=reinterpret_cast<std::uintptr_t>(&caller.cache),
        "each concurrent thread owns a distinct active cache");
    check(p::active_compose_cache==&caller.cache,"worker threads never replace caller TLS scope");
    compare(fixture.bones,fixture.rig,"caller composition remains exact after concurrent workers");
}
int main(){const auto fixture=actual276::get();scope_checks(fixture);mutation_checks(fixture);thread_checks(fixture);
    check(p::active_compose_cache==nullptr,"all test cache scopes released");
    std::printf("PASS %u checks;2000 deterministic mutations, topology/source changes, value snapshots, nested/exception/private-solve cleanup and two-thread isolation\n",checks);
}
