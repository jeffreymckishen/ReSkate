#include "Extension/BMX/bmx_ride_trace.h"
#include <iostream>
#include <stdexcept>
#include <vector>
using namespace dingosdk::bmx;
namespace {
void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
}
int main(){try{
    ride_trace::History<3> history;
    ride_trace::Sample sample;sample.step.ready=true;sample.step.body_token=4;
    for(std::uint64_t serial=10;serial<=15;++serial){
        sample.step.serial=serial;sample.input.left_x=double(serial);
        sample.step.shadow.enabled=true;sample.step.shadow.evaluated=true;sample.step.shadow.valid=true;
        sample.step.shadow.serial=serial;sample.step.shadow.token=sample.step.body_token;
        sample.step.shadow.force={double(serial),0,0};
        require(history.record(sample),"fresh accepted ride step is recorded");
    }
    std::vector<std::uint64_t> serials;std::vector<double> inputs;
    history.each([&](const auto& row){serials.push_back(row.step.serial);inputs.push_back(row.input.left_x);});
    require(serials==std::vector<std::uint64_t>{13,14,15},"ring wrap preserves newest accepted steps in chronological order");
    require(inputs==std::vector<double>{13,14,15},"each retained input belongs to its accepted step");
    history.each([](const auto& row){
        require(row.step.shadow.enabled&&row.step.shadow.evaluated&&row.step.shadow.valid&&
            row.step.shadow.serial==row.step.serial&&row.step.shadow.token==row.step.body_token&&
            row.step.shadow.force[0]==double(row.step.serial),"fixed ride history retains the exact shadow report belonging to each accepted epoch");
    });
    require(history.size()==3&&history.token()==4,"history remains bounded and pinned to its mount");
    require(history.capacity()==3&&history.total_accepted()==6&&history.overwritten()==3&&
        history.first()->step.serial==13&&history.last()->step.serial==15,"retention counters and exact ring endpoints expose overwritten epochs");
    require(!history.record(sample),"duplicate step cannot rewrite evidence");sample.step.serial=14;
    require(!history.record(sample),"older native step cannot rewrite evidence");
    require(history.total_accepted()==6&&history.overwritten()==3,"invalid epochs do not inflate retention coverage");
    sample.step.serial=16;sample.step.body_token=5;
    require(!history.record(sample),"a different body token cannot join an existing mount history");
    require(history.seal()&&!history.seal(),"nonempty evidence seals exactly once");sample.step.body_token=4;
    require(!history.record(sample),"sealed impact evidence rejects later writes");
    history.reset();require(!history.size()&&!history.token()&&!history.seal(),"reset clears mount identity and leaves an empty history unsealed");
    require(!history.total_accepted()&&!history.overwritten()&&!history.first()&&!history.last(),"reset clears all retention metadata");
    sample.step.body_token=0;sample.step.serial=1;
    require(!history.record(sample),"missing body identity is never evidence");sample.step.body_token=5;sample.step.serial=0;
    require(!history.record(sample),"missing native serial is never evidence");sample.step.serial=1;
    require(history.record(sample),"new mount may begin with its own native serial");
    auto snapshot=history;sample.step.serial=2;require(history.record(sample),"live mount continues after snapshot");
    require(snapshot.size()==1,"copied evidence does not grow with the live history");
    snapshot.each([](const auto& row){require(row.step.serial==1&&row.step.body_token==5,"copied evidence retains its original serial and body");});
    sample.step.serial=3;sample.step.ready=false;require(!history.record(sample),"unaccepted chassis step is never recorded");
    {
        ride_trace::BufferPair<3,2> pair;unsigned allocations=0;
        const auto allocate=[&]{++allocations;return std::make_unique<ride_trace::History<3>>();};
        require(pair.prepare(allocate)&&pair.prepare(allocate)&&allocations==2,"both fixed buffers allocate only on first preparation");
        require(pair.begin(),"prepared private capture begins");sample.step.ready=true;sample.step.body_token=7;sample.step.serial=100;
        require(pair.record(sample)&&pair.freeze(false)==ride_trace::Freeze::ready,"nonempty first capture seals and swaps");
        const auto* first=pair.pending().first();require(first&&first->step.serial==100&&pair.captures()==1,"pending owns the sealed exact epoch");
        require(!pair.record(sample),"sealed former active data cannot accept an equal old epoch through recycled empty buffer without mount reset");
    }
    {
        ride_trace::BufferPair<3,2> pair;unsigned allocations=0;
        require(pair.prepare([&]{++allocations;return std::make_unique<ride_trace::History<3>>();}),"pair preparation");
        sample.step.ready=true;sample.step.body_token=7;sample.step.serial=100;require(pair.begin()&&pair.record(sample),"first capture records");
        require(pair.freeze(false)==ride_trace::Freeze::ready,"first capture freezes");const auto* first=pair.pending().first();
        require(pair.begin(),"next admitted mount resets recycled active only");sample.step.body_token=8;sample.step.serial=200;
        require(pair.record(sample)&&first->step.serial==100&&pair.pending().token()==7,"new live mount cannot mutate sealed pending evidence");
        require(pair.freeze(true)==ride_trace::Freeze::pending&&pair.captures()==1&&pair.pending().token()==7,"pending-report refusal cannot overwrite old evidence or spend another export");
        require(pair.begin(),"later mount can reset the refused sealed active history");sample.step.body_token=9;sample.step.serial=300;
        require(pair.record(sample)&&pair.freeze(false)==ride_trace::Freeze::ready,"second capture swaps after prior report consumption");
        require(pair.pending().first()!=first&&pair.pending().token()==9&&pair.captures()==2&&allocations==2,"distinct fixed storage swaps without allocating a third buffer");
        require(!pair.begin(),"exact per-process capture limit refuses a new long capture");
    }
    {
        ride_trace::BufferPair<3> pair;unsigned attempts=0;
        const auto failing=[&]()->std::unique_ptr<ride_trace::History<3>>{if(++attempts==2)throw std::bad_alloc();return std::make_unique<ride_trace::History<3>>();};
        require(!pair.prepare(failing)&&pair.failed()&&!pair.ready(),"second allocation failure commits neither fixed buffer");
        require(!pair.prepare(failing)&&attempts==2&&!pair.begin()&&!pair.record(sample),"allocation failure is latched without retries or a short-capture claim");
    }
    {
        ride_trace::BufferPair<1> pair;require(pair.prepare(),"eight-capture fixture prepares");
        for(unsigned capture=0;capture<ride_trace::long_capture_limit;++capture){
            sample.step.body_token=100+capture;sample.step.serial=1000+capture;
            require(pair.begin()&&pair.record(sample)&&pair.freeze(false)==ride_trace::Freeze::ready,"each of eight independent long captures seals once");
        }
        require(pair.captures()==8&&!pair.begin(),"ninth long capture is refused");
    }
    {
        auto large=std::make_unique<ride_trace::History<ride_trace::long_capacity>>();
        sample.step.ready=true;sample.step.body_token=55;
        for(unsigned i=1;i<=3602;++i){sample.step.serial=i;sample.step.native_simulation_seconds=double(i)*.02;require(large->record(sample),"long ring records only accepted epochs");}
        require(large->size()==3600&&large->total_accepted()==3602&&large->overwritten()==2&&large->first()->step.serial==3&&large->last()->step.serial==3602,"full long ring preserves newest3600 and honest discarded count");
        require(large->last()->step.native_simulation_seconds-large->first()->step.native_simulation_seconds>71,"sample capacity cannot be represented as guaranteed60seconds");
    }
    std::cout<<"ride trace history tests passed; Sample="<<sizeof(ride_trace::Sample)
        <<" History240="<<sizeof(ride_trace::History<>)<<" History3600="<<sizeof(ride_trace::History<ride_trace::long_capacity>)
        <<" LongPair="<<sizeof(ride_trace::BufferPair<>)<<" bytes\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
