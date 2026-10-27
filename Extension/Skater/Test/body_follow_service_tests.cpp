// Includes the actual Follow Service translation unit once, with a test clock.
// The binding, World and actor leaves it calls are constructed below. Where a
// leaf has to mint a credential (a measured source, a release hold, a park
// fence or receipt, a live callback entry) it is the friend the production
// header already declares, so no production header changes for this test.
// Neither native_body_follow.cpp nor owned_bodies.cpp is linked, and no game
// code runs. What executes for real: the Service's locks, phases, deadline and
// guard edges, renewal windows, lease report, dispatch commit on the raw and the
// callback-entry path, the entry's own scope check, and cleanup order.
#include <Windows.h>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <thread>
#include <utility>

namespace service_test_clock {
std::atomic<ULONGLONG> now{100000};
}
ULONGLONG WINAPI service_test_now() noexcept { return service_test_clock::now.load(); }

#include "Extension/Skater/native_body_follow_service.h"
#include "Extension/Skater/native_actions.h"
#include "Engine/Game/Skater/body_follow_transform.h"
#define GetTickCount64 service_test_now
#include "../native_body_follow_service.cpp"
#undef GetTickCount64

namespace service_test {
std::string_view current_case;
unsigned checks{};
void check(bool condition, const char* why) {
    ++checks;
    if (!condition) {
        std::cerr << "body follow service [" << current_case << "]: " << why << '\n';
        std::exit(1);
    }
}
constexpr std::uintptr_t rig = 0x7100, context = 0x7200;
constexpr std::uint64_t body_serial = 40;
// Every constructed leaf result and every count the scenarios read back.
struct Leaves {
    unsigned captures{}, reserve_bindings{}, publish_bindings{}, binding_stops{}, prepares{}, currents{}, originals{};
    unsigned proof_checks{}, holds{}, held_release_requests{}, hold_releases{}, body_releases{}, fences{}, parks{}, completions{};
    bool duties_busy{}, hold_refusal{}, publish_refusal{}, prepare_refusal{}, release_known{true};
    bool measured_target{}, current_refusal{}, seal_refusal{};
    unsigned target_measurements{}, command_seals{}, successful_seals{}, ack_handoffs{};
    dingosdk::owned_bodies::CompletedAckHandoff handoff_result{dingosdk::owned_bodies::CompletedAckHandoff::recorded};
    std::uint64_t handoff_owner{}, handoff_sequence{};
    bool handoff_after_seal{};
    dingosdk::owned_body::Sample dispatch_sample{};
    dingosdk::body_follow_native::Attachment prepared_attachment{};
    std::array<float, 16> original_value{};
    std::uint64_t hold_id{}, requested_hold{};
    dingosdk::owned_bodies::RenewalProof proof_result{dingosdk::owned_bodies::RenewalProof::current};
    std::uint64_t proof_current_serial{}; // zero reports the proof's own serial as the current step
    dingosdk::owned_body::Epoch last_proof{};
    bool proof_identity_reserved{};
    std::function<void()> during_proof, during_publish, during_prepare, during_original;
};
Leaves leaf;
// Runs a scripted interleaving once; it is removed before it runs.
void run_once(std::function<void()>& hook) {
    auto run = std::exchange(hook, {});
    if (run) run();
}
} // namespace service_test

// ---- constructed leaves ------------------------------------------------------------------------
namespace dingosdk::skater_action {
bool follow_duties_idle() noexcept { return !service_test::leaf.duties_busy; }
}
namespace dingosdk::actor_control_native {
actor_control::Snapshot follow_snapshot(std::uint64_t owner, std::uint64_t, const Actor&) noexcept {
    actor_control::Snapshot snapshot;
    snapshot.available = owner != 0; snapshot.owner = owner; snapshot.domain = actor_control::Domain::follow;
    return snapshot;
}
}
namespace dingosdk::owned_bodies {
bool capture_source(std::uint64_t owner, const owned_body::Handle& handle, MeasuredSource& out) noexcept {
    auto& leaf = service_test::leaf;
    ++leaf.captures; out = {};
    if (!owner || !handle.generation) return false;
    out.owner_ = owner; out.handle_ = handle; out.world_generation_ = 23;
    out.sample_.epoch = {23, handle.generation, service_test::body_serial, 1.0, 1.f / 60.f};
    out.sample_.mass = 12;
    out.clock_observed_ms_ = out.captured_ms_ = service_test_clock::now.load();
    out.base_ = 0x140000000; out.world_ = 0x5000; out.state_ = 0x6000;
    out.body_index_ = 3; out.body_generation_ = 7;
    return true;
}
// Only the lead scenarios use this fresh constructed measurement. Production
// World admission is not linked here, including its refusal of corrupt motion.
bool try_measure_source(std::uint64_t owner, const MeasuredSource& identity, MeasuredSource& out) noexcept {
    ++service_test::leaf.target_measurements;
    out = {};
    if (!owner || owner != identity.owner_) return false;
    out = identity;
    out.sample_ = service_test::leaf.dispatch_sample;
    return true;
}
RenewalProof check_renewal_proof(std::uint64_t owner, const MeasuredSource& identity, const owned_body::Epoch& proof,
    std::uint64_t& current_serial) noexcept {
    auto& leaf = service_test::leaf;
    ++leaf.proof_checks; current_serial = 0; leaf.last_proof = proof;
    // The Service must pass the source it reserved, never a plugin value.
    leaf.proof_identity_reserved = identity.owner_ == owner && identity.handle_.generation == 17 &&
        identity.sample_.epoch.serial == service_test::body_serial && identity.body_index_ == 3;
    service_test::run_once(leaf.during_proof);
    if (leaf.proof_result != RenewalProof::current) return leaf.proof_result;
    current_serial = leaf.proof_current_serial ? leaf.proof_current_serial : proof.serial;
    return RenewalProof::current;
}
bool acquire_release_hold(std::uint64_t owner, const MeasuredSource& source, BodyReleaseHold& out) noexcept {
    auto& leaf = service_test::leaf;
    ++leaf.holds;
    if (out.available() || !owner || owner != source.owner_ || leaf.hold_refusal) return false;
    out.owner_ = owner; out.id_ = ++leaf.hold_id; out.handle_ = source.handle_;
    return true;
}
bool release_requested(std::uint64_t owner, const BodyReleaseHold& hold, bool& out) noexcept {
    const auto& leaf = service_test::leaf;
    out = false;
    if (!owner || owner != hold.owner_ || !hold.id_ || !leaf.release_known) return false;
    out = hold.id_ == leaf.requested_hold;
    return true;
}
bool request_held_release(std::uint64_t owner, const BodyReleaseHold& hold) noexcept {
    auto& leaf = service_test::leaf;
    ++leaf.held_release_requests;
    if (!owner || owner != hold.owner_ || !hold.id_) return false;
    leaf.requested_hold = hold.id_;
    return true;
}
bool release_body_hold(std::uint64_t owner, BodyReleaseHold& hold) noexcept {
    ++service_test::leaf.hold_releases;
    if (!owner || owner != hold.owner_ || !hold.id_) return false;
    hold = {};
    return true;
}
std::string release(std::uint64_t, const owned_body::Handle&) noexcept {
    ++service_test::leaf.body_releases;
    return {};
}
bool observe_retained_park(std::uint64_t owner, const RetirementBasis&, RetainedParkReceipt& out) noexcept {
    if (!owner || out.available()) return false;
    out.parked_ms_ = out.observed_ms_ = service_test_clock::now.load();
    return true;
}
} // namespace dingosdk::owned_bodies
namespace dingosdk::body_follow_native {
using actor_control_native::Reason;
bool reserve_binding(std::uint64_t owner, std::uint64_t sequence, const owned_bodies::MeasuredSource& source,
    actor_control_native::Admission admission, Binding& out, Reason& reason) noexcept {
    ++service_test::leaf.reserve_bindings; reason = Reason::unavailable;
    if (out.reserved || out.published || out.stopped || !owner || !sequence || !admission) return false;
    out.owner = owner; out.sequence = sequence; out.source = source; out.admission = admission;
    out.actor = {}; out.actor.rig = service_test::rig; out.actor.context = service_test::context;
    out.reserved = true; reason = Reason::none;
    return true;
}
bool publish_binding(Binding& out, Reason& reason) noexcept {
    ++service_test::leaf.publish_bindings; reason = Reason::unavailable;
    service_test::run_once(service_test::leaf.during_publish);
    if (!out.reserved || out.published || out.stopped || service_test::leaf.publish_refusal) return false;
    out.published = true; reason = Reason::none;
    return true;
}
bool stop(Binding& binding) noexcept {
    ++service_test::leaf.binding_stops;
    // As the production binding: a never-published admission is abandoned; a
    // published claim is revoked and stays reserved until cleanup retires it.
    if (!binding.reserved) return false;
    binding.stopped = true;
    if (!binding.published) binding.reserved = false;
    return true;
}
bool prepare_target(const Binding& binding, std::uintptr_t target_rig, std::uintptr_t target_context,
    const std::array<float, 16>* supplied, const Attachment& attachment, PreparedTarget& out, Reason& reason,
    Diagnostic& diagnostic) noexcept {
    ++service_test::leaf.prepares; reason = Reason::unavailable; diagnostic = {};
    service_test::run_once(service_test::leaf.during_prepare);
    if (service_test::leaf.prepare_refusal || !supplied || binding.actor.rig != target_rig ||
        binding.actor.context != target_context) return false;
    out.source = binding.source; out.value = *supplied; out.owner = binding.owner; out.sequence = binding.sequence;
    service_test::leaf.prepared_attachment = attachment;
    if (service_test::leaf.measured_target) {
        // Reuse the production arithmetic after the constructed current source
        // read. This does not stand in for the unlinked native admission checks.
        if (!owned_bodies::try_measure_source(binding.owner, binding.source, out.source)) return false;
        out.sample = out.source.sample();
        if (!body_follow_transform::transform_led(out.sample, attachment.offset_from_com, attachment.root_in_body,
            attachment.lead, out.value, out.lead_skipped)) return false;
    }
    out.ready = true; reason = Reason::none;
    return true;
}
bool prepare_target(const Binding& binding, const NativeMotionEntry& entry, const Attachment& attachment,
    PreparedTarget& out, Reason& reason, Diagnostic& diagnostic) noexcept {
    return prepare_target(binding, entry.rig(), entry.context(), entry.supplied(), attachment, out, reason, diagnostic);
}
bool current_target(const Binding&, PreparedTarget& target, Reason& reason, Diagnostic&) noexcept {
    ++service_test::leaf.currents;
    const bool current = target.ready && !service_test::leaf.current_refusal;
    reason = current ? Reason::none : Reason::unavailable;
    return current;
}
bool current_target(const Binding& binding, const NativeMotionEntry&, PreparedTarget& target, Reason& reason,
    Diagnostic& diagnostic) noexcept {
    return current_target(binding, target, reason, diagnostic);
}
bool capture_park_fence(const Binding& binding, ParkFence& fence, Reason& reason, Diagnostic&) noexcept {
    ++service_test::leaf.fences; reason = Reason::unavailable;
    if (fence.available() || !binding.stopped) return false;
    fence.owner_ = binding.owner; fence.sequence_ = binding.sequence; fence.actor_ = binding.actor; fence.cleanup_ = binding.cleanup;
    reason = Reason::none;
    return true;
}
bool observe_park(const Binding& binding, const ParkFence& fence, owned_bodies::RetainedParkReceipt& receipt,
    Reason& reason, Diagnostic&) noexcept {
    ++service_test::leaf.parks; reason = Reason::unavailable;
    if (!fence.available() || fence.owner_ != binding.owner) return false;
    if (!receipt.available() && !owned_bodies::observe_retained_park(binding.owner, fence.basis_, receipt)) return false;
    reason = Reason::none;
    return true;
}
bool completed_history_matches(const Binding& binding, const ParkFence& fence,
    const owned_bodies::RetainedParkReceipt& receipt) noexcept {
    return fence.available() && receipt.available() && fence.owner_ == binding.owner && fence.sequence_ == binding.sequence;
}
bool seal_command_cleanup(const Binding&, const ParkFence&, const owned_bodies::RetainedParkReceipt&) noexcept {
    auto& leaf = service_test::leaf;
    ++leaf.command_seals;
    if (leaf.seal_refusal) return false;
    ++leaf.successful_seals;
    return true;
}
owned_bodies::CompletedAckHandoff completed_ack_handoff(const Binding& binding, const ParkFence& fence,
    const owned_bodies::RetainedParkReceipt& receipt) noexcept {
    auto& leaf = service_test::leaf;
    ++leaf.ack_handoffs;
    leaf.handoff_owner = binding.owner; leaf.handoff_sequence = binding.sequence;
    leaf.handoff_after_seal = leaf.successful_seals != 0;
    service_test::check(binding.published && binding.stopped && !binding.reserved &&
        completed_history_matches(binding, fence, receipt), "handoff carries exact completed Follow history");
    return leaf.handoff_result;
}
bool complete_stop(Binding& binding, const ParkFence& fence, const owned_bodies::RetainedParkReceipt& receipt,
    Diagnostic&) noexcept {
    ++service_test::leaf.completions;
    if (!binding.stopped || !fence.available() || !receipt.available()) return false;
    binding.reserved = false;
    return true;
}
// The fixture friend the entry header reserves. It mints one live entry on the
// calling thread, as the installed wrapper does around an engine call; the
// result is constructed in place, since an entry can be neither copied nor moved.
struct CallbackEntryTestAccess {
    static NativeMotionEntry make(NativeMotionEntry::Original original, const std::array<float, 16>* supplied) noexcept {
        return NativeMotionEntry(original, service_test::rig, service_test::context, supplied, 0);
    }
};
} // namespace dingosdk::body_follow_native

// ---- scenarios ---------------------------------------------------------------------------------
namespace dingosdk::body_follow_service::test {
using service_test::check;
using service_test::leaf;
using Reason = actor_control_native::Reason;
using body_follow_api::ReadStatus;
constexpr std::uint64_t owner = 501;
constexpr owned_body::Handle body{17, 0};
constexpr std::uint64_t start_ms = 100000;

std::uint64_t clock_ms() { return service_test_clock::now.load(); }
void at(std::uint64_t ms) { service_test_clock::now = ms; }

LeaseGuard clear_guard() {
    LeaseGuard guard;
    guard.sampled_ms = clock_ms();
    guard.ready = guard.focused = guard.menu_closed = guard.pause_menu_known = guard.pause_menu_closed =
        guard.debug_control_clear = guard.actor_upright = true;
    return guard;
}
// The facts as the client tick would publish them, without running the tick.
void store_guard(const LeaseGuard& guard) { service().guard.store(body_follow_lease::pack(guard), std::memory_order_release); }

void reset(std::string_view name) {
    service_test::current_case = name;
    auto& s = service();
    check(TryAcquireSRWLockExclusive(&s.lock) != 0, "no scenario leaves the Service lock held");
    acknowledge_locked(s);
    s.edge.store(stopped_bit, std::memory_order_release);
    s.guard.store(0, std::memory_order_release);
    ReleaseSRWLockExclusive(&s.lock);
    leaf = {};
    at(start_ms);
}

// Holds the Service lock from another thread, so every Try in the test fails.
class HeldLock {
public:
    HeldLock() : held_(CreateEventW(nullptr, TRUE, FALSE, nullptr)), leave_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {
        check(held_ && leave_, "lock holder events");
        holder_ = std::thread([this] {
            AcquireSRWLockExclusive(&service().lock);
            SetEvent(held_);
            WaitForSingleObject(leave_, 5000);
            ReleaseSRWLockExclusive(&service().lock);
        });
        check(WaitForSingleObject(held_, 5000) == WAIT_OBJECT_0, "another thread holds the Service lock");
    }
    ~HeldLock() {
        SetEvent(leave_);
        holder_.join();
        CloseHandle(held_); CloseHandle(leave_);
    }
    HeldLock(const HeldLock&) = delete;
    HeldLock& operator=(const HeldLock&) = delete;
private:
    HANDLE held_{}, leave_{};
    std::thread holder_;
};

// A reserve as the runtime makes it, without a client tick first.
bool try_reserve(bool renewable, Handle& handle, Reason& reason,
    body_follow_native::CleanupPolicy cleanup = body_follow_native::CleanupPolicy::owned_body,
    body_follow_native::MotionPolicy motion = body_follow_native::MotionPolicy::native_lifetime) {
    owned_bodies::MeasuredSource expected;
    check(owned_bodies::capture_source(owner, body, expected), "constructed source");
    body_follow_native::Attachment attachment;
    attachment.cleanup = cleanup;
    attachment.motion_policy = motion;
    attachment.lifetime = renewable ? body_follow_native::Lifetime::renewable : body_follow_native::Lifetime::fixed;
    handle = {};
    return reserve(owner, body, expected, attachment, body_follow_api::eligible, handle, reason);
}
// A client tick with every fact clear, then an accepted reserve.
Handle reserve_one(bool renewable,
    body_follow_native::MotionPolicy motion = body_follow_native::MotionPolicy::native_lifetime) {
    tick(clear_guard());
    Handle handle; Reason reason{};
    check(try_reserve(renewable, handle, reason, body_follow_native::CleanupPolicy::owned_body, motion) &&
        handle.sequence && reason == Reason::none, "the reserve is accepted");
    return handle;
}
Handle follow_one(bool renewable,
    body_follow_native::MotionPolicy motion = body_follow_native::MotionPolicy::native_lifetime) {
    const auto handle = reserve_one(renewable, motion);
    Reason reason{};
    check(publish(owner, handle, reason) && reason == Reason::none, "the publish is accepted");
    return handle;
}
Receipt read_one(Handle handle) {
    Receipt receipt;
    check(read_status(owner, handle, receipt) == ReadStatus::ok, "the receipt reads");
    return receipt;
}
body_follow_api::LeaseReceipt lease_one(Handle handle) {
    body_follow_api::LeaseReceipt lease;
    check(read_lease(owner, handle, lease) == ReadStatus::ok, "the lease reads");
    check(lease.handle.sequence == handle.sequence, "the lease names its receipt");
    return lease;
}
owned_body::Epoch proof(std::uint64_t serial) { return {23, body.generation, serial, 1.0 + static_cast<double>(serial), 1.f / 60.f}; }
bool renew_one(Handle handle, std::uint64_t serial, std::uint64_t& remaining, body_follow_lease::Refusal& refusal) {
    return renew(owner, handle, body, proof(serial), remaining, refusal);
}
void original(std::uintptr_t, std::uintptr_t, const std::array<float, 16>* value, std::uint8_t) {
    ++leaf.originals;
    if (value) leaf.original_value = *value;
    service_test::run_once(leaf.during_original);
}
const std::array<float, 16> supplied_pose{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
bool dispatch_one() {
    return dispatch(&original, service_test::rig, service_test::context, &supplied_pose, 0);
}
// One engine call through a live entry, as the installed wrapper makes it.
bool dispatch_entry_one() {
    auto entry = body_follow_native::CallbackEntryTestAccess::make(&original, &supplied_pose);
    return dispatch(entry);
}
StopDiagnostic first_stop() {
    StopDiagnostic latched; CleanupDiagnostic cleanup;
    take_diagnostics(latched, cleanup);
    check(latched.available, "the first stop was recorded");
    return latched;
}
// Runs the client tick that finishes a published Follow's cleanup, then ACKs it.
void complete_and_acknowledge(Handle handle) {
    tick(clear_guard());
    check(read_one(handle).phase == Phase::completed, "cleanup completes in the tick after the stop");
    check(acknowledge_completed(owner, handle), "the completed receipt is acknowledged");
}

void fixed_unchanged() {
    reset("fixed_unchanged");
    // Every fact but readiness false: a fixed Follow keeps the original set.
    auto bad = clear_guard();
    bad.focused = bad.menu_closed = bad.pause_menu_known = bad.pause_menu_closed = bad.debug_control_clear = bad.actor_upright = false;
    const auto handle = reserve_one(false);
    store_guard(bad);
    {
        auto& s = service();
        check(s.lease.started == start_ms && s.lease.deadline == start_ms + 3000 && s.lease.ceiling == start_ms + 3000 &&
            !s.lease.renewable, "the fixed deadline is written at reserve as reservation + 3000");
    }
    Reason reason{};
    check(publish(owner, handle, reason) && reason == Reason::none, "publish ignores the extra facts");
    bad.sampled_ms = clock_ms(); tick(bad);
    check(read_one(handle).phase == Phase::following, "tick ignores the extra facts");
    check(dispatch_one() && leaf.originals == 1, "dispatch ignores the extra facts");
    std::uint64_t remaining = 7; auto refusal = body_follow_lease::Refusal::none;
    check(!renew_one(handle, 41, remaining, refusal) && refusal == body_follow_lease::Refusal::not_renewable && !remaining,
        "a fixed Follow cannot be renewed");
    check(!leaf.proof_checks && service().lease.deadline == start_ms + 3000, "the refusal did no World work and changed nothing");
    at(start_ms + 1000);
    auto lease = lease_one(handle);
    check(!lease.renewable && lease.active && lease.remaining_ms == 2000 && lease.lifetime_remaining_ms == 2000 &&
        lease.lifetime_ms == 3000 && lease.base_ms == 3000 && lease.renewal_ms == 500 && !lease.renewals &&
        lease.revocation == body_follow_lease::Revocation::none, "the fixed lease report");
    at(start_ms + 2999);
    bad.sampled_ms = clock_ms(); tick(bad);
    check(read_one(handle).phase == Phase::following, "live at reservation + 2999");
    at(start_ms + 3000);
    bad.sampled_ms = clock_ms(); tick(bad);
    const auto receipt = read_one(handle);
    check(receipt.phase == Phase::completed && receipt.reason == Reason::expired, "the lapse stops it and cleanup completes");
    const auto lapse = first_stop();
    check(lapse.origin == StopOrigin::tick_expired && lapse.reason == Reason::expired &&
        lapse.state.revocation == body_follow_lease::Revocation::deadline, "the original tick lapse");
    lease = lease_one(handle);
    check(!lease.active && !lease.remaining_ms && lease.revocation == body_follow_lease::Revocation::deadline,
        "the lease report names the lapse");
    check(acknowledge_completed(owner, handle), "the completed fixed Follow is acknowledged");
    // Readiness is the one fact a fixed Follow keeps, with its original origin.
    const auto again = follow_one(false);
    auto unready = clear_guard(); unready.ready = false;
    tick(unready);
    const auto unready_stop = first_stop();
    check(unready_stop.origin == StopOrigin::runtime_not_ready && unready_stop.reason == Reason::unavailable &&
        read_one(again).reason == Reason::unavailable, "a client that is not ready stops a fixed Follow as before");
}

void renew_deadline() {
    reset("renew_deadline");
    using body_follow_lease::Refusal;
    auto handle = follow_one(true);
    {
        const auto& s = service();
        check(s.lease.renewable && s.lease.deadline == start_ms + 3000 && s.lease.ceiling == start_ms + 120000,
            "a renewable Follow starts with the fixed floor and the ceiling");
    }
    std::uint64_t remaining{}; auto refusal = Refusal::busy; std::uint64_t serial = service_test::body_serial;
    at(start_ms + 100); tick(clear_guard());
    check(renew_one(handle, ++serial, remaining, refusal) && refusal == Refusal::none && remaining == 2900 &&
        service().lease.deadline == start_ms + 3000 && service().lease.renewals == 1,
        "a renewal inside the floor leaves reservation + 3000 and counts once");
    check(leaf.proof_identity_reserved && leaf.last_proof == proof(serial), "World checked the reserved source and the proof");
    at(start_ms + 2800); tick(clear_guard());
    check(renew_one(handle, ++serial, remaining, refusal) && remaining == 500 && service().lease.deadline == start_ms + 3300,
        "a renewal at R+2800 moves the deadline to R+3300");
    at(start_ms + 3299); tick(clear_guard());
    check(read_one(handle).phase == Phase::following, "the tick edge sees the later deadline");
    check(dispatch_one() && leaf.originals == 1, "the dispatch edges see the later deadline");
    check(renew_one(handle, ++serial, remaining, refusal) && service().lease.deadline == start_ms + 3799, "the window rolls");
    // Every 400 ms to R+119400: the deadline only ever moves forward.
    std::uint64_t previous = service().lease.deadline;
    for (std::uint64_t t = start_ms + 3400; t <= start_ms + 119400; t += 400) {
        at(t); tick(clear_guard());
        check(renew_one(handle, ++serial, remaining, refusal) && remaining == service().lease.deadline - t, "a regular renewal");
        check(service().lease.deadline >= previous, "the deadline never moves back");
        previous = service().lease.deadline;
    }
    check(service().lease.deadline == start_ms + 119900, "the last rolling window");
    at(start_ms + 119800); tick(clear_guard());
    check(renew_one(handle, ++serial, remaining, refusal) && remaining == 200 && service().lease.deadline == start_ms + 120000,
        "a renewal at R+119800 caps the deadline at R+120000");
    const auto checks_before = leaf.proof_checks;
    at(start_ms + 119900); tick(clear_guard());
    check(!renew_one(handle, ++serial, remaining, refusal) && refusal == Refusal::lifetime_exhausted && !remaining,
        "the next renewal is lifetime_exhausted");
    check(leaf.proof_checks == checks_before && read_one(handle).phase == Phase::following,
        "an exhausted renewal did no World work and did not stop the Follow");
    at(start_ms + 119999); tick(clear_guard());
    check(dispatch_one() && leaf.originals == 2, "live to the last millisecond");
    at(start_ms + 120000);
    check(!dispatch_one() && leaf.originals == 2, "the callback at the ceiling is not followed");
    auto first = first_stop();
    check(first.origin == StopOrigin::dispatch_expired && first.reason == Reason::expired &&
        first.state.revocation == body_follow_lease::Revocation::lifetime, "the ceiling lapses at dispatch with lifetime");
    check(lease_one(handle).revocation == body_follow_lease::Revocation::lifetime, "the lease report says lifetime");
    complete_and_acknowledge(handle);

    // Publish at the deadline only refuses; the tick then stops it.
    handle = reserve_one(true);
    const auto unpublished = service().lease.started;
    at(unpublished + 3000);
    Reason reason{};
    check(!publish(owner, handle, reason) && !service().stop_cause_recorded, "publish at the deadline refuses without a stop");
    tick(clear_guard());
    first = first_stop();
    check(first.origin == StopOrigin::tick_expired && first.state.revocation == body_follow_lease::Revocation::deadline,
        "the tick lapse of an unpublished renewable Follow");
    tick(clear_guard());
    check(read_one(handle).phase == Phase::abandoned && acknowledge_abandoned(owner, handle), "never published, abandoned");

    // The lease passes between the opening checks and the closing one.
    handle = reserve_one(true);
    const auto closing = service().lease.started;
    leaf.during_publish = [closing] { at(closing + 3000); };
    check(!publish(owner, handle, reason) && reason == Reason::expired, "publish closing at the deadline");
    first = first_stop();
    check(first.origin == StopOrigin::publish_closing && first.state.revocation == body_follow_lease::Revocation::deadline,
        "the closing publish edge latches deadline");
    complete_and_acknowledge(handle);

    // And between preparation and the forwarding edge.
    handle = follow_one(true);
    const auto forwarding = service().lease.started;
    const auto originals = leaf.originals;
    leaf.during_prepare = [forwarding] { at(forwarding + 3000); };
    check(!dispatch_one() && leaf.originals == originals, "the callback at the forwarding edge is not followed");
    first = first_stop();
    check(first.origin == StopOrigin::dispatch_forwarding_expired && first.reason == Reason::expired &&
        first.state.revocation == body_follow_lease::Revocation::deadline, "the forwarding edge latches deadline");
    complete_and_acknowledge(handle);
}

void renew_windows() {
    reset("renew_windows");
    using body_follow_lease::Refusal;
    std::uint64_t remaining{}; auto refusal = Refusal::busy;
    auto handle = follow_one(true);
    at(start_ms + 2800); tick(clear_guard());
    // Nothing holds the Follow lock while World checks the proof.
    bool other_thread_locked{};
    leaf.during_proof = [&] {
        std::thread other([&] {
            other_thread_locked = TryAcquireSRWLockExclusive(&service().lock) != 0;
            if (other_thread_locked) ReleaseSRWLockExclusive(&service().lock);
        });
        other.join();
    };
    check(renew_one(handle, 41, remaining, refusal) && other_thread_locked, "another thread takes the lock during the body check");
    check(service().lease.renewals == 1 && service().lease.deadline == start_ms + 3300, "and the renewal commits");
    // A stop between the windows: nothing commits.
    leaf.during_proof = [&] { check(stop(owner, handle), "the injected stop"); };
    check(!renew_one(handle, 42, remaining, refusal) && refusal == Refusal::not_following && !remaining,
        "a stop between the windows is not_following");
    check(service().lease.renewals == 1 && service().lease.last_serial == 41 && service().lease.deadline == start_ms + 3300,
        "the stopped renewal did not commit");
    check(first_stop().origin == StopOrigin::explicit_stop, "the injected stop is the receipt's first stop");
    complete_and_acknowledge(handle);
    // An ACK and a new reserve between the windows: the old handle is not_following.
    handle = follow_one(true);
    Handle replacement{};
    leaf.during_proof = [&] {
        check(stop(owner, handle), "stop the old receipt");
        tick(clear_guard());
        check(acknowledge_completed(owner, handle), "acknowledge it");
        replacement = follow_one(true);
    };
    check(!renew_one(handle, 43, remaining, refusal) && refusal == Refusal::not_following, "an ACK and new reserve between the windows");
    check(replacement.sequence && replacement.sequence != handle.sequence, "the replacement is a new receipt");
    const auto fresh = lease_one(replacement);
    check(!fresh.renewals && !fresh.last_serial && service().lease.deadline == clock_ms() + 3000,
        "the replacement's lease is untouched");
    // The lock taken between the windows: the second window is busy.
    std::optional<HeldLock> held;
    leaf.during_proof = [&] { held.emplace(); };
    check(!renew_one(replacement, 44, remaining, refusal) && refusal == Refusal::busy, "a busy second window refuses busy");
    held.reset();
    check(!service().lease.renewals, "a busy second window commits nothing");
    check(renew_one(replacement, 44, remaining, refusal), "the same proof renews once the lock is free");
}

void renew_proof() {
    reset("renew_proof");
    using body_follow_lease::Refusal;
    using owned_bodies::RenewalProof;
    std::uint64_t remaining{}; auto refusal = Refusal::none;
    // Reserved but not yet published: not_following, before any World work, and
    // the refusal neither stops the receipt nor keeps it from publishing.
    const auto handle = reserve_one(true);
    check(!renew_one(handle, 41, remaining, refusal) && refusal == Refusal::not_following && !remaining,
        "an unpublished renewable Follow is not_following");
    check(!leaf.proof_checks && !service().stop_cause_recorded && !service().lease.renewals &&
        read_one(handle).phase == Phase::reserved, "the unpublished refusal did no World work and stopped nothing");
    Reason reason{};
    check(publish(owner, handle, reason) && reason == Reason::none, "the same receipt still publishes");
    at(start_ms + 2800); tick(clear_guard());
    const auto unchanged = [&] {
        const auto& lease = service().lease;
        return !lease.renewals && !lease.last_serial && lease.deadline == start_ms + 3000 && !service().stop_cause_recorded;
    };
    struct Case { RenewalProof world; Refusal lua; };
    for (const auto& item : {Case{RenewalProof::busy, Refusal::busy}, Case{RenewalProof::body_unavailable, Refusal::body_unavailable},
        Case{RenewalProof::not_latest, Refusal::sample_stale}, Case{RenewalProof::clock_stale, Refusal::sample_stale}}) {
        leaf.proof_result = item.world;
        check(!renew_one(handle, 50, remaining, refusal) && refusal == item.lua && !remaining, "each World refusal maps to its reason");
        check(unchanged(), "a World refusal changes nothing and stops nothing");
    }
    leaf.proof_result = RenewalProof::current;
    leaf.proof_current_serial = 49;
    check(!renew_one(handle, 50, remaining, refusal) && refusal == Refusal::sample_stale && unchanged(),
        "a proof newer than the current step is stale");
    leaf.proof_current_serial = 57;
    check(!renew_one(handle, 50, remaining, refusal) && refusal == Refusal::sample_stale && unchanged(),
        "a proof seven steps behind is stale");
    leaf.proof_current_serial = 56;
    check(renew_one(handle, 50, remaining, refusal) && service().lease.last_serial == 50, "a proof six steps behind renews");
    const auto checks_before = leaf.proof_checks;
    leaf.proof_current_serial = 0;
    check(!renew_one(handle, 50, remaining, refusal) && refusal == Refusal::sample_not_advanced, "the same proof does not advance");
    check(!renew_one(handle, 49, remaining, refusal) && refusal == Refusal::sample_not_advanced, "an older proof does not advance");
    check(leaf.proof_checks == checks_before, "not advancing is refused before any World work");
    check(!renew(owner, handle, owned_body::Handle{18, 1}, proof(51), remaining, refusal) && refusal == Refusal::not_following,
        "another body's proof is not_following");
    check(!renew(owner + 1, handle, body, proof(51), remaining, refusal) && refusal == Refusal::not_following,
        "another owner is not_following");
    check(!renew(owner, Handle{handle.sequence + 1}, body, proof(51), remaining, refusal) && refusal == Refusal::not_following,
        "another sequence is not_following");
    check(leaf.proof_checks == checks_before && service().lease.renewals == 1, "foreign renewals reach no World work");
}

void guard_tick_order() {
    struct Case { bool LeaseGuard::*fact; Reason reason; body_follow_lease::Revocation cause; };
    using body_follow_lease::Revocation;
    const Case cases[] = {
        {&LeaseGuard::ready, Reason::unavailable, Revocation::client_not_ready},
        {&LeaseGuard::pause_menu_known, Reason::unavailable, Revocation::client_not_ready},
        {&LeaseGuard::focused, Reason::focus_changed, Revocation::focus_lost},
        {&LeaseGuard::menu_closed, Reason::focus_changed, Revocation::menu_open},
        {&LeaseGuard::pause_menu_closed, Reason::focus_changed, Revocation::pause_menu_open},
        {&LeaseGuard::debug_control_clear, Reason::focus_changed, Revocation::debug_control},
        {&LeaseGuard::actor_upright, Reason::unsupported_state, Revocation::actor_state},
    };
    for (const auto& item : cases) {
        reset("guard_tick_order");
        const auto handle = follow_one(true);
        at(start_ms + 500);
        auto guard = clear_guard();
        guard.*item.fact = false;
        tick(guard);
        // Stopped above the cleanup in the same tick: completed with no second tick.
        const auto receipt = read_one(handle);
        check(receipt.phase == Phase::completed && receipt.reason == item.reason,
            "the tick that saw the fact stopped it and finished cleanup, with the existing reason");
        const auto first = first_stop();
        check(first.origin == StopOrigin::lease_guard && first.reason == item.reason && first.state.revocation == item.cause,
            "the stop's origin and revocation");
        const auto lease = lease_one(handle);
        check(lease.revocation == item.cause && !lease.active && !lease.remaining_ms, "the lease report names the exact cause");
        check(acknowledge_completed(owner, handle), "the stopped Follow is acknowledged");
    }
}

void guard_atomic() {
    reset("guard_atomic");
    using body_follow_lease::Refusal;
    const auto handle = follow_one(true);
    at(start_ms + 200);
    auto guard = clear_guard(); guard.focused = false;
    {
        HeldLock held;
        tick(guard); // its Try misses
        check(service().guard.load() == body_follow_lease::pack(guard), "the tick stored the facts before its Try");
    }
    check(!service().stop_cause_recorded && read_one(handle).phase == Phase::following, "the missed tick stopped nothing");
    std::uint64_t remaining{}; auto refusal = Refusal::none;
    check(!renew_one(handle, 41, remaining, refusal) && refusal == Refusal::focus_lost, "the later renewal sees the stored facts");
    const auto first = first_stop();
    check(first.origin == StopOrigin::lease_guard && first.reason == Reason::focus_changed &&
        first.state.revocation == body_follow_lease::Revocation::focus_lost, "and stops with the exact cause");
    check(!leaf.proof_checks, "a revoked renewal reaches no World work");
}

void guard_reserve_publish() {
    reset("guard_reserve_publish");
    Reason reason{};
    Handle handle;
    // A never-sampled guard refuses a renewable reserve before any claim.
    check(!try_reserve(true, handle, reason) && !handle.sequence && reason == Reason::unavailable && !service().occupied,
        "an unsampled guard refuses a renewable reserve");
    check(!leaf.reserve_bindings && !leaf.holds && leaf.captures == 1, "nothing was claimed, held or captured by the Service");
    // A renewable lease needs owned-body cleanup in the Service too.
    tick(clear_guard());
    check(!try_reserve(true, handle, reason, body_follow_native::CleanupPolicy::actor_lifetime) && !service().occupied,
        "renewable actor-lifetime cleanup is refused");
    struct Case { bool LeaseGuard::*fact; Reason reason; };
    for (const auto& item : {Case{&LeaseGuard::actor_upright, Reason::unsupported_state},
        Case{&LeaseGuard::menu_closed, Reason::focus_changed}, Case{&LeaseGuard::pause_menu_known, Reason::unavailable}}) {
        auto guard = clear_guard(); guard.*item.fact = false;
        store_guard(guard);
        const auto bindings = leaf.reserve_bindings;
        check(!try_reserve(true, handle, reason) && !handle.sequence && reason == item.reason && !service().occupied &&
            leaf.reserve_bindings == bindings, "a revoking fact refuses a renewable reserve before any claim");
    }
    // A guard 250 ms old refuses too; a fixed reserve ignores it.
    tick(clear_guard());
    at(clock_ms() + 250);
    check(!try_reserve(true, handle, reason) && !handle.sequence && reason == Reason::unavailable && !service().occupied,
        "a 250 ms old guard refuses a renewable reserve");
    check(try_reserve(false, handle, reason) && handle.sequence, "a fixed reserve ignores the stale guard");
    check(stop(owner, handle), "stop the fixed reserve");
    tick(clear_guard());
    check(acknowledge_abandoned(owner, handle), "and acknowledge it");
    // Publish with a revoking fact stops with lease_guard before publish_binding.
    handle = reserve_one(true);
    auto guard = clear_guard(); guard.menu_closed = false;
    store_guard(guard);
    const auto publishes = leaf.publish_bindings;
    check(!publish(owner, handle, reason) && reason == Reason::focus_changed && leaf.publish_bindings == publishes,
        "publish under a revoking fact stops before publish_binding");
    auto first = first_stop();
    check(first.origin == StopOrigin::lease_guard && first.state.revocation == body_follow_lease::Revocation::menu_open,
        "the publish stop's origin and revocation");
    tick(clear_guard());
    check(read_one(handle).phase == Phase::abandoned && acknowledge_abandoned(owner, handle), "never published, abandoned");
    // And with a guard that went stale without a tick.
    handle = reserve_one(true);
    at(clock_ms() + 250);
    check(!publish(owner, handle, reason) && reason == Reason::unavailable, "publish with a stale guard");
    first = first_stop();
    check(first.origin == StopOrigin::lease_guard && first.state.revocation == body_follow_lease::Revocation::client_not_ready,
        "the stale publish stop");
    tick(clear_guard());
    check(acknowledge_abandoned(owner, handle), "abandoned and acknowledged");
    // A renewable reserve refused after it took the slot, before its lease
    // started, keeps that receipt's cleanup and reports no renewable lease.
    leaf.hold_refusal = true;
    tick(clear_guard());
    check(!try_reserve(true, handle, reason) && handle.sequence && reason == Reason::motion_owned,
        "a hold refused after the claim");
    leaf.hold_refusal = false;
    first = first_stop();
    check(first.origin == StopOrigin::reserve_hold && first.state.revocation == body_follow_lease::Revocation::none,
        "the hold refusal is not a lease stop");
    const auto unstarted = lease_one(handle);
    check(!unstarted.renewable && !unstarted.active && !unstarted.remaining_ms &&
        unstarted.revocation == body_follow_lease::Revocation::other, "the lease report shows no lease started");
    check(read_one(handle).phase == Phase::abandoned && acknowledge_abandoned(owner, handle), "abandoned and acknowledged");
}

void dispatch_guard_busy() {
    reset("dispatch_guard_busy");
    // Lock misses with no live slot are not counted.
    {
        HeldLock held;
        check(!dispatch_one(), "a miss with no Follow");
    }
    check(!service().dispatch_busy.load(), "a miss with no live slot is not counted");
    auto handle = follow_one(true);
    check(!service().dispatch_busy.load(), "a reserve starts at zero skipped callbacks");
    check(dispatch_one() && leaf.originals == 1, "a callback under a fresh guard is followed");
    at(start_ms + 250);
    check(!dispatch_one() && leaf.originals == 1, "a stale guard stops the callback");
    auto first = first_stop();
    check(first.origin == StopOrigin::dispatch_guard && first.reason == Reason::unavailable &&
        first.state.revocation == body_follow_lease::Revocation::client_not_ready, "dispatch_guard with client_not_ready");
    complete_and_acknowledge(handle);
    // A held lock: the callback is skipped, counted and reported; the Follow continues.
    handle = follow_one(true);
    {
        HeldLock held;
        for (int i = 0; i < 3; ++i) check(!dispatch_one(), "a callback that finds the lock busy is not followed");
    }
    check(leaf.originals == 1 && !service().stop_cause_recorded, "skipped callbacks neither forward nor stop");
    check(lease_one(handle).dispatch_busy == 3, "the lease report counts them");
    check(dispatch_one() && leaf.originals == 2, "the next free callback is followed");
    check(stop(owner, handle), "stop");
    first = first_stop();
    check(first.state.dispatch_busy == 3 && first.origin == StopOrigin::explicit_stop, "the stop diagnostic carries the count");
    complete_and_acknowledge(handle);
}

void revision_exhausted() {
    for (const bool renewable : {true, false}) {
        reset("revision_exhausted");
        const auto handle = follow_one(renewable);
        auto& s = service();
        s.final.revision = std::numeric_limits<std::uint64_t>::max();
        s.returned_revision.store(std::numeric_limits<std::uint64_t>::max());
        check(!dispatch_one() && !leaf.originals, "an exhausted revision is not followed");
        const auto first = first_stop();
        check(first.origin == StopOrigin::dispatch_revision_exhausted && first.reason == Reason::expired,
            "its own origin, the existing receipt reason");
        const auto lease = lease_one(handle);
        check(lease.revocation == body_follow_lease::Revocation::other, "the lease did not cause it");
        check(read_one(handle).reason == Reason::expired, "receipt expired");
    }
}

void revocation_first_only() {
    reset("revocation_first_only");
    auto handle = follow_one(true);
    check(stop(owner, handle), "an explicit stop first");
    at(start_ms + 3000); tick(clear_guard());
    check(lease_one(handle).revocation == body_follow_lease::Revocation::other && read_one(handle).reason == Reason::cancelled,
        "a lapse after an explicit stop reads other");
    check(acknowledge_completed(owner, handle), "acknowledged");
    handle = follow_one(true);
    at(clock_ms() + 3000); tick(clear_guard());
    check(stop(owner, handle), "an explicit stop after the lapse");
    check(lease_one(handle).revocation == body_follow_lease::Revocation::deadline && read_one(handle).reason == Reason::expired,
        "an explicit stop after a lapse reads deadline");
}

void completed_ack_bookkeeping() {
    using owned_bodies::CompletedAckHandoff;
    constexpr std::array outcomes{CompletedAckHandoff::recorded, CompletedAckHandoff::closed_ineligible,
        CompletedAckHandoff::unavailable};
    for (const auto outcome : outcomes) {
        reset("ack_reset");
        const auto handle = follow_one(false);
        check(!acknowledge_completed(owner, handle) && !leaf.ack_handoffs, "premature ACK makes no handoff");
        check(dispatch_one(), "one final original returns before cleanup");
        check(stop(owner, handle), "stop before completed handoff");
        tick(clear_guard());
        check(read_one(handle).phase == Phase::completed && service().command_cleanup_sealed && !leaf.ack_handoffs,
            "completion and sealing alone do not record consumer ACK provenance");
        check(!acknowledge_completed(owner + 1, handle) && !leaf.ack_handoffs, "foreign ACK makes no handoff");
        leaf.handoff_result = outcome;
        // Model unavailable native leaves after the body was retained. The
        // provider's real retained/unreadable metadata cases live in World tests.
        leaf.current_refusal = leaf.prepare_refusal = leaf.seal_refusal = true;
        leaf.release_known = false;
        const auto captures = leaf.captures, currents = leaf.currents, fences = leaf.fences, parks = leaf.parks;
        const auto seals = leaf.command_seals;
        bool acknowledged{};
        if (outcome == CompletedAckHandoff::unavailable) {
            // Cached cleanup permits the existing ACK off the client thread.
            std::thread caller([&] { acknowledged = acknowledge_completed(owner, handle); });
            caller.join();
        } else acknowledged = acknowledge_completed(owner, handle);
        check(acknowledged, "every advisory bookkeeping outcome preserves valid terminal ACK");
        check(leaf.ack_handoffs == 1 && leaf.handoff_owner == owner && leaf.handoff_sequence == handle.sequence &&
            leaf.handoff_after_seal, "one exact handoff occurs after command sealing and before receipt reset");
        check(leaf.captures == captures && leaf.currents == currents && leaf.fences == fences && leaf.parks == parks &&
            leaf.command_seals == seals, "ACK neither refreshes native evidence nor repeats cached command sealing");
        Receipt receipt;
        check(read_status(owner, handle, receipt) == ReadStatus::unavailable && !service().occupied,
            "ACK consumes terminal Follow history for every bookkeeping outcome");
        check(!acknowledge_completed(owner, handle) && leaf.ack_handoffs == 1, "duplicate ACK cannot record provenance");
    }

    reset("ack_reset");
    auto handle = follow_one(false);
    check(stop(owner, handle), "stop before an unavailable command seal");
    leaf.seal_refusal = true;
    tick(clear_guard());
    check(read_one(handle).phase == Phase::completed && !service().command_cleanup_sealed,
        "constructed completion can precede command sealing");
    check(!acknowledge_completed(owner, handle) && !leaf.ack_handoffs && service().occupied,
        "the existing command seal gate still refuses ACK without recording provenance");
    leaf.seal_refusal = false;
    check(acknowledge_completed(owner, handle) && leaf.ack_handoffs == 1 && leaf.handoff_after_seal,
        "a later successful seal permits the same exact terminal ACK");

    reset("ack_reset");
    handle = reserve_one(false);
    check(stop(owner, handle), "stop an unpublished binding");
    tick(clear_guard());
    check(!acknowledge_completed(owner, handle) && acknowledge_abandoned(owner, handle) && !leaf.ack_handoffs,
        "abandoned ACK never records completed provenance");

    reset("ack_reset");
    handle = follow_one(false);
    check(stop(owner, handle), "stop before orphaning completed history");
    tick(clear_guard());
    release_all(owner);
    check(acknowledge_completed(owner, handle) && !leaf.ack_handoffs && !service().occupied,
        "explicit ACK of orphaned completed history resets without live-owner provenance");

    reset("ack_reset");
    handle = follow_one(false);
    release_all(owner);
    tick(clear_guard());
    Receipt receipt;
    check(read_status(owner, handle, receipt) == ReadStatus::unavailable && !service().occupied && !leaf.ack_handoffs,
        "completed orphan auto-cleanup resets without consumer ACK provenance");

    reset("ack_reset");
    handle = reserve_one(false);
    release_all(owner);
    tick(clear_guard());
    check(read_status(owner, handle, receipt) == ReadStatus::unavailable && !service().occupied && !leaf.ack_handoffs,
        "abandoned orphan auto-cleanup also records no completed provenance");
}

void ack_reset() {
    reset("ack_reset");
    using body_follow_lease::Refusal;
    auto handle = follow_one(true);
    std::uint64_t remaining{}; auto refusal = Refusal::none;
    at(start_ms + 2800); tick(clear_guard());
    check(renew_one(handle, 41, remaining, refusal), "renewed once");
    {
        HeldLock held;
        check(!dispatch_one(), "one skipped callback");
    }
    check(stop(owner, handle), "stop");
    tick(clear_guard());
    const auto word = service().guard.load();
    check(acknowledge_completed(owner, handle), "acknowledged");
    const auto& lease = service().lease;
    check(!lease.started && !lease.deadline && !lease.ceiling && !lease.renewals && !lease.last_serial && !lease.renewable &&
        lease.revocation == body_follow_lease::Revocation::none && !service().dispatch_busy.load(),
        "ACK resets the lease state and the skipped-callback count");
    check(service().guard.load() == word && word != 0, "ACK keeps the client's guard word");
    body_follow_api::LeaseReceipt old;
    Receipt receipt;
    check(read_lease(owner, handle, old) == ReadStatus::unavailable && read_status(owner, handle, receipt) == ReadStatus::unavailable,
        "the acknowledged receipt and its lease are unavailable");
    // The kept guard admits a renewable reserve with no tick in between.
    Handle next; Reason reason{};
    check(try_reserve(true, next, reason), "a renewable reserve right after ACK");
    const auto fresh = lease_one(next);
    check(fresh.renewable && !fresh.renewals && !fresh.last_serial && !fresh.dispatch_busy && fresh.remaining_ms == 3000 &&
        fresh.lifetime_remaining_ms == 120000 && fresh.revocation == body_follow_lease::Revocation::none, "a fresh renewable lease");
    check(stop(owner, next), "stop it");
    tick(clear_guard());
    check(acknowledge_abandoned(owner, next), "abandoned and acknowledged");
    at(start_ms + 50000);
    const auto fixed = reserve_one(false);
    check(fixed.sequence > next.sequence && service().lease.deadline == start_ms + 53000 &&
        service().lease.ceiling == start_ms + 53000 && !service().lease.renewable,
        "a new fixed reserve reproduces reservation + 3000");
    completed_ack_bookkeeping();
}

void read_busy() {
    reset("read_busy");
    using body_follow_lease::Refusal;
    const auto handle = follow_one(true);
    Receipt receipt; body_follow_api::LeaseReceipt lease;
    std::uint64_t remaining{}; auto refusal = Refusal::none;
    {
        HeldLock held;
        check(read_status(owner, handle, receipt) == ReadStatus::busy && !read(owner, handle, receipt), "a held lock reads busy");
        check(read_lease(owner, handle, lease) == ReadStatus::busy, "and so does the lease");
        check(!renew_one(handle, 41, remaining, refusal) && refusal == Refusal::busy && !leaf.proof_checks, "and a renewal");
    }
    check(read_status(owner, handle, receipt) == ReadStatus::ok && read(owner, handle, receipt), "free again");
    check(read_status(owner + 1, handle, receipt) == ReadStatus::unavailable, "a foreign owner is unavailable");
    check(read_status(owner, Handle{handle.sequence + 1}, receipt) == ReadStatus::unavailable, "a foreign handle is unavailable");
    check(read_lease(owner + 1, handle, lease) == ReadStatus::unavailable, "a foreign lease is unavailable");
}

// A lapse that a renewal finds stops the Follow there, with renew_expired, in
// either window, and nothing commits. Window B reads its own clock, so a lease
// that lapses while World checks the proof is never renewed away.
void renew_expired_windows() {
    reset("renew_expired_windows");
    using body_follow_lease::Refusal;
    using body_follow_lease::Revocation;
    std::uint64_t remaining{}; auto refusal = Refusal::none;
    // Window A at the deadline: stopped before any World work.
    auto handle = follow_one(true);
    at(start_ms + 3000);
    check(!renew_one(handle, 41, remaining, refusal) && refusal == Refusal::expired && !remaining,
        "a renewal at the deadline is expired");
    check(!leaf.proof_checks && !service().lease.renewals && service().lease.deadline == start_ms + 3000,
        "the window A lapse did no World work and committed nothing");
    auto receipt = read_one(handle);
    check(receipt.phase == Phase::stopping && receipt.reason == Reason::expired, "the renewal itself stopped the Follow");
    auto first = first_stop();
    check(first.origin == StopOrigin::renew_expired && first.reason == Reason::expired &&
        first.state.revocation == Revocation::deadline, "window A stops with renew_expired and deadline");
    check(lease_one(handle).revocation == Revocation::deadline, "the lease report says deadline");
    check(!renew_one(handle, 42, remaining, refusal) && refusal == Refusal::not_following && !leaf.proof_checks,
        "a stopped Follow is not renewed again");
    complete_and_acknowledge(handle);

    // Window B past the deadline: World passed the proof, then the lease lapsed.
    handle = follow_one(true);
    auto reserved_at = service().lease.started;
    at(reserved_at + 2800); tick(clear_guard());
    auto checks_before = leaf.proof_checks;
    leaf.during_proof = [reserved_at] { at(reserved_at + 3000); };
    check(!renew_one(handle, 41, remaining, refusal) && refusal == Refusal::expired && !remaining,
        "a lapse during World's check is expired");
    check(leaf.proof_checks == checks_before + 1 && !service().lease.renewals && !service().lease.last_serial &&
        service().lease.deadline == reserved_at + 3000, "World passed the proof and window B committed nothing");
    receipt = read_one(handle);
    check(receipt.phase == Phase::stopping && receipt.reason == Reason::expired, "window B itself stopped the Follow");
    first = first_stop();
    check(first.origin == StopOrigin::renew_expired && first.reason == Reason::expired &&
        first.state.revocation == Revocation::deadline && !first.state.renewals,
        "window B stops with renew_expired and deadline");
    check(lease_one(handle).revocation == Revocation::deadline, "the lease report says deadline");
    complete_and_acknowledge(handle);

    // Window B before reservation: a native clock that went back is a lapse too.
    handle = follow_one(true);
    reserved_at = service().lease.started;
    at(reserved_at + 2800); tick(clear_guard());
    leaf.during_proof = [reserved_at] { at(reserved_at - 1); };
    check(!renew_one(handle, 41, remaining, refusal) && refusal == Refusal::expired && !service().lease.renewals,
        "a clock before reservation during World's check is expired");
    first = first_stop();
    check(first.origin == StopOrigin::renew_expired && first.reason == Reason::expired &&
        first.state.revocation == Revocation::clock, "window B stops with renew_expired and clock");
    at(reserved_at + 2800);
    complete_and_acknowledge(handle);

    // Window B commits at its own clock, so the window runs from the commit.
    handle = follow_one(true);
    reserved_at = service().lease.started;
    at(reserved_at + 2800); tick(clear_guard());
    checks_before = leaf.proof_checks;
    leaf.during_proof = [reserved_at] { at(reserved_at + 2999); };
    check(renew_one(handle, 41, remaining, refusal) && remaining == 500 && service().lease.deadline == reserved_at + 3499 &&
        leaf.proof_checks == checks_before + 1, "window B's clock, not window A's, sets the new deadline");
    check(stop(owner, handle), "stop");
    complete_and_acknowledge(handle);
}

// A revoking fact published after World's check is found by window B: the
// renewal stops the Follow with lease_guard and the exact cause, and commits nothing.
void renew_guard_windows() {
    using body_follow_lease::Refusal;
    using body_follow_lease::Revocation;
    struct Case { bool LeaseGuard::*fact; Refusal refused; Reason reason; Revocation cause; };
    const Case cases[] = {
        {&LeaseGuard::pause_menu_known, Refusal::client_not_ready, Reason::unavailable, Revocation::client_not_ready},
        {&LeaseGuard::focused, Refusal::focus_lost, Reason::focus_changed, Revocation::focus_lost},
        {&LeaseGuard::debug_control_clear, Refusal::debug_control, Reason::focus_changed, Revocation::debug_control},
        {&LeaseGuard::actor_upright, Refusal::actor_state, Reason::unsupported_state, Revocation::actor_state},
    };
    std::uint64_t remaining{}; auto refusal = Refusal::none;
    for (const auto& item : cases) {
        reset("renew_guard_windows");
        const auto handle = follow_one(true);
        at(start_ms + 2800); tick(clear_guard());
        leaf.during_proof = [&item] {
            auto guard = clear_guard(); guard.*item.fact = false;
            store_guard(guard);
        };
        check(!renew_one(handle, 41, remaining, refusal) && refusal == item.refused && !remaining,
            "a fact revoked during World's check refuses with its own name");
        check(leaf.proof_checks == 1 && !service().lease.renewals && !service().lease.last_serial &&
            service().lease.deadline == start_ms + 3000, "World passed the proof and window B committed nothing");
        const auto receipt = read_one(handle);
        check(receipt.phase == Phase::stopping && receipt.reason == item.reason, "window B itself stopped the Follow");
        const auto first = first_stop();
        check(first.origin == StopOrigin::lease_guard && first.reason == item.reason && first.state.revocation == item.cause,
            "window B stops with lease_guard and the exact cause");
        check(lease_one(handle).revocation == item.cause, "the lease report names the exact cause");
        complete_and_acknowledge(handle);
    }
    // A guard that went stale while World checked, with no client tick between.
    reset("renew_guard_windows");
    const auto handle = follow_one(true);
    at(start_ms + 1000); tick(clear_guard());
    leaf.during_proof = [] { at(start_ms + 1250); };
    check(!renew_one(handle, 41, remaining, refusal) && refusal == Refusal::client_not_ready && !service().lease.renewals,
        "a guard that went stale during World's check is client_not_ready");
    const auto first = first_stop();
    check(first.origin == StopOrigin::lease_guard && first.reason == Reason::unavailable &&
        first.state.revocation == Revocation::client_not_ready, "and window B stops it with lease_guard");
    complete_and_acknowledge(handle);
}

// A lapse at a deadline that renewals moved is a deadline lapse at every edge,
// never lifetime, and the stop diagnostic carries the accepted renewals.
void extended_deadline_lapse() {
    reset("extended_deadline_lapse");
    using body_follow_lease::Refusal;
    using body_follow_lease::Revocation;
    std::uint64_t remaining{}; auto refusal = Refusal::none;
    // The client tick, after two renewals.
    auto handle = follow_one(true);
    at(start_ms + 2800); tick(clear_guard());
    check(renew_one(handle, 41, remaining, refusal) && service().lease.deadline == start_ms + 3300, "the first renewal");
    at(start_ms + 3200); tick(clear_guard());
    check(renew_one(handle, 42, remaining, refusal) && service().lease.deadline == start_ms + 3700, "the second renewal");
    at(start_ms + 3699); tick(clear_guard());
    check(read_one(handle).phase == Phase::following, "live a millisecond before the extended deadline");
    at(start_ms + 3700); tick(clear_guard());
    const auto receipt = read_one(handle);
    check(receipt.phase == Phase::completed && receipt.reason == Reason::expired,
        "the tick at the extended deadline stops it and finishes cleanup");
    auto first = first_stop();
    check(first.origin == StopOrigin::tick_expired && first.reason == Reason::expired &&
        first.state.revocation == Revocation::deadline && first.state.renewals == 2,
        "a tick lapse at an extended deadline is deadline, with both renewals");
    const auto lease = lease_one(handle);
    check(!lease.active && !lease.remaining_ms && !lease.lifetime_remaining_ms && lease.renewals == 2 &&
        lease.last_serial == 42 && lease.revocation == Revocation::deadline, "the lease report after the tick lapse");
    check(acknowledge_completed(owner, handle), "acknowledged");

    // The callback edge.
    handle = follow_one(true);
    auto reserved_at = service().lease.started;
    at(reserved_at + 2800); tick(clear_guard());
    check(renew_one(handle, 43, remaining, refusal) && service().lease.deadline == reserved_at + 3300, "renewed");
    auto originals = leaf.originals;
    at(reserved_at + 3299); tick(clear_guard());
    check(dispatch_one() && leaf.originals == originals + 1, "a callback before the extended deadline is followed");
    at(reserved_at + 3300);
    check(!dispatch_one() && leaf.originals == originals + 1, "the callback at the extended deadline is not followed");
    first = first_stop();
    check(first.origin == StopOrigin::dispatch_expired && first.reason == Reason::expired &&
        first.state.revocation == Revocation::deadline && first.state.renewals == 1,
        "a callback lapse at an extended deadline is deadline, not lifetime");
    check(lease_one(handle).revocation == Revocation::deadline, "the lease report says deadline");
    complete_and_acknowledge(handle);

    // The forwarding edge, between preparation and the original.
    handle = follow_one(true);
    reserved_at = service().lease.started;
    at(reserved_at + 2800); tick(clear_guard());
    check(renew_one(handle, 44, remaining, refusal) && service().lease.deadline == reserved_at + 3300, "renewed");
    at(reserved_at + 3200); tick(clear_guard());
    originals = leaf.originals;
    leaf.during_prepare = [reserved_at] { at(reserved_at + 3300); };
    check(!dispatch_one() && leaf.originals == originals, "the callback crossing the extended deadline is not followed");
    first = first_stop();
    check(first.origin == StopOrigin::dispatch_forwarding_expired && first.reason == Reason::expired &&
        first.state.revocation == Revocation::deadline && first.state.renewals == 1,
        "the forwarding edge lapses at the extended deadline");
    complete_and_acknowledge(handle);
}

// The overload the client tick keeps for its observer-failure path knows only
// readiness, so every other fact reads false. A fixed Follow keeps the original
// rule; a renewable one cannot continue on a word with an unknown menu state.
void tick_ready_only() {
    reset("tick_ready_only");
    using body_follow_lease::Revocation;
    auto handle = follow_one(false);
    at(start_ms + 100);
    tick(true);
    LeaseGuard ready_only;
    ready_only.sampled_ms = clock_ms(); ready_only.ready = true;
    check(service().guard.load() == body_follow_lease::pack(ready_only), "tick(true) stores a word with readiness alone");
    check(read_one(handle).phase == Phase::following, "tick(true) leaves a fixed Follow following");
    at(start_ms + 200);
    tick(false);
    LeaseGuard unready;
    unready.sampled_ms = clock_ms();
    check(service().guard.load() == body_follow_lease::pack(unready), "tick(false) stores a word with no fact set");
    auto receipt = read_one(handle);
    check(receipt.phase == Phase::completed && receipt.reason == Reason::unavailable,
        "tick(false) stops a fixed Follow and finishes cleanup");
    auto first = first_stop();
    check(first.origin == StopOrigin::runtime_not_ready && first.reason == Reason::unavailable &&
        first.state.revocation == Revocation::client_not_ready, "the fixed Follow's original origin");
    check(acknowledge_completed(owner, handle), "acknowledged");
    // Under tick(true)'s word a renewable reserve claims nothing.
    tick(true);
    Handle refused; Reason reason{};
    check(!try_reserve(true, refused, reason) && !refused.sequence && reason == Reason::unavailable && !service().occupied,
        "a renewable reserve under a readiness-only word is refused");
    // And a renewable Follow stops at either overload, guard first.
    for (const bool client_ready : {true, false}) {
        handle = follow_one(true);
        tick(client_ready);
        receipt = read_one(handle);
        check(receipt.phase == Phase::completed && receipt.reason == Reason::unavailable,
            "tick(bool) stops a renewable Follow and finishes cleanup");
        first = first_stop();
        check(first.origin == StopOrigin::lease_guard && first.reason == Reason::unavailable &&
            first.state.revocation == Revocation::client_not_ready, "a renewable Follow stops with lease_guard");
        check(acknowledge_completed(owner, handle), "acknowledged");
    }
}

// The scoped path a live callback entry takes runs the same lease edges as the
// raw one: a renewal-extended deadline and the guard both stop it there.
void dispatch_entry() {
    reset("dispatch_entry");
    using body_follow_lease::Refusal;
    using body_follow_lease::Revocation;
    constexpr auto entry_policy = body_follow_native::MotionPolicy::callback_entry;
    auto handle = follow_one(true, entry_policy);
    check(!dispatch_one() && !leaf.originals && !service().stop_cause_recorded,
        "the raw overload never follows a callback-entry Follow, and stops nothing");
    check(dispatch_entry_one() && leaf.originals == 1, "a live entry under a fresh guard is followed");
    {
        auto entry = body_follow_native::CallbackEntryTestAccess::make(&original, &supplied_pose);
        check(dispatch(entry) && leaf.originals == 2 && !entry.current(), "the entry is followed once and spent");
        check(!dispatch(entry) && leaf.originals == 2 && !service().stop_cause_recorded,
            "a spent entry is not followed again and stops nothing");
    }
    std::uint64_t remaining{}; auto refusal = Refusal::none;
    at(start_ms + 2800); tick(clear_guard());
    check(renew_one(handle, 41, remaining, refusal) && service().lease.deadline == start_ms + 3300, "renewed");
    at(start_ms + 3299); tick(clear_guard());
    check(dispatch_entry_one() && leaf.originals == 3, "a live entry before the extended deadline is followed");
    at(start_ms + 3300);
    check(!dispatch_entry_one() && leaf.originals == 3, "a live entry at the extended deadline is not followed");
    auto first = first_stop();
    check(first.origin == StopOrigin::dispatch_expired && first.reason == Reason::expired &&
        first.state.revocation == Revocation::deadline && first.state.renewals == 1,
        "the scoped path lapses at the extended deadline");
    complete_and_acknowledge(handle);
    // The guard on the scoped path.
    handle = follow_one(true, entry_policy);
    const auto reserved_at = service().lease.started;
    at(reserved_at + 250);
    check(!dispatch_entry_one() && leaf.originals == 3, "a live entry under a stale guard is not followed");
    first = first_stop();
    check(first.origin == StopOrigin::dispatch_guard && first.reason == Reason::unavailable &&
        first.state.revocation == Revocation::client_not_ready, "the scoped path stops with dispatch_guard");
    complete_and_acknowledge(handle);
}

// These scenarios drive the real Service with constructed current measurements.
// Native body/actor admission remains outside this executable.
owned_body::Sample lead_sample() {
    owned_body::Sample sample;
    sample.epoch = {23, body.generation, service_test::body_serial + 1, 2.0, 1.f / 60.f};
    sample.position = {10, 20, 30}; sample.rotation = {0, 0, 0, 1};
    sample.velocity = {3, 0, 0}; sample.angular_velocity = {0, 0, 2}; sample.mass = 12;
    return sample;
}
Handle reserve_attachment(const body_follow_native::Attachment& attachment) {
    tick(clear_guard());
    owned_bodies::MeasuredSource expected;
    check(owned_bodies::capture_source(owner, body, expected), "the lead reserve has a constructed source");
    Handle handle; Reason reason{};
    check(reserve(owner, body, expected, attachment, body_follow_api::eligible, handle, reason) &&
        handle.sequence && reason == Reason::none, "the converted lead attachment is reserved");
    return handle;
}
Handle follow_attachment(body_follow_api::Lead lead, bool scoped) {
    body_follow_api::Attachment api;
    api.offset_from_com = {0, 1, 0};
    api.cleanup = body_follow_api::CleanupPolicy::owned_body;
    api.motion_policy = scoped ? body_follow_api::MotionPolicy::callback_entry : body_follow_api::MotionPolicy::native_lifetime;
    api.lead = lead;
    body_follow_native::Attachment native;
    check(body_follow_native::attachment_from_api(api, native), "the runtime's conversion accepts the lead");
    const auto handle = reserve_attachment(native);
    Reason reason{};
    check(publish(owner, handle, reason) && reason == Reason::none, "the lead Follow is published");
    leaf.measured_target = true; leaf.dispatch_sample = lead_sample();
    return handle;
}
bool dispatch_lead(bool scoped) { return scoped ? dispatch_entry_one() : dispatch_one(); }
std::array<float, 16> unled_pose(const owned_body::Sample& sample) {
    auto value = supplied_pose;
    const auto& attachment = service().attachment;
    check(body_follow_transform::transform(sample, attachment.offset_from_com, attachment.root_in_body, value),
        "the reference unled transform is valid");
    return value;
}
bool same_pose(const std::array<float, 16>& left, const std::array<float, 16>& right) {
    return std::memcmp(left.data(), right.data(), sizeof(left)) == 0;
}

void lead_attachment() {
    reset("lead_attachment");
    body_follow_api::Attachment api;
    api.offset_from_com = {.2f, .4f, -.3f}; api.root_in_body = {0, .6f, 0, .8f};
    api.cleanup = body_follow_api::CleanupPolicy::owned_body;
    api.motion_policy = body_follow_api::MotionPolicy::callback_entry;
    api.lifetime = body_follow_api::Lifetime::renewable; api.lead = {2, true};
    body_follow_native::Attachment native;
    check(body_follow_native::attachment_from_api(api, native), "the same conversion used by RuntimeGame succeeds");
    check(native.offset_from_com == api.offset_from_com && native.root_in_body == api.root_in_body &&
        native.cleanup == api.cleanup && native.motion_policy == body_follow_native::MotionPolicy::callback_entry &&
        native.lifetime == api.lifetime && native.lead.steps == 2 && native.lead.angular,
        "every requested field survives the plugin-to-native conversion");
    const auto handle = reserve_attachment(native);
    const auto& copied = service().attachment;
    check(copied.offset_from_com == api.offset_from_com && copied.root_in_body == api.root_in_body &&
        copied.cleanup == api.cleanup && copied.motion_policy == native.motion_policy &&
        copied.lifetime == api.lifetime && copied.lead.steps == 2 && copied.lead.angular,
        "the actual Service retains the complete converted attachment");
    api.lead = {}; native.lead = {};
    check(copied.lead.steps == 2 && copied.lead.angular, "later caller edits cannot change the reserved lead");
    Reason reason{};
    check(publish(owner, handle, reason), "the copied attachment publishes");
    leaf.measured_target = true; leaf.dispatch_sample = lead_sample();
    check(dispatch_entry_one(), "the callback-entry dispatch reaches the constructed native leaf");
    check(leaf.prepared_attachment.lead.steps == 2 && leaf.prepared_attachment.lead.angular &&
        leaf.target_measurements == 1 && !service().lead_skipped,
        "the retained lead reaches preparation and uses one fresh measurement");
    check(stop(owner, handle), "stop the lead Follow");
    complete_and_acknowledge(handle);

    // A bad API value must clear the out conversion and cannot reach reserve.
    api.lead = {4, true}; native.lead = {3, true};
    check(!body_follow_native::attachment_from_api(api, native) && native.lead.steps == 0 && !native.lead.angular,
        "invalid API lead cannot leave a partially converted attachment");
    const auto reserves = leaf.reserve_bindings, captures = leaf.captures;
    owned_bodies::MeasuredSource expected;
    native.lead = {4, true};
    Handle refused;
    check(!reserve(owner, body, expected, native, body_follow_api::eligible, refused, reason) &&
        !refused.sequence && leaf.reserve_bindings == reserves && leaf.captures == captures,
        "the Service independently refuses invalid native lead before source or claim work");
    check(!service().occupied && !service().lead_skipped, "invalid lead adds no retained slot or counter duty");
}

void lead_dispatch() {
    for (const bool scoped : {false, true}) {
        reset("lead_dispatch");
        auto handle = follow_attachment({2, true}, scoped);
        check(dispatch_lead(scoped) && leaf.originals == 1 && leaf.target_measurements == 1,
            "one admitted callback forwards one freshly measured target");
        check(std::abs(leaf.original_value[12] - (10.f + 1.f / 30.f)) < 1e-5f &&
            leaf.original_value[13] == 21.f && leaf.original_value[14] == 30.f,
            "measured point velocity includes omega cross the attachment offset");
        check(service().final.source.sample().epoch.serial == service_test::body_serial + 1 &&
            same_pose(service().final.value, leaf.original_value), "the committed source and original target name this measurement");
        check(leaf.prepared_attachment.lead.steps == 2 && leaf.prepared_attachment.lead.angular &&
            service().binding.source.sample().velocity == owned_body::Vec{},
            "the lead comes from current motion rather than the stationary reservation sample");

        leaf.dispatch_sample.position = {}; leaf.dispatch_sample.velocity = {30, 0, 0};
        leaf.dispatch_sample.angular_velocity = {};
        leaf.dispatch_sample.epoch.seconds += 5e-8f; ++leaf.dispatch_sample.epoch.serial;
        check(dispatch_lead(scoped) && leaf.originals == 2 && leaf.target_measurements == 2,
            "the next callback takes a new measured velocity and step");
        const float measured_lead = static_cast<float>(30.0 * 2.0 * leaf.dispatch_sample.epoch.seconds);
        check(leaf.original_value[12] == measured_lead && std::abs(measured_lead - 1.f) > 1e-6f &&
            leaf.original_value[13] == 1.f && leaf.original_value[14] == 0.f,
            "the target uses the admitted sample step, not a hard-coded sixty-Hz interval or context read");
        for (const unsigned lane : {3u, 7u, 11u, 15u})
            check(leaf.original_value[lane] == supplied_pose[lane], "lead preserves supplied padding");
        check(!service().lead_skipped && read_one(handle).phase == Phase::following,
            "valid lead neither counts a fallback nor changes Follow state");
        check(stop(owner, handle), "stop the measured lead");
        complete_and_acknowledge(handle);

        handle = follow_attachment({0, true}, scoped);
        leaf.dispatch_sample.velocity[0] = std::numeric_limits<float>::quiet_NaN();
        leaf.dispatch_sample.angular_velocity[1] = std::numeric_limits<float>::infinity();
        leaf.dispatch_sample.epoch.seconds = 0;
        const auto original_pose = unled_pose(leaf.dispatch_sample);
        check(dispatch_lead(scoped) && same_pose(leaf.original_value, original_pose) && !service().lead_skipped,
            "zero steps keep the exact old transform and do not inspect unused motion");
        check(stop(owner, handle), "stop the unled Follow");
        complete_and_acknowledge(handle);

        handle = follow_attachment({2, false}, scoped);
        leaf.dispatch_sample.angular_velocity[0] = std::numeric_limits<float>::quiet_NaN();
        check(dispatch_lead(scoped) && std::abs(leaf.original_value[12] - 10.1f) < 1e-5f && !service().lead_skipped,
            "angular=false uses linear motion only and ignores unused spin");
        check(stop(owner, handle), "stop the linear-only lead");
        complete_and_acknowledge(handle);
    }
}

void lead_fallback() {
    for (const bool scoped : {false, true}) {
        reset("lead_fallback");
        auto handle = follow_attachment({2, true}, scoped);
        leaf.dispatch_sample.velocity[0] = std::numeric_limits<float>::quiet_NaN();
        const auto unled = unled_pose(leaf.dispatch_sample);
        check(dispatch_lead(scoped) && same_pose(leaf.original_value, unled) && service().lead_skipped == 1 &&
            leaf.originals == 1 && read_one(handle).phase == Phase::following,
            "an invalid constructed velocity commits the finite unled target and counts once");
        leaf.dispatch_sample = lead_sample();
        check(dispatch_lead(scoped) && service().lead_skipped == 1 && leaf.originals == 2,
            "the next valid tick recovers without adding a fallback");
        leaf.dispatch_sample.velocity = {101, 0, 0};
        leaf.during_original = [handle] {
            check(service().lead_skipped == 2, "the fallback count is committed before original runs");
            check(stop(owner, handle), "a stop during original retains the committed fallback");
        };
        check(dispatch_lead(scoped) && same_pose(leaf.original_value, unled) && leaf.originals == 3,
            "an excessive constructed velocity also forwards the complete finite baseline");
        check(first_stop().state.lead_skipped == 2 && service().lead_skipped == 2,
            "the first-stop diagnostic carries the committed fallback count");
        check(!dispatch_lead(scoped) && leaf.originals == 3 && service().lead_skipped == 2,
            "a stopped Follow neither follows nor counts again");
        complete_and_acknowledge(handle);
        check(!service().lead_skipped, "ACK resets the fallback count");

        // This private fixture seed proves reserve also resets its own counter.
        service().lead_skipped = 9;
        handle = follow_attachment({2, true}, scoped);
        check(!service().lead_skipped, "a new reserve has no earlier receipt's fallback count");
        leaf.dispatch_sample.velocity = {101, 0, 0};
        service().lead_skipped = std::numeric_limits<std::uint64_t>::max();
        check(dispatch_lead(scoped) && service().lead_skipped == std::numeric_limits<std::uint64_t>::max(),
            "the internal fallback counter saturates instead of wrapping");
        check(stop(owner, handle), "stop the saturated-count Follow");
        complete_and_acknowledge(handle);

        handle = follow_attachment({2, true}, scoped);
        leaf.dispatch_sample.velocity = {101, 0, 0};
        leaf.current_refusal = true;
        const auto originals = leaf.originals;
        check(!dispatch_lead(scoped) && leaf.originals == originals && !service().lead_skipped &&
            first_stop().origin == StopOrigin::dispatch_current,
            "a prepared fallback that loses current-target admission is never committed or counted");
        leaf.current_refusal = false;
        complete_and_acknowledge(handle);

        handle = follow_attachment({2, true}, scoped);
        leaf.dispatch_sample.velocity = {101, 0, 0};
        const auto deadline = service().lease.deadline;
        leaf.during_prepare = [deadline] { at(deadline); };
        check(!dispatch_lead(scoped) && leaf.originals == originals && !service().lead_skipped &&
            first_stop().origin == StopOrigin::dispatch_forwarding_expired,
            "a prepared fallback whose lease expires before forwarding is not counted");
        complete_and_acknowledge(handle);
    }
}
struct Scenario { const char* name; void (*run)(); };
constexpr Scenario scenarios[] = {
    {"fixed_unchanged", fixed_unchanged}, {"renew_deadline", renew_deadline}, {"renew_windows", renew_windows},
    {"renew_proof", renew_proof}, {"guard_tick_order", guard_tick_order}, {"guard_atomic", guard_atomic},
    {"guard_reserve_publish", guard_reserve_publish}, {"dispatch_guard_busy", dispatch_guard_busy},
    {"revision_exhausted", revision_exhausted}, {"revocation_first_only", revocation_first_only},
    {"ack_reset", ack_reset}, {"read_busy", read_busy},
    {"renew_expired_windows", renew_expired_windows}, {"renew_guard_windows", renew_guard_windows},
    {"extended_deadline_lapse", extended_deadline_lapse}, {"tick_ready_only", tick_ready_only},
    {"dispatch_entry", dispatch_entry},
    {"lead_attachment", lead_attachment}, {"lead_dispatch", lead_dispatch}, {"lead_fallback", lead_fallback},
};
} // namespace dingosdk::body_follow_service::test

int main(int argc, char** argv) {
    using dingosdk::body_follow_service::test::scenarios;
    const std::string_view wanted = argc > 1 ? argv[1] : "";
    unsigned ran{};
    for (const auto& scenario : scenarios) {
        if (!wanted.empty() && wanted != scenario.name) continue;
        scenario.run();
        ++ran;
        std::cout << "PASS " << scenario.name << '\n';
    }
    if (!ran) {
        std::cerr << "unknown body follow service scenario: " << wanted << '\n';
        return 1;
    }
    std::cout << ran << " Service scenarios, " << service_test::checks << " checks; native code executed: none\n";
    return 0;
}
