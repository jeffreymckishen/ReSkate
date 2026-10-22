#include "Engine/Game/BMX/bmx_grip_probe_policy.h"
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <limits>
#include <vector>

namespace p=dingosdk::bmx::grip_probe_policy;
unsigned checks{};
void check(bool value,const char* why){++checks;if(!value){std::fprintf(stderr,"FAIL %s\n",why);std::exit(1);}}
p::StationarySample sample(unsigned step=0){
    p::StationarySample s;s.owner={1,2,3,4,5};s.token=17;s.wall=1001+step*17;s.serial=100+step;
    s.seconds=double(float(1./60));s.time=1+step*s.seconds;s.lease_serial=s.serial;s.lease_time=s.time;
    s.associated=s.fully_mounted=s.grounded_presentation=s.quiet_presentation=true;return s;
}
p::StationaryWindow armed(){p::StationaryWindow w;check(w.request(1000),"explicit request accepted");
    for(unsigned i=0;i<30;++i)check(w.observe(sample(i))==(i==29),"exactly30 stable samples before first record");
    check(w.armed&&w.count==1&&w.stable_samples==30,"30th sample begins finite capture");return w;}
int main(){
    p::StationaryScope scope{true,true,true,true,false};check(p::stationary_selected(scope),"exact scope selected");
    for(auto member:{&p::StationaryScope::requested,&p::StationaryScope::native_chassis,&p::StationaryScope::human_ride,&p::StationaryScope::private_profile}){
        auto bad=scope;bad.*member=false;check(!p::stationary_selected(bad),"each required scope proof necessary");}
    scope.conflict=true;check(!p::stationary_selected(scope)&&!p::stationary_selected({}),"conflict and ordinary scope remain off");
    p::StationaryWindow unused;for(unsigned i=0;i<200;++i)check(!unused.observe(sample(i)),"startup cannot consume capture without manual arm");
    check(!unused.used&&!unused.armed&&!unused.count&&!unused.request(0),"default window inert and zero tick refused");
    check(!unused.request(std::numeric_limits<std::uint64_t>::max()),"deadline overflow refused");
    auto complete=armed();for(unsigned i=30;i<157;++i)check(complete.observe(sample(i)),"one record per continuing native serial");
    check(complete.count==128&&complete.sealed&&complete.stop==p::StationaryStop::complete,"128 records seal while still mounted");
    check(!complete.observe(sample(157))&&!complete.request(10000)&&complete.count==128,"no recapture or overwrite after terminal");
    auto duplicate=armed();check(!duplicate.observe(sample(29))&&duplicate.duplicates==1&&duplicate.count==1,"exact duplicate does not consume capacity");
    auto changed=sample(29);changed.time+=.001;changed.lease_time=changed.time;
    check(!duplicate.observe(changed)&&duplicate.stop==p::StationaryStop::clock_rewound,"same-serial changed time seals clock discontinuity");
    duplicate=armed();changed=sample(29);changed.seconds*=2;
    check(!duplicate.observe(changed)&&duplicate.stop==p::StationaryStop::clock_rewound,"same-serial changed timestep seals immutable epoch");
    auto gap=armed();check(!gap.observe(sample(31))&&gap.sealed&&gap.serial_gaps==1&&gap.stop==p::StationaryStop::serial_gap,"post-arm serial gap seals");
    p::StationaryWindow settling;settling.request(1000);settling.observe(sample(0));settling.observe(sample(2));
    check(!settling.sealed&&settling.stable_samples==1&&settling.serial_gaps==1,"pre-arm gap restarts full qualification");
    auto rewind=armed();changed=sample(28);changed.wall=sample(30).wall;
    check(!rewind.observe(changed)&&rewind.stop==p::StationaryStop::clock_rewound,"native rewind seals");
    rewind=armed();changed=sample(30);changed.wall=1000;
    check(!rewind.observe(changed)&&rewind.stop==p::StationaryStop::clock_rewound,"wall rewind seals");
    p::StationaryWindow timeout;timeout.request(1000);timeout.expire(30999);check(!timeout.sealed,"arm deadline remains open before30s");
    timeout.expire(31000);check(timeout.sealed&&timeout.stop==p::StationaryStop::timeout&&!timeout.request(32000),"30s timeout consumes one shot");
    timeout=armed();timeout.expire(timeout.capture_wall+9999);check(!timeout.sealed,"capture before10s deadline open");
    timeout.expire(timeout.capture_wall+10000);check(timeout.sealed&&timeout.count==1&&timeout.stop==p::StationaryStop::timeout,"10s no-progress capture timeout seals finite records");
    for(auto member:{&p::Owner::client,&p::Owner::entity,&p::Owner::core,&p::Owner::context,&p::Owner::rig}){
        auto w=armed();auto s=sample(30);s.owner.*member+=1;
        check(!w.observe(s)&&w.sealed&&w.stop==p::StationaryStop::owner_changed,"all five owner fields immutable");}
    auto owner=armed();changed=sample(30);changed.token++;
    check(!owner.observe(changed)&&owner.stop==p::StationaryStop::owner_changed,"physical token immutable independent of mount presentation token");
    const std::vector<std::function<void(p::StationarySample&)>> invalid{
        [](auto& s){s.associated=false;},[](auto& s){s.fully_mounted=false;},[](auto& s){s.grounded_presentation=false;},
        [](auto& s){s.quiet_presentation=false;},[](auto& s){s.serial=0;},[](auto& s){s.lease_serial=0;},
        [](auto& s){s.position[0]=std::numeric_limits<float>::quiet_NaN();},[](auto& s){s.rotation={0,0,0,0};},
        [](auto& s){s.rotation[3]=std::numeric_limits<float>::infinity();},[](auto& s){s.requested_velocity[0]=1;},
        [](auto& s){s.seconds=0;},[](auto& s){s.lease_time-=.5;},[](auto& s){s.time=std::numeric_limits<double>::quiet_NaN();}
    };
    for(const auto& mutate:invalid){auto w=armed();auto s=sample(30);mutate(s);
        check(!w.observe(s)&&w.sealed&&w.stop==p::StationaryStop::activity&&w.count==1,"post-arm invalid or active presentation seals without an invalid record");
        p::StationaryWindow before;before.request(1000);before.observe(sample(0));s=sample(1);mutate(s);before.observe(s);
        check(!before.armed&&!before.sealed&&before.stable_samples==0,"activity before capture restarts qualification");}
    auto successor=armed();changed=sample(30);changed.lease_serial--;changed.lease_time-=changed.seconds;
    check(successor.observe(changed),"exact clock successor can associate historical active lease");
    auto drift=armed();for(unsigned i=30;i<80&&!drift.sealed;++i){auto s=sample(i);s.position[0]=float(i-29)*.0005f;drift.observe(s);}
    check(drift.stop==p::StationaryStop::activity&&drift.maximum_step_speed<.04&&drift.maximum_root_drift>.02,"whole-window root creep seals despite small steps");
    drift=armed();for(unsigned i=30;i<90&&!drift.sealed;++i){auto s=sample(i);const double a=(i-29)*.0005;
        s.rotation={0,float(std::sin(a/2)),0,float(std::cos(a/2))};drift.observe(s);}
    check(drift.stop==p::StationaryStop::activity&&drift.maximum_angular_speed<.25&&drift.maximum_rotation_drift>.02,"whole-window rotation creep seals despite small steps");
    auto withdrawn=armed();withdrawn.finish(p::StationaryStop::withdrawn);withdrawn.finish(p::StationaryStop::complete);
    check(withdrawn.sealed&&withdrawn.stop==p::StationaryStop::withdrawn&&!withdrawn.observe(sample(30)),"first terminal reason and buffer immutable");
    p::Window ramp;for(unsigned i=1;i<=3;++i)check(!ramp.observe(2,0,true,i,double(i),true),"legacy ramp retains first three airborne wait samples");
    check(ramp.observe(2,0,true,4,4,true)&&ramp.count==1&&ramp.armed,"legacy fourth airborne sample still arms without stationary command");
    check(!ramp.observe(2,0,true,4,4,true)&&ramp.duplicates==1,"legacy duplicate behavior retained");
    std::printf("PASS %u grip probe policy checks\n",checks);
}
