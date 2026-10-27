// The plugin host apart from the game: manifests, the reskate API, storage, modules, hot reload,
// and the sandbox against plugins written to break it (loops, memory, error floods, escapes).
#include "Extension/Plugins/plugin_content.h"
#include "Extension/Plugins/plugin_discovery.h"
#include "Extension/Plugins/plugin_host.h"
#include "Extension/Plugins/plugin_manifest.h"
#include "Extension/Plugins/plugin_session_feed.h"
#include "Extension/Plugins/plugin_wire.h"
#include "Extension/Throwdowns/challenge_registry.h"
#include "Extension/Throwdowns/custom_modes.h"
#include "Extension/Throwdowns/throwdown_kit.h"
#include "Engine/Vfs/mod_list.h"
#include "Engine/Core/Platform/plugin_time_budget.h"
#include "Engine/Core/Platform/launcher_support.h"
#include "Engine/Game/BMX/bmx_chassis_control.h"
#include "Engine/Game/BMX/bmx_interaction.h"
#include "Engine/Game/BMX/equipment_switch.h"
#include "Engine/Game/Input/input_lease_policy.h"
#include "Engine/Game/World/motion_refresh_probe.h"
#ifdef DINGOSDK_BODY_REACTIVATION_QUALIFICATION
#include "Engine/Game/World/body_reactivation_probe.h"
#endif
#include "Extension/BMX/bmx_world_transform.h"
#include "Extension/BMX/bmx_collision_envelope.h"
#include "Extension/Customization/board_material.h"
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <cmath>
#include <format>
#include <fstream>
#include <functional>
#include <memory>
#include <iostream>
#include <iterator>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>

using namespace dingosdk::plugins;
namespace plugin_ui = dingosdk::plugin_ui;
namespace owned_body = dingosdk::owned_body;
namespace body_query = dingosdk::body_query;
namespace game_input_pulse = dingosdk::game_input_pulse;
namespace board_material = dingosdk::board_material;
namespace mods = dingosdk::mods;
namespace {
void check(bool value, const std::string& message) { if (!value) throw std::runtime_error(message); }

std::filesystem::path scratch;


// The wider set's game, faked: it records what plugins asked of it and answers as told.
struct FakeGame final : Game {
    struct InputPulse { std::uint64_t owner{}; game_input_pulse::Receipt receipt{}; };
    std::map<std::uint64_t, InputPulse> input_pulses;
    std::vector<std::uint64_t> input_pulse_releases;
    std::uint64_t input_pulse_sequence{9007199254740994ULL};
    unsigned input_pulse_requests{}, input_pulse_reads{}, input_pulse_cancels{}, input_pulse_acks{};
    bool input_pulse_available{true};
    game_input_pulse::Reason input_pulse_refusal{game_input_pulse::Reason::unsupported_transport};
    std::uint64_t last_input_pulse_owner{};
    bool input_pulse_request(std::uint64_t owner, std::uint32_t user, std::uint16_t button,
        game_input_pulse::Handle& handle, game_input_pulse::Reason& reason) override {
        ++input_pulse_requests; last_input_pulse_owner = owner;
        if (!input_pulse_available) { reason = input_pulse_refusal; return false; }
        handle.sequence = ++input_pulse_sequence;
        auto& row = input_pulses[handle.sequence]; row.owner = owner;
        auto& r = row.receipt; r.handle = handle; r.user = user; r.button = button;
        r.requested_ms = r.observed_ms = 9007199254740997ULL;
        r.expires_ms = r.requested_ms + game_input_pulse::lifetime_ms;
        r.source_epoch = 9007199254741009ULL;
        reason = game_input_pulse::Reason::none; return true;
    }
    bool input_pulse_read(std::uint64_t owner, game_input_pulse::Handle handle, game_input_pulse::Receipt& receipt) override {
        ++input_pulse_reads;
        const auto at = input_pulses.find(handle.sequence);
        if (at == input_pulses.end() || at->second.owner != owner) return false;
        receipt = at->second.receipt; return true;
    }
    bool input_pulse_cancel(std::uint64_t owner, game_input_pulse::Handle handle) override {
        ++input_pulse_cancels;
        const auto at = input_pulses.find(handle.sequence);
        if (at == input_pulses.end() || at->second.owner != owner || game_input_pulse::terminal(at->second.receipt.status)) return false;
        auto& r = at->second.receipt; r.reason = game_input_pulse::Reason::cancelled;
        r.status = r.report_debt ? game_input_pulse::Status::releasing : game_input_pulse::Status::cancelled;
        if (!r.report_debt) r.claim_released = true;
        return true;
    }
    bool input_pulse_acknowledge(std::uint64_t owner, game_input_pulse::Handle handle) override {
        ++input_pulse_acks;
        const auto at = input_pulses.find(handle.sequence);
        if (at == input_pulses.end() || at->second.owner != owner || !game_input_pulse::terminal(at->second.receipt.status) ||
            at->second.receipt.report_debt || !at->second.receipt.claim_released || at->second.receipt.quarantined) return false;
        input_pulses.erase(at); return true;
    }
    void input_pulse_release_all(std::uint64_t owner) override {
        input_pulse_releases.push_back(owner);
        bool pulse_release_recorded{};
        for (auto at = input_pulses.begin(); at != input_pulses.end();) {
            if (at->second.owner != owner) { ++at; continue; }
            if (!pulse_release_recorded) { release_order.emplace_back(owner, "input_pulse"); pulse_release_recorded = true; }
            auto& r = at->second.receipt;
            if (r.report_debt) {
                r.orphaned = r.quarantined = true; r.status = game_input_pulse::Status::revoked;
                r.reason = game_input_pulse::Reason::cancelled; ++at;
            } else at = input_pulses.erase(at);
        }
    }
    struct InputTrace { std::uint64_t owner{}; dingosdk::input_trace::Receipt receipt{}; };
    std::map<std::uint64_t, InputTrace> input_traces;
    std::vector<std::uint64_t> input_trace_releases;
    std::uint64_t input_trace_sequence{9007199254740994ULL};
    unsigned input_trace_requests{}, input_trace_reads{}, input_trace_stops{}, input_trace_acks{};
    bool input_trace_request(std::uint64_t owner, dingosdk::input_trace::Handle& handle,
        dingosdk::input_trace::Reason& reason) override {
        ++input_trace_requests; handle.sequence = ++input_trace_sequence;
        auto& row = input_traces[handle.sequence]; row.owner = owner; row.receipt.handle = handle;
        row.receipt.requested_ms = 9007199254740997ULL; row.receipt.expires_ms = row.receipt.requested_ms + 5000;
        row.receipt.unknown_calls_at_start = 9007199254740998ULL; row.receipt.unknown_calls_total = 9007199254741008ULL;
        reason = dingosdk::input_trace::Reason::none; return true;
    }
    bool input_trace_read(std::uint64_t owner, dingosdk::input_trace::Handle handle, dingosdk::input_trace::Receipt& receipt) override {
        ++input_trace_reads;
        const auto at = input_traces.find(handle.sequence);
        if (at == input_traces.end() || at->second.owner != owner) return false;
        receipt = at->second.receipt; return true;
    }
    bool input_trace_stop(std::uint64_t owner, dingosdk::input_trace::Handle handle) override {
        ++input_trace_stops;
        const auto at = input_traces.find(handle.sequence);
        if (at == input_traces.end() || at->second.owner != owner) return false;
        at->second.receipt.status = dingosdk::input_trace::Status::stopped; return true;
    }
    bool input_trace_acknowledge(std::uint64_t owner, dingosdk::input_trace::Handle handle) override {
        ++input_trace_acks;
        const auto at = input_traces.find(handle.sequence);
        if (at == input_traces.end() || at->second.owner != owner || at->second.receipt.status == dingosdk::input_trace::Status::active) return false;
        input_traces.erase(at); return true;
    }
    void input_trace_release_all(std::uint64_t owner) override {
        input_trace_releases.push_back(owner);
        std::erase_if(input_traces, [owner](const auto& p) { return p.second.owner == owner; });
    }
    std::vector<std::pair<std::uint64_t, std::string>> release_order;
    struct NativeRecovery { std::uint64_t owner{}; dingosdk::skater_recovery::Receipt receipt{}; bool abandoned{}; };
    std::map<std::uint64_t, NativeRecovery> native_recoveries;
    std::vector<std::uint64_t> native_recovery_releases;
    std::uint64_t native_recovery_sequence{9007199254740994ULL}, native_recovery_requested_ms{1000};
    unsigned native_recovery_requests{}, native_recovery_reads{}, native_recovery_cancels{}, native_recovery_acks{};
    bool native_recovery_available{true};
    bool native_recovery_request(std::uint64_t owner, dingosdk::skater_recovery::Handle& handle,
        dingosdk::skater_recovery::Reason& reason) override {
        using namespace dingosdk::skater_recovery;
        ++native_recovery_requests;
        if (!native_recovery_available) { reason = Reason::unavailable; return false; }
        handle.sequence = ++native_recovery_sequence;
        auto& record = native_recoveries[handle.sequence]; record.owner = owner;
        record.receipt.handle = handle; record.receipt.requested_ms = native_recovery_requested_ms;
        reason = Reason::none; return true;
    }
    bool native_recovery_read(std::uint64_t owner, dingosdk::skater_recovery::Handle handle, dingosdk::skater_recovery::Receipt& receipt) override {
        ++native_recovery_reads;
        const auto at = native_recoveries.find(handle.sequence);
        if (at == native_recoveries.end() || at->second.abandoned || at->second.owner != owner) return false;
        receipt = at->second.receipt; return true;
    }
    bool native_recovery_cancel(std::uint64_t owner, dingosdk::skater_recovery::Handle handle) override {
        using namespace dingosdk::skater_recovery;
        ++native_recovery_cancels;
        const auto at = native_recoveries.find(handle.sequence);
        if (at == native_recoveries.end() || at->second.abandoned || at->second.owner != owner ||
            at->second.receipt.status != dingosdk::skater_recovery::Status::pending || at->second.receipt.true_entered) return false;
        at->second.receipt.status = dingosdk::skater_recovery::Status::cancelled; at->second.receipt.reason = Reason::cancelled; return true;
    }
    bool native_recovery_acknowledge(std::uint64_t owner, dingosdk::skater_recovery::Handle handle) override {
        using namespace dingosdk::skater_recovery;
        ++native_recovery_acks;
        const auto at = native_recoveries.find(handle.sequence);
        if (at == native_recoveries.end() || at->second.abandoned || at->second.owner != owner ||
            !terminal(at->second.receipt.status) || at->second.receipt.quarantined ||
            (at->second.receipt.unresolved && !at->second.receipt.actor_retired)) return false;
        native_recoveries.erase(at); return true;
    }
    void native_recovery_release_all(std::uint64_t owner) override {
        using namespace dingosdk::skater_recovery;
        native_recovery_releases.push_back(owner); release_order.emplace_back(owner, "recovery");
        for (auto at = native_recoveries.begin(); at != native_recoveries.end();) {
            if (at->second.owner != owner) { ++at; continue; }
            if (at->second.receipt.unresolved && !at->second.receipt.actor_retired) {
                at->second.abandoned = true; at->second.receipt.quarantined = true;
                at->second.receipt.status = dingosdk::skater_recovery::Status::invalidated; at->second.receipt.reason = Reason::owner_released; ++at;
            } else at = native_recoveries.erase(at);
        }
    }
    struct NativeAction { std::uint64_t owner{}; dingosdk::skater_action::Receipt receipt{}; };
    std::map<std::uint64_t, NativeAction> native_actions;
    std::vector<std::uint64_t> native_action_releases;
    std::uint64_t native_action_sequence{9007199254740994ULL};
    std::uint64_t native_action_requested_ms{1000};
    unsigned native_action_requests{}, native_action_reads{}, native_action_cancels{}, native_action_acks{};
    bool native_actions_available{true};
    bool native_action_request(std::uint64_t owner, dingosdk::skater_action::Kind kind, dingosdk::skater_action::Handle& handle,
        dingosdk::skater_action::Reason& reason) override {
        using namespace dingosdk::skater_action;
        ++native_action_requests;
        if (!native_actions_available) { reason = Reason::unavailable; return false; }
        handle.sequence = ++native_action_sequence;
        auto& record = native_actions[handle.sequence]; record.owner = owner;
        record.receipt.handle = handle; record.receipt.kind = kind; record.receipt.requested_ms = native_action_requested_ms;
        reason = Reason::none; return true;
    }
    bool native_action_read(std::uint64_t owner, dingosdk::skater_action::Handle handle, dingosdk::skater_action::Receipt& receipt) override {
        ++native_action_reads;
        const auto found = native_actions.find(handle.sequence);
        if (found == native_actions.end() || found->second.owner != owner) return false;
        receipt = found->second.receipt; return true;
    }
    bool native_action_cancel(std::uint64_t owner, dingosdk::skater_action::Handle handle) override {
        using namespace dingosdk::skater_action;
        ++native_action_cancels;
        const auto found = native_actions.find(handle.sequence);
        if (found == native_actions.end() || found->second.owner != owner || found->second.receipt.status != dingosdk::skater_action::Status::pending) return false;
        found->second.receipt.status = dingosdk::skater_action::Status::cancelled; found->second.receipt.reason = Reason::cancelled; return true;
    }
    bool native_action_acknowledge(std::uint64_t owner, dingosdk::skater_action::Handle handle) override {
        ++native_action_acks;
        const auto found = native_actions.find(handle.sequence);
        if (found == native_actions.end() || found->second.owner != owner || found->second.receipt.quarantined ||
            !dingosdk::skater_action::terminal(found->second.receipt.status)) return false;
        native_actions.erase(found); return true;
    }
    void native_action_release_all(std::uint64_t owner) override {
        release_order.emplace_back(owner, "equipment");
        native_action_releases.push_back(owner);
        std::erase_if(native_actions, [owner](const auto& pair) { return pair.second.owner == owner; });
    }
    struct OwnedBody {
        std::uint64_t owner{};
        owned_body::Handle handle{};
        owned_body::Definition definition{};
        owned_body::Sample sample{};
        owned_body::Sample latest{};
        owned_body::Mailbox mailbox{};
        bool released{}, quarantined{};
    };
    std::map<std::uint64_t, OwnedBody> owned;
    std::vector<std::uint64_t> body_releases;
    unsigned body_creates{}, body_submissions{}, body_release_calls{};
    unsigned body_submit_entries{}, body_receipt_calls{}, body_acknowledge_calls{};
    unsigned body_prepares{};
    std::string body_prepare_error;
    std::string body_prepare() override { ++body_prepares; return body_prepare_error; }
#include "body_follow_fake_game_fixture.inc"
#include "hop_inert_fake_game_fixture.inc"
#ifdef DINGOSDK_BODY_REACTIVATION_QUALIFICATION
    // Constructed facade/provider boundary only. The shared pure arm is supplied
    // by each fixture; this fake never parses RealGame launch environment/paths.
    std::function<bool(std::uint64_t, std::string_view, const std::filesystem::path&)> reactivation_admit;
    std::function<bool(std::uint64_t)> reactivation_current;
    std::function<void(std::uint64_t)> reactivation_close_arm;
    unsigned reactivation_begins{}, reactivation_polls{}, reactivation_provider_calls{}, reactivation_retirements{}, reactivation_closes{};
    std::uint64_t reactivation_owner{}, reactivation_sequence{}, reactivation_next{9007199254740994ULL};
    owned_body::Handle reactivation_body{};
    std::string reactivation_id, reactivation_begin_error;
    std::filesystem::path reactivation_directory;
    bool reactivation_access{}, reactivation_cleanup_duty{}, reactivation_zero_sequence{};
    dingosdk::body_reactivation_probe::Result reactivation_result{};
    std::string begin_body_reactivation_probe(std::uint64_t owner, std::string_view id,
        const std::filesystem::path& directory, const owned_body::Handle& body, std::uint64_t& sequence) override {
        ++reactivation_begins; sequence = 0;
        reactivation_id = id; reactivation_directory = directory;
        if (!reactivation_admit || !reactivation_admit(owner, id, directory)) return "qualification arm unavailable";
        ++reactivation_provider_calls;
        if (!reactivation_begin_error.empty()) return reactivation_begin_error;
        auto* selected = body_of(owner, body);
        if (!selected || selected->released || selected->quarantined ||
            reactivation_next == std::numeric_limits<std::uint64_t>::max()) return "body or sequence unavailable";
        reactivation_owner = owner; reactivation_body = body; reactivation_sequence = ++reactivation_next;
        reactivation_access = reactivation_cleanup_duty = true;
        reactivation_result = {};
        reactivation_result.phase = dingosdk::body_reactivation_probe::Phase::await_initial_park;
        reactivation_result.cleanup_owed = true;
        reactivation_result.target_position = selected->definition.position;
        reactivation_result.target_rotation = selected->definition.rotation;
        // Model only the required public-authority transition at begin return.
        selected->released = true; selected->mailbox.cancel(); ++reactivation_retirements;
        sequence = reactivation_zero_sequence ? 0 : reactivation_sequence;
        return {};
    }
    std::string poll_body_reactivation_probe(std::uint64_t owner, const owned_body::Handle& body,
        std::uint64_t sequence, dingosdk::body_reactivation_probe::Result& out) override {
        ++reactivation_polls; out = {};
        if (!reactivation_access || !owner || owner != reactivation_owner || body != reactivation_body ||
            !sequence || sequence != reactivation_sequence || !reactivation_current || !reactivation_current(owner))
            return "foreign, stale or revoked qualification";
        out = reactivation_result; return {};
    }
    void close_reactivation_fixture(std::uint64_t owner) {
        if (reactivation_close_arm) reactivation_close_arm(owner);
        if (!owner || owner != reactivation_owner || !reactivation_access) return;
        reactivation_access = false; ++reactivation_closes;
        // Result access closes; independent provider cleanup duty survives.
    }
#endif
    struct SyncProbe {
        std::uint64_t owner{},sequence{};
        owned_body::Handle handle{};
        dingosdk::body_sync_probe::Result result{};
    } sync_probe;
    std::uint64_t sync_probe_sequence{20};
    unsigned sync_probe_starts{},sync_probe_polls{};
    std::string body_begin_sync_probe(std::uint64_t owner,const owned_body::Handle& h,std::uint64_t& sequence) override {
        ++sync_probe_starts;sequence=0;
        auto* b=body_of(owner,h);
        if (!b || b->released || b->quarantined ||
            (sync_probe.sequence && sync_probe.result.status==dingosdk::body_sync_probe::Status::pending)) return "owner, generation or occupied observer";
        b->sample.epoch.serial=9007199254740994ULL;
        sync_probe={};sync_probe.owner=owner;sync_probe.handle=h;sync_probe.sequence=++sync_probe_sequence;
        sync_probe.result.armed_epoch=b->sample.epoch;
        sequence=sync_probe.sequence;return {};
    }
    std::string body_poll_sync_probe(std::uint64_t owner,const owned_body::Handle& h,std::uint64_t sequence,dingosdk::body_sync_probe::Result& out) override {
        ++sync_probe_polls;out={};
        if (!sequence || sync_probe.owner!=owner || sync_probe.handle!=h || sync_probe.sequence!=sequence) return "foreign or stale probe";
        out=sync_probe.result;return {};
    }
    void complete_sync_probe() {
        namespace s=dingosdk::body_sync_probe;
        auto& out=sync_probe.result;out.status=s::Status::observed;out.observed_mask=15;out.rejected=2;out.dropped=3;
        for(std::size_t i=0;i<out.records.size();++i) {
            auto& r=out.records[i];r.present=r.pending_before=r.transform_matches=true;r.pending_after=false;
            r.before_flags=0x80000001u;r.after_flags=0x80000000u;
            r.supplied={1,0,0,0,0,1,0,0,0,0,1,0,5,6,7,1};
            r.com_position={1,2,3};r.origin={5,6,7};r.local_com={.1f,.2f,.3f};r.rotation=r.local_rotation={0,0,0,1};
            r.epoch=out.armed_epoch;r.epoch.serial+=static_cast<std::uint64_t>(i+1);r.epoch.time+=static_cast<double>(i+1)*r.epoch.seconds;
        }
        out.observed_epoch=out.records.back().epoch;++out.observed_epoch.serial;out.observed_epoch.time+=out.observed_epoch.seconds;
    }
    // Constructed actor observations exercise only the real Host binding. They
    // are not native actor identity, callback routing or consumption evidence.
    struct MotionRefreshProbe {
        std::uint64_t owner{}, sequence{};
        double admitted_ms{}, deadline_ms{};
        dingosdk::motion_refresh_probe::Result result{};
    } motion_refresh;
    dingosdk::motion_refresh_probe::Epoch motion_refresh_actor{
        9007199254740995ULL, 9007199254740997ULL, 0, 9007199254741001ULL,
        10.0, static_cast<float>(owned_body::native_seconds)};
    std::uint64_t motion_refresh_sequence{9007199254740994ULL};
    double motion_refresh_now_ms{1000};
    unsigned motion_refresh_starts{}, motion_refresh_polls{}, motion_refresh_cancels{};
    bool motion_refresh_actor_available{true}, motion_refresh_zero_sequence{};
    std::string motion_refresh_begin_error, motion_refresh_poll_error;
    std::string begin_motion_refresh_probe(std::uint64_t owner, std::uint64_t& sequence) override {
        ++motion_refresh_starts; sequence = 0;
        if (!motion_refresh_begin_error.empty()) return motion_refresh_begin_error;
        if (!owner || !motion_refresh_actor_available) return "qualified current actor unavailable";
        if (motion_refresh.sequence && motion_refresh.result.status == dingosdk::motion_refresh_probe::Status::pending)
            return "actor observer occupied";
        if (motion_refresh_sequence == std::numeric_limits<std::uint64_t>::max()) return "observer sequence exhausted";
        motion_refresh = {};
        motion_refresh.owner = owner; motion_refresh.sequence = ++motion_refresh_sequence;
        motion_refresh.admitted_ms = motion_refresh_now_ms;
        motion_refresh.deadline_ms = motion_refresh_now_ms + dingosdk::motion_refresh_probe::lifetime_ms;
        motion_refresh.result.armed_epoch = motion_refresh_actor;
        sequence = motion_refresh_zero_sequence ? 0 : motion_refresh.sequence;
        return {};
    }
    std::string poll_motion_refresh_probe(std::uint64_t owner, std::uint64_t sequence,
        dingosdk::motion_refresh_probe::Result& out) override {
        ++motion_refresh_polls; out = {};
        if (!sequence || motion_refresh.owner != owner || motion_refresh.sequence != sequence)
            return "foreign or stale actor observation";
        if (!motion_refresh_poll_error.empty()) return motion_refresh_poll_error;
        // Fixture facts are controlled by the test. This leaf does not model
        // callback collection, actor refresh, native expiry or confirmation.
        out = motion_refresh.result;
        return {};
    }
    void cancel_motion_refresh_probe(std::uint64_t owner) {
        if (owner && motion_refresh.sequence && motion_refresh.owner == owner) {
            motion_refresh = {}; ++motion_refresh_cancels;
        }
    }
    void complete_motion_refresh_probe() {
        namespace m = dingosdk::motion_refresh_probe;
        auto& out = motion_refresh.result;
        out.status = m::Status::observed; out.client_revalidated = true; out.elapsed_ms = 25;
        auto& record = out.record;
        record.present = record.unchanged_forwarding = true;
        record.flag = 0xa5; record.input = {.125f, -.25f, .5f, 1};
        record.before_epoch = out.armed_epoch;
        ++record.before_epoch.serial; record.before_epoch.time += record.before_epoch.seconds;
        record.after_epoch = record.before_epoch;
        out.confirmed_epoch = record.after_epoch;
        ++out.confirmed_epoch.serial; out.confirmed_epoch.time += out.confirmed_epoch.seconds;
        const auto matrix = [](float position) -> m::Matrix {
            return {1,0,0,0, 0,1,0,0, 0,0,1,0, position,6,7,1};
        };
        for (auto* endpoints : {&record.before, &record.after}) {
            endpoints->root = matrix(5); endpoints->inverse = matrix(-5);
            for (std::size_t i = 0; i < endpoints->caches.size(); ++i)
                endpoints->caches[i] = matrix(20 + static_cast<float>(i));
            for (std::size_t i = 0; i < endpoints->packets.size(); ++i) {
                endpoints->packets[i] = matrix(40 + static_cast<float>(i));
                endpoints->flags[i] = 0x80000000u + static_cast<std::uint32_t>(i);
            }
        }
        // These are independent lower bounds, not an additive partition or a
        // bound on dropped counts. actor_epoch zero is an intentional valid case.
        out.routing = {128, 200, 201, 202, 203, true};
    }
    bool test_body_release_refused{};
    std::string test_body_create_refusal, test_body_submit_refusal;
    unsigned body_create_calls{}, body_read_calls{};
    bool test_body_read_unavailable{};
    bool batch_ground_plane{};
    std::uint64_t body_command_sequence{};
    unsigned query_cast_cost{1}, native_casts{}, batch_calls{}, batch_rays{};
    bool batch_available{true}, batch_clear{}, batch_unqualified{}, batch_change_after{}, batch_bad_count{};
    unsigned batch_drift_field{};
    unsigned batch_failure_ray{std::numeric_limits<unsigned>::max()};
    body_query::Failure batch_refusal{body_query::Failure::none};
    unsigned batch_refusal_casts{};
    bool batch_refusal_accounting_valid{true};
    body_query::Request last_batch;
    std::string body_create(std::uint64_t owner, const owned_body::Definition& definition, owned_body::Handle& handle) override {
        ++body_create_calls;
        if (!owned_body::valid(definition) || owned.size() >= owned_body::retained_capacity) return "definition or capacity";
        if (!test_body_create_refusal.empty()) return test_body_create_refusal;
        ++body_creates; handle = {body_creates, body_creates - 1};
        auto& b = owned[handle.generation]; b.owner = owner; b.handle = handle; b.definition = definition;
        b.sample.epoch = {77, handle.generation, 100, 3, static_cast<float>(owned_body::native_seconds)};
        b.sample.position = definition.position; b.sample.rotation = definition.rotation; b.sample.mass = definition.mass; b.sample.inertia = definition.inertia;
        return {};
    }
    OwnedBody* body_of(std::uint64_t owner, const owned_body::Handle& h) {
        const auto at = owned.find(h.generation);
        return at != owned.end() && at->second.owner == owner && at->second.handle == h ? &at->second : nullptr;
    }
    std::string body_read(std::uint64_t owner, const owned_body::Handle& h, owned_body::Sample& sample) override {
        ++body_read_calls;
        if (test_body_read_unavailable) return "constructed sample unavailable";
        auto* b = body_of(owner, h); if (!b || b->released || b->quarantined) return "owner or generation";
        b->latest = b->sample; (void)b->mailbox.observe_successor(b->sample); sample = b->sample; return {};
    }
    std::string body_submit(std::uint64_t owner, const owned_body::Handle& h, const owned_body::Command& command, std::uint64_t& sequence) override {
        ++body_submit_entries; // Count entry even when the backend rejects a zero/invalid packet.
        sequence = 0;
        if (!test_body_submit_refusal.empty()) return test_body_submit_refusal;
        auto* b = body_of(owner, h);
        if (!b || b->released || body_command_sequence == std::numeric_limits<std::uint64_t>::max() ||
            !b->mailbox.submit(command, b->sample.epoch, 0, body_command_sequence + 1)) return "owner, generation or packet";
        sequence = ++body_command_sequence; ++body_submissions; return {};
    }
    int batch_contact_mode{};
    unsigned batch_available_corruptions{};
    // Constructed category sidecars, copied in after execute like the native adapter:
    // 1 into opted-in hits, 2 into hits even without the opt-in, 3 onto clear rows of
    // an available result, 4 onto a refused result's first row.
    int batch_category_mode{};
    std::array<std::uint32_t, body_query::maximum_rays> batch_categories{};
    std::array<bool, body_query::maximum_rays> batch_category_missing{};
    // Constructed owner slots, the same way: 1 into opted-in hits, 2 into hits even
    // without the opt-in, 3 onto clear rows of an available result.
    int batch_owner_mode{};
    std::array<std::uint32_t, body_query::maximum_rays> batch_owners{};
    std::array<bool, body_query::maximum_rays> batch_owner_missing{};
    // Constructed backend facts, put on every result whether or not it was asked for.
    bool batch_claims_local_actor{}, batch_claims_named_categories{};
    body_query::Result body_probe_batch(std::uint64_t owner, const owned_body::Handle& h, const body_query::Request& request, unsigned allowed) override {
        ++batch_calls; last_batch = request;
        if (batch_refusal != body_query::Failure::none) {
            body_query::Result out; out.count = request.count; out.failure = batch_refusal;
            out.native_casts = batch_refusal_casts; out.accounting_valid = batch_refusal_accounting_valid;
            out.local_actor_excluded = batch_claims_local_actor; out.named_actor_categories_absent = batch_claims_named_categories;
            if (batch_category_mode == 4) { out.rays[0].status = body_query::Status::hit; out.rays[0].in_categories = 9; out.rays[0].in_categories_available = true; }
            native_casts += out.native_casts; return out;
        }
        auto* selected = body_of(owner, h);
        unsigned fences{}, rays{};
        const auto fence = [&] {
            if (!selected || selected->released || selected->quarantined || !body_query::same_sample(selected->sample, request.observation) ||
                !body_query::same_sample(selected->latest, request.observation) ||
                (++fences > 1 && batch_change_after)) return false;
            for (std::size_t i = 0; i < request.exclusions; ++i) {
                const auto* other = body_of(owner, request.excluded[i]);
                if (!other || other->released || other->quarantined || other->sample.epoch.world != request.observation.epoch.world) return false;
            }
            return true;
        };
        auto result=body_query::execute(request, allowed, 1000, [&](const body_query::Ray& ray, unsigned permitted) {
            ++batch_rays; const auto index = rays++;
            if (!index && batch_drift_field) {
                switch (batch_drift_field) {
                case 1: selected->sample.position[0] += .001f; break;
                case 2: selected->sample.velocity[1] += .001f; break;
                case 3: selected->sample.angular_velocity[2] += .001f; break;
                case 4: selected->sample.rotation[0] += .001f; break;
                }
            }
            const auto cast_count = std::min(permitted, query_cast_cost); native_casts += cast_count;
            body_query::Probe out; out.native_casts = batch_bad_count ? permitted + 1 : cast_count;
            out.budget_exhausted = cast_count < query_cast_cost;
            if (!batch_available || !cast_count || out.budget_exhausted || index == batch_failure_ray) return out;
            out.hit.status = batch_clear ? body_query::Status::clear : body_query::Status::hit;
            for (std::size_t i = 0; i < ray.from.size(); ++i) out.hit.position[i] = (ray.from[i] + ray.to[i]) * .5f;
            out.hit.fraction = .5f; out.hit.body = batch_unqualified || batch_clear ? 0 : 1;
            if (batch_ground_plane && !batch_clear) {
                // Constructed fixture geometry only; the shared query fences still apply.
                const float dy = ray.to[1] - ray.from[1];
                const float fraction = dy != 0 ? -ray.from[1] / dy : std::numeric_limits<float>::quiet_NaN();
                if (!std::isfinite(dy) || !std::isfinite(fraction) || fraction < 0 || fraction > 1) {
                    out.hit = {};
                    out.hit.status = body_query::Status::clear;
                    return out; // Preserve this attempted cast's actual accounting.
                }
                out.hit.fraction = fraction;
                for (std::size_t i = 0; i < ray.from.size(); ++i)
                    out.hit.position[i] = ray.from[i] + (ray.to[i] - ray.from[i]) * fraction;
            }
            if (batch_contact_mode && !batch_clear) {
                out.hit.normal_available=out.hit.surface_velocity_available=true;
                out.hit.normal={0,1,0};out.hit.surface_velocity={2,0,-1};
                if (batch_contact_mode==2) out.hit.normal[1]=std::numeric_limits<float>::quiet_NaN();
                if (batch_contact_mode==3) out.hit.normal[1]=-1;
            }
            return out;
        }, fence);
        // Deliberately malformed AVAILABLE results exercise the binding's own
        // independent result guard, after the shared query core has accepted.
        if(result.available && batch_contact_mode>=4) {
            ++batch_available_corruptions;
            if(batch_contact_mode==4)result.rays[0].normal[1]=std::numeric_limits<float>::quiet_NaN();
            if(batch_contact_mode==5)result.rays[0].normal[1]=-1;
            if(batch_contact_mode==6)result.rays[0].surface_velocity_available=false;
        }
        for (std::size_t i = 0; result.available && batch_category_mode >= 1 && batch_category_mode <= 3 && i < result.count; ++i) {
            auto& hit = result.rays[i];
            const bool copied = batch_category_mode == 3 ? hit.status == body_query::Status::clear :
                hit.status == body_query::Status::hit && !batch_category_missing[i] &&
                (request.include_shape_categories || batch_category_mode == 2);
            if (copied) { hit.in_categories = batch_categories[i]; hit.in_categories_available = true; }
        }
        for (std::size_t i = 0; result.available && batch_owner_mode >= 1 && batch_owner_mode <= 3 && i < result.count; ++i) {
            auto& hit = result.rays[i];
            const bool copied = batch_owner_mode == 3 ? hit.status == body_query::Status::clear :
                hit.status == body_query::Status::hit && !batch_owner_missing[i] && (request.include_hit_owner || batch_owner_mode == 2);
            if (copied) { hit.owner = batch_owners[i]; hit.owner_available = true; hit.owner_assigned = batch_owners[i] != 0xffffffffU; }
        }
        if (result.available) {
            result.local_actor_excluded = batch_claims_local_actor; result.named_actor_categories_absent = batch_claims_named_categories;
        }
        return result;
    }
    std::string body_receipt(std::uint64_t owner, const owned_body::Handle& h, std::uint64_t selected, owned_body::Receipt& receipt) override {
        ++body_receipt_calls;
        auto* b = body_of(owner, h); if (!b) return "owner or generation";
        if (!b->released && !b->quarantined && b->mailbox.needs_successor()) {
            b->latest = b->sample; (void)b->mailbox.observe_successor(b->sample);
        }
        if (!b->mailbox.find(selected, receipt)) return "receipt sequence unavailable";
        receipt.retained = b->released; receipt.quarantined = b->quarantined; return {};
    }
    std::string body_acknowledge(std::uint64_t owner, const owned_body::Handle& h, std::uint64_t sequence) override {
        ++body_acknowledge_calls;
        auto* b = body_of(owner, h); return b && b->mailbox.acknowledge(sequence) ? std::string{} : "not ready to acknowledge";
    }
    std::string body_release(std::uint64_t owner, const owned_body::Handle& h) override {
        ++body_release_calls;
        if (test_body_release_refused) return "constructed unknown park";
        auto* b = body_of(owner, h); if (!b) return "owner or generation";
        b->released = true; b->mailbox.cancel();
        if (sync_probe.owner==owner && sync_probe.handle==h && sync_probe.result.status==dingosdk::body_sync_probe::Status::pending)
            sync_probe.result.status=dingosdk::body_sync_probe::Status::invalidated;
        return {};
    }
    void body_release_all(std::uint64_t owner) override {
        close_follow_fixture(owner);
        cancel_motion_refresh_probe(owner); // No owned-body prerequisite; repeated close is idempotent.
#ifdef DINGOSDK_BODY_REACTIVATION_QUALIFICATION
        close_reactivation_fixture(owner);
#endif
        release_order.emplace_back(owner, "body");
        body_releases.push_back(owner);
        if (sync_probe.owner==owner && sync_probe.result.status==dingosdk::body_sync_probe::Status::pending)
            sync_probe.result.status=dingosdk::body_sync_probe::Status::invalidated;
        for (auto& [id, b] : owned) { (void)id; if (b.owner == owner) { b.released = true; b.mailbox.cancel(); } }
    }
    void body_producer_step(bool complete = true) {
        for (auto& [id, b] : owned) {
            (void)id; if (b.released || b.quarantined) continue;
            ++b.sample.epoch.serial; b.sample.epoch.time += b.sample.epoch.seconds;
            owned_body::Command out;
            if (b.mailbox.consume(b.sample.epoch, 1, out)) {
                (void)b.mailbox.finish(true, complete, complete);
                if (!complete) b.quarantined = true;
            }
        }
    }
    struct Effect { std::string owner; EffectRequest request; bool stopped{}; float alpha{1}; };
    std::map<std::uint64_t, Effect> effects;
    std::uint64_t effect_serial{}, effect_epoch{1};
    bool effects_ready{true};
    std::uint64_t effect_create(std::string_view plugin, const EffectRequest& request) override {
        if (!effects_ready) return 0;
        const auto id = ++effect_serial;
        effects.emplace(id, Effect{std::string(plugin), request});
        return id;
    }
    void effect_move(std::string_view plugin, std::uint64_t id, const EffectMatrix& matrix) override {
        if (auto it = effects.find(id); it != effects.end() && it->second.owner == plugin) it->second.request.transform = matrix;
    }
    void effect_stop(std::string_view plugin, std::uint64_t id) override {
        if (auto it = effects.find(id); it != effects.end() && it->second.owner == plugin) it->second.stopped = true;
    }
    void effect_opacity(std::string_view plugin, std::uint64_t id, float value) override {
        if (auto it = effects.find(id); it != effects.end() && it->second.owner == plugin) it->second.alpha = value;
    }
    void effect_release(std::string_view plugin, std::uint64_t id) override {
        if (auto it = effects.find(id); it != effects.end() && it->second.owner == plugin) effects.erase(it);
    }
    std::vector<std::uint64_t> effects_live(std::string_view plugin) override {
        std::vector<std::uint64_t> result;
        for (const auto& [id, e] : effects) if (e.owner == plugin) result.push_back(id);
        return result;
    }
    void effects_clear(std::string_view plugin) override { std::erase_if(effects, [&](const auto& e) { return e.second.owner == plugin; }); }
    std::pair<bool, std::uint64_t> effects_state() override { return {effects_ready, effect_epoch}; }
    std::optional<std::uint32_t> state;
    std::uint64_t wipe{};
    std::vector<std::string> calls;
    std::vector<ChatLine> lines;
    Track now_playing;
    ThrowdownState throwdown;
    std::vector<std::pair<std::string, std::string>> presses;
    std::map<std::string, std::uint32_t> binds;
    std::vector<std::string> released;
    std::string camera_refusal, camera_hold_error = "waiting for the native camera";
    std::optional<std::uint32_t> physics_state() override { return state; }
    std::uint64_t wipeouts() override { return wipe; }
    std::string outfit_set(std::string_view plugin, std::string_view slot, std::string_view item, std::vector<float> placement, bool covers) override {
        calls.push_back(std::format("outfit {} {} {} {} {}", plugin, slot, item, placement.size(), covers));
        return {};
    }
    void outfit_clear(std::string_view plugin, std::string_view slot) override { calls.push_back(std::format("outfit clear {} {}", plugin, slot)); }
    std::string camera_cycle(std::string_view plugin, CycleCamera place) override {
        calls.push_back(std::format("cycle {} {}", plugin, place == CycleCamera::out ? "out" : place == CycleCamera::ready ? "ready" : "active"));
        return {};
    }
    std::vector<CycleNews> cycle_news;
    std::vector<CycleNews> take_camera_cycle() override { return std::exchange(cycle_news, {}); }
    void hide_nametags(std::string_view plugin, bool hidden) override { calls.push_back(std::format("nametags {} {}", plugin, hidden ? "off" : "on")); }
    std::set<std::string, std::less<>> installed; // items found by their whole ending, as Pack/<ending>
    std::string outfit_find(std::string_view ending) override {
        if (installed.contains(ending)) return "Pack/" + std::string(ending);
        return ending == "roadrash_leg1" ? "RoadRash_Leg1" : "";
    }
    std::vector<OutfitSlot> outfit_slots() override { return {{"tattoo_legl", "", {0.5f, 1}}, {"moles", "moles_empty", {}}}; }
    std::optional<std::array<BoardBone, 16>> board_bones() override {
        std::array<BoardBone, 16> bones{};
        bones[3].position = {0, 0.1f, 0};
        return bones;
    }
    std::string board_set(std::string_view plugin, int bone, const BoardBone& value, bool world) override {
        calls.push_back(std::format("board {} {} {:.1f} {}", plugin, bone, value.position[1], world ? "world" : "local"));
        return {};
    }
    std::string board_hide(std::string_view plugin, int bone, bool everyone) override {
        calls.push_back(std::format("board hide {} {}{}", plugin, bone, everyone ? " everyone" : ""));
        return {};
    }
    void board_park(std::string_view plugin, std::vector<int> bones) override { calls.push_back(std::format("board park {} {}", plugin, bones.size())); }
    // The Example declared-input deck as the game holds it: seven live selectors, and the eight colours (and a
    // number) its mod declares for its shader. What plugins hold of it is kept by the same rules as
    // the game's (board_material.h: take, listed, release). Off: no deck declares anything.
    bool declared_rules{}; // the deck answers as the Example deck (else as before: everything is taken)
    bool declared_deck{};  // with declared_rules: the Example deck is equipped (else a deck that declares nothing)
    std::vector<board_material::detail::Hold> declared_holds;
    static constexpr std::array<std::uint64_t, 8> declared_keys{
        0x5b2d035c7746f31aULL, 0x51745c0fd2d117d3ULL, 0x5c1058b72fe158edULL, 0x5a4e08ac201c369fULL,
        0x57fc15cf6583c0c7ULL, 0x5a2f52ddbd12f283ULL, 0x55fda1e1521b9097ULL, 0x580bde15aa576f12ULL};
    static constexpr std::uint64_t declared_number = 0x7777777777777777ULL;
    board_material::detail::Found declared_board() const {
        using namespace board_material;
        detail::Found found;
        detail::Material deck{0x100, 0x200, Part::deck, {}};
        for (std::uint64_t k = 1; k <= 7; ++k)
            deck.nodes.push_back({0x300 + k, {0x5000 + k, k % 2 ? Kind::integer : Kind::toggle, {}, static_cast<std::int32_t>(k)}, 0x1234});
        found.materials.push_back(deck);
        mods::MaterialDeclaration declaration{"Example", "deck", {"Example_Deck"}, {}};
        for (const auto key : declared_keys) declaration.parameters.push_back({key, static_cast<std::uint16_t>(key), true, {.5f, .5f, .5f}});
        declaration.parameters.push_back({declared_number, 0x4242, false, {.25f, 0, 0}});
        auto never_sold = [](std::string_view) { return false; };
        found.declared = detail::declared_for({declaration}, Part::deck, declared_deck ? "Example_Deck" : "Plain_Deck", never_sold, "Example");
        return found;
    }
    bool declared_holds_deck(int part) const { return declared_rules && part == 0; }
    std::optional<std::vector<BoardParameter>> board_parameters(int part) override {
        if (declared_holds_deck(part)) {
            std::vector<BoardParameter> out;
            for (const auto& p : board_material::detail::listed(declared_board(), board_material::Part::deck)) {
                using board_material::Kind;
                out.push_back({p.key, p.kind == Kind::colour ? "colour" : p.kind == Kind::number ? "number" : p.kind == Kind::integer ? "integer" : "switch",
                               p.value, p.integer, p.inherited});
            }
            return out;
        }
        if (part != 1) return std::vector<BoardParameter>{};
        return std::vector<BoardParameter>{{0x873f48af36e50d59ULL, "colour", {.2f, .3f, .4f}, 0},
                                           {0x841c7d74837f1d39ULL, "number", {1, 0, 0}, 0},
                                           {0xb00abec403499469ULL, "integer", {}, 13},
                                           {0xa5f9a6b8098279adULL, "switch", {}, 1}};
    }
    std::string board_set_parameter(std::string_view plugin, int part, std::uint64_t key, std::array<float, 3> value, bool colour) override {
        if (declared_holds_deck(part)) {
            auto why = board_material::detail::take(declared_holds, declared_board(), plugin, board_material::Part::deck, key, value, colour);
            if (why.empty()) calls.push_back(std::format("board parameter {} {} {:016x} {} {:.1f}", plugin, part, key, colour ? "colour" : "number", value[0]));
            return why;
        }
        calls.push_back(std::format("board parameter {} {} {:016x} {} {:.1f}", plugin, part, key, colour ? "colour" : "number", value[0]));
        return {};
    }
    void board_clear_parameter(std::string_view plugin, int part, std::optional<std::uint64_t> key) override {
        calls.push_back(std::format("board parameter clear {} {} {}", plugin, part, key ? std::format("{:016x}", *key) : "all"));
        board_material::detail::release(declared_holds, plugin, part < 0 ? std::nullopt : std::optional(static_cast<board_material::Part>(part)), key);
    }
    std::size_t declared_held(std::string_view plugin) const {
        return static_cast<std::size_t>(std::count_if(declared_holds.begin(), declared_holds.end(), [&](const auto& h) { return h.owner == plugin; }));
    }
    // The general services a game layer in Lua reads and drives (plugin_api_services.cpp).
    std::optional<SkaterTelemetry> telemetry;
    unsigned telemetry_reads{};
    std::optional<SkaterTelemetry> skater_telemetry(std::string_view) override { ++telemetry_reads; return telemetry; }
    std::uint64_t world_id() override { return 77; }
    std::string world_map() override { return "test_map"; }
    std::string pad_flight(std::string_view plugin, bool on) override {
        calls.push_back(std::format("pad flight {} {}", plugin, on));
        return {};
    }
    void competition(std::string_view plugin, bool on) override { calls.push_back(std::format("competition {} {}", plugin, on)); }
    bool stock_physics_ready() override { return true; }
    void prepare_physics() override { calls.push_back("prepare physics"); }
    void trick_feed(std::string_view plugin, bool on) override { calls.push_back(std::format("trick feed {} {}", plugin, on)); }
    std::vector<std::array<float, 2>> trick_gesture(std::string_view trick) override {
        if (trick == "Kickflip") return {{0, 0}, {0.5f, 1}};
        return {};
    }
    std::string bone_cam(std::string_view plugin, const std::vector<std::string>& words) override {
        std::string line = "bone cam " + std::string(plugin);
        for (const auto& w : words) line += " " + w;
        calls.push_back(line);
        if (words.empty()) return "game";
        return words.front() == "ringing" ? "1" : "";
    }
    std::vector<ContentFile> content_files;
    std::map<std::string, std::string> content_texts;
    std::string content_list(std::string_view folder, std::vector<ContentFile>& out) override {
        calls.push_back(std::format("content list {}", folder));
        out = content_files;
        return {};
    }
    std::string content_read(std::string_view mod, std::string_view folder, std::string_view path, std::string& text) override {
        const auto found = content_texts.find(std::format("{}/{}/{}", mod, folder, path));
        if (found == content_texts.end()) return "not found";
        text = found->second;
        return {};
    }
    std::string trick_label(std::string_view plugin, std::string_view from, std::string_view to) override {
        calls.push_back(std::format("trick label {} {}={}", plugin, from, to));
        return {};
    }
    std::string trick_record_as(std::string_view plugin, std::vector<std::uint32_t> from, std::uint32_t to, int within_ms) override {
        std::string ids;
        for (const auto id : from) ids += (ids.empty() ? "" : ",") + std::to_string(id);
        calls.push_back(std::format("trick record {} {}->{} {}", plugin, ids, to, within_ms));
        return {};
    }
    std::string board_toss(std::string_view plugin, std::vector<int> bones, const Vec3& velocity, const Vec3&, float ground) override {
        calls.push_back(std::format("board toss {} {} {:.0f} {:.0f}", plugin, bones.size(), velocity[1], ground));
        return {};
    }
    SkaterNews news;
    SkaterNews take_skater_news() override { return std::exchange(news, {}); }
    std::vector<PhysicsStep> steps;
    std::vector<PhysicsStep> take_physics_steps() override { return std::exchange(steps, {}); }
    std::string xray(std::string_view plugin, bool on) override {
        calls.push_back(std::format("xray {} {}", plugin, on ? "on" : "off"));
        return {};
    }
    std::string hide_skater(std::string_view plugin, bool hidden) override {
        calls.push_back(std::format("hide skater {} {}", plugin, hidden ? "on" : "off"));
        return {};
    }
    std::string hud_corner(std::string_view plugin, bool hidden) override {
        calls.push_back(std::format("corner {} {}", plugin, hidden ? "on" : "off"));
        return {};
    }
    std::string game_speed(std::string_view plugin, float speed) override {
        calls.push_back(std::format("slow {} {:.2f}", plugin, speed));
        return {};
    }
    std::string shape_launch(std::string_view plugin, std::string_view from, std::optional<LaunchShape> shape) override {
        calls.push_back(std::format("launch {} {} {}", plugin, from, shape && shape->across ? std::format("{:.2f}", *shape->across) : "none"));
        return {};
    }
    std::vector<LaunchNews> launches;
    std::vector<LaunchNews> take_launches() override { return std::exchange(launches, {}); }
    std::string hide_pad(std::string_view plugin, const PadHidden& h) override {
        calls.push_back(std::format("hide {} {} {} {}", plugin, h.left_trigger, h.right_trigger, h.left_x_grinding) +
                        (h.right_stick || h.left_stick_click || h.right_stick_click
                             ? std::format(" stick {} {} {}", h.right_stick, h.left_stick_click, h.right_stick_click) : std::string{}));
        return {};
    }
    std::string cruise(std::string_view plugin, float speed, bool may_slow) override {
        calls.push_back(std::format("cruise {} {:.1f} {}", plugin, speed, may_slow));
        return {};
    }
    std::optional<MouseMotion> mouse_motion(std::string_view) override { return MouseMotion{3, -2, 1}; }
    static const char* shown_name(Shown shown) { return shown == Shown::others ? "others" : shown == Shown::me ? "me" : "everyone"; }
    std::string skater_carry(std::string_view plugin, std::optional<Carry> c) override {
        calls.push_back(c ? std::format("carry {} {}{} {:.1f} {:.1f} {:.1f} front {:.2f} grip {} w {:.2f} crouch {:.2f} hunch {:.2f} turn {:.2f} step {:.2f}{}{} {}",
                                        plugin, c->left ? "left" : "right", c->both ? " both" : "", c->front[0], c->front[1], c->front[2],
                                        c->front_from_grip[2], c->worn.has_value(), c->weight, c->crouch, c->hunch, c->turn, c->step,
                                        c->still ? " still" : "", c->push_straightens ? " push" : "", shown_name(c->shown))
                          : std::format("carry {} none", plugin));
        return {};
    }
    std::string skater_pose(std::string_view plugin, const std::vector<JointOffset>& offsets, float weight, Shown shown) override {
        std::string text = std::format("pose {} {:.2f}", plugin, weight);
        if (shown != Shown::everyone) text += std::format(" {}", shown_name(shown));
        auto sorted = offsets;
        std::sort(sorted.begin(), sorted.end(), [](const auto& a, const auto& b) { return a.joint < b.joint; });
        for (const auto& o : sorted) {
            text += std::format(" {}:{:.2f},{:.2f},{:.2f},{:.2f}x{:.2f}", o.joint, o.rotation[0], o.rotation[1], o.rotation[2], o.rotation[3], o.scale);
            if (o.place) {
                const auto& pl = *o.place;
                text += pl.frame == dingosdk::pose_place::Frame::joint ? std::format(" place@{}", pl.joint)
                        : pl.frame == dingosdk::pose_place::Frame::skater ? std::string(" place@skater")
                        : pl.frame == dingosdk::pose_place::Frame::world  ? std::string(" place@world")
                                                                : std::string(" place@parent");
                if (pl.position) text += std::format(" p{:.2f},{:.2f},{:.2f}", (*pl.position)[0], (*pl.position)[1], (*pl.position)[2]);
                if (pl.rotation) text += std::format(" r{:.2f},{:.2f},{:.2f},{:.2f}", (*pl.rotation)[0], (*pl.rotation)[1], (*pl.rotation)[2], (*pl.rotation)[3]);
            }
            if (o.keep_children) text += " keep";
        }
        calls.push_back(text);
        // The order the joints are posed in, when any is set to a place or keeps its children.
        if (std::any_of(offsets.begin(), offsets.end(), [](const auto& o) { return o.place || o.keep_children; })) {
            std::string order = std::format("pose order {}", plugin);
            for (const auto& o : offsets) order += std::format(" {}", o.joint);
            calls.push_back(order);
        }
        return {};
    }
    std::string typed = "";
    std::string typed_text(bool capture) override { return capture ? std::exchange(typed, {}) : std::string{}; }
    std::string room_phase = "idle";
    std::string room_open(std::string_view plugin) override {
        calls.push_back("room open " + std::string(plugin));
        room_phase = "open";
        return {};
    }
    void room_leave(std::string_view plugin) override {
        calls.push_back("room leave " + std::string(plugin));
        room_phase = "idle";
    }
    RoomState room_state(std::string_view) override { return {room_phase, {}}; }
    std::string set_setting(std::string_view plugin, std::string_view name, std::optional<std::string> value) override {
        calls.push_back(std::format("setting {} {} {}", plugin, name, value ? *value : std::string("none")));
        return {};
    }
    std::string set_velocity(std::string_view plugin, const Vec3& v, bool add) override {
        calls.push_back(std::format("velocity {} {:.1f} {:.1f} {:.1f}{}", plugin, v[0], v[1], v[2], add ? " add" : ""));
        return {};
    }
    std::string skater_reach(std::string_view plugin, std::optional<Reach> r) override {
        calls.push_back(r ? std::format("reach {} {} {:.1f} {:.1f} {:.1f} {} {:.2f}", plugin, r->left ? "left" : "right", r->at[0], r->at[1], r->at[2],
                                        r->rotation.has_value(), r->weight) +
                                (r->shown != Shown::everyone ? std::format(" {}", shown_name(r->shown)) : std::string{})
                          : std::format("reach {} none", plugin));
        return {};
    }
    std::optional<HandPlace> skater_hand(bool left) override {
        if (left) return std::nullopt;
        return HandPlace{{1, 2, 3}, {0, 0, 0, 1}};
    }
    std::string screen_look(std::string_view plugin, std::optional<ScreenLook> l) override {
        calls.push_back(l ? std::format("look {} {:.2f} {:.0f} {:.2f} {}{}{}{}{}{}{}{}{}{}{} {:.1f} [{}|{}|{}|{}|{}]", plugin, l->bend, l->fov, l->age, l->bars, l->hood,
                                        l->grade, l->soft, l->scanlines, l->grain, l->dropouts, l->head_switching, l->tracking, l->smear, l->iris, l->rolling,
                                        l->text[0], l->text[1], l->text[2], l->text[3], l->text[4])
                          : std::format("look {} none", plugin));
        return {};
    }
    std::map<std::string, Tuning> tunings{{"physicsmode.jumpmaxheight", {"PhysicsMode.JumpMaxHeight", "Jump height", "Jumps", "number", 1.2, 1.2, ""}},
                                          {"physicsmode.autopushenabled", {"PhysicsMode.AutoPushEnabled", "Auto push", "Push", "flag", 0, 0, ""}}};
    std::optional<Tuning> tuning(std::string_view id, std::string& why) override {
        std::string key(id);
        for (auto& c : key) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        const auto at = tunings.find(key);
        if (at == tunings.end()) {
            why = "no tuning value is called \"" + std::string(id) + "\"";
            return std::nullopt;
        }
        return at->second;
    }
    std::vector<Tuning> find_tuning(std::string_view text, std::size_t most) override {
        std::vector<Tuning> out;
        for (const auto& [key, t] : tunings)
            if (key.find(text) != std::string::npos && out.size() < most) out.push_back(t);
        return out;
    }
    std::string tune(std::string_view plugin, std::string_view id, std::optional<double> value) override {
        calls.push_back(value ? std::format("tune {} {} {:.2f}", plugin, id, *value) : std::format("tune {} {} none", plugin, id));
        return {};
    }
    std::optional<JointPlace> skater_joint(std::uint64_t player, std::uint16_t joint) override {
        if (player == 7 || joint == 300) return std::nullopt;
        return JointPlace{{static_cast<float>(player), static_cast<float>(joint), 0}, {0, 0, 0, 1}, 1};
    }
    std::string screen_slap(std::string_view plugin) override {
        calls.push_back(std::format("slap {}", plugin));
        return {};
    }
    std::optional<Vec3> board_velocity() override { return Vec3{1, -2, 3}; }
    std::optional<Vec3> board_spin() override { return Vec3{0, 4, 0}; }
    std::optional<SlamNews> last_slam() override { return SlamNews{7.5f, 12, 100}; }
    std::string wipeout(float force) override {
        calls.push_back(std::format("wipeout {:.1f}", force));
        return {};
    }
    std::string control(std::string_view action) override { calls.push_back("control " + std::string(action)); return {}; }
    void hide_hud(std::string_view plugin, bool hidden) override { calls.push_back(std::string("hud ") + std::string(plugin) + (hidden ? " on" : " off")); }
    std::vector<CatalogItem> object_catalog() override { return {{"bench_01", "Bench", "Benches"}}; }
    std::vector<GameObject> objects() override { return {{42, "bench_01", {1, 0, 2}, {0, 0, 0, 1}, 1}}; }
    std::string edit_object(std::string_view op, const GameObject& o) override {
        calls.push_back(std::format("{} {} {} {:.1f}", op, o.id, o.item, o.position[0]));
        return {};
    }
    // World objects as the fake keeps them: by plugin and id, ready at once unless hidden.
    std::map<std::pair<std::string, std::uint32_t>, std::pair<std::string, std::array<float, 16>>> entities;
    std::map<std::string, std::array<Vec3,2>> test_entity_boxes;
    std::uint32_t test_entity_fail_id{};
    bool test_forbid_blueprint_enumeration{};
    unsigned test_blueprint_enumerations{}, test_bounds_lookups{};
    std::vector<std::string> test_bounds_names;
    std::string entity_set(std::string_view plugin, std::uint32_t id, std::string_view asset, const std::array<float, 16>& m, bool hidden,
                           std::optional<EntityAttach> attach, bool solid) override {
        if (id == test_entity_fail_id) return "constructed part failure";
        if (entities.size() >= 600) return "too many";
        entities[{std::string(plugin), id}] = {std::string(asset) + (hidden ? " hidden" : ""), m};
        calls.push_back(std::format("entity {} {} {} {:.2f} {:.2f} {:.2f} {:.2f}{}{}", plugin, id, asset, m[12], m[13], m[14], m[8], hidden ? " hidden" : "",
                                    attach ? std::format(" on {} {}{}{}{}", attach->player, attach->joint, attach->upright ? " upright" : "", attach->turn ? "" : " held",
                                                     attach->ground > 0 ? std::format(" ground {:.1f}", attach->ground) : std::string{}) : std::string{}) +
                        (solid ? "" : " ghost"));
        return {};
    }
    unsigned entity_remove_calls{};
    void entity_remove(std::string_view plugin, std::uint32_t id) override { ++entity_remove_calls; entities.erase({std::string(plugin), id}); }
    std::optional<std::array<Vec3, 2>> entity_bounds(std::string_view blueprint) override {
        ++test_bounds_lookups; test_bounds_names.emplace_back(blueprint);
        if (const auto found = test_entity_boxes.find(std::string(blueprint)); found != test_entity_boxes.end()) return found->second;
        if (blueprint != "World/Props/TrashCan_01") return std::nullopt;
        return std::array<Vec3, 2>{Vec3{-0.3f, 0, -0.3f}, Vec3{0.3f, 0.9f, 0.3f}};
    }
    std::vector<std::string> entity_blueprints(std::string_view prefix, bool meshes_only) override {
        ++test_blueprint_enumerations;
        if (test_forbid_blueprint_enumeration) return {};
        std::vector<std::string> out;
        for (const auto* name : {"World/Props/Bench_01", "World/Props/TrashCan_01", "World/Vehicles/Car_01"})
            if (std::string_view(name).starts_with(prefix) && (!meshes_only || entity_bounds(name))) out.emplace_back(name);
        for (const auto& [name, box] : test_entity_boxes) {
            (void)box; if (std::string_view(name).starts_with(prefix)) out.push_back(name);
        }
        return out;
    }
    WorldProbe probe_result;
    // Opt-in responses for actual-package placement tests; other fixtures retain
    // their fixed result and the existing bounded-query accounting.
    std::function<WorldProbe(const Vec3&, const Vec3&)> probe_reply;
    unsigned probes{}, world_picks{};
    Vec3 probe_from{}, probe_to{};
    WorldProbe world_probe(const Vec3& from, const Vec3& to) override {
        ++probes;
        probe_from = from;
        probe_to = to;
        return probe_reply ? probe_reply(from, to) : probe_result;
    }
    CountedProbe world_probe_bounded(const Vec3& from, const Vec3& to, unsigned allowed) override {
        if (!allowed) return {};
        const auto cast_count = std::min(allowed, query_cast_cost); native_casts += cast_count;
        const auto probe = world_probe(from, to);
        return {cast_count && cast_count == query_cast_cost ? probe : WorldProbe{}, cast_count};
    }
    std::optional<WorldPick> world_pick(const Vec3& from, const Vec3&) override {
        ++world_picks;
        if (from[1] > 50) return std::nullopt; // the sky: nothing met
        WorldPick pick{{1, 0, 2}, true, std::array<float, 16>{0, 0, -1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 1, 0, 3, 1}, "World/Props/TrashCan_01"};
        return pick;
    }
    CountedPick world_pick_bounded(const Vec3& from, const Vec3& to, unsigned allowed) override {
        if (!allowed) return {};
        const auto cast_count = std::min(allowed, query_cast_cost); native_casts += cast_count;
        const auto pick = world_pick(from, to);
        return {cast_count && cast_count == query_cast_cost ? pick : std::nullopt, cast_count};
    }
    void entity_clear(std::string_view plugin) override {
        std::erase_if(entities, [&](const auto& e) { return e.first.first == plugin; });
        calls.push_back("entities clear " + std::string(plugin));
    }
    int entity_status(std::string_view plugin, std::uint32_t id) override {
        const auto found = entities.find({std::string(plugin), id});
        return found == entities.end() ? 0 : found->second.first.ends_with(" hidden") ? 5 : 4;
    }
    bool entities_ready(std::string_view) override { return true; }
    std::string set_environment(std::string_view kind, std::string_view key, std::string_view value) override {
        calls.push_back(std::format("env {} {} {}", kind, key, value));
        return key == "never" ? "refused" : "";
    }
    std::vector<Destination> destinations() override { return {{"bam", "BAM", "bam"}}; }
    std::vector<LevelInfo> levels() override { return {{"Levels/Game/X/X", "X", true}}; }
    std::string travel(std::string_view kind, std::string_view target) override { calls.push_back(std::format("travel {} {}", kind, target)); return {}; }
    std::string ai(std::string_view op, int count) override { calls.push_back(std::format("ai {} {}", op, count)); return {}; }
    int ai_count() override { return 3; }
    std::vector<PeerSkater> peer_skaters() override { return {{7, {1, 2, 3}, 0.5f, 40}}; }
    std::vector<Body> body_list; // what bodies() reads
    std::set<std::pair<std::string, std::uint64_t>> hidden_list;
    std::vector<Body> bodies() override { return body_list; }
    std::string hide_player(std::string_view plugin, std::uint64_t player, bool hidden) override {
        calls.push_back(std::format("hide {} {} {}", plugin, player, hidden ? "on" : "off"));
        if (hidden) hidden_list.insert({std::string(plugin), player});
        else hidden_list.erase({std::string(plugin), player});
        return {};
    }
    std::vector<std::uint64_t> hidden_players(std::string_view plugin) override {
        std::vector<std::uint64_t> out;
        for (const auto& [owner, who] : hidden_list)
            if (owner == plugin) out.push_back(who);
        return out;
    }
    void set_nametag(std::string_view plugin, std::uint64_t player, std::string text, std::uint32_t colour) override {
        calls.push_back(std::format("tag {} {} {} {:08x}", plugin, player, text, colour));
    }
    std::string voice_volume(std::uint64_t player, float volume) override { calls.push_back(std::format("voice {} {:.1f}", player, volume)); return {}; }
    std::vector<ChatLine> chat_since(std::uint64_t sequence) override {
        std::vector<ChatLine> result;
        for (const auto& line : lines) if (line.sequence > sequence) result.push_back(line);
        return result;
    }
    std::string send_chat(std::string_view text) override { calls.push_back("chat " + std::string(text)); return {}; }
    std::string local_chat(std::string_view plugin, std::string_view text, std::uint32_t colour) override {
        calls.push_back(std::format("notice {} {} {:08x}", plugin, text, colour));
        return {};
    }
    ThrowdownState throwdowns() override { return throwdown; }
    ClipRef recorded;
    std::vector<std::string> game_clip_names(std::string_view containing, std::size_t most, std::string& why) override {
        if (!game_clips_ready) {
            why = "the game's animations are still being read";
            return {};
        }
        std::vector<std::string> out;
        for (const char* name : {"animation/dingo/c_proto_onb_trick_o_kickflip_high", "animation/dingo/c_proto_onb_trick_o_ollie_mid",
                                 "animation/dingo/seq_c_proto_onb_trick_o_kickflip_low"})
            if (std::string_view(name).find(containing) != std::string_view::npos && out.size() < most) out.push_back(name);
        return out;
    }
    // A game clip: three frames of the whole skeleton, 0.1 s apart, its takeoff and landing marked.
    ClipRef game_clip(std::string_view name, std::string& why) override {
        if (!game_clips_ready) {
            why = "the game's animations are still being read";
            return nullptr;
        }
        if (name.starts_with("animation/dingo/seq_")) {
            why = std::string(name) + " is a SequenceContainerAsset, not a clip";
            return nullptr;
        }
        calls.push_back("game clip " + std::string(name));
        auto clip = std::make_shared<dingosdk::anim_studio::Clip>();
        clip->joints = dingosdk::anim_studio::skeleton_joints;
        clip->times = {0, 0.1f, 0.2f};
        clip->frames.resize(3 * clip->joints);
        clip->board.resize(3);
        clip->takeoff = 0.05f;
        clip->landing = 0.15f;
        return clip;
    }
    bool game_clips_ready{};
    // The fake's clips stand regular, and a mirror is the clip with its takeoff moved, to tell it apart.
    std::optional<bool> clip_goofy(const ClipRef& clip) override {
        if (!game_clips_ready || !clip) return std::nullopt;
        return clip->takeoff > 0.07f;
    }
    ClipRef mirror_clip(const ClipRef& clip, std::string& why) override {
        if (!game_clips_ready) {
            why = "the game's animations are still being read";
            return nullptr;
        }
        auto out = std::make_shared<dingosdk::anim_studio::Clip>(*clip);
        out->takeoff += 0.05f;
        calls.push_back("mirror");
        return out;
    }
    std::string play_clip(std::string_view plugin, ClipRef clip, float speed, float blend, bool loop, float at, bool paused, bool floor) override {
        calls.push_back(std::format("play {} {} frames {:.1f} {:.2f} {}", plugin, clip->times.size(), speed, blend, loop) +
                        (at > 0 || paused ? std::format(" at {:.2f}{}", at, paused ? " paused" : "") : std::string{}) + (floor ? " floor" : ""));
        return {};
    }
    void seek_clip(std::string_view plugin, float seconds) override { calls.push_back(std::format("seek {} {:.2f}", plugin, seconds)); }
    void pause_clip(std::string_view plugin, bool paused) override { calls.push_back(std::format("pause {} {}", plugin, paused)); }
    std::optional<float> clip_time(std::string_view) override { return 0.25f; }
    void stop_clip(std::string_view plugin) override { calls.push_back("stop " + std::string(plugin)); }
    std::string replace_trick(std::string_view plugin, std::string trick, std::string pop, ClipRef clip, float) override {
        calls.push_back(std::format("replace {} {} {} {}", plugin, trick, pop.empty() ? "any" : pop, clip ? "clip" : "none"));
        return {};
    }
    std::string record_clip(std::string_view plugin, float seconds) override {
        calls.push_back(std::format("record {} {:.1f}", plugin, seconds));
        auto clip = std::make_shared<dingosdk::anim_studio::Clip>();
        clip->joints = dingosdk::anim_studio::skeleton_joints;
        clip->times = {0, 0.25f, 0.5f};
        clip->frames.resize(clip->times.size() * clip->joints);
        clip->takeoff = 0.1f;
        clip->landing = 0.4f;
        recorded = std::move(clip);
        return {};
    }
    ClipRef take_recording(std::string_view) override { return std::exchange(recorded, nullptr); }
    std::string current_trick() override { return "kickflip"; }
    std::optional<FlightInput> flight_input(std::string_view) override { return FlightInput{1, 0, 0.5f, 3, 4, true}; }
    std::optional<PadInput> pad = PadInput{0.25f, 0, 0, 0, 0, 1, 0x1000, false};
    std::optional<PadInput> gamepad() override { return pad; }
    std::optional<StickInput> joystick() override {
        StickInput stick;
        stick.axes = {0, -1, 0.5f, 0, 0, 0};
        stick.buttons = 0x4;
        stick.name = "Radio";
        return stick;
    }
    std::string capture_input(std::string_view plugin, bool on) override {
        calls.push_back(std::format("capture {} {}", plugin, on ? "on" : "off"));
        return {};
    }
    std::uint64_t sound_ids{};
    std::uint64_t play_sound(std::string_view plugin, SoundStart sound) override {
        calls.push_back(std::format("sound {} {} {:.2f} {:.2f} {}{}", plugin, sound.wave ? std::to_string(sound.wave->samples.size()) : "motor", sound.volume,
                                    sound.pitch, sound.loop, sound.position ? std::format(" at {} {} {}", (*sound.position)[0], (*sound.position)[1], (*sound.position)[2]) : ""));
        return ++sound_ids;
    }
    bool change_sound(std::string_view plugin, std::uint64_t id, const SoundChange& change) override {
        calls.push_back(std::format("change {} {} {:.1f}{}", plugin, id, change.throttle.value_or(-1),
                                    change.position && !*change.position ? " skater" : ""));
        return true;
    }
    void stop_sound(std::string_view plugin, std::uint64_t id) override { calls.push_back(std::format("stop sound {} {}", plugin, id)); }
    bool sound_playing(std::string_view, std::uint64_t id) override { return id <= sound_ids; }
    std::string host_throwdown(std::string_view plugin, std::string_view series, std::vector<std::uint64_t> players, int most) override {
        calls.push_back(std::format("host {} {} {} players max {}", plugin, series, players.size(), most));
        return {};
    }
    std::string throwdown_status(std::string_view) override { return "open"; }
    std::vector<ThrowdownMode> modes;
    std::string set_throwdown_mode(std::string_view plugin, const ThrowdownMode& mode) override {
        calls.push_back(std::format("mode {} {} {}", plugin, mode.id, mode.name));
        std::erase_if(modes, [&](const auto& m) { return m.id == mode.id; });
        modes.push_back(mode);
        return {};
    }
    void remove_throwdown_mode(std::string_view plugin, std::string_view id) override { calls.push_back(std::format("remove mode {} {}", plugin, id)); }
    // The throwdown kit: documents go to the real store (so the tests read them parsed); the flag is
    // the fake's own (kit::flag is the game's).
    int kit_documents{};
    std::string publish_throwdown_ui(std::string_view plugin, const dingosdk::Json& document) override {
        ++kit_documents;
        return dingosdk::throwdowns::kit::publish(plugin, document);
    }
    dingosdk::throwdowns::kit::flag::State flag;
    bool throwdown_flag_begin(std::string_view mode, std::uint32_t game, const dingosdk::throwdowns::kit::flag::Options& o) override {
        calls.push_back(std::format("flag begin {} {} {} {} {} {:.1f}", mode, game, o.players, o.seconds, o.setup_page, o.cursor_height));
        if (flag.busy) return false;
        flag = {true, false, true, true, std::string(mode), game};
        return true;
    }
    dingosdk::throwdowns::kit::flag::State throwdown_flag_state() override { return flag; }
    void throwdown_flag_leave(std::string_view plugin) override {
        calls.push_back(std::format("flag leave {}", plugin));
        if (flag.mode.starts_with(std::string(plugin) + "/")) flag = {};
    }
    // A plugin's data folder, as a map by "<plugin>/<path>".
    std::map<std::string, std::string> files;
    std::string files_list(std::string_view plugin, std::string_view folder, std::vector<std::string>& names) override {
        const auto prefix = std::string(plugin) + "/" + (folder.empty() ? "" : std::string(folder) + "/");
        for (const auto& [path, text] : files) {
            if (!path.starts_with(prefix)) continue;
            auto rest = path.substr(prefix.size());
            if (const auto slash = rest.find('/'); slash != std::string::npos) rest = rest.substr(0, slash + 1);
            if (std::find(names.begin(), names.end(), rest) == names.end()) names.push_back(rest);
        }
        return {};
    }
    std::string files_read(std::string_view plugin, std::string_view path, std::string& text) override {
        const auto found = files.find(std::string(plugin) + "/" + std::string(path));
        if (found == files.end()) return "not found";
        text = found->second;
        return {};
    }
    std::string files_write(std::string_view plugin, std::string_view path, std::string_view text) override {
        files[std::string(plugin) + "/" + std::string(path)] = std::string(text);
        return {};
    }
    std::string files_remove(std::string_view plugin, std::string_view path) override {
        return files.erase(std::string(plugin) + "/" + std::string(path)) ? std::string{} : std::string("not found");
    }
    std::optional<DialogSpec> dialog;
    std::string dialog_open(std::string_view plugin, const DialogSpec& spec) override {
        calls.push_back(std::format("dialog {} {} rows {} buttons {}", plugin, spec.id, spec.rows.size(), spec.buttons.size()));
        dialog = spec;
        return {};
    }
    // SmokeyDawg58's editor reads the pad and the window's focus.
    std::optional<std::uint32_t> pad_bits_now;
    unsigned focus_reads{};
    InputFocus focus_now{};
    bool input_allowed_now{};
    bool input_allowed() override { return input_allowed_now; }
    std::optional<std::uint32_t> pad_bits(bool) override { return pad_bits_now; }
    InputFocus input_focus() override { ++focus_reads; return focus_now; }
    std::optional<Cursor> cursor_now;
    std::optional<Cursor> cursor() override { return cursor_now; }
    void dialog_close(std::string_view plugin, std::string_view id) override { calls.push_back(std::format("dialog close {} {}", plugin, id)); }
    std::string skater_push(std::string_view plugin, const Vec3& v) override {
        calls.push_back(std::format("push {} {:.0f} {:.0f} {:.0f}", plugin, v[0], v[1], v[2]));
        return {};
    }
    std::string skater_push_wait(std::string_view plugin) override {
        calls.push_back(std::format("push wait {}", plugin));
        return {};
    }
    std::string skater_push_reset(std::string_view plugin) override {
        calls.push_back(std::format("push reset {}", plugin));
        return {};
    }
    std::string skater_hold(std::string_view plugin, bool on) override {
        calls.push_back(std::format("hold {} {}", plugin, on));
        return {};
    }
    std::string kick(std::uint64_t player, std::string_view why) override { calls.push_back(std::format("kick {} {}", player, why)); return {}; }
    std::string announce(std::string_view plugin, std::string_view text) override {
        calls.push_back(std::format("announce {} {}", plugin, text));
        return {};
    }
    std::optional<Role> role(std::uint64_t player) override {
        if (player == 1) return Role{"moderator", 50, true};
        return std::nullopt;
    }
    std::vector<ServerPark> server_parks() override { return {{"street", "San Vansterdam", true, true, 12, 5}, {"plaza", "Isle of Grom", false, false, 0, 0}}; }
    std::string spawn_park(std::string_view plugin, std::string_view name, unsigned minutes) override {
        calls.push_back(std::format("park spawn {} {} {}", plugin, name, minutes));
        return name == "plaza" ? "plaza belongs on Isle of Grom, and the server is on San Vansterdam." : std::string{};
    }
    std::string remove_park(std::string_view plugin, std::string_view name) override {
        calls.push_back(std::format("park remove {} {}", plugin, name));
        return {};
    }
    std::string server_hide(std::string_view plugin, std::uint64_t target, const std::vector<std::uint64_t>& viewers, const Hiding& what) override {
        calls.push_back(std::format("hide {} {} from {} skater {} voice {} sound {}", plugin, target, players_text(viewers), what.skater, what.voice,
                                    what.sound));
        return target == 9 ? "that player is not on the server" : std::string{};
    }
    std::string server_unhide(std::string_view plugin, std::uint64_t target, const std::vector<std::uint64_t>& viewers) override {
        calls.push_back(std::format("unhide {} {} from {}", plugin, target, players_text(viewers)));
        return {};
    }
    static std::string players_text(const std::vector<std::uint64_t>& players) {
        std::string text;
        for (const auto id : players) text += (text.empty() ? "" : ",") + std::to_string(id);
        return text.empty() ? "all" : text;
    }
    std::string server_card(std::string_view plugin, const std::vector<std::uint64_t>& players, std::string_view text, unsigned seconds) override {
        calls.push_back(std::format("card {} {} {} {}", plugin, players_text(players), text, seconds));
        return {};
    }
    std::uint32_t next_poll = 41;
    std::string server_poll(std::string_view plugin, const std::vector<std::uint64_t>& players, std::string_view question,
                            const std::vector<std::string>& answers, unsigned seconds, std::uint32_t& id) override {
        std::string listed;
        for (const auto& answer : answers) listed += (listed.empty() ? "" : "|") + answer;
        calls.push_back(std::format("poll {} {} {} {} {}", plugin, players_text(players), question, listed, seconds));
        if (players == std::vector<std::uint64_t>{9}) return "that player is not on the server";
        id = next_poll++;
        return {};
    }
    std::string server_poll_close(std::string_view plugin, std::uint32_t id) override {
        calls.push_back(std::format("poll close {} {}", plugin, id));
        return {};
    }
    std::vector<PollNews> poll_news;
    std::vector<PollNews> take_poll_news() override { return std::exchange(poll_news, {}); }
    std::optional<CameraView> camera_view() override { return CameraView{{1, 2, 3}, {0, 0, 1}, 60}; }
    std::string set_camera(std::string_view plugin, const std::array<float, 16>& pose, float fov) override {
        if (!camera_refusal.empty()) return camera_refusal;
        calls.push_back(std::format("camera {} {:.1f} {:.1f} {:.1f} back {:.2f} {:.2f} {:.2f} fov {:.0f}", plugin, pose[12], pose[13], pose[14],
                                    pose[8], pose[9], pose[10], fov));
        return {};
    }
    void release_camera(std::string_view plugin) override { calls.push_back("camera release " + std::string(plugin)); }
    std::string camera_status(std::string_view) override { return camera_hold_error; }
    std::string freeze(std::string_view plugin, bool on) override {
        calls.push_back(std::format("freeze {} {}", plugin, on ? "on" : "off"));
        return {};
    }
    Track track() override { return now_playing; }
    std::string music(std::string_view command) override { calls.push_back("music " + std::string(command)); return {}; }
    Progress progress() override { return {true, {{"historic", "Historic", 4}}, {{"c1", "line", "historic", 2, 1, 3}}, 1500, 9000, 2}; }
    std::optional<std::string> setting(std::string_view name) override {
        if (std::find(render_settings.begin(), render_settings.end(), name) != render_settings.end()) return "true";
        return name == "Render.Fov" ? std::optional<std::string>("90") : std::nullopt;
    }
    std::vector<std::string> setting_names() override {
        auto names = render_settings;
        names.insert(names.begin(), "Render.Fov");
        return names;
    }
    std::string bind(std::string_view plugin, std::string_view action, std::uint32_t combo) override {
        binds[std::string(plugin) + "/" + std::string(action)] = combo;
        return {};
    }
    std::vector<std::pair<std::string, std::string>> take_presses() override { return std::exchange(presses, {}); }
    void release(std::string_view plugin) override {
        released.emplace_back(plugin);
        entity_clear(plugin);
        effects_clear(plugin);
        board_material::detail::release(declared_holds, plugin, std::nullopt, std::nullopt);
    }
    // The game menu, its item grid, what is worn, and a screen capture of something turning once
    // every `turning` frames (reskate.capture, room.turn, menu.game/grid, outfit.board).
    GameMenu menu_now;
    unsigned menu_reads{};
    std::optional<MenuGrid> grid_now;
    std::vector<WornItem> board_now, outfit_now;
    std::vector<std::string> render_settings; // more settings, each on
    CaptureStatus capture_now{"idle"};
    double turning = 100;
    std::vector<CaptureStart> capture_starts;
    std::vector<CaptureSave> capture_saves;
    float turned{};
    std::string room_turn(std::string_view, float value, int stick) override {
        if (value != 0 && !menu_now.open) return "the game's menu is not open";
        turned = value;
        calls.push_back(std::format("turn {:.2f} {}", value, stick));
        return {};
    }
    GameMenu game_menu() override { ++menu_reads; return menu_now; }
    std::optional<MenuGrid> menu_grid() override { return grid_now; }
    std::vector<WornItem> board_parts() override { return board_now; }
    std::vector<WornItem> outfit_worn() override { return outfit_now; }
    std::string capture_start(std::string_view plugin, const CaptureStart& request) override {
        capture_starts.push_back(request);
        capture_now = {"recording"};
        calls.push_back(std::format("capture start {}", plugin));
        return {};
    }
    void capture_stop(std::string_view) override {
        if (capture_now.state == "recording") capture_now.state = "stopped";
    }
    void capture_discard(std::string_view plugin) override {
        capture_now = {"idle"};
        calls.push_back(std::format("capture discard {}", plugin));
    }
    CaptureStatus capture_status(std::string_view) override { return capture_now; }
    float capture_compare(std::string_view, std::uint32_t a, std::uint32_t b) override {
        if (a >= capture_now.taken || b >= capture_now.taken) return -1;
        return 100 * static_cast<float>(std::abs(std::sin(3.14159265358979 * (double(a) - double(b)) / turning)));
    }
    std::vector<std::uint32_t> capture_kept(std::string_view) override {
        std::vector<std::uint32_t> out;
        for (std::uint32_t n = 0; n < capture_now.taken; ++n) out.push_back(n);
        return out;
    }
    std::string capture_save(std::string_view, const CaptureSave& request) override {
        capture_saves.push_back(request);
        capture_now = {"saving", capture_now.taken, capture_now.taken};
        return {};
    }
    std::string files_reveal(std::string_view plugin, std::string_view folder) override {
        calls.push_back(std::format("reveal {} {}", plugin, folder));
        return {};
    }
    // Keys held, the keys and pad buttons kept from the game, the items worn on top and what the item
    // grid was asked to show and mark (Item Tabs).
    std::set<int> keys_held;
    bool key_down(int virtual_key) override { return keys_held.contains(virtual_key); }
    std::vector<std::uint8_t> kept_keys;
    std::uint16_t kept_buttons{};
    unsigned game_filter_calls{};
    void game_keys(std::string_view, std::vector<std::uint8_t> keys) override { ++game_filter_calls; kept_keys = std::move(keys); }
    void game_buttons(std::string_view, std::uint16_t hidden, std::uint16_t, bool) override { ++game_filter_calls; kept_buttons = hidden; }
    std::vector<std::string> on_top_now;
    static std::string joined(const std::vector<std::string>& list) {
        std::string out;
        for (const auto& one : list) out += (out.empty() ? "" : ",") + one;
        return out;
    }
    std::string outfit_on_top(std::string_view plugin, std::vector<std::string> items) override {
        calls.push_back(std::format("on top {} [{}]", plugin, joined(items)));
        on_top_now = std::move(items);
        return {};
    }
    OnTop outfit_on_top_state(std::string_view) override { return {on_top_now, on_top_now, {}}; }
    std::optional<std::vector<std::string>> grid_shown;
    std::vector<std::string> grid_marked;
    std::string grid_show(std::string_view plugin, std::optional<std::vector<std::string>> keys) override {
        calls.push_back(keys ? std::format("show {} [{}]", plugin, joined(*keys)) : std::format("show {} none", plugin));
        grid_shown = std::move(keys);
        return {};
    }
    void grid_mark(std::string_view, std::vector<std::string> keys) override { grid_marked = std::move(keys); }
    bool called(std::string_view part) const {
        return std::any_of(calls.begin(), calls.end(), [&](const auto& c) { return c.find(part) != std::string::npos; });
    }
};

struct TestEnvironment final : Environment {
    std::vector<std::string> logs, lines;
    double now = 1000;
    void log(LogLevel, std::string_view text) override { logs.emplace_back(text); }
    void console(std::string_view text) override { lines.emplace_back(text); }
    double now_ms() override { return now; }
    std::filesystem::path storage_root() override { return scratch / "storage"; }
    bool builtin_command(std::string_view word) override { return word == "perf" || word == "load"; }
    // A skater, when there is one, on flat ground at y = 0.
    std::optional<SkaterState> local_skater;
    bool teleport_forbidden{}, teleport_unavailable{};
    std::vector<std::pair<Vec3, float>> teleports;
    int rays{};
    unsigned ray_cast_cost{1}, native_ray_casts{};
    unsigned skater_reads{};
    std::optional<SkaterState> skater() override { ++skater_reads; return local_skater; }
    std::optional<ScoreState> score_now;
    std::optional<ScoreState> score() override { return score_now; }
    std::vector<std::string> toasts, sounds;
    std::vector<ModInfo> mod_list;
    SessionState session_now;
    std::vector<std::vector<std::uint8_t>> sent;
    std::vector<Received> incoming;
    std::vector<plugin_ui::Layer> layers;
    std::vector<plugin_ui::Panel> panels;
    std::vector<plugin_ui::Action> actions;
    bool panels_open{};
    void toast(std::string_view plugin, LogLevel, std::string_view text) override { toasts.push_back(std::string(plugin) + ": " + std::string(text)); }
    bool ui_sound(std::string_view name) override {
        if (name != "select" && name != "cancel" && name != "navigate" && name != "toggle" && name != "tab") return false;
        sounds.emplace_back(name);
        return true;
    }
    std::vector<ModInfo> mods() override { return mod_list; }
    SessionState session() override { return session_now; }
    bool send_message(std::vector<std::uint8_t> bytes) override {
        sent.push_back(std::move(bytes));
        return true;
    }
    std::vector<Received> take_messages() override { return std::exchange(incoming, {}); }
    // A camera at the origin looking down -Z, as the game's matrix has it: rows right, up, back.
    std::optional<Vec3> world_to_screen(const Vec3& p) override {
        if (p[2] >= -0.05f) return std::nullopt;
        const float depth = -p[2];
        return Vec3{960 + p[0] * 1000 / depth, 540 - p[1] * 1000 / depth, depth};
    }
    void publish_layers(std::vector<plugin_ui::Layer> value) override { layers = std::move(value); }
    bool panels_shown() override { return panels_open; }
    std::string shown;
    std::string shown_page() override { return shown; }
    std::vector<plugin_ui::PageEntry> pages;
    void publish_pages(std::vector<plugin_ui::PageEntry> value) override { pages = std::move(value); }
    void publish_panels(std::vector<plugin_ui::Panel> value) override { panels = std::move(value); }
    std::vector<plugin_ui::Action> take_actions() override { return std::exchange(actions, {}); }
    std::vector<HttpRequest> requests;
    std::vector<HttpResponse> responses;
    bool http_request(HttpRequest request) override {
        requests.push_back(std::move(request));
        return true;
    }
    std::vector<HttpResponse> take_http_responses() override { return std::exchange(responses, {}); }
    FakeGame fake;
    Game& game() override { return fake; }
    Teleport teleport(std::string_view, const Vec3& position, float heading) override {
        if (teleport_forbidden) return Teleport::forbidden;
        if (teleport_unavailable || !local_skater) return Teleport::unavailable;
        teleports.emplace_back(position, heading);
        return Teleport::sent;
    }
    std::optional<Vec3> raycast(const Vec3& from, const Vec3& to) override {
        ++rays;
        if ((from[1] > 0) == (to[1] > 0)) return std::nullopt;
        const float f = from[1] / (from[1] - to[1]);
        return Vec3{from[0] + (to[0] - from[0]) * f, 0, from[2] + (to[2] - from[2]) * f};
    }
    Game::CountedProbe raycast_bounded(const Vec3& from, const Vec3& to, unsigned allowed) override {
        if (!allowed) return {};
        const auto calls = std::min(allowed, ray_cast_cost); native_ray_casts += calls;
        const auto hit = raycast(from, to);
        if (!calls || calls != ray_cast_cost) return {{}, calls};
        const float f = hit ? from[1] / (from[1] - to[1]) : 0;
        return {{true, hit.has_value(), hit.value_or(Vec3{}), f}, calls};
    }
    bool logged(std::string_view part) const {
        return std::any_of(logs.begin(), logs.end(), [&](const auto& line) { return line.find(part) != std::string::npos; });
    }
    bool printed(std::string_view part) const {
        return std::any_of(lines.begin(), lines.end(), [&](const auto& line) { return line.find(part) != std::string::npos; });
    }
    std::string all() const {
        std::string text;
        for (const auto& line : logs) text += line + "\n";
        return text;
    }
};

std::string manifest(std::string permissions = "", std::string side = "client") {
    return R"({"api": 1, "entry": "plugin/main.lua", "side": ")" + side + R"(", "permissions": [)" + permissions + "]}";
}

void write(const std::filesystem::path& file, const std::string& text) {
    std::filesystem::create_directories(file.parent_path());
    std::ofstream(file, std::ios::binary | std::ios::trunc) << text;
}

// A mod folder holding a plugin: its reskate-plugin.json and files.
Candidate package(const std::string& id, const std::map<std::string, std::string>& files, std::string fingerprint = "1") {
    const auto directory = scratch / "mods" / id;
    std::filesystem::remove_all(directory);
    for (const auto& [name, text] : files) write(directory / name, text);
    return {id, directory, std::move(fingerprint), {}};
}
Candidate script(const std::string& id, const std::string& main, const std::string& permissions = "") {
    return package(id, {{manifest_file, manifest(permissions)}, {"plugin/main.lua", main}});
}

Status status_of(const Host& host, std::string_view id) {
    for (const auto& status : host.status()) if (status.id == id) return status;
    throw std::runtime_error("no plugin " + std::string(id));
}
void ticks(Host& host, TestEnvironment& environment, int count) {
    for (int i = 0; i < count; ++i) {
        environment.now += 16.7;
        host.tick(16.7);
    }
}
void running(const Host& host, std::string_view id, const TestEnvironment& environment) {
    const auto status = status_of(host, id);
    check(status.state == "running", std::string(id) + " should run, and is " + status.state + ": " + status.reason + "\n" + environment.all());
}
void stopped(const Host& host, std::string_view id, std::string_view because) {
    const auto status = status_of(host, id);
    check(status.state == "stopped", std::string(id) + " should have stopped, and is " + status.state);
    check(status.reason.find(because) != std::string::npos, std::string(id) + " stopped for \"" + status.reason + "\", not for " + std::string(because));
}

void effects_require_resident_roots() {
    auto declaration = dingosdk::Json::parse(manifest(R"("effects")"));
    const std::string particle = "effects/reskate/test/ebp_spark";
    declaration["effects"] = dingosdk::Json::array({particle});
    const auto refused = [&](const dingosdk::Json& value) {
        try { (void)parse_manifest(value.dump()); } catch (const std::exception&) { return; }
        throw std::runtime_error("An effect without valid resident coverage was accepted");
    };
    refused(declaration);
    for (const auto* bundle : {"win32/levels/test/sublevel", "win32/levels/test/root",
                               "win32/levels/game/dingolevel_root/dingolevel_root_extra"}) {
        declaration["resident"] = dingosdk::Json::array({dingosdk::Json{
            {"bundle", bundle}, {"roots", dingosdk::Json::array({"effects/reskate/test/"})}}});
        refused(declaration);
    }
    for (const auto* roots : {R"([])", R"(["effects/reskate/test"])", R"(["effects/reskate/tes/"])",
                             R"(["effects/reskate/test/ebp_spark_extra"])"}) {
        declaration["resident"] = dingosdk::Json::array({dingosdk::Json{
            {"bundle", "win32/levels/game/dingolevel_root/dingolevel_root"}, {"roots", dingosdk::Json::parse(roots)}}});
        refused(declaration);
    }
    for (const auto* root : {"effects/reskate/test/", "EFFECTS/RESKATE/TEST/", "effects/reskate/test/ebp_spark"}) {
        declaration["resident"] = dingosdk::Json::array({dingosdk::Json{
            {"bundle", "win32/levels/game/dingolevel_root/dingolevel_root"}, {"roots", dingosdk::Json::array({root})}}});
        check(parse_manifest(declaration.dump()).effects.contains(particle), "Exact and directory roots cover an effect");
    }
    declaration["resident"][0]["bundle"] = "WIN32/LEVELS/GAME/DINGOLEVEL_ROOT/DINGOLEVEL_ROOT";
    check(parse_manifest(declaration.dump()).effects.contains(particle), "Resident bundle names are normalized consistently with the merge");
    declaration["resident"] = dingosdk::Json::parse(R"([
        {"bundle":"win32/levels/game/dingolevel_root/dingolevel_root","roots":["effects/reskate/other/"]},
        {"bundle":"win32/levels/test/sublevel","roots":["effects/reskate/test/"]}
    ])");
    refused(declaration); // Coverage must be in the same row as the supported bundle.
    // The merge discards the entire resident list when any row or shader is malformed.
    for (const auto* bad : {R"([{"roots":["effects/reskate/test/"]}])",
                           R"([{"bundle":"win32/levels/game/dingolevel_root/dingolevel_root","roots":["effects/reskate/test/"],"shaders":[{"name":"depot","roots":[]}]}])",
                           R"([{"bundle":"win32/levels/game/dingolevel_root/dingolevel_root","roots":["effects/reskate/test/"]},{"bundle":7}])"}) {
        declaration["resident"] = dingosdk::Json::parse(bad);
        refused(declaration);
    }
    bool denied = false;
    try { (void)parse_manifest(manifest(R"("events.physics.geometry")")); }
    catch (const std::exception&) { denied = true; }
    check(denied, "Geometry does not bypass the base physics permission");
}

void expired_effects_return_their_quota() {
    TestEnvironment environment;
    Limits limits;
    limits.call_ms = 1000;
    Host host(environment, Side::client, limits);
    auto declaration = dingosdk::Json::parse(manifest(R"("effects", "console")"));
    declaration["effects"] = dingosdk::Json::array({"effects/reskate/test/ebp_spark", "world/materials/decal/reskate_test/stain_dv"});
    declaration["resident"] = dingosdk::Json::parse(R"([{"bundle":"win32/levels/game/dingolevel_root/dingolevel_root", "roots":["effects/reskate/test/", "world/materials/decal/reskate_test/"]}])");
    host.apply({package("effects-expire", {{manifest_file, declaration.dump()}, {"plugin/main.lua", R"(
        local fx = reskate.effects
        local m = {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}
        reskate.console.command("fxfill", "", function()
            for i=1,24 do assert(fx.particle("effects/reskate/test/ebp_spark", m)) end
            for i=1,2048 do assert(fx.decal("world/materials/decal/reskate_test/stain_dv", m)) end
            assert(fx.particle("effects/reskate/test/ebp_spark", m) == nil)
            assert(fx.decal("world/materials/decal/reskate_test/stain_dv", m) == nil)
        end)
    )"}})});
    auto& game = environment.fake;
    check(host.run_console("fxfill") && game.effects.size() == 2072, "Both effect quotas can be filled");
    game.effects.clear(); // Ten-minute native expiry, with no change to the world epoch.
    ticks(host, environment, 1);
    check(host.run_console("fxfill") && game.effects.size() == 2072, "Expiry returns both quotas without Lua release/clear");
    ticks(host, environment, 1);
    game.effects.clear();
    ++game.effect_epoch;
    // A console call can arrive after the native reset but before Plugin::tick.
    check(host.run_console("fxfill") && game.effects.size() == 2072, "A reset returns quota even before the next VM tick");
    running(host, "effects-expire", environment);
}

void plugins_render_private_effects() {
    TestEnvironment environment;
    // Filling every decal slot tests the resource quota, with room for a busy CI machine.
    Limits limits;
    limits.call_ms = 1000;
    Host host(environment, Side::client, limits);
    host.apply({script("effects-denied", R"(
        for _,f in pairs(reskate.effects) do
            local ok,why=pcall(f)
            assert(not ok and why:find("permission"), tostring(why))
        end
        reskate.log("all effects denied")
    )")});
    running(host, "effects-denied", environment);
    check(environment.logged("all effects denied"), environment.all());
    check(environment.fake.effects.empty(), "A plugin without permission cannot reach the renderer");
    auto declaration = dingosdk::Json::parse(manifest(R"("effects", "console")"));
    const std::string particle = "effects/reskate/test/ebp_spark";
    const std::string material = "world/materials/decal/reskate_test/stain_dv";
    declaration["effects"] = dingosdk::Json::array({particle, material});
    declaration["resident"] = dingosdk::Json::parse(R"([{"bundle":"win32/levels/game/dingolevel_root/dingolevel_root", "roots":["effects/reskate/test/", "world/materials/decal/reskate_test/"]}])");
    for (unsigned scenario = 0; scenario < 3; ++scenario) {
        auto invalid = declaration;
        if (scenario == 0) invalid["permissions"] = dingosdk::Json::array();
        else if (scenario == 1) invalid["effects"] = particle;
        else {
            auto names = dingosdk::Json::array();
            for (unsigned i = 0; i < 129; ++i) names.push_back(particle + std::to_string(i));
            invalid["effects"] = std::move(names);
        }
        bool refused = false;
        try { (void)parse_manifest(invalid.dump()); } catch (const std::exception&) { refused = true; }
        check(refused, "An effect allowlist needs permission, an array and at most 128 names");
    }
    for (const auto* forbidden : {"effects/gestures/effectblueprints/ebp_gesture_applause", "effects/reskate/../store/item", "world/materials/decal/paid"}) {
        auto invalid = declaration;
        invalid["effects"] = dingosdk::Json::array({forbidden});
        bool refused = false;
        try { (void)parse_manifest(invalid.dump()); } catch (const std::exception&) { refused = true; }
        check(refused, "Stock, store and path escapes are refused in effects manifests");
    }
    const auto main = R"(
        local fx=reskate.effects
        local m={1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}
        local p="effects/reskate/test/ebp_spark"
        local d="world/materials/decal/reskate_test/stain_dv"
        assert(not pcall(fx.particle,"effects/reskate/test/not_declared",m))
        assert(not pcall(fx.particle,"effects/gestures/effectblueprints/ebp_gesture_applause",m))
        assert(not pcall(fx.decal,p,m))
        local broken=table.clone(m); broken[1]=0/0
        assert(not pcall(fx.particle,p,broken))
        broken=table.clone(m); broken[4]=1
        assert(not pcall(fx.particle,p,broken))
        broken=table.clone(m); broken[1]=0
        assert(not pcall(fx.particle,p,broken))
        assert(not pcall(fx.decal,d,m,{lift=2}))
        for i=1,24 do assert(fx.particle(p,m)) end
        assert(fx.particle(p,m)==nil,"particle quota")
        for i=1,2048 do assert(fx.decal(d,m,{attach=true,lift=.04})) end
        assert(fx.decal(d,m)==nil,"decal quota")
        fx.clear()
        local id=assert(fx.particle(p,m))
        m[13]=3; fx.move(id,m); fx.stop(id)
        assert(not pcall(fx.opacity,id,-1))
        local decal=assert(fx.decal(d,m,{attach=true,lift=.04})); fx.opacity(decal,.5)
        reskate.console.command("fxgone","",function() fx.release(id); fx.release(decal) end)
        reskate.console.command("fxfail","",function() error("intentional") end)
    )";
    host.apply({package("effects-owner", {{manifest_file, declaration.dump()}, {"plugin/main.lua", main}})});
    running(host, "effects-owner", environment);
    auto& game = environment.fake;
    check(game.effects.size() == 2, "Quota objects are cleared before the two live effects");
    for (const auto& [id, e] : game.effects) {
        check(e.request.transform[12] == 3, "Effects move without native addresses");
        check(e.request.decal ? e.alpha == .5f && e.request.attach : e.stopped, "Stop, opacity and attachment reach the game");
    }
    const auto owned_id = game.effects.begin()->first;
    auto intruder = R"(assert(not pcall(reskate.effects.release, )" + std::to_string(owned_id) + R"()); reskate.log("foreign effect denied"))";
    host.apply({{ "effects-owner", scratch / "mods" / "effects-owner", "1", {} },
                package("effects-intruder", {{manifest_file, declaration.dump()}, {"plugin/main.lua", intruder}})});
    running(host, "effects-intruder", environment);
    check(environment.logged("foreign effect denied") && game.effects.size() == 2, "Handles never cross plugin ownership");
    check(host.run_console("fxgone") && game.effects.empty(), "Release disposes both owned references");
    host.reload("effects-owner");
    running(host, "effects-owner", environment);
    check(game.effects.size() == 2, "Reload starts from a clean owner");
    for (int i = 0; i < 6; ++i) (void)host.run_console("fxfail");
    stopped(host, "effects-owner", "errors");
    check(game.effects.empty(), "Stopping a failing VM releases its effects");
}

void failed_plugin_startup_releases_effects() {
    for (const auto side : {Side::client, Side::server}) {
        TestEnvironment environment;
        const std::string suffix = side == Side::server ? "@server" : "";
        const std::string owner = "effect-startup" + suffix;
        Host host(environment, side, {}, suffix);
        auto declaration = dingosdk::Json::parse(manifest(R"("effects", "console")", "both"));
        declaration["effects"] = dingosdk::Json::array({"effects/reskate/test/ebp_spark", "world/materials/decal/reskate_test/stain_dv"});
        declaration["resident"] = dingosdk::Json::parse(R"([{"bundle":"win32/levels/game/dingolevel_root/dingolevel_root", "roots":["effects/reskate/test/", "world/materials/decal/reskate_test/"]}])");
        // The other copy of this same plugin keeps its effects when this one fails.
        auto& game = environment.fake;
        const auto other = game.effect_create(side == Side::server ? "effect-startup" : "effect-startup@server", {});
        const std::string main = R"(
            local m = {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}
            assert(reskate.effects.particle("effects/reskate/test/ebp_spark", m))
            assert(reskate.effects.decal("world/materials/decal/reskate_test/stain_dv", m))
            reskate.console.command("fxstartup", "", function() end)
        )";
        host.apply({package("effect-startup", {{manifest_file, declaration.dump()},
            {"plugin/main.lua", main + R"(error("intentional effect startup failure"))"}})});
        stopped(host, "effect-startup", "error");
        check(environment.logged("intentional effect startup failure") && game.effect_serial == 3,
              "Startup reached the failure after creating both effects\n" + environment.all());
        check(game.effects.size() == 1 && game.effects.contains(other), "Failed startup releases only its own effects immediately");
        check(game.released == std::vector<std::string>{owner}, "Startup failure releases the full owner id, including its server suffix");
        ticks(host, environment, 2);
        check(game.effects.size() == 1 && game.effects.contains(other), "Later ticks preserve the other copy's effects");
        (void)host.switch_on(owner);
        stopped(host, "effect-startup", "error");
        check(game.effect_serial == 5 && game.effects.size() == 1 && game.effects.contains(other),
              "Repeated startup failures do not accumulate effects");
        write(scratch / "mods/effect-startup/plugin/main.lua", main);
        (void)host.switch_on(owner);
        running(host, "effect-startup", environment);
        check(host.run_console("fxstartup") && game.effects.size() == 3, "A repaired plugin can reclaim its command and create new effects");
        host.shutdown();
        check(game.effects.size() == 1 && game.effects.contains(other), "Shutdown still releases only this copy's effects");
    }
}

void plugins_track_effect_lifetimes() {
    TestEnvironment environment;
    Limits limits;
    limits.call_ms = 1000; // Exercise all 8192 operations independently of the timing tests.
    Host host(environment, Side::client, limits);
    auto declaration = dingosdk::Json::parse(manifest(R"("effects", "console")"));
    declaration["effects"] = dingosdk::Json::array({"effects/reskate/test/ebp_spark"});
    declaration["resident"] = dingosdk::Json::parse(R"([{"bundle":"win32/levels/game/dingolevel_root/dingolevel_root", "roots":["effects/reskate/test/", "world/materials/decal/reskate_test/"]}])");
    host.apply({package("effect-lifetime", {{manifest_file, declaration.dump()}, {"plugin/main.lua", R"(
        local fx = reskate.effects
        local asset = "effects/reskate/test/ebp_spark"
        local transform = {1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1}
        local ready, epoch = fx.state()
        assert(ready)
        local expired = assert(fx.particle(asset, transform))
        reskate.console.command("fxmissing", "", function()
            local available, current = fx.state()
            assert(not available and current ~= epoch)
            local id, why = fx.particle(asset, transform)
            assert(id == nil and why:find("unavailable"))
            fx.release(expired)
            assert(not pcall(fx.release, expired), "a released handle cannot be reused")
            fx.clear(); fx.clear()
            reskate.log("expired effects cleared")
        end)
        reskate.console.command("fxbudget", "", function()
            for i = 1, 8192 do fx.state() end
            local ok, why = pcall(fx.state)
            assert(not ok and why:find("8192"))
            reskate.log("effect call limit enforced")
        end)
        reskate.console.command("fxnew", "", function()
            assert(fx.state())
            local id = assert(fx.particle(asset, transform))
            assert(id ~= expired, "a new world never reuses a stale handle")
            reskate.log("effect created after reset")
        end)
    )"}})});
    running(host, "effect-lifetime", environment);
    auto& game = environment.fake;
    check(game.effects.size() == 1, "An effect belongs to the running plugin");
    game.effects_ready = false;
    ++game.effect_epoch;
    game.effects.clear(); // Native world teardown precedes the plugin's next callback.
    check(host.run_console("fxmissing") && environment.logged("expired effects cleared"), environment.all());
    game.effects_ready = true;
    ticks(host, environment, 1);
    check(host.run_console("fxbudget") && environment.logged("effect call limit enforced"), environment.all());
    ticks(host, environment, 1);
    check(host.run_console("fxnew") && environment.logged("effect created after reset") && game.effects.size() == 1,
          "The next tick restores the operation allowance\n" + environment.all());
    host.reload("effect-lifetime");
    running(host, "effect-lifetime", environment);
    check(game.effects.size() == 1, "Reload releases the previous VM's native effects");
    host.apply({});
    check(game.effects.empty(), "Removing a plugin releases all its effects");
}

void physics_steps_include_optional_geometry() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("physics-geometry", R"(
        local samples = 0
        reskate.on("physics_step", function(step)
            samples += 1
            local body = step.bodies["Left forearm"]
            if samples == 1 then
                assert(step.at == 1000 and math.abs(step.seconds - .05) < .000001)
                assert(step.state == 300 and step.wipeout and step.ragdoll and not step.airborne)
                assert(body.impact == 12 and body.slide == 5 and body.world and not body.board)
                assert(body.point[1] == 2 and body.point[2] == 0 and body.point[3] == 4)
                assert(body.normal[1] == 0 and body.normal[2] == 1 and body.normal[3] == 0)
                local expected = {1,0,0,0,0,1,0,0,0,0,1,0,2,.25,4,1}
                for _, name in {"Pelvis", "Left forearm"} do
                    local pose = step.poses[name]
                    assert(#pose.transform == 16 and #pose.velocity == 3)
                    for i, value in expected do assert(pose.transform[i] == value) end
                    assert(pose.velocity[1] == 5 and pose.velocity[2] == -10 and pose.velocity[3] == 0)
                end
                assert(step.bodies.Pelvis == nil, "a body can have a pose without a contact")
                reskate.log("contact geometry received")
            else
                assert(step.state == nil and step.ragdoll == nil)
                assert(body.point == nil and body.normal == nil and next(step.poses) == nil)
                reskate.log("missing geometry stays absent")
            end
        end)
    )", R"("events.physics", "events.physics.geometry")"), script("physics-basic", R"(
        reskate.on("physics_step", function(step)
            assert(step.poses == nil and step.state == nil)
            local body = step.bodies["Left forearm"]
            assert(body and body.impact == 12 and body.point == nil and body.normal == nil)
            reskate.log("basic physics has no geometry")
        end)
    )", R"("events.physics")"), script("physics-denied", R"(
        local ok, why = pcall(reskate.on, "physics_step", function() error("not permitted") end)
        assert(not ok and why:find("events.physics"))
        reskate.log("physics permission enforced")
    )")});
    running(host, "physics-geometry", environment);
    running(host, "physics-denied", environment);
    check(environment.logged("physics permission enforced"), environment.all());
    PhysicsStep value;
    value.at = environment.now; value.seconds = .05f; value.state = 300;
    value.wipeout = true; value.ragdoll = true;
    const EffectMatrix matrix{1,0,0,0,0,1,0,0,0,0,1,0,2,.25f,4,1};
    value.poses.emplace("Pelvis", PhysicsStep::Pose{matrix, {5, -10, 0}});
    value.poses.emplace("Left forearm", PhysicsStep::Pose{matrix, {5, -10, 0}});
    value.bodies.push_back({"Left forearm", 12, 5, false, false, true, Vec3{2,0,4}, Vec3{0,1,0}});
    environment.fake.steps.push_back(value);
    ticks(host, environment, 1);
    check(environment.logged("contact geometry received") && environment.logged("basic physics has no geometry"), environment.all());
    value.state.reset(); value.ragdoll.reset(); value.poses.clear();
    value.bodies[0].point.reset(); value.bodies[0].normal.reset();
    environment.fake.steps.push_back(value);
    ticks(host, environment, 1);
    check(environment.logged("missing geometry stays absent"), environment.all());
}

void a_manifest_says_what_a_plugin_is() {
    const auto good = parse_manifest(manifest(R"("console", "storage")"));
    check(good.api == 1 && good.entry == "plugin/main.lua" && good.side == Side::client, "A manifest is read");
    check(good.permissions.contains("console") && good.permissions.contains("storage"), "with its permissions");
    const auto refused = [](const std::string& text, std::string_view because) {
        try {
            parse_manifest(text);
        } catch (const std::exception& error) {
            check(std::string(error.what()).find(because) != std::string::npos, "Refused for \"" + std::string(error.what()) + "\", not " + std::string(because));
            return;
        }
        throw std::runtime_error("A manifest that should be refused was read: " + text);
    };
    refused(R"({"entry": "main.lua"})", "\"api\"");
    refused(R"({"api": 2, "entry": "main.lua"})", "update ReSkate");
    refused(R"({"api": 1, "entry": "../main.lua"})", "inside the mod folder");
    refused(R"({"api": 1, "entry": "C:/main.lua"})", "inside the mod folder");
    refused(R"({"api": 1, "entry": "a\\main.lua"})", "inside the mod folder");
    refused(R"({"api": 1, "entry": "main.txt"})", ".lua");
    refused(R"({"api": 1, "entry": "main.lua", "side": "moon"})", "\"side\"");
    refused(R"({"api": 1, "entry": "main.lua", "permissions": ["root"]})", "unknown permission");
    refused("not json", "not valid JSON");
    check(safe_relative_path("a/b.lua") == "a/b.lua", "A path inside the package is kept");
    for (const auto* bad : {"", "/a", "a//b", "./a", "a/../b", "..", "a\\b", "c:a", "a.", "a /b", "a\nb"})
        check(safe_relative_path(bad).empty(), std::string("A path that could leave the package is refused: ") + bad);
}

void plugins_own_typed_bodies_and_acknowledge_measured_results() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    const auto candidate = script("owned-body", R"(
        local P, v = reskate.world.physics, vector.create
        local definition = {mass=12, inertia=v(2,3,4), position=v(1,2,3), rotation={0,0,0,1}, capsules={{a=v(0,0,0),b=v(0,.5,0),radius=.1}}}
        local h = assert(P.create(definition))
        assert(type(h)=="userdata" and getmetatable(h)=="locked")
        local s = assert(P.read(h))
        assert(type(s.epoch)=="userdata" and s.position==v(1,2,3) and s.mass==12 and s.rotation[4]==1 and type(s.serial)=="string")
        local other = assert(P.create(definition))
        assert(not pcall(P.read, {}), "forged body")
        assert(not pcall(P.submit,h,{},{}), "forged epoch")
        assert(not pcall(P.submit,other,s.epoch,{}), "epoch transplanted to another body")
        assert(not pcall(P.submit,h,s.epoch,{impulse=v(0,2,0)}), "anonymous impulse")
        assert(not pcall(P.submit,h,s.epoch,{force=v(40000,40000,0)}), "vector norm")
        assert(not pcall(P.submit,h,s.epoch,{torque=v(0/0,0,0)}), "NaN")
        assert(not pcall(P.submit,h,s.epoch,{impulse_id=1.5}), "fractional event")
        assert(not pcall(P.submit,h,s.epoch,{native_handle=42}), "raw handle field")
        definition.mask=0xffffffff
        assert(not pcall(P.create,definition), "arbitrary collision mask")
        definition.mask=nil
        assert(P.submit(h,s.epoch,{impulse=v(0,2,0),impulse_id=1}))
        assert(not P.submit(h,s.epoch,{}), "immutable pending packet")
        local queued=assert(P.receipt(h))
        assert(queued.outcome=="queued" and not queued.successor and not P.acknowledge(h,queued.sequence))
        assert(not pcall(P.acknowledge,h,1), "sequence string cannot be a coerced number")
        assert(not pcall(P.acknowledge,h,queued.sequence..string.char(0).."junk"), "sequence cannot hide trailing bytes")
        local done=false
        reskate.on("tick",function()
            if done then return end
            local r=assert(P.receipt(h))
            if r.outcome=="queued" then return end
            assert(r.outcome=="applied" and r.force_attempted and r.torque_attempted)
            if not r.successor then
                assert(not P.acknowledge(h,r.sequence), "no fictitious successor")
                return
            end
            assert(tonumber(r.produced_serial)==tonumber(s.serial)+1)
            assert(tonumber(r.successor.serial)>tonumber(r.produced_serial))
            assert(P.acknowledge(h,r.sequence))
            assert(not P.acknowledge(h,r.sequence), "ack twice")
            assert(not P.submit(h,s.epoch,{}), "old observed serial")
            assert(P.release(h) and P.release(other))
            assert(not P.read(h))
            assert(P.receipt(h).retained)
            done=true
            reskate.log("owned body acknowledged its measured successor")
        end)
    )", R"("world.physics")");
    host.apply({candidate}); running(host, "owned-body", environment);
    check(environment.fake.body_creates == 2 && environment.fake.body_submissions == 1, "API forwarded only bounded accepted definitions and one packet");
    environment.fake.body_producer_step(); ticks(host, environment, 1); running(host, "owned-body", environment);
    check(!environment.logged("acknowledged its measured"), "setter completion was not treated as an integrated successor");
    environment.fake.body_producer_step(); ticks(host, environment, 1); running(host, "owned-body", environment);
    check(environment.logged("owned body acknowledged its measured successor"), environment.all());
    const auto old_owner = environment.fake.owned.begin()->second.owner;
    host.apply({}); check(std::find(environment.fake.body_releases.begin(), environment.fake.body_releases.end(), old_owner) != environment.fake.body_releases.end(), "VM close releases its instance");
    host.apply({candidate}); running(host, "owned-body", environment);
    check(environment.fake.owned.at(3).owner != old_owner, "reloaded VM reused its old native owner epoch");
    owned_body::Sample sample;
    check(!environment.fake.body_read(environment.fake.owned.at(3).owner, {1,0}, sample).empty(), "another VM instance adopted a retained body");
}

void plugins_pipeline_native_steps_and_select_owned_receipts() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("body-pipeline", R"(
        local P,v=reskate.world.physics,vector.create
        local d={mass=12,inertia=v(2,3,4),position=v(0,2,0),rotation={0,0,0,1},capsules={{a=v(0,0,0),b=v(0,.5,0),radius=.1}}}
        local h,other=assert(P.create(d)),assert(P.create(d))
        local ids={}
        local function publish(sample)
            local ok,why,id=P.submit(h,sample.epoch,{force=v(0,20,0)})
            assert(ok and why==nil and type(id)=="string")
            table.insert(ids,id)
            return id
        end
        publish(assert(P.read(h)))
        local ok,why,foreign=P.submit(other,assert(P.read(other)).epoch,{})
        assert(ok and why==nil and type(foreign)=="string" and foreign~=ids[1])
        local done=false
        reskate.on("tick",function()
            if done then return end
            local sample=assert(P.read(h))
            local first=assert(P.receipt(h))
            assert(first.sequence==ids[1] and first.outcome=="applied")
            assert(not P.receipt(h,foreign),"foreign body's sequence selected a local receipt")
            assert(not P.receipt(h,"999999999999"),"absent sequence")
            assert(not pcall(P.receipt,h,1) and not pcall(P.receipt,h,ids[1]..string.char(0).."x")
                and not pcall(P.receipt,h,"0"..ids[1]),"malformed selection")
            if #ids==1 then assert(not first.successor and not P.acknowledge(h,ids[1])) end
            if #ids>=2 then assert(first.successor.serial=="102","first successor moved to a later observation") end
            if #ids<4 then
                local id=publish(sample)
                assert(P.receipt(h,id).outcome=="queued" and P.receipt(h).sequence==ids[1])
                return
            end
            local accepted,reason=P.submit(h,sample.epoch,{})
            assert(not accepted and type(reason)=="string","full receipt ring lost backpressure")
            assert(not P.acknowledge(h,ids[2]),"ack order")
            assert(P.acknowledge(h,ids[1]) and not P.receipt(h,ids[1]),"freed record stayed selectable")
            local fifth=publish(sample)
            assert(P.receipt(h,fifth).outcome=="queued" and P.receipt(h).sequence==ids[2])
            assert(tonumber(P.receipt(h,ids[2]).produced_serial)==102 and tonumber(P.receipt(h,ids[3]).produced_serial)==103
                and tonumber(P.receipt(h,ids[4]).produced_serial)==104,"consecutive 60Hz control skipped a native step")
            done=true;reskate.log("body pipeline advanced four native steps without awaiting acknowledgement")
        end)
    )", R"("world.physics")")});
    running(host, "body-pipeline", environment);
    for (unsigned i = 0; i < 4; ++i) { environment.fake.body_producer_step(); ticks(host, environment, 1); running(host, "body-pipeline", environment); }
    check(environment.logged("body pipeline advanced four native steps"), environment.all());
    check(environment.fake.body_submissions == 6, "full-ring refusal was forwarded or consecutive commands were dropped");
    const auto pending_sequence = environment.fake.owned.at(1).mailbox.sequence;
    host.apply({});
    auto& retired = environment.fake.owned.at(1); owned_body::Receipt canceled;
    check(retired.released && !retired.mailbox.pending && retired.mailbox.failed && retired.mailbox.find(pending_sequence, canceled) &&
        canceled.outcome == owned_body::Outcome::rejected, "VM unload did not revoke a pipelined pending packet");
}
void plugins_can_inspect_later_partial_failure_without_acknowledging_unmeasured_head() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("body-pipeline-failure", R"(
        local P,v=reskate.world.physics,vector.create
        local h=assert(P.create({mass=12,inertia=v(2,3,4),position=v(0,2,0),rotation={0,0,0,1},capsules={{a=v(0,0,0),b=v(0,.5,0),radius=.1}}}))
        local ok,why,first=P.submit(h,assert(P.read(h)).epoch,{impulse=v(0,2,0),impulse_id=1})
        assert(ok and not why and type(first)=="string")
        local second,held,done
        reskate.on("tick",function()
            if done then return end
            if not second then
                held=assert(P.read(h)).epoch
                assert(P.receipt(h,first).outcome=="applied" and not P.receipt(h,first).successor)
                local ok,why,id=P.submit(h,held,{impulse=v(0,2,0),impulse_id=2})
                assert(ok and not why);second=id;return
            end
            local head,later=assert(P.receipt(h)),assert(P.receipt(h,second))
            assert(head.sequence==first and head.outcome=="applied" and not head.successor and head.quarantined)
            assert(later.outcome=="partial" and later.force_attempted and not later.torque_attempted and later.quarantined)
            assert(not P.acknowledge(h,first) and not P.acknowledge(h,second),"failure waived successor or ack order")
            assert(not P.read(h) and not P.submit(h,held,{}),"failed owner stayed writable")
            assert(P.release(h) and P.receipt(h,second).retained)
            done=true;reskate.log("later partial body receipt is inspectable behind unmeasured head")
        end)
    )", R"("world.physics")")});
    running(host, "body-pipeline-failure", environment);
    environment.fake.body_producer_step(); ticks(host, environment, 1); running(host, "body-pipeline-failure", environment);
    environment.fake.body_producer_step(false); ticks(host, environment, 1); running(host, "body-pipeline-failure", environment);
    check(environment.logged("later partial body receipt is inspectable"), environment.all());
    check(environment.fake.body_submissions == 2 && environment.fake.owned.at(1).mailbox.failed, "partial command was replayed or failed mailbox reopened");
}

void sync_probe_observations_are_opaque_bounded_and_copied() {
    TestEnvironment environment; Host host(environment, Side::client);
    const auto candidate = script("sync-probe", R"(
        local P=reskate.world.physics;local v=vector.create
        local h=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
            capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
        assert(not pcall(P.begin_sync_probe,{}) and not pcall(P.begin_sync_probe,h,h))
        local probe=assert(P.begin_sync_probe(h))
        assert(type(probe)=="userdata" and getmetatable(probe)=="locked")
        assert(not pcall(function() return probe.sequence end))
        assert(not pcall(P.read,probe) and not pcall(P.poll_sync_probe,h))
        assert(not pcall(P.poll_sync_probe,{}) and not pcall(P.poll_sync_probe,"9007199254740995"))
        assert(not pcall(P.poll_sync_probe,probe,probe))
        local again,why=P.begin_sync_probe(h);assert(again==nil and why:find("once in one tick"))
        for i=1,8 do
            local r=assert(P.poll_sync_probe(probe));assert(r.status=="pending" and not r.terminal)
            assert(#r.records==4 and r.observed_mask==0 and not r.observed_epoch and not r.sequence)
            assert(r.armed_epoch.serial=="9007199254740994" and not r.armed_epoch.world and not r.armed_epoch.body)
            for _,row in r.records do assert(not row.present and not row.supplied and not row.epoch) end
        end
        local no,why=P.poll_sync_probe(probe);assert(no==nil and why:find("8 times in one tick"))
        local done=false
        reskate.on("tick",function()
            if done then return end
            local r=assert(P.poll_sync_probe(probe));assert(r.status=="observed" and r.terminal and r.observed_mask==15)
            assert(r.observed_epoch.serial=="9007199254740999" and not r.observed_epoch.world and not r.observed_epoch.body)
            assert(r.rejected==2 and r.dropped==3 and not r.sequence and not r.native_consumed)
            local previous=r.armed_epoch.time
            for i,row in r.records do
                assert(row.present and row.pending_before and not row.pending_after and row.transform_matches)
                assert(row.before_flags==2147483649 and row.after_flags==2147483648)
                assert(#row.supplied==16 and row.supplied[13]==5 and row.com_position==v(1,2,3))
                assert(row.origin==v(5,6,7) and row.local_com==v(.1,.2,.3))
                assert(#row.rotation==4 and #row.local_rotation==4 and row.epoch.time>previous)
                assert(not row.epoch.world and not row.epoch.body and not row.body and not row.sequence)
                previous=row.epoch.time
            end
            r.records[1].supplied[13]=999;r.records[1].origin=v(999,999,999);r.observed_mask=0
            local copy=assert(P.poll_sync_probe(probe));assert(copy.records[1].supplied[13]==5 and copy.observed_mask==15)
            assert(copy.records[1].origin==v(5,6,7))
            done=true;reskate.log("bounded passive synchronizer facts copied without authority")
        end)
    )", R"("world.physics","world.physics.observe")");
    host.apply({candidate}); running(host,"sync-probe",environment);
    check(environment.fake.sync_probe_starts==1 && environment.fake.sync_probe_polls==8,
        "invalid arguments or per-tick budget reached probe backend");
    environment.fake.complete_sync_probe(); ticks(host,environment,1); running(host,"sync-probe",environment);
    check(environment.logged("bounded passive synchronizer facts copied without authority"),environment.all());
    check(environment.fake.sync_probe_polls==10 && !environment.fake.body_submissions &&
        !environment.fake.batch_calls && environment.teleports.empty() && environment.fake.calls.empty(),
        "copied passive observations performed a body command, raycast or actor action");
    const auto old=environment.fake.sync_probe;
    dingosdk::body_sync_probe::Result denied;
    check(!environment.fake.body_poll_sync_probe(old.owner+1,old.handle,old.sequence,denied).empty() &&
        !environment.fake.body_poll_sync_probe(old.owner,{old.handle.generation+1,old.handle.slot},old.sequence,denied).empty() &&
        !environment.fake.body_poll_sync_probe(old.owner,old.handle,old.sequence+1,denied).empty(),
        "foreign owner, body or opaque sequence adopted probe authority");
    host.apply({});
    check(environment.fake.sync_probe.sequence==old.sequence &&
        std::find(environment.fake.body_releases.begin(),environment.fake.body_releases.end(),old.owner)!=environment.fake.body_releases.end() &&
        environment.fake.body_poll_sync_probe(old.owner,old.handle,old.sequence,denied).empty() &&
        denied.status==old.result.status && denied.observed_mask==old.result.observed_mask &&
        denied.observed_epoch==old.result.observed_epoch && denied.records[0].supplied==old.result.records[0].supplied,
        "VM unload rewrote immutable terminal history");
    host.apply({candidate}); running(host,"sync-probe",environment);
    check(environment.fake.sync_probe.owner!=old.owner && environment.fake.sync_probe.sequence!=old.sequence &&
        !environment.fake.body_poll_sync_probe(environment.fake.sync_probe.owner,old.handle,old.sequence,denied).empty(),
        "replacement VM inherited a previous probe capability");
}

void sync_probe_permissions_client_phase_and_transport_are_enforced() {
    TestEnvironment environment; Host host(environment, Side::client);
    for (const auto& permission : {std::string{},std::string{R"("world.physics")"},std::string{R"("world.physics.observe")"}}) {
        host.apply({script("probe-denied",R"(
            for _,name in {"begin_sync_probe","poll_sync_probe"} do
                local ok,why=pcall(reskate.world.physics[name],{})
                assert(not ok and why:find("world.physics"),name)
            end
        )",permission)}); running(host,"probe-denied",environment);
    }
    check(!environment.fake.sync_probe_starts && !environment.fake.sync_probe_polls,"permission denial reached probe backend");
    TestEnvironment server_environment; Host server(server_environment,Side::server);
    server.apply({package("probe-server",{{manifest_file,manifest(R"("world.physics","world.physics.observe")","server")},{"plugin/main.lua",R"(
        for _,name in {"begin_sync_probe","poll_sync_probe"} do
            local ok,why=pcall(reskate.world.physics[name],{})
            assert(not ok and why:find("client phase only"),name)
        end
    )"}})}); running(server,"probe-server",server_environment);
    check(!server_environment.fake.sync_probe_starts && !server_environment.fake.sync_probe_polls,"server reached probe backend");

    host.apply({script("probe-library",R"(
        local P=reskate.world.physics;local v=vector.create
        local h=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
            capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
        local probe=assert(P.begin_sync_probe(h))
        reskate.expose({probe=function() return probe end})
    )",R"("world.physics","world.physics.observe")"),script("probe-foreign",R"(
        reskate.console.command("probe-transfer","x",function()
            local other=assert(reskate.require_plugin("probe-library"))
            local ok=pcall(other.probe);assert(not ok,"userdata crossed plugin instance transport")
            reskate.log("probe userdata cannot cross plugin transport")
        end)
    )",R"("console","world.physics","world.physics.observe")")});
    running(host,"probe-library",environment); running(host,"probe-foreign",environment);
    check(host.run_console("probe-transfer") && environment.logged("probe userdata cannot cross plugin transport"),environment.all());
    check(environment.fake.sync_probe_starts==1 && !environment.fake.sync_probe_polls,
        "cross-instance transport reached probe polling");
}

void sync_probe_binding_rejects_malformed_backend_facts() {
    for (unsigned corruption=1;corruption<=20;++corruption) {
        TestEnvironment environment; Host host(environment,Side::client);
        host.apply({script("probe-malformed",R"(
            local P=reskate.world.physics;local v=vector.create
            local h=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
                capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
            local probe=assert(P.begin_sync_probe(h))
            reskate.on("tick",function()
                local r,why=P.poll_sync_probe(probe)
                assert(r==nil and why:find("invalid observations"))
                reskate.log("malformed passive evidence rejected")
            end)
        )",R"("world.physics","world.physics.observe")")});
        running(host,"probe-malformed",environment); environment.fake.complete_sync_probe();
        auto& out=environment.fake.sync_probe.result;auto& r=out.records[0];
        const auto nan=std::numeric_limits<float>::quiet_NaN();
        switch(corruption) {
        case 1: out.status=static_cast<dingosdk::body_sync_probe::Status>(255);break;
        case 2: out.armed_epoch.time=nan;break;
        case 3: out.observed_mask|=16;break;
        case 4: r.present=false;break;
        case 5: r.epoch.serial=out.armed_epoch.serial;break;
        case 6: ++r.epoch.world;break;
        case 7: ++r.epoch.body;break;
        case 8: r.pending_after=true;break;
        case 9: r.supplied[0]=nan;break;
        case 10: r.com_position[0]=nan;break;
        case 11: r.origin[0]=nan;break;
        case 12: r.local_com[0]=nan;break;
        case 13: r.rotation[0]=nan;break;
        case 14: r.local_rotation[0]=nan;break;
        case 15: out.observed_epoch=out.armed_epoch;break;
        case 16: out.observed_mask=7;out.records[3].present=false;break;
        case 17: out.observed_epoch=out.records.back().epoch;break;
        case 18: out.armed_epoch.serial=0;break;
        case 19: r.epoch.time=out.armed_epoch.time;break;
        case 20: r.pending_before=false;break;
        }
        ticks(host,environment,1); running(host,"probe-malformed",environment);
        check(environment.logged("malformed passive evidence rejected"),"corruption "+std::to_string(corruption)+"\n"+environment.all());
        check(environment.fake.sync_probe_starts==1 && environment.fake.sync_probe_polls==1 && !environment.fake.body_submissions,
            "malformed evidence issued body commands or retried admission");
    }
}

void sync_probe_terminal_partial_facts_and_body_release_remain_distinct() {
    namespace s=dingosdk::body_sync_probe;
    for(const auto terminal:{s::Status::expired,s::Status::invalidated}) {
        TestEnvironment environment;Host host(environment,Side::client);
        host.apply({script("probe-terminal",R"(
            local P=reskate.world.physics;local v=vector.create
            local h=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
                capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
            local probe=assert(P.begin_sync_probe(h));local done=false
            reskate.on("tick",function()
                if done then return end
                local r=assert(P.poll_sync_probe(probe))
                assert(r.terminal and (r.status=="expired" or r.status=="invalidated"))
                assert(r.observed_mask==3 and not r.observed_epoch and not r.native_consumed)
                assert(r.records[1].present and r.records[2].present and not r.records[3].present and not r.records[4].present)
                assert(P.release(h));local history=assert(P.poll_sync_probe(probe))
                assert(history.status==r.status and history.terminal and history.observed_mask==3)
                assert(history.armed_epoch.serial==r.armed_epoch.serial and not history.observed_epoch)
                assert(history.records[1].supplied[13]==r.records[1].supplied[13])
                done=true;reskate.log("partial terminal facts retained without live body authority")
            end)
        )",R"("world.physics","world.physics.observe")")});
        running(host,"probe-terminal",environment);environment.fake.complete_sync_probe();
        auto& out=environment.fake.sync_probe.result;out.status=terminal;out.observed_mask=3;out.observed_epoch={};
        out.records[2]={};out.records[3]={};
        ticks(host,environment,1);running(host,"probe-terminal",environment);
        check(environment.logged("partial terminal facts retained without live body authority") &&
            environment.fake.body_release_calls==1 && environment.fake.sync_probe.sequence && !environment.fake.body_submissions,
            "explicit release rewrote terminal diagnostic history or observation issued a body command\n"+environment.all());
    }
    for(const bool release_explicitly:{false,true}) {
        TestEnvironment environment;Host host(environment,Side::client);
        const std::string after=release_explicitly?R"(
            assert(P.release(h));local a=assert(P.poll_sync_probe(probe));local b=assert(P.poll_sync_probe(probe))
            assert(a.status=="invalidated" and a.terminal and a.observed_mask==0 and not a.observed_epoch)
            assert(b.status==a.status and b.armed_epoch.serial==a.armed_epoch.serial)
        )":"";
        host.apply({script("probe-pending",R"(
            local P=reskate.world.physics;local v=vector.create
            local h=assert(P.create({mass=12,inertia=v(2,3,4),position=v(1,2,3),rotation={0,0,0,1},
                capsules={{a=v(0,0,0),b=v(0,1,0),radius=.1}}}))
            local probe=assert(P.begin_sync_probe(h))
        )"+after,R"("world.physics","world.physics.observe")")});
        running(host,"probe-pending",environment);const auto before=environment.fake.sync_probe;host.apply({});
        s::Result history;
        check(environment.fake.body_poll_sync_probe(before.owner,before.handle,before.sequence,history).empty() &&
            history.status==s::Status::invalidated && !history.observed_mask &&
            history.armed_epoch==before.result.armed_epoch && !environment.fake.body_submissions,
            "pending probe was not canceled on explicit release or VM unload");
        check(!environment.fake.body_poll_sync_probe(before.owner+1,before.handle,before.sequence,history).empty(),
            "canceled probe history became another owner's authority");
    }
}

void owned_body_refusal_tokens_keep_return_shapes_and_no_command() {
    TestEnvironment environment;
    auto& game = environment.fake;
    game.test_body_create_refusal = "body_preallocation_unavailable";
    Host host(environment, Side::client);
    host.apply({script("body-refusal-tokens", R"(
        local P, v = reskate.world.physics, vector.create
        local definition = {mass=12, inertia=v(2,3,4), position=v(1,2,3), rotation={0,0,0,1},
            capsules={{a=v(0,0,0), b=v(0,.5,0), radius=.1}}}
        local denied = table.pack(P.create(definition))
        assert(denied.n == 2 and denied[1] == nil and denied[2] == "body_preallocation_unavailable")
        reskate.log("body create refusal preserved")
        local body, sample
        reskate.console.command("body_refusal_setup", "x", function()
            body = assert(P.create(definition))
            sample = assert(P.read(body))
            reskate.log("body refusal setup complete")
        end)
        local function refused(expected)
            local row = table.pack(P.submit(body, sample.epoch, {force=v(1,0,0)}))
            assert(row.n == 2 and row[1] == false and row[2] == expected)
            local receipt = assert(P.receipt(body))
            assert(receipt.sequence == "0" and receipt.outcome == "none" and receipt.requested_serial == "0"
                and receipt.produced_serial == "0" and receipt.force_attempted == false and receipt.torque_attempted == false)
            reskate.log("body submit refusal preserved: " .. expected)
        end
        reskate.console.command("body_clock_refusal", "x", function() refused("body_clock_unavailable") end)
        reskate.console.command("body_epoch_refusal", "x", function() refused("body_epoch_expired") end)
    )", R"("world.physics", "console")")});
    running(host, "body-refusal-tokens", environment);
    check(environment.logged("body create refusal preserved") && game.body_create_calls == 1 && !game.body_creates &&
        game.owned.empty() && !game.body_command_sequence && !game.body_submissions && !game.body_submit_entries,
        "A typed creation refusal returns nil/reason without allocating\n" + environment.all());
    game.test_body_create_refusal.clear();
    check(host.run_console("body_refusal_setup") && environment.logged("body refusal setup complete") &&
        game.body_create_calls == 2 && game.body_creates == 1 && game.owned.size() == 1,
        "The refusal fixture has one valid measured body\n" + environment.all());
    const auto before = game.owned.at(1).mailbox;
    unsigned attempts{};
    for (const auto& trial : {std::pair{"body_clock_refusal", "body_clock_unavailable"},
        std::pair{"body_epoch_refusal", "body_epoch_expired"}}) {
        game.test_body_submit_refusal = trial.second;
        check(host.run_console(trial.first) && environment.logged(std::string("body submit refusal preserved: ") + trial.second),
            "A typed submit refusal keeps false/reason and an empty receipt\n" + environment.all());
        ++attempts;
        const auto& after = game.owned.at(1).mailbox;
        check(game.body_submit_entries == attempts && !game.body_submissions && !game.body_command_sequence &&
            after.head == before.head && after.count == before.count && after.inbox == before.inbox &&
            after.sequence == before.sequence && after.last_submitted == before.last_submitted &&
            after.command.epoch == before.command.epoch && after.pending == before.pending &&
            after.producing == before.producing && after.failed == before.failed,
            "A refused command assigns no sequence and leaves mailbox admission unchanged");
    }
}

void native_body_permission_and_client_boundary_are_enforced() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("no-body-permission", R"(
        local P=reskate.world.physics
        for _,name in {"create","read","submit","receipt","acknowledge","release","probe_batch"} do
            local ok,why=pcall(P[name],{})
            assert(not ok and string.find(why,"world.physics"),name)
        end
    )")});
    running(host, "no-body-permission", environment);
    check(!environment.fake.body_create_calls && !environment.fake.body_submit_entries &&
        !environment.fake.body_creates && !environment.fake.body_submissions, "missing permission reached Game");
    TestEnvironment server_environment; Host server(server_environment, Side::server);
    auto server_plugin = package("server-body", {{manifest_file, manifest(R"("world.physics","world.raycast")", "server")}, {"plugin/main.lua", R"(
        local ok,why=pcall(reskate.world.physics.create,{})
        assert(not ok and string.find(why,"client phase only"))
        ok,why=pcall(reskate.world.physics.probe_batch,{},{},{})
        assert(not ok and string.find(why,"client phase only"))
    )"}});
    server.apply({server_plugin}); running(server, "server-body", server_environment);
    check(!server_environment.fake.body_create_calls, "server reached native body creation");
}

void native_actions_keep_opaque_requests_and_observed_receipts_distinct() {
    using namespace dingosdk::skater_action;
    TestEnvironment environment; Host host(environment, Side::client);
    environment.fake.native_action_requested_ms = 9007199254740997ULL;
    const auto candidate = script("native-actions", R"(
        local S = reskate.skater
        for _,bad in {"get_up", "board\0ignored", "on_foot_extra", 1, {}} do
            assert(not pcall(S.action,bad))
        end
        for _,fn in {S.action_state,S.action_cancel,S.action_acknowledge} do
            assert(not pcall(fn,{}))
        end
        local h = assert(S.action("board"))
        assert(type(h)=="userdata" and getmetatable(h)=="locked")
        local r = assert(S.action_state(h))
        assert(r.status=="pending" and not r.terminal and r.kind=="board")
        assert(r.sequence=="9007199254740995" and r.requested_ms=="9007199254740997")
        assert(r.original_candidate==nil and r.final_candidate==nil and r.committed_state==nil)
        assert(r.ragdoll==nil and r.in_air==nil and r.offered_ms==nil)
        r.status="completed"
        assert(S.action_state(h).status=="pending")
        assert(not S.action_acknowledge(h))
        local selected = false
        reskate.on("tick",function()
            if not h then return end
            local state=assert(S.action_state(h))
            if state.status=="selected" then
                assert(not state.terminal and state.original_candidate==200 and state.final_candidate==200)
                assert(state.committed_state==504 and state.ragdoll==true and state.in_air==nil)
                assert(state.offered_ms=="9007199254740998" and not S.action_cancel(h))
                selected=true
            elseif state.status=="completed" then
                assert(selected and state.terminal and state.committed_state==100)
                assert(state.ragdoll==false and state.in_air==false and state.flag_restored)
                assert(state.observed_ms=="9007199254740999")
                assert(S.action_acknowledge(h))
                assert(S.action_state(h)==nil)
                h=nil
                reskate.log("native action receipt acknowledged")
            end
        end)
    )", R"("skater.control")");
    host.apply({candidate}); running(host, "native-actions", environment);
    check(environment.fake.native_action_requests == 1, "invalid actions reached the backend");
    auto& record = environment.fake.native_actions.begin()->second;
    const auto old_owner = record.owner; const auto old_handle = record.receipt.handle;
    record.receipt.status = dingosdk::skater_action::Status::selected; record.receipt.offered_ms = 9007199254740998ULL;
    record.receipt.original_known = record.receipt.final_known = record.receipt.committed_known = true;
    record.receipt.original_candidate = record.receipt.final_candidate = 200; record.receipt.committed_state = 504;
    record.receipt.ragdoll_known = record.receipt.ragdoll = true;
    ticks(host, environment, 1); running(host, "native-actions", environment);
    check(!environment.logged("native action receipt acknowledged"), "selector proposal was converted to completion by the binding");
    record.receipt.status = dingosdk::skater_action::Status::completed; record.receipt.committed_state = 100;
    record.receipt.observed_ms = 9007199254740999ULL;
    record.receipt.ragdoll = false; record.receipt.in_air_known = true; record.receipt.in_air = false; record.receipt.flag_restored = true;
    ticks(host, environment, 1); running(host, "native-actions", environment);
    check(environment.logged("native action receipt acknowledged") && environment.fake.native_actions.empty(), environment.all());
    host.apply({});
    check(std::find(environment.fake.native_action_releases.begin(), environment.fake.native_action_releases.end(), old_owner) != environment.fake.native_action_releases.end(),
        "VM close did not release its native action instance");
    const auto replacement = script("native-actions", "assert(reskate.skater.action('on_foot'))", R"("skater.control")");
    host.apply({replacement}); running(host, "native-actions", environment);
    const auto new_owner = environment.fake.native_actions.begin()->second.owner;
    check(new_owner != old_owner, "reloaded action owner reused a VM instance");
    Receipt stale;
    check(!environment.fake.native_action_read(new_owner, old_handle, stale), "new VM read a retired action");
    const auto live_handle = environment.fake.native_actions.begin()->second.receipt.handle;
    check(!environment.fake.native_action_cancel(old_owner, live_handle) && !environment.fake.native_action_acknowledge(old_owner, live_handle),
        "previous VM changed another VM's action");
    host.apply({}); check(environment.fake.native_actions.empty(), "VM unload left a pending fake native action");
}

void native_actions_check_permission_side_cancellation_and_rate() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("action-no-permission", R"(
        local S=reskate.skater
        for _,name in {"action","action_state","action_cancel","action_acknowledge"} do
            local ok,why=pcall(S[name],{})
            assert(not ok and why:find("skater.control"),name)
        end
    )")}); running(host, "action-no-permission", environment);
    check(environment.fake.native_action_requests == 0 && environment.fake.native_action_reads == 0 &&
        environment.fake.native_action_cancels == 0 && environment.fake.native_action_acks == 0, "denied actions reached Game");
    host.apply({script("action-cancel-rate", R"(
        local S=reskate.skater
        for i=1,4 do
            local h=assert(S.action(i%2==0 and "board" or "on_foot"))
            assert(S.action_cancel(h))
            local r=assert(S.action_state(h))
            assert(r.status=="cancelled" and r.reason=="cancelled" and r.terminal)
            assert(S.action_acknowledge(h))
        end
        local h,why=S.action("board")
        assert(h==nil and why:find("4 times"))
    )", R"("skater.control")")}); running(host, "action-cancel-rate", environment);
    check(environment.fake.native_action_requests == 4 && environment.fake.native_actions.empty(), "native action rate or acknowledgement failed");
    environment.fake.native_actions_available = false;
    host.apply({script("action-unavailable", "local h,why=reskate.skater.action('board'); assert(h==nil and why=='unavailable')", R"("skater.control")")});
    running(host, "action-unavailable", environment);
    TestEnvironment server_environment; Host server(server_environment, Side::server);
    server.apply({package("server-actions", {{manifest_file, manifest(R"("skater.control")", "server")}, {"plugin/main.lua", R"(
        for _,name in {"action","action_state","action_cancel","action_acknowledge"} do
            local ok,why=pcall(reskate.skater[name],{})
            assert(not ok and why:find("client phase only"),name)
        end
    )"}})}); running(server, "server-actions", server_environment);
    check(server_environment.fake.native_action_requests == 0 && server_environment.fake.native_action_reads == 0 &&
        server_environment.fake.native_action_cancels == 0 && server_environment.fake.native_action_acks == 0, "server reached native actions");
}

void native_action_quarantine_remains_visible_until_safe_acknowledgement() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("action-quarantine", R"(
        local S=reskate.skater
        local h=assert(S.action("on_foot"))
        local saw_quarantine=false
        reskate.on("tick",function()
            if not h then return end
            local r=assert(S.action_state(h))
            if r.status~="rejected" then return end
            assert(r.reason=="request_restore_failed" and r.terminal and not r.flag_restored)
            if r.quarantined then
                assert(not S.action_acknowledge(h) and not S.action_cancel(h))
                saw_quarantine=true
                reskate.log("native action quarantine retained")
            else
                assert(saw_quarantine and S.action_acknowledge(h))
                h=nil
                reskate.log("failed native action acknowledged after quarantine cleared")
            end
        end)
    )", R"("skater.control")")}); running(host, "action-quarantine", environment);
    auto& receipt = environment.fake.native_actions.begin()->second.receipt;
    receipt.status = dingosdk::skater_action::Status::rejected;
    receipt.reason = dingosdk::skater_action::Reason::request_restore_failed;
    receipt.quarantined = true;
    ticks(host, environment, 1); running(host, "action-quarantine", environment);
    check(environment.logged("native action quarantine retained") && !environment.fake.native_actions.empty(), environment.all());
    receipt.quarantined = false;
    ticks(host, environment, 1); running(host, "action-quarantine", environment);
    check(environment.logged("failed native action acknowledged after quarantine cleared") && environment.fake.native_actions.empty(), environment.all());
}

void native_recovery_receipts_separate_pulse_cleanup_and_stability() {
    namespace r = dingosdk::skater_recovery;
    TestEnvironment environment; Host host(environment, Side::client);
    environment.fake.native_recovery_requested_ms = 9007199254740997ULL;
    host.apply({script("native-recovery", R"(
        local S=reskate.skater
        for _,bad in {false,1,"get_up",{}} do assert(not pcall(S.recover,bad)) end
        assert(not pcall(S.recover,nil))
        for _,fn in {S.recovery_state,S.recovery_cancel,S.recovery_acknowledge} do
            assert(not pcall(fn,{}))
            assert(not pcall(fn,"9007199254740995"))
        end
        local equipment=assert(S.action("board"))
        assert(not pcall(S.recovery_state,equipment))
        assert(S.action_cancel(equipment) and S.action_acknowledge(equipment))
        local h=assert(S.recover())
        assert(type(h)=="userdata" and getmetatable(h)=="locked")
        assert(not pcall(S.action_state,h) and not pcall(S.recovery_state,h,nil))
        local initial=assert(S.recovery_state(h))
        assert(initial.sequence=="9007199254740995" and initial.requested_ms=="9007199254740997")
        assert(initial.status=="pending" and initial.kind=="get_up" and not initial.terminal)
        assert(initial.native_true_calls==0 and initial.native_reset_calls==0)
        assert(initial.prior_value==nil and initial.true_readback==nil and initial.committed_state==nil)
        assert(initial.ragdoll==nil and initial.in_air==nil and initial.true_ms==nil and initial.reset_ms==nil)
        initial.status="completed";initial.true_entered=true
        assert(S.recovery_state(h).status=="pending" and not S.recovery_state(h).true_entered)
        assert(not S.recovery_acknowledge(h))
        local entered,reset=false,false
        reskate.on("tick",function()
            if not h then return end
            local v=assert(S.recovery_state(h))
            if v.status=="entered" then
                assert(not v.terminal and v.true_entered and v.true_returned and v.true_readback)
                assert(v.native_true_calls==1 and v.native_reset_calls==0)
                assert(v.true_serial=="9007199254740998" and v.true_ms=="9007199254740999" and v.true_time==10)
                assert(v.reset_pending and v.unresolved and v.reset_ms==nil)
                assert(not S.recovery_cancel(h) and not S.recovery_acknowledge(h))
                entered=true
            elseif v.status=="reset" then
                assert(entered and not v.terminal and v.reset_false and not v.unresolved)
                assert(v.native_true_calls==1 and v.native_reset_calls==1)
                assert(v.reset_serial=="9007199254741000" and v.reset_time==10.125)
                assert(v.committed_state==504 and v.ragdoll==false and v.in_air==false)
                assert(v.standing_observed and not v.stable_observed and v.standing_samples==1)
                assert(v.standing_seconds==0 and v.standing_required_seconds==2)
                assert(not S.recovery_acknowledge(h))
                reset=true
            elseif v.status=="completed" then
                assert(reset and v.terminal and v.stable_observed and v.standing_samples==121 and v.standing_seconds==2)
                assert(v.observed_ms=="9007199254741001" and not v.quarantined)
                assert(S.recovery_acknowledge(h) and S.recovery_state(h)==nil)
                h=nil;reskate.log("native recovery separately observed stable")
            end
        end)
    )", R"("skater.control")")}); running(host, "native-recovery", environment);
    check(environment.fake.native_recovery_requests == 1 && environment.fake.native_actions.empty(), "invalid/forged recovery request reached backend");
    auto& entry = environment.fake.native_recoveries.begin()->second;
    const auto owner = entry.owner; const auto handle = entry.receipt.handle;
    auto& receipt = entry.receipt;
    receipt.status = r::Status::entered; receipt.true_entered = receipt.true_returned = receipt.true_readback_known = receipt.true_readback = true;
    receipt.true_serial = 9007199254740998ULL; receipt.true_ms = 9007199254740999ULL; receipt.true_time = 10;
    receipt.native_true_calls = 1;
    receipt.reset_pending = receipt.unresolved = true;
    ticks(host, environment, 1); running(host, "native-recovery", environment);
    check(!environment.logged("native recovery separately observed stable"), "true delivery became physical recovery");
    receipt.status = r::Status::reset; receipt.reset_pending = receipt.unresolved = false;
    receipt.reset_false = receipt.reset_entered = receipt.reset_returned = receipt.reset_readback_known = true;
    receipt.reset_serial = 9007199254741000ULL; receipt.reset_time = 10.125; receipt.reset_ms = 9007199254741000ULL;
    receipt.native_reset_calls = 1;
    receipt.state = {true, true, false, true, false, 504}; receipt.standing_observed = true; receipt.standing_samples = 1;
    ticks(host, environment, 1); running(host, "native-recovery", environment);
    check(!environment.logged("native recovery separately observed stable"), "single504 false flags became stable recovery");
    receipt.status = r::Status::completed; receipt.stable_observed = true; receipt.standing_samples = 121; receipt.standing_seconds = 2;
    receipt.observed_ms = 9007199254741001ULL;
    ticks(host, environment, 1); running(host, "native-recovery", environment);
    check(environment.logged("native recovery separately observed stable") && environment.fake.native_recoveries.empty(), environment.all());
    host.apply({});
    const auto recovery = std::find(environment.fake.release_order.begin(), environment.fake.release_order.end(), std::pair{owner, std::string("recovery")});
    const auto body = std::find(environment.fake.release_order.begin(), environment.fake.release_order.end(), std::pair{owner, std::string("body")});
    check(recovery != environment.fake.release_order.end() && body != environment.fake.release_order.end() && recovery < body,
        "VM close must revoke recovery before releasing its owned bodies");
    host.apply({script("native-recovery", "assert(reskate.skater.recover())", R"("skater.control")")});
    running(host, "native-recovery", environment);
    const auto& replacement = environment.fake.native_recoveries.begin()->second;
    check(replacement.owner != owner, "recovery reload inherited prior VM authority");
    r::Receipt stale;
    check(!environment.fake.native_recovery_read(replacement.owner, handle, stale), "new VM read an old recovery handle");
    check(!environment.fake.native_recovery_cancel(owner, replacement.receipt.handle) &&
        !environment.fake.native_recovery_acknowledge(owner, replacement.receipt.handle), "old VM changed new recovery");
    host.apply({}); check(environment.fake.native_recoveries.empty(), "pending recovery was not revoked on unload");
}

void native_recovery_enforces_permission_phase_arguments_and_shared_request_rate() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("recovery-denied", R"(
        for _,name in {"recover","recovery_state","recovery_cancel","recovery_acknowledge"} do
            local ok,why=pcall(reskate.skater[name],{})
            assert(not ok and why:find("skater.control"),name)
        end
    )")}); running(host, "recovery-denied", environment);
    check(environment.fake.native_recovery_requests == 0 && environment.fake.native_recovery_reads == 0 &&
        environment.fake.native_recovery_cancels == 0 && environment.fake.native_recovery_acks == 0, "permission denial reached recovery backend");
    host.apply({script("recovery-rate", R"(
        local S=reskate.skater
        for i=1,4 do
            if i%2==0 then
                local h=assert(S.action("board"));assert(S.action_cancel(h) and S.action_acknowledge(h))
            else
                local h=assert(S.recover())
                for j=1,6 do assert(S.recovery_state(h).status=="pending") end
                assert(S.recovery_cancel(h))
                local r=assert(S.recovery_state(h));assert(r.status=="cancelled" and r.terminal and not r.true_entered)
                assert(S.recovery_acknowledge(h))
            end
        end
        local h,why=S.recover();assert(h==nil and why:find("4 times"))
        h,why=S.action("board");assert(h==nil and why:find("4 times"))
    )", R"("skater.control")")}); running(host, "recovery-rate", environment);
    check(environment.fake.native_recovery_requests == 2 && environment.fake.native_action_requests == 2 &&
        environment.fake.native_recoveries.empty(), "equipment/recovery request budget was not shared or polls consumed it");
    environment.fake.native_recovery_available = false;
    host.apply({script("recovery-unavailable", "local h,why=reskate.skater.recover();assert(h==nil and why=='unavailable')", R"("skater.control")")});
    running(host, "recovery-unavailable", environment);
    TestEnvironment server_environment; Host server(server_environment, Side::server);
    server.apply({package("recovery-server", {{manifest_file, manifest(R"("skater.control")", "server")}, {"plugin/main.lua", R"(
        for _,name in {"recover","recovery_state","recovery_cancel","recovery_acknowledge"} do
            local ok,why=pcall(reskate.skater[name],{})
            assert(not ok and why:find("client phase only"),name)
        end
    )"}})}); running(server, "recovery-server", server_environment);
    check(server_environment.fake.native_recovery_requests == 0 && server_environment.fake.native_recovery_reads == 0 &&
        server_environment.fake.native_recovery_cancels == 0 && server_environment.fake.native_recovery_acks == 0, "server reached native recovery");
}

void input_pulse_api_keeps_report_receipts_opaque_and_owner_bound() {
    namespace p = game_input_pulse;
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("input-pulse", R"(
        local P=reskate.input
        assert(not pcall(P.pulse) and not pcall(P.pulse,0) and not pcall(P.pulse,0,"y",nil))
        for _,user in {-1,4,.5,math.huge,0/0,"0",false,{}} do assert(not pcall(P.pulse,user,"y")) end
        for _,button in {0,3,0x400,0x800,.5,math.huge,0/0,false,{},"0x8000","Y","y\0junk","board"} do
            assert(not pcall(P.pulse,2,button))
        end
        local h=assert(P.pulse(2,"y"))
        assert(type(h)=="userdata" and getmetatable(h)=="locked")
        for _,fn in {P.pulse_state,P.pulse_cancel,P.pulse_acknowledge} do
            assert(not pcall(fn,{}) and not pcall(fn,"9007199254740995") and not pcall(fn,h,nil))
        end
        local r=assert(P.pulse_state(h))
        assert(r.sequence=="9007199254740995" and r.requested_ms=="9007199254740997" and r.expires_ms=="9007199254741997")
        assert(r.observed_ms==r.requested_ms and r.source_epoch=="9007199254741009")
        assert(r.user==2 and r.button==0x8000 and r.status=="queued" and not r.terminal)
        assert(r.first_rejection_mask==0 and r.first_rejection_stage=="none")
        assert(r.warmup_deferrals=="0")
        assert(not r.first_actor_observation_known and not r.first_actor_owner_present and not r.first_actor_call_active)
        assert(not r.first_actor_inspect_attempted and not r.first_actor_inspect_succeeded and not r.first_actor_equal)
        assert(not r.first_actor_clock_attempted and not r.first_actor_clock_known)
        assert(r.first_actor_enter_phase=="not_attempted" and r.first_actor_enter_reason=="none")
        assert(r.first_actor_inspect_phase=="not_attempted" and r.first_actor_inspect_reason=="none")
        assert(r.transport=="xinput" and r.source_identity=="observed_stream" and r.publication_scope=="process_outer_xinput_buffer")
        assert(r.consumption=="unobserved" and r.semantic_completion=="unobserved" and r.native_consumed==nil)
        assert(r.address==nil and r.actor_ticket==nil and r.device_guid==nil and r.original_result==nil)
        assert(not P.pulse_acknowledge(h))
        reskate.on("tick",function()
            if not h then return end
            local v,why=P.pulse_state(h)
            if not v then assert(why:find("invalid observations"));reskate.log("pulse malformed rejected");return end
            if string.sub(v.first_actor_inspect_phase,1,17)=="controls_profile_" then
                reskate.log("pulse profile phase "..v.first_actor_inspect_phase)
            end
            if v.status=="released" then
                assert(v.terminal and v.consumption=="unobserved" and v.semantic_completion=="unobserved")
                assert(v.press_candidates=="9007199254741012" and v.press_publications=="9007199254741011")
                assert(v.neutral_publications=="1" and v.contentions=="9007199254741013")
                assert(v.warmup_deferrals=="9007199254741014")
                assert(v.original_result_known and v.original_result==1167)
                assert(v.first_rejection_mask==33024 and v.first_rejection_stage=="core_plan")
                assert(v.first_actor_observation_known and v.first_actor_owner_present and v.first_actor_call_active)
                assert(v.first_actor_inspect_attempted and v.first_actor_inspect_succeeded and v.first_actor_equal)
                assert(v.first_actor_clock_attempted and not v.first_actor_clock_known)
                assert(v.first_actor_enter_phase=="qualified" and v.first_actor_enter_reason=="none")
                assert(v.first_actor_inspect_phase=="qualified" and v.first_actor_inspect_reason=="none")
                if v.report_debt or not v.claim_released or v.quarantined then
                    assert(not P.pulse_acknowledge(h));reskate.log("pulse debt retained")
                else
                    assert(P.pulse_acknowledge(h) and P.pulse_state(h)==nil)
                    h=nil;reskate.log("pulse record acknowledged")
                end
            end
        end)
    )", R"("input.control")")}); running(host,"input-pulse",environment);
    check(environment.fake.input_pulse_requests==1 && environment.fake.input_pulses.size()==1,
        "invalid input-pulse arguments reached backend or consumed its start budget");
    auto& row=environment.fake.input_pulses.begin()->second;
    const auto owner=row.owner; const auto handle=row.receipt.handle;
    auto& receipt=row.receipt; const auto valid=receipt;
    const auto malformed=[&](const char* why) {
        environment.lines.clear(); environment.logs.clear(); ticks(host,environment,1); running(host,"input-pulse",environment);
        check(environment.logged("pulse malformed rejected"),why); receipt=valid;
    };
    for (const auto phase : {dingosdk::actor_observation::Phase::controls_profile_lock,
        dingosdk::actor_observation::Phase::controls_profile_inactive,
        dingosdk::actor_observation::Phase::controls_profile_manager_read,
        dingosdk::actor_observation::Phase::controls_profile_manager_null,
        dingosdk::actor_observation::Phase::controls_profile_phase_read,
        dingosdk::actor_observation::Phase::controls_profile_exception}) {
        auto& observation=receipt.first_actor_observation;
        observation.known=observation.owner_present=observation.call_active=observation.inspect_attempted=true;
        observation.enter={dingosdk::actor_observation::Phase::qualified,dingosdk::skater_action::Reason::none};
        observation.inspect={phase,dingosdk::skater_action::Reason::unavailable};
        environment.lines.clear(); environment.logs.clear(); ticks(host,environment,1); running(host,"input-pulse",environment);
        check(environment.logged(std::string("pulse profile phase ")+dingosdk::actor_observation::phase_name(phase)),
            "precise profile refusal did not survive actual Host serialization");
        receipt=valid;
    }
    receipt.status=static_cast<p::Status>(999); malformed("unknown pulse status was serialized");
    receipt.reason=static_cast<p::Reason>(999); malformed("unknown pulse reason was serialized");
    receipt.first_rejection_stage=static_cast<p::RejectionStage>(999); malformed("unknown pulse rejection stage was serialized");
    receipt.first_rejection_mask=1u<<31; malformed("unknown pulse failed-check bits were serialized");
    receipt.first_actor_observation.enter.phase=static_cast<dingosdk::actor_observation::Phase>(255);
    malformed("unknown actor entry phase was serialized");
    receipt.first_actor_observation.inspect.phase=static_cast<dingosdk::actor_observation::Phase>(255);
    malformed("unknown actor inspection phase was serialized");
    receipt.first_actor_observation.enter.reason=static_cast<dingosdk::skater_action::Reason>(255);
    malformed("unknown actor entry reason was serialized");
    receipt.first_actor_observation.inspect.reason=static_cast<dingosdk::skater_action::Reason>(255);
    malformed("unknown actor inspection reason was serialized");
    ++receipt.handle.sequence; malformed("pulse receipt changed its opaque sequence");
    receipt.user=1; malformed("pulse receipt changed the requested slot");
    receipt.button=0x1000; malformed("pulse receipt changed the requested button");
    --receipt.expires_ms; malformed("pulse receipt changed its bounded lifetime");
    --receipt.observed_ms; malformed("pulse receipt predates admission");
    receipt.press_publications=1; malformed("pulse receipt confirmed more presses than candidates");
    receipt.status=p::Status::released; receipt.report_debt=receipt.quarantined=true;
    receipt.press_candidates=9007199254741012ULL; receipt.press_publications=9007199254741011ULL;
    receipt.warmup_deferrals=9007199254741014ULL;
    receipt.neutral_publications=1; receipt.contentions=9007199254741013ULL;
    receipt.original_result_known=true; receipt.original_result=1167;
    receipt.first_rejection_mask=dingosdk::input_pulse::failure_bit(dingosdk::input_pulse::FailedCheck::native_clock) |
        dingosdk::input_pulse::failure_bit(dingosdk::input_pulse::FailedCheck::poll_gap);
    receipt.first_rejection_stage=p::RejectionStage::core_plan;
    auto& first_actor=receipt.first_actor_observation;
    first_actor.known=first_actor.owner_present=first_actor.call_active=first_actor.inspect_attempted=true;
    first_actor.inspect_succeeded=first_actor.actor_equal=first_actor.clock_attempted=true;
    first_actor.enter=first_actor.inspect={dingosdk::actor_observation::Phase::qualified, dingosdk::skater_action::Reason::none};
    ticks(host,environment,1); running(host,"input-pulse",environment);
    check(environment.logged("pulse debt retained") && environment.fake.input_pulses.size()==1,
        "terminal pulse status alone discarded unresolved publication duty");
    receipt.report_debt=receipt.quarantined=false; receipt.claim_released=true;
    ticks(host,environment,1); running(host,"input-pulse",environment);
    check(environment.logged("pulse record acknowledged") && environment.fake.input_pulses.empty(),
        "resolved pulse could not be acknowledged");
    host.apply({});
    host.apply({script("input-pulse","assert(reskate.input.pulse(0,0x1000))",R"("input.control")")});
    running(host,"input-pulse",environment);
    const auto replacement=environment.fake.input_pulses.begin()->second;
    check(replacement.owner!=owner && replacement.receipt.user==0 && replacement.receipt.button==0x1000,
        "input pulse reload reused VM identity or numeric bit lost its value");
    p::Receipt stale;
    check(!environment.fake.input_pulse_read(replacement.owner,handle,stale) &&
        !environment.fake.input_pulse_cancel(owner,replacement.receipt.handle) &&
        !environment.fake.input_pulse_acknowledge(owner,replacement.receipt.handle), "pulse crossed VM owner boundary");
}

void input_pulse_api_enforces_permission_client_phase_and_shared_budget() {
    TestEnvironment environment; Host host(environment,Side::client);
    host.apply({script("input-pulse-denied",R"(
        for _,name in {"pulse","pulse_state","pulse_cancel","pulse_acknowledge"} do
            local ok,why=pcall(reskate.input[name],{})
            assert(not ok and why:find("input.control"),name)
        end
    )",R"("input","skater.control")")}); running(host,"input-pulse-denied",environment);
    check(!environment.fake.input_pulse_requests && !environment.fake.input_pulse_reads &&
        !environment.fake.input_pulse_cancels && !environment.fake.input_pulse_acks,"permission denial reached pulse backend");
    host.apply({script("input-pulse-budget",R"(
        local P=reskate.input
        for i=1,4 do
            local h=assert(P.pulse(0,"a"))
            for j=1,5 do assert(P.pulse_state(h).status=="queued") end
            assert(P.pulse_cancel(h) and P.pulse_acknowledge(h))
        end
        local h,why=P.pulse(0,"a");assert(h==nil and why:find("4 times"))
    )",R"("input.control")")}); running(host,"input-pulse-budget",environment);
    check(environment.fake.input_pulse_requests==4 && environment.fake.input_pulses.empty(),
        "pulse state polls consumed start budget or fifth start reached backend");
    host.apply({script("input-pulse-shared-budget",R"(
        local h=assert(reskate.skater.recover())
        assert(reskate.skater.recovery_cancel(h) and reskate.skater.recovery_acknowledge(h))
        for i=1,3 do
            local p=assert(reskate.input.pulse(0,"b"))
            assert(reskate.input.pulse_cancel(p) and reskate.input.pulse_acknowledge(p))
        end
        local p,why=reskate.input.pulse(0,"a");assert(p==nil and why:find("4 times"))
    )",R"("input.control","skater.control")")}); running(host,"input-pulse-shared-budget",environment);
    check(environment.fake.input_pulse_requests==7 && environment.fake.native_recovery_requests==1,
        "report pulse bypassed shared VM control-start budget");

    TestEnvironment refused; refused.fake.input_pulse_available=false; Host unsupported(refused,Side::client);
    unsupported.apply({script("input-pulse-unsupported",R"(
        local h,why=reskate.input.pulse(0,"a");assert(h==nil and why=="unsupported_transport")
    )",R"("input.control")")}); running(unsupported,"input-pulse-unsupported",refused);
    check(refused.fake.input_pulse_requests==1 && refused.fake.input_pulses.empty() &&
        refused.fake.native_actions.empty() && refused.fake.native_recoveries.empty(), "unsupported pulse transport used a different actuator");

    TestEnvironment server_environment; Host server(server_environment,Side::server);
    server.apply({package("input-pulse-server",{{manifest_file,manifest(R"("input.control")","server")},{"plugin/main.lua",R"(
        for _,name in {"pulse","pulse_state","pulse_cancel","pulse_acknowledge"} do
            local ok,why=pcall(reskate.input[name],{})
            assert(not ok and why:find("client phase only"),name)
        end
    )"}})}); running(server,"input-pulse-server",server_environment);
    check(!server_environment.fake.input_pulse_requests && !server_environment.fake.input_pulse_reads &&
        !server_environment.fake.input_pulse_cancels && !server_environment.fake.input_pulse_acks,"server reached pulse backend");
}

void input_pulse_unload_retains_debt_before_other_actor_cleanup() {
    TestEnvironment environment; Host host(environment,Side::client);
    host.apply({script("input-pulse-orphan","assert(reskate.input.pulse(0,0x1000))",R"("input.control")")});
    running(host,"input-pulse-orphan",environment);
    auto& row=environment.fake.input_pulses.begin()->second;
    const auto owner=row.owner; const auto handle=row.receipt.handle;
    row.receipt.report_debt=true; row.receipt.status=game_input_pulse::Status::pressing;
    environment.fake.release_order.clear(); host.apply({});
    check(environment.fake.input_pulses.size()==1 && row.receipt.report_debt && row.receipt.orphaned &&
        row.receipt.quarantined && !row.receipt.claim_released,"VM unload discarded unresolved report duty");
    check(!environment.fake.release_order.empty() && environment.fake.release_order.front()==std::pair{owner,std::string("input_pulse")},
        "pulse unload did not precede other actor/body cleanup");
    environment.fake.input_pulse_available=false; environment.fake.input_pulse_refusal=game_input_pulse::Reason::busy;
    host.apply({script("input-pulse-orphan",R"(
        local h,why=reskate.input.pulse(0,"a");assert(h==nil and why=="busy")
    )",R"("input.control")")}); running(host,"input-pulse-orphan",environment);
    const auto fresh_owner=environment.fake.last_input_pulse_owner;
    game_input_pulse::Receipt denied;
    check(fresh_owner!=owner && !environment.fake.input_pulse_read(fresh_owner,handle,denied) &&
        !environment.fake.input_pulse_cancel(fresh_owner,handle) && !environment.fake.input_pulse_acknowledge(fresh_owner,handle),
        "reload acquired an orphaned VM's pulse authority");
}

// Real Host/Luau boundary over the portable observation broker. Source, guards,
// and clocks below are constructed trusted facts, never live controller evidence.
void input_lease_api_observes_only_qualified_owner_scoped_streams() {
    namespace lease = dingosdk::input_lease;
    struct LeaseGame final : Game {
        lease::Broker broker{9007199254740995ULL};
        lease::Guard guard{9007199254740997ULL, 9007199254741011ULL, true, true, true, true, true};
        lease::Source source{2, 4294967295u, 9007199254741009ULL, 9007199254741001ULL,
            9007199254740997ULL, 9007199254741011ULL,
            {0xf3ff, 1, 255, -32768, 32767, -1, 1}, true, true};
        unsigned requests{}, reads{}, renewals{}, releases{}, states{}, acknowledgements{}, explicit_pulse_requests{};
        std::uint64_t owner{}, last_owner{};
        lease::Handle handle{};
        bool pulse_busy{}, zero_request_handle{}, refuse{};
        lease::Reason refusal{lease::Reason::unavailable};
        std::function<void(lease::Snapshot&)> alter_sample;
        std::function<void(lease::Receipt&)> alter_receipt;
        std::vector<std::pair<std::uint64_t, std::string>> cleanup;
        unsigned calls() const { return requests + reads + renewals + releases + states + acknowledgements; }
        bool denied(lease::Reason& reason) const {
            if (!refuse) return false;
            reason = refusal; return true;
        }
        bool input_lease_request(std::uint64_t who, std::uint32_t user, lease::Handle& out, lease::Reason& reason) override {
            ++requests; last_owner = who;
            if (denied(reason)) return false;
            if (!broker.request(who, user, source, guard, pulse_busy, out, reason)) return false;
            owner = who; handle = out;
            if (zero_request_handle) out = {};
            return true;
        }
        bool input_lease_read(std::uint64_t who, lease::Handle value, lease::Snapshot& out, lease::Reason& reason) override {
            ++reads;
            if (denied(reason) || !broker.read(who, value, guard, out, reason)) return false;
            if (alter_sample) alter_sample(out);
            return true;
        }
        bool input_lease_renew(std::uint64_t who, lease::Handle value, const lease::Snapshot& epoch, lease::Reason& reason) override {
            ++renewals;
            return !denied(reason) && broker.renew(who, value, epoch, guard, reason);
        }
        bool input_lease_release(std::uint64_t who, lease::Handle value, lease::Reason& reason) override {
            ++releases;
            if (denied(reason)) return false;
            const bool ok = broker.release(who, value);
            reason = ok ? lease::Reason::none : lease::Reason::unavailable;
            return ok;
        }
        bool input_lease_state(std::uint64_t who, lease::Handle value, lease::Receipt& out, lease::Reason& reason) override {
            ++states;
            if (denied(reason)) return false;
            broker.tick(guard);
            const bool ok = broker.state(who, value, out);
            reason = ok ? lease::Reason::none : lease::Reason::unavailable;
            if (ok && alter_receipt) alter_receipt(out);
            return ok;
        }
        bool input_lease_acknowledge(std::uint64_t who, lease::Handle value, lease::Reason& reason) override {
            ++acknowledgements;
            if (denied(reason)) return false;
            const bool ok = broker.acknowledge(who, value);
            reason = ok ? lease::Reason::none : lease::Reason::unavailable;
            return ok;
        }
        void input_lease_release_all(std::uint64_t who) override {
            cleanup.emplace_back(who, "lease"); broker.release_all(who);
        }
        void input_pulse_release_all(std::uint64_t who) override { cleanup.emplace_back(who, "pulse"); }
        void input_trace_release_all(std::uint64_t who) override { cleanup.emplace_back(who, "trace"); }
        void native_recovery_release_all(std::uint64_t who) override { cleanup.emplace_back(who, "recovery"); }
        void native_action_release_all(std::uint64_t who) override { cleanup.emplace_back(who, "action"); }
        void body_release_all(std::uint64_t who) override { cleanup.emplace_back(who, "body"); }
        bool input_pulse_request(std::uint64_t, std::uint32_t, std::uint16_t,
            game_input_pulse::Handle&, game_input_pulse::Reason& reason) override {
            ++explicit_pulse_requests; reason = game_input_pulse::Reason::unavailable; return false;
        }
        void observe(lease::Handle cookie) {
            ++guard.now_ms; source.observed_ms = guard.now_ms; ++source.observation_serial;
            broker.observe(cookie, source, guard);
        }
        void observe() { observe(broker.active()); }
    };
    struct LeaseEnvironment final : Environment {
        LeaseGame fake;
        double now{1000};
        std::vector<std::string> logs;
        void log(LogLevel, std::string_view text) override { logs.emplace_back(text); }
        void console(std::string_view) override {}
        double now_ms() override { return now; }
        std::filesystem::path storage_root() override { return scratch / "lease-storage"; }
        bool builtin_command(std::string_view) override { return false; }
        Game& game() override { return fake; }
        bool logged(std::string_view part) const {
            return std::any_of(logs.begin(), logs.end(), [&](const auto& line) { return line.find(part) != std::string::npos; });
        }
        std::string all() const { std::string result; for (const auto& line : logs) result += line + "\n"; return result; }
    };
    unsigned scenarios{};
    const auto running_lease = [&](const Host& host, std::string_view id, const LeaseEnvironment& environment) {
        const auto status = status_of(host, id);
        check(status.state == "running", std::string(id) + ": " + status.state + ": " + status.reason + "\n" + environment.all());
    };
    const auto tick = [&](Host& host, LeaseEnvironment& environment) {
        environment.now += 16; host.tick(16);
    };
    const auto main_script = [&](const std::string& id, const std::string& main) {
        return script(id, main, R"("input.lease")");
    };
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::client);
        // lease_read is the only route to sample.neutral, so the rest fact is behind input.lease too.
        host.apply({script("lease-denied", R"(
            for _,name in {"lease","lease_read","lease_renew","lease_release","lease_state","lease_acknowledge"} do
                local ok,why=pcall(reskate.input[name],{}, {}, {})
                assert(not ok and why:find('input.lease'),name)
            end
            reskate.log('all six permission first')
        )", R"("input","input.control","skater.control")")});
        running_lease(host, "lease-denied", e);
        check(e.logged("all six permission first") && !e.fake.calls() && !e.fake.explicit_pulse_requests,
            "all six source lease calls require their permission before parsing or backend work");
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::server);
        host.apply({package("lease-server", {{manifest_file, manifest(R"("input.lease")", "server")}, {"plugin/main.lua", R"(
            for _,name in {"lease","lease_read","lease_renew","lease_release","lease_state","lease_acknowledge"} do
                local ok,why=pcall(reskate.input[name],{}, {}, {})
                assert(not ok and why:find('client phase only'),name)
            end
        )"}})});
        running_lease(host, "lease-server", e);
        check(!e.fake.calls(), "server lease calls reached the observation backend");
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::client);
        host.apply({main_script("lease-arguments", R"(
            local P=reskate.input
            assert(not pcall(P.lease) and not pcall(P.lease,2,nil))
            for _,bad in {-1,4,.5,math.huge,0/0,'2',false,{}} do assert(not pcall(P.lease,bad)) end
            local h=assert(P.lease(2))
            assert(typeof(h)=='userdata' and getmetatable(h)=='locked')
            assert(not pcall(function() h.sequence='1' end))
            for _,fn in {P.lease_read,P.lease_release,P.lease_state,P.lease_acknowledge} do
                assert(not pcall(fn) and not pcall(fn,h,nil))
                for _,bad in {{},false,'9007199254740995',2} do assert(not pcall(fn,bad)) end
            end
            assert(not pcall(P.lease_renew,h) and not pcall(P.lease_renew,h,{},nil))
            for _,bad in {{},false,'epoch',h} do assert(not pcall(P.lease_renew,h,bad)) end
            reskate.log('arguments refused before backend')
        )")});
        running_lease(host, "lease-arguments", e);
        check(e.logged("arguments refused before backend") && e.fake.requests == 1 && e.fake.calls() == 1,
            "malformed source slots/handles/epoch/arity reached backend or consumed admission budget");
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::client);
        host.apply({main_script("lease-stream", R"(
            local P=reskate.input
            local h=assert(P.lease(2)); local stage=0
            local r=assert(P.lease_state(h))
            assert(r.status=='warming' and r.observed_ms=='0' and r.last_observation=='0')
            assert(not r.terminal and not r.source_released and not P.lease_read(h))
            assert(not P.lease_acknowledge(h))
            reskate.on('tick',function()
                if stage==0 then
                    assert(P.lease_read(h)==nil); stage=1; reskate.log('pre-cookie unavailable'); return
                elseif stage==1 then
                    local s=assert(P.lease_read(h))
                    assert(typeof(s.epoch)=='userdata' and getmetatable(s.epoch)=='locked')
                    assert(s.sequence=='9007199254740995' and s.source_epoch=='9007199254741009')
                    assert(s.context_generation=='9007199254741011' and s.observation_serial=='9007199254741003')
                    assert(s.observed_ms=='9007199254740999' and s.user==2 and s.packet==4294967295)
                    assert(s.transport=='xinput' and s.source_identity=='observed_stream')
                    assert(s.physical_device_identity=='unobserved' and s.mode=='observe' and not s.capturing and not s.report_debt)
                    local p=s.pad
                    assert(p.left_x==-1 and p.left_y==1 and p.right_x==-1/32768 and p.right_y==1/32767)
                    assert(p.left_trigger==1/255 and p.right_trigger==1 and p.playstation==false)
                    assert(s.neutral==false,'full deflection and held buttons are not at rest')
                    local n=0; for name,value in p.buttons do assert(type(value)=='boolean' and value,name); n+=1 end
                    assert(n==14 and p.buttons.y and p.buttons.start and p.buttons.left_stick)
                    local opaque=s.epoch
                    s.sequence='1'; s.source_epoch='1'; s.observation_serial='1'; s.pad.left_x=0
                    assert(P.lease_renew(h,opaque))
                    local ok,why=P.lease_renew(h,opaque); assert(not ok and why=='stale_epoch')
                    assert(not pcall(P.lease_renew,h,s))
                    local r=assert(P.lease_state(h)); assert(r.status=='active' and r.renewals=='1')
                    assert(not r.capturing and not r.report_debt and not r.terminal and not r.orphaned)
                    assert(P.lease_release(h))
                    r=assert(P.lease_state(h)); assert(r.status=='released' and r.terminal and r.source_released)
                    assert(not r.report_debt and not r.capturing and P.lease_read(h)==nil)
                    assert(P.lease_acknowledge(h) and P.lease_state(h)==nil)
                    stage=2; reskate.log('qualified stream released')
                end
            end)
        )")});
        running_lease(host, "lease-stream", e);
        e.fake.observe({}); tick(host,e); running_lease(host,"lease-stream",e);
        check(e.logged("pre-cookie unavailable"), "a report begun before admission became readable");
        const auto pad_before = e.fake.source.pad;
        e.fake.observe(); tick(host,e); running_lease(host,"lease-stream",e);
        check(e.logged("qualified stream released") && e.fake.renewals == 2 && e.fake.source.pad == pad_before &&
            e.fake.source.packet == 4294967295u && !e.fake.explicit_pulse_requests && !e.fake.broker.active().sequence,
            "qualified held-pad observation failed, rewrote a report or requested an actuator");
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::client);
        host.apply({main_script("lease-neutral", R"(
            local P=reskate.input
            local h=assert(P.lease(2)); local last
            reskate.on('tick',function()
                local s=P.lease_read(h)
                if s and s.observation_serial~=last then
                    last=s.observation_serial
                    assert(type(s.neutral)=='boolean' and s.pad.neutral==nil)
                    reskate.log(s.neutral and 'sample neutral' or 'sample active')
                end
            end)
        )")});
        running_lease(host, "lease-neutral", e);
        // A pad resting in the hands, then one control at a time just past XInput's rest thresholds.
        struct Sample { lease::Pad pad; bool neutral; };
        const Sample samples[] = {
            {{0, 30, 12, 7000, -3000, -8000, 2000}, true}, {{0, 0, 0, 5550, 5550, 0, 8689}, true},
            {{0, 0, 0, 6000, 6000, 0, 0}, false}, {{0, 0, 0, 0, 0, 0, 8690}, false},
            {{0, 0, 31, 0, 0, 0, 0}, false}, {{0x0020, 0, 0, 0, 0, 0, 0}, false}, {{}, true}};
        for (const auto& sample : samples) {
            e.fake.source.pad = sample.pad; e.logs.clear();
            e.fake.observe(); tick(host, e); running_lease(host, "lease-neutral", e);
            check(e.logged(sample.neutral ? "sample neutral" : "sample active") &&
                !e.logged(sample.neutral ? "sample active" : "sample neutral"),
                "lease_read's neutral fact disagrees with the SDK's XInput rest thresholds");
        }
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::client);
        host.apply({main_script("lease-wrong-epoch", R"(
            local P=reskate.input; local h=assert(P.lease(2)); local stage=0; local first
            reskate.on('tick',function()
                if stage==0 then
                    first=assert(P.lease_read(h)).epoch
                    assert(P.lease_release(h) and P.lease_acknowledge(h))
                    h=assert(P.lease(2)); stage=1
                    local ok,why=pcall(P.lease_renew,h,first)
                    assert(not ok and why:find('another lease'))
                    reskate.log('wrong lease epoch blocked')
                end
            end)
        )")});
        running_lease(host,"lease-wrong-epoch",e);
        e.fake.observe(); tick(host,e); running_lease(host,"lease-wrong-epoch",e);
        check(e.logged("wrong lease epoch blocked") && !e.fake.renewals && e.fake.requests == 2,
            "another lease's opaque epoch reached renewal backend");
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::client);
        host.apply({main_script("lease-budget", R"(
            local P=reskate.input
            for i=1,4 do
                local h=assert(P.lease(2))
                for j=1,5 do assert(P.lease_state(h).status=='warming') end
                assert(P.lease_release(h) and P.lease_acknowledge(h))
            end
            local h,why=P.lease(2); assert(h==nil and why:find('4 times'))
            reskate.log('four admissions')
        )")});
        running_lease(host,"lease-budget",e);
        check(e.logged("four admissions") && e.fake.requests == 4 && e.fake.states == 20,
            "lease state polling consumed control budget or a fifth admission reached backend");
        host.apply({script("lease-shared-budget", R"(
            local P=reskate.input
            assert(P.pulse(2,'a')==nil)
            for i=1,3 do local h=assert(P.lease(2)); assert(P.lease_release(h) and P.lease_acknowledge(h)) end
            local h,why=P.lease(2); assert(h==nil and why:find('4 times'))
        )", R"("input.lease","input.control")")});
        running_lease(host,"lease-shared-budget",e);
        check(e.fake.requests == 7 && e.fake.explicit_pulse_requests == 1,
            "observation leases bypassed the existing shared four-per-second control request budget");
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::client);
        host.apply({main_script("lease-malformed-sample", R"(
            local P=reskate.input; local h=assert(P.lease(2))
            reskate.on('tick',function()
                local s,why=P.lease_read(h)
                assert(s==nil and why:find('invalid observations'))
                reskate.log('malformed sample refused')
            end)
        )")});
        running_lease(host,"lease-malformed-sample",e); e.fake.observe();
        const std::vector<std::function<void(lease::Snapshot&)>> malformed{
            [](auto& s) { ++s.handle.sequence; }, [](auto& s) { s.user=1; }, [](auto& s) { s.user=4; },
            [](auto& s) { s.source_epoch=0; }, [](auto& s) { s.observation_serial=0; },
            [](auto& s) { s.context_generation=0; }, [](auto& s) { s.observed_ms=0; },
            [](auto& s) { s.observed_ms=std::numeric_limits<std::uint64_t>::max(); }
        };
        for (const auto& alter : malformed) {
            ++scenarios; e.logs.clear(); e.fake.alter_sample=alter; tick(host,e); running_lease(host,"lease-malformed-sample",e);
            check(e.logged("malformed sample refused"), "malformed backend sample became an epoch authority");
        }
        check(!e.fake.renewals, "malformed backend samples were allowed to renew");
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e, Side::client);
        host.apply({main_script("lease-malformed-receipt", R"(
            local P=reskate.input; local h=assert(P.lease(2))
            reskate.on('tick',function()
                local r,why=P.lease_state(h)
                assert(r==nil and why:find('invalid observations'))
                reskate.log('malformed receipt refused')
            end)
        )")});
        running_lease(host,"lease-malformed-receipt",e); e.fake.observe();
        const std::vector<std::function<void(lease::Receipt&)>> malformed{
            [](auto& r) { ++r.handle.sequence; }, [](auto& r) { r.user=1; }, [](auto& r) { r.user=4; },
            [](auto& r) { r.status=static_cast<lease::Status>(999); }, [](auto& r) { r.reason=static_cast<lease::Reason>(999); },
            [](auto& r) { r.source_epoch=0; }, [](auto& r) { r.context_generation=0; },
            [](auto& r) { r.requested_ms=0; }, [](auto& r) { r.requested_ms=std::numeric_limits<std::uint64_t>::max(); },
            [](auto& r) { r.expires_ms=r.requested_ms; }, [](auto& r) { r.observed_ms=r.requested_ms-1; },
            [](auto& r) { r.last_observation=0; }, [](auto& r) { r.observed_ms=r.expires_ms; },
            [](auto& r) { r.source_released=true; }, [](auto& r) { r.status=lease::Status::released; },
            [](auto& r) { r.status=lease::Status::warming; r.last_observation=0; }
        };
        for (const auto& alter : malformed) {
            ++scenarios; e.logs.clear(); e.fake.alter_receipt=alter; tick(host,e); running_lease(host,"lease-malformed-receipt",e);
            check(e.logged("malformed receipt refused"), "malformed backend receipt became a public observation");
        }
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e,Side::client);
        host.apply({main_script("lease-backend-refusal", R"(
            local P=reskate.input; local h=assert(P.lease(2)); local epoch; local stage=0
            reskate.on('tick',function()
                if stage==0 then epoch=assert(P.lease_read(h)).epoch; stage=1; return end
                local value,why=P.lease_read(h); assert(value==nil and why=='interference')
                value,why=P.lease_state(h); assert(value==nil and why=='interference')
                value,why=P.lease_renew(h,epoch); assert(value==false and why=='interference')
                value,why=P.lease_release(h); assert(value==false and why=='interference')
                value,why=P.lease_acknowledge(h); assert(value==false and why=='interference')
                value,why=P.lease(2); assert(value==nil and why=='interference')
                reskate.log('all six precise backend refusals')
            end)
        )")});
        running_lease(host,"lease-backend-refusal",e); e.fake.observe(); tick(host,e);
        running_lease(host,"lease-backend-refusal",e);
        e.fake.refuse=true; e.fake.refusal=lease::Reason::interference;
        tick(host,e); running_lease(host,"lease-backend-refusal",e);
        check(e.logged("all six precise backend refusals") && e.fake.requests==2 && e.fake.reads==2 &&
            e.fake.states==1 && e.fake.renewals==1 && e.fake.releases==1 && e.fake.acknowledgements==1,
            "a backend refusal was dropped, retried or converted to an observation/action");
    }
    {
        ++scenarios;
        LeaseEnvironment e; e.fake.zero_request_handle=true; Host host(e,Side::client);
        host.apply({main_script("lease-zero-handle", R"(
            local h,why=reskate.input.lease(2)
            assert(h==nil and why=='input lease handle unavailable')
        )")});
        running_lease(host,"lease-zero-handle",e);
        const auto old_owner=e.fake.owner; host.apply({});
        check(!e.fake.broker.active().sequence && old_owner, "invalid backend handle leaked its admitted reservation through VM unload");
    }
    {
        ++scenarios;
        LeaseEnvironment e; e.fake.refuse=true; e.fake.refusal=lease::Reason::source_unavailable; Host host(e,Side::client);
        host.apply({main_script("lease-unavailable", R"(
            local h,why=reskate.input.lease(2); assert(h==nil and why=='source_unavailable')
        )")});
        running_lease(host,"lease-unavailable",e);
        check(e.fake.requests==1 && !e.fake.broker.active().sequence && !e.fake.explicit_pulse_requests,
            "unavailable source fell back to a pulse, report mutation or other ownership");
        e.fake.refusal=static_cast<lease::Reason>(999);
        host.apply({main_script("lease-invalid-refusal", R"(
            local h,why=reskate.input.lease(2); assert(h==nil and why=='input lease unavailable')
        )")});
        running_lease(host,"lease-invalid-refusal",e);
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e,Side::client);
        host.apply({main_script("lease-unload", R"(
            local h=assert(reskate.input.lease(2))
            reskate.on('unload',function() assert(reskate.input.lease_state(h).status=='warming') end)
        )")});
        running_lease(host,"lease-unload",e);
        const auto old_owner=e.fake.owner; const auto old_handle=e.fake.handle;
        const auto original_report=e.fake.source.pad;
        e.fake.cleanup.clear(); host.apply({});
        check(e.fake.cleanup.size()>=6 && e.fake.cleanup[0]==std::pair{old_owner,std::string("lease")} &&
            e.fake.cleanup[1].second=="pulse" && e.fake.cleanup[2].second=="trace" &&
            e.fake.cleanup[3].second=="recovery" && e.fake.cleanup[4].second=="action" && e.fake.cleanup[5].second=="body",
            "observation source release did not precede pulse/actor/body cleanup");
        check(!e.fake.broker.active().sequence && e.fake.source.pad==original_report && !e.fake.explicit_pulse_requests,
            "lease unload left an owner reservation or changed the native report");
        host.apply({main_script("lease-unload", "assert(reskate.input.lease(2))")});
        running_lease(host,"lease-unload",e);
        const auto new_owner=e.fake.owner;
        lease::Snapshot sample; lease::Receipt receipt; lease::Reason reason;
        check(new_owner!=old_owner && !e.fake.broker.read(new_owner,old_handle,e.fake.guard,sample,reason) &&
            !e.fake.broker.state(new_owner,old_handle,receipt) && !e.fake.broker.release(new_owner,old_handle) &&
            !e.fake.broker.acknowledge(new_owner,old_handle), "reload inherited a foreign VM's old source authority");
        check(!e.fake.broker.read(old_owner,e.fake.handle,e.fake.guard,sample,reason),
            "stopped VM owner read its replacement's source handle");
    }
    for (unsigned scenario=0; scenario<5; ++scenario) {
        ++scenarios;
        LeaseEnvironment e; Host host(e,Side::client);
        const std::array<const char*,5> reasons{"source_stale","deadline","source_changed","context_changed","focus_lost"};
        const auto main=std::string(R"(
            local P=reskate.input; local h=assert(P.lease(2))
            reskate.on('tick',function()
                local r=assert(P.lease_state(h))
                assert(r.terminal and r.source_released and not r.capturing and not r.report_debt)
                assert(r.reason==')")+reasons[scenario]+R"(')
                assert(P.lease_read(h)==nil and P.lease_acknowledge(h))
                reskate.log('expired or revoked without actions')
            end)
        )";
        host.apply({main_script("lease-facts-"+std::to_string(scenario),main)});
        running_lease(host,"lease-facts-"+std::to_string(scenario),e);
        const auto unchanged=e.fake.source.pad;
        if (scenario==0) e.fake.guard.now_ms+=101;
        else if (scenario==1) e.fake.guard.now_ms+=250;
        else if (scenario==2) { ++e.fake.source.epoch; e.fake.observe(); }
        else if (scenario==3) ++e.fake.guard.context_generation;
        else e.fake.guard.focused=false;
        tick(host,e); running_lease(host,"lease-facts-"+std::to_string(scenario),e);
        check(e.logged("expired or revoked without actions") && e.fake.source.pad==unchanged && !e.fake.explicit_pulse_requests,
            "source expiry/revocation invented native actions or report debt");
    }
    {
        ++scenarios;
        LeaseEnvironment e; Host host(e,Side::client);
        host.apply({main_script("lease-library", R"(
            local h=assert(reskate.input.lease(2))
            reskate.expose({opaque=function() return h end, plain=function() return {sequence='9007199254740995'} end})
        )"), script("lease-consumer",R"(
            reskate.on('tick',function()
                local lib=assert(reskate.require_plugin('lease-library'))
                assert(not pcall(lib.opaque),'raw userdata must not cross plugin VMs')
                local plain=lib.plain(); assert(plain.sequence=='9007199254740995')
                assert(not pcall(reskate.input.lease_read,plain),'shared descriptive numbers are not handles')
                reskate.log('foreign VM cannot receive authority')
            end)
        )",R"("input.lease")")});
        running_lease(host,"lease-library",e); running_lease(host,"lease-consumer",e);
        tick(host,e); running_lease(host,"lease-consumer",e);
        check(e.logged("foreign VM cannot receive authority") && !e.fake.reads,
            "inter-plugin JSON exchange transferred opaque source authority");
    }
    std::cout << "input lease actual Host: " << scenarios
        << " constructed-source scenarios, opaque owner/epoch isolation, zero native report writes; no gameplay claim\n";
}

// The public capture contract over real portable policies, with constructed
// publication facts. No fixture write is evidence of native consumption.
void input_lease_capture_api_keeps_publication_duty_owner_scoped() {
    namespace lease = dingosdk::input_lease;
    namespace capture = dingosdk::input_lease_capture;
    struct CaptureGame final : Game {
        lease::Broker broker{9007199254740995ULL};
        capture::Capture capture_policy{9007199254741019ULL, 9007199254741021ULL};
        lease::Guard guard{9007199254740997ULL, 9007199254741011ULL, true, true, true, true, true};
        lease::Source source{2, 27, 9007199254741009ULL, 9007199254741001ULL,
            9007199254740997ULL, 9007199254741011ULL, {0x1000}, true, true};
        lease::Handle handle{};
        std::uint64_t owner{}, last_owner{};
        unsigned lease_requests{}, lease_reads{}, capture_requests{}, capture_states{}, capture_releases{}, capture_acks{};
        unsigned fixture_buffer_writes{}, pulse_requests{};
        bool default_native{}, orphaned{}, in_flight{};
        std::vector<std::pair<std::uint64_t,std::string>> cleanup;
        std::function<void(capture::Receipt&)> alter_capture;
        std::function<void(lease::Receipt&)> alter_passive;
        bool capture_busy() const { return capture_policy.reserved() || (capture_policy.state().phase!=capture::Phase::idle && in_flight); }
        bool owns(std::uint64_t who, lease::Handle h) const {
            const auto& r=capture_policy.state();
            return who && r.phase!=capture::Phase::idle && r.key.owner==who && r.key.lease_sequence==h.sequence;
        }
        capture::Input input() const {
            capture::Input in;
            in.source_epoch=source.epoch; in.context_generation=source.context_generation;
            in.observation_serial=source.observation_serial; in.observed_ms=source.observed_ms; in.now_ms=guard.now_ms;
            in.user=source.user; in.raw=in.returned=source.pad;
            in.safety={broker.accepted(owner,handle,source),guard.ready,guard.focused,guard.gameplay,guard.menu_closed,guard.interference_clear};
            in.outer_game_poll=in.has_output=true; in.source_connected=source.connected;
            return in;
        }
        bool input_lease_request(std::uint64_t who,std::uint32_t user,lease::Handle& out,lease::Reason& reason) override {
            ++lease_requests; last_owner=who;
            if (capture_busy()) { reason=lease::Reason::busy; return false; }
            if (!broker.request(who,user,source,guard,false,out,reason)) return false;
            owner=who; handle=out; return true;
        }
        bool input_lease_read(std::uint64_t who,lease::Handle h,lease::Snapshot& out,lease::Reason& reason) override {
            ++lease_reads; return broker.read(who,h,guard,out,reason);
        }
        bool input_lease_renew(std::uint64_t who,lease::Handle h,const lease::Snapshot& epoch,lease::Reason& reason) override {
            return broker.renew(who,h,epoch,guard,reason);
        }
        bool input_lease_release(std::uint64_t who,lease::Handle h,lease::Reason& reason) override {
            const bool ok=broker.release(who,h);
            if (ok && owns(who,h)) (void)capture_policy.release(capture_policy.state().key);
            reason=ok?lease::Reason::none:lease::Reason::unavailable; return ok;
        }
        bool input_lease_state(std::uint64_t who,lease::Handle h,lease::Receipt& out,lease::Reason& reason) override {
            broker.tick(guard);
            const bool ok=broker.state(who,h,out);
            if (ok && owns(who,h) && capture_busy()) { out.source_released=false; out.capture_reserved=true; }
            if (ok && alter_passive) alter_passive(out);
            reason=ok?lease::Reason::none:lease::Reason::unavailable; return ok;
        }
        bool input_lease_acknowledge(std::uint64_t who,lease::Handle h,lease::Reason& reason) override {
            if (owns(who,h) && capture_busy()) { reason=lease::Reason::busy; return false; }
            const bool ok=broker.acknowledge(who,h);
            reason=ok?lease::Reason::none:lease::Reason::unavailable; return ok;
        }
        bool input_lease_capture_request(std::uint64_t who,lease::Handle h,const lease::Snapshot& epoch,capture::Reason& reason) override {
            ++capture_requests;
            if (default_native) return Game::input_lease_capture_request(who,h,epoch,reason);
            reason=capture::Reason::authority_lost;
            broker.tick(guard); lease::Receipt r;
            if (!broker.state(who,h,r) || r.status!=lease::Status::active || !broker.issued(who,h,epoch) ||
                !broker.accepted(who,h,source) || epoch.observation_serial!=source.observation_serial || epoch.pad!=source.pad) return false;
            auto in=input(); in.safety.source_authorized=true;
            return capture_policy.request({who,h.sequence,r.source_epoch,r.context_generation,r.user},r.expires_ms,in,false,reason);
        }
        bool input_lease_capture_state(std::uint64_t who,lease::Handle h,capture::Receipt& out) override {
            ++capture_states;
            if (default_native || !owns(who,h)) return false;
            out=capture_policy.state(); if (alter_capture) alter_capture(out); return true;
        }
        bool input_lease_capture_release(std::uint64_t who,lease::Handle h) override {
            ++capture_releases;
            if (default_native || !owns(who,h)) return false;
            const bool ok=capture_policy.release(capture_policy.state().key);
            if (ok) broker.invalidate(lease::Reason::cancelled);
            return ok;
        }
        bool input_lease_capture_acknowledge(std::uint64_t who,lease::Handle h) override {
            ++capture_acks;
            return !default_native && owns(who,h) && !in_flight && capture_policy.acknowledge(capture_policy.state().key);
        }
        void input_lease_release_all(std::uint64_t who) override {
            cleanup.emplace_back(who,"capture/source");
            if (capture_policy.state().key.owner==who && capture_policy.state().phase!=capture::Phase::idle) {
                orphaned=true; (void)capture_policy.release(capture_policy.state().key);
            }
            broker.release_all(who);
        }
        void input_pulse_release_all(std::uint64_t who) override { cleanup.emplace_back(who,"pulse"); }
        void input_trace_release_all(std::uint64_t who) override { cleanup.emplace_back(who,"trace"); }
        void native_recovery_release_all(std::uint64_t who) override { cleanup.emplace_back(who,"recovery"); }
        void native_action_release_all(std::uint64_t who) override { cleanup.emplace_back(who,"action"); }
        void body_release_all(std::uint64_t who) override { cleanup.emplace_back(who,"body"); }
        bool input_pulse_request(std::uint64_t,std::uint32_t,std::uint16_t,game_input_pulse::Handle&,
            game_input_pulse::Reason& reason) override {
            ++pulse_requests; reason=game_input_pulse::Reason::unavailable; return false;
        }
        void observe(lease::Pad pad={}) {
            source.pad=pad; source.observed_ms=++guard.now_ms; ++source.observation_serial;
            broker.observe(broker.active(),source,guard);
        }
        capture::Plan publish_fixture(lease::Pad pad={},bool published=true) {
            observe(pad); const auto plan=capture_policy.plan(capture_policy.ticket(),input());
            if (plan.suppress) { ++fixture_buffer_writes; (void)capture_policy.confirm(plan,published); }
            return plan;
        }
        unsigned capture_calls() const { return capture_requests+capture_states+capture_releases+capture_acks; }
    };
    struct CaptureEnvironment final : Environment {
        CaptureGame fake;
        double now{1000}; std::vector<std::string> logs;
        void log(LogLevel,std::string_view text) override { logs.emplace_back(text); }
        void console(std::string_view) override {}
        double now_ms() override { return now; }
        std::filesystem::path storage_root() override { return scratch/"capture-storage"; }
        bool builtin_command(std::string_view) override { return false; }
        Game& game() override { return fake; }
        bool logged(std::string_view part) const {
            return std::any_of(logs.begin(),logs.end(),[&](const auto& line){return line.find(part)!=std::string::npos;});
        }
        std::string all() const {std::string out;for(const auto& line:logs)out+=line+"\n";return out;}
    };
    unsigned scenarios{};
    const auto running_capture=[&](const Host& host,std::string_view id,const CaptureEnvironment& e) {
        const auto s=status_of(host,id);
        check(s.state=="running",std::string(id)+": "+s.state+": "+s.reason+"\n"+e.all());
    };
    const auto tick=[&](Host& host,CaptureEnvironment& e){e.now+=16;host.tick(16);};
    const auto captured_script=[&](const std::string& id,const std::string& code) {
        return script(id,code,R"("input.lease","input.capture")");
    };
    for(const auto& permissions : {std::string{},std::string(R"("input.lease")"),std::string(R"("input.capture")")}) {
        ++scenarios; CaptureEnvironment e;Host host(e,Side::client);
        const auto missing=permissions==R"("input.lease")"?"input.capture":"input.lease";
        host.apply({script("capture-denied",std::string(R"(
            for _,name in {'lease_capture','lease_capture_state','lease_release_capture','lease_acknowledge_capture'} do
                local ok,why=pcall(reskate.input[name],{}, {}, {})
                assert(not ok and why:find(')")+missing+R"('),name)
            end
        )",permissions)});
        running_capture(host,"capture-denied",e);
        check(!e.fake.capture_calls()&&!e.fake.lease_requests,"capture permission denial parsed arguments or reached backend");
    }
    {
        ++scenarios;CaptureEnvironment e;Host host(e,Side::server);
        host.apply({package("capture-server",{{manifest_file,manifest(R"("input.lease","input.capture")","server")},{"plugin/main.lua",R"(
            for _,name in {'lease_capture','lease_capture_state','lease_release_capture','lease_acknowledge_capture'} do
                local ok,why=pcall(reskate.input[name],{}, {}, {})
                assert(not ok and why:find('client phase only'),name)
            end
        )"}})});
        running_capture(host,"capture-server",e);check(!e.fake.capture_calls(),"server capture reached backend");
    }
    {
        ++scenarios;CaptureEnvironment e;Host host(e,Side::client);
        host.apply({captured_script("capture-arguments",R"(
            local P=reskate.input;local h=assert(P.lease(2))
            assert(not pcall(P.lease_capture) and not pcall(P.lease_capture,h))
            assert(not pcall(P.lease_capture,h,{},nil))
            for _,bad in {{},2,false,'epoch',h} do assert(not pcall(P.lease_capture,h,bad)) end
            for _,fn in {P.lease_capture_state,P.lease_release_capture,P.lease_acknowledge_capture} do
                assert(not pcall(fn) and not pcall(fn,h,nil))
                for _,bad in {{},false,2,'handle'} do assert(not pcall(fn,bad)) end
            end
            assert(P.lease_capture_state(h)==nil)
            reskate.log('no epoch no capture')
        )")});
        running_capture(host,"capture-arguments",e);
        check(e.logged("no epoch no capture")&&!e.fake.capture_calls()&&e.fake.lease_requests==1,
            "malformed capture arguments or an unadmitted handle reached backend state");
    }
    {
        ++scenarios;CaptureEnvironment e;e.fake.default_native=true;Host host(e,Side::client);
        host.apply({captured_script("capture-native-unavailable",R"(
            local P=reskate.input;local h=assert(P.lease(2))
            reskate.on('tick',function()
                local epoch=assert(P.lease_read(h)).epoch
                for _,bad in {{},false,2,'handle',epoch} do assert(not pcall(P.lease_capture,bad,epoch)) end
                assert(not pcall(P.lease_capture,h,epoch,nil))
                local ok,why=P.lease_capture(h,epoch);assert(ok==false and why=='unavailable')
                assert(P.lease_capture_state(h)==nil)
                assert(not P.lease_release_capture(h) and not P.lease_acknowledge_capture(h))
                assert(P.lease_state(h).mode=='observe')
                reskate.log('default capture unavailable')
            end)
        )")});
        running_capture(host,"capture-native-unavailable",e);e.fake.observe();tick(host,e);
        running_capture(host,"capture-native-unavailable",e);
        check(e.logged("default capture unavailable")&&e.fake.capture_requests==1&&!e.fake.capture_states&&
            !e.fake.fixture_buffer_writes&&!e.fake.pulse_requests,"default capture backend fabricated ownership or fell back to an actuator");
    }
    {
        ++scenarios;CaptureEnvironment e;Host host(e,Side::client);
        host.apply({captured_script("capture-wrong-epoch",R"(
            local P=reskate.input;local h=assert(P.lease(2));local stage=0;local old
            reskate.on('tick',function()
                if stage==0 then
                    old=assert(P.lease_read(h)).epoch
                    assert(P.lease_release(h) and P.lease_acknowledge(h));h=assert(P.lease(2));stage=1
                    local ok,why=pcall(P.lease_capture,h,old);assert(not ok and why:find('another lease'))
                    reskate.log('foreign lease epoch blocked')
                end
            end)
        )")});
        running_capture(host,"capture-wrong-epoch",e);e.fake.observe();tick(host,e);running_capture(host,"capture-wrong-epoch",e);
        check(e.logged("foreign lease epoch blocked")&&!e.fake.capture_requests,"wrong lease epoch crossed capture API owner/key boundary");
    }
    {
        ++scenarios;CaptureEnvironment e;Host host(e,Side::client);
        host.apply({captured_script("capture-stale-epoch",R"(
            local P=reskate.input;local h=assert(P.lease(2));local stage=0;local old
            reskate.on('tick',function()
                if stage==0 then old=assert(P.lease_read(h)).epoch;stage=1;return end
                local ok,why=P.lease_capture(h,old);assert(not ok and why=='authority_lost')
                assert(P.lease_capture_state(h)==nil)
                local current=assert(P.lease_read(h));assert(P.lease_capture(h,current.epoch))
                ok,why=P.lease_capture(h,current.epoch);assert(not ok and why=='busy')
                assert(P.lease_capture_state(h).phase=='waiting_neutral')
                reskate.log('stale then replay refused');stage=2
            end)
        )")});
        running_capture(host,"capture-stale-epoch",e);e.fake.observe();tick(host,e);
        e.fake.observe();tick(host,e);running_capture(host,"capture-stale-epoch",e);
        check(e.logged("stale then replay refused")&&e.fake.capture_requests==3&&!e.fake.fixture_buffer_writes,
            "stale snapshot or replayed admitted epoch produced capture publication");
    }
    {
        ++scenarios;CaptureEnvironment e;Host host(e,Side::client);
        host.apply({captured_script("capture-lifecycle",R"(
            local P=reskate.input;local h=assert(P.lease(2));local stage=0
            reskate.on('tick',function()
                if stage==0 then
                    local s=assert(P.lease_read(h));assert(P.lease_capture(h,s.epoch))
                    s.source_epoch='1';s.observation_serial='1'
                    local r=assert(P.lease_capture_state(h))
                    assert(r.phase=='waiting_neutral' and r.reason=='none' and not r.terminal)
                    assert(r.sequence=='9007199254740995' and r.source_epoch=='9007199254741009')
                    assert(r.context_generation=='9007199254741011' and r.user==2)
                    assert(r.generation=='9007199254741020' and r.revision=='9007199254741022')
                    assert(r.expires_ms=='9007199254741247' and r.publications=='0' and r.neutral_releases=='0')
                    assert(r.transport=='xinput' and r.mode=='capture' and r.source_identity=='observed_stream')
                    assert(r.physical_device_identity=='unobserved' and r.capture_scope=='selected_observed_xinput_stream')
                    assert(r.publication_scope=='process_outer_xinput_buffer')
                    assert(r.consumption=='unobserved' and r.semantic_completion=='unobserved')
                    assert(not r.capturing and not r.report_debt and not r.quarantined)
                    assert(not P.lease_acknowledge_capture(h));stage=1;return
                elseif stage==1 then
                    local r=assert(P.lease_capture_state(h));assert(r.phase=='capturing' and r.capturing and r.report_debt)
                    assert(r.publications=='1' and not r.terminal)
                    assert(P.lease_release(h))
                    local passive=assert(P.lease_state(h))
                    assert(passive.status=='released' and passive.terminal and not passive.source_released and passive.capture_reserved)
                    assert(passive.mode=='observe' and not passive.capturing and not passive.report_debt)
                    local ok,why=P.lease_acknowledge(h);assert(not ok and why=='busy')
                    r=assert(P.lease_capture_state(h));assert(r.phase=='releasing' and r.report_debt and not r.capturing)
                    assert(not P.lease_acknowledge_capture(h));stage=2;return
                elseif stage==2 then
                    local r=assert(P.lease_capture_state(h));assert(r.phase=='releasing' and r.quarantined and r.report_debt)
                    assert(not P.lease_acknowledge_capture(h));stage=3;return
                elseif stage==3 then
                    local r=assert(P.lease_capture_state(h));assert(r.phase=='complete' and r.terminal and not r.report_debt)
                    assert(r.publications=='2' and r.neutral_releases=='1' and not r.quarantined)
                    local passive=assert(P.lease_state(h));assert(passive.source_released and not passive.capture_reserved)
                    assert(P.lease_acknowledge(h))
                    assert(P.lease_capture_state(h).terminal,'capture evidence outlives passive acknowledgement')
                    assert(P.lease_acknowledge_capture(h))
                    assert(P.lease_capture_state(h)==nil)
                    reskate.log('capture duty resolved and acknowledged');stage=4
                end
            end)
        )")});
        running_capture(host,"capture-lifecycle",e);e.fake.observe();tick(host,e);running_capture(host,"capture-lifecycle",e);
        const auto first=e.fake.publish_fixture();
        check(first.suppress&&first.start&&first.pad==lease::Pad{},"constructed neutral successor did not start portable capture");
        tick(host,e);running_capture(host,"capture-lifecycle",e);
        const auto source_epoch=e.fake.source.epoch;++e.fake.source.epoch;
        const auto foreign=e.fake.publish_fixture({0x1000});
        check(!foreign.suppress,"portable cleanup rewrote a replacement observed stream");
        tick(host,e);running_capture(host,"capture-lifecycle",e);
        e.fake.source.epoch=source_epoch;
        const auto release=e.fake.publish_fixture();
        check(release.suppress&&release.release,"portable same-source neutral cleanup was not published");
        tick(host,e);running_capture(host,"capture-lifecycle",e);
        check(e.logged("capture duty resolved and acknowledged")&&e.fake.fixture_buffer_writes==2&&!e.fake.pulse_requests,
            "capture lifecycle lost debt, claimed native consumption or used pulse ownership");
    }
    {
        // A pad resting in the hands reads neutral, starts capture and releases it;
        // a stick pushed past its rest radius does not start it.
        ++scenarios;CaptureEnvironment e;Host host(e,Side::client);
        host.apply({captured_script("capture-resting-noise",R"(
            local P=reskate.input;local h=assert(P.lease(2));local stage=0
            reskate.on('tick',function()
                if stage==0 then
                    local s=assert(P.lease_read(h))
                    assert(s.neutral==true and s.pad.left_x~=0 and s.pad.left_trigger>0)
                    assert(P.lease_capture(h,s.epoch));stage=1;return
                elseif stage==1 then
                    local r=assert(P.lease_capture_state(h));assert(r.phase=='capturing' and r.report_debt)
                    assert(P.lease_release_capture(h));stage=2;return
                elseif stage==2 then
                    local r=assert(P.lease_capture_state(h))
                    assert(r.phase=='complete' and not r.report_debt and r.neutral_releases=='1' and not r.quarantined)
                    assert(P.lease_acknowledge_capture(h) and P.lease_acknowledge(h))
                    reskate.log('resting noise captured and released');stage=3
                end
            end)
        )")});
        const lease::Pad resting{0,30,12,7000,-3000,-8000,2000};
        running_capture(host,"capture-resting-noise",e);e.fake.observe(resting);tick(host,e);
        running_capture(host,"capture-resting-noise",e);
        const auto pushed=e.fake.publish_fixture({0,0,0,6000,6000,0,0});
        check(!pushed.suppress&&e.fake.capture_policy.state().phase==capture::Phase::waiting_neutral,
            "a diagonal push past the stick's rest radius started capture");
        const auto first=e.fake.publish_fixture(resting);
        check(first.suppress&&first.start&&first.pad==lease::Pad{},"resting noise did not start capture with an exact neutral report");
        tick(host,e);running_capture(host,"capture-resting-noise",e);
        const auto release=e.fake.publish_fixture(resting);
        check(release.suppress&&release.release&&release.pad==resting&&!release.held.any(),
            "a resting pad did not finish the handoff on its first report");
        tick(host,e);running_capture(host,"capture-resting-noise",e);
        check(e.logged("resting noise captured and released")&&e.fake.fixture_buffer_writes==2,
            "a resting pad's capture lifecycle did not resolve");
    }
    {
        ++scenarios;CaptureEnvironment e;Host host(e,Side::client);
        host.apply({captured_script("capture-malformed",R"(
            local P=reskate.input;local h=assert(P.lease(2));local first=true
            reskate.on('tick',function()
                if first then assert(P.lease_capture(h,assert(P.lease_read(h)).epoch));first=false;return end
                local r,why=P.lease_capture_state(h);assert(r==nil and why:find('invalid observations'))
                reskate.log('capture malformed refused')
            end)
        )")});
        running_capture(host,"capture-malformed",e);e.fake.observe();tick(host,e);e.fake.publish_fixture();
        const std::vector<std::function<void(capture::Receipt&)>> malformed{
            [](auto& r){++r.key.owner;},[](auto& r){++r.key.lease_sequence;},[](auto& r){++r.key.source_epoch;},
            [](auto& r){++r.key.context_generation;},[](auto& r){r.key.user=1;},[](auto& r){r.key.user=4;},
            [](auto& r){r.key.source_epoch=0;},[](auto& r){r.key.context_generation=0;},
            [](auto& r){r.generation=0;},[](auto& r){r.revision=0;},[](auto& r){r.expires_ms=0;},
            [](auto& r){r.phase=static_cast<capture::Phase>(999);},[](auto& r){r.reason=static_cast<capture::Reason>(999);},
            [](auto& r){r.phase=capture::Phase::idle;},[](auto& r){r.debt=false;},
            [](auto& r){r.publications=0;},[](auto& r){r.quarantined=true;},
            [](auto& r){r.neutral_releases=r.publications+1;},
            [](auto& r){r.phase=capture::Phase::waiting_neutral;},
            [](auto& r){r.phase=capture::Phase::waiting_neutral;r.debt=false;},
            [](auto& r){r.phase=capture::Phase::waiting_neutral;r.debt=false;r.publications=0;r.quarantined=true;},
            [](auto& r){r.phase=capture::Phase::waiting_neutral;r.debt=false;r.publications=0;r.neutral_releases=1;},
            [](auto& r){r.phase=capture::Phase::releasing;r.debt=false;},
            [](auto& r){r.phase=capture::Phase::complete;}
        };
        for(const auto& alter:malformed) {
            ++scenarios;e.logs.clear();e.fake.alter_capture=alter;tick(host,e);running_capture(host,"capture-malformed",e);
            check(e.logged("capture malformed refused"),"malformed capture receipt became public publication evidence");
        }
    }
    for(unsigned admitted=0;admitted<2;++admitted) {
        ++scenarios;CaptureEnvironment e;Host host(e,Side::client);
        const auto code=std::string(R"(
            local P=reskate.input;local h=assert(P.lease(2));local first=true
            reskate.on('tick',function()
                if first then
                    local epoch=assert(P.lease_read(h)).epoch
        )")+(admitted?"assert(P.lease_capture(h,epoch))":"")+R"(
                    first=false;return
                end
                local r,why=P.lease_state(h);assert(r==nil and why:find('invalid observations'))
                reskate.log('passive capture flags refused')
            end)
        )";
        host.apply({captured_script("capture-passive-flags",code)});
        running_capture(host,"capture-passive-flags",e);e.fake.observe();tick(host,e);
        const std::vector<std::function<void(lease::Receipt&)>> malformed{
            [](auto& r){r.capture_reserved=true;r.source_released=true;},
            [](auto& r){r.status=lease::Status::released;r.source_released=false;r.capture_reserved=false;},
            [](auto& r){r.status=lease::Status::released;r.source_released=false;r.capture_reserved=true;++r.source_epoch;},
            [](auto& r){r.status=lease::Status::released;r.source_released=false;r.capture_reserved=true;++r.context_generation;}
        };
        for(const auto& alter:malformed) {
            ++scenarios;e.logs.clear();e.fake.alter_passive=alter;tick(host,e);running_capture(host,"capture-passive-flags",e);
            check(e.logged("passive capture flags refused"),"unproven capture reservation weakened passive receipt validation");
        }
        if(!admitted) {
            ++scenarios;e.logs.clear();e.fake.alter_passive=[](auto& r){r.capture_reserved=true;};
            tick(host,e);running_capture(host,"capture-passive-flags",e);
            check(e.logged("passive capture flags refused"),"a backend flag fabricated local capture admission");
        }
    }
    {
        ++scenarios;CaptureEnvironment e;Host host(e,Side::client);
        host.apply({captured_script("capture-unload",R"(
            local P=reskate.input;local h=assert(P.lease(2));local first=true
            reskate.on('tick',function()if first then assert(P.lease_capture(h,assert(P.lease_read(h)).epoch));first=false end end)
        )")});
        running_capture(host,"capture-unload",e);e.fake.observe();tick(host,e);e.fake.publish_fixture();
        const auto old_owner=e.fake.owner;const auto old_handle=e.fake.handle;
        e.fake.cleanup.clear();host.apply({});
        check(e.fake.orphaned&&e.fake.capture_policy.state().phase==capture::Phase::releasing&&e.fake.capture_policy.state().debt&&
            e.fake.cleanup.size()>=6&&e.fake.cleanup[0]==std::pair{old_owner,std::string("capture/source")}&&
            e.fake.cleanup[1].second=="pulse"&&e.fake.cleanup[2].second=="trace"&&
            e.fake.cleanup[3].second=="recovery"&&e.fake.cleanup[4].second=="action"&&e.fake.cleanup[5].second=="body",
            "VM close discarded capture publication debt or ran actor/body cleanup first");
        ++e.fake.source.epoch;e.fake.publish_fixture();
        check(e.fake.capture_policy.state().quarantined&&e.fake.capture_policy.state().debt,"replacement source retired an orphan's publication debt");
        host.apply({captured_script("capture-unload",R"(
            local h,why=reskate.input.lease(2);assert(h==nil and why=='busy')
        )")});running_capture(host,"capture-unload",e);
        const auto replacement_owner=e.fake.last_owner;capture::Receipt r;
        check(replacement_owner!=old_owner&&!e.fake.input_lease_capture_state(replacement_owner,old_handle,r)&&
            !e.fake.input_lease_capture_release(replacement_owner,old_handle)&&!e.fake.input_lease_capture_acknowledge(replacement_owner,old_handle),
            "replacement VM inherited an orphan's capture key/duty");
        check(!e.fake.pulse_requests,"capture cleanup fell back to pulse arbitration");
    }
    std::cout<<"input lease capture actual Host: "<<scenarios
        <<" constructed-source/publication cases, real portable policies, no native controller/consumption/gameplay claim\n";
}

void input_trace_api_keeps_bounded_observations_opaque_and_vm_owned() {
    namespace t = dingosdk::input_trace;
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("input-trace", R"(
        local S=reskate.skater
        assert(not pcall(S.input_trace,nil))
        local h=assert(S.input_trace())
        assert(type(h)=="userdata" and getmetatable(h)=="locked")
        for _,fn in {S.input_trace_state,S.input_trace_stop,S.input_trace_acknowledge} do
            assert(not pcall(fn,{}) and not pcall(fn,"9007199254740995") and not pcall(fn,h,nil))
        end
        assert(not pcall(S.action_state,h))
        local r=assert(S.input_trace_state(h))
        assert(r.sequence=="9007199254740995" and r.requested_ms=="9007199254740997" and r.expires_ms=="9007199254745997")
        assert(r.status=="active" and not r.terminal and #r.records==0)
        assert(r.seen=="0" and r.duplicates=="0" and r.dropped=="0")
        assert(r.unknown_calls_at_start=="9007199254740998" and r.unknown_calls_total=="9007199254741008")
        assert(r.unknown_returns==nil and r.return_addresses==nil)
        assert(not S.input_trace_acknowledge(h))
        local phase=0
        reskate.on("tick",function()
            local v,why=S.input_trace_state(h)
            if v==nil then assert(why:find("invalid observations"));reskate.log("trace rejected malformed");return end
            if #v.records==2 then
                local a,b=v.records[1],v.records[2]
                assert(a.asset_token==7 and a.thread_id==12 and a.lane=="interpreter" and a.condition_known and a.condition==false)
                assert(a.local_tuple_known and a.container_matches_local and a.snapshot_stable and a.issue==0)
                assert(b.asset_token==8 and b.lane=="alternate" and not b.condition_known and b.condition==nil and b.issue==2)
                assert(a.address==nil and a.asset==nil and a.container==nil)
                assert(v.seen=="9007199254741004" and v.duplicates=="9007199254740998" and v.dropped=="4")
                phase+=1;reskate.log("trace rows checked")
                if phase==2 then
                    assert(S.input_trace_stop(h));assert(S.input_trace_state(h).terminal)
                    assert(S.input_trace_acknowledge(h) and S.input_trace_state(h)==nil)
                    h=nil
                end
            end
        end)
    )", R"("skater.input_trace")")}); running(host, "input-trace", environment);
    check(environment.fake.input_trace_requests == 1 && environment.fake.input_traces.size() == 1, "trace invalid args reached backend");
    auto& row = environment.fake.input_traces.begin()->second;
    const auto owner = row.owner; const auto handle = row.receipt.handle;
    auto& r = row.receipt;
    r.record_count = 129;
    ticks(host, environment, 1); running(host, "input-trace", environment);
    check(environment.logged("trace rejected malformed"), "oversized trace was serialized");
    r.record_count = 2; r.seen = 9007199254741004ULL; r.duplicates = 9007199254740998ULL; r.dropped = 4;
    auto& a = r.records[0]; a.observed_ms = r.requested_ms + 1; a.thread_id = 12; a.lane = t::Lane::interpreter;
    a.asset_token = 7; a.condition_known = a.local_tuple_known = a.container_matches_local = a.snapshot_stable = true;
    auto& b = r.records[1]; b.observed_ms = r.requested_ms + 2; b.lane = t::Lane::alternate; b.asset_token = 8; b.issue = 2;
    a.asset_token = 65;
    const auto reads_before = environment.fake.input_trace_reads;
    ticks(host, environment, 1); running(host, "input-trace", environment);
    check(environment.fake.input_trace_reads > reads_before && !environment.logged("trace rows checked"), "unbounded token was serialized");
    a.asset_token = 7;
    ticks(host, environment, 1); running(host, "input-trace", environment);
    check(environment.logged("trace rows checked"), environment.all());
    ticks(host, environment, 1); running(host, "input-trace", environment);
    check(environment.fake.input_traces.empty(), "stopped trace could not be acknowledged");
    host.apply({}); // Test packages keep fingerprint "1"; explicitly end this VM before replacing its source.
    host.apply({script("input-trace", "assert(reskate.skater.input_trace())", R"("skater.input_trace")")});
    running(host, "input-trace", environment);
    const auto replacement = environment.fake.input_traces.begin()->second;
    check(replacement.owner != owner, "trace reload reused prior VM identity");
    t::Receipt stale_trace_receipt;
    check(!environment.fake.input_trace_read(replacement.owner, handle, stale_trace_receipt) &&
        !environment.fake.input_trace_stop(owner, replacement.receipt.handle) &&
        !environment.fake.input_trace_acknowledge(owner, replacement.receipt.handle), "trace crossed VM owner boundary");
    host.apply({});
    check(environment.fake.input_traces.empty() &&
        std::find(environment.fake.input_trace_releases.begin(), environment.fake.input_trace_releases.end(), replacement.owner) != environment.fake.input_trace_releases.end(),
        "VM unload retained trace ownership");
}

void input_trace_api_requires_permission_client_phase_and_start_budget() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("input-trace-denied", R"(
        for _,name in {"input_trace","input_trace_state","input_trace_stop","input_trace_acknowledge"} do
            local ok,why=pcall(reskate.skater[name],{})
            assert(not ok and why:find("skater.input_trace"),name)
        end
    )", R"("skater.read","skater.control","input")")}); running(host, "input-trace-denied", environment);
    check(environment.fake.input_trace_requests == 0 && environment.fake.input_trace_reads == 0 &&
        environment.fake.input_trace_stops == 0 && environment.fake.input_trace_acks == 0, "permission denial reached trace backend");
    host.apply({script("input-trace-budget", R"(
        local S=reskate.skater
        for i=1,4 do
            local h=assert(S.input_trace())
            for j=1,5 do assert(S.input_trace_state(h).status=="active") end
            assert(S.input_trace_stop(h) and S.input_trace_acknowledge(h))
        end
        local h,why=S.input_trace();assert(h==nil and why:find("4 times"))
    )", R"("skater.input_trace")")}); running(host, "input-trace-budget", environment);
    check(environment.fake.input_trace_requests == 4 && environment.fake.input_traces.empty(), "trace budget charged polls or allowed fifth start");
    TestEnvironment server_environment; Host server(server_environment, Side::server);
    server.apply({package("input-trace-server", {{manifest_file, manifest(R"("skater.input_trace")", "server")}, {"plugin/main.lua", R"(
        for _,name in {"input_trace","input_trace_state","input_trace_stop","input_trace_acknowledge"} do
            local ok,why=pcall(reskate.skater[name],{})
            assert(not ok and why:find("client phase only"),name)
        end
    )"}})}); running(server, "input-trace-server", server_environment);
    check(server_environment.fake.input_trace_requests == 0 && server_environment.fake.input_trace_reads == 0 &&
        server_environment.fake.input_trace_stops == 0 && server_environment.fake.input_trace_acks == 0, "server reached trace backend");
}

void native_recovery_keeps_unresolved_cleanup_quarantined_on_unload() {
    namespace r = dingosdk::skater_recovery;
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("recovery-quarantine", R"(
        local S=reskate.skater;local h=assert(S.recover())
        reskate.on("tick",function()
            if not h then return end
            local v=assert(S.recovery_state(h))
            if v.status=="invalidated" then
                assert(v.terminal and v.reason=="native_lifetime_changed" and not v.reset_false)
                assert(v.unresolved and not S.recovery_cancel(h))
                if v.actor_retired then
                    assert(not v.quarantined and S.recovery_acknowledge(h))
                    h=nil;reskate.log("exact retired recovery authority acknowledged without false proof")
                else
                    assert(v.quarantined and not S.recovery_acknowledge(h))
                    reskate.log("recovery cleanup debt retained")
                end
            end
        end)
    )", R"("skater.control")")}); running(host, "recovery-quarantine", environment);
    auto& entry = environment.fake.native_recoveries.begin()->second;
    const auto owner = entry.owner;
    entry.receipt.status = r::Status::invalidated; entry.receipt.reason = r::Reason::native_lifetime_changed;
    entry.receipt.true_entered = true; entry.receipt.true_serial = 600; entry.receipt.true_time = 10;
    entry.receipt.quarantined = entry.receipt.unresolved = true;
    ticks(host, environment, 1); running(host, "recovery-quarantine", environment);
    check(environment.logged("recovery cleanup debt retained") && !environment.fake.native_recoveries.empty(), environment.all());
    entry.receipt.actor_retired = true; entry.receipt.quarantined = false;
    ticks(host, environment, 1); running(host, "recovery-quarantine", environment);
    check(environment.logged("exact retired recovery authority acknowledged without false proof") && environment.fake.native_recoveries.empty(),
        "exact retired actor exception cannot require false-value verification of a destroyed object");
    host.apply({});
    host.apply({script("recovery-orphan", "assert(reskate.skater.recover())", R"("skater.control")")});
    running(host, "recovery-orphan", environment);
    auto& orphan = environment.fake.native_recoveries.begin()->second;
    const auto orphan_owner = orphan.owner; const auto orphan_handle = orphan.receipt.handle;
    orphan.receipt.true_entered = true; orphan.receipt.unresolved = orphan.receipt.quarantined = true;
    host.apply({});
    const auto at = environment.fake.native_recoveries.find(orphan_handle.sequence);
    check(at != environment.fake.native_recoveries.end() && at->second.abandoned && at->second.receipt.quarantined && at->second.receipt.unresolved,
        "VM shutdown silently erased a possible native true");
    r::Receipt stale_recovery_receipt;
    check(!environment.fake.native_recovery_read(orphan_owner, orphan_handle, stale_recovery_receipt), "unloaded VM retained a readable fake recovery handle");
    check(std::find(environment.fake.native_recovery_releases.begin(), environment.fake.native_recovery_releases.end(), owner) !=
        environment.fake.native_recovery_releases.end(), "VM shutdown omitted recovery release_all");
    at->second.receipt.actor_retired = true; at->second.receipt.quarantined = false;
    environment.fake.native_recovery_release_all(orphan_owner);
    check(environment.fake.native_recoveries.empty(), "exact retired orphan cannot permanently consume retained capacity");
}

std::string batch_main(std::string body) {
    return R"(
        local P,v=reskate.world.physics,vector.create
        local d={mass=12,inertia=v(2,3,4),position=v(0,2,0),rotation={0,0,0,1},capsules={{a=v(0,0,0),b=v(0,.5,0),radius=.1}}}
        local h,other=assert(P.create(d)),assert(P.create(d))
        local sample=assert(P.read(h))
        local epoch=sample.epoch
        local ray={from=v(0,2,0),to=v(0,-2,0)}
        local function rays(n) local out={} for i=1,n do out[i]=ray end return out end
        local function unavailable(out,reason)
            assert(out.status=="unavailable" and out.reason==reason,tostring(out.reason))
            for _,r in out.rays do assert(r.status=="unavailable" and not r.position and not r.fraction and not r.body and not r.motion) end
        end
    )" + body;
}

void body_contact_details_are_known_and_epoch_bound() {
    body_query::Request last;
    unsigned corruptions{};
    const auto load=[&](const char* id,int mode,bool clear,std::string assertions) {
        // Each case starts a fresh synthetic native world. Retained body slots
        // are never erased/recycled merely to make another case fit.
        TestEnvironment environment;Host host(environment,Side::client);
        auto& game=environment.fake;game.batch_contact_mode=mode;game.batch_clear=clear;
        host.apply({script(id,batch_main(assertions),R"("world.physics","world.raycast")")});
        running(host,id,environment);last=game.last_batch;
        corruptions+=game.batch_available_corruptions;
        check(game.body_submissions==0,"contact reads submitted body commands");
    };
    load("contact-measured",1,false,R"(
        local out=P.probe_batch(h,epoch,rays(1),{require_contact=true,exclude_local_actor=true})
        -- The constructed backend runs the batch but establishes no actor exclusion,
        -- and the binding reports the backend's fact, never the request's flag.
        assert(out.status=="available" and out.epoch==epoch and out.local_actor_excluded==false and out.owned_bodies_excluded)
        local hit=out.rays[1]
        assert(hit.motion=="measured" and hit.normal_available and hit.normal==v(0,1,0))
        assert(hit.surface_velocity_available and hit.surface_velocity==v(2,0,-1))
        assert(not pcall(P.probe_batch,h,epoch,rays(1),{require_contact=1}))
    )");
    check(last.require_contact && last.exclude_local_actor,"contact options were dropped");
    load("contact-unknown",0,false,R"(
        unavailable(P.probe_batch(h,epoch,rays(1),{require_contact=true}),"contact_measurement_unavailable")
        local out=P.probe_batch(h,epoch,rays(1))
        assert(out.status=="available" and out.epoch==epoch and not out.local_actor_excluded)
        assert(out.rays[1].normal_available==false and out.rays[1].surface_velocity_available==false)
        assert(not out.rays[1].normal and not out.rays[1].surface_velocity)
    )");
    for(int mode=2;mode<=6;++mode) {
        load(("contact-malformed-"+std::to_string(mode)).c_str(),mode,false,R"(
            unavailable(P.probe_batch(h,epoch,rays(1),{require_contact=true}),"invalid_query_backend_result")
        )");
    }
    check(corruptions==3,"binding guard was not given all three malformed AVAILABLE backend results");
    load("contact-clear",1,true,R"(
        local out=P.probe_batch(h,epoch,rays(1),{require_contact=true})
        assert(out.status=="available" and out.rays[1].status=="clear")
        assert(not out.rays[1].normal and not out.rays[1].surface_velocity)
    )");
}

// A named query preset is a request option, not a claim about the result. A call
// without it keeps the exact earlier result fields; an explicit preset adds only
// the echo of what was asked, on a hit, a clear and a refusal alike.
void owned_body_batches_select_a_named_query_preset() {
    TestEnvironment environment; Host host(environment, Side::client); auto& game = environment.fake;
    host.apply({script("preset-no-ray", R"(
        local ok,why=pcall(reskate.world.physics.probe_batch,{},{},{},{query_preset="terrain"})
        assert(not ok and why:find("world.raycast"))
        reskate.log("query preset without world.raycast denied")
    )", R"("world.physics")"), script("preset-batch", batch_main(R"(
        local fields={status=true,reason=true,native_casts=true,budget_exhausted=true,epoch=true,
            local_actor_excluded=true,owned_bodies_excluded=true,rays=true}
        local function shape(out,echo)
            local n=0
            for k in out do
                n+=1
                assert(fields[k] or (echo and k=="requested_query_preset"),"unexpected batch field "..tostring(k))
            end
            assert(n==(out.reason and 8 or 7)+(echo and 1 or 0),"batch field count "..n)
            assert(out.requested_query_preset==echo,"request echo "..tostring(out.requested_query_preset))
        end
        reskate.console.command("preset-default","",function()
            local out=P.probe_batch(h,epoch,rays(1))
            assert(out.status=="available") shape(out,nil)
            out=P.probe_batch(h,epoch,rays(1),{require_contact=false,exclude_local_actor=false})
            assert(out.status=="available") shape(out,nil)
        end)
        reskate.console.command("preset-hit","",function(args)
            local out=P.probe_batch(h,epoch,rays(2),{query_preset=args[1]})
            assert(out.status=="available" and out.native_casts==2 and not out.local_actor_excluded) shape(out,args[1])
            for _,r in out.rays do assert(r.status=="hit" and r.position==v(0,0,0) and r.fraction==.5 and r.motion=="unknown") end
        end)
        reskate.console.command("preset-clear","",function()
            local out=P.probe_batch(h,epoch,rays(1),{query_preset="terrain",require_contact=true})
            assert(out.status=="available") shape(out,"terrain")
            local r=out.rays[1]
            assert(r.status=="clear" and not r.position and not r.normal and not r.surface_velocity and not r.body and not r.motion)
        end)
        reskate.console.command("preset-refused","",function()
            local out=P.probe_batch(h,epoch,rays(1),{query_preset="terrain",exclude_local_actor=true})
            unavailable(out,"local_actor_exclusion_unavailable") shape(out,"terrain")
            assert(out.native_casts==0 and out.local_actor_excluded==false and out.owned_bodies_excluded==false)
        end)
        reskate.console.command("preset-contact","",function(args)
            local out=P.probe_batch(h,epoch,rays(1),{query_preset="terrain",require_contact=true})
            shape(out,"terrain")
            if args[1]=="missing" then unavailable(out,"contact_measurement_unavailable") return end
            local r=out.rays[1]
            assert(out.status=="available" and r.motion=="measured" and r.normal==v(0,1,0))
            assert(r.surface_velocity_available and r.surface_velocity==v(2,0,-1),"moving measured surface lost its velocity")
        end)
        reskate.console.command("preset-invalid","",function()
            for _,bad in {"Terrain","TERRAIN","static","","terrain"..string.char(0),"camera ",1,0,true,{},function() end} do
                assert(not pcall(P.probe_batch,h,epoch,rays(1),{query_preset=bad}),"preset "..tostring(bad))
            end
            assert(not pcall(P.probe_batch,h,epoch,rays(1),{query_mask=1}),"raw mask option")
            assert(not pcall(P.probe_batch,h,epoch,rays(1),{filter=1,query_preset="terrain"}),"raw filter beside a preset")
            assert(not pcall(P.probe_batch,h,epoch,rays(1),{query_presets="terrain"}),"misspelled option")
            assert(not pcall(P.probe_batch,h,{},rays(1),{query_preset="terrain"}),"forged epoch with a preset")
            assert(not pcall(P.probe_batch,other,epoch,rays(1),{query_preset="terrain"}),"another body's epoch with a preset")
            assert(not pcall(P.probe_batch,epoch,epoch,rays(1),{query_preset="terrain"}),"an epoch is not a body")
        end)
        reskate.log("query preset batches ready")
    )"), R"("world.physics","world.raycast","console")")});
    running(host, "preset-no-ray", environment); running(host, "preset-batch", environment);
    check(environment.logged("query preset without world.raycast denied") && environment.logged("query preset batches ready") &&
        !game.batch_calls, environment.all());
    check(host.run_console("preset-default") && game.batch_calls == 2 && game.last_batch.preset == body_query::QueryPreset::camera,
        "a batch without a preset changed its result fields or left camera\n" + environment.all());
    for (const auto preset : {body_query::QueryPreset::terrain, body_query::QueryPreset::camera}) {
        ticks(host, environment, 1); const auto calls = game.batch_calls;
        check(host.run_console(std::string("preset-hit ") + body_query::name(preset)) && game.batch_calls == calls + 1 &&
            game.last_batch.preset == preset, std::string("explicit preset did not reach the backend: ") + body_query::name(preset) + "\n" + environment.all());
    }
    ticks(host, environment, 1); game.batch_clear = true;
    check(host.run_console("preset-clear") && game.last_batch.preset == body_query::QueryPreset::terrain && game.last_batch.require_contact,
        "terrain clear invented geometry or lost its options\n" + environment.all());
    game.batch_clear = false;
    ticks(host, environment, 1); game.batch_refusal = body_query::Failure::local_actor_exclusion_unavailable;
    auto casts = game.native_casts;
    check(host.run_console("preset-refused") && game.last_batch.preset == body_query::QueryPreset::terrain &&
        game.last_batch.exclude_local_actor && game.native_casts == casts,
        "a terrain request echo became actor exclusion or spent a cast\n" + environment.all());
    game.batch_refusal = body_query::Failure::none;
    ticks(host, environment, 1);
    check(host.run_console("preset-contact missing"), "terrain admitted a hit without contact measurements\n" + environment.all());
    ticks(host, environment, 1); game.batch_contact_mode = 1;
    check(host.run_console("preset-contact measured") && game.last_batch.preset == body_query::QueryPreset::terrain,
        "terrain lost a measured moving contact\n" + environment.all());
    game.batch_contact_mode = 0;
    ticks(host, environment, 1); const auto calls = game.batch_calls; casts = game.native_casts;
    check(host.run_console("preset-invalid") && game.batch_calls == calls && game.native_casts == casts,
        "a rejected preset option reached the backend\n" + environment.all());
    // Another VM's owner or a stale generation is refused with a preset set, before any cast.
    auto request = game.last_batch; request.preset = body_query::QueryPreset::terrain;
    const auto owner = game.owned.at(1).owner; casts = game.native_casts;
    auto refused = game.body_probe_batch(owner + 1, {1,0}, request, 64);
    check(!refused.available && !refused.native_casts && game.native_casts == casts, "another VM's body was queried with a preset");
    refused = game.body_probe_batch(owner, {1,7}, request, 64);
    check(!refused.available && !refused.native_casts && game.native_casts == casts, "a stale body generation was queried with a preset");
}

void owned_body_batches_are_permissioned_opaque_and_transactional() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("batch-no-ray", R"(
        local ok,why=pcall(reskate.world.physics.probe_batch,{},{},{},{require_contact=true})
        assert(not ok and why:find("world.raycast"))
    )", R"("world.physics")"), script("batch-no-body", R"(
        local ok,why=pcall(reskate.world.physics.probe_batch,{},{},{},{require_contact=true})
        assert(not ok and why:find("world.physics"))
    )", R"("world.raycast")"), script("body-batch", batch_main(R"(
        local out=P.probe_batch(h,epoch,rays(2),{exclude_bodies={other,h},exclude_local_actor=true})
        assert(out.status=="available" and out.native_casts==2 and #out.rays==2 and not out.reason)
        assert(out.local_actor_excluded==false,"a request flag alone became an exclusion fact")
        local a,b=out.rays[1],out.rays[2]
        assert(a.status=="hit" and a.position==v(0,0,0) and a.fraction==.5 and a.motion=="unknown")
        assert(type(a.body)=="userdata" and getmetatable(a.body)=="locked" and a.body==b.body)
        assert(not a.normal and not a.velocity and not a.surface_velocity and not a.feature and not a.world)
        assert(not pcall(P.read,a.body) and not pcall(P.probe_batch,a.body,epoch,rays(1)),"hit identity is not an owned handle")
        assert(not pcall(P.probe_batch,h,{},rays(1)) and not pcall(P.probe_batch,other,epoch,rays(1)),"epoch transplant")
        local next=P.probe_batch(h,epoch,rays(1))
        assert(next.status=="available" and a.body~=next.rays[1].body,"body equality has only batch scope")
        assert(not pcall(P.probe_batch,h,epoch,{}) and not pcall(P.probe_batch,h,epoch,rays(33)),"batch bound")
        assert(not pcall(P.probe_batch,h,epoch,{ray,raw_pointer=123}),"array keys")
        assert(not pcall(P.probe_batch,h,epoch,{{from=ray.from,to=ray.to,normal=v(0,1,0)}}),"geometry policy input")
        assert(not pcall(P.probe_batch,h,epoch,{{from=ray.from,to=ray.from}}),"zero ray")
        assert(not pcall(P.probe_batch,h,epoch,{{from=ray.from,to=v(0/0,0,0)}}),"nonfinite ray")
        assert(not pcall(P.probe_batch,h,epoch,rays(1),{exclude_bodies={123}}),"raw native exclusion")
        assert(not pcall(P.probe_batch,h,epoch,rays(1),{exclude_bodies={[2]=other}}),"sparse exclusion")
        assert(not pcall(P.probe_batch,h,epoch,rays(1),{exclude_local_actor=1}),"boolean actor switch")
        assert(not pcall(P.probe_batch,h,epoch,rays(1),{native_world=1}),"no native world option")
        assert(not pcall(P.probe_batch,h,epoch,rays(1),{["exclude_bodies"..string.char(0).."raw"]={}}),"NUL option name")
        assert(not pcall(P.probe_batch,h,epoch,rays(1),{},{}),"extra arguments")
        assert(P.submit(h,epoch,{force=v(0,20,0)}),"query did not consume command epoch")
        local first=assert(P.receipt(h))
        assert(P.probe_batch(h,epoch,rays(1)).status=="available")
        local after=assert(P.receipt(h))
        assert(after.sequence==first.sequence and after.outcome=="queued" and not after.successor,"query consumed pending packet")
        reskate.console.command("batch-pending","",function()
            assert(P.probe_batch(h,epoch,rays(1)).status=="available")
        end)
        reskate.console.command("batch-excluded","",function()
            unavailable(P.probe_batch(h,epoch,rays(1),{exclude_bodies={other}}),"body_epoch_or_observation_changed")
            assert(P.receipt(h).sequence==first.sequence and P.receipt(h).outcome=="queued")
        end)
        reskate.log("owned batch API verified")
    )"), R"("world.physics","world.raycast","console")")});
    running(host, "batch-no-ray", environment); running(host, "batch-no-body", environment); running(host, "body-batch", environment);
    check(environment.logged("owned batch API verified") && environment.fake.batch_calls == 3, environment.all());
    auto& game = environment.fake; const auto mailbox = game.owned.at(1).mailbox;
    check(host.run_console("batch-pending"), "query while a packet is pending");
    const auto& after = game.owned.at(1).mailbox;
    check(after.pending && after.count == mailbox.count && after.sequence == mailbox.sequence && after.last_submitted == mailbox.last_submitted &&
        after.command.epoch == mailbox.command.epoch && after.oldest().outcome == mailbox.oldest().outcome && !after.oldest().successor_available,
        "read-only query changed command/receipt state");
    game.owned.at(2).sample.epoch.world = 78;
    const auto casts = game.native_casts; check(host.run_console("batch-excluded") && game.native_casts == casts, "foreign-world exclusion reached native query");
    auto request = game.last_batch;
    const auto owner = game.owned.at(1).owner;
    auto refused = game.body_probe_batch(owner + 1, {1,0}, request, 64);
    check(!refused.available && !refused.native_casts && game.native_casts == casts, "another VM adopted an owned exclusion/anchor");
    refused = game.body_probe_batch(owner, {1,7}, request, 64);
    check(!refused.available && !refused.native_casts && game.native_casts == casts, "stale handle generation/slot reached query");
    Game portable;
    check(!portable.body_probe_batch(1, {1,0}, {}, 64).available && !portable.world_probe_bounded({}, {}, 64).probe.available &&
        !portable.world_probe_bounded({}, {}, 64).native_casts && !portable.world_pick_bounded({}, {}, 64).native_casts,
        "portable backend fabricated collision or native calls");
}
void owned_body_batches_share_actual_and_logical_query_limits() {
    TestEnvironment environment; Host host(environment, Side::client); auto& game = environment.fake;
    game.body_list = {{9, {{1, {1, 0, 0}, {1, 2, 0}, .16f}}}};
    game.probe_result = {true, false}; game.query_cast_cost = environment.ray_cast_cost = 2;
    host.apply({script("batch-budget", batch_main(R"(
        local from,to=v(0,1,0),v(10,1,0)
        reskate.console.command("batch-mixed","",function()
            for i=1,4 do assert(reskate.world.probe(from,to).status=="clear") end
            for i=1,4 do assert(reskate.world.pick(from,to)) end
            for i=1,4 do assert(not reskate.world.raycast(from,to)) end
            assert(reskate.session.raycast(from,to))
            local batch=P.probe_batch(h,epoch,rays(19))
            assert(batch.status=="available" and batch.native_casts==38)
            unavailable(P.probe_batch(h,epoch,rays(1)),"native_cast_budget_exhausted")
            assert(reskate.world.probe(from,to).status=="unavailable" and not reskate.world.pick(from,to) and not reskate.world.raycast(from,to))
            assert(not reskate.session.raycast(from,to),"unavailable wall query cannot admit a player hit")
        end)
        reskate.console.command("batch-zero","",function()
            unavailable(P.probe_batch(h,epoch,rays(32)),"query_preconditions_unavailable")
            unavailable(P.probe_batch(h,epoch,rays(32)),"query_preconditions_unavailable")
            local ok,why=pcall(P.probe_batch,h,epoch,rays(1))
            assert(not ok and why:find("more than 64 raycasts"),"each input ray spends logical budget")
            assert(not pcall(reskate.world.probe,from,to) and not pcall(reskate.session.raycast,from,to,{world=false}))
        end)
        reskate.console.command("batch-partial","",function()
            for i=1,30 do reskate.world.probe(from,to) end
            reskate.world.raycast(from,to)
            local batch=P.probe_batch(h,epoch,rays(2))
            unavailable(batch,"native_cast_budget_exhausted")
            assert(batch.native_casts==3 and batch.budget_exhausted,"last allowed cast is counted")
        end)
        reskate.console.command("batch-once","",function(args)
            local batch=P.probe_batch(h,epoch,rays(2))
            unavailable(batch,args[1])
            if args[1]=="invalid_query_backend_result" or args[1]=="query_backend_exception" then
                assert(not batch.native_casts,"invalid backend count is not a measured count")
                unavailable(P.probe_batch(h,epoch,rays(1)),"native_cast_budget_exhausted")
            else assert(batch.native_casts==tonumber(args[2])) end
        end)
        reskate.console.command("batch-refusal-budget","",function()
            local batch=P.probe_batch(h,epoch,rays(2))
            unavailable(batch,"body_exclusions_unavailable")
            assert(batch.native_casts==0 and not batch.budget_exhausted)
            for i=1,32 do assert(reskate.world.probe(from,to).status=="clear") end
            assert(reskate.world.probe(from,to).status=="unavailable","zero-cast refusal must leave all 64 native casts")
        end)
        reskate.console.command("batch-clear","",function()
            local batch=P.probe_batch(h,epoch,rays(32))
            assert(batch.status=="available" and batch.native_casts==64)
            for _,r in batch.rays do assert(r.status=="clear" and not r.position and not r.body and not r.motion) end
        end)
        reskate.console.command("batch-unknown","",function()
            local batch=P.probe_batch(h,epoch,rays(1))
            assert(batch.status=="available" and batch.rays[1].status=="hit" and batch.rays[1].motion=="unknown" and not batch.rays[1].body)
        end)
        reskate.console.command("batch-expired","",function()
            unavailable(P.probe_batch(h,epoch,rays(1)),"body_epoch_or_observation_changed")
            assert(not P.submit(h,epoch,{}),"query must not relabel an expired epoch")
        end)
        reskate.console.command("batch-latest","",function(args)
            local pending
            if args[1]=="read" then
                assert(P.read(h).serial==sample.serial,"fixture keeps listener epoch")
            else
                pending=assert(P.receipt(h))
                assert(pending.outcome=="applied" and not pending.successor and pending.produced_serial==sample.serial,
                    "receipt refresh occurs while waiting for a later successor")
            end
            local out=P.probe_batch(h,epoch,rays(2))
            unavailable(out,"body_epoch_or_observation_changed")
            assert(out.native_casts==0,"new latest cannot rebind the immutable old sample")
            if pending then
                local after=assert(P.receipt(h,pending.sequence))
                assert(after.outcome=="applied" and not after.successor and after.produced_serial==pending.produced_serial)
            end
        end)
    )"), R"("world.physics","world.raycast","session.skaters","console")")});
    running(host, "batch-budget", environment);
    check(host.run_console("batch-mixed") && game.native_casts + environment.native_ray_casts == 64 && game.batch_calls == 1,
        "mixed existing APIs, session occlusion and batch escaped actual 64 calls\n" + environment.all());
    ticks(host, environment, 1); game.query_cast_cost = 0;
    auto before = game.batch_calls; auto casts = game.native_casts;
    check(host.run_console("batch-zero") && game.batch_calls == before + 2 && game.native_casts == casts, "zero-call unavailable batches escaped logical cap\n" + environment.all());
    ticks(host, environment, 1); game.batch_change_after = true;
    check(host.run_console("batch-once body_epoch_or_observation_changed 0") && game.native_casts == casts,
        "zero-cast precondition reason overrode the post-query observation fence\n" + environment.all());
    game.batch_change_after = false;
    for (const auto reason : {body_query::Failure::client_phase_unavailable, body_query::Failure::local_actor_exclusion_unavailable,
        body_query::Failure::body_exclusions_unavailable}) {
        ticks(host, environment, 1); game.batch_refusal = reason;
        casts = game.native_casts;
        check(host.run_console(std::string("batch-once ") + body_query::name(reason) + " " + std::to_string(game.batch_refusal_casts)) &&
            game.native_casts == casts + game.batch_refusal_casts && !game.owned.at(1).mailbox.pending &&
            !game.owned.at(1).mailbox.count && !game.owned.at(1).mailbox.failed && !game.body_submissions,
            "typed backend refusal was lost, invented geometry or mutated command state\n" + environment.all());
    }
    ticks(host, environment, 1); game.batch_refusal = body_query::Failure::body_exclusions_unavailable;
    game.query_cast_cost = 2; casts = game.native_casts;
    const bool refusal_budget_command = host.run_console("batch-refusal-budget");
    check(refusal_budget_command && game.native_casts == casts + 64 && !game.body_submissions,
        "known zero-cast exclusion refusal poisoned or spent the shared native allowance\n" + environment.all());
    for (const auto reason : {body_query::Failure::query_backend_exception, body_query::Failure::unavailable}) {
        ticks(host, environment, 1); game.batch_refusal = reason;
        game.batch_refusal_casts = 2; game.batch_refusal_accounting_valid = false;
        before = game.batch_calls; casts = game.native_casts;
        const auto expected = reason == body_query::Failure::query_backend_exception ? "query_backend_exception" : "invalid_query_backend_result";
        check(host.run_console(std::string("batch-once ") + expected + " 0") && game.batch_calls == before + 1 &&
            game.native_casts == casts + 2 && !game.owned.at(1).mailbox.pending && !game.owned.at(1).mailbox.count &&
            !game.owned.at(1).mailbox.failed && !game.body_submissions,
            "unknown catch accounting lost its reason, exposed a count or failed to close the remaining budget\n" + environment.all());
    }
    game.batch_refusal = body_query::Failure::none; game.batch_refusal_casts = 0; game.batch_refusal_accounting_valid = true;
    ticks(host, environment, 1); game.query_cast_cost = 2; environment.ray_cast_cost = 1;
    casts = game.native_casts + environment.native_ray_casts;
    check(host.run_console("batch-partial") && game.native_casts + environment.native_ray_casts == casts + 64, "partial batch retry overspent cap\n" + environment.all());
    ticks(host, environment, 1); game.batch_change_after = true;
    check(host.run_console("batch-once body_epoch_or_observation_changed 4"), "post-query fence did not discard whole batch\n" + environment.all());
    ticks(host, environment, 1); game.batch_change_after = false; game.batch_failure_ray = 1;
    check(host.run_console("batch-once query_unavailable 4"), "partial unavailable geometry escaped\n" + environment.all());
    ticks(host, environment, 1); game.batch_failure_ray = std::numeric_limits<unsigned>::max(); game.query_cast_cost = 3;
    check(host.run_console("batch-once ray_cast_limit_exhausted 2"), "per-ray two-cast bound waived\n" + environment.all());
    ticks(host, environment, 1); game.query_cast_cost = 2; game.batch_bad_count = true;
    before = game.batch_calls;
    check(host.run_console("batch-once invalid_query_backend_result 0") && game.batch_calls == before + 1, "malformed backend accounting did not close tick\n" + environment.all());
    ticks(host, environment, 1); game.batch_bad_count = false; game.batch_clear = true;
    check(host.run_console("batch-clear"), "all-clear full batch failed\n" + environment.all());
    ticks(host, environment, 1); game.batch_clear = false; game.batch_unqualified = true;
    check(host.run_console("batch-unknown"), "unknown BODY identity was fabricated\n" + environment.all());
    const auto canonical = game.last_batch.observation;
    auto& selected = game.owned.at(1);
    const auto sequence = game.body_command_sequence;
    for (unsigned field = 1; field <= 4; ++field) {
        ticks(host, environment, 1); selected.sample = selected.latest = canonical; game.batch_drift_field = field;
        check(host.run_console("batch-once body_epoch_or_observation_changed 4") && body_query::same_sample(selected.latest, canonical) &&
            selected.sample.epoch == canonical.epoch && !selected.mailbox.pending && !selected.mailbox.count && game.body_command_sequence == sequence,
            "same-epoch native pose/velocity drift escaped or query published its read-only observation\n" + environment.all());
    }
    game.batch_drift_field = 0;
    ticks(host, environment, 1); selected.sample = selected.latest = canonical; selected.sample.velocity[0] = .001f; casts = game.native_casts;
    check(host.run_console("batch-once body_epoch_or_observation_changed 0") && game.native_casts == casts && body_query::same_sample(selected.latest, canonical),
        "pre-query native drift was relabeled as a canonical same-epoch sample\n" + environment.all());
    for (const char* route : {"batch-latest read", "batch-latest receipt"}) {
        ticks(host, environment, 1); selected.sample = selected.latest = canonical; selected.sample.position[2] += .001f; casts = game.native_casts;
        const bool receipt = std::string_view(route).ends_with("receipt");
        if (receipt) {
            // Requested99 -> produced100 is applied but cannot be confirmed by another
            // serial100 observation. Receipt must still reread native pose and replace latest.
            owned_body::Command prior; prior.epoch = canonical.epoch; --prior.epoch.serial; prior.epoch.time -= prior.epoch.seconds;
            owned_body::Command applied;
            check(selected.mailbox.submit(prior, prior.epoch, 0, 1) && selected.mailbox.consume(canonical.epoch, 1, applied) &&
                selected.mailbox.finish(true, true, true) && selected.mailbox.needs_successor(), "applied/unmeasured receipt setup");
        }
        check(host.run_console(route) && game.native_casts == casts && body_query::same_sample(selected.latest, selected.sample) &&
            !body_query::same_sample(selected.latest, canonical) && selected.latest.epoch == canonical.epoch && selected.mailbox.count == (receipt ? 1u : 0u) &&
            (!receipt || (selected.mailbox.oldest().outcome == owned_body::Outcome::applied && !selected.mailbox.oldest().successor_available)),
            "same-epoch read/receipt latest replacement rebound an older immutable query token\n" + environment.all());
    }
    selected.sample = selected.latest = canonical;
    ticks(host, environment, 1); game.body_producer_step(); casts = game.native_casts;
    check(host.run_console("batch-expired") && game.native_casts == casts && game.body_submissions == 0, "expired query mutated command admission\n" + environment.all());
    running(host, "batch-budget", environment);
}

void a_plugin_loads_ticks_runs_its_commands_and_unloads() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("hello", R"(
        local ticks = 0
        reskate.on("load", function() reskate.log("loaded " .. reskate.id .. " api " .. reskate.api_version) end)
        reskate.on("tick", function(dt) ticks += 1 end)
        reskate.on("unload", function() reskate.log("bye after " .. ticks) end)
        reskate.console.command("hello there", "Says hello", function(args)
            reskate.console.print("hello " .. table.concat(args, ",") .. " after " .. ticks)
        end)
        print("printed", 1, true)
        reskate.console.command("greet", "Greets", function(args) reskate.console.print("greet " .. (args[1] or "")) end,
            {{name = "loud", args = "[name]", help = "Greets loudly"}, {name = "soft"}})
        assert(not pcall(reskate.console.command, "bad", "x", function() end, {{name = "Two Words"}}), "a subcommand is one word")
    )", R"("console")")});
    running(host, "hello", environment);
    check(environment.logged("[hello] loaded hello api 1"), "The load handler ran\n" + environment.all());
    check(environment.logged("[hello] printed\t1\ttrue"), "print goes to the log");
    ticks(host, environment, 3);
    check(host.run_console("hello there a b"), "Its command runs");
    check(environment.printed("hello a,b after 3"), "with its arguments, after its ticks");
    check(host.run_console("HELLO There"), "whatever the case");
    check(!host.run_console("nothing here"), "and other text is left to ReSkate");
    check(status_of(host, "hello").commands.size() == 4, "Its commands are listed, with the subcommands one declared");
    {
        const auto commands = status_of(host, "hello").commands;
        check(std::any_of(commands.begin(), commands.end(),
                          [](const auto& c) { return c.name == "greet loud" && c.args == "[name]" && c.help == "Greets loudly"; }),
              "A subcommand is listed with its arguments and help");
    }
    check(host.run_console("greet loud") && environment.printed("greet loud"), "and its command's function runs it");
    host.apply({});
    check(environment.logged("[hello] bye after 3"), "Unloading runs its unload handler");
    check(host.status().empty(), "and it is gone");
    check(!host.run_console("hello there"), "with its command");
}

void a_permission_must_be_declared() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("bare", R"(
        local ok, err = pcall(reskate.console.command, "x", "x", function() end)
        assert(not ok and err:find("needs the \"console\" permission"), err)
        ok, err = pcall(reskate.storage.get, "x")
        assert(not ok and err:find("needs the \"storage\" permission"), err)
        -- A mod's variants are read freely, but choosing one (which loads the level again) is asked for.
        assert(reskate.package.variants() == nil, "a mod without variants has none")
        ok, err = pcall(reskate.package.choose, "wide")
        assert(not ok and err:find("needs the \"variants\" permission"), err)
        ok, err = pcall(reskate.tricks.label, "Board Stall", "Rock to Fakie")
        assert(not ok and err:find("needs the \"hud\" permission"), err)
        ok, err = pcall(reskate.tricks.record_as, {9}, 187, 100)
        assert(not ok and err:find("needs the \"skater.control\" permission"), err)
        ok, err = pcall(reskate.mods.content, "parks")
        assert(not ok and err:find("needs the \"mods.read\" permission"), err)
        ok, err = pcall(reskate.board.set_parameter, "grip", "graphic", {r = 1, g = 0, b = 0})
        assert(not ok and err:find("needs the \"board\" permission"), err)
        ok, err = pcall(reskate.board.parameters, "deck")
        assert(not ok and err:find("needs the \"board\" permission"), err)
        reskate.console.print("never")
    )")});
    stopped(host, "bare", "raised an error");
    check(environment.logged("needs the \"console\" permission"), "The error names the permission\n" + environment.all());
}

void command_names_are_checked() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("first", R"(
        reskate.console.command("dom start", "Starts", function() end)
        assert(not pcall(reskate.console.command, "perf mine", "x", function() end), "ReSkate's own")
        assert(not pcall(reskate.console.command, "plugin mine", "x", function() end), "the plugin command")
        assert(not pcall(reskate.console.command, "Bad Name", "x", function() end), "uppercase")
        assert(not pcall(reskate.console.command, "a b c d", "x", function() end), "four words")
        assert(not pcall(reskate.console.command, "dom start", "x", function() end), "twice")
    )", R"("console")"),
        script("second", R"(
        local ok, err = pcall(reskate.console.command, "dom", "x", function() end)
        assert(not ok and err:find("first"), err)
        reskate.console.command("other", "x", function() end)
    )", R"("console")")});
    running(host, "first", environment);
    running(host, "second", environment);
}

void storage_is_kept_across_loads_and_has_a_quota() {
    TestEnvironment environment;
    Limits limits;
    limits.storage_bytes = 300;
    std::filesystem::remove_all(scratch / "storage" / "keeper");
    const auto keeper = script("keeper", R"(
        local runs = reskate.storage.add("runs")
        reskate.storage.set("table", {a = 1, list = {1, 2, 3}, name = "x"})
        local back = reskate.storage.get("table")
        assert(back.a == 1 and back.list[3] == 3 and back.name == "x")
        reskate.storage.set("gone", true)
        reskate.storage.set("gone", nil)
        assert(reskate.storage.get("gone") == nil)
        local ok, err = pcall(reskate.storage.set, "big", string.rep("x", 1000))
        assert(not ok and err:find("full"), err)
        assert(reskate.storage.get("big") == nil)
        assert(not pcall(reskate.storage.set, "f", print), "a function is not JSON")
        assert(not pcall(reskate.storage.set, "", 1), "an empty key")
        local cycle = {} cycle.me = cycle
        assert(not pcall(reskate.storage.set, "c", cycle), "a cycle")
        reskate.log("runs " .. runs)
    )", R"("storage")");
    {
        Host host(environment, Side::client, limits);
        host.apply({keeper});
        running(host, "keeper", environment);
        host.apply({});
        host.apply({keeper});
        running(host, "keeper", environment);
    }
    check(environment.logged("[keeper] runs 1") && environment.logged("[keeper] runs 2"), "Storage is kept from one load to the next\n" + environment.all());
    check(std::filesystem::exists(scratch / "storage" / "keeper" / "storage.json"), "in the plugin's own file");
}

void packages_json_and_modules() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("modules", {
        {manifest_file, manifest()},
        {"data/parks.json", R"({"parks": [{"name": "bowl", "spots": 3}]})"},
        {"data/notes.txt", "hello"},
        {"plugin/lib/util.lua", "loads = (loads or 0) + 1\nreturn {double = function(x) return x * 2 end}"},
        {"plugin/rules.luau", "return {name = 'rules'}"},
        {"plugin/cycle_a.lua", "return require('cycle_b')"},
        {"plugin/cycle_b.lua", "return require('cycle_a')"},
        {"plugin/main.lua", R"(
            assert(reskate.package.read("data/notes.txt") == "hello")
            assert(reskate.package.read("data/missing.txt") == nil)
            local parks = reskate.package.read_json("data/parks.json")
            assert(parks.parks[1].name == "bowl" and parks.parks[1].spots == 3)
            local listing = table.concat(reskate.package.list("data"), ",")
            assert(listing == "notes.txt,parks.json", listing)
            assert(table.concat(reskate.package.list(), ","):find("plugin/"), "folders end in /")
            for _, bad in {"../x", "/x", "C:/x", "data\\notes.txt", "data/../../x"} do
                assert(not pcall(reskate.package.read, bad), bad)
            end
            local util = require("./lib/util")
            assert(util.double(4) == 8)
            assert(require("lib/util") == util and loads == 1, "a module runs once")
            assert(require("rules").name == "rules", ".luau too")
            local ok, err = pcall(require, "cycle_a")
            assert(not ok and err:find("requires itself"), err)
            assert(not pcall(require, "missing"))
            assert(not pcall(require, "../data/notes"))
            local text = reskate.json.encode({a = {1, 2}, b = "x", c = true})
            local back = reskate.json.decode(text)
            assert(back.a[2] == 2 and back.b == "x" and back.c == true, text)
            assert(not pcall(reskate.json.decode, "{nope"))
            assert(not pcall(reskate.json.encode, {[{}] = 1}))
            assert(not pcall(reskate.json.encode, 0/0))
            reskate.log("modules fine")
        )"}})});
    running(host, "modules", environment);
    check(environment.logged("modules fine"), "Packages, JSON and modules work\n" + environment.all());
}

// What a plugin must not be able to reach or change. Each line checks one way out.
void the_sandbox_holds() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("escape", R"(
        assert(io == nil and package == nil and dofile == nil and loadfile == nil, "no files")
        assert(loadstring == nil and load == nil, "no loading code, bytecode or text")
        assert(os.execute == nil and os.remove == nil and os.rename == nil and os.getenv == nil and os.exit == nil, "no os")
        assert(not pcall(function() reskate.log = nil end), "reskate is read only")
        assert(not pcall(function() reskate.storage.get = print end), "and its tables")
        assert(not pcall(rawset, reskate, "x", 1), "even by rawset")
        assert(not pcall(setmetatable, reskate, {}), "or a metatable")
        assert(not pcall(function() string.rep = nil end), "the libraries are read only")
        assert(not pcall(function() getmetatable("").__index = {} end), "and the string metatable")
        assert(not pcall(function() _G.print = nil end) or print ~= nil, "print stays")
        mine = 1
        assert(mine == 1, "its own globals work")
        local function deep(n) return deep(n + 1) + 1 end
        assert(not pcall(deep, 1), "endless recursion is an error, not a crash")
        assert(not pcall(require, "C:/Windows/win.ini"))
        assert(not pcall(reskate.package.read, "../../../Windows/win.ini"))
        assert(not pcall(reskate.time.after, -1, print))
        assert(not pcall(reskate.time.every, 0, print))
        assert(not pcall(reskate.on, "made_up", print))
        assert(not pcall(reskate.log, "x", "loud"))
        reskate.log("sandbox fine")
    )")});
    running(host, "escape", environment);
    check(environment.logged("sandbox fine"), "Every way out is closed\n" + environment.all());
}

void a_runaway_plugin_is_stopped_and_the_rest_go_on() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    const auto start = std::chrono::steady_clock::now();
    host.apply({
        script("bystander", R"(local n = 0 reskate.on("tick", function() n += 1 if n == 30 then reskate.log("bystander ticked 30") end end))"),
        script("loop", "while true do end"),
        script("catches", "while true do pcall(function() while true do end end) end"),
        script("tick_loop", R"(reskate.on("tick", function() while true do end end))"),
        script("memory", R"(local t = {} while true do t[#t + 1] = string.rep("x", 8000000) end)"),
        script("memory_caught", R"(
            pcall(function() local t = {} while true do t[#t + 1] = string.rep("y", 8000000) end end)
            reskate.log("survived the memory bomb")
        )"),
        script("huge", R"(local s = string.rep("x", 100000000))"),
        script("buffer", R"(local b = buffer.create(1e9))"),
        script("errors", R"(reskate.on("tick", function() error("boom") end))"),
        script("timers", R"(
            local ok, err = pcall(function() for i = 1, 2000 do reskate.time.after(1000, function() end) end end)
            assert(not ok and err:find("timers"), err)
            reskate.log("timers capped")
        )"),
        script("chatty", R"(for i = 1, 1000 do reskate.log("line " .. i) end)"),
        script("coroutines", R"(while true do coroutine.wrap(function() end)() end)"),
        script("slow_unload", R"(reskate.on("unload", function() while true do end end))"),
    });
    for (const auto* id : {"loop", "catches"}) stopped(host, id, "ran longer than 50 ms");
    stopped(host, "coroutines", ""); // its time or its memory, whichever runs out first
    for (const auto* id : {"memory", "memory_caught", "huge", "buffer"}) stopped(host, id, "more than 64 MB");
    check(!environment.logged("survived the memory bomb"), "A memory bomb cannot be caught and carried on from");
    running(host, "tick_loop", environment);
    ticks(host, environment, 1);
    stopped(host, "tick_loop", "the tick handler ran longer than 50 ms");
    check(environment.logged("[tick_loop] stopped: the tick handler"), "A stop is logged, which the console shows");
    ticks(host, environment, 4); // five errors, with the tick above
    running(host, "errors", environment);
    ticks(host, environment, 1);
    stopped(host, "errors", "more than 5 errors");
    running(host, "timers", environment);
    check(environment.logged("timers capped"), "Timers have a limit");
    const auto chatty = std::count_if(environment.logs.begin(), environment.logs.end(),
        [](const auto& line) { return line.starts_with("[chatty] line "); });
    check(chatty == 50, "50 lines a second, and the rest left out: " + std::to_string(chatty));
    ticks(host, environment, 30);
    running(host, "bystander", environment);
    check(environment.logged("bystander ticked 30"), "The others go on ticking");
    const auto unloading = std::chrono::steady_clock::now();
    host.apply({});
    const auto unload_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - unloading).count();
    check(unload_ms < 500, "An unload handler that never ends is cut off: " + std::to_string(unload_ms) + " ms");
    const auto total = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    check(total < 20, "and none of it hangs the host: " + std::to_string(total) + " s");
}

void a_plugin_over_its_time_budget_is_stopped() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("busy", R"(reskate.on("tick", function() local s = os.clock() while os.clock() - s < 0.004 do end end))"),
        script("light", R"(reskate.on("tick", function() local s = 0 for i = 1, 100 do s += i end end))")});
    ticks(host, environment, 60 * 5);
    stopped(host, "busy", "ms a tick for 3 s");
    running(host, "light", environment);
}

// The plugin time budget the player picks in the launcher (Engine/Core/Platform/plugin_time_budget.h):
// what the game is handed, parsed the way the game parses it. Reading the variable itself is tested
// with launcher::plugin_tick_ms in Launcher/Test/launch_options_tests.cpp.
void the_plugin_time_budget_setting_parses() {
    namespace budget = dingosdk::plugin_time_budget;
    check(budget::default_ms == 2 && Limits{}.tick_ms == budget::default_ms, "The budget is 2 ms a tick unless the player picks another");
    for (const int ms : budget::choices_ms) {
        check(budget::parse(std::to_string(ms)) == ms, "Each choice parses: " + std::to_string(ms));
        check(budget::parse(std::to_wstring(ms)) == ms, "as the game's variable too: " + std::to_string(ms));
    }
    check(budget::choices_ms.front() == 2 && budget::choices_ms.back() == 6, "The choices run from 2 to 6 ms");
    for (const std::string_view bad : {"", "0", "1", "7", "10", "60", "-2", "2.5", " 3", "3 ", "3ms", "x", "999"})
        check(!budget::parse(bad), "Not a choice, so refused: \"" + std::string(bad) + "\"");
}

void the_chosen_budget_reaches_every_plugin() {
    check(game_limits(4).tick_ms == 4 && game_limits(6).tick_ms == 6, "The game's limits carry the chosen budget");
    for (const int bad : {0, 1, 7, 100, -6})
        check(game_limits(bad).tick_ms == 2, "and a budget off the list is the default, never more: " + std::to_string(bad));
    const Limits defaults;
    check(game_limits(6).call_ms == defaults.call_ms && game_limits(6).over_windows == defaults.over_windows &&
          game_limits(6).memory == defaults.memory, "Only the tick budget changes");
    check(game_limits(2).tick_setting.find("Plugin time budget") != std::string::npos, "The game names where it is changed");
    check(defaults.tick_setting.empty(), "and a host where nobody can change it names nothing");

    TestEnvironment environment;
    Host host(environment, Side::client, game_limits(4));
    check(host.tick_budget_ms() == 4, "The host has the budget");
    // A plugin has no way to its own: a budget in its manifest is not read, and it has no environment.
    host.apply({script("first", R"(reskate.on("tick", function() end))"), script("second", "local x = 1"),
        package("greedy", {{manifest_file, R"({"api": 1, "entry": "plugin/main.lua", "tick_ms": 6, "limits": {"tick_ms": 6}})"},
            {"plugin/main.lua", R"(assert(os.getenv == nil, "no environment") reskate.log("greedy loaded"))"}})});
    for (const auto* id : {"first", "second", "greedy"}) {
        running(host, id, environment);
        check(status_of(host, id).tick_budget_ms == 4, std::string("Every plugin gets the host's budget as it loads: ") + id);
    }
    check(environment.logged("greedy loaded"), "The greedy plugin ran\n" + environment.all());

    TestEnvironment standard;
    Host default_host(standard, Side::client);
    default_host.apply({package("greedy", {{manifest_file, R"({"api": 1, "entry": "plugin/main.lua", "tick_ms": 6})"},
        {"plugin/main.lua", "local x = 1"}})});
    check(status_of(default_host, "greedy").tick_budget_ms == 2, "and its manifest does not raise it");
}

void a_plugin_over_the_chosen_budget_is_stopped_and_one_under_it_is_not() {
    // About 3.5 ms a tick, as plugins that drive a body's physics measured in game; and 4.5 ms.
    const auto busy = [](const std::string& id, double ms) {
        return script(id, std::format(R"(reskate.on("tick", function() local s = os.clock() while os.clock() - s < {} do end end))", ms / 1000));
    };
    const auto light = [] { return script("light", R"(reskate.on("tick", function() local s = 0 for i = 1, 100 do s += i end end))"); };
    {
        TestEnvironment environment;
        Host host(environment, Side::client, game_limits(6));
        host.apply({busy("physics", 3.5), light()});
        ticks(host, environment, 60 * 5);
        running(host, "physics", environment);
        running(host, "light", environment);
        const auto measured = status_of(host, "physics").tick_ms;
        std::cout << std::format("physics: {:.3f} ms a tick, under a 6 ms budget\n", measured);
        check(measured > 3 && measured < 6, "Its measured time is shown against the budget: " + std::to_string(measured));
    }
    {
        TestEnvironment environment;
        Host host(environment, Side::client, game_limits(3));
        host.apply({busy("heavy", 4.5), light()});
        ticks(host, environment, 60 * 5);
        stopped(host, "heavy", "over the plugin time budget of 3 ms");
        stopped(host, "heavy", "(change it in the launcher: Settings, GAME, Plugin time budget)");
        running(host, "light", environment);
        check(environment.logged("[heavy] stopped: it took"), "The stop is logged with its reason\n" + environment.all());
    }
    {
        TestEnvironment environment;
        Host host(environment, Side::client, game_limits(dingosdk::plugin_time_budget::default_ms));
        host.apply({busy("physics", 3.5), light()});
        ticks(host, environment, 60 * 5);
        stopped(host, "physics", "over the plugin time budget of 2 ms");
        running(host, "light", environment);
    }
}

void a_plugin_reloads_when_its_files_change() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("live", R"(reskate.log("version 1") reskate.on("unload", function() reskate.log("unloading 1") end))")});
    running(host, "live", environment);
    auto changed = script("live", R"(reskate.log("version 2"))");
    changed.fingerprint = "2";
    host.apply({changed});
    check(environment.logged("unloading 1") && environment.logged("version 2"), "A changed plugin unloads and loads again\n" + environment.all());
    host.apply({changed});
    check(std::count_if(environment.logs.begin(), environment.logs.end(), [](const auto& line) { return line.find("version 2") != std::string::npos; }) == 1,
        "and an unchanged one is left alone");
    check(host.switch_off("live").find("switched off") != std::string::npos, "It can be switched off by hand");
    check(status_of(host, "live").state == "switched off", "and stays off");
    changed.fingerprint = "3";
    host.apply({changed});
    check(status_of(host, "live").state == "switched off", "even when its files change");
    check(host.switch_on("live").find("started") != std::string::npos, "until it is switched on");
    running(host, "live", environment);
    check(host.reload("live").find("reloaded") != std::string::npos, "and reloaded by hand");
    check(host.reload("nobody").starts_with("error: "), "A plugin that is not there cannot be");
}

void plugins_distinguish_clear_unavailable_and_hit_world_probes() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("bare-probe", R"(
        local ok, why = pcall(reskate.world.probe, vector.create(1, 2, 3), vector.create(1, -2, 3))
        assert(not ok and why:find("world.raycast"), tostring(why))
        reskate.log("probe permission refused")
    )"), script("surface", R"(
        local from, to = vector.create(1, 2, 3), vector.create(1, -2, 3)
        local function fields(result)
            for key in pairs(result) do
                assert(key == "status" or key == "position" or key == "fraction", "no unqualified native fields")
            end
            assert(result.normal == nil and result.surface_velocity == nil and result.world == nil and result.body == nil)
        end
        reskate.console.command("surface", "x", function(args)
            local result = reskate.world.probe(from, to)
            fields(result)
            assert(result.status == args[1], "distinct probe status: " .. result.status)
            if result.status == "hit" then
                assert(result.position == vector.create(1, 0, 3) and result.fraction == 0.5, "actual hit fields")
            else
                assert(result.position == nil and result.fraction == nil, "only hits carry geometry")
            end
            reskate.log("surface " .. args[1])
        end)
        reskate.console.command("surface-bad", "x", function()
            assert(not pcall(reskate.world.probe, vector.create(0/0, 0, 0), to), "NaN")
            assert(not pcall(reskate.world.probe, from, vector.create(math.huge, 0, 0)), "infinity")
            assert(not pcall(reskate.world.probe, vector.create(100001, 0, 0), to), "outside map bounds")
            assert(not pcall(reskate.world.probe, {1, 2, 3}, to), "a vector is required")
            assert(not pcall(reskate.world.probe, vector.create(0, 0, 0), vector.create(1001, 0, 0)), "ray length")
            assert(not pcall(reskate.world.probe, from, to, 1234), "no native handle or exclusion argument")
            local empty = reskate.world.probe(from, from)
            assert(empty.status == "unavailable" and empty.position == nil and empty.fraction == nil, "zero length is not clear")
            reskate.log("bad probe inputs refused")
        end)
        reskate.console.command("surface-budget", "x", function()
            for i = 1, 32 do reskate.world.probe(from, to) end
            for i = 1, 16 do reskate.world.raycast(from, to) end
            for i = 1, 16 do reskate.world.pick(from, to) end
            local ok, why = pcall(reskate.world.probe, from, to)
            assert(not ok and why:find("more than 64 raycasts"), "one shared query budget")
            assert(not pcall(reskate.world.raycast, from, to) and not pcall(reskate.world.pick, from, to), "old APIs share the cap")
            reskate.log("probe shared budget refused")
        end)
    )", R"("console", "world.raycast")")});
    running(host, "bare-probe", environment);
    running(host, "surface", environment);
    auto& game = environment.fake;
    check(game.probes == 0 && environment.logged("probe permission refused"), "Permission denial never reaches the backend");
    check(host.run_console("surface unavailable"), "The default backend is unavailable");
    game.probe_result = {true, false, {std::numeric_limits<float>::quiet_NaN(), 0, 0}, std::numeric_limits<float>::infinity()};
    check(host.run_console("surface clear"), "A successful miss stays distinct and exposes no hit fields");
    game.probe_result = {true, true, {1, 0, 3}, 0.5f};
    check(host.run_console("surface hit") && game.probe_from == Vec3{1, 2, 3} && game.probe_to == Vec3{1, -2, 3},
          "The actual segment and hit pass through the generic Game method");
    const float nan = std::numeric_limits<float>::quiet_NaN(), inf = std::numeric_limits<float>::infinity();
    const Game::WorldProbe malformed[] = {
        {true, true, {nan, 0, 3}, .5f}, {true, true, {inf, 0, 3}, .5f},
        {true, true, {1, 0, 3}, nan}, {true, true, {1, 0, 3}, inf},
        {true, true, {1, 0, 3}, -.1f}, {true, true, {1, 0, 3}, 1.1f},
        {true, true, {2, 0, 3}, .5f}, {true, true, {100001, 0, 3}, .5f},
    };
    for (const auto& value : malformed) {
        game.probe_result = value;
        check(host.run_console("surface unavailable"), "Malformed backend hits are unavailable, not clear or geometry");
    }
    const auto before_bad = game.probes;
    check(host.run_console("surface-bad") && environment.logged("bad probe inputs refused") && game.probes == before_bad,
          "Invalid and zero-length inputs never reach the native query adapter");
    ticks(host, environment, 1);
    const auto before_budget = game.probes;
    const auto rays_before = environment.rays;
    const auto picks_before = game.world_picks;
    check(host.run_console("surface-budget") && environment.logged("probe shared budget refused") && game.probes == before_budget + 32 &&
          environment.rays == rays_before + 16 && game.world_picks == picks_before + 16,
          "All three APIs spend the same64-call budget and refused calls never reach their backend");
    ticks(host, environment, 1);
    game.probe_result = {};
    check(host.run_console("surface unavailable") && game.probes == before_budget + 33, "A new tick renews the query budget");
    running(host, "surface", environment);
}

void the_skater_can_be_read_moved_and_the_world_probed() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("bare", R"(
        local ok, err = pcall(reskate.skater.get)
        assert(not ok and err:find("skater.read"), err)
        ok, err = pcall(reskate.skater.teleport, vector.create(0, 0, 0))
        assert(not ok and err:find("skater.teleport"), err)
        ok, err = pcall(reskate.world.raycast, vector.create(0, 1, 0), vector.create(0, -1, 0))
        assert(not ok and err:find("world.raycast"), err)
        reskate.log("bare refused")
    )"), script("mover", R"(
        reskate.console.command("probe", "x", function()
            local s = reskate.skater.get()
            if not s then reskate.log("no skater") return end
            reskate.log(string.format("at %.1f %.1f %.1f facing %.2f speed %.1f up %.1f air %s %.1f", s.position.x, s.position.y,
                s.position.z, s.heading, s.speed, s.vertical_speed, tostring(s.airborne), s.air_time))
            assert(reskate.skater.position() == s.position and reskate.skater.heading() == s.heading)
            assert(reskate.skater.speed() == s.speed and reskate.skater.on_ground() == not s.airborne)
            local hit = reskate.world.raycast(s.position + vector.create(0, 2, 0), s.position - vector.create(0, 5, 0))
            assert(hit and math.abs(hit.y) < 0.01, "the ground under the skater")
            assert(reskate.world.raycast(vector.create(0, 5, 0), vector.create(0, 1, 0)) == nil, "a clear ray")
        end)
        reskate.console.command("move", "x", function(args)
            local ok, why = reskate.skater.teleport(vector.create(10, 0, 20), args[1] and tonumber(args[1]) or nil)
            reskate.log("teleport " .. tostring(ok) .. " " .. tostring(why))
        end)
        reskate.console.command("bad", "x", function()
            assert(not pcall(reskate.skater.teleport, vector.create(0 / 0, 0, 0)), "NaN")
            assert(not pcall(reskate.skater.teleport, vector.create(1e7, 0, 0)), "far away")
            assert(not pcall(reskate.skater.teleport, {1, 2, 3}), "a table is not a vector")
            assert(not pcall(reskate.skater.teleport, vector.create(0, 0, 0), 0 / 0), "a NaN heading")
            assert(not pcall(reskate.world.raycast, vector.create(0, 0, 0), vector.create(2000, 0, 0)), "too long")
            reskate.log("bad refused")
        end)
        reskate.console.command("rays", "x", function()
            local count = 0
            local ok, err = pcall(function()
                for i = 1, 100 do reskate.world.raycast(vector.create(0, 1, 0), vector.create(0, -1, 0)) count += 1 end
            end)
            reskate.log("rays " .. count .. " " .. tostring(err):match("more than %d+ raycasts") or "")
        end)
    )", R"("console", "skater.read", "skater.teleport", "world.raycast")")});
    running(host, "bare", environment);
    check(environment.logged("bare refused"), "Each needs its permission\n" + environment.all());
    host.run_console("probe");
    check(environment.logged("[mover] no skater"), "Without a skater there is nothing to read");
    host.run_console("move");
    check(environment.logged("teleport false teleporting is unavailable"), "nor to move");
    environment.local_skater = SkaterState{{1, 0, 2}, 1.5f, 4, 0.5f, true, 0.25f};
    host.run_console("probe");
    check(environment.logged("at 1.0 0.0 2.0 facing 1.50 speed 4.0 up 0.5 air true 0."), "The skater is read\n" + environment.all());
    running(host, "mover", environment);
    host.run_console("move 0.5");
    check(environment.teleports.size() == 1 && environment.teleports[0].first == Vec3{10, 0, 20} &&
          std::abs(environment.teleports[0].second - 0.5f) < 1e-6f, "A teleport is sent where it was asked");
    environment.now += 1000;
    host.run_console("move");
    check(environment.teleports.size() == 2 && std::abs(environment.teleports[1].second - 1.5f) < 1e-6f, "facing as the skater does by default");
    host.run_console("move");
    host.run_console("move");
    check(environment.teleports.size() == 3 && environment.logged("asked more than twice in a second"), "Two a second");
    environment.now += 1000;
    environment.teleport_forbidden = true;
    host.run_console("move");
    check(environment.logged("the host has turned teleporting off"), "and none when the host says no");
    host.run_console("bad");
    check(environment.logged("bad refused"), "Bad positions are refused\n" + environment.all());
    ticks(host, environment, 1); // the count is per tick: the probes above used two
    host.run_console("rays");
    check(environment.logged("rays 64 more than 64 raycasts"), "64 raycasts a tick\n" + environment.all());
    ticks(host, environment, 1);
    host.run_console("probe");
    running(host, "mover", environment);
}

void tricks_reach_plugins_that_ask_for_them() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("bare", R"(
        local ok, err = pcall(reskate.on, "trick_landed", function() end)
        assert(not ok and err:find("events.tricks"), err)
        ok, err = pcall(reskate.score.current)
        assert(not ok and err:find("events.tricks"), err)
        reskate.log("bare refused")
    )")});
    check(environment.logged("bare refused") && !host.wants_tricks(), "Tricks need events.tricks, and none is read without it");
    host.apply({script("bare", "reskate.log('bare')"), script("tricks", R"(
        reskate.on("trick_started", function(e) reskate.log(string.format("started at %.0f %.0f %.0f", e.at.x, e.at.y, e.at.z)) end)
        reskate.on("trick_landed", function(e)
            reskate.log(string.format("landed %.0f x%.1f from %.0f to %.0f in %.0f ms", e.points, e.multiplier, e.started_at.x, e.landed_at.x, e.ms))
        end)
        reskate.on("line_broken", function(e) reskate.log("broken by a " .. e.reason) end)
        reskate.console.command("score", "x", function()
            local s = reskate.score.current()
            reskate.log(s and string.format("score %.0f x%.1f %s", s.line, s.multiplier, tostring(s.in_trick)) or "no score")
        end)
    )", R"("console", "events.tricks")")});
    check(host.wants_tricks(), "With a plugin that has events.tricks, tricks are read");
    TrickNews started;
    started.started_at = {1, 2, 3};
    host.trick(started);
    TrickNews landed;
    landed.kind = TrickNews::Kind::landed;
    landed.points = 250;
    landed.multiplier = 2;
    landed.started_at = {1, 2, 3};
    landed.landed_at = {9, 2, 3};
    landed.ms = 1200;
    host.trick(landed);
    TrickNews broken;
    broken.kind = TrickNews::Kind::broken;
    broken.reason = "slam";
    host.trick(broken);
    check(environment.logged("[tricks] started at 1 2 3") && environment.logged("[tricks] landed 250 x2.0 from 1 to 9 in 1200 ms") &&
          environment.logged("[tricks] broken by a slam"), "Each trick event reaches it, with its values\n" + environment.all());
    host.run_console("score");
    environment.score_now = ScoreState{708, 2, true};
    host.run_console("score");
    check(environment.logged("[tricks] no score") && environment.logged("[tricks] score 708 x2.0 true"), "and the score HUD as it is");
    running(host, "tricks", environment);
}

void plugins_draw_pictures() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    const std::string main = R"(
        reskate.on("draw", function(d)
            d:image("icons/flag.png", vector.create(0, 0, 0), vector.create(64, 64, 0), {colour = 0xffffff80})
            d:world_image("icons/flag.png", vector.create(0, 2, -10), 1.5, {uv = {0, 0, 0.5, 0.25}})
            assert(not pcall(d.image, d, "icons/flag.png", vector.create(0, 0, 0), vector.create(1, 1, 0), {uv = {0, 0, 2, 1}}), "uv 0 to 1")
            assert(not pcall(d.image, d, "notes.txt", vector.create(0, 0, 0), vector.create(1, 1, 0)), "only pictures")
            assert(not pcall(d.image, d, "../other/flag.png", vector.create(0, 0, 0), vector.create(1, 1, 0)), "only its own package")
            assert(not pcall(d.image, d, "icons/missing.png", vector.create(0, 0, 0), vector.create(1, 1, 0)), "only files there")
            assert(not pcall(d.world_image, d, "icons/flag.png", vector.create(0, 0, 0), -1), "a height")
            reskate.log("drew")
        end)
    )";
    host.apply({package("pictures", {{manifest_file, manifest(R"("overlay")")}, {"plugin/main.lua", main}, {"icons/flag.png", "not really a png"},
                                     {"notes.txt", "x"}})});
    ticks(host, environment, 1);
    running(host, "pictures", environment);
    check(environment.logged("[pictures] drew") && environment.layers.size() == 1 && environment.layers[0].shapes.size() == 2,
          "A plugin draws pictures from its package\n" + environment.all());
    const auto& picture = environment.layers[0].shapes[0];
    check(picture.kind == plugin_ui::Shape::Kind::image && picture.text.ends_with("flag.png") && picture.style.colour == 0x80ffffff,
          "as the picture's file, tinted");
    check(environment.layers[0].shapes[1].kind == plugin_ui::Shape::Kind::world_image && environment.layers[0].shapes[1].radius == 1.5f &&
              environment.layers[0].shapes[1].style.uv[2] == 0.5f && environment.layers[0].shapes[1].style.uv[3] == 0.25f,
          "and in the world, so many metres tall, a part of it");
}

void plugins_place_world_entities() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const std::string main = R"(
        local gate = "World/Props/Gate_Arch"
        assert(reskate.entities.set(1, gate, {position = vector.create(1, 2, 3), yaw = 90, scale = 2}))
        assert(reskate.entities.set(2, gate, {position = vector.create(0, 0, 0), right = vector.create(1, 0, 0),
            up = vector.create(0, 1, 0), forward = vector.create(0, 0, 3)}))
        assert(reskate.entities.set(3, gate, {matrix = {1,0,0,0, 0,1,0,0, 0,0,1,0, 7,8,9,1}}, true))
        assert(reskate.entities.status(1) == "ready" and reskate.entities.status(3) == "hidden" and reskate.entities.status(9) == nil)
        assert(not pcall(reskate.entities.set, 0, gate, {position = vector.create(0, 0, 0)}), "ids start at 1")
        assert(not pcall(reskate.entities.set, 4, gate, {position = vector.create(0 / 0, 0, 0)}), "a finite position")
        assert(not pcall(reskate.entities.set, 4, gate, {matrix = {1, 2, 3}}), "16 numbers")
        -- On a skater's joint: yours by name, another player's by number.
        assert(reskate.entities.set(4, "Props/Camcorder", {position = vector.create(0, 0.1, 0)}, false, {joint = "right_hand"}))
        assert(reskate.entities.set(5, "Props/Camcorder", {position = vector.create(0, 0, 0)}, false, {player = "76561198000000001", joint = 103}))
        assert(not pcall(reskate.entities.set, 6, gate, {position = vector.create(0, 0, 0)}, false, {joint = 395}), "joints end at 394")
        assert(not pcall(reskate.entities.set, 6, gate, {position = vector.create(0, 0, 0)}, false, {joint = "elbow"}), "a joint's name")
        assert(not pcall(reskate.entities.set, 6, gate, {position = vector.create(0, 0, 0)}, false, {player = "me", joint = 1}), "a player")
        reskate.entities.remove(2)
        assert(reskate.entities.status(2) == nil and reskate.entities.ready())
        reskate.log("placed")
    )";
    host.apply({package("props", {{manifest_file, manifest(R"("world.entities")")}, {"plugin/main.lua", main}})});
    ticks(host, environment, 1);
    running(host, "props", environment);
    check(environment.logged("[props] placed"), "A plugin places world objects\n" + environment.all());
    // Yaw 90: forward is +x (sin, 0, cos), scaled 2; the axes and the matrix come as given.
    check(game.called("entity props 1 World/Props/Gate_Arch 1.00 2.00 3.00 2.00"), "a yaw and a scale\n" + environment.all());
    check(game.called("entity props 2 World/Props/Gate_Arch 0.00 0.00 0.00 0.00"), "its own axes");
    check(game.called("entity props 3 World/Props/Gate_Arch 7.00 8.00 9.00 0.00 hidden"), "a matrix, hidden");
    check(game.called("entity props 4 Props/Camcorder 0.00 0.10 0.00 0.00 on 0 49") &&
              game.called("entity props 5 Props/Camcorder 0.00 0.00 0.00 0.00 on 76561198000000001 103"),
          "on your right hand, on another player's head\n" + environment.all());
    host.apply({});
    check(game.called("entities clear props"), "A plugin's objects go with it");
    // Without the permission, refused.
    host.apply({package("sneaky", {{manifest_file, manifest()}, {"plugin/main.lua", R"(
        reskate.log(tostring(pcall(reskate.entities.set, 1, "x", {position = vector.create(0, 0, 0)})))
    )"}})});
    ticks(host, environment, 1);
    check(environment.logged("[sneaky] false"), "world.entities is needed\n" + environment.all());
}

// What a prop hunt needs: the props this map has, the one a ray meets (to become it), wearing it
// upright on another player, and your own skater hidden on your screen.
void plugins_have_what_a_prop_hunt_needs() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const std::string main = R"(
        local props = reskate.entities.blueprints("World/Props/")
        assert(#props == 2 and props[1] == "World/Props/Bench_01", "the props loaded, by their names' start")
        assert(#reskate.entities.blueprints() == 3, "all of them")
        local shown = reskate.entities.blueprints("", true)
        assert(#shown == 1 and shown[1] == "World/Props/TrashCan_01", "only those with a mesh")
        local low, high = reskate.entities.bounds("World/Props/TrashCan_01")
        assert(low.y == 0 and math.abs(high.y - 0.9) < 1e-5, "its box")
        assert(reskate.entities.bounds("World/Vehicles/Car_01") == nil, "none without a mesh")
        local hit = reskate.world.pick(vector.create(0, 2, 0), vector.create(0, -2, 0))
        assert(hit and hit.position.z == 2 and hit.object.blueprint == "World/Props/TrashCan_01", "the object a ray meets")
        assert(math.abs(hit.object.heading - math.pi / 2) < 1e-4 and hit.object.position.z == 3, "where it is and how it is turned")
        assert(#hit.object.transform.matrix == 16)
        assert(reskate.world.pick(vector.create(0, 60, 0), vector.create(0, 70, 0)) == nil, "nothing met")
        assert(reskate.entities.set(1, hit.object.blueprint, hit.object.transform, false,
            {player = "76561198000000001", joint = "root", upright = true}), "worn upright, at the feet")
        assert(reskate.entities.set(2, hit.object.blueprint, {position = vector.create(0, 0, 0), yaw = 45}, false,
            {joint = "root", turn = false}), "turned as the mod says, whatever the skater does")
        assert(reskate.entities.set(3, hit.object.blueprint, {position = vector.create(0, 0, 0)}, false,
            {joint = "hips", turn = false, ground = 1.5}, {solid = false}), "on the floor, not solid")
        assert(not pcall(reskate.entities.set, 4, hit.object.blueprint, {position = vector.create(0, 0, 0)}, false, {joint = "hips", ground = 80}),
            "the floor within 50 m")
        assert(reskate.skater.hide(true))
        reskate.log("disguised")
    )";
    host.apply({package("prophunt", {{manifest_file, manifest(R"("world.entities", "world.raycast", "skater.control")")}, {"plugin/main.lua", main}})});
    ticks(host, environment, 1);
    running(host, "prophunt", environment);
    check(environment.logged("[prophunt] disguised"), "A prop hunt finds, becomes and wears a prop\n" + environment.all());
    check(game.called("entity prophunt 1 World/Props/TrashCan_01 1.00 0.00 3.00 1.00 on 76561198000000001 1 upright"),
          "the prop on the hider's hips, upright\n" + environment.all());
    check(game.called("hide skater prophunt on"), "your own skater hidden");
    check(game.called("entity prophunt 2 World/Props/TrashCan_01 0.00 0.00 0.00 0.71 on 0 1 held"), "a prop the skater does not turn\n" + environment.all());
    check(game.called("entity prophunt 3 World/Props/TrashCan_01 0.00 0.00 0.00 0.00 on 0 7 held ground 1.5 ghost"), "on the floor and not solid\n" + environment.all());
}

// What a camera mode needs (the Filmer): an arm that reaches, where the hand is, cruise control, the
// mouse, and the right stick and stick clicks kept from the game.
void plugins_reach_cruise_and_read_the_mouse() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const std::string main = R"(
        assert(reskate.skater.reach({at = vector.create(1, 2, 3)}))
        assert(reskate.skater.reach({hand = "left", at = vector.create(4, 5, 6), rotation = {0, 0, 0, 2}, weight = 0.5}))
        assert(reskate.skater.reach(nil))
        assert(not pcall(reskate.skater.reach, {hand = "foot", at = vector.create(0, 0, 0)}), "a hand is right or left")
        assert(not pcall(reskate.skater.reach, {at = vector.create(0, 0, 0), weight = 2}), "a weight is 0 to 1")
        assert(not pcall(reskate.skater.reach, {}), "a reach needs a point")
        local h = reskate.skater.hand()
        assert(h and h.position.x == 1 and h.position.z == 3 and h.rotation[4] == 1, "the right hand")
        assert(reskate.skater.hand("left") == nil and not pcall(reskate.skater.hand, "foot"))
        assert(reskate.skater.cruise(8, true) and reskate.skater.cruise(0))
        assert(reskate.skater.set_velocity(vector.create(1, 5, -2)) and reskate.skater.set_velocity(vector.create(0, 3, 0), true))
        assert(not pcall(reskate.skater.set_velocity, vector.create(0, 101, 0)), "100 m/s an axis")
        assert(not pcall(reskate.skater.cruise, 0.5) and not pcall(reskate.skater.cruise, 31), "1 to 30 m/s")
        local m = reskate.input.mouse()
        assert(m and m.x == 3 and m.y == -2 and m.wheel == 1, "the mouse")
        assert(reskate.input.hide({right_stick = true, right_stick_click = true}))
        assert(reskate.screen.look({bend = 0.8, fov = 110, bars = true, hood = true, grade = true, grain = true, age = 0.35, iris = true,
            rolling = 2, text = {"#rec", "0:00:02", nil, "4:05 PM", "OCT.20 2026"}}))
        assert(reskate.screen.slap() and reskate.screen.look(nil))
        assert(not pcall(reskate.screen.look, {bend = 2}), "a bend is 0 to 1")
        assert(not pcall(reskate.screen.look, {text = {"far too long a line"}}), "12 characters")
        assert(not pcall(reskate.screen.look, {text = {"{}"}}), "the camcorder's characters")
        assert(not pcall(reskate.screen.look, {text = {"a", "b", "c", "d", "e", "f"}}), "5 lines")
        reskate.log("filmed")
    )";
    host.apply({package("filmer", {{manifest_file, manifest(R"("skater.animation", "skater.read", "skater.control", "input", "overlay")")}, {"plugin/main.lua", main}})});
    ticks(host, environment, 1);
    running(host, "filmer", environment);
    check(environment.logged("[filmer] filmed"), "A camera mode's calls work\n" + environment.all());
    check(game.called("reach filmer right 1.0 2.0 3.0 false 1.00") && game.called("reach filmer left 4.0 5.0 6.0 true 0.50") &&
              game.called("reach filmer none"),
          "The arm reaches, either hand, and lets go\n" + environment.all());
    check(game.called("cruise filmer 8.0 true") && game.called("cruise filmer 0.0 false"), "Cruise control on and off");
    check(game.called("velocity filmer 1.0 5.0 -2.0") && game.called("velocity filmer 0.0 3.0 0.0 add"), "A velocity set, and one added");
    check(game.called("hide filmer false false false stick true false true"), "The right stick and its click kept from the game");
    check(game.called("look filmer 0.80 110 0.35 truetruetruefalsefalsetruefalsefalsefalsefalsetrue 2.0 [#REC|0:00:02||4:05 PM|OCT.20 2026]") &&
              game.called("slap filmer") && game.called("look filmer none"),
          "A camcorder look on the screen, its text in capitals, a slap, and off\n" + environment.all());
    // Each needs its permission.
    host.apply({package("sneaky", {{manifest_file, manifest()}, {"plugin/main.lua", R"(
        reskate.log(tostring(pcall(reskate.skater.reach, {at = vector.create(0, 0, 0)})) .. " " .. tostring(pcall(reskate.skater.hand)) .. " " ..
            tostring(pcall(reskate.skater.cruise, 5)) .. " " .. tostring(pcall(reskate.input.mouse)) .. " " .. tostring(pcall(reskate.screen.look, {})))
    )"}})});
    ticks(host, environment, 1);
    check(environment.logged("[sneaky] false false false false false"),
          "skater.animation, skater.read, skater.control, input and overlay are needed\n" + environment.all());
}

// What the Filmer's port needs besides: something carried (seen by the others only), a pose only you
// see, a step in the camera height cycle and its event, the nametags held off, the board hidden from
// everyone, and a camcorder in the hand wear slot.
void plugins_carry_and_take_a_step_in_the_camera_cycle() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const std::string main = R"(
        local steps = {}
        reskate.on("camera_cycle", function(step) table.insert(steps, step) end)
        assert(reskate.skater.carry({at = vector.create(1, 2, 3), rotation = {0, 1, 0, 0}, both = true, front = vector.create(0, -0.143, -0.248),
            grip = {rotation = {0.5, -0.5, 0.5, 0.5}, offset = vector.create(0.12, 0.04, -0.03)}, crouch = 0.22, hunch = 1.0, turn = 0.5,
            step = 0.5, step_phase = 1.25, still = true, push_straightens = true, weight = 0.75, shown = "others"}))
        assert(reskate.skater.carry({hand = "left", at = vector.create(0, 1, 0), rotation = {0, 0, 0, 1}}))
        assert(reskate.skater.carry(nil))
        assert(not pcall(reskate.skater.carry, {at = vector.create(0, 1, 0)}), "a carry needs a rotation")
        assert(not pcall(reskate.skater.carry, {at = vector.create(0, 1, 0), rotation = {0, 0, 0, 1}, crouch = 1}), "a crouch is 0 to 0.6 m")
        assert(not pcall(reskate.skater.carry, {at = vector.create(0, 1, 0), rotation = {0, 0, 0, 1}, shown = "them"}), "shown is everyone, others or me")
        assert(reskate.skater.pose({[48] = {scale = 0}}, 1, {shown = "me"}))
        assert(reskate.skater.reach({at = vector.create(1, 2, 3), shown = "others"}))
        assert(reskate.camera.cycle("ready") and reskate.camera.cycle("active") and reskate.camera.cycle(nil))
        assert(not pcall(reskate.camera.cycle, "on"), "ready or active")
        reskate.session.nametags(false)
        reskate.session.nametags(true)
        assert(reskate.board.hide(2, {others = true}))
        assert(reskate.outfit.set("handwear_l", "Own_HandwearGlove_Gen_GloveFingerless_00001"))
        local ok, why = reskate.outfit.set("shoes", "Own_Shoes_00001")
        assert(not ok and why == "only tattoo, moles, eyewear and hand wear slots", why)
        assert(reskate.input.bind("toggle") and reskate.input.bind("slap", "Pad.LB"), "an action with no key of its own, and one with")
        reskate.on("tick", function()
            if #steps > 0 then reskate.log("steps " .. table.concat(steps, " ")) steps = {} end
        end)
        reskate.log("carried")
    )";
    host.apply({package("filmer", {{manifest_file, manifest(R"("skater.animation", "camera", "session.nametags", "board", "outfit", "input")")},
                                   {"plugin/main.lua", main}})});
    ticks(host, environment, 1);
    running(host, "filmer", environment);
    check(environment.logged("[filmer] carried"), "The calls work\n" + environment.all());
    check(game.called("carry filmer right both 1.0 2.0 3.0 front -0.25 grip true w 0.75 crouch 0.22 hunch 1.00 turn 0.50 step 0.50 still push others") &&
              game.called("carry filmer left 0.0 1.0 0.0 front 0.00 grip false w 1.00 crouch 0.00 hunch 0.00 turn 0.00 step 0.00 everyone") &&
              game.called("carry filmer none"),
          "Carried in both hands for the others, in one, and let go\n" + environment.all());
    check(game.called("pose filmer 1.00 me 48:0.00,0.00,0.00,1.00x0.00") && game.called("reach filmer right 1.0 2.0 3.0 false 1.00 others"),
          "A pose only you see, a reach only the others see\n" + environment.all());
    check(game.called("cycle filmer ready") && game.called("cycle filmer active") && game.called("cycle filmer out"), "In the cycle, on, and out");
    check(game.called("nametags filmer off") && game.called("nametags filmer on"), "The nametags held off and given back");
    check(game.called("board hide filmer 2 everyone"), "The board hidden from everyone");
    check(game.called("outfit filmer handwear_l Own_HandwearGlove_Gen_GloveFingerless_00001 0 false"), "A camcorder in the hand wear slot");
    check(game.binds.contains("filmer/toggle") && game.binds["filmer/toggle"] == 0 && game.binds["filmer/slap"] == combo_of("Pad.LB"),
          "An action the player puts on a key themselves");
    // The button's steps reach the plugin in the cycle, and nobody else.
    game.cycle_news = {{"filmer", true}, {"someone", false}, {"filmer", false}};
    ticks(host, environment, 2);
    check(environment.logged("[filmer] steps enter leave"), "The camera cycle's steps as events\n" + environment.all());
    // Each needs its permission.
    host.apply({package("sneaky", {{manifest_file, manifest()}, {"plugin/main.lua", R"(
        reskate.log(tostring(pcall(reskate.skater.carry, {at = vector.create(0, 0, 0), rotation = {0, 0, 0, 1}})) .. " " ..
            tostring(pcall(reskate.camera.cycle, "ready")) .. " " .. tostring(pcall(reskate.session.nametags, false)) .. " " ..
            tostring(pcall(reskate.on, "camera_cycle", function() end)))
    )"}})});
    ticks(host, environment, 1);
    check(environment.logged("[sneaky] false false false false"), "skater.animation, camera and session.nametags are needed\n" + environment.all());
}

// Reading a skater's joints, and the physics tuning read and set.
void plugins_read_joints_and_tune_physics() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const std::string main = R"(
        local head = reskate.skater.joint("head")
        assert(head and head.position.x == 0 and head.position.y == 103 and head.rotation[4] == 1 and head.scale == 1, "your head")
        assert(reskate.skater.joint(300) == nil, "not known yet")
        local theirs = reskate.session.joint("42", 49)
        assert(theirs and theirs.position.x == 42 and theirs.position.y == 49, "their right hand")
        assert(reskate.session.joint({id = "7"}, "hips") == nil)
        assert(not pcall(reskate.skater.joint, 395) and not pcall(reskate.skater.joint, "elbow") and not pcall(reskate.session.joint, "me", 1))
        local jump = reskate.physics.tuning("PhysicsMode.JumpMaxHeight")
        assert(jump and jump.value == 1.2 and jump.stock == 1.2 and jump.kind == "number" and jump.label == "Jump height" and jump.tuner == nil)
        local none, why = reskate.physics.tuning("nothing.here")
        assert(none == nil and why:find("no tuning value"), why)
        assert(#reskate.physics.find("physicsmode") == 2)
        assert(reskate.physics.tune("PhysicsMode.JumpMaxHeight", 2.5) and reskate.physics.tune("PhysicsMode.AutoPushEnabled", true))
        assert(reskate.physics.tune("PhysicsMode.JumpMaxHeight", nil))
        assert(not pcall(reskate.physics.tune, "x", 0 / 0) and not pcall(reskate.physics.tune, "", 1))
        assert(reskate.skater.pose({head = {scale = 0}, [44] = {angles = vector.create(0, 0, 90)}, [8] = {rotation = {0, 0, 0, 2}}}, 0.5))
        assert(reskate.skater.pose(nil))
        assert(not pcall(reskate.skater.pose, {[1] = {scale = 0}}), "the skater's placement")
        assert(not pcall(reskate.skater.pose, {head = {scale = 11}}), "scale 0 to 10")
        assert(not pcall(reskate.skater.pose, {head = {}}, 2), "weight 0 to 1")
        assert(not pcall(reskate.skater.pose, {head = {}, [103] = {}}), "a joint once")
        local many = {}
        for j = 2, 129 do many[j] = {scale = 1} end
        assert(reskate.skater.pose(many), "128 joints")
        many[130] = {scale = 1}
        assert(not pcall(reskate.skater.pose, many), "at most 128 joints")
        -- Set to a place: a link of a chain relative to another joint, one in the skater's frame keeping
        -- its children where they were, one in the world.
        assert(reskate.skater.pose({[49] = {place = {position = vector.create(0, 0, -0.1), relative_to = 278}},
            [278] = {place = {angles = vector.create(0, 0, 90), relative_to = "skater"}, keep_children = true},
            head = {place = {position = vector.create(1, 2, 3), relative_to = "world"}}, [42] = {place = {position = vector.create(0, 0.2, 0)}}}))
        assert(not pcall(reskate.skater.pose, {[49] = {place = {relative_to = 278}}}), "a place has a position or a rotation")
        assert(not pcall(reskate.skater.pose, {[49] = {place = {position = vector.create(0, 0, 0), relative_to = "moon"}}}), "relative to a joint, the skater or the world")
        assert(not pcall(reskate.skater.pose, {head = {keep_children = 1}}), "keep_children is true or false")
        local _, itself = pcall(reskate.skater.pose, {[49] = {place = {position = vector.create(0, 0, 0), relative_to = 49}}})
        assert(itself:find("relative to itself"), itself)
        local _, below = pcall(reskate.skater.pose, {hips = {place = {position = vector.create(0, 0, 0), relative_to = "spine"}}})
        assert(below:find("hangs from it"), below)
        local _, circle = pcall(reskate.skater.pose, {[49] = {place = {position = vector.create(0, 0, 0), relative_to = 278}},
            [278] = {place = {position = vector.create(0, 0, 0), relative_to = 49}}})
        assert(circle:find("in a circle"), circle)
        assert(reskate.settings.set("Camera.Height", 1.5) and reskate.settings.set("Chat.Show", true) and
            reskate.settings.set("Render.Mode", "fast") and reskate.settings.set("Camera.Height", nil))
        reskate.log("tuned")
    )";
    host.apply({package("tuner", {{manifest_file, manifest(R"("skater.read", "skater.control", "session.skaters", "settings.write", "skater.animation")")}, {"plugin/main.lua", main}})});
    ticks(host, environment, 1);
    running(host, "tuner", environment);
    check(environment.logged("[tuner] tuned"), "A plugin reads joints and tunes physics\n" + environment.all());
    check(game.called("tune tuner PhysicsMode.JumpMaxHeight 2.50") && game.called("tune tuner PhysicsMode.AutoPushEnabled 1.00") &&
              game.called("tune tuner PhysicsMode.JumpMaxHeight none"),
          "A value set, a flag set, and let go\n" + environment.all());
    check(game.called("pose tuner 0.50 8:0.00,0.00,0.00,1.00x1.00 44:0.00,0.00,0.71,0.71x1.00 103:0.00,0.00,0.00,1.00x0.00") &&
              game.called("pose tuner 1.00"),
          "Joints posed: a head shrunk, one turned 90 degrees about Z, and off\n" + environment.all());
    check(game.called("pose tuner 1.00 42:0.00,0.00,0.00,1.00x1.00 place@parent p0.00,0.20,0.00 49:0.00,0.00,0.00,1.00x1.00 place@278 p0.00,0.00,-0.10 "
                      "103:0.00,0.00,0.00,1.00x1.00 place@world p1.00,2.00,3.00 278:0.00,0.00,0.00,1.00x1.00 place@skater r0.00,0.00,0.71,0.71 keep") &&
              game.called("pose order tuner 42 103 278 49"),
          "Joints set to places: in their parent's frame, another joint's, the world and the skater's, the children kept; "
          "each posed after the joint it is placed relative to\n" + environment.all());
    check(game.called("setting tuner Camera.Height 1.5") && game.called("setting tuner Chat.Show true") &&
              game.called("setting tuner Render.Mode fast") && game.called("setting tuner Camera.Height none"),
          "Game settings held and let go\n" + environment.all());
    host.apply({package("sneaky", {{manifest_file, manifest(R"("skater.read")")}, {"plugin/main.lua", R"(
        reskate.log(tostring(pcall(reskate.physics.tune, "PhysicsMode.JumpMaxHeight", 2)) .. " " .. tostring(pcall(reskate.session.joint, "42", 1)) ..
            " " .. tostring(pcall(reskate.settings.set, "Camera.Height", 1)))
    )"}})});
    ticks(host, environment, 1);
    check(environment.logged("[sneaky] false false false"), "skater.control, session.skaters and settings.write are needed\n" + environment.all());
}

// Touching another player, hiding one on this screen, and a ray at players.
void plugins_touch_hide_and_ray_at_players() {
    // A body from its joints: the limbs between theirs, the head on from the neck, the board along its Z.
    const auto body = dingosdk::plugin_feed::body_of(9, [](std::uint16_t joint) -> std::optional<std::array<float, 3>> {
        if (joint == 103) return std::array<float, 3>{0, 1.6f, 0};
        if (joint == 101) return std::array<float, 3>{0, 1.5f, 0};
        return std::array<float, 3>{0, static_cast<float>(joint) / 1000, 0};
    }, std::pair{std::array<float, 3>{0, 0, 0}, std::array<float, 4>{0, 0.7071068f, 0, 0.7071068f}});
    const auto head = std::find_if(body.capsules.begin(), body.capsules.end(), [](const auto& c) { return c.part == 0; });
    const auto deck = std::find_if(body.capsules.begin(), body.capsules.end(), [](const auto& c) { return c.part == 6; });
    check(body.capsules.size() == 11 && head != body.capsules.end() && std::abs(head->b[1] - 1.76f) < 1e-4f && deck != body.capsules.end() &&
              std::abs(deck->a[0] + 0.3f) < 1e-4f && std::abs(deck->b[0] - 0.3f) < 1e-4f && std::abs(deck->a[1] - 0.08f) < 1e-4f,
          "A body: nine limb capsules, the head 16 cm on from the neck, the deck along its length turned 90 degrees");
    const auto gone = dingosdk::plugin_feed::body_of(9, [](std::uint16_t) -> std::optional<std::array<float, 3>> { return std::array<float, 3>{0, NAN, 0}; },
                                           std::nullopt);
    check(gone.capsules.empty(), "No body from a pose that is not finite");

    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const auto upright = [](std::uint64_t player, float x, float y) {
        return Body{player, {{1, {x, y, 0}, {x, y + 1, 0}, 0.16f}, {6, {x, y, -0.3f}, {x, y, 0.3f}, 0.12f}}};
    };
    game.body_list = {upright(0, 0, 0), upright(9, 1, 0), upright(12, 5, 0.5f), upright(13, 8, -3)};
    const std::string main = R"(
        local hit = reskate.session.raycast(vector.create(0, 1, 0), vector.create(10, 1, 0))
        assert(hit and hit.player == "9" and hit.part == "body" and math.abs(hit.distance - 0.84) < 1e-4 and math.abs(hit.position.x - 0.84) < 1e-4,
            "the nearest player, at their body's surface: " .. tostring(hit and hit.distance))
        assert(reskate.session.raycast(vector.create(0, 3, 2), vector.create(10, 3, 2)) == nil, "over everyone")
        assert(reskate.session.raycast(vector.create(8, 3, 0), vector.create(8, -5, 0)) == nil, "the ground in the way")
        local under = reskate.session.raycast(vector.create(8, 3, 0), vector.create(8, -5, 0), {world = false})
        assert(under and under.player == "13", "through the world")
        assert(not pcall(reskate.session.raycast, vector.create(0, 0, 0), vector.create(2000, 0, 0)), "too long")
        assert(reskate.session.hide("12") and reskate.session.hidden()[1] == "12")
        assert(reskate.session.hide({id = "12"}, false) and #reskate.session.hidden() == 0)
        assert(not pcall(reskate.session.touch, true, 2), "a reach is 0 to 1 m")
        reskate.session.touch(true)
        reskate.on("touch", function(e)
            reskate.log(string.format("touch %s %s %s %.2f %d", e.player, e.part, e.their_part, e.distance, #reskate.session.touching()))
        end)
        reskate.on("touch_end", function(e) reskate.log("apart " .. e.player .. " " .. #reskate.session.touching()) end)
        reskate.log("rayed")
    )";
    host.apply({package("tag", {{manifest_file, manifest(R"("session.skaters")")}, {"plugin/main.lua", main}})});
    ticks(host, environment, 2);
    running(host, "tag", environment);
    check(environment.logged("[tag] rayed") && game.called("hide tag 12 on") && game.called("hide tag 12 off"),
          "Rays at players and a player hidden and shown\n" + environment.all());
    check(!environment.logged("[tag] touch "), "Nobody within reach\n" + environment.all());
    const auto count = [&](std::string_view part) {
        return std::count_if(environment.logs.begin(), environment.logs.end(), [&](const auto& line) { return line.find(part) != std::string::npos; });
    };
    game.body_list[1] = upright(9, 0.3f, 0);
    ticks(host, environment, 2);
    check(environment.logged("[tag] touch 9 body body 0.00 1") && count("[tag] touch ") == 1, "Touching: once, as they come into contact\n" + environment.all());
    game.body_list[1] = upright(9, 0.4f, 0);
    ticks(host, environment, 2);
    check(count("[tag] touch ") == 1 && !environment.logged("[tag] apart"), "Still touching a little further apart\n" + environment.all());
    game.body_list[1] = upright(9, 0.6f, 0);
    ticks(host, environment, 1);
    check(environment.logged("[tag] apart 9 0"), "Apart once 10 cm further than the reach\n" + environment.all());
    game.body_list[1] = upright(9, 0.3f, 0);
    ticks(host, environment, 1);
    game.body_list.erase(game.body_list.begin() + 1);
    ticks(host, environment, 1);
    check(count("[tag] touch ") == 2 && count("[tag] apart 9") == 2, "Touching again, and apart when they leave\n" + environment.all());
    host.apply({package("sneaky", {{manifest_file, manifest(R"("skater.read")")}, {"plugin/main.lua", R"(
        reskate.log(tostring(pcall(reskate.session.touch, true)) .. " " .. tostring(pcall(reskate.session.hide, "9")) .. " " ..
            tostring(pcall(reskate.session.raycast, vector.create(0, 1, 0), vector.create(1, 1, 0))) .. " " ..
            tostring(pcall(reskate.on, "touch", function() end)))
    )"}})});
    ticks(host, environment, 1);
    check(environment.logged("[sneaky] false false false false"), "session.skaters is needed\n" + environment.all());
}

// Typing into a field a plugin draws (only while its screen is open), and the character room.
void plugins_type_and_use_the_room() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const std::string main = R"(
        reskate.ui.screen("Editor", function() end, {panel = false})
        assert(not pcall(reskate.ui.screen, "Docked", function() end, {panel = false, dock = "left"}), "no panel, no dock")
        assert(reskate.input.text(true) == "", "nothing without its screen open")
        reskate.ui.open("Editor")
        local typed = reskate.input.text(true)
        assert(typed == "ab", "what was typed: " .. typed)
        assert(reskate.input.text(true) == "", "once")
        assert(reskate.room.state() == "idle")
        assert(reskate.room.open())
        assert(reskate.room.state() == "open")
        reskate.room.leave()
        assert(reskate.room.state() == "idle")
        reskate.log("typed")
    )";
    game.typed = "ab";
    host.apply({package("editor", {{manifest_file, manifest(R"("ui.screen", "input", "room")")}, {"plugin/main.lua", main}})});
    ticks(host, environment, 1);
    running(host, "editor", environment);
    check(environment.logged("[editor] typed"), "A plugin takes typing and the room\n" + environment.all());
    check(game.called("room open editor") && game.called("room leave editor"), "The room is walked to and from\n" + environment.all());
    host.apply({package("sneaky", {{manifest_file, manifest(R"("input")")}, {"plugin/main.lua", R"(
        reskate.log(tostring(pcall(reskate.room.open)) .. " " .. tostring(pcall(reskate.room.state)))
    )"}})});
    ticks(host, environment, 1);
    check(environment.logged("[sneaky] false false"), "room is needed\n" + environment.all());
}

// The game's own clips: listed once they are read, each a "game:" clip like any other.
void plugins_use_the_games_clips() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const std::string main = R"(
        local none, why = reskate.animation.game_clips("trick")
        assert(none == nil and why == "the game's animations are still being read", tostring(why))
        reskate.on("tick", function()
            local names = reskate.animation.game_clips("kickflip")
            if not names or done then return end
            done = true
            assert(#names == 2 and names[1] == "animation/dingo/c_proto_onb_trick_o_kickflip_high", "the names that contain it")
            assert(#reskate.animation.game_clips() == 3, "all of them")
            local info = reskate.animation.info("game:" .. names[1])
            assert(info.frames == 3 and info.joints == 395 and math.abs(info.takeoff - 0.05) < 1e-6 and math.abs(info.landing - 0.15) < 1e-6, "a clip")
            assert(info.stance == "regular", "its stance: " .. tostring(info.stance))
            local mirrored = reskate.animation.mirror("game:" .. names[1])
            assert(mirrored and mirrored:sub(1, 5) == "clip:" and reskate.animation.info(mirrored).stance == "goofy", "mirrored, the other stance")
            assert(reskate.animation.play("game:" .. names[1], {floor = true}))
            local ok, err = pcall(reskate.animation.info, "game:" .. names[2])
            assert(not ok and err:find("SequenceContainerAsset, not a clip"), err)
            assert(not pcall(reskate.animation.game_clips, string.rep("x", 65)), "a part of a name is at most 64 characters")
            reskate.log("game clips")
        end)
    )";
    host.apply({package("clips", {{manifest_file, manifest(R"("skater.animation")")}, {"plugin/main.lua", main}})});
    ticks(host, environment, 1);
    game.game_clips_ready = true;
    ticks(host, environment, 2);
    running(host, "clips", environment);
    check(environment.logged("[clips] game clips"), "A plugin lists and plays the game's clips\n" + environment.all());
    check(game.called("game clip animation/dingo/c_proto_onb_trick_o_kickflip_high") &&
              game.called("play clips 3 frames 1.0 0.15 false floor"),
          "read once, and played on the floor\n" + environment.all());
    host.apply({package("sneaky", {{manifest_file, manifest(R"("files")")}, {"plugin/main.lua", R"(
        reskate.log(tostring(pcall(reskate.animation.game_clips)))
    )"}})});
    ticks(host, environment, 1);
    check(environment.logged("[sneaky] false"), "skater.animation is needed\n" + environment.all());
}

// A clip read, sampled, cut, keyed, saved and read back from the data folder, and played held.
void plugins_edit_clips() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    const std::string main = R"(
        assert(reskate.animation.record(2))
        local rec = reskate.animation.recorded()
        local i = reskate.animation.info(rec)
        assert(i.frames == 3 and i.duration == 0.5 and i.joints == 395 and not i.board, "a recording's info")
        assert(math.abs(i.takeoff - 0.1) < 1e-6 and math.abs(i.landing - 0.4) < 1e-6, "with its takeoff and landing")
        local cut = reskate.animation.trim(rec, 0.2, 0.5)
        local c = reskate.animation.info(cut)
        assert(cut == "clip:2" and c.frames == 2 and math.abs(c.duration - 0.25) < 1e-6, "a trim from its first frame")
        assert(c.takeoff == nil and math.abs(c.landing - 0.15) < 1e-6, "its marks moved with it")
        local work = reskate.animation.edit(rec, {{joint = "hips", keys = {{time = 0, angles = vector.create(0, 0, 90)},
            {time = 0.5, angles = vector.create(0, 0, 90), offset = vector.create(0, 0.5, 0), ease = "linear"}}}}, {name = "work"})
        assert(work == "edit:work", work)
        local s = reskate.animation.sample(work, 7, 0.5)
        assert(math.abs(s.rotation[3] - 0.70711) < 1e-3 and math.abs(s.rotation[4] - 0.70711) < 1e-3, "the hips turned 90 degrees")
        assert(math.abs(s.position.y - 0.5) < 1e-4 and math.abs(reskate.animation.sample(work, "hips", 0.25).position.y - 0.25) < 1e-4, "and moved, blended")
        assert(reskate.animation.sample(rec, 7, 0.5).rotation[4] == 1, "the recording stays as it was")
        assert(reskate.animation.edit(rec, {}, {name = "work"}) == "edit:work", "the same name again")
        assert(reskate.animation.sample("edit:work", 7, 0.5).rotation[4] == 1, "replaces it")
        local list = reskate.animation.joints()
        assert(#list == 25 and list[1].joint == "board" and list[2].joint == 7 and list[2].label == "Hips" and list[2].moves, "the editable joints")
        assert(reskate.animation.save(work, "anims/work.fas"))
        local keyed = reskate.animation.edit(rec, {{joint = 7, keys = {{time = 0.5, offset = vector.create(0, 0.5, 0)}}}})
        assert(reskate.animation.save(keyed, "anims/keyed.fas"))
        local back = reskate.animation.info("data:anims/keyed.fas")
        assert(back.frames == 3 and math.abs(reskate.animation.sample("data:anims/keyed.fas", "hips", 0.5).position.y - 0.5) < 1e-4, "saved and read back")
        assert(reskate.animation.play(work, {at = 0.25, paused = true, floor = true}))
        reskate.animation.seek(0.4)
        reskate.animation.pause(false)
        assert(reskate.animation.time() == 0.25)
        assert(not pcall(reskate.animation.edit, rec, {{joint = 1, keys = {}}}), "the placement joint")
        assert(not pcall(reskate.animation.edit, rec, {{joint = 7, keys = {{time = 0, ease = "bouncy"}}}}), "an ease")
        assert(not pcall(reskate.animation.edit, rec, {{joint = 7, keys = {}}, {joint = "hips", keys = {}}}), "a joint once")
        assert(not pcall(reskate.animation.edit, rec, {}, {name = "../x"}), "a name")
        assert(not pcall(reskate.animation.trim, rec, 0.3, 0.2) and not pcall(reskate.animation.trim, rec, 0.26, 0.3), "a trim keeps two frames")
        assert(not pcall(reskate.animation.info, "data:none.fas") and not pcall(reskate.animation.info, "edit:none"), "clips there are not")
        assert(not pcall(reskate.animation.play, work, {at = 9}), "at is within the clip")
        reskate.log("edited")
    )";
    host.apply({package("editor", {{manifest_file, manifest(R"("skater.animation", "files")")}, {"plugin/main.lua", main}})});
    ticks(host, environment, 1);
    running(host, "editor", environment);
    check(environment.logged("[editor] edited"), "A plugin edits clips\n" + environment.all());
    check(game.called("play editor 3 frames 1.0 0.15 false at 0.25 paused floor") && game.called("seek editor 0.40") && game.called("pause editor false"),
          "and plays one held, moved and let run\n" + environment.all());
    host.apply({package("sneaky", {{manifest_file, manifest(R"("skater.animation")")}, {"plugin/main.lua", R"(
        assert(reskate.animation.record(2))
        local rec = reskate.animation.recorded()
        reskate.log(tostring(pcall(reskate.animation.save, rec, "x.fas")) .. " " .. tostring(pcall(reskate.animation.info, "data:x.fas")))
    )"}})});
    ticks(host, environment, 1);
    check(environment.logged("[sneaky] false false"), "files is needed for data clips\n" + environment.all());
}

void plugins_draw_on_the_overlay() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("painter", R"(
        local saved = nil
        reskate.on("draw", function(d)
            saved = d
            d:text(vector.create(10, 20, 0), "hello", {colour = "#ff8000", size = 24, align = "centre"})
            d:rect(vector.create(0, 0, 0), vector.create(100, 50, 0), {colour = 0x00ff00ff, fill = true, rounding = 4})
            d:line(vector.create(0, 0, 0), vector.create(5, 5, 0))
            d:circle(vector.create(50, 50, 0), 10)
            d:poly({vector.create(0, 0, 0), vector.create(10, 0, 0), vector.create(0, 10, 0)}, {fill = true})
            d:world_text(vector.create(0, 1, -10), "over there")
            d:world_line(vector.create(0, 0, -5), vector.create(1, 0, -5), {thickness = 3})
            d:world_circle(vector.create(0, 0, -5), 2)
            local on = d:world_to_screen(vector.create(1, 0, -10))
            assert(on and math.abs(on.x - 1060) < 0.01 and math.abs(on.z - 10) < 0.01, "world_to_screen")
            assert(d:world_to_screen(vector.create(0, 0, 5)) == nil, "behind the camera")
            -- Just in front of the camera and off to the side the point is millions of pixels
            -- out, which d:poly would refuse.
            assert(d:world_to_screen(vector.create(1000, 0, -0.06)) == nil, "far off the screen")
            assert(d:world_to_screen(vector.create(0, 1000, -0.06)) == nil, "far above the screen")
            assert(d:world_to_screen(vector.create(1, 0, -0.06)), "off the screen but drawable")
            assert(d:size().x == 1920 and d:size().y == 1080)
            assert(not pcall(d.text, d, vector.create(0, 0, 0), "x", {colour = "red"}), "a colour by name")
            assert(not pcall(d.text, d, vector.create(0 / 0, 0, 0), "x"), "NaN")
            assert(not pcall(d.poly, d, {vector.create(0, 0, 0)}), "a polygon of one point")
            assert(not pcall(d.text, d, vector.create(0, 0, 0), string.rep("x", 600)), "a long text")
            reskate.log("drawn")
        end)
        reskate.console.command("outside", "x", function()
            local ok, err = pcall(saved.text, saved, vector.create(0, 0, 0), "x")
            reskate.log("outside " .. tostring(ok) .. " " .. tostring(err):match("only inside a draw handler"))
        end)
        reskate.console.command("toasts", "x", function()
            local shown = 0
            for i = 1, 10 do if reskate.ui.toast("toast " .. i) then shown += 1 end end
            reskate.log("toasts " .. shown)
        end)
    )", R"("console", "overlay")"), script("unseen", R"(
        local ok, err = pcall(reskate.on, "draw", function() end)
        assert(not ok and err:find("overlay"), err)
        ok, err = pcall(reskate.ui.toast, "x")
        assert(not ok and err:find("overlay"), err)
        reskate.log("unseen refused")
    )")});
    running(host, "painter", environment);
    check(environment.logged("unseen refused"), "Drawing needs overlay\n" + environment.all());
    ticks(host, environment, 1);
    running(host, "painter", environment);
    check(environment.layers.size() == 1 && environment.layers[0].plugin == "painter" && environment.layers[0].shapes.size() == 8,
          "Its shapes are handed to the overlay each tick\n" + environment.all());
    check(environment.logged("drawn"), "and the draw handler ran to its end\n" + environment.all());
    const auto& first = environment.layers[0].shapes[0];
    check(first.kind == plugin_ui::Shape::Kind::text && first.text == "hello" && first.style.colour == 0xff0080ff &&
          first.style.size == 24 && first.style.align == 1, "with their style (colours as ImGui keeps them)");
    check(environment.layers[0].shapes[1].style.colour == 0xff00ff00 && environment.layers[0].shapes[1].style.fill, "a colour number too");
    host.run_console("outside");
    check(environment.logged("outside false only inside a draw handler"), "Drawing outside a draw handler is refused\n" + environment.all());
    host.run_console("toasts");
    check(environment.logged("toasts 3") && environment.toasts.size() == 3 && environment.toasts[0] == "painter: toast 1", "Three toasts in 5 s");
    environment.now += 5000;
    host.run_console("toasts");
    check(environment.toasts.size() == 6, "and three more after");
}

void plugins_have_menu_panels() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("panels", R"(
        local state = {on = false, speed = 5, mode = 1, presses = 0}
        reskate.menu.panel("Settings", function(ui)
            ui:heading("Settings")
            ui:label("Some words")
            ui:separator()
            if ui:button("go", "Go") then state.presses += 1 end
            state.on = ui:toggle("on", "Switch", state.on)
            state.speed = ui:slider("speed", "Speed", state.speed, 0, 10)
            state.mode = ui:dropdown("mode", "Mode", {"one", "two", "three"}, state.mode)
            ui:bar("Throttle", 0.25, 0, 1)
            assert(not pcall(ui.bar, ui, "Bad", 0, 1, 0), "a bar's range")
            assert(not pcall(ui.button, ui, "go", "Again"), "two widgets with one id")
        end)
        assert(not pcall(reskate.menu.panel, "Settings", function() end), "two panels with one title")
        reskate.console.command("state", "x", function()
            reskate.log(string.format("state %d %s %.1f %d", state.presses, tostring(state.on), state.speed, state.mode))
        end)
    )", R"("console", "menu")")});
    running(host, "panels", environment);
    ticks(host, environment, 2);
    check(environment.panels.empty(), "Panels are built only while the menu shows them");
    environment.panels_open = true;
    ticks(host, environment, 10);
    check(environment.panels.size() == 1 && environment.panels[0].title == "Settings" && environment.panels[0].widgets.size() == 8 &&
              environment.panels[0].widgets[7].kind == plugin_ui::Widget::Kind::bar && environment.panels[0].widgets[7].value == 0.25f,
          "Then its panel is built\n" + environment.all());
    using A = plugin_ui::Action;
    environment.actions = {A{"panels", "Settings", "go"}, A{"panels", "Settings", "on", true}, A{"panels", "Settings", "speed", false, 99},
                           A{"panels", "Settings", "mode", false, 0, 3}, A{"someone", "Settings", "go"}};
    ticks(host, environment, 10);
    host.run_console("state");
    check(environment.logged("state 1 true 10.0 3"), "What the player did reaches it, the slider held in its range\n" + environment.all());
    const auto& widgets = environment.panels[0].widgets;
    check(widgets[4].on && widgets[5].value == 10 && widgets[6].chosen == 3 && widgets[6].choices.size() == 3, "and shows in the next build");
}

void camera_inspector_prepares_then_explicitly_requests_a_view() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "camera-inspector";
    const auto contents = [](const std::filesystem::path& path) {
        std::ifstream file(path, std::ios::binary);
        check(file.good(), "Camera Inspector source is available: " + path.string());
        return std::string(std::istreambuf_iterator<char>(file), {});
    };
    const auto source = contents(directory / "plugin" / "main.lua");
    const auto declaration = contents(directory / manifest_file);
    check(parse_manifest(declaration).permissions == std::set<std::string, std::less<>>{"camera", "menu", "skater.read"},
          "The inspector asks only for the camera, menu and read-only skater state");
    check(check_package_files(directory).empty(), "The inspector is a sandboxed source-only plugin package");
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({{"camera-inspector", directory, "1", {}}});
    running(host, "camera-inspector", environment);
    ticks(host, environment, 3);
    check(environment.fake.calls.empty(), "Loading and ticking the inspector never requests a camera");
    environment.panels_open = true;
    const auto frame = [&](std::vector<plugin_ui::Action> actions = {}) {
        environment.actions = std::move(actions);
        ticks(host, environment, 10);
        running(host, "camera-inspector", environment);
    };
    const auto message = [&] {
        for (const auto& panel : environment.panels)
            for (const auto& widget : panel.widgets)
                if (widget.text == "Last action") return widget.help;
        throw std::runtime_error("The inspector's action status is missing");
    };
    const auto camera_calls = [&] {
        return std::count_if(environment.fake.calls.begin(), environment.fake.calls.end(),
            [](const auto& call) { return call.starts_with("camera camera-inspector "); });
    };
    using A = plugin_ui::Action;
    const auto press = [](const char* id) { return A{"camera-inspector", "Camera Inspector", id}; };
    const auto value = [](const char* id, float number) { return A{"camera-inspector", "Camera Inspector", id, false, number}; };
    frame();
    check(environment.fake.calls.empty(), "Opening the page never takes the camera");
    frame({press("left"), press("apply")});
    check(camera_calls() == 0 && message().find("Get or prepare") != std::string::npos,
          "No player leaves a visible refusal and no camera request");
    frame({press("get")});
    check(camera_calls() == 0 && message().find("Current view copied") != std::string::npos,
          "Get reads the real sandbox camera API without acquiring it");
    frame({value("target-X", 1), value("target-Y", 2), value("target-Z", 3), press("apply")});
    check(camera_calls() == 0 && message().find("1 cm") != std::string::npos,
          "A coincident eye and target cannot acquire the camera");
    frame({press("get")});
    frame({value("eye-X", std::numeric_limits<float>::quiet_NaN()), press("apply")});
    check(camera_calls() == 0 && message().find("refused edit") != std::string::npos,
          "A nonfinite edit is refused without poisoning the next panel build");
    environment.local_skater = SkaterState{{10, 20, 30}, 0, 0, 0, false, 0};
    frame({press("left")});
    check(camera_calls() == 0 && message().find("Left player view prepared") != std::string::npos,
          "A fresh player preset prepares coordinates only");
    environment.fake.camera_refusal = "another plugin has the camera";
    frame({press("apply")});
    check(camera_calls() == 0 && message().find("another plugin") != std::string::npos,
          "An existing camera owner produces a visible refusal without taking its view");
    environment.fake.camera_refusal.clear();
    frame({press("apply")});
    check(camera_calls() == 1 && environment.fake.called("camera camera-inspector 8.5 21.0 30.0 back -1.00 0.00 0.00 fov 60"),
          "Apply reaches the existing camera.look API with the prepared side view");
    frame();
    check(camera_calls() == 1, "Panel rebuilds never reapply or follow the player");
    environment.fake.camera_hold_error.clear();
    frame();
    bool held = false;
    for (const auto& panel : environment.panels) for (const auto& widget : panel.widgets)
        held = held || (widget.text == "Camera" && widget.help == "Held by this plugin");
    check(held, "Queued and actually held camera states are shown separately");
    frame({press("release")});
    check(environment.fake.called("camera release camera-inspector") && message().find("Release requested") != std::string::npos,
          "Release calls the existing lease release and reports that it is requested");
    frame({press("right")});
    frame({value("fov", 400), press("apply")});
    check(environment.fake.called("camera camera-inspector 11.5 21.0 30.0 back 1.00 0.00 0.00 fov 120"),
          "The actual menu API clamps an edited FOV to the tool's stated range");
    host.apply({});
    check(std::count(environment.fake.calls.begin(), environment.fake.calls.end(), "camera release camera-inspector") >= 2,
          "Unloading also releases the plugin's camera lease");

    TestEnvironment denied;
    denied.local_skater = SkaterState{{10, 20, 30}, 0, 0, 0, false, 0};
    denied.panels_open = true;
    Host bare(denied, Side::client);
    bare.apply({script("no-camera", source, R"("menu", "skater.read")")});
    running(bare, "no-camera", denied);
    denied.actions = {A{"no-camera", "Camera Inspector", "left"}, A{"no-camera", "Camera Inspector", "apply"}};
    ticks(bare, denied, 2);
    running(bare, "no-camera", denied);
    check(denied.fake.calls.empty(), "Without camera permission the inspector cannot request a native view");
    bool explained = false;
    for (const auto& panel : denied.panels) for (const auto& widget : panel.widgets)
        explained = explained || (widget.text == "Last action" && widget.help.find("camera") != std::string::npos);
    check(explained, "The permission refusal remains visible on the page");
}

#include "bmx_first_ride_import_test.inc"
#include "bmx_contact_runtime_host_fixture.inc"
#include "passive_sync_trial_test.inc"
#include "passive_sync_routes_trial_test.inc"

void bmx_lua_first_ride_imports_stay_inert() {
    const auto root = std::filesystem::path(RESKATE_SOURCE_DIR);
    const auto entry = root / "Extension" / "Plugins" / "Test" / "fixtures" / "bmx_first_ride_import.lua";
    std::ifstream file(entry, std::ios::binary);
    check(file.good(), "required inert first-ride import entry: " + entry.string());
    const std::string text(std::istreambuf_iterator<char>(file), {});
    run_bmx_first_ride_import_fixture(root / "contrib" / "bmx-lab" / "bmx-plugin" / "plugin", text);
}

void bmx_lua_policy_runs_as_modules_and_the_inspector_starts_inert() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    const auto contents = [](const std::filesystem::path& path) {
        std::ifstream file(path, std::ios::binary);
        check(file.good(), "BMX Lua source is available: " + path.string());
        return std::string(std::istreambuf_iterator<char>(file), {});
    };
    const auto declaration = contents(directory / manifest_file);
    check(parse_manifest(declaration).permissions == std::set<std::string, std::less<>>{"input", "input.control", "input.lease", "input.capture", "skater.read",
                  "menu", "storage", "overlay", "board", "world.physics", "world.physics.follow", "world.entities"} &&
              check_package_files(directory).empty(),
          "The public package declares exactly its reviewed general input/body/entity permissions and no native skater control");
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({{"bmx-lua-inspector", directory, "1", {}}});
    ticks(host, environment, 3);
    running(host, "bmx-lua-inspector", environment);
    environment.panels_open = true;
    ticks(host, environment, 10);
    running(host, "bmx-lua-inspector", environment);
    check(environment.panels.size() == 2 && environment.panels[0].page && environment.panels[0].title == "BMX Lua migration" &&
              !environment.panels[1].page && environment.panels[1].title == "BMX local scores" && environment.fake.calls.empty() &&
              environment.fake.binds.empty() && environment.teleports.empty() && environment.rays == 0,
          "The actual package loads, ticks and builds its page and local scores panel without acquiring input/camera/pose or invoking gameplay");
    check(!environment.fake.input_pulse_requests && !environment.fake.input_pulse_reads &&
              !environment.fake.input_pulse_cancels && !environment.fake.input_pulse_acks,
          "Startup and menu rebuilds do not arm equipment switching");
    environment.shown = "bmx-lua-inspector";
    const auto panel_value = [&](std::string_view label) {
        for (const auto& panel : environment.panels)
            for (const auto& widget : panel.widgets)
                if (widget.text == label) return widget.help;
        throw std::runtime_error("Missing public bike status: " + std::string(label));
    };
    for (unsigned slot = 0; slot < 4; ++slot) {
        environment.actions = {plugin_ui::Action{"bmx-lua-inspector", "BMX Lua migration", "bike_mount" + std::to_string(slot), false}};
        ticks(host, environment, 10);
        running(host, "bmx-lua-inspector", environment);
        check(panel_value("Last mount click") == "Native bike lifecycle qualification unavailable" &&
                  panel_value("Mount enabled") == "false" && panel_value("Bike authority") == "false" &&
                  panel_value("Cleanup pending / unknown") == "false / false",
              "Each real public Mount button refuses before authority or cleanup duty");
    }
    check(environment.fake.calls.empty() && environment.fake.binds.empty() && environment.fake.entities.empty() &&
              !environment.fake.body_prepares && !environment.fake.body_create_calls && !environment.fake.body_read_calls &&
              !environment.fake.body_submit_entries && !environment.fake.follow_reserves && !environment.fake.follow_publishes &&
              !environment.fake.follow_reads && !environment.fake.follow_stops && !environment.fake.follow_acks &&
              !environment.fake.input_pulse_requests && !environment.fake.input_pulse_reads &&
              !environment.fake.input_pulse_cancels && !environment.fake.input_pulse_acks &&
              !environment.fake.native_action_requests && !environment.fake.native_recovery_requests &&
              environment.teleports.empty() && !environment.rays,
          "Public Mount denial never reaches input reports, Follow, body/entity allocation or native skater actions");
    host.apply({});
    check(!std::filesystem::exists(environment.storage_root() / "bmx-lua-inspector" / "storage.json"),
          "An idle package also unloads without writing equipment storage");
    std::map<std::string, std::string> files{{manifest_file, declaration}};
    for (const auto* name : {"input.lua", "catalog.lua", "tests.lua"}) files[std::string("plugin/") + name] = contents(directory / "plugin" / name);
    // Cold module loading and policy execution use separate unchanged Host call budgets.
    files["plugin/main.lua"] = R"(
        local tests = require("./tests")
        local job, complete = nil, false
        local completed_cases, completed_assertions = 0, 0
        reskate.on("tick", function()
            if complete then return end
            if not job then
                job = coroutine.create(function()
                    return tests.run(function(cases, assertions)
                        assert(cases == completed_cases + 1 and assertions > completed_assertions,
                            "policy case progress must advance exactly once")
                        completed_cases, completed_assertions = cases, assertions
                        coroutine.yield()
                    end)
                end)
            end
            local before_cases = completed_cases
            local ok, result = coroutine.resume(job)
            assert(ok, result)
            if coroutine.status(job) ~= "dead" then
                assert(completed_cases == before_cases + 1, "one complete policy case must yield per callback")
                return
            end
            complete = true
            assert(result.cases == 12 and result.assertions == 1216 and result.native_actions == 0,
                string.format("unexpected Lua coverage: %s/%s", tostring(result.cases), tostring(result.assertions)))
            assert(before_cases == 12 and completed_cases == result.cases and completed_assertions == result.assertions,
                "policy final return must follow all twelve case yields and match their counts")
            local pad, focus = reskate.input.gamepad(), reskate.input.focus()
            assert(type(pad.left_x) == "number" and type(pad.right_y) == "number" and pad.left_trigger > 0 and pad.right_trigger > 0)
            assert(pad.buttons.a and pad.buttons.b and pad.buttons.y and pad.buttons.right_stick and pad.buttons.lb and pad.buttons.rb)
            assert(focus.focused and not focus.interface_open and focus.gameplay)
            reskate.log("BMX Lua: 12 cases, 1216 assertions, 0 native actions")
        end)
    )";
    TestEnvironment portable;
    portable.fake.pad = PadInput{0.25f, 0, 0, -1, 0.3f, 0.9f, 0xb380, false};
    portable.fake.focus_now = {true, false, true};
    check(Limits{}.call_ms == 50 && Limits{}.tick_ms == 2,
          "The policy Host regression uses unchanged default call and tick limits");
    Host unit(portable, Side::client);
    unit.apply({package("bmx-lua-policy-tests", files)});
    running(unit, "bmx-lua-policy-tests", portable);
    const auto policy_inert = [&] {
        const auto& game = portable.fake;
        return game.calls.empty() && game.binds.empty() && game.entities.empty() &&
            !game.body_prepares && !game.body_create_calls && !game.body_read_calls && !game.body_submissions &&
            !game.follow_reserves && !game.follow_publishes && !game.follow_reads && !game.follow_stops && !game.follow_acks &&
            !game.input_pulse_requests && !game.input_pulse_reads && !game.input_pulse_cancels && !game.input_pulse_acks &&
            !game.native_action_requests && !game.native_recovery_requests && portable.teleports.empty() && !portable.rays;
    };
    check(!portable.logged("BMX Lua: 12 cases, 1216 assertions, 0 native actions") && policy_inert(),
          "Cold policy loading stays inert and defers the regression suite to a separate tick call\n" + portable.all());
    // Twelve complete case yields, then one separate callback returns/logs the result.
    for (unsigned tick = 0; tick < 13; ++tick) {
        ticks(unit, portable, 1);
        running(unit, "bmx-lua-policy-tests", portable);
        check(policy_inert(), "Every paced policy callback remains inert\n" + portable.all());
        if (tick < 12)
            check(!portable.logged("BMX Lua: 12 cases, 1216 assertions, 0 native actions"),
                  "Policy completion cannot precede all twelve case yields and the separate return callback\n" + portable.all());
    }
    check(portable.logged("BMX Lua: 12 cases, 1216 assertions, 0 native actions") && portable.fake.calls.empty(),
          "Actual package modules run through the vendored Luau Host with expected coverage and actual input API fields\n" + portable.all());
    check(policy_inert(), "The policy suite and actual input reads never invoke an actuator\n" + portable.all());
    const auto completed = portable.all();
    for (unsigned idle = 0; idle < 2; ++idle) {
        ticks(unit, portable, 1);
        running(unit, "bmx-lua-policy-tests", portable);
        check(portable.all() == completed && policy_inert(), "The input policy regression suite runs only once");
    }
}

void bmx_lua_public_bike_facade_denies_mount_before_service_access() {
    const auto path = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin" / "plugin" / "bike_runtime.lua";
    std::ifstream source(path, std::ios::binary);
    check(source.good(), "The public bike facade source is required: " + path.string());
    std::map<std::string, std::string> files{{manifest_file, manifest("")}};
    files["plugin/bike_runtime.lua"] = std::string(std::istreambuf_iterator<char>(source), {});
    files["plugin/main.lua"] = R"(
        local reads = 0
        local services = setmetatable({}, {__index = function()
            reads += 1
            error("public denial must precede service lookup")
        end})
        local owner = require("./bike_runtime").new(services)
        for slot = 0, 3 do
            local accepted, why = owner:request_mount(slot)
            assert(accepted == false and why == "Native bike lifecycle qualification unavailable")
        end
        for _, slot in {-1, 4, 0.5, "0", math.huge} do
            local accepted, why = owner:request_mount(slot)
            assert(accepted == false and why == "Choose an XInput slot from0 to3")
        end
        local state = owner:status()
        assert(state.mount_enabled == false and state.bike_authority == false and state.used == false)
        assert(state.startup.loaded == 0 and state.startup.pending == false)
        state.phase = "external mutation"; state.startup.loaded = 99
        assert(owner:status().phase == "idle" and owner:status().startup.loaded == 0)
        assert(owner:request_stop("pristine stop") == true)
        for _ = 1, 60 do owner:step(16) end
        assert(reads == 0 and owner:status().used == false)
        owner:unload()
        assert(reads == 0 and owner:status().unloaded == true)
        reskate.log("Public bike facade: denied before service access")
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-public-facade-denial", files)});
    running(host, "bmx-public-facade-denial", environment);
    check(environment.logged("Public bike facade: denied before service access") && environment.fake.calls.empty() &&
              !environment.fake.input_pulse_requests && !environment.fake.body_creates && !environment.fake.follow_reserves,
          "The actual public facade needs no permission, backend module, service read or actuator to deny Mount");
}

void bmx_lua_equipment_requests_match_the_retained_gesture_rules() {
    namespace bmx = dingosdk::bmx;
    using dingosdk::Json;
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    for (const auto* name : {"equipment.lua", "equipment_tests.lua"}) {
        std::ifstream file(directory / "plugin" / name, std::ios::binary);
        check(file.good(), std::string("BMX Lua equipment source is available: ") + name);
        files[std::string("plugin/") + name] = std::string(std::istreambuf_iterator<char>(file), {});
    }
    Json reference = Json::array();
    // The retained policy is an offline oracle only; the Lua package gets no
    // permission, native pointer, equipment action or old runtime entry point.
    for (unsigned scenario = 0; scenario < 8; ++scenario) {
        bmx::BikeQuickSwitchButton quick;
        bmx::BikeInteractionButton ordinary;
        bmx::EquipmentToggleKey toggle;
        unsigned device = 1;
        std::uint64_t clock = 100, wall = 100;
        bool allowed = true;
        unsigned owner_id = 1;
        for (unsigned row = 0; row < 20; ++row) {
            const bool reset = row == 0;
            bool quick_reset = false;
            const bool north = row == 1 || row == 2 || row == 6 || row == 7 || row == 8 ||
                row == 11 || row == 12 || row == 15 || row == 16 || row == 17;
            const bool shoulder = row == 2 || row == 5 || row == 6 || row == 7 ||
                row == 11 || row == 12 || row == 15 || row == 16 || row == 17;
            if (row == 2 || row == 7) { clock += 600; wall += 600; }
            if (row == 11) {
                if (scenario == 0) owner_id = 2;
                if (scenario == 1) owner_id = 0;
                if (scenario == 2) clock = 1;
                if (scenario == 3) { quick.reset(); quick_reset = true; }
                if (scenario == 4) device = 2;
                if (scenario == 5) allowed = false;
                if (scenario == 6) device = 0;
            }
            if (row == 12) { allowed = true; if (scenario == 1) owner_id = 1; if (scenario == 6) device = 1; }
            if (row == 15) device = 3;
            if (row == 16) allowed = false;
            if (row == 17) allowed = true;
            const bool observed = quick.owner_sample_needed(north, shoulder);
            const auto owner = owner_id == 0 ? bmx::BikeQuickSwitchOwner{} : bmx::BikeQuickSwitchOwner{1, 2, 3, 4, owner_id};
            const auto event = quick.update(north, shoulder, allowed, device, observed, owner, clock);
            // The original composition requires a valid source for both latches.
            const auto interaction = ordinary.update(north, allowed && device != 0 && !event.suppress_north, wall);
            const bool toggled = toggle.update(north, allowed && device != 0);
            const char* action = interaction == bmx::BikeInteraction::tap ? "tap" : interaction == bmx::BikeInteraction::hold ? "hold" : "none";
            reference.push_back(Json{{"reset", reset}, {"quick_reset", quick_reset}, {"north", north}, {"shoulder", shoulder},
                {"allowed", allowed}, {"device", device}, {"owner", owner_id == 0 ? "" : owner_id == 1 ? "rider-a" : "rider-b"},
                {"clock", clock}, {"wall", wall}, {"observed", observed}, {"pressed", event.pressed},
                {"suppress", event.suppress_north}, {"capture", event.capture_north}, {"interaction", action}, {"toggle", toggled}});
            ++clock; ++wall;
        }
    }
    // Loading the policy modules and running the entire regression suite are
    // separate calls, each with the Host's unchanged production time limit.
    files["plugin/main.lua"] = R"(local tests = require("./equipment_tests")
        local complete = false
        reskate.on("tick", function()
            if complete then return end
            complete = true
            local reference = reskate.json.decode([=[)" + reference.dump() + R"(]=])
            local result = tests.run(reference)
            assert(result.cases == 8 and result.assertions > 1000 and result.comparisons == 160 and result.native_actions == 0,
                string.format("unexpected equipment coverage: %s/%s/%s", tostring(result.cases), tostring(result.assertions), tostring(result.comparisons)))
            reskate.log(string.format("BMX Lua equipment: %d cases, %d assertions, %d C++ comparisons, 0 native actions", result.cases, result.assertions, result.comparisons))
        end)
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-equipment-tests", files)});
    running(host, "bmx-lua-equipment-tests", environment);
    check(!environment.logged("BMX Lua equipment:"), "Equipment policy tests wait for their separate tick call");
    host.tick(1.0 / 60.0);
    running(host, "bmx-lua-equipment-tests", environment);
    check(environment.logged("BMX Lua equipment: 8 cases") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
              environment.fake.body_creates == 0 && environment.fake.body_submissions == 0 && environment.teleports.empty() && environment.rays == 0,
          "Actual equipment modules agree with retained gesture rules without native services or gameplay permissions\n" + environment.all());
    const auto completed = environment.all();
    host.tick(1.0 / 60.0);
    running(host, "bmx-lua-equipment-tests", environment);
    check(environment.all() == completed, "The equipment regression suite runs only once");
    std::cout << environment.all();
}

void bmx_lua_equipment_transitions_keep_cleanup_and_target_observation_separate() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    for (const auto* name : {"equipment_transition.lua", "equipment_transition_tests.lua"}) {
        std::ifstream file(directory / "plugin" / name, std::ios::binary);
        check(file.good(), std::string("BMX Lua transition source is available: ") + name);
        files[std::string("plugin/") + name] = std::string(std::istreambuf_iterator<char>(file), {});
    }
    files["plugin/main.lua"] = R"(
        local result = require("./equipment_transition_tests").run()
        assert(result.cases >= 10 and result.assertions >= 100 and result.native_actions == 0,
            string.format("unexpected transition coverage: %s/%s", tostring(result.cases), tostring(result.assertions)))
        reskate.log(string.format("BMX Lua transitions: %d cases, %d assertions, 0 native actions", result.cases, result.assertions))
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-transition-tests", files)});
    running(host, "bmx-lua-transition-tests", environment);
    check(environment.logged("BMX Lua transitions:") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
        environment.fake.input_pulse_requests == 0 && environment.fake.input_pulse_reads == 0 &&
        environment.fake.input_pulse_cancels == 0 && environment.fake.input_pulse_acks == 0 &&
        environment.fake.native_action_requests == 0 && environment.fake.native_recovery_requests == 0 &&
        environment.fake.body_creates == 0 && environment.fake.body_submissions == 0 &&
        environment.teleports.empty() && environment.rays == 0,
        "Equipment transition policy runs without native services or gameplay permissions\n" + environment.all());
    std::cout << environment.all();
}

void bmx_lua_equipment_runtime_uses_typed_services_without_native_permissions() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    for (const auto* name : {"equipment_transition.lua", "bike_admission.lua", "equipment_runtime.lua",
             "bike_runtime_core.lua", "equipment_runtime_tests.lua"}) {
        std::ifstream file(directory / "plugin" / name, std::ios::binary);
        check(file.good(), std::string("BMX Lua runtime source is available: ") + name);
        files[std::string("plugin/") + name] = std::string(std::istreambuf_iterator<char>(file), {});
    }
    files["plugin/main.lua"] = R"(
        -- Compile each cold module in its own unchanged-budget callback.
        local modules = {"./equipment_transition", "./bike_admission", "./equipment_runtime",
            "./bike_runtime_core", "./equipment_runtime_tests"}
        local loaded, cases, done, runner = 0, 0, false, nil
        reskate.on("tick", function()
            if done then return end
            if loaded < #modules then
                loaded += 1
                require(modules[loaded])
                return
            end
            runner = runner or require("./equipment_runtime_tests").new_runner()
            local result = runner:step()
            assert(result.cases == cases + 1 and result.total_cases == 13 and result.native_actions == 0)
            cases = result.cases
            assert(result.done == (cases == 13))
            if not result.done then return end
            assert(result.cases == 13 and result.assertions == 260)
            done = true
            reskate.log(string.format("BMX Lua runtime: %d cases, %d assertions, 0 native actions", result.cases, result.assertions))
        end)
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-runtime-tests", files)});
    for (int tick = 0; tick < 18; ++tick) host.tick(1.0 / 60.0);
    running(host, "bmx-lua-runtime-tests", environment);
    check(environment.logged("BMX Lua runtime:") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
              !environment.fake.input_pulse_requests && !environment.fake.input_pulse_reads &&
              !environment.fake.input_pulse_cancels && !environment.fake.input_pulse_acks &&
              !environment.fake.native_action_requests && !environment.fake.native_recovery_requests &&
              !environment.fake.body_creates && !environment.fake.body_submissions && environment.teleports.empty() && !environment.rays,
          "The actual adapter module tests use injected services without actual gameplay permissions\n" + environment.all());
    const auto completed = environment.all();
    host.tick(1.0 / 60.0);
    check(environment.all() == completed, "The equipment runtime regression suite runs only once");
    std::cout << environment.all();
}

void bmx_lua_persistence_keeps_terminal_records_and_public_fault_gates() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    for (const auto* name : {"equipment_transition.lua", "bike_admission.lua", "equipment_runtime.lua",
             "bike_runtime_core.lua", "bike_runtime.lua", "lease_identity.lua", "bike_runtime_core_persist_tests.lua",
             "runtime_progress_fault_tests.lua"}) {
        std::ifstream file(directory / "plugin" / name, std::ios::binary);
        check(file.good(), std::string("BMX Lua persistence source is available: ") + name);
        files[std::string("plugin/") + name] = std::string(std::istreambuf_iterator<char>(file), {});
    }
    files["plugin/main.lua"] = R"(
        local modules = {"./equipment_transition", "./bike_admission", "./equipment_runtime",
            "./bike_runtime_core", "./bike_runtime", "./lease_identity", "./bike_runtime_core_persist_tests",
            "./runtime_progress_fault_tests"}
        local loaded, persisted, persisted_work, persistence, public_done = 0, 0, 0, nil, false
        local expected_cases = {1,1,1,1,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17}
        reskate.on("tick", function()
            -- One cold import, persistence work unit or public suite per unchanged-budget callback.
            if loaded < #modules then
                loaded += 1
                require(modules[loaded])
                return
            end
            if persisted_work < 21 then
                persistence = persistence or require("./bike_runtime_core_persist_tests").new_runner()
                local result = persistence:step()
                assert(type(result.work_unit_complete) == "boolean")
                assert(result.work_units == persisted_work + (result.work_unit_complete and 1 or 0) and result.total_work_units == 21 and result.total_cases == 17 and result.native_actions == 0)
                assert(result.cases == (result.work_units == 0 and 0 or expected_cases[result.work_units]) and result.cases >= persisted and result.cases <= persisted + 1)
                persisted, persisted_work = result.cases, result.work_units
                assert(result.done == (persisted_work == 21))
                if result.done then
                    assert(result.cases == 17 and result.assertions == 216)
                    reskate.log(string.format("BMX Lua persistence: %d cases, %d assertions, 0 native actions", result.cases, result.assertions))
                end
                return
            end
            if public_done then return end
            public_done = true
            local result = require("./runtime_progress_fault_tests").run()
            assert(result.cases == 1 and result.assertions == 12 and result.native_actions == 0)
            reskate.log(string.format("BMX Lua public progress fault: %d cases, %d assertions, 0 native actions", result.cases, result.assertions))
        end)
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-persistence-tests", files)});
    bool public_completed = false;
    for (int tick = 0; tick < 4096; ++tick) {
        host.tick(1.0 / 60.0);
        running(host, "bmx-lua-persistence-tests", environment);
        if (environment.logged("BMX Lua public progress fault:")) {
            public_completed = true;
            break;
        }
    }
    check(public_completed, "Persistence work and the public fault regression complete within 4096 callbacks\n" + environment.all());
    check(environment.logged("BMX Lua persistence:") && environment.logged("BMX Lua public progress fault:") &&
              environment.fake.calls.empty() && environment.fake.binds.empty() &&
              !environment.fake.input_pulse_requests && !environment.fake.input_pulse_reads &&
              !environment.fake.input_pulse_cancels && !environment.fake.input_pulse_acks &&
              !environment.fake.native_action_requests && !environment.fake.native_recovery_requests &&
              !environment.fake.body_creates && !environment.fake.body_submissions && environment.teleports.empty() && !environment.rays,
          "Public owner and persistence regressions use injected services without actual gameplay permissions\n" + environment.all());
    const auto completed = environment.all();
    host.tick(1.0 / 60.0);
    running(host, "bmx-lua-persistence-tests", environment);
    check(environment.all() == completed, "The persistence and public progress suites run only once");
    std::cout << environment.all();
}

void equipment_interruption_fixture_keeps_effects_one_shot() {
    const auto root = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab";
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    const auto source = [&](const std::filesystem::path& directory, const char* name) {
        std::ifstream file(directory / "plugin" / name, std::ios::binary);
        check(file.good(), std::string("Interruption test source is required: ") + name);
        files[std::string("plugin/") + name] = std::string(std::istreambuf_iterator<char>(file), {});
    };
    for (const auto* name : {"fixture.lua", "fixture_tests.lua"}) source(root / "equipment-interruption-trial", name);
    for (const auto* name : {"equipment_runtime.lua", "equipment_transition.lua"}) source(root / "bmx-plugin", name);
    files["plugin/main.lua"] = R"(
        local result = require("./fixture_tests").run()
        assert(result.cases == 13 and result.assertions >= 50 and result.native_actions == 0)
        reskate.log(string.format("Equipment interruption: %d cases, %d assertions, 0 native actions", result.cases, result.assertions))
    )";
    TestEnvironment environment;
    Limits policy_limits; policy_limits.call_ms = 2000; // Many constructed timelines run in one test-only load.
    Host host(environment, Side::client, policy_limits);
    host.apply({package("equipment-interruption-tests", files)});
    running(host, "equipment-interruption-tests", environment);
    check(environment.logged("Equipment interruption:") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
        !environment.fake.input_pulse_requests && !environment.fake.input_pulse_reads && !environment.fake.input_pulse_cancels &&
        !environment.fake.input_pulse_acks && !environment.fake.native_action_requests && !environment.fake.native_recovery_requests &&
        !environment.fake.body_creates && !environment.fake.body_submissions && environment.teleports.empty() && !environment.rays,
        "Actual fixture/factory and production modules run with constructed services and no native permissions\n" + environment.all());
    std::cout << environment.all();
    // The broad skater-control tests cover permitted wipeouts and their rate.
    // This exact denial checks the new diagnostic's sole added control boundary.
    TestEnvironment denied_environment;
    Host denied(denied_environment, Side::client);
    denied.apply({script("interruption-wipeout-denied", R"(
        local ok,why=pcall(reskate.skater.wipeout,0.5)
        assert(not ok and why:find("skater.control",1,true))
    )")});
    running(denied, "interruption-wipeout-denied", denied_environment);
    check(denied_environment.fake.calls.empty(), "A denied wipeout must not reach Game::wipeout");
    auto actual_files = files;
    for (const auto& name : {std::string(manifest_file), std::string("plugin/main.lua")}) {
        std::ifstream file(root / "equipment-interruption-trial" / name, std::ios::binary);
        check(file.good(), "The exact interruption entry/manifest is required: " + name);
        actual_files[name] = std::string(std::istreambuf_iterator<char>(file), {});
    }
    constexpr const char* fixture_id = "LuaEquipmentInterruption_20261023_v1";
    TestEnvironment inert_environment;
    inert_environment.local_skater = SkaterState{};
    inert_environment.fake.focus_now = {true, true, true};
    inert_environment.fake.telemetry = SkaterTelemetry{};
    auto& inert_watch = inert_environment.fake.telemetry->watch;
    inert_environment.fake.telemetry->skater = true;
    inert_watch.valid = inert_watch.ragdoll_known = true; inert_watch.state = 100;
    const auto inert_storage = inert_environment.storage_root() / fixture_id / "storage.json";
    check(!std::filesystem::exists(inert_storage), "The exact interruption entry starts without stored evidence");
    Host inert(inert_environment, Side::client);
    inert.apply({package(fixture_id, actual_files)}); running(inert, fixture_id, inert_environment);
    inert_environment.panels_open = true; inert_environment.shown = fixture_id;
    ticks(inert, inert_environment, 60); running(inert, fixture_id, inert_environment);
    check(std::find(inert_environment.pages.begin(), inert_environment.pages.end(),
        plugin_ui::PageEntry{fixture_id, "Equipment interruption"}) != inert_environment.pages.end(),
        "The exact interruption page loads within the Host title bound");
    check(!inert_environment.fake.input_pulse_requests && !inert_environment.fake.input_pulse_reads &&
        !inert_environment.fake.input_pulse_cancels && !inert_environment.fake.input_pulse_acks &&
        !inert_environment.fake.native_action_requests && !inert_environment.fake.native_recovery_requests &&
        !inert_environment.fake.body_creates && !inert_environment.fake.body_submissions &&
        inert_environment.fake.calls.empty() && inert_environment.teleports.empty() && !inert_environment.rays &&
        !std::filesystem::exists(inert_storage),
        "Actual entry/menu ticks stay inert despite a usable constructed board baseline");
}

void bmx_lua_menu_switches_explicit_slots_and_retains_cleanup_duty() {
    using dingosdk::Json;
    namespace p = game_input_pulse;
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    for (unsigned scenario = 0; scenario < 8; ++scenario) {
        const auto id = "bmx-lua-runtime-menu-" + std::to_string(scenario);
        const auto why = id + ": ";
        TestEnvironment environment;
        environment.local_skater = SkaterState{};
        auto& game = environment.fake;
        game.focus_now = {true, true, true};
        game.input_allowed_now = true; // Constructed native-input readiness; production guard remains required.
        game.telemetry = SkaterTelemetry{};
        game.telemetry->skater = true;
        auto& watch = game.telemetry->watch;
        watch.valid = watch.ragdoll_known = true;
        watch.state = scenario % 2 == 0 ? 504 : 100;
        const auto expected = watch.state == 504 ? 100u : 504u;
        Host host(environment, Side::client);
        host.set_level("sanvan");
        Candidate candidate{id, directory, "bmx-runtime-menu-v1", {}};
        if (scenario == 6) {
            std::map<std::string, std::string> files;
            // Keep the complete real package; subtract only the tested permission.
            // Missing a new lazy dependency would fail load before testing denial.
            for (const auto& entry : std::filesystem::recursive_directory_iterator(directory)) {
                check(!entry.is_symlink(), why + "package source must not contain symlinks");
                if (!entry.is_regular_file()) continue;
                std::ifstream file(entry.path(), std::ios::binary);
                check(file.good(), why + entry.path().string());
                files[entry.path().lexically_relative(directory).generic_string()] = std::string(std::istreambuf_iterator<char>(file), {});
            }
            auto denied_manifest = Json::parse(files.at(manifest_file));
            const auto original_permissions = denied_manifest.at("permissions");
            denied_manifest["permissions"] = Json::array();
            for (const auto& permission : original_permissions)
                if (permission.string() != "input.control")
                    denied_manifest["permissions"].push_back(permission);
            check(denied_manifest["permissions"].size() + 1 == original_permissions.size(),
                  why + "the denial fixture removes only the existing input.control permission");
            files[manifest_file] = denied_manifest.dump();
            candidate = package(id, files);
        }
        host.apply({candidate}); running(host, id, environment);
        const auto step = [&] { environment.now += 100; host.tick(100); running(host, id, environment); };
        environment.panels_open = true; environment.shown = id;
        for (unsigned i = 0; i < 10; ++i) step();
        check(!game.input_pulse_requests && !game.input_pulse_reads && !game.input_pulse_cancels && !game.input_pulse_acks,
              why + "load and menu rebuilds must remain inert with an otherwise usable baseline");
        const auto slot = scenario % 4;
        environment.actions = {plugin_ui::Action{id, "BMX Lua migration", "equipment" + std::to_string(slot), false}};
        step();
        // Three cold stock imports, then a separate Core construction tick.
        // Keep the existing ten-tick wait and the unchanged Host budgets.
        for (unsigned i = 0; i < 10; ++i) {
            step();
            if (i < 4) {
                bool idle = false;
                for (const auto& panel : environment.panels)
                    for (const auto& widget : panel.widgets)
                        if (widget.text == "Switch phase") idle = widget.help == "idle";
                check(idle && !game.input_pulse_requests && !game.body_create_calls && !game.follow_reserves,
                      why + "stock imports and Core construction must finish before equipment handoff");
            }
        }
        check(!game.input_pulse_requests, why + "an explicit menu request cannot publish while the menu remains open");
        if (scenario == 4) {
            game.input_pulse_available = false;
            game.input_pulse_refusal = p::Reason::clock_unavailable;
        }
        if (scenario == 5) { game.focus_now.focused = false; step(); game.focus_now.focused = true; }
        environment.panels_open = false; game.focus_now.interface_open = false;
        for (unsigned i = 0; i < 13; ++i) step();
        const unsigned requests = scenario == 5 || scenario == 6 ? 0u : 1u;
        check(game.input_pulse_requests == requests, why + "one menu intent requests exactly once in the chosen slot");
        if (scenario < 4 || scenario == 7) {
            check(game.input_pulses.size() == 1, why + "one opaque receipt remains owned");
            auto& receipt = game.input_pulses.begin()->second.receipt;
            check(receipt.user == slot && receipt.button == 0x8000, why + "the actual menu forwards its explicit slot and only Y");
            if (scenario == 7) {
                receipt.status = p::Status::pressing; receipt.report_debt = true;
                host.apply({});
                check(game.input_pulse_requests == 1 && game.input_pulse_cancels == 1 && !game.input_pulse_acks &&
                          game.input_pulses.size() == 1 && receipt.report_debt && receipt.orphaned && receipt.quarantined && !receipt.claim_released,
                      why + "Lua unload cancels once and SDK cleanup retains unresolved report duty");
                continue;
            }
            receipt.status = p::Status::revoked; receipt.reason = p::Reason::unavailable;
            receipt.first_rejection_mask = 1280; receipt.first_rejection_stage = p::RejectionStage::core_plan;
            receipt.press_candidates = receipt.press_publications = 7; receipt.neutral_publications = 1;
            receipt.claim_released = true; receipt.observed_ms += 50;
            watch.state = expected;
        }
        for (unsigned i = 0; i < 50; ++i) step();
        check(game.input_pulse_requests == requests && !game.native_action_requests && !game.native_recovery_requests &&
                  !game.body_creates && !game.body_submissions && game.binds.empty() && game.calls.empty() && environment.teleports.empty() && !environment.rays,
              why + "observation must not retry or invoke another actuator");
        check(game.input_pulse_acks == (scenario < 4 ? 1u : 0u), why + "only a saved clean terminal receipt is acknowledged");
        host.apply({});
        std::ifstream stored(environment.storage_root() / id / "storage.json", std::ios::binary);
        check(stored.good(), why + "explicit requests retain their bounded progress ledger");
        const auto document = Json::parse(std::istreambuf_iterator<char>(stored), std::istreambuf_iterator<char>());
        const auto& progress = document.at("bmx_equipment_runtime_v1");
        if (scenario < 4) {
            const auto& terminal = document.at("bmx_equipment_terminal_v1");
            check(progress.at("outcome").string() == "target_observed" && progress.at("historical_transition").get<bool>() &&
                      progress.at("acknowledged").get<bool>() && game.input_pulses.empty(),
                  why + "the actual package independently qualifies the sampled target and releases the receipt");
            check(terminal.at("receipt").at("status").string() == "revoked" &&
                      terminal.at("receipt").at("first_rejection_mask").get<unsigned>() == 1280,
                  why + "the full saved receipt preserves revocation despite the observed target");
        } else check(progress.at("outcome").string() != "target_observed", why + "refusal or invalidation cannot become observed success");
    }
    std::cout << "BMX Lua menu: four explicit slots, refusal, focus loss, permission denial and unresolved unload; constructed observations only\n";
}

void bmx_lua_menu_returns_to_board_without_inverting_the_target() {
    using dingosdk::Json;
    namespace p = game_input_pulse;
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    for (unsigned scenario = 0; scenario < 8; ++scenario) {
        const auto id = "bmx-lua-board-return-menu-" + std::to_string(scenario);
        const auto why = id + ": ";
        TestEnvironment environment;
        environment.local_skater = SkaterState{};
        auto& game = environment.fake;
        game.focus_now = {true, true, true};
        game.input_allowed_now = true;
        game.telemetry = SkaterTelemetry{};
        game.telemetry->skater = true;
        auto& watch = game.telemetry->watch;
        watch.valid = watch.ragdoll_known = true;
        watch.state = scenario == 4 ? 100 : 504;
        Host host(environment, Side::client);
        host.set_level("sanvan");
        host.apply({Candidate{id, directory, "bmx-board-return-menu-v1", {}}});
        running(host, id, environment);
        const auto step = [&] { environment.now += 100; host.tick(100); running(host, id, environment); };
        const auto click = [&](const std::string& widget) {
            environment.actions = {plugin_ui::Action{id, "BMX Lua migration", widget, false}};
            step();
        };
        const auto panel_value = [&](std::string_view label) {
            for (const auto& panel : environment.panels)
                for (const auto& widget : panel.widgets)
                    if (widget.text == label) return widget.help;
            throw std::runtime_error(why + "missing board-return status: " + std::string(label));
        };
        const auto other_actuators_inert = [&](bool after_unload = false) {
            // Host unload clears this owner's entities even when none were created.
            const bool expected_cleanup = after_unload
                ? game.calls == std::vector<std::string>{"entities clear " + id} && game.released == std::vector<std::string>{id}
                : game.calls.empty() && game.released.empty();
            return !game.body_prepares && !game.body_create_calls && !game.body_read_calls &&
                !game.body_submit_entries && !game.follow_reserves && !game.follow_publishes &&
                !game.follow_reads && !game.follow_stops && !game.follow_acks &&
                !game.native_action_requests && !game.native_recovery_requests && game.entities.empty() &&
                game.binds.empty() && expected_cleanup && environment.teleports.empty() && !environment.rays;
        };
        environment.panels_open = true; environment.shown = id;
        for (unsigned i = 0; i < 10; ++i) step();
        check(!game.input_pulse_requests && !game.input_pulse_reads && !game.input_pulse_cancels && !game.input_pulse_acks &&
                  other_actuators_inert(), why + "load and menu rebuilds cannot start a return transaction");
        const auto slot = scenario % 4;
        click("bike_board" + std::to_string(slot));
        // Board startup uses the same three imports and separate construction tick.
        for (unsigned i = 0; i < 14; ++i) {
            step();
            if (i < 4)
                check(panel_value("Switch phase") == "idle" && panel_value("Board return phase") == "draining" &&
                          !game.input_pulse_requests && other_actuators_inert(),
                      why + "cold board startup cannot hand off or acquire native work during Core construction");
        }
        check(!game.input_pulse_requests, why + "board return cannot publish an input report through an open menu");
        if (scenario == 1) {
            // A second slot click must not replace the first transaction's selected source.
            click("bike_board" + std::to_string((slot + 1) % 4));
        }
        if (scenario == 5) { game.focus_now.focused = false; step(); game.focus_now.focused = true; }
        if (scenario == 7) click("bike_stop");
        environment.panels_open = false; game.focus_now.interface_open = false;
        for (unsigned i = 0; i < 13; ++i) step();
        const unsigned requests = scenario < 4 || scenario == 6 ? 1u : 0u;
        check(game.input_pulse_requests == requests, why + "only a still-valid feet-to-board intent publishes once");
        if (requests) {
            check(game.input_pulses.size() == 1, why + "the transaction retains its one opaque report receipt");
            auto& receipt = game.input_pulses.begin()->second.receipt;
            check(receipt.user == slot && receipt.button == 0x8000, why + "return uses the original explicit slot and only Y");
            if (scenario == 6) {
                receipt.status = p::Status::pressing; receipt.report_debt = true;
                step();
                environment.panels_open = true; game.focus_now.interface_open = true;
                click("bike_board" + std::to_string((slot + 1) % 4));
                for (unsigned i = 0; i < 5; ++i) step();
                check(game.input_pulse_requests == 1 && !game.input_pulse_acks && game.input_pulses.size() == 1 &&
                          receipt.report_debt && panel_value("Board return phase") != "done",
                      why + "a duplicate return cannot replace or credit unresolved report duty");
                host.apply({});
                check(game.input_pulse_requests == 1 && game.input_pulse_cancels == 1 && !game.input_pulse_acks &&
                          game.input_pulses.size() == 1 && receipt.report_debt && receipt.orphaned && receipt.quarantined &&
                          !receipt.claim_released && other_actuators_inert(true),
                      why + "unload retains unresolved report duty without a second request or fake completion");
                continue;
            }
            receipt.status = p::Status::revoked; receipt.reason = p::Reason::unavailable;
            receipt.press_candidates = receipt.press_publications = 7; receipt.neutral_publications = 1;
            receipt.claim_released = true; receipt.observed_ms += 50;
            watch.state = 100;
        }
        for (unsigned i = 0; i < 50; ++i) step();
        check(game.input_pulse_requests == requests && game.input_pulse_acks == (scenario < 4 ? 1u : 0u) &&
                  other_actuators_inert(), why + "a return never retries, mounts a bike or invokes another actuator");
        environment.panels_open = true; game.focus_now.interface_open = true;
        step();
        if (scenario <= 4) {
            check(panel_value("Board return phase") == "done" && watch.state == 100 && game.input_pulses.empty(),
                  why + "the menu reports completion only after board100 no-op or qualified target and receipt ACK");
        } else {
            check(panel_value("Board return phase") == "cancelled",
                  why + "focus loss or explicit Stop cannot resurrect a return when readiness later recovers");
        }
        click("bike_mount" + std::to_string(slot));
        check(panel_value("Last mount click") == "Native bike lifecycle qualification unavailable" &&
                  panel_value("Mount enabled") == "false" && !game.body_creates && game.input_pulse_requests == requests,
              why + "a return does not enable public mounting or rearm native bike authority");
        host.apply({});
        const auto stored_path = environment.storage_root() / id / "storage.json";
        if (scenario == 4) {
            check(!std::filesystem::exists(stored_path), why + "already-board no-op creates no equipment or bike lifecycle ledger");
        } else if (scenario < 4) {
            std::ifstream stored(stored_path, std::ios::binary);
            check(stored.good(), why + "the equipment transaction saves its bounded progress");
            const auto document = Json::parse(std::istreambuf_iterator<char>(stored), std::istreambuf_iterator<char>());
            const auto& progress = document.at("bmx_equipment_runtime_v1");
            check(progress.at("initial_state").get<unsigned>() == 504 && progress.at("expected_state").get<unsigned>() == 100 &&
                      progress.at("outcome").string() == "target_observed" && progress.at("acknowledged").get<bool>() &&
                      !progress.at("retained").get<bool>() && !document.contains("bmx_bike_lifecycle_v1"),
                  why + "cold board return preserves the fixed direction without claiming a bike lifecycle marker");
        }
    }
    std::cout << "BMX Lua board return menu: four slots, duplicate intent, board no-op, cancellation and unresolved unload; constructed observations only\n";
}

void bmx_lua_recovery_policy_keeps_native_cleanup_separate() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    for (const auto* name : {"recovery.lua", "recovery_tests.lua"}) {
        std::ifstream file(directory / "plugin" / name, std::ios::binary);
        check(file.good(), std::string("BMX Lua recovery source is available: ") + name);
        files[std::string("plugin/") + name] = std::string(std::istreambuf_iterator<char>(file), {});
    }
    files["plugin/main.lua"] = R"(
        local result = require("./recovery_tests").run()
        assert(result.cases >= 8 and result.assertions >= 100 and result.native_actions == 0,
            string.format("unexpected recovery coverage: %s/%s", tostring(result.cases), tostring(result.assertions)))
        reskate.log(string.format("BMX Lua recovery: %d cases, %d assertions, 0 native actions", result.cases, result.assertions))
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-recovery-tests", files)});
    running(host, "bmx-lua-recovery-tests", environment);
    check(environment.logged("BMX Lua recovery:") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
        environment.fake.native_action_requests == 0 && environment.fake.native_recovery_requests == 0 &&
        environment.fake.native_recovery_reads == 0 && environment.fake.native_recovery_cancels == 0 &&
        environment.fake.native_recovery_acks == 0 && environment.fake.body_creates == 0 &&
        environment.fake.body_submissions == 0 && environment.teleports.empty() && environment.rays == 0,
        "Recovery policy runs without native services or gameplay permissions\n" + environment.all());
    std::cout << environment.all();
}

void bmx_lua_trick_policy_uses_actual_package_modules() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    const auto contents = [](const std::filesystem::path& path) {
        std::ifstream file(path, std::ios::binary);
        check(file.good(), "BMX Lua trick source is available: " + path.string());
        return std::string(std::istreambuf_iterator<char>(file), {});
    };
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    for (const auto* name : {"catalog.lua", "motions.lua", "tricks.lua", "trick_tests.lua"})
        files[std::string("plugin/") + name] = contents(directory / "plugin" / name);
    files["plugin/main.lua"] = R"(
        local paths = {"./catalog", "./motions", "./tricks", "./trick_tests"}
        local loading, tests, job, complete = 1, nil, nil, false
        local completed_cases, completed_assertions = 0, 0
        reskate.on("tick", function()
            if complete then return end
            if loading <= #paths then
                local exports = require(paths[loading])
                if loading == #paths then tests = exports end
                loading += 1
                return
            end
            if not job then
                job = coroutine.create(function()
                    return tests.run(function(cases, assertions)
                        assert(cases == completed_cases + 1 and assertions > completed_assertions,
                            "trick case progress must advance exactly once")
                        completed_cases, completed_assertions = cases, assertions
                        coroutine.yield()
                    end)
                end)
            end
            local ok, result = coroutine.resume(job)
            assert(ok, result)
            if coroutine.status(job) ~= "dead" then return end
            complete = true
            assert(result.cases == 16 and result.assertions > 300 and result.native_actions == 0,
                string.format("unexpected trick coverage: %s/%s", tostring(result.cases), tostring(result.assertions)))
            assert(completed_cases == result.cases and completed_assertions == result.assertions,
                "trick final coverage must match every yielded case")
            reskate.log(string.format("BMX Lua tricks: %d cases, %d assertions, 0 native actions", result.cases, result.assertions))
        end)
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-trick-tests", files)});
    running(host, "bmx-lua-trick-tests", environment);
    check(!environment.logged("BMX Lua tricks:"), "Trick regressions do not execute during startup");
    // Four cold modules, sixteen cases and one final return. Each call keeps
    // the actual Host's unchanged production limits; no case is skipped.
    for (unsigned tick = 0; tick < 21; ++tick) {
        environment.now += 1000.0 / 60.0;
        host.tick(1000.0 / 60.0);
        running(host, "bmx-lua-trick-tests", environment);
        if (tick < 20) check(!environment.logged("BMX Lua tricks:"), "Trick suite cannot complete before all sixteen case boundaries");
    }
    check(environment.logged("BMX Lua tricks: 16 cases") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
              environment.teleports.empty() && environment.rays == 0,
          "Actual Lua trick modules run without native services or gameplay permissions\n" + environment.all());
    const auto completed = environment.all();
    for (unsigned idle = 0; idle < 2; ++idle) {
        environment.now += 1000.0 / 60.0;
        host.tick(1000.0 / 60.0);
        running(host, "bmx-lua-trick-tests", environment);
    }
    check(environment.all() == completed, "The trick regression suite runs only once");
}

void bmx_lua_forces_use_actual_modules_and_match_the_portable_kernel() {
    namespace chassis = dingosdk::bmx::chassis_control;
    using dingosdk::Json;
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    std::map<std::string, std::string> files{{manifest_file, R"({"api":1,"entry":"plugin/main.lua","permissions":[]})"}};
    for (const auto* name : {"force_math.lua", "tire.lua", "brake.lua", "pump.lua", "force_solver.lua", "forces.lua", "force_tests.lua"}) {
        std::ifstream file(directory / "plugin" / name, std::ios::binary);
        check(file.good(), std::string("BMX Lua force source is available: ") + name);
        files[std::string("plugin/") + name] = std::string(std::istreambuf_iterator<char>(file), {});
    }
    Json reference = Json::array();
    const auto append = [&](double speed, chassis::Controls controls, const char* status = "hit", double separation = 0,
                            double h = chassis::verified_native_seconds, double bank = 0, double tilt = 0,
                            double longitudinal = 1, double lateral = 1, unsigned variant = 0) {
        auto body = chassis::proposed_body(); body.center_of_mass = {0, .9, -.05}; body.linear_velocity = {0, 0, speed};
        body.orientation = {std::cos(bank / 2) * std::sin(tilt / 2), std::sin(bank / 2) * std::sin(tilt / 2),
                            std::sin(bank / 2) * std::cos(tilt / 2), std::cos(bank / 2) * std::cos(tilt / 2)};
        const auto turn = [&](chassis::Vec v) { return chassis::detail::turn(body.orientation, v); };
        body.center_of_mass = turn(body.center_of_mass); body.linear_velocity = turn(body.linear_velocity);
        if (bank != 0 || tilt != 0) body.angular_velocity = turn({.07, -.11, .03});
        auto wheels = chassis::proposed_wheels(); for (auto& wheel : wheels) wheel.angular_speed = speed / wheel.radius;
        if (variant) {
            body.inertia_body = variant == 7 ? chassis::Vec{1e9, 1e9, 1e9} : chassis::Vec{11, 37, 5};
            body.center_of_mass = chassis::detail::add(body.center_of_mass, {3, 1, -2});
            wheels[0].radius *= .9; wheels[0].inertia *= .7; wheels[1].radius *= 1.1; wheels[1].inertia *= 1.3;
            for (auto& wheel : wheels) wheel.angular_speed = speed / wheel.radius;
        }
        std::array<chassis::ContactSample, 2> samples{};
        for (unsigned i = 0; i < 2; ++i) {
            auto& sample = samples[i]; sample.separation = separation;
            sample.contact.status = std::string_view(status) == "hit" ? dingosdk::bmx::tire::ContactStatus::hit :
                std::string_view(status) == "clear" ? dingosdk::bmx::tire::ContactStatus::clear : dingosdk::bmx::tire::ContactStatus::unavailable;
            sample.contact.point = turn({0, 0, i == 0 ? .525 : -.525});
            sample.contact.normal = turn({0, 1, 0}); sample.contact.forward = turn({0, 0, 1});
            if (variant) sample.contact.point = chassis::detail::add(sample.contact.point, {3, 1, -2});
            if (variant && variant % 3 == i + 1) sample.contact.status = dingosdk::bmx::tire::ContactStatus::clear;
        }
        chassis::Tuning tuning; tuning.friction = {longitudinal, lateral};
        if (variant) {
            tuning.contact_iterations = variant % 2 ? 1 : 3;
            tuning.brake_iterations = variant % 3 == 0 ? 96 : variant % 2 ? 1 : 3;
            if (variant % 4 == 1) tuning.front_brake_torque = 0;
            if (variant % 4 == 2) tuning.rear_brake_torque = 0;
            if (variant == 6) tuning.force_limit = 100;
        }
        chassis::Controller controller{tuning};
        const auto out = controller.step(h, body, wheels, samples, controls);
        Json expected{{"valid", out.valid}, {"grounded", out.grounded}, {"hop_applied", out.hop_applied},
            {"force", out.force}, {"torque", out.torque}, {"hop_impulse", out.hop_impulse},
            {"normal_load", out.normal_load}, {"normal_impulse", out.normal_impulse}, {"longitudinal_impulse", out.longitudinal_impulse},
            {"lateral_impulse", out.lateral_impulse}, {"brake_impulse", out.brake_impulse}, {"front_steer_angle", out.front_steer_angle},
            {"requested_front_steer_angle", out.requested_front_steer_angle}, {"turning_lean_angle", out.turning_lean_angle},
            {"contact_scale", out.contact_scale}, {"spin", Json::array({out.wheels[0].angular_speed, out.wheels[1].angular_speed})}};
        constexpr const char* issues[]{"none", "unsupported_step", "invalid_sample", "unavailable_contact", "penetration_limit", "output_limit"};
        expected["issue"] = issues[static_cast<unsigned>(out.issue)]; expected["consumed_hop"] = controller.consumed_hop_event_id();
        Json input{{"enabled", controls.enabled}, {"pedal", controls.pedal}, {"brake", controls.brake}, {"steer", controls.steer},
            {"manual", controls.manual}, {"nose_manual", controls.nose_manual}, {"air_yaw", controls.air_yaw},
            {"hop_strength", controls.hop_strength}, {"hop_event_id", controls.hop_event_id}};
        Json input_body{{"mass", body.mass}, {"inertia_body", body.inertia_body}, {"orientation", body.orientation},
            {"center_of_mass", body.center_of_mass}, {"linear_velocity", body.linear_velocity}, {"angular_velocity", body.angular_velocity}};
        Json input_wheels = Json::array(), input_samples = Json::array();
        for (unsigned i = 0; i < 2; ++i) {
            input_wheels.push_back(Json{{"radius", wheels[i].radius}, {"inertia", wheels[i].inertia}, {"angular_speed", wheels[i].angular_speed}});
            const auto& s = samples[i];
            const char* actual_status = s.contact.status == dingosdk::bmx::tire::ContactStatus::hit ? "hit" :
                s.contact.status == dingosdk::bmx::tire::ContactStatus::clear ? "clear" : "unavailable";
            input_samples.push_back(Json{{"contact", Json{{"status", actual_status}, {"point", s.contact.point}, {"normal", s.contact.normal},
                {"forward", s.contact.forward}, {"surface_velocity", s.contact.surface_velocity}}}, {"separation", separation}});
        }
        reference.push_back(Json{{"body", input_body}, {"wheels", input_wheels}, {"samples", input_samples}, {"h", h},
            {"tuning", Json{{"friction", Json{{"longitudinal_friction", longitudinal}, {"lateral_friction", lateral}}},
                {"contact_iterations", tuning.contact_iterations}, {"brake_iterations", tuning.brake_iterations}, {"front_brake_torque", tuning.front_brake_torque},
                {"rear_brake_torque", tuning.rear_brake_torque}, {"force_limit", tuning.force_limit}}}, {"controls", input}, {"result", expected}});
    };
    append(0, {});
    append(5, chassis::Controls{.pedal = 1});
    for (double speed : {-8., 2., 8.}) for (double steer : {-1., 1.}) append(speed, chassis::Controls{.steer = steer});
    append(5, chassis::Controls{.brake = 1}); append(-5, chassis::Controls{.brake = 1});
    append(0, chassis::Controls{.manual = 1}); append(0, chassis::Controls{.nose_manual = 1});
    append(0, chassis::Controls{.hop_strength = 1, .hop_event_id = 1});
    append(0, chassis::Controls{.hop_strength = .25, .hop_event_id = 1});
    append(0, chassis::Controls{.air_yaw = 1}, "clear"); append(0, chassis::Controls{.manual = 1}, "clear");
    append(0, {}, "unavailable"); append(0, {}, "hit", 0, chassis::verified_native_seconds * 2);
    append(0, chassis::Controls{.hop_strength = 1, .hop_event_id = 1}, "hit", .01);
    for (double bank : {-.2, .2}) for (double tilt : {-.15, .15}) for (double speed : {-4., 4.})
        for (const auto friction : {std::array<double, 2>{0, 1}, std::array<double, 2>{1, 0}, std::array<double, 2>{.3, .8}}) {
            append(speed, chassis::Controls{.brake = 1, .steer = .5}, "hit", -.002, chassis::verified_native_seconds, bank, tilt, friction[0], friction[1]);
            append(speed, chassis::Controls{.steer = -.7, .manual = .2}, "hit", 0, chassis::verified_native_seconds, bank, tilt, friction[0], friction[1]);
        }
    for (unsigned variant = 1; variant <= 7; ++variant) {
        append(3, chassis::Controls{.brake = 1, .steer = -.4}, "hit", -.001, chassis::verified_native_seconds, .2, -.15, .7, .3, variant);
        append(-3, chassis::Controls{.steer = .4}, "hit", 0, chassis::verified_native_seconds, -.2, .15, .3, .7, variant);
    }
    append(0, chassis::Controls{.hop_strength = 1, .hop_event_id = 7}, "clear");
    append(0, chassis::Controls{.enabled = false, .hop_strength = 1, .hop_event_id = 7});
    Json projections = Json::array();
    const auto projection = [&](chassis::coupled_brake::Matrix k, std::array<double, 3> g, std::array<double, 3> limits) {
        std::array<double, 3> impulse{};
        const bool valid = chassis::coupled_brake::detail::constrained(k, g, limits, impulse);
        projections.push_back(Json{{"k", k}, {"g", g}, {"limits", limits}, {"valid", valid}, {"impulse", impulse}});
    };
    const chassis::coupled_brake::Matrix identity{{{{1, 0, 0}}, {{0, 1, 0}}, {{0, 0, 1}}}};
    const chassis::coupled_brake::Matrix nonsymmetric{{{{2, .25, -.5}}, {{.3, 1, -.2}}, {{-.4, -.3, 2}}}};
    projection(identity, {.2, .1, 100}, {1, 1, 1}); projection(identity, {.2, .1, -100}, {1, 1, 1});
    projection(nonsymmetric, {2, 1, 100}, {1, 1, 1}); projection(nonsymmetric, {2, 1, -100}, {1, 1, 1});
    projection(identity, {.2, -.3, .1}, {1, 1, 1});
    projection(identity, {.2, .1, 1 + 1e-13}, {1, 1, 1}); projection(identity, {.2, .1, -1 - 1e-13}, {1, 1, 1});
    projection({{{{1, 0, 2}}, {{0, 1, 0}}, {{2, 0, 1}}}}, {0, 0, 100}, {1, 1, 1});
    projection(identity, {10, 3, 100}, {0, 1, 1}); projection(identity, {3, 10, 100}, {1, 0, 1});
    projection(identity, {10, 3, 100}, {1, 1, 0});
    projection({{{{1e200, 0, 0}}, {{0, 1e-200, 0}}, {{0, 0, 1}}}}, {1e199, 0, 0}, {1, 1, 1});
    projection({{{{1e-200, 0, 0}}, {{0, 1e-200, 0}}, {{0, 0, 1}}}}, {1, 1, 0}, {1, 1, 1});
    projection({{{{1, 0, 0}}, {{0, 1e-14, 0}}, {{0, 0, 1}}}}, {3, 1e-10, .5}, {1, 1, 1});
    projection(identity, {2, 1, -10}, {0, 0, 1});
    projection({{{{1, 2, 0}}, {{2, 1, 0}}, {{0, 0, 1}}}}, {0, 0, 100}, {1, 1, 1});
    // Actual slope solves reached these valid brackets only two to nine ULPs
    // wide. Endpoint stagnation or twelve valid probes must retain refinement.
    projection({{{{1.225284966024359, -3.683471955280575e-17, 0}},
                  {{-3.683471955280575e-17, .4929425291155018, 0}}, {{0, 0, 1}}}},
               {17.01065392498224, 2.800646359863398, 0}, {1, 1, 1});
    projection({{{{2.3255356081490772, -.02506090728327499, 0}},
                  {{-.02506090728327499, .18581329903843272, 0}}, {{0, 0, 1}}}},
               {3.2303603001549694, 2.4246027387432054, 0}, {1, 1, 1});
    files["plugin/main.lua"] = "local reference = reskate.json.decode([=[" + reference.dump() + "]=])\nlocal projections = reskate.json.decode([=[" + projections.dump() + R"(]=])
        local result = require("./force_tests").run(reference, projections)
        assert(result.cases == 25 and result.assertions > 1800 and result.comparisons == 83 and result.projections == 18 and result.native_actions == 0,
            string.format("unexpected force coverage: %s/%s/%s", tostring(result.cases), tostring(result.assertions), tostring(result.comparisons)))
        reskate.log(string.format("BMX Lua forces: %d cases, %d assertions, %d C++ comparisons, %d direct projections, 0 native actions", result.cases, result.assertions, result.comparisons, result.projections))
    )";
    TestEnvironment environment;
    // This exhaustive offline regression performs many steps in one load call.
    // Raising only this test's ceiling does not qualify a real-time controller.
    Limits limits; limits.call_ms = 2000;
    Host host(environment, Side::client, limits);
    host.apply({package("bmx-lua-force-tests", files)});
    running(host, "bmx-lua-force-tests", environment);
    check(environment.logged("BMX Lua forces: 25 cases") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
              environment.fake.body_creates == 0 && environment.fake.body_submissions == 0 && environment.teleports.empty() && environment.rays == 0,
          "Pure force modules and actual C++ arithmetic agree without native services or permissions\n" + environment.all());
    std::cout << environment.all();
}

// A plugin's own page in the menu's PLUGINS section: named in the section, built only while the menu
// shows it, page first and its panels after, with cards, tabs, info lines and help.
void plugins_have_pages() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("pages", R"(
        local tab, on, strength = 1, false, 50
        reskate.menu.page("Tools", function(ui)
            tab = ui:tabs("tabs", {"MAIN", "MORE"}, tab)
            ui:card("SWITCHES", "What it does")
            on = ui:toggle("on", "Switch", on, "Turns it on")
            strength = ui:slider("strength", "Strength", strength, 10, 100, "%d%%")
            ui:info("Status", "fine")
            ui:note("A note")
            ui:warn("A warning")
            ui:button("go", "GO", true)
            assert(not pcall(ui.slider, ui, "bad", "Bad", 1, 0, 2, "%s"), "a slider's format is one number")
            assert(not pcall(ui.slider, ui, "bad2", "Bad", 1, 0, 2, "%f %f"), "and only one")
        end)
        assert(not pcall(reskate.menu.page, "Again", function() end), "one page")
        assert(not pcall(reskate.menu.panel, "Tools", function() end), "a panel cannot share the page's title")
        reskate.menu.panel("Extra", function(ui) ui:label("more") end)
        reskate.console.command("state", "x", function() reskate.log(string.format("state %d %s %.0f", tab, tostring(on), strength)) end)
    )", R"("console", "menu")"), script("others", R"(
        reskate.menu.panel("Theirs", function(ui) ui:label("theirs") end)
    )", R"("menu")")});
    running(host, "pages", environment);
    running(host, "others", environment);
    ticks(host, environment, 10);
    check(environment.pages.size() == 2 && environment.pages[0] == plugin_ui::PageEntry{"others", "others"} &&
              environment.pages[1] == plugin_ui::PageEntry{"pages", "Tools"},
          "The PLUGINS section names each plugin's page: its title, or its id with panels only");
    check(environment.panels.empty(), "Nothing is built while no page shows");
    environment.panels_open = true;
    environment.shown = "pages";
    ticks(host, environment, 10);
    check(environment.panels.size() == 2 && environment.panels[0].page && environment.panels[0].title == "Tools" && !environment.panels[1].page &&
              environment.panels[1].title == "Extra",
          "The shown plugin's page is built, then its panels, and no other plugin's\n" + environment.all());
    using K = plugin_ui::Widget::Kind;
    const auto& w = environment.panels[0].widgets;
    check(w.size() == 8 && w[0].kind == K::tabs && w[0].choices.size() == 2 && w[1].kind == K::card && w[1].help == "What it does" &&
              w[2].help == "Turns it on" && w[3].format == "%.0f%%" && w[4].kind == K::info && w[4].help == "fine" && w[5].kind == K::note &&
              w[6].kind == K::warn && w[7].on,
          "with its tabs, cards, help, the slider's format, info lines, notes and a main button");
    using A = plugin_ui::Action;
    environment.actions = {A{"pages", "Tools", "tabs", false, 0, 2}, A{"pages", "Tools", "on", true}, A{"pages", "Tools", "strength", false, 75}};
    ticks(host, environment, 10);
    host.run_console("state");
    check(environment.logged("state 2 true 75"), "What the player did on it reaches the plugin\n" + environment.all());
}

// A 16-bit mono WAVE file of `samples` at `rate`.
std::string wave_file(unsigned rate, std::size_t samples) {
    std::string out = "RIFF";
    const auto put = [&](std::uint32_t v, int bytes) {
        for (int i = 0; i < bytes; ++i) out.push_back(static_cast<char>((v >> (8 * i)) & 0xff));
    };
    put(static_cast<std::uint32_t>(36 + samples * 2), 4);
    out += "WAVEfmt ";
    put(16, 4);
    put(1, 2);
    put(1, 2);
    put(rate, 4);
    put(rate * 2, 4);
    put(2, 2);
    put(16, 2);
    out += "data";
    put(static_cast<std::uint32_t>(samples * 2), 4);
    for (std::size_t i = 0; i < samples; ++i) put(static_cast<std::uint32_t>(static_cast<std::int16_t>((i % 20) * 1000)) & 0xffff, 2);
    return out;
}

void plugins_play_their_own_sounds() {
    std::string error;
    const auto bytes = wave_file(8000, 4000);
    const auto wave = decode_wave(std::span<const std::uint8_t>(reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size()), 30, error);
    check(wave && wave->samples.size() == 8000, "Half a second at 8 kHz is half a second at 16 kHz: " + error);
    check(!decode_wave(std::span<const std::uint8_t>(reinterpret_cast<const std::uint8_t*>(bytes.data()), bytes.size()), 0.25f, error),
          "and a sound longer than allowed is refused");
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("noisy", {{manifest_file, manifest(R"("console", "audio")")}, {"sounds/beep.wav", bytes}, {"notes.txt", "x"},
                                  {"plugin/main.lua", R"(
        reskate.console.command("noise", "x", function()
            local beep = assert(reskate.audio.play("sounds/beep.wav", {volume = 0.5, pitch = 2, loop = true, position = vector.create(1, 2, 3)}))
            local motor = assert(reskate.audio.play("motor", {throttle = 0.4, speed = 10}))
            assert(reskate.audio.set(motor, {throttle = 0.9, position = "skater"}))
            assert(reskate.audio.playing(beep))
            reskate.audio.stop(beep)
            assert(not pcall(reskate.audio.play, "notes.txt"), "a wave")
            assert(not pcall(reskate.audio.play, "../x/beep.wav"), "its own package")
            assert(not pcall(reskate.audio.play, "sounds/beep.wav", {volume = 3}), "a sane volume")
            reskate.log("sounded")
        end)
    )"}})});
    running(host, "noisy", environment);
    host.run_console("noise");
    check(environment.logged("[noisy] sounded"), "A plugin plays its own sounds\n" + environment.all());
    for (const auto* call : {"sound noisy 8000 0.50 2.00 true at 1 2 3", "sound noisy motor 1.00 1.00 false", "change noisy 2 0.9 skater", "stop sound noisy 1"})
        check(environment.fake.called(call), std::string("The game was asked: ") + call + "\n" + environment.all());
}

void plugins_play_sounds_and_read_the_mods() {
    TestEnvironment environment;
    environment.mod_list = {{"Owner-Map", "A Map", true}, {"OldThing", "Old Thing", false}};
    Host host(environment, Side::client);
    host.apply({script("listener", R"(
        reskate.console.command("sounds", "x", function()
            local played = 0
            for i = 1, 20 do if reskate.audio.play_ui("select") then played += 1 end end
            reskate.log("played " .. played)
            assert(not pcall(reskate.audio.play_ui, "explosion"), "a sound there is not")
        end)
        reskate.console.command("mods", "x", function()
            reskate.log(string.format("mods %s %s %s %s %d", tostring(reskate.mods.installed("a map")), tostring(reskate.mods.installed("OWNER-MAP")),
                tostring(reskate.mods.installed("Old Thing")), tostring(reskate.mods.installed("nothing")), #reskate.mods.list()))
        end)
    )", R"("console", "audio.ui", "mods.read")")});
    host.run_console("sounds");
    check(environment.logged("played 10") && environment.sounds.size() == 10, "Ten sounds a second\n" + environment.all());
    host.run_console("mods");
    check(environment.logged("mods on on off nil 2"), "Mods by folder or title, on or off\n" + environment.all());
}

// Two games in one session, each with the same plugin, passing messages through their hosts.
void plugins_follow_the_session_and_message_each_other() {
    TestEnvironment a, b;
    a.session_now = {true, false, {{1, "Ann", true, true}, {2, "Bob", false, false}}};
    b.session_now = {true, false, {{2, "Bob", true, false}, {1, "Ann", false, true}}};
    const auto main = R"(
        reskate.on("player_joined", function(p) reskate.log("joined " .. p.name .. " " .. p.id .. (p.me and " me" or "") .. (p.host and " host" or "")) end)
        reskate.on("player_left", function(p) reskate.log("left " .. p.name) end)
        reskate.on("message", function(from, text) reskate.log("from " .. from.name .. ": " .. text) end)
        reskate.console.command("hello", "x", function(args)
            local s = reskate.session
            reskate.log(string.format("session %s %s %d me %s host %s", tostring(s.active()), tostring(s.is_dedicated()), #s.players(),
                s.me().name, s.host().name))
            assert(reskate.net.send(args[1] or "all", "hi from " .. s.me().name))
        end)
        reskate.console.command("alone", "x", function()
            reskate.log("alone " .. tostring(reskate.net.send("all", "x")) .. " " .. tostring(reskate.session.active()) .. " " .. #reskate.session.players())
        end)
        reskate.console.command("flood", "x", function()
            local ok, err = pcall(function() for i = 1, 10 do reskate.net.send("all", string.rep("x", 4000)) end end)
            reskate.log("flood " .. tostring(err):match("more than %d+ KB") )
            assert(not pcall(reskate.net.send, "all", string.rep("x", 5000)), "too big")
            assert(not pcall(reskate.net.send, "nobody", "x"), "not a player")
        end)
    )";
    // Each game's folder for it is named differently: the messages go by its manifest.json name.
    auto first = package("chat-a", {{manifest_file, manifest(R"("console", "session.read", "net.session")")}, {"manifest.json", R"({"name": "Chatter"})"}, {"plugin/main.lua", main}});
    auto second = package("chat-b", {{manifest_file, manifest(R"("console", "session.read", "net.session")")}, {"manifest.json", R"({"name": "Chatter"})"}, {"plugin/main.lua", main}});
    auto other = package("other", {{manifest_file, manifest(R"("net.session")")}, {"manifest.json", R"({"name": "Other"})"}, {"plugin/main.lua",
        R"(reskate.on("message", function(from, text) reskate.log("other heard " .. text) end))"}});
    Host host_a(a, Side::client), host_b(b, Side::client);
    host_a.apply({first});
    host_b.apply({second, other});
    ticks(host_a, a, 1);
    ticks(host_b, b, 1);
    check(a.logged("[chat-a] joined Ann 1 me host") && a.logged("[chat-a] joined Bob 2"), "Players in the session are heard\n" + a.all());
    host_a.run_console("hello");
    check(a.logged("session true false 2 me Ann host Ann"), "The session reads\n" + a.all());
    check(a.sent.size() == 1 && wire::is_plugin(a.sent[0]), "A message goes out as a plugin message");
    for (auto& bytes : a.sent) b.incoming.push_back({1, bytes});
    a.sent.clear();
    ticks(host_b, b, 1);
    check(b.logged("[chat-b] from Ann: hi from Ann") && !b.logged("other heard"), "and reaches the same plugin only\n" + b.all());
    host_a.run_console("hello 3");
    for (auto& bytes : a.sent) b.incoming.push_back({1, bytes});
    a.sent.clear();
    ticks(host_b, b, 1);
    check(std::count_if(b.logs.begin(), b.logs.end(), [](const auto& l) { return l.find("from Ann") != std::string::npos; }) == 1,
          "A message for another player is not delivered here");
    b.incoming.push_back({1, {0xD1, 1, 1, 2}});
    b.incoming.push_back({1, {7, 7, 7}});
    ticks(host_b, b, 1);
    running(host_b, "chat-b", b);
    host_a.run_console("flood");
    check(a.logged("flood more than 16 KB"), "16 KB a second\n" + a.all());
    a.session_now.players.pop_back();
    ticks(host_a, a, 1);
    check(a.logged("[chat-a] left Bob"), "A player who leaves is heard");
    a.session_now = {};
    ticks(host_a, a, 1);
    a.now += 1000; // past the flood's second
    host_a.run_console("alone");
    check(a.logged("alone false false 0"), "Without a session nothing is sent\n" + a.all());
    running(host_a, "chat-a", a);
}

// A game mode's rules in the plugin's server copy: players' copies talk to it, it answers everyone.
void plugins_server_copies_are_the_authority() {
    TestEnvironment server, player;
    server.session_now = {true, false, {{1, "Ann", true, true}, {2, "Bob", false, false}}};
    player.session_now = {true, false, {{2, "Bob", true, false}, {1, "Ann", false, true}}};
    const std::string main = R"(
        reskate.log("side " .. reskate.side)
        local E = reskate.Enums
        assert(E.Side.server == "server" and E.Event.tick == "tick" and E.Key.Enter == "Enter" and E.LogLevel.warn == "warn"
            and E.Target.all == "all" and E.EntityStatus.ready == "ready" and E.Throwdown.spot_battle == "spot_battle")
        assert(not pcall(function() E.Pop.huge = "huge" end), "an enum is read-only")
        reskate.log("enum check", E.LogLevel.warn)
        if reskate.side == E.Side.server then
            reskate.on("message", function(from, text)
                reskate.log("server heard " .. text .. " from " .. from.name)
                assert(reskate.net.send(reskate.Enums.Target.all, "state " .. text))
                assert(reskate.server.kick(from, "testing"))
                assert(reskate.server.say("round over"))
                assert(not pcall(reskate.net.send, "server", "x"), "it is the server")
            end)
        else
            reskate.on("message", function(from, text) reskate.log("player heard " .. text .. " server " .. tostring(from.server)) end)
            reskate.console.command("join", "x", function()
                assert(reskate.net.send("server", "hello"))
                local ok, err = pcall(reskate.server.kick, "1")
                assert(not ok and err:find("server copy"), err)
            end)
        end
    )";
    const auto mode = [&](const char* id) {
        return package(id, {{manifest_file, manifest(R"("console", "net.session", "server")", "both")}, {"manifest.json", R"({"name": "Mode"})"},
                            {"plugin/main.lua", main}});
    };
    Host server_host(server, Side::server), player_host(player, Side::client);
    server_host.apply({mode("mode-s")});
    player_host.apply({mode("mode-p")});
    ticks(server_host, server, 1);
    ticks(player_host, player, 1);
    check(server.logged("[mode-s] side server") && player.logged("[mode-p] side client"), "Each copy knows its side\n" + server.all() + player.all());
    player_host.run_console("join");
    check(player.sent.size() == 1 && wire::to_of(player.sent[0]) == wire::authority && !wire::from_authority(player.sent[0]) &&
          !wire::relayed(player.sent[0]), "A player's copy speaks to the authority, and no relay passes that on\n" + player.all());
    player_host.apply({});
    player_host.apply({mode("mode-p")});
    ticks(player_host, player, 1);
    player.incoming.push_back({2, player.sent[0]});
    ticks(player_host, player, 1);
    check(!player.logged("player heard hello"), "What is for the authority is not heard by players' copies");
    server.incoming.push_back({2, player.sent[0]});
    ticks(server_host, server, 1);
    check(server.logged("[mode-s] server heard hello from Bob"), "The server copy hears it, from the player\n" + server.all());
    check(server.fake.called("kick 2 testing") && server.fake.called("announce Mode round over"), "and rules: a kick, a line to everyone");
    check(server.sent.size() == 1 && wire::from_authority(server.sent[0]) && !wire::relayed(server.sent[0]), "Its answer is the authority's");
    player.incoming.push_back({1, server.sent[0]});
    ticks(player_host, player, 1);
    check(player.logged("[mode-p] player heard state hello server true"), "and players' copies hear it from the server\n" + player.all());
    running(server_host, "mode-s", server);
    running(player_host, "mode-p", player);
}

// A dedicated server's park mods, for a server copy with server.parks: listed, spawned and removed
// as the server's park-mod does. Not for a copy without the permission, nor for a player's copy.
// One player hidden from others, for a server copy with "server": wholly (skater, name, voice,
// sound) or only their voice or sound, from a player, a list of them or "all", and shown again.
// Not for a copy without the permission, nor for a player's copy.
void plugins_server_copies_hide_players() {
    TestEnvironment server, player, blind;
    const std::string main = R"(
        reskate.console.command("hide", "x", function()
            assert(reskate.server.hide("7", "all"))
            assert(reskate.server.hide({id = "7"}, {"8", {id = "5"}}))
            assert(reskate.server.hide("7", "8", {skater = false, voice = true, sound = false}))
            assert(reskate.server.hide("7", "8", {skater = false, sound = true}))
            assert(reskate.server.hide("7", "8", {skater = true, name = true}))
            local ok, why = reskate.server.hide("9", "8")
            assert(not ok and why == "that player is not on the server", tostring(why))
            assert(reskate.server.unhide("7", "8"))
            assert(reskate.server.unhide("7"))
            assert(not pcall(reskate.server.hide, "7"), "who it is hidden from")
            assert(not pcall(reskate.server.hide, "7", {}), "at least one viewer")
            assert(not pcall(reskate.server.hide, "7", "8", {skater = false, voice = false, sound = false}), "it hides something")
            assert(not pcall(reskate.server.hide, "7", "8", {skater = true, voice = false}), "a hidden skater's voice goes too")
            assert(not pcall(reskate.server.hide, "7", "8", {skater = false, name = true}), "the name goes with the skater")
            assert(not pcall(reskate.server.hide, "7", "8", {colour = true}), "only skater, name, voice and sound")
            assert(not pcall(reskate.server.hide, "7", "8", {skater = "yes"}), "true or false")
            assert(not pcall(reskate.server.unhide, "nobody"), "a player")
            reskate.log("hide done")
        end)
    )";
    const auto hider = [&](const char* id, const char* permissions, const char* side) {
        return package(id, {{manifest_file, manifest(permissions, side)}, {"plugin/main.lua", main}});
    };
    Host server_host(server, Side::server), player_host(player, Side::client), blind_host(blind, Side::server);
    server_host.apply({hider("hide-s", R"("console", "server")", "server")});
    player_host.apply({hider("hide-p", R"("console", "server")", "client")});
    blind_host.apply({hider("hide-b", R"("console")", "server")});
    for (auto* host : {&server_host, &player_host, &blind_host}) host->run_console("hide");
    check(server.logged("[hide-s] hide done"), "A server copy could not hide players\n" + server.all());
    for (const auto* call : {"hide hide-s 7 from all skater true voice true sound true", "hide hide-s 7 from 8,5 skater true voice true sound true",
                             "hide hide-s 7 from 8 skater false voice true sound false", "hide hide-s 7 from 8 skater false voice true sound true",
                             "hide hide-s 9 from 8 skater true voice true sound true", "unhide hide-s 7 from 8", "unhide hide-s 7 from all"})
        check(server.fake.called(call), std::string("The server was asked: ") + call + "\n" + server.all());
    check(!server.fake.called("hide hide-s 7 from 8 skater false voice false sound false") && !server.fake.called("unhide hide-s 0"),
          "A refused call reached the server");
    check(!player.logged("hide done") && player.all().find("server copy") != std::string::npos, "A player's copy hid players\n" + player.all());
    check(!blind.logged("hide done") && blind.all().find("\"server\"") != std::string::npos, "A plugin without server hid players\n" + blind.all());
    running(server_host, "hide-s", server);
}

void plugins_server_copies_spawn_park_mods() {
    TestEnvironment server, player, blind;
    const std::string main = R"(
        reskate.console.command("parks", "x", function()
            local list = reskate.server.parks()
            assert(#list == 2 and list[1].name == "street" and list[1].here and list[1].spawned and list[1].objects == 12 and list[1].minutes_left == 5)
            assert(list[2].map == "Isle of Grom" and not list[2].here and not list[2].spawned)
            assert(reskate.server.park_spawn("street", 30))
            assert(reskate.server.park_spawn("street"))
            local ok, why = reskate.server.park_spawn("plaza")
            assert(not ok and why:find("belongs on Isle of Grom"), why)
            assert(reskate.server.park_remove("street"))
            assert(not pcall(reskate.server.park_spawn, "Street"), "a park mod's name, lower case")
            assert(not pcall(reskate.server.park_spawn, "street 5; map grom"), "one name and nothing else")
            assert(not pcall(reskate.server.park_spawn, "street", 0), "minutes 1 to 1440")
            assert(not pcall(reskate.server.park_spawn, "street", 1441), "minutes 1 to 1440")
            reskate.log("parks done")
        end)
    )";
    const auto parks = [&](const char* id, const char* permissions, const char* side) {
        return package(id, {{manifest_file, manifest(permissions, side)}, {"plugin/main.lua", main}});
    };
    Host server_host(server, Side::server), player_host(player, Side::client), blind_host(blind, Side::server);
    server_host.apply({parks("parks-s", R"("console", "server.parks")", "server")});
    player_host.apply({parks("parks-p", R"("console", "server.parks")", "client")});
    blind_host.apply({parks("parks-b", R"("console", "server")", "server")});
    for (auto* host : {&server_host, &player_host, &blind_host}) host->run_console("parks");
    check(server.logged("[parks-s] parks done"), "A server copy could not use the park mods\n" + server.all());
    check(server.fake.called("park spawn parks-s street 30") && server.fake.called("park spawn parks-s street 0") &&
              server.fake.called("park spawn parks-s plaza 0") && server.fake.called("park remove parks-s street"),
          "The spawns and removal did not reach the server, by the plugin's id");
    check(!server.fake.called("park spawn parks-s Street") && !server.fake.called("park spawn parks-s street 1441"), "A refused call reached the server");
    check(!player.logged("parks done") && player.all().find("server copy") != std::string::npos,
          "A player's copy used the server's park mods\n" + player.all());
    check(!blind.logged("parks done") && blind.all().find("server.parks") != std::string::npos,
          "A plugin without server.parks used the park mods\n" + blind.all());
}

// A player's role, for a server copy with server: read-only, nil for one with none. Not for a copy
// without the permission, nor for a player's copy.
void plugins_server_copies_see_roles() {
    TestEnvironment server, player, blind;
    for (auto* environment : {&server, &player, &blind}) environment->session_now = {true, false, {{1, "Ann", false, false}, {2, "Bob", false, false}}};
    const std::string main = R"(
        reskate.console.command("roles", "x", function()
            local ann, bob = reskate.session.players()[1], reskate.session.players()[2]
            local role = ann.role
            assert(role and role.name == "moderator" and role.rank == 50 and role.staff == true)
            assert(not pcall(function() role.rank = 1000 end), "read-only")
            assert(bob.role == nil, "nil with no role")
            reskate.log("roles done")
        end)
    )";
    const auto roles = [&](const char* id, const char* permissions, const char* side) {
        return package(id, {{manifest_file, manifest(permissions, side)}, {"plugin/main.lua", main}});
    };
    Host server_host(server, Side::server), player_host(player, Side::client), blind_host(blind, Side::server);
    server_host.apply({roles("roles-s", R"("console", "session.read", "server")", "server")});
    player_host.apply({roles("roles-p", R"("console", "session.read", "server")", "client")});
    blind_host.apply({roles("roles-b", R"("console", "session.read")", "server")});
    // a tick first: the host takes the session's players then (Host::follow_session), so they are there to ask
    ticks(server_host, server, 1);
    ticks(player_host, player, 1);
    ticks(blind_host, blind, 1);
    for (auto* host : {&server_host, &player_host, &blind_host}) host->run_console("roles");
    check(server.logged("[roles-s] roles done"), "A server copy could not read the players' roles\n" + server.all());
    check(!player.logged("roles done") && player.all().find("server copy") != std::string::npos,
          "A player's copy read the players' roles\n" + player.all());
    check(!blind.logged("roles done") && blind.all().find("\"server\"") != std::string::npos,
          "A plugin without server read the players' roles\n" + blind.all());
}

// Cards and polls on players' screens, for a server copy with "server": for a player, a list of
// them or "all", with checked text, and each answer or close coming back as an event to the plugin
// that asked. Not for a copy without the permission, nor for a player's copy.
void plugins_server_copies_show_cards_and_polls() {
    TestEnvironment server, player, blind;
    const std::string main = R"(
        local heard = pcall(reskate.on, "poll_answer", function(e)
            reskate.log(string.format("answer %d %s %d %s", e.id, e.player, e.answer, e.text))
        end)
        pcall(reskate.on, "poll_closed", function(e) reskate.log(string.format("closed %d %s %s", e.id, e.player, e.why)) end)
        if not heard then reskate.log("no poll events") end
        reskate.console.command("cards", "x", function()
            assert(reskate.server.card("all", "Race in 30 s"))
            assert(reskate.server.card({"7", {id = "8"}}, "Ready?", 5))
            assert(reskate.server.card({id = "7"}, "Go"))
            local id = assert(reskate.server.poll("all", "Next track?", {"Docks", "Hill"}, {seconds = 20}))
            assert(id == 41, tostring(id))
            assert(reskate.server.poll("7", "Again?", {"Yes", "No", "Later"}) == 42)
            local none, why = reskate.server.poll("9", "Anyone?", {"a", "b"})
            assert(none == nil and why == "that player is not on the server", tostring(why))
            assert(reskate.server.poll_close(41))
            assert(not pcall(reskate.server.card, "all", ""), "a card says something")
            assert(not pcall(reskate.server.card, "all", string.rep("x", 121)), "120 characters at most")
            assert(not pcall(reskate.server.card, "all", "x", 0), "1 to 60 s")
            assert(not pcall(reskate.server.card, "all", "x", 61), "1 to 60 s")
            assert(not pcall(reskate.server.card, "everyone", "x"), "a player, a list of them or all")
            assert(not pcall(reskate.server.card, {}, "x"), "at least one player")
            assert(not pcall(reskate.server.poll, "all", "", {"a", "b"}), "a question")
            assert(not pcall(reskate.server.poll, "all", "q?", {"only one"}), "2 to 6 answers")
            assert(not pcall(reskate.server.poll, "all", "q?", {"1", "2", "3", "4", "5", "6", "7"}), "2 to 6 answers")
            assert(not pcall(reskate.server.poll, "all", "q?", {"a", string.rep("x", 49)}), "48 characters an answer at most")
            assert(not pcall(reskate.server.poll, "all", "q?", {"a", ""}), "an answer says something")
            assert(not pcall(reskate.server.poll, "all", "q?", {"a", "b"}, {seconds = 4}), "5 to 300 s")
            assert(not pcall(reskate.server.poll_close, "x"), "a poll's id")
            reskate.log("cards done")
        end)
    )";
    const auto cards = [&](const char* id, const char* permissions, const char* side) {
        return package(id, {{manifest_file, manifest(permissions, side)}, {"plugin/main.lua", main}});
    };
    Host server_host(server, Side::server), player_host(player, Side::client), blind_host(blind, Side::server);
    server_host.apply({cards("cards-s", R"("console", "server")", "server")});
    player_host.apply({cards("cards-p", R"("console", "server")", "client")});
    blind_host.apply({cards("cards-b", R"("console")", "server")});
    for (auto* host : {&server_host, &player_host, &blind_host}) host->run_console("cards");
    check(server.logged("[cards-s] cards done"), "A server copy could not show cards and polls\n" + server.all());
    for (const auto* call : {"card cards-s all Race in 30 s 0", "card cards-s 7,8 Ready? 5", "card cards-s 7 Go 0",
                             "poll cards-s all Next track? Docks|Hill 20", "poll cards-s 7 Again? Yes|No|Later 0", "poll close cards-s 41"})
        check(server.fake.called(call), std::string("The server was asked: ") + call + "\n" + server.all());
    check(!server.fake.called("card cards-s all  0") && !server.fake.called("poll cards-s all q? only one 0"), "A refused call reached the server");
    // Answers and closes, each to the plugin that asked.
    server.fake.poll_news = {{"cards-s", 41, 7, 2, "Hill", ""}, {"cards-s", 42, 7, 0, "", "timeout"}, {"someone", 50, 8, 1, "Docks", ""}};
    ticks(server_host, server, 1);
    check(server.logged("[cards-s] answer 41 7 2 Hill") && server.logged("[cards-s] closed 42 7 timeout"),
          "The plugin hears its polls answered and closed\n" + server.all());
    check(!server.logged("answer 50"), "and only its own");
    check(!player.logged("cards done") && player.all().find("server copy") != std::string::npos,
          "A player's copy showed cards\n" + player.all());
    check(!blind.logged("cards done") && blind.all().find("\"server\"") != std::string::npos && blind.logged("no poll events"),
          "A plugin without server showed cards or heard polls\n" + blind.all());
    running(server_host, "cards-s", server);
}

// Clips on the skater's body: from the package or recorded, played, replacing a trick.
void plugins_animate_the_skater() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    dingosdk::anim_studio::Clip clip;
    clip.joints = dingosdk::anim_studio::skeleton_joints;
    clip.times = {0, 0.5f};
    clip.frames.resize(clip.times.size() * clip.joints);
    clip.takeoff = 0.1f;
    clip.landing = 0.4f;
    const auto bytes = dingosdk::anim_studio::clip_bytes(clip);
    const std::string main = R"(
        reskate.console.command("go", "x", function()
            assert(reskate.animation.play("clips/spin.fas", {speed = 2, blend = 0.3, loop = true}))
            assert(not pcall(reskate.animation.play, "clips/missing.fas"), "a clip in the package")
            assert(not pcall(reskate.animation.play, "notes.txt"), "a clip file")
            assert(not pcall(reskate.animation.play, "../other/spin.fas"), "its own package only")
            assert(not pcall(reskate.animation.play, "clips/spin.fas", {speed = 99}), "a sane speed")
            assert(reskate.animation.replace("Kickflip", "clips/spin.fas", {pop = "high"}))
            assert(not pcall(reskate.animation.replace, "kick;flip", "clips/spin.fas"), "a trick's name")
            assert(not pcall(reskate.animation.replace, "ollie", "clips/spin.fas", {pop = "huge"}), "a pop")
            assert(reskate.animation.record(2))
            assert(not pcall(reskate.animation.record, 60), "at most 10 s")
            local rec = reskate.animation.recorded()
            assert(rec == "rec:1", tostring(rec))
            assert(reskate.animation.recorded() == nil, "one recording, once")
            for i = 1, 3 do reskate.animation.play(rec) end
            local fifth, why = reskate.animation.play(rec)
            assert(not fifth and why:find("4 times"), "4 a second")
            assert(reskate.animation.trick() == "kickflip")
            reskate.animation.forget(rec)
            assert(not pcall(reskate.animation.play, rec), "a forgotten recording is gone")
            reskate.animation.stop()
            reskate.log("danced")
        end)
    )";
    host.apply({package("dancer", {{manifest_file, manifest(R"("console", "skater.animation")")}, {"plugin/main.lua", main},
                                   {"clips/spin.fas", std::string(bytes.begin(), bytes.end())}, {"notes.txt", "x"}})});
    running(host, "dancer", environment);
    host.run_console("go");
    check(environment.logged("[dancer] danced"), "A plugin animates the skater\n" + environment.all());
    for (const auto* call : {"play dancer 2 frames 2.0 0.30 true", "replace dancer kickflip high clip", "record dancer 2.0", "play dancer 3 frames 1.0 0.15 false",
                             "stop dancer"})
        check(environment.fake.called(call), std::string("The game was asked: ") + call + "\n" + environment.all());
    running(host, "dancer", environment);
}

void plugins_call_and_hear_each_other() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("library", {{manifest_file, manifest()}, {"manifest.json", R"({"name": "Lib"})"}, {"plugin/main.lua", R"(
        reskate.expose({
            add = function(a, b) return a + b end,
            echo = function(t) return {got = t, n = #t.list} end,
            fail = function() error("library failure") end,
            back = function() return reskate.require_plugin("user").poke() end,
        })
        reskate.on_plugin("user", "hello", function(from, data) reskate.log("heard " .. data.word .. " from " .. from) end)
        reskate.on_plugin("*", "anyone", function(from, data) reskate.log("anyone from " .. from) end)
    )"}}), script("user", R"(
        reskate.expose({poke = function() return 1 end})
        reskate.console.command("use", "x", function()
            local lib = assert(reskate.require_plugin("lib"), "by its manifest name")
            assert(lib.add(2, 3) == 5)
            local echoed = lib.echo({list = {1, 2, 3}, word = "hi"})
            assert(echoed.n == 3 and echoed.got.word == "hi")
            local ok, err = pcall(lib.fail)
            assert(not ok and err:find("raised an error"), err)
            assert(not pcall(lib.add, print, 1), "a function does not cross")
            ok, err = pcall(lib.back)
            assert(not ok, "a call back into a plugin in a call is refused")
            local none, why = reskate.require_plugin("nobody")
            assert(none == nil and why:find("no running plugin"), why)
            assert(reskate.emit("hello", {word = "hey"}))
            assert(reskate.emit("anyone"))
            assert(not pcall(reskate.emit, "bad name!"))
            reskate.log("library fine")
        end)
    )", R"("console")")});
    running(host, "library", environment);
    host.run_console("use");
    check(environment.logged("[user] library fine"), "Libraries work\n" + environment.all());
    running(host, "library", environment);
    ticks(host, environment, 1);
    check(environment.logged("[library] heard hey from user") && environment.logged("[library] anyone from user"), "Events reach the next tick\n" + environment.all());
}

void web_requests_go_only_to_listed_domains() {
    TestEnvironment environment;
    check([] {
        try { parse_manifest(R"({"api": 1, "entry": "a.lua", "domains": ["api.example.com"]})"); } catch (const std::exception&) { return true; }
        return false;
    }(), "domains need net.http");
    check([] {
        try { parse_manifest(R"({"api": 1, "entry": "a.lua", "permissions": ["net.http"], "domains": ["*.example.com"]})"); } catch (const std::exception&) { return true; }
        return false;
    }(), "and are plain host names");
    Host host(environment, Side::client);
    host.apply({package("web", {{manifest_file, R"({"api": 1, "entry": "plugin/main.lua", "permissions": ["console", "net.http"], "domains": ["API.example.com"]})"},
        {"plugin/main.lua", R"(
        reskate.console.command("fetch", "x", function()
            assert(reskate.http.request({url = "https://api.example.com/v1/x?y=1"}, function(status, body, err)
                reskate.log("answer " .. status .. " " .. body .. " " .. tostring(err))
            end))
            assert(reskate.http.request({url = "https://api.example.com:443/post", method = "POST", body = "{}", content_type = "application/json"}, function() end))
            for _, bad in {"http://api.example.com/", "https://other.com/", "https://user@api.example.com/", "https://api.example.com:8080/",
                           "https://api.example.com/a b", "ftp://api.example.com/"} do
                assert(not pcall(reskate.http.request, {url = bad}, function() end), bad)
            end
            assert(not pcall(reskate.http.request, {url = "https://api.example.com/", method = "DELETE"}, function() end))
            reskate.log("web fine")
        end)
        reskate.console.command("many", "x", function()
            local ok, err = pcall(function() for i = 1, 20 do reskate.http.request({url = "https://api.example.com/"}, function() end) end end)
            reskate.log("many " .. tostring(err):match("more than %d+ web requests [%a ]+"))
        end)
    )"}})});
    host.run_console("fetch");
    check(environment.logged("[web] web fine") && environment.requests.size() == 2, "Requests go out\n" + environment.all());
    check(environment.requests[0].host == "api.example.com" && environment.requests[0].path == "/v1/x?y=1" && environment.requests[1].method == "POST",
          "with their host, path and method");
    environment.responses.push_back({environment.requests[0].id, "web", 200, "hello", ""});
    ticks(host, environment, 1);
    check(environment.logged("[web] answer 200 hello nil"), "and the answer comes back\n" + environment.all());
    host.run_console("many");
    check(environment.logged("many more than 4 web requests waiting"), "4 waiting at most\n" + environment.all());
}


void declared_board_colours_through_the_api() {
    TestEnvironment environment;
    environment.fake.declared_rules = true;
    environment.fake.declared_deck = true;
    Host host(environment, Side::client);
    host.apply({script("materialapi", R"(
        reskate.console.command("materialapi", "x", function(args)
            local deck = reskate.board.parameters("deck")
            assert(#deck == 7 + 9, "seven selectors and nine declared inputs, not " .. #deck)
            local inherited = 0
            for i, p in deck do
                if i <= 7 then
                    assert(not p.inherited and (p.type == "integer" or p.type == "switch"), "a live selector")
                else
                    assert(p.inherited == true, "a declared input is inherited")
                    if p.type == "colour" then
                        inherited += 1
                        assert(p.value.r == 0.5 and p.value.g == 0.5 and p.value.b == 0.5, "at its declared default")
                    end
                end
            end
            assert(inherited == 8, "eight declared colours")
            for _, key in {"5b2d035c7746f31a", "51745c0fd2d117d3", "5c1058b72fe158ed", "5a4e08ac201c369f",
                           "57fc15cf6583c0c7", "5a2f52ddbd12f283", "55fda1e1521b9097", "580bde15aa576f12"} do
                assert(reskate.board.set_parameter("deck", key, {r = 0.25, g = 0.75, b = 0.375}), key)
            end
            local ok, why = reskate.board.set_parameter("deck", "0000000000005001", 3)
            assert(not ok and why:find("only read"), "a selector stays read-only: " .. tostring(why))
            ok, why = reskate.board.set_parameter("deck", "5b2d035c7746f31a", 0.5)
            assert(not ok and why:find("colour"), "a declared colour is not a number: " .. tostring(why))
            ok, why = reskate.board.set_parameter("deck", "5b2d035c7746f31a", {r = 2, g = 0, b = 0})
            assert(not ok and why:find("0 to 1"), "its channels are 0 to 1")
            ok, why = reskate.board.set_parameter("deck", "7777777777777777", 0.5)
            assert(not ok and why:find("only a declared colour"), "a declared number with no live value is not added: " .. tostring(why))
            ok, why = reskate.board.set_parameter("deck", "1234567812345678", {r = 0, g = 0, b = 0})
            assert(not ok and why:find("no parameter"), "nor anything undeclared")
            reskate.log("materialapi fine")
        end)
        reskate.console.command("materialapi_one", "x", function() reskate.board.clear_parameter("deck", "5b2d035c7746f31a") end)
    )", R"("board", "console")"),
                script("thief", R"(
        reskate.console.command("thief", "x", function()
            local ok, why = reskate.board.set_parameter("deck", "5b2d035c7746f31a", {r = 1, g = 1, b = 1})
            assert(not ok and why:find("materialapi holds"), "another plugin's colour is not taken: " .. tostring(why))
            reskate.log("thief refused")
        end)
    )", R"("board", "console")"),
                script("nopermission", R"(
        local ok, err = pcall(reskate.board.parameters, "deck")
        assert(not ok and err:find("needs the \"board\" permission"), err)
        ok, err = pcall(reskate.board.set_parameter, "deck", "5b2d035c7746f31a", {r = 1, g = 1, b = 1})
        assert(not ok and err:find("needs the \"board\" permission"), err)
        ok, err = pcall(reskate.board.clear_parameter, "deck")
        assert(not ok and err:find("needs the \"board\" permission"), err)
        reskate.log("nopermission refused")
    )")});
    running(host, "materialapi", environment);
    running(host, "nopermission", environment);
    check(environment.logged("nopermission refused"), "A plugin without the board permission reaches no board parameter\n" + environment.all());
    check(environment.fake.declared_holds.empty(), "Nothing is held before a plugin asks");
    check(host.run_console("materialapi") && environment.logged("materialapi fine"), "Declared colours list and set\n" + environment.all());
    check(environment.fake.declared_held("materialapi") == 8, "The plugin holds the eight declared colours");
    check(host.run_console("thief") && environment.logged("thief refused"), "Another plugin cannot take them\n" + environment.all());
    check(environment.fake.declared_held("thief") == 0, "and holds none");
    check(host.run_console("materialapi_one") && environment.fake.declared_held("materialapi") == 7, "Clearing one key lets go of that one");
    host.apply({});
    check(environment.fake.declared_holds.empty(), "Unloading lets go of every one (the game puts them back to their defaults)");
}

void game_menu_distinguishes_unknown_from_closed() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    host.apply({script("menu-reader", R"(
        local function snapshot(known, open, skaters, count)
            local row = reskate.menu.game()
            local fields = 0
            for key in pairs(row) do
                assert(key == "known" or key == "open" or key == "skaters" or key == "buttons", key)
                fields += 1
            end
            assert(fields == 4 and type(row.known) == "boolean" and type(row.open) == "boolean"
                and type(row.skaters) == "boolean" and type(row.buttons) == "table")
            assert(row.known == known and row.open == open and row.skaters == skaters and #row.buttons == count)
            return row
        end
        reskate.console.command("menu_unknown", "x", function()
            snapshot(false, false, false, 0)
            reskate.log("unknown menu preserved")
        end)
        reskate.console.command("menu_closed", "x", function()
            snapshot(true, false, false, 0)
            reskate.log("known closed menu preserved")
        end)
        reskate.console.command("menu_open", "x", function()
            local row = snapshot(true, true, true, 2)
            assert(row.buttons[1] == "Skaters" and row.buttons[2] == "Board")
            reskate.log("known open menu preserved")
        end)
        reskate.console.command("menu_buttons", "x", function()
            local row = snapshot(true, true, false, 64)
            assert(row.buttons[1] == "1" and row.buttons[64] == "64")
            reskate.log("menu button bound preserved")
        end)
    )", R"("menu", "console")"), script("menu-denied", R"(
        local ok, why = pcall(reskate.menu.game)
        assert(not ok and why:find('needs the "menu" permission', 1, true), tostring(why))
        reskate.log("menu permission denied")
    )")});
    running(host, "menu-reader", environment);
    running(host, "menu-denied", environment);
    check(environment.logged("menu permission denied") && game.menu_reads == 0,
          "Without menu permission the backend is not entered\n" + environment.all());
    check(host.run_console("menu_unknown") && environment.logged("unknown menu preserved"),
          "An unknown menu retains every old field\n" + environment.all());
    game.menu_now = {false, true, {}, true};
    check(host.run_console("menu_closed") && environment.logged("known closed menu preserved"),
          "A known closed menu still suppresses Skaters\n" + environment.all());
    game.menu_now = {true, true, {"Skaters", "Board"}, true};
    check(host.run_console("menu_open") && environment.logged("known open menu preserved"),
          "A known open menu retains the page and button order\n" + environment.all());
    game.menu_now = {true, false, {}, true};
    for (unsigned i = 1; i <= 65; ++i) game.menu_now.buttons.push_back(std::to_string(i));
    check(host.run_console("menu_buttons") && environment.logged("menu button bound preserved") && game.menu_reads == 4,
          "The old button limit and call count remain unchanged\n" + environment.all());
}

void the_wider_set_reaches_the_game() {
    TestEnvironment environment;
    auto& game = environment.fake;
    environment.local_skater = SkaterState{{1, 0, 1}, 0.25f, 3, 0, false, 0};
    Host host(environment, Side::client);
    host.apply({script("wide", R"(
        reskate.on("skater_state", function(now, before) reskate.log("state " .. before .. " to " .. now) end)
        reskate.on("bail", function(e) reskate.log("bail " .. e.count .. " force " .. tostring(e.force) .. " cause " .. tostring(e.cause)) end)
        reskate.on("board_landed", function(e) reskate.log(string.format("landed %.1f onto %s", e.down_speed, e.onto)) end)
        reskate.on("body_hit", function(e) reskate.log(string.format("hit %s %.0f", e.bone, e.impact)) end)
        reskate.on("bail_end", function(e) reskate.log(string.format("fall %.1f s left %.0f thigh %.0f", e.seconds, e.left, e.bones["Left thigh"].impact)) end)
        reskate.console.command("outfit", "x", function()
            assert(reskate.outfit.find("roadrash_leg1") == "RoadRash_Leg1" and reskate.outfit.find("nothing") == nil)
            local slots = reskate.outfit.slots()
            assert(#slots == 2 and slots[1].slot == "tattoo_legl" and slots[1].parameters[1] == 0.5)
            assert(reskate.outfit.set("tattoo_legl", "RoadRash_Leg1", {placement = {0.1, 0.2, 0.3, 0.4, 0.5}, covers = true}))
            assert(not pcall(reskate.outfit.set, "tattoo_legl", "x", {placement = {1, 2, 3, 4, 5, 6, 7, 8, 9}}), "at most 8 numbers")
            reskate.outfit.clear("tattoo_legl")
            reskate.log("outfit fine")
        end)
        reskate.console.command("deck", "x", function()
            local bones = reskate.board.bones()
            assert(math.abs(bones[3].position.y - 0.1) < 1e-6 and bones[0] and bones[15] and #bones[3].rotation == 4, "the board's bones")
            assert(reskate.board.set(12, {position = vector.create(0, 2, 0), rotation = {0, 0, 0, 2}, space = "world"}))
            assert(not pcall(reskate.board.set, 1, {position = vector.create(0, 0, 0)}), "bone 1 places the board")
            assert(reskate.board.hide(3))
            reskate.board.park({12, 13, 14, 15})
            assert(reskate.board.toss({12, 4}, {velocity = vector.create(1, 3, 0), spin = vector.create(0, 5, 0), ground = -2}))
            local grip = reskate.board.parameters("grip")
            assert(#grip == 4 and grip[1].key == "873f48af36e50d59" and grip[1].name == "graphic" and grip[1].type == "colour", "the grip's parameters")
            assert(math.abs(grip[1].value.g - 0.3) < 1e-6 and grip[2].value == 1 and grip[2].name == nil, "a colour and a number")
            assert(grip[3].type == "integer" and grip[3].value == 13 and grip[4].type == "switch" and grip[4].value == true, "an integer and a switch")
            assert(#reskate.board.parameters("wheels") == 0)
            assert(reskate.board.set_parameter("grip", "graphic", {r = 1, g = 0, b = 0}))
            assert(reskate.board.set_parameter("deck", "841C7D74837F1D39", 2.5))
            assert(not pcall(reskate.board.parameters, "rail"), "a part is one of four")
            assert(not pcall(reskate.board.set_parameter, "grip", "123", 1), "a key is 16 hex digits")
            assert(not pcall(reskate.board.set_parameter, "grip", "graphic", {r = 1}), "a colour has three channels")
            assert(not pcall(reskate.board.set_parameter, "grip", "graphic", math.huge), "a value is finite")
            reskate.board.clear_parameter("grip", "base")
            reskate.board.clear_parameter()
            reskate.log("deck fine")
        end)
        reskate.console.command("physics", "x", function()
            assert(reskate.board.motion().velocity.y == -2)
            local m = reskate.board.motion()
            assert(m.spin.y == 4, "the board's spin")
            assert(m.place.position.y == 0 and m.place.rotation[4] == 1, "where the board is")
            assert(math.abs(m.deck.position.y - 0.1) < 1e-6, "and its deck, on the board's place")
            assert(reskate.skater.wipeout(2))
            local again, two = reskate.skater.wipeout(2)
            assert(not again and two:find("2 s"), "one wipeout every 2 s")
            assert(not pcall(reskate.skater.wipeout, 10), "a gentle force")
            reskate.log("physics fine")
        end)
        reskate.on("chat", function(line) reskate.log("chat " .. line.name .. ": " .. line.text) end)
        reskate.on("track_changed", function(t) reskate.log("track " .. t.title .. " by " .. t.artist) end)
        reskate.on("throwdown", function(e) reskate.log("throwdown " .. e.phase) end)
        reskate.on("action", function(name) reskate.log("action " .. name) end)
        reskate.on("screen_closed", function(title) reskate.log("closed " .. title) end)
        assert(reskate.input.bind("jump", "Ctrl+K"))
        assert(not pcall(reskate.input.bind, "bad", "Esc"), "Esc is not bindable")
        reskate.ui.screen("Big", function(ui) ui:heading("A screen") if ui:button("ok", "OK") then reskate.log("screen ok") end end)
        reskate.console.command("do", "x", function()
            assert(reskate.skater.state() == "riding")
            assert(reskate.skater.noclip(true) and reskate.skater.boost("up"))
            assert(not pcall(reskate.skater.boost, "sideways"))
            assert(reskate.trainer.set_point() and reskate.trainer.back())
            reskate.hud.hide(true)
            assert(#reskate.objects.catalog() == 1 and reskate.objects.list()[1].id == "42")
            assert(reskate.objects.place("bench_01", vector.create(5, 0, 5), 1.0))
            assert(reskate.objects.move("42", vector.create(6, 0, 6)))
            assert(reskate.objects.remove("42"))
            assert(not pcall(reskate.objects.remove, "not a number"))
            assert(reskate.world.set_time("night") and reskate.world.set_control("fog", 1) and reskate.world.set_park("historic", "skatepark_02"))
            local ok, why = reskate.world.set_time("never")
            assert(not ok and why == "refused")
            assert(#reskate.travel.locations() == 1 and #reskate.travel.levels() == 1)
            assert(reskate.travel.go("bam"))
            local again, wait = reskate.travel.load("Levels/Game/X/X")
            assert(not again and wait:find("5 s"), "one trip every 5 s")
            assert(reskate.ai.spawn(2) and reskate.ai.count() == 3 and reskate.ai.clear())
            assert(not pcall(reskate.ai.spawn, 20))
            local s = reskate.session.skaters()[1]
            assert(s.id == "7" and s.position.y == 2 and s.heading == 0.5)
            reskate.session.tag("7", "IT", 0xff0000ff)
            assert(reskate.voice.set_volume("7", 0))
            assert(reskate.chat.send("hello all"))
            local soon, three = reskate.chat.send("again")
            assert(not soon and three:find("3 s"))
            assert(not pcall(reskate.chat.send, "/kick someone"), "no commands")
            for i = 1, 5 do assert(reskate.chat.notice("note " .. i, 0x00ff00ff)) end
            local sixth, five = reskate.chat.notice("too many")
            assert(not sixth and five:find("5 lines"), "5 lines a second")
            assert(not pcall(reskate.chat.notice, "two\nlines"), "one line")
            assert(reskate.camera.look(vector.create(0, 5, 0), vector.create(0, 5, 10), 70))
            assert(not pcall(reskate.camera.look, vector.create(1, 1, 1), vector.create(1, 1, 1)), "a view needs a direction")
            assert(not pcall(reskate.camera.look, vector.create(0, 0, 0), vector.create(0, 0, 1), 400), "a sane field of view")
            assert(reskate.camera.get().fov == 60 and reskate.camera.get().position.y == 2)
            assert(reskate.camera.set(vector.create(0, 5, 0), vector.create(0, 0, -1), vector.create(1, 1, 0), 80), "a rolled view")
            assert(not pcall(reskate.camera.set, vector.create(0, 0, 0), vector.create(0, 1, 0), vector.create(0, 2, 0)), "up along forward")
            local f = reskate.input.flight()
            assert(f.forward == 0.5 and f.look_x == 3 and f.boost, "the flight keys and mouse")
            local pad = reskate.input.gamepad()
            assert(pad.buttons.a and not pad.buttons.b and pad.left_x == 0.25 and pad.right_trigger == 1, "the gamepad")
            local stick = reskate.input.joystick()
            assert(stick.axes[2] == -1 and stick.buttons[3] and not stick.buttons[1] and stick.name == "Radio", "the radio")
            assert(reskate.input.capture(true))
            reskate.camera.release()
            assert(reskate.skater.freeze(true))
            assert(reskate.throwdowns.state().active == false)
            assert(reskate.throwdowns.host("skate", {"7", {id = "8"}, "7"}, {max = 4}))
            local again, five = reskate.throwdowns.host("jam", {"7"})
            assert(not again and five:find("5 s"), "one drop every 5 s")
            assert(not pcall(reskate.throwdowns.host, "bowling", {"7"}), "a linked mode")
            assert(not pcall(reskate.throwdowns.host, "jam", {}), "someone to play")
            assert(reskate.throwdowns.hosting() == "open")
            assert(reskate.music.next())
            local p = reskate.progression.get()
            assert(p.districts[1].rank == 4 and p.challenges[1].completed_goals == 1 and p.score == 1500)
            assert(reskate.settings.game("Render.Fov") == "90" and reskate.settings.game("Nope") == nil and #reskate.settings.names() == 1)
            reskate.ui.open("Big")
            reskate.log("wide fine")
        end)
    )", R"("console", "events.skater", "skater.read", "skater.control", "trainer", "hud", "world.objects", "world.environment", "travel",
          "world.ai", "session.skaters", "session.nametags", "voice.control", "chat.read", "chat.send", "chat.local", "camera", "throwdowns", "music", "audio", "outfit", "board",
          "progression.read", "settings.read", "input", "ui.screen")")});
    running(host, "wide", environment);
    game.state = 100;
    game.lines = {{1, 5, "Old", "before", false, false}};
    ticks(host, environment, 1);
    check(environment.logged("[wide] state none to riding"), "The skater's state is heard\n" + environment.all());
    host.run_console("do");
    check(environment.logged("[wide] wide fine"), "Every wider-set call works\n" + environment.all());
    for (const auto* call : {"control noclip_on", "control boost_up", "hud wide on", "place 0 bench_01 5.0", "move 42  6.0", "delete 42",
                             "env tod night", "env control fog 1", "env park historic skatepark_02", "travel location bam", "ai spawn 2",
                             "ai clear", "tag wide 7 IT ff0000ff", "voice 7 0.0", "chat hello all", "notice wide note 5 ff00ff00", "camera wide 0.0 5.0 0.0 back 0.00 0.00 -1.00 fov 70",
                             "camera wide 0.0 5.0 0.0 back -0.00 -0.00 1.00 fov 80", "capture wide on",
                             "camera release wide", "freeze wide on", "host wide ThrowdownSkate 2 players max 4", "music next"})
        check(game.called(call), std::string("The game was asked: ") + call);
    check(environment.teleports.size() == 1, "The save point teleports back");
    check(game.binds["wide/jump"] == combo_of("Ctrl+K"), "Its bind is held by the game");
    game.state = 401;
    game.wipe = 1;
    game.lines.push_back({2, 6, "Ann", "hi there", false, false});
    game.now_playing = {true, true, "Spotify", "Song", "Band", "Album", 9};
    game.throwdown.active = true;
    game.presses = {{"wide", "jump"}, {"someone", "jump"}};
    environment.now += 1000; // the music is looked at once a second
    ticks(host, environment, 1);
    check(environment.logged("[wide] state riding to grinding") && environment.logged("[wide] chat Ann: hi there") && !environment.logged("before") &&
          environment.logged("[wide] track Song by Band") && environment.logged("[wide] throwdown started") && environment.logged("[wide] action jump"),
          "And its events, but not chat from before it listened\n" + environment.all());
    ticks(host, environment, 1);
    game.wipe = 2;
    game.news.landings.push_back({4.5f, 6, true});
    game.news.hits.push_back({"Head", 9, false, false});
    game.news.falls.push_back({1.5f, 12, 3, {{"Left thigh", 8, 0.5f}}});
    ticks(host, environment, 1);
    check(environment.logged("[wide] bail 2 force 7.5 cause 12"), "A wipeout is a bail, with the slam's force and cause\n" + environment.all());
    check(environment.logged("[wide] landed 4.5 onto rail") && environment.logged("[wide] hit Head 9") &&
              environment.logged("[wide] fall 1.5 s left 12 thigh 8"),
          "and the board's landings, the body's hits and the fall are heard\n" + environment.all());
    host.run_console("outfit");
    check(environment.logged("[wide] outfit fine") && game.called("outfit wide tattoo_legl RoadRash_Leg1 5 true") &&
              game.called("outfit clear wide tattoo_legl"),
          "A plugin wears items over the outfit\n" + environment.all());
    host.run_console("deck");
    check(environment.logged("[wide] deck fine") && game.called("board wide 12 2.0 world") && game.called("board hide wide 3") &&
              game.called("board park wide 4") && game.called("board toss wide 2 3 -2"),
          "A plugin changes what is drawn of the board\n" + environment.all());
    check(game.called("board parameter wide 1 873f48af36e50d59 colour 1.0") && game.called("board parameter wide 0 841c7d74837f1d39 number 2.5") &&
              game.called("board parameter clear wide 1 8c46cd354b18a9e2") && game.called("board parameter clear wide -1 all"),
          "and holds its shader parameters\n" + environment.all());
    host.run_console("physics");
    check(environment.logged("[wide] physics fine") && game.called("wipeout 2.0"), "The board's motion reads, and a wipeout is asked for\n" + environment.all());
    ticks(host, environment, 10);
    const auto screen = std::find_if(environment.panels.begin(), environment.panels.end(), [](const auto& p) { return p.screen; });
    check(screen != environment.panels.end() && screen->title == "Big" && screen->widgets.size() == 2, "Its open screen is built, without the menu");
    environment.actions = {plugin_ui::Action{"wide", "Big", "ok"}};
    ticks(host, environment, 10);
    check(environment.logged("[wide] screen ok"), "and answers its widgets");
    environment.actions = {plugin_ui::Action{"wide", "Big", plugin_ui::close_widget}};
    ticks(host, environment, 10);
    check(environment.logged("[wide] closed Big") && std::none_of(environment.panels.begin(), environment.panels.end(), [](const auto& p) { return p.screen; }),
          "Esc closes it, which it hears");
    host.apply({});
    check(std::find(game.released.begin(), game.released.end(), "wide") != game.released.end(), "Unloading gives back what it held of the game");
}

void key_names_become_binds() {
    check(combo_of("F7") == (0x80000000u | 0x76u), "F7");
    check(combo_of("k") == (0x80000000u | 'K'), "a letter, any case");
    check(combo_of("Ctrl+K") != 0 && (combo_of("Ctrl+K") & 0xc0000000u) == 0x40000000u, "a chord");
    check(combo_of("Ctrl+K") == combo_of("k+ctrl"), "in any order");
    check(combo_of("Pad.LB+Pad.RB") == 0x300u && combo_of("pad.a") == 0x1000u && combo_of("Pad.RT") == 0x20000u, "pad combos");
    for (const auto* bad : {"", "Esc", "F13", "Ctrl+", "Pad.Z", "Ctrl+Pad.A", "A+B+C+D+E+F", "Num1"})
        check(combo_of(bad) == 0, std::string("not a bind: ") + bad);
}

void level_events_reach_plugins() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("levels", R"(
        assert(reskate.level.current() == nil)
        reskate.on("level_loaded", function(name) reskate.log("loaded " .. name .. " / " .. reskate.level.current().name) end)
        reskate.on("level_unloading", function(name) reskate.log("leaving " .. name) end)
    )")});
    host.set_level("sanvan");
    host.set_level("park");
    host.set_level("");
    check(environment.logged("loaded sanvan / sanvan") && environment.logged("leaving sanvan") &&
          environment.logged("loaded park / park") && environment.logged("leaving park"), "Level events in order\n" + environment.all());
}

void timers_run_when_due() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({script("clock", R"(
        local count = 0
        reskate.time.after(100, function() reskate.log("once") end)
        local id = reskate.time.every(50, function() count += 1 end)
        reskate.time.after(260, function() reskate.time.cancel(id) reskate.log("every ran " .. count) end)
        local cancelled = reskate.time.after(10, function() reskate.log("never") end)
        reskate.time.cancel(cancelled)
    )")});
    ticks(host, environment, 30);
    check(environment.logged("[clock] once") && environment.logged("every ran 5") && !environment.logged("never"),
        "Timers run once, repeat, and stop when cancelled\n" + environment.all());
}

void a_package_with_a_program_or_on_the_wrong_side_is_not_loaded() {
    const auto clean = package("clean", {{manifest_file, manifest()}, {"plugin/main.lua", ""}, {"readme.txt", "A plain file"}});
    check(check_package_files(clean.directory).empty(), "A plain package passes");
    const auto named = package("named", {{manifest_file, manifest()}, {"plugin/main.lua", ""}, {"tools/helper.DLL", "x"}});
    check(check_package_files(named.directory).find("tools/helper.dll") != std::string::npos, "A DLL by its name is refused");
    const auto hidden = package("hidden", {{manifest_file, manifest()}, {"plugin/main.lua", ""}, {"data/picture.png", "MZ\x90\x00"}});
    check(!check_package_files(hidden.directory).empty(), "and a program by its first bytes, whatever its name");
    const auto script_file = package("batch", {{manifest_file, manifest()}, {"plugin/main.lua", ""}, {"run.bat", "echo"}});
    check(!check_package_files(script_file.directory).empty(), "and a script Windows runs");

    TestEnvironment environment;
    Host host(environment, Side::client);
    auto refused = hidden;
    refused.refusal = check_package_files(hidden.directory);
    host.apply({refused, package("server_only", {{manifest_file, manifest("", "server")}, {"plugin/main.lua", ""}}),
        package("broken", {{manifest_file, "{"}, {"plugin/main.lua", ""}}),
        package("syntax", {{manifest_file, manifest()}, {"plugin/main.lua", "local = 1"}})});
    stopped(host, "hidden", "a program");
    check(status_of(host, "server_only").state == "not loaded", "A server plugin waits for a server");
    stopped(host, "broken", "not valid JSON");
    stopped(host, "syntax", "plugin/main.lua");
}

void discovery_finds_the_plugins_among_the_mods_left_on() {
    const auto root = scratch / "game";
    const auto mods = root / "Mods";
    write(mods / "Alpha" / manifest_file, manifest());
    write(mods / "Alpha" / "plugin" / "main.lua", "");
    write(mods / "Beta" / manifest_file, manifest());
    write(mods / "Beta" / "plugin" / "main.lua", "");
    write(mods / "Beta" / "bin" / "tool.exe", "x");
    write(mods / "Gamma" / manifest_file, manifest());
    write(mods / "Gamma" / "plugin" / "main.lua", "");
    write(mods / "JustAMap" / "manifest.json", R"({"name": "Just a map"})");
    check(dingosdk::mods::set_mod_enabled(mods, "Gamma", false), "mods.json switches a mod off");
    FileChecks checks;
    auto found = discover(root, checks);
    std::sort(found.begin(), found.end(), [](const auto& a, const auto& b) { return a.id < b.id; });
    check(found.size() == 2 && found[0].id == "Alpha" && found[1].id == "Beta", "Only the plugins left on are found");
    check(found[0].refusal.empty() && found[1].refusal.find("bin/tool.exe") != std::string::npos, "with what their files say");
    const auto before = found[0].fingerprint;
    write(mods / "Alpha" / "plugin" / "main.lua", "-- changed");
    auto again = discover(root, checks);
    std::sort(again.begin(), again.end(), [](const auto& a, const auto& b) { return a.id < b.id; });
    check(again[0].fingerprint != before, "A changed file changes the fingerprint, which reloads it");
}

// contrib/plugins, kept on this machine and out of the repository: a test of one that is not here
// is skipped (main reports it), not failed.
struct Absent {
    std::string id;
};
std::filesystem::path contrib_plugin(const std::string& id) {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "plugins" / id;
    if (!std::filesystem::exists(directory / "reskate-plugin.json")) throw Absent{id};
    return directory;
}
Candidate contributed(const std::string& id) {
    const auto directory = contrib_plugin(id);
    return {id, directory, "1", check_package_files(directory)};
}
void the_tracked_body_reactivation_harness_stays_inert_until_visual_approval() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "body-reactivation-probe";
    for (const auto* file : {"reskate-plugin.json", "plugin/main.lua", "plugin/probe.lua"})
        check(std::filesystem::is_regular_file(directory / file), "tracked reactivation harness requires " + std::string(file));
    check(check_package_files(directory).empty(), "tracked reactivation harness is a sandbox source package");
    std::ifstream manifest_source(directory / manifest_file, std::ios::binary);
    check(manifest_source.good(), "tracked reactivation manifest is readable");
    const std::string declaration(std::istreambuf_iterator<char>(manifest_source), {});
    constexpr const char* id = "LuaBodyReactivation_20261027_q1";
    constexpr const char* title = "Body reactivation: one cycle";
    TestEnvironment environment;
    auto& game = environment.fake;
    const auto storage = environment.storage_root() / id / "storage.json";
    check(!std::filesystem::exists(storage), "tracked reactivation smoke starts with fresh storage");
    // Constructed availability must not hide accidental startup authority behind
    // an absent actor/focus/level. This test never supplies a native launch arm.
    environment.local_skater = SkaterState{};
    environment.local_skater->position = {0, 1, 0};
    game.telemetry = SkaterTelemetry{};
    game.telemetry->skater = true;
    game.telemetry->watch.valid = true;
    game.telemetry->watch.state = 504;
    game.focus_now = {true, true, true};
    game.menu_now.known = true;
    game.menu_now.open = false;
    Host host(environment, Side::client);
    host.set_level("constructed-reactivation-smoke");
    const auto no_actuation = [&] {
        check(!game.body_create_calls && !game.body_creates && !game.body_read_calls &&
            !game.body_submit_entries && !game.body_submissions && !game.body_release_calls && game.owned.empty() &&
            !game.follow_reserves && !game.follow_publishes && !game.follow_reads && !game.follow_stops && !game.follow_acks &&
            !game.follow_renewals && !game.follow_lease_reads && !game.batch_calls &&
            !game.input_pulse_requests && !game.input_pulse_reads && !game.input_pulse_cancels && !game.input_pulse_acks &&
            !game.input_trace_requests && !game.input_trace_reads && !game.input_trace_stops && !game.input_trace_acks &&
            !game.native_action_requests && !game.native_action_reads && !game.native_action_cancels && !game.native_action_acks &&
            !game.native_recovery_requests && !game.native_recovery_reads && !game.native_recovery_cancels && !game.native_recovery_acks &&
            game.binds.empty() && game.entities.empty() && game.kept_keys.empty() && !game.kept_buttons && environment.teleports.empty(),
            "actual reactivation main reached body, Follow, pose/entity or input authority without approval");
#ifdef DINGOSDK_BODY_REACTIVATION_QUALIFICATION
        check(!game.reactivation_admit && !game.reactivation_begins && !game.reactivation_polls &&
            !game.reactivation_provider_calls && !game.reactivation_access && !game.reactivation_cleanup_duty &&
            !game.reactivation_retirements && !game.reactivation_closes,
            "actual reactivation smoke must not arm, begin, poll or retain native diagnostic work");
#endif
    };
#ifdef DINGOSDK_BODY_REACTIVATION_QUALIFICATION
    check(parse_manifest(declaration).permissions == std::set<std::string, std::less<>>{
        "world.physics", "world.physics.qualify_body_reactivation", "world.raycast", "skater.read", "input", "menu", "storage"},
        "actual harness declares only its reviewed body diagnostic, read-only context, menu and storage permissions");
    game.body_prepare_error = "owned-body clock preparation pending";
    game.probe_reply = [](const Vec3& from, const Vec3& to) -> Game::WorldProbe {
        if (from[1] > to[1]) {
            const float fraction = from[1] / (from[1] - to[1]);
            return {true, true, {from[0] + (to[0] - from[0]) * fraction, 0,
                from[2] + (to[2] - from[2]) * fraction}, fraction};
        }
        return {true, false, {}, 0};
    };
    host.apply({{id, directory, "tracked-body-reactivation-main-v1", {}}});
    running(host, id, environment);
    environment.panels_open = true; environment.shown = id;
    const auto repaint = [&] {
        environment.now += 100; host.tick(100); running(host, id, environment); no_actuation();
        check(game.calls.empty(), "actual reactivation main must not drive ordinary game controls");
    };
    const auto panel_value = [&](std::string_view label) {
        for (const auto& panel : environment.panels) {
            if (panel.plugin != id || panel.title != title) continue;
            for (const auto& widget : panel.widgets)
                if (widget.kind == plugin_ui::Widget::Kind::info && widget.text == label) return widget.help;
        }
        throw std::runtime_error("Missing tracked reactivation status: " + std::string(label));
    };
    const auto has_button = [&](std::string_view button) {
        for (const auto& panel : environment.panels) {
            if (panel.plugin != id || panel.title != title) continue;
            for (const auto& widget : panel.widgets)
                if (widget.kind == plugin_ui::Widget::Kind::button && widget.id == button) return true;
        }
        return false;
    };
    const auto action = [&](const char* button) {
        environment.actions = {plugin_ui::Action{id, title, button, false}}; repaint();
    };
    ticks(host, environment, 60); running(host, id, environment); no_actuation();
    check(panel_value("Phase") == "idle" && has_button("brq_prepare") && !has_button("brq_approve") &&
        !game.body_prepares && !game.probes && !game.telemetry_reads && !game.focus_reads && game.calls.empty() &&
        !std::filesystem::exists(storage), "actual main remains inert through startup and sixty menu ticks");
    action("brq_survey"); action("brq_approve");
    check(panel_value("Phase") == "idle" && !game.body_prepares && !game.probes,
        "actions for absent Survey/Approve buttons cannot admit a cold harness");
    for (unsigned attempt = 1; attempt <= 2; ++attempt) {
        action("brq_prepare"); repaint();
        check(game.body_prepares == attempt - 1 && panel_value("Phase") == "prepare_requested",
            "Prepare menu intent must wait for the interface to close");
        environment.panels_open = false; game.focus_now.interface_open = false;
        ticks(host, environment, 1); running(host, id, environment); no_actuation();
        check(game.body_prepares == attempt, "one explicit Prepare action makes one bounded warm-up call");
        ticks(host, environment, 10);
        check(game.body_prepares == attempt && !game.probes, "pending Prepare never automatically retries or surveys");
        environment.panels_open = true; game.focus_now.interface_open = true; repaint();
        check(panel_value("Phase") == "prepare_pending" && has_button("brq_prepare") && !has_button("brq_approve"),
            "pending warm-up is visible and cannot expose approval");
    }
    game.body_prepare_error.clear();
    ticks(host, environment, 10); running(host, id, environment);
    check(game.body_prepares == 2 && !game.probes, "backend becoming ready cannot substitute for another explicit Prepare");
    action("brq_prepare");
    environment.panels_open = false; game.focus_now.interface_open = false;
    ticks(host, environment, 1); running(host, id, environment); no_actuation();
    environment.panels_open = true; game.focus_now.interface_open = true; repaint();
    check(game.body_prepares == 3 && panel_value("Phase") == "prepared" && has_button("brq_survey") && !has_button("brq_approve"),
        "ready warm-up exposes only the separate survey action");
    action("brq_survey");
    for (unsigned frame = 0; frame < 5; ++frame) {
        const auto probes_before = game.probes;
        ticks(host, environment, 1); running(host, id, environment); no_actuation();
        check(game.probes - probes_before <= 8, "actual survey respects eight ray samples per tick");
    }
    repaint();
    check(panel_value("Phase") == "await_visual_approval" && has_button("brq_approve") &&
        game.probes == 38 && game.native_casts == 38 && !environment.rays,
        "actual API adapters complete the constructed 38-ray survey without allocating a body");
    ticks(host, environment, 10); running(host, id, environment); no_actuation();
    check(game.probes == 38 && game.body_prepares == 3, "waiting for visual approval neither re-surveys nor prepares automatically");
    action("brq_stop"); ticks(host, environment, 1); repaint();
    check(panel_value("Phase") == "refused" && panel_value("Reason") == "operator_stop" &&
        !has_button("brq_approve"), "Stop ends admission before any body creation or native begin");
    host.apply({}); no_actuation();
    check(game.calls == std::vector<std::string>{std::string("entities clear ") + id} &&
        game.released == std::vector<std::string>{id}, "harness unload performs only normal empty-owner cleanup");
    std::ifstream stored(storage, std::ios::binary);
    check(stored.good(), "actual main storage adapter flushes its stopped preparation receipt");
    const auto document = dingosdk::Json::parse(std::istreambuf_iterator<char>(stored), std::istreambuf_iterator<char>());
    const auto& receipt = document.at("body_reactivation_q1");
    check(receipt.at("phase").string() == "refused" && receipt.at("reason").string() == "operator_stop" &&
        receipt.at("terminal").get<bool>() && receipt.at("cleanup").string() == "not_started" &&
        !receipt.at("operator_end_required").get<bool>() && !receipt.contains("approval") &&
        receipt.at("counts").at("prepare").get<unsigned>() == 3 && receipt.at("counts").at("rays").get<unsigned>() == 38 &&
        receipt.at("counts").at("create").get<unsigned>() == 0 && receipt.at("counts").at("begin").get<unsigned>() == 0 &&
        receipt.at("initial_survey").at("ray_count").get<unsigned>() == 38 &&
        receipt.at("candidate").at("position").is_array() &&
        !receipt.at("external_environment_and_process_pins_verified").get<bool>() &&
        !receipt.at("actor_generation_available").get<bool>(),
        "stored actual-main receipt preserves inert counts, array position and unknown external identity");
    std::cout << "tracked reactivation main: actual manifest/modules/UI/storage, explicit cold warm-up, 38 constructed rays, no approval/body/arm\n";
#else
    bool rejected{};
    try { (void)parse_manifest(declaration); }
    catch (const std::exception& error) { rejected = std::string(error.what()).find("unknown permission") != std::string::npos; }
    check(rejected, "default-OFF build must reject the actual harness diagnostic permission");
    host.apply({{id, directory, "tracked-body-reactivation-off-v1", {}}});
    stopped(host, id, "unknown permission");
    environment.panels_open = true; environment.shown = id;
    environment.actions = {plugin_ui::Action{id, title, "brq_prepare", false}};
    ticks(host, environment, 60); stopped(host, id, "unknown permission"); no_actuation();
    check(!game.body_prepares && !game.probes && !game.telemetry_reads && !game.focus_reads &&
        environment.panels.empty() && game.calls.empty() && !std::filesystem::exists(storage),
        "default-OFF manifest refusal happens before actual entry, menu or provider dispatch");
    host.apply({}); no_actuation();
    // Host::unload releases the candidate name even when manifest rejection
    // prevented a VM. FakeGame records that empty-owner cleanup, not dispatch.
    check(game.calls == std::vector<std::string>{std::string("entities clear ") + id} &&
        game.released == std::vector<std::string>{id} && !std::filesystem::exists(storage),
        "default-OFF removal performs only empty-owner bookkeeping and creates no unload ledger");
    std::cout << "tracked reactivation main: default-OFF permission refusal before entry/provider dispatch\n";
#endif
}
void the_tracked_input_pulse_fixture_loads_and_ticks_inert() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "input-pulse-trial";
    check(std::filesystem::is_regular_file(directory / manifest_file) &&
        std::filesystem::is_regular_file(directory / "plugin" / "main.lua"), "tracked input pulse fixture files are required");
    check(check_package_files(directory).empty(), "input pulse fixture is a source-only sandbox package");
    constexpr const char* id = "LuaInputPulse_20261023_v3";
    TestEnvironment environment;
    const auto storage = environment.storage_root() / id / "storage.json";
    check(!std::filesystem::exists(storage), "input pulse fixture starts with fresh test storage");
    // Give accidental automatic arming a usable baseline, rather than masking it
    // behind an unavailable skater or focus in the fake game.
    environment.local_skater = SkaterState{};
    environment.fake.focus_now = {true, false, true};
    environment.fake.telemetry = SkaterTelemetry{};
    environment.fake.telemetry->skater = true;
    environment.fake.telemetry->watch.valid = true;
    environment.fake.telemetry->watch.state = 100;
    environment.fake.telemetry->watch.ragdoll_known = true;
    Host host(environment, Side::client);
    host.apply({{id, directory, "tracked-input-pulse-inert-v3", {}}}); running(host, id, environment);
    environment.panels_open = true; environment.shown = id;
    ticks(host, environment, 60); running(host, id, environment);
    const auto page = std::find_if(environment.panels.begin(), environment.panels.end(), [&](const auto& panel) {
        return panel.plugin == id && panel.page && panel.title == "Lua Input Pulse";
    });
    check(page != environment.panels.end(), "actual tracked input pulse menu builds within Host text limits");
    for (unsigned slot = 0; slot < 4; ++slot) {
        check(std::any_of(page->widgets.begin(), page->widgets.end(), [&](const auto& widget) {
            return widget.kind == plugin_ui::Widget::Kind::button && widget.id == "arm" + std::to_string(slot);
        }), "actual fixture exposes each explicit slot Arm button");
    }
    check(std::any_of(page->widgets.begin(), page->widgets.end(), [](const auto& widget) {
        return widget.kind == plugin_ui::Widget::Kind::info && widget.text == "Phase" && widget.help == "idle";
    }), "actual fixture remains idle, rather than silently refusing its ID or arming");
    check(!environment.fake.input_pulse_requests && !environment.fake.input_pulse_reads &&
        !environment.fake.input_pulse_cancels && !environment.fake.input_pulse_acks &&
        !environment.fake.native_action_requests && !environment.fake.native_action_reads &&
        !environment.fake.native_action_cancels && !environment.fake.native_action_acks &&
        !environment.fake.native_recovery_requests && !environment.fake.native_recovery_reads &&
        !environment.fake.native_recovery_cancels && !environment.fake.native_recovery_acks,
        "loading and 60 ticks/menu builds must not reach pulse/action/recovery before Arm");
    check(!environment.fake.body_creates && !environment.fake.body_submissions && !environment.fake.batch_calls &&
        environment.fake.owned.empty() && environment.fake.calls.empty() && environment.teleports.empty() && !environment.rays,
        "unarmed actual fixture must not actuate bodies, other controls, or queries");
    check(!std::filesystem::exists(storage), "unarmed actual fixture must not write a trial ledger");
    std::cout << "tracked input pulse fixture inert-load: exact main/manifest, 60 ticks/menu, 0 native requests\n";
}
void the_tracked_input_pulse_fixture_bounds_and_separates_active_observations() {
    using dingosdk::Json;
    namespace p = game_input_pulse;
    constexpr const char* id = "LuaInputPulse_20261023_v3";
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "input-pulse-trial";
    const char* scenarios[] = {"late deadline", "terminal fall", "terminal readiness", "watching fall", "watching readiness", "clean revoked"};
    for (unsigned scenario = 0; scenario < std::size(scenarios); ++scenario) {
        const std::string why = std::string("tracked pulse ") + scenarios[scenario] + ": ";
        TestEnvironment environment;
        const auto storage_directory = environment.storage_root() / id;
        std::filesystem::remove_all(storage_directory);
        environment.local_skater = SkaterState{};
        auto& game = environment.fake;
        game.focus_now = {true, true, true};
        game.telemetry = SkaterTelemetry{};
        game.telemetry->skater = true;
        auto& watch = game.telemetry->watch;
        watch.valid = watch.ragdoll_known = true;
        watch.state = 504;
        Host host(environment, Side::client);
        host.apply({{id, directory, "tracked-input-pulse-active-v3", {}}}); running(host, id, environment);
        const auto step = [&](double at) {
            const auto elapsed = at - environment.now;
            check(elapsed >= 0, why + "test clock must be monotonic");
            environment.now = at; host.tick(elapsed); running(host, id, environment);
        };
        environment.panels_open = true; environment.shown = id;
        step(1000);
        environment.actions = {plugin_ui::Action{id, "Lua Input Pulse", "arm0", false}};
        step(1100);
        check(game.input_pulse_requests == 0, why + "explicit menu Arm cannot request while menu is open");
        environment.panels_open = false; game.focus_now.interface_open = false;
        for (unsigned at = 1200; at <= 1800; at += 100) step(at);
        check(game.input_pulse_requests == 1 && game.input_pulses.size() == 1, why + "actual fixture requests exactly once after its baseline");
        auto& receipt = game.input_pulses.begin()->second.receipt;
        receipt.status = p::Status::pressing; receipt.report_debt = true;
        receipt.press_candidates = receipt.press_publications = 7;
        if (scenario == 3) watch.ragdoll = true;
        if (scenario == 4) game.focus_now.focused = false;
        step(1900);
        watch.ragdoll = false; game.focus_now.focused = true;
        step(2000);
        receipt.status = p::Status::revoked; receipt.reason = p::Reason::unavailable;
        receipt.report_debt = receipt.quarantined = false; receipt.claim_released = true;
        receipt.neutral_publications = 1;
        receipt.first_rejection_mask = dingosdk::input_pulse::failure_bit(dingosdk::input_pulse::FailedCheck::actor) |
            dingosdk::input_pulse::failure_bit(dingosdk::input_pulse::FailedCheck::native_clock);
        receipt.first_rejection_stage = p::RejectionStage::core_plan;
        watch.state = scenario == 0 ? 504 : 100;
        if (scenario == 1) watch.ragdoll = true;
        if (scenario == 2) game.focus_now.focused = false;
        step(2100); // The real fixture saves this terminal frame before acknowledging.
        check(game.input_pulse_acks == 1 && game.input_pulses.empty(), why + "clean terminal receipt is acknowledged once");
        watch.ragdoll = false; game.focus_now.focused = true;
        for (unsigned at = 2200; at <= 8000; at += 100) step(at);
        if (scenario == 0) {
            const auto reads = game.telemetry_reads;
            step(8300); // 6200 ms after terminal, beyond the hard observation window.
            check(game.telemetry_reads == reads, why + "late observing tick must stop before another telemetry read");
        } else step(8100);
        check(game.input_pulse_requests == 1 && !game.native_action_requests && !game.native_recovery_requests &&
            !game.body_creates && !game.body_submissions && game.calls.empty() && environment.teleports.empty() && !environment.rays,
            why + "actual fixture must not retry or activate another actuator before unload");
        host.apply({}); // Flush the actual plugin storage after its bounded stop.
        // Host unload always calls Game::release; this fake records its entity
        // cleanup even when the plugin never owned an entity. Keep that single
        // bookkeeping call separate from the fixture's pre-unload actuator check.
        check(game.calls == std::vector<std::string>{std::string("entities clear ") + id} &&
            game.released == std::vector<std::string>{id}, why + "unload records exactly the expected generic cleanup");
        std::ifstream stored(storage_directory / "storage.json", std::ios::binary);
        check(stored.good(), why + "actual fixture must persist its ledger");
        const auto document = Json::parse(std::istreambuf_iterator<char>(stored), std::istreambuf_iterator<char>());
        const auto& ledger = document.at("game_input_pulse_v1");
        const auto& trial = ledger.at("trial");
        check(ledger.at("phase").string() == "stopped" && trial.at("calls").at("request").get<unsigned>() == 1 &&
            trial.at("calls").at("acknowledge").get<unsigned>() == 1 && trial.at("request").at("detail").string() == "accepted",
            why + "classification must not add requests or rewrite acceptance");
        check(trial.at("cleanup_qualified").get<bool>() && !trial.at("normal_report_completion").get<bool>() &&
            trial.at("terminal_receipt").at("status").string() == "revoked" &&
            trial.at("terminal_receipt").at("first_rejection_mask").get<unsigned>() == 1280,
            why + "clean report debt and original revoked receipt remain separate facts");
        if (scenario == 0) {
            check(!trial.at("qualified_sampled_transition").get<bool>() &&
                trial.at("post_observation_deadline_wall_ms").get<unsigned>() == 8100 &&
                trial.at("post_deadline_delivered_wall_ms").get<unsigned>() == 8300 &&
                trial.at("final_context").at("wall_ms").get<unsigned>() == 8000,
                why + "late stop must retain the last in-window gameplay context");
            for (const auto& row : ledger.at("samples"))
                check(row.at("wall_ms").get<unsigned>() <= 8100, why + "samples cannot extend the hard window");
        } else if (scenario < 5) {
            const auto* failure = scenario == 1 ? "post_fall_observed" : scenario == 2 ? "post_readiness_lost" :
                scenario == 3 ? "request_fall_observed" : "request_readiness_lost";
            check(!trial.at("qualified_sampled_transition").get<bool>() &&
                trial.at(failure).get<bool>() && trial.at("observed_suffix").at("seconds").get<double>() >= 2.5,
                why + "failure before the standing suffix must not be erased by later good frames");
        } else {
            check(trial.at("qualified_sampled_transition").get<bool>() &&
                trial.at("post_observed_ms").get<unsigned>() >= 2500 && trial.at("post_observed_ms").get<unsigned>() <= 6000 &&
                trial.at("observed_suffix").at("seconds").get<double>() >= 2.5 &&
                trial.at("observed_suffix").at("qualified_samples").get<unsigned>() >= 10,
                why + "revoked report can independently precede a qualified sampled transition");
        }
    }
    std::cout << "tracked input pulse active Host: six bounded classification cases, constructed receipts, native_actions=0\n";
}
void the_private_input_trace_fixture_loads_inert_when_present() {
    for (const auto* version : {"v1", "v2"}) {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "build" / "bmx" / (std::string("native-input-observer-trial-") + version) / "fixture";
    if (!std::filesystem::exists(directory / manifest_file)) continue;
    check(check_package_files(directory).empty(), "private input trace fixture is source only");
    TestEnvironment environment; Host host(environment, Side::client);
    const auto id = std::string("LuaNativeInputTrace_20261023_") + version;
    host.apply({{id, directory, "private-input-trace-inert-v1", {}}}); running(host, id, environment);
    environment.panels_open = true; environment.shown = id;
    ticks(host, environment, 10); running(host, id, environment);
    check(std::find(environment.pages.begin(), environment.pages.end(), plugin_ui::PageEntry{id, "Lua Input Trace"}) != environment.pages.end(),
        "actual input trace fixture page is registered");
    check(environment.fake.input_trace_requests == 0 && environment.fake.input_trace_reads == 0 &&
        environment.fake.input_trace_stops == 0 && environment.fake.input_trace_acks == 0 &&
        environment.fake.native_action_requests == 0 && environment.fake.native_recovery_requests == 0 &&
        environment.fake.body_creates == 0 && environment.fake.calls.empty() && environment.teleports.empty(),
        "input trace fixture is inert before explicit Arm");
    }
}
void the_private_native_recovery_fixture_loads_inert_when_present() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "build" / "bmx" / "lua-native-recovery-v1" / "fixture";
    if (!std::filesystem::exists(directory / manifest_file)) {
        std::cout << "skipped private recovery inert-load fixture: build/bmx/lua-native-recovery-v1/fixture\n";
        return;
    }
    check(std::filesystem::is_regular_file(directory / "plugin" / "main.lua"), "private recovery fixture entry is present");
    check(check_package_files(directory).empty(), "private recovery fixture must be a source-only sandbox package");
    TestEnvironment environment; Host host(environment, Side::client);
    constexpr const char* id = "LuaNativeRecovery_20261023_v1";
    host.apply({{id, directory, "private-recovery-inert-v1", {}}});
    running(host, id, environment);
    ticks(host, environment, 3);
    environment.panels_open = true; environment.shown = id;
    ticks(host, environment, 10); running(host, id, environment);
    check(std::find(environment.pages.begin(), environment.pages.end(), plugin_ui::PageEntry{id, "Lua Recovery V1"}) != environment.pages.end(),
        "actual private recovery page title must satisfy Host bounds");
    check(!environment.panels.empty() && environment.panels.front().page && environment.panels.front().title == "Lua Recovery V1",
        "actual private recovery page callback builds without Arm");
    check(environment.fake.native_action_requests == 0 && environment.fake.native_action_reads == 0 &&
        environment.fake.native_action_cancels == 0 && environment.fake.native_action_acks == 0 &&
        environment.fake.native_recovery_requests == 0 && environment.fake.native_recovery_reads == 0 &&
        environment.fake.native_recovery_cancels == 0 && environment.fake.native_recovery_acks == 0,
        "loading/opening/ticking private recovery fixture must not request or inspect an action before Arm");
    check(environment.fake.calls.empty() && environment.fake.body_creates == 0 && environment.fake.body_submissions == 0 &&
        environment.teleports.empty() && environment.rays == 0, "inert recovery fixture reached native body/control services");
    std::cout << "private recovery fixture inert-load passed: exact source/manifest and page, 0 action/recovery calls\n";
}
std::string printed_lines(const TestEnvironment& environment) {
    std::string text;
    for (const auto& line : environment.lines) text += line + "\n";
    return text;
}

// Use the Blood package's own manifest: model-only tests miss permission changes
// that remove the poses and contact normals before physics_step reaches it.
void blood_renders_an_impact_through_the_host() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    host.apply({contributed("blood")});
    running(host, "blood", environment);
    check(host.run_console("blood test") && environment.printed("tests passed"),
          "Blood's own checks pass:\n" + printed_lines(environment) + environment.all());
    check(host.run_console("blood on") && host.run_console("blood color 2"), "Blood is enabled with green effects");

    PhysicsStep step;
    step.at = environment.now; step.seconds = .05f; step.state = 100; step.ragdoll = false;
    const EffectMatrix pose{1,0,0,0,0,1,0,0,0,0,1,0,0,.15f,0,1};
    step.poses.emplace("Pelvis", PhysicsStep::Pose{pose, {5, -10, 0}});
    step.poses.emplace("Left forearm", PhysicsStep::Pose{pose, {5, -10, 0}});
    game.steps.push_back(step);
    ticks(host, environment, 1);
    check(game.effects.empty(), "A pose without an impact creates no blood");

    step.at = environment.now; step.state = 300; step.wipeout = true; step.ragdoll = true;
    step.bodies.push_back({"Left forearm", 12, 5, false, false, true, Vec3{0,0,0}, Vec3{0,1,0}});
    game.steps.push_back(step);
    ticks(host, environment, 1);
    running(host, "blood", environment);
    const auto particles = std::count_if(game.effects.begin(), game.effects.end(), [](const auto& effect) {
        return !effect.second.request.decal;
    });
    check(particles == 3 && game.effects.size() == 4,
          "A host-delivered impact creates three particle sources and a decal; check events.physics.geometry in Blood's manifest\n" + environment.all());
    for (const auto& [id, effect] : game.effects) {
        (void)id;
        check(effect.owner == "blood" && effect.request.asset.find("_green") != std::string::npos,
              "Blood uses its declared green assets");
        check(!effect.request.decal || effect.request.attach, "The impact stain attaches to the receiving surface");
    }
    check(host.run_console("blood") && environment.printed("1 impacts, 3 particle sources, 1 marks"),
          "Blood reports the impact delivered through its real permissions:\n" + printed_lines(environment));
    host.switch_off("blood");
    check(game.effects.empty(), "Disabling Blood releases the impact effects");
    std::cout << "Blood package: model checks and host-delivered impact passed\n";
}

void reskate_test_passes_its_own_checks() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "reskate-test");
    environment.mod_list = {{"reskate-test", "ReSkate_Test", true}};
    Host host(environment, Side::client);
    host.apply({contributed("reskate-test")});
    running(host, "reskate-test", environment);
    ticks(host, environment, 5);
    check(host.run_console("ptest all"), "ptest is its command");
    ticks(host, environment, 120); // its later checks run on timers
    const auto output = printed_lines(environment);
    check(output.find("ptest: 79 passed, 0 failed, 10 skipped") != std::string::npos &&
          output.find("FAIL") == std::string::npos, "Every reskate-test check passes:\n" + output + environment.all());
    check(host.run_console("ptest echo a b") && environment.printed("ptest echo: a b"), "and its echo command answers");
    // With a skater on the ground, its skater checks run too.
    environment.local_skater = SkaterState{{5, 0, 5}, 0.3f, 2, 0, false, 0};
    environment.lines.clear();
    check(host.run_console("ptest skater"), "ptest skater");
    check(environment.printed("ptest: 5 passed, 0 failed (skater 5/5)"), "The skater checks pass with a skater:\n" + printed_lines(environment));
    check(host.run_console("ptest tp") && environment.teleports.size() == 1, "and ptest tp teleports it");
    // ptest trick waits for a trick and says what its events held.
    check(host.run_console("ptest trick"), "ptest trick");
    host.trick({TrickNews::Kind::started, 0, 0, {1, 0, 1}});
    host.trick({TrickNews::Kind::landed, 250, 2, {1, 0, 1}, {4, 0, 5}, 900});
    check(environment.printed("ptest trick: started at (1.0, 0.0, 1.0)") &&
          environment.printed("ptest trick: landed 250 points at x2.0 in 900 ms, from (1.0, 0.0, 1.0) to (4.0, 0.0, 5.0)"),
          "ptest trick prints the trick");
    environment.lines.clear();
    check(host.run_console("ptest tricks") && environment.printed("ptest: 3 passed, 0 failed, 1 skipped"),
          "and the tricks checks pass once one landed");
    // Its panel on its page, and its test HUD.
    environment.panels_open = true;
    ticks(host, environment, 10);
    check(environment.panels.size() == 1 && environment.panels[0].title == "reskate-test" && environment.panels[0].widgets.size() == 8,
          "Its panel is built while the menu shows its page");
    environment.actions = {plugin_ui::Action{"reskate-test", "reskate-test", "press"}, plugin_ui::Action{"reskate-test", "reskate-test", "hud", true}};
    ticks(host, environment, 10);
    check(environment.panels[0].widgets[1].text.find("pressed 1 times") != std::string::npos && environment.sounds.size() >= 1,
          "and answers its button with a sound");
    check(!environment.layers.empty() && environment.layers[0].shapes.size() >= 6, "Its HUD toggle draws the test HUD");
    check(host.run_console("ptest hud") && environment.printed("ptest hud: off"), "and ptest hud switches it");
    running(host, "reskate-test", environment);
}

// Road Rash as a mod (contrib/plugins/road-rash): its own checks of its rules pass, falls on one
// side mark that side's leg first, and every mark goes on, at the 4 changes a second ReSkate takes.
void road_rash_marks_the_skater_as_it_bails() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "road-rash");
    auto& game = environment.fake;
    for (const auto* item : {"roadrash_leg_1", "roadrash_leg_2", "roadrash_leg_3_blood", "roadrash_leg_3_dry", "roadrash_arm_1", "roadrash_arm_2",
                             "roadrash_arm_3_blood", "roadrash_face_1", "roadrash_face_2_blood"})
        game.installed.insert(item);
    Host host(environment, Side::client);
    host.apply({contributed("road-rash")});
    running(host, "road-rash", environment);
    check(host.run_console("roadrash test"), "roadrash test");
    check(environment.printed("roadrash: 11 passed, 0 failed") && !environment.printed("FAIL"),
          "Road Rash's own checks pass:\n" + printed_lines(environment) + environment.all());
    // Ten falls on the left, and one that is the tenth entering the wipeout again.
    for (int i = 0; i < 10; ++i) {
        game.news.falls.push_back({1.0f, 12, 1, {}});
        environment.now += 2000;
        ticks(host, environment, 1);
    }
    game.news.falls.push_back({0.4f, 12, 1, {}});
    ticks(host, environment, 20);
    environment.lines.clear();
    check(host.run_console("roadrash"), "roadrash");
    check(environment.printed("roadrash: on, 10 bail(s) counted (left leg 1, left arm 0, right leg 0, right arm 0, face 0)") &&
              environment.printed("1 mark(s) worn"),
          "Ten falls on the left mark the left leg:\n" + printed_lines(environment));
    check(game.called("outfit road-rash tattoo_legl Pack/roadrash_leg_1 5 false") && !game.called("tattoo_arml"), "and it wears the first leg item");
    // Every part at its worst: five items, more than ReSkate takes in a second.
    game.calls.clear();
    check(host.run_console("roadrash bails 25"), "roadrash bails");
    ticks(host, environment, 120);
    for (const auto* call : {"outfit clear road-rash ", "outfit road-rash tattoo_legl Pack/roadrash_leg_3_blood 5 false",
                             "outfit road-rash tattoo_arml Pack/roadrash_arm_3_blood 5 false", "outfit road-rash tattoo_legr Pack/roadrash_leg_3_blood 5 false",
                             "outfit road-rash tattoo_armr Pack/roadrash_arm_3_blood 5 false", "outfit road-rash moles Pack/roadrash_face_2_blood 0 false"})
        check(game.called(call), std::string("Road Rash asked: ") + call + "\n" + environment.all());
    environment.lines.clear();
    check(host.run_console("roadrash"), "roadrash");
    check(environment.printed("5 mark(s) worn"), "All five are worn:\n" + printed_lines(environment));
    // Dry: the arm has no dry worst, so it wears the level below; the face too. Covering tattoos.
    game.calls.clear();
    check(host.run_console("roadrash blood 0") && host.run_console("roadrash tattoos 1"), "roadrash blood and tattoos");
    ticks(host, environment, 240); // 1.5 s off first, then five items over two seconds
    for (const auto* call : {"outfit road-rash tattoo_legl Pack/roadrash_leg_3_dry 5 true", "outfit road-rash tattoo_arml Pack/roadrash_arm_2 5 true",
                             "outfit road-rash moles Pack/roadrash_face_1 0 true"})
        check(game.called(call), std::string("Road Rash asked: ") + call + "\n" + environment.all());
    // Healed, nothing goes back on; switched off, no bail counts.
    game.calls.clear();
    check(host.run_console("roadrash heal") && environment.printed("roadrash: healed"), "roadrash heal");
    ticks(host, environment, 30);
    check(game.called("outfit clear road-rash ") && !game.called("outfit road-rash"), "Healing takes every mark off");
    check(host.run_console("roadrash 0"), "roadrash 0");
    for (int i = 0; i < 12; ++i) {
        game.news.falls.push_back({1.0f, 12, 1, {}});
        environment.now += 2000;
        ticks(host, environment, 1);
    }
    environment.lines.clear();
    check(host.run_console("roadrash"), "roadrash");
    check(environment.printed("roadrash: off, 0 bail(s) counted"), "Off, it counts nothing:\n" + printed_lines(environment));
    // The switches are kept.
    host.apply({});
    host.apply({contributed("road-rash")});
    running(host, "road-rash", environment);
    environment.lines.clear();
    check(host.run_console("roadrash"), "roadrash");
    check(environment.printed("roadrash: off, 0 bail(s) counted") && environment.printed("blood off, covers tattoos on"),
          "Its switches are kept:\n" + printed_lines(environment));
    // Its panel.
    environment.panels_open = true;
    ticks(host, environment, 10);
    check(environment.panels.size() == 1 && environment.panels[0].title == "Road Rash" && environment.panels[0].page &&
              environment.panels[0].widgets.size() == 9 && environment.panels[0].widgets[0].kind == plugin_ui::Widget::Kind::card,
          "Its page is built while the menu shows it");
    environment.actions = {plugin_ui::Action{"road-rash", "Road Rash", "on", true}};
    ticks(host, environment, 10);
    environment.lines.clear();
    check(host.run_console("roadrash"), "roadrash");
    check(environment.printed("roadrash: on"), "and its toggle switches it on:\n" + printed_lines(environment));
}

// Board Break as a mod (contrib/plugins/board-break), in a copy with one crack among its sounds as
// the deck pack brings them: its own checks pass, the stretches are kept off every board, a slam
// breaks the board (the real deck goes away, the crack sounds) and riding again makes it whole.
// Dual Stick as a mod (contrib/plugins/dual-stick): the companion's settings in its own data folder.
// Its own checks pass; without the companion's file it creates none; with it, a preset changes the
// preset's keys and keeps every other line.
void dual_stick_edits_the_companions_settings() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    host.apply({contributed("dual-stick")});
    running(host, "dual-stick", environment);
    check(host.run_console("dualstick test"), "dualstick test");
    check(environment.printed("dualstick: 12 passed, 0 failed") && !environment.printed("FAIL"),
          "Dual Stick's own checks pass:\n" + printed_lines(environment) + environment.all());
    environment.lines.clear();
    check(host.run_console("dualstick preset xl") && environment.printed("session_controls.ini is not in"),
          "Without the companion's file nothing is set:\n" + printed_lines(environment));
    check(game.files.empty(), "and no file is made");
    game.files["dual-stick/session_controls.ini"] = "; companion\r\n[SessionControls]\r\nControllerIndex = 2\r\nPopOnRelease=0\r\n\r\n[Menu]\r\nHotkey=End\r\n";
    environment.lines.clear();
    check(host.run_console("dualstick preset xl") && environment.printed("dualstick: saved."), "dualstick preset xl:\n" + printed_lines(environment));
    const auto& text = game.files["dual-stick/session_controls.ini"];
    check(text.starts_with("; companion\r\n[SessionControls]\r\nControllerIndex = 2\r\nPopOnRelease=1\r\n") &&
              text.find("StickSteering=2\r\n") != std::string::npos && text.ends_with("\r\n\r\n[Menu]\r\nHotkey=End\r\n"),
          "The XL preset's keys are written, every other line kept:\n" + text);
    environment.lines.clear();
    check(host.run_console("dualstick save 2") && host.run_console("dualstick status") && environment.printed("XL-style controls"),
          "Saved to a slot, and read back:\n" + printed_lines(environment));
    check(game.files["dual-stick/session_controls.ini"].find("[CustomPreset2]\r\n") != std::string::npos, "The slot is in the file");
    // Its page builds, and picking Goofy there writes the stance.
    environment.panels_open = true;
    environment.shown = "dual-stick";
    ticks(host, environment, 10);
    running(host, "dual-stick", environment);
    check(environment.panels.size() == 1 && environment.panels[0].page && environment.panels[0].title == "Dual Stick" &&
              environment.panels[0].widgets.size() > 30,
          "Dual Stick's page is built:\n" + environment.all());
    environment.actions = {plugin_ui::Action{"dual-stick", "Dual Stick", "stance", false, 0, 3}};
    ticks(host, environment, 10);
    const auto& after = game.files["dual-stick/session_controls.ini"];
    check(after.find("AutoStance=0\r\n") != std::string::npos && after.find("Stance=goofy\r\n") != std::string::npos,
          "Goofy picked on the page is written:\n" + after + environment.all());
}

// Animator Studio as a mod (contrib/plugins/animator-studio): it records a trick, opens on it, keys a
// joint, saves it to play in game, and puts it back in game when it starts again.
void animator_studio_records_and_saves() {
    TestEnvironment environment;
    auto& game = environment.fake;
    game.files.clear();
    Host host(environment, Side::client);
    host.apply({contributed("animator-studio")});
    running(host, "animator-studio", environment);
    check(host.run_console("studio status") && environment.printed("studio: closed; nothing recorded; 0 saved"),
          "It starts closed:\n" + printed_lines(environment) + environment.all());
    // Not in the middle of a bail: the game would take the studio's hold of the skater away.
    environment.local_skater = SkaterState{{1, 0, 2}, 0, 0, 0, false, 0};
    game.state = 301;
    environment.lines.clear();
    check(host.run_console("studio open") && host.run_console("studio status") && environment.printed("studio: closed") &&
              !game.called("room open animator-studio"),
          "It does not open during a bail:\n" + printed_lines(environment) + environment.all());
    game.state.reset();
    environment.local_skater = SkaterState{{1, 0, 2}, 0, 0, 0, false, 0};
    check(host.run_console("studio record") && game.called("record animator-studio 10.0"), "It records\n" + environment.all());
    ticks(host, environment, 3);
    environment.lines.clear();
    check(host.run_console("studio status") && environment.printed("studio: open; kickflip, 0.50 s; 0 saved"),
          "and opens on the trick:\n" + printed_lines(environment) + environment.all());
    check(game.called("velocity animator-studio 0.0 0.0 0.0") && !game.called("freeze animator-studio on"),
          "The skater's board is stopped, and he stays on it (no noclip)\n" + environment.all());
    ticks(host, environment, 2);
    check(game.called("play animator-studio 3 frames 1.0 0.00 true at 0.00 paused floor"), "held on the skater\n" + environment.all());
    // The game's own tricks, once its animations are read: one for each pop the game has a clip for.
    game.game_clips_ready = true;
    ticks(host, environment, 70);
    environment.lines.clear();
    check(host.run_console("studio status") && environment.printed("0 saved; 2 game tricks"), "The game's tricks are listed:\n" + printed_lines(environment));
    // Past its loading screen, the studio's screen is drawn every frame, within the plugin's time.
    ticks(host, environment, 300); // past the loading screen over the walk to the room
    std::size_t tiles = 0, texts = 0;
    for (const auto& layer : environment.layers)
        for (const auto& shape : layer.shapes) {
            tiles += shape.kind == plugin_ui::Shape::Kind::rough_rect;
            texts += shape.kind == plugin_ui::Shape::Kind::text;
        }
    check(tiles > 30 && texts > 60, std::format("The studio's screen is drawn: {} tiles, {} texts\n", tiles, texts) + environment.all());
    const auto studio_ms = status_of(host, "animator-studio").tick_ms;
    std::cout << std::format("animator-studio: {:.3f} ms a tick open (its budget is 2 ms)\n", studio_ms);
    check(studio_ms < 2, "It stays within its time");
    running(host, "animator-studio", environment);
    // The middle mouse button pans the camera: it moves sideways, looking the same way.
    const auto last_camera = [&] {
        std::string last;
        for (const auto& c : game.calls)
            if (c.starts_with("camera animator-studio")) last = c;
        return last;
    };
    const auto camera_before = last_camera();
    game.cursor_now = Game::Cursor{1300, 300, 0, false, false, true, false};
    ticks(host, environment, 2);
    game.cursor_now->x = 1500;
    ticks(host, environment, 2);
    game.cursor_now->middle = false;
    ticks(host, environment, 2);
    const auto camera_after = last_camera();
    check(!camera_before.empty() && camera_before != camera_after &&
              camera_before.substr(camera_before.find(" back")) == camera_after.substr(camera_after.find(" back")),
          "The middle button pans: " + camera_before + " -> " + camera_after);
    game.cursor_now.reset();
    // Its own checks: the editing, the key maths against the baked clip, and every screen drawn.
    environment.lines.clear();
    check(host.run_console("studio test"), "studio test runs\n" + environment.all());
    check(environment.printed(" failed") && !environment.printed("FAIL") && environment.printed(", 0 failed"),
          "The studio's own checks pass:\n" + printed_lines(environment) + environment.all() + "\nstate: " + status_of(host, "animator-studio").state +
              " " + status_of(host, "animator-studio").reason);
    ticks(host, environment, 20);
    check(environment.printed("studio test: every screen drawn"), "every screen is drawn:\n" + printed_lines(environment) + environment.all());
    running(host, "animator-studio", environment);
    ticks(host, environment, 70); // its file calls (64 a second) back
    // Saved to play in game: a clip file and its keys, and the trick replaced.
    environment.lines.clear();
    check(host.run_console("studio ingame on"), "studio ingame runs\n" + environment.all());
    check(host.run_console("studio save Kick One") && environment.printed("studio: Saved Kick One"),
          "It saves:\n" + printed_lines(environment) + environment.all() + "\nstate: " + status_of(host, "animator-studio").state + " " +
              status_of(host, "animator-studio").reason);
    check(game.files.contains("animator-studio/anims/Kick One.fas") && game.files.contains("animator-studio/anims/Kick One.json"),
          "a clip file and its keys in the data folder\n" + environment.all());
    check(game.called("replace animator-studio kickflip any clip"), "and plays in game\n" + environment.all());
    // It opened in the character room, and walks back from it as it closes.
    check(game.called("room open animator-studio"), "The studio opens in the character room\n" + environment.all());
    check(host.run_console("studio close") && game.called("room leave animator-studio"), "and leaves it as it closes\n" + environment.all());
    // Typed into its card (the trick's name here): what is typed goes into the field, Enter keeps it.
    check(host.run_console("studio open"), "studio open");
    ticks(host, environment, 260); // past the walk's loading screen
    running(host, "animator-studio", environment);
    // The room gone from under it (the game's menu closed): the studio closes with it.
    game.room_phase = "failed";
    ticks(host, environment, 2);
    environment.lines.clear();
    check(host.run_console("studio status") && environment.printed("studio: closed"), "The studio closes with the room:\n" + printed_lines(environment));
    // Started again, it puts it back in game.
    game.calls.clear();
    host.apply({});
    host.apply({contributed("animator-studio")});
    running(host, "animator-studio", environment);
    check(game.called("replace animator-studio kickflip any clip") && environment.logged("[animator-studio] 1 saved animation(s) play in game"),
          "Started again, the saved trick plays in game\n" + environment.all());
    environment.lines.clear();
    check(host.run_console("studio list") && environment.printed("studio: Kick One"), "and lists it:\n" + printed_lines(environment));
}

// Rock to Fakie as a mod (contrib/plugins/rock-to-fakie), on reskate.tricks.label and record_as: off
// until switched on; then a held stall shows the label, B pressed in it asks for fakie_rock, and
// leaving the stall gives the label back.
void rock_to_fakie_relabels_and_records_the_stall() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "rock-to-fakie");
    auto& game = environment.fake;
    game.telemetry = SkaterTelemetry{};
    game.telemetry->watch.valid = true;
    game.telemetry->watch.state = 400;
    game.pad_bits_now = 0u;
    Host host(environment, Side::client);
    host.apply({contributed("rock-to-fakie")});
    running(host, "rock-to-fakie", environment);
    ticks(host, environment, 5);
    check(!game.called("trick label"), "Off by default: nothing is asked\n" + environment.all());
    check(host.run_console("rocktofakie on") && environment.printed("rocktofakie: on."), "rocktofakie on");
    ticks(host, environment, 2);
    check(game.called("trick label rock-to-fakie Board Stall=Rock to Fakie") && game.called("trick label rock-to-fakie Lip Stall=Rock to Fakie"),
          "A held stall is labelled\n" + environment.all());
    game.pad_bits_now = 0x2000u;
    ticks(host, environment, 1);
    check(game.called("trick record rock-to-fakie 9,12->187 250"), "B in the stall asks for fakie_rock\n" + environment.all());
    game.calls.clear();
    ticks(host, environment, 3);
    check(!game.called("trick record"), "B held asks once\n" + environment.all());
    game.telemetry->watch.state = 604;
    game.pad_bits_now = 0u;
    ticks(host, environment, 1);
    check(game.called("trick label rock-to-fakie Board Stall=") && game.called("trick label rock-to-fakie Lip Stall="),
          "Leaving the stall gives the labels back\n" + environment.all());
    game.calls.clear();
    game.pad_bits_now = 0x2000u;
    ticks(host, environment, 1);
    check(!game.called("trick record"), "B outside a stall asks nothing\n" + environment.all());
}

// Shared content: a plugin names a folder in its manifest's "content" and reads it in every enabled
// mod; other folders, and the field without mods.read, are refused.
void a_plugin_reads_the_content_folder_it_names() {
    for (const auto* bad : {R"({"api": 1, "entry": "a.lua", "content": ["parks"]})",
                            R"({"api": 1, "entry": "a.lua", "permissions": ["mods.read"], "content": ["../up"]})",
                            R"({"api": 1, "entry": "a.lua", "permissions": ["mods.read"], "content": "parks"})"}) {
        bool refused = false;
        try { parse_manifest(bad); } catch (const std::exception&) { refused = true; }
        check(refused, std::string("A bad content field is refused: ") + bad);
    }
    check(parse_manifest(R"({"api": 1, "entry": "a.lua", "permissions": ["mods.read"], "content": ["Parks", "parks", "routes"]})").content ==
              std::vector<std::string>{"parks", "routes"},
          "Content names are lower-case, each once");
    TestEnvironment environment;
    auto& game = environment.fake;
    game.content_files = {{"Someone-Park_Pack", "Park Pack", "sanvan/bridge.json", 12}, {"Map_Mod", "Map Mod", "red.json", 7}};
    game.content_texts["Someone-Park_Pack/parks/sanvan/bridge.json"] = R"({"id":"bridge"})";
    Host host(environment, Side::client);
    host.apply({package("reader", {{manifest_file, R"({"api": 1, "entry": "plugin/main.lua", "permissions": ["console", "mods.read"], "content": ["parks"]})"},
                                   {"plugin/main.lua", R"(
        local files = assert(reskate.mods.content("Parks"))
        assert(#files == 2 and files[1].mod == "Someone-Park_Pack" and files[1].path == "sanvan/bridge.json" and files[1].size == 12
               and files[2].title == "Map Mod", "listed")
        assert(reskate.mods.read_content("Someone-Park_Pack", "parks", "sanvan/bridge.json") == '{"id":"bridge"}', "read")
        local text, why = reskate.mods.read_content("Map_Mod", "parks", "missing.json")
        assert(text == nil and why == "not found", "a missing file")
        local ok, err = pcall(reskate.mods.content, "routes")
        assert(not ok and err:find("in the manifest's \"content\""), err)
        ok, err = pcall(reskate.mods.read_content, "Map_Mod", "parks", "../../secret.txt")
        assert(not ok and err:find("a path inside"), err)
        reskate.console.print("content ok")
    )"}})});
    running(host, "reader", environment);
    check(environment.printed("content ok") && game.called("content list parks"), "The plugin reads its content folder\n" + environment.all());
}

// What the game and a dedicated server read for mods.content (plugin_content.h), from real folders:
// every mod folder in a Mods folder by name, each one's files under the folder asked for, and the
// limits a plugin cannot get past.
void content_is_read_from_the_mod_folders() {
    namespace content = dingosdk::plugins::content;
    const auto mods = scratch / "content mods";
    const auto write = [](const std::filesystem::path& file, const std::string& text) {
        std::filesystem::create_directories(file.parent_path());
        std::ofstream(file, std::ios::binary) << text;
    };
    write(mods / "b_track" / "parks" / "start.json", "{}");
    write(mods / "b_track" / "parks" / "deep" / "a" / "b" / "c" / "level4.json", "{}");
    write(mods / "b_track" / "parks" / "deep" / "a" / "b" / "c" / "d" / "level5.json", "{}");
    write(mods / "b_track" / "parks" / "half.tmp", "");
    write(mods / "b_track" / "parks" / "big.json", std::string((1u << 20) + 1, ' '));
    write(mods / "b_track" / "manifest.json", R"({"name": "B Track", "version_number": "1.0.0"})");
    write(mods / "A_Park" / "parks" / "z.json", "zz");
    write(mods / "A_Park" / "reskate-levels.json", "{}");
    write(mods / "no parks" / "manifest.json", "not JSON");
    write(mods / ".reskate_plugin_data" / "parks" / "secret.json", "{}");
    write(mods / "loose.json", "{}");

    const auto found = content::mod_folders(mods);
    check(found.size() == 3 && found[0].name == "A_Park" && found[1].name == "b_track" && found[2].name == "no parks",
          "Every mod folder, by name, none hidden");
    check(found[0].title == "A_Park" && found[1].title == "B Track" && found[2].title == "no parks", "titled as their manifest names them");
    check(content::mod_folders(scratch / "no such folder").empty(), "No Mods folder, no mods");

    std::vector<Game::ContentFile> files;
    content::list(found, "parks", files);
    std::string listed;
    for (const auto& file : files) listed += std::format("{}:{}:{} ", file.mod, file.path, file.size);
    check(listed == std::format("A_Park:z.json:2 b_track:big.json:{} b_track:deep/a/b/c/level4.json:2 b_track:start.json:2 ", (1u << 20) + 1),
          "Mod by mod, sorted, four folders deep at most, no .tmp: " + listed);

    std::string text;
    check(content::read(found, "B_TRACK", "parks", "start.json", text).empty() && text == "{}", "A file is read, the mod named in any case");
    check(content::read(found, "b_track", "parks", "missing.json", text) == "not found", "A missing file");
    check(content::read(found, "b_track", "parks", "big.json", text) == "the file is larger than 1 MB", "A file over 1 MB");
    check(content::read(found, "nobody", "parks", "start.json", text) == "no such mod is on", "A mod that is not there");
    check(content::read(found, ".reskate_plugin_data", "parks", "secret.json", text) == "no such mod is on", "A hidden folder is no mod");

    for (int i = 0; i < 1005; ++i) write(mods / "c_many" / "parks" / std::format("{:04}.json", i), "");
    files.clear();
    content::list(content::mod_folders(mods), "parks", files);
    check(files.size() == content::most_files, std::format("At most {} files, {} listed", content::most_files, files.size()));
}

void board_break_snaps_the_board_on_a_slam() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "board-break");
    auto& game = environment.fake;
    const auto directory = scratch / "mods" / "board-break";
    std::filesystem::remove_all(directory);
    std::filesystem::copy(contrib_plugin("board-break"), directory,
                          std::filesystem::copy_options::recursive);
    write(directory / "sounds" / "heavy" / "snap.wav", wave_file(8000, 4000));
    Host host(environment, Side::client);
    host.apply({{"board-break", directory, "1", check_package_files(directory)}});
    running(host, "board-break", environment);
    check(host.run_console("boardbreak test"), "boardbreak test");
    check(environment.printed("boardbreak: 31 passed, 0 failed") && !environment.printed("FAIL"),
          "Board Break's own checks pass:\n" + printed_lines(environment) + environment.all());
    check(game.called("board park board-break 4"), "The stretches are kept off every board\n" + environment.all());
    // Riding, then a slam; set to always break, it goes.
    check(host.run_console("boardbreak always 1") && environment.printed("boardbreak: always is 1"), "boardbreak always");
    game.state = 100;
    ticks(host, environment, 2);
    game.state = 300;
    game.wipe = 1;
    ticks(host, environment, 1);
    check(game.called("board board-break 3 -949.9 local"), "The real deck goes away\n" + environment.all());
    check(game.called("sound board-break 8000 1.00 1.00 false"), "and the crack sounds\n" + environment.all());
    environment.lines.clear();
    check(host.run_console("boardbreak status") && environment.printed(", broken;"), "It is broken:\n" + printed_lines(environment));
    // Riding again a moment later, it is a new board.
    game.state = 100;
    ticks(host, environment, 100);
    environment.lines.clear();
    check(host.run_console("boardbreak status") && environment.printed("the board is new (0% worn);"),
          "Riding again it is whole and new:\n" + printed_lines(environment) + environment.all());
    // Its panel, whose toggle switches it off; that is kept.
    environment.panels_open = true;
    ticks(host, environment, 10);
    check(environment.panels.size() == 1 && environment.panels[0].title == "Board Break", "Its panel is built while the menu shows its page");
    environment.actions = {plugin_ui::Action{"board-break", "Board Break", "on", false}};
    ticks(host, environment, 10);
    host.apply({});
    host.apply({{"board-break", directory, "1", check_package_files(directory)}});
    running(host, "board-break", environment);
    environment.lines.clear();
    check(host.run_console("boardbreak") && environment.printed("boardbreak: off;"), "Switched off, it stays off:\n" + printed_lines(environment));
}

// The FPV drone as a mod (contrib/plugins/fpv-drone): its own tests of the flight maths pass, and
// over the fake world (flat ground at y = 0) it flies the camera, keeps the game off the input,
// plays its motor, follows the skater and tells the session where it is, within its 2 ms a tick.
// Hall of Meat as a mod (contrib/plugins/hall-of-meat): its own checks pass, and a bail fed through
// physics_step shows the x-ray, hides the HUD corner, slows the game at a break and keeps the map's best.
void hall_of_meat_scores_a_bail() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "hall-of-meat");
    auto& game = environment.fake;
    Host host(environment, Side::client);
    host.apply({contributed("hall-of-meat")});
    running(host, "hall-of-meat", environment);
    check(host.run_console("hallofmeat test"), "hallofmeat test");
    check(environment.printed("hallofmeat: 19 passed, 0 failed") && !environment.printed("FAIL"),
          "Hall of Meat's own checks pass:\n" + printed_lines(environment) + environment.all());
    check(game.called("xray hall-of-meat on") && game.called("corner hall-of-meat off"), "It gets the x-ray and the HUD corner ready\n" + environment.all());
    host.set_level("sanvan");
    // A wipeout that breaks the head, then the body lying for two seconds.
    const auto step = [&](bool wipeout, std::optional<bool> ragdoll, std::vector<PhysicsStep::Body> bodies) {
        game.steps.push_back({environment.now, 1.0f / 60, wipeout, false, ragdoll, Vec3{0, 0, 0}, 0.0f, std::move(bodies)});
        ticks(host, environment, 1);
    };
    step(true, true, {{"Head", 20, 0, false, false, true}});
    for (int i = 0; i < 120; ++i) step(false, true, {});
    check(game.called("corner hall-of-meat on"), "The card takes the HUD corner\n" + environment.all());
    check(game.called("slow hall-of-meat 0.30"), "A break slows the game\n" + environment.all());
    const auto& shapes = environment.layers.empty() ? std::vector<plugin_ui::Shape>{} : environment.layers[0].shapes;
    check(std::any_of(shapes.begin(), shapes.end(), [](const auto& s) { return s.kind == plugin_ui::Shape::Kind::skeleton && s.colours[1] != 0; }) &&
              std::any_of(shapes.begin(), shapes.end(), [](const auto& s) { return s.kind == plugin_ui::Shape::Kind::game_image && s.text == "thrasher"; }),
          "The broken head shows on the x-ray, and the card with skate.'s wordmark");
    // Standing up ends it; it is the map's first, so its best.
    step(false, false, {});
    ticks(host, environment, 200);
    check(game.called("corner hall-of-meat off") && game.called("slow hall-of-meat 1.00"), "The corner and the speed are given back\n" + environment.all());
    environment.lines.clear();
    check(host.run_console("hallofmeat") && environment.printed("hallofmeat: on; this map's best ") && environment.printed("Meat (1 hits, 1 broken"),
          "It says the map's best and the last bail:\n" + printed_lines(environment));
}
// Grind exits as a mod (contrib/plugins/grind-exits): its own checks pass, and RT held in a grind asks
// for the heel side and keeps RT and the stick's lean from the game.
void plugins_add_throwdown_modes() {
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    host.apply({script("modes", R"(
        assert(reskate.throwdowns.mode{id = "duel", name = "Duel", description = "Beat the last total.", art = "Duel", flag = "duel", replaces = "skate",
            players = {min = 1, max = 6, default = 2}, cursor_height = 99999})
        assert(not pcall(reskate.throwdowns.mode, {id = "x", name = "X", flag = "two words"}), "a flag name")
        assert(not pcall(reskate.throwdowns.mode, {id = "x", name = "X", replaces = "bowling"}), "a stock throwdown")
        assert(not pcall(reskate.throwdowns.mode, {id = "x", name = "X", cursor_height = 200000}), "a cursor height")
        assert(reskate.throwdowns.release_flag == nil and reskate.throwdowns.view == nil and reskate.throwdowns.one_up_view == nil,
            "the old flag and view calls are gone")
        assert(not pcall(reskate.on, "throwdown_mode", function() end), "and the old news event")
        reskate.console.command("tdgone", "Removes the mode", function() reskate.throwdowns.remove_mode("duel") end)
    )", R"("throwdowns", "console")")});
    running(host, "modes", environment);
    check(game.called("mode modes duel Duel") && game.modes.size() == 1, "The mode reaches the game\n" + environment.all());
    const auto& mode = game.modes.front();
    check(mode.players == 2 && mode.min_players == 1 && mode.max_players == 6 && mode.flag == "duel" && mode.art == "Duel" && mode.replaces == "skate" &&
              mode.cursor_height == 99999,
          "with its players, flag, art and cursor height");
    check(host.run_console("tdgone") && game.called("remove mode modes duel"), "A mode can go");
    host.apply({contributed("throwdown-modes-test")});
    running(host, "throwdown-modes-test", environment);
    check(game.called("mode throwdown-modes-test duel Duel") && game.called("mode throwdown-modes-test gates Gates"),
          "The test plugin's two modes register\n" + environment.all());
    // Its card clicked: it publishes the setup page, then its waiting card once the flag is down.
    namespace kit = dingosdk::throwdowns::kit;
    kit::post("throwdown-modes-test/gates", "open", {"9"});
    ticks(host, environment, 1);
    const auto setup = kit::documents_for("throwdown-modes-test/gates");
    check(setup && setup->setup && setup->setup->rows.size() == 3 && setup->setup->timer.present, "Its setup page\n" + environment.all());
    kit::post("throwdown-modes-test/gates", "flag_placed", {"9", "1", "2", "3", "0"});
    ticks(host, environment, 1);
    const auto waiting = kit::documents_for("throwdown-modes-test/gates");
    check(waiting && !waiting->setup && waiting->waiting && waiting->waiting->can_start, "Its waiting card\n" + environment.all());
    kit::post("throwdown-modes-test/gates", "start", {"9"});
    ticks(host, environment, 1);
    check(game.called("flag leave throwdown-modes-test"), "Start lets the flag go");
}

// The throwdown kit: a plugin registers a mode, publishes its documents (parsed into the store the
// native UI reads), hears what the native UI posts, holds the native flag, keeps data files, opens a
// dialog; and everything goes when it stops.
// Fit Check as a mod (contrib/plugins/fit-check): its own checks pass, and V on the Board screen
// turns the board until it has come round, eases the stick off when it turns too fast for the frames
// wanted, and saves evenly spaced frames of one turn with the board's parts on its card, the
// browsed deck in place of the worn one; the game's bloom is off while it turns.
void fit_check_turns_the_board_and_saves_it() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "fit-check");
    auto& game = environment.fake;
    const auto directory = scratch / "mods" / "fit-check";
    std::filesystem::remove_all(directory);
    std::filesystem::copy(contrib_plugin("fit-check"), directory,
                          std::filesystem::copy_options::recursive);
    Host host(environment, Side::client);
    host.apply({{"fit-check", directory, "1", check_package_files(directory)}});
    running(host, "fit-check", environment);
    check(host.run_console("fitcheck test") && environment.printed("fitcheck: 10 passed, 0 failed") && !environment.printed("FAIL"),
          "Fit Check's own checks pass:\n" + printed_lines(environment) + environment.all());
    check(game.binds.contains("fit-check/fitcheck"), "V is bound");

    // V in the world does nothing; on the Board screen, with a deck browsed, it turns the board.
    game.presses = {{"fit-check", "fitcheck"}};
    ticks(host, environment, 1);
    check(game.capture_starts.empty(), "Not out of the menu");
    game.menu_now = {true, false, {}};
    game.grid_now = Game::MenuGrid{"deck_b", "Deck B", "Decks", {"deck_a", "deck_b"}, 2, 2};
    game.board_now = {{"Deck", "deck_a", "Deck A"}, {"Wheels", "wheels_a", "Wheels A"}};
    game.render_settings = {"PostProcess.BloomEnable", "Render.ShadowsEnable"};
    game.presses = {{"fit-check", "fitcheck"}};
    ticks(host, environment, 1);
    check(game.capture_starts.size() == 1 && game.capture_starts[0].menu && game.capture_starts[0].left == 0.655f &&
              game.capture_starts[0].skip == 45 && game.capture_starts[0].height == 640,
          "The board's area of the menu is captured\n" + environment.all());
    check(game.called("setting fit-check PostProcess.BloomEnable false") && !game.called("Render.ShadowsEnable"),
          "Bloom is off while it turns, the shadow maps left\n" + environment.all());
    ticks(host, environment, 1);
    check(game.called("turn 0.50 2"), "The right stick is held half over\n" + environment.all());
    // Its banner over the game, and its page saying what it is doing.
    environment.panels_open = true;
    ticks(host, environment, 10);
    const auto banner = std::any_of(environment.layers.begin(), environment.layers.end(), [](const plugin_ui::Layer& layer) {
        return std::any_of(layer.shapes.begin(), layer.shapes.end(), [](const auto& s) { return s.text.starts_with("RECORDING FIT CHECK"); });
    });
    check(banner, "The banner shows while it records\n" + environment.all());
    check(environment.panels.size() == 1 && environment.panels[0].title == "Fit Check" && environment.panels[0].widgets.size() > 8,
          std::format("Its page is built ({} panels, {} widgets)\n", environment.panels.size(),
                      environment.panels.empty() ? 0 : environment.panels[0].widgets.size()) + environment.all());
    environment.panels_open = false;

    // Round in 100 frames, too few for 120 (4 s at 30): slower, and again.
    game.capture_now.taken = 130;
    ticks(host, environment, 1);
    check(game.capture_starts.size() == 2 && game.capture_saves.empty(), "Too fast: started again\n" + environment.all());

    // Round in 130: its 120 evenly spaced frames saved, the card with the browsed deck.
    game.turning = 130;
    game.capture_now.taken = 150;
    ticks(host, environment, 1);
    check(game.called("turn 0.46 2"), "The stick eased off to 0.5 x 0.92\n" + environment.all());
    check(game.capture_saves.size() == 1, "Saved once it came round\n" + environment.all());
    const auto& saved = game.capture_saves[0];
    check(saved.frames.size() == 120 && saved.frames[0] == 0 && saved.frames[60] == 65 && saved.format == "gif" && saved.size == 512 &&
              !saved.background && saved.solid,
          "Evenly spaced frames of one turn, as a transparent GIF");
    check(saved.path.starts_with("fit-checks/Deck-B-") && saved.path.ends_with(".gif"), "named after the deck: " + saved.path);
    check(saved.card_title == "Board" && saved.card.size() == 2 && saved.card[0].second == "Deck B" && saved.card[1].second == "Wheels A",
          "The card has the browsed deck and the worn wheels");
    check(game.called("setting fit-check PostProcess.BloomEnable none") && game.turned == 0, "Bloom back and the stick let go\n" + environment.all());
    game.capture_now = {"saved", 150, 150, true, "cut out by depth", saved.path};
    ticks(host, environment, 1);
    check(environment.logged("[fit-check] Saved Deck-B-") && environment.logged(".gif in the Fit Checks folder (cut out by depth)."),
          "And it says where\n" + environment.all());

    check(game.called("capture discard fit-check"), "Its pictures are let go once saved");
    game.calls.clear();
    // V on the Skaters screen with no grid: the skater; V again stops it.
    game.grid_now.reset();
    game.menu_now = {true, true, {}};
    game.presses = {{"fit-check", "fitcheck"}};
    ticks(host, environment, 1);
    check(game.capture_starts.size() == 3 && game.capture_starts.back().left == 0.27f, "The skater's area\n" + environment.all());
    game.presses = {{"fit-check", "fitcheck"}};
    ticks(host, environment, 1);
    check(game.called("capture discard fit-check") && game.turned == 0, "V again stops it\n" + environment.all());
    check(host.run_console("fitcheck open") && game.called("reveal fit-check fit-checks"), "The folder is shown");
}

// Item Tabs as a mod (contrib/plugins/item-tabs): its own checks pass, and over an item grid the game
// is kept from Tab and its letters; V and Enter put the highlighted item into a tab; Tab shows the
// player's tabs in the grid (and keeps Q, E and Enter too); B wears the item on top, with its check;
// Delete takes everything off; and all is given back when the grid closes.
void item_tabs_keep_tabs_and_wear_on_top() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "item-tabs");
    auto& game = environment.fake;
    game.pad.reset();
    const auto directory = scratch / "mods" / "item-tabs";
    std::filesystem::remove_all(directory);
    std::filesystem::copy(contrib_plugin("item-tabs"), directory,
                          std::filesystem::copy_options::recursive);
    Host host(environment, Side::client);
    host.apply({{"item-tabs", directory, "1", check_package_files(directory)}});
    running(host, "item-tabs", environment);
    check(host.run_console("itemtabs test") && environment.printed("itemtabs: 10 passed, 0 failed") && !environment.printed("FAIL"),
          "Item Tabs' own checks pass:\n" + printed_lines(environment) + environment.all());
    check(game.called("on top item-tabs []"), "Nothing on top yet\n" + environment.all());
    const auto press = [&](int key) {
        game.keys_held = {key};
        ticks(host, environment, 1);
        game.keys_held.clear();
        ticks(host, environment, 1);
    };
    const auto kept = [&](std::initializer_list<int> keys) {
        std::set<int> wanted(keys), now(game.kept_keys.begin(), game.kept_keys.end());
        return wanted == now;
    };

    // Over a grid: Tab, V, R, B and Delete are kept from the game, and the stick clicks and View.
    game.menu_now = {true, false, {}};
    game.grid_now = Game::MenuGrid{"hat_a", "Hat A", "Headwear", {"hat_a", "hat_b"}, 2, 2};
    ticks(host, environment, 2);
    check(kept({9, 'V', 'R', 'B', 46}) && game.kept_buttons == 0xe0, "The grid's keys are kept from the game\n" + environment.all());

    // A tab made at the console; V and Enter put the highlighted hat in it.
    check(host.run_console("itemtabs make Hats") && environment.printed("itemtabs: tab Hats is number 1"), "A tab is made");
    press('V');
    press(13);
    environment.lines.clear();
    check(host.run_console("itemtabs") && environment.printed("1. Hats (folder): 1 item(s)"), "The hat is in it:\n" + printed_lines(environment));
    game.pad = PadInput{0, 0, 0, 0, 0, 0, 0x2000, false}; // B closes the panel
    ticks(host, environment, 1);
    game.pad.reset();
    ticks(host, environment, 1);

    // Tab: the player's tabs, the grid showing the open one's items; Q, E and Enter are kept too.
    press(9);
    check(game.grid_shown && *game.grid_shown == std::vector<std::string>{"hat_a"}, "The grid shows the tab\n" + environment.all());
    check(kept({9, 'V', 'R', 'B', 46, 'Q', 'E', 13}) && game.kept_buttons == 0x13e0, "and keeps Q, E, Enter, LB, RB and A\n" + environment.all());
    const auto drawn = [&](std::string_view part) {
        return std::any_of(environment.layers.begin(), environment.layers.end(), [&](const plugin_ui::Layer& layer) {
            return std::any_of(layer.shapes.begin(), layer.shapes.end(), [&](const auto& s) { return s.text.find(part) != std::string::npos; });
        });
    };
    check(drawn("Hats") && drawn("Game tabs"), "Its tab row is drawn\n" + environment.all());

    // B: the hat on top, with its check; Delete: everything off.
    press('B');
    check(game.on_top_now == std::vector<std::string>{"hat_a"} && game.grid_marked == std::vector<std::string>{"hat_a"},
          "B wears it on top, checked\n" + environment.all());
    press(46);
    check(game.on_top_now.empty() && game.grid_marked.empty(), "Delete takes it off\n" + environment.all());

    // Kept: loaded again, the tab and its hat are still there.
    host.apply({});
    host.apply({{"item-tabs", directory, "1", check_package_files(directory)}});
    running(host, "item-tabs", environment);
    environment.lines.clear();
    check(host.run_console("itemtabs") && environment.printed("1. Hats (folder): 1 item(s)"), "Kept:\n" + printed_lines(environment));

    // The grid closes: everything given back.
    press(9);
    game.grid_now.reset();
    ticks(host, environment, 2);
    check(game.kept_keys.empty() && game.kept_buttons == 0 && !game.grid_shown, "Given back when the grid closes\n" + environment.all());
}

void plugins_drive_the_throwdown_kit() {
    namespace kit = dingosdk::throwdowns::kit;
    TestEnvironment environment;
    auto& game = environment.fake;
    Host host(environment, Side::client);
    host.apply({script("kit", R"(
        assert(reskate.throwdowns.mode{id = "lap", name = "Lap", description = "Through the gates.", card = "spot", order = 2,
            flag = "World/ReSkate/Throwdowns/Flags/lap_Placement", color = 0xff3434ff, players = {min = 1, max = 6, default = 4}})
        assert(not pcall(reskate.throwdowns.mode, {id = "x", name = "X", card = "bowling"}), "a stock card")
        assert(reskate.throwdowns.ui{
            setup = {mode = "lap", title = "LAP", players = {caption = "Players", min = 1, max = 6, step = 1, value = 4},
                     timer = {caption = "Finish deadline", min = 30, max = 600, step = 30, value = 180},
                     rows = {{id = "laps", kind = "choice", caption = "Laps", options = {"1", "2", "3"}, value = 2},
                             {id = "area", kind = "button", caption = "Area", label = "Set optional area"}}},
            waiting = {mode = "lap", title = "LAP", status = "Waiting for host", enrolled = 1, capacity = 6, can_start = true},
            hud = {theme = "lap", layout = "side", counters = {{text = "LEADER 1,200"}},
                   clock = {remaining_ms = 60000, total_ms = 90000, sampled_ms = 5, ticking = true},
                   board = {title = "LEADERBOARD", columns = {"POS", "NAME", "SCORE"},
                            rows = {{rank = 1, name = "Me", value = 1200, self = true, marks = {{text = "S", on = true}}}}},
                   timers = {{caption = "LAP", text = {base_ms = 1500, sampled_ms = 5, running = true, cap_ms = 600000}}},
                   markers = {{at = vector.create(1, 2, 3), text = "1", distance = true}}},
            panel = {title = "LAP", settings = {{icon = "players", caption = "Players", value = "4"}},
                     prompts = {{input = "UI_ShoulderL", caption = "Area", command = "area"}}, players = {{id = "76561198000000001", name = "Me", self = true}}},
            flags = {{id = "f1", mode = "lap", leader = "76561198000000001", game = 7, at = vector.create(1, 2, 3), yaw = 90,
                      stats = {{title = "LAPS", value = "2"}}}},
            match = {teleports = true, hidden = {"76561198000000002"}},
        })
        assert(not pcall(reskate.throwdowns.ui, "text"), "a document is a table")
        reskate.on("throwdown_ui", function(e)
            reskate.log("ui " .. e.action .. " " .. e.mode .. " " .. table.concat(e.args, ","))
            if e.action == "open" then
                assert(reskate.throwdowns.flag.begin("lap", tonumber(e.args[1]), {players = 4, seconds = 90}))
                local state = reskate.throwdowns.flag.state()
                assert(state.mine and state.mode == "lap" and state.game == tonumber(e.args[1]) and state.placing, "the flag is the plugin's")
            elseif e.action == "leave" then
                reskate.throwdowns.flag.leave()
            end
        end)
        assert(reskate.files.write("routes/a.json", "{\"gates\": 3}"))
        assert(reskate.files.read("routes/a.json") == "{\"gates\": 3}")
        local names = reskate.files.list("routes")
        assert(#names == 1 and names[1] == "a.json", "the folder lists its file")
        assert(reskate.files.list()[1] == "routes/", "and the top its folder")
        assert(not pcall(reskate.files.read, "../escape.json"), "no way out")
        assert(not pcall(reskate.files.write, "C:/escape.json", ""), "no drive")
        assert(not pcall(reskate.files.write, "routes/con.json", ""), "no device")
        assert(reskate.files.write("old.json", "x") and reskate.files.remove("old.json"))
        local missing, why = reskate.files.read("old.json")
        assert(missing == nil and why == "not found", "a removed file is gone")
        assert(reskate.ui.dialog("save", {title = "SAVE ROUTE", field = {text = "My route", max = 32},
            list = {rows = {{text = "Route A", sub = "3 gates", buttons = {"rename"}}}, empty = "No routes"},
            buttons = {"Save", {id = "cancel", label = "Cancel"}}, file = {label = "Load .json", filter = "*.json"}}))
        assert(not pcall(reskate.ui.dialog, "x", {buttons = {"1", "2", "3", "4", "5"}}), "at most 4 buttons")
        assert(reskate.skater.push(vector.create(1, 0, 2)))
        assert(reskate.skater.push_wait() and reskate.skater.push_reset())
        reskate.skater.hold(true)
        assert(reskate.modes == nil, "reskate.modes is gone")
        -- The general services: physics, the session's world, the trick feed and flick diagrams,
        -- the pad flight and the Bone Cam.
        reskate.physics.competition(true)
        assert(reskate.physics.stock_ready())
        reskate.physics.prepare()
        local world = reskate.session.world()
        assert(world.world == "77" and world.map == "test_map" and world.barred == false, "the session's world")
        reskate.tricks.feed(true)
        assert(#reskate.tricks.gesture("Kickflip") == 2 and #reskate.tricks.gesture("Boardslide") == 0, "flick diagrams")
        assert(reskate.camera.pad_flight(true))
        assert(reskate.skater.bone_cam() == "game" and reskate.skater.bone_cam("ringing") == "1")
        reskate.skater.bone_cam("game", "on")
    )", R"("throwdowns", "files", "ui.screen", "skater.control", "session.read", "events.tricks", "camera")")});
    running(host, "kit", environment);
    check(game.called("mode kit lap Lap") && game.modes.size() == 1, "The mode reaches the game\n" + environment.all());
    const auto& mode = game.modes.front();
    check(mode.card == "spot" && mode.order == 2 && mode.flag == "World/ReSkate/Throwdowns/Flags/lap_Placement" && mode.color == 0xff3434ffU,
          "with its card, order, flag prefab and colour");
    const auto documents = kit::documents_for("kit/lap");
    check(documents && documents->plugin == "kit" && game.kit_documents == 1, "Its documents are in the kit's store");
    const auto& setup = *documents->setup;
    check(setup.mode == "kit/lap" && setup.title == "LAP" && setup.players.present && setup.players.value == 4 && setup.timer.present &&
              setup.timer.value == 180 && setup.hide_native == std::vector<std::string>{"rounds"},
          "Its setup page, its mode the SDK's id");
    check(setup.rows.size() == 2 && setup.rows[0].kind == "choice" && setup.rows[0].selected == 1 && setup.rows[1].kind == "button" &&
              setup.rows[1].label == "Set optional area",
          "Its setup rows, a choice counted from 0");
    check(documents->waiting && documents->waiting->mode == "kit/lap" && documents->waiting->can_start && documents->waiting->capacity == 6, "Its waiting card");
    const auto& hud = documents->hud;
    check(hud.active && hud.theme == "lap" && hud.counters == std::vector<std::string>{"LEADER 1,200"} && hud.clock.present && hud.clock.remaining_ms == 60000,
          "Its HUD");
    check(hud.board.present && hud.board.rows.size() == 1 && hud.board.rows[0].rank == "1" && hud.board.rows[0].value == "1200" && hud.board.rows[0].self &&
              hud.board.rows[0].marks.size() == 1 && hud.board.rows[0].marks[0].on && hud.board.columns.size() == 3,
          "Its board, numbers as labels");
    check(hud.timers.size() == 1 && hud.timers[0].clock.present && hud.timers[0].clock.up && hud.timers[0].clock.remaining_ms == 1500 &&
              hud.timers[0].clock.total_ms == 600000 && hud.markers.size() == 1 && hud.markers[0].at[2] == 3,
          "A stopwatch timer and a marker");
    check(documents->panel.present && documents->panel.prompts.size() == 1 && documents->panel.prompts[0].glyph == "area" &&
              documents->panel.players.size() == 1 && documents->panel.players[0].id == 76561198000000001ULL,
          "Its match panel");
    check(documents->flags.size() == 1 && documents->flags[0].mode == "kit/lap" && documents->flags[0].leader == 76561198000000001ULL &&
              documents->flags[0].game == 7 && documents->flags[0].at[0] == 1 && documents->flags[0].stats.size() == 1,
          "Its flags");
    check(kit::match().teleports && kit::hidden(76561198000000002ULL) && !kit::hidden(76561198000000001ULL) && kit::active() && kit::active()->plugin == "kit",
          "What its match asks of the game");
    check(game.files.contains("kit/routes/a.json") && !game.files.contains("kit/old.json"), "Its files are in its own folder");
    check(game.called("dialog kit save rows 1 buttons 2") && game.dialog && game.dialog->field.text == "My route" && game.dialog->file.filter == "*.json" &&
              game.dialog->buttons[1].id == "cancel" && game.dialog->rows[0].buttons[0] == "rename",
          "Its dialog");
    check(game.called("push kit 1 0 2") && game.called("push wait kit") && game.called("push reset kit") && game.called("hold kit true"),
          "Push, its wait and reset, and hold reach the game");
    check(game.called("competition kit true") && game.called("prepare physics") && game.called("trick feed kit true") &&
              game.called("pad flight kit true") && game.called("bone cam kit game on"),
          "The general services reach the game\n" + environment.all());
    // The native UI: a card clicked, a dialog answered.
    kit::post("kit/lap", "open", {"7"});
    kit::post_to("kit", "dialog", "", {"save", "Save", "My route", "0", ""});
    kit::post("other/lap", "open", {"8"});
    ticks(host, environment, 1);
    check(environment.logged("[kit] ui open lap 7") && game.called("flag begin kit/lap 7 4 90 true 0.0"),
          "A card clicked reaches the plugin by its own id, which takes the flag\n" + environment.all());
    check(environment.logged("[kit] ui dialog  save,Save,My route,0,"), "A dialog's answer reaches it\n" + environment.all());
    check(!environment.logged("ui open lap 8") && kit::take("other").size() == 1, "Another plugin's events stay its own");
    kit::post("kit/lap", "leave");
    ticks(host, environment, 1);
    check(game.called("flag leave kit") && !game.flag.busy, "Leave lets the flag go");
    host.switch_off("kit");
    check(!kit::documents_for("kit/lap") && !kit::match().teleports && !kit::hidden(76561198000000002ULL), "Its documents go when it stops");
}

// The Throwdowns page's cards: the stock three (one replaced) and the plugin modes by order.
void the_throwdowns_page_lists_the_stock_cards_and_plugin_modes() {
    namespace custom = dingosdk::multiplayer::custom_throwdowns;
    using dingosdk::throwdowns::Adapter;
    custom::Mode skate;
    skate.plugin = "p";
    skate.id = "skate";
    skate.name = "Letters";
    skate.card = "skate";
    skate.replaces = "skate";
    custom::Mode late = skate;
    late.id = "late";
    late.name = "Late";
    late.card = "jam";
    late.replaces.clear();
    late.order = 20;
    late.color = 0xff00ff00U;
    custom::Mode early = late;
    early.id = "early";
    early.name = "Early";
    early.card = "spot";
    early.order = 10;
    early.color = 0;
    check(custom::set_mode(skate).empty() && custom::set_mode(late).empty() && custom::set_mode(early).empty(), "The modes register");
    check(!custom::set_mode([&] { auto bad = early; bad.card = "bowling"; return bad; }()).empty(), "A card is a stock one");
    const auto& registry = dingosdk::throwdowns::registry();
    std::vector<std::string> ids;
    for (const auto& d : registry.definitions()) ids.push_back(d.id);
    check(ids == std::vector<std::string>{"p/skate", "native.spot", "native.jam", "p/early", "p/late"}, "In the grid's order: " + [&] {
        std::string all;
        for (const auto& id : ids) all += id + " ";
        return all;
    }());
    const auto* late_card = registry.find("p/late");
    check(late_card && late_card->adapter == Adapter::plugin && late_card->donor == 2 && late_card->palette.primary == 0xff00ff00U && late_card->plugin == "p",
          "A plugin card: its donor and colour");
    check(registry.find("p/early")->palette.primary == dingosdk::throwdowns::palette_for("p/early").primary, "a colour picked from its id");
    check(registry.find("native.spot")->donor == 1 && registry.find("native.jam")->adapter == Adapter::native_jam, "The stock cards");
    const auto before = registry.revision();
    custom::remove_plugin("p");
    const auto& again = dingosdk::throwdowns::registry();
    check(again.revision() > before && again.definitions().size() == 3 && again.definitions()[0].id == "native.skate", "S.K.A.T.E. is back when it goes");
}

// The Filmer (contrib/plugins/filmer): an AI filmer follows a skater riding a carving line, then you film
// someone, with your skater carrying the camcorder for the others; all within the 2 ms a tick a plugin has.
void filmer_follows_and_films() {
    TestEnvironment environment;
    auto& game = environment.fake;
    const std::string plugin = "filmer";
    Host host(environment, Side::client);
    host.apply({contributed(plugin)});
    running(host, plugin, environment);
    SkaterTelemetry t;
    t.skater = true;
    t.physics_state = 100;
    t.speed = 6;
    game.telemetry = t;
    environment.local_skater = SkaterState{{0, 0.9f, 0}, 0, 6, 0, false, 0};
    host.set_level("sanvan");
    const auto ride = [&](int count) {
        for (int i = 0; i < count; ++i) {
            auto& skater = *environment.local_skater;
            static int step = 0;
            skater.heading = 0.4f * std::sin(static_cast<float>(++step) * 0.012f);
            skater.position[0] += std::sin(skater.heading) * 6.0f * 0.0167f;
            skater.position[2] += std::cos(skater.heading) * 6.0f * 0.0167f;
            game.telemetry->position = skater.position;
            game.telemetry->heading = skater.heading * 57.29578f;
            ticks(host, environment, 1);
        }
    };
    check(host.run_console("filmer mode follow"), "filmer mode follow");
    ride(900);
    running(host, plugin, environment);
    check(!environment.logged(".lua:"), "The Filmer follows without an error\n" + environment.all());
    check(game.called("camera filmer"), "It shows its camera\n" + environment.all());
    check(game.called("look filmer 1.00 100"), "with the VX look over the fisheye\n" + environment.all());
    check(game.called("cycle filmer active"), "in the camera height cycle, on");
    {
        // Where the AI filmer's lens is: behind the skater (never in front), a filmer's distance off, low.
        float x{}, y{}, z{};
        bool found = false;
        for (auto it = game.calls.rbegin(); it != game.calls.rend() && !found; ++it)
            if (it->starts_with("camera filmer ")) found = static_cast<bool>(std::istringstream(it->substr(14)) >> x >> y >> z);
        const auto& at = environment.local_skater->position;
        const float heading = environment.local_skater->heading;
        const float dx = x - at[0], dz = z - at[2];
        const float away = std::sqrt(dx * dx + dz * dz), along = dx * std::sin(heading) + dz * std::cos(heading);
        std::cout << "Filmer follow: the lens " << away << " m from the skater, " << along << " m along, " << y << " m up\n";
        check(found && away > 0.8f && away < 6.0f && along < 0.0f && y > 0.0f && y < 1.5f,
              "The AI filmer rides behind the skater, a filmer's distance off, low\n" + environment.all());
    }
    const auto follow_ms = status_of(host, plugin).tick_ms;
    std::cout << "Filmer follow: " << follow_ms << " ms a tick (its budget is 2 ms)\n";
    check(follow_ms < 2.0, "The Filmer follows within its 2 ms a tick");
    // You film the skater ahead of you, holding the camcorder out for the others to see.
    environment.lines.clear();
    check(host.run_console("filmer mode film"), "filmer mode film");
    ride(600);
    running(host, plugin, environment);
    check(!environment.logged(".lua:"), "You film without an error\n" + environment.all());
    check(game.called("carry filmer right both") && game.called(" push others") && game.called("hide skater filmer on") &&
              game.called("board hide filmer 2"),
          "Your skater carries the camcorder for the others, and you, looking through it, do not see your skater or board\n" + environment.all());
    check(game.called("hide filmer false false false stick true false true"), "The right stick and its click are the camera's");
    const auto film_ms = status_of(host, plugin).tick_ms;
    std::cout << "Filmer film: " << film_ms << " ms a tick\n";
    check(film_ms < 2.0, "You film within the 2 ms a tick");
    check(host.run_console("filmer slap") && environment.printed("Clip 1 marked"), "A slap marks a clip\n" + printed_lines(environment));
    check(host.run_console("filmer mode off"), "filmer mode off");
    ticks(host, environment, 30);
    check(game.called("carry filmer none") && game.called("camera release filmer"), "Off: the camcorder put down and the camera given back\n" + environment.all());
}

void smokey_throwdowns_register_and_play_one_up() {
    namespace kit = dingosdk::throwdowns::kit;
    TestEnvironment environment;
    auto& game = environment.fake;
    const std::string plugin = "SmokeyDawg58-ReSkate_Throwdown";
    Host host(environment, Side::client);
    host.apply({contributed(plugin)});
    running(host, plugin, environment);
    // His challenge registry on the Throwdowns page: R.E.S.K.A.T.E. in S.K.A.T.E.'s place, 1-UP and his
    // game modes after the stock cards, each with his donor card, colour, order and flag prefab.
    check(game.modes.size() == 10, "His ten modes are on the Throwdowns page\n" + environment.all());
    check(game.modes.front().id == "skate" && game.modes.front().replaces == "skate" && game.modes.front().card == "skate",
          "R.E.S.K.A.T.E. takes S.K.A.T.E.'s place");
    const auto registered = [&](const std::string& id) -> const ThrowdownMode& {
        for (const auto& m : game.modes) if (m.id == id) return m;
        throw std::runtime_error("no mode " + id);
    };
    check(registered("oneup").card == "spot" && registered("oneup").order == 1 && registered("oneup").name == "1-UP" &&
              registered("oneup").flag == "World/ReSkate/Throwdowns/Flags/oneup_Placement",
          "1-UP is one of his modes now");
    check(registered("race").card == "spot" && registered("race").color == 0xff3434ffU && registered("race").order == 4 &&
              registered("race").flag == "World/ReSkate/Throwdowns/Flags/race_Placement" && registered("race").cursor_height == 99999,
          "Deathrace: his donor, colour, order, flag and a start flag that may stand on anything");
    check(registered("tag").card == "skate" && registered("hide").card == "skate" && registered("jam").card == "jam" && registered("meat").card == "spot",
          "His donor rule: tag-like modes S.K.A.T.E.'s card, Spot Jam Skate Jam's, the rest Spot Battle's");
    SkaterTelemetry t;
    t.skater = true;
    t.position = {1, 2, 3};
    t.physics_state = 100;
    game.telemetry = t;
    environment.local_skater = SkaterState{{1, 2, 3}, 0, 0, 0, false, 0};
    environment.score_now = ScoreState{0, 1, false, {}, {}, false};
    host.set_level("sanvan");
    ticks(host, environment, 50); // its game layer loads a part a tick
    running(host, plugin, environment);
    check(game.kit_documents >= 5, "It publishes the kit's documents\n" + environment.all());
    {
        const auto idle = kit::documents_for(plugin + "/jam");
        check(idle && !idle->hud.active && !idle->setup && !idle->waiting && !idle->panel.present, "Idle, no HUD and no pages");
    }
    check(!environment.logged(".lua:") && !environment.logged("tick failed"), "Idle ticks run clean\n" + environment.all());
    // His rule checks (tdm test, his mode_rules_tests.cpp).
    environment.lines.clear();
    check(host.run_console("tdm test"), "tdm test");
    check(environment.printed(" 0 failed") && environment.printed(" passed"), "His rule checks pass:\n" + printed_lines(environment));

    const auto docs_of = [&](const std::string& key) {
        const auto docs = kit::documents_for(key);
        check(docs.has_value(), key + ": its documents are in the kit's store");
        return *docs;
    };
    const auto flag_waiting = [&](const std::string& key, std::uint32_t id) { game.flag = {true, true, false, true, key, id}; };
    struct Expect {
        const char* mode;
        const char* title;
        const char* timer;
        std::vector<std::string> rows;
    };
    const std::vector<Expect> expected{
        {"jam", "Spot Jam", "Timer", {"area"}}, {"meat", "Hall of Meat", "Timer", {"area"}},
        {"domination", "Domination", "Timer", {"capture-spots"}}, {"graffiti", "Graffiti", "Timer", {"area"}},
        {"tag", "Skate Tag", "Timer", {"area"}}, {"infection", "Infection", "Timer", {"area"}},
        {"hide", "Hide & Seek", "Duration", {"hide_time", "area"}}, {"skate", "R.E.S.K.A.T.E.", "Turn Timer", {"letters", "tricks", "zone"}},
        {"race", "Deathrace", "Finish deadline", {}}};
    std::uint32_t id = 101;
    for (const auto& e : expected) {
        const std::string mode = e.mode, key = plugin + "/" + mode;
        id += 2;
        // A card click: the kit begins the native flag with the stock setup page open, then says `open`.
        check(game.throwdown_flag_begin(key, id, {6, 120, true, 0}), mode + ": the flag begins");
        game.flag.placing = false;
        kit::post(key, "open", {std::to_string(id)});
        ticks(host, environment, 2);
        auto docs = docs_of(key);
        check(docs.setup && docs.setup->mode == key && docs.setup->title == e.title && docs.setup->timer.present &&
                  docs.setup->timer.caption == e.timer && docs.setup->players.present && docs.setup->players.max == 6 && docs.setup->back == "BACK",
              mode + ": his setup page\n" + environment.all());
        std::vector<std::string> rows;
        for (const auto& row : docs.setup->rows) rows.push_back(row.id);
        check(rows == e.rows, mode + ": his setup rows (" + std::to_string(rows.size()) + ")");
        if (mode == "jam") check(docs.setup->rows[0].kind == "button" && docs.setup->rows[0].label == "Set optional area", "Spot Jam's Area button");
        if (mode == "skate")
            check(docs.setup->rows[1].options.size() == 4 && docs.setup->rows[2].options.size() == 6 && docs.setup->rows[0].max == 7,
                  "R.E.S.K.A.T.E.'s Letters, Tricks and Trick Zone");
        kit::post(key, "setup_row", {"players", "3"});
        ticks(host, environment, 2);
        check(docs_of(key).setup->players.value == 3, mode + ": the Players row sets his capacity");
        // Confirm, then the native flag placed.
        kit::post(key, "setup_confirm", {"3", mode == "race" ? "120" : "300"});
        game.flag.placing = true;
        ticks(host, environment, 1);
        flag_waiting(key, id);
        kit::post(key, "flag_placed", {std::to_string(id), "1", "2", "3", "90"});
        ticks(host, environment, 3);
        docs = docs_of(key);
        // Deathrace's route editor opens over its placed start flag: no waiting card until it closes.
        check(mode == "race" ? !docs.waiting
                             : docs.waiting && docs.waiting->mode == key && docs.waiting->title == e.title && docs.waiting->capacity == 3,
              mode + ": his waiting card\n" + environment.all());
        if (mode == "race") {
            check(docs.hud.active && docs.hud.theme == "race" && docs.hud.editor.present && docs.hud.editor.title == "Deathrace builder" &&
                      docs.hud.editor.prompts.size() == 11 && docs.hud.editor.info_title == "ROUTE INFO" && docs.hud.header.title == "DEATHRACE" &&
                      docs.hud.header.frame_width == 704,
                  "Deathrace's start gate opens his route editor\n" + environment.all());
            // His route library: a route saved on this map, the load dialog (hold Start), a row picked.
            game.files[plugin + "/routes/test_map/Loop.json"] =
                R"({"format": "ReSkate Deathrace route", "version": 1, "id": 7, "name": "Loop", "map": "test_map", "settings": {)"
                R"("duration_seconds": 120, "turn_seconds": 30, "strikes": 3, "radius": 6, "area_radius": 0, "corners": [],)"
                R"("points": [[1, 2, 3], [1, 2, 23], [1, 2, 43]], "yaw_degrees": [0, 0, 0], "half_widths": [6, 6, 6],)"
                R"("gate_types": ["required", "required", "required"], "arrow_roll_degrees": [], "pitch_degrees": [], "spawn": [1, 2, 3],)"
                R"("has_spawn": true, "finish_gate": true, "trick_kinds": 15}})";
            game.focus_now = {true, false, true};
            game.pad_bits_now = 0u;
            ticks(host, environment, 3);
            game.pad_bits_now = 0x10u;
            ticks(host, environment, 100);
            check(game.dialog && game.dialog->id == "route-load" && game.dialog->title == "LOAD DEATHRACE ROUTE" && game.dialog->rows.size() == 1 &&
                      game.dialog->rows[0].text == "Loop" && game.dialog->file.present && game.dialog->buttons[0].label == "Back to builder",
                  "Hold Start: his route library\n" + environment.all());
            game.pad_bits_now = 0u;
            ticks(host, environment, 2);
            kit::post_to(plugin, "dialog", {}, {"route-load", "row", "", "1", ""});
            ticks(host, environment, 3);
            {
                const auto info = docs_of(key).hud.editor.info;
                check(!info.empty() && info[0].first == "Required gates: 1" && info[1].first == "Finish gate: Placed", "The route is loaded\n" + environment.all());
            }
            // Tap Start: name and save it, then players can enroll.
            game.pad_bits_now = 0x10u;
            ticks(host, environment, 2);
            game.pad_bits_now = 0u;
            ticks(host, environment, 3);
            check(game.dialog && game.dialog->id == "route-save" && game.dialog->title == "SAVE DEATHRACE ROUTE" && game.dialog->field.text == "Loop",
                  "Tap Start: his save dialog\n" + environment.all());
            kit::post_to(plugin, "dialog", {}, {"route-save", "save", "Loop Two", "0", ""});
            ticks(host, environment, 3);
            check(game.files.contains(plugin + "/routes/test_map/Loop Two.json") && game.called("dialog close " + plugin + " route-save"),
                  "The route is saved as his JSON\n" + environment.all());
            check(game.files[plugin + "/routes/test_map/Loop Two.json"].find("\"format\": \"ReSkate Deathrace route\"") != std::string::npos,
                  "in his format");
            {
                const auto saved = docs_of(key);
                check(saved.waiting && saved.waiting->title == e.title && saved.waiting->capacity == 3 && saved.waiting->can_start &&
                          !saved.hud.editor.present,
                      "A saved route closes the editor: his waiting card, and it can start\n" + environment.all());
            }
            game.focus_now = {};
            game.pad_bits_now.reset();
        } else {
            if (mode == "domination") check(host.run_console("tdm point"), "his Domination needs a spot: `mode point` where the skater is");
            ticks(host, environment, 2);
            check(docs_of(key).waiting->can_start, mode + ": the host can start\n" + environment.all());
            kit::post(key, "start", {std::to_string(id)});
            ticks(host, environment, 400);
            const auto ms = status_of(host, plugin).tick_ms;
            std::cout << "SmokeyDawg58 " << mode << ": " << ms << " ms a tick playing (its budget is 2 ms)\n";
            check(ms < 2, mode + ": within its time");
            docs = docs_of(key);
            const auto& hud = docs.hud;
            check(hud.active && hud.theme == mode && !docs.waiting, mode + ": Start plays it alone\n" + environment.all());
            check(mode == "skate" ? hud.header.title.empty() && hud.card.present && hud.layout == "bottom"
                                  : hud.header.title == e.title && hud.counters.size() == 2 && hud.counters[0].starts_with("LEADER"),
                  mode + ": his HUD's title and score block");
            check(hud.board.present && !hud.results.present
                      ? hud.board.title == "LEADERBOARD" && hud.board.rows.size() == 1 && hud.board.rows[0].self
                      : hud.results.present && hud.results.title == std::string(e.title) + " RESULTS",
                  mode + ": his leaderboard\n" + environment.all());
            if (!hud.results.present)
                check(docs.panel.present && docs.panel.title == e.title && docs.panel.players.size() == 1 && docs.panel.settings.size() == 3,
                      mode + ": his Throwdown Panel");
            check(kit::match().markers || hud.results.present, mode + ": the match keeps the session markers");
        }
        running(host, plugin, environment);
        check(!environment.logged(".lua:") && !environment.logged("tick failed") && !environment.logged("failed:"),
              mode + " runs without errors\n" + environment.all());
        kit::post(key, "quit", {});
        ticks(host, environment, 3);
        game.flag = {};
        ticks(host, environment, 2);
        docs = docs_of(key);
        check(!docs.hud.active && !docs.waiting, mode + ": Quit ends it\n" + environment.all());
    }
    // 1-UP: a practice match, alone at its flag.
    const std::string oneup = plugin + "/oneup";
    check(game.throwdown_flag_begin(oneup, 501, {4, 120, true, 0}), "1-UP's flag begins");
    game.flag.placing = false;
    kit::post(oneup, "open", {"501"});
    ticks(host, environment, 2);
    auto docs = docs_of(oneup);
    check(docs.setup && docs.setup->title == "1-UP" && docs.setup->timer.value == 20 && docs.setup->timer.max == 120, "1-UP's setup page\n" + environment.all());
    kit::post(oneup, "setup_row", {"players", "1"});
    kit::post(oneup, "setup_confirm", {"1", "20"});
    game.flag.placing = true;
    ticks(host, environment, 1);
    flag_waiting(oneup, 501);
    kit::post(oneup, "flag_placed", {"501", "1", "2", "3", "0"});
    ticks(host, environment, 5);
    docs = docs_of(oneup);
    check(docs.waiting && docs.waiting->title == "1-UP" && docs.waiting->can_start && docs.waiting->capacity == 1, "1-UP's waiting card\n" + environment.all());
    kit::post(oneup, "start", {"501"});
    bool played = false;
    for (int i = 0; i < 600 && !played; ++i) {
        ticks(host, environment, 1);
        docs = docs_of(oneup);
        played = docs.hud.active && docs.hud.clock.present && docs.hud.clock.ticking;
    }
    const auto& hud = docs.hud;
    check(played && hud.theme == "oneup" && hud.header.title == "1-UP" && hud.counters.size() == 2 && hud.counters[0].starts_with("TARGET") &&
              hud.board.present && hud.board.variant == "stamps" && hud.board.rows.size() == 1 && hud.board.rows[0].marks.size() == 3 &&
              hud.board.title.ends_with("'S TURN"),
          "1-UP's practice plays, his score HUD up\n" + environment.all());
    check(docs.panel.present && docs.panel.title == "1-UP" && kit::match().markers, "1-UP's panel and markers");
    std::cout << "SmokeyDawg58 1-UP: " << status_of(host, plugin).tick_ms << " ms a tick playing\n";
    check(status_of(host, plugin).tick_ms < 2, "1-UP within its time");
    kit::post(oneup, "quit", {});
    ticks(host, environment, 3);
    game.flag = {};
    ticks(host, environment, 2);
    check(!docs_of(oneup).hud.active, "1-UP's Quit ends it\n" + environment.all());
    running(host, plugin, environment);
    check(!environment.logged(".lua:") && !environment.logged("tick failed"), "1-UP runs without errors\n" + environment.all());
    // His ReSkate-menu 1-UP card, as the plugin's page: Place 1-Up here, then its lobby, then Exit.
    environment.panels_open = true;
    environment.shown = plugin;
    ticks(host, environment, 5);
    using K = plugin_ui::Widget::Kind;
    check(!environment.panels.empty() && environment.panels[0].page && environment.panels[0].title == "1-UP" &&
              environment.panels[0].widgets[0].kind == K::card && environment.panels[0].widgets[0].text == "1-UP",
          "His 1-UP card on the plugin's page\n" + environment.all());
    environment.actions = {plugin_ui::Action{plugin, "1-UP", "place", false}};
    ticks(host, environment, 30);
    const auto heading = [&] {
        for (const auto& w : environment.panels[0].widgets) if (w.kind == K::heading) return w.text;
        return std::string{};
    };
    {
        std::string widgets;
        for (const auto& w : environment.panels[0].widgets) widgets += w.text + " | " + w.help + "\n";
        check(heading() == "READY UP", "Place 1-Up here opens its lobby: " + heading() + "\n" + widgets + environment.all());
    }
    environment.actions = {plugin_ui::Action{plugin, "1-UP", "exit", false}};
    ticks(host, environment, 30);
    check(heading().empty(), "and Exit 1-Up leaves it");
    environment.panels_open = false;
    // His console verbs, under tdm.
    check(host.run_console("tdm help"), "tdm help");
    check(!environment.logged(".lua:"), "tdm help answers\n" + environment.all());
}

void grind_exits_pick_the_side() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "grind-exits");
    auto& game = environment.fake;
    Host host(environment, Side::client);
    host.apply({contributed("grind-exits")});
    running(host, "grind-exits", environment);
    check(host.run_console("grindexit test"), "grindexit test");
    check(environment.printed("grindexit: 11 passed, 0 failed") && !environment.printed("FAIL"),
          "Grind exits' own checks pass:\n" + printed_lines(environment) + environment.all());
    check(host.run_console("grindexit stance goofy"), "grindexit stance");
    // The board travels along (1, 3) (the fake's board velocity), whose left is (0.95, -0.32); the
    // root's right axis points that way, and a goofy skater riding normal has the toes there.
    environment.local_skater = SkaterState{{0, 0, 0}, 0, 3, 0, false, 0};
    environment.local_skater->right = Vec3{1, 0, 0};
    game.pad = PadInput{};
    game.state = 100;
    ticks(host, environment, 2);
    game.state = 400; // grinding
    ticks(host, environment, 2);
    game.pad->right_trigger = 1;
    ticks(host, environment, 2);
    check(game.called("launch grind-exits grind -1.80"), "RT asks for the heel side, the right of travel\n" + environment.all());
    check(game.called("hide grind-exits false true true"), "and keeps RT and the stick's lean from the game\n" + environment.all());
    const std::array<float, 2> travel{0.316f, 0.949f};
    game.launches.push_back({"grind", {1.708f, 2, -0.569f}, {-1.708f, 2, 0.569f}, travel, 3.2f, "applied", "grind-exits"});
    game.launches.push_back({"ollie", {0, 3, 4}, {0, 3, 4}, travel, 4, "none", ""});
    ticks(host, environment, 1);
    game.pad->right_trigger = 0;
    ticks(host, environment, 10);
    check(game.called("launch grind-exits grind none") && game.called("hide grind-exits false false false"), "Let go, the game's own again");
    environment.lines.clear();
    check(host.run_console("grindexit") && environment.printed("seen: 1, sides set: 1. Last: right of travel (toe_heel)"),
          "It counts the pop out of the grind, not the ollie:\n" + printed_lines(environment));
}
void fpv_drone_flies_and_follows() {
    TestEnvironment environment;
    std::filesystem::remove_all(scratch / "storage" / "fpv-drone");
    auto& game = environment.fake;
    environment.session_now = {true, false, {{1, "Me", true, true, false}, {2, "Other", false, false, false}}};
    Host host(environment, Side::client);
    host.apply({contributed("fpv-drone")});
    running(host, "fpv-drone", environment);
    check(host.run_console("fpv test"), "fpv test");
    ticks(host, environment, 150); // one test every 50 ms
    check(environment.printed("fpv test: 27 passed, 0 failed") && !environment.printed("FAIL"),
          "The drone's own tests pass:\n" + printed_lines(environment) + environment.all());
    running(host, "fpv-drone", environment);
    // No level: it does not take off.
    environment.lines.clear();
    check(host.run_console("fpv fly") && environment.printed("fpv: Load into a level to fly."), "No flight without a level");
    host.set_level("sanvan");
    environment.local_skater = SkaterState{{0, 0, 0}, 0, 0, 0, false, 0};
    environment.lines.clear();
    check(host.run_console("fpv fly") && environment.printed("fpv: flying."), "fpv fly:\n" + printed_lines(environment));
    // The fake's keys: full right, half forward, the mouse moving, boost. It must keep off the ground.
    environment.sent.clear();
    ticks(host, environment, 600);
    running(host, "fpv-drone", environment);
    check(game.called("camera fpv-drone") && game.called("capture fpv-drone on"), "It flies the camera and keeps the game off the input\n" + environment.all());
    check(game.called("sound fpv-drone motor"), "Its motor plays\n" + environment.all());
    check(game.called("outfit fpv-drone eyewear Own_EyewearGlasses_Gen_SunglassesVisorLarge_00001"), "The pilot puts on goggles");
    check(game.called("hud fpv-drone on"), "and the game's HUD is hidden");
    check(environment.sent.size() >= 100 && environment.sent.size() <= 140, "It tells the session where it is about 12 times a second: " +
          std::to_string(environment.sent.size()));
    const auto flying_ms = status_of(host, "fpv-drone").tick_ms;
    const auto flying_message = environment.sent[5];
    environment.lines.clear();
    check(host.run_console("fpv status") && environment.printed("fpv: fly, "), "fpv status:\n" + printed_lines(environment));
    // Follow me, behind a skater riding along +Z.
    check(host.run_console("fpv follow"), "fpv follow");
    for (int i = 0; i < 600; ++i) {
        environment.local_skater->position[2] += 5 * 0.0167f;
        environment.local_skater->speed = 5;
        ticks(host, environment, 1);
    }
    running(host, "fpv-drone", environment);
    const auto following_ms = status_of(host, "fpv-drone").tick_ms;
    const auto& last = game.calls;
    const auto camera = std::find_if(last.rbegin(), last.rend(), [](const auto& c) { return c.starts_with("camera fpv-drone "); });
    check(camera != last.rend(), "Following flies the camera");
    float x{}, y{}, z{};
    std::istringstream words(camera->substr(std::string_view("camera fpv-drone ").size()));
    check(static_cast<bool>(words >> x >> y >> z), "the camera's position: " + *camera);
    const float skater_z = environment.local_skater->position[2];
    check(y > 0.5f && z < skater_z - 1 && z > skater_z - 12, std::format("The drone is behind the skater ({:.1f}, {:.1f}, {:.1f}), the skater at z {:.1f}",
          x, y, z, skater_z));
    environment.lines.clear();
    game.calls.clear();
    check(host.run_console("fpv stop") && environment.printed("fpv: landed."), "fpv stop");
    ticks(host, environment, 120);
    check(game.called("camera release fpv-drone") && game.called("outfit clear fpv-drone eyewear") && game.called("hud fpv-drone off"),
          "Landing gives the camera, the eyewear and the HUD back\n" + environment.all());
    std::cout << std::format("fpv-drone: {:.3f} ms a tick flying, {:.3f} ms following (its budget is 2 ms)\n", flying_ms, following_ms);
    check(flying_ms < 2 && following_ms < 2, "It stays within its time");
    // Another player's drone: a marker, a tag on their nametag and their motor; gone once not heard from.
    game.calls.clear();
    environment.incoming.push_back({2, flying_message});
    ticks(host, environment, 2);
    check(game.called("tag fpv-drone 2 FLYING DRONE") && game.called("sound fpv-drone motor"), "Their drone is tagged and heard\n" + environment.all());
    const bool marked = std::any_of(environment.layers.begin(), environment.layers.end(), [](const auto& layer) {
        return std::any_of(layer.shapes.begin(), layer.shapes.end(), [](const auto& shape) { return shape.text.find(" m") != std::string::npos; });
    });
    check(marked, "and marked with how far it is");
    ticks(host, environment, 120);
    check(game.called("tag fpv-drone 2  ") && game.called("stop sound fpv-drone"), "Not heard from, it is gone\n" + environment.all());
    environment.panels_open = true;
    ticks(host, environment, 5);
    check(environment.panels.size() == 1 && environment.panels[0].page && environment.panels[0].widgets[0].kind == plugin_ui::Widget::Kind::tabs &&
              environment.panels[0].widgets[0].choices.size() == 5,
          "Its page, with its five tabs, is built while the menu shows it: " + std::to_string(environment.panels.size()));
    environment.actions = {plugin_ui::Action{"fpv-drone", "FPV Drone", "tabs", false, 0, 4}};
    ticks(host, environment, 10);
    check(environment.panels[0].widgets[0].chosen == 4 && environment.panels[0].widgets[1].text == "GOGGLE DISPLAY",
          "and a tab picked shows its part");
    environment.panels_open = false;
}

void reskate_hostile_is_stopped_or_refused_every_time() {
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({contributed("reskate-hostile")});
    running(host, "reskate-hostile", environment);
    struct Case { const char* attack; bool stops; int ticks; bool trick = false; bool panels = false; };
    const Case cases[] = {
        {"loop", true, 0}, {"caught-loop", true, 0}, {"tick-loop", true, 1}, {"memory", true, 0},
        {"caught-memory", true, 0}, {"huge-string", true, 0}, {"buffer", true, 0}, {"coroutines", true, 0},
        {"errors", true, 10}, {"slow", true, 60 * 5}, {"log-flood", false, 1}, {"timers", false, 1},
        {"recursion", false, 1}, {"escapes", false, 1}, {"teleport-spam", false, 1}, {"raycast-flood", false, 1}, {"trick-loop", true, 0, true}, {"draw-flood", false, 2}, {"toast-spam", false, 1},
        {"sound-spam", false, 1}, {"message-flood", false, 1}, {"panel-loop", true, 2, false, true},
        {"chat-spam", false, 1}, {"edit-spam", false, 1}, {"travel-spam", false, 1}, {"web-elsewhere", false, 1},
        {"bind-spam", false, 1}, {"screen-loop", true, 10}, {"notice-spam", false, 1}, {"notice-spoof", false, 1},
        {"freeze-spam", false, 1}, {"server-spoof", false, 1}, {"picture-escape", false, 20}, {"clip-garbage", false, 1}, {"outfit-anywhere", false, 1},
        {"throwdown-spam", false, 1},
    };
    for (const auto& item : cases) {
        check(host.reload("reskate-hostile").find("reloaded") != std::string::npos, std::string("reloads before ") + item.attack);
        check(host.run_console(std::string("hostile ") + item.attack), item.attack);
        ticks(host, environment, item.ticks);
        if (item.trick) host.trick({TrickNews::Kind::landed, 100, 1});
        if (item.panels) {
            environment.panels_open = true;
            ticks(host, environment, item.ticks);
            environment.panels_open = false;
        }
        const auto state = status_of(host, "reskate-hostile").state;
        check((state == "stopped") == item.stops, std::string(item.attack) + " left it " + state + "\n" + environment.all());
    }
    check(!environment.printed("ESCAPED"), "No attack got out:\n" + printed_lines(environment));
    check(environment.printed("hostile escapes: 17 of 17 refused"), "and every escape was tried\n" + printed_lines(environment));
    host.reload("reskate-hostile");
    host.run_console("hostile slow-unload");
    const auto start = std::chrono::steady_clock::now();
    host.switch_off("reskate-hostile");
    const auto ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    check(ms < 500, "An unload handler that never ends is cut off: " + std::to_string(ms) + " ms");
}
}

// Actual Host + current Lua API. Native Game observations below are constructed;
// these checks do not establish visible geometry, a native collision or a rider.
void bmx_lua_spawn_uses_owned_chassis_and_measured_part_placement() {
    using dingosdk::Json;
    namespace world = dingosdk::bmx::world;
    const auto root = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib/bmx-lab";
    const auto contents = [](const std::filesystem::path& path) {
        std::ifstream in(path, std::ios::binary);
        check(in.good(), "required Lua spawn source: " + path.string());
        return std::string(std::istreambuf_iterator<char>(in), {});
    };
    std::map<std::string, std::string> files;
    for (const auto* name : {"force_math.lua", "bike_geometry.lua", "bike_visual.lua", "bike_spawn.lua"})
        files[std::string("plugin/") + name] = contents(root / "bmx-plugin/plugin" / name);
    files[manifest_file] = manifest(R"("console","world.entities","world.physics","skater.read","input")");
    files["plugin/main.lua"] = R"(
        local bike=require("./bike_spawn").new()
        reskate.console.command("bike-spawn", "test Arm", function() bike:request() end)
        reskate.console.command("bike-stop", "test stop", function() bike:stop("explicit test stop") end)
        reskate.console.command("bike-clock-retry", "test explicit readiness retry", function() bike:retry_after_clock_warmup() end)
        reskate.console.command("bike-state", "test status", function() reskate.log("SPAWN_STATUS "..reskate.json.encode(bike:status())) end)
        reskate.on("tick",function(dt) bike:update(dt) end)
        reskate.on("unload",function() bike:stop("unload") end)
    )";
    const auto assets = [](TestEnvironment& e) {
        e.fake.test_forbid_blueprint_enumeration=true;
        e.local_skater = SkaterState{{1,2,3}, .3f, 0,0,false,0};
        e.fake.focus_now = {true,false,true};
        constexpr auto radius = static_cast<float>(dingosdk::bmx::geometry::wheel_radius);
        for (const auto name : world::blueprints)
            e.fake.test_entity_boxes[std::string(name)] = {Vec3{-.2f,-radius,-radius},Vec3{.2f,radius,radius}};
    };
    const auto state = [](Host& h, TestEnvironment& e) {
        check(h.run_console("bike-state"), "status command is registered");
        constexpr std::string_view marker="SPAWN_STATUS ";
        for (auto at=e.logs.rbegin(); at!=e.logs.rend(); ++at)
            if (const auto p=at->find(marker); p!=std::string::npos) return Json::parse(at->substr(p+marker.size()));
        throw std::runtime_error("missing actual Lua state: " + e.all());
    };
    const auto no_driving = [](const TestEnvironment& e) {
        check(!e.fake.body_submissions && !e.fake.batch_calls && !e.fake.probes && !e.rays &&
            e.teleports.empty() && e.fake.binds.empty() && !e.fake.input_pulse_requests &&
            !e.fake.native_action_requests && !e.fake.native_recovery_requests,
            "spawn diagnostics must never drive the rider, input, contacts or body");
    };
    const auto bounded_ticks = [](Host& h, TestEnvironment& e, int count) {
        for (int tick=0;tick<count;++tick) {
            const auto before=e.fake.test_bounds_lookups;
            ticks(h,e,1);
            check(e.fake.test_bounds_lookups-before<=1,"preflight made more than one exact bounds lookup in a tick");
            check(!e.fake.test_blueprint_enumerations,"spawn attempted forbidden global asset enumeration");
        }
    };
    unsigned scenarios=0;
    {
        auto actual=files;
        actual[manifest_file]=contents(root/"bike-spawn-trial"/manifest_file);
        actual["plugin/main.lua"]=contents(root/"bike-spawn-trial/plugin/main.lua");
        TestEnvironment e; assets(e); e.panels_open=true; e.shown="bike-spawn-inert";
        Host h(e,Side::client); h.apply({package("bike-spawn-inert",actual)});
        bounded_ticks(h,e,60); running(h,"bike-spawn-inert",e);
        check(!e.fake.body_creates && e.fake.entities.empty() && e.fake.calls.empty(),
            "exact trial page and 60 menu rebuilds remain inert before Arm");
        check(std::any_of(e.panels.begin(),e.panels.end(),[](const auto& p){return p.title=="Lua Bike Spawn Trial";}),
            "exact trial page builds");
        e.fake.focus_now.interface_open=true;
        e.actions={plugin_ui::Action{"bike-spawn-inert","Lua Bike Spawn Trial","spawn",false}};
        bounded_ticks(h,e,1);check(!e.fake.body_creates && e.fake.entities.empty(),"actual menu Arm cannot spawn while menu is open");
        e.panels_open=false;e.fake.focus_now.interface_open=false;
        bounded_ticks(h,e,9);running(h,"bike-spawn-inert",e);
        check(e.fake.body_creates==1 && e.fake.entities.size()==8,"exact menu entry creates one measured chassis after close");
        e.fake.body_producer_step();bounded_ticks(h,e,1);
        e.panels_open=true;e.fake.focus_now.interface_open=true;
        bounded_ticks(h,e,1);
        check(e.fake.body_release_calls==1 && e.fake.entities.empty(),"reopening actual menu stops unmounted trial");
        h.apply({}); // SDK storage flushes on VM shutdown; do not read an older ledger.
        const auto receipt=Json::parse(contents(e.storage_root()/"bike-spawn-inert/storage.json"));
        check(receipt["lua_bike_spawn_v1"]["phase"]==Json("closed") &&
            receipt["lua_bike_spawn_v1"]["visual_updates"]==Json(2) &&
            receipt["lua_bike_spawn_v1"]["last_measurement"]["serial"]==Json("101"),
            "exact page writes measured spawn receipt after release");
        check(e.logged("Lua bike API") && receipt["lua_bike_api_marker_v3"]["event"]==Json("after") &&
            receipt["lua_bike_api_marker_v3"]["operation"]==Json("release"),
            "actual trial source keeps before/after API breadcrumbs through release and storage flush");
        check(receipt["lua_bike_api_create_result_v4"]["pcall_ok"]==Json(true) &&
            receipt["lua_bike_api_create_result_v4"]["value_type"]==Json("userdata") &&
            receipt["lua_bike_api_create_result_v4"]["body_returned"]==Json(true) &&
            receipt["lua_bike_api_create_result_v4"]["arity"]==Json(1) &&
            receipt["lua_bike_api_read_result_v4"]["value_type"]==Json("table") &&
            receipt["lua_bike_api_release_result_v4"]["release_accepted"]==Json(true),
            "independent bounded result records survive later read and release cleanup");
        no_driving(e); ++scenarios;
    }
    for (unsigned scenario=0; scenario<13; ++scenario) {
        const std::string id="bike-spawn-case-"+std::to_string(scenario);
        TestEnvironment e; assets(e);
        if (scenario==1) e.fake.test_entity_boxes.erase("reskate/bmx/fork");
        if (scenario==2) e.fake.test_entity_boxes["reskate/bmx/rear_wheel"]={Vec3{-.2f,-.34f,-.34f},Vec3{.2f,.34f,.34f}};
        if (scenario==3) e.fake.test_entity_fail_id=3;
        if (scenario==10) e.fake.test_body_create_refusal="body_preallocation_unavailable";
        if (scenario==11) e.fake.test_body_create_refusal="partial native body creation retained in quarantine; allocation retry prohibited";
        if (scenario==12) e.fake.test_body_create_refusal="body_preallocation_unavailable";
        Host h(e,Side::client); h.apply({package(id,files)}); running(h,id,e);
        bounded_ticks(h,e,3); check(!e.fake.body_creates && e.fake.entities.empty(),"startup must not spawn");
        check(h.run_console("bike-spawn"),"explicit request reaches actual Lua");
        if (scenario==1) {
            bounded_ticks(h,e,303);
            check(state(h,e)["phase"]==Json("closed") && !e.fake.body_creates && e.fake.entities.empty(),"missing asset times out without allocation");
        } else if (scenario==2 || scenario==3) {
            bounded_ticks(h,e,9);
            const auto result=state(h,e);
            check(result["phase"]==Json("closed") && !e.fake.body_creates && e.fake.entities.empty(),"mismatched mesh, prefix setter failure or clock refusal cleans requested visuals without body retry: "+result.dump());
            bounded_ticks(h,e,10); check(!e.fake.body_creates,"no hidden body creation retry");
        } else if (scenario>=10) {
            bounded_ticks(h,e,9); auto result=state(h,e);
            const bool warmup=scenario!=11;
            check(result["phase"]==Json(warmup ? "clock_prepared" : "cleanup_unknown") && !e.fake.body_creates && e.fake.entities.empty(),
                "only exact preallocation readiness refusal makes a separate retry available: "+result.dump());
            bounded_ticks(h,e,10); check(state(h,e)["creation_attempts"]==Json(1),"readiness does not silently retry");
            if (scenario!=12) e.fake.test_body_create_refusal.clear();
            check(h.run_console("bike-clock-retry"),"explicit readiness retry action"); bounded_ticks(h,e,9);result=state(h,e);
            if (scenario==10) check(result["phase"]==Json("spawned") && result["creation_attempts"]==Json(2) && e.fake.body_creates==1,
                "separate explicit request creates after explicit readiness wait");
            if (scenario==11) check(result["phase"]==Json("cleanup_unknown") && result["creation_attempts"]==Json(1) && !e.fake.body_creates,
                "partial/unknown create can never enter readiness retry");
            if (scenario==12) {
                check(result["phase"]==Json("closed") && result["creation_attempts"]==Json(2),"second exact readiness refusal closes the bounded trial");
                check(h.run_console("bike-clock-retry"),"third retry refused"); bounded_ticks(h,e,2);
                check(state(h,e)["creation_attempts"]==Json(2),"only one explicit readiness retry allowed");
            }
        } else {
            bounded_ticks(h,e,8); check(!e.fake.body_creates && e.fake.entities.size()==8,"eight separate exact mesh probes precede chassis allocation");
            bounded_ticks(h,e,1); auto result=state(h,e);
            check(result["phase"]==Json("spawned") && result["visual_updates"]==Json(1) && e.fake.body_creates==1 && e.fake.entities.size()==8,
                "one measured chassis spawns after visual readiness: "+result.dump()+"\n"+e.all());
            auto& body=e.fake.owned.begin()->second;
            check(body.definition.count==8 && body.definition.mass==106,"authored bounded combined-body definition reached actual API");
            const auto frame=e.fake.entities.at({id,1}).second;
            if (scenario==0) {
                bounded_ticks(h,e,1); check(state(h,e)["visual_updates"]==Json(1),"same immutable native epoch is not another visual step");
                body.sample.position[0]+=.125f; ++body.sample.epoch.serial; body.sample.epoch.time+=body.sample.epoch.seconds;
                bounded_ticks(h,e,1); result=state(h,e);
                check(result["phase"]==Json("spawned") && result["visual_updates"]==Json(2) &&
                    std::abs(e.fake.entities.at({id,1}).second[12]-frame[12]-.125f)<.00001f,"actual body read moves all visuals from measured COM");
                check(h.run_console("bike-stop"),"explicit release command");
                result=state(h,e);
                check(result["phase"]==Json("closed") && result["body_release_accepted"]==Json(true) &&
                    result["visual_remove_requested"]==Json(true) && e.fake.body_release_calls==1 && body.released && e.fake.entities.empty(),
                    "release acceptance and visual removal requests are separately reported");
                check(h.run_console("bike-spawn"),"rearm request consumed"); bounded_ticks(h,e,2);
                check(e.fake.body_creates==1 && e.fake.body_release_calls==1,"one shot does not recreate retained allocations");
            } else if (scenario==4) {
                e.fake.focus_now={false,false,true}; bounded_ticks(h,e,1);
                check(state(h,e)["phase"]==Json("closed") && body.released && e.fake.entities.empty(),"focus loss releases and removes");
            } else if (scenario==5) {
                body.sample.position[0]+=.125f; bounded_ticks(h,e,1);
                check(state(h,e)["phase"]==Json("closed") && body.released && e.fake.entities.empty(),"mutable pose in identical epoch is refused");
            } else if (scenario==6) {
                body.sample.epoch.serial=9007199254740994ULL; body.sample.epoch.time+=body.sample.epoch.seconds;
                bounded_ticks(h,e,1); check(state(h,e)["serial"]==Json("9007199254740994"),"epoch serial above 2^53 stays exact");
                ++body.sample.epoch.serial; body.sample.epoch.time+=body.sample.epoch.seconds; bounded_ticks(h,e,1);
                check(state(h,e)["serial"]==Json("9007199254740995") && state(h,e)["visual_updates"]==Json(3),"adjacent large serials remain distinct");
            } else if (scenario==7) {
                e.fake.test_body_release_refused=true; check(h.run_console("bike-stop"),"constructed unknown release");
                result=state(h,e);
                check(result["phase"]==Json("cleanup_unknown") && result["body"]==Json(true) &&
                    result["cleanup_unknown"]==Json(true) && !body.released && e.fake.entities.empty(),"unknown park retains explicit ownership debt");
                bounded_ticks(h,e,10); check(h.run_console("bike-stop") && h.run_console("bike-spawn"),"retry remains inert");
                check(e.fake.body_release_calls==1 && e.fake.body_creates==1,"unknown cleanup cannot silently retry or rearm");
            } else if (scenario==8) {
                h.apply({}); check(body.released && e.fake.body_release_calls==1 && e.fake.entities.empty(),"active unload requests release exactly once before VM cleanup");
            } else if (scenario==9) {
                bounded_ticks(h,e,8); check(state(h,e)["phase"]==Json("closed") && body.released,"stalled native observation stops before 5 second watchdog");
            }
        }
        no_driving(e); ++scenarios;
    }
    for (unsigned scenario=0;scenario<7;++scenario) {
        const auto id="bike-spawn-bounded-preflight-"+std::to_string(scenario);
        TestEnvironment e;assets(e);
        const auto frame=std::string(world::blueprints[0]);
        if (scenario==0) e.fake.test_entity_boxes[frame]={Vec3{1,0,0},Vec3{0,1,1}};
        if (scenario==1) e.fake.test_entity_boxes[frame]={Vec3{},Vec3{}};
        if (scenario==2) e.fake.test_entity_boxes[frame]={Vec3{std::numeric_limits<float>::infinity(),0,0},Vec3{1,1,1}};
        if (scenario==3) e.fake.test_entity_boxes.erase(std::string(world::blueprints[7]));
        if (scenario==4) e.fake.test_entity_boxes.erase(frame);
        if (scenario==5) e.fake.test_body_create_refusal="body_preallocation_unavailable";
        Host h(e,Side::client);h.apply({package(id,files)});running(h,id,e);
        check(h.run_console("bike-spawn"),"bounded preflight Arm");
        if (scenario<=2) {
            bounded_ticks(h,e,1);
            check(state(h,e)["phase"]==Json("closed") && e.fake.test_bounds_lookups==1 &&
                !e.fake.body_creates && e.fake.entities.empty(),"malformed non-wheel bounds refuse before visuals/body");
        } else if (scenario==3) {
            bounded_ticks(h,e,303);
            check(state(h,e)["phase"]==Json("closed") && !e.fake.body_creates && e.fake.entities.empty(),
                "last missing part shares the one total preflight deadline");
            for (unsigned part=0;part<7;++part)
                check(std::count(e.fake.test_bounds_names.begin(),e.fake.test_bounds_names.end(),world::blueprints[part])==1,
                    "qualified earlier parts are not repeatedly queried");
        } else if (scenario==4) {
            bounded_ticks(h,e,295);
            const auto radius=static_cast<float>(dingosdk::bmx::geometry::wheel_radius);
            e.fake.test_entity_boxes[frame]={Vec3{-.2f,-radius,-radius},Vec3{.2f,radius,radius}};
            bounded_ticks(h,e,10);
            check(state(h,e)["phase"]==Json("closed") && !e.fake.body_creates && e.fake.entities.empty(),
                "late first mesh cannot reset or extend the five-second deadline for remaining parts");
        } else if (scenario==5) {
            bounded_ticks(h,e,9);
            check(state(h,e)["phase"]==Json("clock_prepared") && e.fake.test_bounds_lookups==8,
                "first preallocation refusal completed eight exact part probes");
            e.fake.test_body_create_refusal.clear();e.fake.test_entity_boxes.erase(frame);
            check(h.run_console("bike-clock-retry"),"separate explicit readiness retry");
            bounded_ticks(h,e,303);
            check(state(h,e)["phase"]==Json("closed") && state(h,e)["creation_attempts"]==Json(1) &&
                !e.fake.body_creates && e.fake.entities.empty() && e.fake.test_bounds_names.at(8)==frame,
                "explicit retry must requalify from first mesh and cannot reuse the prior preflight");
        } else {
            bounded_ticks(h,e,4);const auto probes=e.fake.test_bounds_lookups;
            e.fake.focus_now.focused=false;bounded_ticks(h,e,1);
            check(state(h,e)["phase"]==Json("closed") && e.fake.test_bounds_lookups==probes &&
                !e.fake.body_creates && e.fake.entities.empty(),"focus loss stops a partial preflight before another lookup");
        }
        no_driving(e);++scenarios;
    }
    {
        auto actual=files;
        actual[manifest_file]=contents(root/"bike-spawn-trial"/manifest_file);
        actual["plugin/main.lua"]=contents(root/"bike-spawn-trial/plugin/main.lua");
        TestEnvironment e;assets(e);e.fake.test_body_create_refusal="constructed opaque creation refusal";
        Host h(e,Side::client);h.apply({package("bike-spawn-refusal-journal",actual)});
        e.panels_open=true;e.shown="bike-spawn-refusal-journal";e.fake.focus_now.interface_open=true;
        e.actions={plugin_ui::Action{"bike-spawn-refusal-journal","Lua Bike Spawn Trial","spawn",false}};
        bounded_ticks(h,e,1);e.panels_open=false;e.fake.focus_now.interface_open=false;
        bounded_ticks(h,e,9);running(h,"bike-spawn-refusal-journal",e);h.apply({});
        const auto ledger=Json::parse(contents(e.storage_root()/"bike-spawn-refusal-journal/storage.json"));
        const auto& observed=ledger["lua_bike_api_create_result_v4"];
        check(observed["pcall_ok"]==Json(true) && observed["arity"]==Json(2) &&
            observed["value_type"]==Json("nil") && observed["first_is_nil"]==Json(true) &&
            observed["body_returned"]==Json(false) && observed["reason"]==Json("constructed opaque creation refusal"),
            "actual returned refusal is retained independently of later removal markers");
        check(ledger["lua_bike_api_marker_v3"]["operation"]==Json("remove") &&
            ledger["lua_bike_spawn_v1"]["cleanup_unknown"]==Json(true) &&
            !ledger.contains("lua_bike_api_release_result_v4") && !e.fake.body_creates && e.fake.entities.empty(),
            "unknown creation refusal cannot become known preallocation, a body or an invented release");
        no_driving(e);++scenarios;
    }
    // Compare the Lua port with the existing authored transform mathematics.
    // The oracle is source-only C++; no legacy controller or native writer runs.
    Json references=Json::array();
    for (unsigned test=0;test<8;++test) {
        dingosdk::bmx::visual::Frame frame;
        const auto angle=static_cast<float>(test)*.17f;
        frame.position={test%2 ? 1000.f : 0.f,2.f,-3.f};
        frame.chassis_quaternion_available=true;
        frame.chassis_quaternion={.2f*std::sin(angle),.4f*std::sin(angle),.894427191f*std::sin(angle),std::cos(angle)};
        frame.steer=angle; frame.front_wheel_phase=-angle*2; frame.rear_wheel_phase=angle*3;
        frame.crank_phase=angle*4; frame.barspin=-angle; frame.tailwhip=angle*.5f;
        frame.movement_bike_pitch=angle*.3f; frame.movement_bike_roll=-angle*.7f;
        // The C++ reference turns only the handlebars by the barspin angle. The Lua turns the whole
        // front end (fork, front wheel and bars) as a real barspin does (9dc29d7c), which is the
        // reference with the barspin added to the steering and none left for the bars alone.
        auto reference=frame; reference.steer=frame.steer+frame.barspin; reference.barspin=0;
        std::array<world::Matrix,world::part_count> expected;
        check(world::transforms(reference,expected),"authored reference math accepts fixture");
        auto row=Json::object(); row["root"]=frame.position;row["q"]=frame.chassis_quaternion;row["expected"]=expected;
        row["capsules"]=Json::array();
        for (const auto& capsule : dingosdk::bmx::collision_envelope::capsules) {
            auto a=capsule.a,b=capsule.b;
            for (unsigned axis=0;axis<3;++axis) { a[axis]-=dingosdk::bmx::geometry::com_from_root[axis];b[axis]-=dingosdk::bmx::geometry::com_from_root[axis]; }
            row["capsules"].push_back(Json{{"a",a},{"b",b},{"radius",capsule.radius}});
        }
        row["pose"]={{"steer",frame.steer},{"front_wheel_phase",frame.front_wheel_phase},{"rear_wheel_phase",frame.rear_wheel_phase},
            {"crank_phase",frame.crank_phase},{"barspin",frame.barspin},{"tailwhip",frame.tailwhip},
            {"movement_bike_pitch",frame.movement_bike_pitch},{"movement_bike_roll",frame.movement_bike_roll}};
        references.push_back(row);
    }
    auto math_files=files;
    math_files[manifest_file]=manifest();
    math_files["plugin/main.lua"]="local refs=reskate.json.decode([==["+references.dump()+"]==])\n"+R"(
        local V=require("./bike_visual") local G=require("./bike_geometry")
        local checks=0
        for _,r in refs do
            local actual=assert(V.matrices(r.root,r.q,r.pose))
            for part=1,8 do for slot=1,16 do
                assert(math.abs(actual[part][slot]-r.expected[part][slot])<.0002,"authored transform mismatch "..part..":"..slot)
                checks+=1
            end end
            local d=assert(V.definition(r.root,r.q))
            local measured=assert(V.from_sample({position=d.position,rotation=d.rotation},r.pose))
            for part=1,8 do for slot=1,16 do assert(math.abs(actual[part][slot]-measured[part][slot])<.0002) checks+=1 end end
            assert(#d.capsules==8 and d.mass==106 and d.inertia.x==26)
            for i,c in d.capsules do
                local expected=r.capsules[i]
                assert(math.abs(c.radius-expected.radius)<.000001)
                for axis,name in {"x","y","z"} do
                    assert(math.abs(c.a[name]-expected.a[axis])<.000001 and math.abs(c.b[name]-expected.b[axis])<.000001)
                end
            end
        end
        assert(V.matrices({0,0,0},{0,0,0,0})==nil)
        assert(V.matrices({0/0,0,0},{0,0,0,1})==nil)
        local bad=V.neutral() bad.tailwhip=0/0
        assert(V.matrices({0,0,0},{0,0,0,1},bad)==nil)
        assert(checks==2048) reskate.log("bike visual 2048 authored/COM comparisons")
    )";
    TestEnvironment math_environment; Host math_host(math_environment,Side::client);
    math_host.apply({package("bike-visual-math",math_files)});running(math_host,"bike-visual-math",math_environment);
    check(math_environment.logged("bike visual 2048 authored/COM comparisons"),"authored transform tests finish: "+math_environment.all());
    no_driving(math_environment);
    std::cout<<"Lua bike spawn: "<<scenarios<<" Host scenarios, 2048 authored/COM comparisons, 0 driving calls; native Game facts constructed\n";
}

#include "measured_contact_host_fixture.inc"
#include "motion_refresh_host_fixture.inc"
#include "body_reactivation_probe_host_fixture.inc"
#include "body_reactivation_post_follow_host_fixture.inc"
#include "body_prepare_host_fixture.inc"
#include "hop_inert_host_fixture.inc"
#include "body_follow_host_fixture.inc"
#include "body_follow_motion_policy_host_fixture.inc"
#include "body_follow_renew_host_fixture.inc"
#include "body_follow_lead_host_fixture.inc"
#include "body_command_cleanup_host_fixture.inc"
#include "shape_categories_host_fixture.inc"
#include "exclusion_facts_host_fixture.inc"

int main() {
    unsigned skipped = 0;
    const auto run = [&](void (*test)()) {
        try {
            test();
        } catch (const Absent& absent) {
            ++skipped;
            std::cout << "skipped: contrib/plugins/" << absent.id << " is not on this machine\n";
        }
    };
    try {
        scratch = std::filesystem::temp_directory_path() / "reskate-plugin-tests";
        std::filesystem::remove_all(scratch);
        run(a_manifest_says_what_a_plugin_is);
        run(measured_contact_host_fixture_v1);
        run(plugins_own_typed_bodies_and_acknowledge_measured_results);
        run(plugins_pipeline_native_steps_and_select_owned_receipts);
        run(plugins_can_inspect_later_partial_failure_without_acknowledging_unmeasured_head);
        run(owned_body_refusal_tokens_keep_return_shapes_and_no_command);
        run(native_body_permission_and_client_boundary_are_enforced);
        run(sync_probe_observations_are_opaque_bounded_and_copied);
        run(sync_probe_permissions_client_phase_and_transport_are_enforced);
        run(sync_probe_binding_rejects_malformed_backend_facts);
        run(sync_probe_terminal_partial_facts_and_body_release_remain_distinct);
        run(motion_refresh_host_fixture_v1);
        run(body_reactivation_probe_host_fixture_v1);
        run(body_reactivation_post_follow_host_fixture_v1);
        run(the_tracked_body_reactivation_harness_stays_inert_until_visual_approval);
        run(body_prepare_host_fixture_v1);
        run(body_follow_host_fixture_v1);
        run(body_follow_motion_policy_host_fixture_v1);
        run(body_follow_renew_host_fixture_v1);
        run(body_follow_lead_host_fixture_v1);
        run(body_command_cleanup_host_fixture_v1);
        run(the_tracked_passive_sync_trial_runs_once_and_keeps_observation_separate);
        run(the_tracked_passive_sync_routes_trial_copies_validated_route_counts);
        run(native_actions_keep_opaque_requests_and_observed_receipts_distinct);
        run(native_actions_check_permission_side_cancellation_and_rate);
        run(native_action_quarantine_remains_visible_until_safe_acknowledgement);
        run(native_recovery_receipts_separate_pulse_cleanup_and_stability);
        run(native_recovery_enforces_permission_phase_arguments_and_shared_request_rate);
        run(native_recovery_keeps_unresolved_cleanup_quarantined_on_unload);
        run(input_trace_api_keeps_bounded_observations_opaque_and_vm_owned);
        run(input_trace_api_requires_permission_client_phase_and_start_budget);
        run(input_pulse_api_keeps_report_receipts_opaque_and_owner_bound);
        run(input_pulse_api_enforces_permission_client_phase_and_shared_budget);
        run(input_pulse_unload_retains_debt_before_other_actor_cleanup);
        run(input_lease_api_observes_only_qualified_owner_scoped_streams);
        run(input_lease_capture_api_keeps_publication_duty_owner_scoped);
        run(the_tracked_input_pulse_fixture_loads_and_ticks_inert);
        run(the_tracked_input_pulse_fixture_bounds_and_separates_active_observations);
        run(the_private_input_trace_fixture_loads_inert_when_present);
        run(the_private_native_recovery_fixture_loads_inert_when_present);
        run(the_sealed_private_hop_fixture_loads_inert_when_selected);
        run(owned_body_batches_are_permissioned_opaque_and_transactional);
        run(body_contact_details_are_known_and_epoch_bound);
        run(owned_body_batches_select_a_named_query_preset);
        run(shape_categories_host_fixture_v1);
        run(exclusion_facts_host_fixture_v1);
        run(owned_body_batches_share_actual_and_logical_query_limits);
        run(effects_require_resident_roots);
        run(expired_effects_return_their_quota);
        run(plugins_render_private_effects);
        run(failed_plugin_startup_releases_effects);
        run(plugins_track_effect_lifetimes);
        run(physics_steps_include_optional_geometry);
        run(a_plugin_loads_ticks_runs_its_commands_and_unloads);
        run(a_permission_must_be_declared);
        run(command_names_are_checked);
        run(storage_is_kept_across_loads_and_has_a_quota);
        run(packages_json_and_modules);
        run(the_sandbox_holds);
        run(a_runaway_plugin_is_stopped_and_the_rest_go_on);
        run(a_plugin_over_its_time_budget_is_stopped);
        run(the_plugin_time_budget_setting_parses);
        run(the_chosen_budget_reaches_every_plugin);
        run(a_plugin_over_the_chosen_budget_is_stopped_and_one_under_it_is_not);
        run(a_plugin_reloads_when_its_files_change);
        run(the_skater_can_be_read_moved_and_the_world_probed);
        run(plugins_distinguish_clear_unavailable_and_hit_world_probes);
        run(tricks_reach_plugins_that_ask_for_them);
        run(plugins_draw_on_the_overlay);
        run(plugins_draw_pictures);
        run(plugins_place_world_entities);
        run(plugins_have_what_a_prop_hunt_needs);
        run(plugins_reach_cruise_and_read_the_mouse);
        run(plugins_carry_and_take_a_step_in_the_camera_cycle);
        run(plugins_read_joints_and_tune_physics);
        run(plugins_type_and_use_the_room);
        run(plugins_touch_hide_and_ray_at_players);
        run(plugins_use_the_games_clips);
        run(plugins_edit_clips);
        run(animator_studio_records_and_saves);
        run(plugins_server_copies_are_the_authority);
        run(plugins_server_copies_spawn_park_mods);
        run(plugins_server_copies_hide_players);
        run(plugins_server_copies_see_roles);
        run(plugins_server_copies_show_cards_and_polls);
        run(plugins_animate_the_skater);
        run(plugins_play_their_own_sounds);
        run(plugins_have_menu_panels);
        run(camera_inspector_prepares_then_explicitly_requests_a_view);
        run(bmx_lua_spawn_uses_owned_chassis_and_measured_part_placement);
        run(bmx_lua_policy_runs_as_modules_and_the_inspector_starts_inert);
        run(bmx_lua_public_bike_facade_denies_mount_before_service_access);
        run(bmx_lua_first_ride_imports_stay_inert);
        run(bmx_lua_equipment_requests_match_the_retained_gesture_rules);
        run(bmx_lua_equipment_transitions_keep_cleanup_and_target_observation_separate);
        run(bmx_lua_equipment_runtime_uses_typed_services_without_native_permissions);
        run(bmx_lua_persistence_keeps_terminal_records_and_public_fault_gates);
        run(equipment_interruption_fixture_keeps_effects_one_shot);
        run(bmx_lua_menu_switches_explicit_slots_and_retains_cleanup_duty);
        run(bmx_lua_menu_returns_to_board_without_inverting_the_target);
        run(bmx_lua_recovery_policy_keeps_native_cleanup_separate);
        run(bmx_lua_trick_policy_uses_actual_package_modules);
        run(bmx_lua_forces_use_actual_modules_and_match_the_portable_kernel);
        run(bmx_lua_contacts_use_actual_decoder_and_force_modules);
        run(plugins_have_pages);
        run(plugins_play_sounds_and_read_the_mods);
        run(plugins_follow_the_session_and_message_each_other);
        run(plugins_call_and_hear_each_other);
        run(web_requests_go_only_to_listed_domains);
        run(game_menu_distinguishes_unknown_from_closed);
        run(the_wider_set_reaches_the_game);
        run(declared_board_colours_through_the_api);
        run(key_names_become_binds);
        run(level_events_reach_plugins);
        run(timers_run_when_due);
        run(a_package_with_a_program_or_on_the_wrong_side_is_not_loaded);
        run(discovery_finds_the_plugins_among_the_mods_left_on);
        run(blood_renders_an_impact_through_the_host);
        run(reskate_test_passes_its_own_checks);
        run(road_rash_marks_the_skater_as_it_bails);
        run(dual_stick_edits_the_companions_settings);
        run(rock_to_fakie_relabels_and_records_the_stall);
        run(a_plugin_reads_the_content_folder_it_names);
        run(content_is_read_from_the_mod_folders);
        run(board_break_snaps_the_board_on_a_slam);
        run(fpv_drone_flies_and_follows);
        run(hall_of_meat_scores_a_bail);
        run(grind_exits_pick_the_side);
        run(smokey_throwdowns_register_and_play_one_up);
        run(filmer_follows_and_films);
        run(plugins_drive_the_throwdown_kit);
        run(fit_check_turns_the_board_and_saves_it);
        run(item_tabs_keep_tabs_and_wear_on_top);
        run(the_throwdowns_page_lists_the_stock_cards_and_plugin_modes);
        run(plugins_add_throwdown_modes);
        run(reskate_hostile_is_stopped_or_refused_every_time);
        std::filesystem::remove_all(scratch);
        std::cout << "plugin tests passed" << (skipped ? " (" + std::to_string(skipped) + " skipped)" : std::string()) << "\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "plugin test failed: " << error.what() << '\n';
        return 1;
    }
}
