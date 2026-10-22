#pragma once
#include "bmx_coupled_pose_debug.h"
#include <limits>
#include <type_traits>

namespace dingosdk::bmx::rider::forearm_debug {
inline constexpr std::size_t bone_count=395,rig_count=386;
inline constexpr float high_angle=.35f;
enum class Count:unsigned {selected_solves,neutral_eligible,uphill_eligible,ineligible,requested,baseline_valid,
    attempted,applied,requested_unready,ready,completed_writes,completed_requested,completed_applied,count};
inline constexpr std::array<const char*,static_cast<unsigned>(Count::count)> count_names{
    "selected_render_solves","neutral_eligible","uphill_eligible","ineligible","result_requested","result_baseline_valid",
    "result_attempted","result_applied","requested_unready","result_ready","completed_render_writes","completed_requested","completed_applied"};
inline constexpr std::array<const char*,10> range_names{"steer_rad","crank_phase_rad","pedal_effort","preload",
    "front_weight","rear_weight","landing_compression","air_extension_blend","uphill_blend","gaze_counterpitch_rad"};
struct Range {
    std::atomic<std::uint64_t> finite{},nonfinite{};
    std::atomic<float> low{std::numeric_limits<float>::infinity()},high{-std::numeric_limits<float>::infinity()};
    void sample(float value) noexcept {
        if(!std::isfinite(value)){nonfinite.fetch_add(1,std::memory_order_relaxed);return;}
        finite.fetch_add(1,std::memory_order_relaxed);
        auto before=low.load(std::memory_order_relaxed);
        while(value<before&&!low.compare_exchange_weak(before,value,std::memory_order_relaxed)){}
        before=high.load(std::memory_order_relaxed);
        while(value>before&&!high.compare_exchange_weak(before,value,std::memory_order_relaxed)){}
    }
    Json json() const {const auto n=finite.load();return Json{{"finite",n},{"nonfinite",nonfinite.load()},
        {"min",n?Json(low.load()):Json(nullptr)},{"max",n?Json(high.load()):Json(nullptr)}};}
};
struct Witness {
    std::uint64_t frame_revision{},contact_revision{};
    std::uintptr_t component{},holder{},pose_buffer{},render_data{};
};
struct Slot {
    // 0=empty,1=being copied,2=immutable snapshot published. Client export never
    // reads a partially copied fixture; only the atomic exit/write flags evolve.
    std::atomic<unsigned> state{};
    coupled_debug::Fixture fixture;
    Witness witness;
    bool neutral_eligible{},uphill_eligible{};
    std::atomic<bool> callback_exited{},completed_write{};
    std::atomic<std::uint64_t> later_matches_not_retained{};
    std::atomic<unsigned> exit_stage{static_cast<unsigned>(coupled_debug::Stage::solved)};
};
struct Buffers {std::array<Slot,2> slots;const pose::Rig* rig_identity{};};
class Store;
class Ticket {
    friend class Store;
    Store* store_{};Buffers* buffers_{};unsigned mask_{};
    const coupled_debug::Stage* stage_{};bool requested_{},applied_{},completed_{};
    Ticket(Store* store,Buffers* buffers,unsigned mask,const coupled_debug::Stage* stage,bool requested,bool applied) noexcept:
        store_(store),buffers_(buffers),mask_(mask),stage_(stage),requested_(requested),applied_(applied){}
public:
    Ticket()=default;
    Ticket(const Ticket&)=delete;
    Ticket& operator=(const Ticket&)=delete;
    ~Ticket();
    void completed() noexcept;
};
class Store {
    friend class Ticket;
    std::unique_ptr<Buffers> owner_; // client preparation only; never reset while callbacks exist
    std::atomic<Buffers*> buffers_{};
    std::array<std::atomic<std::uint64_t>,static_cast<unsigned>(Count::count)> counts_{};
    std::array<Range,range_names.size()> selected_ranges_,eligible_ranges_;
    void count(Count c) noexcept {counts_[static_cast<unsigned>(c)].fetch_add(1,std::memory_order_relaxed);}
public:
    std::atomic<bool> preparation_attempted{},preparation_failed{};
    std::atomic<std::uint64_t> shape_or_rig_mismatch{};
    template<class Factory> void prepare(const pose::Rig& rig,Factory&& factory) noexcept {
        if(preparation_attempted.exchange(true))return;
        try {
            if(rig.parents.size()!=rig_count||rig.bind.size()!=rig_count)throw std::runtime_error("unsupported diagnostic rig");
            auto prepared=factory();if(!prepared)throw std::bad_alloc();
            for(auto& slot:prepared->slots){slot.fixture.original.resize(bone_count);slot.fixture.rig=rig;}
            prepared->rig_identity=&rig;owner_=std::move(prepared);
            buffers_.store(owner_.get(),std::memory_order_release);
        }catch(...){preparation_failed.store(true,std::memory_order_release);}
    }
    void prepare(const pose::Rig& rig) noexcept {prepare(rig,[]{return std::make_unique<Buffers>();});}
    Ticket observe(bool rendering,const visual::Frame& frame,bool observed,const pose::Rig& rig,
        const std::vector<pose::Bone>& original,const pose::EntryContacts& entry,const pose::SpringBinding& binding,
        const pose::Result& result,Witness witness,coupled_debug::Stage& stage) noexcept {
        if(!rendering||!frame.forearm_repair_selected)return {};
        count(Count::selected_solves);
        const bool neutral=pose::forearm_repair_eligible(frame,observed),uphill=pose::uphill_forearm_repair_eligible(frame,observed);
        if(neutral)count(Count::neutral_eligible);if(uphill)count(Count::uphill_eligible);if(!neutral&&!uphill)count(Count::ineligible);
        if(result.forearm_repair_requested)count(Count::requested);
        if(result.forearm_baseline_valid)count(Count::baseline_valid);
        if(result.forearm_repair_attempted)count(Count::attempted);
        if(result.forearm_repair_applied)count(Count::applied);
        if(result.forearm_repair_requested&&!result.ready)count(Count::requested_unready);
        if(result.ready)count(Count::ready);
        const std::array<float,range_names.size()> values{frame.steer,frame.crank_phase,frame.pedal_effort,frame.preload,
            frame.front_weight,frame.rear_weight,frame.landing_compression,frame.air_extension_blend,frame.rider_uphill_blend,frame.rider_gaze_counterpitch};
        for(unsigned i=0;i<values.size();++i){selected_ranges_[i].sample(values[i]);if(neutral||uphill)eligible_ranges_[i].sample(values[i]);}
        auto* buffers=buffers_.load(std::memory_order_acquire);unsigned mask{};
        if(buffers){
            if(original.size()!=bone_count||buffers->rig_identity!=&rig){shape_or_rig_mismatch.fetch_add(1,std::memory_order_relaxed);}
            else {
                const std::array<bool,2> capture{(neutral||uphill)&&std::abs(frame.steer)>=high_angle&&frame.pedal_effort>0,
                    result.forearm_repair_attempted||(result.forearm_repair_requested&&!result.ready)};
                for(unsigned i=0;i<capture.size();++i){if(!capture[i])continue;auto& slot=buffers->slots[i];unsigned expected{};
                    if(!slot.state.compare_exchange_strong(expected,1,std::memory_order_acq_rel)){
                        slot.later_matches_not_retained.fetch_add(1,std::memory_order_relaxed);continue;}
                    // All variable storage was sized/copied on the client thread.
                    // These are fixed-size assignments and one bounded array copy.
                    std::copy(original.begin(),original.end(),slot.fixture.original.begin());
                    slot.fixture.frame=frame;slot.fixture.entry=entry;slot.fixture.binding=binding;
                    slot.fixture.result=result;slot.fixture.observed_selected=observed;slot.fixture.solved=true;
                    slot.fixture.stage=coupled_debug::Stage::solved;slot.witness=witness;
                    slot.neutral_eligible=neutral;slot.uphill_eligible=uphill;
                    slot.state.store(2,std::memory_order_release);mask|=1u<<i;
                }
            }
        }
        return Ticket(this,buffers,mask,&stage,result.forearm_repair_requested,result.forearm_repair_applied);
    }
    std::uint64_t value(Count c) const noexcept {return counts_[static_cast<unsigned>(c)].load();}
    const Slot* snapshot(unsigned index) const noexcept {const auto* b=buffers_.load(std::memory_order_acquire);
        return b&&index<b->slots.size()&&b->slots[index].state.load(std::memory_order_acquire)==2?&b->slots[index]:nullptr;}
    Json report() const {
        auto counts=Json::object(),selected=Json::object(),eligible=Json::object(),fixtures=Json::array(),states=Json::array();
        for(unsigned i=0;i<count_names.size();++i)counts[count_names[i]]=counts_[i].load();
        for(unsigned i=0;i<range_names.size();++i){selected[range_names[i]]=selected_ranges_[i].json();eligible[range_names[i]]=eligible_ranges_[i].json();}
        const auto* buffers=buffers_.load(std::memory_order_acquire);
        for(unsigned i=0;i<2;++i){const auto state=buffers?buffers->slots[i].state.load(std::memory_order_acquire):0;
            states.push_back(Json{{"state",!buffers?(preparation_failed.load()?"preparation_failed_no_retry":"not_prepared"):
                (state==2?"captured":state==1?"copy_in_progress":"unclaimed")},
                {"later_matches_not_retained",buffers?buffers->slots[i].later_matches_not_retained.load():0}});
            const auto* slot=snapshot(i);if(!slot){fixtures.push_back(nullptr);continue;}
            auto fixture=coupled_debug::fixture_json(slot->fixture);auto& f=fixture["frame"];auto& r=fixture["result"];
            f["forearm_repair_selected"]=slot->fixture.frame.forearm_repair_selected;
            const auto& result=slot->fixture.result;
            r["forearm_repair_requested"]=result.forearm_repair_requested;r["forearm_baseline_valid"]=result.forearm_baseline_valid;
            r["forearm_repair_attempted"]=result.forearm_repair_attempted;r["forearm_repair_applied"]=result.forearm_repair_applied;
            r["forearm_repair_extra_drop"]=result.forearm_repair_extra_drop;r["forearm_repair_evaluations"]=result.forearm_repair_evaluations;
            fixture["kind"]=i==0?"first_eligible_high_angle_loaded_render":"first_attempt_or_requested_invalid_render";
            fixture["neutral_eligible"]=slot->neutral_eligible;fixture["uphill_eligible"]=slot->uphill_eligible;
            fixture["callback_exited"]=slot->callback_exited.load(std::memory_order_acquire);
            fixture["completed_render_write"]=slot->completed_write.load(std::memory_order_acquire);
            fixture["callback_exit_stage"]=coupled_debug::names[slot->exit_stage.load()];
            const auto& w=slot->witness;
            fixture["publication"]=Json{{"frame_revision",w.frame_revision},{"contact_revision",w.contact_revision},
                {"component",w.component},{"holder",w.holder},{"pose_buffer",w.pose_buffer},{"render_data",w.render_data}};
            fixtures.push_back(std::move(fixture));
        }
        return Json{{"schema",1},{"preparation_attempted",preparation_attempted.load()},{"preparation_ready",buffers_.load()!=nullptr},{"preparation_failed",preparation_failed.load()},
            {"shape_or_rig_mismatch",shape_or_rig_mismatch.load()},{"counts",std::move(counts)},
            {"selected_input_ranges",std::move(selected)},{"eligible_input_ranges",std::move(eligible)},
            {"high_angle_threshold_rad",high_angle},{"snapshot_states",std::move(states)},{"snapshots",std::move(fixtures)},
            {"boundary","Process-lifetime selected render solves only. Ranges/counters are independently sampled atomics, not a joint frame. Snapshot bones/frame/result share one existing solve; completed write is separate. No fresh native-clock read, extra solve, repair adoption or visual acceptance. Eligibility includes uphill winners whose original Result flags remain unchanged."}};
    }
};
inline void Ticket::completed() noexcept {
    if(!store_||completed_)return;completed_=true;store_->count(Count::completed_writes);
    if(requested_)store_->count(Count::completed_requested);if(applied_)store_->count(Count::completed_applied);
    if(buffers_)for(unsigned i=0;i<2;++i)if(mask_&(1u<<i))buffers_->slots[i].completed_write.store(true,std::memory_order_release);
}
inline Ticket::~Ticket(){if(buffers_)for(unsigned i=0;i<2;++i)if(mask_&(1u<<i)){
    auto& slot=buffers_->slots[i];slot.exit_stage.store(static_cast<unsigned>(*stage_));slot.callback_exited.store(true,std::memory_order_release);}}
static_assert(std::is_trivially_copyable_v<visual::Frame> && std::is_trivially_copyable_v<pose::Result> &&
    std::is_trivially_copyable_v<pose::EntryContacts> && std::is_trivially_copyable_v<pose::SpringBinding>);
}
