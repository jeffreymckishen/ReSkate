// The plugin host apart from the game: manifests, the reskate API, storage, modules, hot reload,
// and the sandbox against plugins written to break it (loops, memory, error floods, escapes).
#include "Extension/Plugins/plugin_discovery.h"
#include "Extension/Plugins/plugin_host.h"
#include "Extension/Plugins/plugin_manifest.h"
#include "Extension/Plugins/plugin_session_feed.h"
#include "Extension/Plugins/plugin_wire.h"
#include "Extension/Throwdowns/challenge_registry.h"
#include "Extension/Throwdowns/custom_modes.h"
#include "Extension/Throwdowns/throwdown_kit.h"
#include "Engine/Vfs/mod_list.h"
#include "Engine/Game/BMX/bmx_chassis_control.h"
#include "Engine/Game/BMX/bmx_interaction.h"
#include "Engine/Game/BMX/equipment_switch.h"
#include <algorithm>
#include <chrono>
#include <format>
#include <fstream>
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
namespace {
void check(bool value, const std::string& message) { if (!value) throw std::runtime_error(message); }

std::filesystem::path scratch;


// The wider set's game, faked: it records what plugins asked of it and answers as told.
struct FakeGame final : Game {
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
    unsigned body_creates{}, body_submissions{};
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
        if (!owned_body::valid(definition) || owned.size() >= owned_body::retained_capacity) return "definition or capacity";
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
        auto* b = body_of(owner, h); if (!b || b->released || b->quarantined) return "owner or generation";
        b->latest = b->sample; (void)b->mailbox.observe_successor(b->sample); sample = b->sample; return {};
    }
    std::string body_submit(std::uint64_t owner, const owned_body::Handle& h, const owned_body::Command& command, std::uint64_t& sequence) override {
        sequence = 0;
        auto* b = body_of(owner, h);
        if (!b || b->released || body_command_sequence == std::numeric_limits<std::uint64_t>::max() ||
            !b->mailbox.submit(command, b->sample.epoch, 0, body_command_sequence + 1)) return "owner, generation or packet";
        sequence = ++body_command_sequence; ++body_submissions; return {};
    }
    body_query::Result body_probe_batch(std::uint64_t owner, const owned_body::Handle& h, const body_query::Request& request, unsigned allowed) override {
        ++batch_calls; last_batch = request;
        if (batch_refusal != body_query::Failure::none) {
            body_query::Result out; out.count = request.count; out.failure = batch_refusal;
            out.native_casts = batch_refusal_casts; out.accounting_valid = batch_refusal_accounting_valid;
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
        return body_query::execute(request, allowed, 1000, [&](const body_query::Ray& ray, unsigned permitted) {
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
            return out;
        }, fence);
    }
    std::string body_receipt(std::uint64_t owner, const owned_body::Handle& h, std::uint64_t selected, owned_body::Receipt& receipt) override {
        auto* b = body_of(owner, h); if (!b) return "owner or generation";
        if (!b->released && !b->quarantined && b->mailbox.needs_successor()) {
            b->latest = b->sample; (void)b->mailbox.observe_successor(b->sample);
        }
        if (!b->mailbox.find(selected, receipt)) return "receipt sequence unavailable";
        receipt.retained = b->released; receipt.quarantined = b->quarantined; return {};
    }
    std::string body_acknowledge(std::uint64_t owner, const owned_body::Handle& h, std::uint64_t sequence) override {
        auto* b = body_of(owner, h); return b && b->mailbox.acknowledge(sequence) ? std::string{} : "not ready to acknowledge";
    }
    std::string body_release(std::uint64_t owner, const owned_body::Handle& h) override {
        auto* b = body_of(owner, h); if (!b) return "owner or generation";
        b->released = true; b->mailbox.cancel(); return {};
    }
    void body_release_all(std::uint64_t owner) override {
        release_order.emplace_back(owner, "body");
        body_releases.push_back(owner);
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
    std::optional<std::vector<BoardParameter>> board_parameters(int part) override {
        if (part != 1) return std::vector<BoardParameter>{};
        return std::vector<BoardParameter>{{0x873f48af36e50d59ULL, "colour", {.2f, .3f, .4f}, 0},
                                           {0x841c7d74837f1d39ULL, "number", {1, 0, 0}, 0},
                                           {0xb00abec403499469ULL, "integer", {}, 13},
                                           {0xa5f9a6b8098279adULL, "switch", {}, 1}};
    }
    std::string board_set_parameter(std::string_view plugin, int part, std::uint64_t key, std::array<float, 3> value, bool colour) override {
        calls.push_back(std::format("board parameter {} {} {:016x} {} {:.1f}", plugin, part, key, colour ? "colour" : "number", value[0]));
        return {};
    }
    void board_clear_parameter(std::string_view plugin, int part, std::optional<std::uint64_t> key) override {
        calls.push_back(std::format("board parameter clear {} {} {}", plugin, part, key ? std::format("{:016x}", *key) : "all"));
    }
    // The general services a game layer in Lua reads and drives (plugin_api_services.cpp).
    std::optional<SkaterTelemetry> telemetry;
    std::optional<SkaterTelemetry> skater_telemetry(std::string_view) override { return telemetry; }
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
        for (const auto& o : sorted) text += std::format(" {}:{:.2f},{:.2f},{:.2f},{:.2f}x{:.2f}", o.joint, o.rotation[0], o.rotation[1], o.rotation[2], o.rotation[3], o.scale);
        calls.push_back(text);
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
    std::string entity_set(std::string_view plugin, std::uint32_t id, std::string_view asset, const std::array<float, 16>& m, bool hidden,
                           std::optional<EntityAttach> attach, bool solid) override {
        if (entities.size() >= 600) return "too many";
        entities[{std::string(plugin), id}] = {std::string(asset) + (hidden ? " hidden" : ""), m};
        calls.push_back(std::format("entity {} {} {} {:.2f} {:.2f} {:.2f} {:.2f}{}{}", plugin, id, asset, m[12], m[13], m[14], m[8], hidden ? " hidden" : "",
                                    attach ? std::format(" on {} {}{}{}{}", attach->player, attach->joint, attach->upright ? " upright" : "", attach->turn ? "" : " held",
                                                     attach->ground > 0 ? std::format(" ground {:.1f}", attach->ground) : std::string{}) : std::string{}) +
                        (solid ? "" : " ghost"));
        return {};
    }
    void entity_remove(std::string_view plugin, std::uint32_t id) override { entities.erase({std::string(plugin), id}); }
    std::optional<std::array<Vec3, 2>> entity_bounds(std::string_view blueprint) override {
        if (blueprint != "World/Props/TrashCan_01") return std::nullopt;
        return std::array<Vec3, 2>{Vec3{-0.3f, 0, -0.3f}, Vec3{0.3f, 0.9f, 0.3f}};
    }
    std::vector<std::string> entity_blueprints(std::string_view prefix, bool meshes_only) override {
        std::vector<std::string> out;
        for (const auto* name : {"World/Props/Bench_01", "World/Props/TrashCan_01", "World/Vehicles/Car_01"})
            if (std::string_view(name).starts_with(prefix) && (!meshes_only || entity_bounds(name))) out.emplace_back(name);
        return out;
    }
    WorldProbe probe_result;
    unsigned probes{}, world_picks{};
    Vec3 probe_from{}, probe_to{};
    WorldProbe world_probe(const Vec3& from, const Vec3& to) override {
        ++probes;
        probe_from = from;
        probe_to = to;
        return probe_result;
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
    InputFocus focus_now{};
    std::optional<std::uint32_t> pad_bits(bool) override { return pad_bits_now; }
    InputFocus input_focus() override { return focus_now; }
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
    std::vector<ServerPark> server_parks() override { return {{"street", "San Vansterdam", true, true, 12, 5}, {"plaza", "Isle of Grom", false, false, 0, 0}}; }
    std::string spawn_park(std::string_view plugin, std::string_view name, unsigned minutes) override {
        calls.push_back(std::format("park spawn {} {} {}", plugin, name, minutes));
        return name == "plaza" ? "plaza belongs on Isle of Grom, and the server is on San Vansterdam." : std::string{};
    }
    std::string remove_park(std::string_view plugin, std::string_view name) override {
        calls.push_back(std::format("park remove {} {}", plugin, name));
        return {};
    }
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
    void release(std::string_view plugin) override { released.emplace_back(plugin); entity_clear(plugin); }
    // The game menu, its item grid, what is worn, and a screen capture of something turning once
    // every `turning` frames (reskate.capture, room.turn, menu.game/grid, outfit.board).
    GameMenu menu_now;
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
    GameMenu game_menu() override { return menu_now; }
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
    void game_keys(std::string_view, std::vector<std::uint8_t> keys) override { kept_keys = std::move(keys); }
    void game_buttons(std::string_view, std::uint16_t hidden, std::uint16_t, bool) override { kept_buttons = hidden; }
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
    std::optional<SkaterState> skater() override { return local_skater; }
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
    check(environment.fake.body_creates == 0 && environment.fake.body_submissions == 0, "missing permission reached Game");
    TestEnvironment server_environment; Host server(server_environment, Side::server);
    auto server_plugin = package("server-body", {{manifest_file, manifest(R"("world.physics","world.raycast")", "server")}, {"plugin/main.lua", R"(
        local ok,why=pcall(reskate.world.physics.create,{})
        assert(not ok and string.find(why,"client phase only"))
        ok,why=pcall(reskate.world.physics.probe_batch,{},{},{})
        assert(not ok and string.find(why,"client phase only"))
    )"}});
    server.apply({server_plugin}); running(server, "server-body", server_environment);
    check(server_environment.fake.body_creates == 0, "server reached native body creation");
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
void owned_body_batches_are_permissioned_opaque_and_transactional() {
    TestEnvironment environment; Host host(environment, Side::client);
    host.apply({script("batch-no-ray", R"(
        local ok,why=pcall(reskate.world.physics.probe_batch,{},{},{})
        assert(not ok and why:find("world.raycast"))
    )", R"("world.physics")"), script("batch-no-body", R"(
        local ok,why=pcall(reskate.world.physics.probe_batch,{},{},{})
        assert(not ok and why:find("world.physics"))
    )", R"("world.raycast")"), script("body-batch", batch_main(R"(
        local out=P.probe_batch(h,epoch,rays(2),{exclude_bodies={other,h},exclude_local_actor=true})
        assert(out.status=="available" and out.native_casts==2 and #out.rays==2 and not out.reason)
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
    check(environment.logged("at 1.0 0.0 2.0 facing 1.50 speed 4.0 up 0.5 air true 0.2"), "The skater is read\n" + environment.all());
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
            assert(d:size().x == 1920 and d:size().y == 1080)
            assert(not pcall(d.text, d, vector.create(0, 0, 0), "x", {colour = "red"}), "a colour by name")
            assert(not pcall(d.text, d, vector.create(0 / 0, 0, 0), "x"), "NaN")
            assert(not pcall(d.poly, d, {vector.create(0, 0, 0)}), "a polygon of one point")
            assert(not pcall(d.text, d, vector.create(0, 0, 0), string.rep("x", 600)), "a long text")
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

void bmx_lua_policy_runs_as_modules_and_the_inspector_starts_inert() {
    const auto directory = std::filesystem::path(RESKATE_SOURCE_DIR) / "contrib" / "bmx-lab" / "bmx-plugin";
    const auto contents = [](const std::filesystem::path& path) {
        std::ifstream file(path, std::ios::binary);
        check(file.good(), "BMX Lua source is available: " + path.string());
        return std::string(std::istreambuf_iterator<char>(file), {});
    };
    const auto declaration = contents(directory / manifest_file);
    check(parse_manifest(declaration).permissions == std::set<std::string, std::less<>>{"input", "menu"} && check_package_files(directory).empty(),
          "BMX Lua is an input/menu-only source package, without native control permissions");
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({{"bmx-lua-inspector", directory, "1", {}}});
    ticks(host, environment, 3);
    running(host, "bmx-lua-inspector", environment);
    environment.panels_open = true;
    ticks(host, environment, 10);
    running(host, "bmx-lua-inspector", environment);
    check(environment.panels.size() == 1 && environment.panels[0].title == "BMX Lua migration" && environment.fake.calls.empty() &&
              environment.fake.binds.empty() && environment.teleports.empty() && environment.rays == 0,
          "The actual inspector loads, ticks and builds its page without acquiring input/camera/pose or invoking gameplay");
    std::map<std::string, std::string> files{{manifest_file, declaration}};
    for (const auto* name : {"input.lua", "catalog.lua", "tests.lua"}) files[std::string("plugin/") + name] = contents(directory / "plugin" / name);
    files["plugin/main.lua"] = R"(
        local result = require("./tests").run()
        assert(result.cases == 12 and result.assertions == 1216 and result.native_actions == 0,
            string.format("unexpected Lua coverage: %s/%s", tostring(result.cases), tostring(result.assertions)))
        local pad, focus = reskate.input.gamepad(), reskate.input.focus()
        assert(type(pad.left_x) == "number" and type(pad.right_y) == "number" and pad.left_trigger > 0 and pad.right_trigger > 0)
        assert(pad.buttons.a and pad.buttons.b and pad.buttons.y and pad.buttons.right_stick and pad.buttons.lb and pad.buttons.rb)
        assert(focus.focused and not focus.interface_open and focus.gameplay)
        reskate.log("BMX Lua: 12 cases, 1216 assertions, 0 native actions")
    )";
    TestEnvironment portable;
    portable.fake.pad = PadInput{0.25f, 0, 0, -1, 0.3f, 0.9f, 0xb380, false};
    portable.fake.focus_now = {true, false, true};
    Host unit(portable, Side::client);
    unit.apply({package("bmx-lua-policy-tests", files)});
    running(unit, "bmx-lua-policy-tests", portable);
    check(portable.logged("BMX Lua: 12 cases, 1216 assertions, 0 native actions") && portable.fake.calls.empty(),
          "Actual package modules run through the vendored Luau Host with expected coverage and actual input API fields\n" + portable.all());
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
    files["plugin/main.lua"] = "local reference = reskate.json.decode([=[" + reference.dump() + R"(]=])
        local result = require("./equipment_tests").run(reference)
        assert(result.cases == 8 and result.assertions > 1000 and result.comparisons == 160 and result.native_actions == 0,
            string.format("unexpected equipment coverage: %s/%s/%s", tostring(result.cases), tostring(result.assertions), tostring(result.comparisons)))
        reskate.log(string.format("BMX Lua equipment: %d cases, %d assertions, %d C++ comparisons, 0 native actions", result.cases, result.assertions, result.comparisons))
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-equipment-tests", files)});
    running(host, "bmx-lua-equipment-tests", environment);
    check(environment.logged("BMX Lua equipment: 8 cases") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
              environment.fake.body_creates == 0 && environment.fake.body_submissions == 0 && environment.teleports.empty() && environment.rays == 0,
          "Actual equipment modules agree with retained gesture rules without native services or gameplay permissions\n" + environment.all());
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
        local result = require("./trick_tests").run()
        assert(result.cases == 16 and result.assertions > 300 and result.native_actions == 0,
            string.format("unexpected trick coverage: %s/%s", tostring(result.cases), tostring(result.assertions)))
        reskate.log(string.format("BMX Lua tricks: %d cases, %d assertions, 0 native actions", result.cases, result.assertions))
    )";
    TestEnvironment environment;
    Host host(environment, Side::client);
    host.apply({package("bmx-lua-trick-tests", files)});
    running(host, "bmx-lua-trick-tests", environment);
    check(environment.logged("BMX Lua tricks: 16 cases") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
              environment.teleports.empty() && environment.rays == 0,
          "Actual Lua trick modules run without native services or gameplay permissions\n" + environment.all());
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
        assert(result.cases == 17 and result.assertions > 1800 and result.comparisons == 83 and result.projections == 18 and result.native_actions == 0,
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
    check(environment.logged("BMX Lua forces: 17 cases") && environment.fake.calls.empty() && environment.fake.binds.empty() &&
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
        if reskate.side == "server" then
            reskate.on("message", function(from, text)
                reskate.log("server heard " .. text .. " from " .. from.name)
                assert(reskate.net.send("all", "state " .. text))
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
        run(plugins_own_typed_bodies_and_acknowledge_measured_results);
        run(plugins_pipeline_native_steps_and_select_owned_receipts);
        run(plugins_can_inspect_later_partial_failure_without_acknowledging_unmeasured_head);
        run(native_body_permission_and_client_boundary_are_enforced);
        run(native_actions_keep_opaque_requests_and_observed_receipts_distinct);
        run(native_actions_check_permission_side_cancellation_and_rate);
        run(native_action_quarantine_remains_visible_until_safe_acknowledgement);
        run(native_recovery_receipts_separate_pulse_cleanup_and_stability);
        run(native_recovery_enforces_permission_phase_arguments_and_shared_request_rate);
        run(native_recovery_keeps_unresolved_cleanup_quarantined_on_unload);
        run(the_private_native_recovery_fixture_loads_inert_when_present);
        run(owned_body_batches_are_permissioned_opaque_and_transactional);
        run(owned_body_batches_share_actual_and_logical_query_limits);
        run(a_plugin_loads_ticks_runs_its_commands_and_unloads);
        run(a_permission_must_be_declared);
        run(command_names_are_checked);
        run(storage_is_kept_across_loads_and_has_a_quota);
        run(packages_json_and_modules);
        run(the_sandbox_holds);
        run(a_runaway_plugin_is_stopped_and_the_rest_go_on);
        run(a_plugin_over_its_time_budget_is_stopped);
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
        run(plugins_animate_the_skater);
        run(plugins_play_their_own_sounds);
        run(plugins_have_menu_panels);
        run(camera_inspector_prepares_then_explicitly_requests_a_view);
        run(bmx_lua_policy_runs_as_modules_and_the_inspector_starts_inert);
        run(bmx_lua_equipment_requests_match_the_retained_gesture_rules);
        run(bmx_lua_trick_policy_uses_actual_package_modules);
        run(bmx_lua_forces_use_actual_modules_and_match_the_portable_kernel);
        run(plugins_have_pages);
        run(plugins_play_sounds_and_read_the_mods);
        run(plugins_follow_the_session_and_message_each_other);
        run(plugins_call_and_hear_each_other);
        run(web_requests_go_only_to_listed_domains);
        run(the_wider_set_reaches_the_game);
        run(key_names_become_binds);
        run(level_events_reach_plugins);
        run(timers_run_when_due);
        run(a_package_with_a_program_or_on_the_wrong_side_is_not_loaded);
        run(discovery_finds_the_plugins_among_the_mods_left_on);
        run(reskate_test_passes_its_own_checks);
        run(road_rash_marks_the_skater_as_it_bails);
        run(dual_stick_edits_the_companions_settings);
        run(rock_to_fakie_relabels_and_records_the_stall);
        run(a_plugin_reads_the_content_folder_it_names);
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
